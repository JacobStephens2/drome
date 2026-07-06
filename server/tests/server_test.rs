//! drome-server integration tests (docs/PHASE2.md "Tests"): auth against a
//! mock JWKS, session verify/refresh/revoke, the two-device sync round-trip
//! (two real client stores + one in-process server), replay/dedup, the
//! active-challenge conflict, the entitlement gate, and account deletion.

mod common;

use std::sync::Arc;

use axum::http::StatusCode;
use common::{
    json_request, json_request_xff, sign_token, sign_token_with_nonce, test_server,
    test_server_opts, test_server_with_clock, valid_token, AUDIENCE, ISSUER,
};
use drome_core::{
    BackfilledDay, DromeStore, LocalInstant, NewChallenge, RulesetKind, WireEvent, JOB_EXTRA_ID,
};
use serde_json::{json, Value};
use tempfile::TempDir;

const TZ: i32 = -18_000;
const GALLON_ML: i64 = 3_785;
const CTX: &str = "acct";

// --- client-store helpers --------------------------------------------------

struct Client {
    _dir: TempDir,
    store: Arc<DromeStore>,
}

fn new_client() -> Client {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir
        .path()
        .join("client.sqlite")
        .to_string_lossy()
        .into_owned();
    let store = DromeStore::open(path).expect("open client store");
    Client { _dir: dir, store }
}

fn at(date: &str, hour: i64, minute: i64) -> LocalInstant {
    let d = drome_core::time::parse_date(date).expect("test date");
    let wall =
        drome_core::time::wall_secs_at_midnight(d).expect("in range") + hour * 3_600 + minute * 60;
    LocalInstant {
        epoch_secs: wall - i64::from(TZ),
        tz_offset_secs: TZ,
    }
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

/// Logs a mixed day-14 (water + correction, two workouts, all attestations,
/// reading, a photo with a ref, an extra, and a revoke) on `store`.
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
    store
        .revoke_event(extra.event_uuid, at(d, 21, 1))
        .expect("revoke");
    store
        .log_extra_done(JOB_EXTRA_ID.into(), at(d, 21, 2), None)
        .expect("extra2");
}

/// One full sync round-trip for a client store against the server, returning
/// the parsed response (so tests can inspect conflicts etc.). Mirrors what the
/// iOS SyncEngine will do: gather pending + config, POST, apply the response.
async fn sync(app: &axum::Router, token: &str, store: &DromeStore) -> Value {
    // Capture the reset epoch at the START of the round-trip (as the iOS
    // SyncEngine will): every tail write below carries it, so a local "Start
    // over" mid-round-trip makes those writes no-op instead of resurrecting
    // pre-reset sync state (docs/PHASE2.md, sync/reset epoch invariant).
    let reset_epoch = store.current_reset_epoch().expect("reset epoch");
    let device_id = store.device_id().expect("device id");
    let last = store.last_server_seq(CTX.into()).expect("last seq");
    let pending = store.pending_events(CTX.into(), 10_000).expect("pending");
    let config: Value =
        serde_json::from_str(&store.export_config_state().expect("config")).expect("config json");

    let body = json!({
        "device_id": device_id,
        "last_server_seq": last,
        "events": serde_json::to_value(&pending).expect("events json"),
        "config": config,
    });
    let (status, resp) = json_request(app, "POST", "/v1/sync", Some(token), body).await;
    assert_eq!(status, StatusCode::OK, "sync failed: {resp}");

    // Apply the response exactly as a client would: ack pushed, adopt config,
    // apply pulled events + advance the cursor atomically.
    let acked: Vec<String> = serde_json::from_value(resp["acked_uuids"].clone()).expect("acked");
    store
        .ack_pushed(CTX.into(), acked, reset_epoch)
        .expect("ack");
    // On a one-active-challenge conflict the server's winner is authoritative:
    // force-adopt it (LWW cannot, when the loser's local stamp is newer).
    // Otherwise merge config by LWW.
    let config_json = resp["config"].to_string();
    if let Some(winner) = resp["active_challenge_conflict"]["winner_challenge_id"].as_str() {
        store
            .adopt_active_challenge(config_json, winner.to_owned())
            .expect("adopt winner");
    } else {
        store
            .apply_remote_config(config_json, reset_epoch)
            .expect("apply config");
    }
    let events: Vec<WireEvent> =
        serde_json::from_value(resp["events"].clone()).expect("pulled events");
    let new_last = resp["new_last_server_seq"].as_i64().expect("new seq");
    store
        .apply_pull_batch(CTX.into(), events, new_last, reset_epoch)
        .expect("apply pull batch");
    resp
}

