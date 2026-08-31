use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::PathBuf;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use inline_agent_bridge::{
    ActivitySemanticKind, ActivityStatus, ActivityUpsert, AgentEvent, AgentMessagePhase,
    AgentMessageUpdate, ApprovalOption, ApprovalRequest, FileChange, OutputAttachment,
    OutputAttachmentKind, PlanStep, PlanStepStatus, Question, QuestionAnswer, QuestionOption,
    QuestionRequest, TurnId, TurnOutcome, TurnTiming, native_tool_activity,
    sanitize_visible_command,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;

const MAX_PLAN_STEPS: usize = 32;
const MAX_PLAN_TEXT_CHARS: usize = 512;
const MAX_PROVIDER_ID_BYTES: usize = 256;
const MAX_QUESTION_ID_BYTES: usize = 128;
const MAX_QUESTION_HEADER_CHARS: usize = 80;
const MAX_QUESTION_PROMPT_CHARS: usize = 2_000;
const MAX_QUESTION_OPTION_LABEL_CHARS: usize = 160;
const MAX_QUESTION_OPTION_DESCRIPTION_CHARS: usize = 400;
const MAX_AGENT_TEXT_BYTES: usize = 64 * 1024;
const MAX_FILE_CHANGES: usize = 64;
const MAX_FILE_CHANGE_PATH_BYTES: usize = 1024;
const MAX_TURN_ERROR_CHARS: usize = 1_024;
const MAX_OUTPUT_IMAGE_BYTES: usize = 20 * 1024 * 1024;
const MAX_OUTPUT_PATH_BYTES: usize = 4 * 1024;
const TRUNCATED_AGENT_TEXT_MARKER: &str = "\n[additional agent output omitted]";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientInfo {
    pub name: String,
    pub title: Option<String>,
    pub version: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InitializeParams {
    pub client_info: ClientInfo,
    pub capabilities: InitializeCapabilities,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InitializeCapabilities {
    pub experimental_api: bool,
}

impl InitializeParams {
    pub fn inline(version: impl Into<String>) -> Self {
        Self {
            client_info: ClientInfo {
                name: "inline_agent_bridge".to_string(),
                title: Some("Inline Agent Bridge".to_string()),
                version: version.into(),
            },
            capabilities: InitializeCapabilities {
                experimental_api: true,
            },
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartThreadParams {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub permissions: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub config: Option<BTreeMap<String, Value>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ephemeral: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dynamic_tools: Option<Vec<DynamicToolSpec>>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DynamicToolSpec {
    pub name: String,
    pub description: String,
    pub input_schema: Value,
    pub namespace: String,
    pub defer_loading: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResumeThreadParams {
    pub thread_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub config: Option<BTreeMap<String, Value>>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum UserInput {
    Text { text: String },
    Image { url: String },
    LocalImage { path: PathBuf },
    Audio { url: String },
    LocalAudio { path: PathBuf },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartTurnParams {
    pub thread_id: String,
    pub input: Vec<UserInput>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_user_message_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub permissions: Option<String>,
}

impl StartTurnParams {
    pub fn text(thread_id: impl Into<String>, text: impl Into<String>) -> Self {
        Self {
            thread_id: thread_id.into(),
            input: vec![UserInput::Text { text: text.into() }],
            client_user_message_id: None,
            cwd: None,
            model: None,
            effort: None,
            permissions: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SteerTurnParams {
    pub thread_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_user_message_id: Option<String>,
    pub input: Vec<UserInput>,
    pub expected_turn_id: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InterruptTurnParams {
    pub thread_id: String,
    pub turn_id: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactThreadParams {
    pub thread_id: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelListParams {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    pub limit: Option<u32>,
    pub include_hidden: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelListResponse {
    pub data: Vec<CodexModelOption>,
    #[serde(default)]
    pub next_cursor: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexModelOption {
    pub model: String,
    #[serde(default)]
    pub display_name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub hidden: bool,
    #[serde(default)]
    pub supported_reasoning_efforts: Vec<CodexReasoningOption>,
    #[serde(default)]
    pub default_reasoning_effort: String,
    #[serde(default)]
    pub is_default: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexReasoningOption {
    pub reasoning_effort: String,
    pub description: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionProfileListParams {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    pub limit: Option<u32>,
    pub cwd: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionProfileListResponse {
    pub data: Vec<CodexPermissionOption>,
    #[serde(default)]
    pub next_cursor: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexPermissionOption {
    pub id: String,
    pub description: Option<String>,
    /// Older stable app-server responses omitted this field. Treat omission as
    /// selectable; an explicit `false` is the only safe reason to disable it.
    #[serde(default)]
    pub allowed: Option<bool>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CodexNotification {
    pub method: String,
    pub params: Value,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ProtocolError {
    #[error("Codex notification {method} is missing {field}")]
    MissingField { method: String, field: &'static str },
    #[error("Codex notification {method} contains invalid {field}")]
    InvalidField { method: String, field: &'static str },
    #[error("Codex server request is unsupported: {0}")]
    UnsupportedServerRequest(String),
}

pub fn provider_session_id_from_response(
    method: &str,
    response: &Value,
) -> Result<inline_agent_bridge::ProviderSessionId, ProtocolError> {
    let raw = string_at(method, response, &["thread", "id"])?;
    if !safe_provider_id(&raw) {
        return Err(ProtocolError::InvalidField {
            method: method.to_string(),
            field: "thread.id",
        });
    }
    inline_agent_bridge::ProviderSessionId::new(raw).map_err(|_| ProtocolError::InvalidField {
        method: method.to_string(),
        field: "thread.id",
    })
}

pub fn turn_id_from_response(method: &str, response: &Value) -> Result<TurnId, ProtocolError> {
    turn_id_at(method, response, &["turn", "id"])
}

pub fn approval_result(decision: inline_agent_bridge::ApprovalDecision) -> Value {
    let decision = match decision {
        inline_agent_bridge::ApprovalDecision::ApproveOnce => "accept".to_string(),
        inline_agent_bridge::ApprovalDecision::ApproveForSession => "acceptForSession".to_string(),
        inline_agent_bridge::ApprovalDecision::Reject => "decline".to_string(),
        inline_agent_bridge::ApprovalDecision::CancelTurn => "cancel".to_string(),
        inline_agent_bridge::ApprovalDecision::ProviderChoice { option_id } => option_id,
    };
    serde_json::json!({ "decision": decision })
}

pub fn normalize_notification(
    notification: CodexNotification,
) -> Result<Vec<AgentEvent>, ProtocolError> {
    let method = notification.method;
    let params = notification.params;
    match method.as_str() {
        "turn/started" => {
            let turn_id = turn_id_at(&method, &params, &["turn", "id"])?;
            Ok(vec![AgentEvent::TurnStarted { turn_id }])
        }
        "item/agentMessage/delta" => {
            let turn_id = turn_id_at(&method, &params, &["turnId"])?;
            let text = bounded_agent_text(&string_at(&method, &params, &["delta"])?);
            if let Some(item_id) = params
                .get("itemId")
                .and_then(Value::as_str)
                .filter(|id| safe_provider_id(id))
            {
                return Ok(vec![AgentEvent::AgentMessage {
                    turn_id,
                    item_id: item_id.to_string(),
                    phase: message_phase(&params),
                    update: AgentMessageUpdate::Delta(text),
                }]);
            }
            Ok(vec![AgentEvent::AgentTextDelta { turn_id, text }])
        }
        "turn/plan/updated" => normalize_plan_update(&method, &params),
        "item/started" => normalize_started_item(&method, &params),
        "item/commandExecution/outputDelta" => normalize_command_output_progress(&method, &params),
        "item/fileChange/patchUpdated" => normalize_file_change_progress(&method, &params),
        "item/completed" => normalize_completed_item(&method, &params),
        "turn/completed" => normalize_completed_turn(&method, &params),
        _ => Ok(Vec::new()),
    }
}

/// Returns a bounded, metadata-only diagnostic for notification shapes this
/// driver intentionally ignores. Never includes notification parameters.
pub fn unsupported_notification_diagnostic(method: &str, params: &Value) -> Option<String> {
    match method {
        "turn/started"
        | "turn/plan/updated"
        | "item/agentMessage/delta"
        | "item/started"
        | "item/commandExecution/outputDelta"
        | "item/fileChange/patchUpdated"
        | "turn/completed" => None,
        "item/completed" => {
            let item_type = params
                .get("item")
                .and_then(|item| item.get("type"))
                .and_then(Value::as_str)?;
            if matches!(
                item_type,
                "agentMessage"
                    | "fileChange"
                    | "commandExecution"
                    | "imageGeneration"
                    | "mcpToolCall"
                    | "dynamicToolCall"
                    | "webSearch"
                    | "reasoning"
                    | "collabAgentToolCall"
                    | "enteredReviewMode"
                    | "exitedReviewMode"
                    | "contextCompaction"
            ) {
                None
            } else {
                Some(format!(
                    "unsupported Codex item type {}",
                    safe_protocol_identifier(item_type)
                ))
            }
        }
        _ => Some(format!(
            "unsupported Codex notification method {}",
            safe_protocol_identifier(method)
        )),
    }
}

fn normalize_plan_update(method: &str, params: &Value) -> Result<Vec<AgentEvent>, ProtocolError> {
    let turn_id = turn_id_at(method, params, &["turnId"])?;
    let plan = value_at(method, params, &["plan"])?
        .as_array()
        .ok_or_else(|| ProtocolError::InvalidField {
            method: method.to_string(),
            field: "plan",
        })?;
    let mut steps = Vec::with_capacity(plan.len().min(MAX_PLAN_STEPS));
    for item in plan.iter().take(MAX_PLAN_STEPS) {
        let text = bounded_visible_text(&string_at(method, item, &["step"])?);
        if text.is_empty() {
            continue;
        }
        let status = match string_at(method, item, &["status"])?.as_str() {
            "pending" => PlanStepStatus::Pending,
            "inProgress" => PlanStepStatus::InProgress,
            "completed" => PlanStepStatus::Completed,
            _ => {
                return Err(ProtocolError::InvalidField {
                    method: method.to_string(),
                    field: "plan.status",
                });
            }
        };
        steps.push(PlanStep { text, status });
    }
    let explanation = params
        .get("explanation")
        .and_then(Value::as_str)
        .map(bounded_visible_text)
        .filter(|value| !value.is_empty());
    Ok(vec![AgentEvent::PlanUpdated {
        turn_id,
        explanation,
        steps,
    }])
}

fn bounded_visible_text(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(MAX_PLAN_TEXT_CHARS)
        .collect()
}

fn bounded_agent_text(value: &str) -> String {
    if value.len() <= MAX_AGENT_TEXT_BYTES {
        return value.to_string();
    }
    let mut boundary = MAX_AGENT_TEXT_BYTES.min(value.len());
    while boundary > 0 && !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    let mut bounded = value[..boundary].to_string();
    bounded.push_str(TRUNCATED_AGENT_TEXT_MARKER);
    bounded
}

fn safe_file_change_path(value: &str) -> bool {
    let path = std::path::Path::new(value);
    !value.is_empty()
        && value.len() <= MAX_FILE_CHANGE_PATH_BYTES
        && !value.chars().any(char::is_control)
        && !path
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
}

fn safe_file_change_summary(value: &str) -> Option<&'static str> {
    match value.trim().to_ascii_lowercase().as_str() {
        "add" | "added" | "create" | "created" => Some("created"),
        "change" | "changed" | "modify" | "modified" | "update" | "updated" => Some("updated"),
        "delete" | "deleted" | "remove" | "removed" => Some("deleted"),
        "move" | "moved" | "rename" | "renamed" => Some("renamed"),
        _ => None,
    }
}

fn safe_protocol_identifier(value: &str) -> &str {
    if !value.is_empty()
        && value.len() <= 96
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'.' | b'_' | b'-'))
    {
        value
    } else {
        "[unrecognized]"
    }
}

pub fn normalize_server_request(
    request_id: &Value,
    method: &str,
    params: &Value,
) -> Result<ApprovalRequest, ProtocolError> {
    let turn_id = turn_id_at(method, params, &["turnId"])?;
    let approval_id = request_id_string(request_id, method)?;
    match method {
        "item/commandExecution/requestApproval" => Ok(ApprovalRequest {
            approval_id,
            turn_id,
            summary: "Codex wants to run a command.".to_string(),
            command: params
                .get("command")
                .and_then(Value::as_str)
                .and_then(sanitize_visible_command),
            cwd: None,
            options: approval_options(params, true),
        }),
        "item/fileChange/requestApproval" => Ok(ApprovalRequest {
            approval_id,
            turn_id,
            summary: "Codex wants to change files.".to_string(),
            command: None,
            cwd: None,
            options: approval_options(params, false),
        }),
        _ => Err(ProtocolError::UnsupportedServerRequest(method.to_string())),
    }
}

pub fn normalize_question_request(
    request_id: &Value,
    method: &str,
    params: &Value,
) -> Result<QuestionRequest, ProtocolError> {
    if method != "item/tool/requestUserInput" {
        return Err(ProtocolError::UnsupportedServerRequest(method.to_string()));
    }
    let turn_id = turn_id_at(method, params, &["turnId"])?;
    let questions = params
        .get("questions")
        .and_then(Value::as_array)
        .ok_or_else(|| ProtocolError::InvalidField {
            method: method.to_string(),
            field: "questions",
        })?;
    if questions.is_empty() || questions.len() > 3 {
        return Err(ProtocolError::InvalidField {
            method: method.to_string(),
            field: "questions",
        });
    }
    let mut question_ids = HashSet::with_capacity(questions.len());
    let questions = questions
        .iter()
        .map(|question| {
            let question_id = string_at(method, question, &["id"])?;
            if question_id.len() > MAX_QUESTION_ID_BYTES
                || !safe_provider_id(&question_id)
                || !question_ids.insert(question_id.clone())
            {
                return Err(ProtocolError::InvalidField {
                    method: method.to_string(),
                    field: "questions.id",
                });
            }
            let option_values = question
                .get("options")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .collect::<Vec<_>>();
            if option_values.len() > 16 {
                return Err(ProtocolError::InvalidField {
                    method: method.to_string(),
                    field: "questions.options",
                });
            }
            let options = option_values
                .into_iter()
                .map(|option| {
                    Ok(QuestionOption {
                        label: bounded_question_text_at(
                            method,
                            option,
                            &["label"],
                            MAX_QUESTION_OPTION_LABEL_CHARS,
                        )?,
                        description: option
                            .get("description")
                            .and_then(Value::as_str)
                            .filter(|value| !value.trim().is_empty())
                            .map(|value| {
                                bounded_question_text(
                                    method,
                                    "questions.options.description",
                                    value,
                                    MAX_QUESTION_OPTION_DESCRIPTION_CHARS,
                                )
                            })
                            .transpose()?,
                    })
                })
                .collect::<Result<Vec<_>, ProtocolError>>()?;
            Ok(Question {
                question_id,
                header: bounded_question_text_at(
                    method,
                    question,
                    &["header"],
                    MAX_QUESTION_HEADER_CHARS,
                )?,
                prompt: bounded_question_text_at(
                    method,
                    question,
                    &["question"],
                    MAX_QUESTION_PROMPT_CHARS,
                )?,
                options,
                allows_other: question
                    .get("isOther")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                is_secret: question
                    .get("isSecret")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            })
        })
        .collect::<Result<Vec<_>, ProtocolError>>()?;
    Ok(QuestionRequest {
        request_id: request_id_string(request_id, method)?,
        turn_id,
        questions,
        auto_resolution_ms: params.get("autoResolutionMs").and_then(Value::as_u64),
    })
}

pub fn question_result(answers: Vec<QuestionAnswer>) -> Value {
    let answers = answers
        .into_iter()
        .map(|answer| {
            (
                answer.question_id,
                serde_json::json!({ "answers": answer.answers }),
            )
        })
        .collect::<serde_json::Map<_, _>>();
    serde_json::json!({ "answers": answers })
}

fn request_id_string(request_id: &Value, method: &str) -> Result<String, ProtocolError> {
    let value = match request_id {
        Value::String(value) => Ok(value.clone()),
        Value::Number(value) => Ok(value.to_string()),
        _ => Err(ProtocolError::InvalidField {
            method: method.to_string(),
            field: "id",
        }),
    }?;
    if !safe_provider_id(&value) {
        return Err(ProtocolError::InvalidField {
            method: method.to_string(),
            field: "id",
        });
    }
    Ok(value)
}

fn normalize_completed_item(
    method: &str,
    params: &Value,
) -> Result<Vec<AgentEvent>, ProtocolError> {
    let turn_id = turn_id_at(method, params, &["turnId"])?;
    let item = value_at(method, params, &["item"])?;
    let item_type = string_at(method, item, &["type"])?;
    match item_type.as_str() {
        "agentMessage" => {
            let text = bounded_agent_text(&string_at(method, item, &["text"]).unwrap_or_default());
            Ok(vec![if let Some(item_id) = item
                .get("id")
                .and_then(Value::as_str)
                .filter(|id| safe_provider_id(id))
            {
                AgentEvent::AgentMessage {
                    turn_id,
                    item_id: item_id.to_string(),
                    phase: message_phase(item),
                    update: AgentMessageUpdate::Completed(text),
                }
            } else {
                AgentEvent::AgentTextCompleted { turn_id, text }
            }])
        }
        "fileChange" => {
            let files = item
                .get("changes")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|change| {
                    let path = change.get("path")?.as_str()?;
                    if !safe_file_change_path(path) {
                        return None;
                    }
                    Some(FileChange {
                        path: PathBuf::from(path),
                        summary: change
                            .get("kind")
                            .and_then(Value::as_str)
                            .and_then(safe_file_change_summary)
                            .map(str::to_string),
                    })
                })
                .take(MAX_FILE_CHANGES)
                .collect();
            let activity = codex_file_change_activity(item, ActivityStatus::Completed);
            let mut events = vec![AgentEvent::FilesChanged {
                turn_id: turn_id.clone(),
                files,
            }];
            if let Some(activity) = activity {
                events.push(AgentEvent::ActivityUpsert { turn_id, activity });
            }
            Ok(events)
        }
        "imageGeneration" => normalize_image_generation(method, item, turn_id),
        "commandExecution"
        | "mcpToolCall"
        | "dynamicToolCall"
        | "webSearch"
        | "collabAgentToolCall"
        | "enteredReviewMode"
        | "exitedReviewMode"
        | "contextCompaction" => {
            Ok(
                codex_item_activity(method, &turn_id, item, ActivityStatus::Completed)?
                    .map(|activity| AgentEvent::ActivityUpsert { turn_id, activity })
                    .into_iter()
                    .collect(),
            )
        }
        _ => Ok(Vec::new()),
    }
}

fn normalize_image_generation(
    method: &str,
    item: &Value,
    turn_id: TurnId,
) -> Result<Vec<AgentEvent>, ProtocolError> {
    if item.get("status").and_then(Value::as_str) != Some("completed") {
        return Ok(Vec::new());
    }
    let id = string_at(method, item, &["id"])?;
    if !safe_provider_id(&id) {
        return Err(ProtocolError::InvalidField {
            method: method.to_string(),
            field: "item.id",
        });
    }
    let path = PathBuf::from(string_at(method, item, &["savedPath"])?);
    let path_text = path.to_string_lossy();
    if !path.is_absolute()
        || path_text.len() > MAX_OUTPUT_PATH_BYTES
        || path_text.chars().any(char::is_control)
    {
        return Err(ProtocolError::InvalidField {
            method: method.to_string(),
            field: "item.savedPath",
        });
    }
    let result = string_at(method, item, &["result"])?;
    let maximum_base64_bytes = MAX_OUTPUT_IMAGE_BYTES.div_ceil(3) * 4;
    if result.trim().len() > maximum_base64_bytes {
        return Err(ProtocolError::InvalidField {
            method: method.to_string(),
            field: "item.result",
        });
    }
    let expected = BASE64_STANDARD
        .decode(result.trim().as_bytes())
        .map_err(|_| ProtocolError::InvalidField {
            method: method.to_string(),
            field: "item.result",
        })?;
    if expected.is_empty() || expected.len() > MAX_OUTPUT_IMAGE_BYTES || !is_png(&expected) {
        return Err(ProtocolError::InvalidField {
            method: method.to_string(),
            field: "item.result",
        });
    }
    let saved = fs::read(&path).map_err(|_| ProtocolError::InvalidField {
        method: method.to_string(),
        field: "item.savedPath",
    })?;
    if saved != expected {
        return Err(ProtocolError::InvalidField {
            method: method.to_string(),
            field: "item.savedPath",
        });
    }
    let attachment = OutputAttachment {
        id,
        kind: OutputAttachmentKind::Image,
        path,
        mime_type: "image/png".to_string(),
        file_name: "generated-image.png".to_string(),
        size_bytes: u64::try_from(saved.len()).unwrap_or(u64::MAX),
        sha256: format!("{:x}", Sha256::digest(&saved)),
    };
    Ok(vec![AgentEvent::OutputAttachment {
        turn_id,
        attachment,
    }])
}

fn is_png(bytes: &[u8]) -> bool {
    bytes.starts_with(b"\x89PNG\r\n\x1a\n")
}

fn normalize_started_item(method: &str, params: &Value) -> Result<Vec<AgentEvent>, ProtocolError> {
    let turn_id = turn_id_at(method, params, &["turnId"])?;
    let item = value_at(method, params, &["item"])?;
    if item.get("type").and_then(Value::as_str) == Some("agentMessage") {
        return Ok(item
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| safe_provider_id(id))
            .map(|item_id| AgentEvent::AgentMessage {
                turn_id,
                item_id: item_id.to_string(),
                phase: message_phase(item),
                update: AgentMessageUpdate::Started,
            })
            .into_iter()
            .collect());
    }
    let Some(activity) = codex_item_activity(method, &turn_id, item, ActivityStatus::InProgress)?
    else {
        return Ok(Vec::new());
    };
    Ok(vec![AgentEvent::ActivityUpsert { turn_id, activity }])
}

fn normalize_command_output_progress(
    _method: &str,
    _params: &Value,
) -> Result<Vec<AgentEvent>, ProtocolError> {
    Ok(Vec::new())
}

fn normalize_file_change_progress(
    method: &str,
    params: &Value,
) -> Result<Vec<AgentEvent>, ProtocolError> {
    let turn_id = turn_id_at(method, params, &["turnId"])?;
    let activity_id = string_at(method, params, &["itemId"])?;
    let paths = params
        .get("changes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|change| change.get("path").and_then(Value::as_str))
        .map(PathBuf::from);
    Ok(ActivityUpsert::new(
        activity_id,
        ActivitySemanticKind::Edit,
        ActivityStatus::InProgress,
        "Updating files",
    )
    .map(|activity| activity.with_detail("Patch updated.").with_paths(paths))
    .map(|activity| AgentEvent::ActivityUpsert { turn_id, activity })
    .into_iter()
    .collect())
}

fn codex_item_activity(
    method: &str,
    _turn_id: &TurnId,
    item: &Value,
    fallback_status: ActivityStatus,
) -> Result<Option<ActivityUpsert>, ProtocolError> {
    let item_type = string_at(method, item, &["type"])?;
    let id = string_at(method, item, &["id"])?;
    let status = item
        .get("status")
        .and_then(Value::as_str)
        .map(codex_item_status)
        .unwrap_or(fallback_status);
    let activity = match item_type.as_str() {
        "commandExecution" => ActivityUpsert::new(
            id,
            command_semantics(item).0,
            item.get("status")
                .and_then(Value::as_str)
                .map(codex_command_status)
                .unwrap_or(fallback_status),
            command_semantics(item).1,
        )
        .map(|activity| {
            // Explicit per-chat verbose mode remains secret-safe. Command output
            // bytes stay omitted and the visible command is scrubbed before it
            // enters the provider-neutral activity contract.
            let activity = if let Some(command) = item
                .get("command")
                .and_then(Value::as_str)
                .and_then(sanitize_visible_command)
            {
                activity.with_detail(command)
            } else {
                activity
            };
            activity
                .with_paths(item.get("cwd").and_then(Value::as_str).map(PathBuf::from))
                .with_exit_code(
                    item.get("exitCode")
                        .and_then(Value::as_i64)
                        .and_then(|code| i32::try_from(code).ok()),
                )
        }),
        "fileChange" => codex_file_change_activity_from_id(&id, item, fallback_status),
        "mcpToolCall" | "dynamicToolCall" => {
            let name = item
                .get("tool")
                .and_then(Value::as_str)
                .or_else(|| item.get("server").and_then(Value::as_str))
                .unwrap_or_default();
            let presentation = native_tool_activity(name, ActivitySemanticKind::Other);
            ActivityUpsert::new(
                id,
                presentation.kind,
                if item.get("success").and_then(Value::as_bool) == Some(false)
                    || item.get("error").is_some_and(|error| !error.is_null())
                {
                    ActivityStatus::Failed
                } else {
                    status
                },
                presentation.title,
            )
        }
        "webSearch" => {
            ActivityUpsert::new(id, ActivitySemanticKind::Search, status, "Search the web")
        }
        "collabAgentToolCall" => {
            ActivityUpsert::new(id, ActivitySemanticKind::Other, status, "Delegate to agent")
        }
        "enteredReviewMode" | "exitedReviewMode" => {
            ActivityUpsert::new(id, ActivitySemanticKind::Other, status, "Review changes")
        }
        "contextCompaction" => {
            ActivityUpsert::new(id, ActivitySemanticKind::Other, status, "Compact context")
        }
        "reasoning" => None,
        _ => None,
    };
    Ok(activity)
}

fn command_semantics(item: &Value) -> (ActivitySemanticKind, &'static str) {
    let actions = item.get("commandActions").and_then(Value::as_array);
    let Some(actions) = actions.filter(|actions| !actions.is_empty() && actions.len() <= 32) else {
        return (ActivitySemanticKind::Execute, "Run command");
    };
    let first = actions[0].get("type").and_then(Value::as_str);
    if !actions
        .iter()
        .all(|action| action.get("type").and_then(Value::as_str) == first)
    {
        return (ActivitySemanticKind::Execute, "Run command");
    }
    match first {
        Some("read") => (ActivitySemanticKind::Read, "Read files"),
        Some("search") => (ActivitySemanticKind::Search, "Search files"),
        Some("listFiles") => (ActivitySemanticKind::Read, "List files"),
        _ => (ActivitySemanticKind::Execute, "Run command"),
    }
}

fn codex_file_change_activity(
    item: &Value,
    fallback_status: ActivityStatus,
) -> Option<ActivityUpsert> {
    let id = item.get("id").and_then(Value::as_str)?;
    codex_file_change_activity_from_id(id, item, fallback_status)
}

fn codex_file_change_activity_from_id(
    id: &str,
    item: &Value,
    fallback_status: ActivityStatus,
) -> Option<ActivityUpsert> {
    let paths = item
        .get("changes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|change| change.get("path").and_then(Value::as_str))
        .map(PathBuf::from);
    let status = item
        .get("status")
        .and_then(Value::as_str)
        .map(codex_item_status)
        .unwrap_or(fallback_status);
    ActivityUpsert::new(id, ActivitySemanticKind::Edit, status, "Updating files")
        .map(|activity| activity.with_paths(paths))
}

fn codex_item_status(status: &str) -> ActivityStatus {
    match status {
        "completed" => ActivityStatus::Completed,
        "declined" => ActivityStatus::Declined,
        "cancelled" => ActivityStatus::Cancelled,
        "failed" => ActivityStatus::Failed,
        "pending" => ActivityStatus::Pending,
        _ => ActivityStatus::InProgress,
    }
}

fn message_phase(item: &Value) -> Option<AgentMessagePhase> {
    item.get("phase")
        .and_then(Value::as_str)
        .map(|phase| match phase {
            "commentary" => AgentMessagePhase::Commentary,
            "final_answer" => AgentMessagePhase::FinalAnswer,
            _ => AgentMessagePhase::Unknown,
        })
}

fn codex_command_status(status: &str) -> ActivityStatus {
    codex_item_status(status)
}

fn normalize_completed_turn(
    method: &str,
    params: &Value,
) -> Result<Vec<AgentEvent>, ProtocolError> {
    let turn_id = turn_id_at(method, params, &["turn", "id"])?;
    let status = string_at(method, params, &["turn", "status"])?;
    let codex_error_info = params
        .get("turn")
        .and_then(|turn| turn.get("error"))
        .and_then(|error| error.get("codexErrorInfo"))
        .and_then(Value::as_str);
    let outcome = match (status.as_str(), codex_error_info) {
        (_, Some("unauthorized")) => TurnOutcome::AuthenticationRequired,
        ("completed", _) => TurnOutcome::Completed,
        ("interrupted", _) => TurnOutcome::Interrupted,
        ("failed", _) => TurnOutcome::Failed,
        _ => {
            return Err(ProtocolError::InvalidField {
                method: method.to_string(),
                field: "turn.status",
            });
        }
    };
    let error = params
        .get("turn")
        .and_then(|turn| turn.get("error"))
        .and_then(|error| error.get("message"))
        .and_then(Value::as_str)
        .map(|error| {
            error
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
                .chars()
                .take(MAX_TURN_ERROR_CHARS)
                .collect::<String>()
        });
    let error = if outcome == TurnOutcome::AuthenticationRequired {
        Some(
            "Codex requires authentication on this computer. Run `codex login`, then retry."
                .to_string(),
        )
    } else {
        error
    };
    Ok(vec![AgentEvent::TurnCompleted {
        turn_id,
        outcome,
        error,
        timing: TurnTiming::from_provider_duration_ms(
            params
                .get("turn")
                .and_then(|turn| turn.get("durationMs"))
                .and_then(Value::as_i64),
        ),
    }])
}

fn approval_options(params: &Value, command: bool) -> Vec<ApprovalOption> {
    let Some(available) = params.get("availableDecisions").and_then(Value::as_array) else {
        return if command {
            vec![
                ApprovalOption::ApproveOnce,
                ApprovalOption::ApproveForSession,
                ApprovalOption::Reject,
                ApprovalOption::CancelTurn,
            ]
        } else {
            vec![
                ApprovalOption::ApproveOnce,
                ApprovalOption::ApproveForSession,
                ApprovalOption::Reject,
            ]
        };
    };
    available
        .iter()
        .filter_map(Value::as_str)
        .map(|decision| match decision {
            "accept" => ApprovalOption::ApproveOnce,
            "acceptForSession" => ApprovalOption::ApproveForSession,
            "decline" => ApprovalOption::Reject,
            "cancel" => ApprovalOption::CancelTurn,
            other => ApprovalOption::ProviderChoice {
                option_id: other.to_string(),
                label: other.to_string(),
            },
        })
        .collect()
}

fn turn_id_at(method: &str, value: &Value, path: &[&'static str]) -> Result<TurnId, ProtocolError> {
    let raw = string_at(method, value, path)?;
    if !safe_provider_id(&raw) {
        return Err(ProtocolError::InvalidField {
            method: method.to_string(),
            field: "turn id",
        });
    }
    TurnId::new(raw).map_err(|_| ProtocolError::InvalidField {
        method: method.to_string(),
        field: "turn id",
    })
}

fn safe_provider_id(value: &str) -> bool {
    !value.trim().is_empty()
        && value.len() <= MAX_PROVIDER_ID_BYTES
        && !value.chars().any(char::is_control)
}

fn bounded_question_text_at(
    method: &str,
    value: &Value,
    path: &[&'static str],
    maximum_chars: usize,
) -> Result<String, ProtocolError> {
    let text = string_at(method, value, path)?;
    bounded_question_text(
        method,
        path.last().copied().unwrap_or("question"),
        &text,
        maximum_chars,
    )
}

fn bounded_question_text(
    method: &str,
    field: &'static str,
    value: &str,
    maximum_chars: usize,
) -> Result<String, ProtocolError> {
    if value.trim().is_empty()
        || value.chars().count() > maximum_chars
        || value
            .chars()
            .any(|character| character.is_control() && !matches!(character, '\n' | '\r' | '\t'))
    {
        return Err(ProtocolError::InvalidField {
            method: method.to_string(),
            field,
        });
    }
    Ok(value.to_string())
}

fn string_at(method: &str, value: &Value, path: &[&'static str]) -> Result<String, ProtocolError> {
    value_at(method, value, path)?
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| ProtocolError::InvalidField {
            method: method.to_string(),
            field: path.last().copied().unwrap_or("value"),
        })
}

fn value_at<'a>(
    method: &str,
    mut value: &'a Value,
    path: &[&'static str],
) -> Result<&'a Value, ProtocolError> {
    for &field in path {
        value = value
            .get(field)
            .ok_or_else(|| ProtocolError::MissingField {
                method: method.to_string(),
                field,
            })?;
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const FIRST_VERIFIED_COMPATIBILITY_FIXTURE: &str =
        include_str!("../tests/fixtures/app-server-0.146.0.json");
    const LATEST_VERIFIED_COMPATIBILITY_FIXTURE: &str =
        include_str!("../tests/fixtures/app-server-0.150.0-alpha.8.json");

    #[test]
    fn initialize_identifies_inline() {
        let value = serde_json::to_value(InitializeParams::inline("0.6.2"))
            .expect("serialize initialize params");
        assert_eq!(value["clientInfo"]["name"], "inline_agent_bridge");
        assert_eq!(value["clientInfo"]["version"], "0.6.2");
        assert_eq!(value["capabilities"]["experimentalApi"], true);
    }

    #[test]
    fn verified_app_server_fixtures_match_supported_normalizers() {
        for (contents, expected_version) in [
            (
                FIRST_VERIFIED_COMPATIBILITY_FIXTURE,
                crate::minimum_codex_version(),
            ),
            (
                LATEST_VERIFIED_COMPATIBILITY_FIXTURE,
                semver::Version::parse("0.150.0-alpha.8").expect("fixture version"),
            ),
        ] {
            verify_compatibility_fixture(contents, expected_version);
        }
    }

    fn verify_compatibility_fixture(contents: &str, expected_version: semver::Version) {
        let fixture: Value = serde_json::from_str(contents).expect("compatibility fixture");
        assert_eq!(
            fixture["codexVersion"]
                .as_str()
                .and_then(|version| semver::Version::parse(version).ok()),
            Some(expected_version.clone())
        );
        assert!(crate::is_compatible_codex_version(&expected_version));
        let schema_hashes = fixture["schemaSha256"]
            .as_object()
            .expect("schema hash manifest");
        assert_eq!(schema_hashes.len(), 17);
        assert!(schema_hashes.values().all(|hash| {
            hash.as_str().is_some_and(|hash| {
                hash.len() == 64 && hash.bytes().all(|byte| byte.is_ascii_hexdigit())
            })
        }));

        assert_eq!(
            provider_session_id_from_response("thread/start", &fixture["startResponses"]["thread"])
                .expect("thread fixture")
                .as_str(),
            "thread-fixture"
        );
        assert_eq!(
            turn_id_from_response("turn/start", &fixture["startResponses"]["turn"])
                .expect("turn fixture")
                .as_str(),
            "turn-fixture"
        );

        for request in fixture["serverRequests"]
            .as_array()
            .expect("server requests")
        {
            let method = request["method"].as_str().expect("request method");
            if method == "item/tool/requestUserInput" {
                normalize_question_request(&request["id"], method, &request["params"])
                    .expect("question fixture");
            } else {
                normalize_server_request(&request["id"], method, &request["params"])
                    .expect("approval fixture");
            }
        }
        for notification in fixture["notifications"].as_array().expect("notifications") {
            let events = normalize_notification(CodexNotification {
                method: notification["method"]
                    .as_str()
                    .expect("notification method")
                    .to_string(),
                params: notification["params"].clone(),
            })
            .expect("notification fixture");
            assert!(!events.is_empty());
        }
    }

    #[test]
    fn turn_start_uses_app_server_text_shape() {
        let value = serde_json::to_value(StartTurnParams::text("thread-1", "Run tests"))
            .expect("serialize turn params");
        assert_eq!(value["threadId"], "thread-1");
        assert_eq!(value["input"][0]["type"], "text");
        assert_eq!(value["input"][0]["text"], "Run tests");
    }

    #[test]
    fn turn_start_uses_native_app_server_image_shape() {
        let mut params = StartTurnParams::text("thread-1", "Inspect this image");
        params.input.push(UserInput::Image {
            url: "data:image/jpeg;base64,YWJj".to_string(),
        });
        let value = serde_json::to_value(params).expect("serialize image input");
        assert_eq!(value["input"][1]["type"], "image");
        assert_eq!(value["input"][1]["url"], "data:image/jpeg;base64,YWJj");
    }

    #[test]
    fn turn_start_uses_native_app_server_local_media_shapes() {
        let mut params = StartTurnParams::text("thread-1", "Inspect these attachments");
        params.input.extend([
            UserInput::LocalImage {
                path: PathBuf::from("/private/cache/image.png"),
            },
            UserInput::LocalAudio {
                path: PathBuf::from("/private/cache/voice.m4a"),
            },
        ]);
        let value = serde_json::to_value(params).expect("serialize local media inputs");
        assert_eq!(value["input"][1]["type"], "localImage");
        assert_eq!(value["input"][1]["path"], "/private/cache/image.png");
        assert_eq!(value["input"][2]["type"], "localAudio");
        assert_eq!(value["input"][2]["path"], "/private/cache/voice.m4a");
        assert!(value["input"][1].get("url").is_none());
        assert!(value["input"][2].get("url").is_none());
    }

    #[test]
    fn completed_image_generation_becomes_a_verified_output_attachment() {
        let directory = tempfile::tempdir().expect("tempdir");
        let path = directory.path().join("generated.png");
        let png = b"\x89PNG\r\n\x1a\nverified-image";
        fs::write(&path, png).expect("write image");

        let events = normalize_notification(CodexNotification {
            method: "item/completed".to_string(),
            params: json!({
                "turnId": "turn-1",
                "item": {
                    "id": "image-1",
                    "type": "imageGeneration",
                    "status": "completed",
                    "result": BASE64_STANDARD.encode(png),
                    "savedPath": path,
                }
            }),
        })
        .expect("image generation");

        assert!(matches!(
            events.as_slice(),
            [AgentEvent::OutputAttachment { attachment, .. }]
                if attachment.id == "image-1"
                    && attachment.kind == OutputAttachmentKind::Image
                    && attachment.size_bytes == png.len() as u64
                    && attachment.sha256.len() == 64
        ));
        assert_eq!(
            unsupported_notification_diagnostic(
                "item/completed",
                &json!({ "item": { "type": "imageGeneration" } }),
            ),
            None
        );
    }

    #[test]
    fn completed_image_generation_rejects_a_changed_saved_file() {
        let directory = tempfile::tempdir().expect("tempdir");
        let path = directory.path().join("generated.png");
        fs::write(&path, b"\x89PNG\r\n\x1a\ntampered").expect("write image");
        let expected = b"\x89PNG\r\n\x1a\nexpected";

        let error = normalize_notification(CodexNotification {
            method: "item/completed".to_string(),
            params: json!({
                "turnId": "turn-1",
                "item": {
                    "id": "image-1",
                    "type": "imageGeneration",
                    "status": "completed",
                    "result": BASE64_STANDARD.encode(expected),
                    "savedPath": path,
                }
            }),
        })
        .expect_err("changed file must fail");

        assert_eq!(
            error,
            ProtocolError::InvalidField {
                method: "item/completed".to_string(),
                field: "item.savedPath",
            }
        );
    }

    #[test]
    fn normalizes_agent_delta() {
        let events = normalize_notification(CodexNotification {
            method: "item/agentMessage/delta".to_string(),
            params: json!({ "turnId": "turn-1", "itemId": "item-1", "delta": "Hello" }),
        })
        .expect("normalize delta");
        assert_eq!(
            events,
            vec![AgentEvent::AgentMessage {
                turn_id: TurnId::new("turn-1").expect("turn id"),
                item_id: "item-1".into(),
                phase: None,
                update: AgentMessageUpdate::Delta("Hello".into()),
            }]
        );
    }

    #[test]
    fn assistant_lifecycle_preserves_identity_phase_and_empty_authoritative_snapshot() {
        for (method, phase, expected) in [
            ("item/started", "commentary", AgentMessageUpdate::Started),
            (
                "item/completed",
                "final_answer",
                AgentMessageUpdate::Completed(String::new()),
            ),
            (
                "item/completed",
                "future_phase",
                AgentMessageUpdate::Completed(String::new()),
            ),
        ] {
            let events = normalize_notification(CodexNotification {
                method: method.into(), params: json!({"turnId": "turn-1", "item": {"id": "message-1", "type": "agentMessage", "phase": phase, "text": ""}}),
            }).unwrap();
            let expected_phase = match phase {
                "commentary" => AgentMessagePhase::Commentary,
                "final_answer" => AgentMessagePhase::FinalAnswer,
                _ => AgentMessagePhase::Unknown,
            };
            assert_eq!(
                events,
                vec![AgentEvent::AgentMessage {
                    turn_id: TurnId::new("turn-1").unwrap(),
                    item_id: "message-1".into(),
                    phase: Some(expected_phase),
                    update: expected
                }]
            );
        }
    }

    #[test]
    fn command_actions_and_tool_completions_use_safe_semantics() {
        let events = normalize_notification(CodexNotification {
            method: "item/started".into(), params: json!({"turnId":"turn-1", "item": {"id":"cmd", "type":"commandExecution", "command":"cat src/lib.rs", "commandActions":[{"type":"read","name":"lib.rs","path":"/private/project/src/lib.rs"}]}}),
        }).unwrap();
        assert!(
            matches!(&events[0], AgentEvent::ActivityUpsert { activity, .. } if activity.kind == ActivitySemanticKind::Read && activity.title == "Read files")
        );
        for kind in [
            "mcpToolCall",
            "dynamicToolCall",
            "webSearch",
            "collabAgentToolCall",
            "contextCompaction",
        ] {
            let events = normalize_notification(CodexNotification {
                method: "item/completed".into(), params: json!({"turnId":"turn-1", "item": {"id":"tool", "type":kind, "status":"completed", "tool":"read_file", "arguments":{"token":"secret-should-not-appear"}, "result":"private output"}}),
            }).unwrap();
            assert!(
                matches!(&events[0], AgentEvent::ActivityUpsert { activity, .. } if activity.status == ActivityStatus::Completed)
            );
            assert!(!format!("{events:?}").contains("secret-should-not-appear"));
            assert!(!format!("{events:?}").contains("private output"));
        }
        let events = normalize_notification(CodexNotification { method: "item/started".into(), params: json!({"turnId":"turn-1", "item":{"id":"think", "type":"reasoning", "text":"private reasoning"}}) }).unwrap();
        assert!(events.is_empty());
    }

    #[test]
    fn normalizes_replace_all_plan_snapshot() {
        let events = normalize_notification(CodexNotification {
            method: "turn/plan/updated".to_string(),
            params: json!({
                "turnId": "turn-1",
                "explanation": "  Revised   after inspection. ",
                "plan": [
                    { "step": "Inspect", "status": "completed" },
                    { "step": "Implement", "status": "inProgress" },
                    { "step": "Verify", "status": "pending" }
                ]
            }),
        })
        .expect("normalize plan");
        assert_eq!(
            events,
            vec![AgentEvent::PlanUpdated {
                turn_id: TurnId::new("turn-1").expect("turn id"),
                explanation: Some("Revised after inspection.".to_string()),
                steps: vec![
                    PlanStep {
                        text: "Inspect".to_string(),
                        status: PlanStepStatus::Completed,
                    },
                    PlanStep {
                        text: "Implement".to_string(),
                        status: PlanStepStatus::InProgress,
                    },
                    PlanStep {
                        text: "Verify".to_string(),
                        status: PlanStepStatus::Pending,
                    },
                ],
            }]
        );
    }

    #[test]
    fn unknown_notification_diagnostics_are_bounded_and_payload_free() {
        assert_eq!(
            unsupported_notification_diagnostic(
                "account/updated",
                &json!({ "accessToken": "must-not-appear" })
            )
            .as_deref(),
            Some("unsupported Codex notification method account/updated")
        );
        assert_eq!(
            unsupported_notification_diagnostic(
                "item/completed",
                &json!({
                    "turnId": "turn-1",
                    "item": { "type": "future$item", "secret": "must-not-appear" }
                })
            )
            .as_deref(),
            Some("unsupported Codex item type [unrecognized]")
        );
        assert_eq!(
            unsupported_notification_diagnostic(&"a".repeat(97), &json!({})).as_deref(),
            Some("unsupported Codex notification method [unrecognized]")
        );
    }

    #[test]
    fn normalizes_file_changes_without_diff_body() {
        let events = normalize_notification(CodexNotification {
            method: "item/completed".to_string(),
            params: json!({
                "turnId": "turn-1",
                "item": {
                    "type": "fileChange",
                    "changes": [{ "path": "/repo/src/lib.rs", "kind": "update", "diff": "large" }]
                }
            }),
        })
        .expect("normalize files");
        assert_eq!(
            events,
            vec![AgentEvent::FilesChanged {
                turn_id: TurnId::new("turn-1").expect("turn id"),
                files: vec![FileChange {
                    path: PathBuf::from("/repo/src/lib.rs"),
                    summary: Some("updated".to_string())
                }]
            }]
        );
    }

    #[test]
    fn normalizes_codex_item_lifecycle_without_raw_reasoning_or_output() {
        let started = normalize_notification(CodexNotification {
            method: "item/started".to_string(),
            params: json!({
                "turnId": "turn-1",
                "item": {
                    "id": "command-1",
                    "type": "commandExecution",
                    "command": "cargo test -p inline-agent-bridge --token must-not-appear",
                    "cwd": "/workspace",
                    "status": "inProgress",
                    "aggregatedOutput": "private output must not appear"
                }
            }),
        })
        .expect("started item");
        assert!(matches!(
            started.as_slice(),
            [AgentEvent::ActivityUpsert { activity, .. }]
                if activity.activity_id == "command-1"
                    && activity.kind == ActivitySemanticKind::Execute
                    && activity.status == ActivityStatus::InProgress
                    && activity.detail.as_deref()
                        == Some("cargo test -p inline-agent-bridge --token [redacted]")
                    && activity.paths == [PathBuf::from("/workspace")]
        ));

        let progress = normalize_notification(CodexNotification {
            method: "item/commandExecution/outputDelta".to_string(),
            params: json!({
                "turnId": "turn-1",
                "itemId": "command-1",
                "delta": "secret output must not appear"
            }),
        })
        .expect("progress");
        assert!(
            progress.is_empty(),
            "raw output does not replace semantic activity metadata"
        );

        let completed = normalize_notification(CodexNotification {
            method: "item/completed".to_string(),
            params: json!({
                "turnId": "turn-1",
                "item": {
                    "id": "command-1",
                    "type": "commandExecution",
                    "command": "cargo test -p inline-agent-bridge",
                    "cwd": "/workspace",
                    "status": "declined",
                    "exitCode": 126,
                    "aggregatedOutput": "secret output must not appear"
                }
            }),
        })
        .expect("completed item");
        assert!(matches!(
            completed.as_slice(),
            [AgentEvent::ActivityUpsert { activity, .. }]
                if activity.status == ActivityStatus::Declined
                    && activity.exit_code == Some(126)
                    && activity.detail.as_deref() == Some("cargo test -p inline-agent-bridge")
                    && !format!("{activity:?}").contains("secret output")
        ));
    }

    #[test]
    fn malformed_command_identity_does_not_expose_raw_command() {
        let events = normalize_notification(CodexNotification {
            method: "item/completed".to_string(),
            params: json!({
                "turnId": "turn-1",
                "item": {
                    "id": "x".repeat(300),
                    "type": "commandExecution",
                    "command": "private command --token secret",
                    "status": "failed"
                }
            }),
        })
        .expect("normalize malformed command identity");
        assert!(events.is_empty());
    }

    #[test]
    fn command_activity_preserves_only_secret_safe_bounded_details() {
        for (id, command, expected) in [
            (
                "safe-check",
                "cargo test -p inline-agent-bridge --token must-not-appear",
                "cargo test -p inline-agent-bridge --token [redacted]",
            ),
            (
                "unknown-command",
                "deploy --api-key=must-not-appear https://signed.example/file?token=private",
                "deploy --api-key=[redacted] https://signed.example/file?[redacted]",
            ),
        ] {
            let events = normalize_notification(CodexNotification {
                method: "item/started".to_string(),
                params: json!({
                    "turnId": "turn-1",
                    "item": {
                        "id": id,
                        "type": "commandExecution",
                        "command": command,
                        "status": "inProgress"
                    }
                }),
            })
            .expect("normalize command");
            assert!(matches!(
                events.as_slice(),
                [AgentEvent::ActivityUpsert { activity, .. }]
                    if activity.detail.as_deref() == Some(expected)
            ));
        }
    }

    #[test]
    fn classifies_codex_unauthorized_turns_without_using_error_text() {
        let events = normalize_notification(CodexNotification {
            method: "turn/completed".to_string(),
            params: json!({
                "turn": {
                    "id": "turn-1",
                    "status": "failed",
                    "error": {
                        "message": "provider wording must not decide this outcome",
                        "codexErrorInfo": "unauthorized"
                    }
                }
            }),
        })
        .expect("normalize completion");
        assert!(matches!(
            events.as_slice(),
            [AgentEvent::TurnCompleted {
                outcome: TurnOutcome::AuthenticationRequired,
                error: Some(error),
                ..
            }] if error == "Codex requires authentication on this computer. Run `codex login`, then retry."
        ));
    }

    #[test]
    fn preserves_codex_cumulative_turn_duration() {
        let events = normalize_notification(CodexNotification {
            method: "turn/completed".to_string(),
            params: json!({
                "turn": {
                    "id": "turn-1",
                    "status": "completed",
                    "durationMs": 125900
                }
            }),
        })
        .expect("normalize completion");
        assert!(matches!(
            events.as_slice(),
            [AgentEvent::TurnCompleted { timing, .. }]
                if timing.provider_duration_ms == Some(125_900)
        ));
    }

    #[test]
    fn preserves_codex_file_change_terminal_lifecycle() {
        let events = normalize_notification(CodexNotification {
            method: "item/completed".to_string(),
            params: json!({
                "turnId": "turn-1",
                "item": {
                    "id": "file-1",
                    "type": "fileChange",
                    "status": "declined",
                    "changes": [{ "path": "/workspace/src/lib.rs", "kind": "update" }]
                }
            }),
        })
        .expect("file completion");
        assert!(matches!(
            events.as_slice(),
            [AgentEvent::FilesChanged { .. }, AgentEvent::ActivityUpsert { activity, .. }]
                if activity.status == ActivityStatus::Declined
        ));
    }

    #[test]
    fn normalizes_command_approval_with_available_decisions() {
        let request = normalize_server_request(
            &json!(17),
            "item/commandExecution/requestApproval",
            &json!({
                "turnId": "turn-1",
                "command": "cargo test",
                "cwd": "/repo",
                "availableDecisions": ["accept", "decline"]
            }),
        )
        .expect("normalize approval");
        assert_eq!(request.approval_id, "17");
        assert_eq!(
            request.options,
            [ApprovalOption::ApproveOnce, ApprovalOption::Reject]
        );
        assert_eq!(request.command.as_deref(), Some("cargo test"));
    }

    #[test]
    fn command_approval_redacts_sensitive_arguments() {
        let request = normalize_server_request(
            &json!(17),
            "item/commandExecution/requestApproval",
            &json!({
                "turnId": "turn-1",
                "command": "cargo test -- --token secret-value",
                "cwd": "/repo",
                "availableDecisions": ["accept", "decline"]
            }),
        )
        .expect("normalize approval");
        assert_eq!(
            request.command.as_deref(),
            Some("cargo test -- --token [redacted]")
        );
    }

    #[test]
    fn native_tool_calls_use_semantic_titles_without_raw_identifiers() {
        let events = normalize_notification(CodexNotification {
            method: "item/started".to_string(),
            params: json!({
                "turnId": "turn-1",
                "item": {
                    "id": "tool-1",
                    "type": "dynamicToolCall",
                    "tool": "search_web",
                    "status": "inProgress"
                }
            }),
        })
        .expect("normalize native tool");
        assert!(matches!(
            events.as_slice(),
            [AgentEvent::ActivityUpsert { activity, .. }]
                if activity.kind == ActivitySemanticKind::Search
                    && activity.title == "Searching the web"
                    && activity.detail.is_none()
        ));
    }

    #[test]
    fn normalizes_user_input_request_and_response() {
        let request = normalize_question_request(
            &json!(23),
            "item/tool/requestUserInput",
            &json!({
                "threadId": "thread-1",
                "turnId": "turn-1",
                "itemId": "item-1",
                "questions": [
                    {
                        "id": "target",
                        "header": "Target",
                        "question": "Which target?",
                        "isOther": true,
                        "isSecret": false,
                        "options": [
                            { "label": "Core", "description": "Inspect core" },
                            { "label": "TUI", "description": "Inspect TUI" }
                        ]
                    },
                    {
                        "id": "details",
                        "header": "Details",
                        "question": "Anything else?",
                        "options": null
                    }
                ],
                "autoResolutionMs": 60000
            }),
        )
        .expect("normalize question");
        assert_eq!(request.request_id, "23");
        assert_eq!(request.turn_id.as_str(), "turn-1");
        assert_eq!(request.questions.len(), 2);
        assert_eq!(request.questions[0].options[1].label, "TUI");
        assert!(request.questions[0].allows_other);
        assert!(!request.questions[0].is_secret);
        assert_eq!(request.auto_resolution_ms, Some(60_000));

        assert_eq!(
            question_result(vec![
                QuestionAnswer {
                    question_id: "target".to_string(),
                    answers: vec!["TUI".to_string()],
                },
                QuestionAnswer {
                    question_id: "details".to_string(),
                    answers: vec!["user_note: Include snapshots".to_string()],
                },
            ]),
            json!({
                "answers": {
                    "target": { "answers": ["TUI"] },
                    "details": { "answers": ["user_note: Include snapshots"] }
                }
            })
        );
    }

    #[test]
    fn rejects_ambiguous_or_unbounded_user_input_requests() {
        let duplicate = json!({
            "turnId": "turn-1",
            "questions": [
                { "id": "same", "header": "One", "question": "First?" },
                { "id": "same", "header": "Two", "question": "Second?" }
            ]
        });
        assert!(matches!(
            normalize_question_request(&json!(1), "item/tool/requestUserInput", &duplicate),
            Err(ProtocolError::InvalidField {
                field: "questions.id",
                ..
            })
        ));

        let too_many = json!({
            "turnId": "turn-1",
            "questions": [
                { "id": "one", "header": "One", "question": "One?" },
                { "id": "two", "header": "Two", "question": "Two?" },
                { "id": "three", "header": "Three", "question": "Three?" },
                { "id": "four", "header": "Four", "question": "Four?" }
            ]
        });
        assert!(matches!(
            normalize_question_request(&json!(1), "item/tool/requestUserInput", &too_many),
            Err(ProtocolError::InvalidField {
                field: "questions",
                ..
            })
        ));

        let oversized = json!({
            "turnId": "turn-1",
            "questions": [{
                "id": "one",
                "header": "One",
                "question": "x".repeat(MAX_QUESTION_PROMPT_CHARS + 1)
            }]
        });
        assert!(matches!(
            normalize_question_request(&json!(1), "item/tool/requestUserInput", &oversized),
            Err(ProtocolError::InvalidField {
                field: "question",
                ..
            })
        ));
        assert!(
            normalize_question_request(
                &json!("x".repeat(MAX_PROVIDER_ID_BYTES + 1)),
                "item/tool/requestUserInput",
                &json!({
                    "turnId": "turn-1",
                    "questions": [{ "id": "one", "header": "One", "question": "One?" }]
                }),
            )
            .is_err()
        );
    }

    #[test]
    fn extracts_thread_and_turn_ids_from_responses() {
        assert_eq!(
            provider_session_id_from_response(
                "thread/start",
                &json!({ "thread": { "id": "thread-1" } })
            )
            .expect("thread id")
            .as_str(),
            "thread-1"
        );
        assert_eq!(
            turn_id_from_response("turn/start", &json!({ "turn": { "id": "turn-1" } }))
                .expect("turn id")
                .as_str(),
            "turn-1"
        );
    }

    #[test]
    fn approval_decisions_use_codex_wire_values() {
        assert_eq!(
            approval_result(inline_agent_bridge::ApprovalDecision::ApproveForSession),
            json!({ "decision": "acceptForSession" })
        );
        assert_eq!(
            approval_result(inline_agent_bridge::ApprovalDecision::CancelTurn),
            json!({ "decision": "cancel" })
        );
    }
}
