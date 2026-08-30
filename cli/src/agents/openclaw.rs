use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use super::bot::ManagedBot;
use super::discovery::InstalledTarget;
use super::process::{require_success, run};
use super::{
    AccessMode, AgentsSetupArgs, GatewayPreflight, GatewaySetupOutcome, SetupProgressReporter,
    cli_error,
};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(60);
const INSTALL_TIMEOUT: Duration = Duration::from_secs(180);
const PLUGIN_PACKAGE_NAME: &str = "@inline-openclaw/inline";
const MINIMUM_SETUP_PLUGIN_VERSION: &str = "0.0.57";
const SETUP_PLUGIN_SPEC: &str = "@inline-openclaw/inline";

pub(super) async fn preflight(
    installed: &InstalledTarget,
    args: &AgentsSetupArgs,
) -> Result<GatewayPreflight, Box<dyn std::error::Error>> {
    let prefix = profile_prefix(args.profile.as_deref());
    require_success(
        &installed.executable,
        &[],
        &["--version"],
        None,
        COMMAND_TIMEOUT,
    )
    .await?;
    let inspected = run(
        &installed.executable,
        &prefix,
        &["plugins", "inspect", "inline", "--json"],
        None,
        COMMAND_TIMEOUT,
    )
    .await?;
    let plugin_state = inspect_plugin(&inspected)?;
    let plugin_can_probe = matches!(
        &plugin_state,
        PluginState::Healthy { .. } | PluginState::Outdated
    );
    match plugin_state {
        PluginState::Healthy { .. } => {}
        PluginState::Outdated if !args.no_install => {}
        PluginState::Missing if !args.no_install => {}
        PluginState::ManagedBroken if !args.no_install => {}
        PluginState::Foreign if args.replace && !args.no_install => {}
        PluginState::Foreign => {
            return Err(cli_error(
                "setup_conflict",
                "the existing OpenClaw inline plugin has an unrecognized source; rerun with --replace to replace it",
            )
            .into());
        }
        PluginState::Missing => require_plugin_install_allowed(args, "is not installed")?,
        PluginState::Outdated => {
            require_plugin_install_allowed(args, "must be updated for unified setup")?
        }
        PluginState::ManagedBroken => {
            require_plugin_install_allowed(args, "is installed but unusable")?
        }
    };
    let configured_bot_id = if plugin_can_probe {
        let status = run(
            &installed.executable,
            &prefix,
            &[
                "channels",
                "status",
                "--channel",
                "inline",
                "--probe",
                "--json",
            ],
            None,
            COMMAND_TIMEOUT,
        )
        .await?;
        require_probe_success(&status)?;
        match configured_bot_id(&status.stdout) {
            Err(error)
                if args.replace
                    && error
                        .downcast_ref::<crate::errors::CliError>()
                        .is_some_and(|error| error.code == "setup_conflict") =>
            {
                None
            }
            result => result?,
        }
    } else {
        None
    };
    Ok(GatewayPreflight { configured_bot_id })
}

fn gateway_service_loaded(
    status: &super::process::CommandOutput,
) -> Result<bool, crate::errors::CliError> {
    // The status command exits 0 even when no service is installed. Only the
    // explicit service fact can select install versus restart.
    if status.success
        && let Some(loaded) = serde_json::from_str::<serde_json::Value>(&status.stdout)
            .ok()
            .and_then(|value| {
                value
                    .pointer("/service/loaded")
                    .and_then(serde_json::Value::as_bool)
            })
    {
        return Ok(loaded);
    }
    Err(cli_error(
        "gateway_probe_failed",
        format!(
            "OpenClaw could not report whether its gateway service is installed (exit {:?}): {}. Run `openclaw gateway status --json` and repair the service before retrying",
            status.exit_code, status.stderr
        ),
    ))
}

