//! Native Inline client request and record types.
//!
//! These are first-class Inline concepts. Bridge protocol envelopes, HTTP
//! routes, adapter DTOs, and process-management details belong in adapter
//! adapter crates, not in `inline-client`.

use std::fmt;

use serde::{Deserialize, Serialize};

use crate::{
    ClientError, ClientFailure, ClientStatus, ExternalId, InlineId, RandomId, TransactionIdentity,
    validate_token,
};

/// Secret bearer-style auth token accepted by the client connect command.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct AuthToken(String);

impl AuthToken {
    /// Maximum token length in bytes.
    pub const MAX_LEN: usize = 8192;

    /// Creates a validated auth token.
    pub fn try_new(value: impl AsRef<str>) -> Result<Self, ClientError> {
        Ok(Self(
            validate_token("auth_token", value.as_ref(), Self::MAX_LEN)?.to_owned(),
        ))
    }

    /// Exposes the token for transport/auth code.
    ///
    /// Callers should avoid logging this value.
    pub fn expose_secret(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for AuthToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AuthToken(\"[redacted]\")")
    }
}

/// Credential supplied during client connect.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AuthCredential {
    /// Existing Inline access token.
    AccessToken {
        /// Secret access token.
        token: AuthToken,
    },
}

impl AuthCredential {
    /// Returns the access token for credential types that carry one.
    pub fn access_token(&self) -> &AuthToken {
        match self {
            Self::AccessToken { token } => token,
        }
    }
}

impl fmt::Debug for AuthCredential {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AccessToken { .. } => f
                .debug_struct("AccessToken")
                .field("token", &"[redacted]")
                .finish(),
        }
    }
}

/// Inline peer reference used by client operations.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PeerRef {
    /// Direct-message peer by user ID.
    User {
        /// Inline user ID.
        user_id: InlineId,
    },
    /// Chat peer by chat ID.
    Chat {
        /// Inline chat ID.
        chat_id: InlineId,
    },
    /// Thread peer by thread ID, used by existing Inline APIs that expose threads.
    Thread {
        /// Inline thread ID.
        thread_id: InlineId,
    },
}

/// Request to connect or reconnect the client.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectRequest {
    /// Auth credential.
    pub auth: AuthCredential,
    /// Optional account/store namespace chosen by the host.
    pub account_namespace: Option<String>,
}

impl ConnectRequest {
    /// Creates a connect request.
    pub fn new(auth: AuthCredential) -> Self {
        Self {
            auth,
            account_namespace: None,
        }
    }

    /// Sets the account/store namespace.
    pub fn with_account_namespace(mut self, namespace: impl Into<String>) -> Self {
        self.account_namespace = Some(namespace.into());
        self
    }
}

impl fmt::Debug for ConnectRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConnectRequest")
            .field("auth", &self.auth)
            .field("account_namespace", &self.account_namespace)
            .finish()
    }
}

/// Contact method used for client-owned Inline login.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthContactKind {
    /// Email code login.
    Email,
    /// SMS code login.
    Phone,
}

impl AuthContactKind {
    /// Returns the stable wire string for this contact kind.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Email => "email",
            Self::Phone => "phone",
        }
    }
}

/// Request to send an Inline login code.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthStartRequest {
    /// Contact address or phone number.
    pub contact: String,
    /// Contact kind.
    pub kind: AuthContactKind,
    /// Optional human-readable device name.
    pub device_name: Option<String>,
}

impl fmt::Debug for AuthStartRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AuthStartRequest")
            .field("contact", &"[redacted]")
            .field("kind", &self.kind)
            .field("device_name", &self.device_name)
            .finish()
    }
}

/// Response from sending an Inline login code.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthStartResult {
    /// Whether the contact belongs to an existing user.
    pub existing_user: bool,
    /// Whether the flow needs an invite code before login can continue.
    pub needs_invite_code: bool,
    /// Opaque challenge token required by some email verification flows.
    pub challenge_token: Option<String>,
}

