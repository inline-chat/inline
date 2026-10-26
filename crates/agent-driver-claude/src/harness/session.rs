//! `HarnessDriver` and `Session` for Claude Code.
//!
//! One CLI process per session: Claude Code has no multi-session server, so
//! each open spawns `claude` with `--session-id` / `--resume`, and release
//! closes its stdin. The process answers to the mapper; approvals and
//! questions wait in the control handler until [`Session::control`] answers
//! them.

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use inline_agent_bridge::harness::{
    Availability, AvailabilityMatrix, CapabilityManifest, Catalog, CatalogMode, CatalogScope,
    CompatTier, Delivery, DeliveryKind, Envelope, Event, EventHub, EventStream, ExecutableInfo,
    ExecutableSource, ForkPoint, HarnessDriver, HarnessFuture, HeldBy, HeldSurface, Input,
    InputDisposition, InputReceipt, InteractionId, LiveWork, ModeId, Op, OpError, OpKind,
    OpOutcome, OpenError, OpenMode, OpenSpec, QueueEntryId, Released, RunState, RunStateTracker,
    RuntimeHealth, RuntimeInfo, SendError, Session, SessionKey, SessionPage, SessionQuery,
    SessionSummary, SettingsScope, SetupReason, DEFAULT_HUB_CAPACITY,
};
use inline_agent_bridge::{
    DriverCommand, DriverCommandInput, DriverError, DriverFuture, DriverModelOption,
    DriverSettingOption, ProviderId, ProviderSessionId, SessionPageCursor, TurnId,
};
use serde_json::{Value, json};
use tokio::sync::oneshot;

use super::delivery::{OpPlan, op_plan, user_message};
use super::mapper::{ClaudeMapper, RequestMapped};
use super::{CORE_FLOOR, setup_reason};
use crate::agents::{LiveSession, holder, list_live_sessions};
use crate::client::{
    CancelSignal, ClaudeClient, ClientConfig, ClientEvent, ConnectError, ControlError,
    ControlHandler, IncomingCall,
};
use crate::control::{InitializeRequest, InitializeResponse};
use crate::input::UserMessage;
use crate::mcp::{BoxFuture, SdkMcpServer};
use crate::options::{LaunchOptions, ProcessHost, SessionStart};
use crate::sessions::SessionStore;
use crate::version::{ClaudeVersion, capability, probe};

const PROVIDER: &str = "claude";
const CATALOG_TTL: Duration = Duration::from_secs(300);
const SESSION_PAGE_SIZE: usize = 50;

/// How this machine's Claude is run.
#[derive(Clone)]
pub struct ClaudeHarnessConfig {
    /// The executable chosen at setup.
    pub executable: PathBuf,
    pub source: ExecutableSource,
    pub driver_version: String,
    /// Agent Settings default; bypass permissions unless the owner chose otherwise.
    pub permission_mode: String,
    pub model: Option<String>,
    pub effort: Option<String>,
    /// Friendly mode: Claude Code's brief mode (`SendUserMessage`).
    pub brief: bool,
    pub env: Vec<(OsString, OsString)>,
    pub process_host: Option<ProcessHost>,
    /// Inline tools served in-process over `mcp_message`.
    pub mcp_servers: Vec<(String, Arc<dyn SdkMcpServer>)>,
    /// Extra launch flags (labs: `--bare`).
    pub bare: bool,
}

impl ClaudeHarnessConfig {
    pub fn new(executable: impl Into<PathBuf>, driver_version: impl Into<String>) -> Self {
        Self {
            executable: executable.into(),
            source: ExecutableSource::Path,
            driver_version: driver_version.into(),
            permission_mode: "bypassPermissions".into(),
            model: None,
            effort: None,
            brief: false,
            env: Vec::new(),
            process_host: None,
            mcp_servers: Vec::new(),
            bare: false,
        }
    }

    fn launch(&self, cwd: PathBuf, session: SessionStart) -> LaunchOptions {
        let mut options = LaunchOptions::new(&self.executable, cwd);
        options.session = session;
        options.permission_mode = self.permission_mode.clone();
        options.model = self.model.clone();
        options.effort = self.effort.clone();
        options.brief = self.brief;
        options.bare = self.bare;
        options.env = self.env.clone();
        options.process_host = self.process_host.clone();
        options.client_app = Some(format!("inline-bridge/{}", self.driver_version));
        // Checkpoints make "undo this turn's changes" available (rewind_files).
        options.enable_file_checkpointing = true;
        if !self.mcp_servers.is_empty() {
            let names: Vec<&str> = self.mcp_servers.iter().map(|(name, _)| name.as_str()).collect();
            options.mcp_config = Some(crate::mcp::sdk_server_config(&names).to_string());
        }
        options
    }
}

