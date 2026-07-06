//! Friend groups (docs/PHASE2.md "Groups"). All routes here are behind the
//! auth + entitlement middleware (see `build_router`), so every handler has an
//! authenticated `Account` and an entitled caller.
//!
//! PRIVACY IS THE HARD CONSTRAINT. The group surface exposes ONLY each
//! member's chosen display name, day index, current run, today's per-task
//! done/not-done booleans, and a single done/not for this week's extra. It
//! NEVER exposes progress photos or refs, workout/reading notes, the diet
//! description, water amounts, event details, anything about resets/archived
//! challenges, or the weekly extra's name/id. Every response below is a
//! hand-built minimal DTO — never a passthrough of an internal row — and the
//! per-member day-state is derived through the shared core projection
//! (`drome_core::project_group_presence`), which returns only safe primitives.
//!
//! A caller who is not a member of a group gets a 404 for it (same as a group
//! that does not exist), so group membership is never probeable.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::{Extension, Json};
use drome_core::{
    project_group_presence, Challenge, ConfigChallengeSlot, ConfigExtrasSlot, EventRow, ExtraDef,
    LocalInstant,
};
use rand::RngCore;
use rusqlite::{params, Connection, OptionalExtension};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::auth::Account;
use crate::error::ApiError;
use crate::AppState;

const MAX_NAME_LEN: usize = 60;
const MAX_DISPLAY_NAME_LEN: usize = 40;
const INVITE_CODE_LEN: usize = 8;
/// Unambiguous invite-code alphabet: no 0/O or 1/I. 32 symbols divides 256
/// evenly, so `byte % 32` draws each symbol without modulo bias.
const INVITE_ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
/// A member can nudge the same peer in the same group at most once per this
/// window, so a nudge can't be spammed.
const NUDGE_COOLDOWN_SECS: i64 = 300;

// ---------------------------------------------------------------------------
// POST /v1/groups  — create a group, creator auto-joins
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct CreateGroupRequest {
    pub name: String,
    pub display_name: String,
}

pub async fn create_group(
    State(state): State<AppState>,
    Extension(account): Extension<Account>,
    Json(req): Json<CreateGroupRequest>,
) -> Result<Json<Value>, ApiError> {
    let name = validate_field(&req.name, MAX_NAME_LEN, "name")?;
    let display_name = validate_field(&req.display_name, MAX_DISPLAY_NAME_LEN, "display_name")?;
    let now = state.now_epoch();

    let mut conn = state.db.lock().map_err(|_| ApiError::internal("db lock"))?;
    let tx = conn.transaction().map_err(ApiError::internal)?;
    let id = new_group_id();
    let invite_code = unique_invite_code(&tx)?;
    tx.execute(
        "INSERT INTO groups (id, name, invite_code, created_by_account, created_at_epoch)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![id, name, invite_code, account.id, now],
    )
    .map_err(ApiError::internal)?;
    tx.execute(
        "INSERT INTO membership (account_id, group_id, joined_at_epoch, display_name, member_handle)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            account.id,
            id,
            now,
            display_name,
            crate::db::random_member_handle()
        ],
    )
    .map_err(ApiError::internal)?;
    tx.commit().map_err(ApiError::internal)?;

    Ok(Json(json!({
        "id": id,
        "name": name,
        "invite_code": invite_code,
    })))
}

// ---------------------------------------------------------------------------
// POST /v1/groups/join  — join by invite code (idempotent)
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct JoinGroupRequest {
    pub invite_code: String,
    pub display_name: String,
}

