//! Group layer for agents in multiplayer Inline threads (bridge v2 spec §5).
//!
//! Native harnesses assume one user and one session. This module holds the
//! provider-neutral, pure rules that let an agent behave as a teammate:
//! attributed envelopes with native provenance, structured intake (no word
//! triggers, leading mentions decide the addressee), participation modes, the
//! speak-gate interface, the operation permission table, large surfaced
//! safety caps, bounded join and passive context, the hold/release state
//! machine, and the title and archive sync policy. Nothing here performs I/O; the runtime feeds facts in and executes
//! the returned decisions and effects.

mod caps;
mod context;
mod envelope;
mod guide;
mod handoff;
mod hold;
mod input;
mod intake;
mod participation;
mod permissions;
mod speak_gate;
mod sync;

pub use caps::{
    BudgetOutcome, DEFAULT_DAILY_SPEAK_GATE_BUDGET, DEFAULT_LOOP_CAP_HOPS, DailySpeakGateBudget,
    DayKey, LoopGuard, LoopGuards, LoopVerdict,
};
pub use context::{
    ContextAuthorRole, ContextBudget, ContextMessage, ContextParticipant, JoinContext,
    JoinContextInput, LinkedThread, PassiveBatch, PassiveContext,
};
pub use envelope::{
    Author, AuthorKind, ClaudeInputFields, ClaudeOrigin, CodexPlacement, Conversation,
    GroupMessage, INLINE_CHANNEL_SERVER, Mention, MessageEntity, ReplyRef, SentVia, claude_input,
    codex_placement, origin_of,
};
pub use guide::{GuideFacts, trusted_guide};
pub use handoff::{HandoffInstruction, HandoffProvider, HandoffTarget, handoff_instruction};
pub use hold::{
    CLAUDE_EXIT_GRACE, CLAUDE_IDLE_WINDOW, CODEX_DEFAULT_UNLOAD_DELAY, DetachPhase,
    HELD_ELSEWHERE_PROBE_INTERVAL, HoldEffect, HoldEvent, HoldMachine, HoldState, IdleRelease,
    PendingInput, RELEASE_STEP_TIMEOUT, ReleaseCause, ReleaseReceipt, ReleaseRequest, ReleaseStep,
    ReleaseStepOutcome, WakeupDisposition, release_steps,
};
pub use input::{direct_input, passive_input};
pub use intake::{
    AddresseeKind, DirectReason, IntakeDecision, IntakeFacts, ObserveReason, SkipReason, WorkPhase,
    classify_addressee, decide_intake, leading_mentions, required_operation,
};
pub use participation::{
    Participation, ParticipationChange, ParticipationError, ParticipationMode,
    apply_participation_change,
};
pub use permissions::{Admission, Grants, Operation, admit};
pub use speak_gate::{
    ConsiderOutcome, ConsiderQueue, ConsiderReadiness, ConsiderTicket, DEFAULT_QUIET_WINDOW_MS,
    GateAdmission, GateAvailability, SpeakGate, SpeakGateError, SpeakGateFuture, SpeakGateRequest,
    SpeakVerdict, UnavailableSpeakGate, effective_mode, gate_admission,
};
pub use sync::{
    ArchiveEffect, NativeArchive, NativeTitleSource, TitleEffect, TitleEvent, TitleSync,
    TitleSyncPolicy, WorkOrigin, archive_effect,
};
