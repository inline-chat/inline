//! Realtime WebSocket RPC transport for Inline protocol calls.

use futures_util::{SinkExt, StreamExt};
use prost::Message;
use std::collections::HashMap;
use std::fmt;
use std::future::Future;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{Semaphore, broadcast, mpsc, oneshot, watch};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use url::Url;

use crate::client_info::{self, ClientIdentity};
use inline_protocol::proto;

/// Default timeout for opening a realtime connection.
pub const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
/// Default timeout for a single realtime RPC invocation.
pub const DEFAULT_RPC_TIMEOUT: Duration = Duration::from_secs(60);
/// Default number of queued commands accepted by a multiplexed realtime session.
pub const DEFAULT_SESSION_COMMAND_CAPACITY: usize = 64;
/// Default maximum number of RPCs awaiting responses on one realtime session.
pub const DEFAULT_SESSION_MAX_IN_FLIGHT_RPCS: usize = 64;
/// Default number of pushed events retained for each realtime session subscriber.
pub const DEFAULT_SESSION_EVENT_CAPACITY: usize = 256;
/// Default interval between protocol heartbeat pings.
pub const DEFAULT_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(5);
/// Default deadline for a matching protocol pong.
pub const DEFAULT_HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(12);

const SESSION_COMMAND_QUEUED: u8 = 0;
const SESSION_COMMAND_ADMITTED: u8 = 1;
const SESSION_COMMAND_CANCELLED: u8 = 2;

/// Error returned by realtime connection and RPC operations.
#[derive(thiserror::Error)]
#[non_exhaustive]
pub enum RealtimeError {
    /// Invalid realtime WebSocket URL supplied to a realtime client builder.
    #[error("invalid realtime URL: {message}")]
    InvalidUrl {
        /// Original URL value supplied by the caller.
        url: String,
        /// Human-readable validation failure.
        message: String,
    },
    /// WebSocket transport error.
    #[error("websocket error: {0}")]
    WebSocket(Box<tokio_tungstenite::tungstenite::Error>),
    /// A validated client identity could not be represented as a realtime header.
    #[error("{field} contains characters that are invalid in realtime headers")]
    InvalidHeaderValue {
        /// Name of the invalid realtime header field.
        field: &'static str,
    },
    /// Protobuf decode error for a server message.
    #[error("protocol error: {0}")]
    Protocol(#[from] prost::DecodeError),
    /// The server returned an RPC result envelope without a result body.
    #[error("missing rpc result")]
    MissingResult,
    /// The server returned a result oneof that does not match the requested method.
    #[error("unexpected rpc result for {method}: expected {expected}, got {actual}")]
    UnexpectedResult {
        /// Requested RPC method.
        method: &'static str,
        /// Expected result oneof variant.
        expected: &'static str,
        /// Actual result oneof variant.
        actual: &'static str,
    },
    /// A realtime operation exceeded its configured timeout.
    #[error("realtime {operation} timed out after {timeout:?}")]
    Timeout {
        /// Operation that timed out.
        operation: &'static str,
        /// Configured timeout.
        timeout: Duration,
    },
    /// Request bytes were accepted by the local carrier, but no authoritative
    /// result arrived. Callers must reconcile before retrying a mutation.
    #[error("realtime request commit outcome is unknown")]
    CommitOutcomeUnknown,
    /// The realtime server rejected the connection.
    #[error("{friendly}")]
    ConnectionError {
        /// Numeric connection-error reason.
        reason: i32,
        /// Stable protobuf enum name for the reason.
        reason_name: String,
        /// Human-readable formatted error.
        friendly: String,
    },
    /// The realtime connection closed before the requested operation completed.
    #[error("realtime connection closed")]
    ConnectionClosed,
    /// The authenticated transport proved that the account session was revoked.
    #[error("realtime session authorization was revoked")]
    AuthenticationInvalidated,
    /// The secure Inline Protocol carrier rejected an authenticated record or service message.
    #[error("Inline Protocol transport error: {message}")]
    InlineProtocol {
        /// Sanitized transport failure description.
        message: String,
    },
    /// A multiplexed event subscriber could not keep up with pushed events.
    #[error("realtime event subscriber lagged and skipped {skipped} events")]
    EventLagged {
        /// Number of events dropped for this subscriber.
        skipped: u64,
    },
    /// The realtime server returned an RPC error for a request.
    #[error("{friendly}")]
    RpcError {
        /// Transport-level status code.
        code: i32,
        /// Inline RPC error code.
        error_code: i32,
        /// Stable protobuf enum name for the RPC error.
        error_name: String,
        /// Server-provided error message.
        message: String,
        /// Human-readable formatted error.
        friendly: String,
    },
}

impl fmt::Debug for RealtimeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RealtimeError::InvalidUrl { url, message } => f
                .debug_struct("InvalidUrl")
                .field("url", &realtime_url_for_debug(url))
                .field("message", message)
                .finish(),
            RealtimeError::WebSocket(error) => f.debug_tuple("WebSocket").field(error).finish(),
            RealtimeError::InvalidHeaderValue { field } => f
                .debug_struct("InvalidHeaderValue")
                .field("field", field)
                .finish(),
            RealtimeError::Protocol(error) => f.debug_tuple("Protocol").field(error).finish(),
            RealtimeError::MissingResult => f.debug_struct("MissingResult").finish(),
            RealtimeError::UnexpectedResult {
                method,
                expected,
                actual,
            } => f
                .debug_struct("UnexpectedResult")
                .field("method", method)
                .field("expected", expected)
                .field("actual", actual)
                .finish(),
            RealtimeError::Timeout { operation, timeout } => f
                .debug_struct("Timeout")
                .field("operation", operation)
                .field("timeout", timeout)
                .finish(),
            RealtimeError::CommitOutcomeUnknown => f.debug_struct("CommitOutcomeUnknown").finish(),
            RealtimeError::ConnectionError {
                reason,
                reason_name,
                friendly,
            } => f
                .debug_struct("ConnectionError")
                .field("reason", reason)
                .field("reason_name", reason_name)
                .field("friendly", friendly)
                .finish(),
            RealtimeError::ConnectionClosed => f.debug_struct("ConnectionClosed").finish(),
            RealtimeError::AuthenticationInvalidated => {
                f.debug_struct("AuthenticationInvalidated").finish()
            }
            RealtimeError::InlineProtocol { message } => f
                .debug_struct("InlineProtocol")
                .field("message", message)
                .finish(),
            RealtimeError::EventLagged { skipped } => f
                .debug_struct("EventLagged")
                .field("skipped", skipped)
                .finish(),
            RealtimeError::RpcError {
                code,
                error_code,
                error_name,
                message,
                friendly,
            } => f
                .debug_struct("RpcError")
                .field("code", code)
                .field("error_code", error_code)
                .field("error_name", error_name)
                .field("message", message)
                .field("friendly", friendly)
                .finish(),
        }
    }
}

impl From<tokio_tungstenite::tungstenite::Error> for RealtimeError {
    fn from(error: tokio_tungstenite::tungstenite::Error) -> Self {
        Self::WebSocket(Box::new(error))
    }
}

/// Stateful realtime connection for issuing Inline RPC calls.
pub struct RealtimeClient {
    ws: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    seq: u32,
    id_gen: IdGenerator,
    rpc_timeout: Option<Duration>,
    heartbeat_interval: Option<Duration>,
    heartbeat_timeout: Duration,
    max_in_flight_rpcs: usize,
}

/// Server-pushed realtime event received outside a direct RPC result.
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
pub enum RealtimeEvent {
    /// The server explicitly revoked the authenticated account session.
    AuthenticationInvalidated,
    /// Inline protocol updates pushed by the server.
    Updates(Vec<proto::Update>),
    /// Transient Grid state or connection event pushed by the server.
    Grid(proto::GridEvent),
    /// Ephemeral bot-owned interaction delivered outside sequenced buckets.
    Bot(proto::BotEvent),
    /// Server acknowledgement for a previously sent client message.
    Ack {
        /// Client message ID acknowledged by the server.
        msg_id: u64,
    },
    /// Server pong response.
    Pong {
        /// Pong nonce.
        nonce: u64,
    },
}

/// Cloneable realtime session that multiplexes concurrent RPCs and pushed
/// events over one WebSocket connection.
///
/// Create an event receiver with [`RealtimeSession::subscribe`] before issuing
/// RPCs that may cause the server to push update hints.
#[derive(Clone)]
pub struct RealtimeSession {
    commands: mpsc::Sender<SessionCommand>,
    events: broadcast::Sender<RealtimeEvent>,
    initial_events: Arc<Mutex<Option<broadcast::Receiver<RealtimeEvent>>>>,
    closed: watch::Receiver<bool>,
    rpc_timeout: Option<Duration>,
    heartbeat_interval: Option<Duration>,
    heartbeat_timeout: Duration,
    rpc_permits: Arc<Semaphore>,
}

impl fmt::Debug for RealtimeSession {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RealtimeSession")
            .field("rpc_timeout", &self.rpc_timeout)
            .field("heartbeat_interval", &self.heartbeat_interval)
            .field("heartbeat_timeout", &self.heartbeat_timeout)
            .field(
                "available_rpc_permits",
                &self.rpc_permits.available_permits(),
            )
            .field("closed", &*self.closed.borrow())
            .finish_non_exhaustive()
    }
}

/// Receiver for pushed events from a multiplexed [`RealtimeSession`].
pub struct RealtimeEventReceiver {
    events: broadcast::Receiver<RealtimeEvent>,
    closed: watch::Receiver<bool>,
}

impl fmt::Debug for RealtimeEventReceiver {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RealtimeEventReceiver")
            .field("closed", &*self.closed.borrow())
            .finish_non_exhaustive()
    }
}

pub(crate) enum SessionCommand {
    Invoke {
        method: proto::Method,
        input: proto::rpc_call::Input,
        admission: Arc<AtomicU8>,
        attempted: Arc<AtomicBool>,
        response: oneshot::Sender<Result<proto::rpc_result::Result, RealtimeError>>,
    },
}

struct SessionCommandCancellationGuard {
    admission: Arc<AtomicU8>,
}

impl Drop for SessionCommandCancellationGuard {
    fn drop(&mut self) {
        let _ = self.admission.compare_exchange(
            SESSION_COMMAND_QUEUED,
            SESSION_COMMAND_CANCELLED,
            Ordering::AcqRel,
            Ordering::Acquire,
        );
    }
}

pub(crate) fn admit_session_command(admission: &AtomicU8) -> bool {
    admission
        .compare_exchange(
            SESSION_COMMAND_QUEUED,
            SESSION_COMMAND_ADMITTED,
            Ordering::AcqRel,
            Ordering::Acquire,
        )
        .is_ok()
}

/// Builder for [`RealtimeClient`].
#[must_use]
#[derive(Clone)]
pub struct RealtimeClientBuilder {
    url: String,
    token: String,
    identity: ClientIdentity,
    connect_timeout: Option<Duration>,
    rpc_timeout: Option<Duration>,
    heartbeat_interval: Option<Duration>,
    heartbeat_timeout: Duration,
    max_in_flight_rpcs: usize,
}

impl fmt::Debug for RealtimeClientBuilder {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RealtimeClientBuilder")
            .field("url", &realtime_url_for_debug(&self.url))
            .field("token", &"<redacted>")
            .field("identity", &self.identity)
            .field("connect_timeout", &self.connect_timeout)
            .field("rpc_timeout", &self.rpc_timeout)
            .field("heartbeat_interval", &self.heartbeat_interval)
            .field("heartbeat_timeout", &self.heartbeat_timeout)
            .field("max_in_flight_rpcs", &self.max_in_flight_rpcs)
            .finish()
    }
}

/// Typed Inline realtime RPC request.
///
/// This trait is implemented for generated protocol input types so callers can
/// use [`RealtimeClient::call`] without manually pairing each input with its
/// [`proto::Method`] and result oneof.
pub trait RpcRequest: Sized {
    /// Typed response returned by this request.
    type Response;

    /// RPC method associated with this input type.
    const METHOD: proto::Method;

    /// Converts this request into the generated RPC input oneof.
    fn into_rpc_input(self) -> proto::rpc_call::Input;

    /// Extracts the typed response from the generated RPC result oneof.
    fn response_from_rpc_result(
        result: proto::rpc_result::Result,
    ) -> Result<Self::Response, RealtimeError>;
}

pub(crate) fn rpc_method_is_read_only(method: proto::Method) -> bool {
    matches!(
        method,
        proto::Method::GetMe
            | proto::Method::GetPeerPhoto
            | proto::Method::GetChatHistory
            | proto::Method::GetSpaceMembers
            | proto::Method::GetChatParticipants
            | proto::Method::GetChats
            | proto::Method::GetUserSettings
            | proto::Method::GetUpdatesState
            | proto::Method::GetChat
            | proto::Method::GetUpdates
            | proto::Method::SearchMessages
            | proto::Method::ListBots
            | proto::Method::RevealBotToken
            | proto::Method::GetMessages
            | proto::Method::GetBotCommands
            | proto::Method::GetPeerBotCommands
            | proto::Method::GetBotPresence
            | proto::Method::GetSessions
            | proto::Method::CheckUsername
            | proto::Method::GetSpaceUrlPreviewExclusions
            | proto::Method::GetUserGroups
            | proto::Method::GetSpaceSettings
            | proto::Method::GetSpace
            | proto::Method::GetThreadReferences
            | proto::Method::GetThreadSubthreads
            | proto::Method::GetPeerBots
            | proto::Method::GetMyBotCapabilities
            | proto::Method::GetGrid
            | proto::Method::GetGridHome
            | proto::Method::GetExternalProfilePhoto
            | proto::Method::GetChatTranscript
            | proto::Method::SearchExternalResources
            | proto::Method::ListConnectors
            | proto::Method::SearchUsers
            | proto::Method::ResolveUrlPreview
            | proto::Method::GetBotAgent
            | proto::Method::ListBotAgents
            | proto::Method::GetConnectorConfig
            | proto::Method::GetUploadState
    )
}

