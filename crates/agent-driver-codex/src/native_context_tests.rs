//! Explicit runtime qualification with a localhost Responses provider. Codex
//! itself (not a protocol mock) owns context injection and compaction.

use std::ffi::OsString;
use std::process::Stdio;
use std::task::{Context, Poll};
use std::time::Duration;

use inline_agent_bridge::TurnOutcome;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWriteExt, BufReader, ReadBuf};
use tokio::net::{TcpListener, TcpStream};
use tokio::process::Command;

use super::*;
use crate::process::{CodexLaunchConfig, probe_codex_version, should_scrub_codex_environment_name};

const DELIVERY_MARKER: &str = "INLINE_NATIVE_DELIVERY_MARKER";
const QUOTED_MARKER: &str = "INLINE_NATIVE_QUOTED_MARKER";
const WORKSPACE_MARKER: &str = "INLINE_NATIVE_WORKSPACE_MARKER";
const EXISTING_DEVELOPER_MARKER: &str = "INLINE_NATIVE_EXISTING_DEVELOPER_MARKER";

#[derive(Clone, Copy, PartialEq, Eq)]
enum CompactionMode {
    BetweenInputs,
    BeforeNextInput,
    WithinTurn,
}

// Tap actual native notifications without an additional protocol reader or
// persistent fixture session (ephemeral threads cannot read saved turns).
struct NativeReader<R> {
    reader: R,
    bytes: Arc<StdMutex<Vec<u8>>>,
}

impl<R: AsyncRead + Unpin> AsyncRead for NativeReader<R> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let start = buf.filled().len();
        let result = Pin::new(&mut self.reader).poll_read(cx, buf);
        if matches!(result, Poll::Ready(Ok(()))) {
            self.bytes
                .lock()
                .unwrap()
                .extend_from_slice(&buf.filled()[start..]);
        }
        result
    }
}

async fn serve_response(
    stream: TcpStream,
    requests: Arc<StdMutex<Vec<Value>>>,
    mode: CompactionMode,
) {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).await.unwrap();
    let request_line = line.clone();
    let compact = request_line
        .split_whitespace()
        .nth(1)
        .unwrap()
        .ends_with("/compact");
    let mut length = 0;
    loop {
        line.clear();
        assert!(reader.read_line(&mut line).await.unwrap() > 0);
        if line == "\r\n" {
            break;
        }
        if let Some((name, value)) = line.split_once(':')
            && name.eq_ignore_ascii_case("content-length")
        {
            length = value.trim().parse::<usize>().unwrap();
        }
    }
    // Codex can discover optional provider metadata before its first response.
    if request_line.starts_with("GET ") {
        reader
            .get_mut()
            .write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            .await
            .unwrap();
        return;
    }
    assert!(
        length > 0 && length < 2 * 1024 * 1024,
        "{request_line:?}, length={length}"
    );
    let mut body = vec![0; length];
    reader.read_exact(&mut body).await.unwrap();
    let body: Value = serde_json::from_slice(&body).unwrap();
    let number = {
        let mut requests = requests.lock().unwrap();
        requests.push(body);
        requests.len()
    };
    let (content_type, payload) = if compact {
        (
            "application/json",
            json!({"output": [{
                "type": "message", "role": "user",
                "content": [{"type": "input_text", "text": "COMPACTION_SUMMARY"}]
            }]})
            .to_string(),
        )
    } else {
        let id = format!("fixture-{number}");
        let output = if mode == CompactionMode::WithinTurn && number == 1 {
            // An unknown synthetic tool requires a continuation without running
            // a real tool. Reported usage triggers native mid-turn compaction.
            json!({"id": "synthetic-tool", "type": "function_call", "call_id": "synthetic-call",
                "name": "inline_fixture_unknown_noop", "arguments": "{}"})
        } else {
            json!({"id": format!("message-{number}"), "type": "message", "role": "assistant",
                "content": [{"type": "output_text", "text": "COMPACTION_SUMMARY"}]})
        };
        let input_tokens = if mode != CompactionMode::BetweenInputs && number == 1 {
            100_000
        } else {
            10
        };
        let events = [
            json!({"type": "response.created", "response": {"id": id}}),
            json!({"type": "response.output_item.done", "output_index": 0, "item": output}),
            json!({"type": "response.completed", "response": {"id": id,
                "usage": {"input_tokens": input_tokens, "output_tokens": 1, "total_tokens": input_tokens + 1}
            }}),
        ];
        (
            "text/event-stream",
            events
                .into_iter()
                .map(|event| format!("data: {event}\n\n"))
                .collect::<String>(),
        )
    };
    reader.get_mut().write_all(format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
        payload.len()
    ).as_bytes()).await.unwrap();
}

