//! The session event stream (spec §4.2 `Event`).
//!
//! One ordered stream per native session, whoever caused the event: Inline,
//! the terminal, a queue drain, a sub-agent after its turn, a background task.
//! Events keep native ids and the native payload. Unknown kinds render
//! generically and are never dropped.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::{Number, Value};

use super::{
    ChildRef, DecisionId, FieldId, InputId, InteractionId, ItemId, QueueEntryId, RunState,
    SessionKey, UserId,
};
use crate::{
    AgentMessagePhase, DriverSettingOption, DriverUsageWindow, PlanStep, SessionCheckpoint, TurnId,
    TurnOutcome,
};

/// One sequenced event of a session stream.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Envelope {
    /// The session this event belongs to.
    pub session: SessionKey,
    /// Strictly increasing by one within a stream; see [`super::StreamCursor`].
    pub seq: u64,
    /// Native resume cursor after this event, when the harness has one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checkpoint: Option<SessionCheckpoint>,
    /// Bridge receive time in Unix milliseconds.
    pub at_ms: u64,
    /// The event.
    pub event: Event,
}

/// Everything that can happen in a session.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    /// The run state, reported by the driver when it knows it directly.
    State {
        /// New state.
        state: RunState,
    },
    /// A turn started or completed, wherever it came from.
    Turn {
        /// Native turn id.
        turn: TurnId,
        /// Started or completed.
        phase: TurnPhase,
    },
    /// An item started, grew, changed or completed.
    Item(Item),
    /// An approval, question or dialog opened.
    Interaction(Interaction),
    /// A pending interaction closed.
    InteractionClosed {
        /// The interaction.
        id: InteractionId,
        /// Who or what closed it.
        by: ClosedBy,
    },
    /// A delivery fact about one Inline input (spec §4.7).
    Input {
        /// The input.
        id: InputId,
        /// What happened to it.
        fact: InputFact,
    },
    /// The native queue, replaced whole.
    Queue {
        /// Queue entries in order.
        entries: Vec<QueuedInput>,
    },
    /// Effective settings, replaced whole.
    Settings {
        /// What the harness reports as in effect.
        effective: EffectiveSettings,
    },
    /// Token usage, context window and account limits.
    Usage {
        /// The update.
        usage: UsageUpdate,
    },
    /// A child or background task changed.
    Child {
        /// The update.
        update: ChildUpdate,
    },
    /// Another client took the session (`Some`) or let it go (`None`).
    Held {
        /// The holder, or `None` when free.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        by: Option<HeldBy>,
    },
    /// The native session was renamed (Codex `thread/name/updated`).
    Renamed {
        /// New title.
        title: String,
    },
    /// Anything else the harness said, kept whole.
    Notice(Notice),
    /// Events were lost between two sequence numbers. The consumer repairs
    /// from a snapshot before trusting later state.
    Gap {
        /// Sequence the consumer expected.
        expected: u64,
        /// Sequence that arrived.
        actual: u64,
    },
}

impl Event {
    /// Whether losing this event would hide something the user must act on.
    /// Coalescing under pressure never drops these.
    pub fn is_control(&self) -> bool {
        match self {
            Self::Interaction(_)
            | Self::InteractionClosed { .. }
            | Self::Turn { .. }
            | Self::Input { .. }
            | Self::State { .. }
            | Self::Held { .. }
            | Self::Gap { .. } => true,
            Self::Item(item) => !matches!(item.update, ItemUpdate::Delta { .. }),
            _ => false,
        }
    }
}

/// Turn lifecycle.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "phase", rename_all = "snake_case")]
pub enum TurnPhase {
    /// The turn started.
    Started {
        /// Inline inputs the turn starts from, when correlated.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        inputs: Vec<InputId>,
    },
    /// The turn ended.
    Completed {
        /// Terminal classification.
        outcome: TurnOutcome,
        /// Inline inputs the turn consumed (turn input, steers, drained queue).
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        inputs_consumed: Vec<InputId>,
        /// Concise native error, safe to show.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
        /// Native duration.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        duration_ms: Option<u64>,
    },
}

