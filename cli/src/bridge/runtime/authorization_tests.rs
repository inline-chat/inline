use super::*;
use inline_client::{
    AuthCredential, AuthToken, ClientBackend, ConnectRequest, DialogRecord, HistoryRequest,
    InMemoryBackend, LosslessEventReceiver, MessageEntityRecord, MessageMetadata,
};

#[derive(Default)]
struct PublicInputDriver {
    inputs: std::sync::Mutex<Vec<TurnInput>>,
    answer: String,
    hold_completion: bool,
    pending_events: std::sync::Mutex<Option<inline_agent_bridge::AgentEventSender>>,
}

impl AgentDriver for PublicInputDriver {
    fn capabilities(&self) -> inline_agent_bridge::DriverCapabilities {
        inline_agent_bridge::DriverCapabilities {
            resume_session: true,
            steering: SteeringSupport::Native,
            ..Default::default()
        }
    }
    fn start_session<'a>(
        &'a self,
        _: inline_agent_bridge::SessionSpec,
    ) -> inline_agent_bridge::DriverFuture<'a, inline_agent_bridge::ProviderSessionId> {
        Box::pin(async {
            Ok(inline_agent_bridge::ProviderSessionId::new("public-input-test-session").unwrap())
        })
    }
    fn resume_session<'a>(
        &'a self,
        _: inline_agent_bridge::ResumeSessionSpec,
    ) -> inline_agent_bridge::DriverFuture<'a, ()> {
        Box::pin(async { Ok(()) })
    }
    fn start_turn<'a>(
        &'a self,
        _: &'a inline_agent_bridge::ProviderSessionId,
        input: TurnInput,
        _: TurnOptions,
    ) -> inline_agent_bridge::DriverFuture<'a, inline_agent_bridge::StartedTurn> {
        Box::pin(async move {
            self.inputs.lock().unwrap().push(input);
            let turn_id = inline_agent_bridge::TurnId::new("public-input-test-turn").unwrap();
            let (sender, events) = inline_agent_bridge::AgentEventReceiver::default_channel();
            if self.hold_completion {
                *self.pending_events.lock().unwrap() = Some(sender);
            } else {
                sender.send(Ok(AgentEvent::AgentTextCompleted {
                    turn_id: turn_id.clone(),
                    text: self.answer.clone(),
                }));
                sender.send(Ok(AgentEvent::TurnCompleted {
                    turn_id: turn_id.clone(),
                    outcome: TurnOutcome::Completed,
                    error: None,
                    timing: TurnTiming::default(),
                }));
            }
            Ok(inline_agent_bridge::StartedTurn { turn_id, events })
        })
    }
    fn steer_turn<'a>(
        &'a self,
        _: &'a inline_agent_bridge::ProviderSessionId,
        _: &'a inline_agent_bridge::TurnId,
        input: TurnInput,
    ) -> inline_agent_bridge::DriverFuture<'a, ()> {
        Box::pin(async move {
            self.inputs.lock().unwrap().push(input);
            Ok(())
        })
    }
    fn cancel_turn<'a>(
        &'a self,
        _: &'a inline_agent_bridge::ProviderSessionId,
        _: &'a inline_agent_bridge::TurnId,
    ) -> inline_agent_bridge::DriverFuture<'a, ()> {
        Box::pin(async { Ok(()) })
    }
    fn resolve_approval<'a>(
        &'a self,
        _: &'a str,
        _: ApprovalDecision,
    ) -> inline_agent_bridge::DriverFuture<'a, ()> {
        Box::pin(async { Ok(()) })
    }
    fn shutdown(&self) -> inline_agent_bridge::DriverFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn compact_session<'a>(
        &'a self,
        _: &'a inline_agent_bridge::ProviderSessionId,
    ) -> inline_agent_bridge::DriverFuture<'a, inline_agent_bridge::StartedTurn> {
        Box::pin(async { Err(DriverError::Unsupported("test compaction")) })
    }
}

impl SessionCatalogSource for PublicInputDriver {
    fn session_catalog(
        &self,
        _: inline_agent_bridge::ProviderInstanceRef,
        _: WorkspaceId,
        _: &Path,
    ) -> inline_agent_bridge::DriverResult<Option<Box<dyn inline_agent_bridge::AgentSessionCatalog>>>
    {
        Ok(None)
    }
}

#[tokio::test]
async fn provider_payload_uses_verified_public_records_and_omits_stale_cache_and_unverified_reply()
{
    let route = route("acp");
    let (bot, backend, _) = client().await;
    let mut trigger = message(7, Some(false), "current authenticated direction");
    trigger.reply_to_message_id = Some(InlineId::new(1));
    trigger.metadata.revision = Some(1);
    let mut old_reply = message(8, Some(false), "revoked cached quote");
    old_reply.message_id = InlineId::new(1);
    route.bot_store.record_message(old_reply).await.unwrap();
    let mut deleted = message(8, Some(false), "deleted cached excerpt");
    deleted.message_id = InlineId::new(3);
    route.bot_store.record_message(deleted).await.unwrap();
    let mut other_bot = message(98, Some(true), "fresh other bot public evidence");
    other_bot.message_id = InlineId::new(2);
    other_bot.metadata.revision = Some(2);
    other_bot.metadata.agent_session = Some(inline_client::AgentSessionMessageMetadata {
        agent_session_id: 999,
        provider: proto::AgentSessionProvider::Codex as i32,
        role: proto::AgentSessionMessageRole::Assistant as i32,
        relation: proto::AgentSessionMessageRelation::Linked as i32,
    });
    backend.insert_message(other_bot.clone());
    other_bot.content = MessageContent::Text {
        text: "stale bot cache".to_string(),
    };
    route.bot_store.record_message(other_bot).await.unwrap();
    backend.insert_message(trigger.clone());
    route
        .bot_store
        .record_message(trigger.clone())
        .await
        .unwrap();
    let record = inbound_from_message(&bot, &trigger, &route, true)
        .await
        .unwrap()
        .unwrap();
    route.store.accept_inbound(&record).unwrap();
    let record = route
        .store
        .take_next_inbound(&record.binding, 2)
        .unwrap()
        .unwrap();
    let driver = Arc::new(PublicInputDriver::default());
    let manager = ProviderSessionManager::new(
        driver.clone(),
        route.store.clone(),
        route.provider_id.clone(),
    );
    prepare_public_context_input(
        &bot,
        &manager,
        &route,
        &record,
        &record.binding,
        &record.direction.text,
    )
    .await
    .unwrap();
    manager
        .start_admitted_turn(&record.event_id, &record.binding, 3, TurnOptions::default())
        .await
        .unwrap();
    let input = driver.inputs.lock().unwrap()[0].text.clone();
    assert!(input.contains("fresh other bot public evidence"));
    assert!(!input.contains("stale bot cache"));
    assert!(!input.contains("deleted cached excerpt"));
    assert!(!input.contains("revoked cached quote"));
    assert!(input.contains("replied-to message could not be verified"));
    assert!(input.ends_with("current authenticated direction"));
    let snapshot = route
        .store
        .context_input(&record.event_id)
        .unwrap()
        .unwrap()
        .0;
    assert_eq!(snapshot.messages.len(), 2);
    assert!(
        snapshot
            .messages
            .iter()
            .all(|source| source.message_id != 1 && source.message_id != 3)
    );
    bot.shutdown().await.unwrap();
}

#[tokio::test]
async fn edited_source_cannot_consume_a_new_revision_while_sending_frozen_old_instructions() {
    let route = route("acp");
    let (bot, backend, _) = client().await;
    let mut original = message(7, Some(false), "original revision one instruction");
    original.metadata.revision = Some(1);
    original.metadata.source_snapshot = Some("public-snapshot-one".to_string());
    let record = inbound_from_message(&bot, &original, &route, true)
        .await
        .unwrap()
        .unwrap();
    route.store.accept_inbound(&record).unwrap();
    let queued = route
        .store
        .take_next_inbound(&record.binding, 2)
        .unwrap()
        .unwrap();
    assert_eq!(
        queued.direction.source_version,
        record.direction.source_version
    );
    let mut edited = original.clone();
    edited.content = MessageContent::Text {
        text: "new revision two instruction".to_string(),
    };
    edited.metadata.revision = Some(2);
    edited.metadata.source_snapshot = Some("public-snapshot-two".to_string());
    route
        .bot_store
        .record_message(edited.clone())
        .await
        .unwrap();
    backend.insert_message(edited);
    let driver = Arc::new(PublicInputDriver::default());
    let manager = ProviderSessionManager::new(
        driver.clone(),
        route.store.clone(),
        route.provider_id.clone(),
    );
    assert!(
        prepare_public_context_input(
            &bot,
            &manager,
            &route,
            &queued,
            &queued.binding,
            &queued.direction.text
        )
        .await
        .is_err()
    );
    assert!(
        route
            .store
            .context_input(&record.event_id)
            .unwrap()
            .is_none()
    );
    assert!(driver.inputs.lock().unwrap().is_empty());
    bot.shutdown().await.unwrap();
}

#[tokio::test]
async fn source_snapshot_enrichment_preserves_original_lineage_and_never_becomes_fresh_steering() {
    let route = route("acp");
    let (bot, backend, _) = client().await;
    let mut source = message(7, Some(false), "original public request");
    source.metadata.revision = Some(1);
    source.metadata.source_snapshot = Some("original-public-snapshot".to_string());
    let mut record = inbound_from_message(&bot, &source, &route, true)
        .await
        .unwrap()
        .unwrap();
    record.direction.text = format!("Trusted specialization\n{}", record.direction.text);
    route.store.accept_inbound(&record).unwrap();
    let record = route
        .store
        .take_next_inbound(&record.binding, 2)
        .unwrap()
        .unwrap();
    backend.insert_message(source.clone());
    let driver = Arc::new(PublicInputDriver::default());
    let manager = ProviderSessionManager::new(
        driver.clone(),
        route.store.clone(),
        route.provider_id.clone(),
    );
    prepare_public_context_input(
        &bot,
        &manager,
        &route,
        &record,
        &record.binding,
        &record.direction.text,
    )
    .await
    .unwrap();
    let snapshot = route
        .store
        .context_input(&record.event_id)
        .unwrap()
        .unwrap()
        .0;
    assert_eq!(
        snapshot.messages[0].source_snapshot.as_deref(),
        Some("original-public-snapshot")
    );
    let (session, turn, _lease) = manager
        .start_admitted_turn(&record.event_id, &record.binding, 3, TurnOptions::default())
        .await
        .unwrap();
    source.metadata.source_snapshot = Some("enriched-public-snapshot".to_string());
    assert!(
        steer_active_source_edit(
            &bot,
            &source,
            &manager,
            session.session_id(),
            &turn.turn_id,
            &route.store,
            &route
        )
        .await
        .unwrap()
    );
    assert_eq!(
        driver.inputs.lock().unwrap().len(),
        1,
        "lineage-only enrichment is not fresh steering"
    );
    assert!(
        route
            .store
            .get_inbound("inline-message-706-9-edit-1")
            .unwrap()
            .is_none()
    );
    bot.shutdown().await.unwrap();
}

