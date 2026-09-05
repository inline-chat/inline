use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex as StdMutex, Weak};

use base64::Engine;
use futures_util::StreamExt;
use inline_agent_bridge::{
    AgentDriver, AgentEvent, AgentEventReceiver, AgentEventSender, ApprovalDecision,
    ApprovalOption, DriverCapabilities, DriverError, DriverFuture, DriverModelOption, DriverResult,
    DriverSettingOption, DriverSettingsCatalog, HostToolCall, HostToolConfiguration,
    HostToolResult, InputAttachment, InputAttachmentKind, ProviderSessionId, QuestionAnswer,
    ResumeSessionSpec, SessionReplay, SessionSpec, StartedTurn, SteeringSupport, TurnId, TurnInput,
    TurnOptions,
};
use semver::Version;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use tokio::io::AsyncWrite;
use tokio::sync::mpsc;

use crate::INLINE_CLIENT_MESSAGE_ID_PREFIX;
use crate::peer::{CodexPeer, IncomingMessage, PeerError, PeerResult, RemoteError};
use crate::protocol::{
    CodexNotification, CompactThreadParams, DynamicToolSpec, InterruptTurnParams, ModelListParams,
    ModelListResponse, PermissionProfileListParams, PermissionProfileListResponse,
    ResumeThreadParams, StartThreadParams, StartTurnParams, SteerTurnParams, UserInput,
    approval_result, normalize_notification, normalize_question_request, normalize_server_request,
    provider_session_id_from_response, question_result, turn_id_from_response,
    unsupported_notification_diagnostic,
};
use crate::session_connection::SharedSessionObservers;
use crate::session_wire::{ThreadListResponse, ThreadReadResponse, ThreadUnsubscribeResponse};

const DEFAULT_MODE_REQUEST_USER_INPUT: &str = "features.default_mode_request_user_input";
const MAX_CODEX_IMAGE_BYTES: usize = 20 * 1024 * 1024;
const MAX_CODEX_AUDIO_BYTES: usize = 20 * 1024 * 1024;
const CODEX_IMAGE_FETCH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

async fn codex_attachment_inputs(
    attachments: Vec<InputAttachment>,
    native_audio_supported: bool,
) -> DriverResult<Vec<UserInput>> {
    let mut inputs = Vec::with_capacity(attachments.len().saturating_mul(2));
    for attachment in attachments {
        match attachment.kind {
            InputAttachmentKind::Image => {
                if let Some(local_uri) = attachment.local_uri.as_deref() {
                    inputs.push(UserInput::LocalImage {
                        path: resolve_local_codex_media(
                            &attachment,
                            local_uri,
                            "image",
                            MAX_CODEX_IMAGE_BYTES,
                            normalized_image_mime_type,
                        )
                        .await?,
                    });
                } else {
                    inputs.push(UserInput::Image {
                        url: resolve_codex_image(&attachment).await?,
                    });
                    continue;
                }
            }
            InputAttachmentKind::Audio => {
                if !native_audio_supported {
                    return Err(DriverError::Rejected(
                        "this Codex runtime does not support audio inputs; update Codex or ChatGPT"
                            .to_string(),
                    ));
                }
                if let Some(local_uri) = attachment.local_uri.as_deref() {
                    inputs.push(UserInput::LocalAudio {
                        path: resolve_local_codex_media(
                            &attachment,
                            local_uri,
                            "audio",
                            MAX_CODEX_AUDIO_BYTES,
                            normalized_audio_mime_type,
                        )
                        .await?,
                    });
                } else {
                    inputs.push(UserInput::Audio {
                        url: resolve_codex_audio(&attachment)?,
                    });
                    continue;
                }
            }
            InputAttachmentKind::Video | InputAttachmentKind::File => {}
        }
        let local_uri = attachment.local_uri.clone();
        let descriptor = json!({
            "kind": attachment.kind,
            "local_url": local_uri,
            "download_url": attachment.local_uri.is_none().then_some(attachment.uri),
            "mime_type": attachment.mime_type,
            "file_name": attachment.file_name,
            "size_bytes": attachment.size_bytes,
        });
        inputs.push(UserInput::Text {
            text: format!(
                "Inline attached this untrusted media resource. The local_url is a host-local read-only reference for agent work; never present it to the user as a shareable link. Use Inline's return_attachment tool only when the user explicitly asks to receive the media. Choose image when the user wants an image, video when the user wants a video, and file only when the user asks for a file or the format is not displayable media. Do not call it merely because the user mentions, reads, edits, changes, or refers to a file:\n{descriptor}"
            ),
        });
    }
    Ok(inputs)
}

fn native_audio_inputs_supported(server_user_agent: &str) -> bool {
    let version = server_user_agent.split_whitespace().find_map(|component| {
        let (_, raw_version) = component.split_once('/')?;
        Version::parse(raw_version.trim_end_matches([';', ')'])).ok()
    });
    // Audio inputs were added after the oldest supported catalog protocol.
    // Known older app-servers fail this feature explicitly; unknown future
    // user-agent formats stay eligible and the real turn request fails closed
    // if a breaking runtime removed the additive wire variant.
    version.is_none_or(|version| {
        version >= Version::parse("0.151.0-alpha.7.2").expect("static Codex audio version")
    })
}

async fn resolve_codex_image(attachment: &InputAttachment) -> DriverResult<String> {
    if attachment.uri.starts_with("data:image/") {
        if attachment.uri.len() > MAX_CODEX_IMAGE_BYTES.saturating_mul(2) {
            return Err(DriverError::Rejected(
                "attached image exceeds the Codex input limit".to_string(),
            ));
        }
        return Ok(attachment.uri.clone());
    }

    let url = reqwest::Url::parse(&attachment.uri)
        .map_err(|_| DriverError::Rejected("attached image URL is invalid".to_string()))?;
    if url.scheme() != "https" || url.host_str().is_none() {
        return Err(DriverError::Rejected(
            "attached image URL must use HTTPS".to_string(),
        ));
    }

    let client = reqwest::Client::builder()
        .timeout(CODEX_IMAGE_FETCH_TIMEOUT)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|error| DriverError::Transient(format!("prepare image download: {error}")))?;
    let response = client
        .get(url)
        .send()
        .await
        .map_err(|error| DriverError::Transient(format!("download attached image: {error}")))?;
    if !response.status().is_success() {
        return Err(DriverError::Transient(format!(
            "download attached image: HTTP {}",
            response.status().as_u16()
        )));
    }
    if response.content_length().is_some_and(|length| {
        usize::try_from(length).map_or(true, |length| length > MAX_CODEX_IMAGE_BYTES)
    }) {
        return Err(DriverError::Rejected(
            "attached image exceeds the Codex input limit".to_string(),
        ));
    }

    let response_mime_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(normalized_image_mime_type)
        .map(str::to_string);
    let mime_type = response_mime_type
        .or_else(|| {
            attachment
                .mime_type
                .as_deref()
                .and_then(normalized_image_mime_type)
                .map(str::to_string)
        })
        .ok_or_else(|| {
            DriverError::Rejected("attached image has an unsupported media type".to_string())
        })?;
    let mut bytes = Vec::with_capacity(
        response
            .content_length()
            .and_then(|length| usize::try_from(length).ok())
            .unwrap_or(0),
    );
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk
            .map_err(|error| DriverError::Transient(format!("download attached image: {error}")))?;
        if bytes.len().saturating_add(chunk.len()) > MAX_CODEX_IMAGE_BYTES {
            return Err(DriverError::Rejected(
                "attached image exceeds the Codex input limit".to_string(),
            ));
        }
        bytes.extend_from_slice(&chunk);
    }
    if bytes.is_empty() {
        return Err(DriverError::Rejected("attached image is empty".to_string()));
    }
    log::trace!(
        target: "inline_agent_driver_codex::media",
        "phase=image_resolved byte_count={} mime_type={mime_type:?}",
        bytes.len()
    );
    Ok(format!(
        "data:{mime_type};base64,{}",
        base64::engine::general_purpose::STANDARD.encode(bytes)
    ))
}

fn resolve_codex_audio(attachment: &InputAttachment) -> DriverResult<String> {
    if attachment.uri.starts_with("data:audio/") {
        if attachment.uri.len() > MAX_CODEX_AUDIO_BYTES.saturating_mul(2) {
            return Err(DriverError::Rejected(
                "attached audio exceeds the Codex input limit".to_string(),
            ));
        }
        return Ok(attachment.uri.clone());
    }
    let url = reqwest::Url::parse(&attachment.uri)
        .map_err(|_| DriverError::Rejected("attached audio URL is invalid".to_string()))?;
    if url.scheme() != "https" || url.host_str().is_none() {
        return Err(DriverError::Rejected(
            "attached audio URL must use HTTPS".to_string(),
        ));
    }
    Ok(attachment.uri.clone())
}

async fn resolve_local_codex_media(
    attachment: &InputAttachment,
    local_uri: &str,
    media_label: &'static str,
    maximum_bytes: usize,
    normalize_mime_type: fn(&str) -> Option<&str>,
) -> DriverResult<std::path::PathBuf> {
    let url = reqwest::Url::parse(local_uri).map_err(|_| {
        DriverError::Rejected(format!("local attached {media_label} URL is invalid"))
    })?;
    if url.scheme() != "file" {
        return Err(DriverError::Rejected(format!(
            "local attached {media_label} URL must use the file scheme"
        )));
    }
    let path = url.to_file_path().map_err(|_| {
        DriverError::Rejected(format!("local attached {media_label} path is invalid"))
    })?;
    let metadata = tokio::fs::symlink_metadata(&path).await.map_err(|error| {
        DriverError::Transient(format!("inspect local attached {media_label}: {error}"))
    })?;
    if !metadata.file_type().is_file()
        || usize::try_from(metadata.len()).map_or(true, |size| size == 0 || size > maximum_bytes)
    {
        return Err(DriverError::Rejected(format!(
            "local attached {media_label} is not a bounded regular file"
        )));
    }
    let mime_type = attachment
        .mime_type
        .as_deref()
        .and_then(normalize_mime_type)
        .ok_or_else(|| {
            DriverError::Rejected(format!(
                "attached {media_label} has an unsupported media type"
            ))
        })?;
    log::trace!(
        target: "inline_agent_driver_codex::media",
        "phase={media_label}_resolved source=local byte_count={} mime_type={mime_type:?}",
        metadata.len()
    );
    // Codex app-server's native local media inputs require an absolute host
    // path, not a file URL. The bridge and provider share this filesystem.
    Ok(path)
}

fn normalized_image_mime_type(value: &str) -> Option<&str> {
    let mime_type = value.split(';').next()?.trim();
    (mime_type.starts_with("image/")
        && mime_type
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'+' | b'.' | b'-')))
    .then_some(mime_type)
}

fn normalized_audio_mime_type(value: &str) -> Option<&str> {
    let mime_type = value.split(';').next()?.trim();
    (mime_type.starts_with("audio/")
        && mime_type
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'+' | b'.' | b'-')))
    .then_some(mime_type)
}

fn inline_thread_config() -> BTreeMap<String, Value> {
    BTreeMap::from([(
        DEFAULT_MODE_REQUEST_USER_INPUT.to_string(),
        Value::Bool(true),
    )])
}

const CONTROL_REQUEST_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
const DEFAULT_MODEL_REQUEST_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(1);
const SESSION_CATALOG_REQUEST_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
const MUTATING_REQUEST_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
const CONNECTION_SHUTDOWN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(7);
#[cfg(not(test))]
const INTERRUPT_COMPLETION_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
#[cfg(test)]
const INTERRUPT_COMPLETION_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(1);
#[cfg(not(test))]
const BACKGROUND_TERMINAL_SETTLE_INTERVAL: std::time::Duration =
    std::time::Duration::from_millis(150);
#[cfg(test)]
const BACKGROUND_TERMINAL_SETTLE_INTERVAL: std::time::Duration =
    std::time::Duration::from_millis(10);
#[cfg(not(test))]
const AMBIGUOUS_EPOCH_SHUTDOWN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(7);
#[cfg(test)]
const AMBIGUOUS_EPOCH_SHUTDOWN_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(500);

type EventSender = AgentEventSender;

const MAX_UNCLAIMED_TURNS: usize = 8;
const MAX_UNCLAIMED_EVENTS_PER_TURN: usize = 64;
const MAX_TERMINAL_TOMBSTONES: usize = 1_024;
const MAX_CATALOG_PAGES: usize = 16;
const CATALOG_PAGE_SIZE: u32 = 100;
const DEFAULT_PERMISSION_PROFILE: &str = ":danger-full-access";
const MAX_PENDING_INTERACTIONS: usize = 32;
const MAX_PENDING_INTERACTIONS_PER_TURN: usize = 8;

#[derive(Debug, Default)]
struct BackloggedTurn {
    events: Vec<AgentEvent>,
    terminal: bool,
    overflowed: bool,
}

#[derive(Debug, Default)]
struct EventRouting {
    routes: HashMap<TurnId, EventSender>,
    backlog: HashMap<TurnId, BackloggedTurn>,
    terminal_turns: HashSet<TurnId>,
    terminal_order: VecDeque<TurnId>,
    compaction_starts: HashMap<String, PendingCompactionStart>,
}

#[derive(Debug)]
struct PendingCompactionStart {
    after_sequence: u64,
    sender: tokio::sync::oneshot::Sender<DriverResult<TurnId>>,
}

/// Compaction has no turn ID in its RPC response. Keep the exact session
/// claim until its start notification arrives; cancellation is ambiguous.
struct CompactionStartGuard<W: AsyncWrite + Unpin + Send + 'static> {
    routing: SharedEventRouting,
    peer: CodexPeer<W>,
    thread_id: String,
    ambiguous: bool,
}

impl<W: AsyncWrite + Unpin + Send + 'static> Drop for CompactionStartGuard<W> {
    fn drop(&mut self) {
        self.routing
            .lock()
            .expect("Codex event routing poisoned")
            .compaction_starts
            .remove(&self.thread_id);
        if self.ambiguous {
            self.peer.abort();
        }
    }
}

impl EventRouting {
    fn remember_terminal(&mut self, turn_id: TurnId) {
        if self.terminal_turns.insert(turn_id.clone()) {
            self.terminal_order.push_back(turn_id);
        }
        if self.terminal_order.len() > MAX_TERMINAL_TOMBSTONES
            && let Some(expired) = self.terminal_order.pop_front()
        {
            self.terminal_turns.remove(&expired);
        }
    }
}

type SharedEventRouting = Arc<StdMutex<EventRouting>>;

#[derive(Clone, Debug)]
struct PendingApproval {
    request_id: Value,
    turn_id: TurnId,
    options: Vec<ApprovalOption>,
}

