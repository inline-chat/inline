//! The bridge v2 runtime: one native session per (thread, agent) on the
//! session contract, rendered into Inline with blocks (spec §4–§7).
//!
//! This loop owns intake: it decides what each Inline message is for,
//! records direct input in the ledger before acknowledging the delivery, and
//! hands it to the thread's work actor (`work.rs`).

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use inline_agent_bridge::ProviderSessionId;
use inline_agent_bridge::group::{
    ContextAuthorRole, ContextMessage, Conversation, Grants, GroupMessage, IntakeDecision,
    IntakeFacts, LoopGuards, Operation, ParticipationMode, PendingInput, ReleaseCause, WorkPhase,
    decide_intake, direct_input, origin_of,
};
use inline_agent_bridge::harness::{
    Delivery, HarnessDriver, Input, InputContent, InputId, OutputMode, UserId,
};
use inline_client::{
    AnswerMessageActionRequest, BotInteractionEvent, ClientEvent, ClientStatus,
    CreateReplyThreadRequest, InlineClient, InlineId, LosslessEventReceiver, MessageRecord,
};
use inline_protocol::proto;
use tokio::sync::{mpsc, oneshot};

use super::api::{self, Notify, chat_peer};
use super::doc::DocBuilder;
use super::intake::{MessageFacts, grants_by_user, group_message};
use super::ledger::{Begin, InputState, Ledger, input_id};
use super::render::{QUESTION_FORM_ID, Vocabulary};
use super::tools::Tools;
use super::work::{
    AccessSource, ActionData, Agent, Command, Control, Known, OwnerCalls, WorkHandle,
};

const DEFAULT_HEARTBEAT: Duration = Duration::from_secs(60);
/// How often the bot's Inline connection is checked.
const CONNECTION_CHECK: Duration = Duration::from_secs(5);
const MAX_RECONNECT_DELAY: Duration = Duration::from_secs(300);

/// Backoff for resuming a client that stopped receiving events.
#[derive(Default)]
struct Reconnect {
    delay: Duration,
    next: Option<tokio::time::Instant>,
}
/// Messages of a group thread an agent sees when it joins.
const JOIN_CONTEXT_MESSAGES: u32 = 40;
const JOIN_CONTEXT_BYTES: usize = 24 * 1024;
/// Settled ledger records are kept this long for replay detection.
const LEDGER_RETENTION_SECS: i64 = 14 * 24 * 3600;

/// Identity and settings of one v2 agent.
#[derive(Clone, Debug)]
pub(crate) struct V2Config {
    pub vocabulary: Vocabulary,
    pub agent_name: String,
    pub installation_id: String,
    pub owner_user_id: i64,
    pub bot_user_id: i64,
    pub bot_username: String,
    pub dm_chat_id: i64,
    pub folder: PathBuf,
    pub machine_label: String,
    pub executable_path: Option<String>,
    pub accept_messages_after: i64,
    /// The v1 allowlist, imported once as INVOKE + STEER grants.
    pub allowlist: Vec<i64>,
    pub ledger_path: PathBuf,
    /// Downloaded message media, handed to the harness as local files.
    pub attachments_dir: PathBuf,
}

impl V2Config {
    fn provider(&self) -> proto::AgentSessionProvider {
        match self.vocabulary {
            Vocabulary::Codex => proto::AgentSessionProvider::Codex,
            Vocabulary::Claude => proto::AgentSessionProvider::Claude,
        }
    }
}

/// Grants from `listAgentGrants`, cached until a grant update arrives.
struct Access {
    bot: InlineClient,
    owner_user_id: i64,
    cache: tokio::sync::Mutex<Option<HashMap<i64, Grants>>>,
}

impl Access {
    async fn invalidate(&self) {
        *self.cache.lock().await = None;
    }
}

impl AccessSource for Access {
    fn grants(&self, user_id: i64) -> futures_util::future::BoxFuture<'_, Grants> {
        Box::pin(async move {
            if user_id == self.owner_user_id {
                return Grants::OWNER;
            }
            let mut cache = self.cache.lock().await;
            if cache.is_none() {
                match api::list_grants(&self.bot).await {
                    Ok(result) => *cache = Some(grants_by_user(&result)),
                    Err(error) => {
                        // Unknown grants admit nobody but the owner.
                        log::warn!(target: "inline::bridge::v2", "grants unavailable: {error}");
                        return Grants::NONE;
                    }
                }
            }
            cache
                .as_ref()
                .and_then(|grants| grants.get(&user_id).copied())
                .unwrap_or_default()
        })
    }
}

