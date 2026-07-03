use std::cmp::Reverse;
use std::collections::{HashMap, HashSet};

use crate::message_output::message_summary;
use crate::output::{
    ChatListItem, ChatListOutput, PeerSummary, SpaceSummary, space_summary, user_display_name,
};
use crate::peer::{MessageKey, PeerKey, peer_key_from_peer};
use crate::protocol::proto;

pub(crate) fn apply_chat_list_limits(
    mut payload: proto::GetChatsResult,
    limit: Option<usize>,
    offset: Option<usize>,
) -> proto::GetChatsResult {
    let offset = offset.unwrap_or(0);
    let limit = limit.unwrap_or(payload.chats.len());

    payload.chats = payload.chats.into_iter().skip(offset).take(limit).collect();

    // `GetChatsResult` is denormalized, so keep only lists referenced by the retained chats.
    let kept_chat_ids: HashSet<i64> = payload.chats.iter().map(|chat| chat.id).collect();

    // Chat payloads include both chat peers and user peers. Preserve both or DM rows lose messages.
    let mut kept_peers: HashSet<PeerKey> = HashSet::new();
    for chat in &payload.chats {
        kept_peers.insert(PeerKey::Chat(chat.id));
        if let Some(peer) = chat.peer_id.as_ref().and_then(peer_key_from_peer) {
            kept_peers.insert(peer);
        }
    }

    payload.dialogs.retain(|dialog| {
        if let Some(chat_id) = dialog.chat_id {
            if kept_chat_ids.contains(&chat_id) {
                return true;
            }
        }
        dialog
            .peer
            .as_ref()
            .and_then(peer_key_from_peer)
            .is_some_and(|peer| kept_peers.contains(&peer))
    });

    payload.messages.retain(|message| {
        message
            .peer_id
            .as_ref()
            .and_then(peer_key_from_peer)
            .is_some_and(|peer| kept_peers.contains(&peer))
            || (message.chat_id != 0 && kept_peers.contains(&PeerKey::Chat(message.chat_id)))
    });

    let mut kept_space_ids: HashSet<i64> = HashSet::new();
    for chat in &payload.chats {
        if let Some(space_id) = chat.space_id {
            kept_space_ids.insert(space_id);
        }
    }
    for dialog in &payload.dialogs {
        if let Some(space_id) = dialog.space_id {
            kept_space_ids.insert(space_id);
        }
    }
    payload
        .spaces
        .retain(|space| kept_space_ids.contains(&space.id));

    let mut kept_user_ids: HashSet<i64> = HashSet::new();
    for message in &payload.messages {
        kept_user_ids.insert(message.from_id);
    }
    for chat in &payload.chats {
        if let Some(created_by) = chat.created_by {
            kept_user_ids.insert(created_by);
        }
        if let Some(PeerKey::User(user_id)) = chat.peer_id.as_ref().and_then(peer_key_from_peer) {
            kept_user_ids.insert(user_id);
        }
    }
    for dialog in &payload.dialogs {
        if let Some(PeerKey::User(user_id)) = dialog.peer.as_ref().and_then(peer_key_from_peer) {
            kept_user_ids.insert(user_id);
        }
    }
    payload
        .users
        .retain(|user| kept_user_ids.contains(&user.id));

    payload
}

pub(crate) fn apply_chat_list_filter(
    mut payload: proto::GetChatsResult,
    filter: Option<&str>,
) -> proto::GetChatsResult {
    let needle = filter
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.to_lowercase());

    let Some(needle) = needle.as_deref() else {
        return payload;
    };

    let mut users_by_id: HashMap<i64, proto::User> = HashMap::new();
    for user in &payload.users {
        users_by_id.insert(user.id, user.clone());
    }

    let mut spaces_by_id: HashMap<i64, proto::Space> = HashMap::new();
    for space in &payload.spaces {
        spaces_by_id.insert(space.id, space.clone());
    }

    payload.chats.retain(|chat| {
        let display_name = chat_display_name(chat, &users_by_id);
        if display_name.to_lowercase().contains(needle) {
            return true;
        }

        if let Some(space_id) = chat.space_id {
            if let Some(space) = spaces_by_id.get(&space_id) {
                if space.name.to_lowercase().contains(needle) {
                    return true;
                }
            }
        }

        if chat.id.to_string().contains(needle) {
            return true;
        }

        let peer_id = chat
            .peer_id
            .as_ref()
            .and_then(peer_key_from_peer)
            .map(|peer| match peer {
                PeerKey::Chat(id) => id,
                PeerKey::User(id) => id,
            });

        peer_id.is_some_and(|id| id.to_string().contains(needle))
    });

    apply_chat_list_limits(payload, None, None)
}

