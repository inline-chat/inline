use super::super::BridgeNotice;
use super::*;

fn fixture() -> (AccountBridgeConfig, ProviderInstallationConfig, BridgePaths) {
    let root = PathBuf::from("/tmp/Inline & Bridge/accounts/42");
    let provider = ProviderInstallationConfig {
        installation_id: "codex".to_string(),
        provider_id: "codex".to_string(),
        bot_user_id: 84,
        bot_username: "mo_codex_bot".to_string(),
        dm_chat_id: Some(12),
        workspace: PathBuf::from("/tmp/A <Project>"),
        greeting_sent: false,
        accept_messages_after: 1,
        initial_cursor_seeded: true,
        display_name: "Mo's Codex".to_string(),
        managed_avatar_digest: None,
        managed_avatar_file_unique_id: None,
        executable: PathBuf::from("/opt/homebrew/bin/codex"),
        provider_runtime: None,
        provider_path: "/opt/homebrew/bin:/usr/bin:/bin".to_string(),
        state_dir: root.join("providers/codex"),
    };
    (
        AccountBridgeConfig {
            version: 4,
            owner_user_id: 42,
            host_installation_id: "host-test".to_string(),
            host_label: "Test Mac".to_string(),
            api_base_url: "http://localhost:8000/v1".to_string(),
            realtime_url: "ws://localhost:8000/realtime".to_string(),
            service_label: service_label(42),
            service_binary: PathBuf::from("/tmp/Inline & Bridge/bin/inline"),
            provider_path: "/opt/homebrew/bin:/usr/bin:/bin".to_string(),
            superseded_service_labels: Vec::new(),
            operator_user_ids: vec![42],
            owner_control_cursor_seeded: true,
            providers: vec![provider.clone()],
        },
        provider,
        BridgePaths {
            root: root.clone(),
            config: root.join("config.json"),
            secrets: root.join("secrets.json"),
            instance_lock: root.join("bridge.lock"),
            control_socket: root.join("control.sock"),
            owner_client_db: root.join("owner-client.sqlite"),
            logs_dir: root.join("logs"),
            stdout_log: root.join("logs/bridge.log"),
            stderr_log: root.join("logs/bridge.error.log"),
            installed_binary: PathBuf::from("/tmp/Inline & Bridge/bin/inline"),
        },
    )
}

#[test]
fn launch_agent_uses_single_absolute_arguments_and_escapes_xml() {
    let (account, _, paths) = fixture();
    let plist = render_launch_agent_plist(&account, &paths).unwrap();
    assert!(plist.contains("/tmp/Inline &amp; Bridge/bin/inline"));
    assert!(plist.contains("/tmp/Inline &amp; Bridge/accounts/42"));
    assert!(plist.contains("<string>bridge</string>"));
    assert!(plist.contains("<string>run</string>"));
    assert!(!plist.contains("sh -c"));
    assert!(!plist.contains("bot_token"));
    assert!(!plist.contains("control_token"));
    assert!(!plist.contains("localhost:8000"));
}

#[test]
fn systemd_unit_uses_absolute_args_restart_bounds_and_no_secrets() {
    let (mut account, _, mut paths) = fixture();
    paths.root = PathBuf::from("/tmp/A Project/%work");
    account.provider_path = "/opt/bin:/home/alice/A $PATH/bin".to_string();
    let unit = render_systemd_user_unit(&account, &paths).unwrap();
    assert!(unit.contains("ExecStart=\"/tmp/Inline & Bridge/bin/inline\" \"bridge\" \"run\""));
    assert!(unit.contains("WorkingDirectory=\"/tmp/A Project/%%work\""));
    assert!(unit.contains("Environment=\"PATH=/opt/bin:/home/alice/A $PATH/bin\""));
    assert!(unit.contains("Restart=on-failure"));
    assert!(unit.contains("RestartPreventExitStatus=78"));
    assert!(unit.contains("StartLimitIntervalSec=0"));
    assert!(unit.contains("RestartSec=10s"));
    assert!(unit.contains("KillMode=control-group"));
    assert!(unit.contains("UMask=0077"));
    assert!(unit.contains("NoNewPrivileges=true"));
    assert!(!unit.contains("bot-secret"));
    assert!(!unit.contains("control-secret"));
    assert!(!unit.contains("localhost:8000"));
}

