//! The UniFFI-exported surface: `DromeStore` plus every record/enum crossing
//! the FFI (docs/ARCHITECTURE.md, "Core public API").

use std::sync::{Arc, Mutex, MutexGuard};

use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

use crate::error::DromeError;
use crate::events::{self, EventRow};
use crate::projections::Projection;
use crate::rules::RulesetKind;
use crate::time::{self, LocalInstant};
use crate::water::{self, ChugCheck, WaterState};
use crate::{db, export, sync};

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
    pub(crate) fn label(self) -> &'static str {
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

/// A core task `revoke_task` can un-complete. Workouts and water are
/// deliberately NOT here: they already revoke entry-by-entry
/// (`WorkoutEntry.event_uuid` / the `water_log` ledger + `revoke_event`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RevocableTask {
    Diet,
    NoJunk,
    Photo,
    Reading,
    Extra { id: String },
}

impl RevocableTask {
    /// Human-readable name for error messages.
    fn describe(&self) -> String {
        match self {
            RevocableTask::Diet => "diet".into(),
            RevocableTask::NoJunk => "no-junk".into(),
            RevocableTask::Photo => "photo".into(),
            RevocableTask::Reading => "reading".into(),
            RevocableTask::Extra { id } => format!("extra {id:?}"),
        }
    }
}

/// Per-task revocability of a day, for the UI's toggle affordances. A flag is
/// `true` exactly when a live (non-revoked) event of that kind is attributed
/// to the date — i.e. exactly when `revoke_task` would succeed for it.
/// Tasks satisfied only by a `day_backfilled` flag read `false`: a flag is
/// not an event of the task's kind, so there is nothing to peel (revoke the
/// backfill event itself via `revoke_event` instead). `extra_ids` lists the
/// extras with a live `extra_done` event on the date (sorted, deduplicated);
/// backfill-only extras are likewise excluded.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record, Serialize)]
pub struct RevocableTasks {
    pub diet: bool,
    pub no_junk: bool,
    pub photo: bool,
    pub reading: bool,
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
    /// Which tasks `revoke_task` can currently un-complete on this date
    /// (true = a live event of that kind is attributed here; tasks satisfied
    /// only by a `day_backfilled` flag read false). See [`RevocableTasks`].
    pub revocable: RevocableTasks,
    pub core_complete: bool,
}

#[derive(Debug, Clone, uniffi::Record, Serialize)]
pub struct WeekExtraState {
    pub extra_id: String,
    pub name: String,
    pub cadence: Cadence,
    pub week_index: u32,
    pub done: bool,
    /// The date ("YYYY-MM-DD") whose completion satisfies this extra —
    /// within the current week for weekly cadence, today for daily — or
    /// `None` when open. Prefers a date backed by a live `extra_done` event
    /// over a backfill-flag date, so a toggle-off UI can hand it straight to
    /// `revoke_task` (still check `DayState.revocable.extra_ids` there:
    /// flag-only completions have nothing to revoke).
    pub done_on_date: Option<String>,
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
    /// UNCLAMPED 1-based day number for today: below 1 before `start_date`,
    /// above `length_days` once the challenge window is over (out-of-range
    /// days still attribute and hold live events — docs/ARCHITECTURE.md).
    /// This is the honest "days lived" figure destructive-flow copy must
    /// use; `today_day_index` stays clamped for display ("Day 75 of 75").
    pub today_raw_day_index: i64,
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
    /// Set only by `revoke_task(_, Photo, _)`: the `photo_ref`s of every
    /// revoked photo event that carried one (a date can accumulate several
    /// live photo events — e.g. "mark taken" then "attach"), so the app
    /// layer can delete the now-orphaned image files. Always empty on plain
    /// logs and on non-photo revocations.
    pub revoked_photo_refs: Vec<String>,
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
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
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