struct CachedCatalog {
    at: Instant,
    catalog: Catalog,
}

struct HarnessState {
    version: Option<ClaudeVersion>,
    version_text: Option<String>,
    health: RuntimeHealth,
    manifest: Option<CapabilityManifest>,
    catalogs: HashMap<PathBuf, CachedCatalog>,
    permission_modes: Vec<String>,
    sessions: HashMap<String, Weak<SessionInner>>,
}

/// Claude Code on this machine.
pub struct ClaudeHarness {
    config: ClaudeHarnessConfig,
    state: Mutex<HarnessState>,
}

impl ClaudeHarness {
    pub fn new(config: ClaudeHarnessConfig) -> Self {
        Self {
            config,
            state: Mutex::new(HarnessState {
                version: None,
                version_text: None,
                health: RuntimeHealth::Unknown,
                manifest: None,
                catalogs: HashMap::new(),
                permission_modes: Vec::new(),
                sessions: HashMap::new(),
            }),
        }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, HarnessState> {
        self.state.lock().unwrap_or_else(|poison| poison.into_inner())
    }

    fn store(&self) -> Option<SessionStore> {
        SessionStore::resolve(&self.config.env)
    }

    /// Revalidates the executable and reads its version (every connection).
    async fn validate(&self, cwd: &std::path::Path) -> Result<ClaudeVersion, SetupReason> {
        let executable = &self.config.executable;
        if !executable.is_file() {
            return Err(SetupReason::ExecutableMissing {
                path: executable.display().to_string(),
            });
        }
        let spec = self.config.launch(cwd.to_path_buf(), SessionStart::Fresh).command();
        let (version, text) = probe(&spec, Duration::from_secs(10)).await.map_err(|error| {
            SetupReason::ExecutableChanged {
                path: executable.display().to_string(),
                detail: error.to_string(),
            }
        })?;
        let mut state = self.state();
        if let Some(previous) = state.version
            && previous != version
        {
            // A new CLI: catalogs and the manifest are re-derived.
            state.catalogs.clear();
            state.permission_modes.clear();
        }
        state.version = Some(version);
        state.version_text = Some(text);
        if !version.at_least(CORE_FLOOR) {
            let reason = SetupReason::UpdateRuntime {
                min_version: CORE_FLOOR.to_string(),
                found: Some(version.to_string()),
            };
            state.health = RuntimeHealth::NeedsSetup {
                reason: reason.clone(),
            };
            return Err(reason);
        }
        state.health = RuntimeHealth::Ready;
        Ok(version)
    }

    fn permission_modes(&self) -> Vec<String> {
        if let Some(modes) = Some(self.state().permission_modes.clone()).filter(|modes| !modes.is_empty()) {
            return modes;
        }
        let output = std::process::Command::new(&self.config.executable)
            .arg("--help")
            .stdin(std::process::Stdio::null())
            .output();
        let modes = output
            .ok()
            .map(|output| parse_permission_modes(&String::from_utf8_lossy(&output.stdout)))
            .unwrap_or_default();
        self.state().permission_modes = modes.clone();
        modes
    }

    async fn live_sessions(&self, cwd: &std::path::Path) -> Vec<LiveSession> {
        let spec = self.config.launch(cwd.to_path_buf(), SessionStart::Fresh).command();
        list_live_sessions(&spec, false, Duration::from_secs(10))
            .await
            .unwrap_or_default()
    }

    fn own_pids(&self) -> Vec<u32> {
        self.state()
            .sessions
            .values()
            .filter_map(Weak::upgrade)
            .filter_map(|session| session.client.pid())
            .collect()
    }

    fn manifest(&self, version: ClaudeVersion, capabilities: &[String]) -> CapabilityManifest {
        CapabilityManifest {
            provider: provider(),
            version: Some(version.to_string()),
            binary_sha256: None,
            schema_sha256: None,
            tier: if version.at_least(CORE_FLOOR) {
                CompatTier::Supported
            } else {
                CompatTier::BelowFloor {
                    min_version: CORE_FLOOR.to_string(),
                }
            },
            availability: availability(capabilities),
            methods: capabilities.iter().cloned().collect(),
            server_requests: ["can_use_tool", "mcp_message", "hook_callback", "elicitation"]
                .into_iter()
                .map(str::to_string)
                .collect(),
            notifications: Default::default(),
            item_types: Default::default(),
            approval_decisions: Default::default(),
        }
    }
}

fn provider() -> ProviderId {
    ProviderId::new(PROVIDER).expect("provider id")
}

/// Choices of `--permission-mode` in `claude --help`.
pub fn parse_permission_modes(help: &str) -> Vec<String> {
    let Some(start) = help.find("--permission-mode") else {
        return Vec::new();
    };
    let rest = &help[start..];
    let Some(choices) = rest.find("(choices:") else {
        return Vec::new();
    };
    let rest = &rest[choices + "(choices:".len()..];
    let end = rest.find(')').unwrap_or(rest.len());
    rest[..end]
        .split(',')
        .map(|choice| choice.trim().trim_matches('"').to_string())
        .filter(|choice| !choice.is_empty())
        .collect()
}

/// What this connection can do, from the CLI's advertised capabilities.
pub fn availability(capabilities: &[String]) -> AvailabilityMatrix {
    let has = |name: &str| capabilities.iter().any(|capability| capability == name);
    let mut matrix = AvailabilityMatrix::default();
    for kind in DeliveryKind::ALL {
        matrix = matrix.with_delivery(kind, Availability::Supported);
    }
    let unavailable = |reason: &str| Availability::unavailable(reason);
    matrix
        .with_op(OpKind::Interrupt, Availability::Supported)
        .with_op(
            OpKind::InterruptCancelQueued,
            if has(capability::INTERRUPT_CANCEL_QUEUED) {
                Availability::Supported
            } else {
                Availability::NeedsFeature {
                    flag: capability::INTERRUPT_CANCEL_QUEUED.into(),
                }
            },
        )
        .with_op(OpKind::QueueEdit, Availability::Supported)
        .with_op(
            OpKind::QueueStart,
            unavailable("Claude runs queued input on its own once the current work ends"),
        )
        .with_op(OpKind::SettingsThread, Availability::Supported)
        .with_op(OpKind::SettingsTurn, unavailable("Claude settings apply from the next message on"))
        .with_op(OpKind::SettingsPersisted, unavailable("defaults are set in Agent Settings"))
        .with_op(OpKind::Compact, Availability::Supported)
        .with_op(OpKind::Clear, Availability::Supported)
        .with_op(OpKind::Rename, Availability::Supported)
        .with_op(OpKind::Archive, unavailable("Claude Code has no archive"))
        .with_op(OpKind::RewindFiles, Availability::Supported)
        .with_op(OpKind::Mode, Availability::Supported)
        .with_op(OpKind::Review, unavailable("Claude has no review operation over its protocol"))
        .with_op(OpKind::Goal, unavailable("Claude has no session goal operation"))
        .with_op(OpKind::StopChild, Availability::Supported)
        .with_op(OpKind::Answer, Availability::Supported)
        .with_op(OpKind::Sample, unavailable("the Claude speak gate is not wired yet"))
        .with_op(OpKind::McpAuth, unavailable("Claude MCP sign-in runs in the terminal (/mcp)"))
}

impl HarnessDriver for ClaudeHarness {
    fn describe(&self) -> RuntimeInfo {
        let state = self.state();
        RuntimeInfo {
            provider: provider(),
            executable: ExecutableInfo {
                path: self.config.executable.clone(),
                source: self.config.source,
                version: state.version.map(|version| version.to_string()),
                sha256: None,
                other_installs: Vec::new(),
            },
            driver_version: self.config.driver_version.clone(),
            health: state.health.clone(),
            manifest: state.manifest.clone(),
        }
    }

