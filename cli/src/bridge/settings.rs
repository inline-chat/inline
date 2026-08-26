//! Inline-native settings documents and provider-neutral mutations.

use std::sync::{Arc, RwLock};

use super::*;

const SETTINGS_VERSION: u32 = 1;
const DEFAULT_VALUE: &str = "__inline_provider_default__";
const SETTINGS_DEADLINE: Duration = Duration::from_secs(4);
const COMMAND_CHOICE_TTL_SECONDS: i64 = 10 * 60;
const COMMAND_CHOICE_PAGE_SIZE: usize = 6;
const MAX_COMMAND_CHOICES: usize = 60;
const PROVIDER_COMMAND_ITEM_PREFIX: &str = "provider.command:";

const ITEM_MODEL: &str = "agent.model";
const ITEM_REASONING: &str = "agent.reasoning";
const ITEM_PERMISSIONS: &str = "agent.permissions";
const ITEM_VERBOSE: &str = "agent.verbose";
pub(super) const ITEM_REPLY_THREADS: &str = "conversation.reply_threads";
const ITEM_NEW: &str = "session.new";
const ITEM_CLEAR: &str = "session.clear";
const ITEM_COMPACT: &str = "session.compact";
const ITEM_FOLDER: &str = "workspace.folder";

pub(super) struct SettingsCommandResult {
    pub message: String,
    pub failure: Option<String>,
    pub provider_epoch_ended: bool,
    pub choices: Option<SettingsCommandChoices>,
}

#[derive(Clone, Debug)]
pub(super) struct SettingsCommandChoices {
    pub provider_id: ProviderId,
    pub bot_user_id: i64,
    pub actor_user_id: i64,
    pub requires_owner: bool,
    pub item_id: String,
    pub document_revision: String,
    pub catalog_fingerprint: String,
    pub options: Vec<SettingsCommandChoice>,
}

#[derive(Clone, Debug)]
pub(super) struct SettingsCommandChoice {
    pub value: String,
    pub label: String,
}

pub(super) fn provider_command_choices<D: AgentDriver + 'static>(
    runtime: &SettingsRuntime<'_, D>,
    command: &inline_agent_bridge::DriverCommand,
    actor_user_id: i64,
) -> Option<SettingsCommandChoices> {
    let inline_agent_bridge::DriverCommandInput::SingleChoice {
        options,
        catalog_generation,
        ..
    } = command.input_shape()
    else {
        return None;
    };
    let options = options
        .into_iter()
        .filter(|option| !option.disabled)
        .take(MAX_COMMAND_CHOICES)
        .map(|option| SettingsCommandChoice {
            value: option.value,
            label: option.label,
        })
        .collect::<Vec<_>>();
    if options.is_empty() {
        return None;
    }
    let item_id = format!("{PROVIDER_COMMAND_ITEM_PREFIX}{}", command.name);
    let document_revision = catalog_generation
        .map(|generation| format!("provider-command-v1-{generation}"))
        .unwrap_or_else(|| "provider-command-v1-session".to_string());
    let catalog_fingerprint = command_choice_catalog_fingerprint(
        runtime.sessions.provider_id(),
        &item_id,
        &document_revision,
        &options,
    );
    Some(SettingsCommandChoices {
        provider_id: runtime.sessions.provider_id().clone(),
        bot_user_id: runtime.identity.bot_user_id,
        actor_user_id,
        requires_owner: false,
        item_id,
        document_revision,
        catalog_fingerprint,
        options,
    })
}

pub(super) enum SettingsEventOutcome {
    NotHandled,
    Handled { provider_epoch_ended: bool },
}

pub(super) enum SettingsCommandActionOutcome {
    NotHandled,
    Handled { provider_epoch_ended: bool },
}

struct SettingsInteractionResolution {
    response: BotChatSettingsResponse,
    provider_epoch_ended: bool,
}

struct SettingsInvocationFailure {
    response: BotChatSettingsResponse,
    provider_epoch_ended: bool,
}

impl SettingsInvocationFailure {
    fn normal(response: BotChatSettingsResponse) -> Self {
        Self {
            response,
            provider_epoch_ended: false,
        }
    }
}

impl From<BotChatSettingsResponse> for SettingsInvocationFailure {
    fn from(response: BotChatSettingsResponse) -> Self {
        Self::normal(response)
    }
}

impl SettingsInteractionResolution {
    fn normal(response: BotChatSettingsResponse) -> Self {
        Self {
            response,
            provider_epoch_ended: false,
        }
    }
}

#[derive(Clone, Debug)]
pub(super) struct ConversationSnapshot {
    pub binding: BindingKey,
    pub workspace: PathBuf,
}

#[derive(Clone, Debug)]
pub(super) struct ActiveConversation {
    inner: Arc<RwLock<ConversationSnapshot>>,
}

impl ActiveConversation {
    pub fn new(binding: BindingKey, workspace: PathBuf) -> Self {
        Self {
            inner: Arc::new(RwLock::new(ConversationSnapshot { binding, workspace })),
        }
    }

    pub fn snapshot(&self) -> ConversationSnapshot {
        self.inner
            .read()
            .expect("active conversation poisoned")
            .clone()
    }

    pub fn replace(&self, binding: BindingKey, workspace: PathBuf) {
        *self.inner.write().expect("active conversation poisoned") =
            ConversationSnapshot { binding, workspace };
    }
}

pub(super) struct SettingsRuntime<'a, D> {
    pub sessions: &'a ProviderSessionManager<D>,
    pub store: &'a BridgeStore,
    pub active: &'a ActiveConversation,
    pub identity: &'a SettingsIdentity,
    pub turn_active: bool,
}

#[derive(Clone, Debug)]
pub(super) struct SettingsIdentity {
    pub owner_user_id: i64,
    pub owner_dm_chat_id: i64,
    pub bot_user_id: i64,
    pub host_installation_id: String,
    pub host_label: String,
    pub workspace_picker: Option<WorkspacePickerEndpoint>,
    pub bot_store: SqliteStore,
    pub reply_thread_default: ReplyThreadDefault,
}

pub(super) async fn advertise_settings(
    bot: &InlineClient,
) -> Result<(), Box<dyn std::error::Error>> {
    let capabilities = vec![BotCapability {
        kind: BotCapabilityKind::ChatSettings,
        version: SETTINGS_VERSION,
    }];
    let accepted = bot.set_bot_capabilities(capabilities.clone()).await?;
    if accepted != capabilities {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline did not preserve the bridge bot-settings capability",
        )
        .into());
    }
    Ok(())
}

pub(super) async fn send_settings_command_choices(
    bot: &InlineClient,
    store: &BridgeStore,
    record: &InboundRecord,
    message_text: &str,
    choices: &SettingsCommandChoices,
) -> Result<(), Box<dyn std::error::Error>> {
    let token = generate_control_token();
    let page_count = command_choice_page_count(choices.options.len());
    let now = now_seconds();
    if !store.insert_command_choice_request(&PendingCommandChoiceRequest {
        callback_token: token.clone(),
        installation_id: record.binding.installation_id.clone(),
        provider_id: choices.provider_id.clone(),
        workspace_id: record.binding.workspace_id.clone(),
        bot_user_id: choices.bot_user_id,
        actor_user_id: choices.actor_user_id,
        requires_owner: choices.requires_owner,
        origin_chat_id: record.binding.chat_id,
        origin_message_id: record.message_id,
        item_id: choices.item_id.clone(),
        prompt_text: message_text.to_string(),
        catalog_fingerprint: choices.catalog_fingerprint.clone(),
        document_revision: choices.document_revision.clone(),
        page: 0,
        page_count,
        created_at: now,
        expires_at: now.saturating_add(COMMAND_CHOICE_TTL_SECONDS),
    })? {
        return Err(io::Error::other("settings choice request token collision").into());
    }
    let mut message = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(record.binding.chat_id),
        },
        command_choice_page_text(message_text, 0, page_count),
    );
    message.reply_to_message_id = Some(InlineId::new(record.message_id));
    message.external_id = Some(ExternalId::try_new(
        "agent-bridge",
        format!("settings-choice-{token}"),
    )?);
    message.random_id = Some(interaction_random_id("settings-choice", &token));
    message.notification_mode = BridgeNotificationClass::RoutineStatus.notification_mode();
    let mutation = send_interactive_text_with_retry(
        bot,
        SendInteractiveTextRequest {
            message,
            actions: command_choice_actions(&token, 0, &choices.options)?,
        },
    )
    .await?;
    let message_id = mutation.message_id.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::ConnectionAborted,
            "settings choice publication completed without a message identity",
        )
    })?;
    store.attach_command_choice_message(&token, message_id.get())?;
    Ok(())
}

