//! The UniFFI-exported surface: `DromeStore` plus every record/enum crossing
//! the FFI (docs/ARCHITECTURE.md, "Core public API").

use std::sync::{Arc, Mutex, MutexGuard};

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

use crate::error::DromeError;
use crate::events::{self, EventRow};
use crate::projections::Projection;
use crate::rules::RulesetKind;
use crate::time::{self, LocalInstant};
use crate::water::{self, ChugCheck, WaterState};
use crate::{db, export};

pub const DEFAULT_CHALLENGE_LENGTH_DAYS: u32 = 75;
/// The single Phase 1 extra preset (docs/ARCHITECTURE.md, "Event schema").
pub const JOB_EXTRA_ID: &str = "job_application";
pub const JOB_EXTRA_NAME: &str = "Apply to a job";

/// Payload bounds shared by the log_* APIs and the import validation in
/// `export::parse_snapshot` — a snapshot must not smuggle in values the log
/// APIs would reject.
pub(crate) const MAX_WATER_LOG_ML: i64 = 10_000;
pub(crate) const MAX_WATER_GOAL_ML: i64 = 50_000;
pub(crate) const MAX_WORKOUT_DURATION_MIN: u32 = 24 * 60;
pub(crate) const MAX_READING_PAGES: u32 = 10_000;
const MAX_CALENDAR_SPAN_DAYS: i64 = 1_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Cadence {
    Daily,
    Weekly,
}

impl Cadence {
    fn label(self) -> &'static str {
        match self {
            Cadence::Daily => "daily",
            Cadence::Weekly => "weekly",
        }
    }

    fn from_label(s: &str) -> Option<Self> {
        match s {
            "daily" => Some(Cadence::Daily),
            "weekly" => Some(Cadence::Weekly),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record, Serialize, Deserialize)]
pub struct Challenge {
    pub id: String,
    pub created_at: LocalInstant,
    pub ruleset: RulesetKind,
    pub start_date: String,
    pub length_days: u32,
    pub day_cutoff_minutes: u32,
    pub waking_start_minutes: u32,
    pub waking_end_minutes: u32,
    pub initial_water_goal_ml: i64,
    pub diet_description: Option<String>,
    pub current_book: Option<String>,
    pub active: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NewChallenge {
    pub ruleset: RulesetKind,
    pub start_date: String,
    pub length_days: u32,
    pub day_cutoff_minutes: u32,
    pub waking_start_minutes: u32,
    pub waking_end_minutes: u32,
    pub initial_water_goal_ml: i64,
    pub diet_description: Option<String>,
    pub current_book: Option<String>,
    pub created_at: LocalInstant,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record, Serialize, Deserialize)]
pub struct ContainerPreset {
    pub id: String,
    pub name: String,
    pub ml: i64,
    pub sort_order: i32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record, Serialize, Deserialize)]
pub struct ExtraDef {
    pub id: String,
    pub name: String,
    pub cadence: Cadence,
    pub enabled: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct BackfilledDay {
    pub date: String,
    pub water: bool,
    pub outdoor_workout: bool,
    pub second_workout: bool,
    pub reading: bool,
    pub diet: bool,
    /// "No Junk or Alcohol" — the sheet's sixth column, a peer of diet.
    /// Always explicit through this API; only *stored* legacy payloads
    /// missing the key default to `diet` (events::DayBackfilledPayload).
    pub no_junk: bool,
    pub photo: bool,
    pub extra_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record, Serialize)]
pub struct WorkoutEntry {
    pub event_uuid: String,
    pub duration_min: u32,
    pub outdoor: bool,
    pub note: Option<String>,
    pub started_at: Option<LocalInstant>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record, Serialize)]
pub struct DayState {
    pub date: String,
    /// Raw 1-based day number; may fall outside [1, length_days].
    pub day_index: i64,
    pub in_range: bool,
    pub is_backfilled: bool,
    pub is_closed: bool,
    pub water_ml: i64,
    pub water_goal_ml: i64,
    pub water_done: bool,
    pub workouts: Vec<WorkoutEntry>,
    pub outdoor_workout_done: bool,
    pub second_workout_done: bool,
    pub reading_pages: u32,
    pub reading_done: bool,
    pub diet_done: bool,
    /// "No Junk or Alcohol" attestation — sixth core task, a peer of diet.
    pub no_junk_done: bool,
    pub photo_done: bool,
    pub extras_done: Vec<String>,
    pub core_complete: bool,
}

#[derive(Debug, Clone, uniffi::Record, Serialize)]
pub struct WeekExtraState {
    pub extra_id: String,
    pub name: String,
    pub cadence: Cadence,
    pub week_index: u32,
    pub done: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TodayState {
    pub date: String,
    /// Clamped to [1, length_days]; `out_of_range` carries the truth.
    pub day_index: u32,
    pub out_of_range: bool,
    pub day: DayState,
    pub water: WaterState,
    pub week_extras: Vec<WeekExtraState>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record, Serialize)]
