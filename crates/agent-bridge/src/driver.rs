//! Provider-facing contracts normalized by the Inline bridge runtime.
//!
//! Drivers must advertise only capabilities they can honor. The default
//! capability set is deliberately fail-closed: optional operations are
//! unsupported until a driver opts in.

#![warn(missing_docs)]

use std::collections::VecDeque;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::Duration;

use crate::{InputAttachment, OutputAttachment, ProviderSessionId, TurnId};
use futures_util::Stream;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use thiserror::Error;

const DEFAULT_AGENT_EVENT_CAPACITY: usize = 128;
const MAX_COALESCED_TEXT_BYTES: usize = 64 * 1024;
const TRUNCATED_DELTA_MARKER: &str = "\n[additional agent output omitted]";
const MAX_ACTIVITY_ID_BYTES: usize = 256;
const MAX_ACTIVITY_TITLE_CHARS: usize = 240;
const MAX_ACTIVITY_DETAIL_CHARS: usize = 512;
const MAX_ACTIVITY_PATHS: usize = 8;
const MAX_ACTIVITY_PATH_BYTES: usize = 1024;
const MAX_FILE_CHANGES: usize = 64;
const MAX_FILE_CHANGE_PATH_BYTES: usize = 1024;
const MAX_DRIVER_COMMANDS: usize = 64;
const MAX_DRIVER_COMMAND_NAME_BYTES: usize = 64;
const MAX_DRIVER_COMMAND_DESCRIPTION_CHARS: usize = 160;
const MAX_DRIVER_COMMAND_HINT_CHARS: usize = 80;
const MAX_DRIVER_COMMAND_CHOICES: usize = 60;
const MAX_DRIVER_COMMAND_CHOICE_VALUE_BYTES: usize = 512;
const MAX_DRIVER_COMMAND_CHOICE_LABEL_CHARS: usize = 80;
const MAX_DRIVER_COMMAND_CHOICE_DESCRIPTION_CHARS: usize = 160;
const MAX_DRIVER_COMMAND_GENERATION_BYTES: usize = 128;

/// Result returned by provider-driver operations.
pub type DriverResult<T> = Result<T, DriverError>;
/// Sendable boxed future returned by object-safe driver methods.
pub type DriverFuture<'a, T> = Pin<Box<dyn Future<Output = DriverResult<T>> + Send + 'a>>;
/// Boxed future returned by a bridge-owned host tool handler.
pub type HostToolFuture<'a> = Pin<Box<dyn Future<Output = HostToolResult> + Send + 'a>>;

/// Provider transport used to expose bridge-owned host tools.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostToolTransport {
    /// Provider-native host tool calls, such as Codex app-server dynamic tools.
    Native,
    /// A provider-negotiated MCP attachment.
    Mcp,
    /// No verified host-tool transport is available.
    #[default]
    Unsupported,
}

/// One typed bridge-owned tool advertised to a provider.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct HostToolSpec {
    /// Stable tool name without the provider namespace.
    pub name: String,
    /// Concise provider-facing description.
    pub description: String,
    /// Strict JSON Schema for tool arguments.
    pub input_schema: Value,
    /// Whether the tool is read-only.
    pub read_only: bool,
}

/// One provider host-tool call bound to a provider session and turn.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct HostToolCall {
    /// Provider-owned call identity used for idempotency.
    pub call_id: String,
    /// Provider session that issued the call.
    pub session_id: ProviderSessionId,
    /// Provider turn that issued the call.
    pub turn_id: TurnId,
    /// Stable tool name without the provider namespace.
    pub tool_name: String,
    /// Bounded JSON arguments supplied by the provider.
    pub arguments: Value,
}

/// Bounded result returned to a provider host-tool call.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostToolResult {
    /// Whether the operation succeeded.
    pub success: bool,
    /// Text or compact JSON returned as untrusted provider input.
    pub content: String,
}

impl HostToolResult {
    /// Creates a successful host-tool result.
    pub fn success(content: impl Into<String>) -> Self {
        Self {
            success: true,
            content: content.into(),
        }
    }

    /// Creates a failed host-tool result without exposing internal diagnostics.
    pub fn failure(content: impl Into<String>) -> Self {
        Self {
            success: false,
            content: content.into(),
        }
    }
}

/// Bridge-owned executor for provider host-tool calls.
pub trait HostToolHandler: Send + Sync {
    /// Executes one already-framed call. Implementations must reauthorize the
    /// turn before network or durable work.
    fn call<'a>(&'a self, call: HostToolCall) -> HostToolFuture<'a>;
}

/// Tool catalog and executor installed into one provider driver epoch.
#[derive(Clone)]
pub struct HostToolConfiguration {
    /// Typed tools to advertise.
    pub specs: Vec<HostToolSpec>,
    /// Bridge-owned executor.
    pub handler: Arc<dyn HostToolHandler>,
}

impl std::fmt::Debug for HostToolConfiguration {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("HostToolConfiguration")
            .field("specs", &self.specs)
            .field("handler", &"<host-tool-handler>")
            .finish()
    }
}

impl HostToolConfiguration {
    /// Stable fingerprint for the tool names, schemas, and mutation classes
    /// attached when a provider session is created. Descriptions are excluded
    /// so copy-only improvements do not discard otherwise resumable context.
    pub fn compatibility_fingerprint(&self) -> String {
        let mut contracts = self
            .specs
            .iter()
            .map(|spec| {
                json!({
                    "name": spec.name,
                    "input_schema": canonical_json(&spec.input_schema),
                    "read_only": spec.read_only,
                })
            })
            .collect::<Vec<_>>();
        contracts.sort_by(|left, right| {
            left.get("name")
                .and_then(Value::as_str)
                .cmp(&right.get("name").and_then(Value::as_str))
        });
        let encoded = serde_json::to_vec(&contracts)
            .expect("host tool compatibility contract must serialize");
        format!("sha256:{:x}", Sha256::digest(encoded))
    }
}

fn canonical_json(value: &Value) -> Value {
    match value {
        Value::Array(values) => Value::Array(values.iter().map(canonical_json).collect()),
        Value::Object(values) => {
            let mut keys = values.keys().collect::<Vec<_>>();
            keys.sort_unstable();
            let mut canonical = serde_json::Map::new();
            for key in keys {
                canonical.insert(key.clone(), canonical_json(&values[key]));
            }
            Value::Object(canonical)
        }
        value => value.clone(),
    }
}

/// How a driver can apply direction to an already-running turn.
///
/// The default is [`Unsupported`](Self::Unsupported), so callers must queue a
/// new turn unless the driver explicitly advertises another mode.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SteeringSupport {
    /// The provider exposes a first-class mid-turn steering operation.
    Native,
    /// The driver supplies compatible steering through a provider extension.
    Extension,
    /// Mid-turn steering is unavailable and direction must be queued.
    #[default]
    Unsupported,
}

/// When changed provider settings take effect.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApplyTiming {
    /// Apply the setting to the currently running turn.
    Immediate,
    /// Apply the setting when the next turn starts.
    #[default]
    NextTurn,
    /// Apply the setting only after creating a new provider session.
    NewSession,
}

