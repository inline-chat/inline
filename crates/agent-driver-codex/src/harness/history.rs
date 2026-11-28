//! A Codex thread's conversation as turns, for importing it into Inline.
//!
//! Read with `thread/turns/list` in full-item view, oldest first. Tool work
//! is counted, never copied. A turn Inline delivered carries the bridge's
//! client message id on its user message, so a thread that already shows it
//! can skip it.

use std::collections::HashSet;

use inline_agent_bridge::harness::{HistoryEntry, HistoryRole, HistorySteps, HistoryTurn};
use serde_json::Value;

/// Client message id prefixes the bridge (v1 and v2) puts on its input.
const INLINE_CLIENT_PREFIXES: &[&str] = &["inline-agent-bridge:"];

/// One `Turn` from `thread/turns/list` or `thread/read`.
pub(crate) fn turn(value: &Value) -> Option<HistoryTurn> {
    let id = value.get("id")?.as_str()?.to_owned();
    let started_at = value.get("startedAt").and_then(Value::as_i64);
    let completed_at = value.get("completedAt").and_then(Value::as_i64);
    let status = value.get("status").and_then(Value::as_str).unwrap_or("");
    let complete = status != "inProgress";
    let mut entries = Vec::new();
    let mut steps = HistorySteps::default();
    let mut edited = HashSet::new();
    let mut from_inline = false;
    let reply_at = completed_at.or(started_at);
    for item in value
        .get("items")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let item_id = item.get("id").and_then(Value::as_str).unwrap_or("");
        match item.get("type").and_then(Value::as_str).unwrap_or("") {
            "userMessage" => {
                let client = item.get("clientId").and_then(Value::as_str).unwrap_or("");
                if INLINE_CLIENT_PREFIXES
                    .iter()
                    .any(|prefix| client.starts_with(prefix))
                {
                    from_inline = true;
                }
                let (text, marked) = user_text(item.get("content"));
                from_inline |= marked;
                if !text.is_empty() && !item_id.is_empty() {
                    entries.push(HistoryEntry {
                        role: HistoryRole::User,
                        item_ref: item_id.to_owned(),
                        text,
                        at: started_at,
                    });
                }
            }
            "agentMessage" => {
                let text =
                    without_directives(item.get("text").and_then(Value::as_str).unwrap_or(""));
                let text = text.trim();
                if !text.is_empty() && !item_id.is_empty() {
                    entries.push(HistoryEntry {
                        role: HistoryRole::Assistant,
                        item_ref: item_id.to_owned(),
                        text: text.to_owned(),
                        at: reply_at,
                    });
                }
            }
            "commandExecution" => steps.commands += 1,
            "fileChange" => {
                for change in item
                    .get("changes")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                {
                    let path = change.get("path").and_then(Value::as_str).unwrap_or("");
                    if edited.insert(path.to_owned()) {
                        steps.edits += 1;
                    }
                }
            }
            "webSearch" => steps.web += 1,
            "collabAgentToolCall" => steps.agents += 1,
            "mcpToolCall" | "dynamicToolCall" => steps.tools += 1,
            _ => {}
        }
    }
    Some(HistoryTurn {
        id,
        entries,
        steps,
        started_at,
        ended_at: completed_at.or(started_at),
        from_inline,
        complete,
    })
}

/// The user's words, and whether they carry Inline's envelope.
fn user_text(content: Option<&Value>) -> (String, bool) {
    let mut parts = Vec::new();
    let mut marked = false;
    for input in content.and_then(Value::as_array).into_iter().flatten() {
        match input.get("type").and_then(Value::as_str).unwrap_or("") {
            "text" => {
                let text = input.get("text").and_then(Value::as_str).unwrap_or("");
                if text.contains("<inline-message") || text.contains("<inline-context") {
                    marked = true;
                }
                let text = question_replies(&strip_markup(text));
                if !text.is_empty() {
                    parts.push(text);
                }
            }
            "image" | "localImage" => parts.push("[Image]".to_owned()),
            "audio" | "localAudio" => parts.push("[Audio]".to_owned()),
            _ => {}
        }
    }
    (parts.join("\n"), marked)
}

/// The Codex app's answers to a question card, as question and answer.
fn question_replies(text: &str) -> String {
    const OPEN: &str = "<send_user_message_question_reply>";
    const CLOSE: &str = "</send_user_message_question_reply>";
    let Some(start) = text.find(OPEN) else {
        return text.to_owned();
    };
    let body_start = start + OPEN.len();
    let Some(end) = text[body_start..].find(CLOSE).map(|end| end + body_start) else {
        return text.to_owned();
    };
    let Ok(Value::Array(replies)) = serde_json::from_str::<Value>(text[body_start..end].trim())
    else {
        return text.to_owned();
    };
    let answers: Vec<String> = replies
        .iter()
        .filter_map(|reply| {
            let answer = reply.get("answer").and_then(Value::as_str)?.trim();
            Some(match reply.get("question").and_then(Value::as_str) {
                Some(question) => format!("> {}\n\n{answer}", question.trim()),
                None => answer.to_owned(),
            })
        })
        .collect();
    let mut out = text[..start].to_owned();
    out.push_str(&answers.join("\n\n"));
    out.push_str(&text[end + CLOSE.len()..]);
    out.trim().to_owned()
}

