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
mod store;
mod turn;

pub use command::{CommandParseError, parse_command};
pub use driver::{
    ActivitySemanticKind, ActivityStatus, ActivityUpsert, AgentDriver, AgentEvent,
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
    sanitize_visible_command, semantic_activity_title,
};
pub use process_host::{ProcessHostConfig, reap_stale_process_host, run_process_host};
pub use session::{ProviderSessionManager, SessionManagerError, SessionOpenOutcome};
pub use store::{
    ApprovalClaim, ApprovalClaimContext, ApprovalClaimOutcome, ApprovalRecord, ApprovalState,
    BridgeStore, ChatSettingsRecord, CommandChoiceAction, CommandChoiceClaimContext,
    CommandChoiceClaimOutcome, CommandChoiceRequest, CommandChoiceState, DurableProgress,
    HostToolCallClaim, HostToolCallRecord, InboundRecord, InboundState, InboundUndoOutcome,
    InstallationRecord, InterruptedInbound, MAX_RECENT_WORKSPACES, OperatorAllowlistClaimContext,
    OperatorAllowlistClaimOutcome, OperatorAllowlistDecision, OperatorAllowlistRequest,
    OperatorAllowlistState, PendingApproval, PendingCommandChoiceRequest, PendingFinalSend,
    PendingOperatorAllowlistRequest, PendingQuestion, QuestionClaimContext, QuestionClaimLocator,
    QuestionClaimOutcome, QuestionRecord, QuestionResolution, QuestionState, QueueRecord,
    QueueState, ReplyThreadMode, ReplyThreadOverride, ReplyThreadOverrideUpdateOutcome,
    SettingsUpdateOutcome, StoreError, StoreResult, WorkspaceChoice, WorkspaceFilesystemIdentity,
    WorkspaceRecord,
};
pub use turn::{
    Acknowledgement, CoordinatorEffect, DirectionDisposition, RunState, TurnCoordinator,
};
