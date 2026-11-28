//! The Codex `HarnessDriver` and `Session`: one private app-server process per
//! driver, sessions routed by thread id.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex, Weak};
use std::time::Duration;

use inline_agent_bridge::harness::{
    AvailabilityMatrix, Catalog, CatalogFolder, CatalogMode, CatalogScope, ChildRef, CompatTier,
    DEFAULT_HUB_CAPACITY, Delivery, EffectiveSettings, Event, EventHub, EventStream,
    ExecutableInfo, ExecutableSource, HarnessDriver, HarnessFuture, Input, InputDisposition,
    InputReceipt, LiveWork, ModeId, Op, OpError, OpOutcome, OpenError, OpenMode, OpenSpec,
    QueueEntryId, QueueOp, QueuedInput, ReleaseOutcome, Released, RunState, RuntimeHealth,
    RuntimeInfo, SendError, Session, SessionKey, SessionPage, SessionQuery, SessionSummary,
    SetupReason,
};
use inline_agent_bridge::{
    DriverError, DriverFuture, DriverModelOption, DriverSettingOption, HostToolConfiguration,
    ProviderId, ProviderSessionId, SessionPageCursor, TurnId,
};
use semver::Version;
use serde_json::{Value, json};
use tokio::sync::Mutex as AsyncMutex;

use super::delivery::{Request, TurnFacts, input_request, op_request};
use super::manifest::{self, SchemaSurface};
use super::mapper::{AnswerPlan, CodexMapper, RequestMapped};
use crate::peer::{CodexPeer, IncomingMessage, PeerError, RoutedError};
use crate::process::{
    CodexDriverWriter, CodexLaunchConfig, ProcessControl, StdioProcess,
    app_server_version_from_user_agent, spawn_stdio_process,
};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const QUEUE_PREVIEW_CHARS: usize = 160;
const QUEUE_PAGE_SIZE: u32 = 100;
/// Bound on queue pages read in one listing (10,000 entries).
const QUEUE_MAX_PAGES: usize = 100;
/// Bound on project pages read for the catalog (1,000 projects).
const PROJECT_MAX_PAGES: usize = 10;

/// How to run Codex for one bot on this machine.
#[derive(Clone, Debug)]
pub struct CodexHarnessConfig {
    /// Launch settings; `executable` is the path chosen at setup.
    pub launch: CodexLaunchConfig,
    /// How the executable was chosen.
    pub source: ExecutableSource,
    /// SHA-256 recorded at setup. A different binary at that path needs setup
    /// again; Inline never switches installs silently.
    pub pinned_sha256: Option<String>,
    /// Inline CLI version sent in `initialize`.
    pub bridge_version: String,
    /// Folder for the schema cache (`<root>/codex-schema/<sha256>-<version>/`).
    pub cache_root: PathBuf,
}

/// Codex on the session contract.
pub struct CodexHarness {
    config: CodexHarnessConfig,
    info: StdMutex<RuntimeInfo>,
    connection: AsyncMutex<Option<Arc<Connection>>>,
    host_tools: Arc<StdMutex<Option<HostToolConfiguration>>>,
}

struct Connection {
    peer: CodexPeer<CodexDriverWriter>,
    control: ProcessControl,
    sessions: StdMutex<HashMap<String, Weak<SessionInner>>>,
    availability: AvailabilityMatrix,
    /// Random per app-server process. Codex numbers its requests from 0 in
    /// each process; interaction ids carry this so a resumed thread's new
    /// requests never reuse an earlier process's ids (and cards).
    epoch: String,
}

impl Connection {
    /// The process exited, or the peer closed (for example on a corrupt frame).
    fn closed(&self) -> bool {
        self.control.is_finished() || self.peer.is_closed()
    }

    async fn request(&self, request: Request) -> Result<Value, PeerError> {
        self.peer
            .request_with_timeout(request.method, request.params, REQUEST_TIMEOUT)
            .await
    }

    /// A request whose refusal is read from its `codexErrorInfo`.
    async fn request_with_error_data(&self, request: Request) -> Result<Value, RoutedError> {
        self.peer
            .request_with_error_data(request.method, request.params, REQUEST_TIMEOUT)
            .await
    }

    async fn opening_request(&self, request: Request) -> Result<(Value, u64), PeerError> {
        tokio::time::timeout(
            REQUEST_TIMEOUT,
            self.peer
                .request_with_wire_sequence(request.method, request.params),
        )
        .await
        .unwrap_or_else(|_| Err(PeerError::Timeout(request.method.to_owned())))
    }

    fn remove_session(&self, inner: &SessionInner) {
        let mut sessions = self.sessions.lock().expect("session map poisoned");
        if sessions
            .get(&inner.thread)
            .is_some_and(|known| std::ptr::eq(known.as_ptr(), inner))
        {
            sessions.remove(&inner.thread);
        }
    }
}

impl CodexHarness {
    /// A driver that connects on first use.
    pub fn new(config: CodexHarnessConfig) -> Self {
        let info = RuntimeInfo {
            provider: ProviderId::new("codex").expect("provider id"),
            executable: ExecutableInfo {
                path: config.launch.executable.clone(),
                source: config.source,
                version: None,
                sha256: config.pinned_sha256.clone(),
                other_installs: Vec::new(),
            },
            driver_version: env!("CARGO_PKG_VERSION").to_owned(),
            health: RuntimeHealth::Unknown,
            manifest: None,
        };
        Self {
            config,
            info: StdMutex::new(info),
            connection: AsyncMutex::new(None),
            host_tools: Arc::new(StdMutex::new(None)),
        }
    }

    /// Installs Inline's in-process tools, bound to the agent and its work.
    pub fn configure_host_tools(&self, configuration: HostToolConfiguration) {
        *self.host_tools.lock().expect("host tools poisoned") = Some(configuration);
    }

    async fn open_once(&self, spec: &OpenSpec) -> Result<Arc<dyn Session>, OpenError> {
        let connection = self.connection().await?;
        let Request { method, params } = super::delivery::open_request(spec, self.dynamic_tools());
        // A resume can run input persisted in the native queue and ask for
        // approval right away, so the session listens before it loads, and
        // the queue it may run is published first.
        let early = match &spec.mode {
            OpenMode::Resume { session } => {
                let inner = SessionInner::new(&connection, session.as_str().to_owned())?;
                connection
                    .sessions
                    .lock()
                    .expect("session map poisoned")
                    .insert(inner.thread.clone(), Arc::downgrade(&inner));
                let _ = inner.refresh_queue().await;
                Some(inner)
            }
            _ => None,
        };
        let (response, response_sequence) =
            match connection.opening_request(Request { method, params }).await {
                Ok(response) => response,
                Err(error) => {
                    if let Some(inner) = &early {
                        connection.remove_session(inner);
                    }
                    return Err(open_error(error));
                }
            };
        let thread = response
            .pointer("/thread/id")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                OpenError::Driver(DriverError::Protocol(format!(
                    "{method} response has no thread id"
                )))
            })?
            .to_owned();
        let settings = EffectiveSettings {
            model: text(response.get("model")).map(|model| DriverSettingOption {
                value: model.clone(),
                label: model,
                description: None,
                disabled: false,
            }),
            effort: text(response.get("reasoningEffort")),
            speed: text(response.get("serviceTier")),
            permission_mode: text(response.pointer("/activePermissionProfile/id")),
            mode: None,
            folder: text(response.get("cwd")).map(PathBuf::from),
        };
        let inner = match early {
            Some(inner) if inner.thread == thread => inner,
            _ => {
                let inner = SessionInner::new(&connection, thread.clone())?;
                connection
                    .sessions
                    .lock()
                    .expect("session map poisoned")
                    .insert(thread, Arc::downgrade(&inner));
                inner
            }
        };
        *inner.model.lock().expect("model poisoned") =
            settings.model.as_ref().map(|model| model.value.clone());
        *inner.effort.lock().expect("effort poisoned") = settings.effort.clone();
        inner.hub.emit(Event::Settings {
            effective: settings,
        });
        // The initial state comes from the thread's own turns: a resumed
        // thread may already be running one.
        inner.restore_open_snapshot(&response, response_sequence);
        inner.finish_open(response_sequence);
        let session: Arc<dyn Session> = Arc::new(CodexSession { inner, connection });
        Ok(session)
    }

    fn set_health(&self, health: RuntimeHealth) {
        self.info.lock().expect("runtime info poisoned").health = health;
    }

    /// Connects, revalidating the executable and rebuilding the manifest.
    async fn connection(&self) -> Result<Arc<Connection>, OpenError> {
        let mut slot = self.connection.lock().await;
        if let Some(connection) = slot.as_ref()
            && !connection.closed()
        {
            return Ok(connection.clone());
        }
        let connection = self.connect().await?;
        *slot = Some(connection.clone());
        Ok(connection)
    }

    async fn connect(&self) -> Result<Arc<Connection>, OpenError> {
        let executable = self.config.launch.executable.clone();
        let display = executable.display().to_string();
        if !executable.is_file() {
            let reason = SetupReason::ExecutableMissing { path: display };
            self.set_health(RuntimeHealth::NeedsSetup {
                reason: reason.clone(),
            });
            return Err(OpenError::NeedsSetup(reason));
        }
        // Hashed in chunks off the async workers: the ChatGPT app's Codex is
        // hundreds of megabytes.
        let sha256 = {
            let executable = executable.clone();
            tokio::task::spawn_blocking(move || manifest::binary_sha256(&executable))
                .await
                .ok()
                .and_then(Result::ok)
        };
        if let (Some(pinned), Some(found)) = (&self.config.pinned_sha256, &sha256)
            && pinned != found
        {
            let reason = SetupReason::ExecutableChanged {
                path: display,
                detail: "the binary at this path changed since setup".to_owned(),
            };
            self.set_health(RuntimeHealth::NeedsSetup {
                reason: reason.clone(),
            });
            return Err(OpenError::NeedsSetup(reason));
        }

        let StdioProcess { peer, control, .. } =
            spawn_stdio_process(&self.config.launch, vec!["app-server".into()])
                .await
                .map_err(|error| OpenError::Driver(DriverError::Unavailable(error.to_string())))?;
        let incoming = peer.take_incoming().map_err(driver_error)?;
        let initialize = peer
            .request_with_timeout(
                "initialize",
                serde_json::to_value(crate::InitializeParams::inline(&self.config.bridge_version))
                    .expect("initialize params"),
                REQUEST_TIMEOUT,
            )
            .await;
        let initialize = match initialize {
            Ok(value) => value,
            Err(error) => {
                let _ = control.shutdown().await;
                return Err(driver_error(error));
            }
        };
        let version = initialize
            .get("userAgent")
            .and_then(Value::as_str)
            .and_then(app_server_version_from_user_agent);
        peer.notify("initialized", json!({}))
            .await
            .map_err(driver_error)?;

        // The schema is keyed by the binary and the version it reports; a
        // version below the floor is refused without one.
        let surface = match &sha256 {
            Some(sha256)
                if version
                    .as_ref()
                    .is_none_or(|version| version >= &manifest::CORE_FLOOR) =>
            {
                self.schema_surface(sha256, version.as_ref()).await
            }
            _ => None,
        };
        let manifest = manifest::build_manifest(version.as_ref(), sha256.clone(), surface.as_ref());
        let health = match &manifest.tier {
            CompatTier::Supported => RuntimeHealth::Ready,
            CompatTier::BelowFloor { min_version } => RuntimeHealth::NeedsSetup {
                reason: SetupReason::UpdateRuntime {
                    min_version: min_version.clone(),
                    found: version.as_ref().map(Version::to_string),
                },
            },
            CompatTier::NewerThanBridge { reason } => RuntimeHealth::NeedsSetup {
                reason: SetupReason::UpdateInline {
                    detail: reason.clone(),
                },
            },
        };
        {
            let mut info = self.info.lock().expect("runtime info poisoned");
            info.executable.version = version.as_ref().map(Version::to_string);
            info.executable.sha256 = sha256;
            info.health = health.clone();
            info.manifest = Some(manifest.clone());
        }
        if let RuntimeHealth::NeedsSetup { reason } = health {
            let _ = control.shutdown().await;
            return Err(OpenError::NeedsSetup(reason));
        }

        let connection = Arc::new(Connection {
            peer,
            control,
            sessions: StdMutex::new(HashMap::new()),
            availability: manifest.availability,
            epoch: connection_epoch(),
        });
        tokio::spawn(dispatch(
            Arc::downgrade(&connection),
            incoming,
            self.host_tools.clone(),
        ));
        Ok(connection)
    }

    /// Generates (or reads cached) protocol schema for this binary and version.
    async fn schema_surface(
        &self,
        sha256: &str,
        version: Option<&Version>,
    ) -> Option<SchemaSurface> {
        let dir = manifest::schema_cache_dir(&self.config.cache_root, sha256, version);
        if let Ok(surface) = manifest::read_schema_dir(&dir) {
            return Some(surface);
        }
        std::fs::create_dir_all(&dir).ok()?;
        let status = tokio::time::timeout(
            Duration::from_secs(30),
            tokio::process::Command::new(&self.config.launch.executable)
                .args([
                    "app-server",
                    "generate-json-schema",
                    "--experimental",
                    "--out",
                ])
                .arg(&dir)
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status(),
        )
        .await
        .ok()?
        .ok()?;
        if !status.success() {
            let _ = std::fs::remove_dir_all(&dir);
            return None;
        }
        manifest::read_schema_dir(&dir).ok()
    }

    fn dynamic_tools(&self) -> Option<Value> {
        let tools = self.host_tools.lock().expect("host tools poisoned");
        let configuration = tools.as_ref()?;
        let tools: Vec<Value> = configuration
            .specs
            .iter()
            .map(|tool| {
                json!({
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "inputSchema": tool.input_schema,
                    "deferLoading": false,
                })
            })
            .collect();
        // The tagged shape Codex 0.146+ accepts; it normalizes the older flat
        // `{name, namespace}` shape to exactly this.
        Some(json!([{
            "type": "namespace",
            "name": "inline",
            "description": "",
            "tools": tools,
        }]))
    }
}

