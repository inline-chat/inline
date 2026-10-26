//! Frames on Claude Code's stream-json stdout.
//!
//! Every line is kept as its native JSON value. Known message kinds get a
//! typed view that is parsed leniently (missing fields default, extra fields
//! are ignored), so a newer CLI never turns a known frame into an error, and
//! frames this crate does not model survive as [`MessageKind::Other`] or
//! [`MessageKind::System`] with their payload intact.

use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

/// One parsed stdout line.
#[derive(Clone, Debug, PartialEq)]
pub enum Frame {
    /// A request the CLI sends to the host (`can_use_tool`, `mcp_message`, …).
    ControlRequest { request_id: String, request: Value },
    /// The CLI's reply to a request the host sent.
    ControlResponse(ControlResponse),
    /// The CLI withdrew one of its own in-flight requests.
    ControlCancel { request_id: String },
    /// Liveness heartbeat; carries nothing.
    KeepAlive,
    /// Everything else: conversation, system, task and lifecycle messages.
    Message(CliMessage),
}

/// The CLI's reply to one host control request.
#[derive(Clone, Debug, PartialEq)]
pub struct ControlResponse {
    pub request_id: String,
    pub outcome: Result<Value, String>,
}

/// Why a stdout line could not become a frame.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum FrameError {
    #[error("stdout line is not valid JSON: {0}")]
    Json(String),
    #[error("stdout JSON is not an object")]
    NotAnObject,
    #[error("control frame is missing {0}")]
    MissingField(&'static str),
}

/// Parses one complete stdout line. Blank and non-JSON lines (debug output
/// some CLI builds print to stdout) yield `Ok(None)`.
pub fn parse_line(line: &[u8]) -> Result<Option<Frame>, FrameError> {
    let trimmed = trim_ascii(line);
    if trimmed.is_empty() || trimmed[0] != b'{' {
        return Ok(None);
    }
    let value: Value =
        serde_json::from_slice(trimmed).map_err(|error| FrameError::Json(error.to_string()))?;
    parse_value(value).map(Some)
}

/// Classifies one JSON object from stdout.
pub fn parse_value(value: Value) -> Result<Frame, FrameError> {
    if !value.is_object() {
        return Err(FrameError::NotAnObject);
    }
    match value.get("type").and_then(Value::as_str) {
        Some("control_request") => {
            let request_id = string_field(&value, "request_id")
                .ok_or(FrameError::MissingField("request_id"))?;
            let request = value
                .get("request")
                .cloned()
                .ok_or(FrameError::MissingField("request"))?;
            Ok(Frame::ControlRequest {
                request_id,
                request,
            })
        }
        Some("control_response") => {
            let response = value
                .get("response")
                .ok_or(FrameError::MissingField("response"))?;
            let request_id = string_field(response, "request_id")
                .ok_or(FrameError::MissingField("response.request_id"))?;
            let outcome = if response.get("subtype").and_then(Value::as_str) == Some("error") {
                Err(response
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown error")
                    .to_string())
            } else {
                Ok(response.get("response").cloned().unwrap_or(Value::Null))
            };
            Ok(Frame::ControlResponse(ControlResponse {
                request_id,
                outcome,
            }))
        }
        Some("control_cancel_request") => Ok(Frame::ControlCancel {
            request_id: string_field(&value, "request_id")
                .ok_or(FrameError::MissingField("request_id"))?,
        }),
        Some("keep_alive") => Ok(Frame::KeepAlive),
        _ => Ok(Frame::Message(CliMessage::from_value(value))),
    }
}

/// A non-control stdout message with its typed view and native payload.
#[derive(Clone, Debug, PartialEq)]
pub struct CliMessage {
    pub kind: MessageKind,
    pub raw: Value,
}

impl CliMessage {
    pub fn from_value(raw: Value) -> Self {
        let kind = MessageKind::classify(&raw);
        Self { kind, raw }
    }

    /// The top-level `type` field, or `""` when absent.
    pub fn message_type(&self) -> &str {
        self.raw.get("type").and_then(Value::as_str).unwrap_or("")
    }

    /// The `subtype` field, when present.
    pub fn subtype(&self) -> Option<&str> {
        self.raw.get("subtype").and_then(Value::as_str)
    }

