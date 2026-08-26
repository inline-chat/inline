//! Provider-neutral launch, driver, and process-status boundary.

use std::io::Read;
use std::process::Stdio;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

#[cfg(unix)]
use std::os::unix::process::CommandExt;

use super::ProviderInstallationConfig;
use super::{
    AccountBridgeConfig, BridgePaths, adapter::prepare_pinned_adapter, read_optional_json,
};
use inline_agent_bridge::{
    AgentDriver, ApprovalDecision, DriverCapabilities, DriverFuture, DriverResult,
    DriverSettingsCatalog, ProcessHostConfig, ProviderSessionId, QuestionAnswer, ResumeSessionSpec,
    SessionSpec, StartedTurn, TurnId, TurnInput, TurnOptions,
};
use inline_agent_driver_acp::{
    AcpDistribution, AcpDriver, AcpLaunchDescriptor, AcpProcessStatus, VersionDiscovery,
    provider_support, provider_support_catalog, should_scrub_acp_environment_name,
    spawn_acp_driver,
};
#[cfg(test)]
use inline_agent_driver_codex::CodexVersionPolicy;
use inline_agent_driver_codex::{
    CodexAppServerDriver, CodexAppServerTransport, CodexDriverWriter, CodexLaunchConfig,
    CodexProcessStatus, CodexRuntimeDiscoveryConfig, discover_codex_turn_runtime,
    is_certified_codex_version, parse_codex_version, should_scrub_codex_environment_name,
    spawn_codex_driver,
};
use sha2::{Digest, Sha256};

