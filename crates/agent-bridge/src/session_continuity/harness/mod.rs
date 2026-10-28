//! Session-scoped harness contract (bridge v2, spec §4.2).
//!
//! One ordered event stream per native session, whoever caused the event,
//! plus typed inputs and operations. It replaces the turn-scoped
//! [`crate::AgentDriver`] for drivers that implement it.
//!
//! - [`HarnessDriver`] describes a harness install, lists its catalog and
//!   native sessions, and opens a [`Session`].
//! - [`Session::send`] takes an [`Input`] with an explicit [`Delivery`] and
//!   native provenance ([`Origin`]).
//! - [`Session::control`] runs one typed [`Op`].
//! - [`Session::events`] streams sequenced [`Envelope`]s of [`Event`]s.
//!   Events keep native ids and payloads; unknown kinds are never dropped.
//! - [`AvailabilityMatrix`] says, per delivery and operation, whether it can
//!   be used and why not.
//!
//! Every type here is serde-stable: the same envelope feeds the renderer, the
//! journal and recorded conformance fixtures. Changes are additive; a field
//! or variant is never renamed or repurposed.

mod availability;
mod driver;
mod event;
mod ids;
mod input;
mod op;
mod state;
mod stream;

pub use availability::{Availability, AvailabilityMatrix, CapabilityManifest, CompatTier};
pub use driver::{
    Catalog, CatalogFolder, CatalogMode, CatalogScope, EventStream, ExecutableInfo,
    ExecutableSource, ForkPoint, HarnessDriver, HarnessFuture, LiveWork, OpenError, OpenMode,
    OpenSpec, OutputMode, ReleaseOutcome, Released, RuntimeHealth, RuntimeInfo, SendError, Session,
    SessionPage, SessionQuery, SessionSummary,
};
pub use event::{
    ApprovalSubject, ChildStatus, ChildUpdate, ClosedBy, CommandAction, Decision, DecisionKind,
    DeltaStream, EffectiveSettings, Envelope, Event, FieldInput, FieldOption, FileChangeKind,
    FileDiff, FormField, HeldBy, HeldSurface, InputFact, Interaction, InteractionKind, Item,
    ItemBody, ItemDelta, ItemKind, ItemStatus, ItemUpdate, MessageRole, Notice, NoticeLevel,
    QuestionForm, QueuedInput, TokenUsage, TurnPhase, UsageUpdate,
};
pub use ids::{
    ChatId, ChildId, ChildKind, ChildRef, DecisionId, FieldId, InputId, InteractionId,
    InvalidContractId, ItemId, MAX_CONTRACT_ID_BYTES, ModeId, QueueEntryId, SessionKey, UserId,
    WorkRef,
};
pub use input::{
    Acceptance, Delivery, DeliveryKind, Input, InputContent, InputDisposition, InputReceipt,
    Origin, SteerPriority,
};
pub use op::{
    FieldAnswer, GoalOp, InteractionResponse, Op, OpError, OpKind, OpOutcome, QueueOp,
    ReviewTarget, RewindPoint, SettingsChange, SettingsScope,
};
pub use state::{RunState, RunStateTracker, SetupReason, WaitingOn};
pub use stream::{CursorStep, DEFAULT_HUB_CAPACITY, EventHub, StreamCursor};
