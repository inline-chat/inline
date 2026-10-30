//! The ACP driver on the bridge v2 session contract (spec §4.1 "ACP host").
//!
//! ACP stays the path for OpenCode and Amp, and Claude's emergency path when
//! a Claude release breaks the Rust driver. It is turn-scoped underneath, so
//! this adapter declares the reduced capability set: turns, steering where
//! the agent supports it, stop, approvals, questions and compaction; no
//! native queue, passive context, fork or session browser.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use futures_util::StreamExt;
use inline_agent_bridge::harness::{
    ApprovalSubject, Availability, AvailabilityMatrix, CapabilityManifest, Catalog, CatalogScope,
    ClosedBy, CompatTier, DEFAULT_HUB_CAPACITY, Decision, DecisionId, DecisionKind, Delivery,
    DeliveryKind, DeltaStream, Event, EventHub, EventStream, ExecutableInfo, FieldAnswer, FieldId,
    FieldInput, FieldOption, FileChangeKind, FileDiff, FormField, HarnessDriver, HarnessFuture,
    Input, InputDisposition, InputId, InputReceipt, Interaction, InteractionId, InteractionKind,
    InteractionResponse, Item, ItemBody, ItemDelta, ItemId, ItemKind, ItemStatus, ItemUpdate,
    LiveWork, MessageRole, Notice, NoticeLevel, Op, OpError, OpKind, OpOutcome, OpenError,
    OpenMode, OpenSpec, QuestionForm, ReleaseOutcome, Released, RunState, RunStateTracker,
    RuntimeHealth, RuntimeInfo, SendError, Session, SessionKey, SessionPage, SessionQuery,
    SettingsScope, TurnPhase, UserId,
};
use inline_agent_bridge::{
    ActivitySemanticKind, ActivityStatus, ActivityTextStream, AgentDriver, AgentEvent,
    AgentMessageUpdate, ApprovalDecision, ApprovalOption, ApprovalRequest, DriverError,
    DriverFuture, ProviderId, ProviderSessionId, QuestionAnswer, QuestionRequest,
    ResumeSessionSpec, SessionReplay, SessionSpec, SteeringSupport, TurnId, TurnInput, TurnOptions,
    TurnOutcome,
};
use serde_json::{Value, json};

/// The reduced capability set ACP can honour for `driver`.
pub fn acp_availability(driver: &dyn AgentDriver) -> AvailabilityMatrix {
    let capabilities = driver.capabilities();
    let reduced = |reason: &str| Availability::unavailable(format!("{reason} (reduced mode: ACP)"));
    let steer = if matches!(capabilities.steering, SteeringSupport::Unsupported) {
        reduced("this agent cannot be steered mid-turn")
    } else {
        Availability::Supported
    };
    let supported_if = |flag: bool, reason: &str| {
        if flag {
            Availability::Supported
        } else {
            reduced(reason)
        }
    };
    AvailabilityMatrix::default()
        .with_delivery(DeliveryKind::Turn, Availability::Supported)
        .with_delivery(DeliveryKind::SteerNext, steer.clone())
        // ACP has one steer; "now" maps onto it.
        .with_delivery(DeliveryKind::SteerNow, steer)
        .with_delivery(DeliveryKind::Queue, reduced("no native queue"))
        .with_delivery(DeliveryKind::Passive, reduced("no passive context"))
        .with_op(
            OpKind::Interrupt,
            supported_if(capabilities.cancel_turn, "stop is unsupported"),
        )
        .with_op(OpKind::InterruptCancelQueued, reduced("no native queue"))
        .with_op(
            OpKind::Compact,
            supported_if(capabilities.compact_session, "compaction is unsupported"),
        )
        .with_op(
            OpKind::SettingsThread,
            supported_if(capabilities.settings_catalog, "settings are unsupported"),
        )
        .with_op(OpKind::Answer, Availability::Supported)
        .with_op(OpKind::QueueStart, reduced("no native queue"))
        .with_op(OpKind::QueueEdit, reduced("no native queue"))
        .with_op(
            OpKind::SettingsTurn,
            reduced("settings apply from the next message on"),
        )
        .with_op(
            OpKind::SettingsPersisted,
            reduced("defaults are set in Agent Settings"),
        )
        .with_op(OpKind::Rename, reduced("no session rename"))
        .with_op(OpKind::Archive, reduced("no archive"))
        .with_op(OpKind::Clear, reduced("no clear"))
        .with_op(OpKind::RewindFiles, reduced("no file rewind"))
        .with_op(OpKind::Mode, reduced("no modes"))
        .with_op(OpKind::Review, reduced("no review"))
        .with_op(OpKind::Goal, reduced("no goals"))
        .with_op(OpKind::StopChild, reduced("no children"))
        .with_op(OpKind::Sample, reduced("no side calls"))
        .with_op(OpKind::McpAuth, reduced("no MCP sign-in"))
}

