//! The bridge v2 runtime: one native session per (thread, agent) on the
//! session contract, rendered into Inline with blocks (spec §4–§7).
//!
//! This loop owns intake: it decides what each Inline message is for,
//! records direct input in the ledger before acknowledging the delivery, and
//! hands it to the thread's work actor (`work.rs`).

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use inline_agent_bridge::HostToolResult;
use inline_agent_bridge::ProviderSessionId;
use inline_agent_bridge::group::{
    ContextAuthorRole, ContextMessage, Conversation, DEFAULT_DAILY_SPEAK_GATE_BUDGET,
    DEFAULT_LOOP_CAP_HOPS, DailySpeakGateBudget, DayKey, DirectReason, Grants, GroupMessage,
    IntakeDecision, IntakeFacts, LoopGuards, LoopVerdict, ObserveReason, Operation,
    ParticipationMode, PendingInput, ReleaseCause, WorkPhase, decide_intake, direct_input,
    origin_of, required_operation,
};
use inline_agent_bridge::harness::{
    Catalog, CatalogScope, Delivery, HarnessDriver, Input, InputContent, InputId, OpKind,
    OutputMode, RuntimeHealth, SettingsChange, SetupReason, UserId,
};
use inline_client::store::ClientStore;
use inline_client::{
    AnswerBotChatSettingsRequest, AnswerMessageActionRequest, BotCapability,
    BotChatSettingsDocument, BotChatSettingsProblemCode, BotChatSettingsResponse,
    BotInteractionEvent, BotSettingsValue, ClientEvent, ClientStatus, CreateReplyThreadRequest,
    InlineClient, InlineId, LosslessEventReceiver, MessageRecord, SqliteStore,
};
use inline_protocol::proto;
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

use crate::bridge::runtime::{BotAgentResolver, mentioned_agent_id};

use super::api::{self, Notify, chat_peer};
use super::doc::DocBuilder;
use super::folders::{FolderSource, Folders};
use super::intake::{
    MessageFacts, asked, grants_by_user, grants_from_operations, group_message, has_scoped_grants,
};
use super::lead::{
    DIRECTED, LeadRequest, MAX_RUNNING_TASKS, SendMode, SpawnTask, TASK_INSTRUCTIONS, TaskReport,
    card_text, note_text, report_event_id, report_text, status_word,
};
use super::ledger::{Begin, ChildRecord, InputState, LeadEventRecord, Ledger, input_id};
use super::render::{ActionStyle, QUESTION_FORM_ID, Vocabulary};
use super::settings;
use super::skills::{self, Skill, SkillPublisher};
use super::tools::Tools;
use super::work::{
    AccessSource, ActionData, Agent, Command, Control, Known, OwnerCalls, SessionOp, WorkHandle,
    button_rows, paragraph,
};
use super::workspaces::{self, NO_PROJECT_ID};

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
/// Ancestors of the trigger's reply chain read into the join context.
const JOIN_REPLY_CHAIN: usize = 5;
/// Settled ledger records are kept this long for replay detection.
const LEDGER_RETENTION_SECS: i64 = 14 * 24 * 3600;
/// Parents followed to find a thread tree's root, the loop cap's scope.
const LOOP_SCOPE_DEPTH: usize = 8;

/// Identity and settings of one v2 agent.
#[derive(Clone, Debug)]
pub(crate) struct V2Config {
    pub vocabulary: Vocabulary,
    /// The harness runs through ACP (Amp, or OpenCode's fallback route):
    /// no terminal handoff, native queue or session browser.
    pub acp: bool,
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
            Vocabulary::OpenCode => proto::AgentSessionProvider::OpenCode,
            Vocabulary::Amp => proto::AgentSessionProvider::Amp,
        }
    }
}

/// Grants from `listAgentGrants`, cached until a grant update arrives. An
/// agent sender acts for its owner: it also gets what its owner may delegate
/// here (use and steer), so the owner's other agents and agents of people
/// with access work without grants of their own.
struct Access {
    bot: InlineClient,
    owner_user_id: i64,
    names: Arc<api::Names>,
    cache: tokio::sync::Mutex<Option<GrantCache>>,
    /// Server-resolved access per user, used once any grant names a space or a
    /// group. Expires so membership changes show up without a grant update.
    resolved: tokio::sync::Mutex<HashMap<i64, (Grants, std::time::Instant)>>,
    /// Bumped on every grant update, so an answer fetched before a revocation
    /// isn't cached after it.
    generation: std::sync::atomic::AtomicU64,
}

#[derive(Default)]
struct GrantCache {
    by_user: HashMap<i64, Grants>,
    scoped: bool,
}

const RESOLVED_ACCESS_TTL: std::time::Duration = std::time::Duration::from_secs(300);

impl Access {
    async fn invalidate(&self) {
        self.generation
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        *self.cache.lock().await = None;
        self.resolved.lock().await.clear();
    }

    /// Whether any grant names a space or a group (loads the grants if needed).
    async fn scoped(&self) -> bool {
        self.own(0).await;
        self.cache
            .lock()
            .await
            .as_ref()
            .is_some_and(|cache| cache.scoped)
    }

    /// The server's answer for `user_id`, cached for a few minutes.
    async fn resolved(&self, user_id: i64) -> Option<Grants> {
        if let Some((grants, at)) = self.resolved.lock().await.get(&user_id).copied()
            && at.elapsed() < RESOLVED_ACCESS_TTL
        {
            return Some(grants);
        }
        let generation = self.generation.load(std::sync::atomic::Ordering::SeqCst);
        match api::get_agent_access(&self.bot, 0, user_id).await {
            Ok(result) => {
                let grants = if result.is_owner {
                    Grants::OWNER
                } else {
                    grants_from_operations(&result.operations)
                };
                let mut resolved = self.resolved.lock().await;
                if self.generation.load(std::sync::atomic::Ordering::SeqCst) == generation {
                    resolved.insert(user_id, (grants, std::time::Instant::now()));
                }
                Some(grants)
            }
            Err(error) => {
                log::warn!(target: "inline::bridge::v2", "access for {user_id} unavailable: {error}");
                None
            }
        }
    }

    /// The user's own grants, without acting-for.
    async fn own(&self, user_id: i64) -> Grants {
        if user_id == self.owner_user_id {
            return Grants::OWNER;
        }
        let mut cache = self.cache.lock().await;
        if cache.is_none() {
            match api::list_grants(&self.bot).await {
                Ok(result) => {
                    *cache = Some(GrantCache {
                        by_user: grants_by_user(&result),
                        scoped: has_scoped_grants(&result),
                    })
                }
                Err(error) => {
                    // Unknown grants admit nobody but the owner.
                    log::warn!(target: "inline::bridge::v2", "grants unavailable: {error}");
                    return Grants::NONE;
                }
            }
        }
        cache
            .as_ref()
            .and_then(|cache| cache.by_user.get(&user_id).copied())
            .unwrap_or_default()
    }
}

