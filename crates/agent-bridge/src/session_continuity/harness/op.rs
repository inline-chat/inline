//! Typed operations on a live session (spec §4.2 `Op`).
//!
//! Inline slash commands map to these operations with the provider's own
//! meaning. An operation the harness lacks is reported as unavailable with a
//! reason, never sent as a plain prompt.

use std::fmt;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{
    Availability, ChildRef, DecisionId, FieldId, InputId, InteractionId, ItemId, ModeId,
    QueueEntryId, UserId,
};
use crate::{DriverError, TurnId};

/// One operation on a session.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Op {
    /// The harness's stop (Codex `turn/interrupt`, Claude `interrupt`).
    /// `cancel_queued` follows Claude's `cancelQueued`; Codex keeps its queue.
    Interrupt {
        /// Also cancel queued input, where the harness supports it.
        #[serde(default)]
        cancel_queued: bool,
    },
    /// Act on the native queue.
    Queue {
        /// The queue action.
        action: QueueOp,
    },
    /// Change settings with an explicit scope.
    Settings {
        /// Settings to change; `None` fields stay as they are.
        change: SettingsChange,
        /// How long the change lasts.
        scope: SettingsScope,
    },
    /// Compact the session context (Codex `thread/compact/start`, Claude `/compact`).
    Compact,
    /// Rename the native session (Codex `thread/name/set`, Claude `renameSession`).
    Rename {
        /// New title.
        title: String,
    },
    /// Archive where the harness has an archive (Codex `thread/archive`).
    Archive,
    /// Undo [`Op::Archive`] (Codex `thread/unarchive`).
    Unarchive,
    /// Clear the conversation context, where the harness has one.
    Clear,
    /// Restore files to a checkpoint (Claude `rewind_files`, Codex `thread/revert`).
    RewindFiles {
        /// The point to rewind to.
        to: RewindPoint,
    },
    /// Switch collaboration or plan mode.
    Mode {
        /// Native mode id from the catalog.
        mode: ModeId,
    },
    /// Start a review (Codex `review/start`).
    Review {
        /// What to review.
        target: ReviewTarget,
    },
    /// Act on the session goal (Codex `thread/goal/*`).
    Goal {
        /// The goal action.
        action: GoalOp,
    },
    /// Stop one child or background task (Claude `stop_task`,
    /// Codex `thread/backgroundTerminals/terminate`).
    StopChild {
        /// The child to stop.
        child: ChildRef,
    },
    /// Answer a pending interaction. Claimed once and bound to the exact interaction.
    Answer {
        /// The interaction being answered.
        interaction: InteractionId,
        /// The answer.
        response: InteractionResponse,
        /// The Inline user who answered, for `InteractionClosed { by }`.
        by: UserId,
    },
    /// A side call that leaves no trace in the session (speak gate).
    Sample {
        /// Prompt for the side call.
        prompt: String,
    },
    /// Start sign-in for one MCP server (Codex `mcpServer/oauth/login`).
    McpAuth {
        /// Native MCP server name.
        server: String,
    },
}

impl Op {
    /// The availability key for this operation.
    pub fn kind(&self) -> OpKind {
        match self {
            Self::Interrupt {
                cancel_queued: false,
            } => OpKind::Interrupt,
            Self::Interrupt {
                cancel_queued: true,
            } => OpKind::InterruptCancelQueued,
            Self::Queue {
                action: QueueOp::Start,
            } => OpKind::QueueStart,
            Self::Queue { .. } => OpKind::QueueEdit,
            Self::Settings {
                scope: SettingsScope::Turn,
                ..
            } => OpKind::SettingsTurn,
            Self::Settings {
                scope: SettingsScope::Thread,
                ..
            } => OpKind::SettingsThread,
            Self::Settings {
                scope: SettingsScope::Persisted,
                ..
            } => OpKind::SettingsPersisted,
            Self::Compact => OpKind::Compact,
            Self::Rename { .. } => OpKind::Rename,
            Self::Archive | Self::Unarchive => OpKind::Archive,
            Self::Clear => OpKind::Clear,
            Self::RewindFiles { .. } => OpKind::RewindFiles,
            Self::Mode { .. } => OpKind::Mode,
            Self::Review { .. } => OpKind::Review,
            Self::Goal { .. } => OpKind::Goal,
            Self::StopChild { .. } => OpKind::StopChild,
            Self::Answer { .. } => OpKind::Answer,
            Self::Sample { .. } => OpKind::Sample,
            Self::McpAuth { .. } => OpKind::McpAuth,
        }
    }
}

