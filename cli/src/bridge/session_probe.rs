//! One authenticated round trip that settles an ambiguous rejection.
//!
//! A bare HTTP 401/403 or an unconfirmed Inline Protocol 4401 close may only
//! deny one action or ask for a fresh temporary key, so it never parks the
//! bridge by itself. Before parking on one, the bridge connects again with the
//! same credential and asks `GetMe`. Only an explicit revocation from that
//! probe parks; success or anything inconclusive keeps the bridge running.

use super::*;

const SESSION_PROBE_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum SessionProbe {
    /// The credential authenticated and `GetMe` answered.
    Valid,
    /// The server explicitly revoked the session.
    Revoked,
    /// The probe failed for another reason (network, timeout, unknown).
    Inconclusive,
}

pub(super) async fn probe_session(config: &Config, credential: &AuthCredential) -> SessionProbe {
    let legacy_bearer = matches!(credential, AuthCredential::AccessToken { .. });
    let probe = async {
        let mut session =
            crate::owner_session::OwnerSession::connect(config, credential.clone()).await?;
        session.call(proto::GetMeInput {}).await?;
        Ok::<(), Box<dyn std::error::Error>>(())
    };
    let outcome = match tokio::time::timeout(SESSION_PROBE_TIMEOUT, probe).await {
        Ok(Ok(())) => SessionProbe::Valid,
        Ok(Err(error)) => probe_outcome(error.as_ref(), legacy_bearer),
        Err(_) => SessionProbe::Inconclusive,
    };
    log::info!(
        target: "inline::bridge::trace",
        "phase=session_probe outcome={outcome:?} metadata_only=true"
    );
    outcome
}

/// Classifies a failed probe. A bearer probe runs only on the realtime V2
/// transport, where `AuthenticationInvalidated` comes solely from the
/// `INVALID_AUTH` or `SESSION_REVOKED` connection errors. Inline Protocol
/// carriers also produce it for a recoverable close, so it proves nothing
/// there; only a confirmed revocation does.
pub(super) fn probe_outcome(
    error: &(dyn std::error::Error + 'static),
    legacy_bearer: bool,
) -> SessionProbe {
    if classify_failure(error) == FailureClass::NeedsSetup {
        return SessionProbe::Revoked;
    }
    let mut current = Some(error);
    while let Some(error) = current {
        if legacy_bearer
            && matches!(
                error.downcast_ref::<inline_sdk::realtime::RealtimeError>(),
                Some(inline_sdk::realtime::RealtimeError::AuthenticationInvalidated)
            )
        {
            return SessionProbe::Revoked;
        }
        current = error.source();
    }
    SessionProbe::Inconclusive
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_explicit_probe_failures_revoke() {
        assert_eq!(
            probe_outcome(&inline_sdk::InlineProtocolV3Error::SessionRevoked, false),
            SessionProbe::Revoked
        );
        assert_eq!(
            probe_outcome(
                &inline_sdk::InlineProtocolV3Error::AuthorizationInvalidated,
                false
            ),
            SessionProbe::Inconclusive
        );
        let invalidated = inline_sdk::realtime::RealtimeError::AuthenticationInvalidated;
        assert_eq!(probe_outcome(&invalidated, true), SessionProbe::Revoked);
        assert_eq!(
            probe_outcome(&invalidated, false),
            SessionProbe::Inconclusive
        );
        let deactivated = inline_sdk::api::ApiError::Api {
            status: Some(401),
            error: "USER_DEACTIVATED".to_string(),
            error_code: Some(401),
            description: "deleted".to_string(),
        };
        assert_eq!(probe_outcome(&deactivated, true), SessionProbe::Revoked);
        let forbidden = inline_sdk::api::ApiError::Status {
            status: 403,
            message: "Forbidden".to_string(),
            body: None,
        };
        assert_eq!(probe_outcome(&forbidden, true), SessionProbe::Inconclusive);
        assert_eq!(
            probe_outcome(&io::Error::other("connection reset"), true),
            SessionProbe::Inconclusive
        );
    }
}
