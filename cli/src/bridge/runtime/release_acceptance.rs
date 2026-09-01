//! Real provider plus in-memory Inline transport acceptance; no production messages.
use super::*;
use futures_util::future::BoxFuture;
use inline_agent_driver_codex::{CodexAppServerTransport, CodexLaunchConfig, spawn_codex_driver};
use inline_client::*;

#[derive(Clone, Debug)]
struct AcceptanceBackend {
    inner: InMemoryBackend,
    bot_store: SqliteStore,
    connection: Arc<std::sync::Mutex<Option<proto::AgentSessionConnection>>>,
    syncs: Arc<std::sync::Mutex<Vec<proto::SyncAgentSessionMessagesInput>>>,
    fail_next_history_sync: Arc<std::sync::atomic::AtomicBool>,
    interactive: Arc<std::sync::Mutex<Vec<SendInteractiveTextRequest>>>,
}

impl ClientBackend for AcceptanceBackend {
    fn get_agent_session(
        &self,
        request: proto::GetAgentSessionInput,
    ) -> BoxFuture<'static, BackendResult<proto::GetAgentSessionResult>> {
        let connection =
            self.connection
                .lock()
                .expect("connection")
                .clone()
                .filter(|connection| {
                    connection.agent_session.as_ref().is_some_and(|session| {
                        session.bot_user_id == request.bot_user_id
                            && session.peer_id.as_ref().and_then(|peer| {
                                match peer.r#type.as_ref() {
                                    Some(proto::peer::Type::Chat(chat)) => Some(chat.chat_id),
                                    _ => None,
                                }
                            }) == input_chat_id(request.peer_id.as_ref())
                    })
                });
        Box::pin(async move { Ok(proto::GetAgentSessionResult { connection }) })
    }

    fn connect_agent_session(
        &self,
        request: proto::ConnectAgentSessionInput,
    ) -> BoxFuture<'static, BackendResult<proto::ConnectAgentSessionResult>> {
        let mut saved = self.connection.lock().expect("connection");
        let result = if let Some(connection) = saved.as_mut() {
            assert_eq!(
                connection.session_ref, request.session_ref,
                "must retain exact provider identity"
            );
            assert_eq!(connection.instance_ref, request.instance_ref);
            let session = connection.agent_session.as_mut().expect("session");
            if let Some(status) = request.status_message_id {
                session.status_message_id = Some(status);
            }
            proto::ConnectAgentSessionResult {
                agent_session: Some(session.clone()),
                state: proto::ConnectAgentSessionState::AlreadyConnected as i32,
            }
        } else if let Some(chat_id) = input_chat_id(request.peer_id.as_ref()) {
            let session = proto::AgentSession {
                id: 91,
                peer_id: Some(proto::Peer {
                    r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id })),
                }),
                bot_user_id: request.bot_user_id,
                provider: request.provider,
                status_message_id: request.status_message_id,
                parent_chat_id: Some(706),
            };
            *saved = Some(proto::AgentSessionConnection {
                agent_session: Some(session.clone()),
                instance_ref: request.instance_ref,
                session_ref: request.session_ref,
                project_ref: request.project_ref,
            });
            proto::ConnectAgentSessionResult {
                agent_session: Some(session),
                state: proto::ConnectAgentSessionState::Created as i32,
            }
        } else {
            proto::ConnectAgentSessionResult::default()
        };
        Box::pin(async move { Ok(result) })
    }

    fn sync_agent_session_messages(
        &self,
        request: proto::SyncAgentSessionMessagesInput,
    ) -> BoxFuture<'static, BackendResult<proto::SyncAgentSessionMessagesResult>> {
        assert_eq!(request.agent_session_id, 91);
        let fail = request.mode == proto::AgentSessionSyncMode::History as i32
            && self
                .fail_next_history_sync
                .swap(false, std::sync::atomic::Ordering::SeqCst);
        let messages = request
            .messages
            .iter()
            .enumerate()
            .map(|(index, message)| {
                let (state, message_id) = match message.operation.as_ref().expect("operation") {
                    proto::agent_session_message_sync::Operation::Link(link) => {
                        (proto::AgentSessionMessageSyncState::Linked, link.message_id)
                    }
                    proto::agent_session_message_sync::Operation::Upsert(_) => (
                        proto::AgentSessionMessageSyncState::Created,
                        1000 + index as i64,
                    ),
                };
                proto::AgentSessionMessageSyncResult {
                    index: index as i32,
                    state: if fail {
                        proto::AgentSessionMessageSyncState::Conflict as i32
                    } else {
                        state as i32
                    },
                    message_id: Some(message_id),
                    current_revision_ref: None,
                }
            })
            .collect();
        self.syncs.lock().expect("syncs").push(request);
        Box::pin(async move { Ok(proto::SyncAgentSessionMessagesResult { messages }) })
    }

    fn create_reply_thread(
        &self,
        request: CreateReplyThreadRequest,
    ) -> BoxFuture<'static, BackendResult<CreatedChat>> {
        let backend = self.clone();
        Box::pin(async move {
            let created = backend.inner.create_reply_thread(request.clone()).await?;
            let mut dialog = DialogRecord::new(created.chat_id);
            dialog.parent_chat_id = Some(request.parent_chat_id);
            dialog.parent_message_id = request.parent_message_id;
            backend
                .bot_store
                .upsert_dialog(dialog)
                .expect("cache thread");
            Ok(created)
        })
    }
    fn auth_start(
        &self,
        request: AuthStartRequest,
    ) -> BoxFuture<'static, BackendResult<AuthStartResult>> {
        self.inner.auth_start(request)
    }
    fn auth_verify(
        &self,
        request: AuthVerifyRequest,
    ) -> BoxFuture<'static, BackendResult<AuthVerifyResult>> {
        self.inner.auth_verify(request)
    }
    fn resume_session(&self) -> BoxFuture<'static, BackendResult<ClientStatusSnapshot>> {
        self.inner.resume_session()
    }
    fn connect(
        &self,
        request: ConnectRequest,
    ) -> BoxFuture<'static, BackendResult<ClientStatusSnapshot>> {
        self.inner.connect(request)
    }
    fn logout(&self) -> BoxFuture<'static, BackendResult<()>> {
        self.inner.logout()
    }
    fn dialogs(&self, request: DialogsRequest) -> BoxFuture<'static, BackendResult<DialogsPage>> {
        self.inner.dialogs(request)
    }
    fn cached_dialogs(
        &self,
        request: DialogsRequest,
    ) -> BoxFuture<'static, BackendResult<DialogsPage>> {
        self.inner.cached_dialogs(request)
    }
    fn account_state(&self) -> BoxFuture<'static, BackendResult<AccountStateSnapshot>> {
        self.inner.account_state()
    }
    fn chat_state(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, BackendResult<ChatStateSnapshot>> {
        self.inner.chat_state(chat_id)
    }
    fn history(&self, request: HistoryRequest) -> BoxFuture<'static, BackendResult<HistoryPage>> {
        self.inner.history(request)
    }
    fn cached_history(
        &self,
        request: HistoryRequest,
    ) -> BoxFuture<'static, BackendResult<HistoryPage>> {
        self.inner.cached_history(request)
    }
    fn chat_participants(
        &self,
        request: ChatParticipantsRequest,
    ) -> BoxFuture<'static, BackendResult<ChatParticipantsPage>> {
        self.inner.chat_participants(request)
    }
    fn add_chat_participant(
        &self,
        request: AddChatParticipantRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        self.inner.add_chat_participant(request)
    }
    fn remove_chat_participant(
        &self,
        request: RemoveChatParticipantRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        self.inner.remove_chat_participant(request)
    }
    fn update_chat_info(
        &self,
        request: UpdateChatInfoRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        self.inner.update_chat_info(request)
    }
    fn delete_chat(
        &self,
        request: DeleteChatRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        self.inner.delete_chat(request)
    }
    fn create_dm(
        &self,
        request: CreateDmRequest,
    ) -> BoxFuture<'static, BackendResult<CreatedChat>> {
        self.inner.create_dm(request)
    }
    fn create_thread(
        &self,
        request: CreateThreadRequest,
    ) -> BoxFuture<'static, BackendResult<CreatedChat>> {
        self.inner.create_thread(request)
    }
    fn send_text(
        &self,
        request: SendTextRequest,
    ) -> BoxFuture<'static, BackendResult<SendTextOutcome>> {
        self.inner.send_text(request)
    }
    fn send_interactive_text(
        &self,
        request: SendInteractiveTextRequest,
    ) -> BoxFuture<'static, BackendResult<SendTextOutcome>> {
        self.interactive
            .lock()
            .expect("interactive")
            .push(request.clone());
        self.inner.send_interactive_text(request)
    }
    fn send_media(
        &self,
        request: UploadRequest,
        bytes: Vec<u8>,
        thumbnail: Option<UploadThumbnail>,
    ) -> BoxFuture<'static, BackendResult<SendTextOutcome>> {
        self.inner.send_media(request, bytes, thumbnail)
    }
    fn edit_message(
        &self,
        request: EditMessageRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        self.inner.edit_message(request)
    }
    fn edit_interactive_message(
        &self,
        request: EditInteractiveMessageRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        self.inner.edit_interactive_message(request)
    }
    fn delete_message(
        &self,
        request: DeleteMessageRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        self.inner.delete_message(request)
    }
    fn react(&self, request: ReactRequest) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        self.inner.react(request)
    }
    fn read(&self, request: ReadRequest) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        self.inner.read(request)
    }
    fn pin_message(
        &self,
        request: PinMessageRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        self.inner.pin_message(request)
    }
    fn set_marked_unread(
        &self,
        request: SetMarkedUnreadRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        self.inner.set_marked_unread(request)
    }
    fn update_dialog_notifications(
        &self,
        request: UpdateDialogNotificationsRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        self.inner.update_dialog_notifications(request)
    }
    fn update_dialog_follow_mode(
        &self,
        request: UpdateDialogFollowModeRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        self.inner.update_dialog_follow_mode(request)
    }
    fn typing(
        &self,
        request: TypingRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        self.inner.typing(request)
    }
    fn answer_message_action(
        &self,
        request: AnswerMessageActionRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        self.inner.answer_message_action(request)
    }
    fn get_bot_capabilities(&self) -> BoxFuture<'static, BackendResult<Vec<BotCapability>>> {
        self.inner.get_bot_capabilities()
    }
    fn set_bot_capabilities(
        &self,
        capabilities: Vec<BotCapability>,
    ) -> BoxFuture<'static, BackendResult<Vec<BotCapability>>> {
        self.inner.set_bot_capabilities(capabilities)
    }
    fn request_bot_chat_settings(
        &self,
        request: RequestBotChatSettingsRequest,
    ) -> BoxFuture<'static, BackendResult<BotChatSettingsResponse>> {
        self.inner.request_bot_chat_settings(request)
    }
    fn invoke_bot_chat_settings_item(
        &self,
        request: InvokeBotChatSettingsItemRequest,
    ) -> BoxFuture<'static, BackendResult<BotChatSettingsResponse>> {
        self.inner.invoke_bot_chat_settings_item(request)
    }
    fn answer_bot_chat_settings(
        &self,
        request: AnswerBotChatSettingsRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        self.inner.answer_bot_chat_settings(request)
    }
    fn receive_events(&self) -> BoxFuture<'static, BackendResult<Vec<ClientEvent>>> {
        self.inner.receive_events()
    }
}

