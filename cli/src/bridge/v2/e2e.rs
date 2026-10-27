//! End-to-end check of the v2 runtime: a real Inline realtime server, a real
//! `codex app-server`, and a local fake model, with no model usage or
//! account. The server side (`server/src/__tests__/e2e/bridgeV2.e2e.test.ts`)
//! creates the users and the DM, starts realtime, and runs this test with:
//!
//! - `INLINE_V2_E2E_REALTIME_URL`, `INLINE_V2_E2E_API_URL`
//! - `INLINE_V2_E2E_BOT_TOKEN`, `INLINE_V2_E2E_OWNER_TOKEN`
//! - `INLINE_V2_E2E_BOT_USER_ID`, `INLINE_V2_E2E_OWNER_USER_ID`
//! - `INLINE_V2_E2E_DM_CHAT_ID`
//!
//! Codex runs with a temporary `CODEX_HOME`, so the machine's own Codex
//! sessions and settings are never touched.

use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use inline_agent_bridge::harness::{ExecutableSource, HarnessDriver};
use inline_client::{
    AuthCredential, AuthToken, ChatCreateParticipant, ClientIdentity, ConnectRequest,
    CreateThreadRequest, HistoryRequest, InlineClient, InlineId, MessageContent, PeerRef,
    SdkBackend, SendTextRequest, SqliteStore,
};
use inline_protocol::proto;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

use super::render::Vocabulary;
use super::runtime::{Runtime, V2Config};
use super::tools::{Tools, ToolsConfig};
use super::work::OwnerCalls;

// The Claude driver's fake Messages API: replies follow `@text` and `@tool`
// directives in the user's message.
#[allow(dead_code)]
#[path = "../../../../crates/agent-driver-claude/tests/support/fake_messages.rs"]
mod fake_messages;

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} is required"))
}

/// Scripted model turns: each request gets the next output item.
#[derive(Clone)]
struct FakeModel {
    outputs: Arc<StdMutex<Vec<Value>>>,
    requests: Arc<StdMutex<Vec<Value>>>,
}

impl FakeModel {
    async fn start(outputs: Vec<Value>) -> (Self, String) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let model = Self {
            outputs: Arc::new(StdMutex::new(outputs)),
            requests: Arc::new(StdMutex::new(Vec::new())),
        };
        let serving = model.clone();
        tokio::spawn(async move {
            loop {
                let (stream, _) = listener.accept().await.unwrap();
                let model = serving.clone();
                tokio::spawn(async move { model.serve(stream).await });
            }
        });
        (model, format!("http://{address}/v1"))
    }

    async fn serve(&self, stream: TcpStream) {
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        if reader.read_line(&mut line).await.unwrap_or(0) == 0 {
            return;
        }
        let request_line = line.clone();
        let mut length = 0;
        loop {
            line.clear();
            if reader.read_line(&mut line).await.unwrap_or(0) == 0 || line == "\r\n" {
                break;
            }
            if let Some((name, value)) = line.split_once(':')
                && name.eq_ignore_ascii_case("content-length")
            {
                length = value.trim().parse::<usize>().unwrap_or(0);
            }
        }
        if request_line.starts_with("GET ") || length == 0 {
            let _ = reader
                .get_mut()
                .write_all(
                    b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .await;
            return;
        }
        let mut body = vec![0; length];
        if reader.read_exact(&mut body).await.is_err() {
            return;
        }
        let body: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
        let number = {
            let mut requests = self.requests.lock().unwrap();
            requests.push(json!({
                "request": request_line.trim(),
                "model": body.get("model"),
                "last_input": body.get("input").and_then(Value::as_array).and_then(|input| input.last().cloned()),
                // Everything the request carried, for context checks.
                "input_text": body.get("input").map(Value::to_string),
                "ask_tool": std::env::var_os("INLINE_V2_E2E_DUMP_TOOLS").and_then(|_| {
                    body.get("tools")?.as_array()?.iter().find(|tool| tool.get("name") == Some(&json!("request_user_input"))).cloned()
                }),
                "tools": body.get("tools").and_then(Value::as_array).map(|tools| {
                    tools
                        .iter()
                        .map(|tool| tool.get("name").or(tool.get("type")).cloned())
                        .collect::<Vec<_>>()
                }),
            }));
            requests.len()
        };
        let output = {
            let mut outputs = self.outputs.lock().unwrap();
            if outputs.is_empty() {
                json!({"type": "message", "role": "assistant",
                    "content": [{"type": "output_text", "text": "E2E_DONE"}]})
            } else {
                outputs.remove(0)
            }
        };
        let mut output = output;
        // `_delay_ms` holds the reply back, so a turn stays running.
        if let Some(delay) = output
            .as_object_mut()
            .and_then(|output| output.remove("_delay_ms"))
            .and_then(|delay| delay.as_u64())
        {
            tokio::time::sleep(Duration::from_millis(delay)).await;
        }
        if output.get("id").is_none() {
            output["id"] = json!(format!("item-{number}"));
        }
        let id = format!("response-{number}");
        let events = [
            json!({"type": "response.created", "response": {"id": id}}),
            json!({"type": "response.output_item.done", "output_index": 0, "item": output}),
            json!({"type": "response.completed", "response": {"id": id,
                "usage": {"input_tokens": 10, "output_tokens": 1, "total_tokens": 11}}}),
        ];
        let payload: String = events
            .into_iter()
            .map(|event| format!("data: {event}\n\n"))
            .collect();
        let _ = reader
            .get_mut()
            .write_all(
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
                    payload.len()
                )
                .as_bytes(),
            )
            .await;
    }

    fn request_count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }
}

struct OwnerClient(InlineClient);

impl OwnerCalls for OwnerClient {
    fn connect(
        &self,
        input: proto::ConnectAgentSessionInput,
    ) -> futures_util::future::BoxFuture<'_, Result<proto::ConnectAgentSessionResult, String>> {
        Box::pin(async move {
            self.0
                .connect_agent_session(input)
                .await
                .map_err(|error| error.to_string())
        })
    }

    fn lookup(
        &self,
        input: proto::GetAgentSessionInput,
    ) -> futures_util::future::BoxFuture<'_, Result<proto::GetAgentSessionResult, String>> {
        Box::pin(async move {
            self.0
                .get_agent_session(input)
                .await
                .map_err(|error| error.to_string())
        })
    }
}

async fn client(dir: &std::path::Path, name: &str, token: &str) -> InlineClient {
    let store = SqliteStore::open(dir.join(format!("{name}.sqlite"))).unwrap();
    let backend = SdkBackend::builder()
        .api_base_url(env("INLINE_V2_E2E_API_URL"))
        .realtime_url(env("INLINE_V2_E2E_REALTIME_URL"))
        .identity(ClientIdentity::new(
            "agent-bridge-e2e",
            env!("CARGO_PKG_VERSION"),
        ))
        .store(store)
        .build()
        .unwrap();
    let client = InlineClient::builder().backend(backend).build().spawn();
    client
        .connect(ConnectRequest::new(AuthCredential::AccessToken {
            token: AuthToken::try_new(token).unwrap(),
        }))
        .await
        .unwrap();
    client
}

