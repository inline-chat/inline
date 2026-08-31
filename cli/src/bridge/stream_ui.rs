//! Resilient Inline message delivery and provider-neutral turn presentation.

use super::*;

#[cfg(not(test))]
pub(super) const TYPING_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(2);
#[cfg(test)]
pub(super) const TYPING_HEARTBEAT_INTERVAL: Duration = Duration::from_millis(10);

#[cfg(not(test))]
const TYPING_SEND_TIMEOUT: Duration = Duration::from_secs(2);
#[cfg(test)]
const TYPING_SEND_TIMEOUT: Duration = Duration::from_millis(10);

pub(super) trait StreamMessageTransport {
    async fn edit(&self, request: EditMessageRequest) -> Result<(), Box<dyn std::error::Error>>;

    async fn send(
        &self,
        request: SendTextRequest,
    ) -> Result<inline_client::MessageMutation, Box<dyn std::error::Error>>;

    async fn send_media(
        &self,
        request: UploadRequest,
        bytes: Vec<u8>,
    ) -> Result<inline_client::MessageMutation, Box<dyn std::error::Error>>;
}

pub(super) struct InlineStreamMessageTransport<'a>(pub(super) &'a InlineClient);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum BridgeNotificationClass {
    RoutineStatus,
    ActionRequired,
    TerminalAnswer,
    ImportantNotice,
    ImportantFailure,
}

impl BridgeNotificationClass {
    pub(super) fn notification_mode(self) -> SendNotificationMode {
        match self {
            Self::RoutineStatus => SendNotificationMode::Silent,
            Self::ActionRequired
            | Self::TerminalAnswer
            | Self::ImportantNotice
            | Self::ImportantFailure => SendNotificationMode::Normal,
        }
    }
}

impl StreamMessageTransport for InlineStreamMessageTransport<'_> {
    async fn edit(&self, request: EditMessageRequest) -> Result<(), Box<dyn std::error::Error>> {
        self.0.edit_message(request).await.map_err(Into::into)
    }

    async fn send(
        &self,
        request: SendTextRequest,
    ) -> Result<inline_client::MessageMutation, Box<dyn std::error::Error>> {
        self.0.send_text(request).await.map_err(Into::into)
    }

    async fn send_media(
        &self,
        request: UploadRequest,
        bytes: Vec<u8>,
    ) -> Result<inline_client::MessageMutation, Box<dyn std::error::Error>> {
        self.0.send_media(request, bytes).await.map_err(Into::into)
    }
}

pub(super) async fn send_text_reply(
    bot: &InlineClient,
    chat_id: i64,
    reply_to_message_id: i64,
    text: &str,
    external_id: &str,
    notification_class: BridgeNotificationClass,
) -> Result<inline_client::MessageMutation, Box<dyn std::error::Error>> {
    send_text_reply_with_mode(
        bot,
        chat_id,
        reply_to_message_id,
        text,
        external_id,
        notification_class.notification_mode(),
    )
    .await
}

pub(super) async fn send_silent_text(
    bot: &InlineClient,
    chat_id: i64,
    text: &str,
    external_id: &str,
) -> Result<inline_client::MessageMutation, Box<dyn std::error::Error>> {
    send_text_with_mode(
        bot,
        chat_id,
        None,
        text,
        external_id,
        SendNotificationMode::Silent,
    )
    .await
}

pub(super) async fn send_text_message(
    bot: &InlineClient,
    chat_id: i64,
    text: &str,
    external_id: &str,
    notification_class: BridgeNotificationClass,
) -> Result<inline_client::MessageMutation, Box<dyn std::error::Error>> {
    send_text_with_mode(
        bot,
        chat_id,
        None,
        text,
        external_id,
        notification_class.notification_mode(),
    )
    .await
}

async fn send_text_reply_with_mode(
    bot: &InlineClient,
    chat_id: i64,
    reply_to_message_id: i64,
    text: &str,
    external_id: &str,
    notification_mode: SendNotificationMode,
) -> Result<inline_client::MessageMutation, Box<dyn std::error::Error>> {
    send_text_with_mode(
        bot,
        chat_id,
        Some(reply_to_message_id),
        text,
        external_id,
        notification_mode,
    )
    .await
}

async fn send_text_with_mode(
    bot: &InlineClient,
    chat_id: i64,
    reply_to_message_id: Option<i64>,
    text: &str,
    external_id: &str,
    notification_mode: SendNotificationMode,
) -> Result<inline_client::MessageMutation, Box<dyn std::error::Error>> {
    let request = build_text_request(
        chat_id,
        reply_to_message_id,
        text,
        external_id,
        notification_mode,
    )?;
    send_text_with_retry(bot, request).await
}

fn build_text_request(
    chat_id: i64,
    reply_to_message_id: Option<i64>,
    text: &str,
    external_id: &str,
    notification_mode: SendNotificationMode,
) -> Result<SendTextRequest, Box<dyn std::error::Error>> {
    let mut request = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(chat_id),
        },
        text,
    );
    request.reply_to_message_id = reply_to_message_id.map(InlineId::new);
    request.external_id = Some(ExternalId::try_new("agent-bridge", external_id)?);
    request.parse_markdown = true;
    request.notification_mode = notification_mode;
    Ok(request)
}

pub(super) async fn send_text_with_retry(
    bot: &InlineClient,
    request: SendTextRequest,
) -> Result<inline_client::MessageMutation, Box<dyn std::error::Error>> {
    let mut last_error = None;
    for attempt in 0..3 {
        match bot.send_text(request.clone()).await {
            Ok(mutation) => return Ok(mutation),
            Err(error) => last_error = Some(error),
        }
        if attempt < 2 {
            tokio::time::sleep(message_retry_delay(attempt)).await;
        }
    }
    Err(last_error
        .map(|error| Box::new(error) as Box<dyn std::error::Error>)
        .unwrap_or_else(|| Box::new(io::Error::other("Inline message could not be delivered"))))
}

pub(super) async fn send_interactive_text_with_retry(
    bot: &InlineClient,
    request: SendInteractiveTextRequest,
) -> Result<inline_client::MessageMutation, Box<dyn std::error::Error>> {
    let mut last_error = None;
    for attempt in 0..3 {
        match bot.send_interactive_text(request.clone()).await {
            Ok(mutation) => return Ok(mutation),
            Err(error) => last_error = Some(error),
        }
        if attempt < 2 {
            tokio::time::sleep(message_retry_delay(attempt)).await;
        }
    }
    Err(last_error
        .map(|error| Box::new(error) as Box<dyn std::error::Error>)
        .unwrap_or_else(|| {
            Box::new(io::Error::other(
                "Inline interactive message could not be delivered",
            ))
        }))
}

pub(super) async fn edit_message_with_retry(
    bot: &InlineClient,
    request: EditMessageRequest,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut last_error = None;
    for attempt in 0..3 {
        match bot.edit_message(request.clone()).await {
            Ok(()) => return Ok(()),
            Err(error) => last_error = Some(error),
        }
        if attempt < 2 {
            tokio::time::sleep(message_retry_delay(attempt)).await;
        }
    }
    Err(last_error
        .map(|error| Box::new(error) as Box<dyn std::error::Error>)
        .unwrap_or_else(|| Box::new(io::Error::other("Inline message could not be edited"))))
}

pub(super) async fn edit_interactive_message_with_retry(
    bot: &InlineClient,
    request: EditInteractiveMessageRequest,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut last_error = None;
    for attempt in 0..3 {
        match bot.edit_interactive_message(request.clone()).await {
            Ok(()) => return Ok(()),
            Err(error) => last_error = Some(error),
        }
        if attempt < 2 {
            tokio::time::sleep(message_retry_delay(attempt)).await;
        }
    }
    Err(last_error
        .map(|error| Box::new(error) as Box<dyn std::error::Error>)
        .unwrap_or_else(|| {
            Box::new(io::Error::other(
                "Inline interactive message could not be edited",
            ))
        }))
}

