//! `POST /v1/sync` — push + pull in one round-trip (docs/PHASE2.md "Server").
//!
//! Push: dedup by uuid, assign a per-account monotone `server_seq`, ack.
//! Pull: events after the client's `last_server_seq` from ANY other device.
//! Config: per-slot last-writer-wins merge, plus the one-active-challenge
//! rule (first synced active challenge wins; a different incoming active
//! challenge is stored archived + sync_conflict and the response says so).

use axum::extract::State;
use axum::{Extension, Json};
use drome_core::sync::{lww_wins, validate_challenge_slot, validate_wire_event};
use drome_core::{
    events, ConfigBlock, ConfigChallengeSlot, ConfigExtrasSlot, ConfigPresetsSlot, WireEvent,
};
use rusqlite::{params, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};

use crate::auth::Account;
use crate::error::ApiError;
use crate::AppState;

const MAX_WIRE_ID_LEN: usize = 64;

/// Cap on events returned per pull. A heavy first sign-in (or a post-reset
/// re-pull) could otherwise ship an account's ENTIRE history in one response,
/// which the client applies in a single core transaction on the main actor —
/// an unbounded batch janks the UI. The client re-triggers a round-trip while
/// `more` is set, draining the backlog across round-trips (mirroring push).
const PULL_LIMIT: i64 = 500;

#[derive(Debug, Deserialize)]
pub struct SyncRequest {
    /// The pushing device's stable id (event provenance + pull self-echo
    /// suppression).
    pub device_id: String,
    #[serde(default)]
    pub last_server_seq: i64,
    #[serde(default)]
    pub events: Vec<WireEvent>,
    /// The client's config block (challenge settings, presets, extras). JSON
    /// object; absent slots are `null`.
    #[serde(default)]
    pub config: ConfigBlock,
}

#[derive(Debug, Serialize)]
pub struct SyncResponse {
    /// Uuids the server has (newly stored or already present): the client
    /// advances its push watermark past these.
    pub acked_uuids: Vec<String>,
    /// Events with `server_seq > last_server_seq` from other devices.
    pub events: Vec<WireEvent>,
    /// The client's new pull cursor (never less than what it sent).
    pub new_last_server_seq: i64,
    /// True when the pull was capped at `PULL_LIMIT` and events remain past
    /// `new_last_server_seq`; the client re-syncs to drain them.
    pub more: bool,
    /// The account's canonical config after the LWW merge (the active
    /// challenge's slots).
    pub config: ConfigBlock,
    /// Set when this device's active challenge lost the one-active-challenge
    /// race — its challenge was archived; the winner is in `config`.
    pub active_challenge_conflict: Option<ActiveChallengeConflict>,
}

#[derive(Debug, Serialize)]
pub struct ActiveChallengeConflict {
    pub archived_challenge_id: String,
    pub winner_challenge_id: String,
}