pub async fn join_group(
    State(state): State<AppState>,
    Extension(account): Extension<Account>,
    Json(req): Json<JoinGroupRequest>,
) -> Result<Json<Value>, ApiError> {
    let display_name = validate_field(&req.display_name, MAX_DISPLAY_NAME_LEN, "display_name")?;
    let code = normalize_code(&req.invite_code);
    let now = state.now_epoch();

    let conn = state.db.lock().map_err(|_| ApiError::internal("db lock"))?;
    let group: Option<(String, String)> = conn
        .query_row(
            "SELECT id, name FROM groups WHERE invite_code = ?1",
            params![code],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(ApiError::internal)?;
    // An invalid code is a plain 404 — no "code exists but ..." signal.
    let Some((id, name)) = group else {
        return Err(ApiError::not_found("no group with that invite code"));
    };

    // Idempotent: re-joining updates the caller's display name in this group.
    // A fresh member_handle is minted on first join; ON CONFLICT keeps the
    // existing handle (it must stay stable for this membership) and only the
    // display name changes.
    conn.execute(
        "INSERT INTO membership (account_id, group_id, joined_at_epoch, display_name, member_handle)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(account_id, group_id) DO UPDATE SET display_name = excluded.display_name",
        params![
            account.id,
            id,
            now,
            display_name,
            crate::db::random_member_handle()
        ],
    )
    .map_err(ApiError::internal)?;

    Ok(Json(json!({
        "id": id,
        "name": name,
        "invite_code": code,
    })))
}

// ---------------------------------------------------------------------------
// GET /v1/groups  — my groups
// ---------------------------------------------------------------------------

pub async fn list_groups(
    State(state): State<AppState>,
    Extension(account): Extension<Account>,
) -> Result<Json<Value>, ApiError> {
    let conn = state.db.lock().map_err(|_| ApiError::internal("db lock"))?;
    let mut stmt = conn
        .prepare(
            "SELECT g.id, g.name, g.invite_code, m.display_name,
                    (SELECT COUNT(*) FROM membership m2 WHERE m2.group_id = g.id)
             FROM membership m
             JOIN groups g ON g.id = m.group_id
             WHERE m.account_id = ?1
             ORDER BY m.joined_at_epoch, g.id",
        )
        .map_err(ApiError::internal)?;
    let rows = stmt
        .query_map(params![account.id], |r| {
            Ok(json!({
                "id": r.get::<_, String>(0)?,
                "name": r.get::<_, String>(1)?,
                "invite_code": r.get::<_, String>(2)?,
                "my_display_name": r.get::<_, Option<String>>(3)?,
                "member_count": r.get::<_, i64>(4)?,
            }))
        })
        .map_err(ApiError::internal)?;
    let mut groups = Vec::new();
    for row in rows {
        groups.push(row.map_err(ApiError::internal)?);
    }
    Ok(Json(json!({ "groups": groups })))
}

// ---------------------------------------------------------------------------
// GET /v1/groups/:id  — members' minimal day-state DTOs
// ---------------------------------------------------------------------------

pub async fn get_group(
    State(state): State<AppState>,
    Extension(account): Extension<Account>,
    Path(group_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let now_epoch = state.now_epoch();
    let conn = state.db.lock().map_err(|_| ApiError::internal("db lock"))?;
    // Non-member (or nonexistent group) -> 404, no existence leak.
    require_membership(&conn, account.id, &group_id)?;

    let (name, invite_code): (String, String) = conn
        .query_row(
            "SELECT name, invite_code FROM groups WHERE id = ?1",
            params![group_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map_err(ApiError::internal)?;

    let mut stmt = conn
        .prepare(
            "SELECT account_id, member_handle, display_name FROM membership
             WHERE group_id = ?1 ORDER BY joined_at_epoch, account_id",
        )
        .map_err(ApiError::internal)?;
    let member_rows = stmt
        .query_map(params![group_id], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Option<String>>(2)?,
            ))
        })
        .map_err(ApiError::internal)?;
    let members: Vec<(i64, String, Option<String>)> = member_rows
        .collect::<rusqlite::Result<_>>()
        .map_err(ApiError::internal)?;
    drop(stmt);

    let mut dtos = Vec::with_capacity(members.len());
    for (member_id, member_handle, display_name) in members {
        // `is_self` lets the client mark "you" WITHOUT ever seeing the global
        // account id — the id is never on the wire.
        let is_self = member_id == account.id;
        dtos.push(member_presence_dto(
            &conn,
            member_id,
            member_handle,
            display_name.unwrap_or_default(),
            is_self,
            now_epoch,
        )?);
    }

    Ok(Json(json!({
        "id": group_id,
        "name": name,
        "invite_code": invite_code,
        "members": dtos,
    })))
}

/// Builds ONE member's minimal, privacy-safe day-state DTO. Reads only what the
/// projection needs (challenge config, that challenge's events, its extra defs,
/// and the member's last-known tz), runs the shared core projection, and emits
/// exactly `{ member_handle, display_name, is_self, is_active, [day_index,
/// current_run, tasks{7 bools}, weekly_extra_done] }`. The identifier is the
/// opaque per-group `member_handle` — NEVER the global account id, which would
/// let a co-present observer correlate the same person across groups. The
/// `Challenge` it loads carries the diet description and book title; NEITHER is
/// ever placed in the DTO.
fn member_presence_dto(
    conn: &Connection,
    member_id: i64,
    member_handle: String,
    display_name: String,
    is_self: bool,
    now_epoch: i64,
) -> Result<Value, ApiError> {
    let inactive = || {
        json!({
            "member_handle": member_handle,
            "display_name": display_name,
            "is_self": is_self,
            "is_active": false,
        })
    };

    // No active challenge synced -> inactive, no day fields.
    let active_id: Option<String> = conn
        .query_row(
            "SELECT active_challenge_id FROM account WHERE id = ?1",
            params![member_id],
            |r| r.get::<_, Option<String>>(0),
        )
        .optional()
        .map_err(ApiError::internal)?
        .flatten();
    let Some(active_id) = active_id else {
        return Ok(inactive());
    };
    let Some(challenge) = load_member_challenge(conn, member_id, &active_id)? else {
        return Ok(inactive());
    };

    let events = load_member_events(conn, member_id, &active_id)?;
    let extras = load_member_extras(conn, member_id, &active_id)?;
    // "Their today" = server-now stamped with the member's last-known tz offset
    // (their most recent synced event under this challenge), attributed through
    // this challenge's cutoff. A member who hasn't synced today is projected at
    // that offset and honestly shows today's tasks not-done. Documented
    // approximation (docs/PHASE2.md group day-state).
    let tz_offset_secs = last_tz_offset(conn, member_id, &active_id)?.unwrap_or(0);
    let now = LocalInstant {
        epoch_secs: now_epoch,
        tz_offset_secs,
    };
    // Isolate a projection failure to THIS member: one member's unprojectable
    // challenge config (e.g. an unparseable start_date already stored) must
    // never fault the whole group view — it degrades to inactive here instead
    // of 500-ing get_group for everyone. Sync ingest now validates config, so
    // this is defense in depth for anything already persisted.
    let Ok(p) = project_group_presence(&challenge, &events, &extras, now) else {
        return Ok(inactive());
    };

    Ok(json!({
        "member_handle": member_handle,
        "display_name": display_name,
        "is_self": is_self,
        "is_active": true,
        "day_index": p.day_index,
        "current_run": p.current_run,
        "tasks": {
            "water": p.water,
            "outdoor_workout": p.outdoor_workout,
            "second_workout": p.second_workout,
            "reading": p.reading,
            "diet": p.diet,
            "no_junk": p.no_junk,
            "photo": p.photo,
        },
        "weekly_extra_done": p.weekly_extra_done,
    }))
}

// ---------------------------------------------------------------------------
// POST /v1/groups/:id/leave
// ---------------------------------------------------------------------------

pub async fn leave_group(
    State(state): State<AppState>,
    Extension(account): Extension<Account>,
    Path(group_id): Path<String>,
) -> Result<StatusCode, ApiError> {
    let mut conn = state.db.lock().map_err(|_| ApiError::internal("db lock"))?;
    let tx = conn.transaction().map_err(ApiError::internal)?;
    require_membership(&tx, account.id, &group_id)?;

    tx.execute(
        "DELETE FROM membership WHERE account_id = ?1 AND group_id = ?2",
        params![account.id, group_id],
    )
    .map_err(ApiError::internal)?;
    // Drop my nudges in this group (both directions) — I'm no longer here.
    tx.execute(
        "DELETE FROM nudge WHERE group_id = ?1 AND (from_account = ?2 OR to_account = ?2)",
        params![group_id, account.id],
    )
    .map_err(ApiError::internal)?;

    let remaining: i64 = tx
        .query_row(
            "SELECT COUNT(*) FROM membership WHERE group_id = ?1",
            params![group_id],
            |r| r.get(0),
        )
        .map_err(ApiError::internal)?;
    if remaining == 0 {
        // Last member out: the group (and any lingering nudges) is deleted.
        tx.execute("DELETE FROM nudge WHERE group_id = ?1", params![group_id])
            .map_err(ApiError::internal)?;
        tx.execute("DELETE FROM groups WHERE id = ?1", params![group_id])
            .map_err(ApiError::internal)?;
    }
    tx.commit().map_err(ApiError::internal)?;
    Ok(StatusCode::NO_CONTENT)
}

// ---------------------------------------------------------------------------
// POST /v1/groups/:id/nudge  { to_member_handle }
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct NudgeRequest {
    /// The recipient's opaque per-group handle (from the GET /:id member list).
    /// The global account id is never on the wire, so nudges target this handle
    /// and the server resolves it back to an account WITHIN the group.
    pub to_member_handle: String,
}

pub async fn nudge(
    State(state): State<AppState>,
    Extension(account): Extension<Account>,
    Path(group_id): Path<String>,
    Json(req): Json<NudgeRequest>,
) -> Result<StatusCode, ApiError> {
    let now = state.now_epoch();
    let mut conn = state.db.lock().map_err(|_| ApiError::internal("db lock"))?;
    let tx = conn.transaction().map_err(ApiError::internal)?;
    // Sender must be a member -> else 404 (no existence leak). This is checked
    // BEFORE any other validation so a non-member learns nothing about the
    // group, not even that their request was otherwise malformed.
    require_membership(&tx, account.id, &group_id)?;
    // Resolve the opaque handle to an account WITHIN this group. An unknown
    // handle -> 404 (same as a non-member; reveals nothing). This scoping also
    // means a handle only nudges inside the group it belongs to.
    let to_account: Option<i64> = tx
        .query_row(
            "SELECT account_id FROM membership WHERE group_id = ?1 AND member_handle = ?2",
            params![group_id, req.to_member_handle],
            |r| r.get(0),
        )
        .optional()
        .map_err(ApiError::internal)?;
    let Some(to_account) = to_account else {
        return Err(ApiError::not_found("no such group member"));
    };
    if to_account == account.id {
        return Err(ApiError::bad_request("cannot nudge yourself"));
    }

    // Rate limit: one nudge per (from, to, group) per NUDGE_COOLDOWN_SECS.
    let last: Option<i64> = tx
        .query_row(
            "SELECT MAX(created_at_epoch) FROM nudge
             WHERE group_id = ?1 AND from_account = ?2 AND to_account = ?3",
            params![group_id, account.id, to_account],
            |r| r.get(0),
        )
        .map_err(ApiError::internal)?;
    if let Some(t) = last {
        if now - t < NUDGE_COOLDOWN_SECS {
            return Err(ApiError::too_many_requests(
                "you nudged them recently — give it a few minutes",
            ));
        }
    }

    tx.execute(
        "INSERT INTO nudge (group_id, from_account, to_account, created_at_epoch, seen)
         VALUES (?1, ?2, ?3, ?4, 0)",
        params![group_id, account.id, to_account, now],
    )
    .map_err(ApiError::internal)?;
    tx.commit().map_err(ApiError::internal)?;
    Ok(StatusCode::NO_CONTENT)
}

// ---------------------------------------------------------------------------
// GET /v1/nudges  — deliver pending nudges once, then mark them seen
// ---------------------------------------------------------------------------

pub async fn get_nudges(
    State(state): State<AppState>,
    Extension(account): Extension<Account>,
) -> Result<Json<Value>, ApiError> {
    let mut conn = state.db.lock().map_err(|_| ApiError::internal("db lock"))?;
    let tx = conn.transaction().map_err(ApiError::internal)?;

    let mut nudges = Vec::new();
    {
        let mut stmt = tx
            .prepare(
                // The sender's display name is per-group (membership row); the
                // group name comes from the group. Content-free by design.
                "SELECT COALESCE(m.display_name, 'A groupmate'), g.name
                 FROM nudge n
                 JOIN groups g ON g.id = n.group_id
                 LEFT JOIN membership m
                        ON m.group_id = n.group_id AND m.account_id = n.from_account
                 WHERE n.to_account = ?1 AND n.seen = 0
                 ORDER BY n.created_at_epoch, n.id",
            )
            .map_err(ApiError::internal)?;
        let rows = stmt
            .query_map(params![account.id], |r| {
                Ok(json!({
                    "from_display_name": r.get::<_, String>(0)?,
                    "group_name": r.get::<_, String>(1)?,
                }))
            })
            .map_err(ApiError::internal)?;
        for row in rows {
            nudges.push(row.map_err(ApiError::internal)?);
        }
    }

    // Deliver-once: mark exactly the pending set seen (same transaction, so the
    // set can't change between the read and this write).
    tx.execute(
        "UPDATE nudge SET seen = 1 WHERE to_account = ?1 AND seen = 0",
        params![account.id],
    )
    .map_err(ApiError::internal)?;
    tx.commit().map_err(ApiError::internal)?;

    Ok(Json(json!({ "nudges": nudges })))
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

/// 404 unless `account_id` is a member of `group_id`. This is the ONE check
/// that keeps a non-member from learning a group exists (same 404 as a
/// nonexistent group).
fn require_membership(conn: &Connection, account_id: i64, group_id: &str) -> Result<(), ApiError> {
    if is_member(conn, account_id, group_id)? {
        Ok(())
    } else {
        Err(ApiError::not_found("group not found"))
    }
}

fn is_member(conn: &Connection, account_id: i64, group_id: &str) -> Result<bool, ApiError> {
    conn.query_row(
        "SELECT COUNT(*) > 0 FROM membership WHERE account_id = ?1 AND group_id = ?2",
        params![account_id, group_id],
        |r| r.get(0),
    )
    .map_err(ApiError::internal)
}

/// The member's active challenge config (the winner's slot), or None when the
/// slot is absent. Only `challenge` is returned; the caller uses it purely as
/// projection input and never serializes it.
fn load_member_challenge(
    conn: &Connection,
    account_id: i64,
    challenge_id: &str,
) -> Result<Option<Challenge>, ApiError> {
    let payload: Option<String> = conn
        .query_row(
            "SELECT payload FROM config_slot
             WHERE account_id = ?1 AND slot = 'challenge' AND challenge_id = ?2",
            params![account_id, challenge_id],
            |r| r.get(0),
        )
        .optional()
        .map_err(ApiError::internal)?;
    match payload {
        Some(p) => {
            let slot: ConfigChallengeSlot = serde_json::from_str(&p).map_err(ApiError::internal)?;
            Ok(Some(slot.challenge))
        }
        None => Ok(None),
    }
}

/// The member's enabled extra defs for this challenge (empty when the slot is
/// absent). Only used to know whether THIS week's extra is done — never named.
fn load_member_extras(
    conn: &Connection,
    account_id: i64,
    challenge_id: &str,
) -> Result<Vec<ExtraDef>, ApiError> {
    let payload: Option<String> = conn
        .query_row(
            "SELECT payload FROM config_slot
             WHERE account_id = ?1 AND slot = 'extras' AND challenge_id = ?2",
            params![account_id, challenge_id],
            |r| r.get(0),
        )
        .optional()
        .map_err(ApiError::internal)?;
    match payload {
        Some(p) => {
            let slot: ConfigExtrasSlot = serde_json::from_str(&p).map_err(ApiError::internal)?;
            Ok(slot.extras)
        }
        None => Ok(Vec::new()),
    }
}

/// The member's events under `challenge_id`, ordered like the client loads them
/// (`logged_at_epoch, then insertion order`) so the projection is stable.
/// server_seq stands in for the client rowid tiebreak.
fn load_member_events(
    conn: &Connection,
    account_id: i64,
    challenge_id: &str,
) -> Result<Vec<EventRow>, ApiError> {
    let mut stmt = conn
        .prepare(
            "SELECT server_seq, uuid, challenge_id, logged_at_epoch, tz_offset_secs,
                    effective_date, kind, payload, schema_version
             FROM event
             WHERE account_id = ?1 AND challenge_id = ?2
             ORDER BY logged_at_epoch, server_seq",
        )
        .map_err(ApiError::internal)?;
    let rows = stmt
        .query_map(params![account_id, challenge_id], |row| {
            let payload_text: String = row.get(7)?;
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, i32>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, String>(6)?,
                payload_text,
                row.get::<_, i64>(8)?,
            ))
        })
        .map_err(ApiError::internal)?;
    let mut events = Vec::new();
    for row in rows {
        let (seq, uuid, cid, epoch, offset, effective_date, kind, payload_text, version) =
            row.map_err(ApiError::internal)?;
        events.push(EventRow {
            id: seq,
            uuid,
            challenge_id: cid,
            logged_at: LocalInstant {
                epoch_secs: epoch,
                tz_offset_secs: offset,
            },
            effective_date,
            kind,
            payload: serde_json::from_str(&payload_text).map_err(ApiError::internal)?,
            schema_version: version,
        });
    }
    Ok(events)
}