pub struct ChallengeSummary {
    pub days_complete_count: u32,
    pub current_run: u32,
    /// Clamped to [1, length_days]; `today_out_of_range` carries the truth.
    pub today_day_index: u32,
    pub today_out_of_range: bool,
    pub today_date: String,
    pub total_workouts: u32,
    pub total_outdoor_workouts: u32,
    pub total_pages: u64,
    pub total_water_ml: i64,
    pub start_date: String,
    pub length_days: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DayBrief {
    pub date: String,
    pub day_index: i64,
    pub in_range: bool,
    pub core_complete: bool,
    pub is_backfilled: bool,
    pub is_closed: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ShareCardWorkout {
    pub duration_min: u32,
    pub outdoor: bool,
}

/// Share-card payload. Never carries photo refs or workout notes.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ShareCardData {
    pub date: String,
    pub day_index: u32,
    pub out_of_range: bool,
    pub ruleset_label: String,
    pub core_complete: bool,
    pub is_backfilled: bool,
    pub current_run: u32,
    pub water_ml: i64,
    pub water_goal_ml: i64,
    pub water_done: bool,
    pub outdoor_workout_done: bool,
    pub second_workout_done: bool,
    pub reading_pages: u32,
    pub reading_done: bool,
    pub diet_done: bool,
    pub no_junk_done: bool,
    pub photo_done: bool,
    pub workouts: Vec<ShareCardWorkout>,
}

/// One non-revoked `water_add` or `water_adjust` event attributed to a given
/// date — the per-day signed pour ledger. Adds carry positive `ml`,
/// corrections negative. Backfill flags carry no quantity and never appear
/// here. Entries sum to the day's raw signed total; `DayState.water_ml`
/// folds the same entries with a running floor at 0 (an orphaned correction
/// clips instead of debiting later pours), so the two only diverge — the day
/// reading higher, never lower — after a revoke has reordered history
/// underneath a validated adjustment.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WaterLogEntry {
    pub event_uuid: String,
    /// Positive for `water_add`, negative for `water_adjust`.
    pub ml: i64,
    pub logged_at: LocalInstant,
    /// True when the event carried an explicit `effective_date` (retroactive
    /// logging / "edit yesterday"), as opposed to live cutoff attribution.
    pub retro: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LogResult {
    pub event_uuid: String,
    pub day_state: DayState,
    /// True exactly when this log flipped the day incomplete -> complete.
    pub day_became_complete: bool,
    pub week_extra_became_complete: bool,
    /// Present (for water logs) only when the anti-chug guard fires.
    pub chug_warning: Option<ChugCheck>,
}

#[derive(uniffi::Object)]
pub struct DromeStore {
    conn: Mutex<Connection>,
}

/// Water-specific behavior of a `log_kind` call (internal).
#[derive(Debug, Clone, Copy)]
enum WaterOp {
    /// Not a water-quantity event.
    None,
    /// A live `water_add`: run the anti-chug guard over this many ml.
    ChugCheckedAdd(i64),
    /// A `water_adjust`: reject when this (positive) magnitude exceeds the
    /// attributed day's current water total (the over-correction guard).
    BoundedDebit(i64),
}

/// Everything loaded for a projection pass.
struct Loaded {
    challenge: Challenge,
    events: Vec<EventRow>,
    projection: Projection,
}

#[uniffi::export]
impl DromeStore {
    #[uniffi::constructor]
    pub fn open(db_path: String) -> Result<Arc<Self>, DromeError> {
        let conn = db::open(&db_path)?;
        Ok(Arc::new(Self {
            conn: Mutex::new(conn),
        }))
    }

    pub fn active_challenge(&self) -> Result<Option<Challenge>, DromeError> {
        let conn = self.lock()?;
        load_active_challenge(&conn)
    }

    pub fn create_challenge(&self, cfg: NewChallenge) -> Result<Challenge, DromeError> {
        cfg.created_at.wall_secs()?;
        validate_challenge_config(
            &cfg.start_date,
            cfg.length_days,
            cfg.day_cutoff_minutes,
            cfg.waking_start_minutes,
            cfg.waking_end_minutes,
            cfg.initial_water_goal_ml,
        )?;

        let mut conn = self.lock()?;
        let id = Uuid::new_v4().to_string();
        let tx = conn.transaction()?;
        tx.execute("UPDATE challenge SET active = 0 WHERE active = 1", [])?;
        tx.execute(
            "INSERT INTO challenge (id, created_at_epoch, created_tz_offset_secs, ruleset,
                 start_date, length_days, day_cutoff_minutes, waking_start_minutes,
                 waking_end_minutes, initial_water_goal_ml, diet_description, current_book, active)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, 1)",
            params![
                id,
                cfg.created_at.epoch_secs,
                cfg.created_at.tz_offset_secs,
                cfg.ruleset.label(),
                cfg.start_date,
                cfg.length_days,
                cfg.day_cutoff_minutes,
                cfg.waking_start_minutes,
                cfg.waking_end_minutes,
                cfg.initial_water_goal_ml,
                cfg.diet_description,
                cfg.current_book,
            ],
        )?;
        tx.execute(
            "INSERT INTO extra_defs (id, challenge_id, name, cadence, enabled)
             VALUES (?1, ?2, ?3, ?4, 0)",
            params![JOB_EXTRA_ID, id, JOB_EXTRA_NAME, Cadence::Weekly.label()],
        )?;
        tx.commit()?;