/// Coarse item category, kept beside the body so deltas render after a gap.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ItemKind {
    /// User or agent message.
    Message,
    /// Reasoning summary or content.
    Reasoning,
    /// Tool call (MCP, dynamic, web search, Claude tools).
    Tool,
    /// Shell command.
    Command,
    /// File edits.
    FileChange,
    /// Plan or todo list.
    Plan,
    /// Sub-agent or background task item.
    Child,
    /// Usage or compaction marker.
    Usage,
    /// Error reported as an item.
    Error,
    /// A kind this bridge does not know.
    Unknown,
}

/// One item event. Started and Completed carry full snapshots; Delta appends.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    /// Native item id.
    pub id: ItemId,
    /// Turn the item belongs to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn: Option<TurnId>,
    /// Child the item belongs to; `None` for the main agent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<ChildRef>,
    /// Category.
    pub kind: ItemKind,
    /// Message phase (commentary or final answer), when the harness reports one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<AgentMessagePhase>,
    /// Lifecycle step.
    pub update: ItemUpdate,
    /// Native payload, whole.
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub native: Value,
}

impl Item {
    /// Builds an item whose kind follows its body (or `Unknown` for a bare delta).
    pub fn new(id: ItemId, turn: Option<TurnId>, update: ItemUpdate, native: Value) -> Self {
        let kind = update.body().map_or(ItemKind::Unknown, ItemBody::kind);
        Self {
            id,
            turn,
            parent: None,
            kind,
            phase: None,
            update,
            native,
        }
    }

    /// Sets the parent child.
    pub fn with_parent(mut self, parent: Option<ChildRef>) -> Self {
        self.parent = parent;
        self
    }

    /// Sets the message phase.
    pub fn with_phase(mut self, phase: Option<AgentMessagePhase>) -> Self {
        self.phase = phase;
        self
    }

    /// Overrides the kind (for deltas, whose kind is known from the method).
    pub fn with_kind(mut self, kind: ItemKind) -> Self {
        self.kind = kind;
        self
    }
}

/// Item lifecycle.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum ItemUpdate {
    /// The item started, with its first snapshot.
    Started {
        /// Snapshot.
        body: ItemBody,
    },
    /// Append-only text for one stream of the item.
    Delta {
        /// The delta.
        delta: ItemDelta,
    },
    /// Replacement snapshot while the item is still live (plan updates, patch updates).
    Updated {
        /// Snapshot.
        body: ItemBody,
    },
    /// The item ended, with its authoritative snapshot.
    Completed {
        /// Snapshot.
        body: ItemBody,
        /// How it ended.
        status: ItemStatus,
    },
}

impl ItemUpdate {
    /// The snapshot, unless this is a delta.
    pub fn body(&self) -> Option<&ItemBody> {
        match self {
            Self::Started { body } | Self::Updated { body } | Self::Completed { body, .. } => {
                Some(body)
            }
            Self::Delta { .. } => None,
        }
    }
}

/// How an item ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ItemStatus {
    /// Succeeded.
    Completed,
    /// Failed.
    Failed,
    /// Declined by an approval.
    Declined,
    /// Stopped by an interrupt.
    Interrupted,
    /// A status this bridge does not know.
    #[serde(other)]
    Unknown,
}

/// Append-only text.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ItemDelta {
    /// Which text of the item grows.
    pub stream: DeltaStream,
    /// Part index for multipart text (reasoning summary parts).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<u32>,
    /// The appended text.
    pub text: String,
}

/// Which text of an item a delta extends.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeltaStream {
    /// Message text.
    Text,
    /// Reasoning summary.
    ReasoningSummary,
    /// Raw reasoning content.
    ReasoningContent,
    /// Command or tool output.
    Output,
    /// Diff or patch text.
    Diff,
    /// Plan text.
    Plan,
    /// A stream this bridge does not know.
    #[serde(other)]
    Unknown,
}

