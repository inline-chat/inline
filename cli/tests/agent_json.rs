use serde_json::Value;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

fn inline_bin() -> &'static str {
    env!("CARGO_BIN_EXE_inline")
}

fn run_inline(args: &[&str]) -> Output {
    Command::new(inline_bin())
        .args(args)
        .output()
        .expect("run inline binary")
}

fn isolated_paths(label: &str) -> (PathBuf, PathBuf, PathBuf) {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let root =
        std::env::temp_dir().join(format!("inline-cli-{label}-{}-{nanos}", std::process::id()));
    let secrets = root.join("secrets.json");
    let state = root.join("state.json");
    (root, secrets, state)
}

fn run_inline_isolated(
    args: &[&str],
    root: &PathBuf,
    secrets: &PathBuf,
    state: &PathBuf,
) -> Output {
    Command::new(inline_bin())
        .args(args)
        .env("INLINE_DATA_DIR", root)
        .env("INLINE_SECRETS_PATH", secrets)
        .env("INLINE_STATE_PATH", state)
        .env("INLINE_API_BASE_URL", "http://127.0.0.1:9/v1")
        .env("INLINE_REALTIME_URL", "ws://127.0.0.1:9/realtime")
        .output()
        .expect("run isolated inline binary")
}

fn stderr_json(output: &Output) -> Value {
    let stderr = String::from_utf8(output.stderr.clone()).expect("stderr is utf8");
    serde_json::from_str(stderr.trim()).expect("stderr is json")
}

fn assert_json_error_before_auth(label: &str, args: &[&str], code: &str, message: &str) {
    let (root, secrets, state) = isolated_paths(label);
    let output = run_inline_isolated(args, &root, &secrets, &state);

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());

    let payload = stderr_json(&output);
    assert_eq!(payload["error"]["code"], code);
    assert!(
        payload["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .contains(message)
    );

    assert!(!root.exists());
    assert!(!secrets.exists());
    assert!(!state.exists());
}

#[test]
fn parse_errors_emit_structured_json_on_stderr() {
    let output = run_inline(&["--json", "--compact", "definitely-not-a-command"]);

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());

    let payload = stderr_json(&output);
    assert_eq!(payload["error"]["code"], "invalid_args");
    assert!(
        payload["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .contains("unrecognized subcommand")
    );
}

#[test]
fn json_login_emits_interactive_required_without_creating_auth_files() {
    let (root, secrets, state) = isolated_paths("json-login");
    let output = run_inline_isolated(
        &[
            "--json",
            "--compact",
            "auth",
            "login",
            "--email",
            "agent@example.com",
        ],
        &root,
        &secrets,
        &state,
    );

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());

    let payload = stderr_json(&output);
    assert_eq!(payload["error"]["code"], "interactive_required");
    assert!(
        payload["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .contains("auth login does not support JSON/non-interactive verification yet")
    );

    assert!(!root.exists());
    assert!(!secrets.exists());
    assert!(!state.exists());
}

#[test]
fn human_runtime_errors_emit_short_report_on_stderr() {
    let (root, secrets, state) = isolated_paths("human-auth-me");
    let output = run_inline_isolated(&["auth", "me"], &root, &secrets, &state);

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());

    let stderr = String::from_utf8(output.stderr).expect("stderr is utf8");
    assert!(stderr.contains("Error: No token found."));
    assert!(stderr.contains("Code: not_authenticated"));
    assert!(stderr.contains("Hint: Agents and CI can pass a token"));
    assert!(stderr.contains("Examples:\n  inline auth login"));
    assert!(!stderr.contains("\"error\""));

    assert!(!root.exists());
    assert!(!secrets.exists());
    assert!(!state.exists());
}

#[test]
fn translate_validation_runs_before_auth_lookup() {
    assert_json_error_before_auth(
        "translate-validation",
        &[
            "--json",
            "--compact",
            "messages",
            "get",
            "--chat-id",
            "1",
            "--message-id",
            "1",
            "--translate",
            "",
        ],
        "missing_translate_language",
        "--translate",
    );
}

#[test]
fn peer_and_query_validation_run_before_auth_lookup() {
    assert_json_error_before_auth(
        "missing-peer",
        &["--json", "--compact", "messages", "list", "--limit", "1"],
        "missing_peer",
        "--chat-id or --user-id",
    );

    assert_json_error_before_auth(
        "missing-query",
        &["--json", "--compact", "search", "--chat-id", "1"],
        "missing_query",
        "--query",
    );
}

#[test]
fn message_content_validation_runs_before_auth_lookup() {
    assert_json_error_before_auth(
        "missing-send-text",
        &["--json", "--compact", "messages", "send", "--chat-id", "1"],
        "invalid_args",
        "--text/--message/--msg",
    );

    assert_json_error_before_auth(
        "missing-edit-text",
        &[
            "--json",
            "--compact",
            "messages",
            "edit",
            "--chat-id",
            "1",
            "--message-id",
            "1",
        ],
        "missing_text",
        "--text/--message/--msg",
    );

    let (root, secrets, state) = isolated_paths("missing-attachment-path");
    let attachment = root.join("missing.txt").to_string_lossy().into_owned();
    let output = run_inline_isolated(
        &[
            "--json",
            "--compact",
            "messages",
            "send",
            "--chat-id",
            "1",
            "--attach",
            &attachment,
        ],
        &root,
        &secrets,
        &state,
    );

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());

    let payload = stderr_json(&output);
    assert_eq!(payload["error"]["code"], "invalid_args");
    assert!(
        payload["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .contains("Attachment not found")
    );

    assert!(!root.exists());
    assert!(!secrets.exists());
    assert!(!state.exists());
}