    fn catalog<'a>(&'a self, scope: CatalogScope) -> DriverFuture<'a, Catalog> {
        Box::pin(async move {
            let folder = scope
                .folder
                .clone()
                .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
                .unwrap_or_else(|| PathBuf::from("/"));
            if let Some(session) = scope.session.as_ref().and_then(|session| {
                self.state()
                    .sessions
                    .get(session.as_str())
                    .and_then(Weak::upgrade)
            }) && let Some(init) = session.initialize.clone()
            {
                return Ok(catalog_from(&init, &self.permission_modes()));
            }
            if let Some(cached) = self.state().catalogs.get(&folder)
                && cached.at.elapsed() < CATALOG_TTL
            {
                return Ok(cached.catalog.clone());
            }
            self.validate(&folder)
                .await
                .map_err(|reason| DriverError::Unavailable(format!("{reason:?}")))?;
            // A short-lived process answers initialize with the folder's catalog.
            let options = self.config.launch(folder.clone(), SessionStart::Fresh);
            let (client, _events, init) = ClaudeClient::connect(
                &options,
                ClientConfig::default(),
                &InitializeRequest::default(),
            )
            .await
            .map_err(|error| DriverError::Unavailable(error.to_string()))?;
            client.close().await;
            let catalog = catalog_from(&init, &self.permission_modes());
            self.state().catalogs.insert(
                folder,
                CachedCatalog {
                    at: Instant::now(),
                    catalog: catalog.clone(),
                },
            );
            Ok(catalog)
        })
    }

    fn sessions<'a>(&'a self, query: SessionQuery) -> DriverFuture<'a, SessionPage> {
        Box::pin(async move {
            let Some(store) = self.store() else {
                return Ok(SessionPage::default());
            };
            let offset = query
                .cursor
                .as_ref()
                .and_then(|cursor| cursor.as_str().parse::<usize>().ok())
                .unwrap_or(0);
            let limit = query.limit.map_or(SESSION_PAGE_SIZE, |limit| (limit as usize).clamp(1, 200));
            let folder = query.folder.clone();
            let infos = tokio::task::spawn_blocking(move || {
                store.list(folder.as_deref(), true, offset, Some(limit + 1))
            })
            .await
            .map_err(|error| DriverError::Protocol(error.to_string()))?;
            let cwd = query.folder.clone().unwrap_or_else(|| PathBuf::from("/"));
            let live = self.live_sessions(&cwd).await;
            let own = self.own_pids();
            let more = infos.len() > limit;
            let sessions = infos
                .into_iter()
                .take(limit)
                .filter_map(|info| {
                    let key = SessionKey {
                        provider: provider(),
                        session: ProviderSessionId::new(info.session_id.as_str()).ok()?,
                    };
                    Some(SessionSummary {
                        key,
                        title: info.custom_title.clone(),
                        preview: info.first_prompt.clone().or(Some(info.summary.clone())),
                        folder: info.cwd.as_ref().map(PathBuf::from),
                        updated_at: Some((info.last_modified / 1000) as i64),
                        held_by: holder(&live, &info.session_id, &own).map(held_by),
                        archived: false,
                    })
                })
                .collect();
            Ok(SessionPage {
                sessions,
                next: more
                    .then(|| SessionPageCursor::new((offset + limit).to_string()).ok())
                    .flatten(),
            })
        })
    }

    fn open<'a>(&'a self, spec: OpenSpec) -> HarnessFuture<'a, Arc<dyn Session>, OpenError> {
        Box::pin(async move {
            if !spec.folder.is_dir() {
                return Err(OpenError::NeedsSetup(SetupReason::FolderUnavailable {
                    path: spec.folder.display().to_string(),
                }));
            }
            let version = self.validate(&spec.folder).await.map_err(OpenError::NeedsSetup)?;
            let (start, resumed) = match &spec.mode {
                OpenMode::Start => (SessionStart::new_session(), None),
                OpenMode::Resume { session } => {
                    let live = self.live_sessions(&spec.folder).await;
                    if let Some(live) = holder(&live, session.as_str(), &self.own_pids()) {
                        return Err(OpenError::HeldElsewhere(held_by(live)));
                    }
                    if self
                        .store()
                        .and_then(|store| store.find(session.as_str(), None))
                        .is_none()
                    {
                        return Err(OpenError::NotFound);
                    }
                    (
                        SessionStart::Resume {
                            session_id: session.as_str().to_string(),
                        },
                        Some(session.clone()),
                    )
                }
                OpenMode::Fork { session, at } => (
                    SessionStart::Fork {
                        session_id: session.as_str().to_string(),
                        at_message: at.as_ref().map(|at| match at {
                            ForkPoint::Item { item } => item.as_str().to_string(),
                            ForkPoint::Turn { turn } => turn.as_str().to_string(),
                        }),
                        new_session_id: Some(uuid::Uuid::new_v4().to_string()),
                    },
                    None,
                ),
            };
            let mut options = self.config.launch(spec.folder.clone(), start);
            if let Some(model) = &spec.settings.model {
                options.model = Some(model.clone());
            }
            if let Some(effort) = &spec.settings.effort {
                options.effort = Some(effort.clone());
            }
            if let Some(mode) = &spec.settings.permission_mode {
                options.permission_mode = mode.clone();
            }
            let session_id = options
                .target_session_id()
                .map(str::to_string)
                .or_else(|| resumed.as_ref().map(|session| session.as_str().to_string()))
                .ok_or_else(|| OpenError::Driver(DriverError::Protocol("no session id".into())))?;
            let key = SessionKey {
                provider: provider(),
                session: ProviderSessionId::new(session_id.as_str())
                    .map_err(|error| OpenError::Driver(DriverError::Protocol(error.to_string())))?,
            };
            let initialize = InitializeRequest {
                append_system_prompt: spec.instructions.clone(),
                title: matches!(spec.mode, OpenMode::Start).then(|| spec.title.clone()).flatten(),
                per_task_stop_affordance: true,
                ..InitializeRequest::default()
            };
            let session = ClaudeSession::connect(
                key,
                spec.folder.clone(),
                &options,
                &initialize,
                self.config.mcp_servers.clone(),
            )
            .await?;
            let capabilities = session.inner.capabilities();
            let manifest = self.manifest(version, &capabilities);
            {
                let mut state = self.state();
                state.manifest = Some(manifest);
                state.sessions.retain(|_, weak| weak.strong_count() > 0);
                state
                    .sessions
                    .insert(session_id, Arc::downgrade(&session.inner));
            }
            Ok(Arc::new(session) as Arc<dyn Session>)
        })
    }
}