        load_active_challenge(&conn)?.ok_or_else(|| {
            DromeError::Internal("challenge missing immediately after insert".into())
        })
    }

    pub fn update_presets(&self, presets: Vec<ContainerPreset>) -> Result<(), DromeError> {
        for p in &presets {
            if p.id.trim().is_empty() || p.name.trim().is_empty() {
                return Err(DromeError::InvalidArgument(
                    "preset id and name must be non-empty".into(),
                ));
            }
            if !(1..=MAX_WATER_LOG_ML).contains(&p.ml) {
                return Err(DromeError::InvalidArgument(format!(
                    "preset ml must be in 1..={MAX_WATER_LOG_ML}"
                )));
            }
        }
        let mut conn = self.lock()?;
        let challenge = require_active(&conn)?;
        let tx = conn.transaction()?;
        tx.execute(
            "DELETE FROM container_presets WHERE challenge_id = ?1",
            params![challenge.id],
        )?;
        for p in &presets {
            tx.execute(
                "INSERT INTO container_presets (id, challenge_id, name, ml, sort_order)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![p.id, challenge.id, p.name, p.ml, p.sort_order],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn container_presets(&self) -> Result<Vec<ContainerPreset>, DromeError> {
        let conn = self.lock()?;
        let challenge = require_active(&conn)?;
        let mut stmt = conn.prepare(
            "SELECT id, name, ml, sort_order FROM container_presets
             WHERE challenge_id = ?1 ORDER BY sort_order, id",
        )?;
        let rows = stmt.query_map(params![challenge.id], |row| {
            Ok(ContainerPreset {
                id: row.get(0)?,
                name: row.get(1)?,
                ml: row.get(2)?,
                sort_order: row.get(3)?,
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(DromeError::from)
    }

    pub fn set_extra_enabled(&self, extra_id: String, enabled: bool) -> Result<(), DromeError> {
        let conn = self.lock()?;
        let challenge = require_active(&conn)?;
        let changed = conn.execute(
            "UPDATE extra_defs SET enabled = ?1 WHERE challenge_id = ?2 AND id = ?3",
            params![enabled, challenge.id, extra_id],
        )?;
        if changed == 0 {
            return Err(DromeError::UnknownExtra(extra_id));
        }
        Ok(())
    }

    pub fn extra_defs(&self) -> Result<Vec<ExtraDef>, DromeError> {
        let conn = self.lock()?;
        let challenge = require_active(&conn)?;
        load_extra_defs(&conn, &challenge.id)
    }

    pub fn set_current_book(&self, title: String) -> Result<(), DromeError> {
        let conn = self.lock()?;
        let challenge = require_active(&conn)?;
        let book = if title.trim().is_empty() {
            None
        } else {
            Some(title)
        };
        conn.execute(
            "UPDATE challenge SET current_book = ?1 WHERE id = ?2",
            params![book, challenge.id],
        )?;
        Ok(())
    }

    /// Goal changes are events: past days keep the goal they were lived under.
    pub fn set_water_goal(&self, ml: i64, now: LocalInstant) -> Result<(), DromeError> {
        if !(1..=MAX_WATER_GOAL_ML).contains(&ml) {
            return Err(DromeError::InvalidArgument(format!(
                "water goal ml must be in 1..={MAX_WATER_GOAL_ML}"
            )));
        }
        now.wall_secs()?;
        let conn = self.lock()?;
        let challenge = require_active(&conn)?;
        insert_event(
            &conn,
            &challenge.id,
            now,
            None,
            events::KIND_GOAL_CHANGED,
            &json!({ "water_goal_ml": ml }),
        )?;
        Ok(())
    }

    /// Display-only config; safe to edit mid-challenge.
    pub fn set_diet_description(&self, desc: String) -> Result<(), DromeError> {
        let trimmed = desc.trim();
        if trimmed.chars().count() > 500 {
            return Err(DromeError::InvalidArgument(
                "diet description is capped at 500 characters".into(),
            ));
        }
        let conn = self.lock()?;
        let challenge = require_active(&conn)?;
        let value = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_owned())
        };
        conn.execute(
            "UPDATE challenge SET diet_description = ?1 WHERE id = ?2",
            params![value, challenge.id],
        )?;
        Ok(())
    }

    /// The waking window only drives WaterState pacing and the
    /// discourage_catch_up display — never day attribution or completion — so
    /// editing it mid-challenge is a plain config update, not an event.
    pub fn set_waking_window(
        &self,
        start_minutes: u16,
        end_minutes: u16,
    ) -> Result<(), DromeError> {
        // Same bounds as create_challenge/import (validate_challenge_config):
        // end == 1440 (midnight) is a valid window end for the pacing math.
        if start_minutes >= end_minutes || end_minutes > 1_440 {
            return Err(DromeError::InvalidArgument(
                "waking window must satisfy 0 <= start < end <= 1440".into(),
            ));
        }
        let conn = self.lock()?;
        let challenge = require_active(&conn)?;
        conn.execute(
            "UPDATE challenge SET waking_start_minutes = ?1, waking_end_minutes = ?2
             WHERE id = ?3",
            params![start_minutes, end_minutes, challenge.id],
        )?;
        Ok(())
    }

    pub fn log_water(
        &self,
        ml: i64,
        now: LocalInstant,
        effective_date: Option<String>,
    ) -> Result<LogResult, DromeError> {
        if !(1..=MAX_WATER_LOG_ML).contains(&ml) {
            return Err(DromeError::InvalidArgument(format!(
                "water ml must be in 1..={MAX_WATER_LOG_ML}"
            )));
        }
        // Retroactive water (explicit effective_date) is bookkeeping, not
        // current intake: it never trips the anti-chug guard.
        let water_op = if effective_date.is_some() {
            WaterOp::None
        } else {
            WaterOp::ChugCheckedAdd(ml)
        };
        self.log_kind(
            events::KIND_WATER_ADD,
            json!({ "ml": ml }),
            now,
            effective_date,
            None,
            water_op,
        )
    }

    /// Signed correction for over-recorded water. NEGATIVE-ONLY
    /// (`-10_000..=-1`); positive intake stays `log_water`. Rejected
    /// (`InvalidArgument`) when the magnitude exceeds the attributed day's
    /// current water total — the UI clamps, the core enforces. It can only
    /// lower a day's water, so `day_became_complete` never fires from it,
    /// and it returns no chug warning (corrections are not intake).
    pub fn log_water_adjustment(
        &self,
        ml: i64,
        now: LocalInstant,
        effective_date: Option<String>,
    ) -> Result<LogResult, DromeError> {
        if !(-MAX_WATER_LOG_ML..=-1).contains(&ml) {
            return Err(DromeError::InvalidArgument(format!(
                "water adjustment ml must be in -{MAX_WATER_LOG_ML}..=-1"
            )));
        }
        self.log_kind(
            events::KIND_WATER_ADJUST,
            json!({ "ml": ml }),
            now,
            effective_date,
            None,
            WaterOp::BoundedDebit(-ml),
        )
    }

    pub fn log_workout(
        &self,
        duration_min: u32,
        outdoor: bool,
        note: Option<String>,
        started_at: Option<LocalInstant>,
        now: LocalInstant,
        effective_date: Option<String>,
    ) -> Result<LogResult, DromeError> {
        if duration_min == 0 || duration_min > MAX_WORKOUT_DURATION_MIN {
            return Err(DromeError::InvalidArgument(format!(
                "workout duration_min must be in 1..={MAX_WORKOUT_DURATION_MIN}"
            )));
        }
        let payload = serde_json::to_value(events::WorkoutPayload {
            duration_min,
            outdoor,
            note,
            started_at,
        })?;
        self.log_kind(
            events::KIND_WORKOUT,
            payload,
            now,
            effective_date,
            None,
            WaterOp::None,
        )
    }

    pub fn log_reading(
        &self,
        book_title: String,
        pages: u32,
        now: LocalInstant,
        effective_date: Option<String>,
    ) -> Result<LogResult, DromeError> {
        if pages == 0 || pages > MAX_READING_PAGES {
            return Err(DromeError::InvalidArgument(format!(
                "pages must be in 1..={MAX_READING_PAGES}"
            )));
        }
        self.log_kind(
            events::KIND_READING,
            json!({ "book_title": book_title, "pages": pages }),
            now,
            effective_date,
            None,
            WaterOp::None,
        )
    }

    pub fn log_diet_ok(
        &self,
        now: LocalInstant,
        effective_date: Option<String>,
    ) -> Result<LogResult, DromeError> {
        self.log_kind(
            events::KIND_DIET_OK,
            json!({}),
            now,
            effective_date,
            None,
            WaterOp::None,
        )
    }

    /// "No Junk or Alcohol" attestation — the sixth core task, mirroring the
    /// sheet's column of the same name (a separate peer of "Nutrition/Diet").
    pub fn log_no_junk_ok(
        &self,
        now: LocalInstant,
        effective_date: Option<String>,
    ) -> Result<LogResult, DromeError> {
        self.log_kind(
            events::KIND_NO_JUNK_OK,
            json!({}),
            now,
            effective_date,
            None,
            WaterOp::None,
        )
    }

    pub fn log_photo_done(
        &self,
        photo_ref: Option<String>,
        now: LocalInstant,
        effective_date: Option<String>,
    ) -> Result<LogResult, DromeError> {
        self.log_kind(
            events::KIND_PHOTO_DONE,
            json!({ "photo_ref": photo_ref }),
            now,
            effective_date,
            None,
            WaterOp::None,
        )
    }

    pub fn log_extra_done(
        &self,
        extra_id: String,
        now: LocalInstant,
        effective_date: Option<String>,
    ) -> Result<LogResult, DromeError> {
        {
            let conn = self.lock()?;
            let challenge = require_active(&conn)?;
            let known: bool = conn.query_row(
                "SELECT COUNT(*) > 0 FROM extra_defs WHERE challenge_id = ?1 AND id = ?2",
                params![challenge.id, extra_id],
                |row| row.get(0),
            )?;
            if !known {
                return Err(DromeError::UnknownExtra(extra_id));
            }
        }
        self.log_kind(
            events::KIND_EXTRA_DONE,
            json!({ "extra_id": extra_id }),
            now,
            effective_date,
            Some(extra_id.clone()),
            WaterOp::None,
        )
    }

    pub fn close_day(&self, date: String, now: LocalInstant) -> Result<DayState, DromeError> {
        let parsed = time::parse_date(&date)?;
        now.wall_secs()?;
        let conn = self.lock()?;
        let challenge = require_active(&conn)?;
        insert_event(
            &conn,
            &challenge.id,
            now,
            None,
            events::KIND_DAY_CLOSED,
            &json!({ "date": date }),
        )?;
        let loaded = load(&conn)?;
        Ok(loaded.projection.day_state(parsed))
    }

    pub fn revoke_event(&self, event_uuid: String, now: LocalInstant) -> Result<(), DromeError> {
        now.wall_secs()?;
        let conn = self.lock()?;
        let challenge = require_active(&conn)?;
        let kind: Option<String> = conn
            .query_row(
                "SELECT kind FROM events WHERE uuid = ?1 AND challenge_id = ?2",
                params![event_uuid, challenge.id],
                |row| row.get(0),
            )
            .optional()?;
        match kind.as_deref() {
            None => return Err(DromeError::EventNotFound(event_uuid)),
            Some(events::KIND_REVOKED) => {
                return Err(DromeError::InvalidArgument(
                    "revocations cannot be revoked".into(),
                ))
            }
            Some(_) => {}
        }
        insert_event(
            &conn,
            &challenge.id,
            now,
            None,
            events::KIND_REVOKED,
            &json!({ "event_uuid": event_uuid }),
        )?;
        Ok(())
    }

    /// Inserts one `day_backfilled` event per day, all in a single transaction.
    pub fn backfill_days(
        &self,
        days: Vec<BackfilledDay>,
        now: LocalInstant,
    ) -> Result<(), DromeError> {
        now.wall_secs()?;
        let mut conn = self.lock()?;
        let challenge = require_active(&conn)?;
        let known_extras: Vec<String> = load_extra_defs(&conn, &challenge.id)?
            .into_iter()
            .map(|e| e.id)
            .collect();
        for day in &days {
            time::parse_date(&day.date)?;
            for extra in &day.extra_ids {
                if !known_extras.iter().any(|k| k == extra) {
                    return Err(DromeError::UnknownExtra(extra.clone()));
                }
            }
        }
        let tx = conn.transaction()?;
        for day in &days {
            let payload = json!({
                "date": day.date,
                "water": day.water,
                "outdoor_workout": day.outdoor_workout,
                "second_workout": day.second_workout,
                "reading": day.reading,
                "diet": day.diet,
                "no_junk": day.no_junk,
                "photo": day.photo,
                "extra_ids": day.extra_ids,
            });
            insert_event(
                &tx,
                &challenge.id,
                now,
                Some(&day.date),
                events::KIND_DAY_BACKFILLED,
                &payload,
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn day_state(&self, date: String, now: LocalInstant) -> Result<DayState, DromeError> {
        let parsed = time::parse_date(&date)?;
        now.wall_secs()?;
        let conn = self.lock()?;
        let loaded = load(&conn)?;
        Ok(loaded.projection.day_state(parsed))
    }

    /// Every non-revoked `water_add` / `water_adjust` event attributed to
    /// `date` (adds positive, corrections negative), ordered by `logged_at`
    /// ascending. Attribution is exactly the day projection's (cutoff,
    /// closed-day rollover, explicit effective_date), so the entries sum to
    /// that date's raw signed total — `DayState.water_ml` folds the same
    /// entries with a running floor at 0 and only diverges (reading higher,
    /// never lower) after a revoke reorders history. `day_backfilled` water
    /// is a flag with no quantity and is deliberately excluded.
    pub fn water_log(
        &self,
        date: String,
        now: LocalInstant,
    ) -> Result<Vec<WaterLogEntry>, DromeError> {
        let parsed = time::parse_date(&date)?;
        now.wall_secs()?;
        let conn = self.lock()?;
        let loaded = load(&conn)?;
        let proj = &loaded.projection;
        let mut entries = Vec::new();
        // `loaded.events` is ordered by (logged_at_epoch, id) — already the
        // required logged_at-ascending order.
        for e in &loaded.events {
            let ml = match e.kind.as_str() {
                events::KIND_WATER_ADD => e.payload_as::<events::WaterAddPayload>()?.ml,
                events::KIND_WATER_ADJUST => e.payload_as::<events::WaterAdjustPayload>()?.ml,
                _ => continue,
            };
            if proj.is_revoked(&e.uuid)
                || proj.attribute(e.logged_at, e.effective_date.as_deref())? != parsed
            {
                continue;
            }
            entries.push(WaterLogEntry {
                event_uuid: e.uuid.clone(),
                ml,
                logged_at: e.logged_at,
                retro: e.effective_date.is_some(),
            });
        }
        Ok(entries)
    }

    pub fn today(&self, now: LocalInstant) -> Result<TodayState, DromeError> {
        let conn = self.lock()?;
        let loaded = load(&conn)?;
        let proj = &loaded.projection;
        let date = proj.attribute(now, None)?;
        let day = proj.day_state(date);
        let week_idx = time::week_index(day.day_index);

        let minutes = time::minutes_into_day(now, date)?;
        let water = water::compute_water_state(
            day.water_ml,
            day.water_goal_ml,
            minutes,
            loaded.challenge.waking_start_minutes,
            loaded.challenge.waking_end_minutes,
        );

        let mut week_extras = Vec::new();
        for extra in load_extra_defs(&conn, &loaded.challenge.id)? {
            if !extra.enabled {
                continue;
            }
            let done = match extra.cadence {
                Cadence::Weekly => proj.week_extra_done(&extra.id, week_idx)?,
                Cadence::Daily => proj.extra_done_on(&extra.id, date),
            };
            week_extras.push(WeekExtraState {
                extra_id: extra.id,
                name: extra.name,
                cadence: extra.cadence,
                week_index: clamp_u32(week_idx, 1),
                done,
            });
        }

        Ok(TodayState {
            date: day.date.clone(),
            day_index: clamp_index(day.day_index, loaded.challenge.length_days),
            out_of_range: !day.in_range,
            day,
            water,
            week_extras,
        })
    }

    pub fn summary(&self, now: LocalInstant) -> Result<ChallengeSummary, DromeError> {
        let conn = self.lock()?;
        let loaded = load(&conn)?;
        build_summary(&loaded, now)
    }

    pub fn calendar(
        &self,
        from_date: String,
        to_date: String,
        now: LocalInstant,
    ) -> Result<Vec<DayBrief>, DromeError> {
        let from = time::parse_date(&from_date)?;
        let to = time::parse_date(&to_date)?;
        now.wall_secs()?;
        if from > to {
            return Err(DromeError::InvalidArgument(
                "from_date must be <= to_date".into(),
            ));
        }
        let span = to.signed_duration_since(from).num_days();
        if span >= MAX_CALENDAR_SPAN_DAYS {
            return Err(DromeError::InvalidArgument(format!(
                "calendar range is capped at {MAX_CALENDAR_SPAN_DAYS} days"
            )));
        }
        let conn = self.lock()?;
        let loaded = load(&conn)?;
        let mut briefs = Vec::with_capacity((span + 1) as usize);
        for date in from.iter_days().take_while(|d| *d <= to) {
            let day = loaded.projection.day_state(date);
            briefs.push(DayBrief {
                date: day.date,
                day_index: day.day_index,
                in_range: day.in_range,
                core_complete: day.core_complete,
                is_backfilled: day.is_backfilled,
                is_closed: day.is_closed,
            });
        }
        Ok(briefs)
    }

    pub fn water_state(&self, now: LocalInstant) -> Result<WaterState, DromeError> {
        let conn = self.lock()?;
        let loaded = load(&conn)?;
        let date = loaded.projection.attribute(now, None)?;
        let day = loaded.projection.day_state(date);
        let minutes = time::minutes_into_day(now, date)?;
        Ok(water::compute_water_state(
            day.water_ml,
            day.water_goal_ml,
            minutes,
            loaded.challenge.waking_start_minutes,
            loaded.challenge.waking_end_minutes,
        ))
    }

    pub fn check_chug(&self, now: LocalInstant, add_ml: i64) -> Result<ChugCheck, DromeError> {
        if add_ml < 0 {
            return Err(DromeError::InvalidArgument("add_ml must be >= 0".into()));
        }
        now.wall_secs()?;
        let conn = self.lock()?;
        let loaded = load(&conn)?;
        let trailing =
            water::trailing_hour_ml(loaded.projection.water_events_by_epoch(), now.epoch_secs);
        Ok(water::check_chug(trailing, add_ml))
    }

    pub fn share_card(&self, date: String, now: LocalInstant) -> Result<ShareCardData, DromeError> {
        let parsed = time::parse_date(&date)?;
        let conn = self.lock()?;
        let loaded = load(&conn)?;
        let proj = &loaded.projection;
        let day = proj.day_state(parsed);
        let today = proj.attribute(now, None)?;
        Ok(ShareCardData {
            date: day.date,
            day_index: clamp_index(day.day_index, loaded.challenge.length_days),
            out_of_range: !day.in_range,
            ruleset_label: loaded.challenge.ruleset.label().to_owned(),
            core_complete: day.core_complete,
            is_backfilled: day.is_backfilled,
            current_run: proj.current_run(today)?,
            water_ml: day.water_ml,
            water_goal_ml: day.water_goal_ml,
            water_done: day.water_done,
            outdoor_workout_done: day.outdoor_workout_done,
            second_workout_done: day.second_workout_done,
            reading_pages: day.reading_pages,
            reading_done: day.reading_done,
            diet_done: day.diet_done,
            no_junk_done: day.no_junk_done,
            photo_done: day.photo_done,
            workouts: day
                .workouts
                .iter()
                .map(|w| ShareCardWorkout {
                    duration_min: w.duration_min,
                    outdoor: w.outdoor,
                })
                .collect(),
        })
    }

    pub fn export_json(&self, now: LocalInstant) -> Result<String, DromeError> {
        let conn = self.lock()?;
        let loaded = load(&conn)?;
        let presets = load_presets(&conn, &loaded.challenge.id)?;
        let extras = load_extra_defs(&conn, &loaded.challenge.id)?;
        let summary = build_summary(&loaded, now)?;
        export::export_json(
            &loaded.challenge,
            &presets,
            &extras,
            &loaded.events,
            &loaded.projection,
            &summary,
            now,
        )
    }

    pub fn export_csv(&self, now: LocalInstant) -> Result<String, DromeError> {
        let conn = self.lock()?;
        let loaded = load(&conn)?;
        export::export_csv(&loaded.projection, now)
    }

    /// Restores an `export_json` snapshot (challenge config, presets, extra
    /// defs, all events) — the reinstall/restore path. Only into a store with
    /// no active challenge; day states and summary are re-projected from the
    /// log, never read from the snapshot.
    pub fn import_json(&self, snapshot: String) -> Result<(), DromeError> {
        let snap = export::parse_snapshot(&snapshot)?;
        validate_challenge_config(
            &snap.challenge.start_date,
            snap.challenge.length_days,
            snap.challenge.day_cutoff_minutes,
            snap.challenge.waking_start_minutes,
            snap.challenge.waking_end_minutes,
            snap.challenge.initial_water_goal_ml,
        )?;
        // Prove the imported log projects cleanly before touching the DB.
        Projection::build(&snap.challenge, &snap.event_rows())?;

        let mut conn = self.lock()?;
        if load_active_challenge(&conn)?.is_some() {
            return Err(DromeError::ActiveChallengeExists);
        }
        let id_taken: bool = conn.query_row(
            "SELECT COUNT(*) > 0 FROM challenge WHERE id = ?1",
            params![snap.challenge.id],
            |row| row.get(0),
        )?;
        if id_taken {
            return Err(DromeError::InvalidArgument(format!(
                "challenge {} already exists in this store",
                snap.challenge.id
            )));
        }

        let c = &snap.challenge;
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO challenge (id, created_at_epoch, created_tz_offset_secs, ruleset,
                 start_date, length_days, day_cutoff_minutes, waking_start_minutes,
                 waking_end_minutes, initial_water_goal_ml, diet_description, current_book, active)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, 1)",
            params![
                c.id,
                c.created_at.epoch_secs,
                c.created_at.tz_offset_secs,
                c.ruleset.label(),
                c.start_date,
                c.length_days,
                c.day_cutoff_minutes,
                c.waking_start_minutes,
                c.waking_end_minutes,
                c.initial_water_goal_ml,
                c.diet_description,
                c.current_book,
            ],
        )?;
        for p in &snap.container_presets {
            tx.execute(
                "INSERT INTO container_presets (id, challenge_id, name, ml, sort_order)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![p.id, c.id, p.name, p.ml, p.sort_order],
            )?;
        }
        for x in &snap.extra_defs {
            tx.execute(
                "INSERT INTO extra_defs (id, challenge_id, name, cadence, enabled)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![x.id, c.id, x.name, x.cadence.label(), x.enabled],
            )?;
        }
        for e in &snap.events {
            tx.execute(
                "INSERT INTO events (uuid, challenge_id, logged_at_epoch, tz_offset_secs,
                                     effective_date, kind, payload, schema_version)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    e.uuid,
                    c.id,
                    e.logged_at_epoch,
                    e.tz_offset_secs,
                    e.effective_date,
                    e.kind,
                    serde_json::to_string(&e.payload)?,
                    e.schema_version,
                ],
            )?;
        }
        tx.commit()?;
        Ok(())
    }
}

impl DromeStore {
    fn lock(&self) -> Result<MutexGuard<'_, Connection>, DromeError> {
        self.conn
            .lock()
            .map_err(|_| DromeError::Internal("connection lock poisoned".into()))
    }

    /// Shared write path for the log_* methods: project, insert, re-project,
    /// and report the incomplete -> complete flips (the completion moments).
    fn log_kind(
        &self,
        kind: &str,
        payload: serde_json::Value,
        now: LocalInstant,
        effective_date: Option<String>,
        week_extra_id: Option<String>,
        water_op: WaterOp,
    ) -> Result<LogResult, DromeError> {
        now.wall_secs()?;
        let conn = self.lock()?;
        let loaded = load(&conn)?;
        let pre = &loaded.projection;

        let date = pre.attribute(now, effective_date.as_deref())?;
        let pre_day = pre.day_state(date);
        let week_idx = time::week_index(pre_day.day_index);
        let pre_week_done = match &week_extra_id {
            Some(id) => pre.week_extra_done(id, week_idx)?,
            None => false,
        };
        let chug_warning = match water_op {
            WaterOp::ChugCheckedAdd(ml) => {
                let trailing = water::trailing_hour_ml(pre.water_events_by_epoch(), now.epoch_secs);
                Some(water::check_chug(trailing, ml)).filter(|check| check.warn)
            }
            WaterOp::None | WaterOp::BoundedDebit(_) => None,
        };
        if let WaterOp::BoundedDebit(debit) = water_op {
            // Over-correction guard: an adjustment may remove at most the
            // water currently attributed to the day. `pre_day.water_ml` is
            // already floored at 0, so this bound is against what the user
            // actually sees. (The UI clamps; the core enforces.)
            if debit > pre_day.water_ml {
                return Err(DromeError::InvalidArgument(format!(
                    "water adjustment of -{debit} ml exceeds the day's current total of {} ml",
                    pre_day.water_ml
                )));
            }
        }

        let event_uuid = insert_event(
            &conn,
            &loaded.challenge.id,
            now,
            effective_date.as_deref(),
            kind,
            &payload,
        )?;

        let post = load(&conn)?.projection;
        let post_day = post.day_state(date);
        let day_became_complete = !pre_day.core_complete && post_day.core_complete;
        let week_extra_became_complete = match &week_extra_id {
            Some(id) => !pre_week_done && post.week_extra_done(id, week_idx)?,
            None => false,
        };

        Ok(LogResult {
            event_uuid,
            day_state: post_day,
            day_became_complete,
            week_extra_became_complete,
            chug_warning,
        })
    }
}

fn clamp_index(raw: i64, length_days: u32) -> u32 {
    raw.clamp(1, i64::from(length_days.max(1))) as u32
}

fn clamp_u32(raw: i64, min: u32) -> u32 {
    raw.clamp(i64::from(min), i64::from(u32::MAX)) as u32
}

fn validate_challenge_config(
    start_date: &str,
    length_days: u32,
    day_cutoff_minutes: u32,
    waking_start_minutes: u32,
    waking_end_minutes: u32,
    initial_water_goal_ml: i64,
) -> Result<(), DromeError> {
    time::parse_date(start_date)?;
    if length_days == 0 || length_days > 1_000 {
        return Err(DromeError::InvalidArgument(
            "length_days must be in 1..=1000".into(),
        ));
    }
    if day_cutoff_minutes >= 1_440 {
        return Err(DromeError::InvalidArgument(
            "day_cutoff_minutes must be in 0..=1439".into(),
        ));
    }
    if waking_start_minutes >= waking_end_minutes || waking_end_minutes > 1_440 {
        return Err(DromeError::InvalidArgument(
            "waking window must satisfy start < end <= 1440".into(),
        ));
    }
    if !(1..=MAX_WATER_GOAL_ML).contains(&initial_water_goal_ml) {
        return Err(DromeError::InvalidArgument(format!(
            "initial_water_goal_ml must be in 1..={MAX_WATER_GOAL_ML}"
        )));
    }
    Ok(())
}

fn build_summary(loaded: &Loaded, now: LocalInstant) -> Result<ChallengeSummary, DromeError> {
    let proj = &loaded.projection;
    let today = proj.attribute(now, None)?;
    let raw_idx = time::day_index(proj.start_date(), today);
    let (total_workouts, total_outdoor_workouts, total_pages, total_water_ml) = proj.totals();
    Ok(ChallengeSummary {
        days_complete_count: proj.days_complete_count()?,
        current_run: proj.current_run(today)?,
        today_day_index: clamp_index(raw_idx, loaded.challenge.length_days),
        today_out_of_range: raw_idx < 1 || raw_idx > i64::from(loaded.challenge.length_days),
        today_date: time::format_date(today),
        total_workouts,
        total_outdoor_workouts,
        total_pages,
        total_water_ml,
        start_date: loaded.challenge.start_date.clone(),
        length_days: loaded.challenge.length_days,
    })
}

fn load(conn: &Connection) -> Result<Loaded, DromeError> {
    let challenge = require_active(conn)?;
    let events = load_events(conn, &challenge.id)?;
    let projection = Projection::build(&challenge, &events)?;
    Ok(Loaded {
        challenge,
        events,
        projection,
    })
}

fn require_active(conn: &Connection) -> Result<Challenge, DromeError> {
    load_active_challenge(conn)?.ok_or(DromeError::NoActiveChallenge)
}

fn load_active_challenge(conn: &Connection) -> Result<Option<Challenge>, DromeError> {
    let mut stmt = conn.prepare(
        "SELECT id, created_at_epoch, created_tz_offset_secs, ruleset, start_date, length_days,
                day_cutoff_minutes, waking_start_minutes, waking_end_minutes,
                initial_water_goal_ml, diet_description, current_book, active
         FROM challenge WHERE active = 1 LIMIT 1",
    )?;
    let row = stmt
        .query_row([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i32>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, u32>(5)?,
                row.get::<_, u32>(6)?,
                row.get::<_, u32>(7)?,
                row.get::<_, u32>(8)?,
                row.get::<_, i64>(9)?,
                row.get::<_, Option<String>>(10)?,
                row.get::<_, Option<String>>(11)?,
                row.get::<_, bool>(12)?,
            ))
        })
        .optional()?;
    let Some((
        id,
        created_at_epoch,
        created_tz_offset_secs,
        ruleset,
        start_date,
        length_days,
        day_cutoff_minutes,
        waking_start_minutes,
        waking_end_minutes,
        initial_water_goal_ml,
        diet_description,
        current_book,
        active,
    )) = row
    else {
        return Ok(None);
    };
    let ruleset = RulesetKind::from_label(&ruleset)
        .ok_or_else(|| DromeError::Internal(format!("unknown ruleset in db: {ruleset}")))?;
    Ok(Some(Challenge {
        id,
        created_at: LocalInstant {
            epoch_secs: created_at_epoch,
            tz_offset_secs: created_tz_offset_secs,
        },
        ruleset,
        start_date,
        length_days,
        day_cutoff_minutes,
        waking_start_minutes,
        waking_end_minutes,
        initial_water_goal_ml,
        diet_description,
        current_book,
        active,
    }))
}

