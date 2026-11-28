//! Opening a native session from this machine in an Inline thread.
//!
//! The owner picks a session (`/sessions`, or a pasted `codex://threads/…`
//! link, `claude --resume <id>` or bare id). The bridge creates a thread,
//! records the native session as its work, and imports the whole visible
//! conversation through Inline's agent-history sync: the person's words as
//! the owner's messages, the agent's prose as the bot's, at their original
//! times, without unread counts or pushes. A pinned one-line notice opens
//! the thread. Tool calls are summarized in a line per turn, never copied.
//!
//! Sync is idempotent per native item, so an import a restart interrupted
//! finishes on the next pass, and turns taken later in the native app (not
//! Inline's own deliveries, which the thread already shows) are caught up
//! before the thread's work resumes and in a periodic pass while it is idle.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use inline_agent_bridge::ProviderSessionId;
use inline_agent_bridge::harness::{HistoryRole, HistorySteps, HistoryTurn, SessionSummary};
use inline_client::{InlineClient, InlineId, PinMessageRequest};
use inline_protocol::proto;
use uuid::Uuid;

use super::doc::Doc;
use super::limits;
use super::render::Vocabulary;
use super::work::{ActionData, Agent};

/// The pinned notice's item identity, one per imported thread.
pub(crate) const NOTICE_REF: &str = "inline-import:notice";
/// Inline takes at most this many history operations per call.
const SYNC_BATCH: usize = 100;
/// Sessions per picker page.
pub(crate) const PICKER_PAGE: u32 = 8;
/// A part of a long message, below Inline's text limit with room to spare.
const PART_UTF16: usize = 60_000;
/// Catch-up also resends turns that ended this close before the last pass,
/// so one still running then is completed.
const CATCH_UP_SLACK_SECONDS: i64 = 15 * 60;

/// One Inline message an import writes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Row {
    pub role: HistoryRole,
    pub item_ref: String,
    pub text: String,
    /// Unix seconds.
    pub at: i64,
    pub complete: bool,
}

/// The rows for `turns`, oldest first: each person's message as its own
/// row, the agent's prose between them as one row with the turn's work in a
/// closing line. `skip_inline` leaves out turns Inline delivered.
pub(crate) fn rows(turns: &[HistoryTurn], skip_inline: bool, fallback_at: i64) -> Vec<Row> {
    let mut rows = Vec::new();
    let mut last_at = 0;
    for turn in turns {
        if skip_inline && turn.from_inline {
            continue;
        }
        let first_row = rows.len();
        let mut reply: Option<Row> = None;
        let mut at_of = |at: Option<i64>| {
            let at = at
                .or(turn.ended_at)
                .or(turn.started_at)
                .unwrap_or(fallback_at)
                .max(last_at);
            last_at = at;
            at
        };
        for entry in &turn.entries {
            match entry.role {
                HistoryRole::User => {
                    if let Some(reply) = reply.take() {
                        rows.push(reply);
                    }
                    rows.push(Row {
                        role: HistoryRole::User,
                        item_ref: entry.item_ref.clone(),
                        text: entry.text.clone(),
                        at: at_of(entry.at),
                        complete: turn.complete,
                    });
                }
                HistoryRole::Assistant => {
                    let at = at_of(entry.at);
                    match &mut reply {
                        Some(reply) => {
                            reply.text.push_str("\n\n");
                            reply.text.push_str(&entry.text);
                            reply.at = at;
                        }
                        None => {
                            reply = Some(Row {
                                role: HistoryRole::Assistant,
                                item_ref: entry.item_ref.clone(),
                                text: entry.text.clone(),
                                at,
                                complete: turn.complete,
                            });
                        }
                    }
                }
            }
        }
        if let Some(summary) = steps_line(&turn.steps) {
            let footer = format!("_{summary}_");
            match &mut reply {
                Some(reply) => {
                    reply.text.push_str("\n\n");
                    reply.text.push_str(&footer);
                }
                None => {
                    reply = Some(Row {
                        role: HistoryRole::Assistant,
                        item_ref: format!("inline-import:steps:{}", turn.id),
                        text: footer,
                        at: at_of(turn.ended_at),
                        complete: turn.complete,
                    });
                }
            }
        }
        if let Some(reply) = reply {
            rows.push(reply);
        }
        // A turn whose prose is still growing is not final.
        for row in &mut rows[first_row..] {
            row.complete = turn.complete;
        }
    }
    rows.into_iter().flat_map(split).collect()
}