/// Codex's projects as folders, each root under its project's name. An
/// app-server without `project/list` has none.
async fn project_folders(connection: &Connection) -> Vec<CatalogFolder> {
    let mut folders = Vec::new();
    let mut cursor: Option<String> = None;
    for _ in 0..PROJECT_MAX_PAGES {
        let Ok(page) = connection
            .request(Request {
                method: "project/list",
                params: json!({"cursor": cursor, "limit": 100}),
            })
            .await
        else {
            break;
        };
        let Ok(page) = serde_json::from_value::<crate::protocol::ProjectListResponse>(page) else {
            break;
        };
        folders.extend(page.data.into_iter().flat_map(project_roots));
        match page.next_cursor {
            Some(next) if !next.is_empty() && cursor.as_deref() != Some(next.as_str()) => {
                cursor = Some(next);
            }
            _ => break,
        }
    }
    folders
}

fn project_roots(project: crate::protocol::CodexProject) -> Vec<CatalogFolder> {
    let several = project.roots.len() > 1;
    project
        .roots
        .into_iter()
        .filter(|root| root.path.is_absolute())
        .map(|root| {
            let folder = root
                .path
                .file_name()
                .map(|name| name.to_string_lossy().into_owned());
            let label = match (project.name.trim(), folder) {
                ("", Some(folder)) => folder,
                (name, Some(folder)) if several => format!("{name} · {folder}"),
                ("", None) => root.path.display().to_string(),
                (name, _) => name.to_owned(),
            };
            CatalogFolder {
                path: root.path,
                label,
            }
        })
        .collect()
}

/// Enabled skills from a `skills/list` response, once each across its folders.
fn skill_options(response: &Value) -> Vec<DriverSettingOption> {
    let mut seen = std::collections::HashSet::new();
    response
        .get("data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.get("skills").and_then(Value::as_array))
        .flatten()
        .filter(|skill| skill.get("enabled").and_then(Value::as_bool) != Some(false))
        .filter_map(|skill| {
            let name = skill.get("name").and_then(Value::as_str)?;
            let interface = skill.get("interface");
            let text = |value: Option<&Value>| {
                value
                    .and_then(Value::as_str)
                    .filter(|text| !text.is_empty())
                    .map(str::to_owned)
            };
            seen.insert(name.to_owned()).then(|| DriverSettingOption {
                value: name.to_owned(),
                label: text(interface.and_then(|value| value.get("displayName")))
                    .unwrap_or_else(|| name.to_owned()),
                description: text(skill.get("description")),
                disabled: false,
            })
        })
        .collect()
}

impl HarnessDriver for CodexHarness {
    fn describe(&self) -> RuntimeInfo {
        self.info.lock().expect("runtime info poisoned").clone()
    }

    fn catalog<'a>(&'a self, scope: CatalogScope) -> DriverFuture<'a, Catalog> {
        Box::pin(async move {
            let connection = self.connection().await.map_err(open_to_driver)?;
            let mut catalog = Catalog::default();
            let models = connection
                .request(Request {
                    method: "model/list",
                    params: json!({"limit": 100, "includeHidden": false}),
                })
                .await
                .map_err(peer_to_driver)?;
            if let Ok(models) = serde_json::from_value::<crate::protocol::ModelListResponse>(models)
            {
                catalog.models = models
                    .data
                    .into_iter()
                    .filter(|model| !model.hidden)
                    .map(|model| DriverModelOption {
                        label: if model.display_name.is_empty() {
                            model.model.clone()
                        } else {
                            model.display_name
                        },
                        value: model.model,
                        description: (!model.description.is_empty()).then_some(model.description),
                        reasoning: model
                            .supported_reasoning_efforts
                            .into_iter()
                            .map(|effort| DriverSettingOption {
                                label: effort.reasoning_effort.clone(),
                                value: effort.reasoning_effort,
                                description: Some(effort.description),
                                disabled: false,
                            })
                            .collect(),
                        default_reasoning: (!model.default_reasoning_effort.is_empty())
                            .then_some(model.default_reasoning_effort),
                        is_default: model.is_default,
                    })
                    .collect();
            }
            if let Ok(profiles) = connection
                .request(Request {
                    method: "permissionProfile/list",
                    params: json!({"limit": 50, "cwd": scope.folder}),
                })
                .await
                && let Ok(profiles) = serde_json::from_value::<
                    crate::protocol::PermissionProfileListResponse,
                >(profiles)
            {
                catalog.permission_modes = profiles
                    .data
                    .into_iter()
                    .map(|profile| DriverSettingOption {
                        label: profile.id.clone(),
                        value: profile.id,
                        description: profile.description,
                        disabled: profile.allowed == Some(false),
                    })
                    .collect();
            }
            if let Ok(modes) = connection
                .request(Request {
                    method: "collaborationMode/list",
                    params: json!({}),
                })
                .await
            {
                catalog.modes = modes
                    .get("data")
                    .and_then(Value::as_array)
                    .map(|modes| {
                        modes
                            .iter()
                            .filter_map(|mode| {
                                let id = mode
                                    .get("mode")
                                    .and_then(Value::as_str)
                                    .or_else(|| mode.get("name").and_then(Value::as_str))?;
                                Some(CatalogMode {
                                    id: ModeId::new(id).ok()?,
                                    label: mode
                                        .get("name")
                                        .and_then(Value::as_str)
                                        .unwrap_or(id)
                                        .to_owned(),
                                    description: None,
                                })
                            })
                            .collect()
                    })
                    .unwrap_or_default();
            }
            if let Ok(skills) = connection
                .request(Request {
                    method: "skills/list",
                    params: json!({
                        "cwds": scope.folder.iter().collect::<Vec<_>>(),
                        "forceReload": true,
                    }),
                })
                .await
            {
                catalog.skills = skill_options(&skills);
            }
            catalog.folders = project_folders(&connection).await;
            if let Ok(usage) = connection
                .request(Request {
                    method: "account/rateLimits/read",
                    params: json!({}),
                })
                .await
            {
                catalog.usage = crate::protocol::normalize_usage_limits(&usage);
            }
            Ok(catalog)
        })
    }

    fn sessions<'a>(&'a self, query: SessionQuery) -> DriverFuture<'a, SessionPage> {
        Box::pin(async move {
            let connection = self.connection().await.map_err(open_to_driver)?;
            let mut params = json!({
                "limit": query.limit.unwrap_or(20).clamp(1, 100),
                "sortKey": "updated_at",
                "archived": query.archived,
            });
            if let Some(folder) = &query.folder {
                params["cwd"] = json!(folder);
            }
            if let Some(cursor) = &query.cursor {
                params["cursor"] = json!(cursor.as_str());
            }
            let response = connection
                .request(Request {
                    method: "thread/list",
                    params,
                })
                .await
                .map_err(peer_to_driver)?;
            let sessions = response
                .get("data")
                .and_then(Value::as_array)
                .map(|threads| {
                    threads
                        .iter()
                        .filter_map(|thread| {
                            Some(SessionSummary {
                                key: SessionKey {
                                    provider: ProviderId::new("codex").ok()?,
                                    session: ProviderSessionId::new(thread.get("id")?.as_str()?)
                                        .ok()?,
                                },
                                title: text(thread.get("name")),
                                preview: text(thread.get("preview")),
                                folder: text(thread.get("cwd")).map(PathBuf::from),
                                updated_at: thread.get("updatedAt").and_then(Value::as_i64),
                                held_by: None,
                                archived: query.archived,
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            Ok(SessionPage {
                sessions,
                next: text(response.get("nextCursor"))
                    .and_then(|cursor| SessionPageCursor::new(cursor).ok()),
            })
        })
    }

    fn session<'a>(
        &'a self,
        session: &'a ProviderSessionId,
    ) -> DriverFuture<'a, Option<SessionSummary>> {
        Box::pin(async move {
            let connection = self.connection().await.map_err(open_to_driver)?;
            let response = match connection
                .request(Request {
                    method: "thread/read",
                    params: json!({"threadId": session.as_str(), "includeTurns": false}),
                })
                .await
            {
                Ok(response) => response,
                Err(PeerError::Remote(error)) if is_missing_thread(&error) => return Ok(None),
                Err(error) => return Err(peer_to_driver(error)),
            };
            let Some(thread) = response.get("thread") else {
                return Ok(None);
            };
            Ok(Some(SessionSummary {
                key: SessionKey {
                    provider: ProviderId::new("codex")
                        .map_err(|error| DriverError::Protocol(error.to_string()))?,
                    session: session.clone(),
                },
                title: text(thread.get("name")),
                preview: text(thread.get("preview")),
                folder: text(thread.get("cwd")).map(PathBuf::from),
                updated_at: thread.get("updatedAt").and_then(Value::as_i64),
                held_by: None,
                archived: false,
            }))
        })
    }

    fn history<'a>(
        &'a self,
        session: &'a ProviderSessionId,
        _folder: Option<&'a std::path::Path>,
    ) -> DriverFuture<'a, Vec<inline_agent_bridge::harness::HistoryTurn>> {
        Box::pin(async move {
            /// Far beyond any real thread; it only stops a runaway cursor.
            const MAX_PAGES: usize = 400;
            let connection = self.connection().await.map_err(open_to_driver)?;
            let mut turns = Vec::new();
            let mut cursor: Option<String> = None;
            let mut seen = std::collections::HashSet::new();
            for page in 0..MAX_PAGES {
                let mut params = json!({
                    "threadId": session.as_str(),
                    "limit": 50,
                    "sortDirection": "asc",
                    "itemsView": "full",
                });
                if let Some(cursor) = &cursor {
                    params["cursor"] = json!(cursor);
                }
                let response = match connection
                    .request(Request {
                        method: "thread/turns/list",
                        params,
                    })
                    .await
                {
                    Ok(response) => response,
                    // An app-server without turn paging reads the thread whole.
                    Err(PeerError::Remote(error))
                        if page == 0 && matches!(error.code, Some(-32601)) =>
                    {
                        return read_whole_thread(&connection, session).await;
                    }
                    Err(PeerError::Remote(error)) if is_missing_thread(&error) => {
                        return Err(DriverError::InvalidSession(error.message));
                    }
                    Err(error) => return Err(peer_to_driver(error)),
                };
                turns.extend(
                    response
                        .get("data")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                        .filter_map(super::history::turn),
                );
                match text(response.get("nextCursor")) {
                    Some(next) if seen.insert(next.clone()) => cursor = Some(next),
                    Some(_) => {
                        return Err(DriverError::Protocol(
                            "Codex repeated a turn page cursor".to_owned(),
                        ));
                    }
                    None => return Ok(turns),
                }
            }
            Err(DriverError::Protocol(
                "Codex thread history did not end".to_owned(),
            ))
        })
    }

    fn open<'a>(&'a self, spec: OpenSpec) -> HarnessFuture<'a, Arc<dyn Session>, OpenError> {
        Box::pin(async move {
            // Unsubscribe can enter Codex's native shutdown just as the next
            // message arrives. Only its explicit "closing" refusal is safe
            // to retry: no resume or input was accepted. Every attempt gets
            // a fresh early listener, since thread/closed ends the old one.
            let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
            let mut delay = Duration::from_millis(100);
            loop {
                let result = self.open_once(&spec).await;
                if !resume_is_closing(&spec.mode, &result)
                    || tokio::time::Instant::now() + delay > deadline
                {
                    return result;
                }
                tokio::time::sleep(delay).await;
                delay = (delay * 2).min(Duration::from_secs(1));
            }
        })
    }
}

