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

use futures_util::StreamExt;
use inline_agent_bridge::group::{
    Grants, GuideFacts, HandoffInstruction, HandoffProvider, HandoffTarget, HoldEffect, HoldEvent,
    HoldMachine, HoldState, IdleRelease, Operation, PendingInput, ReleaseCause, ReleaseReceipt,
    ReleaseRequest, ReleaseStep, ReleaseStepOutcome, WorkPhase, handoff_instruction, release_event,
    run_state_event, trusted_guide,
};
use inline_agent_bridge::harness::{
    Delivery, Event, EventStream, FieldAnswer, FieldId, FieldInput, HarnessDriver, HeldBy, Input,
    InputDisposition, InputFact, InputId, InteractionId, InteractionResponse, Op, OpError, OpKind,
    OpenError, OpenMode, OpenSpec, OutputMode, QuestionForm, QueueOp, RunState, SendError, Session,
    SteerPriority, TurnPhase, UserId, WaitingOn,
};
use inline_agent_bridge::{ProviderSessionId, TurnId};
use inline_client::{FormFieldValue, FormValue, InlineClient};
use inline_protocol::proto;
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, oneshot, watch};

use super::api::{self, Notify, chat_peer};
use super::doc::{Doc, DocBuilder};
use super::ledger::{InputState, Ledger};
use super::render::{ActionStyle, CardAction, FullDetail, RenderOp, Renderer, Vocabulary};

/// Progress edits are coalesced to at most one per slot in this window.
const EDIT_INTERVAL: Duration = Duration::from_millis(1200);
const TICK: Duration = Duration::from_secs(15);
const NOT_PENDING: &str = "This request is no longer pending.";
const NO_ACCESS: &str = "You don't have access to do that with this agent.";
/// Full details kept for "Full output", newest first out.
const MAX_FULL_DETAILS: usize = 32;
const MAX_FULL_DETAIL_BYTES: usize = 4 * 1024 * 1024;

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
}

impl Agent {
    fn handoff_provider(&self) -> HandoffProvider {
        match self.vocabulary {
            Vocabulary::Codex => HandoffProvider::Codex,
            Vocabulary::Claude => HandoffProvider::Claude,
        }
    }

