//! Event-log projections. Day state is always derived from the append-only
//! log, never stored (docs/ARCHITECTURE.md, "Core principles" #2).

use std::collections::{BTreeMap, BTreeSet, HashSet};

use chrono::NaiveDate;

use crate::api::{Challenge, DayState, WorkoutEntry};
use crate::error::{DromeError, Result};
use crate::events::{
    self, DayBackfilledPayload, DayClosedPayload, EventRow, ExtraDonePayload, GoalChangedPayload,
    ReadingPayload, WaterAddPayload, WaterAdjustPayload, WorkoutPayload,
};
use crate::rules::{RulesetKind, READING_PAGES_TARGET};
use crate::time::{self, attribute_date, day_index, format_date, LocalInstant};

/// A water-goal change attributed to a date. `seq` orders same-day changes
/// (log order: logged_at then row id).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GoalChange {
    pub date: NaiveDate,
    pub seq: (i64, i64),
    pub ml: i64,
}

/// Each day's goal is the last goal set on or before that day; days before any
/// change keep the initial goal. Past days are never rewritten by later changes.
pub fn goal_as_of_day(initial_ml: i64, sorted_changes: &[GoalChange], date: NaiveDate) -> i64 {
    sorted_changes
        .iter()
        .take_while(|c| c.date <= date)
        .last()
        .map_or(initial_ml, |c| c.ml)
}

#[derive(Debug, Default)]
struct DayAccum {
    /// Per-day water total: `water_add` + `water_adjust` ml folded in
    /// (logged_at, id) order with a running floor at 0. A correction can
    /// never consume more than the water logged before it, so revoking the
    /// add a correction was validated against leaves the day at 0 — never
    /// with hidden negative debt that would silently swallow later pours.
    water_ml: i64,
    workouts: Vec<WorkoutEntry>,
    pages: u32,
    diet: bool,
    no_junk: bool,
    photo: bool,
    extras: BTreeSet<String>,
}

/// All non-revoked events of a challenge, attributed and aggregated.
pub struct Projection {
    ruleset: RulesetKind,
    start_date: NaiveDate,
    length_days: u32,
    day_cutoff_minutes: u32,
    initial_water_goal_ml: i64,
    closed_at: BTreeMap<NaiveDate, i64>,
    days: BTreeMap<NaiveDate, DayAccum>,
    goal_changes: Vec<GoalChange>,
    backfills: BTreeMap<NaiveDate, DayBackfilledPayload>,
    /// Non-revoked water adds AND adjustments as `(logged_at_epoch, ml)` —
    /// adjustments carry negative ml — for the chug guard. A live adjustment
    /// nets against the trailing-hour window so honestly correcting a
    /// fat-fingered pour also clears the false chug warning it caused
    /// (`trailing_hour_ml` floors the net at 0 so corrections can never
    /// manufacture headroom to chug against). Excludes explicitly backdated
    /// logs (`effective_date` set) of either kind: retroactive water is
    /// bookkeeping, not current intake, and must never poison the window.
    water_by_epoch: Vec<(i64, i64)>,
    /// UUIDs targeted by a `revoked` event — the single source of truth for
    /// per-event liveness queries (e.g. the water log).
    revoked: HashSet<String>,
    /// The no-junk feature boundary: the earliest local date any event was
    /// written by a six-task-era build (`schema_version >=`
    /// [`events::SIX_TASK_SCHEMA_VERSION`]). Days strictly before it inherit
    /// `diet_done` for `no_junk_done` — the live-log twin of the backfill
    /// fallback in `DayBackfilledPayload::no_junk_effective`. `None` means
    /// the whole log predates the feature (every day inherits).
    no_junk_since: Option<NaiveDate>,
}

