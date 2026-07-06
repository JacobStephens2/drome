//! Group endpoints — the router/auth/entitlement plumbing is real, but the
//! handlers are 501 stubs this stage (docs/PHASE2.md "Sequencing": groups are
//! the next stage). The contract lists them so they exist as gated routes.

use crate::error::ApiError;

pub async fn create_group() -> Result<(), ApiError> {
    Err(ApiError::not_implemented("groups land in a later stage"))
}

pub async fn join_group() -> Result<(), ApiError> {
    Err(ApiError::not_implemented("groups land in a later stage"))
}

pub async fn get_group() -> Result<(), ApiError> {
    Err(ApiError::not_implemented("groups land in a later stage"))
}

pub async fn nudge() -> Result<(), ApiError> {
    Err(ApiError::not_implemented("groups land in a later stage"))
}
