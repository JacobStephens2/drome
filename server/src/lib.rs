//! drome-server: accounts, sync, groups (docs/PHASE2.md "Server"). Axum +
//! rusqlite (WAL, single writer). Shared event/config wire types and their
//! validation come from `drome-core` (path dependency).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use axum::extract::State;
use axum::middleware::from_fn_with_state;
use axum::routing::{delete, get, post};
use axum::Router;
use rusqlite::Connection;

pub mod auth;
pub mod db;
pub mod email;
pub mod entitlement;
pub mod error;
pub mod groups;
pub mod jwks;
pub mod sync;

use crate::email::{EmailSender, LogSender};
use crate::error::ApiError;
use crate::jwks::AppleVerifier;

/// Injected clock (seconds since epoch), swappable in tests.
pub type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;

/// Simple per-token bucket (docs/PHASE2.md "Rate limiting").
#[derive(Debug, Clone, Copy)]
struct TokenBucket {
    tokens: f64,
    last_refill: i64,
}

const BUCKET_CAPACITY: f64 = 120.0;
const BUCKET_REFILL_PER_SEC: f64 = 4.0;
/// Above this many live buckets, sweep the idle ones on insert so the map can
/// never grow without bound (token rotation would otherwise leak an entry per
/// mint). A bucket idle long enough to have fully refilled is indistinguishable
/// from a fresh one, so dropping it changes no rate-limit outcome.
const BUCKET_SWEEP_THRESHOLD: usize = 4_096;
/// Idle horizon after which a bucket has certainly refilled to capacity
/// (> BUCKET_CAPACITY / BUCKET_REFILL_PER_SEC = 30s); evicting past it is safe.
const BUCKET_IDLE_TTL_SECS: i64 = 120;

/// Anonymous auth surface (`/v1/auth/*`) is throttled per client IP — it has no
/// bearer token yet, and each call does real work (RSA verify / DB lookup).
const AUTH_IP_BUCKET_CAPACITY: f64 = 120.0;
const AUTH_IP_REFILL_PER_SEC: f64 = 4.0;

/// Shared server state (Axum `State`; cheap to clone — everything is `Arc`).
#[derive(Clone)]
pub struct AppState {
    pub db: Arc<Mutex<Connection>>,
    pub verifier: Arc<dyn AppleVerifier>,
    /// Sends email OTP login codes. Defaults to `LogSender` (logs, never sends);
    /// `main` swaps in the Resend sender when `RESEND_API_KEY` is configured.
    pub email_sender: Arc<dyn EmailSender>,
    /// Operator address emailed when a new account is created (docs/specs.md
    /// "Accounts"). `None` disables the notification; `main` defaults it to
    /// jacob@stephens.page (env `DROME_SIGNUP_NOTIFY_TO`, empty = off).
    signup_notify_to: Option<String>,
    pub beta_all_entitled: bool,
    /// Local-dev auth affordance (`POST /v1/auth/dev`). OFF by default so a
    /// default (production) configuration can never mint synthetic sessions;
    /// `main` only flips it on when `DROME_DEV_AUTH=1`. When false the route is
    /// not even mounted (docs/PHASE2.md "Local dev auth (never production)").
    dev_auth: bool,
    clock: Clock,
    buckets: Arc<Mutex<HashMap<String, TokenBucket>>>,
    /// Separate namespace so anonymous-auth throttling never interacts with the
    /// per-token buckets (an IP flood can't evict a real user's bucket).
    auth_ip_buckets: Arc<Mutex<HashMap<String, TokenBucket>>>,
}

