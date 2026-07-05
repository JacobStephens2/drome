//! Property tests for the safety-critical math: day attribution, goal-as-of-day,
//! and the anti-chug window.

use std::collections::BTreeMap;

use chrono::NaiveDate;
use proptest::prelude::*;

use crate::projections::{goal_as_of_day, GoalChange};
use crate::time::{attribute_date, wall_secs_at_midnight, LocalInstant};
use crate::water;

const MAX_TZ_OFFSET: i32 = 64_800; // UTC±18h, the real-world extreme

fn arb_date() -> impl Strategy<Value = NaiveDate> {
    (1970i32..2200, 1u32..=12, 1u32..=28)
        .prop_map(|(y, m, d)| NaiveDate::from_ymd_opt(y, m, d).expect("valid ymd"))
}

fn arb_offset() -> impl Strategy<Value = i32> {
    -MAX_TZ_OFFSET..=MAX_TZ_OFFSET
}

fn arb_closed_map() -> impl Strategy<Value = BTreeMap<NaiveDate, i64>> {
    prop::collection::btree_map(arb_date(), any::<i64>(), 0..8)
}

/// Epoch of `minute_of_day` on `date`'s local wall clock, seen from `offset`.
fn epoch_at(date: NaiveDate, minute_of_day: i64, offset: i32) -> i64 {
    wall_secs_at_midnight(date).expect("date in range") + minute_of_day * 60 - i64::from(offset)
}