/// Bot messages in the DM, oldest first, as text.
async fn bot_texts(owner: &InlineClient, chat_id: i64, bot_user_id: i64) -> Vec<(i64, String)> {
    let page = owner
        .history(HistoryRequest {
            chat_id: InlineId::new(chat_id),
            limit: Some(100),
            before_message_id: None,
            after_message_id: None,
        })
        .await
        .unwrap();
    page.messages
        .into_iter()
        .filter(|message| message.sender_id.get() == bot_user_id)
        .map(|message| {
            let text = match message.content {
                MessageContent::Text { text } => text,
                _ => String::new(),
            };
            (message.message_id.get(), text)
        })
        .collect()
}

/// What the fake model saw, for failure messages.
trait Seen {
    fn seen(&self) -> String;
}

impl Seen for FakeModel {
    fn seen(&self) -> String {
        format!("{:#?}", self.requests.lock().unwrap())
    }
}

impl Seen for fake_messages::FakeMessages {
    fn seen(&self) -> String {
        format!(
            "{:#?}",
            self.served()
                .iter()
                .map(fake_messages::Served::summary)
                .collect::<Vec<_>>()
        )
    }
}

async fn wait_for(
    model: &dyn Seen,
    owner: &InlineClient,
    chat_id: i64,
    bot_user_id: i64,
    what: &str,
    found: impl Fn(&[(i64, String)]) -> bool,
) -> Vec<(i64, String)> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(90);
    loop {
        let texts = bot_texts(owner, chat_id, bot_user_id).await;
        if found(&texts) {
            return texts;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for {what}; bot said: {texts:#?}; model saw: {}",
            model.seen()
        );
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

async fn send(owner: &InlineClient, chat_id: i64, text: &str) {
    owner
        .send_text(SendTextRequest::new(
            PeerRef::Chat {
                chat_id: InlineId::new(chat_id),
            },
            text,
        ))
        .await
        .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "needs the server side of the bridge v2 end-to-end test"]
async fn codex_round_trip_through_inline() {
    let _ = env_logger::builder()
        .is_test(true)
        .parse_filters(
            "inline::bridge::v2=debug,inline_agent_driver_codex=debug,inline_client=info",
        )
        .try_init();
    let bot_user_id: i64 = env("INLINE_V2_E2E_BOT_USER_ID").parse().unwrap();
    let owner_user_id: i64 = env("INLINE_V2_E2E_OWNER_USER_ID").parse().unwrap();
    let chat_id: i64 = env("INLINE_V2_E2E_DM_CHAT_ID").parse().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join("project");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join("README.md"), "e2e project\n").unwrap();

    // Turn 1 answers directly. Turn 2 uses Inline tools. Turn 3 runs a
    // command that needs approval, then answers. In a group thread, the agent
    // then moves its work into a subthread and keeps answering there.
    let inline_tool = |name: &str, arguments: Value| {
        json!({"type": "function_call", "call_id": format!("call-{name}-{}", uuid::Uuid::new_v4()),
            "namespace": "inline", "name": name, "arguments": arguments.to_string()})
    };
    let (model, base_url) = FakeModel::start(vec![
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_ANSWER_ONE"}]}),
        inline_tool("send_message", json!({"text": "E2E_TOOL_SENT"})),
        inline_tool("get_current_context", json!({})),
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_TOOLS_DONE"}]}),
        // A question the owner answers through the card's form.
        json!({"type": "function_call", "call_id": "call-ask", "name": "request_user_input",
            "arguments": json!({"questions": [{"id": "color", "header": "Color",
                "question": "Which color fits?", "options": [
                    {"label": "Red", "description": "Warm"},
                    {"label": "Blue", "description": "Cool"}]}]}).to_string()}),
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_ASKED"}]}),
        // A slow reply, so a message sent meanwhile steers the running turn.
        json!({"_delay_ms": 3000, "type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_BEFORE_STEER"}]}),
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_AFTER_STEER"}]}),
        // A slow reply that /stop interrupts; it must never be posted.
        json!({"_delay_ms": 6000, "type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_NEVER_POSTED"}]}),
        // `/new` starts a fresh session in a new thread under the DM message.
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_NEW_THREAD"}]}),
        // Escalation makes Codex ask for approval before running it.
        json!({"type": "function_call", "call_id": "call-1", "name": "exec_command",
            "arguments": json!({"cmd": "echo E2E_RAN > ran.txt",
                "sandbox_permissions": "require_escalated",
                "justification": "Write the e2e marker",
                "workdir": folder.display().to_string()}).to_string()}),
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_ANSWER_TWO"}]}),
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_AFTER_RESTART"}]}),
        inline_tool(
            "start_subthread",
            json!({"title": "E2E sub", "summary": "Moved for the long part"}),
        ),
        inline_tool("send_message", json!({"text": "E2E_IN_SUBTHREAD"})),
        inline_tool("report_status", json!({"text": "Halfway"})),
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_SUB_DONE"}]}),
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_SUB_REPLY"}]}),
        // A second group thread: a mention, then (mentions-only) a plain
        // message the agent observes, then a mention that sees it.
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_G2_ONE"}]}),
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_G2_TWO"}]}),
        // A plain reply to the agent's answer addresses it.
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_G2_REPLY"}]}),
    ])
    .await;
    let codex_home = dir.path().join("codex-home");
    std::fs::create_dir_all(&codex_home).unwrap();
    std::fs::write(
        codex_home.join("config.toml"),
        format!(
            "model_provider = \"inline_e2e\"\nmodel = \"gpt-5\"\napproval_policy = \"on-request\"\n\
             sandbox_mode = \"read-only\"\nthread_unload_delay_secs = 1\n\n[model_providers.inline_e2e]\nname = \"Inline E2E\"\n\
             base_url = \"{base_url}\"\nwire_api = \"responses\"\nrequires_openai_auth = false\n\
             supports_websockets = false\n\n[analytics]\nenabled = false\n\n[feedback]\nenabled = false\n"
        ),
    )
    .unwrap();
    // SAFETY: set before any thread reads the environment for Codex.
    unsafe { isolate_codex(&codex_home) };

    let owner = client(dir.path(), "owner", &env("INLINE_V2_E2E_OWNER_TOKEN")).await;
    let bridge = CodexBridge {
        dir: dir.path().to_owned(),
        folder: folder.clone(),
        owner: owner.clone(),
        owner_user_id,
        bot_user_id,
        dm_chat_id: chat_id,
    };
    let (stop, running, bot) = bridge.start().await;

    // 1. A DM message runs a turn and the answer arrives.
    send(&owner, chat_id, "Say the first answer").await;
    wait_for(
        &model,
        &owner,
        chat_id,
        bot_user_id,
        "the first answer",
        |texts| {
            texts
                .iter()
                .any(|(_, text)| text.contains("E2E_ANSWER_ONE"))
        },
    )
    .await;
    assert!(model.request_count() >= 1);

    // The work is recorded on the server, connected by the owner.
    let work = owner
        .get_agent_session(proto::GetAgentSessionInput {
            peer_id: Some(super::api::chat_peer(chat_id)),
            bot_user_id,
            ..Default::default()
        })
        .await
        .unwrap();
    let connection = work.connection.expect("the work is connected");
    assert!(!connection.session_ref.is_empty());
    let agent_session_id = connection
        .agent_session
        .as_ref()
        .map(|session| session.id)
        .unwrap();

    // 2. Inline tools act as the agent: a message sent by the tool arrives,
    // and the context names this work's thread.
    send(&owner, chat_id, "Use your tools").await;
    wait_for(
        &model,
        &owner,
        chat_id,
        bot_user_id,
        "the tool turn",
        |texts| {
            texts.iter().any(|(_, text)| text.contains("E2E_TOOL_SENT"))
                && texts
                    .iter()
                    .any(|(_, text)| text.contains("E2E_TOOLS_DONE"))
        },
    )
    .await;
    assert!(
        tool_outputs(&model)
            .iter()
            .any(|output| output.contains(&format!("\"chat_id\":{chat_id}"))),
        "get_current_context names the DM: {:#?}",
        tool_outputs(&model)
    );

    // 3. A question card: the owner answers through its form, and the answer
    // reaches Codex.
    send(&owner, chat_id, "Ask me something").await;
    let (card, _) = wait_card(&model, &owner, chat_id, "Which color fits?", CardKind::Form).await;
    owner
        .invoke_rpc(
            proto::Method::InvokeMessageAction,
            proto::rpc_call::Input::InvokeMessageAction(proto::InvokeMessageActionInput {
                peer_id: Some(super::api::chat_peer(chat_id)),
                message_id: card,
                action_id: super::render::QUESTION_FORM_ID.to_owned(),
                form: Some(proto::MessageFormSubmission {
                    values: vec![proto::MessageFormValue {
                        field_id: "f0".to_owned(),
                        value: Some(proto::message_form_value::Value::Selection(
                            proto::MessageFormSelection {
                                option_ids: vec!["o1".to_owned()],
                                other_text: None,
                            },
                        )),
                        redacted: false,
                    }],
                }),
            }),
        )
        .await
        .unwrap();
    wait_for(
        &model,
        &owner,
        chat_id,
        bot_user_id,
        "the answer after the question",
        |texts| texts.iter().any(|(_, text)| text.contains("E2E_ASKED")),
    )
    .await;
    assert!(
        tool_outputs(&model)
            .iter()
            .any(|output| output.contains("Blue")),
        "the form's choice reached Codex: {:#?}",
        tool_outputs(&model)
    );

    // 4. A message sent while a turn runs steers it.
    let before = model.request_count();
    send(&owner, chat_id, "Start the long part").await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    while model.request_count() == before {
        assert!(
            tokio::time::Instant::now() < deadline,
            "the long turn never reached the model"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    send(&owner, chat_id, "E2E_STEER also do this").await;
    wait_for(
        &model,
        &owner,
        chat_id,
        bot_user_id,
        "the steered answer",
        |texts| {
            texts
                .iter()
                .any(|(_, text)| text.contains("E2E_AFTER_STEER"))
        },
    )
    .await;
    assert!(
        model.requests.lock().unwrap().iter().any(|request| request
            .get("last_input")
            .is_some_and(|input| input.to_string().contains("E2E_STEER"))),
        "the steer reached the running turn"
    );

    // 4b. /stop interrupts a running turn: its late reply is dropped and the
    // work settles idle.
    let before = model.request_count();
    send(&owner, chat_id, "Begin something slow").await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    while model.request_count() == before {
        assert!(
            tokio::time::Instant::now() < deadline,
            "the slow turn never reached the model"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    send(&owner, chat_id, "/stop").await;
    let work_id = owner
        .get_agent_session(proto::GetAgentSessionInput {
            peer_id: Some(super::api::chat_peer(chat_id)),
            bot_user_id,
            ..Default::default()
        })
        .await
        .unwrap()
        .connection
        .and_then(|connection| connection.agent_session)
        .map(|session| session.id)
        .unwrap();
    wait_idle(&owner, chat_id, work_id).await;
    // Past the held reply's delay: nothing from the stopped turn appears.
    tokio::time::sleep(Duration::from_secs(7)).await;
    let texts = bot_texts(&owner, chat_id, bot_user_id).await;
    assert!(
        !texts
            .iter()
            .any(|(_, text)| text.contains("E2E_NEVER_POSTED")),
        "a stopped turn posted its late reply: {texts:#?}"
    );

    // 4c. `/new` opens a thread under the message with a fresh session.
    send(&owner, chat_id, "/new the side task").await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(90);
    let new_thread = loop {
        let chats = owner
            .invoke_rpc(
                proto::Method::GetChats,
                proto::rpc_call::Input::GetChats(proto::GetChatsInput {
                    include_subthreads: Some(true),
                }),
            )
            .await
            .unwrap();
        let proto::rpc_result::Result::GetChats(chats) = chats else {
            panic!("unexpected result");
        };
        if let Some(chat) = chats
            .chats
            .iter()
            .find(|chat| chat.parent_chat_id == Some(chat_id))
        {
            break chat.id;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "/new opened no thread under the DM; bot said: {:#?}",
            bot_texts(&owner, chat_id, bot_user_id).await
        );
        tokio::time::sleep(Duration::from_millis(500)).await;
    };
    wait_for(
        &model,
        &owner,
        new_thread,
        bot_user_id,
        "the answer in the new thread",
        |texts| {
            texts
                .iter()
                .any(|(_, text)| text.contains("E2E_NEW_THREAD"))
        },
    )
    .await;
    let new_work = owner
        .get_agent_session(proto::GetAgentSessionInput {
            peer_id: Some(super::api::chat_peer(new_thread)),
            bot_user_id,
            ..Default::default()
        })
        .await
        .unwrap()
        .connection
        .map(|connection| connection.session_ref)
        .unwrap_or_default();
    let dm_work = owner
        .get_agent_session(proto::GetAgentSessionInput {
            peer_id: Some(super::api::chat_peer(chat_id)),
            bot_user_id,
            ..Default::default()
        })
        .await
        .unwrap()
        .connection
        .map(|connection| connection.session_ref)
        .unwrap_or_default();
    assert!(
        !new_work.is_empty() && new_work != dm_work,
        "the new thread has its own session"
    );

    // 5. A command needs approval: the card carries Codex's own choices, and
    // the owner's approval runs it.
    send(&owner, chat_id, "Run the check").await;
    let (card, action) =
        wait_card(&model, &owner, chat_id, "echo E2E_RAN", CardKind::Buttons).await;
    owner
        .invoke_rpc(
            proto::Method::InvokeMessageAction,
            proto::rpc_call::Input::InvokeMessageAction(proto::InvokeMessageActionInput {
                peer_id: Some(super::api::chat_peer(chat_id)),
                message_id: card,
                action_id: action,
                ..Default::default()
            }),
        )
        .await
        .unwrap();
    wait_for(
        &model,
        &owner,
        chat_id,
        bot_user_id,
        "the second answer",
        |texts| {
            texts
                .iter()
                .any(|(_, text)| text.contains("E2E_ANSWER_TWO"))
        },
    )
    .await;
    assert_eq!(
        std::fs::read_to_string(folder.join("ran.txt"))
            .unwrap()
            .trim(),
        "E2E_RAN",
        "the approved command ran in the work's folder"
    );

    // The run state reached the server and settled.
    wait_idle(&owner, chat_id, agent_session_id).await;

    // 6. /release hands the session back with a resume command.
    send(&owner, chat_id, "/release").await;
    wait_for(
        &model,
        &owner,
        chat_id,
        bot_user_id,
        "the release handoff",
        |texts| texts.iter().any(|(_, text)| text.contains("codex resume")),
    )
    .await;

    // 6b. The bridge restarts (new client, new Codex process, same ledger):
    // the next message resumes the same native session from the server.
    let session_ref = |work: proto::GetAgentSessionResult| {
        work.connection
            .map(|connection| connection.session_ref)
            .unwrap_or_default()
    };
    let before_restart = session_ref(
        owner
            .get_agent_session(proto::GetAgentSessionInput {
                peer_id: Some(super::api::chat_peer(chat_id)),
                bot_user_id,
                ..Default::default()
            })
            .await
            .unwrap(),
    );
    let _ = stop.send(());
    let outcome = tokio::time::timeout(Duration::from_secs(20), running).await;
    assert!(
        matches!(outcome, Ok(Ok(Ok(())))),
        "runtime ended cleanly: {outcome:?}"
    );
    bot.shutdown().await.unwrap();
    drop(bot);
    // Sent while the bridge is down: the restarted bridge catches up.
    send(&owner, chat_id, "Back after the restart").await;
    let (stop, running, _bot) = bridge.start().await;
    wait_for(
        &model,
        &owner,
        chat_id,
        bot_user_id,
        "the answer after the restart",
        |texts| {
            texts
                .iter()
                .any(|(_, text)| text.contains("E2E_AFTER_RESTART"))
        },
    )
    .await;
    let after_restart = session_ref(
        owner
            .get_agent_session(proto::GetAgentSessionInput {
                peer_id: Some(super::api::chat_peer(chat_id)),
                bot_user_id,
                ..Default::default()
            })
            .await
            .unwrap(),
    );
    assert!(!before_restart.is_empty());
    assert_eq!(
        before_restart, after_restart,
        "the restarted bridge resumed the same Codex thread"
    );

    // 7. In a group thread, a mention starts a work that moves itself into a
    // subthread; the parent keeps a card and the work goes on there.
    let group = owner
        .create_thread(CreateThreadRequest {
            title: Some("E2E group".to_owned()),
            space_id: None,
            description: None,
            emoji: None,
            is_public: false,
            participants: vec![
                ChatCreateParticipant::from(InlineId::new(owner_user_id)),
                ChatCreateParticipant::from(InlineId::new(bot_user_id)),
            ],
        })
        .await
        .unwrap()
        .chat_id
        .get();
    let mut mention = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(group),
        },
        format!("[@Codex](inline://user?id={bot_user_id}) take this to a subthread"),
    );
    mention.parse_markdown = true;
    owner.send_text(mention).await.unwrap();
    wait_for(
        &model,
        &owner,
        group,
        bot_user_id,
        "the parent card",
        |texts| texts.iter().any(|(_, text)| text.contains("continues in")),
    )
    .await;
    // The model sees the tool's result only with its next request.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    let subthread = loop {
        if let Some(subthread) = tool_outputs(&model)
            .iter()
            .filter_map(|output| serde_json::from_str::<Value>(output).ok())
            .find(|output| output.get("link").is_some())
            .and_then(|output| output["chat_id"].as_i64())
        {
            break subthread;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "start_subthread never returned: {:#?}",
            tool_outputs(&model)
        );
        tokio::time::sleep(Duration::from_millis(200)).await;
    };
    wait_for(
        &model,
        &owner,
        subthread,
        bot_user_id,
        "output in the subthread",
        |texts| {
            texts
                .iter()
                .any(|(_, text)| text.contains("E2E_IN_SUBTHREAD"))
                && texts.iter().any(|(_, text)| text.contains("E2E_SUB_DONE"))
        },
    )
    .await;
    let parent = bot_texts(&owner, group, bot_user_id).await;
    assert!(
        !parent.iter().any(|(_, text)| text.contains("E2E_SUB_DONE")),
        "the answer went to the subthread only: {parent:#?}"
    );
    wait_for(
        &model,
        &owner,
        group,
        bot_user_id,
        "the status on the parent card",
        |texts| {
            texts
                .iter()
                .any(|(_, text)| text.contains("Status: Halfway"))
        },
    )
    .await;
    // The server publishes the work in the subthread now.
    let moved = owner
        .get_agent_session(proto::GetAgentSessionInput {
            peer_id: Some(super::api::chat_peer(subthread)),
            bot_user_id,
            ..Default::default()
        })
        .await
        .unwrap();
    assert!(
        moved
            .connection
            .is_some_and(|connection| !connection.session_ref.is_empty()),
        "the work is recorded in the subthread"
    );
    // A plain reply in the subthread reaches the same work.
    send(&owner, subthread, "Keep going here").await;
    wait_for(
        &model,
        &owner,
        subthread,
        bot_user_id,
        "the subthread reply",
        |texts| texts.iter().any(|(_, text)| text.contains("E2E_SUB_REPLY")),
    )
    .await;

    // 8. Passive context: in a mentions-only group thread a plain message
    // does not wake the agent, and reaches it with its next mention as
    // untrusted context.
    let group_two = owner
        .create_thread(CreateThreadRequest {
            title: Some("E2E group two".to_owned()),
            space_id: None,
            description: None,
            emoji: None,
            is_public: false,
            participants: vec![
                ChatCreateParticipant::from(InlineId::new(owner_user_id)),
                ChatCreateParticipant::from(InlineId::new(bot_user_id)),
            ],
        })
        .await
        .unwrap()
        .chat_id
        .get();
    let mention = |text: &str| {
        let mut request = SendTextRequest::new(
            PeerRef::Chat {
                chat_id: InlineId::new(group_two),
            },
            format!("[@Codex](inline://user?id={bot_user_id}) {text}"),
        );
        request.parse_markdown = true;
        request
    };
    owner.send_text(mention("hello there")).await.unwrap();
    wait_for(
        &model,
        &owner,
        group_two,
        bot_user_id,
        "the first group answer",
        |texts| texts.iter().any(|(_, text)| text.contains("E2E_G2_ONE")),
    )
    .await;
    owner
        .invoke_rpc(
            proto::Method::SetAgentParticipation,
            proto::rpc_call::Input::SetAgentParticipation(proto::SetAgentParticipationInput {
                peer_id: Some(super::api::chat_peer(group_two)),
                bot_user_id,
                mode: proto::AgentParticipationMode::MentionsOnly as i32,
                ..Default::default()
            }),
        )
        .await
        .unwrap();
    let requests_before = model.request_count();
    send(&owner, group_two, "E2E_PASSIVE_LINE for whoever reads this").await;
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert_eq!(
        model.request_count(),
        requests_before,
        "an unaddressed message in a mentions-only thread woke the agent"
    );
    owner
        .send_text(mention("what did I just say?"))
        .await
        .unwrap();
    wait_for(
        &model,
        &owner,
        group_two,
        bot_user_id,
        "the second group answer",
        |texts| texts.iter().any(|(_, text)| text.contains("E2E_G2_TWO")),
    )
    .await;
    let last = model.requests.lock().unwrap().last().cloned().unwrap();
    assert!(
        last.get("input_text")
            .and_then(Value::as_str)
            .is_some_and(|input| input.contains("E2E_PASSIVE_LINE")),
        "the observed message reached the agent as context"
    );
    let texts = bot_texts(&owner, group_two, bot_user_id).await;
    let answer = texts
        .iter()
        .rev()
        .find(|(_, text)| text.contains("E2E_G2_TWO"))
        .map(|(id, _)| *id)
        .unwrap();
    let mut reply = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(group_two),
        },
        "and one more thing",
    );
    reply.reply_to_message_id = Some(InlineId::new(answer));
    owner.send_text(reply).await.unwrap();
    wait_for(
        &model,
        &owner,
        group_two,
        bot_user_id,
        "the answer to a reply",
        |texts| texts.iter().any(|(_, text)| text.contains("E2E_G2_REPLY")),
    )
    .await;

    let _ = stop.send(());
    let outcome = tokio::time::timeout(Duration::from_secs(20), running).await;
    assert!(
        matches!(outcome, Ok(Ok(Ok(())))),
        "runtime ended cleanly: {outcome:?}"
    );
}