impl fmt::Debug for AuthStartResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AuthStartResult")
            .field("existing_user", &self.existing_user)
            .field("needs_invite_code", &self.needs_invite_code)
            .field(
                "challenge_token",
                &self.challenge_token.as_ref().map(|_| "[redacted]"),
            )
            .finish()
    }
}

/// Request to verify an Inline login code.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthVerifyRequest {
    /// Contact address or phone number used in the start step.
    pub contact: String,
    /// Contact kind.
    pub kind: AuthContactKind,
    /// Verification code from email or SMS.
    pub code: String,
    /// Opaque email challenge token from the start step, when present.
    pub challenge_token: Option<String>,
    /// Optional human-readable device name.
    pub device_name: Option<String>,
    /// Optional account/store namespace chosen by the host.
    pub account_namespace: Option<String>,
}

impl fmt::Debug for AuthVerifyRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AuthVerifyRequest")
            .field("contact", &"[redacted]")
            .field("kind", &self.kind)
            .field("code", &"[redacted]")
            .field(
                "challenge_token",
                &self.challenge_token.as_ref().map(|_| "[redacted]"),
            )
            .field("device_name", &self.device_name)
            .field("account_namespace", &self.account_namespace)
            .finish()
    }
}

/// Response from verifying an Inline login code.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthVerifyResult {
    /// Verified Inline user ID.
    pub user_id: InlineId,
    /// Account/store namespace persisted by the client.
    pub account_namespace: String,
    /// Updated client status after persisting the session.
    pub status: ClientStatusSnapshot,
}

/// Request to list dialogs.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DialogsRequest {
    /// Optional page size.
    pub limit: Option<u32>,
    /// Optional opaque pagination cursor.
    pub cursor: Option<String>,
}

/// Request to fetch chat history.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryRequest {
    /// Inline chat ID.
    pub chat_id: InlineId,
    /// Optional page size.
    pub limit: Option<u32>,
    /// Optional exclusive upper message bound.
    pub before_message_id: Option<InlineId>,
    /// Optional exclusive lower message bound for newer-message startup catch-up.
    pub after_message_id: Option<InlineId>,
}

/// Request to fetch chat participants.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatParticipantsRequest {
    /// Inline chat ID.
    pub chat_id: InlineId,
}

/// User participant supplied when creating an Inline chat.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatCreateParticipant {
    /// Inline user ID.
    pub user_id: InlineId,
}

impl From<InlineId> for ChatCreateParticipant {
    fn from(user_id: InlineId) -> Self {
        Self { user_id }
    }
}

/// Request to create or open a direct message chat.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateDmRequest {
    /// Inline user ID to chat with.
    pub user_id: InlineId,
}

/// Request to create a regular Inline thread chat.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateThreadRequest {
    /// Optional explicit title.
    pub title: Option<String>,
    /// Optional parent space ID.
    pub space_id: Option<InlineId>,
    /// Optional description.
    pub description: Option<String>,
    /// Optional emoji/icon.
    pub emoji: Option<String>,
    /// Whether everyone in the parent space can access the chat.
    pub is_public: bool,
    /// Direct child participants.
    #[serde(default)]
    pub participants: Vec<ChatCreateParticipant>,
}

/// Request to create a child Inline thread, optionally anchored to a message.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateReplyThreadRequest {
    /// Required parent chat for inherited access and navigation.
    pub parent_chat_id: InlineId,
    /// Optional parent message anchor. When set, this is a reply thread.
    pub parent_message_id: Option<InlineId>,
    /// Optional explicit title.
    pub title: Option<String>,
    /// Optional description.
    pub description: Option<String>,
    /// Optional emoji/icon.
    pub emoji: Option<String>,
    /// Direct child participants.
    #[serde(default)]
    pub participants: Vec<ChatCreateParticipant>,
}

