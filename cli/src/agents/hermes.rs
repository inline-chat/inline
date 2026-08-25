use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use super::bot::ManagedBot;
use super::discovery::{InstalledTarget, find_executable};
use super::process::{require_success, require_success_with_environment, run_with_environment};
use super::{AccessMode, AgentsSetupArgs, GatewayPreflight, GatewaySetupOutcome, cli_error};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(60);
const INSTALL_TIMEOUT: Duration = Duration::from_secs(180);
const MACHINE_SETUP_PROTOCOL_VERSION: u64 = 1;
const MINIMUM_HERMES_PLUGIN_VERSION: &str = "0.0.7";
const HERMES_PLUGIN_PACKAGE_SPEC: &str = "@inline-chat/hermes-agent-adapter";

struct HermesProfile {
    home: Option<PathBuf>,
    environment: Vec<(OsString, OsString)>,
}

struct PluginSetup {
    action: &'static str,
    version: String,
}

struct MachinePluginStatus {
    version: String,
    configured: bool,
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
    if let Some(machine) = machine_plugin_status(installed, &profile.environment, false).await? {
        let configured_bot_id = if machine.configured {
            let status = run_machine_status(installed, &profile.environment, true).await?;
            let bot_id = status_bot_id(&status.stdout).filter(|_| status.success);
            if bot_id.is_none() && !args.replace {
                return Err(cli_error(
                    "setup_conflict",
                    "the existing Hermes Inline credential cannot be verified; rerun with --replace to replace it",
                )
                .into());
            }
            bot_id
        } else {
            None
        };
        return Ok(GatewayPreflight { configured_bot_id });
    }

    let legacy_configured = match installer.as_deref() {
        Some(installer) => {
            plugin_has_configured_credential(installer, profile.home.as_deref()).await?
                || legacy_plugin_configured(installed, &profile.environment).await?
        }
        None => legacy_plugin_configured(installed, &profile.environment).await?,
    };
    if legacy_configured && !args.replace {
        return Err(cli_error(
            "setup_conflict",
            "the existing Hermes Inline plugin is configured but cannot report its bot identity; rerun with --replace to upgrade and replace it",
        )
        .into());
    }
    if args.no_install {
        if installer.is_none() {
            return Err(cli_error(
                "plugin_unavailable",
                "inline-hermes is not installed and --no-install was provided",
            )
            .into());
        }
        return Err(cli_error(
            "plugin_unavailable",
            "the Inline Hermes plugin does not support machine setup and --no-install was provided",
        )
        .into());
    }
    Ok(GatewayPreflight {
        configured_bot_id: None,
    })
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
    let current_machine = machine_plugin_status(installed, environment, false).await?;
    let mut integration = ensure_plugin(
        current_machine,
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
    let machine = machine_plugin_status(installed, environment, false)
        .await?
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "the installed Inline Hermes plugin does not provide the required machine setup protocol",
            )
        })?;
    integration.version = machine.version;

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

    let credential_status = require_success_with_environment(
        &installed.executable,
        &[],
        &["inline", "status", "--json", "--probe"],
        None,
        COMMAND_TIMEOUT,
        environment,
    )
    .await?;
    verify_status(&credential_status, bot.id)?;

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
        require_success_with_environment(
            &installed.executable,
            &[],
            &["gateway", "status"],
            None,
            COMMAND_TIMEOUT,
            environment,
        )
        .await?;
        (action, true)
    };

    Ok(GatewaySetupOutcome {
        integration_action: integration.action,
        integration_version: integration.version,
        service_action,
        ready,
    })
}

async fn ensure_plugin(
    current_machine: Option<MachinePluginStatus>,
    installer: Option<&Path>,
    no_install: bool,
    hermes_home: Option<&Path>,
) -> Result<PluginSetup, Box<dyn std::error::Error>> {
    if let Some(machine) = current_machine {
        return Ok(PluginSetup {
            action: "kept",
            version: machine.version,
        });
    }
    if let Some(installer) = installer {
        let (healthy, version) = plugin_status(installer, hermes_home).await?;
        if healthy {
            return Ok(PluginSetup {
                action: "kept",
                version,
            });
        }
    }
    if no_install {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "the Inline Hermes plugin does not support machine setup and --no-install was provided",
        )
        .into());
    }
    let version = install_latest_plugin(hermes_home).await?;
    Ok(PluginSetup {
        action: if installer.is_some() {
            "repaired"
        } else {
            "installed"
        },
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
    let install_args = latest_plugin_install_args(hermes_home);
    let install_refs = install_args.iter().map(String::as_str).collect::<Vec<_>>();
    let output = require_success(&npm, &[], &install_refs, None, INSTALL_TIMEOUT).await?;
    let installed_version = plugin_package_version(&output).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "the latest Inline Hermes installer returned no package version",
        )
    })?;
    if semver::Version::parse(&installed_version).is_err() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("the Inline Hermes installer returned invalid version {installed_version}"),
        )
        .into());
    }
    Ok(installed_version)
}

