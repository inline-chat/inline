use super::*;

use std::sync::{
    Mutex,
    atomic::{AtomicUsize, Ordering},
};

use inline_client::{MessageMutation, RandomId, TransactionId, TransactionIdentity};

fn voice_message(
    caption: Option<&str>,
    edit_timestamp: Option<i64>,
) -> inline_client::MessageRecord {
    inline_client::MessageRecord {
        chat_id: InlineId::new(42),
        message_id: InlineId::new(9),
        sender_id: InlineId::new(7),
        timestamp: 1,
        is_outgoing: false,
        content: MessageContent::Media {
            kind: inline_client::MediaKind::Voice,
            file_id: "voice-1".to_string(),
            url: Some("https://cdn.inline.chat/voice.ogg".to_string()),
            mime_type: Some("audio/ogg".to_string()),
            file_name: None,
            caption: caption.map(str::to_string),
            size_bytes: Some(42),
            width: None,
            height: None,
            duration_ms: Some(1_000),
        },
        reply_to_message_id: None,
        metadata: inline_client::MessageMetadata {
            edit_timestamp,
            ..inline_client::MessageMetadata::default()
        },
        transaction: None,
    }
}

#[test]
fn only_an_unedited_blank_voice_message_waits_for_transcription() {
    assert!(should_wait_for_voice_transcript(&voice_message(None, None)));
    assert!(!should_wait_for_voice_transcript(&voice_message(
        Some("transcript"),
        Some(2)
    )));
    assert!(!should_wait_for_voice_transcript(&voice_message(
        None,
        Some(2)
    )));
}

#[test]
fn projected_agent_session_history_is_rejected_before_idle_or_active_handling() {
    let mut message = voice_message(None, None);
    message.metadata.agent_session = Some(inline_client::AgentSessionMessageMetadata {
        agent_session_id: 42,
        provider: proto::AgentSessionProvider::Codex as i32,
        role: proto::AgentSessionMessageRole::User as i32,
        relation: proto::AgentSessionMessageRelation::Imported as i32,
    });

    assert!(is_agent_session_projection(&message));
    assert!(is_agent_session_projection_event(
        &ClientEvent::MessageStored { message }
    ));
}

#[test]
fn pending_voice_registry_deduplicates_replacements_and_cancels_per_chat() {
    let route = InboundRoute {
        store: Arc::new(BridgeStore::open_in_memory().expect("bridge store")),
        installation_id: InstallationId::new("codex").expect("installation"),
        provider_id: ProviderId::new("codex").expect("provider"),
        policy: Arc::new(RwLock::new(OperatorPolicy::owner_only(7))),
        owner_user_id: 7,
        host_label: "Test Mac".to_string(),
        owner_dm_chat_id: 706,
        bot_user_id: 17,
        bot_username: "mo_codex_bot".to_string(),
        bot_store: SqliteStore::open_in_memory().expect("bot store"),
        attachment_cache_dir: PathBuf::from("/tmp/inline-agent-bridge-test-attachments"),
        owner_control: None,
        accept_messages_after: 0,
        deferred_inbound_tx: tokio::sync::mpsc::channel(MAX_PENDING_VOICE_TRANSCRIPTS).0,
        pending_voice_messages: Arc::new(std::sync::Mutex::new(HashSet::new())),
        claude_history: None,
        session_browser: SessionBrowserRuntime::default(),
    };

    assert_eq!(
        route.register_pending_voice(42, 9),
        PendingVoiceRegistration::Registered
    );
    assert_eq!(
        route.register_pending_voice(42, 9),
        PendingVoiceRegistration::Duplicate
    );
    assert_eq!(
        route.register_pending_voice(43, 10),
        PendingVoiceRegistration::Registered
    );
    assert_eq!(route.cancel_pending_voices_in_chat(42), 1);
    assert!(!route.take_pending_voice(42, 9));
    assert!(route.take_pending_voice(43, 10));
}

#[test]
fn pending_voice_registry_is_bounded() {
    let route = InboundRoute {
        store: Arc::new(BridgeStore::open_in_memory().expect("bridge store")),
        installation_id: InstallationId::new("codex").expect("installation"),
        provider_id: ProviderId::new("codex").expect("provider"),
        policy: Arc::new(RwLock::new(OperatorPolicy::owner_only(7))),
        owner_user_id: 7,
        host_label: "Test Mac".to_string(),
        owner_dm_chat_id: 706,
        bot_user_id: 17,
        bot_username: "mo_codex_bot".to_string(),
        bot_store: SqliteStore::open_in_memory().expect("bot store"),
        attachment_cache_dir: PathBuf::from("/tmp/inline-agent-bridge-test-attachments"),
        owner_control: None,
        accept_messages_after: 0,
        deferred_inbound_tx: tokio::sync::mpsc::channel(MAX_PENDING_VOICE_TRANSCRIPTS).0,
        pending_voice_messages: Arc::new(std::sync::Mutex::new(HashSet::new())),
        claude_history: None,
        session_browser: SessionBrowserRuntime::default(),
    };

    for message_id in 1..=MAX_PENDING_VOICE_TRANSCRIPTS as i64 {
        assert_eq!(
            route.register_pending_voice(42, message_id),
            PendingVoiceRegistration::Registered
        );
    }
    assert_eq!(
        route.register_pending_voice(42, MAX_PENDING_VOICE_TRANSCRIPTS as i64 + 1),
        PendingVoiceRegistration::AtCapacity
    );
}

#[test]
fn command_lowering_replaces_text_without_dropping_queued_media() {
    let attachment = inline_agent_bridge::InputAttachment {
        kind: inline_agent_bridge::InputAttachmentKind::Image,
        uri: "https://cdn.inline.chat/photo.png".to_string(),
        local_uri: None,
        mime_type: Some("image/png".to_string()),
        file_name: Some("photo.png".to_string()),
        size_bytes: Some(42),
        width: Some(10),
        height: Some(20),
        duration_ms: None,
    };
    let mut direction = Direction::new(
        DirectionId::new("event-1").expect("direction"),
        "/queue send this",
    )
    .with_attachments(vec![attachment.clone()]);

    replace_direction_text(&mut direction, "send this");

    assert_eq!(direction.text, "send this");
    assert_eq!(direction.attachments, vec![attachment]);
}

#[test]
fn ordinary_progress_is_top_level_but_explicit_status_can_reply() {
    let progress = build_text_request(
        42,
        None,
        "Working…",
        "event-working",
        SendNotificationMode::Silent,
    )
    .expect("progress request");
    assert_eq!(progress.reply_to_message_id, None);
    assert!(progress.parse_markdown);

    let queued = build_text_request(
        42,
        Some(7),
        "Queued for next.",
        "event-queued",
        SendNotificationMode::Normal,
    )
    .expect("queued request");
    assert_eq!(queued.reply_to_message_id, Some(InlineId::new(7)));
    assert!(queued.parse_markdown);
}