fn configured_bot_id(output: &str) -> Result<Option<i64>, Box<dyn std::error::Error>> {
    let value = parse_channel_status(output)?;
    if value
        .pointer("/channelAccounts/inline")
        .and_then(serde_json::Value::as_array)
        .is_some_and(Vec::is_empty)
        && value
            .get("partial")
            .is_none_or(|value| value.as_bool() == Some(false))
        && value
            .get("warnings")
            .is_none_or(|value| value.as_array().is_some_and(Vec::is_empty))
        && value.get("error").is_none_or(serde_json::Value::is_null)
        && value
            .pointer("/channels/inline")
            .is_none_or(|summary| credential_is_absent(summary, false))
    {
        // A complete live response can explicitly list no accounts on a fresh
        // installation. Partial/timed-out snapshots cannot prove absence.
        return Ok(None);
    }
    let channel = selected_channel_account(&value)?;
    match channel
        .get("configured")
        .and_then(serde_json::Value::as_bool)
    {
        Some(false) if credential_is_absent(channel, value.get("channelAccounts").is_some()) => {
            Ok(None)
        }
        Some(true)
            if channel
                .pointer("/probe/ok")
                .and_then(serde_json::Value::as_bool)
                == Some(true) =>
        {
            channel_bot_id(channel)
                .map(Some)
                .ok_or_else(|| channel_probe_error(channel).into())
        }
        Some(false) | Some(true) => Err(cli_error(
            "setup_conflict",
            format!("the existing OpenClaw Inline credential cannot be verified: {}. Repair its credential source, or rerun with --replace to explicitly allow replacement", channel_probe_detail(channel)),
        ).into()),
        _ => Err(channel_probe_error(channel).into()),
    }
}

fn credential_is_absent(channel: &serde_json::Value, require_source: bool) -> bool {
    if channel
        .get("configured")
        .and_then(serde_json::Value::as_bool)
        != Some(false)
    {
        return false;
    }
    let source_absent = match channel.get("tokenSource") {
        Some(serde_json::Value::String(source)) => source == "none",
        None => !require_source, // Legacy channel summaries did not expose it.
        _ => false,
    };
    // SecretRef, unreadable token files, and duplicate credentials can all be
    // reported as configured=false. Preserve them instead of creating a bot.
    source_absent
        && channel
            .get("tokenConfigured")
            .is_none_or(|value| value.as_bool() == Some(false))
        && channel
            .get("tokenStatus")
            .is_none_or(|value| value.as_str() == Some("missing"))
        && channel.get("stateReason").is_none_or(|value| {
            value.is_null() || matches!(value.as_str(), Some("" | "not configured"))
        })
        && channel
            .get("lastError")
            .is_none_or(|value| value.is_null() || value.as_str() == Some(""))
        && channel.get("probe").is_none_or(serde_json::Value::is_null)
        && channel_bot_id(channel).is_none()
}

