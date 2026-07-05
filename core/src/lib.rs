//! drome-core: rules engine, append-only event log, day-boundary math,
//! projections. The pinned contracts live in docs/ARCHITECTURE.md; when this
//! crate and that doc disagree, the doc wins.

uniffi::setup_scaffolding!();

pub mod api;
pub mod db;
pub mod error;
pub mod events;
pub mod export;
pub mod projections;
pub mod rules;
pub mod time;
pub mod water;

#[cfg(test)]
mod proptests;

pub use api::{
    BackfilledDay, Cadence, Challenge, ChallengeSummary, ContainerPreset, DayBrief, DayState,
    DromeStore, ExtraDef, LogResult, NewChallenge, ShareCardData, ShareCardWorkout, TodayState,
    WaterLogEntry, WeekExtraState, WorkoutEntry, DEFAULT_CHALLENGE_LENGTH_DAYS, JOB_EXTRA_ID,
    JOB_EXTRA_NAME,
};
pub use error::DromeError;
pub use rules::RulesetKind;
pub use time::LocalInstant;
pub use water::{ChugCheck, WaterState};