#[test]
fn unbound_chat_without_a_default_workspace_binds_the_user_home() {
    let store = Arc::new(BridgeStore::open_in_memory().expect("bridge store"));
    let installation_id = InstallationId::new("codex").expect("installation");
    store
        .put_installation(&InstallationRecord {
            installation_id: installation_id.clone(),
            provider_id: ProviderId::new("codex").expect("provider"),
            display_name: "Codex".to_string(),
            created_at: 1,
            updated_at: 1,
        })
        .expect("put installation");
    let route = InboundRoute {
        store: store.clone(),
        installation_id: installation_id.clone(),
        provider_id: ProviderId::new("codex").expect("provider"),
        policy: Arc::new(RwLock::new(OperatorPolicy::owner_only(7))),
        owner_user_id: 7,
        host_label: "Test Mac".to_string(),
        owner_dm_chat_id: 706,
        bot_user_id: 17,
        bot_username: "mo_codex_bot".to_string(),
        bot_store: SqliteStore::open_in_memory().expect("bot store"),
        attachment_cache_dir: PathBuf::from("/tmp/inline-agent-bridge-test-attachments"),
        owner_control: None,
        accept_messages_after: 0,
        deferred_inbound_tx: tokio::sync::mpsc::channel(MAX_PENDING_VOICE_TRANSCRIPTS).0,
        pending_voice_messages: Arc::new(std::sync::Mutex::new(HashSet::new())),
        claude_history: None,
        session_browser: SessionBrowserRuntime::default(),
    };

    let conversation = conversation_for_chat(&route, 706).expect("home workspace");
    let home = resolve_setup_workspace(None).expect("test home");
    let snapshot = conversation.snapshot();
    assert_eq!(snapshot.workspace, home);
    assert_eq!(
        store
            .bound_chat_workspace(&installation_id, 706)
            .expect("bound workspace")
            .expect("home binding")
            .workspace_id,
        snapshot.binding.workspace_id
    );
}

#[test]
fn unbound_chat_with_a_replaced_default_workspace_binds_the_user_home() {
    let store = Arc::new(BridgeStore::open_in_memory().expect("bridge store"));
    let installation_id = InstallationId::new("codex").expect("installation");
    store
        .put_installation(&InstallationRecord {
            installation_id: installation_id.clone(),
            provider_id: ProviderId::new("codex").expect("provider"),
            display_name: "Codex".to_string(),
            created_at: 1,
            updated_at: 1,
        })
        .expect("put installation");
    let root = tempfile::tempdir().expect("workspace root");
    let workspace = root.path().join("project");
    let original = root.path().join("project-original");
    fs::create_dir(&workspace).expect("workspace");
    let workspace_id = WorkspaceId::new("workspace-inline").expect("workspace id");
    store
        .select_workspace(&installation_id, &workspace_id, &workspace, 1)
        .expect("select workspace");
    fs::rename(&workspace, &original).expect("move original workspace");
    fs::create_dir(&workspace).expect("replacement workspace");
    let route = InboundRoute {
        store: store.clone(),
        installation_id: installation_id.clone(),
        provider_id: ProviderId::new("codex").expect("provider"),
        policy: Arc::new(RwLock::new(OperatorPolicy::owner_only(7))),
        owner_user_id: 7,
        host_label: "Test Mac".to_string(),
        owner_dm_chat_id: 706,
        bot_user_id: 17,
        bot_username: "mo_codex_bot".to_string(),
        bot_store: SqliteStore::open_in_memory().expect("bot store"),
        attachment_cache_dir: PathBuf::from("/tmp/inline-agent-bridge-test-attachments"),
        owner_control: None,
        accept_messages_after: 0,
        deferred_inbound_tx: tokio::sync::mpsc::channel(MAX_PENDING_VOICE_TRANSCRIPTS).0,
        pending_voice_messages: Arc::new(std::sync::Mutex::new(HashSet::new())),
        claude_history: None,
        session_browser: SessionBrowserRuntime::default(),
    };

    let conversation = conversation_for_chat(&route, 707).expect("home fallback");
    let home = resolve_setup_workspace(None).expect("test home");
    let snapshot = conversation.snapshot();
    assert_eq!(snapshot.workspace, home);
    assert_ne!(snapshot.binding.workspace_id, workspace_id);
}

#[test]
fn unbound_chat_settings_stay_owner_only_and_repair_promoted_cache() {
    let store = Arc::new(BridgeStore::open_in_memory().expect("bridge store"));
    let installation_id = InstallationId::new("codex").expect("installation");
    let workspace_id = WorkspaceId::new("workspace-inline").expect("workspace");
    let workspace = tempfile::tempdir().expect("workspace");
    store
        .put_installation(&InstallationRecord {
            installation_id: installation_id.clone(),
            provider_id: ProviderId::new("codex").expect("provider"),
            display_name: "Codex".to_string(),
            created_at: 1,
            updated_at: 1,
        })
        .expect("put installation");
    store
        .select_workspace(&installation_id, &workspace_id, workspace.path(), 1)
        .expect("select workspace");
    let route = InboundRoute {
        store: store.clone(),
        installation_id: installation_id.clone(),
        provider_id: ProviderId::new("codex").expect("provider"),
        policy: Arc::new(RwLock::new(OperatorPolicy::owner_only(7))),
        owner_user_id: 7,
        host_label: "Test Mac".to_string(),
        owner_dm_chat_id: 706,
        bot_user_id: 17,
        bot_username: "mo_codex_bot".to_string(),
        bot_store: SqliteStore::open_in_memory().expect("bot store"),
        attachment_cache_dir: PathBuf::from("/tmp/inline-agent-bridge-test-attachments"),
        owner_control: None,
        accept_messages_after: 0,
        deferred_inbound_tx: tokio::sync::mpsc::channel(MAX_PENDING_VOICE_TRANSCRIPTS).0,
        pending_voice_messages: Arc::new(std::sync::Mutex::new(HashSet::new())),
        claude_history: None,
        session_browser: SessionBrowserRuntime::default(),
    };

    let conversation = conversation_for_chat(&route, 998).expect("unbound chat should resolve");
    let snapshot = conversation.snapshot();
    assert_eq!(snapshot.binding.workspace_id, workspace_id);
    assert_eq!(
        snapshot.workspace,
        fs::canonicalize(workspace.path()).expect("canonical workspace")
    );
    assert!(
        store
            .bound_chat_workspace(&installation_id, 998)
            .expect("read automatic binding")
            .is_some()
    );

    let event = ClientEvent::BotInteraction(BotInteractionEvent::ChatSettingsRequested {
        request_id: 1,
        chat_id: InlineId::new(999),
        actor_user_id: InlineId::new(8),
        version: 1,
    });

    let resolution = conversation_for_settings_event(&route, &event, None)
        .expect("authorization should be resolved without storage mutation");

    assert!(matches!(
        resolution,
        SettingsConversationResolution::Unauthorized
    ));
    assert!(
        store
            .bound_chat_workspace(&installation_id, 999)
            .expect("read binding")
            .is_none()
    );

    let owner_dm_event = ClientEvent::BotInteraction(BotInteractionEvent::ChatSettingsRequested {
        request_id: 2,
        chat_id: InlineId::new(route.owner_dm_chat_id),
        actor_user_id: InlineId::new(route.owner_user_id),
        version: 1,
    });
    let resolution = conversation_for_settings_event(&route, &owner_dm_event, None)
        .expect("owner DM settings should resolve");
    let SettingsConversationResolution::Ready(conversation) = resolution else {
        panic!("owner thread settings should be ready");
    };
    let snapshot = conversation.snapshot();
    assert_eq!(snapshot.binding.chat_id, route.owner_dm_chat_id);
    assert_eq!(snapshot.binding.workspace_id, workspace_id);
    assert!(
        store
            .bound_chat_workspace(&installation_id, route.owner_dm_chat_id)
            .expect("read binding")
            .is_some()
    );

    let reply_thread_binding = BindingKey {
        installation_id: installation_id.clone(),
        chat_id: 1_000,
        workspace_id: workspace_id.clone(),
    };
    conversation.replace(reply_thread_binding.clone(), workspace.path().to_path_buf());

    let mut conversations = HashMap::from([(route.owner_dm_chat_id, conversation.clone())]);
    repair_promoted_conversation_cache(
        &route,
        &mut conversations,
        route.owner_dm_chat_id,
        reply_thread_binding.chat_id,
    )
    .expect("promotion should preserve exact-chat cache entries");
    assert_eq!(
        conversations
            .get(&route.owner_dm_chat_id)
            .expect("repaired DM cache")
            .snapshot()
            .binding
            .chat_id,
        route.owner_dm_chat_id
    );
    assert_eq!(
        conversations
            .get(&reply_thread_binding.chat_id)
            .expect("promoted thread cache")
            .snapshot()
            .binding,
        reply_thread_binding
    );

    let resolution = conversation_for_settings_event(&route, &owner_dm_event, Some(&conversation))
        .expect("stale cached settings conversation should be repaired");
    let SettingsConversationResolution::Ready(repaired) = resolution else {
        panic!("owner DM settings should remain ready after reply-thread promotion");
    };
    assert_eq!(repaired.snapshot().binding.chat_id, route.owner_dm_chat_id);
    assert_eq!(repaired.snapshot().binding.workspace_id, workspace_id);
    assert_eq!(
        conversation.snapshot().binding,
        reply_thread_binding,
        "repairing the cache must not mutate the conversation held by the active reply-thread turn"
    );
}

