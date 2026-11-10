//! The native driver against an in-process fake of the OpenCode service
//! API: HTTP routes, the SSE event stream, and a client-MCP WebSocket that
//! calls Inline's tools the way OpenCode does.

use std::convert::Infallible;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::Router;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::sse::{Event as SseEvent, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, put};
use futures_util::{SinkExt, StreamExt};
use inline_agent_bridge::harness::*;
use inline_agent_bridge::{
    HostToolCall, HostToolConfiguration, HostToolFuture, HostToolHandler, HostToolResult,
    HostToolSpec, ProviderSessionId, TurnOutcome,
};
use inline_agent_driver_opencode::api::Api;
use inline_agent_driver_opencode::link::Link;
use inline_agent_driver_opencode::service::{Endpoint, ServerInfo, ServiceConfig};
use inline_agent_driver_opencode::{OpenCodeHarness, OpenCodeHarnessConfig};
use serde_json::{Value, json};
use tokio::sync::{broadcast, mpsc};

const SESSION: &str = "ses_fake";

#[derive(Clone)]
struct Fake {
    events: broadcast::Sender<Value>,
    seq: Arc<Mutex<u64>>,
    requests: Arc<Mutex<Vec<(String, Value)>>>,
    tool_results: mpsc::UnboundedSender<Value>,
    folder: String,
}

impl Fake {
    fn record(&self, route: &str, body: Value) {
        self.requests.lock().unwrap().push((route.to_owned(), body));
    }

    fn durable(&self, kind: &str, data: Value) {
        let mut seq = self.seq.lock().unwrap();
        *seq += 1;
        let mut data = data;
        data["sessionID"] = json!(SESSION);
        let _ = self.events.send(json!({
            "id": format!("evt_{}", *seq), "created": 1_700_000_000_000u64 + *seq,
            "type": kind, "durable": {"aggregateID": SESSION, "seq": *seq, "version": 1}, "data": data,
        }));
    }

    fn volatile(&self, kind: &str, data: Value) {
        let mut data = data;
        if data.get("sessionID").is_none() && data.get("form").is_none() {
            data["sessionID"] = json!(SESSION);
        }
        let _ = self
            .events
            .send(json!({"id": "evt_v", "created": 1, "type": kind, "data": data}));
    }

    fn info(&self) -> Value {
        json!({"id": SESSION, "projectID": "p", "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
               "time": {"created": 1, "updated": 2}, "location": {"directory": self.folder}, "title": "Fake"})
    }
}

async fn info() -> axum::Json<Value> {
    axum::Json(
        json!({"version": "2.2.5", "pid": std::process::id(), "urls": [], "paths": {"tmp": "/tmp"}}),
    )
}

async fn event_stream(
    State(fake): State<Fake>,
) -> Sse<impl futures_util::Stream<Item = Result<SseEvent, Infallible>>> {
    let receiver = fake.events.subscribe();
    let connected = futures_util::stream::once(async {
        Ok(SseEvent::default()
            .data(json!({"id": "c", "type": "server.connected", "data": {}}).to_string()))
    });
    let rest =
        tokio_stream_from(receiver).map(|event| Ok(SseEvent::default().data(event.to_string())));
    Sse::new(connected.chain(rest))
}

fn tokio_stream_from(
    receiver: broadcast::Receiver<Value>,
) -> impl futures_util::Stream<Item = Value> {
    futures_util::stream::unfold(receiver, |mut receiver| async move {
        loop {
            match receiver.recv().await {
                Ok(value) => return Some((value, receiver)),
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => return None,
            }
        }
    })
}

async fn create_session(
    State(fake): State<Fake>,
    axum::Json(body): axum::Json<Value>,
) -> axum::Json<Value> {
    fake.record("create", body);
    axum::Json(json!({"data": fake.info()}))
}

async fn get_session(State(fake): State<Fake>, Path(id): Path<String>) -> Response {
    if id != SESSION {
        return (StatusCode::NOT_FOUND, axum::Json(json!({"_tag": "SessionNotFoundError", "sessionID": id, "message": "Session not found"}))).into_response();
    }
    axum::Json(json!({"data": fake.info()})).into_response()
}

