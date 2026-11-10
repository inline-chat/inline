//! The relay engine: mirrors one remote conversation into the owner's DM with
//! a bot, and the owner's DM messages back to the remote network.
//!
//! Both directions run under one apply lock, so the store never sees
//! interleaved half-applied events and a send's remote echo is always
//! processed after its reservation settled.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::{Mutex, mpsc, watch};

use crate::model::*;
use crate::render;
use crate::store::{
    ConfirmationCard, ConfirmationState, Link, Origin, PendingSend, RelayStore, StoreError, part,
};

const CHECKPOINT_KEY: &str = "connector.checkpoint";
const MIRROR_OWNER_KEY: &str = "settings.mirror_owner";
const PENDING_RETRY_TICK: Duration = Duration::from_secs(15);
const READ_MARK_KEY: &str = "sync.agent_read_inline_id";
const PROFILE_NAME_KEY: &str = "profile.name";
const PROFILE_AVATAR_KEY: &str = "profile.avatar";
const FILE_RETRY_PREFIX: &str = "file_retry\u{1f}";
const MAX_FILE_ATTEMPTS: u32 = 6;
const OWNER_TYPING_INTERVAL: Duration = Duration::from_secs(4);
const MAX_SEND_ATTEMPTS: u32 = 8;
const CONFIRMATION_CALLBACK_VERSION: u32 = 1;
const MAX_APPLY_ATTEMPTS: u32 = 5;

/// Relay failure (store or Inline side). Connector failures are handled and
/// reported through health instead.
#[derive(Debug, thiserror::Error)]
pub enum RelayError {
    /// Local store failure.
    #[error(transparent)]
    Store(#[from] StoreError),
    /// Inline side failure.
    #[error("Inline: {0}")]
    Inline(#[from] InlineError),
}

/// Result alias.
pub type RelayResult<T> = Result<T, RelayError>;

/// Static relay settings.
#[derive(Clone, Debug)]
pub struct RelayConfig {
    /// The only Inline user the relay acts for.
    pub owner_user_id: i64,
    /// Agent name used in copy ("Dot").
    pub agent_name: String,
    /// Network name used in copy ("ChatGPT").
    pub network_name: String,
    /// Salt for correlation ids; unique per installation.
    pub request_salt: String,
    /// Whether messages the owner types in the remote app are mirrored into
    /// Inline by default (changeable with `/mirror`).
    pub mirror_owner_default: bool,
}

/// Snapshot for health reporting.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RelayHealth {
    /// Connector state; `None` while starting.
    pub connector: Option<ConnectorHealth>,
    /// Owner messages not yet confirmed delivered.
    pub pending_sends: usize,
    /// Unix seconds of the last applied remote event.
    pub last_remote_event_at: Option<i64>,
}

#[derive(Serialize, Deserialize)]
struct ConfirmationCallback {
    v: u32,
    k: String,
    a: String,
}

#[derive(Serialize, Deserialize)]
struct FileRetry {
    remote_id: String,
    key: String,
    locator: String,
    name: Option<String>,
    reply_to: Option<i64>,
    attempts: u32,
    next_at: i64,
    #[serde(default)]
    owner: bool,
}

#[derive(Serialize, Deserialize)]
struct StoredMedia {
    url: Option<String>,
    name: Option<String>,
    mime: Option<String>,
    size: Option<u64>,
}

/// The relay.
pub struct Relay {
    connector: Arc<dyn Connector>,
    inline: Arc<dyn InlineSide>,
    store: Arc<RelayStore>,
    config: RelayConfig,
    apply: Mutex<()>,
    health: watch::Sender<RelayHealth>,
    /// Last owner typing signal forwarded.
    owner_typing_at: std::sync::Mutex<Option<std::time::Instant>>,
}

impl std::fmt::Debug for Relay {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("Relay")
    }
}

impl Relay {
    /// Builds a relay.
    pub fn new(
        connector: Arc<dyn Connector>,
        inline: Arc<dyn InlineSide>,
        store: Arc<RelayStore>,
        config: RelayConfig,
    ) -> Self {
        let (health, _) = watch::channel(RelayHealth {
            connector: None,
            pending_sends: 0,
            last_remote_event_at: None,
        });
        Self {
            connector,
            inline,
            store,
            config,
            apply: Mutex::new(()),
            health,
            owner_typing_at: Default::default(),
        }
    }

    /// Health updates.
    pub fn health(&self) -> watch::Receiver<RelayHealth> {
        self.health.subscribe()
    }

    /// Settles state left by a previous run. Call once before `run_remote`.
    pub async fn recover(&self) -> RelayResult<()> {
        let _guard = self.apply.lock().await;
        // An answer in flight is never resent. Persist the card text before
        // editing so a failed UI update can be completed on redelivery.
        for card in self.store.confirmations_in(ConfirmationState::Answering)? {
            let key = format!("confirmation_result:{}", card.key);
            let text = self.store.kv_get(&key)?.unwrap_or_else(|| render::confirmation_closed(
                &card.body,
                &format!("The bridge restarted while sending your answer. Check {} to see whether it went through.", self.config.network_name),
            ));
            self.store.kv_set(&key, &text)?;
            self.finish_confirmation(&card, &text).await?;
        }
        self.publish_pending_count()?;
        Ok(())
    }