impl Projection {
    /// `events` must be ordered by `(logged_at_epoch, id)` (the load order).
    pub fn build(challenge: &Challenge, events: &[EventRow]) -> Result<Self> {
        let start_date = time::parse_date(&challenge.start_date)?;

        // An event is skipped if any `revoked` event targets its uuid.
        // Revocations are not themselves revocable (no un-revoke).
        let revoked: HashSet<String> = events
            .iter()
            .filter(|e| e.kind == events::KIND_REVOKED)
            .filter_map(|e| e.payload.get("event_uuid").and_then(|v| v.as_str()))
            .map(str::to_owned)
            .collect();
        let live = |e: &&EventRow| !revoked.contains(e.uuid.as_str());

        // The closed map must be complete before attributing anything: whether
        // a close affects an event is decided per-event by comparing epochs.
        let mut closed_at: BTreeMap<NaiveDate, i64> = BTreeMap::new();
        for e in events
            .iter()
            .filter(|e| e.kind == events::KIND_DAY_CLOSED)
            .filter(live)
        {
            let payload: DayClosedPayload = e.payload_as()?;
            let date = time::parse_date(&payload.date)?;
            let entry = closed_at.entry(date).or_insert(e.logged_at.epoch_secs);
            *entry = (*entry).min(e.logged_at.epoch_secs);
        }

        // The no-junk feature boundary: the earliest local date any event was
        // written by a six-task-era build, by plain cutoff attribution of
        // `logged_at` (the real-world day that build was first used — so
        // revoked events count too and explicit `effective_date`s are
        // ignored; the min handles westward-travel epoch reordering). On a
        // log with no pre-era rows the challenge's creation date bounds it
        // as well: a challenge created by a six-task build requires the
        // attestation from its very first day, even before its first event.
        let mut no_junk_since: Option<NaiveDate> = None;
        let mut has_pre_era_events = false;
        let no_closes = BTreeMap::new();
        for e in events {
            if e.schema_version >= events::SIX_TASK_SCHEMA_VERSION {
                let d =
                    attribute_date(e.logged_at, None, challenge.day_cutoff_minutes, &no_closes)?;
                no_junk_since = Some(no_junk_since.map_or(d, |b| b.min(d)));
            } else {
                has_pre_era_events = true;
            }
        }
        if !has_pre_era_events {
            let d = attribute_date(
                challenge.created_at,
                None,
                challenge.day_cutoff_minutes,
                &no_closes,
            )?;
            no_junk_since = Some(no_junk_since.map_or(d, |b| b.min(d)));
        }

        let mut proj = Projection {
            ruleset: challenge.ruleset,
            start_date,
            length_days: challenge.length_days,
            day_cutoff_minutes: challenge.day_cutoff_minutes,
            initial_water_goal_ml: challenge.initial_water_goal_ml,
            closed_at,
            days: BTreeMap::new(),
            goal_changes: Vec::new(),
            backfills: BTreeMap::new(),
            water_by_epoch: Vec::new(),
            revoked: HashSet::new(),
            no_junk_since,
        };

        for e in events.iter().filter(live) {
            match e.kind.as_str() {
                events::KIND_WATER_ADD => {
                    let p: WaterAddPayload = e.payload_as()?;
                    let day = proj.day_mut(e)?;
                    day.water_ml = day.water_ml.saturating_add(p.ml).max(0);
                    if e.effective_date.is_none() {
                        proj.water_by_epoch.push((e.logged_at.epoch_secs, p.ml));
                    }
                }
                events::KIND_WATER_ADJUST => {
                    let p: WaterAdjustPayload = e.payload_as()?;
                    let day = proj.day_mut(e)?;
                    // p.ml is negative (log/import validation). The running
                    // floor clips an over-correction — possible only after a
                    // revoke reordered history — at 0 right here, so it can
                    // never debit pours folded after it (see DayAccum).
                    day.water_ml = day.water_ml.saturating_add(p.ml).max(0);
                    if e.effective_date.is_none() {
                        proj.water_by_epoch.push((e.logged_at.epoch_secs, p.ml));
                    }
                }
                events::KIND_WORKOUT => {
                    let p: WorkoutPayload = e.payload_as()?;
                    let entry = WorkoutEntry {
                        event_uuid: e.uuid.clone(),
                        duration_min: p.duration_min,
                        outdoor: p.outdoor,
                        note: p.note,
                        started_at: p.started_at,
                    };
                    proj.day_mut(e)?.workouts.push(entry);
                }
                events::KIND_READING => {
                    let p: ReadingPayload = e.payload_as()?;
                    let day = proj.day_mut(e)?;
                    day.pages = day.pages.saturating_add(p.pages);
                }
                events::KIND_DIET_OK => proj.day_mut(e)?.diet = true,
                events::KIND_NO_JUNK_OK => proj.day_mut(e)?.no_junk = true,
                events::KIND_PHOTO_DONE => proj.day_mut(e)?.photo = true,
                events::KIND_EXTRA_DONE => {
                    let p: ExtraDonePayload = e.payload_as()?;
                    proj.day_mut(e)?.extras.insert(p.extra_id);
                }
                events::KIND_GOAL_CHANGED => {
                    let p: GoalChangedPayload = e.payload_as()?;
                    let date = proj.attribute(e.logged_at, e.effective_date.as_deref())?;
                    proj.goal_changes.push(GoalChange {
                        date,
                        seq: (e.logged_at.epoch_secs, e.id),
                        ml: p.water_goal_ml,
                    });
                }
                events::KIND_DAY_BACKFILLED => {
                    let p: DayBackfilledPayload = e.payload_as()?;
                    let date = time::parse_date(&p.date)?;
                    // Later backfills of the same date replace earlier ones.
                    proj.backfills.insert(date, p);
                }
                events::KIND_DAY_CLOSED | events::KIND_REVOKED => {}
                other => {
                    return Err(DromeError::Internal(format!(
                        "unknown event kind in log: {other}"
                    )))
                }
            }
        }
        proj.goal_changes.sort_by_key(|c| (c.date, c.seq));
        proj.revoked = revoked;
        Ok(proj)
    }

