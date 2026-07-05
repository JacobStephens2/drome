//! Water pacing and the anti-chug safety guard
//! (docs/ARCHITECTURE.md, "Water pacing & safety"). Ships in every mode.

use serde::{Deserialize, Serialize};

pub const ON_PACE_SLACK_ML: i64 = 250;
pub const FINAL_OUNCE_ML: i64 = 150;
pub const CATCH_UP_WINDOW_MIN: i64 = 90;
pub const CATCH_UP_REMAINING_ML: i64 = 1_000;
pub const CHUG_WINDOW_SECS: i64 = 3_600;
pub const CHUG_THRESHOLD_ML: i64 = 1_000;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record, Serialize, Deserialize)]
pub struct WaterState {
    pub total_ml: i64,
    pub goal_ml: i64,
    pub remaining_ml: i64,
    pub pace_target_ml: i64,
    pub on_pace: bool,
    pub final_ounce: bool,
    pub discourage_catch_up: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record, Serialize, Deserialize)]
pub struct ChugCheck {
    pub warn: bool,
    pub trailing_60min_ml: i64,
    pub add_ml: i64,
    pub threshold_ml: i64,
}

/// Pure pacing math. `minutes_into_day` is relative to the *attributed* day's
/// local midnight, so a 1:30 AM check-in on a still-open day reads as minute
/// 1530 and the whole waking window counts as elapsed.
pub fn compute_water_state(
    total_ml: i64,
    goal_ml: i64,
    minutes_into_day: i64,
    waking_start_minutes: u32,
    waking_end_minutes: u32,
) -> WaterState {
    let start = i64::from(waking_start_minutes);
    let end = i64::from(waking_end_minutes);
    let window = (end - start).max(1);
    let elapsed = (minutes_into_day - start).clamp(0, window);
    let pace_target_ml = goal_ml
        .saturating_mul(elapsed)
        .checked_div(window)
        .unwrap_or(0)
        .clamp(0, goal_ml.max(0));

    let remaining_ml = (goal_ml - total_ml).max(0);
    WaterState {
        total_ml,
        goal_ml,
        remaining_ml,
        pace_target_ml,
        on_pace: total_ml >= pace_target_ml.saturating_sub(ON_PACE_SLACK_ML),
        final_ounce: remaining_ml > 0 && remaining_ml <= FINAL_OUNCE_ML,
        discourage_catch_up: minutes_into_day >= end - CATCH_UP_WINDOW_MIN
            && remaining_ml > CATCH_UP_REMAINING_ML,
    }
}

/// Sum of water logged in the trailing 60 minutes: `(epoch_secs, ml)` pairs
/// with `now - 60min < epoch <= now`.
pub fn trailing_hour_ml(water_events: &[(i64, i64)], now_epoch: i64) -> i64 {
    let window_start = now_epoch.saturating_sub(CHUG_WINDOW_SECS);
    water_events
        .iter()
        .filter(|(epoch, _)| *epoch > window_start && *epoch <= now_epoch)
        .map(|(_, ml)| *ml)
        .fold(0i64, i64::saturating_add)
}

pub fn check_chug(trailing_60min_ml: i64, add_ml: i64) -> ChugCheck {
    ChugCheck {
        warn: trailing_60min_ml.saturating_add(add_ml) > CHUG_THRESHOLD_ML,
        trailing_60min_ml,
        add_ml,
        threshold_ml: CHUG_THRESHOLD_ML,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Defaults from the architecture doc: waking 7:00–22:00, gallon goal.
    const START: u32 = 420;
    const END: u32 = 1320;
    const GOAL: i64 = 3_785;

    #[test]
    fn pace_is_zero_before_waking_start() {
        let s = compute_water_state(0, GOAL, 300, START, END);
        assert_eq!(s.pace_target_ml, 0);
        assert!(s.on_pace);
    }

    #[test]
    fn pace_is_half_goal_mid_window() {
        let s = compute_water_state(0, GOAL, (420 + 1320) / 2, START, END);
        assert_eq!(s.pace_target_ml, GOAL / 2);
        assert!(!s.on_pace);
    }

    #[test]
    fn pace_is_full_goal_after_waking_end() {
        for minutes in [1320, 1400, 1530] {
            let s = compute_water_state(0, GOAL, minutes, START, END);
            assert_eq!(s.pace_target_ml, GOAL);
        }
    }

    #[test]
    fn on_pace_allows_250ml_slack() {
        let s = compute_water_state(GOAL - 250, GOAL, END.into(), START, END);
        assert!(s.on_pace);
        let s = compute_water_state(GOAL - 251, GOAL, END.into(), START, END);
        assert!(!s.on_pace);
    }

    #[test]
    fn final_ounce_band() {
        for (total, expected) in [
            (GOAL, false),       // remaining 0: done, not "final ounce"
            (GOAL - 1, true),    // remaining 1
            (GOAL - 150, true),  // remaining 150 (boundary)
            (GOAL - 151, false), // remaining 151
        ] {
            let s = compute_water_state(total, GOAL, 800, START, END);
            assert_eq!(s.final_ounce, expected, "total {total}");
        }
    }

    #[test]
    fn discourage_catch_up_near_waking_end_with_big_remainder() {
        // 90 min before waking_end, > 1000 ml remaining.
        let s = compute_water_state(GOAL - 1_001, GOAL, (END as i64) - 90, START, END);
        assert!(s.discourage_catch_up);
        // Same remainder but earlier in the evening: no flag.
        let s = compute_water_state(GOAL - 1_001, GOAL, (END as i64) - 91, START, END);
        assert!(!s.discourage_catch_up);
        // Near the end but only 1000 ml remaining (boundary): no flag.
        let s = compute_water_state(GOAL - 1_000, GOAL, (END as i64) - 30, START, END);
        assert!(!s.discourage_catch_up);
        // Still discouraged after the window end, before the day rolls over.
        let s = compute_water_state(0, GOAL, 1_500, START, END);
        assert!(s.discourage_catch_up);
    }

    #[test]
    fn chug_threshold_is_strictly_over_a_liter() {
        assert!(!check_chug(500, 500).warn); // exactly 1000: no warning
        assert!(check_chug(500, 501).warn);
        assert!(check_chug(0, 1_001).warn);
        assert!(!check_chug(0, 1_000).warn);
    }

    #[test]
    fn trailing_window_is_a_strict_hour() {
        let now = 100_000;
        let events = [
            (now - CHUG_WINDOW_SECS, 999i64), // exactly 60 min old: outside
            (now - CHUG_WINDOW_SECS + 1, 300),
            (now - 10, 200),
            (now + 5, 400), // future (other process clock skew): outside
        ];
        assert_eq!(trailing_hour_ml(&events, now), 500);
    }
}
