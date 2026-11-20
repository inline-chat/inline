//! `inline listen`: stream the signed-in account's matching events as JSON
//! lines so an agent can wake on a message instead of polling.
//!
//! Events come from `inline-client`'s lossless stream, which recovers gaps
//! through sync. Filters run here, against what the account already
//! receives; no server-side subscription exists. A named listener keeps its
//! store and dedupe watermarks on disk and resumes after the last
//! acknowledged event (at-least-once: a crash before acknowledging replays
//! that event with the same `id`).

use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use chrono::{TimeZone, Utc};
use clap::{Args, ValueEnum};
use inline_client::{
    ClientEvent, ClientIdentity, ClientStatus, ClientStore, ConnectRequest, ConversationKind,
    DialogRecord, DialogsOrder, DialogsRequest, InMemoryStore, InlineClient, InlineId, MediaKind,
    MessageContent, MessageRecord, SdkBackend, SqliteStore, UserRecord,
};
use serde::{Deserialize, Serialize};

use crate::auth::AuthStore;
use crate::config::Config;
use crate::errors::{CliError, ReportedExit};
use crate::message_wait::{WAIT_TIMEOUT_EXIT_CODE, parse_wait_duration};
use crate::output;
use crate::state::LocalDb;

pub(crate) const LISTEN_HELP: &str = r#"Examples:
  inline listen --json                                   new messages to you, any chat
  inline listen --sender-id 42 --json                    anything user 42 posts
  inline listen --chat-id 123 --with-threads --json      a chat and its threads
  inline listen --user-id 42 --once --timeout 2h --json  the next DM from user 42
  inline listen --mentions-me --contains deploy --json
  inline listen --event message.created,reaction.added --chat-id 123 --json
  inline listen --name triage --space-id 7 --json        resumable across restarts

Filters: values of one flag are alternatives (comma-separated or repeated).
Where (--chat-id, --user-id, --space-id) are alternatives too; where, who
(--sender-id) and what (--mentions-me, --contains) must all match. Your own
messages and reactions are skipped unless you pass --include-own.

Output with --json is one compact JSON object per line. The first line is
{"type":"ready",...} once the subscription is live; then one line per event:
  {"type":"message.created","id":"msg:123:456","at":"…","chatId":123,
   "messageId":456,"chat":{…},"from":{…},"message":{"text":"…",…}}
Types: message.created, message.updated, message.deleted, reaction.added,
reaction.removed. message.deleted covers messages sent while listening.
Deduplicate by "id": a named listener may replay its last event after a
crash.

Agents: run it in the background and treat each stdout line as a wake-up, or
pass --once so the process exiting is the signal. --count N stops after N
events. --timeout ends the run; with no event it prints {"type":"timeout"}
and exits 124. Connection drops are retried.

Without --name, events start now. With --name, a listener resumes after its
last delivered event, so nothing sent between runs is missed; one process per
name. To wait again and again, rerun the same named listener:
  inline listen --name inbox --once --json
"#;

#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, ValueEnum, Serialize, Deserialize)]
pub(crate) enum ListenEvent {
    #[value(name = "message.created")]
    #[serde(rename = "message.created")]
    MessageCreated,
    #[value(name = "message.updated")]
    #[serde(rename = "message.updated")]
    MessageUpdated,
    #[value(name = "message.deleted")]
    #[serde(rename = "message.deleted")]
    MessageDeleted,
    #[value(name = "reaction.added")]
    #[serde(rename = "reaction.added")]
    ReactionAdded,
    #[value(name = "reaction.removed")]
    #[serde(rename = "reaction.removed")]
    ReactionRemoved,
}

impl ListenEvent {
    fn name(self) -> &'static str {
        match self {
            Self::MessageCreated => "message.created",
            Self::MessageUpdated => "message.updated",
            Self::MessageDeleted => "message.deleted",
            Self::ReactionAdded => "reaction.added",
            Self::ReactionRemoved => "reaction.removed",
        }
    }
}

#[derive(Args, Debug)]
pub(crate) struct ListenArgs {
    #[arg(
        long = "event",
        short = 'e',
        value_enum,
        value_delimiter = ',',
        default_value = "message.created",
        help = "Event types to deliver"
    )]
    events: Vec<ListenEvent>,

    #[arg(
        long = "chat-id",
        short = 'c',
        value_delimiter = ',',
        value_name = "CHAT_ID",
        help = "Only these chats"
    )]
    chat_ids: Vec<i64>,

    #[arg(
        long = "user-id",
        short = 'u',
        value_delimiter = ',',
        value_name = "USER_ID",
        help = "Only the DM with these users (never creates one)"
    )]
    user_ids: Vec<i64>,

    #[arg(
        long = "space-id",
        value_delimiter = ',',
        value_name = "SPACE_ID",
        help = "Only chats in these spaces"
    )]
    space_ids: Vec<i64>,

    #[arg(
        long,
        help = "With --chat-id, also match threads and subthreads under those chats"
    )]
    with_threads: bool,

    #[arg(
        long = "sender-id",
        value_delimiter = ',',
        value_name = "USER_ID",
        help = "Only messages or reactions by these users"
    )]
    sender_ids: Vec<i64>,

    #[arg(long, help = "Only messages that mention you")]
    mentions_me: bool,

    #[arg(
        long = "contains",
        value_name = "TEXT",
        help = "Only messages whose text or caption contains this, ignoring case (repeat for any of several)"
    )]
    contains: Vec<String>,

    #[arg(long, help = "Also deliver your own messages and reactions")]
    include_own: bool,

    #[arg(
        long,
        help = "Exit after the first matching event (same as --count 1)",
        conflicts_with = "count"
    )]
    once: bool,

    #[arg(long, value_name = "N", help = "Exit after this many matching events")]
    count: Option<u64>,

    #[arg(
        long,
        value_name = "DURATION",
        help = "Stop after this long, e.g. 90s, 30m, 2h (max 24h)"
    )]
    timeout: Option<String>,

    #[arg(
        long,
        value_name = "NAME",
        help = "Durable listener name: resume after the last delivered event across restarts"
    )]
    name: Option<String>,
}

