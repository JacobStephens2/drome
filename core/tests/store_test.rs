//! Integration tests against the public `DromeStore` API, including the demo
//! fixture from docs/ARCHITECTURE.md (start 2026-06-21, days 1–12 backfilled
//! complete, day 13 missing reading, day 14 live).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use drome_core::{
    BackfilledDay, DromeError, DromeStore, LocalInstant, NewChallenge, RevocableTask, RulesetKind,
    JOB_EXTRA_ID,
};
use tempfile::TempDir;

const TZ: i32 = -18_000; // US Central daylight time
const GALLON_ML: i64 = 3_785;

fn at(date: &str, hour: i64, minute: i64) -> LocalInstant {
    let d = drome_core::time::parse_date(date).expect("test date");
    let wall =
        drome_core::time::wall_secs_at_midnight(d).expect("in range") + hour * 3_600 + minute * 60;
    LocalInstant {
        epoch_secs: wall - i64::from(TZ),
        tz_offset_secs: TZ,
    }
}

fn plus_min(li: LocalInstant, minutes: i64) -> LocalInstant {
    LocalInstant {
        epoch_secs: li.epoch_secs + minutes * 60,
        tz_offset_secs: li.tz_offset_secs,
    }
}

fn open_store() -> (TempDir, String, Arc<DromeStore>) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir
        .path()
        .join("drome.sqlite")
        .to_string_lossy()
        .into_owned();
    let store = DromeStore::open(path.clone()).expect("open store");
    (dir, path, store)
}

fn challenge_cfg(ruleset: RulesetKind, start_date: &str, created_at: LocalInstant) -> NewChallenge {
    NewChallenge {
        ruleset,
        start_date: start_date.into(),
        length_days: 75,
        day_cutoff_minutes: 240,
        waking_start_minutes: 420,
        waking_end_minutes: 1320,
        initial_water_goal_ml: GALLON_ML,
        diet_description: Some("no sweets, no alcohol".into()),
        current_book: Some("Deep Work".into()),
        created_at,
    }
}

/// Calendar date of fixture day N (start 2026-06-21).
fn fixture_date(day: u32) -> String {
    assert!((1..=40).contains(&day));
    if day <= 10 {
        format!("2026-06-{}", 20 + day)
    } else {
        format!("2026-07-{:02}", day - 10)
    }
}

/// Demo persona: mid-challenge onboarding on day 14 (2026-07-04). Days 1–12 complete
/// (job extra done on day 3 = week 1), day 13 complete except reading.
fn demo_store() -> (TempDir, String, Arc<DromeStore>) {
    let (dir, path, store) = open_store();
    store
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-06-21",
            at("2026-07-04", 9, 0),
        ))
        .expect("create challenge");
    store
        .set_extra_enabled(JOB_EXTRA_ID.into(), true, at("2026-07-04", 9, 0))
        .expect("enable extra");
    let days: Vec<BackfilledDay> = (1..=13)
        .map(|i| BackfilledDay {
            date: fixture_date(i),
            water: true,
            outdoor_workout: true,
            second_workout: true,
            reading: i != 13,
            diet: true,
            no_junk: true,
            photo: true,
            extra_ids: if i == 3 {
                vec![JOB_EXTRA_ID.into()]
            } else {
                vec![]
            },
        })
        .collect();
    store
        .backfill_days(days, at("2026-07-04", 9, 5))
        .expect("backfill");
    (dir, path, store)
}

#[test]
fn set_start_date_reindexes_days_and_rejects_bad_dates() {
    let (_dir, _path, store) = open_store();
    // Onboarded as "Day 5": start 2026-06-30, today 2026-07-04.
    store
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-06-30",
            at("2026-07-04", 9, 0),
        ))
        .expect("create");
    let now = at("2026-07-04", 10, 0);
    assert_eq!(store.today(now).expect("today").day_index, 5);

    // Correct it: actually started 2026-06-27, so today is Day 8.
    store
        .set_start_date("2026-06-27".into(), at("2026-07-04", 10, 1))
        .expect("set start date");
    let today = store.today(now).expect("today after edit");
    assert_eq!(today.date, "2026-07-04");
    assert_eq!(today.day_index, 8);

    // An unparseable date is rejected and leaves the start unchanged.
    assert!(store
        .set_start_date("not-a-date".into(), at("2026-07-04", 10, 2))
        .is_err());
    assert_eq!(store.today(now).expect("today").day_index, 8);
}

#[test]
fn set_day_cutoff_is_forward_only_and_surfaces_current() {
    let (_dir, _path, store) = open_store();
    // 4:00 AM cutoff (240). Start 2026-06-21.
    store
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-06-21",
            at("2026-07-04", 9, 0),
        ))
        .expect("create");

    // A pour at 2:00 AM on 07-04 is BEFORE the 4 AM cutoff → it belongs to 07-03.
    store
        .log_water(500, at("2026-07-04", 2, 0), None)
        .expect("log A");
    let now = at("2026-07-04", 10, 0);
    assert_eq!(
        store.day_state("2026-07-03".into(), now).unwrap().water_ml,
        500
    );
    assert_eq!(
        store.day_state("2026-07-04".into(), now).unwrap().water_ml,
        0
    );

    // Move the cutoff earlier, to 1:00 AM (60), at 10:01 AM on 07-04.
    store
        .set_day_cutoff(60, at("2026-07-04", 10, 1))
        .expect("set cutoff");

    // Forward-only: the already-logged 2 AM pour keeps its day (still 07-03),
    // NOT re-attributed to 07-04 under the new 1 AM boundary.
    assert_eq!(
        store.day_state("2026-07-03".into(), now).unwrap().water_ml,
        500
    );
    assert_eq!(
        store.day_state("2026-07-04".into(), now).unwrap().water_ml,
        0
    );

    // A NEW pour at 2:00 AM on 07-05 is logged AFTER the change → the new 1 AM
    // cutoff applies: 2 AM ≥ 1 AM, so it belongs to 07-05 (under the old 4 AM
    // cutoff it would have counted toward 07-04).
    let now5 = at("2026-07-05", 10, 0);
    store
        .log_water(700, at("2026-07-05", 2, 0), None)
        .expect("log B");
    assert_eq!(
        store.day_state("2026-07-05".into(), now5).unwrap().water_ml,
        700
    );
    assert_eq!(
        store.day_state("2026-07-04".into(), now5).unwrap().water_ml,
        0
    );

    // active_challenge surfaces the CURRENT cutoff (60), not the initial (240).
    let ch = store.active_challenge().unwrap().expect("active");
    assert_eq!(ch.day_cutoff_minutes, 60);

    // Out-of-range cutoff is rejected.
    assert!(store
        .set_day_cutoff(1_440, at("2026-07-05", 11, 0))
        .is_err());
}

#[test]
fn demo_fixture_day_indexing_and_counts() {
    let (_dir, _path, store) = demo_store();
    let now = at("2026-07-04", 10, 0);

    let today = store.today(now).expect("today");
    assert_eq!(today.date, "2026-07-04");
    assert_eq!(today.day_index, 14);
    assert!(!today.out_of_range);
    assert!(!today.day.is_backfilled);

    let summary = store.summary(now).expect("summary");
    assert_eq!(summary.days_complete_count, 12);
    assert_eq!(summary.current_run, 0); // day 13 broke the run, day 14 open
    assert_eq!(summary.today_day_index, 14);
    assert!(!summary.today_out_of_range);

    let day13 = store
        .day_state("2026-07-03".into(), now)
        .expect("day state");
    assert!(day13.is_backfilled);
    assert!(!day13.reading_done);
    assert!(day13.water_done);
    assert!(day13.outdoor_workout_done);
    assert!(day13.second_workout_done);
    assert!(day13.diet_done);
    assert!(day13.no_junk_done);
    assert!(day13.photo_done);
    assert!(!day13.core_complete);

    let day12 = store
        .day_state("2026-07-02".into(), now)
        .expect("day state");
    assert!(day12.core_complete);
    assert!(day12.is_backfilled);
}

#[test]
fn demo_completion_moment_fires_exactly_once() {
    let (_dir, _path, store) = demo_store();
    let mut flips = Vec::new();

    // Water to (past) the goal, spread across the day: crossing the goal alone
    // must not fire the completion moment while other tasks are open.
    for (hour, ml) in [(10, 950), (11, 950), (12, 950), (13, 950)] {
        let r = store
            .log_water(ml, at("2026-07-04", hour, 0), None)
            .expect("log water");
        assert!(r.chug_warning.is_none());
        flips.push(r.day_became_complete);
    }
    let water_done_state = store
        .day_state("2026-07-04".into(), at("2026-07-04", 13, 30))
        .expect("day state");
    assert!(water_done_state.water_done);
    assert!(!water_done_state.core_complete);

    let r = store
        .log_workout(45, true, None, None, at("2026-07-04", 15, 0), None)
        .expect("log workout");
    flips.push(r.day_became_complete);
    let r = store
        .log_workout(
            30,
            false,
            Some("bike trainer".into()),
            None,
            at("2026-07-04", 18, 30),
            None,
        )
        .expect("log workout");
    flips.push(r.day_became_complete);
    let r = store
        .log_reading("Deep Work".into(), 12, at("2026-07-04", 20, 0), None)
        .expect("log reading");
    flips.push(r.day_became_complete);
    let r = store
        .log_diet_ok(at("2026-07-04", 21, 0), None)
        .expect("log diet");
    flips.push(r.day_became_complete);
    let r = store
        .log_no_junk_ok(at("2026-07-04", 21, 10), None)
        .expect("log no junk");
    flips.push(r.day_became_complete);

    // The final open task: this one fires the completion moment.
    let r = store
        .log_photo_done(None, at("2026-07-04", 21, 30), None)
        .expect("log photo");
    flips.push(r.day_became_complete);
    assert!(r.day_state.core_complete);
    assert!(!r.week_extra_became_complete);

    // Logging more afterwards never re-fires it.
    let r = store
        .log_water(200, at("2026-07-04", 21, 45), None)
        .expect("log water");
    flips.push(r.day_became_complete);

    assert_eq!(flips.iter().filter(|f| **f).count(), 1);
    assert_eq!(flips.pop(), Some(false)); // the post-completion water log
    assert_eq!(flips.last(), Some(&true)); // the photo log fired the moment

    let summary = store.summary(at("2026-07-04", 22, 0)).expect("summary");
    assert_eq!(summary.days_complete_count, 13);
    assert_eq!(summary.current_run, 1); // day 13 is incomplete behind it
}

#[test]
fn attribution_early_morning_close_and_effective_date() {
    let (_dir, _path, store) = open_store();
    store
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-06-21",
            at("2026-06-21", 8, 0),
        ))
        .expect("create");

    // 1:30 AM with the 4:00 AM cutoff belongs to the previous date.
    let r = store
        .log_water(500, at("2026-06-22", 1, 30), None)
        .expect("log");
    assert_eq!(r.day_state.date, "2026-06-21");

    // Closing a day pushes later same-window events to the next date...
    store
        .close_day("2026-06-22".into(), at("2026-06-22", 21, 0))
        .expect("close");
    let r = store
        .log_water(300, at("2026-06-22", 23, 0), None)
        .expect("log");
    assert_eq!(r.day_state.date, "2026-06-23");

    // ...but an explicit effective_date still lands on the closed day.
    let r = store
        .log_water(200, at("2026-06-22", 23, 30), Some("2026-06-22".into()))
        .expect("log");
    assert_eq!(r.day_state.date, "2026-06-22");

    let day22 = store
        .day_state("2026-06-22".into(), at("2026-06-23", 9, 0))
        .expect("day state");
    assert!(day22.is_closed);
    assert_eq!(day22.water_ml, 200);
}