#[test]
fn unavailable_bound_workspace_does_not_silently_switch_to_home() {
    let store = Arc::new(BridgeStore::open_in_memory().expect("bridge store"));
    let installation_id = InstallationId::new("codex").expect("installation");
    let workspace_id = WorkspaceId::new("workspace-inline").expect("workspace");
    store
        .put_installation(&InstallationRecord {
            installation_id: installation_id.clone(),
            provider_id: ProviderId::new("codex").expect("provider"),
            display_name: "Codex".to_string(),
            created_at: 1,
            updated_at: 1,
        })
        .expect("put installation");
    store
        .select_workspace(
            &installation_id,
            &workspace_id,
            &std::env::current_dir().expect("cwd"),
            1,
        )
        .expect("select workspace");
    store
        .bind_chat_workspace(&installation_id, 706, &workspace_id, 1)
        .expect("bind workspace");
    assert!(
        store
            .mark_workspace_unavailable(&installation_id, &workspace_id, 2)
            .expect("mark unavailable")
    );
    let route = InboundRoute {
        store: store.clone(),
        installation_id: installation_id.clone(),
        provider_id: ProviderId::new("codex").expect("provider"),
        policy: Arc::new(RwLock::new(OperatorPolicy::owner_only(7))),
        owner_user_id: 7,
        host_label: "Test Mac".to_string(),
        owner_dm_chat_id: 706,
        bot_user_id: 17,
        bot_username: "mo_codex_bot".to_string(),
        bot_store: SqliteStore::open_in_memory().expect("bot store"),
        attachment_cache_dir: PathBuf::from("/tmp/inline-agent-bridge-test-attachments"),
        owner_control: None,
        accept_messages_after: 0,
        deferred_inbound_tx: tokio::sync::mpsc::channel(MAX_PENDING_VOICE_TRANSCRIPTS).0,
        pending_voice_messages: Arc::new(std::sync::Mutex::new(HashSet::new())),
        claude_history: None,
        session_browser: SessionBrowserRuntime::default(),
    };

    let error = conversation_for_chat(&route, 706).expect_err("workspace should be unavailable");
    assert!(matches!(
        error,
        ConversationResolutionError::MissingWorkspace
    ));
    assert_eq!(
        store
            .bound_chat_workspace(&installation_id, 706)
            .expect("bound workspace")
            .expect("original binding")
            .workspace_id,
        workspace_id
    );

    let settings_event = ClientEvent::BotInteraction(BotInteractionEvent::ChatSettingsRequested {
        request_id: 3,
        chat_id: InlineId::new(706),
        actor_user_id: InlineId::new(route.owner_user_id),
        version: 1,
    });
    let resolution = conversation_for_settings_event(&route, &settings_event, None)
        .expect("owner settings should remain available for explicit folder recovery");
    let SettingsConversationResolution::Ready(recovery) = resolution else {
        panic!("missing workspace recovery should open settings");
    };
    assert_eq!(recovery.snapshot().binding.workspace_id, workspace_id);
    assert_eq!(
        store
            .bound_chat_workspace(&installation_id, 706)
            .expect("preserved recovery binding")
            .expect("original binding")
            .workspace_id,
        workspace_id
    );
}

#[derive(Debug)]
struct FaultingStreamTransport {
    remaining_edit_failures: AtomicUsize,
    remaining_send_failures: AtomicUsize,
    edits: AtomicUsize,
    sends: AtomicUsize,
    media_sends: AtomicUsize,
    silent_sends: AtomicUsize,
    edit_requests: Mutex<Vec<EditMessageRequest>>,
    send_requests: Mutex<Vec<SendTextRequest>>,
    silent_message_id: InlineId,
    normal_message_id: InlineId,
}

impl FaultingStreamTransport {
    fn new(edit_failures: usize, send_failures: usize, replacement_message_id: i64) -> Self {
        Self {
            remaining_edit_failures: AtomicUsize::new(edit_failures),
            remaining_send_failures: AtomicUsize::new(send_failures),
            edits: AtomicUsize::new(0),
            sends: AtomicUsize::new(0),
            media_sends: AtomicUsize::new(0),
            silent_sends: AtomicUsize::new(0),
            edit_requests: Mutex::new(Vec::new()),
            send_requests: Mutex::new(Vec::new()),
            silent_message_id: InlineId::new(replacement_message_id),
            normal_message_id: InlineId::new(replacement_message_id + 1),
        }
    }

    fn fail_once(counter: &AtomicUsize) -> bool {
        counter
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |remaining| {
                remaining.checked_sub(1)
            })
            .is_ok()
    }
}

