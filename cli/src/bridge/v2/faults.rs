//! Delivery faults through the real runtime, work actor and SQLite ledger,
//! with only the native session scripted (from the Oct 27 independent
//! review's probes, asserting the intended behavior).

use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use inline_agent_bridge::harness::{
    Availability, AvailabilityMatrix, Catalog, CatalogFolder, CatalogScope, DeliveryKind, Event,
    EventHub, EventStream, ExecutableInfo, ExecutableSource, HarnessFuture, InputDisposition,
    InputFact, InputReceipt, LiveWork, Op, OpError, OpOutcome, OpenError, OpenMode, OpenSpec,
    Origin, Released, RuntimeInfo, SendError, Session, SessionKey, SessionPage, SessionQuery,
};
use inline_agent_bridge::{DriverFuture, DriverSettingOption, ProviderId, TurnId};

use super::*;
use crate::bridge::v2::work::{self, OwnerCalls};

struct Cleanup {
    dir: PathBuf,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

impl Drop for Cleanup {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

struct Owner;

impl OwnerCalls for Owner {
    fn connect(
        &self,
        _: proto::ConnectAgentSessionInput,
    ) -> futures_util::future::BoxFuture<'_, Result<proto::ConnectAgentSessionResult, String>> {
        Box::pin(async {
            Ok(proto::ConnectAgentSessionResult {
                agent_session: Some(proto::AgentSession {
                    id: 1,
                    ..Default::default()
                }),
                state: 1,
            })
        })
    }

    fn lookup(
        &self,
        _: proto::GetAgentSessionInput,
    ) -> futures_util::future::BoxFuture<'_, Result<proto::GetAgentSessionResult, String>> {
        Box::pin(async {
            Ok(proto::GetAgentSessionResult {
                connection: Some(proto::AgentSessionConnection {
                    agent_session: Some(proto::AgentSession {
                        id: 1,
                        ..Default::default()
                    }),
                    session_ref: "fault-session".to_owned(),
                    ..Default::default()
                }),
            })
        })
    }
}

struct FakeSession {
    key: SessionKey,
    hub: EventHub,
    sends: AtomicUsize,
    received: Mutex<Vec<Input>>,
    unknown_first: bool,
}

impl Session for FakeSession {
    fn key(&self) -> &SessionKey {
        &self.key
    }

    fn availability(&self) -> AvailabilityMatrix {
        DeliveryKind::ALL
            .into_iter()
            .fold(AvailabilityMatrix::default(), |matrix, kind| {
                matrix.with_delivery(kind, Availability::Supported)
            })
    }

    fn events(&self) -> EventStream {
        self.hub.subscribe()
    }

    fn send<'a>(&'a self, input: Input) -> HarnessFuture<'a, InputReceipt, SendError> {
        Box::pin(async move {
            let n = self.sends.fetch_add(1, Ordering::SeqCst);
            if self.unknown_first && n == 0 {
                return Err(SendError::Unknown("the reply was lost".into()));
            }
            self.received.lock().unwrap().push(input.clone());
            Ok(InputReceipt {
                input: input.id,
                disposition: InputDisposition::Started {
                    turn: TurnId::new(format!("turn-{n}")).unwrap(),
                },
                native: serde_json::Value::Null,
                acceptance: Default::default(),
            })
        })
    }

    fn control<'a>(&'a self, _: Op) -> HarnessFuture<'a, OpOutcome, OpError> {
        Box::pin(async { Ok(OpOutcome::accepted()) })
    }

    fn live_work(&self) -> LiveWork {
        LiveWork::default()
    }

    fn release<'a>(&'a self) -> HarnessFuture<'a, Released, OpError> {
        Box::pin(async { Err(OpError::Rejected("not in these tests".into())) })
    }
}

struct FakeHarness {
    session: Arc<FakeSession>,
    opened: Mutex<Vec<OpenSpec>>,
    /// Folders the harness knows, as Codex lists its projects.
    folders: Mutex<Vec<CatalogFolder>>,
    /// Sessions a resume does not find.
    missing: Mutex<Vec<String>>,
    catalog_scopes: Mutex<Vec<CatalogScope>>,
    commands: Mutex<HashMap<PathBuf, Vec<inline_agent_bridge::DriverCommand>>>,
}

impl HarnessDriver for FakeHarness {
    fn describe(&self) -> RuntimeInfo {
        RuntimeInfo {
            provider: ProviderId::new("claude").unwrap(),
            executable: ExecutableInfo {
                path: PathBuf::from("/fault-claude"),
                source: ExecutableSource::User,
                version: None,
                sha256: None,
                other_installs: vec![],
            },
            driver_version: "faults".into(),
            health: RuntimeHealth::Ready,
            manifest: None,
        }
    }