const PROVIDER_PROBE_TIMEOUT: Duration = Duration::from_secs(30);
const PROVIDER_PROBE_OUTPUT_BYTES: usize = 64 * 1024;
const PROVIDER_PROBE_DRAIN_TIMEOUT: Duration = Duration::from_secs(1);
const AMP_ADAPTER_INCOMPATIBLE_MESSAGE: &str = "the pinned Amp ACP adapter is incompatible with the installed Amp CLI; update Amp or Inline, then rerun setup";

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct ProviderProbe {
    pub(super) provider_id: &'static str,
    pub(super) display_name: &'static str,
    pub(super) executable: std::path::PathBuf,
    pub(super) provider_runtime: Option<std::path::PathBuf>,
    pub(super) version: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct BridgeProviderSetupDescriptor {
    pub(crate) provider_id: &'static str,
    pub(crate) display_name: &'static str,
    pub(crate) runtime_executable: &'static str,
}

pub(crate) fn bridge_provider_setup_descriptors() -> Vec<BridgeProviderSetupDescriptor> {
    let mut descriptors = vec![BridgeProviderSetupDescriptor {
        provider_id: "codex",
        display_name: "Codex",
        runtime_executable: "codex",
    }];
    descriptors.extend(provider_support_catalog().iter().map(|support| {
        BridgeProviderSetupDescriptor {
            provider_id: support.provider_id,
            display_name: support.display_name,
            runtime_executable: support.login_program,
        }
    }));
    descriptors
}

#[derive(Clone, Copy, Debug)]
pub(super) struct ProviderProfileAsset {
    pub(super) provider_id: &'static str,
    pub(super) file_name: &'static str,
    pub(super) mime_type: &'static str,
    pub(super) bytes: &'static [u8],
}

pub(super) fn provider_profile_asset(provider_id: &str) -> Option<ProviderProfileAsset> {
    let (file_name, bytes): (&str, &[u8]) = match provider_id {
        "codex" => (
            "inline-codex-avatar.png",
            include_bytes!("../../assets/provider-avatars/codex.png"),
        ),
        "claude" => (
            "inline-claude-avatar.png",
            include_bytes!("../../assets/provider-avatars/claude.png"),
        ),
        "opencode" => (
            "inline-opencode-avatar.png",
            include_bytes!("../../assets/provider-avatars/opencode.png"),
        ),
        "amp" => (
            "inline-amp-avatar.png",
            include_bytes!("../../assets/provider-avatars/amp.png"),
        ),
        _ => return None,
    };
    Some(ProviderProfileAsset {
        provider_id: match provider_id {
            "codex" => "codex",
            "claude" => "claude",
            "opencode" => "opencode",
            "amp" => "amp",
            _ => unreachable!(),
        },
        file_name,
        mime_type: "image/png",
        bytes,
    })
}

pub(super) fn validate_provider_profile_asset(asset: ProviderProfileAsset) -> Result<(), String> {
    const PNG_SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";
    if asset.bytes.len() < 24 || asset.bytes.len() > 512 * 1024 {
        return Err(format!(
            "{} avatar has an invalid byte size",
            asset.provider_id
        ));
    }
    if &asset.bytes[..8] != PNG_SIGNATURE || &asset.bytes[12..16] != b"IHDR" {
        return Err(format!("{} avatar is not a valid PNG", asset.provider_id));
    }
    let width = u32::from_be_bytes(asset.bytes[16..20].try_into().expect("PNG width"));
    let height = u32::from_be_bytes(asset.bytes[20..24].try_into().expect("PNG height"));
    if width != 512 || height != 512 {
        return Err(format!(
            "{} avatar must be a 512 x 512 PNG",
            asset.provider_id
        ));
    }
    Ok(())
}

pub(super) fn provider_profile_asset_digest(asset: ProviderProfileAsset) -> String {
    let digest = Sha256::digest(asset.bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub(super) fn provider_display_name(provider_id: &str) -> Option<&'static str> {
    match provider_id {
        "codex" => Some("Codex"),
        provider_id => provider_support(provider_id).map(|support| support.display_name),
    }
}

/// Verifies the exact executable setup will persist, its version surface, and
/// the provider-owned login state without reading provider credential files.
pub(super) fn probe_provider(provider_id: &str) -> Result<ProviderProbe, String> {
    let (display_name, executable, aliases) = if provider_id == "codex" {
        ("Codex", "codex", &[][..])
    } else {
        let support = verified_acp_support(provider_id)?;
        (
            support.display_name,
            support.executable,
            support.executable_aliases,
        )
    };
    let candidates = super::find_named_executables(executable, aliases);
    if candidates.is_empty() {
        let names = std::iter::once(executable)
            .chain(aliases.iter().copied())
            .collect::<Vec<_>>()
            .join(" or ");
        return Err(format!(
            "could not find {display_name} ({names}) on PATH; install and authenticate {display_name}, then rerun setup"
        ));
    }
    let mut last_error = None;
    for candidate in candidates {
        match probe_configured_provider(provider_id, &candidate) {
            Ok(probe) => return Ok(probe),
            Err(error) => last_error = Some(error),
        }
    }
    Err(last_error.unwrap_or_else(|| {
        format!("no working authenticated {display_name} installation was found on PATH")
    }))
}

pub(super) async fn prepare_setup_provider(
    paths: &BridgePaths,
    provider_id: &str,
    json: bool,
    allow_install: bool,
) -> Result<ProviderProbe, String> {
    if provider_id == "codex" {
        let runtime = discover_codex_turn_runtime(&CodexRuntimeDiscoveryConfig {
            configured_executable: configured_provider_executable(paths, provider_id)?,
            ..CodexRuntimeDiscoveryConfig::default()
        })
            .await
            .map_err(|_| {
                "could not find a compatible Codex runtime on PATH or in the signed ChatGPT application; install or update Codex/ChatGPT, sign in there, then retry"
                    .to_string()
            })?;
        if !runtime.capabilities().existing_turn_driver {
            return Err(format!(
                "Codex {} is not certified for this Inline bridge; update Inline or Codex/ChatGPT, then retry",
                runtime.version()
            ));
        }
        return probe_configured_provider_async(provider_id, runtime.executable()).await;
    }
    let Some(support) = provider_support(provider_id) else {
        return probe_provider(provider_id);
    };
    let Some(adapter) = prepare_pinned_adapter(paths, support, allow_install)? else {
        return probe_provider(provider_id);
    };
    if adapter.installed_now && !json {
        println!(
            "Installed verified {} ACP adapter {}.",
            support.display_name, adapter.version
        );
    }
    probe_configured_provider(provider_id, &adapter.executable)
}

fn configured_provider_executable(
    paths: &BridgePaths,
    provider_id: &str,
) -> Result<Option<std::path::PathBuf>, String> {
    let account = read_optional_json::<AccountBridgeConfig>(&paths.config)
        .map_err(|error| format!("could not read the existing bridge configuration: {error}"))?;
    Ok(account.and_then(|account| {
        account
            .providers
            .into_iter()
            .find(|provider| provider.provider_id == provider_id)
            .map(|provider| provider.executable)
            .filter(|executable| !executable.as_os_str().is_empty())
    }))
}

pub(super) fn probe_configured_provider(
    provider_id: &str,
    executable: &std::path::Path,
) -> Result<ProviderProbe, String> {
    probe_configured_provider_with_runtime(provider_id, executable, None)
}

fn probe_configured_provider_with_runtime(
    provider_id: &str,
    executable: &std::path::Path,
    configured_runtime: Option<&std::path::Path>,
) -> Result<ProviderProbe, String> {
    if provider_id == "codex" {
        let version = probe_command(provider_id, executable, &["--version"], "Codex version")?;
        if !version.starts_with("codex-cli ") {
            return Err(format!(
                "the executable at {} did not identify itself as Codex",
                executable.display()
            ));
        }
        let parsed_version = parse_codex_version(&version)
            .map_err(|error| format!("Codex version is invalid: {error}"))?;
        if !is_certified_codex_version(&parsed_version) {
            return Err(format!(
                "Codex {parsed_version} is not certified for this Inline bridge; update Inline or Codex/ChatGPT, then retry"
            ));
        }
        let auth = probe_command(
            provider_id,
            executable,
            &["login", "status"],
            "Codex authentication",
        )?;
        if !auth.to_ascii_lowercase().contains("logged in") {
            return Err("Codex is not authenticated; run `codex login` and retry".to_string());
        }
        return Ok(ProviderProbe {
            provider_id: "codex",
            display_name: "Codex",
            executable: executable.to_path_buf(),
            provider_runtime: None,
            version,
        });
    }

    let support = verified_acp_support(provider_id)?;
    let version = match support.version_discovery {
        VersionDiscovery::Command(arguments) => probe_command(
            provider_id,
            executable,
            arguments,
            &format!("{} version", support.display_name),
        )?,
        VersionDiscovery::InitializeAgentInfo => match support.distribution {
            AcpDistribution::NpmAdapter(adapter) if adapter.is_verified_install_pin() => {
                adapter.registry_version.to_string()
            }
            AcpDistribution::EmbeddedAdapter(adapter) => adapter.version.to_string(),
            _ => {
                return Err(format!(
                    "{} has no verified version source",
                    support.display_name
                ));
            }
        },
    };
    if provider_id == "opencode" && !looks_like_version(&version) {
        return Err(format!(
            "the executable at {} returned an unrecognized OpenCode version",
            executable.display()
        ));
    }
    let mut provider_runtime = None;
    if provider_id == "opencode" {
        let auth = probe_command(
            provider_id,
            executable,
            &["auth", "list"],
            "OpenCode authentication",
        )?;
        let normalized = strip_ansi(&auth).to_ascii_lowercase();
        if normalized.contains("0 credentials") && !normalized.contains("environment variable") {
            let models = probe_command(
                provider_id,
                executable,
                &["models"],
                "OpenCode model availability",
            )?;
            if !has_opencode_model(&models) {
                return Err(
                "OpenCode has no configured credentials or available anonymous models; run `opencode auth login` and retry"
                    .to_string(),
                );
            }
        }
    } else if let Some(auth_probe) = support.auth_probe {
        let auth_executable = super::resolve_executable(std::path::Path::new(auth_probe.program))
            .map_err(|_| {
            format!(
                "{} requires the {} CLI; install it and run its login flow first",
                support.display_name, auth_probe.program
            )
        })?;
        let auth = probe_command(
            provider_id,
            &auth_executable,
            auth_probe.arguments,
            &format!("{} authentication", support.display_name),
        )?;
        if provider_id == "claude"
            && serde_json::from_str::<serde_json::Value>(&auth)
                .ok()
                .and_then(|value| value.get("loggedIn").and_then(serde_json::Value::as_bool))
                != Some(true)
        {
            return Err(
                "Claude is not authenticated; run `claude` and `/login`, then retry".to_string(),
            );
        }
    } else if provider_id == "amp" {
        let amp = if let Some(runtime) = configured_runtime {
            if !super::is_executable_file(runtime) {
                return Err(format!(
                    "the configured Amp CLI at {} is unavailable; rerun setup",
                    runtime.display()
                ));
            }
            runtime.to_path_buf()
        } else {
            super::resolve_executable(std::path::Path::new("amp")).map_err(|_| {
                "Amp requires the installed `amp` CLI on PATH; install and authenticate Amp, then rerun setup"
                    .to_string()
            })?
        };
        let _ = probe_command(provider_id, &amp, &["--version"], "Amp CLI version")?;
        let help = probe_command(provider_id, &amp, &["--help"], "Amp CLI compatibility")?;
        validate_amp_adapter_cli_contract(&help)?;
        probe_command_allow_empty(
            provider_id,
            &amp,
            &[
                "threads",
                "search",
                "__inline_bridge_auth_probe_no_match__",
                "--limit",
                "1",
            ],
            "Amp authentication and compatibility",
        )?;
        provider_runtime = Some(amp);
    }
    Ok(ProviderProbe {
        provider_id: support.provider_id,
        display_name: support.display_name,
        executable: executable.to_path_buf(),
        provider_runtime,
        version,
    })
}

pub(super) async fn probe_configured_provider_async(
    provider_id: &str,
    executable: &std::path::Path,
) -> Result<ProviderProbe, String> {
    probe_configured_provider_async_with_runtime(provider_id, executable, None).await
}

/// Revalidates the exact persisted runtime immediately before the background
/// service launches it. Codex discovery includes exact-version protocol
/// certification and, for a ChatGPT-bundled executable, OpenAI signature
/// verification; it must not silently fall through to another installation.
pub(super) async fn probe_service_provider_async(
    provider_id: &str,
    executable: &std::path::Path,
) -> Result<ProviderProbe, String> {
    if provider_id == "codex" {
        discover_codex_turn_runtime(&CodexRuntimeDiscoveryConfig {
            configured_executable: Some(executable.to_path_buf()),
            search_path: false,
            search_chatgpt_app: false,
        })
        .await
        .map_err(|_| {
            "the configured Codex runtime is no longer signed and compatible; rerun Inline agent setup"
                .to_string()
        })?;
    }
    probe_configured_provider_async(provider_id, executable).await
}

pub(super) async fn probe_configured_provider_async_with_runtime(
    provider_id: &str,
    executable: &std::path::Path,
    configured_runtime: Option<std::path::PathBuf>,
) -> Result<ProviderProbe, String> {
    let provider_id = provider_id.to_string();
    let executable = executable.to_path_buf();
    tokio::task::spawn_blocking(move || {
        probe_configured_provider_with_runtime(
            &provider_id,
            &executable,
            configured_runtime.as_deref(),
        )
    })
    .await
    .map_err(|error| format!("provider probe task failed: {error}"))?
}

/// Whether the long-lived service should repeat setup's provider probe before
/// starting ACP. Amp is already verified during setup, and current Amp builds
/// can leave informational commands such as `--version` blocked indefinitely
/// when launched by a background service. The ACP adapter itself is the
/// authoritative runtime check and reports turn failures normally.
pub(super) fn requires_service_prelaunch_probe(provider_id: &str) -> bool {
    provider_id != "amp"
}

fn validate_amp_adapter_cli_contract(help: &str) -> Result<(), String> {
    let help = strip_ansi(help);
    let supports_archive_flag = help.contains("--no-archive-after-execute");
    let supports_modes = ["low", "medium", "high", "ultra"]
        .iter()
        .all(|mode| help.contains(mode));
    if supports_archive_flag && supports_modes {
        Ok(())
    } else {
        Err(AMP_ADAPTER_INCOMPATIBLE_MESSAGE.to_string())
    }
}

pub(super) fn provider_probe_requires_bridge_update(provider_id: &str, error: &str) -> bool {
    provider_id == "amp" && error == AMP_ADAPTER_INCOMPATIBLE_MESSAGE
}

fn verified_acp_support(
    provider_id: &str,
) -> Result<&'static inline_agent_driver_acp::AcpProviderSupport, String> {
    let support = provider_support(provider_id)
        .ok_or_else(|| format!("unsupported agent provider: {provider_id}"))?;
    if let AcpDistribution::NpmAdapter(adapter) = support.distribution
        && !adapter.is_verified_install_pin()
    {
        return Err(format!(
            "{} setup is unavailable because adapter {}@{} has no verified integrity pin; Inline will not install or trust it unattended",
            support.display_name, adapter.package, adapter.registry_version
        ));
    }
    if let AcpDistribution::EmbeddedAdapter(adapter) = support.distribution
        && (!adapter.checksum.starts_with("sha256-") || adapter.source_revision.len() != 40)
    {
        return Err(format!(
            "{} setup is unavailable because its embedded adapter pin is incomplete",
            support.display_name
        ));
    }
    Ok(support)
}

fn probe_command(
    provider_id: &str,
    executable: &std::path::Path,
    arguments: &[&str],
    label: &str,
) -> Result<String, String> {
    probe_command_inner(provider_id, executable, arguments, label, false)
}

fn probe_command_allow_empty(
    provider_id: &str,
    executable: &std::path::Path,
    arguments: &[&str],
    label: &str,
) -> Result<String, String> {
    probe_command_inner(provider_id, executable, arguments, label, true)
}

fn probe_command_inner(
    provider_id: &str,
    executable: &std::path::Path,
    arguments: &[&str],
    label: &str,
    allow_empty: bool,
) -> Result<String, String> {
    probe_command_inner_with_timeout(
        provider_id,
        executable,
        arguments,
        label,
        allow_empty,
        PROVIDER_PROBE_TIMEOUT,
    )
}

fn probe_command_inner_with_timeout(
    provider_id: &str,
    executable: &std::path::Path,
    arguments: &[&str],
    label: &str,
    allow_empty: bool,
    timeout: Duration,
) -> Result<String, String> {
    let mut command = std::process::Command::new(executable);
    command
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    command.process_group(0);
    for (name, _) in std::env::vars_os() {
        let should_scrub = if provider_id == "codex" {
            should_scrub_codex_environment_name(&name)
        } else {
            should_scrub_acp_environment_name(&name, provider_id)
        };
        if should_scrub {
            command.env_remove(name);
        }
    }
    let mut child = command
        .spawn()
        .map_err(|error| format!("{label} probe could not start: {error}"))?;
    let process_id = child.id();
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| format!("{label} probe stdout was unavailable"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| format!("{label} probe stderr was unavailable"))?;
    let stdout = read_probe_stream(stdout);
    let stderr = read_probe_stream(stderr);
    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|error| format!("{label} probe status failed: {error}"))?
        {
            break status;
        }
        if Instant::now() >= deadline {
            terminate_probe_process(&mut child, process_id);
            return Err(format!(
                "{label} probe timed out after {} seconds",
                timeout.as_secs_f64()
            ));
        }
        thread::sleep(Duration::from_millis(20));
    };
    let stdout = receive_probe_stream(&stdout, &mut child, process_id);
    let stderr = receive_probe_stream(&stderr, &mut child, process_id);
    let value = format_probe_output(stdout, stderr);
    if !status.success() {
        return Err(format!(
            "{label} probe failed: {}",
            super::safe_diagnostic(&value)
        ));
    }
    if value.is_empty() && !allow_empty {
        return Err(format!("{label} probe returned no result"));
    }
    Ok(value)
}

