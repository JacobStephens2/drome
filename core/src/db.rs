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
    Ok(conn)
}
