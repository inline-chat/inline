use std::cmp::Reverse;
use std::collections::{HashMap, HashSet};

use crate::message_output::message_summary;
use crate::output::{
    ChatListItem, ChatListOutput, PeerSummary, SpaceSummary, space_summary, user_display_name,
};
use crate::peer::{MessageKey, PeerKey, peer_key_from_peer};
use inline_protocol::proto;

#[derive(Clone, Copy, Debug, clap::ValueEnum)]
pub(crate) enum ChatKind {
    Dm,
    Thread,
}

#[derive(Default, clap::Args)]
pub(crate) struct ChatListScope {
    #[arg(long, conflicts_with = "home", help = "Only chats in this space")]
    pub space_id: Option<i64>,
    #[arg(
        long,
        conflicts_with = "space_id",
        help = "Only chats outside spaces (DMs and Home threads)"
    )]
    pub home: bool,
    #[arg(long = "type", value_enum, help = "Only direct messages or threads")]
    pub kind: Option<ChatKind>,
    #[arg(long, help = "Only chats with unread messages or a manual unread mark")]
    pub unread: bool,
    #[arg(long, help = "Only pinned chats")]
    pub pinned: bool,
}

impl ChatListScope {
    pub(crate) fn validate(&self) -> Result<(), Box<dyn std::error::Error>> {
        crate::validation::validate_optional_positive_id_arg("--space-id", self.space_id)?;
        Ok(())
    }
}

pub(crate) fn apply_chat_list_scope(
    mut payload: proto::GetChatsResult,
    scope: &ChatListScope,
) -> proto::GetChatsResult {
    if scope.space_id.is_none()
        && !scope.home
        && scope.kind.is_none()
        && !scope.unread
        && !scope.pinned
    {
        return payload;
    }
    let by_chat: HashMap<_, _> = payload
        .dialogs
        .iter()
        .filter_map(|dialog| dialog.chat_id.map(|id| (id, dialog)))
        .collect();
    let by_peer: HashMap<_, _> = payload
        .dialogs
        .iter()
        .filter_map(|dialog| {
            dialog
                .peer
                .as_ref()
                .and_then(peer_key_from_peer)
                .map(|key| (key, dialog))
        })
        .collect();
    payload.chats.retain(|chat| {
        let peer = chat.peer_id.as_ref().and_then(peer_key_from_peer);
        let dialog = peer
            .as_ref()
            .and_then(|key| by_peer.get(key))
            .or_else(|| by_chat.get(&chat.id));
        let is_dm = matches!(peer, Some(PeerKey::User(_)));
        scope.space_id.is_none_or(|id| chat.space_id == Some(id))
            && (!scope.home || chat.space_id.is_none())
            && scope.kind.is_none_or(|kind| match kind {
                ChatKind::Dm => is_dm,
                ChatKind::Thread => !is_dm,
            })
            && (!scope.unread
                || dialog.is_some_and(|d| {
                    d.unread_count.unwrap_or(0) > 0 || d.unread_mark == Some(true)
                }))
            && (!scope.pinned || dialog.is_some_and(|d| d.pinned == Some(true)))
    });
    apply_chat_list_limits(payload, None, None)
}

/// Largest page the server serves.
const CHAT_PAGE_MAX: usize = 100;
/// Smallest page after the first, when local filters dropped some rows.
const MIN_FOLLOW_UP_PAGE: usize = 25;

/// A `chats list` the server can narrow and page instead of answering with the
/// whole catalog. Built only when it saves work: a server-side filter or a limit.
#[derive(Debug, PartialEq)]
pub(crate) struct PagedChatList {
    scope: proto::ChatListScope,
    filter: proto::ChatListFilter,
    /// Without `--include-subthreads` the full catalog shows linked subthreads
    /// only through a visible dialog; the accessible scope returns them all.
    hide_subthreads_without_dialog: bool,
    /// Chats to collect after local filters (offset + limit); `None` walks to the end.
    want: Option<usize>,
    /// The scope combination matches nothing (`--type dm --space-id`).
    empty: bool,
}

