//! The bridge v2 runtime: one native session per (thread, agent) on the
//! session contract, rendered into Inline with blocks (spec §4–§7).
//!
//! This loop owns intake: it decides what each Inline message is for,
//! records direct input in the ledger before acknowledging the delivery, and
//! hands it to the thread's work actor (`work.rs`).

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use inline_agent_bridge::ProviderSessionId;
use inline_agent_bridge::group::{
    ContextAuthorRole, ContextMessage, Conversation, DEFAULT_DAILY_SPEAK_GATE_BUDGET,
    DEFAULT_LOOP_CAP_HOPS, DailySpeakGateBudget, DayKey, DirectReason, Grants, GroupMessage,
    IntakeDecision, IntakeFacts, LoopGuards, LoopVerdict, ObserveReason, Operation,
    ParticipationMode, PendingInput, ReleaseCause, WorkPhase, decide_intake, direct_input,
    origin_of, required_operation,
};
use inline_agent_bridge::harness::{
    Catalog, CatalogScope, Delivery, HarnessDriver, Input, InputContent, InputId, OutputMode,
    RuntimeHealth, SettingsChange, SetupReason, UserId,
};
use inline_client::{
    AnswerBotChatSettingsRequest, AnswerMessageActionRequest, BotCapability,
    BotChatSettingsDocument, BotChatSettingsProblemCode, BotChatSettingsResponse,
    BotInteractionEvent, BotSettingsValue, ClientEvent, ClientStatus, CreateReplyThreadRequest,
    InlineClient, InlineId, LosslessEventReceiver, MessageRecord,
};
use inline_protocol::proto;
use tokio::sync::{mpsc, oneshot};

use super::api::{self, Notify, chat_peer};
use super::doc::DocBuilder;
use super::folders::{FolderSource, Folders};
use super::intake::{MessageFacts, grants_by_user, group_message};
use super::ledger::{Begin, InputState, Ledger, input_id};
use super::render::{ActionStyle, QUESTION_FORM_ID, Vocabulary};
use super::settings;
use super::tools::Tools;
use super::work::{
    AccessSource, ActionData, Agent, Command, Control, Known, OwnerCalls, SessionOp, WorkHandle,
    button_rows, paragraph,
};

const DEFAULT_HEARTBEAT: Duration = Duration::from_secs(60);
/// How long the harness's pickers are reused.
const CATALOG_TTL: Duration = Duration::from_secs(60);
/// How long heartbeats reuse the harness's listing before asking again.
const CAPABILITIES_REFRESH: Duration = Duration::from_secs(600);
const NO_ACCESS: &str = "You don't have access to do that with this agent.";
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
/// Parents followed to find a subthread tree's root.
const LOOP_SCOPE_DEPTH: usize = 8;
/// Ancestors of the trigger's reply chain read into the join context.
const JOIN_REPLY_CHAIN: usize = 5;
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

    fn set_commands(
        &self,
        input: proto::SetBotCommandsInput,
    ) -> futures_util::future::BoxFuture<'_, Result<(), String>> {
        Box::pin(async move {
            self.0
                .set_bot_commands(input)
                .await
                .map_err(|error| error.to_string())
        })
    }
}

