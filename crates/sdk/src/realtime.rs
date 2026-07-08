//! Realtime WebSocket RPC transport for Inline protocol calls.

use futures_util::{SinkExt, StreamExt};
use prost::Message;
use std::fmt;
use std::future::Future;
use std::time::Duration;
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
}

impl fmt::Debug for RealtimeClientBuilder {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RealtimeClientBuilder")
            .field("url", &realtime_url_for_debug(&self.url))
            .field("token", &"<redacted>")
            .field("identity", &self.identity)
            .field("connect_timeout", &self.connect_timeout)
            .field("rpc_timeout", &self.rpc_timeout)
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

impl RealtimeClientBuilder {
    /// Creates a realtime client builder with the default SDK identity.
    pub fn new(url: impl Into<String>, token: impl Into<String>) -> Self {
        Self {
            url: url.into(),
            token: token.into(),
            identity: ClientIdentity::sdk(),
            connect_timeout: Some(DEFAULT_CONNECT_TIMEOUT),
            rpc_timeout: Some(DEFAULT_RPC_TIMEOUT),
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
        let mut request = url.into_client_request()?;
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
}

impl RealtimeClient {
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
        let rpc_call = proto::RpcCall {
            method: method as i32,
            input: Some(input),
        };
        let message_id = self.next_id();
        log::trace!(
            target: "inline_sdk::realtime",
            "sending rpc method={} msg_id={message_id}",
            method.as_str_name()
        );
        let message = proto::ClientMessage {
            id: message_id,
            seq: self.next_seq(),
            body: Some(proto::client_message::Body::RpcCall(rpc_call)),
        };

        self.send_client_message(message).await?;

        with_optional_timeout(
            "rpc",
            self.rpc_timeout,
            self.wait_for_rpc_result(message_id),
        )
        .await
    }

    /// Returns the configured per-RPC timeout.
    pub fn rpc_timeout(&self) -> Option<Duration> {
        self.rpc_timeout
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
                    let message = error.message;
                    let error_name = rpc_error_code_name(error.error_code);
                    let friendly =
                        format_rpc_error(error.error_code, &error_name, &message, error.code);
                    log::warn!(
                        target: "inline_sdk::realtime",
                        "received rpc error msg_id={message_id} error={error_name} status={}",
                        error.code
                    );
                    return Err(RealtimeError::RpcError {
                        code: error.code,
                        error_code: error.error_code,
                        error_name,
                        message,
                        friendly,
                    });
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
                _ => {}
            }
        }
    }

    async fn send_client_message(
        &mut self,
        message: proto::ClientMessage,
    ) -> Result<(), RealtimeError> {
        let bytes = message.encode_to_vec();
        self.ws.send(WsMessage::Binary(bytes)).await?;
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
        UpdatePushNotificationDetailsInput,
        UpdatePushNotificationDetails,
        UpdatePushNotificationDetails,
        UpdatePushNotificationDetailsResult,
        UpdatePushNotificationDetails
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
);

fn connection_init_for_token(token: &str, identity: &ClientIdentity) -> proto::ConnectionInit {
    proto::ConnectionInit {
        token: token.to_string(),
        build_number: None,
        layer: None,
        client_version: Some(identity.client_version().to_string()),
        os_version: client_info::current_os_version(),
    }
}

fn rpc_error_code_name(error_code: i32) -> String {
    proto::rpc_error::Code::try_from(error_code)
        .map(|code| code.as_str_name())
        .unwrap_or("UNKNOWN")
        .to_string()
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
    let reason_name = proto::connection_error::Reason::try_from(reason)
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
    fn connection_error_preserves_proto_reason() {
        let err = connection_error_from_proto(proto::ConnectionError {
            reason: proto::connection_error::Reason::InvalidAuth as i32,
        });

        match err {
            RealtimeError::ConnectionError {
                reason,
                reason_name,
                friendly,
            } => {
                assert_eq!(reason, 2);
                assert_eq!(reason_name, "INVALID_AUTH");
                assert_eq!(friendly, "Realtime auth token is invalid");
            }
            other => panic!("expected connection error, got {other:?}"),
        }
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
            .rpc_timeout(Duration::from_secs(10));

        assert_eq!(builder.connect_timeout, Some(Duration::from_secs(5)));
        assert_eq!(builder.rpc_timeout, Some(Duration::from_secs(10)));

        let builder = builder.without_connect_timeout().without_rpc_timeout();
        assert_eq!(builder.connect_timeout, None);
        assert_eq!(builder.rpc_timeout, None);
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
}