/// Optional operations supported by a provider driver.
///
/// [`Default`] is intentionally conservative: all Boolean capabilities are
/// false, steering is unsupported, approvals are empty, and setting changes
/// apply on the next turn. Callers must gate optional operations on this value
/// and degrade to their provider-neutral fallback.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DriverCapabilities {
    /// Whether a persisted provider session can be resumed.
    pub resume_session: bool,
    /// Whether an existing session can be compacted.
    pub compact_session: bool,
    /// Whether a running turn can be cancelled.
    pub cancel_turn: bool,
    /// Whether [`AgentDriver::settings_catalog`] is available.
    pub settings_catalog: bool,
    /// Whether loading a cold settings catalog starts a provider session.
    ///
    /// Session managers use this to serialize first-use settings with session
    /// creation and to avoid racing a fresh session against durable resume.
    pub settings_catalog_starts_session: bool,
    /// Whether the driver exposes a session-scoped provider command catalog.
    pub session_commands: bool,
    /// The driver's mid-turn steering mode.
    pub steering: SteeringSupport,
    /// When model, reasoning, or permission changes take effect.
    pub settings_apply_timing: ApplyTiming,
    /// Approval choices the provider can resolve.
    pub approvals: Vec<ApprovalOption>,
    /// Verified transport available for bridge-owned host tools.
    pub host_tools: HostToolTransport,
}

/// One provider-native slash command available in a specific agent session.
///
/// These commands are metadata for Inline's help and routing surfaces. They
/// are never registered as account-wide bot commands because ACP catalogs can
/// change per session and workspace.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DriverCommand {
    /// Lowercase command name without the leading slash.
    pub name: String,
    /// Concise human-readable provider description.
    pub description: String,
    /// Optional hint for required unstructured text after the command.
    ///
    /// This compatibility field remains populated for older bridge consumers.
    /// New code should use [`Self::input_shape`].
    pub input_hint: Option<String>,
    /// Typed command-input descriptor.
    #[serde(default)]
    pub input: DriverCommandInput,
}

/// Provider-neutral input shape for one session command.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DriverCommandInput {
    /// The command accepts no value.
    #[default]
    None,
    /// The command accepts unstructured text.
    Freeform {
        /// Concise composer/usage hint.
        hint: String,
        /// Whether omitting the text is invalid.
        required: bool,
    },
    /// The command accepts exactly one current catalog choice.
    SingleChoice {
        /// Bounded enabled and disabled choices in provider order.
        options: Vec<DriverCommandChoice>,
        /// Whether the provider defines a separate default choice.
        include_default: bool,
        /// Optional opaque generation used to invalidate stale cards.
        catalog_generation: Option<String>,
    },
}

/// One bounded provider-native command choice.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DriverCommandChoice {
    /// Stable opaque value sent back to the provider command.
    pub value: String,
    /// Human-readable button label.
    pub label: String,
    /// Optional bounded supporting text.
    pub description: Option<String>,
    /// Whether the choice is currently unavailable.
    pub disabled: bool,
    /// Optional bounded reason shown for an unavailable choice.
    pub disabled_reason: Option<String>,
}

impl DriverCommandChoice {
    /// Creates one safe bounded choice.
    pub fn new(value: impl AsRef<str>, label: impl AsRef<str>) -> Option<Self> {
        let value = value.as_ref().trim();
        if value.is_empty()
            || value.len() > MAX_DRIVER_COMMAND_CHOICE_VALUE_BYTES
            || value.chars().any(char::is_control)
        {
            return None;
        }
        let label =
            bounded_driver_command_text(label.as_ref(), MAX_DRIVER_COMMAND_CHOICE_LABEL_CHARS)?;
        Some(Self {
            value: value.to_string(),
            label,
            description: None,
            disabled: false,
            disabled_reason: None,
        })
    }

    /// Adds bounded display metadata and disabled state.
    pub fn with_metadata(
        mut self,
        description: Option<&str>,
        disabled: bool,
        disabled_reason: Option<&str>,
    ) -> Self {
        self.description = description.and_then(|value| {
            bounded_driver_command_text(value, MAX_DRIVER_COMMAND_CHOICE_DESCRIPTION_CHARS)
        });
        self.disabled = disabled;
        self.disabled_reason = disabled
            .then(|| {
                disabled_reason.and_then(|value| {
                    bounded_driver_command_text(value, MAX_DRIVER_COMMAND_CHOICE_DESCRIPTION_CHARS)
                })
            })
            .flatten();
        self
    }
}

impl DriverCommand {
    /// Creates one bounded command, rejecting names that Inline cannot parse.
    pub fn new(
        name: impl AsRef<str>,
        description: impl AsRef<str>,
        input_hint: Option<&str>,
    ) -> Option<Self> {
        let name = name.as_ref().trim();
        if name.is_empty()
            || name.len() > MAX_DRIVER_COMMAND_NAME_BYTES
            || !name
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
        {
            return None;
        }
        let description = bounded_driver_command_text(
            description.as_ref(),
            MAX_DRIVER_COMMAND_DESCRIPTION_CHARS,
        )?;
        let input_hint = input_hint.map(|hint| {
            bounded_driver_command_text(hint, MAX_DRIVER_COMMAND_HINT_CHARS)
                .unwrap_or_else(|| "input".to_string())
        });
        Some(Self {
            name: name.to_string(),
            description,
            input: input_hint
                .as_ref()
                .map(|hint| DriverCommandInput::Freeform {
                    hint: hint.clone(),
                    required: true,
                })
                .unwrap_or_default(),
            input_hint,
        })
    }

    /// Replaces the no/freeform input with a bounded single-choice catalog.
    pub fn with_single_choice(
        mut self,
        options: impl IntoIterator<Item = DriverCommandChoice>,
        include_default: bool,
        catalog_generation: Option<&str>,
    ) -> Option<Self> {
        let mut bounded = Vec::new();
        for option in options {
            if bounded.len() == MAX_DRIVER_COMMAND_CHOICES {
                break;
            }
            if !bounded
                .iter()
                .any(|existing: &DriverCommandChoice| existing.value == option.value)
            {
                bounded.push(option);
            }
        }
        if bounded.iter().all(|option| option.disabled) {
            return None;
        }
        let catalog_generation = catalog_generation.and_then(|value| {
            let value = value.trim();
            (!value.is_empty()
                && value.len() <= MAX_DRIVER_COMMAND_GENERATION_BYTES
                && !value.chars().any(char::is_control))
            .then(|| value.to_string())
        });
        self.input_hint = None;
        self.input = DriverCommandInput::SingleChoice {
            options: bounded,
            include_default,
            catalog_generation,
        };
        Some(self)
    }

    /// Returns the typed input shape, adapting legacy `input_hint` values.
    pub fn input_shape(&self) -> DriverCommandInput {
        match (&self.input, &self.input_hint) {
            (DriverCommandInput::None, Some(hint)) => DriverCommandInput::Freeform {
                hint: hint.clone(),
                required: true,
            },
            (input, _) => input.clone(),
        }
    }

    /// Bounds and de-duplicates a provider catalog while preserving order.
    pub fn catalog(commands: impl IntoIterator<Item = Self>) -> Vec<Self> {
        let mut bounded = Vec::new();
        for command in commands {
            if bounded.len() == MAX_DRIVER_COMMANDS {
                break;
            }
            if !bounded
                .iter()
                .any(|existing: &Self| existing.name == command.name)
            {
                bounded.push(command);
            }
        }
        bounded
    }
}

fn bounded_driver_command_text(value: &str, maximum_chars: usize) -> Option<String> {
    if value.chars().any(char::is_control) {
        return None;
    }
    bounded_activity_text(value, maximum_chars)
}

/// Provider-authenticated options exposed in Inline's settings UI.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DriverSettingsCatalog {
    /// Models available to the current provider account and workspace.
    pub models: Vec<DriverModelOption>,
    /// Permission modes available to the current provider account.
    pub permissions: Vec<DriverSettingOption>,
    /// Effective permission mode when a conversation has no explicit selection.
    #[serde(default)]
    pub default_permissions: Option<String>,
}