impl StreamMessageTransport for FaultingStreamTransport {
    async fn edit(&self, request: EditMessageRequest) -> Result<(), Box<dyn std::error::Error>> {
        self.edits.fetch_add(1, Ordering::Relaxed);
        self.edit_requests
            .lock()
            .expect("edit requests")
            .push(request);
        if Self::fail_once(&self.remaining_edit_failures) {
            Err(io::Error::new(io::ErrorKind::ConnectionReset, "injected edit failure").into())
        } else {
            Ok(())
        }
    }

    async fn send(
        &self,
        request: SendTextRequest,
    ) -> Result<MessageMutation, Box<dyn std::error::Error>> {
        self.sends.fetch_add(1, Ordering::Relaxed);
        let message_id = if request.notification_mode == SendNotificationMode::Silent {
            self.silent_sends.fetch_add(1, Ordering::Relaxed);
            self.silent_message_id
        } else {
            self.normal_message_id
        };
        self.send_requests
            .lock()
            .expect("send requests")
            .push(request.clone());
        if Self::fail_once(&self.remaining_send_failures) {
            return Err(
                io::Error::new(io::ErrorKind::ConnectionReset, "injected send failure").into(),
            );
        }
        Ok(MessageMutation {
            transaction: TransactionIdentity::new(
                TransactionId::try_new("stream-test").expect("transaction"),
                request.external_id,
                request.random_id.unwrap_or(RandomId::new(1)),
            )
            .with_final_message_id(message_id),
            message_id: Some(message_id),
            state: None,
            failure: None,
        })
    }

    async fn send_media(
        &self,
        request: UploadRequest,
        _bytes: Vec<u8>,
    ) -> Result<MessageMutation, Box<dyn std::error::Error>> {
        self.sends.fetch_add(1, Ordering::Relaxed);
        self.media_sends.fetch_add(1, Ordering::Relaxed);
        if Self::fail_once(&self.remaining_send_failures) {
            return Err(
                io::Error::new(io::ErrorKind::ConnectionReset, "injected send failure").into(),
            );
        }
        Ok(MessageMutation {
            transaction: TransactionIdentity::new(
                TransactionId::try_new("media-stream-test").expect("transaction"),
                request.external_id,
                request.random_id.unwrap_or(RandomId::new(1)),
            )
            .with_final_message_id(self.normal_message_id),
            message_id: Some(self.normal_message_id),
            state: None,
            failure: None,
        })
    }
}

#[tokio::test]
async fn final_delivery_uploads_a_verified_generated_image_before_text() {
    let directory = tempfile::tempdir().expect("tempdir");
    let path = directory.path().join("generated.png");
    let bytes = b"\x89PNG\r\n\x1a\nverified-output";
    fs::write(&path, bytes).expect("write output");
    let attachment = OutputAttachment {
        id: "image-1".to_string(),
        kind: OutputAttachmentKind::Image,
        path,
        mime_type: "image/png".to_string(),
        file_name: "generated-image.png".to_string(),
        size_bytes: bytes.len() as u64,
        sha256: format!("{:x}", Sha256::digest(bytes)),
    };
    let transport = FaultingStreamTransport::new(0, 0, 40);

    let mutation = deliver_pending_final_with_attachments_transport(
        &transport,
        "event-1",
        42,
        None,
        "Worked for 1s",
        RandomId::new(77),
        "Done.",
        &[attachment],
        |_| Duration::ZERO,
    )
    .await
    .expect("deliver output and text");

    assert_eq!(transport.media_sends.load(Ordering::Relaxed), 1);
    assert_eq!(transport.sends.load(Ordering::Relaxed), 2);
    assert_eq!(mutation.message_id, Some(transport.normal_message_id));
}

#[tokio::test]
async fn final_delivery_rejects_a_generated_image_changed_after_staging() {
    let directory = tempfile::tempdir().expect("tempdir");
    let path = directory.path().join("generated.png");
    let original = b"\x89PNG\r\n\x1a\noriginal";
    fs::write(&path, original).expect("write output");
    let attachment = OutputAttachment {
        id: "image-1".to_string(),
        kind: OutputAttachmentKind::Image,
        path: path.clone(),
        mime_type: "image/png".to_string(),
        file_name: "generated-image.png".to_string(),
        size_bytes: original.len() as u64,
        sha256: format!("{:x}", Sha256::digest(original)),
    };
    fs::write(&path, b"\x89PNG\r\n\x1a\ntampered").expect("tamper output");
    let transport = FaultingStreamTransport::new(0, 0, 40);

    let error = deliver_pending_final_with_attachments_transport(
        &transport,
        "event-1",
        42,
        None,
        "Worked for 1s",
        RandomId::new(77),
        "Done.",
        &[attachment],
        |_| Duration::ZERO,
    )
    .await
    .expect_err("changed output must fail");

    assert!(error.to_string().contains("output attachment"));
    assert_eq!(transport.media_sends.load(Ordering::Relaxed), 0);
}

#[derive(Debug, Default)]
struct RecordingTypingTransport {
    calls: Mutex<Vec<(i64, bool)>>,
    fail_every_call: bool,
    hang_every_call: bool,
}

impl RecordingTypingTransport {
    fn failing() -> Self {
        Self {
            calls: Mutex::new(Vec::new()),
            fail_every_call: true,
            hang_every_call: false,
        }
    }

    fn hanging() -> Self {
        Self {
            calls: Mutex::new(Vec::new()),
            fail_every_call: false,
            hang_every_call: true,
        }
    }

    fn calls(&self) -> Vec<(i64, bool)> {
        self.calls.lock().expect("typing calls").clone()
    }
}

impl TypingTransport for RecordingTypingTransport {
    async fn send_typing(
        &self,
        chat_id: InlineId,
        is_typing: bool,
    ) -> Result<(), Box<dyn std::error::Error>> {
        self.calls
            .lock()
            .expect("typing calls")
            .push((chat_id.get(), is_typing));
        if self.hang_every_call {
            std::future::pending::<()>().await;
        }
        if self.fail_every_call {
            Err(io::Error::new(io::ErrorKind::ConnectionReset, "injected typing failure").into())
        } else {
            Ok(())
        }
    }
}

async fn exercise_typing_lifecycle(transport: &RecordingTypingTransport, chat_id: i64) {
    let mut typing = TypingIndicator::start(transport, chat_id).await;
    typing.heartbeat().await;
    typing.stop().await;

    // Terminal cleanup is deliberately idempotent: success, provider error,
    // and user cancellation all converge on the same clear operation.
    typing.stop().await;
    typing.heartbeat().await;
}

#[tokio::test]
async fn typing_lifecycle_targets_the_owner_dm_conversation() {
    let transport = RecordingTypingTransport::default();
    exercise_typing_lifecycle(&transport, 706).await;
    assert_eq!(
        transport.calls(),
        vec![(706, true), (706, true), (706, false)]
    );
}

#[tokio::test]
async fn typing_lifecycle_keeps_the_child_reply_thread_target() {
    let transport = RecordingTypingTransport::default();
    exercise_typing_lifecycle(&transport, 708).await;
    assert_eq!(
        transport.calls(),
        vec![(708, true), (708, true), (708, false)]
    );
}

