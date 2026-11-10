//! The Dots connector for `inline-relay`.

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::time::Duration;

use inline_relay::{
    BoxFuture, Capabilities, Confirmation, ConfirmationAnswer, ConfirmationStatus, Connector,
    ConnectorError, ConnectorEvent, ConnectorHealth, ConnectorResult, FailureKind, FileData,
    OutboundMessage, RemoteFile, RemoteMessage, Speaker, TaskUpdate,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::sync::{Mutex, mpsc};
use tokio::time::Instant;

use crate::client::{DotsClient, MAX_FILE_BYTES, MessageQuery, SendMessage};
use crate::error::DotsError;
use crate::realtime::{self, RealtimePolicy, Signal};
use crate::types::{Decision, Elicitation, Message, TaskSummary};

const PAGE: u32 = 32;
const OVERLAP: usize = 33;
const MAX_PAGES_PER_POLL: usize = 20;
const CHECKPOINT_VERSION: u32 = 1;

/// Tunables; production defaults.
#[derive(Clone, Debug)]
pub struct ConnectorSettings {
    /// Use the realtime socket.
    pub realtime: bool,
    /// Which socket URLs to accept.
    pub realtime_policy: RealtimePolicy,
    /// Poll interval while the socket is subscribed.
    pub poll_with_socket: Duration,
    /// Poll interval without the socket.
    pub poll_without_socket: Duration,
}

impl Default for ConnectorSettings {
    fn default() -> Self {
        Self {
            realtime: true,
            realtime_policy: RealtimePolicy::default(),
            poll_with_socket: Duration::from_secs(30),
            poll_without_socket: Duration::from_secs(3),
        }
    }
}

/// The verified Dot room.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DotRoom {
    /// Room id.
    pub room_id: String,
    /// Dot aeon id.
    pub aeon_id: String,
    /// Dot sender id.
    pub dot_member: String,
    /// Owner sender id.
    pub owner_member: String,
    /// Dot name.
    pub name: String,
    /// Paused by the owner or by OpenAI.
    pub paused: bool,
    /// Rendered avatar URL.
    pub avatar_url: Option<String>,
}

/// Durable sync position. Serialized as the relay checkpoint.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncState {
    /// Format version.
    pub v: u32,
    /// Room this state belongs to.
    pub room_id: String,
    /// Newest message at link time; never mirrored.
    pub baseline_id: Option<String>,
    /// Creation time of the baseline; anything older is never mirrored.
    pub linked_at: Option<String>,
    /// Most recent delivered ids, oldest first. Polls restart from the
    /// oldest so recent edits and reactions are seen again.
    pub recent: VecDeque<String>,
}

impl SyncState {
    fn remember(&mut self, id: &str) {
        if self.recent.iter().any(|known| known == id) {
            return;
        }
        self.recent.push_back(id.to_owned());
        while self.recent.len() > OVERLAP {
            self.recent.pop_front();
        }
    }

    fn resume_after(&self) -> Option<String> {
        self.recent
            .front()
            .cloned()
            .or_else(|| self.baseline_id.clone())
    }
}

struct TaskTrack {
    last: Option<TaskSummary>,
    due: Instant,
    interval: Duration,
    failures: u32,
}

/// ChatGPT Dots connector.
pub struct DotsConnector {
    client: DotsClient,
    settings: ConnectorSettings,
    room: Mutex<Option<DotRoom>>,
    sync: Mutex<SyncState>,
}

impl std::fmt::Debug for DotsConnector {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("DotsConnector")
    }
}

impl DotsConnector {
    /// Builds a connector.
    pub fn new(client: DotsClient, settings: ConnectorSettings) -> Self {
        Self {
            client,
            settings,
            room: Mutex::new(None),
            sync: Mutex::new(SyncState::default()),
        }
    }

    /// Finds and verifies the primary Dot and its DM room.
    pub async fn discover(&self) -> Result<DotRoom, DotsError> {
        let room = discover(&self.client).await?;
        *self.room.lock().await = Some(room.clone());
        Ok(room)
    }

    async fn current_room(&self) -> ConnectorResult<DotRoom> {
        if let Some(room) = self.room.lock().await.clone() {
            return Ok(room);
        }
        self.discover()
            .await
            .map_err(|error| map_error(error, false))
    }

