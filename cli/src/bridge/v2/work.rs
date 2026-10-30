//! One work: the native session of one agent in one Inline thread.
//!
//! An actor task owns the session, the hold machine (spec §4.6), the renderer
//! and the cards. The main loop records each input in the ledger, then hands
//! it here; this task delivers it, follows its receipts, and carries out the
//! hold machine's effects in order, feeding their outcomes back.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Duration;

use futures_util::{FutureExt, StreamExt};
use inline_agent_bridge::group::{
    ConsiderOutcome, ConsiderQueue, ContextBudget, ContextMessage, DailySpeakGateBudget, DayKey,
    GateAdmission, GateAvailability, Grants, GuideFacts, HandoffInstruction, HandoffProvider,
    HandoffTarget, HoldEffect, HoldEvent, HoldMachine, HoldState, IdleRelease, Operation,
    ParticipationMode, PassiveBatch, PendingInput, Publication, PublicationEffect,
    PublicationEvent, ReleaseCause, ReleaseReceipt, ReleaseRequest, ReleaseStep,
    ReleaseStepOutcome, SpeakGateError, SpeakVerdict, WorkPhase, gate_admission,
    handoff_instruction, release_event, run_state_event, trusted_guide,
};
use inline_agent_bridge::harness::ChatId;
use inline_agent_bridge::harness::{
    Acceptance, Delivery, Event, EventStream, FieldAnswer, FieldId, FieldInput, HarnessDriver,
    HeldBy, Input, InputDisposition, InputFact, InputId, InteractionId, InteractionResponse, Op,
    OpError, OpKind, OpenError, OpenMode, OpenSpec, OutputMode, QuestionForm, QueueOp, RunState,
    SendError, Session, SettingsChange, SteerPriority, TurnPhase, UsageUpdate, UserId, WaitingOn,
};
use inline_agent_bridge::{HostToolResult, MAX_SESSION_TITLE_CHARS, ProviderSessionId, TurnId};
use inline_client::{CreateReplyThreadRequest, FormFieldValue, FormValue, InlineClient, InlineId};
use inline_protocol::proto;
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, oneshot, watch};

use super::api::{self, Failure, Notify, chat_peer};
use super::doc::{Doc, DocBuilder};
use super::ledger::{InputState, Ledger};
use super::limits;
use super::render::{self, ActionStyle, CardAction, RenderOp, Renderer, Vocabulary};
use super::settings;
use super::tools::{Tools, WorkTool};

/// Progress edits are coalesced to at most one per slot in this window.
const EDIT_INTERVAL: Duration = Duration::from_millis(1200);
const TICK: Duration = Duration::from_secs(15);
/// The apps drop a compose action after 6 s without a repeat.
const WORKING_HEARTBEAT: Duration = Duration::from_secs(3);
const WORKING_SEND_TIMEOUT: Duration = Duration::from_secs(2);
/// Waits before each attempt to post an answer or card; after the last one
/// it waits for the next tick.
const PUBLISH_RETRIES: [Duration; 3] = [
    Duration::ZERO,
    Duration::from_millis(500),
    Duration::from_secs(2),
];
/// The longest a rate-limited answer waits within one publish attempt.
const MAX_PUBLISH_WAIT: Duration = Duration::from_secs(30);
const NOT_PENDING: &str = "This request is no longer pending.";
/// Trusted instructions for the speak gate's side call.
const SPEAK_GATE_GUIDE: &str = "You take part in this Inline thread but nobody addressed you. \
Decide whether a reply from you would clearly help the people here right now. Stay quiet \
for chatter, for questions others are answering, and when unsure. Reply with only JSON: \
{\"speak\": true or false, \"why\": \"one short reason\", \"confidence\": 0.0 to 1.0}";
const NO_ACCESS: &str = "You don't have access to do that with this agent.";
/// Tries at a subthread move whose outcome is unknown.
const MOVE_ATTEMPTS: u32 = 3;
/// Bound on the observed messages delivered before the next input.
const PASSIVE_CONTEXT_BYTES: usize = 16 * 1024;

/// Owner-authenticated calls a work needs: connect and look up its session.
pub(crate) trait OwnerCalls: Send + Sync {
    fn connect(
        &self,
        input: proto::ConnectAgentSessionInput,
    ) -> futures_util::future::BoxFuture<'_, Result<proto::ConnectAgentSessionResult, String>>;
    fn lookup(
        &self,
        input: proto::GetAgentSessionInput,
    ) -> futures_util::future::BoxFuture<'_, Result<proto::GetAgentSessionResult, String>>;
}

/// The sender grants the runtime knows, shared by every work.
pub(crate) trait AccessSource: Send + Sync {
    fn grants(&self, user_id: i64) -> futures_util::future::BoxFuture<'_, Grants>;
}

/// What every work of one agent shares.
pub(crate) struct Agent {
    pub bot: InlineClient,
    pub owner: Arc<dyn OwnerCalls>,
    pub access: Arc<dyn AccessSource>,
    pub harness: Arc<dyn HarnessDriver>,
    pub ledger: Arc<Ledger>,
    pub vocabulary: Vocabulary,
    pub provider: proto::AgentSessionProvider,
    pub agent_name: String,
    pub installation_id: String,
    pub owner_user_id: i64,
    pub bot_user_id: i64,
    pub folder: PathBuf,
    /// Messages this bot sent, so replies to them address it.
    pub sent: Arc<std::sync::Mutex<HashSet<i64>>>,
    /// Inline tools served to this agent's sessions (spec §4.8).
    pub tools: Option<Arc<Tools>>,
    /// A work that moved into a subthread tells the main loop (from, to).
    pub moves: mpsc::UnboundedSender<(i64, i64)>,
    pub names: Arc<api::Names>,
    /// The owner's DM with the agent, for notices meant for the owner.
    pub dm_chat_id: i64,
    /// The speak gate's daily budget, shared by every work of this agent.
    pub gate_budget: std::sync::Mutex<DailySpeakGateBudget>,
    /// The account's latest usage windows, from any of its sessions, for
    /// the usage button in Compose.
    pub usage: std::sync::Mutex<Vec<inline_agent_bridge::DriverUsageWindow>>,
    /// Chat → how full its session's context window is.
    pub context: std::sync::Mutex<HashMap<i64, settings::ContextUsage>>,
    /// Bound chat → the project its owner chose. Inline pins a bound
    /// thread's sessions to it, so connecting names it.
    pub bound_projects: std::sync::Mutex<HashMap<i64, String>>,
}

impl Agent {
    /// Keeps the latest usage a session reported. Windows merge by name and
    /// length: Claude reports its 5-hour and weekly limits one at a time.
    fn record_usage(&self, chat_id: i64, usage: &UsageUpdate) {
        self.record_limits(&usage.limits);
        let used = usage.last.map(|last| last.total);
        if (used.is_some() || usage.context_window.is_some())
            && let Ok(mut contexts) = self.context.lock()
        {
            let context = contexts.entry(chat_id).or_default();
            if let Some(used) = used {
                context.used = used;
            }
            if let Some(window) = usage.context_window {
                context.window = window;
            }
        }
    }

    pub(super) fn record_limits(&self, limits: &[inline_agent_bridge::DriverUsageWindow]) {
        if !limits.is_empty()
            && let Ok(mut windows) = self.usage.lock()
        {
            for window in limits {
                match windows.iter().position(|known| {
                    known.label == window.label && known.window_minutes == window.window_minutes
                }) {
                    Some(index) => windows[index] = window.clone(),
                    None if windows.len() < 8 => windows.push(window.clone()),
                    None => {}
                }
            }
        }
    }

    fn handoff_provider(&self) -> Option<HandoffProvider> {
        match self.vocabulary {
            Vocabulary::Codex => Some(HandoffProvider::Codex),
            Vocabulary::Claude => Some(HandoffProvider::Claude),
            Vocabulary::OpenCode | Vocabulary::Amp => None,
        }
    }

    fn idle_release(&self) -> IdleRelease {
        match self.vocabulary {
            Vocabulary::Codex => IdleRelease::codex(None),
            // ACP owns one private process per session. Release
            // shuts down that process and confirms native ownership ended.
            Vocabulary::OpenCode | Vocabulary::Amp => IdleRelease::Unsubscribe {
                native_unload_delay_ms: 0,
            },
            Vocabulary::Claude => {
                IdleRelease::claude(inline_agent_bridge::group::CLAUDE_IDLE_WINDOW)
            }
        }
    }
}

/// A work control from the work bar or a command.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Control {
    Stop,
    Pause,
    Resume,
    Release(ReleaseCause),
}

/// Payload of a button this runtime sends.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t")]
pub(crate) enum ActionData {
    /// An approval decision.
    #[serde(rename = "d")]
    Decision { i: String, d: String },
    #[serde(rename = "rc")]
    ReleaseConfirm,
    #[serde(rename = "rx")]
    ReleaseCancel,
    #[serde(rename = "rr")]
    ReleaseRetry,
    #[serde(rename = "f")]
    ForkHere,
    /// Run or discard an input kept pending.
    #[serde(rename = "p")]
    Pending { i: String, run: bool },
    /// "Full output" on progress messages sent before it was removed.
    #[serde(rename = "o")]
    FullOutput,
    /// More agent-only hops in this thread (spec §5.1 rule 6).
    #[serde(rename = "lx")]
    ExtendLoop,
    /// More speak-gate checks for the rest of today.
    #[serde(rename = "gr")]
    RaiseGateBudget,
    /// Option `o` of question `f` on a question card asked with buttons.
    #[serde(rename = "q")]
    Pick { i: String, f: usize, o: usize },
}

pub(crate) enum Command {
    /// Direct input, already recorded in the ledger.
    Input {
        input: Box<Input>,
        pending: PendingInput,
        message_id: i64,
        /// In a group thread the final answer replies to the requester
        /// (spec §6, placement); a DM or the agent's own thread has none.
        answer_reply: bool,
        /// The message this one replies to: a reply to an open question card
        /// is the answer in the person's own words.
        reply_to: Option<i64>,
    },
    /// A message the agent observes without a turn; batched until the next
    /// native boundary.
    Passive {
        message: ContextMessage,
    },
    /// An unaddressed message the speak gate may answer (active participation).
    Consider {
        message_id: i64,
        line: String,
    },
    Control {
        control: Control,
        actor: i64,
        reply: oneshot::Sender<Option<String>>,
    },
    Action {
        message_id: i64,
        actor: i64,
        data: ActionData,
        reply: oneshot::Sender<Option<String>>,
    },
    Form {
        message_id: i64,
        actor: i64,
        values: Vec<FormValue>,
        reply: oneshot::Sender<Option<String>>,
    },
    SetMode(OutputMode),
    /// The Inline thread's title changed (spec §15.7: Inline → harness).
    Title(String),
    /// A session operation from settings or a command; answers with a toast.
    Session {
        op: SessionOp,
        reply: oneshot::Sender<Option<String>>,
    },
    /// The folder this work's session opens in. Refused once a session
    /// exists: it keeps its folder.
    Folder {
        folder: PathBuf,
        reply: oneshot::Sender<Result<(), String>>,
    },
    /// Inputs a previous run left unconfirmed (input, message): the session
    /// opens to settle them.
    Reconcile {
        inputs: Vec<(InputId, i64, i64)>,
    },
    /// A tool that acts through the work (spec §4.8).
    Tool {
        tool: WorkTool,
        reply: oneshot::Sender<HostToolResult>,
    },
}

/// Operations on the work's native session from Agent Settings, the
/// composer chain or a command.
#[derive(Clone, Debug)]
pub(crate) enum SessionOp {
    /// Model, reasoning or permissions for this thread from the next message
    /// on (Oct 26). An empty string clears a field back to the default.
    Settings(SettingsChange),
    Compact,
    Clear,
    /// The harness's own mode: Codex collaboration mode, Claude permission
    /// mode ("plan" for both).
    Mode(String),
    /// Codex's review of uncommitted changes, or of the branch named.
    Review(Option<String>),
    /// Claude's rewind of the last turn's file changes.
    Undo,
}

struct AdmittedCommand {
    command: Command,
    _lease: crate::bridge::update_activity::Lease,
}
#[derive(Clone)]
pub(crate) struct CommandSender(mpsc::Sender<AdmittedCommand>);
#[derive(Clone)]
pub(crate) struct WeakCommandSender(mpsc::WeakSender<AdmittedCommand>);
impl CommandSender {
    pub(crate) async fn send(
        &self,
        command: Command,
    ) -> Result<(), mpsc::error::SendError<Command>> {
        let Some(lease) = crate::bridge::update_activity::global().enter() else {
            return Err(mpsc::error::SendError(command));
        };
        self.0
            .send(AdmittedCommand {
                command,
                _lease: lease,
            })
            .await
            .map_err(|error| mpsc::error::SendError(error.0.command))
    }
    fn downgrade(&self) -> WeakCommandSender {
        WeakCommandSender(self.0.downgrade())
    }
}
impl WeakCommandSender {
    pub(crate) fn upgrade(&self) -> Option<CommandSender> {
        self.0.upgrade().map(CommandSender)
    }
}

/// The main loop's handle on one work.
pub(crate) struct WorkHandle {
    pub tx: CommandSender,
    pub phase: watch::Receiver<WorkPhase>,
    /// Inline's ID for the work, once connected; 0 before.
    pub agent_session_id: Arc<AtomicI64>,
    pub task: tokio::task::JoinHandle<()>,
}

impl WorkHandle {
    pub(crate) fn agent_session_id(&self) -> Option<i64> {
        Some(self.agent_session_id.load(Ordering::Acquire)).filter(|id| *id > 0)
    }
}

/// Where a known work lives, from the server.
#[derive(Clone, Debug, Default)]
pub(crate) struct Known {
    pub agent_session_id: Option<i64>,
    pub native: Option<ProviderSessionId>,
    /// The session is v1's for this thread, not yet recorded in Inline.
    pub from_v1: bool,
}

/// Starts the actor for one work.
pub(crate) fn spawn(
    agent: Arc<Agent>,
    chat_id: i64,
    known: Known,
    output_mode: OutputMode,
    thread_settings: SettingsChange,
) -> WorkHandle {
    let (tx, rx) = mpsc::channel(64);
    let tx = CommandSender(tx);
    let commands = tx.downgrade();
    let (phase_tx, phase) = watch::channel(if known.native.is_some() {
        WorkPhase::Idle
    } else {
        WorkPhase::None
    });
    let agent_session_id = Arc::new(AtomicI64::new(known.agent_session_id.unwrap_or(0)));
    let outbox = agent
        .ledger
        .outputs(chat_id)
        .unwrap_or_else(|error| {
            log::error!(target: "inline::bridge::v2", "cannot restore output queue: {error}");
            Vec::new()
        })
        .into_iter()
        .filter_map(|payload| match serde_json::from_str(&payload) {
            Ok(outgoing) => Some(outgoing),
            Err(error) => {
                log::error!(target: "inline::bridge::v2", "invalid retained output: {error}");
                None
            }
        })
        .collect();
    let actor = Actor {
        hold: HoldMachine::new(agent.idle_release()),
        renderer: Renderer::new(output_mode, agent.vocabulary, agent.agent_name.clone()),
        agent,
        chat_id,
        commands,
        publication: Publication::new(ChatId(chat_id)),
        parent_card: None,
        parent_card_text: None,
        agent_session_id: agent_session_id.clone(),
        native: known.native,
        native_from_v1: known.from_v1,
        session: None,
        events: None,
        probe: None,
        inputs: HashMap::new(),
        retained: Vec::new(),
        removing: HashSet::new(),
        paused: false,
        stopping: false,
        turn: None,
        turn_started: None,
        waiting: None,
        live: Default::default(),
        cards: HashMap::new(),
        card_by_interaction: HashMap::new(),
        release_card: None,
        offers: HashMap::new(),
        slots: HashMap::new(),
        edits: HashMap::new(),
        reported: None,
        working_due: None,
        phase: phase_tx,
        update_busy: crate::bridge::update_activity::global().key(),
        started_ms: now_ms(),
        passive: PassiveBatch::new(chat_id),
        title: None,
        rename_pending: false,
        settings_pending: !settings::effective(&thread_settings).is_empty(),
        settings: thread_settings,
        consider: ConsiderQueue::default(),
        consider_lines: HashMap::new(),
        answer_replies: HashMap::new(),
        answer_to: None,
        unsaved: std::sync::Mutex::new(HashMap::new()),
        uncertain: HashMap::new(),
        outbox,
        rendering_turn: None,
        last_turn_input: None,
    };
    let task = tokio::spawn(actor.run(rx));
    WorkHandle {
        tx,
        phase,
        agent_session_id,
        task,
    }
}

