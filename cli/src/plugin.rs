use serde::Serialize;
use serde_json::Value;
use std::env;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::Command;

use crate::errors::CliError;
use crate::output::{self, JsonFormat};

const MARKETPLACE_SOURCE: &str = "inline-chat/inline";
const MAX_HOST_OUTPUT: usize = 128 * 1024;

/// Agent hosts whose plugin managers can install Inline's packaged plugin.
#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::ValueEnum)]
pub(crate) enum PluginHost {
    Codex,
    Claude,
}

impl PluginHost {
    const ALL: [PluginHost; 2] = [PluginHost::Codex, PluginHost::Claude];

    fn id(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::Claude => "claude",
        }
    }

    fn display_name(self) -> &'static str {
        match self {
            Self::Codex => "Codex",
            Self::Claude => "Claude Code",
        }
    }

    // Claude Code reserves the `inline` marketplace name, so the repository
    // publishes its Claude marketplace as `inline-chat`.
    fn marketplace(self) -> &'static str {
        match self {
            Self::Codex => "inline",
            Self::Claude => "inline-chat",
        }
    }

    fn plugin_id(self) -> &'static str {
        match self {
            Self::Codex => "inline@inline",
            Self::Claude => "inline@inline-chat",
        }
    }

    fn install_verb(self) -> &'static str {
        match self {
            Self::Codex => "add",
            Self::Claude => "install",
        }
    }

    fn unavailable_code(self) -> &'static str {
        match self {
            Self::Codex => "codex_plugin_unavailable",
            Self::Claude => "claude_plugin_unavailable",
        }
    }

    fn failed_code(self) -> &'static str {
        match self {
            Self::Codex => "codex_plugin_failed",
            Self::Claude => "claude_plugin_failed",
        }
    }

    fn sign_in_hint(self) -> &'static str {
        match self {
            Self::Codex => "Start a new Codex session to load the plugin.",
            Self::Claude => {
                "Start a new Claude Code session, then run /mcp to sign in to the inline server."
            }
        }
    }

    fn candidates(self) -> Vec<PathBuf> {
        let mut candidates = Vec::new();
        let override_var = match self {
            Self::Codex => "INLINE_CODEX_BIN",
            Self::Claude => "INLINE_CLAUDE_BIN",
        };
        if let Some(path) = env::var_os(override_var).filter(|value| !value.is_empty()) {
            candidates.push(PathBuf::from(path));
        }
        candidates.push(PathBuf::from(self.id()));
        match self {
            Self::Codex => {
                #[cfg(target_os = "macos")]
                {
                    candidates.push(PathBuf::from(
                        "/Applications/ChatGPT.app/Contents/Resources/codex",
                    ));
                    candidates.push(PathBuf::from(
                        "/Applications/Codex.app/Contents/Resources/codex",
                    ));
                }
            }
            Self::Claude => {
                if let Some(home) = env::var_os("HOME").filter(|value| !value.is_empty()) {
                    let home = PathBuf::from(home);
                    candidates.push(home.join(".claude/local/claude"));
                    candidates.push(home.join(".local/bin/claude"));
                }
            }
        }
        candidates.dedup();
        candidates
    }

    fn install_commands(self) -> Vec<Vec<String>> {
        vec![
            vec![
                self.id().to_string(),
                "plugin".to_string(),
                "marketplace".to_string(),
                "add".to_string(),
                MARKETPLACE_SOURCE.to_string(),
            ],
            vec![
                self.id().to_string(),
                "plugin".to_string(),
                self.install_verb().to_string(),
                self.plugin_id().to_string(),
            ],
        ]
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PluginInstallOutput {
    status: &'static str,
    hosts: Vec<HostInstallOutput>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct HostInstallOutput {
    host: &'static str,
    plugin_id: &'static str,
    marketplace: &'static str,
    includes: [&'static str; 2],
    commands: Vec<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    marketplace_already_added: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    auth_policy: Option<String>,
}

impl HostInstallOutput {
    fn planned(host: PluginHost) -> Self {
        Self {
            host: host.id(),
            plugin_id: host.plugin_id(),
            marketplace: host.marketplace(),
            includes: ["skill", "oauth_mcp"],
            commands: host.install_commands(),
            marketplace_already_added: None,
            version: None,
            auth_policy: None,
        }
    }
}

/// Installs the plugin into the requested host, or into every detected host
/// when none is requested. A dry run prints the plans without probing hosts.
pub(crate) async fn install(
    host: Option<PluginHost>,
    dry_run: bool,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let requested: Vec<PluginHost> =
        host.map_or_else(|| PluginHost::ALL.to_vec(), |host| vec![host]);
    if dry_run {
        let result = PluginInstallOutput {
            status: "dry_run",
            hosts: requested
                .into_iter()
                .map(HostInstallOutput::planned)
                .collect(),
        };
        print_result(&result, json, json_format)?;
        return Ok(());
    }

    let mut detected = Vec::new();
    for candidate_host in &requested {
        if let Some(binary) = find_host_with_plugins(*candidate_host).await {
            detected.push((*candidate_host, binary));
        }
    }
    if detected.is_empty() {
        return Err(unavailable_error(host).into());
    }

    let mut hosts = Vec::new();
    for (host, binary) in detected {
        let marketplace = run_host_install(
            host,
            &binary,
            &["plugin", "marketplace", "add", MARKETPLACE_SOURCE],
            "add the Inline plugin marketplace",
        )
        .await?;
        let installed = run_host_install(
            host,
            &binary,
            &["plugin", host.install_verb(), host.plugin_id()],
            "install the Inline plugin",
        )
        .await?;
        hosts.push(HostInstallOutput {
            marketplace_already_added: marketplace.get("alreadyAdded").and_then(Value::as_bool),
            version: installed
                .get("version")
                .and_then(Value::as_str)
                .map(str::to_string),
            auth_policy: installed
                .get("authPolicy")
                .and_then(Value::as_str)
                .map(str::to_string),
            ..HostInstallOutput::planned(host)
        });
    }

    let result = PluginInstallOutput {
        status: "installed",
        hosts,
    };
    print_result(&result, json, json_format)?;
    Ok(())
}

fn print_result(
    result: &PluginInstallOutput,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), output::OutputError> {
    if json {
        output::print_json(result, json_format)?;
        return Ok(());
    }
    for (index, entry) in result.hosts.iter().enumerate() {
        let host = host_from_id(entry.host);
        if index > 0 {
            println!();
        }
        if result.status == "dry_run" {
            println!(
                "Would install Inline's {} plugin with:",
                host.display_name()
            );
            for command in &entry.commands {
                println!("  {}", command.join(" "));
            }
        } else {
            println!("Installed the Inline plugin for {}.", host.display_name());
            if let Some(version) = entry.version.as_deref() {
                println!("Version: {}", output::terminal_text(version));
            }
            println!("Includes: Inline skill + OAuth MCP server");
            println!("{}", host.sign_in_hint());
        }
    }
    if result.status == "dry_run" {
        println!("The plugin includes the Inline skill and OAuth MCP server.");
        println!("Without --host, only detected hosts are installed.");
    }
    Ok(())
}

fn host_from_id(id: &str) -> PluginHost {
    PluginHost::ALL
        .into_iter()
        .find(|host| host.id() == id)
        .expect("output hosts come from PluginHost")
}

fn unavailable_error(host: Option<PluginHost>) -> CliError {
    match host {
        Some(PluginHost::Codex) => CliError {
            code: PluginHost::Codex.unavailable_code(),
            message: "Could not find a Codex installation with plugin support".to_string(),
            hint: Some(
                "Update Codex, ensure `codex` is on PATH, then retry. On macOS, the bundled ChatGPT and Codex app runtimes are also detected automatically."
                    .to_string(),
            ),
            examples: vec!["codex --version".to_string(), "inline plugin install --dry-run".to_string()],
        },
        Some(PluginHost::Claude) => CliError {
            code: PluginHost::Claude.unavailable_code(),
            message: "Could not find a Claude Code installation with plugin support".to_string(),
            hint: Some(
                "Update Claude Code, ensure `claude` is on PATH (or set INLINE_CLAUDE_BIN), then retry."
                    .to_string(),
            ),
            examples: vec!["claude --version".to_string(), "inline plugin install --host claude --dry-run".to_string()],
        },
        None => CliError {
            code: "plugin_host_unavailable",
            message: "Could not find Codex or Claude Code with plugin support".to_string(),
            hint: Some(
                "Install or update Codex or Claude Code, ensure `codex` or `claude` is on PATH, then retry."
                    .to_string(),
            ),
            examples: vec!["inline plugin install --dry-run".to_string()],
        },
    }
}

async fn find_host_with_plugins(host: PluginHost) -> Option<PathBuf> {
    for candidate in host.candidates() {
        if host_supports_plugins(host, &candidate).await {
            return Some(candidate);
        }
    }
    None
}

async fn host_supports_plugins(host: PluginHost, candidate: &Path) -> bool {
    run_host(
        candidate,
        &["plugin", host.install_verb(), "--help"],
        Duration::from_secs(5),
    )
    .await
    .is_ok_and(|output| output.status.success())
}

async fn run_host_install(
    host: PluginHost,
    candidate: &Path,
    args: &[&str],
    operation: &str,
) -> Result<Value, Box<dyn std::error::Error>> {
    let output = run_host(candidate, args, Duration::from_secs(60)).await?;
    if !output.status.success() {
        let diagnostic = concise_process_error(&output.stderr, &output.stdout);
        return Err(CliError {
            code: host.failed_code(),
            message: format!("Could not {operation} in {}: {diagnostic}", host.display_name()),
            hint: Some(format!(
                "Run `{} plugin --help` to verify plugin support, then retry. Existing marketplace and plugin installs are safe to repeat.",
                host.id()
            )),
            examples: vec!["inline plugin install --dry-run".to_string()],
        }
        .into());
    }
    // Plugin-capable host builds do not all print JSON. Exit status is
    // authoritative; retain optional metadata only when output is JSON, without
    // parsing display text or exposing installed paths in Inline's result.
    Ok(serde_json::from_slice(&output.stdout).unwrap_or(Value::Null))
}

async fn run_host(
    candidate: &Path,
    args: &[&str],
    timeout: Duration,
) -> Result<std::process::Output, std::io::Error> {
    let mut command = Command::new(candidate);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .env("NO_COLOR", "1");
    scrub_inline_environment(&mut command);
    let mut child = command.spawn()?;
    let stdout = child.stdout.take().expect("stdout is piped");
    let stderr = child.stderr.take().expect("stderr is piped");
    let result = tokio::time::timeout(timeout, async {
        tokio::try_join!(
            child.wait(),
            read_host_output(stdout),
            read_host_output(stderr)
        )
    })
    .await
    .map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            format!(
                "{} timed out after {} seconds",
                candidate.display(),
                timeout.as_secs()
            ),
        )
    })?;
    let (status, stdout, stderr) = result?;
    Ok(std::process::Output {
        status,
        stdout,
        stderr,
    })
}

