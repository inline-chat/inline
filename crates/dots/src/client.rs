//! HTTP client for the Dot endpoints on `chatgpt.com/backend-api`.

use std::sync::Arc;
use std::time::Duration;

use reqwest::{Method, StatusCode, header};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use tokio::sync::Mutex;
use url::Url;

use crate::auth::{AccessToken, Identity, TokenSource};
use crate::error::{DotsError, DotsResult};
use crate::types::*;

/// Production API base.
pub const CHATGPT_API_BASE: &str = "https://chatgpt.com/backend-api/";
/// Production task backend.
pub const CODEX_CLOUD_BASE: &str = "https://codex-cloud-backend.chatgpt.com/";
/// Largest file the bridge moves in either direction.
pub const MAX_FILE_BYTES: usize = 20 * 1024 * 1024;
const MAX_JSON_BYTES: usize = 4 * 1024 * 1024;
const REFRESH_MARGIN: Duration = Duration::from_secs(5 * 60);

/// Endpoints and identity of this client.
#[derive(Clone, Debug)]
pub struct DotsConfig {
    /// API base, ending in `/`.
    pub api_base: Url,
    /// Task backend base, ending in `/`.
    pub codex_base: Url,
    /// Honest client name; never a browser or app user agent.
    pub user_agent: String,
    /// Accept download URLs on this host suffix (production:
    /// `.oaiusercontent.com`). Tests point it at the fake server.
    pub download_host_suffix: String,
    /// Require `https` for download URLs.
    pub require_https_downloads: bool,
}

impl Default for DotsConfig {
    fn default() -> Self {
        Self {
            api_base: Url::parse(CHATGPT_API_BASE).expect("valid"),
            codex_base: Url::parse(CODEX_CLOUD_BASE).expect("valid"),
            user_agent: format!("InlineDotsBridge/{}", env!("CARGO_PKG_VERSION")),
            download_host_suffix: ".oaiusercontent.com".into(),
            require_https_downloads: true,
        }
    }
}

/// Query for `GET /messaging/rooms/{room}/messages`.
#[derive(Clone, Debug, Default)]
pub struct MessageQuery {
    /// Page size (server caps at 32).
    pub limit: u32,
    /// Newer than this message id or cursor.
    pub after: Option<String>,
    /// Older than this cursor.
    pub before: Option<String>,
    /// Page around this message id.
    pub around: Option<String>,
    /// Only replies under this root.
    pub reply_root_message_id: Option<String>,
}

/// Outgoing message.
#[derive(Clone, Debug)]
pub struct SendMessage {
    /// Text, or caption when `file_ids` is non-empty.
    pub text: String,
    /// Files from [`DotsClient::upload`].
    pub file_ids: Vec<String>,
    /// Stable client id; reuse it when retrying the same message.
    pub request_id: String,
    /// Parent message.
    pub reply_to: Option<String>,
}

struct Session {
    token: AccessToken,
    identity: Identity,
}

/// ChatGPT Dots client. Cheap to clone.
#[derive(Clone)]
pub struct DotsClient {
    http: reqwest::Client,
    config: Arc<DotsConfig>,
    tokens: Arc<dyn TokenSource>,
    session: Arc<Mutex<Option<Session>>>,
}

impl std::fmt::Debug for DotsClient {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("DotsClient")
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Retry {
    /// Refresh the token and retry once after a 401.
    OnUnauthorized,
    /// Never resend (answers to confirmations).
    Never,
}

impl DotsClient {
    /// Builds a client.
    pub fn new(config: DotsConfig, tokens: Arc<dyn TokenSource>) -> DotsResult<Self> {
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(30))
            .connect_timeout(Duration::from_secs(15))
            .user_agent(config.user_agent.clone())
            .build()?;
        Ok(Self {
            http,
            config: Arc::new(config),
            tokens,
            session: Arc::new(Mutex::new(None)),
        })
    }

    /// Current identity, fetching a token if needed.
    pub async fn identity(&self) -> DotsResult<Identity> {
        Ok(self.session(false).await?.1)
    }