#[derive(Clone, Debug)]
struct Card {
    /// The chat the card was posted in; a move leaves it behind.
    chat: i64,
    interaction: InteractionId,
    approval: bool,
    form: Option<QuestionForm>,
    /// Answers so far, when the card asks its questions one at a time.
    answered: Vec<String>,
}

/// A short digest of an answer's text, for its identity.
fn text_digest(text: &str) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(text.as_bytes())[..8]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// An answer or card waiting to be posted.
#[derive(Clone, Serialize, Deserialize)]
struct Outgoing {
    chat: i64,
    doc: Doc,
    reply_to: Option<i64>,
    actions: Option<proto::MessageActions>,
    random_id: i64,
    /// A card's interaction and form, registered once it is posted.
    card: Option<(InteractionId, Option<QuestionForm>)>,
    #[serde(default)]
    closed: bool,
    /// Already the plain-text form of an item Inline refused once.
    #[serde(default)]
    fallback: bool,
}

/// An input the harness may or may not have.
#[derive(Clone, Copy, Debug)]
struct Uncertain {
    chat_id: i64,
    message_id: i64,
    /// Left by a previous run of the bridge.
    restarted: bool,
}

struct PendingEdit {
    doc: Doc,
    due: tokio::time::Instant,
    /// Replaces the message's buttons; `None` leaves them.
    actions: Option<proto::MessageActions>,
    /// The message's last edit ("Worked for 2m"): it settles the slot.
    closing: bool,
}

struct Actor {
    agent: Arc<Agent>,
    chat_id: i64,
    /// This actor's own command channel, for tool bindings.
    commands: WeakCommandSender,
    /// Where output goes; moves into a subthread (spec §5.2).
    publication: Publication,
    /// The status card left in the parent after a move: (chat, message).
    parent_card: Option<(i64, i64)>,
    /// What the parent card shows, so a status update can redraw it.
    parent_card_text: Option<(ParentCard, i64)>,
    agent_session_id: Arc<AtomicI64>,
    native: Option<ProviderSessionId>,
    /// `native` came from v1 and Inline does not know it yet.
    native_from_v1: bool,
    hold: HoldMachine,
    session: Option<Arc<dyn Session>>,
    /// Behind a mutex only so the actor is `Sync`; polled through `get_mut`.
    events: Option<std::sync::Mutex<EventStream>>,
    /// A session opened by a held-elsewhere probe, used by the next Acquire.
    probe: Option<Arc<dyn Session>>,
    /// Inputs waiting for delivery or kept pending, by ID.
    inputs: HashMap<InputId, (Input, PendingInput, i64)>,
    /// Inputs kept pending after a release, offered at the next acquisition.
    retained: Vec<PendingInput>,
    /// Inputs this bridge is taking out of the native queue.
    removing: HashSet<InputId>,
    paused: bool,
    stopping: bool,
    turn: Option<TurnId>,
    turn_started: Option<i64>,
    waiting: Option<(proto::AgentWaitingReason, i64)>,
    live: inline_agent_bridge::harness::LiveWork,
    renderer: Renderer,
    cards: HashMap<i64, Card>,
    card_by_interaction: HashMap<InteractionId, i64>,
    release_card: Option<i64>,
    offers: HashMap<InputId, i64>,
    slots: HashMap<u32, i64>,
    edits: HashMap<u32, PendingEdit>,
    /// The state last published, without its revision and time, so any
    /// published change (queue count, attention) is sent again.
    reported: Option<proto::AgentSessionState>,
    /// When the "working" compose action is next repeated; `None` while it
    /// is not shown.
    working_due: Option<tokio::time::Instant>,
    phase: watch::Sender<WorkPhase>,
    update_busy: crate::bridge::update_activity::BusyKey,
    started_ms: u64,
    /// Messages observed since the agent last took input (spec §5.1).
    passive: PassiveBatch,
    /// The Inline thread's title, once known.
    title: Option<String>,
    /// The native session still needs `title`.
    rename_pending: bool,
    /// This thread's model, reasoning and permissions.
    settings: SettingsChange,
    /// `settings` changed since the native session last took them.
    settings_pending: bool,
    /// Unaddressed messages waiting for a quiet, idle moment (spec §5.4).
    consider: ConsiderQueue,
    consider_lines: HashMap<i64, String>,
    /// Answers and cards that could not be posted yet, retried under the
    /// same random ID until Inline takes them.
    outbox: VecDeque<Outgoing>,
    /// The turn whose output is being rendered, for the answer's identity.
    rendering_turn: Option<TurnId>,
    /// The first input of the latest turn: what `/undo` rewinds to.
    last_turn_input: Option<InputId>,
    /// Inputs whose delivery was unknown, until the session settles them.
    uncertain: HashMap<InputId, Uncertain>,
    /// Ledger states not saved yet, written again with the next update.
    unsaved: std::sync::Mutex<HashMap<InputId, InputState>>,
    /// Group input → its message, for the answer to reply to.
    answer_replies: HashMap<InputId, i64>,
    /// The message the next final answer replies to: the latest group input
    /// the harness took.
    answer_to: Option<i64>,
}

