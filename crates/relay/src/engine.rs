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
const MAX_SEND_ATTEMPTS: u32 = 8;
const CONFIRMATION_CALLBACK_VERSION: u32 = 1;

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
    /// Inline message id of the text a task was announced with.
    task_anchors: std::sync::Mutex<HashMap<String, i64>>,
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
            task_anchors: Default::default(),
        }
    }

    /// Health updates.
    pub fn health(&self) -> watch::Receiver<RelayHealth> {
        self.health.subscribe()
    }

    /// Settles state left by a previous run. Call once before `run_remote`.
    pub async fn recover(&self) -> RelayResult<()> {
        let _guard = self.apply.lock().await;
        // An answer that was in flight may or may not have landed; it is
        // never resent.
        for card in self.store.confirmations_in(ConfirmationState::Answering)? {
            if self.store.transition_confirmation(
                &card.key,
                ConfirmationState::Answering,
                ConfirmationState::Done,
            )? {
                let text = render::confirmation_closed(
                    &card.body,
                    &format!(
                        "The bridge restarted while sending your answer. Check {} to see whether it went through.",
                        self.config.network_name
                    ),
                );
                self.inline_soft(self.inline.edit(card.inline_id, &text, Some(&[])).await);
            }
        }
        self.publish_pending_count()?;
        Ok(())
    }

    /// Runs the remote side until `shutdown` turns true. Restarts the
    /// connector with backoff after failures.
    pub async fn run_remote(&self, mut shutdown: watch::Receiver<bool>) -> RelayResult<()> {
        let mut backoff = Duration::from_secs(3);
        loop {
            if *shutdown.borrow() {
                return Ok(());
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
                            Some(event) => self.handle_remote(event).await?,
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
                        _ = tick.tick() => self.retry_pending().await?,
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

    fn set_connector_health(&self, health: ConnectorHealth) {
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
        }
    }

    async fn apply_message(&self, message: RemoteMessage) -> RelayResult<()> {
        // Echo of a message this relay sent.
        if message.speaker == Speaker::Owner
            && let Some(request_id) = message.client_request_id.as_deref()
            && self.store.pending_by_request(request_id)?.is_some()
        {
            self.store.settle_send(request_id, Some(&message.id))?;
            self.publish_pending_count()?;
        }
        match self.store.link(&message.id, part::TEXT)? {
            Some(link) => self.apply_update(&message, link).await,
            None => self.apply_new(&message).await,
        }
    }

    async fn apply_new(&self, message: &RemoteMessage) -> RelayResult<()> {
        let reply_to = match message.reply_to.as_deref() {
            Some(parent) => self.store.inline_for_remote(parent)?,
            None => None,
        };
        let mut text_link = Link {
            remote_id: message.id.clone(),
            part: part::TEXT.into(),
            inline_id: None,
            origin: Origin::Remote,
            revision: Some(message.revision.clone()),
            agent_reaction: None,
        };
        if message.deleted {
            return Ok(self.store.put_link(&text_link)?);
        }
        if message.speaker == Speaker::Owner {
            if self.mirror_owner()? && !message.text.trim().is_empty() {
                let post = InlinePost {
                    text: render::owner_mirror(&self.config.network_name, &message.text),
                    reply_to,
                    key: format!("remote:{}:text", message.id),
                    file: None,
                    buttons: Vec::new(),
                    silent: true,
                };
                text_link.inline_id = Some(self.inline.post(&post).await?);
            }
            return Ok(self.store.put_link(&text_link)?);
        }

        // Agent message.
        if !message.text.trim().is_empty() {
            let post = InlinePost {
                text: render::agent_text(&message.text),
                reply_to,
                key: format!("remote:{}:text", message.id),
                file: None,
                buttons: Vec::new(),
                silent: false,
            };
            text_link.inline_id = Some(self.inline.post(&post).await?);
        }
        if let Some(emoji) = message.agent_reaction.as_deref()
            && let Some(target) = text_link.inline_id
        {
            self.inline_soft(self.inline.react(target, emoji, false).await);
            text_link.agent_reaction = Some(emoji.to_owned());
        }
        self.store.put_link(&text_link)?;
        self.inline_soft(self.inline.typing(false).await);

        for file in &message.files {
            self.mirror_file(message, file, reply_to).await?;
        }
        let anchor = text_link.inline_id.or(reply_to);
        if let Some(task_id) = &message.task_id
            && let Some(anchor) = anchor
        {
            self.task_anchors
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .insert(task_id.clone(), anchor);
        }
        if let Some(confirmation) = &message.confirmation {
            self.post_confirmation(message, confirmation, anchor)
                .await?;
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
        if self.store.link(&message.id, &part)?.is_some() {
            return Ok(());
        }
        let name = file.name.clone().unwrap_or_else(|| "file".into());
        let key = format!("remote:{}:{part}", message.id);
        let post = match self.connector.fetch_file(&message.id, file).await {
            Ok(Some(data)) => InlinePost {
                text: String::new(),
                reply_to,
                key,
                file: Some(data),
                buttons: Vec::new(),
                silent: false,
            },
            Ok(None) => InlinePost {
                text: render::file_unavailable(&name, &self.config.network_name),
                reply_to,
                key,
                file: None,
                buttons: Vec::new(),
                silent: true,
            },
            Err(error) => {
                log::warn!(target: "inline::bridge::relay", "file download failed: {}", error.message);
                InlinePost {
                    text: render::file_unavailable(&name, &self.config.network_name),
                    reply_to,
                    key,
                    file: None,
                    buttons: Vec::new(),
                    silent: true,
                }
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

    async fn apply_update(&self, message: &RemoteMessage, mut link: Link) -> RelayResult<()> {
        let revision_changed = link.revision.as_deref() != Some(message.revision.as_str());
        let reaction_changed = link.agent_reaction != message.agent_reaction;
        if !revision_changed && !reaction_changed {
            return Ok(());
        }
        if revision_changed
            && link.origin == Origin::Remote
            && let Some(inline_id) = link.inline_id
        {
            let text = if message.deleted {
                render::deleted(&self.config.network_name)
            } else if message.speaker == Speaker::Owner {
                render::owner_mirror(&self.config.network_name, &message.text)
            } else {
                render::agent_text(&message.text)
            };
            self.inline_soft(self.inline.edit(inline_id, &text, None).await);
        }
        if reaction_changed {
            let target = match link.inline_id {
                Some(id) => Some(id),
                None => self.store.inline_for_remote(&message.id)?,
            };
            if let Some(target) = target {
                if let Some(old) = link.agent_reaction.as_deref() {
                    self.inline_soft(self.inline.react(target, old, true).await);
                }
                if let Some(new) = message.agent_reaction.as_deref() {
                    self.inline_soft(self.inline.react(target, new, false).await);
                }
            }
            link.agent_reaction = message.agent_reaction.clone();
        }
        link.revision = Some(message.revision.clone());
        self.store.put_link(&link)?;

        if message.speaker == Speaker::Agent && !message.deleted {
            for file in &message.files {
                self.mirror_file(message, file, link.inline_id).await?;
            }
            if let Some(task_id) = &message.task_id
                && let Some(anchor) = link.inline_id
            {
                self.task_anchors
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .entry(task_id.clone())
                    .or_insert(anchor);
            }
        }
        if let Some(confirmation) = &message.confirmation {
            match self.store.confirmation(&confirmation.key)? {
                None if message.speaker == Speaker::Agent && !message.deleted => {
                    self.post_confirmation(message, confirmation, link.inline_id)
                        .await?;
                }
                Some(card) => {
                    if let ConfirmationStatus::Closed(status) = &confirmation.status
                        && self.store.transition_confirmation(
                            &card.key,
                            ConfirmationState::Open,
                            ConfirmationState::Done,
                        )?
                    {
                        let text =
                            render::confirmation_closed(&card.body, &render::closed_status(status));
                        self.inline_soft(self.inline.edit(card.inline_id, &text, Some(&[])).await);
                    }
                }
                None => {}
            }
        }
        Ok(())
    }

    async fn apply_task(&self, task: TaskUpdate) -> RelayResult<()> {
        let rendered = render::task_card(&task);
        match self.store.task(&task.id)? {
            Some((_, previous)) if previous == rendered => Ok(()),
            Some((inline_id, _)) => {
                self.inline_soft(self.inline.edit(inline_id, &rendered, None).await);
                Ok(self.store.put_task(&task.id, inline_id, &rendered)?)
            }
            None => {
                let anchor = self
                    .task_anchors
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .get(&task.id)
                    .copied();
                let inline_id = self
                    .inline
                    .post(&InlinePost {
                        text: rendered.clone(),
                        reply_to: anchor,
                        key: format!("task:{}", task.id),
                        file: None,
                        buttons: Vec::new(),
                        silent: true,
                    })
                    .await?;
                Ok(self.store.put_task(&task.id, inline_id, &rendered)?)
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
            } => {
                if sender_id != self.config.owner_user_id {
                    return Ok(());
                }
                self.owner_message(message_id, text, reply_to, media).await
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

    async fn notice(&self, reply_to: i64, key: String, text: String) -> RelayResult<()> {
        self.inline
            .post(&InlinePost {
                text,
                reply_to: Some(reply_to),
                key,
                file: None,
                buttons: Vec::new(),
                silent: true,
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
            Some(parent) => self.store.remote_for_inline(parent)?,
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
                    self.store
                        .settle_send(&pending.request_id, Some(&remote_id))?;
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
        match self.connector.send(&outbound).await {
            Ok(remote_id) => {
                self.store
                    .settle_send(&pending.request_id, Some(&remote_id))?;
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
        if attempts == 1 {
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
        }
        Ok(())
    }

    /// Retries due reservations. Runs on a timer inside `run_remote`.
    pub async fn retry_pending(&self) -> RelayResult<()> {
        let _guard = self.apply.lock().await;
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

    async fn owner_reaction(&self, message_id: i64, emoji: &str, removed: bool) -> RelayResult<()> {
        if !self.connector.capabilities().reactions {
            return Ok(());
        }
        let Some(remote_id) = self.store.remote_for_inline(message_id)? else {
            return Ok(());
        };
        let key = format!("owner_reaction:{remote_id}");
        let current = self.store.kv_get(&key)?;
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
        if card.inline_id != message_id
            || !self.store.transition_confirmation(
                &card.key,
                ConfirmationState::Open,
                ConfirmationState::Answering,
            )?
        {
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
        self.store.transition_confirmation(
            &card.key,
            ConfirmationState::Answering,
            ConfirmationState::Done,
        )?;
        let text = render::confirmation_closed(&card.body, &status);
        self.inline_soft(self.inline.edit(card.inline_id, &text, Some(&[])).await);
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

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}
