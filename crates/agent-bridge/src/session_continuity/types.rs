//! Bounded, provider-scoped values shared by catalog and live-session adapters.

use std::fmt;

use serde::{Deserialize, Deserializer, Serialize};
use thiserror::Error;

use crate::{
    DirectionId, DriverCapabilities, InstallationId, ProviderId, ProviderSessionId,
    SteeringSupport, TurnId, WorkspaceId,
};

pub const DEFAULT_SESSION_PAGE_SIZE: usize = 20;
pub const MAX_SESSION_PAGE_SIZE: usize = 100;
pub const DEFAULT_HISTORY_MESSAGE_LIMIT: usize = 20;
pub const MAX_HISTORY_MESSAGE_LIMIT: usize = 100;
pub const DEFAULT_HISTORY_TEXT_BYTES: usize = 128 * 1024;
pub const MAX_HISTORY_TEXT_BYTES: usize = 512 * 1024;
pub const MAX_SESSION_ITEM_KEY_BYTES: usize = 512;
pub const MAX_SESSION_CURSOR_BYTES: usize = 4 * 1024;
pub const MAX_SESSION_ATTACHMENT_ID_BYTES: usize = 256;
pub const MAX_SESSION_TITLE_CHARS: usize = 240;
pub const MAX_SESSION_PREVIEW_CHARS: usize = 512;
pub const MAX_SESSION_ITEM_TEXT_BYTES: usize = 64 * 1024;
pub const MAX_SESSION_SNAPSHOT_ITEMS: usize = 256;
pub const MAX_INSTALLATION_ID_BYTES: usize = 256;
pub const MAX_PROVIDER_ID_BYTES: usize = 128;
pub const MAX_PROVIDER_SESSION_ID_BYTES: usize = 1024;
pub const MAX_SESSION_CONTROL_ID_BYTES: usize = 512;
pub const MAX_SESSION_CONTROL_TEXT_BYTES: usize = 4 * 1024;
pub const MAX_SESSION_CONTROL_OPTIONS: usize = 32;

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum SessionContractError {
    #[error("{kind} must not be empty")]
    EmptyOpaqueValue { kind: &'static str },
    #[error("{kind} exceeds its {max_bytes}-byte limit")]
    OpaqueValueTooLong {
        kind: &'static str,
        max_bytes: usize,
    },
    #[error("{kind} contains control characters")]
    OpaqueValueContainsControl { kind: &'static str },
    #[error("session title must be nonempty, single-line text of at most {max_chars} characters")]
    InvalidTitle { max_chars: usize },
    #[error("session preview must be nonempty text of at most {max_chars} characters")]
    InvalidPreview { max_chars: usize },
    #[error("session page returned more than {max_items} entries")]
    PageTooLarge { max_items: usize },
    #[error("session page contained an entry from another provider or workspace")]
    PageScopeMismatch,
    #[error("session snapshot returned more than {max_items} total items")]
    SnapshotTooManyItems { max_items: usize },
    #[error("session snapshot returned more than {max_messages} visible messages")]
    SnapshotTooManyMessages { max_messages: usize },
    #[error("session item exceeds its {max_bytes}-byte text limit")]
    ItemTextTooLarge { max_bytes: usize },
    #[error("session snapshot exceeds its {max_bytes}-byte text limit")]
    SnapshotTextTooLarge { max_bytes: usize },
    #[error("{kind} is invalid or exceeds its {max_bytes}-byte limit")]
    InvalidProviderIdentity {
        kind: &'static str,
        max_bytes: usize,
    },
    #[error("session control request is invalid or exceeds its bounded contract")]
    InvalidControl,
    #[error("session activity is invalid or exceeds its bounded contract")]
    InvalidActivity,
    #[error("provider session timestamp must be Unix seconds at or after the epoch")]
    InvalidTimestamp,
}

macro_rules! opaque_string {
    ($name:ident, $label:literal, $max_bytes:expr) => {
        #[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            pub fn new(value: impl Into<String>) -> Result<Self, SessionContractError> {
                let value = value.into();
                if value.trim().is_empty() {
                    return Err(SessionContractError::EmptyOpaqueValue { kind: $label });
                }
                if value.len() > $max_bytes {
                    return Err(SessionContractError::OpaqueValueTooLong {
                        kind: $label,
                        max_bytes: $max_bytes,
                    });
                }
                if value.chars().any(char::is_control) {
                    return Err(SessionContractError::OpaqueValueContainsControl { kind: $label });
                }
                Ok(Self(value))
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl fmt::Debug for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(concat!("<", $label, ">"))
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(&self.0)
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: Deserializer<'de>,
            {
                let value = String::deserialize(deserializer)?;
                Self::new(value).map_err(serde::de::Error::custom)
            }
        }
    };
}

opaque_string!(
    SessionItemKey,
    "session item key",
    MAX_SESSION_ITEM_KEY_BYTES
);
opaque_string!(
    SessionCheckpoint,
    "session checkpoint",
    MAX_SESSION_CURSOR_BYTES
);
opaque_string!(
    SessionPageCursor,
    "session page cursor",
    MAX_SESSION_CURSOR_BYTES
);
opaque_string!(
    SessionAttachmentId,
    "session attachment id",
    MAX_SESSION_ATTACHMENT_ID_BYTES
);
opaque_string!(
    SessionControllerEpoch,
    "session controller epoch",
    MAX_SESSION_ATTACHMENT_ID_BYTES
);
opaque_string!(
    SessionInputCorrelation,
    "session input correlation",
    MAX_SESSION_ITEM_KEY_BYTES
);
opaque_string!(
    SessionControlId,
    "session control id",
    MAX_SESSION_CONTROL_ID_BYTES
);

#[derive(Clone, PartialEq, Eq, Hash, Serialize)]
pub struct ProviderInstanceRef {
    installation_id: InstallationId,
    provider_id: ProviderId,
}

impl ProviderInstanceRef {
    pub fn new(
        installation_id: InstallationId,
        provider_id: ProviderId,
    ) -> Result<Self, SessionContractError> {
        validate_provider_identity(
            installation_id.as_str(),
            "installation id",
            MAX_INSTALLATION_ID_BYTES,
        )?;
        validate_provider_identity(provider_id.as_str(), "provider id", MAX_PROVIDER_ID_BYTES)?;
        Ok(Self {
            installation_id,
            provider_id,
        })
    }

    pub fn installation_id(&self) -> &InstallationId {
        &self.installation_id
    }

    pub fn provider_id(&self) -> &ProviderId {
        &self.provider_id
    }
}

impl fmt::Debug for ProviderInstanceRef {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("<provider instance>")
    }
}