impl Actor {
    async fn run(mut self, mut rx: mpsc::Receiver<AdmittedCommand>) {
        let mut tick = tokio::time::interval(TICK);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            let next_edit = self.edits.values().map(|edit| edit.due).min();
            let next_working = self.working_due;
            tokio::select! {
                command = rx.recv() => {
                    let Some(command) = command else { break };
                    let AdmittedCommand { command, _lease } = command;
                    self.command(command).await;
                    self.publish_phase();
                }
                envelope = next_envelope(&mut self.events), if !crate::bridge::update_activity::global().draining() => match envelope {
                    Some(envelope) => {
                        // Native events can arrive with an idle session attached.
                        // Hold them across a cancelled drain rather than drop them.
                        let lease = loop {
                            if let Some(lease) = crate::bridge::update_activity::global().maintenance() { break lease; }
                            tokio::time::sleep(Duration::from_millis(100)).await;
                        };
                        self.envelope(envelope).await;
                        self.publish_phase();
                        drop(lease);
                    },
                    None => {
                        // The stream ended: the process exited or the
                        // connection closed.
                        self.events = None;
                        self.session = None;
                        self.event(HoldEvent::Detached).await;
                    }
                },
                _ = tick.tick() => {
                    let Some(_tick_activity) = crate::bridge::update_activity::global().maintenance() else { continue; };
                    self.flush_outbox().await;
                    self.event(HoldEvent::Tick).await;
                    self.consider_now().await;
                    self.publish_phase();
                }
                _ = sleep_until(next_edit) => self.flush_edits(false).await,
                _ = sleep_until(next_working) => {}
            }
            self.publish_phase();
            self.sync_working().await;
        }
        log::debug!(target: "inline::bridge::v2", "chat={} work stopped", self.chat_id);
    }

    // ---------------------------------------------------------------
    // Commands
    // ---------------------------------------------------------------

    async fn command(&mut self, command: Command) {
        match command {
            Command::Input {
                input,
                pending,
                message_id,
                reply_to: Some(card),
                ..
            } if self.cards.get(&card).is_some_and(|open| {
                open.form.as_ref().is_some_and(|form| {
                    render::pickable(form) && render::takes_reply(form, open.answered.len())
                })
            }) =>
            {
                let (interaction, field) = {
                    let open = &self.cards[&card];
                    (open.interaction.to_string(), open.answered.len())
                };
                let answer = input.content.text.trim().to_owned();
                let toast = self
                    .pick(card, pending.sender.0, &interaction, field, answer)
                    .await;
                self.mark(&input.id, InputState::Consumed);
                if let Some(toast) = toast {
                    self.reply(message_id, &toast).await;
                }
            }
            Command::Input {
                input,
                pending,
                message_id,
                answer_reply,
                ..
            } => {
                // Direct input restarts paused work (spec §4.5) and answers
                // anything the speak gate was weighing.
                self.paused = false;
                self.consider.supersede();
                self.consider_lines.clear();
                if answer_reply {
                    self.answer_replies.insert(input.id.clone(), message_id);
                }
                self.inputs
                    .insert(input.id.clone(), (*input, pending.clone(), message_id));
                self.event(HoldEvent::AcquireRequested {
                    input: Some(pending),
                })
                .await;
            }
            Command::Passive { message } => self.passive.push(message),
            Command::Control {
                control,
                actor,
                reply,
            } => {
                let toast = self.control(control, actor).await;
                let _ = reply.send(toast);
            }
            Command::Action {
                message_id,
                actor,
                data,
                reply,
            } => {
                let toast = self.action(message_id, actor, data).await;
                let _ = reply.send(toast);
            }
            Command::Form {
                message_id,
                actor,
                values,
                reply,
            } => {
                let toast = self.form(message_id, actor, &values).await;
                let _ = reply.send(toast);
            }
            Command::Consider { message_id, line } => {
                self.consider.push(message_id, now_ms());
                self.consider_lines.insert(message_id, line);
            }
            Command::SetMode(mode) => self.renderer.set_mode(mode),
            Command::Session { op, reply } => {
                let toast = self.session_op(op).await;
                let _ = reply.send(toast);
            }
            Command::Folder { folder, reply } => {
                let _ = reply.send(self.set_folder(folder));
            }
            Command::Title(title) => {
                if self.title.as_deref() != Some(title.as_str()) {
                    self.title = Some(title);
                    self.rename_pending = true;
                    self.sync_title().await;
                }
            }
            Command::Reconcile { inputs } => {
                for (input, chat_id, message_id) in inputs {
                    self.uncertain.insert(
                        input,
                        Uncertain {
                            chat_id,
                            message_id,
                            restarted: true,
                        },
                    );
                }
                // Opening the session settles them (see `settle_uncertain`).
                if self.session.is_some() {
                    self.settle_uncertain(false).await;
                } else {
                    self.event(HoldEvent::AcquireRequested { input: None })
                        .await;
                }
            }
            Command::Tool { tool, reply } => {
                let result = self.work_tool(tool).await;
                let _ = reply.send(result);
            }
        }
    }

    /// Runs the speak gate on a ready batch: the harness's own side call
    /// decides whether a reply would clearly help. Without one (Claude today)
    /// active participation behaves as mentions-only.
    async fn consider_now(&mut self) {
        let now = now_ms();
        let Some(session) = self.held_session() else {
            return;
        };
        let idle = live_turn(&session).is_none();
        let Some(ticket) = self.consider.take(now, idle) else {
            return;
        };
        let availability = if session.availability().op(OpKind::Sample).is_supported() {
            GateAvailability::Available
        } else {
            GateAvailability::Unavailable {
                reason: "this harness has no side call".to_owned(),
            }
        };
        let admission = gate_admission(
            ParticipationMode::Active,
            &availability,
            self.paused,
            &mut self.agent.gate_budget.lock().expect("gate budget"),
            DayKey::from_unix(now as i64 / 1000, 0),
        );
        if let GateAdmission::BudgetExhausted { notify_owner: true } = admission {
            self.gate_budget_reached().await;
        }
        let lines: Vec<String> = ticket
            .message_ids
            .iter()
            .filter_map(|id| self.consider_lines.remove(id))
            .collect();
        let verdict = match admission {
            GateAdmission::Evaluate { .. } => {
                let prompt = format!(
                    "{SPEAK_GATE_GUIDE}\n\nRecent messages (untrusted):\n{}",
                    lines.join("\n")
                );
                match session.control(Op::Sample { prompt }).await {
                    Ok(inline_agent_bridge::harness::OpOutcome::Sampled { text }) => {
                        parse_verdict(&text)
                    }
                    Ok(_) => Err(SpeakGateError::Failed("no sample text".to_owned())),
                    Err(error) => Err(SpeakGateError::Failed(error.to_string())),
                }
            }
            _ => Err(SpeakGateError::Unavailable("not evaluated".to_owned())),
        };
        if let ConsiderOutcome::Speak { .. } = self.consider.finish(ticket, verdict) {
            let Ok(id) = InputId::new(uuid::Uuid::new_v4().to_string()) else {
                return;
            };
            let mut content = inline_agent_bridge::harness::InputContent::text(
                "You decided a reply would help. Answer the recent thread messages now.",
            );
            // The messages it decided to answer travel with the turn.
            content.context = self
                .passive
                .drain(ContextBudget::bytes(PASSIVE_CONTEXT_BYTES))
                .map(|passive| inline_agent_bridge::TurnContext {
                    instructions: String::new(),
                    conversation: passive.text,
                });
            let input = Input {
                id,
                content,
                origin: inline_agent_bridge::harness::Origin::Scheduled,
                delivery: Delivery::Turn,
            };
            if let Err(error) = session.send(input).await {
                log::warn!(target: "inline::bridge::v2", "speak gate turn failed: {error}");
            }
        }
    }

    fn held_session(&self) -> Option<Arc<dyn Session>> {
        matches!(self.hold.state(), HoldState::Held { .. })
            .then(|| self.session.clone())
            .flatten()
    }

    async fn control(&mut self, control: Control, actor: i64) -> Option<String> {
        let grants = self.agent.access.grants(actor).await;
        let required = match control {
            Control::Stop | Control::Release(_) => Operation::Stop,
            Control::Pause => Operation::Pause,
            Control::Resume => Operation::Resume,
        };
        if !grants.permits(required) {
            return Some(NO_ACCESS.to_owned());
        }
        match control {
            Control::Stop => self.stop(false).await,
            Control::Pause => self.stop(true).await,
            Control::Resume => self.resume().await,
            Control::Release(cause) => {
                self.event(HoldEvent::ReleaseRequested {
                    request: ReleaseRequest::new(cause, Some(UserId(actor))),
                })
                .await;
                None
            }
        }
    }

    /// Stop the running turn. Pause also takes this bridge's queued input out
    /// of the native queue first, so nothing runs until a resume.
    async fn stop(&mut self, pause: bool) -> Option<String> {
        let Some(session) = self.held_session() else {
            if pause {
                self.paused = true;
                self.report().await;
                return None;
            }
            return Some("Nothing is running.".to_owned());
        };
        if pause {
            self.paused = true;
            let live = session.live_work();
            for queued in &live.queued {
                let Some(input) = queued.input.clone() else {
                    continue;
                };
                if !self.inputs.contains_key(&input) {
                    // Someone else's queued input (a terminal); leave it.
                    continue;
                }
                self.removing.insert(input.clone());
                match session
                    .control(Op::Queue {
                        action: QueueOp::Remove {
                            entry: queued.entry.clone(),
                        },
                    })
                    .await
                {
                    Ok(_) => {
                        self.mark(&input, InputState::Pending);
                    }
                    // It ran before it could be held; nothing to keep.
                    Err(OpError::NotQueued) => {
                        self.removing.remove(&input);
                    }
                    Err(error) => {
                        self.removing.remove(&input);
                        return Some(format!(
                            "Could not hold queued input, so the agent was not paused: {error}"
                        ));
                    }
                }
            }
        }
        if live_turn(&session).is_some() {
            self.stopping = true;
            self.report().await;
            if let Err(error) = session
                .control(Op::Interrupt {
                    cancel_queued: false,
                })
                .await
            {
                self.stopping = false;
                self.report().await;
                return Some(format!("Could not stop: {error}"));
            }
        } else if !pause {
            return Some("Nothing is running.".to_owned());
        }
        self.report().await;
        None
    }

    /// Resume paused work: input kept pending runs again, in order.
    async fn resume(&mut self) -> Option<String> {
        self.paused = false;
        let mut kept: Vec<(i64, PendingInput)> = self
            .inputs
            .iter()
            .filter(|(id, _)| {
                self.agent
                    .ledger
                    .get(id.as_str())
                    .ok()
                    .flatten()
                    .is_some_and(|record| record.state == InputState::Pending)
            })
            .map(|(_, (_, pending, message_id))| (*message_id, pending.clone()))
            .collect();
        kept.sort_by_key(|(message_id, _)| *message_id);
        if kept.is_empty() {
            // Native input queued from elsewhere starts again too.
            if let Some(session) = self.held_session()
                && !session.live_work().queued.is_empty()
                && session.availability().op(OpKind::QueueStart).is_supported()
                && let Err(error) = session
                    .control(Op::Queue {
                        action: QueueOp::Start,
                    })
                    .await
            {
                return Some(format!("Could not resume the queue: {error}"));
            }
            self.report().await;
            return None;
        }
        for (_, pending) in kept {
            self.event(HoldEvent::AcquireRequested {
                input: Some(pending),
            })
            .await;
        }
        None
    }

    async fn action(&mut self, message_id: i64, actor: i64, data: ActionData) -> Option<String> {
        let grants = self.agent.access.grants(actor).await;
        match data {
            // The main loop answers these; they never reach a work.
            ActionData::ExtendLoop | ActionData::RaiseGateBudget => None,
            ActionData::Pick { i, f, o } => {
                let label = self
                    .cards
                    .get(&message_id)
                    .and_then(|card| card.form.as_ref())
                    .and_then(|form| form.fields.get(f))
                    .and_then(|field| match &field.input {
                        FieldInput::Select { options, .. } => options.get(o),
                        _ => None,
                    })
                    .map(|option| option.label.clone());
                let Some(label) = label else {
                    return Some(NOT_PENDING.to_owned());
                };
                self.pick(message_id, actor, &i, f, label).await
            }
            ActionData::Decision { i, d } => {
                let card = self.cards.get(&message_id).cloned()?;
                if card.interaction.as_str() != i {
                    return Some(NOT_PENDING.to_owned());
                }
                let permitted = if card.approval {
                    grants.permits(Operation::Approve)
                } else {
                    grants.any()
                };
                if !permitted {
                    return Some(NO_ACCESS.to_owned());
                }
                let Ok(decision) = inline_agent_bridge::harness::DecisionId::new(d) else {
                    return Some("That choice is not available.".to_owned());
                };
                self.answer(
                    card.interaction,
                    InteractionResponse::Decision {
                        decision,
                        message: None,
                    },
                    actor,
                )
                .await
            }
            ActionData::ReleaseConfirm | ActionData::ReleaseCancel | ActionData::ReleaseRetry => {
                if !grants.permits(Operation::Stop) {
                    return Some(NO_ACCESS.to_owned());
                }
                if self.release_card != Some(message_id) {
                    return Some(NOT_PENDING.to_owned());
                }
                let event = match data {
                    ActionData::ReleaseConfirm => HoldEvent::ReleaseConfirmed,
                    ActionData::ReleaseCancel => HoldEvent::ReleaseCancelled,
                    _ => HoldEvent::ReleaseRetry,
                };
                self.close_release_card().await;
                self.event(event).await;
                None
            }
            // Older progress messages still carry this button.
            ActionData::FullOutput => Some("That output is in the session history.".to_owned()),
            ActionData::ForkHere => {
                if !grants.permits(Operation::StartWork) {
                    return Some(NO_ACCESS.to_owned());
                }
                self.event(HoldEvent::ForkHere).await;
                None
            }
            ActionData::Pending { i, run } => {
                let Ok(id) = InputId::new(i) else {
                    return Some(NOT_PENDING.to_owned());
                };
                let Some((_, pending, _)) = self.inputs.get(&id).cloned() else {
                    return Some(NOT_PENDING.to_owned());
                };
                // Only the sender decides about their own message.
                if pending.sender.0 != actor && actor != self.agent.owner_user_id {
                    return Some(NO_ACCESS.to_owned());
                }
                if let Some(card) = self.offers.remove(&id) {
                    let text = if run { "Running it now." } else { "Discarded." };
                    let _ = api::edit_doc(
                        &self.agent.bot,
                        self.chat_id,
                        card,
                        &paragraph(text),
                        Some(proto::MessageActions::default()),
                    )
                    .await;
                }
                if run {
                    self.event(HoldEvent::AcquireRequested {
                        input: Some(pending),
                    })
                    .await;
                } else {
                    self.inputs.remove(&id);
                    self.mark(&id, InputState::Discarded);
                }
                None
            }
        }
    }

    /// One answer on a card that asks its questions one at a time: the next
    /// question replaces it, and the last one answers the harness.
    async fn pick(
        &mut self,
        message_id: i64,
        actor: i64,
        interaction: &str,
        field: usize,
        answer: String,
    ) -> Option<String> {
        if !self.agent.access.grants(actor).await.any() {
            return Some(NO_ACCESS.to_owned());
        }
        let Some(card) = self.cards.get_mut(&message_id) else {
            return Some(NOT_PENDING.to_owned());
        };
        let Some(form) = card.form.clone() else {
            return Some(NOT_PENDING.to_owned());
        };
        // A second tap on an answered question, or a stale card.
        if card.interaction.as_str() != interaction || card.answered.len() != field {
            return Some(NOT_PENDING.to_owned());
        }
        card.answered.push(answer);
        let (chat, interaction, answered) =
            (card.chat, card.interaction.clone(), card.answered.clone());
        if answered.len() < form.fields.len() {
            let doc = render::pick_card(&self.agent.agent_name, &form, answered.len(), &answered);
            let actions = pick_actions(&interaction, &form, answered.len());
            if self.edit_in(chat, message_id, &doc, actions).await {
                return None;
            }
            if let Some(card) = self.cards.get_mut(&message_id) {
                card.answered.pop();
            }
            return Some("Could not show the next question. Try again.".to_owned());
        }
        let answers = form
            .fields
            .iter()
            .zip(answered)
            .filter_map(|(field, value)| {
                Some(FieldAnswer {
                    field: FieldId::new(field.id.as_str()).ok()?,
                    values: vec![value],
                })
            })
            .collect();
        let toast = self
            .answer(interaction, InteractionResponse::Answers { answers }, actor)
            .await;
        if toast.is_some()
            && let Some(card) = self.cards.get_mut(&message_id)
        {
            card.answered.pop();
        }
        toast
    }

    async fn form(&mut self, message_id: i64, actor: i64, values: &[FormValue]) -> Option<String> {
        let grants = self.agent.access.grants(actor).await;
        if !grants.any() {
            return Some(NO_ACCESS.to_owned());
        }
        let Some(card) = self.cards.get(&message_id).cloned() else {
            return Some(NOT_PENDING.to_owned());
        };
        let Some(form) = card.form else {
            return Some(NOT_PENDING.to_owned());
        };
        if values.iter().any(|value| value.value.is_none()) {
            return Some("Some answers were not received. Fill in the form again.".to_owned());
        }
        self.answer(
            card.interaction,
            InteractionResponse::Answers {
                answers: form_answers(&form, values),
            },
            actor,
        )
        .await
    }

    async fn answer(
        &mut self,
        interaction: InteractionId,
        response: InteractionResponse,
        actor: i64,
    ) -> Option<String> {
        let session = self.held_session()?;
        // The card's resolution names who answered.
        let name = self.agent.names.of(actor).await;
        self.renderer.name_user(actor, name);
        match session
            .control(Op::Answer {
                interaction,
                response,
                by: UserId(actor),
            })
            .await
        {
            Ok(inline_agent_bridge::harness::OpOutcome::Accepted { native }) => {
                // Codex async questions come back as follow-up input.
                if let Some(text) = native.get("follow_up").and_then(|value| value.as_str())
                    && !text.is_empty()
                {
                    let input = Input {
                        id: InputId::new(uuid::Uuid::new_v4().to_string()).ok()?,
                        content: inline_agent_bridge::harness::InputContent::text(text),
                        origin: inline_agent_bridge::harness::Origin::Teammate {
                            user: UserId(actor),
                        },
                        delivery: match live_turn(&session) {
                            Some(turn) => Delivery::Steer {
                                expected_turn: turn,
                                priority: SteerPriority::Next,
                            },
                            None => Delivery::Turn,
                        },
                    };
                    if let Err(error) = session.send(input).await {
                        return Some(format!("The answer was recorded but not sent: {error}"));
                    }
                }
                None
            }
            Ok(_) => None,
            Err(OpError::InteractionNotPending) => Some(NOT_PENDING.to_owned()),
            Err(error) => Some(format!("Could not send the answer: {error}")),
        }
    }

    // ---------------------------------------------------------------
    // Hold machine
    // ---------------------------------------------------------------

    async fn event(&mut self, event: HoldEvent) {
        let mut queue = VecDeque::from([event]);
        while let Some(event) = queue.pop_front() {
            if !matches!(event, HoldEvent::Tick | HoldEvent::Activity { .. }) {
                log::debug!(target: "inline::bridge::v2", "chat={} hold event={event:?}", self.chat_id);
            }
            let effects = self.hold.handle(event, now_ms());
            for effect in &effects {
                log::debug!(target: "inline::bridge::v2", "chat={} hold effect={effect:?}", self.chat_id);
            }
            for effect in effects {
                if let Some(follow) = self.effect(effect).await {
                    queue.push_back(follow);
                }
            }
        }
        self.report().await;
    }

    async fn effect(&mut self, effect: HoldEffect) -> Option<HoldEvent> {
        match effect {
            HoldEffect::Acquire => self.acquire().await,
            HoldEffect::Deliver { inputs } => {
                for pending in inputs {
                    self.deliver(pending).await;
                }
                let retained = std::mem::take(&mut self.retained);
                self.offer(retained).await;
                None
            }
            HoldEffect::OfferPending { inputs } => {
                self.offer(inputs).await;
                None
            }
            HoldEffect::ShowHeldElsewhere { by } => {
                let actions =
                    button_rows(&[("Fork here", ActionData::ForkHere, ActionStyle::Default)]);
                self.notice_with(
                    &format!(
                        "{} is open in {}. Continue there, or fork the session here.",
                        self.agent.agent_name,
                        held_label(&by)
                    ),
                    actions,
                )
                .await;
                None
            }
            HoldEffect::ProbeHolder => self.probe().await,
            HoldEffect::ReleaseStarted { .. } => None,
            HoldEffect::ReleaseAbandoned => {
                self.close_release_card().await;
                None
            }
            HoldEffect::ConfirmRelease { live, .. } => {
                let mut parts = Vec::new();
                if live.turn.is_some() {
                    parts.push("stop the running turn".to_owned());
                }
                if !live.queued.is_empty() {
                    parts.push(format!(
                        "keep {} queued message(s) pending in Inline",
                        live.queued.len()
                    ));
                }
                if !live.interactions.is_empty() {
                    parts.push(format!(
                        "cancel {} open request(s)",
                        live.interactions.len()
                    ));
                }
                if !live.children.is_empty() {
                    parts.push(format!("stop {} background task(s)", live.children.len()));
                }
                let text = format!(
                    "Releasing {} will {}.",
                    self.agent.agent_name,
                    parts.join(", ")
                );
                let actions = button_rows(&[
                    (
                        "Release",
                        ActionData::ReleaseConfirm,
                        ActionStyle::Destructive,
                    ),
                    ("Cancel", ActionData::ReleaseCancel, ActionStyle::Default),
                ]);
                self.release_card = self.notice_with(&text, actions).await;
                None
            }
            HoldEffect::Step(step) => {
                let outcome = self.step(&step).await;
                Some(HoldEvent::StepFinished { step, outcome })
            }
            HoldEffect::ReleaseFenced { failed, .. } => {
                let reason = match &failed.outcome {
                    ReleaseStepOutcome::Failed { reason }
                    | ReleaseStepOutcome::Unknown { reason } => reason.clone(),
                    ReleaseStepOutcome::Done => String::new(),
                };
                let text = format!(
                    "The release stopped: {} did not finish ({reason}). Nothing more is sent until you retry or cancel.",
                    step_label(&failed.step)
                );
                let actions = button_rows(&[
                    ("Retry", ActionData::ReleaseRetry, ActionStyle::Primary),
                    (
                        "Cancel release",
                        ActionData::ReleaseCancel,
                        ActionStyle::Default,
                    ),
                ]);
                self.release_card = self.notice_with(&text, actions).await;
                None
            }
            HoldEffect::Unsubscribe | HoldEffect::CloseStdin { .. } => {
                let Some(session) = self.session.clone() else {
                    return Some(HoldEvent::Detached);
                };
                match session.release().await {
                    Ok(released) => release_event(&released),
                    Err(error) => {
                        self.notice(&format!("The release did not complete: {error}"))
                            .await;
                        None
                    }
                }
            }
            HoldEffect::Kill => {
                // Dropping the last handle stops the process (its supervisor
                // closes stdin, then kills and reaps it).
                self.session = None;
                self.events = None;
                self.unbind_tools();
                Some(HoldEvent::Detached)
            }
            HoldEffect::Released { cause, receipts } => {
                self.released(cause, &receipts).await;
                None
            }
            HoldEffect::PendingNotDelivered { inputs } => {
                for pending in &inputs {
                    self.mark(&pending.id, InputState::Pending);
                }
                if !inputs.is_empty() {
                    self.notice(&format!(
                        "{} message(s) stay pending in Inline; you'll be offered to run them next time.",
                        inputs.len()
                    ))
                    .await;
                }
                self.retained.extend(inputs);
                None
            }
            HoldEffect::Fork { .. } => match self.fork_here().await {
                Ok(()) => Some(HoldEvent::Acquired),
                Err(error) => {
                    self.notice(&format!("Could not fork the session: {error}"))
                        .await;
                    Some(HoldEvent::Detached)
                }
            },
            HoldEffect::Lost => {
                self.session = None;
                self.events = None;
                self.turn = None;
                self.unbind_tools();
                self.notice(&format!(
                    "{} stopped unexpectedly. Your next message starts it again.",
                    self.agent.agent_name
                ))
                .await;
                None
            }
        }
    }

    /// Fork here: a new session belongs in a new thread (as with `/new`), so
    /// the fork continues in a subthread of this one, and this thread keeps
    /// the original session, still held elsewhere.
    async fn fork_here(&mut self) -> Result<(), String> {
        let native = self.native.clone().ok_or("there is no session to fork")?;
        let session = self
            .open_session(OpenMode::Fork {
                session: native,
                at: None,
            })
            .await
            .map_err(|error| error.to_string())?;
        let created = self
            .agent
            .bot
            .create_reply_thread(CreateReplyThreadRequest {
                parent_chat_id: InlineId::new(self.chat_id),
                parent_message_id: None,
                title: Some(format!("{} fork", self.agent.agent_name)),
                description: None,
                emoji: None,
                participants: Vec::new(),
                agent_context: None,
            })
            .await
            .map_err(|error| format!("Inline could not create the thread ({error})"))?;
        let from = self.chat_id;
        let destination = created.chat_id.get();
        self.agent
            .ledger
            .copy_thread(from, destination)
            .map_err(|error| format!("Could not retain thread settings: {error}"))?;
        self.chat_id = destination;
        self.publication = Publication::new(ChatId(destination));
        self.edits.clear();
        self.slots.clear();
        self.answer_to = None;
        self.answer_replies.clear();
        self.adopt(session, true)
            .await
            .map_err(|error| error.to_string())?;
        let _ = self.agent.moves.send((from, destination));
        let link = format!("inline://chat?id={destination}");
        let random_id = rand::random::<i64>().abs().max(1);
        if let Ok(id) = api::send_markdown(
            &self.agent.bot,
            from,
            None,
            &format!(
                "Forked into [a new thread]({link}); the session here stays where it is held."
            ),
            random_id,
        )
        .await
        {
            self.remember(id);
        }
        Ok(())
    }

    async fn acquire(&mut self) -> Option<HoldEvent> {
        // A session the holder probe already resumed is adopted like any
        // other, with its tools, title and settings.
        if let Some(session) = self.probe.take() {
            return match self.adopt(session, false).await {
                Ok(()) => Some(HoldEvent::Acquired),
                Err(OpenFailure::HeldElsewhere(by)) => Some(HoldEvent::AcquireConflict { by }),
                Err(OpenFailure::Other(message)) => {
                    self.notice(&format!(
                        "{} could not start: {message}",
                        self.agent.agent_name
                    ))
                    .await;
                    Some(HoldEvent::Detached)
                }
            };
        }
        let mode = match self.native.clone() {
            Some(session) => OpenMode::Resume { session },
            None => OpenMode::Start,
        };
        match self.open(mode).await {
            Ok(()) => Some(HoldEvent::Acquired),
            Err(OpenFailure::HeldElsewhere(by)) => Some(HoldEvent::AcquireConflict { by }),
            Err(OpenFailure::Other(message)) => {
                self.notice(&format!(
                    "{} could not start: {message}",
                    self.agent.agent_name
                ))
                .await;
                Some(HoldEvent::Detached)
            }
        }
    }

    async fn probe(&mut self) -> Option<HoldEvent> {
        let native = self.native.clone()?;
        match self
            .open_session(OpenMode::Resume { session: native })
            .await
        {
            Ok(session) => {
                self.probe = Some(session);
                Some(HoldEvent::ElsewhereFreed)
            }
            Err(_) => None,
        }
    }

    async fn open(&mut self, mode: OpenMode) -> Result<(), OpenFailure> {
        if self.native_from_v1 && matches!(mode, OpenMode::Resume { .. }) {
            return self.open_from_v1(mode).await;
        }
        let fresh = !matches!(mode, OpenMode::Resume { .. });
        let session = match self.open_session(mode.clone()).await {
            // The native session is gone. A new session belongs in a new
            // thread, so this one says how to start one.
            Err(OpenFailure::Other(message))
                if matches!(mode, OpenMode::Resume { .. }) && message == NOT_FOUND =>
            {
                return Err(OpenFailure::Other(
                    "its session is no longer on this machine. Start a fresh thread with /new"
                        .to_owned(),
                ));
            }
            other => other?,
        };
        self.adopt(session, fresh).await
    }

    /// The session v1 left for this thread goes on here. One that does not
    /// reopen, or that Inline already gave another thread, is replaced by a
    /// fresh session rather than asking for /new: the thread never had a v2
    /// session to lose. ACP bindings are preserved on every failure instead.
    /// A session held elsewhere still waits for its holder.
    async fn open_from_v1(&mut self, mode: OpenMode) -> Result<(), OpenFailure> {
        let failure = match self.open_session(mode).await {
            Ok(session) => match self.adopt(session, false).await {
                Ok(()) => return Ok(()),
                Err(OpenFailure::Other(message)) => message,
                Err(held) => return Err(held),
            },
            Err(OpenFailure::Other(message)) => message,
            Err(held) => return Err(held),
        };
        if matches!(
            self.agent.vocabulary,
            Vocabulary::OpenCode | Vocabulary::Amp
        ) {
            // Changing OpenCode application generations does not prove its
            // old session IDs migrated. Preserve the binding on every failure.
            return Err(OpenFailure::Other(format!(
                "the saved {} session could not be resumed: {failure}. Its binding is preserved. Retry after checking the agent, or use /new for a fresh conversation",
                self.agent.agent_name
            )));
        }
        log::warn!(
            target: "inline::bridge::v2",
            "v1 session for chat {} did not reopen, starting a fresh one: {failure}",
            self.chat_id
        );
        self.native = None;
        self.native_from_v1 = false;
        let session = self.open_session(OpenMode::Start).await?;
        self.adopt(session, true).await
    }

    /// Makes an opened session this work's: records it in Inline, binds its
    /// tools, settles inputs whose delivery was unknown, and brings its
    /// title and settings up to date.
    async fn adopt(&mut self, session: Arc<dyn Session>, fresh: bool) -> Result<(), OpenFailure> {
        let native = session.key().session.clone();
        if fresh || self.native_from_v1 || self.native.as_ref() != Some(&native) {
            self.connect(&native).await.map_err(OpenFailure::Other)?;
            // A fork or a fresh start replaces the work's session.
            self.unbind_tools();
            self.native_from_v1 = false;
        }
        self.native = Some(native);
        self.attach(session);
        if let (Some(tools), Some(native)) = (&self.agent.tools, &self.native) {
            tools.bind(native, self.chat_id, self.commands.clone(), self.folder());
        }
        self.settle_uncertain(fresh).await;
        // A new session takes the thread's title; a rename made while the
        // session was let go reaches it now.
        if fresh && self.title.is_none() {
            self.title = self
                .agent
                .bot
                .chat_state(InlineId::new(self.chat_id))
                .await
                .ok()
                .and_then(|state| state.dialog)
                // A DM's title is the person, not the work.
                .filter(|dialog| dialog.peer_user_id.is_none())
                .and_then(|dialog| dialog.title)
                .filter(|title| !title.trim().is_empty());
            self.rename_pending = self.title.is_some();
        }
        self.sync_title().await;
        self.sync_settings().await;
        Ok(())
    }

    /// Inputs whose delivery was unknown are settled when a session opens:
    /// a resumed session confirms what it consumed or queued. Missing history
    /// is not evidence that an input never ran. Nothing is sent again.
    async fn settle_uncertain(&mut self, fresh: bool) {
        if self.uncertain.is_empty() {
            return;
        }
        // What the session reported while opening is already buffered.
        while let Some(Some(envelope)) = next_envelope(&mut self.events).now_or_never() {
            Box::pin(self.envelope(envelope)).await;
        }
        let queued: Vec<InputId> = self
            .session
            .as_ref()
            .map(|session| session.live_work().queued)
            .unwrap_or_default()
            .into_iter()
            .filter_map(|queued| queued.input)
            .collect();
        for (input, uncertain) in std::mem::take(&mut self.uncertain) {
            let (state, text) = if queued.contains(&input) {
                (InputState::Accepted, None)
            } else {
                (
                    InputState::Unknown,
                    Some(format!(
                        "{} could not confirm whether this ran{}. It may already have run; check its native session before retrying.",
                        self.agent.agent_name,
                        if fresh {
                            ": its previous session is gone"
                        } else {
                            ""
                        }
                    )),
                )
            };
            self.mark(&input, state);
            if let Some(text) = text {
                self.reply_in(uncertain.chat_id, uncertain.message_id, &text)
                    .await;
            }
        }
    }

    /// An input whose delivery was unknown is settled by the session: it ran.
    async fn settled(&mut self, input: &InputId) {
        if let Some(uncertain) = self.uncertain.remove(input)
            && uncertain.restarted
        {
            self.reply_in(
                uncertain.chat_id,
                uncertain.message_id,
                &format!(
                    "This reached {} before the restart. Any reply it gave then is in the session.",
                    self.agent.agent_name
                ),
            )
            .await;
        }
    }

    /// Where this work's session opens: the thread's folder, else the
    /// agent's.
    fn folder(&self) -> PathBuf {
        self.settings
            .folder
            .clone()
            .unwrap_or_else(|| self.agent.folder.clone())
    }

    fn set_folder(&mut self, folder: PathBuf) -> Result<(), String> {
        if self.native.is_some() || self.session.is_some() {
            let current = self.folder();
            return Err(settings::folder_fixed(&current.file_name().map_or_else(
                || current.display().to_string(),
                |name| name.to_string_lossy().into_owned(),
            )));
        }
        self.settings.folder = Some(folder);
        Ok(())
    }

    async fn open_session(&self, mode: OpenMode) -> Result<Arc<dyn Session>, OpenFailure> {
        self.agent
            .harness
            .open(OpenSpec {
                mode,
                folder: self.folder(),
                settings: settings::effective(&self.settings),
                instructions: Some(trusted_guide(GuideFacts {
                    bot_user_id: self.agent.bot_user_id,
                    owner_user_id: self.agent.owner_user_id,
                    inline_tools: self.agent.tools.is_some(),
                })),
                title: None,
                after: None,
                output_mode: self.renderer.mode(),
            })
            .await
            .map_err(|error| match error {
                OpenError::HeldElsewhere(by) => OpenFailure::HeldElsewhere(by),
                OpenError::NotFound => OpenFailure::Other(NOT_FOUND.to_owned()),
                other => OpenFailure::Other(other.to_string()),
            })
    }

    /// Records the native session as this thread's work (owner-authenticated).
    async fn connect(&self, native: &ProviderSessionId) -> Result<(), String> {
        let result = self
            .agent
            .owner
            .connect(proto::ConnectAgentSessionInput {
                peer_id: Some(chat_peer(self.chat_id)),
                bot_user_id: self.agent.bot_user_id,
                provider: self.agent.provider as i32,
                instance_ref: self.agent.installation_id.clone(),
                session_ref: native.to_string(),
                workspace_label: self
                    .folder()
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned()),
                project_ref: self
                    .agent
                    .bound_projects
                    .lock()
                    .ok()
                    .and_then(|projects| projects.get(&self.chat_id).cloned()),
                ..Default::default()
            })
            .await?;
        if result.state == proto::ConnectAgentSessionState::ConnectedElsewhere as i32 {
            return Err("this session already belongs to another thread".to_owned());
        }
        let id = result
            .agent_session
            .map(|session| session.id)
            .ok_or("Inline did not return the work")?;
        self.agent_session_id.store(id, Ordering::Release);
        Ok(())
    }

    fn attach(&mut self, session: Arc<dyn Session>) {
        self.events = Some(std::sync::Mutex::new(session.events()));
        self.session = Some(session);
    }

    async fn deliver(&mut self, pending: PendingInput) {
        let Some((mut input, _, message_id)) = self.inputs.get(&pending.id).cloned() else {
            return;
        };
        // Grants are rechecked after any wait (spec §7).
        if !self
            .agent
            .access
            .grants(pending.sender.0)
            .await
            .permits(pending.required)
        {
            self.inputs.remove(&pending.id);
            self.mark(&pending.id, InputState::Failed);
            self.reply(
                message_id,
                "This was not sent: the sender no longer has access to this agent.",
            )
            .await;
            return;
        }
        let Some(session) = self.session.clone() else {
            self.retained.push(pending);
            return;
        };
        // What the thread said since the agent last took input travels with
        // it as untrusted context, kept apart from the author's words. Every
        // harness and version keeps that apart; a separate passive message
        // would start a turn on older Claude Code.
        if let Some(passive) = self
            .passive
            .drain(ContextBudget::bytes(PASSIVE_CONTEXT_BYTES))
        {
            let context =
                input
                    .content
                    .context
                    .get_or_insert_with(|| inline_agent_bridge::TurnContext {
                        instructions: String::new(),
                        conversation: String::new(),
                    });
            if !context.conversation.is_empty() {
                context.conversation.push_str("\n\n");
            }
            context.conversation.push_str(&passive.text);
        }
        if !matches!(input.delivery, Delivery::Queue | Delivery::Passive) {
            input.delivery = match live_turn(&session) {
                Some(turn) => Delivery::Steer {
                    expected_turn: turn,
                    priority: SteerPriority::Next,
                },
                None => Delivery::Turn,
            };
        }
        // Recorded as written before it is: an input the ledger cannot track
        // is never sent.
        if !self.mark(&pending.id, InputState::Sent) {
            self.inputs.remove(&pending.id);
            self.reply(
                message_id,
                &format!(
                    "This was not sent: {} could not record it on this machine. Check the disk, then send it again.",
                    self.agent.agent_name
                ),
            )
            .await;
            return;
        }
        let mut result = session.send(input.clone()).await;
        // The turn started or ended between the check and the send.
        if let Err(
            SendError::Busy { active }
            | SendError::TurnMismatch {
                active: Some(active),
            },
        ) = &result
        {
            input.delivery = Delivery::Steer {
                expected_turn: active.clone(),
                priority: SteerPriority::Next,
            };
            result = session.send(input.clone()).await;
        } else if let Err(SendError::TurnMismatch { active: None }) = &result {
            input.delivery = Delivery::Turn;
            result = session.send(input.clone()).await;
        }
        match result {
            Ok(receipt) => {
                // A bare write stays Sent until the harness shows taking it.
                if receipt.acceptance == Acceptance::Accepted {
                    self.mark(&pending.id, InputState::Accepted);
                }
                self.answer_to = self.answer_replies.remove(&pending.id);
                // The harness may report the turn a moment later. Until then
                // the delivery itself is live work, so an idle tick never
                // lets go of a session that was just given a turn.
                let mut live = session.live_work();
                if let InputDisposition::Started { turn } | InputDisposition::Steered { turn } =
                    receipt.disposition
                {
                    self.turn = Some(turn.clone());
                    live.turn.get_or_insert(turn);
                }
                self.live = live.clone();
                Box::pin(self.event(HoldEvent::Activity { live })).await;
            }
            Err(SendError::Unknown(reason)) => {
                // Never resent: the session settles it, as it runs or when it
                // next opens.
                self.mark(&pending.id, InputState::Unknown);
                self.uncertain.insert(
                    pending.id.clone(),
                    Uncertain {
                        chat_id: self
                            .agent
                            .ledger
                            .get(pending.id.as_str())
                            .ok()
                            .flatten()
                            .map_or(self.chat_id, |record| record.chat_id),
                        message_id,
                        restarted: false,
                    },
                );
                self.reply(
                    message_id,
                    &format!(
                        "{} may not have received this ({reason}). It was not sent again. Check the native session before retrying.",
                        self.agent.agent_name
                    ),
                )
                .await;
            }
            Err(SendError::HeldElsewhere(by)) => {
                self.mark(&pending.id, InputState::Pending);
                self.retained.push(pending);
                Box::pin(self.event(HoldEvent::AcquireConflict { by })).await;
            }
            Err(error) => {
                self.inputs.remove(&pending.id);
                self.mark(&pending.id, InputState::Failed);
                self.reply(
                    message_id,
                    &format!("{} could not take this: {error}", self.agent.agent_name),
                )
                .await;
            }
        }
    }

    async fn offer(&mut self, inputs: Vec<PendingInput>) {
        for pending in inputs {
            let Some((_, _, message_id)) = self.inputs.get(&pending.id).cloned() else {
                continue;
            };
            if !self
                .agent
                .access
                .grants(pending.sender.0)
                .await
                .permits(pending.required)
            {
                continue;
            }
            self.mark(&pending.id, InputState::Pending);
            let actions = button_rows(&[
                (
                    "Run it",
                    ActionData::Pending {
                        i: pending.id.to_string(),
                        run: true,
                    },
                    ActionStyle::Primary,
                ),
                (
                    "Discard",
                    ActionData::Pending {
                        i: pending.id.to_string(),
                        run: false,
                    },
                    ActionStyle::Default,
                ),
            ]);
            let doc = paragraph(&format!(
                "This message is still pending for {}. Run it now?",
                self.agent.agent_name
            ));
            if let Ok(card) = api::send_doc(
                &self.agent.bot,
                self.chat_id,
                Some(message_id),
                &doc,
                actions,
                Notify::Normal,
            )
            .await
            {
                self.remember(card);
                self.offers.insert(pending.id.clone(), card);
            }
        }
    }

    async fn step(&mut self, step: &ReleaseStep) -> ReleaseStepOutcome {
        let Some(session) = self.session.clone() else {
            return ReleaseStepOutcome::Failed {
                reason: "the session is not open".to_owned(),
            };
        };
        let op = match step {
            ReleaseStep::KeepQueuedPending { queued } => {
                if let Some(input) = &queued.input {
                    self.removing.insert(input.clone());
                }
                Op::Queue {
                    action: QueueOp::Remove {
                        entry: queued.entry.clone(),
                    },
                }
            }
            ReleaseStep::CancelInteraction { interaction } => Op::Answer {
                interaction: interaction.clone(),
                response: InteractionResponse::Cancel,
                by: UserId(self.agent.owner_user_id),
            },
            ReleaseStep::InterruptTurn { .. } => Op::Interrupt {
                cancel_queued: false,
            },
            ReleaseStep::StopChild { child } => Op::StopChild {
                child: child.clone(),
            },
            // No native call cancels a wakeup; leaving one is a no-op.
            ReleaseStep::CancelWakeup { .. } | ReleaseStep::LeaveWakeup { .. } => {
                return ReleaseStepOutcome::Done;
            }
        };
        let outcome = match tokio::time::timeout(
            inline_agent_bridge::group::RELEASE_STEP_TIMEOUT,
            session.control(op),
        )
        .await
        {
            Ok(Ok(_)) => ReleaseStepOutcome::Done,
            // It ran before it could be held: nothing is left to keep.
            Ok(Err(OpError::NotQueued)) => {
                if let ReleaseStep::KeepQueuedPending { queued } = step
                    && let Some(input) = &queued.input
                {
                    self.removing.remove(input);
                }
                return ReleaseStepOutcome::Done;
            }
            Ok(Err(OpError::Unknown(reason))) => ReleaseStepOutcome::Unknown { reason },
            Ok(Err(OpError::InteractionNotPending)) => ReleaseStepOutcome::Done,
            Ok(Err(error)) => ReleaseStepOutcome::Failed {
                reason: error.to_string(),
            },
            Err(_) => ReleaseStepOutcome::Unknown {
                reason: "the harness did not answer in time".to_owned(),
            },
        };
        if let (ReleaseStep::KeepQueuedPending { queued }, ReleaseStepOutcome::Done) =
            (step, &outcome)
            && let Some(input) = &queued.input
        {
            self.mark(input, InputState::Pending);
        }
        outcome
    }

    async fn released(&mut self, cause: ReleaseCause, receipts: &[ReleaseReceipt]) {
        self.session = None;
        self.events = None;
        self.turn = None;
        // The harness confirmed the release: the session no longer acts here.
        self.unbind_tools();
        self.close_release_card().await;
        if !cause.is_explicit() {
            return;
        }
        let mut builder = DocBuilder::new();
        builder.paragraph(&format!(
            "{} is released. Nothing from Inline runs until it is mentioned again.",
            self.agent.agent_name
        ));
        let done: Vec<String> = receipts
            .iter()
            .filter(|receipt| receipt.outcome == ReleaseStepOutcome::Done)
            .map(|receipt| step_label(&receipt.step))
            .collect();
        if !done.is_empty() {
            builder.paragraph(&format!("Done: {}.", done.join(", ")));
        }
        let missed: Vec<String> = receipts
            .iter()
            .filter(|receipt| receipt.outcome != ReleaseStepOutcome::Done)
            .map(|receipt| step_label(&receipt.step))
            .collect();
        if !missed.is_empty() {
            builder.paragraph(&format!(
                "Could not confirm: {}. Check it where you continue.",
                missed.join(", ")
            ));
        }
        if let (Some(native), Some(provider)) = (&self.native, self.agent.handoff_provider()) {
            match handoff_instruction(
                provider,
                HandoffTarget::Terminal,
                native.as_str(),
                Some(&self.folder()),
            ) {
                HandoffInstruction::Command { command } => {
                    builder.paragraph("Continue in a terminal:");
                    builder.code(&command, Some("sh"));
                }
                HandoffInstruction::Url { url } => {
                    builder.paragraph(&format!("Continue in the app: {url}"));
                }
            }
        }
        self.send(&builder.finish(), None, Notify::Normal).await;
    }

    // ---------------------------------------------------------------
    // Tools that act through the work
    // ---------------------------------------------------------------

    /// Names the native session after the Inline thread (Codex
    /// `thread/name/set`, Claude `renameSession`), where the harness can.
    async fn sync_title(&mut self) {
        if !self.rename_pending {
            return;
        }
        let (Some(title), Some(session)) = (self.title.clone(), self.session.clone()) else {
            return;
        };
        if !session.availability().op(OpKind::Rename).is_supported() {
            self.rename_pending = false;
            return;
        }
        let title: String = title.chars().take(MAX_SESSION_TITLE_CHARS).collect();
        match session.control(Op::Rename { title }).await {
            Ok(_) => self.rename_pending = false,
            Err(error) => {
                log::debug!(target: "inline::bridge::v2", "rename not applied: {error}");
            }
        }
    }

    /// A native sub-agent (a Codex collab thread) acts for this work, so its
    /// tool calls resolve through this session.
    fn bind_children(&self, item: &inline_agent_bridge::harness::Item) {
        let (Some(tools), Some(native)) = (&self.agent.tools, &self.native) else {
            return;
        };
        let started = match item.update.body() {
            Some(inline_agent_bridge::harness::ItemBody::Child { child, .. }) => Some(child),
            _ => None,
        };
        for child in started.into_iter().chain(item.parent.as_ref()) {
            if child.kind == inline_agent_bridge::harness::ChildKind::Subagent
                && let Ok(session) = ProviderSessionId::new(child.id.as_str())
                && &session != native
            {
                tools.bind_child(&session, native);
            }
        }
    }

    async fn session_op(&mut self, op: SessionOp) -> Option<String> {
        match op {
            SessionOp::Settings(change) => {
                settings::merge(&mut self.settings, &change);
                self.settings_pending = true;
                if self.held_session().is_none() {
                    return Some("Applies to this thread from the next message.".to_owned());
                }
                self.sync_settings().await
            }
            SessionOp::Compact => self.native_op(Op::Compact, "Compacting the context.").await,
            SessionOp::Clear => self.native_op(Op::Clear, "Context cleared.").await,
            SessionOp::Mode(mode) => {
                let Ok(id) = inline_agent_bridge::harness::ModeId::new(mode.clone()) else {
                    return Some("That mode is not available.".to_owned());
                };
                let done = if mode == "plan" {
                    "Plan mode: the agent plans and changes nothing until you approve."
                } else {
                    "Plan mode is off."
                };
                self.native_op(Op::Mode { mode: id }, done).await
            }
            SessionOp::Review(branch) => {
                let target = match branch {
                    Some(branch) => {
                        inline_agent_bridge::harness::ReviewTarget::BaseBranch { branch }
                    }
                    None => inline_agent_bridge::harness::ReviewTarget::UncommittedChanges,
                };
                self.native_op(Op::Review { target }, "Reviewing.").await
            }
            SessionOp::Undo => match self.last_turn_input.clone() {
                Some(input) => {
                    self.native_op(
                        Op::RewindFiles {
                            to: inline_agent_bridge::harness::RewindPoint::Input { input },
                        },
                        "Undid the last turn's file changes.",
                    )
                    .await
                }
                None => Some("Nothing to undo yet.".to_owned()),
            },
        }
    }

    async fn native_op(&mut self, op: Op, done: &str) -> Option<String> {
        let Some(session) = self.held_session() else {
            return Some("Nothing is open in this thread yet.".to_owned());
        };
        match session.control(op).await {
            Ok(_) => Some(done.to_owned()),
            Err(error) => Some(format!("Not available: {error}")),
        }
    }

    /// Hands this thread's settings to the held session. A harness that
    /// cannot change a running session takes them at its next open.
    async fn sync_settings(&mut self) -> Option<String> {
        if !self.settings_pending {
            return None;
        }
        let change = settings::effective(&self.settings);
        let session = self.held_session()?;
        if change.is_empty() {
            self.settings_pending = false;
            return Some("Back to the harness's defaults from the next session.".to_owned());
        }
        match session
            .control(Op::Settings {
                change,
                scope: inline_agent_bridge::harness::SettingsScope::Thread,
            })
            .await
        {
            Ok(_) => {
                self.settings_pending = false;
                Some("Applies to this thread from the next message.".to_owned())
            }
            Err(error) => {
                log::debug!(target: "inline::bridge::v2", "settings not applied: {error}");
                Some(format!(
                    "Applies when this thread's session next opens ({error})."
                ))
            }
        }
    }

    fn unbind_tools(&self) {
        if let (Some(tools), Some(native)) = (&self.agent.tools, &self.native) {
            tools.unbind(native);
        }
    }

    async fn work_tool(&mut self, tool: WorkTool) -> HostToolResult {
        match tool {
            WorkTool::StartSubthread {
                title,
                summary,
                anchor_message_id,
            } => {
                self.start_subthread(title, summary, anchor_message_id)
                    .await
            }
        }
    }

    /// Moves this work's publication into a new subthread (spec §5.2). The
    /// native session is unchanged; the parent keeps one status card.
    async fn start_subthread(
        &mut self,
        title: String,
        summary: Option<String>,
        anchor_message_id: Option<i64>,
    ) -> HostToolResult {
        let Some(agent_session_id) =
            Some(self.agent_session_id.load(Ordering::Acquire)).filter(|id| *id > 0)
        else {
            return HostToolResult::failure(
                "This work is not recorded in Inline yet, so it cannot move.",
            );
        };
        if self.publication.chat().is_none() {
            return HostToolResult::failure("This work is already moving.");
        }
        let created = match self
            .agent
            .bot
            .create_reply_thread(CreateReplyThreadRequest {
                parent_chat_id: InlineId::new(self.chat_id),
                parent_message_id: anchor_message_id.map(InlineId::new),
                title: Some(title.clone()),
                description: summary.clone(),
                emoji: None,
                participants: Vec::new(),
                agent_context: None,
            })
            .await
        {
            Ok(created) => created,
            Err(error) => {
                log::warn!(target: "inline::bridge::v2", "subthread failed: {error}");
                return HostToolResult::failure("Inline could not create the subthread.");
            }
        };
        let destination = created.chat_id.get();
        if let Err(error) = self.agent.ledger.copy_thread(self.chat_id, destination) {
            return HostToolResult::failure(format!("Could not retain thread settings: {error}"));
        }
        // Progress still pending lands in the parent before the move.
        self.flush_edits(true).await;
        let effects = self.publication.handle(PublicationEvent::MoveRequested {
            destination: ChatId(destination),
        });
        let card = ParentCard {
            title,
            summary,
            agent_session_id,
        };
        if let Some(reason) = self.publication_effects(effects, Some(&card)).await {
            return HostToolResult::failure(format!(
                "The work stayed in its thread: {reason}. The new subthread {destination} is empty."
            ));
        }
        if self.publication.chat() != Some(ChatId(destination)) {
            return HostToolResult::failure("Inline could not confirm the move.");
        }
        let from = self.chat_id;
        self.chat_id = destination;
        // The subthread is the work's own: its answer stands on its own.
        self.answer_to = None;
        self.answer_replies.clear();
        // Progress goes on in new messages in the subthread; the parent's
        // open progress messages close, since its card links there.
        self.edits.clear();
        let open: Vec<i64> = self
            .slots
            .drain()
            .map(|(_, message_id)| message_id)
            .collect();
        for message_id in open {
            self.edit_in(
                from,
                message_id,
                &paragraph("Continued in the subthread."),
                None,
            )
            .await;
        }
        if let (Some(tools), Some(native)) = (&self.agent.tools, &self.native) {
            tools.move_work(native, destination);
        }
        let _ = self.agent.moves.send((from, destination));
        HostToolResult::success(
            serde_json::json!({
                "chat_id": destination,
                "link": format!("inline://chat?id={destination}"),
                "note": "Your output now goes to the subthread; post a short summary back with send_message when done.",
            })
            .to_string(),
        )
    }

    /// Carries out publication effects; returns why a move failed.
    async fn publication_effects(
        &mut self,
        effects: Vec<PublicationEffect>,
        card: Option<&ParentCard>,
    ) -> Option<String> {
        let mut queue: VecDeque<PublicationEffect> = effects.into();
        let mut attempts = 0;
        let mut failure = None;
        while let Some(effect) = queue.pop_front() {
            match effect {
                PublicationEffect::CallMove { destination } => {
                    let Some(card) = card else { continue };
                    attempts += 1;
                    let event = match api::move_session(
                        &self.agent.bot,
                        card.agent_session_id,
                        destination.0,
                    )
                    .await
                    {
                        Ok(result) => PublicationEvent::MoveConfirmed {
                            destination,
                            moved: result.moved,
                        },
                        // The move is idempotent on the server, so an unknown
                        // outcome is retried a few times.
                        Err(error) if attempts < MOVE_ATTEMPTS => {
                            log::warn!(target: "inline::bridge::v2", "move failed, retrying: {error}");
                            PublicationEvent::MoveUnknown
                        }
                        // Out of retries: only Inline's record says whether
                        // the move happened, so a lost reply is not taken
                        // for a refusal.
                        Err(error) => {
                            let lookup = self
                                .agent
                                .owner
                                .lookup(proto::GetAgentSessionInput {
                                    peer_id: Some(chat_peer(destination.0)),
                                    bot_user_id: self.agent.bot_user_id,
                                    ..Default::default()
                                })
                                .await;
                            let result = match lookup {
                                Ok(result) => result,
                                Err(lookup_error) => {
                                    // Only this work waits. Publication remains fenced while
                                    // Inline cannot establish where the move committed.
                                    log::warn!(target: "inline::bridge::v2", "move lookup unavailable, retaining publication fence: {lookup_error}");
                                    tokio::time::sleep(Duration::from_secs(2)).await;
                                    queue.push_front(PublicationEffect::CallMove { destination });
                                    continue;
                                }
                            };
                            let moved = result
                                .connection
                                .and_then(|connection| connection.agent_session)
                                .is_some_and(|session| session.id == card.agent_session_id);
                            if moved {
                                PublicationEvent::MoveConfirmed {
                                    destination,
                                    moved: true,
                                }
                            } else {
                                PublicationEvent::MoveRejected {
                                    reason: error.to_string(),
                                }
                            }
                        }
                    };
                    queue.extend(self.publication.handle(event));
                }
                PublicationEffect::PostParentStatus { parent, subthread } => {
                    let Some(card) = card else { continue };
                    let text = parent_card_text(&self.agent.agent_name, card, subthread.0, None);
                    let random_id = rand::random::<i64>().abs().max(1);
                    match api::send_markdown(&self.agent.bot, parent.0, None, &text, random_id)
                        .await
                    {
                        Ok(message_id) => {
                            self.remember(message_id);
                            self.parent_card = Some((parent.0, message_id));
                            self.parent_card_text = Some((card.clone(), subthread.0));
                        }
                        Err(error) => {
                            log::warn!(target: "inline::bridge::v2", "parent card failed: {error}");
                        }
                    }
                }
                PublicationEffect::UpdateParentStatus { parent, summary } => {
                    let (Some((chat, message_id)), Some((card, subthread))) =
                        (self.parent_card, self.parent_card_text.clone())
                    else {
                        continue;
                    };
                    if chat != parent.0 {
                        continue;
                    }
                    let text =
                        parent_card_text(&self.agent.agent_name, &card, subthread, Some(&summary));
                    if let Err(error) =
                        api::edit_markdown(&self.agent.bot, chat, message_id, &text).await
                    {
                        log::warn!(target: "inline::bridge::v2", "parent card edit failed: {error}");
                    }
                }
                PublicationEffect::MoveFailed { reason } => failure = Some(reason),
                PublicationEffect::MoveBusy => failure = Some("a move is in progress".to_owned()),
                // The actor publishes inline, so nothing is held during a move.
                PublicationEffect::Publish { .. } => {}
            }
        }
        failure
    }

    // ---------------------------------------------------------------
    // Session events
    // ---------------------------------------------------------------

    async fn envelope(&mut self, envelope: inline_agent_bridge::harness::Envelope) {
        log::debug!(
            target: "inline::bridge::v2",
            "chat={} seq={} event={}",
            self.chat_id,
            envelope.seq,
            event_kind(&envelope.event)
        );
        if let Event::Item(item) = &envelope.event {
            self.bind_children(item);
        }
        match &envelope.event {
            Event::Turn { turn, phase } => match phase {
                TurnPhase::Started { inputs } => {
                    self.turn = Some(turn.clone());
                    if let Some(first) = inputs.first() {
                        self.last_turn_input = Some(first.clone());
                    }
                    self.turn_started = Some(now_ms() as i64 / 1000);
                    // Running again: whatever limit it waited on has reset.
                    self.waiting = None;
                    for input in inputs {
                        self.mark(input, InputState::Consumed);
                        self.inputs.remove(input);
                        self.settled(input).await;
                    }
                }
                TurnPhase::Completed {
                    inputs_consumed, ..
                } => {
                    self.rendering_turn = Some(turn.clone());
                    for input in inputs_consumed {
                        self.mark(input, InputState::Consumed);
                        self.inputs.remove(input);
                        self.settled(input).await;
                    }
                    if self.turn.as_ref() == Some(turn) {
                        self.turn = None;
                        self.turn_started = None;
                    }
                    self.stopping = false;
                    // A usage limit outlasts the turn it stopped.
                    if !matches!(self.waiting, Some((proto::AgentWaitingReason::Limit, _))) {
                        self.waiting = None;
                    }
                }
            },
            Event::Usage { usage } => self.agent.record_usage(self.chat_id, usage),
            Event::Input { id, fact } => match fact {
                InputFact::Consumed { .. } => {
                    self.mark(id, InputState::Consumed);
                    self.inputs.remove(id);
                    self.settled(id).await;
                }
                // Taken out of the queue by this bridge (pause or release):
                // kept pending in Inline.
                InputFact::Cancelled if self.removing.remove(id) => {
                    self.mark(id, InputState::Pending);
                }
                InputFact::Cancelled => {
                    self.mark(id, InputState::Failed);
                    if let Some((_, _, message_id)) = self.inputs.remove(id) {
                        self.reply(message_id, "This message was cancelled before it ran.")
                            .await;
                    }
                }
                InputFact::Rejected { reason } => {
                    self.mark(id, InputState::Failed);
                    if let Some((_, _, message_id)) = self.inputs.remove(id) {
                        self.reply(
                            message_id,
                            &format!("{} refused this: {reason}", self.agent.agent_name),
                        )
                        .await;
                    }
                }
            },
            Event::State { state } => {
                if let RunState::Waiting {
                    on: WaitingOn::Limit { resets_at },
                } = state
                {
                    self.limit_reached(*resets_at).await;
                }
                if let Some(event) = run_state_event(state) {
                    self.event(event).await;
                }
            }
            Event::Held { by: Some(by) } => {
                self.event(HoldEvent::AcquireConflict { by: by.clone() })
                    .await;
            }
            Event::Gap { expected, actual } => {
                log::warn!(target: "inline::bridge::v2", "session events skipped expected={expected} actual={actual}");
            }
            _ => {}
        }
        self.renderer.set_folder(self.folder());
        let ops = self.renderer.apply(&envelope);
        self.render(ops).await;
        if (envelope.event.is_control() || matches!(envelope.event, Event::Child { .. }))
            && let Some(session) = self.session.clone()
        {
            self.live = session.live_work();
            self.event(HoldEvent::Activity {
                live: self.live.clone(),
            })
            .await;
        } else {
            self.report().await;
        }
    }

    /// Today's speak-gate checks ran out: the owner hears once, in the DM,
    /// with one tap to allow more (spec §5.1 rule 6).
    async fn gate_budget_reached(&self) {
        let allowance = self
            .agent
            .gate_budget
            .lock()
            .expect("gate budget")
            .allowance();
        let text = format!(
            "{} used today's {allowance} checks on whether to answer unaddressed messages. Until tomorrow it answers only when addressed.",
            self.agent.agent_name
        );
        let actions = button_rows(&[(
            "Allow more today",
            ActionData::RaiseGateBudget,
            ActionStyle::Primary,
        )]);
        if let Err(error) = api::send_doc(
            &self.agent.bot,
            self.agent.dm_chat_id,
            None,
            &paragraph(&text),
            actions,
            Notify::Normal,
        )
        .await
        {
            log::warn!(target: "inline::bridge::v2", "speak gate budget notice failed: {error}");
        }
    }

    /// Out of usage: one notice says when it resets, and the work's attention
    /// points the owner at it until a turn runs again.
    async fn limit_reached(&mut self, resets_at: Option<i64>) {
        if matches!(self.waiting, Some((proto::AgentWaitingReason::Limit, _))) {
            return;
        }
        let text = limit_notice(&self.agent.agent_name, resets_at, now_ms() as i64 / 1000);
        let notice = self
            .send(&paragraph(&text), None, Notify::Normal)
            .await
            .unwrap_or(0);
        self.waiting = Some((proto::AgentWaitingReason::Limit, notice));
        self.report().await;
    }

    /// A stable random ID for one answer or card of this work's session,
    /// so a retry, or the same output rendered again, is posted once.
    fn output_id(&self, kind: &str, token: Option<&str>) -> i64 {
        match (&self.native, token) {
            (Some(native), Some(token)) => crate::bridge::helpers::interaction_random_id(
                &format!("v2-{kind}"),
                &format!("{native}:{token}"),
            )
            .get(),
            _ => rand::random::<i64>().abs().max(1),
        }
    }

    /// Posts an answer or card; one Inline does not take yet is retried with
    /// the same random ID, now and with each tick, so it lands exactly once.
    async fn publish(&mut self, outgoing: Outgoing) {
        // Retain every item immediately, even when an earlier item blocks the queue.
        if let Err(error) = serde_json::to_string(&outgoing)
            .map_err(|error| error.to_string())
            .and_then(|payload| {
                self.agent
                    .ledger
                    .save_output(self.chat_id, outgoing.random_id, &payload)
                    .map_err(|error| error.to_string())
            })
        {
            log::error!(target: "inline::bridge::v2", "cannot retain output: {error}");
        }
        self.outbox
            .retain(|pending| pending.random_id != outgoing.random_id);
        self.outbox.push_back(outgoing);
        self.flush_outbox().await;
    }

    /// An answer or card Inline refused (or whose chat is gone): one plain-text
    /// try, then it is dropped with a notice, so it never blocks the outbox.
    async fn drop_refused(&mut self, outgoing: Outgoing, failure: Failure) {
        let kind = if outgoing.card.is_some() {
            "card"
        } else {
            "answer"
        };
        log::error!(
            target: "inline::bridge::v2",
            "chat={} {kind} {failure:?} by Inline ({:?})",
            outgoing.chat,
            limits::Size::of(&outgoing.doc)
        );
        if let Err(error) = self.agent.ledger.remove_output(outgoing.random_id) {
            log::error!(target: "inline::bridge::v2", "cannot settle retained output: {error}");
        }
        if failure == Failure::Gone {
            return;
        }
        crate::telemetry::report_bridge_output_refused(kind);
        if !outgoing.fallback {
            let random_id = outgoing.random_id.wrapping_add(1).max(1);
            self.outbox.push_front(Outgoing {
                doc: plain_fallback(&outgoing.doc),
                random_id,
                fallback: true,
                ..outgoing
            });
            return;
        }
        let what = if kind == "card" {
            "a request for you"
        } else {
            "an answer"
        };
        self.notice(&format!(
            "{} had {what} Inline couldn't show. Continue in the terminal to see it.",
            self.agent.agent_name
        ))
        .await;
    }

    async fn flush_outbox(&mut self) {
        while let Some(outgoing) = self.outbox.pop_front() {
            // Persist before the first attempt, including a closed card's replacement.
            let saved = serde_json::to_string(&outgoing)
                .map_err(|error| error.to_string())
                .and_then(|payload| {
                    self.agent
                        .ledger
                        .save_output(self.chat_id, outgoing.random_id, &payload)
                        .map_err(|error| error.to_string())
                });
            if let Err(error) = saved {
                log::error!(target: "inline::bridge::v2", "cannot retain output: {error}");
                self.outbox.push_front(outgoing);
                return;
            }
            // Restore native interactions before exposing their buttons after restart.
            if outgoing.card.is_some() && self.session.is_none() {
                self.outbox.push_front(outgoing);
                return;
            }
            let mut sent = None;
            let mut failure = Failure::Retry(None);
            for delay in PUBLISH_RETRIES {
                let delay = match failure {
                    Failure::Retry(Some(after)) => delay.max(after.min(MAX_PUBLISH_WAIT)),
                    _ => delay,
                };
                tokio::time::sleep(delay).await;
                match api::send_doc_as(
                    &self.agent.bot,
                    outgoing.chat,
                    outgoing.reply_to,
                    &outgoing.doc,
                    outgoing.actions.clone(),
                    Notify::Normal,
                    outgoing.random_id,
                )
                .await
                {
                    Ok(id) => {
                        sent = Some(id);
                        break;
                    }
                    Err(error) => {
                        log::warn!(target: "inline::bridge::v2", "chat={} publish failed: {error}", outgoing.chat);
                        failure = error.failure();
                        if !matches!(failure, Failure::Retry(_)) {
                            break;
                        }
                    }
                }
            }
            let Some(message_id) = sent else {
                match failure {
                    // Kept in order; the next tick tries again.
                    Failure::Retry(_) => {
                        self.outbox.push_front(outgoing);
                        return;
                    }
                    // Never retried as it is, so later output is not stuck
                    // behind it.
                    Failure::Refused | Failure::Gone => {
                        self.drop_refused(outgoing, failure).await;
                        continue;
                    }
                }
            };
            // A closed card also drops its buttons; a refused or vanished
            // card has nothing left to close.
            if outgoing.closed
                && let Err(Failure::Retry(_)) = self
                    .try_edit(
                        outgoing.chat,
                        message_id,
                        &outgoing.doc,
                        Some(proto::MessageActions::default()),
                    )
                    .await
            {
                self.outbox.push_front(outgoing);
                return;
            }
            if let Err(error) = self.agent.ledger.remove_output(outgoing.random_id) {
                log::error!(target: "inline::bridge::v2", "cannot settle retained output: {error}");
                self.outbox.push_front(outgoing);
                return;
            }
            self.remember(message_id);
            if let Some((interaction, form)) = outgoing.card {
                self.card_by_interaction
                    .insert(interaction.clone(), message_id);
                self.waiting = Some((
                    if form.is_some() {
                        proto::AgentWaitingReason::Question
                    } else {
                        proto::AgentWaitingReason::Approval
                    },
                    message_id,
                ));
                self.cards.insert(
                    message_id,
                    Card {
                        chat: outgoing.chat,
                        interaction,
                        approval: form.is_none(),
                        form,
                        answered: Vec::new(),
                    },
                );
                self.report().await;
            }
        }
    }

    async fn render(&mut self, ops: Vec<RenderOp>) {
        for op in ops {
            log::debug!(target: "inline::bridge::v2", "chat={} render={}", self.chat_id, render_kind(&op));
            match op {
                RenderOp::Progress { slot, doc } => match self.slots.get(&slot) {
                    Some(_) => {
                        let due = tokio::time::Instant::now() + EDIT_INTERVAL;
                        self.edits
                            .entry(slot)
                            .and_modify(|edit| edit.doc = doc.clone())
                            .or_insert(PendingEdit {
                                doc,
                                due,
                                actions: None,
                                closing: false,
                            });
                    }
                    None => {
                        if let Some(id) = self.send(&doc, None, Notify::Silent).await {
                            self.slots.insert(slot, id);
                        }
                    }
                },
                RenderOp::EndProgress { slot, doc } => {
                    self.edits.remove(&slot);
                    match self.slots.get(&slot).copied() {
                        Some(message_id) => {
                            match self.try_edit(self.chat_id, message_id, &doc, None).await {
                                Err(Failure::Retry(after)) => {
                                    // "Worked for" must land: kept until it does.
                                    self.edits.insert(
                                        slot,
                                        PendingEdit {
                                            doc,
                                            due: tokio::time::Instant::now()
                                                + after.unwrap_or(EDIT_INTERVAL),
                                            actions: None,
                                            closing: true,
                                        },
                                    );
                                }
                                _ => {
                                    self.slots.remove(&slot);
                                }
                            }
                        }
                        None => {
                            self.send(&doc, None, Notify::Silent).await;
                        }
                    }
                }
                RenderOp::Update { doc } => {
                    self.send(&doc, None, Notify::Silent).await;
                }
                RenderOp::Final { doc } => {
                    // Edits still pending land before the answer.
                    self.flush_edits(true).await;
                    let reply_to = self.answer_to.take();
                    // The turn and the text: a retry or a re-render of this
                    // answer is the same message, another answer is not.
                    let token = self
                        .turn
                        .as_ref()
                        .or(self.rendering_turn.as_ref())
                        .map(|turn| format!("{turn}:{}", text_digest(&doc.text)));
                    // An answer over Inline's limit goes out in parts.
                    let parts = if limits::Size::of(&doc).fits() {
                        vec![doc]
                    } else {
                        split_markdown(&doc.text, limits::MAX_TEXT_UTF16 * 4 / 5)
                            .iter()
                            .map(|part| Doc::markdown(part))
                            .collect()
                    };
                    for (index, doc) in parts.into_iter().enumerate() {
                        let token = token.as_ref().map(|token| {
                            if index == 0 {
                                token.clone()
                            } else {
                                format!("{token}:{index}")
                            }
                        });
                        let random_id = self.output_id("final", token.as_deref());
                        self.publish(Outgoing {
                            chat: self.chat_id,
                            doc,
                            reply_to: if index == 0 { reply_to } else { None },
                            actions: None,
                            random_id,
                            card: None,
                            closed: false,
                            fallback: false,
                        })
                        .await;
                    }
                }
                RenderOp::Notice { doc } => {
                    self.flush_edits(true).await;
                    self.send(&doc, None, Notify::Normal).await;
                }
                RenderOp::Card {
                    interaction,
                    doc,
                    actions,
                    form,
                } => {
                    let buttons = match &form {
                        Some(form) if render::pickable(form) => pick_actions(&interaction, form, 0),
                        _ => card_actions(&interaction, &actions),
                    };
                    let long = long_labels(&actions);
                    let doc = if long.is_empty() {
                        doc
                    } else {
                        let mut doc = doc;
                        for label in long {
                            doc.append_paragraph(&format!("• {label}"));
                        }
                        doc
                    };
                    let random_id = self.output_id("card", Some(interaction.as_str()));
                    self.publish(Outgoing {
                        chat: self.chat_id,
                        doc,
                        reply_to: None,
                        actions: buttons,
                        random_id,
                        card: Some((interaction, form)),
                        closed: false,
                        fallback: false,
                    })
                    .await;
                }
                RenderOp::CardClosed { interaction, doc } => {
                    let random_id = self.output_id("card", Some(interaction.as_str()));
                    let queued = self
                        .outbox
                        .iter()
                        .find(|outgoing| outgoing.random_id == random_id);
                    let mut chat = queued.map_or(self.chat_id, |outgoing| outgoing.chat);
                    if let Some(message_id) = self.card_by_interaction.remove(&interaction) {
                        chat = self
                            .cards
                            .remove(&message_id)
                            .map_or(chat, |card| card.chat);
                        if self.waiting.is_some_and(|(_, card)| card == message_id) {
                            self.waiting = None;
                        }
                    }
                    // The original send may have committed without a reply. Recover
                    // its ID with the same key, then clear the live buttons by edit.
                    self.publish(Outgoing {
                        chat,
                        doc,
                        reply_to: None,
                        actions: Some(proto::MessageActions::default()),
                        random_id,
                        card: None,
                        closed: true,
                        fallback: false,
                    })
                    .await;
                }
            }
        }
    }

    async fn flush_edits(&mut self, all: bool) {
        let now = tokio::time::Instant::now();
        let due: Vec<u32> = self
            .edits
            .iter()
            .filter(|(_, edit)| all || edit.due <= now)
            .map(|(slot, _)| *slot)
            .collect();
        for slot in due {
            let (Some(edit), Some(message_id)) =
                (self.edits.remove(&slot), self.slots.get(&slot).copied())
            else {
                continue;
            };
            match self
                .try_edit(self.chat_id, message_id, &edit.doc, edit.actions.clone())
                .await
            {
                Ok(()) => {
                    if edit.closing {
                        self.slots.remove(&slot);
                    }
                }
                // Tried again later, unless a newer edit replaced it.
                Err(Failure::Retry(after)) => {
                    self.edits.entry(slot).or_insert(PendingEdit {
                        due: now + after.unwrap_or(EDIT_INTERVAL),
                        ..edit
                    });
                }
                // Never retried as it is: the renderer keeps messages within
                // Inline's limits, so this is rare and reported. The next
                // edit of an open message may still land.
                Err(Failure::Refused | Failure::Gone) => {
                    if edit.closing {
                        self.slots.remove(&slot);
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // Inline output and state
    // ---------------------------------------------------------------

    fn remember(&self, message_id: i64) {
        self.agent.sent.lock().expect("sent").insert(message_id);
    }

    async fn send(
        &self,
        doc: &Doc,
        actions: Option<proto::MessageActions>,
        notify: Notify,
    ) -> Option<i64> {
        self.send_in_reply(doc, None, actions, notify).await
    }

    async fn send_in_reply(
        &self,
        doc: &Doc,
        reply_to: Option<i64>,
        actions: Option<proto::MessageActions>,
        notify: Notify,
    ) -> Option<i64> {
        if doc.is_empty() {
            return None;
        }
        match api::send_doc(
            &self.agent.bot,
            self.chat_id,
            reply_to,
            doc,
            actions,
            notify,
        )
        .await
        {
            Ok(id) => {
                self.remember(id);
                Some(id)
            }
            Err(error) => {
                log::warn!(target: "inline::bridge::v2", "send failed: {error}");
                None
            }
        }
    }

    async fn edit(&self, message_id: i64, doc: &Doc, actions: Option<proto::MessageActions>) {
        self.edit_in(self.chat_id, message_id, doc, actions).await;
    }

    async fn edit_in(
        &self,
        chat_id: i64,
        message_id: i64,
        doc: &Doc,
        actions: Option<proto::MessageActions>,
    ) -> bool {
        self.try_edit(chat_id, message_id, doc, actions)
            .await
            .is_ok()
    }

    async fn try_edit(
        &self,
        chat_id: i64,
        message_id: i64,
        doc: &Doc,
        actions: Option<proto::MessageActions>,
    ) -> Result<(), Failure> {
        match api::edit_doc(&self.agent.bot, chat_id, message_id, doc, actions).await {
            Ok(()) => Ok(()),
            Err(error) => {
                let failure = error.failure();
                if failure == Failure::Refused {
                    log::error!(target: "inline::bridge::v2", "chat={chat_id} edit refused: {error} ({:?})", limits::Size::of(doc));
                    crate::telemetry::report_bridge_output_refused("edit");
                } else {
                    log::warn!(target: "inline::bridge::v2", "edit failed: {error}");
                }
                Err(failure)
            }
        }
    }

    async fn notice(&self, text: &str) -> Option<i64> {
        self.send(&paragraph(text), None, Notify::Normal).await
    }

    async fn notice_with(&self, text: &str, actions: Option<proto::MessageActions>) -> Option<i64> {
        self.send(&paragraph(text), actions, Notify::Normal).await
    }

    async fn reply(&self, message_id: i64, text: &str) {
        self.reply_in(self.chat_id, message_id, text).await;
    }

    async fn reply_in(&self, chat_id: i64, message_id: i64, text: &str) {
        match api::send_doc(
            &self.agent.bot,
            chat_id,
            Some(message_id),
            &paragraph(text),
            None,
            Notify::Normal,
        )
        .await
        {
            Ok(id) => self.remember(id),
            Err(error) => log::warn!(target: "inline::bridge::v2", "reply failed: {error}"),
        }
    }

    async fn close_release_card(&mut self) {
        if let Some(card) = self.release_card.take() {
            self.edit(
                card,
                &paragraph("Release request closed."),
                Some(proto::MessageActions::default()),
            )
            .await;
        }
    }

    /// Records where an input stands; true once it is saved. A failed save
    /// is kept and written again with the next one, and until then the
    /// ledger still holds the earlier state, which a restart reconciles.
    /// Callers about to cause a native effect check the result (spec §4.7).
    fn mark(&self, input: &InputId, state: InputState) -> bool {
        let mut unsaved = self.unsaved.lock().expect("unsaved");
        unsaved.remove(input);
        unsaved.retain(|id, state| self.agent.ledger.set(id.as_str(), *state).is_err());
        match self.agent.ledger.set(input.as_str(), state) {
            Ok(()) => true,
            Err(error) => {
                log::warn!(target: "inline::bridge::v2", "ledger update failed: {error}");
                unsaved.insert(input.clone(), state);
                false
            }
        }
    }

    fn publish_phase(&self) {
        self.update_busy.set(
            !self.inputs.is_empty()
                || !self.uncertain.is_empty()
                || self.turn.is_some()
                || self.waiting.is_some()
                || !self.outbox.is_empty()
                || !self.edits.is_empty()
                || !self
                    .unsaved
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .is_empty(),
        );
        let phase = if self.paused {
            WorkPhase::Paused
        } else if self.turn.is_some() {
            WorkPhase::Running
        } else if self.native.is_some() || self.session.is_some() {
            WorkPhase::Idle
        } else {
            WorkPhase::None
        };
        self.phase.send_if_modified(|current| {
            let changed = *current != phase;
            *current = phase;
            changed
        });
    }

    /// Shows "working" where typing shows while a turn runs, and clears it
    /// when the turn ends or waits on someone. Best effort, like typing.
    async fn sync_working(&mut self) {
        let working = self.turn.is_some() && self.waiting.is_none() && !self.stopping;
        let now = tokio::time::Instant::now();
        let send = match (working, self.working_due) {
            (true, Some(due)) if due > now => return,
            (true, _) => {
                self.working_due = Some(now + WORKING_HEARTBEAT);
                true
            }
            (false, Some(_)) => {
                self.working_due = None;
                false
            }
            (false, None) => return,
        };
        let _ = tokio::time::timeout(
            WORKING_SEND_TIMEOUT,
            api::send_working(&self.agent.bot, self.chat_id, send),
        )
        .await;
    }

    /// Reports the run state to Inline when it changes (spec §7).
    async fn report(&mut self) {
        self.publish_phase();
        let Some(agent_session_id) =
            Some(self.agent_session_id.load(Ordering::Acquire)).filter(|id| *id > 0)
        else {
            return;
        };
        let mut state = proto::AgentSessionState {
            revision: revision(self.started_ms),
            ..Default::default()
        };
        // The idle rule detaches silently (Codex right after each turn, then
        // up to its unload delay): only an explicit release shows releasing.
        let releasing = match self.hold.state() {
            HoldState::Detaching { request, .. } => request.cause.is_explicit(),
            HoldState::ConfirmingRelease { .. }
            | HoldState::Releasing { .. }
            | HoldState::ReleaseFenced { .. } => true,
            _ => false,
        };
        let run_state = match self.hold.state() {
            HoldState::HeldElsewhere { .. } => proto::AgentRunState::HeldElsewhere,
            _ if releasing => proto::AgentRunState::Releasing,
            _ if self.stopping => proto::AgentRunState::Stopping,
            _ if self.waiting.is_some() => {
                let (reason, card) = self.waiting.expect("waiting");
                state.waiting_reason = reason as i32;
                if card > 0 {
                    state.attention = Some(proto::AgentAttention {
                        kind: match reason {
                            proto::AgentWaitingReason::Question => {
                                proto::AgentAttentionKind::Question
                            }
                            proto::AgentWaitingReason::Limit => proto::AgentAttentionKind::Limit,
                            _ => proto::AgentAttentionKind::Approval,
                        } as i32,
                        user_ids: vec![self.agent.owner_user_id],
                        message_id: Some(card),
                        text: None,
                    });
                }
                proto::AgentRunState::Waiting
            }
            _ if self.turn.is_some() => {
                state.started_at = self.turn_started;
                proto::AgentRunState::Working
            }
            _ if self.paused => proto::AgentRunState::Paused,
            _ => proto::AgentRunState::Idle,
        };
        state.run_state = run_state as i32;
        state.queued_count = self.live.queued.len() as u32;
        let key = proto::AgentSessionState {
            revision: 0,
            updated_at: 0,
            ..state.clone()
        };
        if self.reported.as_ref() == Some(&key) {
            return;
        }
        self.reported = Some(key);
        if let Err(error) =
            api::update_session_state(&self.agent.bot, agent_session_id, state).await
        {
            log::warn!(target: "inline::bridge::v2", "run state report failed: {error}");
            self.reported = None;
        }
    }
}

/// What the parent's status card says after a move.
#[derive(Clone, Debug)]
struct ParentCard {
    title: String,
    summary: Option<String>,
    agent_session_id: i64,
}

fn parent_card_text(
    agent_name: &str,
    card: &ParentCard,
    subthread: i64,
    status: Option<&str>,
) -> String {
    let title: String = card
        .title
        .chars()
        .filter(|character| !matches!(character, '[' | ']'))
        .collect();
    let mut text = format!("{agent_name} continues in [{title}](inline://chat?id={subthread}).");
    if let Some(summary) = card
        .summary
        .as_deref()
        .filter(|summary| !summary.is_empty())
    {
        text.push_str("\n\n");
        text.push_str(summary);
    }
    if let Some(status) = status {
        text.push_str("\n\nStatus: ");
        text.push_str(status);
    }
    text
}

enum OpenFailure {
    HeldElsewhere(HeldBy),
    Other(String),
}

impl std::fmt::Display for OpenFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::HeldElsewhere(by) => write!(formatter, "it is open in {}", held_label(by)),
            Self::Other(message) => formatter.write_str(message),
        }
    }
}

const NOT_FOUND: &str = "the native session was not found";

async fn next_envelope(
    events: &mut Option<std::sync::Mutex<EventStream>>,
) -> Option<inline_agent_bridge::harness::Envelope> {
    match events {
        Some(stream) => {
            stream
                .get_mut()
                .expect("event stream poisoned")
                .next()
                .await
        }
        None => std::future::pending().await,
    }
}

async fn sleep_until(due: Option<tokio::time::Instant>) {
    match due {
        Some(due) => tokio::time::sleep_until(due).await,
        None => std::future::pending().await,
    }
}

fn live_turn(session: &Arc<dyn Session>) -> Option<TurnId> {
    session.live_work().turn
}

/// The gate's JSON answer; anything unreadable is quiet.
fn parse_verdict(text: &str) -> Result<SpeakVerdict, SpeakGateError> {
    let start = text
        .find('{')
        .ok_or_else(|| SpeakGateError::Failed("no JSON".to_owned()))?;
    let end = text
        .rfind('}')
        .ok_or_else(|| SpeakGateError::Failed("no JSON".to_owned()))?;
    let value: serde_json::Value = serde_json::from_str(&text[start..=end])
        .map_err(|error| SpeakGateError::Failed(error.to_string()))?;
    Ok(SpeakVerdict {
        speak: value["speak"].as_bool().unwrap_or(false),
        why: value["why"].as_str().unwrap_or_default().to_owned(),
        confidence: value["confidence"].as_f64().unwrap_or(0.0) as f32,
    })
}

fn event_kind(event: &Event) -> &'static str {
    match event {
        Event::State { .. } => "state",
        Event::Turn { .. } => "turn",
        Event::Item(_) => "item",
        Event::Interaction(_) => "interaction",
        Event::InteractionClosed { .. } => "interaction_closed",
        Event::Input { .. } => "input",
        Event::Queue { .. } => "queue",
        Event::Settings { .. } => "settings",
        Event::Usage { .. } => "usage",
        Event::Child { .. } => "child",
        Event::Held { .. } => "held",
        Event::Renamed { .. } => "renamed",
        Event::Notice(_) => "notice",
        Event::Gap { .. } => "gap",
    }
}