/// An ACP agent behind the session contract.
pub struct AcpHarness {
    driver: Arc<dyn AgentDriver>,
    provider: ProviderId,
    executable: ExecutableInfo,
    driver_version: String,
    process_status: Option<crate::AcpProcessStatus>,
    catalog_sessions: tokio::sync::Mutex<HashMap<PathBuf, ProviderSessionId>>,
}

impl AcpHarness {
    pub fn new(
        driver: Arc<dyn AgentDriver>,
        provider: ProviderId,
        executable: ExecutableInfo,
        driver_version: impl Into<String>,
    ) -> Self {
        Self {
            driver,
            provider,
            executable,
            driver_version: driver_version.into(),
            process_status: None,
            catalog_sessions: tokio::sync::Mutex::new(HashMap::new()),
        }
    }

    /// Owns a launched ACP epoch, including on partial runtime startup failure.
    pub fn from_spawned(
        spawned: crate::SpawnedAcpDriver,
        provider: ProviderId,
        executable: ExecutableInfo,
        driver_version: impl Into<String>,
    ) -> Self {
        Self {
            driver: Arc::new(spawned.driver),
            provider,
            executable,
            driver_version: driver_version.into(),
            process_status: Some(spawned.process_status),
            catalog_sessions: tokio::sync::Mutex::new(HashMap::new()),
        }
    }

    pub fn process_status(&self) -> Option<crate::AcpProcessStatus> {
        self.process_status.clone()
    }

    pub async fn shutdown(&self) -> Result<(), DriverError> {
        self.driver.shutdown().await
    }
}

impl Drop for AcpHarness {
    fn drop(&mut self) {
        if self
            .process_status
            .as_ref()
            .is_some_and(|status| !status.is_finished())
            && let Ok(runtime) = tokio::runtime::Handle::try_current()
        {
            let driver = self.driver.clone();
            runtime.spawn(async move {
                let _ = driver.shutdown().await;
            });
        }
    }
}

impl HarnessDriver for AcpHarness {
    fn describe(&self) -> RuntimeInfo {
        RuntimeInfo {
            provider: self.provider.clone(),
            executable: self.executable.clone(),
            driver_version: self.driver_version.clone(),
            health: RuntimeHealth::Ready,
            manifest: Some(CapabilityManifest {
                provider: self.provider.clone(),
                version: self.executable.version.clone(),
                binary_sha256: self.executable.sha256.clone(),
                schema_sha256: None,
                tier: CompatTier::Supported,
                availability: acp_availability(self.driver.as_ref()),
                methods: Default::default(),
                server_requests: Default::default(),
                notifications: Default::default(),
                item_types: Default::default(),
                approval_decisions: Default::default(),
            }),
        }
    }