    async fn session(&self, force: bool) -> DotsResult<(AccessToken, Identity)> {
        let mut guard = self.session.lock().await;
        if !force
            && let Some(session) = guard.as_ref()
            && session.identity.remaining() > REFRESH_MARGIN
        {
            return Ok((session.token.clone(), session.identity.clone()));
        }
        let near_expiry = guard.is_some() && !force;
        let token = self.tokens.token(force || near_expiry).await?;
        let identity = token.identity()?;
        if let Some(previous) = guard.as_ref()
            && previous.identity.account_id != identity.account_id
        {
            return Err(DotsError::NotSignedIn(
                "Codex is now signed in to a different ChatGPT account".into(),
            ));
        }
        *guard = Some(Session {
            token: token.clone(),
            identity: identity.clone(),
        });
        Ok((token, identity))
    }

    fn api(&self, segments: &[&str]) -> Url {
        join(&self.config.api_base, segments)
    }

    async fn call<T: DeserializeOwned>(
        &self,
        method: Method,
        endpoint: &'static str,
        url: Url,
        body: Option<Body<'_>>,
        retry: Retry,
    ) -> DotsResult<T> {
        let value = self.call_raw(method, endpoint, url, body, retry).await?;
        serde_json::from_value(value)
            .map_err(|error| DotsError::Protocol(format!("{endpoint}: {error}")))
    }

    async fn call_raw(
        &self,
        method: Method,
        endpoint: &'static str,
        url: Url,
        body: Option<Body<'_>>,
        retry: Retry,
    ) -> DotsResult<Value> {
        let mut forced = false;
        loop {
            let (token, identity) = self.session(forced).await?;
            let mut request = self
                .http
                .request(method.clone(), url.clone())
                .bearer_auth(token.expose())
                .header("ChatGPT-Account-Id", &identity.account_id)
                .header("X-OpenAI-Expected-Account-Id", &identity.account_id);
            if url.host_str() == self.config.codex_base.host_str()
                && url.host_str() != self.config.api_base.host_str()
            {
                request = request.header("X-OpenAI-Product-Sku", "unknown");
            }
            request = match &body {
                None => request,
                Some(Body::Json(value)) => request.json(value),
                Some(Body::File { name, mime, bytes }) => {
                    let part = reqwest::multipart::Part::bytes(bytes.to_vec())
                        .file_name(name.to_string())
                        .mime_str(mime)
                        .map_err(|_| DotsError::Attachment("invalid MIME type".into()))?;
                    request.multipart(reqwest::multipart::Form::new().part("file", part))
                }
            };
            let response = request.send().await?;
            let status = response.status();
            if status == StatusCode::UNAUTHORIZED && retry == Retry::OnUnauthorized && !forced {
                forced = true;
                continue;
            }
            return read_json(endpoint, response).await;
        }
    }

    /// `GET /tbo/primary`, with identity checks. Maps the "no Dot" 404 to
    /// [`DotsError::NoPrimaryDot`].
    pub async fn primary(&self) -> DotsResult<(PrimarySelection, Option<Profile>)> {
        let primary: Primary = match self
            .call(
                Method::GET,
                "/tbo/primary",
                self.api(&["tbo", "primary"]),
                None,
                Retry::OnUnauthorized,
            )
            .await
        {
            Err(DotsError::Http {
                status: 404,
                detail: Some(detail),
                ..
            }) if detail == "Not Found" => return Err(DotsError::NoPrimaryDot),
            other => other?,
        };
        let selection = primary
            .selection
            .filter(|selection| selection.available)
            .ok_or(DotsError::NoPrimaryDot)?;
        if selection.thread_id.is_empty()
            || selection.aeon_id.is_empty()
            || selection.messaging_room_id.is_empty()
        {
            return Err(DotsError::Protocol("primary Dot has incomplete ids".into()));
        }
        Ok((selection, primary.profile))
    }

    /// `GET /tbo/by-thread/{thread}`.
    pub async fn profile(&self, thread_id: &str) -> DotsResult<Profile> {
        self.call(
            Method::GET,
            "/tbo/by-thread/{thread}",
            self.api(&["tbo", "by-thread", thread_id]),
            None,
            Retry::OnUnauthorized,
        )
        .await
    }