/// The tz offset of the member's most recently synced event under this
/// challenge (their best-known current offset). None when they have no events.
fn last_tz_offset(
    conn: &Connection,
    account_id: i64,
    challenge_id: &str,
) -> Result<Option<i32>, ApiError> {
    conn.query_row(
        "SELECT tz_offset_secs FROM event
         WHERE account_id = ?1 AND challenge_id = ?2
         ORDER BY server_seq DESC LIMIT 1",
        params![account_id, challenge_id],
        |r| r.get(0),
    )
    .optional()
    .map_err(ApiError::internal)
}

fn validate_field(value: &str, max_len: usize, what: &'static str) -> Result<String, ApiError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(ApiError::bad_request(format!("{what} must not be empty")));
    }
    if trimmed.chars().count() > max_len {
        return Err(ApiError::bad_request(format!(
            "{what} must be at most {max_len} characters"
        )));
    }
    Ok(trimmed.to_owned())
}

/// Normalizes a submitted invite code: trim, uppercase (codes are drawn from an
/// uppercase alphabet, so entry is case-insensitive).
fn normalize_code(code: &str) -> String {
    code.trim().to_uppercase()
}

/// A random 128-bit group id, hex-encoded.
fn new_group_id() -> String {
    let mut bytes = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut bytes);
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(char::from_digit((b >> 4) as u32, 16).unwrap());
        s.push(char::from_digit((b & 0xf) as u32, 16).unwrap());
    }
    s
}

/// A fresh unambiguous invite code that is not already taken. Retries on the
/// (astronomically rare) collision; bails after a bounded number of attempts
/// rather than looping forever.
fn unique_invite_code(conn: &Connection) -> Result<String, ApiError> {
    for _ in 0..16 {
        let code = random_invite_code();
        let taken: bool = conn
            .query_row(
                "SELECT COUNT(*) > 0 FROM groups WHERE invite_code = ?1",
                params![code],
                |r| r.get(0),
            )
            .map_err(ApiError::internal)?;
        if !taken {
            return Ok(code);
        }
    }
    Err(ApiError::internal(
        "could not allocate a unique invite code",
    ))
}

fn random_invite_code() -> String {
    let mut bytes = [0u8; INVITE_CODE_LEN];
    rand::thread_rng().fill_bytes(&mut bytes);
    bytes
        .iter()
        .map(|b| INVITE_ALPHABET[(*b as usize) % INVITE_ALPHABET.len()] as char)
        .collect()
}