    /// Runs the remote side until `shutdown` turns true. Restarts the
    /// connector with backoff after failures.
    pub async fn run_remote(&self, mut shutdown: watch::Receiver<bool>) -> RelayResult<()> {
        let mut backoff = Duration::from_secs(3);
        let mut apply_failures = HashMap::new();
        let mut retry_event = None;
        loop {
            if *shutdown.borrow() {
                return Ok(());
            }
            // A targeted realtime update may lie outside the poll window.
            // Retain its exact snapshot when restarting the connector.
            if let Some(event) = retry_event.take()
                && !self.apply_or_defer(&event, &mut apply_failures).await?
            {
                retry_event = Some(event);
                tokio::select! {
                    _ = tokio::time::sleep(backoff) => {}
                    _ = shutdown.changed() => {}
                }
                backoff = (backoff * 2).min(Duration::from_secs(60));
                continue;
            }
            let checkpoint = self.store.kv_get(CHECKPOINT_KEY)?;
            let (sender, mut receiver) = mpsc::channel(256);
            let started = std::time::Instant::now();
            let outcome = {
                let run = self.connector.run(checkpoint, sender);
                tokio::pin!(run);
                let mut tick = tokio::time::interval(PENDING_RETRY_TICK);
                tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                let mut run_result = None;
                loop {
                    tokio::select! {
                        biased;
                        _ = shutdown.changed() => {
                            if *shutdown.borrow() { return Ok(()); }
                        }
                        event = receiver.recv() => match event {
                            Some(event) => {
                                if !self.apply_or_defer(&event, &mut apply_failures).await? {
                                    retry_event = Some(event);
                                    break Err(ConnectorError::new(FailureKind::Transient, "couldn't update Inline; retrying"));
                                }
                            },
                            None => {
                                if let Some(result) = run_result.take() { break result; }
                                // Sender dropped but run still finishing.
                                break (&mut run).await;
                            }
                        },
                        result = &mut run, if run_result.is_none() => {
                            // Drain anything the connector queued before returning.
                            run_result = Some(result);
                        }
                        _ = tick.tick() => {
                            if let Err(error) = self.retry_pending().await {
                                log::warn!(target: "inline::bridge::relay", "pending retry failed: {error}");
                                self.set_connector_health(ConnectorHealth::Degraded("couldn't update Inline; retrying".into()));
                            }
                        },
                    }
                }
            };
            let delay = match outcome {
                Ok(()) => Duration::from_secs(3),
                Err(error) => {
                    let health = match error.kind {
                        FailureKind::NeedsLogin => {
                            ConnectorHealth::NeedsLogin(error.message.clone())
                        }
                        _ => ConnectorHealth::Degraded(error.message.clone()),
                    };
                    log::warn!(target: "inline::bridge::relay", "connector stopped: {}", error.message);
                    self.set_connector_health(health);
                    if error.kind == FailureKind::NeedsLogin {
                        Duration::from_secs(60)
                    } else {
                        backoff
                    }
                }
            };
            if started.elapsed() > Duration::from_secs(120) {
                backoff = Duration::from_secs(3);
            } else {
                backoff = (backoff * 2).min(Duration::from_secs(60));
            }
            tokio::select! {
                _ = tokio::time::sleep(delay) => {}
                _ = shutdown.changed() => {}
            }
        }
    }

    async fn apply_or_defer(
        &self,
        event: &ConnectorEvent,
        failures: &mut HashMap<String, u32>,
    ) -> RelayResult<bool> {
        let key = match event {
            ConnectorEvent::Message(message) => format!("message:{}", message.id),
            ConnectorEvent::Task(task) => format!("task:{}", task.id),
            ConnectorEvent::Checkpoint(_) => "checkpoint".into(),
            ConnectorEvent::ReadUpTo(id) => format!("read:{id}"),
            ConnectorEvent::Profile(_) => "profile".into(),
            ConnectorEvent::Health(_) | ConnectorEvent::Typing(_) => "transient".into(),
        };
        let skipped_key = format!("apply_skipped:{}", text_hash(&key));
        let fingerprint = text_hash(&format!("{event:?}"));
        if self.store.kv_get(&skipped_key)?.as_deref() == Some(&fingerprint) {
            return Ok(true);
        }
        match self.handle_remote(event.clone()).await {
            Ok(()) => {
                failures.remove(&key);
                Ok(true)
            }
            Err(error) => {
                let attempts = failures.entry(key.clone()).or_default();
                *attempts += 1;
                self.set_connector_health(ConnectorHealth::Degraded(
                    "couldn't update Inline; retrying".into(),
                ));
                if *attempts < MAX_APPLY_ATTEMPTS {
                    log::warn!(target: "inline::bridge::relay", "remote event apply failed (attempt {attempts}): {error}");
                    return Ok(false);
                }
                // Checkpoint failures must never be skipped: otherwise later
                // events could advance past unapplied work after a store error.
                if matches!(event, ConnectorEvent::Checkpoint(_)) {
                    return Err(error);
                }
                log::error!(target: "inline::bridge::relay", "remote event skipped after {attempts} attempts: {error}");
                self.store.kv_set(&skipped_key, &fingerprint)?;
                failures.remove(&key);
                Ok(true)
            }
        }
    }

    /// Updates connection health, including failures of the hosting worker.
    pub fn set_connector_health(&self, health: ConnectorHealth) {
        self.health
            .send_modify(|current| current.connector = Some(health));
    }

    fn publish_pending_count(&self) -> RelayResult<()> {
        let count = self.store.pending_sends()?.len();
        self.health
            .send_modify(|current| current.pending_sends = count);
        Ok(())
    }

    fn inline_soft(&self, result: InlineResult<()>) {
        if let Err(error) = result {
            log::warn!(target: "inline::bridge::relay", "inline update failed: {error}");
        }
    }

    fn mirror_owner(&self) -> RelayResult<bool> {
        Ok(match self.store.kv_get(MIRROR_OWNER_KEY)?.as_deref() {
            Some("on") => true,
            Some("off") => false,
            _ => self.config.mirror_owner_default,
        })
    }

    // ---------------------------------------------------------------- remote

    /// Applies one connector event.
    pub async fn handle_remote(&self, event: ConnectorEvent) -> RelayResult<()> {
        let _guard = self.apply.lock().await;
        self.health
            .send_modify(|current| current.last_remote_event_at = Some(now()));
        match event {
            ConnectorEvent::Message(message) => self.apply_message(message).await,
            ConnectorEvent::Task(task) => self.apply_task(task).await,
            ConnectorEvent::Typing(active) => {
                self.inline_soft(self.inline.typing(active).await);
                Ok(())
            }
            ConnectorEvent::Checkpoint(checkpoint) => {
                self.store.kv_set(CHECKPOINT_KEY, &checkpoint)?;
                Ok(())
            }
            ConnectorEvent::Health(health) => {
                self.set_connector_health(health);
                Ok(())
            }
            ConnectorEvent::ReadUpTo(remote_id) => self.apply_read(&remote_id).await,
            ConnectorEvent::Profile(profile) => self.apply_profile(profile).await,
        }
    }

