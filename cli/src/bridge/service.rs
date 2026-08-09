use std::fs::{self, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, Instant};

#[cfg(unix)]
use std::os::unix::fs::FileTypeExt;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
#[cfg(unix)]
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::watch;

use super::{
    AccountBridgeConfig, AccountBridgeSecrets, BridgePaths, ProviderInstallationConfig,
    ensure_private_dir, safe_diagnostic, set_file_mode,
};

mod definition;
use definition::*;
mod health;
use health::ProviderRuntimeStatus;
pub(super) use health::{ProviderRuntimeState, RuntimeHealth};
mod logging;

const CONTROL_VERSION: u32 = 1;
// Account services initialize provider probes through a bounded shared lane.
// A cold multi-provider restart can legitimately exceed 30 seconds even when
// the provider being set up is healthy.
const READY_TIMEOUT: Duration = Duration::from_secs(90);
const CONTROL_TIMEOUT: Duration = Duration::from_secs(2);
#[cfg(any(target_os = "macos", test))]
const MAX_LOG_FILE_BYTES: u64 = 4 * 1024 * 1024;
const MAX_LOG_READ_BYTES: u64 = 256 * 1024;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct BridgeStatus {
    pub status: String,
    pub installed: bool,
    pub service_loaded: bool,
    pub healthy: bool,
    pub provider: String,
    pub display_name: Option<String>,
    pub bot_username: Option<String>,
    pub workspace: Option<String>,
    pub process_id: Option<u32>,
    pub inline_connected: bool,
    pub provider_ready: bool,
    pub detail: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct BridgeDoctor {
    pub status: String,
    pub config: Check,
    pub secrets: Check,
    pub installed_binary: Check,
    pub provider: Check,
    pub service_definition: Check,
    pub runtime: BridgeStatus,
}

#[derive(Clone, Debug, Serialize)]
pub(super) struct Check {
    pub ok: bool,
    pub detail: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct BridgeLogs {
    pub status: String,
    pub providers: Vec<String>,
    pub lines: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ControlCommand {
    Status,
    Shutdown,
}

#[derive(Deserialize)]
struct ControlRequest {
    version: u32,
    token: String,
    command: ControlCommand,
}

impl std::fmt::Debug for ControlRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ControlRequest")
            .field("version", &self.version)
            .field("token", &"<redacted>")
            .field("command", &self.command)
            .finish()
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ControlResponse {
    version: u32,
    status: String,
    process_id: u32,
    inline_connected: bool,
    provider_ready: bool,
    detail: Option<String>,
    #[serde(default)]
    providers: Vec<ProviderRuntimeStatus>,
}

pub(super) struct ControlServer {
    shutdown_rx: watch::Receiver<bool>,
    task: tokio::task::JoinHandle<()>,
    socket_path: PathBuf,
}

impl ControlServer {
    pub(super) async fn bind(
        socket_path: &Path,
        token: String,
        health: RuntimeHealth,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        #[cfg(not(unix))]
        {
            let _ = (socket_path, token);
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "the bridge control socket is currently supported only on Unix hosts",
            )
            .into());
        }

        #[cfg(unix)]
        {
            if let Ok(metadata) = fs::symlink_metadata(socket_path) {
                if metadata.file_type().is_symlink() || !metadata.file_type().is_socket() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!(
                            "refusing to replace an unsafe bridge control path: {}",
                            socket_path.display()
                        ),
                    )
                    .into());
                }
                match tokio::time::timeout(CONTROL_TIMEOUT, UnixStream::connect(socket_path)).await
                {
                    Ok(Ok(_)) => {
                        return Err(io::Error::new(
                            io::ErrorKind::AddrInUse,
                            "another bridge control server is already running",
                        )
                        .into());
                    }
                    _ => fs::remove_file(socket_path)?,
                }
            }

            let listener = UnixListener::bind(socket_path)?;
            set_file_mode(socket_path, 0o600)?;
            let (shutdown_tx, shutdown_rx) = watch::channel(false);
            let socket_path = socket_path.to_path_buf();
            let task = tokio::spawn(async move {
                loop {
                    let accepted = listener.accept().await;
                    let Ok((stream, _)) = accepted else {
                        break;
                    };
                    let token = token.clone();
                    let health = health.clone();
                    let shutdown_tx = shutdown_tx.clone();
                    tokio::spawn(async move {
                        let _ =
                            handle_control_connection(stream, &token, health, shutdown_tx).await;
                    });
                }
            });
            Ok(Self {
                shutdown_rx,
                task,
                socket_path,
            })
        }
    }

    pub(super) fn shutdown_receiver(&self) -> watch::Receiver<bool> {
        self.shutdown_rx.clone()
    }

    pub(super) async fn close(self) {
        self.task.abort();
        let _ = self.task.await;
        let _ = fs::remove_file(&self.socket_path);
    }
}