fn input_chat_id(peer: Option<&proto::InputPeer>) -> Option<i64> {
    match peer.and_then(|peer| peer.r#type.as_ref()) {
        Some(proto::input_peer::Type::Chat(chat)) => Some(chat.chat_id),
        _ => None,
    }
}

async fn run_message(
    bot: &InlineClient,
    route: &InboundRoute,
    manager: &ProviderSessionManager<ProviderDriver>,
    identity: &SettingsIdentity,
    chat_id: i64,
    number: i64,
    text: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    run_message_expect(
        bot,
        route,
        manager,
        identity,
        chat_id,
        number,
        text,
        InboundState::Completed,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn run_message_expect(
    bot: &InlineClient,
    route: &InboundRoute,
    manager: &ProviderSessionManager<ProviderDriver>,
    identity: &SettingsIdentity,
    chat_id: i64,
    number: i64,
    text: &str,
    expected: InboundState,
) -> Result<String, Box<dyn std::error::Error>> {
    let active = conversation_for_chat(route, chat_id)?;
    let snapshot = active.snapshot();
    let event_id = format!("acceptance-{number}");
    let record = InboundRecord {
        event_id: event_id.clone(),
        binding: snapshot.binding.clone(),
        message_id: number,
        delivery_chat_id: chat_id,
        sender_user_id: route.owner_user_id,
        direction: Direction::new(DirectionId::new(event_id.clone())?, text),
        state: InboundState::Accepted,
        accepted_at: now_seconds(),
        started_at: None,
        lease_expires_at: None,
        attempt_count: 0,
        provider_turn_id: None,
        stream_message_id: None,
        failure: None,
    };
    route.store.accept_inbound(&record)?;
    let record = route
        .store
        .take_next_inbound(&snapshot.binding, now_seconds())?
        .expect("accepted inbound");
    let (sender, mut receiver) = tokio::sync::mpsc::channel(8);
    let (promotions, _promotion_receiver) = tokio::sync::mpsc::channel(1);
    let result = run_inbound_turn(
        bot,
        &mut receiver,
        manager,
        &route.store,
        &snapshot.binding,
        &snapshot.workspace,
        route,
        &active,
        identity,
        record,
        None,
        sender,
        promotions,
    )
    .await;
    if let Err(error) = result {
        let released = is_provider_epoch_release_command(text, &route.bot_username)
            && error
                .downcast_ref::<io::Error>()
                .is_some_and(|error| error.kind() == io::ErrorKind::ConnectionAborted);
        if !released {
            return Err(error);
        }
    }
    assert_eq!(
        route.store.get_inbound(&event_id)?.expect("inbound").state,
        expected,
        "handler must finish rather than only posting an error notice"
    );
    assert!(
        route
            .store
            .pending_inbound_final_sends(&route.installation_id)?
            .is_empty(),
        "delivery journal must commit after Inline acknowledges the final"
    );
    Ok(event_id)
}

#[tokio::test]
#[ignore = "real authenticated Codex: disposable handoff turns; Inline transport is local and no production messages are sent"]
async fn real_codex_default_chat_projects_open_link_and_resume_deliver_final_answers()
-> Result<(), Box<dyn std::error::Error>> {
    let workspace = match std::env::var_os("INLINE_CODEX_SMOKE_WORKSPACE") {
        Some(path) => PathBuf::from(path).canonicalize()?,
        None => tempfile::tempdir()?.keep().canonicalize()?,
    };
    let mut route = super::authorization_tests::route("codex");
    let workspace_id = WorkspaceId::new("release-acceptance")?;
    route.store.select_workspace(
        &route.installation_id,
        &workspace_id,
        &workspace,
        now_seconds(),
    )?;
    let backend = AcceptanceBackend {
        fail_next_history_sync: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        inner: InMemoryBackend::new(),
        bot_store: route.bot_store.clone(),
        connection: Default::default(),
        syncs: Default::default(),
        interactive: Default::default(),
    };
    let mut dialog = DialogRecord::new(InlineId::new(route.owner_dm_chat_id));
    dialog.peer_user_id = Some(InlineId::new(route.owner_user_id));
    route.bot_store.upsert_dialog(dialog.clone())?;
    backend.inner.upsert_dialog(dialog);
    let bot = InlineClient::builder()
        .backend(backend.clone())
        .build()
        .spawn();
    bot.connect(ConnectRequest::new(AuthCredential::AccessToken {
        token: AuthToken::try_new("in-memory-only")?,
    }))
    .await?;
    // A failed first owner connection must recover before dispatching the
    // ordinary prompt below; no provider or service restart should be needed.
    let mut owner_attempts = 0;
    let owner = crate::bridge::owner_control::retry_owner_control_connection(|| {
        owner_attempts += 1;
        let attempt = owner_attempts;
        let client = bot.clone();
        let store = route.bot_store.clone();
        async move {
            if attempt == 1 {
                Err(ClientRequestError::Backend(BackendError::new(
                    ClientErrorCategory::Network,
                    "synthetic owner connection timeout",
                ))
                .into())
            } else {
                Ok(OwnerControl::for_test(client, store))
            }
        }
    })
    .await?;
    assert_eq!(owner_attempts, 2);
    route.owner_control = Some(Arc::new(owner));
    let identity = SettingsIdentity {
        owner_user_id: route.owner_user_id,
        owner_dm_chat_id: route.owner_dm_chat_id,
        bot_user_id: route.bot_user_id,
        host_installation_id: "acceptance-host".into(),
        host_label: "Acceptance".into(),
        workspace_picker: None,
        codex_projects_path: None,
        codex_project_rpc: None,
        bot_store: route.bot_store.clone(),
        reply_thread_default: ReplyThreadDefault {
            mode: ReplyThreadMode::Auto,
            source: ReplyThreadDefaultSource::BuiltIn,
        },
    };
    let executable = std::env::var_os("INLINE_CODEX_SMOKE_EXECUTABLE")
        .ok_or("set INLINE_CODEX_SMOKE_EXECUTABLE")?;
    let config = CodexLaunchConfig {
        executable: executable.into(),
        transport: CodexAppServerTransport::PrivateStdio,
        ..Default::default()
    };
    let first = spawn_codex_driver(config.clone(), env!("CARGO_PKG_VERSION")).await?;
    let manager = ProviderSessionManager::new(
        Arc::new(ProviderDriver::Codex(first.driver.clone())),
        route.store.clone(),
        route.provider_id.clone(),
    );
    let marker = format!("inline-handler-{}", now_millis());
    let result = tokio::time::timeout(Duration::from_secs(150), async {
        run_message(&bot, &route, &manager, &identity, 706, 101,
            &format!("This is a text-only test. Do not use tools, inspect files or change anything. Remember {marker}. Reply with only that marker.")).await?;
        let active = conversation_for_chat(&route, 706)?;
        let binding = active.snapshot().binding;
        let default_session = route.store.get_binding(&binding)?.expect("default session").1;
        let history = bot.history(HistoryRequest { chat_id: InlineId::new(706), limit: Some(50), before_message_id: None, after_message_id: None }).await?;
        assert!(history.messages.iter().any(|message| matches!(&message.content, MessageContent::Text { text } if text.trim() == marker)), "default handler must deliver final to Inline");
        run_message(&bot, &route, &manager, &identity, 706, 130, "/verbose on").await?;
        let output_marker = format!("inline-command-output-{}", now_millis());
        let answer_marker = format!("inline-tool-answer-{}", now_millis());
        run_message(&bot, &route, &manager, &identity, 706, 131,
            &format!("Use the terminal tool exactly once to run `printf {output_marker}` without reading or changing files. Then reply with only `{answer_marker}`.")).await?;
        let history = bot.history(HistoryRequest { chat_id: InlineId::new(706), limit: Some(50), before_message_id: None, after_message_id: None }).await?;
        let history_text = history.messages.iter().filter_map(|message| match &message.content {
            MessageContent::Text { text } => Some(text.as_str()),
            _ => None,
        }).collect::<Vec<_>>().join("\n");
        for expected in ["<summary>Worked", "Command output", "Provider payload", output_marker.as_str()] {
            assert!(history_text.contains(expected),
                "verbose progress set must retain real Codex field: {expected}");
        }
        assert!(history.messages.iter().any(|message| matches!(&message.content, MessageContent::Text { text } if text.trim() == answer_marker)),
            "tool turn must still deliver its separate final answer");
        run_message(&bot, &route, &manager, &identity, 706, 132, "/verbose off").await?;
        // Model an existing session created in Codex, separate from the session
        // already attached to the ordinary Inline DM. Opening must never steal
        // that DM binding or fork its context.
        let provider_session = first.driver.start_session(inline_agent_bridge::SessionSpec { cwd: workspace.clone() }).await?;
        assert_ne!(provider_session, default_session);
        let mut external = first.driver.start_turn(&provider_session, TurnInput {
            text: format!("Text-only test. Do not use tools. Remember {marker} for later. Reply only with that marker."),
            attachments: vec![], client_message_id: None,
        }, TurnOptions::default()).await?;
        let mut completed = false;
        while let Some(event) = external.events.next().await {
            if let AgentEvent::TurnCompleted { outcome, .. } = event? {
                assert_eq!(outcome, TurnOutcome::Completed);
                completed = true;
                break;
            }
        }
        assert!(completed, "external test turn completed");
        run_message(&bot, &route, &manager, &identity, 706, 102, "/projects").await?;
        assert!(backend.interactive.lock().expect("interactive").iter().any(|request| !request.actions.rows.is_empty()
            && request.message.text.starts_with("Current project:") && request.message.text.contains(&workspace_label(&workspace))),
            "projects must publish a usable picker with the configured workspace");
        run_message(&bot, &route, &manager, &identity, 706, 103, "/sessions").await?;
        let picker = route.store.session_picker_for_origin_event(&route.installation_id, "acceptance-103")?.expect("session picker");
        let index = picker.sessions.iter().position(|session| session.session().session_id() == &provider_session).expect("new session listed");
        let event = ClientEvent::MessageActionInvoked { interaction_id: InlineId::new(77), chat_id: InlineId::new(706), message_id: InlineId::new(picker.picker_message_id.expect("picker message")), actor_user_id: InlineId::new(route.owner_user_id), action_id: format!("bridge_agent_sessions_open_{index}"), data: backend.interactive.lock().expect("interactive").iter().flat_map(|request| &request.actions.rows).flat_map(|row| &row.actions).find_map(|button| match &button.kind { MessageActionKind::Callback { data } if button.action_id == format!("bridge_agent_sessions_open_{index}") => Some(data.clone()), _ => None }).expect("published Open callback") };
        handle_session_browser_action(&bot, &event, &route, &SettingsRuntime { sessions: &manager, store: &route.store, active: &active, identity: &identity, turn_active: false }).await?;
        // The production action runs on the control lane; acquire it to await completion.
        let _settled = route.control_lane.acquire().await?;
        let opened = route.store.session_picker(&picker.callback_token)?.expect("picker");
        assert_eq!(opened.state, SessionPickerState::Completed, "Open must finish history import and binding: {:?}", opened.last_error);
        let target = opened.thread_chat_id.expect("linked thread");
        assert_ne!(target, 706);
        assert!(backend.syncs.lock().expect("syncs").iter().any(|batch| batch.mode == proto::AgentSessionSyncMode::History as i32
            && batch.messages.iter().any(|message| matches!(&message.operation, Some(proto::agent_session_message_sync::Operation::Upsert(item)) if item.text.contains(&marker)))),
            "Open must import the real provider history before becoming ready");
        Ok::<_, Box<dyn std::error::Error>>((target, provider_session))
    }).await;
    let release = if let Ok(Ok((target, _))) = &result {
        run_message(&bot, &route, &manager, &identity, *target, 110, "/stop")
            .await
            .map(|_| ())
    } else {
        Ok(())
    };
    let stopped = first.driver.shutdown().await;
    let (target, provider_session) = result??;
    release?;
    stopped?;
    let second = spawn_codex_driver(config.clone(), env!("CARGO_PKG_VERSION")).await?;
    let manager = ProviderSessionManager::new(
        Arc::new(ProviderDriver::Codex(second.driver.clone())),
        route.store.clone(),
        route.provider_id.clone(),
    );
    let result = tokio::time::timeout(Duration::from_secs(120), async {
        run_message(&bot, &route, &manager, &identity, target, 109, "This prompt must wait for resume.").await?;
        assert!(route.store.get_inbound("acceptance-109")?.unwrap().provider_turn_id.is_none());
        backend.fail_next_history_sync.store(true, std::sync::atomic::Ordering::SeqCst);
        run_message_expect(&bot, &route, &manager, &identity, target, 117, "/resume", InboundState::Failed).await?;
        let binding = conversation_for_chat(&route, target)?.snapshot().binding;
        assert!(manager.session_is_active(&binding).await, "writer acquisition can precede a failed history sync");
        assert!(!manager.session_history_is_ready(&binding).await);
        run_message(&bot, &route, &manager, &identity, target, 118, "This prompt must also wait for successful sync.").await?;
        assert!(route.store.get_inbound("acceptance-118")?.unwrap().provider_turn_id.is_none());
        run_message(&bot, &route, &manager, &identity, target, 111, "/resume").await?;
        assert!(manager.session_history_is_ready(&binding).await);
        assert!(route.store.get_inbound("acceptance-111")?.unwrap().provider_turn_id.is_none(), "resume must not send a model prompt");
        run_message(&bot, &route, &manager, &identity, target, 104, "Do not use tools. Reply with only the marker I asked you to remember earlier.").await?;
        let history = bot.history(HistoryRequest { chat_id: InlineId::new(target), limit: Some(50), before_message_id: None, after_message_id: None }).await?;
        assert_eq!(history.messages.iter().filter(|message| matches!(&message.content, MessageContent::Text { text } if text.trim() == marker)).count(), 1, "one delivered answer in the canonical session thread");
        let binding = conversation_for_chat(&route, target)?.snapshot().binding;
        assert_eq!(route.store.get_binding(&binding)?.expect("binding").1, provider_session);
        let syncs = backend.syncs.lock().expect("syncs");
        for role in [proto::AgentSessionMessageRole::User, proto::AgentSessionMessageRole::Assistant] {
            assert!(syncs.iter().any(|batch| batch.mode == proto::AgentSessionSyncMode::Live as i32 && batch.messages.iter().any(|message| message.role == role as i32 && matches!(message.operation, Some(proto::agent_session_message_sync::Operation::Link(_))))), "user and delivered assistant must link to their existing Inline rows");
        }
        Ok::<_, Box<dyn std::error::Error>>(())
    }).await;
    let release = if matches!(&result, Ok(Ok(()))) {
        run_message(&bot, &route, &manager, &identity, target, 112, "/stop")
            .await
            .map(|_| ())
    } else {
        Ok(())
    };
    let stopped = second.driver.shutdown().await;
    result??;
    release?;
    stopped?;
    // A normal private CLI process must be able to continue after Inline's
    // command has released ownership. No shared endpoint or launch wrapper.
    let external_marker = format!("{marker}-from-cli");
    let output = tokio::time::timeout(Duration::from_secs(120),
        tokio::process::Command::new(&config.executable)
            .current_dir(&workspace)
            .args(["exec", "resume", "--json", "--skip-git-repo-check", provider_session.as_str()])
            .arg(format!("Text-only test. Do not use tools or inspect files. Remember this new marker: {external_marker}. Reply only with it."))
            .kill_on_drop(true)
            .output()
    ).await??;
    assert!(output.status.success(), "normal CLI continuation failed");
    assert!(
        String::from_utf8_lossy(&output.stdout).contains(&external_marker),
        "CLI must answer in the same session"
    );
    let third = spawn_codex_driver(config, env!("CARGO_PKG_VERSION")).await?;
    let manager = ProviderSessionManager::new(
        Arc::new(ProviderDriver::Codex(third.driver.clone())),
        route.store.clone(),
        route.provider_id.clone(),
    );
    let result = tokio::time::timeout(Duration::from_secs(120), async {
        backend.syncs.lock().unwrap().clear();
        run_message(&bot, &route, &manager, &identity, target, 113, "/resume").await?;
        assert!(backend.syncs.lock().unwrap().iter().any(|batch|
            batch.mode == proto::AgentSessionSyncMode::History as i32 && batch.messages.iter().any(|message|
                matches!(&message.operation, Some(proto::agent_session_message_sync::Operation::Upsert(item)) if item.text.contains(&external_marker)))));
        let binding = conversation_for_chat(&route, target)?.snapshot().binding;
        assert_eq!(route.store.get_binding(&binding)?.unwrap().1, provider_session);
        run_message(&bot, &route, &manager, &identity, target, 114, "/resume").await?;
        assert!(route.store.get_inbound("acceptance-114")?.unwrap().provider_turn_id.is_none());
        run_message(&bot, &route, &manager, &identity, target, 115,
            "Do not use tools. Reply only with the newest marker I asked you to remember.").await?;
        let history = bot.history(HistoryRequest { chat_id: InlineId::new(target), limit: Some(50), before_message_id: None, after_message_id: None }).await?;
        assert!(history.messages.iter().any(|message| matches!(&message.content, MessageContent::Text { text } if text.trim() == external_marker)));
        // Exercise the active stop through the real lossless event handler.
        // It must interrupt now but leave release queued until the turn lease
        // is dropped; the supervisor's idle path performs the actual shutdown.
        let (session, turn, work) = manager.start_turn(&binding, now_seconds(), TurnInput {
            text: "Text-only acceptance; do not use tools. Explain the numbers one through one thousand.".into(),
            attachments: vec![], client_message_id: None,
        }, TurnOptions::default()).await?;
        let mut queued = route.store.get_inbound("acceptance-115")?.unwrap();
        queued.event_id = "acceptance-queued-before-stop".into();
        queued.message_id = 120;
        queued.state = InboundState::Accepted;
        queued.direction = Direction::new(DirectionId::new("acceptance-queued-before-stop")?, "This queued work must not run");
        queued.provider_turn_id = None;
        queued.stream_message_id = None;
        route.store.accept_inbound(&queued)?;
        let mut events = bot.take_lossless_events().expect("test event consumer");
        backend.inner.push_event_batch(vec![ClientEvent::MessageStored {
            message: MessageRecord {
                chat_id: InlineId::new(target), message_id: InlineId::new(121),
                sender_id: InlineId::new(route.owner_user_id), timestamp: now_seconds(),
                is_outgoing: false, content: MessageContent::Text { text: "/stop".into() },
                reply_to_message_id: None, metadata: MessageMetadata::default(), transaction: None,
            },
        }]);
        let delivery = loop {
            let delivery = events.recv_delivery().await.expect("stop event");
            if matches!(delivery.event(), ClientEvent::MessageStored { message } if message.chat_id.get() == target && message.message_id.get() == 121 && message.sender_id.get() == route.owner_user_id) {
                break delivery;
            }
            delivery.ack().await?;
        };
        let active = conversation_for_chat(&route, target)?;
        let mut coordinator = TurnCoordinator::running(turn.turn_id.clone());
        let mut typing = TypingIndicator::start(&bot, target).await;
        let mut confirmed = false;
        handle_active_delivery(&bot, delivery, &manager, session.session_id(), &turn.turn_id,
            &route.store, &binding, &route, &active, &identity,
            &mut HashSet::new(), &mut HashMap::new(), &mut coordinator, &mut typing, &mut confirmed).await?;
        assert!(confirmed, "active cancellation must be confirmed");
        assert!(!manager.shutdown_epoch_if_idle().await?, "active work lease must prevent release");
        assert_eq!(route.store.get_inbound(&queued.event_id)?.unwrap().state, InboundState::Failed);
        drop(work);
        drop(turn);
        let stop = route.store.take_next_inbound(&binding, now_seconds())?.expect("durable handoff");
        assert_eq!(stop.direction.text, "/stop");
        let stop_event = stop.event_id.clone();
        let (sender, mut receiver) = tokio::sync::mpsc::channel(8);
        let (promotions, _promoted) = tokio::sync::mpsc::channel(1);
        let released = run_inbound_turn(&bot, &mut receiver, &manager, &route.store, &binding, &workspace,
            &route, &active, &identity, stop, None, sender, promotions).await;
        assert!(released.as_ref().is_err_and(|error| error.downcast_ref::<io::Error>().is_some_and(|error| error.kind() == io::ErrorKind::ConnectionAborted)), "idle stop must end the private epoch");
        assert_eq!(route.store.get_inbound(&stop_event)?.unwrap().state, InboundState::Completed);
        Ok::<_, Box<dyn std::error::Error>>(())
    }).await;
    let stopped = third.driver.shutdown().await;
    bot.shutdown().await?;
    result??;
    stopped?;
    eprintln!(
        "full handler default chat/projects/Open/history/link/stop/normal CLI/resume/exact-context/final delivery passed; disposable Codex session retained: {provider_session}; workspace: {}",
        workspace.display()
    );
    Ok(())
}
