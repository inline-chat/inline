//! `inline sidebar`: read and arrange the user's personal sidebar.
//!
//! The sidebar has three kinds of lanes, all ordered by ascending fractional
//! keys (the server's `FractionalIndex` alphabet):
//! - Pinned: pinned dialogs (`pinned_order`) and pinned folders (`pinned_order`).
//! - Root: open, unpinned, folderless dialogs and unpinned folders (`order`).
//!   A folder occupies the interval from its own `order` to its last child.
//! - Folder: a folder's children (`order`), kept between the folder's `order`
//!   and the next root position.

use std::collections::HashMap;

use clap::{ArgGroup, Args, Subcommand, ValueEnum};
use inline_protocol::proto;
use serde::Serialize;

use crate::auth::AuthStore;
use crate::chat_output::build_chat_list;
use crate::config::Config;
use crate::errors::CliError;
use crate::output::{self, ChatListItem, JsonFormat};

type Error = Box<dyn std::error::Error>;

/// macOS manual cleanup: opened at least 6h ago and quiet for at least 3h.
const CLEANUP_OPENED_AGE_SECONDS: i64 = 6 * 60 * 60;
const CLEANUP_ACTIVITY_AGE_SECONDS: i64 = 3 * 60 * 60;

#[derive(Subcommand)]
pub(crate) enum SidebarCommand {
    #[command(
        about = "Show the sidebar: pinned items, open chats, and folders (default)",
        visible_alias = "ls"
    )]
    List,
    #[command(about = "Open chats or DMs in the sidebar")]
    Open(SidebarOpenArgs),
    #[command(
        about = "Close chats or DMs from the sidebar (they stay accessible)",
        after_help = "--all closes every open chat outside the pinned section, including chats in unpinned folders.\nClosing an empty untitled thread deletes it."
    )]
    Close(PeersOrAllArgs),
    #[command(
        about = "Move one or more chats to a new sidebar position",
        after_help = "The target decides the section: next to a pinned item pins the chats, next to a folder child moves them into that folder, next to a root item moves them to the root. Several chats land together in the order given (-c values first, then -u values).\n\nExamples:\n  inline sidebar move -c 12 --top\n  inline sidebar move -c 12,13,14 --after 34\n  inline sidebar move -c 12 --before-folder 5\n  inline sidebar move -c 12 --bottom --folder 5\n  inline sidebar move -u 42 --top --pinned"
    )]
    Move(SidebarMoveArgs),
    #[command(
        about = "Sort a sidebar section by title or recent activity",
        after_help = "Sorts the root section by default; use --pinned or --folder ID for other sections. Folders sort as single items and keep their chats.\n\nExamples:\n  inline sidebar sort --by activity\n  inline sidebar sort --by title --pinned\n  inline sidebar sort --by title --folder 5 --reverse"
    )]
    Sort(SidebarSortArgs),
    #[command(about = "Pin chats or DMs")]
    Pin(SidebarPinArgs),
    #[command(about = "Unpin chats or DMs (--all unpins every pinned chat)")]
    Unpin(PeersOrAllArgs),
    #[command(about = "Archive chats or DMs")]
    Archive(PeersArgs),
    #[command(about = "Unarchive chats or DMs")]
    Unarchive(PeersArgs),
    #[command(
        about = "Mark chats or DMs as read (--all marks every sidebar chat)",
        visible_alias = "read"
    )]
    MarkRead(PeersOrAllArgs),
    #[command(
        about = "Close inactive chats and delete empty folders, like the macOS Cleanup action",
        after_help = "Closes open, unpinned, read chats that were opened at least 6 hours ago and have had no activity for 3 hours, plus empty untitled threads. Chats in pinned folders are kept. Then deletes folders left without open chats (their chats are kept).\nThe CLI cannot see drafts saved only in an app, so preview with --dry-run when that matters."
    )]
    Cleanup(SidebarCleanupArgs),
    #[command(about = "Create, edit, arrange, and delete sidebar folders")]
    Folder {
        #[command(subcommand)]
        command: SidebarFolderCommand,
    },
}

#[derive(Subcommand)]
pub(crate) enum SidebarFolderCommand {
    #[command(about = "Create a folder, optionally with chats")]
    Create(FolderCreateArgs),
    #[command(
        about = "Rename a folder or change its emoji",
        visible_alias = "rename"
    )]
    Update(FolderUpdateArgs),
    #[command(about = "Move chats into a folder")]
    Add(FolderAddArgs),
    #[command(about = "Move chats out of their folder to the root, right after the folder")]
    Remove(PeersArgs),
    #[command(about = "Move a folder to a new sidebar position")]
    Move(FolderMoveArgs),
    #[command(about = "Pin a folder")]
    Pin(FolderPinArgs),
    #[command(about = "Unpin a folder")]
    Unpin(FolderIdArgs),
    #[command(about = "Delete a folder, keeping or closing its chats")]
    Delete(FolderDeleteArgs),
}

#[derive(Args, Clone, Default)]
#[command(group(ArgGroup::new("peers").required(true).multiple(true).args(["chat_ids", "user_ids"])))]
pub(crate) struct PeersArgs {
    #[arg(
        long = "chat-id",
        short = 'c',
        value_name = "CHAT_ID",
        value_delimiter = ',',
        help = "Chat id (repeat or comma-separate for several)"
    )]
    chat_ids: Vec<i64>,

    #[arg(
        long = "user-id",
        short = 'u',
        value_name = "USER_ID",
        value_delimiter = ',',
        help = "DM counterpart user id (repeat or comma-separate for several)"
    )]
    user_ids: Vec<i64>,
}

#[derive(Args, Clone)]
#[command(group(ArgGroup::new("peers").required(true).multiple(true).args(["chat_ids", "user_ids", "all"])))]
pub(crate) struct PeersOrAllArgs {
    #[arg(
        long = "chat-id",
        short = 'c',
        value_name = "CHAT_ID",
        value_delimiter = ',',
        help = "Chat id (repeat or comma-separate for several)"
    )]
    chat_ids: Vec<i64>,

    #[arg(
        long = "user-id",
        short = 'u',
        value_name = "USER_ID",
        value_delimiter = ',',
        help = "DM counterpart user id (repeat or comma-separate for several)"
    )]
    user_ids: Vec<i64>,

    #[arg(long, conflicts_with_all = ["chat_ids", "user_ids"], help = "Apply to every matching sidebar chat")]
    all: bool,
}

impl PeersOrAllArgs {
    fn peers(&self) -> Option<PeersArgs> {
        (!self.all).then(|| PeersArgs {
            chat_ids: self.chat_ids.clone(),
            user_ids: self.user_ids.clone(),
        })
    }
}

#[derive(Args)]
pub(crate) struct SidebarOpenArgs {
    #[command(flatten)]
    peers: PeersArgs,

    #[arg(long, help = "Open at the top of the sidebar instead of the bottom")]
    top: bool,

    #[arg(
        long,
        value_name = "FOLDER_ID",
        conflicts_with = "top",
        help = "Open inside this folder"
    )]
    folder: Option<i64>,
}

#[derive(Args)]
pub(crate) struct SidebarPinArgs {
    #[command(flatten)]
    peers: PeersArgs,

    #[arg(
        long,
        help = "Pin at the top of the pinned items instead of the bottom"
    )]
    top: bool,
}

#[derive(Args, Clone)]
#[command(group(ArgGroup::new("lane").args(["pinned", "root", "folder"])))]
pub(crate) struct LaneArgs {
    #[arg(long, help = "Use the pinned section")]
    pinned: bool,

    #[arg(long, help = "Use the root section")]
    root: bool,

    #[arg(long, value_name = "FOLDER_ID", help = "Use this folder")]
    folder: Option<i64>,
}

impl LaneArgs {
    fn lane(&self) -> Option<Lane> {
        if self.pinned {
            Some(Lane::Pinned)
        } else if self.root {
            Some(Lane::Root)
        } else {
            self.folder.map(Lane::Folder)
        }
    }
}

#[derive(Args, Clone)]
#[command(group(
    ArgGroup::new("placement")
        .required(true)
        .args(["top", "bottom", "before", "after", "before_folder", "after_folder"])
))]
pub(crate) struct PlacementArgs {
    #[arg(long, help = "Move to the top of the section")]
    top: bool,

    #[arg(long, help = "Move to the bottom of the section")]
    bottom: bool,

    #[arg(long, value_name = "CHAT_ID", help = "Place right before this chat")]
    before: Option<i64>,

    #[arg(long, value_name = "CHAT_ID", help = "Place right after this chat")]
    after: Option<i64>,

    #[arg(
        long,
        value_name = "FOLDER_ID",
        help = "Place right before this folder"
    )]
    before_folder: Option<i64>,

    #[arg(long, value_name = "FOLDER_ID", help = "Place right after this folder")]
    after_folder: Option<i64>,
}

#[derive(Args)]
pub(crate) struct SidebarMoveArgs {
    #[command(flatten)]
    peers: PeersArgs,

    #[command(flatten)]
    placement: PlacementArgs,

    #[command(flatten)]
    lane: LaneArgs,
}

