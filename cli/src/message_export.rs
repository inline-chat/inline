use std::collections::{BTreeSet, HashMap};
use std::path::Path;

use chrono::{DateTime, Utc};
use clap::ValueEnum;
use serde::Serialize;

use crate::media::best_photo_size;
use crate::output::{self, JsonFormat, user_display_name};
use crate::protocol::proto;

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
pub(crate) enum MessageExportFormat {
    Json,
    Jsonl,
    Markdown,
    Csv,
}

impl MessageExportFormat {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Json => "json",
            Self::Jsonl => "jsonl",
            Self::Markdown => "markdown",
            Self::Csv => "csv",
        }
    }

    pub(crate) fn extension(self) -> &'static str {
        match self {
            Self::Json => "json",
            Self::Jsonl => "jsonl",
            Self::Markdown => "md",
            Self::Csv => "csv",
        }
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ExportPeer {
    pub(crate) peer_type: String,
    pub(crate) id: i64,
    pub(crate) name: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ExportUser {
    pub(crate) id: i64,
    pub(crate) first_name: Option<String>,
    pub(crate) last_name: Option<String>,
    pub(crate) username: Option<String>,
    pub(crate) display_name: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ExportMessage {
    pub(crate) id: i64,
    pub(crate) date: i64,
    pub(crate) date_iso: Option<String>,
    pub(crate) from_id: i64,
    pub(crate) sender_name: String,
    pub(crate) text: Option<String>,
    pub(crate) display_text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) reply_to: Option<ResolvedMessageRef>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) forwarded_from: Option<ResolvedForwardRef>,
    pub(crate) media: Vec<ExportMedia>,
    pub(crate) attachments: Vec<ExportAttachment>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ResolvedMessageRef {
    pub(crate) message_id: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) from_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) sender_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) display_text: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ResolvedForwardRef {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) peer: Option<ExportPeer>,
    pub(crate) from_id: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) sender_name: Option<String>,
    pub(crate) message_id: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) message: Option<ResolvedMessageRef>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ExportMedia {
    pub(crate) kind: String,
    pub(crate) media_id: Option<i64>,
    pub(crate) file_name: Option<String>,
    pub(crate) mime_type: Option<String>,
    pub(crate) size: Option<i32>,
    pub(crate) width: Option<i32>,
    pub(crate) height: Option<i32>,
    pub(crate) duration: Option<i32>,
    pub(crate) cdn_url: Option<String>,
    pub(crate) local_path: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ExportAttachment {
    pub(crate) kind: String,
    pub(crate) title: Option<String>,
    pub(crate) url: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MessageExportBundle {
    pub(crate) peer: ExportPeer,
    pub(crate) messages: Vec<ExportMessage>,
    pub(crate) users: Vec<ExportUser>,
    pub(crate) chats: Vec<proto::Chat>,
    pub(crate) spaces: Vec<proto::Space>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub(crate) translations: Vec<proto::MessageTranslation>,
    #[serde(rename = "_warnings")]
    pub(crate) warnings: Vec<String>,
}

pub(crate) struct MessageExportBuildInput<'a> {
    pub(crate) peer: ExportPeer,
    pub(crate) messages: Vec<proto::Message>,
    pub(crate) users_by_id: &'a HashMap<i64, proto::User>,
    pub(crate) chats_by_id: &'a HashMap<i64, proto::Chat>,
    pub(crate) spaces_by_id: &'a HashMap<i64, proto::Space>,
    pub(crate) related_messages_by_id: &'a HashMap<i64, proto::Message>,
    pub(crate) forward_messages_by_key: &'a HashMap<String, proto::Message>,
    pub(crate) translations: Vec<proto::MessageTranslation>,
    pub(crate) warnings: Vec<String>,
}

pub(crate) fn infer_export_format(
    explicit: Option<MessageExportFormat>,
    output: Option<&Path>,
    default: MessageExportFormat,
) -> MessageExportFormat {
    if let Some(format) = explicit {
        return format;
    }
    let Some(output) = output else {
        return default;
    };
    match output
        .extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.to_ascii_lowercase())
        .as_deref()
    {
        Some("json") => MessageExportFormat::Json,
        Some("jsonl") | Some("ndjson") => MessageExportFormat::Jsonl,
        Some("md") | Some("markdown") => MessageExportFormat::Markdown,
        Some("csv") => MessageExportFormat::Csv,
        _ => default,
    }
}

