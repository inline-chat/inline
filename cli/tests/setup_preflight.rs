#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::process::Command;

fn write_executable(path: &std::path::Path, contents: &str) {
    std::fs::write(path, contents).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
}

#[test]
fn preflight_errors_use_the_setup_envelope_without_running_a_provider() {
    let directory = tempfile::tempdir().unwrap();
    for name in ["codex", "claude"] {
        let path = directory.path().join(name);
        std::fs::write(
            &path,
            "#!/bin/sh\nprintf invoked > \"$PREFLIGHT_EXECUTION_MARKER\"\nexit 93\n",
        )
        .unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    for (args, expected_code, expected_target) in [
        (
            vec!["--target", "codex", "--allow-user", "0"],
            "invalid_args",
            Some("codex"),
        ),
        (vec!["--allow-user", "0"], "invalid_args", None),
        (vec![], "target_selection_required", None),
        (
            vec!["--target", "codex", "--no-install", "--no-restart"],
            "not_authenticated",
            Some("codex"),
        ),
    ] {
        for app_protocol in [false, true] {
            let mut command = Command::new(env!("CARGO_BIN_EXE_inline"));
            command.args(["agents", "setup", "--json", "--non-interactive"]);
            command.args(&args);
            if app_protocol {
                command.args(["--app-protocol", "1"]);
            }
            let output = command
                .env("PATH", directory.path())
                .env_remove("INLINE_TOKEN")
                .env("INLINE_CLI_TELEMETRY", "off")
                .env("INLINE_DATA_DIR", directory.path().join("data"))
                .env("INLINE_SECRETS_PATH", directory.path().join("missing-auth"))
                .env("INLINE_STATE_PATH", directory.path().join("missing-state"))
                .env("INLINE_API_BASE_URL", "http://127.0.0.1:9/v1")
                .env("INLINE_REALTIME_URL", "ws://127.0.0.1:9/realtime")
                .env(
                    "PREFLIGHT_EXECUTION_MARKER",
                    directory.path().join("provider-invoked"),
                )
                .output()
                .unwrap();
            assert_eq!(output.status.code(), Some(1));
            assert!(output.stdout.is_empty());
            let payload: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
            if app_protocol {
                assert_eq!(String::from_utf8_lossy(&output.stderr).lines().count(), 1);
            }
            assert_eq!(payload["protocolVersion"], 1);
            assert_eq!(payload["action"], "agents.setup");
            assert_eq!(payload["ok"], false);
            assert_eq!(payload["status"], "failed");
            assert_eq!(payload["failedPhase"], "preflight");
            assert_eq!(payload["changes"], serde_json::json!([]));
            assert_eq!(payload["target"], serde_json::json!(expected_target));
            assert_eq!(payload["error"]["code"], expected_code);
            assert!(
                payload["documentationUrl"]
                    .as_str()
                    .unwrap()
                    .ends_with("/agents")
            );
            let retry = payload["retry"].as_str().unwrap();
            assert!(retry.starts_with("inline agents setup"));
            if args.contains(&"--no-install") {
                assert!(retry.contains("--no-install") && retry.contains("--no-restart"));
            }
            if expected_target.is_none() {
                assert!(!retry.contains("--target"));
            }
        }
    }
    assert!(!directory.path().join("provider-invoked").exists());
    assert!(!directory.path().join("missing-auth").exists());
    assert!(!directory.path().join("missing-state").exists());
}

#[test]
fn claude_dry_run_checks_node_auth_and_adapter_install_prerequisites() {
    let directory = tempfile::tempdir().unwrap();
    write_executable(
        &directory.path().join("claude"),
        "#!/bin/sh\nprintf '{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}\\n'\n",
    );
    write_executable(
        &directory.path().join("node"),
        "#!/bin/sh\nprintf 'v22.12.0\\n'\n",
    );
    write_executable(&directory.path().join("npm"), "#!/bin/sh\nexit 97\n");

    let output = Command::new(env!("CARGO_BIN_EXE_inline"))
        .args([
            "agents",
            "setup",
            "--target",
            "claude",
            "--dry-run",
            "--non-interactive",
            "--json",
        ])
        .env("PATH", directory.path())
        .env("HOME", directory.path())
        .env_remove("INLINE_TOKEN")
        .env("INLINE_CLI_TELEMETRY", "off")
        .output()
        .unwrap();

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.stderr.is_empty());
    let payload: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(payload["target"], "claude");
    assert_eq!(payload["status"], "planned");

    write_executable(
        &directory.path().join("node"),
        "#!/bin/sh\nprintf 'v20.18.0\\n'\n",
    );
    let output = Command::new(env!("CARGO_BIN_EXE_inline"))
        .args([
            "agents",
            "setup",
            "--target",
            "claude",
            "--dry-run",
            "--non-interactive",
            "--json",
        ])
        .env("PATH", directory.path())
        .env("HOME", directory.path())
        .env_remove("INLINE_TOKEN")
        .env("INLINE_CLI_TELEMETRY", "off")
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    let payload: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(payload["error"]["code"], "provider_integration_failed");
    assert!(
        payload["error"]["message"]
            .as_str()
            .unwrap()
            .contains("Node.js 22 or newer")
    );
}

#[test]
fn verbose_setup_failure_returns_a_private_diagnostic_report() {
    let directory = tempfile::tempdir().unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_inline"))
        .args([
            "--verbose",
            "--json",
            "--compact",
            "agents",
            "setup",
            "--target",
            "codex",
            "--allow-user",
            "0",
            "--non-interactive",
        ])
        .env("TMPDIR", directory.path())
        .env("INLINE_CLI_TELEMETRY", "off")
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    let terminal_line = output
        .stderr
        .split(|byte| *byte == b'\n')
        .rev()
        .find(|line| !line.is_empty() && serde_json::from_slice::<serde_json::Value>(line).is_ok());
    let payload: serde_json::Value = serde_json::from_slice(terminal_line.unwrap()).unwrap();
    let report_path = payload["diagnosticReportPath"].as_str().unwrap();
    assert!(std::path::Path::new(report_path).starts_with(directory.path()));
    let report = std::fs::read_to_string(report_path).unwrap();
    assert!(report.contains("diagnostics enabled version="));
    assert!(report.contains("agents.setup failed"));
    assert_eq!(
        std::fs::metadata(report_path).unwrap().permissions().mode() & 0o777,
        0o600
    );
}
