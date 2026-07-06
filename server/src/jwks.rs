//! Apple identity-token verification (docs/PHASE2.md "Auth"): verify the
//! Sign-in-with-Apple JWT against Apple's JWKS (aud = day.drome.app, iss =
//! appleid.apple.com), extract the stable `sub`.
//!
//! The JWKS source is a trait so tests inject a mock key set and exercise the
//! REAL verification path (signature, audience, issuer, expiry) — the only
//! thing mocked is where the public keys come from.

use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use jsonwebtoken::{decode, decode_header, Algorithm, DecodingKey, Validation};
use serde::Deserialize;

use crate::error::ApiError;

pub const APPLE_JWKS_URL: &str = "https://appleid.apple.com/auth/keys";
pub const APPLE_ISSUER: &str = "https://appleid.apple.com";
pub const APPLE_AUDIENCE: &str = "day.drome.app";

/// One RSA public key from a JWKS document (`n`/`e` are base64url, exactly the
/// form `DecodingKey::from_rsa_components` wants).
#[derive(Debug, Clone, Deserialize)]
pub struct Jwk {
    pub kid: String,
    pub n: String,
    pub e: String,
}

#[derive(Debug, Deserialize)]
struct JwkSet {
    keys: Vec<Jwk>,
}

/// The identity a verified token resolves to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedIdentity {
    pub sub: String,
    pub email: Option<String>,
    /// The token's `nonce` claim, if present (Apple echoes back the
    /// `sha256(raw_nonce)` hex the client sent it). The auth handler binds this
    /// against the client-supplied raw nonce before issuing a session — replay
    /// protection (docs/PHASE2.md "Auth"). `None` for legacy tokens minted
    /// without a nonce.
    pub nonce: Option<String>,
}

/// Where the verifier gets its public keys. Injected as a trait so tests can
/// supply a mock JWKS without a network call.
pub trait JwksProvider: Send + Sync {
    fn keys(&self) -> Result<Vec<Jwk>, ApiError>;
}

/// The token verifier. Object-safe so `AppState` can hold `Arc<dyn ...>` and
/// tests swap in a mock-JWKS-backed instance.
pub trait AppleVerifier: Send + Sync {
    fn verify(&self, token: &str) -> Result<VerifiedIdentity, ApiError>;
}

#[derive(Deserialize)]
struct AppleClaims {
    sub: String,
    #[serde(default)]
    email: Option<String>,
    /// Replay-binding nonce: `sha256(raw_nonce)` hex the client handed Apple.
    /// Verified against the raw nonce in the auth handler, not here.
    #[serde(default)]
    nonce: Option<String>,
    // `aud`, `iss`, `exp` are validated by jsonwebtoken from the Validation
    // config; declared here only so deserialization does not choke.
    #[allow(dead_code)]
    #[serde(default)]
    exp: usize,
}

/// The real RS256 verifier: pulls keys from a `JwksProvider`, checks the
/// signature, audience, issuer, and expiry.
pub struct JwtAppleVerifier {
    provider: Box<dyn JwksProvider>,
    audience: String,
    issuer: String,
}

impl JwtAppleVerifier {
    pub fn new(provider: Box<dyn JwksProvider>, audience: impl Into<String>) -> Self {
        Self {
            provider,
            audience: audience.into(),
            issuer: APPLE_ISSUER.to_owned(),
        }
    }

    /// Apple-defaults verifier used in production (fetches + caches the real
    /// JWKS, aud = day.drome.app).
    pub fn apple() -> Self {
        Self::new(
            Box::new(AppleJwksProvider::new(APPLE_JWKS_URL)),
            APPLE_AUDIENCE,
        )
    }
}

impl AppleVerifier for JwtAppleVerifier {
    fn verify(&self, token: &str) -> Result<VerifiedIdentity, ApiError> {
        let header = decode_header(token)
            .map_err(|_| ApiError::unauthorized("bad_token", "malformed token"))?;
        let kid = header
            .kid
            .ok_or_else(|| ApiError::unauthorized("bad_token", "token missing kid"))?;
        let key = self
            .provider
            .keys()?
            .into_iter()
            .find(|k| k.kid == kid)
            .ok_or_else(|| ApiError::unauthorized("unknown_key", "no JWKS key for token kid"))?;
        let decoding = DecodingKey::from_rsa_components(&key.n, &key.e)
            .map_err(|_| ApiError::unauthorized("bad_key", "malformed JWKS key"))?;

        let mut validation = Validation::new(Algorithm::RS256);
        validation.set_audience(&[self.audience.as_str()]);
        validation.set_issuer(&[self.issuer.as_str()]);
        // exp is validated by default; require it to be present.
        validation.set_required_spec_claims(&["exp", "aud", "iss"]);

        let data = decode::<AppleClaims>(token, &decoding, &validation).map_err(map_jwt_error)?;
        Ok(VerifiedIdentity {
            sub: data.claims.sub,
            email: data.claims.email,
            nonce: data.claims.nonce,
        })
    }
}

fn map_jwt_error(err: jsonwebtoken::errors::Error) -> ApiError {
    use jsonwebtoken::errors::ErrorKind;
    match err.kind() {
        ErrorKind::ExpiredSignature => {
            ApiError::unauthorized("token_expired", "identity token expired")
        }
        ErrorKind::InvalidAudience => {
            ApiError::unauthorized("bad_audience", "identity token audience mismatch")
        }
        ErrorKind::InvalidIssuer => {
            ApiError::unauthorized("bad_issuer", "identity token issuer mismatch")
        }
        _ => ApiError::unauthorized("bad_token", "identity token verification failed"),
    }
}

/// Production JWKS provider: fetches Apple's key set over HTTPS and caches it
/// for `ttl`. Uses `ureq` (a synchronous client with no async runtime, so it
/// is safe to call from inside an Axum handler). Never exercised by tests.
pub struct AppleJwksProvider {
    url: String,
    ttl: Duration,
    cache: Mutex<Option<(u64, Vec<Jwk>)>>,
}

impl AppleJwksProvider {
    pub fn new(url: impl Into<String>) -> Self {
        Self {
            url: url.into(),
            ttl: Duration::from_secs(3_600),
            cache: Mutex::new(None),
        }
    }
}

impl JwksProvider for AppleJwksProvider {
    fn keys(&self) -> Result<Vec<Jwk>, ApiError> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        if let Ok(guard) = self.cache.lock() {
            if let Some((fetched_at, keys)) = guard.as_ref() {
                if now.saturating_sub(*fetched_at) < self.ttl.as_secs() {
                    return Ok(keys.clone());
                }
            }
        }
        let set: JwkSet = ureq::get(&self.url)
            .call()
            .map_err(|_| ApiError::internal("jwks fetch failed"))?
            .into_json()
            .map_err(|_| ApiError::internal("jwks parse failed"))?;
        if let Ok(mut guard) = self.cache.lock() {
            *guard = Some((now, set.keys.clone()));
        }
        Ok(set.keys)
    }
}

/// Test/dev JWKS provider backed by a fixed key set.
pub struct StaticJwksProvider {
    pub keys: Vec<Jwk>,
}

impl JwksProvider for StaticJwksProvider {
    fn keys(&self) -> Result<Vec<Jwk>, ApiError> {
        Ok(self.keys.clone())
    }
}