pub(super) async fn handle_settings_command_action<D: AgentDriver + 'static>(
    bot: &InlineClient,
    event: &ClientEvent,
    runtime: &SettingsRuntime<'_, D>,
    operator_policy: &OperatorPolicy,
) -> Result<SettingsCommandActionOutcome, Box<dyn std::error::Error>> {
    let ClientEvent::MessageActionInvoked {
        interaction_id,
        chat_id,
        message_id,
        actor_user_id,
        data,
        ..
    } = event
    else {
        return Ok(SettingsCommandActionOutcome::NotHandled);
    };
    let Ok(callback) = serde_json::from_slice::<SettingsCommandChoiceCallback>(data) else {
        return Ok(SettingsCommandActionOutcome::NotHandled);
    };
    if callback.version != 1 {
        return Ok(SettingsCommandActionOutcome::NotHandled);
    }
    let Some(request) = runtime.store.get_command_choice_request(&callback.token)? else {
        bot.answer_message_action(inline_client::AnswerMessageActionRequest {
            interaction_id: *interaction_id,
            toast: Some("This request is no longer active.".to_string()),
        })
        .await?;
        return Ok(SettingsCommandActionOutcome::Handled {
            provider_epoch_ended: false,
        });
    };
    let snapshot = runtime.active.snapshot();
    let actor_still_authorized = operator_policy.allows(actor_user_id.get());
    let authorized = actor_user_id.get() == request.actor_user_id
        && actor_still_authorized
        && (!request.requires_owner || actor_user_id.get() == runtime.identity.owner_user_id)
        && chat_id.get() == snapshot.binding.chat_id
        && chat_id.get() == request.origin_chat_id
        && message_id.get() == request.card_message_id.unwrap_or_default()
        && request.installation_id == snapshot.binding.installation_id
        && request.provider_id == *runtime.sessions.provider_id()
        && request.bot_user_id == runtime.identity.bot_user_id
        && (request.workspace_id == snapshot.binding.workspace_id
            || (request.state == inline_agent_bridge::CommandChoiceState::Applying
                && request.item_id == ITEM_FOLDER
                && request.selected_value.as_deref()
                    == Some(snapshot.binding.workspace_id.as_str())));
    if !authorized {
        let toast = if request.requires_owner {
            "Only the bot owner can change these settings."
        } else {
            "You are no longer allowed to run this command."
        };
        bot.answer_message_action(inline_client::AnswerMessageActionRequest {
            interaction_id: *interaction_id,
            toast: Some(toast.to_string()),
        })
        .await?;
        return Ok(SettingsCommandActionOutcome::Handled {
            provider_epoch_ended: false,
        });
    }
    let now = now_seconds();
    let action = match &callback.action {
        SettingsCommandChoiceCallbackAction::Select { value } => CommandChoiceAction::Select {
            value: value.clone(),
        },
        SettingsCommandChoiceCallbackAction::Page { page } => {
            CommandChoiceAction::Page { page: *page }
        }
        SettingsCommandChoiceCallbackAction::Cancel => CommandChoiceAction::Cancel,
    };
    if request.expires_at <= now {
        let outcome = runtime.store.claim_command_choice_request(
            &callback.token,
            &action,
            &[],
            &command_choice_context(
                runtime,
                &snapshot,
                interaction_id.get(),
                actor_user_id.get(),
                actor_still_authorized,
                chat_id.get(),
                message_id.get(),
                request.catalog_fingerprint.clone(),
                request.document_revision.clone(),
                request.page_count,
                now,
            ),
        )?;
        if matches!(outcome, CommandChoiceClaimOutcome::Expired(_)) {
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id: *interaction_id,
                toast: Some("This request expired.".to_string()),
            })
            .await?;
            clear_approval(
                bot,
                chat_id.get(),
                *message_id,
                "This choice request expired. Run the command again.",
            )
            .await?;
            return Ok(SettingsCommandActionOutcome::Handled {
                provider_epoch_ended: false,
            });
        }
    }
    if request.item_id.starts_with(PROVIDER_COMMAND_ITEM_PREFIX) {
        return handle_provider_command_choice_action(
            bot,
            runtime,
            &snapshot,
            &request,
            &callback.token,
            &action,
            *interaction_id,
            actor_user_id.get(),
            actor_still_authorized,
            chat_id.get(),
            *message_id,
            now,
        )
        .await;
    }
    let _provider_work_lease = match runtime.sessions.try_begin_provider_work() {
        Ok(Some(lease)) => lease,
        Ok(None) => {
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id: *interaction_id,
                toast: Some(
                    "Inline is releasing the agent connection. Try again in a moment.".to_string(),
                ),
            })
            .await?;
            return Ok(SettingsCommandActionOutcome::Handled {
                provider_epoch_ended: false,
            });
        }
        Err(error) => {
            let provider_epoch_ended = session_error_ends_provider_epoch(&error);
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id: *interaction_id,
                toast: Some("The agent connection restarted. Try again.".to_string()),
            })
            .await?;
            return Ok(SettingsCommandActionOutcome::Handled {
                provider_epoch_ended,
            });
        }
    };
    let catalog = match load_catalog(runtime, &snapshot).await {
        Ok(catalog) => catalog,
        Err(result) => {
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id: *interaction_id,
                toast: Some(result.message),
            })
            .await?;
            return Ok(SettingsCommandActionOutcome::Handled {
                provider_epoch_ended: result.provider_epoch_ended,
            });
        }
    };
    let current = runtime.store.chat_settings(&snapshot.binding, now)?;
    let Some(current_choices) = settings_command_choices_for_item(
        runtime,
        &snapshot,
        &current,
        catalog.as_ref(),
        &request.item_id,
    )
    .await
    else {
        bot.answer_message_action(inline_client::AnswerMessageActionRequest {
            interaction_id: *interaction_id,
            toast: Some("That choice is no longer available.".to_string()),
        })
        .await?;
        clear_approval(
            bot,
            chat_id.get(),
            *message_id,
            "This choice request is stale. Run the command again.",
        )
        .await?;
        return Ok(SettingsCommandActionOutcome::Handled {
            provider_epoch_ended: false,
        });
    };
    let legal_values = current_choices
        .options
        .iter()
        .map(|option| option.value.clone())
        .collect::<Vec<_>>();
    let page_count = command_choice_page_count(current_choices.options.len());
    let outcome = runtime.store.claim_command_choice_request(
        &callback.token,
        &action,
        &legal_values,
        &command_choice_context(
            runtime,
            &snapshot,
            interaction_id.get(),
            actor_user_id.get(),
            actor_still_authorized,
            chat_id.get(),
            message_id.get(),
            current_choices.catalog_fingerprint.clone(),
            current_choices.document_revision.clone(),
            page_count,
            now,
        ),
    )?;
    match outcome {
        CommandChoiceClaimOutcome::Navigated(request) => {
            edit_command_choice_page(bot, &request, &current_choices.options).await?;
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id: *interaction_id,
                toast: Some(format!(
                    "Page {} of {}",
                    request.page + 1,
                    request.page_count
                )),
            })
            .await?;
            Ok(SettingsCommandActionOutcome::Handled {
                provider_epoch_ended: false,
            })
        }
        CommandChoiceClaimOutcome::Cancelled(_) => {
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id: *interaction_id,
                toast: Some("Cancelled".to_string()),
            })
            .await?;
            clear_approval(bot, chat_id.get(), *message_id, "Cancelled.").await?;
            Ok(SettingsCommandActionOutcome::Handled {
                provider_epoch_ended: false,
            })
        }
        CommandChoiceClaimOutcome::Claimed(request)
        | CommandChoiceClaimOutcome::Resumable(request) => {
            let selected = request.selected_value.as_deref().unwrap_or_default();
            let label = current_choices
                .options
                .iter()
                .find(|option| option.value == selected)
                .map(|option| option.label.as_str())
                .unwrap_or("Choice");
            let already_applied =
                command_choice_already_applied(runtime, &request, &snapshot, &current).await;
            let result = if already_applied {
                Ok(snapshot.clone())
            } else {
                let value = BotSettingsValue::String(selected.to_string());
                apply_invocation(
                    runtime,
                    &snapshot,
                    current,
                    catalog.as_ref(),
                    &request.item_id,
                    Some(&value),
                )
                .await
            };
            match result {
                Ok(_) => {
                    runtime.store.finish_command_choice_request(
                        &callback.token,
                        true,
                        now_seconds(),
                    )?;
                    let terminal = settings_choice_terminal_text(
                        &request.item_id,
                        label,
                        runtime
                            .sessions
                            .driver()
                            .capabilities()
                            .settings_apply_timing,
                    );
                    bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                        interaction_id: *interaction_id,
                        toast: Some("Updated".to_string()),
                    })
                    .await?;
                    clear_approval(bot, chat_id.get(), *message_id, &terminal).await?;
                    Ok(SettingsCommandActionOutcome::Handled {
                        provider_epoch_ended: false,
                    })
                }
                Err(failure) => {
                    runtime.store.finish_command_choice_request(
                        &callback.token,
                        false,
                        now_seconds(),
                    )?;
                    let (message, provider_epoch_ended) = match failure {
                        SettingsInvocationFailure {
                            response: BotChatSettingsResponse::Problem(problem),
                            provider_epoch_ended,
                        } => (problem.message, provider_epoch_ended),
                        SettingsInvocationFailure {
                            provider_epoch_ended,
                            ..
                        } => (
                            "That option is no longer available.".to_string(),
                            provider_epoch_ended,
                        ),
                    };
                    bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                        interaction_id: *interaction_id,
                        toast: Some(message),
                    })
                    .await?;
                    clear_approval(
                        bot,
                        chat_id.get(),
                        *message_id,
                        "The change could not be applied. Run the command again.",
                    )
                    .await?;
                    Ok(SettingsCommandActionOutcome::Handled {
                        provider_epoch_ended,
                    })
                }
            }
        }
        CommandChoiceClaimOutcome::Unauthorized => {
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id: *interaction_id,
                toast: Some("Only the bot owner can change these settings.".to_string()),
            })
            .await?;
            Ok(SettingsCommandActionOutcome::Handled {
                provider_epoch_ended: false,
            })
        }
        CommandChoiceClaimOutcome::Unknown | CommandChoiceClaimOutcome::WrongContext => {
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id: *interaction_id,
                toast: Some("This request is no longer active.".to_string()),
            })
            .await?;
            Ok(SettingsCommandActionOutcome::Handled {
                provider_epoch_ended: false,
            })
        }
        CommandChoiceClaimOutcome::Refreshed(request) => {
            edit_command_choice_page(bot, &request, &current_choices.options).await?;
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id: *interaction_id,
                toast: Some("Choices changed. Review the latest options.".to_string()),
            })
            .await?;
            Ok(SettingsCommandActionOutcome::Handled {
                provider_epoch_ended: false,
            })
        }
        CommandChoiceClaimOutcome::InvalidChoice
        | CommandChoiceClaimOutcome::Expired(_)
        | CommandChoiceClaimOutcome::NotPending(_) => {
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id: *interaction_id,
                toast: Some("This request is no longer active.".to_string()),
            })
            .await?;
            clear_approval(
                bot,
                chat_id.get(),
                *message_id,
                "This choice request is no longer active. Run the command again.",
            )
            .await?;
            Ok(SettingsCommandActionOutcome::Handled {
                provider_epoch_ended: false,
            })
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn handle_provider_command_choice_action<D: AgentDriver + 'static>(
    bot: &InlineClient,
    runtime: &SettingsRuntime<'_, D>,
    snapshot: &ConversationSnapshot,
    request: &CommandChoiceRequest,
    callback_token: &str,
    action: &CommandChoiceAction,
    interaction_id: InlineId,
    actor_user_id: i64,
    actor_still_authorized: bool,
    action_chat_id: i64,
    action_message_id: InlineId,
    now: i64,
) -> Result<SettingsCommandActionOutcome, Box<dyn std::error::Error>> {
    let command_name = request
        .item_id
        .strip_prefix(PROVIDER_COMMAND_ITEM_PREFIX)
        .unwrap_or_default();
    let _provider_work_lease = match runtime.sessions.try_begin_provider_work() {
        Ok(Some(lease)) => lease,
        Ok(None) => {
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id,
                toast: Some(
                    "Inline is releasing the agent connection. Try again in a moment.".to_string(),
                ),
            })
            .await?;
            return Ok(SettingsCommandActionOutcome::Handled {
                provider_epoch_ended: false,
            });
        }
        Err(error) => {
            let provider_epoch_ended = session_error_ends_provider_epoch(&error);
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id,
                toast: Some("The agent connection restarted. Try again.".to_string()),
            })
            .await?;
            return Ok(SettingsCommandActionOutcome::Handled {
                provider_epoch_ended,
            });
        }
    };
    let commands = match provider_commands(runtime.sessions, &snapshot.binding).await {
        Ok(commands) => commands,
        Err(error) => {
            let provider_epoch_ended = session_error_ends_provider_epoch(&error);
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id,
                toast: Some("Provider command choices are temporarily unavailable.".to_string()),
            })
            .await?;
            return Ok(SettingsCommandActionOutcome::Handled {
                provider_epoch_ended,
            });
        }
    };
    let Some(command) = commands.iter().find(|command| command.name == command_name) else {
        terminalize_inactive_command_choice(
            bot,
            interaction_id,
            action_chat_id,
            action_message_id,
            "That provider command is no longer available.",
        )
        .await?;
        return Ok(SettingsCommandActionOutcome::Handled {
            provider_epoch_ended: false,
        });
    };
    let Some(current_choices) = provider_command_choices(runtime, command, request.actor_user_id)
    else {
        terminalize_inactive_command_choice(
            bot,
            interaction_id,
            action_chat_id,
            action_message_id,
            "That provider command has no available choices.",
        )
        .await?;
        return Ok(SettingsCommandActionOutcome::Handled {
            provider_epoch_ended: false,
        });
    };
    let legal_values = current_choices
        .options
        .iter()
        .map(|option| option.value.clone())
        .collect::<Vec<_>>();
    let page_count = command_choice_page_count(current_choices.options.len());
    let outcome = runtime.store.claim_command_choice_request(
        callback_token,
        action,
        &legal_values,
        &command_choice_context(
            runtime,
            snapshot,
            interaction_id.get(),
            actor_user_id,
            actor_still_authorized,
            action_chat_id,
            action_message_id.get(),
            current_choices.catalog_fingerprint.clone(),
            current_choices.document_revision.clone(),
            page_count,
            now,
        ),
    )?;
    match outcome {
        CommandChoiceClaimOutcome::Navigated(request) => {
            edit_command_choice_page(bot, &request, &current_choices.options).await?;
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id,
                toast: Some(format!(
                    "Page {} of {}",
                    request.page + 1,
                    request.page_count
                )),
            })
            .await?;
        }
        CommandChoiceClaimOutcome::Cancelled(_) => {
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id,
                toast: Some("Cancelled".to_string()),
            })
            .await?;
            clear_approval(bot, action_chat_id, action_message_id, "Cancelled.").await?;
        }
        CommandChoiceClaimOutcome::Claimed(request)
        | CommandChoiceClaimOutcome::Resumable(request) => {
            let selected = request.selected_value.as_deref().unwrap_or_default();
            let Some(option) = current_choices
                .options
                .iter()
                .find(|option| option.value == selected)
            else {
                runtime.store.finish_command_choice_request(
                    callback_token,
                    false,
                    now_seconds(),
                )?;
                terminalize_inactive_command_choice(
                    bot,
                    interaction_id,
                    action_chat_id,
                    action_message_id,
                    "That provider command choice is no longer available.",
                )
                .await?;
                return Ok(SettingsCommandActionOutcome::Handled {
                    provider_epoch_ended: false,
                });
            };
            let event_id = format!("command-choice-{callback_token}");
            let direction_text = format!("/{command_name} {}", option.value);
            let inbound = InboundRecord {
                event_id: event_id.clone(),
                binding: snapshot.binding.clone(),
                message_id: request.origin_message_id,
                delivery_chat_id: snapshot.binding.chat_id,
                sender_user_id: request.actor_user_id,
                direction: Direction::new(DirectionId::new(event_id.clone())?, direction_text),
                state: InboundState::Accepted,
                accepted_at: request.created_at,
                started_at: None,
                lease_expires_at: None,
                attempt_count: 0,
                provider_turn_id: None,
                stream_message_id: None,
                failure: None,
            };
            let accepted = runtime.store.accept_inbound(&inbound)?;
            let same_durable_direction =
                runtime
                    .store
                    .get_inbound(&event_id)?
                    .is_some_and(|existing| {
                        existing.binding == inbound.binding
                            && existing.sender_user_id == inbound.sender_user_id
                            && existing.direction == inbound.direction
                    });
            if !accepted && !same_durable_direction {
                runtime.store.finish_command_choice_request(
                    callback_token,
                    false,
                    now_seconds(),
                )?;
                return Err(io::Error::other(
                    "provider command choice collided with another durable direction",
                )
                .into());
            }
            runtime
                .store
                .finish_command_choice_request(callback_token, true, now_seconds())?;
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id,
                toast: Some("Sent to agent".to_string()),
            })
            .await?;
            clear_approval(
                bot,
                action_chat_id,
                action_message_id,
                &format!(
                    "{} selected for /{command_name}. Sent to the agent.",
                    truncate(&option.label, 80)
                ),
            )
            .await?;
        }
        CommandChoiceClaimOutcome::Unauthorized => {
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id,
                toast: Some("Only the bot owner can run this command.".to_string()),
            })
            .await?;
        }
        CommandChoiceClaimOutcome::Unknown | CommandChoiceClaimOutcome::WrongContext => {
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id,
                toast: Some("This request is no longer active.".to_string()),
            })
            .await?;
        }
        CommandChoiceClaimOutcome::Refreshed(request) => {
            edit_command_choice_page(bot, &request, &current_choices.options).await?;
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id,
                toast: Some("Choices changed. Review the latest options.".to_string()),
            })
            .await?;
        }
        CommandChoiceClaimOutcome::InvalidChoice
        | CommandChoiceClaimOutcome::Expired(_)
        | CommandChoiceClaimOutcome::NotPending(_) => {
            terminalize_inactive_command_choice(
                bot,
                interaction_id,
                action_chat_id,
                action_message_id,
                "Provider command choices changed. Run the command again.",
            )
            .await?;
        }
    }
    Ok(SettingsCommandActionOutcome::Handled {
        provider_epoch_ended: false,
    })
}

