//! End-to-end tests against a local fake of the ChatGPT Dots endpoints.
//! Fixture shapes follow the 2026-11-10 read-only probe; all values are
//! synthetic.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::Router;
use axum::body::Bytes;
use axum::extract::ws::{Message as WsMessage, WebSocket, WebSocketUpgrade};
use axum::extract::{Multipart, Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use base64::Engine;
use inline_dots::auth::{AccessToken, TokenFuture, TokenSource};
use inline_dots::realtime::RealtimePolicy;
use inline_dots::{ConnectorSettings, DotsClient, DotsConfig, DotsConnector, DotsError};
use inline_relay::*;
use serde_json::{Value, json};
use tokio::sync::mpsc;
use url::Url;

const OWNER_MEMBER: &str = "user-1__acct-1";
const DOT_MEMBER: &str = "dot-member-1";
const OWNER_INLINE: i64 = 100;

fn jwt() -> String {
    let encode = |value: &[u8]| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(value);
    let payload = json!({
        "exp": 4_000_000_000u64,
        "https://api.openai.com/auth": {
            "chatgpt_account_id": "acct-1",
            "chatgpt_user_id": "user-1",
            "chatgpt_account_user_id": OWNER_MEMBER,
        }
    });
    format!(
        "{}.{}.sig",
        encode(b"{}"),
        encode(payload.to_string().as_bytes())
    )
}

#[derive(Default)]
struct CountingTokens {
    calls: AtomicUsize,
    forced: AtomicUsize,
}

impl TokenSource for CountingTokens {
    fn token(&self, force_refresh: bool) -> TokenFuture<'_> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if force_refresh {
            self.forced.fetch_add(1, Ordering::SeqCst);
        }
        Box::pin(async { Ok(AccessToken::new(jwt())) })
    }
}

#[derive(Default)]
struct FakeState {
    base: String,
    messages: Vec<Value>,
    clock: u32,
    sent_bodies: Vec<Value>,
    uploads: HashMap<String, (String, String, Vec<u8>)>,
    reactions: Vec<(String, Option<String>)>,
    elicitation_responses: Vec<Value>,
    storage_saw_auth: bool,
    task_status: String,
    unauthorized_once: bool,
    challenge: bool,
    foreign_download: bool,
    bad_headers: Vec<String>,
    ws: Option<mpsc::UnboundedSender<String>>,
    ws_connections: usize,
}

type Shared = Arc<Mutex<FakeState>>;

impl FakeState {
    fn stamp(&mut self) -> String {
        self.clock += 1;
        format!(
            "2026-11-10T09:{:02}:{:02}Z",
            self.clock / 60,
            self.clock % 60
        )
    }

    fn add(&mut self, sender: &str, content: Value, extra: Value) -> String {
        let id = format!("m-{}", self.messages.len());
        let at = self.stamp();
        let mut message = json!({
            "id": id, "created_at": at, "updated_at": at, "role": "user",
            "account_user_id": sender, "content": content,
            "message_metadata": {"turn_trigger": "user"}, "reactions": {},
            "reply_to": null, "deleted_at": null, "inspector_url": null,
            "request_id": null, "preview": "p",
        });
        if let (Some(target), Some(extra)) = (message.as_object_mut(), extra.as_object()) {
            for (key, value) in extra {
                target.insert(key.clone(), value.clone());
            }
        }
        self.messages.push(message);
        id
    }

    fn push(&self, signal: &str, payload: Value) {
        if let Some(ws) = &self.ws {
            let frame = json!([{"id": 50, "type": "message", "topic_id": "calpico-chatgpt-messaging",
                "payload": {"type": signal, "payload": payload}}]);
            let _ = ws.send(frame.to_string());
        }
    }
}

#[allow(clippy::result_large_err)]
fn check(state: &Shared, headers: &HeaderMap) -> Result<(), Response> {
    let mut state = state.lock().unwrap();
    if state.challenge {
        return Err((
            StatusCode::FORBIDDEN,
            [("cf-mitigated", "challenge"), ("content-type", "text/html")],
            "<html>challenge</html>",
        )
            .into_response());
    }
    if state.unauthorized_once {
        state.unauthorized_once = false;
        return Err((
            StatusCode::UNAUTHORIZED,
            axum::Json(json!({"detail": "expired"})),
        )
            .into_response());
    }
    let header = |name: &str| {
        headers
            .get(name)
            .and_then(|value| value.to_str().ok())
            .unwrap_or("")
    };
    if !header("authorization").starts_with("Bearer ") {
        state.bad_headers.push("authorization".into());
    }
    if header("chatgpt-account-id") != "acct-1"
        || header("x-openai-expected-account-id") != "acct-1"
    {
        state.bad_headers.push("account".into());
    }
    if !header("user-agent").starts_with("InlineDotsBridge/") {
        state.bad_headers.push("user-agent".into());
    }
    Ok(())
}

