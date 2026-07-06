//! Friend-group presence projection (docs/PHASE2.md "Groups").
//!
//! The group surface is privacy-critical: it exposes ONLY a member's day
//! index, current run, today's per-task done/not-done booleans, and a single
//! done/not for this week's extra. Never photos/refs, notes, the diet
//! description, water amounts, event details, resets, or the extra's name/id.
//!
//! This module owns the *derivation* (reusing the same [`Projection`] the
//! client uses, so the rules never fork), returning a flat struct of
//! primitives. The server hand-builds its minimal wire DTO from these fields —
//! it never serializes the underlying [`Challenge`]/[`EventRow`], so nothing
//! sensitive can leak by accident.

use crate::api::{Cadence, Challenge, ExtraDef};
use crate::error::Result;
use crate::events::EventRow;
use crate::projections::Projection;
use crate::time::{self, LocalInstant};

/// A member's shareable day-state, derived server-side from their synced
/// events + config. Every field here is safe to show other group members;
/// this struct deliberately contains NOTHING that could reveal water amounts,
/// notes, photos, the diet text, or which extra the weekly flag refers to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GroupPresence {
    /// Raw 1-based day number for "their today". May fall outside
    /// `[1, length_days]` before the challenge starts or after it ends; the
    /// caller displays it clamped if it wants.
    pub day_index: i64,
    /// Consecutive complete days ending at their today (if complete) else
    /// yesterday — the same figure the summary reports.
    pub current_run: u32,
    pub water: bool,
    pub outdoor_workout: bool,
    pub second_workout: bool,
    pub reading: bool,
    pub diet: bool,
    pub no_junk: bool,
    pub photo: bool,
    /// Done/not for THIS week's extra only. `true` when any enabled
    /// weekly-cadence extra was completed in the current 7-day block. Carries
    /// NO name or id: a member must never learn *which* extra (e.g. that a
    /// groupmate is job-hunting), only that this week's extra is done.
    pub weekly_extra_done: bool,
}