async fn read_host_output(reader: impl AsyncRead + Unpin) -> Result<Vec<u8>, std::io::Error> {
    let mut bytes = Vec::new();
    reader
        .take((MAX_HOST_OUTPUT + 1) as u64)
        .read_to_end(&mut bytes)
        .await?;
    if bytes.len() > MAX_HOST_OUTPUT {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Plugin host command output exceeded 128 KiB",
        ));
    }
    Ok(bytes)
}

fn scrub_inline_environment(command: &mut Command) {
    let names = env::vars_os()
        .map(|(name, _)| name)
        .collect::<Vec<OsString>>();
    for name in names {
        if name.to_string_lossy().starts_with("INLINE_") {
            command.env_remove(name);
        }
    }
}

fn concise_process_error(stderr: &[u8], stdout: &[u8]) -> String {
    let text = if stderr.is_empty() { stdout } else { stderr };
    let text = String::from_utf8_lossy(text);
    let line: String = text
        .lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .map(str::trim)
        .unwrap_or("The plugin host exited without an error message")
        .chars()
        .take(500)
        .collect();
    output::terminal_text(&line).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_plan_uses_fixed_argv_and_includes_mcp() {
        let codex = PluginHost::Codex.install_commands();
        assert_eq!(
            codex[0],
            ["codex", "plugin", "marketplace", "add", MARKETPLACE_SOURCE]
        );
        assert_eq!(codex[1], ["codex", "plugin", "add", "inline@inline"]);

        let claude = PluginHost::Claude.install_commands();
        assert_eq!(
            claude[0],
            ["claude", "plugin", "marketplace", "add", MARKETPLACE_SOURCE]
        );
        assert_eq!(
            claude[1],
            ["claude", "plugin", "install", "inline@inline-chat"]
        );
    }

    #[test]
    fn dry_run_output_lists_each_host_with_mcp() {
        let output = PluginInstallOutput {
            status: "dry_run",
            hosts: PluginHost::ALL
                .into_iter()
                .map(HostInstallOutput::planned)
                .collect(),
        };
        let value = serde_json::to_value(&output).unwrap();
        assert_eq!(value["hosts"][0]["host"], "codex");
        assert_eq!(value["hosts"][1]["host"], "claude");
        assert_eq!(value["hosts"][1]["pluginId"], "inline@inline-chat");
        assert_eq!(value["hosts"][1]["includes"][1], "oauth_mcp");
        assert!(value["hosts"][1].get("version").is_none());
    }

    #[test]
    fn process_errors_are_bounded_and_prefer_stderr() {
        let stderr = format!("first\n{}", "x".repeat(700));
        let diagnostic = concise_process_error(stderr.as_bytes(), b"ignored");

        assert_eq!(diagnostic.len(), 500);
        assert!(diagnostic.chars().all(|character| character == 'x'));
    }

    #[tokio::test]
    async fn subprocess_output_is_bounded_while_reading() {
        let oversized = vec![b'x'; MAX_HOST_OUTPUT + 1];
        let error = read_host_output(oversized.as_slice()).await.unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
        assert_eq!(read_host_output(b"{}".as_slice()).await.unwrap(), b"{}");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn subprocess_timeout_and_both_output_streams_are_handled() {
        let output = run_host(
            Path::new("/bin/sh"),
            &["-c", "printf '{\"ok\":true}'; printf 'diagnostic' >&2"],
            Duration::from_secs(2),
        )
        .await
        .unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, br#"{"ok":true}"#);
        assert_eq!(output.stderr, b"diagnostic");

        let error = run_host(
            Path::new("/bin/sh"),
            &["-c", "exec sleep 2"],
            Duration::from_millis(20),
        )
        .await
        .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
    }

    #[test]
    fn codex_json_fields_map_to_stable_plugin_output() {
        let marketplace: Value = serde_json::from_str(r#"{"alreadyAdded":true}"#).unwrap();
        let installed: Value = serde_json::from_str(
            r#"{"version":"0.1.0","authPolicy":"ON_INSTALL","installedPath":"/private/path"}"#,
        )
        .unwrap();

        assert_eq!(marketplace["alreadyAdded"].as_bool(), Some(true));
        assert_eq!(installed["version"].as_str(), Some("0.1.0"));
        assert_eq!(installed["authPolicy"].as_str(), Some("ON_INSTALL"));
    }
}
