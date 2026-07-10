#![doc = include_str!("../README.md")]
#![warn(missing_docs)]
#![forbid(unsafe_code)]

use std::{fmt, str::FromStr};

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Backend/store boundary for client runtime operations.
pub mod backend;

/// Async client facade and runner.
pub mod runtime;

/// Realtime connector boundary.
pub mod realtime;

/// SDK-backed backend implementation.
pub mod sdk_backend;

/// Inline-native update discovery and bucket recovery policy.
pub mod sync;

/// Durable store boundary.
pub mod store;

/// Native Inline client request and record types.
pub mod types;

pub use backend::{
    BackendError, BackendResult, ClientBackend, InMemoryBackend, OperationOutcome, SendTextOutcome,
};
pub use inline_sdk::ClientIdentity;
pub use realtime::{
    FakeRealtimeAttempt, FakeRealtimeConnector, RealtimeConnectRequest, RealtimeConnectionInfo,
    RealtimeConnector, SdkRealtimeConnector,
};
pub use runtime::{
    ClientCommandError, ClientRequestError, ClientRunner, DEFAULT_COMMAND_QUEUE_CAPACITY,
    DEFAULT_EVENT_QUEUE_CAPACITY, DEFAULT_LOSSLESS_EVENT_QUEUE_CAPACITY,
    DEFAULT_MAX_CONCURRENT_REQUESTS, InlineClient, InlineClientBuilder, InlineClientRuntime,
    LosslessEventDelivery, LosslessEventReceiver, ReconnectPolicy,
};
pub use sdk_backend::{SdkBackend, SdkBackendBuildError, SdkBackendBuilder};
pub use store::{
    AccountStateSnapshot, ChatStateSnapshot, ClientEventDelivery, ClientStore, InMemoryStore,
    PendingSyncBatch, SqliteStore, StoreError, StoreResult, StoredReaction, StoredReadState,
    StoredSession, StoredTransaction, SyncBucketKey, SyncBucketPeer, SyncBucketState, SyncState,
};
pub use sync::SyncConfig;
pub use types::{
    AddChatParticipantRequest, AuthContactKind, AuthCredential, AuthStartRequest, AuthStartResult,
    AuthToken, AuthVerifyRequest, AuthVerifyResult, ChatCreateParticipant, ChatParticipantRecord,
    ChatParticipantsPage, ChatParticipantsRequest, ClientStatusSnapshot, ConnectRequest,
    CreateDmRequest, CreateReplyThreadRequest, CreateThreadRequest, CreatedChat, DeleteChatRequest,
    DeleteMessageRequest, DialogFollowMode, DialogNotificationMode, DialogRecord, DialogsOrder,
    DialogsPage, DialogsRequest, EditMessageRequest, HistoryPage, HistoryRequest, MediaKind,
    MessageContent, MessageMutation, MessageRecord, NotificationMode, PeerRef, ReactRequest,
    ReadRequest, RemoveChatParticipantRequest, SendTextRequest, SetMarkedUnreadRequest,
    SpaceMemberRecord, SpaceMemberRole, SpaceRecord, TypingRequest, UpdateChatInfoRequest,
    UpdateDialogNotificationsRequest, UploadHandle, UploadRequest, UserRecord, UserSettingsRecord,
};

/// Published package version.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Lossless bucket-sync schema implemented by this client release.
pub const CORE_SYNC_SCHEMA_REVISION: u32 = 1;

/// Errors returned by public `inline-client` helper types.
#[derive(Clone, Debug, Error, PartialEq, Eq)]
#[non_exhaustive]
pub enum ClientError {
    /// A required string field was empty or whitespace-only.
    #[error("{field} must not be empty")]
    EmptyField {
        /// Field name.
        field: &'static str,
    },

    /// A string field exceeded its public API limit.
    #[error("{field} is too long ({len} > {max})")]
    FieldTooLong {
        /// Field name.
        field: &'static str,
        /// Actual length in bytes.
        len: usize,
        /// Maximum allowed length in bytes.
        max: usize,
    },

    /// A string field contained ASCII control characters.
    #[error("{field} must not contain ASCII control characters")]
    ControlCharacter {
        /// Field name.
        field: &'static str,
    },
}

