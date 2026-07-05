//! Event kinds and payload shapes (docs/ARCHITECTURE.md, "Event schema").

use serde::{Deserialize, Serialize};

use crate::error::{DromeError, Result};
use crate::time::LocalInstant;

pub const KIND_WATER_ADD: &str = "water_add";
pub const KIND_WORKOUT: &str = "workout";
pub const KIND_READING: &str = "reading";
pub const KIND_DIET_OK: &str = "diet_ok";
pub const KIND_PHOTO_DONE: &str = "photo_done";
pub const KIND_EXTRA_DONE: &str = "extra_done";
pub const KIND_DAY_CLOSED: &str = "day_closed";
pub const KIND_DAY_BACKFILLED: &str = "day_backfilled";
pub const KIND_GOAL_CHANGED: &str = "goal_changed";
pub const KIND_REVOKED: &str = "revoked";

pub const KNOWN_KINDS: &[&str] = &[
    KIND_WATER_ADD,
    KIND_WORKOUT,
    KIND_READING,
    KIND_DIET_OK,
    KIND_PHOTO_DONE,
    KIND_EXTRA_DONE,
    KIND_DAY_CLOSED,
    KIND_DAY_BACKFILLED,
    KIND_GOAL_CHANGED,
    KIND_REVOKED,
];

pub fn is_known_kind(kind: &str) -> bool {
    KNOWN_KINDS.contains(&kind)
}

#[derive(Debug, Serialize, Deserialize)]
pub struct WaterAddPayload {
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
    pub photo: bool,
    pub extra_ids: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct GoalChangedPayload {
    pub water_goal_ml: i64,
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
