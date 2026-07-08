//! Water pacing and the anti-chug safety guard
//! (docs/ARCHITECTURE.md, "Water pacing & safety"). Ships in every mode.

use serde::{Deserialize, Serialize};

pub const ON_PACE_SLACK_ML: i64 = 250;
pub const FINAL_OUNCE_ML: i64 = 150;
/// Completion slack (~half a US fl oz) absorbing oz⇄ml display rounding: a goal
/// entered in whole ounces stores as ml, and whole-ounce pours store as ml that
/// don't sum back to it exactly (four 32 oz bottles = 3784 ml vs a 3785 ml
/// gallon), so an exact ml comparison leaves the goal unreachable and "of N oz"
/// disagreeing with "oz to go". Within this slack the day counts as met and
/// nothing remains — below the finest amount the user can see (1 oz).
pub const FILL_TOLERANCE_ML: i64 = 15;
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

    // Within the fill tolerance the goal counts as met, so nothing remains —
    // this is what makes a whole-ounce goal reachable by whole-ounce pours and
    // keeps "oz to go" consistent with the "of N oz" line.
    let raw_remaining = (goal_ml - total_ml).max(0);
    let remaining_ml = if raw_remaining <= FILL_TOLERANCE_ML {
        0
    } else {
        raw_remaining
    };
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

/// Net water logged in the trailing 60 minutes: `(epoch_secs, ml)` pairs with
/// `now - 60min < epoch <= now`, folded in time order with a running floor
/// at 0. Corrections (`water_adjust`, negative ml) inside the window net
/// against the intake logged BEFORE them, so honestly fixing a fat-fingered
/// pour also clears the false chug warning it caused — the guard should never
/// nag about water that was never drunk. The running floor means a correction
/// can never offset intake logged AFTER it: a stale correction (its original
/// add already aged out of the window) clips to 0 instead of manufacturing
/// "headroom" that would let a genuinely large later chug pass the guard.
/// (Corrections carry no link to the pour they correct, so one logged after
/// real in-window intake still nets against that; the exact per-pour undo is
/// revoking the pour itself, which removes its timestamp from the window.)
pub fn trailing_hour_ml(water_events: &[(i64, i64)], now_epoch: i64) -> i64 {
    let window_start = now_epoch.saturating_sub(CHUG_WINDOW_SECS);
    let mut in_window: Vec<(i64, i64)> = water_events
        .iter()
        .filter(|(epoch, _)| *epoch > window_start && *epoch <= now_epoch)
        .copied()
        .collect();
    // Callers pass log-ordered slices already; sort defensively (stable, so
    // same-epoch events keep their log order) because the fold is order-aware.
    in_window.sort_by_key(|(epoch, _)| *epoch);
    in_window
        .iter()
        .fold(0i64, |acc, (_, ml)| acc.saturating_add(*ml).max(0))
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
            (GOAL, false),                        // remaining 0: done, not "final ounce"
            (GOAL - FILL_TOLERANCE_ML, false),    // within fill tolerance: met, nothing remains
            (GOAL - FILL_TOLERANCE_ML - 1, true), // just past tolerance: the real band starts
            (GOAL - FINAL_OUNCE_ML, true),        // 150 ml (boundary)
            (GOAL - FINAL_OUNCE_ML - 1, false),   // 151 ml
        ] {
            let s = compute_water_state(total, GOAL, 800, START, END);
            assert_eq!(s.final_ounce, expected, "total {total}");
        }
    }

    #[test]
    fn fill_tolerance_completes_a_whole_ounce_goal_from_whole_ounce_pours() {
        // Four 32 oz bottles store as 4 × 946 ml = 3784 ml, one ml shy of the
        // 3785 ml gallon: the tolerance still zeroes the remainder (done).
        let s = compute_water_state(3_784, GOAL, 800, START, END);
        assert_eq!(s.remaining_ml, 0);
        assert!(!s.final_ounce);
        // A genuine shortfall past the tolerance still shows a remainder.
        let s = compute_water_state(GOAL - 100, GOAL, 800, START, END);
        assert_eq!(s.remaining_ml, 100);
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

    #[test]
    fn trailing_window_nets_adjustments_and_floors_at_zero() {
        let now = 100_000;
        // A fat-fingered 2000 corrected by -1900 nets to 100.
        let corrected = [(now - 600, 2_000i64), (now - 540, -1_900)];
        assert_eq!(trailing_hour_ml(&corrected, now), 100);
        // The corrected add aged out of the window but the correction hasn't:
        // it clips at 0 instead of going negative (no chug "headroom").
        let orphaned = [(now - CHUG_WINDOW_SECS, 800i64), (now - 60, -700)];
        assert_eq!(trailing_hour_ml(&orphaned, now), 0);
        assert!(!check_chug(trailing_hour_ml(&orphaned, now), 1_000).warn);
        assert!(check_chug(trailing_hour_ml(&orphaned, now), 1_001).warn);
    }

    #[test]
    fn stale_correction_never_offsets_later_intake() {
        let now = 100_000;
        // A stale correction (its add aged out) followed by a genuine liter:
        // the running floor clips the correction to 0 BEFORE the add, so the
        // fresh intake counts in full. Sum-then-floor would report 100 here
        // and let ~1.9 L inside the hour pass unwarned.
        let events = [(now - 600, -900i64), (now - 300, 1_000)];
        assert_eq!(trailing_hour_ml(&events, now), 1_000);
        assert!(check_chug(trailing_hour_ml(&events, now), 1).warn);
        // Same events arriving unsorted fold identically.
        let shuffled = [(now - 300, 1_000i64), (now - 600, -900)];
        assert_eq!(trailing_hour_ml(&shuffled, now), 1_000);
    }
}