/// Normalized item content. The native payload stays in [`Item::native`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ItemBody {
    /// A message from the user or the agent.
    Message {
        /// Author role.
        role: MessageRole,
        /// Full text.
        text: String,
        /// The Inline input this user message echoes, when the harness
        /// returned the correlation. Uncorrelated user messages came from
        /// another client and are shown.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        input: Option<InputId>,
    },
    /// Reasoning summary and, when exposed, content.
    Reasoning {
        /// Summary parts.
        #[serde(default)]
        summary: Vec<String>,
        /// Raw content parts.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        content: Vec<String>,
    },
    /// A tool call.
    Tool {
        /// Tool name in the harness's own vocabulary (Read, Grep, web search, ...).
        name: String,
        /// MCP server or namespace.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        server: Option<String>,
        /// Arguments.
        #[serde(default, skip_serializing_if = "Value::is_null")]
        input: Value,
        /// Text result.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        output: Option<String>,
        /// Error text.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// A shell command.
    Command {
        /// Command line.
        command: String,
        /// Working folder.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<PathBuf>,
        /// Parsed actions ("explored" vocabulary).
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        actions: Vec<CommandAction>,
        /// Aggregated output.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        output: Option<String>,
        /// Exit code.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        exit_code: Option<i32>,
        /// Duration.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        duration_ms: Option<u64>,
    },
    /// File edits.
    FileChange {
        /// Changed files.
        changes: Vec<FileDiff>,
    },
    /// A plan or todo list (replace-all).
    Plan {
        /// Optional explanation.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        explanation: Option<String>,
        /// Steps.
        #[serde(default)]
        steps: Vec<PlanStep>,
        /// Free-form plan text (Codex plan items).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        text: Option<String>,
    },
    /// A sub-agent or background task started or reported from this session.
    Child {
        /// The child.
        child: ChildRef,
        /// Tool or action that started it (spawn, send, wait, Task).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        action: Option<String>,
        /// Prompt or description.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        prompt: Option<String>,
    },
    /// Context usage marker (compaction).
    Usage {
        /// Human-readable label.
        label: String,
    },
    /// An error reported as an item.
    Error {
        /// Message.
        message: String,
    },
    /// A kind this bridge does not know. Rendered as a generic disclosure.
    Unknown {
        /// Native type name.
        native_type: String,
        /// Best-effort one-line summary.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        summary: Option<String>,
    },
}

impl ItemBody {
    /// The category of this body.
    pub fn kind(&self) -> ItemKind {
        match self {
            Self::Message { .. } => ItemKind::Message,
            Self::Reasoning { .. } => ItemKind::Reasoning,
            Self::Tool { .. } => ItemKind::Tool,
            Self::Command { .. } => ItemKind::Command,
            Self::FileChange { .. } => ItemKind::FileChange,
            Self::Plan { .. } => ItemKind::Plan,
            Self::Child { .. } => ItemKind::Child,
            Self::Usage { .. } => ItemKind::Usage,
            Self::Error { .. } => ItemKind::Error,
            Self::Unknown { .. } => ItemKind::Unknown,
        }
    }
}

/// Message author.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageRole {
    /// A person (or Inline on their behalf).
    User,
    /// The agent.
    Assistant,
    /// Harness or hook text.
    System,
}

/// One parsed part of a shell command.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CommandAction {
    /// Reads a file.
    Read {
        /// Path.
        path: String,
    },
    /// Lists files.
    ListFiles {
        /// Path.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        path: Option<String>,
    },
    /// Searches.
    Search {
        /// Query.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        query: Option<String>,
        /// Path.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        path: Option<String>,
    },
    /// Anything else.
    Unknown {
        /// Command text.
        command: String,
    },
}

