//! Sign-in-with-Apple exchange, opaque bearer sessions (hashed at rest,
//! rotating refresh), and the auth middleware (docs/PHASE2.md "Auth").

use axum::extract::{Request, State};
use axum::http::{header, StatusCode};
use axum::middleware::Next;
use axum::response::Response;
use axum::{Extension, Json};
use rand::RngCore;
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::ApiError;
use crate::AppState;

/// Sessions live 30 days; a refresh rotates both tokens and resets the clock.
const SESSION_TTL_SECS: i64 = 30 * 24 * 3_600;

/// An authenticated account, loaded by the middleware and handed to handlers
/// via `Extension`.
#[derive(Debug, Clone)]
pub struct Account {
    pub id: i64,
    pub apple_sub: String,
    pub email: Option<String>,
    pub active_challenge_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct AppleAuthRequest {
    /// The identity token from `SignInWithAppleButton`.
    pub identity_token: String,
    /// The RAW nonce the client generated for this Sign-in-with-Apple request
    /// (it handed Apple `sha256(nonce)`, which Apple echoes into the token's
    /// `nonce` claim). The server rebinds the two before issuing a session, so
    /// a captured identity token can't be replayed by anyone who doesn't hold
    /// the raw nonce (docs/PHASE2.md "Auth"). Optional while the SwiftUI SIWA
    /// call is still a later stage; when the token carries a nonce claim it MUST
    /// be supplied and match.
    #[serde(default)]
    pub nonce: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct AuthResponse {
    pub account_id: i64,
    pub access_token: String,
    pub refresh_token: String,
    pub expires_at_epoch: i64,
}

#[derive(Debug, Deserialize)]
pub struct RefreshRequest {
    pub refresh_token: String,
}

#[derive(Debug, Deserialize)]
pub struct DevAuthRequest {
    /// An arbitrary label naming the synthetic account to mint a session for.
    /// The account's `apple_sub` is `"dev:" + account_key`, so it can never
    /// collide with a real Sign-in-with-Apple `sub` (Apple subs are opaque and
    /// never carry that prefix), and two distinct keys are two isolated
    /// accounts.
    pub account_key: String,
}

// --- token helpers ---------------------------------------------------------

/// A fresh 256-bit opaque token, hex-encoded.
fn new_token() -> String {
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    to_hex(&bytes)
}

/// SHA-256, hex-encoded — what we persist so a DB leak never yields a usable
/// bearer token.
pub fn hash_token(token: &str) -> String {
    let digest = Sha256::digest(token.as_bytes());
    to_hex(&digest)
}

fn to_hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(char::from_digit((b >> 4) as u32, 16).unwrap());
        s.push(char::from_digit((b & 0xf) as u32, 16).unwrap());
    }
    s
}

/// Binds the client's raw nonce to the identity token's `nonce` claim
/// (docs/PHASE2.md "Auth"): the claim is `sha256(raw)` in hex, exactly what
/// `hash_token` computes. Enforced whenever EITHER side presents a nonce, so a
/// token carrying a nonce claim can never be redeemed without the matching raw
/// value (replay protection), while a legacy token with neither still
/// authenticates. Preimage resistance — not secret comparison — is what makes a
/// stolen token useless, so a plain equality check is sufficient.
fn verify_apple_nonce(raw: Option<&str>, claim: Option<&str>) -> Result<(), ApiError> {
    match (raw, claim) {
        (None, None) => Ok(()),
        (Some(raw), Some(claim)) if hash_token(raw) == claim => Ok(()),
        _ => Err(ApiError::unauthorized(
            "bad_nonce",
            "nonce missing or does not match the identity token",
        )),
    }
}

// --- handlers --------------------------------------------------------------

/// `POST /v1/auth/apple` — verify the identity token, upsert the account by
/// `apple_sub`, issue a new session.
pub async fn apple_auth(
    State(state): State<AppState>,
    Json(req): Json<AppleAuthRequest>,
) -> Result<Json<AuthResponse>, ApiError> {
    let identity = state.verifier.verify(&req.identity_token)?;
    // Replay binding: a token minted for a specific nonce can only be redeemed
    // by a caller who also holds the raw nonce (docs/PHASE2.md "Auth").
    verify_apple_nonce(req.nonce.as_deref(), identity.nonce.as_deref())?;
    let now = state.now_epoch();

    let conn = state.db.lock().map_err(|_| ApiError::internal("db lock"))?;
    // Upsert by apple_sub; keep the latest non-null relay email.
    conn.execute(
        "INSERT INTO account (apple_sub, email, created_at_epoch) VALUES (?1, ?2, ?3)
         ON CONFLICT(apple_sub) DO UPDATE SET email = COALESCE(excluded.email, account.email)",
        params![identity.sub, identity.email, now],
    )
    .map_err(ApiError::internal)?;
    let account_id: i64 = conn
        .query_row(
            "SELECT id FROM account WHERE apple_sub = ?1",
            params![identity.sub],
            |r| r.get(0),
        )
        .map_err(ApiError::internal)?;

    let resp = issue_session(&conn, account_id, now)?;
    Ok(Json(resp))
}