pub(super) fn new_terminal_random_id() -> RandomId {
    loop {
        let value = i64::try_from(OsRng.next_u64() & i64::MAX as u64).unwrap_or(0);
        if value > 0 {
            return RandomId::new(value);
        }
    }
}

async fn update_progress_with_transport<T: StreamMessageTransport>(
    transport: &T,
    chat_id: i64,
    message_id: Option<InlineId>,
    text: &str,
    retry_delay: impl Fn(u32) -> Duration,
) -> Result<(), Box<dyn std::error::Error>> {
    let message_id = message_id
        .ok_or_else(|| io::Error::other("Inline progress message identity is unavailable"))?;
    let request = EditMessageRequest {
        chat_id: InlineId::new(chat_id),
        message_id,
        text: text.to_string(),
        external_id: None,
        parse_markdown: true,
    };
    let mut last_error = None;
    for attempt in 0..3 {
        match transport.edit(request.clone()).await {
            Ok(()) => return Ok(()),
            Err(error) => last_error = Some(error),
        }
        if attempt < 2 {
            tokio::time::sleep(retry_delay(attempt)).await;
        }
    }
    Err(last_error.unwrap_or_else(|| {
        Box::new(io::Error::other(
            "Inline progress message could not be edited",
        ))
    }))
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn sync_turn_progress(
    bot: &InlineClient,
    store: &BridgeStore,
    event_id: &str,
    chat_id: i64,
    primary_message_id: Option<InlineId>,
    message_ids: &mut Vec<InlineId>,
    chunks: &[String],
    hidden_continuation_text: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    if message_ids.is_empty() {
        message_ids.extend(
            store
                .inbound_progress(event_id)?
                .message_ids
                .into_iter()
                .map(InlineId::new),
        );
    }
    if message_ids.is_empty()
        && let Some(message_id) = primary_message_id
    {
        let stored = store
            .attach_inbound_progress_message(event_id, 0, message_id.get())?
            .map(InlineId::new)
            .unwrap_or(message_id);
        message_ids.push(stored);
    }
    if let Err(error) = sync_progress_with_transport(
        &InlineStreamMessageTransport(bot),
        store,
        event_id,
        chat_id,
        message_ids,
        chunks,
        hidden_continuation_text,
        message_retry_delay,
    )
    .await
    {
        eprintln!(
            "Inline progress update is temporarily unavailable: {}",
            safe_diagnostic(&error.to_string())
        );
    }
    Ok(())
}

pub(super) fn persist_progress_ledger(
    store: &BridgeStore,
    event_id: &str,
    tracker: &ActivityTracker,
) -> Result<(), Box<dyn std::error::Error>> {
    let ledger = tracker.durable_json()?;
    if !store.put_inbound_progress_ledger(event_id, &ledger)? {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "started turn disappeared before its progress ledger was persisted",
        )
        .into());
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn sync_progress_with_transport<T: StreamMessageTransport>(
    transport: &T,
    store: &BridgeStore,
    event_id: &str,
    chat_id: i64,
    message_ids: &mut Vec<InlineId>,
    chunks: &[String],
    hidden_continuation_text: &str,
    retry_delay: impl Fn(u32) -> Duration + Copy,
) -> Result<(), Box<dyn std::error::Error>> {
    for (index, text) in chunks.iter().enumerate() {
        let message_id = if let Some(message_id) = message_ids.get(index).copied() {
            message_id
        } else {
            let external_id = if index == 0 {
                format!("{event_id}-working")
            } else {
                format!("{event_id}-working-{index}")
            };
            let request = build_text_request(
                chat_id,
                None,
                text,
                &external_id,
                SendNotificationMode::Silent,
            )?;
            let mut mutation = None;
            for attempt in 0..3 {
                if let Ok(sent) = transport.send(request.clone()).await
                    && sent.message_id.is_some()
                {
                    mutation = sent.message_id;
                    break;
                }
                if attempt < 2 {
                    tokio::time::sleep(retry_delay(attempt)).await;
                }
            }
            let candidate = mutation.ok_or_else(|| {
                io::Error::other("Inline progress continuation could not be delivered")
            })?;
            let stored = store
                .attach_inbound_progress_message(event_id, index, candidate.get())?
                .map(InlineId::new)
                .ok_or_else(|| {
                    io::Error::other("turn ended before progress identity could be persisted")
                })?;
            message_ids.push(stored);
            stored
        };
        update_progress_with_transport(transport, chat_id, Some(message_id), text, retry_delay)
            .await?;
    }
    for message_id in message_ids.iter().skip(chunks.len()).copied() {
        update_progress_with_transport(
            transport,
            chat_id,
            Some(message_id),
            hidden_continuation_text,
            retry_delay,
        )
        .await?;
    }
    Ok(())
}

#[cfg(test)]
pub(super) async fn resolve_progress_with_transport<T: StreamMessageTransport>(
    transport: &T,
    event_id: &str,
    chat_id: i64,
    persisted_message_id: Option<InlineId>,
    retry_delay: impl Fn(u32) -> Duration,
) -> Option<InlineId> {
    if persisted_message_id.is_some() {
        return persisted_message_id;
    }
    let request = match build_text_request(
        chat_id,
        None,
        WORKING_STATUS,
        &format!("{event_id}-working"),
        SendNotificationMode::Silent,
    ) {
        Ok(request) => request,
        Err(error) => {
            eprintln!(
                "Inline progress identity could not be recovered: {}",
                safe_diagnostic(&error.to_string())
            );
            return None;
        }
    };
    for attempt in 0..3 {
        if let Ok(mutation) = transport.send(request.clone()).await
            && mutation.message_id.is_some()
        {
            return mutation.message_id;
        }
        if attempt < 2 {
            tokio::time::sleep(retry_delay(attempt)).await;
        }
    }
    eprintln!("Inline progress identity could not be recovered; sending the answer anyway");
    None
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn publish_inbound_final_send(
    bot: &InlineClient,
    store: &BridgeStore,
    event_id: &str,
    chat_id: i64,
    progress_message_id: Option<InlineId>,
    progress_status: &str,
    final_text: &str,
    state: InboundState,
    failure: Option<&str>,
) -> Result<Option<InlineId>, Box<dyn std::error::Error>> {
    publish_inbound_final_send_with_attachments(
        bot,
        store,
        event_id,
        chat_id,
        progress_message_id,
        progress_status,
        final_text,
        &[],
        None,
        state,
        failure,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn publish_inbound_final_send_with_attachments(
    bot: &InlineClient,
    store: &BridgeStore,
    event_id: &str,
    chat_id: i64,
    progress_message_id: Option<InlineId>,
    progress_status: &str,
    final_text: &str,
    output_attachments: &[OutputAttachment],
    preferred_random_id: Option<RandomId>,
    state: InboundState,
    failure: Option<&str>,
) -> Result<Option<InlineId>, Box<dyn std::error::Error>> {
    if !store.stage_inbound_final_send_with_attachments(
        event_id,
        state,
        final_text,
        output_attachments,
        failure,
    )? {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "started turn disappeared before final message delivery",
        )
        .into());
    }
    let preferred_random_id = preferred_random_id.unwrap_or_else(new_terminal_random_id);
    let random_id = store
        .ensure_inbound_final_send_random_id(event_id, preferred_random_id.get())?
        .map(RandomId::new)
        .ok_or_else(|| io::Error::other("staged final send is missing its random identity"))?;
    let mutation = deliver_pending_final_send_with_attachments(
        bot,
        event_id,
        chat_id,
        progress_message_id,
        progress_status,
        random_id,
        final_text,
        output_attachments,
    )
    .await?;
    if !store.commit_inbound_final_send(event_id)? {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "staged turn disappeared before final-send commit",
        )
        .into());
    }
    Ok(mutation.message_id)
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn deliver_pending_final_send_with_attachments(
    bot: &InlineClient,
    event_id: &str,
    chat_id: i64,
    progress_message_id: Option<InlineId>,
    progress_status: &str,
    random_id: RandomId,
    final_text: &str,
    output_attachments: &[OutputAttachment],
) -> Result<inline_client::MessageMutation, Box<dyn std::error::Error>> {
    deliver_pending_final_with_attachments_transport(
        &InlineStreamMessageTransport(bot),
        event_id,
        chat_id,
        progress_message_id,
        progress_status,
        random_id,
        final_text,
        output_attachments,
        message_retry_delay,
    )
    .await
}

#[cfg(test)]
#[allow(clippy::too_many_arguments)]
pub(super) async fn deliver_pending_final_with_transport<T: StreamMessageTransport>(
    transport: &T,
    event_id: &str,
    chat_id: i64,
    progress_message_id: Option<InlineId>,
    progress_status: &str,
    random_id: RandomId,
    final_text: &str,
    retry_delay: impl Fn(u32) -> Duration,
) -> Result<inline_client::MessageMutation, Box<dyn std::error::Error>> {
    deliver_pending_final_with_attachments_transport(
        transport,
        event_id,
        chat_id,
        progress_message_id,
        progress_status,
        random_id,
        final_text,
        &[],
        retry_delay,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn deliver_pending_final_with_attachments_transport<T: StreamMessageTransport>(
    transport: &T,
    event_id: &str,
    chat_id: i64,
    progress_message_id: Option<InlineId>,
    progress_status: &str,
    random_id: RandomId,
    final_text: &str,
    output_attachments: &[OutputAttachment],
    retry_delay: impl Fn(u32) -> Duration,
) -> Result<inline_client::MessageMutation, Box<dyn std::error::Error>> {
    if let Some(message_id) = progress_message_id {
        let request = EditMessageRequest {
            chat_id: InlineId::new(chat_id),
            message_id,
            text: progress_status.to_string(),
            external_id: None,
            parse_markdown: true,
        };
        let mut terminalized = false;
        for attempt in 0..3 {
            if transport.edit(request.clone()).await.is_ok() {
                terminalized = true;
                break;
            }
            if attempt < 2 {
                tokio::time::sleep(retry_delay(attempt)).await;
            }
        }
        if !terminalized {
            eprintln!("Inline progress status could not be finalized; sending the answer anyway");
        }
    }

    for (index, attachment) in output_attachments.iter().enumerate() {
        let bytes = verified_output_attachment_bytes(attachment)?;
        let external_key = format!("{event_id}-asset-{index}");
        let request = UploadRequest {
            peer: PeerRef::Chat {
                chat_id: InlineId::new(chat_id),
            },
            kind: match attachment.kind {
                OutputAttachmentKind::Image => MediaKind::Photo,
            },
            file_name: Some(attachment.file_name.clone()),
            mime_type: Some(attachment.mime_type.clone()),
            size_bytes: Some(attachment.size_bytes),
            caption: None,
            width: None,
            height: None,
            duration_ms: None,
            external_id: Some(ExternalId::try_new("agent-bridge", &external_key)?),
            random_id: Some(interaction_random_id("terminal-asset", &external_key)),
            reply_to_message_id: None,
        };
        let mut last_error = None;
        for attempt in 0..3 {
            match transport.send_media(request.clone(), bytes.clone()).await {
                Ok(_) => {
                    last_error = None;
                    break;
                }
                Err(error) => last_error = Some(error),
            }
            if attempt < 2 {
                tokio::time::sleep(retry_delay(attempt)).await;
            }
        }
        if let Some(error) = last_error {
            return Err(error);
        }
    }

    let mut request = build_text_request(
        chat_id,
        None,
        final_text,
        &format!("{event_id}-final"),
        BridgeNotificationClass::TerminalAnswer.notification_mode(),
    )?;
    request.random_id = Some(random_id);

    let mut last_error = None;
    for attempt in 0..3 {
        match transport.send(request.clone()).await {
            Ok(mutation) => return Ok(mutation),
            Err(error) => last_error = Some(error),
        }
        if attempt < 2 {
            tokio::time::sleep(retry_delay(attempt)).await;
        }
    }
    Err(last_error.unwrap_or_else(|| {
        Box::new(io::Error::other(
            "Inline final answer could not be delivered",
        ))
    }))
}

fn verified_output_attachment_bytes(
    attachment: &OutputAttachment,
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    const MAX_OUTPUT_BYTES: u64 = 20 * 1024 * 1024;
    if !attachment.path.is_absolute()
        || attachment.size_bytes == 0
        || attachment.size_bytes > MAX_OUTPUT_BYTES
        || attachment.sha256.len() != 64
        || !attachment
            .sha256
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(io::Error::other("agent output attachment metadata is invalid").into());
    }
    let metadata = fs::symlink_metadata(&attachment.path)?;
    if !metadata.file_type().is_file() || metadata.len() != attachment.size_bytes {
        return Err(io::Error::other("agent output attachment changed before delivery").into());
    }
    let bytes = fs::read(&attachment.path)?;
    if format!("{:x}", Sha256::digest(&bytes)) != attachment.sha256 {
        return Err(io::Error::other("agent output attachment failed integrity validation").into());
    }
    match attachment.kind {
        OutputAttachmentKind::Image if supported_output_image(&attachment.mime_type, &bytes) => {}
        _ => return Err(io::Error::other("agent output attachment format is unsupported").into()),
    }
    Ok(bytes)
}

fn supported_output_image(mime_type: &str, bytes: &[u8]) -> bool {
    match mime_type {
        "image/png" => bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
        "image/jpeg" => bytes.starts_with(b"\xff\xd8\xff"),
        "image/webp" => {
            bytes.len() >= 12 && bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP")
        }
        "image/gif" => bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a"),
        _ => false,
    }
}

pub(super) trait TypingTransport {
    async fn send_typing(
        &self,
        chat_id: InlineId,
        is_typing: bool,
    ) -> Result<(), Box<dyn std::error::Error>>;
}

impl TypingTransport for InlineClient {
    async fn send_typing(
        &self,
        chat_id: InlineId,
        is_typing: bool,
    ) -> Result<(), Box<dyn std::error::Error>> {
        self.typing(TypingRequest { chat_id, is_typing })
            .await
            .map_err(Into::into)
    }
}

/// Best-effort compose action bound to the exact Inline conversation that
/// accepted the direction. Reply threads are independent chat peers, so their
/// child chat ID must remain stable across start, heartbeat, and clear.
pub(super) struct TypingIndicator<'a, T: TypingTransport> {
    transport: &'a T,
    chat_id: InlineId,
    active: bool,
}

impl<'a, T: TypingTransport> TypingIndicator<'a, T> {
    pub(super) async fn start(transport: &'a T, chat_id: i64) -> Self {
        let indicator = Self {
            transport,
            chat_id: InlineId::new(chat_id),
            active: true,
        };
        indicator.send(true).await;
        indicator
    }

    pub(super) async fn heartbeat(&self) {
        if self.active {
            self.send(true).await;
        }
    }

    pub(super) async fn stop(&mut self) {
        if self.active {
            self.active = false;
            self.send(false).await;
        }
    }

    async fn send(&self, is_typing: bool) {
        let _ = tokio::time::timeout(
            TYPING_SEND_TIMEOUT,
            self.transport.send_typing(self.chat_id, is_typing),
        )
        .await;
    }
}

pub(super) async fn attach_changed_file_actions(
    bot: &InlineClient,
    chat_id: i64,
    message_id: InlineId,
    text: &str,
    files: &[FileChange],
    workspace: &Path,
) {
    let actions = changed_file_actions(files, workspace);
    if actions.rows.is_empty() {
        return;
    }
    let request = EditInteractiveMessageRequest {
        message: EditMessageRequest {
            chat_id: InlineId::new(chat_id),
            message_id,
            text: text.to_string(),
            external_id: None,
            parse_markdown: true,
        },
        actions,
    };
    if let Err(error) = edit_interactive_message_with_retry(bot, request).await {
        eprintln!(
            "Could not attach changed-file actions: {}",
            safe_diagnostic(&error.to_string())
        );
    }
}

pub(super) fn message_retry_delay(attempt: u32) -> Duration {
    let entropy = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos() as u64;
    message_retry_delay_with_entropy(attempt, entropy)
}

pub(super) fn message_retry_delay_with_entropy(attempt: u32, entropy: u64) -> Duration {
    let multiplier = 1_u64 << attempt.min(3);
    let base_ms = 150_u64.saturating_mul(multiplier).min(1_200);
    let percent = 75 + entropy % 51;
    Duration::from_millis(base_ms.saturating_mul(percent) / 100)
}

pub(super) fn changed_file_actions(files: &[FileChange], workspace: &Path) -> MessageActions {
    let mut seen = HashSet::new();
    let rows = files
        .iter()
        .filter_map(|file| safe_relative_path(&file.path, workspace))
        .filter_map(|path| {
            let text = path.to_str()?.to_string();
            (!text.trim().is_empty() && text.encode_utf16().count() <= 4096).then_some((path, text))
        })
        .filter(|(_, text)| seen.insert(text.clone()))
        .take(8)
        .enumerate()
        .map(|(index, (path, text))| {
            let name = path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("path");
            MessageActionRow {
                actions: vec![MessageActionButton {
                    action_id: format!("bridge_copy_path_{index}"),
                    text: truncate_utf16(&format!("Copy Path · {name}"), 64),
                    kind: MessageActionKind::CopyText { text },
                }],
            }
        })
        .collect();
    MessageActions { rows }
}

const MAX_TRACKED_ACTIVITIES: usize = 64;
const MAX_TRACKED_PROGRESS_FILES: usize = 64;
const MAX_TRACKED_LEGACY_ACTIVITIES: usize = 32;
const MAX_TRACKED_PLAN_STEPS: usize = 64;
const MAX_TRACKED_PATHS_PER_ACTIVITY: usize = 4;
const MAX_TRACKED_MESSAGES: usize = 32;
const MAX_MESSAGE_TEXT_BYTES: usize = 16 * 1024;
const MESSAGE_OMITTED_MARKER: &str = "\n\n[additional output omitted]";

const MAX_PROGRESS_CHUNK_BYTES: usize = 12 * 1024;
const PROGRESS_OMITTED_MARKER: &str = "- [additional activity omitted]";

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum ProgressEntry {
    Message {
        key: String,
        phase: Option<AgentMessagePhase>,
        text: String,
        complete: bool,
    },
    Activity {
        key: String,
        semantic_kind: ActivitySemanticKind,
        status: ActivityStatus,
        title: String,
        detail: Option<String>,
        paths: Vec<String>,
        exit_code: Option<i32>,
    },
    Plan {
        key: String,
        text: String,
        status: PlanStepStatus,
    },
    Legacy {
        key: u64,
        summary: String,
    },
    File {
        path: String,
    },
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub(super) struct ActivityTracker {
    entries: Vec<ProgressEntry>,
    current_plan_keys: Vec<String>,
    plan_generation: u64,
    legacy_sequence: u64,
    omitted: bool,
    visibility_verbose: bool,
    terminal_header: Option<String>,
    workspace_line: Option<String>,
}

#[derive(Debug)]
pub(super) struct ActivityProjection {
    pub status: Option<String>,
    pub priority: UpdatePriority,
    pub validation: Option<ValidationSummary>,
}

impl ActivityTracker {
    pub(super) fn set_workspace(&mut self, workspace: &Path) {
        let line = working_directory_message(workspace)
            .chars()
            .filter(|character| !character.is_control())
            .collect::<String>();
        self.workspace_line = Some(truncate(&line, 1024));
    }

    pub(super) fn apply_message(
        &mut self,
        item_id: &str,
        incoming_phase: Option<AgentMessagePhase>,
        update: AgentMessageUpdate,
    ) {
        if !self
            .entries
            .iter()
            .any(|entry| matches!(entry, ProgressEntry::Message { key, .. } if key == item_id))
        {
            if self
                .entries
                .iter()
                .filter(|entry| matches!(entry, ProgressEntry::Message { .. }))
                .count()
                >= MAX_TRACKED_MESSAGES
            {
                // Keep the latest answer eligible even after a long turn overflows.
                if let Some(index) = self
                    .entries
                    .iter()
                    .position(|entry| matches!(entry, ProgressEntry::Message { .. }))
                {
                    self.entries.remove(index);
                }
                self.omitted = true;
            }
            self.entries.push(ProgressEntry::Message {
                key: item_id.to_string(),
                phase: incoming_phase,
                text: String::new(),
                complete: false,
            });
        }
        if let Some(ProgressEntry::Message {
            phase,
            text,
            complete,
            ..
        }) = self
            .entries
            .iter_mut()
            .find(|entry| matches!(entry, ProgressEntry::Message { key, .. } if key == item_id))
        {
            if incoming_phase.is_some() {
                *phase = incoming_phase;
            }
            match update {
                AgentMessageUpdate::Started => {}
                AgentMessageUpdate::Delta(delta) if !*complete => append_message_text(text, &delta),
                AgentMessageUpdate::Delta(_) => {}
                AgentMessageUpdate::Completed(snapshot) => {
                    text.clear();
                    append_message_text(text, &snapshot);
                    *complete = true;
                }
            }
        }
    }

    fn final_message(&self) -> Option<(&str, &str)> {
        let explicit = self.entries.iter().rev().find_map(|entry| match entry {
            ProgressEntry::Message {
                key,
                phase: Some(AgentMessagePhase::FinalAnswer),
                text,
                ..
            } if !text.trim().is_empty() => Some((key.as_str(), text.as_str())),
            _ => None,
        });
        explicit.or_else(|| {
            self.entries.iter().rev().find_map(|entry| match entry {
                ProgressEntry::Message {
                    key,
                    phase: None | Some(AgentMessagePhase::Unknown),
                    text,
                    complete: true,
                } if !text.trim().is_empty() => Some((key.as_str(), text.as_str())),
                _ => None,
            })
        })
    }

    pub(super) fn final_message_text(&self) -> Option<&str> {
        self.final_message().map(|(_, text)| text)
    }

    pub(super) fn apply(
        &mut self,
        activity: ActivityUpsert,
        mode: VisibilityMode,
        workspace: &Path,
    ) -> ActivityProjection {
        self.set_visibility(mode);
        let validation = activity_validation(&activity);
        // Reasoning is a transient provider state, not a public transcript row.
        if activity.kind == ActivitySemanticKind::Think {
            return ActivityProjection {
                status: self.render(mode, WORKING_STATUS, workspace),
                priority: UpdatePriority::Ordinary,
                validation,
            };
        }
        let paths = activity
            .paths
            .iter()
            .filter_map(|path| normalized_progress_path(path, workspace))
            .take(MAX_TRACKED_PATHS_PER_ACTIVITY)
            .collect::<Vec<_>>();
        let incoming_title = truncate(
            &sanitize_visible_transcript(&activity.title).unwrap_or_else(|| "Tool activity".into()),
            240,
        );
        let incoming_detail = activity
            .detail
            .as_deref()
            .and_then(sanitize_visible_transcript)
            .map(|detail| truncate(&detail, 512));
        if let Some(existing) = self.entries.iter_mut().find(|entry| {
            matches!(entry, ProgressEntry::Activity { key, .. } if key == &activity.activity_id)
        }) {
            if let ProgressEntry::Activity {
                semantic_kind,
                status,
                title,
                detail: existing_detail,
                paths: existing_paths,
                exit_code,
                ..
            } = existing
            {
                *semantic_kind = activity.kind;
                *status = activity.status;
                *title = incoming_title.clone();
                if incoming_detail.is_some() {
                    *existing_detail = incoming_detail.clone();
                }
                for path in paths {
                    if existing_paths.len() < MAX_TRACKED_PATHS_PER_ACTIVITY
                        && !existing_paths.contains(&path)
                    {
                        existing_paths.push(path);
                    }
                }
                *exit_code = activity.exit_code.or(*exit_code);
            }
        } else if self.activity_count() < MAX_TRACKED_ACTIVITIES {
            self.entries.push(ProgressEntry::Activity {
                key: activity.activity_id.clone(),
                semantic_kind: activity.kind,
                status: activity.status,
                title: incoming_title,
                detail: incoming_detail,
                paths,
                exit_code: activity.exit_code,
            });
        } else {
            self.omitted = true;
        }

        let priority = if activity_failed(&activity) {
            UpdatePriority::Attention
        } else {
            UpdatePriority::Ordinary
        };
        ActivityProjection {
            status: self.render(mode, WORKING_STATUS, workspace),
            priority,
            validation,
        }
    }

    pub(super) fn apply_files(
        &mut self,
        files: impl IntoIterator<Item = PathBuf>,
        mode: VisibilityMode,
        workspace: &Path,
    ) -> Option<String> {
        self.set_visibility(mode);
        for path in files {
            if self.file_count() >= MAX_TRACKED_PROGRESS_FILES {
                self.omitted = true;
                break;
            }
            let Some(path) = normalized_progress_path(&path, workspace) else {
                continue;
            };
            if !self
                .entries
                .iter()
                .any(|entry| matches!(entry, ProgressEntry::File { path: existing } if existing == &path))
            {
                self.entries.push(ProgressEntry::File { path });
            }
        }
        self.render(mode, WORKING_STATUS, workspace)
    }

    pub(super) fn apply_legacy(
        &mut self,
        summary: &str,
        mode: VisibilityMode,
        workspace: &Path,
    ) -> Option<String> {
        self.set_visibility(mode);
        if summary
            .trim_end_matches(['.', '…'])
            .eq_ignore_ascii_case("thinking")
        {
            return self.render(mode, WORKING_STATUS, workspace);
        }
        let safe_summary = sanitize_visible_transcript(summary).unwrap_or_default();
        let summary = truncate(
            &safe_summary
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" "),
            160,
        );
        if !summary.is_empty()
            && !self.entries.iter().any(
                |entry| matches!(entry, ProgressEntry::Legacy { summary: existing, .. } if existing == &summary),
            )
        {
            if self.legacy_count() < MAX_TRACKED_LEGACY_ACTIVITIES {
                let key = self.legacy_sequence;
                self.legacy_sequence = self.legacy_sequence.saturating_add(1);
                self.entries.push(ProgressEntry::Legacy { key, summary });
            } else {
                self.omitted = true;
            }
        }
        self.render(mode, WORKING_STATUS, workspace)
    }

    pub(super) fn apply_plan(
        &mut self,
        steps: Vec<PlanStep>,
        mode: VisibilityMode,
        workspace: &Path,
    ) -> Option<String> {
        self.set_visibility(mode);
        self.plan_generation = self.plan_generation.saturating_add(1);
        let generation = self.plan_generation;
        let previous_keys = std::mem::take(&mut self.current_plan_keys);
        let mut current_keys = Vec::new();
        for (position, step) in steps.into_iter().take(MAX_TRACKED_PLAN_STEPS).enumerate() {
            let text = truncate(
                &step.text.split_whitespace().collect::<Vec<_>>().join(" "),
                160,
            );
            if text.is_empty() {
                continue;
            }
            let reusable_key = previous_keys.get(position).and_then(|key| {
                self.entries.iter().find_map(|entry| match entry {
                    ProgressEntry::Plan {
                        key: existing_key,
                        text: existing_text,
                        ..
                    } if existing_key == key && existing_text == &text => {
                        Some(existing_key.clone())
                    }
                    _ => None,
                })
            });
            let key = reusable_key.unwrap_or_else(|| format!("{generation}:{position}"));
            if let Some(ProgressEntry::Plan { status, .. }) = self.entries.iter_mut().find(
                |entry| matches!(entry, ProgressEntry::Plan { key: existing, .. } if existing == &key),
            ) {
                *status = step.status;
            } else if self.plan_count() < MAX_TRACKED_PLAN_STEPS {
                self.entries.push(ProgressEntry::Plan {
                    key: key.clone(),
                    text,
                    status: step.status,
                });
            } else {
                self.omitted = true;
                break;
            }
            current_keys.push(key);
        }
        self.entries.retain(|entry| match entry {
            ProgressEntry::Plan { key, status, .. } => {
                current_keys.contains(key) || !matches!(status, PlanStepStatus::Pending)
            }
            _ => true,
        });
        self.current_plan_keys = current_keys;
        self.render(mode, WORKING_STATUS, workspace)
    }

    pub(super) fn durable_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }

    pub(super) fn from_durable_json(value: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(value)
    }

    pub(super) fn set_visibility(&mut self, mode: VisibilityMode) {
        self.visibility_verbose = matches!(mode, VisibilityMode::Verbose);
    }

    pub(super) fn visibility_mode(&self) -> VisibilityMode {
        if self.visibility_verbose {
            VisibilityMode::Verbose
        } else {
            VisibilityMode::Normal
        }
    }

    pub(super) fn set_terminal_header(&mut self, header: impl Into<String>) {
        self.terminal_header = Some(header.into());
    }

    pub(super) fn terminal_header(&self) -> Option<&str> {
        self.terminal_header.as_deref()
    }

    pub(super) fn render(
        &self,
        mode: VisibilityMode,
        header: &str,
        _workspace: &Path,
    ) -> Option<String> {
        self.render_chunks(mode, header, Some(WORKING_CONTINUED_STATUS))
            .into_iter()
            .next()
    }

    pub(super) fn render_chunks(
        &self,
        mode: VisibilityMode,
        header: &str,
        _continuation_header: Option<&str>,
    ) -> Vec<String> {
        let terminal = self.terminal_header.is_some();
        let final_key = terminal
            .then(|| self.final_message().map(|(key, _)| key))
            .flatten();
        let blocks = self
            .entries
            .iter()
            .filter(|entry| !matches!(entry, ProgressEntry::Message { key, phase, .. } if *phase == Some(AgentMessagePhase::FinalAnswer) || final_key == Some(key.as_str())))
            .map(|entry| render_progress_entry(entry, mode, terminal))
            .filter(|block| !block.is_empty())
            .collect::<Vec<_>>();
        let open = if terminal { "" } else { " open" };
        let kind = if terminal { "" } else { " kind=\"progress\"" };
        let prefix = format!(
            "<details{open}>\n<summary{kind}>{}</summary>",
            progress_literal(header.trim_end_matches(['.', '…']))
        );
        let footer = self.workspace_line.as_deref().unwrap_or("");
        let suffix = if footer.is_empty() {
            "\n</details>".to_string()
        } else {
            format!("\n\n<footer>{footer}</footer>\n</details>")
        };
        let mut text = prefix;
        let limit = MAX_PROGRESS_CHUNK_BYTES
            .saturating_sub(suffix.len() + PROGRESS_OMITTED_MARKER.len() + 4);
        let mut omitted = self.omitted;
        for block in blocks {
            if text.len() + block.len() + 2 > limit {
                omitted = true;
                continue;
            }
            text.push_str("\n\n");
            text.push_str(&block);
        }
        if omitted {
            text.push_str("\n\n");
            text.push_str(PROGRESS_OMITTED_MARKER);
        }
        text.push_str(&suffix);
        vec![text]
    }

    fn activity_count(&self) -> usize {
        self.entries
            .iter()
            .filter(|entry| matches!(entry, ProgressEntry::Activity { .. }))
            .count()
    }

    fn file_count(&self) -> usize {
        self.entries
            .iter()
            .filter(|entry| matches!(entry, ProgressEntry::File { .. }))
            .count()
    }

    fn legacy_count(&self) -> usize {
        self.entries
            .iter()
            .filter(|entry| matches!(entry, ProgressEntry::Legacy { .. }))
            .count()
    }

    fn plan_count(&self) -> usize {
        self.entries
            .iter()
            .filter(|entry| matches!(entry, ProgressEntry::Plan { .. }))
            .count()
    }
}