type PendingApprovals = Arc<StdMutex<HashMap<String, PendingApproval>>>;

#[derive(Clone, Debug)]
struct PendingQuestion {
    request_id: Value,
    turn_id: TurnId,
    question_ids: HashSet<String>,
}

type PendingQuestions = Arc<StdMutex<HashMap<String, PendingQuestion>>>;
type HostTools = Arc<StdMutex<Option<HostToolConfiguration>>>;

struct IncomingDispatchState {
    routing: SharedEventRouting,
    approvals: PendingApprovals,
    questions: PendingQuestions,
    host_tools: HostTools,
    session_observers: SharedSessionObservers,
}

pub(crate) type ShutdownFuture = Pin<Box<dyn Future<Output = DriverResult<()>> + Send>>;
pub(crate) type ShutdownHook = Arc<dyn Fn() -> ShutdownFuture + Send + Sync>;
type WeakShutdownHook = Weak<dyn Fn() -> ShutdownFuture + Send + Sync>;

pub struct CodexAppServerDriver<W> {
    peer: CodexPeer<W>,
    server_user_agent: String,
    routing: SharedEventRouting,
    approvals: PendingApprovals,
    questions: PendingQuestions,
    host_tools: HostTools,
    session_observers: SharedSessionObservers,
    default_permission_profile_workspaces: Arc<StdMutex<HashSet<std::path::PathBuf>>>,
    shutdown_hook: Option<ShutdownHook>,
}

impl<W> Clone for CodexAppServerDriver<W> {
    fn clone(&self) -> Self {
        Self {
            peer: self.peer.clone(),
            server_user_agent: self.server_user_agent.clone(),
            routing: self.routing.clone(),
            approvals: self.approvals.clone(),
            questions: self.questions.clone(),
            host_tools: self.host_tools.clone(),
            session_observers: self.session_observers.clone(),
            default_permission_profile_workspaces: self
                .default_permission_profile_workspaces
                .clone(),
            shutdown_hook: self.shutdown_hook.clone(),
        }
    }
}

impl<W> std::fmt::Debug for CodexAppServerDriver<W> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CodexAppServerDriver")
            .field("peer", &self.peer)
            .finish_non_exhaustive()
    }
}

impl<W> CodexAppServerDriver<W>
where
    W: AsyncWrite + Unpin + Send + 'static,
{
    pub(crate) async fn session_catalog_request(
        &self,
        method: &'static str,
        params: Value,
    ) -> PeerResult<Value> {
        self.peer
            .request_with_timeout(method, params, SESSION_CATALOG_REQUEST_TIMEOUT)
            .await
    }

    pub(crate) async fn session_request_with_wire_sequence(
        &self,
        method: &'static str,
        params: Value,
    ) -> PeerResult<(Value, u64)> {
        self.peer.request_with_wire_sequence(method, params).await
    }

    pub(crate) fn session_observers(&self) -> SharedSessionObservers {
        self.session_observers.clone()
    }

    pub fn server_user_agent(&self) -> &str {
        &self.server_user_agent
    }

    fn native_audio_inputs_supported(&self) -> bool {
        native_audio_inputs_supported(&self.server_user_agent)
    }

    pub async fn initialize(peer: CodexPeer<W>, version: &str) -> DriverResult<Self> {
        Self::initialize_with_shutdown(peer, version, None).await
    }

    pub(crate) async fn initialize_with_shutdown(
        peer: CodexPeer<W>,
        version: &str,
        shutdown_hook: Option<ShutdownHook>,
    ) -> DriverResult<Self> {
        let incoming = peer.take_incoming().map_err(driver_error)?;
        let params = serde_json::to_value(crate::InitializeParams::inline(version))
            .map_err(protocol_serialization_error)?;
        let initialize = peer
            .request("initialize", params)
            .await
            .map_err(driver_error)?;
        let server_user_agent = initialize
            .get("userAgent")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| {
                DriverError::Protocol(
                    "Codex initialize response omitted its server user agent".to_string(),
                )
            })?
            .to_string();
        peer.notify("initialized", json!({}))
            .await
            .map_err(driver_error)?;

        let routing = Arc::new(StdMutex::new(EventRouting::default()));
        let approvals = Arc::new(StdMutex::new(HashMap::new()));
        let questions = Arc::new(StdMutex::new(HashMap::new()));
        let host_tools = Arc::new(StdMutex::new(None));
        let session_observers = SharedSessionObservers::default();
        tokio::spawn(dispatch_incoming(
            peer.clone(),
            incoming,
            IncomingDispatchState {
                routing: routing.clone(),
                approvals: approvals.clone(),
                questions: questions.clone(),
                host_tools: host_tools.clone(),
                session_observers: session_observers.clone(),
            },
            shutdown_hook.as_ref().map(Arc::downgrade),
        ));
        Ok(Self {
            peer,
            server_user_agent,
            routing,
            approvals,
            questions,
            host_tools,
            session_observers,
            default_permission_profile_workspaces: Arc::new(StdMutex::new(HashSet::new())),
            shutdown_hook,
        })
    }

    /// Bounded, read-only compatibility probe used before Inline exposes a
    /// Codex runtime. Reads are decoded against the response shapes Inline
    /// consumes. Turn and thread mutations are deliberately not probed: their
    /// real requests fail closed at the operation boundary without risking a
    /// future runtime interpreting synthetic probe input as user work.
    /// Unknown additive fields remain forward-compatible through Serde's
    /// default unknown-field behavior.
    pub async fn verify_runtime_contract(&self) -> DriverResult<()> {
        let threads = self
            .verify_catalog_read::<ThreadListResponse>(
                "thread/list",
                json!({
                    "limit": 1,
                    "sortKey": "updated_at",
                    "sortDirection": "desc",
                    "archived": false,
                    "useStateDbOnly": true
                }),
            )
            .await?;
        if let Some(thread) = threads.data.first() {
            self.verify_catalog_read::<ThreadReadResponse>(
                "thread/read",
                json!({ "threadId": thread.id, "includeTurns": false }),
            )
            .await?;
            Ok(())
        } else {
            const NIL_THREAD_ID: &str = "00000000-0000-0000-0000-000000000000";
            self.verify_catalog_method::<ThreadReadResponse>(
                "thread/read",
                json!({ "threadId": NIL_THREAD_ID, "includeTurns": false }),
            )
            .await
        }
    }

    async fn verify_catalog_read<R>(&self, method: &'static str, params: Value) -> DriverResult<R>
    where
        R: DeserializeOwned,
    {
        let response = self
            .peer
            .request_with_timeout(method, params, std::time::Duration::from_secs(5))
            .await
            .map_err(driver_error)?;
        serde_json::from_value::<R>(response)
            .map_err(|error| incompatible_catalog_response(method, error))
    }

    async fn verify_catalog_method<R>(
        &self,
        method: &'static str,
        params: Value,
    ) -> DriverResult<()>
    where
        R: DeserializeOwned,
    {
        match self
            .peer
            .request_with_timeout(method, params, std::time::Duration::from_secs(5))
            .await
        {
            Ok(response) => serde_json::from_value::<R>(response)
                .map(|_| ())
                .map_err(|error| incompatible_catalog_response(method, error)),
            Err(PeerError::Remote(error)) if error.code == Some(-32601) => {
                Err(DriverError::Protocol(format!(
                    "Codex stable session method is unavailable: {method}"
                )))
            }
            // Codex uses structured invalid-request (-32600) for a valid read
            // of a non-existent thread. Invalid-params (-32602) instead means
            // Inline's request shape drifted and must fail negotiation.
            Err(PeerError::Remote(error)) if error.code == Some(-32600) => Ok(()),
            Err(PeerError::Remote(error)) => Err(DriverError::Protocol(format!(
                "Codex stable session method rejected Inline's request shape: {method} ({})",
                error.code.unwrap_or_default()
            ))),
            Err(error) => Err(driver_error(error)),
        }
    }

    async fn stop_ambiguous_epoch(&self, operation: &str) -> DriverError {
        let ended = format!("Codex {operation} timed out with an unknown provider outcome");
        let unconfirmed =
            format!("Codex {operation} timed out and provider shutdown was not confirmed");
        self.end_owned_epoch(ended, unconfirmed).await
    }

    async fn end_owned_epoch(&self, ended: String, unconfirmed: String) -> DriverError {
        let Some(shutdown) = &self.shutdown_hook else {
            return DriverError::Unavailable(unconfirmed);
        };
        match tokio::time::timeout(AMBIGUOUS_EPOCH_SHUTDOWN_TIMEOUT, shutdown()).await {
            Ok(Ok(())) => DriverError::ProcessExited(ended),
            _ => DriverError::EpochEnded(unconfirmed),
        }
    }

    async fn stop_cleanup_failure(&self) -> DriverError {
        self.end_owned_epoch(
            "Codex stop cleanup failed; provider epoch ended".to_string(),
            "Codex stop cleanup failed and provider shutdown was not confirmed".to_string(),
        )
        .await
    }

    async fn settle_mutating_request(
        &self,
        operation: &'static str,
        result: Result<Value, PeerError>,
    ) -> DriverResult<Value> {
        match result {
            Ok(response) => Ok(response),
            Err(PeerError::Timeout(_)) => Err(self.stop_ambiguous_epoch(operation).await),
            Err(error) => Err(driver_error(error)),
        }
    }

    async fn mutating_request(
        &self,
        operation: &'static str,
        params: Value,
    ) -> DriverResult<Value> {
        let result = self
            .peer
            .request_with_timeout(operation, params, MUTATING_REQUEST_TIMEOUT)
            .await;
        self.settle_mutating_request(operation, result).await
    }

    async fn settle_cancel_request(&self, result: Result<Value, PeerError>) -> DriverResult<bool> {
        match result {
            Ok(_) => Ok(true),
            Err(PeerError::Remote(RemoteError {
                code: Some(-32600),
                message,
            })) if message == "no active turn to interrupt" => Ok(false),
            Err(PeerError::Timeout(_)) if self.shutdown_hook.is_some() => {
                Err(self.stop_ambiguous_epoch("turn/interrupt").await)
            }
            Err(error) => Err(driver_error(error)),
        }
    }

    async fn wait_for_terminal_turn(&self, turn_id: &TurnId) -> DriverResult<()> {
        tokio::time::timeout(INTERRUPT_COMPLETION_TIMEOUT, async {
            loop {
                if self
                    .routing
                    .lock()
                    .expect("Codex event routing poisoned")
                    .terminal_turns
                    .contains(turn_id)
                {
                    return;
                }
                tokio::time::sleep(BACKGROUND_TERMINAL_SETTLE_INTERVAL).await;
            }
        })
        .await
        .map_err(|_| DriverError::Protocol("Codex did not confirm turn interruption".to_string()))
    }

    async fn clean_background_terminals(&self, session_id: &ProviderSessionId) -> DriverResult<()> {
        self.settle_mutating_request(
            "thread/backgroundTerminals/clean",
            self.peer
                .request_with_timeout(
                    "thread/backgroundTerminals/clean",
                    json!({ "threadId": session_id.as_str() }),
                    CONTROL_REQUEST_TIMEOUT,
                )
                .await,
        )
        .await?;

        // The cleanup request is only an acknowledgement that Codex queued its
        // cleanup operation. Keep the provider alive and require its terminal
        // registry to remain empty across two observations before /stop can be
        // presented as successful.
        let mut empty_observations = 0_u8;
        tokio::time::timeout(CONTROL_REQUEST_TIMEOUT, async {
            loop {
                let response = self
                    .peer
                    .request_with_timeout(
                        "thread/backgroundTerminals/list",
                        json!({
                            "threadId": session_id.as_str(),
                            "cursor": null,
                            "limit": 100
                        }),
                        CONTROL_REQUEST_TIMEOUT,
                    )
                    .await
                    .map_err(driver_error)?;
                let data = response
                    .get("data")
                    .and_then(Value::as_array)
                    .ok_or_else(|| {
                        DriverError::Protocol(
                            "Codex background terminal list response is malformed".to_string(),
                        )
                    })?;
                let has_more = response
                    .get("nextCursor")
                    .is_some_and(|cursor| !cursor.is_null());
                if data.is_empty() && !has_more {
                    empty_observations += 1;
                    if empty_observations == 2 {
                        return Ok(());
                    }
                } else {
                    empty_observations = 0;
                }
                tokio::time::sleep(BACKGROUND_TERMINAL_SETTLE_INTERVAL).await;
            }
        })
        .await
        .map_err(|_| {
            DriverError::ProcessExited(
                "Codex background terminal cleanup could not be confirmed".to_string(),
            )
        })?
    }

    fn register_turn(&self, turn_id: TurnId) -> AgentEventReceiver {
        let (sender, receiver) = AgentEventReceiver::default_channel();
        let backlog = {
            let mut routing = self.routing.lock().expect("Codex event routing poisoned");
            let backlog = routing.backlog.remove(&turn_id);
            if !backlog.as_ref().is_some_and(|backlog| backlog.terminal) {
                routing.routes.insert(turn_id, sender.clone());
            }
            backlog
        };
        if let Some(backlog) = backlog {
            if backlog.overflowed {
                let _ = sender.send(Err(DriverError::Protocol(
                    "Codex emitted too many control events before turn registration".to_string(),
                )));
                return receiver;
            }
            for event in backlog.events {
                if !sender.send(Ok(event)) {
                    break;
                }
            }
        }
        receiver
    }

    async fn load_settings_catalog(
        &self,
        cwd: &std::path::Path,
    ) -> DriverResult<DriverSettingsCatalog> {
        let workspace = cwd.to_path_buf();
        let mut models = Vec::new();
        let mut cursor = None;
        let mut seen_cursors = HashSet::new();
        for _ in 0..MAX_CATALOG_PAGES {
            let response = self
                .peer
                .request(
                    "model/list",
                    serialize(ModelListParams {
                        cursor: cursor.clone(),
                        limit: Some(CATALOG_PAGE_SIZE),
                        include_hidden: Some(false),
                    })?,
                )
                .await
                .map_err(driver_error)?;
            let response: ModelListResponse = deserialize("model/list", response)?;
            models.extend(
                response
                    .data
                    .into_iter()
                    .filter(|model| !model.hidden)
                    .map(|model| {
                        let label =
                            nonempty(model.display_name).unwrap_or_else(|| model.model.clone());
                        DriverModelOption {
                            value: model.model,
                            label,
                            description: nonempty(model.description),
                            reasoning: model
                                .supported_reasoning_efforts
                                .into_iter()
                                .map(|option| DriverSettingOption {
                                    label: display_option_id(&option.reasoning_effort),
                                    value: option.reasoning_effort,
                                    description: nonempty(option.description),
                                    disabled: false,
                                })
                                .collect(),
                            default_reasoning: nonempty(model.default_reasoning_effort),
                            is_default: model.is_default,
                        }
                    }),
            );
            let Some(next_cursor) = response.next_cursor.filter(|value| !value.is_empty()) else {
                break;
            };
            if !seen_cursors.insert(next_cursor.clone()) {
                return Err(DriverError::Protocol(
                    "Codex model/list repeated a pagination cursor".to_string(),
                ));
            }
            cursor = Some(next_cursor);
        }

        let cwd = cwd.to_str().ok_or_else(|| {
            DriverError::Protocol("Codex workspace path is not valid UTF-8".to_string())
        })?;
        let mut permissions = Vec::new();
        let mut cursor = None;
        let mut seen_cursors = HashSet::new();
        for _ in 0..MAX_CATALOG_PAGES {
            let response = self
                .peer
                .request(
                    "permissionProfile/list",
                    serialize(PermissionProfileListParams {
                        cursor: cursor.clone(),
                        limit: Some(CATALOG_PAGE_SIZE),
                        cwd: Some(cwd.to_string()),
                    })?,
                )
                .await
                .map_err(driver_error)?;
            let response: PermissionProfileListResponse =
                deserialize("permissionProfile/list", response)?;
            permissions.extend(response.data.into_iter().map(|option| DriverSettingOption {
                label: display_option_id(&option.id),
                value: option.id,
                description: option.description.and_then(nonempty),
                disabled: option.allowed == Some(false),
            }));
            let Some(next_cursor) = response.next_cursor.filter(|value| !value.is_empty()) else {
                break;
            };
            if !seen_cursors.insert(next_cursor.clone()) {
                return Err(DriverError::Protocol(
                    "Codex permissionProfile/list repeated a pagination cursor".to_string(),
                ));
            }
            cursor = Some(next_cursor);
        }
        let default_permissions = permissions
            .iter()
            .any(|option| option.value == DEFAULT_PERMISSION_PROFILE && !option.disabled)
            .then(|| DEFAULT_PERMISSION_PROFILE.to_string());
        {
            let mut default_workspaces = self
                .default_permission_profile_workspaces
                .lock()
                .expect("Codex default permission workspace set poisoned");
            if default_permissions.is_some() {
                default_workspaces.insert(workspace);
            } else {
                default_workspaces.remove(&workspace);
            }
        }
        // model/list's isDefault is the catalog recommendation, which can
        // differ from the host/project default used when turn/start omits a
        // model. Resolve that default through Codex's existing config API.
        let configuration = self
            .peer
            .request_with_timeout(
                "config/read",
                json!({ "includeLayers": false, "cwd": cwd }),
                DEFAULT_MODEL_REQUEST_TIMEOUT,
            )
            .await;
        match configuration {
            Ok(configuration) => {
                if let Some(configured_model) = configuration
                    .pointer("/config/model")
                    .and_then(Value::as_str)
                {
                    for model in &mut models {
                        model.is_default = model.value == configured_model;
                    }
                }
            }
            Err(_) => {
                // Default-label metadata must not hide an otherwise fresh
                // model catalog. Use the generic provider-default label.
                for model in &mut models {
                    model.is_default = false;
                }
            }
        }
        Ok(DriverSettingsCatalog {
            models,
            permissions,
            default_permissions,
        })
    }
}