/// One provider model and its supported reasoning choices.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DriverModelOption {
    /// Opaque provider model identifier returned unchanged on selection.
    pub value: String,
    /// Human-readable model name.
    pub label: String,
    /// Optional concise provider description.
    pub description: Option<String>,
    /// Reasoning modes supported by this model.
    pub reasoning: Vec<DriverSettingOption>,
    /// Provider-selected default reasoning mode, when declared.
    pub default_reasoning: Option<String>,
    /// Whether this is the provider-selected default model.
    pub is_default: bool,
}

/// One opaque provider setting choice.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DriverSettingOption {
    /// Opaque provider identifier returned unchanged on selection.
    pub value: String,
    /// Human-readable option name.
    pub label: String,
    /// Optional concise provider description.
    pub description: Option<String>,
    /// Whether the provider currently prevents selecting this option.
    pub disabled: bool,
}

/// Approval choices a driver may present to an operator.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalOption {
    /// Allow only the pending operation.
    ApproveOnce,
    /// Allow the operation for the remainder of the provider session.
    ApproveForSession,
    /// Reject the pending operation without necessarily ending the turn.
    Reject,
    /// Reject the pending operation and cancel its turn.
    CancelTurn,
    /// A provider-defined choice whose opaque ID must be preserved.
    ProviderChoice {
        /// Opaque provider option identifier.
        option_id: String,
        /// Human-readable provider option name.
        label: String,
    },
}

/// Operator decision sent back to a provider approval request.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalDecision {
    /// Allow only the pending operation.
    ApproveOnce,
    /// Allow the operation for the remainder of the provider session.
    ApproveForSession,
    /// Reject the pending operation.
    Reject,
    /// Reject the operation and cancel its turn.
    CancelTurn,
    /// Select a provider-defined choice by its opaque identifier.
    ProviderChoice {
        /// Opaque provider option identifier.
        option_id: String,
    },
}

/// Inputs used to create a new provider session.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionSpec {
    /// Canonical local workspace used as the provider process working directory.
    pub cwd: PathBuf,
}

/// Provider history replay requested while resuming a session.
///
/// The default is [`None`](Self::None): the bridge never reconstructs or
/// replays provider history unless a driver explicitly supports a cursor.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SessionReplay {
    /// Resume provider-owned history without bridge-side replay.
    #[default]
    None,
    /// Replay provider-owned history beginning at an opaque cursor.
    From {
        /// Provider-owned replay cursor.
        cursor: String,
    },
}

/// Inputs used to resume a persisted provider session.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResumeSessionSpec {
    /// Persisted provider session identifier.
    pub session_id: ProviderSessionId,
    /// Canonical local workspace for the resumed session.
    pub cwd: PathBuf,
    /// Provider-owned history replay behavior.
    pub replay: SessionReplay,
}

/// One normalized user direction sent to a provider.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnInput {
    /// Plain-text user direction.
    pub text: String,
    /// Ordered media and file descriptors supplied with this direction.
    #[serde(default)]
    pub attachments: Vec<InputAttachment>,
    /// Optional stable client identity for provider-side deduplication.
    pub client_message_id: Option<String>,
}

/// Optional provider settings applied when a turn starts.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnOptions {
    /// Workspace override for this turn.
    pub cwd: Option<PathBuf>,
    /// Opaque model identifier selected from the settings catalog.
    pub model: Option<String>,
    /// Opaque reasoning identifier selected for the model.
    pub reasoning: Option<String>,
    /// Opaque permission-mode identifier selected from the settings catalog.
    pub permissions: Option<String>,
}

/// Provider approval request associated with a running turn.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalRequest {
    /// Provider-owned approval identity.
    pub approval_id: String,
    /// Turn blocked on this request.
    pub turn_id: TurnId,
    /// Concise human-readable description of the requested operation.
    pub summary: String,
    /// Optional command preview suitable for bounded operator display.
    pub command: Option<String>,
    /// Optional local directory associated with the operation.
    pub cwd: Option<PathBuf>,
    /// Decisions accepted by the provider for this request.
    pub options: Vec<ApprovalOption>,
}

/// One predefined response to a provider question.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionOption {
    /// Human-readable option name.
    pub label: String,
    /// Optional concise explanation of the option.
    pub description: Option<String>,
}

/// One provider question requiring operator input.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Question {
    /// Provider-owned question identity.
    pub question_id: String,
    /// Short heading displayed above the prompt.
    pub header: String,
    /// Human-readable prompt.
    pub prompt: String,
    /// Predefined response choices.
    pub options: Vec<QuestionOption>,
    /// Whether a free-form response is accepted.
    pub allows_other: bool,
    /// Whether the answer contains secret material and must not be persisted or echoed.
    pub is_secret: bool,
}

/// A group of provider questions blocking a running turn.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionRequest {
    /// Provider-owned request identity.
    pub request_id: String,
    /// Turn blocked on this request.
    pub turn_id: TurnId,
    /// Questions to present together.
    pub questions: Vec<Question>,
    /// Optional provider deadline for automatic resolution.
    pub auto_resolution_ms: Option<u64>,
}

/// Operator answers for one provider question.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionAnswer {
    /// Provider-owned question identity.
    pub question_id: String,
    /// Selected labels or free-form answers.
    pub answers: Vec<String>,
}

/// One local file changed by a provider turn.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileChange {
    /// Local path changed by the provider.
    pub path: PathBuf,
    /// Optional concise description of the change.
    pub summary: Option<String>,
}

/// Stable semantic category for an activity reported by a local coding agent.
///
/// This is deliberately about the work being performed, rather than a
/// provider's internal item type. Consumers can pick their own icons and
/// wording without inspecting provider-specific payloads.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivitySemanticKind {
    /// Reading a local file or other local data.
    Read,
    /// Creating or modifying files.
    Edit,
    /// Removing files.
    Delete,
    /// Moving or renaming files.
    Move,
    /// Searching local or remote information.
    Search,
    /// Running a command or executable tool.
    Execute,
    /// Fetching an external resource.
    Fetch,
    /// A high-level reasoning state without its private reasoning content.
    Think,
    /// A provider activity that does not have a more precise stable category.
    Other,
}

/// Lifecycle state for a provider activity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivityStatus {
    /// The activity has been described but is not running yet.
    Pending,
    /// The activity is running or receiving progress.
    InProgress,
    /// The activity finished successfully.
    Completed,
    /// The activity was explicitly declined before it could complete.
    Declined,
    /// The activity was cancelled before it could complete.
    Cancelled,
    /// The activity failed without a more precise terminal lifecycle state.
    Failed,
}

/// A replace-all snapshot for one provider activity.
///
/// `activity_id` is opaque and stable only within its provider session. The
/// bridge never treats it as user-facing text. Drivers must keep title/detail
/// concise and omit raw reasoning, command output, and arbitrary tool payloads.
/// `paths` contains only safe, absolute local paths suitable for a future host
/// local-file affordance.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActivityUpsert {
    /// Provider-owned opaque activity identity.
    pub activity_id: String,
    /// Provider-neutral semantic category.
    pub kind: ActivitySemanticKind,
    /// Current lifecycle state.
    pub status: ActivityStatus,
    /// Concise human-readable activity title.
    pub title: String,
    /// Optional concise, display-safe progress detail.
    pub detail: Option<String>,
    /// Safe local paths relevant to the activity.
    pub paths: Vec<PathBuf>,
    /// Command exit code when the provider authoritatively reports one.
    pub exit_code: Option<i32>,
}

