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
    ChatCreateParticipant, CreateThreadRequest, DialogRecord, DialogsOrder, DialogsRequest,
    EditMessageRequest, ExternalId, HistoryPage, HistoryRequest, InlineClient, InlineId,
    PinMessageRequest, ReactRequest,
};
use inline_protocol::proto;
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

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
    works: Mutex<HashMap<String, mpsc::WeakSender<Command>>>,
    /// Session → the folder its work runs in.
    folders: Mutex<HashMap<String, PathBuf>>,
    /// Messages this bot sent, so replies to them address it.
    sent: Arc<Mutex<HashSet<i64>>>,
}

impl Tools {
    pub(crate) fn new(config: ToolsConfig) -> Arc<Self> {
        Arc::new(Self {
            config,
            bindings: Mutex::new(ToolBindings::default()),
            works: Mutex::new(HashMap::new()),
            folders: Mutex::new(HashMap::new()),
            sent: Arc::new(Mutex::new(HashSet::new())),
        })
    }

    pub(crate) fn sent(&self) -> Arc<Mutex<HashSet<i64>>> {
        self.sent.clone()
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
        commands: mpsc::WeakSender<Command>,
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
            "send_message" => {
                let Some(text) = string_arg(arguments, "text", MAX_TEXT_CHARS) else {
                    return HostToolResult::failure("text is required.");
                };
                self.send(
                    chat,
                    positive_i64(arguments, "reply_to_message_id"),
                    &text,
                    "v2-send-message",
                    &call.call_id,
                )
                .await
            }
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
            "ask_teammate" => self.ask_teammate(arguments, work.chat, call).await,
            _ => HostToolResult::failure("Unknown Inline tool."),
        }
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

    async fn ask_teammate(
        &self,
        arguments: &Value,
        chat: i64,
        call: &HostToolCall,
    ) -> HostToolResult {
        let (Some(user_id), Some(question)) = (
            positive_i64(arguments, "user_id"),
            string_arg(arguments, "question", MAX_TEXT_CHARS),
        ) else {
            return HostToolResult::failure("user_id and question are required.");
        };
        let name = match string_arg(arguments, "name", 120) {
            Some(name) => name,
            None => api::get_users(&self.config.bot, vec![user_id])
                .await
                .ok()
                .and_then(|users| users.into_iter().next())
                .and_then(|user| user.first_name.or(user.username))
                .unwrap_or_else(|| "teammate".to_owned()),
        };
        let text = format!("{} {question}", mention(&name, user_id));
        self.send(chat, None, &text, "v2-ask-teammate", &call.call_id)
            .await
    }

    async fn through_work(&self, work: &Work, tool: WorkTool) -> HostToolResult {
        let commands = self
            .works
            .lock()
            .expect("tool works")
            .get(work.session.as_str())
            .and_then(mpsc::WeakSender::upgrade);
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
    ];
    let writes = [
        (
            "send_message",
            "Send a message (default: this work's thread). Markdown; mention with [@Name](inline://user?id=ID), link a thread with [Title](inline://chat?id=ID). Mentioning an agent wakes it: never start reciprocal agent loops.",
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
            "ask_teammate",
            "Ask a person or agent in this work's thread a question, mentioning them.",
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
            json!({"chat_id": chat_id, "text": text, "reply_to_message_id": message_id}),
            &["text"],
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
        "ask_teammate" => (
            json!({
                "user_id": {"type": "integer", "minimum": 1},
                "question": text,
                "name": {"type": "string", "minLength": 1, "maxLength": 120},
            }),
            &["user_id", "question"],
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
    fn mentions_cannot_break_out_of_their_link() {
        assert_eq!(mention("@Ma](x)ya", 4), "[@Maxya](inline://user?id=4)");
    }
}