#[tokio::test]
async fn typing_transport_errors_do_not_skip_heartbeat_or_terminal_clear() {
    let transport = RecordingTypingTransport::failing();
    exercise_typing_lifecycle(&transport, 708).await;
    assert_eq!(
        transport.calls(),
        vec![(708, true), (708, true), (708, false)]
    );
}

#[tokio::test]
async fn stalled_typing_transport_cannot_block_turn_startup() {
    let transport = RecordingTypingTransport::hanging();
    let _typing = tokio::time::timeout(
        Duration::from_millis(100),
        TypingIndicator::start(&transport, 706),
    )
    .await
    .expect("typing startup must remain best effort");
    assert_eq!(transport.calls(), vec![(706, true)]);
}

fn activity_snapshot(
    id: &str,
    kind: ActivitySemanticKind,
    status: ActivityStatus,
    title: &str,
) -> ActivityUpsert {
    ActivityUpsert::new(id, kind, status, title).expect("activity")
}

#[test]
fn structured_activity_upserts_replace_by_id_and_count_concurrency() {
    let mut tracker = ActivityTracker::default();
    let workspace = Path::new("/workspace");
    let first = activity_snapshot(
        "command-1",
        ActivitySemanticKind::Execute,
        ActivityStatus::InProgress,
        "cargo test",
    )
    .with_detail("cargo test -p inline-agent-bridge");
    let update = tracker.apply(first, VisibilityMode::Normal, workspace);
    assert_eq!(update.status.as_deref(), Some(WORKING_STATUS));
    assert!(update.validation.is_none());

    let second = activity_snapshot(
        "read-1",
        ActivitySemanticKind::Read,
        ActivityStatus::InProgress,
        "Reading driver.rs",
    );
    let update = tracker.apply(second, VisibilityMode::Normal, workspace);
    assert_eq!(update.status.as_deref(), Some(WORKING_STATUS));

    let second = activity_snapshot(
        "read-1",
        ActivitySemanticKind::Read,
        ActivityStatus::Completed,
        "Reading driver.rs",
    );
    let update = tracker.apply(second, VisibilityMode::Normal, workspace);
    assert_eq!(update.status.as_deref(), Some(WORKING_STATUS));

    let first = activity_snapshot(
        "command-1",
        ActivitySemanticKind::Execute,
        ActivityStatus::Completed,
        "cargo test",
    )
    .with_exit_code(Some(0));
    let update = tracker.apply(first, VisibilityMode::Normal, workspace);
    assert_eq!(update.status.as_deref(), Some(WORKING_STATUS));
    assert_eq!(
        update.validation,
        Some(ValidationSummary::Passed("cargo test".to_string()))
    );
}

#[test]
fn structured_activity_failure_and_decline_have_truthful_semantics() {
    let mut tracker = ActivityTracker::default();
    let workspace = Path::new("/workspace");
    let failed = activity_snapshot(
        "tool-1",
        ActivitySemanticKind::Other,
        ActivityStatus::Failed,
        "Fetch metadata",
    );
    let update = tracker.apply(failed, VisibilityMode::Normal, workspace);
    assert_eq!(update.priority, UpdatePriority::Attention);
    assert_eq!(update.status.as_deref(), Some(WORKING_STATUS));

    let declined = activity_snapshot(
        "command-2",
        ActivitySemanticKind::Execute,
        ActivityStatus::Declined,
        "cargo check",
    );
    let update = tracker.apply(declined, VisibilityMode::Normal, workspace);
    assert_eq!(update.status.as_deref(), Some(WORKING_STATUS));
    assert!(matches!(
        update.validation,
        Some(ValidationSummary::NotRun(_))
    ));
}

#[test]
fn structured_activity_failure_preempts_concurrent_work() {
    let mut tracker = ActivityTracker::default();
    let workspace = Path::new("/workspace");
    let active = activity_snapshot(
        "read-1",
        ActivitySemanticKind::Read,
        ActivityStatus::InProgress,
        "Reading driver.rs",
    );
    assert!(
        tracker
            .apply(active, VisibilityMode::Normal, workspace)
            .status
            .is_some()
    );

    let failed = activity_snapshot(
        "command-1",
        ActivitySemanticKind::Execute,
        ActivityStatus::Completed,
        "Running command",
    )
    .with_exit_code(Some(1));
    let update = tracker.apply(failed, VisibilityMode::Normal, workspace);
    assert_eq!(update.priority, UpdatePriority::Attention);
    assert_eq!(update.status.as_deref(), Some(WORKING_STATUS));
}

#[test]
fn verbose_activity_ledger_keeps_order_and_updates_rows_in_place() {
    let mut tracker = ActivityTracker::default();
    let workspace = Path::new("/workspace");
    let command = activity_snapshot(
        "command-1",
        ActivitySemanticKind::Execute,
        ActivityStatus::InProgress,
        "cargo test",
    )
    .with_detail("cargo test");
    tracker.apply(command, VisibilityMode::Verbose, workspace);
    let read = activity_snapshot(
        "read-1",
        ActivitySemanticKind::Read,
        ActivityStatus::InProgress,
        "Reading runtime.rs",
    )
    .with_paths(vec![PathBuf::from("/workspace/cli/src/bridge/runtime.rs")]);
    let rendered = tracker
        .apply(read, VisibilityMode::Verbose, workspace)
        .status
        .expect("verbose ledger");
    assert!(rendered.contains("`cargo test`"));
    assert!(rendered.contains("`cli/src/bridge/runtime.rs`"));

    let completed = activity_snapshot(
        "command-1",
        ActivitySemanticKind::Execute,
        ActivityStatus::Completed,
        "cargo test",
    )
    .with_detail("cargo test")
    .with_exit_code(Some(0));
    let rendered = tracker
        .apply(completed, VisibilityMode::Verbose, workspace)
        .status
        .expect("verbose ledger");
    assert_eq!(rendered.matches("cargo test").count(), 1);
    assert!(rendered.find("cargo test").unwrap() < rendered.find("Reading runtime.rs").unwrap());
}

#[test]
fn verbose_activity_ledger_adds_command_detail_from_a_later_provider_update() {
    let mut tracker = ActivityTracker::default();
    let workspace = Path::new("/workspace");
    tracker.apply(
        activity_snapshot(
            "command-1",
            ActivitySemanticKind::Execute,
            ActivityStatus::Pending,
            "Running command",
        ),
        VisibilityMode::Verbose,
        workspace,
    );

    let rendered = tracker
        .apply(
            activity_snapshot(
                "command-1",
                ActivitySemanticKind::Execute,
                ActivityStatus::InProgress,
                "Running command",
            )
            .with_detail("printf 'VISIBLE_COMMAND\\n'"),
            VisibilityMode::Verbose,
            workspace,
        )
        .status
        .expect("verbose ledger");

    assert!(rendered.contains("`printf 'VISIBLE_COMMAND\\n'`"));
}

