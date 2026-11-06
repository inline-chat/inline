//! The paths a single happy turn never reaches, against a scripted fake of
//! the OpenCode service: discovery and auth, a still-starting service,
//! resuming mid-run, stream loss and log replay, send failures, queue and
//! interrupt edge cases, passive input and fork points.

use std::collections::HashMap;
use std::convert::Infallible;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::Router;
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::sse::{Event as SseEvent, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post, put};
use futures_util::StreamExt;
use inline_agent_bridge::harness::*;
use inline_agent_bridge::{ProviderSessionId, TurnId, TurnOutcome};
use inline_agent_driver_opencode::api::Api;
use inline_agent_driver_opencode::link::Link;
use inline_agent_driver_opencode::service::{self, Endpoint, ServerInfo, ServiceConfig};
use inline_agent_driver_opencode::{OpenCodeHarness, OpenCodeHarnessConfig};
use serde_json::{Value, json};
use tokio::sync::{broadcast, watch};

const SESSION: &str = "ses_main";
const PASSWORD: &str = "s3cret";

#[derive(Default)]
struct Script {
    /// Durable events per session, in order.
    log: HashMap<String, Vec<Value>>,
    seq: u64,
    active: Vec<String>,
    inbox: Vec<Value>,
    permissions: Vec<Value>,
    user_messages: Vec<String>,
    all_messages: Vec<Value>,
    requests: Vec<(String, Value)>,
    /// `/api/info` answers 503 this many more times.
    starting: u32,
    prompt_status: Option<u16>,
    interrupted: bool,
    /// `/api/command` lists nothing this many more times (a cold folder).
    cold_commands: u32,
}

#[derive(Clone)]
struct Fake {
    script: Arc<Mutex<Script>>,
    events: broadcast::Sender<Value>,
    /// Bumping it ends every open event stream.
    cut: watch::Sender<u64>,
    folder: String,
    pid: u32,
}

impl Fake {
    fn script(&self) -> std::sync::MutexGuard<'_, Script> {
        self.script.lock().unwrap()
    }

    /// A durable event: logged, and streamed when `live`.
    fn durable(&self, session: &str, kind: &str, data: Value, live: bool) -> u64 {
        let event = {
            let mut script = self.script();
            script.seq += 1;
            let seq = script.seq;
            let mut data = data;
            data["sessionID"] = json!(session);
            let event = json!({"id": format!("evt_{seq}"), "created": 1_700_000_000_000u64 + seq,
                "type": kind, "durable": {"aggregateID": session, "seq": seq, "version": 1}, "data": data});
            script
                .log
                .entry(session.to_owned())
                .or_default()
                .push(event.clone());
            event
        };
        let seq = event["durable"]["seq"].as_u64().unwrap();
        if live {
            let _ = self.events.send(event);
        }
        seq
    }

    fn requests(&self, route: &str) -> Vec<Value> {
        self.script()
            .requests
            .iter()
            .filter(|(name, _)| name == route)
            .map(|(_, body)| body.clone())
            .collect()
    }

    fn session_info(&self, id: &str) -> Value {
        json!({"id": id, "projectID": "p", "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
               "time": {"created": 1, "updated": 2}, "location": {"directory": self.folder},
               "model": {"providerID": "anthropic", "id": "sonnet", "variant": "high"}, "agent": "build"})
    }
}

fn authorized(headers: &HeaderMap) -> bool {
    use base64::Engine;
    let expected = format!(
        "Basic {}",
        base64::engine::general_purpose::STANDARD.encode(format!("opencode:{PASSWORD}"))
    );
    headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        == Some(expected.as_str())
}

