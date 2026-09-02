//! Inline event routing, streaming presentation, approvals, and turn execution.

use super::*;

pub(super) struct TurnLanePromotion {
    pub source_chat_id: i64,
    pub delivery_chat_id: i64,
    pub sender: tokio::sync::mpsc::Sender<LosslessEventDelivery>,
    pub acknowledged: tokio::sync::oneshot::Sender<bool>,
}

pub(super) async fn send_inbound_response(
    bot: &InlineClient,
    route: &InboundRoute,
    record: &InboundRecord,
    chat_id: i64,
    text: &str,
    external_id: &str,
    notification_class: BridgeNotificationClass,
) -> Result<inline_client::MessageMutation, Box<dyn std::error::Error>> {
    let source_message = route
        .bot_store
        .message(
            InlineId::new(record.binding.chat_id),
            InlineId::new(record.message_id),
        )
        .await?;
    let sender_is_bot = match source_message.as_ref() {
        Some(message) => message_sender_is_bot(&route.bot_store, message).await?,
        None => false,
    };
    if sender_is_bot {
        send_text_message(bot, chat_id, text, external_id, notification_class).await
    } else {
        send_text_reply(
            bot,
            chat_id,
            record.message_id,
            text,
            external_id,
            notification_class,
        )
        .await
    }
}

mod admission;
use admission::{
    accept_inbound_or_session_handoff, handle_follow_command, handle_queue_undo_action,
};
pub(super) use admission::{accept_provider_unavailable_delivery, recover_failed_delivery};
mod conversation;
pub(in crate::bridge) use conversation::*;
mod content;
use content::*;
mod queue_ui;
pub(in crate::bridge) use queue_ui::*;
#[cfg(test)]
mod authorization_tests;
#[cfg(test)]
mod release_acceptance;

const APPROVAL_TTL_SECONDS: i64 = 15 * 60;
const QUESTION_TTL_SECONDS: i64 = 15 * 60;
const ACTIVE_STOP_CONFIRMATION_TIMEOUT: Duration = Duration::from_secs(5);
const VOICE_TRANSCRIPT_WAIT: Duration = Duration::from_secs(10);
const BOT_AGENT_CACHE_TTL: Duration = Duration::from_secs(60);
const BOT_AGENT_NEGATIVE_CACHE_TTL: Duration = Duration::from_secs(15);
const BOT_AGENT_CACHE_MAX_ENTRIES: usize = 100;
pub(super) const MAX_PENDING_VOICE_TRANSCRIPTS: usize = 64;

#[cfg(not(test))]
const INITIAL_RESPONSE_DELAY: Duration = Duration::from_millis(100);
#[cfg(test)]
const INITIAL_RESPONSE_DELAY: Duration = Duration::from_millis(10);

fn runtime_agent_event_kind(event: &AgentEvent) -> &'static str {
    match event {
        AgentEvent::TurnStarted { .. } => "turn_started",
        AgentEvent::AgentMessage { .. } => "agent_message",
        AgentEvent::AgentTextDelta { .. } => "agent_text_delta",
        AgentEvent::AgentTextCompleted { .. } => "agent_text_completed",
        AgentEvent::Activity { .. } => "activity",
        AgentEvent::ActivityUpsert { .. } => "activity_upsert",
        AgentEvent::ActivityTextDelta { .. } => "activity_text_delta",
        AgentEvent::PlanUpdated { .. } => "plan_updated",
        AgentEvent::ApprovalRequested(_) => "approval_requested",
        AgentEvent::ApprovalClosed { .. } => "approval_closed",
        AgentEvent::QuestionRequested(_) => "question_requested",
        AgentEvent::FilesChanged { .. } => "files_changed",
        AgentEvent::OutputAttachment { .. } => "output_attachment",
        AgentEvent::TurnCompleted { .. } => "turn_completed",
    }
}

pub(super) fn replace_direction_text(direction: &mut Direction, text: impl Into<String>) {
    direction.text = text.into();
}

fn reconcile_replayed_queue_delivery(
    store: &BridgeStore,
    coordinator: &mut TurnCoordinator,
    record: &InboundRecord,
    queue_id: &QueueItemId,
    was_already_queued: bool,
) -> inline_agent_bridge::StoreResult<()> {
    let enriched = store.enrich_accepted_inbound_attachments(record)?;
    if enriched {
        let mirrored = coordinator.enrich_queued_attachments(queue_id, &record.direction);
        log::trace!(
            target: "inline::bridge::media",
            "phase=inbound_attachment_enriched event_id={:?} attachment_count={} mirrored_in_memory={mirrored}",
            record.event_id,
            record.direction.attachments.len()
        );
    }

    let remains_durably_queued = store
        .get_inbound(&record.event_id)?
        .is_some_and(|stored| stored.state == InboundState::Accepted);
    if !was_already_queued && !remains_durably_queued {
        let _ = coordinator.undo_queue(queue_id);
    }
    Ok(())
}

#[derive(Clone)]
pub(super) struct InboundRoute {
    pub store: Arc<BridgeStore>,
    pub installation_id: InstallationId,
    pub provider_id: ProviderId,
    pub policy: Arc<RwLock<OperatorPolicy>>,
    pub owner_user_id: i64,
    pub host_label: String,
    pub owner_dm_chat_id: i64,
    pub bot_user_id: i64,
    pub bot_username: String,
    pub bot_store: SqliteStore,
    pub attachment_cache_dir: PathBuf,
    pub owner_control: Option<Arc<OwnerControl>>,
    pub accept_messages_after: i64,
    pub deferred_inbound_tx: tokio::sync::mpsc::Sender<InboundRecord>,
    pub pending_voice_messages: Arc<std::sync::Mutex<HashSet<(i64, i64)>>>,
    pub claude_history: Option<ClaudeHistoryRuntime>,
    pub control_lane: Arc<tokio::sync::Semaphore>,
    pub control_epoch: ControlTaskEpoch,
    pub bot_agent_resolver: BotAgentResolver,
}

#[derive(Clone)]
pub(super) struct ControlTaskEpoch {
    version: tokio::sync::watch::Sender<u64>,
}

impl ControlTaskEpoch {
    pub fn new() -> Self {
        let (version, _) = tokio::sync::watch::channel(0);
        Self { version }
    }

    pub fn subscribe(&self) -> tokio::sync::watch::Receiver<u64> {
        self.version.subscribe()
    }

    pub fn advance(&self) {
        self.version.send_modify(|version| {
            *version = version.wrapping_add(1);
        });
    }
}

impl std::fmt::Debug for ControlTaskEpoch {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("ControlTaskEpoch(<generation>)")
    }
}

#[derive(Clone)]
pub(super) struct BotAgentResolver {
    realtime_url: String,
    bot_token: String,
    cache: Arc<RwLock<BotAgentCache>>,
    configuration_catalog: Arc<RwLock<Option<AgentConfigurationCatalog>>>,
    resolution_lock: Arc<tokio::sync::Mutex<()>>,
}

type BotAgentCache = HashMap<i64, (Instant, Option<proto::BotAgent>)>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum AgentConfigurationFallback {
    Catalog,
    Project,
    Model,
    Reasoning,
}

impl AgentConfigurationFallback {
    pub const fn code(self) -> &'static str {
        match self {
            Self::Catalog => "agent_configuration_catalog_defaulted",
            Self::Project => "agent_project_defaulted",
            Self::Model => "agent_model_defaulted",
            Self::Reasoning => "agent_reasoning_defaulted",
        }
    }

    pub const fn message(self) -> &'static str {
        "Some selected Agent settings are unavailable, so I’m using this provider’s defaults. Your request is still continuing."
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct ResolvedAgentConfiguration {
    pub model: Option<String>,
    pub reasoning: Option<String>,
    pub fallback: Option<AgentConfigurationFallback>,
}

fn agent_thread_context_to_proto(
    context: inline_client::AgentThreadContext,
) -> proto::AgentThreadContext {
    proto::AgentThreadContext {
        bot_user_id: context.bot_user_id.get(),
        agent_id: context.agent_id.map(InlineId::get),
        configuration: context
            .configuration
            .map(|configuration| proto::AgentThreadConfiguration {
                project_id: configuration.project_id,
                model_id: configuration.model_id,
                reasoning_effort_id: configuration.reasoning_effort_id,
            }),
    }
}

impl BotAgentResolver {
    pub fn new(realtime_url: String, bot_token: String) -> Self {
        Self {
            realtime_url,
            bot_token,
            cache: Arc::new(RwLock::new(HashMap::new())),
            configuration_catalog: Arc::new(RwLock::new(None)),
            resolution_lock: Arc::new(tokio::sync::Mutex::new(())),
        }
    }

    #[cfg(test)]
    pub fn disabled() -> Self {
        Self::new(String::new(), String::new())
    }

    async fn resolve(&self, agent_id: i64) -> Option<proto::BotAgent> {
        if let Some(cached) = self.cached(agent_id) {
            return cached;
        }
        if self.realtime_url.is_empty() || self.bot_token.is_empty() {
            return None;
        }

        // Agent mentions are resolved on the inbound hot path. Serialize cache
        // misses and recheck after acquiring the lock so concurrent mentions do
        // not each establish their own realtime connection.
        let _resolution_guard = self.resolution_lock.lock().await;
        if let Some(cached) = self.cached(agent_id) {
            return cached;
        }

        let Ok(mut realtime) = connect_realtime(&self.realtime_url, &self.bot_token).await else {
            return None;
        };
        let agent = realtime
            .call(proto::GetBotAgentInput { agent_id })
            .await
            .ok()
            .and_then(|result| result.agent);
        self.store(agent_id, agent.clone());
        agent
    }

    pub(super) fn store_configuration_catalog(&self, catalog: AgentConfigurationCatalog) {
        *self
            .configuration_catalog
            .write()
            .expect("Agent configuration catalog poisoned") = Some(catalog);
    }

    pub(super) fn resolve_configuration(
        &self,
        context: &proto::AgentThreadContext,
    ) -> ResolvedAgentConfiguration {
        let Some(configuration) = context.configuration.as_ref() else {
            return ResolvedAgentConfiguration::default();
        };
        let catalog = self
            .configuration_catalog
            .read()
            .expect("Agent configuration catalog poisoned");
        let Some(catalog) = catalog.as_ref() else {
            return ResolvedAgentConfiguration {
                fallback: (configuration.model_id.is_some()
                    || configuration.reasoning_effort_id.is_some())
                .then_some(AgentConfigurationFallback::Catalog),
                ..ResolvedAgentConfiguration::default()
            };
        };
        let selected_model = configuration.model_id.as_deref().and_then(|model_id| {
            catalog
                .models
                .as_ref()
                .and_then(|models| models.options.iter().find(|model| model.id == model_id))
        });
        let model = match (&configuration.model_id, selected_model) {
            (Some(model), Some(_)) => Some(model.clone()),
            (Some(_), None) => {
                return ResolvedAgentConfiguration {
                    fallback: Some(AgentConfigurationFallback::Model),
                    ..ResolvedAgentConfiguration::default()
                };
            }
            (None, _) => None,
        };
        let reasoning = if let Some(reasoning_id) = configuration.reasoning_effort_id.as_deref() {
            let reasoning_available = catalog.reasoning.as_ref().is_some_and(|reasoning| {
                reasoning
                    .options
                    .iter()
                    .any(|option| option.id == reasoning_id)
            });
            let model_supports_reasoning = selected_model.is_none_or(|model| {
                model.reasoning_effort_ids.is_empty()
                    || model
                        .reasoning_effort_ids
                        .iter()
                        .any(|id| id == reasoning_id)
            });
            if configuration.model_id.is_none() || !reasoning_available || !model_supports_reasoning
            {
                return ResolvedAgentConfiguration {
                    model,
                    fallback: Some(AgentConfigurationFallback::Reasoning),
                    ..ResolvedAgentConfiguration::default()
                };
            }
            Some(reasoning_id.to_string())
        } else {
            None
        };
        ResolvedAgentConfiguration {
            model,
            reasoning,
            fallback: None,
        }
    }

    fn cached(&self, agent_id: i64) -> Option<Option<proto::BotAgent>> {
        let cache = self.cache.read().expect("bot Agent cache poisoned");
        let (loaded_at, agent) = cache.get(&agent_id)?;
        let ttl = if agent.is_some() {
            BOT_AGENT_CACHE_TTL
        } else {
            BOT_AGENT_NEGATIVE_CACHE_TTL
        };
        (loaded_at.elapsed() < ttl).then(|| agent.clone())
    }

    fn store(&self, agent_id: i64, agent: Option<proto::BotAgent>) {
        let mut cache = self.cache.write().expect("bot Agent cache poisoned");
        if !cache.contains_key(&agent_id)
            && cache.len() >= BOT_AGENT_CACHE_MAX_ENTRIES
            && let Some(oldest_id) = cache
                .iter()
                .min_by_key(|(_, (loaded_at, _))| *loaded_at)
                .map(|(cached_id, _)| *cached_id)
        {
            cache.remove(&oldest_id);
        }
        cache.insert(agent_id, (Instant::now(), agent));
    }
}

impl InboundRoute {
    pub(super) async fn chat_agent_context(
        &self,
        chat_id: i64,
    ) -> Result<Option<proto::AgentThreadContext>, String> {
        let dialog = self
            .bot_store
            .dialog(InlineId::new(chat_id))
            .await
            .map_err(|error| error.to_string())?;
        Ok(dialog
            .and_then(|dialog| dialog.agent_context)
            .map(agent_thread_context_to_proto))
    }

