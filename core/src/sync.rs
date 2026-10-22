//! Phase 2 sync engine, client side (docs/PHASE2.md "Sync protocol").
//!
//! Sync is idempotent event exchange: events are immutable and globally
//! unique by uuid, so push/pull both reduce to "insert what's missing".
//! Projections never sync — they recompute. Config (challenge settings,
//! presets, extras) is NOT events: it merges per-slot last-writer-wins on
//! `updated_at` with a device-id tiebreak. Goal changes stay events.
//!
//! This module owns the storage-level mechanics; the exported `DromeStore`
//! methods in `api.rs` are thin transactional wrappers. The server crate
//! (drome-server) reuses the wire types and validation via the Rust API.

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::api::{Challenge, ContainerPreset, ExtraDef};
use crate::error::{DromeError, Result};
use crate::events;
use crate::export;
use crate::time::{self, LocalInstant};

/// Config LWW slot names (the three synced config groups).
pub const SLOT_CHALLENGE: &str = "challenge";
pub const SLOT_PRESETS: &str = "presets";
pub const SLOT_EXTRAS: &str = "extras";

/// Whether a cursor-or-state-mutating sync write took effect, or was dropped
/// because a `reset_all_data` ran since the round-trip captured its reset
/// epoch (docs/PHASE2.md, sync/reset epoch invariant). A `StaleReset` is NOT
/// an error — it is the honest signal that this in-flight round-trip was
/// invalidated by a local "Start over"; the caller discards its results and
/// starts a fresh sync, which begins at cursor 0 and recovers full history.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum, Serialize, Deserialize)]
pub enum SyncOutcome {
    /// Epochs matched: the write applied normally.
    Applied,
    /// A reset invalidated this round-trip; the write was a no-op.
    StaleReset,
}

/// The snapshot one sync round-trip is built from. Read in one immediate
/// transaction, so a log or a reset cannot tear the request apart.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncPreparation {
    pub reset_epoch: i64,
    pub device_id: String,
    pub last_server_seq: i64,
    pub pending: Vec<WireEvent>,
    pub config_json: String,
}

/// One sync response, as the store applies it. `config_json` is the config
/// block the server already returns. A winner id adopts that challenge;
/// `None` or a blank id merges last-writer-wins instead. The store does not
/// learn the HTTP conflict object's field names.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncRoundResponse {
    pub acked_uuids: Vec<String>,
    pub config_json: String,
    pub winner_challenge_id: Option<String>,
    pub events: Vec<WireEvent>,
    pub new_last_server_seq: i64,
}

/// The result of applying one sync response. `inserted` counts pulled events
/// newly stored (0 on `StaleReset`, and also 0 when every pulled uuid was
/// already present). Replaces the old pull-batch record.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record, Serialize, Deserialize)]
pub struct SyncApplyResult {
    pub outcome: SyncOutcome,
    pub inserted: u32,
}

/// Whether the phone should run another sync round-trip.
///
/// True when the outcome is stale (the reset threw this round out), or when
/// the round applied and the push batch was full (`pushed_count >= push_limit`)
/// or the server set `more`. A winner being adopted is not an input: that
/// config and its events are already in this response.
#[uniffi::export]
pub fn sync_follow_up(
    pushed_count: u32,
    push_limit: u32,
    more: bool,
    outcome: SyncOutcome,
) -> bool {
    match outcome {
        SyncOutcome::StaleReset => true,
        SyncOutcome::Applied => more || pushed_count >= push_limit,
    }
}

/// Sanity cap for wire identifiers (uuids, challenge ids, device ids).
pub const MAX_WIRE_ID_LEN: usize = 64;
/// Sanity cap for a single payload's JSON text on the wire.
pub const MAX_WIRE_PAYLOAD_LEN: usize = 4_096;

/// One event serialized for the wire — exactly the client event row minus
/// the local rowid. `payload_json` is the payload as JSON text (UniFFI has
/// no JSON value type). `photo_done` payloads cross the wire with
/// `photo_ref` already stripped (refs are meaningless off-device).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record, Serialize, Deserialize)]
pub struct WireEvent {
    pub uuid: String,
    pub challenge_id: String,
    pub logged_at_epoch: i64,
    pub tz_offset_secs: i32,
    pub effective_date: Option<String>,
    pub kind: String,
    pub payload_json: String,
    pub schema_version: i64,
}