/// Owner-authenticated session calls through the bridge's owner connection.
pub(crate) struct OwnerConnection(pub Arc<crate::bridge::owner_control::OwnerControl>);

impl OwnerCalls for OwnerConnection {
    fn connect(
        &self,
        input: proto::ConnectAgentSessionInput,
    ) -> futures_util::future::BoxFuture<'_, Result<proto::ConnectAgentSessionResult, String>> {
        Box::pin(async move {
            self.0
                .connect_agent_session(input)
                .await
                .map_err(|error| error.to_string())
        })
    }

    fn lookup(
        &self,
        input: proto::GetAgentSessionInput,
    ) -> futures_util::future::BoxFuture<'_, Result<proto::GetAgentSessionResult, String>> {
        Box::pin(async move {
            self.0
                .get_agent_session(input)
                .await
                .map_err(|error| error.to_string())
        })
    }
}

pub(crate) struct Runtime {
    config: V2Config,
    agent: Arc<Agent>,
    access: Arc<Access>,
    works: HashMap<i64, WorkHandle>,
    /// A chat a work moved out of → where it went, so cards left behind still
    /// reach it. Messages there never do: the parent may start its own work.
    moved: HashMap<i64, i64>,
    moves: Option<mpsc::UnboundedReceiver<(i64, i64)>>,
    reconnect: Reconnect,
    participation: HashMap<i64, Option<proto::AgentParticipation>>,
    default_output_mode: OutputMode,
    loop_guards: LoopGuards,
}

impl Runtime {
    pub(crate) fn new(
        config: V2Config,
        bot: InlineClient,
        owner: Arc<dyn OwnerCalls>,
        harness: Arc<dyn HarnessDriver>,
        tools: Option<Arc<Tools>>,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let ledger = Arc::new(Ledger::open(&config.ledger_path)?);
        let (moves_tx, moves) = mpsc::unbounded_channel();
        let access = Arc::new(Access {
            bot: bot.clone(),
            owner_user_id: config.owner_user_id,
            cache: tokio::sync::Mutex::new(None),
        });
        let names = Arc::new(api::Names::new(bot.clone()));
        let agent = Arc::new(Agent {
            bot,
            owner,
            access: access.clone(),
            harness,
            ledger,
            vocabulary: config.vocabulary,
            provider: config.provider(),
            agent_name: config.agent_name.clone(),
            installation_id: config.installation_id.clone(),
            owner_user_id: config.owner_user_id,
            bot_user_id: config.bot_user_id,
            folder: config.folder.clone(),
            sent: tools.as_ref().map_or_else(
                || Arc::new(std::sync::Mutex::new(HashSet::new())),
                |tools| tools.sent(),
            ),
            tools,
            moves: moves_tx,
            names,
        });
        Ok(Self {
            config,
            agent,
            access,
            works: HashMap::new(),
            moved: HashMap::new(),
            moves: Some(moves),
            reconnect: Reconnect::default(),
            participation: HashMap::new(),
            default_output_mode: OutputMode::Detailed,
            loop_guards: LoopGuards::default(),
        })
    }

    /// Serves Inline events until `shutdown` resolves or the stream ends.
    pub(crate) async fn run(
        mut self,
        events: &mut LosslessEventReceiver,
        shutdown: impl std::future::Future<Output = ()>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        if !self.config.allowlist.is_empty()
            && let Err(error) =
                api::import_grants(&self.agent.bot, self.config.allowlist.clone()).await
        {
            log::warn!(target: "inline::bridge::v2", "allowlist import failed: {error}");
        }
        self.recover().await;
        let mut heartbeat = tokio::time::interval(self.heartbeat().await);
        heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        tokio::pin!(shutdown);
        let mut moves = self.moves.take().expect("run once");
        let mut connection = tokio::time::interval(CONNECTION_CHECK);
        connection.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let result = loop {
            tokio::select! {
                biased;
                _ = &mut shutdown => break Ok(()),
                // Before any delivery, so a subthread's first reply finds its work.
                Some((from, to)) = moves.recv() => self.moved_work(from, to),
                _ = connection.tick() => self.keep_connected().await,
                _ = heartbeat.tick() => {
                    let interval = self.heartbeat().await;
                    if interval != heartbeat.period() {
                        heartbeat = tokio::time::interval(interval);
                        heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                    }
                }
                delivery = events.recv_delivery() => {
                    let Some(delivery) = delivery else {
                        break Err("Inline bot event stream closed".to_owned());
                    };
                    let failure = self.handle(delivery.event()).await.err().map(|error| error.to_string());
                    if let Some(error) = failure {
                        log::warn!(target: "inline::bridge::v2", "event handling failed: {error}");
                        // Never silently: tell the sender this message was not taken.
                        if let ClientEvent::MessageStored { message } = delivery.event() {
                            self.reply(
                                message.chat_id.get(),
                                message.message_id.get(),
                                &format!("{} could not take this: {error}", self.config.agent_name),
                            )
                            .await;
                        }
                    }
                    // The input is in the ledger (or was refused visibly), so
                    // the delivery can be acknowledged.
                    if let Err(error) = delivery.ack().await {
                        break Err(error.to_string());
                    }
                }
            }
        };
        self.report_status(proto::AgentRuntimeStatus::Offline).await;
        for (_, work) in self.works.drain() {
            work.task.abort();
        }
        result.map_err(|error| {
            std::io::Error::new(std::io::ErrorKind::ConnectionAborted, error).into()
        })
    }