    /// `GET /messaging/rooms/{room}`.
    pub async fn room(&self, room_id: &str) -> DotsResult<Room> {
        self.call(
            Method::GET,
            "/messaging/rooms/{room}",
            self.api(&["messaging", "rooms", room_id]),
            None,
            Retry::OnUnauthorized,
        )
        .await
    }

    /// `GET /messaging/rooms/{room}/messages`.
    pub async fn messages(&self, room_id: &str, query: &MessageQuery) -> DotsResult<Page> {
        let mut url = self.api(&["messaging", "rooms", room_id, "messages"]);
        {
            let mut pairs = url.query_pairs_mut();
            pairs.append_pair("limit", &query.limit.clamp(1, 32).to_string());
            for (key, value) in [
                ("after", &query.after),
                ("before", &query.before),
                ("around", &query.around),
                ("reply_root_message_id", &query.reply_root_message_id),
            ] {
                if let Some(value) = value {
                    pairs.append_pair(key, value);
                }
            }
        }
        self.call(
            Method::GET,
            "/messaging/rooms/{room}/messages",
            url,
            None,
            Retry::OnUnauthorized,
        )
        .await
    }

    /// Fetches one message by id via an `around` page.
    pub async fn message(&self, room_id: &str, message_id: &str) -> DotsResult<Option<Message>> {
        let page = self
            .messages(
                room_id,
                &MessageQuery {
                    limit: 32,
                    around: Some(message_id.into()),
                    ..Default::default()
                },
            )
            .await?;
        Ok(page.items.into_iter().find(|item| item.id == message_id))
    }

    /// `POST /messaging/rooms/{room}/messages`. Verifies the response echoes
    /// `request_id`; a mismatch is reported as a protocol error, which the
    /// caller must treat as "delivery unknown".
    pub async fn send(&self, room_id: &str, message: &SendMessage) -> DotsResult<Message> {
        let body = SendBody {
            content: SendContent {
                text: message.text.clone(),
                attachments: message
                    .file_ids
                    .iter()
                    .map(|file_id| FileRef {
                        kind: "file",
                        file_id: file_id.clone(),
                    })
                    .collect(),
            },
            request_id: message.request_id.clone(),
            idempotency_token: message.request_id.clone(),
            reply_to: message
                .reply_to
                .clone()
                .map(|message_id| ReplyTo { message_id }),
            timezone_offset_min: timezone_offset_min(),
        };
        let created: Message = self
            .call(
                Method::POST,
                "/messaging/rooms/{room}/messages",
                self.api(&["messaging", "rooms", room_id, "messages"]),
                Some(Body::Json(
                    serde_json::to_value(&body).expect("serializable"),
                )),
                Retry::OnUnauthorized,
            )
            .await?;
        if created.id.is_empty() || created.request_id.as_deref() != Some(&message.request_id) {
            return Err(DotsError::Protocol(
                "sent message did not echo its request id".into(),
            ));
        }
        Ok(created)
    }

    /// `POST /messaging/rooms/{room}/files`; returns the file id.
    pub async fn upload(
        &self,
        room_id: &str,
        name: &str,
        mime: &str,
        bytes: &[u8],
    ) -> DotsResult<String> {
        if bytes.len() > MAX_FILE_BYTES {
            return Err(DotsError::Attachment(format!(
                "file is larger than {} MiB",
                MAX_FILE_BYTES / 1024 / 1024
            )));
        }
        let name = sanitize_file_name(name)?;
        let mime = mime.split(';').next().unwrap_or("").trim();
        let mime = if mime.is_empty() {
            "application/octet-stream"
        } else {
            mime
        };
        let value = self
            .call_raw(
                Method::POST,
                "/messaging/rooms/{room}/files",
                self.api(&["messaging", "rooms", room_id, "files"]),
                Some(Body::File {
                    name: &name,
                    mime,
                    bytes,
                }),
                Retry::OnUnauthorized,
            )
            .await?;
        value
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .map(str::to_owned)
            .ok_or_else(|| DotsError::Protocol("upload returned no file id".into()))
    }

