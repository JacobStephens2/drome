//! User-initiated exports (full JSON, day-per-row CSV mirroring my sister's
//! spreadsheet) and the matching `import_json` snapshot parser — the
//! reinstall/restore path.

use std::collections::HashSet;

use serde::Deserialize;
use serde_json::json;

use crate::api::{
    Challenge, ChallengeSummary, ContainerPreset, ExtraDef, JOB_EXTRA_ID, MAX_READING_PAGES,
    MAX_WATER_GOAL_ML, MAX_WATER_LOG_ML, MAX_WORKOUT_DURATION_MIN,
};
use crate::error::{DromeError, Result};
use crate::events::{
    self, EventRow, GoalChangedPayload, PhotoDonePayload, ReadingPayload, WaterAddPayload,
    WaterAdjustPayload, WorkoutPayload,
};
use crate::projections::Projection;
use crate::time::{self, LocalInstant};

pub const EXPORT_SCHEMA_VERSION: u32 = 1;
const ML_PER_FL_OZ: f64 = 29.5735;

/// The importable subset of an `export_json` document. `days` and `summary`
/// are projections and deliberately ignored: they are rebuilt from the log.
#[derive(Debug, Deserialize)]
pub struct Snapshot {
    pub export_schema_version: u32,
    pub challenge: Challenge,
    #[serde(default)]
    pub container_presets: Vec<ContainerPreset>,
    #[serde(default)]
    pub extra_defs: Vec<ExtraDef>,
    pub events: Vec<SnapshotEvent>,
}

#[derive(Debug, Deserialize)]
pub struct SnapshotEvent {
    pub uuid: String,
    pub logged_at_epoch: i64,
    pub tz_offset_secs: i32,
    #[serde(default)]
    pub effective_date: Option<String>,
    pub kind: String,
    pub payload: serde_json::Value,
    #[serde(default = "default_event_schema_version")]
    pub schema_version: i64,
}

fn default_event_schema_version() -> i64 {
    1
}

pub fn parse_snapshot(json: &str) -> Result<Snapshot> {
    let snap: Snapshot = serde_json::from_str(json)?;
    if snap.export_schema_version != EXPORT_SCHEMA_VERSION {
        return Err(DromeError::InvalidArgument(format!(
            "unsupported export schema version {} (expected {EXPORT_SCHEMA_VERSION})",
            snap.export_schema_version
        )));
    }
    for e in &snap.events {
        if e.uuid.trim().is_empty() {
            return Err(DromeError::InvalidArgument(
                "snapshot event with empty uuid".into(),
            ));
        }
        if !events::is_known_kind(&e.kind) {
            return Err(DromeError::InvalidArgument(format!(
                "snapshot event {} has unknown kind {:?}",
                e.uuid, e.kind
            )));
        }
        if let Some(date) = &e.effective_date {
            time::parse_date(date)?;
        }
        validate_payload_bounds(e)?;
    }
    Ok(snap)
}

/// Imported payloads must satisfy the same bounds the log_* APIs enforce
/// (the shared constants in `api`). Without this, a hand-edited snapshot can
/// smuggle in values the app could never have written — e.g. a `goal_changed`
/// of 0 silently auto-completes water for every later day.
fn validate_payload_bounds(e: &SnapshotEvent) -> Result<()> {
    validate_event_payload(&e.uuid, &e.kind, &e.payload)
}

/// Payload-bounds validation for a single event, shared by the import path
/// (`validate_payload_bounds`) and the Phase 2 sync ingest
/// (`sync::validate_wire_event`) so a synced event can never smuggle in a
/// value the local log APIs would reject. `id` names the event in errors.
pub fn validate_event_payload(id: &str, kind: &str, payload: &serde_json::Value) -> Result<()> {
    match kind {
        events::KIND_WATER_ADD => {
            let p: WaterAddPayload = serde_json::from_value(payload.clone())?;
            if !(1..=MAX_WATER_LOG_ML).contains(&p.ml) {
                return Err(DromeError::InvalidArgument(format!(
                    "event {id}: water ml must be in 1..={MAX_WATER_LOG_ML}"
                )));
            }
        }
        events::KIND_WATER_ADJUST => {
            let p: WaterAdjustPayload = serde_json::from_value(payload.clone())?;
            if !(-MAX_WATER_LOG_ML..=-1).contains(&p.ml) {
                return Err(DromeError::InvalidArgument(format!(
                    "event {id}: water adjustment ml must be in -{MAX_WATER_LOG_ML}..=-1"
                )));
            }
        }
        events::KIND_GOAL_CHANGED => {
            let p: GoalChangedPayload = serde_json::from_value(payload.clone())?;
            if !(1..=MAX_WATER_GOAL_ML).contains(&p.water_goal_ml) {
                return Err(DromeError::InvalidArgument(format!(
                    "event {id}: water goal ml must be in 1..={MAX_WATER_GOAL_ML}"
                )));
            }
        }
        events::KIND_WORKOUT => {
            let p: WorkoutPayload = serde_json::from_value(payload.clone())?;
            if p.duration_min == 0 || p.duration_min > MAX_WORKOUT_DURATION_MIN {
                return Err(DromeError::InvalidArgument(format!(
                    "event {id}: workout duration_min must be in 1..={MAX_WORKOUT_DURATION_MIN}"
                )));
            }
        }
        events::KIND_READING => {
            let p: ReadingPayload = serde_json::from_value(payload.clone())?;
            if p.pages == 0 || p.pages > MAX_READING_PAGES {
                return Err(DromeError::InvalidArgument(format!(
                    "event {id}: pages must be in 1..={MAX_READING_PAGES}"
                )));
            }
        }
        events::KIND_PHOTO_DONE => {
            // Structural check only (the ref is an opaque string or null).
            // Projection::build never parses this payload — it just flips
            // the day's photo flag — so the pre-import projection pass
            // cannot catch a malformed ref, but `revoke_task(_, Photo, _)`
            // parses it later; without this arm a hand-edited snapshot
            // could make the photo toggle-off fail with a raw storage error.
            serde_json::from_value::<PhotoDonePayload>(payload.clone()).map_err(|err| {
                DromeError::InvalidArgument(format!(
                    "event {id}: malformed photo_done payload: {err}"
                ))
            })?;
        }
        // day_backfilled payloads (flags only) are structurally validated by
        // the pre-import Projection::build pass; a payload missing the
        // `no_junk` key stays importable and inherits the day's `diet` flag
        // (the legacy default — see events::DayBackfilledPayload).
        _ => {}
    }
    Ok(())
}