async fn list_sessions(
    State(fake): State<Fake>,
    Query(query): Query<Vec<(String, String)>>,
) -> axum::Json<Value> {
    if query
        .iter()
        .any(|(key, value)| key == "parentID" && value == SESSION)
    {
        return axum::Json(json!({"data": [], "cursor": {}}));
    }
    axum::Json(json!({"data": [fake.info()], "cursor": {"next": "c2"}}))
}

async fn empty_data() -> axum::Json<Value> {
    axum::Json(json!({"data": []}))
}

async fn empty_object() -> axum::Json<Value> {
    axum::Json(json!({"data": {}}))
}

async fn models(State(fake): State<Fake>) -> axum::Json<Value> {
    axum::Json(json!({"location": {"directory": fake.folder}, "data": [
        {"id": "sonnet", "modelID": "claude-sonnet", "providerID": "anthropic", "name": "Sonnet", "enabled": true, "status": "active",
         "capabilities": {"tools": true, "input": [], "output": []}, "variants": [{"id": "high"}], "time": {"released": 1}, "cost": [],
         "limit": {"context": 200000, "output": 8000}}
    ]}))
}

async fn default_model() -> axum::Json<Value> {
    axum::Json(
        json!({"location": {"directory": "/"}, "data": {"id": "sonnet", "providerID": "anthropic"}}),
    )
}

async fn agents() -> axum::Json<Value> {
    axum::Json(json!({"location": {"directory": "/"}, "data": [
        {"id": "build", "name": "build", "mode": "primary", "hidden": false, "permissions": [], "request": {}},
        {"id": "plan", "name": "plan", "mode": "primary", "hidden": false, "permissions": [], "request": {}},
        {"id": "explore", "name": "explore", "mode": "subagent", "hidden": false, "permissions": [], "request": {}}
    ]}))
}

async fn commands() -> axum::Json<Value> {
    axum::Json(
        json!({"location": {"directory": "/"}, "data": [{"name": "init", "description": "Create AGENTS.md"}]}),
    )
}

async fn put_entry(
    State(fake): State<Fake>,
    Path((_, key)): Path<(String, String)>,
    axum::Json(body): axum::Json<Value>,
) -> StatusCode {
    fake.record(&format!("instructions:{key}"), body);
    StatusCode::NO_CONTENT
}

async fn prompt(
    State(fake): State<Fake>,
    axum::Json(body): axum::Json<Value>,
) -> axum::Json<Value> {
    fake.record("prompt", body.clone());
    let id = body["id"].as_str().unwrap().to_owned();
    let delivery = body["delivery"].as_str().unwrap_or("steer").to_owned();
    let response = json!({"data": {"id": id, "sessionID": SESSION, "time": {"created": 1}, "type": "user",
        "payload": {"text": body["text"], "metadata": body["metadata"]}, "delivery": delivery}});
    let fake = fake.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(20)).await;
        fake.durable("session.inbox.enqueued", json!({"inboxID": id, "item": {"type": "user", "delivery": delivery, "payload": {"text": body["text"], "metadata": body["metadata"]}}}));
        fake.durable("session.execution.started", json!({}));
        fake.durable("session.inbox.delivered", json!({"inboxID": id}));
        fake.durable("session.step.started", json!({"assistantMessageID": "msg_a1", "agent": "build", "model": {"providerID": "anthropic", "id": "sonnet"}}));
        fake.durable(
            "session.text.started",
            json!({"assistantMessageID": "msg_a1", "ordinal": 0}),
        );
        fake.volatile(
            "session.text.delta",
            json!({"assistantMessageID": "msg_a1", "ordinal": 0, "delta": "Running"}),
        );
        fake.durable(
            "session.text.ended",
            json!({"assistantMessageID": "msg_a1", "ordinal": 0, "text": "Running the tests."}),
        );
        fake.durable(
            "session.tool.input.started",
            json!({"assistantMessageID": "msg_a1", "id": "call_1", "name": "shell"}),
        );
        fake.durable("session.tool.called", json!({"assistantMessageID": "msg_a1", "id": "call_1", "input": {"command": "cargo test"}, "executed": true}));
        fake.volatile("permission.asked", json!({"id": "per_1", "action": "shell", "resources": ["cargo test"], "save": ["cargo test *"],
            "source": {"type": "tool", "messageID": "msg_a1", "id": "call_1"}}));
    });
    axum::Json(response)
}