fn resume_is_closing<T>(mode: &OpenMode, result: &Result<T, OpenError>) -> bool {
    let (OpenMode::Resume { session }, Err(OpenError::Driver(DriverError::Rejected(message)))) =
        (mode, result)
    else {
        return false;
    };
    message
        == &format!("thread {session} is closing; retry thread/resume after the thread is closed")
}

/// The running and latest finished turn a `thread/*` response reports.
fn thread_turns(response: &Value) -> (Option<TurnId>, Option<TurnId>) {
    let mut active = None;
    let mut finished = None;
    for turn in response
        .pointer("/thread/turns")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(id) = turn
            .get("id")
            .and_then(Value::as_str)
            .and_then(|id| TurnId::new(id).ok())
        else {
            continue;
        };
        match turn.get("status").and_then(Value::as_str) {
            Some("inProgress") => active = Some(id),
            Some("completed" | "interrupted" | "failed") => finished = Some(id),
            _ => {}
        }
    }
    (active, finished)
}

struct SessionInner {
    key: SessionKey,
    thread: String,
    hub: EventHub,
    mapper: StdMutex<CodexMapper>,
    turn_sequence: AtomicU64,
    open_boundary: StdMutex<OpenBoundary>,
    model: StdMutex<Option<String>>,
    /// The thread's reasoning effort, from its latest settings (`None`: the
    /// model's default).
    effort: StdMutex<Option<String>>,
    queue: StdMutex<Vec<QueuedInput>>,
    /// Background terminals still running, from `thread/backgroundTerminals/list`.
    terminals: StdMutex<Vec<inline_agent_bridge::harness::ChildRef>>,
    connection: Weak<Connection>,
}

#[derive(Default)]
struct OpenBoundary {
    response: Option<u64>,
    closed: Option<u64>,
}

impl SessionInner {
    fn new(connection: &Arc<Connection>, thread: String) -> Result<Arc<Self>, OpenError> {
        let key = SessionKey {
            provider: ProviderId::new("codex").expect("provider id"),
            session: ProviderSessionId::new(thread.clone())
                .map_err(|error| OpenError::Driver(DriverError::Protocol(error.to_string())))?,
        };
        Ok(Arc::new(Self {
            hub: EventHub::new(key.clone(), DEFAULT_HUB_CAPACITY),
            key,
            mapper: StdMutex::new(CodexMapper::for_connection(
                thread.clone(),
                connection.epoch.clone(),
            )),
            turn_sequence: AtomicU64::new(0),
            open_boundary: StdMutex::new(OpenBoundary::default()),
            thread,
            model: StdMutex::new(None),
            effort: StdMutex::new(None),
            queue: StdMutex::new(Vec::new()),
            terminals: StdMutex::new(Vec::new()),
            connection: Arc::downgrade(connection),
        }))
    }

    fn restore_open_snapshot(&self, response: &Value, response_sequence: u64) {
        let (active, finished) = thread_turns(response);
        let mut mapper = self.mapper.lock().expect("mapper poisoned");
        // Snapshot restoration and notification versions share the mapper
        // lock, so a completion newer than the response cannot be undone.
        if self.turn_sequence.load(Ordering::Acquire) <= response_sequence {
            mapper.restore_turns(active, finished);
        }
        for event in mapper.restore_inputs(response) {
            self.hub.emit(event);
        }
        self.hub.emit(Event::State {
            state: if mapper.active_turn().is_some() {
                RunState::Working
            } else {
                RunState::Idle
            },
        });
    }

    fn defer_close(&self, sequence: u64) -> bool {
        let mut boundary = self.open_boundary.lock().expect("open boundary poisoned");
        if let Some(response) = boundary.response {
            return sequence <= response;
        }
        boundary.closed = Some(sequence);
        true
    }

    fn finish_open(&self, sequence: u64) {
        let closed = {
            let mut boundary = self.open_boundary.lock().expect("open boundary poisoned");
            boundary.response = Some(sequence);
            boundary
                .closed
                .take()
                .is_some_and(|closed| closed > sequence)
        };
        if closed {
            self.emit_all(vec![Event::State {
                state: RunState::Released,
            }]);
        }
    }

    fn emit_all(&self, events: Vec<Event>) {
        for event in events {
            if let Event::Settings { effective } = &event {
                if let Some(model) = &effective.model {
                    *self.model.lock().expect("model poisoned") = Some(model.value.clone());
                }
                // Each settings event is the whole thread's: no effort is
                // the model's default.
                *self.effort.lock().expect("effort poisoned") = effective.effort.clone();
            }
            if let Event::Queue { entries } = &event {
                *self.queue.lock().expect("queue poisoned") = entries.clone();
            }
            let released = matches!(
                event,
                Event::State {
                    state: RunState::Released
                }
            );
            self.hub.emit(event);
            // Stop routing only once Codex confirms the thread unloaded.
            if released && let Some(connection) = self.connection.upgrade() {
                connection.remove_session(self);
            }
        }
    }

    /// Predicts the user's next message after `turn`, like the Codex app's
    /// composer predictions. Silent when the app-server has no
    /// `thread/sample`, the sample fails, or a newer turn started meanwhile.
    async fn suggest_prompt(self: &Arc<Self>, turn: TurnId) {
        let Some(connection) = self.connection.upgrade() else {
            return;
        };
        if !connection
            .availability
            .op(inline_agent_bridge::harness::OpKind::Sample)
            .is_supported()
        {
            return;
        }
        let Ok(response) = connection
            .request(super::suggestion::request(&self.thread, &turn))
            .await
        else {
            return;
        };
        let Some(text) = super::suggestion::parse(&response) else {
            return;
        };
        let current = {
            let mapper = self.mapper.lock().expect("mapper poisoned");
            mapper.active_turn().is_none() && mapper.last_finished_turn() == Some(&turn)
        };
        if current {
            self.emit_all(vec![Event::PromptSuggestion {
                turn: Some(turn),
                text,
            }]);
        }
    }