fn render_kind(op: &RenderOp) -> &'static str {
    match op {
        RenderOp::Progress { .. } => "progress",
        RenderOp::EndProgress { .. } => "end_progress",
        RenderOp::Update { .. } => "update",
        RenderOp::Final { .. } => "final",
        RenderOp::Card { .. } => "card",
        RenderOp::CardClosed { .. } => "card_closed",
        RenderOp::Notice { .. } => "notice",
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or_default()
}

/// Run-state revisions increase across restarts: wall-clock milliseconds,
/// never behind this actor's start.
fn revision(started_ms: u64) -> i64 {
    now_ms().max(started_ms) as i64
}

/// "Codex reached its usage limit. It can work again in about 2 h 5 min."
fn limit_notice(agent_name: &str, resets_at: Option<i64>, now: i64) -> String {
    let when = match resets_at.map(|at| at - now) {
        Some(left) if left > 0 => {
            let minutes = (left + 59) / 60;
            if minutes >= 60 {
                format!(
                    " It can work again in about {} h {} min.",
                    minutes / 60,
                    minutes % 60
                )
            } else {
                format!(" It can work again in about {minutes} min.")
            }
        }
        Some(_) => " It can work again now.".to_owned(),
        None => " It can work again when the limit resets.".to_owned(),
    };
    format!("{agent_name} reached its usage limit.{when}")
}