/// Rows of turns worth sending again on a catch-up: those that ended near or
/// after the last pass, and any still running.
pub(crate) fn recent(turns: Vec<HistoryTurn>, seen_at: Option<i64>) -> Vec<HistoryTurn> {
    let Some(seen_at) = seen_at else {
        return turns;
    };
    let since = seen_at - CATCH_UP_SLACK_SECONDS;
    turns
        .into_iter()
        .filter(|turn| {
            !turn.complete
                || turn
                    .ended_at
                    .or(turn.started_at)
                    .is_none_or(|at| at >= since)
        })
        .collect()
}

/// "Ran 3 commands · edited 2 files", in the order the apps list work.
pub(crate) fn steps_line(steps: &HistorySteps) -> Option<String> {
    if steps.is_empty() {
        return None;
    }
    let mut parts = Vec::new();
    let mut add = |count: u32, one: &str, many: &str| {
        if count > 0 {
            parts.push(if count == 1 {
                one.to_owned()
            } else {
                many.replace('#', &count.to_string())
            });
        }
    };
    add(steps.commands, "ran 1 command", "ran # commands");
    add(steps.edits, "edited 1 file", "edited # files");
    add(steps.reads, "read 1 file", "read # files");
    add(steps.searches, "1 search", "# searches");
    add(steps.web, "1 web lookup", "# web lookups");
    add(steps.agents, "1 agent", "# agents");
    add(steps.tools, "1 tool call", "# tool calls");
    let mut line = parts.join(" · ");
    if let Some(first) = line.get(..1) {
        line = first.to_uppercase() + &line[1..];
    }
    Some(line)
}

/// Splits a row too long for one Inline message at line breaks, closing and
/// reopening a code fence it cuts through. Later parts get their own item
/// identities.
fn split(row: Row) -> Vec<Row> {
    if row.text.encode_utf16().count() <= PART_UTF16 && row.text.len() <= limits::MAX_TEXT_BYTES / 2
    {
        return vec![row];
    }
    let mut parts: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut units = 0;
    let mut fence: Option<String> = None;
    for line in row.text.split_inclusive('\n') {
        let line_units = line.encode_utf16().count();
        if units + line_units > PART_UTF16 && !current.is_empty() {
            if let Some(open) = &fence {
                current.push_str("\n```\n");
                parts.push(std::mem::take(&mut current));
                current.push_str(open);
                current.push('\n');
            } else {
                parts.push(std::mem::take(&mut current));
            }
            units = current.encode_utf16().count();
        }
        // A single line longer than a part is cut by characters.
        if line_units > PART_UTF16 {
            let mut chunk = String::new();
            for character in line.chars() {
                if chunk.encode_utf16().count() + character.len_utf16() > PART_UTF16 {
                    parts.push(std::mem::take(&mut chunk));
                }
                chunk.push(character);
            }
            current.push_str(&chunk);
            units = current.encode_utf16().count();
            continue;
        }
        let trimmed = line.trim_start();
        if trimmed.starts_with("```") {
            fence = match fence {
                Some(_) => None,
                None => Some(trimmed.trim_end().to_owned()),
            };
        }
        current.push_str(line);
        units += line_units;
    }
    if !current.is_empty() {
        parts.push(current);
    }
    parts
        .into_iter()
        .enumerate()
        .map(|(index, text)| Row {
            item_ref: if index == 0 {
                row.item_ref.clone()
            } else {
                format!("{}#part{}", row.item_ref, index + 1)
            },
            text: text.trim().to_owned(),
            ..row.clone()
        })
        .filter(|row| !row.text.is_empty())
        .collect()
}

