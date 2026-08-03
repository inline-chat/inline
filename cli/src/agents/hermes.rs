use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use super::bot::ManagedBot;
use super::discovery::{InstalledTarget, find_executable};
use super::process::{require_success, require_success_with_environment, run_with_environment};
use super::{AccessMode, AgentsSetupArgs, GatewayPreflight, GatewaySetupOutcome};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(60);
const INSTALL_TIMEOUT: Duration = Duration::from_secs(180);
const MIN_MACHINE_PLUGIN_VERSION: &str = "0.0.6";

struct HermesProfile {
    home: Option<PathBuf>,
    environment: Vec<(OsString, OsString)>,
}

struct PluginSetup {
    action: &'static str,
    version: String,
}

pub(super) async fn preflight(
    installed: &InstalledTarget,
    args: &AgentsSetupArgs,
) -> Result<GatewayPreflight, Box<dyn std::error::Error>> {
    require_success(
        &installed.executable,
        &[],
        &["--version"],
        None,
        COMMAND_TIMEOUT,
    )
    .await?;
    let profile = resolve_profile(installed, args.profile.as_deref()).await?;
    let installer = find_executable("inline-hermes");
    let plugin_ready = match installer.as_deref() {
        Some(installer) => plugin_healthy(installer, profile.home.as_deref()).await?,
        None => false,
    };
    if !plugin_ready
        && !args.replace
        && let Some(installer) = installer.as_deref()
        && plugin_has_configured_credential(installer, profile.home.as_deref()).await?
    {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "the existing Hermes Inline plugin is configured but cannot report its bot identity; rerun with --replace to upgrade and replace it",
        )
        .into());
    }
    if args.no_install {
        installer.as_deref().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "inline-hermes is not installed and --no-install was provided",
            )
        })?;
        if !plugin_ready {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "the Inline Hermes plugin is not usable and --no-install was provided",
            )
            .into());
        }
    }
    let configured_bot_id = if plugin_ready {
        let status = run_with_environment(
            &installed.executable,
            &[],
            &["inline", "status", "--json", "--probe"],
            None,
            COMMAND_TIMEOUT,
            &profile.environment,
        )
        .await?;
        if status.success {
            status_bot_id(&status.stdout)
        } else {
            None
        }
    } else {
        None
    };
    Ok(GatewayPreflight { configured_bot_id })
}

pub(super) async fn setup(
    installed: &InstalledTarget,
    bot: &ManagedBot,
    args: &AgentsSetupArgs,
) -> Result<GatewaySetupOutcome, Box<dyn std::error::Error>> {
    let profile = resolve_profile(installed, args.profile.as_deref()).await?;
    let environment = &profile.environment;
    let _host_version = require_success(
        &installed.executable,
        &[],
        &["--version"],
        None,
        COMMAND_TIMEOUT,
    )
    .await?;
    let installer = find_executable("inline-hermes");
    let integration = ensure_plugin(
        installer.as_deref(),
        args.no_install,
        profile.home.as_deref(),
    )
    .await?;
    require_success_with_environment(
        &installed.executable,
        &[],
        &[
            "plugins",
            "enable",
            "inline-platform",
            "--no-allow-tool-override",
        ],
        None,
        COMMAND_TIMEOUT,
        environment,
    )
    .await?;

    let owner_user_id = bot.owner_user_id.to_string();
    let allowed = args
        .allow_users
        .iter()
        .map(i64::to_string)
        .collect::<Vec<_>>();
    let mut setup_args = vec![
        "inline".to_string(),
        "setup".to_string(),
        "--non-interactive".to_string(),
        "--token-stdin".to_string(),
        "--owner-user-id".to_string(),
        owner_user_id,
        "--access".to_string(),
        access_name(args.access).to_string(),
        "--json".to_string(),
    ];
    for user_id in &allowed {
        setup_args.push("--allow-user".to_string());
        setup_args.push(user_id.clone());
    }
    let setup_refs = setup_args.iter().map(String::as_str).collect::<Vec<_>>();
    let mut token_input = bot.token().as_bytes().to_vec();
    token_input.push(b'\n');
    require_success_with_environment(
        &installed.executable,
        &[],
        &setup_refs,
        Some(&token_input),
        COMMAND_TIMEOUT,
        environment,
    )
    .await?;

    let (service_action, ready) = if args.no_restart {
        ("skipped", false)
    } else {
        let status = run_with_environment(
            &installed.executable,
            &[],
            &["gateway", "status"],
            None,
            COMMAND_TIMEOUT,
            environment,
        )
        .await?;
        let action = if status.success {
            require_success_with_environment(
                &installed.executable,
                &[],
                &["gateway", "restart"],
                None,
                INSTALL_TIMEOUT,
                environment,
            )
            .await?;
            "restarted"
        } else {
            require_success_with_environment(
                &installed.executable,
                &[],
                &["gateway", "install", "--start-now"],
                None,
                INSTALL_TIMEOUT,
                environment,
            )
            .await?;
            "installed"
        };
        let status = require_success_with_environment(
            &installed.executable,
            &[],
            &["inline", "status", "--json", "--probe"],
            None,
            COMMAND_TIMEOUT,
            environment,
        )
        .await?;
        verify_status(&status, bot.id)?;
        (action, true)
    };

    doctor_plugin(
        if integration.action == "kept" {
            installer.as_deref()
        } else {
            None
        },
        profile.home.as_deref(),
    )
    .await?;
    Ok(GatewaySetupOutcome {
        integration_action: integration.action,
        integration_version: integration.version,
        service_action,
        ready,
    })
}

