//! The driver and session traits (spec §4.2).

use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;

use futures_util::Stream;
use serde::{Deserialize, Serialize};

use super::{
    AvailabilityMatrix, CapabilityManifest, ChildRef, Envelope, HeldBy, Input, InputId,
    InputReceipt, InteractionId, ItemId, ModeId, Op, OpError, OpOutcome, QueuedInput, SessionKey,
    SettingsChange, SetupReason,
};
use crate::{
    DriverCommand, DriverError, DriverFuture, DriverModelOption, DriverSettingOption, ProviderId,
    ProviderSessionId, SessionCheckpoint, SessionPageCursor, TurnId,
};

/// Boxed future with a typed error, matching [`DriverFuture`].
pub type HarnessFuture<'a, T, E> = Pin<Box<dyn Future<Output = Result<T, E>> + Send + 'a>>;

/// A session's event stream. Each subscriber sees events from the moment it
/// subscribes; a subscriber that falls behind receives [`super::Event::Gap`].
pub type EventStream = Pin<Box<dyn Stream<Item = Envelope> + Send + 'static>>;

/// One harness on one machine: Codex, Claude, or an ACP agent.
pub trait HarnessDriver: Send + Sync {
    /// Provider, executable, version and capability manifest from the last connection.
    fn describe(&self) -> RuntimeInfo;

    /// Pickers and commands from the harness (models resolved, efforts, speed,
    /// permission modes, collaboration modes, commands with argument forms,
    /// agents, skills).
    fn catalog<'a>(&'a self, scope: CatalogScope) -> DriverFuture<'a, Catalog>;

    /// Native sessions per folder or project, with who holds each.
    fn sessions<'a>(&'a self, query: SessionQuery) -> DriverFuture<'a, SessionPage>;

    /// Starts, resumes or forks a session. Errors are typed so the apps can
    /// offer the fix.
    fn open<'a>(&'a self, spec: OpenSpec) -> HarnessFuture<'a, Arc<dyn Session>, OpenError>;
}

/// One live native session, held by this bridge.
pub trait Session: Send + Sync {
    /// Provider and native session id.
    fn key(&self) -> &SessionKey;

    /// Per-delivery and per-operation availability right now.
    fn availability(&self) -> AvailabilityMatrix;

    /// Subscribes to the session stream.
    fn events(&self) -> EventStream;

    /// Sends one input with an explicit delivery.
    fn send<'a>(&'a self, input: Input) -> HarnessFuture<'a, InputReceipt, SendError>;

    /// Runs one typed operation.
    fn control<'a>(&'a self, op: Op) -> HarnessFuture<'a, OpOutcome, OpError>;

    /// What is live and would be affected by a release: children, background
    /// tasks, pending interactions, queued input, wakeups.
    fn live_work(&self) -> LiveWork;

    /// Lets the session go so another client can take it (Codex unsubscribe,
    /// Claude close stdin then wait). The caller confirms live work first.
    fn release<'a>(&'a self) -> HarnessFuture<'a, Released, OpError>;
}

/// What the bridge knows about one harness install.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeInfo {
    /// Provider.
    pub provider: ProviderId,
    /// Executable chosen at setup and revalidated on every connection.
    pub executable: ExecutableInfo,
    /// Inline driver version, for telemetry.
    pub driver_version: String,
    /// Ready, or what setup is needed.
    pub health: RuntimeHealth,
    /// Manifest from the last connection.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub manifest: Option<CapabilityManifest>,
}

/// The harness executable.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecutableInfo {
    /// Absolute path.
    pub path: PathBuf,
    /// How it was chosen.
    pub source: ExecutableSource,
    /// Version reported by the binary.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// SHA-256 of the binary, when computed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    /// Other installs found on PATH, flagged in `doctor` and Agent Settings.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub other_installs: Vec<PathBuf>,
}

/// How the executable was chosen.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecutableSource {
    /// The owner picked it.
    User,
    /// Found on PATH at setup.
    Path,
}

/// Runtime health.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "health", rename_all = "snake_case")]
pub enum RuntimeHealth {
    /// Ready to run.
    Ready,
    /// Needs setup, with the fix.
    NeedsSetup {
        /// Why.
        reason: SetupReason,
    },
    /// Not connected yet.
    Unknown,
}