/// Fieldless operation key used by availability tables.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OpKind {
    /// Interrupt that keeps queued input.
    Interrupt,
    /// Interrupt that also cancels queued input.
    InterruptCancelQueued,
    /// Start draining the native queue.
    QueueStart,
    /// Remove, reorder or clear queued input.
    QueueEdit,
    /// Settings for the next turn only.
    SettingsTurn,
    /// Settings for this session from now on.
    SettingsThread,
    /// Settings written to the harness's persisted config.
    SettingsPersisted,
    /// [`Op::Compact`].
    Compact,
    /// [`Op::Rename`].
    Rename,
    /// [`Op::Archive`] and [`Op::Unarchive`].
    Archive,
    /// [`Op::Clear`].
    Clear,
    /// [`Op::RewindFiles`].
    RewindFiles,
    /// [`Op::Mode`].
    Mode,
    /// [`Op::Review`].
    Review,
    /// [`Op::Goal`].
    Goal,
    /// [`Op::StopChild`].
    StopChild,
    /// [`Op::Answer`].
    Answer,
    /// [`Op::Sample`].
    Sample,
    /// [`Op::McpAuth`].
    McpAuth,
}

impl OpKind {
    /// Every operation kind, in a stable order.
    pub const ALL: [Self; 19] = [
        Self::Interrupt,
        Self::InterruptCancelQueued,
        Self::QueueStart,
        Self::QueueEdit,
        Self::SettingsTurn,
        Self::SettingsThread,
        Self::SettingsPersisted,
        Self::Compact,
        Self::Rename,
        Self::Archive,
        Self::Clear,
        Self::RewindFiles,
        Self::Mode,
        Self::Review,
        Self::Goal,
        Self::StopChild,
        Self::Answer,
        Self::Sample,
        Self::McpAuth,
    ];
}

/// Native queue actions. Adding to the queue is [`Delivery::Queue`](super::Delivery::Queue).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum QueueOp {
    /// Start draining (Codex `thread/queue/start`), used on resume after pause.
    Start,
    /// Remove one entry.
    Remove {
        /// Native entry id.
        entry: QueueEntryId,
    },
    /// Move one entry to a new position.
    Reorder {
        /// Native entry id.
        entry: QueueEntryId,
        /// Zero-based target position.
        position: u32,
    },
    /// Remove every entry.
    Clear,
}

/// A settings change. `None` fields are left unchanged; values are native ids
/// from the catalog.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettingsChange {
    /// Model id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Reasoning effort id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    /// Speed / service tier id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speed: Option<String>,
    /// Permission mode id (Codex approval policy and sandbox preset, Claude
    /// `--permission-mode`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_mode: Option<String>,
    /// Working folder.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<PathBuf>,
}

impl SettingsChange {
    /// Whether the change sets nothing.
    pub fn is_empty(&self) -> bool {
        self == &Self::default()
    }
}

/// How long a settings change lasts.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SettingsScope {
    /// The next turn only.
    Turn,
    /// This session from the next message on (the composer chain, Oct 26).
    Thread,
    /// The harness's persisted configuration (Agent Settings defaults).
    Persisted,
}

/// A point to rewind files to.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RewindPoint {
    /// Before the given input was applied.
    Input {
        /// Inline input id.
        input: InputId,
    },
    /// Before the given native item (Claude user message uuid).
    Item {
        /// Native item id.
        item: ItemId,
    },
    /// Before the given turn.
    Turn {
        /// Native turn id.
        turn: TurnId,
    },
}

/// What a review looks at (Codex `review/start` targets).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ReviewTarget {
    /// Staged, unstaged and untracked changes.
    UncommittedChanges,
    /// Changes against a base branch.
    BaseBranch {
        /// Branch name.
        branch: String,
    },
    /// One commit.
    Commit {
        /// Commit sha.
        sha: String,
        /// Optional commit title for display.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
    },
    /// Free-form review instructions.
    Custom {
        /// Instructions.
        instructions: String,
    },
}

/// Session goal actions.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum GoalOp {
    /// Set or replace the goal.
    Set {
        /// Goal objective text.
        objective: String,
    },
    /// Clear the goal.
    Clear,
}