pub(crate) fn build_chat_list(
    result: proto::GetChatsResult,
    current_user: Option<&proto::User>,
    limit: Option<usize>,
    offset: Option<usize>,
    filter: Option<&str>,
) -> Result<ChatListOutput, Box<dyn std::error::Error>> {
    let now = current_epoch_seconds() as i64;
    let current_user_id = current_user.map(|user| user.id);

    let needle = filter
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.to_lowercase());

    let mut users_by_id: HashMap<i64, proto::User> = HashMap::new();
    for user in &result.users {
        users_by_id.insert(user.id, user.clone());
    }

    let mut spaces_by_id: HashMap<i64, proto::Space> = HashMap::new();
    for space in &result.spaces {
        spaces_by_id.insert(space.id, space.clone());
    }

    let mut messages_by_id: HashMap<MessageKey, proto::Message> = HashMap::new();
    for message in &result.messages {
        if let Some(peer) = message.peer_id.as_ref().and_then(peer_key_from_peer) {
            messages_by_id.insert(
                MessageKey {
                    peer,
                    id: message.id,
                },
                message.clone(),
            );
        } else if message.chat_id != 0 {
            messages_by_id.insert(
                MessageKey {
                    peer: PeerKey::Chat(message.chat_id),
                    id: message.id,
                },
                message.clone(),
            );
        }
    }

    let mut dialog_by_peer: HashMap<PeerKey, proto::Dialog> = HashMap::new();
    let mut dialog_by_chat_id: HashMap<i64, proto::Dialog> = HashMap::new();
    for dialog in &result.dialogs {
        if let Some(peer) = dialog.peer.as_ref() {
            if let Some(peer_key) = peer_key_from_peer(peer) {
                dialog_by_peer.insert(peer_key, dialog.clone());
            }
        }
        if let Some(chat_id) = dialog.chat_id {
            dialog_by_chat_id.insert(chat_id, dialog.clone());
        }
    }

    struct DraftItem {
        chat: proto::Chat,
        dialog: Option<proto::Dialog>,
        peer: PeerSummary,
        display_name: String,
        space: Option<SpaceSummary>,
        space_name: Option<String>,
        unread_count: Option<i32>,
        last_message: Option<proto::Message>,
        last_message_date: i64,
    }

    let mut drafts = Vec::with_capacity(result.chats.len());
    for chat in &result.chats {
        let peer_key = chat.peer_id.as_ref().and_then(peer_key_from_peer);
        let dialog = peer_key
            .as_ref()
            .and_then(|key| dialog_by_peer.get(key))
            .or_else(|| dialog_by_chat_id.get(&chat.id))
            .cloned();
        let unread_count = dialog.as_ref().and_then(|dialog| dialog.unread_count);

        let last_message = chat.last_msg_id.and_then(|id| {
            peer_key.as_ref().and_then(|peer_key| {
                messages_by_id
                    .get(&MessageKey {
                        peer: peer_key.clone(),
                        id,
                    })
                    .cloned()
            })
        });
        let last_message_date = last_message.as_ref().map(|msg| msg.date).unwrap_or(0);

        let display_name = chat_display_name(chat, &users_by_id);
        let space = chat
            .space_id
            .and_then(|space_id| spaces_by_id.get(&space_id))
            .map(space_summary);
        let space_name = space.as_ref().map(|space| space.display_name.clone());

        let peer = chat
            .peer_id
            .as_ref()
            .and_then(peer_summary_from_peer)
            .unwrap_or(PeerSummary {
                peer_type: "unknown".to_string(),
                id: chat.id,
            });

        if let Some(needle) = needle.as_deref() {
            let mut haystacks = Vec::with_capacity(5);
            haystacks.push(display_name.to_lowercase());
            if let Some(space_name) = space_name.as_deref() {
                haystacks.push(space_name.to_lowercase());
            }
            haystacks.push(chat.id.to_string());
            haystacks.push(peer.id.to_string());
            if !haystacks.iter().any(|value| value.contains(needle)) {
                continue;
            }
        }

        drafts.push(DraftItem {
            chat: chat.clone(),
            dialog,
            peer,
            display_name,
            space,
            space_name,
            unread_count,
            last_message,
            last_message_date,
        });
    }

    drafts.sort_by_key(|item| (Reverse(item.last_message_date), Reverse(item.chat.id)));

    let offset = offset.unwrap_or(0);
    let limit = limit.unwrap_or(drafts.len());
    let drafts = drafts.into_iter().skip(offset).take(limit);

    let mut items = Vec::new();
    for draft in drafts {
        let last_message_summary = draft
            .last_message
            .as_ref()
            .map(|message| message_summary(message, &users_by_id, current_user_id, now, None));
        let last_message_line = last_message_summary.as_ref().map(|summary| {
            if summary.preview.is_empty() {
                summary.sender_name.clone()
            } else {
                format!("{}: {}", summary.sender_name, summary.preview)
            }
        });
        let last_message_relative_date = last_message_summary
            .as_ref()
            .map(|summary| summary.relative_date.clone());

        items.push(ChatListItem {
            chat: draft.chat,
            dialog: draft.dialog,
            peer: draft.peer,
            display_name: draft.display_name,
            space: draft.space,
            space_name: draft.space_name,
            unread_count: draft.unread_count,
            last_message: last_message_summary,
            last_message_line,
            last_message_relative_date,
        });
    }

    Ok(ChatListOutput { items, raw: result })
}

