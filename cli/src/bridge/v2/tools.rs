//! Inline tools for v2 agents (spec §4.8).
//!
//! Served in-process to the harness (Codex dynamic tools, Claude
//! `mcp_message`), acting as the agent's bot. A call is resolved through the
//! session that made it, never through a turn, so background work keeps its
//! tools until the harness confirms the release. The server authorizes every
//! request as the bot, and a link never broadens access: a chat other than the
//! work's own is used only after the bot itself can read it.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use inline_agent_bridge::group::{ToolBinding, ToolBindings, ToolRejection};
use inline_agent_bridge::harness::{ChatId, SessionKey, UserId, WorkRef};
use inline_agent_bridge::{
    HostToolCall, HostToolConfiguration, HostToolFuture, HostToolHandler, HostToolResult,
    HostToolSpec, ProviderId, ProviderSessionId,
};
use inline_client::{
    ChatCreateParticipant, CreateReplyThreadRequest, CreateThreadRequest, DialogRecord,
    DialogsOrder, DialogsRequest, EditMessageRequest, ExternalId, HistoryPage, HistoryRequest,
    InlineClient, InlineId, PinMessageRequest, ReactRequest,
};
use inline_protocol::proto;
use serde_json::{Value, json};
use tokio::sync::oneshot;

use super::api;
use super::work::Command;
use crate::bridge::helpers::interaction_random_id;
use crate::bridge::inline_tools::{
    HOST_TOOL_EXECUTION_TIMEOUT, MAX_HOST_TOOL_ARGUMENT_BYTES, RETURN_ATTACHMENT_TIMEOUT,
    ReturnFile, bool_arg, bounded_limit, bounded_tool_result, json_value_result, positive_i64,
    project_proto_messages, return_local_file, string_arg, valid_tool_call_id,
    validate_tool_arguments,
};

/// How long a tool that acts through the work (subthread, status) waits for
/// the work to answer.
const WORK_ANSWER_TIMEOUT: Duration = Duration::from_secs(12);
const MAX_TEXT_CHARS: usize = 8_000;

/// A tool that acts through the work itself, answered by its actor.
#[derive(Debug)]
pub(crate) enum WorkTool {
    /// Move the work's publication into a new subthread (spec §5.2).
    StartSubthread {
        title: String,
        summary: Option<String>,
        anchor_message_id: Option<i64>,
    },
}

pub(crate) struct ToolsConfig {
    pub bot: InlineClient,
    pub provider: ProviderId,
    pub bot_user_id: i64,
    pub owner_user_id: i64,
    pub agent_name: String,
    pub folder: PathBuf,
    pub attachments_dir: PathBuf,
}

/// One agent's tool host, shared by all of its works.
pub(crate) struct Tools {
    config: ToolsConfig,
    bindings: Mutex<ToolBindings>,
    /// Session → its work's actor, for tools that act through the work.
    works: Mutex<HashMap<String, super::work::WeakCommandSender>>,
    /// Session → the folder its work runs in.
    folders: Mutex<HashMap<String, PathBuf>>,
    /// Messages this bot sent, so replies to them address it.
    sent: Arc<Mutex<HashSet<i64>>>,
    /// Follow choices made here or by /follow, newest wins, so intake sees
    /// them on the next message.
    follows: Mutex<HashMap<i64, bool>>,
    /// Session → the message (chat, message) that started its latest turn,
    /// for `reply_thread: "current"`.
    requests: Mutex<HashMap<String, (i64, i64)>>,
}

impl Tools {
    pub(crate) fn new(config: ToolsConfig) -> Arc<Self> {
        Arc::new(Self {
            config,
            bindings: Mutex::new(ToolBindings::default()),
            works: Mutex::new(HashMap::new()),
            folders: Mutex::new(HashMap::new()),
            sent: Arc::new(Mutex::new(HashSet::new())),
            follows: Mutex::new(HashMap::new()),
            requests: Mutex::new(HashMap::new()),
        })
    }

    pub(crate) fn sent(&self) -> Arc<Mutex<HashSet<i64>>> {
        self.sent.clone()
    }

    /// This bot's latest follow choice for `chat`, made in this run.
    pub(crate) fn follow_choice(&self, chat: i64) -> Option<bool> {
        self.follows.lock().expect("follows").get(&chat).copied()
    }

    pub(crate) fn record_follow(&self, chat: i64, follow: bool) {
        self.follows.lock().expect("follows").insert(chat, follow);
    }

    /// The work's harness took the input from `message` in `chat`.
    pub(crate) fn record_request(&self, session: &ProviderSessionId, chat: i64, message: i64) {
        self.requests
            .lock()
            .expect("tool requests")
            .insert(session.as_str().to_owned(), (chat, message));
    }

    pub(crate) fn configuration(self: &Arc<Self>) -> HostToolConfiguration {
        HostToolConfiguration {
            specs: specs(),
            handler: self.clone(),
        }
    }

    fn key(&self, session: &ProviderSessionId) -> SessionKey {
        SessionKey {
            provider: self.config.provider.clone(),
            session: session.clone(),
        }
    }

    /// On open, resume or fork of a work's session.
    pub(crate) fn bind(
        &self,
        session: &ProviderSessionId,
        chat_id: i64,
        commands: super::work::WeakCommandSender,
        folder: PathBuf,
    ) {
        self.bindings.lock().expect("tool bindings").bind(
            &self.key(session),
            ToolBinding {
                agent: UserId(self.config.bot_user_id),
                work: WorkRef {
                    chat: ChatId(chat_id),
                    session: Some(session.clone()),
                },
            },
        );
        self.works
            .lock()
            .expect("tool works")
            .insert(session.as_str().to_owned(), commands);
        self.folders
            .lock()
            .expect("tool folders")
            .insert(session.as_str().to_owned(), folder);
    }

    /// A native child session (a Codex sub-agent thread) acting for its
    /// parent's work.
    pub(crate) fn bind_child(&self, child: &ProviderSessionId, parent: &ProviderSessionId) {
        self.bindings
            .lock()
            .expect("tool bindings")
            .bind_child(&self.key(child), &self.key(parent));
    }

    /// The work moved its publication into a subthread.
    pub(crate) fn move_work(&self, session: &ProviderSessionId, chat_id: i64) {
        self.bindings
            .lock()
            .expect("tool bindings")
            .move_work(&self.key(session), ChatId(chat_id));
    }