/// An answer to a pending interaction.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum InteractionResponse {
    /// Pick one advertised decision.
    Decision {
        /// One of the interaction's advertised decision ids.
        decision: DecisionId,
        /// Text for decisions that take one ("tell Codex/Claude what to do differently").
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    /// Answer a question form.
    Answers {
        /// Answers by field.
        answers: Vec<FieldAnswer>,
    },
    /// Dismiss without answering (native cancel).
    Cancel,
}

impl fmt::Debug for InteractionResponse {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Decision { decision, message } => formatter
                .debug_struct("Decision")
                .field("decision", decision)
                .field("has_message", &message.is_some())
                .finish(),
            Self::Answers { answers } => formatter
                .debug_struct("Answers")
                .field("fields", &answers.len())
                .finish(),
            Self::Cancel => formatter.write_str("Cancel"),
        }
    }
}

/// Values given for one form field. Secret values are relayed, never logged.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FieldAnswer {
    /// Field id from the form.
    pub field: FieldId,
    /// Selected option labels or typed values, in order.
    pub values: Vec<String>,
}

impl fmt::Debug for FieldAnswer {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("FieldAnswer")
            .field("field", &self.field)
            .field("values", &self.values.len())
            .finish()
    }
}

/// Successful result of an operation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum OpOutcome {
    /// The harness accepted the operation. Its effects arrive as events.
    Accepted {
        /// Native response, kept for the journal.
        #[serde(default, skip_serializing_if = "Value::is_null")]
        native: Value,
    },
    /// The operation started a turn (compact, review).
    TurnStarted {
        /// Native turn id.
        turn: TurnId,
    },
    /// Result of [`Op::Sample`].
    Sampled {
        /// Side-call text.
        text: String,
    },
}

impl OpOutcome {
    /// Accepted with no native payload.
    pub fn accepted() -> Self {
        Self::Accepted {
            native: Value::Null,
        }
    }
}

/// Why an operation failed.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum OpError {
    /// The operation is not available for this harness version or session.
    #[error("operation unavailable: {0}")]
    Unavailable(Availability),
    /// The interaction is not pending (already answered, closed or unknown).
    #[error("interaction is not pending")]
    InteractionNotPending,
    /// The response does not match what the interaction advertised.
    #[error("response does not match the interaction: {0}")]
    InvalidResponse(String),
    /// The harness rejected the operation.
    #[error("harness rejected the operation: {0}")]
    Rejected(String),
    /// A queue entry to remove was no longer queued: it already ran or was
    /// taken, so there is nothing left to hold.
    #[error("the entry is no longer queued")]
    NotQueued,
    /// The harness may or may not have applied it. Never retried automatically.
    #[error("operation outcome is unknown: {0}")]
    Unknown(String),
    /// Transport or process failure before the harness saw the operation.
    #[error(transparent)]
    Driver(#[from] DriverError),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn op_kinds_cover_scope_and_queue_flavors() {
        assert_eq!(
            Op::Interrupt {
                cancel_queued: true
            }
            .kind(),
            OpKind::InterruptCancelQueued
        );
        assert_eq!(
            Op::Settings {
                change: SettingsChange::default(),
                scope: SettingsScope::Thread
            }
            .kind(),
            OpKind::SettingsThread
        );
        assert_eq!(
            Op::Queue {
                action: QueueOp::Start
            }
            .kind(),
            OpKind::QueueStart
        );
        assert_eq!(
            Op::Queue {
                action: QueueOp::Clear
            }
            .kind(),
            OpKind::QueueEdit
        );
    }

    #[test]
    fn answers_round_trip_and_never_debug_print_values() {
        let op = Op::Answer {
            interaction: InteractionId::new("q-1").expect("id"),
            response: InteractionResponse::Answers {
                answers: vec![FieldAnswer {
                    field: FieldId::new("token").expect("field"),
                    values: vec!["s3cret".to_owned()],
                }],
            },
            by: UserId(5),
        };
        let encoded = serde_json::to_value(&op).expect("encode");
        assert_eq!(encoded["op"], "answer");
        assert_eq!(encoded["response"]["kind"], "answers");
        assert_eq!(serde_json::from_value::<Op>(encoded).expect("decode"), op);
        assert!(!format!("{op:?}").contains("s3cret"));
    }

    #[test]
    fn interrupt_defaults_to_keeping_the_queue() {
        let op: Op = serde_json::from_str(r#"{"op":"interrupt"}"#).expect("decode");
        assert_eq!(op.kind(), OpKind::Interrupt);
    }
}