/// The one-line notice that opens an imported thread.
pub(crate) fn notice(vocabulary: Vocabulary, folder: Option<&Path>) -> String {
    let product = vocabulary.product();
    let place = folder
        .map(|folder| format!(" in `{}`", super::workspaces::label(folder)))
        .unwrap_or_default();
    format!(
        "Imported from {product}{place}. Continue here; turns you take in {product} sync in when this thread picks up again."
    )
}

/// What a sync wrote.
#[derive(Debug, Default)]
pub(crate) struct Synced {
    /// Item identity → Inline message.
    pub messages: HashMap<String, i64>,
    pub created: usize,
}

/// Writes `rows` as the work's history, in order. Rows already in Inline are
/// left alone or updated in place; one the owner deleted stays deleted.
pub(crate) async fn sync(
    bot: &InlineClient,
    agent_session_id: i64,
    rows: &[Row],
) -> Result<Synced, String> {
    let mut synced = Synced::default();
    for batch in rows.chunks(SYNC_BATCH) {
        let mut operations: Vec<proto::AgentSessionMessageSync> =
            batch.iter().map(|row| operation(row, None)).collect();
        // A row that changed since it was imported (a turn that was still
        // running) is rewritten over the revision Inline holds.
        for attempt in 0..2 {
            let result = bot
                .sync_agent_session_messages(proto::SyncAgentSessionMessagesInput {
                    agent_session_id,
                    mode: proto::AgentSessionSyncMode::History as i32,
                    messages: operations.clone(),
                })
                .await
                .map_err(|error| format!("Inline did not take the history: {error}"))?;
            if result.messages.len() != operations.len() {
                return Err("Inline returned an incomplete history result".to_owned());
            }
            let mut retry = Vec::new();
            for outcome in result.messages {
                let index = usize::try_from(outcome.index).unwrap_or(usize::MAX);
                let Some(sent) = operations.get(index) else {
                    return Err("Inline returned a history result out of range".to_owned());
                };
                let item_ref = sent.item_ref.clone().unwrap_or_default();
                if let Some(message_id) = outcome.message_id {
                    synced.messages.insert(item_ref.clone(), message_id);
                }
                use proto::AgentSessionMessageSyncState as State;
                match State::try_from(outcome.state) {
                    Ok(State::Created) => synced.created += 1,
                    Ok(
                        State::Edited
                        | State::Linked
                        | State::Unchanged
                        | State::Stale
                        | State::Tombstoned,
                    ) => {}
                    Ok(State::Conflict)
                        if attempt == 0 && outcome.current_revision_ref.is_some() =>
                    {
                        let mut again = sent.clone();
                        again.base_revision_ref = outcome.current_revision_ref.clone();
                        retry.push(again);
                    }
                    _ => {
                        log::warn!(
                            target: "inline::bridge::v2",
                            "history row conflicted with Inline's copy; kept Inline's"
                        );
                    }
                }
            }
            if retry.is_empty() {
                break;
            }
            operations = retry;
        }
    }
    Ok(synced)
}

fn operation(row: &Row, base: Option<String>) -> proto::AgentSessionMessageSync {
    let role = match row.role {
        HistoryRole::User => proto::AgentSessionMessageRole::User,
        HistoryRole::Assistant => proto::AgentSessionMessageRole::Assistant,
    };
    proto::AgentSessionMessageSync {
        role: role as i32,
        item_ref: Some(row.item_ref.clone()),
        correlation_ref: None,
        source_date: Some(row.at),
        revision_ref: Some(Uuid::new_v5(&Uuid::NAMESPACE_OID, row.text.as_bytes()).to_string()),
        base_revision_ref: base,
        complete: row.complete,
        operation: Some(proto::agent_session_message_sync::Operation::Upsert(
            proto::AgentSessionMessageUpsert {
                text: row.text.clone(),
                entities: None,
                assistant_random_id: None,
            },
        )),
    }
}

/// Where an import or catch-up stands after a pass.
#[derive(Debug)]
pub(crate) struct Pass {
    pub created: usize,
}