/// Markdown cut into parts of at most `max_utf16` units at line ends, closing
/// and reopening a code fence a cut falls inside.
fn split_markdown(text: &str, max_utf16: usize) -> Vec<String> {
    let mut parts = Vec::new();
    let mut part = String::new();
    let mut fence: Option<String> = None;
    for line in text.split_inclusive('\n') {
        let units = |text: &str| text.encode_utf16().count();
        if !part.is_empty() && units(&part) + units(line) + 4 > max_utf16 {
            if fence.is_some() {
                part.push_str("\n```");
            }
            parts.push(std::mem::take(&mut part));
            if let Some(open) = &fence {
                part.push_str(open);
                part.push('\n');
            }
        }
        // A line longer than a whole part is cut by characters.
        let mut rest = line;
        while units(rest) > max_utf16 {
            let mut count = 0;
            let cut = rest
                .char_indices()
                .find(|(_, character)| {
                    count += character.len_utf16();
                    count > max_utf16
                })
                .map_or(rest.len(), |(index, _)| index);
            parts.push(rest[..cut].to_owned());
            rest = &rest[cut..];
        }
        let trimmed = rest.trim_start();
        if trimmed.starts_with("```") {
            fence = match fence {
                Some(_) => None,
                None => Some(trimmed.trim_end().to_owned()),
            };
        }
        part.push_str(rest);
    }
    if !part.trim().is_empty() {
        parts.push(part);
    }
    parts
}