    fn catalog<'a>(&'a self, scope: CatalogScope) -> DriverFuture<'a, Catalog> {
        Box::pin(async move {
            if !self.driver.capabilities().settings_catalog {
                return Ok(Catalog::default());
            }
            let folder = scope.folder.unwrap_or_else(|| PathBuf::from("/"));
            let mut catalog_sessions = self.catalog_sessions.lock().await;
            let settings = self.driver.settings_catalog(&folder).await?;
            let commands = if self.driver.capabilities().session_commands {
                let session = match scope
                    .session
                    .or_else(|| catalog_sessions.get(&folder).cloned())
                {
                    Some(session) => session,
                    None => {
                        let session = self
                            .driver
                            .start_session(SessionSpec {
                                cwd: folder.clone(),
                            })
                            .await?;
                        catalog_sessions.insert(folder.clone(), session.clone());
                        session
                    }
                };
                self.driver
                    .session_commands(&session)
                    .await
                    .unwrap_or_default()
            } else {
                Vec::new()
            };
            Ok(Catalog {
                models: settings.models,
                permission_modes: settings.permissions,
                commands,
                ..Catalog::default()
            })
        })
    }

    fn sessions<'a>(&'a self, _query: SessionQuery) -> DriverFuture<'a, SessionPage> {
        // ACP lists no sessions; the native drivers own the session browser.
        Box::pin(async { Ok(SessionPage::default()) })
    }

    fn open<'a>(&'a self, spec: OpenSpec) -> HarnessFuture<'a, Arc<dyn Session>, OpenError> {
        Box::pin(async move {
            let session = match &spec.mode {
                OpenMode::Start => self
                    .driver
                    .start_session(SessionSpec {
                        cwd: spec.folder.clone(),
                    })
                    .await
                    .map_err(OpenError::Driver)?,
                OpenMode::Resume { session } => {
                    if !self.driver.capabilities().resume_session {
                        return Err(OpenError::Unavailable(Availability::unavailable(
                            "resume is unsupported (reduced mode: ACP)",
                        )));
                    }
                    self.driver
                        .resume_session(ResumeSessionSpec {
                            session_id: session.clone(),
                            cwd: spec.folder.clone(),
                            replay: SessionReplay::None,
                        })
                        .await
                        .map_err(|error| match error {
                            DriverError::InvalidSession(_) => OpenError::NotFound,
                            other => OpenError::Driver(other),
                        })?;
                    session.clone()
                }
                OpenMode::Fork { .. } => {
                    return Err(OpenError::Unavailable(Availability::unavailable(
                        "fork is unsupported (reduced mode: ACP)",
                    )));
                }
            };
            let key = SessionKey {
                provider: self.provider.clone(),
                session: session.clone(),
            };
            let inner = Arc::new(AcpSessionInner {
                hub: EventHub::new(key.clone(), DEFAULT_HUB_CAPACITY),
                tracker: Mutex::new(RunStateTracker::new(RunState::Idle)),
                state: Mutex::new(AcpState {
                    first_turn_sent: matches!(spec.mode, OpenMode::Resume { .. }),
                    options: TurnOptions {
                        cwd: Some(spec.folder.clone()),
                        model: spec.settings.model.clone(),
                        reasoning: spec.settings.effort.clone(),
                        permissions: spec.settings.permission_mode.clone(),
                    },
                    ..AcpState::default()
                }),
                key,
                session,
                driver: self.driver.clone(),
                instructions: spec.instructions.clone(),
                mutation: tokio::sync::Mutex::new(()),
            });
            self.catalog_sessions
                .lock()
                .await
                .insert(spec.folder, inner.session.clone());
            if let Some(status) = self.process_status.clone() {
                let weak = Arc::downgrade(&inner);
                tokio::spawn(async move {
                    let _ = status.wait().await;
                    if let Some(inner) = weak.upgrade() {
                        let _mutation = inner.mutation.lock().await;
                        let turn = inner.state().turn.clone();
                        if let Some(turn) = turn {
                            complete_if_active(&inner, turn, TurnOutcome::ConnectionLost);
                        }
                        inner.state().released = true;
                        inner.emit(Event::State {
                            state: RunState::Released,
                        });
                    }
                });
            }
            Ok(Arc::new(AcpSession { inner }) as Arc<dyn Session>)
        })
    }
}

#[derive(Default)]
struct AcpState {
    turn: Option<TurnId>,
    turn_inputs: Vec<InputId>,
    options: TurnOptions,
    approvals: HashMap<String, ApprovalRequest>,
    questions: HashMap<String, QuestionRequest>,
    answered: HashSet<String>,
    activities: HashSet<String>,
    first_turn_sent: bool,
    released: bool,
}

struct AcpSessionInner {
    key: SessionKey,
    session: ProviderSessionId,
    driver: Arc<dyn AgentDriver>,
    hub: EventHub,
    tracker: Mutex<RunStateTracker>,
    state: Mutex<AcpState>,
    instructions: Option<String>,
    mutation: tokio::sync::Mutex<()>,
}

impl AcpSessionInner {
    fn state(&self) -> std::sync::MutexGuard<'_, AcpState> {
        self.state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    fn emit(&self, event: Event) {
        let changed = self
            .tracker
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .apply(&event);
        let is_state = matches!(event, Event::State { .. });
        self.hub.emit(event);
        if let Some(state) = changed.filter(|_| !is_state) {
            self.hub.emit(Event::State { state });
        }
    }
}

/// One ACP session.
pub struct AcpSession {
    inner: Arc<AcpSessionInner>,
}

fn turn_input(input: &Input, instructions: Option<&str>, first: bool) -> TurnInput {
    let mut context = input.content.context.clone();
    // The trusted guide rides on the first turn; ACP has no system prompt slot.
    if first && let Some(instructions) = instructions {
        let mut merged = context.unwrap_or_else(|| inline_agent_bridge::TurnContext {
            instructions: String::new(),
            conversation: String::new(),
        });
        if merged.instructions.is_empty() {
            merged.instructions = instructions.to_string();
        } else {
            merged.instructions = format!("{instructions}\n\n{}", merged.instructions);
        }
        context = Some(merged);
    }
    TurnInput {
        text: input.content.text.clone(),
        attachments: input.content.attachments.clone(),
        context,
        client_message_id: Some(input.id.as_str().to_string()),
    }
}

impl Session for AcpSession {
    fn key(&self) -> &SessionKey {
        &self.inner.key
    }

    fn availability(&self) -> AvailabilityMatrix {
        acp_availability(self.inner.driver.as_ref())
    }

    fn events(&self) -> EventStream {
        self.inner.hub.subscribe()
    }