fn validate_token<'a>(
    field: &'static str,
    value: &'a str,
    max_len: usize,
) -> Result<&'a str, ClientError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(ClientError::EmptyField { field });
    }
    if trimmed.len() > max_len {
        return Err(ClientError::FieldTooLong {
            field,
            len: trimmed.len(),
            max: max_len,
        });
    }
    if trimmed.chars().any(|ch| ch.is_ascii_control()) {
        return Err(ClientError::ControlCharacter { field });
    }
    Ok(trimmed)
}

/// Opaque Inline ID used by high-level client events.
///
/// Inline server IDs are represented as signed 64-bit integers across existing
/// clients. This wrapper avoids mixing user, chat, and message IDs with other
/// integers in public event structures while keeping serialization simple.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct InlineId(i64);

impl InlineId {
    /// Creates an Inline ID from its raw wire value.
    pub const fn new(value: i64) -> Self {
        Self(value)
    }

    /// Returns the raw wire value.
    pub const fn get(self) -> i64 {
        self.0
    }
}

impl From<i64> for InlineId {
    fn from(value: i64) -> Self {
        Self::new(value)
    }
}

impl fmt::Display for InlineId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

/// Deterministic random ID attached to an Inline mutation.
///
/// Hosts should derive this from their own durable event or operation ID plus
/// message content so retries after restart remain idempotent.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RandomId(i64);

impl RandomId {
    /// Creates a random ID wrapper from a caller-provided deterministic value.
    pub const fn new(value: i64) -> Self {
        Self(value)
    }

    /// Returns the raw random ID.
    pub const fn get(self) -> i64 {
        self.0
    }
}

impl From<i64> for RandomId {
    fn from(value: i64) -> Self {
        Self::new(value)
    }
}

impl fmt::Display for RandomId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

/// Opaque host-provided ID used for idempotency and echo reconciliation.
///
/// Hosts can use their own source namespaces, such as `host-event` or
/// `agent-task`. The core client treats this as metadata and does not depend on
/// host-specific semantics.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ExternalId {
    source: String,
    id: String,
}

impl ExternalId {
    /// Maximum source namespace length in bytes.
    pub const MAX_SOURCE_LEN: usize = 64;

    /// Maximum external ID length in bytes.
    pub const MAX_ID_LEN: usize = 512;

    /// Creates a validated external ID.
    pub fn try_new(source: impl AsRef<str>, id: impl AsRef<str>) -> Result<Self, ClientError> {
        let source = validate_token("source", source.as_ref(), Self::MAX_SOURCE_LEN)?;
        let id = validate_token("id", id.as_ref(), Self::MAX_ID_LEN)?;
        Ok(Self {
            source: source.to_owned(),
            id: id.to_owned(),
        })
    }

    /// Returns the source namespace.
    pub fn source(&self) -> &str {
        &self.source
    }

    /// Returns the source-local external ID.
    pub fn id(&self) -> &str {
        &self.id
    }
}

/// Stable client transaction ID.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct TransactionId(String);

impl TransactionId {
    /// Maximum transaction ID length in bytes.
    pub const MAX_LEN: usize = 128;

    /// Creates a validated transaction ID.
    pub fn try_new(value: impl AsRef<str>) -> Result<Self, ClientError> {
        Ok(Self(
            validate_token("transaction_id", value.as_ref(), Self::MAX_LEN)?.to_owned(),
        ))
    }

    /// Returns the transaction ID string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for TransactionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl FromStr for TransactionId {
    type Err = ClientError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::try_new(value)
    }
}

/// Identity data used to reconcile a mutation across host, client, and server.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TransactionIdentity {
    /// Stable client transaction ID.
    pub transaction_id: TransactionId,
    /// Optional host-provided idempotency key.
    pub external_id: Option<ExternalId>,
    /// Inline mutation random ID.
    pub random_id: RandomId,
    /// Temporary local message ID, when the mutation created one.
    pub temporary_message_id: Option<InlineId>,
    /// Final server message ID, when known.
    pub final_message_id: Option<InlineId>,
}