    /// True when a `revoked` event targets this uuid (the event is dead).
    pub fn is_revoked(&self, uuid: &str) -> bool {
        self.revoked.contains(uuid)
    }

    fn day_mut(&mut self, e: &EventRow) -> Result<&mut DayAccum> {
        let date = self.attribute(e.logged_at, e.effective_date.as_deref())?;
        Ok(self.days.entry(date).or_default())
    }

    /// Attribution with this challenge's cutoff and closed-day map.
    pub fn attribute(
        &self,
        logged_at: LocalInstant,
        effective_date: Option<&str>,
    ) -> Result<NaiveDate> {
        let effective = effective_date.map(time::parse_date).transpose()?;
        attribute_date(
            logged_at,
            effective,
            self.day_cutoff_minutes,
            &self.closed_at,
        )
    }

    pub fn start_date(&self) -> NaiveDate {
        self.start_date
    }

    pub fn length_days(&self) -> u32 {
        self.length_days
    }

    pub fn is_closed(&self, date: NaiveDate) -> bool {
        self.closed_at.contains_key(&date)
    }

    pub fn water_events_by_epoch(&self) -> &[(i64, i64)] {
        &self.water_by_epoch
    }

    /// The goal this date is judged against, before the ruleset override.
    pub fn goal_for_date(&self, date: NaiveDate) -> i64 {
        goal_as_of_day(self.initial_water_goal_ml, &self.goal_changes, date)
    }

    pub fn day_state(&self, date: NaiveDate) -> DayState {
        let empty = DayAccum::default();
        let accum = self.days.get(&date).unwrap_or(&empty);
        let backfill = self.backfills.get(&date);
        let bf = |f: fn(&DayBackfilledPayload) -> bool| backfill.map(f).unwrap_or(false);

        let water_goal_ml = self.ruleset.water_goal_ml(self.goal_for_date(date));
        let (outdoor, second) = self.ruleset.workouts_satisfied(&accum.workouts);

        // Already non-negative: the fold applies a running floor per event
        // (see DayAccum). Kept as defense in depth for future event kinds.
        let water_ml = accum.water_ml.max(0);

        let water_done = bf(|b| b.water) || water_ml >= water_goal_ml;
        let outdoor_workout_done = bf(|b| b.outdoor_workout) || outdoor;
        let second_workout_done = bf(|b| b.second_workout) || second;
        let reading_done = bf(|b| b.reading) || accum.pages >= READING_PAGES_TARGET;
        let diet_done = bf(|b| b.diet) || accum.diet;
        // "No Junk or Alcohol" landed after stores already existed, so both
        // storage shapes get the same honest legacy reading: a backfill
        // payload missing the key inherits its `diet` flag (no_junk_effective),
        // and a day lived strictly before this store's six-task boundary
        // (`no_junk_since`) inherits the live diet attestation — the user's
        // sheet kept the two columns equal. An explicit backfill wins over
        // era inheritance; days on/after the boundary need the real attest.
        let pre_no_junk_era = self.no_junk_since.is_none_or(|since| date < since);
        let no_junk_done = match backfill {
            Some(b) => b.no_junk_effective() || accum.no_junk,
            None => accum.no_junk || (accum.diet && pre_no_junk_era),
        };
        let photo_done = bf(|b| b.photo) || accum.photo;

        let mut extras_done: BTreeSet<String> = accum.extras.clone();
        if let Some(b) = backfill {
            extras_done.extend(b.extra_ids.iter().cloned());
        }

        let idx = day_index(self.start_date, date);
        DayState {
            date: format_date(date),
            day_index: idx,
            in_range: idx >= 1 && idx <= i64::from(self.length_days),
            is_backfilled: backfill.is_some(),
            is_closed: self.is_closed(date),
            water_ml,
            water_goal_ml,
            water_done,
            workouts: accum.workouts.clone(),
            outdoor_workout_done,
            second_workout_done,
            reading_pages: accum.pages,
            reading_done,
            diet_done,
            no_junk_done,
            photo_done,
            extras_done: extras_done.into_iter().collect(),
            // All six core tasks, in both rulesets (mirrors the sheet's
            // separate "Nutrition/Diet" and "No Junk or Alcohol" columns).
            core_complete: water_done
                && outdoor_workout_done
                && second_workout_done
                && reading_done
                && diet_done
                && no_junk_done
                && photo_done,
        }
    }