pub(crate) fn build_message_export_bundle(
    input: MessageExportBuildInput<'_>,
) -> MessageExportBundle {
    let MessageExportBuildInput {
        peer,
        messages,
        users_by_id,
        chats_by_id,
        spaces_by_id,
        related_messages_by_id,
        forward_messages_by_key,
        translations,
        warnings,
    } = input;

    let mut rows = messages
        .iter()
        .map(|message| {
            export_message(
                message,
                users_by_id,
                chats_by_id,
                related_messages_by_id,
                forward_messages_by_key,
            )
        })
        .collect::<Vec<_>>();
    rows.sort_by_key(|message| (message.date, message.id));

    let mut user_ids = BTreeSet::new();
    let mut chat_ids = BTreeSet::new();
    let mut space_ids = BTreeSet::new();
    match peer.peer_type.as_str() {
        "chat" => {
            chat_ids.insert(peer.id);
        }
        "user" => {
            user_ids.insert(peer.id);
        }
        _ => {}
    }

    for row in &rows {
        user_ids.insert(row.from_id);
        if let Some(reply) = &row.reply_to
            && let Some(from_id) = reply.from_id
        {
            user_ids.insert(from_id);
        }
        if let Some(forward) = &row.forwarded_from {
            user_ids.insert(forward.from_id);
            if let Some(source_peer) = &forward.peer {
                match source_peer.peer_type.as_str() {
                    "chat" => {
                        chat_ids.insert(source_peer.id);
                    }
                    "user" => {
                        user_ids.insert(source_peer.id);
                    }
                    _ => {}
                }
            }
        }
    }

    for chat_id in &chat_ids {
        if let Some(chat) = chats_by_id.get(chat_id)
            && let Some(space_id) = chat.space_id
        {
            space_ids.insert(space_id);
        }
    }

    let users = user_ids
        .iter()
        .filter_map(|user_id| users_by_id.get(user_id))
        .map(export_user)
        .collect::<Vec<_>>();
    let chats = chat_ids
        .iter()
        .filter_map(|chat_id| chats_by_id.get(chat_id).cloned())
        .collect();
    let spaces = space_ids
        .iter()
        .filter_map(|space_id| spaces_by_id.get(space_id).cloned())
        .collect();

    MessageExportBundle {
        peer,
        messages: rows,
        users,
        chats,
        spaces,
        translations,
        warnings,
    }
}

pub(crate) fn apply_media_local_paths(
    bundle: &mut MessageExportBundle,
    local_paths_by_message_id: &HashMap<i64, String>,
) {
    for message in &mut bundle.messages {
        let Some(local_path) = local_paths_by_message_id.get(&message.id) else {
            continue;
        };
        for media in &mut message.media {
            if media.kind != "nudge" {
                media.local_path = Some(local_path.clone());
            }
        }
    }
}

pub(crate) fn render_export(
    bundle: &MessageExportBundle,
    format: MessageExportFormat,
    json_format: JsonFormat,
) -> Result<String, Box<dyn std::error::Error>> {
    match format {
        MessageExportFormat::Json => Ok(output::json_string(bundle, json_format)?),
        MessageExportFormat::Jsonl => render_jsonl(bundle),
        MessageExportFormat::Markdown => Ok(render_markdown(bundle)),
        MessageExportFormat::Csv => Ok(render_csv(bundle)),
    }
}

pub(crate) fn forward_source_key(peer: &proto::Peer, message_id: i64) -> Option<String> {
    match &peer.r#type {
        Some(proto::peer::Type::Chat(chat)) => Some(format!("chat:{}:{message_id}", chat.chat_id)),
        Some(proto::peer::Type::User(user)) => Some(format!("user:{}:{message_id}", user.user_id)),
        None => None,
    }
}

pub(crate) fn export_peer_from_proto_peer(
    peer: &proto::Peer,
    users_by_id: &HashMap<i64, proto::User>,
    chats_by_id: &HashMap<i64, proto::Chat>,
) -> Option<ExportPeer> {
    match &peer.r#type {
        Some(proto::peer::Type::Chat(chat)) => Some(ExportPeer {
            peer_type: "chat".to_string(),
            id: chat.chat_id,
            name: chats_by_id
                .get(&chat.chat_id)
                .map(|chat| chat.title.clone()),
        }),
        Some(proto::peer::Type::User(user)) => Some(ExportPeer {
            peer_type: "user".to_string(),
            id: user.user_id,
            name: users_by_id.get(&user.user_id).map(user_display_name),
        }),
        None => None,
    }
}