#[derive(Clone, Copy, ValueEnum)]
pub(crate) enum SortKey {
    /// Alphabetical by chat or folder title
    Title,
    /// Most recent message first
    Activity,
}

#[derive(Args)]
pub(crate) struct SidebarSortArgs {
    #[arg(long, value_enum, help = "Sort key")]
    by: SortKey,

    #[arg(long, help = "Reverse the order")]
    reverse: bool,

    #[command(flatten)]
    lane: LaneArgs,
}

#[derive(Args)]
pub(crate) struct SidebarCleanupArgs {
    #[arg(
        long,
        help = "Show what would be closed or deleted without changing anything"
    )]
    dry_run: bool,

    #[arg(long, help = "Do not delete folders left without open chats")]
    keep_folders: bool,
}

#[derive(Args)]
pub(crate) struct FolderCreateArgs {
    #[arg(long, short = 't', help = "Folder title (omit to let Inline name it)")]
    title: Option<String>,

    #[arg(
        long = "chat-id",
        short = 'c',
        value_name = "CHAT_ID",
        value_delimiter = ',',
        help = "Chat to put in the folder (repeat or comma-separate)"
    )]
    chat_ids: Vec<i64>,

    #[arg(
        long = "user-id",
        short = 'u',
        value_name = "USER_ID",
        value_delimiter = ',',
        help = "DM to put in the folder (repeat or comma-separate)"
    )]
    user_ids: Vec<i64>,

    #[arg(long, help = "Pin the new folder")]
    pin: bool,
}

#[derive(Args)]
pub(crate) struct FolderIdArgs {
    #[arg(value_name = "FOLDER_ID", help = "Folder id")]
    folder_id: i64,
}

#[derive(Args)]
#[command(group(
    ArgGroup::new("change")
        .required(true)
        .multiple(true)
        .args(["title", "clear_title", "emoji", "clear_emoji"])
))]
pub(crate) struct FolderUpdateArgs {
    #[arg(value_name = "FOLDER_ID", help = "Folder id")]
    folder_id: i64,

    #[arg(long, short = 't', conflicts_with = "clear_title", help = "New title")]
    title: Option<String>,

    #[arg(long, help = "Remove the title")]
    clear_title: bool,

    #[arg(long, conflicts_with = "clear_emoji", help = "New emoji")]
    emoji: Option<String>,

    #[arg(long, help = "Remove the emoji")]
    clear_emoji: bool,
}

#[derive(Args)]
pub(crate) struct FolderAddArgs {
    #[arg(value_name = "FOLDER_ID", help = "Folder id")]
    folder_id: i64,

    #[command(flatten)]
    peers: PeersArgs,
}

#[derive(Args)]
pub(crate) struct FolderMoveArgs {
    #[arg(value_name = "FOLDER_ID", help = "Folder id")]
    folder_id: i64,

    #[command(flatten)]
    placement: PlacementArgs,
}

#[derive(Args)]
pub(crate) struct FolderPinArgs {
    #[arg(value_name = "FOLDER_ID", help = "Folder id")]
    folder_id: i64,

    #[arg(
        long,
        help = "Pin at the top of the pinned items instead of the bottom"
    )]
    top: bool,
}

#[derive(Args)]
#[command(group(ArgGroup::new("disposition").required(true).args(["keep_chats", "close_chats"])))]
pub(crate) struct FolderDeleteArgs {
    #[arg(value_name = "FOLDER_ID", help = "Folder id")]
    folder_id: i64,

    #[arg(long, help = "Move the folder's chats back to the root")]
    keep_chats: bool,

    #[arg(long, help = "Close the folder's chats")]
    close_chats: bool,
}

// MARK: - Fractional index (mirrors server/src/modules/fractionalIndex.ts)

const ALPHABET: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

fn digit(value: u8) -> Option<usize> {
    ALPHABET.iter().position(|candidate| *candidate == value)
}

/// A key strictly between `left` and `right` (either side may be open).
pub(crate) fn fractional_between(
    left: Option<&str>,
    right: Option<&str>,
) -> Result<String, CliError> {
    if let (Some(left), Some(right)) = (left, right)
        && left >= right
    {
        return Err(CliError::invalid_args(
            "The sidebar has conflicting positions here; reorder it in the app first",
        ));
    }
    let max = ALPHABET.len() - 1;
    let digit_at =
        |value: Option<&str>, position: usize, fallback: usize| -> Result<usize, CliError> {
            match value.and_then(|value| value.as_bytes().get(position)) {
                None => Ok(fallback),
                Some(byte) => digit(*byte).ok_or_else(|| {
                    CliError::invalid_args("The server returned an invalid sidebar position")
                }),
            }
        };
    let mut prefix = String::new();
    let mut position = 0;
    loop {
        let low = digit_at(left, position, 0)?;
        let high = digit_at(right, position, max)?;
        if high - low > 1 {
            prefix.push(ALPHABET[(low + high) / 2] as char);
            return Ok(prefix);
        }
        prefix.push(ALPHABET[low] as char);
        position += 1;
        if prefix.len() > 120 {
            return Err(CliError::invalid_args(
                "Sidebar positions are too dense here; reorder it in the app first",
            ));
        }
    }
}

/// `count` ascending keys strictly between `left` and `right`, split by
/// midpoints so key length grows logarithmically with `count`.
pub(crate) fn fractional_keys(
    left: Option<&str>,
    right: Option<&str>,
    count: usize,
) -> Result<Vec<String>, CliError> {
    if count == 0 {
        return Ok(Vec::new());
    }
    let middle = fractional_between(left, right)?;
    let lower = (count - 1) / 2;
    let mut keys = fractional_keys(left, Some(&middle), lower)?;
    keys.push(middle.clone());
    keys.extend(fractional_keys(Some(&middle), right, count - 1 - lower)?);
    Ok(keys)
}

// MARK: - Sidebar model

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SidebarChat {
    chat_id: i64,
    peer_type: String,
    peer_id: i64,
    title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    space_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    unread_count: Option<i32>,
    unread: bool,
    open: bool,
    pinned: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    folder_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    order: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pinned_order: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    opened_date: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    last_activity: Option<i64>,
    #[serde(skip)]
    has_unknown_last_message: bool,
    #[serde(skip)]
    empty_untitled: bool,
}

impl SidebarChat {
    fn input_peer(&self) -> Result<proto::InputPeer, Error> {
        if self.peer_type == "user" {
            crate::peer::input_peer_from_args(None, Some(self.peer_id))
        } else {
            crate::peer::input_peer_from_args(Some(self.chat_id), None)
        }
    }

