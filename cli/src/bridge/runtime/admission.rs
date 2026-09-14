//! Durable admission behavior while a provider is unavailable, plus queue undo handling.

use super::*;

pub(super) fn accept_inbound_or_session_handoff(
    route: &InboundRoute,
    record: &InboundRecord,
) -> Result<bool, StoreError> {
    if is_linked_codex_stop(route, record)? {
        route.store.accept_session_handoff(record)
    } else {
        accept_or_resume_queued_confirmation(&route.store, record)
    }
}

pub(super) async fn handle_follow_command(
    bot: &InlineClient,
    record: &InboundRecord,
    route: &InboundRoute,
) -> Result<bool, Box<dyn std::error::Error>> {
    let Ok(Some(command)) = parse_command(&record.direction.text, &route.bot_username) else {
        return Ok(false);
    };
    if !matches!(command.name.as_str(), "follow" | "unfollow") {
        return Ok(false);
    }
    if !route.store.claim_event(&record.event_id, now_seconds())? {
        return Ok(true);
    }
    let reply = if !command.arguments.is_empty() {
        format!("Usage: /{}", command.name)
    } else if record.sender_user_id != route.owner_user_id {
        "Only the bot owner can change follow mode.".to_string()
    } else if record.binding.chat_id == route.owner_dm_chat_id {
        "This DM is always active; follow mode isn’t needed here.".to_string()
    } else if let Some(owner_control) = route.owner_control.as_deref() {
        let (mode, confirmation) = if command.name == "follow" {
            (DialogFollowMode::Following, "Following this conversation.")
        } else {
            (
                DialogFollowMode::Unfollowed,
                "No longer following this conversation.",
            )
        };
        match owner_control
            .set_follow_mode(record.binding.chat_id, mode)
            .await
        {
            Ok(()) => confirmation.to_string(),
            Err(error) => {
                eprintln!(
                    "Owner follow update failed: {}",
                    safe_diagnostic(&error.to_string())
                );
                "I couldn’t change follow mode. Try again shortly.".to_string()
            }
        }
    } else {
        "Follow controls are unavailable. Run setup again to repair them.".to_string()
    };
    send_inbound_response(
        bot,
        route,
        record,
        record.binding.chat_id,
        &reply,
        &format!("{}-follow-result", record.event_id),
        BridgeNotificationClass::RoutineStatus,
    )
    .await?;
    Ok(true)
}

async fn handle_provider_unavailable_command(
    bot: &InlineClient,
    record: &InboundRecord,
    route: &InboundRoute,
) -> Result<bool, Box<dyn std::error::Error>> {
    let Ok(Some(command)) = parse_command(&record.direction.text, &route.bot_username) else {
        return Ok(false);
    };
    if command.explicit_target && !command.targets_this_bot {
        return Ok(false);
    }
    let message = match command.name.as_str() {
        "help" if command.arguments.is_empty() => static_command_help(&route.provider_id),
        "status" if command.arguments.is_empty() => {
            "Agent is connected to Inline, but its local provider is restarting. New work will remain queued."
                .to_string()
        }
        "stop" if is_linked_codex_stop(route, record)? => return Ok(false),
        "stop" if command.arguments.is_empty() => "Nothing is running.".to_string(),
        "queue" => return Ok(false),
        "follow" | "unfollow" | "allowlist" => return Ok(false),
        "help" | "status" | "stop" => format!("/{} doesn’t take arguments. Try /help.", command.name),
        "folder" | "projects" => {
            return handle_provider_unavailable_workspace_command(bot, record, route, &command)
                .await;
        }
        "new" | "clear" | "compact" | "sessions" | "open" | "resume" | "close" | "model"
        | "reasoning" | "permissions" | "verbose" | "threads" => {
            "That control is temporarily unavailable while the local provider restarts. Try again shortly."
                .to_string()
        }
        "" => "I couldn’t parse that command. Try /help.".to_string(),
        _ => return Ok(false),
    };
    if ensure_unavailable_command_started(&route.store, record)? {
        send_inbound_response(
            bot,
            route,
            record,
            record.binding.chat_id,
            &message,
            &format!("{}-unavailable-command", record.event_id),
            BridgeNotificationClass::RoutineStatus,
        )
        .await?;
        route.store.complete_inbound(&record.event_id)?;
    }
    Ok(true)
}