impl TransactionIdentity {
    /// Creates a transaction identity before a temporary or final message ID is known.
    pub fn new(
        transaction_id: TransactionId,
        external_id: Option<ExternalId>,
        random_id: RandomId,
    ) -> Self {
        Self {
            transaction_id,
            external_id,
            random_id,
            temporary_message_id: None,
            final_message_id: None,
        }
    }

    /// Records the temporary message ID assigned by optimistic local state.
    pub fn with_temporary_message_id(mut self, message_id: impl Into<InlineId>) -> Self {
        self.temporary_message_id = Some(message_id.into());
        self
    }

    /// Records the final server message ID.
    pub fn with_final_message_id(mut self, message_id: impl Into<InlineId>) -> Self {
        self.final_message_id = Some(message_id.into());
        self
    }
}

/// High-level connection/auth state for apps, bridges, and agents.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[non_exhaustive]
pub enum ClientStatus {
    /// Client is not connected.
    Disconnected,
    /// Client is establishing a session.
    Connecting,
    /// Client is connected and able to send/receive realtime updates.
    Connected,
    /// Client lost realtime connectivity and is retrying.
    Reconnecting,
    /// Client needs interactive auth before it can connect.
    AuthRequired,
    /// Client credentials expired and a relogin or refresh is required.
    AuthExpired,
    /// The account was logged out or invalidated elsewhere.
    LoggedOut,
    /// The client is shutting down.
    ShuttingDown,
}

/// Stable error categories exposed to client hosts.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[non_exhaustive]
pub enum ClientErrorCategory {
    /// Caller supplied invalid input.
    InvalidInput,
    /// Authentication is missing.
    AuthRequired,
    /// Authentication expired and must be refreshed.
    AuthExpired,
    /// The user must relogin interactively.
    ReloginRequired,
    /// Network connectivity failed.
    Network,
    /// Operation timed out.
    Timeout,
    /// Remote server rate limited the operation.
    RateLimited,
    /// Local and remote protocol versions are incompatible.
    ProtocolMismatch,
    /// The target entity was not found.
    NotFound,
    /// The account does not have permission for the operation.
    PermissionDenied,
    /// The operation is unsupported by the current client or server.
    Unsupported,
    /// The operation conflicted with newer state.
    Conflict,
    /// An internal client error occurred.
    Internal,
}

/// Redacted failure value suitable for status endpoints and bridge errors.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClientFailure {
    /// Machine-readable category.
    pub category: ClientErrorCategory,
    /// Human-readable message with secrets and message bodies redacted.
    pub message: String,
}

impl ClientFailure {
    /// Creates a redacted failure.
    pub fn new(category: ClientErrorCategory, message: impl Into<String>) -> Self {
        Self {
            category,
            message: message.into(),
        }
    }
}

/// State of a durable client transaction.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[non_exhaustive]
pub enum TransactionState {
    /// Transaction is queued locally.
    Queued,
    /// Transaction was sent to the realtime or API transport.
    Sent,
    /// Transport acknowledged receipt, but final server result is not known.
    Acked,
    /// Server result completed and final state was applied.
    Completed,
    /// Transaction failed permanently or exhausted retries.
    Failed,
    /// Transaction was cancelled locally.
    Cancelled,
}

/// Transaction event emitted after client state changes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TransactionEvent {
    /// Mutation identity and reconciliation IDs.
    pub identity: TransactionIdentity,
    /// Current transaction state.
    pub state: TransactionState,
    /// Redacted failure, present for failed transactions.
    pub failure: Option<ClientFailure>,
}

/// Reliability class for events delivered to hosts.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum EventReliability {
    /// Event must be delivered or recovered from durable state.
    Lossless,
    /// Event may be dropped under backpressure.
    BestEffort,
}

