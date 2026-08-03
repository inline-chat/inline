use super::*;

#[test]
fn debug_settings_output_redacts_picker_capabilities_recursively() {
    let secret = "capability-that-must-never-be-printed";
    let mut value = serde_json::json!({
        "response": {
            "localPickerCapability": secret,
            "nested": [{ "local_picker_capability": secret }],
        }
    });

    dev::redact_debug_settings_secrets(&mut value);

    let output = serde_json::to_string(&value).expect("serialize redacted output");
    assert!(!output.contains(secret));
    assert_eq!(
        value["response"]["localPickerCapability"],
        serde_json::Value::String("[redacted]".to_string())
    );
    assert_eq!(
        value["response"]["nested"][0]["local_picker_capability"],
        serde_json::Value::String("[redacted]".to_string())
    );
}

#[test]
fn provider_restart_backoff_is_bounded_and_starts_promptly() {
    assert_eq!(provider_restart_delay(0), Duration::from_secs(1));
    assert_eq!(provider_restart_delay(1), Duration::from_secs(1));
    assert_eq!(provider_restart_delay(2), Duration::from_secs(2));
    assert_eq!(provider_restart_delay(6), Duration::from_secs(30));
    assert_eq!(provider_restart_delay(u32::MAX), Duration::from_secs(30));
}

#[test]
fn inline_message_retry_backoff_is_jittered_and_bounded() {
    assert_eq!(
        message_retry_delay_with_entropy(0, 0),
        Duration::from_millis(112)
    );
    assert_eq!(
        message_retry_delay_with_entropy(0, 50),
        Duration::from_millis(187)
    );
    assert_eq!(
        message_retry_delay_with_entropy(1, 0),
        Duration::from_millis(225)
    );
    assert_eq!(
        message_retry_delay_with_entropy(u32::MAX, 50),
        Duration::from_millis(1_500)
    );
}

pub(super) fn account_fixture() -> (AccountBridgeConfig, AccountBridgeSecrets) {
    let codex = ProviderInstallationConfig {
        installation_id: "codex".to_string(),
        provider_id: "codex".to_string(),
        bot_user_id: 84,
        bot_username: "inline_codex_42_bot".to_string(),
        dm_chat_id: Some(12),
        workspace: PathBuf::from("/tmp/project"),
        greeting_sent: true,
        accept_messages_after: 10,
        initial_cursor_seeded: true,
        display_name: "Mo's Codex".to_string(),
        managed_avatar_digest: None,
        managed_avatar_file_unique_id: None,
        executable: PathBuf::from("/usr/bin/codex"),
        provider_runtime: None,
        provider_path: "/usr/bin:/bin".to_string(),
        state_dir: PathBuf::from("/tmp/bridge/accounts/42/providers/codex"),
    };
    (
        AccountBridgeConfig {
            version: ACCOUNT_CONFIG_VERSION,
            owner_user_id: 42,
            host_installation_id: "host-test".to_string(),
            host_label: "Test Mac".to_string(),
            api_base_url: "http://localhost:8000/v1".to_string(),
            realtime_url: "ws://localhost:8000/realtime".to_string(),
            service_label: "chat.inline.agent-bridge.42".to_string(),
            service_binary: PathBuf::from("/tmp/bridge/accounts/42/bin/inline"),
            provider_path: "/usr/bin:/bin".to_string(),
            superseded_service_labels: Vec::new(),
            operator_user_ids: vec![42],
            owner_control_cursor_seeded: true,
            providers: vec![codex],
        },
        AccountBridgeSecrets {
            version: ACCOUNT_SECRETS_VERSION,
            owner_user_id: 42,
            control_token: "control-secret".to_string(),
            owner_token: "owner-secret".to_string(),
            providers: vec![ProviderCredentials {
                installation_id: "codex".to_string(),
                bot_user_id: 84,
                bot_token: "bot-secret".to_string(),
            }],
        },
    )
}