    async fn apply_read(&self, remote_id: &str) -> RelayResult<()> {
        let Some(inline_id) = self.store.inline_for_remote(remote_id)? else {
            return Ok(());
        };
        let current = self
            .store
            .kv_get(READ_MARK_KEY)?
            .and_then(|value| value.parse::<i64>().ok());
        if current.is_some_and(|current| current >= inline_id) {
            return Ok(());
        }
        match self.inline.mark_read(inline_id).await {
            Ok(()) => self.store.kv_set(READ_MARK_KEY, &inline_id.to_string())?,
            Err(error) => {
                log::warn!(target: "inline::bridge::relay", "read state not mirrored: {error}")
            }
        }
        Ok(())
    }

    async fn apply_profile(&self, profile: AgentProfile) -> RelayResult<()> {
        let name = profile.name.trim();
        if !name.is_empty() && self.store.kv_get(PROFILE_NAME_KEY)?.as_deref() != Some(name) {
            match self.inline.update_profile(Some(name), None).await {
                Ok(()) => self.store.kv_set(PROFILE_NAME_KEY, name)?,
                Err(error) => {
                    log::warn!(target: "inline::bridge::relay", "bot name not updated: {error}")
                }
            }
        }
        if let Some(locator) = profile.avatar.as_deref()
            && self.store.kv_get(PROFILE_AVATAR_KEY)?.as_deref() != Some(locator)
        {
            match self.connector.fetch_avatar(locator).await {
                Ok(Some(avatar)) => match self.inline.update_profile(None, Some(&avatar)).await {
                    Ok(()) => self.store.kv_set(PROFILE_AVATAR_KEY, locator)?,
                    Err(error) => log::warn!(
                        target: "inline::bridge::relay",
                        "bot photo not updated: {error}"
                    ),
                },
                Ok(None) => self.store.kv_set(PROFILE_AVATAR_KEY, locator)?,
                Err(error) => log::warn!(
                    target: "inline::bridge::relay",
                    "avatar download failed: {}",
                    error.message
                ),
            }
        }
        Ok(())
    }

    async fn apply_message(&self, message: RemoteMessage) -> RelayResult<()> {
        // Echo of a message this relay sent.
        if message.speaker == Speaker::Owner
            && let Some(request_id) = message.client_request_id.as_deref()
            && let Some(pending) = self.store.pending_by_request(request_id)?
        {
            self.settle_delivered(&pending, &message.id).await?;
            self.publish_pending_count()?;
        }
        self.reconcile_message(&message).await
    }

    async fn reconcile_message(&self, message: &RemoteMessage) -> RelayResult<()> {
        let mut link = self.store.link(&message.id, part::TEXT)?.unwrap_or(Link {
            remote_id: message.id.clone(),
            part: part::TEXT.into(),
            inline_id: None,
            origin: Origin::Remote,
            revision: None,
            agent_reaction: None,
            rendered: None,
        });
        let reply_to = match message.reply_to.as_deref() {
            Some(parent) => self.store.inline_for_remote(parent)?,
            None => None,
        };
        let mirror = message.speaker != Speaker::Owner || self.mirror_owner()?;
        if link.origin == Origin::Remote {
            let existing = self.store.inline_for_remote(&message.id)?;
            let text = if message.deleted {
                existing.map(|_| render::deleted(&self.config.network_name))
            } else if !message.text.trim().is_empty() && (mirror || link.inline_id.is_some()) {
                Some(match message.speaker {
                    Speaker::System => render::system_notice(&message.text),
                    Speaker::Owner => render::agent_text(&message.text),
                    Speaker::Agent => render::agent_text(&message.text),
                })
            } else if link.inline_id.is_some() {
                Some(format!("_Text removed in {}._", self.config.network_name))
            } else {
                None
            };
            if let Some(text) = text {
                let rendered = text_hash(&text);
                if link.rendered.as_deref() != Some(&rendered) {
                    let as_owner = message.speaker == Speaker::Owner;
                    match link.inline_id {
                        Some(inline_id) if as_owner => {
                            self.inline.edit_as_owner(inline_id, &text).await?
                        }
                        Some(inline_id) => self.inline.edit(inline_id, &text, None).await?,
                        None => {
                            link.inline_id = Some(
                                self.inline
                                    .post(&InlinePost {
                                        text,
                                        reply_to: if message.deleted {
                                            existing.or(reply_to)
                                        } else {
                                            reply_to
                                        },
                                        key: format!("remote:{}:text", message.id),
                                        file: None,
                                        buttons: Vec::new(),
                                        silent: message.speaker != Speaker::Agent
                                            || message.deleted,
                                        as_owner,
                                    })
                                    .await?,
                            );
                            if as_owner && let Some(inline_id) = link.inline_id {
                                // The bot sees this as a new owner message;
                                // it came from the remote, so never send it back.
                                self.store.mark_inbound(inline_id, "mirrored", now())?;
                            }
                        }
                    }
                    link.rendered = Some(rendered);
                    self.store.put_link(&link)?;
                }
            }
        } else if message.deleted && link.rendered.as_deref() != Some("deleted") {
            if let Some(inline_id) = link.inline_id {
                self.notice(
                    inline_id,
                    format!("remote-deleted:{}", message.id),
                    render::deleted(&self.config.network_name),
                )
                .await?;
            }
            link.rendered = Some("deleted".into());
            self.store.put_link(&link)?;
        }

        // Reconcile parts on every snapshot, including a replay of a revision
        // whose text succeeded before another part failed.
        if link.origin == Origin::Remote
            && mirror
            && !message.deleted
            && message.speaker != Speaker::System
        {
            for file in &message.files {
                self.mirror_file(message, file, reply_to).await?;
            }
        }
        if link.agent_reaction != message.agent_reaction
            && let Some(target) = self.store.inline_for_remote(&message.id)?
        {
            if let Some(old) = link.agent_reaction.as_deref() {
                self.inline.react(target, old, true).await?;
                link.agent_reaction = None;
                self.store.put_link(&link)?;
            }
            if let Some(new) = message.agent_reaction.as_deref() {
                self.inline.react(target, new, false).await?;
                link.agent_reaction = Some(new.to_owned());
                self.store.put_link(&link)?;
            }
        }
        self.reconcile_owner_reaction(message).await?;
        if message.speaker == Speaker::Agent {
            let anchor = self.store.inline_for_remote(&message.id)?.or(reply_to);
            // In ChatGPT a task is shown as a card at the message that started
            // it. Post the card there now, so it keeps its place; progress
            // updates edit it later.
            if let Some(task_id) = &message.task_id
                && !message.deleted
                && self.store.task(task_id)?.is_none()
            {
                let key = format!("task_anchor:{task_id}");
                if self.store.kv_get(&key)?.is_none()
                    && let Some(anchor) = anchor
                {
                    self.store.kv_set(&key, &anchor.to_string())?;
                }
                let card = self
                    .apply_task_card(&TaskUpdate {
                        id: task_id.clone(),
                        title: None,
                        label: "Starting…".into(),
                        terminal: false,
                        entries: Vec::new(),
                    })
                    .await?;
                // A task-only message is the card; replies to the card
                // answer that message.
                self.store.put_link(&Link {
                    remote_id: message.id.clone(),
                    part: "task".into(),
                    inline_id: Some(card),
                    origin: Origin::Remote,
                    revision: None,
                    agent_reaction: None,
                    rendered: None,
                })?;
            }
            if let Some(task_id) = &message.task_id {
                let remote_key = format!("task_anchor_remote:{task_id}");
                if self.store.kv_get(&remote_key)?.is_none() {
                    self.store.kv_set(&remote_key, &message.id)?;
                }
                let key = format!("task_anchor:{task_id}");
                if self.store.kv_get(&key)?.is_none()
                    && let Some(anchor) = anchor
                {
                    self.store.kv_set(&key, &anchor.to_string())?;
                }
            }
            if let Some(confirmation) = &message.confirmation {
                if let Some(card) = self.store.confirmation(&confirmation.key)? {
                    if card.state == ConfirmationState::Answering {
                        if let Some(text) = self
                            .store
                            .kv_get(&format!("confirmation_result:{}", card.key))?
                        {
                            self.finish_confirmation(&card, &text).await?;
                        }
                    } else if card.state == ConfirmationState::Open {
                        let status = if message.deleted {
                            Some("Deleted in the original conversation.".into())
                        } else if let ConfirmationStatus::Closed(status) = &confirmation.status {
                            Some(render::closed_status(status))
                        } else {
                            None
                        };
                        if let Some(status) = status {
                            let text = render::confirmation_closed(&card.body, &status);
                            self.inline.edit(card.inline_id, &text, Some(&[])).await?;
                            self.store.transition_confirmation(
                                &card.key,
                                ConfirmationState::Open,
                                ConfirmationState::Done,
                            )?;
                        }
                    }
                } else if !message.deleted {
                    self.post_confirmation(message, confirmation, anchor)
                        .await?;
                }
            }
            self.inline_soft(self.inline.typing(false).await);
        }
        // A revision describes a fully reconciled snapshot; partial successes
        // above remain durable and safe to revisit after a restart.
        link.revision = Some(message.revision.clone());
        self.store.put_link(&link)?;
        Ok(())
    }

