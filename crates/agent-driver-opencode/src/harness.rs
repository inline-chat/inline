//! `HarnessDriver` for the shared OpenCode v2 service.
//!
//! The first catalog, listing or open connects: it finds the user's running
//! service (or starts it with `opencode service start`), checks its version,
//! subscribes to its event stream and serves Inline's tools. One connection
//! serves every session; sessions are opened, resumed and forked through the
//! HTTP API and followed through the shared stream.

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use inline_agent_bridge::harness::{
    CapabilityManifest, Catalog, CatalogScope, CompatTier, Event, ExecutableInfo, ExecutableSource,
    ForkPoint, HarnessDriver, HarnessFuture, OpenError, OpenMode, OpenSpec, RuntimeHealth,
    RuntimeInfo, Session, SessionKey, SessionPage, SessionQuery, SessionSummary, SetupReason,
};
use inline_agent_bridge::{
    DriverError, DriverFuture, DriverSettingOption, HostToolConfiguration, ProviderId,
    ProviderSessionId, SessionPageCursor, TurnId,
};
use reqwest::Method;
use serde_json::{Value, json};
use tokio::sync::Mutex as AsyncMutex;

use crate::api::{ApiError, Query, data};
use crate::events::{EventBus, ServiceSignal};
use crate::link::Link;
use crate::service::{ServiceConfig, ServiceError};
use crate::session::{OpenCodeSession, SessionInner};
use crate::tools::{SessionResolver, ToolHost};
use crate::version;

const CATALOG_TTL: Duration = Duration::from_secs(120);
const SESSION_PAGE_SIZE: u32 = 50;
/// Instruction entry key for Inline's guide (`<context key="inline">`).
const GUIDE_KEY: &str = "inline";

/// How this machine's OpenCode is used.
#[derive(Clone)]
pub struct OpenCodeHarnessConfig {
    /// The executable chosen at setup; it starts the service when none runs.
    pub executable: PathBuf,
    pub source: ExecutableSource,
    pub driver_version: String,
    /// Inline's host tools, served over client MCP.
    pub host_tools: Option<HostToolConfiguration>,
    /// Service registration file; `None` uses OpenCode's default.
    pub registration: Option<PathBuf>,
    /// Environment variable names removed when starting the service.
    pub scrub_env: Vec<OsString>,
}

impl OpenCodeHarnessConfig {
    pub fn new(executable: impl Into<PathBuf>, driver_version: impl Into<String>) -> Self {
        Self {
            executable: executable.into(),
            source: ExecutableSource::Path,
            driver_version: driver_version.into(),
            host_tools: None,
            registration: None,
            scrub_env: Vec::new(),
        }
    }

    fn service(&self) -> ServiceConfig {
        let mut service = ServiceConfig::new(&self.executable);
        service.registration = self.registration.clone();
        service.scrub_env = self.scrub_env.clone();
        service
    }
}

/// OpenCode on this machine.
pub struct OpenCodeHarness {
    shared: Arc<Shared>,
}

pub(crate) struct Shared {
    config: OpenCodeHarnessConfig,
    connection: AsyncMutex<Option<Arc<Connection>>>,
    state: Mutex<HarnessState>,
}

pub(crate) struct Connection {
    pub(crate) link: Arc<Link>,
    pub(crate) bus: Arc<EventBus>,
    tools: Option<Arc<ToolHost>>,
}

impl Drop for Connection {
    fn drop(&mut self) {
        self.bus.shutdown();
        if let Some(tools) = &self.tools {
            tools.shutdown();
        }
    }
}

struct HarnessState {
    health: RuntimeHealth,
    version: Option<String>,
    manifest: Option<CapabilityManifest>,
    catalogs: HashMap<PathBuf, (Instant, Catalog)>,
    models: HashMap<PathBuf, (Instant, Value)>,
    sessions: HashMap<String, Weak<SessionInner>>,
}

fn provider() -> ProviderId {
    ProviderId::new(crate::PROVIDER).expect("provider id")
}

