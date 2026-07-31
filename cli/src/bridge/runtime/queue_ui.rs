//! Queue acknowledgement selection and its undoable Inline confirmation.

use super::*;

/// Accepts new work or recognizes a previously accepted delivery whose
/// idempotent queue acknowledgement still needs to be retried. This closes the
/// crash window between durable inbox insertion and Inline send/ACK.
pub(in crate::bridge) fn accept_or_resume_queued_confirmation(
    store: &BridgeStore,
    record: &InboundRecord,
) -> inline_agent_bridge::StoreResult<bool> {
    if store.accept_inbound(record)? {
        return Ok(true);
    }
    Ok(store
        .get_inbound(&record.event_id)?
        .is_some_and(|stored| stored.state == InboundState::Accepted))
}

pub(super) fn coordinator_acknowledgement(
    effects: &[CoordinatorEffect],
) -> Option<Acknowledgement> {
    effects.iter().find_map(|effect| match effect {
        CoordinatorEffect::Acknowledge { acknowledgement } => Some(*acknowledgement),
        _ => None,
    })
}

pub(super) fn queue_acknowledgement(disposition: DirectionDisposition) -> Option<Acknowledgement> {
    match disposition {
        DirectionDisposition::Queued => Some(Acknowledgement::Queued),
        DirectionDisposition::QueuedBecauseSteeringUnsupported => {
            Some(Acknowledgement::QueuedBecauseSteeringUnsupported)
        }
        DirectionDisposition::Started => Some(Acknowledgement::Working),
        DirectionDisposition::Steered => None,
    }
}

pub(super) async fn send_queue_confirmation(
    bot: &InlineClient,
    record: &InboundRecord,
    message_text: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let data = serde_json::to_vec(&QueueUndoCallback {
        version: 1,
        event_id: record.event_id.clone(),
    })?;
    let mut message = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(record.binding.chat_id),
        },
        message_text,
    );
    message.reply_to_message_id = Some(InlineId::new(record.message_id));
    message.external_id = Some(ExternalId::try_new(
        "agent-bridge",
        format!("{}-queue-confirmed", record.event_id),
    )?);
    message.notification_mode = BridgeNotificationClass::RoutineStatus.notification_mode();
    send_interactive_text_with_retry(
        bot,
        SendInteractiveTextRequest {
            message,
            actions: MessageActions {
                rows: vec![MessageActionRow {
                    actions: vec![MessageActionButton {
                        action_id: "bridge_queue_undo".to_string(),
                        text: "Undo".to_string(),
                        kind: MessageActionKind::Callback { data },
                    }],
                }],
            },
        },
    )
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record() -> InboundRecord {
        InboundRecord {
            event_id: "inline-message-10-20".to_string(),
            binding: BindingKey {
                installation_id: InstallationId::new("codex").expect("installation"),
                chat_id: 10,
                workspace_id: WorkspaceId::new("workspace").expect("workspace"),
            },
            message_id: 20,
            delivery_chat_id: 10,
            sender_user_id: 7,
            direction: Direction::new(
                DirectionId::new("inline-message-10-20").expect("direction"),
                "work",
            ),
            state: InboundState::Accepted,
            accepted_at: 10,
            started_at: None,
            lease_expires_at: None,
            attempt_count: 0,
            provider_turn_id: None,
            stream_message_id: None,
            failure: None,
        }
    }

    #[test]
    fn retries_confirmation_after_accept_before_send_crash() {
        let store = BridgeStore::open_in_memory().expect("store");
        let record = record();
        assert!(accept_or_resume_queued_confirmation(&store, &record).expect("accept"));
        assert!(accept_or_resume_queued_confirmation(&store, &record).expect("retry"));

        let started = store
            .take_next_inbound(&record.binding, 20)
            .expect("take")
            .expect("started");
        assert_eq!(started.event_id, record.event_id);
        assert!(!accept_or_resume_queued_confirmation(&store, &record).expect("started replay"));
    }

    #[test]
    fn native_steering_is_silent_but_queue_fallbacks_are_visible() {
        assert_eq!(queue_acknowledgement(DirectionDisposition::Steered), None);
        assert_eq!(
            queue_acknowledgement(DirectionDisposition::QueuedBecauseSteeringUnsupported),
            Some(Acknowledgement::QueuedBecauseSteeringUnsupported)
        );
    }
}