#[test]
fn account_running_is_provider_neutral() {
    let response = ControlResponse {
        version: CONTROL_VERSION,
        status: "running".to_string(),
        process_id: 42,
        inline_connected: false,
        provider_ready: false,
        detail: Some("all providers are restarting".to_string()),
        providers: vec![
            ProviderRuntimeStatus {
                installation_id: "codex".to_string(),
                state: ProviderRuntimeState::Unavailable,
                inline_connected: Some(false),
                detail: None,
            },
            ProviderRuntimeStatus {
                installation_id: "opencode".to_string(),
                state: ProviderRuntimeState::Restarting,
                inline_connected: Some(false),
                detail: None,
            },
        ],
    };
    assert!(account_is_running(&response));

    let stopping = ControlResponse {
        status: "stopping".to_string(),
        ..response
    };
    assert!(!account_is_running(&stopping));
}

#[test]
fn systemd_exec_and_directive_quoting_apply_distinct_dollar_rules() {
    assert_eq!(systemd_quote("/tmp/$agent/%i"), "\"/tmp/$$agent/%%i\"");
    assert_eq!(
        systemd_directive_quote("PATH=/tmp/$agent/%i"),
        "\"PATH=/tmp/$agent/%%i\""
    );
}

#[test]
fn linux_linger_reporting_is_explicit_and_fails_open_for_discovery() {
    assert_eq!(parse_linux_linger_enabled("yes\n"), Some(true));
    assert_eq!(parse_linux_linger_enabled("false"), Some(false));
    assert_eq!(parse_linux_linger_enabled("unknown"), None);
    assert_eq!(
        linux_service_lifecycle_detail(Some(true)),
        "Linux systemd user service starts after login; linger is enabled, so the user manager may remain active without an active login."
    );
    assert_eq!(
        linux_service_lifecycle_detail(Some(false)),
        "Linux systemd user service starts after login; linger is disabled."
    );
    assert_eq!(
        linux_service_lifecycle_detail(None),
        "Linux systemd user service starts after login; linger status could not be determined."
    );
}

#[test]
fn service_lifecycle_detail_preserves_existing_runtime_detail() {
    let lifecycle = "Linux systemd user service starts after login; linger is disabled.";
    assert_eq!(
        merge_service_lifecycle_detail(
            Some("Claude is restarting".to_string()),
            Some(lifecycle.to_string())
        ),
        Some(format!("Claude is restarting {lifecycle}"))
    );
    assert_eq!(
        merge_service_lifecycle_detail(None, Some(lifecycle.to_string())),
        Some(lifecycle.to_string())
    );
    assert_eq!(
        merge_service_lifecycle_detail(Some("ready".to_string()), None),
        Some("ready".to_string())
    );
}

#[cfg(not(target_os = "linux"))]
#[test]
fn non_linux_status_does_not_add_a_service_scope_detail() {
    assert_eq!(service_lifecycle_detail(), None);
    assert_eq!(with_service_lifecycle_detail(None), None);
}

#[test]
fn service_rendering_rejects_provider_path_directive_injection() {
    let (mut account, _, paths) = fixture();
    account.provider_path = "/usr/bin\nExecStart=/tmp/other".to_string();
    assert!(render_systemd_user_unit(&account, &paths).is_err());
}

#[test]
fn service_installation_paths_must_match_and_be_absolute() {
    let (mut account, _, mut paths) = fixture();
    validate_service_paths(&paths, &account).unwrap();

    account.service_binary = PathBuf::from("/tmp/a-different-inline");
    assert!(validate_service_paths(&paths, &account).is_err());

    account.service_binary = paths.installed_binary.clone();
    paths.config = PathBuf::from("relative/config.json");
    assert!(validate_service_paths(&paths, &account).is_err());
}

#[test]
fn service_definition_removal_is_idempotent_and_file_scoped() {
    let root = tempfile::tempdir().unwrap();
    let definition = root.path().join("bridge.service");
    fs::write(&definition, b"service definition").unwrap();

    remove_service_definition(&definition).unwrap();
    assert!(!definition.exists());
    assert!(root.path().is_dir());
    remove_service_definition(&definition).unwrap();
}

#[cfg(unix)]
#[test]
fn service_definition_removal_refuses_symlinks() {
    use std::os::unix::fs::symlink;

    let root = tempfile::tempdir().unwrap();
    let target = root.path().join("unrelated.txt");
    let definition = root.path().join("bridge.service");
    fs::write(&target, b"keep me").unwrap();
    symlink(&target, &definition).unwrap();

    assert!(remove_service_definition(&definition).is_err());
    assert_eq!(fs::read(&target).unwrap(), b"keep me");
}

#[test]
fn log_tail_reader_bounds_input_and_drops_partial_first_line() {
    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let path = PathBuf::from("/tmp").join(format!("inline-log-tail-{unique}.log"));
    let mut content = vec![b'x'; MAX_LOG_READ_BYTES as usize + 100];
    content.push(b'\n');
    content.extend_from_slice(b"last line\n");
    fs::write(&path, content).unwrap();
    let tail = read_log_tail(&path).unwrap();
    assert!(tail.len() <= MAX_LOG_READ_BYTES as usize);
    assert!(tail.ends_with("last line\n"));
    assert!(!tail.starts_with('x'));
}