/// One pass over a thread's import, one at a time per thread: the first
/// import (or the rest of one a restart cut short), else a catch-up with what
/// the native app added since. `None` when the thread imports nothing.
pub(crate) async fn pass(
    agent: &Agent,
    chat_id: i64,
    folder: Option<&Path>,
) -> Result<Option<Pass>, String> {
    let lock = chat_lock(chat_id);
    let _one_at_a_time = lock.lock().await;
    let Some(record) = agent
        .ledger
        .import_of(chat_id)
        .map_err(|error| error.to_string())?
    else {
        return Ok(None);
    };
    let session =
        ProviderSessionId::new(record.session_ref.clone()).map_err(|error| error.to_string())?;
    let (first, seen_at, agent_session_id) =
        (!record.ready, record.seen_at, record.agent_session_id);
    let summary = agent
        .harness
        .session(&session)
        .await
        .map_err(|error| error.to_string())?;
    let updated_at = summary.as_ref().and_then(|summary| summary.updated_at);
    if !first && updated_at.is_some() && updated_at == seen_at {
        return Ok(Some(Pass { created: 0 }));
    }
    let turns = agent
        .harness
        .history(&session, folder)
        .await
        .map_err(|error| error.to_string())?;
    let now = now_seconds();
    let turns = if first { turns } else { recent(turns, seen_at) };
    let mut rows = rows(&turns, !first, now);
    if first {
        let at = rows.first().map_or(now, |row| row.at);
        rows.insert(
            0,
            Row {
                role: HistoryRole::Assistant,
                item_ref: NOTICE_REF.to_owned(),
                text: notice(agent.vocabulary, folder),
                at,
                complete: true,
            },
        );
    }
    let synced = if rows.is_empty() {
        Synced::default()
    } else {
        sync(&agent.bot, agent_session_id, &rows).await?
    };
    if first
        && let Some(notice) = synced.messages.get(NOTICE_REF)
        && let Err(error) = agent
            .bot
            .pin_message(PinMessageRequest {
                chat_id: InlineId::new(chat_id),
                message_id: InlineId::new(*notice),
                unpin: false,
            })
            .await
    {
        log::warn!(target: "inline::bridge::v2", "import notice pin failed chat={chat_id}: {error}");
    }
    agent
        .ledger
        .imported(chat_id, updated_at)
        .map_err(|error| error.to_string())?;
    if synced.created > 0 {
        log::info!(
            target: "inline::bridge::v2",
            "imported history chat={chat_id} rows={} first={first}",
            synced.created
        );
    }
    Ok(Some(Pass {
        created: synced.created,
    }))
}

/// The lock that keeps one pass at a time on a thread.
fn chat_lock(chat_id: i64) -> std::sync::Arc<tokio::sync::Mutex<()>> {
    static LOCKS: std::sync::OnceLock<
        std::sync::Mutex<HashMap<i64, std::sync::Arc<tokio::sync::Mutex<()>>>>,
    > = std::sync::OnceLock::new();
    LOCKS
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .entry(chat_id)
        .or_default()
        .clone()
}

/// A native session the owner pasted: `codex://threads/<id>` (Codex's Copy
/// link), `claude --resume <id>` / `codex resume <id>`, or the id alone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Pasted {
    pub id: String,
    /// A link or resume command, which can only mean the session. A bare id
    /// might mean anything, so it opens only when such a session exists.
    pub explicit: bool,
}

pub(crate) fn pasted_session(text: &str, vocabulary: Vocabulary) -> Option<Pasted> {
    let text = text.trim();
    let explicit = |id: &str| {
        is_session_id(id).then(|| Pasted {
            id: id.to_owned(),
            explicit: true,
        })
    };
    if text.contains(char::is_whitespace) {
        let mut words = text.split_whitespace();
        let (first, second, third) = (words.next()?, words.next()?, words.next());
        if words.next().is_some() {
            return None;
        }
        return match (vocabulary, first, second, third) {
            (Vocabulary::Claude, "claude", "--resume" | "-r", Some(id)) => explicit(id),
            (Vocabulary::Codex, "codex", "resume", Some(id)) => explicit(id),
            _ => None,
        };
    }
    if let Some(rest) = text.strip_prefix("codex://threads/") {
        if vocabulary != Vocabulary::Codex {
            return None;
        }
        return explicit(rest.split(['?', '#', '/']).next()?);
    }
    is_session_id(text).then(|| Pasted {
        id: text.to_owned(),
        explicit: false,
    })
}