/// The plain text of a message Inline refused, within its limits.
fn plain_fallback(doc: &Doc) -> Doc {
    let max = limits::MAX_TEXT_UTF16 * 4 / 5;
    let mut text: String = doc
        .text
        .chars()
        .scan(0, |count, character| {
            *count += character.len_utf16();
            (*count <= max).then_some(character)
        })
        .collect();
    if text.len() < doc.text.len() {
        text.push_str("\n\n(Cut: the rest was longer than Inline allows.)");
    }
    Doc {
        text,
        blocks: Vec::new(),
        markdown: false,
    }
}

pub(crate) fn paragraph(text: &str) -> Doc {
    let mut builder = DocBuilder::new();
    builder.paragraph(text);
    builder.finish()
}

fn held_label(by: &HeldBy) -> String {
    use inline_agent_bridge::harness::HeldSurface;
    let surface = match by.surface {
        HeldSurface::Terminal => "a terminal",
        HeldSurface::DesktopApp => "the provider's app",
        HeldSurface::Background => "a background agent",
        HeldSurface::Ide => "an editor",
        _ => "another client",
    };
    match &by.detail {
        Some(detail) if !detail.is_empty() => format!("{surface} ({detail})"),
        _ => surface.to_owned(),
    }
}

fn step_label(step: &ReleaseStep) -> String {
    match step {
        ReleaseStep::KeepQueuedPending { .. } => "keep queued input pending".to_owned(),
        ReleaseStep::CancelInteraction { .. } => "cancel an open request".to_owned(),
        ReleaseStep::InterruptTurn { .. } => "stop the running turn".to_owned(),
        ReleaseStep::StopChild { .. } => "stop a background task".to_owned(),
        ReleaseStep::CancelWakeup { wakeup } => format!("cancel the wakeup {wakeup}"),
        ReleaseStep::LeaveWakeup { wakeup } => format!("leave the wakeup {wakeup}"),
    }
}