impl OpenCodeHarness {
    pub fn new(config: OpenCodeHarnessConfig) -> Self {
        Self {
            shared: Arc::new(Shared {
                config,
                connection: AsyncMutex::new(None),
                state: Mutex::new(HarnessState {
                    health: RuntimeHealth::Unknown,
                    version: None,
                    manifest: None,
                    catalogs: HashMap::new(),
                    models: HashMap::new(),
                    sessions: HashMap::new(),
                }),
            }),
        }
    }

    /// Connects to an already-running service at a known endpoint (tests,
    /// labs). Skips discovery and never starts a service.
    pub async fn with_link(config: OpenCodeHarnessConfig, link: Link) -> Result<Self, OpenError> {
        let harness = Self::new(config);
        harness.shared.install(Arc::new(link)).await?;
        Ok(harness)
    }

    /// Closes the event stream and the tool connections. Sessions stay open
    /// in the service for other clients.
    pub async fn shutdown(&self) {
        self.shared.connection.lock().await.take();
    }
}

impl Shared {
    fn state(&self) -> std::sync::MutexGuard<'_, HarnessState> {
        self.state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    /// Forgets a released handle, unless a newer one holds the session.
    pub(crate) fn forget(&self, session: &str, inner: &SessionInner) {
        let mut state = self.state();
        if state
            .sessions
            .get(session)
            .is_some_and(|held| std::ptr::eq(held.as_ptr(), inner))
        {
            state.sessions.remove(session);
        }
    }

    /// The live connection, connecting on first use.
    async fn connection(self: &Arc<Self>) -> Result<Arc<Connection>, OpenError> {
        if let Some(connection) = self.connection.lock().await.clone() {
            return Ok(connection);
        }
        let link = Link::connect(self.config.service())
            .await
            .map_err(|error| {
                let reason = match &error {
                    ServiceError::ExecutableMissing(path) => {
                        SetupReason::ExecutableMissing { path: path.clone() }
                    }
                    other => SetupReason::Harness {
                        code: "opencode_service".to_owned(),
                        message: other.to_string(),
                    },
                };
                self.state().health = RuntimeHealth::NeedsSetup {
                    reason: reason.clone(),
                };
                OpenError::NeedsSetup(reason)
            })?;
        self.install(Arc::new(link)).await
    }

    async fn install(self: &Arc<Self>, link: Arc<Link>) -> Result<Arc<Connection>, OpenError> {
        let mut slot = self.connection.lock().await;
        if let Some(connection) = slot.clone() {
            return Ok(connection);
        }
        let info = link.info();
        let parsed = version::parse(&info.version);
        let tier = match &parsed {
            Some(found) if version::native_supported(found) => CompatTier::Supported,
            Some(found) if found.major > 2 => CompatTier::NewerThanBridge {
                reason: format!("OpenCode {found} is newer than this Inline CLI supports"),
            },
            _ => CompatTier::BelowFloor {
                min_version: version::CORE_FLOOR.to_string(),
            },
        };
        {
            let mut state = self.state();
            state.version = Some(info.version.clone());
            state.manifest = Some(manifest(&info.version, tier.clone()));
        }
        match tier {
            CompatTier::Supported => {}
            CompatTier::BelowFloor { min_version } => {
                let reason = SetupReason::UpdateRuntime {
                    min_version,
                    found: Some(info.version.clone()),
                };
                self.state().health = RuntimeHealth::NeedsSetup {
                    reason: reason.clone(),
                };
                return Err(OpenError::NeedsSetup(reason));
            }
            CompatTier::NewerThanBridge { reason } => {
                let reason = SetupReason::UpdateInline { detail: reason };
                self.state().health = RuntimeHealth::NeedsSetup {
                    reason: reason.clone(),
                };
                return Err(OpenError::NeedsSetup(reason));
            }
        }
        let bus = EventBus::start(link.clone());
        let tools = self.config.host_tools.clone().map(|tools| {
            let shared = Arc::downgrade(self);
            let resolver: SessionResolver = Arc::new(move |session: &str| {
                let shared = shared.upgrade()?;
                let sessions: Vec<Arc<SessionInner>> = shared
                    .state()
                    .sessions
                    .values()
                    .filter_map(Weak::upgrade)
                    .collect();
                sessions.iter().find_map(|inner| inner.binding(session))
            });
            Arc::new(ToolHost::new(link.clone(), tools, resolver))
        });
        // Catalog changes (new models, agents, commands) refresh pickers.
        let mut signals = bus.signals();
        let weak = Arc::downgrade(self);
        tokio::spawn(async move {
            while let Ok(signal) = signals.recv().await {
                let Some(shared) = weak.upgrade() else { return };
                if signal == ServiceSignal::CatalogChanged {
                    let mut state = shared.state();
                    state.catalogs.clear();
                    state.models.clear();
                }
            }
        });
        // Give the stream a moment so events of a first prompt are not missed.
        bus.wait_connected(Duration::from_secs(5)).await;
        self.state().health = RuntimeHealth::Ready;
        let connection = Arc::new(Connection { link, bus, tools });
        *slot = Some(connection.clone());
        Ok(connection)
    }