#[derive(Clone, PartialEq, Eq, Hash, Serialize)]
pub struct ProviderSessionRef {
    provider: ProviderInstanceRef,
    session_id: ProviderSessionId,
}

impl ProviderSessionRef {
    pub fn new(
        provider: ProviderInstanceRef,
        session_id: ProviderSessionId,
    ) -> Result<Self, SessionContractError> {
        validate_provider_identity(
            session_id.as_str(),
            "provider session id",
            MAX_PROVIDER_SESSION_ID_BYTES,
        )?;
        Ok(Self {
            provider,
            session_id,
        })
    }

    pub fn provider(&self) -> &ProviderInstanceRef {
        &self.provider
    }

    pub fn session_id(&self) -> &ProviderSessionId {
        &self.session_id
    }
}

impl fmt::Debug for ProviderSessionRef {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("<provider session>")
    }
}

fn validate_provider_identity(
    value: &str,
    kind: &'static str,
    max_bytes: usize,
) -> Result<(), SessionContractError> {
    if value.trim().is_empty() || value.len() > max_bytes || value.chars().any(char::is_control) {
        return Err(SessionContractError::InvalidProviderIdentity { kind, max_bytes });
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionAttachmentSupport {
    #[default]
    Unsupported,
    Exclusive,
    SharedLive,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionReplaySupport {
    #[default]
    None,
    Snapshot,
    Cursor,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStreamFidelity {
    #[default]
    CompletedTurns,
    Semantic,
    Token,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogCapabilities {
    pub list: bool,
    pub read: bool,
    pub rename: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionCapabilities {
    pub catalog: CatalogCapabilities,
    pub attachment: SessionAttachmentSupport,
    pub replay: SessionReplaySupport,
    pub stream_fidelity: SessionStreamFidelity,
    pub external_input: bool,
    pub external_surface_interop: bool,
    pub control_replay: SessionControlCapabilities,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionControlCapabilities {
    pub approvals: bool,
    pub questions: bool,
}

impl SessionCapabilities {
    pub fn supports_shared_live_observation(&self) -> bool {
        self.catalog.list
            && self.catalog.read
            && self.attachment == SessionAttachmentSupport::SharedLive
            && self.replay != SessionReplaySupport::None
            && self.stream_fidelity != SessionStreamFidelity::CompletedTurns
            && self.external_input
            && self.external_surface_interop
    }

    pub fn supports_continuation_with(&self, turn: &DriverCapabilities) -> bool {
        let attachment_ready = self.supports_shared_live_observation()
            || (self.catalog.list
                && self.catalog.read
                && self.attachment == SessionAttachmentSupport::Exclusive
                && self.replay != SessionReplaySupport::None
                && self.stream_fidelity != SessionStreamFidelity::CompletedTurns
                && self.external_surface_interop);
        attachment_ready
            && turn.resume_session
            && turn.cancel_turn
            && turn.steering != SteeringSupport::Unsupported
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderHealth {
    ExecutableMissing,
    UnsupportedVersion,
    Unauthenticated,
    DaemonUnavailable,
    RemoteUnpaired,
    WorkspaceUnavailable,
    Ready,
}

impl ProviderHealth {
    pub fn is_ready(self) -> bool {
        self == Self::Ready
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SessionPageSize(usize);

impl SessionPageSize {
    pub fn new(limit: usize) -> Self {
        Self(limit.clamp(1, MAX_SESSION_PAGE_SIZE))
    }

    pub fn get(self) -> usize {
        self.0
    }
}

impl Default for SessionPageSize {
    fn default() -> Self {
        Self(DEFAULT_SESSION_PAGE_SIZE)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HistoryWindow {
    message_limit: usize,
    max_text_bytes: usize,
}

impl HistoryWindow {
    pub fn new(message_limit: usize, max_text_bytes: usize) -> Self {
        Self {
            message_limit: message_limit.clamp(1, MAX_HISTORY_MESSAGE_LIMIT),
            max_text_bytes: max_text_bytes.clamp(1, MAX_HISTORY_TEXT_BYTES),
        }
    }

    pub fn message_limit(self) -> usize {
        self.message_limit
    }

    pub fn max_text_bytes(self) -> usize {
        self.max_text_bytes
    }
}

impl Default for HistoryWindow {
    fn default() -> Self {
        Self::new(DEFAULT_HISTORY_MESSAGE_LIMIT, DEFAULT_HISTORY_TEXT_BYTES)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionAvailability {
    #[default]
    Unknown,
    Available,
    Active,
    ActiveElsewhere,
    Unavailable,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionQuery {
    pub provider: ProviderInstanceRef,
    pub workspace_id: WorkspaceId,
    pub cursor: Option<SessionPageCursor>,
    pub page_size: SessionPageSize,
}

#[derive(Clone, PartialEq, Eq, Serialize)]
pub struct SessionSummary {
    session: ProviderSessionRef,
    workspace_id: WorkspaceId,
    title: Option<String>,
    preview: Option<String>,
    updated_at: Option<i64>,
    availability: SessionAvailability,
}

impl SessionSummary {
    pub fn new(
        session: ProviderSessionRef,
        workspace_id: WorkspaceId,
        title: Option<String>,
        preview: Option<String>,
        updated_at: Option<i64>,
        availability: SessionAvailability,
    ) -> Result<Self, SessionContractError> {
        if updated_at.is_some_and(|timestamp| timestamp < 0) {
            return Err(SessionContractError::InvalidTimestamp);
        }
        Ok(Self {
            session,
            workspace_id,
            title: title.map(normalize_title).transpose()?,
            preview: preview.map(normalize_preview).transpose()?,
            updated_at,
            availability,
        })
    }

    pub fn session(&self) -> &ProviderSessionRef {
        &self.session
    }

    pub fn workspace_id(&self) -> &WorkspaceId {
        &self.workspace_id
    }

    pub fn title(&self) -> Option<&str> {
        self.title.as_deref()
    }

    /// Bounded first-message context for identifying an unnamed session. This
    /// is deliberately distinct from the user-facing provider title.
    pub fn preview(&self) -> Option<&str> {
        self.preview.as_deref()
    }

    /// Provider-reported last update time in Unix seconds.
    pub fn updated_at(&self) -> Option<i64> {
        self.updated_at
    }

    pub fn availability(&self) -> SessionAvailability {
        self.availability
    }
}

impl fmt::Debug for SessionSummary {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SessionSummary")
            .field("session", &self.session)
            .field("workspace_id", &self.workspace_id)
            .field("has_title", &self.title.is_some())
            .field("has_preview", &self.preview.is_some())
            .field("updated_at", &self.updated_at)
            .field("availability", &self.availability)
            .finish()
    }
}

fn normalize_title(title: String) -> Result<String, SessionContractError> {
    let title = title.trim();
    if title.is_empty()
        || title.chars().count() > MAX_SESSION_TITLE_CHARS
        || title.chars().any(char::is_control)
    {
        return Err(SessionContractError::InvalidTitle {
            max_chars: MAX_SESSION_TITLE_CHARS,
        });
    }
    Ok(title.to_owned())
}

fn normalize_preview(preview: String) -> Result<String, SessionContractError> {
    if preview
        .chars()
        .any(|character| character.is_control() && !character.is_whitespace())
    {
        return Err(SessionContractError::InvalidPreview {
            max_chars: MAX_SESSION_PREVIEW_CHARS,
        });
    }
    let preview = preview.split_whitespace().collect::<Vec<_>>().join(" ");
    if preview.is_empty() || preview.chars().count() > MAX_SESSION_PREVIEW_CHARS {
        return Err(SessionContractError::InvalidPreview {
            max_chars: MAX_SESSION_PREVIEW_CHARS,
        });
    }
    Ok(preview)
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SessionPage {
    sessions: Vec<SessionSummary>,
    next_cursor: Option<SessionPageCursor>,
}

impl SessionPage {
    pub fn new(
        query: &SessionQuery,
        sessions: Vec<SessionSummary>,
        next_cursor: Option<SessionPageCursor>,
    ) -> Result<Self, SessionContractError> {
        if sessions.len() > query.page_size.get() {
            return Err(SessionContractError::PageTooLarge {
                max_items: query.page_size.get(),
            });
        }
        if sessions.iter().any(|summary| {
            summary.session.provider != query.provider || summary.workspace_id != query.workspace_id
        }) {
            return Err(SessionContractError::PageScopeMismatch);
        }
        Ok(Self {
            sessions,
            next_cursor,
        })
    }

    pub fn sessions(&self) -> &[SessionSummary] {
        &self.sessions
    }

    pub fn next_cursor(&self) -> Option<&SessionPageCursor> {
        self.next_cursor.as_ref()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SessionItemVersion(u64);

impl SessionItemVersion {
    pub fn new(revision: u64) -> Self {
        Self(revision)
    }

    /// Baseline for a provider snapshot that does not expose native item
    /// revisions. Live adapters for the same provider must derive subsequent
    /// revisions with [`Self::from_stream_sequence`] so a first live delta can
    /// replace the hydrated item deterministically.
    pub fn snapshot_baseline() -> Self {
        Self(0)
    }

    /// Derives a revision from the attachment-local event sequence. Sequence
    /// zero maps above the snapshot baseline; exhaustion is handled by the
    /// caller as a repair boundary rather than silently reusing a revision.
    pub fn from_stream_sequence(sequence: u64) -> Option<Self> {
        sequence.checked_add(1).map(Self)
    }

    pub fn get(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderSurface {
    Cli,
    Desktop,
    Remote,
    #[default]
    Unknown,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SessionEventOrigin(SessionEventOriginKind);

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "source", rename_all = "snake_case")]
enum SessionEventOriginKind {
    ConfirmedInlineEcho {
        direction_id: DirectionId,
        correlation: SessionInputCorrelation,
    },
    Provider {
        surface: ProviderSurface,
    },
}

impl SessionEventOrigin {
    pub fn provider(surface: ProviderSurface) -> Self {
        Self(SessionEventOriginKind::Provider { surface })
    }

    pub fn confirmed_inline_echo(
        direction_id: DirectionId,
        correlation: SessionInputCorrelation,
    ) -> Self {
        Self(SessionEventOriginKind::ConfirmedInlineEcho {
            direction_id,
            correlation,
        })
    }

    pub fn provider_surface(&self) -> Option<ProviderSurface> {
        match &self.0 {
            SessionEventOriginKind::Provider { surface } => Some(*surface),
            SessionEventOriginKind::ConfirmedInlineEcho { .. } => None,
        }
    }

    /// Provider-returned identity proving that an item echoes an Inline input.
    pub fn confirmed_correlation(&self) -> Option<&SessionInputCorrelation> {
        match &self.0 {
            SessionEventOriginKind::ConfirmedInlineEcho { correlation, .. } => Some(correlation),
            SessionEventOriginKind::Provider { .. } => None,
        }
    }

    fn confirmed_direction_id(&self) -> Option<&DirectionId> {
        match &self.0 {
            SessionEventOriginKind::ConfirmedInlineEcho { direction_id, .. } => Some(direction_id),
            SessionEventOriginKind::Provider { .. } => None,
        }
    }
}

impl fmt::Debug for SessionEventOrigin {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.0 {
            SessionEventOriginKind::ConfirmedInlineEcho { .. } => {
                formatter.write_str("ConfirmedInlineEcho(<correlation>)")
            }
            SessionEventOriginKind::Provider { surface } => formatter
                .debug_struct("Provider")
                .field("surface", surface)
                .finish(),
        }
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SessionItemPayload {
    Message {
        role: SessionMessageRole,
        text: String,
        created_at: Option<i64>,
    },
    Activity {
        activity_kind: SessionActivityKind,
        status: SessionActivityStatus,
        title: String,
        detail: Option<String>,
    },
}

impl fmt::Debug for SessionItemPayload {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Message { role, text, .. } => formatter
                .debug_struct("Message")
                .field("role", role)
                .field("text_bytes", &text.len())
                .finish(),
            Self::Activity {
                activity_kind,
                status,
                title,
                detail,
            } => formatter
                .debug_struct("Activity")
                .field("kind", activity_kind)
                .field("status", status)
                .field(
                    "text_bytes",
                    &(title.len() + detail.as_ref().map_or(0, String::len)),
                )
                .finish(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionActivityKind {
    Progress,
    Command,
    Plan,
    FileChange,
    Control,
    Failure,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionActivityStatus {
    Active,
    Waiting,
    Completed,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionMessageRole {
    User,
    Assistant,
    System,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionItem {
    pub key: SessionItemKey,
    pub revision: SessionItemVersion,
    pub run_id: Option<TurnId>,
    pub origin: SessionEventOrigin,
    pub payload: SessionItemPayload,
}

impl fmt::Debug for SessionItem {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SessionItem")
            .field("key", &self.key)
            .field("revision", &self.revision)
            .field("run_id", &self.run_id.as_ref().map(|_| "<run>"))
            .field("origin", &self.origin)
            .field("payload", &self.payload)
            .finish()
    }
}

impl SessionItem {
    pub fn is_visible_message(&self) -> bool {
        matches!(self.payload, SessionItemPayload::Message { .. })
    }

    pub fn confirmed_inline_echo(&self) -> Option<&DirectionId> {
        self.origin.confirmed_direction_id()
    }

    /// Provider-returned correlation for an Inline-authored input, when present.
    pub fn confirmed_inline_correlation(&self) -> Option<&SessionInputCorrelation> {
        self.origin.confirmed_correlation()
    }

    pub(super) fn validate_text(&self) -> Result<usize, SessionContractError> {
        let text_bytes = match &self.payload {
            SessionItemPayload::Message {
                text, created_at, ..
            } => {
                if created_at.is_some_and(|timestamp| timestamp < 0) {
                    return Err(SessionContractError::InvalidTimestamp);
                }
                text.len()
            }
            SessionItemPayload::Activity { title, detail, .. } => {
                if title.trim().is_empty()
                    || title.chars().count() > MAX_SESSION_TITLE_CHARS
                    || title.chars().any(char::is_control)
                    || detail
                        .as_ref()
                        .is_some_and(|detail| detail.chars().any(|character| character == '\0'))
                {
                    return Err(SessionContractError::InvalidActivity);
                }
                title.len() + detail.as_ref().map_or(0, String::len)
            }
        };
        if text_bytes > MAX_SESSION_ITEM_TEXT_BYTES {
            return Err(SessionContractError::ItemTextTooLarge {
                max_bytes: MAX_SESSION_ITEM_TEXT_BYTES,
            });
        }
        Ok(text_bytes)
    }
}

#[derive(Clone, PartialEq, Eq, Serialize)]
pub struct SessionSnapshot {
    session: ProviderSessionRef,
    items: Vec<SessionItem>,
    checkpoint: Option<SessionCheckpoint>,
    has_older: bool,
    truncated_by_bytes: bool,
}

impl SessionSnapshot {
    pub fn new(
        session: ProviderSessionRef,
        items: Vec<SessionItem>,
        checkpoint: Option<SessionCheckpoint>,
        has_older: bool,
        truncated_by_bytes: bool,
        window: HistoryWindow,
    ) -> Result<Self, SessionContractError> {
        if items.len() > MAX_SESSION_SNAPSHOT_ITEMS {
            return Err(SessionContractError::SnapshotTooManyItems {
                max_items: MAX_SESSION_SNAPSHOT_ITEMS,
            });
        }
        let visible_messages = items
            .iter()
            .filter(|item| item.is_visible_message())
            .count();
        if visible_messages > window.message_limit() {
            return Err(SessionContractError::SnapshotTooManyMessages {
                max_messages: window.message_limit(),
            });
        }
        let total_text_bytes = items.iter().try_fold(0usize, |total, item| {
            item.validate_text().and_then(|bytes| {
                total
                    .checked_add(bytes)
                    .ok_or(SessionContractError::SnapshotTextTooLarge {
                        max_bytes: window.max_text_bytes(),
                    })
            })
        })?;
        if total_text_bytes > window.max_text_bytes() {
            return Err(SessionContractError::SnapshotTextTooLarge {
                max_bytes: window.max_text_bytes(),
            });
        }
        Ok(Self {
            session,
            items,
            checkpoint,
            has_older,
            truncated_by_bytes,
        })
    }

    pub fn session(&self) -> &ProviderSessionRef {
        &self.session
    }

    pub fn items(&self) -> &[SessionItem] {
        &self.items
    }

    pub fn checkpoint(&self) -> Option<&SessionCheckpoint> {
        self.checkpoint.as_ref()
    }

    pub fn has_older(&self) -> bool {
        self.has_older
    }

    pub fn truncated_by_bytes(&self) -> bool {
        self.truncated_by_bytes
    }

    pub(super) fn into_parts(
        self,
    ) -> (
        ProviderSessionRef,
        Vec<SessionItem>,
        Option<SessionCheckpoint>,
    ) {
        (self.session, self.items, self.checkpoint)
    }
}

impl fmt::Debug for SessionSnapshot {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SessionSnapshot")
            .field("session", &self.session)
            .field("item_count", &self.items.len())
            .field("checkpoint", &self.checkpoint)
            .field("has_older", &self.has_older)
            .field("truncated_by_bytes", &self.truncated_by_bytes)
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionReadRequest {
    pub session: ProviderSessionRef,
    pub workspace_id: WorkspaceId,
    pub window: HistoryWindow,
}

#[derive(Clone, PartialEq, Eq)]
pub struct RenameSessionRequest {
    session: ProviderSessionRef,
    title: String,
}

impl fmt::Debug for RenameSessionRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RenameSessionRequest")
            .field("session", &self.session)
            .field("title", &"<session title>")
            .finish()
    }
}

impl RenameSessionRequest {
    pub fn new(session: ProviderSessionRef, title: String) -> Result<Self, SessionContractError> {
        Ok(Self {
            session,
            title: normalize_title(title)?,
        })
    }

    pub fn session(&self) -> &ProviderSessionRef {
        &self.session
    }

    pub fn title(&self) -> &str {
        &self.title
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AttachSessionRequest {
    pub session: ProviderSessionRef,
    pub workspace_id: WorkspaceId,
    pub after: Option<SessionCheckpoint>,
    pub history: HistoryWindow,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DetachSessionRequest {
    pub session: ProviderSessionRef,
    pub attachment_id: SessionAttachmentId,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionStreamPosition {
    pub attachment_id: SessionAttachmentId,
    /// Inclusive attachment-local high-water sequence represented by the
    /// snapshot. The first replay/live event must be exactly this value plus
    /// one; adapters translate provider-inclusive/exclusive cursors first.
    pub last_applied_sequence: u64,
    pub checkpoint: Option<SessionCheckpoint>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SessionControlContext {
    pub session: ProviderSessionRef,
    pub attachment_id: SessionAttachmentId,
    pub controller_epoch: SessionControllerEpoch,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SessionControlOption {
    pub id: SessionControlId,
    pub label: String,
}

impl SessionControlOption {
    pub fn new(id: SessionControlId, label: String) -> Result<Self, SessionContractError> {
        validate_control_text(&label)?;
        Ok(Self { id, label })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SessionQuestion {
    pub id: SessionControlId,
    pub prompt: String,
    pub options: Vec<SessionControlOption>,
    pub secret: bool,
}

impl SessionQuestion {
    pub fn new(
        id: SessionControlId,
        prompt: String,
        options: Vec<SessionControlOption>,
        secret: bool,
    ) -> Result<Self, SessionContractError> {
        validate_control_text(&prompt)?;
        if options.len() > MAX_SESSION_CONTROL_OPTIONS {
            return Err(SessionContractError::InvalidControl);
        }
        Ok(Self {
            id,
            prompt,
            options,
            secret,
        })
    }
}

#[derive(Clone, PartialEq, Eq, Serialize)]
pub enum SessionControlRequest {
    Approval {
        context: SessionControlContext,
        request_id: SessionControlId,
        reason: String,
        options: Vec<SessionControlOption>,
    },
    Questions {
        context: SessionControlContext,
        request_id: SessionControlId,
        questions: Vec<SessionQuestion>,
    },
}

impl fmt::Debug for SessionControlRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Approval {
                context, options, ..
            } => formatter
                .debug_struct("Approval")
                .field("context", context)
                .field("option_count", &options.len())
                .finish(),
            Self::Questions {
                context, questions, ..
            } => formatter
                .debug_struct("Questions")
                .field("context", context)
                .field("question_count", &questions.len())
                .finish(),
        }
    }
}

impl SessionControlRequest {
    pub fn approval(
        context: SessionControlContext,
        request_id: SessionControlId,
        reason: String,
        options: Vec<SessionControlOption>,
    ) -> Result<Self, SessionContractError> {
        validate_control_text(&reason)?;
        if options.is_empty() || options.len() > MAX_SESSION_CONTROL_OPTIONS {
            return Err(SessionContractError::InvalidControl);
        }
        Ok(Self::Approval {
            context,
            request_id,
            reason,
            options,
        })
    }

    pub fn questions(
        context: SessionControlContext,
        request_id: SessionControlId,
        questions: Vec<SessionQuestion>,
    ) -> Result<Self, SessionContractError> {
        if questions.is_empty() || questions.len() > MAX_SESSION_CONTROL_OPTIONS {
            return Err(SessionContractError::InvalidControl);
        }
        Ok(Self::Questions {
            context,
            request_id,
            questions,
        })
    }

    pub fn context(&self) -> &SessionControlContext {
        match self {
            Self::Approval { context, .. } | Self::Questions { context, .. } => context,
        }
    }

    pub(super) fn validate(&self) -> Result<(), SessionContractError> {
        match self {
            Self::Approval {
                reason, options, ..
            } => {
                validate_control_text(reason)?;
                if options.is_empty() || options.len() > MAX_SESSION_CONTROL_OPTIONS {
                    return Err(SessionContractError::InvalidControl);
                }
                for option in options {
                    validate_control_text(&option.label)?;
                }
            }
            Self::Questions { questions, .. } => {
                if questions.is_empty() || questions.len() > MAX_SESSION_CONTROL_OPTIONS {
                    return Err(SessionContractError::InvalidControl);
                }
                for question in questions {
                    validate_control_text(&question.prompt)?;
                    if question.options.len() > MAX_SESSION_CONTROL_OPTIONS {
                        return Err(SessionContractError::InvalidControl);
                    }
                    for option in &question.options {
                        validate_control_text(&option.label)?;
                    }
                }
            }
        }
        Ok(())
    }
}

fn validate_control_text(text: &str) -> Result<(), SessionContractError> {
    if text.trim().is_empty()
        || text.len() > MAX_SESSION_CONTROL_TEXT_BYTES
        || text.chars().any(|character| character == '\0')
    {
        return Err(SessionContractError::InvalidControl);
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionRuntimeState {
    Idle,
    Running,
    WaitingForApproval,
    WaitingForAnswer,
    Reconnecting,
    ActiveElsewhere,
    Unavailable,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionEventPayload {
    Item {
        item: Box<SessionItem>,
    },
    StateChanged {
        state: SessionRuntimeState,
    },
    Gap {
        expected_sequence: u64,
        actual_sequence: u64,
    },
    Removed {
        key: SessionItemKey,
        revision: SessionItemVersion,
    },
    ControlRequested {
        request: Box<SessionControlRequest>,
    },
    ControlClosed {
        context: SessionControlContext,
        request_id: SessionControlId,
    },
    Checkpoint,
}

#[derive(Clone, PartialEq, Eq)]
pub struct SessionEvent {
    pub session: ProviderSessionRef,
    pub attachment_id: SessionAttachmentId,
    pub sequence: u64,
    pub checkpoint: Option<SessionCheckpoint>,
    pub payload: SessionEventPayload,
}

impl fmt::Debug for SessionEvent {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let payload = match &self.payload {
            SessionEventPayload::Item { .. } => "item",
            SessionEventPayload::StateChanged { .. } => "state_changed",
            SessionEventPayload::Gap { .. } => "gap",
            SessionEventPayload::Removed { .. } => "removed",
            SessionEventPayload::ControlRequested { .. } => "control_requested",
            SessionEventPayload::ControlClosed { .. } => "control_closed",
            SessionEventPayload::Checkpoint => "checkpoint",
        };
        formatter
            .debug_struct("SessionEvent")
            .field("session", &self.session)
            .field("attachment_id", &self.attachment_id)
            .field("sequence", &self.sequence)
            .field("checkpoint", &self.checkpoint)
            .field("payload", &payload)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn provider(provider_id: &str) -> ProviderInstanceRef {
        ProviderInstanceRef::new(
            InstallationId::new("install-1").expect("installation"),
            ProviderId::new(provider_id).expect("provider"),
        )
        .expect("provider instance")
    }

    fn session(provider_id: &str, session_id: &str) -> ProviderSessionRef {
        ProviderSessionRef::new(
            provider(provider_id),
            ProviderSessionId::new(session_id).expect("session"),
        )
        .expect("provider session")
    }

    fn workspace() -> WorkspaceId {
        WorkspaceId::new("workspace-1").expect("workspace")
    }

    fn summary(provider_id: &str, session_id: &str) -> SessionSummary {
        SessionSummary::new(
            session(provider_id, session_id),
            workspace(),
            Some("Fix sync".to_owned()),
            Some("Inspect the sync failure".to_owned()),
            Some(1_777_000_000),
            SessionAvailability::Available,
        )
        .expect("summary")
    }

    fn message(text: String) -> SessionItem {
        SessionItem {
            key: SessionItemKey::new("message-1").expect("key"),
            revision: SessionItemVersion::new(1),
            run_id: None,
            origin: SessionEventOrigin::provider(ProviderSurface::Remote),
            payload: SessionItemPayload::Message {
                role: SessionMessageRole::Assistant,
                text,
                created_at: None,
            },
        }
    }

    #[test]
    fn bounded_inputs_clamp_at_both_edges() {
        assert_eq!(SessionPageSize::new(0).get(), 1);
        assert_eq!(
            SessionPageSize::new(usize::MAX).get(),
            MAX_SESSION_PAGE_SIZE
        );
        let window = HistoryWindow::new(usize::MAX, usize::MAX);
        assert_eq!(window.message_limit(), MAX_HISTORY_MESSAGE_LIMIT);
        assert_eq!(window.max_text_bytes(), MAX_HISTORY_TEXT_BYTES);
        assert!(
            SessionItemVersion::from_stream_sequence(0)
                > Some(SessionItemVersion::snapshot_baseline())
        );
        assert_eq!(SessionItemVersion::from_stream_sequence(u64::MAX), None);
    }

    #[test]
    fn session_capabilities_fail_closed() {
        assert!(!SessionCapabilities::default().supports_shared_live_observation());
    }

    #[test]
    fn live_continuity_requires_every_interop_dimension() {
        let capabilities = SessionCapabilities {
            catalog: CatalogCapabilities {
                list: true,
                read: true,
                rename: false,
            },
            attachment: SessionAttachmentSupport::SharedLive,
            replay: SessionReplaySupport::Snapshot,
            stream_fidelity: SessionStreamFidelity::Semantic,
            external_input: true,
            external_surface_interop: true,
            control_replay: SessionControlCapabilities {
                approvals: true,
                questions: true,
            },
        };
        assert!(capabilities.supports_shared_live_observation());
        assert!(!capabilities.supports_continuation_with(&DriverCapabilities::default()));

        let turn = DriverCapabilities {
            resume_session: true,
            cancel_turn: true,
            steering: SteeringSupport::Native,
            ..DriverCapabilities::default()
        };
        assert!(capabilities.supports_continuation_with(&turn));

        let mut exclusive = capabilities;
        exclusive.attachment = SessionAttachmentSupport::Exclusive;
        exclusive.external_input = false;
        assert!(!exclusive.supports_shared_live_observation());
        assert!(exclusive.supports_continuation_with(&turn));
    }

    #[test]
    fn opaque_provider_values_are_bounded_even_when_deserialized() {
        let oversized = "x".repeat(MAX_SESSION_CURSOR_BYTES + 1);
        assert!(SessionCheckpoint::new(oversized.clone()).is_err());
        let encoded = serde_json::to_string(&oversized).expect("encoded");
        assert!(serde_json::from_str::<SessionCheckpoint>(&encoded).is_err());
        assert!(SessionItemKey::new("bad\nkey").is_err());
        let oversized_session =
            ProviderSessionId::new("s".repeat(MAX_PROVIDER_SESSION_ID_BYTES + 1))
                .expect("legacy id accepts nonblank values");
        assert_eq!(
            ProviderSessionRef::new(provider("codex"), oversized_session),
            Err(SessionContractError::InvalidProviderIdentity {
                kind: "provider session id",
                max_bytes: MAX_PROVIDER_SESSION_ID_BYTES,
            })
        );
    }

    #[test]
    fn session_pages_enforce_provider_workspace_and_requested_size() {
        let query = SessionQuery {
            provider: provider("codex"),
            workspace_id: workspace(),
            cursor: None,
            page_size: SessionPageSize::new(1),
        };
        assert_eq!(
            SessionPage::new(
                &query,
                vec![summary("codex", "one"), summary("codex", "two")],
                None,
            ),
            Err(SessionContractError::PageTooLarge { max_items: 1 })
        );
        assert_eq!(
            SessionPage::new(&query, vec![summary("claude", "one")], None),
            Err(SessionContractError::PageScopeMismatch)
        );
    }

    #[test]
    fn snapshots_enforce_item_and_total_text_bounds() {
        let window = HistoryWindow::new(1, 16);
        assert_eq!(
            SessionSnapshot::new(
                session("codex", "thread-1"),
                vec![message("first".to_owned()), message("second".to_owned())],
                None,
                false,
                false,
                window,
            ),
            Err(SessionContractError::SnapshotTooManyMessages { max_messages: 1 })
        );
        assert_eq!(
            SessionSnapshot::new(
                session("codex", "thread-1"),
                vec![message("seventeen bytes!!!".to_owned())],
                None,
                false,
                false,
                window,
            ),
            Err(SessionContractError::SnapshotTextTooLarge { max_bytes: 16 })
        );
    }

    #[test]
    fn debug_output_redacts_provider_ids_and_message_text() {
        let item = message("private provider transcript".to_owned());
        let rendered = format!("{item:?}");
        assert!(!rendered.contains("private provider transcript"));
        assert!(!format!("{:?}", session("codex", "secret-session")).contains("secret-session"));
    }

    #[test]
    fn titles_timestamps_and_activity_snapshots_reject_unsafe_values() {
        assert_eq!(
            SessionSummary::new(
                session("codex", "thread-1"),
                workspace(),
                Some("Title".to_owned()),
                Some("Preview".to_owned()),
                Some(-1),
                SessionAvailability::Available,
            ),
            Err(SessionContractError::InvalidTimestamp)
        );
        let activity = SessionItem {
            key: SessionItemKey::new("activity-1").expect("key"),
            revision: SessionItemVersion::new(1),
            run_id: None,
            origin: SessionEventOrigin::provider(ProviderSurface::Remote),
            payload: SessionItemPayload::Activity {
                activity_kind: SessionActivityKind::Command,
                status: SessionActivityStatus::Active,
                title: "unsafe\ntitle".to_owned(),
                detail: None,
            },
        };
        assert_eq!(
            activity.validate_text(),
            Err(SessionContractError::InvalidActivity)
        );

        let message_with_invalid_time = SessionItem {
            key: SessionItemKey::new("message-with-invalid-time").expect("key"),
            revision: SessionItemVersion::new(1),
            run_id: None,
            origin: SessionEventOrigin::provider(ProviderSurface::Remote),
            payload: SessionItemPayload::Message {
                role: SessionMessageRole::Assistant,
                text: "Done".to_owned(),
                created_at: Some(-1),
            },
        };
        assert_eq!(
            message_with_invalid_time.validate_text(),
            Err(SessionContractError::InvalidTimestamp)
        );
    }
}
