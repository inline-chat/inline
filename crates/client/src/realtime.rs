//! Realtime connector boundary.
//!
//! The full client will own a long-lived realtime manager. This module starts
//! with the smaller production seam needed by hosts: a connector that can
//! validate credentials and establish the SDK realtime protocol handshake, plus
//! a fake connector for deterministic tests.

use std::{
    fmt,
    sync::{Arc, Mutex},
};

use futures_util::future::BoxFuture;
use inline_sdk::{ClientIdentity, RealtimeClient, RealtimeError};

use crate::{AuthToken, BackendError, BackendResult, ClientErrorCategory};

/// Realtime handshake input.
#[derive(Clone, PartialEq, Eq)]
pub struct RealtimeConnectRequest {
    realtime_url: String,
    auth_token: AuthToken,
    identity: ClientIdentity,
}

impl RealtimeConnectRequest {
    /// Creates a realtime connect request.
    pub fn new(
        realtime_url: impl Into<String>,
        auth_token: AuthToken,
        identity: ClientIdentity,
    ) -> Self {
        Self {
            realtime_url: realtime_url.into(),
            auth_token,
            identity,
        }
    }

    /// Returns the realtime URL.
    pub fn realtime_url(&self) -> &str {
        &self.realtime_url
    }

    /// Returns the auth token.
    pub fn auth_token(&self) -> &AuthToken {
        &self.auth_token
    }

    /// Returns the client identity.
    pub fn identity(&self) -> &ClientIdentity {
        &self.identity
    }
}

impl fmt::Debug for RealtimeConnectRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RealtimeConnectRequest")
            .field("realtime_url", &redacted_url_for_debug(&self.realtime_url))
            .field("auth_token", &"[redacted]")
            .field("identity", &self.identity)
            .finish()
    }
}

/// Successful realtime connection summary.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RealtimeConnectionInfo {
    /// Realtime URL that was connected.
    pub realtime_url: String,
    /// Client identity used for the handshake.
    pub identity: ClientIdentity,
}

impl RealtimeConnectionInfo {
    /// Creates connection info.
    pub fn new(realtime_url: impl Into<String>, identity: ClientIdentity) -> Self {
        Self {
            realtime_url: realtime_url.into(),
            identity,
        }
    }
}

/// Realtime connector trait.
pub trait RealtimeConnector: fmt::Debug + Send + Sync + 'static {
    /// Establishes a realtime protocol handshake.
    fn connect(
        &self,
        request: RealtimeConnectRequest,
    ) -> BoxFuture<'static, BackendResult<RealtimeConnectionInfo>>;
}

/// SDK-backed realtime connector.
#[derive(Clone, Debug, Default)]
pub struct SdkRealtimeConnector;

impl SdkRealtimeConnector {
    /// Creates a new SDK realtime connector.
    pub fn new() -> Self {
        Self
    }
}

impl RealtimeConnector for SdkRealtimeConnector {
    fn connect(
        &self,
        request: RealtimeConnectRequest,
    ) -> BoxFuture<'static, BackendResult<RealtimeConnectionInfo>> {
        Box::pin(async move {
            let identity = request.identity;
            let realtime_url = request.realtime_url;
            let token = request.auth_token;
            let debug_url = redacted_url_for_debug(&realtime_url);
            log::debug!(
                "connecting Inline realtime transport at {debug_url} as {}",
                identity.client_type()
            );
            let _client = RealtimeClient::connect_with_identity(
                &realtime_url,
                token.expose_secret(),
                identity.clone(),
            )
            .await
            .map_err(realtime_error_to_backend)?;
            log::debug!("Inline realtime transport handshake completed");
            Ok(RealtimeConnectionInfo::new(realtime_url, identity))
        })
    }
}

/// Fake realtime connector for tests.
#[derive(Clone, Debug, Default)]
pub struct FakeRealtimeConnector {
    state: Arc<Mutex<FakeRealtimeState>>,
}

#[derive(Clone, Debug, Default)]
struct FakeRealtimeState {
    attempts: Vec<FakeRealtimeAttempt>,
    failure: Option<BackendError>,
}

/// Redacted fake realtime connect attempt.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FakeRealtimeAttempt {
    /// Realtime URL used for the attempt.
    pub realtime_url: String,
    /// Client identity used for the attempt.
    pub identity: ClientIdentity,
}

impl FakeRealtimeConnector {
    /// Creates a fake connector that succeeds.
    pub fn new() -> Self {
        Self::default()
    }

