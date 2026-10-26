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
    AuthCredential, AuthToken, ClientIdentity, ConnectRequest, HistoryRequest, InlineClient,
    InlineId, MessageContent, PeerRef, SdkBackend, SendTextRequest, SqliteStore,
};
use inline_protocol::proto;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

use super::render::Vocabulary;
use super::runtime::{Runtime, V2Config};
use super::work::OwnerCalls;

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
                "tools": body.get("tools").and_then(Value::as_array).map(Vec::len),
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

async fn wait_for(
    model: &FakeModel,
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
            "timed out waiting for {what}; bot said: {texts:#?}; model saw: {:#?}",
            model.requests.lock().unwrap()
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
        .parse_filters("inline::bridge::v2=debug,inline_agent_driver_codex=debug")
        .try_init();
    let bot_user_id: i64 = env("INLINE_V2_E2E_BOT_USER_ID").parse().unwrap();
    let owner_user_id: i64 = env("INLINE_V2_E2E_OWNER_USER_ID").parse().unwrap();
    let chat_id: i64 = env("INLINE_V2_E2E_DM_CHAT_ID").parse().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join("project");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join("README.md"), "e2e project\n").unwrap();

    // Turn 1 answers directly. Turn 2 runs a command that needs approval,
    // then answers.
    let (model, base_url) = FakeModel::start(vec![
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_ANSWER_ONE"}]}),
        // Escalation makes Codex ask for approval before running it.
        json!({"type": "function_call", "call_id": "call-1", "name": "exec_command",
            "arguments": json!({"cmd": "echo E2E_RAN > ran.txt",
                "sandbox_permissions": "require_escalated",
                "justification": "Write the e2e marker",
                "workdir": folder.display().to_string()}).to_string()}),
        json!({"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "E2E_ANSWER_TWO"}]}),
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

    let executable = which_codex();
    let harness: Arc<dyn HarnessDriver> =
        Arc::new(inline_agent_driver_codex::harness::CodexHarness::new(
            inline_agent_driver_codex::harness::CodexHarnessConfig {
                launch: inline_agent_driver_codex::CodexLaunchConfig {
                    executable: executable.clone(),
                    ..Default::default()
                },
                source: ExecutableSource::Path,
                pinned_sha256: None,
                bridge_version: env!("CARGO_PKG_VERSION").to_owned(),
                cache_root: dir.path().join("cache"),
            },
        ));

    let owner = client(dir.path(), "owner", &env("INLINE_V2_E2E_OWNER_TOKEN")).await;
    let bot = client(dir.path(), "bot", &env("INLINE_V2_E2E_BOT_TOKEN")).await;
    let mut events = bot.take_lossless_events().unwrap();
    let runtime = Runtime::new(
        V2Config {
            vocabulary: Vocabulary::Codex,
            agent_name: "Codex".to_owned(),
            installation_id: "e2e-installation".to_owned(),
            owner_user_id,
            bot_user_id,
            bot_username: "e2e_codex_bot".to_owned(),
            dm_chat_id: chat_id,
            folder: folder.clone(),
            machine_label: "e2e".to_owned(),
            executable_path: Some(executable.display().to_string()),
            accept_messages_after: 0,
            allowlist: Vec::new(),
            ledger_path: dir.path().join("ledger.sqlite"),
            attachments_dir: dir.path().join("attachments"),
        },
        bot.clone(),
        Arc::new(OwnerClient(owner.clone())),
        harness,
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

    // 2. A command needs approval: the card carries Codex's own choices, and
    // the owner's approval runs it.
    send(&owner, chat_id, "Run the check").await;
    let texts = wait_for(
        &model,
        &owner,
        chat_id,
        bot_user_id,
        "the approval card",
        |texts| texts.iter().any(|(_, text)| text.contains("echo E2E_RAN")),
    )
    .await;
    let card = texts
        .iter()
        .rev()
        .find(|(_, text)| text.contains("echo E2E_RAN"))
        .map(|(id, _)| *id)
        .unwrap();
    let action = approve_action(&owner, chat_id, card).await;
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
            break;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "run state never settled to idle"
        );
        tokio::time::sleep(Duration::from_millis(500)).await;
    }

    // 3. /release hands the session back with a resume command.
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

    let _ = stop.send(());
    let outcome = tokio::time::timeout(Duration::from_secs(20), running).await;
    assert!(
        matches!(outcome, Ok(Ok(Ok(())))),
        "runtime ended cleanly: {outcome:?}"
    );
}

/// The first approval button on a card.
async fn approve_action(owner: &InlineClient, chat_id: i64, message_id: i64) -> String {
    let page = owner
        .history(HistoryRequest {
            chat_id: InlineId::new(chat_id),
            limit: Some(100),
            before_message_id: None,
            after_message_id: None,
        })
        .await
        .unwrap();
    let message = page
        .messages
        .into_iter()
        .find(|message| message.message_id.get() == message_id)
        .expect("card");
    message
        .metadata
        .actions
        .first()
        .map(|action| action.action_id.clone())
        .expect("the card has decision buttons")
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
    if let Ok(path) = std::env::var("INLINE_V2_E2E_CODEX") {
        return path.into();
    }
    for dir in std::env::var("PATH").unwrap_or_default().split(':') {
        let candidate = std::path::Path::new(dir).join("codex");
        if candidate.is_file() {
            return candidate;
        }
    }
    panic!("codex is not installed");
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
    let (model, base_url) = FakeModel::start(vec![json!({"type": "message", "role": "assistant",
        "content": [{"type": "output_text", "text": "E2E_ANSWER_ONE"}]})])
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