fn normalized_progress_path(path: &Path, workspace: &Path) -> Option<String> {
    let path = safe_relative_path(path, workspace)?;
    let value = path.to_str()?;
    (!value.trim().is_empty() && value.len() <= 240 && !value.chars().any(char::is_control))
        .then(|| value.to_string())
}

fn render_progress_entry(entry: &ProgressEntry, mode: VisibilityMode, terminal: bool) -> String {
    match entry {
        ProgressEntry::Message { text, .. } => progress_commentary(text),
        ProgressEntry::Activity {
            semantic_kind,
            status,
            title,
            detail,
            paths,
            exit_code,
            ..
        } => {
            let state = match status {
                ActivityStatus::Failed => " · failed".to_string(),
                ActivityStatus::Completed if exit_code.is_some_and(|code| code != 0) => {
                    format!(" · exit {}", exit_code.unwrap())
                }
                ActivityStatus::Completed => String::new(),
                ActivityStatus::Declined => " · declined".to_string(),
                ActivityStatus::Cancelled => " · cancelled".to_string(),
                ActivityStatus::Pending | ActivityStatus::InProgress if terminal => {
                    " · completion unconfirmed".to_string()
                }
                ActivityStatus::Pending | ActivityStatus::InProgress => " · running".to_string(),
            };
            let mut summary = progress_literal(title.trim_end_matches('…'));
            if !state.is_empty() && state != " · running" {
                summary.push_str(&state);
            }
            let mut details = Vec::new();
            if matches!(mode, VisibilityMode::Verbose)
                && let Some(detail) = detail.as_deref().filter(|detail| !detail.trim().is_empty())
            {
                let rendered_detail = if *semantic_kind == ActivitySemanticKind::Execute {
                    sanitize_visible_command(detail).map(|detail| markdown_code_span(&detail))
                } else {
                    Some(progress_literal(detail))
                };
                if let Some(rendered_detail) = rendered_detail {
                    details.push(rendered_detail);
                }
            }
            if matches!(mode, VisibilityMode::Verbose) {
                details.extend(paths.iter().map(|path| markdown_code_span(path)));
            }
            if details.is_empty() {
                let status = if state.is_empty() {
                    "Completed"
                } else if state.contains("unconfirmed") {
                    "No terminal event was received for this tool."
                } else {
                    state.trim_start_matches(" ·")
                };
                format!(
                    "<details>\n<summary>{summary}</summary>\n\n{}\n</details>",
                    progress_literal(status)
                )
            } else {
                format!(
                    "<details>\n<summary>{summary}</summary>\n\n{}{}\n</details>",
                    details.join("\n\n"),
                    if state != " · running" {
                        String::new()
                    } else {
                        format!("\n\nStatus:{}", state.trim_start_matches(" ·"))
                    }
                )
            }
        }
        ProgressEntry::Plan { text, status, .. } => {
            let marker = match status {
                PlanStepStatus::Completed => "✓",
                PlanStepStatus::InProgress if terminal => "?",
                PlanStepStatus::InProgress => "→",
                PlanStepStatus::Pending => "·",
            };
            format!("- {marker} {}", progress_literal(text))
        }
        ProgressEntry::Legacy { summary, .. } => progress_literal(summary),
        ProgressEntry::File { path } => {
            format!("- Updated {}", markdown_code_span(path))
        }
    }
}