/// Claude Code and Codex name sessions with UUIDs.
fn is_session_id(text: &str) -> bool {
    Uuid::parse_str(text).is_ok() && text.len() == 36
}

/// The picker: a numbered list with each session's folder and age, and a
/// button per session.
pub(crate) fn picker(
    vocabulary: Vocabulary,
    sessions: &[SessionSummary],
    offset: usize,
    more: bool,
    now: i64,
) -> (Doc, Option<proto::MessageActions>) {
    let product = vocabulary.product();
    if sessions.is_empty() {
        return (
            Doc::markdown(&format!(
                "No {product} sessions on this machine yet. Start one in {product}, then send /sessions again."
            )),
            None,
        );
    }
    let mut text = format!(
        "**Open a {product} session here.** It comes with its whole conversation and keeps syncing.\n"
    );
    let mut rows = Vec::new();
    for (index, session) in sessions.iter().enumerate() {
        let number = offset + index + 1;
        let title = session_title(session);
        let mut details = Vec::new();
        if let Some(folder) = &session.folder {
            details.push(format!("`{}`", super::workspaces::label(folder)));
        }
        if let Some(updated) = session.updated_at {
            details.push(ago(now, updated));
        }
        if session.held_by.is_some() {
            details.push(format!("open in {product}"));
        }
        text.push_str(&format!("\n{number}. **{}**", escape(&title)));
        if !details.is_empty() {
            text.push_str(&format!(" — {}", details.join(" · ")));
        }
        rows.push(proto::MessageActionRow {
            actions: vec![callback(
                &format!("{number}. {title}"),
                &ActionData::OpenSession {
                    s: session.key.session.to_string(),
                },
                index,
            )],
        });
    }
    if more {
        rows.push(proto::MessageActionRow {
            actions: vec![callback(
                "More sessions",
                &ActionData::MoreSessions {
                    o: offset + sessions.len(),
                },
                sessions.len(),
            )],
        });
    }
    (Doc::markdown(&text), Some(proto::MessageActions { rows }))
}

fn callback(label: &str, data: &ActionData, index: usize) -> proto::MessageAction {
    proto::MessageAction {
        action_id: format!("v2-s{index}"),
        text: super::work::button_text(label),
        action: Some(proto::message_action::Action::Callback(
            proto::MessageActionCallback {
                data: serde_json::to_vec(data).unwrap_or_default(),
            },
        )),
        style: proto::message_action::Style::Default as i32,
        ..Default::default()
    }
}

/// A session's title as its app lists it, else its first words.
pub(crate) fn session_title(session: &SessionSummary) -> String {
    let title = session
        .title
        .as_deref()
        .or(session.preview.as_deref())
        .unwrap_or("Untitled session");
    let line = title
        .lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("Untitled session");
    let line = line.trim();
    if line.chars().count() > 80 {
        let mut short: String = line.chars().take(79).collect();
        short.push('…');
        short
    } else {
        line.to_owned()
    }
}

fn escape(text: &str) -> String {
    text.replace('*', "\\*")
        .replace('_', "\\_")
        .replace('`', "\\`")
}

fn ago(now: i64, then: i64) -> String {
    let seconds = (now - then).max(0);
    match seconds {
        0..60 => "just now".to_owned(),
        60..3_600 => format!("{}m ago", seconds / 60),
        3_600..86_400 => format!("{}h ago", seconds / 3_600),
        _ => format!("{}d ago", seconds / 86_400),
    }
}

/// The folder an opened session works in: its own, when it is on this
/// machine.
pub(crate) fn session_folder(session: &SessionSummary) -> Option<PathBuf> {
    session.folder.clone().filter(|folder| folder.is_dir())
}