async fn terminalize_inactive_command_choice(
    bot: &InlineClient,
    interaction_id: InlineId,
    chat_id: i64,
    message_id: InlineId,
    terminal: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    bot.answer_message_action(inline_client::AnswerMessageActionRequest {
        interaction_id,
        toast: Some("This request is no longer active.".to_string()),
    })
    .await?;
    clear_approval(bot, chat_id, message_id, terminal).await
}

#[allow(clippy::too_many_arguments)]
fn command_choice_context<D: AgentDriver + 'static>(
    runtime: &SettingsRuntime<'_, D>,
    snapshot: &ConversationSnapshot,
    interaction_id: i64,
    actor_user_id: i64,
    actor_still_authorized: bool,
    action_chat_id: i64,
    action_message_id: i64,
    catalog_fingerprint: String,
    document_revision: String,
    page_count: i64,
    now: i64,
) -> CommandChoiceClaimContext {
    CommandChoiceClaimContext {
        installation_id: snapshot.binding.installation_id.clone(),
        provider_id: runtime.sessions.provider_id().clone(),
        workspace_id: snapshot.binding.workspace_id.clone(),
        bot_user_id: runtime.identity.bot_user_id,
        actor_user_id,
        current_owner_user_id: runtime.identity.owner_user_id,
        actor_still_authorized,
        action_chat_id,
        action_message_id,
        event_id: format!("inline-action-{action_chat_id}-{interaction_id}"),
        catalog_fingerprint,
        document_revision,
        page_count,
        now,
    }
}

fn command_choice_page_count(option_count: usize) -> i64 {
    option_count.div_ceil(COMMAND_CHOICE_PAGE_SIZE).max(1) as i64
}

fn command_choice_page_text(prompt: &str, page: i64, page_count: i64) -> String {
    if page_count <= 1 {
        prompt.to_string()
    } else {
        format!("{prompt}\n\nPage {} of {page_count}", page + 1)
    }
}

fn command_choice_actions(
    token: &str,
    page: i64,
    options: &[SettingsCommandChoice],
) -> Result<MessageActions, serde_json::Error> {
    let page = usize::try_from(page).unwrap_or_default();
    let page_count = command_choice_page_count(options.len());
    let start = page.saturating_mul(COMMAND_CHOICE_PAGE_SIZE);
    let mut rows = options
        .iter()
        .skip(start)
        .take(COMMAND_CHOICE_PAGE_SIZE)
        .enumerate()
        .map(|(index, option)| {
            Ok(MessageActionButton {
                action_id: format!("bridge_setting_choice_{index}"),
                text: truncate_utf16(&option.label, 64),
                kind: MessageActionKind::Callback {
                    data: serde_json::to_vec(&SettingsCommandChoiceCallback {
                        version: 1,
                        token: token.to_string(),
                        action: SettingsCommandChoiceCallbackAction::Select {
                            value: option.value.clone(),
                        },
                    })?,
                },
            })
        })
        .collect::<Result<Vec<_>, serde_json::Error>>()?
        .chunks(2)
        .map(|actions| MessageActionRow {
            actions: actions.to_vec(),
        })
        .collect::<Vec<_>>();
    let mut navigation = Vec::new();
    if page > 0 {
        navigation.push(command_choice_button(
            "back",
            "Back",
            token,
            SettingsCommandChoiceCallbackAction::Page {
                page: page as i64 - 1,
            },
        )?);
    }
    if (page as i64) + 1 < page_count {
        navigation.push(command_choice_button(
            "more",
            "More",
            token,
            SettingsCommandChoiceCallbackAction::Page {
                page: page as i64 + 1,
            },
        )?);
    }
    if !navigation.is_empty() {
        rows.push(MessageActionRow {
            actions: navigation,
        });
    }
    rows.push(MessageActionRow {
        actions: vec![command_choice_button(
            "cancel",
            "Cancel",
            token,
            SettingsCommandChoiceCallbackAction::Cancel,
        )?],
    });
    Ok(MessageActions { rows })
}

fn command_choice_button(
    action_id: &str,
    text: &str,
    token: &str,
    action: SettingsCommandChoiceCallbackAction,
) -> Result<MessageActionButton, serde_json::Error> {
    Ok(MessageActionButton {
        action_id: format!("bridge_setting_{action_id}"),
        text: text.to_string(),
        kind: MessageActionKind::Callback {
            data: serde_json::to_vec(&SettingsCommandChoiceCallback {
                version: 1,
                token: token.to_string(),
                action,
            })?,
        },
    })
}

async fn edit_command_choice_page(
    bot: &InlineClient,
    request: &CommandChoiceRequest,
    options: &[SettingsCommandChoice],
) -> Result<(), Box<dyn std::error::Error>> {
    let message_id = request.card_message_id.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "settings choice request is missing its card identity",
        )
    })?;
    edit_interactive_message_with_retry(
        bot,
        EditInteractiveMessageRequest {
            message: EditMessageRequest {
                chat_id: InlineId::new(request.origin_chat_id),
                message_id: InlineId::new(message_id),
                text: command_choice_page_text(
                    &request.prompt_text,
                    request.page,
                    request.page_count,
                ),
                external_id: None,
                parse_markdown: true,
            },
            actions: command_choice_actions(&request.callback_token, request.page, options)?,
        },
    )
    .await
}

async fn command_choice_already_applied<D: AgentDriver + 'static>(
    runtime: &SettingsRuntime<'_, D>,
    request: &CommandChoiceRequest,
    snapshot: &ConversationSnapshot,
    settings: &ChatSettingsRecord,
) -> bool {
    let Some(selected) = request.selected_value.as_deref() else {
        return false;
    };
    match request.item_id.as_str() {
        ITEM_MODEL => {
            settings.model.as_deref() == setting_value(selected).as_deref()
                && settings.reasoning.is_none()
        }
        ITEM_REASONING => settings.reasoning.as_deref() == setting_value(selected).as_deref(),
        ITEM_PERMISSIONS => settings.permissions.as_deref() == setting_value(selected).as_deref(),
        ITEM_FOLDER => snapshot.binding.workspace_id.as_str() == selected,
        ITEM_REPLY_THREADS => resolve_reply_thread_policy(
            runtime.store,
            &snapshot.binding.installation_id,
            &runtime.identity.bot_store,
            runtime.identity.reply_thread_default,
            snapshot.binding.chat_id,
        )
        .await
        .is_ok_and(|policy| match selected {
            "reset" => policy.override_revision.is_none(),
            "auto" => {
                policy.source == ReplyThreadPolicySource::ChatOverride
                    && policy.mode == ReplyThreadMode::Auto
            }
            "on" => {
                policy.source == ReplyThreadPolicySource::ChatOverride
                    && policy.mode == ReplyThreadMode::On
            }
            "off" => {
                policy.source == ReplyThreadPolicySource::ChatOverride
                    && policy.mode == ReplyThreadMode::Off
            }
            _ => false,
        }),
        _ => false,
    }
}

