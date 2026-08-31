//! Provider-neutral foundation for Inline's local coding-agent bridge.
//!
//! The crate separates provider adapters ([`AgentDriver`]) from Inline-native
//! policy, durable state, session coordination, and presentation. Drivers
//! report optional behavior through [`DriverCapabilities`]; its conservative
//! default advertises no optional capability, so callers can degrade to queued
//! direction, fresh sessions, or unavailable controls without probing a
//! provider by trial and error.

mod command;
mod driver;
mod model;
mod policy;
mod presentation;
mod process_host;
mod session;
mod session_continuity;
mod store;
mod turn;

pub use command::{CommandParseError, parse_command};
pub use driver::{
    ActivitySemanticKind, ActivityStatus, ActivityUpsert, AgentDriver, AgentEvent,
    AgentMessagePhase, AgentMessageUpdate,
    AgentEventReceiver, AgentEventSender, ApplyTiming, ApprovalDecision, ApprovalOption,
    ApprovalRequest, AuthenticationRequired, DriverCapabilities, DriverCommand,
    DriverCommandChoice, DriverCommandInput, DriverError, DriverFuture, DriverModelOption,
    DriverResult, DriverSettingOption, DriverSettingsCatalog, FileChange, HostToolCall,
    HostToolConfiguration, HostToolFuture, HostToolHandler, HostToolResult, HostToolSpec,
    HostToolTransport, PlanStep, PlanStepStatus, Question, QuestionAnswer, QuestionOption,
    QuestionRequest, ResumeSessionSpec, SessionReplay, SessionSpec, StartedTurn, SteeringSupport,
    TurnInput, TurnOptions, TurnOutcome, TurnTiming,
};
pub use model::{
    BindingKey, Direction, DirectionId, InputAttachment, InputAttachmentKind, InstallationId,
    OutputAttachment, OutputAttachmentKind, ProviderId, ProviderSessionId, QueueItemId, TurnId,
    WorkspaceId,
};
pub use policy::{
    ActionInvocation, AddressSignals, Addressing, CommandInvocation, IgnoreReason, InboundEnvelope,
    OperatorPolicy, OperatorPolicyError, TriggerDecision, TriggerResolver,
};
pub use presentation::{
    ActivityKind, NativeToolActivity, PresentationUpdate, SemanticActivity, StreamingPresenter,
    UpdatePriority, ValidationSummary, VisibilityMode, VisibilityPolicy, WORKING_CONTINUED_STATUS,
    WORKING_STATUS, format_elapsed_compact, native_tool_activity, render_completion_summary,
    sanitize_diagnostic_text, sanitize_visible_command, sanitize_visible_transcript,
    semantic_activity_title,
};
pub use process_host::{ProcessHostConfig, reap_stale_process_host, run_process_host};
pub use session::{
    PreparedSessionThread, ProviderSessionManager, ProviderWorkLease, SessionManagerError,
    SessionOpenOutcome,
};
pub use session_continuity::{
    AgentSessionCatalog, AgentSessionConnection, AttachSessionRequest, AttachedSession,
    CatalogCapabilities, DEFAULT_HISTORY_MESSAGE_LIMIT, DEFAULT_HISTORY_TEXT_BYTES,
    DEFAULT_SESSION_PAGE_SIZE, DetachSessionRequest, HistoryWindow, MAX_HISTORY_MESSAGE_LIMIT,
    MAX_HISTORY_TEXT_BYTES, MAX_SESSION_PAGE_SIZE, MAX_SESSION_PREVIEW_CHARS,
    MAX_SESSION_TITLE_CHARS, ProviderHealth, ProviderInstanceRef, ProviderSessionRef,
    ProviderSurface, RenameSessionRequest, SessionAckError, SessionActivityKind,
    SessionActivityStatus, SessionAttachmentId, SessionAttachmentSupport, SessionAvailability,
    SessionCapabilities, SessionCheckpoint, SessionContractError, SessionControlCapabilities,
    SessionControlContext, SessionControlId, SessionControlOption, SessionControlRequest,
    SessionControllerEpoch, SessionEchoCorrelator, SessionEchoError, SessionEvent,
    SessionEventOrigin, SessionEventPayload, SessionEventStream, SessionInputCorrelation,
    SessionItem, SessionItemKey, SessionItemPayload, SessionItemVersion, SessionMessageRole,
    SessionPage, SessionPageCursor, SessionPageSize, SessionPhase, SessionProjectionAck,
    SessionProjectionAckTracker, SessionQuery, SessionQuestion, SessionReadRequest,
    SessionReduceAction, SessionReduceError, SessionRepairReason, SessionReplaySupport,
    SessionRevisionReducer, SessionRuntimeState, SessionSnapshot, SessionStreamFidelity,
    SessionStreamPosition, SessionSummary, SnapshotMerge,
};
pub use store::{
    ApprovalClaim, ApprovalClaimContext, ApprovalClaimOutcome, ApprovalRecord, ApprovalState,
    BridgeStore, ChatSettingsRecord, CommandChoiceAction, CommandChoiceClaimContext,
    CommandChoiceClaimOutcome, CommandChoiceRequest, CommandChoiceState, DurableProgress,
    HistoryImportState, HostToolCallClaim, HostToolCallRecord, InboundRecord, InboundState,
    InboundUndoOutcome, InstallationRecord, InterruptedInbound, MAX_ACTIVE_SESSION_PICKERS,
    MAX_RECENT_WORKSPACES, MAX_SESSION_PICKER_ITEMS, OperatorAllowlistClaimContext,
    OperatorAllowlistClaimOutcome, OperatorAllowlistDecision, OperatorAllowlistRequest,
    OperatorAllowlistState, PendingAgentOutputLink, PendingApproval, PendingCommandChoiceRequest,
    PendingFinalSend, PendingOperatorAllowlistRequest, PendingQuestion, PendingSessionPicker,
    QuestionClaimContext, QuestionClaimLocator, QuestionClaimOutcome, QuestionRecord,
    QuestionResolution, QuestionState, QueueRecord, QueueState, ReplyThreadMode,
    ReplyThreadOverride, ReplyThreadOverrideUpdateOutcome, SESSION_PICKER_PAGE_SIZE,
    SessionPickerAction, SessionPickerClaimContext, SessionPickerClaimOutcome,
    SessionPickerCompletion, SessionPickerRecord, SessionPickerState, SessionPickerThreadGate,
    SessionThreadBindOutcome, SessionThreadBinding, SessionThreadOpening,
    SessionThreadPrepareOutcome, SettingsUpdateOutcome, StoreError, StoreResult, WorkspaceChoice,
    WorkspaceFilesystemIdentity, WorkspaceRecord,
};
pub use turn::{
    Acknowledgement, CoordinatorEffect, DirectionDisposition, RunState, TurnCoordinator,
};
