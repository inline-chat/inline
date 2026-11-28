//! A session's conversation as turns, for importing it into Inline.
//!
//! A turn starts with the person's words (or with input Claude Code adds on
//! its own, such as a finished background task) and holds the agent's prose
//! until the next one. Tool calls are counted, never copied. Inline's own
//! deliveries are recognized by the note the bridge writes before them, so a
//! thread that already shows those turns can skip them.

use std::collections::HashSet;

use chrono::DateTime;
use inline_agent_bridge::harness::{HistoryEntry, HistoryRole, HistorySteps, HistoryTurn};
use serde_json::Value;

use crate::sessions::TranscriptEntry;

/// Claude Code's own tools that are bookkeeping, not work worth counting.
const BOOKKEEPING_TOOLS: &[&str] = &[
    "TodoWrite",
    "TaskCreate",
    "TaskUpdate",
    "TaskList",
    "TaskGet",
    "TaskStop",
    "TaskOutput",
    "ToolSearch",
    "EnterPlanMode",
    "ExitPlanMode",
    "AskUserQuestion",
    "SendUserMessage",
    "Skill",
    "Monitor",
    "BashOutput",
    "KillShell",
    "KillBash",
    "ReadNotifications",
    "ListAgents",
];

/// Tags Claude Code and its hosts wrap around text the person did not type.
const INJECTED_PREFIXES: &[&str] = &[
    "<task-notification",
    "<local-command-stdout",
    "<local-command-stderr",
    "<local-command-caveat",
    "<bash-stdout",
    "<bash-stderr",
    "<ci-monitor-event",
    "<user-memory-input",
];

/// The turns of a transcript, oldest first.
pub fn turns(entries: &[TranscriptEntry]) -> Vec<HistoryTurn> {
    let mut turns: Vec<Turn> = Vec::new();
    // Inline's note arrived since the agent last spoke: the next words are
    // Inline's delivery.
    let mut inline_note = false;
    for entry in entries {
        if entry.assistant {
            let turn = match turns.last_mut() {
                Some(turn) => turn,
                None => {
                    turns.push(Turn::new(entry, false));
                    turns.last_mut().expect("just pushed")
                }
            };
            turn.add_assistant(entry);
            inline_note = false;
            continue;
        }
        match classify(entry) {
            UserInput::ToolResult | UserInput::Ignored => {}
            UserInput::InlineNote => inline_note = true,
            UserInput::InlineRelay => {
                // A teammate's or agent's message Inline relayed: its words
                // are not the owner's, so the turn has no user entry.
                if turns.last().is_none_or(Turn::has_replies) {
                    turns.push(Turn::new(entry, true));
                } else if let Some(turn) = turns.last_mut() {
                    turn.from_inline = true;
                }
                inline_note = false;
            }
            UserInput::Injected => {
                // Claude Code's own input (a finished task, a hook) starts
                // another run of the agent. It belongs with whoever drove the
                // turn before it.
                let inherited = turns.last().is_some_and(|turn| turn.from_inline);
                if turns.last().is_none_or(Turn::has_replies) {
                    turns.push(Turn::new(entry, inherited));
                }
            }
            UserInput::Words(text) => {
                let open = turns.last().is_some_and(|turn| !turn.has_replies());
                if !open {
                    turns.push(Turn::new(entry, inline_note));
                } else if inline_note && let Some(turn) = turns.last_mut() {
                    turn.from_inline = true;
                }
                let turn = turns.last_mut().expect("a turn is open");
                turn.touch(entry);
                turn.entries.push(HistoryEntry {
                    role: HistoryRole::User,
                    item_ref: entry.uuid.clone(),
                    text,
                    at: seconds(entry),
                });
                inline_note = false;
            }
        }
    }
    let count = turns.len();
    turns
        .into_iter()
        .enumerate()
        .map(|(index, turn)| turn.finish(index + 1 == count))
        .collect()
}