    async fn run_inner(
        &self,
        checkpoint: Option<String>,
        events: mpsc::Sender<ConnectorEvent>,
    ) -> ConnectorResult<()> {
        let room = self
            .discover()
            .await
            .map_err(|error| map_error(error, false))?;
        let mut state = checkpoint
            .as_deref()
            .and_then(|raw| serde_json::from_str::<SyncState>(raw).ok())
            .filter(|state| state.v == CHECKPOINT_VERSION && state.room_id == room.room_id);
        if state.is_none() {
            let baseline = baseline(&self.client, &room.room_id)
                .await
                .map_err(|error| map_error(error, false))?;
            let fresh = SyncState {
                v: CHECKPOINT_VERSION,
                room_id: room.room_id.clone(),
                baseline_id: baseline.as_ref().map(|(id, _)| id.clone()),
                linked_at: baseline.map(|(_, at)| at),
                recent: VecDeque::new(),
            };
            if checkpoint.is_some() {
                log::warn!(target: "inline::bridge::dots", "Dot room changed; linking the new room from now on");
            }
            emit(&events, ConnectorEvent::Checkpoint(to_checkpoint(&fresh))).await?;
            state = Some(fresh);
        }
        *self.sync.lock().await = state.expect("state set");
        emit(
            &events,
            ConnectorEvent::Health(if room.paused {
                ConnectorHealth::Degraded("your Dot is paused".into())
            } else {
                ConnectorHealth::Ready
            }),
        )
        .await?;

        let (signal_sender, mut signals) = mpsc::channel(64);
        let realtime_task = self.settings.realtime.then(|| {
            tokio::spawn(realtime_loop(
                self.client.clone(),
                self.settings.realtime_policy.clone(),
                room.clone(),
                signal_sender.clone(),
            ))
        });
        let _abort_realtime = AbortOnDrop(realtime_task);
        drop(signal_sender);

        let mut subscribed = false;
        let mut tasks: HashMap<String, TaskTrack> = HashMap::new();
        let mut failures = 0u32;
        loop {
            match self.poll(&room, &events, &mut tasks).await {
                Ok(()) => {
                    if failures > 0 {
                        emit(&events, ConnectorEvent::Health(ConnectorHealth::Ready)).await?;
                    }
                    failures = 0;
                }
                Err(error) if error.is_transient() && failures < 8 => {
                    failures += 1;
                    log::warn!(target: "inline::bridge::dots", "poll failed: {error}");
                    emit(
                        &events,
                        ConnectorEvent::Health(ConnectorHealth::Degraded(error.to_string())),
                    )
                    .await?;
                }
                // A vanished room or repeated failures restart from discovery.
                Err(error) => return Err(map_error(error, false)),
            }
            self.poll_tasks(&events, &mut tasks).await?;

            let interval = if failures > 0 {
                Duration::from_secs(3u64 << failures.min(4))
            } else if subscribed {
                self.settings.poll_with_socket
            } else {
                self.settings.poll_without_socket
            };
            let next_task = tasks.values().map(|task| task.due).min();
            let wake_at = next_task
                .map(|due| due.min(Instant::now() + interval))
                .unwrap_or(Instant::now() + interval);
            tokio::select! {
                _ = tokio::time::sleep_until(wake_at) => {}
                signal = signals.recv() => match signal {
                    Some(Signal::Subscribed) => subscribed = true,
                    Some(Signal::Wake) => {}
                    Some(Signal::Typing(active)) => {
                        emit(&events, ConnectorEvent::Typing(active)).await?;
                        continue;
                    }
                    Some(Signal::Disconnected(reason)) => {
                        if subscribed {
                            log::info!(target: "inline::bridge::dots", "realtime dropped: {reason}");
                        }
                        subscribed = false;
                    }
                    None => subscribed = false,
                },
                _ = events.closed() => return Ok(()),
            }
        }
    }

