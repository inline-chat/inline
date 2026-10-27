//! Control protocol payloads in both directions.
//!
//! Host → CLI requests are built as JSON objects keyed by `subtype`, so a
//! field this crate does not model can still be sent. CLI → host requests are
//! classified into [`IncomingRequest`], keeping the native payload.

use serde::Deserialize;
use serde_json::{Map, Value, json};

/// The `initialize` request. Everything is optional; [`Self::to_value`]
/// only writes what is set, so older CLIs see a request they understand.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct InitializeRequest {
    /// Hook matchers by event, already carrying `hookCallbackIds`.
    pub hooks: Option<Map<String, Value>>,
    /// Names of in-process MCP servers answered over `mcp_message`.
    pub sdk_mcp_servers: Vec<String>,
    /// Custom agents by name (`AgentDefinition`).
    pub agents: Option<Map<String, Value>>,
    pub append_system_prompt: Option<String>,
    /// A custom session title; skips automatic title generation.
    pub title: Option<String>,
    /// Dialog kinds the host renders. Absent means none (the CLI fails closed).
    pub supported_dialog_kinds: Vec<String>,
    /// The host renders a per-task stop control wired to `stop_task`, so an
    /// interrupt spares running background agents.
    pub per_task_stop_affordance: bool,
    pub forward_subagent_text: bool,
    pub agent_progress_summaries: bool,
    pub prompt_suggestions: bool,
    /// Fields this crate does not model, sent verbatim.
    pub extra: Map<String, Value>,
}

impl InitializeRequest {
    pub fn to_value(&self) -> Value {
        let mut map = Map::new();
        map.insert("subtype".into(), json!("initialize"));
        map.insert(
            "hooks".into(),
            self.hooks.clone().map_or(Value::Null, Value::Object),
        );
        if !self.sdk_mcp_servers.is_empty() {
            map.insert("sdkMcpServers".into(), json!(self.sdk_mcp_servers));
        }
        if let Some(agents) = &self.agents {
            map.insert("agents".into(), Value::Object(agents.clone()));
        }
        if let Some(append) = &self.append_system_prompt {
            map.insert("appendSystemPrompt".into(), json!(append));
        }
        if let Some(title) = &self.title {
            map.insert("title".into(), json!(title));
        }
        if !self.supported_dialog_kinds.is_empty() {
            map.insert(
                "supportedDialogKinds".into(),
                json!(self.supported_dialog_kinds),
            );
        }
        if self.per_task_stop_affordance {
            map.insert("perTaskStopAffordance".into(), json!(true));
        }
        if self.forward_subagent_text {
            map.insert("forwardSubagentText".into(), json!(true));
        }
        if self.agent_progress_summaries {
            map.insert("agentProgressSummaries".into(), json!(true));
        }
        if self.prompt_suggestions {
            map.insert("promptSuggestions".into(), json!(true));
        }
        for (key, value) in &self.extra {
            map.entry(key.clone()).or_insert_with(|| value.clone());
        }
        Value::Object(map)
    }
}

/// The `initialize` response: catalogs and account.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct InitializeResponse {
    pub commands: Vec<SlashCommand>,
    pub agents: Vec<AgentInfo>,
    pub models: Vec<ModelInfo>,
    pub account: Option<Value>,
    pub output_style: Option<String>,
    pub available_output_styles: Vec<String>,
    /// Present on CLIs from about 2.1.30x.
    pub claude_code_version: Option<String>,
    pub fast_mode_state: Option<Value>,
    pub pid: Option<u64>,
    pub current_permission_mode: Option<String>,
    pub session_state: Option<Value>,
    pub capabilities: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SlashCommand {
    pub name: String,
    pub description: Option<String>,
    pub argument_hint: Option<Value>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct AgentInfo {
    pub name: String,
    pub description: Option<String>,
    pub model: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ModelInfo {
    /// The value `set_model` / `--model` accepts (often an alias).
    pub value: String,
    pub display_name: Option<String>,
    pub description: Option<String>,
    pub supports_effort: Option<bool>,
    pub supported_effort_levels: Option<Vec<String>>,
    pub supports_adaptive_thinking: Option<bool>,
    pub supports_fast_mode: Option<bool>,
}

/// The interrupt receipt (`interrupt_receipt_v1`). Both lists are `None` on
/// CLIs that answer with an empty success.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct InterruptReceipt {
    /// Uuids that survive the interrupt and will run next.
    pub still_queued: Option<Vec<String>>,
    /// Uuids the interrupt cancelled (only with `cancel_queued`).
    pub cancelled: Option<Vec<String>>,
}

/// A request the CLI sent to the host.
#[derive(Clone, Debug, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub enum IncomingRequest {
    /// A tool needs permission; also how AskUserQuestion reaches the host.
    CanUseTool(PermissionRequest),
    HookCallback(HookCallbackRequest),
    /// JSON-RPC for an in-process MCP server.
    McpMessage {
        server_name: String,
        message: Value,
    },
    /// An MCP server asked the user for input.
    Elicitation(Value),
    /// A tool-driven blocking dialog (`request_user_dialog`).
    UserDialog(UserDialogRequest),
    /// A subtype this crate does not model.
    Other {
        subtype: String,
        raw: Value,
    },
}