fn append_message_text(text: &mut String, delta: &str) {
    if text.ends_with(MESSAGE_OMITTED_MARKER) {
        return;
    }
    let available =
        MAX_MESSAGE_TEXT_BYTES.saturating_sub(MESSAGE_OMITTED_MARKER.len() + text.len());
    if delta.len() <= available {
        text.push_str(delta);
        return;
    }
    let mut end = available.min(delta.len());
    while !delta.is_char_boundary(end) {
        end -= 1;
    }
    text.push_str(&delta[..end]);
    text.push_str(MESSAGE_OMITTED_MARKER);
}

// Literal labels cannot introduce formatting or structural wrapper syntax.
fn progress_literal(value: &str) -> String {
    let mut result = String::new();
    for c in value.chars().filter(|c| !c.is_control()) {
        match c {
            '&' => result.push_str("&amp;"),
            '<' => result.push_str("&lt;"),
            '>' => result.push_str("&gt;"),
            c if c.is_ascii_punctuation() => {
                result.push('\\');
                result.push(c);
            }
            c => result.push(c),
        }
    }
    result
}

// Provider prose keeps its Markdown. Escape structural HTML outside code and
// close an unfinished fence so the next tool and outer close remain siblings.
fn progress_commentary(text: &str) -> String {
    let text = if text.len() > 4096 {
        let mut end = 4096;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        format!("{}\n\n[additional commentary omitted]", &text[..end])
    } else {
        text.to_string()
    };
    let text = sanitize_visible_transcript(&text).unwrap_or_default();
    let mut fence: Option<(char, usize)> = None;
    let mut lines = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim_start_matches(' ');
        let indent = line.len() - trimmed.len();
        let marker = trimmed.chars().next().filter(|c| matches!(c, '`' | '~'));
        let run = marker.map_or(0, |c| trimmed.chars().take_while(|next| *next == c).count());
        if let Some((character, length)) = fence {
            if indent <= 3
                && marker == Some(character)
                && run >= length
                && trimmed[run..].trim().is_empty()
            {
                fence = None;
            }
            lines.push(line.to_string());
        } else {
            if indent <= 3 && run >= 3 && !(marker == Some('`') && trimmed[run..].contains('`')) {
                fence = marker.map(|c| (c, run));
                lines.push(line.to_string());
            } else {
                lines.push(line.replace('<', "&lt;").replace('>', "&gt;"));
            }
        }
    }
    if let Some((character, length)) = fence {
        lines.push(character.to_string().repeat(length));
    }
    lines.join("\n")
}