/// Projects one member's shareable presence for "their today" =
/// `now` (server-now stamped with the member's last-known tz offset) attributed
/// through this challenge's day-cutoff/closed-day rules.
///
/// This is the SAME [`Projection`] the client's `today`/`summary` build on, so
/// the group view can never disagree with what the member sees locally. It is a
/// pure function of its inputs (no clock, no I/O): the server loads the
/// member's active challenge, its events, and its extra defs, picks the
/// member's last-synced tz offset, and calls this.
///
/// "Their today" is an approximation: a member who has not synced since
/// changing timezones (or at all today) is projected at their last-known
/// offset, so they honestly show today's tasks as not-done until they sync.
pub fn project_group_presence(
    challenge: &Challenge,
    events: &[EventRow],
    extras: &[ExtraDef],
    now: LocalInstant,
) -> Result<GroupPresence> {
    let proj = Projection::build(challenge, events)?;
    let today = proj.attribute(now, None)?;
    let day = proj.day_state(today);
    let week_idx = time::week_index(day.day_index);

    // OR over the enabled weekly extras — Phase 1 ships exactly one
    // (`job_application`), so this is that extra's done/not, but expressed
    // without ever naming it.
    let mut weekly_extra_done = false;
    for x in extras {
        if x.enabled && x.cadence == Cadence::Weekly && proj.week_extra_done(&x.id, week_idx)? {
            weekly_extra_done = true;
            break;
        }
    }

    Ok(GroupPresence {
        day_index: day.day_index,
        current_run: proj.current_run(today)?,
        water: day.water_done,
        outdoor_workout: day.outdoor_workout_done,
        second_workout: day.second_workout_done,
        reading: day.reading_done,
        diet: day.diet_done,
        no_junk: day.no_junk_done,
        photo: day.photo_done,
        weekly_extra_done,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::{Challenge, ExtraDef, JOB_EXTRA_ID};
    use crate::events;
    use crate::rules::RulesetKind;
    use serde_json::json;

    const TZ: i32 = -18_000; // UTC-5

    fn at(date: &str, hour: i64, minute: i64) -> LocalInstant {
        let d = time::parse_date(date).expect("date");
        let wall = time::wall_secs_at_midnight(d).expect("range") + hour * 3_600 + minute * 60;
        LocalInstant {
            epoch_secs: wall - i64::from(TZ),
            tz_offset_secs: TZ,
        }
    }

    fn challenge(start: &str) -> Challenge {
        Challenge {
            id: "ch-1".into(),
            created_at: at(start, 6, 0),
            ruleset: RulesetKind::Flexible,
            start_date: start.into(),
            length_days: 75,
            day_cutoff_minutes: 240,
            waking_start_minutes: 420,
            waking_end_minutes: 1320,
            initial_water_goal_ml: 3_785,
            // The diet text is loaded but must never surface: proving the
            // projection carries it in the Challenge (and the server drops it).
            diet_description: Some("secret keto notes".into()),
            current_book: Some("Deep Work".into()),
            active: true,
        }
    }

    fn ev(id: i64, kind: &str, payload: serde_json::Value, logged: LocalInstant) -> EventRow {
        EventRow {
            id,
            uuid: format!("uuid-{id}"),
            challenge_id: "ch-1".into(),
            logged_at: logged,
            effective_date: None,
            kind: kind.into(),
            payload,
            schema_version: events::SIX_TASK_SCHEMA_VERSION,
        }
    }

    fn job_extra() -> ExtraDef {
        ExtraDef {
            id: JOB_EXTRA_ID.into(),
            name: JOB_EXTRA_NAME_HIDDEN.into(),
            cadence: Cadence::Weekly,
            enabled: true,
        }
    }
    const JOB_EXTRA_NAME_HIDDEN: &str = "Apply to a job";

    #[test]
    fn complete_day_projects_every_task_true() {
        let d = "2026-07-04";
        let events = vec![
            ev(1, events::KIND_WATER_ADD, json!({"ml": 4_000}), at(d, 8, 0)),
            ev(
                2,
                events::KIND_WORKOUT,
                json!({"duration_min": 45, "outdoor": true, "note": "run", "started_at": null}),
                at(d, 9, 0),
            ),
            ev(
                3,
                events::KIND_WORKOUT,
                json!({"duration_min": 30, "outdoor": false, "note": null, "started_at": null}),
                at(d, 18, 0),
            ),
            ev(
                4,
                events::KIND_READING,
                json!({"book_title": "Deep Work", "pages": 20}),
                at(d, 20, 0),
            ),
            ev(5, events::KIND_DIET_OK, json!({}), at(d, 20, 5)),
            ev(6, events::KIND_NO_JUNK_OK, json!({}), at(d, 20, 6)),
            ev(
                7,
                events::KIND_PHOTO_DONE,
                json!({"photo_ref": null}),
                at(d, 20, 7),
            ),
            ev(
                8,
                events::KIND_EXTRA_DONE,
                json!({"extra_id": JOB_EXTRA_ID}),
                at(d, 21, 0),
            ),
        ];
        let p = project_group_presence(&challenge(d), &events, &[job_extra()], at(d, 22, 0))
            .expect("presence");
        assert_eq!(p.day_index, 1);
        assert_eq!(p.current_run, 1);
        assert!(p.water && p.outdoor_workout && p.second_workout);
        assert!(p.reading && p.diet && p.no_junk && p.photo);
        assert!(p.weekly_extra_done, "job extra done this week -> flag true");
    }

    #[test]
    fn a_member_who_has_not_synced_today_shows_tasks_not_done() {
        // Challenge exists but the member logged nothing today.
        let p = project_group_presence(
            &challenge("2026-07-04"),
            &[],
            &[job_extra()],
            at("2026-07-04", 22, 0),
        )
        .expect("presence");
        assert_eq!(p.day_index, 1);
        assert_eq!(p.current_run, 0);
        assert!(!p.water && !p.outdoor_workout && !p.second_workout);
        assert!(!p.reading && !p.diet && !p.no_junk && !p.photo);
        assert!(!p.weekly_extra_done);
    }

    #[test]
    fn only_water_and_reading_done_leaves_the_rest_false() {
        let d = "2026-07-04";
        let events = vec![
            ev(1, events::KIND_WATER_ADD, json!({"ml": 4_000}), at(d, 8, 0)),
            ev(
                2,
                events::KIND_READING,
                json!({"book_title": "X", "pages": 12}),
                at(d, 20, 0),
            ),
        ];
        let p = project_group_presence(&challenge(d), &events, &[job_extra()], at(d, 22, 0))
            .expect("presence");
        assert!(p.water && p.reading);
        assert!(!p.outdoor_workout && !p.second_workout && !p.diet && !p.no_junk && !p.photo);
        assert!(!p.weekly_extra_done);
        assert_eq!(p.current_run, 0, "an incomplete today keeps the run at 0");
    }
}
