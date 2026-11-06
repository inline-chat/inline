//! A broad live lab against a real OpenCode v2 service: steering, queue,
//! interrupt, approvals, questions, Inline tools over client MCP,
//! sub-agents, commands, compact, fork, plan mode, undo, rename and the
//! side call. Model behavior varies, so model-dependent steps report what
//! happened; driver mechanics are asserted.
//!
//! Opt-in like `live_opencode.rs`:
//! `INLINE_OPENCODE_LIVE=1 cargo test -p inline-agent-driver-opencode --test live_lab -- --ignored --nocapture`

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::StreamExt;
use inline_agent_bridge::harness::*;
use inline_agent_bridge::{
    HostToolCall, HostToolConfiguration, HostToolFuture, HostToolHandler, HostToolResult,
    HostToolSpec, TurnId, TurnOutcome,
};
use inline_agent_driver_opencode::{OpenCodeHarness, OpenCodeHarnessConfig};
use serde_json::json;

const STEP_TIMEOUT: Duration = Duration::from_secs(240);

fn executable() -> PathBuf {
    std::env::var_os("INLINE_OPENCODE_EXECUTABLE")
        .map(PathBuf::from)
        .expect("INLINE_OPENCODE_EXECUTABLE")
}

#[derive(Default)]
struct Recorder(Mutex<Vec<HostToolCall>>);

impl HostToolHandler for Recorder {
    fn call<'a>(&'a self, call: HostToolCall) -> HostToolFuture<'a> {
        Box::pin(async move {
            self.0.lock().unwrap().push(call.clone());
            HostToolResult::success("Posted to the Inline thread.")
        })
    }
}

/// What one turn produced, summarized.
#[derive(Debug, Default)]
struct Outcome {
    turn: Option<TurnId>,
    outcome: Option<TurnOutcome>,
    error: Option<String>,
    consumed: Vec<InputId>,
    answer: String,
    kinds: Vec<String>,
    interactions: Vec<Interaction>,
    children: usize,
}

fn kind(event: &Event) -> String {
    match event {
        Event::Item(item) => {
            let body = item
                .update
                .body()
                .map(|body| format!("{:?}", body.kind()))
                .unwrap_or_else(|| "delta".into());
            format!(
                "item:{body}{}",
                if item.parent.is_some() { "(child)" } else { "" }
            )
        }
        Event::Turn {
            phase: TurnPhase::Started { .. },
            ..
        } => "turn:start".into(),
        Event::Turn {
            phase: TurnPhase::Completed { .. },
            ..
        } => "turn:end".into(),
        Event::Interaction(_) => "interaction".into(),
        Event::InteractionClosed { .. } => "interaction:closed".into(),
        Event::Input { .. } => "input".into(),
        Event::Queue { .. } => "queue".into(),
        Event::Settings { .. } => "settings".into(),
        Event::Usage { .. } => "usage".into(),
        Event::Child { .. } => "child".into(),
        Event::Renamed { .. } => "renamed".into(),
        Event::Notice(notice) => format!("notice:{}", notice.code),
        Event::State { .. } => "state".into(),
        Event::Held { .. } => "held".into(),
        Event::Gap { .. } => "gap".into(),
    }
}

fn input(id: &str, text: &str, delivery: Delivery) -> Input {
    Input {
        id: InputId::new(id).unwrap(),
        content: InputContent::text(text),
        origin: Origin::Owner { user: UserId(1) },
        delivery,
    }
}