/// `POST /v1/auth/refresh` — rotate the session (old tokens are invalidated).
pub async fn refresh(
    State(state): State<AppState>,
    Json(req): Json<RefreshRequest>,
) -> Result<Json<AuthResponse>, ApiError> {
    let now = state.now_epoch();
    let refresh_hash = hash_token(&req.refresh_token);
    let conn = state.db.lock().map_err(|_| ApiError::internal("db lock"))?;
    // Gate on expiry exactly like `require_auth` does for the access token
    // (both share `expires_at_epoch`): without this, an EXPIRED refresh token
    // still rotates into a brand-new 30-day session, so the TTL bounds nothing
    // and a single leaked refresh token is a permanent credential. An expired
    // session must force re-authentication, same 401 as an unknown token.
    let session: Option<(i64, i64)> = conn
        .query_row(
            "SELECT id, account_id FROM session
             WHERE refresh_hash = ?1 AND expires_at_epoch > ?2",
            params![refresh_hash, now],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(ApiError::internal)?;
    let Some((session_id, account_id)) = session else {
        return Err(ApiError::unauthorized(
            "bad_refresh",
            "unknown or expired refresh token",
        ));
    };

    // Rotate in place: new hashes, new expiry. The old tokens no longer match.
    let access_token = new_token();
    let refresh_token = new_token();
    let expires_at = now + SESSION_TTL_SECS;
    conn.execute(
        "UPDATE session SET access_hash = ?1, refresh_hash = ?2, expires_at_epoch = ?3
         WHERE id = ?4",
        params![
            hash_token(&access_token),
            hash_token(&refresh_token),
            expires_at,
            session_id
        ],
    )
    .map_err(ApiError::internal)?;

    Ok(Json(AuthResponse {
        account_id,
        access_token,
        refresh_token,
        expires_at_epoch: expires_at,
    }))
}

/// `POST /v1/auth/dev` — **LOCAL DEV ONLY**, mounted only when `DROME_DEV_AUTH=1`
/// (unreachable 404 otherwise; see `build_router`). Mints a normal session for a
/// synthetic account keyed by `account_key` so the iOS client can be exercised
/// end-to-end against a locally-run server WITHOUT a real Sign-in-with-Apple
/// token (Apple tokens can't be minted headlessly). The account is upserted with
/// `apple_sub = "dev:" + account_key`; from there every route treats the session
/// identically to an Apple one because it reuses the exact `issue_session` path.
/// NEVER enable this in production (docs/PHASE2.md "Local dev auth").
pub async fn dev_auth(
    State(state): State<AppState>,
    Json(req): Json<DevAuthRequest>,
) -> Result<Json<AuthResponse>, ApiError> {
    let account_key = req.account_key.trim();
    if account_key.is_empty() {
        return Err(ApiError::bad_request("account_key must be non-empty"));
    }
    let apple_sub = format!("dev:{account_key}");
    let now = state.now_epoch();

    let conn = state.db.lock().map_err(|_| ApiError::internal("db lock"))?;
    // Upsert by apple_sub (idempotent: re-authing the same key reuses its
    // account, like the Apple path). No email for a synthetic account.
    conn.execute(
        "INSERT INTO account (apple_sub, email, created_at_epoch) VALUES (?1, ?2, ?3)
         ON CONFLICT(apple_sub) DO NOTHING",
        params![apple_sub, None::<String>, now],
    )
    .map_err(ApiError::internal)?;
    let account_id: i64 = conn
        .query_row(
            "SELECT id FROM account WHERE apple_sub = ?1",
            params![apple_sub],
            |r| r.get(0),
        )
        .map_err(ApiError::internal)?;

    let resp = issue_session(&conn, account_id, now)?;
    Ok(Json(resp))
}

/// Inserts a fresh session for `account_id` and returns its tokens.
fn issue_session(
    conn: &rusqlite::Connection,
    account_id: i64,
    now: i64,
) -> Result<AuthResponse, ApiError> {
    let access_token = new_token();
    let refresh_token = new_token();
    let expires_at = now + SESSION_TTL_SECS;
    conn.execute(
        "INSERT INTO session (account_id, access_hash, refresh_hash, created_at_epoch,
                              expires_at_epoch)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            account_id,
            hash_token(&access_token),
            hash_token(&refresh_token),
            now,
            expires_at
        ],
    )
    .map_err(ApiError::internal)?;
    Ok(AuthResponse {
        account_id,
        access_token,
        refresh_token,
        expires_at_epoch: expires_at,
    })
}