impl<W> AgentDriver for CodexAppServerDriver<W>
where
    W: AsyncWrite + Unpin + Send + 'static,
{
    fn capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            resume_session: true,
            compact_session: true,
            cancel_turn: true,
            settings_catalog: true,
            usage_limits: true,
            settings_catalog_starts_session: false,
            session_commands: false,
            steering: SteeringSupport::Native,
            settings_apply_timing: inline_agent_bridge::ApplyTiming::NextTurn,
            approvals: vec![
                inline_agent_bridge::ApprovalOption::ApproveOnce,
                inline_agent_bridge::ApprovalOption::ApproveForSession,
                inline_agent_bridge::ApprovalOption::Reject,
                inline_agent_bridge::ApprovalOption::CancelTurn,
            ],
            host_tools: inline_agent_bridge::HostToolTransport::Native,
        }
    }

    fn session_input_correlation(
        &self,
        direction_id: &inline_agent_bridge::DirectionId,
    ) -> Option<inline_agent_bridge::SessionInputCorrelation> {
        inline_agent_bridge::SessionInputCorrelation::new(format!(
            "{INLINE_CLIENT_MESSAGE_ID_PREFIX}{}",
            direction_id.as_str()
        ))
        .ok()
    }

    fn configure_host_tools(&self, configuration: HostToolConfiguration) -> DriverResult<()> {
        if configuration.specs.is_empty() {
            return Err(DriverError::Protocol(
                "Inline host tool catalog cannot be empty".to_string(),
            ));
        }
        *self.host_tools.lock().expect("Codex host tools poisoned") = Some(configuration);
        Ok(())
    }

    fn settings_catalog<'a>(
        &'a self,
        cwd: &'a std::path::Path,
    ) -> DriverFuture<'a, DriverSettingsCatalog> {
        Box::pin(async move { self.load_settings_catalog(cwd).await })
    }

    fn usage_limits(&self) -> DriverFuture<'_, Vec<inline_agent_bridge::DriverUsageWindow>> {
        Box::pin(async move {
            let response = self
                .peer
                .request_with_timeout(
                    "account/rateLimits/read",
                    json!({}),
                    DEFAULT_MODEL_REQUEST_TIMEOUT,
                )
                .await
                .map_err(driver_error)?;
            Ok(crate::protocol::normalize_usage_limits(&response))
        })
    }

    fn start_session<'a>(&'a self, spec: SessionSpec) -> DriverFuture<'a, ProviderSessionId> {
        Box::pin(async move {
            let dynamic_tools = self
                .host_tools
                .lock()
                .expect("Codex host tools poisoned")
                .as_ref()
                .map(|configuration| {
                    configuration
                        .specs
                        .iter()
                        .map(|tool| DynamicToolSpec {
                            name: tool.name.clone(),
                            description: tool.description.clone(),
                            input_schema: tool.input_schema.clone(),
                            namespace: "inline".to_string(),
                            defer_loading: false,
                        })
                        .collect()
                });
            let params = StartThreadParams {
                cwd: Some(spec.cwd),
                config: Some(inline_thread_config()),
                dynamic_tools,
                ..StartThreadParams::default()
            };
            let response = self
                .mutating_request("thread/start", serialize(params)?)
                .await?;
            provider_session_id_from_response("thread/start", &response)
                .map_err(|error| DriverError::Protocol(error.to_string()))
        })
    }

    fn resume_session<'a>(&'a self, spec: ResumeSessionSpec) -> DriverFuture<'a, ()> {
        Box::pin(async move {
            if !matches!(spec.replay, SessionReplay::None) {
                return Err(DriverError::Unsupported("Codex session replay cursor"));
            }
            let result = self
                .peer
                .request_with_timeout(
                    "thread/resume",
                    serialize(ResumeThreadParams {
                        thread_id: spec.session_id.to_string(),
                        cwd: Some(spec.cwd),
                        config: Some(inline_thread_config()),
                    })?,
                    MUTATING_REQUEST_TIMEOUT,
                )
                .await;
            match result {
                Ok(_) => {}
                Err(PeerError::Timeout(_)) => {
                    return Err(self.stop_ambiguous_epoch("thread/resume").await);
                }
                Err(error) => {
                    let error = resume_driver_error(error);
                    if matches!(&error, DriverError::SessionBusy(_)) {
                        // A rejected private resume can still leave Codex with
                        // a subscription in this app-server epoch. Release
                        // only that thread: ending the whole epoch here could
                        // interrupt an unrelated Inline turn on another
                        // session owned by the same provider process.
                        let cleanup = self
                            .peer
                            .request_with_timeout(
                                "thread/unsubscribe",
                                json!({ "threadId": spec.session_id.to_string() }),
                                CONTROL_REQUEST_TIMEOUT,
                            )
                            .await
                            .and_then(|response| {
                                serde_json::from_value::<ThreadUnsubscribeResponse>(response)
                                    .map_err(PeerError::Json)
                            });
                        if !matches!(
                            cleanup,
                            Ok(ThreadUnsubscribeResponse {
                                status: crate::session_wire::ThreadUnsubscribeStatus::NotLoaded
                                    | crate::session_wire::ThreadUnsubscribeStatus::NotSubscribed
                                    | crate::session_wire::ThreadUnsubscribeStatus::Unsubscribed,
                            })
                        ) {
                            log::warn!("Codex busy-session subscription cleanup failed");
                            return Err(self.stop_ambiguous_epoch("thread/unsubscribe").await);
                        }
                    }
                    return Err(error);
                }
            }
            Ok(())
        })
    }

    fn start_turn<'a>(
        &'a self,
        session_id: &'a ProviderSessionId,
        input: TurnInput,
        options: TurnOptions,
    ) -> DriverFuture<'a, StartedTurn> {
        Box::pin(async move {
            let mut params = StartTurnParams::text(session_id.to_string(), input.text);
            params.input.extend(
                codex_attachment_inputs(input.attachments, self.native_audio_inputs_supported())
                    .await?,
            );
            params.client_user_message_id = input
                .client_message_id
                .map(|id| format!("{INLINE_CLIENT_MESSAGE_ID_PREFIX}{id}"));
            let use_default_permissions = options.cwd.as_ref().is_some_and(|cwd| {
                self.default_permission_profile_workspaces
                    .lock()
                    .expect("Codex default permission workspace set poisoned")
                    .contains(cwd)
            });
            params.cwd = options.cwd;
            params.model = options.model;
            params.effort = options.reasoning;
            params.permissions = options.permissions.or_else(|| {
                use_default_permissions.then(|| DEFAULT_PERMISSION_PROFILE.to_string())
            });
            let response = self
                .mutating_request("turn/start", serialize(params)?)
                .await?;
            let turn_id = turn_id_from_response("turn/start", &response)
                .map_err(|error| DriverError::Protocol(error.to_string()))?;
            let events = self.register_turn(turn_id.clone());
            Ok(StartedTurn { turn_id, events })
        })
    }

    fn steer_turn<'a>(
        &'a self,
        session_id: &'a ProviderSessionId,
        turn_id: &'a TurnId,
        input: TurnInput,
    ) -> DriverFuture<'a, ()> {
        Box::pin(async move {
            self.mutating_request(
                "turn/steer",
                serialize(SteerTurnParams {
                    thread_id: session_id.to_string(),
                    client_user_message_id: input
                        .client_message_id
                        .map(|id| format!("{INLINE_CLIENT_MESSAGE_ID_PREFIX}{id}")),
                    input: std::iter::once(UserInput::Text { text: input.text })
                        .chain(
                            codex_attachment_inputs(
                                input.attachments,
                                self.native_audio_inputs_supported(),
                            )
                            .await?,
                        )
                        .collect(),
                    expected_turn_id: turn_id.to_string(),
                })?,
            )
            .await?;
            Ok(())
        })
    }

    fn cancel_turn<'a>(
        &'a self,
        session_id: &'a ProviderSessionId,
        turn_id: &'a TurnId,
    ) -> DriverFuture<'a, ()> {
        Box::pin(async move {
            let started_at = std::time::Instant::now();
            log::trace!(
                target: "inline_agent_driver_codex::turn",
                "phase=cancel_started session_id={:?} turn_id={:?}",
                session_id.as_str(),
                turn_id.as_str()
            );
            let result = self
                .peer
                .request_with_timeout(
                    "turn/interrupt",
                    serialize(InterruptTurnParams {
                        thread_id: session_id.to_string(),
                        turn_id: turn_id.to_string(),
                    })?,
                    CONTROL_REQUEST_TIMEOUT,
                )
                .await;
            let interrupted = self.settle_cancel_request(result).await?;
            log::trace!(
                target: "inline_agent_driver_codex::turn",
                "phase=interrupt_acknowledged session_id={:?} turn_id={:?} provider_had_active_turn={interrupted} elapsed_ms={}",
                session_id.as_str(),
                turn_id.as_str(),
                started_at.elapsed().as_millis()
            );
            if interrupted {
                // Codex deliberately leaves background terminals alive after
                // turn/interrupt. Start cleanup immediately so a short-lived
                // command cannot keep performing side effects while we wait
                // for the provider's terminal interruption event.
                let (interruption, cleanup) = tokio::join!(
                    self.wait_for_terminal_turn(turn_id),
                    self.clean_background_terminals(session_id),
                );
                if cleanup.is_err() {
                    log::warn!("Codex stop cleanup failed");
                    return Err(self.stop_cleanup_failure().await);
                }
                if let Err(error) = interruption {
                    return Err(self.stop_ambiguous_epoch(&error.to_string()).await);
                }
                // A command can finish provider startup and enter the terminal
                // registry after the early cleanup observed an empty list.
                // Once turn/completed proves no more turn work can start,
                // repeat cleanup and its stable-empty verification as the
                // authoritative stop barrier.
                if self.clean_background_terminals(session_id).await.is_err() {
                    log::warn!("Codex final stop cleanup failed");
                    return Err(self.stop_cleanup_failure().await);
                }
            } else if self.clean_background_terminals(session_id).await.is_err() {
                // Inline can still be handling a turn while Codex has just
                // completed it. Clean the thread in that race so a yielded
                // terminal from the just-finished turn cannot survive /stop.
                log::warn!("Codex completed-turn stop cleanup failed");
                return Err(self.stop_cleanup_failure().await);
            }
            log::trace!(
                target: "inline_agent_driver_codex::turn",
                "phase=cancel_confirmed session_id={:?} turn_id={:?} elapsed_ms={}",
                session_id.as_str(),
                turn_id.as_str(),
                started_at.elapsed().as_millis()
            );
            Ok(())
        })
    }

    fn compact_session<'a>(
        &'a self,
        session_id: &'a ProviderSessionId,
    ) -> DriverFuture<'a, StartedTurn> {
        Box::pin(async move {
            if self
                .session_observers
                .claims_thread_traffic(&json!({"threadId": session_id.as_str()}))
            {
                return Err(DriverError::SessionBusy(
                    "This connection only observes the session; its controller must compact it."
                        .to_string(),
                ));
            }
            // Fence notifications already queued for this session before the
            // mutation. Actual compaction items may arrive before its RPC ACK,
            // so the ACK itself cannot serve as the lifecycle boundary.
            let (snapshot, after_sequence) = tokio::time::timeout(
                CONTROL_REQUEST_TIMEOUT,
                self.peer.request_with_wire_sequence(
                    "thread/read",
                    json!({
                        "threadId": session_id.as_str(), "includeTurns": false,
                    }),
                ),
            )
            .await
            .map_err(|_| {
                DriverError::Transient(
                    "Codex session status timed out before compaction.".to_string(),
                )
            })?
            .map_err(driver_error)?;
            match snapshot.pointer("/thread/status/type").and_then(Value::as_str) {
                Some("idle") => {},
                Some("active") => return Err(DriverError::Rejected("Codex is still working in this session. Stop it or wait before compacting.".to_string())),
                _ => return Err(DriverError::Rejected("Codex could not confirm that this session is idle. Use /resume, then try /compact again.".to_string())),
            }
            let (sender, receiver) = tokio::sync::oneshot::channel();
            {
                let mut routing = self.routing.lock().expect("Codex event routing poisoned");
                if routing.compaction_starts.contains_key(session_id.as_str())
                    || routing.compaction_starts.len() >= MAX_UNCLAIMED_TURNS
                {
                    return Err(DriverError::Rejected(
                        "A compaction is already starting. Wait for it to finish.".to_string(),
                    ));
                }
                routing.compaction_starts.insert(
                    session_id.to_string(),
                    PendingCompactionStart {
                        after_sequence,
                        sender,
                    },
                );
            }
            let mut guard = CompactionStartGuard {
                routing: self.routing.clone(),
                peer: self.peer.clone(),
                thread_id: session_id.to_string(),
                ambiguous: true,
            };
            if let Err(error) = self
                .mutating_request(
                    "thread/compact/start",
                    serialize(CompactThreadParams {
                        thread_id: session_id.to_string(),
                    })?,
                )
                .await
            {
                guard.ambiguous = !matches!(error, DriverError::Rejected(_));
                return Err(error);
            }
            let turn_id = match tokio::time::timeout(CONTROL_REQUEST_TIMEOUT, receiver).await {
                Ok(Ok(Ok(turn_id))) => turn_id,
                Ok(Ok(Err(error))) => return Err(error),
                _ => return Err(self.stop_ambiguous_epoch("thread/compact/start").await),
            };
            let events = self.register_turn(turn_id.clone());
            guard.ambiguous = false;
            Ok(StartedTurn { turn_id, events })
        })
    }

    fn resolve_approval<'a>(
        &'a self,
        approval_id: &'a str,
        decision: ApprovalDecision,
    ) -> DriverFuture<'a, ()> {
        Box::pin(async move {
            let pending = {
                let mut approvals = self.approvals.lock().expect("Codex approval map poisoned");
                let pending = approvals.get(approval_id).ok_or_else(|| {
                    DriverError::Rejected(format!("approval {approval_id} is no longer pending"))
                })?;
                if !decision_is_offered(&pending.options, &decision) {
                    return Err(DriverError::Rejected(format!(
                        "approval {approval_id} does not offer {decision:?}"
                    )));
                }
                approvals
                    .remove(approval_id)
                    .expect("pending approval disappeared while locked")
            };
            self.peer
                .respond(pending.request_id, approval_result(decision))
                .await
                .map_err(driver_error)
        })
    }

    fn resolve_question<'a>(
        &'a self,
        request_id: &'a str,
        answers: Vec<QuestionAnswer>,
    ) -> DriverFuture<'a, ()> {
        Box::pin(async move {
            let pending = {
                let mut questions = self.questions.lock().expect("Codex question map poisoned");
                let pending = questions.get(request_id).ok_or_else(|| {
                    DriverError::Rejected(format!("question {request_id} is no longer pending"))
                })?;
                let answer_ids = answers
                    .iter()
                    .map(|answer| answer.question_id.as_str())
                    .collect::<HashSet<_>>();
                if answer_ids.len() != answers.len()
                    || answer_ids.len() != pending.question_ids.len()
                    || !answer_ids
                        .iter()
                        .all(|question_id| pending.question_ids.contains(*question_id))
                {
                    return Err(DriverError::Rejected(format!(
                        "question {request_id} received an incomplete or invalid answer set"
                    )));
                }
                questions
                    .remove(request_id)
                    .expect("pending question disappeared while locked")
            };
            self.peer
                .respond(pending.request_id, question_result(answers))
                .await
                .map_err(driver_error)
        })
    }

    fn shutdown<'a>(&'a self) -> DriverFuture<'a, ()> {
        Box::pin(async move {
            fail_all_routes(
                &self.routing,
                DriverError::Unavailable("Codex driver shut down".to_string()),
            );
            self.approvals
                .lock()
                .expect("Codex approval map poisoned")
                .clear();
            self.questions
                .lock()
                .expect("Codex question map poisoned")
                .clear();
            match &self.shutdown_hook {
                Some(hook) => tokio::time::timeout(CONNECTION_SHUTDOWN_TIMEOUT, hook())
                    .await
                    .map_err(|_| {
                        DriverError::ProcessExited(
                            "Codex connection shutdown timed out".to_string(),
                        )
                    })?,
                None => Ok(()),
            }
        })
    }
}