    /// Lists the thread's running background terminals and reports the ones
    /// that started or ended as child updates.
    async fn refresh_terminals(self: &Arc<Self>) {
        use inline_agent_bridge::harness::{
            ChildId, ChildKind, ChildRef, ChildStatus, ChildUpdate,
        };
        let Some(connection) = self.connection.upgrade() else {
            return;
        };
        let mut running = Vec::new();
        let mut cursor: Option<String> = None;
        for _ in 0..QUEUE_MAX_PAGES {
            let mut params = json!({"threadId": self.thread, "limit": QUEUE_PAGE_SIZE});
            if let Some(cursor) = &cursor {
                params["cursor"] = json!(cursor);
            }
            let Ok(response) = connection
                .request(Request {
                    method: "thread/backgroundTerminals/list",
                    params,
                })
                .await
            else {
                // Older Codex or a failed read: keep what is known.
                return;
            };
            for terminal in response
                .get("data")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                let Some(id) = terminal
                    .get("processId")
                    .and_then(Value::as_str)
                    .and_then(|id| ChildId::new(id).ok())
                else {
                    continue;
                };
                running.push((
                    ChildRef {
                        id,
                        kind: ChildKind::BackgroundTask,
                    },
                    terminal
                        .get("command")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                    terminal.clone(),
                ));
            }
            cursor = response
                .get("nextCursor")
                .and_then(Value::as_str)
                .map(str::to_owned);
            if cursor.is_none() {
                break;
            }
        }
        let previous = std::mem::replace(
            &mut *self.terminals.lock().expect("terminals poisoned"),
            running.iter().map(|(child, _, _)| child.clone()).collect(),
        );
        let mut events = Vec::new();
        for (child, title, native) in &running {
            if !previous.contains(child) {
                events.push(Event::Child {
                    update: ChildUpdate {
                        child: child.clone(),
                        status: ChildStatus::Running,
                        title: title.clone(),
                        accepts_direct_input: false,
                        native: native.clone(),
                    },
                });
            }
        }
        for child in previous {
            if !running.iter().any(|(running, _, _)| *running == child) {
                events.push(Event::Child {
                    update: ChildUpdate {
                        child,
                        status: ChildStatus::Completed,
                        title: None,
                        accepts_direct_input: false,
                        native: Value::Null,
                    },
                });
            }
        }
        self.emit_all(events);
    }

    /// Lists the whole native queue, every page, and publishes it.
    async fn refresh_queue(self: &Arc<Self>) -> Result<Vec<QueuedInput>, PeerError> {
        let Some(connection) = self.connection.upgrade() else {
            return Err(PeerError::Closed);
        };
        let mut entries = Vec::new();
        let mut cursor: Option<String> = None;
        for _ in 0..QUEUE_MAX_PAGES {
            let mut params = json!({"threadId": self.thread, "limit": QUEUE_PAGE_SIZE});
            if let Some(cursor) = &cursor {
                params["cursor"] = json!(cursor);
            }
            let response = connection
                .request(Request {
                    method: "thread/queue/list",
                    params,
                })
                .await?;
            entries.extend(
                response
                    .get("data")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|entry| {
                        let preview: String = entry
                            .get("input")
                            .and_then(Value::as_array)
                            .map(|parts| {
                                parts
                                    .iter()
                                    .filter_map(|part| part.get("text").and_then(Value::as_str))
                                    .collect::<Vec<_>>()
                                    .join(" ")
                            })
                            .unwrap_or_default()
                            .chars()
                            .take(QUEUE_PREVIEW_CHARS)
                            .collect();
                        Some(QueuedInput {
                            entry: QueueEntryId::new(entry.get("id")?.as_str()?).ok()?,
                            input: entry
                                .get("clientUserMessageId")
                                .and_then(Value::as_str)
                                .and_then(|id| {
                                    id.strip_prefix(super::mapper::CLIENT_MESSAGE_PREFIX)
                                })
                                .and_then(|id| inline_agent_bridge::harness::InputId::new(id).ok()),
                            preview,
                        })
                    }),
            );
            cursor = response
                .get("nextCursor")
                .and_then(Value::as_str)
                .map(str::to_owned);
            if cursor.is_none() {
                self.emit_all(vec![Event::Queue {
                    entries: entries.clone(),
                }]);
                return Ok(entries);
            }
        }
        Err(PeerError::InvalidMessage(
            "the Codex queue has more pages than this bridge reads".to_owned(),
        ))
    }
}

/// Routes every incoming message to the sessions that own its thread.
async fn dispatch(
    connection: Weak<Connection>,
    mut incoming: tokio::sync::mpsc::Receiver<IncomingMessage>,
    host_tools: Arc<StdMutex<Option<HostToolConfiguration>>>,
) {
    while let Some(message) = incoming.recv().await {
        let Some(connection) = connection.upgrade() else {
            return;
        };
        let sessions: Vec<Arc<SessionInner>> = connection
            .sessions
            .lock()
            .expect("session map poisoned")
            .values()
            .filter_map(Weak::upgrade)
            .collect();
        match message {
            IncomingMessage::Notification {
                method,
                params,
                wire_sequence,
            } => {
                for session in &sessions {
                    if method == "thread/closed"
                        && params.get("threadId").and_then(Value::as_str)
                            == Some(session.thread.as_str())
                        && session.defer_close(wire_sequence)
                    {
                        continue;
                    }
                    let mapped = {
                        let mut mapper = session.mapper.lock().expect("mapper poisoned");
                        let mapped = mapper.notification(&method, &params);
                        if mapped
                            .events
                            .iter()
                            .any(|event| matches!(event, Event::Turn { .. }))
                        {
                            session
                                .turn_sequence
                                .store(wire_sequence, Ordering::Release);
                        }
                        mapped
                    };
                    let follow = super::suggestion::turn_to_follow(&mapped.events);
                    session.emit_all(mapped.events);
                    if let Some(turn) = follow {
                        let session = session.clone();
                        tokio::spawn(async move { session.suggest_prompt(turn).await });
                    }
                    if mapped.refresh_queue {
                        let session = session.clone();
                        tokio::spawn(async move {
                            let _ = session.refresh_queue().await;
                        });
                    }
                    // Background terminals can outlive the turn that started
                    // them; list them so live work and release see them.
                    if method == "turn/completed"
                        && params.get("threadId").and_then(Value::as_str)
                            == Some(session.thread.as_str())
                    {
                        let session = session.clone();
                        tokio::spawn(async move { session.refresh_terminals().await });
                    }
                }
            }
            IncomingMessage::ServerRequest {
                id, method, params, ..
            } => {
                let mut handled = false;
                for session in &sessions {
                    let mapped = session
                        .mapper
                        .lock()
                        .expect("mapper poisoned")
                        .server_request(&id, &method, &params);
                    match mapped {
                        RequestMapped::NotMine => continue,
                        RequestMapped::Interaction(events) => session.emit_all(events),
                        RequestMapped::Reply { result, events } => {
                            session.emit_all(events);
                            let _ = match result {
                                Ok(result) => connection.peer.respond(id.clone(), result).await,
                                Err((code, message)) => {
                                    connection
                                        .peer
                                        .respond_error(id.clone(), code, &message)
                                        .await
                                }
                            };
                        }
                        RequestMapped::HostTool => {
                            let configuration =
                                host_tools.lock().expect("host tools poisoned").clone();
                            let peer = connection.peer.clone();
                            let (id, params) = (id.clone(), params.clone());
                            tokio::spawn(async move {
                                let result = match configuration {
                                    Some(configuration) => {
                                        crate::driver::execute_host_tool_call(
                                            configuration,
                                            &params,
                                        )
                                        .await
                                    }
                                    None => inline_agent_bridge::HostToolResult::failure(
                                        "Inline tools are unavailable for this session.",
                                    ),
                                };
                                let _ = peer
                                    .respond(
                                        id,
                                        json!({
                                            "contentItems": [{"type": "inputText", "text": result.content}],
                                            "success": result.success,
                                        }),
                                    )
                                    .await;
                            });
                        }
                    }
                    handled = true;
                    break;
                }
                if !handled {
                    let reply = match method.as_str() {
                        "currentTime/read" => {
                            let now = std::time::SystemTime::now()
                                .duration_since(std::time::UNIX_EPOCH)
                                .map_or(0, |elapsed| elapsed.as_secs());
                            connection
                                .peer
                                .respond(id, json!({"currentTime": now}))
                                .await
                        }
                        _ => {
                            // Codex reads the error as a refusal. A request from a
                            // thread no session knows (a sub-agent Inline has not
                            // seen yet) says so where the work is, when there is
                            // one place it can be.
                            if let [session] = sessions.as_slice()
                                && let Some(notice) =
                                    super::mapper::unowned_request_notice(&method, &params)
                            {
                                session.emit_all(vec![notice]);
                            }
                            connection
                                .peer
                                .respond_error(id, -32601, "not supported by Inline")
                                .await
                        }
                    };
                    let _ = reply;
                }
            }
        }
    }
    // The connection ended (the process exited or the peer closed): every
    // pending interaction is gone with it, and a running turn can no longer
    // finish, so it completes as `ConnectionLost` instead of staying working.
    if let Some(connection) = connection.upgrade() {
        log::warn!(
            target: "inline_agent_driver_codex::harness",
            "phase=connection_lost process_exited={}",
            connection.control.is_finished()
        );
        let sessions: Vec<Arc<SessionInner>> = connection
            .sessions
            .lock()
            .expect("session map poisoned")
            .values()
            .filter_map(Weak::upgrade)
            .collect();
        for session in sessions {
            let events = session
                .mapper
                .lock()
                .expect("mapper poisoned")
                .connection_lost();
            session.emit_all(events);
            session.emit_all(vec![Event::State {
                state: RunState::Unknown,
            }]);
        }
        // A peer that failed closed leaves a live process nobody can talk to.
        if !connection.control.is_finished() {
            let _ = connection.control.shutdown().await;
        }
    }
}

/// One Codex thread held by this bridge.
pub struct CodexSession {
    inner: Arc<SessionInner>,
    connection: Arc<Connection>,
}

impl Session for CodexSession {
    fn key(&self) -> &SessionKey {
        &self.inner.key
    }

