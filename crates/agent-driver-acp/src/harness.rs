//! The ACP driver on the bridge v2 session contract (spec §4.1 "ACP host").
//!
//! ACP stays the path for OpenCode and Amp, and Claude's emergency path when
//! a Claude release breaks the Rust driver. It is turn-scoped underneath, so
//! this adapter offers what each agent advertises, gated per session: turns,
//! stop, approvals, questions, reasoning, usage, titles, modes, compaction,
//! the session browser, fork and children; no native queue, passive context
//! or steering (agents reject a prompt during a turn).

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, Weak};

use agent_client_protocol::schema::MaybeUndefined;
use agent_client_protocol::schema::v1 as acp;
use futures_util::StreamExt;
use inline_agent_bridge::harness::{
    ApprovalSubject, Availability, AvailabilityMatrix, CapabilityManifest, Catalog, CatalogMode,
    CatalogScope, ChildId, ChildKind, ChildRef, ChildStatus, ChildUpdate, ClosedBy, CommandAction,
    CompatTier, DEFAULT_HUB_CAPACITY, Decision, DecisionId, DecisionKind, Delivery, DeliveryKind,
    DeltaStream, EffectiveSettings, Event, EventHub, EventStream, ExecutableInfo, FieldAnswer,
    FieldId, FieldInput, FieldOption, FileChangeKind, FileDiff, FormField, HarnessDriver,
    HarnessFuture, Input, InputDisposition, InputId, InputReceipt, Interaction, InteractionId,
    InteractionKind, InteractionResponse, Item, ItemBody, ItemDelta, ItemId, ItemKind, ItemStatus,
    ItemUpdate, LiveWork, MessageRole, ModeId, Notice, NoticeLevel, Op, OpError, OpKind, OpOutcome,
    OpenError, OpenMode, OpenSpec, QuestionForm, ReleaseOutcome, Released, RunState,
    RunStateTracker, RuntimeHealth, RuntimeInfo, SendError, Session, SessionKey, SessionPage,
    SessionQuery, SessionSummary, SettingsScope, TokenUsage, TurnPhase, UserId,
};
use inline_agent_bridge::{
    ActivitySemanticKind, ActivityStatus, ActivityTextStream, ActivityUpsert, AgentDriver,
    AgentEvent, AgentMessagePhase, AgentMessageUpdate, ApprovalDecision, ApprovalOption,
    ApprovalRequest, DriverError, DriverFuture, DriverResult, ProviderId, ProviderSessionId,
    QuestionAnswer, QuestionRequest, ResumeSessionSpec, SessionPageCursor, SessionReplay,
    SessionSpec, SteeringSupport, TurnId, TurnInput, TurnOptions, TurnOutcome,
};
use serde_json::{Value, json};

use crate::AcpDriver;
use crate::driver::{ApprovalContext, OpenCodeChildUpdate, SessionSignal, SessionView};
use crate::mapping::{
    StreamState, ToolDetail, current_choice, stream_events, strip_child_title, unified_diff,
};

const OPENCODE_COMPACTION_META: &str = "opencode/compaction";
const OPENCODE_RETRY_META: &str = "opencode/retry";
const COMMANDS_CHANGED_NOTICE: &str = "available_commands_update";
/// OpenCode's title until a session's first turn has named it.
const OPENCODE_UNNAMED_TITLE_PREFIX: &str = "New session - ";

/// What ACP can honour for `driver`, as far as is known before a session exists.
pub fn acp_availability(driver: &AcpDriver) -> AvailabilityMatrix {
    let opencode = driver.features().opencode;
    availability(driver, opencode, opencode)
}

/// What ACP can honour for one open session, from what that session advertised.
fn session_availability(driver: &AcpDriver, session: &str) -> AvailabilityMatrix {
    let opencode = driver.features().opencode;
    match driver.session_view(session) {
        Some(view) => availability(driver, opencode || view.has_compact, has_plan_mode(&view)),
        None => acp_availability(driver),
    }
}

/// Modes also carry permission presets (Amp's `bypass`). A session only has a
/// mode operation when one of them is a plan mode.
fn has_plan_mode(view: &SessionView) -> bool {
    view.modes.as_ref().is_some_and(|modes| {
        modes
            .available_modes
            .iter()
            .any(|mode| mode.id.to_string().eq_ignore_ascii_case("plan"))
    })
}

fn availability(driver: &AcpDriver, compact: bool, mode: bool) -> AvailabilityMatrix {
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
            supported_if(compact, "this agent has no compact command"),
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
        .with_op(
            OpKind::Mode,
            supported_if(mode, "this agent has no plan mode"),
        )
        .with_op(OpKind::Review, reduced("no review"))
        .with_op(OpKind::Goal, reduced("no goals"))
        .with_op(OpKind::StopChild, reduced("no children"))
        .with_op(OpKind::Sample, reduced("no side calls"))
        .with_op(OpKind::McpAuth, reduced("no MCP sign-in"))
}

/// An ACP agent behind the session contract.
pub struct AcpHarness {
    driver: Arc<AcpDriver>,
    provider: ProviderId,
    executable: ExecutableInfo,
    driver_version: String,
    process_status: Option<crate::AcpProcessStatus>,
    catalog_sessions: tokio::sync::Mutex<HashMap<PathBuf, ProviderSessionId>>,
}

