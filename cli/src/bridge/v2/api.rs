//! Typed Inline calls the v2 runtime makes as its bot, over the client's raw
//! RPC path: messages with blocks, run state, heartbeats, grants and
//! participation.

use inline_client::{ClientRequestError, InlineClient};
use inline_protocol::proto;

use super::doc::Doc;

pub(crate) type ApiResult<T> = Result<T, ApiError>;

#[derive(Debug, thiserror::Error)]
pub(crate) enum ApiError {
    #[error(transparent)]
    Request(#[from] ClientRequestError),
    #[error("Inline returned an unexpected result for {0}")]
    UnexpectedResult(&'static str),
}

/// What to do after Inline did not take a message or an edit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Failure {
    /// Try again later, after the server's delay when it gave one. Covers
    /// network loss, timeouts and an unknown outcome: the same random ID
    /// makes a repeat harmless.
    Retry(Option<std::time::Duration>),
    /// Inline refused it as it is (too large, invalid): the same request
    /// fails again.
    Refused,
    /// The chat or message is gone.
    Gone,
}

impl ApiError {
    pub(crate) fn failure(&self) -> Failure {
        use inline_client::ClientErrorCategory as Category;
        let Self::Request(ClientRequestError::Backend(error)) = self else {
            return Failure::Retry(None);
        };
        match error.category {
            // Only a refusal of this request itself. An unsupported method or a
            // protocol mismatch can clear after a deploy or a reconnect.
            Category::InvalidInput => Failure::Refused,
            Category::NotFound => Failure::Gone,
            Category::RateLimited => Failure::Retry(
                error
                    .retry_after_seconds
                    .map(std::time::Duration::from_secs),
            ),
            _ => Failure::Retry(None),
        }
    }
}

macro_rules! call {
    ($bot:expr, $method:ident, $input:expr) => {{
        match $bot
            .invoke_rpc(
                proto::Method::$method,
                proto::rpc_call::Input::$method($input),
            )
            .await?
        {
            proto::rpc_result::Result::$method(result) => Ok(result),
            _ => Err(ApiError::UnexpectedResult(stringify!($method))),
        }
    }};
}

pub(crate) fn chat_peer(chat_id: i64) -> proto::InputPeer {
    proto::InputPeer {
        r#type: Some(proto::input_peer::Type::Chat(proto::InputPeerChat {
            chat_id,
        })),
    }
}

/// How a sent message notifies.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Notify {
    /// Progress and updates: delivered without a notification.
    Silent,
    /// Final answers and cards.
    Normal,
}

/// Sends a rendered message and returns its ID.
pub(crate) async fn send_doc(
    bot: &InlineClient,
    chat_id: i64,
    reply_to: Option<i64>,
    doc: &Doc,
    actions: Option<proto::MessageActions>,
    notify: Notify,
) -> ApiResult<i64> {
    let random_id = rand::random::<i64>().abs().max(1);
    send_doc_as(bot, chat_id, reply_to, doc, actions, notify, random_id).await
}

/// Sends a rendered message under a caller-chosen random ID. Inline keeps one
/// message per sender and random ID, so a retry with the same ID returns the
/// message a lost reply already created instead of posting it twice.
pub(crate) async fn send_doc_as(
    bot: &InlineClient,
    chat_id: i64,
    reply_to: Option<i64>,
    doc: &Doc,
    actions: Option<proto::MessageActions>,
    notify: Notify,
    random_id: i64,
) -> ApiResult<i64> {
    let result = call!(
        bot,
        SendMessage,
        proto::SendMessageInput {
            peer_id: Some(chat_peer(chat_id)),
            message: Some(doc.text.clone()),
            reply_to_msg_id: reply_to,
            random_id: Some(random_id),
            parse_markdown: Some(doc.markdown),
            send_mode: (notify == Notify::Silent)
                .then_some(proto::MessageSendMode::ModeSilent as i32),
            actions,
            block_content: (!doc.markdown && !doc.blocks.is_empty()).then(|| doc.block_content()),
            ..Default::default()
        }
    )?;
    sent_message_id(&result.updates, random_id).ok_or(ApiError::UnexpectedResult("SendMessage"))
}

fn sent_message_id(updates: &[proto::Update], random_id: i64) -> Option<i64> {
    updates.iter().find_map(|update| match &update.update {
        Some(proto::update::Update::UpdateMessageId(update)) if update.random_id == random_id => {
            Some(update.message_id)
        }
        Some(proto::update::Update::NewMessage(update)) => {
            update.message.as_ref().map(|message| message.id)
        }
        _ => None,
    })
}

