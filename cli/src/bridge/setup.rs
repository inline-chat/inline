//! Project selection and durable provider-bot provisioning.

use super::*;

pub(super) fn resolve_setup_workspace(
    explicit: Option<PathBuf>,
) -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Some(path) = explicit {
        return validate_workspace_choice(canonical_workspace(&path)?);
    }

    let home = env::var_os("HOME")
        .filter(|value| !value.is_empty())
        .or_else(|| env::var_os("USERPROFILE").filter(|value| !value.is_empty()))
        .map(PathBuf::from)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "user home directory not found; pass --folder /absolute/path",
            )
        })?;
    validate_workspace_choice(canonical_workspace(&home)?)
}

pub(super) fn validate_workspace_choice(
    path: PathBuf,
) -> Result<PathBuf, Box<dyn std::error::Error>> {
    if path.parent().is_none() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "the filesystem root cannot be used as a bridge workspace",
        )
        .into());
    }
    Ok(path)
}

pub(super) fn workspace_label(path: &Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .unwrap_or("project")
        .to_string()
}

pub(super) fn working_directory_message(path: &Path) -> String {
    let home = env::var_os("HOME").map(PathBuf::from);
    let canonical_home = home.as_deref().and_then(|home| fs::canonicalize(home).ok());
    let relative = canonical_home
        .as_deref()
        .and_then(|home| path.strip_prefix(home).ok())
        .or_else(|| {
            home.as_deref()
                .and_then(|home| path.strip_prefix(home).ok())
        });
    let display = match relative {
        Some(relative) if relative.as_os_str().is_empty() => "~".to_string(),
        Some(relative) => format!("~/{}", relative.display()),
        None => format!("…/{}", workspace_label(path)),
    };
    format!("Working directory: {}", markdown_code_span(&display))
}

#[cfg(test)]
mod working_directory_tests {
    use super::*;

    #[test]
    fn working_directory_is_home_relative_and_markdown_safe() {
        let home = env::var_os("HOME").map(PathBuf::from).expect("test home");
        assert_eq!(
            working_directory_message(&home.join("dev/inline")),
            "Working directory: `~/dev/inline`"
        );
        assert_eq!(
            working_directory_message(Path::new("/outside/example")),
            "Working directory: `…/example`"
        );
    }
}

pub(super) async fn wait_for_control_shutdown(
    shutdown_rx: &mut Option<tokio::sync::watch::Receiver<bool>>,
) {
    let Some(shutdown_rx) = shutdown_rx else {
        std::future::pending::<()>().await;
        return;
    };
    loop {
        if *shutdown_rx.borrow() {
            return;
        }
        if shutdown_rx.changed().await.is_err() {
            return;
        }
    }
}