#[test]
fn oversized_launchd_log_is_capped_before_runtime_start() {
    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let path = PathBuf::from("/tmp").join(format!("inline-log-cap-{unique}.log"));
    let file = fs::File::create(&path).unwrap();
    file.set_len(MAX_LOG_FILE_BYTES + 1).unwrap();
    cap_log_file(&path).unwrap();
    assert_eq!(path.metadata().unwrap().len(), 0);
}

#[test]
fn stable_binary_refresh_atomically_replaces_the_service_copy() {
    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = PathBuf::from("/tmp").join(format!("inline-update-handoff-{unique}"));
    ensure_private_dir(&root).unwrap();
    let source = root.join("updated-inline");
    let destination = root.join("bin").join("inline");
    fs::write(&source, b"new bridge binary").unwrap();
    set_file_mode(&source, 0o755).unwrap();
    install_stable_binary_from(&source, &destination).unwrap();
    assert_eq!(fs::read(&destination).unwrap(), b"new bridge binary");
    assert!(super::super::is_executable_file(&destination));
    assert!(!destination.with_extension("next").exists());
}

#[test]
fn service_label_is_stable_and_separates_debug() {
    let label = service_label(1_600);
    assert!(label.starts_with("chat.inline.agent-bridge"));
    assert!(label.ends_with(".1600"));
}

#[test]
fn token_comparison_requires_exact_bytes() {
    assert!(constant_time_eq(b"same", b"same"));
    assert!(!constant_time_eq(b"same", b"diff"));
    assert!(!constant_time_eq(b"short", b"longer"));
}

#[test]
fn control_request_debug_redacts_the_capability() {
    let request = ControlRequest {
        version: CONTROL_VERSION,
        token: "control-secret".to_string(),
        command: ControlCommand::Status,
    };
    let debug = format!("{request:?}");
    assert!(debug.contains("<redacted>"));
    assert!(!debug.contains("control-secret"));
}

#[test]
fn status_resolves_readiness_for_the_requested_provider() {
    let response = ControlResponse {
        version: CONTROL_VERSION,
        status: "running".to_string(),
        process_id: 42,
        inline_connected: true,
        provider_ready: true,
        detail: None,
        providers: vec![
            ProviderRuntimeStatus {
                installation_id: "codex".to_string(),
                state: ProviderRuntimeState::Restarting,
                inline_connected: Some(false),
                detail: Some(BridgeNotice::InlineReconnecting.message().to_string()),
            },
            ProviderRuntimeStatus {
                installation_id: "opencode".to_string(),
                state: ProviderRuntimeState::Ready,
                inline_connected: Some(true),
                detail: None,
            },
        ],
    };
    assert_eq!(
        provider_state(&response, "codex"),
        ProviderRuntimeState::Restarting
    );
    assert_eq!(
        provider_state(&response, "opencode"),
        ProviderRuntimeState::Ready
    );
    assert_eq!(
        provider_state(&response, "missing"),
        ProviderRuntimeState::Unavailable
    );
    assert!(!provider_inline_connected(&response, "codex"));
    assert!(provider_inline_connected(&response, "opencode"));
    assert_eq!(
        provider_detail(&response, "codex").as_deref(),
        Some(BridgeNotice::InlineReconnecting.message())
    );
}

#[test]
fn legacy_control_response_uses_aggregate_readiness_as_fallback() {
    let response: ControlResponse = serde_json::from_value(serde_json::json!({
        "version": CONTROL_VERSION,
        "status": "running",
        "processId": 42,
        "inlineConnected": true,
        "providerReady": true,
        "detail": null
    }))
    .unwrap();
    assert_eq!(
        provider_state(&response, "codex"),
        ProviderRuntimeState::Ready
    );
    assert!(provider_inline_connected(&response, "codex"));
}

#[test]
fn launchd_state_distinguishes_loaded_stopped_from_running() {
    assert!(launchd_output_indicates_running(
        "job = {\n\tstate = running\n\tjob state = running\n}"
    ));
    assert!(!launchd_output_indicates_running(
        "job = {\n\tstate = not running\n\tjob state = exited\n}"
    ));
    assert!(launchd_output_indicates_disabled(
        "disabled services = {\n\t\"chat.inline.legacy.42\" => true\n}",
        "chat.inline.legacy.42"
    ));
    assert!(launchd_output_indicates_disabled(
        "disabled services = {\n\t\"chat.inline.legacy.42\" => disabled\n}",
        "chat.inline.legacy.42"
    ));
    assert!(!launchd_output_indicates_disabled(
        "disabled services = {\n\t\"chat.inline.legacy.42\" => false\n}",
        "chat.inline.legacy.42"
    ));
    assert!(!launchd_output_indicates_disabled(
        "disabled services = {\n\t\"chat.inline.legacy.42\" => enabled\n}",
        "chat.inline.legacy.42"
    ));
    assert!(!launchd_output_indicates_disabled(
        "disabled services = {\n\t\"chat.inline.legacy.420\" => disabled\n}",
        "chat.inline.legacy.42"
    ));
}