    pub fn policy_snapshot(&self) -> OperatorPolicy {
        self.policy
            .read()
            .expect("operator policy poisoned")
            .clone()
    }

    pub fn allows(&self, user_id: i64) -> bool {
        self.policy
            .read()
            .expect("operator policy poisoned")
            .allows(user_id)
    }

    pub fn replace_policy(&self, policy: OperatorPolicy) {
        *self.policy.write().expect("operator policy poisoned") = policy;
    }

    pub(in crate::bridge) fn register_pending_voice(
        &self,
        chat_id: i64,
        message_id: i64,
    ) -> PendingVoiceRegistration {
        let mut pending = self
            .pending_voice_messages
            .lock()
            .expect("pending voice registry poisoned");
        if pending.contains(&(chat_id, message_id)) {
            return PendingVoiceRegistration::Duplicate;
        }
        if pending.len() >= MAX_PENDING_VOICE_TRANSCRIPTS {
            return PendingVoiceRegistration::AtCapacity;
        }
        pending.insert((chat_id, message_id));
        PendingVoiceRegistration::Registered
    }

    pub(in crate::bridge) fn take_pending_voice(&self, chat_id: i64, message_id: i64) -> bool {
        self.pending_voice_messages
            .lock()
            .expect("pending voice registry poisoned")
            .remove(&(chat_id, message_id))
    }

    pub(in crate::bridge) fn cancel_pending_voices_in_chat(&self, chat_id: i64) -> usize {
        let mut pending = self
            .pending_voice_messages
            .lock()
            .expect("pending voice registry poisoned");
        let before = pending.len();
        pending.retain(|(pending_chat_id, _)| *pending_chat_id != chat_id);
        before.saturating_sub(pending.len())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::bridge) enum PendingVoiceRegistration {
    Registered,
    Duplicate,
    AtCapacity,
}

pub(super) fn actionable_event_chat_id(event: &ClientEvent) -> Option<i64> {
    match event {
        ClientEvent::MessageStored { message } => Some(message.chat_id.get()),
        ClientEvent::MessageActionInvoked { chat_id, .. } => Some(chat_id.get()),
        ClientEvent::BotInteraction(
            BotInteractionEvent::ChatSettingsRequested { chat_id, .. }
            | BotInteractionEvent::ChatSettingsItemInvoked { chat_id, .. },
        ) => Some(chat_id.get()),
        _ => None,
    }
}

/// Bot-authored sends and edits are observable on the same lossless stream as
/// user input. Never feed those progress projections back into the active-turn
/// control queue: a verbose burst can otherwise fill that queue while the turn
/// is publishing progress and falsely restart a healthy provider epoch.
pub(super) fn active_turn_event_chat_id(event: &ClientEvent, bot_user_id: i64) -> Option<i64> {
    if matches!(
        event,
        ClientEvent::MessageStored { message }
            if message.is_outgoing || message.sender_id.get() == bot_user_id
    ) {
        return None;
    }
    actionable_event_chat_id(event)
}

async fn event_chat_uses_agent_context_settings(
    event: &ClientEvent,
    route: &InboundRoute,
) -> Result<bool, String> {
    let chat_id = match event {
        ClientEvent::BotInteraction(
            BotInteractionEvent::ChatSettingsRequested { chat_id, .. }
            | BotInteractionEvent::ChatSettingsItemInvoked { chat_id, .. },
        )
        | ClientEvent::MessageActionInvoked { chat_id, .. } => chat_id.get(),
        _ => return Ok(false),
    };
    Ok(route.chat_agent_context(chat_id).await?.is_some())
}

async fn reject_agent_context_settings_command(
    bot: &InlineClient,
    record: &InboundRecord,
    route: &InboundRoute,
) -> Result<bool, Box<dyn std::error::Error>> {
    let Ok(Some(command)) = parse_command(&record.direction.text, &route.bot_username) else {
        return Ok(false);
    };
    if !matches!(
        command.name.as_str(),
        "model" | "reasoning" | "folder" | "projects"
    ) || (command.explicit_target && !command.targets_this_bot)
    {
        return Ok(false);
    }
    let context = route
        .chat_agent_context(record.delivery_chat_id)
        .await
        .map_err(io::Error::other)?;
    if context.is_none() {
        return Ok(false);
    }
    send_inbound_response(
        bot,
        route,
        record,
        record.binding.chat_id,
        "Use this thread's Agent controls for Project, Model, and Reasoning.",
        &format!("{}-agent-context-settings", record.event_id),
        BridgeNotificationClass::RoutineStatus,
    )
    .await?;
    Ok(true)
}

pub(super) async fn accept_idle_delivery<D: AgentDriver + SessionCatalogSource + 'static>(
    bot: &InlineClient,
    delivery: &LosslessEventDelivery,
    route: &InboundRoute,
    settings: &SettingsRuntime<'_, D>,
    deferred_by_capacity: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    if is_agent_session_projection_event(delivery.event()) {
        delivery.ack().await?;
        return Ok(());
    }
    if handle_session_browser_action(bot, delivery.event(), route, settings).await? {
        delivery.ack().await?;
        return Ok(());
    }
    if handle_claude_history_action(bot, delivery.event(), route).await? {
        delivery.ack().await?;
        return Ok(());
    }
    if handle_claude_history_import_thread_message(bot, delivery.event(), route).await? {
        delivery.ack().await?;
        return Ok(());
    }
    if handle_allowlist_action(bot, delivery.event(), route).await? {
        delivery.ack().await?;
        return Ok(());
    }
    let agent_context_owned = event_chat_uses_agent_context_settings(delivery.event(), route)
        .await
        .map_err(io::Error::other)?;
    match handle_settings_event(bot, delivery.event(), settings, agent_context_owned).await? {
        SettingsEventOutcome::NotHandled => {}
        SettingsEventOutcome::Handled {
            provider_epoch_ended,
        } => {
            delivery.ack().await?;
            if provider_epoch_ended {
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionAborted,
                    "local agent connection epoch ended during settings handling",
                )
                .into());
            }
            return Ok(());
        }
    }
    let operator_policy = route.policy_snapshot();
    match handle_settings_command_action(
        bot,
        delivery.event(),
        settings,
        &operator_policy,
        agent_context_owned,
    )
    .await?
    {
        SettingsCommandActionOutcome::NotHandled => {}
        SettingsCommandActionOutcome::Handled {
            provider_epoch_ended,
        } => {
            delivery.ack().await?;
            if provider_epoch_ended {
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionAborted,
                    "local agent connection epoch ended during settings handling",
                )
                .into());
            }
            return Ok(());
        }
    }
    if handle_queue_undo_action(bot, delivery.event(), route).await? {
        delivery.ack().await?;
        return Ok(());
    }
    if let ClientEvent::MessageActionInvoked {
        interaction_id,
        actor_user_id,
        ..
    } = delivery.event()
    {
        let toast = if actor_user_id.get() == route.owner_user_id {
            "This request is no longer active."
        } else {
            "Only the bot owner can approve this."
        };
        bot.answer_message_action(inline_client::AnswerMessageActionRequest {
            interaction_id: *interaction_id,
            toast: Some(toast.to_string()),
        })
        .await?;
        delivery.ack().await?;
        return Ok(());
    }
    if let Some(record) = inbound_from_delivery(bot, delivery, route).await? {
        if handle_terminal_question_reply(bot, delivery.event(), &record, route).await? {
            delivery.ack().await?;
            return Ok(());
        }
        if handle_session_browser_command(bot, &record, route, settings).await? {
            delivery.ack().await?;
            return Ok(());
        }
        if handle_claude_history_command(bot, &record, route).await? {
            delivery.ack().await?;
            return Ok(());
        }
        if handle_allowlist_command(bot, &record, route).await? {
            delivery.ack().await?;
            return Ok(());
        }
        if !handle_follow_command(bot, &record, route).await?
            && accept_inbound_or_session_handoff(route, &record)?
            && deferred_by_capacity
        {
            send_text_reply(
                bot,
                record.binding.chat_id,
                record.message_id,
                "Queued — four agent runs are active.",
                &format!("{}-capacity-queued", record.event_id),
                BridgeNotificationClass::RoutineStatus,
            )
            .await?;
        }
    }
    delivery.ack().await?;
    Ok(())
}