/// The challenge-settings config slot: the full challenge row (including the
/// active flag) plus its LWW stamp.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConfigChallengeSlot {
    pub updated_at_epoch: i64,
    pub device_id: String,
    pub challenge: Challenge,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConfigPresetsSlot {
    pub updated_at_epoch: i64,
    pub device_id: String,
    pub challenge_id: String,
    pub presets: Vec<ContainerPreset>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConfigExtrasSlot {
    pub updated_at_epoch: i64,
    pub device_id: String,
    pub challenge_id: String,
    pub extras: Vec<ExtraDef>,
}

/// The config block exchanged in a sync round-trip. Slots are independent:
/// each merges last-writer-wins on `(updated_at_epoch, device_id)`.
/// Crosses the FFI as a JSON string on `SyncPreparation` / `SyncRoundResponse`;
/// the server parses the same struct via serde.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ConfigBlock {
    #[serde(default)]
    pub challenge: Option<ConfigChallengeSlot>,
    #[serde(default)]
    pub presets: Option<ConfigPresetsSlot>,
    #[serde(default)]
    pub extras: Option<ConfigExtrasSlot>,
}

/// Strict last-writer-wins: the remote stamp wins only when it is strictly
/// greater than the local one, comparing `(updated_at_epoch, device_id)`
/// lexicographically (the device id is the deterministic tiebreak for
/// same-second writes on different devices). `None` local = nothing to lose.
pub fn lww_wins(remote: (i64, &str), local: Option<(i64, &str)>) -> bool {
    match local {
        None => true,
        Some(local) => remote > local,
    }
}

/// Validates one wire event against the same bounds the local log APIs
/// enforce (shared with import validation), plus wire-level sanity caps.
/// Both the client (`apply_remote_events`) and the server (push ingest) run
/// this, so a malformed event can never enter either store.
pub fn validate_wire_event(e: &WireEvent) -> Result<()> {
    validate_wire_id(&e.uuid, "event uuid")?;
    validate_wire_id(&e.challenge_id, "challenge id")?;
    if !events::is_known_kind(&e.kind) {
        return Err(DromeError::InvalidArgument(format!(
            "event {}: unknown kind {:?}",
            e.uuid, e.kind
        )));
    }
    if !(1..=1_000).contains(&e.schema_version) {
        return Err(DromeError::InvalidArgument(format!(
            "event {}: schema_version out of range",
            e.uuid
        )));
    }
    // Total time math: the instant must be representable on the wall axis.
    LocalInstant {
        epoch_secs: e.logged_at_epoch,
        tz_offset_secs: e.tz_offset_secs,
    }
    .wall_secs()?;
    if let Some(date) = &e.effective_date {
        time::parse_date(date)?;
    }
    if e.payload_json.len() > MAX_WIRE_PAYLOAD_LEN {
        return Err(DromeError::InvalidArgument(format!(
            "event {}: payload exceeds {MAX_WIRE_PAYLOAD_LEN} bytes",
            e.uuid
        )));
    }
    let payload: serde_json::Value = serde_json::from_str(&e.payload_json).map_err(|err| {
        DromeError::InvalidArgument(format!("event {}: malformed payload JSON: {err}", e.uuid))
    })?;
    export::validate_event_payload(&e.uuid, &e.kind, &payload)
}

/// Validates a synced challenge config slot against the SAME bounds
/// `create_challenge`/import enforce (start_date parses; length/cutoff/waking/
/// goal in range). The client already runs this on apply
/// (`apply_challenge_slot_inner`); the SERVER runs it on sync ingest too, so a
/// malformed challenge config can never be stored. This matters beyond storage
/// hygiene: the group-presence projection reads the server's stored challenge
/// config, and an unparseable `start_date` would fault `Projection::build`,
/// which would otherwise 500 the whole group view.
pub fn validate_challenge_slot(slot: &ConfigChallengeSlot) -> Result<()> {
    let c = &slot.challenge;
    crate::api::validate_challenge_config(
        &c.start_date,
        c.length_days,
        c.day_cutoff_minutes,
        c.waking_start_minutes,
        c.waking_end_minutes,
        c.initial_water_goal_ml,
    )
}

fn validate_wire_id(id: &str, what: &str) -> Result<()> {
    if id.trim().is_empty() || id.len() > MAX_WIRE_ID_LEN {
        return Err(DromeError::InvalidArgument(format!(
            "{what} must be non-empty and at most {MAX_WIRE_ID_LEN} bytes"
        )));
    }
    Ok(())
}