pub(super) async fn setup(
    installed: &InstalledTarget,
    bot: &ManagedBot,
    args: &AgentsSetupArgs,
    progress: &SetupProgressReporter,
) -> Result<GatewaySetupOutcome, Box<dyn std::error::Error>> {
    progress.started("integration");
    let prefix = profile_prefix(args.profile.as_deref());
    let _host_version = require_success(
        &installed.executable,
        &[],
        &["--version"],
        None,
        COMMAND_TIMEOUT,
    )
    .await?;
    let inspected = run(
        &installed.executable,
        &prefix,
        &["plugins", "inspect", "inline", "--json"],
        None,
        COMMAND_TIMEOUT,
    )
    .await?;
    let plugin_state = inspect_plugin(&inspected)?;
    let (integration_action, verify_install) = match plugin_state {
        PluginState::Healthy { .. } => ("kept", false),
        PluginState::Outdated => {
            require_plugin_install_allowed(args, "must be updated for unified setup")?;
            install_latest_plugin(installed, &prefix).await?;
            ("updated", true)
        }
        PluginState::Missing => {
            require_plugin_install_allowed(args, "is not installed")?;
            install_latest_plugin(installed, &prefix).await?;
            ("installed", true)
        }
        PluginState::ManagedBroken => {
            require_plugin_install_allowed(args, "is installed but unusable")?;
            install_latest_plugin(installed, &prefix).await?;
            ("repaired", true)
        }
        PluginState::Foreign => {
            require_plugin_install_allowed(args, "uses an unrecognized source")?;
            if !args.replace {
                return Err(cli_error(
                    "setup_conflict",
                    "the existing OpenClaw inline plugin has an unrecognized source; rerun with --replace to replace it",
                )
                .into());
            }
            install_latest_plugin(installed, &prefix).await?;
            ("replaced", true)
        }
    };
    let plugin = require_success(
        &installed.executable,
        &prefix,
        &["plugins", "inspect", "inline", "--json"],
        None,
        COMMAND_TIMEOUT,
    )
    .await?;
    let version = if verify_install {
        verify_managed_plugin_install(&plugin)?
    } else {
        let PluginState::Healthy { version } = inspect_plugin_json(&plugin) else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "the Inline OpenClaw plugin is still unusable after setup",
            )
            .into());
        };
        version
    };
    progress.completed("integration", integration_action);

    progress.started("access");
    let config_output = require_success(
        &installed.executable,
        &prefix,
        &["config", "file"],
        None,
        COMMAND_TIMEOUT,
    )
    .await?;
    let config_path = parse_config_path(&config_output)?;
    validate_config_path(&config_path)?;
    let token_path = config_path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "OpenClaw config has no parent"))?
        .join("secrets")
        .join("inline-default.token");
    write_secret(&token_path, bot.token())?;
    let token_path_string = token_path.to_string_lossy().into_owned();
    require_success(
        &installed.executable,
        &prefix,
        &[
            "channels",
            "add",
            "--channel",
            "inline",
            "--token-file",
            &token_path_string,
        ],
        None,
        COMMAND_TIMEOUT,
    )
    .await?;
    configure_access(installed, &prefix, bot, args).await?;
    progress.completed("access", "configured");

    progress.started("service");
    let (service_action, ready) = if args.no_restart {
        ("skipped", false)
    } else {
        let status = run(
            &installed.executable,
            &prefix,
            &["gateway", "status", "--json"],
            None,
            COMMAND_TIMEOUT,
        )
        .await?;
        let action = if gateway_service_loaded(&status)? {
            require_success(
                &installed.executable,
                &prefix,
                &["gateway", "restart", "--wait", "30s", "--json"],
                None,
                INSTALL_TIMEOUT,
            )
            .await?;
            "restarted"
        } else {
            require_success(
                &installed.executable,
                &prefix,
                &["gateway", "install", "--json"],
                None,
                INSTALL_TIMEOUT,
            )
            .await?;
            require_success(
                &installed.executable,
                &prefix,
                &["gateway", "start", "--json"],
                None,
                INSTALL_TIMEOUT,
            )
            .await?;
            "installed"
        };
        progress.completed("service", action);
        progress.started("verification");
        let channel_status = require_success(
            &installed.executable,
            &prefix,
            &[
                "channels",
                "status",
                "--channel",
                "inline",
                "--probe",
                "--json",
            ],
            None,
            INSTALL_TIMEOUT,
        )
        .await?;
        verify_channel_status(&channel_status, bot.id)?;
        progress.completed("verification", "ready");
        (action, true)
    };
    if !ready {
        progress.completed("service", service_action);
        progress.started("verification");
        progress.completed("verification", "action_required");
    }
    Ok(GatewaySetupOutcome {
        integration_action,
        integration_version: version,
        service_action,
        ready,
    })
}

enum PluginState {
    Missing,
    Healthy { version: String },
    Outdated,
    ManagedBroken,
    Foreign,
}

async fn install_latest_plugin(
    installed: &InstalledTarget,
    prefix: &[OsString],
) -> Result<(), Box<dyn std::error::Error>> {
    require_success(
        &installed.executable,
        prefix,
        &["plugins", "install", SETUP_PLUGIN_SPEC, "--force"],
        None,
        INSTALL_TIMEOUT,
    )
    .await?;
    Ok(())
}

fn inspect_plugin(
    output: &super::process::CommandOutput,
) -> Result<PluginState, Box<dyn std::error::Error>> {
    if !output.success {
        // The host reports an actual lookup miss as exit 1, even with --json.
        // A broken config, permission error, or crash must not authorize --force.
        if output.exit_code == Some(1)
            && output.stderr.lines().any(|line| {
                let line = line.trim();
                line == "Plugin not found: inline"
                    || line.starts_with("Plugin not found: inline. Run ")
            })
        {
            return Ok(PluginState::Missing);
        }
        return Err(cli_error(
            "plugin_probe_failed",
            format!(
                "could not inspect the OpenClaw Inline plugin (exit {:?}): {}",
                output.exit_code, output.stderr
            ),
        )
        .into());
    }
    let value: serde_json::Value = serde_json::from_str(&output.stdout).map_err(|_| {
        cli_error(
            "plugin_probe_failed",
            "OpenClaw returned unreadable plugin metadata; no plugin was replaced",
        )
    })?;
    if !value
        .get("plugin")
        .is_some_and(serde_json::Value::is_object)
    {
        return Err(cli_error(
            "plugin_probe_failed",
            "OpenClaw returned no plugin metadata; no plugin was replaced",
        )
        .into());
    }
    Ok(inspect_plugin_json(&output.stdout))
}

