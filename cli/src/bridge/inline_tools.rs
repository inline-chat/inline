//! Bot-authenticated Inline tools exposed to verified provider transports.

use super::*;

const MAX_HOST_TOOL_ARGUMENT_BYTES: usize = 32 * 1024;
const MAX_HOST_TOOL_CALL_ID_BYTES: usize = 256;
const MAX_HOST_TOOL_RESULT_BYTES: usize = 16 * 1024;
const HOST_TOOL_EXECUTION_TIMEOUT: Duration = Duration::from_secs(15);
const RETURN_ATTACHMENT_TIMEOUT: Duration = Duration::from_secs(60);
const MAX_RETURN_ATTACHMENT_BYTES: u64 = 20 * 1024 * 1024;
const MAX_VIDEO_THUMBNAIL_BYTES: usize = 2 * 1024 * 1024;

#[derive(Clone)]
pub(super) struct InlineToolHost {
    bot: InlineClient,
    route: InboundRoute,
    realtime_url: String,
    bot_token: String,
}

impl InlineToolHost {
    pub fn new(
        bot: InlineClient,
        route: InboundRoute,
        realtime_url: String,
        bot_token: String,
    ) -> Self {
        Self {
            bot,
            route,
            realtime_url,
            bot_token,
        }
    }

    async fn execute(&self, call: HostToolCall) -> HostToolResult {
        let started_at = Instant::now();
        if !valid_tool_call_id(&call.call_id) {
            return HostToolResult::failure("Inline tool call identity is invalid.");
        }
        let Some(spec) = inline_tool_specs()
            .into_iter()
            .find(|spec| spec.name == call.tool_name)
        else {
            return HostToolResult::failure("Unknown Inline tool.");
        };
        let arguments = match serde_json::to_vec(&call.arguments) {
            Ok(arguments) if arguments.len() <= MAX_HOST_TOOL_ARGUMENT_BYTES => arguments,
            _ => return HostToolResult::failure("Inline tool arguments are invalid or too large."),
        };
        if validate_tool_arguments(&call.arguments, &spec.input_schema).is_err() {
            return HostToolResult::failure("Inline tool arguments do not match the tool schema.");
        }
        log::trace!(
            target: "inline::bridge::tool",
            "phase=tool_received provider_id={:?} session_id={:?} turn_id={:?} call_id={:?} tool={:?}",
            self.route.provider_id.as_str(),
            call.session_id.as_str(),
            call.turn_id.as_str(),
            call.call_id,
            call.tool_name
        );
        let Some(record) = self.authorize(&call).await else {
            log::warn!(
                target: "inline::bridge::tool",
                "phase=tool_rejected reason=unauthorized provider_id={:?} session_id={:?} turn_id={:?} call_id={:?} tool={:?}",
                self.route.provider_id.as_str(),
                call.session_id.as_str(),
                call.turn_id.as_str(),
                call.call_id,
                call.tool_name
            );
            return HostToolResult::failure(
                "This Inline tool call is no longer authorized for the active turn.",
            );
        };
        let arguments_digest = hex_digest(&arguments);
        let claim_record = HostToolCallRecord {
            provider_id: self.route.provider_id.clone(),
            session_id: call.session_id.clone(),
            turn_id: call.turn_id.clone(),
            call_id: call.call_id.clone(),
            tool_name: call.tool_name.clone(),
            arguments_digest,
            result_json: None,
            succeeded: None,
        };
        match self
            .route
            .store
            .claim_host_tool_call(&claim_record, now_seconds())
        {
            Ok(HostToolCallClaim::Claimed) => {}
            Ok(HostToolCallClaim::Cached(cached)) => {
                log::trace!(
                    target: "inline::bridge::tool",
                    "phase=tool_replayed call_id={:?} tool={:?} elapsed_ms={}",
                    call.call_id,
                    call.tool_name,
                    started_at.elapsed().as_millis()
                );
                return cached
                    .result_json
                    .as_deref()
                    .and_then(|value| serde_json::from_str(value).ok())
                    .unwrap_or_else(|| {
                        HostToolResult::failure("Cached Inline tool result is invalid.")
                    });
            }
            Ok(HostToolCallClaim::InFlight) => {
                log::warn!(
                    target: "inline::bridge::tool",
                    "phase=tool_rejected reason=in_flight call_id={:?} tool={:?}",
                    call.call_id,
                    call.tool_name
                );
                return HostToolResult::failure("This Inline tool call is already in progress.");
            }
            Ok(HostToolCallClaim::Conflict) => {
                log::warn!(
                    target: "inline::bridge::tool",
                    "phase=tool_rejected reason=identity_conflict call_id={:?} tool={:?}",
                    call.call_id,
                    call.tool_name
                );
                return HostToolResult::failure(
                    "Inline rejected a conflicting tool call identity.",
                );
            }
            Err(_) => return HostToolResult::failure("Inline could not claim this tool call."),
        }
        let execution_timeout = if call.tool_name == "return_attachment" {
            RETURN_ATTACHMENT_TIMEOUT
        } else {
            HOST_TOOL_EXECUTION_TIMEOUT
        };
        let result =
            match tokio::time::timeout(execution_timeout, self.execute_claimed(&call, &record))
                .await
            {
                Ok(result) => bounded_tool_result(result),
                Err(_) => HostToolResult::failure("Inline tool call timed out."),
            };
        if let Ok(encoded) = serde_json::to_string(&result) {
            let _ = self.route.store.finish_host_tool_call(
                &claim_record,
                &encoded,
                result.success,
                now_seconds(),
            );
        }
        log::trace!(
            target: "inline::bridge::tool",
            "phase=tool_finished call_id={:?} tool={:?} success={} elapsed_ms={}",
            call.call_id,
            call.tool_name,
            result.success,
            started_at.elapsed().as_millis()
        );
        result
    }