#[cfg(unix)]
async fn handle_control_connection(
    stream: UnixStream,
    expected_token: &str,
    health: RuntimeHealth,
    shutdown_tx: watch::Sender<bool>,
) -> io::Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader);
    let mut request = String::new();
    let read = tokio::time::timeout(CONTROL_TIMEOUT, reader.read_line(&mut request))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "bridge control read timed out"))??;
    if read == 0 || request.len() > 8 * 1024 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid bridge control request",
        ));
    }
    let parsed = serde_json::from_str::<ControlRequest>(&request);
    let response = match parsed {
        Ok(request)
            if request.version == CONTROL_VERSION
                && constant_time_eq(request.token.as_bytes(), expected_token.as_bytes()) =>
        {
            match request.command {
                ControlCommand::Status => health_response("running", &health),
                ControlCommand::Shutdown => {
                    let _ = shutdown_tx.send(true);
                    health_response("stopping", &health)
                }
            }
        }
        Ok(_) => ControlResponse {
            version: CONTROL_VERSION,
            status: "unauthorized".to_string(),
            process_id: std::process::id(),
            inline_connected: false,
            provider_ready: false,
            detail: Some("bridge control authentication failed".to_string()),
            providers: Vec::new(),
        },
        Err(_) => ControlResponse {
            version: CONTROL_VERSION,
            status: "invalid_request".to_string(),
            process_id: std::process::id(),
            inline_connected: false,
            provider_ready: false,
            detail: Some("bridge control request was malformed".to_string()),
            providers: Vec::new(),
        },
    };
    let mut bytes = serde_json::to_vec(&response)?;
    bytes.push(b'\n');
    writer.write_all(&bytes).await?;
    writer.shutdown().await
}

fn health_response(status: &str, health: &RuntimeHealth) -> ControlResponse {
    let (inline_connected, provider_ready) = health.snapshot();
    ControlResponse {
        version: CONTROL_VERSION,
        status: status.to_string(),
        process_id: std::process::id(),
        inline_connected,
        provider_ready,
        detail: None,
        providers: health.provider_snapshot(),
    }
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let mut difference = 0_u8;
    for (left, right) in left.iter().zip(right) {
        difference |= left ^ right;
    }
    difference == 0
}

pub(super) fn service_label(owner_user_id: i64) -> String {
    let flavor = if cfg!(debug_assertions) { ".dev" } else { "" };
    format!("chat.inline.agent-bridge{flavor}.{owner_user_id}")
}

pub(super) fn install_service(
    paths: &BridgePaths,
    account: &AccountBridgeConfig,
) -> Result<PathBuf, Box<dyn std::error::Error>> {
    validate_service_paths(paths, account)?;
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = (paths, account);
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "background bridge installation currently requires macOS or Linux",
        )
        .into());
    }

    #[cfg(target_os = "macos")]
    {
        ensure_private_dir(&paths.logs_dir)?;
        ensure_log_file(&paths.stdout_log)?;
        ensure_log_file(&paths.stderr_log)?;
        cap_log_file(&paths.stdout_log)?;
        cap_log_file(&paths.stderr_log)?;
        install_stable_binary(&paths.installed_binary)?;

        let plist_path = service_definition_path(&account.service_label)?;
        let plist = render_launch_agent_plist(account, paths)?;
        write_private_bytes(&plist_path, plist.as_bytes(), 0o600)?;

        let domain = launchd_domain()?;
        for label in &account.superseded_service_labels {
            unload_launch_agent(&domain, label)?;
            disable_launch_agent(&domain, label)?;
        }
        unload_launch_agent(&domain, &account.service_label)?;
        enable_launch_agent(&domain, &account.service_label)?;
        bootstrap_launch_agent(&domain, &plist_path)?;
        Ok(plist_path)
    }

    #[cfg(target_os = "linux")]
    {
        for label in &account.superseded_service_labels {
            retire_systemd_user_service(label)?;
        }
        install_stable_binary(&paths.installed_binary)?;
        let unit_path = service_definition_path(&account.service_label)?;
        let unit = render_systemd_user_unit(account, paths)?;
        write_private_bytes(&unit_path, unit.as_bytes(), 0o600)?;
        run_systemctl(["--user", "daemon-reload"])?;
        let unit_name = systemd_unit_name(&account.service_label);
        run_systemctl(["--user", "enable", &unit_name])?;
        // `start` is a no-op for an active unit. Setup must restart here so a
        // second provider or changed provider configuration is loaded now.
        run_systemctl(["--user", "restart", &unit_name])?;
        Ok(unit_path)
    }
}

pub(super) fn refresh_stable_binary(paths: &BridgePaths, updated_binary: &Path) -> io::Result<()> {
    if !super::is_executable_file(updated_binary) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "updated Inline binary is missing or not executable: {}",
                updated_binary.display()
            ),
        ));
    }
    install_stable_binary_from(updated_binary, &paths.installed_binary)
}