    /// The listed models of a folder, cached briefly.
    async fn models(self: &Arc<Self>, folder: &Path) -> Option<Value> {
        if let Some((at, models)) = self.state().models.get(folder)
            && at.elapsed() < CATALOG_TTL
        {
            return Some(models.clone());
        }
        let connection = self.connection().await.ok()?;
        let models = connection
            .link
            .api()
            .get("api/model", Query::new().location(Some(folder)))
            .await
            .ok()
            .map(data)?;
        self.state()
            .models
            .insert(folder.to_path_buf(), (Instant::now(), models.clone()));
        Some(models)
    }

    /// Whether `name` is an OpenCode command in `folder`.
    pub(crate) async fn has_command(self: &Arc<Self>, folder: &Path, name: &str) -> bool {
        let cached = self
            .state()
            .catalogs
            .get(folder)
            .filter(|(at, _)| at.elapsed() < CATALOG_TTL)
            .map(|(_, catalog)| catalog.commands.iter().any(|command| command.name == name));
        if let Some(found) = cached {
            return found;
        }
        let Ok(connection) = self.connection().await else {
            return false;
        };
        connection
            .link
            .api()
            .get("api/command", Query::new().location(Some(folder)))
            .await
            .ok()
            .map(data)
            .and_then(|commands| commands.as_array().cloned())
            .into_iter()
            .flatten()
            .any(|command| {
                command
                    .get("name")
                    .and_then(Value::as_str)
                    .map(|name| name.trim_start_matches('/'))
                    == Some(name)
            })
    }

    pub(crate) async fn context_window(
        self: &Arc<Self>,
        folder: &Path,
        model: &str,
    ) -> Option<u64> {
        let models = self.models(folder).await?;
        crate::catalog::context_window(&models, model)
    }
}