    /// Mirrors the owner's reaction made in the remote app as the owner's own
    /// Inline reaction. The same key records reactions sent from Inline, so an
    /// echo in either direction is a no-op.
    async fn reconcile_owner_reaction(&self, message: &RemoteMessage) -> RelayResult<()> {
        let key = format!("owner_reaction:{}", message.id);
        let current = self.store.kv_get(&key)?.filter(|value| !value.is_empty());
        if current == message.owner_reaction {
            return Ok(());
        }
        let Some(target) = self.store.inline_for_remote(&message.id)? else {
            return Ok(());
        };
        if let Some(old) = current.as_deref() {
            self.inline.react_as_owner(target, old, true).await?;
            self.store.kv_set(&key, "")?;
        }
        if let Some(new) = message.owner_reaction.as_deref() {
            self.inline.react_as_owner(target, new, false).await?;
            self.store.kv_set(&key, new)?;
        }
        Ok(())
    }

    async fn mirror_file(
        &self,
        message: &RemoteMessage,
        file: &RemoteFile,
        reply_to: Option<i64>,
    ) -> RelayResult<()> {
        let part = format!("{}{}", part::FILE_PREFIX, file.key);
        if self.store.link(&message.id, &part)?.is_some()
            || self
                .store
                .kv_get(&file_retry_key(&message.id, &file.key))?
                .is_some()
        {
            return Ok(());
        }
        let owner = message.speaker == Speaker::Owner;
        let name = file.name.clone().unwrap_or_else(|| "file".into());
        let key = format!("remote:{}:{part}", message.id);
        let post = match self.connector.fetch_file(&message.id, file).await {
            Ok(Some(data)) => InlinePost {
                text: String::new(),
                reply_to,
                key,
                file: Some(data),
                buttons: Vec::new(),
                silent: owner,
                as_owner: owner,
            },
            Ok(None) => InlinePost {
                text: self.file_text(
                    owner,
                    &render::file_unavailable(&name, &self.config.network_name),
                ),
                reply_to,
                key,
                file: None,
                buttons: Vec::new(),
                silent: true,
                as_owner: owner,
            },
            Err(error) => {
                log::warn!(target: "inline::bridge::relay", "file download failed: {}", error.message);
                let retry = FileRetry {
                    remote_id: message.id.clone(),
                    key: file.key.clone(),
                    locator: file.locator.clone(),
                    name: file.name.clone(),
                    reply_to,
                    attempts: 1,
                    next_at: now() + 30,
                    owner,
                };
                self.store.kv_set(
                    &file_retry_key(&message.id, &file.key),
                    &serde_json::to_string(&retry).expect("retry serializes"),
                )?;
                return Ok(());
            }
        };
        let inline_id = self.inline.post(&post).await?;
        self.store.put_link(&Link {
            remote_id: message.id.clone(),
            part,
            inline_id: Some(inline_id),
            origin: Origin::Remote,
            revision: None,
            agent_reaction: None,
            rendered: None,
        })?;
        Ok(())
    }