    async fn authorize(&self, call: &HostToolCall) -> Option<InboundRecord> {
        let mut record = None;
        for _ in 0..5 {
            record = self
                .route
                .store
                .inbound_for_provider_turn(&call.turn_id)
                .ok()
                .flatten();
            if record.is_some() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let record = record?;
        if record.binding.installation_id != self.route.installation_id
            || !self.route.allows(record.sender_user_id)
        {
            return None;
        }
        let turn_binding = BindingKey {
            installation_id: record.binding.installation_id.clone(),
            chat_id: record.delivery_chat_id,
            workspace_id: record.binding.workspace_id.clone(),
        };
        let (provider_id, session_id) =
            self.route.store.get_binding(&turn_binding).ok().flatten()?;
        (provider_id == self.route.provider_id && session_id == call.session_id).then_some(record)
    }

    async fn execute_claimed(&self, call: &HostToolCall, record: &InboundRecord) -> HostToolResult {
        let current_chat_id = record.delivery_chat_id;
        match call.tool_name.as_str() {
            "get_current_context" => self.current_context(record).await,
            "get_chat" => {
                let Some(chat_id) = self
                    .authorized_chat_id(&call.arguments, current_chat_id)
                    .await
                else {
                    return HostToolResult::failure("Inline chat is unavailable to this bot.");
                };
                json_result(self.route.bot_store.dialog(InlineId::new(chat_id)).await)
            }
            "get_messages" | "get_history" => {
                let Some(chat_id) = self
                    .authorized_chat_id(&call.arguments, current_chat_id)
                    .await
                else {
                    return HostToolResult::failure("Inline chat is unavailable to this bot.");
                };
                let limit = bounded_limit(&call.arguments, 20, 100);
                json_result(
                    self.bot
                        .history(HistoryRequest {
                            chat_id: InlineId::new(chat_id),
                            limit: Some(limit),
                            before_message_id: positive_i64(&call.arguments, "before_message_id")
                                .map(InlineId::new),
                            after_message_id: positive_i64(&call.arguments, "after_message_id")
                                .map(InlineId::new),
                        })
                        .await,
                )
            }
            "search_messages" => self.search_messages(&call.arguments, current_chat_id).await,
            "search_chats" => self.search_chats(&call.arguments).await,
            "get_reactions" => self.get_reactions(&call.arguments, current_chat_id).await,
            "list_pins" => {
                let Some(chat_id) = self
                    .authorized_chat_id(&call.arguments, current_chat_id)
                    .await
                else {
                    return HostToolResult::failure("Inline chat is unavailable to this bot.");
                };
                match self.route.bot_store.dialog(InlineId::new(chat_id)).await {
                    Ok(Some(dialog)) => HostToolResult::success(
                        serde_json::json!({"chat_id": chat_id, "message_ids": dialog.pinned_message_ids})
                            .to_string(),
                    ),
                    _ => HostToolResult::failure("Inline chat is unavailable to this bot."),
                }
            }
            "create_chat" => self.create_chat(&call.arguments).await,
            "add_reaction" => {
                self.react(&call.arguments, current_chat_id, false, call)
                    .await
            }
            "remove_reaction" => {
                self.react(&call.arguments, current_chat_id, true, call)
                    .await
            }
            "pin_message" => self.pin(&call.arguments, current_chat_id, false).await,
            "unpin_message" => self.pin(&call.arguments, current_chat_id, true).await,
            "edit_own_message" => {
                self.edit_own_message(&call.arguments, current_chat_id, call)
                    .await
            }
            "return_attachment" => self.return_attachment(&call.arguments, record).await,
            "update_bot_profile" => self.update_bot_profile(&call.arguments).await,
            "set_presence" => self.set_presence(&call.arguments, current_chat_id).await,
            _ => HostToolResult::failure("Unknown Inline tool."),
        }
    }

    async fn current_context(&self, record: &InboundRecord) -> HostToolResult {
        let dialog = self
            .route
            .bot_store
            .dialog(InlineId::new(record.delivery_chat_id))
            .await
            .ok()
            .flatten();
        let title = dialog.as_ref().and_then(|dialog| dialog.title.clone());
        let parent_chat_id = dialog.as_ref().and_then(|dialog| dialog.parent_chat_id);
        let parent_message_id = dialog.as_ref().and_then(|dialog| dialog.parent_message_id);
        HostToolResult::success(
            serde_json::json!({
                "chat_id": record.delivery_chat_id,
                "source_chat_id": record.binding.chat_id,
                "source_message_id": record.message_id,
                "operator_user_id": record.sender_user_id,
                "bot_user_id": self.route.bot_user_id,
                "provider_id": self.route.provider_id.as_str(),
                "title": title,
                "parent_chat_id": parent_chat_id,
                "parent_message_id": parent_message_id,
            })
            .to_string(),
        )
    }

    async fn authorized_chat_id(
        &self,
        arguments: &serde_json::Value,
        fallback: i64,
    ) -> Option<i64> {
        let chat_id = positive_i64(arguments, "chat_id").unwrap_or(fallback);
        self.route
            .bot_store
            .dialog(InlineId::new(chat_id))
            .await
            .ok()
            .flatten()
            .map(|_| chat_id)
    }

    async fn search_chats(&self, arguments: &serde_json::Value) -> HostToolResult {
        let query = string_arg(arguments, "query", 200)
            .unwrap_or_default()
            .to_lowercase();
        if query.is_empty() {
            return HostToolResult::failure("query is required.");
        }
        match self
            .bot
            .cached_dialogs(DialogsRequest {
                limit: Some(100),
                cursor: None,
                order: DialogsOrder::RecentActivity,
            })
            .await
        {
            Ok(page) => {
                let dialogs = page
                    .dialogs
                    .into_iter()
                    .filter(|dialog| {
                        dialog
                            .title
                            .as_deref()
                            .is_some_and(|title| title.to_lowercase().contains(&query))
                    })
                    .take(20)
                    .collect::<Vec<_>>();
                json_value_result(&dialogs)
            }
            Err(_) => HostToolResult::failure("Inline chat search failed."),
        }
    }

    async fn search_messages(
        &self,
        arguments: &serde_json::Value,
        fallback: i64,
    ) -> HostToolResult {
        let Some(chat_id) = self.authorized_chat_id(arguments, fallback).await else {
            return HostToolResult::failure("Inline chat is unavailable to this bot.");
        };
        let Some(query) = string_arg(arguments, "query", 500) else {
            return HostToolResult::failure("query is required.");
        };
        let mut realtime = match connect_realtime(&self.realtime_url, &self.bot_token).await {
            Ok(client) => client,
            Err(_) => return HostToolResult::failure("Inline message search is unavailable."),
        };
        let response = realtime
            .call(proto::SearchMessagesInput {
                peer_id: Some(chat_peer(chat_id)),
                queries: vec![query],
                limit: Some(bounded_limit(arguments, 20, 100) as i32),
                offset_id: positive_i64(arguments, "offset_id"),
                filter: None,
            })
            .await;
        match response {
            Ok(result) => json_value_result(&project_proto_messages(result.messages)),
            Err(_) => HostToolResult::failure("Inline message search failed."),
        }
    }

    async fn get_reactions(&self, arguments: &serde_json::Value, fallback: i64) -> HostToolResult {
        let Some(chat_id) = self.authorized_chat_id(arguments, fallback).await else {
            return HostToolResult::failure("Inline chat is unavailable to this bot.");
        };
        let Some(message_id) = positive_i64(arguments, "message_id") else {
            return HostToolResult::failure("message_id is required.");
        };
        let mut realtime = match connect_realtime(&self.realtime_url, &self.bot_token).await {
            Ok(client) => client,
            Err(_) => return HostToolResult::failure("Inline reactions are unavailable."),
        };
        match realtime
            .call(proto::GetMessagesInput {
                peer_id: Some(chat_peer(chat_id)),
                message_ids: vec![message_id],
            })
            .await
        {
            Ok(result) => json_value_result(
                &result
                    .messages
                    .first()
                    .and_then(|message| message.reactions.clone()),
            ),
            Err(_) => HostToolResult::failure("Inline reactions lookup failed."),
        }
    }

    async fn create_chat(&self, arguments: &serde_json::Value) -> HostToolResult {
        if !bool_arg(arguments, "confirmed_intent") {
            return HostToolResult::failure("Creating a chat requires explicit user intent.");
        }
        let Some(title) = string_arg(arguments, "title", 200) else {
            return HostToolResult::failure("title is required.");
        };
        let is_public = bool_arg(arguments, "is_public");
        let space_id = positive_i64(arguments, "space_id").map(InlineId::new);
        if is_public && (space_id.is_none() || !bool_arg(arguments, "confirmed_public_intent")) {
            return HostToolResult::failure(
                "A public chat requires a space_id and explicit public-chat intent.",
            );
        }
        json_result(
            self.bot
                .create_thread(CreateThreadRequest {
                    title: Some(title),
                    space_id,
                    description: string_arg(arguments, "description", 500),
                    emoji: string_arg(arguments, "emoji", 32),
                    is_public,
                    participants: Vec::new(),
                })
                .await,
        )
    }

    async fn react(
        &self,
        arguments: &serde_json::Value,
        fallback: i64,
        remove: bool,
        call: &HostToolCall,
    ) -> HostToolResult {
        let Some(chat_id) = self.authorized_chat_id(arguments, fallback).await else {
            return HostToolResult::failure("Inline chat is unavailable to this bot.");
        };
        let Some(message_id) = positive_i64(arguments, "message_id") else {
            return HostToolResult::failure("message_id is required.");
        };
        let Some(reaction) = string_arg(arguments, "reaction", 32) else {
            return HostToolResult::failure("reaction is required.");
        };
        let external_id =
            ExternalId::try_new("agent-tool", format!("{}-reaction", call.call_id)).ok();
        match self
            .bot
            .react(ReactRequest {
                chat_id: InlineId::new(chat_id),
                message_id: InlineId::new(message_id),
                reaction,
                remove,
                external_id,
            })
            .await
        {
            Ok(()) => HostToolResult::success("Reaction updated."),
            Err(_) => HostToolResult::failure("Inline could not update the reaction."),
        }
    }

    async fn pin(
        &self,
        arguments: &serde_json::Value,
        fallback: i64,
        unpin: bool,
    ) -> HostToolResult {
        if !bool_arg(arguments, "confirmed_intent") {
            return HostToolResult::failure("Pin changes require explicit user intent.");
        }
        let Some(chat_id) = self.authorized_chat_id(arguments, fallback).await else {
            return HostToolResult::failure("Inline chat is unavailable to this bot.");
        };
        let Some(message_id) = positive_i64(arguments, "message_id") else {
            return HostToolResult::failure("message_id is required.");
        };
        let mut realtime = match connect_realtime(&self.realtime_url, &self.bot_token).await {
            Ok(client) => client,
            Err(_) => return HostToolResult::failure("Inline pinning is unavailable."),
        };
        match realtime
            .call(proto::PinMessageInput {
                peer_id: Some(chat_peer(chat_id)),
                message_id,
                unpin,
            })
            .await
        {
            Ok(_) => HostToolResult::success(if unpin {
                "Message unpinned."
            } else {
                "Message pinned."
            }),
            Err(_) => HostToolResult::failure("Inline could not update the pin."),
        }
    }

    async fn edit_own_message(
        &self,
        arguments: &serde_json::Value,
        fallback: i64,
        call: &HostToolCall,
    ) -> HostToolResult {
        if !bool_arg(arguments, "confirmed_intent") {
            return HostToolResult::failure("Editing a message requires explicit user intent.");
        }
        let Some(chat_id) = self.authorized_chat_id(arguments, fallback).await else {
            return HostToolResult::failure("Inline chat is unavailable to this bot.");
        };
        let Some(message_id) = positive_i64(arguments, "message_id") else {
            return HostToolResult::failure("message_id is required.");
        };
        let Some(text) = string_arg(arguments, "text", 8_000) else {
            return HostToolResult::failure("text is required.");
        };
        match self
            .bot
            .edit_message(EditMessageRequest {
                chat_id: InlineId::new(chat_id),
                message_id: InlineId::new(message_id),
                text,
                external_id: ExternalId::try_new("agent-tool", format!("{}-edit", call.call_id))
                    .ok(),
                parse_markdown: true,
            })
            .await
        {
            Ok(()) => HostToolResult::success("Message edited."),
            Err(_) => HostToolResult::failure(
                "Inline rejected the edit; only this bot's messages can be changed.",
            ),
        }
    }

    async fn return_attachment(
        &self,
        arguments: &serde_json::Value,
        record: &InboundRecord,
    ) -> HostToolResult {
        if !bool_arg(arguments, "confirmed_intent") {
            return HostToolResult::failure(
                "Returning a file requires an explicit request from the user.",
            );
        }
        let Some(path) = string_arg(arguments, "path", 4_096) else {
            return HostToolResult::failure("path is required.");
        };
        let requested_path = match local_file_argument(&path) {
            Ok(path) => path,
            Err(message) => return HostToolResult::failure(message),
        };
        let Some(workspace) = self
            .route
            .store
            .workspace(
                &record.binding.installation_id,
                &record.binding.workspace_id,
            )
            .ok()
            .flatten()
        else {
            return HostToolResult::failure("The active Inline workspace is unavailable.");
        };
        let roots = [
            workspace.path.as_path(),
            self.route.attachment_cache_dir.as_path(),
        ];
        let (path, size_bytes) = match validated_return_attachment_path(&requested_path, &roots) {
            Ok(value) => value,
            Err(message) => return HostToolResult::failure(message),
        };
        let bytes = match tokio::fs::read(&path).await {
            Ok(bytes) if bytes.len() as u64 == size_bytes => bytes,
            _ => {
                return HostToolResult::failure(
                    "The local file changed before Inline could upload it.",
                );
            }
        };
        let file_name = string_arg(arguments, "file_name", 240)
            .as_deref()
            .and_then(safe_file_name)
            .or_else(|| inbound_attachment_file_name(&record.direction.attachments, &path))
            .or_else(|| {
                unique_cached_attachment_file_name(
                    &record.direction.attachments,
                    &path,
                    &bytes,
                    &self.route.attachment_cache_dir,
                )
            })
            .or_else(|| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .and_then(safe_file_name)
            })
            .unwrap_or_else(|| "agent-file".to_string());
        let mime_type = mime_guess::from_path(&path)
            .first_raw()
            .unwrap_or("application/octet-stream")
            .to_string();
        let Some(media_kind) = string_arg(arguments, "kind", 16)
            .as_deref()
            .and_then(ReturnAttachmentKind::parse)
        else {
            return HostToolResult::failure(
                "kind must be image, video, or file based on the user's request.",
            );
        };
        if !media_kind.accepts_mime_type(&mime_type) {
            return HostToolResult::failure(match media_kind {
                ReturnAttachmentKind::Image => {
                    "Image kind requires a supported raster image; use file for SVG or other documents."
                }
                ReturnAttachmentKind::Video => "Video kind requires a video media type.",
                ReturnAttachmentKind::File => unreachable!("files accept any MIME type"),
            });
        }
        let (video_metadata, video_thumbnail) = if media_kind == ReturnAttachmentKind::Video {
            let metadata = inbound_video_metadata(
                &record.direction.attachments,
                &path,
                &bytes,
                &self.route.attachment_cache_dir,
            )
            .or(probe_video_metadata(&path).await);
            let Some(metadata) = metadata else {
                return HostToolResult::failure(
                    "Inline could not verify this video's width, height, and duration, so it was not uploaded as a video. Install ffprobe or return the original attached video.",
                );
            };
            let Some(thumbnail) = generate_video_thumbnail(&path).await else {
                return HostToolResult::failure(
                    "Inline could not generate a safe thumbnail for this video, so it was not uploaded. Install ffmpeg or return the video as a file.",
                );
            };
            (Some(metadata), Some(thumbnail))
        } else {
            (None, None)
        };
        // Providers may retry a tool after Inline already accepted the upload.
        // Bind idempotency to the authenticated direction and verified bytes,
        // not to the provider-generated call ID, so retries cannot duplicate
        // the same returned artifact in the conversation.
        let idempotency_key =
            return_attachment_idempotency_key(&record.event_id, media_kind.as_str(), &bytes);
        let request = UploadRequest {
            peer: PeerRef::Chat {
                chat_id: InlineId::new(record.delivery_chat_id),
            },
            kind: media_kind.protocol_kind(),
            file_name: Some(file_name.clone()),
            mime_type: Some(mime_type),
            size_bytes: Some(size_bytes),
            caption: string_arg(arguments, "caption", 2_000),
            width: video_metadata.map(|metadata| metadata.width),
            height: video_metadata.map(|metadata| metadata.height),
            duration_ms: video_metadata.map(|metadata| metadata.duration_ms),
            external_id: ExternalId::try_new("agent-tool", format!("return-{idempotency_key}"))
                .ok(),
            random_id: Some(interaction_random_id("return-attachment", &idempotency_key)),
            reply_to_message_id: None,
        };
        match self
            .bot
            .send_media_with_thumbnail(request, bytes, video_thumbnail)
            .await
        {
            Ok(_) => HostToolResult::success(format!(
                "Uploaded {file_name} to the current Inline conversation as {}. Do not return the local path to the user.",
                media_kind.result_label()
            )),
            Err(_) => HostToolResult::failure("Inline could not upload the local file."),
        }
    }