fn held_by(live: &LiveSession) -> HeldBy {
    HeldBy {
        surface: match live.kind.as_str() {
            "background" => HeldSurface::Background,
            "interactive" => HeldSurface::Terminal,
            _ => HeldSurface::Unknown,
        },
        detail: Some(
            [
                live.name.clone(),
                live.pid.map(|pid| format!("pid {pid}")),
                live.status.clone(),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" · "),
        ),
    }
}

fn catalog_from(init: &InitializeResponse, permission_modes: &[String]) -> Catalog {
    let option = |value: &str, label: Option<&str>, description: Option<&str>| DriverSettingOption {
        value: value.to_string(),
        label: label.unwrap_or(value).to_string(),
        description: description.map(str::to_string),
        disabled: false,
    };
    Catalog {
        models: init
            .models
            .iter()
            .map(|model| DriverModelOption {
                value: model.value.clone(),
                label: model.display_name.clone().unwrap_or_else(|| model.value.clone()),
                description: model.description.clone(),
                reasoning: model
                    .supported_effort_levels
                    .iter()
                    .flatten()
                    .map(|level| option(level, None, None))
                    .collect(),
                default_reasoning: None,
                is_default: model.value == "default",
            })
            .collect(),
        speeds: Vec::new(),
        permission_modes: permission_modes
            .iter()
            .map(|mode| option(mode, Some(permission_mode_label(mode)), None))
            .collect(),
        modes: vec![CatalogMode {
            id: ModeId::new("plan").expect("mode id"),
            label: "Plan".into(),
            description: Some("Claude plans without changing anything".into()),
        }],
        commands: init
            .commands
            .iter()
            .map(|command| DriverCommand {
                name: command.name.trim_start_matches('/').to_string(),
                description: command.description.clone().unwrap_or_default(),
                input_hint: command
                    .argument_hint
                    .as_ref()
                    .and_then(Value::as_str)
                    .filter(|hint| !hint.is_empty())
                    .map(str::to_string),
                input: DriverCommandInput::default(),
            })
            .collect(),
        agents: init
            .agents
            .iter()
            .map(|agent| option(&agent.name, None, agent.description.as_deref()))
            .collect(),
        skills: Vec::new(),
    }
}