impl AcpHarness {
    pub fn new(
        driver: Arc<AcpDriver>,
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
                availability: acp_availability(&self.driver),
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
            let mut modes = Vec::new();
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
                if let Some(view) = self
                    .driver
                    .session_view(session.as_str())
                    .filter(has_plan_mode)
                {
                    modes = catalog_modes(&view);
                }
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
                modes,
                commands,
                ..Catalog::default()
            })
        })
    }

    fn sessions<'a>(&'a self, query: SessionQuery) -> DriverFuture<'a, SessionPage> {
        Box::pin(async move {
            // ACP has no archive, so an archived listing is empty.
            if !self.driver.features().list_sessions || query.archived {
                return Ok(SessionPage::default());
            }
            let listing = self
                .driver
                .list_sessions(
                    query.folder,
                    query.cursor.map(|cursor| cursor.as_str().to_owned()),
                )
                .await?;
            let opencode = self.driver.features().opencode;
            Ok(SessionPage {
                sessions: listing
                    .sessions
                    .into_iter()
                    // A session nobody ever spoke to is not worth resuming, and
                    // Inline's own picker probes look exactly like one.
                    .filter(|info| {
                        !opencode || !info.title.as_deref().is_some_and(is_unnamed_opencode_title)
                    })
                    .filter_map(|info| {
                        Some(SessionSummary {
                            key: SessionKey {
                                provider: self.provider.clone(),
                                session: ProviderSessionId::new(info.session_id.to_string())
                                    .ok()?,
                            },
                            title: info.title,
                            preview: None,
                            folder: Some(info.cwd),
                            updated_at: info.updated_at.as_deref().and_then(iso8601_seconds),
                            held_by: None,
                            archived: false,
                        })
                    })
                    .collect(),
                next: listing
                    .next
                    .and_then(|cursor| SessionPageCursor::new(cursor).ok()),
            })
        })
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
                OpenMode::Fork { session, at } => {
                    if !self.driver.features().fork_session {
                        return Err(OpenError::Unavailable(Availability::unavailable(
                            "fork is unsupported (reduced mode: ACP)",
                        )));
                    }
                    if at.is_some() {
                        return Err(OpenError::Unavailable(Availability::unavailable(
                            "this agent forks at the end of a session (reduced mode: ACP)",
                        )));
                    }
                    self.driver
                        .fork_session(session, spec.folder.clone())
                        .await
                        .map_err(|error| match error {
                            DriverError::InvalidSession(_) => OpenError::NotFound,
                            other => OpenError::Driver(other),
                        })?
                }
            };
            let signals = self.driver.subscribe_signals(session.as_str());
            let key = SessionKey {
                provider: self.provider.clone(),
                session: session.clone(),
            };
            let inner = Arc::new(AcpSessionInner {
                hub: EventHub::new(key.clone(), DEFAULT_HUB_CAPACITY),
                tracker: Mutex::new(RunStateTracker::new(RunState::Idle)),
                state: Mutex::new(AcpState {
                    // A resume or fork already carries the guide in its history.
                    first_turn_sent: !matches!(spec.mode, OpenMode::Start),
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
            pump_signals(Arc::downgrade(&inner), signals);
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
    /// The open assistant message. Tools and reasoning end it, so text before
    /// them reads as an update and only the last text as the answer.
    text: Option<OpenText>,
    text_messages: u32,
    usage_total: TokenUsage,
    settings: Option<EffectiveSettings>,
    title: Option<String>,
    children: HashMap<String, ChildStream>,
}

struct OpenText {
    id: ItemId,
    text: String,
}

/// One live subagent's stream.
struct ChildStream {
    child: ChildRef,
    stream: StreamState,
    text: String,
}

struct AcpSessionInner {
    key: SessionKey,
    session: ProviderSessionId,
    driver: Arc<AcpDriver>,
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
        session_availability(&self.inner.driver, self.inner.session.as_str())
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
                    sync_settings(&self.inner);
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
                    drop(state);
                    sync_settings(&self.inner);
                    Ok(OpOutcome::accepted())
                }
                Op::Mode { mode } => {
                    self.inner
                        .driver
                        .set_session_mode(self.inner.session.as_str(), mode.as_str())
                        .await
                        .map_err(OpError::Driver)?;
                    self.inner.state().options.permissions = Some(mode.as_str().to_owned());
                    sync_settings(&self.inner);
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
            children: state
                .children
                .values()
                .map(|child| child.child.clone())
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
            let stopped_children = {
                let mut state = self.inner.state();
                state.released = true;
                state
                    .children
                    .drain()
                    .map(|(_, child)| child.child)
                    .collect()
            };
            // Closing also stops work the session left running after its turn.
            let closed = self.inner.driver.features().close_session
                && self
                    .inner
                    .driver
                    .close_session(self.inner.session.as_str())
                    .await
                    .is_ok();
            Ok(Released {
                key: self.inner.key.clone(),
                outcome: if closed {
                    ReleaseOutcome::NativeReleased
                } else {
                    ReleaseOutcome::Unsubscribed
                },
                cancelled_interactions: cancelled,
                pending_inputs: Vec::new(),
                stopped_children,
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

fn decision(
    index: usize,
    option: &ApprovalOption,
    context: Option<&ApprovalContext>,
) -> Option<Decision> {
    use acp::PermissionOptionKind as Kind;
    let provider = |matches: &dyn Fn(&acp::PermissionOption) -> bool| {
        context
            .into_iter()
            .flat_map(|context| context.options.iter())
            .find(|option| matches(option))
            .map(|option| option.name.clone())
    };
    // Cards use the agent's own labels; the bridge's are only a fallback.
    let (label, kind) = match option {
        ApprovalOption::ApproveOnce => (
            provider(&|option| option.kind == Kind::AllowOnce)
                .unwrap_or_else(|| "Allow once".to_string()),
            DecisionKind::Accept,
        ),
        ApprovalOption::ApproveForSession => (
            provider(&|option| option.kind == Kind::AllowAlways)
                .unwrap_or_else(|| "Always allow".to_string()),
            DecisionKind::AcceptForSession,
        ),
        ApprovalOption::Reject => (
            provider(&|option| matches!(option.kind, Kind::RejectOnce | Kind::RejectAlways))
                .unwrap_or_else(|| "Reject".to_string()),
            DecisionKind::Decline,
        ),
        ApprovalOption::CancelTurn => ("Reject and stop".to_string(), DecisionKind::Cancel),
        ApprovalOption::ProviderChoice { label, option_id } => {
            let native = context
                .into_iter()
                .flat_map(|context| context.options.iter())
                .find(|option| option.option_id.to_string() == *option_id)
                .map(|option| option.kind);
            (
                label.clone(),
                match native {
                    Some(Kind::AllowOnce) => DecisionKind::Accept,
                    Some(Kind::AllowAlways) => DecisionKind::AcceptForSession,
                    Some(Kind::RejectOnce | Kind::RejectAlways) => DecisionKind::Decline,
                    _ if option_id.contains("allow_always") => DecisionKind::AcceptForSession,
                    _ if option_id.contains("allow") => DecisionKind::Accept,
                    _ if option_id.contains("reject") => DecisionKind::Decline,
                    _ => DecisionKind::Other,
                },
            )
        }
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

fn approval_subject(
    approval: &ApprovalRequest,
    context: Option<&ApprovalContext>,
) -> ApprovalSubject {
    if let Some(command) = &approval.command {
        return ApprovalSubject::Command {
            command: command.clone(),
            cwd: approval.cwd.clone(),
            reason: Some(approval.summary.clone()),
            network_host: None,
            permissions: None,
        };
    }
    let reason = Some(approval.summary.clone());
    match context {
        Some(context)
            if matches!(
                context.kind,
                Some(acp::ToolKind::Edit | acp::ToolKind::Delete | acp::ToolKind::Move)
            ) && !context.locations.is_empty() =>
        {
            ApprovalSubject::FileChange {
                paths: context.locations.clone(),
                reason,
                grant_root: None,
            }
        }
        Some(ApprovalContext {
            title: Some(title),
            raw_input,
            ..
        }) if !title.trim().is_empty() => ApprovalSubject::Tool {
            name: title.lines().next().unwrap_or_default().trim().to_owned(),
            input: raw_input.clone().unwrap_or(Value::Null),
            reason,
        },
        _ => ApprovalSubject::Other {
            title: approval.summary.clone(),
            detail: None,
        },
    }
}

fn is_unnamed_opencode_title(title: &str) -> bool {
    title.starts_with(OPENCODE_UNNAMED_TITLE_PREFIX)
}

/// Unix seconds of an RFC 3339 timestamp (`2026-10-31T15:13:22.112Z`). Offsets
/// other than `Z` are honoured to the minute. Anything else reads as unknown.
fn iso8601_seconds(value: &str) -> Option<i64> {
    let (date, time) = value.split_once('T')?;
    let mut date = date.splitn(3, '-');
    let year: i64 = date.next()?.parse().ok()?;
    let month: i64 = date.next()?.parse().ok()?;
    let day: i64 = date.next()?.parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    let (clock, offset_seconds) = if let Some(clock) = time.strip_suffix(['Z', 'z']) {
        (clock, 0)
    } else {
        let split = time.rfind(['+', '-'])?;
        let (hours, minutes) = time[split + 1..].split_once(':')?;
        let offset = hours.parse::<i64>().ok()? * 3_600 + minutes.parse::<i64>().ok()? * 60;
        (
            &time[..split],
            if time.as_bytes()[split] == b'-' {
                -offset
            } else {
                offset
            },
        )
    };
    let mut clock = clock.split(':');
    let hour: i64 = clock.next()?.parse().ok()?;
    let minute: i64 = clock.next()?.parse().ok()?;
    let second: i64 = clock.next()?.split('.').next()?.parse().ok()?;
    // Days from civil date (Howard Hinnant's algorithm).
    let shifted = if month <= 2 { year - 1 } else { year };
    let era = shifted.div_euclid(400);
    let year_of_era = shifted.rem_euclid(400);
    let month_index = (month + 9) % 12;
    let day_of_year = (153 * month_index + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    Some(days * 86_400 + hour * 3_600 + minute * 60 + second - offset_seconds)
}

fn catalog_modes(view: &SessionView) -> Vec<CatalogMode> {
    view.modes
        .iter()
        .flat_map(|modes| modes.available_modes.iter())
        .filter_map(|mode| {
            Some(CatalogMode {
                id: ModeId::new(mode.id.to_string()).ok()?,
                label: mode.name.clone(),
                description: mode.description.clone(),
            })
        })
        .collect()
}

/// Emits the effective settings when they changed. A session's first state is
/// sent with its first turn, since nobody has subscribed before that.
fn sync_settings(inner: &AcpSessionInner) {
    let view = inner
        .driver
        .session_view(inner.session.as_str())
        .unwrap_or_default();
    let mode = view
        .modes
        .as_ref()
        .map(|modes| modes.current_mode_id.to_string());
    let effective = EffectiveSettings {
        model: current_choice(
            &view.config_options,
            acp::SessionConfigOptionCategory::Model,
        ),
        effort: current_choice(
            &view.config_options,
            acp::SessionConfigOptionCategory::ThoughtLevel,
        )
        .map(|choice| choice.value),
        speed: None,
        permission_mode: mode.clone(),
        mode,
        folder: inner.state().options.cwd.clone(),
    };
    let changed = {
        let mut state = inner.state();
        if state.settings.as_ref() == Some(&effective) {
            false
        } else {
            state.settings = Some(effective.clone());
            true
        }
    };
    if changed {
        inner.emit(Event::Settings { effective });
    }
}

fn note_title(inner: &AcpSessionInner, title: &str) {
    let title = title.trim();
    if title.is_empty() || is_unnamed_opencode_title(title) {
        return;
    }
    {
        let mut state = inner.state();
        if state.title.as_deref() == Some(title) {
            return;
        }
        state.title = Some(title.to_owned());
    }
    inner.emit(Event::Renamed {
        title: title.to_owned(),
    });
}

/// OpenCode names a session in the background and reports the name only in
/// `session/list`. Asks after each turn until the session has a name.
async fn refresh_title(inner: &AcpSessionInner) {
    let (known, folder) = {
        let state = inner.state();
        (state.title.is_some(), state.options.cwd.clone())
    };
    if known || !inner.driver.features().list_sessions {
        return;
    }
    let Ok(listing) = inner.driver.list_sessions(folder, None).await else {
        return;
    };
    if let Some(title) = listing
        .sessions
        .iter()
        .find(|info| info.session_id.to_string() == inner.session.as_str())
        .and_then(|info| info.title.as_deref())
    {
        note_title(inner, title);
    }
}

fn pump_signals(
    inner: Weak<AcpSessionInner>,
    mut signals: tokio::sync::mpsc::UnboundedReceiver<SessionSignal>,
) {
    tokio::spawn(async move {
        while let Some(signal) = signals.recv().await {
            let Some(inner) = inner.upgrade() else {
                break;
            };
            apply_signal(&inner, signal);
        }
    });
}

fn apply_signal(inner: &AcpSessionInner, signal: SessionSignal) {
    match signal {
        SessionSignal::PromptUsage(usage) => {
            let total = {
                let mut state = inner.state();
                let total = &mut state.usage_total;
                total.input += usage.input_tokens;
                total.output += usage.output_tokens;
                total.cached_input += usage.cached_read_tokens.unwrap_or(0);
                total.reasoning += usage.thought_tokens.unwrap_or(0);
                total.total += usage.total_tokens;
                *total
            };
            inner.emit(Event::Usage {
                usage: inline_agent_bridge::harness::UsageUpdate {
                    total: Some(total),
                    ..Default::default()
                },
            });
        }
        SessionSignal::Child(update) => apply_child_update(inner, *update),
        SessionSignal::Update(update) => match *update {
            acp::SessionUpdate::UsageUpdate(usage) => inner.emit(Event::Usage {
                usage: inline_agent_bridge::harness::UsageUpdate {
                    last: Some(TokenUsage {
                        total: usage.used,
                        ..TokenUsage::default()
                    }),
                    context_window: (usage.size > 0).then_some(usage.size),
                    ..Default::default()
                },
            }),
            acp::SessionUpdate::SessionInfoUpdate(info) => {
                if let MaybeUndefined::Value(title) = &info.title {
                    note_title(inner, title);
                }
                if let Some(meta) = &info.meta {
                    if let Some(marker) = meta.get(OPENCODE_COMPACTION_META) {
                        apply_compaction_marker(inner, marker);
                    }
                    if let Some(retry) = meta.get(OPENCODE_RETRY_META)
                        && retry.is_object()
                    {
                        inner.emit(Event::Notice(Notice {
                            level: NoticeLevel::Warning,
                            code: "retry".into(),
                            message: retry
                                .pointer("/error/message")
                                .and_then(Value::as_str)
                                .map(str::to_owned),
                            native: retry.clone(),
                        }));
                    }
                }
            }
            acp::SessionUpdate::ConfigOptionUpdate(_)
            | acp::SessionUpdate::CurrentModeUpdate(_) => sync_settings(inner),
            acp::SessionUpdate::AvailableCommandsUpdate(update) => {
                inner.emit(Event::Notice(Notice {
                    level: NoticeLevel::Info,
                    code: COMMANDS_CHANGED_NOTICE.into(),
                    message: None,
                    native: serde_json::to_value(&update).unwrap_or(Value::Null),
                }));
            }
            _ => {}
        },
    }
}

/// OpenCode's compaction lifecycle, as it reports it to a client that has not
/// advertised ACP's newer `compaction_update`.
fn apply_compaction_marker(inner: &AcpSessionInner, marker: &Value) {
    let Some(id) = marker.get("messageId").and_then(Value::as_str) else {
        return;
    };
    let body = |label: &str| ItemBody::Usage {
        label: label.to_owned(),
    };
    let update = match marker.get("status").and_then(Value::as_str) {
        Some("started") => ItemUpdate::Started {
            body: body("Compacting context"),
        },
        Some("completed") => ItemUpdate::Completed {
            body: body("Context compacted"),
            status: ItemStatus::Completed,
        },
        Some("failed") => {
            let error = marker.get("error");
            let cancelled = error
                .and_then(|error| error.get("type"))
                .and_then(Value::as_str)
                .is_some_and(|kind| matches!(kind, "aborted" | "compaction.interrupted"));
            let message = error
                .and_then(|error| error.get("message"))
                .and_then(Value::as_str)
                .filter(|message| !message.contains('\n'))
                .unwrap_or("Compaction failed");
            ItemUpdate::Completed {
                body: body(if cancelled {
                    "Compaction cancelled"
                } else {
                    message
                }),
                status: if cancelled {
                    ItemStatus::Interrupted
                } else {
                    ItemStatus::Failed
                },
            }
        }
        _ => return,
    };
    let turn = inner.state().turn.clone();
    inner.emit(Event::Item(Item::new(
        item_id(&format!("compaction:{id}")),
        turn,
        update,
        marker.clone(),
    )));
}

fn apply_child_update(inner: &AcpSessionInner, update: OpenCodeChildUpdate) {
    let Ok(id) = ChildId::new(update.child_session_id.as_str()) else {
        return;
    };
    let child = ChildRef {
        id,
        kind: ChildKind::Subagent,
    };
    let parent = (update.parent_session_id != update.root_session_id)
        .then(|| ChildId::new(update.parent_session_id.as_str()).ok())
        .flatten()
        .map(|id| ChildRef {
            id,
            kind: ChildKind::Subagent,
        });
    let native = serde_json::to_value(&update).unwrap_or(Value::Null);
    let turn = inner.state().turn.clone();
    match update.kind.as_str() {
        "update" => {
            let Some(mut session_update) = update
                .update
                .clone()
                .and_then(|raw| serde_json::from_value::<acp::SessionUpdate>(raw).ok())
            else {
                return;
            };
            if let Some(title) = update.title.as_deref() {
                strip_child_title(&mut session_update, title);
            }
            for event in child_events(inner, &child, &update, turn, session_update, native) {
                inner.emit(event);
            }
        }
        "status" => {
            let status = match update.status.as_deref() {
                Some("created") => ChildStatus::Started,
                Some("running") => ChildStatus::Running,
                Some("completed") => ChildStatus::Completed,
                Some("failed") => ChildStatus::Failed,
                Some("interrupted") => ChildStatus::Stopped,
                _ => ChildStatus::Unknown,
            };
            let terminal = matches!(
                status,
                ChildStatus::Completed | ChildStatus::Failed | ChildStatus::Stopped
            );
            let body = ItemBody::Child {
                child: child.clone(),
                action: None,
                prompt: update.title.clone(),
            };
            let row = item_id(&format!("child:{}", child.id.as_str()));
            let mut events = Vec::new();
            if status == ChildStatus::Started {
                inner.state().children.insert(
                    update.child_session_id.clone(),
                    ChildStream {
                        child: child.clone(),
                        stream: StreamState::new(true),
                        text: String::new(),
                    },
                );
                events.push(Event::Item(
                    Item::new(
                        row,
                        turn.clone(),
                        ItemUpdate::Started { body },
                        native.clone(),
                    )
                    .with_parent(parent.clone()),
                ));
            } else if terminal {
                let open = inner.state().children.remove(&update.child_session_id);
                if let Some(mut open) = open {
                    let stream_turn = child_stream_turn(&child);
                    if let Some(thought) = stream_turn
                        .as_ref()
                        .and_then(|turn| open.stream.close_thought(turn))
                        && let AgentEvent::ActivityUpsert { activity, .. } = thought
                    {
                        events.push(child_activity_item(
                            inner,
                            &child,
                            turn.clone(),
                            &activity,
                            Value::Null,
                        ));
                    }
                    if !open.text.is_empty() {
                        events.push(Event::Item(
                            Item::new(
                                child_text_id(&child),
                                turn.clone(),
                                ItemUpdate::Completed {
                                    body: ItemBody::Message {
                                        role: MessageRole::Assistant,
                                        text: open.text,
                                        input: None,
                                    },
                                    status: ItemStatus::Completed,
                                },
                                Value::Null,
                            )
                            .with_parent(Some(child.clone()))
                            .with_phase(Some(AgentMessagePhase::Commentary)),
                        ));
                    }
                }
                events.push(Event::Item(
                    Item::new(
                        row,
                        turn.clone(),
                        ItemUpdate::Completed {
                            body,
                            status: match status {
                                ChildStatus::Completed => ItemStatus::Completed,
                                ChildStatus::Failed => ItemStatus::Failed,
                                _ => ItemStatus::Interrupted,
                            },
                        },
                        native.clone(),
                    )
                    .with_parent(parent),
                ));
            }
            events.push(Event::Child {
                update: ChildUpdate {
                    child,
                    status,
                    title: update.title.clone(),
                    accepts_direct_input: false,
                    native,
                },
            });
            for event in events {
                inner.emit(event);
            }
        }
        _ => {}
    }
}

/// Mapping a child's stream needs a turn identity; this one never leaves here.
fn child_stream_turn(child: &ChildRef) -> Option<TurnId> {
    TurnId::new(format!("child-{}", child.id.as_str())).ok()
}

fn child_text_id(child: &ChildRef) -> ItemId {
    item_id(&format!("{}:text", child.id.as_str()))
}

fn child_activity_item(
    inner: &AcpSessionInner,
    child: &ChildRef,
    turn: Option<TurnId>,
    activity: &ActivityUpsert,
    native: Value,
) -> Event {
    let mut item = activity_item(inner, turn.clone(), activity, native);
    item.turn = turn;
    Event::Item(item.with_parent(Some(child.clone())))
}

fn child_events(
    inner: &AcpSessionInner,
    child: &ChildRef,
    update: &OpenCodeChildUpdate,
    turn: Option<TurnId>,
    session_update: acp::SessionUpdate,
    native: Value,
) -> Vec<Event> {
    let Some(stream_turn) = child_stream_turn(child) else {
        return Vec::new();
    };
    let mapped = {
        let mut state = inner.state();
        let stream = state
            .children
            .entry(update.child_session_id.clone())
            // A child can outlive the process's knowledge of its creation.
            .or_insert_with(|| ChildStream {
                child: child.clone(),
                stream: StreamState::new(true),
                text: String::new(),
            });
        stream_events(&stream_turn, &mut stream.stream, session_update)
    };
    let mut events = Vec::new();
    for event in mapped {
        match event {
            AgentEvent::AgentTextDelta { text, .. } => {
                if let Some(open) = inner.state().children.get_mut(&update.child_session_id) {
                    open.text.push_str(&text);
                }
                events.push(Event::Item(
                    Item::new(
                        child_text_id(child),
                        turn.clone(),
                        ItemUpdate::Delta {
                            delta: ItemDelta {
                                stream: DeltaStream::Text,
                                index: None,
                                text,
                            },
                        },
                        Value::Null,
                    )
                    .with_kind(ItemKind::Message)
                    .with_parent(Some(child.clone()))
                    .with_phase(Some(AgentMessagePhase::Commentary)),
                ));
            }
            AgentEvent::ActivityUpsert { activity, .. } => {
                events.push(child_activity_item(
                    inner,
                    child,
                    turn.clone(),
                    &activity,
                    native.clone(),
                ));
            }
            AgentEvent::ActivityTextDelta {
                activity_id,
                stream,
                index,
                delta,
                ..
            } => {
                let item = activity_delta_item(&activity_id, turn.clone(), stream, index, delta);
                events.push(Event::Item(item.with_parent(Some(child.clone()))));
            }
            AgentEvent::PlanUpdated {
                explanation, steps, ..
            } => {
                events.push(Event::Item(
                    Item::new(
                        item_id(&format!("{}:plan", child.id.as_str())),
                        turn.clone(),
                        ItemUpdate::Updated {
                            body: ItemBody::Plan {
                                explanation,
                                steps,
                                text: None,
                            },
                        },
                        native.clone(),
                    )
                    .with_parent(Some(child.clone())),
                ));
            }
            _ => {}
        }
    }
    events
}

/// The row of one tool activity, as rich as what the agent reported.
fn activity_body(activity: &ActivityUpsert) -> ItemBody {
    let detail: Option<ToolDetail> = activity
        .verbose_payload
        .as_deref()
        .and_then(|payload| serde_json::from_str(payload).ok());
    let cwd = detail.as_ref().and_then(|detail| detail.cwd.clone());
    let output = detail
        .as_ref()
        .and_then(|detail| detail.output.clone())
        .or_else(|| activity.output_snapshot.clone());
    let tool = |name: String| {
        ItemBody::Tool {
        name,
        server: None,
        input: detail
            .as_ref()
            .map(|detail| detail.raw_input.clone())
            .filter(|input| !input.is_null())
            .unwrap_or_else(|| {
                if activity.details.is_empty() {
                    Value::Null
                } else {
                    json!({"details": activity.details.iter().map(|detail| json!({"label": detail.label, "value": detail.value})).collect::<Vec<_>>()})
                }
            }),
        output: output.clone(),
        error: detail.as_ref().and_then(|detail| detail.error.clone()),
    }
    };
    match activity.kind {
        ActivitySemanticKind::Execute if activity.detail.is_some() => ItemBody::Command {
            command: activity.detail.clone().unwrap(),
            cwd,
            actions: Vec::new(),
            output: output.clone(),
            exit_code: detail
                .as_ref()
                .and_then(|detail| detail.exit_code)
                .or(activity.exit_code),
            duration_ms: None,
        },
        ActivitySemanticKind::Read | ActivitySemanticKind::Search => {
            match detail
                .as_ref()
                .and_then(|detail| exploration(activity.kind, detail))
            {
                // The chat folds these the way it folds Codex's explorations.
                Some((command, action)) => ItemBody::Command {
                    command,
                    cwd,
                    actions: vec![action],
                    output: if activity.kind == ActivitySemanticKind::Search {
                        output.clone()
                    } else {
                        None
                    },
                    exit_code: detail.as_ref().and_then(|detail| detail.exit_code),
                    duration_ms: None,
                },
                None => tool(activity.title.clone()),
            }
        }
        ActivitySemanticKind::Fetch => tool("WebFetch".to_owned()),
        ActivitySemanticKind::Edit | ActivitySemanticKind::Delete | ActivitySemanticKind::Move => {
            let changes = file_changes(activity, detail.as_ref());
            if changes.is_empty() {
                // Arguments still streaming: no file is known yet.
                tool(activity.title.clone())
            } else {
                ItemBody::FileChange { changes }
            }
        }
        // Reasoning text, or a thinking-kind tool (OpenCode's subagent, whose
        // child row carries it) that stays silent unless it fails outright.
        ActivitySemanticKind::Think => match &detail {
            Some(detail) if activity.status == ActivityStatus::Failed => ItemBody::Tool {
                name: detail.tool_name(),
                server: None,
                input: detail.raw_input.clone(),
                output: None,
                error: detail.error.clone(),
            },
            _ if !activity.reasoning_content.is_empty() => ItemBody::Reasoning {
                summary: activity.reasoning_content.clone(),
                content: Vec::new(),
            },
            _ => ItemBody::Reasoning {
                summary: activity.detail.clone().into_iter().collect(),
                content: Vec::new(),
            },
        },
        _ => tool(activity.title.clone()),
    }
}

/// A read, listing or search as a Codex-style parsed action.
fn exploration(kind: ActivitySemanticKind, detail: &ToolDetail) -> Option<(String, CommandAction)> {
    let path = detail
        .path()
        .or_else(|| detail.locations.first().cloned())
        .map(|path| path.display().to_string());
    let name = detail.tool_name();
    if matches!(name.as_str(), "list" | "ls") {
        return Some((
            format!("ls {}", path.as_deref().unwrap_or(".")),
            CommandAction::ListFiles { path },
        ));
    }
    if kind == ActivitySemanticKind::Read {
        let path = path?;
        return Some((format!("read {path}"), CommandAction::Read { path }));
    }
    let input = |keys: &[&str]| {
        keys.iter()
            .find_map(|key| detail.raw_input.get(*key).and_then(Value::as_str))
            .map(str::to_owned)
    };
    let query = input(&["pattern", "query", "glob", "filePattern"])?;
    if name.contains("web") {
        return None;
    }
    let path = input(&["path", "directory"]);
    Some((
        [Some(name), Some(query.clone()), path.clone()]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" "),
        CommandAction::Search {
            query: Some(query),
            path,
        },
    ))
}

fn file_changes(activity: &ActivityUpsert, detail: Option<&ToolDetail>) -> Vec<FileDiff> {
    let reported = detail.is_some_and(|detail| !detail.diffs.is_empty());
    let mut changes = detail.map_or_else(Vec::new, |detail| {
        detail
            .file_diffs()
            .into_iter()
            .map(|diff| FileDiff {
                change: match activity.kind {
                    ActivitySemanticKind::Delete => FileChangeKind::Delete,
                    // Only the protocol's own diff says a file is new; a raw
                    // `content` argument may be overwriting one.
                    _ if reported && diff.old_text.is_none() => FileChangeKind::Add,
                    _ => FileChangeKind::Update { moved_to: None },
                },
                diff: Some(unified_diff(diff.old_text.as_deref(), &diff.new_text)),
                path: diff.path,
            })
            .collect()
    });
    let locations: &[PathBuf] = detail
        .map(|detail| detail.locations.as_slice())
        .filter(|locations| !locations.is_empty())
        .unwrap_or(&activity.paths);
    if activity.kind == ActivitySemanticKind::Move
        && let [from, to, ..] = locations
    {
        return vec![FileDiff {
            path: from.clone(),
            change: FileChangeKind::Update {
                moved_to: Some(to.clone()),
            },
            diff: None,
        }];
    }
    for path in locations {
        if !changes.iter().any(|change| &change.path == path) {
            changes.push(FileDiff {
                path: path.clone(),
                change: match activity.kind {
                    ActivitySemanticKind::Delete => FileChangeKind::Delete,
                    _ => FileChangeKind::Update { moved_to: None },
                },
                diff: None,
            });
        }
    }
    changes
}

fn activity_item(
    inner: &AcpSessionInner,
    turn: Option<TurnId>,
    activity: &ActivityUpsert,
    native: Value,
) -> Item {
    let body = activity_body(activity);
    let first = inner
        .state()
        .activities
        .insert(activity.activity_id.clone());
    let update = match activity.status {
        ActivityStatus::Pending | ActivityStatus::InProgress if first => {
            ItemUpdate::Started { body }
        }
        ActivityStatus::Pending | ActivityStatus::InProgress => ItemUpdate::Updated { body },
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
    Item::new(item_id(&activity.activity_id), turn, update, native)
}

fn activity_delta_item(
    activity_id: &str,
    turn: Option<TurnId>,
    stream: ActivityTextStream,
    index: Option<usize>,
    delta: String,
) -> Item {
    let (stream, kind) = match stream {
        ActivityTextStream::Summary => (DeltaStream::ReasoningSummary, ItemKind::Reasoning),
        ActivityTextStream::Content => (DeltaStream::ReasoningContent, ItemKind::Reasoning),
        ActivityTextStream::Output => (DeltaStream::Output, ItemKind::Unknown),
        _ => (DeltaStream::Unknown, ItemKind::Unknown),
    };
    Item::new(
        item_id(activity_id),
        turn,
        ItemUpdate::Delta {
            delta: ItemDelta {
                stream,
                index: index.and_then(|index| u32::try_from(index).ok()),
                text: delta,
            },
        },
        Value::Null,
    )
    .with_kind(kind)
}

/// Ends the open assistant message, with the text it actually held.
fn close_text(inner: &AcpSessionInner, turn: &TurnId) -> Option<Event> {
    let open = inner.state().text.take()?;
    Some(Event::Item(Item::new(
        open.id,
        Some(turn.clone()),
        ItemUpdate::Completed {
            body: ItemBody::Message {
                role: MessageRole::Assistant,
                text: open.text,
                input: None,
            },
            status: ItemStatus::Completed,
        },
        Value::Null,
    )))
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
                refresh_title(&inner).await;
                break;
            }
        }
        complete_if_active(&inner, turn, TurnOutcome::ConnectionLost);
    });
}

fn pump(inner: &AcpSessionInner, event: DriverResult<AgentEvent>) {
    let mut event = match event {
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
    // Tool detail is on its way into the item's own fields; don't carry it twice.
    let payload = match &mut event {
        AgentEvent::ActivityUpsert { activity, .. } => activity.verbose_payload.take(),
        _ => None,
    };
    let native = serde_json::to_value(&event).unwrap_or(Value::Null);
    if let AgentEvent::ActivityUpsert { activity, .. } = &mut event {
        activity.verbose_payload = payload;
    }
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
        AgentEvent::AgentTextDelta { turn_id, mut text } => {
            let id = {
                let mut state = inner.state();
                // The separator the driver sends after a tool would only
                // start the next message with blank lines.
                if state.text.is_none() && state.text_messages > 0 {
                    text = text.trim_start().to_owned();
                    if text.is_empty() {
                        return Vec::new();
                    }
                }
                if state.text.is_none() {
                    let id = match state.text_messages {
                        0 => format!("{turn_id}:text"),
                        part => format!("{turn_id}:text:{part}"),
                    };
                    state.text_messages += 1;
                    state.text = Some(OpenText {
                        id: item_id(&id),
                        text: String::new(),
                    });
                }
                let open = state.text.as_mut().expect("text just opened");
                open.text.push_str(&text);
                open.id.clone()
            };
            vec![Event::Item(
                Item::new(
                    id,
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
            )]
        }
        AgentEvent::AgentTextCompleted { turn_id, text } => {
            // The driver's text spans the whole turn; each message already
            // holds its own part. A turn that never streamed takes it whole.
            let streamed = inner.state().text_messages > 0;
            if streamed {
                close_text(inner, &turn_id).into_iter().collect()
            } else {
                vec![Event::Item(Item::new(
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
                ))]
            }
        }
        AgentEvent::Activity { summary, .. } => vec![Event::Notice(Notice {
            level: NoticeLevel::Info,
            code: "activity".into(),
            message: Some(summary),
            native,
        })],
        AgentEvent::ActivityUpsert { turn_id, activity } => {
            let mut events: Vec<Event> = close_text(inner, &turn_id).into_iter().collect();
            events.push(Event::Item(activity_item(
                inner,
                Some(turn_id),
                &activity,
                native,
            )));
            events
        }
        AgentEvent::ActivityTextDelta {
            turn_id,
            activity_id,
            stream,
            index,
            delta,
        } => vec![Event::Item(activity_delta_item(
            &activity_id,
            Some(turn_id),
            stream,
            index,
            delta,
        ))],
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
            let context = inner.driver.approval_context(&approval.approval_id);
            let decisions = approval
                .options
                .iter()
                .enumerate()
                .filter_map(|(index, option)| decision(index, option, context.as_ref()))
                .collect();
            let subject = approval_subject(&approval, context.as_ref());
            // OpenCode prefixes a child's tool call id with the child's session.
            let parent = context.as_ref().and_then(|context| {
                let (child, _) = context.tool_call_id.split_once(':')?;
                inner
                    .state()
                    .children
                    .get(child)
                    .map(|open| open.child.clone())
            });
            let tool_item = context
                .as_ref()
                .and_then(|context| ItemId::new(context.tool_call_id.as_str()).ok());
            let turn = approval.turn_id.clone();
            inner
                .state()
                .approvals
                .insert(approval.approval_id.clone(), approval);
            vec![Event::Interaction(Interaction {
                id,
                turn: Some(turn),
                item: tool_item,
                parent,
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
        // The tool's own row already lists these files, with their diffs.
        AgentEvent::FilesChanged { .. } => Vec::new(),
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
            state.text = None;
            state.text_messages = 0;
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

#[cfg(test)]
mod tests {
    use super::*;

    fn upsert(kind: ActivitySemanticKind, detail: &ToolDetail) -> ActivityUpsert {
        ActivityUpsert::new("tool-1", kind, ActivityStatus::Completed, "Working")
            .unwrap()
            .with_verbose_payload(serde_json::to_string(detail).unwrap())
    }

    #[test]
    fn parses_the_timestamps_agents_send() {
        assert_eq!(
            iso8601_seconds("2026-10-31T15:13:22.112Z"),
            Some(1_793_459_602)
        );
        assert_eq!(
            iso8601_seconds("2026-10-31T17:13:22+02:00"),
            Some(1_793_459_602)
        );
        assert_eq!(iso8601_seconds("1970-01-01T00:00:00Z"), Some(0));
        for invalid in ["", "yesterday", "2026-13-01T00:00:00Z", "2026-10-31"] {
            assert_eq!(iso8601_seconds(invalid), None, "{invalid}");
        }
    }

    #[test]
    fn explorations_fold_like_parsed_commands_and_web_search_does_not() {
        let grep = ToolDetail {
            provider_title: "grep".into(),
            raw_input: json!({"pattern": "todo", "path": "src"}),
            ..ToolDetail::default()
        };
        assert!(matches!(
            activity_body(&upsert(ActivitySemanticKind::Search, &grep)),
            ItemBody::Command { actions, .. } if matches!(actions.as_slice(),
                [CommandAction::Search { query: Some(query), path: Some(path) }]
                    if query == "todo" && path == "src")
        ));
        let web = ToolDetail {
            provider_title: "search_web".into(),
            raw_input: json!({"query": "acp"}),
            ..ToolDetail::default()
        };
        assert!(matches!(
            activity_body(&upsert(ActivitySemanticKind::Search, &web)),
            ItemBody::Tool { input, .. } if input["query"] == "acp"
        ));
    }

    #[test]
    fn edits_without_a_known_file_are_not_empty_file_rows() {
        let pending = ToolDetail {
            provider_title: "write".into(),
            ..ToolDetail::default()
        };
        assert!(matches!(
            activity_body(&upsert(ActivitySemanticKind::Edit, &pending)),
            ItemBody::Tool { .. }
        ));
        let write = ToolDetail {
            provider_title: "write".into(),
            raw_input: json!({"path": "/w/note.txt", "content": "x\n"}),
            locations: vec!["/w/note.txt".into()],
            ..ToolDetail::default()
        };
        // A raw `content` argument can't tell a new file from an overwrite.
        assert!(matches!(
            activity_body(&upsert(ActivitySemanticKind::Edit, &write)),
            ItemBody::FileChange { changes } if changes.len() == 1
                && changes[0].change == FileChangeKind::Update { moved_to: None }
                && changes[0].diff.as_deref() == Some("@@ -1,0 +1,1 @@\n+x\n")
        ));
    }

    #[test]
    fn a_thinking_kind_tool_only_shows_when_it_fails() {
        let subagent = ToolDetail {
            provider_title: "subagent".into(),
            error: Some("no such agent".into()),
            ..ToolDetail::default()
        };
        let quiet = upsert(ActivitySemanticKind::Think, &subagent);
        assert!(matches!(
            activity_body(&quiet),
            ItemBody::Reasoning { summary, .. } if summary.is_empty()
        ));
        let mut failed = quiet;
        failed.status = ActivityStatus::Failed;
        assert!(matches!(
            activity_body(&failed),
            ItemBody::Tool { name, error: Some(_), .. } if name == "subagent"
        ));
    }

    #[test]
    fn plan_mode_decides_the_mode_operation() {
        let view = |ids: &[&str]| SessionView {
            modes: Some(acp::SessionModeState::new(
                ids[0].to_string(),
                ids.iter()
                    .map(|id| acp::SessionMode::new(id.to_string(), id.to_string()))
                    .collect(),
            )),
            ..SessionView::default()
        };
        assert!(has_plan_mode(&view(&["build", "plan"])));
        assert!(!has_plan_mode(&view(&["default", "bypass"])));
        assert!(!has_plan_mode(&SessionView::default()));
    }
}