impl ActivityUpsert {
    /// Creates a bounded, display-safe activity snapshot.
    ///
    /// Returns `None` when a provider did not supply a usable opaque identity
    /// or title. IDs are never truncated because that could merge unrelated
    /// provider activities; display text and paths are bounded instead.
    pub fn new(
        activity_id: impl Into<String>,
        kind: ActivitySemanticKind,
        status: ActivityStatus,
        title: impl AsRef<str>,
    ) -> Option<Self> {
        let activity_id = activity_id.into();
        if !safe_activity_id(&activity_id) {
            return None;
        }
        let title = bounded_activity_text(title.as_ref(), MAX_ACTIVITY_TITLE_CHARS)?;
        Some(Self {
            activity_id,
            kind,
            status,
            title,
            detail: None,
            paths: Vec::new(),
            exit_code: None,
        })
    }

    /// Adds a bounded concise detail, dropping an empty or unsafe value.
    #[must_use]
    pub fn with_detail(mut self, detail: impl AsRef<str>) -> Self {
        self.detail = bounded_activity_text(detail.as_ref(), MAX_ACTIVITY_DETAIL_CHARS);
        self
    }

    /// Replaces paths with safe, absolute local paths, capped for display.
    #[must_use]
    pub fn with_paths(mut self, paths: impl IntoIterator<Item = PathBuf>) -> Self {
        self.paths = paths
            .into_iter()
            .filter(|path| safe_activity_path(path.as_path()))
            .take(MAX_ACTIVITY_PATHS)
            .collect();
        self
    }

    /// Adds an authoritatively reported process exit code.
    #[must_use]
    pub fn with_exit_code(mut self, exit_code: Option<i32>) -> Self {
        self.exit_code = exit_code;
        self
    }
}

fn safe_activity_id(value: &str) -> bool {
    !value.trim().is_empty()
        && value.len() <= MAX_ACTIVITY_ID_BYTES
        && !value.chars().any(char::is_control)
}

fn bounded_activity_text(value: &str, maximum_chars: usize) -> Option<String> {
    let normalized = value.split_whitespace().collect::<Vec<_>>().join(" ");
    if normalized.is_empty() {
        return None;
    }
    Some(normalized.chars().take(maximum_chars).collect())
}

fn safe_activity_path(path: &Path) -> bool {
    let value = path.as_os_str().to_string_lossy();
    path.is_absolute()
        && value.len() <= MAX_ACTIVITY_PATH_BYTES
        && !value.chars().any(char::is_control)
        && !path
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
}

/// Provider-neutral execution-plan step state.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanStepStatus {
    /// The step has not started.
    Pending,
    /// The provider is currently working on the step.
    InProgress,
    /// The step finished successfully.
    Completed,
}

/// One human-readable step in a replace-all execution-plan snapshot.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanStep {
    /// Concise step text. Stable ACP v1 and Codex do not provide a shared step ID.
    pub text: String,
    /// Current execution state.
    pub status: PlanStepStatus,
}

/// Terminal outcome of a provider turn.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TurnOutcome {
    /// The provider completed the requested work.
    Completed,
    /// The turn stopped before completing, usually after cancellation.
    Interrupted,
    /// The turn terminated with an error.
    Failed,
    /// The provider connection epoch ended before the turn completed.
    ConnectionLost,
    /// The local provider needs the user to authenticate before it can continue.
    AuthenticationRequired,
}

/// Optional provider-authoritative cumulative timing for one turn.
///
/// Drivers omit timing they cannot prove. Presentation falls back to the
/// bridge's monotonic measurement for missing, negative, or absurd values.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnTiming {
    /// Provider-reported cumulative duration in milliseconds.
    pub provider_duration_ms: Option<u64>,
}

impl TurnTiming {
    const MAX_PROVIDER_DURATION_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

    /// Converts a signed wire value without allowing negative durations.
    pub fn from_provider_duration_ms(duration_ms: Option<i64>) -> Self {
        Self {
            provider_duration_ms: duration_ms.and_then(|value| u64::try_from(value).ok()),
        }
    }

    /// Prefers a plausible provider duration and otherwise uses local monotonic
    /// elapsed time. Sub-second precision is retained until display formatting.
    pub fn resolve(self, local_elapsed: Duration) -> Duration {
        self.provider_duration_ms
            .filter(|duration| *duration <= Self::MAX_PROVIDER_DURATION_MS)
            .map(Duration::from_millis)
            .unwrap_or(local_elapsed)
    }
}

/// A provider-authoritative signal that local authentication is required.
///
/// The message is concise, safe to present in chat, and tells the user how to
/// resume. It must not contain provider request or credential data.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthenticationRequired {
    /// Safe, actionable login guidance supplied by the driver.
    pub message: String,
}

/// Normalized stream events emitted by a provider turn.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AgentEvent {
    /// The provider assigned an identity to the new turn.
    TurnStarted {
        /// Provider-normalized turn identity.
        turn_id: TurnId,
    },
    /// Incremental assistant text appended to the visible response.
    AgentTextDelta {
        /// Turn producing this output.
        turn_id: TurnId,
        /// Text fragment to append.
        text: String,
    },
    /// Authoritative complete assistant text for the visible response.
    AgentTextCompleted {
        /// Turn producing this output.
        turn_id: TurnId,
        /// Complete response text.
        text: String,
    },
    /// Concise human-readable progress suitable for a chat status message.
    Activity {
        /// Turn producing this activity.
        turn_id: TurnId,
        /// Provider-neutral status summary.
        summary: String,
    },
    /// Complete replacement snapshot for one provider activity. Later events
    /// with the same `(turn_id, activity_id)` supersede this snapshot.
    ActivityUpsert {
        /// Turn producing this activity.
        turn_id: TurnId,
        /// Complete current activity snapshot.
        activity: ActivityUpsert,
    },
    /// Complete current execution-plan snapshot. Each event replaces the
    /// previous plan for this turn rather than appending transcript entries.
    PlanUpdated {
        /// Turn whose plan changed.
        turn_id: TurnId,
        /// Optional concise provider explanation for the replacement.
        explanation: Option<String>,
        /// Ordered plan steps. Neither text nor position is a durable identity.
        steps: Vec<PlanStep>,
    },
    /// An operation requiring operator approval.
    ApprovalRequested(ApprovalRequest),
    /// A previously requested approval was withdrawn by the provider before
    /// the operator responded.
    ApprovalClosed {
        /// Turn that owned the request.
        turn_id: TurnId,
        /// Provider-owned approval identity.
        approval_id: String,
    },
    /// Questions requiring operator input.
    QuestionRequested(QuestionRequest),
    /// Files changed so far by a turn.
    FilesChanged {
        /// Turn responsible for the changes.
        turn_id: TurnId,
        /// Changed files and optional summaries.
        files: Vec<FileChange>,
    },
    /// An immutable local artifact produced by the turn and ready for secure
    /// host delivery.
    OutputAttachment {
        /// Turn responsible for the artifact.
        turn_id: TurnId,
        /// Verified artifact descriptor. Payload bytes never enter the event
        /// queue or bridge database.
        attachment: OutputAttachment,
    },
    /// Terminal event for a provider turn.
    TurnCompleted {
        /// Completed turn identity.
        turn_id: TurnId,
        /// Terminal classification.
        outcome: TurnOutcome,
        /// Optional concise error safe for operator presentation.
        error: Option<String>,
        /// Provider timing when the driver can report it authoritatively.
        #[serde(default)]
        timing: TurnTiming,
    },
}

/// Bounded asynchronous receiver for normalized provider events.
///
/// Text, activity, activity-upsert, and replace-all plan snapshots may be coalesced under
/// pressure. Approval, question, and terminal control events are never
/// silently discarded; control-only overflow terminates the stream with
/// [`DriverError::Protocol`].
pub struct AgentEventReceiver {
    inner: Arc<Mutex<AgentEventQueue>>,
}