#[tokio::test]
async fn same_text_rich_changes_with_missing_or_unchanged_token_never_reach_provider() {
    use inline_client::{MediaKind, MessageActionRecord, MessageAttachmentRecord};
    for token in [None, Some("unchanged-server-token")] {
        for mutation in [
            "media",
            "readiness",
            "entity",
            "agent",
            "reply",
            "card",
            "action",
        ] {
            let route = route("acp");
            let (bot, backend, _) = client().await;
            let mut source = message(8, Some(false), "current direction");
            mention(&mut source);
            source.metadata.source_snapshot = token.map(str::to_string);
            source.metadata.attachments.push(MessageAttachmentRecord {
                attachment_id: InlineId::new(1),
                kind: "external_task".into(),
                title: Some("Original card".into()),
                provider: Some("Tracker".into()),
                url: Some("https://example.test/task/1".into()),
            });
            source.metadata.actions.push(MessageActionRecord {
                action_id: "opaque-action".into(),
                label: "Review".into(),
                kind: "callback".into(),
            });
            if matches!(mutation, "media" | "readiness") {
                source.content = MessageContent::Media {
                    kind: MediaKind::Photo,
                    file_id: "photo:1".into(),
                    url: Some("https://cdn.test/photo".into()),
                    mime_type: Some("image/png".into()),
                    file_name: Some("photo.png".into()),
                    caption: Some("current direction".into()),
                    size_bytes: Some(12),
                    width: Some(3),
                    height: Some(4),
                    duration_ms: None,
                };
            }
            let record = inbound_from_message(&bot, &source, &route, true)
                .await
                .unwrap()
                .unwrap();
            route.store.accept_inbound(&record).unwrap();
            let record = route
                .store
                .take_next_inbound(&record.binding, 2)
                .unwrap()
                .unwrap();
            match mutation {
                "media" => {
                    if let MessageContent::Media { file_id, .. } = &mut source.content {
                        *file_id = "photo:2".into()
                    }
                }
                "readiness" => {
                    if let MessageContent::Media { url, .. } = &mut source.content {
                        *url = None
                    }
                }
                "entity" => source.metadata.entities[0].user_id = Some(InlineId::new(98)),
                "agent" => source.metadata.entities[0].agent_id = Some(InlineId::new(73)),
                "reply" => source.reply_to_message_id = Some(InlineId::new(1)),
                "card" => source.metadata.attachments[0].title = Some("Replaced card".into()),
                "action" => source.metadata.actions[0].label = "Different action".into(),
                _ => unreachable!(),
            }
            backend.insert_message(source);
            let driver = Arc::new(PublicInputDriver::default());
            let manager = ProviderSessionManager::new(
                driver.clone(),
                route.store.clone(),
                route.provider_id.clone(),
            );
            assert!(
                prepare_public_context_input(
                    &bot,
                    &manager,
                    &route,
                    &record,
                    &record.binding,
                    &record.direction.text
                )
                .await
                .is_err(),
                "{token:?}/{mutation}"
            );
            assert!(
                route
                    .store
                    .context_input(&record.event_id)
                    .unwrap()
                    .is_none()
            );
            assert!(
                manager
                    .start_admitted_turn(
                        &record.event_id,
                        &record.binding,
                        3,
                        TurnOptions::default()
                    )
                    .await
                    .is_err()
            );
            assert!(
                driver.inputs.lock().unwrap().is_empty(),
                "{token:?}/{mutation}"
            );
            bot.shutdown().await.unwrap();
        }
    }
}

#[tokio::test]
async fn missing_legacy_source_proof_never_authorizes_a_queued_provider_input() {
    for whole_version_missing in [true, false] {
        let route = route("acp");
        let (bot, backend, _) = client().await;
        let source = message(8, Some(false), "request from an allowed human");
        let mut record = inbound_from_message(&bot, &source, &route, true)
            .await
            .unwrap()
            .unwrap();
        if whole_version_missing {
            record.direction.source_version = None;
        } else {
            record
                .direction
                .source_version
                .as_mut()
                .unwrap()
                .visible_fingerprint = None;
        }
        route.store.accept_inbound(&record).unwrap();
        let record = route
            .store
            .take_next_inbound(&record.binding, 2)
            .unwrap()
            .unwrap();
        backend.insert_message(source);
        let driver = Arc::new(PublicInputDriver::default());
        let manager = ProviderSessionManager::new(
            driver.clone(),
            route.store.clone(),
            route.provider_id.clone(),
        );
        assert!(
            prepare_public_context_input(
                &bot,
                &manager,
                &route,
                &record,
                &record.binding,
                &record.direction.text
            )
            .await
            .is_err()
        );
        assert!(
            manager
                .start_admitted_turn(&record.event_id, &record.binding, 3, TurnOptions::default())
                .await
                .is_err()
        );
        assert!(driver.inputs.lock().unwrap().is_empty());
        bot.shutdown().await.unwrap();
    }
}

#[tokio::test]
async fn delayed_pre_reset_trigger_is_refused_but_new_explicit_request_can_quote_old_public_material()
 {
    let route = route("acp");
    let (bot, backend, _) = client().await;
    let driver = Arc::new(PublicInputDriver::default());
    let manager = ProviderSessionManager::new(
        driver.clone(),
        route.store.clone(),
        route.provider_id.clone(),
    );
    let binding = conversation_for_chat(&route, 706)
        .unwrap()
        .snapshot()
        .binding;
    manager.ensure_session(&binding, 1).await.unwrap();
    manager.rotate_session(&binding, 100).await.unwrap();
    // This old physical message was not in the inbox when reset captured its ID floor.
    let mut delayed = message(8, Some(false), "old physical direction");
    delayed.timestamp = 99;
    backend.insert_message(delayed.clone());
    let record = inbound_from_message(&bot, &delayed, &route, true)
        .await
        .unwrap()
        .unwrap();
    route.store.accept_inbound(&record).unwrap();
    let record = route
        .store
        .take_next_inbound(&binding, 101)
        .unwrap()
        .unwrap();
    assert!(
        prepare_public_context_input(
            &bot,
            &manager,
            &route,
            &record,
            &binding,
            &record.direction.text
        )
        .await
        .is_err()
    );
    assert!(
        manager
            .start_admitted_turn(&record.event_id, &binding, 101, TurnOptions::default())
            .await
            .is_err()
    );
    assert!(driver.inputs.lock().unwrap().is_empty());
    route
        .store
        .fail_inbound(&record.event_id, "old trigger refused")
        .unwrap();
    let mut quote = message(8, Some(false), "old explicitly quoted public canary");
    quote.message_id = InlineId::new(1);
    quote.timestamp = 50;
    backend.insert_message(quote.clone());
    route.bot_store.record_message(quote.clone()).await.unwrap();
    let mut current = message(8, Some(false), "Please discuss this quoted material");
    current.message_id = InlineId::new(10);
    current.timestamp = 101;
    current.reply_to_message_id = Some(quote.message_id);
    backend.insert_message(current.clone());
    let record = inbound_from_message(&bot, &current, &route, true)
        .await
        .unwrap()
        .unwrap();
    route.store.accept_inbound(&record).unwrap();
    let record = route
        .store
        .take_next_inbound(&binding, 102)
        .unwrap()
        .unwrap();
    prepare_public_context_input(
        &bot,
        &manager,
        &route,
        &record,
        &binding,
        &record.direction.text,
    )
    .await
    .unwrap();
    let snapshot = route
        .store
        .context_input(&record.event_id)
        .unwrap()
        .unwrap()
        .0;
    assert!(
        snapshot
            .input
            .text
            .contains("old explicitly quoted public canary")
    );
    assert!(!snapshot.input.text.contains("old physical direction"));
    assert_eq!(snapshot.trigger.as_ref().unwrap().message_id, 10);
    manager
        .start_admitted_turn(&record.event_id, &binding, 103, TurnOptions::default())
        .await
        .unwrap();
    assert_eq!(driver.inputs.lock().unwrap().len(), 1);
    bot.shutdown().await.unwrap();
}

