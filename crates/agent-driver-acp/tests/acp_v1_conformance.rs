use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use agent_client_protocol::schema::{ProtocolVersion, v1 as acp};
use agent_client_protocol::{Agent, Channel, ConnectionTo};
use futures_util::StreamExt;
use inline_agent_bridge::{
    AgentDriver, AgentEvent, ApprovalDecision, ApprovalOption, DriverError, HostToolCall,
    HostToolConfiguration, HostToolFuture, HostToolHandler, HostToolResult, HostToolSpec,
    HostToolTransport, QuestionAnswer, ResumeSessionSpec, SessionReplay, SessionSpec,
    SteeringSupport, TurnInput, TurnOptions, TurnOutcome,
};
use inline_agent_driver_acp::AcpDriver;
use tokio::sync::{Notify, oneshot};

const TIMEOUT: Duration = Duration::from_secs(5);

async fn next_event(events: &mut inline_agent_bridge::AgentEventReceiver) -> AgentEvent {
    tokio::time::timeout(TIMEOUT, events.next())
        .await
        .expect("timed out waiting for normalized ACP event")
        .expect("ACP event stream closed early")
        .expect("ACP event stream returned an error")
}

#[tokio::test]
async fn initializes_v1_maps_capabilities_and_shuts_down_cleanly() {
    let initialize = Arc::new(Mutex::new(None));
    let observed_initialize = initialize.clone();
    let agent = Agent.builder().on_receive_request(
        async move |request: acp::InitializeRequest, responder, _connection| {
            *observed_initialize
                .lock()
                .expect("initialize capture poisoned") = Some(request.clone());
            responder.respond(
                acp::InitializeResponse::new(request.protocol_version).agent_capabilities(
                    acp::AgentCapabilities::new().session_capabilities(
                        acp::SessionCapabilities::new()
                            .resume(acp::SessionResumeCapabilities::new()),
                    ),
                ),
            )
        },
        agent_client_protocol::on_receive_request!(),
    );

    let driver = AcpDriver::connect_transport(agent, "9.8.7")
        .await
        .expect("connect in-process ACP agent");
    let capabilities = driver.capabilities();
    assert!(capabilities.resume_session);
    assert!(capabilities.cancel_turn);
    assert!(!capabilities.compact_session);
    assert!(capabilities.settings_catalog);
    assert_eq!(capabilities.steering, SteeringSupport::Unsupported);
    assert_eq!(capabilities.host_tools, HostToolTransport::Mcp);
    assert_eq!(
        capabilities.approvals,
        vec![
            ApprovalOption::ApproveOnce,
            ApprovalOption::ApproveForSession,
            ApprovalOption::Reject,
            ApprovalOption::CancelTurn,
        ]
    );

    let request = initialize
        .lock()
        .expect("initialize capture poisoned")
        .clone()
        .expect("initialize request was observed");
    assert_eq!(request.protocol_version, ProtocolVersion::V1);
    let client = request.client_info.expect("Inline client info");
    assert_eq!(client.name, "inline-agent-bridge");
    assert_eq!(client.version, "9.8.7");
    assert!(
        request
            .client_capabilities
            .session
            .and_then(|session| session.config_options)
            .is_some()
    );
    assert!(
        request
            .client_capabilities
            .elicitation
            .and_then(|elicitation| elicitation.form)
            .is_some()
    );

    tokio::time::timeout(TIMEOUT, driver.shutdown())
        .await
        .expect("ACP shutdown timed out")
        .expect("ACP shutdown failed");
}

#[tokio::test]
async fn claude_form_elicitation_round_trips_through_inline_questions() {
    let (response_tx, response_rx) = oneshot::channel();
    let response_tx = Arc::new(Mutex::new(Some(response_tx)));
    let observed_response = response_tx.clone();
    let agent = Agent
        .builder()
        .on_receive_request(
            async move |request: acp::InitializeRequest, responder, _connection| {
                responder.respond(acp::InitializeResponse::new(request.protocol_version))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_request: acp::NewSessionRequest, responder, _connection| {
                responder.respond(acp::NewSessionResponse::new("claude-question"))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: acp::PromptRequest,
                        responder,
                        connection: ConnectionTo<agent_client_protocol::Client>| {
                let observed_response = observed_response.clone();
                tokio::spawn(async move {
                    let custom_meta = serde_json::json!({
                        "_askUserQuestionCustomAnswer": {
                            "questionId": "question_0",
                            "isCustomAnswer": true,
                        }
                    })
                    .as_object()
                    .expect("custom answer metadata")
                    .clone();
                    let schema = acp::ElicitationSchema::new()
                        .property(
                            "question_0",
                            acp::StringPropertySchema::new()
                                .title("Target")
                                .one_of(vec![
                                    acp::EnumOption::new("core", "Core")
                                        .description("Inspect the core"),
                                    acp::EnumOption::new("cli", "CLI"),
                                ]),
                            false,
                        )
                        .property(
                            "question_0_custom",
                            acp::StringPropertySchema::new()
                                .title("Other")
                                .meta(custom_meta),
                            false,
                        );
                    let response = connection
                        .send_request(acp::CreateElicitationRequest::new(
                            acp::ElicitationFormMode::new(
                                acp::ElicitationSessionScope::new(request.session_id),
                                schema,
                            ),
                            "Which target?",
                        ))
                        .block_task()
                        .await?;
                    if let Some(sender) = observed_response
                        .lock()
                        .expect("elicitation response sender poisoned")
                        .take()
                    {
                        let _ = sender.send(response.action.clone());
                    }
                    responder.respond(acp::PromptResponse::new(acp::StopReason::EndTurn))
                });
                Ok(())
            },
            agent_client_protocol::on_receive_request!(),
        );
    let driver = AcpDriver::connect_transport(agent, "test")
        .await
        .expect("connect Claude elicitation fixture");
    let session = driver
        .start_session(SessionSpec {
            cwd: PathBuf::from("/tmp"),
        })
        .await
        .expect("new session");
    let mut turn = driver
        .start_turn(
            &session,
            TurnInput {
                text: "ask me".to_string(),
                attachments: Vec::new(),
                client_message_id: None,
            },
            TurnOptions::default(),
        )
        .await
        .expect("start turn");
    assert!(matches!(
        next_event(&mut turn.events).await,
        AgentEvent::TurnStarted { .. }
    ));
    let question = match next_event(&mut turn.events).await {
        AgentEvent::QuestionRequested(question) => question,
        event => panic!("expected question request, got {event:?}"),
    };
    assert_eq!(question.questions.len(), 1);
    assert_eq!(question.questions[0].header, "Target");
    assert_eq!(question.questions[0].prompt, "Which target?");
    assert_eq!(question.questions[0].options[0].label, "Core");
    assert!(question.questions[0].allows_other);

    driver
        .resolve_question(
            &question.request_id,
            vec![QuestionAnswer {
                question_id: "question_0".to_string(),
                answers: vec!["Core".to_string()],
            }],
        )
        .await
        .expect("resolve Claude question");
    let action = tokio::time::timeout(TIMEOUT, response_rx)
        .await
        .expect("elicitation response timed out")
        .expect("elicitation response sender dropped");
    let acp::ElicitationAction::Accept(accepted) = action else {
        panic!("expected accepted elicitation response")
    };
    assert_eq!(
        accepted
            .content
            .expect("accepted content")
            .get("question_0"),
        Some(&acp::ElicitationContentValue::String("core".to_string()))
    );
    assert!(matches!(
        next_event(&mut turn.events).await,
        AgentEvent::TurnCompleted {
            outcome: TurnOutcome::Completed,
            ..
        }
    ));
    driver
        .shutdown()
        .await
        .expect("shutdown elicitation fixture");
}

#[derive(Debug)]
struct NeverCalledHostToolHandler;

impl HostToolHandler for NeverCalledHostToolHandler {
    fn call<'a>(&'a self, _call: HostToolCall) -> HostToolFuture<'a> {
        Box::pin(async { HostToolResult::failure("not called") })
    }
}