    fn send<'a>(&'a self, input: Input) -> HarnessFuture<'a, InputReceipt, SendError> {
        Box::pin(async move {
            let _mutation = self.inner.mutation.lock().await;
            if self.inner.state().released {
                return Err(SendError::Rejected("session was released".into()));
            }
            let availability = self.availability().delivery(input.delivery.kind());
            if !availability.is_supported() {
                return Err(SendError::Unavailable(availability));
            }
            let active = self.inner.state().turn.clone();
            match (&input.delivery, active) {
                (Delivery::Turn, Some(active)) => Err(SendError::Busy { active }),
                (Delivery::Turn, None) => {
                    let (options, first) = {
                        let state = self.inner.state();
                        let first = !state.first_turn_sent;
                        (state.options.clone(), first)
                    };
                    let turn_input = turn_input(&input, self.inner.instructions.as_deref(), first);
                    let started = self
                        .inner
                        .driver
                        .start_turn(&self.inner.session, turn_input, options)
                        .await
                        .map_err(SendError::Driver)?;
                    let turn = started.turn_id.clone();
                    {
                        let mut state = self.inner.state();
                        state.first_turn_sent |= first;
                        state.turn = Some(turn.clone());
                        state.turn_inputs = vec![input.id.clone()];
                    }
                    self.inner.emit(Event::Turn {
                        turn: turn.clone(),
                        phase: TurnPhase::Started {
                            inputs: vec![input.id.clone()],
                        },
                    });
                    pump_stream(self.inner.clone(), turn.clone(), started.events);
                    Ok(InputReceipt {
                        input: input.id,
                        disposition: InputDisposition::Started { turn },
                        native: Value::Null,
                        acceptance: inline_agent_bridge::harness::Acceptance::Accepted,
                    })
                }
                (Delivery::Steer { expected_turn, .. }, active)
                    if active.as_ref() != Some(expected_turn) =>
                {
                    Err(SendError::TurnMismatch { active })
                }
                (Delivery::Steer { expected_turn, .. }, _) => {
                    self.inner
                        .driver
                        .steer_turn(
                            &self.inner.session,
                            expected_turn,
                            turn_input(&input, None, false),
                        )
                        .await
                        .map_err(SendError::Driver)?;
                    self.inner.state().turn_inputs.push(input.id.clone());
                    Ok(InputReceipt {
                        input: input.id,
                        disposition: InputDisposition::Steered {
                            turn: expected_turn.clone(),
                        },
                        native: Value::Null,
                        acceptance: inline_agent_bridge::harness::Acceptance::Accepted,
                    })
                }
                (Delivery::Queue | Delivery::Passive, _) => {
                    Err(SendError::Unavailable(availability))
                }
            }
        })
    }

    fn control<'a>(&'a self, op: Op) -> HarnessFuture<'a, OpOutcome, OpError> {
        Box::pin(async move {
            let _mutation = self.inner.mutation.lock().await;
            if self.inner.state().released {
                return Err(OpError::Rejected("session was released".into()));
            }
            let availability = self.availability().op(op.kind());
            if !availability.is_supported() {
                return Err(OpError::Unavailable(availability));
            }
            match op {
                Op::Interrupt { .. } => {
                    let turn = self.inner.state().turn.clone();
                    let Some(turn) = turn else {
                        return Ok(OpOutcome::accepted());
                    };
                    let stopping = self
                        .inner
                        .tracker
                        .lock()
                        .unwrap_or_else(|poison| poison.into_inner())
                        .stopping()
                        .clone();
                    self.inner.hub.emit(Event::State { state: stopping });
                    self.inner
                        .driver
                        .cancel_turn(&self.inner.session, &turn)
                        .await
                        .map_err(OpError::Driver)?;
                    complete_if_active(&self.inner, turn, TurnOutcome::Interrupted);
                    Ok(OpOutcome::accepted())
                }
                Op::Compact => {
                    if self.inner.state().turn.is_some() {
                        return Err(OpError::Rejected("a turn is already running".into()));
                    }
                    let started = self
                        .inner
                        .driver
                        .compact_session(&self.inner.session)
                        .await
                        .map_err(OpError::Driver)?;
                    let turn = started.turn_id.clone();
                    self.inner.state().turn = Some(turn.clone());
                    self.inner.emit(Event::Turn {
                        turn: turn.clone(),
                        phase: TurnPhase::Started { inputs: Vec::new() },
                    });
                    pump_stream(self.inner.clone(), turn.clone(), started.events);
                    Ok(OpOutcome::TurnStarted { turn })
                }
                Op::Settings { change, scope } => {
                    if scope != SettingsScope::Thread
                        || change.folder.is_some()
                        || change.speed.is_some()
                    {
                        return Err(OpError::Unavailable(Availability::unavailable(
                            "only model, reasoning and permissions change here (reduced mode: ACP)",
                        )));
                    }
                    if let Some(mode) = change.permission_mode.as_deref() {
                        self.inner
                            .driver
                            .set_session_permissions(&self.inner.session, mode)
                            .await
                            .map_err(OpError::Driver)?;
                    }
                    let mut state = self.inner.state();
                    if change.model.is_some() {
                        state.options.model = change.model;
                    }
                    if change.effort.is_some() {
                        state.options.reasoning = change.effort;
                    }
                    if change.permission_mode.is_some() {
                        state.options.permissions = change.permission_mode;
                    }
                    Ok(OpOutcome::accepted())
                }
                Op::Answer {
                    interaction,
                    response,
                    by,
                } => self.answer(interaction, response, by).await,
                _ => Err(OpError::Unavailable(availability)),
            }
        })
    }

    fn live_work(&self) -> LiveWork {
        let state = self.inner.state();
        LiveWork {
            turn: state.turn.clone(),
            interactions: state
                .approvals
                .keys()
                .chain(state.questions.keys())
                .filter_map(|id| InteractionId::new(id.as_str()).ok())
                .collect(),
            ..LiveWork::default()
        }
    }

    fn release<'a>(&'a self) -> HarnessFuture<'a, Released, OpError> {
        Box::pin(async move {
            let _mutation = self.inner.mutation.lock().await;
            let cancelled = self.live_work().interactions;
            let turn = self.inner.state().turn.clone();
            if let Some(turn) = turn {
                self.inner
                    .driver
                    .cancel_turn(&self.inner.session, &turn)
                    .await
                    .map_err(OpError::Driver)?;
                complete_if_active(&self.inner, turn, TurnOutcome::Interrupted);
            }
            self.inner.state().released = true;
            Ok(Released {
                key: self.inner.key.clone(),
                outcome: ReleaseOutcome::Unsubscribed,
                cancelled_interactions: cancelled,
                pending_inputs: Vec::new(),
                stopped_children: Vec::new(),
            })
        })
    }
}