/// Scope of a catalog request.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogScope {
    /// Folder whose configuration applies.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<PathBuf>,
    /// Session whose commands, agents and skills apply.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<ProviderSessionId>,
}

/// Pickers and commands, with native ids.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Catalog {
    /// Models with their efforts.
    #[serde(default)]
    pub models: Vec<DriverModelOption>,
    /// Speed / service tiers.
    #[serde(default)]
    pub speeds: Vec<DriverSettingOption>,
    /// Permission modes.
    #[serde(default)]
    pub permission_modes: Vec<DriverSettingOption>,
    /// Collaboration and plan modes.
    #[serde(default)]
    pub modes: Vec<CatalogMode>,
    /// Commands with argument forms.
    #[serde(default)]
    pub commands: Vec<DriverCommand>,
    /// Agents the harness can run.
    #[serde(default)]
    pub agents: Vec<DriverSettingOption>,
    /// Skills.
    #[serde(default)]
    pub skills: Vec<DriverSettingOption>,
}

/// One collaboration or plan mode.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogMode {
    /// Native id.
    pub id: ModeId,
    /// Label.
    pub label: String,
    /// Description.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// A native session listing request.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionQuery {
    /// Folder (or project root) to list; `None` lists every folder.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<PathBuf>,
    /// Include archived sessions.
    #[serde(default)]
    pub archived: bool,
    /// Page cursor.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<SessionPageCursor>,
    /// Page size; drivers clamp it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
}

/// One page of native sessions.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionPage {
    /// Sessions, most recent first.
    pub sessions: Vec<SessionSummary>,
    /// Cursor for the next page.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next: Option<SessionPageCursor>,
}

/// One native session in a listing.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionSummary {
    /// Provider and native id.
    pub key: SessionKey,
    /// Native title.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// First-message preview.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
    /// Folder.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<PathBuf>,
    /// Last update, Unix seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<i64>,
    /// Who holds it, when another client does.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub held_by: Option<HeldBy>,
    /// Archived.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub archived: bool,
}

/// How to open a session.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenSpec {
    /// Start, resume or fork.
    pub mode: OpenMode,
    /// The folder chosen for the thread.
    pub folder: PathBuf,
    /// Initial settings.
    #[serde(default, skip_serializing_if = "SettingsChange::is_empty")]
    pub settings: SettingsChange,
    /// Trusted guide in system/developer instructions (identity, owner,
    /// participants, etiquette, tools). Survives compaction and cold resume.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub instructions: Option<String>,
    /// Native title for a new session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Resume cursor from the journal, when the harness supports replay.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<SessionCheckpoint>,
    /// The effective output mode (thread override, else the agent default).
    /// Claude's Friendly mode is a launch flag (`--brief`, which enables
    /// `SendUserMessage`), so it is fixed when the session opens; a change on a
    /// live session applies at the next open (after an idle release or an
    /// explicit `/release`) and never restarts work in progress. Codex renders
    /// both modes from the same stream and ignores it.
    #[serde(default, skip_serializing_if = "OutputMode::is_detailed")]
    pub output_mode: OutputMode,
}

/// How an agent's work is shown (spec §6): one explicit setting per agent,
/// overridable per thread.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutputMode {
    /// Every item the harness reports, as collapsible progress rows.
    #[default]
    Detailed,
    /// Only the harness's short prose updates, then the final answer.
    Friendly,
}

impl OutputMode {
    /// Whether this is the default mode.
    pub fn is_detailed(&self) -> bool {
        *self == Self::Detailed
    }
}

/// Open mode.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum OpenMode {
    /// A fresh native session.
    Start,
    /// An existing session.
    Resume {
        /// Native session id.
        session: ProviderSessionId,
    },
    /// A copy of an existing session ("Fork here").
    Fork {
        /// Native session id to fork.
        session: ProviderSessionId,
        /// Fork point; `None` forks at the end.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        at: Option<ForkPoint>,
    },
}

/// Where to fork.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ForkPoint {
    /// After this native item.
    Item {
        /// Native item id.
        item: ItemId,
    },
    /// After this turn.
    Turn {
        /// Native turn id.
        turn: TurnId,
    },
}

