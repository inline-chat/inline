//! Delivery faults through the real runtime, work actor and SQLite ledger,
//! with only the native session scripted (from the Oct 27 independent
//! review's probes, asserting the intended behavior).

use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use inline_agent_bridge::harness::{
    Availability, AvailabilityMatrix, Catalog, CatalogScope, DeliveryKind, Event, EventHub,
    EventStream, ExecutableInfo, ExecutableSource, HarnessFuture, InputDisposition, InputFact,
    InputReceipt, LiveWork, Op, OpError, OpOutcome, OpenError, OpenMode, OpenSpec, Origin,
    Released, RuntimeInfo, SendError, Session, SessionKey, SessionPage, SessionQuery,
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

    fn catalog<'a>(&'a self, _: CatalogScope) -> DriverFuture<'a, Catalog> {
        Box::pin(async {
            Ok(Catalog {
                permission_modes: vec![DriverSettingOption {
                    value: "plan".into(),
                    label: "Plan".into(),
                    description: None,
                    disabled: false,
                }],
                ..Default::default()
            })
        })
    }

    fn sessions<'a>(&'a self, _: SessionQuery) -> DriverFuture<'a, SessionPage> {
        Box::pin(async { Ok(Default::default()) })
    }

    fn open<'a>(&'a self, spec: OpenSpec) -> HarnessFuture<'a, Arc<dyn Session>, OpenError> {
        self.opened.lock().unwrap().push(spec);
        Box::pin(async move { Ok(self.session.clone() as Arc<dyn Session>) })
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
        unknown_first,
    });
    let harness = Arc::new(FakeHarness {
        session,
        opened: Mutex::new(vec![]),
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

fn spawn_work(runtime: &Runtime, cleanup: &mut Cleanup) -> mpsc::Sender<Command> {
    let handle = work::spawn(
        runtime.agent.clone(),
        9,
        Known {
            agent_session_id: Some(1),
            native: Some(ProviderSessionId::new("fault-session").unwrap()),
        },
        OutputMode::Detailed,
        SettingsChange::default(),
    );
    cleanup.tasks.push(handle.task);
    handle.tx
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
        .command(9, 1, Grants::OWNER, "permissions", "plan")
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
        .command(9, 1, Grants::OWNER, "permissions", "plan")
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