pub(crate) fn button_rows(
    buttons: &[(&str, ActionData, ActionStyle)],
) -> Option<proto::MessageActions> {
    let actions = buttons
        .iter()
        .enumerate()
        .filter_map(|(index, (label, data, style))| {
            Some(proto::MessageAction {
                action_id: format!("v2-{index}"),
                text: (*label).to_owned(),
                action: Some(proto::message_action::Action::Callback(
                    proto::MessageActionCallback {
                        data: serde_json::to_vec(data).ok()?,
                    },
                )),
                style: action_style(*style) as i32,
                ..Default::default()
            })
        })
        .collect();
    Some(proto::MessageActions {
        rows: vec![proto::MessageActionRow { actions }],
    })
}

fn action_style(style: ActionStyle) -> proto::message_action::Style {
    match style {
        ActionStyle::Default => proto::message_action::Style::Default,
        ActionStyle::Primary => proto::message_action::Style::Primary,
        ActionStyle::Destructive => proto::message_action::Style::Destructive,
    }
}

/// Inline's limit on button text, in characters.
const MAX_BUTTON_CHARS: usize = 64;

/// The harness's label, shortened to fit a button.
fn button_text(label: &str) -> String {
    if label.chars().count() <= MAX_BUTTON_CHARS {
        return label.to_owned();
    }
    let mut text: String = label.chars().take(MAX_BUTTON_CHARS - 1).collect();
    text.push('…');
    text
}