pub(super) async fn start_service(
    paths: &BridgePaths,
    account: &AccountBridgeConfig,
    secrets: &AccountBridgeSecrets,
) -> Result<(), Box<dyn std::error::Error>> {
    validate_service_paths(paths, account)?;
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = (paths, account, secrets);
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "background bridge lifecycle currently requires macOS or Linux",
        )
        .into());
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    {
        let definition = service_definition_path(&account.service_label)?;
        if !definition.is_file() {
            install_service(paths, account)?;
            return wait_for_account_running(paths, secrets, READY_TIMEOUT).await;
        }
    }

    #[cfg(target_os = "macos")]
    {
        let domain = launchd_domain()?;
        enable_launch_agent(&domain, &account.service_label)?;
        if !launchd_loaded(&domain, &account.service_label) {
            let plist_path = service_definition_path(&account.service_label)?;
            run_launchctl(["bootstrap", &domain, plist_path.to_string_lossy().as_ref()])?;
        } else {
            run_launchctl(["kickstart", &format!("{domain}/{}", account.service_label)])?;
        }
        wait_for_account_running(paths, secrets, READY_TIMEOUT).await
    }

    #[cfg(target_os = "linux")]
    {
        run_systemctl([
            "--user",
            "start",
            &systemd_unit_name(&account.service_label),
        ])?;
        wait_for_account_running(paths, secrets, READY_TIMEOUT).await
    }
}

pub(super) async fn stop_service(
    paths: &BridgePaths,
    account: &AccountBridgeConfig,
    secrets: &AccountBridgeSecrets,
    installation: &ProviderInstallationConfig,
) -> Result<BridgeStatus, Box<dyn std::error::Error>> {
    #[cfg(target_os = "macos")]
    let mut stopped_cleanly = false;
    if let Ok(response) = control_request(paths, secrets, ControlCommand::Shutdown).await
        && response.status == "stopping"
    {
        // The account runtime gives provider tasks up to 15 seconds to drain.
        // Wait longer than that before falling back to launchd/systemd so a
        // normal CLI restart cannot interrupt ACP process-group cleanup.
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            if control_request(paths, secrets, ControlCommand::Status)
                .await
                .is_err()
            {
                #[cfg(target_os = "macos")]
                {
                    stopped_cleanly = true;
                }
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }

    #[cfg(target_os = "macos")]
    {
        let domain = launchd_domain()?;
        if !stopped_cleanly && launchd_loaded(&domain, &account.service_label) {
            run_launchctl([
                "kill",
                "SIGTERM",
                &format!("{domain}/{}", account.service_label),
            ])?;
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        unload_launch_agent(&domain, &account.service_label)?;
        disable_launch_agent(&domain, &account.service_label)?;
    }
    #[cfg(target_os = "linux")]
    {
        run_systemctl(["--user", "stop", &systemd_unit_name(&account.service_label)])?;
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = stopped_cleanly;
    }
    Ok(stopped_status(installation, service_loaded(account)))
}

pub(super) async fn restart_service(
    paths: &BridgePaths,
    account: &AccountBridgeConfig,
    secrets: &AccountBridgeSecrets,
) -> Result<(), Box<dyn std::error::Error>> {
    validate_service_paths(paths, account)?;
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    {
        let definition = service_definition_path(&account.service_label)?;
        if !definition.is_file() {
            install_service(paths, account)?;
            return wait_for_account_running(paths, secrets, READY_TIMEOUT).await;
        }
    }
    #[cfg(target_os = "macos")]
    {
        let installation = account.providers.first().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "bridge account has no configured providers",
            )
        })?;
        let _ = stop_service(paths, account, secrets, installation).await?;
        let domain = launchd_domain()?;
        enable_launch_agent(&domain, &account.service_label)?;
        let plist_path = service_definition_path(&account.service_label)?;
        run_launchctl(["bootstrap", &domain, plist_path.to_string_lossy().as_ref()])?;
    }
    #[cfg(target_os = "linux")]
    {
        run_systemctl([
            "--user",
            "restart",
            &systemd_unit_name(&account.service_label),
        ])?;
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = (paths, account, secrets);
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "background bridge lifecycle currently requires macOS or Linux",
        )
        .into());
    }
    wait_for_account_running(paths, secrets, READY_TIMEOUT).await
}

// The command integration owns the public CLI surface; keep this API buildable while it is wired.
#[allow(dead_code)]
pub(super) async fn uninstall_service(
    paths: &BridgePaths,
    account: &AccountBridgeConfig,
    secrets: &AccountBridgeSecrets,
    installation: &ProviderInstallationConfig,
) -> Result<PathBuf, Box<dyn std::error::Error>> {
    validate_service_paths(paths, account)?;
    let definition = service_definition_path(&account.service_label)?;
    let _ = stop_service(paths, account, secrets, installation).await?;

    #[cfg(target_os = "macos")]
    {
        let domain = launchd_domain()?;
        unload_launch_agent(&domain, &account.service_label)?;
        disable_launch_agent(&domain, &account.service_label)?;
    }
    #[cfg(target_os = "linux")]
    {
        retire_systemd_user_service(&account.service_label)?;
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "background bridge uninstallation currently requires macOS or Linux",
        )
        .into());
    }

    remove_service_definition(&definition)?;
    #[cfg(target_os = "linux")]
    run_systemctl(["--user", "daemon-reload"])?;
    Ok(definition)
}