/// One changed file.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileDiff {
    /// Path.
    pub path: PathBuf,
    /// Kind of change.
    pub change: FileChangeKind,
    /// Unified diff, when available.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diff: Option<String>,
}

/// Kind of file change.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FileChangeKind {
    /// Created.
    Add,
    /// Deleted.
    Delete,
    /// Modified, possibly moved.
    Update {
        /// New path when moved.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        moved_to: Option<PathBuf>,
    },
}

/// An approval, question or dialog. Details are shown to the whole thread.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Interaction {
    /// Native request id.
    pub id: InteractionId,
    /// Turn it blocks.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn: Option<TurnId>,
    /// Item it is about.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item: Option<ItemId>,
    /// Child that raised it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<ChildRef>,
    /// What is asked.
    pub kind: InteractionKind,
    /// Native request, whole.
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub native: Value,
}

/// What an interaction asks.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum InteractionKind {
    /// Approve or deny something. Offers exactly the decisions the harness
    /// advertises, with the harness's labels.
    Approval {
        /// What is being approved.
        subject: ApprovalSubject,
        /// Advertised decisions in native order.
        decisions: Vec<Decision>,
    },
    /// Answer a question form.
    Question {
        /// The form.
        form: QuestionForm,
    },
    /// A dialog kind this bridge does not handle. Cancelled safely with a
    /// visible notice.
    Dialog {
        /// Native dialog kind or method.
        dialog: String,
    },
}

/// What an approval is about.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ApprovalSubject {
    /// Run a command (optionally with network or extra permissions).
    Command {
        /// Command line.
        command: String,
        /// Working folder.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<PathBuf>,
        /// Model's reason.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
        /// Network host the command needs, when that is the question.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        network_host: Option<String>,
        /// Extra permissions requested, as the harness phrases them.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        permissions: Option<String>,
    },
    /// Apply file changes.
    FileChange {
        /// Paths.
        #[serde(default)]
        paths: Vec<PathBuf>,
        /// Model's reason.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
        /// Root the harness would grant write access to.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        grant_root: Option<PathBuf>,
    },
    /// Grant permissions.
    Permissions {
        /// Requested permissions, as the harness phrases them.
        summary: String,
        /// Model's reason.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    /// Use a tool (Claude `can_use_tool`, MCP elicitation).
    Tool {
        /// Tool name.
        name: String,
        /// Tool input.
        #[serde(default, skip_serializing_if = "Value::is_null")]
        input: Value,
        /// Reason or description.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    /// Anything else.
    Other {
        /// Title.
        title: String,
        /// Detail.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
}

/// One advertised approval decision.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Decision {
    /// Opaque id, unique within the interaction.
    pub id: DecisionId,
    /// The harness's own label ("Yes, proceed").
    pub label: String,
    /// Category, for styling and defaults only.
    pub kind: DecisionKind,
    /// Extra detail.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Whether the decision takes a message ("tell Codex what to do differently").
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub accepts_message: bool,
    /// Native decision value sent back verbatim.
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub native: Value,
}

/// Decision category.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DecisionKind {
    /// Approve once.
    Accept,
    /// Approve for the rest of the session.
    AcceptForSession,
    /// Approve and remember a rule (execpolicy prefix, network allow,
    /// Claude permission update).
    AcceptAndRemember,
    /// Deny and remember a rule (network deny).
    DeclineAndRemember,
    /// Deny; the turn continues.
    Decline,
    /// Deny and stop the turn.
    Cancel,
    /// A category this bridge does not know.
    #[serde(other)]
    Other,
}

/// A question form. One submit answers every field.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionForm {
    /// Optional title.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Fields in display order.
    pub fields: Vec<FormField>,
    /// The turn does not block on it (Codex async `questions`); the answer is
    /// delivered as ordinary input.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub asynchronous: bool,
    /// Native deadline after which the harness resolves it on its own.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_resolution_ms: Option<u64>,
}