#[test]
fn water_goal_is_evaluated_as_of_each_day() {
    let (_dir, _path, store) = open_store();
    store
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-06-21",
            at("2026-06-21", 8, 0),
        ))
        .expect("create");

    store
        .set_water_goal(3_000, at("2026-06-25", 10, 0))
        .expect("set goal");
    let now = at("2026-06-25", 11, 0);
    let day24 = store.day_state("2026-06-24".into(), now).expect("state");
    assert_eq!(day24.water_goal_ml, GALLON_ML);
    let day25 = store.day_state("2026-06-25".into(), now).expect("state");
    assert_eq!(day25.water_goal_ml, 3_000);
    let day26 = store.day_state("2026-06-26".into(), now).expect("state");
    assert_eq!(day26.water_goal_ml, 3_000);

    // A later change on the same day wins for that day; earlier days keep theirs.
    store
        .set_water_goal(2_500, at("2026-06-25", 12, 0))
        .expect("set goal");
    let now = at("2026-06-25", 13, 0);
    let day25 = store.day_state("2026-06-25".into(), now).expect("state");
    assert_eq!(day25.water_goal_ml, 2_500);
    let day24 = store.day_state("2026-06-24".into(), now).expect("state");
    assert_eq!(day24.water_goal_ml, GALLON_ML);
}

#[test]
fn revocation_hides_events_and_backfills_from_projections() {
    let (_dir, _path, store) = open_store();
    store
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-06-21",
            at("2026-06-21", 8, 0),
        ))
        .expect("create");
    let now = at("2026-06-21", 12, 0);

    let r = store
        .log_water(900, at("2026-06-21", 9, 0), None)
        .expect("log");
    assert_eq!(r.day_state.water_ml, 900);
    store
        .revoke_event(r.event_uuid, at("2026-06-21", 9, 5))
        .expect("revoke");
    let day = store.day_state("2026-06-21".into(), now).expect("state");
    assert_eq!(day.water_ml, 0);

    store
        .backfill_days(
            vec![BackfilledDay {
                date: "2026-06-21".into(),
                water: true,
                outdoor_workout: true,
                second_workout: true,
                reading: true,
                diet: true,
                no_junk: true,
                photo: true,
                extra_ids: vec![],
            }],
            at("2026-06-21", 10, 0),
        )
        .expect("backfill");
    let day = store.day_state("2026-06-21".into(), now).expect("state");
    assert!(day.core_complete);
    assert!(day.is_backfilled);

    // Find the backfill's uuid through the export, then revoke it.
    let json = store.export_json(now).expect("export");
    let doc: serde_json::Value = serde_json::from_str(&json).expect("valid json");
    let backfill_uuid = doc["events"]
        .as_array()
        .expect("events array")
        .iter()
        .find(|e| e["kind"] == "day_backfilled")
        .and_then(|e| e["uuid"].as_str())
        .expect("backfill event")
        .to_owned();
    store
        .revoke_event(backfill_uuid, at("2026-06-21", 11, 0))
        .expect("revoke backfill");
    let day = store.day_state("2026-06-21".into(), now).expect("state");
    assert!(!day.core_complete);
    assert!(!day.is_backfilled);

    let missing = store.revoke_event("no-such-uuid".into(), now);
    assert!(matches!(missing, Err(DromeError::EventNotFound(_))));
}

#[test]
fn events_table_rejects_update_and_delete() {
    let (_dir, path, store) = demo_store();
    drop(store);

    let conn = rusqlite::Connection::open(&path).expect("raw open");
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM events", [], |row| row.get(0))
        .expect("count");
    assert!(count > 0);

    let update = conn.execute("UPDATE events SET kind = 'tampered'", []);
    let err = update.expect_err("update must be rejected").to_string();
    assert!(err.contains("append-only"), "unexpected error: {err}");

    let delete = conn.execute("DELETE FROM events", []);
    let err = delete.expect_err("delete must be rejected").to_string();
    assert!(err.contains("append-only"), "unexpected error: {err}");

    // Same row count afterwards, and appends still work.
    let after: i64 = conn
        .query_row("SELECT COUNT(*) FROM events", [], |row| row.get(0))
        .expect("count");
    assert_eq!(count, after);
}

#[test]
fn weekly_extra_binds_to_week_and_never_gates_core() {
    let (_dir, _path, store) = demo_store();

    // Week 1 (days 1–7) got the extra via the day-3 backfill; days 1–12 are
    // core-complete regardless of the extra: it never gates core_complete.
    let now = at("2026-07-04", 10, 0);
    let day5 = store.day_state("2026-06-25".into(), now).expect("state");
    assert!(day5.core_complete);

    // Day 14 is in week 2 (days 8–14); the extra is still open there.
    let today = store.today(now).expect("today");
    assert_eq!(today.week_extras.len(), 1);
    let extra = &today.week_extras[0];
    assert_eq!(extra.extra_id, JOB_EXTRA_ID);
    assert_eq!(extra.week_index, 2);
    assert!(!extra.done);

    let r = store
        .log_extra_done(JOB_EXTRA_ID.into(), at("2026-07-04", 14, 0), None)
        .expect("log extra");
    assert!(r.week_extra_became_complete);
    assert!(!r.day_became_complete);

    // Logging it again in the same week does not re-fire the weekly moment.
    let r = store
        .log_extra_done(JOB_EXTRA_ID.into(), at("2026-07-04", 15, 0), None)
        .expect("log extra");
    assert!(!r.week_extra_became_complete);

    let today = store.today(at("2026-07-04", 16, 0)).expect("today");
    assert!(today.week_extras[0].done);

    let unknown = store.log_extra_done("meditation".into(), now, None);
    assert!(matches!(unknown, Err(DromeError::UnknownExtra(_))));
}

#[test]
fn csv_export_mirrors_the_sheet() {
    let (_dir, _path, store) = demo_store();
    let csv = store.export_csv(at("2026-07-04", 10, 0)).expect("csv");
    let lines: Vec<&str> = csv.lines().collect();
    assert_eq!(lines.len(), 15); // header + days 1..=14
    assert_eq!(
        lines[0],
        "Date,Day,Workout (Outside),Workout (Inside),Nutrition/Diet,No Junk or Alcohol,\
         Read (10 Pages),Progress Picture,Water (oz),Apply to 1 job/week,Complete"
    );
    // Day 3 carries the weekly extra; backfilled days export 0 oz (flags only).
    assert_eq!(
        lines[3],
        "2026-06-23,3,TRUE,TRUE,TRUE,TRUE,TRUE,TRUE,0,TRUE,TRUE"
    );
    // Day 13: everything but reading.
    assert_eq!(
        lines[13],
        "2026-07-03,13,TRUE,TRUE,TRUE,TRUE,FALSE,TRUE,0,,FALSE"
    );
    // Day 14 is live and still empty at 10:00.
    assert_eq!(
        lines[14],
        "2026-07-04,14,FALSE,FALSE,FALSE,FALSE,FALSE,FALSE,0,,FALSE"
    );
}

#[test]
fn json_export_carries_config_events_and_day_states() {
    let (_dir, _path, store) = demo_store();
    store
        .log_water(500, at("2026-07-04", 10, 0), None)
        .expect("log");
    let json = store.export_json(at("2026-07-04", 11, 0)).expect("json");
    let doc: serde_json::Value = serde_json::from_str(&json).expect("valid json");

    assert_eq!(doc["challenge"]["ruleset"], "flexible");
    assert_eq!(doc["challenge"]["start_date"], "2026-06-21");
    assert_eq!(doc["summary"]["days_complete_count"], 12);
    assert_eq!(doc["days"].as_array().expect("days").len(), 14);
    let events = doc["events"].as_array().expect("events");
    assert_eq!(
        events
            .iter()
            .filter(|e| e["kind"] == "day_backfilled")
            .count(),
        13
    );
    assert!(events.iter().any(|e| e["kind"] == "water_add"));
    assert!(events.iter().all(|e| e["revoked"] == false));
}

#[test]
fn purist_rules_workouts_and_fixed_goal() {
    let (_dir, _path, store) = open_store();
    store
        .create_challenge(challenge_cfg(
            RulesetKind::Purist,
            "2026-06-21",
            at("2026-06-21", 6, 0),
        ))
        .expect("create");
    let d = "2026-06-21";

    // Two 45-minute workouts only 2h apart (start times present): not enough.
    store
        .log_workout(45, true, None, Some(at(d, 8, 0)), at(d, 9, 0), None)
        .expect("workout 1");
    let r = store
        .log_workout(45, false, None, Some(at(d, 10, 0)), at(d, 11, 0), None)
        .expect("workout 2");
    assert!(r.day_state.outdoor_workout_done);
    assert!(!r.day_state.second_workout_done);

    // A third qualifying workout 5h after the first satisfies the 3h gap.
    let r = store
        .log_workout(50, false, None, Some(at(d, 13, 0)), at(d, 14, 0), None)
        .expect("workout 3");
    assert!(r.day_state.second_workout_done);

    // Sub-45-minute workouts never qualify in purist mode.
    let r = store
        .log_workout(44, true, None, None, at("2026-06-22", 9, 0), None)
        .expect("short workout");
    assert!(!r.day_state.outdoor_workout_done);

    // The purist goal is a fixed gallon, whatever the configured goal says.
    store
        .set_water_goal(2_000, at("2026-06-22", 10, 0))
        .expect("set goal");
    let r = store
        .log_water(2_000, at("2026-06-22", 11, 0), None)
        .expect("log water");
    assert_eq!(r.day_state.water_goal_ml, GALLON_ML);
    assert!(!r.day_state.water_done);
    let r = store
        .log_water(1_785, at("2026-06-22", 13, 0), None)
        .expect("log water");
    assert!(r.day_state.water_done);
}

#[test]
fn chug_guard_watches_the_trailing_hour() {
    let (_dir, _path, store) = open_store();
    store
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-06-21",
            at("2026-06-21", 6, 0),
        ))
        .expect("create");
    let t0 = at("2026-06-21", 10, 0);

    let r = store.log_water(800, t0, None).expect("log");
    assert!(r.chug_warning.is_none());

    // 30 minutes later: 800 already in the window, +300 crosses 1000.
    let r = store.log_water(300, plus_min(t0, 30), None).expect("log");
    let warning = r.chug_warning.expect("chug warning");
    assert!(warning.warn);
    assert_eq!(warning.trailing_60min_ml, 800);
    assert_eq!(warning.add_ml, 300);

    // 70 minutes after t0 the 800 has aged out; only the 300 remains.
    let check = store.check_chug(plus_min(t0, 70), 300).expect("check");
    assert!(!check.warn);
    assert_eq!(check.trailing_60min_ml, 300);

    // An event exactly 60 minutes old is outside the window.
    let check = store.check_chug(plus_min(t0, 89), 0).expect("check");
    assert_eq!(check.trailing_60min_ml, 300);
    let check = store.check_chug(plus_min(t0, 90), 0).expect("check");
    assert_eq!(check.trailing_60min_ml, 0);
    assert!(!check.warn);
}