#[test]
fn account_secret_debug_output_is_redacted() {
    let (_, secrets) = account_fixture();
    let rendered = format!("{secrets:?}");
    assert!(!rendered.contains("control-secret"));
    assert!(!rendered.contains("owner-secret"));
    assert!(!rendered.contains("bot-secret"));
    assert!(rendered.contains("<redacted>"));
}

#[test]
fn provider_bot_usernames_are_stable_provider_and_host_scoped() {
    let host_a = "host-0123456789abcdef0123456789abcdef";
    let host_b = "host-fedcba9876543210fedcba9876543210";
    let usernames = ["codex", "opencode", "claude", "amp"]
        .map(|provider_id| provider_bot_username(provider_id, 1_600, host_a));
    assert_eq!(
        usernames,
        ["codex", "opencode", "claude", "amp"].map(|provider_id| provider_bot_username(
            provider_id,
            1_600,
            host_a
        ))
    );
    assert_ne!(usernames[0], provider_bot_username("codex", 1_600, host_b));
    assert!(usernames.iter().all(|username| username.ends_with("bot")));
    assert!(usernames.iter().all(|username| username.len() <= 64));
    assert_ne!(
        provider_installation_id("codex", host_a),
        provider_installation_id("codex", host_b)
    );
}

#[test]
fn control_tokens_are_random_sized_hex_without_shell_metacharacters() {
    let first = generate_control_token();
    let second = generate_control_token();
    assert_eq!(first.len(), 64);
    assert!(first.bytes().all(|byte| byte.is_ascii_hexdigit()));
    assert_ne!(first, second);
}

#[test]
fn interactive_message_identity_is_stable_and_kind_scoped() {
    let first = interaction_random_id("question", "token-1");
    assert_eq!(first, interaction_random_id("question", "token-1"));
    assert_ne!(first, interaction_random_id("approval", "token-1"));
    assert_ne!(first, interaction_random_id("question", "token-2"));
    assert!(first.get() > 0);
}

#[test]
fn legacy_secret_debug_output_is_redacted() {
    let secrets = DevBridgeSecrets {
        bot_user_id: 42,
        bot_token: "bot-secret".to_string(),
        control_token: "control-secret".to_string(),
    };
    let debug = format!("{secrets:?}");
    assert!(debug.contains("<redacted>"));
    assert!(!debug.contains("bot-secret"));
    assert!(!debug.contains("control-secret"));
}