pub async fn sync_handler(
    State(state): State<AppState>,
    Extension(account): Extension<Account>,
    Json(req): Json<SyncRequest>,
) -> Result<Json<SyncResponse>, ApiError> {
    if req.device_id.trim().is_empty() || req.device_id.len() > MAX_WIRE_ID_LEN {
        return Err(ApiError::bad_request(
            "device_id must be a non-empty identifier",
        ));
    }
    if req.last_server_seq < 0 {
        return Err(ApiError::bad_request("last_server_seq must be >= 0"));
    }

    let mut conn = state.db.lock().map_err(|_| ApiError::internal("db lock"))?;
    let tx = conn.transaction().map_err(ApiError::internal)?;

    // --- 1. Push: dedup by uuid, assign server_seq -------------------------
    let mut acked = Vec::with_capacity(req.events.len());
    for e in &req.events {
        validate_wire_event(e)?; // shared core validation (400 on malformed)
        let exists: bool = tx
            .query_row(
                "SELECT COUNT(*) > 0 FROM event WHERE account_id = ?1 AND uuid = ?2",
                params![account.id, e.uuid],
                |r| r.get(0),
            )
            .map_err(ApiError::internal)?;
        if !exists {
            let seq = next_server_seq(&tx, account.id)?;
            // Defense in depth: the client strips photo refs before push, but
            // the server strips again so a non-compliant client can never
            // land a ref (docs/PHASE2.md: photos never sync in Phase 2).
            let payload = wire_payload(&e.kind, &e.payload_json);
            tx.execute(
                "INSERT INTO event (account_id, uuid, server_seq, device_id, challenge_id,
                                    logged_at_epoch, tz_offset_secs, effective_date, kind,
                                    payload, schema_version)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![
                    account.id,
                    e.uuid,
                    seq,
                    req.device_id,
                    e.challenge_id,
                    e.logged_at_epoch,
                    e.tz_offset_secs,
                    e.effective_date,
                    e.kind,
                    payload,
                    e.schema_version,
                ],
            )
            .map_err(ApiError::internal)?;
        }
        acked.push(e.uuid.clone());
    }

    // --- 2. Config LWW merge + one-active-challenge rule -------------------
    let mut active_id = account.active_challenge_id.clone();
    let conflict = merge_config(&tx, account.id, &mut active_id, &req.config, &req.device_id)?;
    if active_id != account.active_challenge_id {
        tx.execute(
            "UPDATE account SET active_challenge_id = ?1 WHERE id = ?2",
            params![active_id, account.id],
        )
        .map_err(ApiError::internal)?;
    }

    // --- 3. Pull: newer events from OTHER devices -------------------------
    // Scoped to the account's ACTIVE challenge: a loser challenge's events are
    // stored (they got server_seqs on push) but must never propagate, or every
    // device would receive orphan rows referencing an archived challenge whose
    // config is not pullable (docs/PHASE2.md: only the winner's config is
    // canonical). Filtering pull by the active challenge id keeps the shared
    // history to exactly the one active challenge.
    let pulled = pull_events(
        &tx,
        account.id,
        req.last_server_seq,
        &req.device_id,
        active_id.as_deref(),
        PULL_LIMIT,
    )?;
    let max_seq: i64 = tx
        .query_row(
            "SELECT COALESCE(MAX(server_seq), 0) FROM event WHERE account_id = ?1",
            params![account.id],
            |r| r.get(0),
        )
        .map_err(ApiError::internal)?;
    // When the pull filled the cap, more events may remain: advance the cursor
    // ONLY to the last event actually returned (never to `max_seq`, which would
    // silently skip the un-returned tail) and tell the client to drain the rest
    // in another round-trip. Otherwise the client has caught up, so the cursor
    // jumps past its own just-pushed events (excluded above, already local) to
    // the account's max seq.
    let capped = pulled.len() as i64 >= PULL_LIMIT;
    let last_pulled_seq = pulled.last().map(|(seq, _)| *seq);
    let events: Vec<WireEvent> = pulled.into_iter().map(|(_, e)| e).collect();
    let (new_last_server_seq, more) = match last_pulled_seq {
        Some(last) if capped && last < max_seq => (last, true),
        _ => (req.last_server_seq.max(max_seq), false),
    };

    // --- 4. Return the merged winning config ------------------------------
    let config = load_config_block(&tx, account.id, active_id.as_deref())?;

    tx.commit().map_err(ApiError::internal)?;

    Ok(Json(SyncResponse {
        acked_uuids: acked,
        events,
        new_last_server_seq,
        more,
        config,
        active_challenge_conflict: conflict,
    }))
}

fn next_server_seq(tx: &Transaction, account_id: i64) -> Result<i64, ApiError> {
    let seq: i64 = tx
        .query_row(
            "SELECT next_server_seq FROM account WHERE id = ?1",
            params![account_id],
            |r| r.get(0),
        )
        .map_err(ApiError::internal)?;
    tx.execute(
        "UPDATE account SET next_server_seq = ?1 WHERE id = ?2",
        params![seq + 1, account_id],
    )
    .map_err(ApiError::internal)?;
    Ok(seq)
}

