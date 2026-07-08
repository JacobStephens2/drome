//! Transactional email for the email six-digit OTP sign-in (docs/PHASE2.md
//! "Auth"). An `EmailSender` abstraction so the request handler stays provider-
//! agnostic and tests inject a recording sender. Production uses Resend; a
//! server with no `RESEND_API_KEY` falls back to logging the code (a local-dev
//! affordance, warned about at startup — never a real delivery path).

use crate::error::ApiError;

/// Sends the six-digit login code to an email address. Synchronous on purpose:
/// it mirrors the JWKS client (`ureq`, no async runtime), so a handler can call
/// it directly. Errors bubble up so the request handler can tell the user to
/// retry rather than silently drop a code they'll never receive.
pub trait EmailSender: Send + Sync {
    fn send_login_code(&self, to: &str, code: &str) -> Result<(), ApiError>;
}

/// Fallback when `RESEND_API_KEY` is unset: logs the code to stderr instead of
/// emailing, so the flow is still exercisable locally (read the log). Like
/// `DROME_DEV_AUTH`, it is a dev affordance and `main` warns loudly about it.
pub struct LogSender;

impl EmailSender for LogSender {
    fn send_login_code(&self, to: &str, code: &str) -> Result<(), ApiError> {
        eprintln!("[email-otp] login code for {to}: {code}  (RESEND_API_KEY unset — NOT emailed)");
        Ok(())
    }
}

/// Production sender: Resend's transactional email API. Synchronous `ureq`
/// (same client the JWKS fetch uses) so it is safe from an Axum handler without
/// spawning; the code row is written before the send and cleaned up if it fails.
pub struct ResendSender {
    api_key: String,
    /// RFC 5322 From, e.g. `Drome <login@drome.day>`.
    from: String,
}

impl ResendSender {
    pub fn new(api_key: String, from: String) -> Self {
        Self { api_key, from }
    }
}

impl EmailSender for ResendSender {
    fn send_login_code(&self, to: &str, code: &str) -> Result<(), ApiError> {
        let subject = format!("{code} is your Drome sign-in code");
        let text = format!(
            "Your Drome sign-in code is {code}.\n\nIt expires in 10 minutes. \
             If you didn't request it, you can ignore this email."
        );
        let html = format!(
            "<div style=\"font-family:-apple-system,Segoe UI,Roboto,sans-serif;color:#2b2118\">\
               <p>Your Drome sign-in code is:</p>\
               <p style=\"font-size:30px;font-weight:800;letter-spacing:6px;margin:12px 0\">{code}</p>\
               <p style=\"color:#6b5d4d\">It expires in 10 minutes. \
                 If you didn't request it, you can ignore this email.</p>\
             </div>"
        );
        let result = ureq::post("https://api.resend.com/emails")
            .set("Authorization", &format!("Bearer {}", self.api_key))
            .send_json(serde_json::json!({
                "from": self.from,
                "to": [to],
                "subject": subject,
                "text": text,
                "html": html,
            }));
        match result {
            Ok(_) => Ok(()),
            // The provider is opaque to the client; don't leak its response.
            Err(_) => Err(ApiError::bad_gateway("couldn't send the code — try again")),
        }
    }
}