    /// Input a previous run recorded but never confirmed is reported to its
    /// sender, never resent: it may already have reached the harness.
    async fn recover(&mut self) {
        let unresolved = match self.agent.ledger.unresolved() {
            Ok(records) => records,
            Err(error) => {
                log::warn!(target: "inline::bridge::v2", "ledger unreadable: {error}");
                return;
            }
        };
        for record in unresolved {
            let text = match record.state {
                InputState::Unknown | InputState::Sent => format!(
                    "{} restarted while this was being delivered, so it may or may not have arrived. Reply again if it still needs doing.",
                    self.config.agent_name
                ),
                _ => format!(
                    "{} restarted before this ran. Reply again if it still needs doing.",
                    self.config.agent_name
                ),
            };
            self.reply(record.chat_id, record.message_id, &text).await;
            let _ = self.agent.ledger.set(&record.input_id, InputState::Failed);
        }
        let _ = self.agent.ledger.prune(LEDGER_RETENTION_SECS);
    }

    async fn heartbeat(&mut self) -> Duration {
        match self.report_status(proto::AgentRuntimeStatus::Online).await {
            Some(result) => {
                if let Some(runtime) = &result.runtime {
                    let mode = output_mode(runtime.default_output_mode);
                    if mode != self.default_output_mode {
                        self.default_output_mode = mode;
                        let chats: Vec<i64> = self.works.keys().copied().collect();
                        for chat_id in chats {
                            self.refresh_mode(chat_id).await;
                        }
                    }
                }
                Duration::from_secs(u64::from(result.heartbeat_interval_seconds.max(15)))
            }
            None => DEFAULT_HEARTBEAT,
        }
    }

    async fn report_status(
        &self,
        status: proto::AgentRuntimeStatus,
    ) -> Option<proto::ReportAgentRuntimeResult> {
        let info = self.agent.harness.describe();
        api::report_runtime(
            &self.agent.bot,
            proto::ReportAgentRuntimeInput {
                provider: self.config.provider() as i32,
                status: status as i32,
                machine_label: Some(self.config.machine_label.clone()),
                executable_path: self.config.executable_path.clone(),
                executable_version: info.executable.version.clone(),
                bridge_version: Some(env!("CARGO_PKG_VERSION").to_owned()),
                ..Default::default()
            },
        )
        .await
        .map_err(|error| log::warn!(target: "inline::bridge::v2", "heartbeat failed: {error}"))
        .ok()
    }