    /// Resolves and downloads a room file. Returns `Ok(None)` when the file
    /// is gone for good (404/410) and [`DotsError::Network`] while it is
    /// still processing.
    pub async fn download(
        &self,
        room_id: &str,
        file_id: &str,
    ) -> DotsResult<Option<DownloadedFile>> {
        let info: FileInfo = match self
            .call(
                Method::GET,
                "/messaging/rooms/{room}/files/{file}",
                self.api(&["messaging", "rooms", room_id, "files", file_id]),
                None,
                Retry::OnUnauthorized,
            )
            .await
        {
            Err(DotsError::Http {
                status: 404 | 410, ..
            }) => return Ok(None),
            other => other?,
        };
        for echoed in [&info.id, &info.file_id].into_iter().flatten() {
            if echoed != file_id {
                return Err(DotsError::Protocol("file info id mismatch".into()));
            }
        }
        let Some(raw_url) = info.download_url.filter(|url| !url.is_empty()) else {
            return Err(DotsError::Network("file is still processing".into()));
        };
        let url = self.check_download_url(&raw_url)?;
        // Storage URLs are pre-signed; never send ChatGPT credentials there.
        let response = self.http.get(url).send().await?;
        if !response.status().is_success() {
            return Err(DotsError::Network(format!(
                "file storage returned HTTP {}",
                response.status().as_u16()
            )));
        }
        if response
            .content_length()
            .is_some_and(|length| length as usize > MAX_FILE_BYTES)
        {
            return Err(DotsError::Attachment("file is larger than 20 MiB".into()));
        }
        let header_mime = response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .map(|value| value.split(';').next().unwrap_or("").trim().to_owned());
        let bytes = read_limited(response, MAX_FILE_BYTES).await?;
        let mime = info
            .mime_type
            .filter(|mime| !matches!(mime.as_str(), "" | "application/octet-stream"))
            .or(header_mime)
            .unwrap_or_else(|| "application/octet-stream".into());
        Ok(Some(DownloadedFile {
            name: info.name.unwrap_or_else(|| "attachment".into()),
            mime,
            bytes,
        }))
    }

    fn check_download_url(&self, raw: &str) -> DotsResult<Url> {
        let url = Url::parse(raw).map_err(|_| DotsError::Protocol("bad download URL".into()))?;
        let host = url.host_str().unwrap_or("");
        let host_ok = host == self.config.download_host_suffix.trim_start_matches('.')
            || host.ends_with(&self.config.download_host_suffix);
        let scheme_ok = url.scheme() == "https"
            || (!self.config.require_https_downloads && url.scheme() == "http");
        if !host_ok
            || !scheme_ok
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
            || (self.config.require_https_downloads && url.port().is_some())
        {
            return Err(DotsError::Protocol(
                "download URL is not on ChatGPT file storage".into(),
            ));
        }
        Ok(url)
    }

    /// Sets (or replaces) the owner's reaction.
    pub async fn react(&self, room_id: &str, message_id: &str, emoji: &str) -> DotsResult<()> {
        self.call_raw(
            Method::POST,
            "/messaging/rooms/{room}/messages/{message}/reactions",
            self.api(&[
                "messaging",
                "rooms",
                room_id,
                "messages",
                message_id,
                "reactions",
            ]),
            Some(Body::Json(json!({ "reaction": emoji }))),
            Retry::OnUnauthorized,
        )
        .await
        .map(drop)
    }

    /// Clears the owner's reaction.
    pub async fn unreact(&self, room_id: &str, message_id: &str) -> DotsResult<()> {
        self.call_raw(
            Method::DELETE,
            "/messaging/rooms/{room}/messages/{message}/reactions",
            self.api(&[
                "messaging",
                "rooms",
                room_id,
                "messages",
                message_id,
                "reactions",
            ]),
            None,
            Retry::OnUnauthorized,
        )
        .await
        .map(drop)
    }

    /// Reads a confirmation's live state.
    pub async fn inspect_elicitation(
        &self,
        room_id: &str,
        message_id: &str,
    ) -> DotsResult<ElicitationState> {
        let mut url = self.api(&[
            "messaging",
            "rooms",
            room_id,
            "messages",
            message_id,
            "elicitation",
        ]);
        url.query_pairs_mut().append_pair("inspect", "true");
        let state: ElicitationState = self
            .call(
                Method::GET,
                "/messaging/rooms/{room}/messages/{message}/elicitation",
                url,
                None,
                Retry::OnUnauthorized,
            )
            .await?;
        if state.request_fingerprint.is_empty() || state.runtime_status.is_empty() {
            return Err(DotsError::Protocol("incomplete confirmation state".into()));
        }
        Ok(state)
    }

