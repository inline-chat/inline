//! A scripted fake of the Anthropic Messages API for driving the real
//! `claude` binary in labs and compatibility CI.
//!
//! The reply is decided by the conversation, so scenarios need no shared
//! state with the server:
//!
//! - The last user message holds tool results: reply with text
//!   `FAKE-DONE` followed by what the model saw (tool results and any text
//!   folded in beside them, such as steers and passive context).
//! - Otherwise its text is scanned for directives, one per line:
//!   `@tool <Name> <json input>` replies with that tool call (several lines
//!   give parallel calls), `@sleep <ms>` delays the reply, `@text <words>`
//!   replies with those words.
//! - Anything else: text `FAKE-OK` followed by the texts the model saw.
//!
//! Directives are honoured only when the request offers that tool, so side
//! requests (titles, summaries) always get plain text.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// One request the fake served.
#[derive(Clone, Debug)]
pub struct Served {
    pub path: String,
    pub body: Value,
    pub reply: Value,
}

impl Served {
    pub fn tool_names(&self) -> Vec<String> {
        self.body["tools"]
            .as_array()
            .map(|tools| {
                tools
                    .iter()
                    .filter_map(|tool| tool["name"].as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Texts and tool results of the last user message.
    pub fn last_user_parts(&self) -> Vec<String> {
        last_user_parts(&self.body)
    }

    pub fn summary(&self) -> Value {
        json!({
            "path": self.path,
            "model": self.body["model"],
            "stream": self.body["stream"],
            "messages": self.body["messages"].as_array().map_or(0, Vec::len),
            "tools": self.tool_names().len(),
            "last_user": self.last_user_parts(),
            "reply": self.reply,
        })
    }
}

#[derive(Clone)]
pub struct FakeMessages {
    pub base_url: String,
    served: Arc<Mutex<Vec<Served>>>,
}

impl FakeMessages {
    pub async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind fake API");
        let address = listener.local_addr().expect("fake API address");
        let served = Arc::new(Mutex::new(Vec::new()));
        let log = served.clone();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                let log = log.clone();
                tokio::spawn(async move {
                    if let Err(error) = serve(stream, log).await {
                        eprintln!("fake API connection failed: {error}");
                    }
                });
            }
        });
        Self {
            base_url: format!("http://{address}"),
            served,
        }
    }

    pub fn served(&self) -> Vec<Served> {
        self.served.lock().unwrap().clone()
    }

    /// Requests to `/v1/messages` that offered tools (the conversation's
    /// own calls, not side requests).
    pub fn conversation_calls(&self) -> Vec<Served> {
        self.served()
            .into_iter()
            .filter(|served| served.path.starts_with("/v1/messages") && !served.path.contains("count_tokens"))
            .filter(|served| !served.tool_names().is_empty())
            .collect()
    }
}