impl RealtimeClient {
    /// Starts a realtime client builder.
    pub fn builder(url: impl Into<String>, token: impl Into<String>) -> RealtimeClientBuilder {
        RealtimeClientBuilder::new(url, token)
    }

    /// Connects to realtime using the default SDK identity.
    pub async fn connect(url: &str, token: &str) -> Result<Self, RealtimeError> {
        Self::builder(url, token).connect().await
    }

    /// Connects to realtime using a caller-provided client identity.
    pub async fn connect_with_identity(
        url: &str,
        token: &str,
        identity: ClientIdentity,
    ) -> Result<Self, RealtimeError> {
        Self::builder(url, token).identity(identity).connect().await
    }
}

impl RealtimeSession {
    /// Connects a multiplexed realtime session using the default SDK identity.
    pub async fn connect(url: &str, token: &str) -> Result<Self, RealtimeError> {
        RealtimeClient::builder(url, token).connect_session().await
    }

    /// Connects a multiplexed realtime session with an explicit client identity.
    pub async fn connect_with_identity(
        url: &str,
        token: &str,
        identity: ClientIdentity,
    ) -> Result<Self, RealtimeError> {
        RealtimeClient::builder(url, token)
            .identity(identity)
            .connect_session()
            .await
    }

    /// Subscribes to server-pushed events routed by this session.
    pub fn subscribe(&self) -> RealtimeEventReceiver {
        let events = self
            .initial_events
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take()
            .unwrap_or_else(|| self.events.subscribe());
        RealtimeEventReceiver {
            events,
            closed: self.closed.clone(),
        }
    }

    /// Returns whether the session transport task has stopped.
    pub fn is_closed(&self) -> bool {
        *self.closed.borrow()
    }

    /// Invokes a typed Inline RPC while the same transport continues routing
    /// pushed events to subscribers.
    pub async fn call<R>(&self, request: R) -> Result<R::Response, RealtimeError>
    where
        R: RpcRequest,
    {
        let result = self.invoke(R::METHOD, request.into_rpc_input()).await?;
        R::response_from_rpc_result(result)
    }

    /// Invokes an Inline RPC while the same transport continues routing pushed
    /// events and other concurrent RPC results.
    pub async fn invoke(
        &self,
        method: proto::Method,
        input: proto::rpc_call::Input,
    ) -> Result<proto::rpc_result::Result, RealtimeError> {
        if self.is_closed() {
            return Err(RealtimeError::ConnectionClosed);
        }
        let (response_tx, response_rx) = oneshot::channel();
        let admission = Arc::new(AtomicU8::new(SESSION_COMMAND_QUEUED));
        let admission_by_actor = admission.clone();
        let admission_by_caller = admission.clone();
        let attempted = Arc::new(AtomicBool::new(false));
        let attempted_by_actor = attempted.clone();
        let commands = self.commands.clone();
        let permits = self.rpc_permits.clone();
        let response = async move {
            let _cancellation_guard = SessionCommandCancellationGuard {
                admission: admission_by_caller,
            };
            let _permit = permits
                .acquire_owned()
                .await
                .map_err(|_| RealtimeError::ConnectionClosed)?;
            commands
                .send(SessionCommand::Invoke {
                    method,
                    input,
                    admission: admission_by_actor,
                    attempted: attempted_by_actor,
                    response: response_tx,
                })
                .await
                .map_err(|_| RealtimeError::ConnectionClosed)?;
            response_rx
                .await
                .map_err(|_| RealtimeError::ConnectionClosed)?
        };
        let read_only = rpc_method_is_read_only(method);
        match with_optional_timeout("rpc", self.rpc_timeout, response).await {
            Err(RealtimeError::Timeout { .. } | RealtimeError::ConnectionClosed)
                if (admission.load(Ordering::Acquire) == SESSION_COMMAND_ADMITTED
                    || attempted.load(Ordering::Acquire))
                    && !read_only =>
            {
                Err(RealtimeError::CommitOutcomeUnknown)
            }
            Err(RealtimeError::CommitOutcomeUnknown) if read_only => Err(RealtimeError::Timeout {
                operation: "rpc",
                timeout: self.rpc_timeout.unwrap_or(DEFAULT_RPC_TIMEOUT),
            }),
            result => result,
        }
    }

    fn from_client(client: RealtimeClient) -> Self {
        let rpc_timeout = client.rpc_timeout;
        let heartbeat_interval = client.heartbeat_interval;
        let heartbeat_timeout = client.heartbeat_timeout;
        let max_in_flight_rpcs = client.max_in_flight_rpcs;
        let (command_tx, command_rx) = mpsc::channel(DEFAULT_SESSION_COMMAND_CAPACITY);
        let (event_tx, initial_event_rx) = broadcast::channel(DEFAULT_SESSION_EVENT_CAPACITY);
        let (closed_tx, closed_rx) = watch::channel(false);
        tokio::spawn(run_realtime_session(
            client,
            command_rx,
            event_tx.clone(),
            closed_tx,
        ));
        Self {
            commands: command_tx,
            events: event_tx,
            initial_events: Arc::new(Mutex::new(Some(initial_event_rx))),
            closed: closed_rx,
            rpc_timeout,
            heartbeat_interval,
            heartbeat_timeout,
            rpc_permits: Arc::new(Semaphore::new(max_in_flight_rpcs)),
        }
    }

    pub(crate) fn from_inline_protocol_v3(
        client: crate::realtime_v3::InlineProtocolV3Connection,
    ) -> Self {
        let (command_tx, command_rx) = mpsc::channel(DEFAULT_SESSION_COMMAND_CAPACITY);
        let (event_tx, initial_event_rx) = broadcast::channel(DEFAULT_SESSION_EVENT_CAPACITY);
        let (closed_tx, closed_rx) = watch::channel(false);
        tokio::spawn(crate::realtime_v3::run_inline_protocol_v3_session(
            client,
            command_rx,
            event_tx.clone(),
            closed_tx,
        ));
        Self {
            commands: command_tx,
            events: event_tx,
            initial_events: Arc::new(Mutex::new(Some(initial_event_rx))),
            closed: closed_rx,
            rpc_timeout: Some(DEFAULT_RPC_TIMEOUT),
            heartbeat_interval: Some(DEFAULT_HEARTBEAT_INTERVAL),
            heartbeat_timeout: DEFAULT_HEARTBEAT_TIMEOUT,
            rpc_permits: Arc::new(Semaphore::new(DEFAULT_SESSION_MAX_IN_FLIGHT_RPCS)),
        }
    }
}

impl RealtimeEventReceiver {
    /// Returns the number of pushed events queued at this receiver now.
    ///
    /// Callers that need a bounded wire-order drain should snapshot this
    /// before calling [`Self::try_recv`], so arrivals during the drain are
    /// left for the normal receiver path.
    pub fn len(&self) -> usize {
        self.events.len()
    }

    /// Returns whether this receiver has no pushed events queued now.
    pub fn is_empty(&self) -> bool {
        self.events.is_empty()
    }

    /// Returns one already-queued pushed event without waiting for a future
    /// event. This is used by callers that need a bounded wire-order drain at
    /// an RPC response boundary.
    pub fn try_recv(&mut self) -> Result<Option<RealtimeEvent>, RealtimeError> {
        match self.events.try_recv() {
            Ok(event) => Ok(Some(event)),
            Err(broadcast::error::TryRecvError::Empty) => Ok(None),
            Err(broadcast::error::TryRecvError::Lagged(skipped)) => {
                Err(RealtimeError::EventLagged { skipped })
            }
            Err(broadcast::error::TryRecvError::Closed) => Err(RealtimeError::ConnectionClosed),
        }
    }

    /// Waits for the next pushed event or a terminal session failure.
    pub async fn recv(&mut self) -> Result<RealtimeEvent, RealtimeError> {
        loop {
            if *self.closed.borrow() && self.events.is_empty() {
                return Err(RealtimeError::ConnectionClosed);
            }

            tokio::select! {
                result = self.events.recv() => return match result {
                    Ok(event) => Ok(event),
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        Err(RealtimeError::EventLagged { skipped })
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        Err(RealtimeError::ConnectionClosed)
                    }
                },
                changed = self.closed.changed() => {
                    match changed {
                        Ok(()) => continue,
                        Err(_) => {
                            // The transport publishes terminal events before dropping
                            // its watch sender. Drain them even if shutdown wins select.
                            return self.try_recv()?.ok_or(RealtimeError::ConnectionClosed);
                        }
                    }
                }
            }
        }
    }
}

impl RealtimeClientBuilder {
    /// Creates a realtime client builder with the default SDK identity.
    pub fn new(url: impl Into<String>, token: impl Into<String>) -> Self {
        Self {
            url: url.into(),
            token: token.into(),
            identity: ClientIdentity::sdk(),
            connect_timeout: Some(DEFAULT_CONNECT_TIMEOUT),
            rpc_timeout: Some(DEFAULT_RPC_TIMEOUT),
            heartbeat_interval: Some(DEFAULT_HEARTBEAT_INTERVAL),
            heartbeat_timeout: DEFAULT_HEARTBEAT_TIMEOUT,
            max_in_flight_rpcs: DEFAULT_SESSION_MAX_IN_FLIGHT_RPCS,
        }
    }

    /// Sets the client identity used in realtime headers and connection init.
    pub fn identity(mut self, identity: ClientIdentity) -> Self {
        self.identity = identity;
        self
    }

    /// Sets the timeout for opening the WebSocket and receiving `ConnectionOpen`.
    pub fn connect_timeout(mut self, timeout: Duration) -> Self {
        self.connect_timeout = Some(timeout);
        self
    }

    /// Disables the connect timeout.
    pub fn without_connect_timeout(mut self) -> Self {
        self.connect_timeout = None;
        self
    }

    /// Sets the timeout for each RPC invocation.
    pub fn rpc_timeout(mut self, timeout: Duration) -> Self {
        self.rpc_timeout = Some(timeout);
        self
    }

    /// Disables the per-RPC timeout.
    pub fn without_rpc_timeout(mut self) -> Self {
        self.rpc_timeout = None;
        self
    }

    /// Sets the maximum number of RPCs awaiting responses on one session.
    pub fn max_in_flight_rpcs(mut self, maximum: usize) -> Self {
        self.max_in_flight_rpcs = maximum.max(1);
        self
    }

    /// Configures protocol heartbeat interval and pong deadline.
    pub fn heartbeat(mut self, interval: Duration, timeout: Duration) -> Self {
        self.heartbeat_interval = Some(interval.max(Duration::from_millis(1)));
        self.heartbeat_timeout = timeout.max(Duration::from_millis(1));
        self
    }

    /// Disables multiplexed-session protocol heartbeat pings.
    pub fn without_heartbeat(mut self) -> Self {
        self.heartbeat_interval = None;
        self
    }

    /// Opens the WebSocket connection and waits for `ConnectionOpen`.
    pub async fn connect(self) -> Result<RealtimeClient, RealtimeError> {
        let url = normalize_realtime_url(self.url)?;
        log::debug!(
            target: "inline_sdk::realtime",
            "opening realtime websocket url={} identity_type={} connect_timeout={:?} rpc_timeout={:?}",
            realtime_url_for_log(&url),
            self.identity.client_type(),
            self.connect_timeout,
            self.rpc_timeout
        );
        let mut request = url.as_str().into_client_request()?;
        request.headers_mut().insert(
            client_info::CLIENT_TYPE_HEADER,
            realtime_header_value("client_type", self.identity.client_type())?,
        );
        request.headers_mut().insert(
            client_info::CLIENT_VERSION_HEADER,
            realtime_header_value("client_version", self.identity.client_version())?,
        );
        request.headers_mut().insert(
            "user-agent",
            realtime_header_value("user_agent", &client_info::user_agent_for(&self.identity))?,
        );

        let (ws, _) =
            with_optional_timeout("connect", self.connect_timeout, connect_async(request)).await?;
        log::debug!(target: "inline_sdk::realtime", "websocket connected");
        let mut client = RealtimeClient {
            ws,
            seq: 0,
            id_gen: IdGenerator::new(),
            rpc_timeout: self.rpc_timeout,
            heartbeat_interval: self.heartbeat_interval,
            heartbeat_timeout: self.heartbeat_timeout,
            max_in_flight_rpcs: self.max_in_flight_rpcs,
        };

        with_optional_timeout(
            "connection_init",
            self.connect_timeout,
            client.send_connection_init(&self.token, &self.identity),
        )
        .await?;
        log::trace!(target: "inline_sdk::realtime", "connection init sent");
        with_optional_timeout(
            "connection_open",
            self.connect_timeout,
            client.wait_for_connection_open(),
        )
        .await?;
        log::debug!(target: "inline_sdk::realtime", "realtime protocol open");
        Ok(client)
    }

    /// Opens one WebSocket and starts a multiplexed session for concurrent RPC
    /// calls and pushed events.
    pub async fn connect_session(self) -> Result<RealtimeSession, RealtimeError> {
        self.connect().await.map(RealtimeSession::from_client)
    }
}

impl RealtimeClient {
    /// Converts this authenticated connection into a multiplexed session,
    /// preserving its socket, request IDs, and timeout policy.
    pub fn into_session(self) -> RealtimeSession {
        RealtimeSession::from_client(self)
    }