#[cfg(unix)]
#[tokio::test]
async fn control_socket_authenticates_status_and_shutdown() {
    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = PathBuf::from("/tmp").join(format!("ibc-{}-{unique}", std::process::id()));
    ensure_private_dir(&root).unwrap();
    let (_, _, mut paths) = fixture();
    paths.root = root.clone();
    paths.control_socket = root.join("control.sock");
    let secrets = AccountBridgeSecrets {
        version: 1,
        owner_user_id: 42,
        control_token: "control-secret".to_string(),
        owner_token: "owner-secret".to_string(),
        providers: vec![super::super::ProviderCredentials {
            installation_id: "codex".to_string(),
            bot_user_id: 84,
            bot_token: "bot-secret".to_string(),
        }],
    };
    let health = RuntimeHealth::ready();
    let server = ControlServer::bind(
        &paths.control_socket,
        secrets.control_token.clone(),
        health.clone(),
    )
    .await
    .unwrap();
    let mut shutdown = server.shutdown_receiver();

    let status = control_request(&paths, &secrets, ControlCommand::Status)
        .await
        .unwrap();
    assert_eq!(status.status, "running");
    assert!(status.inline_connected);
    assert!(status.provider_ready);

    health.mark_provider_unavailable();
    let status = control_request(&paths, &secrets, ControlCommand::Status)
        .await
        .unwrap();
    assert!(status.inline_connected);
    assert!(!status.provider_ready);

    let invalid = AccountBridgeSecrets {
        control_token: "wrong".to_string(),
        ..secrets.clone()
    };
    assert!(
        control_request(&paths, &invalid, ControlCommand::Status)
            .await
            .is_err()
    );

    let response = control_request(&paths, &secrets, ControlCommand::Shutdown)
        .await
        .unwrap();
    assert_eq!(response.status, "stopping");
    shutdown.changed().await.unwrap();
    assert!(*shutdown.borrow());
    server.close().await;
    assert!(!paths.control_socket.exists());
}

#[cfg(unix)]
fn open_descriptor_count() -> usize {
    let limit = unsafe { libc::getdtablesize() };
    (0..limit)
        .filter(|descriptor| unsafe { libc::fcntl(*descriptor, libc::F_GETFD) } >= 0)
        .count()
}

#[cfg(unix)]
async fn assert_control_server_epochs_release_descriptors() {
    let root = tempfile::tempdir().expect("control fixture");
    let (_, _, mut paths) = fixture();
    paths.root = root.path().to_path_buf();
    let secrets = AccountBridgeSecrets {
        version: 1,
        owner_user_id: 42,
        control_token: "control-secret".to_string(),
        owner_token: "owner-secret".to_string(),
        providers: vec![],
    };
    let before = open_descriptor_count();

    for epoch in 0..64 {
        paths.control_socket = root.path().join(format!("control-{epoch}.sock"));
        let server = ControlServer::bind(
            &paths.control_socket,
            secrets.control_token.clone(),
            RuntimeHealth::ready(),
        )
        .await
        .expect("bind control epoch");
        let response = control_request(&paths, &secrets, ControlCommand::Status)
            .await
            .expect("query control epoch");
        assert_eq!(response.status, "running");
        server.close().await;
        assert!(!paths.control_socket.exists());
    }

    tokio::task::yield_now().await;
    let after = open_descriptor_count();
    assert!(
        after <= before + 4,
        "control epochs leaked descriptors: before={before}, after={after}"
    );
}

#[cfg(unix)]
#[tokio::test]
#[ignore = "subprocess helper for isolated process-wide descriptor accounting"]
async fn control_server_descriptor_subprocess() {
    assert_control_server_epochs_release_descriptors().await;
}

#[cfg(unix)]
#[test]
fn repeated_control_server_epochs_release_listener_and_connection_descriptors() {
    let output = std::process::Command::new(std::env::current_exe().expect("current test binary"))
        .args([
            "--ignored",
            "--exact",
            "bridge::service::tests::control_server_descriptor_subprocess",
        ])
        .output()
        .expect("run isolated descriptor-accounting subprocess");
    assert!(
        output.status.success(),
        "isolated descriptor-accounting subprocess failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}
