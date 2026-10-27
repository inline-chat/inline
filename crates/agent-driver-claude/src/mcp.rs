//! In-process MCP servers answered over the control channel.
//!
//! The CLI speaks JSON-RPC to "sdk"-type MCP servers through `mcp_message`
//! control requests, so the host serves tools without a child process or a
//! loopback port. [`ToolServer`] implements the slice of MCP a tool server
//! needs: the handshake, `tools/list`, `tools/call`, `ping` and cancellation.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

/// A boxed, sendable future.
pub type BoxFuture<T> = Pin<Box<dyn Future<Output = T> + Send + 'static>>;

/// The latest MCP protocol version this server speaks; a client asking for
/// another version gets its own version echoed, as MCP servers negotiate.
pub const MCP_PROTOCOL_VERSION: &str = "2025-06-18";

const METHOD_NOT_FOUND: i64 = -32601;
const INVALID_PARAMS: i64 = -32602;
const INTERNAL_ERROR: i64 = -32603;

/// One in-process MCP server. `handle` gets each JSON-RPC message the CLI
/// sends and returns the response for requests, `None` for notifications.
pub trait SdkMcpServer: Send + Sync + 'static {
    fn handle(&self, message: Value) -> BoxFuture<Option<Value>>;
}

/// A tool's MCP definition.
#[derive(Clone, Debug, PartialEq)]
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    pub input_schema: Value,
    pub annotations: Option<Value>,
}

impl ToolDefinition {
    fn to_value(&self) -> Value {
        let mut value = json!({
            "name": self.name,
            "description": self.description,
            "inputSchema": self.input_schema,
        });
        if let Some(annotations) = &self.annotations {
            value["annotations"] = annotations.clone();
        }
        value
    }
}

/// The result of one tool call: MCP content blocks.
#[derive(Clone, Debug, PartialEq)]
pub struct ToolOutput {
    pub content: Vec<Value>,
    pub structured_content: Option<Value>,
    pub is_error: bool,
}

impl ToolOutput {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            content: vec![json!({"type": "text", "text": text.into()})],
            structured_content: None,
            is_error: false,
        }
    }

    pub fn error(text: impl Into<String>) -> Self {
        Self {
            is_error: true,
            ..Self::text(text)
        }
    }

    fn to_value(&self) -> Value {
        let mut value = json!({"content": self.content});
        if let Some(structured) = &self.structured_content {
            value["structuredContent"] = structured.clone();
        }
        if self.is_error {
            value["isError"] = json!(true);
        }
        value
    }
}

/// Runs a tool call.
pub trait ToolCallHandler: Send + Sync + 'static {
    fn call(&self, tool: String, arguments: Value) -> BoxFuture<ToolOutput>;
}

impl<F, Fut> ToolCallHandler for F
where
    F: Fn(String, Value) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = ToolOutput> + Send + 'static,
{
    fn call(&self, tool: String, arguments: Value) -> BoxFuture<ToolOutput> {
        Box::pin(self(tool, arguments))
    }
}

/// A tool-only MCP server.
pub struct ToolServer {
    name: String,
    version: String,
    instructions: Option<String>,
    tools: Arc<Mutex<Vec<ToolDefinition>>>,
    handler: Arc<dyn ToolCallHandler>,
    running: Arc<Mutex<HashMap<String, tokio::task::AbortHandle>>>,
}

impl ToolServer {
    pub fn new(
        name: impl Into<String>,
        version: impl Into<String>,
        tools: Vec<ToolDefinition>,
        handler: impl ToolCallHandler,
    ) -> Self {
        Self {
            name: name.into(),
            version: version.into(),
            instructions: None,
            tools: Arc::new(Mutex::new(tools)),
            handler: Arc::new(handler),
            running: Arc::default(),
        }
    }

    pub fn with_instructions(mut self, instructions: impl Into<String>) -> Self {
        self.instructions = Some(instructions.into());
        self
    }

    /// Replaces the tool list (the next `tools/list` sees it).
    pub fn set_tools(&self, tools: Vec<ToolDefinition>) {
        *self
            .tools
            .lock()
            .unwrap_or_else(|poison| poison.into_inner()) = tools;
    }
}