pub(crate) struct Runtime {
    config: V2Config,
    /// Keep v1's durable receipts authoritative after opting in.
    legacy_store: Option<Arc<inline_agent_bridge::BridgeStore>>,
    agent: Arc<Agent>,
    access: Arc<Access>,
    works: HashMap<i64, WorkHandle>,
    /// A chat a work moved out of → where it went, so cards left behind still
    /// reach it. Messages there never do: the parent may start its own work.
    moved: HashMap<i64, i64>,
    moves: Option<mpsc::UnboundedReceiver<(i64, i64)>>,
    /// Chat → whether this agent created it, so it is the agent's own thread.
    own_threads: HashMap<i64, bool>,
    /// This bot's own follow mode per thread (`Some(true)` following,
    /// `Some(false)` unfollowed), read from its dialog. Inline sets it by the
    /// shared opener rule; an unknown answer is read again after a while.
    follows: HashMap<i64, (Option<bool>, std::time::Instant)>,
    /// Chat → its model, reasoning, permissions and folder (settings and
    /// commands).
    thread_settings: HashMap<i64, SettingsChange>,
    /// Bound chat → the model and reasoning its composer chain last set, so
    /// only a change there overrides a pick made in settings since.
    bound_configs: HashMap<i64, (Option<String>, Option<String>)>,
    /// Bound chat → the project its composer chain last set.
    bound_projects: HashMap<i64, String>,
    /// Chat → whether Inline knows a session for its work, for threads with
    /// no work running here yet. A session keeps its folder.
    known_sessions: HashMap<i64, bool>,
    /// The harness's pickers, refreshed now and then.
    catalog: Option<(tokio::time::Instant, Catalog)>,
    /// The folders registered with the bridge, which threads pick from with
    /// the agent's own and the harness's.
    folder_source: Option<FolderSource>,
    reconnect: Reconnect,
    /// The harness health the last heartbeat reported.
    reported_health: Option<RuntimeHealth>,
    /// What the apps were last told, republished when the catalog changes.
    published: Option<Vec<BotCapability>>,
    /// The command list last registered in Inline's command menu.
    published_commands: Option<Vec<proto::BotCommand>>,
    participation: HashMap<i64, Option<proto::AgentParticipation>>,
    default_output_mode: OutputMode,
    loop_guards: LoopGuards,
    /// Chat → the root of its subthread tree, the loop cap's scope.
    loop_roots: HashMap<i64, i64>,
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
        // Each thread's settings, as a previous run left them.
        let mut thread_settings = HashMap::new();
        let mut bound_configs = HashMap::new();
        let moved = ledger.moves()?.into_iter().collect();
        for (chat_id, saved, bound) in ledger.threads()? {
            if let Ok(saved) = serde_json::from_str::<SettingsChange>(&saved) {
                thread_settings.insert(chat_id, saved);
            }
            if let Some(Ok(bound)) = bound.map(|bound| serde_json::from_str(&bound)) {
                bound_configs.insert(chat_id, bound);
            }
        }
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
            dm_chat_id: config.dm_chat_id,
            gate_budget: std::sync::Mutex::new(DailySpeakGateBudget::default()),
            usage: std::sync::Mutex::new(Vec::new()),
            context: std::sync::Mutex::new(HashMap::new()),
            bound_projects: std::sync::Mutex::new(HashMap::new()),
        });
        Ok(Self {
            config,
            legacy_store: None,
            agent,
            access,
            works: HashMap::new(),
            moved,
            moves: Some(moves),
            own_threads: HashMap::new(),
            follows: HashMap::new(),
            thread_settings,
            bound_configs,
            bound_projects: HashMap::new(),
            known_sessions: HashMap::new(),
            catalog: None,
            folder_source: None,
            reconnect: Reconnect::default(),
            reported_health: None,
            published: None,
            published_commands: None,
            participation: HashMap::new(),
            default_output_mode: OutputMode::Detailed,
            loop_guards: LoopGuards::default(),
            loop_roots: HashMap::new(),
        })
    }

    pub(crate) fn with_legacy_store(
        mut self,
        store: Arc<inline_agent_bridge::BridgeStore>,
    ) -> Self {
        self.legacy_store = Some(store);
        self
    }

    /// Lets threads pick their folder, among these and the harness's.
    pub(crate) fn with_folders(mut self, source: FolderSource) -> Self {
        self.folder_source = Some(source);
        self
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
        self.publish_capabilities().await;
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
                _ = connection.tick() => {
                    self.keep_connected().await;
                    // A harness that needs setup shows in the apps right away.
                    if self.reported_health.as_ref() != Some(&self.agent.harness.describe().health) {
                        self.heartbeat().await;
                    }
                }
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
        self.report_status(proto::AgentRuntimeStatus::Offline, None)
            .await;
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
        // Written but unconfirmed: the thread's session settles them when it
        // opens, by what it shows it already consumed.
        let mut uncertain: HashMap<i64, Vec<(InputId, i64, i64)>> = HashMap::new();
        for record in unresolved {
            if matches!(record.state, InputState::Unknown | InputState::Sent)
                && let Ok(input) = InputId::new(record.input_id.clone())
            {
                uncertain
                    .entry(
                        self.agent
                            .ledger
                            .input_work(&record.input_id, record.chat_id)
                            .unwrap_or(record.chat_id),
                    )
                    .or_default()
                    .push((input, record.chat_id, record.message_id));
                continue;
            }
            // Never written: it never ran.
            self.reply(
                record.chat_id,
                record.message_id,
                &format!(
                    "{} restarted before this ran. Reply again if it still needs doing.",
                    self.config.agent_name
                ),
            )
            .await;
            let _ = self.agent.ledger.set(&record.input_id, InputState::Failed);
        }
        for (chat_id, inputs) in uncertain {
            let opened = self
                .ensure_work(chat_id, None)
                .await
                .map_err(|error| error.to_string());
            if let Err(error) = opened {
                log::warn!(target: "inline::bridge::v2", "chat={chat_id} cannot settle inputs: {error}");
                for (input, request_chat_id, message_id) in inputs {
                    self.reply(
                        request_chat_id,
                        message_id,
                        &format!(
                            "{} restarted while this was being delivered and could not check whether it arrived. Check its native session before retrying.",
                            self.config.agent_name
                        ),
                    )
                    .await;
                    let _ = self.agent.ledger.set(input.as_str(), InputState::Unknown);
                }
                continue;
            }
            if let Some(work) = self.works.get(&chat_id) {
                let _ = work.tx.send(Command::Reconcile { inputs }).await;
            }
        }
        // Consumed inputs can still have an unpublished final or interaction.
        // Restore those works too; no input is resent.
        match self.agent.ledger.output_chats() {
            Ok(chats) => {
                for chat_id in chats {
                    if self.works.contains_key(&chat_id) {
                        continue;
                    }
                    if self.ensure_work(chat_id, None).await.is_ok()
                        && let Some(work) = self.works.get(&chat_id)
                    {
                        let _ = work
                            .tx
                            .send(Command::Reconcile { inputs: Vec::new() })
                            .await;
                    }
                }
            }
            Err(error) => {
                log::warn!(target: "inline::bridge::v2", "cannot recover pending publication: {error}")
            }
        }
        let _ = self.agent.ledger.prune(LEDGER_RETENTION_SECS);
    }

    /// Agent Settings, the composer chain and the empty-page Compose read
    /// these. A harness that cannot list its models yet keeps what an earlier
    /// run published, and is asked again with the next heartbeat. Later
    /// heartbeats reuse the last listing (listing can start a harness
    /// process) for up to ten minutes, so the harness's own folders, such as
    /// Codex projects, still reach the apps.
    async fn publish_capabilities(&mut self) {
        let catalog = match &self.catalog {
            Some((at, catalog)) if at.elapsed() < CAPABILITIES_REFRESH => catalog.clone(),
            Some(_) => self.catalog().await,
            None => {
                let catalog = self.catalog().await;
                if self.catalog.is_none() {
                    return;
                }
                catalog
            }
        };
        let folders = self
            .folders(&catalog)
            .and_then(|folders| folders.catalog(&self.config.machine_label));
        let commands = command_catalog(self.config.vocabulary, &catalog);
        if self.published_commands.as_ref() != Some(&commands) {
            match self
                .agent
                .owner
                .set_commands(proto::SetBotCommandsInput {
                    bot_user_id: self.config.bot_user_id,
                    commands: commands.clone(),
                })
                .await
            {
                Ok(()) => self.published_commands = Some(commands),
                Err(error) => {
                    log::warn!(target: "inline::bridge::v2", "commands not registered: {error}");
                }
            }
        }
        let capabilities = settings::capabilities(&catalog, folders);
        if self.published.as_ref() == Some(&capabilities) {
            return;
        }
        match self
            .agent
            .bot
            .set_bot_capabilities(capabilities.clone())
            .await
        {
            Ok(_) => self.published = Some(capabilities),
            Err(error) => {
                log::warn!(target: "inline::bridge::v2", "settings capabilities not published: {error}");
            }
        }
    }

    async fn heartbeat(&mut self) -> Duration {
        self.publish_capabilities().await;
        let health = self.agent.harness.describe().health;
        let (status, setup) = runtime_status(&health, &self.config.agent_name);
        let reported = self.report_status(status, setup).await;
        if reported.is_some() {
            self.reported_health = Some(health);
        }
        match reported {
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
        setup: Option<proto::AgentRuntimeSetup>,
    ) -> Option<proto::ReportAgentRuntimeResult> {
        let info = self.agent.harness.describe();
        api::report_runtime(
            &self.agent.bot,
            proto::ReportAgentRuntimeInput {
                provider: self.config.provider() as i32,
                status: status as i32,
                setup,
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
                    Ok(ActionData::ExtendLoop) => {
                        self.extend_loop(chat_id.get(), message_id.get(), actor_user_id.get())
                            .await
                    }
                    Ok(ActionData::RaiseGateBudget) => {
                        self.raise_gate_budget(chat_id.get(), message_id.get(), actor_user_id.get())
                            .await
                    }
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
                let chat_id = chat_id.get();
                if !self.works.contains_key(&chat_id) {
                    // Read again with the next message, binding included.
                    self.own_threads.remove(&chat_id);
                    return Ok(());
                }
                let Ok(state) = self.agent.bot.chat_state(InlineId::new(chat_id)).await else {
                    return Ok(());
                };
                let Some(dialog) = state.dialog else {
                    return Ok(());
                };
                // The composer chain of a thread bound to this agent keeps
                // its project, model and reasoning on the thread.
                if let Some((project, model, effort)) = dialog
                    .agent_context
                    .as_ref()
                    .filter(|context| context.bot_user_id.get() == self.config.bot_user_id)
                    .map(|context| {
                        context
                            .configuration
                            .clone()
                            .map(|configuration| {
                                (
                                    configuration.project_id,
                                    configuration.model_id,
                                    configuration.reasoning_effort_id,
                                )
                            })
                            .unwrap_or_default()
                    })
                {
                    self.bound_settings(chat_id, model, effort).await;
                    self.bound_project(chat_id, project).await;
                }
                if dialog.peer_user_id.is_none()
                    && dialog.parent_chat_id.is_some()
                    && let Some(title) = dialog.title.filter(|title| !title.trim().is_empty())
                    && let Some(work) = self.works.get(&chat_id)
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
            ClientEvent::BotInteraction(BotInteractionEvent::ChatSettingsRequested {
                request_id,
                chat_id,
                actor_user_id,
                version,
            }) => {
                let response = self
                    .chat_settings(chat_id.get(), actor_user_id.get(), *version, None)
                    .await;
                self.answer_settings(*request_id, response).await;
                Ok(())
            }
            ClientEvent::BotInteraction(BotInteractionEvent::ChatSettingsItemInvoked {
                request_id,
                chat_id,
                actor_user_id,
                version,
                item_id,
                value,
                document_revision,
            }) => {
                let response = self
                    .chat_settings(
                        chat_id.get(),
                        actor_user_id.get(),
                        *version,
                        Some((item_id, value.as_ref(), document_revision)),
                    )
                    .await;
                self.answer_settings(*request_id, response).await;
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

    /// Whether this agent created the chat (cached; a failed lookup is not).
    /// This bot's follow mode in `chat_id`; `None` when it has made no choice.
    async fn following(&mut self, chat_id: i64) -> Option<bool> {
        const RECHECK: std::time::Duration = std::time::Duration::from_secs(30);
        // A choice the agent or /follow made in this run is the newest.
        if let Some(choice) = self
            .agent
            .tools
            .as_ref()
            .and_then(|tools| tools.follow_choice(chat_id))
        {
            return Some(choice);
        }
        if let Some((mode, read)) = self.follows.get(&chat_id)
            && (mode.is_some() || read.elapsed() < RECHECK)
        {
            return *mode;
        }
        let mode = match api::get_chat(&self.agent.bot, chat_id).await {
            Ok(result) => {
                result.dialog.and_then(|dialog| {
                    match proto::DialogFollowMode::try_from(dialog.follow_mode?) {
                        Ok(proto::DialogFollowMode::Following) => Some(true),
                        Ok(proto::DialogFollowMode::Unfollowed) => Some(false),
                        _ => None,
                    }
                })
            }
            Err(error) => {
                log::warn!(target: "inline::bridge::v2", "chat={chat_id} follow lookup failed: {error}");
                None
            }
        };
        self.follows
            .insert(chat_id, (mode, std::time::Instant::now()));
        mode
    }

    async fn set_following(&mut self, chat_id: i64, follow: bool) -> Result<(), String> {
        let mode = if follow {
            inline_client::DialogFollowMode::Following
        } else {
            inline_client::DialogFollowMode::Unfollowed
        };
        self.agent
            .bot
            .update_dialog_follow_mode(inline_client::UpdateDialogFollowModeRequest {
                chat_id: InlineId::new(chat_id),
                mode,
            })
            .await
            .map_err(|error| error.to_string())?;
        self.follows
            .insert(chat_id, (Some(follow), std::time::Instant::now()));
        if let Some(tools) = &self.agent.tools {
            tools.record_follow(chat_id, follow);
        }
        Ok(())
    }

    async fn is_own_thread(&mut self, chat_id: i64) -> bool {
        if let Some(own) = self.own_threads.get(&chat_id) {
            return *own;
        }
        match api::get_chat(&self.agent.bot, chat_id).await {
            Ok(result) => {
                // Made by this agent's bot, or bound to it (an agent thread
                // its owner started in the app).
                let bound = result
                    .chat
                    .as_ref()
                    .and_then(|chat| chat.agent_context.as_ref())
                    .filter(|context| context.bot_user_id == self.config.bot_user_id)
                    .map(|context| context.configuration.clone().unwrap_or_default());
                let own = bound.is_some()
                    || result
                        .chat
                        .as_ref()
                        .is_some_and(|chat| chat.created_by == Some(self.config.bot_user_id));
                if let Some(configuration) = bound {
                    self.bound_settings(
                        chat_id,
                        configuration.model_id,
                        configuration.reasoning_effort_id,
                    )
                    .await;
                    self.bound_project(chat_id, configuration.project_id).await;
                }
                self.own_threads.insert(chat_id, own);
                own
            }
            Err(error) => {
                log::debug!(target: "inline::bridge::v2", "chat={chat_id} lookup failed: {error}");
                false
            }
        }
    }

    /// The loop cap counts a whole subthread tree, so agents handing work
    /// to each other through subthreads share one count (spec §5.1 rule 6).
    async fn loop_scope(&mut self, chat_id: i64) -> i64 {
        if let Some(root) = self.loop_roots.get(&chat_id) {
            return *root;
        }
        let mut root = chat_id;
        for _ in 0..LOOP_SCOPE_DEPTH {
            let parent = self
                .agent
                .bot
                .chat_state(InlineId::new(root))
                .await
                .ok()
                .and_then(|state| state.dialog)
                .and_then(|dialog| dialog.parent_chat_id);
            match parent {
                Some(parent) => root = parent.get(),
                None => break,
            }
        }
        self.loop_roots.insert(chat_id, root);
        root
    }

    /// Agents went back and forth here without a person: this agent stops
    /// answering other agents and says so, with one tap to allow more.
    async fn loop_cap_reached(&self, chat_id: i64, limit: u32) {
        let text = format!(
            "{} stopped answering other agents here after {limit} agent messages in a row. A message from a person resets this.",
            self.config.agent_name
        );
        let actions = button_rows(&[("Allow more", ActionData::ExtendLoop, ActionStyle::Default)]);
        if let Err(error) = api::send_doc(
            &self.agent.bot,
            chat_id,
            None,
            &paragraph(&text),
            actions,
            Notify::Normal,
        )
        .await
        {
            log::warn!(target: "inline::bridge::v2", "loop cap notice failed: {error}");
        }
    }

    async fn extend_loop(&mut self, chat_id: i64, message_id: i64, actor: i64) -> Option<String> {
        if !self
            .access
            .grants(actor)
            .await
            .permits(Operation::Configure)
        {
            return Some(NO_ACCESS.to_owned());
        }
        let scope = self.loop_scope(chat_id).await;
        self.loop_guards.extend(scope, DEFAULT_LOOP_CAP_HOPS);
        let text = format!(
            "{} answers other agents here again, for {DEFAULT_LOOP_CAP_HOPS} more agent messages.",
            self.config.agent_name
        );
        let _ = api::edit_doc(
            &self.agent.bot,
            chat_id,
            message_id,
            &paragraph(&text),
            Some(proto::MessageActions::default()),
        )
        .await;
        Some(format!("Allowed {DEFAULT_LOOP_CAP_HOPS} more."))
    }

    async fn raise_gate_budget(
        &mut self,
        chat_id: i64,
        message_id: i64,
        actor: i64,
    ) -> Option<String> {
        if !self
            .access
            .grants(actor)
            .await
            .permits(Operation::Configure)
        {
            return Some(NO_ACCESS.to_owned());
        }
        let today = DayKey::from_unix(chrono::Utc::now().timestamp(), 0);
        self.agent
            .gate_budget
            .lock()
            .expect("gate budget")
            .raise_today(today, DEFAULT_DAILY_SPEAK_GATE_BUDGET);
        let text = format!(
            "{} weighs unaddressed messages again today, for {DEFAULT_DAILY_SPEAK_GATE_BUDGET} more checks.",
            self.config.agent_name
        );
        let _ = api::edit_doc(
            &self.agent.bot,
            chat_id,
            message_id,
            &paragraph(&text),
            Some(proto::MessageActions::default()),
        )
        .await;
        Some("Allowed more for today.".to_owned())
    }

    /// Saves a thread's settings so they survive a restart.
    fn save_thread(&self, chat_id: i64) {
        let settings = self
            .thread_settings
            .get(&chat_id)
            .cloned()
            .unwrap_or_default();
        let bound = self
            .bound_configs
            .get(&chat_id)
            .and_then(|bound| serde_json::to_string(bound).ok());
        let saved = serde_json::to_string(&settings)
            .map_err(|error| error.to_string())
            .and_then(|settings| {
                self.agent
                    .ledger
                    .save_thread(chat_id, &settings, bound.as_deref())
                    .map_err(|error| error.to_string())
            });
        if let Err(error) = saved {
            log::warn!(target: "inline::bridge::v2", "thread settings not saved: {error}");
        }
    }

    /// A bound thread's model and reasoning, as its composer chain set them.
    /// Absent means the harness's default.
    async fn bound_settings(
        &mut self,
        chat_id: i64,
        model: Option<String>,
        effort: Option<String>,
    ) {
        let seen = (model.clone(), effort.clone());
        if self.bound_configs.get(&chat_id) == Some(&seen) {
            return;
        }
        self.bound_configs.insert(chat_id, seen);
        let catalog = self.catalog().await;
        let change = settings::bound(model, effort, &catalog);
        let current = self
            .thread_settings
            .get(&chat_id)
            .cloned()
            .unwrap_or_default();
        let mut next = current.clone();
        settings::merge(&mut next, &change);
        if next == current {
            self.save_thread(chat_id);
            return;
        }
        self.thread_settings.insert(chat_id, next);
        self.save_thread(chat_id);
        if self.works.contains_key(&chat_id) {
            let _ = self
                .ask(chat_id, |reply| Command::Session {
                    op: SessionOp::Settings(change),
                    reply,
                })
                .await;
        }
    }

    /// The harness's pickers, kept for a minute.
    async fn catalog(&mut self) -> Catalog {
        if let Some((at, catalog)) = &self.catalog
            && at.elapsed() < CATALOG_TTL
        {
            return catalog.clone();
        }
        match self
            .agent
            .harness
            .catalog(CatalogScope {
                folder: Some(self.config.folder.clone()),
                session: None,
            })
            .await
        {
            Ok(catalog) => {
                self.catalog = Some((tokio::time::Instant::now(), catalog.clone()));
                catalog
            }
            Err(error) => {
                log::warn!(target: "inline::bridge::v2", "catalog unavailable: {error}");
                self.catalog
                    .as_ref()
                    .map(|(_, catalog)| catalog.clone())
                    .unwrap_or_default()
            }
        }
    }

    /// The folders threads pick from: the agent's own, the harness's in
    /// `catalog`, and the ones registered with the bridge.
    fn folders(&self, catalog: &Catalog) -> Option<Folders> {
        self.folder_source
            .as_ref()?
            .read(&self.config.folder, &catalog.folders)
            .map_err(
                |error| log::warn!(target: "inline::bridge::v2", "folders unavailable: {error}"),
            )
            .ok()
    }

    /// Where this thread's work runs: its pick, else the agent's folder.
    fn thread_folder(&self, chat_id: i64) -> PathBuf {
        self.thread_settings
            .get(&chat_id)
            .and_then(|settings| settings.folder.clone())
            .unwrap_or_else(|| self.config.folder.clone())
    }

    /// Whether Inline knows a session for this thread's work, asked once
    /// per thread until a work runs here.
    async fn session_known(&mut self, chat_id: i64) -> Result<bool, String> {
        if let Some(known) = self.known_sessions.get(&chat_id) {
            return Ok(*known);
        }
        let result = self
            .agent
            .owner
            .lookup(proto::GetAgentSessionInput {
                peer_id: Some(chat_peer(chat_id)),
                bot_user_id: self.config.bot_user_id,
                ..Default::default()
            })
            .await?;
        let known = result
            .connection
            .is_some_and(|connection| !connection.session_ref.is_empty());
        self.known_sessions.insert(chat_id, known);
        Ok(known)
    }

    /// A session works in this thread's folder, so it stays.
    async fn folder_fixed(&mut self, chat_id: i64) -> bool {
        match self.works.get(&chat_id) {
            Some(work) if !work.task.is_finished() => *work.phase.borrow() != WorkPhase::None,
            _ => self.session_known(chat_id).await.unwrap_or(false),
        }
    }

    /// Sets the folder this thread's work opens its session in. A running
    /// work decides, since only it knows whether a session opened; a session
    /// keeps its folder, so the change is refused with how to work elsewhere.
    async fn choose_folder(&mut self, chat_id: i64, folder: PathBuf) -> Result<(), String> {
        if !folder.is_dir() {
            return Err(format!(
                "The folder {} is not available on this machine.",
                folder.display()
            ));
        }
        match self.works.get(&chat_id) {
            Some(work) if !work.task.is_finished() => {
                let stopped = || "This work stopped. Try again.".to_owned();
                let (reply, answer) = oneshot::channel();
                work.tx
                    .send(Command::Folder {
                        folder: folder.clone(),
                        reply,
                    })
                    .await
                    .map_err(|_| stopped())?;
                answer.await.map_err(|_| stopped())??;
            }
            _ => {
                let known = self
                    .session_known(chat_id)
                    .await
                    .map_err(|error| format!("Couldn't check this thread's work: {error}"))?;
                if known {
                    return Err(settings::folder_fixed(&folder_label(
                        &self.thread_folder(chat_id),
                    )));
                }
            }
        }
        self.set_thread_folder(chat_id, folder);
        Ok(())
    }

    fn set_thread_folder(&mut self, chat_id: i64, folder: PathBuf) {
        self.thread_settings.entry(chat_id).or_default().folder = Some(folder);
        self.save_thread(chat_id);
    }

    /// A bound thread's project, as its composer chain set it, is the folder
    /// its work opens in. The apps offer the choice only until a session
    /// works there (they read Inline's record), so with no work here an
    /// unanswered lookup trusts the binding; a known session keeps its folder.
    async fn bound_project(&mut self, chat_id: i64, project: Option<String>) {
        let Some(project) = project else {
            return;
        };
        if self.bound_projects.get(&chat_id) == Some(&project) {
            return;
        }
        self.bound_projects.insert(chat_id, project.clone());
        if let Ok(mut projects) = self.agent.bound_projects.lock() {
            projects.insert(chat_id, project.clone());
        }
        let catalog = self.catalog().await;
        let Some(folder) = self
            .folders(&catalog)
            .and_then(|folders| folders.folder(&project).map(PathBuf::from))
        else {
            log::warn!(target: "inline::bridge::v2", "chat={chat_id} project={project} is not on this machine; the thread keeps its folder");
            return;
        };
        if self.thread_folder(chat_id) == folder {
            return;
        }
        let alive = self
            .works
            .get(&chat_id)
            .is_some_and(|work| !work.task.is_finished());
        let result = if alive || self.session_known(chat_id).await.is_ok() {
            self.choose_folder(chat_id, folder).await
        } else {
            self.set_thread_folder(chat_id, folder);
            Ok(())
        };
        if let Err(reason) = result {
            log::info!(target: "inline::bridge::v2", "chat={chat_id} keeps its folder: {reason}");
        }
    }

    async fn settings_document(
        &mut self,
        chat_id: i64,
        catalog: &Catalog,
    ) -> BotChatSettingsDocument {
        let default = SettingsChange::default();
        let folder = self.thread_folder(chat_id);
        let label = folder_label(&folder);
        let folder_fixed = self.folder_fixed(chat_id).await;
        // A bound thread's folder is its composer chain's.
        let folders = if self.bound_configs.contains_key(&chat_id) {
            None
        } else {
            self.folders(catalog)
        };
        let options = folders.as_ref().map(Folders::options).unwrap_or_default();
        // Usage as the harness last reported it; none yet and the apps say so.
        let usage = self
            .agent
            .usage
            .lock()
            .map(|windows| windows.clone())
            .unwrap_or_default();
        let context = self
            .agent
            .context
            .lock()
            .ok()
            .and_then(|contexts| contexts.get(&chat_id).copied());
        settings::document(&settings::DocumentFacts {
            catalog,
            settings: self.thread_settings.get(&chat_id).unwrap_or(&default),
            folder_label: &label,
            machine_label: &self.config.machine_label,
            folders: &options,
            folder_id: folders.as_ref().and_then(|folders| folders.id_of(&folder)),
            folder_fixed,
            can_compact: self.works.contains_key(&chat_id),
            usage: &usage,
            context,
        })
    }

    /// Agent Settings and the composer chain for one thread (spec §6):
    /// the owner or a CONFIGURE grantee reads and changes them.
    async fn chat_settings(
        &mut self,
        chat_id: i64,
        actor: i64,
        version: u32,
        invoked: Option<(&str, Option<&BotSettingsValue>, &str)>,
    ) -> BotChatSettingsResponse {
        if version != settings::SETTINGS_VERSION {
            return settings::problem(
                BotChatSettingsProblemCode::Unavailable,
                "This settings version is not supported. Update Inline and try again.",
                None,
            );
        }
        if !self
            .access
            .grants(actor)
            .await
            .permits(Operation::Configure)
        {
            return settings::problem(
                BotChatSettingsProblemCode::Unavailable,
                "Only the agent's owner, or someone they let configure it, can change these settings.",
                None,
            );
        }
        let catalog = self.catalog().await;
        let current = self.settings_document(chat_id, &catalog).await;
        let Some((item_id, value, revision)) = invoked else {
            return BotChatSettingsResponse::Document(current);
        };
        if revision != current.revision {
            return settings::problem(
                BotChatSettingsProblemCode::Stale,
                "These settings changed. Here are the current ones.",
                Some(current),
            );
        }
        let op = match settings::invocation(item_id, value, &catalog) {
            Ok(settings::Invocation::Change(change)) => {
                settings::merge(self.thread_settings.entry(chat_id).or_default(), &change);
                self.save_thread(chat_id);
                SessionOp::Settings(change)
            }
            Ok(settings::Invocation::Folder(id)) => {
                let chosen = self
                    .folders(&catalog)
                    .and_then(|folders| folders.folder(&id).map(PathBuf::from))
                    .ok_or_else(|| "That folder is not available on this machine.".to_owned());
                let chosen = match chosen {
                    Ok(folder) => self.choose_folder(chat_id, folder).await,
                    Err(message) => Err(message),
                };
                let document = self.settings_document(chat_id, &catalog).await;
                return match chosen {
                    Ok(()) => BotChatSettingsResponse::Document(document),
                    Err(message) => settings::problem(
                        BotChatSettingsProblemCode::InvalidValue,
                        &message,
                        Some(document),
                    ),
                };
            }
            Ok(settings::Invocation::Compact) => SessionOp::Compact,
            Err(message) => {
                return settings::problem(
                    BotChatSettingsProblemCode::InvalidValue,
                    message,
                    Some(current),
                );
            }
        };
        if self.works.contains_key(&chat_id) {
            let _ = self
                .ask(chat_id, |reply| Command::Session { op, reply })
                .await;
        }
        BotChatSettingsResponse::Document(self.settings_document(chat_id, &catalog).await)
    }

    async fn answer_settings(&self, request_id: u64, response: BotChatSettingsResponse) {
        if let Err(error) = self
            .agent
            .bot
            .answer_bot_chat_settings(AnswerBotChatSettingsRequest {
                request_id,
                response,
            })
            .await
        {
            log::warn!(target: "inline::bridge::v2", "settings answer failed: {error}");
        }
    }

    /// A slash command other than the controls and `/queue`. The harness's
    /// own meanings win (spec §2); anything else is said to be unavailable,
    /// never sent as a prompt (§4.1).
    async fn command(
        &mut self,
        chat_id: i64,
        actor: i64,
        grants: Grants,
        name: &str,
        arguments: &str,
        mentions: &[i64],
    ) -> String {
        let item = match name {
            "model" => Some(settings::ITEM_MODEL),
            "reasoning" => Some(settings::ITEM_REASONING),
            "permissions" => Some(settings::ITEM_PERMISSIONS),
            _ => None,
        };
        if let Some(item) = item {
            if !grants.permits(Operation::Configure) {
                return "Only the agent's owner, or someone they let configure it, can change that."
                    .to_owned();
            }
            let catalog = self.catalog().await;
            let argument = arguments.trim();
            if argument.is_empty() {
                return settings::describe(
                    item,
                    &catalog,
                    self.thread_settings
                        .get(&chat_id)
                        .unwrap_or(&SettingsChange::default()),
                );
            }
            let value = BotSettingsValue::String(settings::command_value(argument).to_owned());
            return match settings::invocation(item, Some(&value), &catalog) {
                Ok(settings::Invocation::Change(change)) => {
                    settings::merge(self.thread_settings.entry(chat_id).or_default(), &change);
                    self.save_thread(chat_id);
                    if self.works.contains_key(&chat_id) {
                        self.ask(chat_id, |reply| Command::Session {
                            op: SessionOp::Settings(change),
                            reply,
                        })
                        .await
                        .unwrap_or_else(|| "Set for this thread.".to_owned())
                    } else {
                        "Set for this thread, from the next message.".to_owned()
                    }
                }
                Ok(settings::Invocation::Compact | settings::Invocation::Folder(_)) => {
                    "Use /compact.".to_owned()
                }
                Err(message) => message.to_owned(),
            };
        }
        match name {
            "compact" | "clear" => {
                if !grants.permits(Operation::Steer) {
                    return NO_ACCESS.to_owned();
                }
                if !self.works.contains_key(&chat_id) {
                    return "Nothing is open in this thread yet.".to_owned();
                }
                let op = if name == "compact" {
                    SessionOp::Compact
                } else {
                    SessionOp::Clear
                };
                self.ask(chat_id, |reply| Command::Session { op, reply })
                    .await
                    .unwrap_or_else(|| "Done.".to_owned())
            }
            "status" => self.status(chat_id, actor).await,
            "help" => help_text(&self.config.agent_name, self.config.vocabulary),
            "plan" | "review" | "undo" => {
                if !grants.permits(Operation::Steer) {
                    return NO_ACCESS.to_owned();
                }
                let op = match (name, self.config.vocabulary) {
                    ("plan", Vocabulary::Codex) => SessionOp::Mode(
                        if arguments.trim().eq_ignore_ascii_case("off") {
                            "default"
                        } else {
                            "plan"
                        }
                        .to_owned(),
                    ),
                    ("plan", Vocabulary::Claude)
                        if arguments.trim().eq_ignore_ascii_case("off") =>
                    {
                        return "Approve or reject the plan to leave plan mode, or pick a mode with /permissions."
                            .to_owned();
                    }
                    ("plan", Vocabulary::Claude) => SessionOp::Mode("plan".to_owned()),
                    ("review", Vocabulary::Codex) => SessionOp::Review(
                        Some(arguments.trim().to_owned()).filter(|branch| !branch.is_empty()),
                    ),
                    ("undo", Vocabulary::Claude) => SessionOp::Undo,
                    (other, _) => {
                        return format!(
                            "/{other} isn't available with {}. Send /help for what is.",
                            self.config.agent_name
                        );
                    }
                };
                if !self.works.contains_key(&chat_id) {
                    return "Nothing is open in this thread yet. Send a message first.".to_owned();
                }
                self.ask(chat_id, |reply| Command::Session { op, reply })
                    .await
                    .unwrap_or_else(|| "Done.".to_owned())
            }
            "follow" | "unfollow" => {
                if !grants.permits(Operation::StartWork) {
                    return NO_ACCESS.to_owned();
                }
                if chat_id == self.config.dm_chat_id {
                    return "This is our DM; I always answer here.".to_owned();
                }
                let follow = name == "follow";
                match self.set_following(chat_id, follow).await {
                    Ok(()) if follow => "Following this thread.".to_owned(),
                    Ok(()) => "Unfollowed. I'll answer mentions and replies here.".to_owned(),
                    Err(error) => format!("Could not change that: {error}"),
                }
            }
            "allowlist" => self.allowlist(actor, arguments, mentions).await,
            other => format!(
                "/{other} isn't available with {}. Send /help for what is.",
                self.config.agent_name
            ),
        }
    }

    /// `/allowlist`: the owner lists, adds or removes the people who may use
    /// and steer this agent. Inline holds the list; the bridge rechecks it on
    /// every message.
    async fn allowlist(&mut self, actor: i64, arguments: &str, mentions: &[i64]) -> String {
        if actor != self.config.owner_user_id {
            return "Only the agent's owner can change who may use it.".to_owned();
        }
        let remove = arguments
            .split_whitespace()
            .next()
            .is_some_and(|word| word.eq_ignore_ascii_case("remove"));
        if mentions.is_empty() {
            return match api::list_grants(&self.agent.bot).await {
                Ok(result) if result.grants.is_empty() => {
                    "Only you can use me. Add someone with /allowlist @name.".to_owned()
                }
                Ok(result) => {
                    let mut names = Vec::new();
                    for grant in result.grants {
                        names.push(self.agent.names.of(grant.user_id).await);
                    }
                    format!(
                        "People who can use me: {}. Remove someone with /allowlist remove @name.",
                        names.join(", ")
                    )
                }
                Err(error) => format!("Could not read the list: {error}"),
            };
        }
        let mut done = Vec::new();
        for &user in mentions
            .iter()
            .filter(|&&user| user != self.config.bot_user_id)
        {
            let result = if remove {
                api::delete_grant(&self.agent.bot, user).await
            } else {
                api::grant_use(&self.agent.bot, user).await
            };
            if let Err(error) = result {
                return format!("Could not change the list: {error}");
            }
            done.push(self.agent.names.of(user).await);
        }
        self.access.invalidate().await;
        match (remove, done.is_empty()) {
            (_, true) => "Mention the people to add or remove.".to_owned(),
            (false, false) => format!("{} can now use me.", done.join(", ")),
            (true, false) => format!("{} can no longer use me.", done.join(", ")),
        }
    }

    async fn status(&mut self, chat_id: i64, _actor: i64) -> String {
        let phase = self.works.get(&chat_id).map(|work| *work.phase.borrow());
        let state = match phase {
            None | Some(WorkPhase::None) => "Nothing has run in this thread yet.",
            Some(WorkPhase::Idle) => "Idle.",
            Some(WorkPhase::Running) => "Working.",
            Some(WorkPhase::Paused) => "Paused. Mention the agent or send /resume to go on.",
        };
        let catalog = self.catalog().await;
        let settings = self
            .thread_settings
            .get(&chat_id)
            .cloned()
            .unwrap_or_default();
        let label = |value: &Option<String>| value.clone().unwrap_or_else(|| "default".to_owned());
        let info = self.agent.harness.describe();
        format!(
            "{} on {}: {state}\nModel: {}. Reasoning: {}. Permissions: {}.\nFolder: {}. {} {}.{}",
            self.config.agent_name,
            self.config.machine_label,
            label(&settings.model),
            label(&settings.effort),
            label(&settings.permission_mode),
            folder_label(&self.thread_folder(chat_id)),
            match self.config.vocabulary {
                Vocabulary::Codex => "Codex",
                Vocabulary::Claude => "Claude Code",
            },
            info.executable
                .version
                .as_deref()
                .unwrap_or("(version unknown)"),
            if catalog.models.is_empty() {
                ""
            } else {
                " Models: /model."
            }
        )
    }

    /// A work moved into a subthread: it is that chat's work from now on.
    fn moved_work(&mut self, from: i64, to: i64) {
        if let Err(error) = self.agent.ledger.move_thread(from, to) {
            log::warn!(target: "inline::bridge::v2", "cannot persist moved work: {error}");
        }
        if let Some(settings) = self.thread_settings.get(&from).cloned() {
            self.thread_settings.insert(to, settings);
        }
        if let Some(bound) = self.bound_configs.get(&from).cloned() {
            self.bound_configs.insert(to, bound);
        }
        self.known_sessions.remove(&from);
        self.known_sessions.remove(&to);
        self.own_threads.insert(to, true);
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
        // Message updates and reconnect catch-up can redeliver old input.
        // v2 has its own ledger, but work already accepted by v1 must never
        // run again after enabling v2. Read its receipt without changing it.
        if let Some(store) = &self.legacy_store
            && store.event_processed(&format!(
                "inline-message-{}-{}",
                message.chat_id, message.message_id
            ))?
        {
            return Ok(());
        }
        if message.is_outgoing
            || message.timestamp < self.config.accept_messages_after
            || message.metadata.agent_session.is_some()
        {
            return Ok(());
        }
        // A sender the local store has not met yet: ask Inline whether it is
        // an agent, so the loop cap sees agents it never saw before.
        let resolved;
        let message = if message.metadata.sender_is_bot.is_none() {
            let mut known = message.clone();
            known.metadata.sender_is_bot =
                Some(self.agent.names.is_bot(message.sender_id.get()).await);
            resolved = known;
            &resolved
        } else {
            message
        };
        let chat_id = message.chat_id.get();
        // The agent's own threads are the ones it made (`/new`, a moved work's
        // subthread, `create_chat`) or that are bound to it. A shared thread it
        // was mentioned in stays a group thread, where only addressed
        // messages reach it.
        // This bot's follow mode in the thread (Inline's opener rule,
        // /follow or its tool). Unfollow wins, also in its own threads.
        let followed = if chat_id == self.config.dm_chat_id {
            None
        } else {
            self.following(chat_id).await
        };
        let conversation = if chat_id == self.config.dm_chat_id {
            Conversation::Dm
        } else if followed != Some(false) && self.is_own_thread(chat_id).await {
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
        let scope = self.loop_scope(chat_id).await;
        let loop_verdict = self.loop_guards.record(scope, group.author.kind.is_agent());
        if let LoopVerdict::CapReached {
            limit,
            notify_owners: true,
            ..
        } = loop_verdict
        {
            self.loop_cap_reached(chat_id, limit).await;
        }
        let decision = decide_intake(IntakeFacts {
            message: &group,
            bot_user_id: self.config.bot_user_id,
            grants,
            work,
            participation: participation_mode,
            loop_verdict,
        });
        // In a group thread it follows, every message from a person with
        // access is for the agent; the thread stays a group thread for
        // placement and join context.
        let decision = match decision {
            IntakeDecision::Observe {
                reason: ObserveReason::Unaddressed,
                ..
            } if followed == Some(true)
                && conversation == Conversation::Group
                && !group.author.kind.is_agent()
                && !matches!(
                    participation_mode,
                    Some(ParticipationMode::Muted | ParticipationMode::MentionsOnly)
                ) =>
            {
                let required = required_operation(&group, work);
                if grants.permits(required) {
                    IntakeDecision::Act {
                        reason: DirectReason::WorkThread,
                        join: false,
                        required,
                    }
                } else {
                    decision
                }
            }
            decision => decision,
        };
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
        // Addressing the agent can make it follow (Inline's opener rule), so
        // an unknown follow mode is read again on the next message.
        if self
            .follows
            .get(&chat_id)
            .is_some_and(|(mode, _)| mode.is_none())
        {
            self.follows.remove(&chat_id);
        }
        // A command runs once per message. The same message comes back when
        // it is edited or updated (creating a reply thread updates its
        // parent), and must not run again: a second `/new` returned the same
        // thread and replaced its starting work.
        if let Some((name, _)) = group.command()
            && name != "queue"
        {
            let id = input_id(
                self.config.bot_user_id,
                chat_id,
                group.message_id,
                "command",
            );
            if let Begin::Seen(_) =
                self.agent
                    .ledger
                    .begin(&id, chat_id, group.message_id, group.author.user_id)?
            {
                return Ok(());
            }
            self.agent.ledger.set(&id, InputState::Consumed)?;
        }
        let control = match group.command().map(|(name, _)| name) {
            Some("new") => return self.new_thread(group, grants, participation).await,
            Some("stop") => Some(Control::Stop),
            Some("pause") => Some(Control::Pause),
            Some("resume") => Some(Control::Resume),
            Some("release") => Some(Control::Release(ReleaseCause::Command)),
            Some("terminal") => Some(Control::Release(ReleaseCause::ContinueInTerminal)),
            _ => None,
        };
        // The harness's own slash commands (Claude's custom commands and
        // skills) go to it as typed; Inline's commands win a collision.
        let forward = match group.command() {
            Some((name, _))
                if control.is_none() && name != "queue" && !INLINE_COMMANDS.contains(&name) =>
            {
                self.catalog()
                    .await
                    .commands
                    .iter()
                    .any(|command| command.name == name)
            }
            _ => false,
        };
        if let Some((name, _)) = group.command()
            && control.is_none()
            && name != "queue"
            && !forward
        {
            let arguments = command_arguments(&group.text, name);
            let answer = self
                .command(
                    chat_id,
                    group.author.user_id,
                    grants,
                    name,
                    arguments,
                    &mentioned_users(group),
                )
                .await;
            self.reply(chat_id, group.message_id, &answer).await;
            return Ok(());
        }
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
        let input = if forward {
            Some(Input {
                id: InputId::new(id.clone())?,
                content: InputContent {
                    text: harness_command_text(&group.text, &self.config.bot_username),
                    attachments: Vec::new(),
                    context,
                },
                origin: origin_of(group, self.config.owner_user_id),
                delivery: Delivery::Turn,
            })
        } else {
            direct_input(
                decision,
                group,
                self.config.owner_user_id,
                InputId::new(id.clone())?,
                None,
                context,
            )
        };
        let Some(mut input) = input else {
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
                answer_reply: matches!(group.conversation, Conversation::Group),
                reply_to: group.reply_to.as_ref().map(|reply| reply.message_id),
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
            ContextAuthorRole, ContextBudget, ContextMessage, ContextParticipant, JoinContext,
            JoinContextInput, LinkedThread,
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
        let role = |sender: i64, is_bot: bool| {
            if sender == self.config.bot_user_id {
                ContextAuthorRole::Me
            } else if sender == self.config.owner_user_id {
                ContextAuthorRole::Owner
            } else if is_bot {
                ContextAuthorRole::Agent
            } else {
                ContextAuthorRole::Teammate
            }
        };
        let context_message = |message: &MessageRecord, names: &HashMap<i64, String>| {
            let sender = message.sender_id.get();
            ContextMessage {
                message_id: message.message_id.get(),
                author_name: names
                    .get(&sender)
                    .cloned()
                    .unwrap_or_else(|| format!("user {sender}")),
                role: role(sender, message.metadata.sender_is_bot.unwrap_or(false)),
                reply_to: message.reply_to_message_id.map(InlineId::get),
                text: super::intake::message_text(&message.content).to_owned(),
            }
        };
        let mut recent: Vec<ContextMessage> = page
            .messages
            .iter()
            .filter(|message| message.message_id.get() != group.message_id)
            .map(|message| context_message(message, &names))
            .collect();
        recent.sort_by_key(|message| message.message_id);
        // The trigger's reply chain, nearest first; ancestors older than the
        // fetched window are read one by one.
        let mut reply_chain = Vec::new();
        let mut next = group.reply_to.as_ref().map(|reply| reply.message_id);
        while let Some(id) = next.take() {
            if reply_chain.len() >= JOIN_REPLY_CHAIN {
                break;
            }
            let message = match recent.iter().find(|message| message.message_id == id) {
                Some(message) => message.clone(),
                None => {
                    let Ok(page) = self
                        .agent
                        .bot
                        .history(inline_client::HistoryRequest {
                            chat_id: InlineId::new(group.chat_id),
                            limit: Some(1),
                            before_message_id: Some(InlineId::new(id + 1)),
                            after_message_id: None,
                        })
                        .await
                    else {
                        break;
                    };
                    let Some(found) = page
                        .messages
                        .iter()
                        .find(|message| message.message_id.get() == id)
                    else {
                        break;
                    };
                    context_message(found, &names)
                }
            };
            next = message.reply_to;
            reply_chain.push(message);
        }
        let state = self
            .agent
            .bot
            .chat_state(InlineId::new(group.chat_id))
            .await
            .ok();
        let title = state
            .and_then(|state| state.dialog)
            .and_then(|dialog| dialog.title);
        let participants = match self
            .agent
            .bot
            .chat_participants(inline_client::ChatParticipantsRequest {
                chat_id: InlineId::new(group.chat_id),
            })
            .await
        {
            Ok(page) => page
                .participants
                .iter()
                .map(|participant| {
                    let id = participant.user_id.get();
                    let user = page.users.iter().find(|user| user.user_id.get() == id);
                    let name = user
                        .and_then(|user| {
                            user.display_name
                                .clone()
                                .or_else(|| user.first_name.clone())
                                .or_else(|| user.username.clone())
                        })
                        .or_else(|| names.get(&id).cloned())
                        .unwrap_or_else(|| format!("user {id}"));
                    ContextParticipant {
                        name,
                        role: role(id, user.and_then(|user| user.is_bot).unwrap_or(false)),
                    }
                })
                .collect(),
            Err(error) => {
                log::debug!(target: "inline::bridge::v2", "participants unavailable: {error}");
                Vec::new()
            }
        };
        // Threads the trigger links to, with their titles when this agent
        // can see them.
        let mut linked = Vec::new();
        for entity in &group.entities {
            if let inline_agent_bridge::group::MessageEntity::Link { chat_id, .. } = entity
                && !linked
                    .iter()
                    .any(|thread: &LinkedThread| thread.chat_id == *chat_id)
            {
                let title = self
                    .agent
                    .bot
                    .chat_state(InlineId::new(*chat_id))
                    .await
                    .ok()
                    .and_then(|state| state.dialog)
                    .and_then(|dialog| dialog.title);
                linked.push(LinkedThread {
                    chat_id: *chat_id,
                    title,
                });
            }
        }
        // A thread's first message still tells the agent where it is.
        if title.is_none() && participants.is_empty() && recent.is_empty() && reply_chain.is_empty()
        {
            return None;
        }
        let context = JoinContext::build(
            &JoinContextInput {
                chat_id: group.chat_id,
                title,
                participants,
                recent,
                earlier_unfetched: (!page.has_more).then_some(0),
                reply_chain,
                linked,
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
        // Every path, recovery included, learns a bound thread's project
        // first: its session's registration must name it.
        self.is_own_thread(chat_id).await;
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
        self.agent.ledger.forget_move(chat_id)?;
        self.moved.remove(&chat_id);
        // The work knows its session from now on.
        self.known_sessions.remove(&chat_id);
        self.works.insert(
            chat_id,
            super::work::spawn(
                self.agent.clone(),
                chat_id,
                known,
                mode,
                self.thread_settings
                    .get(&chat_id)
                    .cloned()
                    .unwrap_or_default(),
            ),
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
        self.own_threads.insert(chat_id, true);
        // The new thread works where its parent does.
        if let Some(folder) = self
            .thread_settings
            .get(&group.chat_id)
            .and_then(|settings| settings.folder.clone())
        {
            self.thread_settings.entry(chat_id).or_default().folder = Some(folder);
            self.save_thread(chat_id);
        }
        let mode = self.effective_mode(participation.as_ref());
        self.works.insert(
            chat_id,
            super::work::spawn(
                self.agent.clone(),
                chat_id,
                Known::default(),
                mode,
                self.thread_settings
                    .get(&chat_id)
                    .cloned()
                    .unwrap_or_default(),
            ),
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
                    // `/new` starts the work in its own thread.
                    answer_reply: false,
                    reply_to: None,
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
            .find(|(chat, work)| match agent_session_id {
                Some(id) => work.agent_session_id() == Some(id),
                None => **chat == chat_id,
            })
            .map(|(chat, _)| *chat);
        let Some(work_chat) = known else {
            return problem("This work is not open on this machine.");
        };
        let folder = self.thread_folder(work_chat);
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

/// A folder as people know it: its name.
fn folder_label(folder: &Path) -> String {
    folder
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| folder.display().to_string())
}

/// The text after `/name` (and an optional `@bot`), trimmed.
/// People the message mentions, in order.
fn mentioned_users(message: &GroupMessage) -> Vec<i64> {
    message
        .entities
        .iter()
        .filter_map(|entity| match entity {
            inline_agent_bridge::group::MessageEntity::Mention {
                target: inline_agent_bridge::group::Mention::User { user_id },
                ..
            } => Some(*user_id),
            _ => None,
        })
        .collect()
}

/// The command menu for this agent: Inline's commands for v2, then the
/// harness's own (Claude's commands and skills) that fit Inline's rules, up
/// to Inline's 100.
fn command_catalog(vocabulary: Vocabulary, catalog: &Catalog) -> Vec<proto::BotCommand> {
    let mut commands: Vec<(String, String)> = [
        ("help", "Show this agent's commands"),
        ("status", "What it's doing, its model and folder"),
        ("new", "Start a fresh session in a new thread"),
        ("stop", "Stop the current turn"),
        ("pause", "Pause this thread's work"),
        ("resume", "Resume paused work"),
        ("queue", "Run a message after the current turn"),
        ("model", "Show or choose the model"),
        ("reasoning", "Show or choose reasoning effort"),
        ("permissions", "Show or choose the permission mode"),
        ("plan", "Plan mode: plan before changing anything"),
        ("compact", "Compact the session's context"),
        ("clear", "Clear the session's context"),
        ("follow", "Answer every message in this thread"),
        ("unfollow", "Answer only mentions and replies here"),
        ("allowlist", "Who may use this agent (owner)"),
        ("release", "Let the session go"),
        ("terminal", "Continue the session in a terminal"),
    ]
    .into_iter()
    .map(|(name, description)| (name.to_owned(), description.to_owned()))
    .collect();
    match vocabulary {
        Vocabulary::Codex => commands.insert(
            11,
            ("review".to_owned(), "Codex reviews your changes".to_owned()),
        ),
        Vocabulary::Claude => commands.insert(
            11,
            (
                "undo".to_owned(),
                "Undo the last turn's file changes".to_owned(),
            ),
        ),
    }
    let valid = |name: &str| {
        !name.is_empty()
            && name.len() <= 32
            && name
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
    };
    for command in &catalog.commands {
        if commands.len() >= 100 {
            break;
        }
        if valid(&command.name) && !commands.iter().any(|(name, _)| *name == command.name) {
            let description = if command.description.trim().is_empty() {
                format!("/{}", command.name)
            } else {
                command.description.chars().take(256).collect()
            };
            commands.push((command.name.clone(), description));
        }
    }
    commands
        .into_iter()
        .enumerate()
        .map(|(index, (command, description))| proto::BotCommand {
            command,
            description,
            sort_order: i32::try_from(index).ok(),
        })
        .collect()
}

/// Commands Inline answers itself; the harness's own commands with these
/// names are not forwarded.
const INLINE_COMMANDS: &[&str] = &[
    "new",
    "stop",
    "pause",
    "resume",
    "release",
    "terminal",
    "queue",
    "model",
    "reasoning",
    "permissions",
    "compact",
    "clear",
    "status",
    "help",
    "follow",
    "unfollow",
    "allowlist",
    "plan",
    "review",
    "undo",
];

/// A harness command as the person typed it, without Inline's `@bot` suffix.
fn harness_command_text(text: &str, bot_username: &str) -> String {
    let text = text.trim_start();
    let (command, rest) = text.split_once(char::is_whitespace).unwrap_or((text, ""));
    let command = command
        .strip_suffix(&format!("@{bot_username}"))
        .unwrap_or(command);
    format!("{command} {}", rest.trim()).trim_end().to_owned()
}

/// `/help`: what this agent answers to.
fn help_text(agent_name: &str, vocabulary: Vocabulary) -> String {
    let native = match vocabulary {
        Vocabulary::Codex => {
            "/plan, /plan off · Codex plan mode\n/review [branch] · Codex reviews your changes\n"
        }
        Vocabulary::Claude => {
            "/plan · Claude plan mode\n/undo · undo the last turn's file changes\nClaude's own commands and skills work as you type them.\n"
        }
    };
    format!(
        "{agent_name} commands:\n\
         /status · what I'm doing, my model and folder\n\
         /model, /reasoning, /permissions · change them for this thread\n\
         /stop · stop the current turn; /pause and /resume\n\
         /queue <message> · run it after the current turn\n\
         /compact, /clear · shrink or reset the session's context\n\
         /new <task> · a new thread with a fresh session\n\
         /follow, /unfollow · answer every message in this thread, or only mentions and replies\n\
         /allowlist · who may use me (owner)\n\
         /release · let the session go; /terminal · continue it in a terminal\n\
         {native}"
    )
    .trim_end()
    .to_owned()
}

fn command_arguments<'a>(text: &'a str, name: &str) -> &'a str {
    let lower = text.to_ascii_lowercase();
    let Some(start) = lower.find(&format!("/{name}")) else {
        return "";
    };
    let rest = &text[start + name.len() + 1..];
    let rest = match rest.split_once(char::is_whitespace) {
        Some((token, after)) if token.starts_with('@') || token.is_empty() => after,
        Some((_, after)) => after,
        None => "",
    };
    rest.trim()
}

fn output_mode(mode: i32) -> OutputMode {
    match proto::AgentOutputMode::try_from(mode) {
        Ok(proto::AgentOutputMode::Friendly) => OutputMode::Friendly,
        _ => OutputMode::Detailed,
    }
}

/// What the apps show for the harness's health: online, or what to fix.
fn runtime_status(
    health: &RuntimeHealth,
    agent_name: &str,
) -> (proto::AgentRuntimeStatus, Option<proto::AgentRuntimeSetup>) {
    use proto::agent_runtime_setup::Reason;
    let RuntimeHealth::NeedsSetup { reason } = health else {
        return (proto::AgentRuntimeStatus::Online, None);
    };
    let (code, text, min_version) = match reason {
        SetupReason::UpdateRuntime { min_version, found } => (
            Reason::UpdateRuntime,
            match found {
                Some(found) => {
                    format!("Update {agent_name} to {min_version} or later (found {found}).")
                }
                None => format!("Update {agent_name} to {min_version} or later."),
            },
            Some(min_version.clone()),
        ),
        SetupReason::UpdateInline { detail } => (
            Reason::UpdateInline,
            format!("Update the Inline CLI to work with this {agent_name} ({detail})."),
            None,
        ),
        SetupReason::ExecutableMissing { path } => (
            Reason::ExecutableMissing,
            format!("{agent_name} is no longer at {path}. Reinstall it or run setup again."),
            None,
        ),
        SetupReason::ExecutableChanged { path, detail } => (
            Reason::ExecutableChanged,
            format!("{agent_name} at {path} changed ({detail}). Run setup again to trust it."),
            None,
        ),
        SetupReason::SignIn => (
            Reason::SignIn,
            format!("Sign in to {agent_name} on this machine."),
            None,
        ),
        SetupReason::FolderUnavailable { path } => (
            Reason::FolderUnavailable,
            format!("The folder {path} is not available on this machine."),
            None,
        ),
        SetupReason::Harness { message, .. } => (Reason::Other, message.clone(), None),
    };
    (
        proto::AgentRuntimeStatus::NeedsSetup,
        Some(proto::AgentRuntimeSetup {
            reason: code as i32,
            text: Some(text),
            min_version,
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn harness_commands_go_to_the_harness_as_typed_without_the_bot_suffix() {
        assert_eq!(harness_command_text("/review", "claude_bot"), "/review");
        assert_eq!(
            harness_command_text("/deploy@claude_bot staging now", "claude_bot"),
            "/deploy staging now"
        );
        for name in [
            "help",
            "follow",
            "allowlist",
            "plan",
            "review",
            "undo",
            "compact",
        ] {
            assert!(INLINE_COMMANDS.contains(&name), "{name} is Inline's");
        }
    }

    #[test]
    fn the_command_menu_holds_inlines_commands_then_the_harness_own() {
        let mut catalog = Catalog::default();
        for (name, description) in [
            ("deploy", "Deploy the app"),
            ("compact", "Claude's own compact"),
            ("plugin:skill", "Not a valid Inline command name"),
        ] {
            catalog.commands.push(inline_agent_bridge::DriverCommand {
                name: name.to_owned(),
                description: description.to_owned(),
                input_hint: None,
                input: Default::default(),
            });
        }
        let names = |vocabulary| {
            command_catalog(vocabulary, &catalog)
                .into_iter()
                .map(|command| command.command)
                .collect::<Vec<_>>()
        };
        let claude = names(Vocabulary::Claude);
        assert!(claude.contains(&"undo".to_owned()) && !claude.contains(&"review".to_owned()));
        assert_eq!(claude.last().map(String::as_str), Some("deploy"));
        assert_eq!(claude.iter().filter(|name| *name == "compact").count(), 1);
        assert!(!claude.iter().any(|name| name.contains(':')));
        let codex = names(Vocabulary::Codex);
        assert!(codex.contains(&"review".to_owned()) && !codex.contains(&"undo".to_owned()));
        for name in INLINE_COMMANDS {
            assert!(
                claude.contains(&(*name).to_owned()) || codex.contains(&(*name).to_owned()),
                "/{name} is answered but not in the menu"
            );
        }
        assert!(command_catalog(Vocabulary::Claude, &catalog).len() <= 100);
    }

    #[test]
    fn help_names_each_harness_own_commands() {
        let codex = help_text("Codex", Vocabulary::Codex);
        assert!(codex.contains("/review") && !codex.contains("/undo"));
        let claude = help_text("Claude", Vocabulary::Claude);
        assert!(claude.contains("/undo") && claude.contains("skills"));
        assert!(claude.contains("/allowlist") && claude.contains("/follow"));
    }

    #[test]
    fn command_arguments_follow_the_command_and_its_bot() {
        assert_eq!(command_arguments("/model luna", "model"), "luna");
        assert_eq!(
            command_arguments("/model@codex_bot  luna ", "model"),
            "luna"
        );
        assert_eq!(
            command_arguments("@Codex /reasoning high", "reasoning"),
            "high"
        );
        assert_eq!(command_arguments("/status", "status"), "");
        assert_eq!(command_arguments("/MODEL Sol", "model"), "Sol");
    }

    #[test]
    fn a_harness_that_needs_setup_reports_the_fix() {
        let (status, setup) = runtime_status(&RuntimeHealth::Ready, "Codex");
        assert_eq!(status, proto::AgentRuntimeStatus::Online);
        assert!(setup.is_none());
        let (status, setup) = runtime_status(
            &RuntimeHealth::NeedsSetup {
                reason: SetupReason::UpdateRuntime {
                    min_version: "0.150.0".to_owned(),
                    found: Some("0.140.0".to_owned()),
                },
            },
            "Codex",
        );
        assert_eq!(status, proto::AgentRuntimeStatus::NeedsSetup);
        let setup = setup.unwrap();
        assert_eq!(
            setup.reason,
            proto::agent_runtime_setup::Reason::UpdateRuntime as i32
        );
        assert_eq!(setup.min_version.as_deref(), Some("0.150.0"));
        assert!(setup.text.unwrap().contains("found 0.140.0"));
    }
}

#[cfg(test)]
#[path = "faults.rs"]
mod faults;