#[tokio::test]
async fn post_reset_inferred_reply_and_imported_private_quote_stay_out_of_provider_context() {
    for case in ["discretionary", "imported"] {
        let mut route = route("acp");
        let (bot, backend, _) = client().await;
        let chat_id = if case == "discretionary" { 42 } else { 706 };
        if case == "discretionary" {
            route.owner_control = Some(Arc::new(OwnerControl::for_test(
                bot.clone(),
                route.bot_store.clone(),
            )));
            route
                .bot_store
                .record_dialog(DialogRecord {
                    follow_mode: Some(inline_client::DialogFollowMode::Following),
                    ..DialogRecord::new(InlineId::new(chat_id))
                })
                .await
                .unwrap();
        }
        let driver = Arc::new(PublicInputDriver::default());
        let manager = ProviderSessionManager::new(
            driver.clone(),
            route.store.clone(),
            route.provider_id.clone(),
        );
        let binding = conversation_for_chat(&route, chat_id)
            .unwrap()
            .snapshot()
            .binding;
        manager.ensure_session(&binding, 1).await.unwrap();
        manager.rotate_session(&binding, 100).await.unwrap();
        let mut old = message(8, Some(false), "pre-reset excluded reference canary");
        old.chat_id = InlineId::new(chat_id);
        old.message_id = InlineId::new(1);
        old.timestamp = 50;
        if case == "imported" {
            old.metadata.agent_session = Some(inline_client::AgentSessionMessageMetadata {
                agent_session_id: 91,
                provider: proto::AgentSessionProvider::Codex as i32,
                role: proto::AgentSessionMessageRole::User as i32,
                relation: proto::AgentSessionMessageRelation::Imported as i32,
            });
        }
        backend.insert_message(old.clone());
        route.bot_store.record_message(old.clone()).await.unwrap();
        let mut current = message(7, Some(false), "new current request");
        current.chat_id = InlineId::new(chat_id);
        current.timestamp = 101;
        current.reply_to_message_id = Some(old.message_id);
        backend.insert_message(current.clone());
        let record = inbound_from_message(&bot, &current, &route, true)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(record.direction.is_discretionary(), case == "discretionary");
        route.store.accept_inbound(&record).unwrap();
        let record = route
            .store
            .take_next_inbound(&binding, 102)
            .unwrap()
            .unwrap();
        prepare_public_context_input(
            &bot,
            &manager,
            &route,
            &record,
            &binding,
            &record.direction.text,
        )
        .await
        .unwrap();
        manager
            .start_admitted_turn(&record.event_id, &binding, 103, TurnOptions::default())
            .await
            .unwrap();
        assert!(
            !driver.inputs.lock().unwrap()[0]
                .text
                .contains("pre-reset excluded reference canary"),
            "{case}"
        );
        bot.shutdown().await.unwrap();
    }
}

#[tokio::test]
async fn reset_after_public_preparation_still_prevents_provider_submission() {
    let route = route("acp");
    let (bot, backend, _) = client().await;
    let source = message(8, Some(false), "prepared before reset");
    backend.insert_message(source.clone());
    let record = inbound_from_message(&bot, &source, &route, true)
        .await
        .unwrap()
        .unwrap();
    route.store.accept_inbound(&record).unwrap();
    let record = route
        .store
        .take_next_inbound(&record.binding, 2)
        .unwrap()
        .unwrap();
    let driver = Arc::new(PublicInputDriver::default());
    let manager = ProviderSessionManager::new(
        driver.clone(),
        route.store.clone(),
        route.provider_id.clone(),
    );
    prepare_public_context_input(
        &bot,
        &manager,
        &route,
        &record,
        &record.binding,
        &record.direction.text,
    )
    .await
    .unwrap();
    manager.rotate_session(&record.binding, 100).await.unwrap();
    assert!(
        manager
            .start_admitted_turn(
                &record.event_id,
                &record.binding,
                101,
                TurnOptions::default()
            )
            .await
            .is_err()
    );
    assert!(driver.inputs.lock().unwrap().is_empty());
    bot.shutdown().await.unwrap();
}

#[tokio::test]
async fn allowed_unknown_actor_and_reply_recipient_cannot_invoke_the_provider() {
    for case in [
        "actor-admission",
        "actor-preparation",
        "reply-admission",
        "reply-preparation",
    ] {
        let route = route("acp");
        let (bot, backend, _) = client().await;
        // ID8 really is allowed. A display-only legacy record is not human proof.
        assert!(route.allows(8));
        route
            .bot_store
            .record_users(vec![inline_client::UserRecord {
                user_id: InlineId::new(8),
                display_name: Some("Legacy name".into()),
                username: None,
                first_name: None,
                last_name: None,
                avatar_url: None,
                is_bot: None,
            }])
            .await
            .unwrap();
        let driver = Arc::new(PublicInputDriver::default());
        let manager = ProviderSessionManager::new(
            driver.clone(),
            route.store.clone(),
            route.provider_id.clone(),
        );
        let mut source = message(
            if case.starts_with("actor") { 8 } else { 7 },
            Some(false),
            "current request",
        );
        if case.starts_with("reply") {
            source.reply_to_message_id = Some(InlineId::new(1));
            let mut reply = message(8, None, "unknown recipient");
            reply.message_id = InlineId::new(1);
            backend.insert_message(reply.clone());
            if case.ends_with("preparation") {
                reply.sender_id = InlineId::new(route.bot_user_id);
            }
            route.bot_store.record_message(reply).await.unwrap();
        } else if case.ends_with("admission") {
            source.metadata.sender_is_bot = None;
        }
        if case.ends_with("admission") {
            let error = inbound_from_message(&bot, &source, &route, true)
                .await
                .unwrap_err();
            assert!(error.is::<UnverifiedMessageActor>(), "{case}: {error}");
            assert!(
                route
                    .store
                    .get_inbound("inline-message-706-9")
                    .unwrap()
                    .is_none()
            );
        } else {
            let record = inbound_from_message(&bot, &source, &route, true)
                .await
                .unwrap()
                .unwrap();
            route.store.accept_inbound(&record).unwrap();
            let record = route
                .store
                .take_next_inbound(&record.binding, 2)
                .unwrap()
                .unwrap();
            if case.starts_with("actor") {
                source.metadata.sender_is_bot = None;
            }
            backend.insert_message(source);
            assert!(
                prepare_public_context_input(
                    &bot,
                    &manager,
                    &route,
                    &record,
                    &record.binding,
                    &record.direction.text
                )
                .await
                .is_err(),
                "{case}"
            );
            assert!(
                manager
                    .start_admitted_turn(
                        &record.event_id,
                        &record.binding,
                        3,
                        TurnOptions::default()
                    )
                    .await
                    .is_err()
            );
        }
        assert!(driver.inputs.lock().unwrap().is_empty(), "{case}");
        bot.shutdown().await.unwrap();
    }
}

#[tokio::test]
async fn changed_public_snapshot_is_not_fresh_intent_and_cannot_admit_stale_queued_attachments() {
    let route = route("acp");
    let (bot, backend, _) = client().await;
    let mut source = message(7, Some(false), "unchanged public request");
    source.metadata.revision = Some(1);
    source.metadata.source_snapshot = Some("original-visible-payload".to_string());
    let record = inbound_from_message(&bot, &source, &route, true)
        .await
        .unwrap()
        .unwrap();
    route.store.accept_inbound(&record).unwrap();
    let record = route
        .store
        .take_next_inbound(&record.binding, 2)
        .unwrap()
        .unwrap();
    source.metadata.source_snapshot = Some("changed-visible-payload".to_string());
    backend.insert_message(source);
    let driver = Arc::new(PublicInputDriver::default());
    let manager = ProviderSessionManager::new(
        driver.clone(),
        route.store.clone(),
        route.provider_id.clone(),
    );
    assert!(
        prepare_public_context_input(
            &bot,
            &manager,
            &route,
            &record,
            &record.binding,
            &record.direction.text
        )
        .await
        .is_err()
    );
    assert!(
        route
            .store
            .context_input(&record.event_id)
            .unwrap()
            .is_none()
    );
    assert!(driver.inputs.lock().unwrap().is_empty());
    bot.shutdown().await.unwrap();
}

#[tokio::test]
async fn busy_explicit_and_discretionary_inputs_always_run_as_separate_turns() {
    for incoming_discretionary in [true, false] {
        let mut route = route("acp");
        let (bot, backend) =
            super::release_acceptance::local_client_without_agent_session(route.bot_store.clone())
                .await;
        route.owner_control = Some(Arc::new(OwnerControl::for_test(
            bot.clone(),
            route.bot_store.clone(),
        )));
        let active = conversation_for_chat(&route, 42).unwrap();
        let conversation = active.snapshot();
        let driver = Arc::new(PublicInputDriver {
            answer: if incoming_discretionary {
                SILENT_RESPONSE.to_string()
            } else {
                "requested answer".to_string()
            },
            ..Default::default()
        });
        let manager = ProviderSessionManager::new(
            driver.clone(),
            route.store.clone(),
            route.provider_id.clone(),
        );
        manager
            .ensure_session(&conversation.binding, 1)
            .await
            .unwrap();
        let mut source = message(7, Some(false), "original request");
        source.chat_id = InlineId::new(42);
        if incoming_discretionary {
            mention(&mut source);
        }
        backend.insert_message(source.clone());
        route
            .bot_store
            .record_message(source.clone())
            .await
            .unwrap();
        let original = inbound_from_message(&bot, &source, &route, true)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            original.direction.is_discretionary(),
            !incoming_discretionary
        );
        route.store.accept_inbound(&original).unwrap();
        let original = route
            .store
            .take_next_inbound(&conversation.binding, 2)
            .unwrap()
            .unwrap();
        prepare_public_context_input(
            &bot,
            &manager,
            &route,
            &original,
            &conversation.binding,
            &original.direction.text,
        )
        .await
        .unwrap();
        let (session, turn, lease) = manager
            .start_admitted_turn(
                &original.event_id,
                &conversation.binding,
                3,
                TurnOptions::default(),
            )
            .await
            .unwrap();
        let mut incoming = message(8, Some(false), "new incoming request");
        incoming.chat_id = source.chat_id;
        incoming.message_id = InlineId::new(10);
        incoming.timestamp = now_seconds();
        if !incoming_discretionary {
            mention(&mut incoming);
        }
        backend.insert_message(incoming.clone());
        route
            .bot_store
            .record_message(incoming.clone())
            .await
            .unwrap();
        let mut events = bot.take_lossless_events().unwrap();
        backend.push_event_batch(vec![ClientEvent::MessageStored {
            message: incoming.clone(),
        }]);
        let incoming_delivery = delivery(&mut events).await;
        let mut coordinator = TurnCoordinator::running(turn.turn_id.clone());
        let mut typing = TypingIndicator::quiet(&bot, 42);
        let identity = test_settings_identity(&route);
        handle_active_delivery(
            &bot,
            incoming_delivery,
            &manager,
            session.session_id(),
            &turn.turn_id,
            &route.store,
            &conversation.binding,
            &route,
            &active,
            &identity,
            &mut HashSet::new(),
            &mut HashMap::new(),
            &mut coordinator,
            &mut typing,
            &mut false,
            SteeringSupport::Native,
        )
        .await
        .unwrap();
        assert_eq!(
            driver.inputs.lock().unwrap().len(),
            1,
            "mixed response policies must never steer"
        );
        assert_eq!(coordinator.queue_len(), 1);
        route.store.complete_inbound(&original.event_id).unwrap();
        drop(lease);
        drop(turn);
        let queued = route
            .store
            .take_next_inbound(&conversation.binding, now_seconds())
            .unwrap()
            .unwrap();
        assert_eq!(queued.direction.is_discretionary(), incoming_discretionary);
        let (sender, mut receiver) = tokio::sync::mpsc::channel(8);
        let (promotions, _) = tokio::sync::mpsc::channel(1);
        run_inbound_turn(
            &bot,
            &mut receiver,
            &manager,
            &route.store,
            &conversation.binding,
            &conversation.workspace,
            &route,
            &active,
            &identity,
            queued.clone(),
            None,
            sender,
            promotions,
        )
        .await
        .unwrap();
        let input = driver.inputs.lock().unwrap()[1].text.clone();
        assert_eq!(
            input.contains("Decide whether a reply from you is useful"),
            incoming_discretionary
        );
        assert_eq!(
            route
                .store
                .get_inbound(&queued.event_id)
                .unwrap()
                .unwrap()
                .state,
            InboundState::Completed
        );
        let history = bot
            .history(HistoryRequest {
                chat_id: source.chat_id,
                limit: Some(50),
                before_message_id: None,
                after_message_id: None,
            })
            .await
            .unwrap();
        assert!(!history.messages.iter().any(|row| matches!(&row.content,
            MessageContent::Text { text } if text.contains(SILENT_RESPONSE))));
        assert_eq!(
            history.messages.iter().any(|row| matches!(&row.content,
            MessageContent::Text { text } if text == "requested answer")),
            !incoming_discretionary
        );
        bot.shutdown().await.unwrap();
    }
}