fn latest_plugin_install_args(hermes_home: Option<&Path>) -> Vec<String> {
    let mut install_args = vec![
        "exec".to_string(),
        "--yes".to_string(),
        format!("--package={HERMES_PLUGIN_PACKAGE_SPEC}"),
        "--".to_string(),
        "inline-hermes".to_string(),
    ];
    install_args.extend(installer_args(
        "install",
        hermes_home,
        &["--force", "--json"],
    ));
    install_args
}

fn plugin_package_version(output: &str) -> Option<String> {
    serde_json::from_str::<serde_json::Value>(output)
        .ok()?
        .get("packageVersion")?
        .as_str()
        .map(str::to_string)
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
    let minimum = semver::Version::parse(MINIMUM_HERMES_PLUGIN_VERSION)
        .expect("minimum Hermes plugin version must be valid semver");
    reported_ok && version.is_some_and(|version| version >= minimum)
}

async fn plugin_has_configured_credential(
    installer: &Path,
    hermes_home: Option<&Path>,
) -> Result<bool, Box<dyn std::error::Error>> {
    let args = installer_args("status", hermes_home, &["--json"]);
    let refs = args.iter().map(String::as_str).collect::<Vec<_>>();
    let status = super::process::run(installer, &[], &refs, None, COMMAND_TIMEOUT).await?;
    Ok(plugin_status_has_configured_credential(
        status.success,
        &status.stdout,
    ))
}

fn plugin_status_has_configured_credential(_success: bool, output: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(output)
        .ok()
        .and_then(|value| {
            value
                .pointer("/activation/tokenConfigured")
                .and_then(serde_json::Value::as_bool)
        })
        // An old, broken, or malformed installer must not erase evidence of a
        // possibly configured credential. Requiring --replace is recoverable;
        // silently overwriting the credential is not.
        .unwrap_or(true)
}

async fn machine_plugin_status(
    installed: &InstalledTarget,
    environment: &[(OsString, OsString)],
    probe: bool,
) -> Result<Option<MachinePluginStatus>, Box<dyn std::error::Error>> {
    let status = run_machine_status(installed, environment, probe).await?;
    Ok(parse_machine_plugin_status(status.success, &status.stdout))
}

async fn run_machine_status(
    installed: &InstalledTarget,
    environment: &[(OsString, OsString)],
    probe: bool,
) -> Result<super::process::CommandOutput, Box<dyn std::error::Error>> {
    let args = if probe {
        &["inline", "status", "--json", "--probe"][..]
    } else {
        &["inline", "status", "--json"][..]
    };
    run_with_environment(
        &installed.executable,
        &[],
        args,
        None,
        COMMAND_TIMEOUT,
        environment,
    )
    .await
}

fn parse_machine_plugin_status(success: bool, output: &str) -> Option<MachinePluginStatus> {
    if !success {
        return None;
    }
    let value = serde_json::from_str::<serde_json::Value>(output).ok()?;
    let protocol = value
        .get("setupProtocolVersion")
        .and_then(serde_json::Value::as_u64)?;
    let version = value
        .get("pluginVersion")
        .and_then(serde_json::Value::as_str)
        .and_then(|version| semver::Version::parse(version).ok())?;
    let minimum = semver::Version::parse(MINIMUM_HERMES_PLUGIN_VERSION)
        .expect("minimum Hermes plugin version must be valid semver");
    let sidecar_bundled = value
        .get("sidecarBundled")
        .and_then(serde_json::Value::as_bool)
        == Some(true);
    let sidecar_usable = value
        .pointer("/sidecar/ok")
        .and_then(serde_json::Value::as_bool)
        == Some(true);
    let node_usable = value
        .pointer("/node/ok")
        .and_then(serde_json::Value::as_bool)
        == Some(true);
    if protocol < MACHINE_SETUP_PROTOCOL_VERSION
        || version < minimum
        || !sidecar_bundled
        || !sidecar_usable
        || !node_usable
    {
        return None;
    }
    Some(MachinePluginStatus {
        version: version.to_string(),
        configured: value.get("configured").and_then(serde_json::Value::as_bool) == Some(true),
    })
}

