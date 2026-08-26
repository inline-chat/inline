//! Provider-neutral contracts for browsing and observing durable agent sessions.
//!
//! These contracts compose with [`crate::AgentDriver`]. The turn driver remains
//! the single owner of session creation/resume, input, steering, interruption,
//! approvals, and questions; this module adds catalog and session-wide live
//! observation without creating a parallel execution path.

mod contract;
mod reducer;
mod types;

pub use contract::{
    AgentSessionCatalog, AgentSessionConnection, AttachedSession, SessionEventStream,
};
pub use reducer::{
    SessionAckError, SessionEchoCorrelator, SessionEchoError, SessionPhase, SessionProjectionAck,
    SessionProjectionAckTracker, SessionReduceAction, SessionReduceError, SessionRepairReason,
    SessionRevisionReducer, SnapshotMerge,
};
pub use types::{
    AttachSessionRequest, CatalogCapabilities, DEFAULT_HISTORY_MESSAGE_LIMIT,
    DEFAULT_HISTORY_TEXT_BYTES, DEFAULT_SESSION_PAGE_SIZE, DetachSessionRequest, HistoryWindow,
    MAX_HISTORY_MESSAGE_LIMIT, MAX_HISTORY_TEXT_BYTES, MAX_SESSION_PAGE_SIZE,
    MAX_SESSION_PREVIEW_CHARS, MAX_SESSION_TITLE_CHARS, ProviderHealth, ProviderInstanceRef,
    ProviderSessionRef, ProviderSurface, RenameSessionRequest, SessionActivityKind,
    SessionActivityStatus, SessionAttachmentId, SessionAttachmentSupport, SessionAvailability,
    SessionCapabilities, SessionCheckpoint, SessionContractError, SessionControlCapabilities,
    SessionControlContext, SessionControlId, SessionControlOption, SessionControlRequest,
    SessionControllerEpoch, SessionEvent, SessionEventOrigin, SessionEventPayload,
    SessionInputCorrelation, SessionItem, SessionItemKey, SessionItemPayload, SessionItemVersion,
    SessionMessageRole, SessionPage, SessionPageCursor, SessionPageSize, SessionQuery,
    SessionQuestion, SessionReadRequest, SessionReplaySupport, SessionRuntimeState,
    SessionSnapshot, SessionStreamFidelity, SessionStreamPosition, SessionSummary,
};