    async fn post_confirmation(
        &self,
        message: &RemoteMessage,
        confirmation: &Confirmation,
        reply_to: Option<i64>,
    ) -> RelayResult<()> {
        if self.store.confirmation(&confirmation.key)?.is_some() {
            return Ok(());
        }
        let body = render::confirmation_body(confirmation);
        let open = confirmation.answerable && confirmation.status == ConfirmationStatus::Pending;
        let (text, buttons, state) = match (&confirmation.status, open) {
            (_, true) => (
                body.clone(),
                confirmation_buttons(&confirmation.key),
                ConfirmationState::Open,
            ),
            (ConfirmationStatus::Pending, false) => (
                render::confirmation_closed(
                    &body,
                    &format!("Answer this in {}.", self.config.network_name),
                ),
                Vec::new(),
                ConfirmationState::Done,
            ),
            (ConfirmationStatus::Closed(status), false) => (
                render::confirmation_closed(&body, &render::closed_status(status)),
                Vec::new(),
                ConfirmationState::Done,
            ),
        };
        let inline_id = self
            .inline
            .post(&InlinePost {
                text,
                reply_to,
                key: format!("remote:{}:confirmation:{}", message.id, confirmation.key),
                file: None,
                buttons,
                silent: false,
                as_owner: false,
            })
            .await?;
        self.store.put_confirmation(&ConfirmationCard {
            key: confirmation.key.clone(),
            remote_id: message.id.clone(),
            inline_id,
            state,
            body,
        })?;
        Ok(())
    }

    async fn apply_task(&self, task: TaskUpdate) -> RelayResult<()> {
        let card = self.apply_task_card(&task).await?;
        let remote_id = format!("task:{}", task.id);
        for entry in &task.entries {
            if entry.text.trim().is_empty() || self.store.link(&remote_id, &entry.id)?.is_some() {
                continue;
            }
            let inline_id = self
                .inline
                .post(&InlinePost {
                    text: render::task_entry(entry),
                    reply_to: Some(card),
                    key: format!("task:{}:{}", task.id, entry.id),
                    file: None,
                    buttons: Vec::new(),
                    silent: entry.speaker != Speaker::Agent,
                    as_owner: false,
                })
                .await?;
            self.store.put_link(&Link {
                remote_id: remote_id.clone(),
                part: entry.id.clone(),
                inline_id: Some(inline_id),
                origin: Origin::Remote,
                revision: None,
                agent_reaction: None,
                rendered: None,
            })?;
        }
        Ok(())
    }

    async fn apply_task_card(&self, task: &TaskUpdate) -> RelayResult<i64> {
        let rendered = render::task_card(task);
        match self.store.task(&task.id)? {
            Some((inline_id, previous)) if previous == rendered => Ok(inline_id),
            Some((inline_id, _)) => {
                self.inline.edit(inline_id, &rendered, None).await?;
                self.store.put_task(&task.id, inline_id, &rendered)?;
                Ok(inline_id)
            }
            None => {
                let anchor = self
                    .store
                    .kv_get(&format!("task_anchor:{}", task.id))?
                    .and_then(|id| id.parse().ok());
                let inline_id = self
                    .inline
                    .post(&InlinePost {
                        text: rendered.clone(),
                        reply_to: anchor,
                        key: format!("task:{}", task.id),
                        file: None,
                        buttons: Vec::new(),
                        silent: true,
                        as_owner: false,
                    })
                    .await?;
                self.store.put_task(&task.id, inline_id, &rendered)?;
                Ok(inline_id)
            }
        }
    }

    // ---------------------------------------------------------------- inline

    /// Applies one event from the owner DM. The caller acknowledges the Inline
    /// delivery only after this returns `Ok`.
    pub async fn handle_inline(&self, event: InlineEvent) -> RelayResult<()> {
        let _guard = self.apply.lock().await;
        match event {
            InlineEvent::Message {
                message_id,
                sender_id,
                text,
                reply_to,
                media,
                edited,
            } => {
                if sender_id != self.config.owner_user_id {
                    return Ok(());
                }
                if edited && self.store.inbound_handled(message_id)? {
                    return self.owner_edit(message_id, &text).await;
                }
                self.owner_message(message_id, text, reply_to, media).await
            }
            InlineEvent::Unsupported {
                message_id,
                sender_id,
            } => {
                if sender_id != self.config.owner_user_id
                    || !self.store.mark_inbound(message_id, "unsupported", now())?
                {
                    return Ok(());
                }
                self.notice(
                    message_id,
                    format!("unsupported:{message_id}"),
                    format!(
                        "This kind of message can't be sent to your {} yet.",
                        self.config.agent_name
                    ),
                )
                .await
            }
            InlineEvent::Deleted { message_id } => self.owner_delete(message_id).await,
            InlineEvent::Typing { user_id, active } => {
                if user_id != self.config.owner_user_id || !active {
                    return Ok(());
                }
                let due = {
                    let mut last = self
                        .owner_typing_at
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    let due = last.is_none_or(|at| at.elapsed() >= OWNER_TYPING_INTERVAL);
                    if due {
                        *last = Some(std::time::Instant::now());
                    }
                    due
                };
                if due && let Err(error) = self.connector.owner_typing().await {
                    log::debug!(target: "inline::bridge::relay", "typing not forwarded: {}", error.message);
                }
                Ok(())
            }
            InlineEvent::Reaction {
                message_id,
                user_id,
                emoji,
                removed,
            } => {
                if user_id != self.config.owner_user_id {
                    return Ok(());
                }
                self.owner_reaction(message_id, &emoji, removed).await
            }
            InlineEvent::Action {
                interaction_id,
                message_id,
                actor_id,
                data,
            } => {
                self.action(interaction_id, message_id, actor_id, &data)
                    .await
            }
        }
    }

    /// Update queued text; delivered messages can only be edited in Inline.
    async fn owner_edit(&self, message_id: i64, text: &str) -> RelayResult<()> {
        if let Some(pending) = self.store.pending_by_inline(message_id)? {
            self.store.update_pending_text(&pending.request_id, text)?;
            let key = format!("queued_edit_notice:{message_id}");
            if self.store.kv_get(&key)?.is_none() {
                self.notice(
                    message_id,
                    key.clone(),
                    "Updated the queued message. The bridge will check delivery before retrying."
                        .into(),
                )
                .await?;
                self.store.kv_set(&key, "1")?;
            }
            return Ok(());
        }
        if self.store.remote_for_inline(message_id)?.is_none() {
            return Ok(());
        }
        let key = format!("edit_notice:{message_id}");
        if self.store.kv_get(&key)?.is_some() {
            return Ok(());
        }
        self.notice(
            message_id,
            key.clone(),
            format!(
                "Edits stay in Inline. Your {} still has the original; send a new message to change it.",
                self.config.agent_name
            ),
        )
        .await?;
        self.store.kv_set(&key, "1")?;
        Ok(())
    }