/// Replaces a message's text, blocks and actions.
pub(crate) async fn edit_doc(
    bot: &InlineClient,
    chat_id: i64,
    message_id: i64,
    doc: &Doc,
    actions: Option<proto::MessageActions>,
) -> ApiResult<()> {
    call!(
        bot,
        EditMessage,
        proto::EditMessageInput {
            message_id,
            peer_id: Some(chat_peer(chat_id)),
            text: doc.text.clone(),
            parse_markdown: Some(doc.markdown),
            actions,
            block_content: (!doc.markdown).then(|| doc.block_content()),
            ..Default::default()
        }
    )?;
    Ok(())
}

pub(crate) async fn report_runtime(
    bot: &InlineClient,
    input: proto::ReportAgentRuntimeInput,
) -> ApiResult<proto::ReportAgentRuntimeResult> {
    call!(bot, ReportAgentRuntime, input)
}

pub(crate) async fn update_session_state(
    bot: &InlineClient,
    agent_session_id: i64,
    state: proto::AgentSessionState,
) -> ApiResult<()> {
    call!(
        bot,
        UpdateAgentSessionState,
        proto::UpdateAgentSessionStateInput {
            agent_session_id,
            state: Some(state),
        }
    )?;
    Ok(())
}

/// The "working" compose action, shown like typing (spinner instead of dots).
/// It expires on its own in the apps, so it is repeated while working.
pub(crate) async fn send_working(bot: &InlineClient, chat_id: i64, working: bool) -> ApiResult<()> {
    call!(
        bot,
        SendComposeAction,
        proto::SendComposeActionInput {
            peer_id: Some(chat_peer(chat_id)),
            action: working.then_some(proto::update_compose_action::ComposeAction::Working as i32),
        }
    )?;
    Ok(())
}

pub(crate) async fn list_grants(bot: &InlineClient) -> ApiResult<proto::ListAgentGrantsResult> {
    call!(
        bot,
        ListAgentGrants,
        proto::ListAgentGrantsInput { bot_user_id: 0 }
    )
}

pub(crate) async fn participations(
    bot: &InlineClient,
    chat_id: i64,
) -> ApiResult<Vec<proto::AgentParticipation>> {
    Ok(call!(
        bot,
        GetAgentParticipations,
        proto::GetAgentParticipationsInput {
            peer_id: Some(chat_peer(chat_id)),
        }
    )?
    .participations)
}

pub(crate) async fn join(bot: &InlineClient, chat_id: i64, bot_user_id: i64) -> ApiResult<()> {
    call!(
        bot,
        SetAgentParticipation,
        proto::SetAgentParticipationInput {
            peer_id: Some(chat_peer(chat_id)),
            bot_user_id,
            mode: proto::AgentParticipationMode::Active as i32,
            ..Default::default()
        }
    )?;
    Ok(())
}

pub(crate) async fn import_grants(bot: &InlineClient, user_ids: Vec<i64>) -> ApiResult<()> {
    call!(
        bot,
        ImportAgentGrants,
        proto::ImportAgentGrantsInput { user_ids }
    )?;
    Ok(())
}

/// Reads a chat as the bot; the server refuses chats the bot cannot access.
pub(crate) async fn get_chat(bot: &InlineClient, chat_id: i64) -> ApiResult<proto::GetChatResult> {
    call!(
        bot,
        GetChat,
        proto::GetChatInput {
            peer_id: Some(chat_peer(chat_id)),
            include_recent_messages: false,
        }
    )
}

pub(crate) async fn get_messages(
    bot: &InlineClient,
    chat_id: i64,
    message_ids: Vec<i64>,
) -> ApiResult<Vec<proto::Message>> {
    Ok(call!(
        bot,
        GetMessages,
        proto::GetMessagesInput {
            peer_id: Some(chat_peer(chat_id)),
            message_ids,
        }
    )?
    .messages)
}

pub(crate) async fn search_messages(
    bot: &InlineClient,
    chat_id: i64,
    query: String,
    limit: i32,
    offset_id: Option<i64>,
) -> ApiResult<Vec<proto::Message>> {
    Ok(call!(
        bot,
        SearchMessages,
        proto::SearchMessagesInput {
            peer_id: Some(chat_peer(chat_id)),
            queries: vec![query],
            limit: Some(limit),
            offset_id,
            filter: None,
        }
    )?
    .messages)
}

pub(crate) async fn get_users(
    bot: &InlineClient,
    user_ids: Vec<i64>,
) -> ApiResult<Vec<proto::User>> {
    Ok(call!(bot, GetUsers, proto::GetUsersInput { user_ids })?.users)
}

/// Sends Markdown text (mentions as `[@Name](inline://user?id=N)`, thread
/// links as `[Title](inline://chat?id=N)`) and returns the message ID.
pub(crate) async fn send_markdown(
    bot: &InlineClient,
    chat_id: i64,
    reply_to: Option<i64>,
    text: &str,
    random_id: i64,
) -> ApiResult<i64> {
    let result = call!(
        bot,
        SendMessage,
        proto::SendMessageInput {
            peer_id: Some(chat_peer(chat_id)),
            message: Some(text.to_owned()),
            reply_to_msg_id: reply_to,
            random_id: Some(random_id),
            parse_markdown: Some(true),
            ..Default::default()
        }
    )?;
    sent_message_id(&result.updates, random_id).ok_or(ApiError::UnexpectedResult("SendMessage"))
}