#[test]
fn day_index_clamps_and_flags_out_of_range() {
    let (_dir, _path, store) = open_store();
    store
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-06-21",
            at("2026-06-19", 9, 0),
        ))
        .expect("create");

    // Before the start date.
    let before = at("2026-06-19", 10, 0);
    let summary = store.summary(before).expect("summary");
    assert_eq!(summary.today_day_index, 1);
    assert!(summary.today_out_of_range);
    assert_eq!(summary.today_raw_day_index, -1);
    let today = store.today(before).expect("today");
    assert!(today.out_of_range);
    assert_eq!(today.day.day_index, -1);
    assert!(!today.day.in_range);

    // Day 100, far past the end of the 75. The clamped index is for display;
    // the raw index is the honest "days lived" figure the reset flow's
    // deletion copy uses (out-of-range days still attribute events).
    let after = at("2026-09-28", 10, 0);
    let summary = store.summary(after).expect("summary");
    assert_eq!(summary.today_day_index, 75);
    assert!(summary.today_out_of_range);
    assert_eq!(summary.today_raw_day_index, 100);
    let day = store.day_state("2026-09-28".into(), after).expect("state");
    assert_eq!(day.day_index, 100);
    assert!(!day.in_range);
}

#[test]
fn share_card_shows_the_day_without_photo_refs() {
    let (_dir, _path, store) = demo_store();
    store
        .log_workout(
            45,
            true,
            Some("morning run".into()),
            None,
            at("2026-07-04", 8, 0),
            None,
        )
        .expect("workout");
    store
        .log_photo_done(
            Some("photos/day14.jpg".into()),
            at("2026-07-04", 9, 30),
            None,
        )
        .expect("photo");

    let card = store
        .share_card("2026-07-04".into(), at("2026-07-04", 10, 0))
        .expect("share card");
    assert_eq!(card.ruleset_label, "flexible");
    assert_eq!(card.day_index, 14);
    assert!(!card.is_backfilled);
    assert_eq!(card.current_run, 0);
    assert!(card.photo_done);
    assert_eq!(card.workouts.len(), 1);
    assert_eq!(card.workouts[0].duration_min, 45);
    assert!(card.workouts[0].outdoor);

    // Backfilled days are labelled honestly.
    let card = store
        .share_card("2026-07-02".into(), at("2026-07-04", 10, 0))
        .expect("share card");
    assert!(card.is_backfilled);
    assert!(card.core_complete);
}

#[test]
fn validation_and_missing_challenge_errors() {
    let (_dir, _path, store) = open_store();
    let now = at("2026-06-21", 10, 0);

    assert!(matches!(
        store.log_water(500, now, None),
        Err(DromeError::NoActiveChallenge)
    ));
    assert!(matches!(
        store.today(now),
        Err(DromeError::NoActiveChallenge)
    ));

    let mut bad = challenge_cfg(RulesetKind::Flexible, "2026-06-21", now);
    bad.waking_end_minutes = bad.waking_start_minutes;
    assert!(matches!(
        store.create_challenge(bad),
        Err(DromeError::InvalidArgument(_))
    ));

    store
        .create_challenge(challenge_cfg(RulesetKind::Flexible, "2026-06-21", now))
        .expect("create");
    assert!(matches!(
        store.log_water(0, now, None),
        Err(DromeError::InvalidArgument(_))
    ));
    assert!(matches!(
        store.log_water(500, now, Some("06/21/2026".into())),
        Err(DromeError::InvalidDate(_))
    ));
    assert!(matches!(
        store.day_state("not-a-date".into(), now),
        Err(DromeError::InvalidDate(_))
    ));
    assert!(matches!(
        store.calendar("2026-07-01".into(), "2026-06-01".into(), now),
        Err(DromeError::InvalidArgument(_))
    ));
}

#[test]
fn calendar_returns_briefs_for_the_backfill_grid() {
    let (_dir, _path, store) = demo_store();
    let briefs = store
        .calendar(
            "2026-06-21".into(),
            "2026-07-04".into(),
            at("2026-07-04", 10, 0),
        )
        .expect("calendar");
    assert_eq!(briefs.len(), 14);
    assert_eq!(briefs[0].date, "2026-06-21");
    assert_eq!(briefs[0].day_index, 1);
    assert!(briefs[0].core_complete);
    assert!(briefs[0].is_backfilled);
    assert!(!briefs[12].core_complete); // day 13
    assert!(!briefs[13].is_backfilled); // day 14 is live
}

#[test]
fn new_challenge_replaces_active_and_isolates_events() {
    let (_dir, _path, store) = open_store();
    let first = store
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-06-21",
            at("2026-06-21", 6, 0),
        ))
        .expect("create first");
    store
        .log_water(1_000, at("2026-06-21", 10, 0), None)
        .expect("log");

    let second = store
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-07-01",
            at("2026-07-01", 6, 0),
        ))
        .expect("create second");
    assert_ne!(first.id, second.id);

    let active = store
        .active_challenge()
        .expect("query")
        .expect("some challenge");
    assert_eq!(active.id, second.id);
    assert_eq!(active.start_date, "2026-07-01");

    // The first challenge's water does not leak into the second.
    let day = store
        .day_state("2026-06-21".into(), at("2026-07-01", 10, 0))
        .expect("state");
    assert_eq!(day.water_ml, 0);
}

#[test]
fn water_state_paces_across_the_waking_window() {
    let (_dir, _path, store) = demo_store();

    // 7:00 AM: window just opened, target 0, on pace with nothing logged.
    let s = store.water_state(at("2026-07-04", 7, 0)).expect("state");
    assert_eq!(s.total_ml, 0);
    assert_eq!(s.goal_ml, GALLON_ML);
    assert_eq!(s.pace_target_ml, 0);
    assert!(s.on_pace);
    assert!(!s.discourage_catch_up);

    // 2:30 PM is halfway through 7:00–22:00.
    let s = store.water_state(at("2026-07-04", 14, 30)).expect("state");
    assert_eq!(s.pace_target_ml, GALLON_ML / 2);
    assert!(!s.on_pace);

    // 9:00 PM, nothing logged: late catch-up is discouraged, never cheered.
    let s = store.water_state(at("2026-07-04", 21, 0)).expect("state");
    assert!(s.discourage_catch_up);

    // Final ounce: 100 ml left.
    store
        .log_water(GALLON_ML - 100, at("2026-07-04", 12, 0), None)
        .expect("log");
    let s = store.water_state(at("2026-07-04", 12, 30)).expect("state");
    assert_eq!(s.remaining_ml, 100);
    assert!(s.final_ounce);
}

#[test]
fn import_json_round_trips_into_a_fresh_store() {
    let (_d1, _p1, source) = demo_store();
    source
        .update_presets(
            vec![drome_core::ContainerPreset {
                id: "bottle".into(),
                name: "24 oz bottle".into(),
                ml: 710,
                sort_order: 0,
            }],
            at("2026-07-04", 9, 10),
        )
        .expect("presets");
    // A varied live tail: water, a signed correction, a no-junk attestation,
    // a workout, a revoked reading, a goal change, a closed day, and a
    // post-close log that rolls to the next day.
    source
        .log_water(710, at("2026-07-04", 10, 0), None)
        .expect("water");
    source
        .log_water_adjustment(-150, at("2026-07-04", 10, 30), None)
        .expect("adjustment");
    source
        .log_no_junk_ok(at("2026-07-04", 11, 0), None)
        .expect("no junk");
    source
        .log_workout(
            45,
            true,
            Some("run".into()),
            Some(at("2026-07-04", 7, 0)),
            at("2026-07-04", 8, 0),
            None,
        )
        .expect("workout");
    let r = source
        .log_reading("Deep Work".into(), 11, at("2026-07-04", 12, 0), None)
        .expect("read");
    source
        .revoke_event(r.event_uuid, at("2026-07-04", 12, 5))
        .expect("revoke");
    source
        .set_water_goal(3_000, at("2026-07-04", 13, 0))
        .expect("goal");
    source
        .close_day("2026-07-04".into(), at("2026-07-04", 22, 0))
        .expect("close");
    source
        .log_water(200, at("2026-07-04", 23, 0), None)
        .expect("late water");

    let now = at("2026-07-05", 9, 0);
    let snapshot = source.export_json(now).expect("export");

    let (_d2, _p2, dest) = open_store();
    dest.import_json(snapshot.clone()).expect("import");

    // Identical projections, day by day and in aggregate.
    for day in 1..=15 {
        let date = fixture_date(day);
        assert_eq!(
            source.day_state(date.clone(), now).expect("source state"),
            dest.day_state(date, now).expect("dest state")
        );
    }
    assert_eq!(
        source.summary(now).expect("summary"),
        dest.summary(now).expect("summary")
    );
    assert_eq!(
        source.export_csv(now).expect("csv"),
        dest.export_csv(now).expect("csv")
    );
    assert_eq!(
        source.container_presets().expect("presets"),
        dest.container_presets().expect("presets")
    );
    assert_eq!(
        source.extra_defs().expect("extras"),
        dest.extra_defs().expect("extras")
    );
    assert_eq!(
        source
            .active_challenge()
            .expect("query")
            .expect("challenge"),
        dest.active_challenge().expect("query").expect("challenge")
    );

    // A store with an active challenge refuses the import, typed.
    assert!(matches!(
        dest.import_json(snapshot.clone()),
        Err(DromeError::ActiveChallengeExists)
    ));

    // Garbage and unknown schema versions are typed errors too.
    let (_d3, _p3, fresh) = open_store();
    assert!(matches!(
        fresh.import_json("not json".into()),
        Err(DromeError::Serialization(_))
    ));
    let mut doc: serde_json::Value = serde_json::from_str(&snapshot).expect("parse");
    doc["export_schema_version"] = serde_json::json!(999);
    assert!(matches!(
        fresh.import_json(doc.to_string()),
        Err(DromeError::InvalidArgument(_))
    ));
    // Nothing was written by the failed imports.
    assert!(fresh.active_challenge().expect("query").is_none());
}

#[test]
fn diet_description_setter_trims_and_validates() {
    let (_dir, _path, store) = open_store();
    assert!(matches!(
        store.set_diet_description("keto".into(), at("2026-06-21", 8, 0)),
        Err(DromeError::NoActiveChallenge)
    ));

    store
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-06-21",
            at("2026-06-21", 8, 0),
        ))
        .expect("create");

    store
        .set_diet_description("  keto, no alcohol  ".into(), at("2026-06-21", 8, 5))
        .expect("set diet");
    let challenge = store.active_challenge().expect("query").expect("challenge");
    assert_eq!(
        challenge.diet_description.as_deref(),
        Some("keto, no alcohol")
    );

    // Blank clears the field.
    store
        .set_diet_description("   ".into(), at("2026-06-21", 8, 10))
        .expect("clear");
    let challenge = store.active_challenge().expect("query").expect("challenge");
    assert_eq!(challenge.diet_description, None);

    // 500 chars (after trimming) is fine; 501 is rejected.
    store
        .set_diet_description(format!(" {} ", "x".repeat(500)), at("2026-06-21", 8, 15))
        .expect("500 chars ok");
    assert!(matches!(
        store.set_diet_description("x".repeat(501), at("2026-06-21", 8, 20)),
        Err(DromeError::InvalidArgument(_))
    ));
    let challenge = store.active_challenge().expect("query").expect("challenge");
    assert_eq!(challenge.diet_description.map(|d| d.len()), Some(500));
}