fn read_probe_stream<R: Read + Send + 'static>(mut reader: R) -> mpsc::Receiver<(Vec<u8>, bool)> {
    let (sender, receiver) = mpsc::sync_channel(1);
    thread::spawn(move || {
        let mut output = Vec::new();
        let mut truncated = false;
        let mut chunk = [0_u8; 8 * 1024];
        loop {
            match reader.read(&mut chunk) {
                Ok(0) => break,
                Ok(count) => {
                    let remaining = PROVIDER_PROBE_OUTPUT_BYTES.saturating_sub(output.len());
                    let retained = remaining.min(count);
                    output.extend_from_slice(&chunk[..retained]);
                    truncated |= retained < count;
                }
                Err(_) => break,
            }
        }
        let _ = sender.send((output, truncated));
    });
    receiver
}

fn receive_probe_stream(
    receiver: &mpsc::Receiver<(Vec<u8>, bool)>,
    child: &mut std::process::Child,
    process_id: u32,
) -> (Vec<u8>, bool) {
    if let Ok(output) = receiver.recv_timeout(PROVIDER_PROBE_DRAIN_TIMEOUT) {
        return output;
    }
    terminate_probe_process(child, process_id);
    receiver
        .recv_timeout(PROVIDER_PROBE_DRAIN_TIMEOUT)
        .unwrap_or_else(|_| (Vec::new(), true))
}

