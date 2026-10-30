//! The Codex `HarnessDriver` and `Session`: one private app-server process per
//! driver, sessions routed by thread id.

use std::collections::HashMap;
use std::path::PathBuf;
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
use crate::peer::{CodexPeer, IncomingMessage, PeerError};
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
    /// Folder for the schema cache (`<root>/codex-schema/<sha256>/`).
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
}

impl Connection {
    fn closed(&self) -> bool {
        self.control.is_finished()
    }

    async fn request(&self, request: Request) -> Result<Value, PeerError> {
        self.peer
            .request_with_timeout(request.method, request.params, REQUEST_TIMEOUT)
            .await
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
        let sha256 = manifest::binary_sha256(&executable).ok();
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
        let surface = match &sha256 {
            Some(sha256) => self.schema_surface(sha256).await,
            None => None,
        };

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
        });
        tokio::spawn(dispatch(
            Arc::downgrade(&connection),
            incoming,
            self.host_tools.clone(),
        ));
        Ok(connection)
    }

    /// Generates (or reads cached) protocol schema for this binary.
    async fn schema_surface(&self, sha256: &str) -> Option<SchemaSurface> {
        let dir = manifest::schema_cache_dir(&self.config.cache_root, sha256);
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
        Some(Value::Array(
            configuration
                .specs
                .iter()
                .map(|tool| {
                    json!({
                        "name": tool.name,
                        "description": tool.description,
                        "inputSchema": tool.input_schema,
                        "namespace": "inline",
                        "deferLoading": false,
                    })
                })
                .collect(),
        ))
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

    fn open<'a>(&'a self, spec: OpenSpec) -> HarnessFuture<'a, Arc<dyn Session>, OpenError> {
        Box::pin(async move {
            let connection = self.connection().await?;
            let Request { method, params } =
                super::delivery::open_request(&spec, self.dynamic_tools());
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
            let response = match connection.request(Request { method, params }).await {
                Ok(response) => response,
                Err(error) => {
                    if let Some(inner) = &early {
                        connection
                            .sessions
                            .lock()
                            .expect("session map poisoned")
                            .remove(&inner.thread);
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
            inner.hub.emit(Event::Settings {
                effective: settings,
            });
            // The initial state comes from the thread's own turns: a resumed
            // thread may already be running one.
            let (active, finished) = thread_turns(&response);
            let (running, consumed) = {
                let mut mapper = inner.mapper.lock().expect("mapper poisoned");
                mapper.restore_turns(active.clone(), finished);
                (
                    mapper.active_turn().is_some(),
                    mapper.restore_inputs(&response),
                )
            };
            for event in consumed {
                inner.hub.emit(event);
            }
            inner.hub.emit(Event::State {
                state: if running {
                    RunState::Working
                } else {
                    RunState::Idle
                },
            });
            let session: Arc<dyn Session> = Arc::new(CodexSession { inner, connection });
            Ok(session)
        })
    }
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
    model: StdMutex<Option<String>>,
    queue: StdMutex<Vec<QueuedInput>>,
    /// Background terminals still running, from `thread/backgroundTerminals/list`.
    terminals: StdMutex<Vec<inline_agent_bridge::harness::ChildRef>>,
    connection: Weak<Connection>,
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
            mapper: StdMutex::new(CodexMapper::new(thread.clone())),
            thread,
            model: StdMutex::new(None),
            queue: StdMutex::new(Vec::new()),
            terminals: StdMutex::new(Vec::new()),
            connection: Arc::downgrade(connection),
        }))
    }

    fn emit_all(&self, events: Vec<Event>) {
        for event in events {
            if let Event::Settings { effective } = &event
                && let Some(model) = &effective.model
            {
                *self.model.lock().expect("model poisoned") = Some(model.value.clone());
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
                connection
                    .sessions
                    .lock()
                    .expect("session map poisoned")
                    .remove(&self.thread);
            }
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
            IncomingMessage::Notification { method, params, .. } => {
                for session in &sessions {
                    let mapped = session
                        .mapper
                        .lock()
                        .expect("mapper poisoned")
                        .notification(&method, &params);
                    session.emit_all(mapped.events);
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
    // The connection ended: every pending interaction is gone with it.
    if let Some(connection) = connection.upgrade() {
        let sessions: Vec<Arc<SessionInner>> = connection
            .sessions
            .lock()
            .expect("session map poisoned")
            .values()
            .filter_map(Weak::upgrade)
            .collect();
        for session in sessions {
            let events = session.mapper.lock().expect("mapper poisoned").cancel_all();
            session.emit_all(events);
            session.emit_all(vec![Event::State {
                state: RunState::Unknown,
            }]);
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
            let request = input_request(&self.inner.thread, &input);
            let response = self.connection.request(request).await.map_err(send_error)?;
            let disposition = match &input.delivery {
                Delivery::Turn => {
                    let turn = response
                        .pointer("/turn/id")
                        .and_then(Value::as_str)
                        .and_then(|turn| TurnId::new(turn).ok())
                        .ok_or_else(|| {
                            SendError::Unknown("turn/start returned no turn id".to_owned())
                        })?;
                    self.inner
                        .mapper
                        .lock()
                        .expect("mapper poisoned")
                        .turn_started_by_request(turn.clone());
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
            let request = op_request(
                &self.inner.thread,
                TurnFacts {
                    active: active.as_ref(),
                    last_finished: last_finished.as_ref(),
                },
                model.as_deref(),
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
}