// ---------------------------------------------------------------------------
// Filtering

#[derive(Debug, Default)]
struct Filter {
    events: HashSet<ListenEvent>,
    chat_ids: HashSet<i64>,
    user_ids: HashSet<i64>,
    space_ids: HashSet<i64>,
    with_threads: bool,
    sender_ids: HashSet<i64>,
    mentions_me: bool,
    contains: Vec<String>,
    include_own: bool,
    me: Option<i64>,
}

/// What a filter needs to know about one event.
#[derive(Debug)]
struct Candidate<'a> {
    event: ListenEvent,
    chat_id: i64,
    /// Author of a message or user who reacted; unknown for deletions.
    actor_id: Option<i64>,
    outgoing: bool,
    mentioned: bool,
    text: Option<&'a str>,
}

/// Structural facts about a chat, from the dialog list.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct ChatFacts {
    title: Option<String>,
    kind: ConversationKind,
    peer_user_id: Option<i64>,
    space_id: Option<i64>,
    parent_chat_id: Option<i64>,
    parent_message_id: Option<i64>,
}

impl From<&DialogRecord> for ChatFacts {
    fn from(dialog: &DialogRecord) -> Self {
        Self {
            title: dialog.title.clone(),
            kind: dialog.kind,
            peer_user_id: dialog.peer_user_id.map(InlineId::get),
            space_id: dialog.space_id.map(InlineId::get),
            parent_chat_id: dialog.parent_chat_id.map(InlineId::get),
            parent_message_id: dialog.parent_message_id.map(InlineId::get),
        }
    }
}

enum Scope {
    Match,
    Reject,
    /// Only chat facts can decide.
    NeedsChat,
}

impl Filter {
    fn from_args(args: &ListenArgs, me: Option<i64>) -> Self {
        Self {
            events: args.events.iter().copied().collect(),
            chat_ids: args.chat_ids.iter().copied().collect(),
            user_ids: args.user_ids.iter().copied().collect(),
            space_ids: args.space_ids.iter().copied().collect(),
            with_threads: args.with_threads,
            sender_ids: args.sender_ids.iter().copied().collect(),
            mentions_me: args.mentions_me,
            contains: args
                .contains
                .iter()
                .map(|needle| needle.trim().to_lowercase())
                .filter(|needle| !needle.is_empty())
                .collect(),
            include_own: args.include_own,
            me,
        }
    }

    fn has_scope(&self) -> bool {
        !self.chat_ids.is_empty() || !self.user_ids.is_empty() || !self.space_ids.is_empty()
    }

    /// Cheap checks that need no chat lookup: type, who and what.
    fn matches_without_chat(&self, candidate: &Candidate<'_>) -> bool {
        if !self.events.contains(&candidate.event) {
            return false;
        }
        let own = candidate.outgoing
            || matches!((candidate.actor_id, self.me), (Some(actor), Some(me)) if actor == me);
        let asked_for_self = matches!(
            (candidate.actor_id, self.me),
            (Some(actor), Some(me)) if actor == me && self.sender_ids.contains(&me)
        );
        if own && !self.include_own && !asked_for_self {
            return false;
        }
        if !self.sender_ids.is_empty()
            && !candidate
                .actor_id
                .is_some_and(|actor| self.sender_ids.contains(&actor))
        {
            return false;
        }
        if self.mentions_me && !candidate.mentioned {
            return false;
        }
        if !self.contains.is_empty() {
            let Some(text) = candidate.text else {
                return false;
            };
            let haystack = text.to_lowercase();
            if !self.contains.iter().any(|needle| haystack.contains(needle)) {
                return false;
            }
        }
        true
    }

    fn scope_without_chat(&self, chat_id: i64) -> Scope {
        if !self.has_scope() || self.chat_ids.contains(&chat_id) {
            return Scope::Match;
        }
        if self.user_ids.is_empty() && self.space_ids.is_empty() && !self.with_threads {
            return Scope::Reject;
        }
        Scope::NeedsChat
    }

    fn scope_with_chat(&self, chat_id: i64, chat: Option<&ChatFacts>) -> bool {
        match self.scope_without_chat(chat_id) {
            Scope::Match => true,
            Scope::Reject => false,
            Scope::NeedsChat => chat.is_some_and(|chat| {
                (self.with_threads
                    && chat
                        .parent_chat_id
                        .is_some_and(|parent| self.chat_ids.contains(&parent)))
                    || (chat.kind == ConversationKind::DirectMessage
                        && chat
                            .peer_user_id
                            .is_some_and(|user| self.user_ids.contains(&user)))
                    || chat
                        .space_id
                        .is_some_and(|space| self.space_ids.contains(&space))
            }),
        }
    }
}

// ---------------------------------------------------------------------------
// Replay suppression

/// Snapshot repairs re-store recent history; only messages past a chat's
/// watermark (or, in a chat not seen yet, sent after the floor) are new.
#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Watermarks {
    /// Unix seconds; messages older than this in an unseen chat are history.
    floor: i64,
    chats: HashMap<i64, i64>,
    /// Lowest new message id per chat: the start of what this listener has
    /// seen live. Repairs replay older tombstones as deletions.
    #[serde(default)]
    since: HashMap<i64, i64>,
    #[serde(skip)]
    recent: VecDeque<String>,
    #[serde(skip)]
    recent_set: HashSet<String>,
}