fn now_seconds() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs() as i64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use inline_agent_bridge::harness::HistoryEntry;

    use super::*;

    fn entry(role: HistoryRole, item_ref: &str, text: &str, at: i64) -> HistoryEntry {
        HistoryEntry {
            role,
            item_ref: item_ref.to_owned(),
            text: text.to_owned(),
            at: Some(at),
        }
    }

    fn turn(id: &str, entries: Vec<HistoryEntry>, inline: bool) -> HistoryTurn {
        HistoryTurn {
            id: id.to_owned(),
            entries,
            from_inline: inline,
            complete: true,
            ..HistoryTurn::default()
        }
    }

    #[test]
    fn a_turn_is_the_prompt_then_one_reply_with_its_work() {
        let mut first = turn(
            "t1",
            vec![
                entry(HistoryRole::User, "u1", "fix it", 100),
                entry(HistoryRole::Assistant, "a1", "Looking.", 110),
                entry(HistoryRole::Assistant, "a2", "Fixed.", 120),
            ],
            false,
        );
        first.steps.commands = 3;
        first.steps.edits = 1;
        let rows = rows(&[first], false, 0);
        assert_eq!(rows.len(), 2);
        assert_eq!(
            (rows[0].role, rows[0].text.as_str(), rows[0].at),
            (HistoryRole::User, "fix it", 100)
        );
        assert_eq!(rows[1].item_ref, "a1");
        assert_eq!(
            rows[1].text,
            "Looking.\n\nFixed.\n\n_Ran 3 commands · edited 1 file_"
        );
        assert_eq!(rows[1].at, 120);
    }

    #[test]
    fn a_catch_up_leaves_out_what_inline_delivered() {
        let turns = [
            turn(
                "t1",
                vec![entry(HistoryRole::User, "u1", "from Inline", 100)],
                true,
            ),
            turn(
                "t2",
                vec![entry(HistoryRole::User, "u2", "from the app", 200)],
                false,
            ),
        ];
        let rows = rows(&turns, true, 0);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].item_ref, "u2");
    }

    #[test]
    fn work_without_prose_still_shows_and_times_never_go_back() {
        let mut quiet = turn("t2", vec![], false);
        quiet.steps.commands = 1;
        quiet.ended_at = Some(50);
        let rows = rows(
            &[
                turn("t1", vec![entry(HistoryRole::User, "u1", "go", 100)], false),
                quiet,
            ],
            false,
            0,
        );
        assert_eq!(rows[1].item_ref, "inline-import:steps:t2");
        assert_eq!(rows[1].text, "_Ran 1 command_");
        assert_eq!(
            rows[1].at, 100,
            "a row is never dated before the one above it"
        );
    }

    #[test]
    fn a_running_turn_is_not_final() {
        let mut running = turn("t1", vec![entry(HistoryRole::User, "u1", "go", 1)], false);
        running.complete = false;
        assert!(!rows(&[running], false, 0)[0].complete);
    }

    #[test]
    fn long_replies_split_at_lines_and_keep_code_fenced() {
        let mut text = String::from("```rust\n");
        let line = "x".repeat(1000) + "\n";
        for _ in 0..130 {
            text.push_str(&line);
        }
        text.push_str("```\nafter");
        let parts = split(Row {
            role: HistoryRole::Assistant,
            item_ref: "a".to_owned(),
            text,
            at: 1,
            complete: true,
        });
        assert_eq!(parts.len(), 3);
        assert_eq!(parts[1].item_ref, "a#part2");
        for part in &parts {
            assert!(part.text.encode_utf16().count() <= PART_UTF16 + 16);
            assert_eq!(
                part.text.matches("```").count() % 2,
                0,
                "{}",
                &part.text[..20]
            );
        }
    }

    #[test]
    fn catch_up_resends_only_recent_or_running_turns() {
        let mut old = turn("old", vec![], false);
        old.ended_at = Some(1_000);
        let mut new = turn("new", vec![], false);
        new.ended_at = Some(10_000);
        let mut running = turn("running", vec![], false);
        running.ended_at = Some(1_000);
        running.complete = false;
        let kept: Vec<_> = recent(vec![old, new, running], Some(10_000))
            .into_iter()
            .map(|turn| turn.id)
            .collect();
        assert_eq!(kept, ["new", "running"]);
    }

    #[test]
    fn pasted_handles_name_a_session_only_in_their_own_forms() {
        let id = "01a21edc-1d27-7b43-baa9-bb9acabf1e49";
        let found = |text: &str, vocabulary| {
            pasted_session(text, vocabulary).map(|pasted| (pasted.id, pasted.explicit))
        };
        let explicit = Some((id.to_owned(), true));
        assert_eq!(
            found(&format!("codex://threads/{id}?hostId=x"), Vocabulary::Codex),
            explicit
        );
        assert_eq!(
            found(&format!("codex://threads/{id}"), Vocabulary::Claude),
            None
        );
        assert_eq!(
            found(&format!("claude --resume {id}"), Vocabulary::Claude),
            explicit
        );
        assert_eq!(
            found(&format!("codex resume {id}"), Vocabulary::Codex),
            explicit
        );
        assert_eq!(
            found(&format!("  {id} "), Vocabulary::Claude),
            Some((id.to_owned(), false))
        );
        assert_eq!(found(&format!("look at {id}"), Vocabulary::Claude), None);
        assert_eq!(found("hello", Vocabulary::Claude), None);
    }

    #[test]
    fn the_steps_line_reads_like_the_apps() {
        let steps = HistorySteps {
            commands: 1,
            reads: 2,
            tools: 3,
            ..HistorySteps::default()
        };
        assert_eq!(
            steps_line(&steps).unwrap(),
            "Ran 1 command · read 2 files · 3 tool calls"
        );
        assert_eq!(steps_line(&HistorySteps::default()), None);
    }
}