async fn ensure_plugin(
    installer: Option<&Path>,
    no_install: bool,
    hermes_home: Option<&Path>,
) -> Result<PluginSetup, Box<dyn std::error::Error>> {
    if let Some(installer) = installer {
        let (healthy, version) = plugin_status(installer, hermes_home).await?;
        if healthy {
            return Ok(PluginSetup {
                action: "kept",
                version,
            });
        }
        if no_install {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "the Inline Hermes plugin is not usable and --no-install was provided",
            )
            .into());
        }
        let version = install_latest_plugin(hermes_home).await?;
        return Ok(PluginSetup {
            action: "repaired",
            version,
        });
    }
    if no_install {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "inline-hermes is not installed and --no-install was provided",
        )
        .into());
    }
    let version = install_latest_plugin(hermes_home).await?;
    Ok(PluginSetup {
        action: "installed",
        version,
    })
}

async fn install_latest_plugin(
    hermes_home: Option<&Path>,
) -> Result<String, Box<dyn std::error::Error>> {
    let npm = find_executable("npm").ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "npm is required to install the Inline Hermes plugin",
        )
    })?;
    let mut install_args = vec![
        "exec".to_string(),
        "--yes".to_string(),
        "--package=@inline-chat/hermes-agent-adapter@latest".to_string(),
        "--".to_string(),
        "inline-hermes".to_string(),
    ];
    install_args.extend(installer_args("install", hermes_home, &["--json"]));
    let install_refs = install_args.iter().map(String::as_str).collect::<Vec<_>>();
    let output = require_success(&npm, &[], &install_refs, None, INSTALL_TIMEOUT).await?;
    Ok(plugin_package_version(&output).unwrap_or_else(|| "latest".to_string()))
}

async fn plugin_healthy(
    installer: &Path,
    hermes_home: Option<&Path>,
) -> Result<bool, Box<dyn std::error::Error>> {
    Ok(plugin_status(installer, hermes_home).await?.0)
}

async fn plugin_status(
    installer: &Path,
    hermes_home: Option<&Path>,
) -> Result<(bool, String), Box<dyn std::error::Error>> {
    let args = installer_args("status", hermes_home, &["--json"]);
    let refs = args.iter().map(String::as_str).collect::<Vec<_>>();
    let status = super::process::run(installer, &[], &refs, None, COMMAND_TIMEOUT).await?;
    let version = plugin_package_version(&status.stdout).unwrap_or_else(|| "unknown".to_string());
    Ok((
        plugin_status_healthy(status.success, &status.stdout),
        version,
    ))
}

fn plugin_package_version(output: &str) -> Option<String> {
    serde_json::from_str::<serde_json::Value>(output)
        .ok()?
        .get("packageVersion")?
        .as_str()
        .map(str::to_string)
}

async fn plugin_has_configured_credential(
    installer: &Path,
    hermes_home: Option<&Path>,
) -> Result<bool, Box<dyn std::error::Error>> {
    let args = installer_args("status", hermes_home, &["--json"]);
    let refs = args.iter().map(String::as_str).collect::<Vec<_>>();
    let status = super::process::run(installer, &[], &refs, None, COMMAND_TIMEOUT).await?;
    if !status.success {
        return Ok(false);
    }
    let configured = serde_json::from_str::<serde_json::Value>(&status.stdout)
        .ok()
        .and_then(|value| {
            value
                .pointer("/activation/tokenConfigured")
                .and_then(serde_json::Value::as_bool)
        })
        == Some(true);
    Ok(configured)
}

fn plugin_status_healthy(success: bool, output: &str) -> bool {
    if !success {
        return false;
    }
    let Ok(value) = serde_json::from_str::<serde_json::Value>(output) else {
        return false;
    };
    let reported_ok = value.get("ok").and_then(serde_json::Value::as_bool) == Some(true);
    let version = value
        .get("packageVersion")
        .and_then(serde_json::Value::as_str)
        .and_then(|version| semver::Version::parse(version).ok());
    let minimum = semver::Version::parse(MIN_MACHINE_PLUGIN_VERSION)
        .expect("machine plugin minimum must be valid semver");
    reported_ok && version.is_some_and(|version| version >= minimum)
}

