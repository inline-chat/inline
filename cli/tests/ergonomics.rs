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
