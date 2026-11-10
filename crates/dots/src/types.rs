//! Wire types for the ChatGPT Dots endpoints.
//!
//! Field sets cover what the bridge reads. Unknown fields are ignored so
//! additive server changes do not break the bridge; fields the bridge relies
//! on are required and checked in [`crate::client`].

use std::collections::BTreeMap;

use chrono::{DateTime, FixedOffset};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `GET /tbo/primary`.
#[derive(Clone, Debug, Deserialize)]
pub struct Primary {
    /// The selected primary Dot, if any.
    pub selection: Option<PrimarySelection>,
    /// The Dot profile; newer servers inline it here.
    #[serde(default)]
    pub profile: Option<Profile>,
}

/// The primary Dot selection.
#[derive(Clone, Debug, Deserialize)]
pub struct PrimarySelection {
    /// Root conversation thread.
    pub thread_id: String,
    /// Dot (aeon) id.
    pub aeon_id: String,
    /// Native DM room.
    pub messaging_room_id: String,
    /// Whether the Dot can be used.
    #[serde(default)]
    pub available: bool,
    /// Selection generation.
    #[serde(default)]
    pub generation: Option<String>,
}

/// `GET /tbo/by-thread/{thread}`.
#[derive(Clone, Debug, Deserialize)]
pub struct Profile {
    /// Aeon id.
    pub id: String,
    /// `active` for a usable Dot.
    pub status: String,
    /// Name shown in ChatGPT.
    #[serde(default)]
    pub display_name: Option<String>,
    /// Native DM room.
    pub messaging_room_id: String,
    /// Root thread.
    #[serde(default)]
    pub active_root_thread_id: Option<String>,
    /// Rendered avatar.
    #[serde(default)]
    pub avatar_url: Option<String>,
    /// Paused by the owner.
    #[serde(default)]
    pub is_paused: bool,
    /// Paused by OpenAI.
    #[serde(default)]
    pub is_admin_paused: bool,
}

impl Profile {
    /// Display name with the same fallback ChatGPT uses.
    pub fn name(&self) -> &str {
        self.display_name
            .as_deref()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .unwrap_or("Your Dot")
    }
}

/// `GET /messaging/rooms/{room}`.
#[derive(Clone, Debug, Deserialize)]
pub struct Room {
    /// Room id.
    pub id: String,
    /// `DM` for a Dot room.
    #[serde(rename = "type")]
    pub kind: String,
    /// `chatgpt:messaging` for a Dot room.
    #[serde(default)]
    pub app_source: Option<String>,
    /// Dot aeon id.
    #[serde(default)]
    pub aeon_id: Option<String>,
    /// Exactly two members: the owner and the Dot.
    #[serde(default)]
    pub members: Vec<Member>,
    /// Newest messages; `null` on current servers.
    #[serde(default)]
    pub latest_messages: Option<Vec<MessageStub>>,
    /// Per-member read positions.
    #[serde(default, deserialize_with = "null_as_default")]
    pub read_receipts: Vec<ReadReceipt>,
}

/// A member's read position.
#[derive(Clone, Debug, Deserialize)]
pub struct ReadReceipt {
    /// Member.
    pub account_user_id: String,
    /// RFC 3339 read time.
    pub last_read_at: String,
}

/// Room member.
#[derive(Clone, Debug, Deserialize)]
pub struct Member {
    /// Sender id used on messages and reactions.
    pub account_user_id: String,
    /// Present on the Dot member only.
    #[serde(default)]
    pub aeon_id: Option<String>,
    /// Display name.
    #[serde(default)]
    pub name: Option<String>,
}

/// Minimal message reference.
#[derive(Clone, Debug, Deserialize)]
pub struct MessageStub {
    /// Message id.
    pub id: String,
    /// Creation time.
    pub created_at: String,
}