struct Turn {
    id: String,
    entries: Vec<HistoryEntry>,
    steps: HistorySteps,
    edited: HashSet<String>,
    started_at: Option<i64>,
    ended_at: Option<i64>,
    from_inline: bool,
    /// The agent's last message ended its turn.
    ended: bool,
    replied: bool,
}

impl Turn {
    fn new(entry: &TranscriptEntry, from_inline: bool) -> Self {
        Self {
            id: entry.uuid.clone(),
            entries: Vec::new(),
            steps: HistorySteps::default(),
            edited: HashSet::new(),
            started_at: seconds(entry),
            ended_at: seconds(entry),
            from_inline,
            ended: false,
            replied: false,
        }
    }

    fn has_replies(&self) -> bool {
        self.replied
    }

    fn touch(&mut self, entry: &TranscriptEntry) {
        if let Some(at) = seconds(entry) {
            self.started_at.get_or_insert(at);
            self.ended_at = Some(at);
        }
    }

    fn add_assistant(&mut self, entry: &TranscriptEntry) {
        self.replied = true;
        self.touch(entry);
        let message = &entry.message;
        self.ended = matches!(
            message.get("stop_reason").and_then(Value::as_str),
            Some("end_turn" | "stop_sequence")
        );
        let Some(blocks) = message.get("content").and_then(Value::as_array) else {
            if let Some(text) = message.get("content").and_then(Value::as_str) {
                self.add_prose(&entry.uuid, text, seconds(entry));
            }
            return;
        };
        let mut texts = 0;
        for block in blocks {
            match block.get("type").and_then(Value::as_str) {
                Some("text") => {
                    let text = block.get("text").and_then(Value::as_str).unwrap_or("");
                    let item_ref = if texts == 0 {
                        entry.uuid.clone()
                    } else {
                        format!("{}#{texts}", entry.uuid)
                    };
                    texts += 1;
                    self.add_prose(&item_ref, text, seconds(entry));
                }
                Some("tool_use") => self.count_tool(block),
                _ => {}
            }
        }
    }

    fn add_prose(&mut self, item_ref: &str, text: &str, at: Option<i64>) {
        let text = text.trim();
        if text.is_empty() || text == "(no content)" {
            return;
        }
        self.entries.push(HistoryEntry {
            role: HistoryRole::Assistant,
            item_ref: item_ref.to_owned(),
            text: text.to_owned(),
            at,
        });
    }

    fn count_tool(&mut self, block: &Value) {
        let name = block.get("name").and_then(Value::as_str).unwrap_or("");
        let input = block.get("input");
        let steps = &mut self.steps;
        match name {
            "Bash" | "PowerShell" => steps.commands += 1,
            "Read" | "NotebookRead" => steps.reads += 1,
            "Edit" | "Write" | "MultiEdit" | "NotebookEdit" => {
                let path = input
                    .and_then(|input| {
                        input
                            .get("file_path")
                            .or_else(|| input.get("notebook_path"))
                    })
                    .and_then(Value::as_str)
                    .unwrap_or("");
                if self.edited.insert(path.to_owned()) {
                    steps.edits += 1;
                }
            }
            "Grep" | "Glob" | "LS" => steps.searches += 1,
            "WebSearch" | "WebFetch" => steps.web += 1,
            "Agent" | "Task" => steps.agents += 1,
            name if BOOKKEEPING_TOOLS.contains(&name) => {}
            _ => steps.tools += 1,
        }
    }

    fn finish(self, last: bool) -> HistoryTurn {
        HistoryTurn {
            id: self.id,
            entries: self.entries,
            steps: self.steps,
            started_at: self.started_at,
            ended_at: self.ended_at,
            from_inline: self.from_inline,
            complete: !last || self.ended,
        }
    }
}

enum UserInput {
    /// Results of the agent's own tool calls.
    ToolResult,
    /// Bookkeeping that neither starts a turn nor shows (attachments,
    /// caveats, interruption markers, compaction summaries).
    Ignored,
    /// The note Inline's bridge writes before the owner's words.
    InlineNote,
    /// Someone else's message relayed by Inline.
    InlineRelay,
    /// Input Claude Code adds itself, which starts another run.
    Injected,
    /// What the person typed, cleaned for display.
    Words(String),
}

