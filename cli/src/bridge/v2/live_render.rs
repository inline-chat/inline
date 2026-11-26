//! Live render lab: the installed `codex` or `claude` with a real model,
//! through the v2 harness, rendered as Inline would post it (opt-in; it
//! spends model usage).
//!
//! `INLINE_LIVE_RENDER=codex|claude INLINE_LIVE_OUT=<dir> cargo test -p
//! inline-cli --bin inline live_render -- --ignored --nocapture`
//!
//! The agent works in a scratch git repository under the out folder on a
//! small parser with a failing test: it runs commands (one failing, one
//! drawing a progress bar), reads and searches, writes a new Markdown file,
//! searches the web, plans, uses a sub-agent or task list, and fixes the
//! bug. Approvals are accepted and questions dismissed. Every event goes to
//! `events.jsonl`, and the turns are replayed through the renderer in both
//! output modes into `detailed.txt` and `friendly.txt`: one entry per
//! message as it ends up, with each block's kind, text, meta and status.
//! `INLINE_LIVE_MODEL` picks the model (Claude defaults to `sonnet`).
//! `INLINE_LIVE_REPLAY=<events.jsonl>` renders a recorded run again, for a
//! renderer change, without spending another turn. `INLINE_LIVE_STEPS=picks`
//! runs the second scenario instead: commands that wait for an approval
//! (with `INLINE_LIVE_PERMISSION=default` for Claude), output holding a key
//! and a path, a turn that shows nothing, a task list, an image (Codex) and
//! a compaction; the messages as they stood while each card waited go to
//! `<mode>.waiting[-n].txt`. `INLINE_LIVE_STEPS=answers` runs a plain
//! answer and a one-command turn. Each mode also writes
//! `<mode>.messages.json`, the messages as Inline would store them (text,
//! entities and blocks, base64 protobuf), for the iOS chat harness
//! (`--chatlist-harness --timeline-harness-bridge <file>`) to draw.

use std::collections::HashSet;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures_util::StreamExt;
use inline_agent_bridge::harness::{
    CatalogScope, Decision, DecisionKind, Delivery, Envelope, Event, ExecutableSource,
    HarnessDriver, Input, InputContent, InputId, InteractionKind, InteractionResponse, ItemBody,
    ItemUpdate, ModeId, Op, OpenMode, OpenSpec, Origin, OutputMode, Session, SettingsChange,
    TurnPhase, UserId,
};
use inline_protocol::proto;

use super::blocks::slice;
use super::doc::Doc;
use super::render::{RenderOp, Renderer, Vocabulary};

const TURN: Duration = Duration::from_secs(480);

const PARSER: &str = "def parse(text):\n    if not text:\n        raise ValueError(\"empty\")\n    return text.split(\",\")\n";
const TEST: &str = "import unittest\n\nfrom src.parser import parse\n\n\nclass ParseTest(unittest.TestCase):\n    def test_splits(self):\n        self.assertEqual(parse(\"a,b\"), [\"a\", \"b\"])\n\n    def test_empty_is_an_empty_list(self):\n        self.assertEqual(parse(\"\"), [])\n\n\nif __name__ == \"__main__\":\n    unittest.main()\n";

const PROGRESS: &str = "printf 'Downloading  10%%\\r Downloading  55%%\\rDownloading 100%%\\n'";

/// A prompt, optionally after switching the collaboration mode.
struct Step {
    mode: Option<&'static str>,
    prompt: String,
}

/// Sent as a prompt, runs a compaction instead.
const COMPACT: &str = "::compact";

/// A key and a path in a command's output: the key is hidden, the path kept.
const SECRET: &str = "printf 'API_KEY=sk-live-4f9a8b7c6d5e4f3a2b1c0d9e8f7a\\nlog written to %s/src/parser.py\\n' \"$PWD\"";