macro_rules! guard {
    ($state:expr, $headers:expr) => {
        if let Err(response) = check(&$state, &$headers) {
            return response;
        }
    };
}

async fn primary(State(state): State<Shared>, headers: HeaderMap) -> Response {
    guard!(state, headers);
    axum::Json(serde_json::from_str::<Value>(include_str!("fixtures/primary.json")).unwrap())
        .into_response()
}

async fn room(
    State(state): State<Shared>,
    headers: HeaderMap,
    Path(room): Path<String>,
) -> Response {
    guard!(state, headers);
    if room != "room-1" {
        return (
            StatusCode::NOT_FOUND,
            axum::Json(json!({"detail": "Not Found"})),
        )
            .into_response();
    }
    axum::Json(serde_json::from_str::<Value>(include_str!("fixtures/room.json")).unwrap())
        .into_response()
}

async fn list_messages(
    State(state): State<Shared>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    guard!(state, headers);
    let state = state.lock().unwrap();
    let limit: usize = query
        .get("limit")
        .and_then(|limit| limit.parse().ok())
        .unwrap_or(32);
    let all = &state.messages;
    let items: Vec<Value> = if let Some(root) = query.get("reply_root_message_id") {
        all.iter()
            .filter(|m| {
                m["reply_root_message_id"].as_str() == Some(root) || m["id"].as_str() == Some(root)
            })
            .cloned()
            .collect()
    } else if let Some(after) = query.get("after") {
        let start = all
            .iter()
            .position(|m| m["id"].as_str() == Some(after))
            .map(|i| i + 1)
            .unwrap_or(0);
        all[start..].iter().take(limit).cloned().collect()
    } else if let Some(around) = query.get("around") {
        all.iter()
            .filter(|m| m["id"].as_str() == Some(around))
            .cloned()
            .collect()
    } else {
        all[all.len().saturating_sub(limit)..].to_vec()
    };
    // Newest first, like a server that should not be trusted for ordering.
    let mut items = items;
    items.reverse();
    axum::Json(json!({"items": items, "prev_cursor": null, "next_cursor": null})).into_response()
}

async fn send_message(
    State(state): State<Shared>,
    headers: HeaderMap,
    body: axum::Json<Value>,
) -> Response {
    guard!(state, headers);
    let mut state = state.lock().unwrap();
    let body = body.0;
    state.sent_bodies.push(body.clone());
    let request_id = body["request_id"].as_str().unwrap_or_default().to_owned();
    if let Some(existing) = state
        .messages
        .iter()
        .find(|m| m["request_id"].as_str() == Some(&request_id))
    {
        return axum::Json(existing.clone()).into_response();
    }
    let content = json!({"text": body["content"]["text"], "attachments": body["content"]["attachments"].as_array().cloned().unwrap_or_default()});
    let id = state.add(
        OWNER_MEMBER,
        content,
        json!({"request_id": request_id, "reply_to": body.get("reply_to").cloned().unwrap_or(Value::Null)}),
    );
    let created = state
        .messages
        .iter()
        .find(|m| m["id"] == id)
        .unwrap()
        .clone();
    state.push(
        "calpico-message-add",
        json!({"room_id": "room-1", "message": {"account_user_id": OWNER_MEMBER}}),
    );
    axum::Json(created).into_response()
}

async fn upload(
    State(state): State<Shared>,
    headers: HeaderMap,
    mut multipart: Multipart,
) -> Response {
    guard!(state, headers);
    let field = multipart.next_field().await.unwrap().unwrap();
    assert_eq!(field.name(), Some("file"));
    let name = field.file_name().unwrap_or("").to_owned();
    let mime = field.content_type().unwrap_or("").to_owned();
    let bytes = field.bytes().await.unwrap().to_vec();
    let mut state = state.lock().unwrap();
    let id = format!("file-up-{}", state.uploads.len());
    state.uploads.insert(id.clone(), (name, mime, bytes));
    axum::Json(json!({"id": id, "status": "ready"})).into_response()
}