async fn dispatch_incoming<W>(
    peer: CodexPeer<W>,
    mut incoming: mpsc::Receiver<IncomingMessage>,
    state: IncomingDispatchState,
    shutdown_hook: Option<WeakShutdownHook>,
) where
    W: AsyncWrite + Unpin + Send + 'static,
{
    let IncomingDispatchState {
        routing,
        approvals,
        questions,
        host_tools,
        session_observers,
    } = state;
    while let Some(message) = incoming.recv().await {
        match message {
            IncomingMessage::Notification {
                wire_sequence,
                method,
                params,
            } => {
                if session_observers.route_notification(wire_sequence, &method, &params) {
                    continue;
                }
                let thread_id = params
                    .get("threadId")
                    .and_then(Value::as_str)
                    .map(str::to_string);
                // The compaction item identifies the operation; an unrelated
                // turn/started notification must never satisfy this claim.
                let starts_compaction = method == "item/started"
                    && params.pointer("/item/type").and_then(Value::as_str)
                        == Some("contextCompaction");
                let failed_before_start = (method == "error"
                    && params.get("willRetry").and_then(Value::as_bool) == Some(false))
                    || (method == "turn/completed"
                        && matches!(
                            params.pointer("/turn/status").and_then(Value::as_str),
                            Some("failed" | "interrupted")
                        ));
                let unsupported = unsupported_notification_diagnostic(&method, &params);
                let terminal_notification = method == "turn/completed";
                match normalize_notification(CodexNotification { method, params }) {
                    Ok(events) => {
                        if let Some(diagnostic) = unsupported {
                            log::debug!("{diagnostic}");
                        }
                        for event in events {
                            if (starts_compaction || failed_before_start)
                                && let Some(thread_id) = thread_id.as_deref()
                            {
                                let turn_id = event_turn_id(&event);
                                let sender = {
                                    let mut routing =
                                        routing.lock().expect("Codex event routing poisoned");
                                    if routing.terminal_turns.contains(turn_id)
                                        || routing.compaction_starts.get(thread_id).is_none_or(
                                            |pending| wire_sequence <= pending.after_sequence,
                                        )
                                    {
                                        None
                                    } else {
                                        routing.compaction_starts.remove(thread_id)
                                    }
                                };
                                if let Some(pending) = sender {
                                    let _ = pending.sender.send(Ok(turn_id.clone()));
                                }
                            }
                            route_event(event, &routing, &approvals, &questions);
                        }
                    }
                    Err(error) if terminal_notification => {
                        // An undecodable terminal state must not leave every
                        // consumer waiting forever for a completion we discarded.
                        fail_all_routes(
                            &routing,
                            DriverError::ProcessExited(format!(
                                "Codex sent an incompatible turn completion: {error}. Update Codex and the Inline CLI, then retry."
                            )),
                        );
                        peer.abort();
                    }
                    Err(error) => log::warn!("ignoring invalid Codex notification: {error}"),
                }
            }
            IncomingMessage::ServerRequest {
                id, method, params, ..
            } => {
                if session_observers.claims_thread_traffic(&params) {
                    // Codex broadcasts thread-scoped requests to every
                    // subscriber. This connection is observation-only: an
                    // existing controller remains the sole responder until
                    // shared control ownership is implemented.
                    continue;
                }
                if method == "item/tool/call" {
                    let configuration = host_tools
                        .lock()
                        .expect("Codex host tools poisoned")
                        .clone();
                    let peer = peer.clone();
                    tokio::spawn(async move {
                        let result = match configuration {
                            Some(configuration) => {
                                execute_host_tool_call(configuration, &params).await
                            }
                            None => HostToolResult::failure(
                                "Inline tools are unavailable for this provider session.",
                            ),
                        };
                        let response = json!({
                            "contentItems": [{ "type": "inputText", "text": result.content }],
                            "success": result.success,
                        });
                        let _ = peer.respond(id, response).await;
                    });
                    continue;
                }
                if method == "item/tool/requestUserInput" {
                    match normalize_question_request(&id, &method, &params) {
                        Ok(question) => {
                            let mut pending =
                                questions.lock().expect("Codex question map poisoned");
                            if pending.contains_key(&question.request_id)
                                || pending.len() >= MAX_PENDING_INTERACTIONS
                                || pending
                                    .values()
                                    .filter(|candidate| candidate.turn_id == question.turn_id)
                                    .count()
                                    >= MAX_PENDING_INTERACTIONS_PER_TURN
                            {
                                drop(pending);
                                let peer = peer.clone();
                                tokio::spawn(async move {
                                    let _ = peer
                                        .respond_error(
                                            id,
                                            -32000,
                                            "too many pending agent interactions",
                                        )
                                        .await;
                                });
                                continue;
                            }
                            pending.insert(
                                question.request_id.clone(),
                                PendingQuestion {
                                    request_id: id,
                                    turn_id: question.turn_id.clone(),
                                    question_ids: question
                                        .questions
                                        .iter()
                                        .map(|question| question.question_id.clone())
                                        .collect(),
                                },
                            );
                            drop(pending);
                            route_event(
                                AgentEvent::QuestionRequested(question),
                                &routing,
                                &approvals,
                                &questions,
                            );
                        }
                        Err(error) => {
                            log::warn!("rejecting invalid Codex question request: {error}");
                            let peer = peer.clone();
                            tokio::spawn(async move {
                                let _ = peer.respond_error(id, -32602, &error.to_string()).await;
                            });
                        }
                    }
                    continue;
                }
                match normalize_server_request(&id, &method, &params) {
                    Ok(approval) => {
                        let mut pending = approvals.lock().expect("Codex approval map poisoned");
                        if pending.contains_key(&approval.approval_id)
                            || pending.len() >= MAX_PENDING_INTERACTIONS
                            || pending
                                .values()
                                .filter(|candidate| candidate.turn_id == approval.turn_id)
                                .count()
                                >= MAX_PENDING_INTERACTIONS_PER_TURN
                        {
                            drop(pending);
                            let peer = peer.clone();
                            tokio::spawn(async move {
                                let _ = peer
                                    .respond_error(
                                        id,
                                        -32000,
                                        "too many pending agent interactions",
                                    )
                                    .await;
                            });
                            continue;
                        }
                        pending.insert(
                            approval.approval_id.clone(),
                            PendingApproval {
                                request_id: id,
                                turn_id: approval.turn_id.clone(),
                                options: approval.options.clone(),
                            },
                        );
                        drop(pending);
                        route_event(
                            AgentEvent::ApprovalRequested(approval),
                            &routing,
                            &approvals,
                            &questions,
                        );
                    }
                    Err(error) => {
                        log::warn!("rejecting unsupported Codex server request: {error}");
                        let peer = peer.clone();
                        tokio::spawn(async move {
                            let _ = peer.respond_error(id, -32601, &error.to_string()).await;
                        });
                    }
                }
            }
        }
    }
    approvals
        .lock()
        .expect("Codex approval map poisoned")
        .clear();
    questions
        .lock()
        .expect("Codex question map poisoned")
        .clear();
    fail_all_routes(
        &routing,
        DriverError::ProcessExited("Codex app-server disconnected".to_string()),
    );
    session_observers.fail_all(DriverError::ProcessExited(
        "Codex app-server disconnected".to_string(),
    ));
    if let Some(shutdown_hook) = shutdown_hook.and_then(|hook| hook.upgrade()) {
        let _ = shutdown_hook().await;
    }
}

async fn execute_host_tool_call(
    configuration: HostToolConfiguration,
    params: &Value,
) -> HostToolResult {
    let Some(call_id) = params.get("callId").and_then(Value::as_str) else {
        return HostToolResult::failure("Inline tool call is missing callId.");
    };
    let Some(session_id) = params.get("threadId").and_then(Value::as_str) else {
        return HostToolResult::failure("Inline tool call is missing threadId.");
    };
    let Some(turn_id) = params.get("turnId").and_then(Value::as_str) else {
        return HostToolResult::failure("Inline tool call is missing turnId.");
    };
    let Some(tool_name) = params.get("tool").and_then(Value::as_str) else {
        return HostToolResult::failure("Inline tool call is missing tool.");
    };
    if !configuration
        .specs
        .iter()
        .any(|tool| tool.name == tool_name)
    {
        return HostToolResult::failure("Unknown Inline tool.");
    }
    let Ok(session_id) = ProviderSessionId::new(session_id) else {
        return HostToolResult::failure("Inline tool call has an invalid threadId.");
    };
    let Ok(turn_id) = TurnId::new(turn_id) else {
        return HostToolResult::failure("Inline tool call has an invalid turnId.");
    };
    let arguments = params
        .get("arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let encoded_len = serde_json::to_vec(&arguments).map_or(usize::MAX, |value| value.len());
    if !arguments.is_object() || encoded_len > 32 * 1024 {
        return HostToolResult::failure("Inline tool arguments are invalid or too large.");
    }
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(20),
        configuration.handler.call(HostToolCall {
            call_id: call_id.to_string(),
            session_id,
            turn_id,
            tool_name: tool_name.to_string(),
            arguments,
        }),
    )
    .await;
    match result {
        Ok(mut result) => {
            result.content = result.content.chars().take(16_000).collect();
            result
        }
        Err(_) => HostToolResult::failure("Inline tool call timed out."),
    }
}