#[tokio::test]
async fn active_source_edit_keeps_quiet_policy_and_rejects_authoritative_recipient_retarget() {
    for recipient in ["quiet", "leading-other", "reply-other"] {
        let retarget = recipient != "quiet";
        let route = route("acp");
        let (bot, backend, mut events) = client().await;
        let driver = Arc::new(PublicInputDriver::default());
        let manager = ProviderSessionManager::new(
            driver.clone(),
            route.store.clone(),
            route.provider_id.clone(),
        );
        let binding = conversation_for_chat(&route, 42)
            .unwrap()
            .snapshot()
            .binding;
        manager.ensure_session(&binding, 1).await.unwrap();
        let mut source = message(7, Some(false), "original source");
        source.chat_id = InlineId::new(42);
        source.metadata.revision = Some(1);
        if retarget {
            mention(&mut source);
        }
        if recipient == "reply-other" {
            let mut other = message(98, Some(true), "Other worker's public result");
            other.chat_id = source.chat_id;
            other.message_id = InlineId::new(1);
            backend.insert_message(other);
            source.reply_to_message_id = Some(InlineId::new(1));
        }
        backend.insert_message(source.clone());
        let original = inbound_from_message(&bot, &source, &route, true)
            .await
            .unwrap()
            .unwrap();
        route.store.accept_inbound(&original).unwrap();
        let original = route.store.take_next_inbound(&binding, 2).unwrap().unwrap();
        prepare_public_context_input(
            &bot,
            &manager,
            &route,
            &original,
            &binding,
            &original.direction.text,
        )
        .await
        .unwrap();
        let (session, turn, _lease) = manager
            .start_admitted_turn(&original.event_id, &binding, 3, TurnOptions::default())
            .await
            .unwrap();
        let mut edited = source.clone();
        edited.metadata.revision = Some(2);
        edited.content = MessageContent::Text {
            text: "changed source".to_string(),
        };
        if recipient == "leading-other" {
            edited.metadata.entities[0].user_id = Some(InlineId::new(98));
        } else if recipient == "reply-other" {
            edited.metadata.entities.clear();
        }
        backend
            .delete_message(inline_client::DeleteMessageRequest {
                chat_id: edited.chat_id,
                message_id: edited.message_id,
                external_id: None,
            })
            .await
            .unwrap();
        backend.insert_message(edited.clone());
        // A stale event still points at this bot. Only returned authenticated
        // history is authoritative for recipient admission.
        let mut stale_event = edited.clone();
        if recipient == "leading-other" {
            stale_event.metadata.entities[0].user_id = Some(InlineId::new(17));
        } else if recipient == "reply-other" {
            mention(&mut stale_event);
        }
        backend.push_event_batch(vec![ClientEvent::MessageStored {
            message: stale_event,
        }]);
        let source_edit_delivery = delivery(&mut events).await;
        let active = conversation_for_chat(&route, 42).unwrap();
        let mut coordinator = TurnCoordinator::running(turn.turn_id.clone());
        let mut typing = TypingIndicator::quiet(&bot, 42);
        handle_active_delivery(
            &bot,
            source_edit_delivery,
            &manager,
            session.session_id(),
            &turn.turn_id,
            &route.store,
            &binding,
            &route,
            &active,
            &test_settings_identity(&route),
            &mut HashSet::new(),
            &mut HashMap::new(),
            &mut coordinator,
            &mut typing,
            &mut false,
            SteeringSupport::Native,
        )
        .await
        .unwrap();
        assert_eq!(
            route
                .store
                .get_inbound(&original.event_id)
                .unwrap()
                .unwrap()
                .state,
            InboundState::Started,
            "recipient exclusions must leave admitted work active"
        );
        assert!(!manager.shutdown_epoch_if_idle().await.unwrap());
        let inputs = driver.inputs.lock().unwrap().clone();
        assert_eq!(inputs.len(), if retarget { 1 } else { 2 });
        if !retarget {
            assert!(
                inputs[1]
                    .text
                    .contains("Decide whether a reply from you is useful")
            );
            assert!(
                route
                    .store
                    .get_inbound("inline-message-42-9-edit-2")
                    .unwrap()
                    .unwrap()
                    .direction
                    .is_discretionary()
            );
        }
        bot.shutdown().await.unwrap();
    }
}