#[test]
fn waking_window_setter_repaces_water_but_never_touches_day_state() {
    let (_dir, _path, store) = demo_store();
    let now = at("2026-07-04", 14, 30);

    // Defaults 7:00-22:00: 14:30 is halfway.
    let before = store.water_state(now).expect("water");
    assert_eq!(before.pace_target_ml, GALLON_ML / 2);
    let day13_before = store
        .day_state("2026-07-03".into(), now)
        .expect("day state");
    let summary_before = store.summary(now).expect("summary");

    // 6:00-21:00: same clock instant now sits 510 min into a 900-min window.
    store
        .set_waking_window(360, 1_260, now)
        .expect("set window");
    let after = store.water_state(now).expect("water");
    assert_eq!(after.pace_target_ml, GALLON_ML * 510 / 900);
    assert_ne!(after.pace_target_ml, before.pace_target_ml);

    // Attribution and completion are untouched: past days project identically.
    let day13_after = store
        .day_state("2026-07-03".into(), now)
        .expect("day state");
    assert_eq!(day13_before, day13_after);
    assert_eq!(summary_before, store.summary(now).expect("summary"));

    let challenge = store.active_challenge().expect("query").expect("challenge");
    assert_eq!(challenge.waking_start_minutes, 360);
    assert_eq!(challenge.waking_end_minutes, 1_260);

    // Validation: start < end and end <= 1440, typed errors otherwise.
    assert!(matches!(
        store.set_waking_window(600, 600, now),
        Err(DromeError::InvalidArgument(_))
    ));
    assert!(matches!(
        store.set_waking_window(700, 600, now),
        Err(DromeError::InvalidArgument(_))
    ));
    assert!(matches!(
        store.set_waking_window(0, 1_441, now),
        Err(DromeError::InvalidArgument(_))
    ));
    // A midnight-end window is accepted by create/import, so it must stay
    // editable here too (same bounds).
    store
        .set_waking_window(0, 1_440, now)
        .expect("midnight-end ok");
    let challenge = store.active_challenge().expect("query").expect("challenge");
    assert_eq!(challenge.waking_end_minutes, 1_440);
    store
        .set_waking_window(0, 1_439, now)
        .expect("edge window ok");

    let (_d2, _p2, empty) = open_store();
    assert!(matches!(
        empty.set_waking_window(360, 1_260, now),
        Err(DromeError::NoActiveChallenge)
    ));
}

#[test]
fn retroactive_water_is_bookkeeping_not_chug_intake() {
    let (_dir, _path, store) = demo_store();

    // 21:00: a full gallon logged for yesterday (day 13). The water lands on
    // day 13, but it is not current intake: no chug warning on the log itself.
    let r = store
        .log_water(
            GALLON_ML,
            at("2026-07-04", 21, 0),
            Some("2026-07-03".into()),
        )
        .expect("retroactive log");
    assert_eq!(r.day_state.date, "2026-07-03");
    assert_eq!(r.day_state.water_ml, GALLON_ML);
    assert!(r.chug_warning.is_none());

    // The backdated gallon must not poison the trailing-hour window: a
    // genuine sip a minute later checks clean and logs without a warning.
    let check = store
        .check_chug(at("2026-07-04", 21, 1), 200)
        .expect("check");
    assert!(!check.warn);
    assert_eq!(check.trailing_60min_ml, 0);
    let r = store
        .log_water(200, at("2026-07-04", 21, 2), None)
        .expect("log");
    assert!(r.chug_warning.is_none());

    // Genuine (no effective_date) intake still guards: 200 + 900 = 1100 ml
    // inside the hour crosses the 1000 ml threshold.
    let r = store
        .log_water(900, at("2026-07-04", 21, 30), None)
        .expect("log");
    let warning = r.chug_warning.expect("chug warning");
    assert!(warning.warn);
    assert_eq!(warning.trailing_60min_ml, 200);
    assert_eq!(warning.add_ml, 900);
}

#[test]
fn import_rejects_payloads_the_log_apis_reject() {
    let (_d1, _p1, source) = demo_store();
    source
        .log_water(500, at("2026-07-04", 10, 0), None)
        .expect("water");
    let snapshot = source.export_json(at("2026-07-04", 11, 0)).expect("export");
    let doc: serde_json::Value = serde_json::from_str(&snapshot).expect("parse");

    let with_event = |kind: &str, payload: serde_json::Value| {
        let mut tampered = doc.clone();
        tampered["events"]
            .as_array_mut()
            .expect("events array")
            .push(serde_json::json!({
                "uuid": format!("tampered-{kind}"),
                "logged_at_epoch": 1_782_000_000i64,
                "tz_offset_secs": 0,
                "kind": kind,
                "payload": payload,
            }));
        tampered.to_string()
    };

    let (_d2, _p2, dest) = open_store();
    let cases = [
        // A zero goal would silently auto-complete water for all later days.
        with_event("goal_changed", serde_json::json!({ "water_goal_ml": 0 })),
        with_event("water_add", serde_json::json!({ "ml": -500 })),
        with_event("water_add", serde_json::json!({ "ml": 10_001 })),
        // Adjustments are negative-only and bounded like adds.
        with_event("water_adjust", serde_json::json!({ "ml": 0 })),
        with_event("water_adjust", serde_json::json!({ "ml": 200 })),
        with_event("water_adjust", serde_json::json!({ "ml": -10_001 })),
        with_event(
            "workout",
            serde_json::json!({ "duration_min": 0, "outdoor": true }),
        ),
        with_event(
            "reading",
            serde_json::json!({ "book_title": "Deep Work", "pages": 10_001 }),
        ),
        // Projection::build never parses photo payloads (it only flips the
        // day flag), so import must: a malformed ref would otherwise poison
        // revoke_task(Photo) with an untyped serialization error.
        with_event("photo_done", serde_json::json!({ "photo_ref": 42 })),
    ];
    for tampered in cases {
        assert!(matches!(
            dest.import_json(tampered),
            Err(DromeError::InvalidArgument(_))
        ));
        // Nothing was written by the rejected import.
        assert!(dest.active_challenge().expect("query").is_none());
    }

    // The untampered snapshot still imports cleanly afterwards.
    dest.import_json(snapshot).expect("import");
    assert!(dest.active_challenge().expect("query").is_some());
}

#[test]
fn water_log_matches_day_projection_on_a_mixed_day() {
    let (_dir, _path, store) = demo_store();
    let day = "2026-07-04"; // fixture day 14

    // A mixed day 14: two live pours with a revoke in between, a live pour
    // after the revoke, a signed correction, a post-cutoff-window pour at
    // 1:30 AM of the next calendar date (attributes back to day 14), and a
    // retroactive pour logged the next day with an explicit effective_date.
    let a = store.log_water(500, at(day, 8, 0), None).expect("pour a");
    let b = store.log_water(946, at(day, 10, 0), None).expect("pour b");
    store
        .revoke_event(b.event_uuid.clone(), at(day, 10, 5))
        .expect("revoke b mid-list");
    let c = store.log_water(700, at(day, 12, 0), None).expect("pour c");
    let adj = store
        .log_water_adjustment(-200, at(day, 12, 30), None)
        .expect("correction");
    let d = store
        .log_water(400, at("2026-07-05", 1, 30), None)
        .expect("pour d (1:30 AM, 4:00 cutoff -> day 14)");
    let e = store
        .log_water(300, at("2026-07-05", 9, 0), Some(day.into()))
        .expect("pour e (retroactive)");

    let now = at("2026-07-05", 10, 0);
    let entries = store.water_log(day.into(), now).expect("water log");

    // Revoked pour absent; the correction appears in place, signed; order is
    // logged_at ascending; retro only on e.
    let uuids: Vec<&str> = entries.iter().map(|e| e.event_uuid.as_str()).collect();
    assert_eq!(
        uuids,
        vec![
            a.event_uuid.as_str(),
            c.event_uuid.as_str(),
            adj.event_uuid.as_str(),
            d.event_uuid.as_str(),
            e.event_uuid.as_str(),
        ]
    );
    assert_eq!(
        entries.iter().map(|e| e.retro).collect::<Vec<_>>(),
        vec![false, false, false, false, true]
    );
    assert_eq!(entries[0].ml, 500);
    assert_eq!(entries[2].ml, -200);
    assert_eq!(entries[3].logged_at, at("2026-07-05", 1, 30));

    // Entries always sum to the day projection's water total.
    let day_state = store.day_state(day.into(), now).expect("day state");
    assert_eq!(
        entries.iter().map(|e| e.ml).sum::<i64>(),
        day_state.water_ml
    );
    assert_eq!(day_state.water_ml, 500 + 700 - 200 + 400 + 300);

    // None of the pours leaked onto 2026-07-05.
    let next = store.water_log("2026-07-05".into(), now).expect("log");
    assert!(next.is_empty());
}

#[test]
fn water_log_excludes_backfill_flags_and_is_empty_for_empty_days() {
    let (_dir, _path, store) = demo_store();
    let now = at("2026-07-04", 10, 0);

    // Day 12 is backfilled with water = true, but the flag carries no
    // quantity: the pour log stays empty (and still sums to water_ml == 0).
    let day12 = store
        .day_state("2026-07-02".into(), now)
        .expect("day state");
    assert!(day12.water_done && day12.is_backfilled);
    assert_eq!(day12.water_ml, 0);
    let entries = store.water_log("2026-07-02".into(), now).expect("log");
    assert!(entries.is_empty());

    // A plain empty day (day 14, nothing logged yet) -> empty vec.
    let entries = store.water_log("2026-07-04".into(), now).expect("log");
    assert!(entries.is_empty());

    assert!(matches!(
        store.water_log("not-a-date".into(), now),
        Err(DromeError::InvalidDate(_))
    ));
}

#[test]
fn current_run_ignores_days_past_the_challenge_end() {
    let (_dir, _path, store) = open_store();
    store
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-06-21",
            at("2026-06-21", 8, 0),
        ))
        .expect("create");

    // Every day complete through day 77 — two days past the 75-day end.
    let mut date = drome_core::time::parse_date("2026-06-21").expect("date");
    let mut days = Vec::new();
    for _ in 0..77 {
        days.push(BackfilledDay {
            date: drome_core::time::format_date(date),
            water: true,
            outdoor_workout: true,
            second_workout: true,
            reading: true,
            diet: true,
            no_junk: true,
            photo: true,
            extra_ids: vec![],
        });
        date = date.succ_opt().expect("date in range");
    }
    store
        .backfill_days(days, at("2026-09-05", 9, 0))
        .expect("backfill");

    // Today is day 77 (2026-09-05): the run counts only in-range days, so it
    // can exceed neither length_days nor days_complete_count.
    let now = at("2026-09-05", 12, 0);
    let summary = store.summary(now).expect("summary");
    assert_eq!(summary.days_complete_count, 75);
    assert_eq!(summary.current_run, 75); // not 77
    assert!(summary.today_out_of_range);
    assert!(summary.current_run <= summary.length_days);
    assert!(summary.current_run <= summary.days_complete_count);
}

#[test]
fn water_adjustment_bounds_and_over_correction() {
    let (_dir, _path, store) = demo_store();
    let day = "2026-07-04";

    // Bounds: zero, positive, and beyond -10_000 are all rejected.
    for ml in [0, 1, 500, -10_001] {
        assert!(
            matches!(
                store.log_water_adjustment(ml, at(day, 9, 0), None),
                Err(DromeError::InvalidArgument(_))
            ),
            "ml {ml} should be out of bounds"
        );
    }

    // Nothing logged yet: any adjustment over-corrects.
    assert!(matches!(
        store.log_water_adjustment(-1, at(day, 9, 30), None),
        Err(DromeError::InvalidArgument(_))
    ));

    store.log_water(500, at(day, 10, 0), None).expect("add");
    // Beyond the day's current total: rejected (the UI clamps, the core enforces).
    assert!(matches!(
        store.log_water_adjustment(-501, at(day, 10, 5), None),
        Err(DromeError::InvalidArgument(_))
    ));
    // Up to the total: accepted. Never a chug warning, never a completion.
    let r = store
        .log_water_adjustment(-200, at(day, 10, 6), None)
        .expect("adjust");
    assert_eq!(r.day_state.water_ml, 300);
    assert!(!r.day_became_complete);
    assert!(r.chug_warning.is_none());
    let r = store
        .log_water_adjustment(-300, at(day, 10, 7), None)
        .expect("adjust to zero");
    assert_eq!(r.day_state.water_ml, 0);
    assert!(matches!(
        store.log_water_adjustment(-1, at(day, 10, 8), None),
        Err(DromeError::InvalidArgument(_))
    ));

    // Retroactive adjustments validate against the TARGET day's total, and a
    // backfill water flag carries no quantity to correct (day 13's total is 0).
    assert!(matches!(
        store.log_water_adjustment(-1, at(day, 11, 0), Some("2026-07-03".into())),
        Err(DromeError::InvalidArgument(_))
    ));
}

