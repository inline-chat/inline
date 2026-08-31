use std::process::{Command, Output, Stdio};

fn run(args: &[&str]) -> Output {
    let directory = tempfile::tempdir().unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_inline"))
        .args(args)
        .env_remove("INLINE_TOKEN")
        .env("INLINE_CLI_TELEMETRY", "off")
        .env("INLINE_DATA_DIR", directory.path().join("data"))
        .env(
            "INLINE_SECRETS_PATH",
            directory.path().join("missing-credentials"),
        )
        .env("INLINE_STATE_PATH", directory.path().join("missing-state"))
        .env("INLINE_API_BASE_URL", "http://127.0.0.1:9/v1")
        .env("INLINE_REALTIME_URL", "ws://127.0.0.1:9/realtime")
        .output()
        .unwrap();
    assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
    output
}

#[test]
fn redirected_no_arguments_and_flags_only_keep_existing_error_contracts() {
    let output = run(&[]);
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    let text = String::from_utf8(output.stderr).unwrap();
    assert!(text.contains("Usage:"));
    assert!(!text.contains("Work chat and agents"));

    let output = run(&["--json", "--compact"]);
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["error"]["code"], "invalid_args");
}

#[test]
fn explicit_help_keeps_the_complete_command_reference() {
    let output = run(&["--help"]);
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let text = String::from_utf8(output.stdout).unwrap();
    assert!(text.contains("Commands:"));
    assert!(text.contains("bridge"));
    assert!(text.contains("notifications"));
    assert!(text.contains("--json"));
    assert!(!text.contains("Work chat and agents"));
}

#[test]
fn capabilities_describe_public_commands_without_account_or_network_access() {
    let output = run(&["capabilities", "message", "send", "--compact"]);
    assert!(output.status.success(), "{:?}", output.stderr);
    assert!(output.stderr.is_empty());
    let schema: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(schema["schemaVersion"], 1);
    assert_eq!(
        schema["path"],
        serde_json::json!(["inline", "messages", "send"])
    );
    assert!(
        schema["arguments"]
            .as_array()
            .unwrap()
            .iter()
            .any(|arg| arg["long"] == "text-file")
    );

    let output = run(&["schema", "commands", "auth", "login", "--compact"]);
    assert!(output.status.success());
    let schema = String::from_utf8(output.stdout).unwrap();
    assert!(!schema.contains("mac-app-bootstrap"));
    assert!(!schema.contains("expected-user-id"));

    let output = run(&["capabilities", "missing", "--json", "--compact"]);
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["error"]["code"], "unknown_command_path");
}

#[test]
fn tls_connection_failure_keeps_json_errors_without_overflowing_the_stack() {
    use std::net::TcpListener;
    use std::time::{Duration, Instant};
    let directory = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    listener.set_nonblocking(true).unwrap();
    let server = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if let Ok((stream, _)) = listener.accept() {
                std::thread::sleep(Duration::from_millis(50));
                drop(stream);
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    });
    let output = Command::new(env!("CARGO_BIN_EXE_inline"))
        .args(["me", "--json", "--compact"])
        .env("INLINE_TOKEN", "local-tls-fixture")
        .env("INLINE_CLI_TELEMETRY", "off")
        .env("INLINE_DATA_DIR", directory.path())
        .env(
            "INLINE_SECRETS_PATH",
            directory.path().join("unused-secrets"),
        )
        .env("INLINE_STATE_PATH", directory.path().join("unused-state"))
        .env("INLINE_API_BASE_URL", "http://127.0.0.1:9/v1")
        .env("INLINE_REALTIME_URL", format!("wss://{address}/realtime"))
        .output()
        .unwrap();
    server.join().unwrap();
    assert_eq!(output.status.code(), Some(1), "{:?}", output.stderr);
    assert!(output.stdout.is_empty());
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert!(error["error"]["code"].as_str().is_some());
    assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
}

#[test]
fn plugin_dry_run_is_local_and_shows_fixed_install_commands() {
    let output = run(&["plugins", "install", "--dry-run", "--json", "--compact"]);
    assert!(output.status.success(), "{:?}", output.stderr);
    assert!(output.stderr.is_empty());
    let plan: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(plan["status"], "dry_run");
    assert_eq!(plan["pluginId"], "inline@inline");
    assert_eq!(plan["includes"], serde_json::json!(["skill", "oauth_mcp"]));
    assert_eq!(
        plan["commands"],
        serde_json::json!([
            [
                "codex",
                "plugin",
                "marketplace",
                "add",
                "inline-chat/inline"
            ],
            ["codex", "plugin", "add", "inline@inline"]
        ])
    );
}

#[cfg(unix)]
#[test]
fn plugin_install_uses_supported_argv_without_forwarding_inline_credentials() {
    use std::os::unix::fs::PermissionsExt;
    let directory = tempfile::tempdir().unwrap();
    let codex = directory.path().join("codex");
    std::fs::write(&codex, r#"#!/bin/sh
test -z "${INLINE_TOKEN+x}" || exit 91
test -z "${INLINE_CODEX_BIN+x}" || exit 92
case "$*" in
  'plugin add --help') printf 'Plugin help';;
  'plugin marketplace add inline-chat/inline --json') printf '{"alreadyAdded":true}';;
  'plugin add inline@inline --json') printf '{"version":"0.1.0","authPolicy":"ON_INSTALL","installedPath":"/private/fixture"}';;
  *) exit 93;;