/// One run of the bridge for the Codex test: its own bot client, tool host
/// and Codex process, over the shared ledger.
struct CodexBridge {
    dir: std::path::PathBuf,
    folder: std::path::PathBuf,
    owner: InlineClient,
    owner_user_id: i64,
    bot_user_id: i64,
    dm_chat_id: i64,
}

type Running = tokio::task::JoinHandle<Result<(), String>>;

impl CodexBridge {
    /// Starts the bridge on the bot's persisted store, so a restart catches
    /// up from where the last run stopped.
    async fn start(&self) -> (tokio::sync::oneshot::Sender<()>, Running, InlineClient) {
        let executable = which_codex();
        let bot = client(&self.dir, "bot", &env("INLINE_V2_E2E_BOT_TOKEN")).await;
        let tools = Tools::new(ToolsConfig {
            bot: bot.clone(),
            provider: inline_agent_bridge::ProviderId::new("codex").unwrap(),
            bot_user_id: self.bot_user_id,
            owner_user_id: self.owner_user_id,
            agent_name: "Codex".to_owned(),
            folder: self.folder.clone(),
            attachments_dir: self.dir.join("attachments"),
        });
        let codex = inline_agent_driver_codex::harness::CodexHarness::new(
            inline_agent_driver_codex::harness::CodexHarnessConfig {
                launch: inline_agent_driver_codex::CodexLaunchConfig {
                    executable: executable.clone(),
                    ..Default::default()
                },
                source: ExecutableSource::Path,
                pinned_sha256: None,
                bridge_version: env!("CARGO_PKG_VERSION").to_owned(),
                cache_root: self.dir.join("cache"),
            },
        );
        codex.configure_host_tools(tools.configuration());
        let harness: Arc<dyn HarnessDriver> = Arc::new(codex);
        let mut events = bot.take_lossless_events().unwrap();
        let runtime = Runtime::new(
            V2Config {
                vocabulary: Vocabulary::Codex,
                agent_name: "Codex".to_owned(),
                installation_id: "e2e-installation".to_owned(),
                owner_user_id: self.owner_user_id,
                bot_user_id: self.bot_user_id,
                bot_username: "e2e_codex_bot".to_owned(),
                dm_chat_id: self.dm_chat_id,
                folder: self.folder.clone(),
                machine_label: "e2e".to_owned(),
                executable_path: Some(executable.display().to_string()),
                accept_messages_after: 0,
                allowlist: Vec::new(),
                ledger_path: self.dir.join("ledger.sqlite"),
                attachments_dir: self.dir.join("attachments"),
            },
            bot.clone(),
            Arc::new(OwnerClient(self.owner.clone())),
            harness,
            Some(tools),
        )
        .unwrap();
        let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
        let running = tokio::spawn(async move {
            runtime
                .run(&mut events, async {
                    let _ = stopped.await;
                })
                .await
                .map_err(|error| error.to_string())
        });
        (stop, running, bot)
    }
}