fn permission_mode_label(mode: &str) -> &str {
    match mode {
        "default" | "manual" => "Ask before tools",
        "acceptEdits" => "Accept edits",
        "bypassPermissions" => "Bypass permissions",
        "plan" => "Plan",
        "dontAsk" => "Don't ask (deny unapproved)",
        "auto" => "Auto",
        other => other,
    }
}

struct SessionInner {
    key: SessionKey,
    session_id: String,
    client: ClaudeClient,
    hub: EventHub,
    mapper: Mutex<ClaudeMapper>,
    tracker: Mutex<RunStateTracker>,
    replies: Mutex<HashMap<String, oneshot::Sender<Result<Value, String>>>>,
    initialize: Option<InitializeResponse>,
    capabilities: Mutex<Vec<String>>,
    store: Option<SessionStore>,
    cwd: PathBuf,
}

impl SessionInner {
    fn emit_all(&self, events: Vec<Event>) {
        for event in events {
            self.emit(event);
        }
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

    fn mapper(&self) -> std::sync::MutexGuard<'_, ClaudeMapper> {
        self.mapper.lock().unwrap_or_else(|poison| poison.into_inner())
    }

    fn capabilities(&self) -> Vec<String> {
        self.capabilities
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .clone()
    }
}

/// Routes the CLI's permission asks to the mapper and parks them until
/// answered.
struct SessionHandler {
    inner: Arc<Mutex<Option<Weak<SessionInner>>>>,
}