fn export_message(
    message: &proto::Message,
    users_by_id: &HashMap<i64, proto::User>,
    chats_by_id: &HashMap<i64, proto::Chat>,
    related_messages_by_id: &HashMap<i64, proto::Message>,
    forward_messages_by_key: &HashMap<String, proto::Message>,
) -> ExportMessage {
    let media = export_media(message);
    let attachments = export_attachments(message);
    let display_text = display_text(message.message.as_deref(), &media, &attachments);
    let reply_to = message.reply_to_msg_id.map(|message_id| {
        if let Some(reply) = related_messages_by_id.get(&message_id) {
            resolved_message_ref(reply, users_by_id)
        } else {
            ResolvedMessageRef {
                message_id,
                from_id: None,
                sender_name: None,
                text: None,
                display_text: None,
            }
        }
    });
    let forwarded_from = message.fwd_from.as_ref().map(|forward| {
        let peer = forward
            .from_peer_id
            .as_ref()
            .and_then(|peer| export_peer_from_proto_peer(peer, users_by_id, chats_by_id));
        let source_message = forward
            .from_peer_id
            .as_ref()
            .and_then(|peer| forward_source_key(peer, forward.from_message_id))
            .and_then(|key| forward_messages_by_key.get(&key))
            .map(|message| resolved_message_ref(message, users_by_id));
        ResolvedForwardRef {
            peer,
            from_id: forward.from_id,
            sender_name: users_by_id.get(&forward.from_id).map(user_display_name),
            message_id: forward.from_message_id,
            message: source_message,
        }
    });

    ExportMessage {
        id: message.id,
        date: message.date,
        date_iso: date_iso(message.date),
        from_id: message.from_id,
        sender_name: users_by_id
            .get(&message.from_id)
            .map(user_display_name)
            .unwrap_or_else(|| format!("user {}", message.from_id)),
        text: message.message.clone(),
        display_text,
        reply_to,
        forwarded_from,
        media,
        attachments,
    }
}

fn resolved_message_ref(
    message: &proto::Message,
    users_by_id: &HashMap<i64, proto::User>,
) -> ResolvedMessageRef {
    let media = export_media(message);
    let attachments = export_attachments(message);
    ResolvedMessageRef {
        message_id: message.id,
        from_id: Some(message.from_id),
        sender_name: users_by_id.get(&message.from_id).map(user_display_name),
        text: message.message.clone(),
        display_text: Some(display_text(
            message.message.as_deref(),
            &media,
            &attachments,
        )),
    }
}

fn export_user(user: &proto::User) -> ExportUser {
    ExportUser {
        id: user.id,
        first_name: user.first_name.as_deref().and_then(empty_string_to_none),
        last_name: user
            .last_name
            .as_ref()
            .and_then(|value| empty_string_to_none(value)),
        username: user
            .username
            .as_ref()
            .and_then(|value| empty_string_to_none(value)),
        display_name: user_display_name(user),
    }
}