fn format_probe_output(stdout: (Vec<u8>, bool), stderr: (Vec<u8>, bool)) -> String {
    let (stdout, stdout_truncated) = stdout;
    let (stderr, stderr_truncated) = stderr;
    let stdout = String::from_utf8_lossy(&stdout);
    let stderr = String::from_utf8_lossy(&stderr);
    let mut value = format!("{stdout}\n{stderr}").trim().to_string();
    if stdout_truncated || stderr_truncated {
        value.push_str("\n[additional provider probe output omitted]");
    }
    value
}

fn terminate_probe_process(child: &mut std::process::Child, process_id: u32) {
    #[cfg(unix)]
    unsafe {
        libc::kill(-(process_id as i32), libc::SIGTERM);
    }
    let _ = child.kill();
    let _ = child.wait();
    #[cfg(unix)]
    unsafe {
        libc::kill(-(process_id as i32), libc::SIGKILL);
    }
}

fn looks_like_version(value: &str) -> bool {
    value.trim().split('.').take(3).count() >= 2
        && value
            .trim()
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'+' | b' '))
}

fn has_opencode_model(value: &str) -> bool {
    strip_ansi(value).lines().any(|line| {
        line.trim()
            .split_once('/')
            .is_some_and(|(provider, model)| {
                !provider.trim().is_empty() && !model.trim().is_empty()
            })
    })
}

