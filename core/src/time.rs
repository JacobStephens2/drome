//! Clock-free time primitives and the day-attribution algorithm.
//!
//! The attribution rules (and their rationale) are pinned in
//! docs/ARCHITECTURE.md, "Time & day attribution". All arithmetic is checked so
//! the functions are total over arbitrary inputs (property-tested).

use std::collections::BTreeMap;

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

use crate::error::{DromeError, Result};

pub const SECS_PER_DAY: i64 = 86_400;
pub const DATE_FMT: &str = "%Y-%m-%d";

/// A caller-captured moment: absolute time plus the UTC offset in effect where
/// (and when) it was captured. Local wall time = `epoch_secs + tz_offset_secs`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record, Serialize, Deserialize)]
pub struct LocalInstant {
    pub epoch_secs: i64,
    pub tz_offset_secs: i32,
}

impl LocalInstant {
    /// Seconds on the "local wall clock" axis (epoch shifted by the offset).
    pub fn wall_secs(&self) -> Result<i64> {
        self.epoch_secs
            .checked_add(i64::from(self.tz_offset_secs))
            .ok_or(DromeError::TimeOutOfRange)
    }
}

pub fn parse_date(s: &str) -> Result<NaiveDate> {
    // chrono accepts unpadded fields for %Y-%m-%d; the API contract is strict.
    let bytes = s.as_bytes();
    let well_formed = bytes.len() == 10
        && bytes.iter().enumerate().all(|(i, b)| {
            if i == 4 || i == 7 {
                *b == b'-'
            } else {
                b.is_ascii_digit()
            }
        });
    if !well_formed {
        return Err(DromeError::InvalidDate(s.to_owned()));
    }
    NaiveDate::parse_from_str(s, DATE_FMT).map_err(|_| DromeError::InvalidDate(s.to_owned()))
}

pub fn format_date(d: NaiveDate) -> String {
    d.format(DATE_FMT).to_string()
}

/// Days since 1970-01-01 (may be negative). `NaiveDate::default()` is the epoch.
pub fn days_from_epoch(d: NaiveDate) -> i64 {
    d.signed_duration_since(NaiveDate::default()).num_days()
}

/// Local-wall-clock seconds at this date's midnight.
pub fn wall_secs_at_midnight(d: NaiveDate) -> Result<i64> {
    days_from_epoch(d)
        .checked_mul(SECS_PER_DAY)
        .ok_or(DromeError::TimeOutOfRange)
}

fn date_from_epoch_days(days: i64) -> Result<NaiveDate> {
    let delta = chrono::Duration::try_days(days).ok_or(DromeError::TimeOutOfRange)?;
    NaiveDate::default()
        .checked_add_signed(delta)
        .ok_or(DromeError::TimeOutOfRange)
}

pub fn next_date(d: NaiveDate) -> Result<NaiveDate> {
    d.succ_opt().ok_or(DromeError::TimeOutOfRange)
}

pub fn prev_date(d: NaiveDate) -> Result<NaiveDate> {
    d.pred_opt().ok_or(DromeError::TimeOutOfRange)
}

/// The three-step attribution algorithm from docs/ARCHITECTURE.md.
///
/// `closed_at` maps a date to the `logged_at_epoch` of the *earliest*
/// non-revoked `day_closed` event for that date. Step 3 is applied repeatedly
/// (a chain of already-closed dates keeps pushing forward); it terminates
/// because dates strictly increase and the map is finite.
pub fn attribute_date(
    logged_at: LocalInstant,
    effective_date: Option<NaiveDate>,
    day_cutoff_minutes: u32,
    closed_at: &BTreeMap<NaiveDate, i64>,
) -> Result<NaiveDate> {
    // Step 1: an explicit effective date always wins (retroactive logging).
    if let Some(d) = effective_date {
        return Ok(d);
    }

    // Step 2: local wall clock minus the cutoff, then take the calendar date.
    let wall = logged_at.wall_secs()?;
    let shifted = wall
        .checked_sub(i64::from(day_cutoff_minutes).saturating_mul(60))
        .ok_or(DromeError::TimeOutOfRange)?;
    let mut date = date_from_epoch_days(shifted.div_euclid(SECS_PER_DAY))?;

    // Step 3: a day closed before this event pushes the event to the next date.
    loop {
        match closed_at.get(&date) {
            Some(&closed_epoch) if closed_epoch < logged_at.epoch_secs => {
                date = next_date(date)?;
            }
            _ => return Ok(date),
        }
    }
}

/// 1-based day number relative to the challenge start (day 1 = start_date).
pub fn day_index(start_date: NaiveDate, date: NaiveDate) -> i64 {
    date.signed_duration_since(start_date).num_days() + 1
}

/// 1-based 7-day block for a day index (week 1 = days 1–7).
pub fn week_index(day_index: i64) -> i64 {
    (day_index - 1).div_euclid(7) + 1
}

/// Minutes elapsed since `date`'s local midnight at instant `now`. Can be
/// negative or beyond 1440 when `now` falls outside `date`'s calendar bounds
/// (e.g. logging for day D at 1:30 AM of D+1 yields ~1530).
pub fn minutes_into_day(now: LocalInstant, date: NaiveDate) -> Result<i64> {
    let wall = now.wall_secs()?;
    let midnight = wall_secs_at_midnight(date)?;
    Ok(wall
        .checked_sub(midnight)
        .ok_or(DromeError::TimeOutOfRange)?
        / 60)
}