/// Labels too long for a button, listed in full in the card text.
fn long_labels(actions: &[CardAction]) -> Vec<String> {
    actions
        .iter()
        .filter(|action| action.label.chars().count() > MAX_BUTTON_CHARS)
        .map(|action| action.label.clone())
        .collect()
}

/// A question's options as buttons, one per row; anyone with access to the
/// agent may answer.
pub(crate) fn pick_actions(
    interaction: &InteractionId,
    form: &QuestionForm,
    field: usize,
) -> Option<proto::MessageActions> {
    let FieldInput::Select { options, .. } = &form.fields.get(field)?.input else {
        return None;
    };
    let rows = options
        .iter()
        .enumerate()
        .filter_map(|(index, option)| {
            let data = serde_json::to_vec(&ActionData::Pick {
                i: interaction.to_string(),
                f: field,
                o: index,
            })
            .ok()?;
            Some(proto::MessageActionRow {
                actions: vec![proto::MessageAction {
                    action_id: format!("v2-q{field}-{index}"),
                    text: button_text(&option.label),
                    action: Some(proto::message_action::Action::Callback(
                        proto::MessageActionCallback { data },
                    )),
                    style: proto::message_action::Style::Default as i32,
                    required_grant: proto::AgentGrantRequirement::Access as i32,
                    ..Default::default()
                }],
            })
        })
        .collect();
    Some(proto::MessageActions { rows })
}

/// Approval buttons with the harness's own labels, one per row.
pub(crate) fn card_actions(
    interaction: &InteractionId,
    actions: &[CardAction],
) -> Option<proto::MessageActions> {
    if actions.is_empty() {
        return None;
    }
    let rows = actions
        .iter()
        .enumerate()
        .filter_map(|(index, action)| {
            let data = serde_json::to_vec(&ActionData::Decision {
                i: interaction.to_string(),
                d: action.decision.clone(),
            })
            .ok()?;
            Some(proto::MessageActionRow {
                actions: vec![proto::MessageAction {
                    action_id: format!("v2-{index}"),
                    text: button_text(&action.label),
                    action: Some(proto::message_action::Action::Callback(
                        proto::MessageActionCallback { data },
                    )),
                    style: action_style(action.style) as i32,
                    required_grant: proto::AgentGrantRequirement::Approve as i32,
                    ..Default::default()
                }],
            })
        })
        .collect();
    Some(proto::MessageActions { rows })
}

/// Form values back to the harness: option IDs become the option labels.
pub(crate) fn form_answers(form: &QuestionForm, values: &[FormValue]) -> Vec<FieldAnswer> {
    form.fields
        .iter()
        .enumerate()
        .filter_map(|(index, field)| {
            let field_id = super::doc::form_field_id(index);
            let value = values
                .iter()
                .find(|value| value.field_id == field_id)?
                .value
                .as_ref()?;
            let answers = match (value, &field.input) {
                (
                    FormFieldValue::Selection { option_ids, other },
                    FieldInput::Select { options, .. },
                ) => {
                    let mut labels: Vec<String> = option_ids
                        .iter()
                        .filter_map(|id| id.strip_prefix('o')?.parse::<usize>().ok())
                        .filter_map(|index| options.get(index).map(|option| option.label.clone()))
                        .collect();
                    labels.extend(other.clone().filter(|other| !other.trim().is_empty()));
                    labels
                }
                (FormFieldValue::Text(text), _) => vec![text.clone()],
                (FormFieldValue::Toggle(value), _) => vec![value.to_string()],
                (FormFieldValue::Number(value), _) => vec![value.clone()],
                (FormFieldValue::Selection { option_ids, .. }, _) => option_ids.clone(),
            };
            Some(FieldAnswer {
                field: FieldId::new(field.id.as_str()).ok()?,
                values: answers,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_answer_over_the_limit_splits_at_lines_and_keeps_code_fences_whole() {
        let mut text = String::from("## Report\n\n```rust\n");
        for line in 0..12_000 {
            text.push_str(&format!("let value_{line} = {line};\n"));
        }
        text.push_str("```\n\nDone.");
        let max = limits::MAX_TEXT_UTF16 * 4 / 5;
        let parts = split_markdown(&text, max);
        assert!(parts.len() > 1);
        for part in &parts {
            assert!(part.encode_utf16().count() <= max + 8, "{}", part.len());
            assert_eq!(
                part.matches("```").count() % 2,
                0,
                "every part closes its fences"
            );
        }
        assert!(parts[0].starts_with("## Report"));
        assert!(parts.last().expect("last").trim_end().ends_with("Done."));
        assert!(
            parts[1].starts_with("```rust\n"),
            "the next part reopens the fence"
        );
    }

    #[test]
    fn one_line_longer_than_a_part_is_cut_by_characters() {
        let text = "é".repeat(250_000);
        let parts = split_markdown(&text, 80_000);
        assert_eq!(parts.concat(), text);
        assert!(
            parts
                .iter()
                .all(|part| part.encode_utf16().count() <= 80_000)
        );
    }

    #[test]
    fn the_plain_fallback_fits_and_says_it_was_cut() {
        let doc = Doc::markdown(&"word ".repeat(40_000));
        let plain = plain_fallback(&doc);
        assert!(!plain.markdown && plain.blocks.is_empty());
        assert!(limits::Size::of(&plain).fits());
        assert!(plain.text.ends_with("longer than Inline allows.)"));
        let short = plain_fallback(&Doc::markdown("**hi**"));
        assert_eq!(short.text, "**hi**");
    }
    use inline_agent_bridge::harness::{FieldOption, FormField};

    #[test]
    fn form_answers_map_options_to_labels() {
        let form = QuestionForm {
            title: None,
            fields: vec![FormField {
                // Claude names a question by its text.
                id: FieldId::new("Which one fits?").unwrap(),
                header: None,
                prompt: "Which?".into(),
                input: FieldInput::Select {
                    options: vec![
                        FieldOption {
                            label: "Red".into(),
                            description: None,
                        },
                        FieldOption {
                            label: "Blue".into(),
                            description: None,
                        },
                    ],
                    multiple: true,
                    allow_other: true,
                },
                required: true,
            }],
            asynchronous: false,
            auto_resolution_ms: None,
        };
        let answers = form_answers(
            &form,
            &[FormValue {
                field_id: "f0".into(),
                value: Some(FormFieldValue::Selection {
                    option_ids: vec!["o1".into()],
                    other: Some("Green".into()),
                }),
            }],
        );
        assert_eq!(answers.len(), 1);
        assert_eq!(answers[0].field.as_str(), "Which one fits?");
        assert_eq!(
            answers[0].values,
            vec!["Blue".to_owned(), "Green".to_owned()]
        );
    }

    #[test]
    fn approval_buttons_carry_the_decision_and_require_approve() {
        let interaction = InteractionId::new("req-1").unwrap();
        let actions = card_actions(
            &interaction,
            &[CardAction {
                decision: "accept".into(),
                label: "Yes".into(),
                style: ActionStyle::Primary,
            }],
        )
        .unwrap();
        let action = &actions.rows[0].actions[0];
        assert_eq!(action.text, "Yes");
        assert_eq!(
            action.required_grant,
            proto::AgentGrantRequirement::Approve as i32
        );
        let Some(proto::message_action::Action::Callback(callback)) = &action.action else {
            panic!("callback");
        };
        let data: ActionData = serde_json::from_slice(&callback.data).unwrap();
        assert_eq!(
            data,
            ActionData::Decision {
                i: "req-1".into(),
                d: "accept".into()
            }
        );
    }

    #[test]
    fn a_limit_notice_says_when_the_agent_can_work_again() {
        assert_eq!(
            limit_notice("Codex", Some(1_000 + 7_500), 1_000),
            "Codex reached its usage limit. It can work again in about 2 h 5 min."
        );
        assert_eq!(
            limit_notice("Claude", Some(1_030), 1_000),
            "Claude reached its usage limit. It can work again in about 1 min."
        );
        assert_eq!(
            limit_notice("Codex", None, 1_000),
            "Codex reached its usage limit. It can work again when the limit resets."
        );
    }
}

#[cfg(test)]
pub(crate) mod recovery_tests {
    use super::*;
    pub(crate) async fn acp_migration_preserves_unavailable_session(agent: Arc<Agent>) {
        let mut work = actor(agent);
        work.native_from_v1 = true;
        let native = work.native.clone().unwrap();
        assert!(
            work.open(OpenMode::Resume {
                session: native.clone()
            })
            .await
            .is_err()
        );
        assert_eq!(work.native, Some(native));
        assert!(work.native_from_v1);
        assert!(work.session.is_none());
    }

    fn actor(agent: Arc<Agent>) -> Actor {
        let chat_id = 9;
        let known = Known {
            agent_session_id: Some(1),
            native: Some(ProviderSessionId::new("fault-session").unwrap()),
            from_v1: false,
        };
        let output_mode = OutputMode::Detailed;
        let thread_settings = SettingsChange::default();
        let (tx, _rx) = mpsc::channel(64);
        let commands = CommandSender(tx).downgrade();
        let (phase_tx, _phase) = watch::channel(WorkPhase::Idle);
        let agent_session_id = Arc::new(AtomicI64::new(1));
        let outbox = agent
            .ledger
            .outputs(chat_id)
            .unwrap_or_else(|error| {
                log::error!(target: "inline::bridge::v2", "cannot restore output queue: {error}");
                Vec::new()
            })
            .into_iter()
            .filter_map(|payload| match serde_json::from_str(&payload) {
                Ok(outgoing) => Some(outgoing),
                Err(error) => {
                    log::error!(target: "inline::bridge::v2", "invalid retained output: {error}");
                    None
                }
            })
            .collect();
        Actor {
            hold: HoldMachine::new(agent.idle_release()),
            renderer: Renderer::new(output_mode, agent.vocabulary, agent.agent_name.clone()),
            agent,
            chat_id,
            commands,
            publication: Publication::new(ChatId(chat_id)),
            parent_card: None,
            parent_card_text: None,
            agent_session_id: agent_session_id.clone(),
            native: known.native,
            native_from_v1: known.from_v1,
            session: None,
            events: None,
            probe: None,
            inputs: HashMap::new(),
            retained: Vec::new(),
            removing: HashSet::new(),
            paused: false,
            stopping: false,
            turn: None,
            turn_started: None,
            waiting: None,
            live: Default::default(),
            cards: HashMap::new(),
            card_by_interaction: HashMap::new(),
            release_card: None,
            offers: HashMap::new(),
            slots: HashMap::new(),
            edits: HashMap::new(),
            reported: None,
            working_due: None,
            phase: phase_tx,
            update_busy: crate::bridge::update_activity::global().key(),
            started_ms: now_ms(),
            passive: PassiveBatch::new(chat_id),
            title: None,
            rename_pending: false,
            settings_pending: !settings::effective(&thread_settings).is_empty(),
            settings: thread_settings,
            consider: ConsiderQueue::default(),
            consider_lines: HashMap::new(),
            answer_replies: HashMap::new(),
            answer_to: None,
            unsaved: std::sync::Mutex::new(HashMap::new()),
            uncertain: HashMap::new(),
            outbox,
            rendering_turn: None,
            last_turn_input: None,
        }
    }

    pub(crate) async fn pending_output_survives_restart(agent: Arc<Agent>) {
        let mut work = actor(agent.clone());
        work.render(vec![RenderOp::Final {
            doc: paragraph("retained final"),
        }])
        .await;
        assert_eq!(work.outbox.len(), 1);
        let final_id = work.outbox[0].random_id;
        drop(work);
        let mut work = actor(agent.clone());
        assert_eq!(work.outbox[0].random_id, final_id);
        assert_eq!(work.outbox[0].doc.text, "retained final");
        // A live card cannot post without an adopted native interaction.
        let interaction = InteractionId::new("pending-approval").unwrap();
        work.render(vec![RenderOp::Card {
            interaction: interaction.clone(),
            doc: paragraph("Approve?"),
            actions: vec![],
            form: None,
        }])
        .await;
        let card_id = work.output_id("card", Some(interaction.as_str()));
        work.render(vec![RenderOp::CardClosed {
            interaction,
            doc: paragraph("Cancelled"),
        }])
        .await;
        drop(work);
        let work = actor(agent);
        let closed = work
            .outbox
            .iter()
            .find(|out| out.random_id == card_id)
            .unwrap();
        assert!(closed.closed);
        assert!(closed.card.is_none());
        assert_eq!(closed.doc.text, "Cancelled");
        assert!(work.waiting.is_none());
    }

    pub(crate) async fn unavailable_move_lookup_keeps_publication_fenced(agent: Arc<Agent>) {
        let mut work = actor(agent);
        let effects = work.publication.handle(PublicationEvent::MoveRequested {
            destination: ChatId(10),
        });
        let card = ParentCard {
            title: "child".into(),
            summary: None,
            agent_session_id: 1,
        };
        assert!(
            tokio::time::timeout(
                Duration::from_millis(100),
                work.publication_effects(effects, Some(&card))
            )
            .await
            .is_err()
        );
        assert_eq!(work.publication.chat(), None);
    }
}