    pub fn uuid(&self) -> Option<&str> {
        self.raw.get("uuid").and_then(Value::as_str)
    }

    pub fn session_id(&self) -> Option<&str> {
        self.raw.get("session_id").and_then(Value::as_str)
    }

    /// Set on subagent output; `None` on main-thread messages.
    pub fn parent_tool_use_id(&self) -> Option<&str> {
        self.raw.get("parent_tool_use_id").and_then(Value::as_str)
    }
}

/// Typed views of the messages the driver acts on.
#[derive(Clone, Debug, PartialEq)]
pub enum MessageKind {
    Assistant(AssistantMessage),
    User(UserFrame),
    Result(ResultMessage),
    Init(InitMessage),
    SessionState(SessionStateChanged),
    Status(StatusMessage),
    Task(TaskEvent),
    BackgroundTasksChanged,
    CompactBoundary,
    CommandLifecycle(CommandLifecycle),
    StreamEvent(StreamEvent),
    RateLimit(RateLimitEvent),
    /// A `system` message whose subtype this crate does not model.
    System {
        subtype: String,
    },
    /// A top-level type this crate does not model (`active_goal`,
    /// `tool_progress`, `prompt_suggestion`, newer kinds …).
    Other {
        message_type: String,
    },
}

impl MessageKind {
    fn classify(raw: &Value) -> Self {
        let message_type = raw.get("type").and_then(Value::as_str).unwrap_or("");
        match message_type {
            "assistant" => lenient(raw).map(Self::Assistant),
            "user" => lenient(raw).map(Self::User),
            "result" => lenient(raw).map(Self::Result),
            "stream_event" => lenient(raw).map(Self::StreamEvent),
            "rate_limit_event" => lenient(raw).map(Self::RateLimit),
            "command_lifecycle" => lenient(raw).map(Self::CommandLifecycle),
            "system" => {
                let subtype = raw.get("subtype").and_then(Value::as_str).unwrap_or("");
                match subtype {
                    "init" => lenient(raw).map(Self::Init),
                    "session_state_changed" => lenient(raw).map(Self::SessionState),
                    "status" => lenient(raw).map(Self::Status),
                    "task_started" | "task_progress" | "task_updated" | "task_notification" => {
                        lenient(raw).map(Self::Task)
                    }
                    "background_tasks_changed" => Some(Self::BackgroundTasksChanged),
                    "compact_boundary" => Some(Self::CompactBoundary),
                    _ => None,
                }
                .or_else(|| {
                    Some(Self::System {
                        subtype: subtype.to_string(),
                    })
                })
            }
            _ => None,
        }
        .unwrap_or_else(|| Self::Other {
            message_type: message_type.to_string(),
        })
    }
}

fn lenient<T: DeserializeOwned>(raw: &Value) -> Option<T> {
    T::deserialize(raw).ok()
}

/// An assistant message; `message` is the Messages API message object.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct AssistantMessage {
    pub message: ApiMessage,
    pub parent_tool_use_id: Option<String>,
    pub session_id: Option<String>,
    pub uuid: Option<String>,
    pub error: Option<Value>,
    pub agent_id: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct ApiMessage {
    pub id: Option<String>,
    pub model: Option<String>,
    pub content: Vec<Value>,
    pub stop_reason: Option<String>,
    pub usage: Option<Value>,
}

/// A user message the CLI wrote: tool results, replays and subagent prompts.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct UserFrame {
    pub message: Value,
    pub parent_tool_use_id: Option<String>,
    pub session_id: Option<String>,
    pub uuid: Option<String>,
    pub tool_use_result: Option<Value>,
    pub origin: Option<Value>,
    pub priority: Option<String>,
    #[serde(rename = "isSynthetic")]
    pub is_synthetic: Option<bool>,
    #[serde(rename = "isReplay")]
    pub is_replay: Option<bool>,
    #[serde(rename = "shouldQuery")]
    pub should_query: Option<bool>,
    pub agent_id: Option<String>,
}