    /// Invokes a typed Inline RPC request.
    pub async fn call<R>(&mut self, request: R) -> Result<R::Response, RealtimeError>
    where
        R: RpcRequest,
    {
        log::trace!(
            target: "inline_sdk::realtime",
            "calling typed rpc method={}",
            R::METHOD.as_str_name()
        );
        let result = self.invoke(R::METHOD, request.into_rpc_input()).await?;
        R::response_from_rpc_result(result)
    }

    /// Invokes an Inline RPC method and waits for the matching result.
    pub async fn invoke(
        &mut self,
        method: proto::Method,
        input: proto::rpc_call::Input,
    ) -> Result<proto::rpc_result::Result, RealtimeError> {
        let message_id = self.send_rpc_call(method, input).await?;

        with_optional_timeout(
            "rpc",
            self.rpc_timeout,
            self.wait_for_rpc_result(message_id),
        )
        .await
    }

    async fn send_rpc_call(
        &mut self,
        method: proto::Method,
        input: proto::rpc_call::Input,
    ) -> Result<u64, RealtimeError> {
        let message_id = self.next_id();
        log::trace!(
            target: "inline_sdk::realtime",
            "sending rpc method={} msg_id={message_id}",
            method.as_str_name()
        );
        let message = proto::ClientMessage {
            id: message_id,
            seq: self.next_seq(),
            body: Some(proto::client_message::Body::RpcCall(proto::RpcCall {
                method: method as i32,
                input: Some(input),
            })),
        };
        self.send_client_message(message).await?;
        Ok(message_id)
    }

    /// Returns the configured per-RPC timeout.
    pub fn rpc_timeout(&self) -> Option<Duration> {
        self.rpc_timeout
    }

    /// Waits for the next server-pushed realtime event.
    ///
    /// This reads the same Inline realtime protocol stream used for RPC calls.
    /// Callers that need both request/response RPCs and long-lived pushed
    /// updates should either serialize access to one [`RealtimeClient`] or use
    /// a separate realtime connection for the event receiver.
    pub async fn next_event(&mut self) -> Result<RealtimeEvent, RealtimeError> {
        loop {
            let message = self.read_server_message().await?;
            if let Some(event) = self.event_from_server_message(message).await? {
                return Ok(event);
            }
        }
    }

    async fn send_connection_init(
        &mut self,
        token: &str,
        identity: &ClientIdentity,
    ) -> Result<(), RealtimeError> {
        let init = connection_init_for_token(token, identity);
        let message = proto::ClientMessage {
            id: self.next_id(),
            seq: self.next_seq(),
            body: Some(proto::client_message::Body::ConnectionInit(init)),
        };

        self.send_client_message(message).await
    }

    async fn wait_for_connection_open(&mut self) -> Result<(), RealtimeError> {
        loop {
            let message = self.read_server_message().await?;
            let message_id = message.id;
            match message.body {
                Some(proto::server_protocol_message::Body::ConnectionOpen(_)) => return Ok(()),
                Some(proto::server_protocol_message::Body::ConnectionError(error)) => {
                    log::warn!(
                        target: "inline_sdk::realtime",
                        "connection open rejected reason={}",
                        proto::connection_error::Reason::try_from(error.reason)
                            .map(|reason| reason.as_str_name())
                            .unwrap_or("UNKNOWN")
                    );
                    return Err(connection_error_from_proto(error));
                }
                Some(proto::server_protocol_message::Body::Message(message)) => {
                    let _ = self.server_payload_event(message_id, message).await?;
                }
                _ => {}
            }
        }
    }

    async fn wait_for_rpc_result(
        &mut self,
        message_id: u64,
    ) -> Result<proto::rpc_result::Result, RealtimeError> {
        loop {
            let message = self.read_server_message().await?;
            match message.body {
                Some(proto::server_protocol_message::Body::RpcResult(result))
                    if result.req_msg_id == message_id =>
                {
                    log::trace!(
                        target: "inline_sdk::realtime",
                        "received rpc result msg_id={message_id}"
                    );
                    return result.result.ok_or(RealtimeError::MissingResult);
                }
                Some(proto::server_protocol_message::Body::RpcError(error))
                    if error.req_msg_id == message_id =>
                {
                    log::warn!(
                        target: "inline_sdk::realtime",
                        "received rpc error msg_id={message_id} error={} status={}",
                        rpc_error_code_name(error.error_code),
                        error.code,
                    );
                    return Err(rpc_error_from_proto(error));
                }
                Some(proto::server_protocol_message::Body::ConnectionError(error)) => {
                    log::warn!(
                        target: "inline_sdk::realtime",
                        "connection error while waiting for rpc msg_id={message_id} reason={}",
                        proto::connection_error::Reason::try_from(error.reason)
                            .map(|reason| reason.as_str_name())
                            .unwrap_or("UNKNOWN")
                    );
                    return Err(connection_error_from_proto(error));
                }
                Some(proto::server_protocol_message::Body::Message(server_message)) => {
                    if let Some(event) = self
                        .server_payload_event(message.id, server_message)
                        .await?
                    {
                        log::trace!(
                            target: "inline_sdk::realtime",
                            "received pushed realtime event while waiting for rpc msg_id={message_id}: {}",
                            realtime_event_kind(&event)
                        );
                    }
                }
                _ => {}
            }
        }
    }

    async fn event_from_server_message(
        &mut self,
        message: proto::ServerProtocolMessage,
    ) -> Result<Option<RealtimeEvent>, RealtimeError> {
        match message.body {
            Some(proto::server_protocol_message::Body::Message(server_message)) => {
                self.server_payload_event(message.id, server_message).await
            }
            Some(proto::server_protocol_message::Body::Ack(ack)) => {
                Ok(Some(RealtimeEvent::Ack { msg_id: ack.msg_id }))
            }
            Some(proto::server_protocol_message::Body::Pong(pong)) => {
                Ok(Some(RealtimeEvent::Pong { nonce: pong.nonce }))
            }
            Some(proto::server_protocol_message::Body::ConnectionError(error)) => {
                Err(connection_error_from_proto(error))
            }
            Some(proto::server_protocol_message::Body::ConnectionOpen(_))
            | Some(proto::server_protocol_message::Body::RpcResult(_))
            | Some(proto::server_protocol_message::Body::RpcError(_))
            | None => Ok(None),
        }
    }

    async fn server_payload_event(
        &mut self,
        message_id: u64,
        message: proto::ServerMessage,
    ) -> Result<Option<RealtimeEvent>, RealtimeError> {
        match message.payload {
            Some(proto::server_message::Payload::Update(payload)) => {
                self.send_ack(message_id).await?;
                Ok(Some(RealtimeEvent::Updates(payload.updates)))
            }
            Some(proto::server_message::Payload::Grid(event)) => {
                self.send_ack(message_id).await?;
                Ok(Some(RealtimeEvent::Grid(event)))
            }
            Some(proto::server_message::Payload::Bot(event)) => {
                self.send_ack(message_id).await?;
                Ok(Some(RealtimeEvent::Bot(event)))
            }
            None => Ok(None),
        }
    }

    async fn send_ack(&mut self, msg_id: u64) -> Result<(), RealtimeError> {
        let message = proto::ClientMessage {
            id: self.next_id(),
            seq: self.next_seq(),
            body: Some(proto::client_message::Body::Ack(proto::Ack { msg_id })),
        };
        self.send_client_message(message).await
    }

    async fn send_ping(&mut self, nonce: u64) -> Result<(), RealtimeError> {
        let message = proto::ClientMessage {
            id: self.next_id(),
            seq: self.next_seq(),
            body: Some(proto::client_message::Body::Ping(proto::Ping { nonce })),
        };
        self.send_client_message(message).await
    }

    async fn send_client_message(
        &mut self,
        message: proto::ClientMessage,
    ) -> Result<(), RealtimeError> {
        let bytes = message.encode_to_vec();
        self.ws.send(WsMessage::Binary(bytes.into())).await?;
        Ok(())
    }

    async fn read_server_message(&mut self) -> Result<proto::ServerProtocolMessage, RealtimeError> {
        loop {
            let message = self
                .ws
                .next()
                .await
                .ok_or(RealtimeError::ConnectionClosed)??;
            match message {
                WsMessage::Binary(data) => {
                    return Ok(proto::ServerProtocolMessage::decode(&*data)?);
                }
                WsMessage::Text(_) => continue,
                WsMessage::Close(_) => return Err(RealtimeError::ConnectionClosed),
                WsMessage::Ping(_) | WsMessage::Pong(_) => continue,
                _ => continue,
            }
        }
    }

    fn next_seq(&mut self) -> u32 {
        self.seq = self.seq.wrapping_add(1);
        self.seq
    }

    fn next_id(&mut self) -> u64 {
        self.id_gen.next_id()
    }
}

async fn run_realtime_session(
    mut client: RealtimeClient,
    mut commands: mpsc::Receiver<SessionCommand>,
    events: broadcast::Sender<RealtimeEvent>,
    closed: watch::Sender<bool>,
) {
    let heartbeat_interval = client.heartbeat_interval;
    let heartbeat_timeout = client.heartbeat_timeout;
    let mut heartbeat =
        tokio::time::interval(heartbeat_interval.unwrap_or(Duration::from_secs(24 * 60 * 60)));
    heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    heartbeat.tick().await;
    let mut pending_ping: Option<(u64, tokio::time::Instant)> = None;
    let mut authentication_invalidated = false;
    let mut pending =
        HashMap::<u64, oneshot::Sender<Result<proto::rpc_result::Result, RealtimeError>>>::new();

    loop {
        // A timed-out or cancelled caller drops its receiver. Remove those
        // entries before accepting more work so an unresponsive server cannot
        // grow the pending map indefinitely.
        pending.retain(|_, response| !response.is_closed());
        let heartbeat_deadline = pending_ping
            .map(|(_, deadline)| deadline)
            .unwrap_or_else(tokio::time::Instant::now);
        tokio::select! {
            _ = heartbeat.tick(), if heartbeat_interval.is_some() => {
                if pending_ping.is_none() {
                    let nonce = client.next_id();
                    if let Err(error) = client.send_ping(nonce).await {
                        log::warn!(
                            target: "inline_sdk::realtime",
                            "failed to send realtime heartbeat: {error}"
                        );
                        break;
                    }
                    pending_ping = Some((nonce, tokio::time::Instant::now() + heartbeat_timeout));
                }
            }
            _ = tokio::time::sleep_until(heartbeat_deadline), if pending_ping.is_some() => {
                let nonce = pending_ping.map(|(nonce, _)| nonce).unwrap_or_default();
                log::warn!(
                    target: "inline_sdk::realtime",
                    "realtime heartbeat timed out nonce={nonce} timeout={heartbeat_timeout:?}"
                );
                break;
            }
            command = commands.recv() => {
                let Some(command) = command else {
                    break;
                };
                match command {
                    SessionCommand::Invoke { method, input, admission, attempted, response } => {
                        if !admit_session_command(&admission) {
                            continue;
                        }
                        match client.send_rpc_call(method, input).await {
                            Ok(message_id) => {
                                attempted.store(true, Ordering::Release);
                                pending.insert(message_id, response);
                            }
                            Err(error) => {
                                let _ = response.send(Err(error));
                                break;
                            }
                        }
                    }
                }
            }
            message = client.read_server_message() => {
                let message = match message {
                    Ok(message) => message,
                    Err(error) => {
                        log::warn!(
                            target: "inline_sdk::realtime",
                            "multiplexed realtime session stopped: {error}"
                        );
                        break;
                    }
                };
                match message.body {
                    Some(proto::server_protocol_message::Body::RpcResult(result)) => {
                        if let Some(response) = pending.remove(&result.req_msg_id) {
                            let value = result.result.ok_or(RealtimeError::MissingResult);
                            let _ = response.send(value);
                        } else {
                            log::debug!(
                                target: "inline_sdk::realtime",
                                "received result for unknown or timed-out rpc msg_id={}",
                                result.req_msg_id
                            );
                        }
                    }
                    Some(proto::server_protocol_message::Body::RpcError(error)) => {
                        if let Some(response) = pending.remove(&error.req_msg_id) {
                            let _ = response.send(Err(rpc_error_from_proto(error)));
                        } else {
                            log::debug!(
                                target: "inline_sdk::realtime",
                                "received error for unknown or timed-out rpc msg_id={}",
                                error.req_msg_id
                            );
                        }
                    }
                    Some(proto::server_protocol_message::Body::Message(server_message)) => {
                        match client.server_payload_event(message.id, server_message).await {
                            Ok(Some(event)) => {
                                let _ = events.send(event);
                            }
                            Ok(None) => {}
                            Err(error) => {
                                log::warn!(
                                    target: "inline_sdk::realtime",
                                    "failed to route pushed realtime event: {error}"
                                );
                                break;
                            }
                        }
                    }
                    Some(proto::server_protocol_message::Body::Ack(ack)) => {
                        let _ = events.send(RealtimeEvent::Ack { msg_id: ack.msg_id });
                    }
                    Some(proto::server_protocol_message::Body::Pong(pong)) => {
                        if pending_ping.is_some_and(|(nonce, _)| nonce == pong.nonce) {
                            pending_ping = None;
                        }
                        let _ = events.send(RealtimeEvent::Pong { nonce: pong.nonce });
                    }
                    Some(proto::server_protocol_message::Body::ConnectionError(error)) => {
                        let error = connection_error_from_proto(error);
                        if matches!(error, RealtimeError::AuthenticationInvalidated) {
                            authentication_invalidated = true;
                            let _ = events.send(RealtimeEvent::AuthenticationInvalidated);
                        }
                        log::warn!(
                            target: "inline_sdk::realtime",
                            "multiplexed realtime session rejected: {error}"
                        );
                        break;
                    }
                    Some(proto::server_protocol_message::Body::ConnectionOpen(_)) | None => {}
                }
            }
        }
    }

    for (_, response) in pending {
        let error = if authentication_invalidated {
            RealtimeError::AuthenticationInvalidated
        } else {
            RealtimeError::ConnectionClosed
        };
        let _ = response.send(Err(error));
    }
    let _ = closed.send(true);
}