#[test]
fn setup_defaults_to_home_but_explicit_folder_wins() {
    let home = env::var_os("HOME")
        .or_else(|| env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .expect("test home directory");
    let directory = tempfile::tempdir().expect("temporary directory");
    let explicit = directory.path().join("explicit");
    fs::create_dir(&explicit).expect("explicit workspace");

    assert_eq!(
        resolve_setup_workspace(None).unwrap(),
        fs::canonicalize(home).unwrap()
    );
    assert_eq!(
        resolve_setup_workspace(Some(explicit.clone())).unwrap(),
        fs::canonicalize(explicit).unwrap()
    );
}

#[test]
fn account_paths_scope_service_and_provider_state_by_owner() {
    let config = Config {
        api_base_url: "http://localhost:8000/v1".to_string(),
        realtime_url: "ws://localhost:8000/realtime".to_string(),
        secrets_path: PathBuf::from("/tmp/inline/secrets.json"),
        state_path: PathBuf::from("/tmp/inline/state.json"),
        data_dir: PathBuf::from("/tmp/inline"),
        release_manifest_url: None,
        release_install_url: None,
    };
    let paths = BridgePaths::for_owner(&config, 42);
    assert_eq!(paths.root, PathBuf::from("/tmp/inline/bridge/accounts/42"));
    assert_eq!(
        paths.installed_binary,
        PathBuf::from("/tmp/inline/bridge/accounts/42/bin/inline")
    );
    let (account, _) = account_fixture();
    let provider = paths.provider_paths(&account.providers[0]);
    assert_eq!(
        provider.bridge_db,
        PathBuf::from("/tmp/bridge/accounts/42/providers/codex/bridge.sqlite")
    );

    let wrong_paths = BridgePaths::from_root(
        PathBuf::from("/tmp/inline/bridge/accounts/99"),
        PathBuf::from("/tmp/inline/bridge/accounts/99/bin/inline"),
    );
    assert!(validate_account_location(&wrong_paths, &account).is_err());
}

#[test]
fn legacy_v3_adapts_without_relocating_provider_databases() {
    let legacy_root = PathBuf::from("/tmp/inline/bridge/codex");
    let legacy = DevBridgeConfig {
        version: LEGACY_CONFIG_VERSION,
        installation_id: "codex".to_string(),
        owner_user_id: 42,
        bot_user_id: 84,
        bot_username: "inline_codex_42_bot".to_string(),
        dm_chat_id: Some(12),
        workspace: PathBuf::from("/tmp/project"),
        greeting_sent: true,
        accept_messages_after: 10,
        initial_cursor_seeded: false,
        display_name: "Mo's Codex".to_string(),
        api_base_url: "http://localhost:8000/v1".to_string(),
        realtime_url: "ws://localhost:8000/realtime".to_string(),
        codex_executable: PathBuf::from("/usr/bin/codex"),
        provider_path: "/usr/bin:/bin".to_string(),
        service_label: "chat.inline.agent-bridge.42".to_string(),
        service_binary: PathBuf::from("/tmp/inline/bin/inline"),
    };
    let legacy_secrets = DevBridgeSecrets {
        bot_user_id: 84,
        bot_token: "bot-secret".to_string(),
        control_token: "control-secret".to_string(),
    };
    let (mut account, secrets) = account_from_legacy(legacy, legacy_secrets, &legacy_root).unwrap();
    assert_eq!(account.version, ACCOUNT_CONFIG_VERSION);
    assert_eq!(account.providers[0].state_dir, legacy_root);
    assert_eq!(
        account.providers[0].workspace,
        PathBuf::from("/tmp/project")
    );
    assert_eq!(secrets.owner_user_id, 42);
    assert_eq!(secrets.providers[0].installation_id, "codex");

    account.service_label = "chat.inline.legacy-agent.42".to_string();
    adopt_service_identity(
        &mut account,
        "chat.inline.agent-bridge.42".to_string(),
        PathBuf::from("/tmp/inline/bridge/accounts/42/bin/inline"),
    );
    assert_eq!(
        account.superseded_service_labels,
        vec!["chat.inline.legacy-agent.42"]
    );
    assert_eq!(account.service_label, "chat.inline.agent-bridge.42");
    assert_eq!(account.providers[0].state_dir, legacy_root);
}

#[test]
fn account_schema_preserves_multiple_provider_namespaces() {
    let (mut account, mut secrets) = account_fixture();
    let mut claude = account.providers[0].clone();
    claude.installation_id = "claude".to_string();
    claude.provider_id = "claude".to_string();
    claude.bot_user_id = 85;
    claude.bot_username = "inline_claude_42_bot".to_string();
    claude.display_name = "Mo's Claude".to_string();
    claude.executable = PathBuf::from("/usr/bin/claude");
    claude.state_dir = PathBuf::from("/tmp/bridge/accounts/42/providers/claude");
    account.providers.push(claude);
    secrets.providers.push(ProviderCredentials {
        installation_id: "claude".to_string(),
        bot_user_id: 85,
        bot_token: "claude-secret".to_string(),
    });
    validate_account(&account, &secrets).unwrap();
    assert_eq!(account.providers.len(), 2);
    assert_eq!(secrets.providers.len(), 2);
    let serialized = serde_json::to_string(&account).unwrap();
    assert!(!serialized.contains("bot-secret"));
    assert!(!serialized.contains("claude-secret"));
}

#[test]
fn setup_upsert_preserves_sibling_provider_identity_and_state() {
    let (mut account, mut secrets) = account_fixture();
    let codex_before = account.providers[0].clone();
    let codex_secret_before = secrets.providers[0].clone();
    let mut opencode = codex_before.clone();
    opencode.installation_id = "opencode".to_string();
    opencode.provider_id = "opencode".to_string();
    opencode.bot_user_id = 86;
    opencode.bot_username = "inline_opencode_42_bot".to_string();
    opencode.display_name = "Mo's OpenCode".to_string();
    opencode.executable = PathBuf::from("/usr/bin/opencode");
    opencode.state_dir = PathBuf::from("/tmp/bridge/accounts/42/providers/opencode");
    let opencode_secret = ProviderCredentials {
        installation_id: "opencode".to_string(),
        bot_user_id: 86,
        bot_token: "opencode-secret".to_string(),
    };

    upsert_provider_identity(
        &mut account,
        &mut secrets,
        opencode.clone(),
        opencode_secret.clone(),
    )
    .unwrap();
    opencode.workspace = PathBuf::from("/tmp/another-project");
    upsert_provider_identity(
        &mut account,
        &mut secrets,
        opencode.clone(),
        opencode_secret,
    )
    .unwrap();

    assert_eq!(account.providers.len(), 2);
    assert_eq!(secrets.providers.len(), 2);
    assert_eq!(
        account.providers[0].installation_id,
        codex_before.installation_id
    );
    assert_eq!(account.providers[0].state_dir, codex_before.state_dir);
    assert_eq!(
        secrets.providers[0].bot_user_id,
        codex_secret_before.bot_user_id
    );
    assert_eq!(
        account
            .providers
            .iter()
            .find(|provider| provider.provider_id == "opencode")
            .unwrap()
            .workspace,
        PathBuf::from("/tmp/another-project")
    );
    validate_account(&account, &secrets).unwrap();
}

#[test]
fn account_validation_rejects_duplicate_and_mismatched_identities() {
    let (mut account, secrets) = account_fixture();
    account.providers.push(account.providers[0].clone());
    assert!(validate_account(&account, &secrets).is_err());

    let (account, mut secrets) = account_fixture();
    secrets.providers[0].bot_user_id = 999;
    assert!(validate_account(&account, &secrets).is_err());

    let (account, mut secrets) = account_fixture();
    secrets.owner_user_id = 99;
    assert!(validate_account(&account, &secrets).is_err());

    let (mut account, secrets) = account_fixture();
    account.service_label = "../unsafe".to_string();
    assert!(validate_account(&account, &secrets).is_err());
}

#[test]
fn setup_validation_allows_missing_credentials_but_not_identity_mismatch() {
    let (account, mut secrets) = account_fixture();
    secrets.control_token.clear();
    secrets.providers.clear();
    validate_account_for_setup(&account, &secrets).unwrap();

    let (account, mut secrets) = account_fixture();
    secrets.providers[0].bot_user_id = 999;
    assert!(validate_account_for_setup(&account, &secrets).is_err());
}

fn account_fixture_at(root: &Path) -> (BridgePaths, AccountBridgeConfig, AccountBridgeSecrets) {
    let paths = BridgePaths::from_root(root.to_path_buf(), root.join("bin").join("inline"));
    let (mut account, secrets) = account_fixture();
    account.service_binary = paths.installed_binary.clone();
    account.providers[0].state_dir = root.join("providers").join("codex");
    (paths, account, secrets)
}

#[test]
fn interrupted_first_setup_ignores_orphaned_secrets_and_retries_cleanly() {
    let directory = tempfile::tempdir().expect("tempdir");
    let root = directory.path().join("accounts").join("42");
    let (paths, account, secrets) = account_fixture_at(&root);
    ensure_private_dir(&paths.root).expect("account directory");

    assert_eq!(
        setup_account_write_order(false),
        [SetupAccountFile::Secrets, SetupAccountFile::Config]
    );
    write_private_json(&paths.secrets, &secrets).expect("first setup write");
    assert!(!paths.config.is_file());

    persist_setup_account_files(&paths, &account, &secrets, false).expect("setup retry");
    let (loaded_account, loaded_secrets) =
        load_account_files(&paths).expect("load recovered setup");
    validate_account(&loaded_account, &loaded_secrets).expect("valid recovered setup");
}

#[test]
fn interrupted_provider_addition_is_repairable_from_committed_config() {
    let directory = tempfile::tempdir().expect("tempdir");
    let root = directory.path().join("accounts").join("42");
    let (paths, account, secrets) = account_fixture_at(&root);
    ensure_private_dir(&paths.root).expect("account directory");
    persist_setup_account_files(&paths, &account, &secrets, false).expect("initial setup");

    let mut next_account = account.clone();
    let mut next_secrets = secrets.clone();
    let mut claude = account.providers[0].clone();
    claude.installation_id = "claude".to_string();
    claude.provider_id = "claude".to_string();
    claude.bot_user_id = 85;
    claude.bot_username = "inline_claude_42_bot".to_string();
    claude.display_name = "Mo's Claude".to_string();
    claude.executable = PathBuf::from("/usr/bin/claude");
    claude.state_dir = root.join("providers").join("claude");
    let claude_credentials = ProviderCredentials {
        installation_id: "claude".to_string(),
        bot_user_id: 85,
        bot_token: "claude-secret".to_string(),
    };
    upsert_provider_identity(
        &mut next_account,
        &mut next_secrets,
        claude,
        claude_credentials,
    )
    .expect("add provider");

    assert_eq!(
        setup_account_write_order(true),
        [SetupAccountFile::Config, SetupAccountFile::Secrets]
    );
    write_private_json(&paths.config, &next_account).expect("interrupted config write");
    let (partial_account, partial_secrets) =
        load_account_files(&paths).expect("load partial setup");
    validate_account_for_setup(&partial_account, &partial_secrets)
        .expect("missing new credentials are repairable");
    assert!(validate_account(&partial_account, &partial_secrets).is_err());

    persist_setup_account_files(&paths, &next_account, &next_secrets, true).expect("setup retry");
    let (loaded_account, loaded_secrets) =
        load_account_files(&paths).expect("load recovered setup");
    validate_account(&loaded_account, &loaded_secrets).expect("valid recovered setup");
    assert_eq!(loaded_account.providers.len(), 2);
    assert_eq!(loaded_secrets.providers.len(), 2);
}

#[test]
fn private_chat_id_accepts_server_string_ids() {
    let chat = serde_json::json!({ "id": "706" });
    assert_eq!(private_chat_id(&chat, &serde_json::json!({})).unwrap(), 706);
}

#[test]
fn callback_payload_round_trips_provider_choices() {
    let callback = ApprovalCallback {
        version: 1,
        token: "opaque-token".to_string(),
        decision: CallbackDecision::Option { index: 4 },
    };
    let decoded: ApprovalCallback =
        serde_json::from_slice(&serde_json::to_vec(&callback).unwrap()).unwrap();
    assert_eq!(decoded.token, "opaque-token");
    assert!(matches!(
        decoded.decision,
        CallbackDecision::Option { index: 4 }
    ));
}

#[test]
fn shared_approval_callback_routes_from_private_dm_to_origin_turn() {
    let store = BridgeStore::open_in_memory().expect("store");
    let callback = ApprovalCallback {
        version: 1,
        token: "opaque-token".to_string(),
        decision: CallbackDecision::Option { index: 0 },
    };
    store
        .insert_approval(&PendingApproval {
            callback_token: callback.token.clone(),
            installation_id: InstallationId::new("codex").expect("installation"),
            provider_id: ProviderId::new("codex").expect("provider"),
            provider_approval_id: "provider-approval".to_string(),
            turn_id: inline_agent_bridge::TurnId::new("turn-1").expect("turn"),
            origin_chat_id: 708,
            action_chat_id: 706,
            message_id: Some(9),
            origin_status_message_id: Some(10),
            decisions: vec![ApprovalDecision::ApproveOnce],
            created_at: 100,
            expires_at: 200,
        })
        .expect("insert approval");
    let mut event = ClientEvent::MessageActionInvoked {
        interaction_id: InlineId::new(1),
        chat_id: InlineId::new(706),
        message_id: InlineId::new(9),
        actor_user_id: InlineId::new(42),
        action_id: "bridge_approval_0".to_string(),
        data: serde_json::to_vec(&callback).expect("callback"),
    };

    assert_eq!(
        approval_dispatch_chat_id(&event, &store).expect("dispatch"),
        Some(708)
    );
    if let ClientEvent::MessageActionInvoked { chat_id, .. } = &mut event {
        *chat_id = InlineId::new(999);
    }
    assert_eq!(
        approval_dispatch_chat_id(&event, &store).expect("wrong chat"),
        None
    );
}

#[test]
fn outsider_approval_callback_stays_pending_before_provider_dispatch() {
    let store = BridgeStore::open_in_memory().expect("store");
    let installation_id = InstallationId::new("codex").expect("installation");
    let turn_id = inline_agent_bridge::TurnId::new("turn-1").expect("turn");
    let callback = ApprovalCallback {
        version: 1,
        token: "outsider-proof".to_string(),
        decision: CallbackDecision::Option { index: 0 },
    };
    store
        .insert_approval(&PendingApproval {
            callback_token: callback.token.clone(),
            installation_id: installation_id.clone(),
            provider_id: ProviderId::new("codex").expect("provider"),
            provider_approval_id: "provider-approval".to_string(),
            turn_id: turn_id.clone(),
            origin_chat_id: 708,
            action_chat_id: 706,
            message_id: Some(9),
            origin_status_message_id: Some(10),
            decisions: vec![ApprovalDecision::ApproveOnce],
            created_at: 100,
            expires_at: 200,
        })
        .expect("insert approval");
    let event = ClientEvent::MessageActionInvoked {
        interaction_id: InlineId::new(1),
        chat_id: InlineId::new(706),
        message_id: InlineId::new(9),
        actor_user_id: InlineId::new(8),
        action_id: "bridge_approval_0".to_string(),
        data: serde_json::to_vec(&callback).expect("callback"),
    };

    let dispatch_chat_id = approval_dispatch_chat_id(&event, &store)
        .expect("dispatch lookup")
        .expect("known approval callback");
    let ClientEvent::MessageActionInvoked {
        chat_id,
        actor_user_id,
        ..
    } = event
    else {
        unreachable!("approval event")
    };
    let outcome = store
        .claim_approval(
            &callback.token,
            0,
            &ApprovalClaimContext {
                installation_id,
                turn_id,
                origin_chat_id: dispatch_chat_id,
                action_chat_id: chat_id.get(),
                actor_user_id: actor_user_id.get(),
                allowed_actor_user_id: 7,
                now: 150,
            },
        )
        .expect("claim outcome");

    assert_eq!(outcome, ApprovalClaimOutcome::Unauthorized);
    assert_eq!(
        store
            .get_approval(&callback.token)
            .expect("approval lookup")
            .expect("approval record")
            .state,
        inline_agent_bridge::ApprovalState::Pending
    );
}

#[test]
fn shared_approval_copy_keeps_details_private() {
    assert_eq!(
        shared_approval_waiting_text("Mo"),
        "Waiting for Mo’s approval."
    );
    assert!(!shared_approval_waiting_text("Mo").contains("command"));
}

#[test]
fn agent_command_catalog_is_stable_and_within_server_limits() {
    let catalog = agent_command_catalog();
    let names = catalog
        .iter()
        .map(|command| command.command.as_str())
        .collect::<Vec<_>>();
    assert_eq!(
        names,
        vec![
            "help",
            "status",
            "new",
            "clear",
            "compact",
            "folder",
            "follow",
            "unfollow",
            "queue",
            "stop",
            "model",
            "reasoning",
            "permissions",
            "verbose",
            "threads",
            "allowlist",
        ]
    );
    assert!(catalog.len() <= 100);
    for (index, command) in catalog.iter().enumerate() {
        assert!(!command.command.is_empty() && command.command.len() <= 32);
        assert!(
            command
                .command
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
        );
        assert!(!command.description.is_empty() && command.description.len() <= 256);
        assert_eq!(command.sort_order, i32::try_from(index).ok());
    }
}

#[test]
fn final_output_keeps_file_list_concise_and_relative() {
    let workspace = Path::new("/tmp/project");
    let mut files = (0..10)
        .map(|index| FileChange {
            path: workspace.join(format!("src/file-{index}.rs")),
            summary: (index == 0).then(|| "updated parser".to_string()),
        })
        .collect::<Vec<_>>();
    files.push(FileChange {
        path: PathBuf::from("/private/secret/outside.rs"),
        summary: None,
    });
    let output = final_turn_text(
        "Done.",
        TurnOutcome::Completed,
        &files,
        workspace,
        true,
        None,
    );
    assert!(
        output.contains("- [`src/file-0.rs`](file:///tmp/project/src/file-0.rs) — updated parser")
    );
    assert!(output.contains("- and 2 more"));
    assert!(!output.contains("file-8.rs"));
    assert!(!output.contains("/private/secret"));
    assert!(output.contains("Checks: not reported separately."));

    let shared_output = final_turn_text(
        "Done.",
        TurnOutcome::Completed,
        &files,
        workspace,
        false,
        None,
    );
    assert!(shared_output.contains("- `src/file-0.rs` — updated parser"));
    assert!(!shared_output.contains("file://"));
}

#[test]
fn changed_file_code_labels_handle_backticks_safely() {
    assert_eq!(
        markdown_code_span("src/odd`name.rs"),
        "`` src/odd`name.rs ``"
    );
    assert_eq!(markdown_code_span("src/main.rs"), "`src/main.rs`");
}

#[test]
fn changed_file_actions_copy_only_safe_relative_paths() {
    let workspace = Path::new("/tmp/project");
    let files = vec![
        FileChange {
            path: workspace.join("src/lib.rs"),
            summary: None,
        },
        FileChange {
            path: PathBuf::from("/private/secret/outside.rs"),
            summary: None,
        },
        FileChange {
            path: workspace.join("../secret/escaped.rs"),
            summary: None,
        },
    ];
    let actions = changed_file_actions(&files, workspace);
    assert_eq!(actions.rows.len(), 1);
    assert_eq!(actions.rows[0].actions[0].text, "Copy Path · lib.rs");
    assert!(matches!(
        &actions.rows[0].actions[0].kind,
        MessageActionKind::CopyText { text } if text == "src/lib.rs"
    ));
}

#[test]
fn unhealthy_provider_status_fails_the_command_gate() {
    let mut status = service::BridgeStatus {
        status: "running".to_string(),
        installed: true,
        service_loaded: true,
        healthy: true,
        provider: "codex".to_string(),
        display_name: Some("Codex".to_string()),
        bot_username: Some("mo_codex".to_string()),
        workspace: Some("project".to_string()),
        process_id: Some(42),
        inline_connected: true,
        provider_ready: true,
        detail: None,
    };
    assert!(ensure_provider_statuses_healthy(&[status.clone()]).is_ok());

    status.healthy = false;
    status.status = "needs_attention".to_string();
    assert!(ensure_provider_statuses_healthy(&[status]).is_err());
}

#[cfg(unix)]
#[test]
fn changed_file_paths_reject_symlink_workspace_escapes() {
    use std::os::unix::fs::symlink;

    let root = tempfile::tempdir().expect("temporary root");
    let workspace = root.path().join("workspace");
    let outside = root.path().join("outside");
    fs::create_dir_all(&workspace).expect("workspace");
    fs::create_dir_all(&outside).expect("outside");
    fs::write(outside.join("secret.txt"), "secret").expect("outside file");
    symlink(&outside, workspace.join("linked")).expect("workspace escape symlink");

    let escaped = workspace.join("linked/secret.txt");
    assert_eq!(safe_relative_path(&escaped, &workspace), None);
    assert_eq!(
        safe_relative_path(Path::new("linked/secret.txt"), &workspace),
        None
    );
    assert!(
        changed_file_actions(
            &[FileChange {
                path: escaped,
                summary: None,
            }],
            &workspace,
        )
        .rows
        .is_empty()
    );
}

#[cfg(unix)]
#[test]
fn changed_file_paths_reject_replaced_workspace_roots() {
    use std::os::unix::fs::symlink;

    let root = tempfile::tempdir().expect("temporary root");
    let workspace = root.path().join("workspace");
    let moved_workspace = root.path().join("moved-workspace");
    let outside = root.path().join("outside");
    fs::create_dir_all(&workspace).expect("workspace");
    fs::create_dir_all(&outside).expect("outside");
    fs::write(outside.join("secret.txt"), "secret").expect("outside file");
    fs::rename(&workspace, &moved_workspace).expect("move original workspace");
    symlink(&outside, &workspace).expect("replace workspace with symlink");

    assert_eq!(
        safe_relative_path(Path::new("secret.txt"), &workspace),
        None
    );
}

#[test]
fn failed_and_interrupted_partial_output_stays_honest_without_raw_errors() {
    let workspace = Path::new("/tmp/project");
    let failed = final_turn_text(
        "Partial output",
        TurnOutcome::Failed,
        &[],
        workspace,
        false,
        None,
    );
    assert!(failed.contains("Partial output"));

    let authentication = final_turn_text(
        "Partial output",
        TurnOutcome::AuthenticationRequired,
        &[],
        workspace,
        false,
        None,
    );
    assert!(authentication.contains("Partial output"));
    assert!(authentication.contains(BridgeNotice::AuthenticationRequired.message()));
    assert!(failed.contains("couldn’t finish"));
    assert!(!failed.contains("secret diagnostic"));

    let disconnected = final_turn_text(
        "Partial output",
        TurnOutcome::ConnectionLost,
        &[],
        workspace,
        false,
        None,
    );
    assert!(disconnected.contains(BridgeNotice::AgentConnectionLost.message()));

    let interrupted = final_turn_text(
        "Partial output",
        TurnOutcome::Interrupted,
        &[],
        workspace,
        false,
        None,
    );
    assert_eq!(interrupted, "Stopped.");
}

#[test]
fn utf16_truncation_respects_action_label_limit() {
    let truncated = truncate_utf16(&"🦀".repeat(40), 64);
    assert!(truncated.encode_utf16().count() <= 64);
    assert!(truncated.ends_with('…'));
}

#[test]
fn diagnostics_are_bounded_and_redact_secret_markers() {
    assert_eq!(
        safe_diagnostic("request used Authorization: Bearer private"),
        "[redacted provider diagnostic]"
    );
    assert_eq!(
        safe_diagnostic("request failed with token=private-value"),
        "[redacted provider diagnostic]"
    );
    assert_eq!(
        safe_diagnostic(
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnopqrstuvwxyz"
        ),
        "[redacted provider diagnostic]"
    );
    assert!(safe_diagnostic(&"x".repeat(1_000)).len() <= 513);
}