#[test]
fn verbose_activity_renderer_redacts_command_details_again() {
    let mut tracker = ActivityTracker::default();
    let rendered = tracker
        .apply(
            activity_snapshot(
                "command-secret",
                ActivitySemanticKind::Execute,
                ActivityStatus::InProgress,
                "Running command",
            )
            .with_detail("deploy --api-key must-not-appear https://example.com/file?token=private"),
            VisibilityMode::Verbose,
            Path::new("/workspace"),
        )
        .status
        .expect("verbose ledger");
    assert!(rendered.contains("deploy --api-key [redacted]"));
    assert!(rendered.contains("https://example.com/file?[redacted]"));
    assert!(!rendered.contains("must-not-appear"));
    assert!(!rendered.contains("token=private"));
}

#[test]
fn terminalizing_a_turn_clears_every_active_progress_marker() {
    let mut tracker = ActivityTracker::default();
    let workspace = Path::new("/workspace");
    tracker.apply(
        activity_snapshot(
            "command-1",
            ActivitySemanticKind::Execute,
            ActivityStatus::InProgress,
            "Running command",
        )
        .with_detail("cargo test -p inline-cli"),
        VisibilityMode::Verbose,
        workspace,
    );
    tracker.apply(
        activity_snapshot(
            "read-1",
            ActivitySemanticKind::Read,
            ActivityStatus::Pending,
            "Reading runtime.rs",
        ),
        VisibilityMode::Verbose,
        workspace,
    );

    tracker.terminalize_active(ActivityStatus::Cancelled);
    let rendered = tracker
        .render(VisibilityMode::Verbose, "Stopped after 1s", workspace)
        .expect("terminal progress");
    assert!(!rendered.contains("- →"));
    assert_eq!(rendered.matches("- ×").count(), 2);
}

#[test]
fn extracts_only_terminal_validation_facts() {
    assert!(matches!(
        validation_summary_from_provider("Command completed: cargo test"),
        Some(ValidationSummary::Passed(_))
    ));
    assert!(matches!(
        validation_summary_from_provider("Tests failed: cargo test"),
        Some(ValidationSummary::Failed(_))
    ));
    assert_eq!(validation_summary_from_provider("Running cargo test"), None);
    assert_eq!(validation_summary_from_provider("Reading src/lib.rs"), None);
}

#[test]
fn verbose_plan_keeps_all_steps_without_synthetic_counts() {
    let mut tracker = ActivityTracker::default();
    let steps = vec![
        PlanStep {
            text: "Inspect the existing implementation".to_string(),
            status: PlanStepStatus::Completed,
        },
        PlanStep {
            text: "Implement the durable path".to_string(),
            status: PlanStepStatus::InProgress,
        },
        PlanStep {
            text: "Run focused tests".to_string(),
            status: PlanStepStatus::Pending,
        },
    ];
    let rendered = tracker
        .apply_plan(steps, VisibilityMode::Verbose, Path::new("/workspace"))
        .expect("verbose plan");
    assert!(rendered.contains("Inspect the existing implementation"));
    assert!(rendered.contains("Implement the durable path"));
    assert!(rendered.contains("Run focused tests"));
    assert!(!rendered.contains("next"));
}

#[test]
fn verbose_ledger_preserves_cross_event_order() {
    let mut tracker = ActivityTracker::default();
    let workspace = Path::new("/workspace");
    tracker.apply_legacy(
        "Inspecting command routing",
        VisibilityMode::Verbose,
        workspace,
    );
    tracker.apply_files(
        [PathBuf::from("/workspace/cli/src/bridge/runtime.rs")],
        VisibilityMode::Verbose,
        workspace,
    );
    tracker.apply(
        activity_snapshot(
            "command-1",
            ActivitySemanticKind::Execute,
            ActivityStatus::InProgress,
            "Run bridge tests",
        )
        .with_detail("cargo test -p inline-cli"),
        VisibilityMode::Verbose,
        workspace,
    );

    let rendered = tracker
        .render(VisibilityMode::Verbose, WORKING_STATUS, workspace)
        .expect("ledger");
    let inspect = rendered
        .find("Inspecting command routing")
        .expect("inspect");
    let file = rendered.find("cli/src/bridge/runtime.rs").expect("file");
    let command = rendered.find("Run bridge tests").expect("command");
    assert!(inspect < file && file < command);
}

#[test]
fn plan_replacement_retains_performed_work_and_drops_removed_pending_steps() {
    let mut tracker = ActivityTracker::default();
    let workspace = Path::new("/workspace");
    tracker.apply_plan(
        vec![
            PlanStep {
                text: "Inspect implementation".to_string(),
                status: PlanStepStatus::InProgress,
            },
            PlanStep {
                text: "Potential later work".to_string(),
                status: PlanStepStatus::Pending,
            },
        ],
        VisibilityMode::Verbose,
        workspace,
    );
    let rendered = tracker
        .apply_plan(
            vec![PlanStep {
                text: "Implement durable progress".to_string(),
                status: PlanStepStatus::InProgress,
            }],
            VisibilityMode::Verbose,
            workspace,
        )
        .expect("replacement");

    assert!(rendered.contains("Inspect implementation"));
    assert!(rendered.contains("Implement durable progress"));
    assert!(!rendered.contains("Potential later work"));
}

#[test]
fn progress_ledger_round_trips_only_normalized_relative_paths() {
    let mut tracker = ActivityTracker::default();
    let workspace = Path::new("/workspace");
    tracker.apply(
        activity_snapshot(
            "read-1",
            ActivitySemanticKind::Read,
            ActivityStatus::Completed,
            "Read runtime",
        )
        .with_paths(vec![PathBuf::from("/workspace/cli/src/bridge/runtime.rs")]),
        VisibilityMode::Verbose,
        workspace,
    );
    tracker.set_terminal_header("Worked for 2m 05s");

    let json = tracker.durable_json().expect("serialize");
    assert!(!json.contains("/workspace/"));
    let restored = ActivityTracker::from_durable_json(&json).expect("restore");
    assert_eq!(restored.visibility_mode(), VisibilityMode::Verbose);
    assert_eq!(restored.terminal_header(), Some("Worked for 2m 05s"));
    assert!(
        restored
            .render(VisibilityMode::Verbose, WORKING_STATUS, workspace)
            .expect("render")
            .contains("cli/src/bridge/runtime.rs")
    );
}