fn export_media(message: &proto::Message) -> Vec<ExportMedia> {
    let Some(media) = message.media.as_ref() else {
        return Vec::new();
    };
    match &media.media {
        Some(proto::message_media::Media::Photo(photo)) => {
            let Some(photo) = photo.photo.as_ref() else {
                return Vec::new();
            };
            let (cdn_url, size, width, height) = best_photo_size(photo);
            vec![ExportMedia {
                kind: "photo".to_string(),
                media_id: Some(photo.id),
                file_name: None,
                mime_type: Some(match proto::photo::Format::try_from(photo.format) {
                    Ok(proto::photo::Format::Png) => "image/png".to_string(),
                    _ => "image/jpeg".to_string(),
                }),
                size,
                width,
                height,
                duration: None,
                cdn_url,
                local_path: None,
            }]
        }
        Some(proto::message_media::Media::Video(video)) => video
            .video
            .as_ref()
            .map(|video| {
                vec![ExportMedia {
                    kind: "video".to_string(),
                    media_id: Some(video.id),
                    file_name: None,
                    mime_type: Some("video/mp4".to_string()),
                    size: Some(video.size),
                    width: Some(video.w),
                    height: Some(video.h),
                    duration: Some(video.duration),
                    cdn_url: video.cdn_url.clone(),
                    local_path: None,
                }]
            })
            .unwrap_or_default(),
        Some(proto::message_media::Media::Document(document)) => document
            .document
            .as_ref()
            .map(|document| {
                vec![ExportMedia {
                    kind: "document".to_string(),
                    media_id: Some(document.id),
                    file_name: Some(document.file_name.clone()),
                    mime_type: Some(document.mime_type.clone()),
                    size: Some(document.size),
                    width: None,
                    height: None,
                    duration: None,
                    cdn_url: document.cdn_url.clone(),
                    local_path: None,
                }]
            })
            .unwrap_or_default(),
        Some(proto::message_media::Media::Voice(voice)) => voice
            .voice
            .as_ref()
            .map(|voice| {
                vec![ExportMedia {
                    kind: "voice".to_string(),
                    media_id: Some(voice.id),
                    file_name: None,
                    mime_type: Some(voice.mime_type.clone()),
                    size: Some(voice.size),
                    width: None,
                    height: None,
                    duration: Some(voice.duration),
                    cdn_url: voice.cdn_url.clone(),
                    local_path: None,
                }]
            })
            .unwrap_or_default(),
        Some(proto::message_media::Media::Nudge(_)) => vec![ExportMedia {
            kind: "nudge".to_string(),
            media_id: None,
            file_name: None,
            mime_type: None,
            size: None,
            width: None,
            height: None,
            duration: None,
            cdn_url: None,
            local_path: None,
        }],
        None => Vec::new(),
    }
}

fn export_attachments(message: &proto::Message) -> Vec<ExportAttachment> {
    let Some(attachments) = message.attachments.as_ref() else {
        return Vec::new();
    };
    attachments
        .attachments
        .iter()
        .filter_map(|attachment| match &attachment.attachment {
            Some(proto::message_attachment::Attachment::UrlPreview(preview)) => {
                Some(ExportAttachment {
                    kind: "url_preview".to_string(),
                    title: preview.title.clone(),
                    url: preview.url.clone(),
                })
            }
            Some(proto::message_attachment::Attachment::ExternalTask(task)) => {
                Some(ExportAttachment {
                    kind: "external_task".to_string(),
                    title: Some(task.title.clone()),
                    url: Some(task.url.clone()),
                })
            }
            None => None,
        })
        .collect()
}

fn display_text(
    text: Option<&str>,
    media: &[ExportMedia],
    attachments: &[ExportAttachment],
) -> String {
    if let Some(text) = text.map(str::trim).filter(|text| !text.is_empty()) {
        return text.to_string();
    }
    if let Some(media) = media.first() {
        return format!("[{}]", media.kind);
    }
    if let Some(attachment) = attachments.first() {
        return format!("[{}]", attachment.kind);
    }
    "[non-text]".to_string()
}

fn render_jsonl(bundle: &MessageExportBundle) -> Result<String, Box<dyn std::error::Error>> {
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct ContextLine<'a> {
        r#type: &'static str,
        peer: &'a ExportPeer,
        users: &'a [ExportUser],
        chats: &'a [proto::Chat],
        spaces: &'a [proto::Space],
        translations: &'a [proto::MessageTranslation],
        #[serde(rename = "_warnings")]
        warnings: &'a [String],
    }

    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct MessageLine<'a> {
        r#type: &'static str,
        message: &'a ExportMessage,
    }

    let mut lines = Vec::with_capacity(bundle.messages.len() + 1);
    lines.push(serde_json::to_string(&ContextLine {
        r#type: "context",
        peer: &bundle.peer,
        users: &bundle.users,
        chats: &bundle.chats,
        spaces: &bundle.spaces,
        translations: &bundle.translations,
        warnings: &bundle.warnings,
    })?);
    for message in &bundle.messages {
        lines.push(serde_json::to_string(&MessageLine {
            r#type: "message",
            message,
        })?);
    }
    Ok(format!("{}\n", lines.join("\n")))
}