fn picks(provider: &str) -> Vec<Step> {
    let commands = format!(
        "Run the tests with `python3 -m unittest discover -s tests -t .` (one fails; don't fix anything yet). \
         Then run `{SECRET}` exactly. Reply with a one-line summary."
    );
    let quiet = "Reply with only the word OK.".to_owned();
    let fix = "Track this work with your task list tool (three steps: fix parse, run tests, update NOTES.md) and update each step as you go. \
               Fix parse so empty input returns [], run the tests, and create NOTES.md with one line about the fix. Reply in one line."
        .to_owned();
    let mut steps = vec![
        Step {
            mode: None,
            prompt: commands,
        },
        Step {
            mode: None,
            prompt: quiet,
        },
        Step {
            mode: None,
            prompt: fix,
        },
    ];
    if provider == "codex" {
        steps.push(Step {
            mode: None,
            prompt: "Generate an image of a small red circle on a white background with your image generation tool. Reply in one line.".to_owned(),
        });
    }
    steps.push(Step {
        mode: None,
        prompt: COMPACT.to_owned(),
    });
    steps
}

/// A plain answer, then one that runs a command: the first leaves no
/// progress, the second keeps its "Worked for".
fn answers() -> Vec<Step> {
    vec![
        Step {
            mode: None,
            prompt: "Reply with only the word OK.".to_owned(),
        },
        Step {
            mode: None,
            prompt: "Run `ls` and reply with how many entries it printed, in one line.".to_owned(),
        },
    ]
}

fn steps(provider: &str) -> Vec<Step> {
    match std::env::var("INLINE_LIVE_STEPS").as_deref() {
        Ok("picks") => return picks(provider),
        Ok("answers") => return answers(),
        _ => {}
    }
    let explore = format!(
        "Run the tests with `python3 -m unittest discover -s tests -t .` (one fails; don't fix anything yet). \
         Then run `{PROGRESS}` exactly. Then read src/parser.py and search the repository for the word parse. \
         Then create a new file NOTES.md containing a heading line `# Notes` and two bullet lines \
         `- parser raises on empty input` and `- tests expect an empty list`. Reply with a two-line summary."
    );
    let web = "Search the web for the latest stable Rust release and open its release notes page. Reply with the version and date in one line.".to_owned();
    match provider {
        "codex" => vec![
            Step { mode: None, prompt: explore },
            Step { mode: None, prompt: web },
            Step {
                mode: Some("plan"),
                prompt: "Plan how to make parse('') return an empty list and cover it with a test. Write the plan as a numbered list where step 1 has two nested bullet points under it. Don't change any files.".to_owned(),
            },
            Step {
                mode: Some("default"),
                prompt: "Now fix parse so empty input returns [], then run the tests again and reply in one line.".to_owned(),
            },
        ],
        _ => vec![
            Step { mode: None, prompt: explore },
            Step {
                mode: None,
                prompt: "Use the Task tool with the Explore sub-agent to find every place parse is defined or called and report back. Then summarize its findings in one line.".to_owned(),
            },
            Step {
                mode: None,
                prompt: "Track this work with your task list tool (three steps: fix parse, run tests, update NOTES.md) and update each step as you go. Fix parse so empty input returns [], run the tests, and add a line to NOTES.md. Reply in one line.".to_owned(),
            },
            Step { mode: None, prompt: web },
        ],
    }
}

fn scratch_repo(root: &Path) -> PathBuf {
    let repo = root.join("repo");
    let _ = std::fs::remove_dir_all(&repo);
    std::fs::create_dir_all(repo.join("src")).unwrap();
    std::fs::create_dir_all(repo.join("tests")).unwrap();
    std::fs::write(repo.join("src/__init__.py"), "").unwrap();
    std::fs::write(repo.join("tests/__init__.py"), "").unwrap();
    std::fs::write(repo.join("src/parser.py"), PARSER).unwrap();
    std::fs::write(repo.join("tests/test_parser.py"), TEST).unwrap();
    std::fs::write(repo.join("README.md"), "# Parser\n\nSplits comma lists.\n").unwrap();
    for args in [
        &["init", "-q"][..],
        &["add", "-A"],
        &[
            "-c",
            "user.name=lab",
            "-c",
            "user.email=lab@example.invalid",
            "commit",
            "-q",
            "-m",
            "start",
        ],
    ] {
        let status = std::process::Command::new("git")
            .args(args)
            .current_dir(&repo)
            .status()
            .unwrap();
        assert!(status.success(), "git {args:?}");
    }
    repo.canonicalize().unwrap()
}