    /// True when `extra_id` was done on any day of the 7-day block `week_idx`
    /// (day indexes (w-1)*7+1 ..= w*7), via a live event or a backfill.
    pub fn week_extra_done(&self, extra_id: &str, week_idx: i64) -> Result<bool> {
        if week_idx < 1 {
            return Ok(false);
        }
        let first_idx = (week_idx - 1) * 7 + 1;
        for offset in 0..7 {
            let date = self.date_at_index(first_idx + offset)?;
            if self.extra_done_on(extra_id, date) {
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// True when `extra_id` was done on `date` itself.
    pub fn extra_done_on(&self, extra_id: &str, date: NaiveDate) -> bool {
        let live = self
            .days
            .get(&date)
            .is_some_and(|d| d.extras.contains(extra_id));
        let backfilled = self
            .backfills
            .get(&date)
            .is_some_and(|b| b.extra_ids.iter().any(|id| id == extra_id));
        live || backfilled
    }

    /// Count of `core_complete` days inside the challenge range [1, length].
    pub fn days_complete_count(&self) -> Result<u32> {
        let mut count = 0u32;
        for idx in 1..=i64::from(self.length_days) {
            if self.day_state(self.date_at_index(idx)?).core_complete {
                count += 1;
            }
        }
        Ok(count)
    }

    /// Consecutive complete days ending at `today` if today is complete, else
    /// ending at yesterday. Never reaches before the challenge start, and days
    /// past day `length_days` never count (mirroring the start_date floor):
    /// once the challenge is over, the run is the streak ending at its last day.
    pub fn current_run(&self, today: NaiveDate) -> Result<u32> {
        let end_date = self.date_at_index(i64::from(self.length_days))?;
        let anchor = today.min(end_date);
        let mut cursor = if self.day_state(anchor).core_complete {
            anchor
        } else {
            time::prev_date(anchor)?
        };
        let mut run = 0u32;
        while cursor >= self.start_date && self.day_state(cursor).core_complete {
            run += 1;
            cursor = time::prev_date(cursor)?;
        }
        Ok(run)
    }

    /// (workouts, outdoor workouts, pages, water ml) over every attributed live
    /// event. Backfilled flag-days carry no quantities, so they add nothing.
    pub fn totals(&self) -> (u32, u32, u64, i64) {
        let mut workouts = 0u32;
        let mut outdoor = 0u32;
        let mut pages = 0u64;
        let mut water = 0i64;
        for day in self.days.values() {
            workouts = workouts.saturating_add(day.workouts.len() as u32);
            outdoor =
                outdoor.saturating_add(day.workouts.iter().filter(|w| w.outdoor).count() as u32);
            pages = pages.saturating_add(u64::from(day.pages));
            // day.water_ml is already fold-floored per event (never
            // negative); the .max(0) matches day_state's defense in depth.
            water = water.saturating_add(day.water_ml.max(0));
        }
        (workouts, outdoor, pages, water)
    }

    /// The calendar date of 1-based challenge day `idx` (may be out of range).
    pub fn date_at_index(&self, idx: i64) -> Result<NaiveDate> {
        self.start_date
            .checked_add_signed(
                chrono::Duration::try_days(idx - 1).ok_or(DromeError::TimeOutOfRange)?,
            )
            .ok_or(DromeError::TimeOutOfRange)
    }
}
