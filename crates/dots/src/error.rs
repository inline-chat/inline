//! Error type for the Dots client. Messages never contain tokens, cookies,
//! message text, or full ids.

use std::time::Duration;

/// Result alias for the Dots client.
pub type DotsResult<T> = Result<T, DotsError>;

/// Failures talking to ChatGPT or to the local Codex app-server.
#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum DotsError {
    /// Codex has no usable ChatGPT login.
    #[error("{0}. Run `codex login` (or `codex login --device-auth` on a headless machine).")]
    NotSignedIn(String),
    /// The Codex app-server could not be started or answered unexpectedly.
    #[error("{0}")]
    Codex(String),
    /// The token could not be decoded.
    #[error("ChatGPT token is unusable: {0}")]
    InvalidToken(&'static str),
    /// ChatGPT answered with a non-success status.
    #[error("ChatGPT returned HTTP {status} for {endpoint}{}", detail.as_deref().map(|d| format!(": {d}")).unwrap_or_default())]
    Http {
        /// HTTP status.
        status: u16,
        /// Endpoint template, without ids.
        endpoint: &'static str,
        /// Short server `detail`, when it is a plain string.
        detail: Option<String>,
    },
    /// Cloudflare or a similar edge served a challenge page.
    #[error("ChatGPT served a browser challenge for {endpoint}; the bridge will not work around it")]
    Challenge {
        /// Endpoint template.
        endpoint: &'static str,
    },
    /// ChatGPT rate-limited the bridge.
    #[error("ChatGPT rate-limited {endpoint}")]
    RateLimited {
        /// Endpoint template.
        endpoint: &'static str,
        /// `Retry-After`, when given.
        retry_after: Option<Duration>,
    },
    /// The account has no primary Dot.
    #[error("this ChatGPT account has no Dot yet; create one in the ChatGPT app first")]
    NoPrimaryDot,
    /// A response did not match the expected shape or identity checks.
    #[error("unexpected ChatGPT response: {0}")]
    Protocol(String),
    /// Network failure.
    #[error("network error talking to ChatGPT: {0}")]
    Network(String),
    /// Realtime socket failure.
    #[error("realtime connection failed: {0}")]
    Realtime(String),
    /// A local file or attachment was rejected before upload.
    #[error("{0}")]
    Attachment(String),
}

impl DotsError {
    /// Whether retrying later (with backoff) can succeed without user action.
    pub fn is_transient(&self) -> bool {
        match self {
            Self::Network(_) | Self::Realtime(_) | Self::RateLimited { .. } => true,
            Self::Http { status, .. } => *status >= 500 || *status == 408,
            _ => false,
        }
    }

    /// Whether the user must sign in again (`codex login`).
    pub fn needs_login(&self) -> bool {
        matches!(self, Self::NotSignedIn(_) | Self::InvalidToken(_))
            || matches!(self, Self::Http { status: 401, .. })
    }
}

impl From<reqwest::Error> for DotsError {
    fn from(error: reqwest::Error) -> Self {
        // reqwest errors can carry the request URL, which holds room and
        // message ids. Strip it.
        Self::Network(error.without_url().to_string())
    }
}