fn which(name: &str) -> PathBuf {
    let output = std::process::Command::new("which")
        .arg(name)
        .output()
        .unwrap();
    assert!(output.status.success(), "{name} is not installed");
    PathBuf::from(String::from_utf8(output.stdout).unwrap().trim())
}

fn harness(provider: &str, out: &Path) -> (Arc<dyn HarnessDriver>, Vocabulary, &'static str) {
    match provider {
        "codex" => (
            Arc::new(inline_agent_driver_codex::harness::CodexHarness::new(
                inline_agent_driver_codex::harness::CodexHarnessConfig {
                    launch: inline_agent_driver_codex::CodexLaunchConfig {
                        executable: which("codex"),
                        ..Default::default()
                    },
                    source: ExecutableSource::Path,
                    pinned_sha256: None,
                    bridge_version: env!("CARGO_PKG_VERSION").to_owned(),
                    cache_root: out.join("cache"),
                },
            )),
            Vocabulary::Codex,
            "Codex",
        ),
        "claude" => {
            let mut config = inline_agent_driver_claude::harness::ClaudeHarnessConfig::new(
                which("claude"),
                env!("CARGO_PKG_VERSION"),
            );
            config.model =
                Some(std::env::var("INLINE_LIVE_MODEL").unwrap_or_else(|_| "sonnet".to_owned()));
            (
                Arc::new(inline_agent_driver_claude::harness::ClaudeHarness::new(
                    config,
                )),
                Vocabulary::Claude,
                "Claude",
            )
        }
        other => panic!("INLINE_LIVE_RENDER must be codex or claude, not {other}"),
    }
}

/// The decision a person most likely presses: allow once.
fn allow(decisions: &[Decision]) -> Option<&Decision> {
    decisions
        .iter()
        .find(|decision| decision.kind == DecisionKind::Accept)
        .or_else(|| {
            decisions
                .iter()
                .find(|decision| decision.kind == DecisionKind::AcceptForSession)
        })
        .or_else(|| decisions.first())
}