    /// Only once the session can no longer act for the work: the harness
    /// confirmed the release, or the process is gone.
    pub(crate) fn unbind(&self, session: &ProviderSessionId) {
        self.bindings
            .lock()
            .expect("tool bindings")
            .unbind(&self.key(session));
        self.works
            .lock()
            .expect("tool works")
            .remove(session.as_str());
        self.folders
            .lock()
            .expect("tool folders")
            .remove(session.as_str());
        self.requests
            .lock()
            .expect("tool requests")
            .remove(session.as_str());
    }

    async fn execute(&self, call: HostToolCall) -> HostToolResult {
        if !valid_tool_call_id(&call.call_id) {
            return HostToolResult::failure("Inline tool call identity is invalid.");
        }
        let Some(spec) = specs().into_iter().find(|spec| spec.name == call.tool_name) else {
            return HostToolResult::failure("Unknown Inline tool.");
        };
        if serde_json::to_vec(&call.arguments).map_or(true, |arguments| {
            arguments.len() > MAX_HOST_TOOL_ARGUMENT_BYTES
        }) {
            return HostToolResult::failure("Inline tool arguments are invalid or too large.");
        }
        if validate_tool_arguments(&call.arguments, &spec.input_schema).is_err() {
            return HostToolResult::failure("Inline tool arguments do not match the tool schema.");
        }
        let session = self.key(&call.session_id);
        let target = match tool_target(&call) {
            Ok(target) => target,
            Err(message) => return HostToolResult::failure(message),
        };
        let Some(work_chat) = self
            .bindings
            .lock()
            .expect("tool bindings")
            .resolve(&session)
            .map(|binding| binding.work.chat.0)
        else {
            return HostToolResult::failure(rejection_text(&ToolRejection::UnboundSession));
        };
        // Another chat is used only if the bot can already read it.
        let accessible = match target {
            Some(chat) if chat != work_chat => api::get_chat(&self.config.bot, chat).await.is_ok(),
            _ => false,
        };
        let binding = match self.bindings.lock().expect("tool bindings").authorize(
            &session,
            &call.tool_name,
            target.map(ChatId),
            bool_arg(&call.arguments, "confirmed_intent"),
            |_| accessible,
        ) {
            Ok(binding) => binding.clone(),
            Err(rejection) => {
                log::debug!(
                    target: "inline::bridge::v2::tools",
                    "tool={} rejected={rejection:?}",
                    call.tool_name
                );
                return HostToolResult::failure(rejection_text(&rejection));
            }
        };
        let timeout = if call.tool_name == "return_attachment" {
            RETURN_ATTACHMENT_TIMEOUT
        } else {
            HOST_TOOL_EXECUTION_TIMEOUT
        };
        let work = Work {
            chat: binding.work.chat.0,
            session: binding.work.session.unwrap_or(call.session_id.clone()),
        };
        let chat = target.unwrap_or(work.chat);
        let result = match tokio::time::timeout(timeout, self.run(&call, &work, chat)).await {
            Ok(result) => bounded_tool_result(result),
            Err(_) => HostToolResult::failure("Inline tool call timed out."),
        };
        log::debug!(
            target: "inline::bridge::v2::tools",
            "tool={} chat={chat} success={}",
            call.tool_name,
            result.success
        );
        result
    }

    async fn run(&self, call: &HostToolCall, work: &Work, chat: i64) -> HostToolResult {
        let arguments = &call.arguments;
        match call.tool_name.as_str() {
            "get_current_context" => self.current_context(work.chat).await,
            "get_chat" => match api::get_chat(&self.config.bot, chat).await {
                Ok(result) => json_value_result(&project_chat(&result)),
                Err(_) => HostToolResult::failure("Inline chat is unavailable to this agent."),
            },
            "get_messages" | "get_history" => {
                let page = self
                    .config
                    .bot
                    .history(HistoryRequest {
                        chat_id: InlineId::new(chat),
                        limit: Some(bounded_limit(arguments, 20, 100)),
                        before_message_id: positive_i64(arguments, "before_message_id")
                            .map(InlineId::new),
                        after_message_id: positive_i64(arguments, "after_message_id")
                            .map(InlineId::new),
                    })
                    .await;
                match page {
                    Ok(page) => json_value_result(&project_history(&page)),
                    Err(_) => HostToolResult::failure("Inline history is unavailable."),
                }
            }
            "read_link" => self.read_link(arguments, chat).await,
            "search_messages" => {
                let Some(query) = string_arg(arguments, "query", 500) else {
                    return HostToolResult::failure("query is required.");
                };
                match api::search_messages(
                    &self.config.bot,
                    chat,
                    query,
                    bounded_limit(arguments, 20, 100) as i32,
                    positive_i64(arguments, "offset_id"),
                )
                .await
                {
                    Ok(messages) => json_value_result(&project_proto_messages(messages)),
                    Err(_) => HostToolResult::failure("Inline message search failed."),
                }
            }
            "search_chats" => {
                let Some(query) = string_arg(arguments, "query", 200) else {
                    return HostToolResult::failure("query is required.");
                };
                let query = query.to_lowercase();
                self.dialogs(20, |dialog| {
                    dialog
                        .title
                        .as_deref()
                        .is_some_and(|title| title.to_lowercase().contains(&query))
                })
                .await
            }
            "list_my_threads" => {
                self.dialogs(bounded_limit(arguments, 30, 100) as usize, |_| true)
                    .await
            }
            "get_reactions" => {
                let Some(message_id) = positive_i64(arguments, "message_id") else {
                    return HostToolResult::failure("message_id is required.");
                };
                match api::get_messages(&self.config.bot, chat, vec![message_id]).await {
                    Ok(messages) => json_value_result(
                        &messages
                            .first()
                            .and_then(|message| message.reactions.clone()),
                    ),
                    Err(_) => HostToolResult::failure("Inline reactions lookup failed."),
                }
            }
            "list_pins" => match api::get_chat(&self.config.bot, chat).await {
                Ok(result) => HostToolResult::success(
                    json!({"chat_id": chat, "message_ids": result.pinned_message_ids}).to_string(),
                ),
                Err(_) => HostToolResult::failure("Inline chat is unavailable to this agent."),
            },
            "send_message" => self.send_message(arguments, work, chat, call).await,
            "find_contacts" => self.find_contacts(arguments).await,
            "add_reaction" | "remove_reaction" => {
                let (Some(message_id), Some(reaction)) = (
                    positive_i64(arguments, "message_id"),
                    string_arg(arguments, "reaction", 32),
                ) else {
                    return HostToolResult::failure("message_id and reaction are required.");
                };
                let remove = call.tool_name == "remove_reaction";
                match self
                    .config
                    .bot
                    .react(ReactRequest {
                        chat_id: InlineId::new(chat),
                        message_id: InlineId::new(message_id),
                        reaction,
                        remove,
                        external_id: ExternalId::try_new(
                            "agent-tool",
                            format!("{}-reaction", call.call_id),
                        )
                        .ok(),
                    })
                    .await
                {
                    Ok(()) => HostToolResult::success("Reaction updated."),
                    Err(_) => HostToolResult::failure("Inline could not update the reaction."),
                }
            }
            "pin_message" | "unpin_message" => {
                let Some(message_id) = positive_i64(arguments, "message_id") else {
                    return HostToolResult::failure("message_id is required.");
                };
                let unpin = call.tool_name == "unpin_message";
                match self
                    .config
                    .bot
                    .pin_message(PinMessageRequest {
                        chat_id: InlineId::new(chat),
                        message_id: InlineId::new(message_id),
                        unpin,
                    })
                    .await
                {
                    Ok(()) => HostToolResult::success(if unpin {
                        "Message unpinned."
                    } else {
                        "Message pinned."
                    }),
                    Err(_) => HostToolResult::failure("Inline could not update the pin."),
                }
            }
            "edit_own_message" => {
                let (Some(message_id), Some(text)) = (
                    positive_i64(arguments, "message_id"),
                    string_arg(arguments, "text", MAX_TEXT_CHARS),
                ) else {
                    return HostToolResult::failure("message_id and text are required.");
                };
                match self
                    .config
                    .bot
                    .edit_message(EditMessageRequest {
                        chat_id: InlineId::new(chat),
                        message_id: InlineId::new(message_id),
                        text,
                        external_id: ExternalId::try_new(
                            "agent-tool",
                            format!("{}-edit", call.call_id),
                        )
                        .ok(),
                        parse_markdown: true,
                    })
                    .await
                {
                    Ok(()) => HostToolResult::success("Message edited."),
                    Err(_) => HostToolResult::failure(
                        "Inline rejected the edit; only this agent's messages can be changed.",
                    ),
                }
            }
            "create_chat" => self.create_chat(arguments, call).await,
            "follow_thread" => self.follow_thread(arguments, chat).await,
            "start_subthread" => {
                let Some(title) = string_arg(arguments, "title", 200) else {
                    return HostToolResult::failure("title is required.");
                };
                self.through_work(
                    work,
                    WorkTool::StartSubthread {
                        title,
                        summary: string_arg(arguments, "summary", 2_000),
                        anchor_message_id: positive_i64(arguments, "anchor_message_id"),
                    },
                )
                .await
            }
            "return_attachment" => {
                let folder = self
                    .folders
                    .lock()
                    .expect("tool folders")
                    .get(work.session.as_str())
                    .cloned()
                    .unwrap_or_else(|| self.config.folder.clone());
                let roots = [folder.as_path(), self.config.attachments_dir.as_path()];
                return_local_file(
                    &self.config.bot,
                    ReturnFile {
                        chat_id: work.chat,
                        arguments,
                        roots: &roots,
                        attachments: &[],
                        attachment_cache_dir: &self.config.attachments_dir,
                        idempotency_seed: &call.call_id,
                    },
                )
                .await
            }
            _ => HostToolResult::failure("Unknown Inline tool."),
        }
    }