pub(crate) fn chat_display_name(
    chat: &proto::Chat,
    users_by_id: &HashMap<i64, proto::User>,
) -> String {
    if let Some(peer) = chat.peer_id.as_ref() {
        if let Some(peer_user_id) = match &peer.r#type {
            Some(proto::peer::Type::User(user)) => Some(user.user_id),
            _ => None,
        } {
            if let Some(user) = users_by_id.get(&peer_user_id) {
                let mut name = user_display_name(user);
                if let Some(emoji) = chat.emoji.as_deref() {
                    if !emoji.trim().is_empty() {
                        name = format!("{} {}", emoji.trim(), name);
                    }
                }
                return name;
            }
        }
    }

    let title = chat.title.trim();
    if !title.is_empty() {
        if let Some(emoji) = chat.emoji.as_deref() {
            if !emoji.trim().is_empty() {
                return format!("{} {}", emoji.trim(), title);
            }
        }
        return title.to_string();
    }

    format!("Chat {}", chat.id)
}

fn peer_summary_from_peer(peer: &proto::Peer) -> Option<PeerSummary> {
    match &peer.r#type {
        Some(proto::peer::Type::Chat(chat)) => Some(PeerSummary {
            peer_type: "chat".to_string(),
            id: chat.chat_id,
        }),
        Some(proto::peer::Type::User(user)) => Some(PeerSummary {
            peer_type: "user".to_string(),
            id: user.user_id,
        }),
        None => None,
    }
}