pub(super) async fn wait_for_termination() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        let terminate = signal(SignalKind::terminate());
        match terminate {
            Ok(mut terminate) => {
                tokio::select! {
                    _ = tokio::signal::ctrl_c() => {}
                    _ = terminate.recv() => {}
                }
            }
            Err(_) => {
                let _ = tokio::signal::ctrl_c().await;
            }
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

pub(super) async fn wait_for_provider_exit(
    process_status: ProviderProcessStatus,
    health: service::RuntimeHealth,
) -> String {
    let description = process_status.wait_for_exit().await;
    health.mark_provider_unavailable();
    description
}

pub(super) struct ProvisionedBridge {
    pub(super) paths: BridgePaths,
    pub(super) account: AccountBridgeConfig,
    pub(super) secrets: AccountBridgeSecrets,
    pub(super) installation: ProviderInstallationConfig,
    pub(super) credentials: ProviderCredentials,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum SetupAccountFile {
    Config,
    Secrets,
}

pub(super) fn setup_account_write_order(account_preexisted: bool) -> [SetupAccountFile; 2] {
    if account_preexisted {
        // A missing new credential is intentionally repairable by setup. An
        // extra credential for a config that was not committed is not.
        [SetupAccountFile::Config, SetupAccountFile::Secrets]
    } else {
        // On first install the config is the commit marker. An orphaned
        // secrets file is ignored when setup retries without a config.
        [SetupAccountFile::Secrets, SetupAccountFile::Config]
    }
}

pub(super) fn persist_setup_account_files(
    paths: &BridgePaths,
    account: &AccountBridgeConfig,
    secrets: &AccountBridgeSecrets,
    account_preexisted: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    for file in setup_account_write_order(account_preexisted) {
        match file {
            SetupAccountFile::Config => write_private_json(&paths.config, account)?,
            SetupAccountFile::Secrets => write_private_json(&paths.secrets, secrets)?,
        }
    }
    Ok(())
}

pub(super) async fn provision_dev_bot(
    config: &Config,
    owner: &mut crate::owner_session::OwnerSession,
    me: proto::User,
    provider: &ProviderProbe,
    workspace: &Path,
    requested_name: Option<&str>,
) -> Result<ProvisionedBridge, Box<dyn std::error::Error>> {
    if me.id <= 0 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "owner id is invalid").into());
    }

    let requested_paths = BridgePaths::for_owner(config, me.id);
    ensure_private_dir(&requested_paths.root)?;
    let account_root = fs::canonicalize(&requested_paths.root)?;
    let paths = BridgePaths::from_root(
        account_root.clone(),
        account_root.join("bin").join("inline"),
    );
    // Setup performs a read/modify/write across both account files. Keep the
    // whole mutation serialized with the running bridge and other setup calls.
    let _account_mutation_lock = acquire_account_mutation_lock(&paths)?;
    let account_preexisted = paths.config.is_file();
    let (mut account, mut account_secrets) = if account_preexisted {
        let loaded = load_account_files(&paths)?;
        validate_account_for_setup(&loaded.0, &loaded.1)?;
        loaded
    } else {
        let legacy_paths = BridgePaths::legacy(config);
        if legacy_paths.config.is_file() {
            let (mut migrated, secrets) = load_account_files(&legacy_paths)?;
            if migrated.owner_user_id != me.id {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "the legacy bridge installation belongs to a different Inline user",
                )
                .into());
            }
            migrated.service_binary = paths.installed_binary.clone();
            (migrated, secrets)
        } else {
            let provider_path = default_provider_path();
            (
                AccountBridgeConfig {
                    version: ACCOUNT_CONFIG_VERSION,
                    owner_user_id: me.id,
                    host_installation_id: generate_host_installation_id(),
                    host_label: local_host_label(),
                    api_base_url: config.api_base_url.clone(),
                    realtime_url: config.realtime_url.clone(),
                    service_label: service::service_label(me.id),
                    service_binary: paths.installed_binary.clone(),
                    provider_path,
                    superseded_service_labels: Vec::new(),
                    operator_user_ids: vec![me.id],
                    owner_control_cursor_seeded: false,
                    providers: Vec::new(),
                },
                AccountBridgeSecrets {
                    version: ACCOUNT_SECRETS_VERSION,
                    owner_user_id: me.id,
                    control_token: generate_control_token(),
                    owner_auth: Some(owner.credential()?),
                    owner_token: String::new(),
                    providers: Vec::new(),
                },
            )
        }
    };
    if account.owner_user_id != me.id || account_secrets.owner_user_id != me.id {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "this bridge service belongs to a different Inline user",
        )
        .into());
    }
    if account.host_installation_id.trim().is_empty() {
        account.host_installation_id = generate_host_installation_id();
    }
    if account.host_label.trim().is_empty() {
        account.host_label = local_host_label();
    }
    account.version = ACCOUNT_CONFIG_VERSION;
    account.api_base_url = config.api_base_url.clone();
    account.realtime_url = config.realtime_url.clone();
    account.operator_user_ids.retain(|user_id| *user_id > 0);
    account.operator_user_ids.push(me.id);
    account.operator_user_ids.sort_unstable();
    account.operator_user_ids.dedup();
    adopt_service_identity(
        &mut account,
        service::service_label(me.id),
        paths.installed_binary.clone(),
    );
    account.provider_path = default_provider_path();
    account_secrets.version = ACCOUNT_SECRETS_VERSION;
    account_secrets.owner_auth = Some(owner.credential()?);
    account_secrets.owner_token.clear();
    if account_secrets.control_token.trim().is_empty() {
        account_secrets.control_token = generate_control_token();
    }

    let saved = account
        .providers
        .iter()
        .find(|installation| installation.provider_id == provider.provider_id)
        .cloned();
    let new_installation_id =
        provider_installation_id(provider.provider_id, &account.host_installation_id);
    let bot_username = saved
        .as_ref()
        .map(|saved| saved.bot_username.clone())
        .unwrap_or_else(|| {
            provider_bot_username(provider.provider_id, me.id, &account.host_installation_id)
        });
    let bots = owner.call(proto::ListBotsInput {}).await?.bots;
    let bot = if let Some(saved) = &saved {
        bots.iter().find(|bot| bot.id == saved.bot_user_id).cloned()
    } else {
        bots.iter()
            .find(|bot| bot.username.as_deref() == Some(bot_username.as_str()))
            .cloned()
    };

    let requested_name = requested_name
        .map(str::trim)
        .filter(|name| !name.is_empty());
    let default_name = || {
        let first_name = me
            .first_name
            .as_deref()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .unwrap_or("My");
        format!("{first_name}'s {}", provider.display_name)
    };
    let create_name = requested_name
        .map(str::to_owned)
        .or_else(|| {
            saved
                .as_ref()
                .map(|saved| saved.display_name.clone())
                .filter(|name| !name.is_empty())
        })
        .unwrap_or_else(default_name);

    let (mut bot, created_token) = match bot {
        Some(bot) => (bot, None),
        None if saved.is_some() => {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "the saved bridge bot is no longer available; setup repair is required",
            )
            .into());
        }
        None => {
            let result = owner
                .call(proto::CreateBotInput {
                    name: create_name.clone(),
                    username: bot_username.clone(),
                    add_to_space: None,
                })
                .await?;
            let bot = result.bot.ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "CreateBot returned no bot")
            })?;
            (bot, Some(result.token))
        }
    };

    let legacy_complete_name = bot
        .last_name
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(|last_name| {
            let first_name = bot.first_name.as_deref().unwrap_or_default().trim();
            format!("{first_name} {last_name}").trim().to_string()
        });
    let normalized_name = requested_name
        .map(str::to_string)
        .or(legacy_complete_name)
        .or_else(|| created_token.is_some().then(|| create_name.clone()));
    if let Some(name) = normalized_name.as_deref()
        && (bot.first_name.as_deref().unwrap_or_default().trim() != name
            || bot
                .last_name
                .as_deref()
                .is_some_and(|last_name| !last_name.trim().is_empty()))
    {
        bot = owner
            .call(proto::UpdateBotProfileInput {
                bot_user_id: bot.id,
                name: Some(name.to_string()),
                photo_file_unique_id: None,
            })
            .await?
            .bot
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "UpdateBotProfile returned no bot",
                )
            })?;
    }
    let profile_asset = provider_profile_asset(provider.provider_id).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{} has no bundled profile asset", provider.provider_id),
        )
    })?;
    validate_provider_profile_asset(profile_asset)
        .map_err(|message| io::Error::new(io::ErrorKind::InvalidData, message))?;
    let profile_digest = provider_profile_asset_digest(profile_asset);
    let current_photo_file_unique_id = bot
        .profile_photo
        .as_ref()
        .and_then(|photo| photo.file_unique_id.as_deref())
        .map(str::to_string);
    let current_avatar_is_managed = saved.as_ref().is_some_and(|saved| {
        saved.managed_avatar_file_unique_id.as_deref() == current_photo_file_unique_id.as_deref()
            && saved.managed_avatar_file_unique_id.is_some()
    });
    let should_apply_default_avatar = current_photo_file_unique_id.is_none()
        || (current_avatar_is_managed
            && saved
                .as_ref()
                .and_then(|saved| saved.managed_avatar_digest.as_deref())
                != Some(profile_digest.as_str()));
    let (managed_avatar_digest, managed_avatar_file_unique_id) = if should_apply_default_avatar {
        let source_path = std::env::temp_dir().join(format!(
            "inline-bridge-avatar-{}-{}",
            std::process::id(),
            provider.provider_id,
        ));
        tokio::fs::write(&source_path, profile_asset.bytes).await?;
        let upload = owner
            .upload(inline_sdk::NativeUploadInput::new(
                &source_path,
                profile_asset.file_name,
                profile_asset.mime_type,
                proto::UploadKind::Photo,
            ))
            .await;
        let _ = tokio::fs::remove_file(source_path).await;
        let upload = upload?;
        bot = owner
            .call(proto::UpdateBotProfileInput {
                bot_user_id: bot.id,
                name: None,
                photo_file_unique_id: Some(upload.file_unique_id.clone()),
            })
            .await?
            .bot
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "UpdateBotProfile returned no bot after avatar upload",
                )
            })?;
        (Some(profile_digest), Some(upload.file_unique_id))
    } else if current_avatar_is_managed {
        (
            saved
                .as_ref()
                .and_then(|saved| saved.managed_avatar_digest.clone()),
            current_photo_file_unique_id.clone(),
        )
    } else {
        (None, None)
    };
    sync_agent_command_catalog(owner, bot.id, provider.provider_id).await?;

    let stored_secret = saved.as_ref().and_then(|saved| {
        account_secrets
            .providers
            .iter()
            .find(|secret| secret.installation_id == saved.installation_id)
            .cloned()
    });
    let needs_bot_token = stored_secret
        .as_ref()
        .is_none_or(|secret| secret.bot_user_id != bot.id || secret.bot_token.trim().is_empty());
    let bot_token = if needs_bot_token {
        match created_token {
            Some(token) if !token.trim().is_empty() => token,
            _ => {
                owner
                    .call(proto::RevealBotTokenInput {
                        bot_user_id: bot.id,
                    })
                    .await?
                    .token
            }
        }
    } else {
        stored_secret
            .as_ref()
            .expect("validated stored bridge secret")
            .bot_token
            .clone()
    };
    if bot_token.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline returned an empty bridge bot token",
        )
        .into());
    }
    let credentials = ProviderCredentials {
        installation_id: saved
            .as_ref()
            .map(|saved| saved.installation_id.clone())
            .unwrap_or_else(|| new_installation_id.clone()),
        bot_user_id: bot.id,
        bot_token,
    };

    let dm_chat_id = match saved.as_ref().and_then(|saved| saved.dm_chat_id) {
        Some(chat_id) if chat_id > 0 => chat_id,
        _ => {
            let result = owner
                .call(proto::CreateChatInput {
                    title: None,
                    space_id: None,
                    description: None,
                    emoji: None,
                    is_public: false,
                    participants: vec![proto::InputChatParticipant {
                        user_id: Some(bot.id),
                        group_id: None,
                    }],
                    reserved_chat_id: None,
                    placeholder_title: None,
                })
                .await?;
            result
                .chat
                .map(|chat| chat.id)
                .filter(|chat_id| *chat_id > 0)
                .ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "CreateChat returned no chat")
                })?
        }
    };

    let provider_path = default_provider_path();
    let installation = ProviderInstallationConfig {
        installation_id: saved
            .as_ref()
            .map(|saved| saved.installation_id.clone())
            .unwrap_or_else(|| new_installation_id.clone()),
        provider_id: provider.provider_id.to_string(),
        bot_user_id: bot.id,
        bot_username: bot
            .username
            .unwrap_or_else(|| bot_username.trim_start_matches('@').to_string()),
        dm_chat_id: Some(dm_chat_id),
        workspace: workspace.to_path_buf(),
        greeting_sent: saved.as_ref().is_some_and(|saved| saved.greeting_sent),
        accept_messages_after: saved
            .as_ref()
            .map(|saved| saved.accept_messages_after)
            .filter(|timestamp| *timestamp > 0)
            .unwrap_or_else(now_seconds),
        initial_cursor_seeded: saved
            .as_ref()
            .is_some_and(|saved| saved.initial_cursor_seeded),
        display_name: bot
            .first_name
            .as_deref()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map(str::to_string)
            .unwrap_or(create_name),
        managed_avatar_digest,
        managed_avatar_file_unique_id,
        executable: provider.executable.clone(),
        provider_runtime: provider.provider_runtime.clone(),
        provider_path,
        state_dir: saved
            .as_ref()
            .map(|saved| saved.state_dir.clone())
            .unwrap_or_else(|| paths.root.join("providers").join(&new_installation_id)),
    };
    upsert_provider_identity(
        &mut account,
        &mut account_secrets,
        installation.clone(),
        credentials.clone(),
    )?;
    account_secrets.owner_auth = Some(owner.credential()?);
    account_secrets.owner_token.clear();
    account.provider_path = merged_provider_path(&account.providers, &default_provider_path());
    validate_account(&account, &account_secrets)?;
    ensure_private_dir(&installation.state_dir)?;
    let bridge_store = BridgeStore::open(&paths.provider_paths(&installation).bridge_db)?;
    let installation_id = InstallationId::new(installation.installation_id.clone())?;
    let selected_at = now_seconds();
    bridge_store.put_installation(&InstallationRecord {
        installation_id: installation_id.clone(),
        provider_id: ProviderId::new(installation.provider_id.clone())?,
        display_name: installation.display_name.clone(),
        created_at: selected_at,
        updated_at: selected_at,
    })?;
    let selected_workspace_id = workspace_id(workspace)?;
    bridge_store.select_workspace(
        &installation_id,
        &selected_workspace_id,
        workspace,
        selected_at,
    )?;
    bridge_store.bind_chat_workspace(
        &installation_id,
        dm_chat_id,
        &selected_workspace_id,
        selected_at,
    )?;
    persist_setup_account_files(&paths, &account, &account_secrets, account_preexisted)?;
    ensure_operator_user_config(&account)?;
    Ok(ProvisionedBridge {
        paths,
        account,
        secrets: account_secrets,
        installation,
        credentials,
    })
}