fn settings_choice_terminal_text(
    item_id: &str,
    label: &str,
    apply_timing: inline_agent_bridge::ApplyTiming,
) -> String {
    let label = truncate(label, 80);
    let timing = match apply_timing {
        inline_agent_bridge::ApplyTiming::Immediate => "",
        inline_agent_bridge::ApplyTiming::NextTurn => " Applies to the next turn.",
        inline_agent_bridge::ApplyTiming::NewSession => " Applies to the next session.",
    };
    match item_id {
        ITEM_MODEL => format!("Model set to {label}. Reasoning reset to provider default.{timing}"),
        ITEM_REASONING => format!("Reasoning set to {label}.{timing}"),
        ITEM_PERMISSIONS => format!("Permissions set to {label}.{timing}"),
        ITEM_FOLDER => format!("Project set to {label}."),
        ITEM_REPLY_THREADS if label == "Reset" => {
            "Reply in threads reset to the configured default.".to_string()
        }
        ITEM_REPLY_THREADS => format!("Reply in threads set to {label}."),
        _ => format!("{label} selected.{timing}"),
    }
}

pub(super) async fn handle_settings_event<D: AgentDriver + 'static>(
    bot: &InlineClient,
    event: &ClientEvent,
    runtime: &SettingsRuntime<'_, D>,
) -> Result<SettingsEventOutcome, Box<dyn std::error::Error>> {
    let ClientEvent::BotInteraction(interaction) = event else {
        return Ok(SettingsEventOutcome::NotHandled);
    };
    let (request_id, chat_id, actor_user_id, version) = match interaction {
        BotInteractionEvent::ChatSettingsRequested {
            request_id,
            chat_id,
            actor_user_id,
            version,
        }
        | BotInteractionEvent::ChatSettingsItemInvoked {
            request_id,
            chat_id,
            actor_user_id,
            version,
            ..
        } => (*request_id, chat_id.get(), actor_user_id.get(), *version),
        _ => return Ok(SettingsEventOutcome::NotHandled),
    };
    let snapshot = runtime.active.snapshot();
    let resolution = if actor_user_id != runtime.identity.owner_user_id {
        SettingsInteractionResolution::normal(problem(
            BotChatSettingsProblemCode::Unavailable,
            "Only the bot owner can view or change these settings.",
            None,
        ))
    } else if chat_id != snapshot.binding.chat_id {
        SettingsInteractionResolution::normal(problem(
            BotChatSettingsProblemCode::Unavailable,
            "Settings are not available for this conversation yet.",
            None,
        ))
    } else if version != SETTINGS_VERSION {
        SettingsInteractionResolution::normal(problem(
            BotChatSettingsProblemCode::Unavailable,
            "This settings version is not supported. Update Inline and try again.",
            None,
        ))
    } else {
        resolve_settings_interaction(interaction, runtime, snapshot.clone()).await
    };
    let next_snapshot = runtime.active.snapshot();
    let successful_document = matches!(&resolution.response, BotChatSettingsResponse::Document(_));
    let working_directory_announcement = match interaction {
        BotInteractionEvent::ChatSettingsItemInvoked { item_id, .. }
            if actor_user_id == runtime.identity.owner_user_id
                && chat_id == snapshot.binding.chat_id
                && successful_document
                && ((item_id == ITEM_FOLDER
                    && next_snapshot.binding.workspace_id != snapshot.binding.workspace_id)
                    || matches!(item_id.as_str(), ITEM_NEW | ITEM_CLEAR)) =>
        {
            Some(working_directory_message(&next_snapshot.workspace))
        }
        _ => None,
    };
    answer_settings_compatibly(
        bot,
        AnswerBotChatSettingsRequest {
            request_id,
            response: resolution.response,
        },
    )
    .await?;
    if let Some(message) = working_directory_announcement
        && let Err(error) = send_silent_text(
            bot,
            chat_id,
            &message,
            &format!("settings-{request_id}-working-directory"),
        )
        .await
    {
        eprintln!(
            "Could not publish working-directory status: {}",
            safe_diagnostic(&error.to_string())
        );
    }
    Ok(SettingsEventOutcome::Handled {
        provider_epoch_ended: resolution.provider_epoch_ended,
    })
}

pub(super) async fn handle_unavailable_settings_event(
    bot: &InlineClient,
    event: &ClientEvent,
    owner_user_id: i64,
) -> Result<bool, Box<dyn std::error::Error>> {
    handle_unavailable_settings_event_with_message(
        bot,
        event,
        owner_user_id,
        "Agent settings are temporarily unavailable while the local provider restarts.",
    )
    .await
}

pub(super) async fn handle_unavailable_settings_event_with_message(
    bot: &InlineClient,
    event: &ClientEvent,
    owner_user_id: i64,
    owner_message: &str,
) -> Result<bool, Box<dyn std::error::Error>> {
    let ClientEvent::BotInteraction(interaction) = event else {
        return Ok(false);
    };
    let (request_id, actor_user_id) = match interaction {
        BotInteractionEvent::ChatSettingsRequested {
            request_id,
            actor_user_id,
            ..
        }
        | BotInteractionEvent::ChatSettingsItemInvoked {
            request_id,
            actor_user_id,
            ..
        } => (*request_id, actor_user_id.get()),
        _ => return Ok(false),
    };
    answer_settings_compatibly(
        bot,
        AnswerBotChatSettingsRequest {
            request_id,
            response: unavailable_settings_response(actor_user_id, owner_user_id, owner_message),
        },
    )
    .await?;
    Ok(true)
}

async fn answer_settings_compatibly(
    bot: &InlineClient,
    request: AnswerBotChatSettingsRequest,
) -> Result<(), ClientRequestError> {
    match bot.answer_bot_chat_settings(request).await {
        Ok(()) => Ok(()),
        Err(error) if is_unsupported_settings_answer(&error) => {
            eprintln!(
                "Inline server does not support bot chat-settings responses yet; ignored the stale settings interaction."
            );
            Ok(())
        }
        Err(error) => Err(error),
    }
}

fn is_unsupported_settings_answer(error: &ClientRequestError) -> bool {
    matches!(
        error,
        ClientRequestError::Backend(error)
            if error.category == ClientErrorCategory::Unsupported
    )
}

fn unavailable_settings_response(
    actor_user_id: i64,
    owner_user_id: i64,
    owner_message: &str,
) -> BotChatSettingsResponse {
    let message = if actor_user_id == owner_user_id {
        owner_message
    } else {
        "Only the bot owner can view or change these settings."
    };
    problem(BotChatSettingsProblemCode::Unavailable, message, None)
}

/// Resolves slash commands through the same catalog, persistence, validation,
/// and mutation path used by the toolbar settings document.
pub(super) async fn resolve_reply_threads_command<D: AgentDriver + 'static>(
    runtime: &SettingsRuntime<'_, D>,
    arguments: &str,
) -> SettingsCommandResult {
    let snapshot = runtime.active.snapshot();
    let mut policy = match resolve_reply_thread_policy(
        runtime.store,
        &snapshot.binding.installation_id,
        &runtime.identity.bot_store,
        runtime.identity.reply_thread_default,
        snapshot.binding.chat_id,
    )
    .await
    {
        Ok(policy) => policy,
        Err(error) => return command_failed("I couldn’t read reply-thread settings.", error),
    };
    let action = arguments.trim().to_ascii_lowercase();
    if !action.is_empty() && action != "status" {
        let mode = match action.as_str() {
            "auto" => Some(ReplyThreadMode::Auto),
            "on" => Some(ReplyThreadMode::On),
            "off" => Some(ReplyThreadMode::Off),
            "reset" | "default" => None,
            _ => {
                return command_message(
                    "Usage: /threads, /threads auto, /threads on, /threads off, or /threads reset.",
                );
            }
        };
        match runtime.store.update_reply_thread_override(
            &snapshot.binding.installation_id,
            policy.scope.scope_chat_id,
            policy.override_revision,
            mode,
            now_seconds(),
        ) {
            Ok(ReplyThreadOverrideUpdateOutcome::Applied(_)) => {}
            Ok(ReplyThreadOverrideUpdateOutcome::Stale(_)) => {
                return command_message(
                    "Reply-thread settings changed. Review the latest value and try again.",
                );
            }
            Err(error) => return command_failed("I couldn’t save reply-thread settings.", error),
        }
        policy = match resolve_reply_thread_policy(
            runtime.store,
            &snapshot.binding.installation_id,
            &runtime.identity.bot_store,
            runtime.identity.reply_thread_default,
            snapshot.binding.chat_id,
        )
        .await
        {
            Ok(policy) => policy,
            Err(error) => {
                return command_failed("I couldn’t refresh reply-thread settings.", error);
            }
        };
    }
    let updated = !action.is_empty() && action != "status";
    SettingsCommandResult {
        message: reply_thread_status_text(policy, updated),
        failure: None,
        provider_epoch_ended: false,
        choices: Some(reply_thread_command_choices(runtime, policy)),
    }
}

fn reply_thread_status_text(policy: EffectiveReplyThreadPolicy, updated: bool) -> String {
    let state = if updated { "updated" } else { "are" };
    let behavior = match policy.mode {
        ReplyThreadMode::On => "Top-level replies will start or reuse an Inline reply thread.",
        ReplyThreadMode::Auto => {
            "DMs and fresh chats stay flat. Established chats use reply threads unless the request says to reply here; explicit thread requests also work in group chats."
        }
        ReplyThreadMode::Off => "Top-level replies stay in this conversation.",
    };
    let inherited = if policy.scope.existing_reply_thread {
        " This reply thread controls its parent chat's setting."
    } else {
        ""
    };
    format!(
        "Inline reply threads {state}: {} for this chat ({}).\n{behavior}\nExisting reply threads always stay in place.{inherited}",
        policy.mode.as_str(),
        policy.source.label(),
    )
}

fn reply_thread_command_revision(policy: EffectiveReplyThreadPolicy) -> String {
    format!(
        "reply-threads-v1-{}-{}-{}-{}",
        policy.scope.scope_chat_id,
        policy.mode.as_str(),
        policy.source.label().replace(' ', "-"),
        policy.override_revision.unwrap_or_default(),
    )
}

fn reply_thread_command_choices<D: AgentDriver + 'static>(
    runtime: &SettingsRuntime<'_, D>,
    policy: EffectiveReplyThreadPolicy,
) -> SettingsCommandChoices {
    let mut options = vec![
        SettingsCommandChoice {
            value: "auto".to_string(),
            label: "Auto".to_string(),
        },
        SettingsCommandChoice {
            value: "on".to_string(),
            label: "On".to_string(),
        },
        SettingsCommandChoice {
            value: "off".to_string(),
            label: "Off".to_string(),
        },
    ];
    if policy.override_revision.is_some() {
        options.push(SettingsCommandChoice {
            value: "reset".to_string(),
            label: "Reset".to_string(),
        });
    }
    let document_revision = reply_thread_command_revision(policy);
    let catalog_fingerprint = command_choice_catalog_fingerprint(
        runtime.sessions.provider_id(),
        ITEM_REPLY_THREADS,
        &document_revision,
        &options,
    );
    SettingsCommandChoices {
        provider_id: runtime.sessions.provider_id().clone(),
        bot_user_id: runtime.identity.bot_user_id,
        actor_user_id: runtime.identity.owner_user_id,
        requires_owner: true,
        item_id: ITEM_REPLY_THREADS.to_string(),
        document_revision,
        catalog_fingerprint,
        options,
    }
}