    async fn poll(
        &self,
        room: &DotRoom,
        events: &mpsc::Sender<ConnectorEvent>,
        tasks: &mut HashMap<String, TaskTrack>,
    ) -> Result<(), DotsError> {
        let mut state = self.sync.lock().await.clone();
        let linked_at = state.linked_at.as_deref().and_then(parse_time);
        let mut after = state.resume_after();
        let mut seen_cursors = Vec::new();
        for _ in 0..MAX_PAGES_PER_POLL {
            let page = self
                .client
                .messages(
                    &room.room_id,
                    &MessageQuery {
                        limit: PAGE,
                        after: after.clone(),
                        ..Default::default()
                    },
                )
                .await?;
            let mut items = page.items;
            items.sort_by(|a, b| a.created().cmp(&b.created()).then_with(|| a.id.cmp(&b.id)));
            let full = items.len() as u32 >= PAGE;
            let last_id = items.last().map(|item| item.id.clone());
            for item in &items {
                if Some(&item.id) == state.baseline_id.as_ref() {
                    continue;
                }
                if let (Some(linked), Some(created)) = (linked_at, item.created())
                    && created < linked
                {
                    continue;
                }
                if let Some(remote) = convert(item, room) {
                    if let Some(task_id) = &remote.task_id {
                        tasks.entry(task_id.clone()).or_insert_with(|| TaskTrack {
                            last: None,
                            due: Instant::now(),
                            interval: Duration::from_secs(3),
                            failures: 0,
                        });
                    }
                    emit(events, ConnectorEvent::Message(remote))
                        .await
                        .map_err(|_| DotsError::Protocol("relay stopped".into()))?;
                }
                state.remember(&item.id);
            }
            let next = page
                .next_cursor
                .filter(|cursor| !cursor.is_empty())
                .or(last_id);
            if items.is_empty() || (!full && next.as_ref() == items.last().map(|item| &item.id)) {
                break;
            }
            if next.is_none() || seen_cursors.contains(&next) {
                break;
            }
            seen_cursors.push(next.clone());
            after = next;
        }
        *self.sync.lock().await = state.clone();
        emit(events, ConnectorEvent::Checkpoint(to_checkpoint(&state)))
            .await
            .map_err(|_| DotsError::Protocol("relay stopped".into()))?;
        Ok(())
    }

    async fn poll_tasks(
        &self,
        events: &mpsc::Sender<ConnectorEvent>,
        tasks: &mut HashMap<String, TaskTrack>,
    ) -> ConnectorResult<()> {
        let now = Instant::now();
        let due: Vec<String> = tasks
            .iter()
            .filter(|(_, track)| track.due <= now)
            .map(|(id, _)| id.clone())
            .collect();
        for id in due {
            let result = self.client.task(&id).await;
            let track = tasks.get_mut(&id).expect("tracked");
            match result {
                Ok(summary) => {
                    track.failures = 0;
                    // Ignore an older snapshot arriving after a newer one.
                    if track
                        .last
                        .as_ref()
                        .is_some_and(|last| summary.updated_at < last.updated_at)
                    {
                        track.due = now + track.interval;
                        continue;
                    }
                    let changed = track.last.as_ref() != Some(&summary);
                    if changed {
                        emit(events, ConnectorEvent::Task(task_update(&summary))).await?;
                    }
                    if summary.status.is_terminal() {
                        tasks.remove(&id);
                        continue;
                    }
                    track.interval = if changed {
                        Duration::from_secs(3)
                    } else {
                        (track.interval * 2).min(Duration::from_secs(30))
                    };
                    track.due = now + track.interval;
                    track.last = Some(summary);
                }
                Err(error) => {
                    track.failures += 1;
                    if track.failures >= 5 || !error.is_transient() {
                        let title = track.last.as_ref().and_then(|last| last.title.clone());
                        emit(
                            events,
                            ConnectorEvent::Task(TaskUpdate {
                                id: id.clone(),
                                title,
                                label:
                                    "Task details are unavailable here. Open ChatGPT to follow it."
                                        .into(),
                                terminal: true,
                            }),
                        )
                        .await?;
                        tasks.remove(&id);
                    } else {
                        track.due = now + Duration::from_secs(3u64 << track.failures.min(4));
                    }
                }
            }
        }
        Ok(())
    }
}

struct AbortOnDrop(Option<tokio::task::JoinHandle<()>>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        if let Some(handle) = self.0.take() {
            handle.abort();
        }
    }
}

