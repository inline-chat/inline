use std::collections::VecDeque;
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use inline_agent_bridge::{DriverError, ProcessHostConfig, reap_stale_process_host};
use semver::Version;
use thiserror::Error;
use tokio::io::AsyncReadExt;
use tokio::process::{Child, ChildStderr, ChildStdin, Command};
use tokio::sync::{mpsc, watch};
use tokio::time::timeout;

use crate::{CodexAppServerDriver, CodexPeer};

const VERSION_PROBE_TIMEOUT: Duration = Duration::from_secs(10);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
const DEFAULT_INCOMING_CAPACITY: usize = 256;
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
    // This is an exact certification pin, despite the legacy function name.
    // 0.146 adds the background-terminal list API required to verify that
    // `/stop` cleanup has drained Codex-managed tool processes, and newer
    // protocol shapes must be certified before they are accepted.
    Version::new(0, 146, 0)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexLaunchConfig {
    pub executable: PathBuf,
    pub app_server_args: Vec<OsString>,
    pub required_version: Option<Version>,
    pub incoming_capacity: usize,
    /// Additional host-specific environment variables removed before launching
    /// Codex. The standard Inline/app-secret policy is always applied too.
    pub environment_remove: Vec<OsString>,
    /// Optional crash-surviving process host supplied by the bundled CLI.
    pub process_host: Option<ProcessHostConfig>,
}