async fn info(State(fake): State<Fake>, headers: HeaderMap) -> Response {
    if !authorized(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let body = json!({"version": "2.2.5", "pid": fake.pid, "urls": [], "paths": {"tmp": "/tmp"}});
    let mut script = fake.script();
    if script.starting > 0 {
        script.starting -= 1;
        return (StatusCode::SERVICE_UNAVAILABLE, axum::Json(body)).into_response();
    }
    axum::Json(body).into_response()
}

async fn event_stream(State(fake): State<Fake>, headers: HeaderMap) -> Response {
    if !authorized(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let mut cut = fake.cut.subscribe();
    let start = *cut.borrow_and_update();
    let receiver = fake.events.subscribe();
    let connected = futures_util::stream::once(async {
        Ok::<_, Infallible>(
            SseEvent::default()
                .data(json!({"id": "c", "type": "server.connected", "data": {}}).to_string()),
        )
    });
    let live = futures_util::stream::unfold(
        (receiver, cut, start),
        |(mut receiver, mut cut, start)| async move {
            loop {
                tokio::select! {
                    changed = cut.changed() => {
                        if changed.is_err() || *cut.borrow() != start {
                            return None;
                        }
                    }
                    event = receiver.recv() => match event {
                        Ok(event) => return Some((Ok(SseEvent::default().data(event.to_string())), (receiver, cut, start))),
                        Err(broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(_) => return None,
                    }
                }
            }
        },
    );
    Sse::new(connected.chain(live)).into_response()
}

async fn log(
    State(fake): State<Fake>,
    Path(id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    fake.script()
        .requests
        .push((format!("log:{id}"), json!(query)));
    let after: i64 = query
        .get("after")
        .and_then(|after| after.parse().ok())
        .unwrap_or(-1);
    let (events, head) = {
        let script = fake.script();
        let events: Vec<Value> = script
            .log
            .get(&id)
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|event| event["durable"]["seq"].as_i64().unwrap() > after)
            .collect();
        let head = script
            .log
            .get(&id)
            .and_then(|log| log.last())
            .map(|event| event["durable"]["seq"].clone());
        (events, head)
    };
    let mut frames: Vec<Result<SseEvent, Infallible>> = events
        .into_iter()
        .map(|event| Ok(SseEvent::default().data(event.to_string())))
        .collect();
    let mut synced = json!({"type": "log.synced", "aggregateID": id});
    if let Some(head) = head {
        synced["seq"] = head;
    }
    frames.push(Ok(SseEvent::default().data(synced.to_string())));
    Sse::new(futures_util::stream::iter(frames)).into_response()
}

async fn get_session(State(fake): State<Fake>, Path(id): Path<String>) -> Response {
    axum::Json(json!({"data": fake.session_info(&id)})).into_response()
}

async fn list_sessions(Query(query): Query<HashMap<String, String>>) -> axum::Json<Value> {
    let _ = query;
    axum::Json(json!({"data": [], "cursor": {}}))
}

async fn active(State(fake): State<Fake>) -> axum::Json<Value> {
    let active: serde_json::Map<String, Value> = fake
        .script()
        .active
        .iter()
        .map(|id| (id.clone(), json!({"type": "running"})))
        .collect();
    axum::Json(json!({"data": active}))
}

async fn inbox(State(fake): State<Fake>) -> axum::Json<Value> {
    axum::Json(json!({"data": fake.script().inbox}))
}

async fn permissions(State(fake): State<Fake>) -> axum::Json<Value> {
    axum::Json(json!({"data": fake.script().permissions}))
}

async fn empty_data() -> axum::Json<Value> {
    axum::Json(json!({"data": []}))
}

async fn messages(
    State(fake): State<Fake>,
    Query(query): Query<HashMap<String, String>>,
) -> axum::Json<Value> {
    let script = fake.script();
    if query.get("type").map(String::as_str) == Some("user") {
        let mut ids = script.user_messages.clone();
        if query.get("order").map(String::as_str) == Some("desc") {
            ids.reverse();
        }
        let data: Vec<Value> = ids
            .iter()
            .map(|id| json!({"id": id, "type": "user", "text": "", "time": {"created": 1}}))
            .collect();
        return axum::Json(json!({"data": data, "cursor": {}}));
    }
    // Two pages of all messages, to exercise paging.
    let page: usize = query
        .get("cursor")
        .and_then(|cursor| cursor.parse().ok())
        .unwrap_or(0);
    let chunk: Vec<Value> = script
        .all_messages
        .iter()
        .skip(page * 2)
        .take(2)
        .cloned()
        .collect();
    let next = (script.all_messages.len() > (page + 1) * 2).then(|| (page + 1).to_string());
    axum::Json(json!({"data": chunk, "cursor": {"next": next}}))
}

async fn prompt(
    State(fake): State<Fake>,
    Path(id): Path<String>,
    axum::Json(body): axum::Json<Value>,
) -> Response {
    let status = {
        let mut script = fake.script();
        script.requests.push(("prompt".into(), body.clone()));
        script.prompt_status
    };
    if let Some(status) = status {
        return (
            StatusCode::from_u16(status).unwrap(),
            axum::Json(json!({"_tag": "SessionNotFoundError", "message": "Session not found", "sessionID": id})),
        )
            .into_response();
    }
    axum::Json(json!({"data": {"id": body["id"], "sessionID": id, "type": "user", "delivery": body["delivery"]}})).into_response()
}

async fn record(fake: &Fake, route: &str, body: Value) {
    fake.script().requests.push((route.to_owned(), body));
}

async fn synthetic(
    State(fake): State<Fake>,
    axum::Json(body): axum::Json<Value>,
) -> axum::Json<Value> {
    record(&fake, "synthetic", body.clone()).await;
    axum::Json(json!({"data": {"id": body["id"], "type": "synthetic"}}))
}

async fn interrupt(State(fake): State<Fake>) -> axum::Json<Value> {
    record(&fake, "interrupt", Value::Null).await;
    axum::Json(json!({"interrupted": fake.script().interrupted}))
}

async fn cancel_inbox(
    State(fake): State<Fake>,
    Path((_, inbox)): Path<(String, String)>,
) -> StatusCode {
    record(&fake, "cancel", json!(inbox)).await;
    StatusCode::NO_CONTENT
}

async fn fork(State(fake): State<Fake>, axum::Json(body): axum::Json<Value>) -> axum::Json<Value> {
    record(&fake, "fork", body).await;
    axum::Json(json!({"data": fake.session_info("ses_fork")}))
}

async fn no_content(State(fake): State<Fake>, axum::Json(body): axum::Json<Value>) -> StatusCode {
    record(&fake, "other", body).await;
    StatusCode::NO_CONTENT
}

async fn commands(State(fake): State<Fake>) -> axum::Json<Value> {
    let mut script = fake.script();
    if script.cold_commands > 0 {
        script.cold_commands -= 1;
        return axum::Json(json!({"location": {"directory": fake.folder}, "data": []}));
    }
    axum::Json(
        json!({"location": {"directory": fake.folder}, "data": [{"name": "init", "description": "AGENTS.md"}]}),
    )
}

async fn models(State(fake): State<Fake>) -> axum::Json<Value> {
    axum::Json(json!({"location": {"directory": fake.folder}, "data": [
        {"id": "sonnet", "providerID": "anthropic", "name": "Sonnet", "enabled": true, "status": "active", "type": "chat",
         "variants": [{"id": "high"}], "limit": {"context": 200000, "output": 8000}}
    ]}))
}

async fn serve(folder: &std::path::Path, script: Script) -> (Fake, url::Url) {
    let (events, _) = broadcast::channel(1024);
    let (cut, _) = watch::channel(0);
    let fake = Fake {
        script: Arc::new(Mutex::new(script)),
        events,
        cut,
        folder: folder.display().to_string(),
        pid: 4242,
    };
    let app = Router::new()
        .route("/api/info", get(info))
        .route("/api/event", get(event_stream))
        .route("/api/session", get(list_sessions))
        .route("/api/session/active", get(active))
        .route("/api/session/{id}", get(get_session).patch(no_content))
        .route("/api/session/{id}/inbox", get(inbox))
        .route("/api/session/{id}/inbox/{inbox}", delete(cancel_inbox))
        .route("/api/session/{id}/message", get(messages))
        .route("/api/session/{id}/permission", get(permissions))
        .route("/api/session/{id}/form", get(empty_data))
        .route("/api/session/{id}/prompt", post(prompt))
        .route("/api/session/{id}/synthetic", post(synthetic))
        .route("/api/session/{id}/interrupt", post(interrupt))
        .route("/api/session/{id}/fork", post(fork))
        .route("/api/session/{id}/model", post(no_content))
        .route("/api/experimental/session/{id}/log", get(log))
        .route(
            "/api/experimental/session/{id}/instructions/entries/{key}",
            put(no_content),
        )
        .route("/api/model", get(models))
        .route("/api/model/default", get(empty_data))
        .route("/api/agent", get(empty_data))
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
    )
}

fn registration(dir: &std::path::Path, url: &url::Url, pid: u32) -> std::path::PathBuf {
    let path = dir.join("opencode").join("service.json");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(
        &path,
        json!({"id": "svc", "version": "2.2.5", "url": url.as_str(), "pid": pid, "password": PASSWORD}).to_string(),
    )
    .unwrap();
    path
}

async fn harness(fake: &Fake, url: url::Url) -> OpenCodeHarness {
    let api = Api::new(Endpoint {
        url,
        password: Some(PASSWORD.into()),
    })
    .unwrap();
    let link = Link::fixed(
        api,
        ServerInfo {
            version: "2.2.5".into(),
            pid: fake.pid,
        },
        ServiceConfig::new("/nonexistent/opencode"),
    );
    OpenCodeHarness::with_link(
        OpenCodeHarnessConfig::new("/nonexistent/opencode", "test"),
        link,
    )
    .await
    .unwrap()
}

fn resume(folder: &std::path::Path) -> OpenSpec {
    OpenSpec {
        mode: OpenMode::Resume {
            session: ProviderSessionId::new(SESSION).unwrap(),
        },
        folder: folder.to_path_buf(),
        settings: SettingsChange::default(),
        instructions: None,
        title: None,
        after: None,
        output_mode: OutputMode::Detailed,
    }
}

async fn collect(events: &mut EventStream, wait: Duration) -> Vec<Event> {
    let mut out = Vec::new();
    let _ = tokio::time::timeout(wait, async {
        while let Some(envelope) = events.next().await {
            out.push(envelope.event);
        }
    })
    .await;
    out
}

async fn until(events: &mut EventStream, mut predicate: impl FnMut(&Event) -> bool) -> Vec<Event> {
    let mut seen = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(envelope) = events.next().await {
            let done = predicate(&envelope.event);
            seen.push(envelope.event);
            if done {
                return;
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out; saw {seen:?}"));
    seen
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn discovery_authenticates_waits_for_a_starting_service_and_rejects_stale_registrations() {
    let folder = tempfile::tempdir().unwrap();
    let (fake, url) = serve(
        folder.path(),
        Script {
            starting: 3,
            ..Script::default()
        },
    )
    .await;
    let state = tempfile::tempdir().unwrap();
    let mut config = ServiceConfig::new("/nonexistent/opencode");
    config.registration = Some(registration(state.path(), &url, fake.pid));
    // Starting: not discoverable yet, and ensure waits instead of starting
    // another (the executable does not even exist).
    assert!(service::discover(&config).await.is_none());
    let (endpoint, info) = service::ensure(&config)
        .await
        .expect("waited for the starting service");
    assert_eq!(info.pid, 4242);
    assert_eq!(endpoint.password.as_deref(), Some(PASSWORD));
    assert!(service::discover(&config).await.is_some());

    // A registration whose pid does not match is someone else's leftover.
    config.registration = Some(registration(state.path(), &url, 1));
    assert!(service::discover(&config).await.is_none());
    let error = service::ensure(&config).await.unwrap_err();
    assert!(
        matches!(
            error,
            inline_agent_driver_opencode::ServiceError::ExecutableMissing(_)
        ),
        "{error:?}"
    );

    // No registration at all.
    config.registration = Some(state.path().join("missing").join("service.json"));
    assert!(service::discover(&config).await.is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn resuming_mid_run_restores_the_turn_queue_approval_and_settings() {
    let folder = tempfile::tempdir().unwrap();
    let (fake, url) = serve(folder.path(), Script {
        active: vec![SESSION.into()],
        user_messages: vec!["msg_old".into(), "msg_running".into()],
        inbox: vec![json!({"id": "msg_q", "type": "user", "delivery": "queue",
            "payload": {"text": "after this", "metadata": {"inline.input": "in-q"}}})],
        permissions: vec![json!({"id": "per_1", "sessionID": SESSION, "action": "shell", "resources": ["make"]})],
        ..Script::default()
    })
    .await;
    fake.durable(SESSION, "session.execution.started", json!({}), false);
    let harness = harness(&fake, url).await;
    let session = harness.open(resume(folder.path())).await.unwrap();
    let mut events = session.events();
    let opened = collect(&mut events, Duration::from_millis(300)).await;
    let turn = opened.iter().find_map(|event| match event {
        Event::Turn {
            turn,
            phase: TurnPhase::Started { .. },
        } => Some(turn.as_str().to_owned()),
        _ => None,
    });
    assert_eq!(turn.as_deref(), Some("msg_running"), "{opened:?}");
    assert!(opened.iter().any(|event| matches!(event, Event::Queue { entries } if entries.len() == 1 && entries[0].input.as_ref().map(InputId::as_str) == Some("in-q"))));
    assert!(opened.iter().any(|event| matches!(event, Event::Interaction(interaction) if interaction.id.as_str() == "per_1")));
    assert!(opened.iter().any(|event| matches!(event, Event::Settings { effective } if effective.effort.as_deref() == Some("high") && effective.mode.as_deref() == Some("build"))));
    let live = session.live_work();
    assert_eq!(live.turn.as_ref().map(TurnId::as_str), Some("msg_running"));
    assert_eq!(live.queued.len(), 1);
    assert_eq!(live.interactions.len(), 1);
    // A turn is running: a new turn is refused, a steer to it is taken.
    assert!(matches!(
        session
            .send(Input {
                id: InputId::new("in-2").unwrap(),
                content: InputContent::text("x"),
                origin: Origin::Owner { user: UserId(1) },
                delivery: Delivery::Turn
            })
            .await,
        Err(SendError::Busy { .. })
    ));
    // Effort only: the restored model is kept.
    session
        .control(Op::Settings {
            change: SettingsChange {
                effort: Some("high".into()),
                ..Default::default()
            },
            scope: SettingsScope::Thread,
        })
        .await
        .expect("effort-only change after resume");
    // Removing an entry that is not queued is reported, not silently accepted.
    assert_eq!(
        session
            .control(Op::Queue {
                action: QueueOp::Remove {
                    entry: QueueEntryId::new("msg_gone").unwrap()
                }
            })
            .await,
        Err(OpError::NotQueued)
    );
    session
        .control(Op::Queue {
            action: QueueOp::Remove {
                entry: QueueEntryId::new("msg_q").unwrap(),
            },
        })
        .await
        .unwrap();
    assert_eq!(fake.requests("cancel"), vec![json!("msg_q")]);
    // The service is idle after all: an interrupt that stopped nothing ends the stale turn.
    let ended = {
        let _ = session
            .control(Op::Interrupt {
                cancel_queued: false,
            })
            .await
            .unwrap();
        until(&mut events, |event| {
            matches!(
                event,
                Event::Turn {
                    phase: TurnPhase::Completed { .. },
                    ..
                }
            )
        })
        .await
    };
    assert!(matches!(
        ended.last(),
        Some(Event::Turn {
            phase: TurnPhase::Completed {
                outcome: TurnOutcome::Interrupted,
                ..
            },
            ..
        })
    ));
    assert!(session.live_work().turn.is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_lost_stream_is_repaired_from_the_log_without_replaying_history() {
    let folder = tempfile::tempdir().unwrap();
    let (fake, url) = serve(folder.path(), Script::default()).await;
    // History from before Inline opened the session.
    fake.durable(SESSION, "session.execution.started", json!({}), false);
    fake.durable(SESSION, "session.execution.succeeded", json!({}), false);
    let harness = harness(&fake, url).await;
    let session = harness.open(resume(folder.path())).await.unwrap();
    let mut events = session.events();
    collect(&mut events, Duration::from_millis(200)).await;
    // The floor was read from the log head.
    let head = fake.requests(&format!("log:{SESSION}"));
    assert_eq!(head.len(), 1, "{head:?}");

    // The stream drops; a turn runs and an approval appears and goes away
    // while it is down.
    fake.cut.send_modify(|generation| *generation += 1);
    tokio::time::sleep(Duration::from_millis(100)).await;
    let first_missed = fake.durable(SESSION, "session.execution.started", json!({}), false);
    fake.durable(
        SESSION,
        "session.text.ended",
        json!({"assistantMessageID": "msg_a", "ordinal": 0, "text": "made while offline"}),
        false,
    );
    fake.durable(SESSION, "session.execution.succeeded", json!({}), false);

    // The bus reconnects and the session replays only what it missed.
    let repaired = until(&mut events, |event| {
        matches!(
            event,
            Event::Turn {
                phase: TurnPhase::Completed { .. },
                ..
            }
        )
    })
    .await;
    let replays = fake.requests(&format!("log:{SESSION}"));
    assert_eq!(replays.len(), 2, "{replays:?}");
    assert_eq!(replays[1]["after"], json!((first_missed - 1).to_string()));
    let starts = repaired
        .iter()
        .filter(|event| {
            matches!(
                event,
                Event::Turn {
                    phase: TurnPhase::Started { .. },
                    ..
                }
            )
        })
        .count();
    assert_eq!(
        starts, 1,
        "history before the floor must not replay: {repaired:?}"
    );
    assert!(repaired.iter().any(|event| matches!(event, Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Message { text, .. }, .. }, .. }) if text == "made while offline")));

    // Live events still flow after the repair, without duplicates.
    fake.durable(
        SESSION,
        "session.renamed",
        json!({"title": "Live again"}),
        true,
    );
    let renamed = until(&mut events, |event| matches!(event, Event::Renamed { .. })).await;
    assert_eq!(
        renamed
            .iter()
            .filter(|event| matches!(event, Event::Renamed { .. }))
            .count(),
        1
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn send_failures_are_classified_and_passive_input_never_starts_a_turn() {
    let folder = tempfile::tempdir().unwrap();
    let (fake, url) = serve(folder.path(), Script::default()).await;
    let harness = harness(&fake, url).await;
    let session = harness.open(resume(folder.path())).await.unwrap();
    let input = |id: &str, delivery: Delivery| Input {
        id: InputId::new(id).unwrap(),
        content: InputContent::text("hello"),
        origin: Origin::Owner { user: UserId(1) },
        delivery,
    };
    fake.script().prompt_status = Some(404);
    assert!(matches!(
        session.send(input("in-404", Delivery::Turn)).await,
        Err(SendError::Rejected(_))
    ));
    fake.script().prompt_status = Some(500);
    assert!(matches!(
        session.send(input("in-500", Delivery::Turn)).await,
        Err(SendError::Unknown(_))
    ));
    fake.script().prompt_status = None;
    // A steer to a turn that is not running is a mismatch, never a silent turn.
    assert!(matches!(
        session
            .send(input(
                "in-steer",
                Delivery::Steer {
                    expected_turn: TurnId::new("msg_x").unwrap(),
                    priority: SteerPriority::Next
                }
            ))
            .await,
        Err(SendError::TurnMismatch { active: None })
    ));
    let receipt = session
        .send(input("in-passive", Delivery::Passive))
        .await
        .unwrap();
    assert_eq!(receipt.disposition, InputDisposition::Absorbed);
    let synthetic = fake.requests("synthetic");
    assert_eq!(synthetic[0]["resume"], false);
    assert_eq!(synthetic[0]["metadata"]["inline.input"], "in-passive");
    assert!(
        fake.requests("prompt")
            .iter()
            .all(|body| body["metadata"]["inline.input"] != "in-passive")
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn forks_resolve_turns_and_items_across_pages_and_refuse_unknown_points() {
    let folder = tempfile::tempdir().unwrap();
    let (fake, url) = serve(folder.path(), Script {
        all_messages: vec![
            json!({"id": "msg_u1", "type": "user"}),
            json!({"id": "msg_a1", "type": "assistant", "content": [{"type": "tool", "id": "call_7"}]}),
            json!({"id": "msg_u2", "type": "user"}),
            json!({"id": "msg_a2", "type": "assistant", "content": []}),
            json!({"id": "msg_u3", "type": "user"}),
        ],
        ..Script::default()
    })
    .await;
    let harness = harness(&fake, url).await;
    let fork = |at: ForkPoint| OpenSpec {
        mode: OpenMode::Fork {
            session: ProviderSessionId::new(SESSION).unwrap(),
            at: Some(at),
        },
        ..resume(folder.path())
    };
    harness
        .open(fork(ForkPoint::Turn {
            turn: TurnId::new("msg_u1").unwrap(),
        }))
        .await
        .unwrap();
    harness
        .open(fork(ForkPoint::Item {
            item: ItemId::new("msg_a2:text:0").unwrap(),
        }))
        .await
        .unwrap();
    harness
        .open(fork(ForkPoint::Item {
            item: ItemId::new("call_7").unwrap(),
        }))
        .await
        .unwrap();
    harness
        .open(fork(ForkPoint::Turn {
            turn: TurnId::new("msg_u3").unwrap(),
        }))
        .await
        .unwrap();
    let befores: Vec<Value> = fake
        .requests("fork")
        .iter()
        .map(|body| body["before"].clone())
        .collect();
    assert_eq!(
        befores,
        vec![
            json!("msg_u2"),
            json!("msg_u3"),
            json!("msg_u2"),
            Value::Null
        ]
    );
    let unknown = harness
        .open(fork(ForkPoint::Turn {
            turn: TurnId::new("msg_nope").unwrap(),
        }))
        .await;
    assert!(matches!(unknown, Err(OpenError::Unavailable(_))));
    assert_eq!(
        fake.requests("fork").len(),
        4,
        "an unknown point never forks"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_cold_folder_still_lists_its_commands() {
    let folder = tempfile::tempdir().unwrap();
    let (fake, url) = serve(
        folder.path(),
        Script {
            cold_commands: 1,
            ..Script::default()
        },
    )
    .await;
    let harness = harness(&fake, url).await;
    let catalog = harness
        .catalog(CatalogScope {
            folder: Some(folder.path().to_path_buf()),
            session: None,
        })
        .await
        .unwrap();
    assert_eq!(
        catalog
            .commands
            .iter()
            .map(|command| command.name.as_str())
            .collect::<Vec<_>>(),
        vec!["init"]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn releasing_an_older_handle_never_detaches_a_newer_one() {
    let folder = tempfile::tempdir().unwrap();
    let (fake, url) = serve(folder.path(), Script::default()).await;
    let harness = harness(&fake, url).await;
    let older = harness.open(resume(folder.path())).await.unwrap();
    let newer = harness.open(resume(folder.path())).await.unwrap();
    let mut events = newer.events();
    collect(&mut events, Duration::from_millis(200)).await;
    older.release().await.unwrap();
    drop(older);
    fake.durable(
        SESSION,
        "session.renamed",
        json!({"title": "Still followed"}),
        true,
    );
    let seen = until(&mut events, |event| matches!(event, Event::Renamed { .. })).await;
    assert!(
        seen.iter()
            .any(|event| matches!(event, Event::Renamed { title } if title == "Still followed"))
    );
}