fn inspect_plugin_json(output: &str) -> PluginState {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(output) else {
        return PluginState::Foreign;
    };
    let Some(plugin) = value.get("plugin") else {
        return PluginState::Missing;
    };
    let package_name = plugin
        .get("packageName")
        .and_then(serde_json::Value::as_str)
        .or_else(|| {
            value
                .pointer("/install/resolvedName")
                .and_then(serde_json::Value::as_str)
        });
    if package_name != Some(PLUGIN_PACKAGE_NAME) {
        return PluginState::Foreign;
    }
    let version = plugin
        .get("version")
        .and_then(serde_json::Value::as_str)
        .or_else(|| {
            value
                .pointer("/install/resolvedVersion")
                .and_then(serde_json::Value::as_str)
        })
        .unwrap_or("unknown")
        .to_string();
    let loaded = plugin.get("status").and_then(serde_json::Value::as_str) == Some("loaded");
    let dependencies_ready = plugin
        .pointer("/dependencyStatus/requiredInstalled")
        .and_then(serde_json::Value::as_bool)
        == Some(true);
    let version_ready = semver::Version::parse(&version).is_ok_and(|version| {
        version
            >= semver::Version::parse(MINIMUM_SETUP_PLUGIN_VERSION)
                .expect("OpenClaw setup plugin minimum must be valid semver")
    });
    if !loaded || !dependencies_ready {
        PluginState::ManagedBroken
    } else if version_ready {
        PluginState::Healthy { version }
    } else {
        PluginState::Outdated
    }
}

fn verify_managed_plugin_install(output: &str) -> Result<String, Box<dyn std::error::Error>> {
    let value: serde_json::Value = serde_json::from_str(output).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "OpenClaw returned unreadable Inline plugin metadata after installation",
        )
    })?;
    let PluginState::Healthy { version } = inspect_plugin_json(output) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the Inline OpenClaw plugin is still unusable after installation",
        )
        .into());
    };
    let install = value.get("install");
    let resolved_spec = format!("{PLUGIN_PACKAGE_NAME}@{version}");
    let managed_metadata = install
        .and_then(|value| value.get("source"))
        .and_then(serde_json::Value::as_str)
        == Some("npm")
        && install
            .and_then(|value| value.get("resolvedName"))
            .and_then(serde_json::Value::as_str)
            == Some(PLUGIN_PACKAGE_NAME)
        && install
            .and_then(|value| value.get("resolvedVersion"))
            .and_then(serde_json::Value::as_str)
            == Some(version.as_str())
        && install
            .and_then(|value| value.get("spec"))
            .and_then(serde_json::Value::as_str)
            == Some(SETUP_PLUGIN_SPEC)
        && install
            .and_then(|value| value.get("resolvedSpec"))
            .and_then(serde_json::Value::as_str)
            == Some(resolved_spec.as_str());
    if !managed_metadata {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "OpenClaw did not record a managed Inline plugin install from {SETUP_PLUGIN_SPEC}"
            ),
        )
        .into());
    }
    Ok(version)
}

fn require_plugin_install_allowed(
    args: &AgentsSetupArgs,
    reason: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    if args.no_install {
        return Err(cli_error(
            "plugin_unavailable",
            format!("the Inline OpenClaw plugin {reason} and --no-install was provided"),
        )
        .into());
    }
    Ok(())
}

fn profile_prefix(profile: Option<&str>) -> Vec<OsString> {
    match profile {
        Some(profile) if profile != "default" => {
            vec![OsString::from("--profile"), OsString::from(profile)]
        }
        _ => Vec::new(),
    }
}