#[tokio::test]
async fn unknown_edited_reply_defers_real_receipt_and_original_provider_pump_completes() {
    let mut route = route("acp");
    let (bot, backend) =
        super::release_acceptance::local_client_without_agent_session(route.bot_store.clone())
            .await;
    route.owner_control = Some(Arc::new(OwnerControl::for_test(
        bot.clone(),
        route.bot_store.clone(),
    )));
    let driver = Arc::new(PublicInputDriver {
        hold_completion: true,
        ..Default::default()
    });
    let manager = ProviderSessionManager::new(
        driver.clone(),
        route.store.clone(),
        route.provider_id.clone(),
    );
    let active = conversation_for_chat(&route, 706).unwrap();
    let conversation = active.snapshot();
    let mut source = message(7, Some(false), "original admitted source");
    source.metadata.revision = Some(1);
    backend.insert_message(source.clone());
    let record = inbound_from_message(&bot, &source, &route, true)
        .await
        .unwrap()
        .unwrap();
    route.store.accept_inbound(&record).unwrap();
    let record = route
        .store
        .take_next_inbound(&record.binding, 2)
        .unwrap()
        .unwrap();
    let mut edited = source.clone();
    edited.metadata.revision = Some(2);
    edited.content = MessageContent::Text {
        text: "edited reply with unknown recipient".into(),
    };
    edited.reply_to_message_id = Some(InlineId::new(1));
    let mut reply = message(8, None, "author kind is not established");
    reply.message_id = InlineId::new(1);
    backend.insert_message(reply);

    // The physical receipts use the production SDK claim/outbox implementation.
    // Public-history RPCs use the existing in-memory authenticated test backend.
    let receipts = SqliteStore::open_in_memory().unwrap();
    receipts
        .save_session(inline_client::StoredSession {
            auth: AuthCredential::AccessToken {
                token: AuthToken::try_new("local-test-only").unwrap(),
            },
            account_namespace: None,
        })
        .await
        .unwrap();
    let staged = receipts
        .append_client_events(vec![
            ClientEvent::MessageStored {
                message: edited.clone(),
            },
            ClientEvent::MessageDeleted {
                chat_id: source.chat_id,
                message_id: InlineId::new(100),
            },
        ])
        .await
        .unwrap();
    let receipt_backend = inline_client::SdkBackend::builder()
        .store(receipts.clone())
        .without_realtime_handshake()
        .realtime_url("ws://127.0.0.1:1")
        .build()
        .unwrap();
    let receipt_client = InlineClient::builder()
        .backend(receipt_backend)
        .build()
        .spawn();
    let mut receipt_events = receipt_client.take_lossless_events().unwrap();
    receipt_client
        .connect(ConnectRequest::new(AuthCredential::AccessToken {
            token: AuthToken::try_new("local-test-only").unwrap(),
        }))
        .await
        .unwrap();
    let edit_delivery = delivery(&mut receipt_events).await;
    let control_delivery = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let next = receipt_events.recv_delivery().await.unwrap();
            if matches!(next.event(), ClientEvent::MessageDeleted { .. }) {
                break next;
            }
            next.ack().await.unwrap();
        }
    })
    .await
    .unwrap();
    let (sender, mut receiver) = tokio::sync::mpsc::channel(8);
    let (promotions, _) = tokio::sync::mpsc::channel(1);
    let identity = test_settings_identity(&route);
    let pump = run_inbound_turn(
        &bot,
        &mut receiver,
        &manager,
        &route.store,
        &record.binding,
        &conversation.workspace,
        &route,
        &active,
        &identity,
        record.clone(),
        None,
        sender.clone(),
        promotions,
    );
    let exercise = async {
        tokio::time::timeout(Duration::from_secs(2), async {
            while driver.pending_events.lock().unwrap().is_none() {
                let pending = route.store.get_inbound(&record.event_id).unwrap().unwrap();
                assert_ne!(
                    pending.state,
                    InboundState::Failed,
                    "pump setup failed: {:?}",
                    pending.failure
                );
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        backend
            .delete_message(inline_client::DeleteMessageRequest {
                chat_id: source.chat_id,
                message_id: source.message_id,
                external_id: None,
            })
            .await
            .unwrap();
        backend.insert_message(edited.clone());
        sender.send(edit_delivery).await.unwrap();
        sender.send(control_delivery).await.unwrap();
        // The later durable control must be handled by this same active pump
        // before the provider is allowed to finish.
        tokio::time::timeout(Duration::from_secs(2), async {
            while receipts
                .pending_client_events()
                .await
                .unwrap()
                .iter()
                .any(|delivery| delivery.delivery_id == staged[1].delivery_id)
            {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        assert!(
            receipts
                .pending_client_events()
                .await
                .unwrap()
                .iter()
                .any(|delivery| delivery.delivery_id == staged[0].delivery_id),
            "unverified edit must not be ACKed"
        );
        assert!(
            route
                .store
                .get_inbound("inline-message-706-9-edit-2")
                .unwrap()
                .is_none(),
            "unknown edit must not enter the steering inbox"
        );
        assert_eq!(
            route
                .store
                .get_inbound(&record.event_id)
                .unwrap()
                .unwrap()
                .state,
            InboundState::Started
        );
        assert!(
            !manager.shutdown_epoch_if_idle().await.unwrap(),
            "original provider lease must remain active"
        );
        assert_eq!(
            driver.inputs.lock().unwrap().len(),
            1,
            "unknown edit must not steer"
        );
        driver
            .pending_events
            .lock()
            .unwrap()
            .take()
            .unwrap()
            .send(Ok(AgentEvent::TurnCompleted {
                turn_id: inline_agent_bridge::TurnId::new("public-input-test-turn").unwrap(),
                outcome: TurnOutcome::Completed,
                error: None,
                timing: TurnTiming::default(),
            }));
    };
    let (outcome, ()) = tokio::join!(pump, exercise);
    outcome.unwrap();
    assert_eq!(
        route
            .store
            .get_inbound(&record.event_id)
            .unwrap()
            .unwrap()
            .state,
        InboundState::Completed
    );
    assert_eq!(driver.inputs.lock().unwrap().len(), 1);
    receipt_client.shutdown().await.unwrap();
    bot.shutdown().await.unwrap();
}

#[tokio::test]
async fn provider_payload_includes_verified_visible_cards_and_historical_action_labels() {
    use inline_client::{MessageActionRecord, MessageAttachmentRecord};
    let route = route("acp");
    let (bot, backend, _) = client().await;
    let mut source = message(7, Some(false), "unchanged body");
    source.metadata.revision = Some(1);
    source.metadata.source_snapshot = Some("visible-card-v1".to_string());
    source.metadata.attachments.push(MessageAttachmentRecord {
        attachment_id: InlineId::new(1),
        kind: "external_task".into(),
        title: Some("Original visible card".into()),
        provider: Some("Work tracker".into()),
        url: Some("https://example.test/task/1".into()),
    });
    source.metadata.actions.push(MessageActionRecord {
        action_id: "private-callback-identity".into(),
        label: "Review card".into(),
        kind: "callback".into(),
    });
    let original = inbound_from_message(&bot, &source, &route, true)
        .await
        .unwrap()
        .unwrap();
    route.store.accept_inbound(&original).unwrap();
    let original = route
        .store
        .take_next_inbound(&original.binding, 2)
        .unwrap()
        .unwrap();
    backend.insert_message(source.clone());
    let driver = Arc::new(PublicInputDriver::default());
    let manager = ProviderSessionManager::new(
        driver.clone(),
        route.store.clone(),
        route.provider_id.clone(),
    );
    prepare_public_context_input(
        &bot,
        &manager,
        &route,
        &original,
        &original.binding,
        &original.direction.text,
    )
    .await
    .unwrap();
    let (session, turn, _lease) = manager
        .start_admitted_turn(
            &original.event_id,
            &original.binding,
            3,
            TurnOptions::default(),
        )
        .await
        .unwrap();
    let input = driver.inputs.lock().unwrap()[0].text.clone();
    for visible in [
        "Original visible card",
        "Work tracker",
        "https://example.test/task/1",
        "Historical action label: Review card",
    ] {
        assert!(input.contains(visible), "{visible}");
    }
    assert!(!input.contains("private-callback-identity"));
    source.metadata.attachments[0].title = Some("Changed visible card".into());
    source.metadata.source_snapshot = Some("visible-card-v2".into());
    backend
        .delete_message(inline_client::DeleteMessageRequest {
            chat_id: source.chat_id,
            message_id: source.message_id,
            external_id: None,
        })
        .await
        .unwrap();
    backend.insert_message(source.clone());
    assert!(
        steer_active_source_edit(
            &bot,
            &source,
            &manager,
            session.session_id(),
            &turn.turn_id,
            &route.store,
            &route
        )
        .await
        .unwrap()
    );
    assert_eq!(
        driver.inputs.lock().unwrap().len(),
        1,
        "card changes alone do not steer"
    );
    // A fresh explicit direction carries the newly readable card as context.
    let mut fresh = message(7, Some(false), "discuss this card");
    fresh.message_id = InlineId::new(10);
    fresh.metadata.revision = Some(1);
    backend.insert_message(fresh.clone());
    let fresh = inbound_from_message(&bot, &fresh, &route, true)
        .await
        .unwrap()
        .unwrap();
    route.store.accept_inbound(&fresh).unwrap();
    route.store.start_inbound(&fresh.event_id, 4).unwrap();
    prepare_public_context_input(
        &bot,
        &manager,
        &route,
        &fresh,
        &fresh.binding,
        &fresh.direction.text,
    )
    .await
    .unwrap();
    manager
        .steer_admitted_turn(
            &fresh.event_id,
            &fresh.binding,
            session.session_id(),
            &turn.turn_id,
        )
        .await
        .unwrap();
    let input = driver.inputs.lock().unwrap()[1].text.clone();
    assert!(input.contains("Changed visible card"));
    assert!(input.contains("Historical action label: Review card"));
    assert!(!input.contains("private-callback-identity"));
    bot.shutdown().await.unwrap();
}

fn test_settings_identity(route: &InboundRoute) -> SettingsIdentity {
    SettingsIdentity {
        owner_user_id: route.owner_user_id,
        owner_dm_chat_id: route.owner_dm_chat_id,
        bot_user_id: route.bot_user_id,
        host_installation_id: "public-test-host".into(),
        host_label: "Test".into(),
        workspace_picker: None,
        codex_projects_path: None,
        codex_project_rpc: None,
        bot_store: route.bot_store.clone(),
        reply_thread_default: ReplyThreadDefault {
            mode: ReplyThreadMode::Off,
            source: ReplyThreadDefaultSource::BuiltIn,
        },
    }
}

#[tokio::test]
async fn bound_participant_can_decide_to_stay_quiet_without_progress_or_a_placeholder_reply() {
    let mut route = route("acp");
    let (bot, backend) =
        super::release_acceptance::local_client_without_agent_session(route.bot_store.clone())
            .await;
    route.owner_control = Some(Arc::new(OwnerControl::for_test(
        bot.clone(),
        route.bot_store.clone(),
    )));
    let active = conversation_for_chat(&route, 42).unwrap();
    let conversation = active.snapshot();
    let driver = Arc::new(PublicInputDriver {
        answer: SILENT_RESPONSE.to_string(),
        ..Default::default()
    });
    let manager = ProviderSessionManager::new(
        driver.clone(),
        route.store.clone(),
        route.provider_id.clone(),
    );
    manager
        .ensure_session(&conversation.binding, 1)
        .await
        .unwrap();
    let mut source = message(
        8,
        Some(false),
        "colleague discussion unrelated to this worker",
    );
    source.chat_id = InlineId::new(42);
    route
        .bot_store
        .record_message(source.clone())
        .await
        .unwrap();
    backend.insert_message(source.clone());
    let record = inbound_from_message(&bot, &source, &route, true)
        .await
        .unwrap()
        .unwrap();
    assert!(record.direction.is_discretionary());
    route.store.accept_inbound(&record).unwrap();
    let record = route
        .store
        .take_next_inbound(&record.binding, 2)
        .unwrap()
        .unwrap();
    assert!(
        record.direction.is_discretionary(),
        "queue must preserve the response decision contract"
    );
    let identity = SettingsIdentity {
        owner_user_id: route.owner_user_id,
        owner_dm_chat_id: route.owner_dm_chat_id,
        bot_user_id: route.bot_user_id,
        host_installation_id: "public-test-host".into(),
        host_label: "Test".into(),
        workspace_picker: None,
        codex_projects_path: None,
        codex_project_rpc: None,
        bot_store: route.bot_store.clone(),
        reply_thread_default: ReplyThreadDefault {
            mode: ReplyThreadMode::Off,
            source: ReplyThreadDefaultSource::BuiltIn,
        },
    };
    let (sender, mut receiver) = tokio::sync::mpsc::channel(8);
    let (promotions, _) = tokio::sync::mpsc::channel(1);
    run_inbound_turn(
        &bot,
        &mut receiver,
        &manager,
        &route.store,
        &record.binding,
        &conversation.workspace,
        &route,
        &active,
        &identity,
        record.clone(),
        None,
        sender,
        promotions,
    )
    .await
    .unwrap();
    let saved = route.store.get_inbound(&record.event_id).unwrap().unwrap();
    assert_eq!(saved.state, InboundState::Completed);
    assert!(saved.stream_message_id.is_none());
    assert_eq!(
        route
            .store
            .context_input(&record.event_id)
            .unwrap()
            .unwrap()
            .1,
        inline_agent_bridge::ContextInputState::Accepted
    );
    assert_eq!(
        route
            .store
            .context_receipt(&record.binding)
            .unwrap()
            .consumed
            .len(),
        1
    );
    assert!(
        driver.inputs.lock().unwrap()[0]
            .text
            .contains("Decide whether a reply from you is useful before taking any action")
    );
    let history = bot
        .history(HistoryRequest {
            chat_id: source.chat_id,
            limit: Some(50),
            before_message_id: None,
            after_message_id: None,
        })
        .await
        .unwrap();
    assert_eq!(
        history.messages.len(),
        1,
        "irrelevant participant input must not publish a progress row or Done"
    );
    assert!(
        route
            .store
            .pending_inbound_final_sends(&route.installation_id)
            .unwrap()
            .is_empty()
    );
    bot.shutdown().await.unwrap();
}

#[tokio::test]
async fn following_and_existing_participation_cannot_override_other_bot_reply_or_unfollow() {
    let mut route = route("acp");
    let (bot, backend, _) = client().await;
    route.owner_control = Some(Arc::new(OwnerControl::for_test(
        bot.clone(),
        route.bot_store.clone(),
    )));
    let binding = conversation_for_chat(&route, 42)
        .unwrap()
        .snapshot()
        .binding;
    let driver = Arc::new(PublicInputDriver::default());
    let manager = ProviderSessionManager::new(
        driver.clone(),
        route.store.clone(),
        route.provider_id.clone(),
    );
    manager.ensure_session(&binding, 1).await.unwrap();
    route
        .bot_store
        .record_dialog(DialogRecord {
            follow_mode: Some(DialogFollowMode::Following),
            ..DialogRecord::new(InlineId::new(42))
        })
        .await
        .unwrap();
    let mut other_output = message(98, Some(true), "Other worker response");
    other_output.chat_id = InlineId::new(42);
    other_output.message_id = InlineId::new(1);
    backend.insert_message(other_output.clone());
    route
        .bot_store
        .record_message(other_output.clone())
        .await
        .unwrap();
    let mut source = message(8, Some(false), "follow up question");
    source.chat_id = InlineId::new(42);
    source.reply_to_message_id = Some(InlineId::new(1));
    assert!(
        inbound_from_message(&bot, &source, &route, true)
            .await
            .unwrap()
            .is_none()
    );
    // Even stale cache that mistakes the recipient for this worker cannot
    // push the request through the authenticated provider input boundary.
    other_output.sender_id = InlineId::new(route.bot_user_id);
    route.bot_store.record_message(other_output).await.unwrap();
    backend.insert_message(source.clone());
    let record = inbound_from_message(&bot, &source, &route, true)
        .await
        .unwrap()
        .unwrap();
    route.store.accept_inbound(&record).unwrap();
    let record = route.store.take_next_inbound(&binding, 2).unwrap().unwrap();
    assert!(
        prepare_public_context_input(
            &bot,
            &manager,
            &route,
            &record,
            &binding,
            &record.direction.text
        )
        .await
        .is_err()
    );
    assert!(driver.inputs.lock().unwrap().is_empty());
    source.reply_to_message_id = None;
    route
        .bot_store
        .record_dialog(DialogRecord {
            follow_mode: Some(DialogFollowMode::Unfollowed),
            ..DialogRecord::new(InlineId::new(42))
        })
        .await
        .unwrap();
    assert!(
        inbound_from_message(&bot, &source, &route, true)
            .await
            .unwrap()
            .is_none()
    );
    mention(&mut source);
    assert!(
        inbound_from_message(&bot, &source, &route, true)
            .await
            .unwrap()
            .is_some()
    );
    bot.shutdown().await.unwrap();
}

#[tokio::test]
async fn linked_public_sources_retain_actor_authority_and_forwarded_mentions_never_activate() {
    let route = route("acp");
    let (bot, _, _) = client().await;
    let mut source = message(8, Some(false), "@test inspect this");
    mention(&mut source);
    source.metadata.agent_session = Some(inline_client::AgentSessionMessageMetadata {
        agent_session_id: 999,
        provider: proto::AgentSessionProvider::Codex as i32,
        role: proto::AgentSessionMessageRole::User as i32,
        relation: proto::AgentSessionMessageRelation::Linked as i32,
    });
    assert!(
        inbound_from_message(&bot, &source, &route, true)
            .await
            .unwrap()
            .is_some()
    );
    source.sender_id = InlineId::new(98);
    source.metadata.sender_is_bot = Some(true);
    source.metadata.agent_session.as_mut().unwrap().role =
        proto::AgentSessionMessageRole::Assistant as i32;
    assert!(
        inbound_from_message(&bot, &source, &route, true)
            .await
            .unwrap()
            .is_some(),
        "another bot's public linked output can explicitly delegate"
    );
    source.sender_id = InlineId::new(route.bot_user_id);
    assert!(
        inbound_from_message(&bot, &source, &route, true)
            .await
            .unwrap()
            .is_none(),
        "own linked assistant echo is not new intent"
    );
    source.sender_id = InlineId::new(8);
    source.metadata.sender_is_bot = Some(false);
    source.metadata.agent_session.as_mut().unwrap().role =
        proto::AgentSessionMessageRole::User as i32;
    source.metadata.is_forwarded = true;
    assert!(
        inbound_from_message(&bot, &source, &route, true)
            .await
            .unwrap()
            .is_none()
    );
    source.metadata.is_forwarded = false;
    source.metadata.agent_session.as_mut().unwrap().relation =
        proto::AgentSessionMessageRelation::Imported as i32;
    assert!(
        inbound_from_message(&bot, &source, &route, true)
            .await
            .unwrap()
            .is_none()
    );
    bot.shutdown().await.unwrap();
}

pub(super) fn route(provider: &str) -> InboundRoute {
    let store = Arc::new(BridgeStore::open_in_memory().expect("bridge store"));
    let installation_id = InstallationId::new(provider).expect("installation");
    let provider_id = ProviderId::new(provider).expect("provider");
    store
        .put_installation(&InstallationRecord {
            installation_id: installation_id.clone(),
            provider_id: provider_id.clone(),
            display_name: provider.to_string(),
            created_at: 1,
            updated_at: 1,
        })
        .expect("installation");
    store
        .select_workspace(
            &installation_id,
            &WorkspaceId::new("project").expect("workspace"),
            &std::env::current_dir().expect("cwd"),
            1,
        )
        .expect("workspace");
    InboundRoute {
        store,
        installation_id,
        provider_id,
        policy: Arc::new(RwLock::new(
            OperatorPolicy::from_allowed(7, [8, 77]).expect("policy"),
        )),
        owner_user_id: 7,
        host_label: "Test Mac".to_string(),
        owner_dm_chat_id: 706,
        bot_user_id: 17,
        bot_username: "test_bot".to_string(),
        bot_store: SqliteStore::open_in_memory().expect("bot store"),
        attachment_cache_dir: PathBuf::from("unused-authorization-test-attachments"),
        owner_control: None,
        accept_messages_after: 0,
        deferred_inbound_tx: tokio::sync::mpsc::channel(1).0,
        pending_voice_messages: Arc::new(std::sync::Mutex::new(HashSet::new())),
        claude_history: None,
        control_lane: Arc::new(tokio::sync::Semaphore::new(1)),
        control_epoch: ControlTaskEpoch::new(),
        bot_agent_resolver: BotAgentResolver::disabled(),
    }
}

fn message(sender: i64, is_bot: Option<bool>, text: &str) -> MessageRecord {
    MessageRecord {
        chat_id: InlineId::new(706),
        message_id: InlineId::new(9),
        sender_id: InlineId::new(sender),
        timestamp: 1,
        is_outgoing: false,
        content: MessageContent::Text {
            text: text.to_string(),
        },
        reply_to_message_id: None,
        metadata: MessageMetadata {
            sender_is_bot: is_bot,
            ..MessageMetadata::default()
        },
        transaction: None,
    }
}

fn mention(message: &mut MessageRecord) {
    message.metadata.entities.push(MessageEntityRecord {
        kind: "TYPE_MENTION".to_string(),
        offset: 0,
        length: 4,
        user_id: Some(InlineId::new(17)),
        agent_id: None,
        group_id: None,
        chat_id: None,
        value: None,
    });
}

async fn client() -> (InlineClient, InMemoryBackend, LosslessEventReceiver) {
    let backend = InMemoryBackend::new();
    let bot = InlineClient::builder()
        .backend(backend.clone())
        .build()
        .spawn();
    let events = bot.take_lossless_events().expect("events");
    bot.connect(ConnectRequest::new(AuthCredential::AccessToken {
        token: AuthToken::try_new("local-test-only").expect("test credential"),
    }))
    .await
    .expect("in-memory connect");
    (bot, backend, events)
}

async fn delivery(events: &mut LosslessEventReceiver) -> LosslessEventDelivery {
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let event = events.recv_delivery().await.expect("event delivery");
            if matches!(
                event.event(),
                ClientEvent::MessageStored { message } if !message.is_outgoing
            ) {
                return event;
            }
            event.ack().await.expect("ack status");
        }
    })
    .await
    .expect("message delivery deadline")
}

async fn record_bound_dialog(route: &InboundRoute, model_id: &str) {
    let mut dialog = DialogRecord::new(InlineId::new(706));
    dialog.peer_user_id = Some(InlineId::new(7));
    dialog.agent_context = Some(inline_client::AgentThreadContext {
        bot_user_id: InlineId::new(17),
        agent_id: None,
        configuration: Some(inline_client::AgentThreadConfiguration {
            project_id: Some("project".to_string()),
            model_id: Some(model_id.to_string()),
            reasoning_effort_id: None,
        }),
    });
    route.bot_store.record_dialog(dialog).await.expect("dialog");
}

async fn record_bound_dialog_with_project(route: &InboundRoute, project_id: &str, model_id: &str) {
    let mut dialog = DialogRecord::new(InlineId::new(706));
    dialog.peer_user_id = Some(InlineId::new(7));
    dialog.agent_context = Some(inline_client::AgentThreadContext {
        bot_user_id: InlineId::new(17),
        agent_id: None,
        configuration: Some(inline_client::AgentThreadConfiguration {
            project_id: Some(project_id.to_string()),
            model_id: Some(model_id.to_string()),
            reasoning_effort_id: None,
        }),
    });
    route.bot_store.record_dialog(dialog).await.expect("dialog");
}

fn history_contains(history: &inline_client::HistoryPage, expected: &str) -> bool {
    history.messages.iter().any(|message| {
        matches!(&message.content, MessageContent::Text { text } if text.contains(expected))
    })
}

#[tokio::test]
async fn provider_unavailable_bound_context_without_catalog_handles_status_and_queues_work() {
    let route = route("codex");
    record_bound_dialog(&route, "gpt-test").await;
    let (bot, backend, mut events) = client().await;

    backend.push_event_batch(vec![ClientEvent::MessageStored {
        message: message(7, Some(false), "/status"),
    }]);
    let status_delivery = delivery(&mut events).await;
    accept_provider_unavailable_delivery(&bot, &status_delivery, &route)
        .await
        .expect("status delivery");
    let history = bot
        .history(HistoryRequest {
            chat_id: InlineId::new(706),
            limit: Some(10),
            before_message_id: None,
            after_message_id: None,
        })
        .await
        .expect("status history");
    assert!(history_contains(&history, "local provider is restarting"));

    let mut work = message(7, Some(false), "continue working");
    work.message_id = InlineId::new(10);
    backend.push_event_batch(vec![ClientEvent::MessageStored { message: work }]);
    let work_delivery = delivery(&mut events).await;
    accept_provider_unavailable_delivery(&bot, &work_delivery, &route)
        .await
        .expect("work delivery");
    assert_eq!(
        route
            .store
            .pending_inbound_bindings(&route.installation_id, 10)
            .expect("queued work")
            .len(),
        1
    );
    bot.shutdown().await.expect("shutdown");
}

#[tokio::test]
async fn stale_catalog_preserves_configuration_and_queues_the_delivery() {
    let route = route("codex");
    route
        .bot_agent_resolver
        .store_configuration_catalog(AgentConfigurationCatalog {
            projects: Some(AgentProjectCatalog {
                options: vec![AgentProjectOption {
                    id: "project".to_string(),
                    label: "Project".to_string(),
                    description: None,
                }],
                can_select_folder: None,
                default_project_id: None,
            }),
            models: Some(AgentModelCatalog {
                options: vec![AgentModelOption {
                    id: "gpt-test".to_string(),
                    label: "GPT Test".to_string(),
                    description: None,
                    reasoning_effort_ids: Vec::new(),
                    default_reasoning_effort_id: None,
                }],
                default_model_id: None,
            }),
            reasoning: None,
        });
    record_bound_dialog(&route, "missing-model").await;
    let (bot, backend, mut events) = client().await;

    backend.push_event_batch(vec![ClientEvent::MessageStored {
        message: message(7, Some(false), "continue working"),
    }]);
    let delivery = delivery(&mut events).await;
    accept_provider_unavailable_delivery(&bot, &delivery, &route)
        .await
        .expect("invalid configuration delivery");
    let history = bot
        .history(HistoryRequest {
            chat_id: InlineId::new(706),
            limit: Some(10),
            before_message_id: None,
            after_message_id: None,
        })
        .await
        .expect("failure history");
    assert!(!history_contains(
        &history,
        "using this provider’s defaults"
    ));
    let record = route
        .store
        .get_inbound("inline-message-706-9")
        .unwrap()
        .unwrap();
    assert_eq!(
        route
            .store
            .chat_settings(&record.binding, 2)
            .unwrap()
            .model
            .as_deref(),
        Some("missing-model")
    );
    assert_eq!(
        route
            .store
            .pending_inbound_bindings(&route.installation_id, 10)
            .expect("queued work")
            .len(),
        1
    );
    bot.shutdown().await.expect("shutdown");
}

#[tokio::test]
async fn unavailable_bound_project_offers_retry_without_queueing() {
    let route = route("codex");
    record_bound_dialog_with_project(&route, "missing-project", "gpt-test").await;
    let (bot, backend, mut events) = client().await;

    backend.push_event_batch(vec![ClientEvent::MessageStored {
        message: message(7, Some(false), "continue working"),
    }]);
    let delivery = delivery(&mut events).await;
    accept_provider_unavailable_delivery(&bot, &delivery, &route)
        .await
        .expect("unavailable project delivery");
    let history = bot
        .history(HistoryRequest {
            chat_id: InlineId::new(706),
            limit: Some(10),
            before_message_id: None,
            after_message_id: None,
        })
        .await
        .expect("fallback history");
    assert!(history_contains(&history, "project folder isn’t available"));
    // InMemoryBackend omits action metadata; callback access and deduplication
    // are covered by settings_retry_rechecks_access_and_admits_the_original_request_once.
    assert_eq!(
        route
            .store
            .pending_inbound_bindings(&route.installation_id, 10)
            .expect("queued work")
            .len(),
        0
    );
    bot.shutdown().await.expect("shutdown");
}

#[tokio::test]
async fn unavailable_skilled_agent_defaults_to_the_provider_bot_and_queues() {
    let route = route("codex");
    let mut dialog = DialogRecord::new(InlineId::new(706));
    dialog.peer_user_id = Some(InlineId::new(7));
    dialog.agent_context = Some(inline_client::AgentThreadContext {
        bot_user_id: InlineId::new(17),
        agent_id: Some(InlineId::new(99)),
        configuration: Some(inline_client::AgentThreadConfiguration {
            project_id: Some("project".to_string()),
            model_id: None,
            reasoning_effort_id: None,
        }),
    });
    route.bot_store.record_dialog(dialog).await.expect("dialog");
    let (bot, backend, mut events) = client().await;

    backend.push_event_batch(vec![ClientEvent::MessageStored {
        message: message(7, Some(false), "continue working"),
    }]);
    let delivery = delivery(&mut events).await;
    accept_provider_unavailable_delivery(&bot, &delivery, &route)
        .await
        .expect("unavailable Agent delivery");

    let history = bot
        .history(HistoryRequest {
            chat_id: InlineId::new(706),
            limit: Some(10),
            before_message_id: None,
            after_message_id: None,
        })
        .await
        .expect("fallback history");
    assert!(history_contains(&history, "default behavior"));
    assert_eq!(
        route
            .store
            .pending_inbound_bindings(&route.installation_id, 10)
            .expect("queued work")
            .len(),
        1
    );
    bot.shutdown().await.expect("shutdown");
}

#[tokio::test]
async fn skilled_agent_owned_by_another_provider_fails_closed_without_queuing() {
    let route = route("codex");
    route.bot_agent_resolver.store(
        99,
        Some(proto::BotAgent {
            id: 99,
            bot_user_id: 98,
            name: "Foreign Agent".to_string(),
            ..proto::BotAgent::default()
        }),
    );
    let mut dialog = DialogRecord::new(InlineId::new(706));
    dialog.peer_user_id = Some(InlineId::new(7));
    dialog.agent_context = Some(inline_client::AgentThreadContext {
        bot_user_id: InlineId::new(17),
        agent_id: Some(InlineId::new(99)),
        configuration: None,
    });
    route.bot_store.record_dialog(dialog).await.expect("dialog");
    let (bot, backend, mut events) = client().await;

    backend.push_event_batch(vec![ClientEvent::MessageStored {
        message: message(7, Some(false), "continue working"),
    }]);
    let delivery = delivery(&mut events).await;
    accept_provider_unavailable_delivery(&bot, &delivery, &route)
        .await
        .expect("foreign Agent delivery");

    let history = bot
        .history(HistoryRequest {
            chat_id: InlineId::new(706),
            limit: Some(10),
            before_message_id: None,
            after_message_id: None,
        })
        .await
        .expect("foreign Agent history");
    assert!(history_contains(
        &history,
        "does not belong to this provider"
    ));
    assert!(
        route
            .store
            .pending_inbound_bindings(&route.installation_id, 10)
            .expect("queued work")
            .is_empty()
    );
    bot.shutdown().await.expect("shutdown");
}

#[tokio::test]
async fn agent_context_for_another_provider_preserves_own_authorized_queue() {
    let route = route("codex");
    let mut dialog = DialogRecord::new(InlineId::new(706));
    dialog.peer_user_id = Some(InlineId::new(7));
    dialog.agent_context = Some(inline_client::AgentThreadContext {
        bot_user_id: InlineId::new(99),
        agent_id: None,
        configuration: None,
    });
    route.bot_store.record_dialog(dialog).await.expect("dialog");
    let (bot, backend, mut events) = client().await;

    backend.push_event_batch(vec![ClientEvent::MessageStored {
        message: message(7, Some(false), "continue working"),
    }]);
    let delivery = delivery(&mut events).await;
    accept_provider_unavailable_delivery(&bot, &delivery, &route)
        .await
        .expect("provider mismatch delivery");

    let history = bot
        .history(HistoryRequest {
            chat_id: InlineId::new(706),
            limit: Some(10),
            before_message_id: None,
            after_message_id: None,
        })
        .await
        .expect("mismatch history");
    assert!(!history_contains(&history, "different Agent provider"));
    assert!(
        route
            .store
            .pending_inbound_bindings(&route.installation_id, 10)
            .expect("queued work")
            .len()
            == 1
    );
    bot.shutdown().await.expect("shutdown");
}

#[tokio::test]
async fn failed_delivery_is_settled_and_later_work_still_queues() {
    let route = route("codex");
    let (bot, backend, mut events) = client().await;

    backend.push_event_batch(vec![ClientEvent::MessageStored {
        message: message(7, Some(false), "poisoned request"),
    }]);
    let failed = delivery(&mut events).await;
    recover_failed_delivery(
        &bot,
        &failed,
        &route,
        "test_delivery_recovery",
        &std::io::Error::other("simulated deterministic failure"),
    )
    .await;

    let mut next = message(7, Some(false), "continue working");
    next.message_id = InlineId::new(10);
    backend.push_event_batch(vec![ClientEvent::MessageStored { message: next }]);
    let next = delivery(&mut events).await;
    assert!(matches!(
        next.event(),
        ClientEvent::MessageStored { message } if message.message_id.get() == 10
    ));
    accept_provider_unavailable_delivery(&bot, &next, &route)
        .await
        .expect("later delivery");

    let history = bot
        .history(HistoryRequest {
            chat_id: InlineId::new(706),
            limit: Some(10),
            before_message_id: None,
            after_message_id: None,
        })
        .await
        .expect("recovery history");
    assert!(history_contains(
        &history,
        "skipped it to keep later messages moving"
    ));
    assert_eq!(
        route
            .store
            .pending_inbound_bindings(&route.installation_id, 10)
            .expect("queued work")
            .len(),
        1
    );
    bot.shutdown().await.expect("shutdown");
}

#[tokio::test]
async fn unauthorized_messages_are_silent_before_admission_for_every_provider() {
    for provider in ["codex", "claude", "opencode", "amp"] {
        for case in ["dm", "command", "mention", "unknown", "voice", "revoked"] {
            let route = route(provider);
            let (bot, backend, mut events) = client().await;
            let mut message = message(9, Some(false), "hello");
            match case {
                "command" => {
                    message.content = MessageContent::Text {
                        text: "/status@test_bot".to_string(),
                    }
                }
                "mention" => mention(&mut message),
                "unknown" => message.metadata.sender_is_bot = None,
                "voice" => {
                    message.content = MessageContent::Media {
                        kind: inline_client::MediaKind::Voice,
                        file_id: "voice-test".to_string(),
                        url: None,
                        mime_type: Some("audio/ogg".to_string()),
                        file_name: None,
                        caption: None,
                        size_bytes: Some(42),
                        width: None,
                        height: None,
                        duration_ms: Some(1_000),
                    }
                }
                "revoked" => {
                    message.sender_id = InlineId::new(8);
                    route.replace_policy(OperatorPolicy::owner_only(7));
                }
                _ => {}
            }
            // A real DM shape exercises the old denial-reply path. Mentions
            // also cover shared chats where group membership grants no access.
            let mut dialog = DialogRecord::new(message.chat_id);
            if case != "mention" {
                dialog.peer_user_id = Some(message.sender_id);
            }
            route.bot_store.record_dialog(dialog).await.expect("dialog");
            backend.push_event_batch(vec![ClientEvent::MessageStored { message }]);
            let delivery = delivery(&mut events).await;
            let admission = inbound_from_delivery(&bot, &delivery, &route).await;
            if case == "unknown" {
                assert!(admission.unwrap_err().is::<UnverifiedMessageActor>());
            } else {
                assert!(admission.expect("admission").is_none(), "{provider}/{case}");
                delivery.ack().await.expect("ack ignored message");
            }
            let history = bot
                .history(HistoryRequest {
                    chat_id: InlineId::new(706),
                    limit: Some(10),
                    before_message_id: None,
                    after_message_id: None,
                })
                .await
                .expect("outbound history");
            assert!(
                history.messages.is_empty(),
                "unexpected reply: {provider}/{case}"
            );
            assert!(
                route
                    .store
                    .bound_chat_workspace(&route.installation_id, 706)
                    .expect("binding")
                    .is_none()
            );
            assert!(
                route
                    .pending_voice_messages
                    .lock()
                    .expect("voice registry")
                    .is_empty()
            );
            bot.shutdown().await.expect("shutdown");
        }
    }
}

#[tokio::test]
async fn owner_and_explicitly_allowlisted_users_keep_access() {
    for provider in ["codex", "claude", "opencode", "amp"] {
        for sender in [7, 8, 77] {
            let route = route(provider);
            let (bot, backend, mut events) = client().await;
            let mut message = message(sender, Some(sender == 77), "@bot help");
            if sender != 7 {
                mention(&mut message);
            }
            backend.push_event_batch(vec![ClientEvent::MessageStored { message }]);
            let delivery = delivery(&mut events).await;
            let record = inbound_from_delivery(&bot, &delivery, &route)
                .await
                .expect("admission")
                .expect("authorized message");
            assert_eq!(record.sender_user_id, sender);
            delivery.ack().await.expect("ack message");
            bot.shutdown().await.expect("shutdown");
        }
    }
}

#[tokio::test]
async fn unavailable_workspace_allows_only_owner_project_recovery_commands() {
    for (sender, text, allowed) in [
        (7, "/projects", true),
        (7, "/folder 1", true),
        (7, "/projects@test_bot", true),
        (7, "/projects@other_bot", false),
        (7, "continue working", false),
        (7, "/compact", false),
        (8, "/projects", false),
    ] {
        let route = route("codex");
        let root = tempfile::tempdir().unwrap();
        let workspace = root.path().join("project");
        fs::create_dir(&workspace).unwrap();
        let workspace_id = WorkspaceId::new("missing-project").unwrap();
        route
            .store
            .select_workspace(&route.installation_id, &workspace_id, &workspace, 1)
            .unwrap();
        route
            .store
            .bind_chat_workspace(&route.installation_id, 706, &workspace_id, 1)
            .unwrap();
        fs::rename(&workspace, root.path().join("moved-project")).unwrap();
        let (bot, backend, mut events) = client().await;
        backend.push_event_batch(vec![ClientEvent::MessageStored {
            message: message(sender, Some(false), text),
        }]);
        let delivery = delivery(&mut events).await;
        let record = inbound_from_delivery(&bot, &delivery, &route)
            .await
            .unwrap();
        assert_eq!(record.is_some(), allowed, "sender={sender} command={text}");
        assert_eq!(
            route
                .store
                .bound_chat_workspace(&route.installation_id, 706)
                .unwrap()
                .unwrap()
                .workspace_id,
            workspace_id
        );
        assert!(
            conversation_for_chat(&route, 706).is_err(),
            "recovery must not authorize ordinary execution"
        );
        delivery.ack().await.unwrap();
        bot.shutdown().await.unwrap();
    }
}

#[test]
fn explicit_project_and_projectless_chats_never_follow_recent_workspaces() {
    let route = route("codex");
    let recent = tempfile::tempdir().expect("recent project");
    route
        .store
        .select_workspace(
            &route.installation_id,
            &WorkspaceId::new("experiment").unwrap(),
            recent.path(),
            2,
        )
        .unwrap();
    let context = |project: &str| proto::AgentThreadContext {
        bot_user_id: route.bot_user_id,
        agent_id: None,
        configuration: Some(proto::AgentThreadConfiguration {
            project_id: Some(project.to_string()),
            model_id: Some("gpt-6-astra".to_string()),
            reasoning_effort_id: Some("low".to_string()),
        }),
    };
    let inline =
        conversation_for_chat_with_agent_context(&route, 6336, Some(&context("project")), true)
            .unwrap()
            .snapshot();
    assert_eq!(inline.binding.workspace_id.as_str(), "project");
    let settings = route.store.chat_settings(&inline.binding, 3).unwrap();
    assert_eq!(settings.model.as_deref(), Some("gpt-6-astra"));
    assert_eq!(settings.reasoning.as_deref(), Some("low"));
    let choices =
        projects::project_choices(&route.store, &route.installation_id, None, None).unwrap();
    let no_project = choices
        .iter()
        .find(|choice| choice.display_name == "No project")
        .unwrap();
    let projectless = conversation_for_chat_with_agent_context(
        &route,
        6336,
        Some(&context(no_project.workspace_id.as_str())),
        true,
    )
    .unwrap()
    .snapshot();
    assert_eq!(
        projectless.workspace,
        resolve_setup_workspace(None).unwrap()
    );
    assert_ne!(projectless.binding.workspace_id.as_str(), "experiment");
    // Resolution is repeatable across repeated route resolution; recents cannot undo clearing.
    route
        .store
        .select_workspace(
            &route.installation_id,
            &WorkspaceId::new("experiment").unwrap(),
            recent.path(),
            4,
        )
        .unwrap();
    let resumed = conversation_for_chat_with_agent_context(
        &route,
        6336,
        Some(&context(no_project.workspace_id.as_str())),
        true,
    )
    .unwrap()
    .snapshot();
    assert_eq!(resumed.binding, projectless.binding);
    assert!(matches!(
        conversation_for_chat_with_agent_context(&route, 7000, Some(&context("missing")), true),
        Err(ConversationResolutionError::MissingWorkspace)
    ));
    assert!(
        route
            .store
            .bound_chat_workspace(&route.installation_id, 7000)
            .unwrap()
            .is_none()
    );
}

#[tokio::test]
async fn settings_retry_rechecks_access_and_admits_the_original_request_once() {
    let mut route = route("codex");
    record_bound_dialog_with_project(&route, "project", "gpt-6-astra").await;
    let (bot, _, _) = client().await;
    let source = message(7, Some(false), "continue working");
    route.bot_store.insert_message(source.clone()).unwrap();
    let mut card = message(
        route.bot_user_id,
        Some(true),
        "Choose a project, then retry.",
    );
    card.message_id = InlineId::new(20);
    card.reply_to_message_id = Some(source.message_id);
    card.metadata.actions = vec![inline_client::MessageActionRecord {
        action_id: "bridge_settings_retry".to_string(),
        label: "Retry".to_string(),
        kind: "callback".to_string(),
    }];
    route.bot_store.insert_message(card.clone()).unwrap();
    let action = |actor| ClientEvent::MessageActionInvoked {
        interaction_id: InlineId::new(90),
        chat_id: source.chat_id,
        message_id: card.message_id,
        actor_user_id: InlineId::new(actor),
        action_id: "bridge_settings_retry".to_string(),
        data: b"bridge-settings-retry-v1".to_vec(),
    };
    // Restart cutoffs must not prevent an explicitly retried old request.
    route.accept_messages_after = 100;
    assert!(
        handle_settings_retry(&bot, &action(8), &route)
            .await
            .unwrap()
    );
    assert!(
        route
            .store
            .get_inbound("inline-message-706-9")
            .unwrap()
            .is_none()
    );
    for _ in 0..2 {
        assert!(
            handle_settings_retry(&bot, &action(7), &route)
                .await
                .unwrap()
        );
    }
    let record = route
        .store
        .get_inbound("inline-message-706-9")
        .unwrap()
        .unwrap();
    assert_eq!(record.binding.workspace_id.as_str(), "project");
    assert_eq!(
        route
            .store
            .pending_inbound_bindings(&route.installation_id, 10)
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        route
            .store
            .chat_settings(&record.binding, 3)
            .unwrap()
            .model
            .as_deref(),
        Some("gpt-6-astra")
    );
    bot.shutdown().await.unwrap();
}