#[test]
fn adjustment_nets_the_chug_window_and_floors_at_zero() {
    let (_dir, _path, store) = demo_store();
    let t0 = at("2026-07-04", 10, 0);

    // A fat-fingered 950: the next 200 would cross the 1000 ml threshold.
    store.log_water(950, t0, None).expect("add");
    let check = store.check_chug(plus_min(t0, 5), 200).expect("check");
    assert!(check.warn);

    // Honestly correcting the fat-finger clears the false warning.
    store
        .log_water_adjustment(-900, plus_min(t0, 6), None)
        .expect("adjust");
    let check = store.check_chug(plus_min(t0, 7), 200).expect("check");
    assert!(!check.warn);
    assert_eq!(check.trailing_60min_ml, 50);

    // 65 min later the add has aged out of the window but the correction has
    // not: the running fold clips it at 0 instead of going negative, so
    // corrections never create extra headroom to chug against.
    let check = store.check_chug(plus_min(t0, 65), 1_000).expect("check");
    assert_eq!(check.trailing_60min_ml, 0);
    assert!(!check.warn);
    let check = store.check_chug(plus_min(t0, 65), 1_001).expect("check");
    assert!(check.warn);

    // A retroactive adjustment (explicit effective_date) is bookkeeping and
    // never nets against the live window.
    store.log_water(800, plus_min(t0, 70), None).expect("add");
    store
        .log_water_adjustment(-800, plus_min(t0, 71), Some("2026-07-04".into()))
        .expect("retro adjust");
    let check = store.check_chug(plus_min(t0, 72), 300).expect("check");
    assert_eq!(check.trailing_60min_ml, 800);
    assert!(check.warn);
}

#[test]
fn revoking_adjustments_and_adds_keeps_water_floored() {
    let (_dir, _path, store) = demo_store();
    let day = "2026-07-04";

    let add = store.log_water(1_000, at(day, 8, 0), None).expect("add");
    let adj = store
        .log_water_adjustment(-400, at(day, 8, 30), None)
        .expect("adjust");
    assert_eq!(adj.day_state.water_ml, 600);

    // Revoking the adjustment restores the water it subtracted.
    store
        .revoke_event(adj.event_uuid, at(day, 9, 0))
        .expect("revoke adjustment");
    let state = store.day_state(day.into(), at(day, 9, 5)).expect("state");
    assert_eq!(state.water_ml, 1_000);

    // Adjust away the full total, then revoke the UNDERLYING ADD: the ledger
    // sums to -1000 but the day's fold clips the orphaned correction at 0 —
    // the log-time over-correction guard can't be gamed into a negative total.
    let r = store
        .log_water_adjustment(-1_000, at(day, 9, 30), None)
        .expect("adjust all");
    assert_eq!(r.day_state.water_ml, 0);
    store
        .revoke_event(add.event_uuid, at(day, 10, 0))
        .expect("revoke add");
    let state = store.day_state(day.into(), at(day, 10, 5)).expect("state");
    assert_eq!(state.water_ml, 0);
    assert!(!state.water_done);

    // The ledger stays honest: entries sum to the raw signed total while the
    // day folds with the running floor.
    let entries = store.water_log(day.into(), at(day, 10, 10)).expect("log");
    assert_eq!(entries.iter().map(|e| e.ml).sum::<i64>(), -1_000);

    // And the aggregate total floors per-day too: never negative.
    let summary = store.summary(at(day, 10, 15)).expect("summary");
    assert_eq!(summary.total_water_ml, 0);

    // The orphaned correction is spent, not banked: a fresh pour counts in
    // full instead of repaying hidden debt.
    let r = store
        .log_water(500, at(day, 10, 20), None)
        .expect("new pour");
    assert_eq!(r.day_state.water_ml, 500);
    let entries = store.water_log(day.into(), at(day, 10, 25)).expect("log");
    assert_eq!(entries.iter().map(|e| e.ml).sum::<i64>(), -500);
    let summary = store.summary(at(day, 10, 30)).expect("summary");
    assert_eq!(summary.total_water_ml, 500);
}

#[test]
fn orphaned_correction_never_swallows_later_pours() {
    // The shipped-UI sequence: preset pour 32 oz, drag Jerome down 32 oz
    // (correction), then swipe-remove the pour row (revoke the ADD). The
    // correction is left orphaned; later real pours must count in full —
    // regression for the phantom-debt bug where the day stayed at 0 until
    // 946 ml had been silently repaid.
    let (_dir, _path, store) = demo_store();
    let day = "2026-07-04";

    let add = store.log_water(946, at(day, 9, 0), None).expect("pour");
    store
        .log_water_adjustment(-946, at(day, 9, 10), None)
        .expect("correction");
    store
        .revoke_event(add.event_uuid, at(day, 9, 20))
        .expect("revoke the corrected pour");

    let r = store.log_water(500, at(day, 10, 0), None).expect("pour");
    assert_eq!(r.day_state.water_ml, 500, "the new pour must count in full");
    let r = store.log_water(946, at(day, 11, 0), None).expect("pour");
    assert_eq!(r.day_state.water_ml, 1_446);

    // The visible ledger keeps the raw history; the day total simply never
    // dips below zero mid-fold.
    let entries = store.water_log(day.into(), at(day, 11, 30)).expect("log");
    assert_eq!(
        entries.iter().map(|e| e.ml).collect::<Vec<_>>(),
        vec![-946, 500, 946]
    );
}

#[test]
fn stale_correction_never_masks_fresh_intake_from_the_chug_guard() {
    let (_dir, _path, store) = demo_store();
    let t0 = at("2026-07-04", 8, 0);

    // A double-logged morning pour, honestly corrected half an hour later.
    store.log_water(950, t0, None).expect("add");
    store
        .log_water_adjustment(-900, plus_min(t0, 30), None)
        .expect("correction");

    // An hour on, the pour has aged out but the correction is still in the
    // window; it must not bank headroom against fresh intake.
    let r = store.log_water(1_000, plus_min(t0, 61), None).expect("add");
    assert!(r.chug_warning.is_none()); // exactly at the limit, window truly empty
    let check = store.check_chug(plus_min(t0, 65), 900).expect("check");
    assert_eq!(check.trailing_60min_ml, 1_000);
    assert!(check.warn, "1.9 L inside five minutes must warn");
}

#[test]
fn six_tasks_gate_completion_and_no_junk_last_fires_once() {
    let (_dir, _path, store) = demo_store();
    let d = "2026-07-04";

    store
        .log_water(GALLON_ML, at(d, 9, 0), None)
        .expect("water");
    store
        .log_water(200, at(d, 11, 0), None)
        .expect("more water");
    store
        .log_workout(45, true, None, None, at(d, 10, 0), None)
        .expect("outdoor workout");
    store
        .log_workout(30, false, None, None, at(d, 12, 0), None)
        .expect("second workout");
    store
        .log_reading("Deep Work".into(), 10, at(d, 13, 0), None)
        .expect("reading");
    store.log_diet_ok(at(d, 14, 0), None).expect("diet");
    let r = store
        .log_photo_done(None, at(d, 15, 0), None)
        .expect("photo");

    // All of the original five done, diet included — without the no-junk
    // attestation the day must NOT be complete.
    assert!(r.day_state.diet_done);
    assert!(!r.day_state.no_junk_done);
    assert!(!r.day_state.core_complete);
    assert!(!r.day_became_complete);

    // The attestation is the last open task: it fires the moment, once.
    let r = store.log_no_junk_ok(at(d, 16, 0), None).expect("no junk");
    assert!(r.day_state.no_junk_done);
    assert!(r.day_state.core_complete);
    assert!(r.day_became_complete);
    let r = store
        .log_no_junk_ok(at(d, 16, 30), None)
        .expect("no junk again");
    assert!(!r.day_became_complete);

    // An adjustment can only lower water: it never fires the moment, and a
    // still-above-goal day stays complete.
    let r = store
        .log_water_adjustment(-100, at(d, 17, 0), None)
        .expect("adjust");
    assert!(r.day_state.core_complete);
    assert!(!r.day_became_complete);

    let summary = store.summary(at(d, 18, 0)).expect("summary");
    assert_eq!(summary.days_complete_count, 13);
}

#[test]
fn purist_requires_the_no_junk_attestation_too() {
    let (_dir, _path, store) = open_store();
    store
        .create_challenge(challenge_cfg(
            RulesetKind::Purist,
            "2026-06-21",
            at("2026-06-21", 6, 0),
        ))
        .expect("create");
    store
        .backfill_days(
            vec![BackfilledDay {
                date: "2026-06-21".into(),
                water: true,
                outdoor_workout: true,
                second_workout: true,
                reading: true,
                diet: true,
                no_junk: false,
                photo: true,
                extra_ids: vec![],
            }],
            at("2026-06-22", 9, 0),
        )
        .expect("backfill");

    let now = at("2026-06-22", 10, 0);
    let day = store.day_state("2026-06-21".into(), now).expect("state");
    assert!(day.diet_done);
    assert!(!day.no_junk_done);
    assert!(!day.core_complete);

    let r = store
        .log_no_junk_ok(at("2026-06-22", 10, 30), Some("2026-06-21".into()))
        .expect("attest");
    assert!(r.day_state.no_junk_done);
    assert!(r.day_state.core_complete);
    assert!(r.day_became_complete);
}

#[test]
fn legacy_backfill_payloads_default_no_junk_to_diet() {
    // Two backfilled days whose explicit no_junk is the OPPOSITE of diet, so
    // the legacy fallback is distinguishable from reading the stored key.
    let (_d1, _p1, source) = open_store();
    source
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-06-21",
            at("2026-06-23", 9, 0),
        ))
        .expect("create");
    source
        .backfill_days(
            vec![
                BackfilledDay {
                    date: "2026-06-21".into(),
                    water: true,
                    outdoor_workout: true,
                    second_workout: true,
                    reading: true,
                    diet: true,
                    no_junk: false,
                    photo: true,
                    extra_ids: vec![],
                },
                BackfilledDay {
                    date: "2026-06-22".into(),
                    water: true,
                    outdoor_workout: true,
                    second_workout: true,
                    reading: true,
                    diet: false,
                    no_junk: true,
                    photo: true,
                    extra_ids: vec![],
                },
            ],
            at("2026-06-23", 9, 5),
        )
        .expect("backfill");
    let now = at("2026-06-23", 10, 0);

    // With the key present, the stored value wins — no diet coupling.
    let day1 = source.day_state("2026-06-21".into(), now).expect("state");
    assert!(day1.diet_done && !day1.no_junk_done && !day1.core_complete);
    let day2 = source.day_state("2026-06-22".into(), now).expect("state");
    assert!(!day2.diet_done && day2.no_junk_done && !day2.core_complete);

    // Strip the no_junk keys, simulating a snapshot exported before the
    // no-junk task existed, and restore it into a fresh store.
    let snapshot = source.export_json(now).expect("export");
    let mut doc: serde_json::Value = serde_json::from_str(&snapshot).expect("parse");
    for e in doc["events"].as_array_mut().expect("events") {
        if e["kind"] == "day_backfilled" {
            e["payload"]
                .as_object_mut()
                .expect("payload object")
                .remove("no_junk");
        }
    }
    let (_d2, _p2, dest) = open_store();
    dest.import_json(doc.to_string()).expect("legacy import");

    // Without the key, no_junk inherits diet (the sheet kept them equal).
    let day1 = dest.day_state("2026-06-21".into(), now).expect("state");
    assert!(day1.diet_done && day1.no_junk_done && day1.core_complete);
    let day2 = dest.day_state("2026-06-22".into(), now).expect("state");
    assert!(!day2.diet_done && !day2.no_junk_done && !day2.core_complete);
}

