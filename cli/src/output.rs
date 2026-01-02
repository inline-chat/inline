use serde::Serialize;
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
    } else if pretty {
        JsonFormat::Pretty
    } else {
        JsonFormat::Pretty
    }
}

pub fn json_string<T: Serialize + ?Sized>(value: &T, format: JsonFormat) -> Result<String, OutputError> {
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
    name_width = name_width.min(28);
    space_width = space_width.min(18);
    last_width = last_width.min(72);

    println!(
        "{}  {}  {}  {}  {}",
        pad_left("id", 6),
        pad_right("name", name_width),
        pad_right("space", space_width),
        pad_left("unread", 6),
        pad_right("last message", last_width),
    );

    for item in &output.items {
        let preview = item
            .last_message_line
            .as_deref()
            .unwrap_or("<no messages>");
        let space = item.space_name.as_deref().unwrap_or("-");
        println!(
            "{}  {}  {}  {}  {}",
            pad_left(&item.chat.id.to_string(), 6),
            pad_right(&truncate_display(&item.display_name, name_width), name_width),
            pad_right(&truncate_display(space, space_width), space_width),
            pad_left(&item.unread_count.unwrap_or(0).to_string(), 6),
            pad_right(&truncate_display(preview, last_width), last_width),
        );
    }
    Ok(())
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
    name_width = name_width.min(24);
    username_width = username_width.min(16);

    println!(
        "{}  {}  {}  {}  {}  {}",
        pad_left("id", 6),
        pad_right("name", name_width),
        pad_right("username", username_width),
        pad_right("email", 22),
        pad_right("phone", 16),
        pad_right("bot", 3),
    );
    for user in &output.users {
        let username = user.user.username.as_deref().unwrap_or("-");
        let email = user.user.email.as_deref().unwrap_or("-");
        let phone = user.user.phone_number.as_deref().unwrap_or("-");
        let bot = user.user.bot.unwrap_or(false);
        println!(
            "{}  {}  {}  {}  {}  {}",
            pad_left(&user.user.id.to_string(), 6),
            pad_right(&truncate_display(&user.display_name, name_width), name_width),
            pad_right(&truncate_display(username, username_width), username_width),
            pad_right(&truncate_display(email, 22), 22),
            pad_right(&truncate_display(phone, 16), 16),
            pad_right(if bot { "yes" } else { "no" }, 3),
        );
    }
    Ok(())
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
    name_width = name_width.min(32);

    println!(
        "{}  {}  {}",
        pad_left("id", 6),
        pad_right("name", name_width),
        pad_right("creator", 7),
    );
    for space in &output.spaces {
        println!(
            "{}  {}  {}",
            pad_left(&space.space.id.to_string(), 6),
            pad_right(&truncate_display(&space.display_name, name_width), name_width),
            pad_right(if space.space.creator { "yes" } else { "no" }, 7),
        );
    }
    Ok(())
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
    name_width = name_width.min(28);
    role_width = role_width.min(12);

    println!(
        "{}  {}  {}  {}  {}",
        pad_left("user", 6),
        pad_left("member", 6),
        pad_right("name", name_width),
        pad_right("role", role_width),
        pad_right("public", 6),
    );
    for member in &output.members {
        println!(
            "{}  {}  {}  {}  {}",
            pad_left(&member.member.user_id.to_string(), 6),
            pad_left(&member.member.id.to_string(), 6),
            pad_right(&truncate_display(&member.display_name, name_width), name_width),
            pad_right(&truncate_display(&member.role, role_width), role_width),
            pad_right(if member.can_access_public_chats { "yes" } else { "no" }, 6),
        );
    }
    Ok(())
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
    name_width = name_width.min(28);
    joined_width = joined_width.min(10);

    println!(
        "{}  {}  {}",
        pad_left("user", 6),
        pad_right("name", name_width),
        pad_right("joined", joined_width),
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
            println!("Messages for {} ({} {})", peer_name, peer.peer_type, peer.id);
        } else {
            println!("Messages for {}", peer_name);
        }
    }

    let mut from_width = display_width("from");
    let mut when_width = display_width("when");
    for item in &output.items {
        from_width = from_width.max(display_width(&item.sender_name));
        when_width = when_width.max(display_width(&item.relative_date));
    }
    from_width = from_width.min(18);
    when_width = when_width.min(10);

    println!(
        "{}  {}  {}  {}",
        pad_left("id", 6),
        pad_right("when", when_width),
        pad_right("from", from_width),
        pad_right("text", 72),
    );
    for item in &output.items {
        let text = truncate_display(&item.preview, 72);
        println!(
            "{}  {}  {}  {}",
            pad_left(&item.message.id.to_string(), 6),
            pad_right(&item.relative_date, when_width),
            pad_right(&truncate_display(&item.sender_name, from_width), from_width),
            pad_right(&text, 72),
        );
    }
    Ok(())
}

fn display_width(value: &str) -> usize {
    UnicodeWidthStr::width(value)
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