pub(super) async fn status(
    paths: &BridgePaths,
    account: &AccountBridgeConfig,
    secrets: &AccountBridgeSecrets,
    installation: &ProviderInstallationConfig,
) -> BridgeStatus {
    match control_request(paths, secrets, ControlCommand::Status).await {
        Ok(response) => {
            let provider_state = provider_state(&response, &installation.installation_id);
            let provider_inline_connected =
                provider_inline_connected(&response, &installation.installation_id);
            let provider_connection_detail =
                provider_detail(&response, &installation.installation_id);
            let provider_ready = matches!(provider_state, ProviderRuntimeState::Ready);
            let account_running = response.status == "running";
            let detail = response.detail.or(provider_connection_detail).or_else(|| {
                (!provider_ready).then(|| {
                    format!(
                        "{} is {}",
                        installation.display_name,
                        provider_state.status()
                    )
                })
            });
            BridgeStatus {
                status: if account_running {
                    provider_state.status().to_string()
                } else {
                    response.status
                },
                installed: true,
                service_loaded: service_loaded(account),
                healthy: account_running && provider_inline_connected && provider_ready,
                provider: installation.provider_id.clone(),
                display_name: Some(installation.display_name.clone()),
                bot_username: Some(installation.bot_username.clone()),
                workspace: Some(installation.workspace.display().to_string()),
                process_id: Some(response.process_id),
                inline_connected: provider_inline_connected,
                provider_ready,
                detail: with_service_lifecycle_detail(detail),
            }
        }
        Err(error) => {
            let loaded = service_loaded(account);
            let process_running = service_process_running(account);
            BridgeStatus {
                status: if process_running {
                    "unhealthy"
                } else {
                    "stopped"
                }
                .to_string(),
                installed: true,
                service_loaded: loaded,
                healthy: false,
                provider: installation.provider_id.clone(),
                display_name: Some(installation.display_name.clone()),
                bot_username: Some(installation.bot_username.clone()),
                workspace: Some(installation.workspace.display().to_string()),
                process_id: None,
                inline_connected: false,
                provider_ready: false,
                detail: with_service_lifecycle_detail(
                    process_running.then(|| safe_diagnostic(&error.to_string())),
                ),
            }
        }
    }
}

fn with_service_lifecycle_detail(detail: Option<String>) -> Option<String> {
    merge_service_lifecycle_detail(detail, service_lifecycle_detail())
}

fn merge_service_lifecycle_detail(
    detail: Option<String>,
    lifecycle: Option<String>,
) -> Option<String> {
    match (detail, lifecycle) {
        (Some(detail), Some(lifecycle)) => Some(format!("{detail} {lifecycle}")),
        (Some(detail), None) => Some(detail),
        (None, Some(lifecycle)) => Some(lifecycle),
        (None, None) => None,
    }
}

#[cfg(target_os = "linux")]
fn service_lifecycle_detail() -> Option<String> {
    Some(linux_service_lifecycle_detail(linux_linger_enabled()))
}

#[cfg(not(target_os = "linux"))]
fn service_lifecycle_detail() -> Option<String> {
    None
}

#[cfg(any(target_os = "linux", test))]
fn linux_service_lifecycle_detail(linger_enabled: Option<bool>) -> String {
    match linger_enabled {
        Some(true) => "Linux systemd user service starts after login; linger is enabled, so the user manager may remain active without an active login.".to_string(),
        Some(false) => {
            "Linux systemd user service starts after login; linger is disabled.".to_string()
        }
        None => "Linux systemd user service starts after login; linger status could not be determined."
            .to_string(),
    }
}

#[cfg(target_os = "linux")]
fn linux_linger_enabled() -> Option<bool> {
    let user_id = unsafe { libc::geteuid() }.to_string();
    let output = Command::new("/usr/bin/loginctl")
        .args(["show-user", &user_id, "--property=Linger", "--value"])
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| parse_linux_linger_enabled(&String::from_utf8_lossy(&output.stdout)))?
}

#[cfg(any(target_os = "linux", test))]
fn parse_linux_linger_enabled(output: &str) -> Option<bool> {
    match output.trim().to_ascii_lowercase().as_str() {
        "yes" | "true" => Some(true),
        "no" | "false" => Some(false),
        _ => None,
    }
}