fn load_extra_defs(conn: &Connection, challenge_id: &str) -> Result<Vec<ExtraDef>, DromeError> {
    let mut stmt = conn.prepare(
        "SELECT id, name, cadence, enabled FROM extra_defs
         WHERE challenge_id = ?1 ORDER BY id",
    )?;
    let rows = stmt.query_map(params![challenge_id], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, bool>(3)?,
        ))
    })?;
    let mut defs = Vec::new();
    for row in rows {
        let (id, name, cadence, enabled) = row?;
        let cadence = Cadence::from_label(&cadence)
            .ok_or_else(|| DromeError::Internal(format!("unknown cadence in db: {cadence}")))?;
        defs.push(ExtraDef {
            id,
            name,
            cadence,
            enabled,
        });
    }
    Ok(defs)
}

fn load_presets(conn: &Connection, challenge_id: &str) -> Result<Vec<ContainerPreset>, DromeError> {
    let mut stmt = conn.prepare(
        "SELECT id, name, ml, sort_order FROM container_presets
         WHERE challenge_id = ?1 ORDER BY sort_order, id",
    )?;
    let rows = stmt.query_map(params![challenge_id], |row| {
        Ok(ContainerPreset {
            id: row.get(0)?,
            name: row.get(1)?,
            ml: row.get(2)?,
            sort_order: row.get(3)?,
        })
    })?;
    rows.collect::<rusqlite::Result<Vec<_>>>()
        .map_err(DromeError::from)
}

