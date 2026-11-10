//! Network-neutral vocabulary shared by the relay engine, connectors, and the
//! Inline side.

use std::fmt;
use std::future::Future;
use std::pin::Pin;

/// Boxed future used by the relay's object-safe traits.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Who wrote a message on the remote network.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Speaker {
    /// The hosted agent (for example the ChatGPT Dot).
    Agent,
    /// The owner, writing in the remote app itself or through this relay.
    Owner,
    /// The network itself (joins, setting changes, notices).
    System,
}

/// A file attached to a remote message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteFile {
    /// Stable per-attachment key, unique within its message.
    pub key: String,
    /// Connector-specific locator (for Dots: the file id).
    pub locator: String,
    /// Original name, when known.
    pub name: Option<String>,
}

/// State of a confirmation request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ConfirmationStatus {
    /// Waiting for an answer.
    Pending,
    /// No longer answerable; carries the remote status.
    Closed(String),
}

/// A yes/no request from the agent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Confirmation {
    /// Identifies this exact request definition; a changed definition gets a
    /// new key, so a stale button can never approve something else.
    pub key: String,
    /// Card title.
    pub title: Option<String>,
    /// Prompt.
    pub message: String,
    /// Label/value rows.
    pub fields: Vec<(String, String)>,
    /// Whether a button answer is faithful to the request. When false the
    /// owner is sent to the remote app.
    pub answerable: bool,
    /// Current status.
    pub status: ConfirmationStatus,
}

/// A remote message snapshot. Connectors send a snapshot whenever anything
/// the relay renders may have changed; the relay compares `revision`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteMessage {
    /// Remote id.
    pub id: String,
    /// Author.
    pub speaker: Speaker,
    /// Correlation id echoed for messages this relay sent.
    pub client_request_id: Option<String>,
    /// Text (Markdown).
    pub text: String,
    /// Files.
    pub files: Vec<RemoteFile>,
    /// Parent message id.
    pub reply_to: Option<String>,
    /// Deleted remotely.
    pub deleted: bool,
    /// The agent's reaction on this message, if any.
    pub agent_reaction: Option<String>,
    /// The owner's reaction on this message, if any (set in the remote app or
    /// through this relay).
    pub owner_reaction: Option<String>,
    /// Linked long-running task.
    pub task_id: Option<String>,
    /// Confirmation request carried by this message.
    pub confirmation: Option<Confirmation>,
    /// Changes whenever rendered content changes.
    pub revision: String,
}

/// Progress of a long-running remote task, rendered as a card edited in place.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TaskUpdate {
    /// Task id.
    pub id: String,
    /// Title.
    pub title: Option<String>,
    /// Status label.
    pub label: String,
    /// No further updates expected.
    pub terminal: bool,
    /// Transcript entries known so far, oldest first. The relay posts each
    /// new entry once as a reply under the task card.
    pub entries: Vec<TaskEntry>,
}

/// One prompt or answer inside a task.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TaskEntry {
    /// Stable id within the task.
    pub id: String,
    /// `Owner` for prompts, `Agent` for answers.
    pub speaker: Speaker,
    /// Text (Markdown).
    pub text: String,
}

/// The agent's public profile, mirrored onto the bot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentProfile {
    /// Display name.
    pub name: String,
    /// Connector-specific avatar locator; changes when the avatar changes.
    pub avatar: Option<String>,
}

/// Connector health as seen by the relay.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ConnectorHealth {
    /// Connected and syncing.
    Ready,
    /// Working with reduced fidelity (for example polling without realtime).
    Degraded(String),
    /// The owner must sign in again; the relay keeps the Inline side up.
    NeedsLogin(String),
}

/// Events a connector emits while running.
// Messages dominate the stream; boxing them would allocate per event for no gain.
#[allow(clippy::large_enum_variant)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ConnectorEvent {
    /// New or changed message.
    Message(RemoteMessage),
    /// Task progress.
    Task(TaskUpdate),
    /// The agent is (or stopped) typing.
    Typing(bool),
    /// The agent has read everything up to and including this remote message.
    ReadUpTo(String),
    /// The agent's name or avatar (may be unchanged; the relay compares).
    Profile(AgentProfile),
    /// Opaque connector state. The relay persists it only after every event
    /// sent before it was applied, and passes it back on restart.
    Checkpoint(String),
    /// Health change.
    Health(ConnectorHealth),
}

/// File bytes moving through the relay.
#[derive(Clone, PartialEq, Eq)]
pub struct FileData {
    /// File name.
    pub name: String,
    /// MIME type.
    pub mime: String,
    /// Content.
    pub bytes: Vec<u8>,
}

impl fmt::Debug for FileData {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("FileData")
            .field("mime", &self.mime)
            .field("len", &self.bytes.len())
            .finish_non_exhaustive()
    }
}