/// Waits until the server reports the work idle.
async fn wait_idle(owner: &InlineClient, chat_id: i64, agent_session_id: i64) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let states = owner
            .invoke_rpc(
                proto::Method::GetAgentSessionStates,
                proto::rpc_call::Input::GetAgentSessionStates(proto::GetAgentSessionStatesInput {
                    peer_id: Some(super::api::chat_peer(chat_id)),
                }),
            )
            .await
            .unwrap();
        let proto::rpc_result::Result::GetAgentSessionStates(states) = states else {
            panic!("unexpected result");
        };
        let state = states
            .sessions
            .iter()
            .find(|session| session.id == agent_session_id)
            .and_then(|session| session.state.clone());
        if state.is_some_and(|state| state.run_state == proto::AgentRunState::Idle as i32) {
            return;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "run state never settled to idle"
        );
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

/// Outputs of Inline tool calls, as the model received them.
fn tool_outputs(model: &FakeModel) -> Vec<String> {
    model
        .requests
        .lock()
        .unwrap()
        .iter()
        .filter_map(|request| request.get("last_input"))
        .filter(|input| input.get("type") == Some(&json!("function_call_output")))
        .filter_map(|input| match input.get("output") {
            Some(Value::String(text)) => Some(text.clone()),
            Some(other) => Some(other.to_string()),
            None => None,
        })
        .collect()
}