/// Request to send a text message.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SendTextRequest {
    /// Target peer.
    pub peer: PeerRef,
    /// Message text.
    pub text: String,
    /// Optional host-provided idempotency key.
    pub external_id: Option<ExternalId>,
    /// Optional deterministic random ID supplied by the host.
    pub random_id: Option<RandomId>,
    /// Optional reply target.
    pub reply_to_message_id: Option<InlineId>,
}

impl SendTextRequest {
    /// Creates a text-send request.
    pub fn new(peer: PeerRef, text: impl Into<String>) -> Self {
        Self {
            peer,
            text: text.into(),
            external_id: None,
            random_id: None,
            reply_to_message_id: None,
        }
    }
}

impl fmt::Debug for SendTextRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SendTextRequest")
            .field("peer", &self.peer)
            .field("text_len", &self.text.len())
            .field("external_id", &self.external_id)
            .field("random_id", &self.random_id)
            .field("reply_to_message_id", &self.reply_to_message_id)
            .finish()
    }
}

/// Request to edit a text message.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditMessageRequest {
    /// Inline chat ID.
    pub chat_id: InlineId,
    /// Inline message ID.
    pub message_id: InlineId,
    /// Replacement message text.
    pub text: String,
    /// Optional host-provided idempotency key.
    pub external_id: Option<ExternalId>,
}

impl fmt::Debug for EditMessageRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EditMessageRequest")
            .field("chat_id", &self.chat_id)
            .field("message_id", &self.message_id)
            .field("text_len", &self.text.len())
            .field("external_id", &self.external_id)
            .finish()
    }
}

/// Request to delete or unsend a message.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeleteMessageRequest {
    /// Inline chat ID.
    pub chat_id: InlineId,
    /// Inline message ID.
    pub message_id: InlineId,
    /// Optional host-provided idempotency key.
    pub external_id: Option<ExternalId>,
}

/// Request to add or remove a reaction.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReactRequest {
    /// Inline chat ID.
    pub chat_id: InlineId,
    /// Inline message ID.
    pub message_id: InlineId,
    /// Reaction key, usually an emoji.
    pub reaction: String,
    /// Whether to remove instead of add the reaction.
    pub remove: bool,
    /// Optional host-provided idempotency key.
    pub external_id: Option<ExternalId>,
}

/// Request to mark messages read.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadRequest {
    /// Inline chat ID.
    pub chat_id: InlineId,
    /// Highest message ID to mark read, when known.
    pub max_message_id: Option<InlineId>,
}

/// Request to set typing state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TypingRequest {
    /// Inline chat ID.
    pub chat_id: InlineId,
    /// Whether the current user is typing.
    pub is_typing: bool,
}

/// Request to upload and send media.
///
/// Raw bytes are intentionally passed as a separate argument to
/// [`crate::InlineClient::send_media`] so paths and transport-specific upload
/// bodies do not become part of the reusable request type.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadRequest {
    /// Target peer.
    pub peer: PeerRef,
    /// Inline media kind requested by the host.
    pub kind: MediaKind,
    /// Optional original file name.
    pub file_name: Option<String>,
    /// Optional MIME type.
    pub mime_type: Option<String>,
    /// Optional content length in bytes.
    pub size_bytes: Option<u64>,
    /// Optional caption.
    pub caption: Option<String>,
    /// Optional media width in pixels.
    pub width: Option<u32>,
    /// Optional media height in pixels.
    pub height: Option<u32>,
    /// Optional media duration in milliseconds.
    pub duration_ms: Option<u64>,
    /// Optional host-provided idempotency key.
    pub external_id: Option<ExternalId>,
    /// Optional deterministic random ID supplied by the host.
    pub random_id: Option<RandomId>,
    /// Optional reply target.
    pub reply_to_message_id: Option<InlineId>,
}

impl fmt::Debug for UploadRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("UploadRequest")
            .field("peer", &self.peer)
            .field("kind", &self.kind)
            .field("file_name", &self.file_name)
            .field("mime_type", &self.mime_type)
            .field("size_bytes", &self.size_bytes)
            .field("caption_len", &self.caption.as_ref().map(String::len))
            .field("width", &self.width)
            .field("height", &self.height)
            .field("duration_ms", &self.duration_ms)
            .field("external_id", &self.external_id)
            .field("random_id", &self.random_id)
            .field("reply_to_message_id", &self.reply_to_message_id)
            .finish()
    }
}