impl ControlHandler for SessionHandler {
    fn handle(&self, call: IncomingCall, cancel: CancelSignal) -> BoxFuture<Result<Value, String>> {
        let inner = self
            .inner
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .as_ref()
            .and_then(Weak::upgrade);
        Box::pin(async move {
            let Some(inner) = inner else {
                return Err("session is not ready".into());
            };
            let mapped = inner.mapper().request(&call.request_id, &call.raw);
            match mapped {
                RequestMapped::Interaction(events) => {
                    let (sender, receiver) = oneshot::channel();
                    inner
                        .replies
                        .lock()
                        .unwrap_or_else(|poison| poison.into_inner())
                        .insert(call.request_id.clone(), sender);
                    inner.emit_all(events);
                    drop(cancel);
                    receiver.await.unwrap_or_else(|_| Err("session closed".into()))
                }
                RequestMapped::Reply { response, events } => {
                    inner.emit_all(events);
                    response
                }
                RequestMapped::NotMine => Err(format!(
                    "No handler for control request {}",
                    call.raw["subtype"].as_str().unwrap_or("unknown")
                )),
            }
        })
    }
}

/// One live Claude Code session.
pub struct ClaudeSession {
    inner: Arc<SessionInner>,
}

impl ClaudeSession {
    async fn connect(
        key: SessionKey,
        cwd: PathBuf,
        options: &LaunchOptions,
        initialize: &InitializeRequest,
        mcp_servers: Vec<(String, Arc<dyn SdkMcpServer>)>,
    ) -> Result<Self, OpenError> {
        let slot = Arc::new(Mutex::new(None));
        let config = ClientConfig {
            handler: Arc::new(SessionHandler { inner: slot.clone() }),
            mcp_servers,
            ..ClientConfig::default()
        };
        let (client, mut events) = ClaudeClient::spawn(options, config)
            .map_err(|error| OpenError::Driver(DriverError::Unavailable(error.to_string())))?;
        // Frames that arrive before initialize returns wait in the channel.
        let init = match client.initialize(initialize).await {
            Ok(init) => init,
            Err(error) => {
                let exit = client.wait_exit(Duration::from_secs(3)).await;
                client.close().await;
                return Err(open_error(ConnectError::Initialize {
                    error,
                    exit: exit.map(Box::new),
                }));
            }
        };
        let inner = Arc::new(SessionInner {
            session_id: key.session.as_str().to_string(),
            hub: EventHub::new(key.clone(), DEFAULT_HUB_CAPACITY),
            key,
            client,
            mapper: Mutex::new(ClaudeMapper::new(Some(cwd.clone()))),
            tracker: Mutex::new(RunStateTracker::new(RunState::Idle)),
            replies: Mutex::new(HashMap::new()),
            initialize: Some(init),
            capabilities: Mutex::new(Vec::new()),
            store: SessionStore::resolve(&options.env),
            cwd,
        });
        *slot.lock().unwrap_or_else(|poison| poison.into_inner()) = Some(Arc::downgrade(&inner));
        let pump = Arc::downgrade(&inner);
        tokio::spawn(async move {
            while let Some(event) = events.recv().await {
                let Some(inner) = pump.upgrade() else {
                    return;
                };
                pump_event(&inner, event);
            }
        });
        Ok(Self { inner })
    }

    async fn write(&self, message: &UserMessage) -> Result<(), SendError> {
        self.inner.client.send(message).await.map_err(|error| match error {
            // A broken pipe mid-write: the CLI may or may not have read it.
            ControlError::Closed(reason) => SendError::Unknown(reason),
            other => SendError::Driver(DriverError::Protocol(other.to_string())),
        })
    }

    async fn requests(&self, requests: Vec<Value>) -> Result<Value, OpError> {
        let mut last = Value::Null;
        for request in requests {
            last = self
                .inner
                .client
                .request(request, Duration::from_secs(60))
                .await
                .map_err(op_error)?;
        }
        Ok(last)
    }
}

fn pump_event(inner: &SessionInner, event: ClientEvent) {
    match event {
        ClientEvent::Message(message) => {
            if let crate::wire::MessageKind::Init(init) = &message.kind
                && !init.capabilities.is_empty()
            {
                *inner
                    .capabilities
                    .lock()
                    .unwrap_or_else(|poison| poison.into_inner()) = init.capabilities.clone();
            }
            let events = inner.mapper().message(&message);
            inner.emit_all(events);
        }
        ClientEvent::RequestCancelled { request_id } => {
            // Only permission asks park a reply; other requests open no card.
            let parked = inner
                .replies
                .lock()
                .unwrap_or_else(|poison| poison.into_inner())
                .remove(&request_id)
                .is_some();
            if parked {
                let events = inner.mapper().cancelled(&request_id);
                inner.emit_all(events);
            }
        }
        ClientEvent::Malformed { line, error } => {
            inner.emit(Event::Notice(inline_agent_bridge::harness::Notice {
                level: inline_agent_bridge::harness::NoticeLevel::Warning,
                code: "malformed_frame".into(),
                message: Some(error),
                native: json!({"line": line}),
            }));
        }
        ClientEvent::Exited(report) => {
            inner
                .replies
                .lock()
                .unwrap_or_else(|poison| poison.into_inner())
                .clear();
            let events = inner.mapper().connection_lost();
            inner.emit_all(events);
            let state = match report.startup_failure() {
                Some(failure) => RunState::Waiting {
                    on: inline_agent_bridge::harness::WaitingOn::Setup {
                        reason: setup_reason(failure.reason(), &report.describe()),
                    },
                },
                None => RunState::Offline,
            };
            inner.emit(Event::State { state });
        }
    }
}