pub(crate) fn paged_chat_list(
    scope: &ChatListScope,
    include_subthreads: bool,
    limit: Option<usize>,
    offset: Option<usize>,
) -> Option<PagedChatList> {
    let narrowed = scope.space_id.is_some()
        || scope.home
        || scope.kind.is_some()
        || scope.unread
        || scope.pinned;
    let want = limit.map(|limit| limit.saturating_add(offset.unwrap_or(0)));
    // A plain full listing costs the same either way; keep the catalog's answer.
    if !narrowed && want.is_none() {
        return None;
    }

    let dms = !matches!(scope.kind, Some(ChatKind::Thread)) && scope.space_id.is_none();
    let home_threads = !matches!(scope.kind, Some(ChatKind::Dm)) && scope.space_id.is_none();
    let space_threads = !matches!(scope.kind, Some(ChatKind::Dm)) && !scope.home;
    let mut kinds = Vec::new();
    if !(dms && home_threads && space_threads) {
        if dms {
            kinds.push(proto::ChatListKind::Dm as i32);
        }
        if home_threads {
            kinds.push(proto::ChatListKind::HomeThread as i32);
        }
        if space_threads {
            kinds.push(proto::ChatListKind::SpaceThread as i32);
        }
    }
    let empty = !(dms || home_threads || space_threads);

    // Unread and pinned live on dialogs. Everything else reads the accessible
    // scope, which also covers space threads this user never opened (the full
    // catalog creates their dialogs on the fly).
    let dialogs_only = (scope.unread || scope.pinned) && !include_subthreads;
    Some(PagedChatList {
        scope: if dialogs_only {
            proto::ChatListScope::Dialogs
        } else {
            proto::ChatListScope::Accessible
        },
        filter: proto::ChatListFilter {
            kinds,
            space_ids: scope.space_id.into_iter().collect(),
            unread: scope.unread.then_some(true),
            pinned: scope.pinned.then_some(true),
            ..Default::default()
        },
        hide_subthreads_without_dialog: !include_subthreads && !dialogs_only,
        want,
        empty,
    })
}

/// One `GetChats` call.
pub(crate) trait ChatPageSource {
    async fn get_chats(
        &mut self,
        input: proto::GetChatsInput,
    ) -> Result<proto::GetChatsResult, Box<dyn std::error::Error>>;
}

/// Walks server pages until `want` chats survive the local filters, or the end.
pub(crate) async fn fetch_chat_pages(
    request: &PagedChatList,
    scope: &ChatListScope,
    text_filter: Option<&str>,
    source: &mut impl ChatPageSource,
) -> Result<proto::GetChatsResult, Box<dyn std::error::Error>> {
    let mut merged = proto::GetChatsResult::default();
    if request.empty || request.want == Some(0) {
        return Ok(merged);
    }
    let mut offset = None;
    loop {
        // Counting applies the local filters to a copy, so only a limited
        // listing pays for it; a full walk just follows next_offset.
        let kept = match request.want {
            Some(_) => count_listed_chats(&merged, request, scope, text_filter),
            None => 0,
        };
        let page_size = match request.want {
            Some(want) if kept >= want => break,
            // The first page asks for exactly what is wanted. Later pages exist
            // only because local filters (text, hidden subthreads) dropped rows,
            // so they ask for more rather than shrinking toward one chat each.
            Some(want) if merged.chats.is_empty() => (want - kept).clamp(1, CHAT_PAGE_MAX),
            Some(_) if text_filter.is_some_and(|text| !text.trim().is_empty()) => CHAT_PAGE_MAX,
            Some(want) => (want - kept).clamp(MIN_FOLLOW_UP_PAGE, CHAT_PAGE_MAX),
            None => CHAT_PAGE_MAX,
        };
        let page = source
            .get_chats(proto::GetChatsInput {
                limit: Some(page_size as i32),
                offset,
                order: proto::ChatListOrder::Recent as i32,
                filter: Some(request.filter.clone()),
                scope: request.scope as i32,
                ..Default::default()
            })
            .await?;
        offset = page.next_offset.clone();
        merge_chat_page(&mut merged, page);
        if offset.is_none() {
            break;
        }
    }
    merged.next_offset = None;
    if request.hide_subthreads_without_dialog {
        merged = hide_subthreads_without_dialog(merged);
    }
    Ok(merged)
}