fn validate_context(context: &str) -> Result<()> {
    if context.trim().is_empty() || context.len() > MAX_WIRE_ID_LEN {
        return Err(DromeError::InvalidArgument(
            "sync context must be a non-empty account identifier".into(),
        ));
    }
    Ok(())
}

/// The payload text an event crosses the wire with. `photo_done` is stripped
/// AT THIS BOUNDARY (docs/PHASE2.md: photos never sync in Phase 2; the ref
/// is an on-device file name, meaningless anywhere else). The local row is
/// untouched. Everything else passes through verbatim.
fn wire_payload(kind: &str, payload_text: &str) -> String {
    if kind == events::KIND_PHOTO_DONE {
        r#"{"photo_ref":null}"#.to_owned()
    } else {
        payload_text.to_owned()
    }
}

// ---------------------------------------------------------------------------
// Device identity
// ---------------------------------------------------------------------------

/// This store's stable device id, generated once and persisted. Used as the
/// config-LWW tiebreak and sent with sync requests so the server can label
/// event provenance. Caller must hold a write transaction.
pub(crate) fn ensure_device_id(conn: &Connection) -> Result<String> {
    if let Some(id) = read_device_id(conn)? {
        return Ok(id);
    }
    let id = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT OR IGNORE INTO sync_device (id, device_id) VALUES (1, ?1)",
        params![id],
    )?;
    // Re-read: another connection (the widget process) may have won the race.
    read_device_id(conn)?.ok_or_else(|| {
        DromeError::Internal("sync_device row missing immediately after insert".into())
    })
}

fn read_device_id(conn: &Connection) -> Result<Option<String>> {
    conn.query_row("SELECT device_id FROM sync_device WHERE id = 1", [], |r| {
        r.get(0)
    })
    .optional()
    .map_err(DromeError::from)
}

// ---------------------------------------------------------------------------
// Push side: pending_events / ack_pushed
// ---------------------------------------------------------------------------

/// Local events past the `synced_through` watermark for `context`, oldest
/// first, capped at `limit`, serialized for the wire. Remote-origin events
/// are never included (they came FROM the server). `photo_done` payloads are
/// stripped of `photo_ref` here — the local rows keep theirs.
pub(crate) fn pending_events(
    conn: &Connection,
    context: &str,
    limit: u32,
) -> Result<Vec<WireEvent>> {
    validate_context(context)?;
    let synced_through = read_state(conn, context)?.0;
    let mut stmt = conn.prepare(
        "SELECT uuid, challenge_id, logged_at_epoch, tz_offset_secs, effective_date,
                kind, payload, schema_version
         FROM events
         WHERE id > ?1
           AND uuid NOT IN (SELECT event_uuid FROM remote_events)
         ORDER BY id
         LIMIT ?2",
    )?;
    let rows = stmt.query_map(params![synced_through, i64::from(limit)], |row| {
        Ok(WireEvent {
            uuid: row.get(0)?,
            challenge_id: row.get(1)?,
            logged_at_epoch: row.get(2)?,
            tz_offset_secs: row.get(3)?,
            effective_date: row.get(4)?,
            kind: row.get(5)?,
            payload_json: row.get(6)?,
            schema_version: row.get(7)?,
        })
    })?;
    let mut events = Vec::new();
    for row in rows {
        let mut e = row?;
        e.payload_json = wire_payload(&e.kind, &e.payload_json);
        events.push(e);
    }
    Ok(events)
}