fn wire_payload(kind: &str, payload_json: &str) -> String {
    if kind == events::KIND_PHOTO_DONE {
        r#"{"photo_ref":null}"#.to_owned()
    } else {
        payload_json.to_owned()
    }
}

/// Returns up to `limit` newer events from OTHER devices under the active
/// challenge, each paired with its `server_seq` (so the caller can advance the
/// cursor exactly to the last event returned when the batch is capped).
fn pull_events(
    tx: &Transaction,
    account_id: i64,
    after_seq: i64,
    exclude_device: &str,
    active_id: Option<&str>,
    limit: i64,
) -> Result<Vec<(i64, WireEvent)>, ApiError> {
    // No active challenge => nothing canonical to hand out. (Events only exist
    // once a challenge has been synced, and any event not under the active
    // challenge belongs to an archived loser and must not propagate.)
    let Some(active) = active_id else {
        return Ok(Vec::new());
    };
    let mut stmt = tx
        .prepare(
            "SELECT server_seq, uuid, challenge_id, logged_at_epoch, tz_offset_secs,
                    effective_date, kind, payload, schema_version
             FROM event
             WHERE account_id = ?1 AND server_seq > ?2 AND device_id != ?3
               AND challenge_id = ?4
             ORDER BY server_seq
             LIMIT ?5",
        )
        .map_err(ApiError::internal)?;
    let rows = stmt
        .query_map(
            params![account_id, after_seq, exclude_device, active, limit],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    WireEvent {
                        uuid: row.get(1)?,
                        challenge_id: row.get(2)?,
                        logged_at_epoch: row.get(3)?,
                        tz_offset_secs: row.get(4)?,
                        effective_date: row.get(5)?,
                        kind: row.get(6)?,
                        payload_json: row.get(7)?,
                        schema_version: row.get(8)?,
                    },
                ))
            },
        )
        .map_err(ApiError::internal)?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row.map_err(ApiError::internal)?);
    }
    Ok(out)
}

// --- config merge ----------------------------------------------------------

fn merge_config(
    tx: &Transaction,
    account_id: i64,
    active_id: &mut Option<String>,
    config: &ConfigBlock,
    _device_id: &str,
) -> Result<Option<ActiveChallengeConflict>, ApiError> {
    let mut conflict = None;

    if let Some(cs) = &config.challenge {
        let c = &cs.challenge;
        if c.id.trim().is_empty() || c.id.len() > MAX_WIRE_ID_LEN {
            return Err(ApiError::bad_request(
                "challenge id must be a non-empty identifier",
            ));
        }
        // Validate the FULL challenge config on ingest (start_date parses,
        // length/cutoff/waking/goal in range), mirroring `validate_wire_event`
        // for events. Without this a member's malformed config is stored
        // verbatim and later faults the group-presence projection, 500-ing the
        // WHOLE group view for everyone (docs/PHASE2.md group privacy). Applies
        // to both the active and the archived-loser branch below. A DromeError
        // maps to 400 via `From<DromeError>` (error.rs).
        validate_challenge_slot(cs)?;
        let stamp = (cs.updated_at_epoch, cs.device_id.as_str());
        if c.active {
            match active_id.as_deref() {
                None => {
                    // First active challenge for the account wins.
                    upsert_slot(
                        tx,
                        account_id,
                        "challenge",
                        &c.id,
                        stamp,
                        &to_json(cs)?,
                        false,
                    )?;
                    *active_id = Some(c.id.clone());
                }
                Some(winner) if winner == c.id => {
                    upsert_slot(
                        tx,
                        account_id,
                        "challenge",
                        &c.id,
                        stamp,
                        &to_json(cs)?,
                        false,
                    )?;
                }
                Some(winner) => {
                    // A different active challenge: store it archived + labeled.
                    let mut loser = cs.clone();
                    loser.challenge.active = false;
                    upsert_slot(
                        tx,
                        account_id,
                        "challenge",
                        &c.id,
                        stamp,
                        &to_json(&loser)?,
                        true,
                    )?;
                    conflict = Some(ActiveChallengeConflict {
                        archived_challenge_id: c.id.clone(),
                        winner_challenge_id: winner.to_string(),
                    });
                }
            }
        } else {
            upsert_slot(
                tx,
                account_id,
                "challenge",
                &c.id,
                stamp,
                &to_json(cs)?,
                false,
            )?;
        }
    }

    if let Some(ps) = &config.presets {
        let stamp = (ps.updated_at_epoch, ps.device_id.as_str());
        upsert_slot(
            tx,
            account_id,
            "presets",
            &ps.challenge_id,
            stamp,
            &to_json(ps)?,
            false,
        )?;
    }
    if let Some(xs) = &config.extras {
        let stamp = (xs.updated_at_epoch, xs.device_id.as_str());
        upsert_slot(
            tx,
            account_id,
            "extras",
            &xs.challenge_id,
            stamp,
            &to_json(xs)?,
            false,
        )?;
    }

    Ok(conflict)
}