enum CardKind {
    Buttons,
    Form,
}

/// Waits for the bot's card whose text contains `needle`: the message with
/// decision buttons, or with a form. A progress row can show the same text
/// first. Returns the card and its first button.
async fn wait_card(
    model: &dyn Seen,
    owner: &InlineClient,
    chat_id: i64,
    needle: &str,
    kind: CardKind,
) -> (i64, String) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(90);
    loop {
        let result = owner
            .invoke_rpc(
                proto::Method::GetChatHistory,
                proto::rpc_call::Input::GetChatHistory(proto::GetChatHistoryInput {
                    peer_id: Some(super::api::chat_peer(chat_id)),
                    limit: Some(100),
                    ..Default::default()
                }),
            )
            .await
            .unwrap();
        let proto::rpc_result::Result::GetChatHistory(history) = result else {
            panic!("unexpected result");
        };
        for message in &history.messages {
            if !message
                .message
                .as_deref()
                .unwrap_or_default()
                .contains(needle)
            {
                continue;
            }
            match kind {
                CardKind::Buttons => {
                    if let Some(action) = message
                        .actions
                        .as_ref()
                        .and_then(|actions| actions.rows.first())
                        .and_then(|row| row.actions.first())
                    {
                        return (message.id, action.action_id.clone());
                    }
                }
                CardKind::Form => {
                    if message.block_content.as_ref().is_some_and(|content| {
                        content
                            .blocks
                            .iter()
                            .any(|block| matches!(block.kind, Some(proto::block::Kind::Form(_))))
                    }) {
                        return (message.id, String::new());
                    }
                }
            }
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for the card with {needle}; model saw: {}",
            model.seen()
        );
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "needs the server side of the bridge v2 end-to-end test"]
async fn claude_round_trip_through_inline() {
    let _ = env_logger::builder()
        .is_test(true)
        .parse_filters(
            "inline::bridge::v2=debug,inline_agent_driver_claude=debug,inline_client=info",
        )
        .try_init();
    let bot_user_id: i64 = env("INLINE_V2_E2E_BOT_USER_ID").parse().unwrap();
    let owner_user_id: i64 = env("INLINE_V2_E2E_OWNER_USER_ID").parse().unwrap();
    let chat_id: i64 = env("INLINE_V2_E2E_DM_CHAT_ID").parse().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join("project");
    std::fs::create_dir_all(&folder).unwrap();
    let api = fake_messages::FakeMessages::start().await;
    let owner = client(dir.path(), "owner", &env("INLINE_V2_E2E_OWNER_TOKEN")).await;
    // An isolated config and a dummy key against the fake API: no account.
    let config_dir = dir.path().join("claude-config");
    std::fs::create_dir_all(&config_dir).unwrap();
    let bridge = ClaudeBridge {
        dir: dir.path().to_owned(),
        folder: folder.clone(),
        config_dir,
        api_base_url: api.base_url.clone(),
        owner: owner.clone(),
        owner_user_id,
        bot_user_id,
        dm_chat_id: chat_id,
    };
    let (stop, running, bot) = bridge.start().await;

    // 1. A DM message runs a turn and the answer arrives.
    send(&owner, chat_id, "Say hello\n@text E2E_CLAUDE_ONE").await;
    wait_for(
        &api,
        &owner,
        chat_id,
        bot_user_id,
        "the first answer",
        |texts| {
            texts
                .iter()
                .any(|(_, text)| text.contains("E2E_CLAUDE_ONE"))
        },
    )
    .await;

    // 2. Inline tools reach Claude over `mcp_message` and act as the agent.
    send(
        &owner,
        chat_id,
        "Use a tool\n@tool mcp__inline__send_message {\"text\": \"E2E_CLAUDE_TOOL\"}",
    )
    .await;
    wait_for(
        &api,
        &owner,
        chat_id,
        bot_user_id,
        "the tool message",
        |texts| {
            texts
                .iter()
                .any(|(_, text)| text.contains("E2E_CLAUDE_TOOL"))
                && texts.iter().any(|(_, text)| text.contains("FAKE-DONE"))
        },
    )
    .await;

    // 3. AskUserQuestion: the card is an Inline form, and the owner's choice
    // reaches Claude as the tool's answer.
    send(
        &owner,
        chat_id,
        &format!(
            "Ask me\n@tool AskUserQuestion {}",
            json!({"questions": [{"question": "Which color fits?", "header": "Color",
                "multiSelect": false, "options": [
                    {"label": "Red", "description": "Warm"},
                    {"label": "Blue", "description": "Cool"}]}]})
        ),
    )
    .await;
    let (card, _) = wait_card(&api, &owner, chat_id, "Which color fits?", CardKind::Form).await;
    owner
        .invoke_rpc(
            proto::Method::InvokeMessageAction,
            proto::rpc_call::Input::InvokeMessageAction(proto::InvokeMessageActionInput {
                peer_id: Some(super::api::chat_peer(chat_id)),
                message_id: card,
                action_id: super::render::QUESTION_FORM_ID.to_owned(),
                form: Some(proto::MessageFormSubmission {
                    values: vec![proto::MessageFormValue {
                        field_id: "f0".to_owned(),
                        value: Some(proto::message_form_value::Value::Selection(
                            proto::MessageFormSelection {
                                option_ids: vec!["o1".to_owned()],
                                other_text: None,
                            },
                        )),
                        redacted: false,
                    }],
                }),
            }),
        )
        .await
        .unwrap();
    wait_for(
        &api,
        &owner,
        chat_id,
        bot_user_id,
        "Claude's answer after the question",
        |texts| {
            texts
                .iter()
                .any(|(_, text)| text.contains("FAKE-DONE") && text.contains("Blue"))
        },
    )
    .await;

    // 3b. A message sent while Claude works steers it.
    let before = api.conversation_calls().len();
    send(
        &owner,
        chat_id,
        "Slow one\n@sleep 3000\n@text E2E_CLAUDE_SLOW",
    )
    .await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    while api.conversation_calls().len() == before {
        assert!(
            tokio::time::Instant::now() < deadline,
            "the slow turn never reached the API"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    send(&owner, chat_id, "E2E_CLAUDE_STEER also this").await;
    wait_for(
        &api,
        &owner,
        chat_id,
        bot_user_id,
        "the steered reply",
        |texts| {
            texts
                .iter()
                .any(|(_, text)| text.contains("E2E_CLAUDE_SLOW"))
                && texts
                    .iter()
                    .any(|(_, text)| text.contains("FAKE-OK") && text.contains("E2E_CLAUDE_STEER"))
        },
    )
    .await;

    // 3c. /stop interrupts a running turn; its late reply never appears.
    let before = api.conversation_calls().len();
    send(
        &owner,
        chat_id,
        "Slow two\n@sleep 6000\n@text E2E_CLAUDE_NEVER",
    )
    .await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    while api.conversation_calls().len() == before {
        assert!(
            tokio::time::Instant::now() < deadline,
            "the slow turn never reached the API"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    send(&owner, chat_id, "/stop").await;
    let work_id = owner
        .get_agent_session(proto::GetAgentSessionInput {
            peer_id: Some(super::api::chat_peer(chat_id)),
            bot_user_id,
            ..Default::default()
        })
        .await
        .unwrap()
        .connection
        .and_then(|connection| connection.agent_session)
        .map(|session| session.id)
        .unwrap();
    wait_idle(&owner, chat_id, work_id).await;
    tokio::time::sleep(Duration::from_secs(7)).await;
    let texts = bot_texts(&owner, chat_id, bot_user_id).await;
    assert!(
        !texts
            .iter()
            .any(|(_, text)| text.contains("E2E_CLAUDE_NEVER")),
        "a stopped Claude turn posted its late reply: {texts:#?}"
    );

    // 4. Asking before Bash: the card carries the command, and the owner's
    // approval runs it.
    send(
        &owner,
        chat_id,
        "Run the check\n@tool Bash {\"command\": \"echo E2E_RAN > ran.txt\", \"description\": \"Write the marker\"}",
    )
    .await;
    let (card, action) = wait_card(&api, &owner, chat_id, "echo E2E_RAN", CardKind::Buttons).await;
    owner
        .invoke_rpc(
            proto::Method::InvokeMessageAction,
            proto::rpc_call::Input::InvokeMessageAction(proto::InvokeMessageActionInput {
                peer_id: Some(super::api::chat_peer(chat_id)),
                message_id: card,
                action_id: action,
                ..Default::default()
            }),
        )
        .await
        .unwrap();
    wait_for(
        &api,
        &owner,
        chat_id,
        bot_user_id,
        "the answer after approval",
        |texts| {
            texts
                .iter()
                .filter(|(_, text)| text.contains("FAKE-DONE"))
                .count()
                >= 3
        },
    )
    .await;
    assert_eq!(
        std::fs::read_to_string(folder.join("ran.txt"))
            .unwrap()
            .trim(),
        "E2E_RAN",
        "the approved command ran in the work's folder"
    );

    // 5. /release ends the process and hands the session back.
    send(&owner, chat_id, "/release").await;
    wait_for(
        &api,
        &owner,
        chat_id,
        bot_user_id,
        "the release handoff",
        |texts| {
            texts
                .iter()
                .any(|(_, text)| text.contains("claude --resume"))
        },
    )
    .await;

    // 6. The bridge restarts on the same store: a message sent while it was
    // down is caught up, and the released session resumes (`--resume`).
    let session_ref = |work: proto::GetAgentSessionResult| {
        work.connection
            .map(|connection| connection.session_ref)
            .unwrap_or_default()
    };
    let lookup = || {
        owner.get_agent_session(proto::GetAgentSessionInput {
            peer_id: Some(super::api::chat_peer(chat_id)),
            bot_user_id,
            ..Default::default()
        })
    };
    let before_restart = session_ref(lookup().await.unwrap());
    let _ = stop.send(());
    let outcome = tokio::time::timeout(Duration::from_secs(20), running).await;
    assert!(
        matches!(outcome, Ok(Ok(Ok(())))),
        "runtime ended cleanly: {outcome:?}"
    );
    bot.shutdown().await.unwrap();
    drop(bot);
    send(&owner, chat_id, "Back again\n@text E2E_CLAUDE_RESTARTED").await;
    let (stop, running, _bot) = bridge.start().await;
    wait_for(
        &api,
        &owner,
        chat_id,
        bot_user_id,
        "the answer after the restart",
        |texts| {
            texts
                .iter()
                .any(|(_, text)| text.contains("E2E_CLAUDE_RESTARTED"))
        },
    )
    .await;
    assert!(!before_restart.is_empty());
    assert_eq!(
        before_restart,
        session_ref(lookup().await.unwrap()),
        "the restarted bridge resumed the same Claude session"
    );

    let _ = stop.send(());
    let outcome = tokio::time::timeout(Duration::from_secs(20), running).await;
    assert!(
        matches!(outcome, Ok(Ok(Ok(())))),
        "runtime ended cleanly: {outcome:?}"
    );
}

/// One run of the bridge for the Claude test, over the shared ledger and the
/// bot's persisted store.
struct ClaudeBridge {
    dir: std::path::PathBuf,
    folder: std::path::PathBuf,
    config_dir: std::path::PathBuf,
    api_base_url: String,
    owner: InlineClient,
    owner_user_id: i64,
    bot_user_id: i64,
    dm_chat_id: i64,
}

impl ClaudeBridge {
    async fn start(&self) -> (tokio::sync::oneshot::Sender<()>, Running, InlineClient) {
        let executable = which("claude", "INLINE_V2_E2E_CLAUDE");
        let bot = client(&self.dir, "bot", &env("INLINE_V2_E2E_BOT_TOKEN")).await;
        let tools = Tools::new(ToolsConfig {
            bot: bot.clone(),
            provider: inline_agent_bridge::ProviderId::new("claude").unwrap(),
            bot_user_id: self.bot_user_id,
            owner_user_id: self.owner_user_id,
            agent_name: "Claude".to_owned(),
            folder: self.folder.clone(),
            attachments_dir: self.dir.join("attachments"),
        });
        let mut config = inline_agent_driver_claude::harness::ClaudeHarnessConfig::new(
            executable.clone(),
            env!("CARGO_PKG_VERSION"),
        );
        config.env = vec![
            (
                "ANTHROPIC_BASE_URL".into(),
                self.api_base_url.clone().into(),
            ),
            ("ANTHROPIC_API_KEY".into(), "sk-ant-e2e-dummy".into()),
            (
                "CLAUDE_CONFIG_DIR".into(),
                self.config_dir.clone().into_os_string(),
            ),
            ("DISABLE_AUTOUPDATER".into(), "1".into()),
            ("DISABLE_TELEMETRY".into(), "1".into()),
            (
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC".into(),
                "1".into(),
            ),
            ("DISABLE_ERROR_REPORTING".into(), "1".into()),
            // Newer Claude Code defers MCP tools behind ToolSearch; the scripted
            // model calls Inline's tools directly.
            ("ENABLE_TOOL_SEARCH".into(), "false".into()),
        ];
        config.model = Some("claude-sonnet-4-5".to_owned());
        // Ask before tools, so approvals become cards.
        config.permission_mode = "default".to_owned();
        config.host_tools = Some(tools.configuration());
        let harness: Arc<dyn HarnessDriver> = Arc::new(
            inline_agent_driver_claude::harness::ClaudeHarness::new(config),
        );
        let mut events = bot.take_lossless_events().unwrap();
        let runtime = Runtime::new(
            V2Config {
                vocabulary: Vocabulary::Claude,
                agent_name: "Claude".to_owned(),
                installation_id: "e2e-claude".to_owned(),
                owner_user_id: self.owner_user_id,
                bot_user_id: self.bot_user_id,
                bot_username: "e2e_claude_bot".to_owned(),
                dm_chat_id: self.dm_chat_id,
                folder: self.folder.clone(),
                machine_label: "e2e".to_owned(),
                executable_path: Some(executable.display().to_string()),
                accept_messages_after: 0,
                allowlist: Vec::new(),
                ledger_path: self.dir.join("ledger.sqlite"),
                attachments_dir: self.dir.join("attachments"),
            },
            bot.clone(),
            Arc::new(OwnerClient(self.owner.clone())),
            harness,
            Some(tools),
        )
        .unwrap();
        let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
        let running = tokio::spawn(async move {
            runtime
                .run(&mut events, async {
                    let _ = stopped.await;
                })
                .await
                .map_err(|error| error.to_string())
        });
        (stop, running, bot)
    }
}

/// Points Codex at the temporary home and keeps its fake-model requests off
/// any proxy (a system proxy would otherwise get 127.0.0.1 too).
///
/// # Safety
/// Call before other threads read the environment.
unsafe fn isolate_codex(codex_home: &std::path::Path) {
    unsafe {
        std::env::set_var("CODEX_HOME", codex_home);
        std::env::set_var("NO_PROXY", "127.0.0.1,localhost");
        std::env::set_var("no_proxy", "127.0.0.1,localhost");
    }
}

fn which_codex() -> std::path::PathBuf {
    which("codex", "INLINE_V2_E2E_CODEX")
}

fn which(name: &str, override_variable: &str) -> std::path::PathBuf {
    if let Ok(path) = std::env::var(override_variable) {
        return path.into();
    }
    for dir in std::env::var("PATH").unwrap_or_default().split(':') {
        let candidate = std::path::Path::new(dir).join(name);
        if candidate.is_file() {
            return candidate;
        }
    }
    panic!("{name} is not installed");
}

/// Codex and the fake model alone, without Inline: isolates model wiring.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "runs the installed Codex against a local fake model"]
async fn codex_reaches_the_fake_model() {
    use futures_util::StreamExt;
    use inline_agent_bridge::harness::{
        Delivery, Input, InputContent, InputId, OpenMode, OpenSpec, Origin, UserId,
    };
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join("project");
    std::fs::create_dir_all(&folder).unwrap();
    let (model, base_url) = FakeModel::start(vec![
        json!({"type": "function_call", "call_id": "call-tool", "namespace": "inline",
            "name": "get_current_context", "arguments": "{}"}),
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_ANSWER_ONE"}]}),
    ])
    .await;
    let codex_home = dir.path().join("codex-home");
    std::fs::create_dir_all(&codex_home).unwrap();
    std::fs::write(
        codex_home.join("config.toml"),
        format!(
            "model_provider = \"inline_e2e\"\nmodel = \"gpt-5\"\napproval_policy = \"on-request\"\n\
             sandbox_mode = \"read-only\"\nthread_unload_delay_secs = 1\n\n[model_providers.inline_e2e]\nname = \"Inline E2E\"\n\
             base_url = \"{base_url}\"\nwire_api = \"responses\"\nrequires_openai_auth = false\n\
             supports_websockets = false\n"
        ),
    )
    .unwrap();
    // SAFETY: set before Codex starts.
    unsafe { isolate_codex(&codex_home) };
    let harness = inline_agent_driver_codex::harness::CodexHarness::new(
        inline_agent_driver_codex::harness::CodexHarnessConfig {
            launch: inline_agent_driver_codex::CodexLaunchConfig {
                executable: which_codex(),
                ..Default::default()
            },
            source: ExecutableSource::Path,
            pinned_sha256: None,
            bridge_version: env!("CARGO_PKG_VERSION").to_owned(),
            cache_root: dir.path().join("cache"),
        },
    );
    // Inline's tools as Codex dynamic tools, answered by an echo.
    struct Echo;
    impl inline_agent_bridge::HostToolHandler for Echo {
        fn call<'a>(
            &'a self,
            call: inline_agent_bridge::HostToolCall,
        ) -> inline_agent_bridge::HostToolFuture<'a> {
            Box::pin(async move {
                inline_agent_bridge::HostToolResult::success(format!("echo {}", call.tool_name))
            })
        }
    }
    harness.configure_host_tools(inline_agent_bridge::HostToolConfiguration {
        specs: super::tools::specs(),
        handler: Arc::new(Echo),
    });
    let session = harness
        .open(OpenSpec {
            mode: OpenMode::Start,
            folder: folder.clone(),
            settings: Default::default(),
            instructions: None,
            title: None,
            after: None,
            output_mode: Default::default(),
        })
        .await
        .unwrap();
    let mut events = session.events();
    session
        .send(Input {
            id: InputId::new(uuid::Uuid::new_v4().to_string()).unwrap(),
            content: InputContent::text("hello"),
            origin: Origin::Owner { user: UserId(1) },
            delivery: Delivery::Turn,
        })
        .await
        .unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    while let Ok(Some(envelope)) = tokio::time::timeout_at(deadline, events.next()).await {
        eprintln!("EVENT {:?}", envelope.event);
        if matches!(
            envelope.event,
            inline_agent_bridge::harness::Event::Turn {
                phase: inline_agent_bridge::harness::TurnPhase::Completed { .. },
                ..
            }
        ) {
            break;
        }
    }
    eprintln!("MODEL SAW {:#?}", model.requests.lock().unwrap());
    assert!(model.request_count() >= 1, "the model was reached");
}

/// Two Codex threads on one app-server connection, without Inline: each gets
/// its own turn events.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "runs the installed Codex against a local fake model"]
async fn codex_two_threads_on_one_connection() {
    use inline_agent_bridge::harness::{
        Delivery, Input, InputContent, InputId, OpenMode, OpenSpec, Origin, UserId,
    };
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join("project");
    std::fs::create_dir_all(&folder).unwrap();
    let (model, base_url) = FakeModel::start(vec![
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "ANSWER_A"}]}),
        // A's second turn is interrupted while its reply is held back.
        json!({"_delay_ms": 6000, "type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "ANSWER_A_LATE"}]}),
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "ANSWER_B"}]}),
    ])
    .await;
    let codex_home = dir.path().join("codex-home");
    std::fs::create_dir_all(&codex_home).unwrap();
    std::fs::write(
        codex_home.join("config.toml"),
        format!(
            "model_provider = \"inline_e2e\"\nmodel = \"gpt-5\"\napproval_policy = \"on-request\"\n\
             sandbox_mode = \"read-only\"\n\n[model_providers.inline_e2e]\nname = \"Inline E2E\"\n\
             base_url = \"{base_url}\"\nwire_api = \"responses\"\nrequires_openai_auth = false\n\
             supports_websockets = false\n"
        ),
    )
    .unwrap();
    // SAFETY: set before Codex starts.
    unsafe { isolate_codex(&codex_home) };
    let harness = inline_agent_driver_codex::harness::CodexHarness::new(
        inline_agent_driver_codex::harness::CodexHarnessConfig {
            launch: inline_agent_driver_codex::CodexLaunchConfig {
                executable: which_codex(),
                ..Default::default()
            },
            source: ExecutableSource::Path,
            pinned_sha256: None,
            bridge_version: env!("CARGO_PKG_VERSION").to_owned(),
            cache_root: dir.path().join("cache"),
        },
    );
    let spec = || OpenSpec {
        mode: OpenMode::Start,
        folder: folder.clone(),
        settings: Default::default(),
        instructions: None,
        title: None,
        after: None,
        output_mode: Default::default(),
    };
    let input = |text: &str| Input {
        id: InputId::new(uuid::Uuid::new_v4().to_string()).unwrap(),
        content: InputContent::text(text),
        origin: Origin::Owner { user: UserId(1) },
        delivery: Delivery::Turn,
    };
    let a = harness.open(spec()).await.unwrap();
    let mut a_events = a.events();
    tokio::time::timeout(Duration::from_secs(30), a.send(input("first")))
        .await
        .expect("turn/start A answered")
        .unwrap();
    assert!(
        turn_completed(&mut a_events).await,
        "thread A completed its turn"
    );
    // A's next turn waits on the model; interrupt it, then start B.
    a.send(input("slow")).await.unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    while model.request_count() < 2 {
        assert!(
            tokio::time::Instant::now() < deadline,
            "A's slow turn never reached the model"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    a.control(inline_agent_bridge::harness::Op::Interrupt {
        cancel_queued: false,
    })
    .await
    .unwrap();
    assert!(
        turn_completed(&mut a_events).await,
        "A's interrupted turn ended"
    );
    let b = harness.open(spec()).await.unwrap();
    let mut b_events = b.events();
    tokio::time::timeout(Duration::from_secs(30), b.send(input("second")))
        .await
        .expect("turn/start B answered while A is open")
        .unwrap();
    assert!(
        turn_completed(&mut b_events).await,
        "thread B completed its turn"
    );
}

async fn turn_completed(events: &mut inline_agent_bridge::harness::EventStream) -> bool {
    use futures_util::StreamExt;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    while let Ok(Some(envelope)) = tokio::time::timeout_at(deadline, events.next()).await {
        if matches!(
            envelope.event,
            inline_agent_bridge::harness::Event::Turn {
                phase: inline_agent_bridge::harness::TurnPhase::Completed { .. },
                ..
            }
        ) {
            return true;
        }
    }
    false
}