    async fn update_bot_profile(&self, arguments: &serde_json::Value) -> HostToolResult {
        if !bool_arg(arguments, "confirmed_intent") {
            return HostToolResult::failure("Profile changes require explicit user intent.");
        }
        let Some(name) = string_arg(arguments, "name", 120) else {
            return HostToolResult::failure("name is required.");
        };
        let mut realtime = match connect_realtime(&self.realtime_url, &self.bot_token).await {
            Ok(client) => client,
            Err(_) => return HostToolResult::failure("Inline profile updates are unavailable."),
        };
        match realtime
            .call(proto::UpdateBotProfileInput {
                bot_user_id: self.route.bot_user_id,
                name: Some(name),
                photo_file_unique_id: None,
            })
            .await
        {
            Ok(_) => HostToolResult::success("Bot profile updated."),
            Err(_) => HostToolResult::failure("Inline rejected the bot profile update."),
        }
    }

    async fn set_presence(&self, arguments: &serde_json::Value, fallback: i64) -> HostToolResult {
        let Some(chat_id) = self.authorized_chat_id(arguments, fallback).await else {
            return HostToolResult::failure("Inline chat is unavailable to this bot.");
        };
        let kind = match string_arg(arguments, "state", 20).as_deref() {
            Some("hidden") => proto::bot_presence_state::Kind::Hidden,
            Some("idle") => proto::bot_presence_state::Kind::Idle,
            Some("happy") => proto::bot_presence_state::Kind::Happy,
            Some("waving") => proto::bot_presence_state::Kind::Waving,
            Some("jumping") => proto::bot_presence_state::Kind::Jumping,
            Some("failed") => proto::bot_presence_state::Kind::Failed,
            Some("waiting") => proto::bot_presence_state::Kind::Waiting,
            Some("running") => proto::bot_presence_state::Kind::Running,
            Some("review") => proto::bot_presence_state::Kind::Review,
            _ => return HostToolResult::failure("state is invalid."),
        };
        let mut realtime = match connect_realtime(&self.realtime_url, &self.bot_token).await {
            Ok(client) => client,
            Err(_) => return HostToolResult::failure("Inline presence is unavailable."),
        };
        match realtime
            .call(proto::SetBotPresenceStateInput {
                peer_id: Some(chat_peer(chat_id)),
                state: Some(proto::BotPresenceState {
                    kind: kind.into(),
                    comment: string_arg(arguments, "comment", 120),
                }),
            })
            .await
        {
            Ok(_) => HostToolResult::success("Presence updated."),
            Err(_) => HostToolResult::failure("Inline rejected the presence update."),
        }
    }
}