impl AgentEventReceiver {
    /// Creates an event channel with at least one buffered entry.
    pub fn channel(capacity: usize) -> (AgentEventSender, Self) {
        let inner = Arc::new(Mutex::new(AgentEventQueue {
            entries: VecDeque::with_capacity(capacity.max(1)),
            capacity: capacity.max(1),
            sender_count: 1,
            receiver_alive: true,
            accepting: true,
            waker: None,
        }));
        (
            AgentEventSender {
                inner: inner.clone(),
            },
            Self { inner },
        )
    }

    /// Creates an event channel with the bridge's bounded default capacity.
    pub fn default_channel() -> (AgentEventSender, Self) {
        Self::channel(DEFAULT_AGENT_EVENT_CAPACITY)
    }
}

impl Drop for AgentEventReceiver {
    fn drop(&mut self) {
        self.inner
            .lock()
            .expect("agent event queue poisoned")
            .receiver_alive = false;
    }
}

impl Stream for AgentEventReceiver {
    type Item = DriverResult<AgentEvent>;

    fn poll_next(self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let mut queue = self.inner.lock().expect("agent event queue poisoned");
        if let Some(event) = queue.entries.pop_front() {
            return Poll::Ready(Some(event));
        }
        if queue.sender_count == 0 || !queue.accepting {
            return Poll::Ready(None);
        }
        queue.waker = Some(context.waker().clone());
        Poll::Pending
    }
}

#[derive(Debug)]
struct AgentEventQueue {
    entries: VecDeque<DriverResult<AgentEvent>>,
    capacity: usize,
    sender_count: usize,
    receiver_alive: bool,
    accepting: bool,
    waker: Option<std::task::Waker>,
}

#[derive(Debug)]
/// Non-blocking sender paired with [`AgentEventReceiver`].
pub struct AgentEventSender {
    inner: Arc<Mutex<AgentEventQueue>>,
}

impl Clone for AgentEventSender {
    fn clone(&self) -> Self {
        self.inner
            .lock()
            .expect("agent event queue poisoned")
            .sender_count += 1;
        Self {
            inner: self.inner.clone(),
        }
    }
}

impl Drop for AgentEventSender {
    fn drop(&mut self) {
        let wake = {
            let mut queue = self.inner.lock().expect("agent event queue poisoned");
            queue.sender_count = queue.sender_count.saturating_sub(1);
            (queue.sender_count == 0)
                .then(|| queue.waker.take())
                .flatten()
        };
        if let Some(waker) = wake {
            waker.wake();
        }
    }
}

impl AgentEventSender {
    /// Adds a normalized event without blocking the provider reader loop.
    /// Text deltas, activity, activity upserts, and plan snapshots are coalesced under pressure.
    /// If control events alone fill the queue, the stream fails closed with an
    /// explicit overflow error instead of silently losing an approval or terminal event.
    pub fn send(&self, event: DriverResult<AgentEvent>) -> bool {
        let wake = {
            let mut queue = self.inner.lock().expect("agent event queue poisoned");
            if !queue.receiver_alive || !queue.accepting {
                return false;
            }
            match event {
                Ok(event) => enqueue_agent_event(&mut queue, event),
                Err(error) => enqueue_control(&mut queue, Err(error)),
            }
            queue.waker.take()
        };
        if let Some(waker) = wake {
            waker.wake();
        }
        true
    }
}

fn enqueue_agent_event(queue: &mut AgentEventQueue, event: AgentEvent) {
    let event = match event {
        AgentEvent::AgentTextDelta { turn_id, text } => {
            let mut bounded = String::new();
            append_bounded_delta(&mut bounded, &text);
            AgentEvent::AgentTextDelta {
                turn_id,
                text: bounded,
            }
        }
        AgentEvent::AgentTextCompleted { turn_id, text } => {
            let mut bounded = String::new();
            append_bounded_delta(&mut bounded, &text);
            AgentEvent::AgentTextCompleted {
                turn_id,
                text: bounded,
            }
        }
        AgentEvent::FilesChanged { turn_id, files } => AgentEvent::FilesChanged {
            turn_id,
            files: files
                .into_iter()
                .filter_map(bounded_file_change)
                .take(MAX_FILE_CHANGES)
                .collect(),
        },
        event => event,
    };
    if let AgentEvent::AgentTextDelta { turn_id, text } = &event
        && let Some(Ok(AgentEvent::AgentTextDelta {
            turn_id: pending_turn,
            text: pending_text,
        })) = queue.entries.back_mut()
        && pending_turn == turn_id
    {
        append_bounded_delta(pending_text, text);
        return;
    }
    if let AgentEvent::Activity { turn_id, summary } = &event
        && let Some(Ok(AgentEvent::Activity {
            turn_id: _,
            summary: pending_summary,
        })) = queue.entries.iter_mut().rev().find(|entry| {
            matches!(
                entry,
                Ok(AgentEvent::Activity {
                    turn_id: candidate,
                    ..
                }) if candidate == turn_id
            )
        })
    {
        pending_summary.clone_from(summary);
        return;
    }
    if let AgentEvent::ActivityUpsert { turn_id, activity } = &event
        && let Some(pending) = queue.entries.iter_mut().rev().find(|entry| {
            matches!(
                entry,
                Ok(AgentEvent::ActivityUpsert {
                    turn_id: candidate_turn,
                    activity: candidate_activity,
                }) if candidate_turn == turn_id && candidate_activity.activity_id == activity.activity_id
            )
        })
    {
        *pending = Ok(event);
        return;
    }
    if let AgentEvent::PlanUpdated { turn_id, .. } = &event
        && let Some(pending) = queue.entries.iter_mut().rev().find(|entry| {
            matches!(
                entry,
                Ok(AgentEvent::PlanUpdated {
                    turn_id: candidate,
                    ..
                }) if candidate == turn_id
            )
        })
    {
        *pending = Ok(event);
        return;
    }
    if let AgentEvent::FilesChanged { turn_id, files } = &event
        && let Some(Ok(AgentEvent::FilesChanged {
            turn_id: pending_turn,
            files: pending_files,
        })) = queue.entries.iter_mut().rev().find(|entry| {
            matches!(
                entry,
                Ok(AgentEvent::FilesChanged {
                    turn_id: candidate,
                    ..
                }) if candidate == turn_id
            )
        })
        && pending_turn == turn_id
    {
        for file in files {
            if let Some(existing) = pending_files
                .iter_mut()
                .find(|existing| existing.path == file.path)
            {
                if existing.summary.is_none() {
                    existing.summary.clone_from(&file.summary);
                }
            } else if pending_files.len() < MAX_FILE_CHANGES {
                pending_files.push(file.clone());
            }
        }
        return;
    }
    if queue.entries.len() < queue.capacity {
        queue.entries.push_back(Ok(event));
        return;
    }
    if let Some(position) = queue.entries.iter().position(is_coalescible_event) {
        queue.entries.remove(position);
        queue.entries.push_back(Ok(event));
        return;
    }
    fail_overflow(queue);
}

fn enqueue_control(queue: &mut AgentEventQueue, event: DriverResult<AgentEvent>) {
    if queue.entries.len() == queue.capacity {
        if let Some(position) = queue.entries.iter().position(is_coalescible_event) {
            queue.entries.remove(position);
        } else {
            fail_overflow(queue);
            return;
        }
    }
    queue.entries.push_back(event);
}

fn fail_overflow(queue: &mut AgentEventQueue) {
    queue.entries.clear();
    queue.entries.push_back(Err(DriverError::Protocol(
        "agent event control queue overflowed".to_string(),
    )));
    queue.accepting = false;
}