async fn configure_access(
    installed: &InstalledTarget,
    prefix: &[OsString],
    bot: &ManagedBot,
    args: &AgentsSetupArgs,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut allowed = args.allow_users.clone();
    allowed.push(bot.owner_user_id);
    allowed.sort_unstable();
    allowed.dedup();
    let allowed = allowed
        .into_iter()
        .map(|id| id.to_string())
        .collect::<Vec<_>>();
    match args.access {
        AccessMode::Owner | AccessMode::Allowlist => {
            set_config(
                installed,
                prefix,
                "channels.inline.dmPolicy",
                "\"allowlist\"",
            )
            .await?;
            set_json_config(installed, prefix, "channels.inline.allowFrom", &allowed).await?;
            set_config(installed, prefix, "channels.inline.groupPolicy", "\"open\"").await?;
            set_json_config(
                installed,
                prefix,
                "channels.inline.groupAllowFrom",
                &allowed,
            )
            .await?;
            set_config(
                installed,
                prefix,
                "channels.inline.groups",
                r#"{"*":{"requireMention":true}}"#,
            )
            .await?;
        }
        AccessMode::Open => {
            set_config(installed, prefix, "channels.inline.dmPolicy", "\"open\"").await?;
            set_config(installed, prefix, "channels.inline.allowFrom", r#"["*"]"#).await?;
            set_config(installed, prefix, "channels.inline.groupPolicy", "\"open\"").await?;
            set_config(installed, prefix, "channels.inline.groupAllowFrom", "[]").await?;
            set_config(
                installed,
                prefix,
                "channels.inline.groups",
                r#"{"*":{"requireMention":true}}"#,
            )
            .await?;
        }
        AccessMode::Disabled => {
            set_config(
                installed,
                prefix,
                "channels.inline.dmPolicy",
                "\"disabled\"",
            )
            .await?;
            set_config(
                installed,
                prefix,
                "channels.inline.groupPolicy",
                "\"disabled\"",
            )
            .await?;
            set_config(installed, prefix, "channels.inline.allowFrom", "[]").await?;
            set_config(installed, prefix, "channels.inline.groupAllowFrom", "[]").await?;
        }
    }
    Ok(())
}

async fn set_json_config<T: serde::Serialize>(
    installed: &InstalledTarget,
    prefix: &[OsString],
    path: &str,
    value: &T,
) -> Result<(), Box<dyn std::error::Error>> {
    let value = serde_json::to_string(value)?;
    set_config(installed, prefix, path, &value).await
}

async fn set_config(
    installed: &InstalledTarget,
    prefix: &[OsString],
    path: &str,
    value: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    require_success(
        &installed.executable,
        prefix,
        &["config", "set", path, value, "--strict-json"],
        None,
        COMMAND_TIMEOUT,
    )
    .await?;
    Ok(())
}

fn parse_config_path(output: &str) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let value = output
        .lines()
        .rev()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "OpenClaw returned no config path",
            )
        })?;
    let path = if let Some(relative) = value.strip_prefix("~/") {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "HOME is not configured"))?;
        home.join(relative)
    } else {
        PathBuf::from(value)
    };
    if !path.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "OpenClaw returned a non-absolute config path",
        )
        .into());
    }
    Ok(path)
}

fn validate_config_path(path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "OpenClaw config path must be a regular file",
            )
            .into())
        }
        Ok(_) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn write_secret(path: &Path, token: &str) -> Result<(), Box<dyn std::error::Error>> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "token path has no parent"))?;
    if fs::symlink_metadata(parent).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "OpenClaw secrets directory may not be a symlink",
        )
        .into());
    }
    fs::create_dir_all(parent)?;
    set_dir_mode(parent, 0o700)?;
    if fs::symlink_metadata(path)
        .is_ok_and(|metadata| metadata.file_type().is_symlink() || !metadata.is_file())
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "OpenClaw token path must be a regular file",
        )
        .into());
    }
    let temporary = path.with_extension(format!("token.tmp.{}", std::process::id()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary)?;
    file.write_all(token.as_bytes())?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    set_file_mode(&temporary, 0o600)?;
    fs::rename(&temporary, path)?;
    set_file_mode(path, 0o600)?;
    Ok(())
}

fn verify_channel_status(
    output: &str,
    expected_bot_id: i64,
) -> Result<(), Box<dyn std::error::Error>> {
    let value = parse_channel_status(output)?;
    let channel = selected_channel_account(&value)?;
    let configured = channel
        .get("configured")
        .and_then(serde_json::Value::as_bool)
        == Some(true);
    let running = channel.get("running").and_then(serde_json::Value::as_bool) == Some(true);
    let connected = channel
        .get("connected")
        .and_then(serde_json::Value::as_bool)
        == Some(true);
    let probe_ok = channel
        .pointer("/probe/ok")
        .and_then(serde_json::Value::as_bool)
        == Some(true);
    if !configured
        || !running
        || !connected
        || !probe_ok
        || channel_bot_id(channel) != Some(expected_bot_id)
    {
        return Err(channel_probe_error(channel).into());
    }
    Ok(())
}

fn require_probe_success(
    output: &super::process::CommandOutput,
) -> Result<(), Box<dyn std::error::Error>> {
    if !output.success {
        return Err(cli_error("gateway_probe_failed", format!(
            "OpenClaw channel probe failed (exit {:?}): {}; existing bot identity was not replaced",
            output.exit_code, output.stderr
        )).into());
    }
    Ok(())
}