const MAX_TRACKED_CHATS: usize = 20_000;
const MAX_RECENT_IDS: usize = 4_096;
/// Tolerates a server clock slightly behind ours when seeding the floor.
const FLOOR_SLACK_SECONDS: i64 = 5;

impl Watermarks {
    fn starting_now(now: i64) -> Self {
        Self {
            floor: now - FLOOR_SLACK_SECONDS,
            ..Self::default()
        }
    }

    /// Whether a stored message is new, advancing the chat's watermark.
    /// Repairs re-store history oldest first, so an old message must never
    /// pass just because the one before it raised the watermark.
    fn admit_message(&mut self, chat_id: i64, message_id: i64, timestamp: i64) -> bool {
        let fresh = timestamp >= self.floor
            && self
                .chats
                .get(&chat_id)
                .is_none_or(|&seen| message_id > seen);
        let entry = self.chats.entry(chat_id).or_insert(message_id);
        if message_id > *entry {
            *entry = message_id;
        }
        if fresh {
            let since = self.since.entry(chat_id).or_insert(message_id);
            if message_id < *since {
                *since = message_id;
            }
        }
        if self.chats.len() > MAX_TRACKED_CHATS {
            // Rare; drop arbitrary chats rather than grow without bound.
            let excess: Vec<i64> = self
                .chats
                .keys()
                .copied()
                .filter(|id| *id != chat_id)
                .take(self.chats.len() - MAX_TRACKED_CHATS)
                .collect();
            for id in excess {
                self.chats.remove(&id);
                self.since.remove(&id);
            }
        }
        fresh
    }

    /// Whether a deletion concerns a message sent while listening.
    fn admit_deletion(&self, chat_id: i64, message_id: i64) -> bool {
        self.since
            .get(&chat_id)
            .is_some_and(|&since| message_id >= since)
    }

    /// Whether an occurrence id was not delivered recently.
    fn admit_occurrence(&mut self, id: &str) -> bool {
        if self.recent_set.contains(id) {
            return false;
        }
        self.recent_set.insert(id.to_string());
        self.recent.push_back(id.to_string());
        while self.recent.len() > MAX_RECENT_IDS {
            if let Some(old) = self.recent.pop_front() {
                self.recent_set.remove(&old);
            }
        }
        true
    }
}