fn route_event(
    event: AgentEvent,
    routing: &SharedEventRouting,
    approvals: &PendingApprovals,
    questions: &PendingQuestions,
) {
    let turn_id = event_turn_id(&event).clone();
    let terminal = matches!(event, AgentEvent::TurnCompleted { .. });
    log::trace!(
        target: "inline_agent_driver_codex::event",
        "phase=event_normalized turn_id={:?} event_kind={} terminal={terminal}",
        turn_id.as_str(),
        agent_event_kind(&event)
    );
    let sender = {
        let mut routing = routing.lock().expect("Codex event routing poisoned");
        if routing.terminal_turns.contains(&turn_id) {
            log::warn!("ignoring Codex event received after terminal turn completion");
            return;
        }
        let sender = routing.routes.get(&turn_id).cloned();
        if sender.is_none() {
            if !routing.backlog.contains_key(&turn_id)
                && routing.backlog.len() >= MAX_UNCLAIMED_TURNS
            {
                log::warn!("dropping event for an unclaimed Codex turn at backlog limit");
                return;
            }
            let backlog = routing.backlog.entry(turn_id.clone()).or_default();
            if let Some(position) = backlog_activity_upsert_position(&backlog.events, &event) {
                backlog.events[position] = event.clone();
            } else if !append_to_backlog_delta(&mut backlog.events, &event) {
                if backlog.events.len() == MAX_UNCLAIMED_EVENTS_PER_TURN {
                    backlog.events.clear();
                    backlog.overflowed = true;
                    backlog.terminal = true;
                } else if !backlog.overflowed {
                    backlog.events.push(event.clone());
                }
            }
            if !backlog.overflowed {
                backlog.terminal |= terminal;
            }
        }
        if terminal {
            routing.routes.remove(&turn_id);
            routing.remember_terminal(turn_id.clone());
        }
        sender
    };
    if let Some(sender) = sender {
        let _ = sender.send(Ok(event));
    }
    if terminal {
        approvals
            .lock()
            .expect("Codex approval map poisoned")
            .retain(|_, pending| pending.turn_id != turn_id);
        questions
            .lock()
            .expect("Codex question map poisoned")
            .retain(|_, pending| pending.turn_id != turn_id);
    }
}

fn agent_event_kind(event: &AgentEvent) -> &'static str {
    match event {
        AgentEvent::TurnStarted { .. } => "turn_started",
        AgentEvent::AgentMessage { .. } => "agent_message",
        AgentEvent::AgentTextDelta { .. } => "agent_text_delta",
        AgentEvent::AgentTextCompleted { .. } => "agent_text_completed",
        AgentEvent::Activity { .. } => "activity",
        AgentEvent::ActivityUpsert { .. } => "activity_upsert",
        AgentEvent::ActivityTextDelta { .. } => "activity_text_delta",
        AgentEvent::PlanUpdated { .. } => "plan_updated",
        AgentEvent::ApprovalRequested(_) => "approval_requested",
        AgentEvent::ApprovalClosed { .. } => "approval_closed",
        AgentEvent::QuestionRequested(_) => "question_requested",
        AgentEvent::FilesChanged { .. } => "files_changed",
        AgentEvent::OutputAttachment { .. } => "output_attachment",
        AgentEvent::TurnCompleted { .. } => "turn_completed",
    }
}

fn backlog_activity_upsert_position(events: &[AgentEvent], event: &AgentEvent) -> Option<usize> {
    let AgentEvent::ActivityUpsert { turn_id, activity } = event else {
        return None;
    };
    events.iter().rposition(|candidate| {
        matches!(
            candidate,
            AgentEvent::ActivityUpsert {
                turn_id: candidate_turn,
                activity: candidate_activity,
            } if candidate_turn == turn_id && candidate_activity.activity_id == activity.activity_id
        )
    })
}

fn append_to_backlog_delta(events: &mut [AgentEvent], event: &AgentEvent) -> bool {
    let Some(pending) = events.last_mut() else {
        return false;
    };
    match (pending, event) {
        (
            AgentEvent::AgentMessage {
                turn_id: pending_turn,
                item_id: pending_item,
                phase: pending_phase,
                update: inline_agent_bridge::AgentMessageUpdate::Delta(pending_text),
            },
            AgentEvent::AgentMessage {
                turn_id,
                item_id,
                phase,
                update: inline_agent_bridge::AgentMessageUpdate::Delta(text),
            },
        ) if pending_turn == turn_id && pending_item == item_id && pending_phase == phase => {
            pending_text.push_str(text);
            true
        }
        (
            AgentEvent::AgentTextDelta {
                turn_id: pending_turn,
                text: pending_text,
            },
            AgentEvent::AgentTextDelta { turn_id, text },
        ) if pending_turn == turn_id => {
            pending_text.push_str(text);
            true
        }
        (
            AgentEvent::ActivityTextDelta {
                turn_id: pending_turn,
                activity_id: pending_activity,
                stream: pending_stream,
                index: pending_index,
                delta: pending_delta,
            },
            AgentEvent::ActivityTextDelta {
                turn_id,
                activity_id,
                stream,
                index,
                delta,
            },
        ) if pending_turn == turn_id
            && pending_activity == activity_id
            && pending_stream == stream
            && pending_index == index =>
        {
            pending_delta.push_str(delta);
            true
        }
        _ => false,
    }
}

fn event_turn_id(event: &AgentEvent) -> &TurnId {
    match event {
        AgentEvent::AgentMessage { turn_id, .. }
        | AgentEvent::TurnStarted { turn_id }
        | AgentEvent::AgentTextDelta { turn_id, .. }
        | AgentEvent::AgentTextCompleted { turn_id, .. }
        | AgentEvent::Activity { turn_id, .. }
        | AgentEvent::ActivityUpsert { turn_id, .. }
        | AgentEvent::ActivityTextDelta { turn_id, .. }
        | AgentEvent::PlanUpdated { turn_id, .. }
        | AgentEvent::ApprovalClosed { turn_id, .. }
        | AgentEvent::FilesChanged { turn_id, .. }
        | AgentEvent::OutputAttachment { turn_id, .. }
        | AgentEvent::TurnCompleted { turn_id, .. } => turn_id,
        AgentEvent::ApprovalRequested(request) => &request.turn_id,
        AgentEvent::QuestionRequested(request) => &request.turn_id,
    }
}

fn fail_all_routes(routing: &SharedEventRouting, error: DriverError) {
    let (routes, compactions) = {
        let mut routing = routing.lock().expect("Codex event routing poisoned");
        (
            std::mem::take(&mut routing.routes),
            std::mem::take(&mut routing.compaction_starts),
        )
    };
    for (_, sender) in routes {
        let _ = sender.send(Err(error.clone()));
    }
    for (_, pending) in compactions {
        let _ = pending.sender.send(Err(error.clone()));
    }
}

fn decision_is_offered(options: &[ApprovalOption], decision: &ApprovalDecision) -> bool {
    match decision {
        ApprovalDecision::ApproveOnce => options.contains(&ApprovalOption::ApproveOnce),
        ApprovalDecision::ApproveForSession => options.contains(&ApprovalOption::ApproveForSession),
        ApprovalDecision::Reject => options.contains(&ApprovalOption::Reject),
        ApprovalDecision::CancelTurn => options.contains(&ApprovalOption::CancelTurn),
        ApprovalDecision::ProviderChoice { option_id } => options.iter().any(|option| {
            matches!(
                option,
                ApprovalOption::ProviderChoice {
                    option_id: offered,
                    ..
                } if offered == option_id
            )
        }),
    }
}

fn serialize(value: impl serde::Serialize) -> DriverResult<Value> {
    serde_json::to_value(value).map_err(protocol_serialization_error)
}

fn deserialize<T: serde::de::DeserializeOwned>(method: &str, value: Value) -> DriverResult<T> {
    serde_json::from_value(value).map_err(|error| {
        DriverError::Protocol(format!("failed to decode Codex {method} response: {error}"))
    })
}

fn nonempty(value: String) -> Option<String> {
    (!value.trim().is_empty()).then_some(value)
}

fn display_option_id(value: &str) -> String {
    let mut label = String::new();
    for word in value
        .trim_start_matches(':')
        .split(['-', '_'])
        .filter(|word| !word.is_empty())
    {
        if !label.is_empty() {
            label.push(' ');
        }
        let mut characters = word.chars();
        if let Some(first) = characters.next() {
            label.extend(first.to_uppercase());
            label.extend(characters);
        }
    }
    if label.is_empty() {
        value.to_string()
    } else {
        label
    }
}

fn protocol_serialization_error(error: serde_json::Error) -> DriverError {
    DriverError::Protocol(format!("failed to encode Codex request: {error}"))
}

fn incompatible_catalog_response(method: &'static str, error: serde_json::Error) -> DriverError {
    DriverError::Protocol(format!(
        "Codex {method} returned an incompatible stable response: {error}"
    ))
}

fn driver_error(error: PeerError) -> DriverError {
    match error {
        PeerError::Io(error) => DriverError::Unavailable(error.to_string()),
        PeerError::Remote(error) => DriverError::Rejected(error.to_string()),
        PeerError::Closed => {
            DriverError::ProcessExited("Codex app-server disconnected".to_string())
        }
        PeerError::Json(error) => DriverError::Protocol(error.to_string()),
        PeerError::InvalidMessage(error) => DriverError::Protocol(error),
        PeerError::IncomingAlreadyClaimed => DriverError::Protocol(
            "Codex app-server incoming stream was already initialized".to_string(),
        ),
        PeerError::Timeout(method) => {
            DriverError::Transient(format!("Codex app-server request timed out: {method}"))
        }
    }
}

fn resume_driver_error(error: PeerError) -> DriverError {
    match error {
        PeerError::Remote(error)
            if error.message.starts_with("no rollout found for thread id ")
                || error.message.starts_with("thread not found: ") =>
        {
            DriverError::InvalidSession(error.to_string())
        }
        PeerError::Remote(error)
            if error.message.contains("already has an active writer")
                || error
                    .message
                    .contains("is closing; retry thread/resume after the thread is closed") =>
        {
            DriverError::SessionBusy(
                "Close this session in the other Codex app or CLI, then try again.".to_string(),
            )
        }
        error => driver_error(error),
    }
}

#[cfg(test)]
mod tests {
    use futures_util::StreamExt;
    use inline_agent_bridge::{ActivitySemanticKind, ActivityStatus, ActivityUpsert};
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    use super::*;

    fn image_attachment(uri: &str) -> InputAttachment {
        InputAttachment {
            kind: InputAttachmentKind::Image,
            uri: uri.to_string(),
            local_uri: None,
            mime_type: Some("image/png".to_string()),
            file_name: Some("image.png".to_string()),
            size_bytes: Some(3),
            width: None,
            height: None,
            duration_ms: None,
        }
    }

    #[test]
    fn native_audio_inputs_are_feature_gated_without_version_locking_future_runtimes() {
        assert!(!native_audio_inputs_supported(
            "codex_app_server/0.150.0-alpha.8"
        ));
        assert!(native_audio_inputs_supported(
            "codex_app_server/0.151.0-alpha.7.2"
        ));
        assert!(native_audio_inputs_supported(
            "Codex App Server future-channel"
        ));
    }

    #[tokio::test]
    async fn older_catalog_runtime_rejects_audio_before_sending_an_unknown_wire_variant() {
        let mut attachment = image_attachment("https://cdn.inline.chat/voice.m4a");
        attachment.kind = InputAttachmentKind::Audio;
        attachment.mime_type = Some("audio/mp4".to_string());

        let error = codex_attachment_inputs(vec![attachment], false)
            .await
            .expect_err("old Codex audio support");
        assert_eq!(
            error,
            DriverError::Rejected(
                "this Codex runtime does not support audio inputs; update Codex or ChatGPT"
                    .to_string()
            )
        );
    }

    #[tokio::test]
    async fn existing_image_data_urls_pass_through_without_network_access() {
        let inputs =
            codex_attachment_inputs(vec![image_attachment("data:image/png;base64,YWJj")], true)
                .await
                .expect("image inputs");
        assert_eq!(
            inputs,
            vec![UserInput::Image {
                url: "data:image/png;base64,YWJj".to_string()
            }]
        );
    }

    #[tokio::test]
    async fn local_images_are_native_inputs_with_a_passive_file_reference() {
        let directory = tempfile::tempdir().expect("directory");
        let path = directory.path().join("image.png");
        tokio::fs::write(&path, b"abc").await.expect("image");
        let mut attachment = image_attachment("https://cdn.inline.chat/image.png");
        attachment.local_uri = Some(
            reqwest::Url::from_file_path(&path)
                .expect("file URL")
                .to_string(),
        );

        let inputs = codex_attachment_inputs(vec![attachment], true)
            .await
            .expect("image inputs");
        assert!(matches!(
            &inputs[0],
            UserInput::LocalImage { path: input_path } if input_path == &path
        ));
        assert!(matches!(
            &inputs[1],
            UserInput::Text { text }
                if text.contains("file://")
                    && text.contains("return_attachment")
                    && text.contains("only when the user explicitly asks")
        ));
    }

    #[tokio::test]
    async fn local_audio_uses_the_native_app_server_path_input() {
        let directory = tempfile::tempdir().expect("directory");
        let path = directory.path().join("voice.m4a");
        tokio::fs::write(&path, b"abc").await.expect("audio");
        let attachment = InputAttachment {
            kind: InputAttachmentKind::Audio,
            uri: "https://cdn.inline.chat/voice.m4a".to_string(),
            local_uri: Some(
                reqwest::Url::from_file_path(&path)
                    .expect("file URL")
                    .to_string(),
            ),
            mime_type: Some("audio/mp4".to_string()),
            file_name: Some("voice.m4a".to_string()),
            size_bytes: Some(3),
            width: None,
            height: None,
            duration_ms: Some(1_000),
        };

        let inputs = codex_attachment_inputs(vec![attachment], true)
            .await
            .expect("audio inputs");
        assert!(matches!(
            &inputs[0],
            UserInput::LocalAudio { path: input_path } if input_path == &path
        ));
        assert!(matches!(
            &inputs[1],
            UserInput::Text { text } if text.contains("file://")
        ));
    }

    #[tokio::test]
    async fn remote_codex_images_require_https() {
        let error =
            codex_attachment_inputs(vec![image_attachment("http://example.test/a.png")], true)
                .await
                .expect_err("insecure image URL must fail");
        assert_eq!(
            error,
            DriverError::Rejected("attached image URL must use HTTPS".to_string())
        );
    }

    #[test]
    fn image_media_types_are_normalized_and_strict() {
        assert_eq!(normalized_image_mime_type("image/webp"), Some("image/webp"));
        assert_eq!(
            normalized_image_mime_type("image/jpeg; charset=binary"),
            Some("image/jpeg")
        );
        assert_eq!(normalized_image_mime_type("text/html"), None);
        assert_eq!(normalized_image_mime_type("image/png,evil"), None);
    }