/// Snapshot returned by status APIs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClientStatusSnapshot {
    /// Current client status.
    pub status: ClientStatus,
    /// Optional redacted failure.
    pub failure: Option<ClientFailure>,
}

impl ClientStatusSnapshot {
    /// Creates a status snapshot.
    pub fn current(status: ClientStatus) -> Self {
        Self {
            status,
            failure: None,
        }
    }
}

/// Dialog item returned by the client.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DialogRecord {
    /// Inline chat ID.
    pub chat_id: InlineId,
    /// Display title, when known.
    pub title: Option<String>,
    /// Last known message ID, when known.
    pub last_message_id: Option<InlineId>,
    /// Highest message ID currently stored by `inline-client`, when known.
    pub synced_through_message_id: Option<InlineId>,
    /// Unread count, when known.
    pub unread_count: Option<u32>,
}

/// A page of dialogs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DialogsPage {
    /// Dialogs in display order.
    pub dialogs: Vec<DialogRecord>,
    /// Users referenced by dialogs/messages in this page.
    #[serde(default)]
    pub users: Vec<UserRecord>,
    /// Opaque cursor for the next page.
    pub next_cursor: Option<String>,
}

/// User profile summary returned by the client.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct UserRecord {
    /// Inline user ID.
    pub user_id: InlineId,
    /// Display name suitable for host-visible user profiles.
    pub display_name: Option<String>,
    /// Username, when available.
    pub username: Option<String>,
    /// First name, when available.
    pub first_name: Option<String>,
    /// Last name, when available.
    pub last_name: Option<String>,
    /// Profile/avatar CDN URL, when Inline exposes one.
    pub avatar_url: Option<String>,
    /// Whether this user is a bot.
    pub is_bot: Option<bool>,
}

/// Message content returned by the client.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
#[non_exhaustive]
pub enum MessageContent {
    /// Plain text content.
    Text {
        /// Message text.
        text: String,
    },
    /// Media content represented by an Inline file ID or opaque media handle.
    Media {
        /// Inline media kind.
        kind: MediaKind,
        /// Opaque Inline file/media ID.
        file_id: String,
        /// Download URL, usually an Inline CDN URL.
        url: Option<String>,
        /// Optional MIME type.
        mime_type: Option<String>,
        /// Optional file name.
        file_name: Option<String>,
        /// Optional caption.
        caption: Option<String>,
        /// Optional content length in bytes.
        size_bytes: Option<u64>,
        /// Optional media width in pixels.
        width: Option<u32>,
        /// Optional media height in pixels.
        height: Option<u32>,
        /// Optional media duration in milliseconds.
        duration_ms: Option<u64>,
    },
    /// Unsupported content placeholder.
    Unsupported {
        /// Redacted reason suitable for hosts.
        reason: String,
    },
}

/// Inline media kind exposed by client message descriptors.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum MediaKind {
    /// Photo/image media.
    Photo,
    /// Video media.
    Video,
    /// Document/file media.
    Document,
    /// Voice/audio media.
    Voice,
}

impl fmt::Debug for MessageContent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Text { text } => f
                .debug_struct("Text")
                .field("text_len", &text.len())
                .finish(),
            Self::Media {
                kind,
                file_id,
                url,
                mime_type,
                file_name,
                caption,
                size_bytes,
                width,
                height,
                duration_ms,
            } => f
                .debug_struct("Media")
                .field("kind", kind)
                .field("file_id", file_id)
                .field("has_url", &url.is_some())
                .field("mime_type", mime_type)
                .field("file_name", file_name)
                .field("caption_len", &caption.as_ref().map(String::len))
                .field("size_bytes", size_bytes)
                .field("width", width)
                .field("height", height)
                .field("duration_ms", duration_ms)
                .finish(),
            Self::Unsupported { reason } => f
                .debug_struct("Unsupported")
                .field("reason", reason)
                .finish(),
        }
    }
}

