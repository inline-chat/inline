use std::io;
use std::path::{Path, PathBuf};

use super::{AccountBridgeConfig, BridgePaths};

pub(super) fn validate_service_paths(
    paths: &BridgePaths,
    account: &AccountBridgeConfig,
) -> io::Result<()> {
    if account.service_binary != paths.installed_binary {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bridge service binary does not match the account installation path",
        ));
    }
    for (label, path) in [
        ("bridge root", &paths.root),
        ("bridge config", &paths.config),
        ("bridge service binary", &paths.installed_binary),
    ] {
        if !path.is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{label} must be an absolute path: {}", path.display()),
            ));
        }
        utf8_service_path(path, label)?;
    }
    Ok(())
}

pub(super) fn utf8_service_path<'a>(path: &'a Path, label: &str) -> io::Result<&'a str> {
    path.to_str().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{label} must use a UTF-8 path"),
        )
    })
}

#[cfg(target_os = "macos")]
pub(super) fn service_definition_path(label: &str) -> io::Result<PathBuf> {
    let directory = std::env::var_os("INLINE_BRIDGE_LAUNCH_AGENT_DIR")
        .map(PathBuf::from)
        .map(Ok)
        .unwrap_or_else(|| required_home_dir().map(|home| home.join("Library/LaunchAgents")))?;
    require_absolute_service_directory(&directory)?;
    Ok(directory.join(format!("{label}.plist")))
}

#[cfg(target_os = "linux")]
pub(super) fn service_definition_path(label: &str) -> io::Result<PathBuf> {
    let directory = std::env::var_os("INLINE_BRIDGE_SYSTEMD_USER_DIR")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .map(|root| root.join("systemd").join("user"))
        })
        .map(Ok)
        .unwrap_or_else(|| required_home_dir().map(|home| home.join(".config/systemd/user")))?;
    require_absolute_service_directory(&directory)?;
    Ok(directory.join(systemd_unit_name(label)))
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
pub(super) fn required_home_dir() -> io::Result<PathBuf> {
    let home = std::env::var_os("HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "HOME is not configured"))?;
    require_absolute_service_directory(&home)?;
    Ok(home)
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
pub(super) fn require_absolute_service_directory(directory: &Path) -> io::Result<()> {
    if !directory.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "bridge service directory must be absolute: {}",
                directory.display()
            ),
        ));
    }
    Ok(())
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(super) fn service_definition_path(_label: &str) -> io::Result<PathBuf> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "background service definitions are available only on macOS or Linux",
    ))
}

#[cfg(any(target_os = "macos", test))]
pub(super) fn render_launch_agent_plist(
    account: &AccountBridgeConfig,
    paths: &BridgePaths,
) -> io::Result<String> {
    let service_binary = utf8_service_path(&account.service_binary, "bridge service binary")?;
    let config = utf8_service_path(&paths.config, "bridge config")?;
    let stdout_log = utf8_service_path(&paths.stdout_log, "bridge stdout log")?;
    let stderr_log = utf8_service_path(&paths.stderr_log, "bridge stderr log")?;
    let root = utf8_service_path(&paths.root, "bridge root")?;
    for required in [
        account.service_label.as_str(),
        service_binary,
        config,
        stdout_log,
        stderr_log,
        root,
        account.provider_path.as_str(),
    ] {
        if required.is_empty()
            || required.chars().any(|character| {
                character == '\0'
                    || (character.is_control() && !matches!(character, '\t' | '\n' | '\r'))
            })
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "bridge service configuration contains an invalid empty or control value",
            ));
        }
    }
    let values = [
        service_binary.to_string(),
        "bridge".to_string(),
        "run".to_string(),
        "--config".to_string(),
        config.to_string(),
    ];
    let arguments = values
        .iter()
        .map(|value| format!("    <string>{}</string>", xml_escape(value)))
        .collect::<Vec<_>>()
        .join("\n");
    Ok(format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{label}</string>
  <key>ProgramArguments</key>
  <array>
{arguments}
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>{provider_path}</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>{workspace}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>{stdout}</string>
  <key>StandardErrorPath</key>
  <string>{stderr}</string>
</dict>
</plist>
"#,
        label = xml_escape(&account.service_label),
        provider_path = xml_escape(&account.provider_path),
        workspace = xml_escape(root),
        stdout = xml_escape(stdout_log),
        stderr = xml_escape(stderr_log),
    ))
}

#[cfg(any(target_os = "linux", test))]
pub(super) fn render_systemd_user_unit(
    account: &AccountBridgeConfig,
    paths: &BridgePaths,
) -> io::Result<String> {
    let service_binary = utf8_service_path(&account.service_binary, "bridge service binary")?;
    let config = utf8_service_path(&paths.config, "bridge config")?;
    let root = utf8_service_path(&paths.root, "bridge root")?;
    for required in [
        account.service_label.as_str(),
        service_binary,
        config,
        root,
        account.provider_path.as_str(),
    ] {
        if required.is_empty()
            || required
                .chars()
                .any(|character| matches!(character, '\0' | '\n' | '\r'))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "bridge service configuration contains an invalid empty, NUL, or newline value",
            ));
        }
    }
    let exec_start = [
        service_binary.to_string(),
        "bridge".to_string(),
        "run".to_string(),
        "--config".to_string(),
        config.to_string(),
    ]
    .iter()
    .map(|argument| systemd_quote(argument))
    .collect::<Vec<_>>()
    .join(" ");
    let description = format!("Inline account {}", account.owner_user_id);
    Ok(format!(
        "[Unit]\n\
Description=Inline local coding-agent bridge ({description})\n\
After=network-online.target\n\
Wants=network-online.target\n\
StartLimitIntervalSec=0\n\
\n\
[Service]\n\
Type=simple\n\
ExecStart={exec_start}\n\
WorkingDirectory={}\n\
Environment={}\n\
Restart=on-failure\n\
RestartSec=10s\n\
RestartPreventExitStatus=78\n\
TimeoutStartSec=30s\n\
TimeoutStopSec=30s\n\
KillMode=control-group\n\
UMask=0077\n\
NoNewPrivileges=true\n\
\n\
[Install]\n\
WantedBy=default.target\n",
        systemd_quote(root),
        systemd_directive_quote(&format!("PATH={}", account.provider_path)),
    ))
}

#[cfg(any(target_os = "linux", test))]
pub(super) fn systemd_quote(value: &str) -> String {
    let escaped = value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('%', "%%")
        .replace('$', "$$");
    format!("\"{escaped}\"")
}

#[cfg(any(target_os = "linux", test))]
pub(super) fn systemd_directive_quote(value: &str) -> String {
    let escaped = value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('%', "%%");
    format!("\"{escaped}\"")
}

#[cfg(target_os = "linux")]
pub(super) fn systemd_unit_name(label: &str) -> String {
    format!("{label}.service")
}

#[cfg(any(target_os = "macos", test))]
pub(super) fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