fn is_coalescible_event(event: &DriverResult<AgentEvent>) -> bool {
    matches!(
        event,
        Ok(AgentEvent::AgentTextDelta { .. }
            | AgentEvent::Activity { .. }
            | AgentEvent::ActivityUpsert { .. }
            | AgentEvent::PlanUpdated { .. }
            | AgentEvent::FilesChanged { .. })
    )
}

fn bounded_file_change(mut file: FileChange) -> Option<FileChange> {
    if !safe_file_change_path(&file.path) {
        return None;
    }
    file.summary = file
        .summary
        .as_deref()
        .and_then(safe_file_change_summary)
        .map(str::to_string);
    Some(file)
}

fn safe_file_change_path(path: &Path) -> bool {
    let value = path.as_os_str().to_string_lossy();
    !value.is_empty()
        && value.len() <= MAX_FILE_CHANGE_PATH_BYTES
        && !value.chars().any(char::is_control)
        && !path
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
}

fn safe_file_change_summary(summary: &str) -> Option<&'static str> {
    match summary.trim().to_ascii_lowercase().as_str() {
        "add" | "added" | "create" | "created" => Some("created"),
        "change" | "changed" | "modify" | "modified" | "update" | "updated" => Some("updated"),
        "delete" | "deleted" | "remove" | "removed" => Some("deleted"),
        "move" | "moved" | "rename" | "renamed" => Some("renamed"),
        _ => None,
    }
}

fn append_bounded_delta(target: &mut String, delta: &str) {
    if target.ends_with(TRUNCATED_DELTA_MARKER) {
        return;
    }
    let remaining = MAX_COALESCED_TEXT_BYTES.saturating_sub(target.len());
    if delta.len() <= remaining {
        target.push_str(delta);
        return;
    }
    let mut boundary = remaining.min(delta.len());
    while boundary > 0 && !delta.is_char_boundary(boundary) {
        boundary -= 1;
    }
    target.push_str(&delta[..boundary]);
    target.push_str(TRUNCATED_DELTA_MARKER);
}

/// Running provider turn and its normalized event stream.
pub struct StartedTurn {
    /// Provider-normalized turn identity.
    pub turn_id: TurnId,
    /// Bounded stream of events for the turn.
    pub events: AgentEventReceiver,
}

impl std::fmt::Debug for StartedTurn {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("StartedTurn")
            .field("turn_id", &self.turn_id)
            .field("events", &"<event stream>")
            .finish()
    }
}

/// Provider-neutral interface implemented by each local coding-agent adapter.
///
/// Optional operations must be advertised through [`DriverCapabilities`]. A
/// caller must not infer support from the presence of a trait method. Default
/// optional methods fail closed with [`DriverError::Unsupported`].
pub trait AgentDriver: Send + Sync {
    /// Returns the driver's current, conservative capability declaration.
    fn capabilities(&self) -> DriverCapabilities;

    /// Returns the exact provider-visible correlation used for one Inline
    /// input, when the provider preserves it in later session history.
    fn session_input_correlation(
        &self,
        _direction_id: &crate::DirectionId,
    ) -> Option<crate::SessionInputCorrelation> {
        None
    }

    /// Installs a bridge-owned host-tool catalog for this driver epoch.
    /// Drivers must fail closed unless their advertised transport can carry it.
    fn configure_host_tools(&self, _configuration: HostToolConfiguration) -> DriverResult<()> {
        Err(DriverError::Unsupported("host tools"))
    }

    /// Returns provider-authenticated model, reasoning, and permissions
    /// choices for the selected workspace. Drivers that advertise
    /// `settings_catalog` must preserve provider option IDs exactly. The
    /// default fails closed with [`DriverError::Unsupported`].
    fn settings_catalog<'a>(
        &'a self,
        _cwd: &'a std::path::Path,
    ) -> DriverFuture<'a, DriverSettingsCatalog> {
        Box::pin(async { Err(DriverError::Unsupported("settings catalog")) })
    }

    /// Returns the current provider-native command catalog for one session.
    ///
    /// Callers invoke this only when `session_commands` is advertised. The
    /// default fails closed so a provider command is never guessed from text.
    fn session_commands<'a>(
        &'a self,
        _session_id: &'a ProviderSessionId,
    ) -> DriverFuture<'a, Vec<DriverCommand>> {
        Box::pin(async { Err(DriverError::Unsupported("session commands")) })
    }

    /// Creates a new provider-owned session rooted at the requested workspace.
    fn start_session<'a>(&'a self, spec: SessionSpec) -> DriverFuture<'a, ProviderSessionId>;

    /// Reconnects to an existing provider session.
    ///
    /// Callers invoke this only when `resume_session` is advertised. A missing
    /// session must return [`DriverError::InvalidSession`]; transient provider
    /// failures must preserve the durable binding and return another variant.
    fn resume_session<'a>(&'a self, spec: ResumeSessionSpec) -> DriverFuture<'a, ()>;

    /// Starts one turn in an initialized provider session.
    fn start_turn<'a>(
        &'a self,
        session_id: &'a ProviderSessionId,
        input: TurnInput,
        options: TurnOptions,
    ) -> DriverFuture<'a, StartedTurn>;

    /// Applies operator direction to a running turn.
    ///
    /// Callers invoke this only when [`DriverCapabilities::steering`] is not
    /// [`SteeringSupport::Unsupported`].
    fn steer_turn<'a>(
        &'a self,
        session_id: &'a ProviderSessionId,
        turn_id: &'a TurnId,
        input: TurnInput,
    ) -> DriverFuture<'a, ()>;

    /// Cancels a turn and returns only after the provider can no longer execute it.
    ///
    /// This operation is idempotent for a turn that already reached a terminal
    /// provider state. Callers may treat `Ok(())` as the terminal stop barrier
    /// even when a provider races or omits its terminal event. Drivers must end
    /// their owned provider epoch before returning an ambiguous failure.
    /// Callers invoke this only when `cancel_turn` is advertised.
    fn cancel_turn<'a>(
        &'a self,
        session_id: &'a ProviderSessionId,
        turn_id: &'a TurnId,
    ) -> DriverFuture<'a, ()>;

    /// Compacts provider-owned session context.
    ///
    /// Callers invoke this only when `compact_session` is advertised.
    fn compact_session<'a>(&'a self, session_id: &'a ProviderSessionId) -> DriverFuture<'a, ()>;

    /// Resolves an outstanding provider approval with an advertised decision.
    fn resolve_approval<'a>(
        &'a self,
        approval_id: &'a str,
        decision: ApprovalDecision,
    ) -> DriverFuture<'a, ()>;

    /// Resolves an outstanding provider question request.
    ///
    /// The default fails closed with [`DriverError::Unsupported`]. Drivers
    /// should override it only when they can preserve provider question IDs and
    /// secret-answer handling.
    fn resolve_question<'a>(
        &'a self,
        _request_id: &'a str,
        _answers: Vec<QuestionAnswer>,
    ) -> DriverFuture<'a, ()> {
        Box::pin(async { Err(DriverError::Unsupported("questions")) })
    }

    /// Stops provider resources owned by this driver instance.
    fn shutdown<'a>(&'a self) -> DriverFuture<'a, ()>;
}

