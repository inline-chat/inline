//! The bridge v2 runtime: one native session per (thread, agent) on the
//! session contract, rendered into Inline with blocks (spec §4–§7).
//!
//! The main loop owns intake. Each work has a publisher task that turns the
//! session's events into messages and run-state reports.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::StreamExt;
use inline_agent_bridge::group::{
    Conversation, GroupMessage, GuideFacts, IntakeDecision, IntakeFacts, LoopGuards, Operation,
    ParticipationMode, PassiveContext, WorkPhase, decide_intake, direct_input, passive_input,
    trusted_guide,
};
use inline_agent_bridge::harness::{
    Event, FieldAnswer, FieldId, FieldInput, HarnessDriver, InputId, InteractionId,
    InteractionResponse, Op, OpenMode, OpenSpec, OutputMode, QuestionForm, RunState, SendError,
    Session, TurnPhase, UserId, WaitingOn,
};
use inline_agent_bridge::{ProviderSessionId, TurnId};
use inline_client::{
    AnswerMessageActionRequest, BotInteractionEvent, ClientEvent, CreateReplyThreadRequest,
    FormFieldValue, FormValue, InlineClient, InlineId, LosslessEventReceiver, MessageRecord,
};
use inline_protocol::proto;
use serde::{Deserialize, Serialize};

use super::api::{self, Notify, chat_peer};
use super::doc::Doc;
use super::intake::{MessageFacts, grants_by_user, group_message};
use super::render::{ActionStyle, CardAction, QUESTION_FORM_ID, RenderOp, Renderer, Vocabulary};

/// Progress edits are coalesced to at most one per slot in this window.
const EDIT_INTERVAL: Duration = Duration::from_millis(1200);
const DEFAULT_HEARTBEAT: Duration = Duration::from_secs(60);

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
}

impl V2Config {
    fn provider(&self) -> proto::AgentSessionProvider {
        match self.vocabulary {
            Vocabulary::Codex => proto::AgentSessionProvider::Codex,
            Vocabulary::Claude => proto::AgentSessionProvider::Claude,
        }
    }
}

/// A card's interaction, kept so answers map back to the harness.
#[derive(Clone, Debug)]
struct Card {
    interaction: InteractionId,
    approval: bool,
    form: Option<QuestionForm>,
}

/// State shared by the main loop and one work's publisher.
#[derive(Default)]
struct WorkShared {
    turn: Option<TurnId>,
    paused: bool,
    /// Card message ID → interaction.
    cards: HashMap<i64, Card>,
}

struct Work {
    chat_id: i64,
    agent_session_id: i64,
    session: Arc<dyn Session>,
    shared: Arc<Mutex<WorkShared>>,
    publisher: tokio::task::JoinHandle<()>,
}

impl Work {
    fn phase(&self) -> WorkPhase {
        let shared = self.shared.lock().expect("work state");
        if shared.paused {
            WorkPhase::Paused
        } else if shared.turn.is_some() {
            WorkPhase::Running
        } else {
            WorkPhase::Idle
        }
    }
}

/// Approval button payload.
#[derive(Serialize, Deserialize)]
struct ActionData {
    i: String,
    d: String,
}

pub(crate) struct Runtime {
    config: V2Config,
    bot: InlineClient,
    harness: Arc<dyn HarnessDriver>,
    works: HashMap<i64, Work>,
    grants: Option<HashMap<i64, inline_agent_bridge::group::Grants>>,
    participation: HashMap<i64, Option<proto::AgentParticipation>>,
    default_output_mode: OutputMode,
    loop_guards: LoopGuards,
    /// Messages this bot sent, so replies to them address it.
    sent: Arc<Mutex<HashSet<i64>>>,
    next_input: u64,
}

impl Runtime {
    pub(crate) fn new(
        config: V2Config,
        bot: InlineClient,
        harness: Arc<dyn HarnessDriver>,
    ) -> Self {
        Self {
            config,
            bot,
            harness,
            works: HashMap::new(),
            grants: None,
            participation: HashMap::new(),
            default_output_mode: OutputMode::Detailed,
            loop_guards: LoopGuards::default(),
            sent: Arc::new(Mutex::new(HashSet::new())),
            next_input: 0,
        }
    }

