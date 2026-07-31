//! Provider-neutral slash-command interpretation for the bridge host.

use super::*;

pub(super) enum IdleCommandResolution {
    NotCommand,
    Handled {
        message: String,
        failure: Option<String>,
        provider_epoch_ended: bool,
        choices: Option<SettingsCommandChoices>,
    },
    StartDirection {
        instruction: String,
        acknowledgement: String,
    },
}

pub(super) fn static_command_help() -> String {
    "Agent commands: /status, /new, /clear, /compact, /folder, /queue, /stop, /model, /reasoning, /permissions, /verbose, /threads, /follow, /unfollow, /allowlist <userid>.".to_string()
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn resolve_idle_command<D: AgentDriver + 'static>(
    sessions: &ProviderSessionManager<D>,
    store: &BridgeStore,
    binding: &BindingKey,
    workspace: &Path,
    settings: &SettingsRuntime<'_, D>,
    actor_user_id: i64,
    bot_username: &str,
    text: &str,
) -> IdleCommandResolution {
    let invocation = match parse_command(text, bot_username) {
        Ok(Some(invocation)) => invocation,
        Ok(None) => return IdleCommandResolution::NotCommand,
        Err(_) => return handled("I couldn’t parse that command. Try /help."),
    };
    if invocation.explicit_target && !invocation.targets_this_bot {
        return IdleCommandResolution::NotCommand;
    }
    let name = invocation.name.as_str();
    let arguments = invocation.arguments.trim();
    if actor_user_id != settings.identity.owner_user_id
        && matches!(
            name,
            "folder" | "model" | "reasoning" | "permissions" | "verbose" | "threads"
        )
    {
        return handled("Only the bot owner can change agent settings.");
    }
    if !arguments.is_empty()
        && matches!(
            name,
            "help" | "status" | "new" | "clear" | "compact" | "stop" | "follow" | "unfollow"
        )
    {
        return handled(format!("/{name} doesn’t take arguments. Try /help."));
    }
    match name {
        "help" => {
            let mut message = static_command_help();
            if let Ok(commands) = provider_commands(sessions, binding).await
                && !commands.is_empty()
            {
                let names = commands
                    .iter()
                    .take(8)
                    .map(|command| format!("/{}", command.name))
                    .collect::<Vec<_>>()
                    .join(", ");
                let remaining = commands.len().saturating_sub(8);
                message.push_str(&format!(" Provider commands: {names}"));
                if remaining > 0 {
                    message.push_str(&format!(" and {remaining} more"));
                }
                message.push('.');
            }
            handled(message)
        }
        "status" => {
            let session = match store.get_binding(binding) {
                Ok(Some(_)) => "ready",
                Ok(None) => "new on next task",
                Err(error) => return failed("I couldn’t read the current session.", error, false),
            };
            let current = match store.chat_settings(binding, now_seconds()) {
                Ok(current) => current,
                Err(error) => return failed("I couldn’t read the current settings.", error, false),
            };
            let state = if settings.turn_active {
                "running a turn"
            } else {
                "connected"
            };
            let inline_tools = match sessions.driver().capabilities().host_tools {
                HostToolTransport::Native | HostToolTransport::Mcp => "available",
                HostToolTransport::Unsupported => "unavailable for this provider",
            };
            let reply_threads = match resolve_reply_thread_policy(
                store,
                &binding.installation_id,
                &settings.identity.bot_store,
                settings.identity.reply_thread_default,
                binding.chat_id,
            )
            .await
            {
                Ok(policy) => format!("{} ({})", policy.mode.as_str(), policy.source.label()),
                Err(_) => "unavailable".to_string(),
            };
            handled(format!(
                "Agent is {state}. Host: {}. Project: {}. Session: {session}. Model: {}. Reasoning: {}. Permissions: {}. Verbose: {}. Reply in threads: {reply_threads}. Inline tools: {inline_tools}.",
                settings.identity.host_label,
                workspace_label(workspace),
                current.model.as_deref().unwrap_or("provider default"),
                current.reasoning.as_deref().unwrap_or("provider default"),
                current.permissions.as_deref().unwrap_or("provider default"),
                if current.verbose { "on" } else { "off" },
            ))
        }
        "new" | "clear" if settings.turn_active => {
            handled("Wait for the current turn to finish, or stop it first.")
        }
        "new" | "clear" => match sessions.rotate_session(binding, now_seconds()).await {
            Ok(_) if name == "clear" => handled(format!(
                "Started a fresh agent session. Inline history and project files were not changed.\n\n{}",
                working_directory_message(workspace)
            )),
            Ok(_) => handled(format!(
                "Started a fresh agent session. Project files were not changed.\n\n{}",
                working_directory_message(workspace)
            )),
            Err(error) => {
                let fatal = session_error_ends_epoch(&error);
                failed("I couldn’t start a fresh agent session.", error, fatal)
            }
        },
        "compact" if settings.turn_active => {
            handled("Wait for the current turn to finish, or stop it first.")
        }
        "compact" => {
            if !sessions.driver().capabilities().compact_session {
                return handled(BridgeNotice::SessionCompactionUnsupported.message());
            }
            let session_open = match sessions.ensure_session(binding, now_seconds()).await {
                Ok(session) => session,
                Err(error) => {
                    let fatal = session_error_ends_epoch(&error);
                    return failed("I couldn’t open the current agent session.", error, fatal);
                }
            };
            if let Some(notice) = session_open_notice(&session_open) {
                return handled(notice.message());
            }
            match sessions
                .driver()
                .compact_session(session_open.session_id())
                .await
            {
                Ok(()) => handled("Compacted the current agent session."),
                Err(error) => {
                    let fatal = matches!(&error, DriverError::ProcessExited(_));
                    failed(
                        "I couldn’t compact the current agent session.",
                        error,
                        fatal,
                    )
                }
            }
        }
        "queue" if arguments.is_empty() => handled("Usage: /queue <instruction>"),
        "queue" => IdleCommandResolution::StartDirection {
            instruction: arguments.to_string(),
            acknowledgement: "Nothing was running, so I started it now.".to_string(),
        },
        "stop" => handled("Nothing is running."),
        "folder" | "model" | "reasoning" | "permissions" | "verbose" => {
            let result = resolve_settings_command(settings, name, arguments).await;
            IdleCommandResolution::Handled {
                message: result.message,
                failure: result.failure,
                provider_epoch_ended: result.provider_epoch_ended,
                choices: result.choices,
            }
        }
        "threads" => {
            let result = resolve_reply_threads_command(settings, arguments).await;
            IdleCommandResolution::Handled {
                message: result.message,
                failure: result.failure,
                provider_epoch_ended: result.provider_epoch_ended,
                choices: result.choices,
            }
        }
        "follow" | "unfollow" => {
            handled("Follow controls will be available when this bot is added to shared chats.")
        }
        "allowlist" => handled("Use /allowlist <userid> to choose a user to allow."),
        "" => handled("I couldn’t parse that command. Try /help."),
        _ => match provider_commands(sessions, binding).await {
            Ok(commands) => {
                let Some(command) = commands.iter().find(|command| command.name == name) else {
                    return handled("Unknown command. Try /help.");
                };
                let canonical_arguments = match command.input_shape() {
                    inline_agent_bridge::DriverCommandInput::None => {
                        if !arguments.is_empty() {
                            return handled(format!("/{name} doesn’t take arguments. Try /help."));
                        }
                        String::new()
                    }
                    inline_agent_bridge::DriverCommandInput::Freeform { hint, required } => {
                        if required && arguments.is_empty() {
                            return handled(format!("Usage: /{name} <{hint}>"));
                        }
                        arguments.to_string()
                    }
                    inline_agent_bridge::DriverCommandInput::SingleChoice { options, .. } => {
                        if arguments.is_empty() {
                            let Some(choices) =
                                provider_command_choices(settings, command, actor_user_id)
                            else {
                                return handled("No choices are currently available.");
                            };
                            return IdleCommandResolution::Handled {
                                message: format!("Choose an option for /{name}."),
                                failure: None,
                                provider_epoch_ended: false,
                                choices: Some(choices),
                            };
                        }
                        let matches = options
                            .iter()
                            .filter(|option| {
                                !option.disabled
                                    && (option.value == arguments
                                        || option.label.eq_ignore_ascii_case(arguments))
                            })
                            .collect::<Vec<_>>();
                        match matches.as_slice() {
                            [option] => option.value.clone(),
                            [] => {
                                return handled(format!(
                                    "That /{name} choice is not available. Run /{name} again."
                                ));
                            }
                            _ => {
                                return handled(format!(
                                    "That /{name} choice is ambiguous. Use its exact value."
                                ));
                            }
                        }
                    }
                };
                IdleCommandResolution::StartDirection {
                    instruction: if canonical_arguments.is_empty() {
                        format!("/{name}")
                    } else {
                        format!("/{name} {canonical_arguments}")
                    },
                    acknowledgement: format!("Sent /{name} to the agent."),
                }
            }
            Err(error) => {
                let fatal = session_error_ends_epoch(&error);
                failed(
                    "I couldn’t read the provider command catalog.",
                    error,
                    fatal,
                )
            }
        },
    }
}