fn parse_channel_status(output: &str) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    let value: serde_json::Value = serde_json::from_str(output).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "OpenClaw returned unreadable Inline channel status",
        )
    })?;
    if value
        .get("gatewayReachable")
        .and_then(serde_json::Value::as_bool)
        == Some(false)
        || value.get("configOnly").and_then(serde_json::Value::as_bool) == Some(true)
    {
        return Err(cli_error("gateway_probe_failed", format!(
            "OpenClaw returned config-only status; start or repair its gateway before retrying setup: {}",
            crate::diagnostics::safe_text(value.get("error").and_then(serde_json::Value::as_str).unwrap_or("gateway unavailable"))
        )).into());
    }
    Ok(value)
}

fn selected_channel_account(
    value: &serde_json::Value,
) -> Result<&serde_json::Value, Box<dyn std::error::Error>> {
    // Current hosts put the live probe on the default account, not the summary.
    // Never fall back to another account when the selected one is incomplete.
    if let Some(raw_accounts) = value.pointer("/channelAccounts/inline") {
        let default_id = value
            .pointer("/channelDefaultAccountId/inline")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("default");
        // Unified setup writes the literal default account. A named host
        // default must not be probed and then duplicated into another account.
        if default_id != "default" {
            return Err(cli_error(
                "unsupported_account",
                "Inline setup currently manages only OpenClaw's default account; configure the selected named Inline account with OpenClaw directly, or use a separate profile",
            ).into());
        }
        return raw_accounts
            .as_array()
            .and_then(|accounts| {
                accounts.iter().find(|account| {
                    account.get("accountId").and_then(serde_json::Value::as_str) == Some(default_id)
                })
            })
            .ok_or_else(|| {
                cli_error(
                    "gateway_probe_failed",
                    "OpenClaw returned no status for the selected Inline account",
                )
                .into()
            });
    }
    value
        .pointer("/channels/inline")
        .filter(|channel| channel.is_object())
        .ok_or_else(|| {
            cli_error(
                "gateway_probe_failed",
                "OpenClaw returned no Inline channel status",
            )
            .into()
        })
}

fn channel_bot_id(channel: &serde_json::Value) -> Option<i64> {
    channel
        .pointer("/probe/user/id")
        .and_then(|value| {
            value
                .as_i64()
                .or_else(|| value.as_str().and_then(|value| value.parse().ok()))
        })
        .filter(|id| *id > 0)
}

fn channel_probe_error(channel: &serde_json::Value) -> crate::errors::CliError {
    cli_error(
        "gateway_probe_failed",
        format!(
            "OpenClaw Inline channel did not verify as the selected connected bot: {}. Repair the gateway and retry setup",
            channel_probe_detail(channel)
        ),
    )
}

fn channel_probe_detail(channel: &serde_json::Value) -> String {
    let detail = [
        channel.get("lastError"),
        channel.get("stateReason"),
        channel.pointer("/probe/error"),
    ]
    .into_iter()
    .flatten()
    .filter_map(serde_json::Value::as_str)
    .find(|text| !text.trim().is_empty())
    .unwrap_or("configured identity or live connection could not be verified");
    crate::diagnostics::safe_text(detail)
}