    fn catalog<'a>(&'a self, scope: CatalogScope) -> DriverFuture<'a, Catalog> {
        Box::pin(async move {
            let commands = scope
                .folder
                .as_ref()
                .and_then(|folder| self.commands.lock().unwrap().get(folder).cloned())
                .unwrap_or_default();
            self.catalog_scopes.lock().unwrap().push(scope);
            Ok(Catalog {
                commands,
                permission_modes: vec![DriverSettingOption {
                    value: "plan".into(),
                    label: "Plan".into(),
                    description: None,
                    disabled: false,
                }],
                folders: self.folders.lock().unwrap().clone(),
                ..Default::default()
            })
        })
    }

    fn sessions<'a>(&'a self, _: SessionQuery) -> DriverFuture<'a, SessionPage> {
        Box::pin(async { Ok(Default::default()) })
    }

    fn open<'a>(&'a self, spec: OpenSpec) -> HarnessFuture<'a, Arc<dyn Session>, OpenError> {
        let missing = matches!(&spec.mode, OpenMode::Resume { session }
            if self.missing.lock().unwrap().iter().any(|id| id == session.as_str()));
        self.opened.lock().unwrap().push(spec);
        Box::pin(async move {
            if missing {
                return Err(OpenError::NotFound);
            }
            Ok(self.session.clone() as Arc<dyn Session>)
        })
    }
}

fn runtime(cleanup: &mut Cleanup, harness: Arc<FakeHarness>) -> Runtime {
    let built = InlineClient::builder().build();
    cleanup.tasks.push(tokio::spawn(built.runner.run()));
    Runtime::new(
        V2Config {
            vocabulary: Vocabulary::Claude,
            agent_name: "Fault".into(),
            installation_id: "faults".into(),
            owner_user_id: 1,
            bot_user_id: 2,
            bot_username: "fault_bot".into(),
            dm_chat_id: 9,
            folder: cleanup.dir.clone(),
            machine_label: "faults".into(),
            executable_path: None,
            accept_messages_after: 0,
            allowlist: vec![],
            ledger_path: cleanup.dir.join("ledger.sqlite"),
            attachments_dir: cleanup.dir.join("media"),
        },
        built.client,
        Arc::new(Owner),
        harness,
        None,
    )
    .unwrap()
}

