//! Native Inline client request and record types.
//!
//! These are first-class Inline concepts. Bridge protocol envelopes, HTTP
//! routes, adapter DTOs, and process-management details belong in adapter
//! adapter crates, not in `inline-client`.

use std::fmt;

use serde::{Deserialize, Serialize};

use crate::{
    ClientError, ClientFailure, ClientStatus, ExternalId, InlineId, RandomId, TransactionIdentity,
    TransactionState, validate_token,
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
            .field(
                "account_namespace",
                &self.account_namespace.as_ref().map(|_| "[redacted]"),
            )
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
            .field(
                "account_namespace",
                &self.account_namespace.as_ref().map(|_| "[redacted]"),
            )
            .finish()
    }
}

/// Response from verifying an Inline login code.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthVerifyResult {
    /// Verified Inline user ID.
    pub user_id: InlineId,
    /// Account/store namespace persisted by the client.
    pub account_namespace: String,
    /// Updated client status after persisting the session.
    pub status: ClientStatusSnapshot,
}

impl fmt::Debug for AuthVerifyResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AuthVerifyResult")
            .field("user_id", &self.user_id)
            .field("account_namespace", &"[redacted]")
            .field("status", &self.status)
            .finish()
    }
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

/// Request to add a user to an Inline chat.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AddChatParticipantRequest {
    /// Inline chat ID.
    pub chat_id: InlineId,
    /// Inline user ID to add.
    pub user_id: InlineId,
}

/// Request to remove a user from an Inline chat.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoveChatParticipantRequest {
    /// Inline chat ID.
    pub chat_id: InlineId,
    /// Inline user ID to remove.
    pub user_id: InlineId,
}

/// Request to update mutable Inline chat metadata.
///
/// `None` leaves a field unchanged. An empty emoji clears the current icon.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateChatInfoRequest {
    /// Inline chat ID.
    pub chat_id: InlineId,
    /// Replacement title, when changing it.
    pub title: Option<String>,
    /// Replacement emoji, or an empty string to clear it.
    pub emoji: Option<String>,
}

/// Request to delete an Inline chat when the authenticated user is allowed to.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeleteChatRequest {
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

/// Request to set the explicit marked-unread state for a chat.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SetMarkedUnreadRequest {
    /// Inline chat ID.
    pub chat_id: InlineId,
    /// Whether the chat should be explicitly marked unread.
    pub unread: bool,
}

/// Request to set or clear a per-dialog notification override.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateDialogNotificationsRequest {
    /// Inline chat ID.
    pub chat_id: InlineId,
    /// Explicit mode, or `None` to inherit the account-wide setting.
    pub mode: Option<DialogNotificationMode>,
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
    /// Other user ID when this dialog is a direct message.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer_user_id: Option<InlineId>,
    /// Display title, when known.
    pub title: Option<String>,
    /// Chat emoji/icon, when present.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub emoji: Option<String>,
    /// Last known message ID, when known.
    pub last_message_id: Option<InlineId>,
    /// Highest message ID currently stored by `inline-client`, when known.
    pub synced_through_message_id: Option<InlineId>,
    /// Unread count, when known.
    pub unread_count: Option<u32>,
    /// Parent Inline space ID, when this chat belongs to a space.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub space_id: Option<InlineId>,
    /// Whether the chat is visible to all eligible members of its parent space.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_public: Option<bool>,
    /// Whether the dialog is archived.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archived: Option<bool>,
    /// Whether the dialog is pinned.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned: Option<bool>,
    /// Whether the dialog belongs to the stable sidebar inbox.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub open: Option<bool>,
    /// Whether the dialog is hidden from normal chat lists.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chat_list_hidden: Option<bool>,
    /// Stable fractional normal-list order, when assigned.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub order: Option<String>,
    /// Stable fractional pinned-list order, when assigned.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned_order: Option<String>,
    /// Per-dialog notification override, when present.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notification_mode: Option<DialogNotificationMode>,
    /// Reply-thread follow mode, when present.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub follow_mode: Option<DialogFollowMode>,
    /// Ordered pinned message IDs, newest first.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pinned_message_ids: Vec<InlineId>,
}

impl DialogRecord {
    /// Creates an empty dialog record for a chat ID.
    pub fn new(chat_id: InlineId) -> Self {
        Self {
            chat_id,
            peer_user_id: None,
            title: None,
            emoji: None,
            last_message_id: None,
            synced_through_message_id: None,
            unread_count: None,
            space_id: None,
            is_public: None,
            archived: None,
            pinned: None,
            open: None,
            chat_list_hidden: None,
            order: None,
            pinned_order: None,
            notification_mode: None,
            follow_mode: None,
            pinned_message_ids: Vec::new(),
        }
    }
}

/// Per-dialog notification override.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DialogNotificationMode {
    /// Notify for all messages.
    All,
    /// Notify only for mentions.
    Mentions,
    /// Do not notify for this dialog.
    None,
}

/// Reply-thread automatic surfacing policy.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DialogFollowMode {
    /// Automatically surface activity from this reply thread.
    Following,
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

/// Durable Inline space summary.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpaceRecord {
    /// Inline space ID.
    pub space_id: InlineId,
    /// Space display name.
    pub name: String,
    /// Whether the authenticated user created the space.
    pub creator: bool,
    /// Unix timestamp when the space was created.
    pub date: i64,
    /// Whether this is a public community space.
    pub is_public: Option<bool>,
}

/// Inline space membership role.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SpaceMemberRole {
    /// Space owner.
    Owner,
    /// Space administrator.
    Admin,
    /// Regular space member.
    Member,
}

/// Durable Inline space member state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpaceMemberRecord {
    /// Inline space ID.
    pub space_id: InlineId,
    /// Inline user ID.
    pub user_id: InlineId,
    /// Membership role, when supplied by the server.
    pub role: Option<SpaceMemberRole>,
    /// Unix timestamp when the user joined.
    pub date: i64,
    /// Whether the member may access public chats in this space.
    pub can_access_public_chats: bool,
}

/// Global notification policy.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NotificationMode {
    /// Notify for all messages.
    All,
    /// Disable notifications.
    None,
    /// Notify for mentions.
    Mentions,
    /// Notify only for important messages.
    ImportantOnly,
    /// Notify only for direct mentions.
    OnlyMentions,
}

/// Durable user notification settings relevant to generic clients.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UserSettingsRecord {
    /// Global notification mode, when set.
    pub notification_mode: Option<NotificationMode>,
    /// Whether notification sounds are disabled.
    pub silent: Option<bool>,
    /// Whether zen mode requires a mention.
    pub zen_mode_requires_mention: Option<bool>,
    /// Whether zen mode uses default rules.
    pub zen_mode_uses_default_rules: Option<bool>,
    /// Custom zen-mode rules.
    pub zen_mode_custom_rules: Option<String>,
    /// Whether direct-message notifications are disabled.
    pub disable_dm_notifications: Option<bool>,
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
    /// Durable transaction state after this send attempt.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<TransactionState>,
    /// Redacted terminal or retryable failure details, when present.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure: Option<ClientFailure>,
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
    fn session_namespace_debug_is_redacted() {
        let request = ConnectRequest::new(AuthCredential::AccessToken {
            token: AuthToken::try_new("token").unwrap(),
        })
        .with_account_namespace("secret-namespace");

        let rendered = format!("{request:?}");
        assert!(rendered.contains("[redacted]"));
        assert!(!rendered.contains("secret-namespace"));
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