#[cfg(test)]
pub(crate) fn instant(date: &str, hour: i64, minute: i64, tz_offset_secs: i32) -> LocalInstant {
    let d = parse_date(date).expect("test date");
    let wall = wall_secs_at_midnight(d).expect("test date range") + hour * 3600 + minute * 60;
    LocalInstant {
        epoch_secs: wall - i64::from(tz_offset_secs),
        tz_offset_secs,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> NaiveDate {
        parse_date(s).expect("test date")
    }

    #[test]
    fn parse_and_format_roundtrip() {
        assert_eq!(format_date(d("2026-06-21")), "2026-06-21");
        assert!(parse_date("2026-6-21").is_err());
        assert!(parse_date("garbage").is_err());
        assert!(parse_date("2026-13-01").is_err());
    }

    #[test]
    fn explicit_effective_date_wins() {
        let closed = BTreeMap::from([(d("2026-07-01"), 0i64)]);
        let got = attribute_date(
            instant("2026-07-04", 12, 0, -21600),
            Some(d("2026-07-01")),
            240,
            &closed,
        )
        .expect("attribution");
        assert_eq!(got, d("2026-07-01"));
    }

    #[test]
    fn before_cutoff_belongs_to_previous_date() {
        // 1:30 AM with a 4:00 AM cutoff -> previous date.
        let got = attribute_date(
            instant("2026-07-04", 1, 30, 3600),
            None,
            240,
            &BTreeMap::new(),
        )
        .expect("attribution");
        assert_eq!(got, d("2026-07-03"));
    }

    #[test]
    fn at_or_after_cutoff_belongs_to_same_date() {
        let at = attribute_date(instant("2026-07-04", 4, 0, 0), None, 240, &BTreeMap::new())
            .expect("attribution");
        assert_eq!(at, d("2026-07-04"));
        let evening = attribute_date(
            instant("2026-07-04", 23, 59, 0),
            None,
            240,
            &BTreeMap::new(),
        )
        .expect("attribution");
        assert_eq!(evening, d("2026-07-04"));
    }

    #[test]
    fn zero_cutoff_is_plain_calendar_date() {
        let got = attribute_date(instant("2026-07-04", 0, 0, 0), None, 0, &BTreeMap::new())
            .expect("attribution");
        assert_eq!(got, d("2026-07-04"));
    }

    #[test]
    fn closed_day_pushes_to_next_date() {
        let event = instant("2026-07-04", 23, 30, 0);
        let closed = BTreeMap::from([(d("2026-07-04"), event.epoch_secs - 3600)]);
        let got = attribute_date(event, None, 240, &closed).expect("attribution");
        assert_eq!(got, d("2026-07-05"));
    }

    #[test]
    fn close_after_event_does_not_push() {
        let event = instant("2026-07-04", 23, 30, 0);
        let closed = BTreeMap::from([(d("2026-07-04"), event.epoch_secs + 3600)]);
        let got = attribute_date(event, None, 240, &closed).expect("attribution");
        assert_eq!(got, d("2026-07-04"));
    }

    #[test]
    fn chained_closed_days_keep_pushing() {
        let event = instant("2026-07-04", 23, 30, 0);
        let closed = BTreeMap::from([
            (d("2026-07-04"), event.epoch_secs - 7200),
            (d("2026-07-05"), event.epoch_secs - 3600),
        ]);
        let got = attribute_date(event, None, 240, &closed).expect("attribution");
        assert_eq!(got, d("2026-07-06"));
    }

    #[test]
    fn effective_date_bypasses_closed_push() {
        let event = instant("2026-07-04", 23, 30, 0);
        let closed = BTreeMap::from([(d("2026-07-04"), event.epoch_secs - 3600)]);
        let got = attribute_date(event, Some(d("2026-07-04")), 240, &closed).expect("attribution");
        assert_eq!(got, d("2026-07-04"));
    }

    #[test]
    fn attribution_errors_on_extreme_epochs_instead_of_panicking() {
        for epoch in [i64::MIN, i64::MAX] {
            let li = LocalInstant {
                epoch_secs: epoch,
                tz_offset_secs: -3600,
            };
            assert!(attribute_date(li, None, 240, &BTreeMap::new()).is_err());
        }
    }

    #[test]
    fn day_and_week_index() {
        let start = d("2026-06-21");
        assert_eq!(day_index(start, start), 1);
        assert_eq!(day_index(start, d("2026-07-04")), 14);
        assert_eq!(day_index(start, d("2026-06-20")), 0);
        assert_eq!(week_index(1), 1);
        assert_eq!(week_index(7), 1);
        assert_eq!(week_index(8), 2);
        assert_eq!(week_index(14), 2);
        assert_eq!(week_index(75), 11);
    }

    #[test]
    fn minutes_into_day_spans_midnight() {
        let now = instant("2026-07-05", 1, 30, 0); // 1:30 AM of the next calendar day
        assert_eq!(minutes_into_day(now, d("2026-07-04")).expect("range"), 1530);
        assert_eq!(minutes_into_day(now, d("2026-07-05")).expect("range"), 90);
        assert_eq!(
            minutes_into_day(now, d("2026-07-06")).expect("range"),
            -1350
        );
    }
}