fn provider_state(response: &ControlResponse, installation_id: &str) -> ProviderRuntimeState {
    response
        .providers
        .iter()
        .find(|provider| provider.installation_id == installation_id)
        .map(|provider| provider.state)
        .unwrap_or_else(|| {
            if response.providers.is_empty() && response.provider_ready {
                ProviderRuntimeState::Ready
            } else {
                ProviderRuntimeState::Unavailable
            }
        })
}

fn provider_inline_connected(response: &ControlResponse, installation_id: &str) -> bool {
    response
        .providers
        .iter()
        .find(|provider| provider.installation_id == installation_id)
        .and_then(|provider| provider.inline_connected)
        .unwrap_or(response.inline_connected)
}

fn provider_detail(response: &ControlResponse, installation_id: &str) -> Option<String> {
    response
        .providers
        .iter()
        .find(|provider| provider.installation_id == installation_id)
        .and_then(|provider| provider.detail.clone())
}

pub(super) fn not_installed_status() -> BridgeStatus {
    BridgeStatus {
        status: "not_installed".to_string(),
        installed: false,
        service_loaded: false,
        healthy: false,
        provider: "agent".to_string(),
        display_name: None,
        bot_username: None,
        workspace: None,
        process_id: None,
        inline_connected: false,
        provider_ready: false,
        detail: Some(
            "run `inline setup codex` first; OpenCode, Claude, and Amp setup are experimental"
                .to_string(),
        ),
    }
}

pub(super) async fn doctor(
    paths: &BridgePaths,
    account: &AccountBridgeConfig,
    secrets: &AccountBridgeSecrets,
    installation: &ProviderInstallationConfig,
) -> BridgeDoctor {
    let definition = service_definition_path(&account.service_label).ok();
    let runtime = status(paths, account, secrets, installation).await;
    let provider = match super::probe_configured_provider_async_with_runtime(
        &installation.provider_id,
        &installation.executable,
        installation.provider_runtime.clone(),
    )
    .await
    {
        Ok(probe) => Check {
            ok: true,
            detail: if let Some(runtime) = probe.provider_runtime {
                format!(
                    "{} via {} ({}) — {}",
                    probe.executable.display(),
                    runtime.display(),
                    probe.display_name,
                    probe.version
                )
            } else {
                format!(
                    "{} ({}) — {}",
                    probe.executable.display(),
                    probe.display_name,
                    probe.version
                )
            },
        },
        Err(error) => Check {
            ok: false,
            detail: safe_diagnostic(&error),
        },
    };
    let checks = [
        paths.config.is_file(),
        paths.secrets.is_file()
            && !secrets.providers.is_empty()
            && !secrets.control_token.is_empty(),
        account.service_binary.is_file(),
        provider.ok,
        definition.as_ref().is_some_and(|path| path.is_file()),
        runtime.healthy,
    ];
    BridgeDoctor {
        status: if checks.into_iter().all(|check| check) {
            "healthy"
        } else {
            "needs_attention"
        }
        .to_string(),
        config: file_check(&paths.config),
        secrets: Check {
            ok: paths.secrets.is_file()
                && !secrets.providers.is_empty()
                && !secrets.control_token.is_empty(),
            detail: if paths.secrets.is_file() {
                "protected credentials are present".to_string()
            } else {
                "protected credentials are missing".to_string()
            },
        },
        installed_binary: executable_check(&account.service_binary),
        provider,
        service_definition: definition.as_deref().map(file_check).unwrap_or(Check {
            ok: false,
            detail: "service definition path is unavailable".to_string(),
        }),
        runtime,
    }
}

pub(super) fn logs(
    paths: &BridgePaths,
    account: Option<&AccountBridgeConfig>,
    maximum_lines: usize,
) -> BridgeLogs {
    let providers = account
        .map(|account| {
            account
                .providers
                .iter()
                .map(|provider| provider.provider_id.clone())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    #[cfg(target_os = "linux")]
    if let Some(account) = account {
        let requested_lines = maximum_lines;
        let maximum_lines = requested_lines.to_string();
        let output = Command::new("journalctl")
            .args([
                "--user",
                "--unit",
                &systemd_unit_name(&account.service_label),
                "--no-pager",
                "--lines",
                &maximum_lines,
                "--output",
                "cat",
            ])
            .output();
        let lines = output
            .ok()
            .filter(|output| output.status.success())
            .map(|output| {
                String::from_utf8_lossy(&output.stdout)
                    .lines()
                    .rev()
                    .take(requested_lines)
                    .collect::<Vec<_>>()
                    .into_iter()
                    .rev()
                    .map(safe_diagnostic)
                    .collect()
            })
            .unwrap_or_default();
        return BridgeLogs {
            status: "ok".to_string(),
            providers,
            lines,
        };
    }

    let _ = account;
    let mut lines = Vec::new();
    for (label, path) in [("stdout", &paths.stdout_log), ("stderr", &paths.stderr_log)] {
        if let Ok(tail) = read_log_tail(path) {
            lines.extend(
                tail.lines()
                    .rev()
                    .take(maximum_lines)
                    .collect::<Vec<_>>()
                    .into_iter()
                    .rev()
                    .map(|line| format!("{label}: {}", safe_diagnostic(line))),
            );
        }
    }
    if lines.len() > maximum_lines {
        lines.drain(..lines.len() - maximum_lines);
    }
    BridgeLogs {
        status: "ok".to_string(),
        providers,
        lines,
    }
}

pub(super) fn prepare_runtime_logs(paths: &BridgePaths) -> io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        ensure_private_dir(&paths.logs_dir)?;
        ensure_log_file(&paths.stdout_log)?;
        ensure_log_file(&paths.stderr_log)?;
        cap_log_file(&paths.stdout_log)?;
        cap_log_file(&paths.stderr_log)?;
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = paths;
    }
    Ok(())
}

