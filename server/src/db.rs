//! Server SQLite store: WAL, single writer, embedded migrations run at
//! startup before serving (docs/PHASE2.md "Server (drome-server)"). Same
//! event-store shape as the client core, plus per-account server_seq,
//! sessions, config slots, and membership/entitlement rows.

use std::time::Duration;

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

-- Group membership (groups endpoints are 501 this stage, but account delete
-- must wipe these rows — the table exists so the wipe is real).
CREATE TABLE IF NOT EXISTS membership (
    account_id INTEGER NOT NULL REFERENCES account(id),
    group_id TEXT NOT NULL,
    joined_at_epoch INTEGER NOT NULL,
    PRIMARY KEY (account_id, group_id)
);

-- Entitlement rows land with the RevenueCat webhook at end of phase; during
-- beta the BETA_ALL_ENTITLED env grants everyone regardless of this table.
CREATE TABLE IF NOT EXISTS entitlement (
    account_id INTEGER PRIMARY KEY REFERENCES account(id),
    active INTEGER NOT NULL DEFAULT 0,
    updated_at_epoch INTEGER NOT NULL
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
    Ok(conn)
}