/// Advances the push watermark after the server acked `uuids`: the new
/// `synced_through` is the highest local rowid among them (never moving
/// backwards). Unknown uuids are ignored — an ack can only confirm events
/// this store actually holds.
pub(crate) fn ack_pushed(conn: &Connection, context: &str, uuids: &[String]) -> Result<()> {
    validate_context(context)?;
    ensure_state_row(conn, context)?;
    let mut stmt = conn.prepare("SELECT id FROM events WHERE uuid = ?1")?;
    let mut max_id: Option<i64> = None;
    for uuid in uuids {
        if let Some(id) = stmt
            .query_row(params![uuid], |r| r.get::<_, i64>(0))
            .optional()?
        {
            max_id = Some(max_id.map_or(id, |m| m.max(id)));
        }
    }
    if let Some(id) = max_id {
        conn.execute(
            "UPDATE sync_state SET synced_through = MAX(synced_through, ?1) WHERE context = ?2",
            params![id, context],
        )?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Pull side: apply_remote_events
// ---------------------------------------------------------------------------

/// Idempotent upsert of pulled events: uuids already present locally are
/// skipped (including revoked ones — revocation never deletes the row), so
/// replays and self-echoes are no-ops. Inserted rows are recorded in
/// `remote_events` so `pending_events` never pushes them back. The whole
/// batch is validated first and applies atomically (caller's transaction).
/// Returns the number of events actually inserted.
pub(crate) fn apply_remote_events(conn: &Connection, events: &[WireEvent]) -> Result<u32> {
    for e in events {
        validate_wire_event(e)?;
    }
    let mut inserted = 0u32;
    for e in events {
        // Normalize the payload text (and strip photo refs defensively —
        // a compliant peer already stripped them at its own boundary).
        let payload_text = wire_payload(&e.kind, &e.payload_json);
        let payload: serde_json::Value = serde_json::from_str(&payload_text)?;
        let changed = conn.execute(
            "INSERT INTO events (uuid, challenge_id, logged_at_epoch, tz_offset_secs,
                                 effective_date, kind, payload, schema_version)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(uuid) DO NOTHING",
            params![
                e.uuid,
                e.challenge_id,
                e.logged_at_epoch,
                e.tz_offset_secs,
                e.effective_date,
                e.kind,
                serde_json::to_string(&payload)?,
                e.schema_version,
            ],
        )?;
        if changed == 1 {
            conn.execute(
                "INSERT OR IGNORE INTO remote_events (event_uuid) VALUES (?1)",
                params![e.uuid],
            )?;
            inserted += 1;
        }
    }
    Ok(inserted)
}

// ---------------------------------------------------------------------------
// Config LWW block
// ---------------------------------------------------------------------------

/// Stamps `slot`'s LWW meta with (`now`, this device). Called by every
/// config setter inside its own write transaction.
pub(crate) fn touch_config_slot(conn: &Connection, slot: &str, now: LocalInstant) -> Result<()> {
    let device_id = ensure_device_id(conn)?;
    set_slot_meta(conn, slot, now.epoch_secs, &device_id)
}

fn set_slot_meta(conn: &Connection, slot: &str, updated_at: i64, device_id: &str) -> Result<()> {
    conn.execute(
        "INSERT INTO config_meta (slot, updated_at_epoch, device_id) VALUES (?1, ?2, ?3)
         ON CONFLICT(slot) DO UPDATE
             SET updated_at_epoch = excluded.updated_at_epoch,
                 device_id = excluded.device_id",
        params![slot, updated_at, device_id],
    )?;
    Ok(())
}

fn slot_meta(conn: &Connection, slot: &str) -> Result<Option<(i64, String)>> {
    conn.query_row(
        "SELECT updated_at_epoch, device_id FROM config_meta WHERE slot = ?1",
        params![slot],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .optional()
    .map_err(DromeError::from)
}

/// The local LWW stamp a remote slot competes against. A store with config
/// but no stamp (created before sync existed) claims its challenge's
/// `created_at` under this device's id, so genuine remote edits still win
/// but an empty/older remote block can never clobber real local config.
fn local_stamp(conn: &Connection, slot: &str) -> Result<Option<(i64, String)>> {
    if let Some(meta) = slot_meta(conn, slot)? {
        return Ok(Some(meta));
    }
    match crate::api::load_active_challenge(conn)? {
        Some(c) => Ok(Some((c.created_at.epoch_secs, ensure_device_id(conn)?))),
        None => Ok(None),
    }
}

/// This store's current config block with per-slot LWW stamps. Empty block
/// when no challenge is active (a never-used store has nothing to offer).
/// Caller must hold a write transaction (the device id may be minted here).
pub(crate) fn export_config_block(conn: &Connection) -> Result<ConfigBlock> {
    let Some(challenge) = crate::api::load_active_challenge(conn)? else {
        return Ok(ConfigBlock::default());
    };
    let device_id = ensure_device_id(conn)?;
    let fallback = (challenge.created_at.epoch_secs, device_id);
    let stamp = |slot: &str| -> Result<(i64, String)> {
        Ok(slot_meta(conn, slot)?.unwrap_or_else(|| fallback.clone()))
    };
    let (c_at, c_dev) = stamp(SLOT_CHALLENGE)?;
    let (p_at, p_dev) = stamp(SLOT_PRESETS)?;
    let (x_at, x_dev) = stamp(SLOT_EXTRAS)?;
    let presets = crate::api::load_presets(conn, &challenge.id)?;
    let extras = crate::api::load_extra_defs(conn, &challenge.id)?;
    let challenge_id = challenge.id.clone();
    Ok(ConfigBlock {
        challenge: Some(ConfigChallengeSlot {
            updated_at_epoch: c_at,
            device_id: c_dev,
            challenge,
        }),
        presets: Some(ConfigPresetsSlot {
            updated_at_epoch: p_at,
            device_id: p_dev,
            challenge_id: challenge_id.clone(),
            presets,
        }),
        extras: Some(ConfigExtrasSlot {
            updated_at_epoch: x_at,
            device_id: x_dev,
            challenge_id,
            extras,
        }),
    })
}

/// Merges a remote config block per-slot: a slot applies only when its
/// stamp wins LWW against the local one; winning slots replace the local
/// config wholesale and adopt the remote stamp (so the merge converges).
/// Order matters: the challenge slot lands first so presets/extras can
/// satisfy their foreign keys; slots referencing a challenge this store has
/// never seen are skipped (they retry on a later sync, after the challenge
/// arrives). Caller must hold a write transaction.
pub(crate) fn apply_remote_config_block(conn: &Connection, block: &ConfigBlock) -> Result<()> {
    if let Some(slot) = &block.challenge {
        apply_challenge_slot(conn, slot)?;
    }
    if let Some(slot) = &block.presets {
        apply_presets_slot(conn, slot)?;
    }
    if let Some(slot) = &block.extras {
        apply_extras_slot(conn, slot)?;
    }
    Ok(())
}

/// Force-adopt the server-declared winner of a one-active-challenge conflict
/// (docs/PHASE2.md: "the first synced active challenge wins; a device pushing a
/// different active challenge ... pulls the winner"). The config LWW merge in
/// `apply_remote_config_block` CANNOT do this: when the loser's local challenge
/// stamp is newer than the winner's, the winner slot loses LWW and is skipped,
/// so the loser keeps its own active challenge forever (permanent split-brain).
/// This entry point bypasses LWW for the winner's slots, adopting the winner
/// named by the response's `active_challenge_conflict` regardless of stamp and
/// archiving every other local challenge. Idempotent. Caller holds a write tx.
pub(crate) fn adopt_active_challenge(
    conn: &Connection,
    block: &ConfigBlock,
    winner_id: &str,
) -> Result<()> {
    validate_wire_id(winner_id, "winner challenge id")?;
    // Force-apply the winner's slots (bypassing LWW). The challenge slot lands
    // first (active = 1), archiving any other local challenge; presets/extras
    // then adopt the winner's authoritative config for the same challenge.
    if let Some(slot) = &block.challenge {
        if slot.challenge.id == winner_id {
            apply_challenge_slot_inner(conn, slot, true)?;
        }
    }
    if let Some(slot) = &block.presets {
        if slot.challenge_id == winner_id {
            apply_presets_slot_inner(conn, slot, true)?;
        }
    }
    if let Some(slot) = &block.extras {
        if slot.challenge_id == winner_id {
            apply_extras_slot_inner(conn, slot, true)?;
        }
    }
    // Belt-and-suspenders: only once the winner row is actually present locally,
    // make it the sole active challenge (covers a response that named a winner
    // this store already holds but did not re-send the challenge slot). Guarded
    // on existence so we never leave the store with NO active challenge.
    if challenge_exists(conn, winner_id)? {
        conn.execute(
            "UPDATE challenge SET active = 0 WHERE id != ?1 AND active = 1",
            params![winner_id],
        )?;
        conn.execute(
            "UPDATE challenge SET active = 1 WHERE id = ?1",
            params![winner_id],
        )?;
    }
    Ok(())
}

fn remote_wins(conn: &Connection, slot: &str, updated_at: i64, device_id: &str) -> Result<bool> {
    let local = local_stamp(conn, slot)?;
    Ok(lww_wins(
        (updated_at, device_id),
        local.as_ref().map(|(t, d)| (*t, d.as_str())),
    ))
}

fn apply_challenge_slot(conn: &Connection, slot: &ConfigChallengeSlot) -> Result<()> {
    apply_challenge_slot_inner(conn, slot, false)
}

/// `force = true` bypasses the LWW gate — used only when adopting the
/// server-declared winner of a one-active-challenge conflict, whose stamp may
/// be OLDER than the loser's local one (docs/PHASE2.md: the loser must pull the
/// winner regardless).
fn apply_challenge_slot_inner(
    conn: &Connection,
    slot: &ConfigChallengeSlot,
    force: bool,
) -> Result<()> {
    validate_wire_id(&slot.device_id, "device id")?;
    if !force && !remote_wins(conn, SLOT_CHALLENGE, slot.updated_at_epoch, &slot.device_id)? {
        return Ok(());
    }
    let c = &slot.challenge;
    validate_wire_id(&c.id, "challenge id")?;
    crate::api::validate_challenge_config(
        &c.start_date,
        c.length_days,
        c.day_cutoff_minutes,
        c.waking_start_minutes,
        c.waking_end_minutes,
        c.initial_water_goal_ml,
    )?;
    if c.active {
        // One active challenge per store: adopting a remote active challenge
        // archives any other local one (its events stay in the log).
        conn.execute(
            "UPDATE challenge SET active = 0 WHERE id != ?1",
            params![c.id],
        )?;
    }
    conn.execute(
        "INSERT INTO challenge (id, created_at_epoch, created_tz_offset_secs, ruleset,
             start_date, length_days, day_cutoff_minutes, waking_start_minutes,
             waking_end_minutes, initial_water_goal_ml, diet_description, current_book, active)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
         ON CONFLICT(id) DO UPDATE SET
             created_at_epoch = excluded.created_at_epoch,
             created_tz_offset_secs = excluded.created_tz_offset_secs,
             ruleset = excluded.ruleset,
             start_date = excluded.start_date,
             length_days = excluded.length_days,
             day_cutoff_minutes = excluded.day_cutoff_minutes,
             waking_start_minutes = excluded.waking_start_minutes,
             waking_end_minutes = excluded.waking_end_minutes,
             initial_water_goal_ml = excluded.initial_water_goal_ml,
             diet_description = excluded.diet_description,
             current_book = excluded.current_book,
             active = excluded.active",
        params![
            c.id,
            c.created_at.epoch_secs,
            c.created_at.tz_offset_secs,
            c.ruleset.label(),
            c.start_date,
            c.length_days,
            c.day_cutoff_minutes,
            c.waking_start_minutes,
            c.waking_end_minutes,
            c.initial_water_goal_ml,
            c.diet_description,
            c.current_book,
            c.active,
        ],
    )?;
    set_slot_meta(conn, SLOT_CHALLENGE, slot.updated_at_epoch, &slot.device_id)
}

fn apply_presets_slot(conn: &Connection, slot: &ConfigPresetsSlot) -> Result<()> {
    apply_presets_slot_inner(conn, slot, false)
}

fn apply_presets_slot_inner(
    conn: &Connection,
    slot: &ConfigPresetsSlot,
    force: bool,
) -> Result<()> {
    validate_wire_id(&slot.device_id, "device id")?;
    if !force && !remote_wins(conn, SLOT_PRESETS, slot.updated_at_epoch, &slot.device_id)? {
        return Ok(());
    }
    if !challenge_exists(conn, &slot.challenge_id)? {
        return Ok(()); // Unknown challenge: retry after it syncs.
    }
    for p in &slot.presets {
        if p.id.trim().is_empty() || p.name.trim().is_empty() {
            return Err(DromeError::InvalidArgument(
                "preset id and name must be non-empty".into(),
            ));
        }
        if !(1..=crate::api::MAX_WATER_LOG_ML).contains(&p.ml) {
            return Err(DromeError::InvalidArgument(format!(
                "preset ml must be in 1..={}",
                crate::api::MAX_WATER_LOG_ML
            )));
        }
    }
    conn.execute(
        "DELETE FROM container_presets WHERE challenge_id = ?1",
        params![slot.challenge_id],
    )?;
    for p in &slot.presets {
        conn.execute(
            "INSERT INTO container_presets (id, challenge_id, name, ml, sort_order)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![p.id, slot.challenge_id, p.name, p.ml, p.sort_order],
        )?;
    }
    set_slot_meta(conn, SLOT_PRESETS, slot.updated_at_epoch, &slot.device_id)
}

fn apply_extras_slot(conn: &Connection, slot: &ConfigExtrasSlot) -> Result<()> {
    apply_extras_slot_inner(conn, slot, false)
}

fn apply_extras_slot_inner(conn: &Connection, slot: &ConfigExtrasSlot, force: bool) -> Result<()> {
    validate_wire_id(&slot.device_id, "device id")?;
    if !force && !remote_wins(conn, SLOT_EXTRAS, slot.updated_at_epoch, &slot.device_id)? {
        return Ok(());
    }
    if !challenge_exists(conn, &slot.challenge_id)? {
        return Ok(()); // Unknown challenge: retry after it syncs.
    }
    for x in &slot.extras {
        if x.id.trim().is_empty() || x.name.trim().is_empty() {
            return Err(DromeError::InvalidArgument(
                "extra id and name must be non-empty".into(),
            ));
        }
    }
    conn.execute(
        "DELETE FROM extra_defs WHERE challenge_id = ?1",
        params![slot.challenge_id],
    )?;
    for x in &slot.extras {
        conn.execute(
            "INSERT INTO extra_defs (id, challenge_id, name, cadence, enabled)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                x.id,
                slot.challenge_id,
                x.name,
                x.cadence.label(),
                x.enabled
            ],
        )?;
    }
    set_slot_meta(conn, SLOT_EXTRAS, slot.updated_at_epoch, &slot.device_id)
}

