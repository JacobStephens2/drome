//! drome-server binary entrypoint. Runs embedded migrations at startup, then
//! serves the `/v1` API. Local dev: `cargo run -p drome-server` with a SQLite
//! file beside it (docs/PHASE2.md "Dev process").

use std::sync::Arc;

use drome_server::jwks::JwtAppleVerifier;
use drome_server::{build_router, db, AppState};

#[tokio::main]
async fn main() {
    let db_path = std::env::var("DROME_DB").unwrap_or_else(|_| "drome-server.sqlite".to_owned());
    let bind = std::env::var("DROME_BIND").unwrap_or_else(|_| "0.0.0.0:8080".to_owned());
    // Beta default: everyone entitled (docs/PHASE2.md "Entitlements").
    let beta_all_entitled = std::env::var("BETA_ALL_ENTITLED")
        .map(|v| v != "false" && v != "0")
        .unwrap_or(true);

    let conn = match db::open(&db_path) {
        Ok(conn) => conn,
        Err(e) => {
            eprintln!("failed to open/migrate db at {db_path}: {e}");
            std::process::exit(1);
        }
    };

    let state = AppState::new(conn, Arc::new(JwtAppleVerifier::apple()), beta_all_entitled);
    let app = build_router(state);

    let listener = match tokio::net::TcpListener::bind(&bind).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("failed to bind {bind}: {e}");
            std::process::exit(1);
        }
    };
    eprintln!("drome-server listening on {bind} (db: {db_path})");
    if let Err(e) = axum::serve(listener, app).await {
        eprintln!("server error: {e}");
        std::process::exit(1);
    }
}