/// One form field.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FormField {
    /// Field id.
    pub id: FieldId,
    /// Short header.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,
    /// Prompt.
    pub prompt: String,
    /// Input control.
    pub input: FieldInput,
    /// Whether an answer is required.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub required: bool,
}

/// Input control of a form field.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FieldInput {
    /// Pick from options.
    Select {
        /// Options.
        options: Vec<FieldOption>,
        /// Whether more than one may be picked.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        multiple: bool,
        /// Whether a free-form answer is accepted.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        allow_other: bool,
    },
    /// Free text.
    Text {
        /// Multiline.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        multiline: bool,
        /// Default value.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        default: Option<String>,
    },
    /// Secret text: relayed, never persisted or logged.
    Secret,
    /// On/off.
    Toggle {
        /// Default value.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        default: Option<bool>,
    },
    /// A number.
    Number {
        /// Default value.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        default: Option<Number>,
        /// Minimum.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        min: Option<Number>,
        /// Maximum.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        max: Option<Number>,
    },
}

/// One option of a select field.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FieldOption {
    /// Label, also the answer value.
    pub label: String,
    /// Description.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// Who or what closed an interaction.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ClosedBy {
    /// Answered from Inline.
    Inline {
        /// Who answered.
        user: UserId,
        /// The decision picked, for approvals.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        decision: Option<DecisionId>,
    },
    /// Resolved by another client or by the harness itself.
    External,
    /// Withdrawn or cancelled (turn ended, interrupt, unsupported dialog).
    Cancelled,
}

/// A delivery fact about one Inline input.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "fact", rename_all = "snake_case")]
pub enum InputFact {
    /// The harness consumed it in a turn.
    Consumed {
        /// The turn.
        turn: TurnId,
    },
    /// The harness dropped or cancelled it (Claude `cancelQueued`, queue delete).
    Cancelled,
    /// The harness rejected it.
    Rejected {
        /// Native reason.
        reason: String,
    },
}

/// One native queue entry.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueuedInput {
    /// Native entry id.
    pub entry: QueueEntryId,
    /// The Inline input, when correlated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<InputId>,
    /// Bounded preview of the text.
    pub preview: String,
}

/// Settings the harness reports as in effect.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct EffectiveSettings {
    /// Resolved model (aliases resolve differently per CLI version).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<DriverSettingOption>,
    /// Reasoning effort.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    /// Speed / service tier.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speed: Option<String>,
    /// Permission mode as the harness reports it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_mode: Option<String>,
    /// Collaboration or plan mode.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
    /// Working folder.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<PathBuf>,
}

/// Token, context and account usage.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UsageUpdate {
    /// Tokens used by the last turn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last: Option<TokenUsage>,
    /// Tokens used by the session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total: Option<TokenUsage>,
    /// Model context window.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_window: Option<u64>,
    /// Account usage windows.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub limits: Vec<DriverUsageWindow>,
}

/// Token counts.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenUsage {
    /// Input tokens.
    pub input: u64,
    /// Cached input tokens.
    #[serde(default)]
    pub cached_input: u64,
    /// Output tokens.
    pub output: u64,
    /// Reasoning output tokens.
    #[serde(default)]
    pub reasoning: u64,
    /// Total tokens.
    pub total: u64,
}

/// A child or background task changed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChildUpdate {
    /// The child.
    pub child: ChildRef,
    /// Its status.
    pub status: ChildStatus,
    /// Title or description.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Whether people can address it directly (Codex `canAcceptDirectInput`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub accepts_direct_input: bool,
    /// Native payload.
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub native: Value,
}

/// Child status.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChildStatus {
    /// Started.
    Started,
    /// Running.
    Running,
    /// Waiting on something.
    Waiting,
    /// Finished.
    Completed,
    /// Failed.
    Failed,
    /// Stopped.
    Stopped,
    /// A status this bridge does not know.
    #[serde(other)]
    Unknown,
}

