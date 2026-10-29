//! Replays real local Claude Code transcripts through the renderer (opt-in).
//!
//! `INLINE_RENDER_CORPUS=~/.claude/projects/<project> cargo test -p inline-cli
//! --bin inline corpus -- --ignored --nocapture` turns each turn's tool calls
//! into harness items, renders them as Detailed progress, and checks every
//! message against Inline's limits. With `INLINE_RENDER_CORPUS_OUT=<file>` it
//! also writes each turn's final progress text there to read through.
//! Transcripts stay on the machine; nothing here is committed.

use std::path::{Path, PathBuf};

use inline_agent_bridge::harness::{
    Envelope, Event, FileChangeKind, FileDiff, Item, ItemBody, ItemId, ItemStatus, ItemUpdate,
    OutputMode, SessionKey, TurnPhase,
};
use inline_agent_bridge::{ProviderId, ProviderSessionId, TurnId, TurnOutcome};
use serde_json::Value;

use super::limits::Size;
use super::render::{RenderOp, Renderer, Vocabulary};

/// A tool call from a transcript as the harness would report it.
fn body(name: &str, input: &Value, output: &str) -> ItemBody {
    let text = |key: &str| input.get(key).and_then(Value::as_str).unwrap_or_default();
    match name {
        "Bash" => ItemBody::Command {
            command: text("command").to_owned(),
            cwd: None,
            actions: Vec::new(),
            output: Some(output.to_owned()),
            exit_code: Some(0),
            duration_ms: Some(1000),
        },
        "Edit" | "MultiEdit" | "Write" => ItemBody::FileChange {
            changes: vec![FileDiff {
                path: text("file_path").into(),
                change: if name == "Write" {
                    FileChangeKind::Add
                } else {
                    FileChangeKind::Update { moved_to: None }
                },
                diff: Some(format!(
                    "@@\n-{}\n+{}",
                    text("old_string").replace('\n', "\n-"),
                    text("new_string").replace('\n', "\n+")
                )),
            }],
        },
        _ => ItemBody::Tool {
            name: name.to_owned(),
            server: None,
            input: input.clone(),
            output: Some(output.to_owned()),
            error: None,
        },
    }
}

/// Each turn of one transcript as harness envelopes: a person's message
/// starts a turn, and its tool calls follow in order.
fn turns(path: &Path) -> Vec<Vec<Event>> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut turns: Vec<Vec<Event>> = Vec::new();
    let mut calls: Vec<(String, String, Value)> = Vec::new();
    let mut results: std::collections::HashMap<String, String> = Default::default();
    let flush = |calls: &mut Vec<(String, String, Value)>,
                 results: &mut std::collections::HashMap<String, String>,
                 turns: &mut Vec<Vec<Event>>| {
        if calls.is_empty() {
            return;
        }
        let events = calls
            .drain(..)
            .filter_map(|(id, name, input)| {
                let output = results.remove(&id).unwrap_or_default();
                Some(Event::Item(Item::new(
                    ItemId::new(id).ok()?,
                    None,
                    ItemUpdate::Completed {
                        body: body(&name, &input, &output),
                        status: ItemStatus::Completed,
                    },
                    Value::Null,
                )))
            })
            .collect();
        turns.push(events);
    };
    for line in text.lines() {
        let Ok(entry) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let content = &entry["message"]["content"];
        let blocks = content.as_array().cloned().unwrap_or_default();
        let is_result = blocks.iter().any(|block| block["type"] == "tool_result");
        if entry["type"] == "user" && !is_result {
            flush(&mut calls, &mut results, &mut turns);
            continue;
        }
        for block in blocks {
            match block["type"].as_str() {
                Some("tool_use") => calls.push((
                    block["id"].as_str().unwrap_or_default().to_owned(),
                    block["name"].as_str().unwrap_or_default().to_owned(),
                    block["input"].clone(),
                )),
                Some("tool_result") => {
                    let output = match &block["content"] {
                        Value::String(text) => text.clone(),
                        other => other.to_string(),
                    };
                    results.insert(
                        block["tool_use_id"].as_str().unwrap_or_default().to_owned(),
                        output,
                    );
                }
                _ => {}
            }
        }
    }
    flush(&mut calls, &mut results, &mut turns);
    turns
}

fn transcripts(root: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = walkdir::WalkDir::new(root)
        .into_iter()
        .filter_map(Result::ok)
        .map(|entry| entry.into_path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "jsonl")
        })
        .collect();
    files.sort();
    files
}

#[test]
#[ignore = "reads local transcripts; set INLINE_RENDER_CORPUS"]
fn real_turns_render_within_inlines_limits() {
    let Some(root) = std::env::var_os("INLINE_RENDER_CORPUS") else {
        eprintln!("INLINE_RENDER_CORPUS is not set; nothing to replay");
        return;
    };
    let key = SessionKey {
        provider: ProviderId::new("claude").expect("provider"),
        session: ProviderSessionId::new("corpus").expect("session"),
    };
    let (mut turns_seen, mut messages, mut continued) = (0, 0, 0);
    let mut gallery = String::new();
    for path in transcripts(Path::new(&root)) {
        for events in turns(&path) {
            turns_seen += 1;
            let mut renderer = Renderer::new(OutputMode::Detailed, Vocabulary::Claude, "Claude");
            let turn = TurnId::new(format!("t{turns_seen}")).expect("turn");
            let mut envelopes = vec![Event::Turn {
                turn: turn.clone(),
                phase: TurnPhase::Started { inputs: Vec::new() },
            }];
            envelopes.extend(events);
            envelopes.push(Event::Turn {
                turn,
                phase: TurnPhase::Completed {
                    outcome: TurnOutcome::Completed,
                    inputs_consumed: Vec::new(),
                    error: None,
                    duration_ms: Some(60_000),
                },
            });
            for (seq, event) in envelopes.into_iter().enumerate() {
                let envelope = Envelope {
                    session: key.clone(),
                    seq: seq as u64 + 1,
                    checkpoint: None,
                    at_ms: seq as u64 * 1000,
                    event,
                };
                for op in renderer.apply(&envelope) {
                    let doc = match &op {
                        RenderOp::Progress { doc, .. } | RenderOp::EndProgress { doc, .. } => doc,
                        _ => continue,
                    };
                    messages += 1;
                    let size = Size::of(doc);
                    assert!(
                        size.fits(),
                        "{} turn {turns_seen}: a message over Inline's limits: {size:?}",
                        path.display()
                    );
                    if let RenderOp::EndProgress { doc, .. } = &op {
                        if doc.text.contains("continued below") {
                            continued += 1;
                        }
                        gallery.push_str(&format!(
                            "\n===== {} · turn {turns_seen}\n{}\n",
                            path.display(),
                            doc.text
                        ));
                    }
                }
            }
        }
    }
    eprintln!(
        "{turns_seen} turns, {messages} progress renders, {continued} continued in a new message"
    );
    if let Some(out) = std::env::var_os("INLINE_RENDER_CORPUS_OUT") {
        std::fs::write(out, gallery).expect("gallery");
    }
}