/// Stable error classification returned across the provider-driver boundary.
#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum DriverError {
    /// The provider or adapter does not implement the requested capability.
    #[error("driver capability is unsupported: {0}")]
    Unsupported(&'static str),
    /// The provider process or required external dependency is unavailable.
    #[error("driver is unavailable: {0}")]
    Unavailable(String),
    /// The provider violated or could not negotiate its protocol contract.
    #[error("driver protocol error: {0}")]
    Protocol(String),
    /// The provider process exited while serving a request or turn.
    #[error("driver process exited: {0}")]
    ProcessExited(String),
    /// The caller must discard this provider epoch even when process
    /// termination could not be confirmed. Reusing it could repeat or
    /// misroute a mutation with an ambiguous provider outcome.
    #[error("driver connection epoch ended: {0}")]
    EpochEnded(String),
    /// The provider understood and rejected the request.
    #[error("driver request was rejected: {0}")]
    Rejected(String),
    /// The durable provider session is valid but another provider client owns
    /// its exclusive execution lease. Callers must preserve the binding and
    /// let the user release that other client before retrying.
    #[error("driver session is active elsewhere: {0}")]
    SessionBusy(String),
    /// The local provider authoritatively requires user authentication.
    #[error("driver authentication is required: {}", .0.message)]
    AuthenticationRequired(AuthenticationRequired),
    /// The persisted provider session no longer exists or can no longer be resumed.
    ///
    /// Drivers must only return this when the provider has authoritatively rejected
    /// the session identity itself. Callers may replace the durable binding with a
    /// fresh session; they must not use it for an unavailable process, timeout, or
    /// generic request rejection.
    #[error("driver session is invalid: {0}")]
    InvalidSession(String),
    /// A retryable provider failure that does not invalidate durable state.
    #[error("driver operation failed transiently: {0}")]
    Transient(String),
}

impl DriverError {
    /// Whether this error seals the current provider connection epoch.
    pub const fn ends_epoch(&self) -> bool {
        matches!(self, Self::ProcessExited(_) | Self::EpochEnded(_))
    }
}

#[cfg(test)]
mod tests {
    use futures_util::StreamExt;

    use super::*;

    fn turn_id() -> TurnId {
        TurnId::new("turn-1").expect("turn id")
    }

    #[derive(Debug)]
    struct NeverCalledHostToolHandler;