fn activity_failed(activity: &ActivityUpsert) -> bool {
    activity.status == ActivityStatus::Failed
        || (activity.status == ActivityStatus::Completed
            && activity.exit_code.is_some_and(|exit_code| exit_code != 0))
}

fn activity_validation(activity: &ActivityUpsert) -> Option<ValidationSummary> {
    if !activity_looks_like_check(activity) {
        return None;
    }
    let detail = validation_activity_label(activity);
    match activity.status {
        ActivityStatus::Completed if activity.exit_code.unwrap_or(0) == 0 => {
            Some(ValidationSummary::Passed(detail))
        }
        ActivityStatus::Completed | ActivityStatus::Failed => {
            Some(ValidationSummary::Failed(detail))
        }
        ActivityStatus::Declined | ActivityStatus::Cancelled => {
            Some(ValidationSummary::NotRun(detail))
        }
        ActivityStatus::Pending | ActivityStatus::InProgress => None,
    }
}

fn validation_activity_label(activity: &ActivityUpsert) -> String {
    let mut normalized = activity.title.to_ascii_lowercase();
    if let Some(detail) = activity.detail.as_deref() {
        normalized.push(' ');
        normalized.push_str(&detail.to_ascii_lowercase());
    }
    [
        ("cargo test", "cargo test"),
        ("cargo check", "cargo check"),
        ("clippy", "Clippy"),
        ("lint", "lint"),
        ("cargo build", "cargo build"),
        ("format", "formatting"),
        ("fmt", "formatting"),
        ("test", "tests"),
        ("check", "validation"),
        ("build", "build"),
    ]
    .into_iter()
    .find_map(|(needle, label)| normalized.contains(needle).then(|| label.to_string()))
    .unwrap_or_else(|| "validation".to_string())
}