async fn permission_reply(
    State(fake): State<Fake>,
    Path((_, request)): Path<(String, String)>,
    axum::Json(body): axum::Json<Value>,
) -> StatusCode {
    fake.record(&format!("reply:{request}"), body);
    let fake = fake.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(20)).await;
        fake.volatile(
            "permission.replied",
            json!({"requestID": "per_1", "reply": "once"}),
        );
        fake.durable("session.tool.success", json!({"assistantMessageID": "msg_a1", "id": "call_1",
            "content": [{"type": "text", "text": "test result: ok"}], "metadata": {"exit": 0}, "executed": true}));
        fake.durable("session.step.ended", json!({"assistantMessageID": "msg_a1", "finish": "stop", "cost": 0.0,
            "tokens": {"input": 10, "output": 5, "reasoning": 0, "cache": {"read": 0, "write": 0}}}));
        fake.durable("session.execution.succeeded", json!({}));
    });
    StatusCode::NO_CONTENT
}

async fn command(State(fake): State<Fake>, axum::Json(body): axum::Json<Value>) -> StatusCode {
    fake.record("command", body.clone());
    let fake = fake.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(20)).await;
        // OpenCode prompts with an id of its own and no Inline metadata.
        fake.durable("session.inbox.enqueued", json!({"inboxID": "msg_cmd1", "item": {"type": "user", "delivery": "steer",
            "payload": {"text": format!("Create AGENTS.md {}", body["text"].as_str().unwrap_or(""))}}}));
        fake.durable("session.execution.started", json!({}));
        fake.durable("session.inbox.delivered", json!({"inboxID": "msg_cmd1"}));
        fake.durable("session.execution.succeeded", json!({}));
    });
    StatusCode::NO_CONTENT
}

async fn synthetic(
    State(fake): State<Fake>,
    axum::Json(body): axum::Json<Value>,
) -> axum::Json<Value> {
    fake.record("synthetic", body.clone());
    axum::Json(json!({"data": {"id": body["id"], "type": "synthetic"}}))
}

async fn generate(axum::Json(body): axum::Json<Value>) -> axum::Json<Value> {
    axum::Json(
        json!({"data": {"text": format!("sampled: {}", body["prompt"].as_str().unwrap_or(""))}}),
    )
}

async fn client_mcp(
    State(fake): State<Fake>,
    Query(query): Query<Vec<(String, String)>>,
    upgrade: WebSocketUpgrade,
) -> Response {
    assert!(
        query
            .iter()
            .any(|(key, value)| key == "name" && value == "inline")
    );
    assert!(query.iter().any(|(key, _)| key == "location[directory]"));
    upgrade.on_upgrade(move |socket| mcp_client(socket, fake))
}

/// Plays OpenCode's side: the MCP client.
async fn mcp_client(socket: WebSocket, fake: Fake) {
    let (mut sink, mut stream) = socket.split();
    let call = |id: u64, method: &str, params: Value| {
        json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}).to_string()
    };
    let requests = vec![
        call(
            1,
            "initialize",
            json!({"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "opencode"}}),
        ),
        call(2, "tools/list", json!({})),
        call(
            3,
            "tools/call",
            json!({"name": "send_message", "arguments": {"text": "hi"}, "_meta": {"ai.opencode/sessionID": SESSION}}),
        ),
        call(
            4,
            "tools/call",
            json!({"name": "send_message", "arguments": {"text": "hi"}, "_meta": {"ai.opencode/sessionID": "ses_tui"}}),
        ),
    ];
    for request in requests {
        if sink.send(Message::Text(request.into())).await.is_err() {
            return;
        }
        if let Some(Ok(Message::Text(reply))) = stream.next().await {
            let _ = fake
                .tool_results
                .send(serde_json::from_str(&reply).unwrap());
        }
    }
    // Stay connected like OpenCode.
    while let Some(Ok(_)) = stream.next().await {}
}

struct Echo;

impl HostToolHandler for Echo {
    fn call<'a>(&'a self, call: HostToolCall) -> HostToolFuture<'a> {
        Box::pin(async move {
            HostToolResult::success(format!(
                "sent from {} ({})",
                call.session_id.as_str(),
                call.tool_name
            ))
        })
    }
}