#[test]
fn message_filesystem_validation_runs_before_auth_lookup() {
    assert_json_error_before_auth(
        "export-output-directory",
        &[
            "--json",
            "--compact",
            "messages",
            "export",
            "--chat-id",
            "1",
            "--output",
            ".",
        ],
        "invalid_args",
        "--output",
    );

    assert_json_error_before_auth(
        "download-output-directory",
        &[
            "--json",
            "--compact",
            "messages",
            "download",
            "--chat-id",
            "1",
            "--message-id",
            "2",
            "--output",
            ".",
        ],
        "invalid_args",
        "--output",
    );

    let (root, secrets, state) = isolated_paths("download-dir-file");
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml");
    let manifest = manifest.to_string_lossy().into_owned();
    let output = run_inline_isolated(
        &[
            "--json",
            "--compact",
            "messages",
            "download",
            "--chat-id",
            "1",
            "--message-id",
            "2",
            "--dir",
            &manifest,
        ],
        &root,
        &secrets,
        &state,
    );

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());

    let payload = stderr_json(&output);
    assert_eq!(payload["error"]["code"], "invalid_args");
    assert!(
        payload["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .contains("--dir")
    );

    assert!(!root.exists());
    assert!(!secrets.exists());
    assert!(!state.exists());
}

#[test]
fn reaction_emoji_validation_runs_before_auth_lookup() {
    assert_json_error_before_auth(
        "empty-reaction",
        &[
            "--json",
            "--compact",
            "messages",
            "add-reaction",
            "--chat-id",
            "1",
            "--message-id",
            "1",
            "--emoji",
            "",
        ],
        "invalid_args",
        "Emoji cannot be empty",
    );
}

#[test]
fn chat_and_typing_peer_validation_runs_before_auth_lookup() {
    assert_json_error_before_auth(
        "chat-get-missing-peer",
        &["--json", "--compact", "chats", "get"],
        "missing_peer",
        "--chat-id or --user-id",
    );

    assert_json_error_before_auth(
        "typing-missing-peer",
        &["--json", "--compact", "typing", "start"],
        "missing_peer",
        "--chat-id or --user-id",
    );
}

#[test]
fn table_only_list_flags_validate_before_auth_lookup() {
    assert_json_error_before_auth(
        "users-list-id-json",
        &["--json", "--compact", "users", "list", "--ids"],
        "invalid_args",
        "--ids/--id",
    );

    assert_json_error_before_auth(
        "chats-list-ids-json",
        &["--json", "--compact", "chats", "list", "--ids"],
        "invalid_args",
        "--ids/--id",
    );

    assert_json_error_before_auth(
        "bots-list-id-json",
        &["--json", "--compact", "bots", "list", "--ids"],
        "invalid_args",
        "--ids/--id",
    );
}

#[test]
fn space_invite_and_member_role_validation_runs_before_auth_lookup() {
    assert_json_error_before_auth(
        "space-invite-missing-target",
        &["--json", "--compact", "spaces", "invite", "--space-id", "1"],
        "invalid_args",
        "--user-id, --email, or --phone",
    );

    assert_json_error_before_auth(
        "space-invite-conflicting-target",
        &[
            "--json",
            "--compact",
            "spaces",
            "invite",
            "--space-id",
            "1",
            "--user-id",
            "2",
            "--email",
            "a@example.com",
        ],
        "invalid_args",
        "--user-id",
    );

    assert_json_error_before_auth(
        "space-member-missing-role",
        &[
            "--json",
            "--compact",
            "spaces",
            "update-member-access",
            "--space-id",
            "1",
            "--user-id",
            "2",
        ],
        "invalid_args",
        "--admin or --member",
    );
}

#[test]
fn destructive_json_confirmation_validates_before_auth_lookup() {
    assert_json_error_before_auth(
        "chat-delete-confirmation",
        &["--json", "--compact", "chats", "delete", "--chat-id", "1"],
        "confirmation_required",
        "Confirmation required",
    );

    assert_json_error_before_auth(
        "message-delete-confirmation",
        &[
            "--json",
            "--compact",
            "messages",
            "delete",
            "--chat-id",
            "1",
            "--message-id",
            "2",
        ],
        "confirmation_required",
        "Confirmation required",
    );

    assert_json_error_before_auth(
        "space-delete-member-confirmation",
        &[
            "--json",
            "--compact",
            "spaces",
            "delete-member",
            "--space-id",
            "1",
            "--user-id",
            "2",
        ],
        "confirmation_required",
        "Confirmation required",
    );
}