async fn legacy_plugin_configured(
    installed: &InstalledTarget,
    environment: &[(OsString, OsString)],
) -> Result<bool, Box<dyn std::error::Error>> {
    let status = run_with_environment(
        &installed.executable,
        &[],
        &["inline", "status"],
        None,
        COMMAND_TIMEOUT,
        environment,
    )
    .await?;
    Ok(status.success
        && status
            .stdout
            .lines()
            .any(|line| line.trim().eq_ignore_ascii_case("Inline configured: yes")))
}

async fn resolve_profile(
    installed: &InstalledTarget,
    profile: Option<&str>,
) -> Result<HermesProfile, Box<dyn std::error::Error>> {
    let Some(profile) = profile.filter(|profile| *profile != "default") else {
        return Ok(HermesProfile {
            home: None,
            environment: cli_environment(),
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
    let mut environment = cli_environment();
    environment.push((
        OsString::from("HERMES_HOME"),
        home.as_os_str().to_os_string(),
    ));
    Ok(HermesProfile {
        environment,
        home: Some(home),
    })
}

fn cli_environment() -> Vec<(OsString, OsString)> {
    std::env::current_exe()
        .ok()
        .filter(|path| path.is_absolute())
        .map(|path| {
            vec![(
                OsString::from("INLINE_CLI_BIN"),
                path.as_os_str().to_os_string(),
            )]
        })
        .unwrap_or_default()
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
            r#"{"ok":true,"packageVersion":"0.0.7"}"#
        ));
        assert!(!plugin_status_healthy(
            true,
            r#"{"ok":true,"packageVersion":"0.0.6"}"#
        ));
        assert!(!plugin_status_healthy(
            false,
            r#"{"ok":true,"packageVersion":"9.0.0"}"#
        ));
    }

    #[test]
    fn outdated_managed_plugin_is_repaired_with_the_latest_package_and_force() {
        assert!(!plugin_status_healthy(
            true,
            r#"{"ok":true,"packageVersion":"0.0.6"}"#
        ));
        assert_eq!(
            latest_plugin_install_args(Some(Path::new("/tmp/hermes-profile"))),
            vec![
                "exec",
                "--yes",
                "--package=@inline-chat/hermes-agent-adapter",
                "--",
                "inline-hermes",
                "install",
                "--hermes-home",
                "/tmp/hermes-profile",
                "--force",
                "--json",
            ]
        );
    }

    #[test]
    fn configured_credential_survives_nonzero_or_malformed_installer_status() {
        assert!(plugin_status_has_configured_credential(
            false,
            r#"{"ok":false,"activation":{"tokenConfigured":true}}"#,
        ));
        assert!(!plugin_status_has_configured_credential(
            false,
            r#"{"ok":false,"activation":{"tokenConfigured":false}}"#,
        ));
        assert!(plugin_status_has_configured_credential(false, "not json"));
        assert!(plugin_status_has_configured_credential(
            true,
            r#"{"ok":true}"#
        ));
    }

    #[test]
    fn live_machine_contract_is_independent_of_installer_state() {
        let status = parse_machine_plugin_status(
            true,
            r#"{"ok":false,"setupProtocolVersion":1,"pluginVersion":"0.0.8","configured":false,"sidecarBundled":true,"sidecar":{"ok":true},"node":{"ok":true}}"#,
        )
        .expect("unconfigured live plugin still provides setup capability");
        assert_eq!(status.version, "0.0.8");
        assert!(!status.configured);

        assert!(
            parse_machine_plugin_status(
                true,
                r#"{"ok":true,"setupProtocolVersion":1,"pluginVersion":"0.0.6","configured":true,"sidecarBundled":true,"sidecar":{"ok":true},"node":{"ok":true}}"#,
            )
            .is_none()
        );
        assert!(
            parse_machine_plugin_status(
                true,
                r#"{"ok":true,"setupProtocolVersion":1,"pluginVersion":"0.0.8","configured":true,"sidecarBundled":false,"sidecar":{"ok":true},"node":{"ok":true}}"#,
            )
            .is_none()
        );
        assert!(
            parse_machine_plugin_status(
                true,
                r#"{"ok":true,"setupProtocolVersion":1,"pluginVersion":"0.0.8","configured":true,"sidecarBundled":true,"sidecar":{"ok":false},"node":{"ok":true}}"#,
            )
            .is_none()
        );
        assert!(
            parse_machine_plugin_status(
                true,
                r#"{"ok":true,"setupProtocolVersion":1,"pluginVersion":"0.0.8","configured":true,"sidecarBundled":true,"sidecar":{"ok":true},"node":{"ok":false}}"#,
            )
            .is_none()
        );
    }
}
