//! Identities used by the session contract.
//!
//! Every native identifier is kept verbatim. The newtypes only bound length and
//! reject control characters, so a journal or fixture written by one bridge
//! version decodes in the next one.

use std::fmt;

use serde::{Deserialize, Deserializer, Serialize};

use crate::{ProviderId, ProviderSessionId};

/// Longest native identifier accepted by the contract, in bytes.
pub const MAX_CONTRACT_ID_BYTES: usize = 1024;

/// A native or Inline identifier was blank, too long, or contained control characters.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
#[error("{kind} must be nonblank, single-line, and at most {MAX_CONTRACT_ID_BYTES} bytes")]
pub struct InvalidContractId {
    kind: &'static str,
}

macro_rules! contract_id {
    ($(#[$meta:meta])* $name:ident, $kind:literal) => {
        $(#[$meta])*
        #[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            /// Validates and wraps one identifier.
            pub fn new(value: impl Into<String>) -> Result<Self, InvalidContractId> {
                let value = value.into();
                if value.trim().is_empty()
                    || value.len() > MAX_CONTRACT_ID_BYTES
                    || value.chars().any(char::is_control)
                {
                    return Err(InvalidContractId { kind: $kind });
                }
                Ok(Self(value))
            }

            /// The identifier exactly as received.
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(&self.0)
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: Deserializer<'de>,
            {
                Self::new(String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
            }
        }
    };
}

contract_id!(
    /// Inline-assigned identity of one input. Drivers echo it in receipts,
    /// queue entries and consumption facts so delivery can be reconciled.
    InputId,
    "input id"
);
contract_id!(
    /// Native item identity (Codex item id, Claude message or content-block id).
    ItemId,
    "item id"
);
contract_id!(
    /// Native identity of a pending approval, question or dialog.
    InteractionId,
    "interaction id"
);
contract_id!(
    /// Opaque identity of one advertised decision within an approval.
    DecisionId,
    "decision id"
);
contract_id!(
    /// Identity of one field in a question form.
    FieldId,
    "field id"
);
contract_id!(
    /// Native identity of a sub-agent, background task or child thread.
    ChildId,
    "child id"
);
contract_id!(
    /// Native identity of a queued input entry.
    QueueEntryId,
    "queue entry id"
);
contract_id!(
    /// Native collaboration or plan mode identity.
    ModeId,
    "mode id"
);

/// An Inline user (human or bot) identity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct UserId(pub i64);

/// An Inline chat (thread, DM or subthread) identity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ChatId(pub i64);

/// One agent's work: its canonical chat and, when known, its native session.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct WorkRef {
    /// The chat the work publishes to.
    pub chat: ChatId,
    /// Native session of the work, when the sender knows it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<ProviderSessionId>,
}

/// What kind of native child a [`ChildRef`] names.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChildKind {
    /// A sub-agent (Codex collab agent thread, Claude Task subagent).
    Subagent,
    /// A background task or terminal (Claude background Bash, Codex background terminal).
    BackgroundTask,
    /// A kind this bridge does not know yet.
    #[serde(other)]
    Unknown,
}

/// A native child of a session. Control goes through the parent, as in the harness.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ChildRef {
    /// Native child identity.
    pub id: ChildId,
    /// Child category.
    pub kind: ChildKind,
}

/// Stable key of one native session stream: provider plus native session id.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct SessionKey {
    /// Provider that owns the session (`codex`, `claude`, ...).
    pub provider: ProviderId,
    /// Native session id (Codex thread id, Claude session id).
    pub session: ProviderSessionId,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_reject_blank_control_and_oversized_values_even_when_deserialized() {
        assert!(InputId::new("  ").is_err());
        assert!(ItemId::new("a\nb").is_err());
        assert!(DecisionId::new("x".repeat(MAX_CONTRACT_ID_BYTES + 1)).is_err());
        assert!(serde_json::from_str::<InteractionId>("\"\"").is_err());
        let id: InteractionId = serde_json::from_str("\"approval-1\"").expect("valid id");
        assert_eq!(id.as_str(), "approval-1");
    }

    #[test]
    fn unknown_child_kinds_decode_as_unknown() {
        let child: ChildRef =
            serde_json::from_str(r#"{"id":"task-1","kind":"cron_job"}"#).expect("child");
        assert_eq!(child.kind, ChildKind::Unknown);
    }
}