    /// `now` stamps the presets config-LWW slot (docs/PHASE2.md): presets are
    /// config, not events, and sync last-writer-wins on this timestamp.
    pub fn update_presets(
        &self,
        presets: Vec<ContainerPreset>,
        now: LocalInstant,
    ) -> Result<(), DromeError> {
        now.wall_secs()?;
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
        // IMMEDIATE transaction around the active-challenge read AND the
        // writes: another process (the widget shares this DB) could commit a
        // `reset_all_data` between a bare read and the inserts, orphaning
        // rows under a deleted challenge id. Same pattern in every
        // check-then-write path below.
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let challenge = require_active(&tx)?;
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
        sync::touch_config_slot(&tx, sync::SLOT_PRESETS, now)?;
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

    /// `now` stamps the extras config-LWW slot (docs/PHASE2.md).
    pub fn set_extra_enabled(
        &self,
        extra_id: String,
        enabled: bool,
        now: LocalInstant,
    ) -> Result<(), DromeError> {
        now.wall_secs()?;
        let mut conn = self.lock()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let challenge = require_active(&tx)?;
        let changed = tx.execute(
            "UPDATE extra_defs SET enabled = ?1 WHERE challenge_id = ?2 AND id = ?3",
            params![enabled, challenge.id, extra_id],
        )?;
        if changed == 0 {
            return Err(DromeError::UnknownExtra(extra_id));
        }
        sync::touch_config_slot(&tx, sync::SLOT_EXTRAS, now)?;
        tx.commit()?;
        Ok(())
    }

    pub fn extra_defs(&self) -> Result<Vec<ExtraDef>, DromeError> {
        let conn = self.lock()?;
        let challenge = require_active(&conn)?;
        load_extra_defs(&conn, &challenge.id)
    }

    /// `now` stamps the challenge config-LWW slot (the book lives on the
    /// challenge row — docs/PHASE2.md).
    pub fn set_current_book(&self, title: String, now: LocalInstant) -> Result<(), DromeError> {
        now.wall_secs()?;
        let mut conn = self.lock()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let challenge = require_active(&tx)?;
        let book = if title.trim().is_empty() {
            None
        } else {
            Some(title)
        };
        tx.execute(
            "UPDATE challenge SET current_book = ?1 WHERE id = ?2",
            params![book, challenge.id],
        )?;
        sync::touch_config_slot(&tx, sync::SLOT_CHALLENGE, now)?;
        tx.commit()?;
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
        let mut conn = self.lock()?;
        // Atomic check-then-insert (see update_presets): a goal event must
        // never land under a challenge a concurrent reset just deleted.
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let challenge = require_active(&tx)?;
        insert_event(
            &tx,
            &challenge.id,
            now,
            None,
            events::KIND_GOAL_CHANGED,
            &json!({ "water_goal_ml": ml }),
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Display-only config; safe to edit mid-challenge. `now` stamps the
    /// challenge config-LWW slot (docs/PHASE2.md).
    pub fn set_diet_description(&self, desc: String, now: LocalInstant) -> Result<(), DromeError> {
        now.wall_secs()?;
        let trimmed = desc.trim();
        if trimmed.chars().count() > 500 {
            return Err(DromeError::InvalidArgument(
                "diet description is capped at 500 characters".into(),
            ));
        }
        let mut conn = self.lock()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let challenge = require_active(&tx)?;
        let value = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_owned())
        };
        tx.execute(
            "UPDATE challenge SET diet_description = ?1 WHERE id = ?2",
            params![value, challenge.id],
        )?;
        sync::touch_config_slot(&tx, sync::SLOT_CHALLENGE, now)?;
        tx.commit()?;
        Ok(())
    }

    /// The waking window only drives WaterState pacing and the
    /// discourage_catch_up display — never day attribution or completion — so
    /// editing it mid-challenge is a plain config update, not an event.
    pub fn set_waking_window(
        &self,
        start_minutes: u16,
        end_minutes: u16,
        now: LocalInstant,
    ) -> Result<(), DromeError> {
        // Same bounds as create_challenge/import (validate_challenge_config):
        // end == 1440 (midnight) is a valid window end for the pacing math.
        if start_minutes >= end_minutes || end_minutes > 1_440 {
            return Err(DromeError::InvalidArgument(
                "waking window must satisfy 0 <= start < end <= 1440".into(),
            ));
        }
        now.wall_secs()?;
        let mut conn = self.lock()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let challenge = require_active(&tx)?;
        tx.execute(
            "UPDATE challenge SET waking_start_minutes = ?1, waking_end_minutes = ?2
             WHERE id = ?3",
            params![start_minutes, end_minutes, challenge.id],
        )?;
        sync::touch_config_slot(&tx, sync::SLOT_CHALLENGE, now)?;
        tx.commit()?;
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
        let mut conn = self.lock()?;
        // Atomic check-then-insert (see update_presets).
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let challenge = require_active(&tx)?;
        insert_event(
            &tx,
            &challenge.id,
            now,
            None,
            events::KIND_DAY_CLOSED,
            &json!({ "date": date }),
        )?;
        let loaded = load(&tx)?;
        tx.commit()?;
        Ok(loaded.projection.day_state(parsed))
    }

    pub fn revoke_event(&self, event_uuid: String, now: LocalInstant) -> Result<(), DromeError> {
        now.wall_secs()?;
        let mut conn = self.lock()?;
        // Atomic check-then-insert (see update_presets).
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let challenge = require_active(&tx)?;
        let kind: Option<String> = tx
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
            &tx,
            &challenge.id,
            now,
            None,
            events::KIND_REVOKED,
            &json!({ "event_uuid": event_uuid }),
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Un-completes a task on `date` — attribution identical to `day_state`
    /// (cutoff, closed-day rollover, explicit `effective_date`). The attest
    /// kinds (`Diet`, `NoJunk`, `Photo`, `Extra`) are idempotent, not
    /// additive: ALL their live (non-revoked) events attributed to the date
    /// are revoked in one transaction, so a single call always flips the
    /// task to not-done (a date can honestly hold several — e.g. "mark
    /// photo taken" then attach a picture). `Reading` is additive and peels
    /// only the NEWEST entry and its pages (older entries remain); `Extra`
    /// matches its `id` against `extra_done` events.
    ///
    /// The returned `LogResult` carries the fresh `day_state`;
    /// `day_became_complete` and `week_extra_became_complete` are hard-false
    /// (a revoke only removes satisfaction — the completion/weekly moments
    /// then fire again, INTENTIONALLY, on the future log that re-completes
    /// the day/week: that log is a genuine incomplete -> complete flip).
    /// `revoked_photo_refs` carries every revoked photo event's ref so the
    /// app layer can delete the orphaned image files. `event_uuid` is the
    /// last appended `revoked` event's uuid.
    ///
    /// Errors with `TaskNotRevocable` when no live event of `kind` is
    /// attributed to `date` — e.g. the task is satisfied only by a
    /// `day_backfilled` flag (flags are not peelable events; revoke the
    /// backfill itself via `revoke_event`), or nothing was logged.
    /// `DayState.revocable` reports, per task, whether this call would
    /// succeed.
    pub fn revoke_task(
        &self,
        date: String,
        kind: RevocableTask,
        now: LocalInstant,
    ) -> Result<LogResult, DromeError> {
        let parsed = time::parse_date(&date)?;
        now.wall_secs()?;
        let mut conn = self.lock()?;
        // One IMMEDIATE transaction spans the projection read, the target
        // walk, and the revocation inserts (see update_presets): the events
        // this call revokes must still exist when the inserts land.
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let loaded = load(&tx)?;
        let proj = &loaded.projection;

        // `loaded.events` is (logged_at_epoch, id) ascending; the reverse
        // walk collects targets newest-first. Payloads are inspected only
        // AFTER the liveness + kind + date filters, so a malformed payload
        // on some other date's event can never poison this revocation.
        let mut targets: Vec<&str> = Vec::new();
        let mut revoked_photo_refs: Vec<String> = Vec::new();
        for e in loaded.events.iter().rev() {
            if proj.is_revoked(&e.uuid) {
                continue;
            }
            let kind_matches = matches!(
                (&kind, e.kind.as_str()),
                (RevocableTask::Diet, events::KIND_DIET_OK)
                    | (RevocableTask::NoJunk, events::KIND_NO_JUNK_OK)
                    | (RevocableTask::Reading, events::KIND_READING)
                    | (RevocableTask::Photo, events::KIND_PHOTO_DONE)
                    | (RevocableTask::Extra { .. }, events::KIND_EXTRA_DONE)
            );
            if !kind_matches || proj.attribute(e.logged_at, e.effective_date.as_deref())? != parsed
            {
                continue;
            }
            match &kind {
                RevocableTask::Extra { id } => {
                    if &e.payload_as::<events::ExtraDonePayload>()?.extra_id != id {
                        continue;
                    }
                }
                RevocableTask::Photo => {
                    if let Some(r) = e.payload_as::<events::PhotoDonePayload>()?.photo_ref {
                        revoked_photo_refs.push(r);
                    }
                }
                _ => {}
            }
            targets.push(&e.uuid);
            if matches!(kind, RevocableTask::Reading) {
                break; // Reading peels one entry per call.
            }
        }
        if targets.is_empty() {
            return Err(DromeError::TaskNotRevocable(format!(
                "no live {} event attributed to {date} (backfill flags and empty days \
                 have nothing to revoke)",
                kind.describe()
            )));
        }

        // Same transaction: the task flips off atomically, never half-peeled.
        let mut event_uuid = String::new();
        for target_uuid in &targets {
            event_uuid = insert_event(
                &tx,
                &loaded.challenge.id,
                now,
                None,
                events::KIND_REVOKED,
                &json!({ "event_uuid": target_uuid }),
            )?;
        }
        let post = load(&tx)?.projection;
        tx.commit()?;
        Ok(LogResult {
            event_uuid,
            day_state: post.day_state(parsed),
            // Hard-false by construction: a revoke can only remove
            // satisfaction, and the moments must never fire from an undo.
            day_became_complete: false,
            week_extra_became_complete: false,
            chug_warning: None,
            revoked_photo_refs,
        })
    }

    /// Inserts one `day_backfilled` event per day, all in a single transaction.
    pub fn backfill_days(
        &self,
        days: Vec<BackfilledDay>,
        now: LocalInstant,
    ) -> Result<(), DromeError> {
        now.wall_secs()?;
        let mut conn = self.lock()?;
        // Atomic check-then-insert (see update_presets): the challenge and
        // extra defs validated here must still exist when the inserts land.
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let challenge = require_active(&tx)?;
        let known_extras: Vec<String> = load_extra_defs(&tx, &challenge.id)?
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
            let (done, done_on_date) = match extra.cadence {
                Cadence::Weekly => {
                    let on = proj.week_extra_done_on(&extra.id, week_idx)?;
                    (on.is_some(), on.map(time::format_date))
                }
                Cadence::Daily => {
                    let done = proj.extra_done_on(&extra.id, date);
                    (done, done.then(|| day.date.clone()))
                }
            };
            week_extras.push(WeekExtraState {
                extra_id: extra.id,
                name: extra.name,
                cadence: extra.cadence,
                week_index: clamp_u32(week_idx, 1),
                done,
                done_on_date,
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
        // Atomic check-then-insert (see update_presets): the no-active /
        // id-free preconditions must hold when the snapshot rows land.
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if load_active_challenge(&tx)?.is_some() {
            return Err(DromeError::ActiveChallengeExists);
        }
        let id_taken: bool = tx.query_row(
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

    /// Wipes EVERYTHING — challenge, events, container presets, extra defs —
    /// returning the store to its never-used state (the Settings "Start
    /// over" flow; the app layer owns photo files and its own flags).
    ///
    /// ONE transaction: drop the events append-only triggers, delete every
    /// row, recreate the identical triggers (same DDL const the schema
    /// uses), commit. A failure at ANY statement rolls the whole thing back,
    /// so the store can never be left half-wiped or with the append-only
    /// guard disarmed. VACUUM afterwards (it cannot run inside a
    /// transaction) is best-effort: shrinking the file must not fail a
    /// reset that already committed.
    pub fn reset_all_data(&self) -> Result<(), DromeError> {
        let mut conn = self.lock()?;
        // IMMEDIATE like every other write path: take the write lock up
        // front so no cross-process writer can slip between our BEGIN and
        // the first DELETE.
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        // IF EXISTS on the drops: if the guard was somehow already missing,
        // the right outcome is still "wipe and re-arm", not an error.
        // Deletion order respects the FK references to challenge(id).
        // Clearing sqlite_sequence restarts event ids — a truly fresh log.
        tx.execute_batch(
            "DROP TRIGGER IF EXISTS events_append_only_update;
             DROP TRIGGER IF EXISTS events_append_only_delete;
             DELETE FROM events;
             DELETE FROM container_presets;
             DELETE FROM extra_defs;
             DELETE FROM challenge;
             DELETE FROM sqlite_sequence WHERE name = 'events';
             -- Phase 2 sync state is tied to the wiped account/challenge
             -- context; clear it too. The device id (sync_device) is ALSO
             -- wiped and re-minted on next use: the server's pull excludes a
             -- device's OWN pushed events (device_id != self), so keeping the
             -- id after wiping the local log would make a re-synced reset
             -- device unable to recover its own history (empty log + same id
             -- => the server never returns it). A fresh id re-pulls everything
             -- (uuid dedup keeps it idempotent), exactly like a reinstall.
             DELETE FROM sync_state;
             DELETE FROM remote_events;
             DELETE FROM config_meta;
             DELETE FROM sync_device;",
        )?;
        // Bump the reset generation in the SAME transaction as the wipe (the
        // sync_epoch row is deliberately NOT among the DELETEs above — it must
        // outlive the wipe). Any sync round-trip that captured the old epoch
        // now finds its tail writes stale: set_last_server_seq /
        // apply_pull_batch / ack_pushed / apply_remote_config become no-ops,
        // so a stale round-trip can never resurrect the pre-reset pull cursor
        // and strand the account's server-held history (docs/PHASE2.md).
        sync::bump_reset_epoch(&tx)?;
        tx.execute_batch(db::APPEND_ONLY_TRIGGERS_SQL)?;
        tx.commit()?;
        let _ = conn.execute_batch("VACUUM");
        Ok(())
    }

    // === Phase 2 sync surface (docs/PHASE2.md "Sync protocol") ============
    //
    // All watermark state is keyed by `context` — an opaque per-account
    // identifier (the server account id) so a device that signs into two
    // accounts keeps independent push/pull cursors. Sync is idempotent event
    // exchange; the projections never sync and recompute on every read.

    /// This store's stable device id (the config-LWW tiebreak; also sent with
    /// sync requests so the server can label event provenance). Minted once
    /// and persisted on first use.
    pub fn device_id(&self) -> Result<String, DromeError> {
        let mut conn = self.lock()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let id = sync::ensure_device_id(&tx)?;
        tx.commit()?;
        Ok(id)
    }

    /// Local events past `context`'s `synced_through` watermark, oldest first,
    /// capped at `limit`, serialized for the wire. Remote-origin events are
    /// never returned (they came FROM the server); `photo_done` payloads have
    /// `photo_ref` stripped at this boundary (the local rows keep theirs).
    pub fn pending_events(
        &self,
        context: String,
        limit: u32,
    ) -> Result<Vec<sync::WireEvent>, DromeError> {
        let conn = self.lock()?;
        sync::pending_events(&conn, &context, limit)
    }

    /// Advances `context`'s push watermark past every acked uuid this store
    /// holds (the new `synced_through` is the max of their local rowids, never
    /// moving backwards). Unknown uuids are ignored.
    ///
    /// `expected_reset_epoch` is the reset generation the round-trip captured
    /// at its start (from `current_reset_epoch`). If a `reset_all_data` ran
    /// since, this is a stale in-flight write: it NO-OPs and returns
    /// `StaleReset` (not an error), so a re-minted post-reset store's
    /// watermark is never dragged forward by a round-trip the reset invalidated
    /// (docs/PHASE2.md, sync/reset epoch invariant).
    pub fn ack_pushed(
        &self,
        context: String,
        uuids: Vec<String>,
        expected_reset_epoch: i64,
    ) -> Result<sync::SyncOutcome, DromeError> {
        let mut conn = self.lock()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if sync::reset_gate(&tx, expected_reset_epoch)? == sync::SyncOutcome::StaleReset {
            return Ok(sync::SyncOutcome::StaleReset);
        }
        sync::ack_pushed(&tx, &context, &uuids)?;
        tx.commit()?;
        Ok(sync::SyncOutcome::Applied)
    }

    /// Idempotent upsert of pulled events: uuids already present (including
    /// revoked ones) are skipped, so replays and self-echoes are no-ops.
    /// Inserted rows are marked remote-origin so `pending_events` never pushes
    /// them back. The whole batch validates first and applies atomically.
    /// Returns the number of events actually inserted.
    pub fn apply_remote_events(&self, events: Vec<sync::WireEvent>) -> Result<u32, DromeError> {
        let mut conn = self.lock()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let inserted = sync::apply_remote_events(&tx, &events)?;
        tx.commit()?;
        Ok(inserted)
    }

    /// This store's current config block (challenge settings, presets, extras)
    /// with per-slot LWW stamps, as JSON — the `config` half of a sync
    /// round-trip. Empty (`{}`) when no challenge is active.
    pub fn export_config_state(&self) -> Result<String, DromeError> {
        let mut conn = self.lock()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let block = sync::export_config_block(&tx)?;
        tx.commit()?;
        serde_json::to_string(&block).map_err(DromeError::from)
    }

    /// Merges a remote config block (JSON from `export_config_state`) per-slot
    /// last-writer-wins on `(updated_at, device_id)`. A winning slot replaces
    /// the local config wholesale and adopts the remote stamp so the merge
    /// converges. Slots for a challenge this store has not seen are skipped
    /// (they land on a later sync, after the challenge arrives).
    ///
    /// `expected_reset_epoch` is the reset generation captured at the round-
    /// trip's start. A stale block (a `reset_all_data` ran since) NO-OPs and
    /// returns `StaleReset` rather than re-materializing the wiped challenge
    /// config on a store the user just started over (docs/PHASE2.md).
    pub fn apply_remote_config(
        &self,
        block_json: String,
        expected_reset_epoch: i64,
    ) -> Result<sync::SyncOutcome, DromeError> {
        let block: sync::ConfigBlock = serde_json::from_str(&block_json)?;
        let mut conn = self.lock()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if sync::reset_gate(&tx, expected_reset_epoch)? == sync::SyncOutcome::StaleReset {
            return Ok(sync::SyncOutcome::StaleReset);
        }
        sync::apply_remote_config_block(&tx, &block)?;
        tx.commit()?;
        Ok(sync::SyncOutcome::Applied)
    }

    /// Adopt the server-declared winner of a one-active-challenge conflict.
    /// Call this INSTEAD of `apply_remote_config` when a sync response carries
    /// `active_challenge_conflict`: `block_json` is that response's `config`
    /// (the winner's slots) and `winner_challenge_id` its
    /// `winner_challenge_id`. Unlike the LWW merge, this force-adopts the
    /// winner's challenge/presets/extras even when the loser's local challenge
    /// stamp is newer, and archives the loser locally — without it a loser
    /// whose challenge was created later keeps its own active challenge forever
    /// (a permanent split-brain the server cannot resolve). Idempotent.
    pub fn adopt_active_challenge(
        &self,
        block_json: String,
        winner_challenge_id: String,
    ) -> Result<(), DromeError> {
        let block: sync::ConfigBlock = serde_json::from_str(&block_json)?;
        let mut conn = self.lock()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        sync::adopt_active_challenge(&tx, &block, &winner_challenge_id)?;
        tx.commit()?;
        Ok(())
    }

    /// This store's current reset generation (docs/PHASE2.md, sync/reset epoch
    /// invariant). The SyncEngine reads this ONCE at the start of a sync
    /// round-trip and passes it back into every cursor-or-state-mutating tail
    /// write (`ack_pushed`, `apply_remote_config`, `set_last_server_seq`,
    /// `apply_pull_batch`); a `reset_all_data` between the capture and the tail
    /// bumps the epoch, so those writes NO-OP (return `StaleReset`) instead of
    /// resurrecting pre-reset sync state. A never-reset store reads 0.
    pub fn current_reset_epoch(&self) -> Result<i64, DromeError> {
        let conn = self.lock()?;
        sync::current_reset_epoch(&conn)
    }

    /// `context`'s pull cursor (the highest `server_seq` this store has
    /// applied). 0 when the context has never pulled.
    pub fn last_server_seq(&self, context: String) -> Result<i64, DromeError> {
        let conn = self.lock()?;
        sync::get_last_server_seq(&conn, &context)
    }

    /// Advances `context`'s pull cursor after applying a pull batch.
    ///
    /// `expected_reset_epoch` is the reset generation captured at the round-
    /// trip's start; a stale advance (a `reset_all_data` ran since) NO-OPs and
    /// returns `StaleReset`. This is the exact write the data-loss race turned
    /// on: without the gate, a stale round-trip re-created `sync_state` with a
    /// pre-reset `last_server_seq`, so later clean pulls (`server_seq > cursor`)
    /// skipped the account's own re-pullable history forever (docs/PHASE2.md).
    pub fn set_last_server_seq(
        &self,
        context: String,
        seq: i64,
        expected_reset_epoch: i64,
    ) -> Result<sync::SyncOutcome, DromeError> {
        let mut conn = self.lock()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if sync::reset_gate(&tx, expected_reset_epoch)? == sync::SyncOutcome::StaleReset {
            return Ok(sync::SyncOutcome::StaleReset);
        }
        sync::set_last_server_seq(&tx, &context, seq)?;
        tx.commit()?;
        Ok(sync::SyncOutcome::Applied)
    }

    /// Applies a pulled batch AND advances `context`'s pull cursor in ONE
    /// transaction, returning the number of events inserted. Prefer this over
    /// separate `apply_remote_events` + `set_last_server_seq` calls: it makes
    /// crash-safety a property of the CORE, not of client call ordering. If the
    /// cursor were advanced in its own transaction, a crash between the two
    /// calls could leave the cursor PAST events that were never durably applied
    /// — the next pull would start after them and silently drop them. Bundling
    /// both writes means the cursor can never outrun the applied events.
    ///
    /// `expected_reset_epoch` is the reset generation captured at the round-
    /// trip's start. When a `reset_all_data` ran since, the WHOLE batch is
    /// dropped — neither the events nor the cursor advance land — and the call
    /// returns `{ StaleReset, inserted: 0 }`. This is the invariant that closes
    /// the reset/sync data-loss race: a re-minted post-reset store re-pulls its
    /// history from `server_seq > 0` on the next clean sync, and no stale tail
    /// can silently push the cursor past it (docs/PHASE2.md).
    pub fn apply_pull_batch(
        &self,
        context: String,
        events: Vec<sync::WireEvent>,
        new_last_server_seq: i64,
        expected_reset_epoch: i64,
    ) -> Result<sync::PullResult, DromeError> {
        let mut conn = self.lock()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if sync::reset_gate(&tx, expected_reset_epoch)? == sync::SyncOutcome::StaleReset {
            return Ok(sync::PullResult {
                outcome: sync::SyncOutcome::StaleReset,
                inserted: 0,
            });
        }
        let inserted = sync::apply_remote_events(&tx, &events)?;
        sync::set_last_server_seq(&tx, &context, new_last_server_seq)?;
        tx.commit()?;
        Ok(sync::PullResult {
            outcome: sync::SyncOutcome::Applied,
            inserted,
        })
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
        let mut conn = self.lock()?;
        // ONE IMMEDIATE transaction spans the precondition read (active
        // challenge + pre projection) and the insert. The widget process
        // shares this WAL DB on its own connection: without the write lock
        // held across both steps, a widget tap whose read saw the challenge
        // could queue its INSERT behind an in-flight `reset_all_data` and
        // land AFTER the wipe — an orphaned event under a deleted challenge
        // id that a later restore would silently adopt. With IMMEDIATE, the
        // racing log instead waits, re-reads, and fails NoActiveChallenge.
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let loaded = load(&tx)?;
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
            &tx,
            &loaded.challenge.id,
            now,
            effective_date.as_deref(),
            kind,
            &payload,
        )?;

        let post = load(&tx)?.projection;
        let post_day = post.day_state(date);
        let day_became_complete = !pre_day.core_complete && post_day.core_complete;
        let week_extra_became_complete = match &week_extra_id {
            Some(id) => !pre_week_done && post.week_extra_done(id, week_idx)?,
            None => false,
        };
        tx.commit()?;

        Ok(LogResult {
            event_uuid,
            day_state: post_day,
            day_became_complete,
            week_extra_became_complete,
            chug_warning,
            // Only revoke_task(Photo) ever fills this.
            revoked_photo_refs: Vec::new(),
        })
    }
}

fn clamp_index(raw: i64, length_days: u32) -> u32 {
    raw.clamp(1, i64::from(length_days.max(1))) as u32
}

fn clamp_u32(raw: i64, min: u32) -> u32 {
    raw.clamp(i64::from(min), i64::from(u32::MAX)) as u32
}

pub(crate) fn validate_challenge_config(
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
        today_raw_day_index: raw_idx,
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

pub(crate) fn load_active_challenge(conn: &Connection) -> Result<Option<Challenge>, DromeError> {
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

pub(crate) fn load_extra_defs(
    conn: &Connection,
    challenge_id: &str,
) -> Result<Vec<ExtraDef>, DromeError> {
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

pub(crate) fn load_presets(
    conn: &Connection,
    challenge_id: &str,
) -> Result<Vec<ContainerPreset>, DromeError> {
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