    async fn handle(&mut self, event: &ClientEvent) -> Result<(), Box<dyn std::error::Error>> {
        match event {
            ClientEvent::MessageStored { message } => self.on_message(message).await,
            ClientEvent::MessageActionInvoked {
                interaction_id,
                chat_id,
                message_id,
                actor_user_id,
                data,
                ..
            } => {
                let toast = match serde_json::from_slice::<ActionData>(data) {
                    Ok(data) => {
                        self.ask(chat_id.get(), |reply| Command::Action {
                            message_id: message_id.get(),
                            actor: actor_user_id.get(),
                            data,
                            reply,
                        })
                        .await
                    }
                    Err(_) => Some("This button is no longer active.".to_owned()),
                };
                self.answer(*interaction_id, toast).await;
                Ok(())
            }
            ClientEvent::MessageFormSubmitted {
                interaction_id,
                chat_id,
                message_id,
                actor_user_id,
                form_id,
                values,
            } => {
                let toast = if form_id == QUESTION_FORM_ID {
                    self.ask(chat_id.get(), |reply| Command::Form {
                        message_id: message_id.get(),
                        actor: actor_user_id.get(),
                        values: values.clone(),
                        reply,
                    })
                    .await
                } else {
                    Some("This form is no longer active.".to_owned())
                };
                self.answer(*interaction_id, toast).await;
                Ok(())
            }
            ClientEvent::AgentSessionControlRequested {
                interaction_id,
                agent_session_id,
                actor_user_id,
                op,
                ..
            } => {
                let chat = self
                    .works
                    .iter()
                    .find(|(_, work)| work.agent_session_id() == Some(agent_session_id.get()))
                    .map(|(chat, _)| *chat);
                let control = match proto::AgentSessionControl::try_from(*op) {
                    Ok(proto::AgentSessionControl::Stop) => Some(Control::Stop),
                    Ok(proto::AgentSessionControl::Pause) => Some(Control::Pause),
                    Ok(proto::AgentSessionControl::Resume) => Some(Control::Resume),
                    _ => None,
                };
                let toast = match (chat, control) {
                    (Some(chat), Some(control)) => {
                        self.ask(chat, |reply| Command::Control {
                            control,
                            actor: actor_user_id.get(),
                            reply,
                        })
                        .await
                    }
                    (None, _) => Some("This work is not running on its machine.".to_owned()),
                    (_, None) => Some("That control is not supported.".to_owned()),
                };
                self.answer(*interaction_id, toast).await;
                Ok(())
            }
            // The agent's own work thread (a subthread: `/new` or
            // start_subthread) renamed in Inline renames its native session.
            // A group thread gave its title once, at the start (spec §15.7).
            ClientEvent::ChatUpserted { chat_id } => {
                if let Some(work) = self.works.get(&chat_id.get())
                    && let Ok(state) = self.agent.bot.chat_state(*chat_id).await
                    && let Some(title) = state
                        .dialog
                        .filter(|dialog| {
                            dialog.peer_user_id.is_none() && dialog.parent_chat_id.is_some()
                        })
                        .and_then(|dialog| dialog.title)
                        .filter(|title| !title.trim().is_empty())
                {
                    let _ = work.tx.send(Command::Title(title)).await;
                }
                Ok(())
            }
            ClientEvent::AgentAccessChanged { chat_id, .. } => {
                self.access.invalidate().await;
                match chat_id {
                    Some(chat_id) => {
                        self.participation.remove(&chat_id.get());
                        self.refresh_mode(chat_id.get()).await;
                    }
                    None => self.participation.clear(),
                }
                Ok(())
            }
            ClientEvent::BotInteraction(BotInteractionEvent::FilesystemRequested {
                request_id,
                chat_id,
                actor_user_id,
                operation,
                path,
                after,
                agent_session_id,
                query,
                limit,
                ..
            }) => {
                let response = self
                    .list_files(
                        chat_id.get(),
                        actor_user_id.get(),
                        *operation,
                        *agent_session_id,
                        FileQuery {
                            path,
                            after,
                            query: query.as_deref(),
                            limit: *limit,
                        },
                    )
                    .await;
                self.agent
                    .bot
                    .answer_bot_filesystem(proto::AnswerBotFilesystemInput {
                        request_id: *request_id,
                        response: Some(response),
                    })
                    .await?;
                Ok(())
            }
            _ => Ok(()),
        }
    }

    /// The client stops receiving events after a failure it does not retry
    /// on its own. Resuming it restarts delivery where it stopped, so the
    /// agent never goes quiet without a trace.
    async fn keep_connected(&mut self) {
        let snapshot = self.agent.bot.status_snapshot();
        if snapshot.status != ClientStatus::Disconnected {
            self.reconnect = Reconnect::default();
            return;
        }
        // A failure that keeps coming back is retried less and less often.
        let now = tokio::time::Instant::now();
        if self.reconnect.next.is_some_and(|next| now < next) {
            return;
        }
        self.reconnect.delay =
            (self.reconnect.delay * 2).clamp(CONNECTION_CHECK, MAX_RECONNECT_DELAY);
        self.reconnect.next = Some(now + self.reconnect.delay);
        log::warn!(
            target: "inline::bridge::v2",
            "Inline connection lost ({}); resuming",
            snapshot
                .failure
                .as_ref()
                .map_or("no detail".to_owned(), |failure| format!(
                    "{:?}: {}",
                    failure.category, failure.message
                ))
        );
        if let Err(error) = self.agent.bot.resume_session().await {
            log::warn!(target: "inline::bridge::v2", "resuming the Inline connection failed: {error}");
        }
    }