    /// Creates a fake connector that fails with the provided error.
    pub fn failing(error: BackendError) -> Self {
        Self {
            state: Arc::new(Mutex::new(FakeRealtimeState {
                attempts: Vec::new(),
                failure: Some(error),
            })),
        }
    }

    /// Returns all redacted connection attempts.
    pub fn attempts(&self) -> Vec<FakeRealtimeAttempt> {
        self.state
            .lock()
            .expect("fake realtime connector poisoned")
            .attempts
            .clone()
    }
}

impl RealtimeConnector for FakeRealtimeConnector {
    fn connect(
        &self,
        request: RealtimeConnectRequest,
    ) -> BoxFuture<'static, BackendResult<RealtimeConnectionInfo>> {
        let connector = self.clone();
        Box::pin(async move {
            let mut state = connector
                .state
                .lock()
                .expect("fake realtime connector poisoned");
            state.attempts.push(FakeRealtimeAttempt {
                realtime_url: request.realtime_url.clone(),
                identity: request.identity.clone(),
            });
            if let Some(error) = state.failure.clone() {
                return Err(error);
            }
            Ok(RealtimeConnectionInfo::new(
                request.realtime_url,
                request.identity,
            ))
        })
    }
}

fn realtime_error_to_backend(error: RealtimeError) -> BackendError {
    match error {
        RealtimeError::InvalidUrl { message, .. } => {
            BackendError::new(ClientErrorCategory::InvalidInput, message)
        }
        RealtimeError::Timeout { .. } => {
            BackendError::new(ClientErrorCategory::Timeout, error.to_string())
        }
        RealtimeError::ConnectionError { .. } | RealtimeError::RpcError { .. } => {
            BackendError::new(ClientErrorCategory::AuthExpired, error.to_string())
        }
        RealtimeError::ConnectionClosed | RealtimeError::WebSocket(_) => {
            BackendError::new(ClientErrorCategory::Network, error.to_string())
        }
        RealtimeError::InvalidHeaderValue { .. }
        | RealtimeError::Protocol(_)
        | RealtimeError::MissingResult
        | RealtimeError::UnexpectedResult { .. } => {
            BackendError::new(ClientErrorCategory::ProtocolMismatch, error.to_string())
        }
        _ => BackendError::new(ClientErrorCategory::Internal, error.to_string()),
    }
}

pub(crate) fn redacted_url_for_debug(url: &str) -> String {
    let without_fragment = url.split('#').next().unwrap_or(url);
    let without_query = without_fragment
        .split('?')
        .next()
        .unwrap_or(without_fragment);
    match without_query.split_once("://") {
        Some((scheme, rest)) => {
            let host_and_path = rest.rsplit_once('@').map_or(rest, |(_, tail)| tail);
            format!("{scheme}://{host_and_path}")
        }
        None => without_query.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn realtime_connect_request_debug_redacts_token_and_url_credentials() {
        let request = RealtimeConnectRequest::new(
            "wss://user:secret@api.inline.chat/realtime?token=secret#frag",
            AuthToken::try_new("secret-token").unwrap(),
            ClientIdentity::new("test", "0.1.0"),
        );

        let rendered = format!("{request:?}");
        assert!(rendered.contains("wss://api.inline.chat/realtime"));
        assert!(!rendered.contains("secret-token"));
        assert!(!rendered.contains("token="));
    }

    #[tokio::test]
    async fn fake_realtime_connector_records_redacted_attempts() {
        let connector = FakeRealtimeConnector::new();
        let request = RealtimeConnectRequest::new(
            "wss://api.inline.chat/realtime",
            AuthToken::try_new("secret-token").unwrap(),
            ClientIdentity::new("test", "0.1.0"),
        );

        let info = connector.connect(request).await.unwrap();

        assert_eq!(info.realtime_url, "wss://api.inline.chat/realtime");
        let attempts = connector.attempts();
        assert_eq!(attempts.len(), 1);
        assert_eq!(attempts[0].identity.client_type(), "test");
    }

    #[tokio::test]
    async fn fake_realtime_connector_can_fail() {
        let connector = FakeRealtimeConnector::failing(BackendError::new(
            ClientErrorCategory::Network,
            "offline",
        ));
        let request = RealtimeConnectRequest::new(
            "wss://api.inline.chat/realtime",
            AuthToken::try_new("secret-token").unwrap(),
            ClientIdentity::new("test", "0.1.0"),
        );

        let error = connector.connect(request).await.unwrap_err();

        assert_eq!(error.category, ClientErrorCategory::Network);
    }
}