fn manifest(version: &str, tier: CompatTier) -> CapabilityManifest {
    CapabilityManifest {
        provider: provider(),
        version: Some(version.to_owned()),
        binary_sha256: None,
        schema_sha256: None,
        tier,
        availability: crate::session::availability(),
        methods: [
            "session.create",
            "session.prompt",
            "session.synthetic",
            "session.interrupt",
            "session.compact",
            "session.fork",
            "session.revert",
            "session.model",
            "session.agent",
            "session.generate",
            "session.inbox",
            "session.log",
            "session.instructions",
            "client-mcp",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        server_requests: ["permission.asked", "form.created"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        notifications: Default::default(),
        item_types: ["text", "reasoning", "tool"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        approval_decisions: [(
            "permission".to_owned(),
            ["once", "always", "reject"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
        )]
        .into_iter()
        .collect(),
    }
}

fn driver_error(error: OpenError) -> DriverError {
    match error {
        OpenError::Driver(error) => error,
        other => DriverError::Unavailable(other.to_string()),
    }
}

fn api_open_error(error: ApiError) -> OpenError {
    if error.is_not_found() {
        OpenError::NotFound
    } else {
        OpenError::Driver(DriverError::Unavailable(error.to_string()))
    }
}

impl HarnessDriver for OpenCodeHarness {
    fn describe(&self) -> RuntimeInfo {
        let state = self.shared.state();
        RuntimeInfo {
            provider: provider(),
            executable: ExecutableInfo {
                path: self.shared.config.executable.clone(),
                source: self.shared.config.source,
                version: state.version.clone(),
                sha256: None,
                other_installs: Vec::new(),
            },
            driver_version: self.shared.config.driver_version.clone(),
            health: state.health.clone(),
            manifest: state.manifest.clone(),
        }
    }

    fn catalog<'a>(&'a self, scope: CatalogScope) -> DriverFuture<'a, Catalog> {
        Box::pin(async move {
            let shared = &self.shared;
            let folder = scope
                .folder
                .clone()
                .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
                .unwrap_or_else(|| PathBuf::from("/"));
            if let Some((at, catalog)) = shared.state().catalogs.get(&folder)
                && at.elapsed() < CATALOG_TTL
            {
                return Ok(catalog.clone());
            }
            let connection = shared.connection().await.map_err(driver_error)?;
            let api = connection.link.api();
            let catalog = crate::catalog::read(&api, Some(&folder))
                .await
                .map_err(|error| DriverError::Unavailable(error.to_string()))?;
            // A folder still loading lists no commands; read it again next time.
            if !catalog.commands.is_empty() {
                let mut cached = catalog.clone();
                // Usage is a live reading, not cached with the pickers.
                cached.usage.clear();
                shared
                    .state()
                    .catalogs
                    .insert(folder, (Instant::now(), cached));
            }
            Ok(catalog)
        })
    }

    fn sessions<'a>(&'a self, query: SessionQuery) -> DriverFuture<'a, SessionPage> {
        Box::pin(async move {
            let connection = self.shared.connection().await.map_err(driver_error)?;
            let api = connection.link.api();
            let limit = query.limit.unwrap_or(SESSION_PAGE_SIZE).clamp(1, 200);
            let request = Query::new()
                .with("limit", limit)
                .with("order", "desc")
                // Top-level sessions only; sub-agents show under their parent.
                .with("parentID", "null")
                .with("archived", query.archived)
                .maybe(
                    "directory",
                    query
                        .folder
                        .as_ref()
                        .map(|folder| folder.display().to_string()),
                )
                .maybe(
                    "cursor",
                    query
                        .cursor
                        .as_ref()
                        .map(|cursor| cursor.as_str().to_owned()),
                );
            let response = api
                .get("api/session", request)
                .await
                .map_err(|error| DriverError::Unavailable(error.to_string()))?;
            let sessions = response
                .get("data")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(summary)
                .collect();
            Ok(SessionPage {
                sessions,
                next: response
                    .pointer("/cursor/next")
                    .and_then(Value::as_str)
                    .and_then(|cursor| SessionPageCursor::new(cursor).ok()),
            })
        })
    }

    fn open<'a>(&'a self, spec: OpenSpec) -> HarnessFuture<'a, Arc<dyn Session>, OpenError> {
        Box::pin(async move {
            let shared = &self.shared;
            if !spec.folder.is_dir() {
                return Err(OpenError::NeedsSetup(SetupReason::FolderUnavailable {
                    path: spec.folder.display().to_string(),
                }));
            }
            let connection = shared.connection().await?;
            let api = connection.link.api();
            let info = match &spec.mode {
                OpenMode::Start => {
                    let mut body = json!({
                        "location": {"directory": spec.folder.display().to_string()},
                        "metadata": {"inline": true},
                    });
                    if let Some(title) = &spec.title {
                        body["title"] = json!(title);
                    }
                    if let Some(model) = &spec.settings.model
                        && let Some(reference) =
                            crate::catalog::model_ref(model, spec.settings.effort.as_deref())
                    {
                        body["model"] = reference;
                    }
                    if let Some(rules) = spec
                        .settings
                        .permission_mode
                        .as_deref()
                        .and_then(crate::catalog::permission_rules)
                    {
                        body["permissions"] = rules;
                    }
                    api.post("api/session", body)
                        .await
                        .map_err(api_open_error)?
                        .map(data)
                        .unwrap_or_default()
                }
                OpenMode::Resume { session } => api
                    .get(&format!("api/session/{}", session.as_str()), Query::new())
                    .await
                    .map(data)
                    .map_err(api_open_error)?,
                OpenMode::Fork { session, at } => {
                    let before = match at {
                        Some(point) => fork_boundary(&api, session.as_str(), point).await?,
                        None => None,
                    };
                    let mut body = json!({});
                    if let Some(before) = before {
                        body["before"] = json!(before);
                    }
                    api.post(&format!("api/session/{}/fork", session.as_str()), body)
                        .await
                        .map_err(api_open_error)?
                        .map(data)
                        .unwrap_or_default()
                }
            };
            let id = info
                .get("id")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    OpenError::Driver(DriverError::Protocol(
                        "OpenCode returned no session id".to_owned(),
                    ))
                })?
                .to_owned();
            let folder = info
                .pointer("/location/directory")
                .and_then(Value::as_str)
                .map(PathBuf::from)
                .unwrap_or_else(|| spec.folder.clone());
            let key = SessionKey {
                provider: provider(),
                session: ProviderSessionId::new(id.as_str())
                    .map_err(|error| OpenError::Driver(DriverError::Protocol(error.to_string())))?,
            };
            // Subscribe before reading state so nothing falls between.
            let receiver = connection.bus.register(&id);
            let inner = SessionInner::new(
                key,
                folder.clone(),
                connection.link.clone(),
                connection.bus.clone(),
                Arc::downgrade(shared),
            );
            shared
                .state()
                .sessions
                .insert(id.clone(), Arc::downgrade(&inner));
            let session: Arc<dyn Session> = Arc::new(OpenCodeSession {
                inner: inner.clone(),
            });
            if let Some(tools) = &connection.tools {
                tools.serve(folder.clone());
            }
            // Inline's trusted guide lives in the session's instructions,
            // where it survives compaction; a changed guide is narrated.
            let guide = spec.instructions.as_deref().filter(|guide| !guide.trim().is_empty()).map(|guide| {
                if connection.tools.is_some() {
                    // OpenCode serves client tools inside its Code Mode
                    // `execute` tool unless that tool is denied.
                    format!(
                        "{guide}\n\nIn OpenCode, Inline's tools are the `{server}` MCP tools: `{server}_<tool>`, or `{server}.<tool>(...)` inside `execute`.",
                        server = crate::tools::SERVER_NAME
                    )
                } else {
                    guide.to_owned()
                }
            });
            if let Some(guide) = guide
                && let Err(error) = api
                    .send(
                        Method::PUT,
                        &format!("api/experimental/session/{id}/instructions/entries/{GUIDE_KEY}"),
                        Query::new(),
                        Some(json!({"value": guide})),
                    )
                    .await
            {
                log::warn!(target: "inline::opencode", "could not attach Inline's guide to {id}: {error}");
            }
            if !matches!(spec.mode, OpenMode::Start) {
                apply_settings(&api, &id, &spec).await;
            }
            restore(shared, &inner, &api, &info, &folder, &spec).await;
            inner.follow(receiver);
            Ok(session)
        })
    }
}