fn activity_looks_like_check(activity: &ActivityUpsert) -> bool {
    activity_text_looks_like_check(&activity.title, activity.detail.as_deref())
}

fn activity_text_looks_like_check(title: &str, detail: Option<&str>) -> bool {
    let mut normalized = title.to_ascii_lowercase();
    if let Some(detail) = detail {
        normalized.push(' ');
        normalized.push_str(&detail.to_ascii_lowercase());
    }
    ["test", "check", "build", "lint", "clippy", "fmt"]
        .iter()
        .any(|needle| normalized.contains(needle))
}

pub(super) fn validation_summary_from_provider(summary: &str) -> Option<ValidationSummary> {
    let normalized = summary.to_ascii_lowercase();
    let describes_checks = ["test", "check", "lint", "build"]
        .iter()
        .any(|marker| normalized.contains(marker));
    if !describes_checks {
        return None;
    }
    let detail = truncate(
        &summary.split_whitespace().collect::<Vec<_>>().join(" "),
        160,
    );
    if ["failed", "failure", "error"]
        .iter()
        .any(|marker| normalized.contains(marker))
    {
        Some(ValidationSummary::Failed(detail))
    } else if ["completed", "passed", "succeeded", "success"]
        .iter()
        .any(|marker| normalized.contains(marker))
    {
        Some(ValidationSummary::Passed(detail))
    } else {
        None
    }
}

