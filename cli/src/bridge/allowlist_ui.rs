//! Owner-only operator allowlist commands and durable callbacks.

use super::*;

const ALLOWLIST_TTL_SECONDS: i64 = 10 * 60;

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum AllowlistCallbackDecision {
    Allow,
    Cancel,
}

#[derive(Debug, Serialize, Deserialize)]
struct AllowlistCallback {
    version: u32,
    token: String,
    decision: AllowlistCallbackDecision,
}

pub(super) async fn handle_allowlist_command(
    bot: &InlineClient,
    record: &InboundRecord,
    route: &InboundRoute,
) -> Result<bool, Box<dyn std::error::Error>> {
    let Ok(Some(command)) = parse_command(&record.direction.text, &route.bot_username) else {
        return Ok(false);
    };
    if command.name != "allowlist" {
        return Ok(false);
    }
    if !ensure_command_inbound_started(&route.store, record)? {
        return Ok(true);
    }
    let result = handle_allowlist_command_inner(bot, record, route, &command.arguments).await;
    match result {
        Ok(()) => {
            route.store.complete_inbound(&record.event_id)?;
            Ok(true)
        }
        Err(error) => {
            route
                .store
                .fail_inbound(&record.event_id, "allowlist command failed")?;
            Err(error)
        }
    }
}

async fn handle_allowlist_command_inner(
    bot: &InlineClient,
    record: &InboundRecord,
    route: &InboundRoute,
    arguments: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    if record.sender_user_id != route.owner_user_id {
        return send_allowlist_reply(
            bot,
            record,
            "Only the bot owner can change who may drive this agent.",
            "owner-only",
        )
        .await;
    }
    let parts = arguments.split_whitespace().collect::<Vec<_>>();
    let target_user_id = match parts.as_slice() {
        [value] => value.parse::<i64>().ok().filter(|value| *value > 0),
        _ => None,
    };
    let Some(target_user_id) = target_user_id else {
        return send_allowlist_reply(bot, record, "Usage: /allowlist <userid>", "usage").await;
    };
    if route.allows(target_user_id) {
        return send_allowlist_reply(
            bot,
            record,
            "That user is already allowed to drive this agent.",
            "already-allowed",
        )
        .await;
    }
    let owner_user = match route.owner_control.as_deref() {
        Some(owner_control) => owner_control.user(target_user_id).await?,
        None => None,
    };
    let user = match owner_user {
        Some(user) => Some(user),
        None => route.bot_store.user(InlineId::new(target_user_id)).await?,
    };
    let Some(user) = user else {
        return send_allowlist_reply(
            bot,
            record,
            "I can’t find that user in Inline yet. Check the user ID and try again.",
            "user-missing",
        )
        .await;
    };
    if user.is_bot == Some(true) {
        return send_allowlist_reply(
            bot,
            record,
            "Bots cannot be added as agent operators.",
            "bot-rejected",
        )
        .await;
    }
    let full_name = allowlist_user_full_name(&user).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline user has no display name",
        )
    })?;
    let username = user
        .username
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| format!("@{value}"))
        .unwrap_or_else(|| "No username".to_string());
    let token = generate_control_token();
    let now = now_seconds();
    if !route
        .store
        .insert_operator_allowlist_request(&PendingOperatorAllowlistRequest {
            callback_token: token.clone(),
            installation_id: route.installation_id.clone(),
            provider_id: route.provider_id.clone(),
            owner_user_id: route.owner_user_id,
            target_user_id,
            origin_chat_id: record.binding.chat_id,
            created_at: now,
            expires_at: now.saturating_add(ALLOWLIST_TTL_SECONDS),
        })?
    {
        return Err(io::Error::other("allowlist request token collision").into());
    }
    let actions = MessageActions {
        rows: vec![MessageActionRow {
            actions: vec![
                allowlist_button("allow", "Allow", &token, AllowlistCallbackDecision::Allow)?,
                allowlist_button(
                    "cancel",
                    "Cancel",
                    &token,
                    AllowlistCallbackDecision::Cancel,
                )?,
            ],
        }],
    };
    let mut message = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(record.binding.chat_id),
        },
        format!(
            "Allow **{}** ({}) — user ID `{}` — to drive this agent?",
            truncate(&full_name.replace('*', ""), 120),
            truncate(&username, 80),
            target_user_id
        ),
    );
    message.reply_to_message_id = Some(InlineId::new(record.message_id));
    message.external_id = Some(ExternalId::try_new(
        "agent-bridge",
        format!("allowlist-{token}"),
    )?);
    message.random_id = Some(interaction_random_id("allowlist", &token));
    message.notification_mode = BridgeNotificationClass::ActionRequired.notification_mode();
    let mutation =
        send_interactive_text_with_retry(bot, SendInteractiveTextRequest { message, actions })
            .await?;
    let message_id = mutation.message_id.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::ConnectionAborted,
            "allowlist publication completed without a message identity",
        )
    })?;
    route
        .store
        .attach_operator_allowlist_message(&token, message_id.get())?;
    Ok(())
}