/// Who holds a session elsewhere.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct HeldBy {
    /// Which client.
    pub surface: HeldSurface,
    /// Native detail (process, client name).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// Client category holding a session.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HeldSurface {
    /// A terminal CLI session.
    Terminal,
    /// The ChatGPT or Claude desktop app.
    DesktopApp,
    /// An IDE extension.
    Ide,
    /// A background or remote process.
    Background,
    /// Unknown.
    #[serde(other)]
    Unknown,
}

/// Something the harness said that has no typed home. Never dropped.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Notice {
    /// Severity.
    pub level: NoticeLevel,
    /// Native method or type.
    pub code: String,
    /// Human-readable text, when the harness gave one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// Native payload, whole.
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub native: Value,
}

/// Notice severity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NoticeLevel {
    /// Informational; shown in Detailed mode only.
    Info,
    /// Worth showing.
    Warning,
    /// An error.
    Error,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ProviderId, ProviderSessionId};

    fn key() -> SessionKey {
        SessionKey {
            provider: ProviderId::new("codex").expect("provider"),
            session: ProviderSessionId::new("thread-1").expect("session"),
        }
    }

    #[test]
    fn envelope_round_trips_with_stable_wire_shape() {
        let envelope = Envelope {
            session: key(),
            seq: 4,
            checkpoint: None,
            at_ms: 1_777_000_000_000,
            event: Event::Item(
                Item::new(
                    ItemId::new("msg-1").expect("id"),
                    Some(TurnId::new("turn-1").expect("turn")),
                    ItemUpdate::Delta {
                        delta: ItemDelta {
                            stream: DeltaStream::Text,
                            index: None,
                            text: "Hel".to_owned(),
                        },
                    },
                    Value::Null,
                )
                .with_kind(ItemKind::Message),
            ),
        };
        let encoded = serde_json::to_value(&envelope).expect("encode");
        assert_eq!(
            encoded,
            serde_json::json!({
                "session": {"provider": "codex", "session": "thread-1"},
                "seq": 4,
                "at_ms": 1_777_000_000_000_u64,
                "event": {
                    "type": "item",
                    "id": "msg-1",
                    "turn": "turn-1",
                    "kind": "message",
                    "update": {"op": "delta", "delta": {"stream": "text", "text": "Hel"}}
                }
            })
        );
        assert_eq!(
            serde_json::from_value::<Envelope>(encoded).expect("decode"),
            envelope
        );
    }

    #[test]
    fn unknown_native_enums_decode_without_failing_the_stream() {
        let status: ItemStatus = serde_json::from_str("\"paused\"").expect("status");
        assert_eq!(status, ItemStatus::Unknown);
        let kind: DecisionKind = serde_json::from_str("\"accept_forever\"").expect("kind");
        assert_eq!(kind, DecisionKind::Other);
        let stream: DeltaStream = serde_json::from_str("\"audio\"").expect("stream");
        assert_eq!(stream, DeltaStream::Unknown);
    }

    #[test]
    fn deltas_are_not_control_but_item_boundaries_are() {
        let delta = Event::Item(Item::new(
            ItemId::new("i").expect("id"),
            None,
            ItemUpdate::Delta {
                delta: ItemDelta {
                    stream: DeltaStream::Output,
                    index: None,
                    text: "x".to_owned(),
                },
            },
            Value::Null,
        ));
        assert!(!delta.is_control());
        let completed = Event::Item(Item::new(
            ItemId::new("i").expect("id"),
            None,
            ItemUpdate::Completed {
                body: ItemBody::Error {
                    message: "boom".to_owned(),
                },
                status: ItemStatus::Failed,
            },
            Value::Null,
        ));
        assert!(completed.is_control());
        assert_eq!(
            match &completed {
                Event::Item(item) => item.kind,
                _ => unreachable!(),
            },
            ItemKind::Error
        );
    }
}