/// Settings for a resumed or forked session.
async fn apply_settings(api: &crate::api::Api, id: &str, spec: &OpenSpec) {
    if let Some(model) = &spec.settings.model
        && let Some(reference) = crate::catalog::model_ref(model, spec.settings.effort.as_deref())
        && let Err(error) = api
            .post(
                &format!("api/session/{id}/model"),
                json!({"model": reference}),
            )
            .await
    {
        log::warn!(target: "inline::opencode", "could not set the model of {id}: {error}");
    }
    if let Some(rules) = spec
        .settings
        .permission_mode
        .as_deref()
        .and_then(crate::catalog::permission_rules)
        && let Err(error) = api
            .send(
                Method::PATCH,
                &format!("api/session/{id}"),
                Query::new(),
                Some(json!({"permissions": rules})),
            )
            .await
    {
        log::warn!(target: "inline::opencode", "could not set permissions of {id}: {error}");
    }
}

/// Brings a newly held session up to date: settings, a running turn,
/// sub-agents, pending approvals and questions, and the queue.
async fn restore(
    shared: &Arc<Shared>,
    inner: &Arc<SessionInner>,
    api: &crate::api::Api,
    info: &Value,
    folder: &Path,
    spec: &OpenSpec,
) {
    let id = inner.id.clone();
    let (inbox_path, message_path) = (
        format!("api/session/{id}/inbox"),
        format!("api/session/{id}/message"),
    );
    let log_path = format!("api/experimental/session/{id}/log");
    let (active, inbox, children, latest, floor) = tokio::join!(
        api.get("api/session/active", Query::new()),
        api.get(&inbox_path, Query::new()),
        api.get(
            "api/session",
            Query::new().with("parentID", &id).with("limit", 50)
        ),
        api.get(
            &message_path,
            Query::new()
                .with("type", "user")
                .with("limit", 1)
                .with("order", "desc"),
        ),
        log_head(api, &log_path),
    );
    let active = active.map(data).unwrap_or_default();
    let running = |session: &str| active.get(session).is_some();
    let model = info
        .get("model")
        .and_then(crate::catalog::model_value)
        .or_else(|| spec.settings.model.clone());
    let window = match &model {
        Some(model) => shared.context_window(folder, model).await,
        None => None,
    };
    {
        let mut state = inner.state();
        let mut events = Vec::new();
        state.mapper.set_context_window(window);
        // Effective settings as the session reports them.
        let mut settings = inline_agent_bridge::harness::EffectiveSettings {
            model: model.map(|value| DriverSettingOption {
                label: value.clone(),
                value,
                description: None,
                disabled: false,
            }),
            effort: info
                .pointer("/model/variant")
                .and_then(Value::as_str)
                .map(str::to_owned),
            speed: None,
            permission_mode: spec.settings.permission_mode.clone(),
            mode: info.get("agent").and_then(Value::as_str).map(str::to_owned),
            folder: Some(folder.to_path_buf()),
        };
        if settings.effort.is_none() {
            settings.effort = spec.settings.effort.clone();
        }
        state.mapper.set_floor(floor);
        state.mapper.set_settings(settings.clone());
        events.push(Event::Settings {
            effective: settings,
        });
        if let Some(title) = info
            .get("title")
            .and_then(Value::as_str)
            .filter(|_| !matches!(spec.mode, OpenMode::Start))
        {
            events.push(Event::Renamed {
                title: title.to_owned(),
            });
        }
        for child in children
            .ok()
            .and_then(|children| children.get("data").cloned())
            .and_then(|children| children.as_array().cloned())
            .unwrap_or_default()
        {
            if let Some(child_id) = child.get("id").and_then(Value::as_str) {
                inner_link_child(inner, child_id);
                state.mapper.adopt_child(
                    child_id,
                    child
                        .get("title")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                    running(child_id),
                );
            }
        }
        if running(&id) {
            // Named, like every turn, after the prompt that started it.
            let turn = latest
                .ok()
                .and_then(|latest| latest.get("data").cloned())
                .and_then(|data| {
                    data.as_array()?
                        .first()?
                        .get("id")?
                        .as_str()
                        .map(str::to_owned)
                })
                .and_then(|turn| TurnId::new(turn).ok())
                .unwrap_or_else(|| TurnId::new(format!("{id}:running")).expect("turn id"));
            events.push(state.mapper.resume_turn(turn));
        }
        if let Ok(inbox) = inbox {
            events.extend(state.mapper.seed_inbox(&data(inbox)));
        }
        inner.emit_locked(&mut state, events);
    }
    inner.refresh_interactions().await;
}