pub(super) async fn handle_allowlist_action(
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
    let Ok(callback) = serde_json::from_slice::<AllowlistCallback>(data) else {
        return Ok(false);
    };
    if callback.version != 1 {
        return Ok(false);
    }
    let decision = match callback.decision {
        AllowlistCallbackDecision::Allow => OperatorAllowlistDecision::Allow,
        AllowlistCallbackDecision::Cancel => OperatorAllowlistDecision::Cancel,
    };
    let outcome = route.store.claim_operator_allowlist_request(
        &callback.token,
        decision,
        &OperatorAllowlistClaimContext {
            installation_id: route.installation_id.clone(),
            provider_id: route.provider_id.clone(),
            actor_user_id: actor_user_id.get(),
            action_chat_id: chat_id.get(),
            action_message_id: message_id.get(),
            event_id: format!("inline-action-{}-{}", chat_id.get(), interaction_id.get()),
            now: now_seconds(),
        },
    )?;
    let (toast, terminal) = match outcome {
        OperatorAllowlistClaimOutcome::Claimed(request)
        | OperatorAllowlistClaimOutcome::Resumable(request) => {
            match add_operator_for_provider(
                route.owner_user_id,
                route.provider_id.as_str(),
                request.target_user_id,
            ) {
                Ok(policy) => {
                    route.replace_policy(policy);
                    route.store.finish_operator_allowlist_request(
                        &callback.token,
                        true,
                        now_seconds(),
                    )?;
                    (
                        "Allowed",
                        Some(format!(
                            "User ID `{}` can now drive this agent.",
                            request.target_user_id
                        )),
                    )
                }
                Err(error) => {
                    route.store.finish_operator_allowlist_request(
                        &callback.token,
                        false,
                        now_seconds(),
                    )?;
                    eprintln!(
                        "Could not update operator policy: {}",
                        safe_diagnostic(&error.to_string())
                    );
                    (
                        "Couldn’t update the allowlist",
                        Some("The allowlist was not changed.".to_string()),
                    )
                }
            }
        }
        OperatorAllowlistClaimOutcome::Cancelled(_) => {
            ("Cancelled", Some("Allowlist change cancelled.".to_string()))
        }
        OperatorAllowlistClaimOutcome::Unauthorized => {
            ("Only the bot owner can approve this.", None)
        }
        OperatorAllowlistClaimOutcome::Unknown
        | OperatorAllowlistClaimOutcome::WrongContext
        | OperatorAllowlistClaimOutcome::Expired
        | OperatorAllowlistClaimOutcome::NotPending(_) => {
            ("This request is no longer active.", None)
        }
    };
    bot.answer_message_action(inline_client::AnswerMessageActionRequest {
        interaction_id: *interaction_id,
        toast: Some(toast.to_string()),
    })
    .await?;
    if let Some(terminal) = terminal {
        clear_approval(bot, chat_id.get(), *message_id, &terminal).await?;
    }
    Ok(true)
}

fn ensure_command_inbound_started(
    store: &BridgeStore,
    record: &InboundRecord,
) -> Result<bool, Box<dyn std::error::Error>> {
    match store.get_inbound(&record.event_id)? {
        Some(existing) if existing.state == InboundState::Started => Ok(true),
        Some(existing) if existing.state == InboundState::Accepted => {
            Ok(store.start_inbound(&record.event_id, now_seconds())?)
        }
        Some(_) => Ok(false),
        None => {
            if !store.accept_inbound(record)? {
                return Ok(false);
            }
            Ok(store.start_inbound(&record.event_id, now_seconds())?)
        }
    }
}

fn allowlist_button(
    action_id: &str,
    text: &str,
    token: &str,
    decision: AllowlistCallbackDecision,
) -> Result<MessageActionButton, serde_json::Error> {
    Ok(MessageActionButton {
        action_id: format!("bridge_allowlist_{action_id}"),
        text: text.to_string(),
        kind: MessageActionKind::Callback {
            data: serde_json::to_vec(&AllowlistCallback {
                version: 1,
                token: token.to_string(),
                decision,
            })?,
        },
    })
}

fn allowlist_user_full_name(user: &inline_client::UserRecord) -> Option<String> {
    let structured = [user.first_name.as_deref(), user.last_name.as_deref()]
        .into_iter()
        .flatten()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    if !structured.is_empty() {
        Some(structured)
    } else {
        user.display_name
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
    }
}

async fn send_allowlist_reply(
    bot: &InlineClient,
    record: &InboundRecord,
    text: &str,
    suffix: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    send_text_reply(
        bot,
        record.binding.chat_id,
        record.message_id,
        text,
        &format!("{}-allowlist-{suffix}", record.event_id),
        BridgeNotificationClass::RoutineStatus,
    )
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn callback_buttons_are_exact_and_distinct() {
        let allow = allowlist_button("allow", "Allow", "token", AllowlistCallbackDecision::Allow)
            .expect("allow");
        let cancel = allowlist_button(
            "cancel",
            "Cancel",
            "token",
            AllowlistCallbackDecision::Cancel,
        )
        .expect("cancel");
        assert_eq!(allow.text, "Allow");
        assert_eq!(cancel.text, "Cancel");
        assert_ne!(allow.action_id, cancel.action_id);
    }
}
