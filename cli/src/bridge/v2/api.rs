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
    let result = call!(
        bot,
        SendMessage,
        proto::SendMessageInput {
            peer_id: Some(chat_peer(chat_id)),
            message: Some(doc.text.clone()),
            reply_to_msg_id: reply_to,
            random_id: Some(random_id),
            parse_markdown: Some(false),
            send_mode: (notify == Notify::Silent)
                .then_some(proto::MessageSendMode::ModeSilent as i32),
            actions,
            block_content: (!doc.blocks.is_empty()).then(|| doc.block_content()),
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
            parse_markdown: Some(false),
            actions,
            block_content: Some(doc.block_content()),
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