    /// Reads or changes this bot's own follow mode in a thread, as Hermes and
    /// OpenClaw's follow tools do, and reports what Inline reads back.
    async fn follow_thread(&self, arguments: &Value, chat: i64) -> HostToolResult {
        use inline_client::DialogFollowMode;
        let mode = match arguments
            .get("action")
            .and_then(Value::as_str)
            .unwrap_or("status")
        {
            "status" => None,
            "follow" => Some(DialogFollowMode::Following),
            "unfollow" => Some(DialogFollowMode::Unfollowed),
            _ => return HostToolResult::failure("action is status, follow or unfollow."),
        };
        let Ok(result) = api::get_chat(&self.config.bot, chat).await else {
            return HostToolResult::failure("Inline chat is unavailable to this agent.");
        };
        let direct = result
            .chat
            .as_ref()
            .and_then(|chat| chat.peer_id.as_ref())
            .is_some_and(|peer| matches!(peer.r#type, Some(proto::peer::Type::User(_))));
        if direct {
            return HostToolResult::failure(
                "Direct messages are always answered; there is nothing to follow.",
            );
        }
        let mut read = result.dialog.and_then(|dialog| dialog.follow_mode);
        if let Some(mode) = mode {
            let following = mode == DialogFollowMode::Following;
            if self
                .config
                .bot
                .update_dialog_follow_mode(inline_client::UpdateDialogFollowModeRequest {
                    chat_id: InlineId::new(chat),
                    mode,
                })
                .await
                .is_err()
            {
                return HostToolResult::failure("Inline could not change the follow mode.");
            }
            self.record_follow(chat, following);
            read = api::get_chat(&self.config.bot, chat)
                .await
                .ok()
                .and_then(|result| result.dialog)
                .and_then(|dialog| dialog.follow_mode);
        }
        let state = match read.and_then(|mode| proto::DialogFollowMode::try_from(mode).ok()) {
            Some(proto::DialogFollowMode::Following) => "following",
            Some(proto::DialogFollowMode::Unfollowed) => "unfollowed",
            _ => "default",
        };
        if let Some(mode) = mode {
            let expected = if mode == DialogFollowMode::Following {
                "following"
            } else {
                "unfollowed"
            };
            if state != expected {
                return HostToolResult::failure("Inline did not confirm the change.");
            }
        }
        HostToolResult::success(json!({"chat_id": chat, "follow_mode": state}).to_string())
    }

    async fn current_context(&self, chat: i64) -> HostToolResult {
        let thread = api::get_chat(&self.config.bot, chat).await.ok();
        json_value_result(&json!({
            "chat_id": chat,
            "thread": thread.as_ref().map(project_chat),
            "agent_user_id": self.config.bot_user_id,
            "agent_name": self.config.agent_name,
            "owner_user_id": self.config.owner_user_id,
            "provider": self.config.provider.as_str(),
            "mention_syntax": "[@Name](inline://user?id=USER_ID)",
            "thread_link_syntax": "[Title](inline://chat?id=CHAT_ID)",
        }))
    }

    async fn read_link(&self, arguments: &Value, chat: i64) -> HostToolResult {
        let message = string_arg(arguments, "url", 2_048)
            .and_then(|url| parse_link(&url))
            .and_then(|(_, message)| message);
        let thread = match api::get_chat(&self.config.bot, chat).await {
            Ok(result) => project_chat(&result),
            Err(_) => return HostToolResult::failure("Inline chat is unavailable to this agent."),
        };
        let messages = match message {
            Some(message_id) => {
                match api::get_messages(&self.config.bot, chat, vec![message_id]).await {
                    Ok(messages) => json!(project_proto_messages(messages)),
                    Err(_) => return HostToolResult::failure("Inline message is unavailable."),
                }
            }
            None => match self
                .config
                .bot
                .history(HistoryRequest {
                    chat_id: InlineId::new(chat),
                    limit: Some(20),
                    before_message_id: None,
                    after_message_id: None,
                })
                .await
            {
                Ok(page) => project_history(&page),
                Err(_) => return HostToolResult::failure("Inline history is unavailable."),
            },
        };
        json_value_result(&json!({"thread": thread, "messages": messages}))
    }

    async fn dialogs(&self, limit: usize, keep: impl Fn(&DialogRecord) -> bool) -> HostToolResult {
        match self
            .config
            .bot
            .cached_dialogs(DialogsRequest {
                limit: Some(100),
                cursor: None,
                order: DialogsOrder::RecentActivity,
            })
            .await
        {
            Ok(page) => {
                let dialogs: Vec<Value> = page
                    .dialogs
                    .iter()
                    .filter(|dialog| keep(dialog))
                    .take(limit)
                    .map(|dialog| {
                        json!({
                            "chat_id": dialog.chat_id.get(),
                            "title": dialog.title,
                            "parent_chat_id": dialog.parent_chat_id.map(InlineId::get),
                            "dm_user_id": dialog.peer_user_id.map(InlineId::get),
                        })
                    })
                    .collect();
                json_value_result(&dialogs)
            }
            Err(_) => HostToolResult::failure("Inline chats are unavailable."),
        }
    }

    async fn send(
        &self,
        chat: i64,
        reply_to: Option<i64>,
        text: &str,
        kind: &str,
        call_id: &str,
    ) -> HostToolResult {
        // A retried call reuses its random ID, so the server deduplicates it.
        let random_id = interaction_random_id(kind, call_id).get();
        match api::send_markdown(&self.config.bot, chat, reply_to, text, random_id).await {
            Ok(message_id) => {
                self.sent.lock().expect("sent").insert(message_id);
                HostToolResult::success(
                    json!({"chat_id": chat, "message_id": message_id}).to_string(),
                )
            }
            Err(_) => HostToolResult::failure("Inline could not send the message."),
        }
    }

    async fn create_chat(&self, arguments: &Value, call: &HostToolCall) -> HostToolResult {
        let (Some(title), Some(initial_message)) = (
            string_arg(arguments, "title", 200),
            string_arg(arguments, "initial_message", MAX_TEXT_CHARS),
        ) else {
            return HostToolResult::failure("title and initial_message are required.");
        };
        let mut participants = vec![
            ChatCreateParticipant::from(InlineId::new(self.config.owner_user_id)),
            ChatCreateParticipant::from(InlineId::new(self.config.bot_user_id)),
        ];
        participants.dedup_by_key(|participant| participant.user_id);
        let created = match self
            .config
            .bot
            .create_thread(CreateThreadRequest {
                title: Some(title),
                space_id: positive_i64(arguments, "space_id").map(InlineId::new),
                description: string_arg(arguments, "description", 500),
                emoji: string_arg(arguments, "emoji", 32),
                is_public: false,
                participants,
            })
            .await
        {
            Ok(created) => created,
            Err(_) => return HostToolResult::failure("Inline could not create the chat."),
        };
        let chat_id = created.chat_id.get();
        let sent = self
            .send(
                chat_id,
                None,
                &initial_message,
                "v2-create-chat",
                &call.call_id,
            )
            .await;
        if sent.success {
            HostToolResult::success(json!({"chat_id": chat_id}).to_string())
        } else {
            HostToolResult::failure(format!(
                "Inline created chat {chat_id}, but its first message failed. Reuse that chat instead of creating another."
            ))
        }
    }

    /// `send_message`: in the chat, or in the reply thread on a message
    /// (created or reused), adding mentioned users who aren't there yet. The
    /// result says, per mention, whether they were added and whether a
    /// mentioned agent will answer.
    async fn send_message(
        &self,
        arguments: &Value,
        work: &Work,
        chat: i64,
        call: &HostToolCall,
    ) -> HostToolResult {
        let Some(text) = string_arg(arguments, "text", MAX_TEXT_CHARS) else {
            return HostToolResult::failure("text is required.");
        };
        let anchor = match arguments.get("reply_thread") {
            None => None,
            Some(Value::String(current)) if current == "current" => {
                match self
                    .requests
                    .lock()
                    .expect("tool requests")
                    .get(work.session.as_str())
                    .copied()
                {
                    Some(request) => Some(request),
                    None => {
                        return HostToolResult::failure(
                            "No message started this work's current turn; pass a message ID as reply_thread.",
                        );
                    }
                }
            }
            Some(value) => match value.as_i64().filter(|id| *id > 0) {
                Some(message_id) => Some((chat, message_id)),
                None => {
                    return HostToolResult::failure("reply_thread is a message ID or \"current\".");
                }
            },
        };
        let destination = match anchor {
            None => chat,
            Some((parent, message_id)) => match self
                .config
                .bot
                .create_reply_thread(CreateReplyThreadRequest {
                    parent_chat_id: InlineId::new(parent),
                    parent_message_id: Some(InlineId::new(message_id)),
                    title: None,
                    description: None,
                    emoji: None,
                    participants: Vec::new(),
                    agent_context: None,
                })
                .await
            {
                Ok(created) => created.chat_id.get(),
                Err(_) => {
                    return HostToolResult::failure(
                        "Inline could not open the reply thread on that message.",
                    );
                }
            },
        };
        // A retried call reuses its random ID, so the server deduplicates it.
        let random_id = interaction_random_id("v2-send-message", &call.call_id).get();
        let sent = match api::send_markdown_adding_mentions(
            &self.config.bot,
            destination,
            positive_i64(arguments, "reply_to_message_id"),
            &text,
            random_id,
        )
        .await
        {
            Ok(sent) => sent,
            Err(_) => return HostToolResult::failure("Inline could not send the message."),
        };
        self.sent.lock().expect("sent").insert(sent.message_id);
        let mentioned: Vec<i64> = mentioned_user_ids(&text)
            .into_iter()
            .filter(|id| *id != self.config.bot_user_id)
            .collect();
        let reach = self.reach(&mentioned).await;
        let mut result = json!({"chat_id": destination, "message_id": sent.message_id});
        if anchor.is_some() {
            result["link"] = json!(format!("inline://chat?id={destination}"));
        }
        if !mentioned.is_empty() {
            result["mentions"] = json!(mention_report(&mentioned, &sent, &reach));
        }
        HostToolResult::success(result.to_string())
    }

    /// Whether each mentioned bot would answer this agent: `None` for people
    /// and for what Inline did not say.
    async fn reach(&self, user_ids: &[i64]) -> HashMap<i64, Reach> {
        let mut reach = HashMap::new();
        if user_ids.is_empty() {
            return reach;
        }
        let Ok(users) = api::get_users(&self.config.bot, user_ids.to_vec()).await else {
            return reach;
        };
        for user in users.iter().filter(|user| user.bot.unwrap_or(false)) {
            // What this agent (acting for its owner) may do with that bot.
            let can_use =
                match api::get_agent_access(&self.config.bot, user.id, self.config.bot_user_id)
                    .await
                {
                    Ok(access) => Some(
                        access.is_owner
                            || access
                                .operations
                                .contains(&(proto::AgentGrantOperation::Invoke as i32)),
                    ),
                    Err(_) => None,
                };
            reach.insert(
                user.id,
                Reach {
                    can_use,
                    offline: is_offline(user),
                },
            );
        }
        reach
    }

    /// `find_contacts`: people and agents this agent or its owner knows, with
    /// what this agent may do with each agent.
    async fn find_contacts(&self, arguments: &Value) -> HostToolResult {
        let kind = match arguments.get("kind").and_then(Value::as_str) {
            Some("people") => proto::ContactKind::People,
            Some("bots") => proto::ContactKind::Bots,
            _ => proto::ContactKind::All,
        };
        match api::get_contacts(
            &self.config.bot,
            string_arg(arguments, "query", 200),
            kind,
            bounded_limit(arguments, 20, 50) as i32,
        )
        .await
        {
            Ok(result) => json_value_result(&project_contacts(&result)),
            Err(_) => HostToolResult::failure("Inline contacts are unavailable."),
        }
    }

    async fn through_work(&self, work: &Work, tool: WorkTool) -> HostToolResult {
        let commands = self
            .works
            .lock()
            .expect("tool works")
            .get(work.session.as_str())
            .and_then(super::work::WeakCommandSender::upgrade);
        let Some(commands) = commands else {
            return HostToolResult::failure("This work is no longer running here.");
        };
        let (reply, answer) = oneshot::channel();
        if commands.send(Command::Tool { tool, reply }).await.is_err() {
            return HostToolResult::failure("This work is no longer running here.");
        }
        match tokio::time::timeout(WORK_ANSWER_TIMEOUT, answer).await {
            Ok(Ok(result)) => result,
            _ => HostToolResult::failure("The work did not answer in time."),
        }
    }
}

impl HostToolHandler for Tools {
    fn call<'a>(&'a self, call: HostToolCall) -> HostToolFuture<'a> {
        Box::pin(self.execute(call))
    }
}

