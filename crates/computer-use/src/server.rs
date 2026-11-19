//! A small stdio MCP server: newline-delimited JSON-RPC, one call at a time.
//! UI actions are sequential by nature, so calls run in order.

use std::io::{self, BufRead, Write};

use serde_json::{Value, json};

use crate::tools;

const LATEST_PROTOCOL: &str = "2025-06-18";
const PROTOCOLS: &[&str] = &["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
const MAX_MESSAGE_BYTES: usize = 4 * 1024 * 1024;

/// One tool call's MCP result.
pub(crate) struct Output {
    pub content: Vec<Value>,
    pub is_error: bool,
}

impl Output {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            content: vec![json!({ "type": "text", "text": text.into() })],
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
        json!({ "content": self.content, "isError": self.is_error })
    }
}

/// Serves MCP on stdin and stdout until stdin closes.
pub fn serve_stdio() -> io::Result<()> {
    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    let mut session = Session::new();
    let mut line = Vec::new();
    let mut input = stdin.lock();
    loop {
        line.clear();
        if input.read_until(b'\n', &mut line)? == 0 {
            return Ok(());
        }
        if line.len() > MAX_MESSAGE_BYTES {
            write(
                &mut stdout,
                &error(Value::Null, -32600, "message too large"),
            )?;
            continue;
        }
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        let response = match serde_json::from_slice::<Value>(&line) {
            Ok(message) => session.handle(&message),
            Err(err) => Some(error(Value::Null, -32700, &format!("parse error: {err}"))),
        };
        if let Some(response) = response {
            write(&mut stdout, &response)?;
        }
    }
}

fn write(out: &mut impl Write, message: &Value) -> io::Result<()> {
    serde_json::to_writer(&mut *out, message)?;
    out.write_all(b"\n")?;
    out.flush()
}

fn error(id: Value, code: i64, message: &str) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

struct Session {
    #[cfg(target_os = "macos")]
    engine: Option<crate::engine::Engine>,
}

impl Session {
    fn new() -> Self {
        Self {
            #[cfg(target_os = "macos")]
            engine: None,
        }
    }

    /// The response to one message; `None` for notifications.
    fn handle(&mut self, message: &Value) -> Option<Value> {
        let method = message.get("method").and_then(Value::as_str);
        let id = message.get("id").cloned();
        let (Some(method), Some(id)) = (method, id) else {
            // Notifications (initialized, cancelled) and stray responses.
            return None;
        };
        let params = message.get("params").cloned().unwrap_or(Value::Null);
        let result = match method {
            "initialize" => initialize(&params),
            "ping" => json!({}),
            "tools/list" => json!({ "tools": tools::list() }),
            "tools/call" => self.call(&params).to_value(),
            _ => return Some(error(id, -32601, &format!("method not found: {method}"))),
        };
        Some(json!({ "jsonrpc": "2.0", "id": id, "result": result }))
    }

    fn call(&mut self, params: &Value) -> Output {
        let Some(name) = params.get("name").and_then(Value::as_str) else {
            return Output::error("tools/call needs a tool name");
        };
        if !tools::TOOLS.iter().any(|tool| tool.name == name) {
            return Output::error(format!("unknown tool: {name}"));
        }
        let arguments = params
            .get("arguments")
            .cloned()
            .unwrap_or_else(|| json!({}));
        self.run(name, &arguments)
    }

    #[cfg(target_os = "macos")]
    fn run(&mut self, name: &str, arguments: &Value) -> Output {
        if self.engine.is_none() {
            match crate::engine::Engine::new() {
                Ok(engine) => self.engine = Some(engine),
                Err(output) => return output,
            }
        }
        self.engine
            .as_mut()
            .expect("engine was just set")
            .call(name, arguments)
    }

    #[cfg(not(target_os = "macos"))]
    fn run(&mut self, _name: &str, _arguments: &Value) -> Output {
        Output::error("computer use is only available on macOS")
    }
}

fn initialize(params: &Value) -> Value {
    let requested = params.get("protocolVersion").and_then(Value::as_str);
    let version = requested
        .filter(|version| PROTOCOLS.contains(version))
        .unwrap_or(LATEST_PROTOCOL);
    json!({
        "protocolVersion": version,
        "capabilities": { "tools": { "listChanged": false } },
        "serverInfo": { "name": "inline-computer-use", "version": env!("CARGO_PKG_VERSION") },
        "instructions": tools::INSTRUCTIONS,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initialize_echoes_a_supported_version_and_lists_tools() {
        let mut session = Session::new();
        let init = session
            .handle(&json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": { "protocolVersion": "2025-03-26" } }))
            .unwrap();
        assert_eq!(init["result"]["protocolVersion"], "2025-03-26");
        assert!(
            init["result"]["instructions"]
                .as_str()
                .unwrap()
                .contains("snapshot")
        );

        let newer = session
            .handle(&json!({ "jsonrpc": "2.0", "id": 2, "method": "initialize",
                "params": { "protocolVersion": "2099-01-01" } }))
            .unwrap();
        assert_eq!(newer["result"]["protocolVersion"], LATEST_PROTOCOL);

        let list = session
            .handle(&json!({ "jsonrpc": "2.0", "id": 3, "method": "tools/list" }))
            .unwrap();
        assert_eq!(
            list["result"]["tools"].as_array().unwrap().len(),
            tools::TOOLS.len()
        );
    }

    #[test]
    fn notifications_get_no_response_and_unknown_methods_error() {
        let mut session = Session::new();
        assert!(
            session
                .handle(&json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }))
                .is_none()
        );
        let unknown = session
            .handle(&json!({ "jsonrpc": "2.0", "id": 9, "method": "resources/list" }))
            .unwrap();
        assert_eq!(unknown["error"]["code"], -32601);
    }

    #[test]
    fn unknown_tool_is_a_tool_error() {
        let mut session = Session::new();
        let result = session
            .handle(&json!({ "jsonrpc": "2.0", "id": 4, "method": "tools/call",
                "params": { "name": "format_disk", "arguments": {} } }))
            .unwrap();
        assert_eq!(result["result"]["isError"], true);
    }
}