impl Snapshot {
    /// Rows for projection validation, in array order (the export order). The
    /// synthetic ids preserve that order for same-instant tie-breaking, exactly
    /// like fresh AUTOINCREMENT ids will after insertion.
    pub fn event_rows(&self) -> Vec<EventRow> {
        self.events
            .iter()
            .enumerate()
            .map(|(i, e)| EventRow {
                id: i as i64 + 1,
                uuid: e.uuid.clone(),
                challenge_id: self.challenge.id.clone(),
                logged_at: LocalInstant {
                    epoch_secs: e.logged_at_epoch,
                    tz_offset_secs: e.tz_offset_secs,
                },
                effective_date: e.effective_date.clone(),
                kind: e.kind.clone(),
                payload: e.payload.clone(),
                schema_version: e.schema_version,
            })
            .collect()
    }
}

/// Days 1..=N where N is today's day index clamped into the challenge range
/// (nothing before day 1, nothing past the end, no empty future rows).
fn exported_day_count(proj: &Projection, now: LocalInstant) -> Result<i64> {
    let today = proj.attribute(now, None)?;
    let idx = time::day_index(proj.start_date(), today);
    Ok(idx.clamp(0, i64::from(proj.length_days())))
}

#[allow(clippy::too_many_arguments)]
pub fn export_json(
    challenge: &Challenge,
    presets: &[ContainerPreset],
    extras: &[ExtraDef],
    events: &[EventRow],
    proj: &Projection,
    summary: &ChallengeSummary,
    now: LocalInstant,
) -> Result<String> {
    let revoked: HashSet<&str> = events
        .iter()
        .filter(|e| e.kind == events::KIND_REVOKED)
        .filter_map(|e| e.payload.get("event_uuid").and_then(|v| v.as_str()))
        .collect();

    let event_values: Vec<serde_json::Value> = events
        .iter()
        .map(|e| {
            json!({
                "id": e.id,
                "uuid": e.uuid,
                "logged_at_epoch": e.logged_at.epoch_secs,
                "tz_offset_secs": e.logged_at.tz_offset_secs,
                "effective_date": e.effective_date,
                "kind": e.kind,
                "payload": e.payload,
                "schema_version": e.schema_version,
                "revoked": revoked.contains(e.uuid.as_str()),
            })
        })
        .collect();

    let mut days = Vec::new();
    for idx in 1..=exported_day_count(proj, now)? {
        days.push(proj.day_state(proj.date_at_index(idx)?));
    }

    let doc = json!({
        "export_schema_version": EXPORT_SCHEMA_VERSION,
        "exported_at": now,
        "challenge": challenge,
        "container_presets": presets,
        "extra_defs": extras,
        "events": event_values,
        "days": days,
        "summary": summary,
    });
    serde_json::to_string_pretty(&doc).map_err(DromeError::from)
}

/// Column layout mirrors the user's tracking spreadsheet; booleans are
/// TRUE/FALSE like a Google Sheets checkbox export.
pub fn export_csv(proj: &Projection, now: LocalInstant) -> Result<String> {
    let mut out = String::from(
        "Date,Day,Workout (Outside),Workout (Inside),Nutrition/Diet,No Junk or Alcohol,\
         Read (10 Pages),Progress Picture,Water (oz),Apply to 1 job/week,Complete\n",
    );
    for idx in 1..=exported_day_count(proj, now)? {
        let date = proj.date_at_index(idx)?;
        let day = proj.day_state(date);
        let job = if proj.extra_done_on(JOB_EXTRA_ID, date) {
            "TRUE"
        } else {
            ""
        };
        let oz = (day.water_ml as f64 / ML_PER_FL_OZ).round() as i64;
        out.push_str(&format!(
            "{},{},{},{},{},{},{},{},{},{},{}\n",
            day.date,
            idx,
            csv_bool(day.outdoor_workout_done),
            csv_bool(day.second_workout_done),
            csv_bool(day.diet_done),
            csv_bool(day.no_junk_done),
            csv_bool(day.reading_done),
            csv_bool(day.photo_done),
            oz,
            job,
            csv_bool(day.core_complete),
        ));
    }
    Ok(out)
}

fn csv_bool(b: bool) -> &'static str {
    if b {
        "TRUE"
    } else {
        "FALSE"
    }
}