    /// A work moved into a subthread: it is that chat's work from now on.
    fn moved_work(&mut self, from: i64, to: i64) {
        if let Some(work) = self.works.remove(&from) {
            self.works.insert(to, work);
        }
        for destination in self.moved.values_mut() {
            if *destination == from {
                *destination = to;
            }
        }
        self.moved.insert(from, to);
    }

    /// Asks a work actor and waits for its toast. Cards left in a chat the
    /// work moved out of still reach it.
    async fn ask(
        &self,
        chat_id: i64,
        command: impl FnOnce(oneshot::Sender<Option<String>>) -> Command,
    ) -> Option<String> {
        let work = self.works.get(&chat_id).or_else(|| {
            self.moved
                .get(&chat_id)
                .and_then(|destination| self.works.get(destination))
        });
        let Some(work) = work else {
            return Some("This request is no longer pending.".to_owned());
        };
        let (reply, answer) = oneshot::channel();
        if work.tx.send(command(reply)).await.is_err() {
            return Some("This work stopped. Mention the agent to start it again.".to_owned());
        }
        answer.await.unwrap_or(None)
    }

    async fn answer(&self, interaction_id: InlineId, toast: Option<String>) {
        if let Err(error) = self
            .agent
            .bot
            .answer_message_action(AnswerMessageActionRequest {
                interaction_id,
                toast,
            })
            .await
        {
            log::warn!(target: "inline::bridge::v2", "action answer failed: {error}");
        }
    }

    async fn reply(&self, chat_id: i64, message_id: i64, text: &str) {
        let mut builder = DocBuilder::new();
        builder.paragraph(text);
        match api::send_doc(
            &self.agent.bot,
            chat_id,
            Some(message_id),
            &builder.finish(),
            None,
            Notify::Normal,
        )
        .await
        {
            Ok(id) => {
                self.agent.sent.lock().expect("sent").insert(id);
            }
            Err(error) => log::warn!(target: "inline::bridge::v2", "reply failed: {error}"),
        }
    }

    async fn participation_of(
        &mut self,
        chat_id: i64,
    ) -> Result<Option<proto::AgentParticipation>, api::ApiError> {
        if let Some(cached) = self.participation.get(&chat_id) {
            return Ok(cached.clone());
        }
        let participation = api::participations(&self.agent.bot, chat_id)
            .await?
            .into_iter()
            .find(|participation| participation.bot_user_id == self.config.bot_user_id);
        self.participation.insert(chat_id, participation.clone());
        Ok(participation)
    }

    fn effective_mode(&self, participation: Option<&proto::AgentParticipation>) -> OutputMode {
        participation
            .and_then(|participation| participation.output_mode)
            .filter(|mode| *mode != proto::AgentOutputMode::Unspecified as i32)
            .map(output_mode)
            .unwrap_or(self.default_output_mode)
    }

    async fn refresh_mode(&mut self, chat_id: i64) {
        if !self.works.contains_key(&chat_id) {
            return;
        }
        let Ok(participation) = self.participation_of(chat_id).await else {
            return;
        };
        let mode = self.effective_mode(participation.as_ref());
        if let Some(work) = self.works.get(&chat_id) {
            let _ = work.tx.send(Command::SetMode(mode)).await;
        }
    }