async fn file_info(
    State(state): State<Shared>,
    headers: HeaderMap,
    Path((_room, file)): Path<(String, String)>,
) -> Response {
    guard!(state, headers);
    let state = state.lock().unwrap();
    if file == "gone" {
        return (StatusCode::GONE, axum::Json(json!({"detail": "gone"}))).into_response();
    }
    let host = if state.foreign_download {
        "http://evil.example"
    } else {
        state.base.as_str()
    };
    axum::Json(
        json!({"file_id": file, "download_url": format!("{host}/storage/{file}"),
        "name": "chart.png", "mime_type": "image/png"}),
    )
    .into_response()
}

async fn storage(State(state): State<Shared>, headers: HeaderMap) -> Response {
    if headers.contains_key("authorization") || headers.contains_key("chatgpt-account-id") {
        state.lock().unwrap().storage_saw_auth = true;
    }
    (
        [("content-type", "image/png")],
        Bytes::from_static(b"\x89PNGfake"),
    )
        .into_response()
}

async fn reaction(
    State(state): State<Shared>,
    headers: HeaderMap,
    method: axum::http::Method,
    Path((_room, message)): Path<(String, String)>,
    body: Option<axum::Json<Value>>,
) -> Response {
    guard!(state, headers);
    let emoji = (method == axum::http::Method::POST)
        .then(|| body.and_then(|body| body["reaction"].as_str().map(str::to_owned)))
        .flatten();
    state.lock().unwrap().reactions.push((message, emoji));
    axum::Json(json!({})).into_response()
}

async fn inspect(State(state): State<Shared>, headers: HeaderMap) -> Response {
    guard!(state, headers);
    let elicitation: Value =
        serde_json::from_str(include_str!("fixtures/elicitation.json")).unwrap();
    axum::Json(
        json!({"elicitation": elicitation, "request_fingerprint": "fp-1",
        "can_respond": true, "runtime_status": "pending"}),
    )
    .into_response()
}

async fn respond(
    State(state): State<Shared>,
    headers: HeaderMap,
    body: axum::Json<Value>,
) -> Response {
    guard!(state, headers);
    state.lock().unwrap().elicitation_responses.push(body.0);
    axum::Json(json!({"status": "applied"})).into_response()
}

async fn ws_endpoint(State(state): State<Shared>, headers: HeaderMap) -> Response {
    guard!(state, headers);
    let base = state.lock().unwrap().base.replace("http://", "ws://");
    axum::Json(json!({"websocket_url": format!("{base}/ws?ticket=secret")})).into_response()
}

async fn ws_upgrade(State(state): State<Shared>, upgrade: WebSocketUpgrade) -> Response {
    upgrade.on_upgrade(move |socket| ws_session(state, socket))
}

async fn ws_session(state: Shared, mut socket: WebSocket) {
    let Some(Ok(WsMessage::Text(first))) = socket.recv().await else {
        return;
    };
    let frame: Value = serde_json::from_str(first.as_str()).unwrap();
    assert_eq!(frame[1]["command"]["topic_id"], "calpico-chatgpt-messaging");
    let ack =
        json!([{"id": 2, "reply": {"type": "subscribe", "topic_id": "calpico-chatgpt-messaging"}}]);
    socket
        .send(WsMessage::Text(ack.to_string().into()))
        .await
        .unwrap();
    let (sender, mut frames) = mpsc::unbounded_channel();
    {
        let mut state = state.lock().unwrap();
        state.ws = Some(sender);
        state.ws_connections += 1;
    }
    loop {
        tokio::select! {
            frame = frames.recv() => match frame {
                Some(frame) => if socket.send(WsMessage::Text(frame.into())).await.is_err() { return },
                None => return,
            },
            incoming = socket.recv() => match incoming {
                Some(Ok(WsMessage::Close(_))) | None | Some(Err(_)) => return,
                _ => {}
            }
        }
    }
}