pub(super) fn agent_command_catalog(provider_id: &str) -> Vec<proto::BotCommand> {
    let mut commands = vec![
        ("help", "Show agent commands"),
        ("status", "Show bridge and session status"),
        ("new", "Start a fresh agent session"),
        ("clear", "Start fresh without reverting files"),
        ("compact", "Compact the current session"),
        ("folder", "Show or choose a project folder"),
        ("projects", "Show or choose a project"),
        ("follow", "Follow this chat"),
        ("unfollow", "Stop following this chat"),
        ("queue", "Queue work after the active turn"),
        ("stop", if provider_id == "codex" { "Stop and release a linked Codex session" } else { "Stop the active turn" }),
        ("model", "Show or choose the model"),
        ("reasoning", "Show or choose reasoning effort"),
        ("permissions", "Show or choose permission mode"),
        ("verbose", "Toggle detailed agent activity"),
        ("threads", "Configure Inline reply-thread routing"),
        ("allowlist", "Allow another user to drive this agent"),
    ];
    if provider_id == "codex" {
        commands.splice(
            2..2,
            [
                ("sessions", "Browse Codex sessions"),
                ("open", "Browse Codex sessions"),
                ("resume", "Resume this linked Codex session"),
                ("close", "Release Codex from Inline"),
            ],
        );
    } else if provider_id == "claude" {
        commands.splice(2..2, [("history", "Import recent local Claude history")]);
    }
    commands
        .into_iter()
        .enumerate()
        .map(|(index, (command, description))| proto::BotCommand {
            command: command.to_string(),
            description: description.to_string(),
            sort_order: i32::try_from(index).ok(),
        })
        .collect()
}

async fn sync_agent_command_catalog(
    owner: &mut crate::owner_session::OwnerSession,
    bot_user_id: i64,
    provider_id: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let commands = agent_command_catalog(provider_id);
    let result = owner
        .call(proto::SetBotCommandsInput {
            bot_user_id,
            commands: commands.clone(),
        })
        .await?;
    if result.commands != commands {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline returned a different coding-agent command catalog",
        )
        .into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_command_catalog_exposes_session_continuity() {
        let commands = agent_command_catalog("codex")
            .into_iter()
            .map(|command| command.command)
            .collect::<Vec<_>>();
        for required in ["projects", "sessions", "open", "close"] {
            assert!(commands.iter().any(|command| command == required));
        }
        assert!(!commands.iter().any(|command| command == "history"));
    }

    #[test]
    fn claude_command_catalog_exposes_projects_and_honest_history_import() {
        let commands = agent_command_catalog("claude")
            .into_iter()
            .map(|command| command.command)
            .collect::<Vec<_>>();
        for required in ["projects", "history"] {
            assert!(commands.iter().any(|command| command == required));
        }
        for unsupported in ["sessions", "open", "close"] {
            assert!(!commands.iter().any(|command| command == unsupported));
        }
    }
}