fn strip_ansi(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    let mut bytes = value.bytes();
    while let Some(byte) = bytes.next() {
        if byte == 0x1b {
            if bytes.next() == Some(b'[') {
                for byte in bytes.by_ref() {
                    if (0x40..=0x7e).contains(&byte) {
                        break;
                    }
                }
            }
        } else {
            output.push(char::from(byte));
        }
    }
    output
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum ProviderLaunch {
    Codex(CodexLaunchConfig),
    Acp(AcpLaunchDescriptor),
}

impl ProviderLaunch {
    pub(super) fn from_installation(
        installation: &ProviderInstallationConfig,
    ) -> Result<Self, String> {
        let process_host = ProcessHostConfig {
            executable: std::env::current_exe().map_err(|error| {
                format!("could not locate the Inline bridge executable: {error}")
            })?,
            lock_file: installation.state_dir.join("provider.process.lock"),
        };
        match installation.provider_id.as_str() {
            "codex" => {
                // Codex continuity deliberately uses one private provider
                // epoch as the exclusive session writer. Its ambiguous-send
                // safety and `/close` handoff both depend on shutdown ending
                // that epoch. SharedLocal remains dark until simultaneous
                // observation/control can reconcile all external traffic.
                let mut config = CodexLaunchConfig {
                    transport: CodexAppServerTransport::PrivateStdio,
                    ..CodexLaunchConfig::default()
                };
                if installation.executable.as_os_str().is_empty() {
                    config.executable = super::resolve_executable(&config.executable)
                        .map_err(|error| error.to_string())?;
                } else {
                    config.executable = installation.executable.clone();
                }
                config.process_host = Some(process_host);
                Ok(Self::Codex(config))
            }
            provider_id => {
                let support = provider_support(provider_id)
                    .ok_or_else(|| format!("unsupported agent provider: {provider_id}"))?;
                let executable = (!installation.executable.as_os_str().is_empty())
                    .then(|| installation.executable.clone());
                let mut descriptor = support.launch_descriptor(executable);
                if provider_id == "amp" {
                    descriptor.provider_runtime = Some(
                        if let Some(runtime) = installation
                            .provider_runtime
                            .as_ref()
                            .filter(|runtime| super::is_executable_file(runtime))
                        {
                            runtime.clone()
                        } else {
                            let search_path = if installation.provider_path.trim().is_empty() {
                                std::env::var_os("PATH")
                                    .ok_or_else(|| "Amp provider PATH is unavailable".to_string())?
                            } else {
                                std::ffi::OsString::from(&installation.provider_path)
                            };
                            super::resolve_executable_in_search_path(
                                std::path::Path::new("amp"),
                                &search_path,
                            )
                            .map_err(|_| {
                                "the installed Amp CLI is unavailable; rerun setup".to_string()
                            })?
                        },
                    );
                }
                descriptor.process_host = Some(process_host);
                Ok(Self::Acp(descriptor))
            }
        }
    }

    pub(super) fn provider_name(&self) -> &'static str {
        match self {
            Self::Codex(_) => "Codex",
            Self::Acp(descriptor) => {
                provider_display_name(descriptor.provider_id.as_str()).unwrap_or("Agent")
            }
        }
    }

    pub(super) async fn spawn(
        &self,
        bridge_version: &str,
    ) -> Result<SpawnedProvider, Box<dyn std::error::Error>> {
        match self {
            Self::Codex(config) => {
                let spawned = spawn_codex_driver(config.clone(), bridge_version).await?;
                Ok(SpawnedProvider {
                    driver: ProviderDriver::Codex(spawned.driver),
                    process_status: ProviderProcessStatus::Codex(spawned.process_status),
                })
            }
            Self::Acp(descriptor) => {
                let spawned = spawn_acp_driver(descriptor.clone(), bridge_version).await?;
                Ok(SpawnedProvider {
                    driver: ProviderDriver::Acp(Box::new(spawned.driver)),
                    process_status: ProviderProcessStatus::Acp(spawned.process_status),
                })
            }
        }
    }
}