impl Default for CodexLaunchConfig {
    fn default() -> Self {
        Self {
            executable: PathBuf::from("codex"),
            app_server_args: vec![OsString::from("app-server")],
            required_version: Some(minimum_codex_version()),
            incoming_capacity: DEFAULT_INCOMING_CAPACITY,
            environment_remove: vec![
                OsString::from("INLINE_TOKEN"),
                OsString::from("INLINE_SECRETS_PATH"),
                OsString::from("INLINE_DEVICE_ID"),
            ],
            process_host: None,
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
    #[error("Codex {found} is unsupported; this Inline build is certified only with {required}")]
    UnsupportedVersion { found: Version, required: Version },
    #[error("failed to start Codex app-server: {0}")]
    Spawn(#[source] std::io::Error),
    #[error("Codex app-server did not expose {0}")]
    MissingPipe(&'static str),
    #[error("Codex app-server initialization failed: {0}")]
    Initialize(#[from] DriverError),
    #[error("Codex process host recovery failed: {0}")]
    ProcessHost(#[source] std::io::Error),
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
    pub driver: CodexAppServerDriver<ChildStdin>,
    pub version: CodexVersionProbe,
    pub stderr_tail: RedactedStderrTail,
    pub process_status: CodexProcessStatus,
}

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
        .kill_on_drop(true);
    apply_child_environment(&mut command, config);
    configure_process_group(&mut command);
    let mut child = command
        .spawn()
        .map_err(|source| CodexLaunchError::ProbeIo {
            executable: config.executable.clone(),
            source,
        })?;
    let process_id = child.id();
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
    let collected = timeout(VERSION_PROBE_TIMEOUT, async {
        let (status, stdout, stderr) = tokio::try_join!(
            child.wait(),
            read_probe_output(&mut stdout),
            read_probe_output(&mut stderr),
        )?;
        Ok::<_, std::io::Error>((status, stdout, stderr))
    })
    .await;
    let (status, stdout_bytes, stderr_bytes) = match collected {
        Ok(result) => {
            // `codex` can be a wrapper. Once --version has completed, remove
            // any descendant that retained the probe's pipes instead of
            // allowing it to escape the bridge service process.
            signal_process_group(process_id, libc::SIGKILL);
            result.map_err(|source| CodexLaunchError::ProbeIo {
                executable: config.executable.clone(),
                source,
            })?
        }
        Err(_) => {
            let _ = terminate_process(&mut child, process_id).await;
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
    if let Some(required) = config.required_version.as_ref() {
        ensure_supported_version(&version, required)?;
    }
    Ok(CodexVersionProbe {
        executable: config.executable.clone(),
        version,
    })
}

async fn read_probe_output(
    stream: &mut (impl tokio::io::AsyncRead + Unpin),
) -> std::io::Result<Vec<u8>> {
    const MAX_PROBE_OUTPUT_BYTES: u64 = 64 * 1024;

    let mut output = Vec::new();
    stream
        .take(MAX_PROBE_OUTPUT_BYTES)
        .read_to_end(&mut output)
        .await?;
    Ok(output)
}

pub async fn spawn_codex_driver(
    config: CodexLaunchConfig,
    bridge_version: &str,
) -> Result<SpawnedCodexDriver, CodexLaunchError> {
    let version = probe_codex_version(&config).await?;
    if let Some(host) = config.process_host.as_ref() {
        reap_stale_process_host(&host.lock_file)
            .await
            .map_err(CodexLaunchError::ProcessHost)?;
    }
    let mut command = hosted_codex_command(
        &config,
        config.process_host.as_ref(),
        config.app_server_args.iter().cloned(),
    );
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    apply_child_environment(&mut command, &config);
    configure_process_group(&mut command);
    let mut child = command.spawn().map_err(CodexLaunchError::Spawn)?;
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
    let process_id = child.id();
    let stderr_tail = RedactedStderrTail::new();
    let stderr_sink = stderr_tail.clone();
    tokio::spawn(capture_stderr(stderr, stderr_sink));

    let process_status = CodexProcessStatus::new();
    let (shutdown_tx, shutdown_rx) = mpsc::channel(1);
    let (completion_tx, completion_rx) = watch::channel(None);
    tokio::spawn(supervise_process(
        child,
        process_id,
        shutdown_rx,
        process_status.clone(),
        completion_tx,
    ));
    let hook_sender = shutdown_tx.clone();
    let hook_completion = completion_rx.clone();
    let shutdown_hook = Arc::new(move || {
        let shutdown = hook_sender.clone();
        let mut completion = hook_completion.clone();
        Box::pin(async move {
            let _ = shutdown.send(()).await;
            loop {
                if let Some(result) = completion.borrow().clone() {
                    return result;
                }
                completion.changed().await.map_err(|_| {
                    DriverError::ProcessExited("Codex app-server supervisor exited".to_string())
                })?;
            }
        }) as super::driver::ShutdownFuture
    });
    let peer = CodexPeer::new(stdout, stdin, config.incoming_capacity);
    let driver = match CodexAppServerDriver::initialize_with_shutdown(
        peer,
        bridge_version,
        Some(shutdown_hook),
    )
    .await
    {
        Ok(driver) => driver,
        Err(error) => {
            let _ = shutdown_tx.send(()).await;
            let mut completion = completion_rx;
            while completion.borrow().is_none() && completion.changed().await.is_ok() {}
            return Err(CodexLaunchError::Initialize(error));
        }
    };
    Ok(SpawnedCodexDriver {
        driver,
        version,
        stderr_tail,
        process_status,
    })
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

fn ensure_supported_version(found: &Version, required: &Version) -> Result<(), CodexLaunchError> {
    if found != required {
        return Err(CodexLaunchError::UnsupportedVersion {
            found: found.clone(),
            required: required.clone(),
        });
    }
    Ok(())
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
        Ok(Err(error)) => Err(DriverError::Unavailable(format!(
            "failed to wait for Codex app-server: {error}"
        ))),
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

fn exit_description(result: std::io::Result<std::process::ExitStatus>) -> String {
    match result {
        Ok(status) => status.to_string(),
        Err(error) => format!("wait failed: {error}"),
    }
}

async fn capture_stderr(mut stderr: ChildStderr, sink: RedactedStderrTail) {
    let mut chunk = [0_u8; 1_024];
    let mut line = Vec::with_capacity(STDERR_LINE_BYTES);
    loop {
        match stderr.read(&mut chunk).await {
            Ok(0) => break,
            Ok(read) => {
                for byte in &chunk[..read] {
                    if *byte == b'\n' {
                        flush_stderr_chunk(&mut line, &sink);
                    } else {
                        line.push(*byte);
                        if line.len() == STDERR_LINE_BYTES {
                            flush_stderr_chunk(&mut line, &sink);
                        }
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
    fn accepts_only_the_certified_codex_version() {
        assert!(
            ensure_supported_version(&minimum_codex_version(), &minimum_codex_version()).is_ok()
        );
        assert!(matches!(
            ensure_supported_version(&Version::new(0, 144, 9), &minimum_codex_version()),
            Err(CodexLaunchError::UnsupportedVersion { .. })
        ));
        assert!(matches!(
            ensure_supported_version(&Version::new(0, 147, 0), &minimum_codex_version()),
            Err(CodexLaunchError::UnsupportedVersion { .. })
        ));
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
            app_server_args: vec![
                OsString::from("-c"),
                OsString::from(
                    "IFS= read -r request; printf '%s\\n' '{\"id\":1,\"result\":{\"userAgent\":\"fake-codex\"}}'; IFS= read -r initialized; sleep 30",
                ),
            ],
            required_version: None,
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
            app_server_args: vec![
                OsString::from("-c"),
                OsString::from(
                    "IFS= read -r request; printf '%s\\n' '{\"id\":1,\"result\":{\"userAgent\":\"fake-codex\"}}'; IFS= read -r initialized; sleep 30",
                ),
            ],
            required_version: None,
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
            app_server_args: vec![
                OsString::from("-c"),
                OsString::from(
                    "IFS= read -r request; printf '%s\\n' '{\"id\":1,\"result\":{\"userAgent\":\"fake-codex\"}}'; IFS= read -r initialized; printf '%s\\n' 'not-json'; sleep 30",
                ),
            ],
            required_version: None,
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
            app_server_args: vec![
                OsString::from("-c"),
                OsString::from(
                    "IFS= read -r request; printf '%s\\n' '{\"id\":1,\"result\":{\"userAgent\":\"fake-codex\"}}'; IFS= read -r initialized; sleep 30 & printf '%s\\n' \"$!\" > \"$1\"",
                ),
                OsString::from("inline-codex-process-test"),
                descendant_pid_file.as_os_str().to_owned(),
            ],
            required_version: None,
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
        let mut config = CodexLaunchConfig::default();
        if let Some(executable) = std::env::var_os("INLINE_CODEX_SMOKE_EXECUTABLE") {
            config.executable = executable.into();
        }
        let spawned = spawn_codex_driver(config, "0.6.2")
            .await
            .expect("initialize installed Codex app-server");
        assert_eq!(spawned.version.version, minimum_codex_version());
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
}