async fn doctor_plugin(
    installer: Option<&Path>,
    hermes_home: Option<&Path>,
) -> Result<(), Box<dyn std::error::Error>> {
    let doctor_args = installer_args("doctor", hermes_home, &["--json"]);
    if let Some(installer) = installer {
        let refs = doctor_args.iter().map(String::as_str).collect::<Vec<_>>();
        require_success(installer, &[], &refs, None, COMMAND_TIMEOUT).await?;
        return Ok(());
    }
    let npm = find_executable("npm").ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "npm is required to verify the Inline Hermes plugin",
        )
    })?;
    let mut args = vec![
        "exec".to_string(),
        "--yes".to_string(),
        "--package=@inline-chat/hermes-agent-adapter@latest".to_string(),
        "--".to_string(),
        "inline-hermes".to_string(),
    ];
    args.extend(doctor_args);
    let refs = args.iter().map(String::as_str).collect::<Vec<_>>();
    require_success(&npm, &[], &refs, None, INSTALL_TIMEOUT).await?;
    Ok(())
}

async fn resolve_profile(
    installed: &InstalledTarget,
    profile: Option<&str>,
) -> Result<HermesProfile, Box<dyn std::error::Error>> {
    let Some(profile) = profile.filter(|profile| *profile != "default") else {
        return Ok(HermesProfile {
            home: None,
            environment: Vec::new(),
        });
    };
    let output = require_success(
        &installed.executable,
        &[],
        &["profile", "show", profile],
        None,
        COMMAND_TIMEOUT,
    )
    .await?;
    let home = parse_profile_home(&output)?;
    Ok(HermesProfile {
        environment: vec![(
            OsString::from("HERMES_HOME"),
            home.as_os_str().to_os_string(),
        )],
        home: Some(home),
    })
}

fn parse_profile_home(output: &str) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let home = output
        .lines()
        .find_map(|line| line.trim().strip_prefix("Path:").map(str::trim))
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "Hermes returned no absolute profile path",
            )
        })?;
    Ok(home)
}

fn installer_args(command: &str, hermes_home: Option<&Path>, tail: &[&str]) -> Vec<String> {
    let mut args = vec![command.to_string()];
    if let Some(home) = hermes_home {
        args.push("--hermes-home".to_string());
        args.push(home.to_string_lossy().into_owned());
    }
    args.extend(tail.iter().map(|value| (*value).to_string()));
    args
}

fn access_name(access: AccessMode) -> &'static str {
    match access {
        AccessMode::Owner => "owner",
        AccessMode::Allowlist => "allowlist",
        AccessMode::Open => "open",
        AccessMode::Disabled => "disabled",
    }
}

fn verify_status(output: &str, expected_bot_id: i64) -> Result<(), Box<dyn std::error::Error>> {
    let value: serde_json::Value = serde_json::from_str(output).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "Hermes returned unreadable Inline status",
        )
    })?;
    let ok = value.get("ok").and_then(serde_json::Value::as_bool) == Some(true);
    let actual_id = value.pointer("/probe/botUserId").and_then(|value| {
        value
            .as_i64()
            .or_else(|| value.as_str().and_then(|value| value.parse().ok()))
    });
    if !ok || actual_id != Some(expected_bot_id) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Hermes Inline credential did not verify as the selected bot",
        )
        .into());
    }
    Ok(())
}

fn status_bot_id(output: &str) -> Option<i64> {
    let value: serde_json::Value = serde_json::from_str(output).ok()?;
    value.pointer("/probe/botUserId").and_then(|value| {
        value
            .as_i64()
            .or_else(|| value.as_str().and_then(|value| value.parse().ok()))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_verification_requires_the_selected_bot() {
        verify_status(r#"{"ok":true,"probe":{"botUserId":"42"}}"#, 42)
            .expect("matching bot verifies");
        assert!(verify_status(r#"{"ok":true,"probe":{"botUserId":"43"}}"#, 42).is_err());
        assert!(verify_status(r#"{"ok":false}"#, 42).is_err());
    }

    #[test]
    fn parses_profile_home_without_reading_profile_files() {
        assert_eq!(
            parse_profile_home("Profile: work\nPath:    /Users/example/.hermes/profiles/work\n")
                .expect("profile home"),
            PathBuf::from("/Users/example/.hermes/profiles/work")
        );
        assert!(parse_profile_home("Profile: work\nPath: relative/path\n").is_err());
    }

    #[test]
    fn plugin_health_requires_the_machine_setup_contract_version() {
        assert!(plugin_status_healthy(
            true,
            r#"{"ok":true,"packageVersion":"0.0.6"}"#
        ));
        assert!(!plugin_status_healthy(
            true,
            r#"{"ok":true,"packageVersion":"0.0.5"}"#
        ));
        assert!(!plugin_status_healthy(
            false,
            r#"{"ok":true,"packageVersion":"9.0.0"}"#
        ));
    }
}