impl AppState {
    pub fn new(
        conn: Connection,
        verifier: Arc<dyn AppleVerifier>,
        beta_all_entitled: bool,
    ) -> Self {
        Self {
            db: Arc::new(Mutex::new(conn)),
            verifier,
            email_sender: Arc::new(LogSender),
            signup_notify_to: None,
            beta_all_entitled,
            dev_auth: false,
            clock: Arc::new(system_now),
            buckets: Arc::new(Mutex::new(HashMap::new())),
            auth_ip_buckets: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Overrides the clock (tests only).
    pub fn with_clock(mut self, clock: Clock) -> Self {
        self.clock = clock;
        self
    }

    /// Sets the email OTP sender (`main` injects Resend; tests inject a recorder).
    pub fn with_email_sender(mut self, sender: Arc<dyn EmailSender>) -> Self {
        self.email_sender = sender;
        self
    }

    /// Sets the operator address notified on new-account creation. An empty /
    /// whitespace-only value disables the notification (stored as `None`).
    pub fn with_signup_notify_to(mut self, to: Option<String>) -> Self {
        self.signup_notify_to = to.filter(|s| !s.trim().is_empty());
        self
    }

    /// Best-effort operator notification that a new account was created. Called
    /// by the auth handlers AFTER the session is issued and the DB lock dropped,
    /// so a slow or failing email never delays or breaks someone's sign-in — a
    /// delivery error is logged, not propagated (docs/specs.md "Accounts").
    pub fn notify_signup(&self, new_account_email: Option<&str>) {
        let Some(to) = self.signup_notify_to.as_deref() else {
            return;
        };
        if let Err(e) = self
            .email_sender
            .send_signup_notification(to, new_account_email)
        {
            eprintln!("[signup-notify] failed to email {to}: {e:?}");
        }
    }

    /// Enables the local-dev auth affordance (`POST /v1/auth/dev`). OFF by
    /// default; `main` turns it on ONLY when `DROME_DEV_AUTH=1`, and logs a loud
    /// startup warning. Never enable it in production — it mints real sessions
    /// for synthetic accounts with no Sign-in-with-Apple proof (docs/PHASE2.md
    /// "Local dev auth (never production)").
    pub fn with_dev_auth(mut self, enabled: bool) -> Self {
        self.dev_auth = enabled;
        self
    }

    pub fn now_epoch(&self) -> i64 {
        (self.clock)()
    }

    /// Beta: everyone entitled when `BETA_ALL_ENTITLED`. Otherwise the
    /// entitlement table decides (populated by the RevenueCat webhook later).
    pub fn is_entitled(&self, account_id: i64) -> Result<bool, ApiError> {
        if self.beta_all_entitled {
            return Ok(true);
        }
        let conn = self.db.lock().map_err(|_| ApiError::internal("db lock"))?;
        let active: Option<bool> = conn
            .query_row(
                "SELECT active FROM entitlement WHERE account_id = ?1",
                rusqlite::params![account_id],
                |r| r.get(0),
            )
            .ok();
        Ok(active.unwrap_or(false))
    }

    /// Consumes one token from the caller's per-token bucket; 429 when empty.
    pub fn check_rate_limit(&self, token: &str) -> Result<(), ApiError> {
        let key = auth::hash_token(token);
        consume_token(
            &self.buckets,
            key,
            self.now_epoch(),
            BUCKET_CAPACITY,
            BUCKET_REFILL_PER_SEC,
            "per-token rate limit exceeded",
        )
    }

    /// Consumes one token from `ip`'s anonymous-auth bucket; 429 when empty.
    /// Keyed on the client IP so the unauthenticated `/v1/auth/*` surface has
    /// backpressure independent of the per-token limiter.
    pub fn check_auth_ip_rate_limit(&self, ip: &str) -> Result<(), ApiError> {
        consume_token(
            &self.auth_ip_buckets,
            ip.to_owned(),
            self.now_epoch(),
            AUTH_IP_BUCKET_CAPACITY,
            AUTH_IP_REFILL_PER_SEC,
            "auth rate limit exceeded",
        )
    }
}

/// Shared token-bucket consume: refill by elapsed time, take one token, 429 if
/// empty. Sweeps buckets idle past the refill horizon once the map is large so
/// it stays bounded regardless of how many distinct keys are ever presented.
fn consume_token(
    buckets: &Mutex<HashMap<String, TokenBucket>>,
    key: String,
    now: i64,
    capacity: f64,
    refill_per_sec: f64,
    too_many_msg: &'static str,
) -> Result<(), ApiError> {
    let mut buckets = buckets
        .lock()
        .map_err(|_| ApiError::internal("bucket lock"))?;
    if buckets.len() > BUCKET_SWEEP_THRESHOLD {
        buckets.retain(|_, b| (now - b.last_refill).max(0) <= BUCKET_IDLE_TTL_SECS);
    }
    let bucket = buckets.entry(key).or_insert(TokenBucket {
        tokens: capacity,
        last_refill: now,
    });
    let elapsed = (now - bucket.last_refill).max(0) as f64;
    bucket.tokens = (bucket.tokens + elapsed * refill_per_sec).min(capacity);
    bucket.last_refill = now;
    if bucket.tokens >= 1.0 {
        bucket.tokens -= 1.0;
        Ok(())
    } else {
        Err(ApiError::too_many_requests(too_many_msg))
    }
}

fn system_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Builds the full `/v1` router (docs/PHASE2.md "Endpoints v1"). Auth and
/// entitlement are real middleware; group handlers are 501 stubs this stage.
pub fn build_router(state: AppState) -> Router {
    // Local-dev auth is opt-in; read it before `state` is moved into layers.
    let dev_auth_enabled = state.dev_auth;

    // Sync + groups: authed AND entitlement-gated.
    let gated = Router::new()
        .route("/v1/sync", post(sync::sync_handler))
        .route(
            "/v1/groups",
            post(groups::create_group).get(groups::list_groups),
        )
        .route("/v1/groups/join", post(groups::join_group))
        .route("/v1/groups/:id", get(groups::get_group))
        .route("/v1/groups/:id/leave", post(groups::leave_group))
        .route("/v1/groups/:id/nudge", post(groups::nudge))
        .route("/v1/nudges", get(groups::get_nudges))
        // route_layer order: the LAST layer added is OUTERMOST, so auth runs
        // first (inserting the account), then entitlement reads it.
        .route_layer(from_fn_with_state(
            state.clone(),
            entitlement::require_entitlement,
        ))
        .route_layer(from_fn_with_state(state.clone(), auth::require_auth));

    // Authed but NOT entitlement-gated: reading your own entitlement and
    // deleting your account must work even when a subscription has lapsed.
    let authed = Router::new()
        .route("/v1/entitlement", get(entitlement::get_entitlement))
        .route("/v1/account", delete(auth::delete_account))
        .route("/v1/account/link/code", post(auth::issue_account_link_code))
        .route_layer(from_fn_with_state(state.clone(), auth::require_auth));

    // Anonymous token-minting endpoints: per-IP rate limited (they do real RSA
    // / DB work with no bearer token to key the per-token limiter on).
    let mut public_auth = Router::new()
        .route("/v1/auth/apple", post(auth::apple_auth))
        .route("/v1/auth/email/request", post(auth::email_request))
        .route("/v1/auth/email/verify", post(auth::email_verify))
        .route("/v1/auth/refresh", post(auth::refresh));
    let public_link = Router::new()
        .route("/v1/account/link", post(auth::attach_account_link))
        .route_layer(from_fn_with_state(
            state.clone(),
            auth::public_auth_rate_limit,
        ));
    // `/v1/auth/dev` is mounted ONLY when DROME_DEV_AUTH=1. In a default
    // (production) configuration the route simply does not exist, so it is
    // unreachable (404) — not merely guarded inside the handler.
    if dev_auth_enabled {
        public_auth = public_auth.route("/v1/auth/dev", post(auth::dev_auth));
    }
    let public_auth = public_auth.route_layer(from_fn_with_state(
        state.clone(),
        auth::public_auth_rate_limit,
    ));

    // /healthz is the uptime + deploy probe: never throttled, but it DOES touch
    // the DB so it reports real reachability.
    let public = Router::new().route("/healthz", get(healthz));

    public
        .merge(public_auth)
        .merge(public_link)
        .merge(authed)
        .merge(gated)
        .with_state(state)
}

/// Liveness for the uptime check + deploy gate (docs/PHASE2.md). Actually
/// touches the DB (a static 200 would greenlight a deploy and stay green
/// through a real DB outage — poisoned mutex, wedged WAL, full disk).
async fn healthz(State(state): State<AppState>) -> Result<&'static str, ApiError> {
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::service_unavailable("db lock poisoned"))?;
    conn.query_row("SELECT 1", [], |r| r.get::<_, i64>(0))
        .map_err(|_| ApiError::service_unavailable("db unreachable"))?;
    Ok("ok")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The rate-limit bucket map is bounded: once it crosses the sweep
    /// threshold, buckets idle past the refill horizon are evicted on the next
    /// insert (docs/PHASE2.md rate limiting; a fully-refilled bucket is
    /// indistinguishable from a fresh one, so dropping it changes no outcome).
    /// Without this, token rotation would leak one entry per mint forever.
    #[test]
    fn idle_buckets_are_swept_so_the_map_stays_bounded() {
        let buckets = Mutex::new(HashMap::new());
        // Fill just past the sweep threshold, all stamped at t=0 (idle).
        for i in 0..=BUCKET_SWEEP_THRESHOLD {
            consume_token(
                &buckets,
                format!("key-{i}"),
                0,
                BUCKET_CAPACITY,
                BUCKET_REFILL_PER_SEC,
                "x",
            )
            .expect("first hit always has tokens");
        }
        let before = buckets.lock().unwrap().len();
        assert!(before > BUCKET_SWEEP_THRESHOLD);

        // A fresh key past the idle TTL triggers a sweep of the stale buckets.
        consume_token(
            &buckets,
            "fresh".to_owned(),
            BUCKET_IDLE_TTL_SECS + 1,
            BUCKET_CAPACITY,
            BUCKET_REFILL_PER_SEC,
            "x",
        )
        .expect("fresh key has tokens");
        let after = buckets.lock().unwrap().len();
        assert!(
            after < BUCKET_SWEEP_THRESHOLD,
            "idle buckets must be evicted (was {before}, now {after})"
        );
    }
}
