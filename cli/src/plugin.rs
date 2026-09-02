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
const PLUGIN_ID: &str = "inline@inline";
const MAX_CODEX_OUTPUT: usize = 128 * 1024;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PluginInstallOutput {
    status: &'static str,
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

pub(crate) async fn install_for_codex(
    dry_run: bool,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let commands = install_commands();
    if dry_run {
        let result = PluginInstallOutput {
            status: "dry_run",
            plugin_id: PLUGIN_ID,
            marketplace: "inline",
            includes: ["skill", "oauth_mcp"],
            commands,
            marketplace_already_added: None,
            version: None,
            auth_policy: None,
        };
        print_result(&result, json, json_format)?;
        return Ok(());
    }

    let codex = find_codex_with_plugins().await?;
    let marketplace = run_codex_install(
        &codex,
        &["plugin", "marketplace", "add", MARKETPLACE_SOURCE],
        "add the Inline plugin marketplace",
    )
    .await?;
    let installed = run_codex_install(
        &codex,
        &["plugin", "add", PLUGIN_ID],
        "install the Inline plugin",
    )
    .await?;

    let result = PluginInstallOutput {
        status: "installed",
        plugin_id: PLUGIN_ID,
        marketplace: "inline",
        includes: ["skill", "oauth_mcp"],
        commands,
        marketplace_already_added: marketplace.get("alreadyAdded").and_then(Value::as_bool),
        version: installed
            .get("version")
            .and_then(Value::as_str)
            .map(str::to_string),
        auth_policy: installed
            .get("authPolicy")
            .and_then(Value::as_str)
            .map(str::to_string),
    };
    print_result(&result, json, json_format)?;
    Ok(())
}

fn install_commands() -> Vec<Vec<String>> {
    vec![
        vec![
            "codex".to_string(),
            "plugin".to_string(),
            "marketplace".to_string(),
            "add".to_string(),
            MARKETPLACE_SOURCE.to_string(),
        ],
        vec![
            "codex".to_string(),
            "plugin".to_string(),
            "add".to_string(),
            PLUGIN_ID.to_string(),
        ],
    ]
}

fn print_result(
    result: &PluginInstallOutput,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), output::OutputError> {
    if json {
        output::print_json(result, json_format)?;
    } else if result.status == "dry_run" {
        println!("Would install Inline's Codex plugin with:");
        for command in &result.commands {
            println!("  {}", command.join(" "));
        }
        println!("The plugin includes the Inline skill and OAuth MCP server.");
    } else {
        println!("Installed the Inline plugin for Codex.");
        if let Some(version) = result.version.as_deref() {
            println!("Version: {}", output::terminal_text(version));
        }
        println!("Includes: Inline skill + OAuth MCP server");
        println!("Start a new Codex session to load the plugin.");
    }
    Ok(())
}

async fn find_codex_with_plugins() -> Result<PathBuf, CliError> {
    for candidate in codex_candidates() {
        if codex_supports_plugins(&candidate).await {
            return Ok(candidate);
        }
    }
    Err(CliError {
        code: "codex_plugin_unavailable",
        message: "Could not find a Codex installation with plugin support".to_string(),
        hint: Some(
            "Update Codex, ensure `codex` is on PATH, then retry. On macOS, the bundled ChatGPT and Codex app runtimes are also detected automatically."
                .to_string(),
        ),
        examples: vec!["codex --version".to_string(), "inline plugin install --dry-run".to_string()],
    })
}

fn codex_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(path) = env::var_os("INLINE_CODEX_BIN").filter(|value| !value.is_empty()) {
        candidates.push(PathBuf::from(path));
    }
    candidates.push(PathBuf::from("codex"));
    #[cfg(target_os = "macos")]
    {
        candidates.push(PathBuf::from(
            "/Applications/ChatGPT.app/Contents/Resources/codex",
        ));
        candidates.push(PathBuf::from(
            "/Applications/Codex.app/Contents/Resources/codex",
        ));
    }
    candidates.dedup();
    candidates
}

async fn codex_supports_plugins(candidate: &Path) -> bool {
    run_codex(
        candidate,
        &["plugin", "add", "--help"],
        Duration::from_secs(5),
    )
    .await
    .is_ok_and(|output| output.status.success())
}

async fn run_codex_install(
    candidate: &Path,
    args: &[&str],
    operation: &str,
) -> Result<Value, Box<dyn std::error::Error>> {
    let output = run_codex(candidate, args, Duration::from_secs(60)).await?;
    if !output.status.success() {
        let diagnostic = concise_process_error(&output.stderr, &output.stdout);
        return Err(CliError {
            code: "codex_plugin_failed",
            message: format!("Could not {operation}: {diagnostic}"),
            hint: Some(
                "Run `codex plugin --help` to verify plugin support, then retry. Existing marketplace and plugin installs are safe to repeat."
                    .to_string(),
            ),
            examples: vec!["inline plugin install --dry-run".to_string()],
        }
        .into());
    }
    // Plugin-capable Codex builds do not all support --json. Exit status is
    // authoritative; retain optional metadata only when output is JSON, without
    // parsing display text or exposing installed paths in Inline's result.
    Ok(serde_json::from_slice(&output.stdout).unwrap_or(Value::Null))
}

async fn run_codex(
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
            read_codex_output(stdout),
            read_codex_output(stderr)
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

async fn read_codex_output(reader: impl AsyncRead + Unpin) -> Result<Vec<u8>, std::io::Error> {
    let mut bytes = Vec::new();
    reader
        .take((MAX_CODEX_OUTPUT + 1) as u64)
        .read_to_end(&mut bytes)
        .await?;
    if bytes.len() > MAX_CODEX_OUTPUT {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Codex plugin command output exceeded 128 KiB",
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
        .unwrap_or("Codex exited without an error message")
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
        let commands = install_commands();

        assert_eq!(
            commands[0],
            ["codex", "plugin", "marketplace", "add", MARKETPLACE_SOURCE]
        );
        assert_eq!(commands[1], ["codex", "plugin", "add", PLUGIN_ID]);
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
        let oversized = vec![b'x'; MAX_CODEX_OUTPUT + 1];
        let error = read_codex_output(oversized.as_slice()).await.unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
        assert_eq!(read_codex_output(b"{}".as_slice()).await.unwrap(), b"{}");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn subprocess_timeout_and_both_output_streams_are_handled() {
        let output = run_codex(
            Path::new("/bin/sh"),
            &["-c", "printf '{\"ok\":true}'; printf 'diagnostic' >&2"],
            Duration::from_secs(2),
        )
        .await
        .unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, br#"{"ok":true}"#);
        assert_eq!(output.stderr, b"diagnostic");

        let error = run_codex(
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