    async fn on_message(
        &mut self,
        message: &MessageRecord,
    ) -> Result<(), Box<dyn std::error::Error>> {
        if message.is_outgoing
            || message.timestamp < self.config.accept_messages_after
            || message.metadata.agent_session.is_some()
        {
            return Ok(());
        }
        let chat_id = message.chat_id.get();
        let conversation = if chat_id == self.config.dm_chat_id {
            Conversation::Dm
        } else if self.works.contains_key(&chat_id) {
            Conversation::WorkThread
        } else {
            Conversation::Group
        };
        let reply_author = message.reply_to_message_id.map(|id| {
            if self.agent.sent.lock().expect("sent").contains(&id.get()) {
                self.config.bot_user_id
            } else {
                0
            }
        });
        let group = group_message(
            message,
            MessageFacts {
                bot_user_id: self.config.bot_user_id,
                bot_username: &self.config.bot_username,
                conversation,
                reply_author,
                author_name: self.agent.names.of(message.sender_id.get()).await,
            },
        );
        let grants = self.access.grants(group.author.user_id).await;
        let participation = match conversation {
            Conversation::Group => self.participation_of(chat_id).await?,
            _ => None,
        };
        let participation_mode = match conversation {
            // The DM and the agent's own threads always count as joined.
            Conversation::Dm | Conversation::WorkThread => Some(ParticipationMode::Active),
            Conversation::Group => participation.as_ref().and_then(|participation| {
                match proto::AgentParticipationMode::try_from(participation.mode) {
                    Ok(proto::AgentParticipationMode::Active) => Some(ParticipationMode::Active),
                    Ok(proto::AgentParticipationMode::MentionsOnly) => {
                        Some(ParticipationMode::MentionsOnly)
                    }
                    Ok(proto::AgentParticipationMode::Muted) => Some(ParticipationMode::Muted),
                    _ => None,
                }
            }),
        };
        let work = self
            .works
            .get(&chat_id)
            .map_or(WorkPhase::None, |work| *work.phase.borrow());
        let loop_verdict = self
            .loop_guards
            .record(chat_id, group.author.kind.is_agent());
        let decision = decide_intake(IntakeFacts {
            message: &group,
            bot_user_id: self.config.bot_user_id,
            grants,
            work,
            participation: participation_mode,
            loop_verdict,
        });
        match decision {
            IntakeDecision::Act { join, required, .. } => {
                if join
                    && conversation == Conversation::Group
                    && let Err(error) =
                        api::join(&self.agent.bot, chat_id, self.config.bot_user_id).await
                {
                    log::warn!(target: "inline::bridge::v2", "join failed: {error}");
                }
                self.act(message, &group, &decision, required, grants, participation)
                    .await
            }
            IntakeDecision::Observe { consider, .. } => {
                if let Some(work) = self.works.get(&chat_id) {
                    // Batched in the work and delivered at its next native
                    // boundary (spec §5.1).
                    let role = if group.author.user_id == self.config.owner_user_id {
                        ContextAuthorRole::Owner
                    } else if group.author.kind.is_agent() {
                        ContextAuthorRole::Agent
                    } else {
                        ContextAuthorRole::Teammate
                    };
                    let _ = work
                        .tx
                        .send(Command::Passive {
                            message: ContextMessage {
                                message_id: group.message_id,
                                author_name: group.author.display_name.clone(),
                                role,
                                reply_to: message.reply_to_message_id.map(InlineId::get),
                                text: group.text.clone(),
                            },
                        })
                        .await;
                    if consider {
                        let _ = work
                            .tx
                            .send(Command::Consider {
                                message_id: group.message_id,
                                line: format!("{}: {}", group.author.display_name, group.text),
                            })
                            .await;
                    }
                }
                Ok(())
            }
            IntakeDecision::Skip { .. } => Ok(()),
        }
    }

    async fn act(
        &mut self,
        message: &MessageRecord,
        group: &GroupMessage,
        decision: &IntakeDecision,
        required: Operation,
        grants: Grants,
        participation: Option<proto::AgentParticipation>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let chat_id = group.chat_id;
        let control = match group.command().map(|(name, _)| name) {
            Some("new") => return self.new_thread(group, grants, participation).await,
            Some("stop") => Some(Control::Stop),
            Some("pause") => Some(Control::Pause),
            Some("resume") => Some(Control::Resume),
            Some("release") => Some(Control::Release(ReleaseCause::Command)),
            Some("terminal") => Some(Control::Release(ReleaseCause::ContinueInTerminal)),
            _ => None,
        };
        if let Some(control) = control {
            let toast = if self.works.contains_key(&chat_id) {
                self.ask(chat_id, |reply| Command::Control {
                    control,
                    actor: group.author.user_id,
                    reply,
                })
                .await
            } else {
                Some("Nothing is running in this thread.".to_owned())
            };
            if let Some(toast) = toast {
                self.reply(chat_id, group.message_id, &toast).await;
            }
            return Ok(());
        }
        let id = input_id(self.config.bot_user_id, chat_id, group.message_id, "direct");
        // Joining a group thread: the recent conversation comes along as
        // untrusted context (spec §5.3).
        let context =
            if group.conversation == Conversation::Group && !self.works.contains_key(&chat_id) {
                self.join_context(group).await
            } else {
                None
            };
        let Some(mut input) = direct_input(
            decision,
            group,
            self.config.owner_user_id,
            InputId::new(id.clone())?,
            None,
            context,
        ) else {
            // A command this agent does not handle.
            return Ok(());
        };
        // Media reaches the harness as local files, like v1.
        if let Some(content) = crate::bridge::runtime::normalize_inbound_content(
            &message.content,
            &message.metadata.entities,
            self.config.bot_user_id,
        ) {
            if !content.attachments.is_empty() {
                input.content.attachments =
                    crate::bridge::runtime::materialize_inbound_attachments(
                        &content.attachments,
                        &self.config.attachments_dir,
                    )
                    .await;
            }
            if input.content.text.trim().is_empty() {
                input.content.text = content.text;
            }
        }
        match self
            .agent
            .ledger
            .begin(&id, chat_id, group.message_id, group.author.user_id)?
        {
            Begin::Seen(_) => return Ok(()),
            Begin::New { .. } => {}
        }
        if let Err(error) = self.ensure_work(chat_id, participation.as_ref()).await {
            self.agent.ledger.set(&id, InputState::Failed)?;
            return Err(error);
        }
        let pending = PendingInput {
            id: input.id.clone(),
            sender: UserId(group.author.user_id),
            required,
        };
        let work = self.works.get(&chat_id).expect("work");
        if work
            .tx
            .send(Command::Input {
                input: Box::new(input),
                pending,
                message_id: group.message_id,
            })
            .await
            .is_err()
        {
            self.works.remove(&chat_id);
            self.agent.ledger.set(&id, InputState::Failed)?;
            return Err("the work stopped; send the message again".into());
        }
        Ok(())
    }