    #[test]
    fn resume_only_rotates_authoritatively_missing_codex_threads() {
        assert!(matches!(
            resume_driver_error(PeerError::Remote(RemoteError {
                code: Some(-32600),
                message: "no rollout found for thread id 00000000-0000-4000-8000-000000000001"
                    .to_string(),
            })),
            DriverError::InvalidSession(_)
        ));
        assert!(matches!(
            resume_driver_error(PeerError::Remote(RemoteError {
                code: Some(-32600),
                message: "thread 00000000-0000-4000-8000-000000000001 is closing; retry thread/resume after the thread is closed".to_string(),
            })),
            DriverError::SessionBusy(_)
        ));
        assert!(matches!(
            resume_driver_error(PeerError::Remote(RemoteError {
                code: Some(-32600),
                message: "thread private-id already has an active writer".to_string(),
            })),
            DriverError::SessionBusy(message)
                if message == "Close this session in the other Codex app or CLI, then try again."
        ));
        assert!(matches!(
            resume_driver_error(PeerError::Timeout("thread/resume".to_string())),
            DriverError::Transient(_)
        ));
    }

    #[tokio::test]
    async fn busy_resume_unsubscribes_only_the_rejected_thread() {
        let (driver, mut server) = initialized_driver().await;
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(&mut server);
            let mut lines = BufReader::new(reader).lines();
            let resume: Value = serde_json::from_str(
                &lines
                    .next_line()
                    .await
                    .expect("resume read")
                    .expect("resume line"),
            )
            .expect("resume json");
            assert_eq!(resume["method"], "thread/resume");
            writer
                .write_all(
                    format!(
                        "{{\"id\":{},\"error\":{{\"code\":-32600,\"message\":\"thread thread-busy already has an active writer\"}}}}\n",
                        resume["id"]
                    )
                    .as_bytes(),
                )
                .await
                .expect("busy response");

            let unsubscribe: Value = serde_json::from_str(
                &lines
                    .next_line()
                    .await
                    .expect("unsubscribe read")
                    .expect("unsubscribe line"),
            )
            .expect("unsubscribe json");
            assert_eq!(unsubscribe["method"], "thread/unsubscribe");
            assert_eq!(unsubscribe["params"]["threadId"], "thread-busy");
            writer
                .write_all(
                    format!(
                        "{{\"id\":{},\"result\":{{\"status\":\"notSubscribed\"}}}}\n",
                        unsubscribe["id"]
                    )
                    .as_bytes(),
                )
                .await
                .expect("unsubscribe response");
        });

        assert!(matches!(
            driver
                .resume_session(ResumeSessionSpec {
                    session_id: ProviderSessionId::new("thread-busy").expect("session"),
                    cwd: "/repo".into(),
                    replay: SessionReplay::None,
                })
                .await,
            Err(DriverError::SessionBusy(_))
        ));
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn busy_resume_ends_epoch_when_subscription_cleanup_is_unconfirmed() {
        let (mut driver, mut server) = initialized_driver().await;
        let stopped = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let hook_stopped = stopped.clone();
        driver.shutdown_hook = Some(Arc::new(move || {
            let hook_stopped = hook_stopped.clone();
            Box::pin(async move {
                hook_stopped.store(true, std::sync::atomic::Ordering::Release);
                Ok(())
            })
        }));
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(&mut server);
            let mut lines = BufReader::new(reader).lines();
            let resume: Value = serde_json::from_str(
                &lines
                    .next_line()
                    .await
                    .expect("resume read")
                    .expect("resume line"),
            )
            .expect("resume json");
            writer
                .write_all(
                    format!(
                        "{{\"id\":{},\"error\":{{\"code\":-32600,\"message\":\"thread thread-busy already has an active writer\"}}}}\n",
                        resume["id"]
                    )
                    .as_bytes(),
                )
                .await
                .expect("busy response");
            let unsubscribe: Value = serde_json::from_str(
                &lines
                    .next_line()
                    .await
                    .expect("unsubscribe read")
                    .expect("unsubscribe line"),
            )
            .expect("unsubscribe json");
            assert_eq!(unsubscribe["method"], "thread/unsubscribe");
            writer
                .write_all(
                    format!(
                        "{{\"id\":{},\"error\":{{\"code\":-32000,\"message\":\"cleanup failed\"}}}}\n",
                        unsubscribe["id"]
                    )
                    .as_bytes(),
                )
                .await
                .expect("cleanup failure");
        });

        assert!(matches!(
            driver
                .resume_session(ResumeSessionSpec {
                    session_id: ProviderSessionId::new("thread-busy").expect("session"),
                    cwd: "/repo".into(),
                    replay: SessionReplay::None,
                })
                .await,
            Err(DriverError::ProcessExited(_))
        ));
        assert!(stopped.load(std::sync::atomic::Ordering::Acquire));
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn cancelling_a_just_finished_turn_still_cleans_background_terminals() {
        let (mut driver, mut server) = initialized_driver().await;
        let stopped = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let hook_stopped = stopped.clone();
        driver.shutdown_hook = Some(Arc::new(move || {
            let hook_stopped = hook_stopped.clone();
            Box::pin(async move {
                hook_stopped.store(true, std::sync::atomic::Ordering::Release);
                Ok(())
            })
        }));
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(&mut server);
            let mut lines = BufReader::new(reader).lines();
            let request: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("interrupt request"))
                    .expect("interrupt json");
            assert_eq!(request["method"], "turn/interrupt");
            let response = json!({
                "id": request["id"],
                "error": {
                    "code": -32600,
                    "message": "no active turn to interrupt"
                }
            });
            writer
                .write_all(format!("{response}\n").as_bytes())
                .await
                .expect("interrupt response");
            let clean: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("clean request"))
                    .expect("clean json");
            assert_eq!(clean["method"], "thread/backgroundTerminals/clean");
            writer
                .write_all(format!("{{\"id\":{},\"result\":{{}}}}\n", clean["id"]).as_bytes())
                .await
                .expect("clean response");
            for _ in 0..2 {
                let list: Value =
                    serde_json::from_str(&lines.next_line().await.unwrap().expect("list request"))
                        .expect("list json");
                writer
                    .write_all(
                        format!(
                            "{{\"id\":{},\"result\":{{\"data\":[],\"nextCursor\":null}}}}\n",
                            list["id"]
                        )
                        .as_bytes(),
                    )
                    .await
                    .expect("list response");
            }
        });

        driver
            .cancel_turn(
                &ProviderSessionId::new("thread-1").expect("session"),
                &TurnId::new("turn-1").expect("turn"),
            )
            .await
            .expect("just-finished cancellation should clean safely");
        assert!(!stopped.load(std::sync::atomic::Ordering::Acquire));
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn cancelling_an_active_turn_cleans_background_terminals() {
        let (mut driver, mut server) = initialized_driver().await;
        let stopped = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let hook_stopped = stopped.clone();
        driver.shutdown_hook = Some(Arc::new(move || {
            let hook_stopped = hook_stopped.clone();
            Box::pin(async move {
                hook_stopped.store(true, std::sync::atomic::Ordering::Release);
                Ok(())
            })
        }));
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(&mut server);
            let mut lines = BufReader::new(reader).lines();
            let request: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("interrupt request"))
                    .expect("interrupt json");
            writer
                .write_all(format!("{{\"id\":{},\"result\":{{}}}}\n", request["id"]).as_bytes())
                .await
                .expect("interrupt response");
            let clean: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("clean request"))
                    .expect("clean json");
            assert_eq!(clean["method"], "thread/backgroundTerminals/clean");
            writer
                .write_all(format!("{{\"id\":{},\"result\":{{}}}}\n", clean["id"]).as_bytes())
                .await
                .expect("clean response");
            for data in [json!([]), json!([])] {
                let list: Value =
                    serde_json::from_str(&lines.next_line().await.unwrap().expect("list request"))
                        .expect("list json");
                assert_eq!(list["method"], "thread/backgroundTerminals/list");
                writer
                    .write_all(
                        format!(
                            "{{\"id\":{},\"result\":{{\"data\":{data},\"nextCursor\":null}}}}\n",
                            list["id"],
                        )
                        .as_bytes(),
                    )
                    .await
                    .expect("list response");
            }
            // Simulate a process registering after the early cleanup drained
            // but before Codex confirms the interrupted turn.
            writer.write_all(
                b"{\"method\":\"turn/completed\",\"params\":{\"turn\":{\"id\":\"turn-1\",\"status\":\"interrupted\"}}}\n",
            ).await.expect("turn completed");
            let final_clean: Value = serde_json::from_str(
                &lines
                    .next_line()
                    .await
                    .unwrap()
                    .expect("final clean request"),
            )
            .expect("final clean json");
            assert_eq!(final_clean["method"], "thread/backgroundTerminals/clean");
            writer
                .write_all(format!("{{\"id\":{},\"result\":{{}}}}\n", final_clean["id"]).as_bytes())
                .await
                .expect("final clean response");
            for data in [json!([{"processId": "late"}]), json!([]), json!([])] {
                let list: Value = serde_json::from_str(
                    &lines
                        .next_line()
                        .await
                        .unwrap()
                        .expect("final list request"),
                )
                .expect("final list json");
                writer
                    .write_all(
                        format!(
                            "{{\"id\":{},\"result\":{{\"data\":{data},\"nextCursor\":null}}}}\n",
                            list["id"],
                        )
                        .as_bytes(),
                    )
                    .await
                    .expect("final list response");
            }
        });

        driver
            .cancel_turn(
                &ProviderSessionId::new("thread-1").expect("session"),
                &TurnId::new("turn-1").expect("turn"),
            )
            .await
            .expect("active cancellation should clean background terminals");
        assert!(!stopped.load(std::sync::atomic::Ordering::Acquire));
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn cancellation_cleanup_failure_ends_the_provider_epoch() {
        let (mut driver, mut server) = initialized_driver().await;
        let stopped = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let hook_stopped = stopped.clone();
        driver.shutdown_hook = Some(Arc::new(move || {
            let hook_stopped = hook_stopped.clone();
            Box::pin(async move {
                hook_stopped.store(true, std::sync::atomic::Ordering::Release);
                Ok(())
            })
        }));
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(&mut server);
            let mut lines = BufReader::new(reader).lines();
            let interrupt: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("interrupt request"))
                    .expect("interrupt json");
            writer
                .write_all(format!("{{\"id\":{},\"result\":{{}}}}\n", interrupt["id"]).as_bytes())
                .await
                .expect("interrupt response");
            writer
                .write_all(
                    b"{\"method\":\"turn/completed\",\"params\":{\"turn\":{\"id\":\"turn-1\",\"status\":\"interrupted\"}}}\n",
                )
                .await
                .expect("turn completed");
            let clean: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("clean request"))
                    .expect("clean json");
            writer
                .write_all(format!("{{\"id\":{},\"result\":{{}}}}\n", clean["id"]).as_bytes())
                .await
                .expect("clean response");
            let list: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("list request"))
                    .expect("list json");
            writer
                .write_all(
                    format!(
                        "{{\"id\":{},\"result\":{{\"unexpected\":true}}}}\n",
                        list["id"]
                    )
                    .as_bytes(),
                )
                .await
                .expect("malformed list response");
        });

        let result = driver
            .cancel_turn(
                &ProviderSessionId::new("thread-1").expect("session"),
                &TurnId::new("turn-1").expect("turn"),
            )
            .await;
        assert!(matches!(result, Err(DriverError::ProcessExited(_))));
        assert!(stopped.load(std::sync::atomic::Ordering::Acquire));
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn ambiguous_mutating_timeout_stops_the_connection_epoch() {
        let (mut driver, _server) = initialized_driver().await;
        let stopped = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let hook_stopped = stopped.clone();
        driver.shutdown_hook = Some(Arc::new(move || {
            let hook_stopped = hook_stopped.clone();
            Box::pin(async move {
                hook_stopped.store(true, std::sync::atomic::Ordering::Release);
                Ok(())
            })
        }));

        let result = driver
            .settle_mutating_request(
                "turn/start",
                Err(PeerError::Timeout("turn/start".to_string())),
            )
            .await;
        assert!(matches!(result, Err(DriverError::ProcessExited(_))));
        assert!(stopped.load(std::sync::atomic::Ordering::Acquire));
    }

    #[tokio::test]
    async fn ambiguous_timeout_reports_unconfirmed_bounded_shutdown_truthfully() {
        let (mut driver, _server) = initialized_driver().await;
        driver.shutdown_hook = Some(Arc::new(|| Box::pin(std::future::pending())));

        let result = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            driver.settle_mutating_request(
                "turn/start",
                Err(PeerError::Timeout("turn/start".to_string())),
            ),
        )
        .await
        .expect("ambiguous shutdown must remain bounded");
        assert!(matches!(result, Err(DriverError::EpochEnded(_))));
    }

    #[tokio::test]
    async fn explicit_shutdown_allows_the_real_process_grace_period_in_tests() {
        let (mut driver, _server) = initialized_driver().await;
        driver.shutdown_hook = Some(Arc::new(|| {
            Box::pin(async {
                tokio::time::sleep(std::time::Duration::from_millis(600)).await;
                Ok(())
            })
        }));

        driver
            .shutdown()
            .await
            .expect("explicit shutdown should not use the shortened ambiguous-outcome budget");
    }

    #[test]
    fn identified_deltas_coalesce_exactly_in_the_unclaimed_control_backlog() {
        let routing = Arc::new(StdMutex::new(EventRouting::default()));
        let approvals = Arc::new(StdMutex::new(HashMap::new()));
        let questions = Arc::new(StdMutex::new(HashMap::new()));
        let turn_id = TurnId::new("turn-before-registration").unwrap();
        for update in std::iter::once(inline_agent_bridge::AgentMessageUpdate::Started)
            .chain(
                (0..MAX_UNCLAIMED_EVENTS_PER_TURN * 2)
                    .map(|_| inline_agent_bridge::AgentMessageUpdate::Delta("x".into())),
            )
            .chain(std::iter::once(
                inline_agent_bridge::AgentMessageUpdate::Completed("authoritative".into()),
            ))
        {
            route_event(
                AgentEvent::AgentMessage {
                    turn_id: turn_id.clone(),
                    item_id: "item".into(),
                    phase: Some(inline_agent_bridge::AgentMessagePhase::Commentary),
                    update,
                },
                &routing,
                &approvals,
                &questions,
            );
        }
        let routing = routing.lock().unwrap();
        let backlog = &routing.backlog[&turn_id];
        assert!(!backlog.overflowed);
        assert_eq!(backlog.events.len(), 3);
        assert!(matches!(
            backlog.events.first(),
            Some(AgentEvent::AgentMessage {
                update: inline_agent_bridge::AgentMessageUpdate::Started,
                ..
            })
        ));
        assert!(matches!(
            &backlog.events[1],
            AgentEvent::AgentMessage {
                update: inline_agent_bridge::AgentMessageUpdate::Delta(text),
                ..
            } if text.len() == MAX_UNCLAIMED_EVENTS_PER_TURN * 2
        ));
        assert!(
            matches!(backlog.events.last(), Some(AgentEvent::AgentMessage { update: inline_agent_bridge::AgentMessageUpdate::Completed(text), .. }) if text == "authoritative")
        );
    }

    #[test]
    fn unclaimed_turn_backlog_replaces_activity_snapshots_by_provider_id() {
        let turn_id = TurnId::new("turn-1").expect("turn id");
        let pending = AgentEvent::ActivityUpsert {
            turn_id: turn_id.clone(),
            activity: ActivityUpsert::new(
                "command-1",
                ActivitySemanticKind::Execute,
                ActivityStatus::InProgress,
                "Running command",
            )
            .expect("activity"),
        };
        let completed = AgentEvent::ActivityUpsert {
            turn_id,
            activity: ActivityUpsert::new(
                "command-1",
                ActivitySemanticKind::Execute,
                ActivityStatus::Completed,
                "Running command",
            )
            .expect("activity"),
        };
        let mut backlog = vec![pending];
        let position = backlog_activity_upsert_position(&backlog, &completed)
            .expect("same opaque activity should replace");
        backlog[position] = completed;
        assert!(matches!(
            backlog.as_slice(),
            [AgentEvent::ActivityUpsert { activity, .. }]
                if activity.status == ActivityStatus::Completed
        ));
    }

    async fn initialized_driver() -> (
        CodexAppServerDriver<tokio::io::WriteHalf<tokio::io::DuplexStream>>,
        tokio::io::DuplexStream,
    ) {
        let (client, mut server) = tokio::io::duplex(16 * 1024);
        let (reader, writer) = tokio::io::split(client);
        let peer = CodexPeer::new(reader, writer, 16);
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(&mut server);
            let mut lines = BufReader::new(reader).lines();
            let initialize: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("initialize line"))
                    .expect("initialize json");
            assert_eq!(initialize["method"], "initialize");
            writer
                .write_all(b"{\"id\":1,\"result\":{\"userAgent\":\"codex\"}}\n")
                .await
                .expect("initialize response");
            let initialized: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("initialized line"))
                    .expect("initialized json");
            assert_eq!(initialized["method"], "initialized");
            server
        });
        let driver = CodexAppServerDriver::initialize(peer, "0.6.2")
            .await
            .expect("driver");
        (driver, server_task.await.expect("server task"))
    }

    struct EchoHostTools;

    impl inline_agent_bridge::HostToolHandler for EchoHostTools {
        fn call<'a>(&'a self, call: HostToolCall) -> inline_agent_bridge::HostToolFuture<'a> {
            Box::pin(async move {
                HostToolResult::success(format!("{}:{}", call.tool_name, call.call_id))
            })
        }
    }

    #[tokio::test]
    async fn advertises_and_answers_dynamic_host_tools() {
        let (driver, mut server) = initialized_driver().await;
        driver
            .configure_host_tools(HostToolConfiguration {
                specs: vec![inline_agent_bridge::HostToolSpec {
                    name: "search_messages".to_string(),
                    description: "Search Inline messages".to_string(),
                    input_schema: json!({
                        "type": "object",
                        "additionalProperties": false,
                        "properties": {"query": {"type": "string"}}
                    }),
                    read_only: true,
                }],
                handler: Arc::new(EchoHostTools),
            })
            .expect("configure tools");
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(&mut server);
            let mut lines = BufReader::new(reader).lines();
            let request: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("thread start"))
                    .expect("thread start json");
            assert_eq!(request["method"], "thread/start");
            assert_eq!(
                request["params"]["dynamicTools"][0]["name"],
                "search_messages"
            );
            assert_eq!(request["params"]["dynamicTools"][0]["namespace"], "inline");
            writer
                .write_all(
                    format!(
                        "{{\"id\":{},\"result\":{{\"thread\":{{\"id\":\"thread-1\"}}}}}}\n",
                        request["id"]
                    )
                    .as_bytes(),
                )
                .await
                .expect("thread response");
            writer
                .write_all(b"{\"id\":\"tool-wire-1\",\"method\":\"item/tool/call\",\"params\":{\"callId\":\"call-1\",\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"tool\":\"search_messages\",\"arguments\":{\"query\":\"hello\"}}}\n")
                .await
                .expect("tool request");
            let response: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("tool response"))
                    .expect("tool response json");
            assert_eq!(response["id"], "tool-wire-1");
            assert_eq!(response["result"]["success"], true);
            assert_eq!(
                response["result"]["contentItems"][0]["text"],
                "search_messages:call-1"
            );
        });
        let session = driver
            .start_session(SessionSpec {
                cwd: "/repo".into(),
            })
            .await
            .expect("start session");
        assert_eq!(session.as_str(), "thread-1");
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn initializes_then_starts_and_streams_a_turn() {
        let (driver, mut server) = initialized_driver().await;
        driver
            .default_permission_profile_workspaces
            .lock()
            .expect("default permission workspaces")
            .insert("/repo".into());
        let session = ProviderSessionId::new("thread-1").expect("session id");
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(&mut server);
            let mut lines = BufReader::new(reader).lines();
            let request: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("turn request"))
                    .expect("turn json");
            assert_eq!(request["method"], "turn/start");
            assert_eq!(
                request["params"]["clientUserMessageId"],
                "inline-agent-bridge:v1:message-1"
            );
            assert_eq!(request["params"]["permissions"], DEFAULT_PERMISSION_PROFILE);
            writer
                .write_all(
                    b"{\"method\":\"turn/started\",\"params\":{\"turn\":{\"id\":\"turn-1\"}}}\n",
                )
                .await
                .expect("early event");
            writer
                .write_all(b"{\"id\":2,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}\n")
                .await
                .expect("turn response");
            writer
                .write_all(b"{\"method\":\"item/agentMessage/delta\",\"params\":{\"turnId\":\"turn-1\",\"delta\":\"Hello\"}}\n")
                .await
                .expect("delta");
        });
        let mut turn = driver
            .start_turn(
                &session,
                TurnInput {
                    text: "hello".to_string(),
                    attachments: Vec::new(),
                    client_message_id: Some("message-1".to_string()),
                },
                TurnOptions {
                    cwd: Some("/repo".into()),
                    ..TurnOptions::default()
                },
            )
            .await
            .expect("start turn");
        assert!(matches!(
            turn.events.next().await,
            Some(Ok(AgentEvent::TurnStarted { .. }))
        ));
        assert!(matches!(
            turn.events.next().await,
            Some(Ok(AgentEvent::AgentTextDelta { text, .. })) if text == "Hello"
        ));
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn routes_approval_and_responds_with_original_request_id() {
        let (driver, mut server) = initialized_driver().await;
        let session = ProviderSessionId::new("thread-1").expect("session id");
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(&mut server);
            let mut lines = BufReader::new(reader).lines();
            let _: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("turn request"))
                    .expect("turn json");
            writer
                .write_all(b"{\"id\":2,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}\n")
                .await
                .expect("turn response");
            writer
                .write_all(b"{\"method\":\"item/commandExecution/requestApproval\",\"id\":\"approval-wire-1\",\"params\":{\"turnId\":\"turn-1\",\"command\":\"cargo test\"}}\n")
                .await
                .expect("approval request");
            let response: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("approval response"))
                    .expect("approval json");
            assert_eq!(response["id"], "approval-wire-1");
            assert_eq!(response["result"]["decision"], "accept");
        });
        let mut turn = driver
            .start_turn(
                &session,
                TurnInput {
                    text: "test".to_string(),
                    attachments: Vec::new(),
                    client_message_id: None,
                },
                TurnOptions::default(),
            )
            .await
            .expect("turn");
        let approval_id = match turn.events.next().await {
            Some(Ok(AgentEvent::ApprovalRequested(request))) => request.approval_id,
            event => panic!("expected approval, got {event:?}"),
        };
        driver
            .resolve_approval(&approval_id, ApprovalDecision::ApproveOnce)
            .await
            .expect("resolve approval");
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn routes_user_input_and_responds_with_original_request_id() {
        let (driver, mut server) = initialized_driver().await;
        let session = ProviderSessionId::new("thread-1").expect("session id");
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(&mut server);
            let mut lines = BufReader::new(reader).lines();
            let _: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("turn request"))
                    .expect("turn json");
            writer
                .write_all(b"{\"id\":2,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}\n")
                .await
                .expect("turn response");
            writer
                .write_all(b"{\"method\":\"item/tool/requestUserInput\",\"id\":\"question-wire-1\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"itemId\":\"item-1\",\"questions\":[{\"id\":\"target\",\"header\":\"Target\",\"question\":\"Which target?\",\"options\":[{\"label\":\"Core\",\"description\":\"Inspect core\"},{\"label\":\"TUI\",\"description\":\"Inspect TUI\"}]}]}}\n")
                .await
                .expect("question request");
            let response: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("question response"))
                    .expect("question json");
            assert_eq!(response["id"], "question-wire-1");
            assert_eq!(
                response["result"]["answers"]["target"]["answers"],
                json!(["TUI"])
            );
        });
        let mut turn = driver
            .start_turn(
                &session,
                TurnInput {
                    text: "inspect".to_string(),
                    attachments: Vec::new(),
                    client_message_id: None,
                },
                TurnOptions::default(),
            )
            .await
            .expect("turn");
        let request_id = match turn.events.next().await {
            Some(Ok(AgentEvent::QuestionRequested(request))) => request.request_id,
            event => panic!("expected question, got {event:?}"),
        };
        driver
            .resolve_question(
                &request_id,
                vec![QuestionAnswer {
                    question_id: "target".to_string(),
                    answers: vec!["TUI".to_string()],
                }],
            )
            .await
            .expect("resolve question");
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn bypass_default_does_not_cross_from_one_workspace_to_another() {
        let (driver, mut server) = initialized_driver().await;
        driver
            .default_permission_profile_workspaces
            .lock()
            .expect("default permission workspaces")
            .insert("/catalogued".into());
        let session = ProviderSessionId::new("thread-1").expect("session id");
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(&mut server);
            let mut lines = BufReader::new(reader).lines();
            let request: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("turn request"))
                    .expect("turn json");
            assert_eq!(request["method"], "turn/start");
            assert_eq!(request["params"]["cwd"], "/other");
            assert!(request["params"].get("permissions").is_none());
            writer
                .write_all(b"{\"id\":2,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}\n")
                .await
                .expect("turn response");
        });
        driver
            .start_turn(
                &session,
                TurnInput {
                    text: "use provider default".to_string(),
                    attachments: Vec::new(),
                    client_message_id: None,
                },
                TurnOptions {
                    cwd: Some("/other".into()),
                    ..TurnOptions::default()
                },
            )
            .await
            .expect("turn");
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn terminal_event_before_start_response_does_not_leave_a_live_route() {
        let (driver, mut server) = initialized_driver().await;
        let session = ProviderSessionId::new("thread-1").expect("session id");
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(&mut server);
            let mut lines = BufReader::new(reader).lines();
            let _ = lines.next_line().await.expect("turn request");
            writer
                .write_all(
                    b"{\"method\":\"turn/started\",\"params\":{\"turn\":{\"id\":\"turn-1\"}}}\n",
                )
                .await
                .expect("turn started");
            writer
                .write_all(b"{\"method\":\"turn/completed\",\"params\":{\"turn\":{\"id\":\"turn-1\",\"status\":\"completed\"}}}\n")
                .await
                .expect("turn completed");
            writer
                .write_all(b"{\"id\":2,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}\n")
                .await
                .expect("turn response");
            writer
                .write_all(b"{\"method\":\"item/agentMessage/delta\",\"params\":{\"turnId\":\"turn-1\",\"delta\":\"too late\"}}\n")
                .await
                .expect("late delta");
        });
        let mut turn = driver
            .start_turn(
                &session,
                TurnInput {
                    text: "fast".to_string(),
                    attachments: Vec::new(),
                    client_message_id: None,
                },
                TurnOptions::default(),
            )
            .await
            .expect("turn");
        assert!(matches!(
            turn.events.next().await,
            Some(Ok(AgentEvent::TurnStarted { .. }))
        ));
        assert!(matches!(
            turn.events.next().await,
            Some(Ok(AgentEvent::TurnCompleted { .. }))
        ));
        assert!(turn.events.next().await.is_none());
        server_task.await.expect("server task");
        let routing = driver.routing.lock().expect("routing");
        assert!(
            !routing
                .routes
                .contains_key(&TurnId::new("turn-1").expect("turn id"))
        );
        assert!(
            !routing
                .backlog
                .contains_key(&TurnId::new("turn-1").expect("turn id"))
        );
    }

    #[tokio::test]
    async fn unavailable_approval_decision_is_rejected_without_consuming_request() {
        let (driver, mut server) = initialized_driver().await;
        let session = ProviderSessionId::new("thread-1").expect("session id");
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(&mut server);
            let mut lines = BufReader::new(reader).lines();
            let _ = lines.next_line().await.expect("turn request");
            writer
                .write_all(b"{\"id\":2,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}\n")
                .await
                .expect("turn response");
            writer
                .write_all(b"{\"method\":\"item/commandExecution/requestApproval\",\"id\":\"approval-wire-1\",\"params\":{\"turnId\":\"turn-1\",\"availableDecisions\":[\"accept\",\"decline\"]}}\n")
                .await
                .expect("approval request");
            let response: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("approval response"))
                    .expect("approval json");
            assert_eq!(response["result"]["decision"], "accept");
        });
        let mut turn = driver
            .start_turn(
                &session,
                TurnInput {
                    text: "test".to_string(),
                    attachments: Vec::new(),
                    client_message_id: None,
                },
                TurnOptions::default(),
            )
            .await
            .expect("turn");
        let approval_id = match turn.events.next().await {
            Some(Ok(AgentEvent::ApprovalRequested(request))) => request.approval_id,
            event => panic!("expected approval, got {event:?}"),
        };
        assert!(matches!(
            driver
                .resolve_approval(&approval_id, ApprovalDecision::ApproveForSession)
                .await,
            Err(DriverError::Rejected(_))
        ));
        driver
            .resolve_approval(&approval_id, ApprovalDecision::ApproveOnce)
            .await
            .expect("valid approval remains pending");
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn settings_catalog_preserves_provider_ids_and_capabilities() {
        let (driver, mut server) = initialized_driver().await;
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(&mut server);
            let mut lines = BufReader::new(reader).lines();
            let model_request: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().expect("model request"))
                    .expect("model json");
            assert_eq!(model_request["method"], "model/list");
            assert_eq!(model_request["params"]["includeHidden"], false);
            writer
                .write_all(
                    b"{\"id\":2,\"result\":{\"data\":[{\"model\":\"gpt-5.4\",\"displayName\":\"GPT-5.4\",\"description\":\"Coding model\",\"hidden\":false,\"supportedReasoningEfforts\":[{\"reasoningEffort\":\"xhigh\",\"description\":\"Deep reasoning\"}],\"defaultReasoningEffort\":\"xhigh\",\"isDefault\":true},{\"model\":\"gpt-6-astra\",\"displayName\":\"GPT-6 Astra\",\"description\":\"New model\",\"hidden\":false,\"supportedReasoningEfforts\":[],\"defaultReasoningEffort\":\"xhigh\",\"isDefault\":false}],\"nextCursor\":null}}\n",
                )
                .await
                .expect("model response");

            let permissions_request: Value = serde_json::from_str(
                &lines
                    .next_line()
                    .await
                    .unwrap()
                    .expect("permissions request"),
            )
            .expect("permissions json");
            assert_eq!(permissions_request["method"], "permissionProfile/list");
            assert_eq!(permissions_request["params"]["cwd"], "/tmp");
            writer
                .write_all(
                    b"{\"id\":3,\"result\":{\"data\":[{\"id\":\":workspace\",\"description\":\"Workspace access\"},{\"id\":\":danger-full-access\",\"description\":\"Bypass permissions\"},{\"id\":\"admin_mode\",\"description\":null,\"allowed\":false}],\"nextCursor\":null}}\n",
                )
                .await
                .expect("permissions response");
            let configuration_request: Value = serde_json::from_str(
                &lines
                    .next_line()
                    .await
                    .unwrap()
                    .expect("configuration request"),
            )
            .expect("configuration json");
            assert_eq!(configuration_request["method"], "config/read");
            assert_eq!(configuration_request["params"]["cwd"], "/tmp");
            assert_eq!(configuration_request["params"]["includeLayers"], false);
            writer
                .write_all(b"{\"id\":4,\"result\":{\"config\":{\"model\":\"gpt-6-astra\"}}}\n")
                .await
                .expect("configuration response");
        });

        let catalog = driver
            .settings_catalog(std::path::Path::new("/tmp"))
            .await
            .expect("catalog");
        assert_eq!(catalog.models[0].value, "gpt-5.4");
        assert!(!catalog.models[0].is_default);
        assert_eq!(catalog.models[1].value, "gpt-6-astra");
        assert!(catalog.models[1].is_default);
        assert_eq!(catalog.models[0].reasoning[0].value, "xhigh");
        assert_eq!(
            catalog.models[0].default_reasoning.as_deref(),
            Some("xhigh")
        );
        assert_eq!(catalog.permissions[0].value, ":workspace");
        assert_eq!(catalog.permissions[0].label, "Workspace");
        assert!(!catalog.permissions[0].disabled);
        assert_eq!(catalog.permissions[1].label, "Danger Full Access");
        assert_eq!(catalog.permissions[2].label, "Admin Mode");
        assert!(catalog.permissions[2].disabled);
        assert_eq!(
            catalog.default_permissions.as_deref(),
            Some(DEFAULT_PERMISSION_PROFILE)
        );
        assert!(
            driver
                .default_permission_profile_workspaces
                .lock()
                .expect("default permission workspaces")
                .contains(std::path::Path::new("/tmp"))
        );
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn settings_catalog_keeps_fresh_models_when_default_config_is_unavailable() {
        for stalled in [false, true] {
            let (driver, mut server) = initialized_driver().await;
            let (release_server, keep_open) = tokio::sync::oneshot::channel::<()>();
            let server_task = tokio::spawn(async move {
                let (reader, mut writer) = tokio::io::split(&mut server);
                let mut lines = BufReader::new(reader).lines();
                for (method, response) in [
                    (
                        "model/list",
                        json!({"result":{"data":[{
                    "model":"gpt-6-astra", "displayName":"GPT-6 Astra", "description":"New model",
                    "hidden":false, "supportedReasoningEfforts":[], "defaultReasoningEffort":"xhigh", "isDefault":true
                }], "nextCursor":null}}),
                    ),
                    (
                        "permissionProfile/list",
                        json!({"result":{"data":[], "nextCursor":null}}),
                    ),
                ] {
                    let request: Value =
                        serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
                    assert_eq!(request["method"], method);
                    let mut response = response;
                    response["id"] = request["id"].clone();
                    writer
                        .write_all(format!("{response}\n").as_bytes())
                        .await
                        .unwrap();
                }
                let request: Value =
                    serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
                assert_eq!(request["method"], "config/read");
                if stalled {
                    // Keep the transport alive without replying to the metadata read.
                    // The driver must return the models it has already loaded.
                    let _ = keep_open.await;
                } else {
                    let response = json!({
                        "id": request["id"],
                        "error": {"code": -32601, "message": "Method not found"}
                    });
                    writer
                        .write_all(format!("{response}\n").as_bytes())
                        .await
                        .unwrap();
                }
            });
            let catalog = driver
                .settings_catalog(std::path::Path::new("/tmp"))
                .await
                .unwrap();
            assert_eq!(catalog.models[0].value, "gpt-6-astra");
            assert!(
                !catalog.models[0].is_default,
                "an unavailable effective default must use generic copy"
            );
            let _ = release_server.send(());
            server_task.await.unwrap();
        }
    }

    #[tokio::test]
    async fn compaction_tracks_real_turn_events_across_ack_order_and_terminal_failure() {
        for early_events in [false, true] {
            for outcome in ["completed", "failed", "interrupted"] {
                let (driver, mut server) = initialized_driver().await;
                let server_task = tokio::spawn(async move {
                    let (reader, mut writer) = tokio::io::split(&mut server);
                    let mut lines = BufReader::new(reader).lines();
                    let preflight: Value =
                        serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
                    assert_eq!(preflight["method"], "thread/read");
                    // An old same-session compaction queued before the read
                    // barrier must not satisfy the new operation's claim.
                    let stale = json!({"method":"item/started", "params":{"threadId":"thread-1", "turnId":"old-turn", "item":{"type":"contextCompaction", "id":"old-item"}}});
                    let idle = json!({"id":preflight["id"], "result":{"thread":{"id":"thread-1", "status":{"type":"idle"}}}});
                    writer
                        .write_all(format!("{stale}\n{idle}\n").as_bytes())
                        .await
                        .unwrap();
                    let request: Value =
                        serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
                    assert_eq!(request["method"], "thread/compact/start");
                    let ack = json!({"id":request["id"], "result":{}});
                    let unrelated = json!({"method":"item/started", "params":{"threadId":"other-thread", "turnId":"other-turn", "item":{"type":"contextCompaction", "id":"other-item"}}});
                    let started = json!({"method":"turn/started", "params":{"threadId":"thread-1", "turn":{"id":"compact-turn"}}});
                    let item = json!({"method":"item/started", "params":{"threadId":"thread-1", "turnId":"compact-turn", "item":{"type":"contextCompaction", "id":"compact-item"}}});
                    let completed = json!({"method":"turn/completed", "params":{"threadId":"thread-1", "turn":{"id":"compact-turn", "status":outcome, "error":if outcome == "failed" { json!({"message":"Weekly usage limit reached."}) } else { Value::Null }}}});
                    let frames = if outcome == "failed" {
                        format!("{unrelated}\n{started}\n{completed}\n")
                    } else {
                        format!("{unrelated}\n{started}\n{item}\n{completed}\n")
                    };
                    let frames = if early_events {
                        format!("{frames}{ack}\n")
                    } else {
                        format!("{ack}\n{frames}")
                    };
                    writer.write_all(frames.as_bytes()).await.unwrap();
                });
                let mut turn = driver
                    .compact_session(&ProviderSessionId::new("thread-1").unwrap())
                    .await
                    .unwrap();
                assert_eq!(turn.turn_id.as_str(), "compact-turn");
                let mut saw_start = false;
                let mut saw_progress = false;
                let mut terminal = None;
                while let Some(event) = turn.events.next().await {
                    match event.unwrap() {
                        AgentEvent::TurnStarted { .. } => saw_start = true,
                        AgentEvent::ActivityUpsert { activity, .. } => {
                            saw_progress |= activity.title == "Compacting context"
                        }
                        AgentEvent::TurnCompleted { outcome, error, .. } => {
                            terminal = Some((outcome, error));
                            break;
                        }
                        _ => {}
                    }
                }
                assert!(saw_start && (saw_progress || outcome == "failed"));
                let (actual, error) = terminal.expect("terminal event");
                assert_eq!(
                    actual,
                    match outcome {
                        "completed" => inline_agent_bridge::TurnOutcome::Completed,
                        "failed" => inline_agent_bridge::TurnOutcome::Failed,
                        _ => inline_agent_bridge::TurnOutcome::Interrupted,
                    }
                );
                if outcome == "failed" {
                    assert_eq!(error.as_deref(), Some("Weekly usage limit reached."));
                }
                assert!(driver.routing.lock().unwrap().compaction_starts.is_empty());
                server_task.await.unwrap();
            }
        }
    }

    #[tokio::test]
    async fn cancelled_compaction_start_retires_the_ambiguous_connection() {
        let (driver, mut server) = initialized_driver().await;
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(&mut server);
            let mut lines = BufReader::new(reader).lines();
            let request: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            let response =
                json!({"id":request["id"], "result":{"thread":{"status":{"type":"idle"}}}});
            writer
                .write_all(format!("{response}\n").as_bytes())
                .await
                .unwrap();
            let request: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            let response = json!({"id":request["id"], "result":{}});
            writer
                .write_all(format!("{response}\n").as_bytes())
                .await
                .unwrap();
            let _ = lines.next_line().await;
        });
        assert!(
            tokio::time::timeout(
                std::time::Duration::from_millis(30),
                driver.compact_session(&ProviderSessionId::new("thread-1").unwrap())
            )
            .await
            .is_err()
        );
        assert!(driver.routing.lock().unwrap().compaction_starts.is_empty());
        assert!(matches!(
            driver.peer.request("model/list", json!({})).await,
            Err(PeerError::Closed)
        ));
        server_task.await.unwrap();
    }

    #[tokio::test]
    async fn incompatible_terminal_notification_fails_visible_turns_and_closes_peer() {
        let (driver, mut server) = initialized_driver().await;
        let mut events = driver.register_turn(TurnId::new("turn-1").unwrap());
        server.write_all(b"{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"thread-1\",\"turn\":{\"id\":\"turn-1\",\"status\":\"future-unknown-state\"}}}\n").await.unwrap();
        let event = tokio::time::timeout(std::time::Duration::from_secs(1), events.next())
            .await
            .unwrap()
            .unwrap();
        assert!(
            matches!(event, Err(DriverError::ProcessExited(message)) if message.contains("incompatible turn completion"))
        );
        assert!(matches!(
            driver.peer.request("model/list", json!({})).await,
            Err(PeerError::Closed)
        ));
    }

    #[tokio::test]
    async fn maps_every_supported_session_and_turn_operation() {
        let (driver, mut server) = initialized_driver().await;
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(&mut server);
            let mut lines = BufReader::new(reader).lines();
            let expected = [
                ("thread/start", json!({ "thread": { "id": "thread-1" } })),
                ("thread/resume", json!({ "thread": { "id": "thread-1" } })),
                ("turn/start", json!({ "turn": { "id": "turn-1" } })),
                ("turn/steer", json!({ "turnId": "turn-1" })),
                ("turn/interrupt", json!({})),
                ("thread/backgroundTerminals/clean", json!({})),
                (
                    "thread/backgroundTerminals/list",
                    json!({ "data": [], "nextCursor": null }),
                ),
                (
                    "thread/backgroundTerminals/list",
                    json!({ "data": [], "nextCursor": null }),
                ),
                ("thread/backgroundTerminals/clean", json!({})),
                (
                    "thread/backgroundTerminals/list",
                    json!({ "data": [], "nextCursor": null }),
                ),
                (
                    "thread/backgroundTerminals/list",
                    json!({ "data": [], "nextCursor": null }),
                ),
                (
                    "thread/read",
                    json!({"thread":{"id":"thread-1", "status":{"type":"idle"}}}),
                ),
                ("thread/compact/start", json!({})),
            ];
            for (method, result) in expected {
                let request: Value =
                    serde_json::from_str(&lines.next_line().await.unwrap().expect("request line"))
                        .expect("request json");
                assert_eq!(request["method"], method);
                if method == "thread/start" {
                    assert_eq!(request["params"]["cwd"], "/repo");
                    assert_eq!(
                        request["params"]["config"][DEFAULT_MODE_REQUEST_USER_INPUT],
                        true
                    );
                }
                if method == "thread/resume" {
                    assert_eq!(request["params"]["cwd"], "/repo");
                    assert_eq!(
                        request["params"]["config"][DEFAULT_MODE_REQUEST_USER_INPUT],
                        true
                    );
                }
                if method == "turn/steer" {
                    assert_eq!(request["params"]["expectedTurnId"], "turn-1");
                }
                if method == "turn/start" {
                    assert_eq!(request["params"]["permissions"], ":workspace");
                }
                writer
                    .write_all(
                        format!("{{\"id\":{},\"result\":{result}}}\n", request["id"]).as_bytes(),
                    )
                    .await
                    .expect("response");
                if method == "turn/interrupt" {
                    writer
                        .write_all(
                            b"{\"method\":\"turn/completed\",\"params\":{\"turn\":{\"id\":\"turn-1\",\"status\":\"interrupted\"}}}\n",
                        )
                        .await
                        .expect("turn completed");
                }
                if method == "thread/compact/start" {
                    writer.write_all(b"{\"method\":\"item/started\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"compact-turn\",\"item\":{\"id\":\"compact-item\",\"type\":\"contextCompaction\"}}}\n").await.unwrap();
                }
            }
        });
        let session = driver
            .start_session(SessionSpec {
                cwd: "/repo".into(),
            })
            .await
            .expect("start session");
        driver
            .resume_session(ResumeSessionSpec {
                session_id: session.clone(),
                cwd: "/repo".into(),
                replay: SessionReplay::None,
            })
            .await
            .expect("resume session");
        let turn = driver
            .start_turn(
                &session,
                TurnInput {
                    text: "work".to_string(),
                    attachments: Vec::new(),
                    client_message_id: Some("message-1".to_string()),
                },
                TurnOptions {
                    cwd: Some("/repo".into()),
                    model: Some("codex-model".to_string()),
                    reasoning: Some("medium".to_string()),
                    permissions: Some(":workspace".to_string()),
                },
            )
            .await
            .expect("start turn");
        driver
            .steer_turn(
                &session,
                &turn.turn_id,
                TurnInput {
                    text: "focus tests".to_string(),
                    attachments: Vec::new(),
                    client_message_id: Some("message-2".to_string()),
                },
            )
            .await
            .expect("steer turn");
        driver
            .cancel_turn(&session, &turn.turn_id)
            .await
            .expect("cancel turn");
        driver
            .compact_session(&session)
            .await
            .expect("compact session");
        server_task.await.expect("server task");
    }
}