/// Message the relay sends to the remote network.
#[derive(Clone, Debug)]
pub struct OutboundMessage {
    /// Stable correlation id; identical across retries of the same message.
    pub request_id: String,
    /// Text or caption.
    pub text: String,
    /// One file, optional.
    pub file: Option<FileData>,
    /// Remote parent id.
    pub reply_to: Option<String>,
}

/// Result of answering a confirmation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ConfirmationAnswer {
    /// The remote applied the answer.
    Applied,
    /// The request was no longer answerable; carries the reason.
    NotApplied(String),
}

/// What a connector supports. The relay degrades gracefully for anything
/// missing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Capabilities {
    /// Owner reactions can be sent.
    pub reactions: bool,
    /// Files can be sent.
    pub send_files: bool,
    /// Largest file accepted in either direction.
    pub max_file_bytes: usize,
    /// Edits made in Inline can be sent.
    pub edits: bool,
}

/// How certain a failure is about delivery.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FailureKind {
    /// Certainly not delivered; do not retry.
    Rejected,
    /// May or may not have been delivered; reconcile, then retry.
    Uncertain,
    /// Not delivered; retry later.
    Transient,
    /// Not delivered; the owner must sign in again.
    NeedsLogin,
    /// Not delivered; the network is not serving this conversation from
    /// where the bridge runs (for example a region or VPN location without
    /// the product). Keep waiting without a give-up limit.
    Unavailable,
}

/// Connector failure. Messages must be safe to show the owner and to log.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConnectorError {
    /// Classification.
    pub kind: FailureKind,
    /// Safe description.
    pub message: String,
}

impl ConnectorError {
    /// Builds an error.
    pub fn new(kind: FailureKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
}

impl fmt::Display for ConnectorError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ConnectorError {}

/// Result alias for connector calls.
pub type ConnectorResult<T> = Result<T, ConnectorError>;

/// One remote network. Implementations own auth, discovery, wire formats,
/// realtime, and polling; they know nothing about Inline.
pub trait Connector: Send + Sync + 'static {
    /// What the network supports.
    fn capabilities(&self) -> Capabilities;

    /// Syncs until a fatal error. `checkpoint` is the last persisted
    /// [`ConnectorEvent::Checkpoint`]; `None` means first link, and the
    /// connector must not replay history from before that point. Returns
    /// when `events` is closed.
    fn run<'a>(
        &'a self,
        checkpoint: Option<String>,
        events: tokio::sync::mpsc::Sender<ConnectorEvent>,
    ) -> BoxFuture<'a, ConnectorResult<()>>;

    /// Sends a message; returns the remote id.
    fn send<'a>(&'a self, message: &'a OutboundMessage) -> BoxFuture<'a, ConnectorResult<String>>;

    /// Looks for a message sent earlier with `request_id` whose delivery was
    /// uncertain. Returns its remote id when found.
    fn find_sent<'a>(
        &'a self,
        request_id: &'a str,
        reply_to: Option<&'a str>,
    ) -> BoxFuture<'a, ConnectorResult<Option<String>>>;

    /// Sets (`Some`) or clears (`None`) the owner's reaction.
    fn set_reaction<'a>(
        &'a self,
        message_id: &'a str,
        emoji: Option<&'a str>,
    ) -> BoxFuture<'a, ConnectorResult<()>>;

    /// Downloads a remote file. `Ok(None)` means it is permanently gone.
    fn fetch_file<'a>(
        &'a self,
        message_id: &'a str,
        file: &'a RemoteFile,
    ) -> BoxFuture<'a, ConnectorResult<Option<FileData>>>;

    /// Answers a confirmation. Implementations must never resend an answer.
    fn answer_confirmation<'a>(
        &'a self,
        message_id: &'a str,
        key: &'a str,
        accept: bool,
    ) -> BoxFuture<'a, ConnectorResult<ConfirmationAnswer>>;

    /// A short status line for `/status`.
    fn describe(&self) -> BoxFuture<'_, String>;

    /// Tells the remote the owner is typing. Default: unsupported, no-op.
    fn owner_typing(&self) -> BoxFuture<'_, ConnectorResult<()>> {
        Box::pin(async { Ok(()) })
    }

    /// Marks the remote conversation read up to a message. Default: no-op.
    fn mark_read<'a>(&'a self, _message_id: &'a str) -> BoxFuture<'a, ConnectorResult<()>> {
        Box::pin(async { Ok(()) })
    }

    /// Downloads the avatar named by [`AgentProfile::avatar`]. Default: none.
    fn fetch_avatar<'a>(
        &'a self,
        _locator: &'a str,
    ) -> BoxFuture<'a, ConnectorResult<Option<FileData>>> {
        Box::pin(async { Ok(None) })
    }
}

/// A button on an Inline message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Button {
    /// Action id.
    pub id: String,
    /// Label.
    pub label: String,
    /// Callback payload.
    pub data: Vec<u8>,
}