/// The work a call acts for.
struct Work {
    chat: i64,
    /// The work's own session (a child resolves to its parent).
    session: ProviderSessionId,
}

/// The chat a call names: `chat_id`, or the chat of a `read_link` URL.
fn tool_target(call: &HostToolCall) -> Result<Option<i64>, &'static str> {
    if call.tool_name == "read_link" {
        let url = string_arg(&call.arguments, "url", 2_048).ok_or("url is required.")?;
        let (chat, _) = parse_link(&url).ok_or("This is not an Inline thread or message link.")?;
        return Ok(Some(chat));
    }
    Ok(positive_i64(&call.arguments, "chat_id"))
}

fn rejection_text(rejection: &ToolRejection) -> &'static str {
    match rejection {
        ToolRejection::UnknownTool => "Unknown Inline tool.",
        ToolRejection::UnboundSession => {
            "This session no longer acts for an Inline work, so Inline tools are unavailable."
        }
        ToolRejection::MissingIntent => {
            "This action needs confirmed_intent: true, set only when the person asked for it."
        }
        ToolRejection::TargetNotAccessible { .. } => {
            "That chat is not available to this agent here. Links never broaden access."
        }
    }
}

/// Parses an Inline thread or message link: `in://chat/12`,
/// `inline://chat/12/message/34`, `inline://thread?id=12` or
/// `https://inline.chat/c/12`.
pub(crate) fn parse_link(text: &str) -> Option<(i64, Option<i64>)> {
    let url = url::Url::parse(text.trim()).ok()?;
    let id = |value: &str| value.parse::<i64>().ok().filter(|id| *id > 0);
    let query = |names: &[&str]| {
        url.query_pairs()
            .find(|(key, _)| names.contains(&key.as_ref()))
            .and_then(|(_, value)| id(&value))
    };
    let parts: Vec<String> = url
        .path_segments()
        .map(|segments| {
            segments
                .filter(|part| !part.is_empty())
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    let host = url.host_str()?.to_ascii_lowercase();
    match url.scheme() {
        "in" | "inline" if host == "chat" || host == "thread" => {
            let chat = parts
                .first()
                .and_then(|part| id(part))
                .or_else(|| query(&["id", "chat_id", "chatId", "thread_id", "threadId"]))?;
            let message = match parts.as_slice() {
                [_, kind, message] if kind == "message" => id(message),
                _ => query(&["message_id", "messageId"]),
            };
            Some((chat, message))
        }
        "https" if host == "inline.chat" || host == "www.inline.chat" => match parts.as_slice() {
            [kind, chat] if kind == "c" => Some((id(chat)?, None)),
            _ => None,
        },
        _ => None,
    }
}

fn mention(name: &str, user_id: i64) -> String {
    let label: String = name
        .trim_start_matches('@')
        .chars()
        .filter(|character| !matches!(character, '[' | ']' | '(' | ')' | '\n'))
        .collect();
    format!("[@{label}](inline://user?id={user_id})")
}

/// Users mentioned in Markdown text (`[@Name](inline://user?id=N)`), in order,
/// without repeats.
fn mentioned_user_ids(text: &str) -> Vec<i64> {
    const LINK: &str = "inline://user?id=";
    let mut ids = Vec::new();
    for (start, _) in text.match_indices(LINK) {
        let digits: String = text[start + LINK.len()..]
            .chars()
            .take_while(char::is_ascii_digit)
            .collect();
        if let Some(id) = digits.parse::<i64>().ok().filter(|id| *id > 0)
            && !ids.contains(&id)
        {
            ids.push(id);
        }
    }
    ids
}

/// Whether a mentioned bot will answer this agent.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Reach {
    /// This agent (or its owner) may use the bot; `None` when unknown.
    can_use: Option<bool>,
    offline: bool,
}

/// This agent may start work on the contact: it (or its owner) manages the
/// bot or holds INVOKE on it.
fn contact_can_use(contact: &proto::Contact) -> bool {
    contact.manages_bot
        || contact
            .bot_operations
            .contains(&(proto::AgentGrantOperation::Invoke as i32))
}

fn is_offline(user: &proto::User) -> bool {
    user.status
        .as_ref()
        .is_some_and(|status| status.online == proto::user_status::Status::Offline as i32)
}

/// Per mention: `added` to the thread, `already_in` it, or `cant_add` (not a
/// contact of this agent or its owner, or not in the space). Mentioned agents
/// that won't answer get `wont_respond`: `no_access` (no INVOKE, not managed)
/// or `offline`. Notes for the agent to pass on, not failures.
fn mention_report(
    mentioned: &[i64],
    sent: &api::SentMessage,
    reach: &HashMap<i64, Reach>,
) -> Vec<Value> {
    mentioned
        .iter()
        .map(|user_id| {
            let status = if sent.added_user_ids.contains(user_id) {
                "added"
            } else if sent.unadded_user_ids.contains(user_id) {
                "cant_add"
            } else {
                "already_in"
            };
            let mut row = json!({"user_id": user_id, "status": status});
            if let Some(reach) = reach.get(user_id) {
                row["is_bot"] = json!(true);
                if reach.can_use == Some(false) {
                    row["wont_respond"] = json!("no_access");
                } else if reach.offline {
                    row["wont_respond"] = json!("offline");
                }
            }
            row
        })
        .collect()
}

fn relation_name(relation: i32) -> Option<&'static str> {
    use proto::ContactRelation as Relation;
    Some(match Relation::try_from(relation).ok()? {
        Relation::Unspecified => return None,
        Relation::SharedChat => "shared_chat",
        Relation::SharedSpace => "shared_space",
        Relation::Managed => "managed",
        Relation::Owner => "owner",
        Relation::CanUse => "can_use",
        Relation::UsesYourBot => "uses_your_bot",
    })
}

