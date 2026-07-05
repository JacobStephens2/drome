//! Ruleset abstraction (docs/ARCHITECTURE.md, "Flexible-mode day completion").
//! Flexible is fully implemented; Purist implements only what is cheap in the
//! core (workout duration/spacing, fixed gallon goal) and has no other surface.

use serde::{Deserialize, Serialize};

use crate::api::WorkoutEntry;

pub const PURIST_WATER_GOAL_ML: i64 = 3_785;
pub const READING_PAGES_TARGET: u32 = 10;
const PURIST_WORKOUT_MIN: u32 = 45;
const PURIST_GAP_SECS: i64 = 3 * 3_600;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RulesetKind {
    Flexible,
    Purist,
}

impl RulesetKind {
    pub fn label(self) -> &'static str {
        match self {
            RulesetKind::Flexible => "flexible",
            RulesetKind::Purist => "purist",
        }
    }

    pub fn from_label(s: &str) -> Option<Self> {
        match s {
            "flexible" => Some(RulesetKind::Flexible),
            "purist" => Some(RulesetKind::Purist),
            _ => None,
        }
    }

    /// The water goal a day is judged against. Purist is a fixed gallon;
    /// flexible uses the goal in effect as of that day.
    pub fn water_goal_ml(self, goal_as_of_day: i64) -> i64 {
        match self {
            RulesetKind::Flexible => goal_as_of_day,
            RulesetKind::Purist => PURIST_WATER_GOAL_ML,
        }
    }

    /// (outdoor slot done, second slot done) for a day's workouts.
    pub fn workouts_satisfied(self, workouts: &[WorkoutEntry]) -> (bool, bool) {
        match self {
            RulesetKind::Flexible => {
                let outdoor = workouts.iter().any(|w| w.outdoor);
                (outdoor, workouts.len() >= 2)
            }
            RulesetKind::Purist => {
                let qualifying: Vec<&WorkoutEntry> = workouts
                    .iter()
                    .filter(|w| w.duration_min >= PURIST_WORKOUT_MIN)
                    .collect();
                let outdoor = qualifying.iter().any(|w| w.outdoor);
                let second = qualifying.len() >= 2 && purist_gap_ok(&qualifying);
                (outdoor, second)
            }
        }
    }
}

/// The >=3h spacing rule, enforced only when at least two qualifying workouts
/// carry start times ("when start times present" — self-reported logs without
/// them are taken at their word).
fn purist_gap_ok(qualifying: &[&WorkoutEntry]) -> bool {
    let starts: Vec<i64> = qualifying
        .iter()
        .filter_map(|w| w.started_at.map(|s| s.epoch_secs))
        .collect();
    if starts.len() < 2 {
        return true;
    }
    let min = starts.iter().min().copied().unwrap_or(0);
    let max = starts.iter().max().copied().unwrap_or(0);
    max.saturating_sub(min) >= PURIST_GAP_SECS
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time::LocalInstant;

    fn workout(duration_min: u32, outdoor: bool, started_epoch: Option<i64>) -> WorkoutEntry {
        WorkoutEntry {
            event_uuid: String::new(),
            duration_min,
            outdoor,
            note: None,
            started_at: started_epoch.map(|epoch_secs| LocalInstant {
                epoch_secs,
                tz_offset_secs: 0,
            }),
        }
    }

    #[test]
    fn flexible_any_duration_counts() {
        let ws = [workout(5, true, None), workout(1, false, None)];
        assert_eq!(RulesetKind::Flexible.workouts_satisfied(&ws), (true, true));
        let one_indoor = [workout(90, false, None)];
        assert_eq!(
            RulesetKind::Flexible.workouts_satisfied(&one_indoor),
            (false, false)
        );
    }

    #[test]
    fn purist_requires_45_minutes() {
        let ws = [workout(44, true, None), workout(45, false, None)];
        assert_eq!(RulesetKind::Purist.workouts_satisfied(&ws), (false, false));
        let ws = [workout(45, true, None), workout(60, false, None)];
        assert_eq!(RulesetKind::Purist.workouts_satisfied(&ws), (true, true));
    }

    #[test]
    fn purist_gap_enforced_only_with_start_times() {
        // Both start times present, 2h apart: too close.
        let close = [
            workout(45, true, Some(1_000)),
            workout(45, false, Some(1_000 + 2 * 3_600)),
        ];
        assert_eq!(
            RulesetKind::Purist.workouts_satisfied(&close),
            (true, false)
        );
        // 3h apart: fine.
        let spaced = [
            workout(45, true, Some(1_000)),
            workout(45, false, Some(1_000 + 3 * 3_600)),
        ];
        assert_eq!(
            RulesetKind::Purist.workouts_satisfied(&spaced),
            (true, true)
        );
        // Only one start time: gap not enforceable, taken at their word.
        let partial = [workout(45, true, Some(1_000)), workout(45, false, None)];
        assert_eq!(
            RulesetKind::Purist.workouts_satisfied(&partial),
            (true, true)
        );
    }

    #[test]
    fn purist_water_goal_is_fixed() {
        assert_eq!(
            RulesetKind::Purist.water_goal_ml(2_000),
            PURIST_WATER_GOAL_ML
        );
        assert_eq!(RulesetKind::Flexible.water_goal_ml(2_000), 2_000);
    }

    #[test]
    fn labels_roundtrip() {
        for kind in [RulesetKind::Flexible, RulesetKind::Purist] {
            assert_eq!(RulesetKind::from_label(kind.label()), Some(kind));
        }
        assert_eq!(RulesetKind::from_label("strict"), None);
    }
}