impl IncomingRequest {
    pub fn parse(request: &Value) -> Self {
        let subtype = request
            .get("subtype")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let parsed = match subtype.as_str() {
            "can_use_tool" => PermissionRequest::deserialize(request)
                .ok()
                .map(|mut permission| {
                    permission.raw = request.clone();
                    Self::CanUseTool(permission)
                }),
            "hook_callback" => HookCallbackRequest::deserialize(request)
                .ok()
                .map(Self::HookCallback),
            "mcp_message" => match (
                request.get("server_name").and_then(Value::as_str),
                request.get("message"),
            ) {
                (Some(server_name), Some(message)) if message.is_object() => {
                    Some(Self::McpMessage {
                        server_name: server_name.to_string(),
                        message: message.clone(),
                    })
                }
                _ => None,
            },
            "elicitation" => Some(Self::Elicitation(request.clone())),
            "request_user_dialog" => UserDialogRequest::deserialize(request)
                .ok()
                .map(Self::UserDialog),
            _ => None,
        };
        parsed.unwrap_or(Self::Other {
            subtype,
            raw: request.clone(),
        })
    }
}

/// `can_use_tool`.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct PermissionRequest {
    pub tool_name: String,
    pub input: Value,
    pub tool_use_id: Option<String>,
    /// Set when a subagent asks.
    pub agent_id: Option<String>,
    /// Suggested `PermissionUpdate`s, offered as "always allow" choices.
    pub permission_suggestions: Vec<Value>,
    pub blocked_path: Option<String>,
    pub decision_reason: Option<String>,
    pub decision_reason_type: Option<String>,
    pub title: Option<String>,
    pub display_name: Option<String>,
    pub description: Option<String>,
    pub mcp_server: Option<Value>,
    pub classifier_approvable: Option<bool>,
    /// Omit any persistent "don't ask again" choice.
    pub suppress_always_allow_rule: Option<bool>,
    /// Do not pre-select approve.
    pub default_to_no: Option<bool>,
    /// The ask cannot be answered by a one-tap approve.
    pub requires_user_interaction: Option<bool>,
    #[serde(skip)]
    pub raw: Value,
}

impl PermissionRequest {
    /// AskUserQuestion arrives as a permission request for that tool.
    pub fn is_ask_user_question(&self) -> bool {
        self.tool_name == "AskUserQuestion"
    }

    /// The questions of an AskUserQuestion call.
    pub fn questions(&self) -> Vec<AskQuestion> {
        self.input
            .get("questions")
            .and_then(Value::as_array)
            .map(|questions| {
                questions
                    .iter()
                    .filter_map(|question| AskQuestion::deserialize(question).ok())
                    .collect()
            })
            .unwrap_or_default()
    }
}

/// One question of AskUserQuestion's input.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct AskQuestion {
    pub question: String,
    pub header: Option<String>,
    pub options: Vec<AskOption>,
    pub multi_select: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct AskOption {
    pub label: String,
    pub description: Option<String>,
}

/// The host's answer to `can_use_tool`.
#[derive(Clone, Debug, PartialEq)]
pub enum PermissionDecision {
    Allow {
        /// Replaces the tool input; `None` keeps the original.
        updated_input: Option<Value>,
        /// Permission updates to apply (the suggestions the user picked).
        updated_permissions: Vec<Value>,
    },
    Deny {
        message: String,
        /// Also interrupt the turn.
        interrupt: bool,
    },
}