/// Collects events until a turn completes, answering interactions with `answer`.
async fn until_done(
    session: &dyn Session,
    events: &mut EventStream,
    mut answer: impl FnMut(&Interaction) -> Option<InteractionResponse>,
) -> Outcome {
    let mut out = Outcome::default();
    let mut deltas = 0usize;
    let finished = tokio::time::timeout(STEP_TIMEOUT, async {
        while let Some(envelope) = events.next().await {
            let event = envelope.event;
            let name = kind(&event);
            if name == "item:delta" {
                deltas += 1;
            } else if out.kinds.last() != Some(&name) {
                out.kinds.push(name);
            }
            match &event {
                Event::Interaction(interaction) => {
                    out.interactions.push(interaction.clone());
                    let response = answer(interaction).unwrap_or(InteractionResponse::Cancel);
                    if let Err(error) = session
                        .control(Op::Answer {
                            interaction: interaction.id.clone(),
                            response,
                            by: UserId(1),
                        })
                        .await
                    {
                        eprintln!("  answer failed: {error}");
                    }
                }
                Event::Child { .. } => out.children += 1,
                Event::Input {
                    id,
                    fact: InputFact::Consumed { .. },
                } => out.consumed.push(id.clone()),
                Event::Item(Item {
                    update:
                        ItemUpdate::Completed {
                            body:
                                ItemBody::Message {
                                    role: MessageRole::Assistant,
                                    text,
                                    ..
                                },
                            ..
                        },
                    parent: None,
                    ..
                }) => out.answer = text.clone(),
                Event::Turn {
                    turn,
                    phase: TurnPhase::Started { .. },
                } if out.turn.is_none() => out.turn = Some(turn.clone()),
                Event::Turn {
                    phase:
                        TurnPhase::Completed {
                            outcome,
                            error,
                            inputs_consumed,
                            ..
                        },
                    ..
                } => {
                    out.outcome = Some(*outcome);
                    out.error = error.clone();
                    for id in inputs_consumed {
                        if !out.consumed.contains(id) {
                            out.consumed.push(id.clone());
                        }
                    }
                    return;
                }
                _ => {}
            }
        }
    })
    .await;
    if finished.is_err() {
        out.error = Some("timed out".into());
    }
    eprintln!("  events: {} (+{deltas} deltas)", out.kinds.join(" "));
    out
}

