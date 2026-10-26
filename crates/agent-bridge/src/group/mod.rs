//! Group layer for agents in multiplayer Inline threads (bridge v2 spec §5).
//!
//! Native harnesses assume one user and one session. This module holds the
//! provider-neutral, pure rules that let an agent behave as a teammate:
//! attributed envelopes with native provenance, structured intake (no word
//! triggers, leading mentions decide the addressee), participation modes, the
//! speak-gate interface, large surfaced safety caps, bounded join and passive
//! context, the hold/release state machine, and the title and archive sync
//! policy. Nothing here performs I/O; the runtime feeds facts in and executes
//! the returned decisions and effects.

mod caps;
mod context;
mod envelope;
mod guide;
mod handoff;
mod hold;
mod intake;
mod participation;
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
    GroupMessage, INLINE_CHANNEL_SERVER, Mention, MessageEntity, Provenance, ReplyRef, SentVia,
};
pub use guide::{GuideFacts, trusted_guide};
pub use handoff::{HandoffInstruction, HandoffProvider, HandoffTarget, handoff_instruction};
pub use hold::{
    CLAUDE_EXIT_GRACE, CLAUDE_IDLE_WINDOW, CODEX_DEFAULT_UNLOAD_DELAY,
    HELD_ELSEWHERE_PROBE_INTERVAL, HeldBy, HoldEffect, HoldEvent, HoldMachine, HoldState,
    IdleRelease, LiveItem, LiveWork, PendingInput, RELEASE_STEP_TIMEOUT, ReleaseAction,
    ReleaseCause, ReleasePhase, ReleaseReceipt, ReleaseRequest, ReleaseStep, ReleaseStepOutcome,
    WakeupDisposition,
};
pub use intake::{
    Access, AddresseeKind, DirectReason, IntakeDecision, IntakeFacts, ObserveReason, SkipReason,
    classify_addressee, decide_intake, leading_mentions,
};
pub use participation::{
    Participation, ParticipationChange, ParticipationError, ParticipationMode,
    apply_participation_change,
};
pub use speak_gate::{
    ConsiderOutcome, ConsiderQueue, ConsiderReadiness, ConsiderTicket, DEFAULT_QUIET_WINDOW_MS,
    GateAdmission, GateAvailability, SpeakGate, SpeakGateError, SpeakGateFuture, SpeakGateRequest,
    SpeakVerdict, UnavailableSpeakGate, effective_mode, gate_admission,
};
pub use sync::{
    ArchiveEffect, NativeArchive, NativeTitleSource, TitleEffect, TitleEvent, TitleSync,
    TitleSyncPolicy, WorkOrigin, archive_effect,
};
