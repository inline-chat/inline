//! Steering through the real session against the installed Claude Code and a
//! real model. Run by hand; it spends tokens:
//!
//! `CLAUDE_LIVE_BIN=$(which claude) cargo test -p inline-agent-driver-claude --test steer_live -- --ignored --nocapture`

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures_util::StreamExt;
use inline_agent_bridge::TurnOutcome;
use inline_agent_bridge::harness::{
    Delivery, Event, HarnessDriver, Input, InputContent, InputId, Op, OpenMode, OpenSpec, Origin,
    OutputMode, Session, SettingsChange, SteerPriority, TurnPhase, UserId,
};
use inline_agent_driver_claude::harness::{ClaudeHarness, ClaudeHarnessConfig};

const STEER: &str = "Also: end your final reply with the exact word PINEAPPLE.";
const ESSAY: &str = "Write a 900 word essay about the history of lighthouses. Use no tools.";
const COMMAND: &str = "Use Bash in the foreground (do not background it, timeout 120000 ms) to run exactly `python3 -c 'import time; time.sleep(40); print(1)'`. After it finishes, reply with one short line.";

struct Live {
    session: Arc<dyn Session>,
    events: Arc<Mutex<Vec<Event>>>,
    _folder: tempfile::TempDir,
}

fn input(text: &str, delivery: Delivery) -> Input {
    Input {
        id: InputId::new(uuid::Uuid::new_v4().to_string()).unwrap(),
        content: InputContent::text(text),
        origin: Origin::Owner { user: UserId(1) },
        delivery,
    }
}

impl Live {
    async fn start() -> Option<Self> {
        let Ok(executable) = std::env::var("CLAUDE_LIVE_BIN") else {
            return None;
        };
        let mut config = ClaudeHarnessConfig::new(executable, "live");
        config.model = Some(std::env::var("CLAUDE_LIVE_MODEL").unwrap_or("haiku".into()));
        let folder = tempfile::tempdir().unwrap();
        let session = ClaudeHarness::new(config)
            .open(OpenSpec {
                mode: OpenMode::Start,
                folder: folder.path().canonicalize().unwrap(),
                settings: SettingsChange::default(),
                instructions: None,
                title: None,
                after: None,
                output_mode: OutputMode::default(),
            })
            .await
            .unwrap_or_else(|_| panic!("the session did not open"));
        let events = Arc::new(Mutex::new(Vec::new()));
        let sink = events.clone();
        let mut stream = session.events();
        tokio::spawn(async move {
            while let Some(envelope) = stream.next().await {
                sink.lock().unwrap().push(envelope.event);
            }
        });
        Some(Self {
            session,
            events,
            _folder: folder,
        })
    }

    async fn until(&self, what: &str, within: Duration, done: impl Fn(&[Event]) -> bool) {
        let deadline = Instant::now() + within;
        while !done(&self.events.lock().unwrap()) {
            if Instant::now() >= deadline {
                for event in self.events.lock().unwrap().iter() {
                    let line = serde_json::to_string(event).unwrap();
                    println!("{}", line.chars().take(240).collect::<String>());
                }
                panic!("timed out waiting for {what}");
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    async fn steer(&self) -> String {
        let turn = self.session.live_work().turn.expect("a running turn");
        let receipt = self
            .session
            .send(input(
                STEER,
                Delivery::Steer {
                    expected_turn: turn,
                    priority: SteerPriority::Next,
                },
            ))
            .await
            .map_err(|error| error.to_string())
            .expect("the steer was taken");
        receipt.native["priority"].as_str().unwrap().to_string()
    }

    fn outcomes(&self) -> Vec<TurnOutcome> {
        outcomes(&self.events.lock().unwrap())
    }
}

fn outcomes(events: &[Event]) -> Vec<TurnOutcome> {
    events
        .iter()
        .filter_map(|event| match event {
            Event::Turn {
                phase: TurnPhase::Completed { outcome, .. },
                ..
            } => Some(*outcome),
            _ => None,
        })
        .collect()
}

fn mentions(events: &[Event], needle: &str) -> bool {
    events
        .iter()
        .any(|event| serde_json::to_string(event).unwrap().contains(needle))
}

fn is_text(event: &Event) -> bool {
    let text = serde_json::to_string(event).unwrap();
    text.contains("delta") && text.contains("\"text\"")
}

#[tokio::test]
#[ignore = "live: needs CLAUDE_LIVE_BIN and spends tokens"]
async fn a_steer_cuts_a_streaming_reply_and_the_turn_is_not_stopped() {
    let Some(live) = Live::start().await else {
        return;
    };
    live.session
        .send(input(ESSAY, Delivery::Turn))
        .await
        .map_err(|error| error.to_string())
        .unwrap();
    live.until("the reply to stream", Duration::from_secs(60), |events| {
        events.iter().any(is_text)
    })
    .await;
    assert_eq!(live.steer().await, "now");
    let sent = Instant::now();
    live.until("the cut", Duration::from_secs(3), |events| {
        !outcomes(events).is_empty()
    })
    .await;
    println!("cut after {:?}", sent.elapsed());
    live.until("the steered turn", Duration::from_secs(90), |events| {
        outcomes(events).len() >= 2
    })
    .await;
    assert_eq!(
        live.outcomes(),
        vec![TurnOutcome::Completed, TurnOutcome::Completed]
    );
    assert!(mentions(&live.events.lock().unwrap(), "PINEAPPLE"));
}

#[tokio::test]
#[ignore = "live: needs CLAUDE_LIVE_BIN and spends tokens"]
async fn a_steer_moves_a_long_command_to_the_background() {
    let Some(live) = Live::start().await else {
        return;
    };
    live.session
        .send(input(COMMAND, Delivery::Turn))
        .await
        .map_err(|error| error.to_string())
        .unwrap();
    live.until("the command", Duration::from_secs(60), |events| {
        mentions(events, "time.sleep(40)")
    })
    .await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(live.steer().await, "next");
    let sent = Instant::now();
    // The command runs for 40s; the steer does not wait for it. The model may
    // still choose to wait for the output afterwards.
    live.until("the command to move", Duration::from_secs(25), |events| {
        events.iter().any(|event| {
            let event = serde_json::to_string(event).unwrap();
            event.contains("time.sleep(40)") && event.contains("\"op\":\"completed\"")
        })
    })
    .await;
    println!("moved after {:?}", sent.elapsed());
    assert!(
        !live.outcomes().contains(&TurnOutcome::Interrupted),
        "{:?}",
        live.outcomes()
    );
}

#[tokio::test]
#[ignore = "live: needs CLAUDE_LIVE_BIN and spends tokens"]
async fn a_plain_stop_still_reads_as_a_stop() {
    let Some(live) = Live::start().await else {
        return;
    };
    live.session
        .send(input(ESSAY, Delivery::Turn))
        .await
        .map_err(|error| error.to_string())
        .unwrap();
    live.until("the reply to stream", Duration::from_secs(60), |events| {
        events.iter().any(is_text)
    })
    .await;
    live.session
        .control(Op::Interrupt {
            cancel_queued: false,
        })
        .await
        .map_err(|error| error.to_string())
        .unwrap();
    live.until("the stop", Duration::from_secs(5), |events| {
        !outcomes(events).is_empty()
    })
    .await;
    assert_eq!(live.outcomes(), vec![TurnOutcome::Interrupted]);
}