pub(super) async fn inbound_from_delivery(
    bot: &InlineClient,
    delivery: &LosslessEventDelivery,
    route: &InboundRoute,
) -> Result<Option<InboundRecord>, Box<dyn std::error::Error>> {
    let ClientEvent::MessageStored { message } = delivery.event() else {
        return Ok(None);
    };
    if is_agent_session_projection(message) {
        return Ok(None);
    }
    let response_not_before = tokio::time::Instant::now() + INITIAL_RESPONSE_DELAY;
    if message.timestamp < route.accept_messages_after {
        return Ok(None);
    }
    // Human access is provider-wide and owner-controlled. Bot deliveries have
    // already passed the server's exact structured-mention gate, so admitting
    // them here preserves the universal bot-to-bot mention-only rule without
    // forcing bots into the human operator allowlist.
    let sender_is_bot = message.is_outgoing
        || message.sender_id.get() == route.bot_user_id
        || message_sender_is_bot(&route.bot_store, message).await?;
    if !sender_is_bot && !route.allows(message.sender_id.get()) {
        return Ok(None);
    }
    tokio::time::sleep_until(response_not_before).await;
    let event_id = format!("inline-message-{}-{}", message.chat_id, message.message_id);
    match route.store.session_picker_thread_gate(
        &route.installation_id,
        message.chat_id.get(),
        now_seconds(),
    )? {
        SessionPickerThreadGate::Ready => {}
        SessionPickerThreadGate::Opening => {
            send_text_reply(
                bot,
                message.chat_id.get(),
                message.message_id.get(),
                "This Codex session is still importing and opening. Return to the bot’s private DM, finish Open, then resend this message.",
                &format!("{event_id}-session-picker-opening"),
                BridgeNotificationClass::ImportantFailure,
            )
            .await?;
            return Ok(None);
        }
        SessionPickerThreadGate::Failed => {
            send_text_reply(
                bot,
                message.chat_id.get(),
                message.message_id.get(),
                "This Codex session did not finish opening. Return to the bot’s private DM, open it again from /sessions, then resend this message.",
                &format!("{event_id}-session-picker-failed"),
                BridgeNotificationClass::ImportantFailure,
            )
            .await?;
            return Ok(None);
        }
    }
    if let Some(anchor_message_id) = unresolved_session_thread_anchor(route, message).await? {
        send_text_reply(
            bot,
            message.chat_id.get(),
            message.message_id.get(),
            "This Codex session has not finished opening. Return to the bot’s private DM, open it again from /sessions, then resend this message.",
            &format!("{event_id}-session-opening-{anchor_message_id}"),
            BridgeNotificationClass::ImportantFailure,
        )
        .await?;
        return Ok(None);
    }
    let Some(content) = normalize_inbound_content(&message.content) else {
        return Ok(None);
    };
    let text = content.text;
    let attachments = content.attachments;
    let mut message_route = resolve_message_route(
        message,
        route.owner_dm_chat_id,
        route.bot_user_id,
        &route.bot_store,
        route.owner_control.as_deref(),
    )
    .await?;
    let chat_agent_context = route
        .chat_agent_context(message.chat_id.get())
        .await
        .map_err(io::Error::other)?;
    if message_route.addressing == Addressing::None
        && !starts_with_other_user_mention(message, route.bot_user_id)
    {
        message_route = with_agent_session_thread_addressing(
            message_route,
            chat_agent_context
                .as_ref()
                .is_some_and(|context| context.bot_user_id == route.bot_user_id)
                || route
                    .store
                    .session_thread_binding_for_chat(&route.installation_id, message.chat_id.get())?
                    .is_some(),
        );
    }
    let event_id = format!("inline-message-{}-{}", message.chat_id, message.message_id);
    let command = match parse_command(&text, &route.bot_username) {
        Ok(command) => command,
        Err(_) => Some(CommandInvocation {
            name: String::new(),
            arguments: String::new(),
            explicit_target: false,
            targets_this_bot: false,
        }),
    };
    let command = command.map(|mut command| {
        if let Some(target_bot_user_id) = message_route.command_target_bot_user_id {
            command.explicit_target = true;
            command.targets_this_bot = target_bot_user_id == route.bot_user_id;
        }
        command
    });
    if matches!(
        &command,
        Some(CommandInvocation {
            name,
            arguments,
            targets_this_bot: true,
            ..
        }) if name == "stop" && arguments.is_empty()
    ) {
        let cancelled = route.cancel_pending_voices_in_chat(message.chat_id.get());
        if cancelled > 0 {
            log::trace!(
                target: "inline::bridge::media",
                "phase=voice_wait_cancelled chat_id={} pending_count={} reason=stop",
                message.chat_id.get(),
                cancelled
            );
        }
    }
    let policy = route.policy_snapshot();
    let decision = TriggerResolver.resolve(
        &policy,
        InboundEnvelope {
            event_id: event_id.clone(),
            chat_id: message.chat_id.get(),
            message_id: message.message_id.get(),
            sender_user_id: message.sender_id.get(),
            text: text.clone(),
            duplicate: false,
            bot_authored: message_route.bot_authored,
            addressing: message_route.addressing,
            command,
            action: None,
        },
    );
    let (mut direction, is_command) = match decision {
        TriggerDecision::Direction { direction, .. } => {
            (direction.with_attachments(attachments), false)
        }
        TriggerDecision::Command { .. } => (
            Direction::new(
                DirectionId::new(event_id.clone()).expect("non-empty message event id"),
                text,
            )
            .with_attachments(attachments),
            true,
        ),
        _ => return Ok(None),
    };
    if !is_command
        && let Some(agent_id) = chat_agent_context
            .as_ref()
            .and_then(|context| context.agent_id)
            .or_else(|| mentioned_agent_id(message, route.bot_user_id))
    {
        match route.bot_agent_resolver.resolve(agent_id).await {
            Some(agent) if agent.bot_user_id == route.bot_user_id => {
                let original = direction.text.clone();
                replace_direction_text(
                    &mut direction,
                    agent_specialization_instruction(&agent, &original),
                );
            }
            Some(_) => {
                send_text_reply(
                    bot,
                    message.chat_id.get(),
                    message.message_id.get(),
                    "The selected Skilled Agent does not belong to this provider.",
                    &format!("{event_id}-agent-provider-mismatch"),
                    BridgeNotificationClass::ImportantFailure,
                )
                .await?;
                return Ok(None);
            }
            None => {
                crate::telemetry::report_bridge_configuration_fallback(
                    route.provider_id.as_str(),
                    "agent_specialization_defaulted",
                );
                if let Err(error) = send_text_reply(
                    bot,
                    message.chat_id.get(),
                    message.message_id.get(),
                    "The selected Skilled Agent is unavailable, so I’m continuing with this bot’s default behavior.",
                    &format!("{event_id}-agent-defaulted"),
                    BridgeNotificationClass::RoutineStatus,
                )
                .await
                {
                    eprintln!(
                        "Agent fallback notice failed; continuing the request: {}",
                        safe_diagnostic(&error.to_string())
                    );
                }
            }
        }
    }
    if let Some(notice) = content.unsupported_notice
        && !is_command
    {
        send_text_reply(
            bot,
            message.chat_id.get(),
            message.message_id.get(),
            &notice,
            &format!("{event_id}-unsupported-content"),
            BridgeNotificationClass::RoutineStatus,
        )
        .await?;
        return Ok(None);
    }
    let resolved = if is_command
        && message.sender_id.get() == route.owner_user_id
        && (is_workspace_recovery_command(&direction.text, &route.bot_username)
            || is_provider_epoch_release_command(&direction.text, &route.bot_username))
    {
        conversation_for_workspace_selection_inheriting_parent(route, message.chat_id.get())
            .await
            .map(|conversation| (conversation, None))
    } else {
        conversation_for_chat_with_agent_context(
            route,
            message.chat_id.get(),
            chat_agent_context.as_ref(),
            !is_command,
        )
    };
    let conversation = match resolved {
        Ok((conversation, fallback)) => {
            if let Some(fallback) = fallback {
                crate::telemetry::report_bridge_configuration_fallback(
                    route.provider_id.as_str(),
                    fallback.code(),
                );
                if let Err(error) = send_text_reply(
                    bot,
                    message.chat_id.get(),
                    message.message_id.get(),
                    fallback.message(),
                    &format!("{event_id}-agent-configuration-defaulted"),
                    BridgeNotificationClass::RoutineStatus,
                )
                .await
                {
                    eprintln!(
                        "Agent configuration fallback notice failed; continuing the request: {}",
                        safe_diagnostic(&error.to_string())
                    );
                }
            }
            conversation.snapshot()
        }
        Err(ConversationResolutionError::MissingWorkspace) => {
            let notice = BridgeNotice::MissingWorkspace.message().to_string();
            send_text_reply(
                bot,
                message.chat_id.get(),
                message.message_id.get(),
                &notice,
                &format!("{event_id}-missing-workspace"),
                BridgeNotificationClass::ImportantFailure,
            )
            .await?;
            return Ok(None);
        }
        Err(ConversationResolutionError::InvalidAgentContext(notice)) => {
            send_text_reply(
                bot,
                message.chat_id.get(),
                message.message_id.get(),
                &notice,
                &format!("{event_id}-invalid-agent-context"),
                BridgeNotificationClass::ImportantFailure,
            )
            .await?;
            return Ok(None);
        }
        Err(error) => return Err(error.into()),
    };
    Ok(Some(InboundRecord {
        event_id,
        binding: conversation.binding,
        message_id: message.message_id.get(),
        delivery_chat_id: message.chat_id.get(),
        sender_user_id: message.sender_id.get(),
        direction,
        state: InboundState::Accepted,
        accepted_at: now_seconds(),
        started_at: None,
        lease_expires_at: None,
        attempt_count: 0,
        provider_turn_id: None,
        stream_message_id: None,
        failure: None,
    })
    .and_then(|record| {
        if should_wait_for_voice_transcript(message) {
            let chat_id = message.chat_id.get();
            let message_id = message.message_id.get();
            match route.register_pending_voice(chat_id, message_id) {
                PendingVoiceRegistration::Registered => {}
                PendingVoiceRegistration::Duplicate => {
                    log::trace!(
                        target: "inline::bridge::media",
                        "phase=voice_wait_duplicate event_id={:?}",
                        record.event_id
                    );
                    return None;
                }
                PendingVoiceRegistration::AtCapacity => {
                    log::warn!(
                        target: "inline::bridge::media",
                        "phase=voice_wait_skipped event_id={:?} reason=capacity",
                        record.event_id
                    );
                    return Some(record);
                }
            }
            let sender = route.deferred_inbound_tx.clone();
            let pending_voice_messages = route.pending_voice_messages.clone();
            let event_id = record.event_id.clone();
            let deferred_event_id = event_id.clone();
            tokio::spawn(async move {
                tokio::time::sleep(VOICE_TRANSCRIPT_WAIT).await;
                if !pending_voice_messages
                    .lock()
                    .expect("pending voice registry poisoned")
                    .remove(&(chat_id, message_id))
                {
                    log::trace!(
                        target: "inline::bridge::media",
                        "phase=voice_wait_abandoned event_id={deferred_event_id:?} reason=replaced_or_stopped"
                    );
                    return;
                }
                if sender.send(record).await.is_err() {
                    log::trace!(
                        target: "inline::bridge::media",
                        "phase=voice_wait_abandoned event_id={deferred_event_id:?} reason=runtime_closed"
                    );
                }
            });
            log::trace!(
                target: "inline::bridge::media",
                "phase=voice_wait_started event_id={event_id:?} deadline_ms={}",
                VOICE_TRANSCRIPT_WAIT.as_millis()
            );
            None
        } else {
            if is_voice_message(message)
                && route.take_pending_voice(message.chat_id.get(), message.message_id.get())
            {
                log::trace!(
                    target: "inline::bridge::media",
                    "phase=voice_wait_replaced event_id={:?} reason=message_update",
                    record.event_id
                );
            }
            Some(record)
        }
    }))
}

async fn unresolved_session_thread_anchor(
    route: &InboundRoute,
    message: &MessageRecord,
) -> Result<Option<i64>, Box<dyn std::error::Error>> {
    if route
        .store
        .session_thread_binding_for_chat(&route.installation_id, message.chat_id.get())?
        .is_some()
    {
        return Ok(None);
    }
    let Some(dialog) = route.bot_store.dialog(message.chat_id).await? else {
        return Ok(None);
    };
    let (Some(parent_chat_id), Some(anchor_message_id)) =
        (dialog.parent_chat_id, dialog.parent_message_id)
    else {
        return Ok(None);
    };
    route
        .store
        .session_thread_opening_matches_anchor(
            &route.installation_id,
            parent_chat_id.get(),
            anchor_message_id.get(),
        )
        .map(|matches| matches.then_some(anchor_message_id.get()))
        .map_err(Into::into)
}

pub(super) fn mentioned_agent_id(
    message: &inline_client::MessageRecord,
    bot_user_id: i64,
) -> Option<i64> {
    message.metadata.entities.iter().find_map(|entity| {
        (entity.kind == "TYPE_MENTION" && entity.user_id.is_some_and(|id| id.get() == bot_user_id))
            .then_some(entity.agent_id)
            .flatten()
            .map(InlineId::get)
    })
}

pub(super) fn agent_specialization_instruction(agent: &proto::BotAgent, task: &str) -> String {
    let skill_key = agent
        .skill_key
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let instructions = agent
        .instructions
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .or_else(|| {
            skill_key.is_none().then(|| {
                format!(
                    "You are a specialized agent named {:?}. Proceed with the user's request.",
                    agent.name
                )
            })
        })
        .unwrap_or_default();
    let skill_hint = skill_key
        .map(|value| {
            format!("\nConfigured skill key: {value}. Use it when this harness provides it.")
        })
        .unwrap_or_default();
    format!(
        "Inline Agent specialization (trusted bot configuration):\n{instructions}{skill_hint}\n\nCurrent task:\n{task}"
    )
}

pub(super) fn is_agent_session_projection(message: &inline_client::MessageRecord) -> bool {
    message.metadata.agent_session.is_some()
}

pub(super) fn is_agent_session_projection_event(event: &ClientEvent) -> bool {
    matches!(
        event,
        ClientEvent::MessageStored { message } if is_agent_session_projection(message)
    )
}

fn is_voice_message(message: &inline_client::MessageRecord) -> bool {
    matches!(
        &message.content,
        MessageContent::Media {
            kind: inline_client::MediaKind::Voice,
            ..
        }
    )
}

pub(super) fn should_wait_for_voice_transcript(message: &inline_client::MessageRecord) -> bool {
    matches!(
        &message.content,
        MessageContent::Media {
            kind: inline_client::MediaKind::Voice,
            caption,
            ..
        } if caption.as_deref().is_none_or(|caption| caption.trim().is_empty())
    ) && message.metadata.edit_timestamp.is_none()
}

async fn steer_active_source_edit<D: AgentDriver + 'static>(
    message: &inline_client::MessageRecord,
    sessions: &ProviderSessionManager<D>,
    session_id: &inline_agent_bridge::ProviderSessionId,
    turn_id: &inline_agent_bridge::TurnId,
    store: &BridgeStore,
    route: &InboundRoute,
) -> Result<bool, Box<dyn std::error::Error>> {
    let Some(edit_version) = message
        .metadata
        .revision
        .or(message.metadata.edit_timestamp)
        .filter(|version| *version > 0)
    else {
        return Ok(false);
    };
    if !matches!(
        sessions.driver().capabilities().steering,
        SteeringSupport::Native | SteeringSupport::Extension
    ) || !route.allows(message.sender_id.get())
    {
        return Ok(false);
    }
    let Some(source) = store.inbound_for_provider_turn(turn_id)? else {
        return Ok(false);
    };
    if source.binding.chat_id != message.chat_id.get()
        || source.message_id != message.message_id.get()
        || source.sender_user_id != message.sender_id.get()
    {
        return Ok(false);
    }
    let Some(content) = normalize_inbound_content(&message.content) else {
        return Ok(false);
    };
    if content.text == source.direction.text && content.attachments == source.direction.attachments
    {
        return Ok(false);
    }
    let event_id = format!(
        "inline-message-{}-{}-edit-{edit_version}",
        message.chat_id, message.message_id
    );
    if store.event_processed(&event_id)? {
        return Ok(true);
    }
    sessions
        .driver()
        .steer_turn(
            session_id,
            turn_id,
            TurnInput {
                text: content.text,
                attachments: content.attachments,
                client_message_id: Some(event_id.clone()),
            },
        )
        .await?;
    store.claim_event(&event_id, now_seconds())?;
    log::trace!(
        target: "inline::bridge::media",
        "phase=source_edit_steered event_id={event_id:?} source_event_id={:?} revision={} attachment_count={}",
        source.event_id,
        edit_version,
        source.direction.attachments.len()
    );
    Ok(true)
}