/// Committed client event for apps, bridges, agents, and hosts.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[non_exhaustive]
pub enum ClientEvent {
    /// Connection/auth status changed.
    StatusChanged {
        /// New client status.
        status: ClientStatus,
        /// Optional redacted failure details.
        failure: Option<ClientFailure>,
    },
    /// A durable transaction changed state.
    TransactionChanged(TransactionEvent),
    /// A chat was inserted or updated in the local store.
    ChatUpserted {
        /// Inline chat ID.
        chat_id: InlineId,
    },
    /// A chat was deleted from durable client state.
    ChatDeleted {
        /// Inline chat ID.
        chat_id: InlineId,
    },
    /// The participant snapshot for a chat changed.
    ChatParticipantsChanged {
        /// Inline chat ID.
        chat_id: InlineId,
    },
    /// A user was inserted or updated in the local store.
    UserUpserted {
        /// Inline user ID.
        user_id: InlineId,
    },
    /// A space was inserted or updated in durable client state.
    SpaceUpserted {
        /// Inline space ID.
        space_id: InlineId,
    },
    /// Durable membership for a space changed.
    SpaceMemberChanged {
        /// Inline space ID.
        space_id: InlineId,
        /// Inline user ID.
        user_id: InlineId,
        /// Whether the member was removed.
        removed: bool,
    },
    /// Durable global user settings changed.
    UserSettingsChanged {},
    /// A bot message action was invoked and requires lossless host handling.
    MessageActionInvoked {
        /// Server interaction ID.
        interaction_id: InlineId,
        /// Chat containing the action.
        chat_id: InlineId,
        /// Message containing the action.
        message_id: InlineId,
        /// User who invoked the action.
        actor_user_id: InlineId,
        /// Bot-defined action ID.
        action_id: String,
        /// Opaque bot-defined payload.
        data: Vec<u8>,
    },
    /// A previously invoked message action received a UI response.
    MessageActionAnswered {
        /// Server interaction ID.
        interaction_id: InlineId,
        /// Optional toast text supplied by the bot.
        toast: Option<String>,
    },
    /// A message was inserted or updated in the local store.
    MessageUpserted {
        /// Inline chat ID.
        chat_id: InlineId,
        /// Inline message ID.
        message_id: InlineId,
    },
    /// A message was inserted or updated and the committed record is available.
    MessageStored {
        /// Committed message record.
        message: MessageRecord,
    },
    /// A message was deleted or unsent.
    MessageDeleted {
        /// Inline chat ID.
        chat_id: InlineId,
        /// Inline message ID.
        message_id: InlineId,
    },
    /// Stored history was cleared for a chat, optionally before a timestamp.
    ChatHistoryCleared {
        /// Inline chat ID.
        chat_id: InlineId,
        /// Unix timestamp cutoff; `None` means all history.
        before_date: Option<i64>,
    },
    /// Reactions for a message changed.
    ReactionChanged {
        /// Inline chat ID.
        chat_id: InlineId,
        /// Inline message ID.
        message_id: InlineId,
        /// Inline user ID that changed the reaction.
        user_id: InlineId,
        /// Reaction emoji.
        reaction: String,
        /// Whether the reaction was removed.
        removed: bool,
    },
    /// Read state changed for a chat.
    ReadStateChanged {
        /// Inline chat ID.
        chat_id: InlineId,
    },
    /// Typing state changed.
    Typing {
        /// Inline chat ID.
        chat_id: InlineId,
        /// Inline user ID.
        user_id: InlineId,
        /// Whether the user is typing.
        is_typing: bool,
    },
    /// Transient user presence changed.
    UserStatusChanged {
        /// Inline user ID.
        user_id: InlineId,
        /// `Some(true)` for online, `Some(false)` for offline, or `None` when hidden/unknown.
        is_online: Option<bool>,
        /// Last-online Unix timestamp, when disclosed.
        last_online: Option<i64>,
    },
    /// Transient bot activity/presence changed for a peer.
    BotPresenceChanged {
        /// Inline bot user ID.
        bot_user_id: InlineId,
        /// Resolved chat ID, when available.
        chat_id: Option<InlineId>,
        /// Stable protobuf presence kind name.
        kind: String,
        /// Optional bot-supplied status comment.
        comment: Option<String>,
        /// Whether the bot avatar changed.
        avatar_changed: bool,
    },
    /// A notification-class message update was received.
    NewMessageNotification {
        /// Message referenced by the notification.
        message: MessageRecord,
        /// Stable protobuf notification reason name.
        reason: String,
    },
}