fn render_markdown(bundle: &MessageExportBundle) -> String {
    let mut output = String::new();
    output.push_str("# ");
    output.push_str(bundle.peer.name.as_deref().unwrap_or("Inline transcript"));
    output.push_str("\n\n");
    if let Some(url) = inline_peer_url(&bundle.peer) {
        output.push_str("[Open in Inline](");
        output.push_str(&url);
        output.push_str(")\n\n");
    }

    let mut last_timestamp_date = None;
    for message in &bundle.messages {
        output.push_str("**");
        output.push_str(&message.sender_name);
        output.push_str("**");
        if should_show_timestamp(last_timestamp_date, message.date) {
            output.push_str(" - ");
            output.push_str(&format_markdown_date(message.date));
            last_timestamp_date = Some(message.date);
        }
        output.push_str("\n\n");

        if let Some(reply) = &message.reply_to
            && let Some(display_text) = reply.display_text.as_deref()
        {
            output.push_str("*Replying to ");
            output.push_str(reply.sender_name.as_deref().unwrap_or("message"));
            output.push_str(": \"");
            output.push_str(&markdown_inline_preview(display_text));
            output.push_str("\"*\n\n");
        }

        if let Some(forward) = &message.forwarded_from {
            output.push_str("Forwarded from ");
            if let Some(peer) = &forward.peer {
                output.push_str(peer.name.as_deref().unwrap_or(&peer.peer_type));
                output.push_str(" / ");
            }
            output.push_str(forward.sender_name.as_deref().unwrap_or("unknown sender"));
            output.push_str(":\n\n");
            if let Some(source) = &forward.message
                && let Some(display_text) = source.display_text.as_deref()
            {
                output.push_str("> ");
                output.push_str(&display_text.replace('\n', "\n> "));
                output.push_str("\n\n");
            }
        }

        if let Some(text) = message
            .text
            .as_deref()
            .map(str::trim)
            .filter(|text| !text.is_empty())
        {
            output.push_str(text);
            output.push_str("\n\n");
        }

        for media in &message.media {
            if let Some(url) = media.local_path.as_ref().or(media.cdn_url.as_ref()) {
                match media.kind.as_str() {
                    "photo" => {
                        output.push_str("![photo](");
                        output.push_str(url);
                        output.push_str(")\n\n");
                    }
                    kind => {
                        output.push('[');
                        output.push_str(kind);
                        if let Some(file_name) = &media.file_name {
                            output.push_str(": ");
                            output.push_str(file_name);
                        }
                        output.push_str("](");
                        output.push_str(url);
                        output.push_str(")\n\n");
                    }
                }
            } else if media.kind != "nudge" {
                output.push('[');
                output.push_str(&media.kind);
                output.push_str("]\n\n");
            }
        }

        for attachment in &message.attachments {
            if let Some(url) = &attachment.url {
                output.push('[');
                output.push_str(attachment.title.as_deref().unwrap_or(&attachment.kind));
                output.push_str("](");
                output.push_str(url);
                output.push_str(")\n\n");
            }
        }

        output.push_str(&markdown_metadata_comment(message));
        output.push_str("\n\n");
    }

    output
}

fn inline_peer_url(peer: &ExportPeer) -> Option<String> {
    match peer.peer_type.as_str() {
        "chat" => Some(format!("inline://chat/{}", peer.id)),
        "user" => Some(format!("inline://user/{}", peer.id)),
        _ => None,
    }
}

fn should_show_timestamp(previous_date: Option<i64>, current_date: i64) -> bool {
    match previous_date {
        Some(previous_date) => current_date.saturating_sub(previous_date).abs() >= 600,
        None => true,
    }
}

fn markdown_metadata_comment(message: &ExportMessage) -> String {
    let mut fields = vec![
        format!("MSG={}", message.id),
        format!("from={}", message.from_id),
        format!("date={}", message.date),
    ];
    if let Some(forward) = &message.forwarded_from {
        if let Some(peer) = &forward.peer {
            match peer.peer_type.as_str() {
                "chat" => fields.push(format!("fwd_chat={}", peer.id)),
                "user" => fields.push(format!("fwd_user={}", peer.id)),
                _ => {}
            }
        }
        fields.push(format!("fwd_MSG={}", forward.message_id));
    }
    format!("<!-- inline: {} -->", fields.join(" "))
}

