//! Durable admission behavior while a provider is unavailable, plus queue undo handling.

use super::*;

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
        "stop" if command.arguments.is_empty() => "Nothing is running.".to_string(),
        "queue" => return Ok(false),
        "follow" | "unfollow" | "allowlist" => return Ok(false),
        "help" | "status" | "stop" => format!("/{} doesn’t take arguments. Try /help.", command.name),
        "new" | "clear" | "compact" | "folder" | "model" | "reasoning" | "permissions"
        | "verbose" | "threads" => {
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

fn ensure_unavailable_command_started(
    store: &BridgeStore,
    record: &InboundRecord,
) -> Result<bool, Box<dyn std::error::Error>> {
    if !store.accept_inbound(record)? {
        return Ok(false);
    }
    Ok(store.start_inbound(&record.event_id, now_seconds())?)
}

pub(in crate::bridge) async fn accept_provider_unavailable_delivery(
    bot: &InlineClient,
    delivery: LosslessEventDelivery,
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
    if handle_unavailable_settings_event(bot, delivery.event(), route.owner_user_id).await? {
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
    if let Some(record) = inbound_from_delivery(bot, &delivery, route).await? {
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
            && accept_or_resume_queued_confirmation(&route.store, &record)?
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