proptest! {
    // (a) Attribution is a total function: arbitrary epochs/offsets/cutoffs and
    // closed maps never panic, and an Ok result is a single, stable date.
    #[test]
    fn attribution_is_total_and_deterministic(
        epoch in any::<i64>(),
        offset in arb_offset(),
        cutoff in 0u32..1440,
        closed in arb_closed_map(),
    ) {
        let li = LocalInstant { epoch_secs: epoch, tz_offset_secs: offset };
        let first = attribute_date(li, None, cutoff, &closed);
        let second = attribute_date(li, None, cutoff, &closed);
        match (first, second) {
            (Ok(a), Ok(b)) => prop_assert_eq!(a, b),
            (Err(_), Err(_)) => {}
            _ => prop_assert!(false, "attribution not deterministic"),
        }
    }

    // (b) An explicit effective_date always wins, whatever else is going on.
    #[test]
    fn effective_date_always_wins(
        eff in arb_date(),
        epoch in any::<i64>(),
        offset in arb_offset(),
        cutoff in 0u32..1440,
        closed in arb_closed_map(),
    ) {
        let li = LocalInstant { epoch_secs: epoch, tz_offset_secs: offset };
        let got = attribute_date(li, Some(eff), cutoff, &closed);
        prop_assert_eq!(got.ok(), Some(eff));
    }

    // (c) With cutoff C, a local time before C attributes to the previous
    // calendar date; at or after C, to the same date.
    #[test]
    fn cutoff_splits_the_night(
        date in arb_date(),
        cutoff in 0u32..1440,
        minute in 0i64..1440,
        offset in arb_offset(),
    ) {
        let li = LocalInstant {
            epoch_secs: epoch_at(date, minute, offset),
            tz_offset_secs: offset,
        };
        let got = attribute_date(li, None, cutoff, &BTreeMap::new());
        let expected = if minute < i64::from(cutoff) {
            date.pred_opt().expect("date in range")
        } else {
            date
        };
        prop_assert_eq!(got.ok(), Some(expected));
    }

    // (d) day_closed(D) at T pushes later same-window events to D+1, while an
    // explicit effective_date = D still lands on D.
    #[test]
    fn closed_day_pushes_later_events(
        date in arb_date(),
        cutoff in 0u32..1440,
        minute_after_cutoff in 0i64..1440,
        offset in arb_offset(),
        gap_secs in 1i64..1_000_000,
    ) {
        // Event inside D's window: local time in [cutoff, cutoff + 24h).
        let li = LocalInstant {
            epoch_secs: epoch_at(date, i64::from(cutoff) + minute_after_cutoff, offset),
            tz_offset_secs: offset,
        };
        let closed = BTreeMap::from([(date, li.epoch_secs - gap_secs)]);

        let pushed = attribute_date(li, None, cutoff, &closed);
        prop_assert_eq!(pushed.ok(), Some(date.succ_opt().expect("date in range")));

        let explicit = attribute_date(li, Some(date), cutoff, &closed);
        prop_assert_eq!(explicit.ok(), Some(date));
    }

    // (e) DST safety: holding the local wall-clock time fixed, the attributed
    // date is invariant to the tz offset the instant was captured with.
    #[test]
    fn attribution_invariant_to_offset_at_fixed_wall_time(
        date in arb_date(),
        minute in 0i64..1440,
        cutoff in 0u32..1440,
        offset_a in arb_offset(),
        offset_b in arb_offset(),
    ) {
        let a = LocalInstant {
            epoch_secs: epoch_at(date, minute, offset_a),
            tz_offset_secs: offset_a,
        };
        let b = LocalInstant {
            epoch_secs: epoch_at(date, minute, offset_b),
            tz_offset_secs: offset_b,
        };
        prop_assert_eq!(
            attribute_date(a, None, cutoff, &BTreeMap::new()).ok(),
            attribute_date(b, None, cutoff, &BTreeMap::new()).ok()
        );
    }

    // (f) Water goal-as-of-day: appending a goal change never rewrites the goal
    // of any earlier day, and each day's goal matches the last-on-or-before model.
    #[test]
    fn goal_changes_never_rewrite_earlier_days(
        initial in 1i64..50_000,
        raw_changes in prop::collection::vec((0i64..75, 1i64..50_000), 0..10),
        new_day in 0i64..75,
        new_ml in 1i64..50_000,
    ) {
        let start = NaiveDate::from_ymd_opt(2026, 6, 21).expect("valid ymd");
        let day = |offset: i64| start + chrono::Duration::days(offset);

        let mut changes: Vec<GoalChange> = raw_changes
            .iter()
            .enumerate()
            .map(|(i, (offset, ml))| GoalChange {
                date: day(*offset),
                seq: (i as i64, i as i64),
                ml: *ml,
            })
            .collect();
        changes.sort_by_key(|c| (c.date, c.seq));

        // Model: last change on or before the day, in (date, seq) order.
        for offset in 0..75 {
            let expected = changes
                .iter()
                .rfind(|c| c.date <= day(offset))
                .map_or(initial, |c| c.ml);
            prop_assert_eq!(goal_as_of_day(initial, &changes, day(offset)), expected);
        }

        let before: Vec<i64> = (0..75)
            .map(|offset| goal_as_of_day(initial, &changes, day(offset)))
            .collect();
        let mut appended = changes.clone();
        appended.push(GoalChange {
            date: day(new_day),
            seq: (i64::MAX, i64::MAX),
            ml: new_ml,
        });
        appended.sort_by_key(|c| (c.date, c.seq));
        for offset in 0..new_day {
            prop_assert_eq!(
                goal_as_of_day(initial, &appended, day(offset)),
                before[offset as usize],
                "goal for day offset {} was rewritten by a change on day offset {}",
                offset,
                new_day
            );
        }
    }

    // (g) Anti-chug: events inside the trailing hour count, older ones don't,
    // and the warning is exactly `sum + add > 1000`.
    #[test]
    fn chug_counts_only_the_trailing_hour(
        now in 10_000i64..1_000_000_000,
        raw_events in prop::collection::vec((0i64..7_200, 1i64..1_500), 0..20),
        add in 0i64..2_000,
    ) {
        let events: Vec<(i64, i64)> = raw_events
            .iter()
            .map(|(age_secs, ml)| (now - age_secs, *ml))
            .collect();
        let expected_sum: i64 = raw_events
            .iter()
            .filter(|(age_secs, _)| *age_secs < 3_600)
            .map(|(_, ml)| ml)
            .sum();
        let trailing = water::trailing_hour_ml(&events, now);
        prop_assert_eq!(trailing, expected_sum);
        let check = water::check_chug(trailing, add);
        prop_assert_eq!(check.warn, expected_sum + add > 1_000);
    }
}