/// End of one turn (or a startup failure).
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct ResultMessage {
    pub subtype: String,
    pub is_error: bool,
    pub duration_ms: Option<u64>,
    pub duration_api_ms: Option<u64>,
    pub num_turns: Option<u64>,
    pub session_id: Option<String>,
    pub result: Option<String>,
    pub stop_reason: Option<String>,
    pub terminal_reason: Option<String>,
    pub total_cost_usd: Option<f64>,
    pub usage: Option<Value>,
    #[serde(rename = "modelUsage")]
    pub model_usage: Option<Value>,
    pub permission_denials: Option<Vec<Value>>,
    pub errors: Option<Vec<Value>>,
    pub api_error_status: Option<Value>,
    /// Uuids of the user messages this turn consumed (absent before 2.1.29x).
    pub user_message_uuids: Option<Vec<String>>,
    pub queued_turn_count: Option<u64>,
    /// Typed reason the CLI refused to start (see [`StartupFailure`]).
    pub startup_failure_reason: Option<String>,
    pub uuid: Option<String>,
}

impl ResultMessage {
    /// The most informative text of an error result, as the SDKs pick it.
    pub fn error_text(&self) -> String {
        let errors: Vec<String> = self
            .errors
            .iter()
            .flatten()
            .filter_map(|error| match error {
                Value::String(text) => Some(text.clone()),
                Value::Object(map) => map
                    .get("message")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                _ => None,
            })
            .filter(|text| !text.trim().is_empty())
            .collect();
        if !errors.is_empty() {
            return errors.join("; ");
        }
        if let Some(result) = self.result.as_deref().map(str::trim)
            && !result.is_empty()
        {
            return result.to_string();
        }
        if !self.subtype.is_empty() && self.subtype != "success" {
            return self.subtype.clone();
        }
        if let Some(status) = &self.api_error_status
            && !status.is_null()
        {
            return format!("API error (HTTP {status})");
        }
        "unknown error".to_string()
    }
}

/// `system/init`: emitted at the start of each turn.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct InitMessage {
    pub session_id: Option<String>,
    pub claude_code_version: Option<String>,
    pub cwd: Option<String>,
    pub model: Option<String>,
    #[serde(rename = "permissionMode")]
    pub permission_mode: Option<String>,
    pub tools: Vec<String>,
    pub slash_commands: Vec<String>,
    pub terminal_slash_commands: Vec<String>,
    pub agents: Vec<String>,
    pub skills: Vec<Value>,
    pub mcp_servers: Vec<Value>,
    pub plugins: Vec<Value>,
    pub output_style: Option<String>,
    #[serde(rename = "apiKeySource")]
    pub api_key_source: Option<String>,
    pub capabilities: Vec<String>,
    pub effort: Option<String>,
    pub fast_mode_state: Option<Value>,
    pub view_mode: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct SessionStateChanged {
    /// `idle`, `running` or `requires_action`.
    pub state: String,
    pub sdk_host_only: Option<bool>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct StatusMessage {
    /// `compacting`, `requesting` or null.
    pub status: Option<String>,
    #[serde(rename = "permissionMode")]
    pub permission_mode: Option<String>,
    pub compact_result: Option<String>,
    pub compact_error: Option<String>,
}

/// `task_started`, `task_progress`, `task_updated` and `task_notification`.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct TaskEvent {
    pub subtype: String,
    pub task_id: String,
    pub run_id: Option<String>,
    pub tool_use_id: Option<String>,
    pub task_type: Option<String>,
    pub description: Option<String>,
    pub status: Option<String>,
    pub summary: Option<String>,
    pub output_file: Option<String>,
    pub last_tool_name: Option<String>,
    pub usage: Option<Value>,
    pub patch: Option<Value>,
    pub is_backgrounded: Option<bool>,
}

/// Terminal task statuses, as the SDKs treat them.
pub const TERMINAL_TASK_STATUSES: &[&str] = &["completed", "failed", "stopped", "killed"];

impl TaskEvent {
    /// The status this event leaves the task in, if it says.
    pub fn effective_status(&self) -> Option<&str> {
        match self.subtype.as_str() {
            "task_started" => Some("running"),
            "task_notification" => self.status.as_deref(),
            "task_updated" => self
                .patch
                .as_ref()
                .and_then(|patch| patch.get("status"))
                .and_then(Value::as_str),
            _ => None,
        }
    }

    pub fn is_terminal(&self) -> bool {
        self.effective_status()
            .is_some_and(|status| TERMINAL_TASK_STATUSES.contains(&status))
    }
}