async fn task(State(state): State<Shared>, headers: HeaderMap, Path(id): Path<String>) -> Response {
    guard!(state, headers);
    let status = state.lock().unwrap().task_status.clone();
    let thread_status = if status == "completed" {
        "idle"
    } else {
        "active"
    };
    axum::Json(
        json!({"thread": {"id": id, "name": "Book flights", "updatedAt": 1_700_000_000,
        "status": {"type": thread_status, "activeFlags": []}}}),
    )
    .into_response()
}

async fn turns(State(state): State<Shared>, headers: HeaderMap) -> Response {
    guard!(state, headers);
    let status = state.lock().unwrap().task_status.clone();
    axum::Json(json!({"data": [{"id": "turn-1", "status": status, "startedAt": 1_700_000_000}], "nextCursor": null}))
        .into_response()
}

async fn start() -> (Shared, String) {
    let state: Shared = Arc::new(Mutex::new(FakeState {
        task_status: "inProgress".into(),
        ..Default::default()
    }));
    let baseline: Value = serde_json::from_str(include_str!("fixtures/message.json")).unwrap();
    state.lock().unwrap().messages.push(baseline);
    let app = Router::new()
        .route("/backend-api/tbo/primary", get(primary))
        .route("/backend-api/messaging/rooms/{room}", get(room))
        .route(
            "/backend-api/messaging/rooms/{room}/messages",
            get(list_messages).post(send_message),
        )
        .route("/backend-api/messaging/rooms/{room}/files", post(upload))
        .route(
            "/backend-api/messaging/rooms/{room}/files/{file}",
            get(file_info),
        )
        .route(
            "/backend-api/messaging/rooms/{room}/messages/{message}/reactions",
            post(reaction).delete(reaction),
        )
        .route(
            "/backend-api/messaging/rooms/{room}/messages/{message}/elicitation",
            get(inspect),
        )
        .route(
            "/backend-api/messaging/rooms/{room}/messages/{message}/elicitation/response",
            post(respond),
        )
        .route("/backend-api/celsius/ws/user", get(ws_endpoint))
        .route("/ws", get(ws_upgrade))
        .route("/storage/{file}", get(storage))
        .route("/codex/v1/threads/{id}", get(task))
        .route("/codex/v2/threads/{id}/turns", get(turns))
        .with_state(state.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    state.lock().unwrap().base = base.clone();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (state, base)
}

fn client(base: &str, tokens: Arc<CountingTokens>) -> DotsClient {
    DotsClient::new(
        DotsConfig {
            api_base: Url::parse(&format!("{base}/backend-api/")).unwrap(),
            codex_base: Url::parse(&format!("{base}/codex/")).unwrap(),
            download_host_suffix: "127.0.0.1".into(),
            require_https_downloads: false,
            ..DotsConfig::default()
        },
        tokens,
    )
    .unwrap()
}

fn connector(base: &str) -> Arc<DotsConnector> {
    Arc::new(DotsConnector::new(
        client(base, Arc::new(CountingTokens::default())),
        ConnectorSettings {
            realtime: true,
            realtime_policy: RealtimePolicy {
                host: "127.0.0.1".into(),
                allow_plain: true,
            },
            poll_with_socket: Duration::from_millis(400),
            poll_without_socket: Duration::from_millis(100),
        },
    ))
}

#[derive(Default)]
struct RecordingInline {
    next: Mutex<i64>,
    posts: Mutex<Vec<(i64, InlinePost)>>,
    edits: Mutex<Vec<(i64, String)>>,
    reactions: Mutex<Vec<(i64, String, bool)>>,
    typing: Mutex<Vec<bool>>,
}

impl InlineSide for RecordingInline {
    fn post<'a>(&'a self, post: &'a InlinePost) -> BoxFuture<'a, InlineResult<i64>> {
        Box::pin(async move {
            let mut next = self.next.lock().unwrap();
            *next += 1;
            let id = 5000 + *next;
            self.posts.lock().unwrap().push((id, post.clone()));
            Ok(id)
        })
    }
    fn edit<'a>(
        &'a self,
        id: i64,
        text: &'a str,
        _b: Option<&'a [Vec<Button>]>,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(async move {
            self.edits.lock().unwrap().push((id, text.to_owned()));
            Ok(())
        })
    }
    fn react<'a>(
        &'a self,
        id: i64,
        emoji: &'a str,
        remove: bool,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(async move {
            self.reactions
                .lock()
                .unwrap()
                .push((id, emoji.to_owned(), remove));
            Ok(())
        })
    }
    fn typing(&self, active: bool) -> BoxFuture<'_, InlineResult<()>> {
        Box::pin(async move {
            self.typing.lock().unwrap().push(active);
            Ok(())
        })
    }
    fn answer_action<'a>(
        &'a self,
        _id: i64,
        _toast: Option<&'a str>,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(async { Ok(()) })
    }
    fn fetch_media<'a>(
        &'a self,
        media: &'a InlineMedia,
        _limit: usize,
    ) -> BoxFuture<'a, InlineResult<FileData>> {
        Box::pin(async move {
            Ok(FileData {
                name: media.name.clone().unwrap_or_default(),
                mime: "image/jpeg".into(),
                bytes: b"jpegbytes".to_vec(),
            })
        })
    }
}

