use super::*;
use inline_client::{
    AuthCredential, AuthToken, ConnectRequest, DialogRecord, HistoryRequest, InMemoryBackend,
    LosslessEventReceiver, MessageEntityRecord, MessageMetadata,
};

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
            if matches!(event.event(), ClientEvent::MessageStored { .. }) {
                return event;
            }
            event.ack().await.expect("ack status");
        }
    })
    .await
    .expect("message delivery deadline")
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
            assert!(
                inbound_from_delivery(&bot, &delivery, &route)
                    .await
                    .expect("admission")
                    .is_none(),
                "{provider}/{case}"
            );
            delivery.ack().await.expect("ack ignored message");
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
