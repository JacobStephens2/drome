//! SQLite schema and connection setup. The DB is shared with the widget
//! process, hence WAL mode and a busy timeout. The `events` table is
//! append-only, enforced in the database itself with RAISE triggers.

use std::time::Duration;

use rusqlite::Connection;

use crate::error::Result;

const BUSY_TIMEOUT: Duration = Duration::from_millis(5_000);

const SCHEMA_SQL: &str = "
CREATE TABLE IF NOT EXISTS challenge (
    id TEXT PRIMARY KEY,
    created_at_epoch INTEGER NOT NULL,
    created_tz_offset_secs INTEGER NOT NULL,
    ruleset TEXT NOT NULL CHECK (ruleset IN ('flexible', 'purist')),
    start_date TEXT NOT NULL,
    length_days INTEGER NOT NULL,
    day_cutoff_minutes INTEGER NOT NULL,
    waking_start_minutes INTEGER NOT NULL,
    waking_end_minutes INTEGER NOT NULL,
    initial_water_goal_ml INTEGER NOT NULL,
    diet_description TEXT,
    current_book TEXT,
    active INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS container_presets (
    id TEXT NOT NULL,
    challenge_id TEXT NOT NULL REFERENCES challenge(id),
    name TEXT NOT NULL,
    ml INTEGER NOT NULL,
    sort_order INTEGER NOT NULL,
    PRIMARY KEY (challenge_id, id)
);

CREATE TABLE IF NOT EXISTS extra_defs (
    id TEXT NOT NULL,
    challenge_id TEXT NOT NULL REFERENCES challenge(id),
    name TEXT NOT NULL,
    cadence TEXT NOT NULL CHECK (cadence IN ('daily', 'weekly')),
    enabled INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (challenge_id, id)
);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT NOT NULL UNIQUE,
    challenge_id TEXT NOT NULL,
    logged_at_epoch INTEGER NOT NULL,
    tz_offset_secs INTEGER NOT NULL,
    effective_date TEXT,
    kind TEXT NOT NULL,
    payload TEXT NOT NULL,
    schema_version INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_events_challenge
    ON events (challenge_id, logged_at_epoch, id);

-- Phase 2 sync state (docs/PHASE2.md \"Sync protocol\"). Plain config tables,
-- NOT append-only: watermarks move forward, config stamps get overwritten.

-- This store's stable device identity (lazily generated once).
CREATE TABLE IF NOT EXISTS sync_device (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    device_id TEXT NOT NULL
);

-- Per account/device-context watermarks: `synced_through` is the local
-- events.id high-water mark the server has acked (push side);
-- `last_server_seq` is the pull cursor over the account's server_seq.
CREATE TABLE IF NOT EXISTS sync_state (
    context TEXT PRIMARY KEY,
    synced_through INTEGER NOT NULL DEFAULT 0,
    last_server_seq INTEGER NOT NULL DEFAULT 0
);

-- UUIDs of events applied FROM the server (remote origin), so
-- pending_events never echoes them back to the server.
CREATE TABLE IF NOT EXISTS remote_events (
    event_uuid TEXT PRIMARY KEY
);

-- Per-slot last-writer-wins stamps for the config block (challenge settings,
-- presets, extras). Written by the config setters, compared on merge.
CREATE TABLE IF NOT EXISTS config_meta (
    slot TEXT PRIMARY KEY,
    updated_at_epoch INTEGER NOT NULL,
    device_id TEXT NOT NULL
);

-- Monotonic reset generation (docs/PHASE2.md, sync/reset epoch invariant).
-- A single row that reset_all_data INCREMENTS and, unlike every other sync
-- table, NEVER wipes: it must survive the wipe so a sync round-trip captured
-- before the reset can be told its tail writes are stale. Every cursor-or-
-- state-mutating sync call carries the epoch in effect when its round-trip
-- began and no-ops when this counter has moved on — that is what stops a
-- stale in-flight round-trip from resurrecting a pre-reset pull cursor and
-- silently stranding the account's server-held history.
CREATE TABLE IF NOT EXISTS sync_epoch (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    epoch INTEGER NOT NULL DEFAULT 0
);
INSERT OR IGNORE INTO sync_epoch (id, epoch) VALUES (1, 0);
";

/// The append-only guard on `events`, enforced in the database itself.
/// Kept as its own const because `DromeStore::reset_all_data` must drop and
/// recreate these EXACT triggers inside its wipe transaction — this is the
/// single source of truth for their DDL (both `open` and the reset run it).
pub(crate) const APPEND_ONLY_TRIGGERS_SQL: &str = "
CREATE TRIGGER IF NOT EXISTS events_append_only_update
BEFORE UPDATE ON events
BEGIN
    SELECT RAISE(ABORT, 'events table is append-only');
END;

CREATE TRIGGER IF NOT EXISTS events_append_only_delete
BEFORE DELETE ON events
BEGIN
    SELECT RAISE(ABORT, 'events table is append-only');
END;
";

pub fn open(db_path: &str) -> Result<Connection> {
    let conn = Connection::open(db_path)?;
    // journal_mode returns a result row; query it rather than execute it.
    let _mode: String = conn.query_row("PRAGMA journal_mode = WAL", [], |row| row.get(0))?;
    conn.busy_timeout(BUSY_TIMEOUT)?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.execute_batch(SCHEMA_SQL)?;
    conn.execute_batch(APPEND_ONLY_TRIGGERS_SQL)?;
    Ok(conn)
}