async fn eventually(what: &str, mut check: impl FnMut() -> bool) {
    for _ in 0..100 {
        if check() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("timed out waiting for {what}");
}

fn relay(
    connector: Arc<DotsConnector>,
    inline: Arc<RecordingInline>,
    store: Arc<RelayStore>,
) -> Arc<Relay> {
    Arc::new(Relay::new(
        connector,
        inline,
        store,
        RelayConfig {
            owner_user_id: OWNER_INLINE,
            agent_name: "Dot".into(),
            network_name: "ChatGPT".into(),
            request_salt: "bot-7".into(),
            mirror_owner_default: true,
        },
    ))
}

fn spawn(relay: Arc<Relay>) -> tokio::sync::watch::Sender<bool> {
    let (stop, stopped) = tokio::sync::watch::channel(false);
    tokio::spawn(async move {
        relay.recover().await.unwrap();
        relay.run_remote(stopped).await.unwrap();
    });
    stop
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_round_trip_through_fake_chatgpt() {
    let (fake, base) = start().await;
    let inline = Arc::new(RecordingInline::default());
    let dir = tempfile_dir();
    let store = Arc::new(RelayStore::open(&dir.join("relay.sqlite")).unwrap());
    let relay_one = relay(connector(&base), inline.clone(), store.clone());
    let stop = spawn(relay_one.clone());

    eventually("first link", || {
        store.kv_get("connector.checkpoint").unwrap().is_some()
    })
    .await;
    eventually("socket", || fake.lock().unwrap().ws_connections == 1).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(
        inline.posts.lock().unwrap().is_empty(),
        "history before linking is not imported"
    );

    // Dot speaks; the socket wakes the poller.
    let hello = {
        let mut state = fake.lock().unwrap();
        let id = state.add(
            DOT_MEMBER,
            json!({"text": "Hello from Pip", "attachments": []}),
            json!({}),
        );
        state.push(
            "calpico-is-responding-heartbeat",
            json!({"room_id": "room-1", "source": {"role": "user", "account_user_id": DOT_MEMBER}}),
        );
        state.push(
            "calpico-message-add",
            json!({"room_id": "room-1", "message": {"account_user_id": DOT_MEMBER}}),
        );
        id
    };
    eventually("dot message mirrored", || {
        inline.posts.lock().unwrap().len() == 1
    })
    .await;
    let hello_inline = inline.posts.lock().unwrap()[0].0;
    assert_eq!(inline.posts.lock().unwrap()[0].1.text, "Hello from Pip");
    assert!(inline.typing.lock().unwrap().contains(&true));

    // Owner replies from Inline.
    relay_one
        .handle_inline(InlineEvent::Message {
            message_id: 501,
            sender_id: OWNER_INLINE,
            text: "Thanks Pip".into(),
            reply_to: Some(hello_inline),
            media: None,
        })
        .await
        .unwrap();
    {
        let state = fake.lock().unwrap();
        let body = state.sent_bodies.last().unwrap();
        assert_eq!(body["content"]["text"], "Thanks Pip");
        assert_eq!(body["reply_to"]["message_id"], hello.as_str());
        assert_eq!(body["request_id"], body["idempotency_token"]);
        assert_eq!(body["request_id"], correlation_id("bot-7", 501).as_str());
    }
    let owner_remote = store.remote_for_inline(501).unwrap().unwrap();

    // The Dot reacts to the owner's message.
    {
        let mut state = fake.lock().unwrap();
        let message = state
            .messages
            .iter_mut()
            .find(|m| m["id"] == owner_remote.as_str())
            .unwrap();
        message["reactions"] = json!({DOT_MEMBER: "👍"});
        state.push("calpico-message-update", json!({"room_id": "room-1"}));
    }
    eventually("dot reaction mirrored", || {
        inline
            .reactions
            .lock()
            .unwrap()
            .contains(&(501, "👍".into(), false))
    })
    .await;
    assert_eq!(
        inline.posts.lock().unwrap().len(),
        1,
        "echo of owner message not mirrored"
    );

    // Owner reacts in Inline.
    relay_one
        .handle_inline(InlineEvent::Reaction {
            message_id: hello_inline,
            user_id: OWNER_INLINE,
            emoji: "🎉".into(),
            removed: false,
        })
        .await
        .unwrap();
    assert_eq!(
        fake.lock().unwrap().reactions,
        vec![(hello.clone(), Some("🎉".into()))]
    );

    // Owner sends a photo.
    relay_one
        .handle_inline(InlineEvent::Message {
            message_id: 502,
            sender_id: OWNER_INLINE,
            text: "the receipt".into(),
            reply_to: None,
            media: Some(InlineMedia {
                url: Some("https://cdn.inline.chat/x".into()),
                name: Some("receipt.jpg".into()),
                mime: Some("image/jpeg".into()),
                size: Some(9),
            }),
        })
        .await
        .unwrap();
    {
        let state = fake.lock().unwrap();
        let (name, mime, bytes) = state.uploads.get("file-up-0").unwrap();
        assert_eq!(
            (name.as_str(), mime.as_str(), bytes.as_slice()),
            ("receipt.jpg", "image/jpeg", &b"jpegbytes"[..])
        );
        let body = state.sent_bodies.last().unwrap();
        assert_eq!(
            body["content"]["attachments"][0],
            json!({"type": "file", "file_id": "file-up-0"})
        );
    }

    // Dot sends a file.
    fake.lock().unwrap().add(
        DOT_MEMBER,
        json!({"text": "", "attachments": [{"type": "file", "file_id": "file-dot-1", "attachment_id": "att-1"}]}),
        json!({}),
    );
    eventually("dot file mirrored", || {
        inline.posts.lock().unwrap().iter().any(|(_, post)| {
            post.file
                .as_ref()
                .is_some_and(|file| file.bytes == b"\x89PNGfake")
        })
    })
    .await;
    assert!(
        !fake.lock().unwrap().storage_saw_auth,
        "storage never sees ChatGPT credentials"
    );

    // Dot asks for confirmation.
    let elicitation: Value =
        serde_json::from_str(include_str!("fixtures/elicitation.json")).unwrap();
    fake.lock().unwrap().add(
        DOT_MEMBER,
        json!({"text": "I drafted the email.", "attachments": [], "elicitation": elicitation}),
        json!({}),
    );
    eventually("confirmation card", || {
        inline
            .posts
            .lock()
            .unwrap()
            .iter()
            .any(|(_, post)| !post.buttons.is_empty())
    })
    .await;
    let (card_id, card) = inline
        .posts
        .lock()
        .unwrap()
        .iter()
        .find(|(_, post)| !post.buttons.is_empty())
        .cloned()
        .unwrap();
    assert!(card.text.contains("Send email") && card.text.contains("sam@example.com"));
    relay_one
        .handle_inline(InlineEvent::Action {
            interaction_id: 1,
            message_id: card_id,
            actor_id: OWNER_INLINE,
            data: card.buttons[0][0].data.clone(),
        })
        .await
        .unwrap();
    {
        let state = fake.lock().unwrap();
        assert_eq!(
            state.elicitation_responses,
            vec![
                json!({"request_fingerprint": "fp-1", "result": {"action": "accept", "content": {"confirmed": true}, "_meta": null}})
            ]
        );
    }
    assert!(
        inline
            .edits
            .lock()
            .unwrap()
            .iter()
            .any(|(id, text)| *id == card_id && text.ends_with("_✅ Approved._"))
    );

    // Dot starts a task; the card follows the task backend.
    fake.lock().unwrap().add(
        DOT_MEMBER,
        json!({"text": "Working on it.", "attachments": [{"type": "thread", "thread_id": "task-1"}]}),
        json!({}),
    );
    eventually("task card", || {
        inline
            .posts
            .lock()
            .unwrap()
            .iter()
            .any(|(_, post)| post.text == "🗂 **Book flights**\nWorking…")
    })
    .await;
    fake.lock().unwrap().task_status = "completed".into();
    eventually("task card completed", || {
        inline
            .edits
            .lock()
            .unwrap()
            .iter()
            .any(|(_, text)| text == "🗂 **Book flights**\nCompleted")
    })
    .await;

    // The owner types in ChatGPT itself.
    fake.lock().unwrap().add(
        OWNER_MEMBER,
        json!({"text": "from my phone", "attachments": []}),
        json!({}),
    );
    eventually("owner mirror", || {
        inline
            .posts
            .lock()
            .unwrap()
            .iter()
            .any(|(_, post)| post.text == "_You, in ChatGPT:_\n> from my phone")
    })
    .await;

    assert!(
        fake.lock().unwrap().bad_headers.is_empty(),
        "every request carried Beeper-shaped headers and our UA"
    );

    // Restart on the same store: nothing is posted twice.
    stop.send(true).unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    let before = inline.posts.lock().unwrap().len();
    let stop_two = spawn(relay(connector(&base), inline.clone(), store.clone()));
    eventually("second socket", || fake.lock().unwrap().ws_connections == 2).await;
    tokio::time::sleep(Duration::from_millis(800)).await;
    assert_eq!(
        inline.posts.lock().unwrap().len(),
        before,
        "restart re-mirrors nothing"
    );
    stop_two.send(true).unwrap();
}

#[tokio::test]
async fn unauthorized_refreshes_token_once() {
    let (fake, base) = start().await;
    let tokens = Arc::new(CountingTokens::default());
    let client = client(&base, tokens.clone());
    fake.lock().unwrap().unauthorized_once = true;
    let (selection, profile) = client.primary().await.unwrap();
    assert_eq!(selection.messaging_room_id, "room-1");
    assert_eq!(profile.unwrap().name(), "Pip");
    assert_eq!(tokens.forced.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn challenge_page_is_reported_not_worked_around() {
    let (fake, base) = start().await;
    let client = client(&base, Arc::new(CountingTokens::default()));
    fake.lock().unwrap().challenge = true;
    assert!(matches!(
        client.primary().await,
        Err(DotsError::Challenge { .. })
    ));
}

#[tokio::test]
async fn downloads_only_from_file_storage() {
    let (fake, base) = start().await;
    let client = client(&base, Arc::new(CountingTokens::default()));
    fake.lock().unwrap().foreign_download = true;
    assert!(matches!(
        client.download("room-1", "f1").await,
        Err(DotsError::Protocol(_))
    ));
    fake.lock().unwrap().foreign_download = false;
    assert!(client.download("room-1", "gone").await.unwrap().is_none());
    assert_eq!(
        client
            .download("room-1", "f1")
            .await
            .unwrap()
            .unwrap()
            .bytes,
        b"\x89PNGfake"
    );
}

#[tokio::test]
async fn discovery_verifies_the_room() {
    let (_fake, base) = start().await;
    let room = inline_dots::discover(&client(&base, Arc::new(CountingTokens::default())))
        .await
        .unwrap();
    assert_eq!(room.dot_member, DOT_MEMBER);
    assert_eq!(room.owner_member, OWNER_MEMBER);
    assert_eq!(room.name, "Pip");
    assert!(!room.paused);
}

#[test]
fn fixture_elicitation_is_a_yes_no_confirmation() {
    let raw: Value = serde_json::from_str(include_str!("fixtures/elicitation.json")).unwrap();
    let parsed = inline_dots::types::Elicitation::parse(&raw).unwrap();
    assert_eq!(parsed.accept_content, Some(json!({"confirmed": true})));
    assert_eq!(parsed.title.as_deref(), Some("Send email"));
    assert!(parsed.is_pending());
    let mut richer = raw.clone();
    richer["params"]["requestedSchema"]["properties"]["note"] = json!({"type": "string"});
    assert!(
        inline_dots::types::Elicitation::parse(&richer)
            .unwrap()
            .accept_content
            .is_none()
    );
}

fn tempfile_dir() -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "inline-dots-test-{}-{}",
        std::process::id(),
        rand_suffix()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn rand_suffix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos() as u64
}