pub(super) async fn resolve_settings_command<D: AgentDriver + 'static>(
    runtime: &SettingsRuntime<'_, D>,
    name: &str,
    arguments: &str,
) -> SettingsCommandResult {
    let snapshot = runtime.active.snapshot();
    if name == "folder" {
        match runtime.store.session_thread_binding_for_chat(
            &snapshot.binding.installation_id,
            snapshot.binding.chat_id,
        ) {
            Ok(Some(_)) => {
                return command_message(format!(
                    "This thread is pinned to {}. Open the bot’s private DM to choose a project with /projects, then open another Codex session.",
                    workspace_label(&snapshot.workspace)
                ));
            }
            Ok(None) => {}
            Err(error) => return command_failed("I couldn’t read this session thread.", error),
        }
    }
    let catalog = match load_catalog(runtime, &snapshot).await {
        Ok(catalog) => catalog,
        Err(result) => return result,
    };
    let current = match runtime
        .store
        .chat_settings(&snapshot.binding, now_seconds())
    {
        Ok(settings) => settings,
        Err(error) => {
            return command_failed("I couldn’t read the current agent settings.", error);
        }
    };
    let arguments = arguments.trim();
    let verbose_toggle;
    let arguments = if arguments.is_empty() && name == "verbose" {
        verbose_toggle = if current.verbose { "off" } else { "on" };
        verbose_toggle
    } else {
        arguments
    };
    if arguments.is_empty() {
        return command_status(runtime, &snapshot, &current, catalog.as_ref(), name).await;
    }

    let (item_id, value, confirmation) = match command_value(
        runtime,
        &snapshot,
        &current,
        catalog.as_ref(),
        name,
        arguments,
    ) {
        Ok(value) => value,
        Err(message) => return command_message(message),
    };
    match apply_invocation(
        runtime,
        &snapshot,
        current,
        catalog.as_ref(),
        item_id,
        value.as_ref(),
    )
    .await
    {
        Ok(next)
            if item_id == ITEM_FOLDER
                && next.binding.workspace_id != snapshot.binding.workspace_id =>
        {
            command_message(format!(
                "{confirmation}\n\n{}",
                working_directory_message(&next.workspace)
            ))
        }
        Ok(_) => command_message(confirmation),
        Err(SettingsInvocationFailure {
            response: BotChatSettingsResponse::Problem(problem),
            provider_epoch_ended,
        }) => SettingsCommandResult {
            message: problem.message,
            failure: None,
            provider_epoch_ended,
            choices: None,
        },
        Err(_) => command_message("I couldn’t apply that setting. Try again."),
    }
}

async fn load_catalog<D: AgentDriver + 'static>(
    runtime: &SettingsRuntime<'_, D>,
    snapshot: &ConversationSnapshot,
) -> Result<Option<DriverSettingsCatalog>, SettingsCommandResult> {
    match tokio::time::timeout(
        SETTINGS_DEADLINE,
        runtime
            .sessions
            .settings_catalog(&snapshot.binding, now_seconds()),
    )
    .await
    {
        Ok(Ok(catalog)) => Ok(Some(catalog)),
        Ok(Err(error)) => {
            let provider_epoch_ended = session_error_ends_provider_epoch(&error);
            let mut result = command_failed("Provider options are temporarily unavailable.", error);
            result.provider_epoch_ended = provider_epoch_ended;
            Err(result)
        }
        Err(_) => Ok(None),
    }
}

async fn command_status<D: AgentDriver + 'static>(
    runtime: &SettingsRuntime<'_, D>,
    snapshot: &ConversationSnapshot,
    settings: &ChatSettingsRecord,
    catalog: Option<&DriverSettingsCatalog>,
    name: &str,
) -> SettingsCommandResult {
    let message = match name {
        "model" => format_setting_status(
            "Model",
            settings.model.as_deref(),
            catalog.map(|catalog| catalog.models.iter().map(|option| option.value.as_str())),
            "/model <value|default>",
        ),
        "reasoning" => format_setting_status(
            "Reasoning",
            settings.reasoning.as_deref(),
            selected_model(catalog, settings.model.as_deref())
                .map(|model| model.reasoning.iter().map(|option| option.value.as_str())),
            "/reasoning <value|default>",
        ),
        "permissions" => {
            let choices = catalog
                .map(|catalog| {
                    catalog
                        .permissions
                        .iter()
                        .filter(|option| !option.disabled)
                        .map(|option| option.value.as_str())
                        .take(16)
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .filter(|choices| !choices.is_empty())
                .unwrap_or_else(|| "temporarily unavailable".to_string());
            format!(
                "Permissions: {}. Choices: {choices}. Use `/permissions <value|default>`.",
                permission_selection_label(settings.permissions.as_deref(), catalog)
            )
        }
        "verbose" => format!(
            "Verbose is {}. Use `/verbose on` or `/verbose off`.",
            if settings.verbose { "on" } else { "off" }
        ),
        "folder" => match runtime.store.recent_workspace_choices(
            &snapshot.binding.installation_id,
            Some(&snapshot.binding.workspace_id),
        ) {
            Ok(choices) => {
                let list = choices
                    .iter()
                    .enumerate()
                    .map(|(index, choice)| {
                        let hint = choice
                            .parent_hint
                            .as_deref()
                            .map_or(String::new(), |hint| format!(" — {hint}"));
                        format!("{}. {}{}", index + 1, choice.display_name, hint)
                    })
                    .collect::<Vec<_>>()
                    .join("; ");
                format!(
                    "Current project: {}. Recent: {list}. Use `/folder <number|name>`, or choose Pick a Folder… in settings on {}.",
                    workspace_label(&snapshot.workspace),
                    runtime.identity.host_label
                )
            }
            Err(error) => {
                return command_failed("I couldn’t list recent project folders.", error);
            }
        },
        _ => "Unknown settings command. Try /help.".to_string(),
    };
    let mut result = command_message(message);
    result.choices = settings_command_choices(runtime, snapshot, settings, catalog, name).await;
    result
}

async fn settings_command_choices<D: AgentDriver + 'static>(
    runtime: &SettingsRuntime<'_, D>,
    snapshot: &ConversationSnapshot,
    settings: &ChatSettingsRecord,
    catalog: Option<&DriverSettingsCatalog>,
    name: &str,
) -> Option<SettingsCommandChoices> {
    let item_id = match name {
        "model" => ITEM_MODEL,
        "reasoning" => ITEM_REASONING,
        "permissions" => ITEM_PERMISSIONS,
        "folder" => ITEM_FOLDER,
        _ => return None,
    };
    settings_command_choices_for_item(runtime, snapshot, settings, catalog, item_id).await
}

async fn settings_command_choices_for_item<D: AgentDriver + 'static>(
    runtime: &SettingsRuntime<'_, D>,
    snapshot: &ConversationSnapshot,
    settings: &ChatSettingsRecord,
    catalog: Option<&DriverSettingsCatalog>,
    item_id: &str,
) -> Option<SettingsCommandChoices> {
    if item_id == ITEM_REPLY_THREADS {
        let policy = resolve_reply_thread_policy(
            runtime.store,
            &snapshot.binding.installation_id,
            &runtime.identity.bot_store,
            runtime.identity.reply_thread_default,
            snapshot.binding.chat_id,
        )
        .await
        .ok()?;
        return Some(reply_thread_command_choices(runtime, policy));
    }
    let document = build_settings_document(runtime, snapshot, settings, catalog)
        .await
        .ok()?;
    let item = document
        .sections
        .iter()
        .flat_map(|section| section.items.iter())
        .find(|item| item.id == item_id && !item.disabled)?;
    let options = match &item.control {
        BotChatSettingsControl::Select { options, .. } => options
            .iter()
            .filter(|option| !option.disabled)
            .take(MAX_COMMAND_CHOICES)
            .map(|option| SettingsCommandChoice {
                value: option.value.clone(),
                label: option.label.clone(),
            })
            .collect::<Vec<_>>(),
        BotChatSettingsControl::Folder(folder) => folder
            .recent_folders
            .iter()
            .filter(|option| !option.disabled)
            .take(MAX_COMMAND_CHOICES)
            .map(|option| SettingsCommandChoice {
                value: option.value.clone(),
                label: option.label.clone(),
            })
            .collect::<Vec<_>>(),
        _ => return None,
    };
    if options.is_empty() {
        return None;
    }
    let catalog_fingerprint = command_choice_catalog_fingerprint(
        runtime.sessions.provider_id(),
        item_id,
        &document.revision,
        &options,
    );
    Some(SettingsCommandChoices {
        provider_id: runtime.sessions.provider_id().clone(),
        bot_user_id: runtime.identity.bot_user_id,
        actor_user_id: runtime.identity.owner_user_id,
        requires_owner: true,
        item_id: item_id.to_string(),
        document_revision: document.revision,
        catalog_fingerprint,
        options,
    })
}