/// Message record returned by history/detail commands.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessageRecord {
    /// Inline chat ID.
    pub chat_id: InlineId,
    /// Inline message ID.
    pub message_id: InlineId,
    /// Sender user ID.
    pub sender_id: InlineId,
    /// Unix timestamp in seconds.
    pub timestamp: i64,
    /// Whether the message was sent by the current user.
    pub is_outgoing: bool,
    /// Message content.
    pub content: MessageContent,
    /// Optional reply target.
    pub reply_to_message_id: Option<InlineId>,
    /// Optional transaction identity for local/pending sends.
    pub transaction: Option<TransactionIdentity>,
}

/// A page of chat history.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryPage {
    /// Messages in chronological order.
    pub messages: Vec<MessageRecord>,
    /// Users referenced by messages in this page, when available.
    #[serde(default)]
    pub users: Vec<UserRecord>,
    /// Whether older history exists.
    pub has_more: bool,
    /// Opaque cursor for the next page, when available.
    pub next_cursor: Option<String>,
}

/// Chat participant returned by the client.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatParticipantRecord {
    /// Inline user ID.
    pub user_id: InlineId,
    /// Unix timestamp in seconds when the participant was added, when known.
    pub date: Option<i64>,
}

/// A chat participant snapshot.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatParticipantsPage {
    /// Users who currently have direct or group-derived access to the chat.
    pub participants: Vec<ChatParticipantRecord>,
    /// User profiles referenced by participants.
    #[serde(default)]
    pub users: Vec<UserRecord>,
}

/// Chat created or opened by the client.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreatedChat {
    /// Inline chat ID.
    pub chat_id: InlineId,
    /// Display title, when known.
    pub title: Option<String>,
    /// Parent chat ID for child/reply threads.
    pub parent_chat_id: Option<InlineId>,
    /// Parent message ID for reply-thread chats.
    pub parent_message_id: Option<InlineId>,
}

/// A message mutation acknowledgement.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessageMutation {
    /// Transaction identity for reconciliation.
    pub transaction: TransactionIdentity,
    /// Final message ID, when already known.
    pub message_id: Option<InlineId>,
}

/// Uploaded file/media handle returned by the client.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadHandle {
    /// Opaque Inline file/media ID.
    pub file_id: String,
    /// Optional MIME type.
    pub mime_type: Option<String>,
    /// Optional content length in bytes.
    pub size_bytes: Option<u64>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{TransactionId, TransactionIdentity};

    #[test]
    fn auth_token_debug_is_redacted() {
        let token = AuthToken::try_new("secret-token").unwrap();

        assert_eq!(format!("{token:?}"), "AuthToken(\"[redacted]\")");
        assert_eq!(token.expose_secret(), "secret-token");
    }

    #[test]
    fn send_text_debug_redacts_body() {
        let req = SendTextRequest::new(
            PeerRef::User {
                user_id: InlineId::new(42),
            },
            "hello private world",
        );
        let rendered = format!("{req:?}");

        assert!(rendered.contains("text_len"));
        assert!(!rendered.contains("hello private world"));
    }

    #[test]
    fn history_page_redacts_message_text_in_debug() {
        let message = MessageRecord {
            chat_id: InlineId::new(1),
            message_id: InlineId::new(2),
            sender_id: InlineId::new(3),
            timestamp: 1_783_452_698,
            is_outgoing: false,
            content: MessageContent::Text {
                text: "private message".to_owned(),
            },
            reply_to_message_id: None,
            transaction: Some(TransactionIdentity::new(
                TransactionId::try_new("txn-1").unwrap(),
                None,
                RandomId::new(1),
            )),
        };
        let rendered = format!("{message:?}");

        assert!(rendered.contains("text_len"));
        assert!(!rendered.contains("private message"));
    }
}