async fn realtime_loop(
    client: DotsClient,
    policy: RealtimePolicy,
    room: DotRoom,
    signals: mpsc::Sender<Signal>,
) {
    let mut backoff = Duration::from_secs(1);
    loop {
        let started = Instant::now();
        let result = async {
            let url = client.realtime_endpoint().await?;
            realtime::session(&url, &policy, &room.room_id, &room.dot_member, &signals).await
        }
        .await;
        let reason = match result {
            Ok(()) => return,
            Err(error) => error.to_string(),
        };
        if signals.send(Signal::Disconnected(reason)).await.is_err() {
            return;
        }
        if started.elapsed() >= Duration::from_secs(60) {
            backoff = Duration::from_secs(1);
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(60));
    }
}

async fn emit(events: &mpsc::Sender<ConnectorEvent>, event: ConnectorEvent) -> ConnectorResult<()> {
    events
        .send(event)
        .await
        .map_err(|_| ConnectorError::new(FailureKind::Transient, "relay stopped"))
}

fn to_checkpoint(state: &SyncState) -> String {
    serde_json::to_string(state).expect("sync state serializes")
}

fn parse_time(value: &str) -> Option<chrono::DateTime<chrono::FixedOffset>> {
    chrono::DateTime::parse_from_rfc3339(value).ok()
}

fn task_update(summary: &TaskSummary) -> TaskUpdate {
    TaskUpdate {
        id: summary.id.clone(),
        title: summary.title.clone(),
        label: summary.status.label().into(),
        terminal: summary.status.is_terminal(),
    }
}

/// Finds and verifies the primary Dot and its room.
pub async fn discover(client: &DotsClient) -> Result<DotRoom, DotsError> {
    let identity = client.identity().await?;
    let (selection, inline_profile) = client.primary().await?;
    let profile = match inline_profile {
        Some(profile) => profile,
        None => client.profile(&selection.thread_id).await?,
    };
    if profile.status != "active"
        || profile.id != selection.aeon_id
        || profile.messaging_room_id != selection.messaging_room_id
        || profile
            .active_root_thread_id
            .as_deref()
            .is_some_and(|thread| !thread.is_empty() && thread != selection.thread_id)
    {
        return Err(DotsError::Protocol(
            "Dot profile does not match its selection".into(),
        ));
    }
    let room = client.room(&selection.messaging_room_id).await?;
    if room.kind != "DM"
        || room.app_source.as_deref() != Some("chatgpt:messaging")
        || room.id != selection.messaging_room_id
        || room.aeon_id.as_deref() != Some(selection.aeon_id.as_str())
        || room.members.len() != 2
    {
        return Err(DotsError::Protocol("room is not the Dot's DM".into()));
    }
    let dot = room
        .members
        .iter()
        .find(|member| member.aeon_id.as_deref() == Some(selection.aeon_id.as_str()))
        .ok_or_else(|| DotsError::Protocol("Dot room has no Dot member".into()))?;
    let owner = room
        .members
        .iter()
        .find(|member| member.aeon_id.as_deref().is_none_or(str::is_empty))
        .ok_or_else(|| DotsError::Protocol("Dot room has no owner member".into()))?;
    if owner.account_user_id != identity.account_user_id
        && owner.account_user_id != identity.user_id
    {
        return Err(DotsError::Protocol(
            "the Dot room belongs to a different ChatGPT user".into(),
        ));
    }
    Ok(DotRoom {
        room_id: room.id,
        aeon_id: selection.aeon_id,
        dot_member: dot.account_user_id.clone(),
        owner_member: owner.account_user_id.clone(),
        name: profile.name().to_owned(),
        paused: profile.is_paused || profile.is_admin_paused,
        avatar_url: profile.avatar_url,
    })
}

/// Newest message at link time, as `(id, created_at)`.
async fn baseline(
    client: &DotsClient,
    room_id: &str,
) -> Result<Option<(String, String)>, DotsError> {
    let room = client.room(room_id).await?;
    if let Some(latest) = room.latest_messages.filter(|latest| !latest.is_empty()) {
        return Ok(latest
            .into_iter()
            .max_by_key(|stub| parse_time(&stub.created_at))
            .map(|stub| (stub.id, stub.created_at)));
    }
    let page = client
        .messages(
            room_id,
            &MessageQuery {
                limit: 1,
                ..Default::default()
            },
        )
        .await?;
    Ok(page
        .items
        .into_iter()
        .max_by_key(|item| item.created())
        .map(|item| (item.id, item.created_at)))
}

