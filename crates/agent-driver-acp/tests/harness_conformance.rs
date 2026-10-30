//! Exercise the bridge v2 adapter over real ACP request/notification dispatch.
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use agent_client_protocol::{Agent, ConnectionTo, schema::v1 as acp};
use futures_util::StreamExt;
use inline_agent_bridge::harness::*;
use inline_agent_bridge::{AgentDriver, ProviderId, TurnOutcome};
use inline_agent_driver_acp::{AcpDriver, AcpHarness};
use tokio::sync::Notify;

fn options(model: &str, effort: &str) -> Vec<acp::SessionConfigOption> {
    vec![
        acp::SessionConfigOption::select(
            "mode",
            "Mode",
            "build",
            vec![
                acp::SessionConfigSelectOption::new("build", "Build"),
                acp::SessionConfigSelectOption::new("plan", "Plan"),
            ],
        )
        .category(acp::SessionConfigOptionCategory::Mode),
        acp::SessionConfigOption::select(
            "model",
            "Model",
            model.to_owned(),
            vec![
                acp::SessionConfigSelectOption::new("provider/a", "A"),
                acp::SessionConfigSelectOption::new("provider/b", "B"),
            ],
        )
        .category(acp::SessionConfigOptionCategory::Model),
        acp::SessionConfigOption::select(
            "effort",
            "Effort",
            effort.to_owned(),
            vec![
                acp::SessionConfigSelectOption::new("low", "Low"),
                acp::SessionConfigSelectOption::new("high", "High"),
            ],
        )
        .category(acp::SessionConfigOptionCategory::ThoughtLevel),
    ]
}

struct Fixture {
    harness: AcpHarness,
    driver: Arc<AcpDriver>,
    selections: Arc<Mutex<Vec<(String, String)>>>,
}

async fn fixture() -> Fixture {
    let selections = Arc::new(Mutex::new(Vec::new()));
    let capture = selections.clone();
    let mode_capture = selections.clone();
    let cancel = Arc::new(Notify::new());
    let cancel_request = cancel.clone();
    let agent = Agent.builder()
        .on_receive_request(async |r: acp::InitializeRequest, responder, _| {
            responder.respond(acp::InitializeResponse::new(r.protocol_version)
                .agent_info(acp::Implementation::new("opencode", "2.0.32"))
                .agent_capabilities(acp::AgentCapabilities::new().session_capabilities(
                    acp::SessionCapabilities::new().resume(acp::SessionResumeCapabilities::new()))))
        }, agent_client_protocol::on_receive_request!())
        .on_receive_request(async |_r: acp::NewSessionRequest, responder, connection: ConnectionTo<agent_client_protocol::Client>| {
            connection.send_notification(acp::SessionNotification::new("ses_fixture", acp::SessionUpdate::AvailableCommandsUpdate(acp::AvailableCommandsUpdate::new(vec![acp::AvailableCommand::new("fixture-command", "Fixture command")]))))?;
            responder.respond(acp::NewSessionResponse::new("ses_fixture").config_options(options("provider/a", "low")))
        }, agent_client_protocol::on_receive_request!())
        .on_receive_request(async |r: acp::ResumeSessionRequest, responder, _| {
            assert_eq!(r.session_id.to_string(), "ses_fixture");
            responder.respond(acp::ResumeSessionResponse::new().config_options(options("provider/a", "low")))
        }, agent_client_protocol::on_receive_request!())
        .on_receive_request(async move |r: acp::SetSessionConfigOptionRequest, responder, _| {
            let id = r.config_id.to_string();
            let value = r.value.as_value_id().unwrap().to_string();
            capture.lock().unwrap().push((id.clone(), value.clone()));
            let (model, effort) = if id == "model" { (value.as_str(), "low") } else { ("provider/b", value.as_str()) };
            responder.respond(acp::SetSessionConfigOptionResponse::new(options(model, effort)))
        }, agent_client_protocol::on_receive_request!())
        .on_receive_request(async move |r: acp::SetSessionModeRequest, responder, _| {
            mode_capture.lock().unwrap().push(("mode".into(), r.mode_id.to_string()));
            responder.respond(acp::SetSessionModeResponse::default())
        }, agent_client_protocol::on_receive_request!())
        .on_receive_notification(async move |_r: acp::CancelNotification, _| {
            cancel_request.notify_one();
            Ok(())
        }, agent_client_protocol::on_receive_notification!())
        .on_receive_request(async move |r: acp::PromptRequest, responder, connection: ConnectionTo<agent_client_protocol::Client>| {
            let cancel = cancel.clone();
            tokio::spawn(async move {
                let text = r.prompt.iter().filter_map(|part| match part {
                    acp::ContentBlock::Text(t) => Some(t.text.as_str()), _ => None,
                }).collect::<Vec<_>>().join(" ");
                let waiting = text.contains("wait for cancellation");
                if text.contains("ask permission") {
                    let permission = connection.send_request(acp::RequestPermissionRequest::new(
                        r.session_id.clone(),
                        acp::ToolCallUpdate::new("call_shell", acp::ToolCallUpdateFields::new().title("Run echo").raw_input(serde_json::json!({"command":"echo proof"}))),
                        vec![acp::PermissionOption::new("once", "Allow once", acp::PermissionOptionKind::AllowOnce)],
                    )).block_task().await?;
                    assert!(matches!(permission.outcome, acp::RequestPermissionOutcome::Selected(s) if s.option_id.to_string() == "once"));
                }
                if text.contains("ask question") {
                    let schema = acp::ElicitationSchema::new().property("pm",
                        acp::StringPropertySchema::new().one_of(vec![acp::EnumOption::new("bun", "Bun"), acp::EnumOption::new("npm", "npm")]), true);
                    let answer = connection.send_request(acp::CreateElicitationRequest::new(
                        acp::ElicitationFormMode::new(acp::ElicitationSessionScope::new(r.session_id.clone()), schema), "Which package manager?",
                    )).block_task().await?;
                    let acp::ElicitationAction::Accept(accepted) = answer.action else { panic!("answer rejected") };
                    assert_eq!(accepted.content.unwrap().get("pm"), Some(&acp::ElicitationContentValue::String("bun".into())));
                }
                connection.send_notification(acp::SessionNotification::new(r.session_id.clone(), acp::SessionUpdate::AgentMessageChunk(acp::ContentChunk::new(acp::ContentBlock::Text(acp::TextContent::new("hello "))))))?;
                if waiting {
                    cancel.notified().await;
                    return responder.respond(acp::PromptResponse::new(acp::StopReason::Cancelled));
                }
                connection.send_notification(acp::SessionNotification::new(r.session_id, acp::SessionUpdate::AgentMessageChunk(acp::ContentChunk::new(acp::ContentBlock::Text(acp::TextContent::new("world"))))))?;
                responder.respond(acp::PromptResponse::new(acp::StopReason::EndTurn))
            });
            Ok(())
        }, agent_client_protocol::on_receive_request!());
    let driver = Arc::new(AcpDriver::connect_transport(agent, "test").await.unwrap());
    let harness = AcpHarness::new(
        driver.clone(),
        ProviderId::new("opencode").unwrap(),
        ExecutableInfo {
            path: "opencode".into(),
            source: ExecutableSource::Path,
            version: Some("2.0.32".into()),
            sha256: None,
            other_installs: Vec::new(),
        },
        "test",
    );
    Fixture {
        harness,
        driver,
        selections,
    }
}