#[test]
fn verbose_progress_overflow_is_bounded_and_terminal_headers_do_not_repeat_working() {
    let mut tracker = ActivityTracker::default();
    let workspace = Path::new("/workspace");
    for index in 0..MAX_TRACKED_ACTIVITIES {
        let paths = (0..MAX_TRACKED_PATHS_PER_ACTIVITY)
            .map(|path_index| {
                PathBuf::from(format!(
                    "/workspace/{index}/{}-{path_index}.rs",
                    "long-safe-path".repeat(12)
                ))
            })
            .collect::<Vec<_>>();
        tracker.apply(
            activity_snapshot(
                &format!("activity-{index}"),
                ActivitySemanticKind::Execute,
                ActivityStatus::Completed,
                &format!("Run command {index} {}", "x".repeat(180)),
            )
            .with_detail(format!(
                "cargo test --package package-{index} {}",
                "y".repeat(420)
            ))
            .with_paths(paths),
            VisibilityMode::Verbose,
            workspace,
        );
    }

    let live = tracker.render_chunks(
        VisibilityMode::Verbose,
        WORKING_STATUS,
        Some(WORKING_CONTINUED_STATUS),
    );
    assert_eq!(live.len(), MAX_PROGRESS_CHUNKS);
    assert!(live[0].starts_with("Working...\n\n"));
    assert!(
        live[1..]
            .iter()
            .all(|chunk| chunk.starts_with("Working... · continued\n\n"))
    );
    assert!(
        live.last()
            .expect("last")
            .contains("[additional activity omitted]")
    );
    assert!(
        live.iter()
            .all(|chunk| chunk.len() <= MAX_PROGRESS_CHUNK_BYTES)
    );

    let terminal = tracker.render_chunks(VisibilityMode::Verbose, "Worked for 2m 05s", None);
    assert!(terminal[0].starts_with("Worked for 2m 05s\n\n"));
    assert!(
        terminal
            .iter()
            .all(|chunk| !chunk.contains(WORKING_CONTINUED_STATUS))
    );
    assert!(
        terminal
            .iter()
            .all(|chunk| chunk.len() <= MAX_PROGRESS_CHUNK_BYTES)
    );
}

#[test]
fn typed_authentication_has_host_login_guidance() {
    let output = final_turn_text(
        "Run `codex login` on the bridge host, then send your message again.",
        TurnOutcome::AuthenticationRequired,
        &[],
        Path::new("/repo"),
        false,
        None,
    );
    assert!(output.contains("codex login"));
    assert!(!output.contains(BridgeNotice::AgentTurnFailed.message()));

    let empty = final_turn_text(
        "",
        TurnOutcome::AuthenticationRequired,
        &[],
        Path::new("/repo"),
        false,
        None,
    );
    assert_eq!(empty, BridgeNotice::AuthenticationRequired.message());
}

#[test]
fn final_output_does_not_duplicate_provider_completion_sections() {
    let workspace = Path::new("/tmp/project");
    let files = vec![FileChange {
        path: workspace.join("src/lib.rs"),
        summary: Some("updated parser".to_string()),
    }];
    let output = final_turn_text(
        "Implemented the parser.\n\nChanged files (only these two):\n- `src/lib.rs`\n\nChecks passed: 8 tests",
        TurnOutcome::Completed,
        &files,
        workspace,
        true,
        Some(&ValidationSummary::Passed("8 tests".to_string())),
    );

    assert_eq!(output.matches("Changed files").count(), 1);
    assert_eq!(output.matches("Checks passed:").count(), 1);
    assert!(!output.contains("file:///"));
}

#[test]
fn final_output_appends_only_missing_completion_sections() {
    let workspace = Path::new("/tmp/project");
    let files = vec![FileChange {
        path: workspace.join("src/lib.rs"),
        summary: None,
    }];
    let output = final_turn_text(
        "Implemented the parser.\n\n## Checks\n\n8 tests passed.",
        TurnOutcome::Completed,
        &files,
        workspace,
        false,
        Some(&ValidationSummary::Passed("8 tests".to_string())),
    );

    assert!(output.contains("Changed files:\n- `src/lib.rs`"));
    assert_eq!(output.matches("Checks").count(), 1);
}

#[tokio::test]
async fn separate_final_send_reuses_identity_after_retry_and_restart() {
    let directory = tempfile::tempdir().expect("tempdir");
    let database = directory.path().join("bridge.sqlite");
    let binding = BindingKey {
        installation_id: InstallationId::new("codex").expect("installation"),
        chat_id: 42,
        workspace_id: WorkspaceId::new("workspace").expect("workspace"),
    };
    let store = BridgeStore::open(&database).expect("store");
    store
        .accept_inbound(&InboundRecord {
            event_id: "event-1".to_string(),
            binding: binding.clone(),
            message_id: 10,
            delivery_chat_id: 42,
            sender_user_id: 1,
            direction: Direction::new(DirectionId::new("direction-1").expect("direction"), "work"),
            state: InboundState::Accepted,
            accepted_at: 1,
            started_at: None,
            lease_expires_at: None,
            attempt_count: 0,
            provider_turn_id: None,
            stream_message_id: None,
            failure: None,
        })
        .expect("accept");
    assert!(store.start_inbound("event-1", 2).expect("start"));
    assert!(
        store
            .attach_inbound_turn(
                "event-1",
                &inline_agent_bridge::TurnId::new("turn-1").expect("turn"),
                Some(55),
            )
            .expect("attach")
    );
    assert!(
        store
            .stage_inbound_final_send(
                "event-1",
                InboundState::Completed,
                "Authoritative final result.",
                None,
            )
            .expect("stage")
    );
    let terminal_random_id = store
        .ensure_inbound_final_send_random_id("event-1", 777)
        .expect("final send identity")
        .expect("staged identity");

    let first_transport = FaultingStreamTransport::new(0, 2, 99);
    let mutation = deliver_pending_final_with_transport(
        &first_transport,
        "event-1",
        binding.chat_id,
        Some(InlineId::new(55)),
        "Completed.",
        RandomId::new(terminal_random_id),
        "Authoritative final result.",
        |_| Duration::ZERO,
    )
    .await
    .expect("replacement delivery");
    assert_eq!(mutation.message_id, Some(InlineId::new(100)));
    assert_eq!(first_transport.edits.load(Ordering::Relaxed), 1);
    assert_eq!(first_transport.sends.load(Ordering::Relaxed), 3);
    {
        let edits = first_transport.edit_requests.lock().expect("edit requests");
        assert_eq!(edits[0].message_id, InlineId::new(55));
        assert_eq!(edits[0].text, "Completed.");
    }
    let first_external_id = {
        let sends = first_transport.send_requests.lock().expect("send requests");
        assert_eq!(sends.len(), 3);
        assert!(sends.iter().all(|request| {
            request.random_id == Some(RandomId::new(777))
                && request.notification_mode == SendNotificationMode::Normal
                && request.reply_to_message_id.is_none()
                && request.parse_markdown
                && request.text == "Authoritative final result."
        }));
        let first_external_id = sends[0].external_id.clone();
        assert!(
            sends
                .iter()
                .all(|request| request.external_id == first_external_id)
        );
        first_external_id
    };
    drop(store);

    let reopened = BridgeStore::open(&database).expect("reopen");
    let pending = reopened
        .pending_inbound_final_sends(&binding.installation_id)
        .expect("pending final send");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].stream_message_id, Some(55));
    assert_eq!(pending[0].final_text, "Authoritative final result.");

    let recovered_transport = FaultingStreamTransport::new(0, 0, 99);
    let recovered = deliver_pending_final_with_transport(
        &recovered_transport,
        &pending[0].event_id,
        binding.chat_id,
        pending[0].stream_message_id.map(InlineId::new),
        "Completed.",
        RandomId::new(
            pending[0]
                .terminal_random_id
                .expect("persisted final send identity"),
        ),
        &pending[0].final_text,
        |_| Duration::ZERO,
    )
    .await
    .expect("recovery send");
    assert_eq!(recovered.message_id, Some(InlineId::new(100)));
    let recovered_sends = recovered_transport
        .send_requests
        .lock()
        .expect("recovered sends");
    assert_eq!(recovered_sends.len(), 1);
    assert_eq!(recovered_sends[0].random_id, Some(RandomId::new(777)));
    assert_eq!(recovered_sends[0].external_id, first_external_id);
    drop(recovered_sends);
    assert!(
        reopened
            .commit_inbound_final_send("event-1")
            .expect("commit")
    );
    assert_eq!(
        reopened
            .get_inbound("event-1")
            .expect("load")
            .expect("record")
            .state,
        InboundState::Completed
    );
}