async fn handle_provider_unavailable_workspace_command(
    bot: &InlineClient,
    record: &InboundRecord,
    route: &InboundRoute,
    command: &CommandInvocation,
) -> Result<bool, Box<dyn std::error::Error>> {
    if !ensure_unavailable_command_started(&route.store, record)? {
        return Ok(true);
    }
    let command_name = if command.name == "projects" {
        "projects"
    } else {
        "folder"
    };
    let provider_name = provider_display_name(route.provider_id.as_str()).unwrap_or("The provider");
    let message = if record.sender_user_id != route.owner_user_id
        || record.binding.chat_id != route.owner_dm_chat_id
    {
        "Open the bot's private DM as its owner to choose a project.".to_string()
    } else if route
        .store
        .session_thread_binding_for_chat(&route.installation_id, record.binding.chat_id)?
        .is_some()
    {
        "This session thread is pinned to its provider project. Choose a project in the bot DM, then open another session."
            .to_string()
    } else {
        let choices = route
            .store
            .recent_workspace_choices(&route.installation_id, Some(&record.binding.workspace_id))?;
        if command.arguments.trim().is_empty() {
            let list = choices
                .iter()
                .enumerate()
                .map(|(index, choice)| {
                    let hint = choice
                        .parent_hint
                        .as_deref()
                        .map_or(String::new(), |hint| format!(" — {hint}"));
                    format!("{}. {}{hint}", index + 1, choice.display_name)
                })
                .collect::<Vec<_>>()
                .join("; ");
            format!(
                "Projects remain available while {provider_name} restarts. Recent: {list}. Use `/{command_name} <number|name>`."
            )
        } else {
            match resolve_workspace_argument(command.arguments.trim(), &choices) {
                Ok(choice) => {
                    let selected = route.store.bind_chat_workspace(
                        &route.installation_id,
                        record.binding.chat_id,
                        &choice.workspace_id,
                        now_seconds(),
                    )?;
                    format!(
                        "Switched this conversation to {}. New work will use it after {provider_name} reconnects.",
                        selected.display_name
                    )
                }
                Err(message) => message.replace("`/folder", &format!("`/{command_name}")),
            }
        }
    };
    send_inbound_response(
        bot,
        route,
        record,
        record.binding.chat_id,
        &message,
        &format!("{}-provider-restart-project", record.event_id),
        BridgeNotificationClass::RoutineStatus,
    )
    .await?;
    route.store.complete_inbound(&record.event_id)?;
    Ok(true)
}

fn ensure_unavailable_command_started(
    store: &BridgeStore,
    record: &InboundRecord,
) -> Result<bool, Box<dyn std::error::Error>> {
    if !store.accept_inbound(record)? {
        return Ok(false);
    }
    Ok(store.start_inbound(&record.event_id, now_seconds())?)
}