impl PermissionDecision {
    pub fn allow() -> Self {
        Self::Allow {
            updated_input: None,
            updated_permissions: Vec::new(),
        }
    }

    pub fn deny(message: impl Into<String>) -> Self {
        Self::Deny {
            message: message.into(),
            interrupt: false,
        }
    }

    /// Answers AskUserQuestion: `answers` maps each question's text to the
    /// chosen label (several labels joined with ", " for multi-select).
    pub fn answer_questions(original_input: &Value, answers: Map<String, Value>) -> Self {
        let mut input = original_input.clone();
        if let Some(object) = input.as_object_mut() {
            object.insert("answers".into(), Value::Object(answers));
        }
        Self::Allow {
            updated_input: Some(input),
            updated_permissions: Vec::new(),
        }
    }

    /// The control_response payload. The CLI requires `updatedInput` on
    /// allow, so the original input is sent when none replaces it.
    pub fn to_value(&self, original_input: &Value) -> Value {
        match self {
            Self::Allow {
                updated_input,
                updated_permissions,
            } => {
                let mut map = Map::new();
                map.insert("behavior".into(), json!("allow"));
                map.insert(
                    "updatedInput".into(),
                    updated_input
                        .clone()
                        .unwrap_or_else(|| original_input.clone()),
                );
                if !updated_permissions.is_empty() {
                    map.insert("updatedPermissions".into(), json!(updated_permissions));
                }
                Value::Object(map)
            }
            Self::Deny { message, interrupt } => {
                let mut map = Map::new();
                map.insert("behavior".into(), json!("deny"));
                map.insert("message".into(), json!(message));
                if *interrupt {
                    map.insert("interrupt".into(), json!(true));
                }
                Value::Object(map)
            }
        }
    }
}

/// `hook_callback`.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct HookCallbackRequest {
    pub callback_id: String,
    pub input: Value,
    pub tool_use_id: Option<String>,
}

/// `request_user_dialog`.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct UserDialogRequest {
    pub dialog_kind: String,
    pub payload: Value,
    pub tool_use_id: Option<String>,
}

/// Builders for host → CLI control requests.
pub mod request {
    use serde_json::{Value, json};

    pub fn interrupt(cancel_queued: bool) -> Value {
        if cancel_queued {
            json!({"subtype": "interrupt", "cancel_queued": true})
        } else {
            json!({"subtype": "interrupt"})
        }
    }

    /// `None` resets to the session default model.
    pub fn set_model(model: Option<&str>) -> Value {
        json!({"subtype": "set_model", "model": model})
    }

    pub fn set_permission_mode(mode: &str) -> Value {
        json!({"subtype": "set_permission_mode", "mode": mode})
    }

    /// `None` resets thinking to the session default.
    pub fn set_max_thinking_tokens(tokens: Option<u64>) -> Value {
        json!({"subtype": "set_max_thinking_tokens", "max_thinking_tokens": tokens})
    }

    pub fn get_context_usage() -> Value {
        json!({"subtype": "get_context_usage"})
    }

    pub fn mcp_status() -> Value {
        json!({"subtype": "mcp_status"})
    }

    pub fn mcp_toggle(server_name: &str, enabled: bool) -> Value {
        json!({"subtype": "mcp_toggle", "serverName": server_name, "enabled": enabled})
    }

    pub fn mcp_reconnect(server_name: &str) -> Value {
        json!({"subtype": "mcp_reconnect", "serverName": server_name})
    }

    pub fn rewind_files(user_message_id: &str, dry_run: bool) -> Value {
        if dry_run {
            json!({"subtype": "rewind_files", "user_message_id": user_message_id, "dry_run": true})
        } else {
            json!({"subtype": "rewind_files", "user_message_id": user_message_id})
        }
    }

    pub fn stop_task(task_id: &str) -> Value {
        json!({"subtype": "stop_task", "task_id": task_id})
    }

    /// Drops one queued user message by uuid.
    pub fn cancel_async_message(message_uuid: &str) -> Value {
        json!({"subtype": "cancel_async_message", "message_uuid": message_uuid})
    }

    pub fn rename_session(title: &str, session_id: Option<&str>) -> Value {
        let mut value = json!({"subtype": "rename_session", "title": title, "source": "host"});
        if let Some(session_id) = session_id {
            value["session_id"] = json!(session_id);
        }
        value
    }

