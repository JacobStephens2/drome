//! Shared test scaffolding: an in-process server (mock JWKS), signed Apple
//! identity tokens, and a JSON request helper over `tower::ServiceExt`.

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::Router;
use drome_server::jwks::{Jwk, JwtAppleVerifier, StaticJwksProvider};
use drome_server::{build_router, db, AppState};
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use serde::Serialize;
use serde_json::Value;
use tempfile::TempDir;
use tower::ServiceExt;

pub const TEST_KID: &str = "drome-test-key-1";
pub const AUDIENCE: &str = "day.drome.app";
pub const ISSUER: &str = "https://appleid.apple.com";

/// A throwaway RSA-2048 key (PKCS#1 PEM). Test-only; never used anywhere real.
pub const TEST_RSA_PEM: &str = "-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA3RilSeXB3/lUyB/5WBKsm789noDaDVw6ejgMWfFCGSdgQr00
BUbvOcZiBXyHkDCCgTM4fyTntQHOeW/e4HoTAJfpXCI7xiKyK5uUZ57EgJXbdX/p
31E7g8CadW3/skPrSZ8gLjAHSvpaEMFMGzbEgTSEZEat/fLgh9clIzXY5+ZVgKPh
I/VnkODA3xe1hFs+p1wo/qeAIKYrRzMsS2ea1ZRTz0GVqYTMzxwpVepijVtlHGhL
TEUSuYKtCigJz336zJJg82Ty3qDrGxWPc18ej6687GV72rFLTHqFvPioE6AlQp9N
HMNBvnDXfTpy99fF3UoVGMcuvs+3JnM0AGw9OwIDAQABAoIBAQCAwPp4l1EY8mTa
Ciy1imJ0bKEgrd7NyvjO9dbThfi9Fz4qf25M6Gsl1Q5+LW/wmx9UyBRNjptUwJGS
DIDZbp2kSdL+8XynvMrPNFHvKfk6/IoJ2gzDHNYwurf4TK+MC5t4iy89VoDYvAQ5
H6gHbRRwPboffz2R1p/E25hn8dK38EiUxz+c/FqMJBnfkOY7yh4Jl0/Ko6Recktp
c0fzfMGHIIw2/1sXjh8mkxPoqhT0flBJdzDGVIDoqMHW7GXLNP1uswBdLosus82k
OiliP3ruWzsO1SinVVGlOE0ZXenWBrmbaz6FYZjZiJopBu9q3/i0++Jem91w9Y2W
P9ZpReSJAoGBAPJQcKqCJq891yZSr03YjkqQJ6kgKDOg9LrsaxwUCDBi4K3Xmg/8
KooHopJ1pCRH9RwkdjSVHYA2cPIbGmLad7wX7giql010//mnFga+05FegkQsxZbC
ihJdLrteILvVuOGkaqIbCljCsHPTeN21Rx1SZRUrLurpZ2KFjbg9K6d3AoGBAOmV
a67cDrpp8lyC0vOhMza6IF+vkumBd1nb0C1PKQXYtJrvromwYFcLlWV0kZLN+TuB
9CcxXFBAh+xs7AqtO7APuR/8PD9K7XSuxAu+lK312zYsjLwBm9fIhOQjFZXjFy4I
FomOz8ZwEt6T6kvAXZ2OPNrigV8HI3qaKm15epFdAoGAOAmKRKRcteIjQ2WTzPjr
zyqPQXmCUo5CiofqLVAkpKv5MbrOkivK2qjxW9WA5DMP6DY2b+qcK+5rKFJEQ+Aq
GIGgNrjczLjmCaIuYdj3rIKitYl1GGxc6epKyGH4R/ghDW2si1idh/FeRSr+pKcr
jwhjAAZAj2ry0cH5CEZ9NfkCgYA1dIJ+M9ITCyfxz+ai5qMnxRSfkTiXw48iu1E6
7UDAG8XJJ0zUKc8CXJ5F55Vg+U4uNiE/zuYHX507l/m0v8xHEHIXRcwr1+Pbrhsj
bOvtm7QdA7j5VYzqpvLymqzX7m5hlGxD8rDOAtvun/8gctd5tRFsLiXZL3MJHbrT
7tcD6QKBgH5LEMKE1zOKHv4SItVdEyywtWF5tLJE1gL9OxVodAbaQdO4hIIpBi28
7h8VqJbG3tWgx5wnf1/Tl/GH6qJU2C9l4EaOUlz+OGO4YL8/SniwaAS9GiIIDktz
zYwwn4ilGEC1BScHwA1oB8fpD1ZFAEWgiKSXpFjgp8J+1gD/Gi6J
-----END RSA PRIVATE KEY-----";

