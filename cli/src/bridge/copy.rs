//! Canonical concise copy for provider-neutral bridge states.

use inline_agent_bridge::SessionOpenOutcome;
use inline_client::{ClientErrorCategory, ClientFailure, ClientStatus};

/// A user-visible bridge state shared by messages, commands, and settings.
// Session replacement, reconnect, and update copy are contract-first: the
// current transport cannot emit each state to chat yet, but keeping their copy
// here prevents later lifecycle work from inventing a second wording path.
#[allow(dead_code)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum BridgeNotice {
    AuthenticationRequired,
    AgentStartFailed,
    AgentTurnFailed,
    AgentConnectionLost,
    SettingsUnavailable,
    TurnTrackingFailed,
    ProviderRestartingQueued,
    MissingWorkspace,
    SessionCompactionUnsupported,
    SessionReplaced,
    InlineReconnecting,
    BridgeUpdateRequired,
}

impl BridgeNotice {
    pub(super) const fn message(self) -> &'static str {
        match self {
            Self::AuthenticationRequired => {
                "Authentication required. Sign in to this agent on the host, then resend the task."
            }
            Self::AgentStartFailed => {
                "I couldn’t start the agent. Run /status for details, then try again."
            }
            Self::AgentTurnFailed => {
                "The agent couldn’t finish this turn. Run /status for details, then try again."
            }
            Self::AgentConnectionLost => {
                "The local agent disconnected and is restarting. Check /status, then resend this task."
            }
            Self::SettingsUnavailable => {
                "I couldn’t load this conversation’s agent settings. Restart the bridge and try again."
            }
            Self::TurnTrackingFailed => {
                "I couldn’t safely track this agent turn, so I stopped it. Restart the bridge and try again."
            }
            Self::ProviderRestartingQueued => {
                "The local agent isn’t ready — I queued this. Run /status for details."
            }
            Self::MissingWorkspace => {
                "The selected project folder is unavailable. Choose another in Agent Settings."
            }
            Self::SessionCompactionUnsupported => {
                "This agent doesn’t support session compaction here."
            }
            Self::SessionReplaced => {
                "The previous agent session was unavailable, so I started a new one."
            }
            Self::InlineReconnecting => {
                "Inline is reconnecting. Accepted work will resume automatically."
            }
            Self::BridgeUpdateRequired => {
                "The local bridge needs an update. Run inline update on the host."
            }
        }
    }
}

/// Selects the one lifecycle notice that must accompany automatic replacement.
pub(super) const fn session_open_notice(outcome: &SessionOpenOutcome) -> Option<BridgeNotice> {
    if outcome.was_replaced() {
        Some(BridgeNotice::SessionReplaced)
    } else {
        None
    }
}

/// Maps typed Inline transport state to concise operator-facing recovery copy.
/// This feeds local status/doctor surfaces; reconnect transitions do not create
/// unsolicited chat messages.
pub(super) const fn inline_client_notice(
    status: ClientStatus,
    failure: Option<&ClientFailure>,
) -> Option<BridgeNotice> {
    if matches!(
        failure,
        Some(ClientFailure {
            category: ClientErrorCategory::ProtocolMismatch,
            ..
        })
    ) {
        return Some(BridgeNotice::BridgeUpdateRequired);
    }
    if matches!(
        failure,
        Some(ClientFailure {
            category: ClientErrorCategory::AuthRequired
                | ClientErrorCategory::AuthExpired
                | ClientErrorCategory::ReloginRequired,
            ..
        })
    ) || matches!(
        status,
        ClientStatus::AuthRequired | ClientStatus::AuthExpired | ClientStatus::LoggedOut
    ) {
        return Some(BridgeNotice::AuthenticationRequired);
    }
    if matches!(
        status,
        ClientStatus::Connecting | ClientStatus::Reconnecting
    ) || matches!(
        failure,
        Some(ClientFailure {
            category: ClientErrorCategory::Network
                | ClientErrorCategory::Timeout
                | ClientErrorCategory::RateLimited,
            ..
        })
    ) {
        return Some(BridgeNotice::InlineReconnecting);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_state_is_concise_and_safe_for_chat() {
        let states = [
            BridgeNotice::AuthenticationRequired,
            BridgeNotice::AgentStartFailed,
            BridgeNotice::AgentTurnFailed,
            BridgeNotice::AgentConnectionLost,
            BridgeNotice::SettingsUnavailable,
            BridgeNotice::TurnTrackingFailed,
            BridgeNotice::ProviderRestartingQueued,
            BridgeNotice::MissingWorkspace,
            BridgeNotice::SessionCompactionUnsupported,
            BridgeNotice::SessionReplaced,
            BridgeNotice::InlineReconnecting,
            BridgeNotice::BridgeUpdateRequired,
        ];
        for state in states {
            let message = state.message();
            assert!(!message.is_empty());
            assert!(message.chars().count() <= 120);
            assert!(!message.contains('\n'));
            assert!(!message.contains("/Users/"));
            assert!(!message.to_ascii_lowercase().contains("token"));
        }
    }

    #[test]
    fn recovery_states_tell_the_user_what_happens_next() {
        assert!(
            BridgeNotice::ProviderRestartingQueued
                .message()
                .contains("queued")
        );
        assert!(
            BridgeNotice::InlineReconnecting
                .message()
                .contains("resume")
        );
        assert!(
            BridgeNotice::AgentConnectionLost
                .message()
                .contains("restarting")
        );
        assert!(
            BridgeNotice::AuthenticationRequired
                .message()
                .contains("Sign in")
        );
    }

    #[test]
    fn unavailable_workspace_copy_describes_the_selected_folder() {
        let message = BridgeNotice::MissingWorkspace.message();
        assert_eq!(
            message,
            "The selected project folder is unavailable. Choose another in Agent Settings."
        );
        assert!(!message.contains("No project folder is available"));
        assert!(!message.contains("/Users/"));
        assert!(!message.to_ascii_lowercase().contains("token"));
    }

    #[test]
    fn only_automatic_session_replacement_selects_an_announcement() {
        use inline_agent_bridge::ProviderSessionId;

        let session = || ProviderSessionId::new("session-1").expect("session");
        for outcome in [
            SessionOpenOutcome::Active(session()),
            SessionOpenOutcome::Created(session()),
            SessionOpenOutcome::Resumed(session()),
        ] {
            assert_eq!(session_open_notice(&outcome), None);
        }
        assert_eq!(
            session_open_notice(&SessionOpenOutcome::Replaced(session())),
            Some(BridgeNotice::SessionReplaced)
        );
    }

    #[test]
    fn inline_transport_states_use_typed_canonical_notices() {
        assert_eq!(
            inline_client_notice(ClientStatus::Reconnecting, None),
            Some(BridgeNotice::InlineReconnecting)
        );
        assert_eq!(
            inline_client_notice(
                ClientStatus::Disconnected,
                Some(&ClientFailure::new(
                    ClientErrorCategory::ProtocolMismatch,
                    "incompatible protocol"
                ))
            ),
            Some(BridgeNotice::BridgeUpdateRequired)
        );
        assert_eq!(
            inline_client_notice(ClientStatus::AuthExpired, None),
            Some(BridgeNotice::AuthenticationRequired)
        );
        assert_eq!(inline_client_notice(ClientStatus::Connected, None), None);
    }
}
