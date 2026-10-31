//! Exercise the bridge v2 adapter over real ACP request/notification dispatch.
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
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
    closed: Arc<Mutex<Vec<String>>>,
    prompts: Arc<Mutex<Vec<Vec<acp::ContentBlock>>>>,
    new_sessions: Arc<AtomicUsize>,
}

async fn fixture() -> Fixture {
    let selections = Arc::new(Mutex::new(Vec::new()));
    let closed = Arc::new(Mutex::new(Vec::new()));
    let close_capture = closed.clone();
    let prompts = Arc::new(Mutex::new(Vec::new()));
    let prompt_capture = prompts.clone();
    let new_sessions = Arc::new(AtomicUsize::new(0));
    let new_session_capture = new_sessions.clone();
    let capture = selections.clone();
    let mode_capture = selections.clone();
    let cancel = Arc::new(Notify::new());
    let cancel_request = cancel.clone();
    let agent = Agent.builder()
        .on_receive_request(async |r: acp::InitializeRequest, responder, _| {
            responder.respond(acp::InitializeResponse::new(r.protocol_version)
                .agent_info(acp::Implementation::new("opencode", "2.0.32"))
                .agent_capabilities(acp::AgentCapabilities::new().session_capabilities(
                    acp::SessionCapabilities::new()
                        .resume(acp::SessionResumeCapabilities::new())
                        .list(acp::SessionListCapabilities::new())
                        .close(acp::SessionCloseCapabilities::new())
                        .fork(acp::SessionForkCapabilities::new()))))
        }, agent_client_protocol::on_receive_request!())
        .on_receive_request(async move |_r: acp::NewSessionRequest, responder, connection: ConnectionTo<agent_client_protocol::Client>| {
            new_session_capture.fetch_add(1, Ordering::SeqCst);
            connection.send_notification(acp::SessionNotification::new("ses_fixture", acp::SessionUpdate::AvailableCommandsUpdate(acp::AvailableCommandsUpdate::new(vec![acp::AvailableCommand::new("fixture-command", "Fixture command")]))))?;
            responder.respond(acp::NewSessionResponse::new("ses_fixture").config_options(options("provider/a", "low")))
        }, agent_client_protocol::on_receive_request!())
        .on_receive_request(async |_r: acp::ListSessionsRequest, responder, _| {
            responder.respond(acp::ListSessionsResponse::new(vec![
                acp::SessionInfo::new("ses_named", "/tmp/project")
                    .title("Fix the build".to_string())
                    .updated_at("2026-10-31T15:13:22.112Z".to_string()),
                acp::SessionInfo::new("ses_probe", "/tmp/project")
                    .title("New session - 2026-10-31T15:13:22.112Z".to_string()),
            ]).next_cursor("page-2".to_string()))
        }, agent_client_protocol::on_receive_request!())
        .on_receive_request(async move |r: acp::CloseSessionRequest, responder, _| {
            close_capture.lock().unwrap().push(r.session_id.to_string());
            responder.respond(acp::CloseSessionResponse::new())
        }, agent_client_protocol::on_receive_request!())
        .on_receive_request(async |r: acp::ForkSessionRequest, responder, _| {
            assert_eq!(r.session_id.to_string(), "ses_fixture");
            responder.respond(acp::ForkSessionResponse::new("ses_forked").config_options(options("provider/a", "low")))
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
            let prompt_capture = prompt_capture.clone();
            tokio::spawn(async move {
                let text = r.prompt.iter().filter_map(|part| match part {
                    acp::ContentBlock::Text(t) => Some(t.text.as_str()), _ => None,
                }).collect::<Vec<_>>().join(" ");
                prompt_capture.lock().unwrap().push(r.prompt.clone());
                let waiting = text.contains("wait for cancellation");
                if text.contains("tool presentation") {
                    for call in [
                        acp::ToolCall::new("shell", "shell_command: ls -la").kind(acp::ToolKind::Other)
                            .raw_input(serde_json::json!({ "command": "ls -la", "workdir": "/tmp" })),
                        acp::ToolCall::new("without-args", "Running command").kind(acp::ToolKind::Execute),
                        acp::ToolCall::new("generic", "inspect_project: private payload").kind(acp::ToolKind::Other),
                    ] {
                        let id = call.tool_call_id.clone();
                        connection.send_notification(acp::SessionNotification::new(r.session_id.clone(),
                            acp::SessionUpdate::ToolCall(call)))?;
                        connection.send_notification(acp::SessionNotification::new(r.session_id.clone(),
                            acp::SessionUpdate::ToolCallUpdate(acp::ToolCallUpdate::new(id,
                                acp::ToolCallUpdateFields::new().status(acp::ToolCallStatus::Completed)))))?;
                    }
                }
                if text.contains("rich stream") {
                    let send = |update: acp::SessionUpdate| connection.send_notification(acp::SessionNotification::new(r.session_id.clone(), update));
                    send(acp::SessionUpdate::AgentThoughtChunk(acp::ContentChunk::new(acp::ContentBlock::Text(acp::TextContent::new("weighing it"))).message_id(acp::MessageId::new("m1:reasoning:0"))))?;
                    send(acp::SessionUpdate::AgentMessageChunk(acp::ContentChunk::new(acp::ContentBlock::Text(acp::TextContent::new("Looking first.")))))?;
                    send(acp::SessionUpdate::ToolCall(acp::ToolCall::new("read-1", "read").kind(acp::ToolKind::Read).status(acp::ToolCallStatus::InProgress)
                        .raw_input(serde_json::json!({"path": "/tmp/project/a.rs"}))))?;
                    send(acp::SessionUpdate::ToolCallUpdate(acp::ToolCallUpdate::new("read-1", acp::ToolCallUpdateFields::new().status(acp::ToolCallStatus::Completed))))?;
                    send(acp::SessionUpdate::ToolCall(acp::ToolCall::new("edit-1", "edit").kind(acp::ToolKind::Edit).status(acp::ToolCallStatus::InProgress)
                        .raw_input(serde_json::json!({"path": "/tmp/project/a.rs", "oldString": "x", "newString": "y"}))
                        .locations(vec![acp::ToolCallLocation::new("/tmp/project/a.rs")])))?;
                    send(acp::SessionUpdate::ToolCallUpdate(acp::ToolCallUpdate::new("edit-1", acp::ToolCallUpdateFields::new().status(acp::ToolCallStatus::Completed))))?;
                    send(acp::SessionUpdate::ToolCall(acp::ToolCall::new("shell-1", "shell").kind(acp::ToolKind::Execute).status(acp::ToolCallStatus::InProgress)
                        .raw_input(serde_json::json!({"command": "false", "cwd": "/tmp/project"}))))?;
                    send(acp::SessionUpdate::ToolCallUpdate(acp::ToolCallUpdate::new("shell-1", acp::ToolCallUpdateFields::new().status(acp::ToolCallStatus::Completed)
                        .content(vec![acp::ToolCallContent::from("Exited with code 1")])
                        .raw_output(serde_json::json!({"metadata": {"exit": 1}})))))?;
                    send(acp::SessionUpdate::UsageUpdate(acp::UsageUpdate::new(10_146, 262_144)))?;
                    send(acp::SessionUpdate::SessionInfoUpdate(acp::SessionInfoUpdate::new().title("Agent chosen title".to_string())))?;
                    for status in ["started", "completed"] {
                        send(acp::SessionUpdate::SessionInfoUpdate(acp::SessionInfoUpdate::new().meta(serde_json::Map::from_iter([(
                            "opencode/compaction".to_string(),
                            serde_json::json!({"status": status, "messageId": "msg_1", "reason": "manual"}),
                        )]))))?;
                    }
                    let child = |extra: serde_json::Value| {
                        let mut params = serde_json::json!({
                            "rootSessionId": r.session_id.to_string(),
                            "childSessionId": "ses_child",
                            "parentSessionId": r.session_id.to_string(),
                            "depth": 1,
                            "title": "Run echo hi",
                        });
                        params.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
                        connection.send_notification(agent_client_protocol::UntypedMessage::new("opencode/session/child_update", params).unwrap())
                    };
                    child(serde_json::json!({"type": "status", "status": "created"}))?;
                    child(serde_json::json!({"type": "update", "update": {
                        "sessionUpdate": "tool_call", "toolCallId": "ses_child:call_1", "title": "Run echo hi: echo hi",
                        "kind": "execute", "status": "in_progress", "rawInput": {"command": "echo hi"},
                    }}))?;
                    child(serde_json::json!({"type": "update", "update": {
                        "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hi back"},
                    }}))?;
                    child(serde_json::json!({"type": "status", "status": "completed"}))?;
                }
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
                responder.respond(acp::PromptResponse::new(acp::StopReason::EndTurn).usage(acp::Usage::new(120, 100, 20)))
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
        closed,
        prompts,
        new_sessions,
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
async fn repeated_catalog_reads_reuse_the_folder_session() {
    let f = fixture().await;
    for _ in 0..3 {
        f.harness
            .catalog(CatalogScope {
                folder: Some("/tmp".into()),
                session: None,
            })
            .await
            .unwrap();
    }
    assert_eq!(f.new_sessions.load(Ordering::SeqCst), 1);
    let session = f.harness.open(spec(OpenMode::Start)).await.unwrap();
    let opened = f.new_sessions.load(Ordering::SeqCst);
    f.harness
        .catalog(CatalogScope {
            folder: Some("/tmp".into()),
            session: Some(session.key().session.clone()),
        })
        .await
        .unwrap();
    assert_eq!(f.new_sessions.load(Ordering::SeqCst), opened);
    f.driver.shutdown().await.unwrap();
}

#[tokio::test]
async fn guide_is_sent_once_and_not_prepended_to_native_commands_or_resume() {
    let f = fixture().await;
    let mut start = spec(OpenMode::Start);
    start.instructions = Some("unique trusted guide".into());
    let session = f.harness.open(start).await.unwrap();
    let mut events = session.events();
    let mut command = input("command", "/fixture-command");
    command.content.context = Some(inline_agent_bridge::TurnContext {
        instructions: "untrusted context instructions".into(),
        conversation: "passive conversation".into(),
    });
    session.send(command).await.unwrap();
    assert_eq!(completed(&mut events).await, TurnOutcome::Completed);
    let mut resume = spec(OpenMode::Resume {
        session: session.key().session.clone(),
    });
    resume.instructions = Some("unique trusted guide".into());
    session.release().await.unwrap();
    let resumed = f.harness.open(resume).await.unwrap();
    let mut events = resumed.events();
    resumed.send(input("resumed", "continue")).await.unwrap();
    assert_eq!(completed(&mut events).await, TurnOutcome::Completed);
    resumed
        .send(input("resumed-again", "continue again"))
        .await
        .unwrap();
    assert_eq!(completed(&mut events).await, TurnOutcome::Completed);
    let prompts = f.prompts.lock().unwrap().clone();
    assert!(
        matches!(&prompts[0][0], acp::ContentBlock::Text(text) if text.text == "/fixture-command")
    );
    let initial_context = prompt_text(&prompts[0][1..]);
    assert_eq!(initial_context.matches("unique trusted guide").count(), 1);
    assert!(initial_context.contains("passive conversation"));
    assert!(!prompt_text(&prompts[1]).contains("unique trusted guide"));
    assert!(!prompt_text(&prompts[2]).contains("unique trusted guide"));
    f.driver.shutdown().await.unwrap();
}

#[tokio::test]
async fn unknown_slash_text_keeps_guide_and_conversation_context() {
    let f = fixture().await;
    let mut start = spec(OpenMode::Start);
    start.instructions = Some("unique trusted guide".into());
    let session = f.harness.open(start).await.unwrap();
    let mut events = session.events();
    let mut input = input("unknown", "/not-a-command");
    input.content.context = Some(inline_agent_bridge::TurnContext {
        instructions: String::new(),
        conversation: "passive conversation".into(),
    });
    session.send(input).await.unwrap();
    assert_eq!(completed(&mut events).await, TurnOutcome::Completed);
    let prompts = f.prompts.lock().unwrap().clone();
    assert_eq!(
        prompts[0].len(),
        1,
        "ordinary prompts retain merged context compatibility"
    );
    let text = prompt_text(&prompts[0]);
    assert!(text.contains("unique trusted guide"));
    assert!(text.contains("passive conversation"));
    assert!(text.contains("/not-a-command"));
    f.driver.shutdown().await.unwrap();
}

fn prompt_text(blocks: &[acp::ContentBlock]) -> String {
    blocks
        .iter()
        .filter_map(|block| match block {
            acp::ContentBlock::Text(text) => Some(text.text.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[tokio::test]
async fn tool_progress_retains_real_commands_without_fabricating_arguments() {
    let f = fixture().await;
    let session = f.harness.open(spec(OpenMode::Start)).await.unwrap();
    let mut events = session.events();
    session
        .send(input("tools", "tool presentation"))
        .await
        .unwrap();
    let mut commands = Vec::new();
    let mut tools = Vec::new();
    loop {
        match event(&mut events).await {
            Event::Item(item) => {
                if let ItemUpdate::Completed { body, .. } = item.update {
                    match body {
                        ItemBody::Command { command, .. } => commands.push(command),
                        ItemBody::Tool { name, input, .. } => tools.push((name, input)),
                        _ => {}
                    }
                }
            }
            Event::Turn {
                phase: TurnPhase::Completed { .. },
                ..
            } => break,
            _ => {}
        }
    }
    assert_eq!(commands, ["ls -la"]);
    assert_eq!(tools.len(), 2);
    assert!(
        tools
            .iter()
            .any(|(name, input)| name == "Running command" && input.is_null())
    );
    assert!(
        tools
            .iter()
            .any(|(name, input)| name == "inspect_project" && input.is_null())
    );
    f.driver.shutdown().await.unwrap();
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

async fn collect_until_turn_end(events: &mut EventStream) -> Vec<Event> {
    let mut seen = Vec::new();
    loop {
        let next = event(events).await;
        let done = matches!(
            &next,
            Event::Turn {
                phase: TurnPhase::Completed { .. },
                ..
            }
        );
        seen.push(next);
        if done {
            // Session facts travel beside the turn stream; let them land.
            while let Ok(Some(late)) =
                tokio::time::timeout(Duration::from_millis(100), events.next()).await
            {
                seen.push(late.event);
            }
            return seen;
        }
    }
}

fn completed_bodies(events: &[Event]) -> Vec<(&ItemBody, &Item)> {
    events
        .iter()
        .filter_map(|event| match event {
            Event::Item(item) => match &item.update {
                ItemUpdate::Completed { body, .. } => Some((body, item)),
                _ => None,
            },
            _ => None,
        })
        .collect()
}

#[tokio::test]
async fn a_turn_reports_what_native_harnesses_report() {
    let f = fixture().await;
    let session = f.harness.open(spec(OpenMode::Start)).await.unwrap();
    let mut events = session.events();
    session.send(input("rich", "rich stream")).await.unwrap();
    let seen = collect_until_turn_end(&mut events).await;
    let completed = completed_bodies(&seen);

    assert!(completed.iter().any(|(body, _)| matches!(body,
        ItemBody::Reasoning { summary, .. } if summary == &["weighing it".to_string()])));
    // Text before a tool is its own message, so only the last one is the answer.
    let messages: Vec<&str> = completed
        .iter()
        .filter(|(_, item)| item.parent.is_none())
        .filter_map(|(body, _)| match body {
            ItemBody::Message { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(messages, ["Looking first.", "hello world"]);
    assert!(completed.iter().any(|(body, _)| matches!(body,
        ItemBody::Command { actions, .. } if matches!(actions.as_slice(),
            [CommandAction::Read { path }] if path == "/tmp/project/a.rs"))));
    assert!(completed.iter().any(|(body, _)| matches!(body,
        ItemBody::FileChange { changes } if changes.len() == 1
            && changes[0].diff.as_deref() == Some("@@ -1,1 +1,1 @@\n-x\n+y\n"))));
    assert!(completed.iter().any(|(body, _)| matches!(body,
        ItemBody::Command { command, exit_code: Some(1), output: Some(output), cwd: Some(_), .. }
            if command == "false" && output == "Exited with code 1")));

    assert!(
        seen.iter()
            .any(|event| matches!(event, Event::Usage { usage }
        if usage.last.is_some_and(|last| last.total == 10_146)
            && usage.context_window == Some(262_144)))
    );
    assert!(
        seen.iter()
            .any(|event| matches!(event, Event::Usage { usage }
        if usage.total.is_some_and(|total| total.total == 120 && total.output == 20)))
    );
    assert!(
        seen.iter()
            .any(|event| matches!(event, Event::Renamed { title }
        if title == "Agent chosen title"))
    );
    assert!(completed.iter().any(|(body, _)| matches!(body,
        ItemBody::Usage { label } if label == "Context compacted")));
    assert!(
        seen.iter()
            .any(|event| matches!(event, Event::Settings { effective }
        if effective.mode.as_deref() == Some("build")))
    );

    // The child nests, without the title prefix OpenCode puts on its tools.
    assert!(
        seen.iter()
            .any(|event| matches!(event, Event::Child { update }
        if update.status == ChildStatus::Started && update.child.id.as_str() == "ses_child"))
    );
    assert!(completed.iter().any(|(body, item)| matches!(body,
        ItemBody::Child { prompt: Some(prompt), .. } if prompt == "Run echo hi")
        && item.parent.is_none()));
    assert!(completed.iter().any(|(body, item)| {
        matches!(body,
        ItemBody::Message { text, .. } if text == "hi back")
            && item
                .parent
                .as_ref()
                .is_some_and(|child| child.id.as_str() == "ses_child")
    }));
    assert!(seen.iter().any(|event| matches!(event, Event::Item(item)
        if item.parent.is_some() && matches!(item.update.body(),
            Some(ItemBody::Command { command, .. }) if command == "echo hi"))));
    assert!(session.live_work().children.is_empty());
    f.driver.shutdown().await.unwrap();
}

#[tokio::test]
async fn compact_and_mode_are_real_operations_gated_per_session() {
    let f = fixture().await;
    let manifest = f.harness.describe().manifest.unwrap();
    assert!(manifest.availability.op(OpKind::Compact).is_supported());
    assert!(manifest.availability.op(OpKind::Mode).is_supported());
    assert!(
        !manifest
            .availability
            .delivery(DeliveryKind::SteerNext)
            .is_supported()
    );

    let session = f.harness.open(spec(OpenMode::Start)).await.unwrap();
    let matrix = session.availability();
    assert!(matrix.op(OpKind::Mode).is_supported());
    assert!(matrix.op(OpKind::Compact).is_supported());

    session
        .control(Op::Mode {
            mode: ModeId::new("plan").unwrap(),
        })
        .await
        .unwrap();
    assert_eq!(
        f.selections.lock().unwrap().last().unwrap(),
        &("mode".to_string(), "plan".to_string())
    );

    // The fixture does not advertise `compact`, so nothing is sent as a prompt.
    let refused = session.control(Op::Compact).await;
    assert!(matches!(
        refused,
        Err(OpError::Driver(
            inline_agent_bridge::DriverError::Unsupported(_)
        ))
    ));
    assert!(f.prompts.lock().unwrap().is_empty());
    f.driver.shutdown().await.unwrap();
}

#[tokio::test]
async fn sessions_fork_and_close_follow_what_the_agent_advertises() {
    let f = fixture().await;
    let page = f
        .harness
        .sessions(SessionQuery {
            folder: Some(PathBuf::from("/tmp/project")),
            ..SessionQuery::default()
        })
        .await
        .unwrap();
    assert_eq!(
        page.sessions.len(),
        1,
        "unnamed probes stay out of the list"
    );
    assert_eq!(page.sessions[0].title.as_deref(), Some("Fix the build"));
    assert_eq!(page.sessions[0].updated_at, Some(1_793_459_602));
    assert_eq!(page.next.unwrap().as_str(), "page-2");

    let forked = f
        .harness
        .open(spec(OpenMode::Fork {
            session: inline_agent_bridge::ProviderSessionId::new("ses_fixture").unwrap(),
            at: None,
        }))
        .await
        .unwrap();
    assert_eq!(forked.key().session.as_str(), "ses_forked");

    let released = forked.release().await.unwrap();
    assert_eq!(released.outcome, ReleaseOutcome::NativeReleased);
    assert_eq!(f.closed.lock().unwrap().as_slice(), ["ses_forked"]);
    f.driver.shutdown().await.unwrap();
}

#[tokio::test]
async fn approval_cards_use_the_agents_own_labels_and_subjects() {
    let f = fixture().await;
    let session = f.harness.open(spec(OpenMode::Start)).await.unwrap();
    let mut events = session.events();
    session.send(input("perm", "ask permission")).await.unwrap();
    let interaction = loop {
        if let Event::Interaction(interaction) = event(&mut events).await {
            break interaction;
        }
    };
    let InteractionKind::Approval { subject, decisions } = &interaction.kind else {
        panic!("expected an approval");
    };
    assert!(matches!(subject, ApprovalSubject::Command { command, .. } if command == "echo proof"));
    assert_eq!(decisions[0].label, "Allow once");
    assert_eq!(interaction.item.as_ref().unwrap().as_str(), "call_shell");
    session
        .control(Op::Answer {
            interaction: interaction.id.clone(),
            response: InteractionResponse::Decision {
                decision: decisions[0].id.clone(),
                message: None,
            },
            by: UserId(1),
        })
        .await
        .unwrap();
    assert!(matches!(
        completed(&mut events).await,
        TurnOutcome::Completed
    ));
    f.driver.shutdown().await.unwrap();
}