impl ClientEvent {
    /// Returns the event delivery reliability class.
    pub const fn reliability(&self) -> EventReliability {
        match self {
            Self::Typing { .. }
            | Self::UserStatusChanged { .. }
            | Self::BotPresenceChanged { .. }
            | Self::NewMessageNotification { .. } => EventReliability::BestEffort,
            Self::StatusChanged { .. }
            | Self::TransactionChanged(_)
            | Self::ChatUpserted { .. }
            | Self::ChatDeleted { .. }
            | Self::ChatParticipantsChanged { .. }
            | Self::UserUpserted { .. }
            | Self::SpaceUpserted { .. }
            | Self::SpaceMemberChanged { .. }
            | Self::UserSettingsChanged { .. }
            | Self::MessageActionInvoked { .. }
            | Self::MessageActionAnswered { .. }
            | Self::MessageUpserted { .. }
            | Self::MessageStored { .. }
            | Self::MessageDeleted { .. }
            | Self::ChatHistoryCleared { .. }
            | Self::ReactionChanged { .. }
            | Self::ReadStateChanged { .. } => EventReliability::Lossless,
        }
    }
}

/// Convenient imports for common client consumers.
pub mod prelude {
    pub use crate::{
        AddChatParticipantRequest, AuthCredential, AuthToken, BackendError, BackendResult,
        ClientBackend, ClientCommandError, ClientError, ClientErrorCategory, ClientEvent,
        ClientEventDelivery, ClientFailure, ClientIdentity, ClientRequestError, ClientRunner,
        ClientStatus, ClientStore, ConnectRequest, DEFAULT_COMMAND_QUEUE_CAPACITY,
        DEFAULT_EVENT_QUEUE_CAPACITY, DEFAULT_LOSSLESS_EVENT_QUEUE_CAPACITY, DeleteChatRequest,
        DeleteMessageRequest, DialogFollowMode, DialogNotificationMode, DialogRecord, DialogsPage,
        DialogsRequest, EditMessageRequest, EventReliability, ExternalId, FakeRealtimeAttempt,
        FakeRealtimeConnector, HistoryPage, HistoryRequest, InMemoryBackend, InMemoryStore,
        InlineClient, InlineClientBuilder, InlineClientRuntime, InlineId, LosslessEventDelivery,
        LosslessEventReceiver, MessageContent, MessageMutation, MessageRecord, NotificationMode,
        PeerRef, RandomId, ReactRequest, ReadRequest, RealtimeConnectRequest,
        RealtimeConnectionInfo, RealtimeConnector, ReconnectPolicy, RemoveChatParticipantRequest,
        SdkBackend, SdkBackendBuildError, SdkBackendBuilder, SdkRealtimeConnector, SendTextOutcome,
        SendTextRequest, SetMarkedUnreadRequest, SpaceMemberRecord, SpaceMemberRole, SpaceRecord,
        SqliteStore, StoreError, StoreResult, StoredReaction, StoredReadState, StoredSession,
        StoredTransaction, SyncBucketKey, SyncBucketPeer, SyncBucketState, SyncConfig, SyncState,
        TransactionEvent, TransactionId, TransactionIdentity, TransactionState, TypingRequest,
        UpdateChatInfoRequest, UpdateDialogNotificationsRequest, UploadHandle, UploadRequest,
        UserSettingsRecord, VERSION,
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn external_id_rejects_empty_values() {
        assert_eq!(
            ExternalId::try_new("host-event", " "),
            Err(ClientError::EmptyField { field: "id" })
        );
    }

    #[test]
    fn transaction_identity_records_message_ids() {
        let identity = TransactionIdentity::new(
            TransactionId::try_new("txn-1").unwrap(),
            Some(ExternalId::try_new("host-event", "event-1").unwrap()),
            RandomId::new(42),
        )
        .with_temporary_message_id(-1)
        .with_final_message_id(100);

        assert_eq!(identity.random_id.get(), 42);
        assert_eq!(identity.temporary_message_id.unwrap().get(), -1);
        assert_eq!(identity.final_message_id.unwrap().get(), 100);
    }

    #[test]
    fn typing_is_best_effort() {
        let event = ClientEvent::Typing {
            chat_id: InlineId::new(1),
            user_id: InlineId::new(2),
            is_typing: true,
        };

        assert_eq!(event.reliability(), EventReliability::BestEffort);
    }
}