    /// Deletions cannot reach the remote; say so once for a delivered message.
    async fn owner_delete(&self, message_id: i64) -> RelayResult<()> {
        let Some(remote_id) = self.store.remote_for_inline(message_id)? else {
            return Ok(());
        };
        let Some(link) = self.store.link(&remote_id, part::TEXT)? else {
            return Ok(());
        };
        if link.origin != Origin::Inline || link.inline_id != Some(message_id) {
            return Ok(());
        }
        let key = format!("delete_notice:{message_id}");
        if self.store.kv_get(&key)?.is_some() {
            return Ok(());
        }
        self.store.kv_set(&key, "1")?;
        self.inline
            .post(&InlinePost {
                text: format!(
                    "_You deleted a message here. It is still in {}; it can't be deleted from Inline._",
                    self.config.network_name
                ),
                reply_to: None,
                key,
                file: None,
                buttons: Vec::new(),
                silent: true,
                as_owner: false,
            })
            .await?;
        Ok(())
    }

    async fn notice(&self, reply_to: i64, key: String, text: String) -> RelayResult<()> {
        self.inline
            .post(&InlinePost {
                text,
                reply_to: Some(reply_to),
                key,
                file: None,
                buttons: Vec::new(),
                silent: true,
                as_owner: false,
            })
            .await?;
        Ok(())
    }

    async fn owner_message(
        &self,
        message_id: i64,
        text: String,
        reply_to: Option<i64>,
        media: Option<InlineMedia>,
    ) -> RelayResult<()> {
        if self.store.inbound_handled(message_id)? {
            return Ok(());
        }
        if let Some(reply) = self.command(&text).await? {
            self.notice(message_id, format!("command:{message_id}"), reply)
                .await?;
            self.store.mark_inbound(message_id, "command", now())?;
            return Ok(());
        }
        let capabilities = self.connector.capabilities();
        if media.is_some() && !capabilities.send_files {
            self.notice(
                message_id,
                format!("rejected:{message_id}"),
                format!(
                    "{} can't receive files from Inline yet.",
                    self.config.agent_name
                ),
            )
            .await?;
            self.store.mark_inbound(message_id, "rejected", now())?;
            return Ok(());
        }
        if text.trim().is_empty() && media.is_none() {
            self.store.mark_inbound(message_id, "empty", now())?;
            return Ok(());
        }
        let remote_reply_to = match reply_to {
            Some(parent) => self.remote_target(parent)?,
            None => None,
        };
        let pending = PendingSend {
            request_id: correlation_id(&self.config.request_salt, message_id),
            inline_id: message_id,
            reply_to: remote_reply_to,
            text,
            media: media.as_ref().map(|media| {
                serde_json::to_string(&StoredMedia {
                    url: media.url.clone(),
                    name: media.name.clone(),
                    mime: media.mime.clone(),
                    size: media.size,
                })
                .expect("media serializes")
            }),
            attempts: 0,
            next_attempt_at: now(),
        };
        self.store.reserve_send(&pending)?;
        self.store.mark_inbound(message_id, "reserved", now())?;
        self.publish_pending_count()?;
        self.attempt_send(pending).await
    }

    async fn attempt_send(&self, pending: PendingSend) -> RelayResult<()> {
        let attempts = pending.attempts + 1;
        // A retry first checks whether an earlier attempt already landed.
        if pending.attempts > 0 {
            match self
                .connector
                .find_sent(&pending.request_id, pending.reply_to.as_deref())
                .await
            {
                Ok(Some(remote_id)) => {
                    self.settle_delivered(&pending, &remote_id).await?;
                    return self.publish_pending_count();
                }
                Ok(None) => {}
                Err(error) => return self.defer(&pending, attempts, &error).await,
            }
        }
        let file = match &pending.media {
            None => None,
            Some(raw) => {
                let stored: StoredMedia = serde_json::from_str(raw).map_err(|error| {
                    RelayError::Store(StoreError::from(rusqlite::Error::ToSqlConversionFailure(
                        Box::new(error),
                    )))
                })?;
                let media = InlineMedia {
                    url: stored.url,
                    name: stored.name,
                    mime: stored.mime,
                    size: stored.size,
                };
                let limit = self.connector.capabilities().max_file_bytes;
                match self.inline.fetch_media(&media, limit).await {
                    Ok(data) => Some(data),
                    Err(error) => {
                        self.store.settle_send(&pending.request_id, None)?;
                        self.publish_pending_count()?;
                        return self
                            .notice(
                                pending.inline_id,
                                format!("failed:{}", pending.inline_id),
                                format!("Couldn't send that file: {error}"),
                            )
                            .await;
                    }
                }
            }
        };
        let outbound = OutboundMessage {
            request_id: pending.request_id.clone(),
            text: pending.text.clone(),
            file,
            reply_to: pending.reply_to.clone(),
        };
        self.store.kv_set(
            &format!("attempted_text:{}", pending.inline_id),
            &text_hash(&pending.text),
        )?;
        match self.connector.send(&outbound).await {
            Ok(remote_id) => {
                self.settle_delivered(&pending, &remote_id).await?;
                // Writing back means the owner has read everything before it.
                if let Err(error) = self.connector.mark_read(&remote_id).await {
                    log::debug!(target: "inline::bridge::relay", "read state not sent: {}", error.message);
                }
                self.publish_pending_count()
            }
            Err(error) if error.kind == FailureKind::Rejected => {
                self.store.settle_send(&pending.request_id, None)?;
                self.publish_pending_count()?;
                self.notice(
                    pending.inline_id,
                    format!("failed:{}", pending.inline_id),
                    format!(
                        "{} didn't accept this message: {}",
                        self.config.network_name, error.message
                    ),
                )
                .await
            }
            Err(error) => self.defer(&pending, attempts, &error).await,
        }
    }