/// Compact contact rows: who they are, how they're known, whether this agent
/// may use a bot, and how to mention them.
fn project_contacts(result: &proto::GetContactsResult) -> Value {
    let users: HashMap<i64, &proto::User> =
        result.users.iter().map(|user| (user.id, user)).collect();
    let name = |user_id: i64| {
        users
            .get(&user_id)
            .and_then(|user| api::display_name(user))
            .unwrap_or_else(|| format!("user {user_id}"))
    };
    let rows: Vec<Value> = result
        .contacts
        .iter()
        .map(|contact| {
            let user = users.get(&contact.user_id);
            let is_bot = user.is_some_and(|user| user.bot.unwrap_or(false));
            let display = name(contact.user_id);
            let mut row = json!({
                "user_id": contact.user_id,
                "name": display,
                "username": user.and_then(|user| user.username.clone()),
                "is_bot": is_bot,
                "relations": contact
                    .relations
                    .iter()
                    .filter_map(|relation| relation_name(*relation))
                    .collect::<Vec<_>>(),
                "via_owner": contact.via_owner,
                "mention": mention(&display, contact.user_id),
            });
            if let Some(status) = user.and_then(|user| user.status.as_ref()) {
                match proto::user_status::Status::try_from(status.online) {
                    Ok(proto::user_status::Status::Online) => row["online"] = json!(true),
                    Ok(proto::user_status::Status::Offline) => row["online"] = json!(false),
                    _ => {}
                }
            }
            if is_bot {
                row["can_use"] = json!(contact_can_use(contact));
                if let Some(owner) = user.and_then(|user| api::bot_owner(user)) {
                    row["owner"] = json!({"user_id": owner, "name": name(owner)});
                }
            }
            if let Some(date) = contact.last_interaction_date {
                row["last_interaction_date"] = json!(date);
            }
            row
        })
        .collect();
    json!({"contacts": rows})
}