/// `GET /messaging/rooms/{room}/messages`.
#[derive(Clone, Debug, Deserialize)]
pub struct Page {
    /// Messages, in server order (not trusted; callers sort).
    #[serde(default)]
    pub items: Vec<Message>,
    /// Cursor for newer messages.
    #[serde(default)]
    pub next_cursor: Option<String>,
    /// Cursor for older messages.
    #[serde(default)]
    pub prev_cursor: Option<String>,
}

/// A Dot room message.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct Message {
    /// Message id.
    pub id: String,
    /// RFC 3339 creation time.
    pub created_at: String,
    /// RFC 3339 last update.
    #[serde(default)]
    pub updated_at: Option<String>,
    /// Sender member id. Absent on `system` messages and on some `assistant`
    /// messages.
    #[serde(default)]
    pub account_user_id: Option<String>,
    /// Echo of the client `request_id` for messages this client sent.
    #[serde(default)]
    pub request_id: Option<String>,
    /// Set once deleted.
    #[serde(default)]
    pub deleted_at: Option<String>,
    /// `account_user_id` to one emoji.
    #[serde(default, deserialize_with = "null_as_default")]
    pub reactions: BTreeMap<String, String>,
    /// Direct parent.
    #[serde(default)]
    pub reply_to: Option<ReplyTo>,
    /// Root of the reply thread.
    #[serde(default)]
    pub reply_root_message_id: Option<String>,
    /// `user` (owner or Dot), `assistant`, or `system`.
    #[serde(default)]
    pub role: Option<String>,
    /// Linked task (the app reads this; older payloads use a `thread`
    /// attachment instead).
    #[serde(default)]
    pub task_id: Option<String>,
    /// Server-rendered summary; the only text of `system` messages.
    #[serde(default)]
    pub preview: Option<String>,
    /// Body.
    #[serde(default, deserialize_with = "null_as_default")]
    pub content: Content,
}

/// Treats JSON `null` like a missing field.
fn null_as_default<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Default + Deserialize<'de>,
{
    Ok(Option::<T>::deserialize(deserializer)?.unwrap_or_default())
}

impl Message {
    /// Parsed creation time; messages with an unparseable time sort first.
    pub fn created(&self) -> Option<DateTime<FixedOffset>> {
        DateTime::parse_from_rfc3339(&self.created_at).ok()
    }
}

/// Reply target.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ReplyTo {
    /// Parent message id.
    pub message_id: String,
}

/// Message body.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct Content {
    /// Text; `null` or empty for media.
    #[serde(default, deserialize_with = "null_as_default")]
    pub text: String,
    /// Attachments.
    #[serde(default, deserialize_with = "null_as_default")]
    pub attachments: Vec<Attachment>,
    /// Content kind on `system` messages.
    #[serde(rename = "type", default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    /// Confirmation request, raw. Parse with [`Elicitation::parse`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub elicitation: Option<Value>,
}

/// Message attachment.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Attachment {
    /// `file`, `thread`, `link`, or something new.
    #[serde(rename = "type")]
    pub kind: String,
    /// For `file`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_id: Option<String>,
    /// Stable attachment id, when present.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attachment_id: Option<String>,
    /// For `thread` (task card).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread_id: Option<String>,
    /// File name, when present.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// Outgoing message body for `POST /messaging/rooms/{room}/messages`.
#[derive(Clone, Debug, Serialize)]
pub struct SendBody {
    /// Text and attachments.
    pub content: SendContent,
    /// Client correlation id, echoed on the created message.
    pub request_id: String,
    /// Same value as `request_id`.
    pub idempotency_token: String,
    /// Parent message.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<ReplyTo>,
    /// Minutes from local time to UTC (JavaScript `getTimezoneOffset`), as
    /// the ChatGPT apps send it.
    pub timezone_offset_min: i32,
}

/// One prompt or answer extracted from a task turn.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TaskTurnEntry {
    /// `<turn id>:prompt` or `<turn id>:answer`.
    pub id: String,
    /// `true` for the owner's prompt.
    pub prompt: bool,
    /// Text.
    pub text: String,
}