// --- middleware ------------------------------------------------------------

/// Extracts + validates the `Authorization: Bearer` session token, loads the
/// account, and stashes it in the request extensions for downstream handlers.
pub async fn require_auth(
    State(state): State<AppState>,
    mut req: Request,
    next: Next,
) -> Result<Response, ApiError> {
    let token = bearer_token(&req)?;
    let now = state.now_epoch();
    let account = {
        let conn = state.db.lock().map_err(|_| ApiError::internal("db lock"))?;
        let access_hash = hash_token(&token);
        let account_id: Option<i64> = conn
            .query_row(
                "SELECT account_id FROM session
                 WHERE access_hash = ?1 AND expires_at_epoch > ?2",
                params![access_hash, now],
                |r| r.get(0),
            )
            .optional()
            .map_err(ApiError::internal)?;
        let Some(account_id) = account_id else {
            return Err(ApiError::unauthorized(
                "bad_session",
                "invalid or expired session",
            ));
        };
        load_account(&conn, account_id)?
    };

    // Per-token rate limit (simple in-memory token bucket).
    state.check_rate_limit(&token)?;

    req.extensions_mut().insert(account);
    Ok(next.run(req).await)
}

/// Per-IP rate limit for the anonymous `/v1/auth/*` routes (docs/PHASE2.md:
/// server-side rate limiting). These have no bearer token to key the per-token
/// limiter on, yet each does real work (RSA verify / indexed DB lookup), so an
/// unthrottled anonymous caller is a cheap DoS. Runs before the handler.
pub async fn public_auth_rate_limit(
    State(state): State<AppState>,
    req: Request,
    next: Next,
) -> Result<Response, ApiError> {
    let ip = client_ip(&req);
    state.check_auth_ip_rate_limit(&ip)?;
    Ok(next.run(req).await)
}

/// Best-effort client IP. In production the server sits behind Caddy
/// (docs/PHASE2.md), which overwrites `X-Forwarded-For` with the real client —
/// so its first hop is trustworthy. Falls back to the socket peer, then a
/// constant (dev with no proxy → a single coarse bucket, still a backstop).
fn client_ip(req: &Request) -> String {
    if let Some(xff) = req
        .headers()
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
    {
        if let Some(first) = xff.split(',').next() {
            let ip = first.trim();
            if !ip.is_empty() {
                return ip.to_owned();
            }
        }
    }
    if let Some(peer) = req
        .extensions()
        .get::<axum::extract::ConnectInfo<std::net::SocketAddr>>()
    {
        return peer.0.ip().to_string();
    }
    "unknown".to_owned()
}

fn bearer_token(req: &Request) -> Result<String, ApiError> {
    let value = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| ApiError::unauthorized("no_auth", "missing Authorization header"))?;
    let token = value
        .strip_prefix("Bearer ")
        .or_else(|| value.strip_prefix("bearer "))
        .ok_or_else(|| ApiError::unauthorized("no_auth", "expected Bearer token"))?;
    if token.trim().is_empty() {
        return Err(ApiError::unauthorized("no_auth", "empty bearer token"));
    }
    Ok(token.to_owned())
}

pub fn load_account(conn: &rusqlite::Connection, account_id: i64) -> Result<Account, ApiError> {
    conn.query_row(
        "SELECT id, apple_sub, email, active_challenge_id FROM account WHERE id = ?1",
        params![account_id],
        |r| {
            Ok(Account {
                id: r.get(0)?,
                apple_sub: r.get(1)?,
                email: r.get(2)?,
                active_challenge_id: r.get(3)?,
            })
        },
    )
    .optional()
    .map_err(ApiError::internal)?
    .ok_or_else(|| ApiError::unauthorized("bad_session", "account not found"))
}

/// `DELETE /v1/account` — wipes the account and everything owned by it
/// (events, config, sessions, memberships, entitlement). Local data is
/// untouched; this is the App Store account-deletion requirement.
pub async fn delete_account(
    State(state): State<AppState>,
    Extension(account): Extension<Account>,
) -> Result<StatusCode, ApiError> {
    let conn = state.db.lock().map_err(|_| ApiError::internal("db lock"))?;
    // Child rows first (FKs reference account).
    for sql in [
        "DELETE FROM event WHERE account_id = ?1",
        "DELETE FROM config_slot WHERE account_id = ?1",
        "DELETE FROM session WHERE account_id = ?1",
        "DELETE FROM membership WHERE account_id = ?1",
        "DELETE FROM entitlement WHERE account_id = ?1",
        "DELETE FROM account WHERE id = ?1",
    ] {
        conn.execute(sql, params![account.id])
            .map_err(ApiError::internal)?;
    }
    Ok(StatusCode::NO_CONTENT)
}