    impl HostToolHandler for NeverCalledHostToolHandler {
        fn call<'a>(&'a self, _call: HostToolCall) -> HostToolFuture<'a> {
            Box::pin(async { HostToolResult::failure("not called") })
        }
    }

    fn host_tools(specs: Vec<HostToolSpec>) -> HostToolConfiguration {
        HostToolConfiguration {
            specs,
            handler: Arc::new(NeverCalledHostToolHandler),
        }
    }

    #[test]
    fn host_tool_fingerprint_is_order_stable_and_ignores_copy() {
        let first = HostToolSpec {
            name: "get_chat".to_string(),
            description: "First description".to_string(),
            input_schema: json!({
                "type": "object",
                "properties": {"chat_id": {"type": "integer"}},
                "required": ["chat_id"],
                "additionalProperties": false
            }),
            read_only: true,
        };
        let second = HostToolSpec {
            name: "create_chat".to_string(),
            description: "Create".to_string(),
            input_schema: json!({"additionalProperties": false, "type": "object"}),
            read_only: false,
        };
        let mut copy_changed = first.clone();
        copy_changed.description = "Improved description".to_string();

        assert_eq!(
            host_tools(vec![first.clone(), second.clone()]).compatibility_fingerprint(),
            host_tools(vec![second, copy_changed]).compatibility_fingerprint()
        );

        let mut schema_changed = first;
        schema_changed.input_schema["required"] = json!([]);
        assert_ne!(
            host_tools(vec![schema_changed]).compatibility_fingerprint(),
            host_tools(vec![HostToolSpec {
                name: "get_chat".to_string(),
                description: "irrelevant".to_string(),
                input_schema: json!({
                    "type": "object",
                    "properties": {"chat_id": {"type": "integer"}},
                    "required": ["chat_id"],
                    "additionalProperties": false
                }),
                read_only: true,
            }])
            .compatibility_fingerprint()
        );
    }

    #[tokio::test]
    async fn bounded_channel_coalesces_adjacent_text_deltas() {
        let (sender, mut receiver) = AgentEventReceiver::channel(2);
        assert!(sender.send(Ok(AgentEvent::AgentTextDelta {
            turn_id: turn_id(),
            text: "Hello".to_string(),
        })));
        assert!(sender.send(Ok(AgentEvent::AgentTextDelta {
            turn_id: turn_id(),
            text: " world".to_string(),
        })));

        assert!(matches!(
            receiver.next().await,
            Some(Ok(AgentEvent::AgentTextDelta { text, .. })) if text == "Hello world"
        ));
    }

    #[tokio::test]
    async fn bounded_channel_caps_a_single_oversized_text_delta() {
        let (sender, mut receiver) = AgentEventReceiver::channel(2);
        assert!(sender.send(Ok(AgentEvent::AgentTextDelta {
            turn_id: turn_id(),
            text: "x".repeat(MAX_COALESCED_TEXT_BYTES * 2),
        })));

        let Some(Ok(AgentEvent::AgentTextDelta { text, .. })) = receiver.next().await else {
            panic!("expected bounded text delta");
        };
        assert!(text.len() <= MAX_COALESCED_TEXT_BYTES + TRUNCATED_DELTA_MARKER.len());
        assert!(text.ends_with(TRUNCATED_DELTA_MARKER));
    }

    #[tokio::test]
    async fn bounded_channel_caps_a_single_oversized_completed_text() {
        let (sender, mut receiver) = AgentEventReceiver::channel(2);
        assert!(sender.send(Ok(AgentEvent::AgentTextCompleted {
            turn_id: turn_id(),
            text: "x".repeat(MAX_COALESCED_TEXT_BYTES * 2),
        })));

        let Some(Ok(AgentEvent::AgentTextCompleted { text, .. })) = receiver.next().await else {
            panic!("expected bounded completed text");
        };
        assert!(text.len() <= MAX_COALESCED_TEXT_BYTES + TRUNCATED_DELTA_MARKER.len());
        assert!(text.ends_with(TRUNCATED_DELTA_MARKER));
    }

    #[tokio::test]
    async fn bounded_channel_replaces_plan_snapshots_for_the_same_turn() {
        let (sender, mut receiver) = AgentEventReceiver::channel(2);
        assert!(sender.send(Ok(AgentEvent::PlanUpdated {
            turn_id: turn_id(),
            explanation: None,
            steps: vec![PlanStep {
                text: "First".to_string(),
                status: PlanStepStatus::InProgress,
            }],
        })));
        assert!(sender.send(Ok(AgentEvent::PlanUpdated {
            turn_id: turn_id(),
            explanation: Some("Revised".to_string()),
            steps: vec![PlanStep {
                text: "Second".to_string(),
                status: PlanStepStatus::Completed,
            }],
        })));

        assert!(matches!(
            receiver.next().await,
            Some(Ok(AgentEvent::PlanUpdated { explanation, steps, .. }))
                if explanation.as_deref() == Some("Revised")
                    && steps[0].text == "Second"
        ));
    }

    #[tokio::test]
    async fn bounded_channel_replaces_activity_snapshots_by_opaque_id() {
        let (sender, mut receiver) = AgentEventReceiver::channel(3);
        let first = ActivityUpsert::new(
            "tool-1",
            ActivitySemanticKind::Execute,
            ActivityStatus::InProgress,
            "Running command",
        )
        .expect("activity");
        let completed = ActivityUpsert::new(
            "tool-1",
            ActivitySemanticKind::Execute,
            ActivityStatus::Completed,
            "Running command",
        )
        .expect("activity");
        let second = ActivityUpsert::new(
            "tool-2",
            ActivitySemanticKind::Read,
            ActivityStatus::InProgress,
            "Reading file",
        )
        .expect("activity");
        sender.send(Ok(AgentEvent::ActivityUpsert {
            turn_id: turn_id(),
            activity: first,
        }));
        sender.send(Ok(AgentEvent::ActivityUpsert {
            turn_id: turn_id(),
            activity: second,
        }));
        sender.send(Ok(AgentEvent::ActivityUpsert {
            turn_id: turn_id(),
            activity: completed,
        }));

        assert!(matches!(
            receiver.next().await,
            Some(Ok(AgentEvent::ActivityUpsert { activity, .. }))
                if activity.activity_id == "tool-1" && activity.status == ActivityStatus::Completed
        ));
        assert!(matches!(
            receiver.next().await,
            Some(Ok(AgentEvent::ActivityUpsert { activity, .. }))
                if activity.activity_id == "tool-2"
        ));
    }

    #[tokio::test]
    async fn bounded_channel_merges_and_sanitizes_file_change_snapshots() {
        let (sender, mut receiver) = AgentEventReceiver::channel(2);
        for index in 0..(MAX_FILE_CHANGES + 8) {
            sender.send(Ok(AgentEvent::FilesChanged {
                turn_id: turn_id(),
                files: vec![
                    FileChange {
                        path: PathBuf::from(format!("/workspace/src/{index}.rs")),
                        summary: Some("updated".to_string()),
                    },
                    FileChange {
                        path: PathBuf::from("/workspace/src/shared.rs"),
                        summary: Some("token=must-not-appear".to_string()),
                    },
                    FileChange {
                        path: PathBuf::from("../outside"),
                        summary: None,
                    },
                ],
            }));
        }

        let Some(Ok(AgentEvent::FilesChanged { files, .. })) = receiver.next().await else {
            panic!("expected merged files");
        };
        assert_eq!(files.len(), MAX_FILE_CHANGES);
        assert!(files.iter().all(|file| !file.path.starts_with("..")));
        assert!(files.iter().all(|file| {
            file.summary
                .as_deref()
                .is_none_or(|summary| summary == "updated")
        }));
    }

    #[test]
    fn activity_snapshots_bound_text_and_filter_unsafe_paths() {
        let snapshot = ActivityUpsert::new(
            "tool-1",
            ActivitySemanticKind::Read,
            ActivityStatus::Pending,
            format!("  reading {} ", "x".repeat(300)),
        )
        .expect("activity")
        .with_detail(format!("  detail {} ", "x".repeat(700)))
        .with_paths([
            PathBuf::from("relative.rs"),
            PathBuf::from("/workspace/../secret"),
            PathBuf::from("/workspace/src/lib.rs"),
        ]);
        assert_eq!(snapshot.title.chars().count(), MAX_ACTIVITY_TITLE_CHARS);
        assert_eq!(
            snapshot.detail.as_ref().map(|value| value.chars().count()),
            Some(MAX_ACTIVITY_DETAIL_CHARS)
        );
        assert_eq!(snapshot.paths, [PathBuf::from("/workspace/src/lib.rs")]);
        assert!(
            ActivityUpsert::new(
                format!("tool{}", "x".repeat(MAX_ACTIVITY_ID_BYTES)),
                ActivitySemanticKind::Other,
                ActivityStatus::Pending,
                "Title",
            )
            .is_none()
        );
    }

    #[test]
    fn provider_command_catalog_is_safe_bounded_and_first_write_wins() {
        let command = DriverCommand::new(
            "research_codebase",
            format!(" Research   {} ", "x".repeat(200)),
            Some(" topic to investigate "),
        )
        .expect("command");
        assert_eq!(
            command.description.chars().count(),
            MAX_DRIVER_COMMAND_DESCRIPTION_CHARS
        );
        assert_eq!(command.input_hint.as_deref(), Some("topic to investigate"));
        assert!(matches!(
            command.input_shape(),
            DriverCommandInput::Freeform { ref hint, required: true }
                if hint == "topic to investigate"
        ));
        assert!(DriverCommand::new("Bad-Command", "Description", None).is_none());
        assert!(DriverCommand::new("", "Description", None).is_none());
        assert!(DriverCommand::new("safe", "private\u{1b}[31m", None).is_none());
        assert_eq!(
            DriverCommand::new("safe", "Description", Some("private\u{1b}[31m"))
                .expect("command")
                .input_hint
                .as_deref(),
            Some("input")
        );

        let duplicate = DriverCommand::new("research_codebase", "Second", None).expect("command");
        let catalog = DriverCommand::catalog([command.clone(), duplicate]);
        assert_eq!(catalog, [command]);

        let finite = DriverCommand::new("mode", "Choose mode", None)
            .expect("command")
            .with_single_choice(
                [
                    DriverCommandChoice::new("safe", "Safe").expect("choice"),
                    DriverCommandChoice::new("fast", "Fast").expect("choice"),
                ],
                false,
                Some("generation-1"),
            )
            .expect("finite command");
        assert!(finite.input_hint.is_none());
        assert!(matches!(
            finite.input_shape(),
            DriverCommandInput::SingleChoice { options, catalog_generation, .. }
                if options.len() == 2 && catalog_generation.as_deref() == Some("generation-1")
        ));
    }

    #[test]
    fn provider_timing_prefers_only_plausible_nonnegative_values() {
        let local = Duration::from_secs(3);
        assert_eq!(
            TurnTiming::from_provider_duration_ms(Some(125_900)).resolve(local),
            Duration::from_millis(125_900)
        );
        assert_eq!(
            TurnTiming::from_provider_duration_ms(Some(-1)).resolve(local),
            local
        );
        assert_eq!(
            TurnTiming {
                provider_duration_ms: Some(TurnTiming::MAX_PROVIDER_DURATION_MS + 1),
            }
            .resolve(local),
            local
        );
    }

    #[tokio::test]
    async fn control_events_evict_coalescible_output_under_pressure() {
        let (sender, mut receiver) = AgentEventReceiver::channel(2);
        sender.send(Ok(AgentEvent::AgentTextDelta {
            turn_id: turn_id(),
            text: "working".to_string(),
        }));
        sender.send(Ok(AgentEvent::ApprovalRequested(ApprovalRequest {
            approval_id: "approval-1".to_string(),
            turn_id: turn_id(),
            summary: "Run tests?".to_string(),
            command: Some("cargo test".to_string()),
            cwd: None,
            options: vec![ApprovalOption::ApproveOnce, ApprovalOption::Reject],
        })));
        sender.send(Ok(AgentEvent::TurnCompleted {
            turn_id: turn_id(),
            outcome: TurnOutcome::Completed,
            error: None,
            timing: TurnTiming::default(),
        }));

        assert!(matches!(
            receiver.next().await,
            Some(Ok(AgentEvent::ApprovalRequested(_)))
        ));
        assert!(matches!(
            receiver.next().await,
            Some(Ok(AgentEvent::TurnCompleted { .. }))
        ));
    }

    #[tokio::test]
    async fn control_only_overflow_fails_the_stream_explicitly() {
        let (sender, mut receiver) = AgentEventReceiver::channel(1);
        sender.send(Ok(AgentEvent::TurnStarted { turn_id: turn_id() }));
        sender.send(Ok(AgentEvent::TurnCompleted {
            turn_id: turn_id(),
            outcome: TurnOutcome::Completed,
            error: None,
            timing: TurnTiming::default(),
        }));

        assert!(matches!(
            receiver.next().await,
            Some(Err(DriverError::Protocol(message)))
                if message == "agent event control queue overflowed"
        ));
        assert_eq!(receiver.next().await, None);
        assert!(!sender.send(Ok(AgentEvent::TurnStarted { turn_id: turn_id() })));
    }
}
