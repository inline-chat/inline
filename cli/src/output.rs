use serde::Serialize;
use std::collections::HashMap;
use std::env;
use std::io::{self, IsTerminal};
use thiserror::Error;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::protocol::proto;

#[derive(Debug, Error)]
pub enum OutputError {
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Clone, Copy)]
pub enum JsonFormat {
    Pretty,
    Compact,
}

#[derive(Clone, Copy)]
struct FlexibleColumn {
    header: &'static str,
    content_width: usize,
    min_width: usize,
    max_width: usize,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatListOutput {
    pub items: Vec<ChatListItem>,
    pub raw: proto::GetChatsResult,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatListItem {
    pub chat: proto::Chat,
    pub dialog: Option<proto::Dialog>,
    pub peer: PeerSummary,
    pub display_name: String,
    pub space: Option<SpaceSummary>,
    pub space_name: Option<String>,
    pub unread_count: Option<i32>,
    pub last_message: Option<MessageSummary>,
    pub last_message_line: Option<String>,
    pub last_message_relative_date: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UserSummary {
    pub display_name: String,
    pub user: proto::User,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpaceSummary {
    pub display_name: String,
    pub space: proto::Space,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerSummary {
    pub peer_type: String,
    pub id: i64,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageSummary {
    pub message: proto::Message,
    pub preview: String,
    pub translation: Option<proto::MessageTranslation>,
    pub sender: Option<UserSummary>,
    pub sender_name: String,
    pub relative_date: String,
    pub media: Option<MediaSummary>,
    pub attachments: Vec<AttachmentSummary>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaSummary {
    pub kind: String,
    pub file_name: Option<String>,
    pub mime_type: Option<String>,
    pub size: Option<i32>,
    pub duration: Option<i32>,
    pub width: Option<i32>,
    pub height: Option<i32>,
    pub url: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AttachmentSummary {
    pub kind: String,
    pub title: Option<String>,
    pub url: Option<String>,
    pub site_name: Option<String>,
    pub application: Option<String>,
    pub status: Option<String>,
    pub number: Option<String>,
    pub assigned_user_id: Option<i64>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UserListOutput {
    pub users: Vec<UserSummary>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpaceListOutput {
    pub spaces: Vec<SpaceSummary>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageListOutput {
    pub items: Vec<MessageSummary>,
    pub peer: Option<PeerSummary>,
    pub peer_name: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpaceMemberSummary {
    pub member: proto::Member,
    pub user: Option<UserSummary>,
    pub display_name: String,
    pub role: String,
    pub can_access_public_chats: bool,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpaceMembersOutput {
    pub members: Vec<SpaceMemberSummary>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatParticipantSummary {
    pub participant: proto::ChatParticipant,
    pub user: Option<UserSummary>,
    pub display_name: String,
    pub relative_date: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatParticipantsOutput {
    pub participants: Vec<ChatParticipantSummary>,
}

pub fn resolve_json_format(pretty: bool, compact: bool) -> JsonFormat {
    if compact {
        JsonFormat::Compact
    } else {
        // Pretty is the default even when neither --pretty nor --compact are provided.
        // Keep `pretty` parameter for clarity and potential future behavior changes.
        let _ = pretty;
        JsonFormat::Pretty
    }
}

pub fn json_string<T: Serialize + ?Sized>(
    value: &T,
    format: JsonFormat,
) -> Result<String, OutputError> {
    let payload = match format {
        JsonFormat::Pretty => serde_json::to_string_pretty(value)?,
        JsonFormat::Compact => serde_json::to_string(value)?,
    };
    Ok(payload)
}

pub fn print_json<T: Serialize + ?Sized>(value: &T, format: JsonFormat) -> Result<(), OutputError> {
    let payload = json_string(value, format)?;
    println!("{payload}");
    Ok(())
}

pub(crate) fn format_bytes(bytes: i64) -> String {
    let bytes = bytes.max(0) as f64;
    if bytes < 1024.0 {
        return format!("{}B", bytes as i64);
    }
    let kb = bytes / 1024.0;
    if kb < 1024.0 {
        return format!("{:.1}KB", kb);
    }
    let mb = kb / 1024.0;
    if mb < 1024.0 {
        return format!("{:.1}MB", mb);
    }
    let gb = mb / 1024.0;
    format!("{:.1}GB", gb)
}

pub(crate) fn format_relative_date(timestamp: i64, now: i64) -> String {
    if now <= 0 || timestamp <= 0 {
        return "-".to_string();
    }
    let (delta, future) = if timestamp > now {
        (timestamp - now, true)
    } else {
        (now - timestamp, false)
    };
    if delta < 10 {
        return "now".to_string();
    }
    if delta < 60 {
        return format_relative_unit(delta, "s", future);
    }
    let minutes = delta / 60;
    if minutes < 60 {
        return format_relative_unit(minutes, "m", future);
    }
    let hours = minutes / 60;
    if hours < 24 {
        return format_relative_unit(hours, "h", future);
    }
    let days = hours / 24;
    if days < 7 {
        return format_relative_unit(days, "d", future);
    }
    let weeks = days / 7;
    if weeks < 4 {
        return format_relative_unit(weeks, "w", future);
    }
    let months = days / 30;
    if months < 12 {
        return format_relative_unit(months, "mo", future);
    }
    let years = days / 365;
    format_relative_unit(years, "y", future)
}

fn format_relative_unit(value: i64, unit: &str, future: bool) -> String {
    if future {
        format!("in {}{}", value, unit)
    } else {
        format!("{}{} ago", value, unit)
    }
}

pub fn print_chat_list(
    output: &ChatListOutput,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), OutputError> {
    if json {
        return print_json(output, json_format);
    }

    let mut name_width = display_width("name");
    let mut space_width = display_width("space");
    let mut last_width = display_width("last message");
    for item in &output.items {
        name_width = name_width.max(display_width(&item.display_name));
        if let Some(space) = &item.space_name {
            space_width = space_width.max(display_width(space));
        }
        if let Some(line) = &item.last_message_line {
            last_width = last_width.max(display_width(line));
        }
    }
    let widths = flexible_widths(
        &[
            FlexibleColumn {
                header: "name",
                content_width: name_width,
                min_width: 12,
                max_width: 28,
            },
            FlexibleColumn {
                header: "space",
                content_width: space_width,
                min_width: 8,
                max_width: 18,
            },
            FlexibleColumn {
                header: "last message",
                content_width: last_width,
                min_width: 24,
                max_width: 96,
            },
        ],
        fixed_table_width(&[6, 6], 5),
    );
    let name_width = widths[0];
    let space_width = widths[1];
    let last_width = widths[2];

    println!(
        "{}  {}  {}  {}  {}",
        header_left("id", 6),
        header_right("name", name_width),
        header_right("space", space_width),
        header_left("unread", 6),
        header_right("last message", last_width),
    );

    for item in &output.items {
        let preview = item.last_message_line.as_deref().unwrap_or("<no messages>");
        let space = item.space_name.as_deref().unwrap_or("-");
        println!(
            "{}  {}  {}  {}  {}",
            pad_left(&item.chat.id.to_string(), 6),
            pad_right(
                &truncate_display(&item.display_name, name_width),
                name_width
            ),
            pad_right(&truncate_display(space, space_width), space_width),
            pad_left(&item.unread_count.unwrap_or(0).to_string(), 6),
            pad_right(&truncate_display(preview, last_width), last_width),
        );
    }
    Ok(())
}

pub(crate) fn print_chat_details(chat: &proto::Chat, dialog: Option<&proto::Dialog>) {
    for line in chat_detail_lines(chat, dialog) {
        println!("{line}");
    }
}

fn chat_detail_lines(chat: &proto::Chat, dialog: Option<&proto::Dialog>) -> Vec<String> {
    let title = chat.title.trim();
    let name = if !title.is_empty() {
        if let Some(emoji) = chat.emoji.as_deref() {
            if !emoji.trim().is_empty() {
                format!("{} {}", emoji.trim(), title)
            } else {
                title.to_string()
            }
        } else {
            title.to_string()
        }
    } else if let Some(peer) = chat.peer_id.as_ref() {
        match &peer.r#type {
            Some(proto::peer::Type::User(user)) => format!("DM with user {}", user.user_id),
            Some(proto::peer::Type::Chat(chat_peer)) => format!("Chat {}", chat_peer.chat_id),
            None => format!("Chat {}", chat.id),
        }
    } else {
        format!("Chat {}", chat.id)
    };

    let mut lines = vec![format!("Chat {}: {}", chat.id, name)];
    if let Some(space_id) = chat.space_id {
        lines.push(format!("  space: {}", space_id));
    }
    if let Some(is_public) = chat.is_public {
        lines.push(format!(
            "  public: {}",
            if is_public { "yes" } else { "no" }
        ));
    }
    if let Some(description) = chat.description.as_deref() {
        let trimmed = description.trim();
        if !trimmed.is_empty() {
            lines.push(format!("  description: {}", trimmed));
        }
    }
    if let Some(dialog) = dialog {
        if let Some(unread_count) = dialog.unread_count {
            lines.push(format!("  unread: {}", unread_count));
        }
        if let Some(read_max_id) = dialog.read_max_id {
            lines.push(format!("  read max id: {}", read_max_id));
        }
        if let Some(unread_mark) = dialog.unread_mark {
            lines.push(format!(
                "  unread mark: {}",
                if unread_mark { "yes" } else { "no" }
            ));
        }
    }
    lines
}

pub fn print_users(
    output: &UserListOutput,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), OutputError> {
    if json {
        return print_json(output, json_format);
    }

    let mut name_width = display_width("name");
    let mut username_width = display_width("username");
    for user in &output.users {
        name_width = name_width.max(display_width(&user.display_name));
        if let Some(username) = user.user.username.as_deref() {
            username_width = username_width.max(display_width(username));
        }
    }
    let widths = flexible_widths(
        &[
            FlexibleColumn {
                header: "name",
                content_width: name_width,
                min_width: 10,
                max_width: 24,
            },
            FlexibleColumn {
                header: "username",
                content_width: username_width,
                min_width: 8,
                max_width: 16,
            },
            FlexibleColumn {
                header: "email",
                content_width: 22,
                min_width: 10,
                max_width: 28,
            },
            FlexibleColumn {
                header: "phone",
                content_width: 16,
                min_width: 8,
                max_width: 18,
            },
        ],
        fixed_table_width(&[6, 3], 6),
    );
    let name_width = widths[0];
    let username_width = widths[1];
    let email_width = widths[2];
    let phone_width = widths[3];

    println!(
        "{}  {}  {}  {}  {}  {}",
        header_left("id", 6),
        header_right("name", name_width),
        header_right("username", username_width),
        header_right("email", email_width),
        header_right("phone", phone_width),
        header_right("bot", 3),
    );
    for user in &output.users {
        let username = user.user.username.as_deref().unwrap_or("-");
        let email = user.user.email.as_deref().unwrap_or("-");
        let phone = user.user.phone_number.as_deref().unwrap_or("-");
        let bot = user.user.bot.unwrap_or(false);
        println!(
            "{}  {}  {}  {}  {}  {}",
            pad_left(&user.user.id.to_string(), 6),
            pad_right(
                &truncate_display(&user.display_name, name_width),
                name_width
            ),
            pad_right(&truncate_display(username, username_width), username_width),
            pad_right(&truncate_display(email, email_width), email_width),
            pad_right(&truncate_display(phone, phone_width), phone_width),
            pad_right(if bot { "yes" } else { "no" }, 3),
        );
    }
    Ok(())
}

pub(crate) fn build_user_list(result: &proto::GetChatsResult) -> UserListOutput {
    let users = result.users.iter().map(user_summary).collect();
    UserListOutput { users }
}

pub(crate) fn user_summary(user: &proto::User) -> UserSummary {
    UserSummary {
        display_name: user_display_name(user),
        user: user.clone(),
    }
}

pub(crate) fn user_display_name(user: &proto::User) -> String {
    let mut parts = Vec::new();
    if let Some(first) = user
        .first_name
        .as_deref()
        .map(str::trim)
        .filter(|first| !first.is_empty())
    {
        parts.push(first);
    }
    if let Some(last) = user
        .last_name
        .as_deref()
        .map(str::trim)
        .filter(|last| !last.is_empty())
    {
        parts.push(last);
    }
    if !parts.is_empty() {
        return parts.join(" ");
    }
    if let Some(username) = user
        .username
        .as_deref()
        .map(str::trim)
        .filter(|username| !username.is_empty())
    {
        return format!("@{username}");
    }
    if let Some(email) = user
        .email
        .as_deref()
        .map(str::trim)
        .filter(|email| !email.is_empty())
    {
        return email.to_string();
    }
    if let Some(phone) = user
        .phone_number
        .as_deref()
        .map(str::trim)
        .filter(|phone| !phone.is_empty())
    {
        return phone.to_string();
    }
    format!("user {}", user.id)
}

pub fn print_spaces(
    output: &SpaceListOutput,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), OutputError> {
    if json {
        return print_json(output, json_format);
    }

    let mut name_width = display_width("name");
    for space in &output.spaces {
        name_width = name_width.max(display_width(&space.display_name));
    }
    let widths = flexible_widths(
        &[FlexibleColumn {
            header: "name",
            content_width: name_width,
            min_width: 12,
            max_width: 32,
        }],
        fixed_table_width(&[6, 7], 3),
    );
    let name_width = widths[0];

    println!(
        "{}  {}  {}",
        header_left("id", 6),
        header_right("name", name_width),
        header_right("creator", 7),
    );
    for space in &output.spaces {
        println!(
            "{}  {}  {}",
            pad_left(&space.space.id.to_string(), 6),
            pad_right(
                &truncate_display(&space.display_name, name_width),
                name_width
            ),
            pad_right(if space.space.creator { "yes" } else { "no" }, 7),
        );
    }
    Ok(())
}

pub(crate) fn build_space_list(result: &proto::GetChatsResult) -> SpaceListOutput {
    let spaces = result.spaces.iter().map(space_summary).collect();
    SpaceListOutput { spaces }
}

pub(crate) fn space_summary(space: &proto::Space) -> SpaceSummary {
    SpaceSummary {
        display_name: space.name.clone(),
        space: space.clone(),
    }
}

pub fn print_space_members(
    output: &SpaceMembersOutput,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), OutputError> {
    if json {
        return print_json(output, json_format);
    }

    let mut name_width = display_width("name");
    let mut role_width = display_width("role");
    for member in &output.members {
        name_width = name_width.max(display_width(&member.display_name));
        role_width = role_width.max(display_width(&member.role));
    }
    let widths = flexible_widths(
        &[
            FlexibleColumn {
                header: "name",
                content_width: name_width,
                min_width: 12,
                max_width: 28,
            },
            FlexibleColumn {
                header: "role",
                content_width: role_width,
                min_width: 6,
                max_width: 12,
            },
        ],
        fixed_table_width(&[6, 6, 6], 5),
    );
    let name_width = widths[0];
    let role_width = widths[1];

    println!(
        "{}  {}  {}  {}  {}",
        header_left("user", 6),
        header_left("member", 6),
        header_right("name", name_width),
        header_right("role", role_width),
        header_right("public", 6),
    );
    for member in &output.members {
        println!(
            "{}  {}  {}  {}  {}",
            pad_left(&member.member.user_id.to_string(), 6),
            pad_left(&member.member.id.to_string(), 6),
            pad_right(
                &truncate_display(&member.display_name, name_width),
                name_width
            ),
            pad_right(&truncate_display(&member.role, role_width), role_width),
            pad_right(
                if member.can_access_public_chats {
                    "yes"
                } else {
                    "no"
                },
                6
            ),
        );
    }
    Ok(())
}

pub(crate) fn build_space_members_output(
    result: proto::GetSpaceMembersResult,
) -> SpaceMembersOutput {
    let users_by_id: HashMap<i64, proto::User> = result
        .users
        .into_iter()
        .map(|user| (user.id, user))
        .collect();
    let mut members = result
        .members
        .into_iter()
        .map(|member| {
            let can_access_public_chats = member.can_access_public_chats;
            let user = users_by_id.get(&member.user_id).cloned();
            let display_name = user
                .as_ref()
                .map(user_display_name)
                .unwrap_or_else(|| format!("user {}", member.user_id));
            let role = member_role_label(&member);
            SpaceMemberSummary {
                member,
                user: user.as_ref().map(user_summary),
                display_name,
                role,
                can_access_public_chats,
            }
        })
        .collect::<Vec<_>>();
    members.sort_by(|a, b| a.display_name.cmp(&b.display_name));
    SpaceMembersOutput { members }
}

fn member_role_label(member: &proto::Member) -> String {
    match member
        .role
        .and_then(|role| proto::member::Role::try_from(role).ok())
    {
        Some(proto::member::Role::Owner) => "owner".to_string(),
        Some(proto::member::Role::Admin) => "admin".to_string(),
        Some(proto::member::Role::Member) => "member".to_string(),
        None => "-".to_string(),
    }
}

pub fn print_chat_participants(
    output: &ChatParticipantsOutput,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), OutputError> {
    if json {
        return print_json(output, json_format);
    }

    let mut name_width = display_width("name");
    let mut joined_width = display_width("joined");
    for participant in &output.participants {
        name_width = name_width.max(display_width(&participant.display_name));
        joined_width = joined_width.max(display_width(&participant.relative_date));
    }
    let widths = flexible_widths(
        &[
            FlexibleColumn {
                header: "name",
                content_width: name_width,
                min_width: 12,
                max_width: 28,
            },
            FlexibleColumn {
                header: "joined",
                content_width: joined_width,
                min_width: 6,
                max_width: 10,
            },
        ],
        fixed_table_width(&[6], 3),
    );
    let name_width = widths[0];
    let joined_width = widths[1];

    println!(
        "{}  {}  {}",
        header_left("user", 6),
        header_right("name", name_width),
        header_right("joined", joined_width),
    );
    for participant in &output.participants {
        println!(
            "{}  {}  {}",
            pad_left(&participant.participant.user_id.to_string(), 6),
            pad_right(
                &truncate_display(&participant.display_name, name_width),
                name_width
            ),
            pad_right(&participant.relative_date, joined_width),
        );
    }
    Ok(())
}

pub(crate) fn build_chat_participants_output(
    result: proto::GetChatParticipantsResult,
    now: i64,
) -> ChatParticipantsOutput {
    let users_by_id: HashMap<i64, proto::User> = result
        .users
        .into_iter()
        .map(|user| (user.id, user))
        .collect();
    let mut participants = result
        .participants
        .into_iter()
        .map(|participant| {
            let user = users_by_id.get(&participant.user_id).cloned();
            let display_name = user
                .as_ref()
                .map(user_display_name)
                .unwrap_or_else(|| format!("user {}", participant.user_id));
            let relative_date = format_relative_date(participant.date, now);
            ChatParticipantSummary {
                participant,
                user: user.as_ref().map(user_summary),
                display_name,
                relative_date,
            }
        })
        .collect::<Vec<_>>();
    participants.sort_by(|a, b| a.display_name.cmp(&b.display_name));
    ChatParticipantsOutput { participants }
}

pub fn print_messages(
    output: &MessageListOutput,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), OutputError> {
    if json {
        return print_json(output, json_format);
    }

    if let Some(peer_name) = &output.peer_name {
        if let Some(peer) = &output.peer {
            println!(
                "{}",
                style_heading(&format!(
                    "Messages for {} ({} {})",
                    peer_name, peer.peer_type, peer.id
                ))
            );
        } else {
            println!("{}", style_heading(&format!("Messages for {}", peer_name)));
        }
    }

    let mut from_width = display_width("from");
    let mut when_width = display_width("when");
    for item in &output.items {
        from_width = from_width.max(display_width(&item.sender_name));
        when_width = when_width.max(display_width(&item.relative_date));
    }
    let when_width = when_width.min(10);
    let mut text_width = display_width("text");
    for item in &output.items {
        text_width = text_width.max(display_width(&item.preview));
    }
    let widths = flexible_widths(
        &[
            FlexibleColumn {
                header: "from",
                content_width: from_width,
                min_width: 10,
                max_width: 18,
            },
            FlexibleColumn {
                header: "text",
                content_width: text_width,
                min_width: 24,
                max_width: 96,
            },
        ],
        fixed_table_width(&[6, when_width], 4),
    );
    let from_width = widths[0];
    let text_width = widths[1];

    println!(
        "{}  {}  {}  {}",
        header_left("id", 6),
        header_right("when", when_width),
        header_right("from", from_width),
        header_right("text", text_width),
    );
    for item in &output.items {
        let text = truncate_display(&item.preview, text_width);
        println!(
            "{}  {}  {}  {}",
            pad_left(&item.message.id.to_string(), 6),
            pad_right(&item.relative_date, when_width),
            pad_right(&truncate_display(&item.sender_name, from_width), from_width),
            pad_right(&text, text_width),
        );
    }
    Ok(())
}

pub(crate) fn print_message_detail(summary: &MessageSummary, peer_label: &str) {
    println!(
        "{}",
        style_heading(&format!("Message {} ({})", summary.message.id, peer_label))
    );
    println!("  from: {}", summary.sender_name);
    println!(
        "  when: {} ({})",
        summary.relative_date, summary.message.date
    );

    let text = summary
        .message
        .message
        .as_deref()
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .unwrap_or("<non-text>");
    println!();
    println!("{}", style_heading("Text"));
    print_detail_block(text);

    if let Some(translation) = &summary.translation {
        println!();
        println!(
            "{}",
            style_heading(&format!("Translation ({})", translation.language))
        );
        let translated = translation.translation.trim();
        if translated.is_empty() {
            print_detail_block("<empty>");
        } else {
            print_detail_block(translated);
        }
    }

    if let Some(media) = &summary.media {
        println!();
        println!("{}", style_heading("Media"));
        println!("  {}", format_media_detail(media));
    }

    if !summary.attachments.is_empty() {
        println!();
        println!("{}", style_heading("Attachments"));
        for attachment in &summary.attachments {
            println!("  - {}", format_attachment_detail(attachment));
        }
    }
}

fn print_detail_block(value: &str) {
    for line in value.lines() {
        println!("  {}", line);
    }
}

fn format_media_detail(media: &MediaSummary) -> String {
    let mut parts = vec![media.kind.clone()];
    if let Some(file_name) = &media.file_name {
        parts.push(format!("name={}", file_name));
    }
    if let Some(mime) = &media.mime_type {
        parts.push(format!("type={}", mime));
    }
    if let Some(size) = media.size {
        parts.push(format!("size={}", format_bytes(size as i64)));
    }
    if let Some(duration) = media.duration {
        parts.push(format!("duration={}s", duration));
    }
    if let (Some(width), Some(height)) = (media.width, media.height) {
        parts.push(format!("{}x{}", width, height));
    }
    if let Some(url) = &media.url {
        parts.push(format!("url={}", url));
    }
    parts.join(" ")
}

fn format_attachment_detail(attachment: &AttachmentSummary) -> String {
    let mut parts = vec![attachment.kind.clone()];
    if let Some(title) = &attachment.title {
        parts.push(format!("title={}", title));
    }
    if let Some(url) = &attachment.url {
        parts.push(format!("url={}", url));
    }
    if let Some(site) = &attachment.site_name {
        parts.push(format!("site={}", site));
    }
    if let Some(application) = &attachment.application {
        parts.push(format!("app={}", application));
    }
    if let Some(status) = &attachment.status {
        parts.push(format!("status={}", status));
    }
    if let Some(number) = &attachment.number {
        parts.push(format!("number={}", number));
    }
    if let Some(assigned_user_id) = attachment.assigned_user_id {
        parts.push(format!("assignedUserId={}", assigned_user_id));
    }
    parts.join(" ")
}

fn fixed_table_width(fixed_columns: &[usize], column_count: usize) -> usize {
    fixed_columns.iter().sum::<usize>() + column_gap_width(column_count)
}

fn column_gap_width(column_count: usize) -> usize {
    column_count.saturating_sub(1) * 2
}

fn flexible_widths(columns: &[FlexibleColumn], fixed_width: usize) -> Vec<usize> {
    fit_flexible_widths(columns, fixed_width, terminal_columns())
}

fn fit_flexible_widths(
    columns: &[FlexibleColumn],
    fixed_width: usize,
    terminal_columns: Option<usize>,
) -> Vec<usize> {
    let minimum_widths: Vec<usize> = columns
        .iter()
        .map(|column| minimum_column_width(*column))
        .collect();
    let mut widths: Vec<usize> = columns
        .iter()
        .zip(&minimum_widths)
        .map(|(column, minimum)| {
            display_width(column.header)
                .max(column.content_width)
                .min(column.max_width)
                .max(*minimum)
        })
        .collect();

    let Some(terminal_columns) = terminal_columns else {
        return widths;
    };
    let available_width = terminal_columns.saturating_sub(fixed_width);
    if available_width == 0 {
        return widths;
    }

    let minimum_total = minimum_widths.iter().sum::<usize>();
    let target_width = available_width.max(minimum_total);
    let mut current_width = widths.iter().sum::<usize>();

    while current_width > target_width {
        let Some((index, _)) = widths
            .iter()
            .enumerate()
            .filter(|(index, width)| **width > minimum_widths[*index])
            .max_by_key(|(_, width)| **width)
        else {
            break;
        };
        widths[index] -= 1;
        current_width -= 1;
    }

    widths
}

fn minimum_column_width(column: FlexibleColumn) -> usize {
    display_width(column.header)
        .max(column.min_width)
        .min(column.max_width)
}

fn terminal_columns() -> Option<usize> {
    env::var("COLUMNS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|columns| *columns >= 20)
}

fn display_width(value: &str) -> usize {
    UnicodeWidthStr::width(value)
}

fn header_right(value: &str, width: usize) -> String {
    style_heading(&pad_right(value, width))
}

fn header_left(value: &str, width: usize) -> String {
    style_heading(&pad_left(value, width))
}

pub(crate) fn style_heading(value: &str) -> String {
    if should_use_color() {
        format!("\x1b[1m{value}\x1b[0m")
    } else {
        value.to_string()
    }
}

fn should_use_color() -> bool {
    if env::var_os("NO_COLOR").is_some() {
        return false;
    }
    if env::var_os("CLICOLOR_FORCE").is_some_and(|force| force != "0") {
        return true;
    }
    io::stdout().is_terminal()
}

fn truncate_display(value: &str, max_width: usize) -> String {
    if display_width(value) <= max_width {
        return value.to_string();
    }
    let ellipsis = "...";
    let mut width = 0usize;
    let mut output = String::new();
    for ch in value.chars() {
        let ch_width = UnicodeWidthChar::width(ch).unwrap_or(0);
        if width + ch_width + ellipsis.len() > max_width {
            break;
        }
        output.push(ch);
        width += ch_width;
    }
    output.push_str(ellipsis);
    output
}

fn pad_right(value: &str, width: usize) -> String {
    let mut output = value.to_string();
    let current = display_width(value);
    if current < width {
        output.push_str(&" ".repeat(width - current));
    }
    output
}

fn pad_left(value: &str, width: usize) -> String {
    let current = display_width(value);
    if current >= width {
        return value.to_string();
    }
    let mut output = " ".repeat(width - current);
    output.push_str(value);
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flexible_widths_keep_preferred_width_without_terminal_columns() {
        let widths = fit_flexible_widths(
            &[
                FlexibleColumn {
                    header: "name",
                    content_width: 40,
                    min_width: 12,
                    max_width: 28,
                },
                FlexibleColumn {
                    header: "text",
                    content_width: 120,
                    min_width: 24,
                    max_width: 96,
                },
            ],
            20,
            None,
        );
        assert_eq!(widths, vec![28, 96]);
    }

    #[test]
    fn flexible_widths_shrink_widest_columns_to_fit_terminal() {
        let columns = [
            FlexibleColumn {
                header: "name",
                content_width: 40,
                min_width: 12,
                max_width: 28,
            },
            FlexibleColumn {
                header: "space",
                content_width: 30,
                min_width: 8,
                max_width: 18,
            },
            FlexibleColumn {
                header: "last message",
                content_width: 160,
                min_width: 24,
                max_width: 96,
            },
        ];
        let widths = fit_flexible_widths(&columns, 20, Some(80));

        assert_eq!(widths.iter().sum::<usize>(), 60);
        assert!(widths[0] >= 12);
        assert!(widths[1] >= 8);
        assert!(widths[2] >= 24);
    }

    #[test]
    fn truncate_display_preserves_display_width() {
        assert_eq!(truncate_display("hello world", 8), "hello...");
        assert_eq!(display_width(&truncate_display("hello world", 8)), 8);
    }

    #[test]
    fn format_bytes_uses_compact_binary_units() {
        assert_eq!(format_bytes(-1), "0B");
        assert_eq!(format_bytes(512), "512B");
        assert_eq!(format_bytes(1536), "1.5KB");
        assert_eq!(format_bytes(1_572_864), "1.5MB");
        assert_eq!(format_bytes(1_610_612_736), "1.5GB");
    }

    #[test]
    fn format_relative_date_handles_past_future_and_invalid_values() {
        let now = 1_700_000_000;

        assert_eq!(format_relative_date(0, now), "-");
        assert_eq!(format_relative_date(now - 4, now), "now");
        assert_eq!(format_relative_date(now - 45, now), "45s ago");
        assert_eq!(format_relative_date(now - 120, now), "2m ago");
        assert_eq!(format_relative_date(now - 7_200, now), "2h ago");
        assert_eq!(format_relative_date(now - 172_800, now), "2d ago");
        assert_eq!(format_relative_date(now - 1_209_600, now), "2w ago");
        assert_eq!(format_relative_date(now - 5_184_000, now), "2mo ago");
        assert_eq!(format_relative_date(now - 63_072_000, now), "2y ago");
        assert_eq!(format_relative_date(now + 120, now), "in 2m");
    }

    #[test]
    fn chat_detail_lines_include_optional_chat_and_dialog_fields() {
        let chat = proto::Chat {
            id: 123,
            title: "Launch".to_string(),
            emoji: Some("🚀".to_string()),
            space_id: Some(7),
            is_public: Some(false),
            description: Some(" Project launch ".to_string()),
            ..Default::default()
        };
        let dialog = proto::Dialog {
            unread_count: Some(3),
            read_max_id: Some(99),
            unread_mark: Some(true),
            ..Default::default()
        };

        assert_eq!(
            chat_detail_lines(&chat, Some(&dialog)),
            vec![
                "Chat 123: 🚀 Launch",
                "  space: 7",
                "  public: no",
                "  description: Project launch",
                "  unread: 3",
                "  read max id: 99",
                "  unread mark: yes",
            ]
        );
    }

    #[test]
    fn chat_detail_lines_name_dm_without_title() {
        let chat = proto::Chat {
            id: 456,
            peer_id: Some(proto::Peer {
                r#type: Some(proto::peer::Type::User(proto::PeerUser { user_id: 42 })),
            }),
            ..Default::default()
        };

        assert_eq!(
            chat_detail_lines(&chat, None),
            vec!["Chat 456: DM with user 42"]
        );
    }

    #[test]
    fn user_display_name_uses_name_then_username_then_contact_then_id() {
        assert_eq!(
            user_display_name(&proto::User {
                id: 1,
                first_name: Some(" Ava ".to_string()),
                last_name: Some(" Chen ".to_string()),
                username: Some("ava".to_string()),
                ..Default::default()
            }),
            "Ava Chen"
        );
        assert_eq!(
            user_display_name(&proto::User {
                id: 2,
                username: Some("sam".to_string()),
                ..Default::default()
            }),
            "@sam"
        );
        assert_eq!(
            user_display_name(&proto::User {
                id: 3,
                email: Some("sam@example.com".to_string()),
                ..Default::default()
            }),
            "sam@example.com"
        );
        assert_eq!(
            user_display_name(&proto::User {
                id: 4,
                phone_number: Some("+15551234567".to_string()),
                ..Default::default()
            }),
            "+15551234567"
        );
        assert_eq!(
            user_display_name(&proto::User {
                id: 5,
                ..Default::default()
            }),
            "user 5"
        );
    }

    #[test]
    fn space_members_output_uses_user_names_roles_and_sorting() {
        let output = build_space_members_output(proto::GetSpaceMembersResult {
            users: vec![
                proto::User {
                    id: 2,
                    first_name: Some("Zoe".to_string()),
                    ..Default::default()
                },
                proto::User {
                    id: 1,
                    first_name: Some("Ava".to_string()),
                    ..Default::default()
                },
            ],
            members: vec![
                proto::Member {
                    id: 20,
                    user_id: 2,
                    role: Some(proto::member::Role::Member as i32),
                    can_access_public_chats: true,
                    ..Default::default()
                },
                proto::Member {
                    id: 10,
                    user_id: 1,
                    role: Some(proto::member::Role::Admin as i32),
                    can_access_public_chats: false,
                    ..Default::default()
                },
            ],
        });

        assert_eq!(
            output
                .members
                .iter()
                .map(|member| (member.display_name.as_str(), member.role.as_str()))
                .collect::<Vec<_>>(),
            vec![("Ava", "admin"), ("Zoe", "member")]
        );
        assert!(!output.members[0].can_access_public_chats);
        assert!(output.members[1].can_access_public_chats);
    }

    #[test]
    fn chat_participants_output_uses_user_names_dates_and_sorting() {
        let now = 1_700_000_000;
        let output = build_chat_participants_output(
            proto::GetChatParticipantsResult {
                users: vec![
                    proto::User {
                        id: 2,
                        first_name: Some("Zoe".to_string()),
                        ..Default::default()
                    },
                    proto::User {
                        id: 1,
                        first_name: Some("Ava".to_string()),
                        ..Default::default()
                    },
                ],
                participants: vec![
                    proto::ChatParticipant {
                        user_id: 2,
                        date: now - 120,
                    },
                    proto::ChatParticipant {
                        user_id: 1,
                        date: now - 45,
                    },
                ],
            },
            now,
        );

        assert_eq!(
            output
                .participants
                .iter()
                .map(|participant| {
                    (
                        participant.display_name.as_str(),
                        participant.relative_date.as_str(),
                    )
                })
                .collect::<Vec<_>>(),
            vec![("Ava", "45s ago"), ("Zoe", "2m ago")]
        );
    }

    #[test]
    fn media_detail_includes_file_type_size_duration_dimensions_and_url() {
        let media = MediaSummary {
            kind: "video".to_string(),
            file_name: Some("launch.mp4".to_string()),
            mime_type: Some("video/mp4".to_string()),
            size: Some(1_572_864),
            duration: Some(12),
            width: Some(1920),
            height: Some(1080),
            url: Some("https://cdn.example/video".to_string()),
        };

        assert_eq!(
            format_media_detail(&media),
            "video name=launch.mp4 type=video/mp4 size=1.5MB duration=12s 1920x1080 url=https://cdn.example/video"
        );
    }

    #[test]
    fn attachment_detail_includes_available_fields() {
        let attachment = AttachmentSummary {
            kind: "external_task".to_string(),
            title: Some("Fix login".to_string()),
            url: Some("https://linear.example/ISSUE-1".to_string()),
            site_name: Some("Linear".to_string()),
            application: Some("linear".to_string()),
            status: Some("in_progress".to_string()),
            number: Some("ISSUE-1".to_string()),
            assigned_user_id: Some(42),
        };

        assert_eq!(
            format_attachment_detail(&attachment),
            "external_task title=Fix login url=https://linear.example/ISSUE-1 site=Linear app=linear status=in_progress number=ISSUE-1 assignedUserId=42"
        );
    }
}
