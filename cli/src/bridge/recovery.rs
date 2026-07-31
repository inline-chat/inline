//! Durable turn recovery shared by process startup and in-process provider restart.

use super::*;

#[derive(Clone, Copy, Debug)]
pub(super) enum InterruptionKind {
    BridgeRestart,
    ProviderRestart,
}

impl InterruptionKind {
    fn failure(self) -> &'static str {
        match self {
            Self::BridgeRestart => "bridge process restarted during the turn",
            Self::ProviderRestart => "local agent disconnected during the turn",
        }
    }

    fn message(self) -> &'static str {
        match self {
            Self::BridgeRestart => {
                "This turn was interrupted when the bridge restarted. Send it again if you still want me to continue."
            }
            Self::ProviderRestart => {
                "This turn was interrupted when the local agent disconnected. Send it again after the agent reconnects."
            }
        }
    }
}

pub(super) async fn recover_provider_inbox(
    bot: &InlineClient,
    store: &BridgeStore,
    installation_id: &InstallationId,
    interruption: InterruptionKind,
) -> Result<(), Box<dyn std::error::Error>> {
    for request in store
        .expire_open_command_choice_requests_for_installation(installation_id, now_seconds())?
    {
        let message_id = match request.card_message_id.map(InlineId::new) {
            Some(message_id) => message_id,
            None => {
                resolve_interaction_message(
                    bot,
                    request.origin_chat_id,
                    "settings-choice",
                    &request.callback_token,
                    "This choice request expired when the local bridge restarted.",
                )
                .await?
            }
        };
        if let Err(error) = clear_approval(
            bot,
            request.origin_chat_id,
            message_id,
            "This choice request expired when the local bridge restarted. Run the command again.",
        )
        .await
        {
            eprintln!(
                "Could not clear a stale command choice message: {}",
                safe_diagnostic(&error.to_string())
            );
        }
    }
    for approval in store.open_approvals_for_installation(installation_id)? {
        if approval.message_id.is_none() {
            let message_id = resolve_interaction_message(
                bot,
                approval.action_chat_id,
                "approval",
                &approval.callback_token,
                "This approval request expired when the local bridge restarted.",
            )
            .await?;
            store.attach_approval_message(&approval.callback_token, message_id.get())?;
        }
    }
    for approval in
        store.invalidate_open_approvals_for_installation(installation_id, now_seconds())?
    {
        if let Some(message_id) = approval.message_id.map(InlineId::new)
            && let Err(error) = clear_approval(
                bot,
                approval.action_chat_id,
                message_id,
                "This approval request expired when the local bridge restarted.",
            )
            .await
        {
            eprintln!(
                "Could not clear a stale approval message: {}",
                safe_diagnostic(&error.to_string())
            );
        }
        if let Err(error) = clear_shared_approval_status(
            bot,
            &approval,
            "Approval request expired when the local bridge restarted.",
        )
        .await
        {
            eprintln!(
                "Could not clear a stale shared approval status: {}",
                safe_diagnostic(&error.to_string())
            );
        }
    }

    for question in store.open_questions_for_installation(installation_id)? {
        if question.message_id.is_none() {
            let message_id = resolve_interaction_message(
                bot,
                question.chat_id,
                "question",
                &question.callback_token,
                "This question is no longer active because the local bridge restarted.",
            )
            .await?;
            store.attach_question_message(&question.callback_token, message_id.get())?;
        }
    }
    store.invalidate_open_questions_for_installation(installation_id, now_seconds())?;
    for question in store.questions_requiring_ui_cleanup_for_installation(installation_id, 1_000)? {
        let Some(message_id) = question.message_id.map(InlineId::new) else {
            continue;
        };
        if try_update_question_message(
            bot,
            question.chat_id,
            message_id,
            question.state.terminal_text(),
        )
        .await
        .is_ok()
        {
            store.mark_question_ui_cleared(&question.callback_token, now_seconds())?;
        }
    }
    store.stage_interrupted_inbound_for_installation(
        installation_id,
        interruption.failure(),
        interruption.message(),
    )?;

    recover_pending_final_sends_with_transport(
        &InlineStreamMessageTransport(bot),
        store,
        installation_id,
        message_retry_delay,
    )
    .await
}