impl SdkMcpServer for ToolServer {
    fn handle(&self, message: Value) -> BoxFuture<Option<Value>> {
        let id = message.get("id").cloned();
        let method = message
            .get("method")
            .and_then(Value::as_str)
            .map(str::to_string);
        let params = message.get("params").cloned().unwrap_or(Value::Null);
        let Some(method) = method else {
            // A response to a request this server never sends.
            return Box::pin(async { None });
        };
        let Some(id) = id else {
            if method == "notifications/cancelled"
                && let Some(request_id) = params.get("requestId").map(request_key)
                && let Some(handle) = self
                    .running
                    .lock()
                    .unwrap_or_else(|poison| poison.into_inner())
                    .remove(&request_id)
            {
                handle.abort();
            }
            return Box::pin(async { None });
        };
        match method.as_str() {
            "initialize" => {
                let requested = params
                    .get("protocolVersion")
                    .and_then(Value::as_str)
                    .unwrap_or(MCP_PROTOCOL_VERSION)
                    .to_string();
                let mut result = json!({
                    "protocolVersion": requested,
                    "capabilities": {"tools": {"listChanged": false}},
                    "serverInfo": {"name": self.name, "version": self.version},
                });
                if let Some(instructions) = &self.instructions {
                    result["instructions"] = json!(instructions);
                }
                ready(rpc_result(id, result))
            }
            "ping" => ready(rpc_result(id, json!({}))),
            "tools/list" => {
                let tools: Vec<Value> = self
                    .tools
                    .lock()
                    .unwrap_or_else(|poison| poison.into_inner())
                    .iter()
                    .map(ToolDefinition::to_value)
                    .collect();
                ready(rpc_result(id, json!({"tools": tools})))
            }
            "tools/call" => {
                let Some(tool) = params
                    .get("name")
                    .and_then(Value::as_str)
                    .map(str::to_string)
                else {
                    return ready(rpc_error(id, INVALID_PARAMS, "tools/call needs a name"));
                };
                let known = self
                    .tools
                    .lock()
                    .unwrap_or_else(|poison| poison.into_inner())
                    .iter()
                    .any(|definition| definition.name == tool);
                if !known {
                    return ready(rpc_result(
                        id,
                        ToolOutput::error(format!("Unknown tool: {tool}")).to_value(),
                    ));
                }
                let arguments = params.get("arguments").cloned().unwrap_or(json!({}));
                let handler = self.handler.clone();
                let running = self.running.clone();
                let key = request_key(&id);
                let task = tokio::spawn(async move { handler.call(tool, arguments).await });
                running
                    .lock()
                    .unwrap_or_else(|poison| poison.into_inner())
                    .insert(key.clone(), task.abort_handle());
                Box::pin(async move {
                    let outcome = task.await;
                    running
                        .lock()
                        .unwrap_or_else(|poison| poison.into_inner())
                        .remove(&key);
                    match outcome {
                        Ok(output) => Some(rpc_result(id, output.to_value())),
                        Err(error) if error.is_cancelled() => {
                            Some(rpc_error(id, INTERNAL_ERROR, "tool call cancelled"))
                        }
                        Err(_) => Some(rpc_error(id, INTERNAL_ERROR, "tool call failed")),
                    }
                })
            }
            other => ready(rpc_error(
                id,
                METHOD_NOT_FOUND,
                &format!("Method not found: {other}"),
            )),
        }
    }
}

fn ready(value: Value) -> BoxFuture<Option<Value>> {
    Box::pin(async move { Some(value) })
}

fn request_key(id: &Value) -> String {
    id.to_string()
}

pub(crate) fn rpc_result(id: Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

pub(crate) fn rpc_error(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

/// The `--mcp-config` entry that declares an in-process server to the CLI.
pub fn sdk_server_config(names: &[&str]) -> Value {
    let servers: serde_json::Map<String, Value> = names
        .iter()
        .map(|name| ((*name).to_string(), json!({"type": "sdk", "name": name})))
        .collect();
    json!({"mcpServers": servers})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn server() -> ToolServer {
        ToolServer::new(
            "inline",
            "0.0.0",
            vec![ToolDefinition {
                name: "echo".into(),
                description: "Echo text".into(),
                input_schema: json!({"type": "object", "properties": {"text": {"type": "string"}}}),
                annotations: None,
            }],
            |_tool: String, arguments: Value| async move {
                ToolOutput::text(arguments["text"].as_str().unwrap_or_default())
            },
        )
    }

    #[tokio::test]
    async fn handshake_lists_and_calls_tools() {
        let server = server();
        let init = server
            .handle(json!({"jsonrpc": "2.0", "id": 0, "method": "initialize",
                "params": {"protocolVersion": "2025-03-26", "capabilities": {}}}))
            .await
            .unwrap();
        assert_eq!(init["result"]["protocolVersion"], json!("2025-03-26"));
        assert_eq!(init["result"]["serverInfo"]["name"], json!("inline"));

        assert_eq!(
            server
                .handle(json!({"jsonrpc": "2.0", "method": "notifications/initialized"}))
                .await,
            None
        );

        let list = server
            .handle(json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}))
            .await
            .unwrap();
        assert_eq!(list["result"]["tools"][0]["name"], json!("echo"));

        let call = server
            .handle(json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": {"name": "echo", "arguments": {"text": "hi"}}}))
            .await
            .unwrap();
        assert_eq!(call["result"]["content"][0]["text"], json!("hi"));

        let unknown = server
            .handle(json!({"jsonrpc": "2.0", "id": 3, "method": "resources/list"}))
            .await
            .unwrap();
        assert_eq!(unknown["error"]["code"], json!(METHOD_NOT_FOUND));
    }

    #[tokio::test]
    async fn cancellation_aborts_a_running_call() {
        let server = ToolServer::new(
            "inline",
            "0.0.0",
            vec![ToolDefinition {
                name: "slow".into(),
                description: String::new(),
                input_schema: json!({"type": "object"}),
                annotations: None,
            }],
            |_tool: String, _arguments: Value| async move {
                tokio::time::sleep(std::time::Duration::from_secs(60)).await;
                ToolOutput::text("late")
            },
        );
        let call = server.handle(json!({"jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": {"name": "slow"}}));
        server
            .handle(
                json!({"jsonrpc": "2.0", "method": "notifications/cancelled",
                "params": {"requestId": 7}}),
            )
            .await;
        let response = call.await.unwrap();
        assert_eq!(response["error"]["message"], json!("tool call cancelled"));
    }

    #[test]
    fn sdk_config_declares_in_process_servers() {
        assert_eq!(
            sdk_server_config(&["inline"]),
            json!({"mcpServers": {"inline": {"type": "sdk", "name": "inline"}}})
        );
    }
}