#[tokio::test]
async fn terminal_progress_failure_does_not_suppress_normal_final_send() {
    let transport = FaultingStreamTransport::new(3, 0, 99);
    let mutation = deliver_pending_final_with_transport(
        &transport,
        "event-final",
        42,
        Some(InlineId::new(55)),
        "Failed.",
        RandomId::new(808),
        "The agent failed safely.",
        |_| Duration::ZERO,
    )
    .await
    .expect("final send");

    assert_eq!(transport.edits.load(Ordering::Relaxed), 3);
    assert_eq!(transport.sends.load(Ordering::Relaxed), 1);
    assert_eq!(transport.silent_sends.load(Ordering::Relaxed), 0);
    assert_eq!(mutation.message_id, Some(InlineId::new(100)));
}

#[tokio::test]
async fn progress_edit_failure_does_not_create_a_replacement_message() {
    let transport = FaultingStreamTransport::new(3, 0, 99);

    let error = update_progress_with_transport(
        &transport,
        42,
        Some(InlineId::new(55)),
        "Running checks…",
        |_| Duration::ZERO,
    )
    .await
    .expect_err("edit should fail without sending another progress message");

    assert!(error.to_string().contains("injected edit failure"));
    assert_eq!(transport.edits.load(Ordering::Relaxed), 3);
    assert_eq!(transport.sends.load(Ordering::Relaxed), 0);
    assert_eq!(transport.silent_sends.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn recovery_reconciles_progress_accepted_before_store_attachment() {
    let transport = FaultingStreamTransport::new(0, 0, 99);
    let initial = build_text_request(
        42,
        None,
        "Working in inline…",
        "event-crash-working",
        SendNotificationMode::Silent,
    )
    .expect("initial progress request");
    let accepted = transport.send(initial).await.expect("server acceptance");
    assert_eq!(accepted.message_id, Some(InlineId::new(99)));

    let recovered =
        resolve_progress_with_transport(&transport, "event-crash", 42, None, |_| Duration::ZERO)
            .await;
    assert_eq!(recovered, Some(InlineId::new(99)));

    {
        let requests = transport.send_requests.lock().expect("send requests");
        assert_eq!(requests.len(), 2);
        assert!(requests.iter().all(|request| {
            request.notification_mode == SendNotificationMode::Silent
                && request.reply_to_message_id.is_none()
                && request.external_id == requests[0].external_id
        }));
    }

    deliver_pending_final_with_transport(
        &transport,
        "event-crash",
        42,
        recovered,
        "Stopped.",
        RandomId::new(909),
        "This turn was interrupted when the bridge restarted.",
        |_| Duration::ZERO,
    )
    .await
    .expect("final delivery");
    let edits = transport.edit_requests.lock().expect("edit requests");
    assert_eq!(edits.len(), 1);
    assert_eq!(edits[0].message_id, InlineId::new(99));
    assert_eq!(edits[0].text, "Stopped.");
}

#[tokio::test]
async fn final_send_preserves_owner_dm_and_reply_thread_chat_targets() {
    for chat_id in [706, 910] {
        let transport = FaultingStreamTransport::new(0, 0, 99);
        deliver_pending_final_with_transport(
            &transport,
            &format!("event-{chat_id}"),
            chat_id,
            Some(InlineId::new(55)),
            "Completed.",
            RandomId::new(chat_id),
            "Done.",
            |_| Duration::ZERO,
        )
        .await
        .expect("final delivery");

        let sends = transport.send_requests.lock().expect("send requests");
        assert_eq!(sends.len(), 1);
        assert_eq!(
            sends[0].peer,
            PeerRef::Chat {
                chat_id: InlineId::new(chat_id)
            }
        );
    }
}

#[tokio::test]
async fn recovery_sends_pending_final_results_in_ingest_order() {
    let store = BridgeStore::open_in_memory().expect("store");
    let installation_id = InstallationId::new("codex").expect("installation");
    let workspace_id = WorkspaceId::new("workspace").expect("workspace");
    for (index, event_id, final_text) in [
        (1_i64, "event-first", "First final result."),
        (2_i64, "event-second", "Second final result."),
    ] {
        store
            .accept_inbound(&InboundRecord {
                event_id: event_id.to_string(),
                binding: BindingKey {
                    installation_id: installation_id.clone(),
                    chat_id: 42,
                    workspace_id: workspace_id.clone(),
                },
                message_id: 10 + index,
                delivery_chat_id: 42,
                sender_user_id: 1,
                direction: Direction::new(
                    DirectionId::new(format!("direction-{index}")).expect("direction"),
                    "work",
                ),
                state: InboundState::Accepted,
                accepted_at: index,
                started_at: None,
                lease_expires_at: None,
                attempt_count: 0,
                provider_turn_id: None,
                stream_message_id: None,
                failure: None,
            })
            .expect("accept");
        assert!(store.start_inbound(event_id, 10 + index).expect("start"));
        assert!(
            store
                .attach_inbound_turn(
                    event_id,
                    &inline_agent_bridge::TurnId::new(format!("turn-{index}")).expect("turn"),
                    Some(50 + index),
                )
                .expect("attach")
        );
        assert!(
            store
                .stage_inbound_final_send(event_id, InboundState::Completed, final_text, None,)
                .expect("stage")
        );
    }

    let transport = FaultingStreamTransport::new(0, 0, 99);
    recover_pending_final_sends_with_transport(&transport, &store, &installation_id, |_| {
        Duration::ZERO
    })
    .await
    .expect("recover pending sends");

    {
        let sends = transport.send_requests.lock().expect("send requests");
        assert_eq!(sends.len(), 2);
        assert_eq!(sends[0].text, "First final result.");
        assert_eq!(sends[1].text, "Second final result.");
        assert!(sends.iter().all(|request| {
            request.notification_mode == SendNotificationMode::Normal
                && request
                    .random_id
                    .is_some_and(|random_id| random_id.get() > 0)
        }));
    }
    assert!(
        store
            .pending_inbound_final_sends(&installation_id)
            .expect("pending")
            .is_empty()
    );
}