/// The fate of a uuid-stamped user message the host sent.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct CommandLifecycle {
    pub command_uuid: String,
    /// `queued`, `started`, `completed`, `cancelled`, `discarded` or `refused`.
    pub state: String,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct StreamEvent {
    pub event: Value,
    pub parent_tool_use_id: Option<String>,
    pub session_id: Option<String>,
    pub uuid: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct RateLimitEvent {
    pub rate_limit_info: Value,
}

/// Claude Code's typed reasons for refusing to start
/// (`SDKStartupFailureReason`). Unknown reasons are kept verbatim.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StartupFailure {
    CliVersionTooOld,
    SessionHeldByBackground,
    CwdUnavailable,
    WorktreeResumeRefused,
    WorktreeUnverified,
    BypassRoot,
    ShellToolMissing,
    TempDirUnusable,
    ProxyInvalid,
    GatewaySigninRequired,
    GatewayAccessDenied,
    /// Organization pins, managed settings and policy refusals.
    Organization(String),
    Other(String),
}

impl StartupFailure {
    pub fn parse(reason: &str) -> Self {
        match reason {
            "cli_version_too_old" => Self::CliVersionTooOld,
            "session_held_by_background" => Self::SessionHeldByBackground,
            "cwd_unavailable" => Self::CwdUnavailable,
            "worktree_resume_refused" => Self::WorktreeResumeRefused,
            "worktree_unverified" => Self::WorktreeUnverified,
            "bypass_root" => Self::BypassRoot,
            "shell_tool_missing" => Self::ShellToolMissing,
            "temp_dir_unusable" => Self::TempDirUnusable,
            "proxy_invalid" => Self::ProxyInvalid,
            "gateway_signin_required" => Self::GatewaySigninRequired,
            "gateway_access_denied" => Self::GatewayAccessDenied,
            "org_pin_api_key_conflict"
            | "provider_not_allowed"
            | "org_verify_failed"
            | "org_pin_mismatch"
            | "managed_settings_invalid"
            | "remote_settings_required_unavailable"
            | "org_config_required_unavailable"
            | "org_config_refused" => Self::Organization(reason.to_string()),
            other => Self::Other(other.to_string()),
        }
    }

    /// The native reason string.
    pub fn reason(&self) -> &str {
        match self {
            Self::CliVersionTooOld => "cli_version_too_old",
            Self::SessionHeldByBackground => "session_held_by_background",
            Self::CwdUnavailable => "cwd_unavailable",
            Self::WorktreeResumeRefused => "worktree_resume_refused",
            Self::WorktreeUnverified => "worktree_unverified",
            Self::BypassRoot => "bypass_root",
            Self::ShellToolMissing => "shell_tool_missing",
            Self::TempDirUnusable => "temp_dir_unusable",
            Self::ProxyInvalid => "proxy_invalid",
            Self::GatewaySigninRequired => "gateway_signin_required",
            Self::GatewayAccessDenied => "gateway_access_denied",
            Self::Organization(reason) | Self::Other(reason) => reason,
        }
    }

    /// Whether running the same launch again may succeed without a fix.
    pub fn is_retryable(&self) -> bool {
        matches!(
            self,
            Self::WorktreeUnverified | Self::SessionHeldByBackground
        ) || matches!(self, Self::Organization(reason) if reason == "org_config_required_unavailable" || reason == "org_verify_failed")
    }
}