impl Session for ClaudeSession {
    fn key(&self) -> &SessionKey {
        &self.inner.key
    }

    fn availability(&self) -> AvailabilityMatrix {
        availability(&self.inner.capabilities())
    }

    fn events(&self) -> EventStream {
        self.inner.hub.subscribe()
    }

    fn send<'a>(&'a self, input: Input) -> HarnessFuture<'a, InputReceipt, SendError> {
        Box::pin(async move {
            let availability = self.availability().delivery(input.delivery.kind());
            if !availability.is_supported() {
                return Err(SendError::Unavailable(availability));
            }
            if uuid::Uuid::parse_str(input.id.as_str()).is_err() {
                return Err(SendError::Rejected(
                    "Claude correlates inputs by uuid; the input id must be a UUID".into(),
                ));
            }
            let active = self.inner.mapper().turn().cloned();
            match (&input.delivery, &active) {
                (Delivery::Turn, Some(active)) => {
                    return Err(SendError::Busy {
                        active: active.clone(),
                    });
                }
                (Delivery::Steer { expected_turn, .. }, active)
                    if active.as_ref() != Some(expected_turn) =>
                {
                    return Err(SendError::TurnMismatch {
                        active: active.clone(),
                    });
                }
                _ => {}
            }
            let message = user_message(&self.inner.session_id, &input);
            self.inner
                .mapper()
                .sent(&input.id, matches!(input.delivery, Delivery::Turn));
            self.write(&message).await?;
            let disposition = match &input.delivery {
                Delivery::Turn => InputDisposition::Started {
                    turn: TurnId::new(input.id.as_str())
                        .map_err(|error| SendError::Rejected(error.to_string()))?,
                },
                Delivery::Steer { expected_turn, .. } => InputDisposition::Steered {
                    turn: expected_turn.clone(),
                },
                Delivery::Queue => {
                    let events = self.inner.mapper().queued(&input.id, &input.content.text);
                    self.inner.emit_all(events);
                    InputDisposition::Queued {
                        entry: QueueEntryId::new(input.id.as_str()).ok(),
                    }
                }
                Delivery::Passive => InputDisposition::Absorbed,
            };
            Ok(InputReceipt {
                input: input.id,
                disposition,
                native: message.to_value(),
            })
        })
    }

    fn control<'a>(&'a self, op: Op) -> HarnessFuture<'a, OpOutcome, OpError> {
        Box::pin(async move {
            let availability = self.availability().op(op.kind());
            if !availability.is_supported() {
                return Err(OpError::Unavailable(availability));
            }
            if let Op::Settings { scope, .. } = &op
                && *scope != SettingsScope::Thread
            {
                return Err(OpError::Unavailable(self.availability().op(op.kind())));
            }
            match &op {
                Op::Answer {
                    interaction,
                    response,
                    by,
                } => {
                    let plan = self.inner.mapper().answer(interaction, response, *by)?;
                    let reply = self
                        .inner
                        .replies
                        .lock()
                        .unwrap_or_else(|poison| poison.into_inner())
                        .remove(&plan.request_id);
                    let Some(reply) = reply else {
                        return Err(OpError::InteractionNotPending);
                    };
                    if reply.send(Ok(plan.response.clone())).is_err() {
                        return Err(OpError::Unknown("the ask was withdrawn while answering".into()));
                    }
                    self.inner.emit_all(plan.events);
                    return Ok(OpOutcome::Accepted {
                        native: plan.response,
                    });
                }
                Op::Rename { title } => {
                    let native = match self
                        .inner
                        .client
                        .rename_session(title, Some(&self.inner.session_id))
                        .await
                    {
                        Ok(native) => native,
                        // CLIs without rename_session: write the store entry.
                        Err(ControlError::Refused { .. }) => {
                            let store = self.inner.store.clone().ok_or_else(|| {
                                OpError::Rejected("no Claude session store".into())
                            })?;
                            store
                                .rename(&self.inner.session_id, title, Some(&self.inner.cwd))
                                .map_err(|error| OpError::Rejected(error.to_string()))?;
                            json!({"renamed_in_store": true})
                        }
                        Err(other) => return Err(op_error(other)),
                    };
                    self.inner.emit(Event::Renamed {
                        title: title.clone(),
                    });
                    return Ok(OpOutcome::Accepted { native });
                }
                Op::Interrupt { .. } => {
                    let changed = self
                        .inner
                        .tracker
                        .lock()
                        .unwrap_or_else(|poison| poison.into_inner())
                        .stopping()
                        .clone();
                    self.inner.hub.emit(Event::State { state: changed });
                }
                _ => {}
            }
            match op_plan(&op) {
                OpPlan::Control(requests) => {
                    let native = self.requests(requests).await?;
                    if let Op::Interrupt { .. } = op {
                        let receipt = serde_json::from_value(native.clone()).unwrap_or_default();
                        let events = self.inner.mapper().interrupt_receipt(&receipt);
                        self.inner.emit_all(events);
                    }
                    Ok(OpOutcome::Accepted { native })
                }
                OpPlan::SlashCommand(command) => {
                    let mut message = UserMessage::text(command);
                    message.session_id = self.inner.session_id.clone();
                    let busy = self.inner.mapper().turn().is_some();
                    if busy {
                        message = message.with_priority(crate::input::Priority::Later);
                    }
                    let id = inline_agent_bridge::harness::InputId::new(message.uuid.as_str())
                        .map_err(|error| OpError::Rejected(error.to_string()))?;
                    self.inner.mapper().sent(&id, !busy);
                    self.inner.client.send(&message).await.map_err(op_error)?;
                    let turn = TurnId::new(message.uuid.as_str())
                        .map_err(|error| OpError::Rejected(error.to_string()))?;
                    Ok(OpOutcome::TurnStarted { turn })
                }
                OpPlan::Session => Err(OpError::Unavailable(Availability::unavailable(
                    "not available for Claude yet",
                ))),
                OpPlan::Unavailable(reason) => {
                    Err(OpError::Unavailable(Availability::unavailable(reason)))
                }
            }
        })
    }

    fn live_work(&self) -> LiveWork {
        let mapper = self.inner.mapper();
        LiveWork {
            turn: mapper.turn().cloned(),
            children: mapper.live_children(),
            interactions: mapper.pending_interactions(),
            queued: mapper.queue().to_vec(),
            wakeups: Vec::new(),
        }
    }

    fn release<'a>(&'a self) -> HarnessFuture<'a, Released, OpError> {
        Box::pin(async move {
            let live = self.live_work();
            // Queued input stays pending in Inline instead of running unattended.
            let mut pending_inputs = Vec::new();
            for queued in &live.queued {
                if self
                    .inner
                    .client
                    .cancel_async_message(queued.entry.as_str())
                    .await
                    .is_ok()
                    && let Some(input) = &queued.input
                {
                    pending_inputs.push(input.clone());
                }
            }
            let mut stopped_children = Vec::new();
            for child in &live.children {
                if self.inner.client.stop_task(child.id.as_str()).await.is_ok() {
                    stopped_children.push(child.clone());
                }
            }
            self.inner.client.close().await;
            let cancelled_interactions: Vec<InteractionId> = live.interactions.clone();
            Ok(Released {
                key: self.inner.key.clone(),
                cancelled_interactions,
                pending_inputs,
                stopped_children,
            })
        })
    }
}

fn op_error(error: ControlError) -> OpError {
    match error {
        ControlError::Refused { message, .. } => OpError::Rejected(message),
        ControlError::Timeout { subtype } => OpError::Unknown(format!("{subtype} timed out")),
        ControlError::Closed(reason) => OpError::Driver(DriverError::ProcessExited(reason)),
        ControlError::Malformed { message, .. } => OpError::Driver(DriverError::Protocol(message)),
    }
}

fn open_error(error: ConnectError) -> OpenError {
    if let Some(failure) = error.startup_failure() {
        return match failure {
            crate::wire::StartupFailure::SessionHeldByBackground => OpenError::HeldElsewhere(HeldBy {
                surface: HeldSurface::Background,
                detail: Some("running as a background session".into()),
            }),
            other => OpenError::NeedsSetup(setup_reason(other.reason(), &error.to_string())),
        };
    }
    OpenError::Driver(DriverError::Unavailable(error.to_string()))
}

#[allow(dead_code)]
fn envelope_session(envelope: &Envelope) -> &str {
    envelope.session.session.as_str()
}
