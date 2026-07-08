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

    /// Notifies the operator (`to`) that a brand-new account was just created.
    /// `new_account_email` is the signer's email when known (`None` for an Apple
    /// private-relay account that shared no address). Fired best-effort by the
    /// auth handlers — a failure here must never block someone's sign-in — so the
    /// returned error is logged, not surfaced to the caller (docs/specs.md
    /// "Accounts": jacob@stephens.page is emailed on every new Drome account).
    fn send_signup_notification(
        &self,
        to: &str,
        new_account_email: Option<&str>,
    ) -> Result<(), ApiError>;
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

    fn send_signup_notification(
        &self,
        to: &str,
        new_account_email: Option<&str>,
    ) -> Result<(), ApiError> {
        let who = new_account_email.unwrap_or("(no email shared)");
        eprintln!("[signup-notify] new Drome account ({who}) — would notify {to}  (RESEND_API_KEY unset — NOT emailed)");
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

    /// Posts one transactional email to Resend. Shared by every message this
    /// sender delivers so the auth header / endpoint / error handling live in
    /// one place. The provider's response is opaque to the client; on any error
    /// we surface `err_msg` and never leak Resend's body.
    fn post(&self, to: &str, subject: &str, text: &str, html: &str, err_msg: &'static str) -> Result<(), ApiError> {
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
            Err(_) => Err(ApiError::bad_gateway(err_msg)),
        }
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
        self.post(to, &subject, &text, &html, "couldn't send the code — try again")
    }

    fn send_signup_notification(
        &self,
        to: &str,
        new_account_email: Option<&str>,
    ) -> Result<(), ApiError> {
        let who = new_account_email.unwrap_or("(no email shared)");
        let subject = "New Drome account created".to_owned();
        let text = format!("A new Drome account was just created.\n\nEmail: {who}");
        let html = format!(
            "<div style=\"font-family:-apple-system,Segoe UI,Roboto,sans-serif;color:#2b2118\">\
               <p>A new Drome account was just created.</p>\
               <p><strong>Email:</strong> {who}</p>\
             </div>"
        );
        self.post(to, &subject, &text, &html, "couldn't send signup notification")
    }
}