impl HostToolHandler for InlineToolHost {
    fn call<'a>(&'a self, call: HostToolCall) -> inline_agent_bridge::HostToolFuture<'a> {
        Box::pin(async move { self.execute(call).await })
    }
}

pub(super) fn inline_tool_configuration(host: Arc<InlineToolHost>) -> HostToolConfiguration {
    HostToolConfiguration {
        specs: inline_tool_specs(),
        handler: host,
    }
}

pub(super) fn configure_provider_inline_tools(
    driver: &ProviderDriver,
    configuration: HostToolConfiguration,
) -> Result<Option<String>, Box<dyn std::error::Error>> {
    match driver.capabilities().host_tools {
        HostToolTransport::Native | HostToolTransport::Mcp => {
            let fingerprint = provider_session_configuration_fingerprint(
                driver,
                configuration.compatibility_fingerprint(),
            );
            driver.configure_host_tools(configuration)?;
            return Ok(Some(fingerprint));
        }
        HostToolTransport::Unsupported => {
            eprintln!(
                "Inline tools are unavailable for this provider; ordinary turns remain active."
            );
        }
    }
    Ok(None)
}

fn provider_session_configuration_fingerprint(
    driver: &ProviderDriver,
    host_tools_fingerprint: String,
) -> String {
    match driver {
        // A Codex thread durably stores its native user-input blocks. Bumping
        // this suffix rotates sessions created by the earlier file-URL image
        // adapter, whose malformed historical image block would otherwise
        // make every later turn fail even after the adapter is corrected.
        ProviderDriver::Codex(_) => {
            format!("{host_tools_fingerprint}:codex-local-media-path-v1")
        }
        ProviderDriver::Acp(_) => host_tools_fingerprint,
    }
}

pub(super) fn inline_tool_specs() -> Vec<HostToolSpec> {
    let read = [
        (
            "get_current_context",
            "Get the originating Inline chat, message, operator, and bot context.",
        ),
        ("get_chat", "Get one bot-accessible Inline chat."),
        (
            "get_messages",
            "Get a bounded page of messages from a bot-accessible Inline chat.",
        ),
        (
            "get_history",
            "Get bounded Inline chat history using message ID cursors.",
        ),
        (
            "search_messages",
            "Search messages in a bot-accessible Inline chat.",
        ),
        (
            "search_chats",
            "Search the bot's synced chats and reply threads by title.",
        ),
        ("get_reactions", "Get reactions for one Inline message."),
        ("list_pins", "List pinned message IDs in one Inline chat."),
    ];
    let writes = [
        (
            "create_chat",
            "Create a private Inline chat, or an explicitly requested public space chat.",
        ),
        ("add_reaction", "Add a reaction to an Inline message."),
        (
            "remove_reaction",
            "Remove this bot's reaction from an Inline message.",
        ),
        (
            "pin_message",
            "Pin a message when the user explicitly requested it.",
        ),
        (
            "unpin_message",
            "Unpin a message when the user explicitly requested it.",
        ),
        ("edit_own_message", "Edit a message authored by this bot."),
        (
            "return_attachment",
            "Return a local workspace file or inbound attachment as native Inline media, only when the user explicitly asks to receive it. Choose image when the user wants an image, video when the user wants a video, and file only when the user asks for a file or the format is not displayable media. Never call this merely because a request mentions, reads, edits, changes, or refers to a file. Use it instead of presenting file:// or /tmp paths.",
        ),
        (
            "update_bot_profile",
            "Update only this bot's display name with explicit user intent.",
        ),
        (
            "set_presence",
            "Set this bot's presence in an accessible Inline chat.",
        ),
    ];
    read.into_iter()
        .map(|(name, description)| tool_spec(name, description, true))
        .chain(
            writes
                .into_iter()
                .map(|(name, description)| tool_spec(name, description, false)),
        )
        .collect()
}