    /// Recent messages of a group thread, as untrusted context for an agent
    /// joining it. Best effort: without history the agent still gets the
    /// message itself.
    async fn join_context(&self, group: &GroupMessage) -> Option<inline_agent_bridge::TurnContext> {
        use inline_agent_bridge::group::{
            ContextAuthorRole, ContextBudget, ContextMessage, JoinContext, JoinContextInput,
        };
        let page = self
            .agent
            .bot
            .history(inline_client::HistoryRequest {
                chat_id: InlineId::new(group.chat_id),
                limit: Some(JOIN_CONTEXT_MESSAGES),
                before_message_id: Some(InlineId::new(group.message_id)),
                after_message_id: None,
            })
            .await
            .ok()?;
        let mut names: HashMap<i64, String> = HashMap::new();
        for user in &page.users {
            let id = user.user_id.get();
            let name = user
                .display_name
                .clone()
                .or_else(|| user.first_name.clone())
                .or_else(|| user.username.clone());
            if let Some(name) = name {
                self.agent.names.remember(id, name.clone()).await;
                names.insert(id, name);
            }
        }
        let mut recent: Vec<ContextMessage> = page
            .messages
            .iter()
            .filter(|message| message.message_id.get() != group.message_id)
            .map(|message| {
                let sender = message.sender_id.get();
                ContextMessage {
                    message_id: message.message_id.get(),
                    author_name: names
                        .get(&sender)
                        .cloned()
                        .unwrap_or_else(|| format!("user {sender}")),
                    role: if sender == self.config.bot_user_id {
                        ContextAuthorRole::Me
                    } else if sender == self.config.owner_user_id {
                        ContextAuthorRole::Owner
                    } else if message.metadata.sender_is_bot.unwrap_or(false) {
                        ContextAuthorRole::Agent
                    } else {
                        ContextAuthorRole::Teammate
                    },
                    reply_to: message.reply_to_message_id.map(InlineId::get),
                    text: super::intake::message_text(&message.content).to_owned(),
                }
            })
            .collect();
        recent.sort_by_key(|message| message.message_id);
        if recent.is_empty() {
            return None;
        }
        let context = JoinContext::build(
            &JoinContextInput {
                chat_id: group.chat_id,
                title: None,
                participants: Vec::new(),
                recent,
                earlier_unfetched: (!page.has_more).then_some(0),
                reply_chain: Vec::new(),
                linked: Vec::new(),
                trigger_message_id: group.message_id,
            },
            ContextBudget::bytes(JOIN_CONTEXT_BYTES),
        );
        Some(inline_agent_bridge::TurnContext {
            instructions: String::new(),
            conversation: context.text,
        })
    }

    /// Spawns the work actor for a thread, resuming the session the server
    /// knows. A failed lookup never starts a new session.
    async fn ensure_work(
        &mut self,
        chat_id: i64,
        participation: Option<&proto::AgentParticipation>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        if let Some(work) = self.works.get(&chat_id)
            && !work.task.is_finished()
        {
            return Ok(());
        }
        let result = self
            .agent
            .owner
            .lookup(proto::GetAgentSessionInput {
                peer_id: Some(chat_peer(chat_id)),
                bot_user_id: self.config.bot_user_id,
                ..Default::default()
            })
            .await
            .map_err(|error| format!("could not look up this thread's work: {error}"))?;
        let known = match result.connection {
            Some(connection) if !connection.session_ref.is_empty() => Known {
                agent_session_id: connection.agent_session.map(|session| session.id),
                native: Some(ProviderSessionId::new(connection.session_ref)?),
            },
            _ => Known::default(),
        };
        let mode = self.effective_mode(participation);
        // A new work here takes the chat back from one that moved out.
        self.moved.remove(&chat_id);
        self.works.insert(
            chat_id,
            super::work::spawn(self.agent.clone(), chat_id, known, mode),
        );
        Ok(())
    }

