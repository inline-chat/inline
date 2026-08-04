use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use super::bot::ManagedBot;
use super::discovery::InstalledTarget;
use super::process::{require_success, run};
use super::{AccessMode, AgentsSetupArgs, GatewayPreflight, GatewaySetupOutcome};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(60);
const INSTALL_TIMEOUT: Duration = Duration::from_secs(180);
const MIN_SETUP_PLUGIN_VERSION: &str = "0.0.56";

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
    let plugin_state = inspect_plugin(&inspected);
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
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
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
        if status.success {
            configured_bot_id(&status.stdout)
        } else {
            None
        }
    } else {
        None
    };
    Ok(GatewayPreflight { configured_bot_id })
}

fn configured_bot_id(output: &str) -> Option<i64> {
    let value: serde_json::Value = serde_json::from_str(output).ok()?;
    value
        .pointer("/channels/inline/probe/user/id")
        .and_then(|value| {
            value
                .as_i64()
                .or_else(|| value.as_str().and_then(|value| value.parse().ok()))
        })
        .filter(|id| *id > 0)
}

pub(super) async fn setup(
    installed: &InstalledTarget,
    bot: &ManagedBot,
    args: &AgentsSetupArgs,
) -> Result<GatewaySetupOutcome, Box<dyn std::error::Error>> {
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
    let plugin_state = inspect_plugin(&inspected);
    let integration_action = match plugin_state {
        PluginState::Healthy { .. } => "kept",
        PluginState::Outdated => {
            require_plugin_install_allowed(args, "must be updated for unified setup")?;
            require_success(
                &installed.executable,
                &prefix,
                &["plugins", "update", "inline"],
                None,
                INSTALL_TIMEOUT,
            )
            .await?;
            "updated"
        }
        PluginState::Missing => {
            require_plugin_install_allowed(args, "is not installed")?;
            require_success(
                &installed.executable,
                &prefix,
                &["plugins", "install", "@inline-openclaw/inline"],
                None,
                INSTALL_TIMEOUT,
            )
            .await?;
            "installed"
        }
        PluginState::ManagedBroken => {
            require_plugin_install_allowed(args, "is installed but unusable")?;
            require_success(
                &installed.executable,
                &prefix,
                &["plugins", "update", "inline"],
                None,
                INSTALL_TIMEOUT,
            )
            .await?;
            "repaired"
        }
        PluginState::Foreign => {
            require_plugin_install_allowed(args, "uses an unrecognized source")?;
            if !args.replace {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "the existing OpenClaw inline plugin has an unrecognized source; rerun with --replace to replace it",
                )
                .into());
            }
            require_success(
                &installed.executable,
                &prefix,
                &["plugins", "install", "@inline-openclaw/inline", "--force"],
                None,
                INSTALL_TIMEOUT,
            )
            .await?;
            "replaced"
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
    let PluginState::Healthy { version } = inspect_plugin_json(&plugin) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the Inline OpenClaw plugin is still unusable after setup",
        )
        .into());
    };

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
        let action = if status.success {
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
        (action, true)
    };
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

fn inspect_plugin(output: &super::process::CommandOutput) -> PluginState {
    if !output.success {
        return PluginState::Missing;
    }
    inspect_plugin_json(&output.stdout)
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
    if package_name != Some("@inline-openclaw/inline") {
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
        .unwrap_or(true);
    let version_ready = semver::Version::parse(&version).is_ok_and(|version| {
        version
            >= semver::Version::parse(MIN_SETUP_PLUGIN_VERSION)
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

fn require_plugin_install_allowed(
    args: &AgentsSetupArgs,
    reason: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    if args.no_install {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
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
    let value: serde_json::Value = serde_json::from_str(output).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "OpenClaw returned unreadable Inline channel status",
        )
    })?;
    let channel = value.pointer("/channels/inline").ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "OpenClaw returned no Inline channel status",
        )
    })?;
    let configured = channel
        .get("configured")
        .and_then(serde_json::Value::as_bool)
        == Some(true);
    let running = channel.get("running").and_then(serde_json::Value::as_bool) == Some(true);
    let probe_ok = channel
        .pointer("/probe/ok")
        .and_then(serde_json::Value::as_bool)
        == Some(true);
    let actual_id = channel.pointer("/probe/user/id").and_then(|value| {
        value
            .as_i64()
            .or_else(|| value.as_str().and_then(|value| value.parse().ok()))
    });
    if !configured || !running || !probe_ok || actual_id != Some(expected_bot_id) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "OpenClaw Inline channel did not verify as the selected bot",
        )
        .into());
    }
    Ok(())
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
            r#"{"channels":{"inline":{"configured":true,"running":true,"probe":{"ok":true,"user":{"id":"42"}}}}}"#,
            42,
        )
        .expect("matching bot verifies");
        assert!(
            verify_channel_status(
                r#"{"channels":{"inline":{"configured":true,"running":true,"probe":{"ok":true,"user":{"id":"43"}}}}}"#,
                42,
            )
            .is_err()
        );
    }

    #[test]
    fn plugin_inspection_distinguishes_healthy_and_foreign_sources() {
        let healthy = inspect_plugin_json(
            r#"{"plugin":{"packageName":"@inline-openclaw/inline","version":"0.0.56","status":"loaded","dependencyStatus":{"requiredInstalled":true}}}"#,
        );
        assert!(matches!(
            healthy,
            PluginState::Healthy { version } if version == "0.0.56"
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
    }
}