fn load_events(conn: &Connection, challenge_id: &str) -> Result<Vec<EventRow>, DromeError> {
    let mut stmt = conn.prepare(
        "SELECT id, uuid, challenge_id, logged_at_epoch, tz_offset_secs, effective_date,
                kind, payload, schema_version
         FROM events WHERE challenge_id = ?1 ORDER BY logged_at_epoch, id",
    )?;
    let rows = stmt.query_map(params![challenge_id], |row| {
        Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, i64>(3)?,
            row.get::<_, i32>(4)?,
            row.get::<_, Option<String>>(5)?,
            row.get::<_, String>(6)?,
            row.get::<_, String>(7)?,
            row.get::<_, i64>(8)?,
        ))
    })?;
    let mut events = Vec::new();
    for row in rows {
        let (id, uuid, challenge_id, epoch, offset, effective_date, kind, payload, version) = row?;
        events.push(EventRow {
            id,
            uuid,
            challenge_id,
            logged_at: LocalInstant {
                epoch_secs: epoch,
                tz_offset_secs: offset,
            },
            effective_date,
            kind,
            payload: serde_json::from_str(&payload)?,
            schema_version: version,
        });
    }
    Ok(events)
}

fn insert_event(
    conn: &Connection,
    challenge_id: &str,
    now: LocalInstant,
    effective_date: Option<&str>,
    kind: &str,
    payload: &serde_json::Value,
) -> Result<String, DromeError> {
    let uuid = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO events (uuid, challenge_id, logged_at_epoch, tz_offset_secs,
                             effective_date, kind, payload, schema_version)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            uuid,
            challenge_id,
            now.epoch_secs,
            now.tz_offset_secs,
            effective_date,
            kind,
            serde_json::to_string(payload)?,
            // The log dialect this build writes; v1 rows mark pre-no-junk
            // history (see events::SIX_TASK_SCHEMA_VERSION).
            events::EVENT_SCHEMA_VERSION,
        ],
    )?;
    Ok(uuid)
}