impl AcpSession {
    async fn answer(
        &self,
        interaction: InteractionId,
        response: InteractionResponse,
        by: UserId,
    ) -> Result<OpOutcome, OpError> {
        let id = interaction.as_str().to_string();
        let (approval, question) = {
            let state = self.inner.state();
            (
                state.approvals.get(&id).cloned(),
                state.questions.get(&id).cloned(),
            )
        };
        let picked = match (approval, question, &response) {
            (Some(approval), _, InteractionResponse::Decision { decision, .. }) => {
                let index: usize = decision
                    .as_str()
                    .strip_prefix("option:")
                    .and_then(|index| index.parse().ok())
                    .filter(|index| *index < approval.options.len())
                    .ok_or_else(|| {
                        OpError::InvalidResponse(format!("decision {decision} was not offered"))
                    })?;
                let native = approval_decision(&approval.options[index]);
                self.inner
                    .driver
                    .resolve_approval(&id, native)
                    .await
                    .map_err(OpError::Driver)?;
                Some(decision.clone())
            }
            (Some(_), _, InteractionResponse::Cancel) => {
                self.inner
                    .driver
                    .resolve_approval(&id, ApprovalDecision::Reject)
                    .await
                    .map_err(OpError::Driver)?;
                None
            }
            (None, Some(_), InteractionResponse::Answers { answers }) => {
                let answers = answers.iter().map(question_answer).collect();
                self.inner
                    .driver
                    .resolve_question(&id, answers)
                    .await
                    .map_err(OpError::Driver)?;
                None
            }
            (None, Some(question), InteractionResponse::Cancel) => {
                let empty = question
                    .questions
                    .iter()
                    .map(|question| QuestionAnswer {
                        question_id: question.question_id.clone(),
                        answers: Vec::new(),
                    })
                    .collect();
                self.inner
                    .driver
                    .resolve_question(&id, empty)
                    .await
                    .map_err(OpError::Driver)?;
                None
            }
            (None, None, _) => return Err(OpError::InteractionNotPending),
            _ => {
                return Err(OpError::InvalidResponse(
                    "response does not fit this interaction".into(),
                ));
            }
        };
        {
            let mut state = self.inner.state();
            state.approvals.remove(&id);
            state.questions.remove(&id);
            state.answered.insert(id);
        }
        self.inner.emit(Event::InteractionClosed {
            id: interaction,
            by: ClosedBy::Inline {
                user: by,
                decision: picked,
            },
        });
        Ok(OpOutcome::accepted())
    }
}

fn question_answer(answer: &FieldAnswer) -> QuestionAnswer {
    QuestionAnswer {
        question_id: answer.field.as_str().to_string(),
        answers: answer.values.clone(),
    }
}