pub(super) async fn resolve_interaction_message(
    bot: &InlineClient,
    chat_id: i64,
    kind: &str,
    token: &str,
    terminal_text: &str,
) -> Result<InlineId, Box<dyn std::error::Error>> {
    let mut request = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(chat_id),
        },
        terminal_text,
    );
    request.external_id = Some(ExternalId::try_new(
        "agent-bridge",
        format!("{kind}-{token}"),
    )?);
    request.random_id = Some(interaction_random_id(kind, token));
    request.notification_mode = BridgeNotificationClass::RoutineStatus.notification_mode();
    send_text_with_retry(bot, request)
        .await?
        .message_id
        .ok_or_else(|| {
            io::Error::other("interaction send completed without a message identity").into()
        })
}

pub(super) async fn recover_pending_final_sends_with_transport<T: StreamMessageTransport>(
    transport: &T,
    store: &BridgeStore,
    installation_id: &InstallationId,
    retry_delay: impl Fn(u32) -> Duration + Copy,
) -> Result<(), Box<dyn std::error::Error>> {
    for pending in store.pending_inbound_final_sends(installation_id)? {
        let terminal_random_id = match pending.terminal_random_id {
            Some(random_id) => Some(random_id),
            None => store.ensure_inbound_final_send_random_id(
                &pending.event_id,
                new_terminal_random_id().get(),
            )?,
        }
        .map(RandomId::new)
        .ok_or_else(|| io::Error::other("staged final send is missing its random identity"))?;
        let durable_progress = store.inbound_progress(&pending.event_id)?;
        let tracker = durable_progress
            .ledger_json
            .as_deref()
            .and_then(|ledger| ActivityTracker::from_durable_json(ledger).ok())
            .unwrap_or_default();
        let fallback_header = match pending.state {
            InboundState::Completed => "Worked",
            InboundState::Failed => "Failed",
            _ => "Stopped",
        };
        let progress_header = tracker.terminal_header().unwrap_or(fallback_header);
        let chunks = tracker.render_chunks(tracker.visibility_mode(), progress_header, None);
        let mut progress_message_ids = durable_progress
            .message_ids
            .into_iter()
            .map(InlineId::new)
            .collect::<Vec<_>>();
        if progress_message_ids.is_empty()
            && let Some(message_id) = pending.stream_message_id.map(InlineId::new)
        {
            let stored = store
                .attach_inbound_progress_message(&pending.event_id, 0, message_id.get())?
                .map(InlineId::new)
                .unwrap_or(message_id);
            progress_message_ids.push(stored);
        }
        sync_progress_with_transport(
            transport,
            store,
            &pending.event_id,
            pending.delivery_chat_id,
            &mut progress_message_ids,
            &chunks,
            "Continued",
            retry_delay,
        )
        .await?;
        let progress_message_id = progress_message_ids.first().copied();
        if pending.stream_message_id.is_none()
            && let Some(message_id) = progress_message_id
        {
            store.attach_inbound_stream_message(&pending.event_id, message_id.get())?;
        }
        deliver_pending_final_with_attachments_transport(
            transport,
            &pending.event_id,
            pending.delivery_chat_id,
            progress_message_id,
            chunks
                .first()
                .map(String::as_str)
                .unwrap_or(progress_header),
            terminal_random_id,
            &pending.final_text,
            &pending.output_attachments,
            retry_delay,
        )
        .await?;
        if !store.commit_inbound_final_send(&pending.event_id)? {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "staged turn disappeared before recovery commit",
            )
            .into());
        }
    }

    Ok(())
}