#[test]
fn pre_no_junk_stores_keep_live_logged_days_complete() {
    // A store whose whole log predates the no-junk task (schema-v1 rows, no
    // no_junk_ok anywhere): its LIVE-logged complete days must stay complete
    // after upgrading, exactly like legacy backfill payloads do — otherwise
    // an upgrade silently collapses days_complete_count and the current run.
    let (_d1, _p1, source) = open_store();
    source
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-06-21",
            at("2026-06-21", 6, 0),
        ))
        .expect("create");
    let d1 = "2026-06-21";
    source
        .log_water(GALLON_ML, at(d1, 9, 0), None)
        .expect("water");
    source
        .log_workout(45, true, None, None, at(d1, 10, 0), None)
        .expect("outdoor");
    source
        .log_workout(30, false, None, None, at(d1, 12, 0), None)
        .expect("second");
    source
        .log_reading("Deep Work".into(), 10, at(d1, 13, 0), None)
        .expect("reading");
    source.log_diet_ok(at(d1, 14, 0), None).expect("diet");
    source
        .log_photo_done(None, at(d1, 15, 0), None)
        .expect("photo");

    // Rewrite the export as a five-task-era store: v1 rows only.
    let snapshot = source.export_json(at("2026-06-22", 9, 0)).expect("export");
    let mut doc: serde_json::Value = serde_json::from_str(&snapshot).expect("parse");
    for e in doc["events"].as_array_mut().expect("events") {
        e["schema_version"] = serde_json::json!(1);
    }
    let (_d2, _p2, store) = open_store();
    store.import_json(doc.to_string()).expect("legacy import");

    // Nothing logged since the upgrade: the whole log is pre-era, so the
    // lived day inherits its diet attestation and stays complete.
    let now = at("2026-06-22", 10, 0);
    let day1 = store.day_state(d1.into(), now).expect("state");
    assert!(day1.diet_done && day1.no_junk_done && day1.core_complete);
    assert!(!day1.is_backfilled);
    assert_eq!(store.summary(now).expect("summary").days_complete_count, 1);

    // The first post-upgrade write pins the boundary at ITS day: day 1 stays
    // complete, but from that day on the attestation is genuinely required.
    let d2 = "2026-06-22";
    store
        .log_water(GALLON_ML, at(d2, 9, 0), None)
        .expect("water");
    store
        .log_workout(45, true, None, None, at(d2, 10, 0), None)
        .expect("outdoor");
    store
        .log_workout(30, false, None, None, at(d2, 12, 0), None)
        .expect("second");
    store
        .log_reading("Deep Work".into(), 10, at(d2, 13, 0), None)
        .expect("reading");
    store.log_diet_ok(at(d2, 14, 0), None).expect("diet");
    let r = store
        .log_photo_done(None, at(d2, 15, 0), None)
        .expect("photo");
    assert!(r.day_state.diet_done);
    assert!(
        !r.day_state.no_junk_done,
        "post-upgrade days need the attestation"
    );
    assert!(!r.day_state.core_complete);
    let day1 = store.day_state(d1.into(), at(d2, 15, 30)).expect("state");
    assert!(
        day1.no_junk_done && day1.core_complete,
        "pre-era day keeps its completion after new logs"
    );

    let r = store.log_no_junk_ok(at(d2, 16, 0), None).expect("attest");
    assert!(r.day_state.core_complete);
    assert!(r.day_became_complete);
    let summary = store.summary(at(d2, 17, 0)).expect("summary");
    assert_eq!(summary.days_complete_count, 2);
    assert_eq!(summary.current_run, 2);
}

#[test]
fn revoke_task_toggles_each_kind_and_the_moment_refires_on_recompletion() {
    let (_dir, _path, store) = demo_store();
    let d = "2026-07-04";

    // Complete day 14 with live events (the photo carries a ref).
    store
        .log_water(GALLON_ML, at(d, 9, 0), None)
        .expect("water");
    store
        .log_workout(45, true, None, None, at(d, 10, 0), None)
        .expect("outdoor");
    store
        .log_workout(30, false, None, None, at(d, 11, 0), None)
        .expect("second");
    store
        .log_reading("Deep Work".into(), 12, at(d, 12, 0), None)
        .expect("reading");
    store.log_diet_ok(at(d, 13, 0), None).expect("diet");
    store.log_no_junk_ok(at(d, 13, 30), None).expect("no junk");
    let r = store
        .log_photo_done(Some("photos/day14.jpg".into()), at(d, 14, 0), None)
        .expect("photo");
    assert!(r.day_became_complete);
    assert!(
        r.revoked_photo_refs.is_empty(),
        "plain logs never carry refs"
    );

    // Every live-logged task reports revocable; nothing extra does.
    let day = r.day_state;
    assert!(day.revocable.diet);
    assert!(day.revocable.no_junk);
    assert!(day.revocable.photo);
    assert!(day.revocable.reading);
    assert!(day.revocable.extra_ids.is_empty());

    // Diet: off honestly (no moments, no chug warning), then back on — the
    // completion moment fires AGAIN on the re-completing log. Intended: that
    // log is a genuine incomplete -> complete flip, and celebrating it is
    // the honest reading of the day's current state.
    let r = store
        .revoke_task(d.into(), RevocableTask::Diet, at(d, 15, 0))
        .expect("revoke diet");
    assert!(!r.day_state.diet_done);
    assert!(!r.day_state.core_complete);
    assert!(!r.day_state.revocable.diet);
    assert!(!r.day_became_complete);
    assert!(!r.week_extra_became_complete);
    assert!(r.chug_warning.is_none());
    assert!(r.revoked_photo_refs.is_empty());
    let r = store.log_diet_ok(at(d, 15, 5), None).expect("re-attest");
    assert!(r.day_state.core_complete);
    assert!(r.day_became_complete, "re-completion is a genuine flip");

    // No-junk round trip.
    let r = store
        .revoke_task(d.into(), RevocableTask::NoJunk, at(d, 15, 10))
        .expect("revoke no-junk");
    assert!(!r.day_state.no_junk_done);
    assert!(!r.day_state.core_complete);
    let r = store
        .log_no_junk_ok(at(d, 15, 15), None)
        .expect("re-attest no-junk");
    assert!(r.day_became_complete);

    // Photo: the revoke surfaces the orphaned ref for file cleanup.
    let r = store
        .revoke_task(d.into(), RevocableTask::Photo, at(d, 15, 20))
        .expect("revoke photo");
    assert!(!r.day_state.photo_done);
    assert_eq!(r.revoked_photo_refs, vec!["photos/day14.jpg".to_string()]);
    let r = store
        .log_photo_done(None, at(d, 15, 25), None)
        .expect("re-photo");
    assert!(r.day_became_complete);
    // A ref-less photo revokes with no ref to clean up.
    let r = store
        .revoke_task(d.into(), RevocableTask::Photo, at(d, 15, 30))
        .expect("revoke ref-less photo");
    assert!(r.revoked_photo_refs.is_empty());
    store
        .log_photo_done(None, at(d, 15, 35), None)
        .expect("re-photo again");

    // Reading (single entry): the whole task flips off and back on.
    let r = store
        .revoke_task(d.into(), RevocableTask::Reading, at(d, 16, 0))
        .expect("revoke reading");
    assert!(!r.day_state.reading_done);
    assert_eq!(r.day_state.reading_pages, 0);
    assert!(!r.day_state.revocable.reading);
    let r = store
        .log_reading("Deep Work".into(), 10, at(d, 16, 5), None)
        .expect("re-read");
    assert!(r.day_became_complete);

    let summary = store.summary(at(d, 17, 0)).expect("summary");
    assert_eq!(summary.days_complete_count, 13); // 1..=12 + day 14
}

#[test]
fn revoke_task_rejects_backfill_flags_and_empty_days() {
    let (_dir, _path, store) = demo_store();
    let now = at("2026-07-04", 10, 0);

    // Day 12 is complete via backfill flags only: nothing is peelable, and
    // the day's revocable record says so up front.
    let day12 = store
        .day_state("2026-07-02".into(), now)
        .expect("day state");
    assert!(day12.diet_done && day12.no_junk_done && day12.photo_done && day12.reading_done);
    assert!(!day12.revocable.diet);
    assert!(!day12.revocable.no_junk);
    assert!(!day12.revocable.photo);
    assert!(!day12.revocable.reading);
    assert!(day12.revocable.extra_ids.is_empty());
    for kind in [
        RevocableTask::Diet,
        RevocableTask::NoJunk,
        RevocableTask::Photo,
        RevocableTask::Reading,
    ] {
        assert!(
            matches!(
                store.revoke_task("2026-07-02".into(), kind.clone(), now),
                Err(DromeError::TaskNotRevocable(_))
            ),
            "backfill-flag {kind:?} must not be revocable"
        );
    }

    // Day 3's weekly extra came from the backfill payload: same rule.
    let day3 = store
        .day_state("2026-06-23".into(), now)
        .expect("day state");
    assert!(day3.extras_done.contains(&JOB_EXTRA_ID.to_string()));
    assert!(day3.revocable.extra_ids.is_empty());
    assert!(matches!(
        store.revoke_task(
            "2026-06-23".into(),
            RevocableTask::Extra {
                id: JOB_EXTRA_ID.into()
            },
            now
        ),
        Err(DromeError::TaskNotRevocable(_))
    ));

    // Day 14 is empty: nothing to revoke there either.
    assert!(matches!(
        store.revoke_task("2026-07-04".into(), RevocableTask::Diet, now),
        Err(DromeError::TaskNotRevocable(_))
    ));

    // A live diet on day 14 never satisfies a revoke for another date.
    store
        .log_diet_ok(at("2026-07-04", 11, 0), None)
        .expect("diet");
    assert!(matches!(
        store.revoke_task(
            "2026-07-03".into(),
            RevocableTask::Diet,
            at("2026-07-04", 11, 5)
        ),
        Err(DromeError::TaskNotRevocable(_))
    ));

    assert!(matches!(
        store.revoke_task("not-a-date".into(), RevocableTask::Diet, now),
        Err(DromeError::InvalidDate(_))
    ));
}

#[test]
fn revoke_task_reading_peels_newest_first() {
    let (_dir, _path, store) = demo_store();
    let d = "2026-07-04";
    store
        .log_reading("Deep Work".into(), 6, at(d, 9, 0), None)
        .expect("morning read");
    store
        .log_reading("Deep Work".into(), 7, at(d, 20, 0), None)
        .expect("evening read");
    let day = store.day_state(d.into(), at(d, 21, 0)).expect("day state");
    assert_eq!(day.reading_pages, 13);
    assert!(day.reading_done);

    // First revoke peels the NEWEST entry (the evening 7 pages).
    let r = store
        .revoke_task(d.into(), RevocableTask::Reading, at(d, 21, 5))
        .expect("revoke newest");
    assert_eq!(r.day_state.reading_pages, 6);
    assert!(!r.day_state.reading_done);
    assert!(
        r.day_state.revocable.reading,
        "the morning entry is still peelable"
    );

    // Second revoke peels the remaining morning entry; a third has nothing.
    let r = store
        .revoke_task(d.into(), RevocableTask::Reading, at(d, 21, 10))
        .expect("revoke remaining");
    assert_eq!(r.day_state.reading_pages, 0);
    assert!(!r.day_state.revocable.reading);
    assert!(matches!(
        store.revoke_task(d.into(), RevocableTask::Reading, at(d, 21, 15)),
        Err(DromeError::TaskNotRevocable(_))
    ));
}