fn project_chat(result: &proto::GetChatResult) -> Value {
    let chat = result.chat.as_ref();
    json!({
        "chat_id": chat.map(|chat| chat.id),
        "title": chat.map(|chat| chat.title.clone()),
        "description": chat.and_then(|chat| chat.description.clone()),
        "space_id": chat.and_then(|chat| chat.space_id),
        "parent_chat_id": chat.and_then(|chat| chat.parent_chat_id),
        "parent_message_id": chat.and_then(|chat| chat.parent_message_id),
        "is_public": chat.and_then(|chat| chat.is_public),
        "pinned_message_ids": result.pinned_message_ids,
    })
}

fn project_history(page: &HistoryPage) -> Value {
    let names: HashMap<i64, String> = page
        .users
        .iter()
        .filter_map(|user| {
            let name = user
                .display_name
                .clone()
                .or_else(|| user.first_name.clone())
                .or_else(|| user.username.clone())?;
            Some((user.user_id.get(), name))
        })
        .collect();
    let messages: Vec<Value> = page
        .messages
        .iter()
        .map(|message| {
            let sender = message.sender_id.get();
            json!({
                "message_id": message.message_id.get(),
                "sender_user_id": sender,
                "sender_name": names.get(&sender),
                "timestamp": message.timestamp,
                "text": super::intake::message_text(&message.content)
                    .chars()
                    .take(2_000)
                    .collect::<String>(),
                "reply_to_message_id": message.reply_to_message_id.map(InlineId::get),
            })
        })
        .collect();
    json!({"messages": messages, "has_more": page.has_more})
}

