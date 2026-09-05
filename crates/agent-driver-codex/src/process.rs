use std::collections::VecDeque;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use inline_agent_bridge::{AgentDriver, DriverError, ProcessHostConfig, reap_stale_process_host};
use semver::Version;
use thiserror::Error;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, watch};
use tokio::task::JoinSet;
use tokio::time::timeout;
use tokio_tungstenite::client_async_with_config;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;

use crate::{CodexAppServerDriver, CodexPeer};

const VERSION_PROBE_TIMEOUT: Duration = Duration::from_secs(10);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
const SHARED_HOST_START_TIMEOUT: Duration = Duration::from_secs(15);
const SHARED_HOST_RETRY_DELAY: Duration = Duration::from_millis(100);
const RUNTIME_CONTRACT_TIMEOUT: Duration = Duration::from_secs(20);
const DEFAULT_INCOMING_CAPACITY: usize = 256;
const SOCKET_ADAPTER_BUFFER_BYTES: usize = 256 * 1024;
const MAX_WEBSOCKET_MESSAGE_BYTES: usize = 32 * 1024 * 1024;
const STDERR_TAIL_LINES: usize = 40;
const STDERR_LINE_BYTES: usize = 512;

/// Environment names owned by Codex/OpenAI which are deliberately retained.
///
/// Codex normally discovers its login from `HOME`/`CODEX_HOME`; the OpenAI
/// variables support its documented API-key and endpoint configuration. Keep
/// this small exception list before applying the generic secret-name scrubber.
const PROVIDER_ENVIRONMENT_PREFIXES: &[&str] = &["CODEX_", "OPENAI_"];

/// Exact non-provider credentials which do not always contain a generic
/// sensitive-name component. The component rules below handle the common
/// `*_TOKEN`, `*_SECRET`, and `*_API_KEY` forms.
const SENSITIVE_ENVIRONMENT_NAMES: &[&str] = &[
    "DATABASE_URL",
    "REDIS_URL",
    "SENTRY_DSN",
    "SENTRY_AUTH_TOKEN",
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "NPM_TOKEN",
    "BUN_AUTH_TOKEN",
    "YARN_NPM_AUTH_TOKEN",
];

pub fn minimum_codex_version() -> Version {
    // The oldest app-server protocol with the stable methods required by this
    // bridge. Newer versions are accepted after a live capability probe.
    Version::new(0, 146, 0)
}

