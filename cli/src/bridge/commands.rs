//! Provider-neutral slash-command interpretation for the bridge host.

use super::*;

pub(super) enum IdleCommandResolution {
    NotCommand,
    StartCompaction,
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

pub(super) fn static_command_help(provider_id: &ProviderId) -> String {
    let provider_commands = match provider_id.as_str() {
        "codex" => ", /sessions, /open, /resume, /close",
        "claude" => ", /history",
        _ => "",
    };
    format!(
        "Agent commands: /status{provider_commands}, /new, /clear, /compact, /projects, /folder, /queue, /stop, /model, /reasoning, /permissions, /verbose, /threads, /follow, /unfollow, /allowlist <userid>."
    )
}

pub(super) fn is_provider_epoch_release_command(text: &str, bot_username: &str) -> bool {
    let Ok(Some(command)) = parse_command(text, bot_username) else {
        return false;
    };
    matches!(command.name.as_str(), "close" | "stop")
        && command.arguments.trim().is_empty()
        && (!command.explicit_target || command.targets_this_bot)
}

pub(super) fn is_linked_codex_stop(
    route: &InboundRoute,
    record: &InboundRecord,
) -> Result<bool, StoreError> {
    Ok(route.provider_id.as_str() == "codex"
        && record.sender_user_id == route.owner_user_id
        && matches!(parse_command(&record.direction.text, &route.bot_username),
            Ok(Some(command)) if command.name == "stop"
                && command.arguments.trim().is_empty()
                && (!command.explicit_target || command.targets_this_bot))
        && route
            .store
            .session_thread_binding_for_chat(
                &record.binding.installation_id,
                record.binding.chat_id,
            )?
            .is_some())
}

pub(super) fn is_workspace_recovery_command(text: &str, bot_username: &str) -> bool {
    let Ok(Some(command)) = parse_command(text, bot_username) else {
        return false;
    };
    matches!(command.name.as_str(), "folder" | "projects")
        && (!command.explicit_target || command.targets_this_bot)
}

fn unsupported_close_message(provider_id: &str) -> Option<&'static str> {
    (provider_id != "codex")
        .then_some("This provider does not support /close. Use /new to start a fresh session.")
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
    if name == "close"
        && let Some(message) = unsupported_close_message(sessions.provider_id().as_str())
    {
        return handled(message);
    }
    if actor_user_id != settings.identity.owner_user_id && name == "close" {
        return handled("Only the bot owner can release the provider connection.");
    }
    if actor_user_id != settings.identity.owner_user_id
        && matches!(
            name,
            "folder" | "projects" | "model" | "reasoning" | "permissions" | "verbose" | "threads"
        )
    {
        return handled("Only the bot owner can change agent settings.");
    }
    if !arguments.is_empty()
        && matches!(
            name,
            "help"
                | "status"
                | "new"
                | "clear"
                | "compact"
                | "close"
                | "stop"
                | "follow"
                | "unfollow"
        )
    {
        return handled(format!("/{name} doesn’t take arguments. Try /help."));
    }
    let linked_codex_session = if sessions.provider_id().as_str() == "codex" {
        match store.session_thread_binding_for_chat(&binding.installation_id, binding.chat_id) {
            Ok(linked) => linked.is_some(),
            Err(error) => return failed("I couldn’t read this session thread.", error, false),
        }
    } else {
        false
    };
    let needs_resume = linked_codex_session && !sessions.session_history_is_ready(binding).await;
    match name {
        "help" => {
            let mut message = static_command_help(sessions.provider_id());
            if !needs_resume
                && let Ok(commands) = provider_commands(sessions, binding).await
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
            let session_active = sessions.session_is_active(binding).await;
            let session = match store.get_binding(binding) {
                Ok(Some(_)) if session_active => "owned by Inline",
                Ok(Some(_)) => "opened; Inline acquires on next task",
                Ok(None) => "new on next task",
                Err(error) => return failed("I couldn’t read the current session.", error, false),
            };
            let current = match store.chat_settings(binding, now_seconds()) {
                Ok(current) => current,
                Err(error) => return failed("I couldn’t read the current settings.", error, false),
            };
            let state = if settings.turn_active {
                "running a turn"
            } else if session_active {
                "connected"
            } else {
                "idle"
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
            let settings_catalog = if settings.turn_active {
                // A cancelled provider read can close its connection epoch.
                // Status must never put a running turn at risk.
                None
            } else {
                match tokio::time::timeout(
                    SETTINGS_DEADLINE,
                    sessions.settings_catalog(binding, now_seconds()),
                )
                .await
                {
                    Ok(Ok(catalog)) => Some(catalog),
                    Ok(Err(error)) if session_error_ends_epoch(&error) => {
                        return failed(
                            "I couldn’t load the current permission settings.",
                            error,
                            true,
                        );
                    }
                    Ok(Err(_)) | Err(_) => None,
                }
            };
            let model = model_selection_label(current.model.as_deref(), settings_catalog.as_ref());
            let permissions = permission_selection_label(
                current.permissions.as_deref(),
                settings_catalog.as_ref(),
            );
            let mut message = format!(
                "Agent is {state}. Host: {}. Project: {}. Session: {session}. Model: {}. Reasoning: {}. Permissions: {}. Verbose: {}. Reply in threads: {reply_threads}. Inline tools: {inline_tools}.",
                settings.identity.host_label,
                workspace_label(workspace),
                model,
                current.reasoning.as_deref().unwrap_or("provider default"),
                permissions,
                if current.verbose { "on" } else { "off" },
            );
            if sessions.driver().capabilities().usage_limits {
                // Status shares the active control lane with /stop. Give this
                // optional read only a small slice of that lane while running.
                let deadline = if settings.turn_active {
                    Duration::from_millis(250)
                } else {
                    SETTINGS_DEADLINE
                };
                let usage = tokio::time::timeout(deadline, sessions.driver().usage_limits()).await;
                message.push_str("\n\n");
                message.push_str(&match usage {
                    Ok(Ok(windows)) => usage_status_text(&windows),
                    Ok(Err(error)) => super::copy::failure_with_diagnostic(
                        "Provider usage is unavailable.",
                        Some(&error.to_string()),
                    ),
                    Err(_) => {
                        "Provider usage is unavailable; the status request timed out.".to_string()
                    }
                });
            }
            handled(message)
        }
        "new" | "clear" if settings.turn_active => {
            handled("Wait for the current turn to finish, or stop it first.")
        }
        "new" | "clear"
            if matches!(
                store.session_thread_binding_for_chat(&binding.installation_id, binding.chat_id),
                Ok(Some(_))
            ) =>
        {
            handled(
                "This thread is pinned to its Codex session. Use /sessions in the bot DM to open another session.",
            )
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
        "close" | "stop" if settings.turn_active => {
            handled("Wait for the current turn to finish, or stop it first.")
        }
        "close" | "stop" if name == "close" || linked_codex_session => {
            if actor_user_id != settings.identity.owner_user_id {
                return handled("Only the bot owner can release the provider connection.");
            }
            let session_thread = match store
                .session_thread_binding_for_chat(&binding.installation_id, binding.chat_id)
            {
                Ok(session_thread) => session_thread,
                Err(error) => {
                    return failed("I couldn’t read this session thread.", error, false);
                }
            };
            if session_thread.is_none() {
                return handled(
                    "This conversation is not an opened provider session. Use /sessions in the bot DM first.",
                );
            }
            match sessions.shutdown_epoch_if_idle().await {
                Ok(false) => handled(
                    "Another Inline Codex operation is still in progress, so this session has not been released. Wait for it to finish, then use /stop again. Other tasks were not interrupted.",
                ),
                Ok(true) => IdleCommandResolution::Handled {
                    message: "Released from Inline. Continue this same session in ChatGPT Desktop or Codex CLI. If Codex says it is still closing, retry in a moment. When you’re ready to return, close the session there and use /resume here.".to_string(),
                    failure: None,
                    provider_epoch_ended: true,
                    choices: None,
                },
                Err(error) => {
                    failed(
                        "I couldn’t confirm that Codex released Inline’s connection.",
                        error,
                        true,
                    )
                }
            }
        }
        "compact" if settings.turn_active => {
            handled("Wait for the current turn to finish, or stop it first.")
        }
        "compact" if needs_resume => {
            handled("Use /resume to sync recent history before compacting this session.")
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
            IdleCommandResolution::StartCompaction
        }
        "queue" if arguments.is_empty() => handled("Usage: /queue <instruction>"),
        "queue" => IdleCommandResolution::StartDirection {
            instruction: arguments.to_string(),
            acknowledgement: "Nothing was running, so I started it now.".to_string(),
        },
        "stop" => handled("Nothing is running."),
        "folder" | "projects" | "model" | "reasoning" | "permissions" | "verbose" => {
            let settings_name = if name == "projects" { "folder" } else { name };
            let mut result = resolve_settings_command(settings, settings_name, arguments).await;
            if name == "projects" {
                result.message = result.message.replace("`/folder", "`/projects");
            }
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
        _ if needs_resume => {
            handled("Use /resume to sync recent history before sending provider commands.")
        }
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
        message: super::copy::failure_with_diagnostic(message, Some(&error.to_string())),
        failure: Some(safe_diagnostic(&error.to_string())),
        provider_epoch_ended,
        choices: None,
    }
}

fn usage_status_text(windows: &[inline_agent_bridge::DriverUsageWindow]) -> String {
    if windows.is_empty() {
        return "Provider usage is unavailable.".to_string();
    }
    windows
        .iter()
        .take(16)
        .map(|window| {
            let label =
                safe_chat_diagnostic(&window.label).unwrap_or_else(|| "Provider".to_string());
            let duration = match window.window_minutes {
                Some(10_080) => "weekly".to_string(),
                Some(minutes) if minutes % 60 == 0 => format!("{}-hour", minutes / 60),
                Some(minutes) => format!("{minutes}-minute"),
                None => "usage".to_string(),
            };
            let remaining = 100_u8.saturating_sub(window.used_percent);
            let reset = window
                .resets_at
                .and_then(|seconds| chrono::DateTime::from_timestamp(seconds, 0))
                .map(|time| format!("resets {}", time.format("%b %-d at %H:%M UTC")))
                .unwrap_or_else(|| "reset time unavailable".to_string());
            format!(
                "{label} {duration}: {remaining}% remaining{}; {reset}.",
                if remaining == 0 {
                    " (limit reached)"
                } else {
                    ""
                }
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn session_error_ends_epoch(error: &SessionManagerError) -> bool {
    matches!(error, SessionManagerError::Driver(error) if error.ends_epoch())
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex as StdMutex};

    use inline_agent_bridge::{
        AgentEventReceiver, ApprovalDecision, DriverCapabilities, DriverError, DriverFuture,
        DriverModelOption, DriverSettingOption, DriverSettingsCatalog, ProviderInstanceRef,
        ProviderSessionId, ProviderSessionRef, ResumeSessionSpec, SessionSpec,
        SessionThreadBinding, StartedTurn, SteeringSupport, TurnId,
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

    #[test]
    fn status_names_the_effective_provider_default_model() {
        let catalog = DriverSettingsCatalog {
            models: vec![DriverModelOption {
                value: "default".to_string(),
                label: "Default".to_string(),
                description: Some("Claude Sonnet 4.6".to_string()),
                reasoning: Vec::new(),
                default_reasoning: None,
                is_default: true,
            }],
            ..DriverSettingsCatalog::default()
        };

        assert_eq!(
            model_selection_label(None, Some(&catalog)),
            "Claude Sonnet 4.6 (provider default)"
        );
        assert_eq!(
            model_selection_label(Some("default"), Some(&catalog)),
            "Claude Sonnet 4.6 (provider default)"
        );
        assert_eq!(model_selection_label(None, None), "provider default");
    }

    #[test]
    fn status_reports_weekly_exhaustion_and_unknown_reset_without_assuming_capacity() {
        let text = usage_status_text(&[inline_agent_bridge::DriverUsageWindow {
            label: "Codex".to_string(),
            used_percent: 100,
            window_minutes: Some(10_080),
            resets_at: None,
        }]);
        assert!(text.contains("weekly: 0% remaining (limit reached)"));
        assert!(text.contains("reset time unavailable"));
        assert_eq!(usage_status_text(&[]), "Provider usage is unavailable.");
    }

    #[test]
    fn command_failure_includes_the_provider_explanation() {
        assert!(
            matches!(failed("Compaction failed.", "Weekly usage limit reached. Try again tomorrow.", false),
            IdleCommandResolution::Handled { message, provider_epoch_ended:false, .. }
                if message.contains("Weekly usage limit reached"))
        );
    }

    #[test]
    fn only_an_exact_release_for_this_bot_skips_the_provider_work_lease() {
        assert!(is_provider_epoch_release_command("/stop", "codex_bot"));
        assert!(is_provider_epoch_release_command(
            "/stop@codex_bot",
            "codex_bot"
        ));
        assert!(!is_provider_epoch_release_command(
            "/stop@other_bot",
            "codex_bot"
        ));
        assert!(!is_provider_epoch_release_command("/stop now", "codex_bot"));
        assert!(is_provider_epoch_release_command("/close", "codex_bot"));
        assert!(is_provider_epoch_release_command(
            "/close@codex_bot",
            "codex_bot"
        ));
        assert!(!is_provider_epoch_release_command(
            "/close@other_bot",
            "codex_bot"
        ));
        assert!(!is_provider_epoch_release_command(
            "/close now",
            "codex_bot"
        ));
    }

    #[test]
    fn help_advertises_only_each_providers_real_session_surface() {
        let codex = static_command_help(&ProviderId::new("codex").expect("provider"));
        assert!(codex.contains("/sessions, /open, /resume, /close"));
        assert!(!codex.contains("/history"));

        let claude = static_command_help(&ProviderId::new("claude").expect("provider"));
        assert!(claude.contains("/history"));
        assert!(!claude.contains("/sessions"));
        assert!(!claude.contains("/open"));
        assert!(!claude.contains("/close"));

        let amp = static_command_help(&ProviderId::new("amp").expect("provider"));
        assert!(!amp.contains("/sessions"));
        assert!(!amp.contains("/history"));
        assert!(amp.contains("/projects"));
    }

    #[test]
    fn close_is_reserved_for_codex_session_release() {
        assert_eq!(
            unsupported_close_message("claude"),
            Some("This provider does not support /close. Use /new to start a fresh session.")
        );
        assert_eq!(unsupported_close_message("codex"), None);
    }

    #[derive(Debug, Default)]
    struct FakeDriver {
        starts: StdMutex<Vec<PathBuf>>,
        compactions: StdMutex<Vec<ProviderSessionId>>,
        shutdowns: StdMutex<usize>,
        commands: Vec<inline_agent_bridge::DriverCommand>,
        compact_session: bool,
        resume_session: bool,
        settings_catalog_process_exited: bool,
        settings_catalog_pending: bool,
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
            if self.settings_catalog_pending {
                return Box::pin(std::future::pending());
            }
            if self.settings_catalog_process_exited {
                return Box::pin(async {
                    Err(DriverError::ProcessExited("provider exited".to_string()))
                });
            }
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
                    default_permissions: None,
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
        ) -> DriverFuture<'a, StartedTurn> {
            Box::pin(async move {
                self.compactions
                    .lock()
                    .expect("compactions")
                    .push(session_id.clone());
                let (sender, events) = AgentEventReceiver::default_channel();
                let turn_id = TurnId::new("compact-turn").unwrap();
                sender.send(Ok(AgentEvent::TurnCompleted {
                    turn_id: turn_id.clone(),
                    outcome: TurnOutcome::Completed,
                    error: None,
                    timing: Default::default(),
                }));
                Ok(StartedTurn { turn_id, events })
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
            Box::pin(async move {
                *self.shutdowns.lock().expect("shutdowns") += 1;
                Ok(())
            })
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
                codex_projects_path: None,
                codex_project_rpc: None,
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
    async fn pinned_session_threads_refuse_rotation_and_close_the_provider_epoch() {
        let (_directory, driver, store, manager, binding, workspace) = fixture(false);
        let provider = ProviderInstanceRef::new(
            binding.installation_id.clone(),
            ProviderId::new("codex").expect("provider"),
        )
        .expect("provider instance");
        let session = ProviderSessionRef::new(
            provider,
            ProviderSessionId::new("provider-session-1").expect("session"),
        )
        .expect("provider session");
        manager
            .bind_session_thread(
                &SessionThreadBinding::new(
                    session,
                    binding.workspace_id.clone(),
                    3,
                    binding.chat_id,
                )
                .expect("thread binding"),
                2,
            )
            .await
            .expect("bind session thread");
        let (active, identity) = settings_fixture(&binding, &workspace);
        let runtime = SettingsRuntime {
            sessions: &manager,
            store: &store,
            active: &active,
            identity: &identity,
            turn_active: false,
        };

        for command in ["/help", "/compact", "/providercommand"] {
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
            let IdleCommandResolution::Handled { message, .. } = result else {
                panic!("paused command must be handled locally");
            };
            assert!(message.contains("/resume"), "{command}: {message}");
        }
        assert!(!manager.session_is_active(&binding).await);

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
        let IdleCommandResolution::Handled { message, .. } = new_session else {
            panic!("expected pinned response");
        };
        assert!(message.contains("pinned"));
        assert!(driver.starts.lock().expect("starts").is_empty());

        let projects = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            identity.owner_user_id,
            "mo_codex_bot",
            "/projects",
        )
        .await;
        let IdleCommandResolution::Handled {
            message,
            choices: None,
            ..
        } = projects
        else {
            panic!("expected pinned project response");
        };
        assert!(message.contains("pinned"));
        assert!(message.contains("private DM"));

        let delegated_close = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            99,
            "mo_codex_bot",
            "/stop",
        )
        .await;
        let IdleCommandResolution::Handled { message, .. } = delegated_close else {
            panic!("expected owner-only close response");
        };
        assert_eq!(
            message,
            "Only the bot owner can release the provider connection."
        );
        assert_eq!(*driver.shutdowns.lock().expect("shutdowns"), 0);

        let close = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            identity.owner_user_id,
            "mo_codex_bot",
            "/close",
        )
        .await;
        assert!(matches!(
            close,
            IdleCommandResolution::Handled {
                failure: None,
                provider_epoch_ended: true,
                ..
            }
        ));
        assert_eq!(*driver.shutdowns.lock().expect("shutdowns"), 1);
        assert!(store.get_binding(&binding).expect("binding").is_some());
    }

    #[tokio::test]
    async fn stop_refuses_dequeued_provider_work_before_turn_start() {
        let (_directory, driver, store, manager, binding, workspace) = fixture(false);
        let provider = ProviderInstanceRef::new(
            binding.installation_id.clone(),
            ProviderId::new("codex").expect("provider"),
        )
        .expect("provider instance");
        manager
            .bind_session_thread(
                &SessionThreadBinding::new(
                    ProviderSessionRef::new(
                        provider,
                        ProviderSessionId::new("provider-session-1").expect("session"),
                    )
                    .expect("provider session"),
                    binding.workspace_id.clone(),
                    3,
                    binding.chat_id,
                )
                .expect("thread binding"),
                2,
            )
            .await
            .expect("bind session thread");
        let provider_work_lease = manager
            .begin_provider_work()
            .await
            .expect("dequeued provider work");
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
            "/stop",
        )
        .await;

        let IdleCommandResolution::Handled {
            message,
            provider_epoch_ended,
            ..
        } = resolution
        else {
            panic!("expected busy response");
        };
        assert!(message.contains("Another Inline Codex operation"));
        assert!(!provider_epoch_ended);
        assert_eq!(*driver.shutdowns.lock().expect("shutdowns"), 0);
        drop(provider_work_lease);
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
    async fn status_returns_when_the_provider_catalog_stalls() {
        let (_directory, _driver, store, _manager, binding, workspace) = fixture(false);
        let driver = Arc::new(FakeDriver {
            settings_catalog_pending: true,
            ..Default::default()
        });
        let manager = ProviderSessionManager::new(
            driver,
            Arc::clone(&store),
            ProviderId::new("codex").expect("provider"),
        );
        let (active, identity) = settings_fixture(&binding, &workspace);
        for turn_active in [true, false] {
            let deadline = if turn_active {
                Duration::from_millis(250)
            } else {
                SETTINGS_DEADLINE + Duration::from_secs(1)
            };
            let resolution = tokio::time::timeout(
                deadline,
                resolve_idle_command(
                    &manager,
                    &store,
                    &binding,
                    &workspace,
                    &SettingsRuntime {
                        sessions: &manager,
                        store: &store,
                        active: &active,
                        identity: &identity,
                        turn_active,
                    },
                    identity.owner_user_id,
                    "mo_codex_bot",
                    "/status",
                ),
            )
            .await
            .expect("bounded status");
            assert!(
                matches!(resolution, IdleCommandResolution::Handled { failure: None, provider_epoch_ended: false, message, .. } if message.contains("provider default"))
            );
        }
    }

    #[tokio::test]
    async fn status_reports_provider_epoch_loss_while_loading_permission_defaults() {
        let (directory, _driver, store, _manager, binding, workspace) = fixture(false);
        let driver = Arc::new(FakeDriver {
            settings_catalog_process_exited: true,
            ..FakeDriver::default()
        });
        let manager = ProviderSessionManager::new(
            driver,
            Arc::clone(&store),
            ProviderId::new("codex").expect("provider"),
        );
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
            "/status",
        )
        .await;

        assert!(matches!(
            resolution,
            IdleCommandResolution::Handled {
                failure: Some(_),
                provider_epoch_ended: true,
                ..
            }
        ));
        drop(directory);
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
            vec!["Automatic — GPT Test", "GPT Test"]
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

        let projects = resolve_idle_command(
            &manager,
            &store,
            &binding,
            &workspace,
            &runtime,
            identity.owner_user_id,
            "mo_codex_bot",
            "/projects",
        )
        .await;
        let IdleCommandResolution::Handled { message, .. } = projects else {
            panic!("expected project browser response");
        };
        assert!(message.contains("Current project:"));
        assert!(message.contains("`/projects <number|name>`"));
        assert!(!message.contains("`/folder"));
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