fn spec(mode: OpenMode) -> OpenSpec {
    OpenSpec {
        mode,
        folder: PathBuf::from("/tmp"),
        settings: Default::default(),
        instructions: None,
        title: None,
        after: None,
        output_mode: OutputMode::Detailed,
    }
}
fn input(id: &str, text: &str) -> Input {
    Input {
        id: InputId::new(id).unwrap(),
        content: InputContent::text(text),
        origin: Origin::Owner { user: UserId(1) },
        delivery: Delivery::Turn,
    }
}
async fn event(events: &mut EventStream) -> Event {
    tokio::time::timeout(Duration::from_secs(5), events.next())
        .await
        .expect("event timed out")
        .expect("stream ended")
        .event
}
async fn completed(events: &mut EventStream) -> TurnOutcome {
    loop {
        if let Event::Turn {
            phase: TurnPhase::Completed { outcome, .. },
            ..
        } = event(events).await
        {
            return outcome;
        }
    }
}
async fn text_started(events: &mut EventStream) {
    loop {
        if matches!(event(events).await, Event::Item(_)) {
            break;
        }
    }
}

#[tokio::test]
async fn bridge_v2_streams_selects_models_and_resumes_native_identity() {
    let f = fixture().await;
    assert_eq!(
        f.harness.describe().executable.version.as_deref(),
        Some("2.0.32")
    );
    let catalog = f
        .harness
        .catalog(CatalogScope {
            folder: Some("/tmp".into()),
            session: None,
        })
        .await
        .unwrap();
    assert_eq!(catalog.models.len(), 2);
    let session = f.harness.open(spec(OpenMode::Start)).await.unwrap();
    session
        .control(Op::Settings {
            scope: SettingsScope::Thread,
            change: SettingsChange {
                model: Some("provider/b".into()),
                effort: Some("high".into()),
                ..Default::default()
            },
        })
        .await
        .unwrap();
    let mut events = session.events();
    session.send(input("one", "hello")).await.unwrap();
    let mut saw_text = false;
    loop {
        match event(&mut events).await {
            Event::Item(item) => {
                if let ItemUpdate::Completed {
                    body: ItemBody::Message { text, .. },
                    ..
                } = item.update
                {
                    assert_eq!(text, "hello world");
                    saw_text = true;
                }
            }
            Event::Turn {
                phase:
                    TurnPhase::Completed {
                        outcome,
                        inputs_consumed,
                        ..
                    },
                ..
            } => {
                assert_eq!(outcome, TurnOutcome::Completed);
                assert_eq!(inputs_consumed, vec![InputId::new("one").unwrap()]);
                break;
            }
            _ => {}
        }
    }
    assert!(saw_text);
    assert_eq!(
        *f.selections.lock().unwrap(),
        vec![
            ("model".into(), "provider/b".into()),
            ("effort".into(), "high".into())
        ]
    );
    session
        .control(Op::Settings {
            scope: SettingsScope::Thread,
            change: SettingsChange {
                permission_mode: Some("plan".into()),
                ..Default::default()
            },
        })
        .await
        .unwrap();
    assert_eq!(
        f.selections.lock().unwrap().last(),
        Some(&("mode".into(), "plan".into()))
    );
    session
        .control(Op::Settings {
            scope: SettingsScope::Thread,
            change: SettingsChange {
                permission_mode: Some("build".into()),
                ..Default::default()
            },
        })
        .await
        .unwrap();
    assert_eq!(
        f.selections.lock().unwrap().last(),
        Some(&("mode".into(), "build".into()))
    );
    session.release().await.unwrap();
    assert!(session.send(input("released", "no")).await.is_err());
    let resumed = f
        .harness
        .open(spec(OpenMode::Resume {
            session: session.key().session.clone(),
        }))
        .await
        .unwrap();
    assert_eq!(resumed.key(), session.key());
    f.driver.shutdown().await.unwrap();
}