    /// Answers a confirmation. Never resent, even after a 401: an answer is
    /// not idempotent. Returns the server status; only `applied` is success.
    pub async fn respond_elicitation(
        &self,
        room_id: &str,
        message_id: &str,
        fingerprint: &str,
        decision: Decision,
        accept_content: &Value,
    ) -> DotsResult<String> {
        let result = match decision {
            Decision::Accept => {
                json!({"action": "accept", "content": accept_content, "_meta": null})
            }
            Decision::Decline => json!({"action": "decline", "content": null, "_meta": null}),
        };
        let value = self
            .call_raw(
                Method::POST,
                "/messaging/rooms/{room}/messages/{message}/elicitation/response",
                self.api(&[
                    "messaging",
                    "rooms",
                    room_id,
                    "messages",
                    message_id,
                    "elicitation",
                    "response",
                ]),
                Some(Body::Json(
                    json!({"request_fingerprint": fingerprint, "result": result}),
                )),
                Retry::Never,
            )
            .await?;
        Ok(value
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned())
    }

    /// `POST /messaging/rooms/{room}/responding_heartbeat`: the owner is
    /// typing. The ChatGPT apps send it with no body.
    pub async fn responding_heartbeat(&self, room_id: &str) -> DotsResult<()> {
        self.call_raw(
            Method::POST,
            "/messaging/rooms/{room}/responding_heartbeat",
            self.api(&["messaging", "rooms", room_id, "responding_heartbeat"]),
            None,
            Retry::OnUnauthorized,
        )
        .await
        .map(drop)
    }

    /// `POST /messaging/rooms/{room}/read {last_read_at}`.
    pub async fn mark_read(&self, room_id: &str, last_read_at: &str) -> DotsResult<()> {
        self.call_raw(
            Method::POST,
            "/messaging/rooms/{room}/read",
            self.api(&["messaging", "rooms", room_id, "read"]),
            Some(Body::Json(json!({ "last_read_at": last_read_at }))),
            Retry::OnUnauthorized,
        )
        .await
        .map(drop)
    }

    /// Downloads a Dot avatar from OpenAI's asset hosts, without credentials.
    pub async fn avatar(&self, raw_url: &str) -> DotsResult<DownloadedFile> {
        let url = Url::parse(raw_url).map_err(|_| DotsError::Protocol("bad avatar URL".into()))?;
        let host = url.host_str().unwrap_or("");
        let trusted = host == "cdn.openai.com"
            || host.ends_with(".oaiusercontent.com")
            || host.ends_with(".oaistatic.com")
            || (!self.config.require_https_downloads
                && host == self.config.download_host_suffix.trim_start_matches('.'));
        if !trusted || (url.scheme() != "https" && self.config.require_https_downloads) {
            return Err(DotsError::Protocol(
                "avatar is not on an OpenAI asset host".into(),
            ));
        }
        let response = self.http.get(url).send().await?;
        if !response.status().is_success() {
            return Err(DotsError::Network(format!(
                "avatar download returned HTTP {}",
                response.status().as_u16()
            )));
        }
        let mime = response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .map(|value| value.split(';').next().unwrap_or("").trim().to_owned())
            .unwrap_or_default();
        if !mime.starts_with("image/") {
            return Err(DotsError::Protocol("avatar is not an image".into()));
        }
        let bytes = read_limited(response, 4 * 1024 * 1024).await?;
        let extension = mime.trim_start_matches("image/").replace("jpeg", "jpg");
        Ok(DownloadedFile {
            name: format!("dot-avatar.{extension}"),
            mime,
            bytes,
        })
    }

    /// Prompt and final answer of the latest task turns, oldest first.
    pub async fn task_transcript(
        &self,
        thread_id: &str,
        turns: u32,
    ) -> DotsResult<Vec<TaskTurnEntry>> {
        let mut url = join(
            &self.config.codex_base,
            &["v2", "threads", thread_id, "turns"],
        );
        url.query_pairs_mut()
            .append_pair("limit", &turns.clamp(1, 20).to_string())
            .append_pair("sortDirection", "desc")
            .append_pair("itemsView", "full");
        let value: Value = self
            .call(
                Method::GET,
                "/v2/threads/{thread}/turns",
                url,
                None,
                Retry::OnUnauthorized,
            )
            .await?;
        let data = value
            .get("data")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        Ok(data.iter().rev().flat_map(turn_entries).collect())
    }