pub(super) fn final_turn_text(
    content: &str,
    outcome: TurnOutcome,
    files: &[FileChange],
    workspace: &Path,
    expose_local_file_links: bool,
    validation: Option<&ValidationSummary>,
) -> String {
    if outcome == TurnOutcome::Interrupted {
        return "Stopped.".to_string();
    }
    let content_has_changed_files = has_completion_section(content, &["changed files", "changed"]);
    let content_has_checks = has_completion_section(
        content,
        &["checks", "checks passed", "checks failed", "checks not run"],
    );
    let mut text = if !content.trim().is_empty() {
        content.trim().to_string()
    } else {
        match outcome {
            TurnOutcome::Completed => "Done.".to_string(),
            TurnOutcome::Interrupted => unreachable!("interrupted turns return above"),
            TurnOutcome::Failed => BridgeNotice::AgentTurnFailed.message().to_string(),
            TurnOutcome::ConnectionLost => BridgeNotice::AgentConnectionLost.message().to_string(),
            TurnOutcome::AuthenticationRequired => {
                BridgeNotice::AuthenticationRequired.message().to_string()
            }
        }
    };
    if !content.trim().is_empty() {
        match outcome {
            TurnOutcome::Completed => {}
            TurnOutcome::Interrupted => unreachable!("interrupted turns return above"),
            TurnOutcome::Failed => {
                text.push_str("\n\n");
                text.push_str(BridgeNotice::AgentTurnFailed.message());
            }
            TurnOutcome::ConnectionLost => {
                text.push_str("\n\n");
                text.push_str(BridgeNotice::AgentConnectionLost.message());
            }
            TurnOutcome::AuthenticationRequired => {
                text.push_str("\n\n");
                text.push_str(BridgeNotice::AuthenticationRequired.message());
            }
        }
    }
    let append_changed_files = !files.is_empty() && !content_has_changed_files;
    if append_changed_files {
        let relative_files = files
            .iter()
            .filter_map(|file| {
                safe_relative_path(&file.path, workspace)
                    .map(|path| (path, file.summary.as_deref()))
            })
            .take(8)
            .collect::<Vec<_>>();
        if !relative_files.is_empty() {
            text.push_str("\n\nChanged files:");
        }
        for (path, summary) in relative_files {
            text.push_str("\n- ");
            let absolute_path = workspace.join(&path);
            let display_path = truncate(&path.display().to_string(), 240);
            if expose_local_file_links
                && let Ok(file_url) = url::Url::from_file_path(&absolute_path)
            {
                text.push('[');
                text.push_str(&markdown_code_span(&display_path));
                text.push_str("](");
                text.push_str(file_url.as_str());
                text.push(')');
            } else {
                text.push_str(&markdown_code_span(&display_path));
            }
            if let Some(summary) = summary {
                let summary = summary.split_whitespace().collect::<Vec<_>>().join(" ");
                if !summary.is_empty() {
                    text.push_str(" — ");
                    text.push_str(&truncate(&summary, 120));
                }
            }
        }
        let safe_count = files
            .iter()
            .filter(|file| safe_relative_path(&file.path, workspace).is_some())
            .count();
        if safe_count > 8 {
            text.push_str(&format!("\n- and {} more", safe_count - 8));
        }
    }
    let append_checks = (!files.is_empty() || validation.is_some()) && !content_has_checks;
    if append_checks {
        text.push_str("\n\n");
        match validation {
            Some(ValidationSummary::Passed(detail)) => {
                text.push_str("Checks passed: ");
                text.push_str(&truncate(detail, 160));
            }
            Some(ValidationSummary::Failed(detail)) => {
                text.push_str("Checks failed: ");
                text.push_str(&truncate(detail, 160));
            }
            Some(ValidationSummary::NotRun(detail)) => {
                text.push_str("Checks not run: ");
                text.push_str(&truncate(detail, 160));
            }
            None => text.push_str("Checks: not reported separately."),
        }
    }
    text
}

fn has_completion_section(content: &str, labels: &[&str]) -> bool {
    content.lines().any(|line| {
        let line = line
            .trim()
            .trim_start_matches('#')
            .trim()
            .trim_matches(['*', '_'])
            .trim();
        let normalized = line.to_ascii_lowercase();
        labels.iter().any(|label| {
            normalized == *label
                || normalized.strip_prefix(label).is_some_and(|suffix| {
                    let suffix = suffix.trim();
                    suffix.starts_with(':')
                        || (suffix.starts_with('(')
                            && suffix
                                .rfind(')')
                                .is_some_and(|end| suffix[end + 1..].trim().starts_with(':')))
                })
        })
    })
}

pub(super) fn markdown_code_span(value: &str) -> String {
    let value = value.replace(['\r', '\n'], " ");
    let longest_backtick_run = value
        .split(|character| character != '`')
        .map(str::len)
        .max()
        .unwrap_or(0);
    let fence = "`".repeat(longest_backtick_run.saturating_add(1).max(1));
    if longest_backtick_run == 0 {
        format!("{fence}{value}{fence}")
    } else {
        format!("{fence} {value} {fence}")
    }
}

#[cfg(test)]
#[path = "runtime/tests.rs"]
mod presentation_tests;

#[cfg(test)]
mod disclosure_tests {
    use super::*;

    fn snapshot(tracker: &ActivityTracker) -> String {
        tracker
            .render_chunks(
                VisibilityMode::Verbose,
                tracker.terminal_header().unwrap_or(WORKING_STATUS),
                None,
            )
            .remove(0)
    }

