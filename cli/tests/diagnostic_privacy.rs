#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::process::Command;

#[test]
fn provider_credentials_are_scrubbed_by_the_final_error_renderer() {
    let directory = tempfile::tempdir().unwrap();
    let provider = directory.path().join("codex");
    std::fs::write(
        &provider,
        r#"#!/bin/sh
case "$*" in
  'plugin add --help') exit 0;;
  'plugin marketplace add inline-chat/inline'*)
    printf '%s\n' "$DIAGNOSTIC_FIXTURE" >&2
    exit 1;;
  *) exit 93;;
esac
"#,
    )
    .unwrap();
    std::fs::set_permissions(&provider, std::fs::Permissions::from_mode(0o700)).unwrap();
    for key in [
        "refreshToken",
        "accessToken",
        "apiKey",
        "providerApiKey",
        "ACCESS_TOKEN",
        "refresh-token",
        "sessionToken",
    ] {
        for json in [false, true] {
            let mut command = Command::new(env!("CARGO_BIN_EXE_inline"));
            command.args(["plugin", "install"]);
            if json {
                command.args(["--json", "--compact"]);
            }
            let output = command
                .env("INLINE_CODEX_BIN", &provider)
                .env("INLINE_CLI_TELEMETRY", "off")
                .env("INLINE_API_BASE_URL", "invalid and unused")
                .env("INLINE_SECRETS_PATH", directory.path().join("unused-auth"))
                .env(
                    "DIAGNOSTIC_FIXTURE",
                    format!(r#"{{"{key}":"OPAQUE_CREDENTIAL_FIXTURE_831"}}"#),
                )
                .output()
                .unwrap();
            assert!(!output.status.success());
            assert!(output.stdout.is_empty());
            let diagnostic = String::from_utf8(output.stderr).unwrap();
            assert!(
                !diagnostic.contains("OPAQUE_CREDENTIAL_FIXTURE_831"),
                "{key}: {diagnostic}"
            );
            assert!(diagnostic.contains("redacted"), "{key}: {diagnostic}");
            if json {
                let payload: serde_json::Value = serde_json::from_str(&diagnostic).unwrap();
                assert_eq!(payload["error"]["code"], "codex_plugin_failed");
            }
        }
    }
    assert!(!directory.path().join("unused-auth").exists());
}

#[test]
fn parser_errors_do_not_echo_credential_values() {
    for json in [false, true] {
        let mut command = Command::new(env!("CARGO_BIN_EXE_inline"));
        command.args(["plugin", "install", "--apiKey=OPAQUE_PARSE_FIXTURE_831"]);
        if json {
            command.args(["--json", "--compact"]);
        }
        let output = command.env("INLINE_CLI_TELEMETRY", "off").output().unwrap();
        assert_eq!(output.status.code(), Some(2));
        assert!(output.stdout.is_empty());
        let error = String::from_utf8(output.stderr).unwrap();
        assert!(!error.contains("OPAQUE_PARSE_FIXTURE_831"));
        assert!(error.contains("redacted"));
        if json {
            let payload: serde_json::Value = serde_json::from_str(&error).unwrap();
            assert_eq!(payload["error"]["code"], "invalid_args");
        }
    }
}
