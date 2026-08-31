#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::process::Command;

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