macro_rules! rpc_requests {
    ($(($input_ty:ident, $method:ident, $input_variant:ident, $result_ty:ident, $result_variant:ident)),+ $(,)?) => {
        $(
            impl RpcRequest for proto::$input_ty {
                type Response = proto::$result_ty;

                const METHOD: proto::Method = proto::Method::$method;

                fn into_rpc_input(self) -> proto::rpc_call::Input {
                    proto::rpc_call::Input::$input_variant(self)
                }

                fn response_from_rpc_result(
                    result: proto::rpc_result::Result,
                ) -> Result<Self::Response, RealtimeError> {
                    match result {
                        proto::rpc_result::Result::$result_variant(response) => Ok(response),
                        other => {
                            let actual = rpc_result_variant_name(&other);
                            log::warn!(
                                target: "inline_sdk::realtime",
                                "unexpected rpc result method={} expected={} actual={actual}",
                                Self::METHOD.as_str_name(),
                                stringify!($result_variant)
                            );
                            Err(RealtimeError::UnexpectedResult {
                                method: Self::METHOD.as_str_name(),
                                expected: stringify!($result_variant),
                                actual,
                            })
                        }
                    }
                }
            }
        )+

        fn rpc_result_variant_name(result: &proto::rpc_result::Result) -> &'static str {
            match result {
                $(proto::rpc_result::Result::$result_variant(_) => stringify!($result_variant),)+
                _ => "unknown",
            }
        }

        pub(crate) fn validate_rpc_result_for_method(
            method: proto::Method,
            result: &proto::rpc_result::Result,
        ) -> Result<(), RealtimeError> {
            match (method, result) {
                $((proto::Method::$method, proto::rpc_result::Result::$result_variant(_)) => Ok(()),)+
                (method, result) => {
                    let Some(expected) = (match method {
                        $(proto::Method::$method => Some(stringify!($result_variant)),)+
                        _ => None,
                    }) else {
                        // Untyped methods are still available through `invoke`; their
                        // caller owns result-shape validation.
                        return Ok(());
                    };
                    let actual = rpc_result_variant_name(result);
                    log::warn!(
                        target: "inline_sdk::realtime",
                        "unexpected rpc result method={} expected={expected} actual={actual}",
                        method.as_str_name(),
                    );
                    Err(RealtimeError::UnexpectedResult {
                        method: method.as_str_name(),
                        expected,
                        actual,
                    })
                }
            }
        }
    };
}

rpc_requests!(
    (GetMeInput, GetMe, GetMe, GetMeResult, GetMe),
    (
        GetPeerPhotoInput,
        GetPeerPhoto,
        GetPeerPhoto,
        GetPeerPhotoResult,
        GetPeerPhoto
    ),
    (
        DeleteMessagesInput,
        DeleteMessages,
        DeleteMessages,
        DeleteMessagesResult,
        DeleteMessages
    ),
    (
        SendMessageInput,
        SendMessage,
        SendMessage,
        SendMessageResult,
        SendMessage
    ),
    (
        GetChatHistoryInput,
        GetChatHistory,
        GetChatHistory,
        GetChatHistoryResult,
        GetChatHistory
    ),
    (
        AddReactionInput,
        AddReaction,
        AddReaction,
        AddReactionResult,
        AddReaction
    ),
    (
        DeleteReactionInput,
        DeleteReaction,
        DeleteReaction,
        DeleteReactionResult,
        DeleteReaction
    ),
    (
        EditMessageInput,
        EditMessage,
        EditMessage,
        EditMessageResult,
        EditMessage
    ),
    (
        CreateChatInput,
        CreateChat,
        CreateChat,
        CreateChatResult,
        CreateChat
    ),
    (
        GetSpaceMembersInput,
        GetSpaceMembers,
        GetSpaceMembers,
        GetSpaceMembersResult,
        GetSpaceMembers
    ),
    (
        DeleteChatInput,
        DeleteChat,
        DeleteChat,
        DeleteChatResult,
        DeleteChat
    ),
    (
        InviteToSpaceInput,
        InviteToSpace,
        InviteToSpace,
        InviteToSpaceResult,
        InviteToSpace
    ),
    (
        GetChatParticipantsInput,
        GetChatParticipants,
        GetChatParticipants,
        GetChatParticipantsResult,
        GetChatParticipants
    ),
    (
        AddChatParticipantInput,
        AddChatParticipant,
        AddChatParticipant,
        AddChatParticipantResult,
        AddChatParticipant
    ),
    (
        RemoveChatParticipantInput,
        RemoveChatParticipant,
        RemoveChatParticipant,
        RemoveChatParticipantResult,
        RemoveChatParticipant
    ),
    (
        TranslateMessagesInput,
        TranslateMessages,
        TranslateMessages,
        TranslateMessagesResult,
        TranslateMessages
    ),
    (GetChatsInput, GetChats, GetChats, GetChatsResult, GetChats),
    (
        UpdateUserSettingsInput,
        UpdateUserSettings,
        UpdateUserSettings,
        UpdateUserSettingsResult,
        UpdateUserSettings
    ),
    (
        GetUserSettingsInput,
        GetUserSettings,
        GetUserSettings,
        GetUserSettingsResult,
        GetUserSettings
    ),
    (
        SendComposeActionInput,
        SendComposeAction,
        SendComposeAction,
        SendComposeActionResult,
        SendComposeAction
    ),
    (
        CreateBotInput,
        CreateBot,
        CreateBot,
        CreateBotResult,
        CreateBot
    ),
    (
        DeleteMemberInput,
        DeleteMember,
        DeleteMember,
        DeleteMemberResult,
        DeleteMember
    ),
    (
        MarkAsUnreadInput,
        MarkAsUnread,
        MarkAsUnread,
        MarkAsUnreadResult,
        MarkAsUnread
    ),
    (
        GetUpdatesStateInput,
        GetUpdatesState,
        GetUpdatesState,
        GetUpdatesStateResult,
        GetUpdatesState
    ),
    (GetChatInput, GetChat, GetChat, GetChatResult, GetChat),
    (
        GetUpdatesInput,
        GetUpdates,
        GetUpdates,
        GetUpdatesResult,
        GetUpdates
    ),
    (
        UpdateMemberAccessInput,
        UpdateMemberAccess,
        UpdateMemberAccess,
        UpdateMemberAccessResult,
        UpdateMemberAccess
    ),
    (
        SearchMessagesInput,
        SearchMessages,
        SearchMessages,
        SearchMessagesResult,
        SearchMessages
    ),
    (
        ForwardMessagesInput,
        ForwardMessages,
        ForwardMessages,
        ForwardMessagesResult,
        ForwardMessages
    ),
    (
        UpdateChatVisibilityInput,
        UpdateChatVisibility,
        UpdateChatVisibility,
        UpdateChatVisibilityResult,
        UpdateChatVisibility
    ),
    (
        PinMessageInput,
        PinMessage,
        PinMessage,
        PinMessageResult,
        PinMessage
    ),
    (
        UpdateChatInfoInput,
        UpdateChatInfo,
        UpdateChatInfo,
        UpdateChatInfoResult,
        UpdateChatInfo
    ),
    (ListBotsInput, ListBots, ListBots, ListBotsResult, ListBots),
    (
        RevealBotTokenInput,
        RevealBotToken,
        RevealBotToken,
        RevealBotTokenResult,
        RevealBotToken
    ),
    (
        MoveThreadInput,
        MoveThread,
        MoveThread,
        MoveThreadResult,
        MoveThread
    ),
    (
        RotateBotTokenInput,
        RotateBotToken,
        RotateBotToken,
        RotateBotTokenResult,
        RotateBotToken
    ),
    (
        UpdateBotProfileInput,
        UpdateBotProfile,
        UpdateBotProfile,
        UpdateBotProfileResult,
        UpdateBotProfile
    ),
    (
        GetMessagesInput,
        GetMessages,
        GetMessages,
        GetMessagesResult,
        GetMessages
    ),
    (
        UpdateDialogNotificationSettingsInput,
        UpdateDialogNotificationSettings,
        UpdateDialogNotificationSettings,
        UpdateDialogNotificationSettingsResult,
        UpdateDialogNotificationSettings
    ),
    (
        ReadMessagesInput,
        ReadMessages,
        ReadMessages,
        ReadMessagesResult,
        ReadMessages
    ),
    (
        CreateExternalTaskInput,
        CreateExternalTask,
        CreateExternalTask,
        CreateExternalTaskResult,
        CreateExternalTask
    ),
    (LogOutInput, LogOut, LogOut, LogOutResult, LogOut),
    (
        RegisterDeviceInput,
        RegisterDevice,
        RegisterDevice,
        RegisterDeviceResult,
        RegisterDevice
    ),
    (
        CreateSubthreadInput,
        CreateSubthread,
        CreateSubthread,
        CreateSubthreadResult,
        CreateSubthread
    ),
    (
        GetBotCommandsInput,
        GetBotCommands,
        GetBotCommands,
        GetBotCommandsResult,
        GetBotCommands
    ),
    (
        SetBotCommandsInput,
        SetBotCommands,
        SetBotCommands,
        SetBotCommandsResult,
        SetBotCommands
    ),
    (
        GetMyBotCapabilitiesInput,
        GetMyBotCapabilities,
        GetMyBotCapabilities,
        GetMyBotCapabilitiesResult,
        GetMyBotCapabilities
    ),
    (
        SetMyBotCapabilitiesInput,
        SetMyBotCapabilities,
        SetMyBotCapabilities,
        SetMyBotCapabilitiesResult,
        SetMyBotCapabilities
    ),
    (
        RequestBotChatSettingsInput,
        RequestBotChatSettings,
        RequestBotChatSettings,
        RequestBotChatSettingsResult,
        RequestBotChatSettings
    ),
    (
        InvokeBotChatSettingsItemInput,
        InvokeBotChatSettingsItem,
        InvokeBotChatSettingsItem,
        InvokeBotChatSettingsItemResult,
        InvokeBotChatSettingsItem
    ),
    (
        AnswerBotChatSettingsInput,
        AnswerBotChatSettings,
        AnswerBotChatSettings,
        AnswerBotChatSettingsResult,
        AnswerBotChatSettings
    ),
    (
        GetPeerBotCommandsInput,
        GetPeerBotCommands,
        GetPeerBotCommands,
        GetPeerBotCommandsResult,
        GetPeerBotCommands
    ),
    (
        ShowInChatListInput,
        ShowInChatList,
        ShowInChatList,
        ShowInChatListResult,
        ShowInChatList
    ),
    (
        ReserveChatIdsInput,
        ReserveChatIds,
        ReserveChatIds,
        ReserveChatIdsResult,
        ReserveChatIds
    ),
    (
        InvokeMessageActionInput,
        InvokeMessageAction,
        InvokeMessageAction,
        InvokeMessageActionResult,
        InvokeMessageAction
    ),
    (
        AnswerMessageActionInput,
        AnswerMessageAction,
        AnswerMessageAction,
        AnswerMessageActionResult,
        AnswerMessageAction
    ),
    (
        RevokeSessionInput,
        RevokeSession,
        RevokeSession,
        RevokeSessionResult,
        RevokeSession
    ),
    (
        UpdateDialogOpenInput,
        UpdateDialogOpen,
        UpdateDialogOpen,
        UpdateDialogOpenResult,
        UpdateDialogOpen
    ),
    (
        UpdateDialogOrderInput,
        UpdateDialogOrder,
        UpdateDialogOrder,
        UpdateDialogOrderResult,
        UpdateDialogOrder
    ),
    (
        ClearChatHistoryInput,
        ClearChatHistory,
        ClearChatHistory,
        ClearChatHistoryResult,
        ClearChatHistory
    ),
    (
        DeleteBotInput,
        DeleteBot,
        DeleteBot,
        DeleteBotResult,
        DeleteBot
    ),
    (
        DeleteMessageAttachmentInput,
        DeleteMessageAttachment,
        DeleteMessageAttachment,
        DeleteMessageAttachmentResult,
        DeleteMessageAttachment
    ),
    (
        SetBotAvatarInput,
        SetBotAvatar,
        SetBotAvatar,
        SetBotAvatarResult,
        SetBotAvatar
    ),
    (
        ClearBotAvatarInput,
        ClearBotAvatar,
        ClearBotAvatar,
        ClearBotAvatarResult,
        ClearBotAvatar
    ),
    (
        GetBotPresenceInput,
        GetBotPresence,
        GetBotPresence,
        GetBotPresenceResult,
        GetBotPresence
    ),
    (
        SetBotPresenceStateInput,
        SetBotPresenceState,
        SetBotPresenceState,
        SetBotPresenceStateResult,
        SetBotPresenceState
    ),
    (
        UpdateDialogFollowModeInput,
        UpdateDialogFollowMode,
        UpdateDialogFollowMode,
        UpdateDialogFollowModeResult,
        UpdateDialogFollowMode
    ),
    (
        GetSessionsInput,
        GetSessions,
        GetSessions,
        GetSessionsResult,
        GetSessions
    ),
    (
        CheckUsernameInput,
        CheckUsername,
        CheckUsername,
        CheckUsernameResult,
        CheckUsername
    ),
    (
        ChangeUsernameInput,
        ChangeUsername,
        ChangeUsername,
        ChangeUsernameResult,
        ChangeUsername
    ),
    (
        UpdateProfileInput,
        UpdateProfile,
        UpdateProfile,
        UpdateProfileResult,
        UpdateProfile
    ),
    (
        GetSpaceUrlPreviewExclusionsInput,
        GetSpaceUrlPreviewExclusions,
        GetSpaceUrlPreviewExclusions,
        GetSpaceUrlPreviewExclusionsResult,
        GetSpaceUrlPreviewExclusions
    ),
    (
        AddSpaceUrlPreviewExclusionInput,
        AddSpaceUrlPreviewExclusion,
        AddSpaceUrlPreviewExclusion,
        AddSpaceUrlPreviewExclusionResult,
        AddSpaceUrlPreviewExclusion
    ),
    (
        RemoveSpaceUrlPreviewExclusionInput,
        RemoveSpaceUrlPreviewExclusion,
        RemoveSpaceUrlPreviewExclusion,
        RemoveSpaceUrlPreviewExclusionResult,
        RemoveSpaceUrlPreviewExclusion
    ),
    (
        GetUserGroupsInput,
        GetUserGroups,
        GetUserGroups,
        GetUserGroupsResult,
        GetUserGroups
    ),
    (
        CreateUserGroupInput,
        CreateUserGroup,
        CreateUserGroup,
        CreateUserGroupResult,
        CreateUserGroup
    ),
    (
        UpdateUserGroupInput,
        UpdateUserGroup,
        UpdateUserGroup,
        UpdateUserGroupResult,
        UpdateUserGroup
    ),
    (
        DeleteUserGroupInput,
        DeleteUserGroup,
        DeleteUserGroup,
        DeleteUserGroupResult,
        DeleteUserGroup
    ),
    (
        GetSpaceSettingsInput,
        GetSpaceSettings,
        GetSpaceSettings,
        GetSpaceSettingsResult,
        GetSpaceSettings
    ),
    (
        ToggleSpaceGridInput,
        ToggleSpaceGrid,
        ToggleSpaceGrid,
        ToggleSpaceGridResult,
        ToggleSpaceGrid
    ),
    (GetGridInput, GetGrid, GetGrid, GetGridResult, GetGrid),
    (
        CreateGridRoomInput,
        CreateGridRoom,
        CreateGridRoom,
        CreateGridRoomResult,
        CreateGridRoom
    ),
    (
        JoinGridRoomInput,
        JoinGridRoom,
        JoinGridRoom,
        JoinGridRoomResult,
        JoinGridRoom
    ),
    (
        LeaveGridRoomInput,
        LeaveGridRoom,
        LeaveGridRoom,
        LeaveGridRoomResult,
        LeaveGridRoom
    ),
    (
        SetGridRoomTitleInput,
        SetGridRoomTitle,
        SetGridRoomTitle,
        SetGridRoomTitleResult,
        SetGridRoomTitle
    ),
    (
        SetGridRoomLockedInput,
        SetGridRoomLocked,
        SetGridRoomLocked,
        SetGridRoomLockedResult,
        SetGridRoomLocked
    ),
    (
        DeleteGridRoomInput,
        DeleteGridRoom,
        DeleteGridRoom,
        DeleteGridRoomResult,
        DeleteGridRoom
    ),
    (
        PrepareGridConnectionInput,
        PrepareGridConnection,
        PrepareGridConnection,
        PrepareGridConnectionResult,
        PrepareGridConnection
    ),
    (
        SetGridAvatarMicrophoneEnabledInput,
        SetGridAvatarMicrophoneEnabled,
        SetGridAvatarMicrophoneEnabled,
        SetGridAvatarMicrophoneEnabledResult,
        SetGridAvatarMicrophoneEnabled
    ),
    (
        GetGridHomeInput,
        GetGridHome,
        GetGridHome,
        GetGridHomeResult,
        GetGridHome
    ),
    (
        GetThreadReferencesInput,
        GetThreadReferences,
        GetThreadReferences,
        GetThreadReferencesResult,
        GetThreadReferences
    ),
    (
        GetThreadSubthreadsInput,
        GetThreadSubthreads,
        GetThreadSubthreads,
        GetThreadSubthreadsResult,
        GetThreadSubthreads
    ),
    (
        CreateUploadInput,
        CreateUpload,
        CreateUpload,
        CreateUploadResult,
        CreateUpload
    ),
    (
        SaveUploadPartInput,
        SaveUploadPart,
        SaveUploadPart,
        SaveUploadPartResult,
        SaveUploadPart
    ),
    (
        GetUploadStateInput,
        GetUploadState,
        GetUploadState,
        GetUploadStateResult,
        GetUploadState
    ),
    (
        FinishUploadInput,
        FinishUpload,
        FinishUpload,
        FinishUploadResult,
        FinishUpload
    ),
    (
        CancelUploadInput,
        CancelUpload,
        CancelUpload,
        CancelUploadResult,
        CancelUpload
    ),
    (
        UpdateDialogArchivedInput,
        UpdateDialogArchived,
        UpdateDialogArchived,
        UpdateDialogArchivedResult,
        UpdateDialogArchived
    ),
    (GetSpaceInput, GetSpace, GetSpace, GetSpaceResult, GetSpace),
    (
        ConnectAgentSessionInput,
        ConnectAgentSession,
        ConnectAgentSession,
        ConnectAgentSessionResult,
        ConnectAgentSession
    ),
    (
        SyncAgentSessionMessagesInput,
        SyncAgentSessionMessages,
        SyncAgentSessionMessages,
        SyncAgentSessionMessagesResult,
        SyncAgentSessionMessages
    ),
    (
        GetAgentSessionInput,
        GetAgentSession,
        GetAgentSession,
        GetAgentSessionResult,
        GetAgentSession
    ),
    (
        CreateBotAgentInput,
        CreateBotAgent,
        CreateBotAgent,
        CreateBotAgentResult,
        CreateBotAgent
    ),
    (
        GetBotAgentInput,
        GetBotAgent,
        GetBotAgent,
        GetBotAgentResult,
        GetBotAgent
    ),
    (
        ListBotAgentsInput,
        ListBotAgents,
        ListBotAgents,
        ListBotAgentsResult,
        ListBotAgents
    ),
    (
        UpdateBotAgentInput,
        UpdateBotAgent,
        UpdateBotAgent,
        UpdateBotAgentResult,
        UpdateBotAgent
    ),
    (
        DeleteBotAgentInput,
        DeleteBotAgent,
        DeleteBotAgent,
        DeleteBotAgentResult,
        DeleteBotAgent
    ),
    (
        GetBotConfigurationCatalogInput,
        GetBotConfigurationCatalog,
        GetBotConfigurationCatalog,
        GetBotConfigurationCatalogResult,
        GetBotConfigurationCatalog
    ),
);