fn approval_decision(option: &ApprovalOption) -> ApprovalDecision {
    match option {
        ApprovalOption::ApproveOnce => ApprovalDecision::ApproveOnce,
        ApprovalOption::ApproveForSession => ApprovalDecision::ApproveForSession,
        ApprovalOption::Reject => ApprovalDecision::Reject,
        ApprovalOption::CancelTurn => ApprovalDecision::CancelTurn,
        ApprovalOption::ProviderChoice { option_id, .. } => ApprovalDecision::ProviderChoice {
            option_id: option_id.clone(),
        },
    }
}

fn decision(index: usize, option: &ApprovalOption) -> Option<Decision> {
    let (label, kind) = match option {
        ApprovalOption::ApproveOnce => ("Allow once".to_string(), DecisionKind::Accept),
        ApprovalOption::ApproveForSession => {
            ("Always allow".to_string(), DecisionKind::AcceptForSession)
        }
        ApprovalOption::Reject => ("Reject".to_string(), DecisionKind::Decline),
        ApprovalOption::CancelTurn => ("Reject and stop".to_string(), DecisionKind::Cancel),
        ApprovalOption::ProviderChoice { label, option_id } => (
            label.clone(),
            if option_id.contains("allow_always") {
                DecisionKind::AcceptForSession
            } else if option_id.contains("allow") {
                DecisionKind::Accept
            } else if option_id.contains("reject") {
                DecisionKind::Decline
            } else {
                DecisionKind::Other
            },
        ),
    };
    Some(Decision {
        id: DecisionId::new(format!("option:{index}")).ok()?,
        label,
        kind,
        description: None,
        accepts_message: false,
        native: serde_json::to_value(option).unwrap_or(Value::Null),
    })
}

fn item_id(id: &str) -> ItemId {
    ItemId::new(id).unwrap_or_else(|_| ItemId::new(uuid::Uuid::new_v4().to_string()).expect("uuid"))
}

fn complete_if_active(inner: &AcpSessionInner, turn: TurnId, outcome: TurnOutcome) {
    pump(
        inner,
        Ok(AgentEvent::TurnCompleted {
            turn_id: turn,
            outcome,
            error: None,
            timing: Default::default(),
        }),
    );
}

fn pump_stream(
    inner: Arc<AcpSessionInner>,
    turn: TurnId,
    mut events: inline_agent_bridge::AgentEventReceiver,
) {
    tokio::spawn(async move {
        while let Some(event) = events.next().await {
            // A cancellation barrier may already have ended this turn. Never
            // let its late output or stream closure touch the next turn.
            if inner.state().turn.as_ref() != Some(&turn) {
                break;
            }
            let terminal = matches!(&event, Ok(AgentEvent::TurnCompleted { .. }));
            pump(&inner, event);
            if terminal {
                break;
            }
        }
        complete_if_active(&inner, turn, TurnOutcome::ConnectionLost);
    });
}

fn pump(inner: &AcpSessionInner, event: inline_agent_bridge::DriverResult<AgentEvent>) {
    let event = match event {
        Ok(event) => event,
        Err(error) => {
            inner.emit(Event::Notice(Notice {
                level: NoticeLevel::Error,
                code: "acp_error".into(),
                message: Some(error.to_string()),
                native: Value::Null,
            }));
            return;
        }
    };
    let native = serde_json::to_value(&event).unwrap_or(Value::Null);
    for mapped in map_event(inner, event, native) {
        inner.emit(mapped);
    }
}