fn render_csv(bundle: &MessageExportBundle) -> String {
    let mut output = String::new();
    output.push_str("id,date,date_iso,from_id,sender_name,text,display_text,reply_to_msg_id,reply_to_preview,forward_from_peer_type,forward_from_peer_id,forward_from_msg_id,forward_preview,media_count,media_kinds,media_urls,local_paths\n");
    for message in &bundle.messages {
        let media_kinds = message
            .media
            .iter()
            .map(|media| media.kind.as_str())
            .collect::<Vec<_>>()
            .join(";");
        let media_urls = message
            .media
            .iter()
            .filter_map(|media| media.cdn_url.as_deref())
            .collect::<Vec<_>>()
            .join(";");
        let local_paths = message
            .media
            .iter()
            .filter_map(|media| media.local_path.as_deref())
            .collect::<Vec<_>>()
            .join(";");
        let forward_peer_type = message
            .forwarded_from
            .as_ref()
            .and_then(|forward| forward.peer.as_ref())
            .map(|peer| peer.peer_type.as_str())
            .unwrap_or("");
        let forward_peer_id = message
            .forwarded_from
            .as_ref()
            .and_then(|forward| forward.peer.as_ref())
            .map(|peer| peer.id.to_string())
            .unwrap_or_default();
        let forward_preview = message
            .forwarded_from
            .as_ref()
            .and_then(|forward| forward.message.as_ref())
            .and_then(|message| message.display_text.as_deref())
            .unwrap_or("");
        let fields = [
            message.id.to_string(),
            message.date.to_string(),
            message.date_iso.clone().unwrap_or_default(),
            message.from_id.to_string(),
            message.sender_name.clone(),
            message.text.clone().unwrap_or_default(),
            message.display_text.clone(),
            message
                .reply_to
                .as_ref()
                .map(|reply| reply.message_id.to_string())
                .unwrap_or_default(),
            message
                .reply_to
                .as_ref()
                .and_then(|reply| reply.display_text.clone())
                .unwrap_or_default(),
            forward_peer_type.to_string(),
            forward_peer_id,
            message
                .forwarded_from
                .as_ref()
                .map(|forward| forward.message_id.to_string())
                .unwrap_or_default(),
            forward_preview.to_string(),
            message.media.len().to_string(),
            media_kinds,
            media_urls,
            local_paths,
        ];
        output.push_str(
            &fields
                .iter()
                .map(|field| csv_field(field))
                .collect::<Vec<_>>()
                .join(","),
        );
        output.push('\n');
    }
    output
}

fn date_iso(timestamp: i64) -> Option<String> {
    DateTime::<Utc>::from_timestamp(timestamp, 0).map(|date| date.to_rfc3339())
}

fn format_markdown_date(timestamp: i64) -> String {
    DateTime::<Utc>::from_timestamp(timestamp, 0)
        .map(|date| date.format("%b %-d, %H:%M UTC").to_string())
        .unwrap_or_else(|| timestamp.to_string())
}

fn markdown_inline_preview(value: &str) -> String {
    let value = value
        .replace(['\n', '\r'], " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if value.chars().count() <= 120 {
        return value;
    }
    let mut preview = value.chars().take(117).collect::<String>();
    preview.push_str("...");
    preview
}

fn csv_field(value: &str) -> String {
    if value.contains([',', '"', '\n', '\r']) {
        format!("\"{}\"", value.replace('"', "\"\""))
    } else {
        value.to_string()
    }
}

