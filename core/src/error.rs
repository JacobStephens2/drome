/// Crate-wide error type. Crossed to Swift as a flat error (variant + message).
#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum DromeError {
    #[error("database error: {0}")]
    Database(#[from] rusqlite::Error),
    #[error("serialization error: {0}")]
    Serialization(#[from] serde_json::Error),
    #[error("invalid date {0:?}: expected \"YYYY-MM-DD\"")]
    InvalidDate(String),
    #[error("invalid argument: {0}")]
    InvalidArgument(String),
    #[error("no active challenge")]
    NoActiveChallenge,
    #[error("a challenge is already active; import requires a store without one")]
    ActiveChallengeExists,
    #[error("event not found: {0}")]
    EventNotFound(String),
    #[error("unknown extra: {0}")]
    UnknownExtra(String),
    #[error("time value out of representable range")]
    TimeOutOfRange,
    #[error("internal error: {0}")]
    Internal(String),
}

pub type Result<T, E = DromeError> = std::result::Result<T, E>;