fn tool_spec(name: &str, description: &str, read_only: bool) -> HostToolSpec {
    HostToolSpec {
        name: name.to_string(),
        description: description.to_string(),
        input_schema: tool_input_schema(name),
        read_only,
    }
}

fn tool_input_schema(name: &str) -> serde_json::Value {
    let chat_id = serde_json::json!({"type": "integer", "minimum": 1});
    let message_id = serde_json::json!({"type": "integer", "minimum": 1});
    let limit = serde_json::json!({"type": "integer", "minimum": 1, "maximum": 100});
    let confirmed_intent = serde_json::json!({"type": "boolean", "const": true});
    let (properties, required) = match name {
        "get_current_context" => (serde_json::json!({}), Vec::new()),
        "get_chat" | "list_pins" => (serde_json::json!({"chat_id": chat_id}), Vec::new()),
        "get_messages" | "get_history" => (
            serde_json::json!({
                "chat_id": chat_id,
                "before_message_id": message_id,
                "after_message_id": message_id,
                "limit": limit
            }),
            Vec::new(),
        ),
        "search_messages" => (
            serde_json::json!({
                "chat_id": chat_id,
                "query": {"type": "string", "minLength": 1, "maxLength": 500},
                "offset_id": message_id,
                "limit": limit
            }),
            vec!["query"],
        ),
        "search_chats" => (
            serde_json::json!({
                "query": {"type": "string", "minLength": 1, "maxLength": 200}
            }),
            vec!["query"],
        ),
        "get_reactions" => (
            serde_json::json!({"chat_id": chat_id, "message_id": message_id}),
            vec!["message_id"],
        ),
        "create_chat" => (
            serde_json::json!({
                "title": {"type": "string", "minLength": 1, "maxLength": 200},
                "space_id": {"type": "integer", "minimum": 1},
                "description": {"type": "string", "maxLength": 500},
                "emoji": {"type": "string", "maxLength": 32},
                "is_public": {"type": "boolean"},
                "confirmed_intent": confirmed_intent,
                "confirmed_public_intent": {"type": "boolean", "const": true}
            }),
            vec!["title", "confirmed_intent"],
        ),
        "add_reaction" | "remove_reaction" => (
            serde_json::json!({
                "chat_id": chat_id,
                "message_id": message_id,
                "reaction": {"type": "string", "minLength": 1, "maxLength": 32}
            }),
            vec!["message_id", "reaction"],
        ),
        "pin_message" | "unpin_message" => (
            serde_json::json!({
                "chat_id": chat_id,
                "message_id": message_id,
                "confirmed_intent": confirmed_intent
            }),
            vec!["message_id", "confirmed_intent"],
        ),
        "edit_own_message" => (
            serde_json::json!({
                "chat_id": chat_id,
                "message_id": message_id,
                "text": {"type": "string", "minLength": 1, "maxLength": 8000},
                "confirmed_intent": confirmed_intent
            }),
            vec!["message_id", "text", "confirmed_intent"],
        ),
        "return_attachment" => (
            serde_json::json!({
                "path": {"type": "string", "minLength": 1, "maxLength": 4096},
                "file_name": {"type": "string", "minLength": 1, "maxLength": 240, "description": "Original user-facing file name. Supply this when returning one of several inbound attachments."},
                "caption": {"type": "string", "maxLength": 2000},
                "kind": {
                    "type": "string",
                    "enum": ["image", "video", "file"],
                    "description": "The native Inline media kind. Choose from the user's intent: image for a photo/image, video for a video, or file only when explicitly requested or when the format is not displayable media."
                },
                "confirmed_intent": confirmed_intent
            }),
            vec!["path", "kind", "confirmed_intent"],
        ),
        "update_bot_profile" => (
            serde_json::json!({
                "name": {"type": "string", "minLength": 1, "maxLength": 120},
                "confirmed_intent": confirmed_intent
            }),
            vec!["name", "confirmed_intent"],
        ),
        "set_presence" => (
            serde_json::json!({
                "chat_id": chat_id,
                "state": {"type": "string", "enum": ["hidden", "idle", "happy", "waving", "jumping", "failed", "waiting", "running", "review"]},
                "comment": {"type": "string", "maxLength": 120}
            }),
            vec!["state"],
        ),
        _ => (serde_json::json!({}), Vec::new()),
    };
    serde_json::json!({
        "type": "object",
        "additionalProperties": false,
        "properties": properties,
        "required": required
    })
}

fn positive_i64(arguments: &serde_json::Value, key: &str) -> Option<i64> {
    arguments.get(key)?.as_i64().filter(|value| *value > 0)
}

fn bounded_limit(arguments: &serde_json::Value, default: u32, maximum: u32) -> u32 {
    arguments
        .get("limit")
        .and_then(serde_json::Value::as_u64)
        .and_then(|value| u32::try_from(value).ok())
        .unwrap_or(default)
        .clamp(1, maximum)
}

fn string_arg(arguments: &serde_json::Value, key: &str, maximum: usize) -> Option<String> {
    let value = arguments.get(key)?.as_str()?.trim();
    (!value.is_empty() && !value.chars().any(char::is_control))
        .then(|| value.chars().take(maximum).collect())
}

fn bool_arg(arguments: &serde_json::Value, key: &str) -> bool {
    arguments.get(key).and_then(serde_json::Value::as_bool) == Some(true)
}

fn local_file_argument(value: &str) -> Result<PathBuf, &'static str> {
    let path = if value.starts_with("file:") {
        let url = url::Url::parse(value).map_err(|_| "The local file URL is invalid.")?;
        if url.scheme() != "file" {
            return Err("Only a local file URL or absolute path can be returned.");
        }
        url.to_file_path()
            .map_err(|_| "The local file URL does not name a valid path.")?
    } else {
        PathBuf::from(value)
    };
    path.is_absolute()
        .then_some(path)
        .ok_or("The returned file path must be absolute.")
}

fn validated_return_attachment_path(
    requested_path: &Path,
    allowed_roots: &[&Path],
) -> Result<(PathBuf, u64), &'static str> {
    let original =
        fs::symlink_metadata(requested_path).map_err(|_| "The local file is unavailable.")?;
    if !original.file_type().is_file() {
        return Err("Only regular, non-symlink local files can be returned.");
    }
    let canonical =
        fs::canonicalize(requested_path).map_err(|_| "The local file path cannot be verified.")?;
    let allowed = allowed_roots.iter().any(|root| {
        fs::canonicalize(root)
            .ok()
            .is_some_and(|root| canonical.starts_with(root))
    });
    if !allowed {
        return Err(
            "The file must be inside the active workspace or Inline's private attachment cache.",
        );
    }
    let metadata = fs::metadata(&canonical).map_err(|_| "The local file is unavailable.")?;
    if metadata.len() == 0 || metadata.len() > MAX_RETURN_ATTACHMENT_BYTES {
        return Err("The local file must be between 1 byte and 20 MiB.");
    }
    Ok((canonical, metadata.len()))
}