    fn availability(&self) -> AvailabilityMatrix {
        self.connection.availability.clone()
    }

    fn events(&self) -> EventStream {
        self.inner.hub.subscribe()
    }

    fn send<'a>(&'a self, input: Input) -> HarnessFuture<'a, InputReceipt, SendError> {
        Box::pin(async move {
            let availability = self.connection.availability.delivery(input.delivery.kind());
            if !availability.is_supported() {
                return Err(SendError::Unavailable(availability));
            }
            let active = self
                .inner
                .mapper
                .lock()
                .expect("mapper poisoned")
                .active_turn()
                .cloned();
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
            let (note, request) = input_request(&self.inner.thread, &input);
            if let Some(note) = note {
                self.connection.request(note).await.map_err(send_error)?;
            }
            let response = match self.connection.request_with_error_data(request).await {
                Ok(response) => response,
                Err(refused) => return self.refused(input, active, refused).await,
            };
            let disposition = match &input.delivery {
                Delivery::Turn => {
                    let turn = response
                        .pointer("/turn/id")
                        .and_then(Value::as_str)
                        .and_then(|turn| TurnId::new(turn).ok())
                        .ok_or_else(|| {
                            SendError::Unknown("turn/start returned no turn id".to_owned())
                        })?;
                    let lost = self
                        .inner
                        .mapper
                        .lock()
                        .expect("mapper poisoned")
                        .turn_started_by_request(turn.clone());
                    self.inner.emit_all(lost);
                    InputDisposition::Started { turn }
                }
                Delivery::Steer { expected_turn, .. } => InputDisposition::Steered {
                    turn: response
                        .get("turnId")
                        .and_then(Value::as_str)
                        .and_then(|turn| TurnId::new(turn).ok())
                        .unwrap_or_else(|| expected_turn.clone()),
                },
                Delivery::Queue => InputDisposition::Queued {
                    entry: response
                        .pointer("/queuedSubmission/id")
                        .and_then(Value::as_str)
                        .and_then(|id| QueueEntryId::new(id).ok()),
                },
                Delivery::Passive => InputDisposition::Absorbed,
            };
            Ok(InputReceipt {
                input: input.id,
                disposition,
                native: response,
                acceptance: inline_agent_bridge::harness::Acceptance::Accepted,
            })
        })
    }

    fn control<'a>(&'a self, op: Op) -> HarnessFuture<'a, OpOutcome, OpError> {
        Box::pin(async move {
            let availability = self.connection.availability.op(op.kind());
            if !availability.is_supported() {
                return Err(OpError::Unavailable(availability));
            }
            if let Op::Answer {
                interaction,
                response,
                by,
            } = &op
            {
                let plan = self.inner.mapper.lock().expect("mapper poisoned").answer(
                    interaction,
                    response,
                    *by,
                )?;
                return match plan {
                    AnswerPlan::Respond {
                        rpc_id,
                        result,
                        events,
                        follow_up,
                    } => {
                        self.connection
                            .peer
                            .respond(rpc_id, result)
                            .await
                            .map_err(op_error)?;
                        self.inner.emit_all(events);
                        Ok(OpOutcome::Accepted {
                            native: follow_up
                                .map_or(Value::Null, |text| json!({"follow_up": text})),
                        })
                    }
                    AnswerPlan::SendInput { text, events } => {
                        self.inner.emit_all(events);
                        Ok(OpOutcome::Accepted {
                            native: if text.is_empty() {
                                Value::Null
                            } else {
                                json!({"follow_up": text})
                            },
                        })
                    }
                };
            }
            if let Op::Queue {
                action: action @ (QueueOp::Reorder { .. } | QueueOp::Clear),
            } = &op
            {
                return self.edit_queue(action).await;
            }
            let (active, last_finished) = {
                let mapper = self.inner.mapper.lock().expect("mapper poisoned");
                (
                    mapper.active_turn().cloned(),
                    mapper.last_finished_turn().cloned(),
                )
            };
            let model = self.inner.model.lock().expect("model poisoned").clone();
            let effort = self.inner.effort.lock().expect("effort poisoned").clone();
            let request = op_request(
                &self.inner.thread,
                TurnFacts {
                    active: active.as_ref(),
                    last_finished: last_finished.as_ref(),
                },
                model.as_deref(),
                effort.as_deref(),
                &op,
            )?;
            let response = self.connection.request(request).await.map_err(op_error)?;
            // `deleted: false`: the entry ran or was taken before the delete.
            if let Op::Queue {
                action: QueueOp::Remove { .. },
            } = op
                && response.get("deleted").and_then(Value::as_bool) == Some(false)
            {
                return Err(OpError::NotQueued);
            }
            if matches!(op, Op::Compact | Op::Review { .. })
                && let Some(turn) = response
                    .pointer("/turn/id")
                    .and_then(Value::as_str)
                    .and_then(|turn| TurnId::new(turn).ok())
            {
                return Ok(OpOutcome::TurnStarted { turn });
            }
            if let Op::Sample { .. } = op
                && let Some(text) = response.get("text").and_then(Value::as_str)
            {
                return Ok(OpOutcome::Sampled {
                    text: text.to_owned(),
                });
            }
            Ok(OpOutcome::Accepted { native: response })
        })
    }

    fn live_work(&self) -> LiveWork {
        let mapper = self.inner.mapper.lock().expect("mapper poisoned");
        LiveWork {
            turn: mapper.active_turn().cloned(),
            children: mapper
                .children()
                .into_iter()
                .chain(
                    self.inner
                        .terminals
                        .lock()
                        .expect("terminals poisoned")
                        .iter()
                        .cloned(),
                )
                .collect(),
            interactions: mapper.pending_interactions(),
            queued: self.inner.queue.lock().expect("queue poisoned").clone(),
            wakeups: Vec::new(),
        }
    }

    fn release<'a>(&'a self) -> HarnessFuture<'a, Released, OpError> {
        Box::pin(async move {
            self.connection
                .request(Request {
                    method: "thread/unsubscribe",
                    params: json!({"threadId": self.inner.thread}),
                })
                .await
                .map_err(op_error)?;
            let events = self
                .inner
                .mapper
                .lock()
                .expect("mapper poisoned")
                .cancel_all();
            let cancelled = events
                .iter()
                .filter_map(|event| match event {
                    Event::InteractionClosed { id, .. } => Some(id.clone()),
                    _ => None,
                })
                .collect();
            self.inner.emit_all(events);
            // The thread stays loaded through Codex's grace period; the stream
            // reports `Released` when `thread/closed` arrives.
            self.inner.emit_all(vec![Event::State {
                state: RunState::Releasing,
            }]);
            Ok(Released {
                key: self.inner.key.clone(),
                outcome: ReleaseOutcome::Unsubscribed,
                cancelled_interactions: cancelled,
                // Codex keeps its own queue across unload; nothing is held by Inline.
                pending_inputs: Vec::new(),
                stopped_children: Vec::<ChildRef>::new(),
            })
        })
    }
}

impl CodexSession {
    /// A refused delivery. Codex's answer to a steer is newer than the
    /// notifications still being mapped, so the running turn follows it, and
    /// the bridge retries: a new turn when none runs, a steer into the one
    /// that does. A review or compaction takes no steering: the input waits
    /// in Codex's queue and runs when it ends, as the Codex TUI queues it.
    async fn refused(
        &self,
        input: Input,
        active: Option<TurnId>,
        refused: RoutedError,
    ) -> Result<InputReceipt, SendError> {
        let refusal = steer_refusal(&refused);
        match (refusal, &input.delivery) {
            (Some(SteerRefusal::NotSteerable), Delivery::Turn | Delivery::Steer { .. }) => {
                let active = match &input.delivery {
                    Delivery::Steer { expected_turn, .. } => Some(expected_turn.clone()),
                    _ => active,
                };
                self.queue_behind_turn(input, active, refused.error).await
            }
            (Some(SteerRefusal::NoActiveTurn), Delivery::Steer { expected_turn, .. }) => {
                self.inner
                    .mapper
                    .lock()
                    .expect("mapper poisoned")
                    .steer_refused(expected_turn, None);
                Err(SendError::TurnMismatch { active: None })
            }
            (Some(SteerRefusal::OtherTurn(running)), Delivery::Steer { expected_turn, .. }) => {
                self.inner
                    .mapper
                    .lock()
                    .expect("mapper poisoned")
                    .steer_refused(expected_turn, running.clone());
                Err(SendError::TurnMismatch { active: running })
            }
            _ => Err(send_error(refused.error)),
        }
    }

    /// Puts input Codex could not take into the running turn in its native
    /// queue. Without one, the input is refused as busy behind that turn.
    async fn queue_behind_turn(
        &self,
        input: Input,
        active: Option<TurnId>,
        error: PeerError,
    ) -> Result<InputReceipt, SendError> {
        if !self
            .connection
            .availability
            .delivery(inline_agent_bridge::harness::DeliveryKind::Queue)
            .is_supported()
        {
            return Err(match active {
                Some(active) => SendError::Busy { active },
                None => send_error(error),
            });
        }
        let queued = Input {
            delivery: Delivery::Queue,
            ..input
        };
        let (note, request) = input_request(&self.inner.thread, &queued);
        if let Some(note) = note {
            self.connection.request(note).await.map_err(send_error)?;
        }
        let response = self.connection.request(request).await.map_err(send_error)?;
        Ok(InputReceipt {
            input: queued.id,
            disposition: InputDisposition::Queued {
                entry: response
                    .pointer("/queuedSubmission/id")
                    .and_then(Value::as_str)
                    .and_then(|id| QueueEntryId::new(id).ok()),
            },
            native: response,
            acceptance: inline_agent_bridge::harness::Acceptance::Accepted,
        })
    }

    async fn edit_queue(&self, action: &QueueOp) -> Result<OpOutcome, OpError> {
        let entries = self.inner.refresh_queue().await.map_err(op_error)?;
        match action {
            QueueOp::Clear => {
                for entry in &entries {
                    self.connection
                        .request(Request {
                            method: "thread/queue/delete",
                            params: json!({"threadId": self.inner.thread, "queuedSubmissionId": entry.entry.as_str()}),
                        })
                        .await
                        .map_err(op_error)?;
                }
                // Only the entries listed are deleted; input that arrived since
                // stays queued. Confirm none of the listed ones remain.
                let remaining = self.inner.refresh_queue().await.map_err(op_error)?;
                if remaining
                    .iter()
                    .any(|queued| entries.iter().any(|entry| entry.entry == queued.entry))
                {
                    return Err(OpError::Rejected(
                        "Codex kept some queued input after clearing".to_owned(),
                    ));
                }
            }
            QueueOp::Reorder { entry, position } => {
                let mut ids: Vec<String> = entries
                    .iter()
                    .map(|queued| queued.entry.as_str().to_owned())
                    .filter(|id| id != entry.as_str())
                    .collect();
                let position = (*position as usize).min(ids.len());
                ids.insert(position, entry.as_str().to_owned());
                self.connection
                    .request(Request {
                        method: "thread/queue/reorder",
                        params: json!({"threadId": self.inner.thread, "queuedSubmissionIds": ids}),
                    })
                    .await
                    .map_err(op_error)?;
            }
            _ => {}
        }
        Ok(OpOutcome::accepted())
    }
}