    /// Serves Inline events until `shutdown` resolves or the stream ends.
    pub(crate) async fn run(
        mut self,
        events: &mut LosslessEventReceiver,
        shutdown: impl std::future::Future<Output = ()>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        if !self.config.allowlist.is_empty()
            && let Err(error) = api::import_grants(&self.bot, self.config.allowlist.clone()).await
        {
            log::warn!(target: "inline::bridge::v2", "allowlist import failed: {error}");
        }
        let mut heartbeat = tokio::time::interval(self.heartbeat().await);
        heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        tokio::pin!(shutdown);
        let result = loop {
            tokio::select! {
                _ = &mut shutdown => break Ok(()),
                _ = heartbeat.tick() => {
                    let interval = self.heartbeat().await;
                    if interval != heartbeat.period() {
                        heartbeat = tokio::time::interval(interval);
                        heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                    }
                }
                delivery = events.recv_delivery() => {
                    let Some(delivery) = delivery else {
                        break Err(std::io::Error::new(
                            std::io::ErrorKind::ConnectionAborted,
                            "Inline bot event stream closed",
                        ).into());
                    };
                    if let Err(error) = self.handle(delivery.event()).await {
                        log::warn!(target: "inline::bridge::v2", "event handling failed: {error}");
                    }
                    delivery.ack().await?;
                }
            }
        };
        self.report_status(proto::AgentRuntimeStatus::Offline).await;
        for (_, work) in self.works.drain() {
            work.publisher.abort();
        }
        result
    }