#[derive(Clone, Debug)]
pub(super) enum ProviderProcessStatus {
    Codex(CodexProcessStatus),
    Acp(AcpProcessStatus),
}

impl ProviderProcessStatus {
    pub(super) fn exit_description(&self) -> Option<String> {
        match self {
            Self::Codex(status) => status.exit_description(),
            Self::Acp(status) => status.exit_description(),
        }
    }

    pub(super) async fn wait_for_exit(self) -> String {
        loop {
            if let Some(description) = self.exit_description() {
                return description;
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
    }
}

#[derive(Debug)]
pub(super) struct SpawnedProvider {
    pub(super) driver: ProviderDriver,
    pub(super) process_status: ProviderProcessStatus,
}

#[derive(Debug)]
pub(super) enum ProviderDriver {
    Codex(CodexAppServerDriver<CodexDriverWriter>),
    Acp(Box<AcpDriver>),
}

impl AgentDriver for ProviderDriver {
    fn capabilities(&self) -> DriverCapabilities {
        match self {
            Self::Codex(driver) => driver.capabilities(),
            Self::Acp(driver) => driver.capabilities(),
        }
    }

    fn configure_host_tools(
        &self,
        configuration: inline_agent_bridge::HostToolConfiguration,
    ) -> DriverResult<()> {
        match self {
            Self::Codex(driver) => driver.configure_host_tools(configuration),
            Self::Acp(driver) => driver.configure_host_tools(configuration),
        }
    }

    fn settings_catalog<'a>(
        &'a self,
        cwd: &'a std::path::Path,
    ) -> DriverFuture<'a, DriverSettingsCatalog> {
        match self {
            Self::Codex(driver) => driver.settings_catalog(cwd),
            Self::Acp(driver) => driver.settings_catalog(cwd),
        }
    }