/// Stores `payload` for a config slot only when its `(updated_at, device_id)`
/// stamp strictly beats the stored one (last-writer-wins). `sync_conflict`
/// marks a challenge that lost the one-active-challenge race.
fn upsert_slot(
    tx: &Transaction,
    account_id: i64,
    slot: &str,
    challenge_id: &str,
    stamp: (i64, &str),
    payload: &str,
    sync_conflict: bool,
) -> Result<(), ApiError> {
    let existing: Option<(i64, String)> = tx
        .query_row(
            "SELECT updated_at_epoch, device_id FROM config_slot
             WHERE account_id = ?1 AND slot = ?2 AND challenge_id = ?3",
            params![account_id, slot, challenge_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(ApiError::internal)?;
    let wins = lww_wins(stamp, existing.as_ref().map(|(t, d)| (*t, d.as_str())));
    if !wins {
        return Ok(());
    }
    tx.execute(
        "INSERT INTO config_slot (account_id, slot, challenge_id, updated_at_epoch, device_id,
                                  payload, sync_conflict)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(account_id, slot, challenge_id) DO UPDATE SET
             updated_at_epoch = excluded.updated_at_epoch,
             device_id = excluded.device_id,
             payload = excluded.payload,
             sync_conflict = excluded.sync_conflict",
        params![
            account_id,
            slot,
            challenge_id,
            stamp.0,
            stamp.1,
            payload,
            sync_conflict as i64
        ],
    )
    .map_err(ApiError::internal)?;
    Ok(())
}

/// Builds the account's canonical config block from the active challenge's
/// stored slots (the winner of any conflict).
fn load_config_block(
    tx: &Transaction,
    account_id: i64,
    active_id: Option<&str>,
) -> Result<ConfigBlock, ApiError> {
    let Some(active) = active_id else {
        return Ok(ConfigBlock::default());
    };
    Ok(ConfigBlock {
        challenge: load_slot::<ConfigChallengeSlot>(tx, account_id, "challenge", active)?,
        presets: load_slot::<ConfigPresetsSlot>(tx, account_id, "presets", active)?,
        extras: load_slot::<ConfigExtrasSlot>(tx, account_id, "extras", active)?,
    })
}

fn load_slot<T: serde::de::DeserializeOwned>(
    tx: &Transaction,
    account_id: i64,
    slot: &str,
    challenge_id: &str,
) -> Result<Option<T>, ApiError> {
    let payload: Option<String> = tx
        .query_row(
            "SELECT payload FROM config_slot
             WHERE account_id = ?1 AND slot = ?2 AND challenge_id = ?3",
            params![account_id, slot, challenge_id],
            |r| r.get(0),
        )
        .optional()
        .map_err(ApiError::internal)?;
    match payload {
        Some(p) => Ok(Some(serde_json::from_str(&p).map_err(ApiError::internal)?)),
        None => Ok(None),
    }
}

fn to_json<T: Serialize>(value: &T) -> Result<String, ApiError> {
    serde_json::to_string(value).map_err(ApiError::internal)
}