    async fn settle_delivered(&self, pending: &PendingSend, remote_id: &str) -> RelayResult<()> {
        // A queued edit cannot change a POST that already reached the remote
        // while its response was lost. Keep the correlation id and explain
        // which version landed rather than sending a duplicate.
        if self
            .store
            .kv_get(&format!("queued_edit_notice:{}", pending.inline_id))?
            .is_some()
            && self
                .store
                .kv_get(&format!("attempted_text:{}", pending.inline_id))?
                .is_some_and(|attempted| attempted != text_hash(&pending.text))
        {
            self.notice(pending.inline_id, format!("queued_edit_delivered:{}", pending.inline_id),
                format!("{} received the earlier version before your edit. Send a new message with the correction.", self.config.network_name)).await?;
        }
        self.store
            .settle_send(&pending.request_id, Some(remote_id))?;
        Ok(())
    }

    async fn defer(
        &self,
        pending: &PendingSend,
        attempts: u32,
        error: &ConnectorError,
    ) -> RelayResult<()> {
        if attempts >= MAX_SEND_ATTEMPTS {
            self.store.settle_send(&pending.request_id, None)?;
            self.publish_pending_count()?;
            return self
                .notice(
                    pending.inline_id,
                    format!("failed:{}", pending.inline_id),
                    format!(
                        "Couldn't deliver this to {} after several tries ({}). Send it again if it isn't there.",
                        self.config.agent_name, error.message
                    ),
                )
                .await;
        }
        let delay = 15i64 << attempts.min(6);
        self.store
            .defer_send(&pending.request_id, attempts, now() + delay.min(900))?;
        let notice_key = format!("delayed_notice:{}", pending.inline_id);
        if self.store.kv_get(&notice_key)?.is_none() {
            let reason = if error.kind == FailureKind::NeedsLogin {
                format!("{} sign-in is needed", self.config.network_name)
            } else {
                error.message.clone()
            };
            self.notice(
                pending.inline_id,
                format!("delayed:{}", pending.inline_id),
                format!("Not delivered yet ({reason}). The bridge will keep trying."),
            )
            .await?;
            self.store.kv_set(&notice_key, "1")?;
        }
        Ok(())
    }

    /// Retries due reservations. Runs on a timer inside `run_remote`.
    pub async fn retry_pending(&self) -> RelayResult<()> {
        let _guard = self.apply.lock().await;
        self.retry_files().await?;
        let now = now();
        for pending in self.store.pending_sends()? {
            if pending.next_attempt_at > now {
                continue;
            }
            // Mark as tried before the network call so a crash in between is
            // reconciled with `find_sent` rather than blindly resent.
            let pending = PendingSend {
                attempts: pending.attempts.max(1),
                ..pending
            };
            self.attempt_send(pending).await?;
        }
        Ok(())
    }

    async fn retry_files(&self) -> RelayResult<()> {
        for (key, raw) in self.store.kv_prefix(FILE_RETRY_PREFIX)? {
            let Ok(mut retry) = serde_json::from_str::<FileRetry>(&raw) else {
                self.store.kv_delete(&key)?;
                continue;
            };
            if retry.next_at > now() {
                continue;
            }
            let part = format!("{}{}", part::FILE_PREFIX, retry.key);
            if self.store.link(&retry.remote_id, &part)?.is_some() {
                self.store.kv_delete(&key)?;
                continue;
            }
            let file = RemoteFile {
                key: retry.key.clone(),
                locator: retry.locator.clone(),
                name: retry.name.clone(),
            };
            let name = retry.name.clone().unwrap_or_else(|| "file".into());
            let unavailable = render::file_unavailable(&name, &self.config.network_name);
            let post = match self.connector.fetch_file(&retry.remote_id, &file).await {
                Ok(Some(data)) => Some((Some(data), String::new(), false)),
                Ok(None) => Some((None, unavailable, true)),
                Err(_) if retry.attempts + 1 >= MAX_FILE_ATTEMPTS => {
                    Some((None, unavailable, true))
                }
                Err(_) => None,
            };
            match post {
                Some((file, text, silent)) => {
                    let inline_id = self
                        .inline
                        .post(&InlinePost {
                            text: self.file_text(retry.owner, &text),
                            reply_to: retry.reply_to,
                            key: format!("remote:{}:{part}", retry.remote_id),
                            file,
                            buttons: Vec::new(),
                            silent: silent || retry.owner,
                            as_owner: retry.owner,
                        })
                        .await?;
                    self.store.put_link(&Link {
                        remote_id: retry.remote_id.clone(),
                        part,
                        inline_id: Some(inline_id),
                        origin: Origin::Remote,
                        revision: None,
                        agent_reaction: None,
                        rendered: None,
                    })?;
                    self.store.kv_delete(&key)?;
                }
                None => {
                    retry.attempts += 1;
                    retry.next_at = now() + (30i64 << retry.attempts.min(5)).min(900);
                    self.store.kv_set(
                        &key,
                        &serde_json::to_string(&retry).expect("retry serializes"),
                    )?;
                }
            }
        }
        Ok(())
    }

    fn file_text(&self, owner: bool, text: &str) -> String {
        // Owner files are posted from the owner's account, so no label.
        let _ = owner;
        text.to_owned()
    }

    fn synthetic_task(&self, inline_id: i64) -> RelayResult<Option<String>> {
        if let Some(task) = self.store.task_by_inline(inline_id)? {
            return Ok(Some(task));
        }
        Ok(self
            .store
            .remote_for_inline(inline_id)?
            .and_then(|id| id.strip_prefix("task:").map(str::to_owned)))
    }

    fn remote_target(&self, inline_id: i64) -> RelayResult<Option<String>> {
        if let Some(task) = self.synthetic_task(inline_id)? {
            return Ok(self.store.kv_get(&format!("task_anchor_remote:{task}"))?);
        }
        Ok(self.store.remote_for_inline(inline_id)?)
    }