/// The v2 catalog (spec §4.8). Names served by v1 keep their names.
pub(crate) fn specs() -> Vec<HostToolSpec> {
    let read = [
        (
            "get_current_context",
            "Get this work's Inline thread, your identity as an agent, your owner, and the mention and link syntax.",
        ),
        ("get_chat", "Get one Inline chat you can access."),
        (
            "get_messages",
            "Get a page of messages from a chat you can access (default: this work's thread).",
        ),
        (
            "get_history",
            "Get chat history around message ID cursors (default: this work's thread).",
        ),
        (
            "read_link",
            "Read an Inline thread or message link. Links never broaden access: only threads you can already access are read.",
        ),
        (
            "search_messages",
            "Search messages in a chat you can access (default: this work's thread).",
        ),
        ("search_chats", "Search your threads by title."),
        (
            "list_my_threads",
            "List the threads you are in, most recent first.",
        ),
        ("get_reactions", "Get the reactions on one message."),
        ("list_pins", "List pinned message IDs in a chat."),
        (
            "find_contacts",
            "Find people and agents you or your owner know, to mention and ask. Each row has the mention to use; for agents, can_use says whether you may ask them and owner says whose they are.",
        ),
    ];
    let writes = [
        (
            "send_message",
            "Send a message (default: this work's thread). Markdown; mention with [@Name](inline://user?id=ID), link a thread with [Title](inline://chat?id=ID). To ask a person or agent, start the message with their mention, usually with reply_thread to post in the reply thread on a message (\"current\": the message that started this turn). Mentioned people and agents not in the thread are added when you may. The result reports each mention: added, already_in or cant_add, and wont_respond (no_access, offline) for agents that won't answer. Mentioning an agent wakes it: never start reciprocal agent loops.",
        ),
        ("add_reaction", "Add a reaction to a message."),
        ("remove_reaction", "Remove your reaction from a message."),
        (
            "pin_message",
            "Pin a message, only when a person asked for it.",
        ),
        (
            "unpin_message",
            "Unpin a message, only when a person asked for it.",
        ),
        ("edit_own_message", "Edit a message you sent."),
        (
            "create_chat",
            "Create a new private thread with your owner and send its first message, only when a person asked for one.",
        ),
        (
            "start_subthread",
            "Move this work into a new subthread of its thread, for long, multi-step or approval-heavy work. The thread keeps a status card linking to it; replies in the subthread reach this work.",
        ),
        (
            "return_attachment",
            "Send a local file from your folder to this work's thread as native Inline media, only when a person asked to receive it. Choose image, video or file from their request.",
        ),
        (
            "follow_thread",
            "Check, start or stop following a thread (default: this work's thread), only when a person asked. Following: you answer every message there from people with access. Unfollowed: only mentions and replies to you.",
        ),
    ];
    read.into_iter()
        .map(|(name, description)| spec(name, description, true))
        .chain(
            writes
                .into_iter()
                .map(|(name, description)| spec(name, description, false)),
        )
        .collect()
}

fn spec(name: &str, description: &str, read_only: bool) -> HostToolSpec {
    HostToolSpec {
        name: name.to_owned(),
        description: description.to_owned(),
        input_schema: input_schema(name),
        read_only,
    }
}

fn input_schema(name: &str) -> Value {
    let chat_id = json!({"type": "integer", "minimum": 1});
    let message_id = json!({"type": "integer", "minimum": 1});
    let limit = json!({"type": "integer", "minimum": 1, "maximum": 100});
    let intent = json!({"type": "boolean", "const": true});
    let text = json!({"type": "string", "minLength": 1, "maxLength": MAX_TEXT_CHARS});
    let (properties, required): (Value, &[&str]) = match name {
        "get_current_context" => (json!({}), &[]),
        "get_chat" | "list_pins" => (json!({"chat_id": chat_id}), &[]),
        "get_messages" | "get_history" => (
            json!({
                "chat_id": chat_id,
                "before_message_id": message_id,
                "after_message_id": message_id,
                "limit": limit,
            }),
            &[],
        ),
        "read_link" => (
            json!({"url": {"type": "string", "minLength": 1, "maxLength": 2048}}),
            &["url"],
        ),
        "search_messages" => (
            json!({
                "chat_id": chat_id,
                "query": {"type": "string", "minLength": 1, "maxLength": 500},
                "offset_id": message_id,
                "limit": limit,
            }),
            &["query"],
        ),
        "search_chats" => (
            json!({"query": {"type": "string", "minLength": 1, "maxLength": 200}}),
            &["query"],
        ),
        "list_my_threads" => (json!({"limit": limit}), &[]),
        "get_reactions" => (
            json!({"chat_id": chat_id, "message_id": message_id}),
            &["message_id"],
        ),
        "send_message" => (
            json!({
                "chat_id": chat_id,
                "text": text,
                "reply_to_message_id": message_id,
                "reply_thread": {
                    "anyOf": [
                        {"type": "integer", "minimum": 1},
                        {"type": "string", "const": "current"},
                    ],
                },
            }),
            &["text"],
        ),
        "find_contacts" => (
            json!({
                "query": {"type": "string", "minLength": 1, "maxLength": 200},
                "kind": {"type": "string", "enum": ["all", "people", "bots"]},
                "limit": {"type": "integer", "minimum": 1, "maximum": 50},
            }),
            &[],
        ),
        "add_reaction" | "remove_reaction" => (
            json!({
                "chat_id": chat_id,
                "message_id": message_id,
                "reaction": {"type": "string", "minLength": 1, "maxLength": 32},
            }),
            &["message_id", "reaction"],
        ),
        "pin_message" | "unpin_message" => (
            json!({"chat_id": chat_id, "message_id": message_id, "confirmed_intent": intent}),
            &["message_id", "confirmed_intent"],
        ),
        "edit_own_message" => (
            json!({
                "chat_id": chat_id,
                "message_id": message_id,
                "text": text,
                "confirmed_intent": intent,
            }),
            &["message_id", "text", "confirmed_intent"],
        ),
        "create_chat" => (
            json!({
                "title": {"type": "string", "minLength": 1, "maxLength": 200},
                "initial_message": text,
                "space_id": {"type": "integer", "minimum": 1},
                "description": {"type": "string", "maxLength": 500},
                "emoji": {"type": "string", "maxLength": 32},
                "confirmed_intent": intent,
            }),
            &["title", "initial_message", "confirmed_intent"],
        ),
        "start_subthread" => (
            json!({
                "title": {"type": "string", "minLength": 1, "maxLength": 200},
                "summary": {"type": "string", "maxLength": 2000},
                "anchor_message_id": message_id,
            }),
            &["title"],
        ),
        "return_attachment" => (
            json!({
                "path": {"type": "string", "minLength": 1, "maxLength": 4096},
                "kind": {"type": "string", "enum": ["image", "video", "file"]},
                "file_name": {"type": "string", "minLength": 1, "maxLength": 240},
                "caption": {"type": "string", "maxLength": 2000},
                "confirmed_intent": intent,
            }),
            &["path", "kind", "confirmed_intent"],
        ),
        "follow_thread" => (
            json!({
                "chat_id": chat_id,
                "action": {"type": "string", "enum": ["status", "follow", "unfollow"]},
            }),
            &["action"],
        ),
        _ => (json!({}), &[]),
    };
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": properties,
        "required": required,
    })
}

#[cfg(test)]
mod tests {
    use inline_agent_bridge::group::{TOOL_CATALOG, ToolTarget, tool};

    use super::*;