/// Outgoing content.
#[derive(Clone, Debug, Serialize)]
pub struct SendContent {
    /// Text, or a caption.
    pub text: String,
    /// Uploaded file references.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub attachments: Vec<FileRef>,
}

/// Uploaded file reference.
#[derive(Clone, Debug, Serialize)]
pub struct FileRef {
    /// Always `file`.
    #[serde(rename = "type")]
    pub kind: &'static str,
    /// From the upload response.
    pub file_id: String,
}

/// `GET /messaging/rooms/{room}/files/{file}`.
#[derive(Clone, Debug, Deserialize)]
pub struct FileInfo {
    /// Echoed id (either key).
    #[serde(default)]
    pub id: Option<String>,
    /// Echoed id (either key).
    #[serde(default)]
    pub file_id: Option<String>,
    /// Signed storage URL; empty while processing.
    #[serde(default)]
    pub download_url: Option<String>,
    /// File name.
    #[serde(default)]
    pub name: Option<String>,
    /// MIME type.
    #[serde(default)]
    pub mime_type: Option<String>,
}

/// A parsed confirmation request (elicitation).
#[derive(Clone, Debug, PartialEq)]
pub struct Elicitation {
    /// Request id.
    pub request_id: String,
    /// Task thread.
    pub thread_id: String,
    /// `pending`, or a terminal status.
    pub status: Option<String>,
    /// Prompt shown to the user.
    pub message: String,
    /// Title from `_meta.openai/confirmation.presentation`.
    pub title: Option<String>,
    /// Label/value rows from the presentation.
    pub fields: Vec<(String, String)>,
    /// Content to send on accept, when the bridge can answer this shape;
    /// `None` means it must be answered in ChatGPT.
    pub accept_content: Option<Value>,
}