    /// Ctrl+B: background one task (by its tool_use id) or all foreground tasks.
    pub fn background_tasks(tool_use_id: Option<&str>) -> Value {
        match tool_use_id {
            Some(id) => json!({"subtype": "background_tasks", "tool_use_id": id}),
            None => json!({"subtype": "background_tasks"}),
        }
    }

    pub fn get_settings() -> Value {
        json!({"subtype": "get_settings"})
    }

    pub fn apply_flag_settings(settings: Value) -> Value {
        json!({"subtype": "apply_flag_settings", "settings": settings})
    }

    pub fn list_models() -> Value {
        json!({"subtype": "list_models"})
    }

    pub fn get_usage() -> Value {
        json!({"subtype": "get_usage"})
    }

    pub fn get_session_cost() -> Value {
        json!({"subtype": "get_session_cost"})
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initialize_writes_only_what_is_set() {
        let request = InitializeRequest {
            sdk_mcp_servers: vec!["inline".into()],
            per_task_stop_affordance: true,
            ..InitializeRequest::default()
        };
        assert_eq!(
            request.to_value(),
            json!({
                "subtype": "initialize",
                "hooks": null,
                "sdkMcpServers": ["inline"],
                "perTaskStopAffordance": true
            })
        );
    }

    #[test]
    fn can_use_tool_is_parsed_with_its_payload() {
        let raw = json!({
            "subtype": "can_use_tool",
            "tool_name": "Bash",
            "input": {"command": "rm -rf build"},
            "tool_use_id": "toolu_1",
            "permission_suggestions": [{"type": "addRules", "destination": "localSettings"}],
            "decision_reason": "dangerous",
            "brand_new": 1
        });
        let IncomingRequest::CanUseTool(request) = IncomingRequest::parse(&raw) else {
            panic!("permission request");
        };
        assert_eq!(request.tool_name, "Bash");
        assert_eq!(request.permission_suggestions.len(), 1);
        assert_eq!(request.raw["brand_new"], json!(1));
    }

    #[test]
    fn allow_echoes_the_original_input() {
        let input = json!({"command": "ls"});
        assert_eq!(
            PermissionDecision::allow().to_value(&input),
            json!({"behavior": "allow", "updatedInput": {"command": "ls"}})
        );
        assert_eq!(
            PermissionDecision::Deny {
                message: "no".into(),
                interrupt: true
            }
            .to_value(&input),
            json!({"behavior": "deny", "message": "no", "interrupt": true})
        );
    }

    #[test]
    fn ask_user_question_answers_ride_on_updated_input() {
        let input = json!({"questions": [{
            "question": "Which color?",
            "header": "Color",
            "options": [{"label": "Red"}, {"label": "Blue"}],
            "multiSelect": false
        }]});
        let raw =
            json!({"subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": input});
        let IncomingRequest::CanUseTool(request) = IncomingRequest::parse(&raw) else {
            panic!("permission request");
        };
        assert!(request.is_ask_user_question());
        let questions = request.questions();
        assert_eq!(questions[0].options[1].label, "Blue");

        let mut answers = Map::new();
        answers.insert("Which color?".into(), json!("Blue"));
        let decision = PermissionDecision::answer_questions(&request.input, answers);
        let value = decision.to_value(&request.input);
        assert_eq!(
            value["updatedInput"]["answers"]["Which color?"],
            json!("Blue")
        );
        assert_eq!(
            value["updatedInput"]["questions"][0]["header"],
            json!("Color")
        );
    }

    #[test]
    fn unknown_and_malformed_requests_are_other() {
        let raw = json!({"subtype": "mcp_message", "server_name": "inline"});
        assert!(matches!(
            IncomingRequest::parse(&raw),
            IncomingRequest::Other { ref subtype, .. } if subtype == "mcp_message"
        ));
        let raw = json!({"subtype": "side_question"});
        assert!(matches!(
            IncomingRequest::parse(&raw),
            IncomingRequest::Other { .. }
        ));
    }

    #[test]
    fn interrupt_receipt_tolerates_old_clis() {
        let receipt: InterruptReceipt = serde_json::from_value(json!({})).unwrap();
        assert_eq!(receipt, InterruptReceipt::default());
        let receipt: InterruptReceipt =
            serde_json::from_value(json!({"still_queued": [], "cancelled": ["l1", "l2"]})).unwrap();
        assert_eq!(receipt.cancelled.unwrap(), ["l1", "l2"]);
    }
}