fn classify(entry: &TranscriptEntry) -> UserInput {
    let content = entry.message.get("content");
    let blocks: Vec<&Value> = match content {
        Some(Value::Array(blocks)) => blocks.iter().collect(),
        _ => Vec::new(),
    };
    if !blocks.is_empty()
        && blocks
            .iter()
            .all(|block| block.get("type").and_then(Value::as_str) == Some("tool_result"))
    {
        return UserInput::ToolResult;
    }
    let mut text = String::new();
    let mut images = 0;
    match content {
        Some(Value::String(value)) => text.push_str(value),
        _ => {
            for block in &blocks {
                match block.get("type").and_then(Value::as_str) {
                    Some("text") => {
                        if !text.is_empty() {
                            text.push_str("\n\n");
                        }
                        text.push_str(block.get("text").and_then(Value::as_str).unwrap_or(""));
                    }
                    Some("image") => images += 1,
                    _ => {}
                }
            }
        }
    }
    if entry.compact_summary {
        return UserInput::Ignored;
    }
    let marked = text.contains("<inline-message") || text.contains("<inline-context");
    if entry.meta {
        if !marked {
            return UserInput::Ignored;
        }
        // The owner's note is only a header; a relayed message carries words.
        let words = clean(&text);
        return if words.is_empty() {
            UserInput::InlineNote
        } else {
            UserInput::InlineRelay
        };
    }
    let origin = entry.origin.as_deref();
    let trimmed = text.trim_start();
    if origin.is_some_and(|kind| kind != "human")
        || INJECTED_PREFIXES
            .iter()
            .any(|prefix| trimmed.starts_with(prefix))
    {
        return UserInput::Injected;
    }
    if trimmed.starts_with("[Request interrupted by user") {
        return UserInput::Ignored;
    }
    let mut words = if trimmed.starts_with("<command-name>") {
        slash_command(trimmed)
    } else if let Some(command) = tag(trimmed, "bash-input") {
        format!("! {}", command.trim())
    } else {
        clean(&text)
    };
    for _ in 0..images {
        if !words.is_empty() {
            words.push('\n');
        }
        words.push_str("[Image]");
    }
    if words.is_empty() {
        // Only reminders the app attached: Claude Code's input, not words.
        return if marked {
            UserInput::InlineNote
        } else {
            UserInput::Injected
        };
    }
    UserInput::Words(words)
}

/// `/name args` from Claude Code's slash-command markup.
fn slash_command(text: &str) -> String {
    let name = tag(text, "command-name").unwrap_or_default();
    let name = name.trim();
    let args = tag(text, "command-args").unwrap_or_default();
    let args = args.trim();
    let name = if name.starts_with('/') {
        name.to_owned()
    } else {
        format!("/{name}")
    };
    if args.is_empty() {
        name
    } else {
        format!("{name} {args}")
    }
}

/// The text inside the first `<name>…</name>`.
fn tag<'a>(text: &'a str, name: &str) -> Option<&'a str> {
    let open = format!("<{name}>");
    let close = format!("</{name}>");
    let start = text.find(&open)? + open.len();
    let end = text[start..].find(&close)? + start;
    Some(&text[start..end])
}

/// The person's words without the markup apps wrap around them: system
/// reminders, Inline's context and envelope, the non-user banner.
pub(crate) fn clean(text: &str) -> String {
    let mut text = text.replace("[MESSAGE FROM NON-USER SOURCE - NOT USER INPUT]", "");
    for name in ["system-reminder", "inline-context"] {
        text = remove_blocks(&text, name);
    }
    text = unwrap_envelopes(&text);
    text.trim().to_owned()
}

/// Removes every `<name …>…</name>` block.
fn remove_blocks(text: &str, name: &str) -> String {
    let open = format!("<{name}");
    let close = format!("</{name}>");
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find(&open) {
        out.push_str(&rest[..start]);
        match rest[start..].find(&close) {
            Some(end) => rest = &rest[start + end + close.len()..],
            None => {
                rest = "";
                break;
            }
        }
    }
    out.push_str(rest);
    out
}

