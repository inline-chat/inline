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
    /// Keeps no durable event rows, like a real OpenCode that projects
    /// events into messages: the log knows only its head sequence.
    no_event_rows: bool,
    /// `/api/event` answers 503 (a service that went away).
    refuse_events: bool,
    /// The OpenCode release the fake plays (2.2.5 when unset): routes that
    /// came later answer 404, like a real older service.
    version: Option<&'static str>,
    /// Sub-agent sessions of the main session.
    children: Vec<String>,
    /// Background jobs (`Job.Info`), as `GET /api/experimental/job` lists them.
    jobs: Vec<Value>,
}

impl Script {
    fn version(&self) -> semver::Version {
        semver::Version::parse(self.version.unwrap_or("2.2.5")).unwrap()
    }

    /// Whether the release has a route added in `since`.
    fn has(&self, since: (u64, u64, u64)) -> bool {
        self.version() >= semver::Version::new(since.0, since.1, since.2)
    }
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
    let mut script = fake.script();
    let body = json!({"version": script.version().to_string(), "pid": fake.pid, "urls": [], "paths": {"tmp": "/tmp"}});
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
    if fake.script().refuse_events {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
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
            .filter(|_| !script.no_event_rows)
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

async fn list_sessions(
    State(fake): State<Fake>,
    Query(query): Query<HashMap<String, String>>,
) -> axum::Json<Value> {
    let children: Vec<Value> = if query.get("parentID").map(String::as_str) == Some(SESSION) {
        fake.script()
            .children
            .iter()
            .map(|id| {
                let mut info = fake.session_info(id);
                info["parentID"] = json!(SESSION);
                info["title"] = json!("List files");
                info
            })
            .collect()
    } else {
        Vec::new()
    };
    axum::Json(json!({"data": children, "cursor": {}}))
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

/// `GET /message` as OpenCode pages it: `order` only on the first page, a
/// cursor (which carries the order) after it, `cursor.next` on every
/// non-empty page, and at most 200 per page.
async fn messages(
    State(fake): State<Fake>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let mut script = fake.script();
    script.requests.push(("messages".into(), json!(query)));
    let invalid = |message: &str| {
        (
            StatusCode::BAD_REQUEST,
            axum::Json(json!({"_tag": "InvalidCursorError", "message": message})),
        )
            .into_response()
    };
    if query.contains_key("cursor") && query.contains_key("order") {
        return invalid("Cursor cannot be combined with order");
    }
    let limit: usize = query
        .get("limit")
        .map_or(Some(50), |limit| limit.parse().ok())
        .filter(|limit| (1..=200).contains(limit))
        .unwrap_or(0);
    if limit == 0 {
        return (
            StatusCode::BAD_REQUEST,
            axum::Json(json!({"message": "bad limit"})),
        )
            .into_response();
    }
    let (order, start) = match query.get("cursor") {
        Some(cursor) => match cursor
            .split_once(':')
            .and_then(|(order, index)| Some((order.to_owned(), index.parse::<usize>().ok()? + 1)))
        {
            Some(found) => found,
            None => return invalid("Invalid cursor"),
        },
        None => (
            query.get("order").cloned().unwrap_or_else(|| "desc".into()),
            0,
        ),
    };
    let mut all: Vec<Value> = if query.get("type").map(String::as_str) == Some("user") {
        script
            .user_messages
            .iter()
            .map(|id| json!({"id": id, "type": "user", "text": "", "time": {"created": 1}}))
            .collect()
    } else {
        script.all_messages.clone()
    };
    if order == "desc" {
        all.reverse();
    }
    let page: Vec<Value> = all.into_iter().skip(start).take(limit).collect();
    let next = (!page.is_empty()).then(|| format!("{order}:{}", start + page.len() - 1));
    axum::Json(json!({"data": page, "cursor": {"next": next}})).into_response()
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

/// A query an Effect `HttpApi` route decodes: an unknown key (a typo the
/// real service would silently ignore) or a value outside its schema is a
/// 400 here.
fn strict_query(query: &HashMap<String, String>, allowed: &[(&str, &[&str])]) -> Option<Response> {
    for (key, value) in query {
        let Some((_, values)) = allowed.iter().find(|(name, _)| name == key) else {
            return Some(bad_request(&format!("unexpected query parameter {key}")));
        };
        if !values.is_empty() && !values.contains(&value.as_str()) {
            return Some(bad_request(&format!("invalid {key}: {value}")));
        }
    }
    None
}

fn bad_request(message: &str) -> Response {
    (
        StatusCode::BAD_REQUEST,
        axum::Json(json!({"_tag": "InvalidRequestError", "message": message})),
    )
        .into_response()
}

const BOOLEAN: &[&str] = &["true", "false"];

async fn interrupt(
    State(fake): State<Fake>,
    Path(id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if let Some(response) = strict_query(&query, &[("resume", BOOLEAN)]) {
        return response;
    }
    record(&fake, "interrupt", json!({"session": id, "query": query})).await;
    let script = fake.script();
    let interrupted = if id == SESSION {
        script.interrupted
    } else {
        script.active.contains(&id)
    };
    axum::Json(json!({"interrupted": interrupted})).into_response()
}

/// `GET /api/experimental/job` (2.2.6+).
async fn jobs(State(fake): State<Fake>, Query(query): Query<HashMap<String, String>>) -> Response {
    let mut script = fake.script();
    if !script.has((2, 2, 6)) {
        return StatusCode::NOT_FOUND.into_response();
    }
    if let Some(response) = strict_query(
        &query,
        &[
            ("sessionID", &[]),
            ("kind", &["shell", "subagent", "image", "video", "codemode"]),
            ("status", &["running", "completed", "error", "cancelled"]),
            ("descendants", BOOLEAN),
        ],
    ) {
        return response;
    }
    script.requests.push(("jobs".into(), json!(query)));
    let owners: Vec<String> = match query.get("sessionID") {
        Some(session) if session == SESSION || script.children.contains(session) => {
            let mut owners = vec![session.clone()];
            if session == SESSION && query.get("descendants").map(String::as_str) == Some("true") {
                owners.extend(script.children.iter().cloned());
            }
            owners
        }
        Some(session) => {
            return (
                StatusCode::NOT_FOUND,
                axum::Json(json!({"_tag": "SessionNotFoundError", "sessionID": session, "message": "Session not found"})),
            )
                .into_response();
        }
        None => Vec::new(),
    };
    let data: Vec<Value> = script
        .jobs
        .iter()
        .filter(|job| {
            owners.is_empty()
                || owners
                    .iter()
                    .any(|owner| job["sessionID"].as_str() == Some(owner))
        })
        .filter(|job| {
            query
                .get("status")
                .is_none_or(|status| job["status"].as_str() == Some(status))
        })
        .filter(|job| {
            query
                .get("kind")
                .is_none_or(|kind| job["kind"].as_str() == Some(kind))
        })
        .cloned()
        .collect();
    axum::Json(json!({"data": data})).into_response()
}

/// `POST /api/experimental/job/{id}/cancel` (2.4.0+): no payload, 204 even
/// for a job that already ended.
async fn cancel_job(
    State(fake): State<Fake>,
    Path(id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let mut script = fake.script();
    if !script.has((2, 4, 0)) {
        return StatusCode::NOT_FOUND.into_response();
    }
    if let Some(response) = strict_query(&query, &[]) {
        return response;
    }
    script.requests.push(("job-cancel".into(), json!(id)));
    for job in &mut script.jobs {
        if job["id"] == id && job["status"] == "running" {
            job["status"] = json!("cancelled");
        }
    }
    StatusCode::NO_CONTENT.into_response()
}

/// `PATCH /api/session/{id}/inbox/{inboxID}`: only a pending entry of the
/// other delivery changes; steering it wakes the session.
async fn update_inbox(
    State(fake): State<Fake>,
    Path((_, inbox)): Path<(String, String)>,
    axum::Json(body): axum::Json<Value>,
) -> Response {
    let Some(delivery) = body["delivery"]
        .as_str()
        .filter(|delivery| ["steer", "queue"].contains(delivery))
        .map(str::to_owned)
    else {
        return bad_request("delivery must be steer or queue");
    };
    let changed = {
        let mut script = fake.script();
        script
            .requests
            .push(("inbox-update".into(), json!({"inbox": inbox, "body": body})));
        let entry = script
            .inbox
            .iter_mut()
            .find(|entry| entry["id"] == inbox && entry["delivery"] != delivery);
        match entry {
            Some(entry) => {
                entry["delivery"] = json!(delivery);
                true
            }
            None => false,
        }
    };
    if !changed {
        return (
            StatusCode::CONFLICT,
            axum::Json(json!({"_tag": "ConflictError", "resource": inbox, "message": format!("Pending input cannot change to {delivery}: {inbox}")})),
        )
            .into_response();
    }
    fake.durable(
        SESSION,
        "session.inbox.delivery.changed",
        json!({"inboxID": inbox, "delivery": delivery}),
        true,
    );
    StatusCode::NO_CONTENT.into_response()
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

async fn shell_delete(
    State(fake): State<Fake>,
    Path(id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if let Some(response) = strict_query(&query, &[("location[directory]", &[])]) {
        return response;
    }
    record(&fake, "shell-delete", json!({"id": id, "query": query})).await;
    StatusCode::NO_CONTENT.into_response()
}

async fn mcp_add(
    State(fake): State<Fake>,
    Path(name): Path<String>,
    Query(query): Query<HashMap<String, String>>,
    axum::Json(body): axum::Json<Value>,
) -> StatusCode {
    record(
        &fake,
        "mcp",
        json!({"name": name, "query": query, "body": body}),
    )
    .await;
    StatusCode::NO_CONTENT
}

async fn serve(folder: &std::path::Path, script: Script) -> (Fake, url::Url) {
    serve_as(folder, script, 4242).await
}

async fn serve_as(folder: &std::path::Path, script: Script, pid: u32) -> (Fake, url::Url) {
    let (events, _) = broadcast::channel(1024);
    let (cut, _) = watch::channel(0);
    let fake = Fake {
        script: Arc::new(Mutex::new(script)),
        events,
        cut,
        folder: folder.display().to_string(),
        pid,
    };
    let app = Router::new()
        .route("/api/info", get(info))
        .route("/api/event", get(event_stream))
        .route("/api/session", get(list_sessions))
        .route("/api/session/active", get(active))
        .route("/api/session/{id}", get(get_session).patch(no_content))
        .route("/api/session/{id}/inbox", get(inbox))
        .route(
            "/api/session/{id}/inbox/{inbox}",
            delete(cancel_inbox).patch(update_inbox),
        )
        .route("/api/session/{id}/message", get(messages))
        .route("/api/session/{id}/permission", get(permissions))
        .route("/api/session/{id}/form", get(empty_data))
        .route("/api/session/{id}/prompt", post(prompt))
        .route("/api/session/{id}/synthetic", post(synthetic))
        .route("/api/session/{id}/interrupt", post(interrupt))
        .route("/api/session/{id}/fork", post(fork))
        .route("/api/session/{id}/model", post(no_content))
        .route("/api/experimental/session/{id}/log", get(log))
        .route("/api/shell/{id}", delete(shell_delete))
        .route("/api/experimental/job", get(jobs))
        .route("/api/experimental/job/{id}/cancel", post(cancel_job))
        .route("/api/experimental/mcp/{name}", put(mcp_add))
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
    let version = fake.script().version().to_string();
    let link = Link::fixed(
        api,
        ServerInfo {
            version,
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
    let passive = synthetic
        .iter()
        .find(|body| body["metadata"]["inline.input"] == "in-passive")
        .expect("passive synthetic");
    assert_eq!(passive["resume"], false);
    assert!(passive.get("description").is_none());
    // Every prompt's note went first, hidden (no description), never waking.
    assert!(
        synthetic
            .iter()
            .filter(|body| body["metadata"].get("inline.note").is_some())
            .all(|note| note["resume"] == false && note.get("description").is_none())
    );
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
async fn forks_past_the_first_page_follow_the_cursor_alone() {
    let folder = tempfile::tempdir().unwrap();
    // A prompt every ten messages, 450 in all: three pages of up to 200.
    let all_messages = (0..450)
        .map(|index| {
            let id = format!("msg_{index:03}");
            if index % 10 == 0 {
                json!({"id": id, "type": "user"})
            } else {
                json!({"id": id, "type": "assistant", "content": []})
            }
        })
        .collect();
    let (fake, url) = serve(
        folder.path(),
        Script {
            all_messages,
            ..Script::default()
        },
    )
    .await;
    let harness = harness(&fake, url).await;
    let fork = |turn: &str| OpenSpec {
        mode: OpenMode::Fork {
            session: ProviderSessionId::new(SESSION).unwrap(),
            at: Some(ForkPoint::Turn {
                turn: TurnId::new(turn).unwrap(),
            }),
        },
        ..resume(folder.path())
    };
    // A point on the second page, then the last turn (kept whole, so the
    // walk reads to the short last page).
    harness.open(fork("msg_220")).await.unwrap();
    harness.open(fork("msg_440")).await.unwrap();
    let befores: Vec<Value> = fake
        .requests("fork")
        .iter()
        .map(|body| body["before"].clone())
        .collect();
    assert_eq!(befores, vec![json!("msg_230"), Value::Null]);
    let paged: Vec<Value> = fake
        .requests("messages")
        .into_iter()
        .filter(|query| query.get("cursor").is_some())
        .collect();
    assert_eq!(paged.len(), 3, "{paged:?}");
    assert!(paged.iter().all(|query| query.get("order").is_none()));
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

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn without_event_rows_a_lost_stream_is_rebuilt_from_the_messages() {
    let folder = tempfile::tempdir().unwrap();
    let (fake, url) = serve(folder.path(), Script {
        no_event_rows: true,
        // Created a moment before Inline opens the session: within clock
        // grace, so only the open-time anchor keeps it out.
        all_messages: vec![json!({"id": "msg_before", "type": "user", "text": "earlier", "time": {"created": now_ms()}})],
        ..Script::default()
    })
    .await;
    fake.durable(SESSION, "session.execution.succeeded", json!({}), false);
    let harness = harness(&fake, url).await;
    let session = harness.open(resume(folder.path())).await.unwrap();
    let mut events = session.events();
    collect(&mut events, Duration::from_millis(200)).await;

    // While the stream is down, a prompt from the terminal runs to the end.
    fake.cut.send_modify(|generation| *generation += 1);
    tokio::time::sleep(Duration::from_millis(100)).await;
    let at = now_ms();
    {
        let mut script = fake.script();
        script.all_messages.push(json!({"id": "msg_u1", "type": "user", "text": "from the terminal", "time": {"created": at}}));
        script.all_messages.push(json!({"id": "msg_a1", "type": "assistant", "time": {"created": at + 1, "completed": at + 2},
            "content": [{"type": "text", "text": "Done while you slept"}]}));
        script.all_messages.push(json!({"id": "msg_idle", "type": "idle", "outcome": "succeeded", "time": {"created": at + 3}}));
    }
    fake.durable(SESSION, "session.execution.started", json!({}), false);
    fake.durable(SESSION, "session.execution.succeeded", json!({}), false);

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
    assert!(repaired.iter().any(|event| matches!(event, Event::Turn { turn, phase: TurnPhase::Started { .. } } if turn.as_str() == "msg_u1")), "{repaired:?}");
    assert!(repaired.iter().any(|event| matches!(event, Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Message { text, .. }, .. }, .. }) if text == "Done while you slept")));
    assert!(!repaired.iter().any(|event| matches!(event, Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Message { text, .. }, .. }, .. }) if text == "earlier")), "history before opening is never replayed");
    assert!(matches!(
        repaired.last(),
        Some(Event::Turn {
            phase: TurnPhase::Completed {
                outcome: TurnOutcome::Completed,
                ..
            },
            ..
        })
    ));
    assert!(session.live_work().turn.is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn settings_apply_what_opencode_takes_and_skip_the_rest() {
    let folder = tempfile::tempdir().unwrap();
    let (fake, url) = serve(folder.path(), Script::default()).await;
    let harness = harness(&fake, url).await;
    let session = harness.open(resume(folder.path())).await.unwrap();
    // A speed and another harness's permission mode ride along with a model.
    let outcome = session
        .control(Op::Settings {
            change: SettingsChange {
                model: Some("openai/gpt-6-luna".into()),
                effort: Some("low".into()),
                speed: Some("fast".into()),
                permission_mode: Some("bypassPermissions".into()),
                folder: None,
            },
            scope: SettingsScope::Thread,
        })
        .await
        .expect("the model change applies");
    assert!(
        matches!(&outcome, OpOutcome::Accepted { native } if native["skipped"].as_array().unwrap().len() == 2),
        "{outcome:?}"
    );
    let switched = fake.requests("other");
    assert!(
        switched.iter().any(|body| body["model"]
            == json!({"providerID": "openai", "id": "gpt-6-luna", "variant": "low"})),
        "{switched:?}"
    );
    // Nothing OpenCode can take: unavailable, with the reason.
    let nothing = session
        .control(Op::Settings {
            change: SettingsChange {
                speed: Some("fast".into()),
                ..Default::default()
            },
            scope: SettingsScope::Thread,
        })
        .await;
    assert!(matches!(nothing, Err(OpError::Unavailable(_))));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stopping_a_background_shell_names_its_location() {
    let folder = tempfile::tempdir().unwrap();
    let (fake, url) = serve(folder.path(), Script::default()).await;
    let harness = harness(&fake, url).await;
    let session = harness.open(resume(folder.path())).await.unwrap();
    session
        .control(Op::StopChild {
            child: ChildRef {
                id: ChildId::new("sh_1").unwrap(),
                kind: ChildKind::BackgroundTask,
            },
        })
        .await
        .unwrap();
    // Shells are per location: without one OpenCode looks elsewhere, finds
    // nothing and still answers 204.
    assert_eq!(
        fake.requests("shell-delete"),
        vec![json!({"id": "sh_1", "query": {"location[directory]": fake.folder}})]
    );
}

fn with_computer_use() -> OpenCodeHarnessConfig {
    let mut config = OpenCodeHarnessConfig::new("/nonexistent/opencode", "test");
    config.stdio_mcp_servers = vec![inline_agent_bridge::StdioMcpServer {
        name: "computer-use".into(),
        command: "/opt/inline/computer-use".into(),
        args: vec!["mcp".into()],
    }];
    config
}

/// Waits until `route` was requested `count` times.
async fn requested(fake: &Fake, route: &str, count: usize, wait: Duration) -> Vec<Value> {
    let deadline = tokio::time::Instant::now() + wait;
    loop {
        let requests = fake.requests(route);
        if requests.len() >= count || tokio::time::Instant::now() >= deadline {
            return requests;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn mcp_servers_come_back_after_their_location_shuts_down() {
    let folder = tempfile::tempdir().unwrap();
    let (fake, url) = serve(folder.path(), Script::default()).await;
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
    let harness = OpenCodeHarness::with_link(with_computer_use(), link)
        .await
        .unwrap();
    let _session = harness.open(resume(folder.path())).await.unwrap();
    let added = requested(&fake, "mcp", 1, Duration::from_secs(5)).await;
    assert_eq!(added.len(), 1);
    assert_eq!(added[0]["name"], "computer-use");
    assert_eq!(added[0]["query"]["location[directory]"], json!(fake.folder));
    assert_eq!(
        added[0]["body"]["config"]["command"],
        json!(["/opt/inline/computer-use", "mcp"])
    );
    // Another folder's location going away leaves this one alone.
    let _ = fake.events.send(
        json!({"id": "evt_x", "type": "location.shutdown", "location": {"directory": "/elsewhere"}, "data": {}}),
    );
    assert_eq!(
        requested(&fake, "mcp", 2, Duration::from_secs(1))
            .await
            .len(),
        1
    );
    // This folder's location reloads: its in-memory servers are gone.
    let _ = fake.events.send(
        json!({"id": "evt_y", "type": "location.shutdown", "location": {"directory": fake.folder}, "data": {}}),
    );
    let again = requested(&fake, "mcp", 2, Duration::from_secs(5)).await;
    assert_eq!(again.len(), 2, "{again:?}");
    assert_eq!(again[1], again[0]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn mcp_servers_come_back_when_the_service_restarts_elsewhere() {
    let folder = tempfile::tempdir().unwrap();
    let (old, old_url) = serve(folder.path(), Script::default()).await;
    let (new, new_url) = serve_as(folder.path(), Script::default(), 4343).await;
    let state = tempfile::tempdir().unwrap();
    let mut service = ServiceConfig::new("/nonexistent/opencode");
    // The registration already names the restarted service.
    service.registration = Some(registration(state.path(), &new_url, new.pid));
    let api = Api::new(Endpoint {
        url: old_url,
        password: Some(PASSWORD.into()),
    })
    .unwrap();
    let link = Link::fixed(
        api,
        ServerInfo {
            version: "2.2.5".into(),
            pid: old.pid,
        },
        service,
    );
    let harness = OpenCodeHarness::with_link(with_computer_use(), link)
        .await
        .unwrap();
    let _session = harness.open(resume(folder.path())).await.unwrap();
    assert_eq!(
        requested(&old, "mcp", 1, Duration::from_secs(5))
            .await
            .len(),
        1
    );
    // The old service goes away; the bus finds the new one.
    old.script().refuse_events = true;
    old.cut.send_modify(|generation| *generation += 1);
    let added = requested(&new, "mcp", 1, Duration::from_secs(10)).await;
    assert_eq!(
        added.len(),
        1,
        "the restarted service gets the servers again"
    );
    assert_eq!(added[0]["query"]["location[directory]"], json!(new.folder));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_silent_event_stream_ends_while_heartbeats_keep_one_open() {
    use axum::response::sse::KeepAlive;
    use inline_agent_driver_opencode::api::ApiError;
    let app = Router::new()
        // One event, then nothing at all: a half-open connection.
        .route(
            "/silent",
            get(|| async {
                Sse::new(
                    futures_util::stream::once(async {
                        Ok::<_, Infallible>(SseEvent::default().data("{\"n\":1}"))
                    })
                    .chain(futures_util::stream::pending()),
                )
            }),
        )
        // Heartbeat comments only, until an event well past the idle limit.
        .route(
            "/beating",
            get(|| async {
                Sse::new(
                    futures_util::stream::once(async {
                        tokio::time::sleep(Duration::from_millis(600)).await;
                        Ok::<_, Infallible>(SseEvent::default().data("{\"n\":2}"))
                    })
                    .chain(futures_util::stream::pending()),
                )
                .keep_alive(KeepAlive::new().interval(Duration::from_millis(50)))
            }),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let api = Api::new(Endpoint {
        url: url::Url::parse(&format!("http://{address}/")).unwrap(),
        password: None,
    })
    .unwrap();
    let idle = Some(Duration::from_millis(200));
    let query = inline_agent_driver_opencode::api::Query::new;
    let silent = api.sse_with_idle("silent", query(), idle).await.unwrap();
    let items: Vec<Result<Value, ApiError>> =
        tokio::time::timeout(Duration::from_secs(5), silent.collect())
            .await
            .expect("a silent stream ends on its own");
    assert_eq!(items[0], Ok(json!({"n": 1})));
    assert!(
        matches!(items.last(), Some(Err(ApiError::Transport(_)))),
        "{items:?}"
    );
    let beating = api.sse_with_idle("beating", query(), idle).await.unwrap();
    let mut beating = Box::pin(beating);
    let first = tokio::time::timeout(Duration::from_secs(5), beating.next())
        .await
        .unwrap();
    assert_eq!(first, Some(Ok(json!({"n": 2}))));
}

/// The main session's background work as OpenCode lists it: its own shell,
/// a sub-agent and that sub-agent's shell, next to a finished job and
/// another session's job that Stop must leave alone.
fn background_jobs() -> Vec<Value> {
    let job = |kind: &str, id: &str, owner: &str, status: &str| {
        let mut job = json!({"kind": kind, "id": id, "sessionID": owner, "status": status,
            "time": {"started": 1}});
        if kind == "shell" {
            job["shellID"] = json!(id);
            job["command"] = json!("make watch");
        } else {
            job["childSessionID"] = json!(id);
            job["agent"] = json!("explore");
            job["description"] = json!("List files");
        }
        job
    };
    vec![
        job("shell", "sh_1", SESSION, "running"),
        job("subagent", "ses_child", SESSION, "running"),
        job("shell", "sh_2", "ses_child", "running"),
        job("shell", "sh_done", SESSION, "completed"),
        job("shell", "sh_other", "ses_other", "running"),
    ]
}

/// A main session whose turn has ended while a sub-agent and a shell it
/// moved to the background keep working (OpenCode 2.3+).
async fn idle_with_background(
    version: &'static str,
) -> (
    Fake,
    OpenCodeHarness,
    Arc<dyn Session>,
    EventStream,
    tempfile::TempDir,
) {
    let folder = tempfile::tempdir().unwrap();
    let (fake, url) = serve(
        folder.path(),
        Script {
            version: Some(version),
            children: vec!["ses_child".into()],
            active: vec!["ses_child".into()],
            jobs: background_jobs(),
            ..Script::default()
        },
    )
    .await;
    let harness = harness(&fake, url).await;
    let session = harness.open(resume(folder.path())).await.unwrap();
    let mut events = session.events();
    fake.durable(SESSION, "session.execution.started", json!({}), true);
    fake.durable(
        SESSION,
        "session.tool.called",
        json!({"assistantMessageID": "msg_a", "id": "call_sh", "name": "shell",
        "input": {"command": "make watch"}, "executed": true}),
        true,
    );
    fake.durable(SESSION, "session.tool.success", json!({"assistantMessageID": "msg_a", "id": "call_sh",
        "content": [{"type": "text", "text": "Command moved to the background (shell ID: sh_1)."}],
        "metadata": {"status": "running", "shellID": "sh_1", "truncated": false}, "executed": true}), true);
    fake.durable(SESSION, "session.execution.succeeded", json!({}), true);
    until(&mut events, |event| {
        matches!(
            event,
            Event::Turn {
                phase: TurnPhase::Completed { .. },
                ..
            }
        )
    })
    .await;
    (fake, harness, session, events, folder)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stop_ends_background_work_on_every_release() {
    for version in ["2.2.5", "2.3.2", "2.4.0"] {
        let (fake, _harness, session, mut events, _folder) = idle_with_background(version).await;
        // No turn runs, but the session's background work does: Stop has
        // something to stop.
        let live = session.live_work();
        assert!(live.turn.is_none(), "{version}");
        let mut running: Vec<&str> = live
            .children
            .iter()
            .map(|child| child.id.as_str())
            .collect();
        running.sort_unstable();
        assert_eq!(running, vec!["ses_child", "sh_1"], "{version}");

        let OpOutcome::Accepted { native } = session
            .control(Op::Interrupt {
                cancel_queued: false,
            })
            .await
            .unwrap()
        else {
            panic!("{version}: not accepted");
        };
        let requests = fake.script().requests.clone();
        let position = |route: &str, body: Value| {
            requests
                .iter()
                .position(|(name, sent)| name == route && *sent == body)
                .unwrap_or_else(|| panic!("{version}: no {route} {body}: {requests:?}"))
        };
        // The main session stops with nothing a person sent waiting, so
        // without `resume`: nothing wakes it again
        // (`stop_resumes_only_for_a_persons_steer`). Its sub-agents stop for
        // good, after it.
        let main = position("interrupt", json!({"session": SESSION, "query": {}}));
        let child = position("interrupt", json!({"session": "ses_child", "query": {}}));
        assert!(main < child, "{version}: {requests:?}");
        // Background work stops before the interrupt, so none of it ends in
        // between and wakes the session again.
        for (index, (name, _)) in requests.iter().enumerate() {
            if name == "job-cancel" || name == "shell-delete" {
                assert!(index < main, "{version}: {requests:?}");
            }
        }
        let listed = fake.requests("jobs");
        let cancelled = fake.requests("job-cancel");
        let deleted = fake.requests("shell-delete");
        let deleted_ids: Vec<&Value> = deleted.iter().map(|request| &request["id"]).collect();
        match version {
            // No job API: the shell this session saw start.
            "2.2.5" => {
                assert!(listed.is_empty());
                assert!(cancelled.is_empty());
                assert_eq!(deleted_ids, vec!["sh_1"]);
            }
            // Jobs are listed, sub-agents' too, but not cancelled yet.
            "2.3.2" => {
                assert_eq!(
                    listed[0],
                    json!({"sessionID": SESSION, "descendants": "true", "status": "running"})
                );
                assert!(cancelled.is_empty());
                assert_eq!(deleted_ids, vec!["sh_1", "sh_2"]);
            }
            _ => {
                // Listed again after the interrupt, for what its last step
                // started; nothing is cancelled twice.
                assert_eq!(listed.len(), 2);
                assert_eq!(
                    cancelled,
                    vec![json!("sh_1"), json!("ses_child"), json!("sh_2")]
                );
                assert!(deleted.is_empty());
            }
        }
        for request in &deleted {
            assert_eq!(
                request["query"],
                json!({"location[directory]": fake.folder}),
                "{version}"
            );
        }
        assert_eq!(
            native["stopped"]["children"],
            json!(["ses_child"]),
            "{version}"
        );
        // The shell's child ends now: a cancelled job sends no notice.
        until(&mut events, |event| {
            matches!(event, Event::Child { update } if update.child.id.as_str() == "sh_1" && update.status == ChildStatus::Stopped)
        })
        .await;
        assert!(
            session
                .live_work()
                .children
                .iter()
                .all(|child| child.id.as_str() != "sh_1"),
            "{version}"
        );
    }
}

/// Stop resumes (`resume=true`, the TUI's Esc Esc) only for a message a
/// person already sent as a steer. OpenCode resumes on any steer it holds,
/// so anything else parked as one (a mode switch's reminder, passive
/// context) would start a turn on Stop, also on an idle session.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stop_resumes_only_for_a_persons_steer() {
    let reminder = json!({"id": "msg_plan", "type": "synthetic", "delivery": "steer",
        "payload": {"text": "<system-reminder>\nYou are in Plan mode.\n</system-reminder>"}});
    let passive = json!({"id": "msg_ctx", "type": "synthetic", "delivery": "steer",
        "payload": {"text": "<inline-context untrusted=\"true\">\nhi\n</inline-context>",
            "metadata": {"inline.input": "in-ctx"}}});
    let typed = json!({"id": "msg_typed", "type": "user", "delivery": "steer",
        "payload": {"text": "also check the tests", "metadata": {"inline.input": "in-typed"}}});
    for (case, parked, running, resumed) in [
        ("idle, a mode reminder", reminder, false, false),
        ("running, passive context", passive, true, false),
        ("running, a person's steer", typed, true, true),
    ] {
        let folder = tempfile::tempdir().unwrap();
        let (fake, url) = serve(
            folder.path(),
            Script {
                inbox: vec![parked],
                ..Script::default()
            },
        )
        .await;
        let harness = harness(&fake, url).await;
        let session = harness.open(resume(folder.path())).await.unwrap();
        let mut events = session.events();
        if running {
            fake.durable(SESSION, "session.execution.started", json!({}), true);
            until(&mut events, |event| {
                matches!(
                    event,
                    Event::Turn {
                        phase: TurnPhase::Started { .. },
                        ..
                    }
                )
            })
            .await;
        } else {
            assert!(session.live_work().is_idle(), "{case}");
        }
        session
            .control(Op::Interrupt {
                cancel_queued: false,
            })
            .await
            .unwrap();
        let query = if resumed {
            json!({"resume": "true"})
        } else {
            json!({})
        };
        assert_eq!(
            fake.requests("interrupt"),
            vec![json!({"session": SESSION, "query": query})],
            "{case}"
        );
        if !running {
            assert!(session.live_work().is_idle(), "{case}");
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_wake_from_a_stopped_sub_agent_is_stopped_again() {
    let (fake, _harness, session, mut events, _folder) = idle_with_background("2.3.2").await;
    session
        .control(Op::Interrupt {
            cancel_queued: false,
        })
        .await
        .unwrap();
    let before = fake.requests("interrupt").len();
    // The interrupted sub-agent still reports, and its report wakes the
    // main session.
    fake.durable(
        "ses_child",
        "session.execution.interrupted",
        json!({"reason": "user"}),
        true,
    );
    fake.durable(SESSION, "session.inbox.enqueued", json!({"inboxID": "msg_report", "item": {"type": "synthetic", "delivery": "steer", "payload": {
        "text": "<subagent sessionID=\"ses_child\" state=\"cancelled\" description=\"List files\">\n</subagent>",
        "description": "List files",
        "metadata": {"source": "subagent", "childID": "ses_child", "agent": "Explore", "state": "cancelled"}}}}), true);
    fake.durable(SESSION, "session.execution.started", json!({}), true);
    let sent = requested(&fake, "interrupt", before + 1, Duration::from_secs(5)).await;
    // Stopped again, without resuming: the report stays parked.
    assert_eq!(
        sent.get(before),
        Some(&json!({"session": SESSION, "query": {}})),
        "{sent:?}"
    );
    fake.durable(
        SESSION,
        "session.execution.interrupted",
        json!({"reason": "user"}),
        true,
    );
    let ended = until(&mut events, |event| {
        matches!(
            event,
            Event::Turn {
                phase: TurnPhase::Completed { .. },
                ..
            }
        )
    })
    .await;
    assert!(
        matches!(ended.last(), Some(Event::Turn { turn, phase: TurnPhase::Completed { outcome: TurnOutcome::Interrupted, error: None, .. } }) if turn.as_str() == "msg_report"),
        "{ended:?}"
    );
    // The sub-agent, woken again by its own shell's notice, stops too.
    fake.durable("ses_child", "session.execution.started", json!({}), true);
    let sent = requested(&fake, "interrupt", before + 2, Duration::from_secs(5)).await;
    assert_eq!(
        sent.get(before + 1),
        Some(&json!({"session": "ses_child", "query": {}})),
        "{sent:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn queue_start_steers_the_first_parked_prompt() {
    let folder = tempfile::tempdir().unwrap();
    // Queued prompts a stop left parked.
    let (fake, url) = serve(
        folder.path(),
        Script {
            inbox: vec![
                json!({"id": "msg_q1", "type": "user", "delivery": "queue",
                    "payload": {"text": "first", "metadata": {"inline.input": "in-q1"}}}),
                json!({"id": "msg_q2", "type": "user", "delivery": "queue",
                    "payload": {"text": "second"}}),
            ],
            ..Script::default()
        },
    )
    .await;
    let harness = harness(&fake, url).await;
    let session = harness.open(resume(folder.path())).await.unwrap();
    let mut events = session.events();
    assert!(session.availability().op(OpKind::QueueStart).is_supported());
    assert_eq!(session.live_work().queued.len(), 2);

    session
        .control(Op::Queue {
            action: QueueOp::Start,
        })
        .await
        .unwrap();
    assert_eq!(
        fake.requests("inbox-update"),
        vec![json!({"inbox": "msg_q1", "body": {"delivery": "steer"}})]
    );
    // OpenCode announces the change; the rest stays queued behind it.
    until(&mut events, |event| {
        matches!(event, Event::Queue { entries } if entries.len() == 1 && entries[0].entry.as_str() == "msg_q2")
    })
    .await;

    // Taken by another client meanwhile: it is not queued any more.
    fake.script().inbox[1]["delivery"] = json!("steer");
    assert_eq!(
        session
            .control(Op::Queue {
                action: QueueOp::Start,
            })
            .await,
        Err(OpError::NotQueued)
    );

    // A running turn takes the queue when it finishes: nothing to start.
    fake.durable(SESSION, "session.execution.started", json!({}), true);
    until(&mut events, |event| {
        matches!(
            event,
            Event::Turn {
                phase: TurnPhase::Started { .. },
                ..
            }
        )
    })
    .await;
    let before = fake.requests("inbox-update").len();
    session
        .control(Op::Queue {
            action: QueueOp::Start,
        })
        .await
        .unwrap();
    assert_eq!(fake.requests("inbox-update").len(), before);
}