/// A message the relay posts in the owner DM.
#[derive(Clone, Debug)]
pub struct InlinePost {
    /// Markdown text, or caption.
    pub text: String,
    /// Inline parent message.
    pub reply_to: Option<i64>,
    /// Stable key; the Inline side derives its idempotency ids from it so a
    /// retried post after a crash does not duplicate.
    pub key: String,
    /// One file, optional.
    pub file: Option<FileData>,
    /// Button rows.
    pub buttons: Vec<Vec<Button>>,
    /// Deliver without a notification.
    pub silent: bool,
    /// Post from the owner's own account instead of the bot's, so something
    /// the owner wrote on the other network appears as theirs.
    pub as_owner: bool,
}

/// Inline media reference on an inbound message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InlineMedia {
    /// Download URL.
    pub url: Option<String>,
    /// File name.
    pub name: Option<String>,
    /// MIME type.
    pub mime: Option<String>,
    /// Size, when known.
    pub size: Option<u64>,
}

/// Inline failure. The text is safe to log.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InlineError(pub String);

impl fmt::Display for InlineError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for InlineError {}

/// Result alias for Inline side calls.
pub type InlineResult<T> = Result<T, InlineError>;

/// The bot's side of the owner DM. The CLI implements it on `inline-client`;
/// tests use an in-memory fake.
pub trait InlineSide: Send + Sync + 'static {
    /// Posts a message; returns its id.
    fn post<'a>(&'a self, post: &'a InlinePost) -> BoxFuture<'a, InlineResult<i64>>;
    /// Replaces a message's text. `buttons: None` is a plain text edit;
    /// `Some(rows)` also replaces the buttons (empty rows clear them).
    fn edit<'a>(
        &'a self,
        message_id: i64,
        text: &'a str,
        buttons: Option<&'a [Vec<Button>]>,
    ) -> BoxFuture<'a, InlineResult<()>>;
    /// Adds or removes the bot's reaction.
    fn react<'a>(
        &'a self,
        message_id: i64,
        emoji: &'a str,
        remove: bool,
    ) -> BoxFuture<'a, InlineResult<()>>;
    /// Edits a message the owner's account posted (see [`InlinePost::as_owner`]).
    fn edit_as_owner<'a>(
        &'a self,
        message_id: i64,
        text: &'a str,
    ) -> BoxFuture<'a, InlineResult<()>>;
    /// Adds or removes the owner's own reaction.
    fn react_as_owner<'a>(
        &'a self,
        message_id: i64,
        emoji: &'a str,
        remove: bool,
    ) -> BoxFuture<'a, InlineResult<()>>;
    /// Shows or clears the bot's typing indicator.
    fn typing(&self, active: bool) -> BoxFuture<'_, InlineResult<()>>;
    /// Answers a button click with an optional toast.
    fn answer_action<'a>(
        &'a self,
        interaction_id: i64,
        toast: Option<&'a str>,
    ) -> BoxFuture<'a, InlineResult<()>>;
    /// Marks the DM read (by the bot) up to a message, so the owner sees the
    /// agent has read it.
    fn mark_read(&self, message_id: i64) -> BoxFuture<'_, InlineResult<()>>;
    /// Updates the bot's name and/or photo.
    fn update_profile<'a>(
        &'a self,
        name: Option<&'a str>,
        avatar: Option<&'a FileData>,
    ) -> BoxFuture<'a, InlineResult<()>>;
    /// Downloads inbound media, refusing anything over `limit` bytes.
    fn fetch_media<'a>(
        &'a self,
        media: &'a InlineMedia,
        limit: usize,
    ) -> BoxFuture<'a, InlineResult<FileData>>;
}

/// Something that happened in the owner DM.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InlineEvent {
    /// A message. The same id may arrive again (redelivery or edit); the
    /// relay acts on each id once.
    Message {
        /// Inline message id.
        message_id: i64,
        /// Sender.
        sender_id: i64,
        /// Text or caption.
        text: String,
        /// Parent.
        reply_to: Option<i64>,
        /// Attached media.
        media: Option<InlineMedia>,
        /// The message carries an edit.
        edited: bool,
    },
    /// The owner sent something the relay cannot represent (a poll, a
    /// sticker, a new kind of content).
    Unsupported {
        /// Inline message id.
        message_id: i64,
        /// Sender.
        sender_id: i64,
    },
    /// A message was deleted.
    Deleted {
        /// Inline message id.
        message_id: i64,
    },
    /// Someone in the DM started or stopped typing.
    Typing {
        /// Typist.
        user_id: i64,
        /// Typing state.
        active: bool,
    },
    /// Reaction added or removed.
    Reaction {
        /// Target message.
        message_id: i64,
        /// Reactor.
        user_id: i64,
        /// Emoji.
        emoji: String,
        /// Removed instead of added.
        removed: bool,
    },
    /// Button click.
    Action {
        /// Interaction to answer.
        interaction_id: i64,
        /// Message carrying the button.
        message_id: i64,
        /// Clicker.
        actor_id: i64,
        /// Callback payload.
        data: Vec<u8>,
    },
}