#[test]
fn revoke_task_clears_stacked_attest_events_in_one_call() {
    // Attest kinds are idempotent, not additive: "mark photo taken" followed
    // by attaching a picture leaves TWO live photo events on the date, and a
    // single un-mark must flip the task to not-done (revoking only the
    // newest would silently delete the attach's JPEG while the day still
    // read done). Reading stays additive and keeps its one-entry peel.
    let (_dir, _path, store) = demo_store();
    let d = "2026-07-04";

    store.log_photo_done(None, at(d, 9, 0), None).expect("mark");
    store
        .log_photo_done(Some("photos/day14.jpg".into()), at(d, 9, 5), None)
        .expect("attach");
    let r = store
        .revoke_task(d.into(), RevocableTask::Photo, at(d, 10, 0))
        .expect("revoke photo");
    assert!(!r.day_state.photo_done, "one un-mark flips the task off");
    assert!(!r.day_state.revocable.photo);
    assert_eq!(r.revoked_photo_refs, vec!["photos/day14.jpg".to_string()]);

    // Same for a doubled diet attest (e.g. board tile + yesterday sheet).
    store.log_diet_ok(at(d, 11, 0), None).expect("diet");
    store.log_diet_ok(at(d, 11, 5), None).expect("diet again");
    let r = store
        .revoke_task(d.into(), RevocableTask::Diet, at(d, 11, 10))
        .expect("revoke diet");
    assert!(!r.day_state.diet_done);
    assert!(!r.day_state.revocable.diet);

    // A doubled extra clears in one call too, and only on the target date.
    store
        .log_extra_done(JOB_EXTRA_ID.into(), at(d, 12, 0), None)
        .expect("extra");
    store
        .log_extra_done(JOB_EXTRA_ID.into(), at(d, 12, 5), None)
        .expect("extra again");
    let r = store
        .revoke_task(
            d.into(),
            RevocableTask::Extra {
                id: JOB_EXTRA_ID.into(),
            },
            at(d, 12, 10),
        )
        .expect("revoke extra");
    assert!(r.day_state.extras_done.is_empty());
    assert!(r.day_state.revocable.extra_ids.is_empty());
}

#[test]
fn today_reports_the_date_backing_each_week_extra() {
    let (_dir, _path, store) = demo_store();
    let d = "2026-07-04"; // day 14 = week 2 (days 8-14)

    // Week 2 is open: no done date.
    let today = store.today(at(d, 9, 0)).expect("today");
    assert!(!today.week_extras[0].done);
    assert_eq!(today.week_extras[0].done_on_date, None);

    // Re-backfill day 8 with the extra as a flag: the week reads done and
    // the flag date is reported (there is no live event anywhere).
    store
        .backfill_days(
            vec![BackfilledDay {
                date: "2026-06-28".into(),
                water: true,
                outdoor_workout: true,
                second_workout: true,
                reading: true,
                diet: true,
                no_junk: true,
                photo: true,
                extra_ids: vec![JOB_EXTRA_ID.into()],
            }],
            at(d, 9, 30),
        )
        .expect("backfill day 8");
    let today = store.today(at(d, 10, 0)).expect("today");
    assert!(today.week_extras[0].done);
    assert_eq!(
        today.week_extras[0].done_on_date.as_deref(),
        Some("2026-06-28")
    );
    // ... but that date has nothing live to revoke (flag-only), which the
    // UI reads from the day's revocable record.
    let day8 = store
        .day_state("2026-06-28".into(), at(d, 10, 0))
        .expect("day 8");
    assert!(day8.revocable.extra_ids.is_empty());

    // A live event later in the week wins over the earlier flag: the toggle
    // must target a date where revoke_task succeeds whenever one exists.
    store
        .log_extra_done(JOB_EXTRA_ID.into(), at(d, 11, 0), None)
        .expect("live extra");
    let today = store.today(at(d, 11, 30)).expect("today");
    assert_eq!(today.week_extras[0].done_on_date.as_deref(), Some(d));

    // Revoking the live event falls back to the flag date, still done.
    store
        .revoke_task(
            d.into(),
            RevocableTask::Extra {
                id: JOB_EXTRA_ID.into(),
            },
            at(d, 12, 0),
        )
        .expect("revoke live extra");
    let today = store.today(at(d, 12, 30)).expect("today");
    assert!(today.week_extras[0].done);
    assert_eq!(
        today.week_extras[0].done_on_date.as_deref(),
        Some("2026-06-28")
    );
}

#[test]
fn revoke_task_extra_flips_week_state_without_the_weekly_moment() {
    let (_dir, _path, store) = demo_store();
    let d = "2026-07-04"; // day 14 = week 2

    let r = store
        .log_extra_done(JOB_EXTRA_ID.into(), at(d, 9, 0), None)
        .expect("extra");
    assert!(r.week_extra_became_complete);
    assert_eq!(
        r.day_state.revocable.extra_ids,
        vec![JOB_EXTRA_ID.to_string()]
    );

    let r = store
        .revoke_task(
            d.into(),
            RevocableTask::Extra {
                id: JOB_EXTRA_ID.into(),
            },
            at(d, 10, 0),
        )
        .expect("revoke extra");
    assert!(
        !r.week_extra_became_complete,
        "an undo must never fire the weekly moment"
    );
    assert!(!r.day_became_complete);
    assert!(r.day_state.extras_done.is_empty());
    assert!(r.day_state.revocable.extra_ids.is_empty());
    let today = store.today(at(d, 10, 30)).expect("today");
    assert!(!today.week_extras[0].done, "week 2 is open again");

    // Week 1 (backfilled on day 3) is untouched by the week-2 revoke.
    let day3 = store
        .day_state("2026-06-23".into(), at(d, 10, 30))
        .expect("day state");
    assert!(day3.extras_done.contains(&JOB_EXTRA_ID.to_string()));

    // Re-completing the week fires the weekly moment again: a genuine flip.
    let r = store
        .log_extra_done(JOB_EXTRA_ID.into(), at(d, 11, 0), None)
        .expect("re-extra");
    assert!(r.week_extra_became_complete);
}

#[test]
fn revoke_task_attributes_dates_like_day_state() {
    let (_dir, _path, store) = demo_store();

    // Yesterday (day 13) via explicit effective_date: retroactive reading
    // completes the backfilled-but-for-reading day, and revoking BY DATE
    // undoes exactly that entry.
    let r = store
        .log_reading(
            "Deep Work".into(),
            10,
            at("2026-07-04", 9, 0),
            Some("2026-07-03".into()),
        )
        .expect("retro reading");
    assert!(r.day_became_complete);
    let r = store
        .revoke_task(
            "2026-07-03".into(),
            RevocableTask::Reading,
            at("2026-07-04", 9, 30),
        )
        .expect("revoke yesterday's reading");
    assert_eq!(r.day_state.date, "2026-07-03");
    assert!(!r.day_state.reading_done);
    assert!(!r.day_state.core_complete);
    assert!(!r.day_became_complete);

    // Live cutoff attribution: a 1:30 AM diet belongs to day 14 (4:00 AM
    // cutoff), so the revoke finds it under day 14's date — and NOT under
    // the calendar date it was logged on.
    store
        .log_diet_ok(at("2026-07-05", 1, 30), None)
        .expect("late-night diet");
    assert!(matches!(
        store.revoke_task(
            "2026-07-05".into(),
            RevocableTask::Diet,
            at("2026-07-05", 1, 35)
        ),
        Err(DromeError::TaskNotRevocable(_))
    ));
    let r = store
        .revoke_task(
            "2026-07-04".into(),
            RevocableTask::Diet,
            at("2026-07-05", 1, 40),
        )
        .expect("revoke day-14 diet");
    assert!(!r.day_state.diet_done);
}

#[test]
fn revoke_task_history_survives_export_import_round_trip() {
    let (_d1, _p1, source) = demo_store();
    let d = "2026-07-04";
    source.log_diet_ok(at(d, 9, 0), None).expect("diet");
    source.log_no_junk_ok(at(d, 9, 5), None).expect("no junk");
    source
        .log_photo_done(Some("photos/day14.jpg".into()), at(d, 9, 10), None)
        .expect("photo");
    source
        .log_reading("Deep Work".into(), 12, at(d, 9, 15), None)
        .expect("reading");
    source
        .revoke_task(d.into(), RevocableTask::Photo, at(d, 10, 0))
        .expect("revoke photo");
    source
        .revoke_task(d.into(), RevocableTask::Diet, at(d, 10, 5))
        .expect("revoke diet");

    let now = at(d, 11, 0);
    let snapshot = source.export_json(now).expect("export");
    let (_d2, _p2, dest) = open_store();
    dest.import_json(snapshot).expect("import");

    // Identical projections (DayState equality covers `revocable` too).
    for day in 1..=14 {
        let date = fixture_date(day);
        assert_eq!(
            source.day_state(date.clone(), now).expect("source state"),
            dest.day_state(date, now).expect("dest state")
        );
    }
    // The restored store keeps both the un-done state and the remaining
    // revocability (no-junk / reading still live; diet / photo revoked).
    let day14 = dest.day_state(d.into(), now).expect("day state");
    assert!(!day14.diet_done && !day14.photo_done);
    assert!(day14.no_junk_done && day14.reading_done);
    assert!(!day14.revocable.diet && !day14.revocable.photo);
    assert!(day14.revocable.no_junk && day14.revocable.reading);
    assert_eq!(
        source.export_csv(now).expect("csv"),
        dest.export_csv(now).expect("csv")
    );
}

#[test]
fn new_challenges_require_the_attestation_from_day_one() {
    // A challenge created by a six-task build has no pre-era history: even
    // before its first event, retroactive diet logging (the yesterday sheet)
    // must not complete the no-junk task for lived days.
    let (_dir, _path, store) = open_store();
    store
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-06-21",
            at("2026-06-21", 6, 0),
        ))
        .expect("create");
    let r = store
        .log_diet_ok(at("2026-06-22", 9, 0), Some("2026-06-21".into()))
        .expect("retro diet");
    assert!(r.day_state.diet_done);
    assert!(!r.day_state.no_junk_done);
    assert!(!r.day_state.core_complete);
}

// ---------------------------------------------------------------------------
// reset_all_data — the app's ONE destructive operation. The cardinal rule is
// "data cannot be lost", so these tests pin the three safety properties: the
// wipe is total, the recreated append-only guard still bites, and the
// export → reset → import escape hatch is lossless. A failed reset must be a
// perfect no-op (single transaction).
// ---------------------------------------------------------------------------