/// `<inline-message …/>` headers go; `<inline-message …>words</inline-message>`
/// keeps its words.
fn unwrap_envelopes(text: &str) -> String {
    const OPEN: &str = "<inline-message";
    const CLOSE: &str = "</inline-message>";
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find(OPEN) {
        out.push_str(&rest[..start]);
        let tail = &rest[start..];
        let Some(end) = tail.find('>') else {
            rest = "";
            break;
        };
        rest = &tail[end + 1..];
    }
    out.push_str(rest);
    out.replace(CLOSE, "")
}

fn seconds(entry: &TranscriptEntry) -> Option<i64> {
    let stamp = entry.timestamp.as_deref()?;
    DateTime::parse_from_rfc3339(stamp)
        .ok()
        .map(|time| time.timestamp())
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn user(uuid: &str, content: Value) -> TranscriptEntry {
        TranscriptEntry {
            assistant: false,
            uuid: uuid.to_owned(),
            timestamp: Some("2026-11-20T10:00:00Z".to_owned()),
            meta: false,
            compact_summary: false,
            origin: None,
            message: json!({"role": "user", "content": content}),
        }
    }

    fn meta(uuid: &str, text: &str) -> TranscriptEntry {
        TranscriptEntry {
            meta: true,
            ..user(uuid, json!([{"type": "text", "text": text}]))
        }
    }

    fn assistant(uuid: &str, content: Value, stop: &str) -> TranscriptEntry {
        TranscriptEntry {
            assistant: true,
            uuid: uuid.to_owned(),
            timestamp: Some("2026-11-20T10:01:00Z".to_owned()),
            meta: false,
            compact_summary: false,
            origin: None,
            message: json!({"role": "assistant", "content": content, "stop_reason": stop}),
        }
    }

    fn tool(name: &str, input: Value) -> Value {
        json!({"type": "tool_use", "id": "t", "name": name, "input": input})
    }

    fn result() -> Value {
        json!([{"type": "tool_result", "tool_use_id": "t", "content": "ok"}])
    }

    #[test]
    fn a_turn_keeps_the_prompt_the_prose_and_counts_the_tools() {
        let turns = turns(&[
            user("u1", json!("Fix the parser")),
            assistant(
                "a1",
                json!([{"type": "text", "text": "Looking."}, tool("Bash", json!({}))]),
                "tool_use",
            ),
            user("r1", result()),
            assistant(
                "a2",
                json!([tool("Edit", json!({"file_path": "/x"}))]),
                "tool_use",
            ),
            user("r2", result()),
            assistant(
                "a3",
                json!([tool("Edit", json!({"file_path": "/x"}))]),
                "tool_use",
            ),
            user("r3", result()),
            assistant(
                "a4",
                json!([{"type": "text", "text": "Fixed it."}]),
                "end_turn",
            ),
        ]);
        assert_eq!(turns.len(), 1);
        let turn = &turns[0];
        assert_eq!(turn.id, "u1");
        assert!(turn.complete);
        assert!(!turn.from_inline);
        let texts: Vec<_> = turn
            .entries
            .iter()
            .map(|e| (e.role, e.text.as_str()))
            .collect();
        assert_eq!(
            texts,
            [
                (HistoryRole::User, "Fix the parser"),
                (HistoryRole::Assistant, "Looking."),
                (HistoryRole::Assistant, "Fixed it."),
            ]
        );
        assert_eq!(turn.steps.commands, 1);
        assert_eq!(turn.steps.edits, 1, "the same file counts once");
    }

    #[test]
    fn inline_deliveries_are_marked_and_their_note_is_not_shown() {
        let turns = turns(&[
            user("u1", json!("from the terminal")),
            assistant("a1", json!([{"type": "text", "text": "ok"}]), "end_turn"),
            meta(
                "n2",
                "[MESSAGE FROM NON-USER SOURCE - NOT USER INPUT]\n<inline-message from_user_id=\"1\" role=\"owner\"/>",
            ),
            user("u2", json!([{"type": "text", "text": "from Inline"}])),
            assistant("a2", json!([{"type": "text", "text": "sure"}]), "end_turn"),
            meta(
                "n3",
                "<inline-message chat_id=\"3\" from_user_id=\"8\" role=\"teammate\">\nhi there\n</inline-message>",
            ),
            assistant("a3", json!([{"type": "text", "text": "hello"}]), "end_turn"),
        ]);
        assert_eq!(turns.len(), 3);
        assert!(!turns[0].from_inline);
        assert!(turns[1].from_inline);
        assert_eq!(turns[1].entries[0].text, "from Inline");
        assert!(turns[2].from_inline);
        assert_eq!(
            turns[2].entries.len(),
            1,
            "a relayed message is not the owner's"
        );
    }

    #[test]
    fn claude_codes_own_input_starts_a_run_owned_by_the_turn_before() {
        let turns = turns(&[
            meta("n1", "<inline-message from_user_id=\"1\" role=\"owner\"/>"),
            user("u1", json!("run it in the background")),
            assistant(
                "a1",
                json!([{"type": "text", "text": "started"}]),
                "end_turn",
            ),
            TranscriptEntry {
                origin: Some("task-notification".to_owned()),
                ..user(
                    "t1",
                    json!("<task-notification><task-id>x</task-id></task-notification>"),
                )
            },
            assistant(
                "a2",
                json!([{"type": "text", "text": "it finished"}]),
                "end_turn",
            ),
        ]);
        assert_eq!(turns.len(), 2);
        assert!(turns[1].from_inline);
        assert_eq!(turns[1].entries.len(), 1);
    }

    #[test]
    fn reminders_commands_and_interruptions_read_as_the_app_shows_them() {
        let turns = turns(&[
            user(
                "u1",
                json!("<system-reminder>linked sessions</system-reminder>\nship it"),
            ),
            user("x1", json!("[Request interrupted by user]")),
            assistant("a1", json!([{"type": "text", "text": "ok"}]), "end_turn"),
            user(
                "u2",
                json!(
                    "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>opus</command-args>"
                ),
            ),
            user(
                "o2",
                json!("<local-command-stdout>Set model</local-command-stdout>"),
            ),
            assistant(
                "a2",
                json!([{"type": "text", "text": "switched"}]),
                "tool_use",
            ),
        ]);
        assert_eq!(turns[0].entries[0].text, "ship it");
        assert_eq!(turns[1].entries[0].text, "/model opus");
        assert!(!turns[1].complete, "the last turn has not ended");
    }

    #[test]
    fn images_are_placeholders() {
        let turns = turns(&[user(
            "u1",
            json!([{"type": "image", "source": {}}, {"type": "text", "text": "what is this"}]),
        )]);
        assert_eq!(turns[0].entries[0].text, "what is this\n[Image]");
    }
}

/// Reads real sessions from this machine's Claude Code store (opt-in):
/// `INLINE_HISTORY_LAB=<session id>[,<id>…] cargo test -p inline-agent-driver-claude --lib history_lab -- --ignored --nocapture`
#[cfg(test)]
#[test]
#[ignore]
fn history_lab() {
    let store = crate::sessions::SessionStore::resolve(&[]).expect("a Claude Code store");
    for id in std::env::var("INLINE_HISTORY_LAB")
        .unwrap_or_default()
        .split(',')
    {
        let entries = store.transcript(id.trim(), None).expect("the session");
        let turns = turns(&entries);
        println!("== {id}: {} entries, {} turns", entries.len(), turns.len());
        for turn in &turns {
            let first = turn
                .entries
                .first()
                .map(|e| e.text.chars().take(60).collect::<String>())
                .unwrap_or_default();
            println!(
                "  {} inline={} complete={} entries={} steps={:?} | {}",
                &turn.id[..8.min(turn.id.len())],
                turn.from_inline,
                turn.complete,
                turn.entries.len(),
                turn.steps,
                first.replace('\n', " ")
            );
        }
    }
}