fn spec(folder: &std::path::Path, mode: OpenMode, permission: Option<&str>) -> OpenSpec {
    OpenSpec {
        mode,
        folder: folder.to_path_buf(),
        settings: SettingsChange {
            model: std::env::var("INLINE_OPENCODE_MODEL").ok(),
            permission_mode: permission.map(str::to_owned),
            ..Default::default()
        },
        instructions: Some("You are Inline's test agent. Keep answers to one short sentence unless asked otherwise.".into()),
        title: Some("Inline live lab".into()),
        after: None,
        output_mode: OutputMode::Detailed,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "needs a real OpenCode v2; set INLINE_OPENCODE_LIVE=1"]
async fn live_lab() {
    if std::env::var("INLINE_OPENCODE_LIVE").as_deref() != Ok("1") {
        return;
    }
    let folder = tempfile::tempdir().unwrap();
    let folder = folder.path().canonicalize().unwrap();
    std::fs::write(folder.join("notes.txt"), "alpha\n").unwrap();
    let recorder = Arc::new(Recorder::default());
    let mut config = OpenCodeHarnessConfig::new(executable(), "live-lab");
    config.host_tools = Some(HostToolConfiguration {
        specs: vec![HostToolSpec {
            name: "send_message".into(),
            description: "Post a short message to the Inline thread this session belongs to."
                .into(),
            input_schema: json!({"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}),
            read_only: false,
        }],
        handler: recorder.clone(),
    });
    let harness = OpenCodeHarness::new(config);
    let mut report = Vec::<String>::new();

    // Catalog on a cold folder lists OpenCode's built-in commands.
    let catalog = harness
        .catalog(CatalogScope {
            folder: Some(folder.clone()),
            session: None,
        })
        .await
        .unwrap();
    let commands: Vec<_> = catalog
        .commands
        .iter()
        .map(|command| command.name.clone())
        .collect();
    eprintln!(
        "catalog: {} models, modes {:?}, commands {commands:?}, {} skills, usage {:?}",
        catalog.models.len(),
        catalog
            .modes
            .iter()
            .map(|mode| mode.id.as_str())
            .collect::<Vec<_>>(),
        catalog.skills.len(),
        catalog.usage
    );
    assert!(commands.contains(&"init".to_owned()), "{commands:?}");

    let session = harness
        .open(spec(&folder, OpenMode::Start, Some("ask")))
        .await
        .unwrap();
    let mut events = session.events();

    // 1. Approval: a shell command under "ask first".
    eprintln!("1. approval (shell under ask)");
    session
        .send(input(
            "lab-1",
            "Run the shell command `cat notes.txt` and tell me its output.",
            Delivery::Turn,
        ))
        .await
        .unwrap();
    let out = until_done(
        session.as_ref(),
        &mut events,
        |interaction| match &interaction.kind {
            InteractionKind::Approval { decisions, .. } => decisions
                .iter()
                .find(|decision| decision.id.as_str() == "once")
                .map(|decision| InteractionResponse::Decision {
                    decision: decision.id.clone(),
                    message: None,
                }),
            _ => None,
        },
    )
    .await;
    report.push(format!(
        "approval: {:?} interactions={} answer={:?}",
        out.outcome,
        out.interactions.len(),
        out.answer
    ));
    assert_eq!(out.outcome, Some(TurnOutcome::Completed), "{:?}", out.error);
    assert!(out.consumed.contains(&InputId::new("lab-1").unwrap()));

    // 2. Steering mid-turn and a queued follow-up in the same execution.
    eprintln!("2. steer + queue");
    let receipt = session
        .send(input(
            "lab-2",
            "Count slowly from 1 to 30, one number per line, then say done.",
            Delivery::Turn,
        ))
        .await
        .unwrap();
    let InputDisposition::Started { turn } = receipt.disposition else {
        panic!()
    };
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let steer = session
        .send(input(
            "lab-3",
            "Actually stop at 5 and say steered.",
            Delivery::Steer {
                expected_turn: turn.clone(),
                priority: SteerPriority::Next,
            },
        ))
        .await;
    let queued = session
        .send(input("lab-4", "Then say queued.", Delivery::Queue))
        .await;
    eprintln!(
        "  steer: {:?}",
        steer.as_ref().map(|receipt| &receipt.disposition)
    );
    eprintln!(
        "  queue: {:?}",
        queued.as_ref().map(|receipt| &receipt.disposition)
    );
    eprintln!("  live queue: {:?}", session.live_work().queued);
    let out = until_done(session.as_ref(), &mut events, |_| None).await;
    report.push(format!(
        "steer/queue: {:?} turn={:?} consumed={:?} answer={:?}",
        out.outcome, out.turn, out.consumed, out.answer
    ));
    assert_eq!(
        out.turn.as_ref(),
        Some(&turn),
        "the turn keeps the id its receipt named"
    );

    // 3. Interrupt with the queue cancelled.
    eprintln!("3. interrupt");
    session
        .send(input(
            "lab-5",
            "Write a 600 word story about a lighthouse.",
            Delivery::Turn,
        ))
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(2500)).await;
    let stopped = session
        .control(Op::Interrupt {
            cancel_queued: true,
        })
        .await;
    eprintln!("  interrupt: {stopped:?}");
    let out = until_done(session.as_ref(), &mut events, |_| None).await;
    report.push(format!(
        "interrupt: {:?} error={:?}",
        out.outcome, out.error
    ));
    assert!(
        matches!(
            out.outcome,
            Some(TurnOutcome::Interrupted | TurnOutcome::Completed)
        ),
        "{out:?}"
    );

    // 4. Inline tools over client MCP.
    eprintln!("4. inline tool");
    session
        .send(input(
            "lab-6",
            "Use Inline's send_message tool (the `inline` MCP tool; in code mode `inline.send_message`) to post the text 'hello from opencode'. Then confirm.",
            Delivery::Turn,
        ))
        .await
        .unwrap();
    let out = until_done(session.as_ref(), &mut events, |_| None).await;
    let calls = recorder.0.lock().unwrap().clone();
    report.push(format!(
        "inline tool: {:?} calls={:?}",
        out.outcome,
        calls
            .iter()
            .map(|call| (
                call.tool_name.clone(),
                call.session_id.as_str().to_owned(),
                call.arguments.clone()
            ))
            .collect::<Vec<_>>()
    ));
    for call in &calls {
        assert_eq!(&call.session_id, &session.key().session);
    }

    // 5. Question form.
    eprintln!("5. question");
    session
        .send(input(
            "lab-7",
            "Use your question tool to ask me to choose between 'red' and 'blue', then tell me what I chose.",
            Delivery::Turn,
        ))
        .await
        .unwrap();
    let out = until_done(
        session.as_ref(),
        &mut events,
        |interaction| match &interaction.kind {
            InteractionKind::Question { form } => Some(InteractionResponse::Answers {
                answers: form
                    .fields
                    .iter()
                    .map(|field| FieldAnswer {
                        field: field.id.clone(),
                        values: match &field.input {
                            FieldInput::Select { options, .. } => options
                                .iter()
                                .find(|option| option.label.to_lowercase().contains("blue"))
                                .or(options.first())
                                .map(|option| vec![option.label.clone()])
                                .unwrap_or_default(),
                            _ => vec!["blue".into()],
                        },
                    })
                    .collect(),
            }),
            _ => None,
        },
    )
    .await;
    report.push(format!(
        "question: {:?} interactions={} answer={:?}",
        out.outcome,
        out.interactions.len(),
        out.answer
    ));

    // 6. Sub-agent.
    eprintln!("6. sub-agent");
    session
        .send(input(
            "lab-8",
            "Use the subagent tool with the explore agent to list the files in this folder, then report them.",
            Delivery::Turn,
        ))
        .await
        .unwrap();
    let out = until_done(session.as_ref(), &mut events, |_| None).await;
    report.push(format!(
        "sub-agent: {:?} child updates={} answer={:?}",
        out.outcome, out.children, out.answer
    ));

    // 7. Settings, plan mode, rename, side call.
    eprintln!("7. settings");
    let model = catalog
        .models
        .iter()
        .find(|model| !model.reasoning.is_empty());
    if let Some(model) = model {
        let changed = session
            .control(Op::Settings {
                change: SettingsChange {
                    model: Some(model.value.clone()),
                    effort: model.reasoning.first().map(|effort| effort.value.clone()),
                    ..Default::default()
                },
                scope: SettingsScope::Thread,
            })
            .await;
        report.push(format!("model+effort {}: {changed:?}", model.value));
        assert!(changed.is_ok());
    }
    let mode = session
        .control(Op::Mode {
            mode: ModeId::new("plan").unwrap(),
        })
        .await;
    let mode_back = session
        .control(Op::Mode {
            mode: ModeId::new("build").unwrap(),
        })
        .await;
    let rename = session
        .control(Op::Rename {
            title: "Inline lab renamed".into(),
        })
        .await;
    let sample = session
        .control(Op::Sample {
            prompt: "Reply with the single word ok.".into(),
        })
        .await;
    report.push(format!(
        "plan={mode:?} build={mode_back:?} rename={rename:?} sample={sample:?}"
    ));
    assert!(mode.is_ok() && mode_back.is_ok() && rename.is_ok());
    assert!(matches!(sample, Ok(OpOutcome::Sampled { .. })));

    // 8. A command through OpenCode's command API.
    eprintln!("8. command");
    let receipt = session
        .send(input("lab-9", "/review", Delivery::Turn))
        .await;
    eprintln!("  receipt: {receipt:?}");
    let out = until_done(session.as_ref(), &mut events, |_| None).await;
    report.push(format!(
        "command /review: {:?} consumed={:?}",
        out.outcome, out.consumed
    ));
    assert!(
        out.consumed.contains(&InputId::new("lab-9").unwrap()),
        "{:?}",
        out.consumed
    );

    // 9. Compact.
    eprintln!("9. compact");
    let compact = session.control(Op::Compact).await;
    eprintln!("  compact: {compact:?}");
    let out = until_done(session.as_ref(), &mut events, |_| None).await;
    report.push(format!("compact: {:?} kinds={:?}", out.outcome, out.kinds));

    // 10. Fork after the first turn, and undo the last turn.
    eprintln!("10. fork + undo");
    let first = InputId::new("lab-1").unwrap();
    let _ = first;
    let page = harness
        .sessions(SessionQuery {
            folder: Some(folder.clone()),
            ..Default::default()
        })
        .await
        .unwrap();
    report.push(format!("sessions listed: {}", page.sessions.len()));
    let fork = harness
        .open(OpenSpec {
            mode: OpenMode::Fork {
                session: session.key().session.clone(),
                at: None,
            },
            ..spec(&folder, OpenMode::Start, None)
        })
        .await;
    report.push(format!(
        "fork: {:?}",
        fork.as_ref()
            .map(|fork| fork.key().session.as_str().to_owned())
    ));
    assert!(fork.is_ok());
    let undo = session
        .control(Op::RewindFiles {
            to: RewindPoint::Input {
                input: InputId::new("lab-8").unwrap(),
            },
        })
        .await;
    report.push(format!("undo: {undo:?}"));

    eprintln!("\n==== live lab report ====");
    for line in &report {
        eprintln!("- {line}");
    }
    session.release().await.unwrap();
    harness.shutdown().await;
}

/// The service restarts under an idle held session: the driver finds it
/// again (new port and password), resyncs without replaying history, and
/// the next turn runs.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "needs a real OpenCode v2; set INLINE_OPENCODE_LIVE=1"]
async fn live_service_restart() {
    if std::env::var("INLINE_OPENCODE_LIVE").as_deref() != Ok("1") {
        return;
    }
    let folder = tempfile::tempdir().unwrap();
    let folder = folder.path().canonicalize().unwrap();
    let harness = OpenCodeHarness::new(OpenCodeHarnessConfig::new(executable(), "live-restart"));
    let session = harness
        .open(spec(&folder, OpenMode::Start, None))
        .await
        .unwrap();
    let mut events = session.events();
    session
        .send(input("restart-1", "Say one.", Delivery::Turn))
        .await
        .unwrap();
    let first = until_done(session.as_ref(), &mut events, |_| None).await;
    assert_eq!(
        first.outcome,
        Some(TurnOutcome::Completed),
        "{:?}",
        first.error
    );

    let status = std::process::Command::new(executable())
        .args(["service", "restart"])
        .status()
        .expect("restart the service");
    assert!(status.success());
    // Rediscovery happens after a few failed reconnects.
    let mut replayed = Vec::new();
    let settle = tokio::time::timeout(Duration::from_secs(25), async {
        while let Some(envelope) = events.next().await {
            replayed.push(kind(&envelope.event));
        }
    })
    .await;
    let _ = settle;
    eprintln!("after restart: {replayed:?}");
    assert!(
        !replayed.iter().any(|kind| kind.starts_with("turn:")),
        "history must not replay as new turns: {replayed:?}"
    );

    let mut events = session.events();
    let receipt = tokio::time::timeout(
        Duration::from_secs(60),
        session.send(input("restart-2", "Say two.", Delivery::Turn)),
    )
    .await
    .expect("send in time");
    eprintln!("send after restart: {receipt:?}");
    receipt.unwrap();
    let second = until_done(session.as_ref(), &mut events, |_| None).await;
    eprintln!("second turn: {:?} {:?}", second.outcome, second.answer);
    assert_eq!(
        second.outcome,
        Some(TurnOutcome::Completed),
        "{:?}",
        second.error
    );
    harness.shutdown().await;
}