esac
"#).unwrap();
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o700)).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_inline"))
        .args(["plugin", "install", "--json", "--compact"])
        .env("INLINE_CODEX_BIN", &codex)
        .env("INLINE_TOKEN", "fixture-token-never-forwarded")
        .env("INLINE_CLI_TELEMETRY", "off")
        .env("INLINE_API_BASE_URL", "invalid and unused")
        .env(
            "INLINE_SECRETS_PATH",
            directory.path().join("unused-secrets"),
        )
        .output()
        .unwrap();
    assert!(output.status.success(), "{:?}", output.stderr);
    assert!(output.stderr.is_empty());
    let installed: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(installed["status"], "installed");
    assert_eq!(installed["version"], "0.1.0");
    assert_eq!(installed["marketplaceAlreadyAdded"], true);
    assert!(installed.get("installedPath").is_none());
    assert!(!directory.path().join("unused-secrets").exists());
}

#[test]
fn generates_all_completions_without_configuration_or_network() {
    for shell in ["bash", "zsh", "fish", "powershell", "elvish"] {
        let output = Command::new(env!("CARGO_BIN_EXE_inline"))
            .args(["completion", shell])
            // Invalid configuration must not affect this local command.
            .env("INLINE_API_BASE_URL", "not a URL")
            .env("INLINE_CLI_SENTRY_DSN", "not a DSN")
            .output()
            .unwrap();
        assert!(output.status.success(), "{shell}: {:?}", output.stderr);
        assert!(output.stderr.is_empty());
        let text = String::from_utf8(output.stdout).unwrap();
        assert!(text.contains("inline"));
        assert!(text.contains("text-file"));
        assert!(text.contains("unread"));
        assert!(!text.contains("mac-app-bootstrap"), "{shell}");
        assert!(!text.contains("expected-user-id"), "{shell}");
        assert!(!text.contains("provider-host"), "{shell}");
    }
}

#[test]
fn completion_exits_quietly_when_a_pipeline_consumer_closes() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_inline"))
        .args(["completion", "bash"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    drop(child.stdout.take());
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success(), "{:?}", output.stderr);
    assert!(output.stderr.is_empty());
}

#[test]
fn completion_rejects_json_before_emitting_a_script() {
    for args in [
        ["--json", "completion", "bash"],
        ["completion", "bash", "--json"],
    ] {
        let output = run(&args);
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
        assert_eq!(error["error"]["code"], "invalid_args");
    }
}

#[test]
fn aliases_and_new_flags_appear_in_command_help() {
    for args in [
        vec!["chat", "ls", "--help"],
        vec!["message", "view", "--help"],
        vec!["user", "ls", "--help"],
        vec!["space", "ls", "--help"],
        vec!["completions", "--help"],
    ] {
        let output = run(&args);
        assert!(output.status.success(), "{args:?}: {:?}", output.stderr);
    }
    let output = run(&["message", "send", "--help"]);
    let help = String::from_utf8(output.stdout).unwrap();
    assert!(help.contains("--text-file"));
    assert!(help.contains("-c, --chat-id"));
}

#[test]
fn new_invalid_arguments_fail_before_auth_with_existing_json_envelope() {
    for args in [
        vec!["chat", "ls", "--space-id", "0"],
        vec!["chats", "subthread", "--parent-chat-id", "0"],
        vec!["chats", "move", "--chat-id", "1", "--space-id", "0"],
        vec!["chats", "follow", "-c", "0"],
        vec!["messages", "pin", "-c", "1", "--message-id", "0"],
        vec!["notifications", "set-chat", "-c", "0", "--mode", "inherit"],
        vec!["auth", "revoke-session", "--session-id", "0", "--yes"],
        vec!["chat", "ls", "--home", "--space-id", "7"],
        vec!["chat", "ls", "-f", "launch", "--id", "-L", "1"],
        vec!["chat", "ls", "-f", "launch", "--id", "--offset", "1"],
        vec!["message", "ls", "-c", "1", "--ids", "--translate", "en"],
        vec!["message", "ls", "-c", "1", "--ids"],
        vec!["search", "hello", "-c", "1", "--ids"],
        vec!["messages", "search", "hello", "-c", "1", "--ids"],
        vec!["search", "hello", "-c", "1", "--offset-id", "0"],
        vec!["messages", "search", "hello", "-c", "1", "--offset-id", "0"],
        vec!["search", "hello", "-c", "1", "-q", "world"],
        vec![
            "message",
            "send",
            "-c",
            "1",
            "--text-file",
            "-",
            "-m",
            "hello",
        ],
    ] {
        let mut json_args = vec!["--json", "--compact"];
        json_args.extend(args);
        let output = run(&json_args);
        assert!(!output.status.success(), "{json_args:?}");
        assert!(output.stdout.is_empty());
        let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
        assert_eq!(
            error["error"]["code"], "invalid_args",
            "{json_args:?}: {error}"
        );
    }
}

#[test]
fn literal_query_after_double_dash_does_not_enable_json_errors() {
    for args in [
        vec!["search", "-c", "1", "--", "--json"],
        vec!["messages", "search", "-c", "1", "--", "--json"],
    ] {
        let output = run(&args);
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        let error = String::from_utf8(output.stderr).unwrap();
        assert!(error.contains("not_authenticated"), "{error}");
        assert!(serde_json::from_str::<serde_json::Value>(&error).is_err());
    }
}

#[test]
fn empty_text_file_is_rejected_before_auth_for_send_and_edit() {
    let file = tempfile::NamedTempFile::new().unwrap();
    for operation in ["send", "edit"] {
        let mut args = vec![
            "--json",
            "--compact",
            "message",
            operation,
            "-c",
            "1",
            "--text-file",
            file.path().to_str().unwrap(),
        ];
        if operation == "edit" {
            args.extend(["--message-id", "1"]);
        }
        let output = run(&args);
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
        assert_eq!(error["error"]["code"], "invalid_args");
        assert_eq!(error["error"]["message"], "--text-file was empty");
    }
}