    fn session_commands<'a>(
        &'a self,
        session_id: &'a ProviderSessionId,
    ) -> DriverFuture<'a, Vec<inline_agent_bridge::DriverCommand>> {
        match self {
            Self::Codex(driver) => driver.session_commands(session_id),
            Self::Acp(driver) => driver.session_commands(session_id),
        }
    }

    fn start_session<'a>(&'a self, spec: SessionSpec) -> DriverFuture<'a, ProviderSessionId> {
        match self {
            Self::Codex(driver) => driver.start_session(spec),
            Self::Acp(driver) => driver.start_session(spec),
        }
    }

    fn resume_session<'a>(&'a self, spec: ResumeSessionSpec) -> DriverFuture<'a, ()> {
        match self {
            Self::Codex(driver) => driver.resume_session(spec),
            Self::Acp(driver) => driver.resume_session(spec),
        }
    }

    fn start_turn<'a>(
        &'a self,
        session_id: &'a ProviderSessionId,
        input: TurnInput,
        options: TurnOptions,
    ) -> DriverFuture<'a, StartedTurn> {
        match self {
            Self::Codex(driver) => driver.start_turn(session_id, input, options),
            Self::Acp(driver) => driver.start_turn(session_id, input, options),
        }
    }

    fn steer_turn<'a>(
        &'a self,
        session_id: &'a ProviderSessionId,
        turn_id: &'a TurnId,
        input: TurnInput,
    ) -> DriverFuture<'a, ()> {
        match self {
            Self::Codex(driver) => driver.steer_turn(session_id, turn_id, input),
            Self::Acp(driver) => driver.steer_turn(session_id, turn_id, input),
        }
    }

    fn cancel_turn<'a>(
        &'a self,
        session_id: &'a ProviderSessionId,
        turn_id: &'a TurnId,
    ) -> DriverFuture<'a, ()> {
        match self {
            Self::Codex(driver) => driver.cancel_turn(session_id, turn_id),
            Self::Acp(driver) => driver.cancel_turn(session_id, turn_id),
        }
    }

    fn compact_session<'a>(&'a self, session_id: &'a ProviderSessionId) -> DriverFuture<'a, ()> {
        match self {
            Self::Codex(driver) => driver.compact_session(session_id),
            Self::Acp(driver) => driver.compact_session(session_id),
        }
    }

    fn resolve_approval<'a>(
        &'a self,
        approval_id: &'a str,
        decision: ApprovalDecision,
    ) -> DriverFuture<'a, ()> {
        match self {
            Self::Codex(driver) => driver.resolve_approval(approval_id, decision),
            Self::Acp(driver) => driver.resolve_approval(approval_id, decision),
        }
    }

    fn resolve_question<'a>(
        &'a self,
        request_id: &'a str,
        answers: Vec<QuestionAnswer>,
    ) -> DriverFuture<'a, ()> {
        match self {
            Self::Codex(driver) => driver.resolve_question(request_id, answers),
            Self::Acp(driver) => driver.resolve_question(request_id, answers),
        }
    }

    fn shutdown<'a>(&'a self) -> DriverFuture<'a, ()> {
        match self {
            Self::Codex(driver) => driver.shutdown(),
            Self::Acp(driver) => driver.shutdown(),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;
    use std::path::PathBuf;

    use super::*;

    #[test]
    fn probe_output_is_bounded_and_marks_omission() {
        let output = format_probe_output(
            (vec![b'x'; PROVIDER_PROBE_OUTPUT_BYTES], true),
            (Vec::new(), false),
        );
        assert!(output.len() <= PROVIDER_PROBE_OUTPUT_BYTES + 64);
        assert!(output.ends_with("[additional provider probe output omitted]"));
    }

    #[cfg(unix)]
    #[test]
    fn provider_probe_timeout_is_bounded() {
        let started = Instant::now();
        let error = probe_command_inner_with_timeout(
            "opencode",
            std::path::Path::new("/bin/sh"),
            &["-c", "sleep 30"],
            "test provider",
            false,
            Duration::from_millis(100),
        )
        .expect_err("probe must time out");
        assert!(error.contains("timed out"));
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    fn installation(provider_id: &str, executable: &str) -> ProviderInstallationConfig {
        ProviderInstallationConfig {
            installation_id: provider_id.to_string(),
            provider_id: provider_id.to_string(),
            bot_user_id: 42,
            bot_username: format!("inline_{provider_id}_bot"),
            dm_chat_id: Some(7),
            workspace: PathBuf::from("/tmp/project"),
            greeting_sent: true,
            accept_messages_after: 0,
            initial_cursor_seeded: true,
            display_name: provider_id.to_string(),
            managed_avatar_digest: None,
            managed_avatar_file_unique_id: None,
            executable: PathBuf::from(executable),
            provider_runtime: None,
            provider_path: "/usr/bin:/bin".to_string(),
            state_dir: PathBuf::from(format!("/tmp/providers/{provider_id}")),
        }
    }

    #[test]
    fn codex_exclusive_continuity_uses_a_private_turn_epoch() {
        let launch = ProviderLaunch::from_installation(&installation("codex", "/opt/codex"))
            .expect("codex launch");
        let ProviderLaunch::Codex(config) = launch else {
            panic!("expected Codex launch");
        };
        assert_eq!(config.executable, PathBuf::from("/opt/codex"));
        assert_eq!(config.transport, CodexAppServerTransport::PrivateStdio);
        assert_eq!(config.version_policy, CodexVersionPolicy::Certified);
        assert_eq!(
            config.process_host.expect("process host").lock_file,
            PathBuf::from("/tmp/providers/codex/provider.process.lock")
        );
    }

    #[test]
    fn codex_setup_reuses_the_existing_configured_runtime_before_discovery() {
        let directory = tempfile::tempdir().expect("temporary bridge directory");
        let paths = BridgePaths::from_root(
            directory.path().to_path_buf(),
            directory.path().join("bin/inline"),
        );
        let account = AccountBridgeConfig {
            version: 5,
            owner_user_id: 42,
            host_installation_id: "host".to_string(),
            host_label: "Mac".to_string(),
            api_base_url: "https://api.inline.chat".to_string(),
            realtime_url: "wss://api.inline.chat/realtime".to_string(),
            service_label: "chat.inline.bridge".to_string(),
            service_binary: paths.installed_binary.clone(),
            provider_path: String::new(),
            superseded_service_labels: Vec::new(),
            operator_user_ids: Vec::new(),
            owner_control_cursor_seeded: true,
            providers: vec![installation("codex", "/Applications/ChatGPT.app/codex")],
        };
        std::fs::write(
            &paths.config,
            serde_json::to_vec(&account).expect("serialize account"),
        )
        .expect("write account");

        assert_eq!(
            configured_provider_executable(&paths, "codex").expect("configured executable"),
            Some(PathBuf::from("/Applications/ChatGPT.app/codex"))
        );
        assert_eq!(
            configured_provider_executable(&paths, "claude").expect("missing provider"),
            None
        );
    }

    #[cfg(unix)]
    #[test]
    fn all_acp_providers_share_one_launch_path() {
        for (provider_id, executable, expected_argument) in [
            ("opencode", "/opt/opencode", Some("acp")),
            ("claude", "/opt/claude", None),
        ] {
            let launch = ProviderLaunch::from_installation(&installation(provider_id, executable))
                .expect("ACP launch");
            let ProviderLaunch::Acp(descriptor) = launch else {
                panic!("expected shared ACP launch for {provider_id}");
            };
            assert_eq!(descriptor.provider_id.as_str(), provider_id);
            assert_eq!(
                descriptor.arguments.first().map(String::as_str),
                expected_argument
            );
            assert!(descriptor.provider_runtime.is_none());
            assert_eq!(
                descriptor.process_host.expect("process host").lock_file,
                PathBuf::from(format!(
                    "/tmp/providers/{provider_id}/provider.process.lock"
                ))
            );
        }

        use std::os::unix::fs::PermissionsExt;
        let runtime = tempfile::tempdir().expect("runtime directory");
        let amp = runtime.path().join("amp");
        std::fs::write(&amp, "#!/bin/sh\n").expect("Amp fixture");
        let mut permissions = std::fs::metadata(&amp).expect("metadata").permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(&amp, permissions).expect("executable fixture");
        let mut amp_installation = installation("amp", "/bridge/adapters/amp/0.8.1/dist/index.js");
        amp_installation.provider_runtime = Some(amp.clone());
        amp_installation.provider_path = "/path/that/must/not/be/searched".to_string();
        let ProviderLaunch::Acp(descriptor) =
            ProviderLaunch::from_installation(&amp_installation).expect("Amp ACP launch")
        else {
            panic!("expected shared ACP launch for Amp");
        };
        assert_eq!(descriptor.provider_runtime, Some(amp));
    }

    #[test]
    fn unknown_provider_fails_closed() {
        let error = ProviderLaunch::from_installation(&installation("unknown", "/opt/unknown"))
            .expect_err("unknown provider must fail");
        assert_eq!(error, "unsupported agent provider: unknown");
    }

    #[test]
    fn curated_adapters_have_verified_install_pins() {
        let claude = verified_acp_support("claude").expect("verified Claude support");
        let AcpDistribution::NpmAdapter(adapter) = claude.distribution else {
            panic!("expected npm adapter provider");
        };
        assert!(adapter.is_verified_install_pin());

        let amp = verified_acp_support("amp").expect("verified Amp support");
        let AcpDistribution::EmbeddedAdapter(adapter) = amp.distribution else {
            panic!("expected embedded adapter provider");
        };
        assert!(adapter.checksum.starts_with("sha256-"));
    }

    #[test]
    fn provider_names_are_not_codex_fallbacks() {
        assert_eq!(provider_display_name("codex"), Some("Codex"));
        assert_eq!(provider_display_name("opencode"), Some("OpenCode"));
        assert_eq!(provider_display_name("claude"), Some("Claude"));
        assert_eq!(provider_display_name("amp"), Some("Amp"));
        assert_eq!(provider_display_name("unknown"), None);
    }

    #[test]
    fn every_provider_has_a_distinct_valid_512_profile_asset() {
        let mut digests = HashSet::new();
        for provider_id in ["codex", "claude", "opencode", "amp"] {
            let asset = provider_profile_asset(provider_id).expect("profile asset");
            validate_provider_profile_asset(asset).expect("valid profile asset");
            assert_eq!(asset.provider_id, provider_id);
            assert!(digests.insert(provider_profile_asset_digest(asset)));
        }
        assert!(provider_profile_asset("unknown").is_none());
    }

    #[test]
    fn anonymous_opencode_models_are_a_usable_auth_path() {
        assert!(has_opencode_model(
            "\u{1b}[32mopencode/deepseek-v4-flash-free\u{1b}[0m\n"
        ));
        assert!(!has_opencode_model("Credentials\n0 credentials\n"));
    }

    #[test]
    fn amp_adapter_cli_contract_rejects_drifted_flags_and_modes() {
        let compatible = "--no-archive-after-execute --mode <low|medium|high|ultra>";
        assert_eq!(validate_amp_adapter_cli_contract(compatible), Ok(()));

        let current_incompatible = "--archive --mode <deep|large|rush|smart>";
        let error = validate_amp_adapter_cli_contract(current_incompatible)
            .expect_err("drifted Amp CLI must fail closed");
        assert!(error.contains("incompatible"));
        assert!(!error.contains(current_incompatible));
        assert!(provider_probe_requires_bridge_update("amp", &error));
        assert!(!provider_probe_requires_bridge_update("claude", &error));
        assert!(!requires_service_prelaunch_probe("amp"));
        assert!(requires_service_prelaunch_probe("claude"));
    }

    #[cfg(unix)]
    #[test]
    fn amp_probe_checks_the_configured_runtime_instead_of_searching_path() {
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().expect("runtime directory");
        let runtime = directory.path().join("verified-amp");
        std::fs::write(
            &runtime,
            "#!/bin/sh\ncase \"$1\" in\n  --version) echo 'amp 1' ;;\n  --help) echo '--no-archive-after-execute low medium high ultra' ;;\n  threads) exit 0 ;;\n  *) exit 2 ;;\nesac\n",
        )
        .expect("runtime fixture");
        let mut permissions = std::fs::metadata(&runtime).expect("metadata").permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(&runtime, permissions).expect("executable fixture");

        let probe = probe_configured_provider_with_runtime(
            "amp",
            std::path::Path::new("/unused/embedded-adapter"),
            Some(&runtime),
        )
        .expect("configured Amp runtime probe");
        assert_eq!(probe.provider_runtime, Some(runtime));

        let missing = directory.path().join("missing-amp");
        let error = probe_configured_provider_with_runtime(
            "amp",
            std::path::Path::new("/unused/embedded-adapter"),
            Some(&missing),
        )
        .expect_err("missing configured runtime must not fall back to PATH");
        assert!(error.contains("configured Amp CLI"));
        assert!(error.contains("rerun setup"));
    }

    #[test]
    #[ignore = "requires an installed OpenCode CLI"]
    fn installed_opencode_probe_accepts_available_anonymous_models() {
        let executable = std::env::var_os("INLINE_ACP_OPENCODE_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("opencode"));
        let probe = probe_configured_provider("opencode", &executable)
            .expect("installed OpenCode should pass its native probes");
        assert_eq!(probe.provider_id, "opencode");
        assert!(!probe.version.is_empty());
    }
}
