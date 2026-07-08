//! Server SQLite store: WAL, single writer, embedded migrations run at
//! startup before serving (docs/PHASE2.md "Server (drome-server)"). Same
//! event-store shape as the client core, plus per-account server_seq,
//! sessions, config slots, and membership/entitlement rows.

use std::time::Duration;

use rand::RngCore;
use rusqlite::Connection;

use crate::error::ApiError;

const BUSY_TIMEOUT: Duration = Duration::from_millis(5_000);

/// Embedded schema, applied idempotently at startup (single-writer, so no
/// migration ordering concerns yet — this is the v1 baseline).
const MIGRATIONS_SQL: &str = "
CREATE TABLE IF NOT EXISTS account (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    apple_sub TEXT NOT NULL UNIQUE,
    email TEXT,
    created_at_epoch INTEGER NOT NULL,
    -- The account's one canonical active challenge (docs/PHASE2.md
    -- \"one active challenge per account\"). NULL until the first is synced.
    active_challenge_id TEXT,
    -- Monotone per-account server_seq allocator (assigned on event insert).
    next_server_seq INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS session (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id INTEGER NOT NULL REFERENCES account(id),
    -- Opaque bearer tokens are stored ONLY as SHA-256 hashes (never at rest).
    access_hash TEXT NOT NULL UNIQUE,
    refresh_hash TEXT NOT NULL UNIQUE,
    created_at_epoch INTEGER NOT NULL,
    expires_at_epoch INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_session_account ON session (account_id);

CREATE TABLE IF NOT EXISTS event (
    account_id INTEGER NOT NULL REFERENCES account(id),
    uuid TEXT NOT NULL,
    server_seq INTEGER NOT NULL,
    device_id TEXT NOT NULL,
    challenge_id TEXT NOT NULL,
    logged_at_epoch INTEGER NOT NULL,
    tz_offset_secs INTEGER NOT NULL,
    effective_date TEXT,
    kind TEXT NOT NULL,
    payload TEXT NOT NULL,
    schema_version INTEGER NOT NULL,
    PRIMARY KEY (account_id, uuid)
);

CREATE INDEX IF NOT EXISTS idx_event_seq ON event (account_id, server_seq);

-- Per-slot last-writer-wins config (challenge settings, presets, extras).
-- Keyed by challenge so an account can hold an archived (lost-conflict)
-- challenge's config alongside the active one. `payload` is the serialized
-- client config slot, returned verbatim on pull.
CREATE TABLE IF NOT EXISTS config_slot (
    account_id INTEGER NOT NULL REFERENCES account(id),
    slot TEXT NOT NULL,
    challenge_id TEXT NOT NULL,
    updated_at_epoch INTEGER NOT NULL,
    device_id TEXT NOT NULL,
    payload TEXT NOT NULL,
    -- 1 when this challenge lost the one-active-challenge race and is stored
    -- archived with the sync_conflict label.
    sync_conflict INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, slot, challenge_id)
);

-- Friend groups (docs/PHASE2.md groups). The invite_code is the join
-- credential (short, unambiguous — no 0/O/1/I). created_by_account is the
-- creator; a group is deleted when its last member leaves.
CREATE TABLE IF NOT EXISTS groups (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    invite_code TEXT NOT NULL UNIQUE,
    created_by_account INTEGER NOT NULL REFERENCES account(id),
    created_at_epoch INTEGER NOT NULL
);

-- Group membership. display_name is PER-MEMBERSHIP (a user may present a
-- different name in each group) and is the ONLY human-facing identity leaked
-- to a group. member_handle is an opaque per-(group,account) id — the ONLY
-- member identifier that crosses the group wire. It is unique per membership,
-- so the same user carries a DIFFERENT handle in each group and cannot be
-- correlated across groups; the global account.id is NEVER exposed to a group.
CREATE TABLE IF NOT EXISTS membership (
    account_id INTEGER NOT NULL REFERENCES account(id),
    group_id TEXT NOT NULL,
    joined_at_epoch INTEGER NOT NULL,
    display_name TEXT,
    member_handle TEXT,
    PRIMARY KEY (account_id, group_id)
);

CREATE INDEX IF NOT EXISTS idx_membership_group ON membership (group_id);

-- In-app nudges (docs/PHASE2.md: \"a nudge row the member sees on next sync\").
-- Content-free: only who nudged whom, in which group, and whether it has been
-- delivered (seen). No message body ever.
CREATE TABLE IF NOT EXISTS nudge (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    group_id TEXT NOT NULL,
    from_account INTEGER NOT NULL REFERENCES account(id),
    to_account INTEGER NOT NULL REFERENCES account(id),
    created_at_epoch INTEGER NOT NULL,
    seen INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_nudge_inbox ON nudge (to_account, seen);

-- Entitlement rows land with the RevenueCat webhook at end of phase; during
-- beta the BETA_ALL_ENTITLED env grants everyone regardless of this table.
CREATE TABLE IF NOT EXISTS entitlement (
    account_id INTEGER PRIMARY KEY REFERENCES account(id),
    active INTEGER NOT NULL DEFAULT 0,
    updated_at_epoch INTEGER NOT NULL
);

-- Pending email six-digit OTP codes (docs/PHASE2.md \"Auth\"). ONE row per
-- email (a new request replaces the prior code), the code stored ONLY as a
-- SHA-256 hash. `attempts` caps guessing; `expires_at_epoch` bounds the window;
-- `created_at_epoch` drives the resend cooldown. The row is deleted on success,
-- expiry, or attempt exhaustion — it never becomes an account by itself.
CREATE TABLE IF NOT EXISTS email_code (
    email TEXT PRIMARY KEY,
    code_hash TEXT NOT NULL,
    expires_at_epoch INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    created_at_epoch INTEGER NOT NULL
);
";

/// Opens the server DB (WAL, foreign keys on) and runs migrations.
pub fn open(db_path: &str) -> Result<Connection, ApiError> {
    let conn = Connection::open(db_path).map_err(ApiError::internal)?;
    let _mode: String = conn
        .query_row("PRAGMA journal_mode = WAL", [], |row| row.get(0))
        .map_err(ApiError::internal)?;
    conn.busy_timeout(BUSY_TIMEOUT)
        .map_err(ApiError::internal)?;
    conn.pragma_update(None, "foreign_keys", "ON")
        .map_err(ApiError::internal)?;
    conn.pragma_update(None, "synchronous", "NORMAL")
        .map_err(ApiError::internal)?;
    conn.execute_batch(MIGRATIONS_SQL)
        .map_err(ApiError::internal)?;
    ensure_membership_display_name(&conn)?;
    ensure_membership_member_handle(&conn)?;
    Ok(conn)
}

/// Idempotently adds `membership.display_name` to a dev DB created before
/// groups shipped (a fresh DB already has it from the `CREATE TABLE` above, so
/// `ADD COLUMN` would error — guard on the column's presence). display_name is
/// the only identity a group leaks, so it must exist before any group route.
fn ensure_membership_display_name(conn: &Connection) -> Result<(), ApiError> {
    let has: bool = conn
        .query_row(
            "SELECT COUNT(*) > 0 FROM pragma_table_info('membership') WHERE name = 'display_name'",
            [],
            |r| r.get(0),
        )
        .map_err(ApiError::internal)?;
    if !has {
        conn.execute("ALTER TABLE membership ADD COLUMN display_name TEXT", [])
            .map_err(ApiError::internal)?;
    }
    Ok(())
}

/// Idempotently adds `membership.member_handle` (the opaque per-(group,account)
/// wire id) to a dev DB created before per-group handles shipped, then backfills
/// a fresh random handle for every membership row missing one. The handle is
/// the ONLY member identifier the group surface exposes, so every membership
/// must have one before any group route runs — and it must exist for the rows
/// created by earlier builds too, not just fresh inserts.
fn ensure_membership_member_handle(conn: &Connection) -> Result<(), ApiError> {
    let has: bool = conn
        .query_row(
            "SELECT COUNT(*) > 0 FROM pragma_table_info('membership') WHERE name = 'member_handle'",
            [],
            |r| r.get(0),
        )
        .map_err(ApiError::internal)?;
    if !has {
        conn.execute("ALTER TABLE membership ADD COLUMN member_handle TEXT", [])
            .map_err(ApiError::internal)?;
    }
    // Backfill any rows without a handle (older memberships, or the column just
    // added). Read the target rows first, then update each with a fresh handle.
    let targets: Vec<(i64, String)> = {
        let mut stmt = conn
            .prepare(
                "SELECT account_id, group_id FROM membership
                 WHERE member_handle IS NULL OR member_handle = ''",
            )
            .map_err(ApiError::internal)?;
        let rows = stmt
            .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))
            .map_err(ApiError::internal)?;
        let mut v = Vec::new();
        for row in rows {
            v.push(row.map_err(ApiError::internal)?);
        }
        v
    };
    for (account_id, group_id) in targets {
        conn.execute(
            "UPDATE membership SET member_handle = ?3 WHERE account_id = ?1 AND group_id = ?2",
            rusqlite::params![account_id, group_id, random_member_handle()],
        )
        .map_err(ApiError::internal)?;
    }
    Ok(())
}

/// A random 128-bit opaque membership handle, hex-encoded. Shared by the
/// backfill migration and (via `groups`) fresh joins.
pub fn random_member_handle() -> String {
    let mut bytes = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut bytes);
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(char::from_digit((b >> 4) as u32, 16).unwrap());
        s.push(char::from_digit((b & 0xf) as u32, 16).unwrap());
    }
    s
}