fn text(value: Option<&Value>) -> Option<String> {
    value?
        .as_str()
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

fn driver_error(error: PeerError) -> OpenError {
    OpenError::Driver(peer_to_driver(error))
}

/// Codex's refusal for a thread id it does not have.
fn is_missing_thread(error: &crate::peer::RemoteError) -> bool {
    let message = error.message.to_ascii_lowercase();
    message.contains("not found")
        || message.contains("no rollout")
        || message.contains("invalid thread")
}

async fn read_whole_thread(
    connection: &Connection,
    session: &ProviderSessionId,
) -> Result<Vec<inline_agent_bridge::harness::HistoryTurn>, DriverError> {
    let response = connection
        .request(Request {
            method: "thread/read",
            params: json!({"threadId": session.as_str(), "includeTurns": true}),
        })
        .await
        .map_err(|error| match error {
            PeerError::Remote(error) if is_missing_thread(&error) => {
                DriverError::InvalidSession(error.message)
            }
            other => peer_to_driver(other),
        })?;
    Ok(response
        .get("thread")
        .and_then(|thread| thread.get("turns"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(super::history::turn)
        .collect())
}

fn peer_to_driver(error: PeerError) -> DriverError {
    match error {
        PeerError::Remote(remote) => DriverError::Rejected(remote.message),
        PeerError::Closed => DriverError::ProcessExited("Codex app-server closed".to_owned()),
        PeerError::Timeout(method) => DriverError::Transient(format!("{method} timed out")),
        other => DriverError::Protocol(other.to_string()),
    }
}

fn open_to_driver(error: OpenError) -> DriverError {
    match error {
        OpenError::Driver(error) => error,
        other => DriverError::Unavailable(other.to_string()),
    }
}

fn open_error(error: PeerError) -> OpenError {
    if let PeerError::Remote(remote) = &error {
        let message = remote.message.to_ascii_lowercase();
        if message.contains("conflict") || message.contains("live local writer") {
            return OpenError::HeldElsewhere(inline_agent_bridge::harness::HeldBy {
                surface: inline_agent_bridge::harness::HeldSurface::Unknown,
                detail: Some(remote.message.clone()),
            });
        }
        if message.contains("not found") || message.contains("no rollout") {
            return OpenError::NotFound;
        }
    }
    OpenError::Driver(peer_to_driver(error))
}

/// A random id for one app-server process (see [`Connection::epoch`]).
fn connection_epoch() -> String {
    uuid::Uuid::new_v4().simple().to_string()[..8].to_owned()
}

/// Why Codex refused a steer (or the steer half of `turn/start`), when the
/// bridge can do better than report it.
#[derive(Debug, PartialEq)]
enum SteerRefusal {
    /// The turn ended, or is ending, before the steer reached it.
    NoActiveTurn,
    /// Another turn runs (the one Codex named, when it did).
    OtherTurn(Option<TurnId>),
    /// A review or compaction runs; it takes no steering.
    NotSteerable,
}

/// Reads a refusal: `codexErrorInfo` in the error's data first, then Codex's
/// messages (`turn_processor.rs`), which older versions send alone.
fn steer_refusal(refused: &RoutedError) -> Option<SteerRefusal> {
    let PeerError::Remote(remote) = &refused.error else {
        return None;
    };
    let info = refused
        .data
        .as_ref()
        .and_then(|data| data.get("codexErrorInfo"))
        .and_then(|info| {
            info.as_str()
                .or_else(|| info.as_object()?.keys().next().map(String::as_str))
        });
    if info == Some("activeTurnNotSteerable") {
        return Some(SteerRefusal::NotSteerable);
    }
    let message = remote.message.to_ascii_lowercase();
    // "cannot steer a review turn" / "cannot steer a compact turn"; a
    // refused `turn/start` reports `ActiveTurnNotSteerable { .. }` in text.
    if message.starts_with("cannot steer a ") || message.contains("activeturnnotsteerable") {
        return Some(SteerRefusal::NotSteerable);
    }
    if message.contains("no active turn to steer") {
        return Some(SteerRefusal::NoActiveTurn);
    }
    // "expected active turn id `x` but found `y`"
    if message.contains("expected") && message.contains("turn") {
        let running = remote
            .message
            .split("but found `")
            .nth(1)
            .and_then(|rest| rest.split('`').next())
            .and_then(|turn| TurnId::new(turn).ok());
        return Some(SteerRefusal::OtherTurn(running));
    }
    None
}

/// A request lost in flight may or may not have been applied: never retried.
fn send_error(error: PeerError) -> SendError {
    match error {
        PeerError::Remote(remote) => {
            let message = remote.message.to_ascii_lowercase();
            if message.contains("expected") && message.contains("turn") {
                SendError::TurnMismatch { active: None }
            } else {
                SendError::Rejected(remote.message)
            }
        }
        PeerError::Closed | PeerError::Timeout(_) | PeerError::Io(_) => {
            SendError::Unknown(error.to_string())
        }
        other => SendError::Driver(peer_to_driver(other)),
    }
}

fn op_error(error: PeerError) -> OpError {
    match error {
        PeerError::Remote(remote) => OpError::Rejected(remote.message),
        PeerError::Closed | PeerError::Timeout(_) | PeerError::Io(_) => {
            OpError::Unknown(error.to_string())
        }
        other => OpError::Driver(peer_to_driver(other)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use inline_agent_bridge::TurnOutcome;

    #[cfg(unix)]
    fn scripted_harness(closing: bool) -> (tempfile::TempDir, CodexHarness) {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let executable = dir.path().join("codex");
        let script = r#"#!/bin/bash
[[ "$*" == "app-server" ]] || exit 1
attempt=0
while IFS= read -r request; do
  [[ "$request" == *'"id":'* ]] || continue
  printf '%s\n' "$request" >> "$0.requests"
  id=${request#*'"id":'}
  id=${id%%[!0-9]*}
  case "$request" in
    *'"method":"initialize"'*)
      printf '{"id":%s,"result":{"userAgent":"codex_app_server/0.166.0"}}\n' "$id" ;;
    *'"method":"thread/resume"'*)
      attempt=$((attempt+1))
      if [[ $attempt == 1 ]]; then
        printf '{"id":%s,"error":{"code":-32600,"message":"REJECTION"}}\n' "$id"
        printf '%s\n' '{"method":"thread/closed","params":{"threadId":"thread-1"}}'
      else
        printf '{"id":%s,"result":{"thread":{"id":"thread-1","turns":[]},"model":"test-model","cwd":"/work"}}\n' "$id"
      fi ;;
    *'"method":"test/event"'*)
      printf '{"id":%s,"result":{}}\n' "$id"
      printf '%s\n' '{"method":"thread/name/updated","params":{"threadId":"thread-1","threadName":"still routed"}}' ;;
    *'"method":"test/complete"'*)
      printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-live","status":"inProgress"}}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-live","status":"completed"}}}'
      printf '{"id":%s,"result":{}}\n' "$id" ;;
    *) printf '{"id":%s,"result":{"data":[]}}\n' "$id" ;;
  esac