/// Moves a work's publication into a subthread of its chat (spec §5.2).
pub(crate) async fn move_session(
    bot: &InlineClient,
    agent_session_id: i64,
    destination: i64,
) -> ApiResult<proto::MoveAgentSessionResult> {
    call!(
        bot,
        MoveAgentSession,
        proto::MoveAgentSessionInput {
            agent_session_id,
            destination_peer_id: Some(chat_peer(destination)),
        }
    )
}

pub(crate) async fn edit_markdown(
    bot: &InlineClient,
    chat_id: i64,
    message_id: i64,
    text: &str,
) -> ApiResult<()> {
    call!(
        bot,
        EditMessage,
        proto::EditMessageInput {
            message_id,
            peer_id: Some(chat_peer(chat_id)),
            text: text.to_owned(),
            parse_markdown: Some(true),
            ..Default::default()
        }
    )?;
    Ok(())
}

/// Display names of Inline users, as this bot sees them, cached for the run.
pub(crate) struct Names {
    bot: InlineClient,
    cache: tokio::sync::Mutex<std::collections::HashMap<i64, String>>,
    /// Whether each user is a bot, for senders the local store has not met.
    bots: tokio::sync::Mutex<std::collections::HashMap<i64, bool>>,
}

impl Names {
    pub(crate) fn new(bot: InlineClient) -> Self {
        Self {
            bot,
            cache: tokio::sync::Mutex::new(std::collections::HashMap::new()),
            bots: tokio::sync::Mutex::new(std::collections::HashMap::new()),
        }
    }

    /// Whether the user is a bot (an agent), asking Inline once when the
    /// store does not know. Unknown counts as a person.
    pub(crate) async fn is_bot(&self, user_id: i64) -> bool {
        if let Some(bot) = self.bots.lock().await.get(&user_id) {
            return *bot;
        }
        let Some(user) = get_users(&self.bot, vec![user_id])
            .await
            .ok()
            .and_then(|users| users.into_iter().find(|user| user.id == user_id))
        else {
            return false;
        };
        let bot = user.bot.unwrap_or(false);
        self.bots.lock().await.insert(user_id, bot);
        if let Some(name) = display_name(&user) {
            self.remember(user_id, name).await;
        }
        bot
    }

    pub(crate) async fn remember(&self, user_id: i64, name: String) {
        self.cache.lock().await.entry(user_id).or_insert(name);
    }

    /// The user's name, or "user N" when Inline does not say.
    pub(crate) async fn of(&self, user_id: i64) -> String {
        if let Some(name) = self.cache.lock().await.get(&user_id) {
            return name.clone();
        }
        let found = get_users(&self.bot, vec![user_id])
            .await
            .ok()
            .and_then(|users| users.into_iter().find(|user| user.id == user_id))
            .and_then(|user| display_name(&user));
        match found {
            Some(name) => {
                self.remember(user_id, name.clone()).await;
                name
            }
            None => format!("user {user_id}"),
        }
    }
}

fn display_name(user: &proto::User) -> Option<String> {
    let full = [user.first_name.as_deref(), user.last_name.as_deref()]
        .into_iter()
        .flatten()
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    (!full.is_empty())
        .then_some(full)
        .or_else(|| user.username.clone().filter(|name| !name.trim().is_empty()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use inline_client::{BackendError, ClientErrorCategory};

    fn error(category: ClientErrorCategory, retry_after: Option<u64>) -> ApiError {
        let mut error = BackendError::new(category, "test");
        error.retry_after_seconds = retry_after;
        ApiError::Request(ClientRequestError::Backend(error))
    }

    #[test]
    fn failures_say_whether_a_retry_can_help() {
        use std::time::Duration;
        assert_eq!(
            error(ClientErrorCategory::InvalidInput, None).failure(),
            Failure::Refused
        );
        assert_eq!(
            error(ClientErrorCategory::NotFound, None).failure(),
            Failure::Gone
        );
        assert_eq!(
            error(ClientErrorCategory::RateLimited, Some(7)).failure(),
            Failure::Retry(Some(Duration::from_secs(7)))
        );
        for category in [
            ClientErrorCategory::Unsupported,
            ClientErrorCategory::ProtocolMismatch,
            ClientErrorCategory::Network,
            ClientErrorCategory::Timeout,
            ClientErrorCategory::CommitOutcomeUnknown,
            ClientErrorCategory::Internal,
        ] {
            assert_eq!(error(category, None).failure(), Failure::Retry(None));
        }
        assert_eq!(
            ApiError::UnexpectedResult("SendMessage").failure(),
            Failure::Retry(None)
        );
    }
}