fn map_event(inner: &AcpSessionInner, event: AgentEvent, native: Value) -> Vec<Event> {
    match event {
        // The adapter emits the start itself when the turn is accepted.
        AgentEvent::TurnStarted { .. } => Vec::new(),
        AgentEvent::AgentMessage {
            turn_id,
            item_id: id,
            phase,
            update,
        } => {
            let update = match update {
                AgentMessageUpdate::Started => ItemUpdate::Started {
                    body: ItemBody::Message {
                        role: MessageRole::Assistant,
                        text: String::new(),
                        input: None,
                    },
                },
                AgentMessageUpdate::Delta(text) => ItemUpdate::Delta {
                    delta: ItemDelta {
                        stream: DeltaStream::Text,
                        index: None,
                        text,
                    },
                },
                AgentMessageUpdate::Completed(text) => ItemUpdate::Completed {
                    body: ItemBody::Message {
                        role: MessageRole::Assistant,
                        text,
                        input: None,
                    },
                    status: ItemStatus::Completed,
                },
            };
            vec![Event::Item(
                Item::new(item_id(&id), Some(turn_id), update, native)
                    .with_kind(ItemKind::Message)
                    .with_phase(phase),
            )]
        }
        AgentEvent::AgentTextDelta { turn_id, text } => vec![Event::Item(
            Item::new(
                item_id(&format!("{turn_id}:text")),
                Some(turn_id),
                ItemUpdate::Delta {
                    delta: ItemDelta {
                        stream: DeltaStream::Text,
                        index: None,
                        text,
                    },
                },
                native,
            )
            .with_kind(ItemKind::Message),
        )],
        AgentEvent::AgentTextCompleted { turn_id, text } => vec![Event::Item(Item::new(
            item_id(&format!("{turn_id}:text")),
            Some(turn_id),
            ItemUpdate::Completed {
                body: ItemBody::Message {
                    role: MessageRole::Assistant,
                    text,
                    input: None,
                },
                status: ItemStatus::Completed,
            },
            native,
        ))],
        AgentEvent::Activity { summary, .. } => vec![Event::Notice(Notice {
            level: NoticeLevel::Info,
            code: "activity".into(),
            message: Some(summary),
            native,
        })],
        AgentEvent::ActivityUpsert { turn_id, activity } => {
            let body = match activity.kind {
                ActivitySemanticKind::Execute if activity.detail.is_some() => ItemBody::Command {
                    command: activity.detail.clone().unwrap(),
                    cwd: None,
                    actions: Vec::new(),
                    output: activity.output_snapshot.clone(),
                    exit_code: activity.exit_code,
                    duration_ms: None,
                },
                ActivitySemanticKind::Edit
                | ActivitySemanticKind::Delete
                | ActivitySemanticKind::Move => ItemBody::FileChange {
                    changes: activity
                        .paths
                        .iter()
                        .map(|path| FileDiff {
                            path: path.clone(),
                            change: match activity.kind {
                                ActivitySemanticKind::Delete => FileChangeKind::Delete,
                                _ => FileChangeKind::Update { moved_to: None },
                            },
                            diff: None,
                        })
                        .collect(),
                },
                ActivitySemanticKind::Think => ItemBody::Reasoning {
                    summary: activity.detail.clone().into_iter().collect(),
                    content: activity.reasoning_content.clone(),
                },
                _ => ItemBody::Tool {
                    name: activity.title.clone(),
                    server: None,
                    input: if activity.details.is_empty() {
                        Value::Null
                    } else {
                        json!({"details": activity.details.iter().map(|detail| json!({"label": detail.label, "value": detail.value})).collect::<Vec<_>>()})
                    },
                    output: activity.output_snapshot.clone(),
                    error: None,
                },
            };
            let first = inner
                .state()
                .activities
                .insert(activity.activity_id.clone());
            let update = match activity.status {
                ActivityStatus::Pending | ActivityStatus::InProgress if first => {
                    ItemUpdate::Started { body }
                }
                ActivityStatus::Pending | ActivityStatus::InProgress => {
                    ItemUpdate::Updated { body }
                }
                ActivityStatus::Completed => ItemUpdate::Completed {
                    body,
                    status: ItemStatus::Completed,
                },
                ActivityStatus::Declined => ItemUpdate::Completed {
                    body,
                    status: ItemStatus::Declined,
                },
                ActivityStatus::Cancelled => ItemUpdate::Completed {
                    body,
                    status: ItemStatus::Interrupted,
                },
                ActivityStatus::Failed => ItemUpdate::Completed {
                    body,
                    status: ItemStatus::Failed,
                },
            };
            vec![Event::Item(Item::new(
                item_id(&activity.activity_id),
                Some(turn_id),
                update,
                native,
            ))]
        }
        AgentEvent::ActivityTextDelta {
            turn_id,
            activity_id,
            stream,
            index,
            delta,
        } => vec![Event::Item(
            Item::new(
                item_id(&activity_id),
                Some(turn_id),
                ItemUpdate::Delta {
                    delta: ItemDelta {
                        stream: match stream {
                            ActivityTextStream::Summary => DeltaStream::ReasoningSummary,
                            ActivityTextStream::Content => DeltaStream::ReasoningContent,
                            ActivityTextStream::Output => DeltaStream::Output,
                            _ => DeltaStream::Unknown,
                        },
                        index: index.and_then(|index| u32::try_from(index).ok()),
                        text: delta,
                    },
                },
                native,
            )
            .with_kind(ItemKind::Unknown),
        )],
        AgentEvent::PlanUpdated {
            turn_id,
            explanation,
            steps,
        } => vec![Event::Item(Item::new(
            item_id(&format!("{turn_id}:plan")),
            Some(turn_id),
            ItemUpdate::Updated {
                body: ItemBody::Plan {
                    explanation,
                    steps,
                    text: None,
                },
            },
            native,
        ))],
        AgentEvent::ApprovalRequested(approval) => {
            let Ok(id) = InteractionId::new(approval.approval_id.as_str()) else {
                return Vec::new();
            };
            let decisions = approval
                .options
                .iter()
                .enumerate()
                .filter_map(|(index, option)| decision(index, option))
                .collect();
            let subject = match &approval.command {
                Some(command) => ApprovalSubject::Command {
                    command: command.clone(),
                    cwd: approval.cwd.clone(),
                    reason: Some(approval.summary.clone()),
                    network_host: None,
                    permissions: None,
                },
                None => ApprovalSubject::Other {
                    title: approval.summary.clone(),
                    detail: None,
                },
            };
            let turn = approval.turn_id.clone();
            inner
                .state()
                .approvals
                .insert(approval.approval_id.clone(), approval);
            vec![Event::Interaction(Interaction {
                id,
                turn: Some(turn),
                item: None,
                parent: None,
                kind: InteractionKind::Approval { subject, decisions },
                native,
            })]
        }
        AgentEvent::ApprovalClosed { approval_id, .. } => {
            let mut state = inner.state();
            let answered = state.answered.remove(&approval_id);
            state.approvals.remove(&approval_id);
            drop(state);
            match (answered, InteractionId::new(approval_id.as_str())) {
                (false, Ok(id)) => vec![Event::InteractionClosed {
                    id,
                    by: ClosedBy::External,
                }],
                _ => Vec::new(),
            }
        }
        AgentEvent::QuestionRequested(question) => {
            let Ok(id) = InteractionId::new(question.request_id.as_str()) else {
                return Vec::new();
            };
            let form = QuestionForm {
                title: None,
                fields: question
                    .questions
                    .iter()
                    .filter_map(|item| {
                        Some(FormField {
                            id: FieldId::new(item.question_id.as_str()).ok()?,
                            header: Some(item.header.clone()).filter(|header| !header.is_empty()),
                            prompt: item.prompt.clone(),
                            input: if item.is_secret {
                                FieldInput::Secret
                            } else if item.options.is_empty() {
                                FieldInput::Text {
                                    multiline: false,
                                    default: None,
                                }
                            } else {
                                FieldInput::Select {
                                    options: item
                                        .options
                                        .iter()
                                        .map(|option| FieldOption {
                                            label: option.label.clone(),
                                            description: option.description.clone(),
                                        })
                                        .collect(),
                                    multiple: item.allows_multiple,
                                    allow_other: item.allows_other,
                                }
                            },
                            required: true,
                        })
                    })
                    .collect(),
                asynchronous: false,
                auto_resolution_ms: question.auto_resolution_ms,
            };
            let turn = question.turn_id.clone();
            inner
                .state()
                .questions
                .insert(question.request_id.clone(), question);
            vec![Event::Interaction(Interaction {
                id,
                turn: Some(turn),
                item: None,
                parent: None,
                kind: InteractionKind::Question { form },
                native,
            })]
        }
        AgentEvent::FilesChanged { turn_id, files } => vec![Event::Item(Item::new(
            item_id(&format!(
                "{turn_id}:files:{}",
                uuid::Uuid::new_v4().simple()
            )),
            Some(turn_id),
            ItemUpdate::Completed {
                body: ItemBody::FileChange {
                    changes: files
                        .into_iter()
                        .map(|file| FileDiff {
                            path: file.path,
                            change: FileChangeKind::Update { moved_to: None },
                            diff: file.summary,
                        })
                        .collect(),
                },
                status: ItemStatus::Completed,
            },
            native,
        ))],
        AgentEvent::OutputAttachment { .. } => vec![Event::Notice(Notice {
            level: NoticeLevel::Info,
            code: "output_attachment".into(),
            message: None,
            native,
        })],
        AgentEvent::TurnCompleted {
            turn_id,
            outcome,
            error,
            timing,
        } => {
            let mut state = inner.state();
            if state.turn.as_ref() != Some(&turn_id) {
                return Vec::new();
            }
            state.turn = None;
            let questions: Vec<String> = state.questions.keys().cloned().collect();
            let approvals: Vec<String> = state.approvals.keys().cloned().collect();
            state.questions.clear();
            state.approvals.clear();
            state.activities.clear();
            let inputs = std::mem::take(&mut state.turn_inputs);
            drop(state);
            let mut events: Vec<Event> = questions
                .into_iter()
                .chain(approvals)
                .filter_map(|id| InteractionId::new(id).ok())
                .map(|id| Event::InteractionClosed {
                    id,
                    by: ClosedBy::Cancelled,
                })
                .collect();
            events.push(Event::Turn {
                turn: turn_id,
                phase: TurnPhase::Completed {
                    outcome,
                    inputs_consumed: inputs,
                    error,
                    duration_ms: timing.provider_duration_ms,
                },
            });
            events
        }
    }
}