    fn target(&self) -> Result<PeerTarget, Error> {
        let peer = self.input_peer()?;
        Ok(PeerTarget {
            label: format!(
                "{} ({})",
                crate::peer_label_from_input(&peer),
                output::terminal_text(&self.title)
            ),
            peer,
        })
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SidebarFolder {
    folder_id: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    emoji: Option<String>,
    pinned: bool,
    order: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pinned_order: Option<String>,
    chats: Vec<SidebarChat>,
}

impl SidebarFolder {
    fn display_title(&self) -> String {
        self.title
            .as_deref()
            .filter(|title| !title.trim().is_empty())
            .map(|title| output::terminal_text(title).into_owned())
            .unwrap_or_else(|| "Untitled folder".to_string())
    }
}

#[derive(Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub(crate) enum SidebarEntry {
    Chat(SidebarChat),
    Folder(SidebarFolder),
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Sidebar {
    pinned: Vec<SidebarEntry>,
    items: Vec<SidebarEntry>,
    /// Dialogs known to the snapshot, including closed ones, for state lookups.
    #[serde(skip)]
    dialogs: Vec<SidebarChat>,
}

fn key_cmp(lhs: Option<&str>, rhs: Option<&str>) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    match (lhs, rhs) {
        (Some(lhs), Some(rhs)) => lhs.cmp(rhs),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
}

impl SidebarEntry {
    fn lane_key(&self, pinned_lane: bool) -> Option<&str> {
        match (self, pinned_lane) {
            (Self::Chat(chat), true) => chat.pinned_order.as_deref(),
            (Self::Chat(chat), false) => chat.order.as_deref(),
            (Self::Folder(folder), true) => folder.pinned_order.as_deref(),
            (Self::Folder(folder), false) => Some(folder.order.as_str()),
        }
    }

    /// The last coordinate this entry occupies in the root lane.
    fn lane_end(&self, pinned_lane: bool) -> Option<&str> {
        match self {
            Self::Folder(folder) if !pinned_lane => folder
                .chats
                .iter()
                .filter_map(|chat| chat.order.as_deref())
                .chain(std::iter::once(folder.order.as_str()))
                .max(),
            _ => self.lane_key(pinned_lane),
        }
    }

    fn matches(&self, item: Moving) -> bool {
        match (self, item) {
            (Self::Chat(chat), Moving::Chat(id)) => chat.chat_id == id,
            (Self::Folder(folder), Moving::Folder(id)) => folder.folder_id == id,
            _ => false,
        }
    }

    fn title_key(&self) -> String {
        match self {
            Self::Chat(chat) => chat.title.to_lowercase(),
            Self::Folder(folder) => folder.display_title().to_lowercase(),
        }
    }

    fn activity(&self) -> i64 {
        match self {
            Self::Chat(chat) => chat.last_activity.unwrap_or(0),
            Self::Folder(folder) => folder
                .chats
                .iter()
                .filter_map(|chat| chat.last_activity)
                .max()
                .unwrap_or(0),
        }
    }

    fn describe(&self) -> String {
        match self {
            Self::Chat(chat) => format!(
                "chat {} ({})",
                chat.chat_id,
                output::terminal_text(&chat.title)
            ),
            Self::Folder(folder) => {
                format!("folder {} ({})", folder.folder_id, folder.display_title())
            }
        }
    }

    fn chats(&self) -> Vec<&SidebarChat> {
        match self {
            Self::Chat(chat) => vec![chat],
            Self::Folder(folder) => folder.chats.iter().collect(),
        }
    }
}

impl Sidebar {
    pub(crate) fn build(
        payload: proto::GetChatsResult,
        current_user: Option<&proto::User>,
    ) -> Result<Self, Error> {
        let folders = payload.folders.clone();
        let list = build_chat_list(payload, current_user, None, None, None)?;
        let dialogs: Vec<SidebarChat> = list.items.iter().filter_map(sidebar_chat).collect();
        let active_dialog_ids: Vec<i64> = list
            .items
            .iter()
            .filter(|item| {
                item.dialog.as_ref().is_some_and(|dialog| {
                    dialog.archived != Some(true)
                        && (dialog.open == Some(true) || dialog.pinned == Some(true))
                })
            })
            .map(|item| item.chat.id)
            .collect();

        let mut folder_entries: HashMap<i64, SidebarFolder> = folders
            .iter()
            .map(|folder| {
                (
                    folder.id,
                    SidebarFolder {
                        folder_id: folder.id,
                        title: folder.title.clone(),
                        emoji: folder.emoji.clone(),
                        pinned: folder.pinned_order.is_some(),
                        order: folder.order.clone(),
                        pinned_order: folder.pinned_order.clone(),
                        chats: Vec::new(),
                    },
                )
            })
            .collect();

        let mut pinned = Vec::new();
        let mut items = Vec::new();
        for chat in dialogs
            .iter()
            .filter(|chat| active_dialog_ids.contains(&chat.chat_id))
        {
            if let Some(folder) = chat.folder_id.and_then(|id| folder_entries.get_mut(&id)) {
                folder.chats.push(chat.clone());
            } else if chat.pinned {
                pinned.push(SidebarEntry::Chat(chat.clone()));
            } else {
                items.push(SidebarEntry::Chat(chat.clone()));
            }
        }
        for mut folder in folder_entries.into_values() {
            folder.chats.sort_by(|lhs, rhs| {
                key_cmp(lhs.order.as_deref(), rhs.order.as_deref())
                    .then(lhs.chat_id.cmp(&rhs.chat_id))
            });
            if folder.pinned {
                pinned.push(SidebarEntry::Folder(folder));
            } else {
                items.push(SidebarEntry::Folder(folder));
            }
        }
        let stable = |entry: &SidebarEntry| match entry {
            SidebarEntry::Chat(chat) => (0, chat.chat_id),
            SidebarEntry::Folder(folder) => (1, folder.folder_id),
        };
        pinned.sort_by(|lhs, rhs| {
            key_cmp(lhs.lane_key(true), rhs.lane_key(true)).then(stable(lhs).cmp(&stable(rhs)))
        });
        items.sort_by(|lhs, rhs| {
            key_cmp(lhs.lane_key(false), rhs.lane_key(false)).then(stable(lhs).cmp(&stable(rhs)))
        });
        Ok(Self {
            pinned,
            items,
            dialogs,
        })
    }

    fn all_chats(&self) -> Vec<&SidebarChat> {
        self.pinned
            .iter()
            .chain(&self.items)
            .flat_map(SidebarEntry::chats)
            .collect()
    }

    fn folder(&self, folder_id: i64) -> Option<&SidebarFolder> {
        self.pinned
            .iter()
            .chain(&self.items)
            .find_map(|entry| match entry {
                SidebarEntry::Folder(folder) if folder.folder_id == folder_id => Some(folder),
                _ => None,
            })
    }

    fn require_folder(&self, folder_id: i64) -> Result<&SidebarFolder, CliError> {
        self.folder(folder_id)
            .ok_or_else(|| CliError::invalid_args(format!("Folder {folder_id} was not found")))
    }

    fn dialog(&self, peer: &proto::InputPeer) -> Option<&SidebarChat> {
        self.dialogs.iter().find(|chat| match &peer.r#type {
            Some(proto::input_peer::Type::Chat(input)) => chat.chat_id == input.chat_id,
            Some(proto::input_peer::Type::User(input)) => {
                chat.peer_type == "user" && chat.peer_id == input.user_id
            }
            _ => false,
        })
    }

    fn location(&self, item: Moving) -> Option<Lane> {
        if self.pinned.iter().any(|entry| entry.matches(item)) {
            return Some(Lane::Pinned);
        }
        if self.items.iter().any(|entry| entry.matches(item)) {
            return Some(Lane::Root);
        }
        let Moving::Chat(chat_id) = item else {
            return None;
        };
        self.pinned
            .iter()
            .chain(&self.items)
            .find_map(|entry| match entry {
                SidebarEntry::Folder(folder)
                    if folder.chats.iter().any(|chat| chat.chat_id == chat_id) =>
                {
                    Some(Lane::Folder(folder.folder_id))
                }
                _ => None,
            })
    }

    /// Entries of a lane in display order plus the lane's outer bounds.
    fn lane(
        &self,
        lane: Lane,
    ) -> Result<(Vec<SidebarEntry>, Option<String>, Option<String>), CliError> {
        match lane {
            Lane::Pinned => Ok((self.pinned.clone(), None, None)),
            Lane::Root => Ok((self.items.clone(), None, None)),
            Lane::Folder(folder_id) => {
                let folder = self.require_folder(folder_id)?;
                // Children always live in the folder's root interval, even
                // when the folder itself is pinned (matches the server).
                let entries = folder
                    .chats
                    .iter()
                    .cloned()
                    .map(SidebarEntry::Chat)
                    .collect();
                let upper = self
                    .items
                    .iter()
                    .filter(|entry| !entry.matches(Moving::Folder(folder_id)))
                    .filter_map(|entry| entry.lane_key(false))
                    .filter(|key| *key > folder.order.as_str())
                    .min()
                    .map(str::to_string);
                Ok((entries, Some(folder.order.clone()), upper))
            }
        }
    }

    /// Computes the lane and one key per moving item, in order, for a placement.
    fn placement(
        &self,
        moving: &[Moving],
        placement: &Placement,
    ) -> Result<(Lane, Vec<String>), CliError> {
        let current = moving.first().and_then(|item| self.location(*item));
        let lane = match placement {
            Placement::Top(lane) | Placement::Bottom(lane) => {
                lane.or(current).unwrap_or(Lane::Root)
            }
            Placement::Before(target) | Placement::After(target) => {
                if moving.contains(target) {
                    return Err(CliError::invalid_args(
                        "Chats cannot be placed relative to themselves",
                    ));
                }
                self.location(*target).ok_or_else(|| match target {
                    Moving::Chat(id) => CliError::invalid_args(format!(
                        "Chat {id} is not in the sidebar; run `inline sidebar` to see ids"
                    )),
                    Moving::Folder(id) => {
                        CliError::invalid_args(format!("Folder {id} was not found"))
                    }
                })?
            }
        };
        if moving.iter().any(|item| matches!(item, Moving::Folder(_)))
            && matches!(lane, Lane::Folder(_))
        {
            return Err(CliError::invalid_args(
                "Folders cannot be nested inside folders",
            ));
        }

        let pinned_lane = lane == Lane::Pinned;
        let (entries, lower, upper) = self.lane(lane)?;
        let keyed: Vec<&SidebarEntry> = entries
            .iter()
            .filter(|entry| !moving.iter().any(|item| entry.matches(*item)))
            .filter(|entry| entry.lane_key(pinned_lane).is_some())
            .collect();
        let start = |entry: &SidebarEntry| entry.lane_key(pinned_lane).map(str::to_string);
        let end = |entry: &SidebarEntry| entry.lane_end(pinned_lane).map(str::to_string);

        let (left, right) = match placement {
            Placement::Top(_) => (
                lower.clone(),
                keyed
                    .first()
                    .and_then(|entry| start(entry))
                    .or(upper.clone()),
            ),
            Placement::Bottom(_) => (
                keyed.last().and_then(|entry| end(entry)).or(lower.clone()),
                upper.clone(),
            ),
            Placement::Before(target) | Placement::After(target) => {
                let index = keyed
                    .iter()
                    .position(|entry| entry.matches(*target))
                    .ok_or_else(|| {
                        CliError::invalid_args(
                            "The target has no stored sidebar position; move it first",
                        )
                    })?;
                if matches!(placement, Placement::Before(_)) {
                    let left = index
                        .checked_sub(1)
                        .and_then(|previous| end(keyed[previous]))
                        .or(lower.clone());
                    (left, start(keyed[index]))
                } else {
                    let right = keyed
                        .get(index + 1)
                        .and_then(|next| start(next))
                        .or(upper.clone());
                    (end(keyed[index]), right)
                }
            }
        };
        let keys = fractional_keys(left.as_deref(), right.as_deref(), moving.len().max(1))?;
        Ok((lane, keys))
    }

    /// Returns the sorted lane with new keys, or `None` when it is already sorted.
    fn sorted_lane(
        &self,
        lane: Lane,
        by: SortKey,
        reverse: bool,
    ) -> Result<Option<Vec<(SidebarEntry, String)>>, CliError> {
        let pinned_lane = lane == Lane::Pinned;
        let (entries, lower, upper) = self.lane(lane)?;
        let mut sorted = entries.clone();
        match by {
            SortKey::Title => sorted.sort_by_key(SidebarEntry::title_key),
            SortKey::Activity => sorted.sort_by_key(|entry| std::cmp::Reverse(entry.activity())),
        }
        if reverse {
            sorted.reverse();
        }
        let unchanged = sorted
            .iter()
            .zip(&entries)
            .all(|(lhs, rhs)| lhs.describe() == rhs.describe())
            && entries
                .iter()
                .all(|entry| entry.lane_key(pinned_lane).is_some());
        if unchanged {
            return Ok(None);
        }
        let keys = match lane {
            // Allocate below every current root key and apply bottom-up, so a
            // folder's children are always re-laid before its next sibling.
            Lane::Root => {
                let first = entries
                    .iter()
                    .filter_map(|entry| entry.lane_key(false))
                    .min();
                fractional_keys(None, first, sorted.len())?
            }
            Lane::Pinned | Lane::Folder(_) => {
                fractional_keys(lower.as_deref(), upper.as_deref(), sorted.len())?
            }
        };
        Ok(Some(sorted.into_iter().zip(keys).collect()))
    }

    /// Chats the macOS manual Cleanup would close.
    fn cleanup_candidates(&self, now: i64) -> Vec<&SidebarChat> {
        let pinned_folder_ids: Vec<i64> = self
            .pinned
            .iter()
            .filter_map(|entry| match entry {
                SidebarEntry::Folder(folder) => Some(folder.folder_id),
                _ => None,
            })
            .collect();
        self.all_chats()
            .into_iter()
            .filter(|chat| chat.open && !chat.pinned && !chat.unread)
            .filter(|chat| {
                !chat
                    .folder_id
                    .is_some_and(|id| pinned_folder_ids.contains(&id))
            })
            .filter(|chat| {
                if chat.empty_untitled {
                    return true;
                }
                let Some(opened) = chat.opened_date else {
                    return false;
                };
                if chat.has_unknown_last_message {
                    return false;
                }
                opened <= now - CLEANUP_OPENED_AGE_SECONDS
                    && chat.last_activity.unwrap_or(opened) <= now - CLEANUP_ACTIVITY_AGE_SECONDS
            })
            .collect()
    }

    /// Folders with no open chat once `closing` chats are closed.
    fn empty_folders_after(&self, closing: &[i64]) -> Vec<&SidebarFolder> {
        self.pinned
            .iter()
            .chain(&self.items)
            .filter_map(|entry| match entry {
                SidebarEntry::Folder(folder)
                    if folder
                        .chats
                        .iter()
                        .all(|chat| !chat.open || closing.contains(&chat.chat_id)) =>
                {
                    Some(folder)
                }
                _ => None,
            })
            .collect()
    }
}

fn sidebar_chat(item: &ChatListItem) -> Option<SidebarChat> {
    let dialog = item.dialog.as_ref()?;
    let last_activity = item
        .last_message
        .as_ref()
        .map(|summary| summary.message.date);
    let is_dm = item.peer.peer_type == "user";
    Some(SidebarChat {
        chat_id: item.chat.id,
        peer_type: item.peer.peer_type.clone(),
        peer_id: item.peer.id,
        title: item.display_name.clone(),
        space_name: item.space_name.clone(),
        unread_count: item.unread_count.filter(|count| *count > 0),
        unread: item.unread_count.is_some_and(|count| count > 0)
            || dialog.unread_mark == Some(true),
        open: dialog.open == Some(true),
        pinned: dialog.pinned == Some(true),
        folder_id: dialog.folder_id,
        order: dialog.order.clone(),
        pinned_order: dialog.pinned_order.clone(),
        opened_date: dialog.opened_date,
        last_activity,
        has_unknown_last_message: item.chat.last_msg_id.is_some() && last_activity.is_none(),
        empty_untitled: !is_dm
            && (item.chat.untitled == Some(true) || item.chat.title.trim().is_empty())
            && item.chat.last_msg_id.is_none(),
    })
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Lane {
    Pinned,
    Root,
    Folder(i64),
}

impl Lane {
    fn describe(self) -> String {
        match self {
            Self::Pinned => "pinned items".to_string(),
            Self::Root => "the sidebar".to_string(),
            Self::Folder(id) => format!("folder {id}"),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Moving {
    Chat(i64),
    Folder(i64),
}

enum Placement {
    Top(Option<Lane>),
    Bottom(Option<Lane>),
    Before(Moving),
    After(Moving),
}

impl Placement {
    fn from_args(args: &PlacementArgs, lane: Option<Lane>) -> Self {
        if let Some(id) = args.before {
            Self::Before(Moving::Chat(id))
        } else if let Some(id) = args.after {
            Self::After(Moving::Chat(id))
        } else if let Some(id) = args.before_folder {
            Self::Before(Moving::Folder(id))
        } else if let Some(id) = args.after_folder {
            Self::After(Moving::Folder(id))
        } else if args.top {
            Self::Top(lane)
        } else {
            Self::Bottom(lane)
        }
    }

    fn validate_lane_flags(&self, lane: Option<Lane>) -> Result<(), CliError> {
        if lane.is_some() && matches!(self, Self::Before(_) | Self::After(_)) {
            return Err(CliError::invalid_args(
                "--pinned, --root, and --folder only apply to --top and --bottom; a --before/--after target decides the section",
            ));
        }
        Ok(())
    }

    fn describe(&self, lane: Lane) -> String {
        match self {
            Self::Top(_) => format!("to the top of {}", lane.describe()),
            Self::Bottom(_) => format!("to the bottom of {}", lane.describe()),
            Self::Before(Moving::Chat(id)) => format!("before chat {id}"),
            Self::After(Moving::Chat(id)) => format!("after chat {id}"),
            Self::Before(Moving::Folder(id)) => format!("before folder {id}"),
            Self::After(Moving::Folder(id)) => format!("after folder {id}"),
        }
    }
}

// MARK: - Batch execution

pub(crate) struct SidebarContext<'a> {
    pub(crate) config: &'a Config,
    pub(crate) auth_store: &'a AuthStore,
    pub(crate) current_user: Option<proto::User>,
    pub(crate) json: bool,
    pub(crate) json_format: JsonFormat,
}

struct PeerTarget {
    peer: proto::InputPeer,
    label: String,
}

impl PeersArgs {
    fn targets(&self) -> Result<Vec<PeerTarget>, Error> {
        let mut targets = Vec::new();
        for chat_id in dedup(&self.chat_ids) {
            let peer = crate::peer::input_peer_from_args(Some(chat_id), None)?;
            targets.push(PeerTarget {
                label: crate::peer_label_from_input(&peer),
                peer,
            });
        }
        for user_id in dedup(&self.user_ids) {
            let peer = crate::peer::input_peer_from_args(None, Some(user_id))?;
            targets.push(PeerTarget {
                label: crate::peer_label_from_input(&peer),
                peer,
            });
        }
        Ok(targets)
    }
}

fn dedup(ids: &[i64]) -> Vec<i64> {
    let mut seen = Vec::new();
    for id in ids {
        if !seen.contains(id) {
            seen.push(*id);
        }
    }
    seen
}

/// Collects per-chat results so one failure does not stop a batch.
struct Batch<T> {
    results: Vec<T>,
    failures: Vec<String>,
    json: bool,
}

#[derive(Serialize)]
struct BatchOutput<'a, T> {
    results: &'a [T],
    failed: &'a [String],
}

impl<T: Serialize> Batch<T> {
    fn new(json: bool) -> Self {
        Self {
            results: Vec::new(),
            failures: Vec::new(),
            json,
        }
    }

    fn record<E: std::fmt::Display>(
        &mut self,
        label: &str,
        result: Result<T, E>,
        message: impl FnOnce(&T) -> String,
    ) {
        match result {
            Ok(payload) => {
                if !self.json {
                    println!("{}", message(&payload));
                }
                self.results.push(payload);
            }
            Err(error) => {
                let failure = format!("{label}: {error}");
                if !self.json {
                    eprintln!("Failed {failure}");
                }
                self.failures.push(failure);
            }
        }
    }

    fn finish(self, ctx: &SidebarContext<'_>, empty_message: &str) -> Result<(), Error> {
        if self.json {
            output::print_json(
                &BatchOutput {
                    results: &self.results,
                    failed: &self.failures,
                },
                ctx.json_format,
            )?;
        } else if self.results.is_empty() && self.failures.is_empty() {
            println!("{empty_message}");
        }
        if self.failures.is_empty() {
            return Ok(());
        }
        Err(Box::new(CliError {
            code: "partial_failure",
            message: format!(
                "{} of {} sidebar changes failed:\n  {}",
                self.failures.len(),
                self.failures.len() + self.results.len(),
                self.failures.join("\n  ")
            ),
            hint: Some(
                "Run `inline sidebar` to check the current state, then retry the failed chats."
                    .to_string(),
            ),
            examples: Vec::new(),
        }))
    }
}

async fn load_sidebar(
    realtime: &mut crate::AuthenticatedRealtime,
    current_user: Option<&proto::User>,
) -> Result<Sidebar, Error> {
    let payload = realtime
        .call(proto::GetChatsInput {
            include_subthreads: Some(false),
        })
        .await?;
    Sidebar::build(payload, current_user)
}

fn print_payload<T: Serialize>(
    ctx: &SidebarContext<'_>,
    payload: &T,
    message: impl FnOnce() -> String,
) -> Result<(), Error> {
    if ctx.json {
        output::print_json(payload, ctx.json_format)?;
    } else {
        println!("{}", message());
    }
    Ok(())
}

/// Resolves explicit peers, or every sidebar chat `select` keeps for `--all`.
async fn resolve_targets(
    args: &PeersOrAllArgs,
    realtime: &mut crate::AuthenticatedRealtime,
    current_user: Option<&proto::User>,
    select: impl Fn(&Sidebar) -> Vec<&SidebarChat>,
) -> Result<Vec<PeerTarget>, Error> {
    match args.peers() {
        Some(peers) => peers.targets(),
        None => {
            let sidebar = load_sidebar(realtime, current_user).await?;
            select(&sidebar)
                .into_iter()
                .map(SidebarChat::target)
                .collect()
        }
    }
}

fn moving_chats(sidebar: &Sidebar, targets: &[PeerTarget]) -> Vec<Moving> {
    targets
        .iter()
        .map(|target| {
            Moving::Chat(
                sidebar
                    .dialog(&target.peer)
                    .map(|chat| chat.chat_id)
                    .unwrap_or(0),
            )
        })
        .collect()
}

fn to_json<T: Serialize>(value: T) -> serde_json::Value {
    serde_json::to_value(value).unwrap_or(serde_json::Value::Null)
}

fn capitalize(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

// MARK: - Handlers

pub(crate) async fn run(
    command: Option<SidebarCommand>,
    ctx: SidebarContext<'_>,
) -> Result<(), Error> {
    let command = command.unwrap_or(SidebarCommand::List);
    let mut realtime = crate::connect_authenticated_realtime(ctx.config, ctx.auth_store).await?;
    let current_user = ctx.current_user.clone();
    let current_user = current_user.as_ref();
    match command {
        SidebarCommand::List => {
            let sidebar = load_sidebar(&mut realtime, current_user).await?;
            if ctx.json {
                output::print_json(&sidebar, ctx.json_format)?;
            } else {
                print_sidebar(&sidebar);
            }
        }
        SidebarCommand::Open(args) => {
            let targets = args.peers.targets()?;
            let orders: Vec<Option<String>> = if args.top {
                let sidebar = load_sidebar(&mut realtime, current_user).await?;
                let moving = moving_chats(&sidebar, &targets);
                let (_, keys) = sidebar.placement(&moving, &Placement::Top(Some(Lane::Root)))?;
                keys.into_iter().map(Some).collect()
            } else {
                vec![None; targets.len()]
            };
            let mut batch = Batch::new(ctx.json);
            for (target, order) in targets.into_iter().zip(orders) {
                let result = realtime
                    .call(proto::UpdateDialogOpenInput {
                        peer_id: Some(target.peer),
                        open: true,
                        order,
                        folder_id: args.folder,
                    })
                    .await;
                batch.record(&target.label, result, |_| match args.folder {
                    Some(folder) => format!("Opened {} in folder {folder}.", target.label),
                    None => format!("Opened {}.", target.label),
                });
            }
            batch.finish(&ctx, "Nothing to open.")?;
        }
        SidebarCommand::Close(args) => {
            let targets = resolve_targets(&args, &mut realtime, current_user, |sidebar| {
                // Everything outside the pinned section, like macOS Close All.
                sidebar
                    .items
                    .iter()
                    .flat_map(SidebarEntry::chats)
                    .filter(|chat| chat.open)
                    .collect()
            })
            .await?;
            let mut batch = Batch::new(ctx.json);
            for target in targets {
                let result = realtime
                    .call(proto::UpdateDialogOpenInput {
                        peer_id: Some(target.peer),
                        open: false,
                        order: None,
                        folder_id: None,
                    })
                    .await;
                batch.record(&target.label, result, |payload| {
                    if payload.deleted_chat == Some(true) {
                        format!(
                            "Closed {} (an empty untitled thread, so it was deleted).",
                            target.label
                        )
                    } else {
                        format!("Closed {}.", target.label)
                    }
                });
            }
            batch.finish(&ctx, "No open chats to close.")?;
        }
        SidebarCommand::Move(args) => {
            let lane_flag = args.lane.lane();
            let placement = Placement::from_args(&args.placement, lane_flag);
            placement.validate_lane_flags(lane_flag)?;
            let targets = args.peers.targets()?;
            let sidebar = load_sidebar(&mut realtime, current_user).await?;
            let moving = moving_chats(&sidebar, &targets);
            let (lane, keys) = sidebar.placement(&moving, &placement)?;
            let mut batch = Batch::new(ctx.json);
            for (target, key) in targets.into_iter().zip(keys) {
                let input =
                    move_input(target.peer.clone(), sidebar.dialog(&target.peer), lane, key);
                let result = realtime.call(input).await;
                batch.record(&target.label, result, |_| {
                    format!("Moved {} {}.", target.label, placement.describe(lane))
                });
            }
            batch.finish(&ctx, "Nothing to move.")?;
        }
        SidebarCommand::Sort(args) => {
            let sidebar = load_sidebar(&mut realtime, current_user).await?;
            let lane = args.lane.lane().unwrap_or(Lane::Root);
            let Some(sorted) = sidebar.sorted_lane(lane, args.by, args.reverse)? else {
                let empty: Vec<serde_json::Value> = Vec::new();
                let output = BatchOutput {
                    results: &empty,
                    failed: &[],
                };
                return print_payload(&ctx, &output, || {
                    format!("{} is already sorted.", capitalize(&lane.describe()))
                });
            };
            let mut batch: Batch<serde_json::Value> = Batch::new(ctx.json);
            // Bottom-up so root folders re-lay their chats below the next sibling.
            for (entry, key) in sorted.into_iter().rev() {
                let label = entry.describe();
                let result: Result<serde_json::Value, Error> = match &entry {
                    SidebarEntry::Chat(chat) => {
                        let input = proto::UpdateDialogOrderInput {
                            peer_id: Some(chat.input_peer()?),
                            order: (lane != Lane::Pinned).then(|| key.clone()),
                            pinned_order: (lane == Lane::Pinned).then(|| key.clone()),
                            pinned: None,
                            destination: None,
                        };
                        realtime.call(input).await.map(to_json)
                    }
                    SidebarEntry::Folder(folder) => {
                        let mut input = folder_update(folder.folder_id);
                        if lane == Lane::Pinned {
                            input.pinned_order_update = Some(
                                proto::update_dialog_folder_input::PinnedOrderUpdate::PinnedOrder(
                                    key.clone(),
                                ),
                            );
                        } else {
                            input.order = Some(key.clone());
                        }
                        realtime.call(input).await.map(to_json)
                    }
                };
                batch.record(&label, result, |_| format!("Placed {label}."));
            }
            batch.finish(&ctx, "Nothing to sort.")?;
        }
        SidebarCommand::Pin(args) => {
            let targets = args.peers.targets()?;
            let pinned_orders: Vec<Option<String>> = if args.top {
                let sidebar = load_sidebar(&mut realtime, current_user).await?;
                let moving = moving_chats(&sidebar, &targets);
                let (_, keys) = sidebar.placement(&moving, &Placement::Top(Some(Lane::Pinned)))?;
                keys.into_iter().map(Some).collect()
            } else {
                vec![None; targets.len()]
            };
            let mut batch = Batch::new(ctx.json);
            for (target, pinned_order) in targets.into_iter().zip(pinned_orders) {
                let result = realtime
                    .call(proto::UpdateDialogOrderInput {
                        peer_id: Some(target.peer),
                        order: None,
                        pinned_order,
                        pinned: Some(true),
                        destination: None,
                    })
                    .await;
                batch.record(&target.label, result, |_| {
                    format!("Pinned {}.", target.label)
                });
            }
            batch.finish(&ctx, "Nothing to pin.")?;
        }
        SidebarCommand::Unpin(args) => {
            let targets = resolve_targets(&args, &mut realtime, current_user, |sidebar| {
                sidebar
                    .all_chats()
                    .into_iter()
                    .filter(|chat| chat.pinned)
                    .collect()
            })
            .await?;
            let mut batch = Batch::new(ctx.json);
            for target in targets {
                let result = realtime
                    .call(proto::UpdateDialogOrderInput {
                        peer_id: Some(target.peer),
                        order: None,
                        pinned_order: None,
                        pinned: Some(false),
                        destination: None,
                    })
                    .await;
                batch.record(&target.label, result, |_| {
                    format!("Unpinned {}.", target.label)
                });
            }
            batch.finish(&ctx, "No pinned chats to unpin.")?;
        }
        SidebarCommand::Archive(args) => archive(&mut realtime, &args, true, &ctx).await?,
        SidebarCommand::Unarchive(args) => archive(&mut realtime, &args, false, &ctx).await?,
        SidebarCommand::MarkRead(args) => {
            let targets = resolve_targets(&args, &mut realtime, current_user, |sidebar| {
                sidebar
                    .all_chats()
                    .into_iter()
                    .filter(|chat| chat.unread)
                    .collect()
            })
            .await?;
            let mut batch = Batch::new(ctx.json);
            for target in targets {
                let result = realtime
                    .call(proto::ReadMessagesInput {
                        peer_id: Some(target.peer),
                        max_id: None,
                    })
                    .await;
                batch.record(&target.label, result, |_| {
                    format!("Marked {} as read.", target.label)
                });
            }
            batch.finish(&ctx, "No unread sidebar chats.")?;
        }
        SidebarCommand::Cleanup(args) => cleanup(&mut realtime, current_user, &args, &ctx).await?,
        SidebarCommand::Folder { command } => {
            run_folder(command, &mut realtime, current_user, &ctx).await?
        }
    }
    Ok(())
}

fn move_input(
    peer: proto::InputPeer,
    current: Option<&SidebarChat>,
    lane: Lane,
    key: String,
) -> proto::UpdateDialogOrderInput {
    let already_pinned = current.is_some_and(|chat| chat.pinned && chat.folder_id.is_none());
    let in_folder = current.and_then(|chat| chat.folder_id);
    match lane {
        Lane::Pinned => proto::UpdateDialogOrderInput {
            peer_id: Some(peer),
            order: None,
            pinned_order: Some(key),
            pinned: (!already_pinned).then_some(true),
            destination: None,
        },
        Lane::Root => proto::UpdateDialogOrderInput {
            peer_id: Some(peer),
            order: Some(key),
            pinned_order: None,
            pinned: Some(false),
            destination: in_folder.map(|_| destination_root()),
        },
        Lane::Folder(folder_id) => proto::UpdateDialogOrderInput {
            peer_id: Some(peer),
            order: Some(key),
            pinned_order: None,
            pinned: None,
            destination: Some(destination_folder(folder_id)),
        },
    }
}

async fn archive(
    realtime: &mut crate::AuthenticatedRealtime,
    args: &PeersArgs,
    archived: bool,
    ctx: &SidebarContext<'_>,
) -> Result<(), Error> {
    let mut batch = Batch::new(ctx.json);
    for target in args.targets()? {
        let result = realtime
            .call(proto::UpdateDialogArchivedInput {
                peer_id: Some(target.peer),
                archived,
            })
            .await;
        batch.record(&target.label, result, |_| {
            if archived {
                format!("Archived {}.", target.label)
            } else {
                format!("Unarchived {}.", target.label)
            }
        });
    }
    batch.finish(ctx, "Nothing to change.")
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CleanupPlan<'a> {
    dry_run: bool,
    close: Vec<&'a SidebarChat>,
    delete_folders: Vec<&'a SidebarFolder>,
}

async fn cleanup(
    realtime: &mut crate::AuthenticatedRealtime,
    current_user: Option<&proto::User>,
    args: &SidebarCleanupArgs,
    ctx: &SidebarContext<'_>,
) -> Result<(), Error> {
    let sidebar = load_sidebar(realtime, current_user).await?;
    let now = chrono::Utc::now().timestamp();
    let close = sidebar.cleanup_candidates(now);
    let closing: Vec<i64> = close.iter().map(|chat| chat.chat_id).collect();
    let delete_folders = if args.keep_folders {
        Vec::new()
    } else {
        sidebar.empty_folders_after(&closing)
    };

    if args.dry_run {
        if ctx.json {
            return output::print_json(
                &CleanupPlan {
                    dry_run: true,
                    close,
                    delete_folders,
                },
                ctx.json_format,
            )
            .map_err(Into::into);
        }
        if close.is_empty() && delete_folders.is_empty() {
            println!("Nothing to clean up.");
        }
        for chat in &close {
            println!("Would close {}", chat_line(chat, "").trim_start());
        }
        for folder in &delete_folders {
            println!(
                "Would delete empty folder {} ({})",
                folder.folder_id,
                folder.display_title()
            );
        }
        return Ok(());
    }

    let mut batch: Batch<serde_json::Value> = Batch::new(ctx.json);
    for chat in &close {
        let target = chat.target()?;
        let result = realtime
            .call(proto::UpdateDialogOpenInput {
                peer_id: Some(target.peer),
                open: false,
                order: None,
                folder_id: None,
            })
            .await
            .map(to_json);
        batch.record(&target.label, result, |_| {
            format!("Closed {}.", target.label)
        });
    }
    for folder in &delete_folders {
        let label = format!("folder {} ({})", folder.folder_id, folder.display_title());
        let result = realtime
            .call(proto::DeleteDialogFolderInput {
                folder_id: folder.folder_id,
                disposition: proto::DeleteDialogFolderDisposition::KeepDialogs as i32,
            })
            .await
            .map(to_json);
        batch.record(&label, result, |_| format!("Deleted empty {label}."));
    }
    batch.finish(ctx, "Nothing to clean up.")
}

fn destination_root() -> proto::DialogFolderDestination {
    proto::DialogFolderDestination {
        destination: Some(proto::dialog_folder_destination::Destination::Root(true)),
    }
}

fn destination_folder(folder_id: i64) -> proto::DialogFolderDestination {
    proto::DialogFolderDestination {
        destination: Some(proto::dialog_folder_destination::Destination::FolderId(
            folder_id,
        )),
    }
}

fn folder_label(folder: &proto::DialogFolder) -> String {
    match folder
        .title
        .as_deref()
        .filter(|title| !title.trim().is_empty())
    {
        Some(title) => format!("folder {} \"{}\"", folder.id, output::terminal_text(title)),
        None => format!("folder {}", folder.id),
    }
}

fn folder_update(folder_id: i64) -> proto::UpdateDialogFolderInput {
    proto::UpdateDialogFolderInput {
        folder_id,
        title_update: None,
        order: None,
        emoji_update: None,
        pinned_order_update: None,
    }
}

async fn run_folder(
    command: SidebarFolderCommand,
    realtime: &mut crate::AuthenticatedRealtime,
    current_user: Option<&proto::User>,
    ctx: &SidebarContext<'_>,
) -> Result<(), Error> {
    use proto::update_dialog_folder_input::{EmojiUpdate, PinnedOrderUpdate, TitleUpdate};

    match command {
        SidebarFolderCommand::Create(args) => {
            let peers = PeersArgs {
                chat_ids: args.chat_ids,
                user_ids: args.user_ids,
            }
            .targets()?
            .into_iter()
            .map(|target| target.peer)
            .collect();
            let pinned_order = if args.pin {
                let sidebar = load_sidebar(realtime, current_user).await?;
                let (_, keys) = sidebar
                    .placement(&[Moving::Folder(0)], &Placement::Bottom(Some(Lane::Pinned)))?;
                keys.into_iter().next()
            } else {
                None
            };
            let title = args
                .title
                .map(|title| title.trim().to_string())
                .filter(|title| !title.is_empty());
            let payload = realtime
                .call(proto::CreateDialogFolderInput {
                    title,
                    peers,
                    order: None,
                    pinned_order,
                })
                .await?;
            print_payload(ctx, &payload, || match payload.folder.as_ref() {
                Some(folder) => format!(
                    "Created {} with {} chat(s).",
                    folder_label(folder),
                    payload.dialogs.len()
                ),
                None => "Created folder.".to_string(),
            })?;
        }
        SidebarFolderCommand::Update(args) => {
            let mut input = folder_update(args.folder_id);
            input.title_update = match (args.title, args.clear_title) {
                (Some(title), _) => Some(TitleUpdate::Title(title)),
                (None, true) => Some(TitleUpdate::ClearTitle(true)),
                (None, false) => None,
            };
            input.emoji_update = match (args.emoji, args.clear_emoji) {
                (Some(emoji), _) => Some(EmojiUpdate::Emoji(emoji)),
                (None, true) => Some(EmojiUpdate::ClearEmoji(true)),
                (None, false) => None,
            };
            let payload = realtime.call(input).await?;
            print_payload(ctx, &payload, || match payload.folder.as_ref() {
                Some(folder) => format!("Updated {}.", folder_label(folder)),
                None => format!("Updated folder {}.", args.folder_id),
            })?;
        }
        SidebarFolderCommand::Add(args) => {
            let mut batch = Batch::new(ctx.json);
            for target in args.peers.targets()? {
                let result = realtime
                    .call(proto::UpdateDialogOrderInput {
                        peer_id: Some(target.peer),
                        order: None,
                        pinned_order: None,
                        pinned: None,
                        destination: Some(destination_folder(args.folder_id)),
                    })
                    .await;
                batch.record(&target.label, result, |_| {
                    format!("Moved {} into folder {}.", target.label, args.folder_id)
                });
            }
            batch.finish(ctx, "Nothing to move.")?;
        }
        SidebarFolderCommand::Remove(args) => {
            let sidebar = load_sidebar(realtime, current_user).await?;
            // Group by folder so each folder's chats land together right after it.
            let mut groups: Vec<(i64, Vec<PeerTarget>)> = Vec::new();
            for target in args.targets()? {
                let folder_id = sidebar
                    .dialog(&target.peer)
                    .and_then(|chat| chat.folder_id)
                    .filter(|id| sidebar.folder(*id).is_some())
                    .ok_or_else(|| {
                        CliError::invalid_args(format!("{} is not in a folder", target.label))
                    })?;
                match groups.iter_mut().find(|(id, _)| *id == folder_id) {
                    Some((_, targets)) => targets.push(target),
                    None => groups.push((folder_id, vec![target])),
                }
            }
            let mut batch = Batch::new(ctx.json);
            for (folder_id, targets) in groups {
                let orders: Vec<Option<String>> =
                    if sidebar.location(Moving::Folder(folder_id)) == Some(Lane::Root) {
                        let moving = moving_chats(&sidebar, &targets);
                        let (_, keys) = sidebar
                            .placement(&moving, &Placement::After(Moving::Folder(folder_id)))?;
                        keys.into_iter().map(Some).collect()
                    } else {
                        vec![None; targets.len()]
                    };
                for (target, order) in targets.into_iter().zip(orders) {
                    let result = realtime
                        .call(proto::UpdateDialogOrderInput {
                            peer_id: Some(target.peer),
                            order,
                            pinned_order: None,
                            pinned: None,
                            destination: Some(destination_root()),
                        })
                        .await;
                    batch.record(&target.label, result, |_| {
                        format!("Moved {} out of folder {folder_id}.", target.label)
                    });
                }
            }
            batch.finish(ctx, "Nothing to move.")?;
        }
        SidebarFolderCommand::Move(args) => {
            let placement = Placement::from_args(&args.placement, None);
            let sidebar = load_sidebar(realtime, current_user).await?;
            sidebar.require_folder(args.folder_id)?;
            let (lane, keys) = sidebar.placement(&[Moving::Folder(args.folder_id)], &placement)?;
            let key = keys.into_iter().next().unwrap_or_default();
            let mut input = folder_update(args.folder_id);
            match lane {
                Lane::Pinned => {
                    input.pinned_order_update = Some(PinnedOrderUpdate::PinnedOrder(key))
                }
                Lane::Root => {
                    input.order = Some(key);
                    if sidebar.location(Moving::Folder(args.folder_id)) == Some(Lane::Pinned) {
                        input.pinned_order_update = Some(PinnedOrderUpdate::ClearPinnedOrder(true));
                    }
                }
                Lane::Folder(_) => unreachable!("rejected by placement"),
            }
            let payload = realtime.call(input).await?;
            print_payload(ctx, &payload, || {
                format!(
                    "Moved folder {} {}.",
                    args.folder_id,
                    placement.describe(lane)
                )
            })?;
        }
        SidebarFolderCommand::Pin(args) => {
            let sidebar = load_sidebar(realtime, current_user).await?;
            sidebar.require_folder(args.folder_id)?;
            let placement = if args.top {
                Placement::Top(Some(Lane::Pinned))
            } else {
                Placement::Bottom(Some(Lane::Pinned))
            };
            let (_, keys) = sidebar.placement(&[Moving::Folder(args.folder_id)], &placement)?;
            let mut input = folder_update(args.folder_id);
            input.pinned_order_update = keys.into_iter().next().map(PinnedOrderUpdate::PinnedOrder);
            let payload = realtime.call(input).await?;
            print_payload(ctx, &payload, || {
                format!("Pinned folder {}.", args.folder_id)
            })?;
        }
        SidebarFolderCommand::Unpin(args) => {
            let mut input = folder_update(args.folder_id);
            input.pinned_order_update = Some(PinnedOrderUpdate::ClearPinnedOrder(true));
            let payload = realtime.call(input).await?;
            print_payload(ctx, &payload, || {
                format!("Unpinned folder {}.", args.folder_id)
            })?;
        }
        SidebarFolderCommand::Delete(args) => {
            let disposition = if args.close_chats {
                proto::DeleteDialogFolderDisposition::CloseDialogs
            } else {
                proto::DeleteDialogFolderDisposition::KeepDialogs
            };
            let payload = realtime
                .call(proto::DeleteDialogFolderInput {
                    folder_id: args.folder_id,
                    disposition: disposition as i32,
                })
                .await?;
            print_payload(ctx, &payload, || {
                if args.close_chats {
                    format!(
                        "Deleted folder {} and closed its {} chat(s).",
                        args.folder_id,
                        payload.dialogs.len()
                    )
                } else {
                    format!(
                        "Deleted folder {}; its {} chat(s) moved to the sidebar.",
                        args.folder_id,
                        payload.dialogs.len()
                    )
                }
            })?;
        }
    }
    Ok(())
}

// MARK: - Text output

fn chat_line(chat: &SidebarChat, indent: &str) -> String {
    let mut line = format!(
        "{indent}{:>8}  {}",
        chat.chat_id,
        output::terminal_text(&chat.title)
    );
    if let Some(space) = chat.space_name.as_deref() {
        line.push_str(&format!("  · {}", output::terminal_text(space)));
    }
    if chat.peer_type == "user" {
        line.push_str(&format!("  · DM user {}", chat.peer_id));
    }
    if let Some(unread) = chat.unread_count {
        line.push_str(&format!("  · {unread} unread"));
    } else if chat.unread {
        line.push_str("  · marked unread");
    }
    line
}

fn folder_lines(folder: &SidebarFolder, lines: &mut Vec<String>) {
    let emoji = folder
        .emoji
        .as_deref()
        .map(|emoji| format!("{} ", output::terminal_text(emoji)))
        .unwrap_or_default();
    lines.push(format!(
        "  folder {:>2}  {emoji}{}",
        folder.folder_id,
        folder.display_title()
    ));
    if folder.chats.is_empty() {
        lines.push("              (empty)".to_string());
    }
    for chat in &folder.chats {
        lines.push(chat_line(chat, "    "));
    }
}

fn section_lines(title: &str, entries: &[SidebarEntry], lines: &mut Vec<String>) {
    lines.push(title.to_string());
    if entries.is_empty() {
        lines.push("  (none)".to_string());
    }
    for entry in entries {
        match entry {
            SidebarEntry::Chat(chat) => lines.push(chat_line(chat, "")),
            SidebarEntry::Folder(folder) => folder_lines(folder, lines),
        }
    }
}

fn print_sidebar(sidebar: &Sidebar) {
    let mut lines = Vec::new();
    if !sidebar.pinned.is_empty() {
        section_lines("Pinned", &sidebar.pinned, &mut lines);
        lines.push(String::new());
    }
    section_lines("Sidebar", &sidebar.items, &mut lines);
    println!("{}", lines.join("\n"));
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_000_000;

    fn chat(chat_id: i64, order: &str) -> SidebarChat {
        SidebarChat {
            chat_id,
            peer_type: "chat".to_string(),
            peer_id: chat_id,
            title: format!("chat {chat_id}"),
            space_name: None,
            unread_count: None,
            unread: false,
            open: true,
            pinned: false,
            folder_id: None,
            order: Some(order.to_string()),
            pinned_order: None,
            opened_date: Some(NOW - 7 * 3600),
            last_activity: Some(NOW - 4 * 3600),
            has_unknown_last_message: false,
            empty_untitled: false,
        }
    }

    fn pinned(chat_id: i64, pinned_order: &str) -> SidebarChat {
        SidebarChat {
            pinned: true,
            pinned_order: Some(pinned_order.to_string()),
            ..chat(chat_id, "a")
        }
    }

    fn folder(folder_id: i64, order: &str, chats: Vec<SidebarChat>) -> SidebarFolder {
        SidebarFolder {
            folder_id,
            title: None,
            emoji: None,
            pinned: false,
            order: order.to_string(),
            pinned_order: None,
            chats: chats
                .into_iter()
                .map(|chat| SidebarChat {
                    folder_id: Some(folder_id),
                    ..chat
                })
                .collect(),
        }
    }

    fn sidebar(pinned: Vec<SidebarEntry>, items: Vec<SidebarEntry>) -> Sidebar {
        let dialogs = pinned
            .iter()
            .chain(&items)
            .flat_map(SidebarEntry::chats)
            .cloned()
            .collect();
        Sidebar {
            pinned,
            items,
            dialogs,
        }
    }

    fn fixture() -> Sidebar {
        // Root: chat 1 (b), folder 9 (d) with chats 3 (d1), 4 (d2), chat 2 (f).
        sidebar(
            vec![
                SidebarEntry::Chat(pinned(7, "M")),
                SidebarEntry::Chat(pinned(8, "P")),
            ],
            vec![
                SidebarEntry::Chat(chat(1, "b")),
                SidebarEntry::Folder(folder(9, "d", vec![chat(3, "d1"), chat(4, "d2")])),
                SidebarEntry::Chat(chat(2, "f")),
            ],
        )
    }

    fn one(
        sidebar: &Sidebar,
        moving: Moving,
        placement: Placement,
    ) -> Result<(Lane, String), CliError> {
        sidebar
            .placement(&[moving], &placement)
            .map(|(lane, keys)| (lane, keys.into_iter().next().unwrap()))
    }

    #[test]
    fn between_matches_server_algorithm() {
        assert_eq!(fractional_between(None, None).unwrap(), "U");
        assert_eq!(fractional_between(Some("a"), Some("b")).unwrap(), "aU");
        assert_eq!(fractional_between(None, Some("1")).unwrap(), "0U");
        assert_eq!(fractional_between(Some("z"), None).unwrap(), "zU");
        assert!(fractional_between(Some("b"), Some("a")).is_err());
    }

    #[test]
    fn many_keys_are_ascending_bounded_and_short() {
        let keys = fractional_keys(Some("d2"), Some("f"), 200).unwrap();
        assert_eq!(keys.len(), 200);
        assert!(keys.windows(2).all(|pair| pair[0] < pair[1]));
        assert!(keys.first().unwrap().as_str() > "d2" && keys.last().unwrap().as_str() < "f");
        assert!(keys.iter().all(|key| key.len() < 12), "{keys:?}");
    }

    #[test]
    fn root_placement_after_folder_skips_its_children() {
        let (lane, key) = one(
            &fixture(),
            Moving::Chat(1),
            Placement::After(Moving::Folder(9)),
        )
        .unwrap();
        assert_eq!(lane, Lane::Root);
        assert!(key.as_str() > "d2" && key.as_str() < "f", "{key}");
        let (_, key) = one(
            &fixture(),
            Moving::Chat(1),
            Placement::Before(Moving::Chat(2)),
        )
        .unwrap();
        assert!(key.as_str() > "d2" && key.as_str() < "f", "{key}");
    }

    #[test]
    fn top_and_bottom_use_current_lane() {
        let (lane, key) = one(&fixture(), Moving::Chat(2), Placement::Top(None)).unwrap();
        assert_eq!(lane, Lane::Root);
        assert!(key.as_str() < "b");
        let (lane, key) = one(&fixture(), Moving::Chat(7), Placement::Bottom(None)).unwrap();
        assert_eq!(lane, Lane::Pinned);
        assert!(key.as_str() > "P");
    }

    #[test]
    fn folder_placement_stays_inside_folder_interval() {
        let sidebar = fixture();
        let (lane, key) = one(
            &sidebar,
            Moving::Chat(1),
            Placement::Top(Some(Lane::Folder(9))),
        )
        .unwrap();
        assert_eq!(lane, Lane::Folder(9));
        assert!(key.as_str() > "d" && key.as_str() < "d1", "{key}");
        let (_, key) = one(
            &sidebar,
            Moving::Chat(1),
            Placement::Bottom(Some(Lane::Folder(9))),
        )
        .unwrap();
        assert!(key.as_str() > "d2" && key.as_str() < "f", "{key}");
        let (lane, key) =
            one(&sidebar, Moving::Chat(2), Placement::After(Moving::Chat(3))).unwrap();
        assert_eq!(lane, Lane::Folder(9));
        assert!(key.as_str() > "d1" && key.as_str() < "d2", "{key}");
    }

    #[test]
    fn target_lane_decides_pinning() {
        let (lane, key) = one(
            &fixture(),
            Moving::Chat(1),
            Placement::Before(Moving::Chat(8)),
        )
        .unwrap();
        assert_eq!(lane, Lane::Pinned);
        assert!(key.as_str() > "M" && key.as_str() < "P", "{key}");
    }

    #[test]
    fn several_chats_land_together_in_order() {
        let sidebar = fixture();
        let (lane, keys) = sidebar
            .placement(
                &[Moving::Chat(2), Moving::Chat(1)],
                &Placement::Before(Moving::Chat(8)),
            )
            .unwrap();
        assert_eq!(lane, Lane::Pinned);
        assert_eq!(keys.len(), 2);
        assert!(
            keys[0].as_str() > "M" && keys[0] < keys[1] && keys[1].as_str() < "P",
            "{keys:?}"
        );
        assert!(
            sidebar
                .placement(
                    &[Moving::Chat(1), Moving::Chat(2)],
                    &Placement::After(Moving::Chat(2))
                )
                .is_err()
        );
    }

    #[test]
    fn folders_cannot_nest_and_unknown_targets_fail() {
        let sidebar = fixture();
        assert!(
            one(
                &sidebar,
                Moving::Folder(9),
                Placement::After(Moving::Chat(3))
            )
            .is_err()
        );
        assert!(
            one(
                &sidebar,
                Moving::Chat(1),
                Placement::After(Moving::Chat(99))
            )
            .is_err()
        );
        assert!(
            one(
                &sidebar,
                Moving::Chat(1),
                Placement::After(Moving::Folder(99))
            )
            .is_err()
        );
        let (lane, key) = one(&sidebar, Moving::Folder(9), Placement::Top(None)).unwrap();
        assert_eq!(lane, Lane::Root);
        assert!(key.as_str() < "b");
    }

    #[test]
    fn sort_by_title_allocates_below_current_root_keys() {
        let mut a = chat(1, "b");
        a.title = "Zulu".to_string();
        let mut b = chat(2, "f");
        b.title = "alpha".to_string();
        let mut grouped = folder(9, "d", vec![chat(3, "d1")]);
        grouped.title = Some("Mid".to_string());
        let sidebar = sidebar(
            Vec::new(),
            vec![
                SidebarEntry::Chat(a),
                SidebarEntry::Folder(grouped),
                SidebarEntry::Chat(b),
            ],
        );
        let sorted = sidebar
            .sorted_lane(Lane::Root, SortKey::Title, false)
            .unwrap()
            .unwrap();
        let order: Vec<String> = sorted.iter().map(|(entry, _)| entry.describe()).collect();
        assert_eq!(order, ["chat 2 (alpha)", "folder 9 (Mid)", "chat 1 (Zulu)"]);
        assert!(sorted.windows(2).all(|pair| pair[0].1 < pair[1].1));
        assert!(sorted.iter().all(|(_, key)| key.as_str() < "b"));
    }

    #[test]
    fn sort_reports_already_sorted() {
        let mut recent = chat(1, "b");
        recent.last_activity = Some(NOW);
        let older = chat(2, "f");
        let sidebar = sidebar(
            Vec::new(),
            vec![SidebarEntry::Chat(recent), SidebarEntry::Chat(older)],
        );
        assert!(
            sidebar
                .sorted_lane(Lane::Root, SortKey::Activity, false)
                .unwrap()
                .is_none()
        );
        assert!(
            sidebar
                .sorted_lane(Lane::Root, SortKey::Activity, true)
                .unwrap()
                .is_some()
        );
    }

    #[test]
    fn cleanup_matches_macos_manual_rules() {
        let stale = chat(1, "a");
        let mut fresh_open = chat(2, "b");
        fresh_open.opened_date = Some(NOW - 3600);
        let mut recent_activity = chat(3, "c");
        recent_activity.last_activity = Some(NOW - 600);
        let mut unread = chat(4, "d");
        unread.unread = true;
        let mut empty_untitled = chat(5, "e");
        empty_untitled.opened_date = None;
        empty_untitled.empty_untitled = true;
        let mut unknown_last = chat(6, "f");
        unknown_last.last_activity = None;
        unknown_last.has_unknown_last_message = true;
        let mut never_stamped = chat(10, "g");
        never_stamped.opened_date = None;
        let mut pinned_folder = folder(9, "h", vec![chat(11, "h1")]);
        pinned_folder.pinned = true;
        pinned_folder.pinned_order = Some("A".to_string());
        let doomed_folder = folder(12, "i", vec![chat(13, "i1")]);
        let sidebar = sidebar(
            vec![
                SidebarEntry::Chat(pinned(7, "M")),
                SidebarEntry::Folder(pinned_folder),
            ],
            vec![
                SidebarEntry::Chat(stale),
                SidebarEntry::Chat(fresh_open),
                SidebarEntry::Chat(recent_activity),
                SidebarEntry::Chat(unread),
                SidebarEntry::Chat(empty_untitled),
                SidebarEntry::Chat(unknown_last),
                SidebarEntry::Chat(never_stamped),
                SidebarEntry::Folder(doomed_folder),
            ],
        );
        let closing: Vec<i64> = sidebar
            .cleanup_candidates(NOW)
            .iter()
            .map(|chat| chat.chat_id)
            .collect();
        assert_eq!(closing, [1, 5, 13]);
        let folders: Vec<i64> = sidebar
            .empty_folders_after(&closing)
            .iter()
            .map(|folder| folder.folder_id)
            .collect();
        assert_eq!(folders, [12]);
    }
}