/// Sends `prompt` as a new turn and answers what it asks until it ends.
async fn run_turn(
    session: &Arc<dyn Session>,
    events: &Arc<Mutex<Vec<Envelope>>>,
    answered: &mut HashSet<String>,
    prompt: &str,
) -> String {
    let start = events.lock().unwrap().len();
    if prompt == COMPACT {
        let outcome = session.control(Op::Compact).await;
        println!("compact: {outcome:?}");
        if outcome.is_err() {
            return format!("compact refused: {outcome:?}");
        }
    } else {
        let id = InputId::new(uuid::Uuid::new_v4().to_string()).unwrap();
        session
            .send(Input {
                id,
                content: InputContent::text(prompt),
                origin: Origin::Owner { user: UserId(1) },
                delivery: Delivery::Turn,
            })
            .await
            .unwrap_or_else(|error| panic!("send failed: {error:?}"));
    }
    let deadline = Instant::now() + TURN;
    let mut seen = start;
    let mut started = false;
    loop {
        assert!(Instant::now() < deadline, "the turn did not end in time");
        let batch: Vec<Envelope> = events.lock().unwrap()[seen..].to_vec();
        seen += batch.len();
        for envelope in batch {
            match &envelope.event {
                Event::Turn {
                    phase: TurnPhase::Started { .. },
                    ..
                } => started = true,
                Event::Turn {
                    phase: TurnPhase::Completed { outcome, error, .. },
                    ..
                } if started => {
                    return format!(
                        "{outcome:?}{}",
                        error
                            .as_deref()
                            .map(|e| format!(": {e}"))
                            .unwrap_or_default()
                    );
                }
                Event::Interaction(interaction) if answered.insert(interaction.id.to_string()) => {
                    let response = match &interaction.kind {
                        InteractionKind::Approval { decisions, .. } => match allow(decisions) {
                            Some(decision) => InteractionResponse::Decision {
                                decision: decision.id.clone(),
                                message: None,
                            },
                            None => InteractionResponse::Cancel,
                        },
                        _ => InteractionResponse::Cancel,
                    };
                    println!("answering {} with {response:?}", interaction.id);
                    let outcome = session
                        .control(Op::Answer {
                            interaction: interaction.id.clone(),
                            response,
                            by: UserId(1),
                        })
                        .await;
                    println!("  -> {outcome:?}");
                }
                _ => {}
            }
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
}

/// Every message as it ends up: progress keeps its last edit, a card its
/// resolution.
fn messages(ops: Vec<RenderOp>) -> Vec<(String, Doc)> {
    let mut out: Vec<(String, Doc)> = Vec::new();
    let mut slots = std::collections::HashMap::new();
    let mut cards = std::collections::HashMap::new();
    for op in ops {
        match op {
            RenderOp::Progress { slot, doc } | RenderOp::EndProgress { slot, doc } => {
                match slots.get(&slot) {
                    Some(&index) => out[index] = (format!("progress {slot}"), doc),
                    None => {
                        slots.insert(slot, out.len());
                        out.push((format!("progress {slot}"), doc));
                    }
                }
            }
            RenderOp::DeleteProgress { slot } => {
                if let Some(index) = slots.remove(&slot) {
                    out[index] = (format!("progress {slot} (deleted)"), Doc::default());
                }
            }
            RenderOp::Image { path, .. } => {
                out.push((format!("image {}", path.display()), Doc::default()))
            }
            RenderOp::Update { doc } => out.push(("update".to_owned(), doc)),
            RenderOp::Final { doc } => out.push(("answer".to_owned(), doc)),
            RenderOp::PlanProposal { doc } => out.push(("plan proposal".to_owned(), doc)),
            RenderOp::Notice { doc } => out.push(("notice".to_owned(), doc)),
            RenderOp::Card {
                interaction, doc, ..
            } => {
                cards.insert(interaction.to_string(), out.len());
                out.push((format!("card {interaction}"), doc));
            }
            RenderOp::CardClosed { interaction, doc } => {
                match cards.get(&interaction.to_string()) {
                    Some(&index) => out[index] = (format!("card {interaction} (closed)"), doc),
                    None => out.push((format!("card {interaction} (closed)"), doc)),
                }
            }
        }
    }
    out
}

/// The messages as Inline stores them, for the apps' harnesses. Markdown
/// answers are parsed by the server, which the harness doesn't do, so their
/// markers are dropped and they read as plain text.
fn manifest(agent: &str, messages: &[(String, Doc)]) -> serde_json::Value {
    use base64::Engine as _;
    use prost::Message as _;
    let encode = |bytes: Vec<u8>| base64::engine::general_purpose::STANDARD.encode(bytes);
    let items: Vec<serde_json::Value> = messages
        .iter()
        .filter(|(_, doc)| !doc.is_empty())
        .map(|(label, doc)| {
            let text = if doc.markdown {
                doc.text.replace("**", "").replace('`', "")
            } else {
                doc.text.clone()
            };
            let mut content = doc.block_content();
            // For screenshots: progress and group rows open, so their rows show.
            if std::env::var_os("INLINE_LIVE_OPEN").is_some() {
                open_groups(&mut content.blocks);
            }
            serde_json::json!({
                "label": label,
                "text": text,
                "blocks": (!doc.markdown && !doc.blocks.is_empty())
                    .then(|| encode(content.encode_to_vec())),
                "entities": doc.message_entities().map(|entities| encode(entities.encode_to_vec())),
            })
        })
        .collect();
    serde_json::json!({ "agent": agent, "messages": items })
}

/// Opens every disclosure that holds other disclosures (a progress message
/// and its groups), leaving single rows closed.
fn open_groups(blocks: &mut [proto::Block]) {
    for block in blocks {
        if let Some(proto::block::Kind::Disclosure(disclosure)) = &mut block.kind {
            let groups = disclosure
                .children
                .iter()
                .any(|child| matches!(child.kind, Some(proto::block::Kind::Disclosure(_))));
            if groups {
                disclosure.initially_open = Some(true);
            }
            open_groups(&mut disclosure.children);
        }
    }
}

fn text(doc: &Doc, span: Option<&proto::BlockText>) -> String {
    span.and_then(|span| slice(&doc.text, span))
        .unwrap_or_default()
}

fn outline(doc: &Doc, blocks: &[proto::Block], depth: usize, out: &mut String) {
    use proto::block::Kind;
    let pad = "  ".repeat(depth);
    for block in blocks {
        let Some(kind) = &block.kind else { continue };
        match kind {
            Kind::Paragraph(span) => writeln!(out, "{pad}¶ {}", text(doc, Some(span))).unwrap(),
            Kind::Footer(span) => writeln!(out, "{pad}— {}", text(doc, Some(span))).unwrap(),
            Kind::Heading(heading) => {
                writeln!(out, "{pad}# {}", text(doc, heading.text.as_ref())).unwrap();
            }
            Kind::Code(code) => {
                writeln!(out, "{pad}```{}", code.language.as_deref().unwrap_or("")).unwrap();
                for line in text(doc, code.text.as_ref()).lines() {
                    writeln!(out, "{pad}{line}").unwrap();
                }
                writeln!(out, "{pad}```").unwrap();
            }
            Kind::Disclosure(disclosure) => {
                let meta = text(doc, disclosure.meta.as_ref());
                writeln!(
                    out,
                    "{pad}▸ {}{}  [status {:?}, activity {:?}]",
                    text(doc, disclosure.summary.as_ref()),
                    if meta.is_empty() {
                        String::new()
                    } else {
                        format!("  ·  {meta}")
                    },
                    proto::BlockStatus::try_from(disclosure.status).ok(),
                    proto::block_disclosure::ActivityKind::try_from(disclosure.activity_kind).ok(),
                )
                .unwrap();
                outline(doc, &disclosure.children, depth + 1, out);
            }
            Kind::Diff(diff) => {
                writeln!(
                    out,
                    "{pad}± {} (+{} −{})",
                    text(doc, diff.path.as_ref()),
                    diff.additions.unwrap_or(0),
                    diff.deletions.unwrap_or(0)
                )
                .unwrap();
                for line in text(doc, diff.text.as_ref()).lines().take(12) {
                    writeln!(out, "{pad}  {line}").unwrap();
                }
            }
            Kind::List(list) => {
                for item in &list.items {
                    writeln!(out, "{pad}•").unwrap();
                    outline(doc, &item.children, depth + 1, out);
                }
            }
            Kind::Callout(callout) => {
                writeln!(out, "{pad}! {}", text(doc, callout.title.as_ref())).unwrap();
                outline(doc, &callout.children, depth + 1, out);
            }
            Kind::Steps(steps) => {
                for step in &steps.steps {
                    writeln!(
                        out,
                        "{pad}[{:?}] {}",
                        proto::BlockStatus::try_from(step.status).ok(),
                        text(doc, step.text.as_ref())
                    )
                    .unwrap();
                }
            }
            Kind::Approval(approval) => {
                writeln!(
                    out,
                    "{pad}☐ {} | {}",
                    text(doc, approval.title.as_ref()),
                    text(doc, approval.command.as_ref())
                )
                .unwrap();
                outline(doc, &approval.children, depth + 1, out);
            }
            Kind::PlanProposal(plan) => {
                writeln!(out, "{pad}☐ plan: {}", text(doc, plan.title.as_ref())).unwrap();
                outline(doc, &plan.children, depth + 1, out);
            }
            other => {
                let name = format!("{other:?}");
                writeln!(out, "{pad}<{}>", name.split('(').next().unwrap_or("?")).unwrap();
            }
        }
    }
}

fn dump(messages: &[(String, Doc)]) -> String {
    let mut out = String::new();
    for (label, doc) in messages {
        writeln!(out, "──── {label}").unwrap();
        if doc.blocks.is_empty() {
            writeln!(out, "{}", doc.text).unwrap();
        } else {
            outline(doc, &doc.blocks, 0, &mut out);
        }
        out.push('\n');
    }
    out
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live lab: spends model usage; set INLINE_LIVE_RENDER"]
async fn live_render() {
    let Ok(provider) = std::env::var("INLINE_LIVE_RENDER") else {
        return;
    };
    let out =
        PathBuf::from(std::env::var("INLINE_LIVE_OUT").expect("INLINE_LIVE_OUT")).join(&provider);
    std::fs::create_dir_all(&out).unwrap();
    let (envelopes, outcomes, folder, vocabulary, agent) = match std::env::var("INLINE_LIVE_REPLAY")
    {
        // A recorded run, rendered again (after a renderer change) without
        // spending another turn.
        Ok(path) => {
            let envelopes: Vec<Envelope> = std::fs::read_to_string(path)
                .unwrap()
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect();
            let (vocabulary, agent) = match provider.as_str() {
                "codex" => (Vocabulary::Codex, "Codex"),
                _ => (Vocabulary::Claude, "Claude"),
            };
            // The folder the run worked in, as its settings reported it.
            let folder = envelopes
                .iter()
                .find_map(|envelope| match &envelope.event {
                    Event::Settings { effective } => effective.folder.clone(),
                    _ => None,
                })
                .unwrap_or_else(|| out.join("repo"));
            (envelopes, Vec::new(), folder, vocabulary, agent)
        }
        Err(_) => {
            let (envelopes, outcomes, folder, vocabulary, agent) = record(&provider, &out).await;
            (envelopes, outcomes, folder, vocabulary, agent)
        }
    };
    // Items the mapper could not name, worth a look.
    let unknown: Vec<String> = envelopes
        .iter()
        .filter_map(|envelope| match &envelope.event {
            Event::Item(item) => match &item.update {
                ItemUpdate::Completed {
                    body: ItemBody::Unknown { native_type, .. },
                    ..
                } => Some(native_type.clone()),
                _ => None,
            },
            _ => None,
        })
        .collect();
    for (mode, name) in [
        (OutputMode::Detailed, "detailed"),
        (OutputMode::Friendly, "friendly"),
    ] {
        let mut renderer = Renderer::new(mode, vocabulary, agent);
        renderer.set_folder(folder.clone());
        // The bridge shows the start before the session opens, for the first
        // message.
        let start = envelopes.first().map_or(0, |first| first.at_ms);
        let mut ops: Vec<RenderOp> = envelopes
            .first()
            .map(|_| renderer.starting(start))
            .unwrap_or_default();
        // What each progress message said, and when: a start, a status line.
        let mut timeline = String::new();
        let mut note = |at: u64, ops: &[RenderOp]| {
            for op in ops {
                let line = match op {
                    RenderOp::Progress { slot, doc } | RenderOp::EndProgress { slot, doc } => {
                        format!("progress {slot}: {}", doc.text.lines().next().unwrap_or(""))
                    }
                    RenderOp::DeleteProgress { slot } => format!("progress {slot} deleted"),
                    RenderOp::Final { doc } => {
                        format!("answer: {}", doc.text.lines().next().unwrap_or(""))
                    }
                    _ => continue,
                };
                if !timeline.ends_with(&format!("{line}\n")) {
                    let _ = writeln!(timeline, "{:>7} ms  {line}", at.saturating_sub(start));
                }
            }
        };
        note(start, &ops);
        for envelope in &envelopes {
            let applied = renderer.apply(envelope);
            note(envelope.at_ms, &applied);
            ops.extend(applied);
        }
        std::fs::write(out.join(format!("{name}.timeline.txt")), timeline).unwrap();
        // The chat while each card waited for its answer.
        let closings = ops
            .iter()
            .enumerate()
            .filter(|(_, op)| matches!(op, RenderOp::CardClosed { .. }))
            .map(|(index, _)| index);
        for (n, closed) in closings.enumerate() {
            let waiting = messages(ops[..closed].to_vec());
            let suffix = if n == 0 {
                String::new()
            } else {
                format!("-{}", n + 1)
            };
            std::fs::write(
                out.join(format!("{name}.waiting{suffix}.txt")),
                dump(&waiting),
            )
            .unwrap();
            std::fs::write(
                out.join(format!("{name}.waiting{suffix}.messages.json")),
                serde_json::to_string_pretty(&manifest(agent, &waiting)).unwrap(),
            )
            .unwrap();
        }
        // The chat while the session started: the last progress still
        // headed "Starting …".
        let starting = ops.iter().rposition(
            |op| matches!(op, RenderOp::Progress { doc, .. } if doc.text.starts_with("Starting")),
        );
        if let Some(last) = starting {
            let snapshot = messages(ops[..=last].to_vec());
            std::fs::write(out.join(format!("{name}.starting.txt")), dump(&snapshot)).unwrap();
            std::fs::write(
                out.join(format!("{name}.starting.messages.json")),
                serde_json::to_string_pretty(&manifest(agent, &snapshot)).unwrap(),
            )
            .unwrap();
        }
        let messages = messages(ops);
        std::fs::write(out.join(format!("{name}.txt")), dump(&messages)).unwrap();
        std::fs::write(
            out.join(format!("{name}.messages.json")),
            serde_json::to_string_pretty(&manifest(agent, &messages)).unwrap(),
        )
        .unwrap();
    }
    println!(
        "{} events, outcomes {outcomes:?}, unknown items {unknown:?}, out {}",
        envelopes.len(),
        out.display()
    );
}

/// Runs the steps against the real harness and returns every event.
async fn record(
    provider: &str,
    out: &Path,
) -> (
    Vec<Envelope>,
    Vec<String>,
    PathBuf,
    Vocabulary,
    &'static str,
) {
    let folder = scratch_repo(out);
    let (driver, vocabulary, agent) = harness(provider, out);
    let opening = Instant::now();
    let session = driver
        .open(OpenSpec {
            mode: OpenMode::Start,
            folder: folder.clone(),
            settings: SettingsChange {
                permission_mode: std::env::var("INLINE_LIVE_PERMISSION").ok(),
                ..SettingsChange::default()
            },
            instructions: None,
            title: Some("inline live render lab".to_owned()),
            after: None,
            output_mode: OutputMode::Detailed,
        })
        .await
        .unwrap_or_else(|error| panic!("open failed: {error:?}"));
    println!("open: {} ms", opening.elapsed().as_millis());
    // Listings: the open session's folder, then a folder with no session.
    for (label, scope) in [
        ("live session's folder", folder.clone()),
        ("another folder", out.to_path_buf()),
    ] {
        let listing = Instant::now();
        let catalog = driver
            .catalog(CatalogScope {
                folder: Some(scope),
                session: None,
            })
            .await;
        println!(
            "catalog ({label}): {} ms, {}",
            listing.elapsed().as_millis(),
            catalog.map_or_else(
                |error| format!("failed: {error}"),
                |catalog| format!(
                    "{} commands, {} usage windows",
                    catalog.commands.len(),
                    catalog.usage.len()
                )
            )
        );
    }
    let events = Arc::new(Mutex::new(Vec::<Envelope>::new()));
    let sink = events.clone();
    let mut stream = session.events();
    tokio::spawn(async move {
        while let Some(envelope) = stream.next().await {
            sink.lock().unwrap().push(envelope);
        }
    });
    let mut answered = HashSet::new();
    let mut outcomes = Vec::new();
    for step in steps(provider) {
        if let Some(mode) = step.mode {
            let outcome = session
                .control(Op::Mode {
                    mode: ModeId::new(mode).unwrap(),
                })
                .await;
            println!("mode {mode}: {outcome:?}");
        }
        let outcome = run_turn(&session, &events, &mut answered, &step.prompt).await;
        println!("turn: {outcome}");
        outcomes.push(outcome);
    }
    tokio::time::sleep(Duration::from_secs(2)).await;
    let _ = session.release().await;
    let envelopes = events.lock().unwrap().clone();
    let mut jsonl = String::new();
    for envelope in &envelopes {
        jsonl.push_str(&serde_json::to_string(envelope).unwrap());
        jsonl.push('\n');
    }
    std::fs::write(out.join("events.jsonl"), jsonl).unwrap();
    (envelopes, outcomes, folder, vocabulary, agent)
}