#[tokio::test]
async fn configured_inline_tools_attach_as_one_stable_stdio_mcp_server() {
    let observed_servers = Arc::new(Mutex::new(None));
    let captured_servers = Arc::clone(&observed_servers);
    let agent = Agent
        .builder()
        .on_receive_request(
            async move |request: acp::InitializeRequest, responder, _connection| {
                responder.respond(acp::InitializeResponse::new(request.protocol_version))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: acp::NewSessionRequest, responder, _connection| {
                *captured_servers.lock().expect("MCP capture poisoned") = Some(request.mcp_servers);
                responder.respond(acp::NewSessionResponse::new("session-with-tools"))
            },
            agent_client_protocol::on_receive_request!(),
        );
    let driver = AcpDriver::connect_transport(agent, "test")
        .await
        .expect("connect ACP tool fixture");
    driver
        .configure_host_tools(HostToolConfiguration {
            specs: vec![HostToolSpec {
                name: "get_current_context".to_string(),
                description: "Get current Inline context.".to_string(),
                input_schema: serde_json::json!({
                    "type": "object",
                    "additionalProperties": false
                }),
                read_only: true,
            }],
            handler: Arc::new(NeverCalledHostToolHandler),
        })
        .expect("configure ACP tools");
    let session = driver
        .start_session(SessionSpec {
            cwd: PathBuf::from("/tmp/acp-tools"),
        })
        .await
        .expect("create ACP tool session");
    assert_eq!(session.as_str(), "session-with-tools");

    let servers = observed_servers
        .lock()
        .expect("MCP capture poisoned")
        .take()
        .expect("session/new was observed");
    assert_eq!(servers.len(), 1);
    let acp::McpServer::Stdio(server) = &servers[0] else {
        panic!("Inline tools must use stable stdio MCP")
    };
    assert_eq!(server.name, "inline");
    assert!(server.command.is_absolute());
    assert_eq!(server.args, ["bridge", "inline-tools-mcp"]);
    assert_eq!(server.env.len(), 2);
    assert!(
        server
            .env
            .iter()
            .any(|value| value.name == "INLINE_ACP_MCP_PORT")
    );
    assert!(
        server
            .env
            .iter()
            .any(|value| value.name == "INLINE_ACP_MCP_CAPABILITY" && value.value.len() == 64)
    );

    driver.shutdown().await.expect("shutdown ACP tool fixture");
}

#[tokio::test]
async fn repeated_connection_epochs_terminate_all_owned_dispatch_tasks() {
    for epoch in 0..64 {
        let agent = Agent.builder().on_receive_request(
            async move |request: acp::InitializeRequest, responder, _connection| {
                responder.respond(acp::InitializeResponse::new(request.protocol_version))
            },
            agent_client_protocol::on_receive_request!(),
        );
        let driver = tokio::time::timeout(
            TIMEOUT,
            AcpDriver::connect_transport(agent, &format!("epoch-{epoch}")),
        )
        .await
        .expect("ACP connection leaked during initialization")
        .expect("connect repeated ACP epoch");
        tokio::time::timeout(TIMEOUT, driver.shutdown())
            .await
            .expect("ACP connection leaked during shutdown")
            .expect("shutdown repeated ACP epoch");
    }
}

#[tokio::test]
async fn creates_session_normalizes_stream_and_resolves_permission() {
    let requested_cwd = Arc::new(Mutex::new(None));
    let observed_cwd = requested_cwd.clone();
    let agent = Agent
        .builder()
        .on_receive_request(
            async move |request: acp::InitializeRequest, responder, _connection| {
                responder.respond(acp::InitializeResponse::new(request.protocol_version))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: acp::NewSessionRequest, responder, _connection| {
                *observed_cwd.lock().expect("cwd capture poisoned") = Some(request.cwd);
                responder.respond(acp::NewSessionResponse::new("session-stream"))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: acp::PromptRequest,
                        responder,
                        connection: ConnectionTo<agent_client_protocol::Client>| {
                tokio::spawn(async move {
                    assert_eq!(request.session_id.to_string(), "session-stream");
                    connection.send_notification(acp::SessionNotification::new(
                        request.session_id.clone(),
                        acp::SessionUpdate::AgentMessageChunk(acp::ContentChunk::new(
                            acp::ContentBlock::Text(acp::TextContent::new("hello ")),
                        )),
                    ))?;
                    connection.send_notification(acp::SessionNotification::new(
                        request.session_id.clone(),
                        acp::SessionUpdate::ToolCall(
                            acp::ToolCall::new("tool-1", "Editing the proof")
                                .kind(acp::ToolKind::Edit)
                                .locations(vec![acp::ToolCallLocation::new("/tmp/proof.rs")]),
                        ),
                    ))?;
                    let tool = acp::ToolCallUpdate::new(
                        "tool-1",
                        acp::ToolCallUpdateFields::new()
                            .title("Run the proof")
                            .raw_input(serde_json::json!({
                                "command": "cargo test --test proof",
                                "cwd": "/tmp/project"
                            })),
                    );
                    let permission = connection
                        .send_request(acp::RequestPermissionRequest::new(
                            request.session_id.clone(),
                            tool,
                            vec![
                                acp::PermissionOption::new(
                                    "once",
                                    "Allow once",
                                    acp::PermissionOptionKind::AllowOnce,
                                ),
                                acp::PermissionOption::new(
                                    "deny",
                                    "Deny",
                                    acp::PermissionOptionKind::RejectOnce,
                                ),
                            ],
                        ))
                        .block_task()
                        .await?;
                    assert!(matches!(
                        permission.outcome,
                        acp::RequestPermissionOutcome::Selected(selected)
                            if selected.option_id.to_string() == "once"
                    ));
                    connection.send_notification(acp::SessionNotification::new(
                        request.session_id.clone(),
                        acp::SessionUpdate::ToolCallUpdate(acp::ToolCallUpdate::new(
                            "tool-1",
                            acp::ToolCallUpdateFields::new().status(acp::ToolCallStatus::Completed),
                        )),
                    ))?;
                    connection.send_notification(acp::SessionNotification::new(
                        request.session_id,
                        acp::SessionUpdate::AgentMessageChunk(acp::ContentChunk::new(
                            acp::ContentBlock::Text(acp::TextContent::new("world")),
                        )),
                    ))?;
                    responder.respond(acp::PromptResponse::new(acp::StopReason::EndTurn))
                });
                Ok(())
            },
            agent_client_protocol::on_receive_request!(),
        );

    let driver = AcpDriver::connect_transport(agent, "test")
        .await
        .expect("connect ACP fixture");
    let cwd = PathBuf::from("/tmp/project");
    let session = driver
        .start_session(SessionSpec { cwd: cwd.clone() })
        .await
        .expect("create ACP session");
    assert_eq!(session.to_string(), "session-stream");
    assert_eq!(
        requested_cwd.lock().expect("cwd capture poisoned").as_ref(),
        Some(&cwd)
    );

    let mut turn = driver
        .start_turn(
            &session,
            TurnInput {
                text: "do it".to_string(),
                attachments: Vec::new(),
                client_message_id: Some("message-1".to_string()),
            },
            TurnOptions::default(),
        )
        .await
        .expect("start ACP turn");
    let mut events = Vec::new();
    loop {
        let event = next_event(&mut turn.events).await;
        if let AgentEvent::ApprovalRequested(request) = &event {
            assert_eq!(request.summary, "Use an agent tool");
            assert_eq!(request.command.as_deref(), Some("cargo test --test proof"));
            assert_eq!(request.cwd, None);
            assert_eq!(
                request.options,
                vec![
                    ApprovalOption::ApproveOnce,
                    ApprovalOption::Reject,
                    ApprovalOption::CancelTurn,
                ]
            );
            driver
                .resolve_approval(&request.approval_id, ApprovalDecision::ApproveOnce)
                .await
                .expect("resolve ACP permission request");
        }
        let finished = matches!(event, AgentEvent::TurnCompleted { .. });
        events.push(event);
        if finished {
            break;
        }
    }

    assert!(matches!(
        events.first(),
        Some(AgentEvent::TurnStarted { .. })
    ));
    assert!(events.iter().any(|event| matches!(
        event,
        AgentEvent::AgentTextDelta { text, .. } if text == "hello "
    )));
    assert!(events.iter().any(|event| matches!(
        event,
        AgentEvent::ActivityUpsert { activity, .. }
            if activity.title == "Updating files"
    )));
    assert!(events.iter().any(|event| matches!(
        event,
        AgentEvent::FilesChanged { files, .. }
            if files.iter().any(|file| file.path == std::path::Path::new("/tmp/proof.rs"))
    )));
    assert!(events.iter().any(|event| matches!(
        event,
        AgentEvent::AgentTextCompleted { text, .. } if text == "hello world"
    )));
    assert!(matches!(
        events.last(),
        Some(AgentEvent::TurnCompleted {
            outcome: TurnOutcome::Completed,
            error: None,
            ..
        })
    ));
    driver.shutdown().await.expect("shutdown ACP fixture");
}

fn config_options(model: &str, reasoning: &str) -> Vec<acp::SessionConfigOption> {
    vec![
        acp::SessionConfigOption::select(
            "mode",
            "Mode",
            "default",
            vec![
                acp::SessionConfigSelectOption::new("default", "Manual"),
                acp::SessionConfigSelectOption::new("acceptEdits", "Accept edits"),
                acp::SessionConfigSelectOption::new("plan", "Plan"),
                acp::SessionConfigSelectOption::new("auto", "Auto"),
                acp::SessionConfigSelectOption::new("bypassPermissions", "Bypass permissions"),
            ],
        )
        .category(acp::SessionConfigOptionCategory::Mode),
        acp::SessionConfigOption::select(
            "model",
            "Model",
            model.to_string(),
            vec![
                acp::SessionConfigSelectOption::new("model-a", "Model A"),
                acp::SessionConfigSelectOption::new("model-b", "Model B"),
            ],
        )
        .category(acp::SessionConfigOptionCategory::Model),
        acp::SessionConfigOption::select(
            "reasoning",
            "Reasoning",
            reasoning.to_string(),
            vec![
                acp::SessionConfigSelectOption::new("low", "Low"),
                acp::SessionConfigSelectOption::new("high", "High"),
            ],
        )
        .category(acp::SessionConfigOptionCategory::ThoughtLevel),
        acp::SessionConfigOption::boolean("fast", "Fast mode", false)
            .category(acp::SessionConfigOptionCategory::ModelConfig),
        acp::SessionConfigOption::select(
            "agent",
            "Agent",
            "default",
            vec![
                acp::SessionConfigSelectOption::new("default", "Default"),
                acp::SessionConfigSelectOption::new("reviewer", "Reviewer"),
            ],
        ),
    ]
}

fn session_modes(current: &str) -> acp::SessionModeState {
    acp::SessionModeState::new(
        current.to_string(),
        vec![
            acp::SessionMode::new("default", "Manual"),
            acp::SessionMode::new("acceptEdits", "Accept edits"),
            acp::SessionMode::new("plan", "Plan"),
            acp::SessionMode::new("auto", "Auto"),
            acp::SessionMode::new("bypassPermissions", "Bypass Permissions"),
        ],
    )
}

#[tokio::test]
async fn prewarms_claude_shaped_settings_and_applies_supported_selections() {
    let new_session_count = Arc::new(AtomicUsize::new(0));
    let observed_new_session_count = new_session_count.clone();
    let selections = Arc::new(Mutex::new(Vec::new()));
    let observed_selections = selections.clone();
    let mode_selections = Arc::new(Mutex::new(Vec::new()));
    let observed_mode_selections = Arc::clone(&mode_selections);
    let agent = Agent
        .builder()
        .on_receive_request(
            async move |request: acp::InitializeRequest, responder, _connection| {
                responder.respond(acp::InitializeResponse::new(request.protocol_version))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_request: acp::NewSessionRequest, responder, _connection| {
                observed_new_session_count.fetch_add(1, Ordering::Relaxed);
                responder.respond(
                    acp::NewSessionResponse::new("session-settings")
                        .config_options(config_options("model-a", "low"))
                        .modes(session_modes("default")),
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: acp::SetSessionModeRequest, responder, _connection| {
                observed_mode_selections
                    .lock()
                    .expect("mode selection capture poisoned")
                    .push(request.mode_id.to_string());
                responder.respond(acp::SetSessionModeResponse::default())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: acp::SetSessionConfigOptionRequest, responder, _connection| {
                let value = request
                    .value
                    .as_value_id()
                    .expect("select value")
                    .to_string();
                let config_id = request.config_id.to_string();
                observed_selections
                    .lock()
                    .expect("selection capture poisoned")
                    .push((config_id.clone(), value.clone()));
                let (model, reasoning) = if config_id == "model" {
                    (value.as_str(), "low")
                } else {
                    ("model-b", value.as_str())
                };
                responder.respond(acp::SetSessionConfigOptionResponse::new(config_options(
                    model, reasoning,
                )))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: acp::PromptRequest, responder, _connection| {
                assert_eq!(request.session_id.to_string(), "session-settings");
                responder.respond(acp::PromptResponse::new(acp::StopReason::EndTurn))
            },
            agent_client_protocol::on_receive_request!(),
        );

    let driver = AcpDriver::connect_transport(agent, "test")
        .await
        .expect("connect ACP settings fixture");
    let cwd = PathBuf::from("/tmp/settings-project");
    let catalog = driver
        .settings_catalog(&cwd)
        .await
        .expect("load ACP settings catalog");
    assert_eq!(catalog.models.len(), 2);
    assert_eq!(catalog.models[0].value, "model-a");
    assert!(catalog.models[0].is_default);
    assert_eq!(catalog.models[0].default_reasoning.as_deref(), Some("low"));
    assert_eq!(catalog.models[0].reasoning.len(), 2);
    assert_eq!(
        catalog
            .permissions
            .iter()
            .map(|option| option.value.as_str())
            .collect::<Vec<_>>(),
        [
            "default",
            "acceptEdits",
            "plan",
            "auto",
            "bypassPermissions"
        ]
    );

    let session = driver
        .start_session(SessionSpec { cwd })
        .await
        .expect("consume prewarmed ACP session");
    assert_eq!(new_session_count.load(Ordering::Relaxed), 1);
    let mut turn = driver
        .start_turn(
            &session,
            TurnInput {
                text: "Use the selected settings".to_string(),
                attachments: Vec::new(),
                client_message_id: None,
            },
            TurnOptions {
                model: Some("model-b".to_string()),
                reasoning: Some("high".to_string()),
                permissions: Some("plan".to_string()),
                ..TurnOptions::default()
            },
        )
        .await
        .expect("start configured ACP turn");
    loop {
        if matches!(
            next_event(&mut turn.events).await,
            AgentEvent::TurnCompleted { .. }
        ) {
            break;
        }
    }
    assert_eq!(
        *selections.lock().expect("selection capture poisoned"),
        vec![
            ("model".to_string(), "model-b".to_string()),
            ("reasoning".to_string(), "high".to_string()),
        ]
    );
    assert_eq!(
        *mode_selections
            .lock()
            .expect("mode selection capture poisoned"),
        vec!["plan".to_string()]
    );
    let mut repeated = driver
        .start_turn(
            &session,
            TurnInput {
                text: "Keep the selected settings".to_string(),
                attachments: Vec::new(),
                client_message_id: None,
            },
            TurnOptions {
                permissions: Some("plan".to_string()),
                ..TurnOptions::default()
            },
        )
        .await
        .expect("start repeated configured ACP turn");
    while !matches!(
        next_event(&mut repeated.events).await,
        AgentEvent::TurnCompleted { .. }
    ) {}
    assert_eq!(
        mode_selections
            .lock()
            .expect("mode selection capture poisoned")
            .len(),
        1,
        "an already-active mode must not trigger another session/set_mode request"
    );
    driver.shutdown().await.expect("shutdown settings fixture");
}

#[tokio::test]
async fn settings_deadline_does_not_cancel_acp_session_prewarm() {
    let new_session_count = Arc::new(AtomicUsize::new(0));
    let observed_new_session_count = Arc::clone(&new_session_count);
    let release_session = Arc::new(Notify::new());
    let release_new_session = Arc::clone(&release_session);
    let (entered_tx, entered_rx) = oneshot::channel();
    let entered_tx = Arc::new(Mutex::new(Some(entered_tx)));
    let observed_entered_tx = Arc::clone(&entered_tx);
    let agent = Agent
        .builder()
        .on_receive_request(
            async move |request: acp::InitializeRequest, responder, _connection| {
                responder.respond(acp::InitializeResponse::new(request.protocol_version))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_request: acp::NewSessionRequest, responder, _connection| {
                observed_new_session_count.fetch_add(1, Ordering::Relaxed);
                if let Some(entered_tx) = observed_entered_tx
                    .lock()
                    .expect("session entry sender poisoned")
                    .take()
                {
                    let _ = entered_tx.send(());
                }
                release_new_session.notified().await;
                responder.respond(acp::NewSessionResponse::new("session-after-deadline"))
            },
            agent_client_protocol::on_receive_request!(),
        );

    let driver = AcpDriver::connect_transport(agent, "test")
        .await
        .expect("connect delayed ACP settings fixture");
    let cwd = PathBuf::from("/tmp/settings-deadline-project");
    let deadline_driver = driver.clone();
    let deadline_cwd = cwd.clone();
    let deadline = tokio::spawn(async move {
        tokio::time::timeout(
            Duration::from_millis(50),
            deadline_driver.settings_catalog(&deadline_cwd),
        )
        .await
    });
    tokio::time::timeout(TIMEOUT, entered_rx)
        .await
        .expect("settings prewarm did not reach the ACP provider")
        .expect("settings prewarm entry sender dropped");
    assert!(
        deadline
            .await
            .expect("settings deadline task panicked")
            .is_err(),
        "the presentation deadline should expire before session/new"
    );

    release_session.notify_one();
    let session = tokio::time::timeout(TIMEOUT, driver.start_session(SessionSpec { cwd }))
        .await
        .expect("background ACP prewarm did not finish")
        .expect("background ACP prewarm ended the connection epoch");
    assert_eq!(session.as_str(), "session-after-deadline");
    assert_eq!(new_session_count.load(Ordering::Relaxed), 1);
    driver
        .shutdown()
        .await
        .expect("shutdown delayed settings fixture");
}

#[tokio::test]
async fn cancellation_is_forwarded_and_completes_as_interrupted() {
    let (cancelled_tx, cancelled_rx) = oneshot::channel();
    let cancelled_tx = Arc::new(Mutex::new(Some(cancelled_tx)));
    let notify_tx = cancelled_tx.clone();
    let cancelled_rx = Arc::new(tokio::sync::Mutex::new(Some(cancelled_rx)));
    let prompt_cancelled_rx = cancelled_rx.clone();
    let agent = Agent
        .builder()
        .on_receive_request(
            async move |request: acp::InitializeRequest, responder, _connection| {
                responder.respond(acp::InitializeResponse::new(request.protocol_version))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_request: acp::NewSessionRequest, responder, _connection| {
                responder.respond(acp::NewSessionResponse::new("session-cancel"))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_notification(
            async move |notification: acp::CancelNotification, _connection| {
                assert_eq!(notification.session_id.to_string(), "session-cancel");
                if let Some(sender) = notify_tx.lock().expect("cancel sender poisoned").take() {
                    let _ = sender.send(());
                }
                Ok(())
            },
            agent_client_protocol::on_receive_notification!(),
        )
        .on_receive_request(
            async move |_request: acp::PromptRequest, responder, _connection| {
                prompt_cancelled_rx
                    .lock()
                    .await
                    .take()
                    .expect("cancel receiver")
                    .await
                    .map_err(|_| agent_client_protocol::Error::internal_error())?;
                responder.respond(acp::PromptResponse::new(acp::StopReason::Cancelled))
            },
            agent_client_protocol::on_receive_request!(),
        );

    let driver = AcpDriver::connect_transport(agent, "test")
        .await
        .expect("connect ACP fixture");
    let session = driver
        .start_session(SessionSpec {
            cwd: PathBuf::from("/tmp"),
        })
        .await
        .expect("new session");
    let mut turn = driver
        .start_turn(
            &session,
            TurnInput {
                text: "wait".to_string(),
                attachments: Vec::new(),
                client_message_id: None,
            },
            TurnOptions::default(),
        )
        .await
        .expect("start turn");
    assert!(matches!(
        next_event(&mut turn.events).await,
        AgentEvent::TurnStarted { .. }
    ));
    driver
        .cancel_turn(&session, &turn.turn_id)
        .await
        .expect("cancel active ACP turn");
    assert!(matches!(
        next_event(&mut turn.events).await,
        AgentEvent::TurnCompleted {
            outcome: TurnOutcome::Interrupted,
            error: None,
            ..
        }
    ));
    driver
        .cancel_turn(&session, &turn.turn_id)
        .await
        .expect("repeated cancellation is an idempotent terminal barrier");
    driver.shutdown().await.expect("shutdown ACP fixture");
}

#[tokio::test]
async fn resume_and_load_are_selected_only_when_advertised() {
    async fn exercise(load_only: bool) {
        let resumed = Arc::new(Mutex::new(None));
        let loaded = Arc::new(Mutex::new(None));
        let resume_capture = resumed.clone();
        let load_capture = loaded.clone();
        let capabilities = if load_only {
            acp::AgentCapabilities::new().load_session(true)
        } else {
            acp::AgentCapabilities::new().session_capabilities(
                acp::SessionCapabilities::new().resume(acp::SessionResumeCapabilities::new()),
            )
        };
        let agent = Agent
            .builder()
            .on_receive_request(
                async move |request: acp::InitializeRequest, responder, _connection| {
                    responder.respond(
                        acp::InitializeResponse::new(request.protocol_version)
                            .agent_capabilities(capabilities.clone()),
                    )
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: acp::ResumeSessionRequest,
                            responder,
                            connection: ConnectionTo<agent_client_protocol::Client>| {
                    *resume_capture.lock().expect("resume capture poisoned") =
                        Some((request.session_id.to_string(), request.mcp_servers.len()));
                    connection.send_notification(acp::SessionNotification::new(
                        request.session_id,
                        acp::SessionUpdate::AvailableCommandsUpdate(
                            acp::AvailableCommandsUpdate::new(vec![acp::AvailableCommand::new(
                                "resume_command",
                                "Available during resume",
                            )]),
                        ),
                    ))?;
                    responder.respond(acp::ResumeSessionResponse::new())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: acp::LoadSessionRequest,
                            responder,
                            connection: ConnectionTo<agent_client_protocol::Client>| {
                    *load_capture.lock().expect("load capture poisoned") =
                        Some((request.session_id.to_string(), request.mcp_servers.len()));
                    connection.send_notification(acp::SessionNotification::new(
                        request.session_id,
                        acp::SessionUpdate::AvailableCommandsUpdate(
                            acp::AvailableCommandsUpdate::new(vec![acp::AvailableCommand::new(
                                "load_command",
                                "Available during load",
                            )]),
                        ),
                    ))?;
                    responder.respond(acp::LoadSessionResponse::new())
                },
                agent_client_protocol::on_receive_request!(),
            );
        let driver = AcpDriver::connect_transport(agent, "test")
            .await
            .expect("connect ACP fixture");
        driver
            .configure_host_tools(HostToolConfiguration {
                specs: vec![HostToolSpec {
                    name: "get_current_context".to_string(),
                    description: "Get current Inline context.".to_string(),
                    input_schema: serde_json::json!({
                        "type": "object",
                        "additionalProperties": false
                    }),
                    read_only: true,
                }],
                handler: Arc::new(NeverCalledHostToolHandler),
            })
            .expect("configure resumed ACP tools");
        assert!(driver.capabilities().resume_session);
        let session_id =
            inline_agent_bridge::ProviderSessionId::new("existing-session").expect("session id");
        driver
            .resume_session(ResumeSessionSpec {
                session_id: session_id.clone(),
                cwd: PathBuf::from("/tmp/project"),
                replay: SessionReplay::None,
            })
            .await
            .expect("resume advertised ACP session");
        let commands = driver
            .session_commands(&session_id)
            .await
            .expect("replayed command catalog");
        if load_only {
            assert_eq!(
                loaded.lock().expect("load capture poisoned").as_ref(),
                Some(&("existing-session".to_string(), 1))
            );
            assert!(resumed.lock().expect("resume capture poisoned").is_none());
            assert_eq!(commands[0].name, "load_command");
        } else {
            assert_eq!(
                resumed.lock().expect("resume capture poisoned").as_ref(),
                Some(&("existing-session".to_string(), 1))
            );
            assert!(loaded.lock().expect("load capture poisoned").is_none());
            assert_eq!(commands[0].name, "resume_command");
        }
        driver.shutdown().await.expect("shutdown ACP fixture");
    }

    exercise(false).await;
    exercise(true).await;

    let agent = Agent.builder().on_receive_request(
        async move |request: acp::InitializeRequest, responder, _connection| {
            responder.respond(acp::InitializeResponse::new(request.protocol_version))
        },
        agent_client_protocol::on_receive_request!(),
    );
    let driver = AcpDriver::connect_transport(agent, "test")
        .await
        .expect("connect ACP fixture without resume support");
    assert!(!driver.capabilities().resume_session);
    let result = driver
        .resume_session(ResumeSessionSpec {
            session_id: inline_agent_bridge::ProviderSessionId::new("existing-session")
                .expect("session id"),
            cwd: PathBuf::from("/tmp/project"),
            replay: SessionReplay::None,
        })
        .await;
    assert!(matches!(
        result,
        Err(DriverError::Unsupported("ACP session resume"))
    ));
    driver.shutdown().await.expect("shutdown ACP fixture");
}

#[tokio::test]
async fn invalid_approval_choice_keeps_the_permission_request_resolvable() {
    let (outcome_tx, outcome_rx) = oneshot::channel();
    let outcome_tx = Arc::new(Mutex::new(Some(outcome_tx)));
    let observed_outcome = outcome_tx.clone();
    let agent = Agent
        .builder()
        .on_receive_request(
            async move |request: acp::InitializeRequest, responder, _connection| {
                responder.respond(acp::InitializeResponse::new(request.protocol_version))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_request: acp::NewSessionRequest, responder, _connection| {
                responder.respond(acp::NewSessionResponse::new("approval-retry"))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: acp::PromptRequest,
                        responder,
                        connection: ConnectionTo<agent_client_protocol::Client>| {
                let observed_outcome = observed_outcome.clone();
                tokio::spawn(async move {
                    let response = connection
                        .send_request(acp::RequestPermissionRequest::new(
                            request.session_id,
                            acp::ToolCallUpdate::new(
                                "tool-retry",
                                acp::ToolCallUpdateFields::new().title("Retry permission"),
                            ),
                            vec![acp::PermissionOption::new(
                                "once",
                                "Allow once",
                                acp::PermissionOptionKind::AllowOnce,
                            )],
                        ))
                        .block_task()
                        .await?;
                    if let Some(sender) = observed_outcome
                        .lock()
                        .expect("outcome sender poisoned")
                        .take()
                    {
                        let _ = sender.send(response.outcome.clone());
                    }
                    responder.respond(acp::PromptResponse::new(acp::StopReason::EndTurn))
                });
                Ok(())
            },
            agent_client_protocol::on_receive_request!(),
        );
    let driver = AcpDriver::connect_transport(agent, "test")
        .await
        .expect("connect approval fixture");
    let session = driver
        .start_session(SessionSpec {
            cwd: PathBuf::from("/tmp"),
        })
        .await
        .expect("new session");
    let mut turn = driver
        .start_turn(
            &session,
            TurnInput {
                text: "request permission".to_string(),
                attachments: Vec::new(),
                client_message_id: None,
            },
            TurnOptions::default(),
        )
        .await
        .expect("start turn");
    assert!(matches!(
        next_event(&mut turn.events).await,
        AgentEvent::TurnStarted { .. }
    ));
    let request = match next_event(&mut turn.events).await {
        AgentEvent::ApprovalRequested(request) => request,
        event => panic!("expected approval request, got {event:?}"),
    };
    let invalid = driver
        .resolve_approval(
            &request.approval_id,
            ApprovalDecision::ProviderChoice {
                option_id: "not-offered".to_string(),
            },
        )
        .await;
    assert!(matches!(invalid, Err(DriverError::Rejected(_))));
    driver
        .resolve_approval(&request.approval_id, ApprovalDecision::ApproveOnce)
        .await
        .expect("valid retry resolves the original permission request");
    assert!(matches!(
        tokio::time::timeout(TIMEOUT, outcome_rx)
            .await
            .expect("permission response timed out")
            .expect("permission outcome sender dropped"),
        acp::RequestPermissionOutcome::Selected(selected)
            if selected.option_id.to_string() == "once"
    ));
    while !matches!(
        next_event(&mut turn.events).await,
        AgentEvent::TurnCompleted { .. }
    ) {}
    driver.shutdown().await.expect("shutdown approval fixture");
}

#[tokio::test]
async fn cancel_turn_approval_responds_cancelled_and_notifies_the_agent() {
    let (outcome_tx, outcome_rx) = oneshot::channel();
    let outcome_tx = Arc::new(Mutex::new(Some(outcome_tx)));
    let observed_outcome = outcome_tx.clone();
    let (cancel_tx, cancel_rx) = oneshot::channel();
    let cancel_tx = Arc::new(Mutex::new(Some(cancel_tx)));
    let observed_cancel = cancel_tx.clone();
    let agent = Agent
        .builder()
        .on_receive_request(
            async move |request: acp::InitializeRequest, responder, _connection| {
                responder.respond(acp::InitializeResponse::new(request.protocol_version))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_request: acp::NewSessionRequest, responder, _connection| {
                responder.respond(acp::NewSessionResponse::new("approval-cancel"))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_notification(
            async move |notification: acp::CancelNotification, _connection| {
                assert_eq!(notification.session_id.to_string(), "approval-cancel");
                if let Some(sender) = observed_cancel
                    .lock()
                    .expect("cancel sender poisoned")
                    .take()
                {
                    let _ = sender.send(());
                }
                Ok(())
            },
            agent_client_protocol::on_receive_notification!(),
        )
        .on_receive_request(
            async move |request: acp::PromptRequest,
                        responder,
                        connection: ConnectionTo<agent_client_protocol::Client>| {
                let observed_outcome = observed_outcome.clone();
                tokio::spawn(async move {
                    let response = connection
                        .send_request(acp::RequestPermissionRequest::new(
                            request.session_id,
                            acp::ToolCallUpdate::new(
                                "tool-cancel",
                                acp::ToolCallUpdateFields::new().title("Cancel permission"),
                            ),
                            vec![acp::PermissionOption::new(
                                "once",
                                "Allow once",
                                acp::PermissionOptionKind::AllowOnce,
                            )],
                        ))
                        .block_task()
                        .await?;
                    if let Some(sender) = observed_outcome
                        .lock()
                        .expect("outcome sender poisoned")
                        .take()
                    {
                        let _ = sender.send(response.outcome.clone());
                    }
                    responder.respond(acp::PromptResponse::new(acp::StopReason::Cancelled))
                });
                Ok(())
            },
            agent_client_protocol::on_receive_request!(),
        );
    let driver = AcpDriver::connect_transport(agent, "test")
        .await
        .expect("connect cancel fixture");
    let session = driver
        .start_session(SessionSpec {
            cwd: PathBuf::from("/tmp"),
        })
        .await
        .expect("new session");
    let mut turn = driver
        .start_turn(
            &session,
            TurnInput {
                text: "cancel through approval".to_string(),
                attachments: Vec::new(),
                client_message_id: None,
            },
            TurnOptions::default(),
        )
        .await
        .expect("start turn");
    assert!(matches!(
        next_event(&mut turn.events).await,
        AgentEvent::TurnStarted { .. }
    ));
    let request = match next_event(&mut turn.events).await {
        AgentEvent::ApprovalRequested(request) => request,
        event => panic!("expected approval request, got {event:?}"),
    };
    driver
        .resolve_approval(&request.approval_id, ApprovalDecision::CancelTurn)
        .await
        .expect("cancel approval");
    assert!(matches!(
        tokio::time::timeout(TIMEOUT, outcome_rx)
            .await
            .expect("cancelled permission response timed out")
            .expect("permission outcome sender dropped"),
        acp::RequestPermissionOutcome::Cancelled
    ));
    tokio::time::timeout(TIMEOUT, cancel_rx)
        .await
        .expect("session/cancel notification timed out")
        .expect("cancel notification sender dropped");
    assert!(matches!(
        next_event(&mut turn.events).await,
        AgentEvent::TurnCompleted {
            outcome: TurnOutcome::Interrupted,
            ..
        }
    ));
    driver.shutdown().await.expect("shutdown cancel fixture");
}

#[tokio::test]
async fn turn_and_approval_ids_are_unique_across_driver_restarts() {
    async fn run_once() -> (String, String) {
        let agent = Agent
            .builder()
            .on_receive_request(
                async move |request: acp::InitializeRequest, responder, _connection| {
                    responder.respond(acp::InitializeResponse::new(request.protocol_version))
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: acp::NewSessionRequest, responder, _connection| {
                    responder.respond(acp::NewSessionResponse::new("restart-session"))
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: acp::PromptRequest,
                            responder,
                            connection: ConnectionTo<agent_client_protocol::Client>| {
                    tokio::spawn(async move {
                        let _permission = connection
                            .send_request(acp::RequestPermissionRequest::new(
                                request.session_id,
                                acp::ToolCallUpdate::new(
                                    "tool-id",
                                    acp::ToolCallUpdateFields::new().title("Capture ID"),
                                ),
                                vec![acp::PermissionOption::new(
                                    "once",
                                    "Allow once",
                                    acp::PermissionOptionKind::AllowOnce,
                                )],
                            ))
                            .block_task()
                            .await?;
                        responder.respond(acp::PromptResponse::new(acp::StopReason::EndTurn))
                    });
                    Ok(())
                },
                agent_client_protocol::on_receive_request!(),
            );
        let driver = AcpDriver::connect_transport(agent, "test")
            .await
            .expect("connect restart fixture");
        let session = driver
            .start_session(SessionSpec {
                cwd: PathBuf::from("/tmp"),
            })
            .await
            .expect("new session");
        let mut turn = driver
            .start_turn(
                &session,
                TurnInput {
                    text: "capture IDs".to_string(),
                    attachments: Vec::new(),
                    client_message_id: None,
                },
                TurnOptions::default(),
            )
            .await
            .expect("start turn");
        assert!(matches!(
            next_event(&mut turn.events).await,
            AgentEvent::TurnStarted { .. }
        ));
        let approval = match next_event(&mut turn.events).await {
            AgentEvent::ApprovalRequested(request) => request,
            event => panic!("expected approval request, got {event:?}"),
        };
        driver
            .resolve_approval(&approval.approval_id, ApprovalDecision::ApproveOnce)
            .await
            .expect("resolve ID fixture approval");
        while !matches!(
            next_event(&mut turn.events).await,
            AgentEvent::TurnCompleted { .. }
        ) {}
        driver.shutdown().await.expect("shutdown restart fixture");
        (turn.turn_id.to_string(), approval.approval_id)
    }

    let first = run_once().await;
    let second = run_once().await;
    assert_ne!(first.0, second.0, "turn IDs must include a process epoch");
    assert_ne!(
        first.1, second.1,
        "approval IDs must include a process epoch"
    );
}

#[tokio::test]
async fn transport_eof_fails_active_turn_and_is_observable() {
    let (driver_channel, agent_channel) = Channel::duplex();
    let (close_tx, close_rx) = oneshot::channel();
    let close_tx = Arc::new(Mutex::new(Some(close_tx)));
    let close_on_prompt = close_tx.clone();
    let held_responder: Arc<Mutex<Option<agent_client_protocol::Responder<acp::PromptResponse>>>> =
        Arc::new(Mutex::new(None));
    let prompt_responder = held_responder.clone();
    let agent = Agent
        .builder()
        .on_receive_request(
            async move |request: acp::InitializeRequest, responder, _connection| {
                responder.respond(acp::InitializeResponse::new(request.protocol_version))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_request: acp::NewSessionRequest, responder, _connection| {
                responder.respond(acp::NewSessionResponse::new("eof-session"))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_request: acp::PromptRequest, responder, _connection| {
                *prompt_responder
                    .lock()
                    .expect("prompt responder capture poisoned") = Some(responder);
                if let Some(sender) = close_on_prompt
                    .lock()
                    .expect("transport close sender poisoned")
                    .take()
                {
                    let _ = sender.send(());
                }
                Ok(())
            },
            agent_client_protocol::on_receive_request!(),
        );
    let agent_task = tokio::spawn(agent.connect_with(
        agent_channel,
        move |_connection| async move {
            let _ = close_rx.await;
            Ok(())
        },
    ));
    let driver = AcpDriver::connect_transport(driver_channel, "test")
        .await
        .expect("connect EOF fixture");
    let session = driver
        .start_session(SessionSpec {
            cwd: PathBuf::from("/tmp"),
        })
        .await
        .expect("new session");
    let mut turn = driver
        .start_turn(
            &session,
            TurnInput {
                text: "wait while transport closes".to_string(),
                attachments: Vec::new(),
                client_message_id: None,
            },
            TurnOptions::default(),
        )
        .await
        .expect("start turn");
    assert!(matches!(
        next_event(&mut turn.events).await,
        AgentEvent::TurnStarted { .. }
    ));
    assert!(matches!(
        next_event(&mut turn.events).await,
        AgentEvent::TurnCompleted {
            outcome: TurnOutcome::ConnectionLost,
            error: Some(error),
            ..
        } if error.contains("transport closed")
    ));
    let shutdown = tokio::time::timeout(TIMEOUT, driver.shutdown())
        .await
        .expect("connection status did not become observable");
    assert!(
        matches!(shutdown, Err(DriverError::ProcessExited(error)) if error.contains("transport closed"))
    );
    drop(
        held_responder
            .lock()
            .expect("prompt responder capture poisoned")
            .take(),
    );
    agent_task
        .await
        .expect("agent fixture task panicked")
        .expect("agent fixture failed");
}