async fn serve(mut stream: TcpStream, log: Arc<Mutex<Vec<Served>>>) -> std::io::Result<()> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    let head_end = loop {
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            return Ok(());
        }
        buffer.extend_from_slice(&chunk[..read]);
        if let Some(index) = find(&buffer, b"\r\n\r\n") {
            break index + 4;
        }
    };
    let head = String::from_utf8_lossy(&buffer[..head_end]).to_string();
    let mut lines = head.split("\r\n");
    let request_line = lines.next().unwrap_or_default().to_string();
    let path = request_line
        .split_whitespace()
        .nth(1)
        .unwrap_or("/")
        .split('?')
        .next()
        .unwrap_or("/")
        .to_string();
    let content_length = lines
        .filter_map(|line| line.split_once(':'))
        .find(|(name, _)| name.trim().eq_ignore_ascii_case("content-length"))
        .and_then(|(_, value)| value.trim().parse::<usize>().ok())
        .unwrap_or(0);
    while buffer.len() < head_end + content_length {
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
    }
    let body: Value = serde_json::from_slice(&buffer[head_end..]).unwrap_or(Value::Null);

    if path.ends_with("/count_tokens") {
        let reply = json!({"input_tokens": 1000});
        log.lock().unwrap().push(Served {
            path,
            body,
            reply: reply.clone(),
        });
        return write_json(&mut stream, 200, &reply).await;
    }
    if !path.starts_with("/v1/messages") {
        let reply = json!({"type": "error", "error": {"type": "not_found_error", "message": path}});
        log.lock().unwrap().push(Served {
            path: path.clone(),
            body,
            reply: reply.clone(),
        });
        return write_json(&mut stream, 404, &reply).await;
    }

    let plan = plan_reply(&body);
    let model = body["model"].as_str().unwrap_or("claude-fake").to_string();
    let reply_summary = json!({"blocks": plan.blocks, "stop_reason": plan.stop_reason});
    log.lock().unwrap().push(Served {
        path,
        body: body.clone(),
        reply: reply_summary,
    });
    if plan.delay > Duration::ZERO {
        tokio::time::sleep(plan.delay).await;
    }
    if body["stream"].as_bool() == Some(true) {
        write_stream(&mut stream, &model, &plan).await
    } else {
        let message = json!({
            "id": format!("msg_fake_{}", uuid::Uuid::new_v4().simple()),
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": plan.blocks,
            "stop_reason": plan.stop_reason,
            "stop_sequence": null,
            "usage": {"input_tokens": 10, "output_tokens": 5}
        });
        write_json(&mut stream, 200, &message).await
    }
}

struct Plan {
    blocks: Vec<Value>,
    stop_reason: &'static str,
    delay: Duration,
}

