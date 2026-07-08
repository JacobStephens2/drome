//! Event kinds and payload shapes (docs/ARCHITECTURE.md, "Event schema").

use serde::{Deserialize, Serialize};

use crate::error::{DromeError, Result};
use crate::time::LocalInstant;

pub const KIND_WATER_ADD: &str = "water_add";
pub const KIND_WATER_ADJUST: &str = "water_adjust";
pub const KIND_WORKOUT: &str = "workout";
pub const KIND_READING: &str = "reading";
pub const KIND_DIET_OK: &str = "diet_ok";
pub const KIND_NO_JUNK_OK: &str = "no_junk_ok";
pub const KIND_PHOTO_DONE: &str = "photo_done";
pub const KIND_EXTRA_DONE: &str = "extra_done";
pub const KIND_DAY_CLOSED: &str = "day_closed";
pub const KIND_DAY_BACKFILLED: &str = "day_backfilled";
pub const KIND_GOAL_CHANGED: &str = "goal_changed";
pub const KIND_CUTOFF_CHANGED: &str = "cutoff_changed";
pub const KIND_REVOKED: &str = "revoked";

pub const KNOWN_KINDS: &[&str] = &[
    KIND_WATER_ADD,
    KIND_WATER_ADJUST,
    KIND_WORKOUT,
    KIND_READING,
    KIND_DIET_OK,
    KIND_NO_JUNK_OK,
    KIND_PHOTO_DONE,
    KIND_EXTRA_DONE,
    KIND_DAY_CLOSED,
    KIND_DAY_BACKFILLED,
    KIND_GOAL_CHANGED,
    KIND_CUTOFF_CHANGED,
    KIND_REVOKED,
];

pub fn is_known_kind(kind: &str) -> bool {
    KNOWN_KINDS.contains(&kind)
}

/// Event-log dialect versions, stamped per row in the `schema_version`
/// column:
/// - 1: the original five-task era — `no_junk_ok` and `water_adjust` did
///   not exist yet.
/// - 2: the six-task era ("No Junk or Alcohol" is a core task; signed water
///   corrections exist).
///
/// The projection reads the earliest v2 row's logged date as the no-junk
/// feature boundary: days lived strictly before it inherit `diet_done`
/// (`Projection::day_state`), the live-log twin of the backfill fallback in
/// [`DayBackfilledPayload::no_junk_effective`]. Exports carry the version and
/// imports preserve it, so restored legacy stores keep the honest reading.
pub const SIX_TASK_SCHEMA_VERSION: i64 = 2;

/// What this build stamps on every event row it writes.
pub const EVENT_SCHEMA_VERSION: i64 = SIX_TASK_SCHEMA_VERSION;

#[derive(Debug, Serialize, Deserialize)]
pub struct WaterAddPayload {
    pub ml: i64,
}

/// A signed water correction. Always NEGATIVE (`-10_000..=-1`): positive
/// intake stays `water_add`, so the ledger keeps an honest add-vs-correct
/// distinction instead of mixing signs inside one kind.
#[derive(Debug, Serialize, Deserialize)]
pub struct WaterAdjustPayload {
    pub ml: i64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct WorkoutPayload {
    pub duration_min: u32,
    pub outdoor: bool,
    pub note: Option<String>,
    pub started_at: Option<LocalInstant>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ReadingPayload {
    pub book_title: String,
    pub pages: u32,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PhotoDonePayload {
    pub photo_ref: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ExtraDonePayload {
    pub extra_id: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct DayClosedPayload {
    pub date: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct DayBackfilledPayload {
    pub date: String,
    pub water: bool,
    pub outdoor_workout: bool,
    pub second_workout: bool,
    pub reading: bool,
    pub diet: bool,
    /// `None` on payloads written before the no-junk task existed (older
    /// stores and imported legacy snapshots lack the key). Never read this
    /// directly — resolve through [`Self::no_junk_effective`].
    #[serde(default)]
    pub no_junk: Option<bool>,
    pub photo: bool,
    pub extra_ids: Vec<String>,
}

impl DayBackfilledPayload {
    /// LEGACY DEFAULT: a payload missing the `no_junk` key inherits the day's
    /// `diet` flag. The user's spreadsheet tracked "Nutrition/Diet" and
    /// "No Junk or Alcohol" as separate columns that were always kept equal,
    /// so equating them is the honest reading of pre-no-junk history.
    pub fn no_junk_effective(&self) -> bool {
        self.no_junk.unwrap_or(self.diet)
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct GoalChangedPayload {
    pub water_goal_ml: i64,
}

/// A day-cutoff change. Unlike the goal, the cutoff decides which DAY a live
/// log lands on, so the projection applies it forward-only: it is keyed by the
/// change's own `logged_at` instant, and each event is attributed under the
/// cutoff in effect when it was logged. Past days keep the boundary they were
/// lived under; only later logs use the new cutoff.
#[derive(Debug, Serialize, Deserialize)]
pub struct CutoffChangedPayload {
    pub day_cutoff_minutes: u32,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct RevokedPayload {
    pub event_uuid: String,
}

/// A raw row from the `events` table.
#[derive(Debug, Clone, Serialize)]
pub struct EventRow {
    pub id: i64,
    pub uuid: String,
    pub challenge_id: String,
    pub logged_at: LocalInstant,
    pub effective_date: Option<String>,
    pub kind: String,
    pub payload: serde_json::Value,
    pub schema_version: i64,
}

impl EventRow {
    pub fn payload_as<T: serde::de::DeserializeOwned>(&self) -> Result<T> {
        serde_json::from_value(self.payload.clone()).map_err(DromeError::from)
    }
}