/// The log's head sequence: a replay after an impossible sequence answers
/// with only the `log.synced` marker, which carries the current head.
async fn log_head(api: &crate::api::Api, path: &str) -> Option<u64> {
    // JavaScript's largest safe integer: past any real sequence.
    const BEYOND: u64 = 9_007_199_254_740_991;
    let stream = api
        .sse(
            path,
            Query::new().with("after", BEYOND).with("follow", false),
        )
        .await
        .ok()?;
    let mut stream = Box::pin(stream);
    let reading = async {
        while let Some(Ok(event)) = futures_util::StreamExt::next(&mut stream).await {
            if event.get("type").and_then(Value::as_str) == Some("log.synced") {
                // An empty log has no head; replay from the start then.
                return Some(event.get("seq").and_then(Value::as_u64));
            }
        }
        None
    };
    tokio::time::timeout(Duration::from_secs(5), reading)
        .await
        .ok()
        .flatten()
        .flatten()
}

fn inner_link_child(inner: &SessionInner, child: &str) {
    inner.bus().link_child(child, &inner.id);
}

/// The `before` message of a fork that keeps everything through `point`:
/// the first user message after it, or `None` when it is the end. A point
/// that is not in the session is an error, never a silent full copy.
async fn fork_boundary(
    api: &crate::api::Api,
    session: &str,
    point: &ForkPoint,
) -> Result<Option<String>, OpenError> {
    let target = match point {
        ForkPoint::Item { item } => item.as_str().to_owned(),
        ForkPoint::Turn { turn } => turn.as_str().to_owned(),
    };
    // Item ids are message ids, `msg_x:text:0` parts or tool call ids.
    let target_message = target.split(':').next().unwrap_or(&target).to_owned();
    let path = format!("api/session/{session}/message");
    let mut cursor: Option<String> = None;
    let mut found = false;
    for _ in 0..100 {
        let page = api
            .get(
                &path,
                Query::new()
                    .with("order", "asc")
                    .with("limit", 200)
                    .maybe("cursor", cursor.clone()),
            )
            .await
            .map_err(api_open_error)?;
        for message in page
            .get("data")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let id = message
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let kind = message
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if found && kind == "user" {
                return Ok(Some(id.to_owned()));
            }
            let holds_tool = message
                .get("content")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .any(|part| part.get("id").and_then(Value::as_str) == Some(target.as_str()));
            if id == target_message || holds_tool {
                found = true;
            }
        }
        cursor = page
            .pointer("/cursor/next")
            .and_then(Value::as_str)
            .map(str::to_owned);
        if cursor.is_none() {
            break;
        }
    }
    if found {
        Ok(None)
    } else {
        Err(OpenError::Unavailable(
            inline_agent_bridge::harness::Availability::unavailable(
                "that point is not in the OpenCode session",
            ),
        ))
    }
}

