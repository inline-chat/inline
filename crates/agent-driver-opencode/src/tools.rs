//! Inline's host tools, served to OpenCode as a client-hosted MCP server.
//!
//! OpenCode v2 lets a client expose tools over a WebSocket at
//! `/api/experimental/client-mcp?location[directory]=…&name=inline`: the
//! service is the MCP client and the bridge answers `initialize`,
//! `tools/list` and `tools/call` (one JSON-RPC message per text frame). The
//! model sees the tools as `inline_<tool>`, and every call names the session
//! that made it in `_meta["ai.opencode/sessionID"]`, so one connection per
//! folder serves every Inline session there with its own binding. No child
//! process, loopback port or credential leaves the bridge.
//!
//! The connection is per folder, so OpenCode may also offer the tools to
//! sessions Inline did not open (the owner's TUI in the same folder). Those
//! calls are refused: only sessions this bridge holds have a binding.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use inline_agent_bridge::{HostToolCall, HostToolConfiguration, ProviderSessionId, TurnId};
use serde_json::{Value, json};
use tokio::sync::watch;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::link::Link;

/// The client name; OpenCode shows the tools as `inline_<tool>`.
pub const SERVER_NAME: &str = "inline";
const SESSION_META_KEY: &str = "ai.opencode/sessionID";
const PROTOCOL_VERSION: &str = "2025-11-25";
const RECONNECT_MIN: Duration = Duration::from_millis(500);
const RECONNECT_MAX: Duration = Duration::from_secs(10);
const MAX_ARGUMENT_BYTES: usize = 32 * 1024;
const MAX_RESULT_CHARS: usize = 16_000;
const CALL_TIMEOUT: Duration = Duration::from_secs(25);

/// Resolves a calling session to the Inline session it is bound to (itself,
/// or the held session a sub-agent runs under) and that session's running
/// turn; `None` when the bridge holds neither.
pub type SessionResolver = Arc<dyn Fn(&str) -> Option<(String, Option<TurnId>)> + Send + Sync>;

/// One client-MCP connection per folder.
pub struct ToolHost {
    link: Arc<Link>,
    tools: HostToolConfiguration,
    resolver: SessionResolver,
    folders: Mutex<HashMap<PathBuf, watch::Sender<bool>>>,
}

impl ToolHost {
    pub fn new(link: Arc<Link>, tools: HostToolConfiguration, resolver: SessionResolver) -> Self {
        Self {
            link,
            tools,
            resolver,
            folders: Mutex::new(HashMap::new()),
        }
    }

    /// Serves the tools in `folder` from now until shutdown. Idempotent.
    pub fn serve(self: &Arc<Self>, folder: PathBuf) {
        let mut folders = self
            .folders
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if folders.contains_key(&folder) {
            return;
        }
        let (stop, stopped) = watch::channel(false);
        folders.insert(folder.clone(), stop);
        let host = Arc::downgrade(self);
        tokio::spawn(async move {
            let mut delay = RECONNECT_MIN;
            loop {
                let Some(strong) = host.upgrade() else { return };
                let outcome = strong.connection(&folder, stopped.clone()).await;
                drop(strong);
                match outcome {
                    Connection::Stopped => return,
                    Connection::Initialized => delay = RECONNECT_MIN,
                    Connection::Failed(error) => {
                        log::debug!(target: "inline::opencode", "client MCP for {} closed: {error}", folder.display());
                    }
                }
                let mut stopped = stopped.clone();
                tokio::select! {
                    _ = tokio::time::sleep(delay) => {}
                    _ = async { let _ = stopped.wait_for(|stop| *stop).await; } => return,
                }
                delay = (delay * 2).min(RECONNECT_MAX);
            }
        });
    }

    /// Closes every connection.
    pub fn shutdown(&self) {
        for (_, stop) in self
            .folders
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .drain()
        {
            let _ = stop.send(true);
        }
    }

    fn url(endpoint: &crate::service::Endpoint, folder: &std::path::Path) -> url::Url {
        let mut url = endpoint.join("api/experimental/client-mcp");
        url.query_pairs_mut()
            .append_pair("location[directory]", &folder.display().to_string())
            .append_pair("name", SERVER_NAME);
        let scheme = if url.scheme() == "https" { "wss" } else { "ws" };
        let _ = url.set_scheme(scheme);
        url
    }

