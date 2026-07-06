//! Entitlement gate (docs/PHASE2.md "Entitlements"). During beta the
//! `BETA_ALL_ENTITLED` env grants everyone; the check and the client-facing
//! "subscription required" surface exist from day one but never fire. A
//! lapsed subscription pauses sync/groups only — never the local app.

use axum::extract::{Request, State};
use axum::middleware::Next;
use axum::response::Response;
use axum::Json;
use serde_json::json;

use crate::auth::Account;
use crate::error::ApiError;
use crate::AppState;

/// `GET /v1/entitlement` — the client reads its own entitlement even when not
/// entitled (this route is NOT itself gated).
pub async fn get_entitlement(
    State(state): State<AppState>,
    req: Request,
) -> Result<Json<serde_json::Value>, ApiError> {
    let account = account_from(&req)?;
    let entitled = state.is_entitled(account.id)?;
    Ok(Json(json!({
        "entitled": entitled,
        "beta_all_entitled": state.beta_all_entitled,
    })))
}

/// Middleware gating sync/group routes. Runs AFTER `require_auth`, so the
/// account is already in the request extensions.
pub async fn require_entitlement(
    State(state): State<AppState>,
    req: Request,
    next: Next,
) -> Result<Response, ApiError> {
    let account = account_from(&req)?;
    if state.is_entitled(account.id)? {
        Ok(next.run(req).await)
    } else {
        Err(ApiError::payment_required(
            "an active subscription is required for sync",
        ))
    }
}

fn account_from(req: &Request) -> Result<Account, ApiError> {
    req.extensions()
        .get::<Account>()
        .cloned()
        .ok_or_else(|| ApiError::internal("entitlement middleware ran before auth"))
}
