//! Live qualification against a real OpenCode v2 service.
//!
//! Opt-in: `INLINE_OPENCODE_LIVE=1 cargo test -p inline-agent-driver-opencode
//! --test live_opencode -- --ignored --nocapture`. Uses the `opencode` on PATH
//! (or `INLINE_OPENCODE_EXECUTABLE`), its running background service or one
//! it starts, a scratch folder, and the model in `INLINE_OPENCODE_MODEL`
//! (`provider/id`, default: OpenCode's default model). It creates and leaves
//! one session in that scratch folder.

use std::path::PathBuf;
use std::time::Duration;

use futures_util::StreamExt;
use inline_agent_bridge::TurnOutcome;
use inline_agent_bridge::harness::*;
use inline_agent_driver_opencode::{OpenCodeHarness, OpenCodeHarnessConfig};

const TURN_TIMEOUT: Duration = Duration::from_secs(300);

fn executable() -> PathBuf {
    std::env::var_os("INLINE_OPENCODE_EXECUTABLE")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("PATH").and_then(|path| {
                std::env::split_paths(&path)
                    .map(|dir| dir.join("opencode"))
                    .find(|candidate| candidate.is_file())
            })
        })
        .expect("opencode on PATH or INLINE_OPENCODE_EXECUTABLE")
}

fn trace(event: &Event) -> String {
    match event {
        Event::Turn { turn, phase } => format!(
            "turn {} {}",
            turn.as_str(),
            match phase {
                TurnPhase::Started { .. } => "started",
                TurnPhase::Completed { .. } => "completed",
            }
        ),
        Event::Item(item) => format!("item {:?}", item.kind),
        Event::Notice(notice) => format!("notice {}", notice.code),
        other => format!("{:?}", std::mem::discriminant(other)),
    }
}

async fn turn(session: &dyn Session, id: &str, text: &str) -> (String, Vec<Event>) {
    let mut events = session.events();
    let receipt = session
        .send(Input {
            id: InputId::new(id).unwrap(),
            content: InputContent::text(text),
            origin: Origin::Owner { user: UserId(1) },
            delivery: Delivery::Turn,
        })
        .await
        .expect("turn accepted");
    let InputDisposition::Started { turn } = receipt.disposition else {
        panic!("{receipt:?}");
    };
    let mut seen = Vec::new();
    let mut answer = String::new();
    tokio::time::timeout(TURN_TIMEOUT, async {
        while let Some(envelope) = events.next().await {
            let event = envelope.event;
            match &event {
                Event::Interaction(interaction) => {
                    session
                        .control(Op::Answer {
                            interaction: interaction.id.clone(),
                            response: InteractionResponse::Cancel,
                            by: UserId(1),
                        })
                        .await
                        .ok();
                }
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
                }) => answer = text.clone(),
                Event::Turn {
                    turn: ended,
                    phase: TurnPhase::Completed { outcome, error, .. },
                } if *ended == turn => {
                    assert_eq!(*outcome, TurnOutcome::Completed, "{error:?}");
                    seen.push(event);
                    return;
                }
                _ => {}
            }
            seen.push(event);
        }
    })
    .await
    .unwrap_or_else(|_| {
        panic!(
            "turn {turn:?} did not complete in time; saw {:?}",
            seen.iter().map(trace).collect::<Vec<_>>()
        )
    });
    (answer, seen)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "needs a real OpenCode v2 with credentials; set INLINE_OPENCODE_LIVE=1"]
async fn live_turns_steering_catalog_and_resume() {
    if std::env::var("INLINE_OPENCODE_LIVE").as_deref() != Ok("1") {
        return;
    }
    let folder = tempfile::tempdir().unwrap();
    let harness = OpenCodeHarness::new(OpenCodeHarnessConfig::new(executable(), "live-test"));
    let catalog = harness
        .catalog(CatalogScope {
            folder: Some(folder.path().to_path_buf()),
            session: None,
        })
        .await
        .expect("catalog");
    eprintln!(
        "OpenCode {:?}: {} models, modes {:?}, {} commands",
        harness.describe().executable.version,
        catalog.models.len(),
        catalog
            .modes
            .iter()
            .map(|mode| mode.id.as_str())
            .collect::<Vec<_>>(),
        catalog.commands.len()
    );
    assert!(!catalog.models.is_empty(), "OpenCode has no usable model");
    let spec = |mode| OpenSpec {
        mode,
        folder: folder.path().to_path_buf(),
        settings: SettingsChange {
            model: std::env::var("INLINE_OPENCODE_MODEL").ok(),
            ..Default::default()
        },
        instructions: Some("Answer in one short sentence.".into()),
        title: Some("Inline live test".into()),
        after: None,
        output_mode: OutputMode::Detailed,
    };
    let session = harness.open(spec(OpenMode::Start)).await.expect("start");
    let (answer, events) = turn(session.as_ref(), "live-1", "Reply with the word pineapple.").await;
    eprintln!("answer: {answer}");
    assert!(answer.to_lowercase().contains("pineapple"), "{answer}");
    assert!(events.iter().any(|event| matches!(
        event,
        Event::Input {
            fact: InputFact::Consumed { .. },
            ..
        }
    )));
    let id = session.key().session.clone();
    session.release().await.unwrap();
    drop(session);

    // Resume: the same session answers with its history.
    let resumed = harness
        .open(spec(OpenMode::Resume {
            session: id.clone(),
        }))
        .await
        .expect("resume");
    let (answer, _) = turn(
        resumed.as_ref(),
        "live-2",
        "Which fruit did you just name? One word.",
    )
    .await;
    assert!(answer.to_lowercase().contains("pineapple"), "{answer}");
    let page = harness
        .sessions(SessionQuery {
            folder: Some(folder.path().to_path_buf()),
            ..Default::default()
        })
        .await
        .unwrap();
    assert!(
        page.sessions
            .iter()
            .any(|summary| summary.key.session == id)
    );
    harness.shutdown().await;
}