/// Why a session could not be opened.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum OpenError {
    /// The runtime needs setup first.
    #[error("runtime needs setup: {0:?}")]
    NeedsSetup(SetupReason),
    /// Another client holds the session. The input stays pending.
    #[error("session is held elsewhere")]
    HeldElsewhere(HeldBy),
    /// The native session does not exist.
    #[error("session not found")]
    NotFound,
    /// The mode (resume, fork) is unavailable for this harness.
    #[error("open mode unavailable: {0}")]
    Unavailable(super::Availability),
    /// Transport or process failure.
    #[error(transparent)]
    Driver(#[from] DriverError),
}

/// Why an input was not accepted.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum SendError {
    /// The delivery is unavailable for this harness.
    #[error("delivery unavailable: {0}")]
    Unavailable(super::Availability),
    /// A steer named a turn that is no longer running.
    #[error("expected turn is not running")]
    TurnMismatch {
        /// The running turn, if any.
        active: Option<TurnId>,
    },
    /// A turn is running and the delivery was `Turn`.
    #[error("a turn is already running")]
    Busy {
        /// The running turn.
        active: TurnId,
    },
    /// Another client holds the session.
    #[error("session is held elsewhere")]
    HeldElsewhere(HeldBy),
    /// The harness rejected the input.
    #[error("harness rejected the input: {0}")]
    Rejected(String),
    /// The harness may or may not have accepted it. Never retried
    /// automatically; it fences conflicting operations until reconciled.
    #[error("delivery outcome is unknown: {0}")]
    Unknown(String),
    /// Transport or process failure before the harness saw the input.
    #[error(transparent)]
    Driver(#[from] DriverError),
}

/// Live work a release would affect.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LiveWork {
    /// Running turn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn: Option<TurnId>,
    /// Running children and background tasks.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<ChildRef>,
    /// Pending interactions.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub interactions: Vec<InteractionId>,
    /// Queued input.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub queued: Vec<QueuedInput>,
    /// Scheduled wakeups, as the harness names them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub wakeups: Vec<String>,
}

impl LiveWork {
    /// Nothing live: the idle timer may release.
    pub fn is_idle(&self) -> bool {
        self.turn.is_none()
            && self.children.is_empty()
            && self.interactions.is_empty()
            && self.queued.is_empty()
            && self.wakeups.is_empty()
    }
}

/// Receipt of a release.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Released {
    /// The session.
    pub key: SessionKey,
    /// Whether native ownership is already released or still pending.
    pub outcome: ReleaseOutcome,
    /// Interactions cancelled by the release.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub cancelled_interactions: Vec<InteractionId>,
    /// Inline inputs kept pending in Inline.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pending_inputs: Vec<InputId>,
    /// Children stopped by the release.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub stopped_children: Vec<ChildRef>,
}

/// How far a release has gone.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReleaseOutcome {
    /// This bridge stopped listening, but the harness still owns the session
    /// for now. The stream reports `RunState::Released` when it lets go;
    /// until then the apps show "releasing".
    Unsubscribed,
    /// The harness released native ownership; another client may take it.
    NativeReleased,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn live_work_is_idle_only_when_everything_is_empty() {
        assert!(LiveWork::default().is_idle());
        let busy = LiveWork {
            wakeups: vec!["cron 9am".to_owned()],
            ..LiveWork::default()
        };
        assert!(!busy.is_idle());
    }

    #[test]
    fn open_spec_round_trips_with_fork_point() {
        let spec = OpenSpec {
            mode: OpenMode::Fork {
                session: ProviderSessionId::new("thread-1").expect("session"),
                at: Some(ForkPoint::Turn {
                    turn: TurnId::new("turn-3").expect("turn"),
                }),
            },
            folder: PathBuf::from("/work/inline"),
            settings: SettingsChange::default(),
            instructions: None,
            title: None,
            after: None,
            output_mode: OutputMode::Detailed,
        };
        let encoded = serde_json::to_value(&spec).expect("encode");
        assert_eq!(
            encoded,
            serde_json::json!({
                "mode": {"kind": "fork", "session": "thread-1", "at": {"kind": "turn", "turn": "turn-3"}},
                "folder": "/work/inline"
            })
        );
        assert_eq!(
            serde_json::from_value::<OpenSpec>(encoded).expect("decode"),
            spec
        );
    }
}