    #[test]
    fn commentary_tools_and_final_have_independent_item_identity() {
        let mut tracker = ActivityTracker::default();
        tracker.set_workspace(Path::new("/workspace/project"));
        tracker.apply_message(
            "a",
            Some(AgentMessagePhase::Commentary),
            AgentMessageUpdate::Started,
        );
        tracker.apply_message("a", None, AgentMessageUpdate::Delta("First draft".into()));
        tracker.apply(
            ActivityUpsert::new(
                "tool",
                ActivitySemanticKind::Read,
                ActivityStatus::InProgress,
                "Read files",
            )
            .unwrap()
            .with_detail("cat src/lib.rs"),
            VisibilityMode::Verbose,
            Path::new("/workspace/project"),
        );
        tracker.apply_message(
            "b",
            Some(AgentMessagePhase::Commentary),
            AgentMessageUpdate::Delta("Second commentary".into()),
        );
        tracker.apply_message(
            "final",
            Some(AgentMessagePhase::FinalAnswer),
            AgentMessageUpdate::Delta("The answer".into()),
        );
        // A late completion must replace a, without moving it or replacing b/final.
        tracker.apply_message(
            "a",
            None,
            AgentMessageUpdate::Completed("First authoritative 👩‍💻 e\u{301} مرحبا".into()),
        );
        tracker.apply_message("a", None, AgentMessageUpdate::Delta(" stale".into()));
        let live = snapshot(&tracker);
        assert!(live.find("First authoritative").unwrap() < live.find("Read files").unwrap());
        assert!(live.find("Read files").unwrap() < live.find("Second commentary").unwrap());
        assert!(!live.contains("First draft"));
        assert!(!live.contains("stale"));
        assert!(!live.contains("The answer"));
        assert_eq!(tracker.final_message_text(), Some("The answer"));
        assert!(live.contains("<footer>Working directory:"));
        assert!(live.starts_with("<details open>"));
        tracker.set_terminal_header("Worked for 3s");
        let terminal = snapshot(&tracker);
        assert!(terminal.starts_with("<details>\n<summary>Worked for 3s</summary>"));
        assert!(!terminal.contains("kind=\"progress\""));
        assert!(terminal.contains("completion unconfirmed"));
        if let Ok(path) = std::env::var("INLINE_PROGRESS_FIXTURE_PATH") {
            let adversarial = "Safe\n</details>\nAuthorization: Bearer fixture-credential\nRead /Users/alice/private\n````rust\n    let x = 1;\n    TOKEN=fixture-code-credential\n```\n</details>";
            let mut adversarial_tracker = ActivityTracker::default();
            adversarial_tracker.set_workspace(Path::new("/workspace/project"));
            adversarial_tracker.apply_message(
                "a",
                Some(AgentMessagePhase::Commentary),
                AgentMessageUpdate::Completed(adversarial.into()),
            );
            adversarial_tracker.apply(
                ActivityUpsert::new(
                    "tool",
                    ActivitySemanticKind::Read,
                    ActivityStatus::Completed,
                    "Read files",
                )
                .unwrap(),
                VisibilityMode::Normal,
                Path::new("/workspace/project"),
            );
            std::fs::write(
                path,
                serde_json::to_string(&vec![
                    live.clone(),
                    terminal.clone(),
                    snapshot(&adversarial_tracker),
                ])
                .unwrap(),
            )
            .unwrap();
        }
        assert_eq!(
            ActivityTracker::from_durable_json(&tracker.durable_json().unwrap())
                .unwrap()
                .final_message_text(),
            Some("The answer")
        );
    }

    #[test]
    fn unknown_phase_is_terminal_only_and_commentary_never_becomes_answer() {
        let mut tracker = ActivityTracker::default();
        tracker.apply_message(
            "a",
            None,
            AgentMessageUpdate::Completed("Legacy interim".into()),
        );
        tracker.apply_message(
            "b",
            Some(AgentMessagePhase::Unknown),
            AgentMessageUpdate::Completed("Legacy answer".into()),
        );
        tracker.apply_message(
            "c",
            Some(AgentMessagePhase::Commentary),
            AgentMessageUpdate::Completed("Later commentary".into()),
        );
        assert!(snapshot(&tracker).contains("Legacy answer"));
        assert_eq!(tracker.final_message_text(), Some("Legacy answer"));
        tracker.set_terminal_header("Worked for 2s");
        let terminal = snapshot(&tracker);
        assert!(terminal.contains("Legacy interim"));
        assert!(terminal.contains("Later commentary"));
        assert!(!terminal.contains("Legacy answer"));
        tracker.apply_message("b", None, AgentMessageUpdate::Completed(String::new()));
        assert_eq!(tracker.final_message_text(), Some("Legacy interim"));
    }

    #[test]
    fn commentary_is_confined_to_its_disclosure_even_during_open_code_fences() {
        let prose = "Safe\n</details>\n<footer>pretend footer</footer>\n````rust\nlet x = 1;\n```\n</details>";
        let text = progress_commentary(prose);
        assert!(text.contains("&lt;/details&gt;"));
        assert!(text.ends_with("\n````"));
        assert!(text.contains("\n```\n</details>\n````"));
        assert_eq!(progress_commentary("~~~txt\nhello"), "~~~txt\nhello\n~~~");
        assert_eq!(
            progress_commentary("```txt\nhello\n```"),
            "```txt\nhello\n```"
        );
        let literal = progress_literal("</summary>\n<details>");
        assert!(!literal.contains('<') && !literal.contains('\n'));
        assert!(literal.contains("&lt;"));
    }

    #[test]
    fn commentary_redacts_credentials_and_paths_without_flattening_markdown() {
        let prose = "## Checking\n\n- Read source  \n  - Keep nested indentation\n\nAuthorization: Bearer bearer-value-123\nTOKEN=assigned-value-123\ncurl --api-key flag-value-123 https://example.com/file?signature=signed-value-123\nRead </Users/alice/private>\n\n```rust\n    let x = 1;  \n    TOKEN=code-value-123\n</details>\n```";
        let mut tracker = ActivityTracker::default();
        tracker.apply_message(
            "comment",
            Some(AgentMessagePhase::Commentary),
            AgentMessageUpdate::Completed(prose.into()),
        );
        let progress = snapshot(&tracker);
        for private in [
            "bearer-value-123",
            "assigned-value-123",
            "flag-value-123",
            "signed-value-123",
            "code-value-123",
            "/Users/alice",
        ] {
            assert!(!progress.contains(private), "must redact {private}");
        }
        assert!(progress.contains("## Checking\n\n- Read source  \n  - Keep nested indentation"));
        assert!(progress.contains("```rust\n    let x = 1;  \n    TOKEN= [redacted]\n</details>\n```"));
        assert!(progress.contains("[local-path]"));
        assert!(progress.contains("https://example.com/file?[redacted]"));
    }

    #[test]
    fn message_overflow_keeps_final_answer_and_one_complete_progress_message() {
        let mut tracker = ActivityTracker::default();
        for i in 0..MAX_TRACKED_MESSAGES + 8 {
            tracker.apply_message(
                &format!("comment-{i}"),
                Some(AgentMessagePhase::Commentary),
                AgentMessageUpdate::Completed("α".repeat(20_000)),
            );
        }
        tracker.apply_message(
            "answer",
            Some(AgentMessagePhase::FinalAnswer),
            AgentMessageUpdate::Completed("Final survives".into()),
        );
        let chunks = tracker.render_chunks(VisibilityMode::Normal, WORKING_STATUS, None);
        assert_eq!(chunks.len(), 1);
        assert!(chunks[0].len() <= MAX_PROGRESS_CHUNK_BYTES);
        assert!(chunks[0].ends_with("</details>"));
        assert_eq!(
            chunks[0].matches("[additional activity omitted]").count(),
            1
        );
        assert_eq!(tracker.final_message_text(), Some("Final survives"));
        assert!(tracker.durable_json().unwrap().len() < 600_000);
    }

    #[test]
    fn completion_does_not_fabricate_tool_success_and_normal_hides_details() {
        let mut tracker = ActivityTracker::default();
        for (id, status) in [
            ("done", ActivityStatus::Completed),
            ("pending", ActivityStatus::InProgress),
            ("failed", ActivityStatus::Failed),
        ] {
            tracker.apply(
                ActivityUpsert::new(id, ActivitySemanticKind::Execute, status, id)
                    .unwrap()
                    .with_detail("private verbose detail")
                    .with_exit_code((id == "done").then_some(0)),
                VisibilityMode::Normal,
                Path::new("/workspace"),
            );
        }
        tracker.set_terminal_header("Failed after 4s");
        let normal = tracker
            .render_chunks(VisibilityMode::Normal, "Failed after 4s", None)
            .remove(0);
        assert!(!normal.contains("private verbose detail"));
        assert!(!normal.contains("exit 0"));
        assert_eq!(normal.matches("completion unconfirmed").count(), 1);
        assert!(normal.contains("Completed"));
        assert!(normal.contains("failed"));
    }
}