fn inbound_attachment_file_name(
    attachments: &[inline_agent_bridge::InputAttachment],
    returned_path: &Path,
) -> Option<String> {
    attachments.iter().find_map(|attachment| {
        let local_uri = attachment.local_uri.as_deref()?;
        let local_path = local_file_argument(local_uri).ok()?;
        let canonical = fs::canonicalize(local_path).ok()?;
        (canonical == returned_path)
            .then(|| attachment.file_name.as_deref().and_then(safe_file_name))
            .flatten()
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ReturnedVideoMetadata {
    width: u32,
    height: u32,
    duration_ms: u64,
}

fn inbound_video_metadata(
    attachments: &[inline_agent_bridge::InputAttachment],
    returned_path: &Path,
    bytes: &[u8],
    attachment_cache_dir: &Path,
) -> Option<ReturnedVideoMetadata> {
    let exact = attachments.iter().find_map(|attachment| {
        let local_uri = attachment.local_uri.as_deref()?;
        let local_path = local_file_argument(local_uri).ok()?;
        let canonical = fs::canonicalize(local_path).ok()?;
        if canonical != returned_path {
            return None;
        }
        returned_video_metadata(attachment)
    });
    if exact.is_some() {
        return exact;
    }

    let [attachment] = attachments else {
        return None;
    };
    let canonical_cache = fs::canonicalize(attachment_cache_dir).ok()?;
    if !returned_path.starts_with(canonical_cache)
        || returned_path.file_stem()?.to_str()? != hex_digest(bytes)
    {
        return None;
    }
    returned_video_metadata(attachment)
}

fn returned_video_metadata(
    attachment: &inline_agent_bridge::InputAttachment,
) -> Option<ReturnedVideoMetadata> {
    (attachment.kind == inline_agent_bridge::InputAttachmentKind::Video).then_some(())?;
    Some(ReturnedVideoMetadata {
        width: attachment.width.filter(|value| *value > 0)?,
        height: attachment.height.filter(|value| *value > 0)?,
        duration_ms: attachment.duration_ms.filter(|value| *value > 0)?,
    })
}

async fn probe_video_metadata(path: &Path) -> Option<ReturnedVideoMetadata> {
    let mut command = tokio::process::Command::new("ffprobe");
    command
        .kill_on_drop(true)
        .args([
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=width,height,duration:format=duration",
            "-of",
            "json",
        ])
        .arg(path);
    let output = tokio::time::timeout(Duration::from_secs(5), command.output())
        .await
        .ok()?
        .ok()?;
    if !output.status.success() || output.stdout.len() > 16 * 1024 {
        return None;
    }
    let parsed: FfprobeVideoOutput = serde_json::from_slice(&output.stdout).ok()?;
    let stream = parsed.streams.into_iter().next()?;
    let duration = stream
        .duration
        .or_else(|| parsed.format.and_then(|format| format.duration))?
        .parse::<f64>()
        .ok()?;
    if stream.width == 0
        || stream.height == 0
        || !duration.is_finite()
        || duration <= 0.0
        || duration > f64::from(i32::MAX)
    {
        return None;
    }
    Some(ReturnedVideoMetadata {
        width: stream.width,
        height: stream.height,
        duration_ms: (duration * 1_000.0).ceil() as u64,
    })
}

async fn generate_video_thumbnail(path: &Path) -> Option<UploadThumbnail> {
    let mut command = tokio::process::Command::new("ffmpeg");
    command.kill_on_drop(true).args(["-v", "error", "-i"]);
    command.arg(path).args([
        "-map",
        "0:v:0",
        "-frames:v",
        "1",
        "-vf",
        "thumbnail,scale=640:640:force_original_aspect_ratio=decrease",
        "-c:v",
        "mjpeg",
        "-q:v",
        "4",
        "-f",
        "image2pipe",
        "pipe:1",
    ]);
    let output = tokio::time::timeout(Duration::from_secs(10), command.output())
        .await
        .ok()?
        .ok()?;
    if !output.status.success() || !valid_video_thumbnail_bytes(&output.stdout) {
        return None;
    }
    log::trace!(
        target: "inline::bridge::media",
        "phase=video_thumbnail_generated byte_count={} mime_type=\"image/jpeg\"",
        output.stdout.len()
    );
    Some(UploadThumbnail {
        bytes: output.stdout,
        file_name: "video-thumbnail.jpg".to_string(),
        mime_type: "image/jpeg".to_string(),
    })
}

fn valid_video_thumbnail_bytes(bytes: &[u8]) -> bool {
    !bytes.is_empty()
        && bytes.len() <= MAX_VIDEO_THUMBNAIL_BYTES
        && bytes.starts_with(b"\xff\xd8\xff")
        && bytes.ends_with(b"\xff\xd9")
}

#[derive(serde::Deserialize)]
struct FfprobeVideoOutput {
    streams: Vec<FfprobeVideoStream>,
    format: Option<FfprobeVideoFormat>,
}

#[derive(serde::Deserialize)]
struct FfprobeVideoStream {
    width: u32,
    height: u32,
    duration: Option<String>,
}

#[derive(serde::Deserialize)]
struct FfprobeVideoFormat {
    duration: Option<String>,
}

fn unique_cached_attachment_file_name(
    attachments: &[inline_agent_bridge::InputAttachment],
    returned_path: &Path,
    bytes: &[u8],
    attachment_cache_dir: &Path,
) -> Option<String> {
    let [attachment] = attachments else {
        return None;
    };
    let canonical_cache = fs::canonicalize(attachment_cache_dir).ok()?;
    if !returned_path.starts_with(canonical_cache) {
        return None;
    }
    let cached_digest = returned_path.file_stem()?.to_str()?;
    if cached_digest != hex_digest(bytes) {
        return None;
    }
    attachment.file_name.as_deref().and_then(safe_file_name)
}

fn safe_file_name(value: &str) -> Option<String> {
    let name = Path::new(value).file_name()?.to_str()?.trim();
    (!name.is_empty() && !name.chars().any(char::is_control))
        .then(|| name.chars().take(240).collect())
}

fn valid_tool_call_id(call_id: &str) -> bool {
    !call_id.is_empty()
        && call_id.len() <= MAX_HOST_TOOL_CALL_ID_BYTES
        && !call_id.chars().any(char::is_control)
}

fn validate_tool_arguments(
    arguments: &serde_json::Value,
    schema: &serde_json::Value,
) -> Result<(), ()> {
    let arguments = arguments.as_object().ok_or(())?;
    let properties = schema
        .get("properties")
        .and_then(serde_json::Value::as_object)
        .ok_or(())?;
    let required = schema
        .get("required")
        .and_then(serde_json::Value::as_array)
        .ok_or(())?;
    if arguments.keys().any(|key| !properties.contains_key(key)) {
        return Err(());
    }
    for key in required.iter().filter_map(serde_json::Value::as_str) {
        if !arguments.contains_key(key) {
            return Err(());
        }
    }
    for (key, value) in arguments {
        validate_schema_value(value, properties.get(key).ok_or(())?)?;
    }
    Ok(())
}

fn validate_schema_value(value: &serde_json::Value, schema: &serde_json::Value) -> Result<(), ()> {
    match schema.get("type").and_then(serde_json::Value::as_str) {
        Some("integer") => {
            let value = value.as_i64().ok_or(())?;
            if schema
                .get("minimum")
                .and_then(serde_json::Value::as_i64)
                .is_some_and(|minimum| value < minimum)
                || schema
                    .get("maximum")
                    .and_then(serde_json::Value::as_i64)
                    .is_some_and(|maximum| value > maximum)
            {
                return Err(());
            }
        }
        Some("boolean") if !value.is_boolean() => return Err(()),
        Some("string") => {
            let value = value.as_str().ok_or(())?;
            let length = value.chars().count();
            if value.chars().any(char::is_control)
                || schema
                    .get("minLength")
                    .and_then(serde_json::Value::as_u64)
                    .is_some_and(|minimum| length < minimum as usize)
                || schema
                    .get("maxLength")
                    .and_then(serde_json::Value::as_u64)
                    .is_some_and(|maximum| length > maximum as usize)
            {
                return Err(());
            }
        }
        Some("boolean") => {}
        _ => return Err(()),
    }
    if schema
        .get("const")
        .is_some_and(|expected| expected != value)
    {
        return Err(());
    }
    if schema
        .get("enum")
        .and_then(serde_json::Value::as_array)
        .is_some_and(|options| !options.contains(value))
    {
        return Err(());
    }
    Ok(())
}

fn bounded_tool_result(result: HostToolResult) -> HostToolResult {
    if result.content.len() <= MAX_HOST_TOOL_RESULT_BYTES {
        result
    } else {
        HostToolResult::failure("Inline tool result is too large; narrow the request.")
    }
}

fn chat_peer(chat_id: i64) -> proto::InputPeer {
    proto::InputPeer {
        r#type: Some(proto::input_peer::Type::Chat(proto::InputPeerChat {
            chat_id,
        })),
    }
}