pub(super) fn install_runtime_logging(paths: &BridgePaths) -> io::Result<()> {
    prepare_runtime_logs(paths)?;
    logging::install_bounded_process_logging(paths)
}

fn read_log_tail(path: &Path) -> io::Result<String> {
    let mut file = fs::File::open(path)?;
    let length = file.metadata()?.len();
    let start = length.saturating_sub(MAX_LOG_READ_BYTES);
    file.seek(SeekFrom::Start(start))?;
    let mut bytes = Vec::with_capacity((length - start) as usize);
    file.read_to_end(&mut bytes)?;
    if start > 0
        && let Some(newline) = bytes.iter().position(|byte| *byte == b'\n')
    {
        bytes.drain(..=newline);
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

#[cfg(any(target_os = "macos", test))]
fn cap_log_file(path: &Path) -> io::Result<()> {
    if path
        .metadata()
        .is_ok_and(|metadata| metadata.len() > MAX_LOG_FILE_BYTES)
    {
        OpenOptions::new().write(true).truncate(true).open(path)?;
    }
    Ok(())
}

pub(super) async fn wait_for_provider_ready(
    paths: &BridgePaths,
    account: &AccountBridgeConfig,
    installation: &ProviderInstallationConfig,
    secrets: &AccountBridgeSecrets,
) -> Result<BridgeStatus, Box<dyn std::error::Error>> {
    wait_for_provider_ready_with_timeout(paths, account, installation, secrets, READY_TIMEOUT).await
}

async fn wait_for_provider_ready_with_timeout(
    paths: &BridgePaths,
    account: &AccountBridgeConfig,
    installation: &ProviderInstallationConfig,
    secrets: &AccountBridgeSecrets,
    timeout: Duration,
) -> Result<BridgeStatus, Box<dyn std::error::Error>> {
    let deadline = Instant::now() + timeout;
    let mut last_error = None;
    while Instant::now() < deadline {
        match control_request(paths, secrets, ControlCommand::Status).await {
            Ok(response) => {
                let state = provider_state(&response, &installation.installation_id);
                let inline_connected =
                    provider_inline_connected(&response, &installation.installation_id);
                let provider_connection_detail =
                    provider_detail(&response, &installation.installation_id);
                if response.status == "running"
                    && inline_connected
                    && matches!(state, ProviderRuntimeState::Ready)
                {
                    return Ok(BridgeStatus {
                        status: "running".to_string(),
                        installed: true,
                        service_loaded: service_loaded(account),
                        healthy: true,
                        provider: installation.provider_id.clone(),
                        display_name: Some(installation.display_name.clone()),
                        bot_username: Some(installation.bot_username.clone()),
                        workspace: Some(installation.workspace.display().to_string()),
                        process_id: Some(response.process_id),
                        inline_connected: true,
                        provider_ready: true,
                        detail: None,
                    });
                }
                last_error = response.detail.or(provider_connection_detail).or_else(|| {
                    Some(format!(
                        "{} is {}",
                        installation.display_name,
                        state.status()
                    ))
                });
            }
            Err(error) => last_error = Some(safe_diagnostic(&error.to_string())),
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        format!(
            "bridge did not become healthy within {} seconds{}",
            timeout.as_secs(),
            last_error
                .map(|detail| format!(": {detail}"))
                .unwrap_or_default()
        ),
    )
    .into())
}

fn account_is_running(response: &ControlResponse) -> bool {
    response.status == "running"
}

async fn wait_for_account_running(
    paths: &BridgePaths,
    secrets: &AccountBridgeSecrets,
    timeout: Duration,
) -> Result<(), Box<dyn std::error::Error>> {
    let deadline = Instant::now() + timeout;
    let mut last_error = None;
    while Instant::now() < deadline {
        match control_request(paths, secrets, ControlCommand::Status).await {
            Ok(response) if account_is_running(&response) => return Ok(()),
            Ok(response) => {
                last_error = response.detail.or(Some(response.status));
            }
            Err(error) => last_error = Some(safe_diagnostic(&error.to_string())),
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        format!(
            "bridge control plane did not start within {} seconds{}",
            timeout.as_secs(),
            last_error
                .map(|detail| format!(": {detail}"))
                .unwrap_or_default()
        ),
    )
    .into())
}

#[cfg(unix)]
async fn control_request(
    paths: &BridgePaths,
    secrets: &AccountBridgeSecrets,
    command: ControlCommand,
) -> Result<ControlResponse, Box<dyn std::error::Error>> {
    let mut stream =
        tokio::time::timeout(CONTROL_TIMEOUT, UnixStream::connect(&paths.control_socket))
            .await
            .map_err(|_| {
                io::Error::new(io::ErrorKind::TimedOut, "bridge control connect timed out")
            })??;
    let request = serde_json::json!({
        "version": CONTROL_VERSION,
        "token": secrets.control_token,
        "command": match command {
            ControlCommand::Status => "status",
            ControlCommand::Shutdown => "shutdown",
        },
    });
    let mut bytes = serde_json::to_vec(&request)?;
    bytes.push(b'\n');
    stream.write_all(&bytes).await?;
    stream.shutdown().await?;
    let mut reader = BufReader::new(stream);
    let mut response = String::new();
    tokio::time::timeout(CONTROL_TIMEOUT, reader.read_line(&mut response))
        .await
        .map_err(|_| {
            io::Error::new(io::ErrorKind::TimedOut, "bridge control response timed out")
        })??;
    let response: ControlResponse = serde_json::from_str(&response)?;
    if response.version != CONTROL_VERSION || response.status == "unauthorized" {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "bridge control authentication failed",
        )
        .into());
    }
    Ok(response)
}