pub(super) async fn provider_commands<D: AgentDriver + 'static>(
    sessions: &ProviderSessionManager<D>,
    binding: &BindingKey,
) -> Result<Vec<inline_agent_bridge::DriverCommand>, SessionManagerError> {
    if !sessions.driver().capabilities().session_commands {
        return Ok(Vec::new());
    }
    let session = sessions.ensure_session(binding, now_seconds()).await?;
    Ok(sessions
        .driver()
        .session_commands(session.session_id())
        .await?)
}

fn handled(message: impl Into<String>) -> IdleCommandResolution {
    IdleCommandResolution::Handled {
        message: message.into(),
        failure: None,
        provider_epoch_ended: false,
        choices: None,
    }
}

fn failed(
    message: &str,
    error: impl std::fmt::Display,
    provider_epoch_ended: bool,
) -> IdleCommandResolution {
    IdleCommandResolution::Handled {
        message: message.to_string(),
        failure: Some(safe_diagnostic(&error.to_string())),
        provider_epoch_ended,
        choices: None,
    }
}

fn session_error_ends_epoch(error: &SessionManagerError) -> bool {
    matches!(
        error,
        SessionManagerError::Driver(DriverError::ProcessExited(_))
    )
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex as StdMutex};

    use inline_agent_bridge::{
        AgentEventReceiver, ApprovalDecision, DriverCapabilities, DriverError, DriverFuture,
        DriverModelOption, DriverSettingOption, DriverSettingsCatalog, ProviderSessionId,
        ResumeSessionSpec, SessionSpec, StartedTurn, SteeringSupport, TurnId,
    };

    use super::*;

    #[test]
    fn only_connection_epoch_loss_is_a_fatal_session_command_error() {
        assert!(session_error_ends_epoch(&SessionManagerError::Driver(
            DriverError::ProcessExited("epoch ended".to_string())
        )));
        assert!(!session_error_ends_epoch(&SessionManagerError::Driver(
            DriverError::Transient("retryable".to_string())
        )));
    }

    #[derive(Debug, Default)]
    struct FakeDriver {
        starts: StdMutex<Vec<PathBuf>>,
        compactions: StdMutex<Vec<ProviderSessionId>>,
        commands: Vec<inline_agent_bridge::DriverCommand>,
        compact_session: bool,
        resume_session: bool,
    }

    impl AgentDriver for FakeDriver {
        fn capabilities(&self) -> DriverCapabilities {
            DriverCapabilities {
                resume_session: self.resume_session,
                compact_session: self.compact_session,
                settings_catalog: true,
                session_commands: !self.commands.is_empty(),
                steering: SteeringSupport::Native,
                ..DriverCapabilities::default()
            }
        }

        fn settings_catalog<'a>(
            &'a self,
            _cwd: &'a Path,
        ) -> DriverFuture<'a, DriverSettingsCatalog> {
            Box::pin(async {
                Ok(DriverSettingsCatalog {
                    models: vec![DriverModelOption {
                        value: "gpt-test".to_string(),
                        label: "GPT Test".to_string(),
                        description: None,
                        reasoning: vec![DriverSettingOption {
                            value: "high".to_string(),
                            label: "High".to_string(),
                            description: None,
                            disabled: false,
                        }],
                        default_reasoning: Some("high".to_string()),
                        is_default: true,
                    }],
                    permissions: vec![DriverSettingOption {
                        value: "workspace".to_string(),
                        label: "Workspace".to_string(),
                        description: None,
                        disabled: false,
                    }],
                })
            })
        }

        fn session_commands<'a>(
            &'a self,
            _session_id: &'a ProviderSessionId,
        ) -> DriverFuture<'a, Vec<inline_agent_bridge::DriverCommand>> {
            Box::pin(async { Ok(self.commands.clone()) })
        }

        fn start_session<'a>(&'a self, spec: SessionSpec) -> DriverFuture<'a, ProviderSessionId> {
            Box::pin(async move {
                let mut starts = self.starts.lock().expect("starts");
                starts.push(spec.cwd);
                ProviderSessionId::new(format!("session-{}", starts.len()))
                    .map_err(|error| DriverError::Protocol(error.to_string()))
            })
        }

        fn resume_session<'a>(&'a self, _spec: ResumeSessionSpec) -> DriverFuture<'a, ()> {
            Box::pin(async { Ok(()) })
        }

        fn start_turn<'a>(
            &'a self,
            _session_id: &'a ProviderSessionId,
            _input: TurnInput,
            _options: TurnOptions,
        ) -> DriverFuture<'a, StartedTurn> {
            Box::pin(async {
                let (_sender, events) = AgentEventReceiver::default_channel();
                Ok(StartedTurn {
                    turn_id: TurnId::new("turn-1")
                        .map_err(|error| DriverError::Protocol(error.to_string()))?,
                    events,
                })
            })
        }

        fn steer_turn<'a>(
            &'a self,
            _session_id: &'a ProviderSessionId,
            _turn_id: &'a TurnId,
            _input: TurnInput,
        ) -> DriverFuture<'a, ()> {
            Box::pin(async { Ok(()) })
        }

        fn cancel_turn<'a>(
            &'a self,
            _session_id: &'a ProviderSessionId,
            _turn_id: &'a TurnId,
        ) -> DriverFuture<'a, ()> {
            Box::pin(async { Ok(()) })
        }

        fn compact_session<'a>(
            &'a self,
            session_id: &'a ProviderSessionId,
        ) -> DriverFuture<'a, ()> {
            Box::pin(async move {
                self.compactions
                    .lock()
                    .expect("compactions")
                    .push(session_id.clone());
                Ok(())
            })
        }

        fn resolve_approval<'a>(
            &'a self,
            _approval_id: &'a str,
            _decision: ApprovalDecision,
        ) -> DriverFuture<'a, ()> {
            Box::pin(async { Ok(()) })
        }

        fn shutdown<'a>(&'a self) -> DriverFuture<'a, ()> {
            Box::pin(async { Ok(()) })
        }
    }

    fn fixture(
        compact_session: bool,
    ) -> (
        tempfile::TempDir,
        Arc<FakeDriver>,
        Arc<BridgeStore>,
        ProviderSessionManager<FakeDriver>,
        BindingKey,
        PathBuf,
    ) {
        fixture_with_session_capabilities(compact_session, true)
    }

    fn fixture_with_session_capabilities(
        compact_session: bool,
        resume_session: bool,
    ) -> (
        tempfile::TempDir,
        Arc<FakeDriver>,
        Arc<BridgeStore>,
        ProviderSessionManager<FakeDriver>,
        BindingKey,
        PathBuf,
    ) {
        let directory = tempfile::tempdir().expect("tempdir");
        let store =
            Arc::new(BridgeStore::open(directory.path().join("bridge.sqlite3")).expect("store"));
        let driver = Arc::new(FakeDriver {
            compact_session,
            resume_session,
            ..FakeDriver::default()
        });
        let manager = ProviderSessionManager::new(
            Arc::clone(&driver),
            Arc::clone(&store),
            ProviderId::new("codex").expect("provider"),
        );
        let binding = BindingKey {
            installation_id: InstallationId::new("codex").expect("installation"),
            chat_id: 706,
            workspace_id: WorkspaceId::new("workspace").expect("workspace"),
        };
        let workspace = directory.path().join("project");
        std::fs::create_dir(&workspace).expect("workspace");
        let installation_id = InstallationId::new("codex").expect("installation");
        store
            .put_installation(&InstallationRecord {
                installation_id: installation_id.clone(),
                provider_id: ProviderId::new("codex").expect("provider"),
                display_name: "Codex".to_string(),
                created_at: 1,
                updated_at: 1,
            })
            .expect("installation");
        store
            .select_workspace(&installation_id, &binding.workspace_id, &workspace, 1)
            .expect("workspace registration");
        (directory, driver, store, manager, binding, workspace)
    }

    fn settings_fixture(
        binding: &BindingKey,
        workspace: &Path,
    ) -> (ActiveConversation, SettingsIdentity) {
        (
            ActiveConversation::new(binding.clone(), workspace.to_path_buf()),
            SettingsIdentity {
                owner_user_id: 1,
                owner_dm_chat_id: 3,
                bot_user_id: 2,
                host_installation_id: "host-test".to_string(),
                host_label: "Test Mac".to_string(),
                workspace_picker: None,
                bot_store: SqliteStore::open_in_memory().expect("bot store"),
                reply_thread_default: ReplyThreadDefault {
                    mode: ReplyThreadMode::Auto,
                    source: ReplyThreadDefaultSource::BuiltIn,
                },
            },
        )
    }

    #[tokio::test]
    async fn queue_without_active_turn_starts_the_instruction() {
        let (_directory, _driver, store, manager, binding, workspace) = fixture(false);
        let (active, identity) = settings_fixture(&binding, &workspace);
        let resolution = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &SettingsRuntime {
                sessions: &manager,
                store: &store,
                active: &active,
                identity: &identity,
                turn_active: false,
            },
            identity.owner_user_id,
            "mo_codex_bot",
            "/queue fix the tests",
        )
        .await;

        match resolution {
            IdleCommandResolution::StartDirection {
                instruction,
                acknowledgement,
            } => {
                assert_eq!(instruction, "fix the tests");
                assert_eq!(acknowledgement, "Nothing was running, so I started it now.");
            }
            _ => panic!("expected queued direction to start"),
        }
    }

    #[tokio::test]
    async fn threads_is_owner_only_and_offers_buttons_with_typed_compatibility() {
        let (_directory, _driver, store, manager, binding, workspace) = fixture(false);
        let (active, identity) = settings_fixture(&binding, &workspace);
        let runtime = SettingsRuntime {
            sessions: &manager,
            store: &store,
            active: &active,
            identity: &identity,
            turn_active: false,
        };

        let rejected = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            99,
            "mo_codex_bot",
            "/threads on",
        )
        .await;
        let IdleCommandResolution::Handled { message, .. } = rejected else {
            panic!("expected owner rejection");
        };
        assert_eq!(message, "Only the bot owner can change agent settings.");

        let prompt = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            identity.owner_user_id,
            "mo_codex_bot",
            "/threads",
        )
        .await;
        let IdleCommandResolution::Handled {
            choices: Some(choices),
            failure: None,
            ..
        } = prompt
        else {
            panic!("expected reply-thread choices");
        };
        assert_eq!(choices.item_id, ITEM_REPLY_THREADS);
        assert_eq!(
            choices
                .options
                .iter()
                .map(|option| option.value.as_str())
                .collect::<Vec<_>>(),
            ["auto", "on", "off"]
        );

        let applied = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            identity.owner_user_id,
            "mo_codex_bot",
            "/threads off",
        )
        .await;
        let IdleCommandResolution::Handled { message, .. } = applied else {
            panic!("expected reply-thread update");
        };
        assert!(message.contains("off for this chat (chat override)"));
        assert_eq!(
            store
                .reply_thread_override(&binding.installation_id, binding.chat_id)
                .expect("override")
                .expect("stored override")
                .mode,
            ReplyThreadMode::Off
        );
    }

    #[tokio::test]
    async fn provider_commands_are_discovered_per_session_without_static_registration() {
        let (_directory, _driver, store, _manager, binding, workspace) = fixture(false);
        let command = inline_agent_bridge::DriverCommand::new(
            "research_codebase",
            "Research the selected project",
            Some("topic"),
        )
        .expect("command");
        let driver = Arc::new(FakeDriver {
            commands: vec![command],
            resume_session: true,
            ..FakeDriver::default()
        });
        let manager = ProviderSessionManager::new(
            Arc::clone(&driver),
            Arc::clone(&store),
            ProviderId::new("acp").expect("provider"),
        );
        let (active, identity) = settings_fixture(&binding, &workspace);
        let runtime = SettingsRuntime {
            sessions: &manager,
            store: &store,
            active: &active,
            identity: &identity,
            turn_active: false,
        };

        let help = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            identity.owner_user_id,
            "mo_acp_bot",
            "/help",
        )
        .await;
        let IdleCommandResolution::Handled {
            message, failure, ..
        } = help
        else {
            panic!("expected help response");
        };
        assert!(message.contains("/research_codebase"));
        assert!(failure.is_none());

        let invocation = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            identity.owner_user_id,
            "mo_acp_bot",
            "/research_codebase bridge lifecycle",
        )
        .await;
        let IdleCommandResolution::StartDirection {
            instruction,
            acknowledgement,
        } = invocation
        else {
            panic!("expected provider direction");
        };
        assert_eq!(instruction, "/research_codebase bridge lifecycle");
        assert_eq!(acknowledgement, "Sent /research_codebase to the agent.");
    }

    #[tokio::test]
    async fn provider_single_choice_commands_render_buttons_and_keep_typed_compatibility() {
        let (_directory, _driver, store, _manager, binding, workspace) = fixture(false);
        let command =
            inline_agent_bridge::DriverCommand::new("review_mode", "Choose a review mode", None)
                .expect("command")
                .with_single_choice(
                    [
                        inline_agent_bridge::DriverCommandChoice::new("safe", "Safe")
                            .expect("choice"),
                        inline_agent_bridge::DriverCommandChoice::new("fast", "Fast")
                            .expect("choice"),
                    ],
                    false,
                    Some("catalog-1"),
                )
                .expect("single choice");
        let driver = Arc::new(FakeDriver {
            commands: vec![command],
            resume_session: true,
            ..FakeDriver::default()
        });
        let manager = ProviderSessionManager::new(
            Arc::clone(&driver),
            Arc::clone(&store),
            ProviderId::new("acp").expect("provider"),
        );
        let (active, identity) = settings_fixture(&binding, &workspace);
        let runtime = SettingsRuntime {
            sessions: &manager,
            store: &store,
            active: &active,
            identity: &identity,
            turn_active: false,
        };

        let prompt = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            identity.owner_user_id,
            "mo_acp_bot",
            "/review_mode",
        )
        .await;
        let IdleCommandResolution::Handled {
            choices: Some(choices),
            failure: None,
            ..
        } = prompt
        else {
            panic!("expected provider choice card");
        };
        assert_eq!(choices.item_id, "provider.command:review_mode");
        assert_eq!(
            choices
                .options
                .iter()
                .map(|option| option.value.as_str())
                .collect::<Vec<_>>(),
            ["safe", "fast"]
        );

        let typed = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            identity.owner_user_id,
            "mo_acp_bot",
            "/review_mode Fast",
        )
        .await;
        let IdleCommandResolution::StartDirection { instruction, .. } = typed else {
            panic!("expected typed provider direction");
        };
        assert_eq!(instruction, "/review_mode fast");
    }

    #[tokio::test]
    async fn new_rotates_the_binding_and_compact_is_capability_gated() {
        let (_directory, driver, store, manager, binding, workspace) = fixture(false);
        let (active, identity) = settings_fixture(&binding, &workspace);
        let resolution = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &SettingsRuntime {
                sessions: &manager,
                store: &store,
                active: &active,
                identity: &identity,
                turn_active: false,
            },
            identity.owner_user_id,
            "mo_codex_bot",
            "/new",
        )
        .await;
        assert!(matches!(
            resolution,
            IdleCommandResolution::Handled { failure: None, .. }
        ));
        assert_eq!(driver.starts.lock().expect("starts").len(), 1);
        let (_, persisted) = store
            .get_binding(&binding)
            .expect("binding lookup")
            .expect("binding");
        assert_eq!(persisted.as_str(), "session-1");

        let resolution = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &SettingsRuntime {
                sessions: &manager,
                store: &store,
                active: &active,
                identity: &identity,
                turn_active: false,
            },
            identity.owner_user_id,
            "mo_codex_bot",
            "/compact",
        )
        .await;
        match resolution {
            IdleCommandResolution::Handled {
                message, failure, ..
            } => {
                assert!(message.contains("doesn’t support"));
                assert!(failure.is_none());
            }
            _ => panic!("expected capability response"),
        }
        assert!(driver.compactions.lock().expect("compactions").is_empty());
    }

    #[tokio::test]
    async fn active_turn_controls_respond_now_and_match_toolbar_timing() {
        let (_directory, driver, store, manager, binding, workspace) = fixture(false);
        let (active, identity) = settings_fixture(&binding, &workspace);
        let runtime = SettingsRuntime {
            sessions: &manager,
            store: &store,
            active: &active,
            identity: &identity,
            turn_active: true,
        };

        let status = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            identity.owner_user_id,
            "mo_codex_bot",
            "/status",
        )
        .await;
        let IdleCommandResolution::Handled {
            message, failure, ..
        } = status
        else {
            panic!("expected active status response");
        };
        assert!(failure.is_none());
        assert!(message.contains("running a turn"));
        assert!(message.contains(&identity.host_label));
        assert!(message.contains("Model: provider default"));

        let model = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            identity.owner_user_id,
            "mo_codex_bot",
            "/model gpt-test",
        )
        .await;
        assert!(matches!(
            model,
            IdleCommandResolution::Handled { failure: None, .. }
        ));
        assert_eq!(
            store
                .chat_settings(&binding, 9)
                .expect("settings")
                .model
                .as_deref(),
            Some("gpt-test")
        );

        let new_session = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            identity.owner_user_id,
            "mo_codex_bot",
            "/new",
        )
        .await;
        let IdleCommandResolution::Handled {
            message, failure, ..
        } = new_session
        else {
            panic!("expected active-turn session response");
        };
        assert!(message.contains("current turn"));
        assert!(failure.is_none());
        assert!(driver.starts.lock().expect("starts").is_empty());
    }

    #[tokio::test]
    async fn compact_reports_automatic_session_replacement_once() {
        let (_directory, driver, store, manager, binding, workspace) =
            fixture_with_session_capabilities(true, false);
        store
            .put_binding(
                &binding,
                &ProviderId::new("codex").expect("provider"),
                &ProviderSessionId::new("session-old").expect("session"),
                1,
            )
            .expect("binding");
        let (active, identity) = settings_fixture(&binding, &workspace);

        let resolution = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &SettingsRuntime {
                sessions: &manager,
                store: &store,
                active: &active,
                identity: &identity,
                turn_active: false,
            },
            identity.owner_user_id,
            "mo_codex_bot",
            "/compact",
        )
        .await;

        let IdleCommandResolution::Handled {
            message, failure, ..
        } = resolution
        else {
            panic!("expected replacement response");
        };
        assert_eq!(message, BridgeNotice::SessionReplaced.message());
        assert!(failure.is_none());
        assert_eq!(driver.starts.lock().expect("starts").len(), 1);
        assert!(driver.compactions.lock().expect("compactions").is_empty());
    }

    #[tokio::test]
    async fn targeted_other_bot_command_is_not_interpreted_by_this_bot() {
        let (_directory, _driver, store, manager, binding, workspace) = fixture(false);
        let (active, identity) = settings_fixture(&binding, &workspace);
        let resolution = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &SettingsRuntime {
                sessions: &manager,
                store: &store,
                active: &active,
                identity: &identity,
                turn_active: false,
            },
            identity.owner_user_id,
            "mo_codex_bot",
            "/status@someone_else",
        )
        .await;

        assert!(matches!(resolution, IdleCommandResolution::NotCommand));
    }

    #[tokio::test]
    async fn settings_commands_share_toolbar_state_and_validation() {
        let (_directory, _driver, store, manager, binding, workspace) = fixture(false);
        let (active, identity) = settings_fixture(&binding, &workspace);
        let runtime = SettingsRuntime {
            sessions: &manager,
            store: &store,
            active: &active,
            identity: &identity,
            turn_active: false,
        };

        let result = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            identity.owner_user_id,
            "mo_codex_bot",
            "/model",
        )
        .await;
        let IdleCommandResolution::Handled {
            choices: Some(choices),
            ..
        } = result
        else {
            panic!("expected interactive model choices");
        };
        assert_eq!(choices.item_id, "agent.model");
        assert_eq!(
            choices
                .options
                .iter()
                .map(|choice| choice.label.as_str())
                .collect::<Vec<_>>(),
            vec!["Provider default", "GPT Test"]
        );

        for command in [
            "/model gpt-test",
            "/reasoning high",
            "/permissions workspace",
            "/verbose on",
        ] {
            let result = resolve_idle_command(
                &manager,
                &store,
                &binding,
                &workspace,
                &runtime,
                identity.owner_user_id,
                "mo_codex_bot",
                command,
            )
            .await;
            assert!(matches!(
                result,
                IdleCommandResolution::Handled { failure: None, .. }
            ));
        }

        let settings = store.chat_settings(&binding, 9).expect("settings");
        assert_eq!(settings.model.as_deref(), Some("gpt-test"));
        assert_eq!(settings.reasoning.as_deref(), Some("high"));
        assert_eq!(settings.permissions.as_deref(), Some("workspace"));
        assert!(settings.verbose);

        let result = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            identity.owner_user_id,
            "mo_codex_bot",
            "/verbose",
        )
        .await;
        let IdleCommandResolution::Handled { message, .. } = result else {
            panic!("expected verbose toggle response");
        };
        assert_eq!(message, "Verbose is now off.");
        assert!(!store.chat_settings(&binding, 10).expect("settings").verbose);

        let result = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            identity.owner_user_id,
            "mo_codex_bot",
            "/model retired",
        )
        .await;
        let IdleCommandResolution::Handled {
            message, failure, ..
        } = result
        else {
            panic!("expected validation response");
        };
        assert!(message.contains("not available"));
        assert!(failure.is_none());
    }

    #[tokio::test]
    async fn delegated_operators_cannot_read_or_mutate_owner_settings() {
        let (_directory, _driver, store, manager, binding, workspace) = fixture(false);
        let (active, identity) = settings_fixture(&binding, &workspace);
        let runtime = SettingsRuntime {
            sessions: &manager,
            store: &store,
            active: &active,
            identity: &identity,
            turn_active: false,
        };
        let result = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            99,
            "mo_codex_bot",
            "/model gpt-test",
        )
        .await;
        let IdleCommandResolution::Handled {
            message, failure, ..
        } = result
        else {
            panic!("expected owner-only response");
        };
        assert_eq!(message, "Only the bot owner can change agent settings.");
        assert!(failure.is_none());
        assert!(
            store
                .chat_settings(&binding, 10)
                .expect("settings")
                .model
                .is_none()
        );
    }
}