#[cfg(unix)]
fn set_file_mode(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn set_file_mode(_path: &Path, _mode: u32) -> io::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn set_dir_mode(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn set_dir_mode(_path: &Path, _mode: u32) -> io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absent_gateway_service_requires_install_even_when_status_exits_successfully() {
        let mut status = super::super::process::CommandOutput {
            success: true,
            stdout: r#"{"service":{"loaded":false}}"#.into(),
            stderr: String::new(),
            exit_code: Some(0),
        };
        assert!(!gateway_service_loaded(&status).unwrap());
        status.stdout = r#"{"service":{"loaded":true,"runtime":{"status":"stopped"}}}"#.into();
        assert!(gateway_service_loaded(&status).unwrap());
        status.stdout = "{}".into();
        assert!(gateway_service_loaded(&status).is_err());
        status.stdout = r#"{"service":{"loaded":false}}"#.into();
        status.success = false;
        assert!(gateway_service_loaded(&status).is_err());
    }

    #[test]
    fn parses_absolute_and_home_relative_config_paths() {
        assert_eq!(
            parse_config_path("/tmp/openclaw.json\n").unwrap(),
            PathBuf::from("/tmp/openclaw.json")
        );
        assert!(parse_config_path("relative/openclaw.json").is_err());
    }

    #[test]
    fn channel_verification_requires_the_selected_running_bot() {
        verify_channel_status(
            r#"{"channels":{"inline":{"configured":true,"running":true,"connected":true,"probe":{"ok":true,"user":{"id":"42"}}}}}"#,
            42,
        )
        .expect("matching bot verifies");
        assert!(
            verify_channel_status(
                r#"{"channels":{"inline":{"configured":true,"running":true,"connected":true,"probe":{"ok":true,"user":{"id":"43"}}}}}"#,
                42,
            )
            .is_err()
        );
    }

    #[test]
    fn channel_probe_uses_the_default_account_and_requires_a_live_connection() {
        let output = r#"{"channels":{"inline":{"configured":true}},"channelDefaultAccountId":{"inline":"default"},"channelAccounts":{"inline":[{"accountId":"work","configured":true,"probe":{"ok":true,"user":{"id":"43"}}},{"accountId":"default","configured":true,"running":true,"connected":true,"probe":{"ok":true,"user":{"id":"42"}}}]}}"#;
        assert_eq!(configured_bot_id(output).unwrap(), Some(42));
        verify_channel_status(output, 42).unwrap();
        assert!(
            verify_channel_status(
                &output.replace("\"connected\":true", "\"connected\":false"),
                42
            )
            .is_err()
        );
        assert!(
            configured_bot_id(&output.replace("\"inline\":\"default\"", "\"inline\":\"missing\""))
                .is_err()
        );
    }

    #[test]
    fn named_default_account_is_not_silently_copied_into_default() {
        let output = r#"{"channelDefaultAccountId":{"inline":"work"},"channelAccounts":{"inline":[{"accountId":"work","configured":true,"running":true,"connected":true,"probe":{"ok":true,"user":{"id":"42"}}}]}}"#;
        let error = configured_bot_id(output).unwrap_err();
        // --replace only overrides setup_conflict, never an account mismatch.
        assert_eq!(
            error
                .downcast_ref::<crate::errors::CliError>()
                .unwrap()
                .code,
            "unsupported_account"
        );
        assert!(verify_channel_status(output, 42).is_err());
    }

    #[test]
    fn unavailable_channel_probes_never_mean_no_existing_bot() {
        for output in [
            r#"{"gatewayReachable":false,"configOnly":true,"configuredChannels":["inline"],"error":"gateway unavailable"}"#,
            // Config-only announcement lists omit disabled channels and do not
            // include persisted auth state. An empty list cannot prove absence.
            r#"{"gatewayReachable":false,"configOnly":true,"configuredChannels":[]}"#,
            "not json",
            "{}",
            r#"{"channels":{"inline":{"configured":true,"probe":{"ok":false}}}}"#,
        ] {
            assert!(configured_bot_id(output).is_err(), "{output}");
            assert!(verify_channel_status(output, 42).is_err());
        }
        assert_eq!(
            configured_bot_id(r#"{"channels":{"inline":{"configured":false}}}"#).unwrap(),
            None
        );
    }

    #[test]
    fn complete_empty_live_account_lists_allow_first_setup() {
        let fresh = r#"{"channelAccounts":{"inline":[]},"channelDefaultAccountId":{"inline":"default"},"channels":{"inline":{"configured":false}}}"#;
        assert_eq!(configured_bot_id(fresh).unwrap(), None);
        assert_eq!(configured_bot_id(r#"{"channelAccounts":{"inline":[]},"channelDefaultAccountId":{"inline":"default"}}"#).unwrap(), None);
        assert!(
            configured_bot_id(&fresh.replace("\"configured\":false", "\"configured\":true"))
                .is_err()
        );
        let mut partial: serde_json::Value = serde_json::from_str(fresh).unwrap();
        partial["partial"] = true.into();
        assert!(configured_bot_id(&partial.to_string()).is_err());
    }

    #[test]
    fn unavailable_or_duplicate_credentials_are_not_absent() {
        for account in [
            serde_json::json!({"configured":false,"tokenSource":"file","stateReason":"not configured: token file is configured but unavailable"}),
            serde_json::json!({"configured":false,"tokenSource":"env","tokenStatus":"configured_unavailable"}),
            serde_json::json!({"configured":false,"tokenSource":"config","lastError":"duplicate token"}),
            serde_json::json!({"configured":false,"tokenSource":"none","stateReason":"credential unavailable"}),
            serde_json::json!({"configured":false}),
        ] {
            let mut account = account;
            account["accountId"] = "default".into();
            let output = serde_json::json!({"channelAccounts":{"inline":[account]},"channelDefaultAccountId":{"inline":"default"}});
            assert!(configured_bot_id(&output.to_string()).is_err(), "{output}");
        }
        let unconfigured = r#"{"channelAccounts":{"inline":[{"accountId":"default","configured":false,"tokenSource":"none","stateReason":"not configured"}]}}"#;
        assert_eq!(configured_bot_id(unconfigured).unwrap(), None);
        let failure = configured_bot_id(r#"{"channels":{"inline":{"configured":true,"lastError":null,"probe":{"ok":false,"error":"credential rejected TOKEN=private-value"}}}}"#).unwrap_err();
        assert_eq!(
            failure
                .downcast_ref::<crate::errors::CliError>()
                .unwrap()
                .code,
            "setup_conflict"
        );
        assert!(failure.to_string().contains("credential rejected"));
        assert!(!failure.to_string().contains("private-value"));
    }

    #[test]
    fn plugin_probe_failures_do_not_authorize_installation() {
        let mut output = super::super::process::CommandOutput {
            success: false,
            stdout: String::new(),
            exit_code: Some(1),
            stderr:
                "Plugin not found: inline. Run `openclaw plugins list` to see installed plugins."
                    .into(),
        };
        assert!(matches!(
            inspect_plugin(&output).unwrap(),
            PluginState::Missing
        ));
        output.stderr = "config load failed: permission denied".into();
        assert!(inspect_plugin(&output).is_err());
        output.success = true;
        output.stdout = "{}".into();
        assert!(inspect_plugin(&output).is_err());
    }

    #[test]
    fn plugin_inspection_distinguishes_healthy_and_foreign_sources() {
        let healthy = inspect_plugin_json(
            r#"{"plugin":{"packageName":"@inline-openclaw/inline","version":"0.0.57","status":"loaded","dependencyStatus":{"requiredInstalled":true}}}"#,
        );
        assert!(matches!(
            healthy,
            PluginState::Healthy { version } if version == "0.0.57"
        ));
        assert!(matches!(
            inspect_plugin_json(
                r#"{"plugin":{"packageName":"@inline-openclaw/inline","version":"0.0.55","status":"loaded","dependencyStatus":{"requiredInstalled":true}}}"#
            ),
            PluginState::Outdated
        ));
        assert!(matches!(
            inspect_plugin_json(
                r#"{"plugin":{"packageName":"other-inline-plugin","status":"loaded"}}"#
            ),
            PluginState::Foreign
        ));
        assert!(matches!(
            inspect_plugin_json(
                r#"{"plugin":{"packageName":"@inline-openclaw/inline","status":"error"}}"#
            ),
            PluginState::ManagedBroken
        ));
        assert!(matches!(
            inspect_plugin_json(
                r#"{"plugin":{"packageName":"@inline-openclaw/inline","version":"0.0.57","status":"loaded"}}"#
            ),
            PluginState::ManagedBroken
        ));
    }

    #[test]
    fn latest_install_metadata_must_match_the_managed_external_package() {
        let inspected = r#"{
            "plugin": {
                "packageName": "@inline-openclaw/inline",
                "version": "0.0.58",
                "status": "loaded",
                "dependencyStatus": { "requiredInstalled": true }
            },
            "install": {
                "source": "npm",
                "spec": "@inline-openclaw/inline",
                "resolvedName": "@inline-openclaw/inline",
                "resolvedVersion": "0.0.58",
                "resolvedSpec": "@inline-openclaw/inline@0.0.58"
            }
        }"#;
        assert_eq!(verify_managed_plugin_install(inspected).unwrap(), "0.0.58");

        let pinned = inspected.replace(
            "\"spec\": \"@inline-openclaw/inline\"",
            "\"spec\": \"@inline-openclaw/inline@0.0.58\"",
        );
        assert!(verify_managed_plugin_install(&pinned).is_err());
        let mismatched_resolution = inspected.replace(
            "\"resolvedSpec\": \"@inline-openclaw/inline@0.0.58\"",
            "\"resolvedSpec\": \"@inline-openclaw/inline@0.0.57\"",
        );
        assert!(verify_managed_plugin_install(&mismatched_resolution).is_err());
        assert_eq!(
            ["plugins", "install", SETUP_PLUGIN_SPEC, "--force"],
            ["plugins", "install", "@inline-openclaw/inline", "--force"]
        );
    }
}