/// Converts a wire message into a relay snapshot. `None` for senders that are
/// neither the Dot nor the owner.
pub fn convert(message: &Message, room: &DotRoom) -> Option<RemoteMessage> {
    let speaker = if message.account_user_id == room.dot_member {
        Speaker::Agent
    } else if message.account_user_id == room.owner_member {
        Speaker::Owner
    } else {
        return None;
    };
    let mut text = message.content.text.clone();
    let mut files = Vec::new();
    let mut task_id = None;
    let mut unsupported = 0;
    for (index, attachment) in message.content.attachments.iter().enumerate() {
        match attachment.kind.as_str() {
            "file" => match &attachment.file_id {
                Some(file_id) if !file_id.is_empty() => files.push(RemoteFile {
                    key: attachment
                        .attachment_id
                        .clone()
                        .unwrap_or_else(|| format!("{file_id}#{index}")),
                    locator: file_id.clone(),
                    name: attachment.name.clone(),
                }),
                _ => unsupported += 1,
            },
            "thread" => {
                if task_id.is_none() {
                    task_id = attachment.thread_id.clone().filter(|id| !id.is_empty());
                }
            }
            "link" => {}
            _ => unsupported += 1,
        }
    }
    if unsupported > 0 {
        if !text.is_empty() {
            text.push_str("\n\n");
        }
        text.push_str("_[An attachment here only shows in ChatGPT.]_");
    }
    let confirmation = match (&message.content.elicitation, speaker) {
        (Some(raw), Speaker::Agent) => Some(confirmation(raw)),
        _ => None,
    };
    let revision = {
        let fingerprint = json!({
            "text": text,
            "deleted": message.deleted_at.is_some(),
            "files": files.iter().map(|file| &file.key).collect::<Vec<_>>(),
            "task": task_id,
            "confirmation": confirmation.as_ref().map(|c| (&c.key, format!("{:?}", c.status))),
        });
        hex(&Sha256::digest(fingerprint.to_string()))[..16].to_owned()
    };
    Some(RemoteMessage {
        id: message.id.clone(),
        speaker,
        client_request_id: message.request_id.clone().filter(|id| !id.is_empty()),
        text,
        files,
        reply_to: message
            .reply_to
            .as_ref()
            .map(|reply| reply.message_id.clone()),
        deleted: message.deleted_at.is_some(),
        agent_reaction: message.reactions.get(&room.dot_member).cloned(),
        task_id,
        confirmation,
        revision,
    })
}

/// Hash of the confirmation definition, excluding its mutable status.
pub fn definition_key(raw: &Value) -> String {
    let mut definition = raw.clone();
    if let Some(object) = definition.as_object_mut() {
        object.remove("status");
    }
    hex(&Sha256::digest(canonical(&definition)))[..24].to_owned()
}

fn canonical(value: &Value) -> String {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<_> = map.keys().collect();
            keys.sort();
            let body: Vec<String> = keys
                .into_iter()
                .map(|key| format!("{}:{}", Value::String(key.clone()), canonical(&map[key])))
                .collect();
            format!("{{{}}}", body.join(","))
        }
        Value::Array(items) => {
            format!(
                "[{}]",
                items.iter().map(canonical).collect::<Vec<_>>().join(",")
            )
        }
        other => other.to_string(),
    }
}

