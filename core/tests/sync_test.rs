//! Phase 2 client-side sync engine tests (docs/PHASE2.md "Sync protocol").
//! These exercise the core `DromeStore` sync surface WITHOUT a server: two
//! in-process stores exchange wire events + config blocks directly. The
//! server crate's tests cover server_seq assignment and the HTTP round-trip.

use std::sync::Arc;

use drome_core::{
    sync_follow_up, BackfilledDay, DromeError, DromeStore, LocalInstant, NewChallenge, RulesetKind,
    SyncApplyResult, SyncOutcome, SyncPreparation, SyncRoundResponse, WireEvent, JOB_EXTRA_ID,
};
use tempfile::TempDir;

const TZ: i32 = -18_000; // US Central daylight time
const GALLON_ML: i64 = 3_785;
const CTX: &str = "acct-1";

fn at(date: &str, hour: i64, minute: i64) -> LocalInstant {
    let d = drome_core::time::parse_date(date).expect("test date");
    let wall =
        drome_core::time::wall_secs_at_midnight(d).expect("in range") + hour * 3_600 + minute * 60;
    LocalInstant {
        epoch_secs: wall - i64::from(TZ),
        tz_offset_secs: TZ,
    }
}

fn open_store() -> (TempDir, Arc<DromeStore>) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir
        .path()
        .join("drome.sqlite")
        .to_string_lossy()
        .into_owned();
    let store = DromeStore::open(path).expect("open store");
    (dir, store)
}