fn plan_reply(body: &Value) -> Plan {
    let offered: Vec<String> = body["tools"]
        .as_array()
        .map(|tools| {
            tools
                .iter()
                .filter_map(|tool| tool["name"].as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    let last = last_user_message(body);
    let has_tool_result = last
        .and_then(|message| message["content"].as_array())
        .is_some_and(|blocks| blocks.iter().any(|block| block["type"] == "tool_result"));
    let parts = last_user_parts(body);
    if has_tool_result {
        return Plan {
            blocks: vec![json!({"type": "text", "text": format!("FAKE-DONE {}", parts.join(" | "))})],
            stop_reason: "end_turn",
            delay: Duration::ZERO,
        };
    }

    let mut delay = Duration::ZERO;
    let mut blocks = Vec::new();
    let mut text = None;
    for line in user_texts(last).iter().flat_map(|text| text.lines()) {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("@sleep ") {
            delay = Duration::from_millis(rest.trim().parse().unwrap_or(0));
        } else if let Some(rest) = line.strip_prefix("@text ") {
            text = Some(rest.trim().to_string());
        } else if let Some(rest) = line.strip_prefix("@tool ") {
            let (name, input) = rest.trim().split_once(' ').unwrap_or((rest.trim(), "{}"));
            if offered.iter().any(|tool| tool == name) {
                let input: Value = serde_json::from_str(input).unwrap_or_else(|_| json!({}));
                blocks.push(json!({
                    "type": "tool_use",
                    "id": format!("toolu_fake_{}", uuid::Uuid::new_v4().simple()),
                    "name": name,
                    "input": input,
                }));
            }
        }
    }
    if !blocks.is_empty() {
        return Plan {
            blocks,
            stop_reason: "tool_use",
            delay,
        };
    }
    let text = text.unwrap_or_else(|| format!("FAKE-OK {}", parts.join(" | ")));
    Plan {
        blocks: vec![json!({"type": "text", "text": text})],
        stop_reason: "end_turn",
        delay,
    }
}

fn last_user_message(body: &Value) -> Option<&Value> {
    body["messages"]
        .as_array()?
        .iter()
        .rev()
        .find(|message| message["role"] == "user")
}

fn user_texts(message: Option<&Value>) -> Vec<String> {
    let Some(message) = message else {
        return Vec::new();
    };
    match &message["content"] {
        Value::String(text) => vec![text.clone()],
        Value::Array(blocks) => blocks
            .iter()
            .filter(|block| block["type"] == "text")
            .filter_map(|block| block["text"].as_str().map(str::to_string))
            .collect(),
        _ => Vec::new(),
    }
}

fn last_user_parts(body: &Value) -> Vec<String> {
    let Some(message) = last_user_message(body) else {
        return Vec::new();
    };
    let blocks = match &message["content"] {
        Value::String(text) => return vec![clip(text)],
        Value::Array(blocks) => blocks,
        _ => return Vec::new(),
    };
    blocks
        .iter()
        .filter_map(|block| match block["type"].as_str() {
            Some("text") => block["text"].as_str().map(clip),
            Some("tool_result") => Some(format!(
                "tool_result[{}]",
                clip(&match &block["content"] {
                    Value::String(text) => text.clone(),
                    Value::Array(items) => items
                        .iter()
                        .filter_map(|item| item["text"].as_str())
                        .collect::<Vec<_>>()
                        .join(" "),
                    other => other.to_string(),
                })
            )),
            Some(other) => Some(format!("<{other}>")),
            None => None,
        })
        .collect()
}

/// Keeps directive lines and short texts readable in evidence; system
/// reminders are reduced to their first line.
fn clip(text: &str) -> String {
    let flat = text.replace('\n', " ⏎ ");
    if flat.chars().count() <= 240 {
        flat
    } else {
        format!("{}…", flat.chars().take(240).collect::<String>())
    }
}

async fn write_json(stream: &mut TcpStream, status: u16, value: &Value) -> std::io::Result<()> {
    let body = value.to_string();
    let reason = if status == 200 { "OK" } else { "Not Found" };
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nrequest-id: req_fake\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(response.as_bytes()).await?;
    stream.shutdown().await
}

async fn write_stream(stream: &mut TcpStream, model: &str, plan: &Plan) -> std::io::Result<()> {
    stream
        .write_all(
            b"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-cache\r\nrequest-id: req_fake\r\nconnection: close\r\n\r\n",
        )
        .await?;
    let id = format!("msg_fake_{}", uuid::Uuid::new_v4().simple());
    let mut events = vec![(
        "message_start",
        json!({"type": "message_start", "message": {
            "id": id, "type": "message", "role": "assistant", "model": model,
            "content": [], "stop_reason": null, "stop_sequence": null,
            "usage": {"input_tokens": 10, "output_tokens": 1}
        }}),
    )];
    for (index, block) in plan.blocks.iter().enumerate() {
        match block["type"].as_str() {
            Some("tool_use") => {
                events.push((
                    "content_block_start",
                    json!({"type": "content_block_start", "index": index, "content_block": {
                        "type": "tool_use", "id": block["id"], "name": block["name"], "input": {}
                    }}),
                ));
                events.push((
                    "content_block_delta",
                    json!({"type": "content_block_delta", "index": index, "delta": {
                        "type": "input_json_delta", "partial_json": block["input"].to_string()
                    }}),
                ));
            }
            _ => {
                events.push((
                    "content_block_start",
                    json!({"type": "content_block_start", "index": index,
                        "content_block": {"type": "text", "text": ""}}),
                ));
                events.push((
                    "content_block_delta",
                    json!({"type": "content_block_delta", "index": index,
                        "delta": {"type": "text_delta", "text": block["text"]}}),
                ));
            }
        }
        events.push((
            "content_block_stop",
            json!({"type": "content_block_stop", "index": index}),
        ));
    }
    events.push((
        "message_delta",
        json!({"type": "message_delta", "delta": {"stop_reason": plan.stop_reason, "stop_sequence": null},
            "usage": {"output_tokens": 5}}),
    ));
    events.push(("message_stop", json!({"type": "message_stop"})));
    for (name, data) in events {
        stream
            .write_all(format!("event: {name}\ndata: {data}\n\n").as_bytes())
            .await?;
    }
    stream.shutdown().await
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}