fn fixture(unknown_first: bool) -> (Runtime, Arc<FakeHarness>, Cleanup) {
    let dir = std::env::temp_dir().join(format!("inline-v2-faults-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&dir).unwrap();
    let mut cleanup = Cleanup { dir, tasks: vec![] };
    let key = SessionKey {
        provider: ProviderId::new("claude").unwrap(),
        session: ProviderSessionId::new("fault-session").unwrap(),
    };
    let session = Arc::new(FakeSession {
        hub: EventHub::new(key.clone(), 32),
        key,
        sends: AtomicUsize::new(0),
        received: Mutex::new(Vec::new()),
        unknown_first,
    });
    let harness = Arc::new(FakeHarness {
        session,
        opened: Mutex::new(vec![]),
        folders: Mutex::new(vec![]),
        missing: Mutex::new(vec![]),
        catalog_scopes: Mutex::new(vec![]),
        commands: Mutex::new(HashMap::new()),
    });
    (runtime(&mut cleanup, harness.clone()), harness, cleanup)
}

fn input(runtime: &Runtime, message: i64) -> (String, Command) {
    let id = input_id(2, 9, message, "direct");
    runtime.agent.ledger.begin(&id, 9, message, 1).unwrap();
    let input = InputId::new(id.clone()).unwrap();
    (
        id,
        Command::Input {
            input: Box::new(Input {
                id: input.clone(),
                content: InputContent::text("a task"),
                origin: Origin::Owner { user: UserId(1) },
                delivery: Delivery::Turn,
            }),
            pending: PendingInput {
                id: input,
                sender: UserId(1),
                required: Operation::StartWork,
            },
            message_id: message,
            answer_reply: false,
            reply_to: None,
        },
    )
}

fn state(runtime: &Runtime, id: &str) -> Option<InputState> {
    runtime
        .agent
        .ledger
        .get(id)
        .unwrap()
        .map(|record| record.state)
}

async fn until(mut condition: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(3), async {
        while !condition() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("no progress");
}

fn spawn_work(runtime: &Runtime, cleanup: &mut Cleanup) -> crate::bridge::v2::work::CommandSender {
    let handle = work::spawn(
        runtime.agent.clone(),
        9,
        Known {
            agent_session_id: Some(1),
            native: Some(ProviderSessionId::new("fault-session").unwrap()),
            from_v1: false,
        },
        OutputMode::Detailed,
        SettingsChange::default(),
    );
    cleanup.tasks.push(handle.task);
    handle.tx
}

#[tokio::test]
async fn service_messages_are_skipped_but_identical_human_text_still_runs() {
    let (mut runtime, harness, mut cleanup) = fixture(false);
    let mut message = MessageRecord {
        chat_id: InlineId::new(9),
        message_id: InlineId::new(35),
        sender_id: InlineId::new(1),
        timestamp: 1,
        is_outgoing: false,
        content: inline_client::MessageContent::Text {
            text: "Linked from another thread".into(),
        },
        reply_to_message_id: None,
        metadata: inline_client::MessageMetadata {
            is_service: true,
            ..Default::default()
        },
        transaction: None,
    };
    for chat_id in [9, 10, 11] {
        runtime.own_threads.insert(chat_id, chat_id == 10);
        runtime
            .follows
            .insert(chat_id, (Some(true), std::time::Instant::now()));
        message.chat_id = InlineId::new(chat_id);
        tokio::time::timeout(Duration::from_millis(200), runtime.on_message(&message))
            .await
            .expect("service events must be skipped before any native or network call")
            .unwrap();
        assert!(
            runtime
                .agent
                .ledger
                .get(&input_id(2, chat_id, 35, "direct"))
                .unwrap()
                .is_none()
        );
    }
    assert!(runtime.works.is_empty());
    assert!(harness.opened.lock().unwrap().is_empty());
    assert_eq!(harness.session.sends.load(Ordering::SeqCst), 0);

    // The fallback wording is also valid human input; only provenance
    // distinguishes it. The skipped notice must not occupy its input ID.
    message.chat_id = InlineId::new(10);
    message.metadata.is_service = false;
    message.metadata.sender_is_bot = Some(false);
    runtime.agent.names.remember(1, "Owner".into()).await;
    runtime.loop_roots.insert(10, 10);
    runtime.on_message(&message).await.unwrap();
    cleanup.tasks.push(runtime.works.remove(&10).unwrap().task);
    until(|| harness.session.sends.load(Ordering::SeqCst) == 1).await;
    assert!(state(&runtime, &input_id(2, 10, 35, "direct")).is_some());
}

#[tokio::test]
async fn v1_receipts_prevent_replayed_work_after_v2_cutover_and_restart() {
    let (first, harness, mut cleanup) = fixture(false);
    let path = cleanup.dir.join("bridge.sqlite");
    let legacy = Arc::new(inline_agent_bridge::BridgeStore::open(&path).unwrap());
    legacy.claim_event("inline-message-9-35", 1).unwrap();
    let message = MessageRecord {
        chat_id: InlineId::new(9),
        message_id: InlineId::new(35),
        sender_id: InlineId::new(1),
        timestamp: 1,
        is_outgoing: false,
        content: inline_client::MessageContent::Text {
            text: "old work".into(),
        },
        reply_to_message_id: None,
        metadata: Default::default(),
        transaction: None,
    };
    let mut first = first.with_legacy_store(legacy);
    let mut second = runtime(&mut cleanup, harness.clone()).with_legacy_store(Arc::new(
        inline_agent_bridge::BridgeStore::open(&path).unwrap(),
    ));
    for runtime in [&mut first, &mut second] {
        tokio::time::timeout(Duration::from_millis(200), runtime.on_message(&message))
            .await
            .expect("old input must be skipped before any native or network call")
            .unwrap();
        assert!(
            runtime
                .agent
                .ledger
                .get(&input_id(2, 9, 35, "direct"))
                .unwrap()
                .is_none()
        );
    }
    assert!(harness.opened.lock().unwrap().is_empty());
    assert_eq!(harness.session.sends.load(Ordering::SeqCst), 0);
    let legacy = inline_agent_bridge::BridgeStore::open(path).unwrap();
    assert!(legacy.event_processed("inline-message-9-35").unwrap());
    assert!(!legacy.event_processed("inline-message-10-35").unwrap());
    assert!(!legacy.event_processed("inline-message-9-36").unwrap());
}

#[tokio::test]
async fn an_input_the_ledger_cannot_record_is_never_sent() {
    let (runtime, harness, mut cleanup) = fixture(false);
    let (id, command) = input(&runtime, 12);
    rusqlite::Connection::open(cleanup.dir.join("ledger.sqlite"))
        .unwrap()
        .execute_batch(
            "CREATE TRIGGER fail_updates BEFORE UPDATE ON v2_inputs
             BEGIN SELECT RAISE(FAIL, 'disk full'); END;",
        )
        .unwrap();
    let tx = spawn_work(&runtime, &mut cleanup);
    tx.send(command).await.unwrap();
    until(|| !harness.opened.lock().unwrap().is_empty()).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(harness.session.sends.load(Ordering::SeqCst), 0);
    assert_eq!(state(&runtime, &id), Some(InputState::Received));
}

#[tokio::test]
async fn an_unknown_delivery_is_settled_by_the_session_never_resent() {
    let (runtime, harness, mut cleanup) = fixture(true);
    let tx = spawn_work(&runtime, &mut cleanup);
    let (first, command) = input(&runtime, 10);
    tx.send(command).await.unwrap();
    until(|| state(&runtime, &first) == Some(InputState::Unknown)).await;
    // Later input is not held back by it.
    let (second, command) = input(&runtime, 11);
    tx.send(command).await.unwrap();
    until(|| state(&runtime, &second) == Some(InputState::Accepted)).await;
    assert_eq!(harness.session.sends.load(Ordering::SeqCst), 2);
    // The session shows it ran: settled, and it was sent only once.
    harness.session.hub.emit(Event::Input {
        id: InputId::new(first.clone()).unwrap(),
        fact: InputFact::Consumed {
            turn: TurnId::new("turn-0").unwrap(),
        },
    });
    until(|| state(&runtime, &first) == Some(InputState::Consumed)).await;
    assert_eq!(harness.session.sends.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn restart_accepts_positive_receipts_and_keeps_unconfirmed_input_unknown() {
    let (mut runtime, harness, _cleanup) = fixture(false);
    let (ran, _) = input(&runtime, 13);
    let (lost, _) = input(&runtime, 14);
    runtime.agent.ledger.set(&ran, InputState::Unknown).unwrap();
    runtime.agent.ledger.set(&lost, InputState::Sent).unwrap();
    // The resumed session reports what it already consumed.
    harness.session.hub.emit(Event::Input {
        id: InputId::new(ran.clone()).unwrap(),
        fact: InputFact::Consumed {
            turn: TurnId::new("turn-9").unwrap(),
        },
    });
    runtime.recover().await;
    until(|| {
        state(&runtime, &ran) == Some(InputState::Consumed)
            && state(&runtime, &lost) == Some(InputState::Unknown)
    })
    .await;
    assert!(matches!(
        harness.opened.lock().unwrap()[0].mode,
        OpenMode::Resume { .. }
    ));
    assert_eq!(harness.session.sends.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_thread_permission_choice_survives_a_restart() {
    let (mut runtime, harness, mut cleanup) = fixture(false);
    let reply = runtime
        .command(9, 1, Grants::OWNER, "permissions", "plan", &[])
        .await;
    assert!(reply.contains("Set for this thread"), "{reply}");
    drop(runtime);
    let mut restarted = super::faults::runtime(&mut cleanup, harness.clone());
    restarted.ensure_work(9, None).await.unwrap();
    let (id, command) = input(&restarted, 15);
    restarted.works[&9].tx.send(command).await.unwrap();
    until(|| state(&restarted, &id) == Some(InputState::Accepted)).await;
    assert_eq!(
        harness
            .opened
            .lock()
            .unwrap()
            .last()
            .unwrap()
            .settings
            .permission_mode
            .as_deref(),
        Some("plan")
    );
    cleanup.tasks.push(restarted.works.remove(&9).unwrap().task);
}

#[tokio::test]
async fn a_stream_gap_is_not_proof_of_non_delivery() {
    let (mut runtime, harness, mut cleanup) = fixture(false);
    let (ran, _) = input(&runtime, 81);
    runtime.agent.ledger.set(&ran, InputState::Unknown).unwrap();
    harness.session.hub.emit(Event::Input {
        id: InputId::new(ran.clone()).unwrap(),
        fact: InputFact::Consumed {
            turn: TurnId::new("already-ran").unwrap(),
        },
    });
    // The actual bounded EventHub now reports a gap before its retained tail.
    for _ in 0..40 {
        harness.session.hub.emit(Event::State {
            state: inline_agent_bridge::harness::RunState::Idle,
        });
    }
    runtime.recover().await;
    until(|| !harness.opened.lock().unwrap().is_empty()).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(state(&runtime, &ran), Some(InputState::Unknown));
    assert_eq!(harness.session.sends.load(Ordering::SeqCst), 0);
    cleanup.tasks.push(runtime.works.remove(&9).unwrap().task);
}

#[tokio::test]
async fn completed_turn_consumption_remains_consumed() {
    let (mut runtime, harness, mut cleanup) = fixture(false);
    let (ran, _) = input(&runtime, 82);
    runtime.agent.ledger.set(&ran, InputState::Unknown).unwrap();
    harness.session.hub.emit(Event::Turn {
        turn: TurnId::new("already-completed").unwrap(),
        phase: inline_agent_bridge::harness::TurnPhase::Completed {
            outcome: inline_agent_bridge::TurnOutcome::Completed,
            inputs_consumed: vec![InputId::new(ran.clone()).unwrap()],
            error: None,
            duration_ms: None,
        },
    });
    runtime.recover().await;
    until(|| state(&runtime, &ran) == Some(InputState::Consumed)).await;
    assert_eq!(harness.session.sends.load(Ordering::SeqCst), 0);
    cleanup.tasks.push(runtime.works.remove(&9).unwrap().task);
}

#[tokio::test]
async fn moved_work_keeps_permissions_on_restart() {
    let (mut runtime, harness, mut cleanup) = fixture(false);
    let reply = runtime
        .command(9, 1, Grants::OWNER, "permissions", "plan", &[])
        .await;
    assert!(reply.contains("Set for this thread"));
    runtime.ensure_work(9, None).await.unwrap();
    runtime.moved_work(9, 10);
    cleanup.tasks.push(runtime.works.remove(&10).unwrap().task);
    drop(runtime);
    let mut restarted = super::faults::runtime(&mut cleanup, harness.clone());
    restarted.ensure_work(10, None).await.unwrap();
    let (_, command) = input(&restarted, 83);
    restarted.works[&10].tx.send(command).await.unwrap();
    until(|| !harness.opened.lock().unwrap().is_empty()).await;
    assert_eq!(
        harness
            .opened
            .lock()
            .unwrap()
            .last()
            .unwrap()
            .settings
            .permission_mode
            .as_deref(),
        Some("plan"),
        "the destination retains the saved permission mode"
    );
    cleanup
        .tasks
        .push(restarted.works.remove(&10).unwrap().task);
}

#[tokio::test]
async fn pending_final_and_closed_card_recover_after_actor_restart() {
    let (runtime, _, _cleanup) = fixture(false);
    work::recovery_tests::pending_output_survives_restart(runtime.agent.clone()).await;
}

#[tokio::test]
async fn acp_migration_does_not_silently_replace_a_missing_v1_session() {
    for vocabulary in [Vocabulary::OpenCode, Vocabulary::Amp] {
        let (mut runtime, harness, _cleanup) = fixture(false);
        Arc::get_mut(&mut runtime.agent).unwrap().vocabulary = vocabulary;
        harness.missing.lock().unwrap().push("fault-session".into());
        work::recovery_tests::acp_migration_preserves_unavailable_session(runtime.agent.clone())
            .await;
        let opened = harness.opened.lock().unwrap();
        assert_eq!(opened.len(), 1);
        assert!(
            matches!(&opened[0].mode, OpenMode::Resume { session } if session.as_str() == "fault-session")
        );
    }
}

#[tokio::test]
async fn acp_unsupported_commands_offer_a_useful_next_step_without_opening_a_session() {
    for vocabulary in [Vocabulary::OpenCode, Vocabulary::Amp] {
        let (mut runtime, harness, _cleanup) = fixture(false);
        runtime.config.vocabulary = vocabulary;
        let compact = runtime
            .command(9, 1, Grants::OWNER, "compact", "", &[])
            .await;
        assert!(compact.contains("keep chatting") && compact.contains("/new"));
        let terminal = runtime
            .command(9, 1, Grants::OWNER, "terminal", "", &[])
            .await;
        assert!(terminal.contains("/release"));
        assert!(!compact.contains("ACP") && !terminal.contains("ACP"));
        assert!(harness.opened.lock().unwrap().is_empty());
    }
}

#[tokio::test]
async fn acp_advertised_commands_use_the_threads_folder_and_preserve_inline_controls() {
    use inline_agent_bridge::{DriverCommand, DriverCommandInput};
    for vocabulary in [Vocabulary::OpenCode, Vocabulary::Amp] {
        let (mut runtime, harness, mut cleanup) = fixture(false);
        runtime.config.vocabulary = vocabulary;
        let folder = PathBuf::from("/project-with-commands");
        runtime.thread_settings.entry(9).or_default().folder = Some(folder.clone());
        let advertised = if vocabulary == Vocabulary::OpenCode {
            vec!["compact", "plan", "review", "undo", "clear", "init"]
        } else {
            vec!["init", "review"]
        };
        harness.commands.lock().unwrap().insert(
            folder.clone(),
            advertised
                .iter()
                .copied()
                .chain(["stop", "model"])
                .map(|name| DriverCommand {
                    name: name.into(),
                    description: String::new(),
                    input_hint: None,
                    input: DriverCommandInput::None,
                })
                .collect(),
        );
        for name in &advertised {
            assert!(
                runtime.forwards_command(9, name, Grants::OWNER).await,
                "{name}"
            );
            assert!(
                !runtime.forwards_command(10, name, Grants::OWNER).await,
                "{name} leaked folders"
            );
        }
        for name in ["stop", "new", "model", "help", "terminal", "queue"] {
            assert!(
                !runtime.forwards_command(9, name, Grants::OWNER).await,
                "{name}"
            );
        }
        assert!(
            !runtime
                .forwards_command(9, "not-advertised", Grants::OWNER)
                .await
        );
        let help = runtime.command(9, 1, Grants::OWNER, "help", "", &[]).await;
        assert!(help.contains("Provider commands for this thread:"));
        for name in &advertised {
            assert!(help.contains(&format!("\n/{name}")));
        }
        let elsewhere = runtime.command(10, 1, Grants::OWNER, "help", "", &[]).await;
        assert!(!elsewhere.contains("Provider commands for this thread:"));
        if vocabulary == Vocabulary::Amp {
            assert!(!runtime.forwards_command(9, "compact", Grants::OWNER).await);
        }
        assert!(
            !runtime
                .forwards_command(
                    9,
                    "review",
                    Grants {
                        invoke: true,
                        ..Grants::NONE
                    }
                )
                .await
        );
        let name = if vocabulary == Vocabulary::OpenCode {
            "compact"
        } else {
            "init"
        };
        let text = format!("/{name}@{}", runtime.config.bot_username);
        let message = MessageRecord {
            chat_id: InlineId::new(9),
            message_id: InlineId::new(901),
            sender_id: InlineId::new(1),
            timestamp: 1,
            is_outgoing: false,
            content: inline_client::MessageContent::Text { text: text.clone() },
            reply_to_message_id: None,
            metadata: Default::default(),
            transaction: None,
        };
        let group = GroupMessage {
            chat_id: 9,
            message_id: 901,
            author: inline_agent_bridge::group::Author {
                user_id: 1,
                display_name: "Owner".into(),
                kind: inline_agent_bridge::group::AuthorKind::Human,
            },
            conversation: Conversation::Dm,
            via: Default::default(),
            text,
            entities: vec![inline_agent_bridge::group::MessageEntity::Command {
                offset: 0,
                length: 8,
                name: name.into(),
                target_user_id: Some(2),
            }],
            reply_to: None,
            sent_at: 1,
        };
        let decision = IntakeDecision::Act {
            reason: DirectReason::Command,
            join: false,
            required: Operation::StartWork,
        };
        runtime
            .act(
                &message,
                &group,
                &decision,
                Operation::StartWork,
                Grants::OWNER,
                None,
            )
            .await
            .unwrap();
        until(|| !harness.session.received.lock().unwrap().is_empty()).await;
        {
            let received = harness.session.received.lock().unwrap();
            assert_eq!(received[0].content.text, format!("/{name}"));
            assert!(received[0].content.context.is_none());
        }
        assert!(runtime.forwards_command(9, name, Grants::OWNER).await);
        let scopes = harness.catalog_scopes.lock().unwrap();
        let scope = scopes.last().unwrap();
        assert_eq!(scope.folder.as_ref(), Some(&folder));
        assert_eq!(
            scope.session.as_ref().map(|session| session.as_str()),
            Some("fault-session")
        );
        drop(scopes);
        let handle = runtime.works.remove(&9).unwrap();
        cleanup.tasks.push(handle.task);
    }
}

#[tokio::test]
async fn unknown_native_manifest_keeps_claudes_compact_control() {
    let (mut runtime, _, _cleanup) = fixture(false);
    let document = runtime.settings_document(9, &Catalog::default()).await;
    assert!(
        document
            .sections
            .iter()
            .flat_map(|section| &section.items)
            .any(|item| item.id == settings::ITEM_COMPACT)
    );
    runtime.config.vocabulary = Vocabulary::OpenCode;
    let document = runtime.settings_document(9, &Catalog::default()).await;
    assert!(
        !document
            .sections
            .iter()
            .flat_map(|section| &section.items)
            .any(|item| item.id == settings::ITEM_COMPACT)
    );
}

struct UnreachableOwner;
impl OwnerCalls for UnreachableOwner {
    fn connect(
        &self,
        _: proto::ConnectAgentSessionInput,
    ) -> futures_util::future::BoxFuture<'_, Result<proto::ConnectAgentSessionResult, String>> {
        Box::pin(async { Err("owner connection unavailable".into()) })
    }
    fn lookup(
        &self,
        _: proto::GetAgentSessionInput,
    ) -> futures_util::future::BoxFuture<'_, Result<proto::GetAgentSessionResult, String>> {
        Box::pin(async { Err("owner connection unavailable".into()) })
    }
}
#[tokio::test]
async fn unavailable_canonical_lookup_does_not_reopen_source_publication() {
    let (mut runtime, _, _cleanup) = fixture(false);
    Arc::get_mut(&mut runtime.agent).unwrap().owner = Arc::new(UnreachableOwner);
    work::recovery_tests::unavailable_move_lookup_keeps_publication_fenced(runtime.agent.clone())
        .await;
}

/// Inline knows no session for the thread until the work opens one.
struct NoSessionYet;
impl OwnerCalls for NoSessionYet {
    fn connect(
        &self,
        input: proto::ConnectAgentSessionInput,
    ) -> futures_util::future::BoxFuture<'_, Result<proto::ConnectAgentSessionResult, String>> {
        Owner.connect(input)
    }
    fn lookup(
        &self,
        _: proto::GetAgentSessionInput,
    ) -> futures_util::future::BoxFuture<'_, Result<proto::GetAgentSessionResult, String>> {
        Box::pin(async { Ok(proto::GetAgentSessionResult::default()) })
    }
}

/// A runtime whose agent works in its own folder, and whose harness knows
/// another: (runtime, harness, cleanup, own folder, other folder).
fn folder_fixture(
    owner: Arc<dyn OwnerCalls>,
) -> (Runtime, Arc<FakeHarness>, Cleanup, PathBuf, PathBuf) {
    let (mut runtime, harness, cleanup) = fixture(false);
    // The bridge keeps canonical paths, the agent's own folder among them.
    let own = std::fs::canonicalize(&cleanup.dir).unwrap();
    let other = own.join("other");
    std::fs::create_dir(&other).unwrap();
    *harness.folders.lock().unwrap() = vec![CatalogFolder {
        path: other.clone(),
        label: "Other project".into(),
    }];
    runtime.config.folder = own.clone();
    let agent = Arc::get_mut(&mut runtime.agent).unwrap();
    agent.folder = own.clone();
    agent.owner = owner;
    let runtime = runtime.with_folders(super::super::folders::FolderSource::listing(
        &own.join("bridge.sqlite"),
        "faults",
        &[],
    ));
    (runtime, harness, cleanup, own, other)
}

fn folder_item(response: &BotChatSettingsResponse) -> inline_client::BotChatSettingsItem {
    let document = match response {
        BotChatSettingsResponse::Document(document) => document,
        BotChatSettingsResponse::Problem(problem) => {
            problem.current_document.as_ref().expect("a document")
        }
        other => panic!("no document: {other:?}"),
    };
    document
        .sections
        .iter()
        .flat_map(|section| &section.items)
        .find(|item| item.id == settings::ITEM_FOLDER_CHOICE)
        .cloned()
        .expect("the folder choice")
}

fn revision(response: &BotChatSettingsResponse) -> String {
    match response {
        BotChatSettingsResponse::Document(document) => document.revision.clone(),
        other => panic!("no document: {other:?}"),
    }
}

fn selected(item: &inline_client::BotChatSettingsItem) -> &str {
    match &item.control {
        inline_client::BotChatSettingsControl::Select { value, .. } => value,
        other => panic!("not a select: {other:?}"),
    }
}

#[tokio::test]
async fn a_folder_picked_in_settings_is_where_the_session_opens_and_stays() {
    let (mut runtime, harness, mut cleanup, own, other) = folder_fixture(Arc::new(NoSessionYet));
    let own_id = crate::bridge::workspace_id(&own).unwrap();
    let other_id = crate::bridge::workspace_id(&other).unwrap();
    // The agent publishes its folders, its own the default, the harness's
    // under the harness's name.
    let catalog = runtime.catalog().await;
    let catalog = runtime
        .folders(&catalog)
        .unwrap()
        .catalog("faults")
        .expect("folder catalog");
    assert_eq!(catalog.default_project_id.as_deref(), Some(own_id.as_str()));
    assert!(
        catalog
            .options
            .iter()
            .any(|option| option.id == other_id.as_str() && option.label == "Other project")
    );

    // Before any work, the thread's folder is a choice.
    let shown = runtime.chat_settings(9, 1, 1, None).await;
    let choice = folder_item(&shown);
    assert!(!choice.disabled);
    assert_eq!(selected(&choice), own_id.as_str());
    let value = BotSettingsValue::String(other_id.as_str().to_owned());
    let chosen = runtime
        .chat_settings(
            9,
            1,
            1,
            Some((
                settings::ITEM_FOLDER_CHOICE,
                Some(&value),
                &revision(&shown),
            )),
        )
        .await;
    assert_eq!(selected(&folder_item(&chosen)), other_id.as_str());

    // The work opens its session there.
    runtime.ensure_work(9, None).await.unwrap();
    let (id, command) = input(&runtime, 91);
    runtime.works[&9].tx.send(command).await.unwrap();
    until(|| state(&runtime, &id) == Some(InputState::Accepted)).await;
    assert_eq!(harness.opened.lock().unwrap().last().unwrap().folder, other);
    until(|| *runtime.works[&9].phase.borrow() != WorkPhase::None).await;

    // Now the session keeps its folder: shown, disabled, and refused.
    let shown = runtime.chat_settings(9, 1, 1, None).await;
    let choice = folder_item(&shown);
    assert!(choice.disabled);
    assert_eq!(selected(&choice), other_id.as_str());
    assert!(
        choice
            .disabled_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("Start a new thread"))
    );
    let back = BotSettingsValue::String(own_id.as_str().to_owned());
    let refused = runtime
        .chat_settings(
            9,
            1,
            1,
            Some((settings::ITEM_FOLDER_CHOICE, Some(&back), &revision(&shown))),
        )
        .await;
    let BotChatSettingsResponse::Problem(problem) = &refused else {
        panic!("a change after the session opened was applied: {refused:?}");
    };
    assert!(
        problem.message.contains("works in other"),
        "{}",
        problem.message
    );
    assert_eq!(runtime.thread_folder(9), other);
    assert_eq!(harness.opened.lock().unwrap().len(), 1);
    cleanup.tasks.push(runtime.works.remove(&9).unwrap().task);
}

#[tokio::test]
async fn a_bound_thread_runs_in_its_project_and_a_restart_keeps_it() {
    let (mut runtime, harness, mut cleanup, _own, other) = folder_fixture(Arc::new(NoSessionYet));
    let other_id = crate::bridge::workspace_id(&other).unwrap();
    runtime
        .bound_project(9, Some(other_id.as_str().to_owned()))
        .await;
    assert_eq!(runtime.thread_folder(9), other);
    runtime.ensure_work(9, None).await.unwrap();
    let (id, command) = input(&runtime, 92);
    runtime.works[&9].tx.send(command).await.unwrap();
    until(|| state(&runtime, &id) == Some(InputState::Accepted)).await;
    assert_eq!(harness.opened.lock().unwrap().last().unwrap().folder, other);
    cleanup.tasks.push(runtime.works.remove(&9).unwrap().task);
    drop(runtime);

    // A restart resumes the session where it opened.
    let mut restarted = super::faults::runtime(&mut cleanup, harness.clone());
    restarted.ensure_work(9, None).await.unwrap();
    let (id, command) = input(&restarted, 93);
    restarted.works[&9].tx.send(command).await.unwrap();
    until(|| state(&restarted, &id) == Some(InputState::Accepted)).await;
    assert_eq!(harness.opened.lock().unwrap().last().unwrap().folder, other);
    cleanup.tasks.push(restarted.works.remove(&9).unwrap().task);
}

#[tokio::test]
async fn a_session_inline_knows_keeps_its_folder_with_no_work_here() {
    // The default owner knows a session for every thread.
    let (mut runtime, harness, _cleanup, _own, other) = folder_fixture(Arc::new(Owner));
    let other_id = crate::bridge::workspace_id(&other).unwrap();
    let shown = runtime.chat_settings(9, 1, 1, None).await;
    assert!(folder_item(&shown).disabled);
    runtime
        .bound_project(9, Some(other_id.as_str().to_owned()))
        .await;
    assert_eq!(runtime.thread_folder(9), runtime.config.folder);
    assert!(harness.opened.lock().unwrap().is_empty());
}

/// A runtime that knows v1's session `session` for chat 9, in the harness's
/// other folder: (runtime, harness, cleanup, other folder).
fn v1_fixture(session: &str) -> (Runtime, Arc<FakeHarness>, Cleanup, PathBuf) {
    let (runtime, harness, cleanup, _own, other) = folder_fixture(Arc::new(NoSessionYet));
    let v1 = super::super::folders::FolderSource::listing(
        &cleanup.dir.join("v1.sqlite"),
        "faults",
        &[&other],
    );
    v1.store
        .put_binding(
            &inline_agent_bridge::BindingKey {
                installation_id: v1.installation_id.clone(),
                chat_id: 9,
                workspace_id: crate::bridge::workspace_id(&other).unwrap(),
            },
            &ProviderId::new("codex").unwrap(),
            &ProviderSessionId::new(session).unwrap(),
            10,
        )
        .unwrap();
    (runtime.with_legacy_store(v1.store), harness, cleanup, other)
}

fn opened_modes(harness: &FakeHarness) -> Vec<String> {
    harness
        .opened
        .lock()
        .unwrap()
        .iter()
        .map(|spec| match &spec.mode {
            OpenMode::Start => "start".to_owned(),
            OpenMode::Resume { session } => format!("resume {session}"),
            OpenMode::Fork { session, .. } => format!("fork {session}"),
        })
        .collect()
}

#[tokio::test]
async fn a_thread_v1_served_goes_on_in_its_session_and_folder() {
    let (mut runtime, harness, mut cleanup, other) = v1_fixture("fault-session");
    runtime.ensure_work(9, None).await.unwrap();
    let (id, command) = input(&runtime, 93);
    runtime.works[&9].tx.send(command).await.unwrap();
    until(|| state(&runtime, &id) == Some(InputState::Accepted)).await;
    assert_eq!(opened_modes(&harness), ["resume fault-session"]);
    assert_eq!(harness.opened.lock().unwrap()[0].folder, other);
    // Inline now knows the session, so later lookups find it there.
    until(|| runtime.works[&9].agent_session_id() == Some(1)).await;
    let task = runtime.works.remove(&9).unwrap().task;
    task.abort();
    let _ = task.await;
    drop(runtime);
    // The next process sees the registered session on Inline. Its folder
    // survives in the v2 ledger without the legacy store attached.
    let mut restarted = super::faults::runtime(&mut cleanup, harness.clone());
    restarted.ensure_work(9, None).await.unwrap();
    let (id, command) = input(&restarted, 95);
    restarted.works[&9].tx.send(command).await.unwrap();
    until(|| state(&restarted, &id) == Some(InputState::Accepted)).await;
    assert_eq!(harness.opened.lock().unwrap()[1].folder, other);
    cleanup.tasks.push(restarted.works.remove(&9).unwrap().task);
}

#[tokio::test]
async fn registered_acp_legacy_sessions_inherit_only_their_matching_folder() {
    for vocabulary in [Vocabulary::OpenCode, Vocabulary::Amp] {
        for (legacy_session, explicit_folder, use_legacy) in [
            ("fault-session", false, true),
            ("fault-session", true, false),
            ("another-session", false, false),
        ] {
            let (mut runtime, harness, mut cleanup, other) = v1_fixture(legacy_session);
            runtime.config.vocabulary = vocabulary;
            let agent = Arc::get_mut(&mut runtime.agent).unwrap();
            agent.owner = Arc::new(Owner);
            agent.vocabulary = vocabulary;
            if explicit_folder {
                runtime.thread_settings.entry(9).or_default().folder =
                    Some(runtime.config.folder.clone());
            }
            runtime.ensure_work(9, None).await.unwrap();
            let (id, command) = input(&runtime, 96);
            runtime.works[&9].tx.send(command).await.unwrap();
            until(|| state(&runtime, &id) == Some(InputState::Accepted)).await;
            let expected = if use_legacy {
                &other
            } else {
                &runtime.config.folder
            };
            assert_eq!(&harness.opened.lock().unwrap()[0].folder, expected);
            assert_eq!(&runtime.thread_folder(9), expected);
            cleanup.tasks.push(runtime.works.remove(&9).unwrap().task);
        }
    }
}

#[tokio::test]
async fn a_v1_session_that_does_not_reopen_gives_way_to_a_fresh_one() {
    let (mut runtime, harness, mut cleanup, _other) = v1_fixture("gone-session");
    harness
        .missing
        .lock()
        .unwrap()
        .push("gone-session".to_owned());
    runtime.ensure_work(9, None).await.unwrap();
    let (id, command) = input(&runtime, 94);
    runtime.works[&9].tx.send(command).await.unwrap();
    until(|| state(&runtime, &id) == Some(InputState::Accepted)).await;
    assert_eq!(opened_modes(&harness), ["resume gone-session", "start"]);
    assert_eq!(harness.session.sends.load(Ordering::SeqCst), 1);
    until(|| runtime.works[&9].agent_session_id() == Some(1)).await;
    cleanup.tasks.push(runtime.works.remove(&9).unwrap().task);
}