fn empty_string_to_none(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn infers_export_format_from_output_extension() {
        assert_eq!(
            infer_export_format(
                None,
                Some(Path::new("feedback.md")),
                MessageExportFormat::Json
            ),
            MessageExportFormat::Markdown
        );
        assert_eq!(
            infer_export_format(None, None, MessageExportFormat::Markdown),
            MessageExportFormat::Markdown
        );
    }

    #[test]
    fn markdown_transcript_is_content_first() {
        let user = proto::User {
            id: 1,
            first_name: Some("Ava".to_string()),
            ..Default::default()
        };
        let mut users = HashMap::new();
        users.insert(user.id, user);
        let empty_chats = HashMap::new();
        let empty_spaces = HashMap::new();
        let empty_messages = HashMap::new();
        let empty_forwards = HashMap::new();
        let bundle = build_message_export_bundle(MessageExportBuildInput {
            peer: ExportPeer {
                peer_type: "chat".to_string(),
                id: 10,
                name: Some("Town Hall".to_string()),
            },
            messages: vec![proto::Message {
                id: 7,
                from_id: 1,
                message: Some("Ship it".to_string()),
                date: 0,
                ..Default::default()
            }],
            users_by_id: &users,
            chats_by_id: &empty_chats,
            spaces_by_id: &empty_spaces,
            related_messages_by_id: &empty_messages,
            forward_messages_by_key: &empty_forwards,
            translations: Vec::new(),
            warnings: Vec::new(),
        });

        let markdown = render_markdown(&bundle);
        assert!(markdown.contains("# Town Hall"));
        assert!(markdown.contains("[Open in Inline](inline://chat/10)"));
        assert!(markdown.contains("**Ava**"));
        assert!(markdown.contains("Ship it"));
        assert!(markdown.contains("<!-- inline: MSG=7 from=1 date=0 -->"));
    }

    #[test]
    fn markdown_keeps_replies_light_and_timestamps_sparse() {
        let ava = proto::User {
            id: 1,
            first_name: Some("Ava".to_string()),
            ..Default::default()
        };
        let ben = proto::User {
            id: 2,
            first_name: Some("Ben".to_string()),
            ..Default::default()
        };
        let mut users = HashMap::new();
        users.insert(ava.id, ava);
        users.insert(ben.id, ben);
        let empty_chats = HashMap::new();
        let empty_spaces = HashMap::new();
        let first = proto::Message {
            id: 1,
            from_id: 1,
            message: Some("First note".to_string()),
            date: 0,
            ..Default::default()
        };
        let reply = proto::Message {
            id: 2,
            from_id: 2,
            message: Some("Agree".to_string()),
            reply_to_msg_id: Some(1),
            date: 300,
            ..Default::default()
        };
        let later = proto::Message {
            id: 3,
            from_id: 1,
            message: Some("Later note".to_string()),
            date: 1200,
            ..Default::default()
        };
        let related_messages = HashMap::from([(first.id, first.clone())]);
        let empty_forwards = HashMap::new();
        let bundle = build_message_export_bundle(MessageExportBuildInput {
            peer: ExportPeer {
                peer_type: "chat".to_string(),
                id: 10,
                name: Some("Town Hall".to_string()),
            },
            messages: vec![first, reply, later],
            users_by_id: &users,
            chats_by_id: &empty_chats,
            spaces_by_id: &empty_spaces,
            related_messages_by_id: &related_messages,
            forward_messages_by_key: &empty_forwards,
            translations: Vec::new(),
            warnings: Vec::new(),
        });

        let markdown = render_markdown(&bundle);

        assert!(markdown.contains("**Ben**\n\n*Replying to Ava: \"First note\"*"));
        assert_eq!(markdown.matches("Jan 1, 00:").count(), 2);
    }

    #[test]
    fn markdown_prefers_downloaded_media_paths() {
        let user = proto::User {
            id: 1,
            first_name: Some("Ava".to_string()),
            ..Default::default()
        };
        let mut users = HashMap::new();
        users.insert(user.id, user);
        let empty_chats = HashMap::new();
        let empty_spaces = HashMap::new();
        let empty_messages = HashMap::new();
        let empty_forwards = HashMap::new();
        let mut bundle = build_message_export_bundle(MessageExportBuildInput {
            peer: ExportPeer {
                peer_type: "chat".to_string(),
                id: 10,
                name: Some("Town Hall".to_string()),
            },
            messages: vec![proto::Message {
                id: 8,
                from_id: 1,
                date: 0,
                media: Some(proto::MessageMedia {
                    media: Some(proto::message_media::Media::Document(
                        proto::MessageDocument {
                            document: Some(proto::Document {
                                id: 32,
                                file_name: "report.pdf".to_string(),
                                mime_type: "application/pdf".to_string(),
                                cdn_url: Some("https://cdn.example/report.pdf".to_string()),
                                ..Default::default()
                            }),
                        },
                    )),
                }),
                ..Default::default()
            }],
            users_by_id: &users,
            chats_by_id: &empty_chats,
            spaces_by_id: &empty_spaces,
            related_messages_by_id: &empty_messages,
            forward_messages_by_key: &empty_forwards,
            translations: Vec::new(),
            warnings: Vec::new(),
        });
        let local_paths = HashMap::from([(
            8,
            "feedback-media/19700101-0000-MSG8-document-32-report.pdf".to_string(),
        )]);

        apply_media_local_paths(&mut bundle, &local_paths);
        let markdown = render_markdown(&bundle);

        assert!(markdown.contains("feedback-media/19700101-0000-MSG8-document-32-report.pdf"));
        assert!(!markdown.contains("https://cdn.example/report.pdf"));
    }
}