    async fn connection(
        &self,
        folder: &std::path::Path,
        mut stopped: watch::Receiver<bool>,
    ) -> Connection {
        let api = self.link.api();
        let endpoint = api.endpoint();
        let mut request = match Self::url(endpoint, folder).as_str().into_client_request() {
            Ok(request) => request,
            Err(error) => return Connection::Failed(error.to_string()),
        };
        if let Some(authorization) = endpoint.authorization()
            && let Ok(value) = authorization.parse()
        {
            request.headers_mut().insert("authorization", value);
        }
        let (socket, _) = match tokio_tungstenite::connect_async(request).await {
            Ok(connected) => connected,
            Err(error) => return Connection::Failed(error.to_string()),
        };
        let (mut sink, mut stream) = socket.split();
        let (replies, mut outgoing) = tokio::sync::mpsc::unbounded_channel::<String>();
        let mut initialized = false;
        loop {
            tokio::select! {
                _ = async { let _ = stopped.wait_for(|stop| *stop).await; } => {
                    let _ = sink.send(Message::Close(None)).await;
                    return Connection::Stopped;
                }
                Some(reply) = outgoing.recv() => {
                    if sink.send(Message::Text(reply.into())).await.is_err() {
                        return Connection::Failed("send failed".to_owned());
                    }
                }
                frame = stream.next() => {
                    let text = match frame {
                        Some(Ok(Message::Text(text))) => text.to_string(),
                        Some(Ok(Message::Ping(payload))) => {
                            let _ = sink.send(Message::Pong(payload)).await;
                            continue;
                        }
                        Some(Ok(Message::Close(_))) | None => {
                            return if initialized { Connection::Initialized } else { Connection::Failed("closed".to_owned()) };
                        }
                        Some(Ok(_)) => continue,
                        Some(Err(error)) => return Connection::Failed(error.to_string()),
                    };
                    let Ok(message) = serde_json::from_str::<Value>(&text) else { continue };
                    if message.get("method").and_then(Value::as_str) == Some("notifications/initialized") {
                        initialized = true;
                    }
                    let (Some(id), Some(method)) = (message.get("id").cloned(), message.get("method").and_then(Value::as_str).map(str::to_owned)) else {
                        continue;
                    };
                    if !(id.is_string() || id.is_number()) {
                        continue;
                    }
                    let params = message.get("params").cloned().unwrap_or(Value::Null);
                    let tools = self.tools.clone();
                    let resolver = self.resolver.clone();
                    let replies = replies.clone();
                    // Calls run concurrently; replies keep their ids.
                    tokio::spawn(async move {
                        let mut reply = respond(&tools, &resolver, &method, &params).await;
                        reply["jsonrpc"] = json!("2.0");
                        reply["id"] = id;
                        let _ = replies.send(reply.to_string());
                    });
                }
            }
        }
    }
}

impl Drop for ToolHost {
    fn drop(&mut self) {
        self.shutdown();
    }
}

enum Connection {
    Stopped,
    Initialized,
    Failed(String),
}

/// The JSON-RPC result or error for one request (without `id`).
pub async fn respond(
    tools: &HostToolConfiguration,
    resolver: &SessionResolver,
    method: &str,
    params: &Value,
) -> Value {
    match method {
        "initialize" => json!({"result": {
            "protocolVersion": params.get("protocolVersion").and_then(Value::as_str).unwrap_or(PROTOCOL_VERSION),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": env!("CARGO_PKG_VERSION")},
        }}),
        "ping" => json!({"result": {}}),
        "tools/list" => json!({"result": {"tools": tools.specs.iter().map(|spec| {
            let mut schema = spec.input_schema.clone();
            if let Value::Object(map) = &mut schema {
                map.insert("type".into(), json!("object"));
            }
            json!({
                "name": spec.name,
                "description": spec.description,
                "inputSchema": schema,
                "annotations": {"readOnlyHint": spec.read_only},
            })
        }).collect::<Vec<_>>()}}),
        "tools/call" => json!({"result": call(tools, resolver, params).await}),
        other => {
            json!({"error": {"code": -32601, "message": format!("Method not found: {other}")}})
        }
    }
}

