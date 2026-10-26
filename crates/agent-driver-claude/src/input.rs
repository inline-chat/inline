//! User messages the host writes to the CLI's stdin.
//!
//! Each message carries a `uuid` so the CLI's `command_lifecycle` frames,
//! interrupt receipts and `result.user_message_uuids` can name it, plus the
//! native delivery fields: `priority` (`now` / `next` / `later`),
//! `shouldQuery` (passive context when false) and `origin` (provenance).

use serde_json::{Map, Value, json};

/// When a message sent during a turn reaches the model.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Priority {
    /// Interrupt the current turn at the next safe point and run this next.
    Now,
    /// Fold into the current turn after the running tool round (the CLI's
    /// default for typing while it works).
    Next,
    /// Queue behind the current turn.
    Later,
}

impl Priority {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Now => "now",
            Self::Next => "next",
            Self::Later => "later",
        }
    }
}

/// Native provenance of a user message (`SDKMessageOrigin`).
#[derive(Clone, Debug, PartialEq)]
pub enum Origin {
    /// The session's owner typing.
    Human,
    /// Input relayed from a channel such as an Inline thread.
    Channel { server: String },
    /// Another agent.
    Peer {
        from: String,
        name: Option<String>,
        from_session: Option<String>,
    },
    /// A scheduled or background delivery.
    TaskNotification { subkind: Option<String> },
    /// A kind this crate does not model, sent verbatim.
    Raw(Value),
}

impl Origin {
    pub fn to_value(&self) -> Value {
        match self {
            Self::Human => json!({"kind": "human"}),
            Self::Channel { server } => json!({"kind": "channel", "server": server}),
            Self::Peer {
                from,
                name,
                from_session,
            } => {
                let mut map = Map::new();
                map.insert("kind".into(), json!("peer"));
                map.insert("from".into(), json!(from));
                if let Some(name) = name {
                    map.insert("name".into(), json!(name));
                }
                if let Some(from_session) = from_session {
                    map.insert("fromSession".into(), json!(from_session));
                }
                Value::Object(map)
            }
            Self::TaskNotification { subkind } => {
                let mut map = Map::new();
                map.insert("kind".into(), json!("task-notification"));
                if let Some(subkind) = subkind {
                    map.insert("subkind".into(), json!(subkind));
                }
                Value::Object(map)
            }
            Self::Raw(value) => value.clone(),
        }
    }
}

/// Content of a user message: plain text or Messages API content blocks
/// (text, image, document …).
#[derive(Clone, Debug, PartialEq)]
pub enum UserContent {
    Text(String),
    Blocks(Vec<Value>),
}

impl UserContent {
    /// A base64 image block, as the Messages API takes it.
    pub fn image_block(media_type: &str, base64_data: &str) -> Value {
        json!({
            "type": "image",
            "source": {"type": "base64", "media_type": media_type, "data": base64_data}
        })
    }

    /// A base64 PDF document block.
    pub fn pdf_block(base64_data: &str, title: Option<&str>) -> Value {
        let mut block = json!({
            "type": "document",
            "source": {"type": "base64", "media_type": "application/pdf", "data": base64_data}
        });
        if let Some(title) = title {
            block["title"] = json!(title);
        }
        block
    }

    pub fn text_block(text: &str) -> Value {
        json!({"type": "text", "text": text})
    }

    fn to_value(&self) -> Value {
        match self {
            Self::Text(text) => json!(text),
            Self::Blocks(blocks) => Value::Array(blocks.clone()),
        }
    }
}

/// One stdin user message.
#[derive(Clone, Debug, PartialEq)]
pub struct UserMessage {
    pub uuid: String,
    pub content: UserContent,
    pub priority: Option<Priority>,
    /// `Some(false)` appends to the transcript without starting a turn.
    pub should_query: Option<bool>,
    pub origin: Option<Origin>,
    /// Deliver the text as written: no `@path` expansion and no slash-command
    /// dispatch (Claude Code ≥ 2.1.248). Leave off for typed input so the
    /// harness behaves as in its own CLI.
    pub client_composed: bool,
    pub parent_tool_use_id: Option<String>,
    /// Fields newer CLIs accept that this crate does not model.
    pub extra: Map<String, Value>,
}