/// Agent text without the Codex app's own UI directives
/// (`::browser-complete{…}` on a line of its own).
fn without_directives(text: &str) -> String {
    text.lines()
        .filter(|line| {
            let line = line.trim();
            !(line.starts_with("::")
                && line.ends_with('}')
                && line[2..].split('{').next().is_some_and(|name| {
                    !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
                }))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// The words without Inline's context blocks and envelope headers.
fn strip_markup(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find("<inline-context") {
        out.push_str(&rest[..start]);
        match rest[start..].find("</inline-context>") {
            Some(end) => rest = &rest[start + end + "</inline-context>".len()..],
            None => {
                rest = "";
                break;
            }
        }
    }
    out.push_str(rest);
    let mut clean = String::with_capacity(out.len());
    let mut rest = out.as_str();
    while let Some(start) = rest.find("<inline-message") {
        clean.push_str(&rest[..start]);
        let tail = &rest[start..];
        let Some(end) = tail.find('>') else {
            rest = "";
            break;
        };
        rest = &tail[end + 1..];
    }
    clean.push_str(rest);
    clean.replace("</inline-message>", "").trim().to_owned()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn a_turn_keeps_prompt_and_prose_and_counts_work() {
        let turn = turn(&json!({
            "id": "t1", "status": "completed", "startedAt": 100, "completedAt": 160,
            "items": [
                {"type": "userMessage", "id": "u1", "clientId": "desktop-1",
                 "content": [{"type": "text", "text": "fix it"}, {"type": "localImage", "path": "/x.png"}]},
                {"type": "reasoning", "id": "r1", "summary": []},
                {"type": "agentMessage", "id": "a1", "text": "Looking.", "phase": "commentary"},
                {"type": "commandExecution", "id": "c1", "command": "ls"},
                {"type": "fileChange", "id": "f1", "changes": [{"path": "/a"}, {"path": "/b"}]},
                {"type": "fileChange", "id": "f2", "changes": [{"path": "/a"}]},
                {"type": "mcpToolCall", "id": "m1"},
                {"type": "agentMessage", "id": "a2", "text": "Done.", "phase": "final_answer"},
            ]
        }))
        .unwrap();
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
                (HistoryRole::User, "fix it\n[Image]"),
                (HistoryRole::Assistant, "Looking."),
                (HistoryRole::Assistant, "Done."),
            ]
        );
        assert_eq!(turn.entries[0].at, Some(100));
        assert_eq!(turn.entries[2].at, Some(160));
        assert_eq!(
            (turn.steps.commands, turn.steps.edits, turn.steps.tools),
            (1, 2, 1)
        );
    }

    #[test]
    fn the_codex_apps_markup_reads_as_words() {
        let turn = turn(&json!({"id": "t", "status": "completed", "items": [
            {"type": "userMessage", "id": "u", "content": [{"type": "text", "text":
                "<send_user_message_question_reply>\n[{\"questionItemId\":\"x\",\"question\":\"Which device?\",\"answer\":\"the Mac\"}]\n</send_user_message_question_reply>"}]},
            {"type": "agentMessage", "id": "a", "text": "Checked.\n\n::browser-complete{title=\"Checked\"}\n\nDone."}]}))
        .unwrap();
        assert_eq!(turn.entries[0].text, "> Which device?\n\nthe Mac");
        assert_eq!(turn.entries[1].text, "Checked.\n\n\nDone.");
    }

    #[test]
    fn inline_input_is_recognized_by_client_id_or_envelope() {
        let by_id = turn(&json!({"id": "t", "status": "completed", "items": [
            {"type": "userMessage", "id": "u", "clientId": "inline-agent-bridge:v2:abc",
             "content": [{"type": "text", "text": "hi"}]}]}))
        .unwrap();
        assert!(by_id.from_inline);
        let by_envelope = turn(&json!({"id": "t", "status": "inProgress", "items": [
            {"type": "userMessage", "id": "u",
             "content": [{"type": "text", "text": "<inline-message from_user_id=\"1\" role=\"owner\"/>"},
                         {"type": "text", "text": "<inline-context untrusted=\"true\">\nearlier\n</inline-context>\nship it"}]}]}))
        .unwrap();
        assert!(by_envelope.from_inline);
        assert!(!by_envelope.complete);
        assert_eq!(by_envelope.entries[0].text, "ship it");
    }
}