fn model_texts(request: &Value) -> Vec<(&str, &str)> {
    request["input"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|item| {
            let role = item["role"].as_str().unwrap_or("");
            item["content"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(move |part| part["text"].as_str().map(|text| (role, text)))
        })
        .collect()
}

async fn finish(mut turn: StartedTurn) {
    tokio::time::timeout(Duration::from_secs(25), async {
        while let Some(event) = turn.events.next().await {
            if let AgentEvent::TurnCompleted { outcome, error, .. } = event.unwrap() {
                assert_eq!(outcome, TurnOutcome::Completed, "{error:?}");
                return;
            }
        }
        panic!("provider stream closed before terminal event");
    })
    .await
    .expect("bounded local provider turn");
}

#[tokio::test]
#[ignore = "set INLINE_CODEX_CONTEXT_EXECUTABLE; runs real Codex against a localhost-only provider"]
async fn native_context_survives_compaction_without_polluting_visible_input() {
    qualify_context(CompactionMode::BetweenInputs).await;
}

#[tokio::test]
#[ignore = "set INLINE_CODEX_CONTEXT_EXECUTABLE; runs real Codex against a localhost-only provider"]
async fn native_context_survives_pre_turn_automatic_compaction() {
    qualify_context(CompactionMode::BeforeNextInput).await;
}

#[tokio::test]
#[ignore = "set INLINE_CODEX_CONTEXT_EXECUTABLE; runs real Codex against a localhost-only provider"]
async fn native_delivery_guidance_survives_mid_turn_automatic_compaction() {
    qualify_context(CompactionMode::WithinTurn).await;
}

async fn qualify_context(mode: CompactionMode) {
    let executable = std::env::var_os("INLINE_CODEX_CONTEXT_EXECUTABLE")
        .expect("explicit runtime under qualification");
    let workspace = tempfile::tempdir().unwrap();
    std::fs::write(
        workspace.path().join("AGENTS.md"),
        format!("Keep {WORKSPACE_MARKER} as project guidance.\n"),
    )
    .unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let requests = Arc::new(StdMutex::new(Vec::<Value>::new()));
    let address = listener.local_addr().unwrap();
    let captures = requests.clone();
    let server = tokio::spawn(async move {
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            serve_response(stream, captures.clone(), mode).await;
        }
    });
    let config = json!({
        "model_provider": "inline_context_fixture", "model": "gpt-5",
        "model_providers.inline_context_fixture.name": "Inline context fixture",
        "model_providers.inline_context_fixture.base_url": format!("http://{address}/v1"),
        "model_providers.inline_context_fixture.wire_api": "responses",
        "model_providers.inline_context_fixture.requires_openai_auth": false,
        "model_providers.inline_context_fixture.supports_websockets": false,
        "analytics.enabled": false, "feedback.enabled": false,
        "developer_instructions": EXISTING_DEVELOPER_MARKER,
        "model_auto_compact_token_limit": 50_000,
    });
    let mut args = vec![OsString::from("app-server")];
    for (key, value) in config.as_object().unwrap() {
        args.extend([
            OsString::from("-c"),
            OsString::from(format!("{key}={value}")),
        ]);
    }
    let launch = CodexLaunchConfig {
        executable: executable.clone().into(),
        ..Default::default()
    };
    let version = probe_codex_version(&launch).await.unwrap().version;
    let mut command = Command::new(executable);
    command
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    for (name, _) in std::env::vars_os() {
        if should_scrub_codex_environment_name(&name) {
            command.env_remove(name);
        }
    }
    let mut child = command.spawn().unwrap();
    let native_bytes = Arc::new(StdMutex::new(Vec::new()));
    let peer = CodexPeer::new(
        NativeReader {
            reader: child.stdout.take().unwrap(),
            bytes: native_bytes.clone(),
        },
        child.stdin.take().unwrap(),
        64,
    );
    let driver = CodexAppServerDriver::initialize(peer, "inline-context-qualification")
        .await
        .unwrap()
        .with_application_instructions(DELIVERY_MARKER);
    driver.verify_runtime_contract().await.unwrap();
    // Ephemeral avoids writing a fixture session into the user's chat history.
    let response = driver
        .peer
        .request(
            "thread/start",
            json!({
                "cwd": workspace.path(), "ephemeral": true, "model": "gpt-5",
                "config": driver.thread_config(workspace.path()).await.unwrap()
            }),
        )
        .await
        .unwrap();
    let session = provider_session_id_from_response("thread/start", &response).unwrap();
    let input = || TurnInput {
        text: "clean user request".to_string(),
        attachments: Vec::new(),
        context: Some(TurnContext {
            instructions: DELIVERY_MARKER.to_string(),
            conversation: QUOTED_MARKER.to_string(),
        }),
        client_message_id: Some("same-unchanged-input".to_string()),
    };
    finish(
        driver
            .start_turn(&session, input(), TurnOptions::default())
            .await
            .unwrap(),
    )
    .await;
    if mode == CompactionMode::BetweenInputs {
        finish(driver.compact_session(&session).await.unwrap()).await;
    }
    if mode != CompactionMode::WithinTurn {
        finish(
            driver
                .start_turn(&session, input(), TurnOptions::default())
                .await
                .unwrap(),
        )
        .await;
    }
    driver.shutdown().await.unwrap();
    child.start_kill().unwrap();
    child.wait().await.unwrap();
    server.abort();

    let requests = requests.lock().unwrap();
    assert!(
        requests.len() >= 3,
        "actual provider compaction request missing"
    );
    for (index, request) in [requests.first().unwrap(), requests.last().unwrap()]
        .into_iter()
        .enumerate()
    {
        let texts = model_texts(request);
        assert!(
            texts
                .iter()
                .any(|(role, text)| *role == "developer" && text.contains(DELIVERY_MARKER))
        );
        assert!(
            texts.iter().any(
                |(role, text)| *role == "developer" && text.contains(EXISTING_DEVELOPER_MARKER)
            ),
            "existing developer instructions replaced"
        );
        // Quoted history is summarized during mid-turn compaction; the stable
        // delivery guide must remain exact in the reconstructed instructions.
        if mode != CompactionMode::WithinTurn || index == 0 {
            assert!(
                texts
                    .iter()
                    .any(|(role, text)| *role == "user" && text.contains(QUOTED_MARKER))
            );
        }
        assert!(
            texts
                .iter()
                .any(|(_, text)| text.contains(WORKSPACE_MARKER)),
            "project instructions replaced"
        );
        assert!(
            texts
                .iter()
                .any(|(role, text)| *role == "user" && *text == "clean user request")
        );
    }
    let mut visible_user_items = 0;
    for line in native_bytes
        .lock()
        .unwrap()
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
    {
        let message: Value = serde_json::from_slice(line).unwrap();
        if message["method"] == "item/completed" {
            let item = &message["params"]["item"];
            if item["type"] == "userMessage" {
                visible_user_items += 1;
                assert_eq!(item["content"][0]["text"], "clean user request");
                assert_eq!(item["content"].as_array().unwrap().len(), 1);
            }
        }
    }
    assert_eq!(
        visible_user_items,
        if mode == CompactionMode::WithinTurn {
            1
        } else {
            2
        }
    );
    let completed_compactions = native_bytes
        .lock()
        .unwrap()
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
        .filter(|line| {
            let message: Value = serde_json::from_slice(line).unwrap();
            message["method"] == "item/completed"
                && message["params"]["item"]["type"] == "contextCompaction"
        })
        .count();
    assert_eq!(
        completed_compactions, 1,
        "native compaction did not execute"
    );
    eprintln!(
        "qualified native context + compaction + visible input on {}",
        version
    );
}