impl UserMessage {
    /// A text message with a fresh uuid and the harness defaults.
    pub fn text(text: impl Into<String>) -> Self {
        Self::new(UserContent::Text(text.into()))
    }

    pub fn new(content: UserContent) -> Self {
        Self {
            uuid: uuid::Uuid::new_v4().to_string(),
            content,
            priority: None,
            should_query: None,
            origin: None,
            client_composed: false,
            parent_tool_use_id: None,
            extra: Map::new(),
        }
    }

    pub fn with_uuid(mut self, uuid: impl Into<String>) -> Self {
        self.uuid = uuid.into();
        self
    }

    pub fn with_priority(mut self, priority: Priority) -> Self {
        self.priority = Some(priority);
        self
    }

    /// Passive context: recorded, merged into the next querying message.
    pub fn passive(mut self) -> Self {
        self.should_query = Some(false);
        self
    }

    pub fn with_origin(mut self, origin: Origin) -> Self {
        self.origin = Some(origin);
        self
    }

    /// The stdin JSON object.
    pub fn to_value(&self) -> Value {
        let mut map = Map::new();
        map.insert("type".into(), json!("user"));
        map.insert(
            "message".into(),
            json!({"role": "user", "content": self.content.to_value()}),
        );
        map.insert(
            "parent_tool_use_id".into(),
            self.parent_tool_use_id
                .as_ref()
                .map_or(Value::Null, |id| json!(id)),
        );
        map.insert("session_id".into(), json!(""));
        map.insert("uuid".into(), json!(self.uuid));
        if let Some(priority) = self.priority {
            map.insert("priority".into(), json!(priority.as_str()));
        }
        if let Some(should_query) = self.should_query {
            map.insert("shouldQuery".into(), json!(should_query));
        }
        if let Some(origin) = &self.origin {
            map.insert("origin".into(), origin.to_value());
        }
        if self.client_composed {
            map.insert("client_composed".into(), json!(true));
        }
        for (key, value) in &self.extra {
            map.entry(key.clone()).or_insert_with(|| value.clone());
        }
        Value::Object(map)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn steer_message_carries_native_fields() {
        let message = UserMessage::text("also check the tests")
            .with_uuid("m1")
            .with_priority(Priority::Next)
            .with_origin(Origin::Channel {
                server: "inline".into(),
            });
        assert_eq!(
            message.to_value(),
            json!({
                "type": "user",
                "message": {"role": "user", "content": "also check the tests"},
                "parent_tool_use_id": null,
                "session_id": "",
                "uuid": "m1",
                "priority": "next",
                "origin": {"kind": "channel", "server": "inline"}
            })
        );
    }

    #[test]
    fn passive_context_sets_should_query_false() {
        let value = UserMessage::text("ambient").with_uuid("p1").passive().to_value();
        assert_eq!(value["shouldQuery"], json!(false));
        assert!(value.get("priority").is_none());
    }

    #[test]
    fn peer_origin_omits_absent_fields() {
        let origin = Origin::Peer {
            from: "bot:42".into(),
            name: Some("Codex".into()),
            from_session: None,
        };
        assert_eq!(
            origin.to_value(),
            json!({"kind": "peer", "from": "bot:42", "name": "Codex"})
        );
    }

    #[test]
    fn blocks_are_sent_as_content_arrays() {
        let message = UserMessage::new(UserContent::Blocks(vec![
            UserContent::text_block("what is this?"),
            UserContent::image_block("image/png", "AAAA"),
        ]));
        let value = message.to_value();
        assert_eq!(value["message"]["content"][1]["type"], json!("image"));
        assert_eq!(value["message"]["content"][1]["source"]["data"], json!("AAAA"));
    }
}