fn current_epoch_seconds() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chat_json_filter_trims_denormalized_payload_by_title() {
        let launch_peer = proto::Peer {
            r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id: 10 })),
        };
        let random_peer = proto::Peer {
            r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id: 20 })),
        };

        let payload = proto::GetChatsResult {
            dialogs: vec![
                proto::Dialog {
                    peer: Some(launch_peer.clone()),
                    chat_id: Some(10),
                    ..Default::default()
                },
                proto::Dialog {
                    peer: Some(random_peer.clone()),
                    chat_id: Some(20),
                    ..Default::default()
                },
            ],
            chats: vec![
                proto::Chat {
                    id: 10,
                    title: "Launch Room".to_string(),
                    peer_id: Some(launch_peer.clone()),
                    space_id: Some(7),
                    ..Default::default()
                },
                proto::Chat {
                    id: 20,
                    title: "Random".to_string(),
                    peer_id: Some(random_peer.clone()),
                    space_id: Some(8),
                    ..Default::default()
                },
            ],
            spaces: vec![
                proto::Space {
                    id: 7,
                    name: "Product".to_string(),
                    ..Default::default()
                },
                proto::Space {
                    id: 8,
                    name: "Other".to_string(),
                    ..Default::default()
                },
            ],
            users: vec![
                proto::User {
                    id: 1,
                    first_name: Some("Mona".to_string()),
                    ..Default::default()
                },
                proto::User {
                    id: 2,
                    first_name: Some("Sam".to_string()),
                    ..Default::default()
                },
            ],
            messages: vec![
                proto::Message {
                    id: 1,
                    from_id: 1,
                    peer_id: Some(launch_peer),
                    chat_id: 10,
                    ..Default::default()
                },
                proto::Message {
                    id: 2,
                    from_id: 2,
                    peer_id: Some(random_peer),
                    chat_id: 20,
                    ..Default::default()
                },
            ],
        };

        let trimmed = apply_chat_list_filter(payload, Some("launch"));

        assert_eq!(
            trimmed.chats.iter().map(|chat| chat.id).collect::<Vec<_>>(),
            vec![10]
        );
        assert_eq!(
            trimmed
                .dialogs
                .iter()
                .filter_map(|dialog| dialog.chat_id)
                .collect::<Vec<_>>(),
            vec![10]
        );
        assert_eq!(
            trimmed
                .messages
                .iter()
                .map(|message| message.id)
                .collect::<Vec<_>>(),
            vec![1]
        );
        assert_eq!(
            trimmed
                .spaces
                .iter()
                .map(|space| space.id)
                .collect::<Vec<_>>(),
            vec![7]
        );
        assert_eq!(
            trimmed.users.iter().map(|user| user.id).collect::<Vec<_>>(),
            vec![1]
        );
    }

    #[test]
    fn chat_json_filter_trims_denormalized_payload_by_dm_user_name() {
        let dm_peer = proto::Peer {
            r#type: Some(proto::peer::Type::User(proto::PeerUser { user_id: 42 })),
        };
        let other_peer = proto::Peer {
            r#type: Some(proto::peer::Type::User(proto::PeerUser { user_id: 99 })),
        };

        let payload = proto::GetChatsResult {
            dialogs: vec![
                proto::Dialog {
                    peer: Some(dm_peer.clone()),
                    chat_id: None,
                    ..Default::default()
                },
                proto::Dialog {
                    peer: Some(other_peer.clone()),
                    chat_id: None,
                    ..Default::default()
                },
            ],
            chats: vec![
                proto::Chat {
                    id: 10,
                    peer_id: Some(dm_peer.clone()),
                    ..Default::default()
                },
                proto::Chat {
                    id: 20,
                    peer_id: Some(other_peer.clone()),
                    ..Default::default()
                },
            ],
            users: vec![
                proto::User {
                    id: 42,
                    first_name: Some("Sam".to_string()),
                    ..Default::default()
                },
                proto::User {
                    id: 99,
                    first_name: Some("Other".to_string()),
                    ..Default::default()
                },
            ],
            messages: vec![
                proto::Message {
                    id: 1,
                    from_id: 42,
                    peer_id: Some(dm_peer),
                    chat_id: 0,
                    ..Default::default()
                },
                proto::Message {
                    id: 2,
                    from_id: 99,
                    peer_id: Some(other_peer),
                    chat_id: 0,
                    ..Default::default()
                },
            ],
            ..Default::default()
        };

        let trimmed = apply_chat_list_filter(payload, Some("sam"));

        assert_eq!(
            trimmed.chats.iter().map(|chat| chat.id).collect::<Vec<_>>(),
            vec![10]
        );
        assert_eq!(trimmed.dialogs.len(), 1);
        assert_eq!(
            trimmed
                .messages
                .iter()
                .map(|message| message.id)
                .collect::<Vec<_>>(),
            vec![1]
        );
        assert_eq!(
            trimmed.users.iter().map(|user| user.id).collect::<Vec<_>>(),
            vec![42]
        );
    }

    #[test]
    fn chat_list_limit_trims_payload_but_keeps_dm_messages() {
        let user_peer = proto::Peer {
            r#type: Some(proto::peer::Type::User(proto::PeerUser { user_id: 42 })),
        };
        let chat_peer = proto::Peer {
            r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id: 20 })),
        };
        let payload = proto::GetChatsResult {
            chats: vec![
                proto::Chat {
                    id: 10,
                    peer_id: Some(user_peer.clone()),
                    ..Default::default()
                },
                proto::Chat {
                    id: 20,
                    peer_id: Some(chat_peer.clone()),
                    ..Default::default()
                },
            ],
            dialogs: vec![
                proto::Dialog {
                    peer: Some(user_peer.clone()),
                    ..Default::default()
                },
                proto::Dialog {
                    peer: Some(chat_peer.clone()),
                    chat_id: Some(20),
                    ..Default::default()
                },
            ],
            messages: vec![
                proto::Message {
                    id: 1,
                    peer_id: Some(user_peer),
                    from_id: 42,
                    ..Default::default()
                },
                proto::Message {
                    id: 2,
                    peer_id: Some(chat_peer),
                    chat_id: 20,
                    from_id: 7,
                    ..Default::default()
                },
            ],
            users: vec![
                proto::User {
                    id: 42,
                    first_name: Some("Sam".to_string()),
                    ..Default::default()
                },
                proto::User {
                    id: 7,
                    first_name: Some("Ava".to_string()),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };

        let trimmed = apply_chat_list_limits(payload, Some(1), Some(0));

        assert_eq!(
            trimmed.chats.iter().map(|chat| chat.id).collect::<Vec<_>>(),
            vec![10]
        );
        assert_eq!(trimmed.dialogs.len(), 1);
        assert_eq!(
            trimmed
                .messages
                .iter()
                .map(|message| message.id)
                .collect::<Vec<_>>(),
            vec![1]
        );
        assert_eq!(
            trimmed.users.iter().map(|user| user.id).collect::<Vec<_>>(),
            vec![42]
        );
    }
}