    fn idle_release(&self) -> IdleRelease {
        match self.vocabulary {
            Vocabulary::Codex => IdleRelease::codex(None),
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
    /// Send the untruncated detail of a finished progress message.
    #[serde(rename = "o")]
    FullOutput,
}

pub(crate) enum Command {
    /// Direct input, already recorded in the ledger.
    Input {
        input: Box<Input>,
        pending: PendingInput,
        message_id: i64,
    },
    /// Context the agent observes without a turn.
    Passive {
        input: Box<Input>,
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
}

/// The main loop's handle on one work.
pub(crate) struct WorkHandle {
    pub tx: mpsc::Sender<Command>,
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
}

/// Starts the actor for one work.
pub(crate) fn spawn(
    agent: Arc<Agent>,
    chat_id: i64,
    known: Known,
    output_mode: OutputMode,
) -> WorkHandle {
    let (tx, rx) = mpsc::channel(64);
    let (phase_tx, phase) = watch::channel(if known.native.is_some() {
        WorkPhase::Idle
    } else {
        WorkPhase::None
    });
    let agent_session_id = Arc::new(AtomicI64::new(known.agent_session_id.unwrap_or(0)));
    let actor = Actor {
        hold: HoldMachine::new(agent.idle_release()),
        renderer: Renderer::new(output_mode, agent.vocabulary, agent.agent_name.clone()),
        agent,
        chat_id,
        agent_session_id: agent_session_id.clone(),
        native: known.native,
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
        full: VecDeque::new(),
        reported: None,
        phase: phase_tx,
        started_ms: now_ms(),
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
    interaction: InteractionId,
    approval: bool,
    form: Option<QuestionForm>,
}

struct PendingEdit {
    doc: Doc,
    due: tokio::time::Instant,
}

struct Actor {
    agent: Arc<Agent>,
    chat_id: i64,
    agent_session_id: Arc<AtomicI64>,
    native: Option<ProviderSessionId>,
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
    /// Finished progress message → the detail it shows cut short.
    full: VecDeque<(i64, Vec<FullDetail>)>,
    reported: Option<(i32, i32)>,
    phase: watch::Sender<WorkPhase>,
    started_ms: u64,
}

impl Actor {
    async fn run(mut self, mut rx: mpsc::Receiver<Command>) {
        let mut tick = tokio::time::interval(TICK);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            let next_edit = self.edits.values().map(|edit| edit.due).min();
            tokio::select! {
                command = rx.recv() => {
                    let Some(command) = command else { break };
                    self.command(command).await;
                }
                envelope = next_envelope(&mut self.events) => match envelope {
                    Some(envelope) => self.envelope(envelope).await,
                    None => {
                        // The stream ended: the process exited or the
                        // connection closed.
                        self.events = None;
                        self.session = None;
                        self.event(HoldEvent::Detached).await;
                    }
                },
                _ = tick.tick() => {
                    self.event(HoldEvent::Tick).await;
                }
                _ = sleep_until(next_edit) => self.flush_edits(false).await,
            }
            self.publish_phase();
        }
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
            } => {
                // Direct input restarts paused work (spec §4.5).
                self.paused = false;
                self.inputs
                    .insert(input.id.clone(), (*input, pending.clone(), message_id));
                self.event(HoldEvent::AcquireRequested {
                    input: Some(pending),
                })
                .await;
            }
            Command::Passive { input } => {
                // Best effort: context only reaches a session this bridge holds.
                if let Some(session) = self.held_session() {
                    let _ = session.send(*input).await;
                }
            }
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
            Command::SetMode(mode) => self.renderer.set_mode(mode),
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
                    Ok(_) => self.mark(&input, InputState::Pending),
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
            ActionData::FullOutput => {
                if !grants.any() {
                    return Some(NO_ACCESS.to_owned());
                }
                let Some((_, details)) = self.full.iter().find(|(id, _)| *id == message_id) else {
                    return Some(
                        "That output is no longer kept; it is in the session history.".to_owned(),
                    );
                };
                let text = details
                    .iter()
                    .map(|detail| format!("## {}\n\n{}", detail.title, detail.text))
                    .collect::<Vec<_>>()
                    .join("\n\n");
                let bytes = text.into_bytes();
                let request = inline_client::UploadRequest {
                    peer: inline_client::PeerRef::Chat {
                        chat_id: inline_client::InlineId::new(self.chat_id),
                    },
                    kind: inline_client::MediaKind::Document,
                    file_name: Some("output.txt".to_owned()),
                    mime_type: Some("text/plain".to_owned()),
                    size_bytes: Some(bytes.len() as u64),
                    caption: None,
                    width: None,
                    height: None,
                    duration_ms: None,
                    external_id: None,
                    random_id: None,
                    reply_to_message_id: Some(inline_client::InlineId::new(message_id)),
                };
                match self.agent.bot.send_media(request, bytes).await {
                    Ok(_) => None,
                    Err(error) => Some(format!("Could not send the output: {error}")),
                }
            }
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
            let effects = self.hold.handle(event, now_ms());
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
            HoldEffect::Fork { pending } => {
                let Some(native) = self.native.clone() else {
                    self.notice("There is no session to fork.").await;
                    return None;
                };
                match self
                    .open(OpenMode::Fork {
                        session: native,
                        at: None,
                    })
                    .await
                {
                    Ok(()) => {
                        for input in pending {
                            self.deliver(input).await;
                        }
                        None
                    }
                    Err(error) => {
                        self.notice(&format!("Could not fork the session: {error}"))
                            .await;
                        None
                    }
                }
            }
            HoldEffect::Lost => {
                self.session = None;
                self.events = None;
                self.turn = None;
                self.notice(&format!(
                    "{} stopped unexpectedly. Your next message starts it again.",
                    self.agent.agent_name
                ))
                .await;
                None
            }
        }
    }

    async fn acquire(&mut self) -> Option<HoldEvent> {
        if let Some(session) = self.probe.take() {
            self.attach(session);
            return Some(HoldEvent::Acquired);
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
        let fresh = !matches!(mode, OpenMode::Resume { .. });
        let session = match self.open_session(mode.clone()).await {
            Err(OpenFailure::Other(message))
                if matches!(mode, OpenMode::Resume { .. }) && message == NOT_FOUND =>
            {
                // The native session is gone; start a new one and say so.
                self.notice(&format!(
                    "The previous {} session was not found on this machine, so a new one started.",
                    self.agent.agent_name
                ))
                .await;
                self.open_session(OpenMode::Start).await?
            }
            other => other?,
        };
        let native = session.key().session.clone();
        if fresh || self.native.as_ref() != Some(&native) {
            self.connect(&native).await.map_err(OpenFailure::Other)?;
        }
        self.native = Some(native);
        self.attach(session);
        Ok(())
    }

    async fn open_session(&self, mode: OpenMode) -> Result<Arc<dyn Session>, OpenFailure> {
        self.agent
            .harness
            .open(OpenSpec {
                mode,
                folder: self.agent.folder.clone(),
                settings: Default::default(),
                instructions: Some(trusted_guide(GuideFacts {
                    bot_user_id: self.agent.bot_user_id,
                    owner_user_id: self.agent.owner_user_id,
                    inline_tools: false,
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
                    .agent
                    .folder
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned()),
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
        if !matches!(input.delivery, Delivery::Queue | Delivery::Passive) {
            input.delivery = match live_turn(&session) {
                Some(turn) => Delivery::Steer {
                    expected_turn: turn,
                    priority: SteerPriority::Next,
                },
                None => Delivery::Turn,
            };
        }
        self.mark(&pending.id, InputState::Sent);
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
                self.mark(&pending.id, InputState::Accepted);
                if let InputDisposition::Started { turn } | InputDisposition::Steered { turn } =
                    receipt.disposition
                {
                    self.turn = Some(turn);
                }
            }
            Err(SendError::Unknown(reason)) => {
                self.mark(&pending.id, InputState::Unknown);
                self.reply(
                    message_id,
                    &format!(
                        "{} may or may not have received this ({reason}). It was not sent again; check before resending.",
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
        if let Some(native) = &self.native {
            match handoff_instruction(
                self.agent.handoff_provider(),
                HandoffTarget::Terminal,
                native.as_str(),
                Some(&self.agent.folder),
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
    // Session events
    // ---------------------------------------------------------------

    async fn envelope(&mut self, envelope: inline_agent_bridge::harness::Envelope) {
        match &envelope.event {
            Event::Turn { turn, phase } => match phase {
                TurnPhase::Started { inputs } => {
                    self.turn = Some(turn.clone());
                    self.turn_started = Some(now_ms() as i64 / 1000);
                    for input in inputs {
                        self.mark(input, InputState::Consumed);
                        self.inputs.remove(input);
                    }
                }
                TurnPhase::Completed {
                    inputs_consumed, ..
                } => {
                    for input in inputs_consumed {
                        self.mark(input, InputState::Consumed);
                        self.inputs.remove(input);
                    }
                    if self.turn.as_ref() == Some(turn) {
                        self.turn = None;
                        self.turn_started = None;
                    }
                    self.stopping = false;
                    self.waiting = None;
                }
            },
            Event::Input { id, fact } => match fact {
                InputFact::Consumed { .. } => {
                    self.mark(id, InputState::Consumed);
                    self.inputs.remove(id);
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
                    on: WaitingOn::Limit { .. },
                } = state
                {
                    self.waiting = Some((proto::AgentWaitingReason::Limit, 0));
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

    async fn render(&mut self, ops: Vec<RenderOp>) {
        for op in ops {
            match op {
                RenderOp::Progress { slot, doc } => match self.slots.get(&slot) {
                    Some(_) => {
                        let due = tokio::time::Instant::now() + EDIT_INTERVAL;
                        self.edits
                            .entry(slot)
                            .and_modify(|edit| edit.doc = doc.clone())
                            .or_insert(PendingEdit { doc, due });
                    }
                    None => {
                        if let Some(id) = self.send(&doc, None, Notify::Silent).await {
                            self.slots.insert(slot, id);
                        }
                    }
                },
                RenderOp::EndProgress { slot, doc, full } => {
                    self.edits.remove(&slot);
                    let actions = (!full.is_empty())
                        .then(|| {
                            button_rows(&[(
                                "Full output",
                                ActionData::FullOutput,
                                ActionStyle::Default,
                            )])
                        })
                        .flatten();
                    let message_id = match self.slots.remove(&slot) {
                        Some(message_id) => {
                            self.edit(message_id, &doc, actions).await;
                            Some(message_id)
                        }
                        None => self.send(&doc, actions, Notify::Silent).await,
                    };
                    if let Some(message_id) = message_id.filter(|_| !full.is_empty()) {
                        self.keep_full(message_id, full);
                    }
                }
                RenderOp::Update { doc } => {
                    self.send(&doc, None, Notify::Silent).await;
                }
                RenderOp::Final { doc } | RenderOp::Notice { doc } => {
                    // Edits still pending land before the answer.
                    self.flush_edits(true).await;
                    self.send(&doc, None, Notify::Normal).await;
                }
                RenderOp::Card {
                    interaction,
                    doc,
                    actions,
                    form,
                } => {
                    let buttons = card_actions(&interaction, &actions);
                    if let Some(message_id) = self.send(&doc, buttons, Notify::Normal).await {
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
                                interaction,
                                approval: form.is_none(),
                                form,
                            },
                        );
                    }
                }
                RenderOp::CardClosed { interaction, doc } => {
                    if let Some(message_id) = self.card_by_interaction.remove(&interaction) {
                        self.cards.remove(&message_id);
                        if self.waiting.is_some_and(|(_, card)| card == message_id) {
                            self.waiting = None;
                        }
                        self.edit(message_id, &doc, Some(proto::MessageActions::default()))
                            .await;
                    }
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
            if let (Some(edit), Some(message_id)) =
                (self.edits.remove(&slot), self.slots.get(&slot).copied())
            {
                self.edit(message_id, &edit.doc, None).await;
            }
        }
    }

    // ---------------------------------------------------------------
    // Inline output and state
    // ---------------------------------------------------------------

    /// Keeps the full detail of a finished message, bounded by count and size.
    fn keep_full(&mut self, message_id: i64, mut details: Vec<FullDetail>) {
        for detail in &mut details {
            // The message already shows the end; keep the beginning.
            if detail.text.len() > MAX_FULL_DETAIL_BYTES {
                let mut end = MAX_FULL_DETAIL_BYTES;
                while !detail.text.is_char_boundary(end) {
                    end -= 1;
                }
                detail.text.truncate(end);
                detail
                    .text
                    .push_str("\n… (cut at 4 MB; the session history has the rest)");
            }
        }
        self.full.push_back((message_id, details));
        while self.full.len() > MAX_FULL_DETAILS {
            self.full.pop_front();
        }
    }

    fn remember(&self, message_id: i64) {
        self.agent.sent.lock().expect("sent").insert(message_id);
    }

    async fn send(
        &self,
        doc: &Doc,
        actions: Option<proto::MessageActions>,
        notify: Notify,
    ) -> Option<i64> {
        if doc.is_empty() {
            return None;
        }
        match api::send_doc(&self.agent.bot, self.chat_id, None, doc, actions, notify).await {
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
        if let Err(error) =
            api::edit_doc(&self.agent.bot, self.chat_id, message_id, doc, actions).await
        {
            log::warn!(target: "inline::bridge::v2", "edit failed: {error}");
        }
    }

    async fn notice(&self, text: &str) -> Option<i64> {
        self.send(&paragraph(text), None, Notify::Normal).await
    }

    async fn notice_with(&self, text: &str, actions: Option<proto::MessageActions>) -> Option<i64> {
        self.send(&paragraph(text), actions, Notify::Normal).await
    }

    async fn reply(&self, message_id: i64, text: &str) {
        match api::send_doc(
            &self.agent.bot,
            self.chat_id,
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

    fn mark(&self, input: &InputId, state: InputState) {
        if let Err(error) = self.agent.ledger.set(input.as_str(), state) {
            log::warn!(target: "inline::bridge::v2", "ledger update failed: {error}");
        }
    }

    fn publish_phase(&self) {
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
        let run_state = match self.hold.state() {
            HoldState::HeldElsewhere { .. } => proto::AgentRunState::HeldElsewhere,
            HoldState::ConfirmingRelease { .. }
            | HoldState::Releasing { .. }
            | HoldState::ReleaseFenced { .. }
            | HoldState::Detaching { .. } => proto::AgentRunState::Releasing,
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
        let key = (state.run_state, state.waiting_reason);
        if self.reported == Some(key) {
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

fn paragraph(text: &str) -> Doc {
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

fn button_rows(buttons: &[(&str, ActionData, ActionStyle)]) -> Option<proto::MessageActions> {
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
                    text: action.label.clone(),
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
        .filter_map(|field| {
            let value = values
                .iter()
                .find(|value| value.field_id == field.id.as_str())?
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
    use inline_agent_bridge::harness::{FieldOption, FormField};

    #[test]
    fn form_answers_map_options_to_labels() {
        let form = QuestionForm {
            title: None,
            fields: vec![FormField {
                id: FieldId::new("pick").unwrap(),
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
                field_id: "pick".into(),
                value: Some(FormFieldValue::Selection {
                    option_ids: vec!["o1".into()],
                    other: Some("Green".into()),
                }),
            }],
        );
        assert_eq!(answers.len(), 1);
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
}