    /// `/new`: a new Inline thread under this chat with a fresh native session.
    async fn new_thread(
        &mut self,
        group: &GroupMessage,
        grants: Grants,
        participation: Option<proto::AgentParticipation>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        if !grants.permits(Operation::StartWork) {
            return Ok(());
        }
        let created = self
            .agent
            .bot
            .create_reply_thread(CreateReplyThreadRequest {
                parent_chat_id: InlineId::new(group.chat_id),
                parent_message_id: Some(InlineId::new(group.message_id)),
                title: None,
                description: None,
                emoji: None,
                participants: Vec::new(),
                agent_context: None,
            })
            .await?;
        let chat_id = created.chat_id.get();
        let mode = self.effective_mode(participation.as_ref());
        self.works.insert(
            chat_id,
            super::work::spawn(self.agent.clone(), chat_id, Known::default(), mode),
        );
        let task = group
            .text
            .trim_start()
            .trim_start_matches('/')
            .split_once(char::is_whitespace)
            .map(|(_, rest)| rest.trim().to_owned())
            .unwrap_or_default();
        if task.is_empty() {
            return Ok(());
        }
        let id = input_id(
            self.config.bot_user_id,
            group.chat_id,
            group.message_id,
            "new",
        );
        if let Begin::Seen(_) =
            self.agent
                .ledger
                .begin(&id, chat_id, group.message_id, group.author.user_id)?
        {
            return Ok(());
        }
        let input = Input {
            id: InputId::new(id)?,
            content: InputContent::text(task),
            origin: origin_of(group, self.config.owner_user_id),
            delivery: Delivery::Turn,
        };
        let pending = PendingInput {
            id: input.id.clone(),
            sender: UserId(group.author.user_id),
            required: Operation::StartWork,
        };
        if let Some(work) = self.works.get(&chat_id) {
            let _ = work
                .tx
                .send(Command::Input {
                    input: Box::new(input),
                    pending,
                    message_id: group.message_id,
                })
                .await;
        }
        Ok(())
    }

    async fn list_files(
        &mut self,
        chat_id: i64,
        actor: i64,
        operation: i32,
        agent_session_id: Option<i64>,
        query: FileQuery<'_>,
    ) -> proto::BotFilesystemResponse {
        use proto::bot_filesystem_response::Result as Reply;
        let problem = |message: &str| proto::BotFilesystemResponse {
            result: Some(Reply::Problem(message.to_owned())),
        };
        if operation != 3 {
            return problem("Browsing this machine is not available for this agent yet.");
        }
        if !self
            .access
            .grants(actor)
            .await
            .permits(Operation::StartWork)
        {
            return problem("You don't have access to this agent's files.");
        }
        let known = self
            .works
            .iter()
            .any(|(chat, work)| match agent_session_id {
                Some(id) => work.agent_session_id() == Some(id),
                None => *chat == chat_id,
            });
        if !known {
            return problem("This work is not open on this machine.");
        }
        let folder = self.config.folder.clone();
        let path = query.path.to_owned();
        let after = query.after.to_owned();
        let text = query.query.map(str::to_owned);
        let limit = query.limit.unwrap_or(50).clamp(1, 200) as usize;
        match tokio::task::spawn_blocking(move || {
            crate::bridge::filesystem::work_files_listing(
                &folder,
                &path,
                text.as_deref(),
                &after,
                limit,
            )
        })
        .await
        {
            Ok(Ok(listing)) => proto::BotFilesystemResponse {
                result: Some(Reply::Listing(listing)),
            },
            Ok(Err(message)) => problem(message),
            Err(_) => problem("Listing the files failed."),
        }
    }
}

struct FileQuery<'a> {
    path: &'a str,
    after: &'a str,
    query: Option<&'a str>,
    limit: Option<u32>,
}

fn output_mode(mode: i32) -> OutputMode {
    match proto::AgentOutputMode::try_from(mode) {
        Ok(proto::AgentOutputMode::Friendly) => OutputMode::Friendly,
        _ => OutputMode::Detailed,
    }
}