fn connection_init_for_token(token: &str, identity: &ClientIdentity) -> proto::ConnectionInit {
    proto::ConnectionInit {
        token: token.to_string(),
        build_number: None,
        layer: None,
        client_version: Some(identity.client_version().to_string()),
        os_version: client_info::current_os_version(),
        device_id: None,
        device_name: None,
        client_type: None,
        time_zone: None,
    }
}

fn rpc_error_code_name(error_code: i32) -> String {
    proto::rpc_error::Code::try_from(error_code)
        .map(|code| code.as_str_name())
        .unwrap_or("UNKNOWN")
        .to_string()
}

fn rpc_error_from_proto(error: proto::RpcError) -> RealtimeError {
    let error_name = rpc_error_code_name(error.error_code);
    let friendly = format_rpc_error(error.error_code, &error_name, &error.message, error.code);
    RealtimeError::RpcError {
        code: error.code,
        error_code: error.error_code,
        error_name,
        message: error.message,
        friendly,
    }
}

fn format_rpc_error(error_code: i32, error_name: &str, message: &str, status_code: i32) -> String {
    let label = match error_name {
        "UNKNOWN" => "Unknown RPC error",
        "BAD_REQUEST" => "Bad request",
        "UNAUTHENTICATED" => "Not authenticated",
        "RATE_LIMIT" => "Rate limited",
        "INTERNAL_ERROR" => "Internal server error",
        "PEER_ID_INVALID" => "Invalid peer (chat/user id)",
        "MESSAGE_ID_INVALID" => "Invalid message id",
        "USER_ID_INVALID" => "Invalid user id",
        "USER_ALREADY_MEMBER" => "User already in chat/space",
        "SPACE_ID_INVALID" => "Invalid space id",
        "CHAT_ID_INVALID" => "Invalid chat id",
        "EMAIL_INVALID" => "Invalid email address",
        "PHONE_NUMBER_INVALID" => "Invalid phone number",
        "SPACE_ADMIN_REQUIRED" => "Space admin required",
        "SPACE_OWNER_REQUIRED" => "Space owner required",
        "USERNAME_INVALID" => "Invalid username",
        "USERNAME_TAKEN" => "Username already taken",
        "FIRST_NAME_INVALID" => "Invalid first name",
        _ => "Unknown RPC error",
    };

    let mut formatted = String::from(label);
    if error_name == "UNKNOWN" && error_code != 0 {
        formatted.push_str(&format!(" {error_code}"));
    }
    if !message.is_empty() && !message.eq_ignore_ascii_case(label) {
        formatted.push_str(": ");
        formatted.push_str(message);
    }
    if status_code != 0 {
        formatted.push_str(&format!(" (HTTP {status_code})"));
    }
    formatted
}

fn connection_error_from_proto(error: proto::ConnectionError) -> RealtimeError {
    let reason = error.reason;
    let parsed_reason = proto::connection_error::Reason::try_from(reason).ok();
    if matches!(
        parsed_reason,
        Some(
            proto::connection_error::Reason::InvalidAuth
                | proto::connection_error::Reason::SessionRevoked
        )
    ) {
        return RealtimeError::AuthenticationInvalidated;
    }
    let reason_name = parsed_reason
        .map(|reason| reason.as_str_name())
        .unwrap_or("UNKNOWN")
        .to_string();
    let friendly = format_connection_error(reason, &reason_name);
    RealtimeError::ConnectionError {
        reason,
        reason_name,
        friendly,
    }
}

fn format_connection_error(reason: i32, reason_name: &str) -> String {
    match reason_name {
        "UNAUTHORIZED" => "Realtime connection unauthorized".to_string(),
        "INVALID_AUTH" => "Realtime auth token is invalid".to_string(),
        "SESSION_REVOKED" => "Realtime session was revoked".to_string(),
        "REASON_UNSPECIFIED" => "Realtime connection rejected".to_string(),
        _ => format!("Realtime connection rejected: unknown reason {reason}"),
    }
}

fn normalize_realtime_url(url: impl Into<String>) -> Result<Url, RealtimeError> {
    let original = url.into();
    let normalized = original.trim().to_string();
    if normalized.is_empty() {
        return Err(RealtimeError::InvalidUrl {
            url: original,
            message: "realtime URL cannot be empty".to_string(),
        });
    }

    let parsed = Url::parse(&normalized).map_err(|err| RealtimeError::InvalidUrl {
        url: normalized.clone(),
        message: err.to_string(),
    })?;

    if !matches!(parsed.scheme(), "ws" | "wss") {
        return Err(RealtimeError::InvalidUrl {
            url: normalized,
            message: "scheme must be ws or wss".to_string(),
        });
    }

    if parsed.host_str().is_none() {
        return Err(RealtimeError::InvalidUrl {
            url: normalized,
            message: "host is required".to_string(),
        });
    }

    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err(RealtimeError::InvalidUrl {
            url: normalized,
            message: "credentials are not valid in the realtime URL".to_string(),
        });
    }

    if parsed.fragment().is_some() {
        return Err(RealtimeError::InvalidUrl {
            url: normalized,
            message: "fragments are not valid in the realtime URL".to_string(),
        });
    }

    Ok(parsed)
}

fn realtime_url_for_log(url: &Url) -> String {
    let host = url.host_str().unwrap_or("<missing-host>");
    let port = url
        .port()
        .map(|port| format!(":{port}"))
        .unwrap_or_default();
    format!("{}://{}{}{}", url.scheme(), host, port, url.path())
}

fn realtime_url_for_debug(raw_url: &str) -> String {
    Url::parse(raw_url.trim())
        .map(|url| realtime_url_for_log(&url))
        .unwrap_or_else(|_| "<invalid>".to_string())
}

fn realtime_header_value(field: &'static str, value: &str) -> Result<HeaderValue, RealtimeError> {
    HeaderValue::from_str(value).map_err(|_| RealtimeError::InvalidHeaderValue { field })
}

fn realtime_event_kind(event: &RealtimeEvent) -> &'static str {
    match event {
        RealtimeEvent::AuthenticationInvalidated => "authentication_invalidated",
        RealtimeEvent::Updates(_) => "updates",
        RealtimeEvent::Grid(_) => "grid",
        RealtimeEvent::Bot(_) => "bot",
        RealtimeEvent::Ack { .. } => "ack",
        RealtimeEvent::Pong { .. } => "pong",
    }
}

async fn with_optional_timeout<T, E, Fut>(
    operation: &'static str,
    timeout: Option<Duration>,
    future: Fut,
) -> Result<T, RealtimeError>
where
    Fut: Future<Output = Result<T, E>>,
    RealtimeError: From<E>,
{
    match timeout {
        Some(timeout) => tokio::time::timeout(timeout, future)
            .await
            .map_err(|_| RealtimeError::Timeout { operation, timeout })?
            .map_err(RealtimeError::from),
        None => future.await.map_err(RealtimeError::from),
    }
}