fn challenge_cfg(start_date: &str, created_at: LocalInstant) -> NewChallenge {
    NewChallenge {
        ruleset: RulesetKind::Flexible,
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

/// A device-A store with a challenge and a mixed logged day-14.
fn store_a() -> (TempDir, Arc<DromeStore>) {
    let (dir, store) = open_store();
    store
        .create_challenge(challenge_cfg("2026-06-21", at("2026-07-04", 9, 0)))
        .expect("create challenge");
    store
        .set_extra_enabled(JOB_EXTRA_ID.into(), true, at("2026-07-04", 9, 1))
        .expect("enable extra");
    (dir, store)
}

/// Log a full mixed day-14 on `store`: water + correction, two workouts,
/// all attestations, reading, a photo (with a ref), an extra, plus a revoke.
fn log_mixed_day(store: &DromeStore) {
    let d = "2026-07-04";
    store.log_water(2_000, at(d, 8, 0), None).expect("water");
    store
        .log_water_adjustment(-250, at(d, 8, 30), None)
        .expect("adjust");
    store.log_water(2_100, at(d, 9, 0), None).expect("water2");
    store
        .log_workout(45, true, Some("run".into()), None, at(d, 9, 30), None)
        .expect("outdoor");
    store
        .log_workout(30, false, None, None, at(d, 18, 0), None)
        .expect("indoor");
    store
        .log_reading("Deep Work".into(), 20, at(d, 20, 0), None)
        .expect("read");
    store.log_diet_ok(at(d, 20, 5), None).expect("diet");
    store.log_no_junk_ok(at(d, 20, 6), None).expect("no junk");
    store
        .log_photo_done(Some("/photos/day14.jpg".into()), at(d, 20, 7), None)
        .expect("photo");
    let extra = store
        .log_extra_done(JOB_EXTRA_ID.into(), at(d, 21, 0), None)
        .expect("extra");
    // A revoke of the extra, then re-log it, to prove revoked uuids sync too.
    store
        .revoke_event(extra.event_uuid, at(d, 21, 1))
        .expect("revoke");
    store
        .log_extra_done(JOB_EXTRA_ID.into(), at(d, 21, 2), None)
        .expect("extra2");
}

fn prepare(store: &DromeStore, limit: u32) -> SyncPreparation {
    store
        .prepare_sync_round(CTX.into(), limit)
        .expect("prepare")
}

fn apply(
    store: &DromeStore,
    epoch: i64,
    acked: Vec<String>,
    config_json: &str,
    winner: Option<&str>,
    events: Vec<WireEvent>,
    seq: i64,
) -> Result<SyncApplyResult, DromeError> {
    store.apply_sync_response(
        CTX.into(),
        epoch,
        SyncRoundResponse {
            acked_uuids: acked,
            config_json: config_json.into(),
            winner_challenge_id: winner.map(str::to_owned),
            events,
            new_last_server_seq: seq,
        },
    )
}

/// Merge `config_json` and `events` into `store`, leaving its cursor put.
fn merge_in(store: &DromeStore, config_json: &str, events: Vec<WireEvent>) -> SyncApplyResult {
    let snap = prepare(store, 0);
    let result = apply(
        store,
        snap.reset_epoch,
        Vec::new(),
        config_json,
        None,
        events,
        snap.last_server_seq,
    )
    .expect("merge");
    assert_eq!(result.outcome, SyncOutcome::Applied);
    result
}

/// Server-less one-way sync: push A's config + pending events into B, then
/// ack A locally (as a real server would after accepting them).
fn push(from: &DromeStore, to: &DromeStore) -> Vec<WireEvent> {
    let from_snap = prepare(from, 10_000);
    let merged = merge_in(to, &from_snap.config_json, from_snap.pending.clone());
    assert_eq!(merged.inserted as usize, from_snap.pending.len());
    let uuids: Vec<String> = from_snap.pending.iter().map(|e| e.uuid.clone()).collect();
    let acked = apply(
        from,
        from_snap.reset_epoch,
        uuids,
        "{}",
        None,
        Vec::new(),
        from_snap.last_server_seq,
    )
    .expect("ack");
    assert_eq!(acked.outcome, SyncOutcome::Applied);
    from_snap.pending
}

#[test]
fn pending_events_then_ack_advances_the_watermark() {
    let (_da, a) = store_a();
    log_mixed_day(&a);

    let first = prepare(&a, 10_000);
    assert!(!first.pending.is_empty());
    assert!(!first.device_id.is_empty());
    assert_eq!(
        prepare(&a, 0).pending.len(),
        0,
        "a limit of 0 returns no events"
    );
    // A limit caps the batch; the events are oldest-first (stable id order).
    let capped = prepare(&a, 3);
    assert_eq!(capped.pending.len(), 3);
    assert_eq!(capped.pending[0], first.pending[0]);
    assert_eq!(
        capped.device_id, first.device_id,
        "device id is minted once"
    );

    // Nothing acked yet: still fully pending.
    assert_eq!(prepare(&a, 10_000).pending.len(), first.pending.len());

    // Ack the first two; only the tail remains pending.
    let acked: Vec<String> = first
        .pending
        .iter()
        .take(2)
        .map(|e| e.uuid.clone())
        .collect();
    apply(
        &a,
        first.reset_epoch,
        acked,
        "{}",
        None,
        Vec::new(),
        first.last_server_seq,
    )
    .expect("ack");
    let after = prepare(&a, 10_000);
    assert_eq!(after.pending.len(), first.pending.len() - 2);
    assert_eq!(after.pending[0], first.pending[2]);

    // Ack the rest: nothing pending.
    let rest: Vec<String> = first.pending.iter().map(|e| e.uuid.clone()).collect();
    apply(
        &a,
        first.reset_epoch,
        rest,
        "{}",
        None,
        Vec::new(),
        after.last_server_seq,
    )
    .expect("ack rest");
    assert!(prepare(&a, 10_000).pending.is_empty());
}

#[test]
fn apply_remote_events_is_idempotent_on_replay() {
    let (_da, a) = store_a();
    log_mixed_day(&a);
    let (_db, b) = open_store();
    let from = prepare(&a, 10_000);
    merge_in(&b, &from.config_json, Vec::new());

    let batch = from.pending;
    let snap = prepare(&b, 0);
    let n1 = apply(
        &b,
        snap.reset_epoch,
        Vec::new(),
        "{}",
        None,
        batch.clone(),
        7,
    )
    .expect("apply1");
    assert_eq!(n1.outcome, SyncOutcome::Applied);
    assert_eq!(n1.inserted as usize, batch.len());
    assert_eq!(prepare(&b, 0).last_server_seq, 7);
    // Re-applying the exact batch inserts nothing (dedup by uuid) but still
    // assigns the cursor, including downward.
    let n2 = apply(
        &b,
        snap.reset_epoch,
        Vec::new(),
        "{}",
        None,
        batch.clone(),
        4,
    )
    .expect("apply2");
    assert_eq!(n2.inserted, 0);
    assert_eq!(
        prepare(&b, 0).last_server_seq,
        4,
        "cursor is assigned, not raised"
    );
    // A partial replay (subset) is also a no-op. An empty pull still moves
    // the cursor.
    let n3 = apply(
        &b,
        snap.reset_epoch,
        Vec::new(),
        "{}",
        None,
        batch[..batch.len() / 2].to_vec(),
        9,
    )
    .expect("apply3");
    assert_eq!(n3.inserted, 0);
    let n4 = apply(&b, snap.reset_epoch, Vec::new(), "{}", None, Vec::new(), 11).expect("empty");
    assert_eq!(n4.inserted, 0);
    assert_eq!(prepare(&b, 0).last_server_seq, 11);
}

#[test]
fn remote_origin_events_are_never_re_pushed() {
    let (_da, a) = store_a();
    log_mixed_day(&a);
    let (_db, b) = open_store();

    // B pulls everything from A.
    push(&a, &b);
    // B has applied all of A's events but must not echo them back: they are
    // remote-origin. B's own pending set is empty.
    assert!(prepare(&b, 10_000).pending.is_empty());

    // B logs something new of its own; only THAT is pending on B.
    b.log_water(500, at("2026-07-05", 8, 0), None)
        .expect("b water");
    let b_pending = prepare(&b, 10_000).pending;
    assert_eq!(b_pending.len(), 1);
    assert_eq!(b_pending[0].kind, "water_add");
}

#[test]
fn photo_ref_is_stripped_on_the_wire_but_intact_locally() {
    let (_da, a) = store_a();
    a.log_photo_done(
        Some("/photos/secret.jpg".into()),
        at("2026-07-04", 20, 0),
        None,
    )
    .expect("photo");

    let pending = prepare(&a, 10_000).pending;
    let photo = pending
        .iter()
        .find(|e| e.kind == "photo_done")
        .expect("photo event on wire");
    // Stripped at the boundary: the ref never crosses the wire.
    assert_eq!(photo.payload_json, r#"{"photo_ref":null}"#);
    assert!(!photo.payload_json.contains("secret"));

    // The local row still holds the ref (export carries it).
    let export = a.export_json(at("2026-07-04", 22, 0)).expect("export");
    assert!(export.contains("/photos/secret.jpg"));

    // A peer that applies the stripped event still marks the photo task done.
    let (_db, b) = open_store();
    push(&a, &b);
    let day = b
        .day_state("2026-07-04".into(), at("2026-07-04", 22, 0))
        .expect("day");
    assert!(day.photo_done);
}

#[test]
fn two_store_merge_yields_identical_day_state_and_summary() {
    let now = at("2026-07-04", 22, 0);
    let (_da, a) = store_a();
    // Backfill days 1..=13 on A so the summary is substantial, then a mixed
    // live day 14.
    let days: Vec<BackfilledDay> = (1..=13)
        .map(|i| BackfilledDay {
            date: if i <= 10 {
                format!("2026-06-{}", 20 + i)
            } else {
                format!("2026-07-{:02}", i - 10)
            },
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
    a.backfill_days(days, at("2026-07-04", 9, 5))
        .expect("backfill");
    log_mixed_day(&a);

    // B starts from empty and pulls A's config + events.
    let (_db, b) = open_store();
    push(&a, &b);

    // Every projection must match, exactly, on both stores.
    for date in ["2026-06-21", "2026-06-24", "2026-07-03", "2026-07-04"] {
        assert_eq!(
            a.day_state(date.into(), now).expect("a day"),
            b.day_state(date.into(), now).expect("b day"),
            "day_state diverged on {date}"
        );
    }
    assert_eq!(
        a.summary(now).expect("a summary"),
        b.summary(now).expect("b summary")
    );
    assert_eq!(
        a.export_csv(now).expect("a csv"),
        b.export_csv(now).expect("b csv")
    );

    // Now B logs more, A pulls, and A matches B.
    b.log_reading("Deep Work".into(), 15, at("2026-07-05", 7, 0), None)
        .expect("b read");
    b.log_water(3_800, at("2026-07-05", 8, 0), None)
        .expect("b water");
    b.log_workout(60, true, None, None, at("2026-07-05", 9, 0), None)
        .expect("b outdoor");
    b.log_workout(20, false, None, None, at("2026-07-05", 18, 0), None)
        .expect("b indoor");
    b.log_diet_ok(at("2026-07-05", 20, 0), None)
        .expect("b diet");
    b.log_no_junk_ok(at("2026-07-05", 20, 1), None)
        .expect("b nj");
    b.log_photo_done(None, at("2026-07-05", 20, 2), None)
        .expect("b photo");
    push(&b, &a);

    let later = at("2026-07-05", 22, 0);
    assert_eq!(
        a.day_state("2026-07-05".into(), later).expect("a d15"),
        b.day_state("2026-07-05".into(), later).expect("b d15")
    );
    assert_eq!(
        a.summary(later).expect("a summary2"),
        b.summary(later).expect("b summary2")
    );
    assert_eq!(
        a.export_csv(later).expect("a csv2"),
        b.export_csv(later).expect("b csv2")
    );
}

#[test]
fn config_lww_resolves_both_directions() {
    // Bring both stores to a shared challenge.
    let (_da, a) = store_a();
    let (_db, b) = open_store();
    let shared = prepare(&a, 0).config_json;
    merge_in(&b, &shared, Vec::new());

    // A edits the book earlier; B edits it later. B must win everywhere.
    a.set_current_book("Book A".into(), at("2026-07-04", 10, 0))
        .expect("a book");
    b.set_current_book("Book B".into(), at("2026-07-04", 11, 0))
        .expect("b book");

    // B applies A's (older) config: keeps "Book B". A blank winner is a merge,
    // not an adopt.
    let a_cfg = prepare(&a, 0).config_json;
    let b_snap = prepare(&b, 0);
    apply(
        &b,
        b_snap.reset_epoch,
        Vec::new(),
        &a_cfg,
        Some(""),
        Vec::new(),
        b_snap.last_server_seq,
    )
    .expect("b apply a");
    assert_eq!(book(&b), "Book B");
    // A applies B's (newer) config: adopts "Book B".
    merge_in(&a, &prepare(&b, 0).config_json, Vec::new());
    assert_eq!(book(&a), "Book B");

    // Presets is an independent slot: A sets presets after the book race; a
    // later A-presets edit still wins its own slot regardless of the book.
    a.update_presets(
        vec![drome_core::ContainerPreset {
            id: "bottle".into(),
            name: "24oz".into(),
            ml: 710,
            sort_order: 0,
        }],
        at("2026-07-04", 12, 0),
    )
    .expect("a presets");
    merge_in(&b, &prepare(&a, 0).config_json, Vec::new());
    let b_presets = b.container_presets().expect("b presets");
    assert_eq!(b_presets.len(), 1);
    assert_eq!(b_presets[0].id, "bottle");
    // The book slot did NOT regress on B (still "Book B"): presets is separate.
    assert_eq!(book(&b), "Book B");
}

#[test]
fn last_server_seq_is_assigned_per_context() {
    let (_da, a) = store_a();
    let snap = prepare(&a, 0);
    assert_eq!(snap.last_server_seq, 0);
    assert_eq!(snap.reset_epoch, 0);
    let primed = apply(&a, snap.reset_epoch, Vec::new(), "{}", None, Vec::new(), 42).expect("set");
    assert_eq!(primed.outcome, SyncOutcome::Applied);
    assert_eq!(primed.inserted, 0);
    assert_eq!(prepare(&a, 0).last_server_seq, 42);
    // A different context keeps its own cursor.
    assert_eq!(
        a.prepare_sync_round("acct-2".into(), 0)
            .expect("other")
            .last_server_seq,
        0
    );
    apply(
        &a,
        snap.reset_epoch,
        Vec::new(),
        "{}",
        None,
        Vec::new(),
        100,
    )
    .expect("set2");
    assert_eq!(prepare(&a, 0).last_server_seq, 100);
    apply(&a, snap.reset_epoch, Vec::new(), "{}", None, Vec::new(), 5).expect("rewind");
    assert_eq!(
        prepare(&a, 0).last_server_seq,
        5,
        "the cursor is assigned, including downward"
    );
}

#[test]
fn adopt_active_challenge_overrides_newer_local_stamp() {
    // Winner challenge created EARLIER (older LWW stamp).
    let (_da, a) = open_store();
    a.create_challenge(challenge_cfg("2026-06-21", at("2026-07-04", 10, 0)))
        .expect("winner");
    let winner_id = a.active_challenge().unwrap().unwrap().id;
    let winner_config = prepare(&a, 0).config_json;

    // Loser challenge created LATER (newer stamp) on a separate store.
    let (_db, b) = open_store();
    b.create_challenge(challenge_cfg("2026-06-01", at("2026-07-04", 12, 0)))
        .expect("loser");
    let loser_id = b.active_challenge().unwrap().unwrap().id;
    assert_ne!(winner_id, loser_id);

    // Plain LWW config apply CANNOT dislodge the newer local challenge: the
    // winner slot loses last-writer-wins and is skipped. This is precisely the
    // permanent split-brain the server's conflict signal exists to break.
    let lww = prepare(&b, 0);
    apply(
        &b,
        lww.reset_epoch,
        Vec::new(),
        &winner_config,
        None,
        Vec::new(),
        lww.last_server_seq,
    )
    .expect("lww apply");
    assert_eq!(
        b.active_challenge().unwrap().unwrap().id,
        loser_id,
        "LWW must not switch when the local stamp is newer"
    );

    // Force-adopt (what the client does on active_challenge_conflict): the
    // loser adopts the winner regardless of stamp and archives its own.
    let adopt_snap = prepare(&b, 0);
    apply(
        &b,
        adopt_snap.reset_epoch,
        Vec::new(),
        &winner_config,
        Some(&winner_id),
        Vec::new(),
        adopt_snap.last_server_seq,
    )
    .expect("adopt");
    let active = b.active_challenge().unwrap().unwrap();
    assert_eq!(active.id, winner_id);
    assert!(active.active);

    // Idempotent: adopting again is a no-op.
    let again = prepare(&b, 0);
    apply(
        &b,
        again.reset_epoch,
        Vec::new(),
        &prepare(&a, 0).config_json,
        Some(&winner_id),
        Vec::new(),
        again.last_server_seq,
    )
    .expect("adopt2");
    assert_eq!(b.active_challenge().unwrap().unwrap().id, winner_id);

    // An unknown winner with an empty config block does not archive the
    // challenge this store actually holds.
    let (_dc, c) = store_a();
    let kept = c.active_challenge().unwrap().unwrap().id;
    let c_snap = prepare(&c, 0);
    apply(
        &c,
        c_snap.reset_epoch,
        Vec::new(),
        "{}",
        Some("unknown-winner"),
        Vec::new(),
        c_snap.last_server_seq,
    )
    .expect("unknown winner");
    assert_eq!(c.active_challenge().unwrap().unwrap().id, kept);
}

#[test]
fn pulled_events_and_cursor_land_together() {
    let (_da, a) = store_a();
    log_mixed_day(&a);
    let (_db, b) = open_store();
    let from = prepare(&a, 10_000);
    merge_in(&b, &from.config_json, Vec::new());

    let batch = from.pending;
    assert_eq!(prepare(&b, 0).last_server_seq, 0);

    // One apply stores the batch AND assigns the cursor.
    let snap = prepare(&b, 0);
    let pulled = apply(
        &b,
        snap.reset_epoch,
        Vec::new(),
        "{}",
        None,
        batch.clone(),
        7,
    )
    .expect("batch");
    assert_eq!(pulled.outcome, SyncOutcome::Applied);
    assert_eq!(pulled.inserted as usize, batch.len());
    assert_eq!(
        prepare(&b, 0).last_server_seq,
        7,
        "cursor advanced with the batch"
    );

    // Replaying the same batch inserts nothing (uuid dedup) but still moves the
    // cursor. The two effects never come apart.
    let snap2 = prepare(&b, 0);
    let pulled2 = apply(&b, snap2.reset_epoch, Vec::new(), "{}", None, batch, 9).expect("batch2");
    assert_eq!(pulled2.outcome, SyncOutcome::Applied);
    assert_eq!(pulled2.inserted, 0);
    assert_eq!(prepare(&b, 0).last_server_seq, 9);
}

/// The full Finding-1 contract from the loser's side: after adopting the
/// server-declared winner, the loser's active-challenge projections CONVERGE
/// with the winner's (its own events never pollute the winner's day), and its
/// original challenge is ARCHIVED — kept, inactive, still owning its own events
/// — not deleted (history stays coherent; no orphaned rows).
#[test]
fn loser_adopts_winner_converges_and_archives_its_original() {
    let now = at("2026-07-04", 22, 0);

    // Winner: challenge W (older stamp), a real logged day, exported to sync.
    let (_dw, w) = open_store();
    w.create_challenge(challenge_cfg("2026-06-21", at("2026-07-04", 10, 0)))
        .expect("winner");
    let winner_id = w.active_challenge().unwrap().unwrap().id;
    w.log_water(2_000, at("2026-07-04", 8, 0), None)
        .expect("w water");
    w.log_reading("Deep Work".into(), 20, at("2026-07-04", 20, 0), None)
        .expect("w read");
    let winner = prepare(&w, 10_000);
    let winner_config = winner.config_json;
    let winner_events = winner.pending;

    // Loser: a DIFFERENT challenge L created LATER (newer stamp) with its OWN
    // event. Keep the db path so we can prove the archived row survives.
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir
        .path()
        .join("drome.sqlite")
        .to_string_lossy()
        .into_owned();
    let l = DromeStore::open(path.clone()).expect("open loser");
    l.create_challenge(challenge_cfg("2026-06-01", at("2026-07-04", 12, 0)))
        .expect("loser");
    let loser_id = l.active_challenge().unwrap().unwrap().id;
    let loser_event = l
        .log_water(999, at("2026-07-04", 9, 0), None)
        .expect("l water");
    assert_ne!(winner_id, loser_id);

    // One apply is the whole conflict response: adopt the winner (LWW alone
    // cannot — the loser's stamp is newer) and store the winner's events.
    let loser_snap = prepare(&l, 0);
    let adopted = apply(
        &l,
        loser_snap.reset_epoch,
        Vec::new(),
        &winner_config,
        Some(&winner_id),
        winner_events.clone(),
        winner_events.len() as i64,
    )
    .expect("adopt");
    assert_eq!(adopted.outcome, SyncOutcome::Applied);
    assert_eq!(adopted.inserted as usize, winner_events.len());

    // Converged: same active challenge, and every projection matches the winner
    // — the loser's own 999 ml is NOT mixed into the winner's day (projections
    // read only the active challenge's events).
    let active = l.active_challenge().unwrap().unwrap();
    assert_eq!(active.id, winner_id);
    assert!(active.active);
    assert_eq!(
        l.day_state("2026-07-04".into(), now).unwrap(),
        w.day_state("2026-07-04".into(), now).unwrap(),
        "loser day_state must converge to the winner's"
    );
    assert_eq!(
        l.summary(now).unwrap(),
        w.summary(now).unwrap(),
        "loser summary must converge to the winner's"
    );
    assert_eq!(
        l.day_state("2026-07-04".into(), now).unwrap().water_ml,
        2_000,
        "winner's water, never the loser's 999"
    );

    // Archived, NOT deleted: the loser's original challenge row still exists
    // (active = 0) and its own event stays owned by it (not orphaned/leaked).
    let raw = rusqlite::Connection::open(&path).expect("reopen loser db");
    let still_active: i64 = raw
        .query_row(
            "SELECT active FROM challenge WHERE id = ?1",
            rusqlite::params![loser_id],
            |r| r.get(0),
        )
        .expect("loser challenge row must survive (archived, not deleted)");
    assert_eq!(still_active, 0, "loser challenge archived (active = 0)");
    let owned: i64 = raw
        .query_row(
            "SELECT COUNT(*) FROM events WHERE challenge_id = ?1 AND uuid = ?2",
            rusqlite::params![loser_id, loser_event.event_uuid],
            |r| r.get(0),
        )
        .expect("loser event query");
    assert_eq!(
        owned, 1,
        "loser event stays owned by its archived challenge"
    );
}

/// Builds store A with a challenge and a fully-logged day, then snapshots the
/// account's server-held state: the config block plus A's own events (which the
/// server would hold at server_seq 1..=n). Returns `(dir, store, config,
/// events, max_seq)`. The dir must outlive the store (temp db).
fn logged_a_with_server_snapshot() -> (TempDir, Arc<DromeStore>, String, Vec<WireEvent>, i64) {
    let (dir, a) = store_a();
    let day = "2026-07-04";
    a.log_water(2_000, at(day, 8, 0), None).expect("water");
    a.log_reading("Deep Work".into(), 20, at(day, 20, 0), None)
        .expect("read");
    let snap = prepare(&a, 10_000);
    let max_seq = snap.pending.len() as i64;
    (dir, a, snap.config_json, snap.pending, max_seq)
}

fn prime_cursor(store: &DromeStore, seq: i64) {
    let snap = prepare(store, 0);
    let primed = apply(
        store,
        snap.reset_epoch,
        Vec::new(),
        "{}",
        None,
        Vec::new(),
        seq,
    )
    .expect("prime cursor");
    assert_eq!(primed.outcome, SyncOutcome::Applied);
}

fn bad_wire_event() -> WireEvent {
    WireEvent {
        uuid: "not-a-real-event".into(),
        challenge_id: "not-a-challenge".into(),
        logged_at_epoch: 0,
        tz_offset_secs: 0,
        effective_date: None,
        kind: "not-a-kind".into(),
        payload_json: "NOT JSON".into(),
        schema_version: 1,
    }
}

/// Models drome-server's active-challenge pull: return the account's events
/// whose server_seq is strictly greater than the client's cursor. Here the
/// whole log is seq 1..=max_seq, so any cursor below max_seq gets everything
/// and a cursor at/above it gets nothing.
fn server_pull(events: &[WireEvent], max_seq: i64, cursor: i64) -> Vec<WireEvent> {
    if cursor < max_seq {
        events.to_vec()
    } else {
        Vec::new()
    }
}

/// THE regression test for the proven reset/sync data-loss race
/// (docs/PHASE2.md, sync/reset epoch invariant). A local "Start over" mid
/// round-trip must invalidate the round-trip's stale tail writes, and a clean
/// sync afterwards must recover the full server-held history.
///
/// Without the epoch gate this FAILS: the stale apply drags the pull cursor
/// to 2, so the next clean pull (`server_seq > 2`) returns nothing and the
/// day is silently, permanently empty. (Confirmed by making
/// `bump_reset_epoch` a no-op: the cursor-stays-0 assertion trips and the day
/// comes back empty.)
#[test]
fn reset_epoch_invalidates_stale_round_trip_tail_then_clean_sync_recovers() {
    let now = at("2026-07-04", 22, 0);
    let day = "2026-07-04";
    let (_da, a, config, events, max_seq) = logged_a_with_server_snapshot();
    assert_eq!(max_seq, 2, "A pushed exactly its two logged events");

    // A has already synced through seq 2 — its cursor mirrors the server max.
    prime_cursor(&a, max_seq);

    // The truth we must not lose.
    let pre_day = a.day_state(day.into(), now).expect("pre day");
    let pre_summary = a.summary(now).expect("pre summary");
    assert_eq!(pre_day.water_ml, 2_000);
    assert_eq!(pre_day.reading_pages, 20);

    // 1. A sync round-trip begins and captures the epoch in effect NOW.
    let captured = prepare(&a, 0);
    let winner_id = {
        let block: serde_json::Value = serde_json::from_str(&config).expect("config");
        block["challenge"]["challenge"]["id"]
            .as_str()
            .expect("winner id")
            .to_owned()
    };
    let tail_uuids: Vec<String> = events.iter().map(|e| e.uuid.clone()).collect();

    // 2. Before the tail lands, the user taps "Start over".
    a.reset_all_data().expect("reset");
    assert!(a.active_challenge().expect("q").is_none());
    assert_eq!(prepare(&a, 10_000).last_server_seq, 0);
    assert!(prepare(&a, 10_000).pending.is_empty());

    // 3. A malformed payload on the stale epoch is not an error.
    let malformed = apply(
        &a,
        captured.reset_epoch,
        tail_uuids.clone(),
        "NOT JSON",
        Some(&winner_id),
        vec![bad_wire_event()],
        max_seq,
    )
    .expect("stale malformed payload is not an error");
    assert_eq!(malformed.outcome, SyncOutcome::StaleReset);
    assert_eq!(malformed.inserted, 0);

    // 4. The real stale tail names the winner and carries the events. It
    //    still writes nothing: no challenge, no cursor, no log.
    let stale = apply(
        &a,
        captured.reset_epoch,
        tail_uuids,
        &config,
        Some(&winner_id),
        events.clone(),
        max_seq,
    )
    .expect("stale tail");
    assert_eq!(stale.outcome, SyncOutcome::StaleReset);
    assert_eq!(stale.inserted, 0);
    assert!(a.active_challenge().expect("q").is_none());
    let after_stale = prepare(&a, 10_000);
    assert_eq!(
        after_stale.last_server_seq, 0,
        "stale tail must not drag the cursor forward past the reset"
    );
    assert!(after_stale.pending.is_empty());
    assert_ne!(after_stale.reset_epoch, captured.reset_epoch);

    // 5. A fresh prepare and apply restores the server-held day.
    let fresh = prepare(&a, 0);
    let recovered = apply(
        &a,
        fresh.reset_epoch,
        Vec::new(),
        &config,
        None,
        server_pull(&events, max_seq, fresh.last_server_seq),
        max_seq,
    )
    .expect("clean pull");
    assert_eq!(recovered.outcome, SyncOutcome::Applied);
    assert_eq!(recovered.inserted, 2, "both events re-pulled and applied");

    assert_eq!(a.day_state(day.into(), now).expect("post day"), pre_day);
    assert_eq!(a.summary(now).expect("post summary"), pre_summary);
}

/// Two "Start over"s back to back: the epoch is monotonic, so a tail captured
/// before EITHER reset is stale, and a clean sync at the current epoch still
/// recovers.
#[test]
fn two_resets_in_a_row_still_recover() {
    let now = at("2026-07-04", 22, 0);
    let day = "2026-07-04";
    let (_da, a, config, events, max_seq) = logged_a_with_server_snapshot();
    prime_cursor(&a, max_seq);
    let pre_day = a.day_state(day.into(), now).expect("pre day");

    let before_first = prepare(&a, 0).reset_epoch;
    a.reset_all_data().expect("reset 1");
    let between = prepare(&a, 0).reset_epoch;
    a.reset_all_data().expect("reset 2");
    let after_second = prepare(&a, 0).reset_epoch;
    assert!(
        before_first < between && between < after_second,
        "reset epoch is strictly monotonic across resets"
    );
    assert_eq!(prepare(&a, 0).last_server_seq, 0);

    // A tail captured before the FIRST reset AND one captured between the two
    // are both stale now, even when each names a winner and carries events.
    let winner_id = events[0].challenge_id.clone();
    assert_eq!(
        apply(
            &a,
            before_first,
            Vec::new(),
            &config,
            Some(&winner_id),
            events.clone(),
            max_seq,
        )
        .expect("stale-0")
        .outcome,
        SyncOutcome::StaleReset
    );
    assert_eq!(
        apply(
            &a,
            between,
            Vec::new(),
            &config,
            Some(&winner_id),
            events.clone(),
            max_seq,
        )
        .expect("stale-1")
        .outcome,
        SyncOutcome::StaleReset
    );
    assert_eq!(
        prepare(&a, 10_000).last_server_seq,
        0,
        "neither stale tail moved the cursor"
    );
    assert!(a.active_challenge().expect("q").is_none());

    // Clean sync at the current epoch recovers the full history.
    let fresh = prepare(&a, 0);
    let recovered = apply(
        &a,
        fresh.reset_epoch,
        Vec::new(),
        &config,
        None,
        server_pull(&events, max_seq, fresh.last_server_seq),
        max_seq,
    )
    .expect("clean pull");
    assert_eq!(recovered.outcome, SyncOutcome::Applied);
    assert_eq!(recovered.inserted, 2);
    assert_eq!(a.day_state(day.into(), now).expect("post day"), pre_day);
}

/// A reset with NO in-flight round-trip: the ordinary "Start over" path still
/// recovers the account's history on the next clean sync (the reset re-mints
/// the device id so the server stops treating its events as self-echoes).
#[test]
fn reset_with_no_in_flight_round_trip_recovers() {
    let now = at("2026-07-04", 22, 0);
    let day = "2026-07-04";
    let (_da, a, config, events, max_seq) = logged_a_with_server_snapshot();
    prime_cursor(&a, max_seq);
    let pre_day = a.day_state(day.into(), now).expect("pre day");
    let pre_summary = a.summary(now).expect("pre summary");
    let device_before = prepare(&a, 0).device_id;

    a.reset_all_data().expect("reset");
    assert!(a.active_challenge().expect("q").is_none());

    // Straight into a clean sync at the fresh epoch — no stale tail at all.
    let fresh = prepare(&a, 0);
    assert_ne!(
        fresh.device_id, device_before,
        "reset re-mints the device id"
    );
    let recovered = apply(
        &a,
        fresh.reset_epoch,
        Vec::new(),
        &config,
        None,
        server_pull(&events, max_seq, fresh.last_server_seq),
        max_seq,
    )
    .expect("pull");
    assert_eq!(recovered.outcome, SyncOutcome::Applied);
    assert_eq!(recovered.inserted, 2);
    assert_eq!(a.day_state(day.into(), now).expect("post day"), pre_day);
    assert_eq!(a.summary(now).expect("post summary"), pre_summary);
}

#[test]
fn malformed_config_on_a_live_epoch_does_not_advance_the_push_watermark() {
    let (_da, a) = store_a();
    log_mixed_day(&a);
    let before = prepare(&a, 10_000);
    let uuids: Vec<String> = before.pending.iter().map(|e| e.uuid.clone()).collect();
    let mut block: serde_json::Value =
        serde_json::from_str(&before.config_json).expect("config json");
    block["challenge"]["challenge"]["start_date"] = serde_json::json!("NOT-A-DATE");

    apply(
        &a,
        before.reset_epoch,
        uuids,
        &block.to_string(),
        None,
        Vec::new(),
        9,
    )
    .expect_err("malformed config is an error on a live epoch");

    let after = prepare(&a, 10_000);
    assert_eq!(after.pending.len(), before.pending.len());
    assert_eq!(after.pending[0].uuid, before.pending[0].uuid);
    assert_eq!(after.last_server_seq, 0);
    assert_eq!(
        a.active_challenge().unwrap().unwrap().start_date,
        "2026-06-21"
    );
}

#[test]
fn follow_up_is_stale_or_a_full_batch_or_more() {
    assert!(sync_follow_up(0, 500, false, SyncOutcome::StaleReset));
    assert!(sync_follow_up(500, 500, false, SyncOutcome::Applied));
    assert!(sync_follow_up(3, 500, true, SyncOutcome::Applied));
    assert!(
        !sync_follow_up(499, 500, false, SyncOutcome::Applied),
        "a short applied batch does not continue, winner or not"
    );
    assert!(!sync_follow_up(0, 500, false, SyncOutcome::Applied));
}

fn book(store: &DromeStore) -> String {
    store
        .active_challenge()
        .expect("query")
        .expect("challenge")
        .current_book
        .unwrap_or_default()
}