pub fn is_compatible_codex_version(version: &Version) -> bool {
    version >= &minimum_codex_version()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CodexVersionPolicy {
    /// Accept the minimum supported protocol and every newer Codex version.
    /// Production callers also probe the methods and response shapes Inline
    /// consumes before exposing the runtime.
    Compatible,
    Exact(Version),
    Any,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum CodexAppServerTransport {
    /// One app-server process and one Inline connection over stdio.
    #[default]
    PrivateStdio,
    /// Attach to the user's default multi-client control socket. If no host is
    /// listening, launch one from the selected signed/compatible executable and
    /// supervise it for the lifetime of this bridge connection. This transport
    /// remains catalog/connection-foundation only until the live session hub
    /// demultiplexes external traffic and reconciles ambiguous mutations; the
    /// ordinary turn driver must continue using `PrivateStdio` until then.
    SharedLocal,
}

impl CodexAppServerTransport {
    fn stdio_arguments(&self) -> Option<Vec<OsString>> {
        match self {
            Self::PrivateStdio => Some(vec![OsString::from("app-server")]),
            Self::SharedLocal => None,
        }
    }

    fn host_arguments(&self) -> Option<Vec<OsString>> {
        match self {
            Self::PrivateStdio => None,
            Self::SharedLocal => Some(vec![
                OsString::from("app-server"),
                OsString::from("--listen"),
                OsString::from("unix://"),
            ]),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexLaunchConfig {
    pub executable: PathBuf,
    pub transport: CodexAppServerTransport,
    pub version_policy: CodexVersionPolicy,
    pub incoming_capacity: usize,
    /// Additional host-specific environment variables removed before launching
    /// Codex. The standard Inline/app-secret policy is always applied too.
    pub environment_remove: Vec<OsString>,
    /// Optional crash-surviving process host supplied by the bundled CLI.
    pub process_host: Option<ProcessHostConfig>,
    #[cfg(test)]
    pub(crate) app_server_args_override: Option<Vec<OsString>>,
}

impl Default for CodexLaunchConfig {
    fn default() -> Self {
        Self {
            executable: PathBuf::from("codex"),
            transport: CodexAppServerTransport::default(),
            version_policy: CodexVersionPolicy::Compatible,
            incoming_capacity: DEFAULT_INCOMING_CAPACITY,
            environment_remove: vec![
                OsString::from("INLINE_TOKEN"),
                OsString::from("INLINE_SECRETS_PATH"),
                OsString::from("INLINE_DEVICE_ID"),
            ],
            process_host: None,
            #[cfg(test)]
            app_server_args_override: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexVersionProbe {
    pub executable: PathBuf,
    pub version: Version,
}

#[derive(Debug, Error)]
pub enum CodexLaunchError {
    #[error("failed to run {executable}: {source}")]
    ProbeIo {
        executable: PathBuf,
        source: std::io::Error,
    },
    #[error("timed out while checking {0} --version")]
    ProbeTimeout(PathBuf),
    #[error("{executable} --version failed with {status}: {diagnostic}")]
    ProbeFailed {
        executable: PathBuf,
        status: String,
        diagnostic: String,
    },
    #[error("could not parse a Codex version from: {0}")]
    InvalidVersionOutput(String),
    #[error("Codex {found} is unsupported; this Inline build requires {required}")]
    UnsupportedVersion { found: Version, required: String },
    #[error("failed to start Codex app-server: {0}")]
    Spawn(#[source] std::io::Error),
    #[error("Codex app-server did not expose {0}")]
    MissingPipe(&'static str),
    #[error("Codex app-server initialization failed: {0}")]
    Initialize(#[from] DriverError),
    #[error("Codex app-server compatibility probe failed: {0}")]
    IncompatibleProtocol(#[source] DriverError),
    #[error("Codex process host recovery failed: {0}")]
    ProcessHost(#[source] std::io::Error),
    #[error("Codex shared app-server did not become available: {0}")]
    SharedHostUnavailable(String),
    #[error("Codex shared app-server is incompatible: {0}")]
    SharedHostIncompatible(String),
}

#[derive(Clone, Debug)]
pub struct RedactedStderrTail {
    lines: Arc<StdMutex<VecDeque<String>>>,
}

impl RedactedStderrTail {
    fn new() -> Self {
        Self {
            lines: Arc::new(StdMutex::new(VecDeque::with_capacity(STDERR_TAIL_LINES))),
        }
    }

    fn push(&self, line: &str) {
        let mut lines = self.lines.lock().expect("Codex stderr tail poisoned");
        if lines.len() == STDERR_TAIL_LINES {
            lines.pop_front();
        }
        lines.push_back(redact_stderr_line(line));
    }

    pub fn snapshot(&self) -> Vec<String> {
        self.lines
            .lock()
            .expect("Codex stderr tail poisoned")
            .iter()
            .cloned()
            .collect()
    }
}

#[derive(Debug)]
pub struct SpawnedCodexDriver {
    pub driver: CodexAppServerDriver<CodexDriverWriter>,
    pub version: CodexVersionProbe,
    /// Advisory version parsed from initialize metadata. Future app-server
    /// user-agent formats may omit a SemVer while still satisfying Inline's
    /// live protocol contract.
    pub app_server_version: Option<Version>,
    pub transport: CodexAppServerTransport,
    pub stderr_tail: RedactedStderrTail,
    pub process_status: CodexProcessStatus,
}

pub type CodexDriverWriter = Box<dyn AsyncWrite + Send + Unpin>;

#[derive(Clone, Debug)]
pub struct CodexProcessStatus {
    exit: Arc<StdMutex<Option<String>>>,
}

impl CodexProcessStatus {
    fn new() -> Self {
        Self {
            exit: Arc::new(StdMutex::new(None)),
        }
    }

    fn record(&self, status: impl Into<String>) {
        *self.exit.lock().expect("Codex process status poisoned") = Some(status.into());
    }

    pub fn exit_description(&self) -> Option<String> {
        self.exit
            .lock()
            .expect("Codex process status poisoned")
            .clone()
    }
}

pub async fn probe_codex_version(
    config: &CodexLaunchConfig,
) -> Result<CodexVersionProbe, CodexLaunchError> {
    let probe_host = config.process_host.as_ref().map(|host| ProcessHostConfig {
        executable: host.executable.clone(),
        lock_file: host.lock_file.with_extension("version.lock"),
    });
    if let Some(host) = probe_host.as_ref() {
        reap_stale_process_host(&host.lock_file)
            .await
            .map_err(CodexLaunchError::ProcessHost)?;
    }
    let mut command = hosted_codex_command(config, probe_host.as_ref(), ["--version"]);
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // A bundled process host must handle TERM itself so it can clean its
        // provider's separate process group before releasing the ownership lock.
        .kill_on_drop(!cfg!(unix) || probe_host.is_none());
    apply_child_environment(&mut command, config);
    configure_process_group(&mut command);
    let mut child = command
        .spawn()
        .map_err(|source| CodexLaunchError::ProbeIo {
            executable: config.executable.clone(),
            source,
        })?;
    let process_id = child.id();
    let mut process_guard = SpawnedProcessGuard::new(
        process_id,
        if probe_host.is_some() {
            libc::SIGTERM
        } else {
            libc::SIGKILL
        },
    );
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| CodexLaunchError::ProbeIo {
            executable: config.executable.clone(),
            source: std::io::Error::other("Codex version probe did not expose stdout"),
        })?;
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| CodexLaunchError::ProbeIo {
            executable: config.executable.clone(),
            source: std::io::Error::other("Codex version probe did not expose stderr"),
        })?;
    let mut readers = JoinSet::new();
    readers.spawn(async move { (true, read_probe_output(&mut stdout).await) });
    readers.spawn(async move { (false, read_probe_output(&mut stderr).await) });
    let collected = timeout(VERSION_PROBE_TIMEOUT, async {
        let status = child.wait().await?;
        // A direct executable can be a wrapper which exits while descendants
        // retain its pipes. Stop that process group before waiting for EOF.
        signal_process_group(process_id, libc::SIGKILL);
        let mut stdout = None;
        let mut stderr = None;
        while let Some(result) = readers.join_next().await {
            let (is_stdout, output) = result
                .map_err(|error| std::io::Error::other(format!("probe reader failed: {error}")))?;
            if is_stdout {
                stdout = Some(output?);
            } else {
                stderr = Some(output?);
            }
        }
        let stdout = stdout.ok_or_else(|| std::io::Error::other("stdout reader disappeared"))?;
        let stderr = stderr.ok_or_else(|| std::io::Error::other("stderr reader disappeared"))?;
        Ok::<_, std::io::Error>((status, stdout, stderr))
    })
    .await;
    let (status, stdout_bytes, stderr_bytes) = match collected {
        Ok(Ok(result)) => {
            process_guard.disarm();
            result
        }
        Ok(Err(source)) => {
            return Err(CodexLaunchError::ProbeIo {
                executable: config.executable.clone(),
                source,
            });
        }
        Err(_) => {
            if terminate_process(&mut child, process_id).await.is_ok() {
                process_guard.disarm();
            }
            return Err(CodexLaunchError::ProbeTimeout(config.executable.clone()));
        }
    };
    let stdout = String::from_utf8_lossy(&stdout_bytes);
    let stderr = String::from_utf8_lossy(&stderr_bytes);
    let diagnostic = if stdout.trim().is_empty() {
        stderr.trim()
    } else {
        stdout.trim()
    };
    if !status.success() {
        return Err(CodexLaunchError::ProbeFailed {
            executable: config.executable.clone(),
            status: status.to_string(),
            diagnostic: redact_stderr_line(diagnostic),
        });
    }
    let version = parse_codex_version(diagnostic)?;
    ensure_supported_version(&version, &config.version_policy)?;
    Ok(CodexVersionProbe {
        executable: config.executable.clone(),
        version,
    })
}

async fn read_probe_output(
    stream: &mut (impl tokio::io::AsyncRead + Unpin),
) -> std::io::Result<Vec<u8>> {
    const MAX_PROBE_OUTPUT_BYTES: usize = 64 * 1024;

    let mut output = Vec::with_capacity(MAX_PROBE_OUTPUT_BYTES);
    let mut buffer = [0_u8; 8 * 1024];
    loop {
        let read = stream.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        let remaining = MAX_PROBE_OUTPUT_BYTES.saturating_sub(output.len());
        output.extend_from_slice(&buffer[..read.min(remaining)]);
    }
    Ok(output)
}

pub async fn spawn_codex_driver(
    config: CodexLaunchConfig,
    bridge_version: &str,
) -> Result<SpawnedCodexDriver, CodexLaunchError> {
    let version = probe_codex_version(&config).await?;
    #[cfg(test)]
    if let Some(arguments) = config.app_server_args_override.clone() {
        return spawn_codex_stdio_client(&config, arguments, bridge_version, version).await;
    }

    if let Some(arguments) = config.transport.stdio_arguments() {
        return spawn_codex_stdio_client(&config, arguments, bridge_version, version).await;
    }

    let socket_path = default_control_socket_path()?;
    match connect_shared_codex(
        &config,
        &socket_path,
        bridge_version,
        version.clone(),
        None,
        RedactedStderrTail::new(),
    )
    .await
    {
        Ok(spawned) => return Ok(spawned),
        Err(CodexLaunchError::SharedHostUnavailable(_)) => {}
        Err(error) => return Err(error),
    }

    let host_arguments = config
        .transport
        .host_arguments()
        .expect("shared transport has host arguments");
    let host = spawn_shared_host(&config, host_arguments).await?;
    let deadline = tokio::time::Instant::now() + SHARED_HOST_START_TIMEOUT;
    loop {
        match connect_shared_codex(
            &config,
            &socket_path,
            bridge_version,
            version.clone(),
            Some(host.control.clone()),
            host.stderr_tail.clone(),
        )
        .await
        {
            Ok(spawned) => return Ok(spawned),
            Err(CodexLaunchError::SharedHostUnavailable(_))
                if tokio::time::Instant::now() < deadline && !host.control.is_finished() =>
            {
                tokio::time::sleep(SHARED_HOST_RETRY_DELAY).await;
            }
            Err(CodexLaunchError::SharedHostUnavailable(_))
                if tokio::time::Instant::now() < deadline =>
            {
                // Another process can win Codex's startup lock while this
                // launch exits with AddrInUse. Keep probing the shared socket.
                tokio::time::sleep(SHARED_HOST_RETRY_DELAY).await;
            }
            Err(CodexLaunchError::SharedHostUnavailable(_)) => {
                let _ = host.control.shutdown().await;
                return Err(CodexLaunchError::SharedHostUnavailable(
                    host.status
                        .exit_description()
                        .unwrap_or_else(|| "startup timed out".to_string()),
                ));
            }
            Err(error) => {
                let _ = host.control.shutdown().await;
                return Err(error);
            }
        }
    }
}

#[derive(Clone)]
struct ProcessControl {
    shutdown: mpsc::Sender<()>,
    completion: watch::Receiver<Option<Result<(), DriverError>>>,
}

impl ProcessControl {
    fn is_finished(&self) -> bool {
        self.completion.borrow().is_some()
    }

    async fn shutdown(&self) -> Result<(), DriverError> {
        let _ = self.shutdown.send(()).await;
        let mut completion = self.completion.clone();
        loop {
            if let Some(result) = completion.borrow().clone() {
                return result;
            }
            completion.changed().await.map_err(|_| {
                DriverError::ProcessExited("Codex app-server supervisor exited".to_string())
            })?;
        }
    }
}

struct SharedHostProcess {
    control: ProcessControl,
    status: CodexProcessStatus,
    stderr_tail: RedactedStderrTail,
}

async fn spawn_shared_host(
    config: &CodexLaunchConfig,
    arguments: Vec<OsString>,
) -> Result<SharedHostProcess, CodexLaunchError> {
    let process_host = config.process_host.as_ref().map(|host| ProcessHostConfig {
        executable: host.executable.clone(),
        lock_file: shared_host_lock_file(&host.lock_file),
    });
    if let Some(host) = process_host.as_ref() {
        reap_stale_process_host(&host.lock_file)
            .await
            .map_err(CodexLaunchError::ProcessHost)?;
    }
    let mut command = hosted_codex_command(config, process_host.as_ref(), arguments);
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(!cfg!(unix) || process_host.is_none());
    apply_child_environment(&mut command, config);
    configure_process_group(&mut command);
    let mut child = command.spawn().map_err(CodexLaunchError::Spawn)?;
    let process_id = child.id();
    let mut process_guard = SpawnedProcessGuard::new(
        process_id,
        if process_host.is_some() {
            libc::SIGTERM
        } else {
            libc::SIGKILL
        },
    );
    let stderr = child
        .stderr
        .take()
        .ok_or(CodexLaunchError::MissingPipe("shared host stderr"))?;
    let stderr_tail = RedactedStderrTail::new();
    tokio::spawn(capture_stderr(stderr, stderr_tail.clone()));
    let status = CodexProcessStatus::new();
    let control = supervise_child(child, process_id, status.clone());
    process_guard.disarm();
    Ok(SharedHostProcess {
        control,
        status,
        stderr_tail,
    })
}

fn shared_host_lock_file(proxy_lock_file: &Path) -> PathBuf {
    let mut file_name = proxy_lock_file
        .file_name()
        .unwrap_or_default()
        .to_os_string();
    file_name.push(".shared-host");
    proxy_lock_file.with_file_name(file_name)
}

fn default_control_socket_path() -> Result<PathBuf, CodexLaunchError> {
    let codex_home = match std::env::var_os("CODEX_HOME") {
        Some(path) if !path.is_empty() => PathBuf::from(path),
        _ => std::env::var_os("HOME")
            .map(PathBuf::from)
            .map(|home| home.join(".codex"))
            .ok_or_else(|| {
                CodexLaunchError::SharedHostUnavailable(
                    "Codex home directory is unavailable".to_string(),
                )
            })?,
    };
    if !codex_home.is_absolute() {
        return Err(CodexLaunchError::SharedHostUnavailable(
            "Codex home directory must be absolute".to_string(),
        ));
    }
    Ok(codex_home
        .join("app-server-control")
        .join("app-server-control.sock"))
}

async fn connect_shared_codex(
    config: &CodexLaunchConfig,
    socket_path: &Path,
    bridge_version: &str,
    version: CodexVersionProbe,
    shared_host: Option<ProcessControl>,
    stderr_tail: RedactedStderrTail,
) -> Result<SpawnedCodexDriver, CodexLaunchError> {
    let stream = timeout(
        Duration::from_secs(2),
        tokio::net::UnixStream::connect(socket_path),
    )
    .await
    .map_err(|_| {
        CodexLaunchError::SharedHostUnavailable("control socket connection timed out".to_string())
    })?
    .map_err(|_| {
        CodexLaunchError::SharedHostUnavailable(
            "control socket is not accepting connections".to_string(),
        )
    })?;
    let websocket_config = WebSocketConfig::default()
        .max_message_size(Some(MAX_WEBSOCKET_MESSAGE_BYTES))
        .max_frame_size(Some(MAX_WEBSOCKET_MESSAGE_BYTES));
    let (websocket, _) = timeout(
        Duration::from_secs(2),
        client_async_with_config("ws://localhost/rpc", stream, Some(websocket_config)),
    )
    .await
    .map_err(|_| {
        CodexLaunchError::SharedHostIncompatible(
            "control socket WebSocket upgrade timed out".to_string(),
        )
    })?
    .map_err(|_| {
        CodexLaunchError::SharedHostIncompatible(
            "control socket rejected the WebSocket upgrade".to_string(),
        )
    })?;

    let (peer_io, adapter_io) = tokio::io::duplex(SOCKET_ADAPTER_BUFFER_BYTES);
    let (peer_reader, peer_writer) = tokio::io::split(peer_io);
    let process_status = CodexProcessStatus::new();
    let control = supervise_socket_adapter(websocket, adapter_io, process_status.clone());
    let hook_control = control.clone();
    let hook_shared_host = shared_host.clone();
    let shutdown_hook = Arc::new(move || {
        let control = hook_control.clone();
        let shared_host = hook_shared_host.clone();
        Box::pin(async move {
            let client_result = control.shutdown().await;
            if let Some(shared_host) = shared_host {
                let host_result = shared_host.shutdown().await;
                client_result.and(host_result)
            } else {
                client_result
            }
        }) as super::driver::ShutdownFuture
    });
    let peer = CodexPeer::new(
        peer_reader,
        Box::new(peer_writer) as CodexDriverWriter,
        config.incoming_capacity,
    );
    let driver = match CodexAppServerDriver::initialize_with_shutdown(
        peer,
        bridge_version,
        Some(shutdown_hook),
    )
    .await
    {
        Ok(driver) => driver,
        Err(error) => {
            let _ = control.shutdown().await;
            return Err(CodexLaunchError::Initialize(error));
        }
    };
    let app_server_version = match verified_app_server_version(&driver, &config.version_policy) {
        Ok(version) => version,
        Err(error) => {
            let _ = driver.shutdown().await;
            return Err(error);
        }
    };
    if let Err(error) = verify_runtime_contract(&driver, &config.version_policy).await {
        let _ = driver.shutdown().await;
        return Err(error);
    }
    Ok(SpawnedCodexDriver {
        driver,
        version,
        app_server_version,
        transport: CodexAppServerTransport::SharedLocal,
        stderr_tail,
        process_status,
    })
}

fn supervise_socket_adapter(
    websocket: tokio_tungstenite::WebSocketStream<tokio::net::UnixStream>,
    adapter_io: tokio::io::DuplexStream,
    process_status: CodexProcessStatus,
) -> ProcessControl {
    let (shutdown_tx, mut shutdown_rx) = mpsc::channel(1);
    let (completion_tx, completion_rx) = watch::channel(None);
    tokio::spawn(async move {
        let result = run_socket_adapter(websocket, adapter_io, &mut shutdown_rx).await;
        process_status.record(match &result {
            Ok(()) => "shared app-server connection closed".to_string(),
            Err(error) => error.to_string(),
        });
        let _ = completion_tx.send(Some(result));
    });
    ProcessControl {
        shutdown: shutdown_tx,
        completion: completion_rx,
    }
}

async fn run_socket_adapter(
    mut websocket: tokio_tungstenite::WebSocketStream<tokio::net::UnixStream>,
    adapter_io: tokio::io::DuplexStream,
    shutdown: &mut mpsc::Receiver<()>,
) -> Result<(), DriverError> {
    let (adapter_reader, mut adapter_writer) = tokio::io::split(adapter_io);
    let mut adapter_reader = BufReader::new(adapter_reader);
    loop {
        tokio::select! {
            biased;
            outgoing = crate::peer::read_bounded_frame(&mut adapter_reader) => {
                let Some(outgoing) = outgoing.map_err(socket_adapter_io_error)? else {
                    return Ok(());
                };
                let outgoing = String::from_utf8(outgoing).map_err(|_| {
                    DriverError::Protocol("Codex JSON-RPC output was not valid UTF-8".to_string())
                })?;
                websocket
                    .send(Message::Text(outgoing.into()))
                    .await
                    .map_err(socket_adapter_error)?;
            }
            _ = shutdown.recv() => {
                // Drain already-buffered JSON-RPC first, including the
                // post-initialize notification, then drop the local Unix
                // stream. Waiting for the peer's WebSocket close handshake can
                // delay shutdown even though the shared host has no connection
                // state left for this client.
                return Ok(());
            }
            incoming = websocket.next() => {
                match incoming {
                    Some(Ok(Message::Text(payload))) => {
                        if payload.len() > MAX_WEBSOCKET_MESSAGE_BYTES {
                            return Err(DriverError::Protocol(
                                "Codex app-server WebSocket frame exceeded the input limit".to_string(),
                            ));
                        }
                        adapter_writer
                            .write_all(payload.as_bytes())
                            .await
                            .map_err(socket_adapter_io_error)?;
                        adapter_writer
                            .write_all(b"\n")
                            .await
                            .map_err(socket_adapter_io_error)?;
                        adapter_writer.flush().await.map_err(socket_adapter_io_error)?;
                    }
                    Some(Ok(Message::Ping(payload))) => {
                        websocket
                            .send(Message::Pong(payload))
                            .await
                            .map_err(socket_adapter_error)?;
                    }
                    Some(Ok(Message::Pong(_))) => {}
                    Some(Ok(Message::Close(_))) | None => {
                        return Err(DriverError::ProcessExited(
                            "Codex shared app-server connection closed".to_string(),
                        ));
                    }
                    Some(Ok(Message::Binary(_))) => {
                        return Err(DriverError::Protocol(
                            "Codex shared app-server sent an unexpected binary frame".to_string(),
                        ));
                    }
                    Some(Ok(Message::Frame(_))) => {}
                    Some(Err(error)) => return Err(socket_adapter_error(error)),
                }
            }
        }
    }
}

fn socket_adapter_error(error: tokio_tungstenite::tungstenite::Error) -> DriverError {
    DriverError::Unavailable(format!(
        "Codex shared app-server connection failed: {error}"
    ))
}

fn socket_adapter_io_error(error: std::io::Error) -> DriverError {
    DriverError::Unavailable(format!("Codex shared app-server adapter failed: {error}"))
}

async fn spawn_codex_stdio_client(
    config: &CodexLaunchConfig,
    arguments: Vec<OsString>,
    bridge_version: &str,
    version: CodexVersionProbe,
) -> Result<SpawnedCodexDriver, CodexLaunchError> {
    if let Some(host) = config.process_host.as_ref() {
        reap_stale_process_host(&host.lock_file)
            .await
            .map_err(CodexLaunchError::ProcessHost)?;
    }
    let mut command = hosted_codex_command(config, config.process_host.as_ref(), arguments);
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(!cfg!(unix) || config.process_host.is_none());
    apply_child_environment(&mut command, config);
    configure_process_group(&mut command);
    let mut child = command.spawn().map_err(CodexLaunchError::Spawn)?;
    let process_id = child.id();
    let mut process_guard = SpawnedProcessGuard::new(
        process_id,
        if config.process_host.is_some() {
            libc::SIGTERM
        } else {
            libc::SIGKILL
        },
    );
    let stdin = child
        .stdin
        .take()
        .ok_or(CodexLaunchError::MissingPipe("stdin"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or(CodexLaunchError::MissingPipe("stdout"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or(CodexLaunchError::MissingPipe("stderr"))?;
    let stderr_tail = RedactedStderrTail::new();
    let stderr_sink = stderr_tail.clone();
    tokio::spawn(capture_stderr(stderr, stderr_sink));

    let process_status = CodexProcessStatus::new();
    let control = supervise_child(child, process_id, process_status.clone());
    process_guard.disarm();
    let hook_control = control.clone();
    let shutdown_hook = Arc::new(move || {
        let control = hook_control.clone();
        Box::pin(async move { control.shutdown().await }) as super::driver::ShutdownFuture
    });
    let peer = CodexPeer::new(
        stdout,
        Box::new(stdin) as CodexDriverWriter,
        config.incoming_capacity,
    );
    let driver = match CodexAppServerDriver::initialize_with_shutdown(
        peer,
        bridge_version,
        Some(shutdown_hook),
    )
    .await
    {
        Ok(driver) => driver,
        Err(error) => {
            let _ = control.shutdown().await;
            return Err(CodexLaunchError::Initialize(error));
        }
    };
    let app_server_version = match verified_app_server_version(&driver, &config.version_policy) {
        Ok(version) => version,
        Err(error) => {
            let _ = driver.shutdown().await;
            return Err(error);
        }
    };
    if let Err(error) = verify_runtime_contract(&driver, &config.version_policy).await {
        let _ = driver.shutdown().await;
        return Err(error);
    }
    Ok(SpawnedCodexDriver {
        driver,
        version,
        app_server_version,
        transport: config.transport.clone(),
        stderr_tail,
        process_status,
    })
}

fn supervise_child(
    child: Child,
    process_id: Option<u32>,
    process_status: CodexProcessStatus,
) -> ProcessControl {
    let (shutdown_tx, shutdown_rx) = mpsc::channel(1);
    let (completion_tx, completion_rx) = watch::channel(None);
    tokio::spawn(supervise_process(
        child,
        process_id,
        shutdown_rx,
        process_status,
        completion_tx,
    ));
    ProcessControl {
        shutdown: shutdown_tx,
        completion: completion_rx,
    }
}

fn hosted_codex_command(
    config: &CodexLaunchConfig,
    process_host: Option<&ProcessHostConfig>,
    arguments: impl IntoIterator<Item = impl Into<OsString>>,
) -> Command {
    let mut command = match process_host {
        Some(host) => {
            let mut command = Command::new(&host.executable);
            command
                .args(["bridge", "provider-host", "--lock-file"])
                .arg(&host.lock_file)
                .arg("--")
                .arg(&config.executable);
            command
        }
        None => Command::new(&config.executable),
    };
    command.args(arguments.into_iter().map(Into::into));
    command
}

pub fn parse_codex_version(output: &str) -> Result<Version, CodexLaunchError> {
    output
        .split_whitespace()
        .filter_map(|word| {
            let candidate = word
                .trim_matches(|character: char| {
                    !character.is_ascii_alphanumeric()
                        && character != '.'
                        && character != '-'
                        && character != '+'
                })
                .split('(')
                .next()
                .unwrap_or(word);
            let candidate = candidate.strip_prefix('v').unwrap_or(candidate);
            Version::parse(candidate).ok()
        })
        .next()
        .ok_or_else(|| CodexLaunchError::InvalidVersionOutput(redact_stderr_line(output)))
}

fn verified_app_server_version(
    driver: &CodexAppServerDriver<CodexDriverWriter>,
    policy: &CodexVersionPolicy,
) -> Result<Option<Version>, CodexLaunchError> {
    let user_agent = driver.server_user_agent();
    let version = app_server_version_from_user_agent(user_agent);
    match (policy, version.as_ref()) {
        (CodexVersionPolicy::Exact(_), None) => Err(CodexLaunchError::InvalidVersionOutput(
            redact_stderr_line(user_agent),
        )),
        (_, Some(version)) => {
            ensure_supported_version(version, policy)?;
            Ok(Some(version.clone()))
        }
        // Compatible runtimes are accepted by their live read-only contract,
        // not by a forever-fixed initialize user-agent spelling.
        (CodexVersionPolicy::Compatible | CodexVersionPolicy::Any, None) => Ok(None),
    }
}

fn app_server_version_from_user_agent(user_agent: &str) -> Option<Version> {
    user_agent.split_whitespace().find_map(|component| {
        let (_, raw_version) = component.split_once('/')?;
        Version::parse(raw_version.trim_end_matches([';', ')'])).ok()
    })
}

async fn verify_runtime_contract(
    driver: &CodexAppServerDriver<CodexDriverWriter>,
    policy: &CodexVersionPolicy,
) -> Result<(), CodexLaunchError> {
    if !matches!(policy, CodexVersionPolicy::Compatible) {
        return Ok(());
    }
    timeout(RUNTIME_CONTRACT_TIMEOUT, driver.verify_runtime_contract())
        .await
        .map_err(|_| {
            CodexLaunchError::IncompatibleProtocol(DriverError::Unavailable(
                "compatibility probe timed out".to_string(),
            ))
        })?
        .map_err(CodexLaunchError::IncompatibleProtocol)
}

fn ensure_supported_version(
    found: &Version,
    policy: &CodexVersionPolicy,
) -> Result<(), CodexLaunchError> {
    let supported = match policy {
        CodexVersionPolicy::Compatible => is_compatible_codex_version(found),
        CodexVersionPolicy::Exact(required) => found == required,
        CodexVersionPolicy::Any => true,
    };
    if supported {
        return Ok(());
    }
    let required = match policy {
        CodexVersionPolicy::Compatible => format!("Codex {} or newer", minimum_codex_version()),
        CodexVersionPolicy::Exact(required) => required.to_string(),
        CodexVersionPolicy::Any => unreachable!("any Codex version is accepted"),
    };
    Err(CodexLaunchError::UnsupportedVersion {
        found: found.clone(),
        required,
    })
}

/// Removes credentials that belong to Inline or to the host application while
/// retaining normal process discovery (`PATH`, `HOME`, locale, SSH agent,
/// etc.) and Codex/OpenAI authentication. This is intentionally a scrub list,
/// not `env_clear()`: the agent still needs the user's normal shell and project
/// environment for the same UX as the native Codex CLI.
///
/// The policy is applied to both `--version` and `app-server`, because an
/// executable can inspect its environment before the app-server starts.
fn apply_child_environment(command: &mut Command, config: &CodexLaunchConfig) {
    for name in inherited_sensitive_environment_names() {
        command.env_remove(name);
    }
    for variable in &config.environment_remove {
        command.env_remove(variable);
    }
}

fn inherited_sensitive_environment_names() -> Vec<OsString> {
    std::env::vars_os()
        .filter_map(|(name, _)| should_scrub_codex_environment_name(&name).then_some(name))
        .collect()
}

/// Returns whether a host environment variable must be removed before any
/// Codex executable probe or app-server launch. Provider-owned Codex/OpenAI
/// authentication is retained; Inline and unrelated credential material is
/// removed by name without inspecting its value.
pub fn should_scrub_codex_environment_name(name: &std::ffi::OsStr) -> bool {
    let Some(name) = name.to_str() else {
        // Environment names outside the platform's text encoding cannot be
        // classified safely. Fail closed instead of retaining a value that
        // could be a host credential under an opaque name.
        return true;
    };
    let uppercase = name.to_ascii_uppercase();

    // Inline is the host bridge. No Inline variable is a Codex requirement,
    // including future bridge/config secrets that have not been enumerated.
    if uppercase.starts_with("INLINE_") {
        return true;
    }
    if PROVIDER_ENVIRONMENT_PREFIXES
        .iter()
        .any(|prefix| uppercase.starts_with(prefix))
    {
        return false;
    }
    if SENSITIVE_ENVIRONMENT_NAMES.contains(&uppercase.as_str()) {
        return true;
    }

    let components: Vec<_> = uppercase.split('_').collect();
    components.iter().any(|component| {
        matches!(
            *component,
            "TOKEN"
                | "SECRET"
                | "PASSWORD"
                | "PASSWD"
                | "CREDENTIAL"
                | "CREDENTIALS"
                | "KEY"
                | "DSN"
        )
    }) || uppercase.contains("API_KEY")
        || uppercase.contains("ACCESS_KEY")
        || uppercase.contains("PRIVATE_KEY")
        || uppercase.contains("CONNECTION_STRING")
}

async fn supervise_process(
    mut child: Child,
    process_id: Option<u32>,
    mut shutdown_rx: mpsc::Receiver<()>,
    process_status: CodexProcessStatus,
    completion: watch::Sender<Option<Result<(), DriverError>>>,
) {
    tokio::select! {
        result = child.wait() => {
            // Reap any descendants that remained in the provider's own
            // process group after a wrapper exit. Codex tool processes can
            // create separate sessions, so turn cleanup must not rely on this.
            signal_process_group(process_id, libc::SIGKILL);
            process_status.record(exit_description(result));
            let _ = completion.send(Some(Ok(())));
        }
        _ = shutdown_rx.recv() => {
            let result = terminate_process(&mut child, process_id).await;
            process_status.record(match &result {
                Ok(status) => status.to_string(),
                Err(error) => error.to_string(),
            });
            let _ = completion.send(Some(result.map(|_| ())));
        }
    }
}

async fn terminate_process(
    child: &mut Child,
    process_id: Option<u32>,
) -> Result<std::process::ExitStatus, DriverError> {
    signal_process_group(process_id, libc::SIGTERM);
    match timeout(SHUTDOWN_TIMEOUT, child.wait()).await {
        Ok(Ok(status)) => {
            // A wrapper can exit before descendants in its own group.
            signal_process_group(process_id, libc::SIGKILL);
            Ok(status)
        }
        Ok(Err(error)) => {
            signal_process_group(process_id, libc::SIGKILL);
            Err(DriverError::Unavailable(format!(
                "failed to wait for Codex app-server: {error}"
            )))
        }
        Err(_) => {
            signal_process_group(process_id, libc::SIGKILL);
            child.start_kill().map_err(|error| {
                DriverError::Unavailable(format!("failed to stop Codex app-server: {error}"))
            })?;
            child.wait().await.map_err(|error| {
                DriverError::Unavailable(format!("failed to reap Codex app-server: {error}"))
            })
        }
    }
}

/// Owns the short spawn-to-supervisor gap. Tokio's `kill_on_drop` only owns
/// the direct child, while Codex may be launched through a wrapper with its
/// own descendants. Once `supervise_child` owns the process this guard is
/// disarmed and the normal graceful shutdown path becomes authoritative.
struct SpawnedProcessGuard {
    process_id: Option<u32>,
    signal: i32,
    armed: bool,
}

impl SpawnedProcessGuard {
    fn new(process_id: Option<u32>, signal: i32) -> Self {
        Self {
            process_id,
            signal,
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for SpawnedProcessGuard {
    fn drop(&mut self) {
        if self.armed {
            signal_process_group(self.process_id, self.signal);
        }
    }
}

fn exit_description(result: std::io::Result<std::process::ExitStatus>) -> String {
    match result {
        Ok(status) => status.to_string(),
        Err(error) => format!("wait failed: {error}"),
    }
}

async fn capture_stderr(mut stderr: impl AsyncRead + Unpin, sink: RedactedStderrTail) {
    let mut chunk = [0_u8; 1_024];
    let mut line = Vec::with_capacity(STDERR_LINE_BYTES);
    loop {
        match stderr.read(&mut chunk).await {
            Ok(0) => break,
            Ok(read) => {
                for byte in &chunk[..read] {
                    if *byte == b'\n' {
                        flush_stderr_chunk(&mut line, &sink);
                    } else if line.len() < STDERR_LINE_BYTES {
                        // Keep a bounded physical line. Splitting it into
                        // pseudo-lines can detach a secret from its label.
                        line.push(*byte);
                    }
                }
            }
            Err(error) => {
                sink.push(&format!("stderr read failed: {error}"));
                break;
            }
        }
    }
    flush_stderr_chunk(&mut line, &sink);
}

fn flush_stderr_chunk(line: &mut Vec<u8>, sink: &RedactedStderrTail) {
    if line.is_empty() {
        return;
    }
    let display = String::from_utf8_lossy(line);
    sink.push(display.trim_end_matches('\r'));
    line.clear();
}

#[cfg(unix)]
fn configure_process_group(command: &mut Command) {
    use std::os::unix::process::CommandExt;
    command.as_std_mut().process_group(0);
}

#[cfg(not(unix))]
fn configure_process_group(_command: &mut Command) {}

#[cfg(unix)]
fn signal_process_group(process_id: Option<u32>, signal: i32) {
    let Some(process_id) = process_id.and_then(|id| i32::try_from(id).ok()) else {
        return;
    };
    // The child is placed in a process group whose id equals its pid before spawn.
    unsafe {
        libc::kill(-process_id, signal);
    }
}

#[cfg(not(unix))]
fn signal_process_group(_process_id: Option<u32>, _signal: i32) {}

fn redact_stderr_line(line: &str) -> String {
    let lowered = line.to_ascii_lowercase();
    if [
        "authorization",
        "bearer ",
        "api_key",
        "api-key",
        "access_token",
        "refresh_token",
        "cookie",
        "secret",
    ]
    .iter()
    .any(|marker| lowered.contains(marker))
    {
        return "[redacted sensitive Codex diagnostic]".to_string();
    }
    line.chars().take(STDERR_LINE_BYTES).collect()
}

#[cfg(test)]
mod tests {
    use inline_agent_bridge::AgentDriver;

    use super::*;

    #[test]
    fn parses_release_and_prerelease_versions() {
        assert_eq!(
            parse_codex_version("codex-cli 0.121.0").expect("release"),
            Version::new(0, 121, 0)
        );
        assert_eq!(
            parse_codex_version("codex 0.130.0-alpha.3 (build)")
                .expect("prerelease")
                .to_string(),
            "0.130.0-alpha.3"
        );
    }

    #[test]
    fn accepts_the_minimum_and_all_future_codex_versions() {
        assert!(
            ensure_supported_version(&minimum_codex_version(), &CodexVersionPolicy::Compatible)
                .is_ok()
        );
        assert!(
            ensure_supported_version(
                &Version::parse("0.151.0-alpha.7.2").expect("future prerelease"),
                &CodexVersionPolicy::Compatible,
            )
            .is_ok()
        );
        assert!(
            ensure_supported_version(&Version::new(1, 0, 0), &CodexVersionPolicy::Compatible)
                .is_ok()
        );
        assert!(matches!(
            ensure_supported_version(&Version::new(0, 145, 9), &CodexVersionPolicy::Compatible,),
            Err(CodexLaunchError::UnsupportedVersion { .. })
        ));
    }

    #[test]
    fn initialize_version_metadata_is_advisory_for_future_user_agent_formats() {
        assert_eq!(
            app_server_version_from_user_agent("codex_app_server/1.7.3 channel/stable"),
            Some(Version::new(1, 7, 3))
        );
        assert_eq!(
            app_server_version_from_user_agent("Codex App Server future-channel"),
            None
        );
    }

    #[tokio::test]
    async fn version_probe_output_is_bounded_but_fully_drained() {
        let (mut reader, mut writer) = tokio::io::duplex(4 * 1024);
        let payload = vec![b'x'; 80 * 1024];
        let writer_task = tokio::spawn(async move {
            writer.write_all(&payload).await.expect("write noisy probe");
            writer.shutdown().await.expect("close noisy probe");
        });

        let captured = timeout(Duration::from_secs(1), read_probe_output(&mut reader))
            .await
            .expect("probe output should drain")
            .expect("read noisy probe");
        writer_task.await.expect("writer should not block");
        assert_eq!(captured.len(), 64 * 1024);
        assert!(captured.iter().all(|byte| *byte == b'x'));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn cancelling_a_version_probe_stops_its_process_group() {
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().expect("temporary directory");
        let executable = directory.path().join("blocking-codex");
        let descendant_pid_file = directory.path().join("descendant.pid");
        std::fs::write(
            &executable,
            format!(
                "#!/bin/sh\nsleep 30 &\nprintf '%s\\n' \"$!\" > '{}'\nsleep 30\n",
                descendant_pid_file.display()
            ),
        )
        .expect("write fake Codex executable");
        let mut permissions = std::fs::metadata(&executable)
            .expect("fake executable metadata")
            .permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(&executable, permissions).expect("make fake Codex executable");

        let config = CodexLaunchConfig {
            executable,
            version_policy: CodexVersionPolicy::Any,
            ..CodexLaunchConfig::default()
        };
        let probe = tokio::spawn(async move { probe_codex_version(&config).await });
        let descendant_pid = timeout(Duration::from_secs(2), async {
            loop {
                if let Ok(contents) = std::fs::read_to_string(&descendant_pid_file)
                    && let Ok(pid) = contents.trim().parse::<i32>()
                    && pid > 0
                {
                    break pid;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await;
        probe.abort();
        let _ = probe.await;

        // File creation precedes the shell's write. Wait for its complete PID
        // before cancellation, and abort the probe even if startup times out.
        let descendant_pid = descendant_pid.expect("probe descendant should start");
        timeout(Duration::from_secs(2), async {
            loop {
                let result = unsafe { libc::kill(descendant_pid, 0) };
                if result == -1
                    && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("cancelled probe descendant should be gone");
    }

    #[tokio::test]
    async fn compatible_policy_accepts_a_future_user_agent_after_read_only_negotiation() {
        let config = CodexLaunchConfig {
            executable: PathBuf::from("/bin/bash"),
            transport: CodexAppServerTransport::PrivateStdio,
            app_server_args_override: Some(vec![
                OsString::from("-c"),
                OsString::from(
                    "IFS= read -r initialize; printf '%s\\n' '{\"id\":1,\"result\":{\"userAgent\":\"Codex App Server future-channel\"}}'; IFS= read -r initialized; IFS= read -r list; case \"$list\" in *'\"method\":\"thread/list\"'*'\"useStateDbOnly\":true'*) ;; *) exit 41 ;; esac; printf '%s\\n' '{\"id\":2,\"result\":{\"data\":[],\"nextCursor\":null}}'; IFS= read -r read; case \"$read\" in *'\"method\":\"thread/read\"'*) ;; *) exit 42 ;; esac; printf '%s\\n' '{\"id\":3,\"error\":{\"code\":-32600,\"message\":\"thread not found\"}}'; sleep 30",
                ),
            ]),
            version_policy: CodexVersionPolicy::Compatible,
            incoming_capacity: 8,
            environment_remove: CodexLaunchConfig::default().environment_remove,
            process_host: None,
        };

        let spawned = spawn_codex_driver(config, "0.7.6")
            .await
            .expect("capability-compatible future runtime");
        assert_eq!(spawned.app_server_version, None);
        spawned.driver.shutdown().await.expect("shutdown process");
    }

    #[test]
    fn transport_arguments_preserve_the_private_turn_default() {
        assert_eq!(
            CodexLaunchConfig::default().transport,
            CodexAppServerTransport::PrivateStdio
        );
        assert_eq!(
            CodexAppServerTransport::SharedLocal.host_arguments(),
            Some(vec![
                OsString::from("app-server"),
                OsString::from("--listen"),
                OsString::from("unix://"),
            ])
        );
        assert_eq!(CodexAppServerTransport::SharedLocal.stdio_arguments(), None);
        assert_eq!(
            CodexAppServerTransport::PrivateStdio.stdio_arguments(),
            Some(vec![OsString::from("app-server")])
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn shared_socket_adapter_initializes_and_shuts_down_cleanly() {
        use tokio_tungstenite::accept_async;

        let directory = tempfile::tempdir().expect("temporary directory");
        let socket_path = directory.path().join("codex.sock");
        let listener = tokio::net::UnixListener::bind(&socket_path).expect("bind Unix socket");
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.expect("accept Unix client");
            let mut websocket = accept_async(stream).await.expect("upgrade WebSocket");
            let initialize = websocket
                .next()
                .await
                .expect("initialize frame")
                .expect("initialize message");
            let Message::Text(initialize) = initialize else {
                panic!("initialize was not text");
            };
            let initialize: serde_json::Value =
                serde_json::from_str(&initialize).expect("initialize JSON");
            assert_eq!(initialize["method"], "initialize");
            assert_eq!(
                initialize["params"]["clientInfo"]["name"],
                "inline_agent_bridge"
            );
            websocket
                .send(Message::Text(
                    serde_json::json!({
                        "id": initialize["id"],
                        "result": {
                            "userAgent": "codex_app_server/0.150.0-alpha.8"
                        }
                    })
                    .to_string()
                    .into(),
                ))
                .await
                .expect("initialize response");
            let initialized = websocket
                .next()
                .await
                .expect("initialized frame")
                .expect("initialized message");
            let Message::Text(initialized) = initialized else {
                panic!("initialized was not text");
            };
            let initialized: serde_json::Value =
                serde_json::from_str(&initialized).expect("initialized JSON");
            assert_eq!(initialized["method"], "initialized");
            while let Some(message) = websocket.next().await {
                if matches!(message, Ok(Message::Close(_))) {
                    break;
                }
            }
        });
        let version = Version::parse("0.150.0-alpha.8").expect("fixture version");
        let config = CodexLaunchConfig {
            transport: CodexAppServerTransport::SharedLocal,
            version_policy: CodexVersionPolicy::Exact(version.clone()),
            ..CodexLaunchConfig::default()
        };
        let spawned = connect_shared_codex(
            &config,
            &socket_path,
            "0.7.4",
            CodexVersionProbe {
                executable: PathBuf::from("/signed/codex"),
                version: version.clone(),
            },
            None,
            RedactedStderrTail::new(),
        )
        .await
        .expect("shared Codex connection");
        assert_eq!(spawned.transport, CodexAppServerTransport::SharedLocal);
        assert_eq!(spawned.app_server_version, Some(version));
        spawned
            .driver
            .shutdown()
            .await
            .expect("shutdown connection");
        server.await.expect("server task");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn existing_incompatible_control_socket_does_not_look_unavailable() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let socket_path = directory.path().join("codex.sock");
        let listener = tokio::net::UnixListener::bind(&socket_path).expect("bind Unix socket");
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept Unix client");
            stream
                .write_all(
                    b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .await
                .expect("reject WebSocket upgrade");
        });
        let version = Version::parse("0.150.0-alpha.8").expect("fixture version");
        let error = connect_shared_codex(
            &CodexLaunchConfig::default(),
            &socket_path,
            "0.7.4",
            CodexVersionProbe {
                executable: PathBuf::from("/signed/codex"),
                version,
            },
            None,
            RedactedStderrTail::new(),
        )
        .await
        .expect_err("incompatible shared host");
        assert!(matches!(error, CodexLaunchError::SharedHostIncompatible(_)));
        server.await.expect("server task");
    }

    #[tokio::test]
    async fn long_stderr_lines_never_detach_credentials_from_their_labels() {
        let sink = RedactedStderrTail::new();
        let output = format!(
            "{}Authorization: Bearer opaque-private-value\nnext diagnostic\n",
            "x".repeat(490)
        );
        capture_stderr(output.as_bytes(), sink.clone()).await;
        let lines = sink.snapshot();
        assert_eq!(
            lines,
            vec!["[redacted sensitive Codex diagnostic]", "next diagnostic"]
        );
        assert!(!lines.join("\n").contains("opaque-private-value"));
    }

    #[test]
    fn redacts_sensitive_and_bounds_other_diagnostics() {
        assert_eq!(
            redact_stderr_line("Authorization: Bearer private"),
            "[redacted sensitive Codex diagnostic]"
        );
        assert_eq!(
            redact_stderr_line(&"x".repeat(800)).len(),
            STDERR_LINE_BYTES
        );
    }

    #[tokio::test]
    async fn spawns_initializes_and_stops_a_supervised_process_group() {
        let config = CodexLaunchConfig {
            executable: PathBuf::from("/bin/bash"),
            transport: CodexAppServerTransport::PrivateStdio,
            app_server_args_override: Some(vec![
                OsString::from("-c"),
                OsString::from(
                    "IFS= read -r request; printf '%s\\n' '{\"id\":1,\"result\":{\"userAgent\":\"codex_app_server/0.146.0\"}}'; IFS= read -r initialized; sleep 30",
                ),
            ]),
            version_policy: CodexVersionPolicy::Any,
            incoming_capacity: 8,
            environment_remove: CodexLaunchConfig::default().environment_remove,
            process_host: None,
        };
        let spawned = spawn_codex_driver(config, "0.6.2")
            .await
            .expect("spawn fake app-server");
        spawned.driver.shutdown().await.expect("shutdown process");
        spawned
            .driver
            .shutdown()
            .await
            .expect("idempotent shutdown");
        assert!(spawned.process_status.exit_description().is_some());
    }

    #[tokio::test]
    async fn dropping_the_driver_stops_the_supervised_process_group() {
        let config = CodexLaunchConfig {
            executable: PathBuf::from("/bin/bash"),
            transport: CodexAppServerTransport::PrivateStdio,
            app_server_args_override: Some(vec![
                OsString::from("-c"),
                OsString::from(
                    "IFS= read -r request; printf '%s\\n' '{\"id\":1,\"result\":{\"userAgent\":\"codex_app_server/0.146.0\"}}'; IFS= read -r initialized; sleep 30",
                ),
            ]),
            version_policy: CodexVersionPolicy::Any,
            incoming_capacity: 8,
            environment_remove: CodexLaunchConfig::default().environment_remove,
            process_host: None,
        };
        let spawned = spawn_codex_driver(config, "0.6.2")
            .await
            .expect("spawn fake app-server");
        let status = spawned.process_status.clone();
        drop(spawned.driver);

        timeout(Duration::from_secs(5), async {
            while status.exit_description().is_none() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("driver drop should stop child process");
    }

    #[tokio::test]
    async fn fatal_peer_input_stops_the_supervised_process_group() {
        let config = CodexLaunchConfig {
            executable: PathBuf::from("/bin/bash"),
            transport: CodexAppServerTransport::PrivateStdio,
            app_server_args_override: Some(vec![
                OsString::from("-c"),
                OsString::from(
                    "IFS= read -r request; printf '%s\\n' '{\"id\":1,\"result\":{\"userAgent\":\"codex_app_server/0.146.0\"}}'; IFS= read -r initialized; printf '%s\\n' 'not-json'; sleep 30",
                ),
            ]),
            version_policy: CodexVersionPolicy::Any,
            incoming_capacity: 8,
            environment_remove: CodexLaunchConfig::default().environment_remove,
            process_host: None,
        };
        let spawned = spawn_codex_driver(config, "0.6.2")
            .await
            .expect("spawn fake app-server");
        let status = spawned.process_status.clone();

        timeout(Duration::from_secs(5), async {
            while status.exit_description().is_none() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("fatal peer input should stop child process");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn natural_wrapper_exit_kills_its_leaderless_descendants() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let descendant_pid_file = directory.path().join("descendant.pid");
        let config = CodexLaunchConfig {
            executable: PathBuf::from("/bin/bash"),
            transport: CodexAppServerTransport::PrivateStdio,
            app_server_args_override: Some(vec![
                OsString::from("-c"),
                OsString::from(
                    "IFS= read -r request; printf '%s\\n' '{\"id\":1,\"result\":{\"userAgent\":\"codex_app_server/0.146.0\"}}'; IFS= read -r initialized; sleep 30 & printf '%s\\n' \"$!\" > \"$1\"",
                ),
                OsString::from("inline-codex-process-test"),
                descendant_pid_file.as_os_str().to_owned(),
            ]),
            version_policy: CodexVersionPolicy::Any,
            incoming_capacity: 8,
            environment_remove: CodexLaunchConfig::default().environment_remove,
            process_host: None,
        };
        let spawned = spawn_codex_driver(config, "0.6.2")
            .await
            .expect("spawn fake app-server");
        let status = spawned.process_status.clone();
        timeout(Duration::from_secs(5), async {
            while status.exit_description().is_none() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("wrapper should exit");

        let descendant_pid = std::fs::read_to_string(&descendant_pid_file)
            .expect("read descendant pid")
            .trim()
            .parse::<i32>()
            .expect("parse descendant pid");
        timeout(Duration::from_secs(2), async {
            loop {
                let result = unsafe { libc::kill(descendant_pid, 0) };
                if result == -1
                    && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("leaderless descendant should be gone");
    }

    #[test]
    fn environment_scrubber_removes_host_credentials_but_keeps_codex_discovery() {
        for name in [
            "INLINE_TOKEN",
            "INLINE_SECRETS_PATH",
            "INLINE_BRIDGE_CONTROL_TOKEN",
            "GITHUB_TOKEN",
            "AWS_ACCESS_KEY_ID",
            "DATABASE_URL",
            "APP_PRIVATE_KEY",
            "APP_KEY",
            "SENTRY_DSN",
        ] {
            assert!(
                should_scrub_codex_environment_name(std::ffi::OsStr::new(name)),
                "{name} should not reach Codex"
            );
        }

        for name in [
            "PATH",
            "HOME",
            "SSH_AUTH_SOCK",
            "XDG_CONFIG_HOME",
            "CODEX_HOME",
            "OPENAI_API_KEY",
            "OPENAI_BASE_URL",
        ] {
            assert!(
                !should_scrub_codex_environment_name(std::ffi::OsStr::new(name)),
                "{name} is needed for normal Codex operation"
            );
        }
    }

    #[test]
    fn launch_config_can_scrub_an_additional_host_variable() {
        let config = CodexLaunchConfig {
            environment_remove: vec![OsString::from("LOCAL_APP_SESSION")],
            ..CodexLaunchConfig::default()
        };
        let mut command = Command::new("codex");
        apply_child_environment(&mut command, &config);
        assert!(command.as_std().get_envs().any(|(name, value)| {
            name == std::ffi::OsStr::new("LOCAL_APP_SESSION") && value.is_none()
        }));
    }

    #[test]
    fn launch_routes_codex_through_the_bundled_process_host() {
        let config = CodexLaunchConfig {
            executable: "/opt/codex".into(),
            process_host: Some(ProcessHostConfig {
                executable: "/opt/inline".into(),
                lock_file: "/tmp/provider.process.lock".into(),
            }),
            ..CodexLaunchConfig::default()
        };

        let command = hosted_codex_command(
            &config,
            config.process_host.as_ref(),
            [OsString::from("app-server")],
        );
        assert_eq!(
            command.as_std().get_program(),
            std::ffi::OsStr::new("/opt/inline")
        );
        assert_eq!(
            command.as_std().get_args().collect::<Vec<_>>(),
            [
                "bridge",
                "provider-host",
                "--lock-file",
                "/tmp/provider.process.lock",
                "--",
                "/opt/codex",
                "app-server",
            ]
        );
    }

    #[tokio::test]
    #[ignore = "requires an installed Codex CLI binary"]
    async fn installed_codex_app_server_initializes_and_stops() {
        let mut config = CodexLaunchConfig {
            transport: CodexAppServerTransport::PrivateStdio,
            ..CodexLaunchConfig::default()
        };
        if let Some(executable) = std::env::var_os("INLINE_CODEX_SMOKE_EXECUTABLE") {
            config.executable = executable.into();
        }
        let spawned = spawn_codex_driver(config, "0.6.2")
            .await
            .expect("initialize installed Codex app-server");
        assert!(is_compatible_codex_version(&spawned.version.version));
        assert!(
            spawned
                .app_server_version
                .as_ref()
                .map(is_compatible_codex_version)
                .unwrap_or(true)
        );
        let catalog = spawned
            .driver
            .settings_catalog(&std::env::current_dir().expect("current directory"))
            .await
            .expect("load installed Codex settings catalog");
        assert!(!catalog.models.is_empty(), "Codex model/list was empty");
        spawned
            .driver
            .shutdown()
            .await
            .expect("stop installed Codex app-server");
    }

    #[tokio::test]
    #[ignore = "creates an isolated authenticated Codex session and runs a short turn, compaction, and follow-up"]
    async fn installed_codex_usage_and_compaction_round_trip() {
        use inline_agent_bridge::{AgentEvent, SessionSpec, TurnInput, TurnOptions, TurnOutcome};
        async fn finish(mut turn: inline_agent_bridge::StartedTurn) -> (TurnOutcome, bool) {
            tokio::time::timeout(std::time::Duration::from_secs(90), async {
                let mut compaction = false;
                while let Some(event) = turn.events.next().await {
                    match event.expect("provider event") {
                        AgentEvent::ActivityUpsert { activity, .. } => {
                            compaction |= activity.title.contains("context")
                        }
                        AgentEvent::TurnCompleted { outcome, .. } => return (outcome, compaction),
                        _ => {}
                    }
                }
                panic!("provider stream closed before terminal event");
            })
            .await
            .expect("bounded provider turn")
        }
        let mut config = CodexLaunchConfig {
            transport: CodexAppServerTransport::PrivateStdio,
            ..CodexLaunchConfig::default()
        };
        if let Some(executable) = std::env::var_os("INLINE_CODEX_SMOKE_EXECUTABLE") {
            config.executable = executable.into();
        }
        let spawned = spawn_codex_driver(config, "0.7.13-validation")
            .await
            .expect("initialize Codex");
        let workspace = tempfile::tempdir().expect("isolated workspace");
        let catalog = spawned
            .driver
            .settings_catalog(workspace.path())
            .await
            .expect("current catalog");
        assert!(
            catalog
                .models
                .iter()
                .any(|model| model.value == "gpt-6-astra")
        );
        let _usage = spawned
            .driver
            .usage_limits()
            .await
            .expect("read account usage");
        let session = spawned
            .driver
            .start_session(SessionSpec {
                cwd: workspace.path().to_path_buf(),
            })
            .await
            .expect("new isolated session");
        let prompt = || TurnInput {
            text: "Reply with exactly OK. Do not use tools or change files.".to_string(),
            attachments: Vec::new(),
            client_message_id: None,
        };
        let options = || TurnOptions {
            model: Some("gpt-6-astra".to_string()),
            reasoning: Some("low".to_string()),
            ..Default::default()
        };
        let first = spawned
            .driver
            .start_turn(&session, prompt(), options())
            .await
            .expect("first turn");
        assert_eq!(finish(first).await.0, TurnOutcome::Completed);
        let compact = spawned
            .driver
            .compact_session(&session)
            .await
            .expect("start compaction");
        let (outcome, saw_compaction) = finish(compact).await;
        assert_eq!(outcome, TurnOutcome::Completed);
        assert!(saw_compaction, "canonical compaction activity was missing");
        let next = spawned
            .driver
            .start_turn(&session, prompt(), options())
            .await
            .expect("post-compaction turn");
        assert_eq!(finish(next).await.0, TurnOutcome::Completed);
        spawned
            .driver
            .shutdown()
            .await
            .expect("stop isolated provider");
    }
}