/// One native session in a listing.
fn summary(info: &Value) -> Option<SessionSummary> {
    let id = info.get("id")?.as_str()?;
    Some(SessionSummary {
        key: SessionKey {
            provider: provider(),
            session: ProviderSessionId::new(id).ok()?,
        },
        title: info.get("title").and_then(Value::as_str).map(str::to_owned),
        preview: None,
        folder: info
            .pointer("/location/directory")
            .and_then(Value::as_str)
            .map(PathBuf::from),
        updated_at: info
            .pointer("/time/updated")
            .and_then(Value::as_i64)
            .map(crate::catalog::milliseconds_to_seconds),
        // The service is shared: another client running it does not hold
        // it. Inline steers into a running session like any client.
        held_by: None,
        archived: info.pointer("/time/archived").is_some(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summaries_read_session_info() {
        let info = json!({
            "id": "ses_1",
            "title": "Fix the build",
            "location": {"directory": "/work/app"},
            "time": {"created": 1_700_000_000_000i64, "updated": 1_700_000_100_000i64, "archived": 1},
        });
        let summary = summary(&info).unwrap();
        assert_eq!(summary.key.session.as_str(), "ses_1");
        assert_eq!(summary.folder.as_deref(), Some(Path::new("/work/app")));
        assert_eq!(summary.updated_at, Some(1_700_000_100));
        assert!(summary.archived);
        assert!(summary.held_by.is_none());
    }

    #[test]
    fn the_manifest_declares_the_native_core() {
        let manifest = manifest("2.2.5", CompatTier::Supported);
        assert!(manifest.core_ready());
        assert!(manifest.methods.contains("client-mcp"));
        assert!(
            manifest
                .availability
                .op(inline_agent_bridge::harness::OpKind::Compact)
                .is_supported()
        );
    }
}