#[cfg(not(unix))]
async fn control_request(
    _paths: &BridgePaths,
    _secrets: &AccountBridgeSecrets,
    _command: ControlCommand,
) -> Result<ControlResponse, Box<dyn std::error::Error>> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "Unix control sockets are unavailable",
    )
    .into())
}

fn stopped_status(installation: &ProviderInstallationConfig, loaded: bool) -> BridgeStatus {
    BridgeStatus {
        status: "stopped".to_string(),
        installed: true,
        service_loaded: loaded,
        healthy: false,
        provider: installation.provider_id.clone(),
        display_name: Some(installation.display_name.clone()),
        bot_username: Some(installation.bot_username.clone()),
        workspace: Some(installation.workspace.display().to_string()),
        process_id: None,
        inline_connected: false,
        provider_ready: false,
        detail: None,
    }
}

fn file_check(path: &Path) -> Check {
    Check {
        ok: path.is_file(),
        detail: if path.is_file() {
            path.display().to_string()
        } else {
            format!("missing: {}", path.display())
        },
    }
}

fn executable_check(path: &Path) -> Check {
    Check {
        ok: super::is_executable_file(path),
        detail: if super::is_executable_file(path) {
            path.display().to_string()
        } else {
            format!("missing or not executable: {}", path.display())
        },
    }
}

#[cfg(target_os = "macos")]
fn ensure_log_file(path: &Path) -> io::Result<()> {
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)?;
    set_file_mode(path, 0o600)
}

fn install_stable_binary(destination: &Path) -> io::Result<()> {
    install_stable_binary_from(&std::env::current_exe()?, destination)
}

fn install_stable_binary_from(source: &Path, destination: &Path) -> io::Result<()> {
    let source = fs::canonicalize(source)?;
    if source == destination {
        return Ok(());
    }
    let parent = destination.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "installed binary has no parent",
        )
    })?;
    ensure_private_dir(parent)?;
    let temporary = destination.with_extension("next");
    fs::copy(&source, &temporary)?;
    set_file_mode(&temporary, 0o755)?;
    fs::rename(&temporary, destination)?;
    set_file_mode(destination, 0o755)
}

fn write_private_bytes(path: &Path, bytes: &[u8], mode: u32) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "service file has no parent"))?;
    fs::create_dir_all(parent)?;
    let temporary = path.with_extension("service.tmp");
    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(mode);
    }
    let mut file = options.open(&temporary)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    set_file_mode(&temporary, mode)?;
    fs::rename(&temporary, path)?;
    set_file_mode(path, mode)
}

#[allow(dead_code)]
fn remove_service_definition(path: &Path) -> io::Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "refusing to remove an unsafe bridge service definition: {}",
                path.display()
            ),
        ));
    }
    fs::remove_file(path)
}

#[cfg(target_os = "macos")]
fn launchd_domain() -> io::Result<String> {
    let output = Command::new("id").arg("-u").output()?;
    if !output.status.success() {
        return Err(io::Error::other("could not determine the current user id"));
    }
    let uid = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if uid.is_empty() || !uid.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "current user id is invalid",
        ));
    }
    Ok(format!("gui/{uid}"))
}

#[cfg(target_os = "macos")]
fn launchd_loaded(domain: &str, label: &str) -> bool {
    Command::new("launchctl")
        .args(["print", &format!("{domain}/{label}")])
        .output()
        .is_ok_and(|output| output.status.success())
}