struct IdGenerator {
    last_timestamp: u64,
    sequence: u32,
}

impl IdGenerator {
    fn new() -> Self {
        Self {
            last_timestamp: 0,
            sequence: 0,
        }
    }

    fn next_id(&mut self) -> u64 {
        let timestamp = current_epoch_seconds().saturating_sub(EPOCH_SECONDS);
        if timestamp == self.last_timestamp {
            self.sequence = self.sequence.wrapping_add(1);
        } else {
            self.sequence = 0;
            self.last_timestamp = timestamp;
        }

        (timestamp << 32) | self.sequence as u64
    }
}

const EPOCH_SECONDS: u64 = 1_735_689_600; // 2025-01-01T00:00:00Z

fn current_epoch_seconds() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::{TcpListener, TcpStream};
    use tokio_tungstenite::WebSocketStream;
    use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
    use tokio_tungstenite::{accept_async, accept_hdr_async};

    #[tokio::test]
    async fn first_session_subscriber_receives_events_published_before_subscription() {
        let (commands, _command_rx) = mpsc::channel(DEFAULT_SESSION_COMMAND_CAPACITY);
        let (events, initial_events) = broadcast::channel(DEFAULT_SESSION_EVENT_CAPACITY);
        let (_closed_tx, closed) = watch::channel(false);
        let session = RealtimeSession {
            commands,
            events: events.clone(),
            initial_events: Arc::new(Mutex::new(Some(initial_events))),
            closed,
            rpc_timeout: Some(DEFAULT_RPC_TIMEOUT),
            heartbeat_interval: Some(DEFAULT_HEARTBEAT_INTERVAL),
            heartbeat_timeout: DEFAULT_HEARTBEAT_TIMEOUT,
            rpc_permits: Arc::new(Semaphore::new(DEFAULT_SESSION_MAX_IN_FLIGHT_RPCS)),
        };

        events.send(RealtimeEvent::Pong { nonce: 42 }).unwrap();
        let mut receiver = session.subscribe();

        assert!(matches!(
            receiver.recv().await.unwrap(),
            RealtimeEvent::Pong { nonce: 42 }
        ));
    }

    #[tokio::test]
    async fn receiver_drains_queued_events_after_transport_task_exits() {
        let (events, receiver) = broadcast::channel(128);
        let (closed_tx, closed) = watch::channel(false);
        let mut receiver = RealtimeEventReceiver {
            events: receiver,
            closed,
        };
        for nonce in 0..64 {
            events.send(RealtimeEvent::Pong { nonce }).unwrap();
        }
        events
            .send(RealtimeEvent::AuthenticationInvalidated)
            .unwrap();
        closed_tx.send(true).unwrap();
        drop(closed_tx);

        for expected in 0..64 {
            assert!(
                matches!(receiver.recv().await, Ok(RealtimeEvent::Pong { nonce }) if nonce == expected)
            );
        }
        assert!(matches!(
            receiver.recv().await,
            Ok(RealtimeEvent::AuthenticationInvalidated)
        ));
        assert!(matches!(
            receiver.recv().await,
            Err(RealtimeError::ConnectionClosed)
        ));
    }

    #[test]
    fn bounded_receiver_snapshot_does_not_chase_future_events() {
        let (commands, _command_rx) = mpsc::channel(DEFAULT_SESSION_COMMAND_CAPACITY);
        let (events, initial_events) = broadcast::channel(DEFAULT_SESSION_EVENT_CAPACITY);
        let (_closed_tx, closed) = watch::channel(false);
        let session = RealtimeSession {
            commands,
            events: events.clone(),
            initial_events: Arc::new(Mutex::new(Some(initial_events))),
            closed,
            rpc_timeout: Some(DEFAULT_RPC_TIMEOUT),
            heartbeat_interval: Some(DEFAULT_HEARTBEAT_INTERVAL),
            heartbeat_timeout: DEFAULT_HEARTBEAT_TIMEOUT,
            rpc_permits: Arc::new(Semaphore::new(DEFAULT_SESSION_MAX_IN_FLIGHT_RPCS)),
        };

        events.send(RealtimeEvent::Pong { nonce: 42 }).unwrap();
        let mut receiver = session.subscribe();
        let queued_count = receiver.len();
        events.send(RealtimeEvent::Pong { nonce: 43 }).unwrap();

        for _ in 0..queued_count {
            assert!(receiver.try_recv().unwrap().is_some());
        }
        assert!(matches!(
            receiver.try_recv().unwrap(),
            Some(RealtimeEvent::Pong { nonce: 43 })
        ));
    }

    #[test]
    fn rpc_error_code_name_uses_stable_proto_name() {
        assert_eq!(
            rpc_error_code_name(proto::rpc_error::Code::PeerIdInvalid as i32),
            "PEER_ID_INVALID"
        );
        assert_eq!(rpc_error_code_name(999), "UNKNOWN");
    }

    #[test]
    fn rpc_error_formatter_covers_new_profile_codes() {
        assert_eq!(
            format_rpc_error(
                proto::rpc_error::Code::UsernameInvalid as i32,
                "USERNAME_INVALID",
                "",
                400
            ),
            "Invalid username (HTTP 400)"
        );
        assert_eq!(
            format_rpc_error(
                proto::rpc_error::Code::UsernameTaken as i32,
                "USERNAME_TAKEN",
                "handle exists",
                409
            ),
            "Username already taken: handle exists (HTTP 409)"
        );
        assert_eq!(
            format_rpc_error(
                proto::rpc_error::Code::FirstNameInvalid as i32,
                "FIRST_NAME_INVALID",
                "",
                400
            ),
            "Invalid first name (HTTP 400)"
        );
    }

    #[test]
    fn authenticated_connection_revocation_has_a_distinct_terminal_error() {
        for reason in [
            proto::connection_error::Reason::InvalidAuth,
            proto::connection_error::Reason::SessionRevoked,
        ] {
            assert!(matches!(
                connection_error_from_proto(proto::ConnectionError {
                    reason: reason as i32,
                }),
                RealtimeError::AuthenticationInvalidated
            ));
        }
    }

    #[test]
    fn unauthorized_connection_error_remains_non_destructive() {
        let err = connection_error_from_proto(proto::ConnectionError {
            reason: proto::connection_error::Reason::Unauthorized as i32,
        });
        assert!(matches!(
            err,
            RealtimeError::ConnectionError { ref reason_name, .. }
                if reason_name == "UNAUTHORIZED"
        ));
    }

    #[test]
    fn unknown_connection_error_reason_is_preserved() {
        let err = connection_error_from_proto(proto::ConnectionError { reason: 999 });

        match err {
            RealtimeError::ConnectionError {
                reason,
                reason_name,
                friendly,
            } => {
                assert_eq!(reason, 999);
                assert_eq!(reason_name, "UNKNOWN");
                assert_eq!(friendly, "Realtime connection rejected: unknown reason 999");
            }
            other => panic!("expected connection error, got {other:?}"),
        }
    }

    #[test]
    fn connection_init_uses_custom_client_identity() {
        let init =
            connection_init_for_token("token-1", &ClientIdentity::new("integration-test", "9.9.9"));

        assert_eq!(init.token, "token-1");
        assert_eq!(init.client_version.as_deref(), Some("9.9.9"));
        assert!(init.build_number.is_none());
        assert!(init.layer.is_none());
    }

    #[tokio::test]
    #[allow(clippy::result_large_err)]
    async fn realtime_client_connects_and_calls_get_me_against_local_server() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_hdr_async(stream, |request: &Request, response: Response| {
                assert_eq!(
                    request
                        .headers()
                        .get(client_info::CLIENT_TYPE_HEADER)
                        .and_then(|value| value.to_str().ok()),
                    Some("transport-test")
                );
                assert_eq!(
                    request
                        .headers()
                        .get(client_info::CLIENT_VERSION_HEADER)
                        .and_then(|value| value.to_str().ok()),
                    Some("1.2.3")
                );
                Ok(response)
            })
            .await
            .unwrap();

            let init = read_test_client_message(&mut ws).await;
            match init.body {
                Some(proto::client_message::Body::ConnectionInit(init)) => {
                    assert_eq!(init.token, "token-1");
                    assert_eq!(init.client_version.as_deref(), Some("1.2.3"));
                    assert!(init.os_version.is_some());
                }
                other => panic!("expected connection init, got {other:?}"),
            }
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;

            let rpc = read_test_client_message(&mut ws).await;
            match &rpc.body {
                Some(proto::client_message::Body::RpcCall(call)) => {
                    assert_eq!(call.method, proto::Method::GetMe as i32);
                    assert!(matches!(call.input, Some(proto::rpc_call::Input::GetMe(_))));
                }
                other => panic!("expected getMe rpc call, got {other:?}"),
            }
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 2,
                    body: Some(proto::server_protocol_message::Body::RpcResult(
                        proto::RpcResult {
                            req_msg_id: rpc.id,
                            result: Some(proto::rpc_result::Result::GetMe(proto::GetMeResult {
                                user: Some(proto::User {
                                    id: 42,
                                    first_name: Some("Ada".to_string()),
                                    ..Default::default()
                                }),
                            })),
                        },
                    )),
                },
            )
            .await;
        });

        let mut client = RealtimeClient::builder(format!("ws://{addr}/realtime"), "token-1")
            .identity(ClientIdentity::new("transport-test", "1.2.3"))
            .without_connect_timeout()
            .without_rpc_timeout()
            .connect()
            .await
            .unwrap();
        let result = client.call(proto::GetMeInput {}).await.unwrap();

        assert_eq!(result.user.unwrap().id, 42);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn converting_client_to_session_reuses_authenticated_socket_and_request_ids() {
        tokio::time::timeout(Duration::from_secs(3), async {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            let server = tokio::spawn(async move {
                let (stream, _) = listener.accept().await.unwrap();
                let mut ws = accept_async(stream).await.unwrap();
                let init = read_test_client_message(&mut ws).await;
                assert!(matches!(
                    init.body,
                    Some(proto::client_message::Body::ConnectionInit(_))
                ));
                send_test_server_message(
                    &mut ws,
                    proto::ServerProtocolMessage {
                        id: 1,
                        body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                            proto::ConnectionOpen {},
                        )),
                    },
                )
                .await;
                let mut previous_id = 0;
                for response_id in [2, 3] {
                    let rpc = read_test_client_message(&mut ws).await;
                    assert!(matches!(
                        rpc.body,
                        Some(proto::client_message::Body::RpcCall(_))
                    ));
                    assert!(rpc.id > previous_id);
                    previous_id = rpc.id;
                    send_test_server_message(
                        &mut ws,
                        get_me_result_message(response_id, rpc.id, 42),
                    )
                    .await;
                }
            });
            let mut client = RealtimeClient::builder(format!("ws://{addr}/realtime"), "test-token")
                .rpc_timeout(Duration::from_millis(500))
                .connect()
                .await
                .unwrap();
            assert_eq!(
                client
                    .call(proto::GetMeInput {})
                    .await
                    .unwrap()
                    .user
                    .unwrap()
                    .id,
                42
            );
            let session = client.into_session();
            assert_eq!(session.rpc_timeout, Some(Duration::from_millis(500)));
            assert_eq!(
                session
                    .call(proto::GetMeInput {})
                    .await
                    .unwrap()
                    .user
                    .unwrap()
                    .id,
                42
            );
            server.await.unwrap();
        })
        .await
        .expect("conversion must not open another connection");
    }

    #[tokio::test]
    async fn realtime_client_receives_update_events_and_acks_them() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();

            let init = read_test_client_message(&mut ws).await;
            assert!(matches!(
                init.body,
                Some(proto::client_message::Body::ConnectionInit(_))
            ));
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;
            send_test_server_message(&mut ws, test_update_server_message(9, 77)).await;

            let ack = read_test_client_message(&mut ws).await;
            match ack.body {
                Some(proto::client_message::Body::Ack(ack)) => {
                    assert_eq!(ack.msg_id, 9);
                }
                other => panic!("expected ack for pushed update, got {other:?}"),
            }
        });

        let mut client = RealtimeClient::builder(format!("ws://{addr}/realtime"), "token-1")
            .without_connect_timeout()
            .without_rpc_timeout()
            .connect()
            .await
            .unwrap();
        let event = client.next_event().await.unwrap();

        match event {
            RealtimeEvent::Updates(updates) => {
                assert_eq!(updates.len(), 1);
                match updates[0].update.as_ref() {
                    Some(proto::update::Update::NewMessage(update)) => {
                        assert_eq!(update.message.as_ref().unwrap().id, 77);
                    }
                    other => panic!("expected new message update, got {other:?}"),
                }
            }
            other => panic!("expected updates event, got {other:?}"),
        }
        server.await.unwrap();
    }

    #[tokio::test]
    async fn realtime_client_receives_grid_events_and_acks_them() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();

            let init = read_test_client_message(&mut ws).await;
            assert!(matches!(
                init.body,
                Some(proto::client_message::Body::ConnectionInit(_))
            ));
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;
            send_test_server_message(&mut ws, test_grid_server_message(9, 7)).await;

            let ack = read_test_client_message(&mut ws).await;
            match ack.body {
                Some(proto::client_message::Body::Ack(ack)) => {
                    assert_eq!(ack.msg_id, 9);
                }
                other => panic!("expected ack for pushed Grid event, got {other:?}"),
            }
        });

        let mut client = RealtimeClient::builder(format!("ws://{addr}/realtime"), "token-1")
            .without_connect_timeout()
            .without_rpc_timeout()
            .connect()
            .await
            .unwrap();
        let event = client.next_event().await.unwrap();

        match event {
            RealtimeEvent::Grid(event) => match event.event {
                Some(proto::grid_event::Event::Changed(changed)) => {
                    assert_eq!(changed.space_ids, vec![7]);
                }
                other => panic!("expected changed Grid event, got {other:?}"),
            },
            other => panic!("expected Grid event, got {other:?}"),
        }
        server.await.unwrap();
    }

    #[tokio::test]
    async fn realtime_client_receives_bot_events_and_acks_them() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();

            let init = read_test_client_message(&mut ws).await;
            assert!(matches!(
                init.body,
                Some(proto::client_message::Body::ConnectionInit(_))
            ));
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;
            send_test_server_message(&mut ws, test_bot_server_message(9, 7)).await;

            let ack = read_test_client_message(&mut ws).await;
            match ack.body {
                Some(proto::client_message::Body::Ack(ack)) => assert_eq!(ack.msg_id, 9),
                other => panic!("expected ack for pushed bot event, got {other:?}"),
            }
        });

        let mut client = RealtimeClient::builder(format!("ws://{addr}/realtime"), "token-1")
            .without_connect_timeout()
            .without_rpc_timeout()
            .connect()
            .await
            .unwrap();
        let event = client.next_event().await.unwrap();

        match event {
            RealtimeEvent::Bot(event) => match event.event {
                Some(proto::bot_event::Event::ChatSettingsRequested(request)) => {
                    assert_eq!(request.chat_id, 7);
                }
                other => panic!("expected chat settings bot event, got {other:?}"),
            },
            other => panic!("expected bot event, got {other:?}"),
        }
        server.await.unwrap();
    }

    #[tokio::test]
    async fn realtime_rpc_wait_acks_pushed_updates_before_matching_result() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();

            let init = read_test_client_message(&mut ws).await;
            assert!(matches!(
                init.body,
                Some(proto::client_message::Body::ConnectionInit(_))
            ));
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;

            let rpc = read_test_client_message(&mut ws).await;
            send_test_server_message(&mut ws, test_update_server_message(10, 88)).await;

            let ack = read_test_client_message(&mut ws).await;
            match ack.body {
                Some(proto::client_message::Body::Ack(ack)) => {
                    assert_eq!(ack.msg_id, 10);
                }
                other => panic!("expected ack while waiting for rpc result, got {other:?}"),
            }

            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 2,
                    body: Some(proto::server_protocol_message::Body::RpcResult(
                        proto::RpcResult {
                            req_msg_id: rpc.id,
                            result: Some(proto::rpc_result::Result::GetMe(proto::GetMeResult {
                                user: Some(proto::User {
                                    id: 42,
                                    ..Default::default()
                                }),
                            })),
                        },
                    )),
                },
            )
            .await;
        });

        let mut client = RealtimeClient::builder(format!("ws://{addr}/realtime"), "token-1")
            .without_connect_timeout()
            .without_rpc_timeout()
            .connect()
            .await
            .unwrap();
        let result = client.call(proto::GetMeInput {}).await.unwrap();

        assert_eq!(result.user.unwrap().id, 42);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn realtime_session_routes_pushed_updates_during_rpc() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();

            let init = read_test_client_message(&mut ws).await;
            assert!(matches!(
                init.body,
                Some(proto::client_message::Body::ConnectionInit(_))
            ));
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;

            let rpc = read_test_client_message(&mut ws).await;
            send_test_server_message(&mut ws, test_update_server_message(10, 88)).await;
            let ack = read_test_client_message(&mut ws).await;
            assert!(matches!(
                ack.body,
                Some(proto::client_message::Body::Ack(proto::Ack { msg_id: 10 }))
            ));
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 2,
                    body: Some(proto::server_protocol_message::Body::RpcResult(
                        proto::RpcResult {
                            req_msg_id: rpc.id,
                            result: Some(proto::rpc_result::Result::GetMe(proto::GetMeResult {
                                user: Some(proto::User {
                                    id: 42,
                                    ..Default::default()
                                }),
                            })),
                        },
                    )),
                },
            )
            .await;
        });

        let session = RealtimeClient::builder(format!("ws://{addr}/realtime"), "token-1")
            .without_connect_timeout()
            .without_rpc_timeout()
            .connect_session()
            .await
            .unwrap();
        let mut events = session.subscribe();
        let (result, event) = tokio::join!(session.call(proto::GetMeInput {}), events.recv());

        assert_eq!(result.unwrap().user.unwrap().id, 42);
        match event.unwrap() {
            RealtimeEvent::Updates(updates) => match updates[0].update.as_ref() {
                Some(proto::update::Update::NewMessage(update)) => {
                    assert_eq!(update.message.as_ref().unwrap().id, 88);
                }
                other => panic!("expected new message update, got {other:?}"),
            },
            other => panic!("expected updates event, got {other:?}"),
        }
        server.await.unwrap();
    }

    #[tokio::test]
    async fn realtime_session_matches_concurrent_rpc_results_by_request_id() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            let _ = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;

            let first = read_test_client_message(&mut ws).await;
            let second = read_test_client_message(&mut ws).await;
            for (id, request, user_id) in [(2, &second, 2), (3, &first, 1)] {
                send_test_server_message(
                    &mut ws,
                    proto::ServerProtocolMessage {
                        id,
                        body: Some(proto::server_protocol_message::Body::RpcResult(
                            proto::RpcResult {
                                req_msg_id: request.id,
                                result: Some(proto::rpc_result::Result::GetMe(
                                    proto::GetMeResult {
                                        user: Some(proto::User {
                                            id: user_id,
                                            ..Default::default()
                                        }),
                                    },
                                )),
                            },
                        )),
                    },
                )
                .await;
            }
        });

        let session = RealtimeClient::builder(format!("ws://{addr}/realtime"), "token-1")
            .without_connect_timeout()
            .without_rpc_timeout()
            .connect_session()
            .await
            .unwrap();
        let (first, second) = tokio::join!(
            session.call(proto::GetMeInput {}),
            session.call(proto::GetMeInput {})
        );

        assert_eq!(first.unwrap().user.unwrap().id, 1);
        assert_eq!(second.unwrap().user.unwrap().id, 2);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn unauthenticated_application_rpc_keeps_v2_session_usable() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            let _ = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;

            let rejected = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 2,
                    body: Some(proto::server_protocol_message::Body::RpcError(
                        proto::RpcError {
                            req_msg_id: rejected.id,
                            error_code: proto::rpc_error::Code::Unauthenticated as i32,
                            message: "request rejected".into(),
                            code: 401,
                        },
                    )),
                },
            )
            .await;

            let recovered = read_test_client_message(&mut ws).await;
            send_test_server_message(&mut ws, get_me_result_message(3, recovered.id, 42)).await;
        });

        let session = RealtimeClient::builder(format!("ws://{addr}/realtime"), "token-1")
            .without_connect_timeout()
            .without_rpc_timeout()
            .connect_session()
            .await
            .unwrap();
        let mut events = session.subscribe();
        let error = session.call(proto::GetMeInput {}).await.unwrap_err();
        assert!(matches!(
            error,
            RealtimeError::RpcError { ref error_name, .. }
                if error_name == "UNAUTHENTICATED"
        ));
        assert!(matches!(events.try_recv(), Ok(None)));
        assert_eq!(
            session
                .call(proto::GetMeInput {})
                .await
                .unwrap()
                .user
                .unwrap()
                .id,
            42
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn authenticated_v2_revocation_emits_terminal_event_and_rejects_pending_call() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            let _ = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;
            let _pending = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 2,
                    body: Some(proto::server_protocol_message::Body::ConnectionError(
                        proto::ConnectionError {
                            reason: proto::connection_error::Reason::SessionRevoked as i32,
                        },
                    )),
                },
            )
            .await;
        });

        let session = RealtimeClient::builder(format!("ws://{addr}/realtime"), "token-1")
            .without_connect_timeout()
            .without_rpc_timeout()
            .connect_session()
            .await
            .unwrap();
        let mut events = session.subscribe();
        let (result, event) = tokio::join!(session.call(proto::GetMeInput {}), events.recv());
        assert!(matches!(
            result,
            Err(RealtimeError::AuthenticationInvalidated)
        ));
        assert!(matches!(
            event,
            Ok(RealtimeEvent::AuthenticationInvalidated)
        ));
        server.await.unwrap();
    }

    #[tokio::test]
    async fn realtime_session_bounds_in_flight_rpcs() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            let _ = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;

            let first = read_test_client_message(&mut ws).await;
            assert!(
                tokio::time::timeout(Duration::from_millis(50), read_test_client_message(&mut ws),)
                    .await
                    .is_err(),
                "session issued a second RPC above its configured in-flight limit"
            );
            send_test_server_message(&mut ws, get_me_result_message(2, first.id, 1)).await;
            let second = read_test_client_message(&mut ws).await;
            send_test_server_message(&mut ws, get_me_result_message(3, second.id, 2)).await;
        });

        let session = RealtimeClient::builder(format!("ws://{addr}/realtime"), "token-1")
            .without_connect_timeout()
            .without_rpc_timeout()
            .max_in_flight_rpcs(1)
            .connect_session()
            .await
            .unwrap();
        let (first, second) = tokio::join!(
            session.call(proto::GetMeInput {}),
            session.call(proto::GetMeInput {})
        );

        assert_eq!(first.unwrap().user.unwrap().id, 1);
        assert_eq!(second.unwrap().user.unwrap().id, 2);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn realtime_session_drops_timed_out_rpc_and_remains_usable() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            let _ = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;

            let timed_out = read_test_client_message(&mut ws).await;
            tokio::time::sleep(Duration::from_millis(40)).await;
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 2,
                    body: Some(proto::server_protocol_message::Body::RpcResult(
                        proto::RpcResult {
                            req_msg_id: timed_out.id,
                            result: Some(proto::rpc_result::Result::GetMe(proto::GetMeResult {
                                user: Some(proto::User {
                                    id: 1,
                                    ..Default::default()
                                }),
                            })),
                        },
                    )),
                },
            )
            .await;

            let recovered = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 3,
                    body: Some(proto::server_protocol_message::Body::RpcResult(
                        proto::RpcResult {
                            req_msg_id: recovered.id,
                            result: Some(proto::rpc_result::Result::GetMe(proto::GetMeResult {
                                user: Some(proto::User {
                                    id: 2,
                                    ..Default::default()
                                }),
                            })),
                        },
                    )),
                },
            )
            .await;
        });

        let session = RealtimeClient::builder(format!("ws://{addr}/realtime"), "token-1")
            .without_connect_timeout()
            .rpc_timeout(Duration::from_millis(25))
            .connect_session()
            .await
            .unwrap();

        assert!(matches!(
            session.call(proto::GetMeInput {}).await,
            Err(RealtimeError::Timeout {
                operation: "rpc",
                ..
            })
        ));
        let recovered = session.call(proto::GetMeInput {}).await.unwrap();
        assert_eq!(recovered.user.unwrap().id, 2);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn realtime_session_reports_commit_unknown_for_timed_out_mutation() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            let _ = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;

            let _mutation = read_test_client_message(&mut ws).await;
            tokio::time::sleep(Duration::from_millis(50)).await;
        });

        let session = RealtimeClient::builder(format!("ws://{addr}/realtime"), "token-1")
            .without_connect_timeout()
            .rpc_timeout(Duration::from_millis(25))
            .connect_session()
            .await
            .unwrap();

        let error = session
            .invoke(
                proto::Method::DeleteChat,
                proto::rpc_call::Input::DeleteChat(proto::DeleteChatInput::default()),
            )
            .await
            .unwrap_err();
        assert!(matches!(error, RealtimeError::CommitOutcomeUnknown));
        server.await.unwrap();
    }

    #[tokio::test]
    async fn timed_out_queued_session_command_cannot_be_admitted_later() {
        let (command_tx, mut command_rx) = mpsc::channel(1);
        let (event_tx, initial_event_rx) = broadcast::channel(1);
        let (_closed_tx, closed_rx) = watch::channel(false);
        let session = RealtimeSession {
            commands: command_tx,
            events: event_tx,
            initial_events: Arc::new(Mutex::new(Some(initial_event_rx))),
            closed: closed_rx,
            rpc_timeout: Some(Duration::from_millis(20)),
            heartbeat_interval: None,
            heartbeat_timeout: DEFAULT_HEARTBEAT_TIMEOUT,
            rpc_permits: Arc::new(Semaphore::new(1)),
        };

        let invocation = tokio::spawn(async move {
            session
                .invoke(
                    proto::Method::DeleteChat,
                    proto::rpc_call::Input::DeleteChat(proto::DeleteChatInput::default()),
                )
                .await
        });
        let command = command_rx.recv().await.unwrap();

        assert!(matches!(
            invocation.await.unwrap(),
            Err(RealtimeError::Timeout {
                operation: "rpc",
                ..
            })
        ));
        let SessionCommand::Invoke {
            admission,
            attempted,
            response,
            ..
        } = command;
        assert!(!admit_session_command(&admission));
        assert!(!attempted.load(Ordering::Acquire));
        assert!(response.is_closed());
    }

    #[tokio::test]
    async fn realtime_session_closes_when_heartbeat_pong_is_missing() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            let _ = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;
            let ping = read_test_client_message(&mut ws).await;
            assert!(matches!(
                ping.body,
                Some(proto::client_message::Body::Ping(_))
            ));
            tokio::time::sleep(Duration::from_millis(100)).await;
        });

        let session = RealtimeClient::builder(format!("ws://{addr}/realtime"), "token-1")
            .without_connect_timeout()
            .heartbeat(Duration::from_millis(20), Duration::from_millis(30))
            .connect_session()
            .await
            .unwrap();
        let mut events = session.subscribe();

        let error = tokio::time::timeout(Duration::from_millis(150), events.recv())
            .await
            .expect("heartbeat deadline should close the session")
            .unwrap_err();
        assert!(matches!(error, RealtimeError::ConnectionClosed));
        assert!(session.is_closed());
        server.await.unwrap();
    }

    #[test]
    fn realtime_url_validation_accepts_ws_urls() {
        let url = normalize_realtime_url(" wss://api.inline.chat/realtime?edge=iad ").unwrap();
        assert_eq!(url.as_str(), "wss://api.inline.chat/realtime?edge=iad");
    }

    #[test]
    fn realtime_url_validation_rejects_invalid_urls() {
        let err = normalize_realtime_url("inline.test").unwrap_err();
        match err {
            RealtimeError::InvalidUrl { url, message } => {
                assert_eq!(url, "inline.test");
                assert!(message.contains("relative URL without a base"));
            }
            other => panic!("expected invalid URL, got {other:?}"),
        }

        let err = normalize_realtime_url("https://api.inline.chat/realtime").unwrap_err();
        match err {
            RealtimeError::InvalidUrl { message, .. } => {
                assert_eq!(message, "scheme must be ws or wss");
            }
            other => panic!("expected invalid URL, got {other:?}"),
        }

        let err = normalize_realtime_url("wss://user:secret@api.inline.chat/realtime").unwrap_err();
        match &err {
            RealtimeError::InvalidUrl { message, .. } => {
                assert_eq!(message, "credentials are not valid in the realtime URL");
                assert!(!err.to_string().contains("secret"));
            }
            other => panic!("expected invalid URL, got {other:?}"),
        }

        let err = normalize_realtime_url("wss://api.inline.chat/realtime#token").unwrap_err();
        match err {
            RealtimeError::InvalidUrl { message, .. } => {
                assert_eq!(message, "fragments are not valid in the realtime URL");
            }
            other => panic!("expected invalid URL, got {other:?}"),
        }
    }

    #[test]
    fn realtime_invalid_url_debug_redacts_unsafe_url_parts() {
        let err = normalize_realtime_url(
            "wss://user:url-secret@api.inline.chat/realtime?token=query-secret#frag",
        )
        .unwrap_err();
        let debug = format!("{err:?}");

        assert!(debug.contains("wss://api.inline.chat/realtime"));
        assert!(!debug.contains("url-secret"));
        assert!(!debug.contains("query-secret"));
    }

    #[test]
    fn realtime_url_for_log_omits_query_and_fragment() {
        let url = Url::parse("wss://api.inline.chat/realtime?token=secret#frag").unwrap();
        assert_eq!(realtime_url_for_log(&url), "wss://api.inline.chat/realtime");
    }

    #[test]
    fn realtime_header_value_rejects_invalid_values() {
        let err = realtime_header_value("user_agent", "bad\nvalue").unwrap_err();
        match err {
            RealtimeError::InvalidHeaderValue { field } => {
                assert_eq!(field, "user_agent");
            }
            other => panic!("expected invalid header value, got {other:?}"),
        }
    }

    #[test]
    fn realtime_builder_keeps_custom_identity_and_default_timeouts() {
        let builder = RealtimeClient::builder("wss://api.inline.chat/realtime", "token-1")
            .identity(ClientIdentity::new("agent", "0.2.0"));

        assert_eq!(builder.url, "wss://api.inline.chat/realtime");
        assert_eq!(builder.token, "token-1");
        assert_eq!(builder.identity.client_type(), "agent");
        assert_eq!(builder.identity.client_version(), "0.2.0");
        assert_eq!(builder.connect_timeout, Some(DEFAULT_CONNECT_TIMEOUT));
        assert_eq!(builder.rpc_timeout, Some(DEFAULT_RPC_TIMEOUT));
        assert_eq!(builder.heartbeat_interval, Some(DEFAULT_HEARTBEAT_INTERVAL));
        assert_eq!(builder.heartbeat_timeout, DEFAULT_HEARTBEAT_TIMEOUT);
        assert_eq!(
            builder.max_in_flight_rpcs,
            DEFAULT_SESSION_MAX_IN_FLIGHT_RPCS
        );
    }

    #[test]
    fn realtime_builder_debug_redacts_token() {
        let builder = RealtimeClient::builder(
            "wss://user:url-secret@api.inline.chat/realtime?token=query-secret",
            "secret-token-1",
        );
        let debug = format!("{builder:?}");

        assert!(debug.contains("RealtimeClientBuilder"));
        assert!(debug.contains("wss://api.inline.chat/realtime"));
        assert!(debug.contains("<redacted>"));
        assert!(!debug.contains("secret-token-1"));
        assert!(!debug.contains("url-secret"));
        assert!(!debug.contains("query-secret"));
    }

    #[test]
    fn realtime_builder_can_override_or_disable_timeouts() {
        let builder = RealtimeClient::builder("wss://api.inline.chat/realtime", "token-1")
            .connect_timeout(Duration::from_secs(5))
            .rpc_timeout(Duration::from_secs(10))
            .max_in_flight_rpcs(7);

        assert_eq!(builder.connect_timeout, Some(Duration::from_secs(5)));
        assert_eq!(builder.rpc_timeout, Some(Duration::from_secs(10)));
        assert_eq!(builder.max_in_flight_rpcs, 7);

        let builder = builder
            .without_connect_timeout()
            .without_rpc_timeout()
            .without_heartbeat();
        assert_eq!(builder.connect_timeout, None);
        assert_eq!(builder.rpc_timeout, None);
        assert_eq!(builder.heartbeat_interval, None);
    }

    #[test]
    fn typed_rpc_request_maps_method_input_and_result() {
        assert_eq!(
            <proto::GetChatsInput as RpcRequest>::METHOD,
            proto::Method::GetChats
        );

        let input = proto::GetChatsInput {};
        match input.into_rpc_input() {
            proto::rpc_call::Input::GetChats(_) => {}
            other => panic!("expected GetChats input, got {other:?}"),
        }

        let response = <proto::GetChatsInput as RpcRequest>::response_from_rpc_result(
            proto::rpc_result::Result::GetChats(proto::GetChatsResult::default()),
        )
        .unwrap();
        assert!(response.dialogs.is_empty());
    }

    #[test]
    fn bot_settings_rpc_requests_map_all_transport_variants() {
        assert_eq!(
            <proto::GetMyBotCapabilitiesInput as RpcRequest>::METHOD,
            proto::Method::GetMyBotCapabilities
        );
        assert!(matches!(
            proto::RequestBotChatSettingsInput::default().into_rpc_input(),
            proto::rpc_call::Input::RequestBotChatSettings(_)
        ));
        assert!(matches!(
            proto::InvokeBotChatSettingsItemInput::default().into_rpc_input(),
            proto::rpc_call::Input::InvokeBotChatSettingsItem(_)
        ));
        assert!(matches!(
            proto::AnswerBotChatSettingsInput::default().into_rpc_input(),
            proto::rpc_call::Input::AnswerBotChatSettings(_)
        ));
        assert!(
            <proto::AnswerBotChatSettingsInput as RpcRequest>::response_from_rpc_result(
                proto::rpc_result::Result::AnswerBotChatSettings(
                    proto::AnswerBotChatSettingsResult::default(),
                ),
            )
            .is_ok()
        );
    }

    #[test]
    fn bot_agent_rpc_requests_map_all_transport_variants() {
        assert_eq!(
            <proto::CreateBotAgentInput as RpcRequest>::METHOD,
            proto::Method::CreateBotAgent
        );
        assert!(matches!(
            proto::GetBotAgentInput::default().into_rpc_input(),
            proto::rpc_call::Input::GetBotAgent(_)
        ));
        assert!(matches!(
            proto::ListBotAgentsInput::default().into_rpc_input(),
            proto::rpc_call::Input::ListBotAgents(_)
        ));
        assert!(matches!(
            proto::UpdateBotAgentInput::default().into_rpc_input(),
            proto::rpc_call::Input::UpdateBotAgent(_)
        ));
        assert!(
            <proto::DeleteBotAgentInput as RpcRequest>::response_from_rpc_result(
                proto::rpc_result::Result::DeleteBotAgent(proto::DeleteBotAgentResult::default(),),
            )
            .is_ok()
        );
    }

    #[test]
    fn typed_rpc_request_rejects_unexpected_result_variant() {
        let err = <proto::GetChatsInput as RpcRequest>::response_from_rpc_result(
            proto::rpc_result::Result::GetMe(proto::GetMeResult::default()),
        )
        .unwrap_err();

        match err {
            RealtimeError::UnexpectedResult {
                method,
                expected,
                actual,
            } => {
                assert_eq!(method, "GET_CHATS");
                assert_eq!(expected, "GetChats");
                assert_eq!(actual, "GetMe");
            }
            other => panic!("expected unexpected result error, got {other:?}"),
        }
    }

    #[test]
    fn archived_dialog_rpc_has_typed_v2_and_v3_mapping() {
        assert_eq!(
            <proto::UpdateDialogArchivedInput as RpcRequest>::METHOD,
            proto::Method::UpdateDialogArchived
        );
        assert!(matches!(
            proto::UpdateDialogArchivedInput::default().into_rpc_input(),
            proto::rpc_call::Input::UpdateDialogArchived(_)
        ));
        assert!(
            <proto::UpdateDialogArchivedInput as RpcRequest>::response_from_rpc_result(
                proto::rpc_result::Result::UpdateDialogArchived(
                    proto::UpdateDialogArchivedResult::default(),
                ),
            )
            .is_ok()
        );
    }

    #[tokio::test]
    async fn optional_timeout_reports_elapsed_operation() {
        let err = with_optional_timeout("test", Some(Duration::from_millis(1)), async {
            tokio::time::sleep(Duration::from_millis(20)).await;
            Ok::<(), RealtimeError>(())
        })
        .await
        .unwrap_err();

        match err {
            RealtimeError::Timeout { operation, timeout } => {
                assert_eq!(operation, "test");
                assert_eq!(timeout, Duration::from_millis(1));
            }
            other => panic!("expected timeout, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn optional_timeout_can_be_disabled() {
        with_optional_timeout("test", None, async { Ok::<_, RealtimeError>("done") })
            .await
            .unwrap();
    }

    async fn read_test_client_message(ws: &mut WebSocketStream<TcpStream>) -> proto::ClientMessage {
        loop {
            match ws.next().await.unwrap().unwrap() {
                WsMessage::Binary(bytes) => {
                    return proto::ClientMessage::decode(&*bytes).unwrap();
                }
                WsMessage::Ping(_) | WsMessage::Pong(_) | WsMessage::Text(_) => continue,
                other => panic!("unexpected websocket message: {other:?}"),
            }
        }
    }

    async fn send_test_server_message(
        ws: &mut WebSocketStream<TcpStream>,
        message: proto::ServerProtocolMessage,
    ) {
        ws.send(WsMessage::Binary(message.encode_to_vec().into()))
            .await
            .unwrap();
    }

    fn get_me_result_message(
        id: u64,
        request_id: u64,
        user_id: i64,
    ) -> proto::ServerProtocolMessage {
        proto::ServerProtocolMessage {
            id,
            body: Some(proto::server_protocol_message::Body::RpcResult(
                proto::RpcResult {
                    req_msg_id: request_id,
                    result: Some(proto::rpc_result::Result::GetMe(proto::GetMeResult {
                        user: Some(proto::User {
                            id: user_id,
                            ..Default::default()
                        }),
                    })),
                },
            )),
        }
    }

    fn test_update_server_message(
        message_id: u64,
        inline_message_id: i64,
    ) -> proto::ServerProtocolMessage {
        proto::ServerProtocolMessage {
            id: message_id,
            body: Some(proto::server_protocol_message::Body::Message(
                proto::ServerMessage {
                    payload: Some(proto::server_message::Payload::Update(
                        proto::UpdatesPayload {
                            updates: vec![proto::Update {
                                seq: Some(1),
                                date: Some(1),
                                update: Some(proto::update::Update::NewMessage(
                                    proto::UpdateNewMessage {
                                        message: Some(proto::Message {
                                            id: inline_message_id,
                                            from_id: 42,
                                            peer_id: Some(proto::Peer {
                                                r#type: Some(proto::peer::Type::Chat(
                                                    proto::PeerChat { chat_id: 7 },
                                                )),
                                            }),
                                            chat_id: 7,
                                            message: Some("hello".to_owned()),
                                            date: 1,
                                            ..Default::default()
                                        }),
                                    },
                                )),
                            }],
                        },
                    )),
                },
            )),
        }
    }

    fn test_grid_server_message(message_id: u64, space_id: i64) -> proto::ServerProtocolMessage {
        proto::ServerProtocolMessage {
            id: message_id,
            body: Some(proto::server_protocol_message::Body::Message(
                proto::ServerMessage {
                    payload: Some(proto::server_message::Payload::Grid(proto::GridEvent {
                        event: Some(proto::grid_event::Event::Changed(proto::GridChanged {
                            space_ids: vec![space_id],
                            room_id: None,
                        })),
                    })),
                },
            )),
        }
    }

    fn test_bot_server_message(message_id: u64, chat_id: i64) -> proto::ServerProtocolMessage {
        proto::ServerProtocolMessage {
            id: message_id,
            body: Some(proto::server_protocol_message::Body::Message(
                proto::ServerMessage {
                    payload: Some(proto::server_message::Payload::Bot(proto::BotEvent {
                        event: Some(proto::bot_event::Event::ChatSettingsRequested(
                            proto::BotChatSettingsRequested {
                                request_id: 1,
                                chat_id,
                                actor_user_id: 42,
                                version: 1,
                            },
                        )),
                    })),
                },
            )),
        }
    }
}