#[tokio::test]
async fn bridge_v2_permission_and_question_answers_round_trip() {
    let f = fixture().await;
    let session = f.harness.open(spec(OpenMode::Start)).await.unwrap();
    let mut events = session.events();
    session
        .send(input("interactions", "ask permission and ask question"))
        .await
        .unwrap();
    let mut answered = 0;
    loop {
        match event(&mut events).await {
            Event::Interaction(interaction) => {
                let response = match interaction.kind {
                    InteractionKind::Approval { decisions, .. } => InteractionResponse::Decision {
                        decision: decisions[0].id.clone(),
                        message: None,
                    },
                    InteractionKind::Question { form } => InteractionResponse::Answers {
                        answers: vec![FieldAnswer {
                            field: form.fields[0].id.clone(),
                            values: vec!["Bun".into()],
                        }],
                    },
                    other => panic!("unexpected interaction {other:?}"),
                };
                session
                    .control(Op::Answer {
                        interaction: interaction.id,
                        response,
                        by: UserId(1),
                    })
                    .await
                    .unwrap();
                answered += 1;
            }
            Event::Turn {
                phase: TurnPhase::Completed { outcome, .. },
                ..
            } => {
                assert_eq!(outcome, TurnOutcome::Completed);
                break;
            }
            _ => {}
        }
    }
    assert_eq!(answered, 2);
    assert!(session.live_work().is_idle());
    f.driver.shutdown().await.unwrap();
}

#[tokio::test]
async fn bridge_v2_cancel_is_a_barrier_and_does_not_end_the_next_turn() {
    let f = fixture().await;
    let session = f.harness.open(spec(OpenMode::Start)).await.unwrap();
    let mut events = session.events();
    let (first, second) = tokio::join!(
        session.send(input("one", "wait for cancellation")),
        session.send(input("two", "wait for cancellation"))
    );
    assert!(first.is_ok());
    assert!(matches!(second, Err(SendError::Busy { .. })));
    text_started(&mut events).await;
    session
        .control(Op::Interrupt {
            cancel_queued: false,
        })
        .await
        .unwrap();
    assert_eq!(completed(&mut events).await, TurnOutcome::Interrupted);
    assert!(session.live_work().is_idle());
    session.send(input("three", "hello again")).await.unwrap();
    assert_eq!(completed(&mut events).await, TurnOutcome::Completed);
    session
        .control(Op::Interrupt {
            cancel_queued: false,
        })
        .await
        .unwrap();
    f.driver.shutdown().await.unwrap();
}

#[tokio::test]
async fn bridge_v2_reports_process_loss_and_rejects_unavailable_deliveries() {
    let f = fixture().await;
    let session = f.harness.open(spec(OpenMode::Start)).await.unwrap();
    let mut queued = input("queue", "hello");
    queued.delivery = Delivery::Queue;
    assert!(matches!(
        session.send(queued).await,
        Err(SendError::Unavailable(_))
    ));
    let mut events = session.events();
    session
        .send(input("live", "wait for cancellation"))
        .await
        .unwrap();
    text_started(&mut events).await;
    f.driver.shutdown().await.unwrap();
    assert_eq!(completed(&mut events).await, TurnOutcome::ConnectionLost);
    assert!(session.live_work().is_idle());
}

#[tokio::test]
async fn catalog_retains_commands_delivered_before_new_session_response() {
    let f = fixture().await;
    let catalog = f
        .harness
        .catalog(CatalogScope {
            folder: Some(PathBuf::from("/workspace")),
            session: None,
        })
        .await
        .unwrap();
    assert!(
        catalog
            .commands
            .iter()
            .any(|command| command.name == "fixture-command")
    );
    f.driver.shutdown().await.unwrap();
}