// ---------------------------------------------------------------------------
// Output

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReadyLine<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    events: Vec<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    user_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<&'a str>,
    resumed: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct TimeoutLine {
    #[serde(rename = "type")]
    kind: &'static str,
    matched: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct EventLine {
    #[serde(rename = "type")]
    kind: &'static str,
    id: String,
    at: String,
    chat_id: i64,
    message_id: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    chat: Option<ChatOut>,
    #[serde(skip_serializing_if = "Option::is_none")]
    from: Option<UserOut>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<MessageOut>,
    #[serde(skip_serializing_if = "Option::is_none")]
    emoji: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ChatOut {
    id: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    peer_user_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    space_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    parent_chat_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    parent_message_id: Option<i64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct UserOut {
    id: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    username: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    is_bot: Option<bool>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct MessageOut {
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    media: Option<MediaOut>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reply_to_message_id: Option<i64>,
    mentioned: bool,
    outgoing: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    service: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    edited_at: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct MediaOut {
    kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    file_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    mime_type: Option<String>,
}

fn rfc3339(unix_seconds: i64) -> String {
    Utc.timestamp_opt(unix_seconds, 0)
        .single()
        .unwrap_or_else(Utc::now)
        .to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn message_text(message: &MessageRecord) -> Option<&str> {
    match &message.content {
        MessageContent::Text { text } => Some(text.as_str()),
        MessageContent::Media { caption, .. } => caption.as_deref(),
        _ => None,
    }
}

fn media_kind(kind: MediaKind) -> &'static str {
    match kind {
        MediaKind::Photo => "photo",
        MediaKind::Video => "video",
        MediaKind::Document => "document",
        MediaKind::Voice => "voice",
        _ => "media",
    }
}

fn message_out(message: &MessageRecord) -> MessageOut {
    let media = match &message.content {
        MessageContent::Media {
            kind,
            file_name,
            mime_type,
            ..
        } => Some(MediaOut {
            kind: media_kind(*kind),
            file_name: file_name.clone(),
            mime_type: mime_type.clone(),
        }),
        _ => None,
    };
    MessageOut {
        text: message_text(message)
            .filter(|text| !text.is_empty())
            .map(str::to_string),
        media,
        reply_to_message_id: message.reply_to_message_id.map(InlineId::get),
        mentioned: message.metadata.mentioned.unwrap_or(false),
        outgoing: message.is_outgoing,
        service: message.metadata.is_service,
        edited_at: message.metadata.edit_timestamp.map(rfc3339),
    }
}

fn chat_out(chat_id: i64, chat: &ChatFacts) -> ChatOut {
    let kind = match chat.kind {
        ConversationKind::DirectMessage => "dm",
        _ if chat.parent_message_id.is_some() => "reply_thread",
        _ if chat.parent_chat_id.is_some() => "subthread",
        ConversationKind::Chat => "chat",
        _ => "unknown",
    };
    ChatOut {
        id: chat_id,
        title: chat.title.clone(),
        kind,
        peer_user_id: chat.peer_user_id,
        space_id: chat.space_id,
        parent_chat_id: chat.parent_chat_id,
        parent_message_id: chat.parent_message_id,
    }
}

fn user_out(user_id: i64, user: Option<&UserRecord>) -> UserOut {
    let name = user.and_then(|user| {
        user.display_name.clone().or_else(|| {
            let joined = [user.first_name.as_deref(), user.last_name.as_deref()]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>()
                .join(" ");
            (!joined.is_empty()).then_some(joined)
        })
    });
    UserOut {
        id: user_id,
        name,
        username: user.and_then(|user| user.username.clone()),
        is_bot: user.and_then(|user| user.is_bot),
    }
}

fn human_line(line: &EventLine) -> String {
    let time = chrono::DateTime::parse_from_rfc3339(&line.at)
        .map(|at| at.with_timezone(&chrono::Local).format("%H:%M").to_string())
        .unwrap_or_default();
    let place = line
        .chat
        .as_ref()
        .and_then(|chat| chat.title.clone())
        .map(|title| format!("#{title}"))
        .unwrap_or_else(|| format!("chat {}", line.chat_id));
    let who = line
        .from
        .as_ref()
        .map(|user| {
            user.name
                .clone()
                .or_else(|| user.username.clone())
                .unwrap_or_else(|| format!("user {}", user.id))
        })
        .unwrap_or_else(|| "someone".to_string());
    let body = match line.kind {
        "message.created" | "message.updated" => {
            let text = line
                .message
                .as_ref()
                .and_then(|message| {
                    message.text.clone().or_else(|| {
                        message
                            .media
                            .as_ref()
                            .map(|media| format!("[{}]", media.kind))
                    })
                })
                .unwrap_or_default();
            let edited = if line.kind == "message.updated" {
                " (edited)"
            } else {
                ""
            };
            format!("{who}{edited}: {}", text.replace('\n', " "))
        }
        "message.deleted" => format!("message {} deleted", line.message_id),
        "reaction.added" => format!(
            "{who} reacted {} to {}",
            line.emoji.as_deref().unwrap_or(""),
            line.message_id
        ),
        _ => format!(
            "{who} removed {} from {}",
            line.emoji.as_deref().unwrap_or(""),
            line.message_id
        ),
    };
    format!(
        "{}  {}  {}",
        output::style_dim(&time),
        output::style_dim(&place),
        body
    )
}

/// Writes one line; `false` when the reader went away.
fn emit(text: &str) -> io::Result<bool> {
    let mut stdout = io::stdout().lock();
    match writeln!(stdout, "{text}").and_then(|()| stdout.flush()) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::BrokenPipe => Ok(false),
        Err(error) => Err(error),
    }
}

// ---------------------------------------------------------------------------
// Durable listener files

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
}

struct NamedListener {
    directory: PathBuf,
    _lock: File,
}

impl NamedListener {
    fn open(
        data_dir: &Path,
        account: &str,
        name: &str,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let directory = data_dir.join("listen").join(account).join(name);
        fs::create_dir_all(&directory)?;
        let lock = File::options()
            .create(true)
            .truncate(false)
            .write(true)
            .open(directory.join("lock"))?;
        match lock.try_lock() {
            Ok(()) => {}
            Err(fs::TryLockError::WouldBlock) => {
                return Err(CliError::invalid_args(format!(
                    "Another `inline listen --name {name}` is already running."
                ))
                .into());
            }
            Err(fs::TryLockError::Error(error)) => return Err(error.into()),
        }
        Ok(Self {
            directory,
            _lock: lock,
        })
    }

    fn store_path(&self) -> PathBuf {
        self.directory.join("client.sqlite")
    }

    fn state_path(&self) -> PathBuf {
        self.directory.join("watermarks.json")
    }

    fn load(&self) -> Option<Watermarks> {
        let bytes = fs::read(self.state_path()).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    fn save(&self, watermarks: &Watermarks) -> io::Result<()> {
        let temporary = self.directory.join("watermarks.json.tmp");
        fs::write(&temporary, serde_json::to_vec(watermarks)?)?;
        fs::rename(temporary, self.state_path())
    }
}

// ---------------------------------------------------------------------------
// Chat and user lookups

const DIALOG_REFRESH_COOLDOWN: Duration = Duration::from_secs(10);

struct Directory {
    client: InlineClient,
    store: Arc<dyn ClientStore>,
    chats: HashMap<i64, Option<ChatFacts>>,
    users: HashMap<i64, UserRecord>,
    last_refresh: Option<tokio::time::Instant>,
}

impl Directory {
    async fn chat(&mut self, chat_id: i64) -> Option<ChatFacts> {
        if let Some(Some(known)) = self.chats.get(&chat_id) {
            return Some(known.clone());
        }
        if let Ok(Some(dialog)) = self.store.dialog(InlineId::new(chat_id)).await {
            let facts = ChatFacts::from(&dialog);
            self.chats.insert(chat_id, Some(facts.clone()));
            return Some(facts);
        }
        // A chat with a new message sorts first, so the newest page has it.
        let due = self
            .last_refresh
            .is_none_or(|at| at.elapsed() >= DIALOG_REFRESH_COOLDOWN);
        if due {
            self.last_refresh = Some(tokio::time::Instant::now());
            if let Ok(page) = self
                .client
                .dialogs(DialogsRequest {
                    limit: Some(50),
                    cursor: None,
                    order: DialogsOrder::RecentActivity,
                })
                .await
            {
                for dialog in &page.dialogs {
                    self.chats
                        .insert(dialog.chat_id.get(), Some(ChatFacts::from(dialog)));
                }
                for user in page.users {
                    self.users.insert(user.user_id.get(), user);
                }
            }
        }
        self.chats.entry(chat_id).or_insert(None).clone()
    }

    async fn user(&mut self, user_id: i64) -> Option<UserRecord> {
        if let Some(user) = self.users.get(&user_id) {
            return Some(user.clone());
        }
        let user = self
            .store
            .user(InlineId::new(user_id))
            .await
            .ok()
            .flatten()?;
        self.users.insert(user_id, user.clone());
        Some(user)
    }
}

// ---------------------------------------------------------------------------
// Event translation

/// One account event reduced to what listen can deliver.
enum Occurrence {
    Message {
        event: ListenEvent,
        message: Box<MessageRecord>,
    },
    Deleted {
        chat_id: i64,
        message_id: i64,
    },
    Reaction {
        chat_id: i64,
        message_id: i64,
        user_id: i64,
        emoji: String,
        removed: bool,
    },
}

impl Occurrence {
    fn id(&self) -> String {
        match self {
            Self::Message {
                event: ListenEvent::MessageUpdated,
                message,
            } => format!(
                "msg:{}:{}:edit:{}",
                message.chat_id.get(),
                message.message_id.get(),
                message
                    .metadata
                    .revision
                    .or(message.metadata.edit_timestamp)
                    .unwrap_or_default()
            ),
            Self::Message { message, .. } => {
                format!("msg:{}:{}", message.chat_id.get(), message.message_id.get())
            }
            Self::Deleted {
                chat_id,
                message_id,
            } => format!("del:{chat_id}:{message_id}"),
            Self::Reaction {
                chat_id,
                message_id,
                user_id,
                emoji,
                removed,
            } => format!(
                "react:{chat_id}:{message_id}:{user_id}:{emoji}:{}",
                if *removed { "removed" } else { "added" }
            ),
        }
    }

    fn candidate(&self) -> Candidate<'_> {
        match self {
            Self::Message { event, message } => Candidate {
                event: *event,
                chat_id: message.chat_id.get(),
                actor_id: Some(message.sender_id.get()),
                outgoing: message.is_outgoing,
                mentioned: message.metadata.mentioned.unwrap_or(false),
                text: message_text(message),
            },
            Self::Deleted { chat_id, .. } => Candidate {
                event: ListenEvent::MessageDeleted,
                chat_id: *chat_id,
                actor_id: None,
                outgoing: false,
                mentioned: false,
                text: None,
            },
            Self::Reaction {
                chat_id,
                user_id,
                removed,
                ..
            } => Candidate {
                event: if *removed {
                    ListenEvent::ReactionRemoved
                } else {
                    ListenEvent::ReactionAdded
                },
                chat_id: *chat_id,
                // The backend reports its own optimistic reactions as user 0.
                actor_id: (*user_id > 0).then_some(*user_id),
                outgoing: *user_id == 0,
                mentioned: false,
                text: None,
            },
        }
    }
}

/// Maps a client event to an occurrence, dropping replayed history.
fn occurrence_for(event: &ClientEvent, watermarks: &mut Watermarks) -> Option<Occurrence> {
    match event {
        ClientEvent::MessageStored { message } => {
            if message.transaction.is_some() {
                return None;
            }
            let chat_id = message.chat_id.get();
            let message_id = message.message_id.get();
            let fresh = watermarks.admit_message(chat_id, message_id, message.timestamp);
            if let Some(edited) = message.metadata.edit_timestamp {
                // An edit to an older message, unless repair re-stored it.
                return (edited >= watermarks.floor).then(|| Occurrence::Message {
                    event: ListenEvent::MessageUpdated,
                    message: Box::new(message.clone()),
                });
            }
            fresh.then(|| Occurrence::Message {
                event: ListenEvent::MessageCreated,
                message: Box::new(message.clone()),
            })
        }
        ClientEvent::MessageDeleted {
            chat_id,
            message_id,
        } => watermarks
            .admit_deletion(chat_id.get(), message_id.get())
            .then(|| Occurrence::Deleted {
                chat_id: chat_id.get(),
                message_id: message_id.get(),
            }),
        ClientEvent::ReactionChanged {
            chat_id,
            message_id,
            user_id,
            reaction,
            removed,
        } => Some(Occurrence::Reaction {
            chat_id: chat_id.get(),
            message_id: message_id.get(),
            user_id: user_id.get(),
            emoji: reaction.clone(),
            removed: *removed,
        }),
        _ => None,
    }
}

async fn render(
    occurrence: &Occurrence,
    chat: Option<&ChatFacts>,
    directory: &mut Directory,
) -> EventLine {
    let candidate = occurrence.candidate();
    let from = match candidate.actor_id {
        Some(actor) => Some(user_out(actor, directory.user(actor).await.as_ref())),
        None => None,
    };
    let chat_id = candidate.chat_id;
    let chat = chat.map(|facts| chat_out(chat_id, facts));
    match occurrence {
        Occurrence::Message { event, message } => EventLine {
            kind: event.name(),
            id: occurrence.id(),
            at: rfc3339(
                message
                    .metadata
                    .edit_timestamp
                    .filter(|_| *event == ListenEvent::MessageUpdated)
                    .unwrap_or(message.timestamp),
            ),
            chat_id,
            message_id: message.message_id.get(),
            chat,
            from,
            message: Some(message_out(message)),
            emoji: None,
        },
        Occurrence::Deleted { message_id, .. } => EventLine {
            kind: ListenEvent::MessageDeleted.name(),
            id: occurrence.id(),
            at: rfc3339(Utc::now().timestamp()),
            chat_id,
            message_id: *message_id,
            chat,
            from: None,
            message: None,
            emoji: None,
        },
        Occurrence::Reaction {
            message_id, emoji, ..
        } => EventLine {
            kind: candidate.event.name(),
            id: occurrence.id(),
            at: rfc3339(Utc::now().timestamp()),
            chat_id,
            message_id: *message_id,
            chat,
            from,
            message: None,
            emoji: Some(emoji.clone()),
        },
    }
}

// ---------------------------------------------------------------------------
// Command

pub(crate) async fn run(
    args: ListenArgs,
    config: &Config,
    auth_store: &AuthStore,
    local_db: &LocalDb,
    json: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(name) = args.name.as_deref()
        && !valid_name(name)
    {
        return Err(
            CliError::invalid_args("--name takes 1-64 letters, digits, '-' or '_'.").into(),
        );
    }
    if args.with_threads && args.chat_ids.is_empty() {
        return Err(CliError::invalid_args("--with-threads needs --chat-id.").into());
    }
    let limit = if args.once { Some(1) } else { args.count };
    if limit == Some(0) {
        return Err(CliError::invalid_args("--count must be at least 1.").into());
    }
    let timeout = args
        .timeout
        .as_deref()
        .map(|raw| parse_wait_duration("--timeout", raw))
        .transpose()
        .map_err(CliError::invalid_args)?;

    let credential = crate::require_owner_credential(auth_store)?;
    let me = match local_db.load()?.current_user.map(|user| user.id) {
        Some(id) => id,
        None => {
            let me = crate::fetch_authenticated_me(config, auth_store).await?;
            let id = me.id;
            local_db.set_current_user(me)?;
            id
        }
    };
    let filter = Filter::from_args(&args, Some(me));
    let account = format!("user-{me}");

    let named = match args.name.as_deref() {
        Some(name) => Some(NamedListener::open(&config.data_dir, &account, name)?),
        None => None,
    };
    let resumed_state = named.as_ref().and_then(NamedListener::load);
    let resumed = resumed_state.is_some();
    let mut watermarks =
        resumed_state.unwrap_or_else(|| Watermarks::starting_now(Utc::now().timestamp()));

    let store: Arc<dyn ClientStore> = match &named {
        Some(named) => Arc::new(SqliteStore::open(named.store_path())?),
        None => Arc::new(InMemoryStore::new()),
    };
    let backend = SdkBackend::builder()
        .api_base_url(config.api_base_url.clone())
        .realtime_url(config.realtime_url.clone())
        .identity(ClientIdentity::new(
            "inline-cli-listen",
            env!("CARGO_PKG_VERSION"),
        ))
        .enable_realtime_handshake()
        .shared_store(store.clone())
        .build()?;
    let client = InlineClient::builder().backend(backend).build().spawn();
    let mut events = client
        .take_lossless_events()
        .ok_or_else(|| io::Error::other("listen event stream was already claimed"))?;
    let mut request =
        ConnectRequest::new(credential).with_account_namespace(format!("cli-listen-{account}"));
    if !resumed {
        request = request.start_after_current();
    }
    if let Err(error) = client.connect(request).await {
        let _ = tokio::time::timeout(Duration::from_secs(3), client.shutdown()).await;
        if let inline_client::ClientRequestError::Backend(backend) = &error
            && backend.category == inline_client::ClientErrorCategory::RateLimited
        {
            // Fresh listeners replay the same catch-up page; the server
            // slows a session that keeps asking for it.
            let retry = backend
                .retry_after_seconds
                .map(|seconds| format!(" Retry in {seconds}s."))
                .unwrap_or_default();
            return Err(CliError {
                code: "rate_limited",
                message: format!("Inline is rate limiting new listeners on this session.{retry}"),
                hint: Some(
                    "To wait repeatedly, reuse one named listener (`--name NAME --once`): it resumes where it stopped instead of starting over."
                        .to_string(),
                ),
                examples: vec!["inline listen --name inbox --once --json".to_string()],
            }
            .into());
        }
        return Err(error.into());
    }
    if let Some(named) = &named {
        named.save(&watermarks)?;
    }

    let mut event_names: Vec<&'static str> =
        filter.events.iter().map(|event| event.name()).collect();
    event_names.sort_unstable();
    if json {
        let ready = ReadyLine {
            kind: "ready",
            events: event_names,
            user_id: Some(me),
            name: args.name.as_deref(),
            resumed,
        };
        if !emit(&serde_json::to_string(&ready)?)? {
            let _ = tokio::time::timeout(Duration::from_secs(3), client.shutdown()).await;
            return Ok(());
        }
    } else {
        eprintln!(
            "{}",
            output::style_dim(&format!(
                "Listening for {}{}. Press Ctrl-C to stop.",
                event_names.join(", "),
                if resumed { " (resumed)" } else { "" }
            ))
        );
    }

    let mut directory = Directory {
        client: client.clone(),
        store,
        chats: HashMap::new(),
        users: HashMap::new(),
        last_refresh: None,
    };
    let deadline = timeout.map(|timeout| tokio::time::Instant::now() + timeout);
    let mut matched: u64 = 0;
    let mut dirty = false;
    let mut last_save = tokio::time::Instant::now();

    let outcome: Result<bool, Box<dyn std::error::Error>> =
        async {
            loop {
                let delivery = tokio::select! {
                    delivery = events.recv_delivery() => delivery,
                    () = sleep_until_or_forever(deadline) => return Ok(false),
                };
                let Some(delivery) = delivery else {
                    return Err(io::Error::other("the Inline connection ended").into());
                };
                match delivery.event() {
                    ClientEvent::StatusChanged {
                        status:
                            ClientStatus::AuthExpired
                            | ClientStatus::LoggedOut
                            | ClientStatus::AuthRequired,
                        ..
                    } => {
                        return Err(CliError::not_authenticated().into());
                    }
                    ClientEvent::StatusChanged {
                        status: ClientStatus::Reconnecting,
                        ..
                    } if !json => eprintln!("{}", output::style_dim("Reconnecting…")),
                    _ => {}
                }

                let occurrence = occurrence_for(delivery.event(), &mut watermarks);
                if matches!(delivery.event(), ClientEvent::MessageStored { .. }) {
                    dirty = true;
                }
                let mut line = None;
                if let Some(occurrence) = occurrence {
                    let candidate = occurrence.candidate();
                    if filter.matches_without_chat(&candidate) {
                        let needs_chat =
                            !matches!(filter.scope_without_chat(candidate.chat_id), Scope::Reject);
                        let chat = if needs_chat {
                            directory.chat(candidate.chat_id).await
                        } else {
                            None
                        };
                        if filter.scope_with_chat(candidate.chat_id, chat.as_ref())
                            && watermarks.admit_occurrence(&occurrence.id())
                        {
                            line = Some(render(&occurrence, chat.as_ref(), &mut directory).await);
                        }
                    }
                }

                if let Some(line) = line {
                    if let Some(named) = &named {
                        named.save(&watermarks)?;
                        dirty = false;
                        last_save = tokio::time::Instant::now();
                    }
                    let text = if json {
                        serde_json::to_string(&line)?
                    } else {
                        human_line(&line)
                    };
                    if !emit(&text)? {
                        return Ok(true);
                    }
                    delivery.ack().await?;
                    matched += 1;
                    if limit.is_some_and(|limit| matched >= limit) {
                        return Ok(true);
                    }
                } else {
                    delivery.ack().await?;
                }

                if dirty
                    && let Some(named) = &named
                    && last_save.elapsed() >= Duration::from_secs(1)
                {
                    named.save(&watermarks)?;
                    dirty = false;
                    last_save = tokio::time::Instant::now();
                }
            }
        }
        .await;

    if let Some(named) = &named {
        let _ = named.save(&watermarks);
    }
    let _ = tokio::time::timeout(Duration::from_secs(3), client.shutdown()).await;

    let finished = outcome?;
    if !finished && matched == 0 {
        if json {
            let _ = emit(&serde_json::to_string(&TimeoutLine {
                kind: "timeout",
                matched,
            })?);
        } else {
            eprintln!(
                "{}",
                output::style_dim("No matching events before the timeout.")
            );
        }
        return Err(ReportedExit(WAIT_TIMEOUT_EXIT_CODE).into());
    }
    Ok(())
}

async fn sleep_until_or_forever(deadline: Option<tokio::time::Instant>) {
    match deadline {
        Some(deadline) => tokio::time::sleep_until(deadline).await,
        None => std::future::pending().await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use inline_client::MessageMetadata;

    fn message(
        chat_id: i64,
        message_id: i64,
        sender_id: i64,
        timestamp: i64,
        text: &str,
    ) -> MessageRecord {
        MessageRecord {
            chat_id: InlineId::new(chat_id),
            message_id: InlineId::new(message_id),
            sender_id: InlineId::new(sender_id),
            timestamp,
            is_outgoing: false,
            content: MessageContent::Text {
                text: text.to_string(),
            },
            reply_to_message_id: None,
            metadata: MessageMetadata::default(),
            transaction: None,
        }
    }

    fn filter(configure: impl FnOnce(&mut Filter)) -> Filter {
        let mut filter = Filter {
            events: [ListenEvent::MessageCreated].into_iter().collect(),
            me: Some(1),
            ..Filter::default()
        };
        configure(&mut filter);
        filter
    }

    fn created(chat_id: i64, sender_id: i64, text: &str) -> Occurrence {
        Occurrence::Message {
            event: ListenEvent::MessageCreated,
            message: Box::new(message(chat_id, 10, sender_id, 1_000, text)),
        }
    }

    #[test]
    fn skips_own_messages_unless_asked() {
        let own = created(5, 1, "hi");
        assert!(!filter(|_| {}).matches_without_chat(&own.candidate()));
        assert!(filter(|f| f.include_own = true).matches_without_chat(&own.candidate()));
        assert!(
            filter(|f| {
                f.sender_ids.insert(1);
            })
            .matches_without_chat(&own.candidate())
        );
        assert!(filter(|_| {}).matches_without_chat(&created(5, 2, "hi").candidate()));
    }

    #[test]
    fn who_and_what_must_all_match() {
        let f = filter(|f| {
            f.sender_ids.insert(42);
            f.contains = vec!["deploy".to_string()];
        });
        assert!(f.matches_without_chat(&created(5, 42, "Ready to DEPLOY?").candidate()));
        assert!(!f.matches_without_chat(&created(5, 42, "lunch?").candidate()));
        assert!(!f.matches_without_chat(&created(5, 43, "deploy").candidate()));
    }

    #[test]
    fn mentions_require_the_mention_flag() {
        let f = filter(|f| f.mentions_me = true);
        let mut occurrence = created(5, 2, "hey");
        assert!(!f.matches_without_chat(&occurrence.candidate()));
        if let Occurrence::Message { message, .. } = &mut occurrence {
            message.metadata.mentioned = Some(true);
        }
        assert!(f.matches_without_chat(&occurrence.candidate()));
    }

    #[test]
    fn scopes_are_alternatives() {
        let f = filter(|f| {
            f.chat_ids.insert(5);
            f.user_ids.insert(42);
            f.with_threads = true;
        });
        assert!(f.scope_with_chat(5, None));
        assert!(!f.scope_with_chat(6, None));
        let dm = ChatFacts {
            kind: ConversationKind::DirectMessage,
            peer_user_id: Some(42),
            ..ChatFacts::default()
        };
        assert!(f.scope_with_chat(6, Some(&dm)));
        let thread = ChatFacts {
            kind: ConversationKind::Chat,
            parent_chat_id: Some(5),
            ..ChatFacts::default()
        };
        assert!(f.scope_with_chat(7, Some(&thread)));
        let other = ChatFacts {
            kind: ConversationKind::Chat,
            parent_chat_id: Some(9),
            ..ChatFacts::default()
        };
        assert!(!f.scope_with_chat(8, Some(&other)));

        let only_chats = filter(|f| {
            f.chat_ids.insert(5);
        });
        assert!(matches!(only_chats.scope_without_chat(6), Scope::Reject));
        let space = filter(|f| {
            f.space_ids.insert(3);
        });
        let in_space = ChatFacts {
            space_id: Some(3),
            ..ChatFacts::default()
        };
        assert!(space.scope_with_chat(11, Some(&in_space)));
        assert!(!space.scope_with_chat(11, None));
    }

    #[test]
    fn repaired_history_is_not_new() {
        let mut marks = Watermarks::starting_now(1_000);
        // A snapshot re-stores an old message in an unseen chat.
        let old = ClientEvent::MessageStored {
            message: message(5, 100, 2, 900, "old"),
        };
        assert!(occurrence_for(&old, &mut marks).is_none());
        let new = ClientEvent::MessageStored {
            message: message(5, 101, 2, 1_001, "new"),
        };
        assert!(occurrence_for(&new, &mut marks).is_some());
        // Repeating it, or anything at or below the watermark, is replay.
        assert!(occurrence_for(&new, &mut marks).is_none());
        let backfill = ClientEvent::MessageStored {
            message: message(5, 99, 2, 1_002, "late"),
        };
        assert!(occurrence_for(&backfill, &mut marks).is_none());
    }

    #[test]
    fn ascending_history_in_a_new_chat_stays_history() {
        let mut marks = Watermarks::starting_now(10_000);
        for id in 1..=5 {
            let old = ClientEvent::MessageStored {
                message: message(9, id, 2, 100 + id, "old"),
            };
            assert!(occurrence_for(&old, &mut marks).is_none(), "message {id}");
        }
        let new = ClientEvent::MessageStored {
            message: message(9, 6, 2, 10_001, "new"),
        };
        assert!(occurrence_for(&new, &mut marks).is_some());
    }

    #[test]
    fn only_deletions_of_messages_seen_live_are_delivered() {
        let mut marks = Watermarks::starting_now(1_000);
        let deleted = |id| ClientEvent::MessageDeleted {
            chat_id: InlineId::new(5),
            message_id: InlineId::new(id),
        };
        // A repair's tombstones for a chat with no live activity yet.
        assert!(occurrence_for(&deleted(40), &mut marks).is_none());
        let new = ClientEvent::MessageStored {
            message: message(5, 100, 2, 1_001, "new"),
        };
        assert!(occurrence_for(&new, &mut marks).is_some());
        assert!(occurrence_for(&deleted(40), &mut marks).is_none());
        assert!(occurrence_for(&deleted(100), &mut marks).is_some());
    }

    #[test]
    fn edits_after_the_floor_are_updates() {
        let mut marks = Watermarks::starting_now(1_000);
        let mut edited = message(5, 50, 2, 500, "fixed typo");
        edited.metadata.edit_timestamp = Some(1_010);
        let occurrence = occurrence_for(
            &ClientEvent::MessageStored {
                message: edited.clone(),
            },
            &mut marks,
        )
        .expect("edit");
        assert_eq!(occurrence.candidate().event, ListenEvent::MessageUpdated);
        edited.metadata.edit_timestamp = Some(400);
        assert!(
            occurrence_for(&ClientEvent::MessageStored { message: edited }, &mut marks).is_none()
        );
    }

    #[test]
    fn occurrence_ids_dedupe() {
        let mut marks = Watermarks::default();
        assert!(marks.admit_occurrence("msg:1:2"));
        assert!(!marks.admit_occurrence("msg:1:2"));
        assert!(marks.admit_occurrence("msg:1:3"));
    }

    #[test]
    fn event_lines_are_compact_camel_case() {
        let occurrence = created(5, 42, "hello");
        let facts = ChatFacts {
            title: Some("Design".to_string()),
            kind: ConversationKind::Chat,
            space_id: Some(3),
            ..ChatFacts::default()
        };
        let line = EventLine {
            kind: "message.created",
            id: occurrence.id(),
            at: rfc3339(0),
            chat_id: 5,
            message_id: 10,
            chat: Some(chat_out(5, &facts)),
            from: Some(user_out(42, None)),
            message: match &occurrence {
                Occurrence::Message { message, .. } => Some(message_out(message)),
                _ => None,
            },
            emoji: None,
        };
        let json = serde_json::to_string(&line).unwrap();
        assert_eq!(
            json,
            r#"{"type":"message.created","id":"msg:5:10","at":"1970-01-01T00:00:00Z","chatId":5,"messageId":10,"chat":{"id":5,"title":"Design","kind":"chat","spaceId":3},"from":{"id":42},"message":{"text":"hello","mentioned":false,"outgoing":false}}"#
        );
    }

    #[test]
    fn names_are_path_safe() {
        assert!(valid_name("triage-1_a"));
        assert!(!valid_name("../x"));
        assert!(!valid_name(""));
    }
}