fn confirmation(raw: &Value) -> Confirmation {
    let key = definition_key(raw);
    match Elicitation::parse(raw) {
        Some(parsed) => Confirmation {
            key,
            title: parsed.title.clone(),
            message: if parsed.message.is_empty() {
                "Your Dot needs your confirmation.".into()
            } else {
                parsed.message.clone()
            },
            fields: parsed.fields.clone(),
            answerable: parsed.accept_content.is_some(),
            status: if parsed.is_pending() {
                ConfirmationStatus::Pending
            } else {
                ConfirmationStatus::Closed(parsed.status.clone().unwrap_or_default())
            },
        },
        None => Confirmation {
            key,
            title: None,
            message: "Your Dot needs your confirmation.".into(),
            fields: Vec::new(),
            answerable: false,
            status: ConfirmationStatus::Pending,
        },
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Maps client errors onto the relay's delivery semantics. `sending` marks
/// a message POST, where a timeout or 5xx leaves delivery uncertain.
pub fn map_error(error: DotsError, sending: bool) -> ConnectorError {
    let kind = if error.needs_login() || matches!(error, DotsError::NoPrimaryDot) {
        FailureKind::NeedsLogin
    } else {
        match &error {
            DotsError::RateLimited { .. } | DotsError::Challenge { .. } => FailureKind::Transient,
            DotsError::Http { status: 403, .. } => FailureKind::Transient,
            DotsError::Http { status, .. } if (400..500).contains(status) && *status != 408 => {
                if sending {
                    FailureKind::Rejected
                } else {
                    FailureKind::Transient
                }
            }
            DotsError::Attachment(_) => FailureKind::Rejected,
            DotsError::Network(_) | DotsError::Protocol(_) | DotsError::Http { .. } if sending => {
                FailureKind::Uncertain
            }
            _ => FailureKind::Transient,
        }
    };
    ConnectorError::new(kind, error.to_string())
}

impl Connector for DotsConnector {
    fn capabilities(&self) -> Capabilities {
        Capabilities {
            reactions: true,
            send_files: true,
            max_file_bytes: MAX_FILE_BYTES,
            edits: false,
        }
    }

    fn run<'a>(
        &'a self,
        checkpoint: Option<String>,
        events: mpsc::Sender<ConnectorEvent>,
    ) -> BoxFuture<'a, ConnectorResult<()>> {
        Box::pin(self.run_inner(checkpoint, events))
    }

    fn send<'a>(&'a self, message: &'a OutboundMessage) -> BoxFuture<'a, ConnectorResult<String>> {
        Box::pin(async move {
            let room = self.current_room().await?;
            let mut file_ids = Vec::new();
            if let Some(file) = &message.file {
                // Not yet delivered if the upload fails: never "uncertain".
                let id = self
                    .client
                    .upload(&room.room_id, &file.name, &file.mime, &file.bytes)
                    .await
                    .map_err(|error| {
                        let mapped = map_error(error, false);
                        if mapped.kind == FailureKind::Uncertain {
                            ConnectorError::new(FailureKind::Transient, mapped.message)
                        } else {
                            mapped
                        }
                    })?;
                file_ids.push(id);
            }
            let sent = self
                .client
                .send(
                    &room.room_id,
                    &SendMessage {
                        text: message.text.clone(),
                        file_ids,
                        request_id: message.request_id.clone(),
                        reply_to: message.reply_to.clone(),
                    },
                )
                .await
                .map_err(|error| map_error(error, true))?;
            if sent.account_user_id != room.owner_member {
                return Err(ConnectorError::new(
                    FailureKind::Uncertain,
                    "sent message has an unexpected sender",
                ));
            }
            Ok(sent.id)
        })
    }

    fn find_sent<'a>(
        &'a self,
        request_id: &'a str,
        reply_to: Option<&'a str>,
    ) -> BoxFuture<'a, ConnectorResult<Option<String>>> {
        Box::pin(async move {
            let room = self.current_room().await?;
            let matches = |message: &Message| {
                message.request_id.as_deref() == Some(request_id)
                    && message.account_user_id == room.owner_member
            };
            let mut after = self.sync.lock().await.resume_after();
            for _ in 0..4 {
                let page = self
                    .client
                    .messages(
                        &room.room_id,
                        &MessageQuery {
                            limit: PAGE,
                            after: after.clone(),
                            ..Default::default()
                        },
                    )
                    .await
                    .map_err(|error| map_error(error, false))?;
                if let Some(found) = page.items.iter().find(|item| matches(item)) {
                    return Ok(Some(found.id.clone()));
                }
                if page.items.len() < PAGE as usize {
                    break;
                }
                let next = page.next_cursor.clone().or_else(|| {
                    page.items
                        .iter()
                        .max_by_key(|item| item.created())
                        .map(|item| item.id.clone())
                });
                if next == after {
                    break;
                }
                after = next;
            }
            if let Some(parent) = reply_to {
                let root = match self
                    .client
                    .message(&room.room_id, parent)
                    .await
                    .map_err(|error| map_error(error, false))?
                {
                    Some(parent_message) => parent_message
                        .reply_root_message_id
                        .filter(|root| !root.is_empty())
                        .unwrap_or(parent_message.id),
                    None => parent.to_owned(),
                };
                let page = self
                    .client
                    .messages(
                        &room.room_id,
                        &MessageQuery {
                            limit: PAGE,
                            reply_root_message_id: Some(root),
                            ..Default::default()
                        },
                    )
                    .await
                    .map_err(|error| map_error(error, false))?;
                if let Some(found) = page.items.iter().find(|item| matches(item)) {
                    return Ok(Some(found.id.clone()));
                }
            }
            Ok(None)
        })
    }

    fn set_reaction<'a>(
        &'a self,
        message_id: &'a str,
        emoji: Option<&'a str>,
    ) -> BoxFuture<'a, ConnectorResult<()>> {
        Box::pin(async move {
            let room = self.current_room().await?;
            let result = match emoji {
                Some(emoji) => self.client.react(&room.room_id, message_id, emoji).await,
                None => self.client.unreact(&room.room_id, message_id).await,
            };
            result.map_err(|error| map_error(error, false))
        })
    }

    fn fetch_file<'a>(
        &'a self,
        _message_id: &'a str,
        file: &'a RemoteFile,
    ) -> BoxFuture<'a, ConnectorResult<Option<FileData>>> {
        Box::pin(async move {
            let room = self.current_room().await?;
            let downloaded = self
                .client
                .download(&room.room_id, &file.locator)
                .await
                .map_err(|error| map_error(error, false))?;
            Ok(downloaded.map(|downloaded| FileData {
                name: file.name.clone().unwrap_or(downloaded.name),
                mime: downloaded.mime,
                bytes: downloaded.bytes,
            }))
        })
    }

    fn answer_confirmation<'a>(
        &'a self,
        message_id: &'a str,
        key: &'a str,
        accept: bool,
    ) -> BoxFuture<'a, ConnectorResult<ConfirmationAnswer>> {
        Box::pin(async move {
            let room = self.current_room().await?;
            let state = self
                .client
                .inspect_elicitation(&room.room_id, message_id)
                .await
                .map_err(|error| map_error(error, false))?;
            if !state.can_respond || state.runtime_status != "pending" {
                return Ok(ConfirmationAnswer::NotApplied(format!(
                    "it is {}",
                    if state.runtime_status.is_empty() {
                        "no longer pending"
                    } else {
                        &state.runtime_status
                    }
                )));
            }
            if definition_key(&state.elicitation) != key {
                return Ok(ConfirmationAnswer::NotApplied(
                    "the request changed after it was shown".into(),
                ));
            }
            let Some(parsed) = Elicitation::parse(&state.elicitation) else {
                return Ok(ConfirmationAnswer::NotApplied(
                    "the request is malformed".into(),
                ));
            };
            if !parsed.is_pending() {
                return Ok(ConfirmationAnswer::NotApplied(
                    "it was already answered".into(),
                ));
            }
            let Some(content) = parsed.accept_content else {
                return Ok(ConfirmationAnswer::NotApplied(
                    "it needs more than a yes or no".into(),
                ));
            };
            let status = self
                .client
                .respond_elicitation(
                    &room.room_id,
                    message_id,
                    &state.request_fingerprint,
                    if accept {
                        Decision::Accept
                    } else {
                        Decision::Decline
                    },
                    &content,
                )
                .await
                .map_err(|error| {
                    // An answer is never retried; report it as uncertain.
                    ConnectorError::new(FailureKind::Uncertain, error.to_string())
                })?;
            Ok(if status == "applied" {
                ConfirmationAnswer::Applied
            } else {
                ConfirmationAnswer::NotApplied(if status.is_empty() {
                    "no status returned".into()
                } else {
                    status
                })
            })
        })
    }

    fn describe(&self) -> BoxFuture<'_, String> {
        Box::pin(async move {
            match self.room.lock().await.as_ref() {
                Some(room) => format!(
                    "Dot: {}{}",
                    room.name,
                    if room.paused { " (paused)" } else { "" }
                ),
                None => "Dot: not found yet".into(),
            }
        })
    }
}