async fn authenticate(app: &axum::Router, sub: &str) -> String {
    let (status, body) = json_request(
        app,
        "POST",
        "/v1/auth/apple",
        None,
        json!({ "identity_token": valid_token(sub) }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "auth failed: {body}");
    body["access_token"]
        .as_str()
        .expect("access token")
        .to_owned()
}

// --- health + auth ---------------------------------------------------------

#[tokio::test]
async fn healthz_is_public_and_ok() {
    let srv = test_server(true);
    let (status, _b) = json_request(&srv.app, "GET", "/healthz", None, Value::Null).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn healthz_reports_503_when_the_db_is_unreachable() {
    let srv = test_server(true);
    // Poison the shared DB mutex (a real outage: a handler panicked mid-write).
    // A static-200 healthz would stay green through this and greenlight a deploy
    // over a wedged DB; the query-backed one must fail closed.
    let db = srv.state.db.clone();
    let _ = std::thread::spawn(move || {
        let _guard = db.lock().expect("lock");
        panic!("poison the db mutex");
    })
    .join();

    let (status, _b) = json_request(&srv.app, "GET", "/healthz", None, Value::Null).await;
    assert_eq!(
        status,
        StatusCode::SERVICE_UNAVAILABLE,
        "healthz must fail closed when the DB is unreachable"
    );
}

#[tokio::test]
async fn apple_auth_enforces_nonce_binding() {
    use drome_server::auth::hash_token;
    let srv = test_server(true);

    // A real SIWA flow: the client picks a raw nonce and hands Apple its
    // sha256; Apple echoes that hash into the token's `nonce` claim.
    let raw = "client-raw-nonce-3f9a2c";
    let claim = hash_token(raw); // == sha256(raw) hex
    let token = sign_token_with_nonce("sub-nonce", AUDIENCE, ISSUER, 3_600, Some(&claim));

    // Matching raw nonce → a session is issued.
    let (status, body) = json_request(
        &srv.app,
        "POST",
        "/v1/auth/apple",
        None,
        json!({ "identity_token": token, "nonce": raw }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "matching nonce must authenticate");
    assert!(body["access_token"].as_str().is_some());

    // Wrong raw nonce → 401 (someone replaying a stolen token can't forge it).
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/auth/apple",
        None,
        json!({ "identity_token": token, "nonce": "attacker-guess" }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "mismatched nonce rejected"
    );

    // Token carries a nonce claim but the client supplies none → 401. A token
    // minted with replay binding must not be redeemable without the raw nonce.
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/auth/apple",
        None,
        json!({ "identity_token": token }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "a nonce-bound token requires the raw nonce"
    );

    // Legacy token (no nonce claim) + no supplied nonce still authenticates, so
    // the check is additive, not a hard break for pre-nonce clients.
    let legacy = valid_token("sub-legacy");
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/auth/apple",
        None,
        json!({ "identity_token": legacy }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "no-nonce token still works");
}

#[tokio::test]
async fn apple_auth_happy_expired_and_bad_audience() {
    let srv = test_server(true);

    // Happy path: a valid token mints a session.
    let (status, body) = json_request(
        &srv.app,
        "POST",
        "/v1/auth/apple",
        None,
        json!({ "identity_token": valid_token("apple-sub-1") }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["access_token"].as_str().is_some());
    assert!(body["refresh_token"].as_str().is_some());

    // Expired token → 401.
    let expired = sign_token("apple-sub-1", AUDIENCE, ISSUER, -3_600);
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/auth/apple",
        None,
        json!({ "identity_token": expired }),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // Wrong audience → 401.
    let bad_aud = sign_token("apple-sub-1", "com.someone.else", ISSUER, 3_600);
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/auth/apple",
        None,
        json!({ "identity_token": bad_aud }),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn apple_auth_upserts_one_account_per_sub() {
    let srv = test_server(true);
    for _ in 0..3 {
        let (status, _b) = json_request(
            &srv.app,
            "POST",
            "/v1/auth/apple",
            None,
            json!({ "identity_token": valid_token("stable-sub") }),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }
    let conn = srv.state.db.lock().unwrap();
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM account", [], |r| r.get(0))
        .unwrap();
    assert_eq!(
        count, 1,
        "repeated sign-in must not create duplicate accounts"
    );
}

// --- local-dev auth (DROME_DEV_AUTH) ---------------------------------------

#[tokio::test]
async fn dev_auth_is_unreachable_and_mints_nothing_by_default() {
    // Default (production) configuration: DROME_DEV_AUTH unset → the route is
    // not even mounted, so it 404s and no synthetic account can be created.
    let srv = test_server(true);

    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/auth/dev",
        None,
        json!({ "account_key": "alice" }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "dev auth must be unreachable without DROME_DEV_AUTH=1"
    );

    // The rejected call created nothing.
    let accounts: i64 = {
        let conn = srv.state.db.lock().unwrap();
        conn.query_row("SELECT COUNT(*) FROM account", [], |r| r.get(0))
            .unwrap()
    };
    assert_eq!(accounts, 0, "no dev account may be creatable by default");
}

#[tokio::test]
async fn dev_auth_mints_a_session_that_authenticates_sync() {
    // With DROME_DEV_AUTH enabled, /v1/auth/dev mints a normal session (same
    // shape as /v1/auth/apple) that authorizes the rest of the API.
    let srv = test_server_opts(true, true);

    let (status, body) = json_request(
        &srv.app,
        "POST",
        "/v1/auth/dev",
        None,
        json!({ "account_key": "alice" }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "dev auth must mint a session: {body}"
    );
    let token = body["access_token"]
        .as_str()
        .expect("access token")
        .to_owned();
    assert!(body["refresh_token"].as_str().is_some());
    assert!(body["account_id"].as_i64().is_some());

    // The synthetic account is keyed by "dev:" + account_key.
    {
        let conn = srv.state.db.lock().unwrap();
        let sub: String = conn
            .query_row(
                "SELECT apple_sub FROM account WHERE id = ?1",
                [body["account_id"].as_i64().unwrap()],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(sub, "dev:alice");
    }

    // The token drives a real /v1/sync round-trip: a dev session is treated
    // identically to an Apple one.
    let client = new_client();
    client
        .store
        .create_challenge(challenge_cfg("2026-06-21", at("2026-07-04", 9, 0)))
        .expect("create");
    log_mixed_day(&client.store);
    sync(&srv.app, &token, &client.store).await;

    let events: i64 = {
        let conn = srv.state.db.lock().unwrap();
        conn.query_row("SELECT COUNT(*) FROM event", [], |r| r.get(0))
            .unwrap()
    };
    assert!(
        events > 0,
        "dev session must be able to push events via sync"
    );
}

#[tokio::test]
async fn dev_auth_two_keys_are_isolated_accounts() {
    let srv = test_server_opts(true, true);

    let alice = json_request(
        &srv.app,
        "POST",
        "/v1/auth/dev",
        None,
        json!({ "account_key": "alice" }),
    )
    .await
    .1;
    let bob = json_request(
        &srv.app,
        "POST",
        "/v1/auth/dev",
        None,
        json!({ "account_key": "bob" }),
    )
    .await
    .1;

    let alice_id = alice["account_id"].as_i64().expect("alice id");
    let bob_id = bob["account_id"].as_i64().expect("bob id");
    assert_ne!(alice_id, bob_id, "distinct keys are distinct accounts");
    assert_eq!(
        {
            let conn = srv.state.db.lock().unwrap();
            conn.query_row("SELECT COUNT(*) FROM account", [], |r| r.get::<_, i64>(0))
                .unwrap()
        },
        2,
        "exactly two synthetic accounts exist"
    );

    // Isolation is real, not just distinct ids: alice pushes a challenge; bob,
    // a separate account, pulls nothing of hers.
    let alice_token = alice["access_token"].as_str().unwrap();
    let bob_token = bob["access_token"].as_str().unwrap();

    let a = new_client();
    a.store
        .create_challenge(challenge_cfg("2026-06-21", at("2026-07-04", 9, 0)))
        .expect("create");
    log_mixed_day(&a.store);
    sync(&srv.app, alice_token, &a.store).await;

    let b = new_client();
    let resp = sync(&srv.app, bob_token, &b.store).await;
    let pulled: Vec<WireEvent> =
        serde_json::from_value(resp["events"].clone()).expect("bob pulled");
    assert!(
        pulled.is_empty(),
        "bob's account must not see alice's events"
    );
    assert!(
        b.store.active_challenge().unwrap().is_none(),
        "bob has no challenge of his own"
    );
}

#[tokio::test]
async fn session_verify_refresh_and_revoke() {
    let srv = test_server(true);
    let (status, body) = json_request(
        &srv.app,
        "POST",
        "/v1/auth/apple",
        None,
        json!({ "identity_token": valid_token("sub-session") }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let access = body["access_token"].as_str().unwrap().to_owned();
    let refresh = body["refresh_token"].as_str().unwrap().to_owned();

    // Verify: an authed call succeeds with the access token.
    let (status, _b) = json_request(
        &srv.app,
        "GET",
        "/v1/entitlement",
        Some(&access),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // A bogus token is rejected.
    let (status, _b) = json_request(
        &srv.app,
        "GET",
        "/v1/entitlement",
        Some("not-a-token"),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // Refresh rotates: new tokens work, the OLD access token is now invalid.
    let (status, body) = json_request(
        &srv.app,
        "POST",
        "/v1/auth/refresh",
        None,
        json!({ "refresh_token": refresh }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let new_access = body["access_token"].as_str().unwrap().to_owned();

    let (status, _b) = json_request(
        &srv.app,
        "GET",
        "/v1/entitlement",
        Some(&access),
        Value::Null,
    )
    .await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "old access token must be revoked on rotate"
    );
    let (status, _b) = json_request(
        &srv.app,
        "GET",
        "/v1/entitlement",
        Some(&new_access),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // Revoke: deleting the account invalidates the session entirely.
    let (status, _b) = json_request(
        &srv.app,
        "DELETE",
        "/v1/account",
        Some(&new_access),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _b) = json_request(
        &srv.app,
        "GET",
        "/v1/entitlement",
        Some(&new_access),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

// --- THE BIG ONE: two-device sync round-trip -------------------------------

#[tokio::test]
async fn two_device_sync_round_trip_matches_projections() {
    let srv = test_server(true);
    let token = authenticate(&srv.app, "sub-sync").await;
    let now = at("2026-07-04", 22, 0);

    // Device A: a backfilled fixture plus a mixed live day 14.
    let a = new_client();
    a.store
        .create_challenge(challenge_cfg("2026-06-21", at("2026-07-04", 9, 0)))
        .expect("create");
    a.store
        .set_extra_enabled(JOB_EXTRA_ID.into(), true, at("2026-07-04", 9, 1))
        .expect("extra");
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
    a.store
        .backfill_days(days, at("2026-07-04", 9, 5))
        .expect("backfill");
    log_mixed_day(&a.store);

    // A syncs (push). Nothing to pull back yet.
    sync(&srv.app, &token, &a.store).await;

    // Device B syncs from empty: pulls A's config + events and applies them.
    let b = new_client();
    sync(&srv.app, &token, &b.store).await;

    for date in ["2026-06-21", "2026-06-24", "2026-07-03", "2026-07-04"] {
        assert_eq!(
            a.store.day_state(date.into(), now).expect("a day"),
            b.store.day_state(date.into(), now).expect("b day"),
            "day_state diverged on {date}"
        );
    }
    assert_eq!(
        a.store.summary(now).expect("a summary"),
        b.store.summary(now).expect("b summary")
    );
    assert_eq!(
        a.store.export_csv(now).expect("a csv"),
        b.store.export_csv(now).expect("b csv")
    );

    // Photo ref never left device A: B has the flag but no ref.
    let b_export = b.store.export_json(now).expect("b export");
    assert!(!b_export.contains("/photos/day14.jpg"));
    assert!(
        b.store
            .day_state("2026-07-04".into(), now)
            .expect("b day")
            .photo_done
    );

    // B logs more; A pulls and must match B.
    b.store
        .log_reading("Deep Work".into(), 15, at("2026-07-05", 7, 0), None)
        .expect("b read");
    b.store
        .log_water(3_800, at("2026-07-05", 8, 0), None)
        .expect("b water");
    b.store
        .log_workout(60, true, None, None, at("2026-07-05", 9, 0), None)
        .expect("b outdoor");
    b.store
        .log_workout(20, false, None, None, at("2026-07-05", 18, 0), None)
        .expect("b indoor");
    b.store
        .log_diet_ok(at("2026-07-05", 20, 0), None)
        .expect("b diet");
    b.store
        .log_no_junk_ok(at("2026-07-05", 20, 1), None)
        .expect("b nj");
    b.store
        .log_photo_done(None, at("2026-07-05", 20, 2), None)
        .expect("b photo");
    sync(&srv.app, &token, &b.store).await;
    sync(&srv.app, &token, &a.store).await;

    let later = at("2026-07-05", 22, 0);
    assert_eq!(
        a.store
            .day_state("2026-07-05".into(), later)
            .expect("a d15"),
        b.store
            .day_state("2026-07-05".into(), later)
            .expect("b d15")
    );
    assert_eq!(
        a.store.summary(later).expect("a s2"),
        b.store.summary(later).expect("b s2")
    );
    assert_eq!(
        a.store.export_csv(later).expect("a csv2"),
        b.store.export_csv(later).expect("b csv2")
    );
}

#[tokio::test]
async fn replay_of_the_same_batch_is_a_no_op() {
    let srv = test_server(true);
    let token = authenticate(&srv.app, "sub-replay").await;

    let a = new_client();
    a.store
        .create_challenge(challenge_cfg("2026-06-21", at("2026-07-04", 9, 0)))
        .expect("create");
    log_mixed_day(&a.store);

    // Capture A's first pending batch BEFORE syncing.
    let device_id = a.store.device_id().unwrap();
    let batch = a.store.pending_events(CTX.into(), 10_000).unwrap();
    let config: Value = serde_json::from_str(&a.store.export_config_state().unwrap()).unwrap();
    sync(&srv.app, &token, &a.store).await;

    let count_after_first: i64 = {
        let conn = srv.state.db.lock().unwrap();
        conn.query_row("SELECT COUNT(*) FROM event", [], |r| r.get(0))
            .unwrap()
    };
    assert_eq!(count_after_first as usize, batch.len());

    // Re-push the exact same batch: the server dedups by uuid — all acked, no
    // new rows inserted.
    let body = json!({
        "device_id": device_id,
        "last_server_seq": 0,
        "events": serde_json::to_value(&batch).unwrap(),
        "config": config,
    });
    let (status, resp) = json_request(&srv.app, "POST", "/v1/sync", Some(&token), body).await;
    assert_eq!(status, StatusCode::OK);
    let acked: Vec<String> = serde_json::from_value(resp["acked_uuids"].clone()).unwrap();
    assert_eq!(
        acked.len(),
        batch.len(),
        "every replayed uuid is still acked"
    );

    let count_after_replay: i64 = {
        let conn = srv.state.db.lock().unwrap();
        conn.query_row("SELECT COUNT(*) FROM event", [], |r| r.get(0))
            .unwrap()
    };
    assert_eq!(
        count_after_replay, count_after_first,
        "replay inserted nothing"
    );
}

#[tokio::test]
async fn one_active_challenge_conflict_archives_the_loser() {
    let srv = test_server(true);
    let token = authenticate(&srv.app, "sub-conflict").await;

    // The REALISTIC split-brain: sync order and creation time are independent.
    // Winner is created EARLIER (10:00) and synced FIRST (first-active-wins),
    // but the loser is created LATER (12:00) so its config LWW stamp is NEWER.
    // Pure LWW would refuse to adopt the winner (the older stamp loses) and the
    // loser would keep its own active challenge forever — a permanent
    // split-brain. Adoption must be driven by the server's conflict signal, not
    // LWW. (Reverse of the artificial winner-created-later tuning that hid this.)
    let winner = new_client();
    winner
        .store
        .create_challenge(challenge_cfg("2026-06-21", at("2026-07-04", 10, 0)))
        .expect("winner challenge");
    let winner_id = winner.store.active_challenge().unwrap().unwrap().id;
    sync(&srv.app, &token, &winner.store).await;

    // Loser: a DIFFERENT active challenge, created LATER, synced second.
    let loser = new_client();
    loser
        .store
        .create_challenge(challenge_cfg("2026-06-01", at("2026-07-04", 12, 0)))
        .expect("loser challenge");
    let loser_id = loser.store.active_challenge().unwrap().unwrap().id;
    assert_ne!(winner_id, loser_id);

    let resp = sync(&srv.app, &token, &loser.store).await;

    // The response tells the loser its challenge was archived; the winner id
    // is reported.
    let conflict = &resp["active_challenge_conflict"];
    assert_eq!(conflict["archived_challenge_id"], json!(loser_id));
    assert_eq!(conflict["winner_challenge_id"], json!(winner_id));

    // Server: the account's active challenge is the winner; the loser's
    // challenge slot is stored with the sync_conflict label.
    {
        let conn = srv.state.db.lock().unwrap();
        let active: String = conn
            .query_row(
                "SELECT active_challenge_id FROM account WHERE apple_sub = 'sub-conflict'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(active, winner_id);
        let conflicted: i64 = conn
            .query_row(
                "SELECT sync_conflict FROM config_slot WHERE slot = 'challenge' AND challenge_id = ?1",
                [&loser_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(conflicted, 1);
    }

    // The loser store pulled the winner and adopted it as its active challenge.
    let loser_active = loser.store.active_challenge().unwrap().unwrap();
    assert_eq!(loser_active.id, winner_id);
    assert!(loser_active.active);
}

#[tokio::test]
async fn archived_loser_events_never_propagate() {
    let srv = test_server(true);
    let token = authenticate(&srv.app, "sub-orphan").await;

    // Winner: an active challenge with a logged event, synced first.
    let winner = new_client();
    winner
        .store
        .create_challenge(challenge_cfg("2026-06-21", at("2026-07-04", 10, 0)))
        .expect("winner challenge");
    let winner_id = winner.store.active_challenge().unwrap().unwrap().id;
    winner
        .store
        .log_water(2_000, at("2026-07-04", 8, 0), None)
        .expect("winner water");
    sync(&srv.app, &token, &winner.store).await;

    // Loser: a DIFFERENT active challenge with ITS OWN logged events, synced
    // second (it loses the one-active-challenge race and adopts the winner).
    let loser = new_client();
    loser
        .store
        .create_challenge(challenge_cfg("2026-06-01", at("2026-07-04", 12, 0)))
        .expect("loser challenge");
    let loser_id = loser.store.active_challenge().unwrap().unwrap().id;
    loser
        .store
        .log_water(999, at("2026-07-04", 9, 0), None)
        .expect("loser water");
    loser
        .store
        .log_reading("Other Book".into(), 5, at("2026-07-04", 10, 0), None)
        .expect("loser read");
    let resp = sync(&srv.app, &token, &loser.store).await;
    assert!(
        resp["active_challenge_conflict"].is_object(),
        "loser must lose the race"
    );

    // A THIRD, fresh device pulls: it may receive ONLY the winner's events.
    // The loser's events reference an archived challenge whose config is not
    // pullable — propagating them would seed every device with dead orphans.
    let third = new_client();
    let resp3 = sync(&srv.app, &token, &third.store).await;
    let pulled: Vec<WireEvent> =
        serde_json::from_value(resp3["events"].clone()).expect("third pulled");
    assert!(
        !pulled.is_empty(),
        "third device pulled the winner's real events"
    );
    for e in &pulled {
        assert_eq!(
            e.challenge_id, winner_id,
            "only the active challenge's events propagate"
        );
        assert_ne!(e.challenge_id, loser_id, "archived-loser event leaked");
    }

    // The third device converges to the winner's projection (999 ml never
    // reaches it; the winner's 2000 ml does).
    let now = at("2026-07-04", 22, 0);
    let third_day = third
        .store
        .day_state("2026-07-04".into(), now)
        .expect("third");
    assert_eq!(third_day.water_ml, 2_000);
    assert_eq!(
        third_day,
        winner
            .store
            .day_state("2026-07-04".into(), now)
            .expect("winner day")
    );
}

#[tokio::test]
async fn heavy_first_sync_drains_across_capped_pulls() {
    // A device that has never synced pulls the account's whole history. The
    // server caps each pull (PULL_LIMIT) and flags `more`, so a >cap history is
    // drained over several round-trips instead of one giant batch — the client
    // re-triggers while `more` is set. Convergence must still be exact.
    let srv = test_server(true);
    let token = authenticate(&srv.app, "sub-heavy").await;

    let a = new_client();
    a.store
        .create_challenge(challenge_cfg("2026-06-21", at("2026-07-04", 9, 0)))
        .expect("create");
    // Comfortably over the 500-event pull cap so the first pull is capped.
    for _ in 0..550 {
        a.store
            .log_water(100, at("2026-07-04", 8, 0), None)
            .expect("water");
    }
    sync(&srv.app, &token, &a.store).await;

    // Device B drains: each capped round-trip sets `more`; loop until caught up.
    let b = new_client();
    let mut rounds = 0;
    loop {
        let resp = sync(&srv.app, &token, &b.store).await;
        rounds += 1;
        assert!(rounds < 10, "drain must terminate");
        if !resp["more"].as_bool().unwrap_or(false) {
            break;
        }
    }
    assert!(
        rounds >= 2,
        "a >cap history must take multiple capped pulls to drain"
    );

    let now = at("2026-07-04", 22, 0);
    assert_eq!(
        a.store.day_state("2026-07-04".into(), now).expect("a day"),
        b.store.day_state("2026-07-04".into(), now).expect("b day"),
        "B must converge to A after draining every capped pull"
    );
}

#[tokio::test]
async fn reset_device_recovers_its_own_history() {
    let srv = test_server(true);
    let token = authenticate(&srv.app, "sub-reset").await;

    let a = new_client();
    a.store
        .create_challenge(challenge_cfg("2026-06-21", at("2026-07-04", 9, 0)))
        .expect("create");
    a.store
        .log_water(2_000, at("2026-07-04", 8, 0), None)
        .expect("water");
    a.store
        .log_reading("Deep Work".into(), 20, at("2026-07-04", 20, 0), None)
        .expect("read");
    sync(&srv.app, &token, &a.store).await;

    let now = at("2026-07-04", 22, 0);
    let before = a.store.day_state("2026-07-04".into(), now).expect("before");
    assert_eq!(before.water_ml, 2_000);
    assert_eq!(before.reading_pages, 20);

    // Local "Start over" wipes everything, but the device keeps re-syncing the
    // SAME account. The server's pull excludes a device's own pushed events, so
    // recovery hinges on the reset re-minting the device id.
    a.store.reset_all_data().expect("reset");
    assert!(a.store.active_challenge().unwrap().is_none());
    assert_eq!(
        a.store
            .pending_events(CTX.into(), 10_000)
            .expect("pending")
            .len(),
        0,
        "reset leaves an empty local log"
    );

    sync(&srv.app, &token, &a.store).await;

    // The device recovered its OWN server-held config and events.
    let after = a.store.day_state("2026-07-04".into(), now).expect("after");
    assert_eq!(
        after.water_ml, before.water_ml,
        "reset device must recover its own water"
    );
    assert_eq!(after, before, "reset device must recover its full day");
}

#[tokio::test]
async fn refresh_rejects_expired_session() {
    let srv = test_server(true);
    let (status, body) = json_request(
        &srv.app,
        "POST",
        "/v1/auth/apple",
        None,
        json!({ "identity_token": valid_token("sub-refresh-exp") }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let refresh = body["refresh_token"].as_str().unwrap().to_owned();

    // The session has already expired (its 30-day window elapsed).
    {
        let conn = srv.state.db.lock().unwrap();
        conn.execute("UPDATE session SET expires_at_epoch = 1", [])
            .unwrap();
    }

    // An expired refresh token must NOT rotate into a brand-new session, or the
    // TTL bounds nothing and a leaked token is a permanent credential.
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/auth/refresh",
        None,
        json!({ "refresh_token": refresh }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "expired refresh token must not mint a fresh session"
    );
}

#[tokio::test]
async fn public_auth_is_ip_rate_limited() {
    let srv = test_server(true);

    // Hammer /v1/auth/apple from ONE IP with garbage tokens (each rejected fast
    // but still consuming an IP token). Once the bucket drains, the IP is 429'd
    // before the handler runs — the anonymous surface has backpressure.
    let mut saw_429 = false;
    for _ in 0..140 {
        let (status, _b) = json_request_xff(
            &srv.app,
            "/v1/auth/apple",
            "203.0.113.7",
            json!({ "identity_token": "garbage" }),
        )
        .await;
        if status == StatusCode::TOO_MANY_REQUESTS {
            saw_429 = true;
            break;
        }
    }
    assert!(
        saw_429,
        "a single IP must be throttled on the anonymous auth surface"
    );

    // A DIFFERENT IP is unaffected (per-IP isolation): its garbage token is
    // processed to a 401, not blanket-429'd.
    let (status, _b) = json_request_xff(
        &srv.app,
        "/v1/auth/apple",
        "198.51.100.42",
        json!({ "identity_token": "garbage" }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "a fresh IP must not be throttled"
    );
}

#[tokio::test]
async fn entitlement_gate_flips_with_the_env() {
    // Beta OFF, no entitlement row: sync is blocked, but auth + entitlement
    // status + account delete still work.
    let srv = test_server(false);
    let token = authenticate(&srv.app, "sub-ent").await;

    let (status, body) = json_request(
        &srv.app,
        "GET",
        "/v1/entitlement",
        Some(&token),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["entitled"], json!(false));

    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/sync",
        Some(&token),
        json!({ "device_id": "dev-1", "last_server_seq": 0, "events": [], "config": {} }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::PAYMENT_REQUIRED,
        "sync must be gated when not entitled"
    );

    // Beta ON: the same call passes.
    let srv_on = test_server(true);
    let token_on = authenticate(&srv_on.app, "sub-ent").await;
    let (status, body) = json_request(
        &srv_on.app,
        "GET",
        "/v1/entitlement",
        Some(&token_on),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["entitled"], json!(true));
    let (status, _b) = json_request(
        &srv_on.app,
        "POST",
        "/v1/sync",
        Some(&token_on),
        json!({ "device_id": "dev-1", "last_server_seq": 0, "events": [], "config": {} }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn delete_account_leaves_no_rows() {
    let srv = test_server(true);
    let token = authenticate(&srv.app, "sub-delete").await;

    let a = new_client();
    a.store
        .create_challenge(challenge_cfg("2026-06-21", at("2026-07-04", 9, 0)))
        .expect("create");
    log_mixed_day(&a.store);
    sync(&srv.app, &token, &a.store).await;

    // Rows exist before deletion.
    {
        let conn = srv.state.db.lock().unwrap();
        let events: i64 = conn
            .query_row("SELECT COUNT(*) FROM event", [], |r| r.get(0))
            .unwrap();
        assert!(events > 0);
    }

    let (status, _b) =
        json_request(&srv.app, "DELETE", "/v1/account", Some(&token), Value::Null).await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let conn = srv.state.db.lock().unwrap();
    for table in [
        "account",
        "event",
        "config_slot",
        "session",
        "membership",
        "entitlement",
    ] {
        let count: i64 = conn
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 0, "{table} still had rows after account deletion");
    }
}

// --- groups -----------------------------------------------------------------

/// Authenticate a sub and return (access_token, account_id).
async fn auth_account(app: &axum::Router, sub: &str) -> (String, i64) {
    let (status, body) = json_request(
        app,
        "POST",
        "/v1/auth/apple",
        None,
        json!({ "identity_token": valid_token(sub) }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "auth failed: {body}");
    (
        body["access_token"].as_str().expect("token").to_owned(),
        body["account_id"].as_i64().expect("account id"),
    )
}

/// Create a group; returns (group_id, invite_code).
async fn create_group(
    app: &axum::Router,
    token: &str,
    name: &str,
    display: &str,
) -> (String, String) {
    let (status, body) = json_request(
        app,
        "POST",
        "/v1/groups",
        Some(token),
        json!({ "name": name, "display_name": display }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "create group failed: {body}");
    (
        body["id"].as_str().expect("group id").to_owned(),
        body["invite_code"]
            .as_str()
            .expect("invite code")
            .to_owned(),
    )
}

/// A challenge cfg carrying sentinel strings in every field the group surface
/// must NEVER leak (diet text, book title). Start day 2026-06-21 → day 14 on
/// 2026-07-04.
fn sentinel_cfg() -> NewChallenge {
    NewChallenge {
        ruleset: RulesetKind::Flexible,
        start_date: "2026-06-21".into(),
        length_days: 75,
        day_cutoff_minutes: 240,
        waking_start_minutes: 420,
        waking_end_minutes: 1320,
        initial_water_goal_ml: GALLON_ML,
        diet_description: Some("SENTINELDIET_carnivore_only".into()),
        current_book: Some("SENTINELBOOK_deepwork".into()),
        created_at: at("2026-07-04", 9, 0),
    }
}

/// Logs a fully-complete day 14 whose payloads carry sentinels (note, photo
/// ref, book title) and distinctive water amounts, with the weekly job extra
/// enabled + done.
fn log_sentinel_day(store: &DromeStore) {
    store
        .set_extra_enabled(JOB_EXTRA_ID.into(), true, at("2026-07-04", 9, 1))
        .expect("enable extra");
    let d = "2026-07-04";
    store.log_water(1_234, at(d, 8, 0), None).expect("water");
    store.log_water(2_601, at(d, 9, 0), None).expect("water2");
    store
        .log_workout(
            45,
            true,
            Some("SENTINELNOTE_shin_splints".into()),
            None,
            at(d, 9, 30),
            None,
        )
        .expect("outdoor");
    store
        .log_workout(30, false, None, None, at(d, 18, 0), None)
        .expect("indoor");
    store
        .log_reading("SENTINELBOOK_deepwork".into(), 20, at(d, 20, 0), None)
        .expect("read");
    store.log_diet_ok(at(d, 20, 5), None).expect("diet");
    store.log_no_junk_ok(at(d, 20, 6), None).expect("no junk");
    store
        .log_photo_done(
            Some("SENTINELPHOTO_/private/day14.jpg".into()),
            at(d, 20, 7),
            None,
        )
        .expect("photo");
    store
        .log_extra_done(JOB_EXTRA_ID.into(), at(d, 21, 0), None)
        .expect("extra");
}

#[tokio::test]
async fn groups_require_auth() {
    let srv = test_server(true);
    for (method, uri) in [
        ("POST", "/v1/groups"),
        ("GET", "/v1/groups"),
        ("POST", "/v1/groups/join"),
        ("GET", "/v1/groups/abc"),
        ("POST", "/v1/groups/abc/leave"),
        ("POST", "/v1/groups/abc/nudge"),
        ("GET", "/v1/nudges"),
    ] {
        let (status, _b) = json_request(&srv.app, method, uri, None, json!({})).await;
        assert_eq!(
            status,
            StatusCode::UNAUTHORIZED,
            "{method} {uri} must require auth"
        );
    }
}

#[tokio::test]
async fn create_and_join_by_code() {
    let srv = test_server(true);
    let (alice, _aid) = auth_account(&srv.app, "sub-alice").await;
    let (bob, _bid) = auth_account(&srv.app, "sub-bob").await;

    let (gid, code) = create_group(&srv.app, &alice, "Summer Crew", "Alice").await;

    // Bob joins by code.
    let (status, body) = json_request(
        &srv.app,
        "POST",
        "/v1/groups/join",
        Some(&bob),
        json!({ "invite_code": code, "display_name": "Bob" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "join failed: {body}");
    assert_eq!(body["id"], json!(gid));

    // Bob's group list shows the group with member_count 2 and HIS display name.
    let (status, body) = json_request(&srv.app, "GET", "/v1/groups", Some(&bob), Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    let groups = body["groups"].as_array().expect("groups array");
    assert_eq!(groups.len(), 1);
    assert_eq!(groups[0]["id"], json!(gid));
    assert_eq!(groups[0]["member_count"], json!(2));
    assert_eq!(groups[0]["my_display_name"], json!("Bob"));

    // Re-joining is idempotent and updates the display name (no second row).
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/groups/join",
        Some(&bob),
        json!({ "invite_code": code, "display_name": "Bobby" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_s, body) = json_request(&srv.app, "GET", "/v1/groups", Some(&bob), Value::Null).await;
    assert_eq!(
        body["groups"][0]["member_count"],
        json!(2),
        "re-join must not add a row"
    );
    assert_eq!(body["groups"][0]["my_display_name"], json!("Bobby"));
}

#[tokio::test]
async fn join_with_invalid_code_is_404() {
    let srv = test_server(true);
    let (alice, _aid) = auth_account(&srv.app, "sub-alice").await;
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/groups/join",
        Some(&alice),
        json!({ "invite_code": "ZZZZZZZZ", "display_name": "Alice" }),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "an invalid code must 404");
}

#[tokio::test]
async fn non_member_group_access_is_404_no_leak() {
    let srv = test_server(true);
    let (alice, _aid) = auth_account(&srv.app, "sub-alice").await;
    let (carol, _carol_id) = auth_account(&srv.app, "sub-carol").await;

    let (gid, _code) = create_group(&srv.app, &alice, "Private", "Alice").await;

    // Carol is not a member: GET the group → 404 (identical to a nonexistent
    // group, so she can't even confirm it exists).
    let (status, _b) = json_request(
        &srv.app,
        "GET",
        &format!("/v1/groups/{gid}"),
        Some(&carol),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _b) = json_request(
        &srv.app,
        "GET",
        "/v1/groups/totally-made-up-id",
        Some(&carol),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // Carol nudging into the group → 404 (no leak that the group or members
    // exist). She's not a member, so require_membership 404s before the handle
    // is ever resolved.
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        &format!("/v1/groups/{gid}/nudge"),
        Some(&carol),
        json!({ "to_member_handle": "deadbeefdeadbeefdeadbeefdeadbeef" }),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // Leaving a group she isn't in → 404.
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        &format!("/v1/groups/{gid}/leave"),
        Some(&carol),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

/// THE PRIVACY TEST: a member with a rich, sensitive day exposes ONLY the
/// allowed fields — no photo ref, note text, diet description, water amount, or
/// the extra's name/id.
#[tokio::test]
async fn group_member_dto_exposes_only_safe_fields() {
    let now = at("2026-07-04", 22, 0);
    let srv = test_server_with_clock(true, now.epoch_secs);
    let (alice, _alice_id) = auth_account(&srv.app, "sub-alice").await;
    let (gid, _code) = create_group(&srv.app, &alice, "Crew", "Alice").await;

    // Alice syncs a sensitive, fully-complete day 14.
    let a = new_client();
    a.store.create_challenge(sentinel_cfg()).expect("create");
    log_sentinel_day(&a.store);
    sync(&srv.app, &alice, &a.store).await;

    let (status, body) = json_request(
        &srv.app,
        "GET",
        &format!("/v1/groups/{gid}"),
        Some(&alice),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "get group failed: {body}");

    let members = body["members"].as_array().expect("members");
    // Alice is the caller and the sole member: her DTO is the one flagged
    // is_self. The DTO carries an opaque per-group handle, never the account id.
    let dto = members
        .iter()
        .find(|m| m["is_self"] == json!(true))
        .expect("alice's DTO");

    // Exactly the allowed top-level keys — nothing else.
    let mut keys: Vec<&str> = dto
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort();
    assert_eq!(
        keys,
        vec![
            "current_run",
            "day_index",
            "display_name",
            "is_active",
            "is_self",
            "member_handle",
            "tasks",
            "weekly_extra_done",
        ],
        "unexpected keys in member DTO: {dto}"
    );
    // The global account id must NOT appear as a key (it would let a co-present
    // observer correlate the same person across groups).
    assert!(
        dto.get("account_id").is_none(),
        "member DTO must not carry the global account id"
    );
    // Exactly the seven task keys.
    let mut tkeys: Vec<&str> = dto["tasks"]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    tkeys.sort();
    assert_eq!(
        tkeys,
        vec![
            "diet",
            "no_junk",
            "outdoor_workout",
            "photo",
            "reading",
            "second_workout",
            "water",
        ]
    );

    // The values are the honest projection: day 14, all tasks done, weekly done.
    assert_eq!(dto["day_index"], json!(14));
    assert_eq!(dto["is_active"], json!(true));
    for t in [
        "water",
        "outdoor_workout",
        "second_workout",
        "reading",
        "diet",
        "no_junk",
        "photo",
    ] {
        assert_eq!(dto["tasks"][t], json!(true), "task {t} should be done");
    }
    assert_eq!(dto["weekly_extra_done"], json!(true));

    // NOTHING sensitive leaked. Every one of these is present in Alice's synced
    // data (config diet/book, event note/photo-ref, water ml, the extra id).
    // Scan with the random opaque handle removed: a random hex handle could
    // coincidentally contain a forbidden digit-substring yet carries no
    // sensitive data by construction.
    let mut sanitized = dto.clone();
    sanitized.as_object_mut().unwrap().remove("member_handle");
    let serialized = sanitized.to_string();
    for forbidden in [
        "SENTINELDIET_carnivore_only",
        "SENTINELBOOK_deepwork",
        "SENTINELNOTE_shin_splints",
        "SENTINELPHOTO",
        "day14.jpg",
        "1234", // a water amount
        "2601", // the other water amount
        "3835", // their sum
        "job_application",
        "job", // the extra's id/name must never appear
        "Apply to a job",
        "photo_ref",
        "diet_description",
        "water_ml",
    ] {
        assert!(
            !serialized.contains(forbidden),
            "member DTO leaked {forbidden:?}: {serialized}"
        );
    }
}

#[tokio::test]
async fn two_members_see_each_other_third_is_404() {
    let now = at("2026-07-04", 22, 0);
    let srv = test_server_with_clock(true, now.epoch_secs);
    let (alice, _alice_id) = auth_account(&srv.app, "sub-alice").await;
    let (bob, _bob_id) = auth_account(&srv.app, "sub-bob").await;
    let (carol, _cid) = auth_account(&srv.app, "sub-carol").await;

    let (gid, code) = create_group(&srv.app, &alice, "Crew", "Alice").await;
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/groups/join",
        Some(&bob),
        json!({ "invite_code": code, "display_name": "Bob" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // Both sync an active challenge, so both are is_active with day fields.
    let a = new_client();
    a.store.create_challenge(sentinel_cfg()).expect("a create");
    log_sentinel_day(&a.store);
    sync(&srv.app, &alice, &a.store).await;

    let b = new_client();
    b.store.create_challenge(sentinel_cfg()).expect("b create");
    b.store
        .log_water(500, at("2026-07-04", 8, 0), None)
        .expect("b water");
    sync(&srv.app, &bob, &b.store).await;

    // Alice sees both members.
    let (status, body) = json_request(
        &srv.app,
        "GET",
        &format!("/v1/groups/{gid}"),
        Some(&alice),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let members = body["members"].as_array().expect("members");
    assert_eq!(members.len(), 2);
    // Members are identified by display name + opaque handle, never account id.
    let names: Vec<&str> = members
        .iter()
        .filter_map(|m| m["display_name"].as_str())
        .collect();
    assert!(names.contains(&"Alice") && names.contains(&"Bob"));
    // Exactly one member is flagged is_self for the caller (Alice); the handles
    // are distinct opaque strings and no global account id is present.
    let self_count = members
        .iter()
        .filter(|m| m["is_self"] == json!(true))
        .count();
    assert_eq!(self_count, 1, "exactly the caller is is_self");
    for m in members {
        assert!(
            m["member_handle"].as_str().is_some_and(|h| !h.is_empty()),
            "every member carries an opaque handle"
        );
        assert!(
            m.get("account_id").is_none(),
            "no global account id on the wire"
        );
        assert_eq!(
            m["is_active"],
            json!(true),
            "both synced an active challenge"
        );
    }
    // Bob (a member) can read the group too.
    let (status, _b) = json_request(
        &srv.app,
        "GET",
        &format!("/v1/groups/{gid}"),
        Some(&bob),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // Carol (not a member) → 404.
    let (status, _b) = json_request(
        &srv.app,
        "GET",
        &format!("/v1/groups/{gid}"),
        Some(&carol),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn member_without_active_challenge_is_inactive() {
    let srv = test_server(true);
    let (alice, _aid) = auth_account(&srv.app, "sub-alice").await;
    let (bob, _bob_id) = auth_account(&srv.app, "sub-bob").await;

    let (gid, code) = create_group(&srv.app, &alice, "Crew", "Alice").await;
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/groups/join",
        Some(&bob),
        json!({ "invite_code": code, "display_name": "Bob" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // Bob never synced a challenge → inactive, with NO day fields.
    let (status, body) = json_request(
        &srv.app,
        "GET",
        &format!("/v1/groups/{gid}"),
        Some(&alice),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let bob_dto = body["members"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["display_name"] == json!("Bob"))
        .expect("bob dto");
    assert_eq!(bob_dto["is_active"], json!(false));
    assert!(
        bob_dto.get("day_index").is_none(),
        "inactive member exposes no day fields"
    );
    assert!(bob_dto.get("tasks").is_none());
    assert_eq!(bob_dto["display_name"], json!("Bob"));
}

#[tokio::test]
async fn nudge_delivered_once_then_seen_and_rate_limited() {
    let srv = test_server(true);
    let (alice, _aid) = auth_account(&srv.app, "sub-alice").await;
    let (bob, _bob_id) = auth_account(&srv.app, "sub-bob").await;

    let (gid, code) = create_group(&srv.app, &alice, "Crew", "AliceDisplay").await;
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/groups/join",
        Some(&bob),
        json!({ "invite_code": code, "display_name": "Bob" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // Alice reads the group to learn Bob's opaque per-group handle (the only
    // member id on the wire — the global account id is never exposed).
    let (_s, body) = json_request(
        &srv.app,
        "GET",
        &format!("/v1/groups/{gid}"),
        Some(&alice),
        Value::Null,
    )
    .await;
    let bob_handle = body["members"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["display_name"] == json!("Bob"))
        .and_then(|m| m["member_handle"].as_str())
        .expect("bob's handle")
        .to_owned();
    let alice_handle = body["members"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["is_self"] == json!(true))
        .and_then(|m| m["member_handle"].as_str())
        .expect("alice's handle")
        .to_owned();

    // Nudging your OWN handle → 400 (you can't nudge yourself).
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        &format!("/v1/groups/{gid}/nudge"),
        Some(&alice),
        json!({ "to_member_handle": alice_handle }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "self-nudge is rejected");

    // An unknown handle → 404 (reveals nothing).
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        &format!("/v1/groups/{gid}/nudge"),
        Some(&alice),
        json!({ "to_member_handle": "deadbeefdeadbeefdeadbeefdeadbeef" }),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "unknown handle is 404");

    // Alice nudges Bob by his handle.
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        &format!("/v1/groups/{gid}/nudge"),
        Some(&alice),
        json!({ "to_member_handle": bob_handle }),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT, "nudge should be created");

    // Immediately nudging again → 429 (rate limited per from/to/group).
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        &format!("/v1/groups/{gid}/nudge"),
        Some(&alice),
        json!({ "to_member_handle": bob_handle }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::TOO_MANY_REQUESTS,
        "a rapid re-nudge is throttled"
    );

    // Bob receives it once: only Alice's display name + the group name, no content.
    let (status, body) = json_request(&srv.app, "GET", "/v1/nudges", Some(&bob), Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    let nudges = body["nudges"].as_array().expect("nudges");
    assert_eq!(nudges.len(), 1);
    assert_eq!(nudges[0]["from_display_name"], json!("AliceDisplay"));
    assert_eq!(nudges[0]["group_name"], json!("Crew"));
    let mut nkeys: Vec<&str> = nudges[0]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    nkeys.sort();
    assert_eq!(
        nkeys,
        vec!["from_display_name", "group_name"],
        "nudge carries no content"
    );

    // Delivered once: a second poll is empty (they were marked seen).
    let (status, body) = json_request(&srv.app, "GET", "/v1/nudges", Some(&bob), Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body["nudges"].as_array().unwrap().len(),
        0,
        "nudges deliver once"
    );
}

#[tokio::test]
async fn last_member_leave_deletes_the_group() {
    let srv = test_server(true);
    let (alice, _aid) = auth_account(&srv.app, "sub-alice").await;
    let (bob, _bid) = auth_account(&srv.app, "sub-bob").await;

    let (gid, code) = create_group(&srv.app, &alice, "Crew", "Alice").await;
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/groups/join",
        Some(&bob),
        json!({ "invite_code": code, "display_name": "Bob" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // Alice leaves: two members → one, the group survives.
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        &format!("/v1/groups/{gid}/leave"),
        Some(&alice),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let group_rows: i64 = {
        let conn = srv.state.db.lock().unwrap();
        conn.query_row("SELECT COUNT(*) FROM groups WHERE id = ?1", [&gid], |r| {
            r.get(0)
        })
        .unwrap()
    };
    assert_eq!(group_rows, 1, "group survives while Bob remains");

    // Bob leaves: last member out → the group is deleted.
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        &format!("/v1/groups/{gid}/leave"),
        Some(&bob),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let conn = srv.state.db.lock().unwrap();
    let group_rows: i64 = conn
        .query_row("SELECT COUNT(*) FROM groups WHERE id = ?1", [&gid], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(group_rows, 0, "last-member leave deletes the group");
    let membership_rows: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM membership WHERE group_id = ?1",
            [&gid],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(membership_rows, 0);
}

/// A synced complete day (13 backfilled + a full live day 14) derives all task
/// booleans true with the right day index and run.
#[tokio::test]
async fn synced_complete_day_derives_all_tasks_true() {
    let now = at("2026-07-04", 22, 0);
    let srv = test_server_with_clock(true, now.epoch_secs);
    let (alice, _alice_id) = auth_account(&srv.app, "sub-alice").await;
    let (gid, _code) = create_group(&srv.app, &alice, "Crew", "Alice").await;

    let a = new_client();
    a.store
        .create_challenge(challenge_cfg("2026-06-21", at("2026-07-04", 9, 0)))
        .expect("create");
    a.store
        .set_extra_enabled(JOB_EXTRA_ID.into(), true, at("2026-07-04", 9, 1))
        .expect("enable extra");
    // Days 1..=13 fully complete via backfill.
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
            reading: true,
            diet: true,
            no_junk: true,
            photo: true,
            extra_ids: vec![],
        })
        .collect();
    a.store
        .backfill_days(days, at("2026-07-04", 9, 5))
        .expect("backfill");
    // A full live day 14 (incl. the job extra).
    log_mixed_day(&a.store);
    sync(&srv.app, &alice, &a.store).await;

    let (status, body) = json_request(
        &srv.app,
        "GET",
        &format!("/v1/groups/{gid}"),
        Some(&alice),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let dto = body["members"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["is_self"] == json!(true))
        .expect("alice dto");
    assert_eq!(dto["day_index"], json!(14));
    assert_eq!(
        dto["current_run"],
        json!(14),
        "13 backfilled + full live day 14"
    );
    for t in [
        "water",
        "outdoor_workout",
        "second_workout",
        "reading",
        "diet",
        "no_junk",
        "photo",
    ] {
        assert_eq!(
            dto["tasks"][t],
            json!(true),
            "task {t} true on a complete day"
        );
    }
    assert_eq!(dto["weekly_extra_done"], json!(true));
}

/// Regression: DELETE /v1/account for the CREATOR of a group that still has
/// other members must succeed (it used to 500 on the `created_by_account`
/// foreign key and leave the account half-deleted). The group survives, its
/// creator is reassigned to a remaining member, and the whole delete is atomic.
#[tokio::test]
async fn delete_account_succeeds_for_group_creator() {
    let srv = test_server(true);
    let (alice, _aid) = auth_account(&srv.app, "sub-alice").await;
    let (bob, _bid) = auth_account(&srv.app, "sub-bob").await;

    // Alice creates the group (so groups.created_by_account = Alice); Bob joins.
    let (gid, code) = create_group(&srv.app, &alice, "Crew", "Alice").await;
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/groups/join",
        Some(&bob),
        json!({ "invite_code": code, "display_name": "Bob" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // The creator deletes her account while Bob remains -> the group must
    // survive and the delete must not fail on the dangling creator FK.
    let (status, _b) =
        json_request(&srv.app, "DELETE", "/v1/account", Some(&alice), Value::Null).await;
    assert_eq!(
        status,
        StatusCode::NO_CONTENT,
        "creator delete with remaining members must succeed"
    );

    {
        let conn = srv.state.db.lock().unwrap();
        // Fully deleted, not stripped-but-surviving.
        let alice_rows: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM account WHERE apple_sub = 'sub-alice'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(alice_rows, 0, "the creator's account is fully deleted");
        // The surviving group's creator was reassigned to a LIVE member.
        let created_by: i64 = conn
            .query_row(
                "SELECT created_by_account FROM groups WHERE id = ?1",
                [&gid],
                |r| r.get(0),
            )
            .unwrap();
        let account_exists: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM account WHERE id = ?1",
                [created_by],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            account_exists, 1,
            "created_by_account must reference a live account (no dangling FK)"
        );
    }

    // Bob still sees the group he remains in.
    let (status, body) = json_request(
        &srv.app,
        "GET",
        &format!("/v1/groups/{gid}"),
        Some(&bob),
        Value::Null,
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "surviving group still readable: {body}"
    );
    assert_eq!(
        body["members"].as_array().unwrap().len(),
        1,
        "only Bob remains"
    );

    // Sole-creator case: Bob (now alone) deletes -> the group is removed too and
    // the delete still succeeds.
    let (status, _b) =
        json_request(&srv.app, "DELETE", "/v1/account", Some(&bob), Value::Null).await;
    assert_eq!(
        status,
        StatusCode::NO_CONTENT,
        "sole-member creator delete succeeds"
    );
    let conn = srv.state.db.lock().unwrap();
    let group_rows: i64 = conn
        .query_row("SELECT COUNT(*) FROM groups WHERE id = ?1", [&gid], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(group_rows, 0, "last member's delete removes the group");
}

/// Regression: a malformed challenge config (e.g. an unparseable start_date)
/// must be REJECTED on sync ingest with a 400, mirroring event validation —
/// otherwise it is stored verbatim and later faults the group projection.
#[tokio::test]
async fn sync_rejects_malformed_challenge_config() {
    let srv = test_server(true);
    let (token, _aid) = auth_account(&srv.app, "sub-badcfg").await;

    let c = new_client();
    c.store
        .create_challenge(challenge_cfg("2026-06-21", at("2026-07-04", 9, 0)))
        .expect("create");
    let mut config: Value =
        serde_json::from_str(&c.store.export_config_state().expect("cfg")).expect("cfg json");
    config["challenge"]["challenge"]["start_date"] = json!("NOT-A-REAL-DATE");

    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/sync",
        Some(&token),
        json!({ "device_id": "dev-1", "last_server_seq": 0, "events": [], "config": config }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "a malformed challenge config must be rejected on ingest"
    );
}

/// Regression: even if a bad challenge config is somehow already stored for ONE
/// member (bypassing ingest validation), GET /v1/groups/:id must not 500 for
/// the whole group — that member degrades to inactive and everyone else stays
/// visible.
#[tokio::test]
async fn one_members_bad_config_does_not_fault_the_group() {
    let now = at("2026-07-04", 22, 0);
    let srv = test_server_with_clock(true, now.epoch_secs);
    let (alice, _aid) = auth_account(&srv.app, "sub-alice").await;
    let (bob, bob_id) = auth_account(&srv.app, "sub-bob").await;

    let (gid, code) = create_group(&srv.app, &alice, "Crew", "Alice").await;
    let (status, _b) = json_request(
        &srv.app,
        "POST",
        "/v1/groups/join",
        Some(&bob),
        json!({ "invite_code": code, "display_name": "Bob" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let a = new_client();
    a.store
        .create_challenge(challenge_cfg("2026-06-21", at("2026-07-04", 9, 0)))
        .expect("a create");
    log_mixed_day(&a.store);
    sync(&srv.app, &alice, &a.store).await;

    let b = new_client();
    b.store
        .create_challenge(challenge_cfg("2026-06-21", at("2026-07-04", 9, 0)))
        .expect("b create");
    b.store
        .log_water(500, at("2026-07-04", 8, 0), None)
        .expect("b water");
    sync(&srv.app, &bob, &b.store).await;

    // Corrupt Bob's STORED challenge config directly (bypassing ingest
    // validation, mirroring anything a prior build could have persisted).
    {
        let conn = srv.state.db.lock().unwrap();
        let payload: String = conn
            .query_row(
                &format!(
                    "SELECT payload FROM config_slot WHERE account_id = {bob_id} AND slot = 'challenge'"
                ),
                [],
                |r| r.get(0),
            )
            .unwrap();
        let mut v: Value = serde_json::from_str(&payload).unwrap();
        v["challenge"]["start_date"] = json!("NOT-A-REAL-DATE");
        conn.execute(
            &format!(
                "UPDATE config_slot SET payload = ?1 WHERE account_id = {bob_id} AND slot = 'challenge'"
            ),
            [v.to_string()],
        )
        .unwrap();
    }

    let (status, body) = json_request(
        &srv.app,
        "GET",
        &format!("/v1/groups/{gid}"),
        Some(&alice),
        Value::Null,
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "one member's bad config must not fault the whole group: {body}"
    );
    let members = body["members"].as_array().unwrap();
    assert_eq!(members.len(), 2);
    let bob_dto = members
        .iter()
        .find(|m| m["display_name"] == json!("Bob"))
        .expect("bob dto");
    assert_eq!(
        bob_dto["is_active"],
        json!(false),
        "the bad-config member degrades to inactive"
    );
    assert!(
        bob_dto.get("day_index").is_none(),
        "a degraded member exposes no day fields"
    );
    let alice_dto = members
        .iter()
        .find(|m| m["is_self"] == json!(true))
        .expect("alice dto");
    assert_eq!(
        alice_dto["is_active"],
        json!(true),
        "the honest member is unaffected"
    );
}

/// Privacy regression: the same person co-present in two groups must carry a
/// DIFFERENT opaque handle in each (so they can't be correlated), and the
/// global account id must never appear on the group wire.
#[tokio::test]
async fn member_handle_differs_across_groups_and_hides_account_id() {
    let now = at("2026-07-04", 22, 0);
    let srv = test_server_with_clock(true, now.epoch_secs);
    let (alice, _aid) = auth_account(&srv.app, "sub-alice").await;
    let (bob, _bid) = auth_account(&srv.app, "sub-bob").await;

    let (g1, c1) = create_group(&srv.app, &alice, "One", "Alice").await;
    let (g2, c2) = create_group(&srv.app, &alice, "Two", "Alice").await;
    for (code, name) in [(&c1, "BobOne"), (&c2, "BobTwo")] {
        let (status, _b) = json_request(
            &srv.app,
            "POST",
            "/v1/groups/join",
            Some(&bob),
            json!({ "invite_code": code, "display_name": name }),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }

    fn bob_handle(body: &Value) -> String {
        body["members"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| {
                m["display_name"]
                    .as_str()
                    .is_some_and(|n| n.starts_with("Bob"))
            })
            .and_then(|m| m["member_handle"].as_str())
            .expect("bob's handle")
            .to_owned()
    }

    let (_s, b1) = json_request(
        &srv.app,
        "GET",
        &format!("/v1/groups/{g1}"),
        Some(&alice),
        Value::Null,
    )
    .await;
    let (_s, b2) = json_request(
        &srv.app,
        "GET",
        &format!("/v1/groups/{g2}"),
        Some(&alice),
        Value::Null,
    )
    .await;

    assert_ne!(
        bob_handle(&b1),
        bob_handle(&b2),
        "the same user must NOT share a handle across groups (correlation defeat)"
    );
    assert!(
        !b1.to_string().contains("account_id") && !b2.to_string().contains("account_id"),
        "the global account id must never appear on the group wire"
    );
}