async fn call(tools: &HostToolConfiguration, resolver: &SessionResolver, params: &Value) -> Value {
    let error = |text: &str| json!({"content": [{"type": "text", "text": text}], "isError": true});
    let Some(name) = params.get("name").and_then(Value::as_str) else {
        return error("The tool call named no tool.");
    };
    if !tools.specs.iter().any(|spec| spec.name == name) {
        return error(&format!("Unknown Inline tool: {name}"));
    }
    let arguments = params
        .get("arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));
    if arguments.to_string().len() > MAX_ARGUMENT_BYTES {
        return error("The tool arguments are too large.");
    }
    let Some(session) = params
        .pointer(&format!("/_meta/{}", SESSION_META_KEY.replace('/', "~1")))
        .and_then(Value::as_str)
    else {
        return error("Inline tools need the calling OpenCode session.");
    };
    // Only sessions this bridge holds have an Inline binding.
    let Some((bound, turn)) = resolver(session) else {
        return error("Inline tools are only available in sessions Inline opened.");
    };
    let (Ok(session_id), Ok(turn_id)) = (
        ProviderSessionId::new(bound),
        turn.map_or_else(|| TurnId::new("mcp"), Ok),
    ) else {
        return error("Inline tools are unavailable.");
    };
    let call = HostToolCall {
        call_id: uuid::Uuid::new_v4().to_string(),
        session_id,
        turn_id,
        tool_name: name.to_owned(),
        arguments,
    };
    match tokio::time::timeout(CALL_TIMEOUT, tools.handler.call(call)).await {
        Ok(result) => json!({
            "content": [{"type": "text", "text": crate::api::bounded(&result.content, MAX_RESULT_CHARS)}],
            "isError": !result.success,
        }),
        Err(_) => error("Inline did not answer in time."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use inline_agent_bridge::{HostToolHandler, HostToolResult, HostToolSpec};

    struct Echo;

    impl HostToolHandler for Echo {
        fn call<'a>(&'a self, call: HostToolCall) -> inline_agent_bridge::HostToolFuture<'a> {
            Box::pin(async move {
                HostToolResult::success(format!(
                    "{}:{}:{}",
                    call.session_id.as_str(),
                    call.turn_id.as_str(),
                    call.arguments
                ))
            })
        }
    }

    fn configuration() -> HostToolConfiguration {
        HostToolConfiguration {
            specs: vec![HostToolSpec {
                name: "send_message".into(),
                description: "Send".into(),
                input_schema: json!({"properties": {"text": {"type": "string"}}}),
                read_only: false,
            }],
            handler: Arc::new(Echo),
        }
    }

    fn resolver() -> SessionResolver {
        Arc::new(|session: &str| match session {
            "ses_held" => Some((session.to_owned(), Some(TurnId::new("msg_turn").unwrap()))),
            "ses_idle" => Some((session.to_owned(), None)),
            "ses_child" => Some(("ses_held".to_owned(), None)),
            _ => None,
        })
    }

    #[tokio::test]
    async fn lists_tools_as_objects() {
        let reply = respond(&configuration(), &resolver(), "tools/list", &Value::Null).await;
        assert_eq!(reply["result"]["tools"][0]["name"], "send_message");
        assert_eq!(reply["result"]["tools"][0]["inputSchema"]["type"], "object");
        let init = respond(
            &configuration(),
            &resolver(),
            "initialize",
            &json!({"protocolVersion": "2025-06-18"}),
        )
        .await;
        assert_eq!(init["result"]["protocolVersion"], "2025-06-18");
        assert_eq!(init["result"]["serverInfo"]["name"], "inline");
    }

    #[tokio::test]
    async fn calls_bind_to_the_calling_held_session() {
        let params = |session: &str| json!({"name": "send_message", "arguments": {"text": "hi"}, "_meta": {"ai.opencode/sessionID": session}});
        let reply = respond(
            &configuration(),
            &resolver(),
            "tools/call",
            &params("ses_held"),
        )
        .await;
        assert_eq!(reply["result"]["isError"], false);
        assert_eq!(
            reply["result"]["content"][0]["text"],
            "ses_held:msg_turn:{\"text\":\"hi\"}"
        );
        let idle = respond(
            &configuration(),
            &resolver(),
            "tools/call",
            &params("ses_idle"),
        )
        .await;
        assert!(
            idle["result"]["content"][0]["text"]
                .as_str()
                .unwrap()
                .starts_with("ses_idle:mcp:")
        );
        let child = respond(
            &configuration(),
            &resolver(),
            "tools/call",
            &params("ses_child"),
        )
        .await;
        assert!(
            child["result"]["content"][0]["text"]
                .as_str()
                .unwrap()
                .starts_with("ses_held:mcp:")
        );
        let foreign = respond(
            &configuration(),
            &resolver(),
            "tools/call",
            &params("ses_tui"),
        )
        .await;
        assert_eq!(foreign["result"]["isError"], true);
        let anonymous = respond(
            &configuration(),
            &resolver(),
            "tools/call",
            &json!({"name": "send_message", "arguments": {}}),
        )
        .await;
        assert_eq!(anonymous["result"]["isError"], true);
        let unknown = respond(
            &configuration(),
            &resolver(),
            "resources/list",
            &Value::Null,
        )
        .await;
        assert_eq!(unknown["error"]["code"], -32601);
    }
}