    async fn heartbeat(&mut self) -> Duration {
        match self.report_status(proto::AgentRuntimeStatus::Online).await {
            Some(result) => {
                if let Some(runtime) = &result.runtime {
                    self.default_output_mode = output_mode(runtime.default_output_mode);
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
        let info = self.harness.describe();
        api::report_runtime(
            &self.bot,
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
                let toast = self
                    .on_action(chat_id.get(), message_id.get(), actor_user_id.get(), data)
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
                    self.on_form(chat_id.get(), message_id.get(), actor_user_id.get(), values)
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
                let toast = self
                    .on_control(agent_session_id.get(), actor_user_id.get(), *op)
                    .await;
                self.answer(*interaction_id, toast).await;
                Ok(())
            }
            ClientEvent::AgentAccessChanged { chat_id, .. } => {
                self.grants = None;
                match chat_id {
                    Some(chat_id) => {
                        self.participation.remove(&chat_id.get());
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
                        path,
                        after,
                        query.as_deref(),
                        *limit,
                    )
                    .await;
                self.bot
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

    async fn answer(&self, interaction_id: InlineId, toast: Option<String>) {
        if let Err(error) = self
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

    async fn grants_of(&mut self, user_id: i64) -> inline_agent_bridge::group::Grants {
        if user_id == self.config.owner_user_id {
            return inline_agent_bridge::group::Grants::OWNER;
        }
        if self.grants.is_none() {
            match api::list_grants(&self.bot).await {
                Ok(result) => self.grants = Some(grants_by_user(&result)),
                Err(error) => {
                    log::warn!(target: "inline::bridge::v2", "grants unavailable: {error}");
                    return inline_agent_bridge::group::Grants::NONE;
                }
            }
        }
        self.grants
            .as_ref()
            .and_then(|grants| grants.get(&user_id).copied())
            .unwrap_or_default()
    }

    async fn participation_of(&mut self, chat_id: i64) -> Option<proto::AgentParticipation> {
        if let Some(cached) = self.participation.get(&chat_id) {
            return cached.clone();
        }
        let participation = api::participations(&self.bot, chat_id)
            .await
            .ok()
            .and_then(|list| {
                list.into_iter()
                    .find(|participation| participation.bot_user_id == self.config.bot_user_id)
            });
        self.participation.insert(chat_id, participation.clone());
        participation
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
            if self.sent.lock().expect("sent").contains(&id.get()) {
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
                author_name: format!("user {}", message.sender_id.get()),
            },
        );
        let grants = self.grants_of(group.author.user_id).await;
        let participation = self.participation_of(chat_id).await;
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
            .map_or(WorkPhase::None, Work::phase);
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
            IntakeDecision::Act { join, .. } => {
                if join
                    && conversation == Conversation::Group
                    && let Err(error) = api::join(&self.bot, chat_id, self.config.bot_user_id).await
                {
                    log::warn!(target: "inline::bridge::v2", "join failed: {error}");
                }
                self.act(&group, &decision, participation).await
            }
            IntakeDecision::Observe { .. } => {
                let id = self.input_id();
                if let Some(work) = self.works.get(&chat_id) {
                    let input = passive_input(
                        PassiveContext {
                            chat_id,
                            text: format!("{}: {}", group.author.display_name, group.text),
                            included_message_ids: vec![group.message_id],
                            omitted: 0,
                        },
                        id,
                    );
                    // Passive context is best effort; harnesses without it skip.
                    let _ = work.session.send(input).await;
                }
                Ok(())
            }
            IntakeDecision::Skip { .. } => Ok(()),
        }
    }

    fn input_id(&mut self) -> InputId {
        self.next_input += 1;
        InputId::new(format!(
            "inline-{}-{}",
            chrono_like_now_ms(),
            self.next_input
        ))
        .expect("input id")
    }

    async fn act(
        &mut self,
        group: &GroupMessage,
        decision: &IntakeDecision,
        participation: Option<proto::AgentParticipation>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let chat_id = group.chat_id;
        match group.command().map(|(name, _)| name) {
            Some("new") => return self.new_thread(group, participation).await,
            Some("stop") => {
                if let Some(work) = self.works.get(&chat_id) {
                    stop(work, false).await;
                }
                return Ok(());
            }
            Some("pause") => {
                if let Some(work) = self.works.get(&chat_id) {
                    stop(work, true).await;
                }
                return Ok(());
            }
            Some("resume") => {
                if let Some(work) = self.works.get(&chat_id) {
                    resume(&self.bot, work).await;
                }
                return Ok(());
            }
            Some("release") => {
                if let Some(work) = self.works.remove(&chat_id) {
                    release(&self.bot, work).await;
                }
                return Ok(());
            }
            _ => {}
        }
        if !self.works.contains_key(&chat_id) {
            let mode = self.output_mode_for(participation.as_ref());
            let work = self.open_work(chat_id, mode).await?;
            self.works.insert(chat_id, work);
        }
        let work = self.works.get(&chat_id).expect("work");
        // Direct input restarts paused work.
        work.shared.lock().expect("work state").paused = false;
        let running = work.shared.lock().expect("work state").turn.clone();
        let id = self.input_id();
        let Some(input) = direct_input(
            decision,
            group,
            self.config.owner_user_id,
            id,
            running.as_ref(),
            None,
        ) else {
            return Ok(());
        };
        let work = self.works.get(&chat_id).expect("work");
        match work.session.send(input.clone()).await {
            Ok(_) => Ok(()),
            // The turn ended or started between the check and the send.
            Err(SendError::Busy { active }) => {
                let mut input = input;
                input.delivery = inline_agent_bridge::harness::Delivery::Steer {
                    expected_turn: active,
                    priority: inline_agent_bridge::harness::SteerPriority::Next,
                };
                work.session
                    .send(input)
                    .await
                    .map(|_| ())
                    .map_err(Into::into)
            }
            Err(SendError::TurnMismatch { active: None }) => {
                let mut input = input;
                input.delivery = inline_agent_bridge::harness::Delivery::Turn;
                work.session
                    .send(input)
                    .await
                    .map(|_| ())
                    .map_err(Into::into)
            }
            Err(error) => {
                let doc = notice_doc(&format!(
                    "{} could not take that: {error}",
                    self.config.agent_name
                ));
                api::send_doc(
                    &self.bot,
                    chat_id,
                    Some(group.message_id),
                    &doc,
                    None,
                    Notify::Normal,
                )
                .await?;
                Ok(())
            }
        }
    }

    fn output_mode_for(&self, participation: Option<&proto::AgentParticipation>) -> OutputMode {
        participation
            .and_then(|participation| participation.output_mode)
            .map(output_mode)
            .filter(|_| {
                participation
                    .and_then(|participation| participation.output_mode)
                    .is_some_and(|mode| mode != proto::AgentOutputMode::Unspecified as i32)
            })
            .unwrap_or(self.default_output_mode)
    }

    /// `/new`: a new Inline thread under this chat with a fresh native session.
    async fn new_thread(
        &mut self,
        group: &GroupMessage,
        participation: Option<proto::AgentParticipation>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let created = self
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
        let mode = self.output_mode_for(participation.as_ref());
        let work = self.open_work_with(chat_id, mode, OpenMode::Start).await?;
        self.works.insert(chat_id, work);
        let task = group
            .text
            .trim_start()
            .trim_start_matches('/')
            .split_once(char::is_whitespace)
            .map(|(_, rest)| rest.trim().to_owned())
            .unwrap_or_default();
        if !task.is_empty() {
            let id = self.input_id();
            let work = self.works.get(&chat_id).expect("work");
            work.session
                .send(inline_agent_bridge::harness::Input {
                    id,
                    content: inline_agent_bridge::harness::InputContent::text(task),
                    origin: inline_agent_bridge::group::origin_of(group, self.config.owner_user_id),
                    delivery: inline_agent_bridge::harness::Delivery::Turn,
                })
                .await?;
        }
        Ok(())
    }

    /// Resumes the thread's native session when the server knows one,
    /// otherwise starts a new one.
    async fn open_work(
        &self,
        chat_id: i64,
        output_mode: OutputMode,
    ) -> Result<Work, Box<dyn std::error::Error>> {
        let existing = self
            .bot
            .get_agent_session(proto::GetAgentSessionInput {
                peer_id: Some(chat_peer(chat_id)),
                bot_user_id: self.config.bot_user_id,
                ..Default::default()
            })
            .await
            .ok()
            .and_then(|result| result.connection)
            .filter(|connection| !connection.session_ref.is_empty());
        let mode = match existing {
            Some(connection) => OpenMode::Resume {
                session: ProviderSessionId::new(connection.session_ref)?,
            },
            None => OpenMode::Start,
        };
        self.open_work_with(chat_id, output_mode, mode).await
    }

    async fn open_work_with(
        &self,
        chat_id: i64,
        output_mode: OutputMode,
        mode: OpenMode,
    ) -> Result<Work, Box<dyn std::error::Error>> {
        let session = self
            .harness
            .open(OpenSpec {
                mode,
                folder: self.config.folder.clone(),
                settings: Default::default(),
                instructions: Some(trusted_guide(GuideFacts {
                    bot_user_id: self.config.bot_user_id,
                    owner_user_id: self.config.owner_user_id,
                    inline_tools: false,
                })),
                title: None,
                after: None,
                output_mode,
            })
            .await?;
        let connected = self
            .bot
            .connect_agent_session(proto::ConnectAgentSessionInput {
                peer_id: Some(chat_peer(chat_id)),
                bot_user_id: self.config.bot_user_id,
                provider: self.config.provider() as i32,
                instance_ref: self.config.installation_id.clone(),
                session_ref: session.key().session.to_string(),
                workspace_label: self
                    .config
                    .folder
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned()),
                ..Default::default()
            })
            .await?;
        let agent_session_id = connected
            .agent_session
            .map(|agent_session| agent_session.id)
            .ok_or("Inline did not return the agent session")?;
        let shared = Arc::new(Mutex::new(WorkShared::default()));
        let publisher = tokio::spawn(publish(Publisher {
            bot: self.bot.clone(),
            chat_id,
            agent_session_id,
            owner_user_id: self.config.owner_user_id,
            session: session.clone(),
            renderer: Renderer::new(
                output_mode,
                self.config.vocabulary,
                self.config.agent_name.clone(),
            ),
            shared: shared.clone(),
            sent: self.sent.clone(),
        }));
        Ok(Work {
            chat_id,
            agent_session_id,
            session,
            shared,
            publisher,
        })
    }

    async fn on_action(
        &mut self,
        chat_id: i64,
        message_id: i64,
        actor: i64,
        data: &[u8],
    ) -> Option<String> {
        let Ok(data) = serde_json::from_slice::<ActionData>(data) else {
            return Some("This button is no longer active.".to_owned());
        };
        let grants = self.grants_of(actor).await;
        let work = self.works.get(&chat_id)?;
        let card = work
            .shared
            .lock()
            .expect("work state")
            .cards
            .get(&message_id)
            .cloned()?;
        if card.interaction.as_str() != data.i {
            return Some("This request is no longer pending.".to_owned());
        }
        let permitted = if card.approval {
            grants.permits(Operation::Approve)
        } else {
            grants.any()
        };
        if !permitted {
            return Some("You don't have access to answer this.".to_owned());
        }
        let Ok(decision) = inline_agent_bridge::harness::DecisionId::new(data.d) else {
            return Some("That choice is not available.".to_owned());
        };
        match work
            .session
            .control(Op::Answer {
                interaction: card.interaction,
                response: InteractionResponse::Decision {
                    decision,
                    message: None,
                },
                by: UserId(actor),
            })
            .await
        {
            Ok(_) => None,
            Err(error) => Some(format!("Could not send the answer: {error}")),
        }
    }

    async fn on_form(
        &mut self,
        chat_id: i64,
        message_id: i64,
        actor: i64,
        values: &[FormValue],
    ) -> Option<String> {
        let grants = self.grants_of(actor).await;
        if !grants.any() {
            return Some("You don't have access to answer this.".to_owned());
        }
        let work = self.works.get(&chat_id)?;
        let card = work
            .shared
            .lock()
            .expect("work state")
            .cards
            .get(&message_id)
            .cloned()?;
        let form = card.form?;
        let answers = form_answers(&form, values);
        match work
            .session
            .control(Op::Answer {
                interaction: card.interaction,
                response: InteractionResponse::Answers { answers },
                by: UserId(actor),
            })
            .await
        {
            Ok(_) => None,
            Err(error) => Some(format!("Could not send the answer: {error}")),
        }
    }

    async fn on_control(&mut self, agent_session_id: i64, actor: i64, op: i32) -> Option<String> {
        let grants = self.grants_of(actor).await;
        let chat_id = self
            .works
            .values()
            .find(|work| work.agent_session_id == agent_session_id)
            .map(|work| work.chat_id)?;
        match proto::AgentSessionControl::try_from(op) {
            Ok(proto::AgentSessionControl::Stop) if grants.permits(Operation::Stop) => {
                stop(&self.works[&chat_id], false).await;
                None
            }
            Ok(proto::AgentSessionControl::Pause) if grants.permits(Operation::Pause) => {
                stop(&self.works[&chat_id], true).await;
                None
            }
            Ok(proto::AgentSessionControl::Resume) if grants.permits(Operation::Resume) => {
                resume(&self.bot, &self.works[&chat_id]).await;
                None
            }
            _ => Some("You don't have access to control this agent.".to_owned()),
        }
    }

    #[allow(clippy::too_many_arguments)]
    async fn list_files(
        &mut self,
        chat_id: i64,
        actor: i64,
        operation: i32,
        agent_session_id: Option<i64>,
        path: &str,
        after: &str,
        query: Option<&str>,
        limit: Option<u32>,
    ) -> proto::BotFilesystemResponse {
        use proto::bot_filesystem_response::Result as Reply;
        let problem = |message: &str| proto::BotFilesystemResponse {
            result: Some(Reply::Problem(message.to_owned())),
        };
        if operation != 3 {
            return problem("Browsing this machine is not available for this agent yet.");
        }
        let grants = self.grants_of(actor).await;
        if !grants.permits(Operation::StartWork) {
            return problem("You don't have access to this agent's files.");
        }
        let work = self.works.values().find(|work| {
            agent_session_id.map_or(work.chat_id == chat_id, |id| work.agent_session_id == id)
        });
        if work.is_none() && agent_session_id.is_some() {
            return problem("This work is not open on this machine.");
        }
        let folder = self.config.folder.clone();
        let path = path.to_owned();
        let after = after.to_owned();
        let query = query.map(str::to_owned);
        let limit = limit.unwrap_or(50).clamp(1, 200) as usize;
        match tokio::task::spawn_blocking(move || {
            crate::bridge::filesystem::work_files_listing(
                &folder,
                &path,
                query.as_deref(),
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

async fn stop(work: &Work, pause: bool) {
    if pause {
        work.shared.lock().expect("work state").paused = true;
    }
    if let Err(error) = work
        .session
        .control(Op::Interrupt {
            cancel_queued: false,
        })
        .await
    {
        log::warn!(target: "inline::bridge::v2", "stop failed: {error}");
    }
}

async fn resume(bot: &InlineClient, work: &Work) {
    work.shared.lock().expect("work state").paused = false;
    report_state(
        bot,
        work.agent_session_id,
        run_state(proto::AgentRunState::Idle),
    )
    .await;
}

async fn release(bot: &InlineClient, work: Work) {
    match work.session.release().await {
        Ok(_) => {}
        Err(error) => log::warn!(target: "inline::bridge::v2", "release failed: {error}"),
    }
    let doc = notice_doc("Released. You can continue this session in the terminal or the app.");
    let _ = api::send_doc(bot, work.chat_id, None, &doc, None, Notify::Normal).await;
    work.publisher.abort();
}

fn output_mode(mode: i32) -> OutputMode {
    match proto::AgentOutputMode::try_from(mode) {
        Ok(proto::AgentOutputMode::Friendly) => OutputMode::Friendly,
        _ => OutputMode::Detailed,
    }
}

fn notice_doc(text: &str) -> Doc {
    let mut builder = super::doc::DocBuilder::new();
    builder.paragraph(text);
    builder.finish()
}

/// Wall-clock milliseconds; also the run-state revision, which must keep
/// increasing across restarts.
fn chrono_like_now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or_default()
}

fn run_state(state: proto::AgentRunState) -> proto::AgentSessionState {
    proto::AgentSessionState {
        run_state: state as i32,
        revision: chrono_like_now_ms(),
        ..Default::default()
    }
}

async fn report_state(bot: &InlineClient, agent_session_id: i64, state: proto::AgentSessionState) {
    if let Err(error) = api::update_session_state(bot, agent_session_id, state).await {
        log::warn!(target: "inline::bridge::v2", "run state report failed: {error}");
    }
}

/// Form values back to the harness: option IDs become the option labels.
fn form_answers(form: &QuestionForm, values: &[FormValue]) -> Vec<FieldAnswer> {
    form.fields
        .iter()
        .filter_map(|field| {
            let value = values
                .iter()
                .find(|value| value.field_id == field.id.as_str())?
                .value
                .as_ref()?;
            let answers = match (value, &field.input) {
                (
                    FormFieldValue::Selection { option_ids, other },
                    FieldInput::Select { options, .. },
                ) => {
                    let mut labels: Vec<String> = option_ids
                        .iter()
                        .filter_map(|id| id.strip_prefix('o')?.parse::<usize>().ok())
                        .filter_map(|index| options.get(index).map(|option| option.label.clone()))
                        .collect();
                    labels.extend(other.clone().filter(|other| !other.trim().is_empty()));
                    labels
                }
                (FormFieldValue::Text(text), _) => vec![text.clone()],
                (FormFieldValue::Toggle(value), _) => vec![value.to_string()],
                (FormFieldValue::Number(value), _) => vec![value.clone()],
                (FormFieldValue::Selection { option_ids, .. }, _) => option_ids.clone(),
            };
            Some(FieldAnswer {
                field: FieldId::new(field.id.as_str()).ok()?,
                values: answers,
            })
        })
        .collect()
}

struct Publisher {
    bot: InlineClient,
    chat_id: i64,
    agent_session_id: i64,
    owner_user_id: i64,
    session: Arc<dyn Session>,
    renderer: Renderer,
    shared: Arc<Mutex<WorkShared>>,
    sent: Arc<Mutex<HashSet<i64>>>,
}

struct Pending {
    doc: Doc,
    due: tokio::time::Instant,
}

/// Renders one work's events into Inline messages and run-state reports.
async fn publish(mut publisher: Publisher) {
    let mut events = publisher.session.events();
    let mut slots: HashMap<u32, i64> = HashMap::new();
    let mut cards: HashMap<InteractionId, i64> = HashMap::new();
    let mut pending: HashMap<u32, Pending> = HashMap::new();
    let mut turn_started: Option<i64> = None;
    loop {
        let next_due = pending.values().map(|pending| pending.due).min();
        let envelope = tokio::select! {
            envelope = events.next() => envelope,
            _ = async {
                match next_due {
                    Some(due) => tokio::time::sleep_until(due).await,
                    None => std::future::pending().await,
                }
            } => {
                let now = tokio::time::Instant::now();
                let due: Vec<u32> = pending
                    .iter()
                    .filter(|(_, pending)| pending.due <= now)
                    .map(|(slot, _)| *slot)
                    .collect();
                for slot in due {
                    if let (Some(item), Some(message_id)) = (pending.remove(&slot), slots.get(&slot)) {
                        let _ = api::edit_doc(&publisher.bot, publisher.chat_id, *message_id, &item.doc, None).await;
                    }
                }
                continue;
            }
        };
        let Some(envelope) = envelope else {
            break;
        };
        publisher
            .track_state(&envelope.event, &mut turn_started)
            .await;
        for op in publisher.renderer.apply(&envelope) {
            match op {
                RenderOp::Progress { slot, doc } => match slots.get(&slot) {
                    Some(_) => {
                        let due = tokio::time::Instant::now() + EDIT_INTERVAL;
                        pending
                            .entry(slot)
                            .and_modify(|pending| pending.doc = doc.clone())
                            .or_insert(Pending { doc, due });
                    }
                    None => {
                        if let Some(id) = publisher.send(&doc, None, Notify::Silent).await {
                            slots.insert(slot, id);
                        }
                    }
                },
                RenderOp::EndProgress { slot, doc } => {
                    pending.remove(&slot);
                    match slots.remove(&slot) {
                        Some(message_id) => {
                            let _ = api::edit_doc(
                                &publisher.bot,
                                publisher.chat_id,
                                message_id,
                                &doc,
                                None,
                            )
                            .await;
                        }
                        None => {
                            publisher.send(&doc, None, Notify::Silent).await;
                        }
                    }
                }
                RenderOp::Update { doc } => {
                    publisher.send(&doc, None, Notify::Silent).await;
                }
                RenderOp::Final { doc } | RenderOp::Notice { doc } => {
                    publisher.send(&doc, None, Notify::Normal).await;
                }
                RenderOp::Card {
                    interaction,
                    doc,
                    actions,
                    form,
                } => {
                    let buttons = card_actions(&interaction, &actions);
                    if let Some(message_id) = publisher.send(&doc, buttons, Notify::Normal).await {
                        cards.insert(interaction.clone(), message_id);
                        publisher.shared.lock().expect("work state").cards.insert(
                            message_id,
                            Card {
                                interaction: interaction.clone(),
                                approval: form.is_none(),
                                form,
                            },
                        );
                        let mut state = run_state(proto::AgentRunState::Waiting);
                        state.waiting_reason = if actions.is_empty() {
                            proto::AgentWaitingReason::Question
                        } else {
                            proto::AgentWaitingReason::Approval
                        } as i32;
                        state.attention = Some(proto::AgentAttention {
                            kind: if actions.is_empty() {
                                proto::AgentAttentionKind::Question
                            } else {
                                proto::AgentAttentionKind::Approval
                            } as i32,
                            user_ids: vec![publisher.owner_user_id],
                            message_id: Some(message_id),
                            text: None,
                        });
                        state.started_at = turn_started;
                        report_state(&publisher.bot, publisher.agent_session_id, state).await;
                    }
                }
                RenderOp::CardClosed { interaction, doc } => {
                    if let Some(message_id) = cards.remove(&interaction) {
                        publisher
                            .shared
                            .lock()
                            .expect("work state")
                            .cards
                            .remove(&message_id);
                        let _ = api::edit_doc(
                            &publisher.bot,
                            publisher.chat_id,
                            message_id,
                            &doc,
                            Some(proto::MessageActions::default()),
                        )
                        .await;
                    }
                }
            }
        }
    }
}

impl Publisher {
    async fn send(
        &self,
        doc: &Doc,
        actions: Option<proto::MessageActions>,
        notify: Notify,
    ) -> Option<i64> {
        if doc.is_empty() {
            return None;
        }
        match api::send_doc(&self.bot, self.chat_id, None, doc, actions, notify).await {
            Ok(id) => {
                self.sent.lock().expect("sent").insert(id);
                Some(id)
            }
            Err(error) => {
                log::warn!(target: "inline::bridge::v2", "send failed: {error}");
                None
            }
        }
    }

    async fn track_state(&self, event: &Event, turn_started: &mut Option<i64>) {
        let state = match event {
            Event::Turn { turn, phase } => match phase {
                TurnPhase::Started { .. } => {
                    self.shared.lock().expect("work state").turn = Some(turn.clone());
                    *turn_started = Some(chrono_like_now_ms() / 1000);
                    let mut state = run_state(proto::AgentRunState::Working);
                    state.started_at = *turn_started;
                    Some(state)
                }
                TurnPhase::Completed { .. } => {
                    let paused = {
                        let mut shared = self.shared.lock().expect("work state");
                        shared.turn = None;
                        shared.paused
                    };
                    *turn_started = None;
                    Some(run_state(if paused {
                        proto::AgentRunState::Paused
                    } else {
                        proto::AgentRunState::Idle
                    }))
                }
            },
            Event::InteractionClosed { .. } => {
                let mut state = run_state(proto::AgentRunState::Working);
                state.started_at = *turn_started;
                Some(state)
            }
            Event::State { state } => match state {
                RunState::HeldElsewhere { .. } => {
                    Some(run_state(proto::AgentRunState::HeldElsewhere))
                }
                RunState::Waiting {
                    on: WaitingOn::Limit { .. },
                } => {
                    let mut state = run_state(proto::AgentRunState::Waiting);
                    state.waiting_reason = proto::AgentWaitingReason::Limit as i32;
                    Some(state)
                }
                RunState::Released => Some(run_state(proto::AgentRunState::Idle)),
                _ => None,
            },
            _ => None,
        };
        if let Some(state) = state {
            report_state(&self.bot, self.agent_session_id, state).await;
        }
    }
}

/// Approval buttons with the harness's own labels, one per row.
fn card_actions(
    interaction: &InteractionId,
    actions: &[CardAction],
) -> Option<proto::MessageActions> {
    if actions.is_empty() {
        return None;
    }
    let rows = actions
        .iter()
        .enumerate()
        .filter_map(|(index, action)| {
            let data = serde_json::to_vec(&ActionData {
                i: interaction.to_string(),
                d: action.decision.clone(),
            })
            .ok()?;
            Some(proto::MessageActionRow {
                actions: vec![proto::MessageAction {
                    action_id: format!("v2-{index}"),
                    text: action.label.clone(),
                    action: Some(proto::message_action::Action::Callback(
                        proto::MessageActionCallback { data },
                    )),
                    style: match action.style {
                        ActionStyle::Default => proto::message_action::Style::Default,
                        ActionStyle::Primary => proto::message_action::Style::Primary,
                        ActionStyle::Destructive => proto::message_action::Style::Destructive,
                    } as i32,
                    required_grant: proto::AgentGrantRequirement::Approve as i32,
                    ..Default::default()
                }],
            })
        })
        .collect();
    Some(proto::MessageActions { rows })
}

#[cfg(test)]
mod tests {
    use super::*;
    use inline_agent_bridge::harness::{FieldOption, FormField};

    #[test]
    fn form_answers_map_options_to_labels() {
        let form = QuestionForm {
            title: None,
            fields: vec![FormField {
                id: FieldId::new("pick").unwrap(),
                header: None,
                prompt: "Which?".into(),
                input: FieldInput::Select {
                    options: vec![
                        FieldOption {
                            label: "Red".into(),
                            description: None,
                        },
                        FieldOption {
                            label: "Blue".into(),
                            description: None,
                        },
                    ],
                    multiple: true,
                    allow_other: true,
                },
                required: true,
            }],
            asynchronous: false,
            auto_resolution_ms: None,
        };
        let answers = form_answers(
            &form,
            &[FormValue {
                field_id: "pick".into(),
                value: Some(FormFieldValue::Selection {
                    option_ids: vec!["o1".into()],
                    other: Some("Green".into()),
                }),
            }],
        );
        assert_eq!(answers.len(), 1);
        assert_eq!(
            answers[0].values,
            vec!["Blue".to_owned(), "Green".to_owned()]
        );
    }

    #[test]
    fn approval_buttons_carry_the_decision_and_require_approve() {
        let interaction = InteractionId::new("req-1").unwrap();
        let actions = card_actions(
            &interaction,
            &[CardAction {
                decision: "accept".into(),
                label: "Yes".into(),
                style: ActionStyle::Primary,
            }],
        )
        .unwrap();
        let action = &actions.rows[0].actions[0];
        assert_eq!(action.text, "Yes");
        assert_eq!(
            action.required_grant,
            proto::AgentGrantRequirement::Approve as i32
        );
        let Some(proto::message_action::Action::Callback(callback)) = &action.action else {
            panic!("callback");
        };
        let data: ActionData = serde_json::from_slice(&callback.data).unwrap();
        assert_eq!((data.i.as_str(), data.d.as_str()), ("req-1", "accept"));
    }
}