/// Settles one delivery-local failure without allowing it to own provider or
/// account liveness. Accepted work stays in the existing durable inbox; a
/// request that never reached that boundary gets a best-effort retry notice.
/// The delivery is then acknowledged so a deterministic poison event cannot
/// head-of-line block later work.
pub(in crate::bridge) async fn recover_failed_delivery(
    bot: &InlineClient,
    delivery: &LosslessEventDelivery,
    route: &InboundRoute,
    phase: &'static str,
    error: &(dyn std::error::Error + 'static),
) {
    crate::telemetry::report_bridge_runtime_error(route.provider_id.as_str(), phase, error, None);
    eprintln!(
        "Bridge delivery failed during {phase}; continuing with later work: {}",
        safe_diagnostic(&error.to_string())
    );

    let notice_result = if let ClientEvent::MessageStored { message } = delivery.event() {
        let event_id = format!("inline-message-{}-{}", message.chat_id, message.message_id);
        match route.store.get_inbound(&event_id) {
            Ok(Some(record)) if record.state == InboundState::Accepted => {
                send_queue_confirmation(bot, &record, Acknowledgement::Queued.message()).await
            }
            Ok(Some(_)) => Ok(()),
            Ok(None) | Err(_) => {
                let sender_is_bot = message.is_outgoing
                    || message_sender_is_bot(&route.bot_store, message)
                        .await
                        .unwrap_or(true);
                if route.allows(message.sender_id.get()) && !sender_is_bot {
                    send_text_reply(
                        bot,
                        message.chat_id.get(),
                        message.message_id.get(),
                        "I couldn’t process that request, so I skipped it to keep later messages moving. Please try again.",
                        &format!("{event_id}-delivery-skipped"),
                        BridgeNotificationClass::ImportantFailure,
                    )
                    .await
                    .map(|_| ())
                } else {
                    Ok(())
                }
            }
        }
    } else {
        Ok(())
    };
    if let Err(notice_error) = notice_result {
        eprintln!(
            "Bridge delivery recovery notice failed; still advancing the delivery: {}",
            safe_diagnostic(&notice_error.to_string())
        );
    }
    if let Err(ack_error) = delivery.ack().await {
        eprintln!(
            "Bridge delivery recovery acknowledgement failed; it can retry without stopping later work: {}",
            safe_diagnostic(&ack_error.to_string())
        );
    }
}

pub(in crate::bridge) async fn accept_provider_unavailable_delivery(
    bot: &InlineClient,
    delivery: &LosslessEventDelivery,
    route: &InboundRoute,
) -> Result<(), Box<dyn std::error::Error>> {
    if handle_claude_history_action(bot, delivery.event(), route).await? {
        delivery.ack().await?;
        return Ok(());
    }
    if handle_claude_history_import_thread_message(bot, delivery.event(), route).await? {
        delivery.ack().await?;
        return Ok(());
    }
    if handle_allowlist_action(bot, delivery.event(), route).await? {
        delivery.ack().await?;
        return Ok(());
    }
    if handle_provider_unavailable_settings_event(bot, delivery.event(), route).await? {
        delivery.ack().await?;
        return Ok(());
    }
    if handle_provider_unavailable_session_browser_action(bot, delivery.event(), route).await? {
        delivery.ack().await?;
        return Ok(());
    }
    if handle_queue_undo_action(bot, delivery.event(), route).await? {
        delivery.ack().await?;
        return Ok(());
    }
    if let ClientEvent::MessageActionInvoked {
        interaction_id,
        actor_user_id,
        ..
    } = delivery.event()
    {
        let toast = if actor_user_id.get() == route.owner_user_id {
            "This request is no longer active."
        } else {
            "Only the bot owner can approve this."
        };
        bot.answer_message_action(inline_client::AnswerMessageActionRequest {
            interaction_id: *interaction_id,
            toast: Some(toast.to_string()),
        })
        .await?;
        delivery.ack().await?;
        return Ok(());
    }
    if let Some(record) = inbound_from_delivery(bot, delivery, route).await? {
        if handle_claude_history_command(bot, &record, route).await? {
            delivery.ack().await?;
            return Ok(());
        }
        if handle_allowlist_command(bot, &record, route).await? {
            delivery.ack().await?;
            return Ok(());
        }
        if handle_provider_unavailable_command(bot, &record, route).await? {
            delivery.ack().await?;
            return Ok(());
        }
        if !handle_follow_command(bot, &record, route).await?
            && accept_inbound_or_session_handoff(route, &record)?
        {
            send_text_reply(
                bot,
                record.binding.chat_id,
                record.message_id,
                BridgeNotice::ProviderRestartingQueued.message(),
                &format!("{}-provider-restarting", record.event_id),
                BridgeNotificationClass::RoutineStatus,
            )
            .await?;
        }
    }
    delivery.ack().await?;
    Ok(())
}

pub(super) async fn handle_queue_undo_action(
    bot: &InlineClient,
    event: &ClientEvent,
    route: &InboundRoute,
) -> Result<bool, Box<dyn std::error::Error>> {
    let ClientEvent::MessageActionInvoked {
        interaction_id,
        chat_id,
        message_id,
        actor_user_id,
        data,
        ..
    } = event
    else {
        return Ok(false);
    };
    let Ok(callback) = serde_json::from_slice::<QueueUndoCallback>(data) else {
        return Ok(false);
    };
    if callback.version != 1 {
        return Ok(false);
    }
    let outcome = route.store.undo_accepted_inbound(
        &callback.event_id,
        &route.installation_id,
        chat_id.get(),
        actor_user_id.get(),
    )?;
    let (toast, replacement) = match outcome {
        InboundUndoOutcome::Removed => ("Removed", Some("Removed from the queue.")),
        InboundUndoOutcome::Unauthorized => ("Only the person who queued this can undo it.", None),
        InboundUndoOutcome::WrongContext | InboundUndoOutcome::Unknown => {
            ("This queue item is no longer available.", None)
        }
        InboundUndoOutcome::AlreadyStarted => ("Already started", Some("Already started.")),
    };
    bot.answer_message_action(inline_client::AnswerMessageActionRequest {
        interaction_id: *interaction_id,
        toast: Some(toast.to_string()),
    })
    .await?;
    if let Some(replacement) = replacement {
        clear_approval(bot, chat_id.get(), *message_id, replacement).await?;
    }
    Ok(true)
}