fn challenge_exists(conn: &Connection, id: &str) -> Result<bool> {
    conn.query_row(
        "SELECT COUNT(*) > 0 FROM challenge WHERE id = ?1",
        params![id],
        |r| r.get(0),
    )
    .map_err(DromeError::from)
}

// ---------------------------------------------------------------------------
// Pull cursor
// ---------------------------------------------------------------------------

pub(crate) fn get_last_server_seq(conn: &Connection, context: &str) -> Result<i64> {
    validate_context(context)?;
    Ok(read_state(conn, context)?.1)
}

pub(crate) fn set_last_server_seq(conn: &Connection, context: &str, seq: i64) -> Result<()> {
    validate_context(context)?;
    if seq < 0 {
        return Err(DromeError::InvalidArgument(
            "last_server_seq must be >= 0".into(),
        ));
    }
    ensure_state_row(conn, context)?;
    conn.execute(
        "UPDATE sync_state SET last_server_seq = ?1 WHERE context = ?2",
        params![seq, context],
    )?;
    Ok(())
}

/// (synced_through, last_server_seq) for `context`; (0, 0) when the context
/// has never synced (read-only — no row is created).
fn read_state(conn: &Connection, context: &str) -> Result<(i64, i64)> {
    conn.query_row(
        "SELECT synced_through, last_server_seq FROM sync_state WHERE context = ?1",
        params![context],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .optional()
    .map(|row| row.unwrap_or((0, 0)))
    .map_err(DromeError::from)
}

fn ensure_state_row(conn: &Connection, context: &str) -> Result<()> {
    conn.execute(
        "INSERT OR IGNORE INTO sync_state (context) VALUES (?1)",
        params![context],
    )?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Reset epoch (the sync/reset atomicity invariant — docs/PHASE2.md)
// ---------------------------------------------------------------------------

/// This store's current reset generation. `prepare_sync_round` reads it in
/// the same transaction as the rest of the request snapshot, and
/// `apply_sync_response` no-ops the whole tail when it no longer matches,
/// because a `reset_all_data` bumped it during the network hop. Defaults to 0
/// for a store opened before this table existed (treated as never-reset).
/// Caller reads under the same lock as the mutation it guards, so the check
/// is atomic with the write (no reset can slip in between).
pub(crate) fn current_reset_epoch(conn: &Connection) -> Result<i64> {
    conn.query_row("SELECT epoch FROM sync_epoch WHERE id = 1", [], |r| {
        r.get(0)
    })
    .optional()
    .map(|row| row.unwrap_or(0))
    .map_err(DromeError::from)
}

/// Increments the reset generation, invalidating every in-flight round-trip's
/// tail writes. Called INSIDE `reset_all_data`'s wipe transaction; the row is
/// deliberately never deleted by the wipe (it must outlive it). Caller holds
/// the write transaction.
pub(crate) fn bump_reset_epoch(conn: &Connection) -> Result<()> {
    conn.execute(
        "INSERT INTO sync_epoch (id, epoch) VALUES (1, 1)
         ON CONFLICT(id) DO UPDATE SET epoch = epoch + 1",
        [],
    )?;
    Ok(())
}

/// The gate every stale-deliverable sync write shares: `Applied` when the
/// captured epoch still matches this store's current reset generation,
/// `StaleReset` when a reset has since moved it on. Evaluated inside the
/// caller's write transaction so the decision and the write it guards commit
/// together.
pub(crate) fn reset_gate(conn: &Connection, expected_epoch: i64) -> Result<SyncOutcome> {
    if current_reset_epoch(conn)? == expected_epoch {
        Ok(SyncOutcome::Applied)
    } else {
        Ok(SyncOutcome::StaleReset)
    }
}

/// Field checks a config block must pass before any tail write. An unknown
/// challenge is not an error here: the merge skips that slot, same as apply.
pub(crate) fn validate_config_block(block: &ConfigBlock) -> Result<()> {
    if let Some(slot) = &block.challenge {
        validate_wire_id(&slot.device_id, "device id")?;
        validate_wire_id(&slot.challenge.id, "challenge id")?;
        validate_challenge_slot(slot)?;
    }
    if let Some(slot) = &block.presets {
        validate_wire_id(&slot.device_id, "device id")?;
        validate_wire_id(&slot.challenge_id, "challenge id")?;
        for p in &slot.presets {
            if p.id.trim().is_empty() || p.name.trim().is_empty() {
                return Err(DromeError::InvalidArgument(
                    "preset id and name must be non-empty".into(),
                ));
            }
            if !(1..=crate::api::MAX_WATER_LOG_ML).contains(&p.ml) {
                return Err(DromeError::InvalidArgument(format!(
                    "preset ml must be in 1..={}",
                    crate::api::MAX_WATER_LOG_ML
                )));
            }
        }
    }
    if let Some(slot) = &block.extras {
        validate_wire_id(&slot.device_id, "device id")?;
        validate_wire_id(&slot.challenge_id, "challenge id")?;
        for x in &slot.extras {
            if x.id.trim().is_empty() || x.name.trim().is_empty() {
                return Err(DromeError::InvalidArgument(
                    "extra id and name must be non-empty".into(),
                ));
            }
        }
    }
    Ok(())
}

fn normalize_winner(raw: Option<&str>) -> Result<Option<String>> {
    match raw {
        None => Ok(None),
        Some(id) if id.trim().is_empty() => Ok(None),
        Some(id) => {
            validate_wire_id(id, "winner challenge id")?;
            Ok(Some(id.to_owned()))
        }
    }
}

/// Reset epoch, device id, pull cursor, pending events, and config JSON.
/// The device id is minted here on first use, so this is a write transaction.
/// Caller holds an immediate transaction and commits it.
pub(crate) fn prepare_sync_round(
    conn: &Connection,
    context: &str,
    limit: u32,
) -> Result<SyncPreparation> {
    let reset_epoch = current_reset_epoch(conn)?;
    let device_id = ensure_device_id(conn)?;
    let last_server_seq = get_last_server_seq(conn, context)?;
    let pending = pending_events(conn, context, limit)?;
    let config_json = serde_json::to_string(&export_config_block(conn)?)?;
    Ok(SyncPreparation {
        reset_epoch,
        device_id,
        last_server_seq,
        pending,
        config_json,
    })
}

/// Apply one sync response inside the caller's write transaction.
///
/// The epoch is checked before any write and before payload validation. A
/// stale epoch returns `StaleReset` and leaves the transaction untouched,
/// even when the payload is malformed. A live epoch validates config and
/// pulled events before ack; a bad payload returns an error with nothing
/// written (the caller rolls the transaction back). A valid payload then
/// acks, adopts or merges, inserts the pulled events, and assigns the cursor.
pub(crate) fn apply_sync_response(
    conn: &Connection,
    context: &str,
    expected_reset_epoch: i64,
    response: &SyncRoundResponse,
) -> Result<SyncApplyResult> {
    if reset_gate(conn, expected_reset_epoch)? == SyncOutcome::StaleReset {
        return Ok(SyncApplyResult {
            outcome: SyncOutcome::StaleReset,
            inserted: 0,
        });
    }
    let block: ConfigBlock = serde_json::from_str(&response.config_json)?;
    validate_config_block(&block)?;
    for event in &response.events {
        validate_wire_event(event)?;
    }
    if response.new_last_server_seq < 0 {
        return Err(DromeError::InvalidArgument(
            "last_server_seq must be >= 0".into(),
        ));
    }
    let winner = normalize_winner(response.winner_challenge_id.as_deref())?;
    ack_pushed(conn, context, &response.acked_uuids)?;
    if let Some(id) = winner.as_deref() {
        adopt_active_challenge(conn, &block, id)?;
    } else {
        apply_remote_config_block(conn, &block)?;
    }
    let inserted = apply_remote_events(conn, &response.events)?;
    set_last_server_seq(conn, context, response.new_last_server_seq)?;
    Ok(SyncApplyResult {
        outcome: SyncOutcome::Applied,
        inserted,
    })
}