impl Elicitation {
    /// Parses and validates `content.elicitation`. Returns `None` for
    /// malformed requests.
    pub fn parse(raw: &Value) -> Option<Self> {
        let request_id = raw.get("request_id")?.as_str()?.to_owned();
        let thread_id = raw.get("thread_id")?.as_str()?.to_owned();
        if request_id.is_empty() || thread_id.is_empty() {
            return None;
        }
        let params = raw.get("params")?;
        if params.get("threadId").and_then(Value::as_str) != Some(thread_id.as_str()) {
            return None;
        }
        let turn = raw.get("turn_id").and_then(Value::as_str).unwrap_or("");
        match params.get("turnId").and_then(Value::as_str) {
            None | Some("") => {}
            Some(param_turn) if param_turn == turn => {}
            Some(_) => return None,
        }
        let message = params
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_owned();
        let meta = params.get("_meta");
        let presentation = meta
            .and_then(|meta| meta.get("openai/confirmation"))
            .and_then(|confirmation| confirmation.get("presentation"));
        let title = presentation
            .and_then(|p| p.get("title"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        let fields = presentation
            .and_then(|p| p.get("fields"))
            .and_then(Value::as_array)
            .map(|fields| {
                fields
                    .iter()
                    .filter_map(|field| {
                        Some((
                            field.get("label")?.as_str()?.to_owned(),
                            field.get("value")?.as_str()?.to_owned(),
                        ))
                    })
                    .collect()
            })
            .unwrap_or_default();
        Some(Self {
            request_id,
            thread_id,
            status: raw.get("status").and_then(Value::as_str).map(str::to_owned),
            accept_content: binary_accept_content(params, &message),
            message,
            title,
            fields,
        })
    }

    /// Whether the request still waits for an answer.
    pub fn is_pending(&self) -> bool {
        matches!(self.status.as_deref(), None | Some("") | Some("pending"))
    }
}

/// Returns the accept content for the two shapes a yes/no button can answer
/// faithfully: an empty form, or a single required boolean declared as the
/// confirmation field. Anything richer goes to ChatGPT.
fn binary_accept_content(params: &Value, message: &str) -> Option<Value> {
    if message.is_empty() {
        return None;
    }
    match params.get("mode").and_then(Value::as_str) {
        None | Some("") | Some("form") => {}
        Some(_) => return None,
    }
    if matches!(
        params.get("serverName").and_then(Value::as_str),
        Some("browser" | "browser-use")
    ) {
        return None;
    }
    let meta = params.get("_meta");
    if let Some(meta) = meta.and_then(Value::as_object)
        && meta
            .keys()
            .any(|key| key != "reason" && key != "openai/confirmation")
    {
        return None;
    }
    let schema = params.get("requestedSchema")?;
    if schema.get("type").and_then(Value::as_str) != Some("object") {
        return None;
    }
    let properties = schema.get("properties")?.as_object()?;
    let required: Vec<&str> = schema
        .get("required")
        .and_then(Value::as_array)
        .map(|required| required.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    if properties.is_empty() && required.is_empty() {
        return Some(Value::Object(Default::default()));
    }
    let confirmation = meta?.get("openai/confirmation")?;
    if confirmation.get("version").and_then(Value::as_u64) != Some(1) {
        return None;
    }
    let field = confirmation.get("field")?.as_str()?;
    if properties.len() != 1 || required != [field] {
        return None;
    }
    let property = properties.get(field)?.as_object()?;
    if property.get("type").and_then(Value::as_str) != Some("boolean")
        || property
            .keys()
            .any(|key| !matches!(key.as_str(), "type" | "title" | "description" | "default"))
    {
        return None;
    }
    Some(serde_json::json!({ field: true }))
}

/// `GET .../elicitation?inspect=true`.
#[derive(Clone, Debug, Deserialize)]
pub struct ElicitationState {
    /// Current definition.
    pub elicitation: Value,
    /// Must be echoed in the response.
    pub request_fingerprint: String,
    /// Whether this account may answer now.
    #[serde(default)]
    pub can_respond: bool,
    /// `pending` while answerable.
    #[serde(default)]
    pub runtime_status: String,
}

/// Answer to a confirmation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Approve.
    Accept,
    /// Reject.
    Decline,
}

/// Realtime endpoint (`GET /celsius/ws/user`).
#[derive(Clone, Debug, Deserialize)]
pub struct RealtimeEndpoint {
    /// `wss://ws.chatgpt.com/...`; carries its own auth.
    pub websocket_url: String,
}

/// Task status from the Codex cloud backend.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TaskStatus {
    /// Created, no turn yet.
    Thinking,
    /// Running.
    InProgress,
    /// Waiting for the owner.
    NeedsInput,
    /// Done.
    Completed,
    /// Failed.
    Failed,
    /// Stopped.
    Interrupted,
}

impl TaskStatus {
    /// Parses a server status string.
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "thinking" => Self::Thinking,
            "inProgress" => Self::InProgress,
            "needsInput" => Self::NeedsInput,
            "completed" => Self::Completed,
            "failed" => Self::Failed,
            "interrupted" => Self::Interrupted,
            _ => return None,
        })
    }

    /// No further changes expected.
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Interrupted)
    }

    /// Short label for a task card.
    pub fn label(self) -> &'static str {
        match self {
            Self::Thinking => "Starting…",
            Self::InProgress => "Working…",
            Self::NeedsInput => "Waiting for your input in ChatGPT",
            Self::Completed => "Completed",
            Self::Failed => "Failed",
            Self::Interrupted => "Interrupted",
        }
    }
}

/// A task's current summary.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TaskSummary {
    /// Task thread id.
    pub id: String,
    /// Task title.
    pub title: Option<String>,
    /// Derived status.
    pub status: TaskStatus,
    /// Server `updatedAt`, Unix seconds.
    pub updated_at: i64,
}