#[test]
fn reset_all_data_wipes_everything_and_rearms_the_append_only_guard() {
    let (_dir, path, store) = demo_store();
    store
        .log_water(500, at("2026-07-04", 10, 0), None)
        .expect("water");

    store.reset_all_data().expect("reset");

    // Never-used state: no challenge, and every table literally empty.
    assert!(store.active_challenge().expect("query").is_none());
    assert!(matches!(
        store.summary(at("2026-07-04", 11, 0)),
        Err(DromeError::NoActiveChallenge)
    ));
    let conn = rusqlite::Connection::open(&path).expect("raw open");
    for table in ["events", "challenge", "container_presets", "extra_defs"] {
        let count: i64 = conn
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .expect("count");
        assert_eq!(count, 0, "{table} not empty after reset");
    }

    // A fresh challenge starts cleanly at day 1, nothing inherited.
    store
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-08-01",
            at("2026-08-01", 8, 0),
        ))
        .expect("fresh challenge");
    let now = at("2026-08-01", 9, 0);
    let today = store.today(now).expect("today");
    assert_eq!(today.date, "2026-08-01");
    assert_eq!(today.day_index, 1);
    assert!(!today.day.core_complete);
    assert_eq!(today.day.water_ml, 0);
    let summary = store.summary(now).expect("summary");
    assert_eq!(summary.days_complete_count, 0);
    assert_eq!(summary.current_run, 0);
    assert_eq!(summary.today_day_index, 1);

    // The RECREATED triggers still enforce append-only: insert an event on
    // the fresh challenge, then raw UPDATE/DELETE must RAISE exactly like a
    // never-reset store — proof the guard was rebuilt, not just dropped.
    store
        .log_water(500, at("2026-08-01", 9, 30), None)
        .expect("water");
    let update = conn.execute("UPDATE events SET kind = 'tampered'", []);
    let err = update.expect_err("update must be rejected").to_string();
    assert!(err.contains("append-only"), "unexpected error: {err}");
    let delete = conn.execute("DELETE FROM events", []);
    let err = delete.expect_err("delete must be rejected").to_string();
    assert!(err.contains("append-only"), "unexpected error: {err}");
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM events", [], |row| row.get(0))
        .expect("count");
    assert_eq!(count, 1);
}

#[test]
fn reset_then_restore_round_trip_rebuilds_identical_projections() {
    // The product's escape hatch: export → reset → import must be lossless.
    let (_dir, _path, store) = demo_store();
    store
        .update_presets(
            vec![drome_core::ContainerPreset {
                id: "bottle".into(),
                name: "24 oz bottle".into(),
                ml: 710,
                sort_order: 0,
            }],
            at("2026-07-04", 9, 10),
        )
        .expect("presets");
    // A mixed live week on top of the fixture: water + a signed correction,
    // both workouts, reading (one entry revoked), all three attestations, a
    // photo with a ref, a revoked task, a goal change, a closed day, and a
    // post-close log that rolls to the next date.
    let d = "2026-07-04";
    store.log_water(2_000, at(d, 8, 0), None).expect("water");
    store
        .log_water_adjustment(-250, at(d, 8, 30), None)
        .expect("adjustment");
    store
        .log_workout(45, true, Some("run".into()), None, at(d, 9, 0), None)
        .expect("outdoor workout");
    store
        .log_workout(30, false, None, None, at(d, 18, 0), None)
        .expect("second workout");
    let r = store
        .log_reading("Deep Work".into(), 4, at(d, 12, 0), None)
        .expect("reading");
    store
        .revoke_event(r.event_uuid, at(d, 12, 5))
        .expect("revoke reading");
    store
        .log_reading("Deep Work".into(), 12, at(d, 12, 10), None)
        .expect("reading again");
    store.log_diet_ok(at(d, 13, 0), None).expect("diet");
    store.log_no_junk_ok(at(d, 13, 5), None).expect("no junk");
    store
        .log_photo_done(Some("2026-07-04.jpg".into()), at(d, 13, 10), None)
        .expect("photo");
    store
        .revoke_task(d.into(), RevocableTask::Diet, at(d, 14, 0))
        .expect("revoke diet");
    store.log_diet_ok(at(d, 14, 30), None).expect("diet again");
    store
        .log_extra_done(JOB_EXTRA_ID.into(), at(d, 15, 0), None)
        .expect("extra");
    store.set_water_goal(3_000, at(d, 16, 0)).expect("goal");
    store.close_day(d.into(), at(d, 22, 0)).expect("close");
    store
        .log_water(200, at(d, 23, 0), None)
        .expect("late water");

    let now = at("2026-07-05", 9, 0);
    let pre_states: Vec<drome_core::DayState> = (1..=15)
        .map(|day| store.day_state(fixture_date(day), now).expect("pre state"))
        .collect();
    let pre_summary = store.summary(now).expect("pre summary");
    let pre_csv = store.export_csv(now).expect("pre csv");
    let pre_presets = store.container_presets().expect("pre presets");
    let pre_extras = store.extra_defs().expect("pre extras");
    let pre_challenge = store
        .active_challenge()
        .expect("query")
        .expect("pre challenge");
    let snapshot = store.export_json(now).expect("export");

    store.reset_all_data().expect("reset");
    assert!(store.active_challenge().expect("query").is_none());

    store.import_json(snapshot).expect("restore");

    // Projections identical to pre-reset, day by day and in aggregate.
    for (day, pre) in (1..=15).zip(pre_states) {
        assert_eq!(
            pre,
            store.day_state(fixture_date(day), now).expect("post state"),
            "day {day} diverged across reset + restore"
        );
    }
    assert_eq!(pre_summary, store.summary(now).expect("post summary"));
    assert_eq!(pre_csv, store.export_csv(now).expect("post csv"));
    assert_eq!(
        pre_presets,
        store.container_presets().expect("post presets")
    );
    assert_eq!(pre_extras, store.extra_defs().expect("post extras"));
    assert_eq!(
        pre_challenge,
        store
            .active_challenge()
            .expect("query")
            .expect("post challenge")
    );
}

#[test]
fn failed_mid_transaction_reset_leaves_everything_intact() {
    let (_dir, path, store) = demo_store();
    let now = at("2026-07-04", 10, 0);
    store
        .log_water(500, at("2026-07-04", 9, 0), None)
        .expect("water");
    let pre_summary = store.summary(now).expect("pre summary");
    let pre_day13 = store
        .day_state(fixture_date(13), now)
        .expect("pre day state");

    // Simulate a failure MID-transaction, after the append-only triggers
    // were already dropped: a saboteur BEFORE DELETE trigger (own name, so
    // the reset's drops don't remove it) makes the wipe's `DELETE FROM
    // events` RAISE partway through the batch.
    let conn = rusqlite::Connection::open(&path).expect("raw open");
    conn.execute_batch(
        "CREATE TRIGGER test_reset_saboteur BEFORE DELETE ON events
         BEGIN SELECT RAISE(ABORT, 'simulated mid-reset failure'); END;",
    )
    .expect("saboteur trigger");

    let err = store.reset_all_data().expect_err("reset must fail");
    assert!(
        err.to_string().contains("simulated mid-reset failure"),
        "unexpected error: {err}"
    );

    // Rolled back completely: challenge, events, and projections intact…
    assert!(store.active_challenge().expect("query").is_some());
    assert_eq!(pre_summary, store.summary(now).expect("post summary"));
    assert_eq!(
        pre_day13,
        store
            .day_state(fixture_date(13), now)
            .expect("post day state")
    );
    // …and the append-only guard is back in force (the DROPs rolled back).
    let update = conn.execute("UPDATE events SET kind = 'tampered'", []);
    let err = update.expect_err("update must be rejected").to_string();
    assert!(err.contains("append-only"), "unexpected error: {err}");

    // With the saboteur removed, the very same store resets cleanly.
    conn.execute_batch("DROP TRIGGER test_reset_saboteur")
        .expect("drop saboteur");
    store.reset_all_data().expect("reset");
    assert!(store.active_challenge().expect("query").is_none());
}

// ---------------------------------------------------------------------------
// Cross-handle wipe race — the widget process holds its OWN connection to the
// shared WAL DB, so the Mutex inside one DromeStore protects nothing across
// handles. Every log path must be atomic with its active-challenge check
// (one IMMEDIATE transaction): a write racing `reset_all_data` must fail
// NoActiveChallenge, never orphan an event under the deleted challenge id
// (which a later restore of the same challenge would silently adopt).
// ---------------------------------------------------------------------------

#[test]
fn stale_handle_log_after_reset_is_rejected_and_leaves_no_orphan() {
    let (_dir, path, store) = demo_store();
    // Second handle to the same file — the widget process.
    let widget = DromeStore::open(path.clone()).expect("open widget handle");
    // Warm the stale handle: it has seen the challenge (the widget's last
    // read before the user hits "Delete everything").
    assert!(widget.active_challenge().expect("query").is_some());

    store.reset_all_data().expect("reset");

    let err = widget
        .log_water(500, at("2026-07-04", 10, 0), None)
        .expect_err("a log through the stale handle must be rejected");
    assert!(
        matches!(err, DromeError::NoActiveChallenge),
        "unexpected error: {err}"
    );

    let conn = rusqlite::Connection::open(&path).expect("raw open");
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM events", [], |row| row.get(0))
        .expect("count");
    assert_eq!(count, 0, "a post-reset log must never orphan an event");
}

#[test]
fn companion_water_command_uuid_is_idempotent() {
    let (_dir, _path, store) = open_store();
    store
        .create_challenge(challenge_cfg(
            RulesetKind::Flexible,
            "2026-07-04",
            at("2026-07-04", 8, 0),
        ))
        .expect("create");
    let id = "67f6438d-8484-4959-8f4b-22d607bfe5c8".to_owned();
    let first = store
        .log_water_idempotent(id.clone(), 473, at("2026-07-04", 9, 0))
        .expect("first delivery");
    let duplicate = store
        .log_water_idempotent(id.clone(), 473, at("2026-07-05", 9, 0))
        .expect("duplicate delivery");
    assert_eq!(first.event_uuid, id);
    assert_eq!(duplicate.event_uuid, id);
    assert_eq!(
        store
            .day_state("2026-07-04".into(), at("2026-07-05", 9, 1))
            .expect("day")
            .water_ml,
        473
    );
    assert_eq!(
        store
            .day_state("2026-07-05".into(), at("2026-07-05", 9, 1))
            .expect("next day")
            .water_ml,
        0
    );
}

#[test]
fn widget_logs_racing_the_reset_never_survive_the_wipe() {
    // Interleaved version of the same promise: a second handle hammers
    // log_water from another thread while the reset commits. Whatever the
    // interleaving, the wiped store must end EMPTY — pre-fix, a log whose
    // challenge read predated the reset could commit its INSERT after the
    // wipe and leave a live event under the deleted challenge id.
    let (_dir, path, store) = demo_store();
    let widget = DromeStore::open(path.clone()).expect("open widget handle");

    let stop = Arc::new(AtomicBool::new(false));
    let stop_writer = stop.clone();
    let writer = std::thread::spawn(move || {
        let mut minute: i64 = 0;
        while !stop_writer.load(Ordering::Relaxed) {
            // Errors are expected once the wipe lands (NoActiveChallenge);
            // the invariant checked below is what's IN the store.
            let _ = widget.log_water(10, plus_min(at("2026-07-04", 10, 0), minute), None);
            minute += 1;
            // Breathe between writes: a zero-gap hammer loop can starve the
            // reset's BEGIN IMMEDIATE past the 5s busy_timeout (a livelock,
            // not the race under test). The interleaving that this test cares
            // about — a write whose challenge-read predates the wipe still
            // firing across the reset window — is fully preserved.
            std::thread::sleep(Duration::from_micros(500));
        }
    });
    std::thread::sleep(Duration::from_millis(25));
    store.reset_all_data().expect("reset");
    stop.store(true, Ordering::Relaxed);
    writer.join().expect("writer thread");

    assert!(store.active_challenge().expect("query").is_none());
    let conn = rusqlite::Connection::open(&path).expect("raw open");
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM events", [], |row| row.get(0))
        .expect("count");
    assert_eq!(
        count, 0,
        "an event outlived the wipe (orphaned by the race)"
    );
}