    #[test]
    fn specs_match_the_catalog() {
        let names: HashSet<String> = specs().into_iter().map(|spec| spec.name).collect();
        let catalog: HashSet<String> = TOOL_CATALOG
            .iter()
            .map(|tool| tool.name.to_owned())
            .collect();
        assert_eq!(names, catalog);
        for spec in specs() {
            let descriptor = tool(&spec.name).expect("catalog entry");
            assert_eq!(spec.read_only, descriptor.read_only, "{}", spec.name);
            // A tool that needs intent must ask for it in its schema.
            let asks = spec.input_schema["required"]
                .as_array()
                .is_some_and(|required| required.iter().any(|key| key == "confirmed_intent"));
            assert_eq!(asks, descriptor.needs_intent, "{}", spec.name);
            // Only tools that may leave the work's thread take a chat_id.
            let takes_chat = spec.input_schema["properties"].get("chat_id").is_some();
            assert_eq!(
                takes_chat,
                descriptor.target == ToolTarget::Accessible && spec.name != "read_link",
                "{}",
                spec.name
            );
        }
    }

    #[test]
    fn links_name_a_thread_and_maybe_a_message() {
        assert_eq!(parse_link("in://chat/12"), Some((12, None)));
        assert_eq!(
            parse_link("inline://chat/12/message/34"),
            Some((12, Some(34)))
        );
        assert_eq!(parse_link("inline://thread?id=7"), Some((7, None)));
        assert_eq!(
            parse_link("inline://chat?id=7&message_id=9"),
            Some((7, Some(9)))
        );
        assert_eq!(parse_link("https://inline.chat/c/55"), Some((55, None)));
        assert_eq!(parse_link("https://example.com/c/55"), None);
        assert_eq!(parse_link("inline://user/5"), None);
        assert_eq!(parse_link("in://chat/-3"), None);
        assert_eq!(parse_link("not a link"), None);
    }

    #[test]
    fn mentions_are_read_from_markdown_links() {
        assert_eq!(
            mentioned_user_ids(
                "[@Dena](inline://user?id=8) and [@Codex](inline://user?id=41), [@Dena](inline://user?id=8)"
            ),
            vec![8, 41]
        );
        assert!(mentioned_user_ids("no mentions, inline://user?id=x").is_empty());
    }

    #[test]
    fn each_mention_reports_whether_it_was_added_and_will_answer() {
        let sent = api::SentMessage {
            message_id: 1,
            added_user_ids: vec![8, 41],
            unadded_user_ids: vec![9],
        };
        let reach = HashMap::from([
            (
                41,
                Reach {
                    can_use: Some(false),
                    offline: true,
                },
            ),
            (
                42,
                Reach {
                    can_use: Some(true),
                    offline: true,
                },
            ),
            (
                43,
                Reach {
                    can_use: Some(true),
                    offline: false,
                },
            ),
        ]);
        let report = mention_report(&[8, 9, 41, 42, 43], &sent, &reach);
        assert_eq!(report[0], json!({"user_id": 8, "status": "added"}));
        assert_eq!(report[1], json!({"user_id": 9, "status": "cant_add"}));
        assert_eq!(
            report[2],
            json!({"user_id": 41, "status": "added", "is_bot": true, "wont_respond": "no_access"})
        );
        assert_eq!(
            report[3],
            json!({"user_id": 42, "status": "already_in", "is_bot": true, "wont_respond": "offline"})
        );
        assert_eq!(
            report[4],
            json!({"user_id": 43, "status": "already_in", "is_bot": true})
        );
    }

    #[test]
    fn contacts_project_to_compact_rows() {
        let owner = proto::User {
            id: 7,
            first_name: Some("Dena".into()),
            username: Some("dena".into()),
            status: Some(proto::UserStatus {
                online: proto::user_status::Status::Online as i32,
                last_online: None,
            }),
            ..Default::default()
        };
        let codex = proto::User {
            id: 41,
            first_name: Some("Dena's Codex".into()),
            username: Some("dena_codex_bot".into()),
            bot: Some(true),
            bot_info: Some(proto::BotInfo {
                owner: Some(proto::bot_info::Owner::OwnerUserId(7)),
            }),
            status: Some(proto::UserStatus {
                online: proto::user_status::Status::Offline as i32,
                last_online: None,
            }),
            ..Default::default()
        };
        let result = proto::GetContactsResult {
            contacts: vec![
                proto::Contact {
                    user_id: 41,
                    relations: vec![
                        proto::ContactRelation::SharedSpace as i32,
                        proto::ContactRelation::CanUse as i32,
                    ],
                    via_owner: true,
                    bot_operations: vec![proto::AgentGrantOperation::Invoke as i32],
                    ..Default::default()
                },
                proto::Contact {
                    user_id: 7,
                    relations: vec![proto::ContactRelation::SharedChat as i32],
                    last_interaction_date: Some(100),
                    ..Default::default()
                },
            ],
            users: vec![owner, codex],
        };
        let rows = project_contacts(&result);
        assert_eq!(
            rows["contacts"][0],
            json!({
                "user_id": 41,
                "name": "Dena's Codex",
                "username": "dena_codex_bot",
                "is_bot": true,
                "relations": ["shared_space", "can_use"],
                "via_owner": true,
                "mention": "[@Dena's Codex](inline://user?id=41)",
                "online": false,
                "can_use": true,
                "owner": {"user_id": 7, "name": "Dena"},
            })
        );
        let person = &rows["contacts"][1];
        assert_eq!(person["is_bot"], json!(false));
        assert_eq!(person["online"], json!(true));
        assert_eq!(person["last_interaction_date"], json!(100));
        assert!(person.get("can_use").is_none());
        // Without INVOKE or management, an agent can't be used.
        assert!(!contact_can_use(&proto::Contact {
            bot_operations: vec![proto::AgentGrantOperation::Steer as i32],
            ..Default::default()
        }));
        assert!(contact_can_use(&proto::Contact {
            manages_bot: true,
            ..Default::default()
        }));
    }

    #[test]
    fn reply_thread_takes_a_message_or_current() {
        let schema = input_schema("send_message");
        for arguments in [
            json!({"text": "hi", "reply_thread": 12}),
            json!({"text": "hi", "reply_thread": "current"}),
        ] {
            assert!(
                validate_tool_arguments(&arguments, &schema).is_ok(),
                "{arguments}"
            );
        }
        for arguments in [
            json!({"text": "hi", "reply_thread": 0}),
            json!({"text": "hi", "reply_thread": "latest"}),
        ] {
            assert!(
                validate_tool_arguments(&arguments, &schema).is_err(),
                "{arguments}"
            );
        }
    }

    #[test]
    fn mentions_cannot_break_out_of_their_link() {
        assert_eq!(mention("@Ma](x)ya", 4), "[@Maxya](inline://user?id=4)");
    }
}