/// Shared handle type the CLI stores.
pub type SharedDotsConnector = Arc<DotsConnector>;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Attachment, Content, ReplyTo};

    fn room() -> DotRoom {
        DotRoom {
            room_id: "room".into(),
            aeon_id: "aeon".into(),
            dot_member: "dot".into(),
            owner_member: "me".into(),
            name: "Pip".into(),
            paused: false,
            avatar_url: None,
        }
    }

    fn message(sender: &str) -> Message {
        Message {
            id: "m1".into(),
            created_at: "2026-11-10T10:00:00Z".into(),
            updated_at: None,
            account_user_id: sender.into(),
            request_id: None,
            deleted_at: None,
            reactions: Default::default(),
            reply_to: None,
            reply_root_message_id: None,
            role: None,
            content: Content::default(),
        }
    }

    #[test]
    fn convert_maps_speakers_and_parts() {
        let mut dot = message("dot");
        dot.content = Content {
            text: "Here".into(),
            attachments: vec![
                Attachment {
                    kind: "file".into(),
                    file_id: Some("f1".into()),
                    attachment_id: Some("a1".into()),
                    thread_id: None,
                    name: Some("x.png".into()),
                },
                Attachment {
                    kind: "thread".into(),
                    file_id: None,
                    attachment_id: None,
                    thread_id: Some("t1".into()),
                    name: None,
                },
                Attachment {
                    kind: "poll".into(),
                    file_id: None,
                    attachment_id: None,
                    thread_id: None,
                    name: None,
                },
            ],
            elicitation: None,
        };
        dot.reply_to = Some(ReplyTo {
            message_id: "p".into(),
        });
        dot.reactions.insert("dot".into(), "👍".into());
        dot.reactions.insert("me".into(), "❤️".into());
        let converted = convert(&dot, &room()).unwrap();
        assert_eq!(converted.speaker, Speaker::Agent);
        assert_eq!(converted.files[0].key, "a1");
        assert_eq!(converted.task_id.as_deref(), Some("t1"));
        assert_eq!(converted.reply_to.as_deref(), Some("p"));
        assert_eq!(converted.agent_reaction.as_deref(), Some("👍"));
        assert!(converted.text.contains("only shows in ChatGPT"));

        assert_eq!(
            convert(&message("me"), &room()).unwrap().speaker,
            Speaker::Owner
        );
        assert!(convert(&message("stranger"), &room()).is_none());
    }

    #[test]
    fn revision_ignores_reactions_but_tracks_text() {
        let mut a = message("dot");
        a.content.text = "x".into();
        let mut b = a.clone();
        b.reactions.insert("dot".into(), "👍".into());
        assert_eq!(
            convert(&a, &room()).unwrap().revision,
            convert(&b, &room()).unwrap().revision
        );
        b.content.text = "y".into();
        assert_ne!(
            convert(&a, &room()).unwrap().revision,
            convert(&b, &room()).unwrap().revision
        );
    }

    #[test]
    fn definition_key_ignores_status_and_key_order() {
        let a = json!({"request_id": "r", "status": "pending", "params": {"a": 1, "b": 2}});
        let b = json!({"params": {"b": 2, "a": 1}, "status": "accepted", "request_id": "r"});
        assert_eq!(definition_key(&a), definition_key(&b));
        let c = json!({"request_id": "r", "params": {"a": 1, "b": 3}});
        assert_ne!(definition_key(&a), definition_key(&c));
    }

    #[test]
    fn send_errors_classify_delivery() {
        let http = |status| DotsError::Http {
            status,
            endpoint: "x",
            detail: None,
        };
        assert_eq!(map_error(http(400), true).kind, FailureKind::Rejected);
        assert_eq!(map_error(http(502), true).kind, FailureKind::Uncertain);
        assert_eq!(map_error(http(401), true).kind, FailureKind::NeedsLogin);
        assert_eq!(
            map_error(
                DotsError::RateLimited {
                    endpoint: "x",
                    retry_after: None
                },
                true
            )
            .kind,
            FailureKind::Transient
        );
        assert_eq!(
            map_error(DotsError::Network("t".into()), true).kind,
            FailureKind::Uncertain
        );
        assert_eq!(
            map_error(DotsError::Network("t".into()), false).kind,
            FailureKind::Transient
        );
    }

    #[test]
    fn sync_state_window_is_bounded() {
        let mut state = SyncState::default();
        for i in 0..40 {
            state.remember(&format!("m{i}"));
        }
        state.remember("m39");
        assert_eq!(state.recent.len(), OVERLAP);
        assert_eq!(state.resume_after().as_deref(), Some("m7"));
    }
}