fn project_proto_messages(messages: Vec<proto::Message>) -> Vec<serde_json::Value> {
    messages
        .into_iter()
        .take(100)
        .map(|message| {
            serde_json::json!({
                "chat_id": message.chat_id,
                "message_id": message.id,
                "sender_user_id": message.from_id,
                "timestamp": message.date,
                "text": message.message.unwrap_or_default().chars().take(2_000).collect::<String>(),
                "reply_to_message_id": message.reply_to_msg_id,
            })
        })
        .collect()
}

fn json_result<T: Serialize, E>(result: Result<T, E>) -> HostToolResult {
    match result {
        Ok(value) => json_value_result(&value),
        Err(_) => HostToolResult::failure("Inline request failed."),
    }
}

fn json_value_result<T: Serialize>(value: &T) -> HostToolResult {
    serde_json::to_string(value)
        .map(HostToolResult::success)
        .unwrap_or_else(|_| HostToolResult::failure("Inline result could not be encoded."))
}

fn hex_digest(value: &[u8]) -> String {
    Sha256::digest(value)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ReturnAttachmentKind {
    Image,
    Video,
    File,
}

impl ReturnAttachmentKind {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "image" => Some(Self::Image),
            "video" => Some(Self::Video),
            "file" => Some(Self::File),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Image => "image",
            Self::Video => "video",
            Self::File => "file",
        }
    }

    fn protocol_kind(self) -> MediaKind {
        match self {
            Self::Image => MediaKind::Photo,
            Self::Video => MediaKind::Video,
            Self::File => MediaKind::Document,
        }
    }

    fn result_label(self) -> &'static str {
        match self {
            Self::Image => "an image",
            Self::Video => "a video",
            Self::File => "a file",
        }
    }

    fn accepts_mime_type(self, mime_type: &str) -> bool {
        match self {
            Self::Image => matches!(
                mime_type,
                "image/jpeg"
                    | "image/png"
                    | "image/webp"
                    | "image/gif"
                    | "image/heic"
                    | "image/heif"
            ),
            Self::Video => mime_type.starts_with("video/"),
            Self::File => true,
        }
    }
}