    async fn owner_reaction(&self, message_id: i64, emoji: &str, removed: bool) -> RelayResult<()> {
        if !self.connector.capabilities().reactions {
            return Ok(());
        }
        if self.synthetic_task(message_id)?.is_some() {
            return Ok(());
        }
        let Some(remote_id) = self.store.remote_for_inline(message_id)? else {
            return Ok(());
        };
        let key = format!("owner_reaction:{remote_id}");
        let current = self.store.kv_get(&key)?.filter(|value| !value.is_empty());
        // Already in this state: an echo of a reaction this relay mirrored.
        if !removed && current.as_deref() == Some(emoji) {
            return Ok(());
        }
        let result = if removed {
            // The remote keeps one reaction per person; only clear it if it
            // is still the one being removed.
            if current.as_deref() != Some(emoji) {
                return Ok(());
            }
            self.connector.set_reaction(&remote_id, None).await
        } else {
            self.connector.set_reaction(&remote_id, Some(emoji)).await
        };
        match result {
            Ok(()) => {
                self.store.kv_set(&key, if removed { "" } else { emoji })?;
                // The remote keeps one reaction per person and just replaced
                // the old one; mirror that so both sides show the same.
                if !removed
                    && let Some(old) = current.as_deref()
                    && let Err(error) = self.inline.react_as_owner(message_id, old, true).await
                {
                    log::warn!(target: "inline::bridge::relay", "replaced reaction not cleared: {error}");
                }
            }
            Err(error) => {
                log::warn!(target: "inline::bridge::relay", "reaction not forwarded: {}", error.message);
            }
        }
        Ok(())
    }

    async fn action(
        &self,
        interaction_id: i64,
        message_id: i64,
        actor_id: i64,
        data: &[u8],
    ) -> RelayResult<()> {
        let answer = |toast: &'static str| async move {
            self.inline_soft(self.inline.answer_action(interaction_id, Some(toast)).await);
            Ok::<(), RelayError>(())
        };
        let Ok(callback) = serde_json::from_slice::<ConfirmationCallback>(data) else {
            return answer("This button is no longer active.").await;
        };
        if callback.v != CONFIRMATION_CALLBACK_VERSION {
            return answer("This button is no longer active.").await;
        }
        if actor_id != self.config.owner_user_id {
            return answer("Only the bot owner can answer this.").await;
        }
        let accept = match callback.a.as_str() {
            "accept" => true,
            "decline" => false,
            _ => return answer("This button is no longer active.").await,
        };
        let Some(card) = self.store.confirmation(&callback.k)? else {
            return answer("This request is no longer active.").await;
        };
        if card.inline_id != message_id {
            return answer("This button is no longer active.").await;
        }
        if card.state == ConfirmationState::Answering
            && let Some(text) = self
                .store
                .kv_get(&format!("confirmation_result:{}", card.key))?
        {
            self.finish_confirmation(&card, &text).await?;
            return answer("This request was already answered.").await;
        }
        if !self.store.transition_confirmation(
            &card.key,
            ConfirmationState::Open,
            ConfirmationState::Answering,
        )? {
            return answer("This request was already answered.").await;
        }
        self.inline_soft(
            self.inline
                .answer_action(interaction_id, Some("Sending your answer…"))
                .await,
        );
        let status = match self
            .connector
            .answer_confirmation(&card.remote_id, &card.key, accept)
            .await
        {
            Ok(ConfirmationAnswer::Applied) => {
                if accept {
                    "✅ Approved.".to_owned()
                } else {
                    "Declined.".to_owned()
                }
            }
            Ok(ConfirmationAnswer::NotApplied(reason)) => {
                format!("Not applied: {reason}. Check {}.", self.config.network_name)
            }
            Err(error) => format!(
                "Couldn't send your answer ({}). Answer it in {}.",
                error.message, self.config.network_name
            ),
        };
        let text = render::confirmation_closed(&card.body, &status);
        self.store
            .kv_set(&format!("confirmation_result:{}", card.key), &text)?;
        self.finish_confirmation(&card, &text).await
    }

    async fn finish_confirmation(&self, card: &ConfirmationCard, text: &str) -> RelayResult<()> {
        self.inline.edit(card.inline_id, text, Some(&[])).await?;
        self.store.transition_confirmation(
            &card.key,
            ConfirmationState::Answering,
            ConfirmationState::Done,
        )?;
        Ok(())
    }

    async fn command(&self, text: &str) -> RelayResult<Option<String>> {
        let trimmed = text.trim();
        let Some(command) = trimmed.strip_prefix('/') else {
            return Ok(None);
        };
        let mut words = command.split_whitespace();
        let name = words
            .next()
            .unwrap_or("")
            .split('@')
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();
        Ok(Some(match name.as_str() {
            "help" => render::help(&self.config.agent_name, &self.config.network_name),
            "status" => {
                let health = self.health.borrow().clone();
                let detail = self.connector.describe().await;
                render::status(
                    &self.config.network_name,
                    &health,
                    &detail,
                    self.mirror_owner()?,
                )
            }
            "mirror" => match words.next() {
                Some("on") => {
                    self.store.kv_set(MIRROR_OWNER_KEY, "on")?;
                    format!(
                        "Messages you type in {} will show up here.",
                        self.config.network_name
                    )
                }
                Some("off") => {
                    self.store.kv_set(MIRROR_OWNER_KEY, "off")?;
                    format!(
                        "Messages you type in {} will no longer show up here.",
                        self.config.network_name
                    )
                }
                _ => "Use `/mirror on` or `/mirror off`.".into(),
            },
            // Unknown slash text goes to the agent as typed.
            _ => return Ok(None),
        }))
    }
}

fn confirmation_buttons(key: &str) -> Vec<Vec<Button>> {
    let data = |action: &str| {
        serde_json::to_vec(&ConfirmationCallback {
            v: CONFIRMATION_CALLBACK_VERSION,
            k: key.to_owned(),
            a: action.to_owned(),
        })
        .expect("callback serializes")
    };
    vec![vec![
        Button {
            id: "relay_confirm_accept".into(),
            label: "Approve".into(),
            data: data("accept"),
        },
        Button {
            id: "relay_confirm_decline".into(),
            label: "Decline".into(),
            data: data("decline"),
        },
    ]]
}

/// Stable, UUID-shaped correlation id for one Inline message.
pub fn correlation_id(salt: &str, inline_message_id: i64) -> String {
    let digest = Sha256::digest(format!("inline-relay-v1\0{salt}\0{inline_message_id}"));
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

fn text_hash(text: &str) -> String {
    format!("{:x}", Sha256::digest(text.as_bytes()))
}

fn file_retry_key(remote_id: &str, key: &str) -> String {
    format!("{FILE_RETRY_PREFIX}{remote_id}\u{1f}{key}")
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}