fn command_choice_catalog_fingerprint(
    provider_id: &ProviderId,
    item_id: &str,
    document_revision: &str,
    options: &[SettingsCommandChoice],
) -> String {
    let mut digest = Sha256::new();
    digest.update(b"inline-agent-command-choice-v1");
    for value in [provider_id.as_str(), item_id, document_revision] {
        digest.update([0]);
        digest.update(value.as_bytes());
    }
    for option in options {
        digest.update([1]);
        digest.update(option.value.as_bytes());
        digest.update([0]);
        digest.update(option.label.as_bytes());
    }
    digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn command_value<D: AgentDriver + 'static>(
    runtime: &SettingsRuntime<'_, D>,
    snapshot: &ConversationSnapshot,
    settings: &ChatSettingsRecord,
    catalog: Option<&DriverSettingsCatalog>,
    name: &str,
    argument: &str,
) -> Result<(&'static str, Option<BotSettingsValue>, String), String> {
    match name {
        "model" => {
            let value = resolve_select_argument(
                argument,
                catalog
                    .map(|catalog| {
                        catalog
                            .models
                            .iter()
                            .map(|option| (option.value.as_str(), option.label.as_str(), false))
                    })
                    .into_iter()
                    .flatten(),
                "model",
            )?;
            let label = display_selected(value.as_deref()).to_string();
            Ok((
                ITEM_MODEL,
                Some(BotSettingsValue::String(
                    value.unwrap_or_else(|| DEFAULT_VALUE.to_string()),
                )),
                format!(
                    "Model set to {label}. Reasoning reset to provider default. Applies to the next turn."
                ),
            ))
        }
        "reasoning" => {
            let value = resolve_select_argument(
                argument,
                selected_model(catalog, settings.model.as_deref())
                    .map(|model| {
                        model.reasoning.iter().map(|option| {
                            (
                                option.value.as_str(),
                                option.label.as_str(),
                                option.disabled,
                            )
                        })
                    })
                    .into_iter()
                    .flatten(),
                "reasoning level",
            )?;
            let label = display_selected(value.as_deref()).to_string();
            Ok((
                ITEM_REASONING,
                Some(BotSettingsValue::String(
                    value.unwrap_or_else(|| DEFAULT_VALUE.to_string()),
                )),
                format!("Reasoning set to {label}. Applies to the next turn."),
            ))
        }
        "permissions" => {
            let value = resolve_select_argument(
                argument,
                catalog
                    .map(|catalog| {
                        catalog.permissions.iter().map(|option| {
                            (
                                option.value.as_str(),
                                option.label.as_str(),
                                option.disabled,
                            )
                        })
                    })
                    .into_iter()
                    .flatten(),
                "permission profile",
            )?;
            let label = permission_selection_label(value.as_deref(), catalog);
            Ok((
                ITEM_PERMISSIONS,
                Some(BotSettingsValue::String(
                    value.unwrap_or_else(|| DEFAULT_VALUE.to_string()),
                )),
                format!("Permissions set to {label}. Applies to the next turn."),
            ))
        }
        "verbose" => {
            let enabled = match argument.to_ascii_lowercase().as_str() {
                "on" | "true" | "yes" | "1" => true,
                "off" | "false" | "no" | "0" => false,
                _ => return Err("Usage: /verbose <on|off>".to_string()),
            };
            Ok((
                ITEM_VERBOSE,
                Some(BotSettingsValue::Bool(enabled)),
                format!("Verbose is now {}.", if enabled { "on" } else { "off" }),
            ))
        }
        "folder" => {
            let choices = runtime
                .store
                .recent_workspace_choices(
                    &snapshot.binding.installation_id,
                    Some(&snapshot.binding.workspace_id),
                )
                .map_err(|_| "I couldn’t list recent project folders.".to_string())?;
            let choice = resolve_workspace_argument(argument, &choices)?;
            let label = choice.display_name.clone();
            Ok((
                ITEM_FOLDER,
                Some(BotSettingsValue::String(choice.workspace_id.to_string())),
                format!("Switched this conversation to {label}."),
            ))
        }
        _ => Err("Unknown settings command. Try /help.".to_string()),
    }
}

fn resolve_select_argument<'a>(
    argument: &str,
    options: impl Iterator<Item = (&'a str, &'a str, bool)>,
    kind: &str,
) -> Result<Option<String>, String> {
    if argument.eq_ignore_ascii_case("default") {
        return Ok(None);
    }
    let matches = options
        .filter(|(value, label, disabled)| {
            !*disabled
                && (value.eq_ignore_ascii_case(argument) || label.eq_ignore_ascii_case(argument))
        })
        .map(|(value, _, _)| value.to_string())
        .collect::<Vec<_>>();
    match matches.as_slice() {
        [value] => Ok(Some(value.clone())),
        [] => Err(format!(
            "That {kind} is not available. Run `/{}` to see choices.",
            kind_command(kind)
        )),
        _ => Err(format!("That {kind} is ambiguous. Use its exact value.")),
    }
}

fn kind_command(kind: &str) -> &str {
    match kind {
        "reasoning level" => "reasoning",
        "permission profile" => "permissions",
        other => other,
    }
}

fn resolve_workspace_argument<'a>(
    argument: &str,
    choices: &'a [WorkspaceChoice],
) -> Result<&'a WorkspaceChoice, String> {
    if let Ok(index) = argument.parse::<usize>() {
        return index
            .checked_sub(1)
            .and_then(|index| choices.get(index))
            .ok_or_else(|| {
                "That recent project number is not available. Run `/folder` again.".to_string()
            });
    }
    let matches = choices
        .iter()
        .filter(|choice| {
            choice.workspace_id.as_str() == argument
                || choice.display_name.eq_ignore_ascii_case(argument)
        })
        .collect::<Vec<_>>();
    match matches.as_slice() {
        [choice] => Ok(*choice),
        [] => Err("That recent project is not available. Run `/folder` again.".to_string()),
        _ => Err(
            "More than one recent project has that name. Use its number from `/folder`."
                .to_string(),
        ),
    }
}

fn format_setting_status<'a, I>(
    label: &str,
    selected: Option<&str>,
    options: Option<I>,
    usage: &str,
) -> String
where
    I: Iterator<Item = &'a str>,
{
    let choices = options
        .map(|values| values.take(16).collect::<Vec<_>>().join(", "))
        .filter(|values| !values.is_empty())
        .unwrap_or_else(|| "temporarily unavailable".to_string());
    format!(
        "{label}: {}. Choices: {choices}. Use `{usage}`.",
        display_selected(selected)
    )
}

fn display_selected(value: Option<&str>) -> &str {
    value.unwrap_or("provider default")
}

pub(super) fn permission_selection_label(
    selected: Option<&str>,
    catalog: Option<&DriverSettingsCatalog>,
) -> String {
    if let Some(selected) = selected {
        return catalog
            .and_then(|catalog| {
                catalog
                    .permissions
                    .iter()
                    .find(|option| option.value == selected)
            })
            .map_or_else(|| selected.to_string(), |option| option.label.clone());
    }
    catalog
        .and_then(|catalog| {
            let default = catalog.default_permissions.as_deref()?;
            catalog
                .permissions
                .iter()
                .find(|option| option.value == default)
        })
        .map_or_else(
            || "provider default".to_string(),
            |option| format!("{} (default)", option.label),
        )
}

fn command_message(message: impl Into<String>) -> SettingsCommandResult {
    SettingsCommandResult {
        message: message.into(),
        failure: None,
        provider_epoch_ended: false,
        choices: None,
    }
}

fn command_failed(message: &str, error: impl std::fmt::Display) -> SettingsCommandResult {
    SettingsCommandResult {
        message: message.to_string(),
        failure: Some(safe_diagnostic(&error.to_string())),
        provider_epoch_ended: false,
        choices: None,
    }
}

async fn resolve_settings_interaction<D: AgentDriver + 'static>(
    interaction: &BotInteractionEvent,
    runtime: &SettingsRuntime<'_, D>,
    snapshot: ConversationSnapshot,
) -> SettingsInteractionResolution {
    resolve_settings_interaction_with_deadline(interaction, runtime, snapshot, SETTINGS_DEADLINE)
        .await
}

async fn resolve_settings_interaction_with_deadline<D: AgentDriver + 'static>(
    interaction: &BotInteractionEvent,
    runtime: &SettingsRuntime<'_, D>,
    snapshot: ConversationSnapshot,
    deadline: Duration,
) -> SettingsInteractionResolution {
    let _provider_work_lease = match runtime.sessions.try_begin_provider_work() {
        Ok(Some(lease)) => lease,
        Ok(None) => {
            return SettingsInteractionResolution::normal(problem(
                BotChatSettingsProblemCode::Unavailable,
                "Inline is releasing the agent connection. Try Settings again in a moment.",
                None,
            ));
        }
        Err(error) => {
            eprintln!(
                "Agent settings provider admission failed: {}",
                safe_diagnostic(&error.to_string())
            );
            return SettingsInteractionResolution {
                response: problem(
                    BotChatSettingsProblemCode::Unavailable,
                    BridgeNotice::AgentConnectionLost.message(),
                    None,
                ),
                provider_epoch_ended: true,
            };
        }
    };
    let catalog = match tokio::time::timeout(
        deadline,
        runtime
            .sessions
            .settings_catalog(&snapshot.binding, now_seconds()),
    )
    .await
    {
        Ok(Ok(catalog)) => Some(catalog),
        Ok(Err(error)) if session_error_ends_provider_epoch(&error) => {
            eprintln!(
                "Agent settings catalog unavailable: {}",
                safe_diagnostic(&error.to_string())
            );
            return SettingsInteractionResolution {
                response: problem(
                    BotChatSettingsProblemCode::Unavailable,
                    BridgeNotice::AgentConnectionLost.message(),
                    None,
                ),
                provider_epoch_ended: true,
            };
        }
        Ok(Err(error)) => {
            eprintln!(
                "Agent settings catalog unavailable: {}",
                safe_diagnostic(&error.to_string())
            );
            None
        }
        Err(_) => {
            eprintln!("Agent settings catalog timed out");
            None
        }
    };
    let current = match runtime
        .store
        .chat_settings(&snapshot.binding, now_seconds())
    {
        Ok(settings) => settings,
        Err(error) => {
            eprintln!(
                "Agent settings state unavailable: {}",
                safe_diagnostic(&error.to_string())
            );
            return SettingsInteractionResolution::normal(problem(
                BotChatSettingsProblemCode::Unavailable,
                "Agent settings are temporarily unavailable.",
                None,
            ));
        }
    };
    let current_document =
        match build_settings_document(runtime, &snapshot, &current, catalog.as_ref()).await {
            Ok(document) => document,
            Err(error) => {
                eprintln!(
                    "Agent settings document failed: {}",
                    safe_diagnostic(&error.to_string())
                );
                return SettingsInteractionResolution::normal(problem(
                    BotChatSettingsProblemCode::Unavailable,
                    "Agent settings are temporarily unavailable.",
                    None,
                ));
            }
        };
    let BotInteractionEvent::ChatSettingsItemInvoked {
        item_id,
        value,
        document_revision,
        ..
    } = interaction
    else {
        return SettingsInteractionResolution::normal(BotChatSettingsResponse::Document(
            current_document,
        ));
    };
    if document_revision != &current_document.revision {
        return SettingsInteractionResolution::normal(problem(
            BotChatSettingsProblemCode::Stale,
            "Settings changed. Review the latest values and try again.",
            Some(current_document),
        ));
    }

    match apply_invocation(
        runtime,
        &snapshot,
        current,
        catalog.as_ref(),
        item_id,
        value.as_ref(),
    )
    .await
    {
        Ok(snapshot) => {
            let settings = match runtime
                .store
                .chat_settings(&snapshot.binding, now_seconds())
            {
                Ok(settings) => settings,
                Err(error) => {
                    eprintln!(
                        "Agent settings reload failed: {}",
                        safe_diagnostic(&error.to_string())
                    );
                    return SettingsInteractionResolution::normal(problem(
                        BotChatSettingsProblemCode::Failed,
                        "The change was applied, but settings could not be refreshed.",
                        None,
                    ));
                }
            };
            match build_settings_document(runtime, &snapshot, &settings, catalog.as_ref()).await {
                Ok(document) => SettingsInteractionResolution::normal(
                    BotChatSettingsResponse::Document(document),
                ),
                Err(error) => {
                    eprintln!(
                        "Agent settings refresh failed: {}",
                        safe_diagnostic(&error.to_string())
                    );
                    SettingsInteractionResolution::normal(problem(
                        BotChatSettingsProblemCode::Failed,
                        "The change was applied, but settings could not be refreshed.",
                        None,
                    ))
                }
            }
        }
        Err(failure) => SettingsInteractionResolution {
            response: failure.response,
            provider_epoch_ended: failure.provider_epoch_ended,
        },
    }
}