/// Previews what importing real sessions on this machine would post
/// (opt-in, read-only): `INLINE_IMPORT_LAB=claude:<id>,codex:<id>
/// INLINE_IMPORT_OUT=<file.md> cargo test -p inline-cli --bin inline
/// import_lab -- --ignored --nocapture`.
#[cfg(test)]
#[tokio::test]
#[ignore = "reads this machine's Claude Code and Codex sessions"]
async fn import_lab() {
    use inline_agent_bridge::harness::HarnessDriver;
    use std::fmt::Write as _;
    let mut out = String::new();
    for spec in std::env::var("INLINE_IMPORT_LAB")
        .unwrap_or_default()
        .split(',')
    {
        let Some((kind, id)) = spec.trim().split_once(':') else {
            continue;
        };
        let turns = match kind {
            "claude" => {
                let store = inline_agent_driver_claude::SessionStore::resolve(&[]).unwrap();
                inline_agent_driver_claude::history::turns(&store.transcript(id, None).unwrap())
            }
            "codex" => {
                let harness = inline_agent_driver_codex::harness::CodexHarness::new(
                    inline_agent_driver_codex::harness::CodexHarnessConfig {
                        launch: inline_agent_driver_codex::CodexLaunchConfig {
                            executable: std::env::var("INLINE_IMPORT_CODEX")
                                .unwrap_or_else(|_| "codex".to_owned())
                                .into(),
                            ..Default::default()
                        },
                        source: inline_agent_bridge::harness::ExecutableSource::Path,
                        pinned_sha256: None,
                        bridge_version: env!("CARGO_PKG_VERSION").to_owned(),
                        cache_root: std::env::temp_dir().join("inline-import-lab"),
                    },
                );
                harness
                    .history(&ProviderSessionId::new(id.to_owned()).unwrap(), None)
                    .await
                    .unwrap()
            }
            _ => continue,
        };
        let rows = rows(&turns, false, now_seconds());
        let _ = writeln!(
            out,
            "# {kind} {id}: {} turns, {} rows\n",
            turns.len(),
            rows.len()
        );
        for row in &rows {
            let who = match row.role {
                HistoryRole::User => "Owner",
                HistoryRole::Assistant => "Bot",
            };
            let when = chrono::DateTime::from_timestamp(row.at, 0)
                .map(|time| time.format("%Y-%m-%d %H:%M").to_string())
                .unwrap_or_default();
            let _ = writeln!(out, "---\n**{who}** · {when}\n\n{}\n", row.text);
        }
    }
    match std::env::var("INLINE_IMPORT_OUT") {
        Ok(path) => std::fs::write(path, out).unwrap(),
        Err(_) => println!("{out}"),
    }
}