async fn handle_terminal_question_reply(
    bot: &InlineClient,
    event: &ClientEvent,
    record: &InboundRecord,
    route: &InboundRoute,
) -> Result<bool, Box<dyn std::error::Error>> {
    let ClientEvent::MessageStored { message } = event else {
        return Ok(false);
    };
    let reply_to = match message.reply_to_message_id {
        Some(message_id) => Some(message_id),
        None => route
            .bot_store
            .message(message.chat_id, message.message_id)
            .await?
            .and_then(|stored| stored.reply_to_message_id),
    };
    let Some(question_message_id) = reply_to.map(InlineId::get) else {
        return Ok(false);
    };
    let Some(question) = route
        .store
        .get_question_by_message(record.binding.chat_id, question_message_id)?
    else {
        return Ok(false);
    };
    if question.state == inline_agent_bridge::QuestionState::Pending {
        return Ok(false);
    }
    if route.store.claim_event(&record.event_id, now_seconds())? {
        send_text_reply(
            bot,
            record.binding.chat_id,
            record.message_id,
            "That question is no longer active. Send your request again if you still want me to continue.",
            &format!("{}-question-inactive", record.event_id),
            BridgeNotificationClass::RoutineStatus,
        )
        .await?;
    }
    Ok(true)
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn run_inbound_turn<D: AgentDriver + SessionCatalogSource + 'static>(
    bot: &InlineClient,
    inline_events: &mut tokio::sync::mpsc::Receiver<LosslessEventDelivery>,
    sessions: &ProviderSessionManager<D>,
    store: &BridgeStore,
    source_binding: &BindingKey,
    source_workspace: &Path,
    route: &InboundRoute,
    active: &ActiveConversation,
    settings_identity: &SettingsIdentity,
    mut record: InboundRecord,
    _provider_work_lease: Option<inline_agent_bridge::ProviderWorkLease>,
    lane_sender: tokio::sync::mpsc::Sender<LosslessEventDelivery>,
    lane_promotions: tokio::sync::mpsc::Sender<TurnLanePromotion>,
) -> Result<(), Box<dyn std::error::Error>> {
    log::trace!(
        target: "inline::bridge::turn",
        "phase=inbound_started event_id={:?} provider_id={:?} chat_id={} message_id={} sender_user_id={}",
        record.event_id,
        sessions.provider_id().as_str(),
        source_binding.chat_id,
        record.message_id,
        record.sender_user_id
    );
    if handle_session_browser_command(
        bot,
        &record,
        route,
        &SettingsRuntime {
            sessions,
            store,
            active,
            identity: settings_identity,
            turn_active: false,
        },
    )
    .await?
        || handle_claude_history_command(bot, &record, route).await?
        || handle_allowlist_command(bot, &record, route).await?
    {
        return Ok(());
    }
    if reject_agent_context_settings_command(bot, &record, route).await? {
        return Ok(());
    }
    let (instruction, command_acknowledgement) = match resolve_idle_command(
        sessions,
        store,
        source_binding,
        source_workspace,
        &SettingsRuntime {
            sessions,
            store,
            active,
            identity: settings_identity,
            turn_active: false,
        },
        record.sender_user_id,
        &route.bot_username,
        &record.direction.text,
    )
    .await
    {
        IdleCommandResolution::NotCommand => (record.direction.text.clone(), None),
        IdleCommandResolution::StartDirection {
            instruction,
            acknowledgement,
        } => (instruction, Some(acknowledgement)),
        IdleCommandResolution::Handled {
            message,
            failure,
            provider_epoch_ended,
            choices,
        } => {
            if let Some(choices) = choices.as_ref() {
                send_settings_command_choices(bot, store, &record, &message, choices).await?;
            } else {
                send_inbound_response(
                    bot,
                    route,
                    &record,
                    source_binding.chat_id,
                    &message,
                    &format!("{}-command-result", record.event_id),
                    if failure.is_some() {
                        BridgeNotificationClass::ImportantFailure
                    } else {
                        BridgeNotificationClass::RoutineStatus
                    },
                )
                .await?;
            }
            match failure {
                Some(failure) => {
                    eprintln!("Bridge command failed: {failure}");
                    store.fail_inbound(&record.event_id, &failure)?;
                }
                None => {
                    store.complete_inbound(&record.event_id)?;
                }
            }
            if provider_epoch_ended {
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionAborted,
                    "local agent connection epoch ended during command handling",
                )
                .into());
            }
            return Ok(());
        }
    };
    let binding = match prepare_turn_delivery(
        bot,
        store,
        settings_identity,
        source_binding,
        &record,
        &instruction,
    )
    .await
    {
        Ok(binding) => binding,
        Err(error) => {
            let diagnostic = safe_diagnostic(&error.to_string());
            publish_inbound_final_send(
                bot,
                store,
                &record.event_id,
                source_binding.chat_id,
                None,
                "Failed.",
                "I couldn’t prepare the Inline reply thread for this turn. Please try again.",
                InboundState::Failed,
                Some(&diagnostic),
            )
            .await?;
            return Ok(());
        }
    };
    record.delivery_chat_id = binding.chat_id;
    if binding.chat_id != source_binding.chat_id {
        let (acknowledged, receiver) = tokio::sync::oneshot::channel();
        lane_promotions
            .send(TurnLanePromotion {
                source_chat_id: source_binding.chat_id,
                delivery_chat_id: binding.chat_id,
                sender: lane_sender,
                acknowledged,
            })
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "turn supervisor stopped"))?;
        if !receiver.await.unwrap_or(false) {
            publish_inbound_final_send(
                bot,
                store,
                &record.event_id,
                binding.chat_id,
                None,
                "Failed.",
                "Another agent turn is already active in this reply thread. Please try again when it finishes.",
                InboundState::Failed,
                Some("reply-thread delivery lane is already active"),
            )
            .await?;
            return Ok(());
        }
        active.replace(binding.clone(), source_workspace.to_path_buf());
    }
    let workspace = source_workspace;
    let binding = &binding;
    let prepared_agent_input = match prepare_agent_session_input(
        sessions, store, route, binding, &record,
    )
    .await
    {
        Ok(prepared) => prepared,
        Err(error) => {
            let diagnostic = safe_diagnostic(&error.to_string());
            publish_inbound_final_send(
                bot,
                store,
                &record.event_id,
                binding.chat_id,
                None,
                "Failed.",
                "I couldn’t connect this message to the selected agent session. Nothing was sent to the provider; try again.",
                InboundState::Failed,
                Some(&diagnostic),
            )
            .await?;
            return Ok(());
        }
    };
    let agent_session_id = prepared_agent_input
        .as_ref()
        .map(|input| input.agent_session_id);
    if sessions.provider_id().as_str() == "codex"
        && agent_session_id.is_some()
        && !sessions.session_history_is_ready(binding).await
    {
        publish_inbound_final_send(
            bot,
            store,
            &record.event_id,
            binding.chat_id,
            None,
            "",
            if record.sender_user_id == route.owner_user_id {
                "This session needs /resume before you can send prompts. Use /resume to reconnect and sync recent history, then send your prompt again. This message was not sent to Codex."
            } else {
                "This session needs /resume before you can send prompts. Ask the bot owner to use /resume to sync recent history, then send your prompt again. This message was not sent to Codex."
            },
            InboundState::Completed,
            None,
        )
        .await?;
        return Ok(());
    }
    let mut initial_progress = ActivityTracker::default();
    initial_progress.set_workspace(workspace);
    if let Some(ref acknowledgement) = command_acknowledgement {
        initial_progress.apply_legacy(acknowledgement, VisibilityMode::Normal, workspace);
    }
    let acknowledgement_text = initial_progress
        .render_chunks(VisibilityMode::Normal, WORKING_STATUS, None)
        .remove(0);
    let acknowledgement = send_silent_text(
        bot,
        binding.chat_id,
        &acknowledgement_text,
        &format!("{}-working", record.event_id),
    )
    .await?;
    let stream_message_id = acknowledgement.message_id;
    if let Some(message_id) = stream_message_id
        && !store.attach_inbound_stream_message(&record.event_id, message_id.get())?
    {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "started turn disappeared while attaching its acknowledgement message",
        )
        .into());
    }
    let mut typing = TypingIndicator::start(bot, binding.chat_id).await;
    let instruction = match build_turn_instruction(route, &record, &instruction).await {
        Ok(instruction) => instruction,
        Err(error) => {
            eprintln!(
                "Inline context resolution failed: {}",
                safe_diagnostic(&error.to_string())
            );
            instruction
        }
    };
    let settings = match store.chat_settings(binding, now_seconds()) {
        Ok(settings) => settings,
        Err(error) => {
            typing.stop().await;
            let diagnostic = safe_diagnostic(&error.to_string());
            let _ = publish_inbound_final_send(
                bot,
                store,
                &record.event_id,
                binding.chat_id,
                stream_message_id,
                "Failed.",
                BridgeNotice::SettingsUnavailable.message(),
                InboundState::Failed,
                Some(&diagnostic),
            )
            .await;
            return Err(error.into());
        }
    };
    let mut visibility_mode = if settings.verbose {
        VisibilityMode::Verbose
    } else {
        VisibilityMode::Normal
    };
    let turn_started_at = Instant::now();
    let provider_attachments =
        materialize_inbound_attachments(&record.direction.attachments, &route.attachment_cache_dir)
            .await;
    let started = sessions
        .start_turn(
            binding,
            now_seconds(),
            TurnInput {
                text: instruction,
                attachments: provider_attachments,
                client_message_id: Some(record.direction.id.to_string()),
            },
            TurnOptions {
                cwd: None,
                model: settings.model,
                reasoning: settings.reasoning,
                permissions: settings.permissions,
            },
        )
        .await;
    let (session_open, mut turn, _provider_turn_lease) = match started {
        Ok(started) => started,
        Err(error) => {
            crate::telemetry::report_bridge_runtime_error(
                sessions.provider_id().as_str(),
                "turn_start",
                &error,
                None,
            );
            let connection_epoch_ended =
                matches!(&error, SessionManagerError::Driver(error) if error.ends_epoch());
            let diagnostic = safe_diagnostic(&error.to_string());
            eprintln!("Agent turn start failed: {}", diagnostic);
            typing.stop().await;
            let message = match &error {
                SessionManagerError::Driver(DriverError::AuthenticationRequired(required)) => {
                    required.message.as_str()
                }
                SessionManagerError::Driver(DriverError::SessionBusy(_)) => {
                    BridgeNotice::SessionActiveElsewhere.message()
                }
                _ => BridgeNotice::AgentStartFailed.message(),
            };
            publish_inbound_final_send(
                bot,
                store,
                &record.event_id,
                binding.chat_id,
                stream_message_id,
                "Failed.",
                message,
                InboundState::Failed,
                Some(&diagnostic),
            )
            .await?;
            if connection_epoch_ended {
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionAborted,
                    "local agent connection epoch ended during turn start",
                )
                .into());
            }
            return Ok(());
        }
    };
    let session_id = session_open.session_id().clone();
    log::trace!(
        target: "inline::bridge::turn",
        "phase=provider_turn_started event_id={:?} provider_id={:?} session_id={:?} turn_id={:?} session_open={:?} elapsed_ms={}",
        record.event_id,
        sessions.provider_id().as_str(),
        session_id.as_str(),
        turn.turn_id.as_str(),
        session_open,
        turn_started_at.elapsed().as_millis()
    );
    let tracked = store.attach_inbound_turn(
        &record.event_id,
        &turn.turn_id,
        stream_message_id.map(InlineId::get),
    );
    if !matches!(tracked, Ok(true)) {
        typing.stop().await;
        if let Err(cancel_error) = sessions
            .driver()
            .cancel_turn(&session_id, &turn.turn_id)
            .await
        {
            eprintln!(
                "Could not cancel an untracked provider turn: {}",
                safe_diagnostic(&cancel_error.to_string())
            );
        }
        let error: Box<dyn std::error::Error> = match tracked {
            Err(error) => error.into(),
            _ => {
                io::Error::other("started turn disappeared before provider acceptance was recorded")
                    .into()
            }
        };
        let diagnostic = safe_diagnostic(&error.to_string());
        let _ = publish_inbound_final_send(
            bot,
            store,
            &record.event_id,
            binding.chat_id,
            stream_message_id,
            "Failed.",
            BridgeNotice::TurnTrackingFailed.message(),
            InboundState::Failed,
            Some(&diagnostic),
        )
        .await;
        return Err(error);
    }
    let mut input_link_needs_repair = false;
    if let Some(prepared) = prepared_agent_input.as_ref()
        && let Err(error) =
            link_accepted_agent_session_input(bot, prepared, record.message_id).await
    {
        input_link_needs_repair = true;
        eprintln!(
            "Accepted agent input linkage needs resync: {}",
            safe_diagnostic(&error.to_string())
        );
    }
    let mut presenter = StreamingPresenter::new(now_millis(), 750);
    let mut coordinator = TurnCoordinator::running(turn.turn_id.clone());
    let mut files = Vec::new();
    let mut seen_files = HashSet::new();
    let mut output_attachments = Vec::new();
    let mut seen_output_attachments = HashSet::new();
    let mut validation = None;
    let durable_progress = store.inbound_progress(&record.event_id)?;
    let mut progress_message_ids = durable_progress
        .message_ids
        .into_iter()
        .map(InlineId::new)
        .collect::<Vec<_>>();
    let mut activities = durable_progress
        .ledger_json
        .as_deref()
        .and_then(|ledger| ActivityTracker::from_durable_json(ledger).ok())
        .unwrap_or_default();
    activities.set_visibility(visibility_mode);
    activities.set_workspace(workspace);
    persist_progress_ledger(store, &record.event_id, &activities)?;
    let mut pending_approvals = HashSet::<String>::new();
    let mut pending_questions = HashMap::<i64, PendingQuestionUi>::new();
    let mut turn_question_tokens = HashSet::<String>::new();
    let mut heartbeat = tokio::time::interval(TYPING_HEARTBEAT_INTERVAL);
    heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut last_lease_renewal = now_seconds();
    let mut turn_timing = TurnTiming::default();
    let terminal_result: Result<_, Box<dyn std::error::Error>> = async {
        if let Some(notice) = session_open_notice(&session_open) {
            send_text_reply(
                bot,
                binding.chat_id,
                record.message_id,
                notice.message(),
                &format!("{}-session-notice", record.event_id),
                BridgeNotificationClass::ImportantNotice,
            )
            .await?;
        }
        Ok(loop {
            tokio::select! {
            event = turn.events.next() => {
                if let Some(Ok(event)) = event.as_ref() {
                    log::trace!(
                        target: "inline::bridge::turn",
                        "phase=provider_event event_id={:?} turn_id={:?} event_kind={}",
                        record.event_id,
                        turn.turn_id.as_str(),
                        runtime_agent_event_kind(event)
                    );
                }
                match event {
                    Some(Ok(AgentEvent::AgentMessage { item_id, phase, update, .. })) => {
                        activities.apply_message(&item_id, phase, update);
                        if !presenter.ordinary_update_ready(now_millis()) {
                            continue;
                        }
                        let status = activities
                            .render(visibility_mode, WORKING_STATUS, workspace)
                            .unwrap_or_default();
                        if presenter.show_transient(
                            now_millis(), status, UpdatePriority::Ordinary,
                        ).is_some() {
                            persist_progress_ledger(store, &record.event_id, &activities)?;
                            let chunks = activities.render_chunks(visibility_mode, WORKING_STATUS, None);
                            sync_turn_progress(
                                bot, store, &record.event_id, binding.chat_id, stream_message_id,
                                &mut progress_message_ids, &chunks, WORKING_CONTINUED_STATUS,
                            ).await?;
                        }
                    }
                    Some(Ok(AgentEvent::AgentTextDelta { text, .. })) => {
                        let _ = presenter.push_delta(now_millis(), &text);
                    }
                    Some(Ok(AgentEvent::AgentTextCompleted { text, .. })) => {
                        if !text.trim().is_empty() {
                            let _ = presenter.replace_snapshot(now_millis(), text);
                        }
                    }
                    Some(Ok(AgentEvent::FilesChanged { files: changed, .. })) => {
                        let progress_paths = changed
                            .iter()
                            .map(|file| file.path.clone())
                            .collect::<Vec<_>>();
                        for file in changed {
                            if seen_files.insert(file.path.clone()) {
                                files.push(file);
                            }
                        }
                        let status = activities.apply_files(
                            progress_paths,
                            visibility_mode,
                            workspace,
                        );
                        persist_progress_ledger(store, &record.event_id, &activities)?;
                        if let Some(status) = status
                            && presenter.show_transient(
                                now_millis(),
                                status,
                                UpdatePriority::Ordinary,
                            ).is_some()
                        {
                            let chunks = activities.render_chunks(
                                visibility_mode,
                                WORKING_STATUS,
                                Some(WORKING_CONTINUED_STATUS),
                            );
                            sync_turn_progress(
                                bot,
                                store,
                                &record.event_id,
                                binding.chat_id,
                                stream_message_id,
                                &mut progress_message_ids,
                                &chunks,
                                WORKING_CONTINUED_STATUS,
                            ).await?;
                        }
                    }
                    Some(Ok(AgentEvent::OutputAttachment { attachment, .. })) => {
                        if seen_output_attachments.insert(attachment.id.clone()) {
                            output_attachments.push(attachment);
                        }
                    }
                    Some(Ok(AgentEvent::ApprovalRequested(request))) => {
                        let token = approval_token(&request);
                        let created_at = now_seconds();
                        let pending = PendingApproval {
                            callback_token: token.clone(),
                            installation_id: binding.installation_id.clone(),
                            provider_id: sessions.provider_id().clone(),
                            provider_approval_id: request.approval_id.clone(),
                            turn_id: request.turn_id.clone(),
                            origin_chat_id: binding.chat_id,
                            action_chat_id: binding.chat_id,
                            message_id: None,
                            origin_status_message_id: None,
                            decisions: approval_decisions(&request),
                            created_at,
                            expires_at: created_at.saturating_add(APPROVAL_TTL_SECONDS),
                        };
                        if store.insert_approval(&pending)? {
                            pending_approvals.insert(token.clone());
                            let workspace_label = workspace
                                .file_name()
                                .and_then(|name| name.to_str())
                                .unwrap_or("the selected project");
                            let message_id = send_approval(
                                bot,
                                binding.chat_id,
                                &request,
                                provider_display_name(sessions.provider_id().as_str())
                                    .unwrap_or("Agent"),
                                &route.host_label,
                                workspace_label,
                            )
                            .await?;
                            store.attach_approval_message(&token, message_id.get())?;
                        }
                    }
                    Some(Ok(AgentEvent::ApprovalClosed { approval_id, .. })) => {
                        if let Some(approval) = store.close_provider_approval(
                            sessions.provider_id(),
                            &turn.turn_id,
                            &approval_id,
                            now_seconds(),
                        )? {
                            pending_approvals.remove(&approval.callback_token);
                            if let Some(message_id) = approval.message_id.map(InlineId::new) {
                                let _ = clear_approval(
                                    bot,
                                    approval.action_chat_id,
                                    message_id,
                                    "This approval request was withdrawn by the agent.",
                                )
                                .await;
                            }
                            let _ = clear_shared_approval_status(
                                bot,
                                &approval,
                                "Approval request withdrawn by the agent.",
                            )
                            .await;
                        }
                    }
                    Some(Ok(AgentEvent::QuestionRequested(mut request))) => {
                        if question_contains_secret(&request) {
                            sessions
                                .driver()
                                .resolve_question(
                                    &request.request_id,
                                    empty_question_answers(&request),
                                )
                                .await?;
                            send_text_reply(
                                bot,
                                binding.chat_id,
                                record.message_id,
                                "The agent requested secret input, so I declined it. Enter secrets only through the provider on the host computer.",
                                &format!("{}-secret-question-declined", record.event_id),
                                BridgeNotificationClass::ImportantFailure,
                            )
                            .await?;
                        } else {
                            let token = question_token(&request);
                            let created_at = now_seconds();
                            let maximum_expiry = created_at.saturating_add(QUESTION_TTL_SECONDS);
                            let requested_expiry = request.auto_resolution_ms.and_then(|milliseconds| {
                                i64::try_from(milliseconds.div_ceil(1_000))
                                    .ok()
                                    .and_then(|seconds| created_at.checked_add(seconds))
                            });
                            let expires_at = Some(
                                requested_expiry
                                    .unwrap_or(maximum_expiry)
                                    .max(created_at.saturating_add(1))
                                    .min(maximum_expiry),
                            );
                            request.auto_resolution_ms = expires_at.and_then(|expires_at| {
                                u64::try_from(expires_at.saturating_sub(created_at))
                                    .ok()
                                    .and_then(|seconds| seconds.checked_mul(1_000))
                            });
                            let pending = PendingQuestion {
                                callback_token: token.clone(),
                                installation_id: binding.installation_id.clone(),
                                provider_id: sessions.provider_id().clone(),
                                provider_question_id: request.request_id.clone(),
                                turn_id: request.turn_id.clone(),
                                chat_id: binding.chat_id,
                                message_id: None,
                                owner_user_id: route.owner_user_id,
                                created_at,
                                expires_at,
                            };
                            if !store.insert_question(&pending)? {
                                sessions
                                    .driver()
                                    .resolve_question(
                                        &request.request_id,
                                        empty_question_answers(&request),
                                    )
                                    .await?;
                                continue;
                            }
                            turn_question_tokens.insert(token.clone());
                            match send_question(
                                bot,
                                binding.chat_id,
                                record.message_id,
                                provider_display_name(sessions.provider_id().as_str())
                                    .unwrap_or("Agent"),
                                &request,
                            )
                            .await
                            {
                                Ok(Some(message_id)) => {
                                    store.attach_question_message(&token, message_id.get())?;
                                    pending_questions.insert(
                                        message_id.get(),
                                        PendingQuestionUi {
                                            request,
                                            message_id,
                                            token,
                                        },
                                    );
                                }
                                Ok(None) | Err(_) => return Err(io::Error::new(
                                    io::ErrorKind::ConnectionAborted,
                                    "agent question publication could not be confirmed",
                                ).into()),
                            }
                        }
                    }
                    Some(Ok(AgentEvent::TurnCompleted { outcome, error, timing, .. })) => {
                        turn_timing = timing;
                        break (outcome, error);
                    }
                    Some(Ok(AgentEvent::ActivityUpsert { activity, .. })) => {
                        let projection = activities.apply(activity, visibility_mode, workspace);
                        persist_progress_ledger(store, &record.event_id, &activities)?;
                        if let Some(update) = projection.validation {
                            validation = Some(update);
                        }
                        if let Some(status) = projection.status
                            && presenter.show_transient(
                                now_millis(),
                                status,
                                projection.priority,
                            ).is_some()
                        {
                            let chunks = activities.render_chunks(
                                visibility_mode,
                                WORKING_STATUS,
                                Some(WORKING_CONTINUED_STATUS),
                            );
                            sync_turn_progress(
                                bot,
                                store,
                                &record.event_id,
                                binding.chat_id,
                                stream_message_id,
                                &mut progress_message_ids,
                                &chunks,
                                WORKING_CONTINUED_STATUS,
                            ).await?;
                        }
                    }
                    Some(Ok(AgentEvent::ActivityTextDelta {
                        activity_id,
                        stream,
                        index,
                        delta,
                        ..
                    })) => {
                        activities.apply_activity_text_delta(&activity_id, stream, index, &delta);
                        let now = now_millis();
                        if presenter.ordinary_update_ready(now) {
                            persist_progress_ledger(store, &record.event_id, &activities)?;
                            let status = activities
                                .render(visibility_mode, WORKING_STATUS, workspace)
                                .unwrap_or_default();
                            if presenter
                                .show_transient(now, status, UpdatePriority::Ordinary)
                                .is_none()
                            {
                                continue;
                            }
                            let chunks = activities.render_chunks(
                                visibility_mode,
                                WORKING_STATUS,
                                Some(WORKING_CONTINUED_STATUS),
                            );
                            sync_turn_progress(
                                bot,
                                store,
                                &record.event_id,
                                binding.chat_id,
                                stream_message_id,
                                &mut progress_message_ids,
                                &chunks,
                                WORKING_CONTINUED_STATUS,
                            ).await?;
                        }
                    }
                    Some(Ok(AgentEvent::Activity { summary, .. })) => {
                        if let Some(update) = validation_summary_from_provider(&summary) {
                            validation = Some(update);
                        }
                        let status = activities.apply_legacy(
                            &summary,
                            visibility_mode,
                            workspace,
                        );
                        persist_progress_ledger(store, &record.event_id, &activities)?;
                        if let Some(status) = status
                            && presenter.show_transient(
                                now_millis(),
                                status,
                                UpdatePriority::Ordinary,
                            ).is_some()
                        {
                            let chunks = activities.render_chunks(
                                visibility_mode,
                                WORKING_STATUS,
                                Some(WORKING_CONTINUED_STATUS),
                            );
                            sync_turn_progress(
                                bot,
                                store,
                                &record.event_id,
                                binding.chat_id,
                                stream_message_id,
                                &mut progress_message_ids,
                                &chunks,
                                WORKING_CONTINUED_STATUS,
                            ).await?;
                        }
                    }
                    Some(Ok(AgentEvent::PlanUpdated { explanation, steps, .. })) => {
                        if let Some(explanation) = explanation {
                            activities.apply_legacy(&explanation, visibility_mode, workspace);
                        }
                        let status = activities.apply_plan(
                            steps,
                            visibility_mode,
                            workspace,
                        );
                        persist_progress_ledger(store, &record.event_id, &activities)?;
                        if let Some(status) = status
                            && presenter.show_transient(
                                now_millis(),
                                status,
                                UpdatePriority::Ordinary,
                            ).is_some()
                        {
                            let chunks = activities.render_chunks(
                                visibility_mode,
                                WORKING_STATUS,
                                Some(WORKING_CONTINUED_STATUS),
                            );
                            sync_turn_progress(
                                bot,
                                store,
                                &record.event_id,
                                binding.chat_id,
                                stream_message_id,
                                &mut progress_message_ids,
                                &chunks,
                                WORKING_CONTINUED_STATUS,
                            ).await?;
                        }
                    }
                    Some(Ok(AgentEvent::TurnStarted { .. })) => {}
                    Some(Err(error)) => {
                        let outcome = if error.ends_epoch() {
                            TurnOutcome::ConnectionLost
                        } else {
                            TurnOutcome::Failed
                        };
                        break (outcome, Some(error.to_string()));
                    }
                    None => break (
                        TurnOutcome::ConnectionLost,
                        Some("Agent event stream closed before completion".to_string()),
                    ),
                }
            }
            delivery = inline_events.recv() => {
                let Some(delivery) = delivery else {
                    break (
                        TurnOutcome::Interrupted,
                        Some("Bridge stopped while this turn was running".to_string()),
                    );
                };
                let mut stop_confirmed = false;
                handle_active_delivery(
                    bot,
                    delivery,
                    sessions,
                    &session_id,
                    &turn.turn_id,
                    store,
                    binding,
                    route,
                    active,
                    settings_identity,
                    &mut pending_approvals,
                    &mut pending_questions,
                    &mut coordinator,
                    &mut typing,
                    &mut stop_confirmed,
                ).await?;
                if stop_confirmed {
                    break (TurnOutcome::Interrupted, None);
                }
                let refreshed_mode = if store
                    .chat_settings(binding, now_seconds())?
                    .verbose
                {
                    VisibilityMode::Verbose
                } else {
                    VisibilityMode::Normal
                };
                if refreshed_mode != visibility_mode {
                    visibility_mode = refreshed_mode;
                    activities.set_visibility(visibility_mode);
                    persist_progress_ledger(store, &record.event_id, &activities)?;
                    let chunks = activities.render_chunks(
                        visibility_mode,
                        WORKING_STATUS,
                        Some(WORKING_CONTINUED_STATUS),
                    );
                    sync_turn_progress(
                        bot,
                        store,
                        &record.event_id,
                        binding.chat_id,
                        stream_message_id,
                        &mut progress_message_ids,
                        &chunks,
                        WORKING_CONTINUED_STATUS,
                    ).await?;
                }
            }
            _ = heartbeat.tick() => {
                // Flush the latest coalesced snapshot even if the provider goes quiet.
                let status = activities
                    .render(visibility_mode, WORKING_STATUS, workspace)
                    .unwrap_or_default();
                if presenter.show_transient(now_millis(), status, UpdatePriority::Ordinary).is_some() {
                    persist_progress_ledger(store, &record.event_id, &activities)?;
                    let chunks = activities.render_chunks(visibility_mode, WORKING_STATUS, None);
                    sync_turn_progress(
                        bot, store, &record.event_id, binding.chat_id, stream_message_id,
                        &mut progress_message_ids, &chunks, WORKING_CONTINUED_STATUS,
                    ).await?;
                }
                let now = now_seconds();
                if now.saturating_sub(last_lease_renewal) >= 60 {
                    let _ = store.renew_inbound_lease(&record.event_id, now)?;
                    last_lease_renewal = now;
                }
                expire_active_interactions(
                    bot,
                    sessions,
                    &session_id,
                    &turn.turn_id,
                    store,
                    &mut pending_approvals,
                    &mut pending_questions,
                    now,
                ).await?;
                typing.heartbeat().await;
            }
            }
        })
    }
    .await;

    let mut fatal_driver_error = None;
    let terminal = match terminal_result {
        Ok(terminal) => terminal,
        Err(error) => {
            eprintln!(
                "Agent turn handling failed: {}",
                safe_diagnostic(&error.to_string())
            );
            if error
                .downcast_ref::<io::Error>()
                .is_some_and(|error| error.kind() == io::ErrorKind::ConnectionAborted)
            {
                fatal_driver_error = Some("Agent connection epoch ended".to_string());
            }
            let cancellation = sessions
                .driver()
                .cancel_turn(&session_id, &turn.turn_id)
                .await;
            if let Err(cancel_error) = cancellation {
                eprintln!(
                    "Agent cleanup cancellation failed: {}",
                    safe_diagnostic(&cancel_error.to_string())
                );
                if let Err(shutdown_error) = sessions.driver().shutdown().await {
                    eprintln!(
                        "Agent cleanup shutdown failed: {}",
                        safe_diagnostic(&shutdown_error.to_string())
                    );
                }
                fatal_driver_error = Some(safe_diagnostic(&cancel_error.to_string()));
            } else if tokio::time::timeout(Duration::from_secs(10), async {
                while let Some(event) = turn.events.next().await {
                    match event {
                        Ok(AgentEvent::TurnCompleted { .. }) | Err(_) => break,
                        Ok(AgentEvent::ApprovalRequested(request)) => {
                            let decision = if request.options.contains(&ApprovalOption::CancelTurn)
                            {
                                Some(ApprovalDecision::CancelTurn)
                            } else if request.options.contains(&ApprovalOption::Reject) {
                                Some(ApprovalDecision::Reject)
                            } else {
                                None
                            };
                            if let Some(decision) = decision {
                                let _ = sessions
                                    .driver()
                                    .resolve_approval(&request.approval_id, decision)
                                    .await;
                            }
                        }
                        Ok(AgentEvent::QuestionRequested(request)) => {
                            let _ = sessions
                                .driver()
                                .resolve_question(
                                    &request.request_id,
                                    empty_question_answers(&request),
                                )
                                .await;
                        }
                        Ok(_) => {}
                    }
                }
            })
            .await
            .is_err()
            {
                eprintln!("Agent did not finish interrupting the failed turn in time");
                if let Err(shutdown_error) = sessions.driver().shutdown().await {
                    eprintln!(
                        "Agent cleanup shutdown failed: {}",
                        safe_diagnostic(&shutdown_error.to_string())
                    );
                }
                fatal_driver_error = Some("Agent interruption timed out".to_string());
            }
            (
                TurnOutcome::Failed,
                Some(safe_diagnostic(&error.to_string())),
            )
        }
    };

    typing.stop().await;
    let terminal_diagnostic = terminal.1.as_deref().map(safe_diagnostic);
    log::trace!(
        target: "inline::bridge::turn",
        "phase=turn_terminal event_id={:?} session_id={:?} turn_id={:?} outcome={:?} elapsed_ms={} diagnostic={:?}",
        record.event_id,
        session_id.as_str(),
        turn.turn_id.as_str(),
        terminal.0,
        turn_started_at.elapsed().as_millis(),
        terminal_diagnostic
    );
    let _ = coordinator.complete_turn(&turn.turn_id);
    for token in &pending_approvals {
        if let Some(approval) = store.get_approval(token)?
            && approval.message_id.is_none()
        {
            let message_id = resolve_interaction_message(
                bot,
                approval.action_chat_id,
                "approval",
                token,
                "This approval request is no longer active.",
            )
            .await?;
            store.attach_approval_message(token, message_id.get())?;
        }
    }
    store.invalidate_turn_approvals(&turn.turn_id, now_seconds())?;
    for token in pending_approvals {
        if let Some(approval) = store.get_approval(&token)? {
            if let Some(message_id) = approval.message_id.map(InlineId::new)
                && let Err(error) = clear_approval(
                    bot,
                    approval.action_chat_id,
                    message_id,
                    "This request is no longer active.",
                )
                .await
            {
                eprintln!(
                    "Could not clear a terminal approval message: {}",
                    safe_diagnostic(&error.to_string())
                );
            }
            if let Err(error) =
                clear_shared_approval_status(bot, &approval, "Approval request expired.").await
            {
                eprintln!(
                    "Could not clear a terminal approval status: {}",
                    safe_diagnostic(&error.to_string())
                );
            }
        }
    }
    for token in &turn_question_tokens {
        if let Some(question) = store.get_question(token)?
            && question.message_id.is_none()
        {
            let message_id = resolve_interaction_message(
                bot,
                question.chat_id,
                "question",
                token,
                "This question is no longer active.",
            )
            .await?;
            store.attach_question_message(token, message_id.get())?;
        }
    }
    store.invalidate_turn_questions(&turn.turn_id, now_seconds())?;
    for token in turn_question_tokens {
        if let Some(question) = store.get_question(&token)?
            && let Some(message_id) = question.message_id.map(InlineId::new)
            && try_update_question_message(
                bot,
                question.chat_id,
                message_id,
                question.state.terminal_text(),
            )
            .await
            .is_ok()
        {
            store.mark_question_ui_cleared(&token, now_seconds())?;
        }
    }
    if let Some(text) = activities.final_message_text() {
        let _ =
            presenter.replace_snapshot_with_priority(now_millis(), text, UpdatePriority::Terminal);
    }
    let final_text = final_turn_text(
        presenter.content(),
        terminal.0,
        &files,
        workspace,
        binding.chat_id == route.owner_dm_chat_id,
        validation.as_ref(),
    );
    let final_state = match terminal.0 {
        TurnOutcome::Completed | TurnOutcome::Interrupted => InboundState::Completed,
        TurnOutcome::Failed | TurnOutcome::ConnectionLost | TurnOutcome::AuthenticationRequired => {
            InboundState::Failed
        }
    };
    let terminal_failure = matches!(
        terminal.0,
        TurnOutcome::Failed | TurnOutcome::ConnectionLost | TurnOutcome::AuthenticationRequired
    )
    .then(|| safe_diagnostic(terminal.1.as_deref().unwrap_or("Agent turn failed")));
    let elapsed = format_elapsed_compact(turn_timing.resolve(turn_started_at.elapsed()));
    let progress_header = match terminal.0 {
        TurnOutcome::Completed => format!("Worked for {elapsed}"),
        TurnOutcome::Interrupted => format!("Stopped after {elapsed}"),
        TurnOutcome::Failed | TurnOutcome::ConnectionLost | TurnOutcome::AuthenticationRequired => {
            format!("Failed after {elapsed}")
        }
    };
    activities.set_visibility(visibility_mode);
    activities.set_terminal_header(progress_header.clone());
    persist_progress_ledger(store, &record.event_id, &activities)?;
    let progress_chunks = activities.render_chunks(visibility_mode, &progress_header, None);
    sync_turn_progress(
        bot,
        store,
        &record.event_id,
        binding.chat_id,
        stream_message_id,
        &mut progress_message_ids,
        &progress_chunks,
        "Continued",
    )
    .await?;
    let progress_status = progress_chunks.first().cloned().unwrap_or(progress_header);
    let final_message_id = publish_inbound_final_send_with_attachments(
        bot,
        store,
        &record.event_id,
        binding.chat_id,
        stream_message_id,
        &progress_status,
        &final_text,
        &output_attachments,
        agent_session_id.map(|_| assistant_final_random_id(&turn.turn_id)),
        agent_session_id,
        final_state,
        terminal_failure.as_deref(),
    )
    .await?;
    if input_link_needs_repair
        && let Some(prepared) = prepared_agent_input.as_ref()
        && let Err(error) =
            link_accepted_agent_session_input(bot, prepared, record.message_id).await
    {
        eprintln!(
            "Accepted agent input linkage still needs resync: {}",
            safe_diagnostic(&error.to_string())
        );
    }
    if let (Some(agent_session_id), Some(message_id)) = (agent_session_id, final_message_id) {
        match link_agent_session_assistant_output(
            bot,
            agent_session_id,
            &turn.turn_id,
            message_id.get(),
        )
        .await
        {
            Ok(()) => {
                store.mark_agent_output_linked(&record.event_id)?;
            }
            Err(error) => {
                eprintln!(
                    "Agent session response linkage needs repair: {}",
                    safe_diagnostic(&error.to_string())
                );
            }
        }
    }
    if let Some(message_id) = final_message_id {
        attach_changed_file_actions(
            bot,
            binding.chat_id,
            message_id,
            &final_text,
            &files,
            workspace,
        )
        .await;
    }
    if matches!(terminal.0, TurnOutcome::ConnectionLost) && fatal_driver_error.is_none() {
        fatal_driver_error = Some("Agent connection epoch ended".to_string());
    }
    if let Some(error) = fatal_driver_error {
        return Err(io::Error::new(
            io::ErrorKind::ConnectionAborted,
            format!("Agent turn cleanup failed; the provider was stopped: {error}"),
        )
        .into());
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn expire_active_interactions<D: AgentDriver + 'static>(
    bot: &InlineClient,
    sessions: &ProviderSessionManager<D>,
    session_id: &inline_agent_bridge::ProviderSessionId,
    turn_id: &inline_agent_bridge::TurnId,
    store: &BridgeStore,
    pending_approvals: &mut HashSet<String>,
    pending_questions: &mut HashMap<i64, PendingQuestionUi>,
    now: i64,
) -> Result<(), Box<dyn std::error::Error>> {
    for approval in store.expire_turn_approvals(turn_id, now)? {
        pending_approvals.remove(&approval.callback_token);
        let decision = if approval.decisions.contains(&ApprovalDecision::Reject) {
            Some(ApprovalDecision::Reject)
        } else if approval.decisions.contains(&ApprovalDecision::CancelTurn) {
            Some(ApprovalDecision::CancelTurn)
        } else {
            None
        };
        let result = if let Some(decision) = decision {
            sessions
                .driver()
                .resolve_approval(&approval.provider_approval_id, decision)
                .await
        } else {
            sessions.driver().cancel_turn(session_id, turn_id).await
        };
        if let Some(message_id) = approval.message_id.map(InlineId::new) {
            let _ = clear_approval(
                bot,
                approval.action_chat_id,
                message_id,
                "This approval request expired.",
            )
            .await;
        }
        let _ = clear_shared_approval_status(bot, &approval, "Approval request expired.").await;
        if let Err(error) = result {
            return Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                format!(
                    "expired approval response could not be confirmed: {}",
                    safe_diagnostic(&error.to_string())
                ),
            )
            .into());
        }
    }

    for question in store.expire_turn_questions(turn_id, now)? {
        let pending_entry = pending_questions
            .iter()
            .find(|(_, pending)| pending.token == question.callback_token)
            .map(|(message_id, pending)| (*message_id, pending.clone()));
        let Some((message_id, pending)) = pending_entry else {
            return Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "expired question lost its provider response state",
            )
            .into());
        };
        pending_questions.remove(&message_id);
        let result = sessions
            .driver()
            .resolve_question(
                &pending.request.request_id,
                empty_question_answers(&pending.request),
            )
            .await;
        if try_update_question_message(
            bot,
            question.chat_id,
            pending.message_id,
            QuestionState::Expired.terminal_text(),
        )
        .await
        .is_ok()
        {
            store.mark_question_ui_cleared(&question.callback_token, now)?;
        }
        if let Err(error) = result {
            return Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                format!(
                    "expired question response could not be confirmed: {}",
                    safe_diagnostic(&error.to_string())
                ),
            )
            .into());
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn handle_active_delivery<D: AgentDriver + SessionCatalogSource + 'static>(
    bot: &InlineClient,
    delivery: LosslessEventDelivery,
    sessions: &ProviderSessionManager<D>,
    session_id: &inline_agent_bridge::ProviderSessionId,
    turn_id: &inline_agent_bridge::TurnId,
    store: &BridgeStore,
    binding: &BindingKey,
    route: &InboundRoute,
    active: &ActiveConversation,
    settings_identity: &SettingsIdentity,
    pending: &mut HashSet<String>,
    pending_questions: &mut HashMap<i64, PendingQuestionUi>,
    coordinator: &mut TurnCoordinator,
    typing: &mut TypingIndicator<'_, InlineClient>,
    stop_confirmed: &mut bool,
) -> Result<(), Box<dyn std::error::Error>> {
    if is_agent_session_projection_event(delivery.event()) {
        delivery.ack().await?;
        return Ok(());
    }
    if handle_session_browser_action(
        bot,
        delivery.event(),
        route,
        &SettingsRuntime {
            sessions,
            store,
            active,
            identity: settings_identity,
            turn_active: true,
        },
    )
    .await?
    {
        delivery.ack().await?;
        return Ok(());
    }
    if handle_active_claude_history_action(bot, delivery.event(), route).await? {
        delivery.ack().await?;
        return Ok(());
    }
    if handle_allowlist_action(bot, delivery.event(), route).await? {
        delivery.ack().await?;
        return Ok(());
    }
    let agent_context_owned = event_chat_uses_agent_context_settings(delivery.event(), route)
        .await
        .map_err(io::Error::other)?;
    match handle_settings_event(
        bot,
        delivery.event(),
        &SettingsRuntime {
            sessions,
            store,
            active,
            identity: settings_identity,
            turn_active: true,
        },
        agent_context_owned,
    )
    .await?
    {
        SettingsEventOutcome::NotHandled => {}
        SettingsEventOutcome::Handled {
            provider_epoch_ended,
        } => {
            delivery.ack().await?;
            if provider_epoch_ended {
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionAborted,
                    "local agent connection epoch ended during settings handling",
                )
                .into());
            }
            return Ok(());
        }
    }
    let operator_policy = route.policy_snapshot();
    match handle_settings_command_action(
        bot,
        delivery.event(),
        &SettingsRuntime {
            sessions,
            store,
            active,
            identity: settings_identity,
            turn_active: true,
        },
        &operator_policy,
        agent_context_owned,
    )
    .await?
    {
        SettingsCommandActionOutcome::NotHandled => {}
        SettingsCommandActionOutcome::Handled {
            provider_epoch_ended,
        } => {
            delivery.ack().await?;
            if provider_epoch_ended {
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionAborted,
                    "local agent connection epoch ended during settings handling",
                )
                .into());
            }
            return Ok(());
        }
    }
    if handle_queue_undo_action(bot, delivery.event(), route).await? {
        delivery.ack().await?;
        return Ok(());
    }
    match handle_question_action(
        bot,
        delivery.event(),
        sessions,
        store,
        binding,
        pending_questions,
        route.owner_user_id,
    )
    .await?
    {
        QuestionActionOutcome::NotHandled => {}
        QuestionActionOutcome::Handled => {
            delivery.ack().await?;
            return Ok(());
        }
        QuestionActionOutcome::ProviderEpochEnded => {
            delivery.ack().await?;
            return Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "local agent question response could not be confirmed",
            )
            .into());
        }
    }
    match delivery.event() {
        ClientEvent::MessageActionInvoked {
            interaction_id,
            chat_id,
            actor_user_id,
            data,
            ..
        } => {
            let callback = serde_json::from_slice::<ApprovalCallback>(data).ok();
            match callback.filter(|callback| callback.version == 1) {
                Some(callback) => {
                    let option_index = match callback.decision {
                        CallbackDecision::Option { index } => index,
                    };
                    let context = ApprovalClaimContext {
                        installation_id: binding.installation_id.clone(),
                        turn_id: turn_id.clone(),
                        origin_chat_id: binding.chat_id,
                        action_chat_id: chat_id.get(),
                        actor_user_id: actor_user_id.get(),
                        allowed_actor_user_id: route.owner_user_id,
                        now: now_seconds(),
                    };
                    match store.claim_approval(&callback.token, option_index, &context)? {
                        ApprovalClaimOutcome::Claimed(claim) => {
                            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                                interaction_id: *interaction_id,
                                toast: Some("Applying choice…".to_string()),
                            })
                            .await?;
                            let resolution_text = approval_resolution_text(&claim.decision);
                            match sessions
                                .driver()
                                .resolve_approval(
                                    &claim.record.provider_approval_id,
                                    claim.decision.clone(),
                                )
                                .await
                            {
                                Ok(()) => {
                                    store.complete_approval(
                                        &callback.token,
                                        actor_user_id.get(),
                                        now_seconds(),
                                    )?;
                                    pending.remove(&callback.token);
                                    if let Some(message_id) =
                                        claim.record.message_id.map(InlineId::new)
                                        && let Err(error) = clear_approval(
                                            bot,
                                            claim.record.action_chat_id,
                                            message_id,
                                            resolution_text,
                                        )
                                        .await
                                    {
                                        eprintln!(
                                            "Could not finalize an approval card: {}",
                                            safe_diagnostic(&error.to_string())
                                        );
                                    }
                                    if let Err(error) = clear_shared_approval_status(
                                        bot,
                                        &claim.record,
                                        resolution_text,
                                    )
                                    .await
                                    {
                                        eprintln!(
                                            "Could not finalize a shared approval status: {}",
                                            safe_diagnostic(&error.to_string())
                                        );
                                    }
                                }
                                Err(error) => {
                                    store.fail_approval_dispatch(
                                        &callback.token,
                                        actor_user_id.get(),
                                        now_seconds(),
                                    )?;
                                    pending.remove(&callback.token);
                                    eprintln!(
                                        "Agent approval resolution failed: {}",
                                        safe_diagnostic(&error.to_string())
                                    );
                                    if let Some(message_id) =
                                        claim.record.message_id.map(InlineId::new)
                                    {
                                        let _ = clear_approval(
                                            bot,
                                            claim.record.action_chat_id,
                                            message_id,
                                            "The choice could not be confirmed. This request was closed.",
                                        )
                                        .await;
                                    }
                                    let _ = clear_shared_approval_status(
                                        bot,
                                        &claim.record,
                                        "The approval result could not be confirmed.",
                                    )
                                    .await;
                                    delivery.ack().await?;
                                    return Err(io::Error::new(
                                        io::ErrorKind::ConnectionAborted,
                                        "local agent approval response could not be confirmed",
                                    )
                                    .into());
                                }
                            }
                        }
                        ApprovalClaimOutcome::Unauthorized => {
                            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                                interaction_id: *interaction_id,
                                toast: Some("Only the bot owner can approve this.".to_string()),
                            })
                            .await?;
                        }
                        ApprovalClaimOutcome::Unknown
                        | ApprovalClaimOutcome::WrongContext
                        | ApprovalClaimOutcome::InvalidOption
                        | ApprovalClaimOutcome::Expired
                        | ApprovalClaimOutcome::NotPending(_) => {
                            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                                interaction_id: *interaction_id,
                                toast: Some("This request is no longer active.".to_string()),
                            })
                            .await?;
                        }
                    }
                }
                _ => {
                    bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                        interaction_id: *interaction_id,
                        toast: Some("This request is no longer active.".to_string()),
                    })
                    .await?;
                }
            }
            delivery.ack().await?;
        }
        ClientEvent::MessageStored { message } => {
            if steer_active_source_edit(message, sessions, session_id, turn_id, store, route)
                .await?
            {
                delivery.ack().await?;
                return Ok(());
            }
            let reply_to_message_id = match message.reply_to_message_id {
                Some(message_id) => Some(message_id),
                None => route
                    .bot_store
                    .message(message.chat_id, message.message_id)
                    .await?
                    .and_then(|stored| stored.reply_to_message_id),
            };
            if let Some(mut record) = inbound_from_delivery(bot, &delivery, route).await? {
                if handle_terminal_question_reply(bot, delivery.event(), &record, route).await? {
                    delivery.ack().await?;
                    return Ok(());
                }
                if handle_session_browser_command(
                    bot,
                    &record,
                    route,
                    &SettingsRuntime {
                        sessions,
                        store,
                        active,
                        identity: settings_identity,
                        turn_active: true,
                    },
                )
                .await?
                {
                    delivery.ack().await?;
                    return Ok(());
                }
                if handle_active_claude_history_command(bot, &record, route).await? {
                    delivery.ack().await?;
                    return Ok(());
                }
                if handle_allowlist_command(bot, &record, route).await? {
                    delivery.ack().await?;
                    return Ok(());
                }
                if let Some(question_message_id) = reply_to_message_id.map(InlineId::get)
                    && let Some(pending_question) = pending_questions.remove(&question_message_id)
                {
                    if record.sender_user_id != route.owner_user_id {
                        pending_questions.insert(question_message_id, pending_question);
                        if store.claim_event(&record.event_id, now_seconds())? {
                            send_text_reply(
                                bot,
                                record.binding.chat_id,
                                record.message_id,
                                "Only the bot owner can answer this question.",
                                &format!("{}-question-unauthorized", record.event_id),
                                BridgeNotificationClass::RoutineStatus,
                            )
                            .await?;
                        }
                        delivery.ack().await?;
                        return Ok(());
                    }
                    match parse_question_answers(&pending_question.request, &record.direction.text)
                    {
                        Ok(answers) => {
                            let context = QuestionClaimContext {
                                installation_id: binding.installation_id.clone(),
                                provider_id: sessions.provider_id().clone(),
                                turn_id: pending_question.request.turn_id.clone(),
                                chat_id: binding.chat_id,
                                message_id: question_message_id,
                                actor_user_id: record.sender_user_id,
                                event_id: record.event_id.clone(),
                                now: now_seconds(),
                            };
                            match store.claim_question(
                                &QuestionClaimLocator::Message {
                                    chat_id: binding.chat_id,
                                    message_id: question_message_id,
                                },
                                &context,
                            )? {
                                QuestionClaimOutcome::Claimed(_) => {}
                                _ => {
                                    delivery.ack().await?;
                                    return Ok(());
                                }
                            }
                            store.claim_event(&record.event_id, now_seconds())?;
                            match sessions
                                .driver()
                                .resolve_question(&pending_question.request.request_id, answers)
                                .await
                            {
                                Ok(()) => {
                                    store.finish_question(
                                        &pending_question.token,
                                        &record.event_id,
                                        record.sender_user_id,
                                        QuestionResolution::Resolved,
                                        now_seconds(),
                                    )?;
                                    if try_update_question_message(
                                        bot,
                                        binding.chat_id,
                                        pending_question.message_id,
                                        "Answered.",
                                    )
                                    .await
                                    .is_ok()
                                    {
                                        store.mark_question_ui_cleared(
                                            &pending_question.token,
                                            now_seconds(),
                                        )?;
                                    }
                                    let _ = send_text_reply(
                                        bot,
                                        binding.chat_id,
                                        record.message_id,
                                        "Answer sent.",
                                        &format!("{}-question-answered", record.event_id),
                                        BridgeNotificationClass::RoutineStatus,
                                    )
                                    .await;
                                }
                                Err(error) => {
                                    store.finish_question(
                                        &pending_question.token,
                                        &record.event_id,
                                        record.sender_user_id,
                                        QuestionResolution::DeliveryFailed,
                                        now_seconds(),
                                    )?;
                                    eprintln!(
                                        "Agent question resolution failed: {}",
                                        safe_diagnostic(&error.to_string())
                                    );
                                    if try_update_question_message(
                                        bot,
                                        binding.chat_id,
                                        pending_question.message_id,
                                        "This question is no longer active.",
                                    )
                                    .await
                                    .is_ok()
                                    {
                                        store.mark_question_ui_cleared(
                                            &pending_question.token,
                                            now_seconds(),
                                        )?;
                                    }
                                    delivery.ack().await?;
                                    return Err(io::Error::new(
                                        io::ErrorKind::ConnectionAborted,
                                        "local agent question response could not be confirmed",
                                    )
                                    .into());
                                }
                            }
                        }
                        Err(message) => {
                            pending_questions.insert(question_message_id, pending_question);
                            if let Err(error) = send_text_reply(
                                bot,
                                binding.chat_id,
                                record.message_id,
                                message,
                                &format!("{}-question-invalid", record.event_id),
                                BridgeNotificationClass::RoutineStatus,
                            )
                            .await
                            {
                                eprintln!(
                                    "Could not explain an invalid agent answer: {}",
                                    safe_diagnostic(&error.to_string())
                                );
                            }
                        }
                    }
                    delivery.ack().await?;
                    return Ok(());
                }
                if handle_follow_command(bot, &record, route).await? {
                    delivery.ack().await?;
                    return Ok(());
                }
                if record.binding != *binding {
                    if store.accept_inbound(&record)? {
                        send_text_reply(
                            bot,
                            record.binding.chat_id,
                            record.message_id,
                            "Got it — I’ll start this shortly.",
                            &format!("{}-accepted", record.event_id),
                            BridgeNotificationClass::RoutineStatus,
                        )
                        .await?;
                    }
                    delivery.ack().await?;
                    return Ok(());
                }
                let command = parse_command(&record.direction.text, &route.bot_username);
                if matches!(
                    &command,
                    Ok(Some(CommandInvocation { name, arguments, .. }))
                        if name == "stop" && arguments.is_empty()
                ) {
                    log::trace!(
                        target: "inline::bridge::turn",
                        "phase=stop_received event_id={:?} session_id={:?} turn_id={:?}",
                        record.event_id,
                        session_id.as_str(),
                        turn_id.as_str()
                    );
                    let mut cancel_turn = false;
                    let mut acknowledgement = None;
                    let handoff = is_linked_codex_stop(route, &record)?;
                    let accepted = if handoff {
                        // The same command becomes idle release work after
                        // this turn's terminal cleanup drops its provider leases.
                        store.accept_session_handoff(&record)?
                    } else {
                        store.claim_event(&record.event_id, now_seconds())?
                    };
                    if accepted {
                        let effects = coordinator.stop();
                        acknowledgement = Some(
                            coordinator_acknowledgement(&effects)
                                .unwrap_or(Acknowledgement::Stopping),
                        );
                        cancel_turn = effects
                            .iter()
                            .any(|effect| matches!(effect, CoordinatorEffect::CancelTurn { .. }));
                    }
                    if cancel_turn {
                        // Stop the visible activity before any acknowledgement
                        // network I/O. A slow Inline send must never postpone
                        // the actual provider interrupt.
                        typing.stop().await;
                    }
                    if cancel_turn {
                        let acknowledgement = acknowledgement.unwrap_or(Acknowledgement::Stopping);
                        let acknowledgement_external_id = format!("{}-stopping", record.event_id);
                        // The durable event claim already prevents replay from
                        // becoming work. Start the provider interrupt in the
                        // same poll as delivery/message acknowledgement so no
                        // Inline network latency can postpone cancellation.
                        let (delivery_result, acknowledgement_result, cancellation) = tokio::join!(
                            delivery.ack(),
                            send_inbound_response(
                                bot,
                                route,
                                &record,
                                binding.chat_id,
                                if handoff {
                                    "Stop requested. Once stopping is confirmed, Inline will try to release Codex. Earlier queued messages in this thread were cancelled. Wait for the release confirmation before continuing elsewhere."
                                } else {
                                    acknowledgement.message()
                                },
                                &acknowledgement_external_id,
                                BridgeNotificationClass::RoutineStatus,
                            ),
                            tokio::time::timeout(
                                ACTIVE_STOP_CONFIRMATION_TIMEOUT,
                                sessions.driver().cancel_turn(session_id, turn_id),
                            ),
                        );
                        if let Err(error) = delivery_result {
                            eprintln!(
                                "Could not acknowledge stop delivery: {}",
                                safe_diagnostic(&error.to_string())
                            );
                        }
                        if let Err(error) = acknowledgement_result {
                            eprintln!(
                                "Could not publish stop acknowledgement: {}",
                                safe_diagnostic(&error.to_string())
                            );
                        }
                        let error = match cancellation {
                            Ok(Ok(())) => {
                                // A successful cancellation is itself the
                                // terminal barrier. Some providers can race or
                                // omit their terminal event after reporting
                                // that no turn remains active.
                                *stop_confirmed = true;
                                log::trace!(
                                    target: "inline::bridge::turn",
                                    "phase=stop_confirmed event_id={:?} session_id={:?} turn_id={:?}",
                                    record.event_id,
                                    session_id.as_str(),
                                    turn_id.as_str()
                                );
                                return Ok(());
                            }
                            Ok(Err(error)) => error,
                            Err(_) => {
                                log::warn!(
                                    target: "inline::bridge::turn",
                                    "phase=stop_watchdog_expired event_id={:?} session_id={:?} turn_id={:?} deadline_ms={}",
                                    record.event_id,
                                    session_id.as_str(),
                                    turn_id.as_str(),
                                    ACTIVE_STOP_CONFIRMATION_TIMEOUT.as_millis()
                                );
                                if let Err(error) = sessions.driver().shutdown().await {
                                    eprintln!(
                                        "Agent stop watchdog shutdown failed: {}",
                                        safe_diagnostic(&error.to_string())
                                    );
                                }
                                DriverError::ProcessExited(
                                    "agent cancellation exceeded the stop deadline; provider epoch stopped"
                                        .to_string(),
                                )
                            }
                        };
                        let connection_epoch_ended = error.ends_epoch();
                        eprintln!(
                            "Agent turn cancellation failed: {}",
                            safe_diagnostic(&error.to_string())
                        );
                        send_inbound_response(
                            bot,
                            route,
                            &record,
                            binding.chat_id,
                            if connection_epoch_ended {
                                BridgeNotice::AgentConnectionLost.message()
                            } else {
                                "I couldn’t confirm the stop. I’m restarting the local agent and failing this turn."
                            },
                            &format!("{}-stop-failed", record.event_id),
                            BridgeNotificationClass::ImportantFailure,
                        )
                        .await?;
                        if connection_epoch_ended {
                            return Err(io::Error::new(
                                io::ErrorKind::ConnectionAborted,
                                "local agent connection epoch ended during cancellation",
                            )
                            .into());
                        }
                        // A cancellation failure makes a successful `Stopped.`
                        // terminal unsafe even if the provider later emits an
                        // interrupted event. Fail this turn and restart the
                        // provider worker so an uncertain tool process cannot
                        // remain attached to a supposedly healthy epoch.
                        return Err(io::Error::new(
                            io::ErrorKind::ConnectionAborted,
                            "local agent stop could not be confirmed; restarting provider",
                        )
                        .into());
                    } else {
                        delivery.ack().await?;
                        if let Some(acknowledgement) = acknowledgement {
                            send_inbound_response(
                                bot,
                                route,
                                &record,
                                binding.chat_id,
                                acknowledgement.message(),
                                &format!("{}-stopping", record.event_id),
                                BridgeNotificationClass::RoutineStatus,
                            )
                            .await?;
                        }
                    }
                    return Ok(());
                }
                if let Ok(Some(CommandInvocation {
                    name, arguments, ..
                })) = &command
                    && name == "queue"
                {
                    if arguments.is_empty() {
                        if store.claim_event(&record.event_id, now_seconds())? {
                            send_text_reply(
                                bot,
                                binding.chat_id,
                                record.message_id,
                                "Usage: /queue <instruction>",
                                &format!("{}-queue-usage", record.event_id),
                                BridgeNotificationClass::RoutineStatus,
                            )
                            .await?;
                        }
                    } else {
                        // `/queue` changes only the instruction text. Preserve
                        // media from the command message so the deferred turn
                        // sees exactly what the user queued.
                        replace_direction_text(&mut record.direction, arguments.clone());
                        let queue_id = QueueItemId::new(record.event_id.clone())?;
                        let was_already_queued = coordinator.has_queued_direction(&queue_id);
                        let (disposition, _) = coordinator.accept_direction(
                            record.direction.clone(),
                            true,
                            sessions.driver().capabilities().steering,
                            queue_id.clone(),
                        );
                        if store.accept_inbound(&record)? {
                            if let Some(acknowledgement) = queue_acknowledgement(disposition) {
                                send_queue_confirmation(bot, &record, acknowledgement.message())
                                    .await?;
                            }
                        } else {
                            reconcile_replayed_queue_delivery(
                                store,
                                coordinator,
                                &record,
                                &queue_id,
                                was_already_queued,
                            )?;
                        }
                    }
                    delivery.ack().await?;
                    return Ok(());
                }
                if command.as_ref().is_err() || matches!(command.as_ref(), Ok(Some(_))) {
                    if reject_agent_context_settings_command(bot, &record, route).await? {
                        delivery.ack().await?;
                        return Ok(());
                    }
                    let snapshot = active.snapshot();
                    match resolve_idle_command(
                        sessions,
                        store,
                        &snapshot.binding,
                        &snapshot.workspace,
                        &SettingsRuntime {
                            sessions,
                            store,
                            active,
                            identity: settings_identity,
                            turn_active: true,
                        },
                        record.sender_user_id,
                        &route.bot_username,
                        &record.direction.text,
                    )
                    .await
                    {
                        IdleCommandResolution::NotCommand => {}
                        IdleCommandResolution::Handled {
                            message,
                            failure,
                            provider_epoch_ended,
                            choices,
                        } => {
                            if store.claim_event(&record.event_id, now_seconds())? {
                                if let Some(choices) = choices.as_ref() {
                                    send_settings_command_choices(
                                        bot, store, &record, &message, choices,
                                    )
                                    .await?;
                                } else {
                                    send_inbound_response(
                                        bot,
                                        route,
                                        &record,
                                        binding.chat_id,
                                        &message,
                                        &format!("{}-command-result", record.event_id),
                                        if failure.is_some() {
                                            BridgeNotificationClass::ImportantFailure
                                        } else {
                                            BridgeNotificationClass::RoutineStatus
                                        },
                                    )
                                    .await?;
                                }
                            }
                            if let Some(failure) = failure {
                                eprintln!("Bridge command failed: {failure}");
                            }
                            delivery.ack().await?;
                            if provider_epoch_ended {
                                return Err(io::Error::new(
                                    io::ErrorKind::ConnectionAborted,
                                    "local agent connection epoch ended during command handling",
                                )
                                .into());
                            }
                            return Ok(());
                        }
                        IdleCommandResolution::StartDirection {
                            instruction,
                            acknowledgement: _,
                        } => {
                            // Provider commands can lower into an ordinary
                            // direction. Keep any media attached to the command
                            // message while replacing its canonical text.
                            replace_direction_text(&mut record.direction, instruction);
                            let queue_id = QueueItemId::new(record.event_id.clone())?;
                            let was_already_queued = coordinator.has_queued_direction(&queue_id);
                            let (disposition, _) = coordinator.accept_direction(
                                record.direction.clone(),
                                true,
                                sessions.driver().capabilities().steering,
                                queue_id.clone(),
                            );
                            if store.accept_inbound(&record)? {
                                if let Some(acknowledgement) = queue_acknowledgement(disposition) {
                                    send_queue_confirmation(
                                        bot,
                                        &record,
                                        acknowledgement.message(),
                                    )
                                    .await?;
                                }
                            } else {
                                reconcile_replayed_queue_delivery(
                                    store,
                                    coordinator,
                                    &record,
                                    &queue_id,
                                    was_already_queued,
                                )?;
                            }
                            delivery.ack().await?;
                            return Ok(());
                        }
                    }
                    // A command explicitly targeting a different bot is not an
                    // instruction for the active local agent.
                    delivery.ack().await?;
                    return Ok(());
                }
                let queue_id = QueueItemId::new(record.event_id.clone())?;
                let was_already_queued = coordinator.has_queued_direction(&queue_id);
                let (disposition, _) = coordinator.accept_direction(
                    record.direction.clone(),
                    false,
                    sessions.driver().capabilities().steering,
                    queue_id.clone(),
                );
                match disposition {
                    DirectionDisposition::Queued
                    | DirectionDisposition::QueuedBecauseSteeringUnsupported => {
                        if store.accept_inbound(&record)? {
                            if let Some(acknowledgement) = queue_acknowledgement(disposition) {
                                send_queue_confirmation(bot, &record, acknowledgement.message())
                                    .await?;
                            }
                        } else {
                            reconcile_replayed_queue_delivery(
                                store,
                                coordinator,
                                &record,
                                &queue_id,
                                was_already_queued,
                            )?;
                        }
                    }
                    DirectionDisposition::Steered => {
                        let accepted = store.accept_inbound(&record)?;
                        if accepted && store.start_inbound(&record.event_id, now_seconds())? {
                            let prepared = match prepare_agent_session_input(
                                sessions, store, route, binding, &record,
                            )
                            .await
                            {
                                Ok(prepared) => prepared,
                                Err(error) => {
                                    let diagnostic = safe_diagnostic(&error.to_string());
                                    store.fail_inbound(&record.event_id, &diagnostic)?;
                                    send_text_reply(
                                    bot,
                                    binding.chat_id,
                                    record.message_id,
                                    "I couldn’t connect this message to the selected agent session. Nothing was sent to the provider; try again.",
                                    &format!("{}-session-link-failed", record.event_id),
                                    BridgeNotificationClass::ImportantFailure,
                                )
                                .await?;
                                    delivery.ack().await?;
                                    return Ok(());
                                }
                            };
                            let steered = sessions
                                .driver()
                                .steer_turn(
                                    session_id,
                                    turn_id,
                                    TurnInput {
                                        text: record.direction.text.clone(),
                                        attachments: record.direction.attachments.clone(),
                                        client_message_id: Some(record.direction.id.to_string()),
                                    },
                                )
                                .await;
                            match steered {
                                Ok(()) => {
                                    if !store.attach_inbound_turn(
                                        &record.event_id,
                                        turn_id,
                                        None,
                                    )? {
                                        return Err(io::Error::other(
                                            "accepted steering input lost its durable record",
                                        )
                                        .into());
                                    }
                                    if let Some(prepared) = prepared.as_ref()
                                        && let Err(error) = link_accepted_agent_session_input(
                                            bot,
                                            prepared,
                                            record.message_id,
                                        )
                                        .await
                                    {
                                        eprintln!(
                                            "Accepted steering linkage needs resync: {}",
                                            safe_diagnostic(&error.to_string())
                                        );
                                    }
                                    // Native steering is intentionally silent. The running
                                    // agent's updated output is the acknowledgement.
                                    store.complete_inbound(&record.event_id)?;
                                }
                                Err(error) => {
                                    if error.ends_epoch() {
                                        let diagnostic = safe_diagnostic(&error.to_string());
                                        store.fail_inbound(&record.event_id, &diagnostic)?;
                                        send_text_reply(
                                            bot,
                                            binding.chat_id,
                                            record.message_id,
                                            BridgeNotice::AgentConnectionLost.message(),
                                            &format!("{}-steer-failed", record.event_id),
                                            BridgeNotificationClass::ImportantFailure,
                                        )
                                        .await?;
                                        return Err(io::Error::new(
                                            io::ErrorKind::ConnectionAborted,
                                            "local agent connection epoch ended during steering",
                                        )
                                        .into());
                                    }
                                    let _ = coordinator.queue_after_failed_steer(
                                        record.direction.clone(),
                                        queue_id,
                                    );
                                    store.defer_inbound(&record.event_id)?;
                                    send_queue_confirmation(
                                        bot,
                                        &record,
                                        Acknowledgement::QueuedBecauseSteeringUnsupported.message(),
                                    )
                                    .await?;
                                }
                            }
                        }
                    }
                    DirectionDisposition::Started => {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "active turn coordinator unexpectedly became idle",
                        )
                        .into());
                    }
                }
            }
            delivery.ack().await?;
        }
        _ => delivery.ack().await?,
    }
    Ok(())
}