async fn apply_invocation<D: AgentDriver + 'static>(
    runtime: &SettingsRuntime<'_, D>,
    snapshot: &ConversationSnapshot,
    mut settings: ChatSettingsRecord,
    catalog: Option<&DriverSettingsCatalog>,
    item_id: &str,
    value: Option<&BotSettingsValue>,
) -> Result<ConversationSnapshot, SettingsInvocationFailure> {
    match item_id {
        ITEM_MODEL => {
            let Some(BotSettingsValue::String(value)) = value else {
                return Err(invalid_value("Choose a model from the list.").into());
            };
            let selected = setting_value(value);
            if let Some(selected) = selected.as_deref()
                && !catalog.is_some_and(|catalog| {
                    catalog.models.iter().any(|option| option.value == selected)
                })
            {
                return Err(invalid_value("That model is no longer available.").into());
            }
            settings.model = selected;
            settings.reasoning = None;
        }
        ITEM_REASONING => {
            let Some(BotSettingsValue::String(value)) = value else {
                return Err(invalid_value("Choose a reasoning level from the list.").into());
            };
            let selected = setting_value(value);
            if let Some(selected) = selected.as_deref()
                && !selected_model(catalog, settings.model.as_deref()).is_some_and(|model| {
                    model
                        .reasoning
                        .iter()
                        .any(|option| option.value == selected && !option.disabled)
                })
            {
                return Err(invalid_value("That reasoning level is no longer available.").into());
            }
            settings.reasoning = selected;
        }
        ITEM_PERMISSIONS => {
            let Some(BotSettingsValue::String(value)) = value else {
                return Err(invalid_value("Choose a permission profile from the list.").into());
            };
            let selected = setting_value(value);
            if let Some(selected) = selected.as_deref()
                && !catalog.is_some_and(|catalog| {
                    catalog
                        .permissions
                        .iter()
                        .any(|option| option.value == selected && !option.disabled)
                })
            {
                return Err(invalid_value("That permission profile is not available.").into());
            }
            settings.permissions = selected;
        }
        ITEM_REPLY_THREADS => {
            let Some(BotSettingsValue::String(value)) = value else {
                return Err(invalid_value("Choose Auto, On, or Off.").into());
            };
            let mode = match value.as_str() {
                "auto" => Some(ReplyThreadMode::Auto),
                "on" => Some(ReplyThreadMode::On),
                "off" => Some(ReplyThreadMode::Off),
                "reset" => None,
                _ => return Err(invalid_value("Choose Auto, On, or Off.").into()),
            };
            let policy = resolve_reply_thread_policy(
                runtime.store,
                &snapshot.binding.installation_id,
                &runtime.identity.bot_store,
                runtime.identity.reply_thread_default,
                snapshot.binding.chat_id,
            )
            .await
            .map_err(|error| {
                operation_failed("Couldn’t read reply-thread settings.", error, false)
            })?;
            return match runtime
                .store
                .update_reply_thread_override(
                    &snapshot.binding.installation_id,
                    policy.scope.scope_chat_id,
                    policy.override_revision,
                    mode,
                    now_seconds(),
                )
                .map_err(|error| {
                    operation_failed("Couldn’t save reply-thread settings.", error, false)
                })? {
                ReplyThreadOverrideUpdateOutcome::Applied(_) => Ok(snapshot.clone()),
                ReplyThreadOverrideUpdateOutcome::Stale(_) => {
                    let document = build_settings_document(runtime, snapshot, &settings, catalog)
                        .await
                        .map_err(|error| {
                            operation_failed("Couldn’t refresh settings.", error, false)
                        })?;
                    Err(problem(
                        BotChatSettingsProblemCode::Stale,
                        "Settings changed. Review the latest values and try again.",
                        Some(document),
                    )
                    .into())
                }
            };
        }
        ITEM_VERBOSE => {
            let Some(BotSettingsValue::Bool(value)) = value else {
                return Err(invalid_value("Choose whether Verbose mode is on or off.").into());
            };
            settings.verbose = *value;
        }
        ITEM_NEW | ITEM_CLEAR => {
            if runtime.turn_active {
                return Err(SettingsInvocationFailure::normal(problem(
                    BotChatSettingsProblemCode::Failed,
                    "Wait for the current turn to finish, or stop it first.",
                    None,
                )));
            }
            if runtime
                .store
                .session_thread_binding_for_chat(
                    &snapshot.binding.installation_id,
                    snapshot.binding.chat_id,
                )
                .map_err(|error| {
                    operation_failed("Couldn’t read this session thread.", error, false)
                })?
                .is_some()
            {
                return Err(SettingsInvocationFailure::normal(problem(
                    BotChatSettingsProblemCode::Failed,
                    "This thread is pinned to its Codex session. Open another session from the bot DM.",
                    None,
                )));
            }
            let _provider_work_lease = reserve_provider_mutation(runtime)?;
            runtime
                .sessions
                .rotate_session(&snapshot.binding, now_seconds())
                .await
                .map_err(|error| {
                    let provider_epoch_ended = session_error_ends_provider_epoch(&error);
                    operation_failed(
                        "Couldn’t start a fresh session.",
                        error,
                        provider_epoch_ended,
                    )
                })?;
            return Ok(snapshot.clone());
        }
        ITEM_COMPACT => {
            if runtime.turn_active {
                return Err(SettingsInvocationFailure::normal(problem(
                    BotChatSettingsProblemCode::Failed,
                    "Wait for the current turn to finish, or stop it first.",
                    None,
                )));
            }
            let _provider_work_lease = reserve_provider_mutation(runtime)?;
            if !runtime.sessions.driver().capabilities().compact_session {
                return Err(SettingsInvocationFailure::normal(problem(
                    BotChatSettingsProblemCode::InvalidValue,
                    BridgeNotice::SessionCompactionUnsupported.message(),
                    None,
                )));
            }
            let session = runtime
                .sessions
                .ensure_session(&snapshot.binding, now_seconds())
                .await
                .map_err(|error| {
                    let provider_epoch_ended = session_error_ends_provider_epoch(&error);
                    operation_failed(
                        "Couldn’t open the current session.",
                        error,
                        provider_epoch_ended,
                    )
                })?;
            if let Some(notice) = session_open_notice(&session) {
                return Err(SettingsInvocationFailure::normal(problem(
                    BotChatSettingsProblemCode::Failed,
                    notice.message(),
                    None,
                )));
            }
            runtime
                .sessions
                .driver()
                .compact_session(session.session_id())
                .await
                .map_err(|error| {
                    let provider_epoch_ended = error.ends_epoch();
                    operation_failed(
                        "Couldn’t compact the current session.",
                        error,
                        provider_epoch_ended,
                    )
                })?;
            return Ok(snapshot.clone());
        }
        ITEM_FOLDER => {
            if runtime.turn_active {
                return Err(SettingsInvocationFailure::normal(problem(
                    BotChatSettingsProblemCode::Failed,
                    "Wait for the current turn to finish, or stop it first.",
                    None,
                )));
            }
            if runtime
                .store
                .session_thread_binding_for_chat(
                    &snapshot.binding.installation_id,
                    snapshot.binding.chat_id,
                )
                .map_err(|error| {
                    operation_failed("Couldn’t read this session thread.", error, false)
                })?
                .is_some()
            {
                return Err(SettingsInvocationFailure::normal(problem(
                    BotChatSettingsProblemCode::Failed,
                    "This session thread is pinned to its Codex project. Choose a project in the bot DM, then open another session.",
                    None,
                )));
            }
            let Some(BotSettingsValue::String(value)) = value else {
                return Err(invalid_value("Choose a recent project folder.").into());
            };
            let workspace_id = WorkspaceId::new(value.clone())
                .map_err(|_| invalid_value("That project folder is not available."))?;
            let workspace = runtime
                .store
                .verified_workspace(
                    &snapshot.binding.installation_id,
                    &workspace_id,
                    now_seconds(),
                )
                .map_err(|error| {
                    operation_failed("Couldn’t load that project folder.", error, false)
                })?;
            runtime
                .store
                .bind_chat_workspace(
                    &snapshot.binding.installation_id,
                    snapshot.binding.chat_id,
                    &workspace_id,
                    now_seconds(),
                )
                .map_err(|error| {
                    operation_failed("Couldn’t select that project folder.", error, false)
                })?;
            let next = ConversationSnapshot {
                binding: BindingKey {
                    installation_id: snapshot.binding.installation_id.clone(),
                    chat_id: snapshot.binding.chat_id,
                    workspace_id,
                },
                workspace: workspace.path,
            };
            runtime
                .active
                .replace(next.binding.clone(), next.workspace.clone());
            return Ok(next);
        }
        _ => return Err(invalid_value("That setting is no longer available.").into()),
    }

    match runtime
        .store
        .update_chat_settings(settings.revision, &settings, now_seconds())
        .map_err(|error| operation_failed("Couldn’t save that setting.", error, false))?
    {
        SettingsUpdateOutcome::Applied(_) => Ok(snapshot.clone()),
        SettingsUpdateOutcome::Stale(current) => {
            let document = build_settings_document(runtime, snapshot, &current, catalog)
                .await
                .map_err(|error| operation_failed("Couldn’t refresh settings.", error, false))?;
            Err(problem(
                BotChatSettingsProblemCode::Stale,
                "Settings changed. Review the latest values and try again.",
                Some(document),
            )
            .into())
        }
    }
}

fn reserve_provider_mutation<D: AgentDriver + 'static>(
    runtime: &SettingsRuntime<'_, D>,
) -> Result<inline_agent_bridge::ProviderWorkLease, SettingsInvocationFailure> {
    match runtime.sessions.try_begin_provider_work() {
        Ok(Some(lease)) => Ok(lease),
        Ok(None) => Err(SettingsInvocationFailure::normal(problem(
            BotChatSettingsProblemCode::Unavailable,
            "Inline is releasing the agent connection. Try again in a moment.",
            None,
        ))),
        Err(error) => {
            let provider_epoch_ended = session_error_ends_provider_epoch(&error);
            Err(operation_failed(
                "The agent connection restarted. Try again.",
                error,
                provider_epoch_ended,
            ))
        }
    }
}

