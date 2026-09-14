//! Retry an unstarted request after repairing its project in Agent settings.

use super::*;

const SETTINGS_RETRY_ACTION: &str = "bridge_settings_retry";

pub(super) async fn send_workspace_recovery(
    bot: &InlineClient,
    source: &MessageRecord,
    event_id: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut message = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: source.chat_id,
        },
        "This project folder isn’t available. Choose a project or No project in Agent settings, then retry your request.",
    );
    message.reply_to_message_id = Some(source.message_id);
    message.external_id = Some(ExternalId::try_new(
        "agent-bridge",
        format!("{event_id}-missing-workspace"),
    )?);
    message.notification_mode = BridgeNotificationClass::ImportantFailure.notification_mode();
    send_interactive_text_with_retry(
        bot,
        SendInteractiveTextRequest {
            message,
            actions: MessageActions {
                rows: vec![MessageActionRow {
                    actions: vec![MessageActionButton {
                        action_id: SETTINGS_RETRY_ACTION.to_string(),
                        text: "Retry".to_string(),
                        kind: MessageActionKind::Callback {
                            data: b"bridge-settings-retry-v1".to_vec(),
                        },
                    }],
                }],
            },
        },
    )
    .await?;
    Ok(())
}

pub(super) async fn handle_settings_retry(
    bot: &InlineClient,
    event: &ClientEvent,
    route: &InboundRoute,
) -> Result<bool, Box<dyn std::error::Error>> {
    let ClientEvent::MessageActionInvoked {
        interaction_id,
        chat_id,
        message_id,
        actor_user_id,
        action_id,
        data,
        ..
    } = event
    else {
        return Ok(false);
    };
    if action_id != SETTINGS_RETRY_ACTION || data != b"bridge-settings-retry-v1" {
        return Ok(false);
    }
    // Resolve the original request through our own card, not callback-supplied IDs.
    let card = route.bot_store.message(*chat_id, *message_id).await?;
    let source_id = card
        .filter(|card| {
            card.sender_id.get() == route.bot_user_id
                && card
                    .metadata
                    .actions
                    .iter()
                    .any(|action| action.action_id == SETTINGS_RETRY_ACTION)
        })
        .and_then(|card| card.reply_to_message_id);
    let source = match source_id {
        Some(id) => route.bot_store.message(*chat_id, id).await?,
        None => None,
    };
    let toast = match source.filter(|source| {
        route.allows(actor_user_id.get())
            && (source.sender_id == *actor_user_id || actor_user_id.get() == route.owner_user_id)
    }) {
        Some(source)
            if route
                .store
                .get_inbound(&format!(
                    "inline-message-{}-{}",
                    source.chat_id, source.message_id
                ))?
                .is_some() =>
        {
            "This request has already been received."
        }
        Some(source) => match inbound_from_message(bot, &source, route, true).await? {
            Some(record) if accept_inbound_or_session_handoff(route, &record)? => "Request queued.",
            Some(_) => "This request has already been received.",
            None => "Choose an available project or No project in Agent settings, then retry.",
        },
        None => "This request is unavailable or you don’t have access to retry it.",
    };
    bot.answer_message_action(inline_client::AnswerMessageActionRequest {
        interaction_id: *interaction_id,
        toast: Some(toast.to_string()),
    })
    .await?;
    Ok(true)
}