fn count_listed_chats(
    merged: &proto::GetChatsResult,
    request: &PagedChatList,
    scope: &ChatListScope,
    text_filter: Option<&str>,
) -> usize {
    if merged.chats.is_empty() {
        return 0;
    }
    let mut payload = merged.clone();
    if request.hide_subthreads_without_dialog {
        payload = hide_subthreads_without_dialog(payload);
    }
    apply_chat_list_filter(apply_chat_list_scope(payload, scope), text_filter)
        .chats
        .len()
}

fn merge_chat_page(merged: &mut proto::GetChatsResult, page: proto::GetChatsResult) {
    let known_users: HashSet<i64> = merged.users.iter().map(|user| user.id).collect();
    let known_spaces: HashSet<i64> = merged.spaces.iter().map(|space| space.id).collect();
    merged.chats.extend(page.chats);
    merged.dialogs.extend(page.dialogs);
    merged.messages.extend(page.messages);
    merged.users.extend(
        page.users
            .into_iter()
            .filter(|user| !known_users.contains(&user.id)),
    );
    merged.spaces.extend(
        page.spaces
            .into_iter()
            .filter(|space| !known_spaces.contains(&space.id)),
    );
    if merged.folders.is_empty() {
        merged.folders = page.folders;
    }
}

/// Matches the full catalog without `--include-subthreads`: a linked subthread
/// is listed only through a dialog that is not hidden from chat lists.
fn hide_subthreads_without_dialog(mut payload: proto::GetChatsResult) -> proto::GetChatsResult {
    let visible: HashSet<i64> = payload
        .dialogs
        .iter()
        .filter(|dialog| dialog.chat_list_hidden != Some(true))
        .filter_map(|dialog| dialog.chat_id)
        .collect();
    payload
        .chats
        .retain(|chat| chat.parent_chat_id.is_none() || visible.contains(&chat.id));
    apply_chat_list_limits(payload, None, None)
}

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
        if dialog
            .chat_id
            .is_some_and(|chat_id| kept_chat_ids.contains(&chat_id))
        {
            return true;
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

        if chat
            .space_id
            .and_then(|space_id| spaces_by_id.get(&space_id))
            .is_some_and(|space| space.name.to_lowercase().contains(needle))
        {
            return true;
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

    let mut messages_by_id: HashMap<MessageKey, &proto::Message> = HashMap::new();
    for message in &result.messages {
        if let Some(peer) = message.peer_id.as_ref().and_then(peer_key_from_peer) {
            messages_by_id.insert(
                MessageKey {
                    peer,
                    id: message.id,
                },
                message,
            );
        } else if message.chat_id != 0 {
            messages_by_id.insert(
                MessageKey {
                    peer: PeerKey::Chat(message.chat_id),
                    id: message.id,
                },
                message,
            );
        }
    }

    let mut dialog_by_peer: HashMap<PeerKey, &proto::Dialog> = HashMap::new();
    let mut dialog_by_chat_id: HashMap<i64, &proto::Dialog> = HashMap::new();
    for dialog in &result.dialogs {
        if let Some(peer_key) = dialog.peer.as_ref().and_then(peer_key_from_peer) {
            dialog_by_peer.insert(peer_key, dialog);
        }
        if let Some(chat_id) = dialog.chat_id {
            dialog_by_chat_id.insert(chat_id, dialog);
        }
    }

    struct DraftItem<'a> {
        chat: &'a proto::Chat,
        dialog: Option<&'a proto::Dialog>,
        peer: PeerSummary,
        display_name: String,
        space: Option<SpaceSummary>,
        space_name: Option<String>,
        unread_count: Option<i32>,
        last_message: Option<&'a proto::Message>,
        last_message_date: i64,
    }

    let mut drafts = Vec::with_capacity(result.chats.len());
    for chat in &result.chats {
        let peer_key = chat.peer_id.as_ref().and_then(peer_key_from_peer);
        let dialog = peer_key
            .as_ref()
            .and_then(|key| dialog_by_peer.get(key))
            .or_else(|| dialog_by_chat_id.get(&chat.id))
            .copied();
        let unread_count = dialog.as_ref().and_then(|dialog| dialog.unread_count);

        let last_message = chat.last_msg_id.and_then(|id| {
            messages_by_id
                .get(&MessageKey {
                    peer: peer_key.clone().unwrap_or(PeerKey::Chat(chat.id)),
                    id,
                })
                .copied()
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
            chat,
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
            chat: draft.chat.clone(),
            dialog: draft.dialog.cloned(),
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
    let peer_user_id = chat.peer_id.as_ref().and_then(|peer| match &peer.r#type {
        Some(proto::peer::Type::User(user)) => Some(user.user_id),
        _ => None,
    });
    if let Some(user) = peer_user_id.and_then(|peer_user_id| users_by_id.get(&peer_user_id)) {
        let mut name = user_display_name(user);
        if let Some(emoji) = chat
            .emoji
            .as_deref()
            .map(str::trim)
            .filter(|emoji| !emoji.is_empty())
        {
            name = format!("{emoji} {name}");
        }
        return name;
    }

    let title = chat.title.trim();
    if !title.is_empty() {
        if let Some(emoji) = chat
            .emoji
            .as_deref()
            .map(str::trim)
            .filter(|emoji| !emoji.is_empty())
        {
            return format!("{emoji} {title}");
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
    use std::collections::VecDeque;

    fn scope_fixture() -> proto::GetChatsResult {
        let dm = proto::Peer {
            r#type: Some(proto::peer::Type::User(proto::PeerUser { user_id: 42 })),
        };
        let thread = proto::Peer {
            r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id: 42 })),
        };
        proto::GetChatsResult {
            chats: vec![
                proto::Chat {
                    id: 1,
                    peer_id: Some(dm.clone()),
                    ..Default::default()
                },
                proto::Chat {
                    id: 42,
                    peer_id: Some(thread.clone()),
                    space_id: Some(7),
                    ..Default::default()
                },
                proto::Chat {
                    id: 3,
                    ..Default::default()
                },
            ],
            dialogs: vec![
                proto::Dialog {
                    peer: Some(dm.clone()),
                    unread_mark: Some(true),
                    pinned: Some(true),
                    ..Default::default()
                },
                proto::Dialog {
                    peer: Some(thread.clone()),
                    unread_count: Some(2),
                    ..Default::default()
                },
                proto::Dialog {
                    chat_id: Some(3),
                    unread_count: Some(0),
                    ..Default::default()
                },
            ],
            messages: vec![
                proto::Message {
                    id: 1,
                    peer_id: Some(dm),
                    from_id: 42,
                    ..Default::default()
                },
                proto::Message {
                    id: 1,
                    peer_id: Some(thread),
                    from_id: 5,
                    ..Default::default()
                },
            ],
            users: vec![
                proto::User {
                    id: 42,
                    ..Default::default()
                },
                proto::User {
                    id: 5,
                    ..Default::default()
                },
            ],
            spaces: vec![proto::Space {
                id: 7,
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    #[test]
    fn unfiltered_json_catalog_preserves_unopened_subthreads() {
        let mut payload = scope_fixture();
        payload.chats.push(proto::Chat {
            id: 500,
            title: "Unopened child".into(),
            peer_id: Some(proto::Peer {
                r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id: 500 })),
            }),
            parent_chat_id: Some(42),
            parent_message_id: Some(7),
            ..Default::default()
        });
        // A child without a dialog must survive the same unfiltered JSON path
        // used by complete archive discovery.
        let scoped = apply_chat_list_scope(payload, &ChatListScope::default());
        let result = apply_chat_list_filter(scoped, None);
        assert!(result.chats.iter().any(|chat| chat.id == 500));
        assert!(
            !result
                .dialogs
                .iter()
                .any(|dialog| dialog.chat_id == Some(500))
        );
        let json = serde_json::to_value(&result).unwrap();
        let child = json["chats"]
            .as_array()
            .unwrap()
            .iter()
            .find(|chat| chat["id"] == 500)
            .unwrap();
        assert_eq!(child["parent_chat_id"], 42);
    }

    #[test]
    fn scope_filters_combine_before_pagination_without_colliding_peer_ids() {
        let filtered = apply_chat_list_scope(
            scope_fixture(),
            &ChatListScope {
                space_id: Some(7),
                kind: Some(ChatKind::Thread),
                unread: true,
                ..Default::default()
            },
        );
        let page = apply_chat_list_limits(filtered, Some(1), None);
        assert_eq!(page.chats.iter().map(|c| c.id).collect::<Vec<_>>(), [42]);
        assert_eq!(page.dialogs.len(), 1);
        assert_eq!(page.messages.len(), 1);
        assert_eq!(page.messages[0].from_id, 5);
        assert_eq!(page.users.len(), 1);
        assert_eq!(page.spaces.len(), 1);

        let pinned = apply_chat_list_scope(
            scope_fixture(),
            &ChatListScope {
                home: true,
                kind: Some(ChatKind::Dm),
                unread: true,
                pinned: true,
                ..Default::default()
            },
        );
        assert_eq!(pinned.chats[0].id, 1);
        assert_eq!(pinned.messages[0].from_id, 42);
        assert!(pinned.spaces.is_empty());
    }

    #[test]
    fn home_includes_unspaced_threads_and_default_scope_leaves_payload_unchanged() {
        let original = scope_fixture();
        let unfiltered = apply_chat_list_scope(original.clone(), &ChatListScope::default());
        assert_eq!(
            serde_json::to_value(original).unwrap(),
            serde_json::to_value(unfiltered).unwrap()
        );
        let home = apply_chat_list_scope(
            scope_fixture(),
            &ChatListScope {
                home: true,
                ..Default::default()
            },
        );
        assert_eq!(home.chats.iter().map(|c| c.id).collect::<Vec<_>>(), [1, 3]);
        let threads = apply_chat_list_scope(
            scope_fixture(),
            &ChatListScope {
                home: true,
                kind: Some(ChatKind::Thread),
                ..Default::default()
            },
        );
        assert_eq!(threads.chats[0].id, 3);
        assert_eq!(threads.dialogs[0].chat_id, Some(3));
    }

    #[test]
    fn projection_finds_last_message_without_peer_metadata() {
        let payload = proto::GetChatsResult {
            chats: vec![proto::Chat {
                id: 7,
                last_msg_id: Some(2),
                ..Default::default()
            }],
            messages: vec![proto::Message {
                id: 2,
                chat_id: 7,
                date: 10,
                message: Some("hello".into()),
                ..Default::default()
            }],
            ..Default::default()
        };
        let output = build_chat_list(payload, None, None, None, None).unwrap();
        assert_eq!(output.items[0].last_message.as_ref().unwrap().message.id, 2);
    }

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
            ..Default::default()
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

    fn peer_chat(chat_id: i64) -> proto::Peer {
        proto::Peer {
            r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id })),
        }
    }

    fn page_chat(id: i64, parent_chat_id: Option<i64>) -> proto::Chat {
        proto::Chat {
            id,
            peer_id: Some(peer_chat(id)),
            space_id: Some(7),
            parent_chat_id,
            ..Default::default()
        }
    }

    fn page_dialog(chat_id: i64, hidden: bool) -> proto::Dialog {
        proto::Dialog {
            peer: Some(peer_chat(chat_id)),
            chat_id: Some(chat_id),
            chat_list_hidden: hidden.then_some(true),
            ..Default::default()
        }
    }

    /// Serves fixed pages in order and records every request.
    struct FakePages {
        pages: VecDeque<proto::GetChatsResult>,
        requests: Vec<proto::GetChatsInput>,
    }

    impl ChatPageSource for FakePages {
        async fn get_chats(
            &mut self,
            input: proto::GetChatsInput,
        ) -> Result<proto::GetChatsResult, Box<dyn std::error::Error>> {
            self.requests.push(input);
            Ok(self.pages.pop_front().unwrap_or_default())
        }
    }

    fn next(chat_id: i64) -> Option<proto::ChatListOffset> {
        Some(proto::ChatListOffset {
            chat_id,
            date: Some(1),
        })
    }

    #[test]
    fn plain_full_listing_keeps_the_catalog() {
        assert_eq!(
            paged_chat_list(&ChatListScope::default(), false, None, None),
            None
        );
    }

    #[test]
    fn scope_flags_become_server_filters() {
        let unread = ChatListScope {
            unread: true,
            ..Default::default()
        };
        let request = paged_chat_list(&unread, false, None, None).unwrap();
        assert_eq!(request.scope, proto::ChatListScope::Dialogs);
        assert_eq!(request.filter.unread, Some(true));
        assert!(request.filter.kinds.is_empty());
        assert!(!request.hide_subthreads_without_dialog);

        let home_dms = ChatListScope {
            home: true,
            kind: Some(ChatKind::Dm),
            ..Default::default()
        };
        let request = paged_chat_list(&home_dms, false, Some(5), Some(2)).unwrap();
        assert_eq!(request.scope, proto::ChatListScope::Accessible);
        assert_eq!(request.filter.kinds, vec![proto::ChatListKind::Dm as i32]);
        assert_eq!(request.want, Some(7));
        assert!(request.hide_subthreads_without_dialog);

        let space = ChatListScope {
            space_id: Some(9),
            ..Default::default()
        };
        let request = paged_chat_list(&space, true, None, None).unwrap();
        assert_eq!(
            request.filter.kinds,
            vec![proto::ChatListKind::SpaceThread as i32]
        );
        assert_eq!(request.filter.space_ids, vec![9]);
        assert!(!request.hide_subthreads_without_dialog);

        let impossible = ChatListScope {
            space_id: Some(9),
            kind: Some(ChatKind::Dm),
            ..Default::default()
        };
        assert!(
            paged_chat_list(&impossible, false, None, None)
                .unwrap()
                .empty
        );
    }

    #[tokio::test]
    async fn a_limit_stops_after_enough_chats_without_shrinking_follow_up_pages() {
        let scope = ChatListScope::default();
        let request = paged_chat_list(&scope, false, Some(3), None).unwrap();
        let mut source = FakePages {
            pages: VecDeque::from([
                proto::GetChatsResult {
                    // 2 is a linked subthread without a dialog: the catalog hides it.
                    chats: vec![
                        page_chat(1, None),
                        page_chat(2, Some(1)),
                        page_chat(3, None),
                    ],
                    dialogs: vec![page_dialog(1, false), page_dialog(3, false)],
                    next_offset: next(3),
                    ..Default::default()
                },
                proto::GetChatsResult {
                    chats: vec![page_chat(4, Some(1))],
                    dialogs: vec![page_dialog(4, false)],
                    next_offset: next(4),
                    ..Default::default()
                },
                proto::GetChatsResult {
                    chats: vec![page_chat(5, None)],
                    ..Default::default()
                },
            ]),
            requests: Vec::new(),
        };
        let merged = fetch_chat_pages(&request, &scope, None, &mut source)
            .await
            .unwrap();

        let ids: Vec<i64> = merged.chats.iter().map(|chat| chat.id).collect();
        assert_eq!(ids, vec![1, 3, 4]);
        assert_eq!(merged.next_offset, None);
        let sizes: Vec<_> = source.requests.iter().map(|input| input.limit).collect();
        assert_eq!(sizes, vec![Some(3), Some(25)]);
        assert_eq!(source.requests[1].offset, next(3));
        assert!(
            source
                .requests
                .iter()
                .all(|input| input.include_subthreads.is_none())
        );
    }

    #[tokio::test]
    async fn walks_every_page_without_a_limit_and_drops_hidden_subthreads() {
        let scope = ChatListScope {
            space_id: Some(7),
            ..Default::default()
        };
        let request = paged_chat_list(&scope, false, None, None).unwrap();
        let mut source = FakePages {
            pages: VecDeque::from([
                proto::GetChatsResult {
                    chats: vec![page_chat(1, None), page_chat(2, Some(1))],
                    dialogs: vec![page_dialog(2, true)],
                    next_offset: next(2),
                    ..Default::default()
                },
                proto::GetChatsResult {
                    chats: vec![page_chat(3, None)],
                    ..Default::default()
                },
            ]),
            requests: Vec::new(),
        };
        let merged = fetch_chat_pages(&request, &scope, None, &mut source)
            .await
            .unwrap();
        let ids: Vec<i64> = merged.chats.iter().map(|chat| chat.id).collect();
        assert_eq!(ids, vec![1, 3]);
        assert!(merged.dialogs.is_empty());
        assert_eq!(source.requests.len(), 2);
        assert!(source.requests.iter().all(|input| input.limit == Some(100)));
    }
}