    /// `GET /celsius/ws/user`.
    pub async fn realtime_endpoint(&self) -> DotsResult<Url> {
        let endpoint: RealtimeEndpoint = self
            .call(
                Method::GET,
                "/celsius/ws/user",
                self.api(&["celsius", "ws", "user"]),
                None,
                Retry::OnUnauthorized,
            )
            .await?;
        Url::parse(&endpoint.websocket_url)
            .map_err(|_| DotsError::Protocol("bad websocket URL".into()))
    }

    /// Task summary from the Codex cloud backend.
    pub async fn task(&self, thread_id: &str) -> DotsResult<TaskSummary> {
        let thread: Value = self
            .call(
                Method::GET,
                "/v1/threads/{thread}",
                join(&self.config.codex_base, &["v1", "threads", thread_id]),
                None,
                Retry::OnUnauthorized,
            )
            .await?;
        let thread = thread
            .get("thread")
            .ok_or_else(|| DotsError::Protocol("task response has no thread".into()))?;
        if thread.get("id").and_then(Value::as_str) != Some(thread_id) {
            return Err(DotsError::Protocol("task id mismatch".into()));
        }
        let status = thread.get("status").unwrap_or(&Value::Null);
        let status_type = status.get("type").and_then(Value::as_str).unwrap_or("");
        if status_type.is_empty() {
            return Err(DotsError::Protocol("task has no status".into()));
        }
        let mut turns = join(
            &self.config.codex_base,
            &["v2", "threads", thread_id, "turns"],
        );
        turns
            .query_pairs_mut()
            .append_pair("limit", "1")
            .append_pair("sortDirection", "desc")
            .append_pair("itemsView", "notLoaded");
        let turns: Value = self
            .call(
                Method::GET,
                "/v2/threads/{thread}/turns",
                turns,
                None,
                Retry::OnUnauthorized,
            )
            .await?;
        let latest_turn_status = turns
            .get("data")
            .and_then(Value::as_array)
            .and_then(|data| data.first())
            .and_then(|turn| turn.get("status"))
            .and_then(Value::as_str);
        let has_flags = status
            .get("activeFlags")
            .and_then(Value::as_array)
            .is_some_and(|flags| !flags.is_empty());
        let derived = derive_task_status(status_type, has_flags, latest_turn_status)?;
        Ok(TaskSummary {
            id: thread_id.into(),
            title: thread
                .get("name")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .map(str::to_owned),
            status: derived,
            updated_at: thread.get("updatedAt").and_then(Value::as_i64).unwrap_or(0),
        })
    }
}