fn string_field(value: &Value, key: &str) -> Option<String> {
    match value.get(key)? {
        Value::String(text) => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

fn trim_ascii(bytes: &[u8]) -> &[u8] {
    let start = bytes
        .iter()
        .position(|byte| !byte.is_ascii_whitespace())
        .unwrap_or(bytes.len());
    let end = bytes
        .iter()
        .rposition(|byte| !byte.is_ascii_whitespace())
        .map_or(start, |index| index + 1);
    &bytes[start..end]
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn non_json_and_blank_lines_are_skipped() {
        assert_eq!(parse_line(b""), Ok(None));
        assert_eq!(parse_line(b"   \r\n"), Ok(None));
        assert_eq!(parse_line(b"[SandboxDebug] hello"), Ok(None));
        assert!(matches!(parse_line(b"{oops"), Err(FrameError::Json(_))));
    }

    #[test]
    fn control_frames_are_routed() {
        let request = parse_line(
            br#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash"}}"#,
        )
        .unwrap()
        .unwrap();
        assert!(matches!(request, Frame::ControlRequest { ref request_id, .. } if request_id == "r1"));

        let success = parse_line(
            br#"{"type":"control_response","response":{"subtype":"success","request_id":"req_1","response":{"still_queued":[]}}}"#,
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            success,
            Frame::ControlResponse(ControlResponse {
                request_id: "req_1".into(),
                outcome: Ok(json!({"still_queued": []})),
            })
        );

        let error = parse_line(
            br#"{"type":"control_response","response":{"subtype":"error","request_id":"req_2","error":"nope"}}"#,
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            error,
            Frame::ControlResponse(ControlResponse {
                request_id: "req_2".into(),
                outcome: Err("nope".into()),
            })
        );

        assert_eq!(
            parse_line(br#"{"type":"control_cancel_request","request_id":"r9"}"#).unwrap(),
            Some(Frame::ControlCancel {
                request_id: "r9".into()
            })
        );
        assert_eq!(
            parse_line(br#"{"type":"keep_alive"}"#).unwrap(),
            Some(Frame::KeepAlive)
        );
    }

    #[test]
    fn unknown_kinds_keep_their_payload() {
        let raw = json!({"type": "active_goal", "value": null, "uuid": "u", "session_id": "s"});
        let message = CliMessage::from_value(raw.clone());
        assert_eq!(
            message.kind,
            MessageKind::Other {
                message_type: "active_goal".into()
            }
        );
        assert_eq!(message.raw, raw);

        let system = CliMessage::from_value(json!({"type": "system", "subtype": "hook_started"}));
        assert_eq!(
            system.kind,
            MessageKind::System {
                subtype: "hook_started".into()
            }
        );
    }

    #[test]
    fn known_kinds_parse_leniently() {
        let result = CliMessage::from_value(json!({
            "type": "result",
            "subtype": "success",
            "is_error": false,
            "num_turns": 1,
            "session_id": "s",
            "user_message_uuids": ["m1", "m2"],
            "terminal_reason": "completed",
            "a_future_field": {"x": 1}
        }));
        let MessageKind::Result(result) = result.kind else {
            panic!("result kind");
        };
        assert_eq!(result.user_message_uuids.unwrap(), ["m1", "m2"]);
        assert_eq!(result.terminal_reason.as_deref(), Some("completed"));

        let task = CliMessage::from_value(json!({
            "type": "system",
            "subtype": "task_updated",
            "task_id": "t1",
            "patch": {"status": "completed"}
        }));
        let MessageKind::Task(task) = task.kind else {
            panic!("task kind");
        };
        assert!(task.is_terminal());

        let lifecycle = CliMessage::from_value(json!({
            "type": "command_lifecycle",
            "command_uuid": "m1",
            "state": "queued",
            "uuid": "x",
            "session_id": "s"
        }));
        assert_eq!(
            lifecycle.kind,
            MessageKind::CommandLifecycle(CommandLifecycle {
                command_uuid: "m1".into(),
                state: "queued".into()
            })
        );
    }

    #[test]
    fn malformed_known_kinds_fall_back_to_other() {
        let message = CliMessage::from_value(json!({"type": "assistant", "message": 7}));
        assert_eq!(
            message.kind,
            MessageKind::Other {
                message_type: "assistant".into()
            }
        );
    }

    #[test]
    fn error_text_prefers_errors_then_result() {
        let result = ResultMessage {
            subtype: "success".into(),
            is_error: true,
            result: Some("API Error: 529".into()),
            ..ResultMessage::default()
        };
        assert_eq!(result.error_text(), "API Error: 529");
        let result = ResultMessage {
            subtype: "error_during_execution".into(),
            errors: Some(vec![json!("first"), json!({"message": "second"})]),
            ..ResultMessage::default()
        };
        assert_eq!(result.error_text(), "first; second");
    }

    #[test]
    fn startup_failures_round_trip() {
        for reason in [
            "cli_version_too_old",
            "session_held_by_background",
            "cwd_unavailable",
            "org_pin_mismatch",
            "brand_new_reason",
        ] {
            assert_eq!(StartupFailure::parse(reason).reason(), reason);
        }
        assert_eq!(
            StartupFailure::parse("cli_version_too_old"),
            StartupFailure::CliVersionTooOld
        );
    }
}