fn return_attachment_idempotency_key(event_id: &str, presentation: &str, bytes: &[u8]) -> String {
    let mut digest = Sha256::new();
    digest.update(event_id.as_bytes());
    digest.update([0]);
    digest.update(presentation.as_bytes());
    digest.update([0]);
    digest.update(Sha256::digest(bytes));
    digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_is_distinct_bounded_and_strict() {
        let specs = inline_tool_specs();
        assert_eq!(specs.len(), 17);
        let names = specs.iter().map(|spec| &spec.name).collect::<HashSet<_>>();
        assert_eq!(names.len(), specs.len());
        assert!(
            specs
                .iter()
                .all(|spec| spec.input_schema["additionalProperties"] == false)
        );
        assert!(
            specs
                .iter()
                .any(|spec| spec.name == "search_messages" && spec.read_only)
        );
        assert!(!specs.iter().any(|spec| spec.name == "create_reply_thread"));
        assert!(
            specs
                .iter()
                .any(|spec| spec.name == "return_attachment" && !spec.read_only)
        );
    }

    #[test]
    fn tool_arguments_are_enforced_against_the_advertised_schema() {
        let search_schema = tool_input_schema("search_messages");
        assert!(
            validate_tool_arguments(
                &serde_json::json!({"query": "needle", "limit": 20}),
                &search_schema,
            )
            .is_ok()
        );
        assert!(
            validate_tool_arguments(
                &serde_json::json!({"query": "needle", "unexpected": true}),
                &search_schema,
            )
            .is_err()
        );
        assert!(
            validate_tool_arguments(
                &serde_json::json!({"query": "needle", "limit": 101}),
                &search_schema
            )
            .is_err()
        );

        let mutation_schema = tool_input_schema("pin_message");
        assert!(
            validate_tool_arguments(
                &serde_json::json!({"message_id": 42, "confirmed_intent": false}),
                &mutation_schema,
            )
            .is_err()
        );

        let return_schema = tool_input_schema("return_attachment");
        assert!(
            validate_tool_arguments(
                &serde_json::json!({
                    "path": "/workspace/result.png",
                    "kind": "image",
                    "confirmed_intent": true
                }),
                &return_schema,
            )
            .is_ok()
        );
        assert!(
            validate_tool_arguments(
                &serde_json::json!({
                    "path": "/workspace/result.png",
                    "kind": "image",
                    "confirmed_intent": false
                }),
                &return_schema,
            )
            .is_err()
        );
    }

    #[test]
    fn returned_files_are_regular_bounded_and_contained() {
        let root = tempfile::tempdir().expect("root");
        let file = root.path().join("result.txt");
        fs::write(&file, b"result").expect("write result");
        let file_url = url::Url::from_file_path(&file).expect("file URL");
        assert_eq!(
            local_file_argument(file_url.as_str()).expect("local URL"),
            file
        );
        assert_eq!(
            validated_return_attachment_path(&file, &[root.path()])
                .expect("contained file")
                .1,
            6
        );

        let outside = tempfile::NamedTempFile::new().expect("outside");
        assert!(
            validated_return_attachment_path(outside.path(), &[root.path()])
                .expect_err("outside file")
                .contains("active workspace")
        );
        assert!(local_file_argument("relative.txt").is_err());
    }

    #[test]
    fn returned_inbound_attachment_preserves_its_inline_file_name() {
        let root = tempfile::tempdir().expect("root");
        let cached = root.path().join("content-digest.svg");
        fs::write(&cached, b"<svg/>").expect("cached attachment");
        let canonical = fs::canonicalize(&cached).expect("canonical cached attachment");
        let local_uri = url::Url::from_file_path(&canonical)
            .expect("local URI")
            .to_string();
        let attachments = vec![inline_agent_bridge::InputAttachment {
            kind: inline_agent_bridge::InputAttachmentKind::File,
            uri: "https://cdn.inline.chat/file".to_string(),
            local_uri: Some(local_uri),
            mime_type: Some("image/svg+xml".to_string()),
            file_name: Some("original-logo.svg".to_string()),
            size_bytes: Some(6),
            width: None,
            height: None,
            duration_ms: None,
        }];

        assert_eq!(
            inbound_attachment_file_name(&attachments, &canonical).as_deref(),
            Some("original-logo.svg")
        );
        assert_eq!(
            safe_file_name("../nested/report.pdf").as_deref(),
            Some("report.pdf")
        );
    }

    #[test]
    fn returned_attachment_retries_share_one_direction_and_content_identity() {
        let first = return_attachment_idempotency_key("inline-message-1", "image", b"same bytes");
        let retry = return_attachment_idempotency_key("inline-message-1", "image", b"same bytes");
        let other_direction =
            return_attachment_idempotency_key("inline-message-2", "image", b"same bytes");
        let other_file =
            return_attachment_idempotency_key("inline-message-1", "image", b"other bytes");
        let other_presentation =
            return_attachment_idempotency_key("inline-message-1", "file", b"same bytes");

        assert_eq!(first, retry);
        assert_ne!(first, other_direction);
        assert_ne!(first, other_file);
        assert_ne!(first, other_presentation);
    }

    #[test]
    fn returned_inbound_video_reuses_verified_inline_metadata() {
        let root = tempfile::tempdir().expect("root");
        let cached = root.path().join("clip.mp4");
        fs::write(&cached, b"video").expect("cached attachment");
        let canonical = fs::canonicalize(&cached).expect("canonical cached attachment");
        let local_uri = url::Url::from_file_path(&canonical)
            .expect("local URI")
            .to_string();
        let attachments = vec![inline_agent_bridge::InputAttachment {
            kind: inline_agent_bridge::InputAttachmentKind::Video,
            uri: "https://cdn.inline.chat/clip.mp4".to_string(),
            local_uri: Some(local_uri),
            mime_type: Some("video/mp4".to_string()),
            file_name: Some("clip.mp4".to_string()),
            size_bytes: Some(5),
            width: Some(640),
            height: Some(360),
            duration_ms: Some(1_500),
        }];

        assert_eq!(
            inbound_video_metadata(&attachments, &canonical, b"video", root.path()),
            Some(ReturnedVideoMetadata {
                width: 640,
                height: 360,
                duration_ms: 1_500,
            })
        );
    }

    #[test]
    fn returned_cached_video_recovers_metadata_before_local_uri_is_persisted() {
        let cache = tempfile::tempdir().expect("cache");
        let bytes = b"video";
        let cached = cache.path().join(format!("{}.mp4", hex_digest(bytes)));
        fs::write(&cached, bytes).expect("cached attachment");
        let canonical = fs::canonicalize(&cached).expect("canonical cached attachment");
        let attachments = vec![inline_agent_bridge::InputAttachment {
            kind: inline_agent_bridge::InputAttachmentKind::Video,
            uri: "https://cdn.inline.chat/clip.mp4".to_string(),
            local_uri: None,
            mime_type: Some("video/mp4".to_string()),
            file_name: Some("clip.mp4".to_string()),
            size_bytes: Some(5),
            width: Some(320),
            height: Some(240),
            duration_ms: Some(1_000),
        }];

        assert_eq!(
            inbound_video_metadata(&attachments, &canonical, bytes, cache.path()),
            Some(ReturnedVideoMetadata {
                width: 320,
                height: 240,
                duration_ms: 1_000,
            })
        );
    }

    #[test]
    fn returned_media_kind_matches_inline_protocol_surfaces() {
        assert_eq!(
            ReturnAttachmentKind::Image.protocol_kind(),
            MediaKind::Photo
        );
        assert_eq!(
            ReturnAttachmentKind::Video.protocol_kind(),
            MediaKind::Video
        );
        assert_eq!(
            ReturnAttachmentKind::File.protocol_kind(),
            MediaKind::Document
        );
        assert!(ReturnAttachmentKind::Image.accepts_mime_type("image/png"));
        assert!(!ReturnAttachmentKind::Image.accepts_mime_type("image/svg+xml"));
        assert!(ReturnAttachmentKind::Video.accepts_mime_type("video/mp4"));
        assert!(!ReturnAttachmentKind::Video.accepts_mime_type("audio/mp4"));
    }

    #[test]
    fn generated_video_thumbnail_requires_a_bounded_complete_jpeg() {
        assert!(valid_video_thumbnail_bytes(b"\xff\xd8\xffjpeg\xff\xd9"));
        assert!(!valid_video_thumbnail_bytes(b"\xff\xd8\xfftruncated"));
        assert!(!valid_video_thumbnail_bytes(b"not-a-jpeg"));
        assert!(!valid_video_thumbnail_bytes(&vec![
            0;
            MAX_VIDEO_THUMBNAIL_BYTES
                + 1
        ]));
    }

    #[test]
    fn single_content_addressed_inbound_attachment_recovers_original_name() {
        let cache = tempfile::tempdir().expect("cache");
        let bytes = b"<svg/>";
        let digest = hex_digest(bytes);
        let cached = cache.path().join(format!("{digest}.svg"));
        fs::write(&cached, bytes).expect("cached attachment");
        let canonical = fs::canonicalize(&cached).expect("canonical cached attachment");
        let attachments = vec![inline_agent_bridge::InputAttachment {
            kind: inline_agent_bridge::InputAttachmentKind::File,
            uri: "https://cdn.inline.chat/file".to_string(),
            local_uri: None,
            mime_type: Some("image/svg+xml".to_string()),
            file_name: Some("original-logo.svg".to_string()),
            size_bytes: Some(bytes.len() as u64),
            width: None,
            height: None,
            duration_ms: None,
        }];

        assert_eq!(
            unique_cached_attachment_file_name(&attachments, &canonical, bytes, cache.path())
                .as_deref(),
            Some("original-logo.svg")
        );
    }

    #[test]
    fn host_tool_results_fail_closed_before_provider_or_cache_limits() {
        let allowed = "x".repeat(MAX_HOST_TOOL_RESULT_BYTES);
        assert_eq!(
            bounded_tool_result(HostToolResult::success(&allowed)).content,
            allowed
        );

        let rejected = bounded_tool_result(HostToolResult::success(
            "x".repeat(MAX_HOST_TOOL_RESULT_BYTES + 1),
        ));
        assert!(!rejected.success);
        assert_eq!(
            rejected.content,
            "Inline tool result is too large; narrow the request."
        );
    }
}