/// Extracts the prompt and, once the turn finished, its final answer.
pub fn turn_entries(turn: &Value) -> Vec<TaskTurnEntry> {
    let Some(turn_id) = turn.get("id").and_then(Value::as_str) else {
        return Vec::new();
    };
    let finished = turn
        .get("status")
        .and_then(Value::as_str)
        .and_then(TaskStatus::parse)
        .is_some_and(TaskStatus::is_terminal);
    let items = turn
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut prompt = None;
    let mut answer = None;
    for item in &items {
        match item.get("type").and_then(Value::as_str).unwrap_or("") {
            "userMessage" if prompt.is_none() => {
                let text = content_text(item);
                if !text.is_empty() {
                    prompt = Some(text);
                }
            }
            "functionCallOutput"
                if prompt.is_none()
                    && item.get("namespace").and_then(Value::as_str) == Some("cloud_threads")
                    && item.get("name").and_then(Value::as_str) == Some("send_message") =>
            {
                let output = item.get("output").and_then(Value::as_str).unwrap_or("");
                if let Some(inner) = output
                    .split_once("<input>")
                    .and_then(|(_, rest)| rest.split_once("</input>"))
                    .map(|(inner, _)| unescape_html(inner.trim()))
                    .filter(|inner| !inner.is_empty())
                {
                    prompt = Some(inner);
                }
            }
            "agentMessage" if finished => {
                let text = item
                    .get("text")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .unwrap_or_else(|| content_text(item));
                if !text.trim().is_empty() {
                    let is_final =
                        item.get("phase").and_then(Value::as_str) == Some("final_answer");
                    answer = Some(text);
                    if is_final {
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    let mut entries = Vec::new();
    if let Some(text) = prompt {
        entries.push(TaskTurnEntry {
            id: format!("{turn_id}:prompt"),
            prompt: true,
            text,
        });
    }
    if let Some(text) = answer {
        entries.push(TaskTurnEntry {
            id: format!("{turn_id}:answer"),
            prompt: false,
            text,
        });
    }
    entries
}

fn content_text(item: &Value) -> String {
    item.get("content")
        .and_then(Value::as_array)
        .map(|parts| {
            parts
                .iter()
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
        .trim()
        .to_owned()
}

fn unescape_html(text: &str) -> String {
    text.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&amp;", "&")
}

/// JavaScript `Date#getTimezoneOffset`: minutes to add to local time for UTC.
pub fn timezone_offset_min() -> i32 {
    -(chrono::Local::now().offset().local_minus_utc() / 60)
}

/// Status precedence: thread error and active state win over the latest turn.
pub fn derive_task_status(
    status_type: &str,
    has_active_flags: bool,
    latest_turn_status: Option<&str>,
) -> DotsResult<TaskStatus> {
    Ok(match status_type {
        "systemError" => TaskStatus::Failed,
        "active" if has_active_flags => TaskStatus::NeedsInput,
        "active" => TaskStatus::InProgress,
        _ => match latest_turn_status {
            None => TaskStatus::Thinking,
            Some(turn) => TaskStatus::parse(turn)
                .ok_or_else(|| DotsError::Protocol("unknown task status".into()))?,
        },
    })
}

/// Bytes of a downloaded room file.
#[derive(Clone)]
pub struct DownloadedFile {
    /// Original name.
    pub name: String,
    /// MIME type.
    pub mime: String,
    /// Content.
    pub bytes: Vec<u8>,
}

impl std::fmt::Debug for DownloadedFile {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("DownloadedFile")
            .field("mime", &self.mime)
            .field("len", &self.bytes.len())
            .finish_non_exhaustive()
    }
}

enum Body<'a> {
    Json(Value),
    File {
        name: &'a str,
        mime: &'a str,
        bytes: &'a [u8],
    },
}

fn join(base: &Url, segments: &[&str]) -> Url {
    let mut url = base.clone();
    {
        let mut path = url.path_segments_mut().expect("base URL can hold a path");
        path.pop_if_empty();
        for segment in segments {
            path.push(segment);
        }
    }
    url
}

/// Cleans a file name for the multipart header.
pub fn sanitize_file_name(name: &str) -> DotsResult<String> {
    let cleaned: String = name
        .chars()
        .map(|c| match c {
            '"' => '\'',
            '/' | '\\' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .collect();
    let cleaned = cleaned.trim();
    if cleaned.len() > 255 {
        return Err(DotsError::Attachment("file name is too long".into()));
    }
    Ok(if cleaned.is_empty() {
        "attachment".into()
    } else {
        cleaned.into()
    })
}

async fn read_limited(response: reqwest::Response, limit: usize) -> DotsResult<Vec<u8>> {
    use futures_util::StreamExt;
    let mut stream = response.bytes_stream();
    let mut bytes = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if bytes.len() + chunk.len() > limit {
            return Err(DotsError::Attachment("response is too large".into()));
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

async fn read_json(endpoint: &'static str, response: reqwest::Response) -> DotsResult<Value> {
    let status = response.status();
    let headers = response.headers().clone();
    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("")
        .to_owned();
    if headers
        .get("cf-mitigated")
        .and_then(|value| value.to_str().ok())
        == Some("challenge")
        || (!status.is_success() && content_type.starts_with("text/html"))
    {
        return Err(DotsError::Challenge { endpoint });
    }
    if status == StatusCode::TOO_MANY_REQUESTS {
        let retry_after = headers
            .get(header::RETRY_AFTER)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.trim().parse::<u64>().ok())
            .map(Duration::from_secs);
        return Err(DotsError::RateLimited {
            endpoint,
            retry_after,
        });
    }
    let bytes = read_limited(response, MAX_JSON_BYTES).await?;
    let value: Option<Value> = serde_json::from_slice(&bytes).ok();
    if !status.is_success() {
        let detail = value.as_ref().and_then(error_detail);
        return Err(DotsError::Http {
            status: status.as_u16(),
            endpoint,
            detail,
        });
    }
    if bytes.is_empty() {
        return Ok(Value::Null);
    }
    value.ok_or_else(|| DotsError::Protocol(format!("{endpoint}: response is not JSON")))
}

fn error_detail(value: &Value) -> Option<String> {
    let detail = match value.get("detail") {
        Some(Value::String(detail)) => Some(detail.clone()),
        Some(detail) => detail
            .get("message")
            .and_then(Value::as_str)
            .map(str::to_owned),
        None => value
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
            .map(str::to_owned),
    }?;
    // Keep details short; they end up in logs.
    Some(detail.chars().take(120).collect())
}

#[allow(dead_code)]
fn _assert_send_sync() {
    fn check<T: Send + Sync>() {}
    check::<DotsClient>();
}

#[allow(dead_code)]
fn _serialize_check<T: Serialize>() {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn join_escapes_segments() {
        let base = Url::parse("https://chatgpt.com/backend-api/").unwrap();
        let url = join(&base, &["messaging", "rooms", "a/b?c", "messages"]);
        assert_eq!(
            url.as_str(),
            "https://chatgpt.com/backend-api/messaging/rooms/a%2Fb%3Fc/messages"
        );
    }

    #[test]
    fn task_status_precedence() {
        use TaskStatus::*;
        assert_eq!(
            derive_task_status("systemError", false, Some("completed")).unwrap(),
            Failed
        );
        assert_eq!(
            derive_task_status("active", true, None).unwrap(),
            NeedsInput
        );
        assert_eq!(
            derive_task_status("active", false, Some("completed")).unwrap(),
            InProgress
        );
        assert_eq!(derive_task_status("idle", false, None).unwrap(), Thinking);
        assert_eq!(
            derive_task_status("idle", false, Some("completed")).unwrap(),
            Completed
        );
        assert!(derive_task_status("idle", false, Some("weird")).is_err());
    }

    #[test]
    fn turn_entries_take_prompt_and_final_answer() {
        let turn = json!({"id": "t1", "status": "completed", "items": [
            {"type": "functionCallOutput", "namespace": "cloud_threads", "name": "send_message",
             "output": "x <input>Find &amp; book</input> y"},
            {"type": "agentMessage", "text": "draft"},
            {"type": "agentMessage", "text": "Booked.", "phase": "final_answer"},
            {"type": "agentMessage", "text": "after"}
        ]});
        let entries = turn_entries(&turn);
        assert_eq!(entries[0].text, "Find & book");
        assert!(entries[0].prompt);
        assert_eq!(entries[1].text, "Booked.");
        let running = json!({"id": "t2", "status": "inProgress", "items": [
            {"type": "userMessage", "content": [{"type": "text", "text": "Go"}]},
            {"type": "agentMessage", "text": "partial"}
        ]});
        let entries = turn_entries(&running);
        assert_eq!(entries.len(), 1, "no answer until the turn finishes");
        assert_eq!(entries[0].id, "t2:prompt");
    }

    #[test]
    fn file_names_are_cleaned() {
        assert_eq!(sanitize_file_name("a/b\"c.txt").unwrap(), "a_b'c.txt");
        assert_eq!(sanitize_file_name("  ").unwrap(), "attachment");
        assert!(sanitize_file_name(&"x".repeat(300)).is_err());
    }

    #[test]
    fn error_detail_forms() {
        assert_eq!(
            error_detail(&json!({"detail": "Not Found"})).as_deref(),
            Some("Not Found")
        );
        assert_eq!(
            error_detail(&json!({"detail": {"message": "nope"}})).as_deref(),
            Some("nope")
        );
        assert_eq!(
            error_detail(&json!({"error": {"message": "bad"}})).as_deref(),
            Some("bad")
        );
    }
}
