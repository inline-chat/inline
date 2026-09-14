//! Canonical concise copy for provider-neutral bridge states.

use inline_agent_bridge::SessionOpenOutcome;
use inline_client::{ClientErrorCategory, ClientFailure, ClientStatus};

/// Present the useful provider message without dumping its response envelope,
/// credentials, or host paths into a potentially shared conversation.
pub(super) fn failure_message(notice: BridgeNotice, diagnostic: Option<&str>) -> String {
    let summary = match notice {
        BridgeNotice::AgentStartFailed => "I couldn’t start the agent.",
        BridgeNotice::AgentTurnFailed => "The agent couldn’t finish this turn.",
        _ => notice.message(),
    };
    let message = failure_with_diagnostic(summary, diagnostic);
    if message == summary {
        notice.message().to_string()
    } else {
        message
    }
}

pub(super) fn failure_with_diagnostic(summary: &str, diagnostic: Option<&str>) -> String {
    let detail = diagnostic.and_then(|diagnostic| {
        let json = match diagnostic.find('{') {
            Some(start) => {
                Some(serde_json::from_str::<serde_json::Value>(&diagnostic[start..]).ok()?)
            }
            None => None,
        };
        let message = match json.as_ref() {
            Some(value) => value
                .pointer("/error/message")
                .or_else(|| value.get("message"))
                .and_then(serde_json::Value::as_str)?,
            None => diagnostic,
        };
        super::safe_chat_diagnostic(message)
    });
    let Some(detail) = detail else {
        return summary.to_string();
    };
    // Keep the provider's explanation distinct from the bridge's own copy.
    format!("{summary}\n\n> {detail}")
}

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
    SessionActiveElsewhere,
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
            Self::SessionActiveElsewhere => {
                "This Codex session is open in another interface. Close it there, then retry /resume or your message here."
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
    fn provider_failure_exposes_actionable_message_without_response_envelope() {
        let diagnostic = r#"{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'gpt-6-astra' model requires a newer version of Codex. Please upgrade to the latest app or CLI and try again."}}"#;
        let message = failure_message(BridgeNotice::AgentTurnFailed, Some(diagnostic));
        assert!(message.contains("gpt-6-astra"));
        assert!(message.contains("Please upgrade"));
        assert!(!message.contains("invalid_request_error"));
        assert!(!message.contains("/status"));
    }

    #[test]
    fn provider_failure_keeps_generic_copy_for_sensitive_or_missing_details() {
        for diagnostic in [
            None,
            Some(""),
            Some("Authorization: Bearer private"),
            Some("refreshToken=private"),
            Some("apiKey=private"),
            Some("Invalid API key sk-private"),
            Some("failed reading /Users/mo/private.txt"),
            Some("failed reading /users/mo/private.txt"),
            Some("failed reading path:/tmp/private.txt"),
            Some("failed reading '/var/private.txt'"),
            Some(r"failed reading D:\Users\Mo\private.txt"),
            Some(r"failed reading \\host\private.txt"),
            Some("failed reading ~/private.txt"),
            Some("failed reading file:///private.txt"),
            Some("Rejected credential: SK-private"),
            Some("Rejected credential: ghp_private"),
            Some("Rejected credential: github_pat_private"),
            Some("Rejected credential: xoxb-private"),
            Some(r#"{"request":{"prompt":"private"}}"#),
        ] {
            assert_eq!(
                failure_message(BridgeNotice::AgentTurnFailed, diagnostic),
                BridgeNotice::AgentTurnFailed.message()
            );
        }
        let message = failure_message(
            BridgeNotice::AgentStartFailed,
            Some("Quota exceeded. Try again tomorrow."),
        );
        assert!(message.contains("Quota exceeded. Try again tomorrow."));
        let message = failure_message(
            BridgeNotice::AgentStartFailed,
            Some("Sign in again. See https://example.com/help for instructions."),
        );
        assert!(message.contains("https://example.com/help"));
        let message = failure_message(
            BridgeNotice::AgentTurnFailed,
            Some("Codex usage limit reached. Run /status for reset times."),
        );
        assert!(message.contains("Run /status for reset times."));
        let message = failure_message(
            BridgeNotice::AgentTurnFailed,
            Some(
                "Failed to fetch https://user:credential@example.com/file?signature=private-value",
            ),
        );
        assert!(!message.contains("credential"));
        assert!(!message.contains("private-value"));
    }

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
            BridgeNotice::SessionActiveElsewhere,
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