#[cfg(target_os = "macos")]
fn unload_launch_agent(domain: &str, label: &str) -> io::Result<()> {
    if !launchd_loaded(domain, label) {
        return Ok(());
    }
    if let Err(error) = run_launchctl(["bootout", &format!("{domain}/{label}")])
        && launchd_loaded(domain, label)
    {
        return Err(error);
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    while launchd_loaded(domain, label) {
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!("the previous bridge LaunchAgent {label} did not unload in time"),
            ));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn disable_launch_agent(domain: &str, label: &str) -> io::Result<()> {
    run_launchctl(["disable", &format!("{domain}/{label}")])?;
    let output = run_launchctl(["print-disabled", domain])?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    if !launchd_output_indicates_disabled(&stdout, label) {
        return Err(io::Error::other(format!(
            "LaunchAgent {label} was not persistently disabled"
        )));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn enable_launch_agent(domain: &str, label: &str) -> io::Result<()> {
    run_launchctl(["enable", &format!("{domain}/{label}")]).map(|_| ())
}

#[cfg(target_os = "macos")]
fn service_loaded(account: &AccountBridgeConfig) -> bool {
    launchd_domain()
        .ok()
        .is_some_and(|domain| launchd_loaded(&domain, &account.service_label))
}

#[cfg(target_os = "macos")]
fn service_process_running(account: &AccountBridgeConfig) -> bool {
    let Ok(domain) = launchd_domain() else {
        return false;
    };
    let Ok(output) = Command::new("launchctl")
        .args(["print", &format!("{domain}/{}", account.service_label)])
        .output()
    else {
        return false;
    };
    output.status.success()
        && launchd_output_indicates_running(&String::from_utf8_lossy(&output.stdout))
}

#[cfg(target_os = "linux")]
fn service_loaded(account: &AccountBridgeConfig) -> bool {
    Command::new("systemctl")
        .args([
            "--user",
            "is-enabled",
            &systemd_unit_name(&account.service_label),
        ])
        .output()
        .is_ok_and(|output| output.status.success())
}

#[cfg(target_os = "linux")]
fn retire_systemd_user_service(label: &str) -> io::Result<()> {
    let unit = systemd_unit_name(label);
    let enabled = Command::new("systemctl")
        .args(["--user", "is-enabled", &unit])
        .status()
        .is_ok_and(|status| status.success());
    let active = Command::new("systemctl")
        .args(["--user", "is-active", "--quiet", &unit])
        .status()
        .is_ok_and(|status| status.success());
    if enabled {
        run_systemctl(["--user", "disable", "--now", &unit])?;
    } else if active {
        run_systemctl(["--user", "stop", &unit])?;
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn service_process_running(account: &AccountBridgeConfig) -> bool {
    Command::new("systemctl")
        .args([
            "--user",
            "is-active",
            "--quiet",
            &systemd_unit_name(&account.service_label),
        ])
        .status()
        .is_ok_and(|status| status.success())
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn service_loaded(_account: &AccountBridgeConfig) -> bool {
    false
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn service_process_running(_account: &AccountBridgeConfig) -> bool {
    false
}

#[cfg(any(target_os = "macos", test))]
fn launchd_output_indicates_running(output: &str) -> bool {
    output.contains("\n\tstate = running\n")
}

#[cfg(any(target_os = "macos", test))]
fn launchd_output_indicates_disabled(output: &str, label: &str) -> bool {
    output.lines().any(|line| {
        line.split_once("=>").is_some_and(|(key, value)| {
            key.trim().trim_matches('"') == label
                && matches!(
                    value.trim().trim_end_matches([',', ';']).trim(),
                    "true" | "disabled"
                )
        })
    })
}

#[cfg(target_os = "macos")]
fn run_launchctl<const N: usize>(arguments: [&str; N]) -> io::Result<Output> {
    let output = Command::new("launchctl").args(arguments).output()?;
    if output.status.success() {
        return Ok(output);
    }
    Err(io::Error::other(format!(
        "launchctl failed: {}",
        safe_diagnostic(&String::from_utf8_lossy(&output.stderr))
    )))
}

#[cfg(target_os = "macos")]
fn bootstrap_launch_agent(domain: &str, plist_path: &Path) -> io::Result<()> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match run_launchctl(["bootstrap", domain, plist_path.to_string_lossy().as_ref()]) {
            Ok(_) => return Ok(()),
            Err(_) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(error) => return Err(error),
        }
    }
}

#[cfg(target_os = "linux")]
fn run_systemctl<const N: usize>(arguments: [&str; N]) -> io::Result<Output> {
    let output = Command::new("systemctl").args(arguments).output()?;
    if output.status.success() {
        return Ok(output);
    }
    Err(io::Error::other(format!(
        "systemctl failed: {}",
        safe_diagnostic(&String::from_utf8_lossy(&output.stderr))
    )))
}

#[cfg(test)]
#[path = "service/tests.rs"]
mod tests;