done
"#;
        let message = if closing {
            "thread thread-1 is closing; retry thread/resume after the thread is closed"
        } else {
            "model is unavailable"
        };
        std::fs::write(&executable, script.replace("REJECTION", message)).unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        let harness = CodexHarness::new(CodexHarnessConfig {
            launch: CodexLaunchConfig {
                executable,
                ..Default::default()
            },
            source: ExecutableSource::User,
            pinned_sha256: None,
            bridge_version: "test".into(),
            cache_root: dir.path().join("cache"),
        });
        (dir, harness)
    }

    fn resume_spec() -> OpenSpec {
        OpenSpec {
            mode: OpenMode::Resume {
                session: ProviderSessionId::new("thread-1").unwrap(),
            },
            folder: "/work".into(),
            settings: Default::default(),
            instructions: None,
            title: None,
            after: None,
            output_mode: Default::default(),
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn closing_resume_retries_without_sending_input_and_keeps_event_routing() {
        use futures_util::StreamExt;
        for late_close in [false, true] {
            let (dir, harness) = scripted_harness(true);
            if late_close {
                let executable = &harness.config.launch.executable;
                let script = std::fs::read_to_string(executable).unwrap();
                let close = "        printf '%s\\n' '{\"method\":\"thread/closed\",\"params\":{\"threadId\":\"thread-1\"}}'\n";
                let script = script
                    .replace(close, "")
                    .replace("      else\n", &format!("      else\n{close}"));
                std::fs::write(executable, script).unwrap();
            }
            let session = tokio::time::timeout(Duration::from_secs(3), harness.open(resume_spec()))
                .await
                .unwrap()
                .unwrap();
            let mut events = session.events();
            let connection = harness.connection().await.unwrap();
            connection
                .request(Request {
                    method: "test/event",
                    params: json!({}),
                })
                .await
                .unwrap();
            tokio::time::timeout(Duration::from_secs(2), async {
                while let Some(envelope) = events.next().await {
                    let event = envelope.event;
                    assert!(!matches!(
                        event,
                        Event::State {
                            state: RunState::Released
                        }
                    ));
                    if matches!(event, Event::Renamed { title } if title == "still routed") {
                        return;
                    }
                }
                panic!("resumed event stream ended");
            })
            .await
            .unwrap();
            let requests = std::fs::read_to_string(dir.path().join("codex.requests")).unwrap();
            assert_eq!(requests.matches("\"method\":\"thread/resume\"").count(), 2);
            assert!(!requests.contains("\"method\":\"turn/start\""));
            connection.control.shutdown().await.unwrap();
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_completion_newer_than_the_resume_snapshot_is_not_undone() {
        use futures_util::StreamExt;
        let (_dir, harness) = scripted_harness(true);
        let session = harness.open(resume_spec()).await.unwrap();
        let connection = harness.connection().await.unwrap();
        let inner = connection
            .sessions
            .lock()
            .unwrap()
            .get("thread-1")
            .unwrap()
            .upgrade()
            .unwrap();
        let response_sequence = inner.open_boundary.lock().unwrap().response.unwrap();
        let mut events = session.events();
        connection
            .request(Request {
                method: "test/complete",
                params: json!({}),
            })
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(2), async {
            while let Some(event) = events.next().await {
                if matches!(
                    event.event,
                    Event::Turn {
                        phase: inline_agent_bridge::harness::TurnPhase::Completed { .. },
                        ..
                    }
                ) {
                    return;
                }
            }
            panic!("completion missing");
        })
        .await
        .unwrap();
        inner.restore_open_snapshot(
            &json!({"thread":{"turns":[{"id":"turn-live","status":"inProgress"}]}}),
            response_sequence,
        );
        assert!(inner.mapper.lock().unwrap().active_turn().is_none());
        connection.control.shutdown().await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn permanent_resume_rejection_is_not_retried() {
        let (dir, harness) = scripted_harness(false);
        assert!(matches!(harness.open(resume_spec()).await,
            Err(OpenError::Driver(DriverError::Rejected(message))) if message == "model is unavailable"));
        let requests = std::fs::read_to_string(dir.path().join("codex.requests")).unwrap();
        assert_eq!(requests.matches("\"method\":\"thread/resume\"").count(), 1);
        harness
            .connection()
            .await
            .unwrap()
            .control
            .shutdown()
            .await
            .unwrap();
    }

    #[test]
    fn skill_options_keep_enabled_skills_once() {
        let options = skill_options(&serde_json::json!({"data": [
            {"cwd": "/a", "errors": [], "skills": [
                {"name": "fix-ci", "description": "Fixes CI", "enabled": true, "path": "/s", "scope": "user",
                 "interface": {"displayName": "Fix CI"}},
                {"name": "off", "description": "Disabled", "enabled": false, "path": "/o", "scope": "user"},
            ]},
            {"cwd": "/b", "errors": [], "skills": [
                {"name": "fix-ci", "description": "Again", "enabled": true, "path": "/s2", "scope": "repo"},
                {"name": "plain", "description": "", "enabled": true, "path": "/p", "scope": "repo"},
            ]},
        ]}));
        let summary = options
            .iter()
            .map(|option| {
                (
                    option.value.as_str(),
                    option.label.as_str(),
                    option.description.as_deref(),
                )
            })
            .collect::<Vec<_>>();
        assert_eq!(
            summary,
            [
                ("fix-ci", "Fix CI", Some("Fixes CI")),
                ("plain", "plain", None)
            ]
        );
    }

    #[test]
    fn a_project_lists_each_root_under_its_name() {
        let project = |name: &str, roots: &[&str]| crate::protocol::CodexProject {
            name: name.to_owned(),
            roots: roots
                .iter()
                .map(|path| crate::protocol::CodexProjectRoot { path: path.into() })
                .collect(),
        };
        let labels = |project| {
            project_roots(project)
                .into_iter()
                .map(|folder| (folder.path.display().to_string(), folder.label))
                .collect::<Vec<_>>()
        };
        assert_eq!(
            labels(project("Inline", &["/work/inline"])),
            [("/work/inline".to_owned(), "Inline".to_owned())]
        );
        assert_eq!(
            labels(project("Site", &["/work/web", "/work/api", "relative"])),
            [
                ("/work/web".to_owned(), "Site · web".to_owned()),
                ("/work/api".to_owned(), "Site · api".to_owned()),
            ]
        );
        assert_eq!(
            labels(project(" ", &["/work/scratch"])),
            [("/work/scratch".to_owned(), "scratch".to_owned())]
        );
        let page: crate::protocol::ProjectListResponse = serde_json::from_value(json!({
            "data": [{"id": "p1", "name": "Inline", "createdAt": 1, "updatedAt": 1,
                "position": 0, "metadata": {}, "roots": [{"path": "/work/inline"}]}],
            "nextCursor": null
        }))
        .unwrap();
        assert_eq!(page.data[0].name, "Inline");
    }

    /// A scripted stand-in for `codex app-server`: answers `initialize`,
    /// `thread/start` and `turn/start`, starts the turn, then runs `after`.
    #[cfg(unix)]
    fn fake_app_server(dir: &std::path::Path, after: &str) -> CodexHarness {
        use std::os::unix::fs::PermissionsExt;
        let executable = dir.join("fake-codex");
        std::fs::write(
            &executable,
            format!(
                r#"#!/bin/sh
[ "$1" = "app-server" ] && [ -z "$2" ] || exit 1
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | grep -o '"id":[0-9]*' | head -n 1 | cut -d: -f2)
  case "$line" in
    *'"method":"initialize"'*)
      printf '{{"id":%s,"result":{{}}}}\n' "$id" ;;
    *'"method":"thread/start"'*)
      printf '{{"id":%s,"result":{{"thread":{{"id":"thr-1","turns":[]}},"model":"gpt-5"}}}}\n' "$id" ;;
    *'"method":"turn/start"'*)
      printf '{{"id":%s,"result":{{"turn":{{"id":"turn-1","status":"inProgress"}}}}}}\n' "$id"
      printf '{{"method":"turn/started","params":{{"threadId":"thr-1","turn":{{"id":"turn-1","status":"inProgress"}}}}}}\n'
      {after} ;;
    *)
      [ -n "$id" ] && printf '{{"id":%s,"error":{{"code":-32601,"message":"unsupported"}}}}\n' "$id" ;;
  esac
done
"#
            ),
        )
        .expect("write fake app-server");
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700))
            .expect("make fake app-server executable");
        CodexHarness::new(CodexHarnessConfig {
            launch: CodexLaunchConfig {
                executable,
                version_policy: crate::CodexVersionPolicy::Any,
                ..CodexLaunchConfig::default()
            },
            source: ExecutableSource::Path,
            pinned_sha256: None,
            bridge_version: "0.0.0-test".to_owned(),
            cache_root: dir.join("cache"),
        })
    }

    /// Opens a thread, starts one turn and returns how that turn completed.
    #[cfg(unix)]
    async fn run_one_turn(harness: &CodexHarness, folder: &std::path::Path) -> TurnOutcome {
        use futures_util::StreamExt;
        use inline_agent_bridge::harness::{InputContent, InputId, Origin, TurnPhase, UserId};
        let session = harness
            .open(OpenSpec {
                mode: OpenMode::Start,
                folder: folder.to_owned(),
                settings: Default::default(),
                instructions: None,
                title: None,
                after: None,
                output_mode: Default::default(),
            })
            .await
            .unwrap_or_else(|error| panic!("open: {error}"));
        let mut events = session.events();
        let receipt = session
            .send(Input {
                id: InputId::new("input-1").expect("input id"),
                content: InputContent::text("hello"),
                origin: Origin::Owner { user: UserId(1) },
                delivery: Delivery::Turn,
            })
            .await
            .unwrap_or_else(|error| panic!("send: {error:?}"));
        assert!(matches!(
            receipt.disposition,
            InputDisposition::Started { ref turn } if turn.as_str() == "turn-1"
        ));
        let outcome = tokio::time::timeout(Duration::from_secs(10), async {
            while let Some(envelope) = events.next().await {
                if let Event::Turn {
                    turn,
                    phase: TurnPhase::Completed { outcome, .. },
                } = envelope.event
                {
                    assert_eq!(turn.as_str(), "turn-1");
                    return outcome;
                }
            }
            panic!("the event stream ended before the turn completed");
        })
        .await
        .expect("the turn must complete instead of staying working");
        assert!(session.live_work().turn.is_none(), "no turn left running");
        outcome
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_crash_mid_turn_completes_the_turn_as_connection_lost() {
        let dir = tempfile::tempdir().expect("temporary directory");
        let harness = fake_app_server(dir.path(), "exit 3");
        assert_eq!(
            run_one_turn(&harness, dir.path()).await,
            TurnOutcome::ConnectionLost
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_stray_stdout_line_mid_turn_is_skipped() {
        let dir = tempfile::tempdir().expect("temporary directory");
        let harness = fake_app_server(
            dir.path(),
            r#"printf 'warning: a tool wrote to stdout\n'
      printf '{"method":"turn/completed","params":{"threadId":"thr-1","turn":{"id":"turn-1","status":"completed"}}}\n'"#,
        );
        assert_eq!(
            run_one_turn(&harness, dir.path()).await,
            TurnOutcome::Completed
        );
    }

    /// A scripted app-server with a schema (so the native queue and modes
    /// are available) and a thread whose effort is `high`. `turn/steer`
    /// refuses: during a review for input "review-steer", otherwise with
    /// "no active turn to steer". `after` runs once a turn starts.
    #[cfg(unix)]
    fn steering_app_server(dir: &std::path::Path, after: &str) -> CodexHarness {
        use std::os::unix::fs::PermissionsExt;
        let methods = [
            "thread/start",
            "thread/resume",
            "turn/start",
            "turn/steer",
            "turn/interrupt",
            "thread/queue/add",
            "thread/inject_items",
            "thread/settings/update",
            "collaborationMode/list",
        ];
        let client_requests = json!({"oneOf": methods
            .iter()
            .map(|method| json!({"properties": {"method": {"enum": [method]}}}))
            .collect::<Vec<_>>()});
        let script = r#"#!/bin/sh
if [ "$1" = "app-server" ] && [ "$2" = "generate-json-schema" ]; then
  printf '%s' 'CLIENT_REQUESTS' > "$5/ClientRequest.json"
  printf '%s' '{"oneOf":[]}' > "$5/ServerRequest.json"
  printf '%s' '{"oneOf":[]}' > "$5/ServerNotification.json"
  exit 0
fi
[ "$1" = "app-server" ] && [ -z "$2" ] || exit 1
while IFS= read -r line; do
  case "$line" in *'"id":'*) printf '%s\n' "$line" >> "$0.requests" ;; esac
  id=$(printf '%s\n' "$line" | grep -o '"id":[0-9]*' | head -n 1 | cut -d: -f2)
  case "$line" in
    *'"result":'*) ;;
    *'"method":"initialize"'*)
      printf '{"id":%s,"result":{}}\n' "$id" ;;
    *'"method":"thread/start"'*)
      printf '{"id":%s,"result":{"thread":{"id":"thr-1","turns":[]},"model":"gpt-5","reasoningEffort":"high"}}\n' "$id" ;;
    *'"method":"turn/start"'*)
      printf '{"id":%s,"result":{"turn":{"id":"turn-1","status":"inProgress"}}}\n' "$id"
      printf '{"method":"turn/started","params":{"threadId":"thr-1","turn":{"id":"turn-1","status":"inProgress"}}}\n'
      AFTER ;;
    *'"method":"turn/steer"'*'review-steer'*)
      printf '{"id":%s,"error":{"code":-32600,"message":"cannot steer a review turn","data":{"message":"cannot steer a review turn","codexErrorInfo":{"activeTurnNotSteerable":{"turnKind":"review"}},"additionalDetails":null}}}\n' "$id" ;;
    *'"method":"turn/steer"'*)
      printf '{"id":%s,"error":{"code":-32600,"message":"no active turn to steer"}}\n' "$id" ;;
    *'"method":"thread/queue/add"'*)
      printf '{"id":%s,"result":{"queuedSubmission":{"id":"q-1"}}}\n' "$id" ;;
    *)
      [ -n "$id" ] && printf '{"id":%s,"result":{}}\n' "$id" ;;
  esac