async fn serve(folder: &std::path::Path) -> (Fake, url::Url, mpsc::UnboundedReceiver<Value>) {
    let (events, _) = broadcast::channel(1024);
    let (tool_results, tool_receiver) = mpsc::unbounded_channel();
    let fake = Fake {
        events,
        seq: Arc::new(Mutex::new(0)),
        requests: Arc::new(Mutex::new(Vec::new())),
        tool_results,
        folder: folder.display().to_string(),
    };
    let app = Router::new()
        .route("/api/info", get(info))
        .route("/api/event", get(event_stream))
        .route("/api/session", post(create_session).get(list_sessions))
        .route("/api/session/active", get(empty_object))
        .route("/api/session/{id}", get(get_session))
        .route("/api/session/{id}/inbox", get(empty_data))
        .route("/api/session/{id}/message", get(empty_data))
        .route("/api/session/{id}/permission", get(empty_data))
        .route("/api/session/{id}/form", get(empty_data))
        .route("/api/session/{id}/prompt", post(prompt))
        .route("/api/session/{id}/synthetic", post(synthetic))
        .route("/api/session/{id}/generate", post(generate))
        .route("/api/session/{id}/command", post(command))
        .route(
            "/api/session/{id}/permission/{request}/reply",
            post(permission_reply),
        )
        .route(
            "/api/experimental/session/{id}/instructions/entries/{key}",
            put(put_entry),
        )
        .route("/api/experimental/client-mcp", get(client_mcp))
        .route("/api/model", get(models))
        .route("/api/model/default", get(default_model))
        .route("/api/agent", get(agents))
        .route("/api/command", get(commands))
        .route("/api/skill", get(empty_data))
        .route("/api/project", get(empty_data))
        .with_state(fake.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (
        fake,
        url::Url::parse(&format!("http://{address}/")).unwrap(),
        tool_receiver,
    )
}

async fn next_matching(
    events: &mut EventStream,
    mut predicate: impl FnMut(&Event) -> bool,
) -> Event {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let envelope = events.next().await.expect("stream open");
            if predicate(&envelope.event) {
                return envelope.event;
            }
        }
    })
    .await
    .expect("event in time")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_turn_runs_end_to_end_with_approval_tools_and_catalog() {
    let folder = tempfile::tempdir().unwrap();
    let (fake, url, mut tool_results) = serve(folder.path()).await;
    let api = Api::new(Endpoint::open(url)).unwrap();
    let link = Link::fixed(
        api,
        ServerInfo {
            version: "2.2.5".into(),
            pid: std::process::id(),
        },
        ServiceConfig::new("/nonexistent/opencode"),
    );
    let mut config = OpenCodeHarnessConfig::new("/nonexistent/opencode", "test");
    config.host_tools = Some(HostToolConfiguration {
        specs: vec![HostToolSpec {
            name: "send_message".into(),
            description: "Send a message to the Inline thread".into(),
            input_schema: json!({"type": "object", "properties": {"text": {"type": "string"}}}),
            read_only: false,
        }],
        handler: Arc::new(Echo),
    });
    let harness = OpenCodeHarness::with_link(config, link).await.unwrap();
    assert_eq!(harness.describe().health, RuntimeHealth::Ready);

    let catalog = harness
        .catalog(CatalogScope {
            folder: Some(folder.path().to_path_buf()),
            session: None,
        })
        .await
        .unwrap();
    assert_eq!(catalog.models[0].value, "anthropic/sonnet");
    assert!(catalog.models[0].is_default);
    assert_eq!(catalog.models[0].reasoning[0].value, "high");
    assert_eq!(catalog.modes.len(), 2);
    assert_eq!(catalog.commands[0].name, "init");

    let page = harness.sessions(SessionQuery::default()).await.unwrap();
    assert_eq!(page.sessions[0].key.session.as_str(), SESSION);
    assert_eq!(page.next.as_ref().unwrap().as_str(), "c2");

    let session = harness
        .open(OpenSpec {
            mode: OpenMode::Start,
            folder: folder.path().to_path_buf(),
            settings: SettingsChange {
                model: Some("anthropic/sonnet".into()),
                effort: Some("high".into()),
                permission_mode: Some("ask".into()),
                ..Default::default()
            },
            instructions: Some("You are Inline's agent.".into()),
            title: None,
            after: None,
            output_mode: OutputMode::Detailed,
        })
        .await
        .unwrap();
    let mut events = session.events();
    {
        let requests = fake.requests.lock().unwrap();
        let create = &requests
            .iter()
            .find(|(route, _)| route == "create")
            .unwrap()
            .1;
        assert_eq!(
            create["model"],
            json!({"providerID": "anthropic", "id": "sonnet", "variant": "high"})
        );
        assert_eq!(create["permissions"][0]["effect"], "ask");
        assert_eq!(
            create["location"]["directory"],
            json!(folder.path().display().to_string())
        );
        let guide = &requests
            .iter()
            .find(|(route, _)| route == "instructions:inline")
            .unwrap()
            .1;
        assert!(guide["value"].as_str().unwrap().starts_with(
            "You are Inline's agent.\n\nIn OpenCode, Inline's tools are the `inline` MCP tools"
        ));
    }

    // Inline's tools are served over client MCP, bound to held sessions only.
    let mut replies = Vec::new();
    for _ in 0..4 {
        replies.push(
            tokio::time::timeout(Duration::from_secs(5), tool_results.recv())
                .await
                .unwrap()
                .unwrap(),
        );
    }
    assert_eq!(replies[0]["result"]["serverInfo"]["name"], "inline");
    assert_eq!(replies[1]["result"]["tools"][0]["name"], "send_message");
    assert_eq!(replies[2]["result"]["isError"], false);
    assert_eq!(
        replies[2]["result"]["content"][0]["text"],
        format!("sent from {SESSION} (send_message)")
    );
    assert_eq!(replies[3]["result"]["isError"], true);

    // A turn: the receipt names the turn, and the stream starts it with that id.
    let receipt = session
        .send(Input {
            id: InputId::new("in-1").unwrap(),
            content: InputContent::text("run the tests"),
            origin: Origin::Owner { user: UserId(1) },
            delivery: Delivery::Turn,
        })
        .await
        .unwrap();
    let InputDisposition::Started { turn } = receipt.disposition.clone() else {
        panic!("{receipt:?}");
    };
    assert!(turn.as_str().starts_with("msg_"));
    {
        let requests = fake.requests.lock().unwrap();
        let prompt = &requests
            .iter()
            .find(|(route, _)| route == "prompt")
            .unwrap()
            .1;
        assert_eq!(prompt["id"], json!(turn.as_str()));
        assert_eq!(prompt["metadata"]["inline.input"], "in-1");
        assert_eq!(prompt["delivery"], "steer");
    }
    let started = next_matching(&mut events, |event| {
        matches!(
            event,
            Event::Turn {
                phase: TurnPhase::Started { .. },
                ..
            }
        )
    })
    .await;
    assert!(matches!(started, Event::Turn { turn: started, .. } if started == turn));
    next_matching(&mut events, |event| {
        matches!(
            event,
            Event::Input {
                fact: InputFact::Consumed { .. },
                ..
            }
        )
    })
    .await;
    let text = next_matching(&mut events, |event| {
        matches!(
            event,
            Event::Item(Item {
                update: ItemUpdate::Completed {
                    body: ItemBody::Message {
                        role: MessageRole::Assistant,
                        ..
                    },
                    ..
                },
                ..
            })
        )
    })
    .await;
    assert!(
        matches!(text, Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Message { text, .. }, .. }, .. }) if text == "Running the tests.")
    );

    // A busy session refuses a second turn but takes a steer.
    assert!(matches!(
        session
            .send(Input {
                id: InputId::new("in-2").unwrap(),
                content: InputContent::text("again"),
                origin: Origin::Owner { user: UserId(1) },
                delivery: Delivery::Turn,
            })
            .await,
        Err(SendError::Busy { .. })
    ));

    let approval = next_matching(&mut events, |event| matches!(event, Event::Interaction(_))).await;
    let Event::Interaction(interaction) = approval else {
        unreachable!()
    };
    assert!(
        matches!(&interaction.kind, InteractionKind::Approval { subject: ApprovalSubject::Command { command, .. }, .. } if command == "cargo test")
    );
    assert_eq!(session.live_work().interactions.len(), 1);
    session
        .control(Op::Answer {
            interaction: interaction.id.clone(),
            response: InteractionResponse::Decision {
                decision: DecisionId::new("once").unwrap(),
                message: None,
            },
            by: UserId(1),
        })
        .await
        .unwrap();
    let closed = next_matching(&mut events, |event| {
        matches!(event, Event::InteractionClosed { .. })
    })
    .await;
    assert!(matches!(
        closed,
        Event::InteractionClosed {
            by: ClosedBy::Inline { .. },
            ..
        }
    ));
    {
        let requests = fake.requests.lock().unwrap();
        let reply = &requests
            .iter()
            .find(|(route, _)| route == "reply:per_1")
            .unwrap()
            .1;
        assert_eq!(reply["decision"], "once");
    }
    let command = next_matching(&mut events, |event| {
        matches!(
            event,
            Event::Item(Item {
                update: ItemUpdate::Completed {
                    body: ItemBody::Command { .. },
                    ..
                },
                ..
            })
        )
    })
    .await;
    assert!(
        matches!(command, Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Command { output: Some(output), exit_code: Some(0), .. }, .. }, .. }) if output == "test result: ok")
    );
    let completed = next_matching(&mut events, |event| {
        matches!(
            event,
            Event::Turn {
                phase: TurnPhase::Completed { .. },
                ..
            }
        )
    })
    .await;
    assert!(matches!(
        completed,
        Event::Turn { phase: TurnPhase::Completed { outcome: TurnOutcome::Completed, inputs_consumed, .. }, .. } if inputs_consumed == vec![InputId::new("in-1").unwrap()]
    ));
    assert!(session.live_work().is_idle());

    // An advertised OpenCode command runs through the command API and is
    // correlated with the prompt OpenCode makes of it.
    let receipt = session
        .send(Input {
            id: InputId::new("in-cmd").unwrap(),
            content: InputContent::text("/init for the CLI"),
            origin: Origin::Teammate { user: UserId(42) },
            delivery: Delivery::Turn,
        })
        .await
        .unwrap();
    assert!(
        matches!(&receipt.disposition, InputDisposition::Started { turn } if turn.as_str() == "msg_cmd1"),
        "{receipt:?}"
    );
    {
        let requests = fake.requests.lock().unwrap();
        let command = &requests
            .iter()
            .find(|(route, _)| route == "command")
            .unwrap()
            .1;
        assert_eq!(command["name"], "init");
        assert_eq!(command["text"], "for the CLI");
        let context_index = requests
            .iter()
            .position(|(route, _)| route == "synthetic")
            .unwrap();
        let command_index = requests
            .iter()
            .position(|(route, _)| route == "command")
            .unwrap();
        assert!(context_index < command_index);
        let context = &requests[context_index].1;
        assert_eq!(context["resume"], false);
        let text = context["text"].as_str().unwrap();
        assert!(text.contains("Inline user 42 (a teammate, not the owner)"));
        assert!(
            !text.contains("for the CLI"),
            "command arguments are not copied into context"
        );
        assert_eq!(
            requests
                .iter()
                .filter(|(route, _)| route == "prompt")
                .count(),
            1
        );
    }
    let consumed = next_matching(&mut events, |event| {
        matches!(event, Event::Turn { phase: TurnPhase::Completed { .. }, turn } if turn.as_str() == "msg_cmd1")
    })
    .await;
    assert!(matches!(
        consumed,
        Event::Turn { phase: TurnPhase::Completed { inputs_consumed, .. }, .. } if inputs_consumed == vec![InputId::new("in-cmd").unwrap()]
    ));

    // Side calls leave no trace in the session.
    let sampled = session
        .control(Op::Sample {
            prompt: "summarize".into(),
        })
        .await
        .unwrap();
    assert_eq!(
        sampled,
        OpOutcome::Sampled {
            text: "sampled: summarize".into()
        }
    );

    // Unknown sessions are reported as missing, not as failures.
    let missing = harness
        .open(OpenSpec {
            mode: OpenMode::Resume {
                session: ProviderSessionId::new("ses_gone").unwrap(),
            },
            folder: folder.path().to_path_buf(),
            settings: SettingsChange::default(),
            instructions: None,
            title: None,
            after: None,
            output_mode: OutputMode::Detailed,
        })
        .await;
    assert!(matches!(missing, Err(OpenError::NotFound)));

    let released = session.release().await.unwrap();
    assert_eq!(released.outcome, ReleaseOutcome::NativeReleased);
    harness.shutdown().await;
}