/// The matching public key, in JWKS `n`/`e` (base64url) form.
pub fn test_jwk() -> Jwk {
    Jwk {
        kid: TEST_KID.to_owned(),
        n: "3RilSeXB3_lUyB_5WBKsm789noDaDVw6ejgMWfFCGSdgQr00BUbvOcZiBXyHkDCCgTM4fyTntQHOeW_e4HoTAJfpXCI7xiKyK5uUZ57EgJXbdX_p31E7g8CadW3_skPrSZ8gLjAHSvpaEMFMGzbEgTSEZEat_fLgh9clIzXY5-ZVgKPhI_VnkODA3xe1hFs-p1wo_qeAIKYrRzMsS2ea1ZRTz0GVqYTMzxwpVepijVtlHGhLTEUSuYKtCigJz336zJJg82Ty3qDrGxWPc18ej6687GV72rFLTHqFvPioE6AlQp9NHMNBvnDXfTpy99fF3UoVGMcuvs-3JnM0AGw9Ow".to_owned(),
        e: "AQAB".to_owned(),
    }
}

#[derive(Serialize)]
struct AppleClaims {
    sub: String,
    aud: String,
    iss: String,
    exp: i64,
    iat: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    email: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    nonce: Option<String>,
}

/// Signs an Apple-style identity token with the test key.
pub fn sign_token(sub: &str, aud: &str, iss: &str, exp_offset_secs: i64) -> String {
    sign_token_with_nonce(sub, aud, iss, exp_offset_secs, None)
}

/// Signs an Apple-style identity token that carries a `nonce` claim (the
/// `sha256(raw_nonce)` hex a real SIWA flow would embed). `nonce = None` omits
/// the claim entirely (legacy tokens).
pub fn sign_token_with_nonce(
    sub: &str,
    aud: &str,
    iss: &str,
    exp_offset_secs: i64,
    nonce: Option<&str>,
) -> String {
    let now = now_epoch();
    let claims = AppleClaims {
        sub: sub.to_owned(),
        aud: aud.to_owned(),
        iss: iss.to_owned(),
        exp: now + exp_offset_secs,
        iat: now,
        email: Some(format!("{sub}@privaterelay.appleid.com")),
        nonce: nonce.map(str::to_owned),
    };
    let mut header = Header::new(Algorithm::RS256);
    header.kid = Some(TEST_KID.to_owned());
    let key = EncodingKey::from_rsa_pem(TEST_RSA_PEM.as_bytes()).expect("encoding key");
    encode(&header, &claims, &key).expect("sign token")
}

/// A valid, non-expired identity token for `sub`.
pub fn valid_token(sub: &str) -> String {
    sign_token(sub, AUDIENCE, ISSUER, 3_600)
}

pub fn now_epoch() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// A server with a mock-JWKS verifier and its own temp DB.
pub struct TestServer {
    pub app: Router,
    pub state: AppState,
    _dir: TempDir,
}

pub fn test_server(beta_all_entitled: bool) -> TestServer {
    test_server_opts(beta_all_entitled, false)
}

/// Like `test_server` but with the local-dev auth affordance
/// (`POST /v1/auth/dev`) toggleable, mirroring `DROME_DEV_AUTH=1` in `main`.
pub fn test_server_opts(beta_all_entitled: bool, dev_auth: bool) -> TestServer {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir
        .path()
        .join("server.sqlite")
        .to_string_lossy()
        .into_owned();
    let conn = db::open(&path).expect("open server db");
    let provider = StaticJwksProvider {
        keys: vec![test_jwk()],
    };
    let verifier = JwtAppleVerifier::new(Box::new(provider), AUDIENCE);
    let state = AppState::new(conn, Arc::new(verifier), beta_all_entitled).with_dev_auth(dev_auth);
    let app = build_router(state.clone());
    TestServer {
        app,
        state,
        _dir: dir,
    }
}

/// Fires one JSON request carrying an `X-Forwarded-For` (the source the server
/// keys anonymous-auth rate limiting on behind Caddy). Always POST, no bearer.
pub async fn json_request_xff(
    app: &Router,
    uri: &str,
    xff: &str,
    body: Value,
) -> (StatusCode, Value) {
    let request = Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .header("x-forwarded-for", xff)
        .body(Body::from(serde_json::to_vec(&body).expect("body json")))
        .expect("build request");
    let response = app
        .clone()
        .oneshot(request)
        .await
        .expect("oneshot response");
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), 4 * 1024 * 1024)
        .await
        .expect("read body");
    let value = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap_or(Value::Null)
    };
    (status, value)
}

/// Fires one JSON request at the app and returns (status, parsed JSON body).
pub async fn json_request(
    app: &Router,
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Value,
) -> (StatusCode, Value) {
    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json");
    if let Some(t) = token {
        builder = builder.header("authorization", format!("Bearer {t}"));
    }
    let request = builder
        .body(Body::from(serde_json::to_vec(&body).expect("body json")))
        .expect("build request");
    let response = app
        .clone()
        .oneshot(request)
        .await
        .expect("oneshot response");
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), 4 * 1024 * 1024)
        .await
        .expect("read body");
    let value = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap_or(Value::Null)
    };
    (status, value)
}