async fn build_settings_document<D: AgentDriver + 'static>(
    runtime: &SettingsRuntime<'_, D>,
    snapshot: &ConversationSnapshot,
    settings: &ChatSettingsRecord,
    catalog: Option<&DriverSettingsCatalog>,
) -> Result<BotChatSettingsDocument, Box<dyn std::error::Error>> {
    let reply_threads = resolve_reply_thread_policy(
        runtime.store,
        &snapshot.binding.installation_id,
        &runtime.identity.bot_store,
        runtime.identity.reply_thread_default,
        snapshot.binding.chat_id,
    )
    .await?;
    let choices = runtime.store.recent_workspace_choices(
        &snapshot.binding.installation_id,
        Some(&snapshot.binding.workspace_id),
    )?;
    let model = selected_model(catalog, settings.model.as_deref());
    let model_options = select_options(
        catalog.map(|catalog| {
            catalog.models.iter().map(|model| {
                (
                    model.value.as_str(),
                    model.label.as_str(),
                    model.description.as_deref(),
                    false,
                )
            })
        }),
        settings.model.as_deref(),
        "Provider default",
    );
    let reasoning_options = select_options(
        model.map(|model| {
            model.reasoning.iter().map(|option| {
                (
                    option.value.as_str(),
                    option.label.as_str(),
                    option.description.as_deref(),
                    option.disabled,
                )
            })
        }),
        settings.reasoning.as_deref(),
        model
            .and_then(|model| model.default_reasoning.as_deref())
            .map_or("Provider default".to_string(), |value| {
                format!("Provider default ({value})")
            })
            .as_str(),
    );
    let permission_default_label = catalog
        .and_then(|catalog| {
            catalog.default_permissions.as_deref().and_then(|default| {
                catalog
                    .permissions
                    .iter()
                    .find(|option| option.value == default)
            })
        })
        .map_or_else(
            || "Provider default".to_string(),
            |option| format!("{} (default)", option.label),
        );
    let permission_options = select_options(
        catalog.map(|catalog| {
            catalog.permissions.iter().map(|option| {
                (
                    option.value.as_str(),
                    option.label.as_str(),
                    option.description.as_deref(),
                    option.disabled,
                )
            })
        }),
        settings.permissions.as_deref(),
        &permission_default_label,
    );
    let catalog_reason = catalog
        .is_none()
        .then(|| "Provider options are temporarily unavailable.".to_string());
    let active_reason = runtime
        .turn_active
        .then(|| "Available after the current turn finishes.".to_string());
    let session_thread_pinned = runtime
        .store
        .session_thread_binding_for_chat(
            &snapshot.binding.installation_id,
            snapshot.binding.chat_id,
        )?
        .is_some();
    let session_rotation_reason = active_reason.clone().or_else(|| {
        session_thread_pinned.then(|| "This thread is pinned to its Codex session.".to_string())
    });
    let project_reason = active_reason.clone().or_else(|| {
        session_thread_pinned
            .then(|| "This session thread is pinned to its Codex project.".to_string())
    });
    let compact_supported = runtime.sessions.driver().capabilities().compact_session;
    Ok(BotChatSettingsDocument {
        version: SETTINGS_VERSION,
        revision: document_revision(settings, reply_threads),
        sections: vec![
            BotChatSettingsSection {
                id: "agent".to_string(),
                title: Some("Agent".to_string()),
                description: Some("Changes apply to the next turn.".to_string()),
                items: vec![
                    select_item(
                        ITEM_MODEL,
                        "Model",
                        settings.model.as_deref().unwrap_or(DEFAULT_VALUE),
                        model_options,
                        catalog_reason.clone(),
                    ),
                    select_item(
                        ITEM_REASONING,
                        "Reasoning",
                        settings.reasoning.as_deref().unwrap_or(DEFAULT_VALUE),
                        reasoning_options,
                        catalog_reason.clone().or_else(|| {
                            model
                                .is_some_and(|model| model.reasoning.is_empty())
                                .then(|| {
                                    "This model does not expose reasoning choices.".to_string()
                                })
                        }),
                    ),
                    select_item(
                        ITEM_PERMISSIONS,
                        "Permissions",
                        settings.permissions.as_deref().unwrap_or(DEFAULT_VALUE),
                        permission_options,
                        catalog_reason.clone().or_else(|| {
                            catalog
                                .is_some_and(|catalog| catalog.permissions.is_empty())
                                .then(|| {
                                    "This provider does not expose permission profiles.".to_string()
                                })
                        }),
                    ),
                    BotChatSettingsItem {
                        id: ITEM_VERBOSE.to_string(),
                        label: Some("Verbose".to_string()),
                        description: Some("Show more tool and command detail.".to_string()),
                        disabled: false,
                        disabled_reason: None,
                        control: BotChatSettingsControl::Toggle {
                            value: settings.verbose,
                        },
                    },
                ],
            },
            BotChatSettingsSection {
                id: "conversation".to_string(),
                title: Some("Conversation".to_string()),
                description: Some(
                    "An anchored reply thread inherits this parent chat's setting.".to_string(),
                ),
                items: vec![BotChatSettingsItem {
                    id: ITEM_REPLY_THREADS.to_string(),
                    label: Some("Reply in threads".to_string()),
                    description: Some(format!(
                        "Effective from {}. Existing reply threads always stay in place.",
                        reply_threads.source.label()
                    )),
                    disabled: false,
                    disabled_reason: None,
                    control: BotChatSettingsControl::Select {
                        value: reply_threads.mode.as_str().to_string(),
                        options: vec![
                            BotChatSettingsSelectOption {
                                value: "auto".to_string(),
                                label: "Auto".to_string(),
                                description: Some(
                                    "Keep DMs and fresh chats flat; thread established chats contextually."
                                        .to_string(),
                                ),
                                disabled: false,
                            },
                            BotChatSettingsSelectOption {
                                value: "on".to_string(),
                                label: "On".to_string(),
                                description: Some(
                                    "Start or reuse a reply thread for top-level requests."
                                        .to_string(),
                                ),
                                disabled: false,
                            },
                            BotChatSettingsSelectOption {
                                value: "off".to_string(),
                                label: "Off".to_string(),
                                description: Some(
                                    "Keep top-level replies in this conversation.".to_string(),
                                ),
                                disabled: false,
                            },
                        ],
                    },
                }],
            },
            BotChatSettingsSection {
                id: "session".to_string(),
                title: Some("Session".to_string()),
                description: None,
                items: vec![
                    button_item(ITEM_NEW, "New Session", session_rotation_reason.clone()),
                    button_item(ITEM_CLEAR, "Clear", session_rotation_reason),
                    button_item(
                        ITEM_COMPACT,
                        "Compact",
                        active_reason.clone().or_else(|| {
                            (!compact_supported)
                                .then(|| "This provider does not support compaction.".to_string())
                        }),
                    ),
                ],
            },
            BotChatSettingsSection {
                id: "project".to_string(),
                title: Some("Project".to_string()),
                description: None,
                items: vec![BotChatSettingsItem {
                    id: ITEM_FOLDER.to_string(),
                    label: Some("Folder".to_string()),
                    description: Some("Recent folders on the bridge host.".to_string()),
                    disabled: project_reason.is_some(),
                    disabled_reason: project_reason,
                    control: BotChatSettingsControl::Folder(BotChatSettingsFolder {
                        value: snapshot.binding.workspace_id.to_string(),
                        recent_folders: folder_options(choices),
                        host_installation_id: runtime.identity.host_installation_id.clone(),
                        host_label: runtime.identity.host_label.clone(),
                        allows_local_picker: runtime.identity.workspace_picker.is_some(),
                        local_picker_port: runtime
                            .identity
                            .workspace_picker
                            .as_ref()
                            .map(|endpoint| endpoint.port as u32),
                        local_picker_capability: runtime
                            .identity
                            .workspace_picker
                            .as_ref()
                            .map(|endpoint| endpoint.capability.clone()),
                    }),
                }],
            },
            BotChatSettingsSection {
                id: "status".to_string(),
                title: Some("Status".to_string()),
                description: None,
                items: vec![BotChatSettingsItem {
                    id: "status.bridge".to_string(),
                    label: Some("Bridge".to_string()),
                    description: None,
                    disabled: true,
                    disabled_reason: None,
                    control: BotChatSettingsControl::Info {
                        text: format!("Connected · {}", workspace_label(&snapshot.workspace)),
                        tone: BotChatSettingsInfoTone::Success,
                    },
                }],
            },
        ],
    })
}

fn selected_model<'a>(
    catalog: Option<&'a DriverSettingsCatalog>,
    selected: Option<&str>,
) -> Option<&'a inline_agent_bridge::DriverModelOption> {
    let catalog = catalog?;
    selected
        .and_then(|selected| catalog.models.iter().find(|model| model.value == selected))
        .or_else(|| catalog.models.iter().find(|model| model.is_default))
        .or_else(|| catalog.models.first())
}

fn select_options<'a, I>(
    options: Option<I>,
    selected: Option<&str>,
    default_label: &str,
) -> Vec<BotChatSettingsSelectOption>
where
    I: Iterator<Item = (&'a str, &'a str, Option<&'a str>, bool)>,
{
    let mut values = vec![BotChatSettingsSelectOption {
        value: DEFAULT_VALUE.to_string(),
        label: default_label.to_string(),
        description: None,
        disabled: false,
    }];
    if let Some(options) = options {
        values.extend(options.map(|(value, label, description, disabled)| {
            BotChatSettingsSelectOption {
                value: value.to_string(),
                label: label.to_string(),
                description: description.map(str::to_string),
                disabled,
            }
        }));
    }
    if let Some(selected) = selected
        && !values.iter().any(|option| option.value == selected)
    {
        values.push(BotChatSettingsSelectOption {
            value: selected.to_string(),
            label: "Unavailable choice".to_string(),
            description: Some("Choose another value to replace it.".to_string()),
            disabled: true,
        });
    }
    values
}

fn select_item(
    id: &str,
    label: &str,
    value: &str,
    options: Vec<BotChatSettingsSelectOption>,
    disabled_reason: Option<String>,
) -> BotChatSettingsItem {
    BotChatSettingsItem {
        id: id.to_string(),
        label: Some(label.to_string()),
        description: None,
        disabled: disabled_reason.is_some(),
        disabled_reason,
        control: BotChatSettingsControl::Select {
            value: value.to_string(),
            options,
        },
    }
}

fn button_item(id: &str, label: &str, disabled_reason: Option<String>) -> BotChatSettingsItem {
    BotChatSettingsItem {
        id: id.to_string(),
        label: Some(label.to_string()),
        description: None,
        disabled: disabled_reason.is_some(),
        disabled_reason,
        control: BotChatSettingsControl::Button,
    }
}

fn folder_options(choices: Vec<WorkspaceChoice>) -> Vec<BotChatSettingsFolderOption> {
    choices
        .into_iter()
        .map(|choice| BotChatSettingsFolderOption {
            value: choice.workspace_id.to_string(),
            label: choice.display_name,
            parent_hint: choice.parent_hint,
            disabled: false,
        })
        .collect()
}

fn setting_value(value: &str) -> Option<String> {
    (value != DEFAULT_VALUE).then(|| value.to_string())
}

fn document_revision(
    settings: &ChatSettingsRecord,
    reply_threads: EffectiveReplyThreadPolicy,
) -> String {
    format!(
        "settings-v2-{}-{}-{}-{}-{}",
        settings.binding.workspace_id,
        settings.revision,
        reply_threads.scope.scope_chat_id,
        reply_threads.mode.as_str(),
        reply_threads.override_revision.unwrap_or_default(),
    )
}

fn invalid_value(message: &str) -> BotChatSettingsResponse {
    problem(BotChatSettingsProblemCode::InvalidValue, message, None)
}

fn operation_failed(
    message: &str,
    error: impl std::fmt::Display,
    provider_epoch_ended: bool,
) -> SettingsInvocationFailure {
    eprintln!(
        "Agent settings operation failed: {}",
        safe_diagnostic(&error.to_string())
    );
    SettingsInvocationFailure {
        response: problem(BotChatSettingsProblemCode::Failed, message, None),
        provider_epoch_ended,
    }
}

fn session_error_ends_provider_epoch(error: &SessionManagerError) -> bool {
    matches!(error, SessionManagerError::Driver(error) if error.ends_epoch())
}

fn problem(
    code: BotChatSettingsProblemCode,
    message: &str,
    current_document: Option<BotChatSettingsDocument>,
) -> BotChatSettingsResponse {
    BotChatSettingsResponse::Problem(BotChatSettingsProblem {
        code,
        message: message.to_string(),
        current_document,
    })
}

#[cfg(test)]
mod tests;