impl AccessSource for Access {
    fn grants(&self, user_id: i64) -> futures_util::future::BoxFuture<'_, Grants> {
        Box::pin(async move {
            let own = self.own(user_id).await;
            if own.owner {
                return own;
            }
            // Space and group grants need the server to know who's a member.
            if self.scoped().await
                && let Some(grants) = self.resolved(user_id).await
            {
                return grants;
            }
            let owner = match self.names.owner_of(user_id).await {
                // A bot never inherits from itself.
                Some(owner) if owner != user_id => Some(self.own(owner).await),
                _ => None,
            };
            Grants::acting_for(own, owner)
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
    startup_activity: Option<crate::bridge::update_activity::Lease>,
    /// Keep v1's durable receipts authoritative after opting in.
    legacy_store: Option<Arc<inline_agent_bridge::BridgeStore>>,
    agent: Arc<Agent>,
    access: Arc<Access>,
    works: HashMap<i64, WorkHandle>,
    /// A chat a work moved out of → where it went, so cards left behind still
    /// reach it. Messages there never do: the parent may start its own work.
    moved: HashMap<i64, i64>,
    moves: Option<mpsc::UnboundedReceiver<(i64, i64)>>,
    /// The DM lead's tool calls and its tasks' reports.
    lead: Option<mpsc::UnboundedReceiver<LeadRequest>>,
    /// `wait_tasks` calls waiting for a task to finish: (tasks, reply);
    /// no tasks is any.
    waiters: Vec<(Vec<i64>, oneshot::Sender<HostToolResult>)>,
    /// (lead, title, brief) → the task started for it and when, so a
    /// spawn_thread retried after a tool timeout returns the same task.
    recent_spawns: HashMap<(i64, String, String), (i64, Instant)>,
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
    participation: HashMap<i64, Option<proto::AgentParticipation>>,
    default_output_mode: OutputMode,
    /// Agent-only hops per thread tree: reply threads and subthreads count
    /// with the chat they hang off, so asking in a new thread doesn't reset it.
    loop_guards: LoopGuards,
    /// Chat → the root of its thread tree, the loop cap's scope.
    loop_roots: HashMap<i64, i64>,
    /// (chat, person) → when they were last told they can't use this agent,
    /// so a mention without access gets an answer instead of silence.
    access_notices: HashMap<(i64, i64), tokio::time::Instant>,
    skills: Option<SkillPublisher>,
    /// Skills by thread folder, briefly: Amp takes seconds to list them.
    listed_skills: HashMap<PathBuf, (tokio::time::Instant, Vec<Skill>)>,
    agent_profiles: Option<(BotAgentResolver, SqliteStore)>,
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
        let (lead_tx, lead) = mpsc::unbounded_channel();
        if let Some(tools) = &tools {
            tools.set_lead(lead_tx.clone(), config.dm_chat_id);
        }
        let names = Arc::new(api::Names::new(bot.clone()));
        let access = Arc::new(Access {
            bot: bot.clone(),
            owner_user_id: config.owner_user_id,
            names: names.clone(),
            cache: tokio::sync::Mutex::new(None),
            resolved: tokio::sync::Mutex::new(HashMap::new()),
            generation: std::sync::atomic::AtomicU64::new(0),
        });
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
            acp: config.acp,
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
            lead: lead_tx,
            names,
            dm_chat_id: config.dm_chat_id,
            gate_budget: std::sync::Mutex::new(DailySpeakGateBudget::default()),
            usage: std::sync::Mutex::new(Vec::new()),
            context: std::sync::Mutex::new(HashMap::new()),
            bound_projects: std::sync::Mutex::new(HashMap::new()),
        });
        Ok(Self {
            config,
            startup_activity: None,
            legacy_store: None,
            agent,
            access,
            works: HashMap::new(),
            moved,
            moves: Some(moves),
            lead: Some(lead),
            waiters: Vec::new(),
            recent_spawns: HashMap::new(),
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
            participation: HashMap::new(),
            default_output_mode: OutputMode::Detailed,
            loop_guards: LoopGuards::default(),
            loop_roots: HashMap::new(),
            access_notices: HashMap::new(),
            skills: None,
            listed_skills: HashMap::new(),
            agent_profiles: None,
        })
    }

    pub(crate) fn with_legacy_store(
        mut self,
        store: Arc<inline_agent_bridge::BridgeStore>,
    ) -> Self {
        self.legacy_store = Some(store);
        self
    }

    pub(crate) fn with_startup_activity(
        mut self,
        activity: crate::bridge::update_activity::Lease,
    ) -> Self {
        self.startup_activity = Some(activity);
        self
    }

    /// Lets threads pick their folder, among these and the harness's.
    pub(crate) fn with_folders(mut self, source: FolderSource) -> Self {
        self.folder_source = Some(source);
        self
    }

    /// Publishes installed skills and answers `/skill-name`.
    pub(crate) fn with_skills(mut self, publisher: SkillPublisher) -> Self {
        self.skills = Some(publisher);
        self
    }

    /// Applies Skilled Agents to the messages addressed to them.
    pub(crate) fn with_agent_profiles(
        mut self,
        resolver: BotAgentResolver,
        store: SqliteStore,
    ) -> Self {
        self.agent_profiles = Some((resolver, store));
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
        let _skill_sync = self.skills.clone().map(SkillPublisher::spawn);
        self.startup_activity.take();
        let mut heartbeat = tokio::time::interval(self.heartbeat().await);
        heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        tokio::pin!(shutdown);
        let mut moves = self.moves.take().expect("run once");
        let mut lead = self.lead.take().expect("run once");
        let mut connection = tokio::time::interval(CONNECTION_CHECK);
        connection.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let result = loop {
            tokio::select! {
                biased;
                _ = &mut shutdown => break Ok(()),
                // Before any delivery, so a subthread's first reply finds its work.
                Some((from, to)) = moves.recv() => self.moved_work(from, to),
                Some(request) = lead.recv() => self.lead_request(request).await,
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
                delivery = events.recv_delivery(), if !crate::bridge::update_activity::global().draining() => {
                    let Some(_delivery_activity) = crate::bridge::update_activity::global().enter() else { continue; };
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
        // Task reports no lead input took yet reach their lead again.
        let leads: HashSet<i64> = self
            .agent
            .ledger
            .lead_events()
            .unwrap_or_default()
            .into_iter()
            .map(|event| event.lead_chat_id)
            .collect();
        for lead in leads {
            self.deliver_lead_events(lead).await;
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
            ClientEvent::MessageWidgetCalled {
                interaction_id,
                chat_id,
                message_id,
                actor_user_id,
                widget_id,
                name,
                payload,
            } => {
                let toast = self
                    .on_widget_call(
                        interaction_id.get(),
                        chat_id.get(),
                        message_id.get(),
                        actor_user_id.get(),
                        &widget_call_text(widget_id, name, payload, message_id.get()),
                    )
                    .await;
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
                // A subthread of the owner's DM is part of the DM, as v1
                // treated it, whoever opened it.
                let own = bound.is_some()
                    || result.chat.as_ref().is_some_and(|chat| {
                        chat.created_by == Some(self.config.bot_user_id)
                            || chat.parent_chat_id == Some(self.config.dm_chat_id)
                    });
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

    /// Agents went back and forth here without a person: this agent stops
    /// answering other agents and says so, with one tap to allow more.
    /// The root of `chat_id`'s thread tree, cached.
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

    /// Answers a person who addressed the agent without access, at most once
    /// per chat every few hours, so they know to ask the owner instead of
    /// assuming the agent is broken.
    async fn access_notice(&mut self, chat_id: i64, group: &GroupMessage) {
        const QUIET: std::time::Duration = std::time::Duration::from_secs(6 * 60 * 60);
        let now = tokio::time::Instant::now();
        let key = (chat_id, group.author.user_id);
        if self
            .access_notices
            .get(&key)
            .is_some_and(|sent| now.duration_since(*sent) < QUIET)
        {
            return;
        }
        self.access_notices.insert(key, now);
        let owner = self.agent.names.of(self.config.owner_user_id).await;
        let text = format!(
            "I only take requests from {owner} and people they've added. {owner} can add you with /allowlist in their chat with {}.",
            self.config.agent_name
        );
        if let Err(error) = api::send_doc(
            &self.agent.bot,
            chat_id,
            Some(group.message_id),
            &paragraph(&text),
            None,
            Notify::Normal,
        )
        .await
        {
            log::warn!(target: "inline::bridge::v2", "access notice failed: {error}");
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
        let catalog = self.catalog_for_chat(chat_id).await;
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
                self.agent.record_limits(&catalog.usage);
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

    /// ACP commands and settings can depend on the thread's project. Do not
    /// reuse the installation-wide catalog for a different folder.
    async fn catalog_for_chat(&mut self, chat_id: i64) -> Catalog {
        if !matches!(
            self.config.vocabulary,
            Vocabulary::OpenCode | Vocabulary::Amp
        ) {
            return self.catalog().await;
        }
        match self
            .agent
            .harness
            .catalog(CatalogScope {
                folder: Some(self.thread_folder(chat_id)),
                session: self
                    .works
                    .get(&chat_id)
                    .and_then(WorkHandle::catalog_session),
            })
            .await
        {
            Ok(catalog) => {
                self.agent.record_limits(&catalog.usage);
                catalog
            }
            Err(error) => {
                log::warn!(target: "inline::bridge::v2", "chat={chat_id} catalog unavailable: {error}");
                Catalog::default()
            }
        }
    }

    /// The installed skill `/name` means in this thread, if any. Inline's
    /// commands win, as they do over the harness's.
    async fn skill_for_command(&mut self, chat_id: i64, name: &str) -> Option<Skill> {
        if INLINE_COMMANDS.contains(&name) {
            return None;
        }
        let catalog = self.skills.as_ref()?.catalog.clone();
        let folder = self.thread_folder(chat_id);
        let cached = self
            .listed_skills
            .get(&folder)
            .filter(|(at, _)| at.elapsed() < CATALOG_TTL)
            .map(|(_, skills)| skills.clone());
        let skills = match cached {
            Some(skills) => skills,
            None => {
                // A failed read isn't cached, so the next command tries again.
                let skills = catalog.list(&folder).await?;
                self.listed_skills
                    .insert(folder, (tokio::time::Instant::now(), skills.clone()));
                skills
            }
        };
        skills.into_iter().find(|skill| skill.answers_to(name))
    }

    /// Applies the thread's or mentioned Skilled Agent to a message. False
    /// when the message must not run.
    async fn apply_agent_profile(
        &self,
        message: &MessageRecord,
        chat_id: i64,
        input: &mut Input,
    ) -> bool {
        let Some((resolver, store)) = &self.agent_profiles else {
            return true;
        };
        let bot_user_id = self.config.bot_user_id;
        let thread_agent = store
            .dialog(InlineId::new(chat_id))
            .await
            .ok()
            .flatten()
            .and_then(|dialog| dialog.agent_context)
            .filter(|context| context.bot_user_id.get() == bot_user_id)
            .and_then(|context| context.agent_id)
            .map(InlineId::get);
        let Some(agent_id) = thread_agent.or_else(|| mentioned_agent_id(message, bot_user_id))
        else {
            return true;
        };
        match resolver.resolve(agent_id).await {
            Some(agent) if agent.bot_user_id == bot_user_id => {
                input.content.text =
                    skills::specialized_task(self.config.vocabulary, &agent, &input.content.text);
                true
            }
            Some(_) => {
                self.reply(
                    chat_id,
                    message.message_id.get(),
                    "The selected Skilled Agent does not belong to this provider.",
                )
                .await;
                false
            }
            None => {
                self.reply(
                    chat_id,
                    message.message_id.get(),
                    "The selected Skilled Agent is unavailable, so I’m continuing with this bot’s default behavior.",
                )
                .await;
                true
            }
        }
    }

    async fn forwards_command(&mut self, chat_id: i64, name: &str, grants: Grants) -> bool {
        if !harness_command_candidate(
            self.config.vocabulary,
            self.agent.harness.describe().manifest.as_ref(),
            name,
        ) || (INLINE_COMMANDS.contains(&name) && !grants.permits(Operation::Steer))
        {
            return false;
        }
        self.catalog_for_chat(chat_id)
            .await
            .commands
            .iter()
            .any(|command| command.name == name)
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
            .is_some_and(|connection| !connection.session_ref.is_empty())
            || self.v1_session(chat_id).is_some();
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
        let previous = self
            .thread_settings
            .entry(chat_id)
            .or_default()
            .folder
            .replace(folder.clone());
        self.save_thread(chat_id);
        if let Some(previous) = previous.filter(|previous| *previous != folder) {
            workspaces::forget(&previous);
        }
    }

    /// The folder a choice id stands for in this thread. No project is the
    /// thread's own folder in Documents/Inline, made now when it has none.
    fn chosen_folder(
        &self,
        chat_id: i64,
        id: &str,
        folders: Option<&Folders>,
    ) -> Result<PathBuf, String> {
        if id == NO_PROJECT_ID {
            let current = self.thread_folder(chat_id);
            return if workspaces::is_managed(&current) {
                std::fs::create_dir_all(&current)
                    .map(|()| current)
                    .map_err(|error| format!("Couldn't make the No project folder: {error}"))
            } else {
                workspaces::allocate(&self.config.agent_name, chat_id)
            };
        }
        folders
            .and_then(|folders| folders.folder(id).map(PathBuf::from))
            .ok_or_else(|| "That folder is not available on this machine.".to_owned())
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
        let folders = self.folders(&catalog);
        let folder = match self.chosen_folder(chat_id, &project, folders.as_ref()) {
            Ok(folder) => folder,
            Err(reason) => {
                log::warn!(target: "inline::bridge::v2", "chat={chat_id} project={project}: {reason}; the thread keeps its folder");
                return;
            }
        };
        if self.thread_folder(chat_id) == folder {
            return;
        }
        let alive = self
            .works
            .get(&chat_id)
            .is_some_and(|work| !work.task.is_finished());
        let result = if alive || self.session_known(chat_id).await.is_ok() {
            self.choose_folder(chat_id, folder.clone()).await
        } else {
            self.set_thread_folder(chat_id, folder.clone());
            Ok(())
        };
        if let Err(reason) = result {
            workspaces::forget(&folder);
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
            compact_supported: native_operation_supported(
                self.config.vocabulary,
                self.agent.harness.describe().manifest.as_ref(),
                OpKind::Compact,
            ),
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
        let catalog = self.catalog_for_chat(chat_id).await;
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
                let folders = self.folders(&catalog);
                let chosen = match self.chosen_folder(chat_id, &id, folders.as_ref()) {
                    Ok(folder) if folder == self.thread_folder(chat_id) => Ok(()),
                    Ok(folder) => {
                        let chosen = self.choose_folder(chat_id, folder.clone()).await;
                        if chosen.is_err() {
                            workspaces::forget(&folder);
                        }
                        chosen
                    }
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
            let catalog = self.catalog_for_chat(chat_id).await;
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
                let kind = if name == "compact" {
                    OpKind::Compact
                } else {
                    OpKind::Clear
                };
                if !native_operation_supported(
                    self.config.vocabulary,
                    self.agent.harness.describe().manifest.as_ref(),
                    kind,
                ) {
                    return format!(
                        "{} cannot {name} this session. You can keep chatting here, or use /new for a fresh thread.",
                        self.config.agent_name
                    );
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
            "terminal" if self.config.acp => {
                format!(
                    "Terminal handoff is not available for {}. Use /release to close this session, or keep chatting here.",
                    self.config.agent_name
                )
            }
            "status" => self.status(chat_id, actor).await,
            "help" => {
                let mut help = help_text(
                    &self.config.agent_name,
                    self.config.vocabulary,
                    self.config.acp,
                );
                if matches!(
                    self.config.vocabulary,
                    Vocabulary::OpenCode | Vocabulary::Amp
                ) {
                    let catalog = self.catalog_for_chat(chat_id).await;
                    let info = self.agent.harness.describe();
                    let commands: Vec<_> = catalog
                        .commands
                        .iter()
                        .filter(|command| {
                            harness_command_candidate(
                                self.config.vocabulary,
                                info.manifest.as_ref(),
                                &command.name,
                            )
                        })
                        .take(24)
                        .collect();
                    if !commands.is_empty() {
                        help.push_str("\n\nProvider commands for this thread:");
                        for command in commands {
                            let name: String = command.name.chars().take(64).collect();
                            help.push_str(&format!("\n/{name}"));
                            let description: String = command
                                .description
                                .lines()
                                .next()
                                .unwrap_or_default()
                                .chars()
                                .take(120)
                                .collect();
                            if !description.is_empty() {
                                help.push_str(&format!(" · {description}"));
                            }
                        }
                    }
                }
                help
            }
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
                    // OpenCode's plan agent is a mode; build is its default.
                    ("plan", Vocabulary::OpenCode) if !self.config.acp => SessionOp::Mode(
                        if arguments.trim().eq_ignore_ascii_case("off") {
                            "build"
                        } else {
                            "plan"
                        }
                        .to_owned(),
                    ),
                    ("undo", Vocabulary::OpenCode) if !self.config.acp => SessionOp::Undo,
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
            "allowlist" | "share" => self.allowlist(actor, arguments, mentions).await,
            "unshare" => {
                self.allowlist(actor, &format!("remove {arguments}"), mentions)
                    .await
            }
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
                    "Only you can use me. Add someone with /share @name.".to_owned()
                }
                Ok(result) => {
                    let mut names = Vec::new();
                    for grant in result.grants {
                        names.push(self.agent.names.of(grant.user_id).await);
                    }
                    format!(
                        "People who can use me: {}. Remove someone with /unshare @name.",
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
        let catalog = self.catalog_for_chat(chat_id).await;
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
                Vocabulary::OpenCode => "OpenCode",
                Vocabulary::Amp => "Amp",
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
        self.intake(message, None).await.map(drop)
    }

    /// A viewer's `inline.action` call from a widget in this agent's message:
    /// input from them as if they had replied to that message with
    /// `text`, under the same access and addressing rules. The toast for
    /// the viewer: none when it reached the agent.
    async fn on_widget_call(
        &mut self,
        interaction_id: i64,
        chat_id: i64,
        message_id: i64,
        actor: i64,
        text: &str,
    ) -> Option<String> {
        let message = MessageRecord {
            chat_id: InlineId::new(chat_id),
            message_id: InlineId::new(message_id),
            sender_id: InlineId::new(actor),
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |elapsed| elapsed.as_secs() as i64)
                .max(self.config.accept_messages_after),
            is_outgoing: false,
            content: inline_client::MessageContent::Text {
                text: text.to_owned(),
            },
            reply_to_message_id: Some(InlineId::new(message_id)),
            metadata: Default::default(),
            transaction: None,
        };
        match self.intake(&message, Some(interaction_id)).await {
            Ok(Some(IntakeDecision::Act { .. })) => None,
            Ok(decision) => Some(widget_call_refusal(decision).to_owned()),
            Err(error) => {
                log::warn!(target: "inline::bridge::v2", "chat={chat_id} widget call failed: {error}");
                Some("The agent couldn't take this. Try again.".to_owned())
            }
        }
    }

    /// One message's intake, and the decision it got (`None` when it was
    /// never weighed: a replay, the agent's own, a service row). With
    /// `widget_call` (its interaction ID) the message stands in for a widget
    /// call: it is acted on or refused, never kept as context.
    async fn intake(
        &mut self,
        message: &MessageRecord,
        widget_call: Option<i64>,
    ) -> Result<Option<IntakeDecision>, Box<dyn std::error::Error>> {
        // Message updates and reconnect catch-up can redeliver old input.
        // v2 has its own ledger, but work already accepted by v1 must never
        // run again after enabling v2. Read its receipt without changing it.
        if let Some(store) = &self.legacy_store
            && store.event_processed(&format!(
                "inline-message-{}-{}",
                message.chat_id, message.message_id
            ))?
        {
            return Ok(None);
        }
        if message.is_outgoing
            || message.timestamp < self.config.accept_messages_after
            // Service notices use the actor's user ID, but are not input
            // from that person, including in a followed or owned thread.
            || message.metadata.is_service
            || message.metadata.agent_session.is_some()
        {
            return Ok(None);
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
        let sender_is_bot = message.metadata.sender_is_bot.unwrap_or(false);
        // The person an agent sender acts for (`User.bot_info`).
        let author_owner = if sender_is_bot {
            self.agent.names.owner_of(message.sender_id.get()).await
        } else {
            None
        };
        let (reply_author, reply_mentions_author) = match message.reply_to_message_id {
            Some(id) => {
                let (author, mentions) = self
                    .replied_to(chat_id, id.get(), message.sender_id.get())
                    .await;
                (Some(author), mentions)
            }
            None => (None, false),
        };
        let group = group_message(
            message,
            MessageFacts {
                bot_user_id: self.config.bot_user_id,
                bot_username: &self.config.bot_username,
                conversation,
                reply_author,
                reply_mentions_author,
                author_owner,
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
        if widget_call.is_none()
            && !group.author.kind.is_agent()
            && matches!(
                decision,
                IntakeDecision::Observe {
                    reason: ObserveReason::NotGranted,
                    ..
                } | IntakeDecision::Skip {
                    reason: inline_agent_bridge::group::SkipReason::NotGranted,
                }
            )
        {
            self.access_notice(chat_id, &group).await;
        }
        match decision {
            IntakeDecision::Act { join, required, .. } => {
                if join
                    && conversation == Conversation::Group
                    && let Err(error) =
                        api::join(&self.agent.bot, chat_id, self.config.bot_user_id).await
                {
                    log::warn!(target: "inline::bridge::v2", "join failed: {error}");
                }
                self.act(
                    message,
                    &group,
                    &decision,
                    required,
                    grants,
                    participation,
                    widget_call,
                )
                .await?;
                Ok(Some(decision))
            }
            IntakeDecision::Observe { .. } if widget_call.is_some() => Ok(Some(decision)),
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
                Ok(Some(decision))
            }
            IntakeDecision::Skip { .. } => Ok(Some(decision)),
        }
    }

    /// Who wrote the replied-to message (0 when unknown), and whether it
    /// mentioned `sender`: a reply to this agent's message from someone it
    /// asked is the answer it asked for (a hand-back). Read from Inline, not
    /// remembered, so it holds across restarts.
    async fn replied_to(&self, chat_id: i64, reply_id: i64, sender: i64) -> (i64, bool) {
        let mine = self.agent.sent.lock().expect("sent").contains(&reply_id);
        let known = if mine { self.config.bot_user_id } else { 0 };
        match api::get_messages(&self.agent.bot, chat_id, vec![reply_id]).await {
            Ok(messages) => messages
                .iter()
                .find(|replied| replied.id == reply_id)
                .map_or((known, false), |replied| {
                    (replied.from_id, asked(replied, sender))
                }),
            Err(error) => {
                log::debug!(target: "inline::bridge::v2", "chat={chat_id} reply lookup failed: {error}");
                (known, false)
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    async fn act(
        &mut self,
        message: &MessageRecord,
        group: &GroupMessage,
        decision: &IntakeDecision,
        required: Operation,
        grants: Grants,
        participation: Option<proto::AgentParticipation>,
        widget_call: Option<i64>,
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
            Some("terminal") if !self.config.acp => {
                Some(Control::Release(ReleaseCause::ContinueInTerminal))
            }
            _ => None,
        };
        // Advertised commands go to the harness as typed. ACP may advertise
        // a slash command for an operation its structured API cannot perform.
        // Inline's controls and access/settings commands still win collisions.
        let forward = match group.command() {
            Some((name, _)) if control.is_none() => {
                self.forwards_command(chat_id, name, grants).await
            }
            _ => false,
        };
        let skill = match group.command() {
            Some((name, _)) if control.is_none() && !forward => {
                self.skill_for_command(chat_id, name).await
            }
            _ => None,
        };
        if let Some((name, _)) = group.command()
            && control.is_none()
            && name != "queue"
            && !forward
            && skill.is_none()
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
            // /stop in the DM also stops the lead's running tasks.
            let stopped_tasks =
                if chat_id == self.config.dm_chat_id && matches!(control, Control::Stop) {
                    self.stop_tasks(chat_id, group.author.user_id).await
                } else {
                    0
                };
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
            let toast = match (stopped_tasks, toast) {
                (0, toast) => toast,
                (count, None) => Some(format!(
                    "Also stopped {count} running task{}.",
                    plural(count)
                )),
                (count, Some(toast)) if toast.starts_with("Nothing is running") => {
                    Some(format!("Stopped {count} running task{}.", plural(count)))
                }
                (count, Some(toast)) => Some(format!(
                    "{toast} Stopped {count} running task{}.",
                    plural(count)
                )),
            };
            if let Some(toast) = toast {
                self.reply(chat_id, group.message_id, &toast).await;
            }
            return Ok(());
        }
        // Each widget call is its own input, though calls share their message.
        let kind = widget_call.map_or_else(
            || "direct".to_owned(),
            |interaction| format!("widget-{interaction}"),
        );
        let id = input_id(self.config.bot_user_id, chat_id, group.message_id, &kind);
        // Joining a group thread: the recent conversation comes along as
        // untrusted context (spec §5.3).
        let context =
            if group.conversation == Conversation::Group && !self.works.contains_key(&chat_id) {
                let anchor = self.anchor_context(chat_id).await;
                with_anchor(self.join_context(group).await, anchor)
            } else if group.conversation == Conversation::WorkThread
                && !self.works.contains_key(&chat_id)
                && !self.session_known(chat_id).await.unwrap_or(true)
            {
                // A reply thread someone opened (in the DM, say) starts
                // from the message it hangs off.
                with_anchor(None, self.anchor_context(chat_id).await)
            } else {
                None
            };
        let input = if forward || skill.is_some() {
            let text = match (&skill, group.command()) {
                (Some(skill), Some((name, _))) => skills::activation_text(
                    self.config.vocabulary,
                    &skill.key,
                    command_arguments(&group.text, name),
                ),
                _ => harness_command_text(&group.text, &self.config.bot_username),
            };
            Some(Input {
                id: InputId::new(id.clone())?,
                content: InputContent {
                    text,
                    attachments: Vec::new(),
                    context: None,
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
        if group.command().is_none()
            && !self.apply_agent_profile(message, chat_id, &mut input).await
        {
            self.agent.ledger.set(&id, InputState::Consumed)?;
            return Ok(());
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
                // An agent's answer to this agent's request is not quoted:
                // quoting would wake it again.
                answer_reply: matches!(group.conversation, Conversation::Group)
                    && !(required == Operation::HandBack && group.author.kind.is_agent()),
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

    /// Where a reply thread or subthread hangs: its parent thread and the
    /// message it started from, as untrusted context.
    async fn anchor_context(&self, chat_id: i64) -> Option<String> {
        let chat = api::get_chat(&self.agent.bot, chat_id).await.ok()?.chat?;
        let parent = chat.parent_chat_id?;
        let title = self
            .agent
            .bot
            .chat_state(InlineId::new(parent))
            .await
            .ok()
            .and_then(|state| state.dialog)
            .and_then(|dialog| dialog.title);
        let place = if parent == self.config.dm_chat_id {
            "your owner's DM".to_owned()
        } else {
            match title {
                Some(title) => format!("\"{title}\""),
                None => "another thread".to_owned(),
            }
        };
        let mut text =
            format!("This thread is a subthread of {place} (inline://chat?id={parent}).");
        if let Some(message_id) = chat.parent_message_id
            && let Ok(messages) = api::get_messages(&self.agent.bot, parent, vec![message_id]).await
            && let Some(message) = messages.into_iter().next()
        {
            let author = self.agent.names.of(message.from_id).await;
            let body: String = message
                .message
                .unwrap_or_default()
                .chars()
                .take(ANCHOR_CHARS)
                .collect();
            text.push_str(&format!(
                " It started from this message there (message {message_id}):\n{author}: {body}"
            ));
        }
        Some(text)
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
        let mut settings = self
            .thread_settings
            .get(&chat_id)
            .cloned()
            .unwrap_or_default();
        let legacy = self.v1_session(chat_id);
        // Keep the folder even when Inline already knows the legacy session.
        // Save it before adoption, so the next restart does not use the default.
        if settings.folder.is_none()
            && let Some((native, Some(folder))) = &legacy
            && result.connection.as_ref().is_none_or(|connection| {
                connection.session_ref.is_empty() || connection.session_ref == native.as_str()
            })
        {
            settings.folder = Some(folder.clone());
            self.thread_settings.insert(chat_id, settings.clone());
            self.save_thread(chat_id);
        }
        let known = match result.connection {
            Some(connection) if !connection.session_ref.is_empty() => Known {
                agent_session_id: connection.agent_session.map(|session| session.id),
                native: Some(ProviderSessionId::new(connection.session_ref)?),
                from_v1: false,
                fork_from: None,
                fork_at: None,
            },
            // Inline knows no work here: a thread v1 served goes on in its
            // session and folder.
            _ => match legacy {
                Some((native, _)) => Known {
                    agent_session_id: None,
                    native: Some(native),
                    from_v1: true,
                    fork_from: None,
                    fork_at: None,
                },
                None => Known::default(),
            },
        };
        let mode = self.effective_mode(participation);
        // A new work here takes the chat back from one that moved out.
        self.agent.ledger.forget_move(chat_id)?;
        self.moved.remove(&chat_id);
        // The work knows its session from now on.
        self.known_sessions.remove(&chat_id);
        self.works.insert(
            chat_id,
            super::work::spawn(self.agent.clone(), chat_id, known, mode, settings),
        );
        // A new DM work takes the task reports waiting for its next input.
        if chat_id == self.config.dm_chat_id {
            let reports: Vec<LeadEventRecord> = self
                .agent
                .ledger
                .lead_events()
                .unwrap_or_default()
                .into_iter()
                .filter(|report| report.lead_chat_id == chat_id)
                .collect();
            if !reports.is_empty()
                && let Some(work) = self.works.get(&chat_id)
            {
                let _ = work.tx.send(Command::LeadReports(reports)).await;
            }
        }
        Ok(())
    }

    /// The native session and folder v1 kept for a thread it served before
    /// this bridge moved to v2.
    fn v1_session(&self, chat_id: i64) -> Option<(ProviderSessionId, Option<PathBuf>)> {
        let store = self.legacy_store.as_ref()?;
        let installation =
            inline_agent_bridge::InstallationId::new(self.config.installation_id.clone()).ok()?;
        let (workspace_id, _, native) = store
            .latest_binding_for_chat(&installation, chat_id)
            .map_err(|error| {
                log::warn!(target: "inline::bridge::v2", "cannot read v1 sessions: {error}");
            })
            .ok()??;
        let folder = store
            .workspace(&installation, &workspace_id)
            .ok()
            .flatten()
            .map(|workspace| workspace.path)
            .filter(|path| path.is_dir());
        Some((native, folder))
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
        // The new thread works where its parent does; a parent in No project
        // gives it a No project folder of its own.
        if let Some(folder) = self
            .thread_settings
            .get(&group.chat_id)
            .and_then(|settings| settings.folder.clone())
        {
            let folder = if workspaces::is_managed(&folder) {
                workspaces::allocate(&self.config.agent_name, chat_id)?
            } else {
                folder
            };
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

// ---------------------------------------------------------------
// The DM lead and its task subthreads (see `lead.rs`)
// ---------------------------------------------------------------

impl Runtime {
    async fn lead_request(&mut self, request: LeadRequest) {
        // The tool gave up waiting: acting now would surprise the lead, which
        // was told it may not have happened.
        let abandoned = match &request {
            LeadRequest::Spawn { reply, .. }
            | LeadRequest::Send { reply, .. }
            | LeadRequest::Stop { reply, .. }
            | LeadRequest::List { reply, .. }
            | LeadRequest::Wait { reply, .. }
            | LeadRequest::NotifyOwner { reply, .. } => reply.is_closed(),
            LeadRequest::Report(_) => false,
        };
        if abandoned {
            return;
        }
        match request {
            LeadRequest::Spawn {
                caller,
                task,
                reply,
            } => {
                let result = match self.spawn_task(caller, task).await {
                    Ok(result) => result,
                    Err(error) => HostToolResult::failure(error),
                };
                let _ = reply.send(result);
            }
            LeadRequest::Wait {
                caller,
                targets,
                reply,
            } => {
                if let Err(error) = self.lead_only(caller) {
                    let _ = reply.send(HostToolResult::failure(error));
                } else if let Some(result) = self.wait_now(caller, &targets) {
                    let _ = reply.send(result);
                } else {
                    self.waiters.retain(|(_, reply)| !reply.is_closed());
                    self.waiters.push((targets, reply));
                }
            }
            LeadRequest::Send {
                caller,
                target,
                text,
                mode,
                interrupt,
                call_id,
                reply,
            } => {
                let result = match self
                    .send_to_task(caller, target, text, mode, interrupt, &call_id)
                    .await
                {
                    Ok(result) => result,
                    Err(error) => HostToolResult::failure(error),
                };
                let _ = reply.send(result);
            }
            LeadRequest::Stop {
                caller,
                target,
                reply,
            } => {
                let result = match self.stop_task(caller, target).await {
                    Ok(result) => result,
                    Err(error) => HostToolResult::failure(error),
                };
                let _ = reply.send(result);
            }
            LeadRequest::List { caller, reply } => {
                let result = match self.list_tasks(caller) {
                    Ok(result) => result,
                    Err(error) => HostToolResult::failure(error),
                };
                let _ = reply.send(result);
            }
            LeadRequest::NotifyOwner {
                caller,
                text,
                call_id,
                reply,
            } => {
                let result = match self.notify_owner(caller, text, &call_id).await {
                    Ok(result) => result,
                    Err(error) => HostToolResult::failure(error),
                };
                let _ = reply.send(result);
            }
            LeadRequest::Report(report) => self.task_report(report).await,
        }
    }

    /// A task with a turn running or its session still starting.
    fn task_running(&self, chat: i64) -> bool {
        self.works.get(&chat).is_some_and(|work| {
            !work.task.is_finished()
                && matches!(*work.phase.borrow(), WorkPhase::Running | WorkPhase::None)
        })
    }

    /// Stops a task's running turn. Bounded, so one busy work never holds
    /// up every chat.
    async fn halt_task(&self, chat: i64, actor: i64) -> Option<String> {
        let phase = self.works.get(&chat).map(|work| *work.phase.borrow());
        match phase {
            Some(WorkPhase::Running) => {}
            Some(WorkPhase::None) => {
                return Some(
                    "It is still starting, so there is nothing to stop yet; its brief will run."
                        .to_owned(),
                );
            }
            _ => return Some("Nothing is running there.".to_owned()),
        }
        tokio::time::timeout(
            TASK_CONTROL_TIMEOUT,
            self.ask(chat, |reply| Command::Control {
                control: Control::Stop,
                actor,
                reply,
            }),
        )
        .await
        .unwrap_or_else(|_| Some("The task did not answer in time.".to_owned()))
    }

    /// Records a task's status and shows it on the lead's card.
    async fn set_task_status(&self, child_chat_id: i64, status: &str) {
        let Ok(Some(child)) = self.agent.ledger.child(child_chat_id) else {
            return;
        };
        let _ = self.agent.ledger.set_child_status(child_chat_id, status);
        if let Some(card) = child.card_message_id
            && let Err(error) = api::edit_markdown(
                &self.agent.bot,
                child.lead_chat_id,
                card,
                &card_text(&self.config.agent_name, &child.title, child_chat_id, status),
            )
            .await
        {
            log::warn!(target: "inline::bridge::v2", "task card edit failed: {error}");
        }
    }

    fn lead_only(&self, caller: i64) -> Result<(), String> {
        if caller == self.config.dm_chat_id {
            Ok(())
        } else {
            Err("Only the session in your owner's DM runs task subthreads.".to_owned())
        }
    }

    /// `spawn_thread`: a task subthread of the DM with a fresh session that
    /// inherits the lead's settings, the brief as its first visible message,
    /// and the lead's card in the DM.
    async fn spawn_task(&mut self, caller: i64, task: SpawnTask) -> Result<HostToolResult, String> {
        self.lead_only(caller)?;
        self.recent_spawns
            .retain(|_, (_, at)| at.elapsed() < SPAWN_RETRY_WINDOW);
        let key = (caller, task.title.clone(), task.brief.clone());
        if let Some((child, _)) = self.recent_spawns.get(&key) {
            return Ok(spawned(*child, &task.title, true));
        }
        let (fork_from, fork_at) = if task.fork {
            let (session, turn) = self
                .works
                .get(&caller)
                .and_then(WorkHandle::fork_point)
                .ok_or("Your session is not open here, so a task cannot fork it. Start it with a brief.")?;
            (Some(session), turn)
        } else {
            (None, None)
        };
        let running = self
            .agent
            .ledger
            .children(caller)
            .map_err(|error| format!("Could not read your tasks: {error}"))?
            .into_iter()
            .filter(|(chat, _)| self.task_running(*chat))
            .count();
        if running >= MAX_RUNNING_TASKS {
            return Err(format!(
                "{running} tasks are already running. Wait for one to finish, or stop one with stop_thread."
            ));
        }
        // Listing can start a harness process; only a choice needs it.
        let catalog = if task.model.is_some() || task.reasoning.is_some() || task.project.is_some()
        {
            self.catalog().await
        } else {
            Catalog::default()
        };
        let mut settings = self
            .thread_settings
            .get(&caller)
            .cloned()
            .unwrap_or_default();
        settings.folder = None;
        if let Some(model) = task.model.clone() {
            if !catalog.models.is_empty()
                && !catalog.models.iter().any(|option| option.value == model)
            {
                let models: Vec<&str> = catalog
                    .models
                    .iter()
                    .map(|option| option.value.as_str())
                    .collect();
                return Err(format!(
                    "Unknown model {model}. Models: {}.",
                    models.join(", ")
                ));
            }
            settings.model = Some(model);
        }
        if let Some(reasoning) = task.reasoning.clone() {
            let model = settings.model.as_deref();
            let option = catalog
                .models
                .iter()
                .find(|option| Some(option.value.as_str()) == model)
                .or_else(|| catalog.models.iter().find(|option| option.is_default));
            if let Some(option) = option
                && !option.reasoning.is_empty()
                && !option
                    .reasoning
                    .iter()
                    .any(|effort| effort.value == reasoning)
            {
                let efforts: Vec<&str> = option
                    .reasoning
                    .iter()
                    .map(|effort| effort.value.as_str())
                    .collect();
                return Err(format!(
                    "Unknown reasoning effort {reasoning} for {}. Efforts: {}.",
                    option.value,
                    efforts.join(", ")
                ));
            }
            settings.effort = Some(reasoning);
        }
        let folders = self.folders(&catalog);
        if let Some(project) = task.project.as_deref()
            && project != NO_PROJECT_ID
            && folders
                .as_ref()
                .and_then(|folders| folders.folder(project))
                .is_none()
        {
            let options = folders
                .map(|folders| {
                    folders
                        .options()
                        .into_iter()
                        .map(|folder| format!("{} ({})", folder.id, folder.label))
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            return Err(format!("Unknown project {project}. Projects: {options}."));
        }
        let created = self
            .agent
            .bot
            .create_reply_thread(CreateReplyThreadRequest {
                parent_chat_id: InlineId::new(caller),
                parent_message_id: None,
                title: Some(task.title.clone()),
                description: None,
                emoji: None,
                participants: Vec::new(),
                agent_context: None,
            })
            .await
            .map_err(|error| format!("Inline could not create the subthread: {error}"))?;
        let child = created.chat_id.get();
        self.own_threads.insert(child, true);
        self.recent_spawns.insert(key, (child, Instant::now()));
        // The task works in the project chosen for it, else the lead's; a
        // lead in No project gives it a No project folder of its own.
        let folder = match task.project.as_deref() {
            Some(project) => Some(self.chosen_folder(child, project, folders.as_ref())?),
            None => match self
                .thread_settings
                .get(&caller)
                .and_then(|settings| settings.folder.clone())
            {
                Some(folder) if workspaces::is_managed(&folder) => {
                    Some(workspaces::allocate(&self.config.agent_name, child)?)
                }
                folder => folder,
            },
        };
        settings.folder = folder;
        self.thread_settings.insert(child, settings.clone());
        self.save_thread(child);
        let card = api::send_markdown(
            &self.agent.bot,
            caller,
            None,
            &card_text(&self.config.agent_name, &task.title, child, "running"),
            crate::bridge::helpers::interaction_random_id("v2-lead-card", &task.call_id).get(),
        )
        .await
        .map_err(|error| log::warn!(target: "inline::bridge::v2", "task card failed: {error}"))
        .ok();
        if let Some(card) = card {
            self.agent.sent.lock().expect("sent").insert(card);
        }
        self.agent
            .ledger
            .add_child(
                child,
                &ChildRecord {
                    lead_chat_id: caller,
                    lead_session_id: self
                        .works
                        .get(&caller)
                        .and_then(WorkHandle::agent_session_id),
                    title: task.title.clone(),
                    card_message_id: card,
                    status: Some(DIRECTED.to_owned()),
                },
            )
            .map_err(|error| format!("Could not record the task: {error}"))?;
        let mode = self.effective_mode(None);
        self.works.insert(
            child,
            super::work::spawn(
                self.agent.clone(),
                child,
                Known {
                    fork_from,
                    fork_at,
                    ..Known::default()
                },
                mode,
                settings,
            ),
        );
        if let Err(error) = self
            .direct_task(
                child,
                &format!("**Task**\n\n{}", task.brief),
                task.brief,
                Some(TASK_INSTRUCTIONS),
                Delivery::Turn,
                crate::bridge::helpers::interaction_random_id("v2-lead-task", &task.call_id).get(),
            )
            .await
        {
            // An empty task holds no slot; its thread stays for a retry by hand.
            if let Some(work) = self.works.remove(&child) {
                work.task.abort();
            }
            self.recent_spawns.retain(|_, (task, _)| *task != child);
            self.set_task_status(child, "failed to start").await;
            return Err(format!(
                "The task's thread {child} was created but its brief was not delivered: {error}"
            ));
        }
        Ok(spawned(child, &task.title, false))
    }

    /// Posts the lead's direction in a task's thread and gives it to its
    /// work as a message typed there would: a turn, or a steer of the
    /// running one.
    async fn direct_task(
        &mut self,
        chat: i64,
        visible: &str,
        text: String,
        instructions: Option<&str>,
        delivery: Delivery,
        // Stable per tool call, so a retry posts the same message.
        random_id: i64,
    ) -> Result<(), String> {
        let message_id = api::send_markdown(&self.agent.bot, chat, None, visible, random_id)
            .await
            .map_err(|error| format!("Inline could not post in the thread: {error}"))?;
        self.agent.sent.lock().expect("sent").insert(message_id);
        let id = input_id(self.config.bot_user_id, chat, message_id, "lead");
        let begun = self
            .agent
            .ledger
            .begin(&id, chat, message_id, self.config.owner_user_id)
            .map_err(|error| format!("Could not record the direction: {error}"))?;
        // A retried tool call posts the same message; it ran already.
        if let Begin::Seen(_) = begun {
            return Ok(());
        }
        self.ensure_work(chat, None)
            .await
            .map_err(|error| error.to_string())?;
        let mut content = InputContent::text(text);
        if let Some(instructions) = instructions {
            content.context = Some(inline_agent_bridge::TurnContext {
                instructions: instructions.to_owned(),
                conversation: String::new(),
            });
        }
        let input = Input {
            id: InputId::new(id).map_err(|error| error.to_string())?,
            content,
            origin: inline_agent_bridge::harness::Origin::Agent {
                bot: UserId(self.config.bot_user_id),
                work: inline_agent_bridge::harness::WorkRef {
                    chat: inline_agent_bridge::harness::ChatId(self.config.dm_chat_id),
                    session: None,
                },
            },
            delivery,
        };
        let pending = PendingInput {
            id: input.id.clone(),
            // The lead acts for its owner.
            sender: UserId(self.config.owner_user_id),
            required: Operation::StartWork,
        };
        let work = self
            .works
            .get(&chat)
            .ok_or("The thread's work did not start.")?;
        work.tx
            .send(Command::Input {
                input: Box::new(input),
                pending,
                message_id,
                answer_reply: false,
                reply_to: None,
            })
            .await
            .map_err(|_| "The thread's work stopped. Try again.".to_owned())
    }

    /// The threads a lead may direct: its tasks and this agent's own work
    /// threads. Anywhere else it posts with send_message.
    async fn directable(&mut self, caller: i64, target: i64) -> Result<(), String> {
        self.lead_only(caller)?;
        if target == caller {
            return Err("That is this thread.".to_owned());
        }
        let task = matches!(self.agent.ledger.child(target), Ok(Some(_)));
        if task || self.is_own_thread(target).await {
            Ok(())
        } else {
            Err("Only your task subthreads and your own work threads take direction. Use send_message to post elsewhere.".to_owned())
        }
    }

    async fn send_to_task(
        &mut self,
        caller: i64,
        target: i64,
        text: String,
        mode: SendMode,
        interrupt: bool,
        call_id: &str,
    ) -> Result<HostToolResult, String> {
        self.directable(caller, target).await?;
        if mode == SendMode::Note {
            return self.note_task(target, text, call_id).await;
        }
        self.set_task_status(target, DIRECTED).await;
        // Queue only means something while a turn runs.
        let running = self
            .works
            .get(&target)
            .is_some_and(|work| *work.phase.borrow() == WorkPhase::Running);
        let queued = mode == SendMode::Queue && running && !interrupt;
        let delivery = if queued {
            Delivery::Queue
        } else {
            Delivery::Turn
        };
        if interrupt
            && self
                .works
                .get(&target)
                .is_some_and(|work| *work.phase.borrow() == WorkPhase::Running)
        {
            let _ = self.halt_task(target, self.config.owner_user_id).await;
        }
        self.direct_task(
            target,
            &format!("**From the DM**\n\n{text}"),
            text,
            None,
            delivery,
            crate::bridge::helpers::interaction_random_id("v2-lead-send", call_id).get(),
        )
        .await?;
        Ok(HostToolResult::success(
            json!({
                "chat_id": target,
                "sent": true,
                "queued": queued,
            })
            .to_string(),
        ))
    }

    /// `send_to_thread` mode note: posted there, and context for the task's
    /// next turn without starting one (Codex's queue-only `send_message`).
    async fn note_task(
        &mut self,
        target: i64,
        text: String,
        call_id: &str,
    ) -> Result<HostToolResult, String> {
        let message_id = api::send_markdown(
            &self.agent.bot,
            target,
            None,
            &format!("**Note from the DM**\n\n{text}"),
            crate::bridge::helpers::interaction_random_id("v2-lead-note", call_id).get(),
        )
        .await
        .map_err(|error| format!("Inline could not post in the thread: {error}"))?;
        self.agent.sent.lock().expect("sent").insert(message_id);
        self.ensure_work(target, None)
            .await
            .map_err(|error| error.to_string())?;
        if let Some(work) = self.works.get(&target) {
            let _ = work
                .tx
                .send(Command::Passive {
                    message: ContextMessage {
                        message_id,
                        author_name: format!(
                            "{} (your lead in your owner's DM)",
                            self.config.agent_name
                        ),
                        role: ContextAuthorRole::Agent,
                        reply_to: None,
                        text,
                    },
                })
                .await;
        }
        Ok(HostToolResult::success(
            json!({"chat_id": target, "noted": true}).to_string(),
        ))
    }

    /// `wait_tasks` answered at once: a named task already finished, or
    /// nothing is running to wait for.
    fn wait_now(&self, lead: i64, targets: &[i64]) -> Option<HostToolResult> {
        let children = self.agent.ledger.children(lead).unwrap_or_default();
        let running = |chat: i64| {
            children
                .iter()
                .any(|(child, record)| *child == chat && record.status.as_deref() == Some(DIRECTED))
        };
        let finished: Vec<Value> = targets
            .iter()
            .filter(|chat| !running(**chat))
            .filter_map(|chat| {
                children
                    .iter()
                    .find(|(child, _)| child == chat)
                    .map(|(child, record)| {
                        json!({
                            "chat_id": child,
                            "title": record.title,
                            "status": record.status,
                            "note": "Finished earlier; read its thread with get_messages for the answer.",
                        })
                    })
            })
            .collect();
        if !finished.is_empty() {
            return Some(json_result(&json!({"finished": finished})));
        }
        let any_running = if targets.is_empty() {
            children.iter().any(|(chat, _)| running(*chat))
        } else {
            targets.iter().any(|chat| running(*chat))
        };
        (!any_running).then(|| {
            json_result(&json!({
                "finished": [],
                "note": "None of those tasks is running.",
            }))
        })
    }

    async fn stop_task(&mut self, caller: i64, target: i64) -> Result<HostToolResult, String> {
        self.directable(caller, target).await?;
        if !self.works.contains_key(&target) {
            return Ok(HostToolResult::success("Nothing is running there."));
        }
        let toast = self.halt_task(target, self.config.owner_user_id).await;
        if toast.is_none() {
            self.set_task_status(target, "stopped").await;
        }
        Ok(HostToolResult::success(
            toast.unwrap_or_else(|| "Stopped.".to_owned()),
        ))
    }

    /// `/stop` in the DM: the lead's running tasks stop too.
    async fn stop_tasks(&mut self, lead: i64, actor: i64) -> usize {
        let children = self.agent.ledger.children(lead).unwrap_or_default();
        let mut stopped = 0;
        for (chat, _) in children {
            let running = self
                .works
                .get(&chat)
                .is_some_and(|work| *work.phase.borrow() == WorkPhase::Running);
            if running && self.halt_task(chat, actor).await.is_none() {
                self.set_task_status(chat, "stopped").await;
                stopped += 1;
            }
        }
        stopped
    }

    /// The DM lead's tasks and this agent's other works; any work may read
    /// it.
    fn list_tasks(&self, caller: i64) -> Result<HostToolResult, String> {
        let lead = self.config.dm_chat_id;
        let phase = |chat: &i64| {
            self.works
                .get(chat)
                .filter(|work| !work.task.is_finished())
                .map(|work| match *work.phase.borrow() {
                    WorkPhase::None => "starting",
                    WorkPhase::Idle => "idle",
                    WorkPhase::Running => "working",
                    WorkPhase::Paused => "paused",
                })
        };
        let children = self
            .agent
            .ledger
            .children(lead)
            .map_err(|error| format!("Could not read your tasks: {error}"))?;
        let tasks: Vec<Value> = children
            .iter()
            .map(|(chat, child)| {
                json!({
                    "chat_id": chat,
                    "title": child.title,
                    "link": format!("inline://chat?id={chat}"),
                    "state": phase(chat).unwrap_or("not loaded"),
                    "last_result": child.status,
                })
            })
            .collect();
        let others: Vec<Value> = self
            .works
            .keys()
            .filter(|chat| {
                **chat != lead
                    && **chat != caller
                    && !children.iter().any(|(child, _)| child == *chat)
            })
            .filter_map(|chat| {
                phase(chat).map(|state| {
                    json!({
                        "chat_id": chat,
                        "link": format!("inline://chat?id={chat}"),
                        "state": state,
                    })
                })
            })
            .collect();
        Ok(json_result(&json!({
            "tasks": tasks,
            "other_works": others,
            "hint": "Read a thread with get_messages; find others with list_my_threads or search_chats.",
        })))
    }

    /// `notify_owner`: a work outside the DM tells the owner there, and the
    /// lead sees it with its next input.
    async fn notify_owner(
        &mut self,
        caller: i64,
        text: String,
        call_id: &str,
    ) -> Result<HostToolResult, String> {
        let dm = self.config.dm_chat_id;
        if caller == dm {
            return Err("You are in your owner's DM already; answer here.".to_owned());
        }
        let title = self
            .agent
            .bot
            .chat_state(InlineId::new(caller))
            .await
            .ok()
            .and_then(|state| state.dialog)
            .and_then(|dialog| dialog.title)
            .map(|title| title.replace(['[', ']'], ""))
            .unwrap_or_else(|| "a thread".to_owned());
        let message_id = api::send_markdown(
            &self.agent.bot,
            dm,
            None,
            &format!("From [{title}](inline://chat?id={caller}):\n\n{text}"),
            crate::bridge::helpers::interaction_random_id("v2-notify-owner", call_id).get(),
        )
        .await
        .map_err(|error| format!("Inline could not post in your owner's DM: {error}"))?;
        self.agent.sent.lock().expect("sent").insert(message_id);
        let event = LeadEventRecord {
            event_id: report_event_id(
                self.config.bot_user_id,
                caller,
                &format!("notify-{message_id}"),
                "",
            ),
            lead_chat_id: dm,
            child_chat_id: caller,
            text: format!(
                "Note your work in inline://chat?id={caller} posted to your owner here (not a message from your owner):\n{text}"
            ),
        };
        if let Err(error) = self.agent.ledger.add_lead_event(&event) {
            log::warn!(target: "inline::bridge::v2", "cannot keep the owner note: {error}");
        }
        self.deliver_lead_events(dm).await;
        Ok(HostToolResult::success(
            json!({"chat_id": dm, "message_id": message_id}).to_string(),
        ))
    }

    /// A task's turn ended: its card shows it, and its lead hears it.
    async fn task_report(&mut self, report: TaskReport) {
        let Ok(Some(child)) = self.agent.ledger.child(report.child_chat_id) else {
            return;
        };
        self.set_task_status(report.child_chat_id, status_word(report.outcome))
            .await;
        // A lead waiting on this task takes the result in its running turn.
        if report.directed {
            self.waiters.retain(|(_, reply)| !reply.is_closed());
            if let Some(index) = self.waiters.iter().position(|(targets, _)| {
                targets.is_empty() || targets.contains(&report.child_chat_id)
            }) {
                let (_, reply) = self.waiters.remove(index);
                let finished = json!({"finished": [{
                    "chat_id": report.child_chat_id,
                    "title": child.title,
                    "status": status_word(report.outcome),
                    "answer": report.answer,
                }]});
                if reply.send(json_result(&finished)).is_ok() {
                    return;
                }
            }
        }
        let event = LeadEventRecord {
            event_id: report_event_id(
                self.config.bot_user_id,
                report.child_chat_id,
                &report.turn,
                report.answer.as_deref().unwrap_or_default(),
            ),
            lead_chat_id: child.lead_chat_id,
            child_chat_id: report.child_chat_id,
            text: if report.directed {
                report_text(&child.title, report.child_chat_id, &report)
            } else {
                note_text(&child.title, report.child_chat_id, report.outcome)
            },
        };
        if let Err(error) = self.agent.ledger.add_lead_event(&event) {
            log::warn!(target: "inline::bridge::v2", "cannot keep task report: {error}");
        }
        self.deliver_lead_events(child.lead_chat_id).await;
    }

    /// The lead's work takes its pending reports; it runs them between its
    /// own turns.
    async fn deliver_lead_events(&mut self, lead: i64) {
        let events: Vec<LeadEventRecord> = self
            .agent
            .ledger
            .lead_events()
            .unwrap_or_default()
            .into_iter()
            .filter(|event| event.lead_chat_id == lead)
            .collect();
        if events.is_empty() {
            return;
        }
        if let Err(error) = self.ensure_work(lead, None).await {
            log::warn!(target: "inline::bridge::v2", "lead={lead} cannot take task reports: {error}");
            return;
        }
        if let Some(work) = self.works.get(&lead) {
            let _ = work.tx.send(Command::LeadReports(events)).await;
        }
    }
}

/// How long the lead's tools wait for a task's work to answer a control.
const TASK_CONTROL_TIMEOUT: Duration = Duration::from_secs(5);
/// How long the same spawn_thread call returns the task it already started.
const SPAWN_RETRY_WINDOW: Duration = Duration::from_secs(120);

/// spawn_thread's answer for a started task.
fn spawned(child: i64, title: &str, again: bool) -> HostToolResult {
    let mut result = json!({
        "chat_id": child,
        "link": format!("inline://chat?id={child}"),
        "title": title,
        "note": "The task runs in its own session. Your owner sees its answer in the subthread and on your card; you receive it with your next message.",
    });
    if again {
        result["already_started"] = json!(true);
    }
    HostToolResult::success(result.to_string())
}
/// Characters of a reply thread's starting message given as context.
const ANCHOR_CHARS: usize = 2_000;

/// Join context with the thread's anchor first.
fn with_anchor(
    context: Option<inline_agent_bridge::TurnContext>,
    anchor: Option<String>,
) -> Option<inline_agent_bridge::TurnContext> {
    let Some(anchor) = anchor else {
        return context;
    };
    let mut context = context.unwrap_or(inline_agent_bridge::TurnContext {
        instructions: String::new(),
        conversation: String::new(),
    });
    context.conversation = if context.conversation.is_empty() {
        anchor
    } else {
        format!("{anchor}\n\n{}", context.conversation)
    };
    Some(context)
}

/// The most of a widget call's payload a turn shows: the server's own cap.
const MAX_WIDGET_PAYLOAD_BYTES: usize = 4 * 1024;

/// A widget call as the turn's text. Every part is the viewer's, so it is
/// untrusted input like any message they type; the payload is cut to 4 KiB.
fn widget_call_text(widget_id: &str, name: &str, payload: &[u8], message_id: i64) -> String {
    let clean = |text: &str| -> String {
        text.chars()
            .map(|character| {
                if character.is_control() {
                    ' '
                } else {
                    character
                }
            })
            .collect()
    };
    let full = String::from_utf8_lossy(payload);
    let mut end = full.len().min(MAX_WIDGET_PAYLOAD_BYTES);
    while !full.is_char_boundary(end) {
        end -= 1;
    }
    let mut payload = clean(full[..end].trim());
    if end < full.len() {
        payload.push('…');
    }
    let mut text = format!("[Widget call] {}", clean(name));
    if !payload.is_empty() {
        text.push(' ');
        text.push_str(&payload);
    }
    text.push_str(&format!(
        " (from the widget \"{}\" on message {message_id})",
        clean(widget_id)
    ));
    text
}

/// Why a widget call did not reach the agent, for the viewer's toast.
fn widget_call_refusal(decision: Option<IntakeDecision>) -> &'static str {
    use inline_agent_bridge::group::SkipReason;
    match decision {
        Some(
            IntakeDecision::Observe {
                reason: ObserveReason::NotGranted,
                ..
            }
            | IntakeDecision::Skip {
                reason: SkipReason::NotGranted,
            },
        ) => "You don't have access to ask this agent.",
        Some(IntakeDecision::Skip {
            reason: SkipReason::Muted | SkipReason::NotParticipating,
        }) => "This agent isn't taking requests in this thread.",
        Some(
            IntakeDecision::Observe {
                reason: ObserveReason::LoopCapReached,
                ..
            }
            | IntakeDecision::Skip {
                reason: SkipReason::LoopCapReached,
            },
        ) => "This agent has paused here for now.",
        _ => "This widget isn't connected to the agent here.",
    }
}

fn plural(count: usize) -> &'static str {
    if count == 1 { "" } else { "s" }
}

fn json_result(value: &Value) -> HostToolResult {
    HostToolResult::success(value.to_string())
}

struct FileQuery<'a> {
    path: &'a str,
    after: &'a str,
    query: Option<&'a str>,
    limit: Option<u32>,
}

/// A folder as people know it: its name, or No project.
fn folder_label(folder: &Path) -> String {
    workspaces::label(folder)
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

/// Commands Inline answers itself; the harness's own commands with these
/// names are not forwarded.
pub(super) const INLINE_COMMANDS: &[&str] = &[
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
    "share",
    "unshare",
    "plan",
    "review",
    "undo",
];

fn native_operation_supported(
    vocabulary: Vocabulary,
    manifest: Option<&inline_agent_bridge::harness::CapabilityManifest>,
    kind: OpKind,
) -> bool {
    manifest.map_or(
        // Native harnesses learn their manifest when their first session
        // opens. An absent manifest must not remove Claude's existing UI.
        !matches!(vocabulary, Vocabulary::OpenCode | Vocabulary::Amp),
        |manifest| manifest.availability.op(kind).is_supported(),
    )
}

fn harness_command_candidate(
    vocabulary: Vocabulary,
    manifest: Option<&inline_agent_bridge::harness::CapabilityManifest>,
    name: &str,
) -> bool {
    if !INLINE_COMMANDS.contains(&name) {
        return true;
    }
    if !matches!(vocabulary, Vocabulary::OpenCode | Vocabulary::Amp) {
        return false;
    }
    let kind = match name {
        "compact" => OpKind::Compact,
        "clear" => OpKind::Clear,
        "plan" => OpKind::Mode,
        "review" => OpKind::Review,
        "undo" => OpKind::RewindFiles,
        _ => return false,
    };
    !native_operation_supported(vocabulary, manifest, kind)
}

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
fn help_text(agent_name: &str, vocabulary: Vocabulary, acp: bool) -> String {
    if acp || vocabulary == Vocabulary::Amp {
        return format!(
            "{agent_name} commands:\n/status · current model and folder\n/model, /reasoning, /permissions · settings for this thread\n/stop · stop the current turn; /pause and /resume\n/new <task> · a new thread with a fresh session\n/follow, /unfollow · choose which messages to answer\n/share @name, /unshare @name · who may use me (owner)\n/release · close this session while preserving its history\nThe agent's advertised commands and installed skills work as you type them."
        );
    }
    let native = match vocabulary {
        Vocabulary::Codex => {
            "/plan, /plan off · Codex plan mode\n/review [branch] · Codex reviews your changes\nInstalled Codex skills work as /skill-name.\n"
        }
        Vocabulary::Claude => {
            "/plan · Claude plan mode\n/undo · undo the last turn's file changes\nClaude's own commands and skills work as you type them.\n"
        }
        Vocabulary::OpenCode => {
            "/plan, /plan off · OpenCode's plan agent, or back to build\n/undo · undo the last turn, files and conversation\nOpenCode's own commands and skills work as you type them; /terminal opens this session in OpenCode alongside Inline.\n"
        }
        Vocabulary::Amp => unreachable!("ACP providers have capability-limited help above"),
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
         /share @name, /unshare @name · who may use me (owner)\n\
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
            "share",
            "unshare",
            "plan",
            "review",
            "undo",
            "compact",
        ] {
            assert!(INLINE_COMMANDS.contains(&name), "{name} is Inline's");
        }
    }

    #[test]
    fn help_names_each_harness_own_commands() {
        let codex = help_text("Codex", Vocabulary::Codex, false);
        assert!(codex.contains("/review") && !codex.contains("/undo"));
        let claude = help_text("Claude", Vocabulary::Claude, false);
        assert!(claude.contains("/undo") && claude.contains("skills"));
        assert!(claude.contains("/share") && claude.contains("/follow"));
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

    #[test]
    fn a_threads_anchor_comes_before_its_conversation() {
        assert_eq!(with_anchor(None, None), None);
        let only = with_anchor(None, Some("Anchor".to_owned())).unwrap();
        assert_eq!(only.conversation, "Anchor");
        let joined = with_anchor(
            Some(inline_agent_bridge::TurnContext {
                instructions: "keep".to_owned(),
                conversation: "Recent".to_owned(),
            }),
            Some("Anchor".to_owned()),
        )
        .unwrap();
        assert_eq!(joined.conversation, "Anchor\n\nRecent");
        assert_eq!(joined.instructions, "keep");
    }
}

#[cfg(test)]
#[path = "faults.rs"]
mod faults;