done
"#
        .replace("CLIENT_REQUESTS", &client_requests.to_string())
        .replace("AFTER", if after.is_empty() { ":" } else { after });
        let executable = dir.join("codex");
        std::fs::write(&executable, script).expect("write fake app-server");
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700))
            .expect("make fake app-server executable");
        CodexHarness::new(CodexHarnessConfig {
            launch: CodexLaunchConfig {
                executable,
                version_policy: crate::CodexVersionPolicy::Any,
                ..CodexLaunchConfig::default()
            },
            source: ExecutableSource::Path,
            pinned_sha256: None,
            bridge_version: "0.0.0-test".to_owned(),
            cache_root: dir.join("cache"),
        })
    }

    #[cfg(unix)]
    fn start_spec(folder: &std::path::Path) -> OpenSpec {
        OpenSpec {
            mode: OpenMode::Start,
            folder: folder.to_owned(),
            settings: Default::default(),
            instructions: None,
            title: None,
            after: None,
            output_mode: Default::default(),
        }
    }

    #[cfg(unix)]
    fn owner_input(id: &str, text: &str, delivery: Delivery) -> Input {
        use inline_agent_bridge::harness::{InputContent, InputId, Origin, UserId};
        Input {
            id: InputId::new(id).expect("input id"),
            content: InputContent::text(text),
            origin: Origin::Owner { user: UserId(1) },
            delivery,
        }
    }

    /// Waits for the fake app-server to have logged a line containing `needle`.
    #[cfg(unix)]
    async fn logged(dir: &std::path::Path, needle: &str) -> String {
        let path = dir.join("codex.requests");
        for _ in 0..100 {
            let log = std::fs::read_to_string(&path).unwrap_or_default();
            if log.contains(needle) {
                return log;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!(
            "`{needle}` never reached the app-server:\n{}",
            std::fs::read_to_string(&path).unwrap_or_default()
        );
    }

    /// Live repro (audit B1): Codex numbers requests from 0 in every
    /// process, so after a restart a thread's first approval had the same
    /// interaction id, and the same card, as an old closed one.
    #[cfg(unix)]
    #[tokio::test]
    async fn a_new_app_server_process_never_reuses_an_interaction_id() {
        use futures_util::StreamExt;
        use inline_agent_bridge::harness::{DecisionId, InteractionResponse, UserId};
        let approval = r#"printf '%s\n' '{"id":0,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr-1","turnId":"turn-1","itemId":"c1","command":"ls","availableDecisions":["accept","cancel"]}}'"#;
        let mut ids = Vec::new();
        for _ in 0..2 {
            let dir = tempfile::tempdir().expect("temporary directory");
            let harness = steering_app_server(dir.path(), approval);
            let session = harness.open(start_spec(dir.path())).await.expect("open");
            let mut events = session.events();
            session
                .send(owner_input("in-1", "hello", Delivery::Turn))
                .await
                .expect("send");
            let interaction = tokio::time::timeout(Duration::from_secs(5), async {
                while let Some(envelope) = events.next().await {
                    if let Event::Interaction(interaction) = envelope.event {
                        return interaction.id;
                    }
                }
                panic!("the event stream ended before the approval");
            })
            .await
            .expect("the approval must reach the session");
            assert!(interaction.as_str().ends_with(":0"), "{interaction}");
            assert_eq!(
                session.live_work().interactions,
                std::slice::from_ref(&interaction)
            );
            // The answer goes back to Codex's own request id.
            session
                .control(Op::Answer {
                    interaction: interaction.clone(),
                    response: InteractionResponse::Decision {
                        decision: DecisionId::new("accept").expect("decision"),
                        message: None,
                    },
                    by: UserId(1),
                })
                .await
                .expect("answer");
            logged(dir.path(), r#"{"id":0,"result":{"decision":"accept"}}"#).await;
            ids.push(interaction);
            harness
                .connection()
                .await
                .expect("connection")
                .control
                .shutdown()
                .await
                .expect("shutdown");
        }
        assert_ne!(ids[0], ids[1]);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_steer_codex_cannot_take_now_waits_in_its_queue_or_starts_the_next_turn() {
        use inline_agent_bridge::harness::{ModeId, SteerPriority};
        let dir = tempfile::tempdir().expect("temporary directory");
        let harness = steering_app_server(dir.path(), "");
        let session = harness.open(start_spec(dir.path())).await.expect("open");
        let turn = TurnId::new("turn-1").expect("turn");
        let steer = || Delivery::Steer {
            expected_turn: turn.clone(),
            priority: SteerPriority::Next,
        };
        let started = session
            .send(owner_input("in-1", "hello", Delivery::Turn))
            .await
            .expect("send");
        assert_eq!(
            started.disposition,
            InputDisposition::Started { turn: turn.clone() }
        );

        // A review runs: Codex takes no steering, so the input waits in its
        // queue and runs when the review ends, as the Codex TUI queues it.
        let queued = session
            .send(owner_input("in-2", "review-steer", steer()))
            .await
            .expect("queued instead of refused");
        assert_eq!(
            queued.disposition,
            InputDisposition::Queued {
                entry: Some(QueueEntryId::new("q-1").expect("entry"))
            }
        );
        let log = logged(dir.path(), "thread/queue/add").await;
        let queue_add = log
            .lines()
            .find(|line| line.contains("thread/queue/add"))
            .expect("queue add");
        assert!(queue_add.contains("inline-agent-bridge:v2:in-2"));
        assert!(log.contains("thread/inject_items"));

        // The turn ended before the steer reached it: the bridge's retry as
        // a new turn is not refused against the turn Inline saw last.
        let late = session
            .send(owner_input("in-3", "late-steer", steer()))
            .await
            .expect_err("no turn to steer");
        assert!(matches!(late, SendError::TurnMismatch { active: None }));
        assert!(session.live_work().turn.is_none());
        let retried = session
            .send(owner_input("in-3", "late-steer", Delivery::Turn))
            .await
            .expect("a new turn");
        assert!(matches!(
            retried.disposition,
            InputDisposition::Started { .. }
        ));

        // Switching modes keeps the thread's effort.
        session
            .control(Op::Mode {
                mode: ModeId::new("plan").expect("mode"),
            })
            .await
            .expect("mode");
        let log = logged(dir.path(), "collaborationMode").await;
        let update = log
            .lines()
            .find(|line| line.contains("thread/settings/update"))
            .expect("settings update");
        assert!(
            update.contains(r#""settings":{"model":"gpt-5","reasoning_effort":"high"}"#),
            "{update}"
        );
        harness
            .connection()
            .await
            .expect("connection")
            .control
            .shutdown()
            .await
            .expect("shutdown");
    }

    #[test]
    fn steer_refusals_read_codex_error_info_first() {
        let refused = |message: &str, data: Option<Value>| RoutedError {
            error: PeerError::Remote(crate::peer::RemoteError {
                code: Some(-32600),
                message: message.to_owned(),
            }),
            data,
        };
        // The structured reason wins over any wording.
        assert_eq!(
            steer_refusal(&refused(
                "something new",
                Some(
                    json!({"codexErrorInfo": {"activeTurnNotSteerable": {"turnKind": "compact"}}})
                )
            )),
            Some(SteerRefusal::NotSteerable)
        );
        assert_eq!(
            steer_refusal(&refused("cannot steer a compact turn", None)),
            Some(SteerRefusal::NotSteerable)
        );
        // `turn/start` steers into a running turn and says so in text.
        assert_eq!(
            steer_refusal(&refused(
                "failed to submit turn input: ActiveTurnNotSteerable { turn_kind: Review }",
                None
            )),
            Some(SteerRefusal::NotSteerable)
        );
        assert_eq!(
            steer_refusal(&refused("no active turn to steer", None)),
            Some(SteerRefusal::NoActiveTurn)
        );
        assert_eq!(
            steer_refusal(&refused(
                "expected active turn id `turn-1` but found `turn-2`",
                None
            )),
            Some(SteerRefusal::OtherTurn(Some(
                TurnId::new("turn-2").unwrap()
            )))
        );
        assert_eq!(
            steer_refusal(&refused("input must not be empty", None)),
            None
        );
        assert_eq!(steer_refusal(&RoutedError::from(PeerError::Closed)), None);
    }

    #[test]
    fn each_connection_has_its_own_epoch() {
        let first = connection_epoch();
        assert_eq!(first.len(), 8);
        assert!(first.chars().all(|character| character.is_ascii_hexdigit()));
        assert_ne!(first, connection_epoch());
    }

    #[test]
    fn a_lost_connection_completes_a_turn_whose_start_reply_was_still_in_flight() {
        let mut mapper = CodexMapper::new("thr-1");
        // The process died between answering `turn/start` and starting the turn.
        assert!(mapper.connection_lost().is_empty());
        let turn = TurnId::new("turn-1").unwrap();
        let events = mapper.turn_started_by_request(turn.clone());
        assert!(matches!(
            events.as_slice(),
            [Event::Turn {
                phase: inline_agent_bridge::harness::TurnPhase::Completed {
                    outcome: TurnOutcome::ConnectionLost,
                    ..
                },
                ..
            }]
        ));
        assert!(mapper.active_turn().is_none());
        // Reported once, however late the reply is handled.
        assert!(mapper.turn_started_by_request(turn).is_empty());
    }
}
