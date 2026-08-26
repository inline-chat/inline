//! Stable Codex app-server v2 shapes used by the session catalog.
//!
//! These types intentionally model only the stable fields Inline consumes.
//! Serde ignores additive provider fields, while required identity, scope, and
//! history fields still fail closed when they are absent or malformed.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ThreadListParams {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    pub limit: u32,
    pub sort_key: ThreadSortKey,
    pub sort_direction: SortDirection,
    pub archived: bool,
    pub cwd: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ThreadSortKey {
    UpdatedAt,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum SortDirection {
    Desc,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ThreadListResponse {
    pub data: Vec<CodexThread>,
    pub next_cursor: Option<String>,
    #[serde(default, rename = "backwardsCursor")]
    pub _backwards_cursor: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CodexThread {
    pub id: String,
    #[serde(default)]
    pub preview: String,
    pub updated_at: i64,
    pub status: CodexThreadStatus,
    pub cwd: String,
    #[serde(rename = "source")]
    pub _source: CodexSessionSource,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub turns: Vec<CodexTurn>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum CodexSessionSource {
    Cli,
    #[serde(rename = "vscode")]
    VsCode,
    Exec,
    AppServer,
    Custom(String),
    SubAgent(serde_json::Value),
    #[serde(other)]
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub(crate) enum CodexThreadStatus {
    NotLoaded,
    Idle,
    SystemError,
    Active {
        #[serde(default, rename = "activeFlags")]
        _active_flags: Vec<String>,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ThreadReadParams {
    pub thread_id: String,
    pub include_turns: bool,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub(crate) struct ThreadReadResponse {
    pub thread: CodexThread,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ThreadTurnsListParams {
    pub thread_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    pub limit: u32,
    pub sort_direction: SortDirection,
    pub items_view: TurnItemsView,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum TurnItemsView {
    Full,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ThreadTurnsListResponse {
    pub data: Vec<CodexTurn>,
    pub next_cursor: Option<String>,
    #[serde(default, rename = "backwardsCursor")]
    pub _backwards_cursor: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub(crate) struct ThreadResumeResponse {
    pub thread: CodexThread,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CodexTurn {
    pub id: String,
    #[serde(default)]
    pub items: Vec<CodexThreadItem>,
    #[serde(default)]
    pub started_at: Option<i64>,
    #[serde(default)]
    pub completed_at: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub(crate) enum CodexThreadItem {
    UserMessage {
        id: String,
        #[serde(default, rename = "clientId")]
        client_id: Option<String>,
        #[serde(default)]
        content: Vec<CodexUserInput>,
    },
    AgentMessage {
        id: String,
        text: String,
    },
    Plan {
        id: String,
        text: String,
    },
    CommandExecution {
        id: String,
        command: String,
        status: String,
    },
    FileChange {
        id: String,
        #[serde(default)]
        changes: Vec<serde_json::Value>,
        status: String,
    },
    #[serde(other)]
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub(crate) enum CodexUserInput {
    Text {
        text: String,
    },
    #[serde(other)]
    Unknown,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GetAccountParams {
    pub refresh_token: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GetAccountResponse {
    pub account: Option<CodexAccount>,
    pub requires_openai_auth: bool,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
pub(crate) enum CodexAccount {
    #[serde(rename = "apiKey")]
    ApiKey,
    #[serde(rename = "chatgpt")]
    ChatGpt {
        #[serde(rename = "email")]
        _email: Option<serde::de::IgnoredAny>,
        #[serde(rename = "planType")]
        _plan_type: CodexPlanType,
    },
    #[serde(rename = "amazonBedrock")]
    AmazonBedrock {
        #[serde(default)]
        #[serde(rename = "usesCodexManagedCredentials")]
        _uses_codex_managed_credentials: bool,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CodexPlanType {
    Free,
    Go,
    Plus,
    Pro,
    Prolite,
    Team,
    SelfServeBusinessProlite,
    SelfServeBusinessUsageBased,
    Business,
    Ent26,
    EnterpriseCbpAutomation,
    EnterpriseCbpUsageBased,
    Enterprise,
    Edu,
    EduPlus,
    EduPro,
    #[serde(other)]
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ThreadSetNameParams {
    pub thread_id: String,
    pub name: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ThreadLoadedListParams {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ThreadLoadedListResponse {
    pub data: Vec<String>,
    pub next_cursor: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ThreadUnsubscribeParams {
    pub thread_id: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ThreadUnsubscribeStatus {
    NotLoaded,
    NotSubscribed,
    Unsubscribed,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub(crate) struct ThreadUnsubscribeResponse {
    pub status: ThreadUnsubscribeStatus,
}
