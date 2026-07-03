mod api;
mod attachments;
mod auth;
mod auth_flow;
mod chat_output;
mod client_info;
mod config;
mod dates;
mod doctor;
mod downloads;
mod errors;
mod media;
mod message_export;
mod message_output;
mod message_selectors;
mod notifications;
mod output;
mod peer;
mod protocol;
mod realtime;
mod state;
mod update;
mod validation;

use chrono::Utc;
use clap::{ArgAction, Args, Parser, Subcommand, error::ErrorKind};
use dialoguer::Confirm;
use futures_util::stream::{self, StreamExt};
use rand::{RngCore, rngs::OsRng};
use serde::Serialize;
use std::collections::HashMap;
use std::ffi::OsString;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use std::{env, fs, io};

use crate::api::{ApiClient, CreateLinearIssueInput, CreateNotionTaskInput};
use crate::attachments::{
    MAX_ATTACHMENT_BYTES, PreparedAttachment, input_media_from_upload, prepare_attachments,
};
use crate::auth::AuthStore;
use crate::auth_flow::{
    build_auth_logout_output, handle_login, print_auth_logout, print_auth_user,
};
use crate::chat_output::{
    apply_chat_list_filter, apply_chat_list_limits, build_chat_list, chat_display_name,
};
use crate::config::Config;
use crate::doctor::{build_doctor_output, print_doctor};
use crate::downloads::{
    download_message_media, resolve_batch_download_path, resolve_download_path,
};
use crate::errors::{
    CliError, JsonCliError, JsonErrorEnvelope, human_cli_error_from_error,
    json_cli_error_from_error,
};
use crate::message_export::{
    ExportPeer, MessageExportBuildInput, MessageExportFormat, apply_media_local_paths,
    build_message_export_bundle, forward_source_key, infer_export_format, render_export,
};
use crate::message_output::{
    build_message_list, build_message_list_from_messages, message_summary,
};
use crate::message_selectors::parse_message_id_selectors;
use crate::notifications::{
    NotificationModeArg, notification_mode_from_arg, notification_settings_values,
    print_notification_settings,
};
use crate::output::{
    PeerSummary, UserListOutput, UserSummary, build_chat_participants_output, build_space_list,
    build_space_members_output, build_user_list, print_chat_details, print_message_detail,
    user_display_name, user_summary,
};
use crate::peer::input_peer_from_args;
use crate::protocol::proto;
use crate::realtime::RealtimeClient;
use crate::state::LocalDb;
use crate::validation::{
    normalize_search_queries, normalize_translation_language, parse_time_filters,
    validate_attachment_inputs, validate_message_id_arg, validate_message_ids_arg,
    validate_message_limit, validate_optional_message_id_arg, validate_optional_positive_id_arg,
    validate_output_dir_path_arg, validate_output_file_path_arg, validate_positive_id_arg,
    validate_positive_ids_arg, validate_table_only_list_flags,
};

#[derive(Clone, Copy)]
struct DetectedGlobalFlags {
    json: bool,
    json_format: output::JsonFormat,
}

fn detect_global_flags(argv: &[OsString]) -> DetectedGlobalFlags {
    let mut json = false;
    let mut pretty = false;
    let mut compact = false;
    for arg in argv {
        if arg == "--json" {
            json = true;
        } else if arg == "--pretty" {
            pretty = true;
        } else if arg == "--compact" {
            compact = true;
        }
    }
    DetectedGlobalFlags {
        json,
        json_format: output::resolve_json_format(pretty, compact),
    }
}

#[derive(Parser)]
#[command(
    name = "inline",
    version,
    about = "Inline CLI",
    disable_version_flag = true,
    propagate_version = true,
    after_help = r#"Common workflows:
  Start:
    inline login [--email you@example.com | --phone +15551234567]
    inline me
    inline logout
    inline doctor

  Review a thread:
    inline chats list --filter "launch"
    inline transcript --chat-id 123 --limit 500 --output ./feedback.md
    inline transcript --chat-id 123 --limit 500 --download-media --output ./feedback-bundle
    inline transcript --chat-id 123 --limit 500 --download-media --media-dir ./feedback-media --output ./feedback.md
    inline messages export --chat-id 123 --output ./messages.json
    inline messages get --chat-id 123 --message-id 91,92,100 --json
    inline messages download --chat-id 123 --message-id 80-100 --dir ./media

  Core command groups:
    chats         list|get|participants|add-participant|remove-participant|create|create-dm|update-visibility|rename|mark-unread|mark-read|delete
    messages      list|search|get|send|forward|edit|delete|add-reaction|delete-reaction|download|export|transcript
    users         list|get
    spaces        list|members|invite|delete-member|update-member-access
    notifications get|set
    bots          list|create|reveal-token
    typing        start|stop
    tasks         create-linear|create-notion
    schema        proto

  Aliases and shortcuts:
    inline login                  -> inline auth login
    inline logout                 -> inline auth logout
    inline chat/thread/threads ... -> inline chats ...
    inline bot ...                  -> inline bots ...
    inline me, inline whoami        -> inline auth me
    inline search ...               -> inline messages search ...
    inline transcript ...           -> inline messages transcript ... (supports --download-media)
    inline messages send/edit accept: --text | --message | --msg | -m

  JSON mode:
    --json prints raw RPC payloads (use --pretty or --compact for formatting).
    In --json mode, these table-only helpers are disabled:
      inline users list --filter/--ids/--id
      inline bots list --filter/--ids/--id
      inline chats list --ids/--id
    Destructive commands never prompt in --json mode; pass --yes.

  Notes:
    Bot tokens are not printed in table output; use: inline bots reveal-token --bot-user-id <ID>
    Mentions use UTF-16 offsets: --mention USER_ID:OFFSET:LENGTH

  Key examples:
    inline chats list --filter "launch"
    inline chats update-visibility --chat-id 123 --private --participant 42
    inline messages send --chat-id 123 --text "@Sam hello" --mention 42:0:4
    inline messages list --chat-id 123 --since "2h ago" --until "1h ago"
    inline transcript --chat-id 123 --limit 500 --output ./feedback.md
    inline transcript --chat-id 123 --limit 500 --download-media --output ./feedback-bundle
    inline transcript --chat-id 123 --limit 500 --download-media --media-dir ./feedback-media --output ./feedback.md
    inline messages export --chat-id 123 --output ./messages.json
    inline messages get --chat-id 123 --message-id 91,92,100 --json
    inline messages download --chat-id 123 --message-id 80-100 --dir ./media
    inline tasks create-linear --chat-id 123 --message-id 456
    inline schema proto

Docs:
  https://github.com/inline-chat/inline/blob/main/cli/README.md
  https://github.com/inline-chat/inline/blob/main/cli/skill/SKILL.md
"#
)]
struct Cli {
    #[command(subcommand)]
    command: Command,

    #[arg(short = 'v', long = "version", global = true, action = ArgAction::Version, help = "Print version information")]
    version: Option<bool>,

    #[arg(
        long,
        global = true,
        help = "Output JSON instead of a table (use --pretty/--compact to control formatting)"
    )]
    json: bool,

    #[arg(
        long,
        global = true,
        help = "Pretty-print JSON output (default)",
        conflicts_with = "compact"
    )]
    pretty: bool,

    #[arg(
        long,
        global = true,
        help = "Compact JSON output (no whitespace)",
        conflicts_with = "pretty"
    )]
    compact: bool,
}

#[derive(Subcommand)]
enum Command {
    #[command(about = "Authenticate this CLI")]
    Auth {
        #[command(subcommand)]
        command: AuthCommand,
    },
    #[command(about = "Log in (shortcut for auth login)")]
    Login(AuthLoginArgs),
    #[command(about = "Log out (shortcut for auth logout)")]
    Logout,
    #[command(about = "Update the CLI to the latest release")]
    Update,
    #[command(about = "Print diagnostic information about this CLI")]
    Doctor,
    #[command(
        about = "List chats and threads",
        alias = "chat",
        alias = "thread",
        alias = "threads"
    )]
    Chats {
        #[command(subcommand)]
        command: ChatsCommand,
    },
    #[command(about = "List users or fetch a user by id")]
    Users {
        #[command(subcommand)]
        command: UsersCommand,
    },
    #[command(about = "Read and send messages")]
    Messages {
        #[command(subcommand)]
        command: MessagesCommand,
    },
    #[command(about = "List spaces from your chats")]
    Spaces {
        #[command(subcommand)]
        command: SpacesCommand,
    },
    #[command(about = "View or update notification settings")]
    Notifications {
        #[command(subcommand)]
        command: NotificationsCommand,
    },
    #[command(about = "Create tasks from messages (Linear, Notion)")]
    Tasks {
        #[command(subcommand)]
        command: TasksCommand,
    },

    #[command(about = "Bot operations", alias = "bot")]
    Bots {
        #[command(subcommand)]
        command: BotsCommand,
    },

    #[command(about = "Send typing (compose) actions")]
    Typing {
        #[command(subcommand)]
        command: TypingCommand,
    },

    // Read-only shortcuts (desire paths).
    #[command(about = "Show current user (shortcut for auth me)", alias = "whoami")]
    Me,
    #[command(about = "Search messages (shortcut for messages search)")]
    Search(MessagesSearchArgs),
    #[command(
        about = "Export a clean markdown transcript (shortcut for messages transcript)",
        after_help = r#"Examples:
  inline transcript --chat-id 123 --limit 500 --download-media --media-dir ./feedback-media --output feedback.md
  inline transcript --chat-id 123 --limit 500 --download-media --output ./feedback-bundle
  inline transcript --chat-id 123 --from-msg-id 600 --limit 50 --output feedback.md
  inline transcript --chat-id 123 --limit 500 --output feedback.md
  inline transcript --chat-id 123 --message-id 91,92,100

One-pass review:
  Use --download-media to download photos/files and rewrite transcript links to local paths.
  If --output is a directory or no-extension bundle path, transcript writes transcript.md plus a media/ folder.
"#
    )]
    Transcript(MessagesTranscriptArgs),

    #[command(about = "Show local API schema info")]
    Schema {
        #[command(subcommand)]
        command: SchemaCommand,
    },
}

#[derive(Subcommand)]
enum AuthCommand {
    #[command(about = "Log in via email or phone code")]
    Login(AuthLoginArgs),
    #[command(about = "Show the currently authenticated user")]
    Me,
    #[command(about = "Clear the saved token")]
    Logout,
}

#[derive(Args)]
pub(crate) struct AuthLoginArgs {
    #[arg(
        long,
        help = "Email address to send the login code to",
        conflicts_with = "phone"
    )]
    email: Option<String>,

    #[arg(
        long,
        help = "Phone number to send the login code to",
        conflicts_with = "email"
    )]
    phone: Option<String>,
}

#[derive(Subcommand)]
enum SchemaCommand {
    #[command(about = "Print the bundled protobuf schema (.proto sources)")]
    Proto,
}

#[derive(Subcommand)]
enum ChatsCommand {
    #[command(about = "List chats with last message and unread count")]
    List(ChatsListArgs),
    #[command(about = "Fetch a chat by id or user")]
    Get(ChatsGetArgs),
    #[command(about = "List participants in a chat")]
    Participants(ChatsParticipantsArgs),
    #[command(about = "Add a participant to a chat")]
    AddParticipant(ChatsParticipantArgs),
    #[command(about = "Remove a participant from a chat")]
    RemoveParticipant(ChatsParticipantArgs),
    #[command(about = "Create a new chat or thread")]
    Create(ChatsCreateArgs),
    #[command(about = "Create a private chat (DM)")]
    CreateDm(ChatsCreateDmArgs),
    #[command(about = "Update chat visibility (public/private)")]
    UpdateVisibility(ChatsUpdateVisibilityArgs),
    #[command(about = "Rename a chat or thread")]
    Rename(ChatsRenameArgs),
    #[command(about = "Mark a chat or DM as unread")]
    MarkUnread(ChatsMarkUnreadArgs),
    #[command(about = "Mark a chat or DM as read")]
    MarkRead(ChatsMarkReadArgs),
    #[command(about = "Delete a chat (space thread)")]
    Delete(ChatsDeleteArgs),
}

#[derive(Subcommand)]
enum BotsCommand {
    #[command(about = "List bots you can access")]
    List(BotsListArgs),
    #[command(about = "Create a new bot")]
    Create(BotsCreateArgs),
    #[command(about = "Reveal a bot token by bot user id")]
    RevealToken(BotsRevealTokenArgs),
}

#[derive(Subcommand)]
enum TypingCommand {
    #[command(about = "Start typing")]
    Start(TypingArgs),
    #[command(about = "Stop typing (clear compose action)")]
    Stop(TypingArgs),
}

#[derive(Args)]
struct ChatsListArgs {
    #[arg(long, help = "Maximum number of chats to return")]
    limit: Option<usize>,

    #[arg(long, help = "Offset into the chat list")]
    offset: Option<usize>,

    #[arg(long, help = "Filter chats by name, space, or id")]
    filter: Option<String>,

    #[arg(long, help = "Print only chat ids (one per line)")]
    ids: bool,

    #[arg(
        long,
        help = "Require exactly one match and print only its chat id",
        conflicts_with = "ids",
        requires = "filter"
    )]
    id: bool,
}

#[derive(Args)]
struct ChatsGetArgs {
    #[arg(long, help = "Chat id", conflicts_with = "user_id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)", conflicts_with = "chat_id")]
    user_id: Option<i64>,
}

#[derive(Args)]
struct ChatsParticipantsArgs {
    #[arg(long, help = "Chat id")]
    chat_id: i64,
}

#[derive(Args)]
struct ChatsParticipantArgs {
    #[arg(long, help = "Chat id")]
    chat_id: i64,

    #[arg(long, help = "User id")]
    user_id: i64,
}

#[derive(Args)]
struct ChatsCreateArgs {
    #[arg(long, help = "Chat title")]
    title: String,

    #[arg(long, help = "Space id (for threads within a space)")]
    space_id: Option<i64>,

    #[arg(long, help = "Optional chat description")]
    description: Option<String>,

    #[arg(long, help = "Optional emoji for the chat icon")]
    emoji: Option<String>,

    #[arg(long, help = "Create a public chat (participants must be empty)")]
    public: bool,

    #[arg(
        long = "participant",
        value_name = "USER_ID",
        num_args = 1..,
        action = ArgAction::Append,
        help = "Participant user id (repeatable)"
    )]
    participants: Vec<i64>,
}

#[derive(Args)]
struct ChatsCreateDmArgs {
    #[arg(long, help = "User id to start a DM with")]
    user_id: i64,
}

#[derive(Args)]
struct ChatsUpdateVisibilityArgs {
    #[arg(long, help = "Chat id (space thread)")]
    chat_id: i64,

    #[arg(long, help = "Make the chat public", conflicts_with = "private")]
    public: bool,

    #[arg(long, help = "Make the chat private", conflicts_with = "public")]
    private: bool,

    #[arg(
        long = "participant",
        value_name = "USER_ID",
        num_args = 1..,
        action = ArgAction::Append,
        help = "Participant user id (repeatable, required for private chats)"
    )]
    participants: Vec<i64>,
}

#[derive(Args)]
struct ChatsRenameArgs {
    #[arg(long, help = "Chat id (space thread)")]
    chat_id: i64,

    #[arg(long, help = "New chat/thread title")]
    title: String,

    #[arg(long, help = "Optional emoji for the chat icon")]
    emoji: Option<String>,
}

#[derive(Args)]
struct ChatsMarkUnreadArgs {
    #[arg(long, help = "Chat id", conflicts_with = "user_id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)", conflicts_with = "chat_id")]
    user_id: Option<i64>,
}

#[derive(Args)]
struct ChatsMarkReadArgs {
    #[arg(long, help = "Chat id", conflicts_with = "user_id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)", conflicts_with = "chat_id")]
    user_id: Option<i64>,

    #[arg(long, help = "Max message id to mark as read")]
    max_id: Option<i64>,
}

#[derive(Args)]
struct ChatsDeleteArgs {
    #[arg(long, help = "Chat id (space thread)")]
    chat_id: i64,

    #[arg(long, short = 'y', help = "Skip confirmation prompt")]
    yes: bool,
}

#[derive(Subcommand)]
enum UsersCommand {
    #[command(
        about = "List users that appear in your chats",
        alias = "search",
        alias = "find"
    )]
    List(UsersListArgs),
    #[command(about = "Fetch a user by id from the chat list payload")]
    Get(UserGetArgs),
}

#[derive(Args)]
struct UsersListArgs {
    #[arg(long, help = "Filter users by name, username, email, or phone")]
    filter: Option<String>,

    #[arg(long, help = "Print only user ids (one per line)")]
    ids: bool,

    #[arg(
        long,
        help = "Require exactly one match and print only its user id",
        conflicts_with = "ids",
        requires = "filter"
    )]
    id: bool,
}

#[derive(Args)]
struct UserGetArgs {
    #[arg(long, help = "User id")]
    id: i64,
}

#[derive(Args)]
struct BotsListArgs {
    #[arg(long, help = "Filter bots by name or username")]
    filter: Option<String>,

    #[arg(long, help = "Print only bot user ids (one per line)")]
    ids: bool,

    #[arg(
        long,
        help = "Require exactly one match and print only its user id",
        conflicts_with = "ids",
        requires = "filter"
    )]
    id: bool,
}

#[derive(Args)]
struct BotsCreateArgs {
    #[arg(long, help = "Bot display name")]
    name: String,

    #[arg(long, help = "Bot username (without @)")]
    username: String,

    #[arg(long, help = "Optional space id to add the bot to")]
    add_to_space: Option<i64>,
}

#[derive(Args)]
struct BotsRevealTokenArgs {
    #[arg(long, help = "Bot user id")]
    bot_user_id: i64,
}

#[derive(Args)]
struct TypingArgs {
    #[arg(long, help = "Chat id", conflicts_with = "user_id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)", conflicts_with = "chat_id")]
    user_id: Option<i64>,
}

#[derive(Subcommand)]
enum MessagesCommand {
    #[command(about = "List messages for a chat or user")]
    List(MessagesListArgs),
    #[command(about = "Search messages in a chat or DM")]
    Search(MessagesSearchArgs),
    #[command(
        about = "Fetch one or more messages by id",
        after_help = r#"Examples:
  inline messages get --chat-id 123 --message-id 456
  inline messages get --chat-id 123 --message-id 91,92,100 --json
  inline messages get --chat-id 123 --message-id 91-100 --json --compact
"#
    )]
    Get(MessagesGetArgs),
    #[command(about = "Send a message to a chat or user")]
    Send(MessagesSendArgs),
    #[command(about = "Forward messages between chats or DMs")]
    Forward(MessagesForwardArgs),
    #[command(
        about = "Export messages as json, jsonl, markdown, or csv",
        after_help = r#"Examples:
  inline messages export --chat-id 123 --limit 500 --format markdown --output feedback.md
  inline messages export --chat-id 123 --limit 500 --format markdown --download-media --output ./feedback-bundle
  inline messages export --chat-id 123 --limit 500 --format markdown --download-media --media-dir ./feedback-media --output feedback.md
  inline messages export --chat-id 123 --limit 500 --format json --output feedback.json
  inline messages export --chat-id 123 --message-id 91,92,100 --format jsonl
  inline messages export --chat-id 123 --from-msg-id 600 --limit 50 --format markdown --output feedback.md

Output directories:
  If --output is a directory, export writes transcript.<format> inside it.
  With --download-media, a no-extension output path is treated as a bundle directory.
  With --download-media and no --media-dir, media files go in ./media inside that directory.
"#
    )]
    Export(MessagesExportArgs),
    #[command(
        about = "Export a clean markdown transcript",
        after_help = r#"Examples:
  inline transcript --chat-id 123 --limit 500 --download-media --media-dir ./feedback-media --output feedback.md
  inline transcript --chat-id 123 --limit 500 --download-media --output ./feedback-bundle
  inline transcript --chat-id 123 --from-msg-id 600 --limit 50 --output feedback.md
  inline messages transcript --chat-id 123 --limit 500 --output feedback.md
  inline messages transcript --chat-id 123 --message-id 91,92,100

One-pass review:
  Use --download-media to download photos/files and rewrite transcript links to local paths.
  If --output is a directory or no-extension bundle path, transcript writes transcript.md plus a media/ folder.
"#
    )]
    Transcript(MessagesTranscriptArgs),
    #[command(
        about = "Download media from one or more messages",
        after_help = r#"Examples:
  inline messages download --chat-id 123 --message-id 456 --dir ./media
  inline messages download --chat-id 123 --message-id 80-100 --dir ./media --parallel 8
  inline messages download --user-id 42 --message-id 3,7,13,14 --dir ./media
  inline messages download --chat-id 123 --from-msg-id 600 --limit 50 --dir ./media

Batch behavior:
  Ranges and comma selectors skip messages without media instead of failing the command.
  Human output reports downloaded, skipped, missing, and failed counts; --json includes details.
"#
    )]
    Download(MessagesDownloadArgs),
    #[command(about = "Delete message(s) by id (asks for confirmation)")]
    Delete(MessagesDeleteArgs),
    #[command(about = "Edit a message")]
    Edit(MessagesEditArgs),
    #[command(about = "Add an emoji reaction to a message")]
    AddReaction(MessagesReactionArgs),
    #[command(about = "Delete an emoji reaction from a message")]
    DeleteReaction(MessagesReactionArgs),
}

#[derive(Args)]
struct MessagesListArgs {
    #[arg(long, help = "Chat id", conflicts_with = "user_id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)", conflicts_with = "chat_id")]
    user_id: Option<i64>,

    #[arg(long, help = "Maximum number of messages to return")]
    limit: Option<i32>,

    #[arg(long, help = "Offset message id for pagination")]
    offset_id: Option<i64>,

    #[arg(long, help = "Only include messages with media")]
    has_media: bool,

    #[arg(long, help = "Only include messages with empty or missing text")]
    empty_text: bool,

    #[arg(long, help = "Only include forwarded messages")]
    forwarded: bool,

    #[arg(
        long,
        value_name = "LANG",
        help = "Translate messages to language code (e.g., en)"
    )]
    translate: Option<String>,

    #[arg(
        long,
        value_name = "TIME",
        help = "Filter messages since time (e.g., yesterday, 2h ago, 2024-01-15)"
    )]
    since: Option<String>,

    #[arg(
        long,
        value_name = "TIME",
        help = "Filter messages until time (e.g., today, 1d ago, 2024-01-20)"
    )]
    until: Option<String>,
}

#[derive(Args)]
struct MessagesSearchArgs {
    #[arg(long, help = "Chat id", conflicts_with = "user_id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)", conflicts_with = "chat_id")]
    user_id: Option<i64>,

    #[arg(long, help = "Search query (repeatable)")]
    query: Vec<String>,

    #[arg(long, help = "Maximum number of results to return")]
    limit: Option<i32>,

    #[arg(
        long,
        value_name = "LANG",
        help = "Translate search results to language code (e.g., en)"
    )]
    translate: Option<String>,

    #[arg(
        long,
        value_name = "TIME",
        help = "Filter results since time (e.g., yesterday, 2h ago)"
    )]
    since: Option<String>,

    #[arg(
        long,
        value_name = "TIME",
        help = "Filter results until time (e.g., today, 1d ago)"
    )]
    until: Option<String>,
}

#[derive(Args)]
struct MessagesGetArgs {
    #[arg(long, help = "Chat id", conflicts_with = "user_id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)", conflicts_with = "chat_id")]
    user_id: Option<i64>,

    #[arg(
        long = "message-id",
        value_name = "ID[,ID|START-END]",
        num_args = 1..,
        action = ArgAction::Append,
        help = "Message id selector. Supports single IDs, comma lists, ranges, and repeated flags."
    )]
    message_ids: Vec<String>,

    #[arg(
        long,
        value_name = "LANG",
        help = "Translate message to language code (e.g., en)"
    )]
    translate: Option<String>,
}

#[derive(Args)]
struct MessagesSendArgs {
    #[arg(long, help = "Chat id", conflicts_with = "user_id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)", conflicts_with = "chat_id")]
    user_id: Option<i64>,

    #[arg(
        long,
        short = 'm',
        alias = "message",
        alias = "msg",
        help = "Message text (used as caption for attachments)"
    )]
    text: Option<String>,

    #[arg(long, help = "Reply to message id")]
    reply_to: Option<i64>,

    #[arg(
        long = "mention",
        value_name = "USER_ID:OFFSET:LENGTH",
        num_args = 1..,
        action = ArgAction::Append,
        help = "Mention entity (repeatable). Format: user_id:offset:length (offset/length are UTF-16 units)."
    )]
    mentions: Vec<String>,

    #[arg(long, help = "Force image attachments to upload as files (documents)")]
    force_file: bool,

    #[arg(
        long = "attach",
        alias = "file",
        value_name = "PATH",
        num_args = 1..,
        action = ArgAction::Append,
        help = "Attachment path (file or folder). Repeatable; folders are zipped before upload."
    )]
    attachments: Vec<PathBuf>,

    #[arg(long, help = "Read message text/caption from stdin")]
    stdin: bool,
}

#[derive(Args)]
struct MessagesForwardArgs {
    #[arg(long, help = "Source chat id", conflicts_with = "from_user_id")]
    from_chat_id: Option<i64>,

    #[arg(
        long,
        help = "Source user id (for DMs)",
        conflicts_with = "from_chat_id"
    )]
    from_user_id: Option<i64>,

    #[arg(
        long = "message-id",
        value_name = "ID",
        num_args = 1..,
        action = ArgAction::Append,
        help = "Message id to forward (repeatable)"
    )]
    message_ids: Vec<i64>,

    #[arg(long, help = "Destination chat id", conflicts_with = "to_user_id")]
    to_chat_id: Option<i64>,

    #[arg(
        long,
        help = "Destination user id (for DMs)",
        conflicts_with = "to_chat_id"
    )]
    to_user_id: Option<i64>,

    #[arg(long, help = "Do not include forward header")]
    no_header: bool,
}

#[derive(Args)]
struct MessagesExportArgs {
    #[arg(long, help = "Chat id", conflicts_with = "user_id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)", conflicts_with = "chat_id")]
    user_id: Option<i64>,

    #[arg(long, help = "Maximum number of messages to return")]
    limit: Option<i32>,

    #[arg(long, help = "Offset message id for pagination")]
    offset_id: Option<i64>,

    #[arg(
        long,
        value_name = "ID",
        help = "Start a history window from this message id",
        conflicts_with_all = ["offset_id", "message_ids"]
    )]
    from_msg_id: Option<i64>,

    #[arg(
        long = "message-id",
        value_name = "ID[,ID|START-END]",
        num_args = 1..,
        action = ArgAction::Append,
        help = "Message id selector. Supports single IDs, comma lists, ranges, and repeated flags."
    )]
    message_ids: Vec<String>,

    #[arg(
        long,
        value_enum,
        value_name = "FORMAT",
        help = "Export format: json, jsonl, markdown, or csv"
    )]
    format: Option<MessageExportFormat>,

    #[arg(
        long,
        value_name = "PATH",
        help = "Output file path or bundle directory"
    )]
    output: Option<PathBuf>,

    #[arg(long, help = "Download media and write local paths into the export")]
    download_media: bool,

    #[arg(
        long,
        value_name = "DIR",
        help = "Directory for --download-media files (default: output-dir/media, <output-stem>-media, or ./inline-media)"
    )]
    media_dir: Option<PathBuf>,

    #[arg(
        long,
        value_name = "N",
        help = "Maximum concurrent media downloads for --download-media"
    )]
    parallel: Option<usize>,

    #[arg(
        long,
        value_name = "TIME",
        help = "Filter messages since time (e.g., yesterday, 2h ago, 2024-01-15)"
    )]
    since: Option<String>,

    #[arg(
        long,
        value_name = "TIME",
        help = "Filter messages until time (e.g., today, 1d ago, 2024-01-20)"
    )]
    until: Option<String>,
}

#[derive(Args)]
struct MessagesTranscriptArgs {
    #[arg(long, help = "Chat id", conflicts_with = "user_id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)", conflicts_with = "chat_id")]
    user_id: Option<i64>,

    #[arg(long, help = "Maximum number of messages to return")]
    limit: Option<i32>,

    #[arg(long, help = "Offset message id for pagination")]
    offset_id: Option<i64>,

    #[arg(
        long,
        value_name = "ID",
        help = "Start a history window from this message id",
        conflicts_with_all = ["offset_id", "message_ids"]
    )]
    from_msg_id: Option<i64>,

    #[arg(
        long = "message-id",
        value_name = "ID[,ID|START-END]",
        num_args = 1..,
        action = ArgAction::Append,
        help = "Message id selector. Supports single IDs, comma lists, ranges, and repeated flags."
    )]
    message_ids: Vec<String>,

    #[arg(
        long,
        value_name = "PATH",
        help = "Output markdown file path or bundle directory"
    )]
    output: Option<PathBuf>,

    #[arg(
        long,
        help = "Download media and rewrite transcript links to local paths"
    )]
    download_media: bool,

    #[arg(
        long,
        value_name = "DIR",
        help = "Directory for --download-media files (default: output-dir/media, <output-stem>-media, or ./inline-media)"
    )]
    media_dir: Option<PathBuf>,

    #[arg(
        long,
        value_name = "N",
        help = "Maximum concurrent media downloads for --download-media"
    )]
    parallel: Option<usize>,

    #[arg(
        long,
        value_name = "TIME",
        help = "Filter messages since time (e.g., yesterday, 2h ago, 2024-01-15)"
    )]
    since: Option<String>,

    #[arg(
        long,
        value_name = "TIME",
        help = "Filter messages until time (e.g., today, 1d ago, 2024-01-20)"
    )]
    until: Option<String>,
}

impl From<MessagesTranscriptArgs> for MessagesExportArgs {
    fn from(args: MessagesTranscriptArgs) -> Self {
        Self {
            chat_id: args.chat_id,
            user_id: args.user_id,
            limit: args.limit,
            offset_id: args.offset_id,
            from_msg_id: args.from_msg_id,
            message_ids: args.message_ids,
            format: Some(MessageExportFormat::Markdown),
            output: args.output,
            download_media: args.download_media,
            media_dir: args.media_dir,
            parallel: args.parallel,
            since: args.since,
            until: args.until,
        }
    }
}

#[derive(Args)]
struct MessagesDownloadArgs {
    #[arg(long, help = "Chat id", conflicts_with = "user_id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)", conflicts_with = "chat_id")]
    user_id: Option<i64>,

    #[arg(
        long = "message-id",
        value_name = "ID[,ID|START-END]",
        num_args = 1..,
        action = ArgAction::Append,
        help = "Message id selector. Supports single IDs, comma lists, ranges, and repeated flags; batch downloads skip messages without media."
    )]
    message_ids: Vec<String>,

    #[arg(
        long,
        value_name = "ID",
        help = "Download media from a history window starting at this message id",
        conflicts_with = "message_ids"
    )]
    from_msg_id: Option<i64>,

    #[arg(
        long,
        value_name = "N",
        help = "Maximum messages to fetch with --from-msg-id"
    )]
    limit: Option<i32>,

    #[arg(
        long,
        help = "Output file path (defaults to current directory)",
        conflicts_with = "dir"
    )]
    output: Option<PathBuf>,

    #[arg(
        long,
        help = "Output directory (defaults to current directory)",
        conflicts_with = "output"
    )]
    dir: Option<PathBuf>,

    #[arg(
        long,
        default_value_t = 8,
        help = "Maximum concurrent downloads for batch selectors"
    )]
    parallel: usize,
}

#[derive(Args)]
struct MessagesDeleteArgs {
    #[arg(long, help = "Chat id", conflicts_with = "user_id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)", conflicts_with = "chat_id")]
    user_id: Option<i64>,

    #[arg(
        long = "message-id",
        value_name = "ID",
        num_args = 1..,
        action = ArgAction::Append,
        help = "Message id to delete (repeatable)"
    )]
    message_ids: Vec<i64>,

    #[arg(long, short = 'y', help = "Skip confirmation prompt")]
    yes: bool,
}

#[derive(Args)]
struct MessagesEditArgs {
    #[arg(long, help = "Chat id", conflicts_with = "user_id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)", conflicts_with = "chat_id")]
    user_id: Option<i64>,

    #[arg(long, help = "Message id")]
    message_id: i64,

    #[arg(
        long,
        short = 'm',
        alias = "message",
        alias = "msg",
        help = "New message text"
    )]
    text: Option<String>,

    #[arg(long, help = "Read message text from stdin")]
    stdin: bool,
}

#[derive(Args)]
struct MessagesReactionArgs {
    #[arg(long, help = "Chat id", conflicts_with = "user_id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)", conflicts_with = "chat_id")]
    user_id: Option<i64>,

    #[arg(long, help = "Message id")]
    message_id: i64,

    #[arg(long, help = "Emoji reaction (use a real emoji character)")]
    emoji: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ExportOutput {
    path: String,
    format: String,
    messages: usize,
    bytes: usize,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    media_files: Vec<DownloadedFileOutput>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    skipped_message_ids: Vec<i64>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    media_errors: Vec<DownloadErrorOutput>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DownloadOutput {
    path: String,
    bytes: u64,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct DownloadedFileOutput {
    message_id: i64,
    path: String,
    bytes: u64,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct DownloadErrorOutput {
    message_id: i64,
    error: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DownloadBatchOutput {
    files: Vec<DownloadedFileOutput>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    skipped_message_ids: Vec<i64>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    missing_message_ids: Vec<i64>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    errors: Vec<DownloadErrorOutput>,
}

#[derive(Default)]
struct MediaDownloadSummary {
    files: Vec<DownloadedFileOutput>,
    skipped_message_ids: Vec<i64>,
    errors: Vec<DownloadErrorOutput>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TranslatedChatHistoryOutput {
    #[serde(flatten)]
    payload: proto::GetChatHistoryResult,
    translations: Vec<proto::MessageTranslation>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TranslatedSearchMessagesOutput {
    #[serde(flatten)]
    payload: proto::SearchMessagesResult,
    translations: Vec<proto::MessageTranslation>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TranslatedMessageOutput {
    #[serde(flatten)]
    message: proto::Message,
    translations: Vec<proto::MessageTranslation>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct MessagesGetBatchOutput {
    messages: Vec<proto::Message>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    missing_message_ids: Vec<i64>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    translations: Vec<proto::MessageTranslation>,
}

#[derive(Subcommand)]
enum SpacesCommand {
    #[command(about = "List spaces referenced in your chats")]
    List,
    #[command(about = "List members in a space")]
    Members(SpacesMembersArgs),
    #[command(about = "Invite a user to a space")]
    Invite(SpacesInviteArgs),
    #[command(about = "Remove a member from a space (asks for confirmation)")]
    DeleteMember(SpacesDeleteMemberArgs),
    #[command(about = "Update a member's access/role in a space")]
    UpdateMemberAccess(SpacesUpdateMemberAccessArgs),
}

#[derive(Subcommand)]
enum NotificationsCommand {
    #[command(about = "Show current notification settings")]
    Get,
    #[command(about = "Update notification settings")]
    Set(NotificationsSetArgs),
}

#[derive(Args)]
struct NotificationsSetArgs {
    #[arg(
        long,
        value_name = "MODE",
        value_enum,
        help = "Notification mode: all, none, mentions, only-mentions"
    )]
    mode: Option<NotificationModeArg>,

    #[arg(long, help = "Mute notification sounds")]
    silent: bool,

    #[arg(long, help = "Enable notification sounds", conflicts_with = "silent")]
    sound: bool,
}

#[derive(Args)]
struct SpacesMembersArgs {
    #[arg(long, help = "Space id")]
    space_id: i64,
}

#[derive(Args)]
struct SpacesInviteArgs {
    #[arg(long, help = "Space id")]
    space_id: i64,

    #[arg(long, help = "User id to invite", conflicts_with_all = ["email", "phone"])]
    user_id: Option<i64>,

    #[arg(long, help = "Email address to invite", conflicts_with_all = ["user_id", "phone"])]
    email: Option<String>,

    #[arg(long, help = "Phone number to invite", conflicts_with_all = ["user_id", "email"])]
    phone: Option<String>,

    #[arg(long, help = "Invite as space admin")]
    admin: bool,

    #[arg(long, help = "Allow access to public chats (member role only)")]
    public_chats: bool,
}

#[derive(Args)]
struct SpacesDeleteMemberArgs {
    #[arg(long, help = "Space id")]
    space_id: i64,

    #[arg(long, help = "User id")]
    user_id: i64,

    #[arg(long, short = 'y', help = "Skip confirmation prompt")]
    yes: bool,
}

#[derive(Args)]
struct SpacesUpdateMemberAccessArgs {
    #[arg(long, help = "Space id")]
    space_id: i64,

    #[arg(long, help = "User id")]
    user_id: i64,

    #[arg(long, help = "Set role to admin")]
    admin: bool,

    #[arg(long, help = "Set role to member")]
    member: bool,

    #[arg(long, help = "Allow access to public chats (member role only)")]
    public_chats: bool,
}

#[derive(Subcommand)]
enum TasksCommand {
    #[command(about = "Create a Linear issue from a message")]
    CreateLinear(TasksCreateLinearArgs),
    #[command(about = "Create a Notion task from a message")]
    CreateNotion(TasksCreateNotionArgs),
}

#[derive(Args)]
struct TasksCreateLinearArgs {
    #[arg(long, help = "Chat id containing the message")]
    chat_id: i64,

    #[arg(long, help = "Message id to create the task from")]
    message_id: i64,

    #[arg(long, help = "Space id (optional, inferred from chat if not provided)")]
    space_id: Option<i64>,
}

#[derive(Args)]
struct TasksCreateNotionArgs {
    #[arg(long, help = "Chat id containing the message")]
    chat_id: i64,

    #[arg(long, help = "Message id to create the task from")]
    message_id: i64,

    #[arg(long, help = "Space id (required for Notion tasks)")]
    space_id: i64,
}

#[tokio::main]
async fn main() {
    install_broken_pipe_handler();
    let argv: Vec<OsString> = env::args_os().collect();
    let flags = detect_global_flags(&argv);

    let started_at = Instant::now();
    let cli = match Cli::try_parse_from(&argv) {
        Ok(cli) => cli,
        Err(err) => {
            if matches!(
                err.kind(),
                ErrorKind::DisplayHelp | ErrorKind::DisplayVersion
            ) {
                let _ = err.print();
                std::process::exit(err.exit_code());
            }

            if flags.json {
                let payload = JsonErrorEnvelope {
                    error: JsonCliError::invalid_args(err.to_string()),
                };
                if let Ok(text) = output::json_string(&payload, flags.json_format) {
                    eprintln!("{text}");
                } else {
                    eprintln!("{}", err);
                }
            } else {
                let _ = err.print();
            }
            std::process::exit(err.exit_code());
        }
    };

    if let Err(error) = run(cli, started_at).await {
        if flags.json {
            let payload = JsonErrorEnvelope {
                error: json_cli_error_from_error(error.as_ref()),
            };

            if let Ok(text) = output::json_string(&payload, flags.json_format) {
                eprintln!("{text}");
            } else {
                eprintln!("{}", error);
            }
        } else {
            eprintln!("{}", human_cli_error_from_error(error.as_ref()));
        }
        std::process::exit(1);
    }
}

fn install_broken_pipe_handler() {
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        if is_broken_pipe_panic(info) {
            std::process::exit(0);
        }
        default_hook(info);
    }));
}

fn is_broken_pipe_panic(info: &std::panic::PanicHookInfo<'_>) -> bool {
    let message = info.to_string();
    message.contains("failed printing to stdout")
        && (message.contains("Broken pipe") || message.contains("broken pipe"))
}

fn is_interactive_terminal() -> bool {
    io::stdin().is_terminal() && io::stderr().is_terminal()
}

async fn run(cli: Cli, started_at: Instant) -> Result<(), Box<dyn std::error::Error>> {
    let json_format = output::resolve_json_format(cli.pretty, cli.compact);
    let config = Config::load();
    let auth_store = AuthStore::new(config.secrets_path.clone(), config.api_base_url.clone());
    let local_db = LocalDb::new(config.state_path.clone(), config.api_base_url.clone());
    let api = ApiClient::new(config.api_base_url.clone());
    let skip_update_check = matches!(
        &cli.command,
        Command::Login(_)
            | Command::Auth {
                command: AuthCommand::Login(_)
            }
            | Command::Update
            | Command::Doctor
    );
    let update_handle = if skip_update_check || cli.json || !io::stdout().is_terminal() {
        None
    } else {
        update::spawn_update_check(&config, &local_db, cli.json)
    };

    let result = async {
        match cli.command {
            Command::Login(args) => {
                handle_login(
                    args,
                    &api,
                    &auth_store,
                    &config.realtime_url,
                    &local_db,
                    cli.json,
                )
                .await?;
            }
            Command::Logout => {
                let env_token_present = auth::env_token_present();
                auth_store.clear_token()?;
                local_db.clear_current_user()?;
                let output = build_auth_logout_output(env_token_present);
                if cli.json {
                    output::print_json(&output, json_format)?;
                } else {
                    print_auth_logout(&output);
                }
            }
            Command::Auth { command } => match command {
                AuthCommand::Login(args) => {
                    handle_login(
                        args,
                        &api,
                        &auth_store,
                        &config.realtime_url,
                        &local_db,
                        cli.json,
                    )
                    .await?;
                }
                AuthCommand::Me => {
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let me = fetch_me(&mut realtime).await?;
                    local_db.set_current_user(me.clone())?;
                    if cli.json {
                        output::print_json(&me, json_format)?;
                    } else {
                        print_auth_user(&me);
                    }
                }
                AuthCommand::Logout => {
                    let env_token_present = auth::env_token_present();
                    auth_store.clear_token()?;
                    local_db.clear_current_user()?;
                    let output = build_auth_logout_output(env_token_present);
                    if cli.json {
                        output::print_json(&output, json_format)?;
                    } else {
                        print_auth_logout(&output);
                    }
                }
            },
            Command::Update => {
                update::run_update(&config, cli.json).await?;
            }
            Command::Doctor => {
                let output = build_doctor_output(&config, &auth_store, &local_db);
                if cli.json {
                    output::print_json(&output, json_format)?;
                } else {
                    print_doctor(&output);
                }
            }
            Command::Me => {
                let token = require_token(&auth_store)?;
                let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;
                let me = fetch_me(&mut realtime).await?;
                local_db.set_current_user(me.clone())?;
                if cli.json {
                    output::print_json(&me, json_format)?;
                } else {
                    print_auth_user(&me);
                }
            }
            Command::Search(args) => {
                // Shortcut for `inline messages search ...`
                let limit = validate_message_limit(args.limit)?;
                let (since_ts, until_ts) =
                    parse_time_filters(args.since.as_deref(), args.until.as_deref(), Utc::now())?;
                let translation_language = args
                    .translate
                    .as_deref()
                    .map(normalize_translation_language)
                    .transpose()?;
                let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                let queries = normalize_search_queries(&args.query)?;
                let peer_summary = peer_summary_from_input(&peer);
                let token = require_token(&auth_store)?;
                let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;

                let input = proto::SearchMessagesInput {
                    peer_id: Some(peer.clone()),
                    queries,
                    limit,
                    offset_id: None,
                    filter: None,
                };
                let result = realtime
                    .call_rpc(
                        proto::Method::SearchMessages,
                        proto::rpc_call::Input::SearchMessages(input),
                    )
                    .await?;
                match result {
                    proto::rpc_result::Result::SearchMessages(mut payload) => {
                        filter_messages_by_time(&mut payload.messages, since_ts, until_ts);
                        if cli.json {
                            if let Some(language) = translation_language.as_deref() {
                                let message_ids = collect_message_ids(&payload.messages);
                                let translations_by_id = fetch_message_translations(
                                    &mut realtime,
                                    &peer,
                                    &message_ids,
                                    language,
                                )
                                .await?;
                                let output = TranslatedSearchMessagesOutput {
                                    payload,
                                    translations: translations_in_message_order(
                                        &message_ids,
                                        &translations_by_id,
                                    ),
                                };
                                output::print_json(&output, json_format)?;
                            } else {
                                output::print_json(&payload, json_format)?;
                            }
                        } else {
                            let translations_by_id =
                                if let Some(language) = translation_language.as_deref() {
                                    let message_ids = collect_message_ids(&payload.messages);
                                    fetch_message_translations(
                                        &mut realtime,
                                        &peer,
                                        &message_ids,
                                        language,
                                    )
                                    .await?
                                } else {
                                    HashMap::new()
                                };
                            let chats_result = realtime
                                .call_rpc(
                                    proto::Method::GetChats,
                                    proto::rpc_call::Input::GetChats(proto::GetChatsInput {}),
                                )
                                .await?;
                            let (users_by_id, chats_by_id) = match chats_result {
                                proto::rpc_result::Result::GetChats(chats_payload) => {
                                    let users = chats_payload
                                        .users
                                        .into_iter()
                                        .map(|user| (user.id, user))
                                        .collect();
                                    let chats = chats_payload
                                        .chats
                                        .into_iter()
                                        .map(|chat| (chat.id, chat))
                                        .collect();
                                    (users, chats)
                                }
                                _ => return Err(CliError::unexpected_rpc_result("getChats").into()),
                            };
                            let current_user_id = local_db.load()?.current_user.map(|user| user.id);
                            let output = build_message_list_from_messages(
                                &payload.messages,
                                &users_by_id,
                                current_user_id,
                                peer_summary,
                                peer_name_from_input(&peer, &users_by_id, &chats_by_id),
                                Some(&translations_by_id),
                            );
                            output::print_messages(&output, false, json_format)?;
                        }
                    }
                    _ => return Err(CliError::unexpected_rpc_result("searchMessages").into()),
                }
            }
            Command::Transcript(args) => {
                handle_messages_export(
                    args.into(),
                    &config,
                    &auth_store,
                    cli.json,
                    json_format,
                    MessageExportFormat::Markdown,
                )
                .await?;
            }
            Command::Schema { command } => match command {
                SchemaCommand::Proto => {
                    let bundle = bundled_proto_sources();
                    if cli.json {
                        output::print_json(&bundle, json_format)?;
                    } else {
                        for file in bundle.files {
                            println!("# {}", file.name);
                            println!("{}", file.contents);
                            println!();
                        }
                    }
                }
            },
            Command::Bots { command } => match command {
                BotsCommand::List(args) => {
                    validate_table_only_list_flags(cli.json, args.ids, args.id)?;
                    let token = require_token(&auth_store)?;
                    let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let result = realtime
                        .call_rpc(
                            proto::Method::ListBots,
                            proto::rpc_call::Input::ListBots(proto::ListBotsInput {}),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::ListBots(payload) => {
                            let mut payload = payload;
                            if cli.json {
                                filter_bots_payload(&mut payload, args.filter.as_deref());
                                output::print_json(&payload, json_format)?;
                            } else {
                                let mut output = UserListOutput {
                                    users: payload.bots.iter().map(user_summary).collect(),
                                };
                                filter_users_output(&mut output, args.filter.as_deref());
                                if args.ids {
                                    for user in &output.users {
                                        println!("{}", user.user.id);
                                    }
                                } else if args.id {
                                    if output.users.len() != 1 {
                                        return Err(CliError::invalid_args(format!(
                                            "Expected exactly 1 match for --id, got {}",
                                            output.users.len()
                                        ))
                                        .into());
                                    }
                                    if let Some(user) = output.users.first() {
                                        println!("{}", user.user.id);
                                    }
                                } else {
                                    output::print_users(&output, false, json_format)?;
                                }
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("listBots").into()),
                    }
                }
                BotsCommand::Create(args) => {
                    let add_to_space =
                        validate_optional_positive_id_arg("--add-to-space", args.add_to_space)?;
                    let name = args.name.trim();
                    if name.is_empty() {
                        return Err(CliError::invalid_args("Bot name cannot be empty").into());
                    }
                    let username = args.username.trim().trim_start_matches('@');
                    if username.is_empty() {
                        return Err(CliError::invalid_args("Bot username cannot be empty").into());
                    }

                    let token = require_token(&auth_store)?;
                    let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::CreateBotInput {
                        name: name.to_string(),
                        username: username.to_string(),
                        add_to_space,
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::CreateBot,
                            proto::rpc_call::Input::CreateBot(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::CreateBot(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else if let Some(bot) = payload.bot.as_ref() {
                                println!(
                                    "Created bot {} (id {}).",
                                    user_display_name(bot),
                                    bot.id
                                );
                                println!(
                                    "To reveal token: inline bots reveal-token --bot-user-id {}",
                                    bot.id
                                );
                            } else {
                                println!("Created bot.");
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("createBot").into()),
                    }
                }
                BotsCommand::RevealToken(args) => {
                    let bot_user_id =
                        validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
                    let token = require_token(&auth_store)?;
                    let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::RevealBotTokenInput {
                        bot_user_id,
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::RevealBotToken,
                            proto::rpc_call::Input::RevealBotToken(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::RevealBotToken(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                println!("{}", payload.token);
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("revealBotToken").into()),
                    }
                }
            },
            Command::Typing { command } => {
                let (label, args, action) = match command {
                    TypingCommand::Start(args) => (
                        "started",
                        args,
                        Some(proto::update_compose_action::ComposeAction::Typing as i32),
                    ),
                    TypingCommand::Stop(args) => ("stopped", args, None),
                };
                let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                let token = require_token(&auth_store)?;
                let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;
                let input = proto::SendComposeActionInput {
                    peer_id: Some(peer.clone()),
                    action,
                };
                let result = realtime
                    .call_rpc(
                        proto::Method::SendComposeAction,
                        proto::rpc_call::Input::SendComposeAction(input),
                    )
                    .await?;
                match result {
                    proto::rpc_result::Result::SendComposeAction(payload) => {
                        if cli.json {
                            output::print_json(&payload, json_format)?;
                        } else {
                            println!("Typing {label} for {}.", peer_label_from_input(&peer));
                        }
                    }
                    _ => return Err(CliError::unexpected_rpc_result("sendComposeAction").into()),
                }
            }
            Command::Chats { command } => match command {
                ChatsCommand::List(args) => {
                    validate_table_only_list_flags(cli.json, args.ids, args.id)?;
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let result = realtime
                        .call_rpc(
                            proto::Method::GetChats,
                            proto::rpc_call::Input::GetChats(proto::GetChatsInput {}),
                        )
                        .await?;

                    match result {
                        proto::rpc_result::Result::GetChats(payload) => {
                            if cli.json {
                                let payload = apply_chat_list_filter(payload, args.filter.as_deref());
                                if args.limit.is_some() || args.offset.is_some() {
                                    let payload =
                                        apply_chat_list_limits(payload, args.limit, args.offset);
                                    output::print_json(&payload, json_format)?;
                                } else {
                                    output::print_json(&payload, json_format)?;
                                }
                            } else {
                                let current_user = local_db.load()?.current_user;
                                let output = build_chat_list(
                                    payload,
                                    current_user.as_ref(),
                                    args.limit,
                                    args.offset,
                                    args.filter.as_deref(),
                                )
                                ?;
                                if args.ids {
                                    for item in &output.items {
                                        println!("{}", item.chat.id);
                                    }
                                } else if args.id {
                                    if output.items.len() != 1 {
                                        return Err(CliError::invalid_args(format!(
                                            "Expected exactly 1 match for --id, got {}",
                                            output.items.len()
                                        ))
                                        .into());
                                    }
                                    if let Some(item) = output.items.first() {
                                        println!("{}", item.chat.id);
                                    }
                                } else {
                                    output::print_chat_list(&output, false, json_format)?;
                                }
                            }
                        }
                        _ => {
                            return Err(CliError::unexpected_rpc_result("getChats").into());
                        }
                    }
                }
                ChatsCommand::Get(args) => {
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::GetChatInput {
                        peer_id: Some(peer),
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::GetChat,
                            proto::rpc_call::Input::GetChat(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::GetChat(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else if let Some(chat) = payload.chat.as_ref() {
                                print_chat_details(chat, payload.dialog.as_ref());
                            } else {
                                println!("Chat not found.");
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("getChat").into()),
                    }
                }
                ChatsCommand::Participants(args) => {
                    let chat_id = validate_positive_id_arg("--chat-id", args.chat_id)?;
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::GetChatParticipantsInput { chat_id };
                    let result = realtime
                        .call_rpc(
                            proto::Method::GetChatParticipants,
                            proto::rpc_call::Input::GetChatParticipants(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::GetChatParticipants(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                let output = build_chat_participants_output(
                                    payload,
                                    current_epoch_seconds() as i64,
                                );
                                output::print_chat_participants(&output, false, json_format)?;
                            }
                        }
                        _ => {
                            return Err(
                                CliError::unexpected_rpc_result("getChatParticipants").into()
                            );
                        }
                    }
                }
                ChatsCommand::AddParticipant(args) => {
                    let chat_id = validate_positive_id_arg("--chat-id", args.chat_id)?;
                    let user_id = validate_positive_id_arg("--user-id", args.user_id)?;
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::AddChatParticipantInput { chat_id, user_id };
                    let result = realtime
                        .call_rpc(
                            proto::Method::AddChatParticipant,
                            proto::rpc_call::Input::AddChatParticipant(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::AddChatParticipant(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                println!("Added user {} to chat {}.", user_id, chat_id);
                            }
                        }
                        _ => {
                            return Err(
                                CliError::unexpected_rpc_result("addChatParticipant").into()
                            );
                        }
                    }
                }
                ChatsCommand::RemoveParticipant(args) => {
                    let chat_id = validate_positive_id_arg("--chat-id", args.chat_id)?;
                    let user_id = validate_positive_id_arg("--user-id", args.user_id)?;
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::RemoveChatParticipantInput { chat_id, user_id };
                    let result = realtime
                        .call_rpc(
                            proto::Method::RemoveChatParticipant,
                            proto::rpc_call::Input::RemoveChatParticipant(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::RemoveChatParticipant(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                println!("Removed user {} from chat {}.", user_id, chat_id);
                            }
                        }
                        _ => {
                            return Err(
                                CliError::unexpected_rpc_result("removeChatParticipant").into()
                            );
                        }
                    }
                }
                ChatsCommand::Create(args) => {
                    let space_id =
                        validate_optional_positive_id_arg("--space-id", args.space_id)?;
                    let title = args.title.trim();
                    if title.is_empty() {
                        return Err(CliError::invalid_args("Chat title cannot be empty").into());
                    }
                    if args.public && !args.participants.is_empty() {
                        return Err(CliError::invalid_args(
                            "Public chats cannot include explicit participants",
                        )
                        .into());
                    }
                    if space_id.is_none() {
                        if args.public {
                            return Err(CliError::invalid_args(
                                "Public home threads are not supported yet.",
                            )
                            .into());
                        }
                        if args.participants.is_empty() {
                            return Err(CliError::invalid_args(
                                "Provide at least one --participant for a home thread.",
                            )
                            .into());
                        }
                    }
                    validate_positive_ids_arg("--participant", &args.participants)?;
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let participants = args
                        .participants
                        .iter()
                        .map(|user_id| proto::InputChatParticipant { user_id: *user_id })
                        .collect();
                    let description = args.description.and_then(|value| {
                        let trimmed = value.trim();
                        if trimmed.is_empty() {
                            None
                        } else {
                            Some(trimmed.to_string())
                        }
                    });
                    let emoji = args.emoji.and_then(|value| {
                        let trimmed = value.trim();
                        if trimmed.is_empty() {
                            None
                        } else {
                            Some(trimmed.to_string())
                        }
                    });
                    let input = proto::CreateChatInput {
                        title: Some(title.to_string()),
                        space_id,
                        description,
                        emoji,
                        is_public: args.public,
                        participants,
                        reserved_chat_id: None,
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::CreateChat,
                            proto::rpc_call::Input::CreateChat(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::CreateChat(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else if let Some(chat) = payload.chat.as_ref() {
                                println!("Created chat {}.", chat.id);
                            } else {
                                println!("Created chat.");
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("createChat").into()),
                    }
                }
                ChatsCommand::CreateDm(args) => {
                    let user_id = validate_positive_id_arg("--user-id", args.user_id)?;
                    let token = require_token(&auth_store)?;
                    let payload = api.create_private_chat(&token, user_id).await?;
                    if cli.json {
                        output::print_json(&payload, json_format)?;
                    } else {
                        let chat_id = payload.chat.get("id").and_then(|value| value.as_i64());
                        if let Some(chat_id) = chat_id {
                            println!("Created DM chat {} with user {}.", chat_id, user_id);
                        } else {
                            println!("Created DM with user {}.", user_id);
                        }
                    }
                }
                ChatsCommand::UpdateVisibility(args) => {
                    let chat_id = validate_positive_id_arg("--chat-id", args.chat_id)?;
                    if args.public == args.private {
                        return Err(CliError::invalid_args("Provide --public or --private").into());
                    }
                    if args.public && !args.participants.is_empty() {
                        return Err(CliError::invalid_args(
                            "Public chats cannot include explicit participants",
                        )
                        .into());
                    }
                    if args.private && args.participants.is_empty() {
                        return Err(
                            CliError::invalid_args("Private chats require at least one participant.")
                                .into(),
                        );
                    }
                    validate_positive_ids_arg("--participant", &args.participants)?;

                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let participants = args
                        .participants
                        .iter()
                        .map(|user_id| proto::InputChatParticipant { user_id: *user_id })
                        .collect();
                    let input = proto::UpdateChatVisibilityInput {
                        chat_id,
                        is_public: args.public,
                        participants,
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::UpdateChatVisibility,
                            proto::rpc_call::Input::UpdateChatVisibility(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::UpdateChatVisibility(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                let label = if args.public { "public" } else { "private" };
                                if let Some(chat) = payload.chat.as_ref() {
                                    println!("Updated chat {} to {}.", chat.id, label);
                                } else {
                                    println!("Updated chat {} to {}.", chat_id, label);
                                }
                            }
                        }
                        _ => {
                            return Err(
                                CliError::unexpected_rpc_result("updateChatVisibility").into()
                            );
                        }
                    }
                }
                ChatsCommand::Rename(args) => {
                    let chat_id = validate_positive_id_arg("--chat-id", args.chat_id)?;
                    let title = args.title.trim();
                    if title.is_empty() {
                        return Err(CliError::invalid_args("Chat/thread title cannot be empty").into());
                    }
                    let emoji = args.emoji.and_then(|value| {
                        let trimmed = value.trim();
                        if trimmed.is_empty() {
                            None
                        } else {
                            Some(trimmed.to_string())
                        }
                    });

                    let token = require_token(&auth_store)?;
                    let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::UpdateChatInfoInput {
                        chat_id,
                        title: Some(title.to_string()),
                        emoji,
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::UpdateChatInfo,
                            proto::rpc_call::Input::UpdateChatInfo(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::UpdateChatInfo(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else if let Some(chat) = payload.chat.as_ref() {
                                println!("Renamed chat {} to \"{}\".", chat.id, chat.title);
                            } else {
                                println!("Renamed chat {}.", chat_id);
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("updateChatInfo").into()),
                    }
                }
                ChatsCommand::MarkUnread(args) => {
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::MarkAsUnreadInput {
                        peer_id: Some(peer),
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::MarkAsUnread,
                            proto::rpc_call::Input::MarkAsUnread(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::MarkAsUnread(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                println!("Marked as unread (updates: {}).", payload.updates.len());
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("markAsUnread").into()),
                    }
                }
                ChatsCommand::MarkRead(args) => {
                    let max_id = validate_optional_message_id_arg("--max-id", args.max_id)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let label = peer_label_from_input(&peer);
                    let token = require_token(&auth_store)?;
                    let input = api::ReadMessagesInput {
                        peer_user_id: args.user_id,
                        peer_thread_id: args.chat_id,
                        max_id,
                    };
                    let payload = api.read_messages(&token, input).await?;
                    if cli.json {
                        output::print_json(&payload, json_format)?;
                    } else if let Some(max_id) = max_id {
                        println!("Marked {label} as read (max id {max_id}).");
                    } else {
                        println!("Marked {label} as read.");
                    }
                }
                ChatsCommand::Delete(args) => {
                    let chat_id = validate_positive_id_arg("--chat-id", args.chat_id)?;
                    let prompt = format!("Delete chat {}? This cannot be undone.", chat_id);
                    if cli.json && !args.yes {
                        return Err(CliError::confirmation_required().into());
                    }
                    let token = require_token(&auth_store)?;
                    if !confirm_action(&prompt, args.yes)? {
                        println!("Cancelled.");
                        return Ok(());
                    }
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let peer = input_peer_from_args(Some(chat_id), None)?;
                    let input = proto::DeleteChatInput {
                        peer_id: Some(peer),
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::DeleteChat,
                            proto::rpc_call::Input::DeleteChat(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::DeleteChat(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                println!("Deleted chat {}.", chat_id);
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("deleteChat").into()),
                    }
                }
            },
            Command::Users { command } => match command {
                UsersCommand::List(args) => {
                    validate_table_only_list_flags(cli.json, args.ids, args.id)?;
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let result = realtime
                        .call_rpc(
                            proto::Method::GetChats,
                            proto::rpc_call::Input::GetChats(proto::GetChatsInput {}),
                        )
                        .await?;

                    match result {
                        proto::rpc_result::Result::GetChats(payload) => {
                            let mut payload = payload;
                            if cli.json {
                                filter_users_payload(&mut payload, args.filter.as_deref());
                                output::print_json(&payload, json_format)?;
                            } else {
                                let mut output = build_user_list(&payload);
                                filter_users_output(&mut output, args.filter.as_deref());
                                if args.ids {
                                    for user in &output.users {
                                        println!("{}", user.user.id);
                                    }
                                } else if args.id {
                                    if output.users.len() != 1 {
                                        return Err(CliError::invalid_args(format!(
                                            "Expected exactly 1 match for --id, got {}",
                                            output.users.len()
                                        ))
                                        .into());
                                    }
                                    if let Some(user) = output.users.first() {
                                        println!("{}", user.user.id);
                                    }
                                } else {
                                    output::print_users(&output, false, json_format)?;
                                }
                            }
                        }
                        _ => {
                            return Err(CliError::unexpected_rpc_result("getChats").into());
                        }
                    }
                }
                UsersCommand::Get(args) => {
                    let user_id = validate_positive_id_arg("--id", args.id)?;
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let result = realtime
                        .call_rpc(
                            proto::Method::GetChats,
                            proto::rpc_call::Input::GetChats(proto::GetChatsInput {}),
                        )
                        .await?;

                    match result {
                        proto::rpc_result::Result::GetChats(payload) => {
                            if cli.json {
                                if let Some(user) =
                                    payload.users.iter().find(|user| user.id == user_id)
                                {
                                    output::print_json(user, json_format)?;
                                } else {
                                    return Err(CliError::not_found_user_id(user_id).into());
                                }
                            } else {
                                let output = build_user_list(&payload);
                                if let Some(user) = output
                                    .users
                                    .into_iter()
                                    .find(|user| user.user.id == user_id)
                                {
                                    output::print_users(
                                        &UserListOutput { users: vec![user] },
                                        false,
                                        json_format,
                                    )?;
                                } else {
                                    return Err(CliError::not_found_user_id(user_id).into());
                                }
                            }
                        }
                        _ => {
                            return Err(CliError::unexpected_rpc_result("getChats").into());
                        }
                    }
                }
            },
            Command::Messages { command } => match command {
                MessagesCommand::List(args) => {
                    let limit = validate_message_limit(args.limit)?;
                    let offset_id = validate_optional_message_id_arg("--offset-id", args.offset_id)?;
                    let (since_ts, until_ts) =
                        parse_time_filters(args.since.as_deref(), args.until.as_deref(), Utc::now())?;
                    let translation_language = args
                        .translate
                        .as_deref()
                        .map(normalize_translation_language)
                        .transpose()?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let peer_summary = peer_summary_from_input(&peer);
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;

                    let input = proto::GetChatHistoryInput {
                        peer_id: Some(peer.clone()),
                        offset_id,
                        limit,
                        ..Default::default()
                    };

                    let result = realtime
                        .call_rpc(
                            proto::Method::GetChatHistory,
                            proto::rpc_call::Input::GetChatHistory(input),
                        )
                        .await?;

                    match result {
                        proto::rpc_result::Result::GetChatHistory(mut payload) => {
                            filter_messages_by_time(&mut payload.messages, since_ts, until_ts);
                            filter_messages_by_list_options(&mut payload.messages, &args);

                            if cli.json {
                                if let Some(language) = translation_language.as_deref() {
                                    let message_ids = collect_message_ids(&payload.messages);
                                    let translations_by_id = fetch_message_translations(
                                        &mut realtime,
                                        &peer,
                                        &message_ids,
                                        language,
                                    )
                                    .await?;
                                    let output = TranslatedChatHistoryOutput {
                                        payload,
                                        translations: translations_in_message_order(
                                            &message_ids,
                                            &translations_by_id,
                                        ),
                                    };
                                    output::print_json(&output, json_format)?;
                                } else {
                                    output::print_json(&payload, json_format)?;
                                }
                            } else {
                                let translations_by_id =
                                    if let Some(language) = translation_language.as_deref() {
                                        let message_ids = collect_message_ids(&payload.messages);
                                        fetch_message_translations(
                                            &mut realtime,
                                            &peer,
                                            &message_ids,
                                            language,
                                        )
                                        .await?
                                    } else {
                                        HashMap::new()
                                    };
                                let chats_result = realtime
                                    .call_rpc(
                                        proto::Method::GetChats,
                                        proto::rpc_call::Input::GetChats(proto::GetChatsInput {}),
                                    )
                                    .await?;
                                let (users_by_id, chats_by_id) = match chats_result {
                                    proto::rpc_result::Result::GetChats(chats_payload) => {
                                        let users = chats_payload
                                            .users
                                            .into_iter()
                                            .map(|user| (user.id, user))
                                            .collect();
                                        let chats = chats_payload
                                            .chats
                                            .into_iter()
                                            .map(|chat| (chat.id, chat))
                                            .collect();
                                        (users, chats)
                                    }
                                    _ => {
                                        return Err(
                                            CliError::unexpected_rpc_result("getChats").into()
                                        );
                                    }
                                };
                                let current_user_id =
                                    local_db.load()?.current_user.map(|user| user.id);
                                let output = build_message_list(
                                    payload,
                                    &users_by_id,
                                    current_user_id,
                                    peer_summary,
                                    peer_name_from_input(&peer, &users_by_id, &chats_by_id),
                                    Some(&translations_by_id),
                                );
                                output::print_messages(&output, false, json_format)?;
                            }
                        }
                        _ => {
                            return Err(CliError::unexpected_rpc_result("getChatHistory").into());
                        }
                    }
                }
                MessagesCommand::Search(args) => {
                    let limit = validate_message_limit(args.limit)?;
                    let (since_ts, until_ts) =
                        parse_time_filters(args.since.as_deref(), args.until.as_deref(), Utc::now())?;
                    let translation_language = args
                        .translate
                        .as_deref()
                        .map(normalize_translation_language)
                        .transpose()?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let queries = normalize_search_queries(&args.query)?;
                    let peer_summary = peer_summary_from_input(&peer);
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;

                    let input = proto::SearchMessagesInput {
                        peer_id: Some(peer.clone()),
                        queries,
                        limit,
                        offset_id: None,
                        filter: None,
                    };

                    let result = realtime
                        .call_rpc(
                            proto::Method::SearchMessages,
                            proto::rpc_call::Input::SearchMessages(input),
                        )
                        .await?;

                    match result {
                        proto::rpc_result::Result::SearchMessages(mut payload) => {
                            filter_messages_by_time(&mut payload.messages, since_ts, until_ts);

                            if cli.json {
                                if let Some(language) = translation_language.as_deref() {
                                    let message_ids = collect_message_ids(&payload.messages);
                                    let translations_by_id = fetch_message_translations(
                                        &mut realtime,
                                        &peer,
                                        &message_ids,
                                        language,
                                    )
                                    .await?;
                                    let output = TranslatedSearchMessagesOutput {
                                        payload,
                                        translations: translations_in_message_order(
                                            &message_ids,
                                            &translations_by_id,
                                        ),
                                    };
                                    output::print_json(&output, json_format)?;
                                } else {
                                    output::print_json(&payload, json_format)?;
                                }
                            } else {
                                let translations_by_id =
                                    if let Some(language) = translation_language.as_deref() {
                                        let message_ids = collect_message_ids(&payload.messages);
                                        fetch_message_translations(
                                            &mut realtime,
                                            &peer,
                                            &message_ids,
                                            language,
                                        )
                                        .await?
                                    } else {
                                        HashMap::new()
                                    };
                                let chats_result = realtime
                                    .call_rpc(
                                        proto::Method::GetChats,
                                        proto::rpc_call::Input::GetChats(proto::GetChatsInput {}),
                                    )
                                    .await?;
                                let (users_by_id, chats_by_id) = match chats_result {
                                    proto::rpc_result::Result::GetChats(chats_payload) => {
                                        let users = chats_payload
                                            .users
                                            .into_iter()
                                            .map(|user| (user.id, user))
                                            .collect();
                                        let chats = chats_payload
                                            .chats
                                            .into_iter()
                                            .map(|chat| (chat.id, chat))
                                            .collect();
                                        (users, chats)
                                    }
                                    _ => {
                                        return Err(
                                            CliError::unexpected_rpc_result("getChats").into()
                                        );
                                    }
                                };
                                let current_user_id =
                                    local_db.load()?.current_user.map(|user| user.id);
                                let output = build_message_list_from_messages(
                                    &payload.messages,
                                    &users_by_id,
                                    current_user_id,
                                    peer_summary,
                                    peer_name_from_input(&peer, &users_by_id, &chats_by_id),
                                    Some(&translations_by_id),
                                );
                                output::print_messages(&output, false, json_format)?;
                            }
                        }
                        _ => {
                            return Err(CliError::unexpected_rpc_result("searchMessages").into());
                        }
                    }
                }
                MessagesCommand::Get(args) => {
                    let message_ids = parse_message_id_selectors("--message-id", &args.message_ids)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let peer_label = peer_label_from_input(&peer);
                    let translation_language = args
                        .translate
                        .as_deref()
                        .map(normalize_translation_language)
                        .transpose()?;
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let (messages, missing_message_ids) =
                        fetch_messages_by_ids(&mut realtime, &peer, &message_ids).await?;
                    if message_ids.len() == 1 {
                        let message = messages.into_iter().next().ok_or_else(|| {
                            CliError::invalid_args("Message not found for that peer.")
                        })?;
                        if cli.json {
                            if let Some(language) = translation_language.as_deref() {
                                let message_ids = [message.id];
                                let translations_by_id = fetch_message_translations(
                                    &mut realtime,
                                    &peer,
                                    &message_ids,
                                    language,
                                )
                                .await?;
                                let output = TranslatedMessageOutput {
                                    message,
                                    translations: translations_in_message_order(
                                        &message_ids,
                                        &translations_by_id,
                                    ),
                                };
                                output::print_json(&output, json_format)?;
                            } else {
                                output::print_json(&message, json_format)?;
                            }
                        } else {
                            let translations_by_id =
                                if let Some(language) = translation_language.as_deref() {
                                    fetch_message_translations(
                                        &mut realtime,
                                        &peer,
                                        &[message.id],
                                        language,
                                    )
                                    .await?
                                } else {
                                    HashMap::new()
                                };
                            let chats_result = realtime
                                .call_rpc(
                                    proto::Method::GetChats,
                                    proto::rpc_call::Input::GetChats(proto::GetChatsInput {}),
                                )
                                .await?;
                            let users_by_id = match chats_result {
                                proto::rpc_result::Result::GetChats(chats_payload) => chats_payload
                                    .users
                                    .into_iter()
                                    .map(|user| (user.id, user))
                                    .collect(),
                                _ => return Err(CliError::unexpected_rpc_result("getChats").into()),
                            };
                            let current_user_id = local_db.load()?.current_user.map(|user| user.id);
                            let summary = message_summary(
                                &message,
                                &users_by_id,
                                current_user_id,
                                current_epoch_seconds() as i64,
                                Some(&translations_by_id),
                            );
                            print_message_detail(&summary, &peer_label);
                        }
                    } else if cli.json {
                        let translations = if let Some(language) = translation_language.as_deref() {
                            let found_ids = collect_message_ids(&messages);
                            let translations_by_id = fetch_message_translations(
                                &mut realtime,
                                &peer,
                                &found_ids,
                                language,
                            )
                            .await?;
                            translations_in_message_order(&found_ids, &translations_by_id)
                        } else {
                            Vec::new()
                        };
                        let output = MessagesGetBatchOutput {
                            messages,
                            missing_message_ids,
                            translations,
                        };
                        output::print_json(&output, json_format)?;
                    } else {
                        let translations_by_id =
                            if let Some(language) = translation_language.as_deref() {
                                let found_ids = collect_message_ids(&messages);
                                fetch_message_translations(
                                    &mut realtime,
                                    &peer,
                                    &found_ids,
                                    language,
                                )
                                .await?
                            } else {
                                HashMap::new()
                            };
                        let chats_result = realtime
                            .call_rpc(
                                proto::Method::GetChats,
                                proto::rpc_call::Input::GetChats(proto::GetChatsInput {}),
                            )
                            .await?;
                        let (users_by_id, chats_by_id) = match chats_result {
                            proto::rpc_result::Result::GetChats(chats_payload) => {
                                let users = chats_payload
                                    .users
                                    .into_iter()
                                    .map(|user| (user.id, user))
                                    .collect();
                                let chats = chats_payload
                                    .chats
                                    .into_iter()
                                    .map(|chat| (chat.id, chat))
                                    .collect();
                                (users, chats)
                            }
                            _ => return Err(CliError::unexpected_rpc_result("getChats").into()),
                        };
                        let current_user_id = local_db.load()?.current_user.map(|user| user.id);
                        let output = build_message_list_from_messages(
                            &messages,
                            &users_by_id,
                            current_user_id,
                            peer_summary_from_input(&peer),
                            peer_name_from_input(&peer, &users_by_id, &chats_by_id),
                            Some(&translations_by_id),
                        );
                        output::print_messages(&output, false, json_format)?;
                        if !missing_message_ids.is_empty() {
                            eprintln!(
                                "Warning: {} message id(s) were not found: {}",
                                missing_message_ids.len(),
                                missing_message_ids
                                    .iter()
                                    .map(ToString::to_string)
                                    .collect::<Vec<_>>()
                                    .join(",")
                            );
                        }
                    }
                }
                MessagesCommand::Send(args) => {
                    let reply_to = validate_optional_message_id_arg("--reply-to", args.reply_to)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let caption = resolve_message_caption(args.text, args.stdin)?;
                    let mention_entities = parse_mention_entities(&args.mentions)?;
                    if mention_entities.is_some() && caption.is_none() {
                        return Err(CliError::mentions_require_text().into());
                    }
                    if args.attachments.is_empty() && caption.is_none() {
                        return Err(CliError::invalid_args(
                            "Missing required argument: provide --text/--message/--msg, --stdin, or --attach",
                        )
                        .into());
                    }
                    validate_attachment_inputs(&args.attachments, MAX_ATTACHMENT_BYTES)?;
                    let token = require_token(&auth_store)?;
                    let attachments = prepare_attachments(
                        &args.attachments,
                        &config.data_dir,
                        args.force_file,
                        cli.json,
                    )?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    if attachments.is_empty() {
                        let text = caption
                            .ok_or_else(|| {
                                CliError::invalid_args(
                                    "Missing required argument: provide --text/--message/--msg, --stdin, or --attach",
                                )
                            })?;
                        let payload = send_message(
                            &mut realtime,
                            &peer,
                            Some(text),
                            None,
                            true,
                            reply_to,
                            mention_entities,
                        )
                        .await?;
                        if cli.json {
                            output::print_json(&payload, json_format)?;
                        } else {
                            println!("Message sent (updates: {}).", payload.updates.len());
                        }
                    } else {
                        let peer_summary = peer_summary_from_input(&peer);
                        let output = send_messages_with_attachments(
                            &api,
                            &mut realtime,
                            &token,
                            &peer,
                            caption,
                            reply_to,
                            mention_entities,
                            attachments,
                            peer_summary,
                            cli.json,
                        )
                        .await?;
                        if cli.json {
                            output::print_json(&output, json_format)?;
                        }
                    }
                }
                MessagesCommand::Forward(args) => {
                    let MessagesForwardArgs {
                        from_chat_id,
                        from_user_id,
                        message_ids,
                        to_chat_id,
                        to_user_id,
                        no_header,
                    } = args;

                    if message_ids.is_empty() {
                        return Err(CliError::missing_message_ids().into());
                    }
                    validate_message_ids_arg("--message-id", &message_ids)?;

                    let from_peer = match (from_chat_id, from_user_id) {
                        (Some(_), Some(_)) => {
                            return Err(CliError::invalid_args(
                                "Provide only one of --from-chat-id or --from-user-id",
                            )
                            .into());
                        }
                        (Some(chat_id), None) => {
                            let chat_id = validate_positive_id_arg("--from-chat-id", chat_id)?;
                            proto::InputPeer {
                                r#type: Some(proto::input_peer::Type::Chat(
                                    proto::InputPeerChat { chat_id },
                                )),
                            }
                        }
                        (None, Some(user_id)) => {
                            let user_id = validate_positive_id_arg("--from-user-id", user_id)?;
                            proto::InputPeer {
                                r#type: Some(proto::input_peer::Type::User(
                                    proto::InputPeerUser { user_id },
                                )),
                            }
                        }
                        (None, None) => return Err(CliError::missing_forward_source().into()),
                    };

                    let to_peer = match (to_chat_id, to_user_id) {
                        (Some(_), Some(_)) => {
                            return Err(CliError::invalid_args(
                                "Provide only one of --to-chat-id or --to-user-id",
                            )
                            .into());
                        }
                        (Some(chat_id), None) => {
                            let chat_id = validate_positive_id_arg("--to-chat-id", chat_id)?;
                            proto::InputPeer {
                                r#type: Some(proto::input_peer::Type::Chat(
                                    proto::InputPeerChat { chat_id },
                                )),
                            }
                        }
                        (None, Some(user_id)) => {
                            let user_id = validate_positive_id_arg("--to-user-id", user_id)?;
                            proto::InputPeer {
                                r#type: Some(proto::input_peer::Type::User(
                                    proto::InputPeerUser { user_id },
                                )),
                            }
                        }
                        (None, None) => return Err(CliError::missing_forward_destination().into()),
                    };

                    let from_label = peer_label_from_input(&from_peer);
                    let to_label = peer_label_from_input(&to_peer);
                    let message_count = message_ids.len();
                    let share_forward_header = if no_header { Some(false) } else { None };

                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::ForwardMessagesInput {
                        from_peer_id: Some(from_peer),
                        message_ids,
                        to_peer_id: Some(to_peer),
                        share_forward_header,
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::ForwardMessages,
                            proto::rpc_call::Input::ForwardMessages(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::ForwardMessages(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                println!(
                                    "Forwarded {} message(s) from {} to {} (updates: {}).",
                                    message_count,
                                    from_label,
                                    to_label,
                                    payload.updates.len()
                                );
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("forwardMessages").into()),
                    }
                }
                MessagesCommand::Export(args) => {
                    handle_messages_export(
                        args,
                        &config,
                        &auth_store,
                        cli.json,
                        json_format,
                        MessageExportFormat::Json,
                    )
                    .await?;
                }
                MessagesCommand::Transcript(args) => {
                    handle_messages_export(
                        args.into(),
                        &config,
                        &auth_store,
                        cli.json,
                        json_format,
                        MessageExportFormat::Markdown,
                    )
                    .await?;
                }
                MessagesCommand::Download(args) => {
                    if args.message_ids.is_empty() && args.from_msg_id.is_none() {
                        return Err(CliError::missing_message_ids().into());
                    }
                    if args.limit.is_some() && args.from_msg_id.is_none() {
                        return Err(CliError::invalid_args(
                            "--limit requires --from-msg-id for downloads",
                        )
                        .into());
                    }
                    let message_ids = if args.message_ids.is_empty() {
                        Vec::new()
                    } else {
                        parse_message_id_selectors("--message-id", &args.message_ids)?
                    };
                    let from_msg_id =
                        validate_optional_message_id_arg("--from-msg-id", args.from_msg_id)?;
                    let limit = validate_message_limit(args.limit)?;
                    let parallel = validate_download_parallel(args.parallel)?;
                    let history_window_download = from_msg_id.is_some();
                    let batch_download = history_window_download || message_ids.len() > 1;
                    if batch_download && args.output.is_some() {
                        return Err(CliError::invalid_args(
                            "--output can only be used with one --message-id; use --dir for batch or history-window downloads",
                        )
                        .into());
                    }
                    if batch_download && args.dir.is_none() {
                        return Err(CliError::invalid_args(
                            "Batch and history-window downloads require --dir so every file has a destination directory",
                        )
                        .into());
                    }
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    if let Some(output) = args.output.as_ref() {
                        validate_output_file_path_arg("--output", output)?;
                    }
                    if let Some(dir) = args.dir.as_ref() {
                        validate_output_dir_path_arg("--dir", dir)?;
                    }
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let (messages, missing_message_ids) = if let Some(from_msg_id) = from_msg_id {
                        (
                            fetch_history_messages(&mut realtime, &peer, Some(from_msg_id), limit)
                                .await?,
                            Vec::new(),
                        )
                    } else {
                        fetch_messages_by_ids(&mut realtime, &peer, &message_ids).await?
                    };
                    if !history_window_download && message_ids.len() == 1 {
                        let message = messages.into_iter().next().ok_or_else(|| {
                            CliError::invalid_args("Message not found for that peer.")
                        })?;
                        let output_path = resolve_download_path(&message, args.output, args.dir)?;
                        let bytes = download_message_media(&message, &output_path).await?;
                        if cli.json {
                            let output = DownloadOutput {
                                path: output_path.display().to_string(),
                                bytes,
                            };
                            output::print_json(&output, json_format)?;
                        } else {
                            println!("Downloaded to {}", output_path.display());
                        }
                    } else {
                        let Some(dir) = args.dir else {
                            unreachable!("batch download directory is validated before auth");
                        };
                        let summary = download_messages_media(&messages, &dir, parallel).await?;

                        let output = DownloadBatchOutput {
                            files: summary.files,
                            skipped_message_ids: summary.skipped_message_ids,
                            missing_message_ids,
                            errors: summary.errors,
                        };
                        if cli.json {
                            output::print_json(&output, json_format)?;
                        } else {
                            print_download_batch_summary(&output, &dir);
                        }
                    }
                }
                MessagesCommand::Delete(args) => {
                    if args.message_ids.is_empty() {
                        return Err(CliError::missing_message_ids().into());
                    }
                    validate_message_ids_arg("--message-id", &args.message_ids)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let message_count = args.message_ids.len();
                    let prompt = format!(
                        "Delete {} message(s) from {}?",
                        message_count,
                        peer_label_from_input(&peer)
                    );
                    if cli.json && !args.yes {
                        return Err(CliError::confirmation_required().into());
                    }
                    let token = require_token(&auth_store)?;
                    if !confirm_action(&prompt, args.yes)? {
                        println!("Cancelled.");
                        return Ok(());
                    }
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::DeleteMessagesInput {
                        message_ids: args.message_ids,
                        peer_id: Some(peer),
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::DeleteMessages,
                            proto::rpc_call::Input::DeleteMessages(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::DeleteMessages(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                println!(
                                    "Deleted {} message(s) (updates: {}).",
                                    message_count,
                                    payload.updates.len()
                                );
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("deleteMessages").into()),
                    }
                }
                MessagesCommand::Edit(args) => {
                    let message_id = validate_message_id_arg("--message-id", args.message_id)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let text = resolve_message_caption(args.text, args.stdin)?
                        .ok_or_else(CliError::missing_text_or_stdin)?;
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::EditMessageInput {
                        message_id,
                        peer_id: Some(peer),
                        text,
                        entities: None,
                        parse_markdown: None,
                        actions: None,
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::EditMessage,
                            proto::rpc_call::Input::EditMessage(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::EditMessage(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                println!("Message edited (updates: {}).", payload.updates.len());
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("editMessage").into()),
                    }
                }
                MessagesCommand::AddReaction(args) => {
                    let message_id = validate_message_id_arg("--message-id", args.message_id)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let emoji = args.emoji.trim().to_string();
                    if emoji.is_empty() {
                        return Err(CliError::invalid_args("Emoji cannot be empty").into());
                    }
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::AddReactionInput {
                        emoji,
                        message_id,
                        peer_id: Some(peer),
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::AddReaction,
                            proto::rpc_call::Input::AddReaction(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::AddReaction(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                println!("Reaction added (updates: {}).", payload.updates.len());
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("addReaction").into()),
                    }
                }
                MessagesCommand::DeleteReaction(args) => {
                    let message_id = validate_message_id_arg("--message-id", args.message_id)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let emoji = args.emoji.trim().to_string();
                    if emoji.is_empty() {
                        return Err(CliError::invalid_args("Emoji cannot be empty").into());
                    }
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::DeleteReactionInput {
                        emoji,
                        peer_id: Some(peer),
                        message_id,
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::DeleteReaction,
                            proto::rpc_call::Input::DeleteReaction(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::DeleteReaction(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                println!("Reaction deleted (updates: {}).", payload.updates.len());
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("deleteReaction").into()),
                    }
                }
            },
            Command::Spaces { command } => match command {
                SpacesCommand::List => {
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let result = realtime
                        .call_rpc(
                            proto::Method::GetChats,
                            proto::rpc_call::Input::GetChats(proto::GetChatsInput {}),
                        )
                        .await?;

                    match result {
                        proto::rpc_result::Result::GetChats(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                let output = build_space_list(&payload);
                                output::print_spaces(&output, false, json_format)?;
                            }
                        }
                        _ => {
                            return Err(CliError::unexpected_rpc_result("getChats").into());
                        }
                    }
                }
                SpacesCommand::Members(args) => {
                    let space_id = validate_positive_id_arg("--space-id", args.space_id)?;
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::GetSpaceMembersInput { space_id };
                    let result = realtime
                        .call_rpc(
                            proto::Method::GetSpaceMembers,
                            proto::rpc_call::Input::GetSpaceMembers(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::GetSpaceMembers(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                let output = build_space_members_output(payload);
                                output::print_space_members(&output, false, json_format)?;
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("getSpaceMembers").into()),
                    }
                }
                SpacesCommand::Invite(args) => {
                    let space_id = validate_positive_id_arg("--space-id", args.space_id)?;
                    let via = invite_target_from_args(&args)?;
                    let role = invite_role_from_args(args.admin, args.public_chats)?;
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::InviteToSpaceInput {
                        space_id,
                        role,
                        via: Some(via),
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::InviteToSpace,
                            proto::rpc_call::Input::InviteToSpace(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::InviteToSpace(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                let name = payload
                                    .user
                                    .as_ref()
                                    .map(user_display_name)
                                    .unwrap_or_else(|| "user".to_string());
                                println!("Invited {} to space {}.", name, space_id);
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("inviteToSpace").into()),
                    }
                }
                SpacesCommand::DeleteMember(args) => {
                    let space_id = validate_positive_id_arg("--space-id", args.space_id)?;
                    let user_id = validate_positive_id_arg("--user-id", args.user_id)?;
                    let prompt = format!("Remove user {} from space {}?", user_id, space_id);
                    if cli.json && !args.yes {
                        return Err(CliError::confirmation_required().into());
                    }
                    let token = require_token(&auth_store)?;
                    if !confirm_action(&prompt, args.yes)? {
                        println!("Cancelled.");
                        return Ok(());
                    }
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::DeleteMemberInput { space_id, user_id };
                    let result = realtime
                        .call_rpc(
                            proto::Method::DeleteMember,
                            proto::rpc_call::Input::DeleteMember(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::DeleteMember(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                println!("Member removed (updates: {}).", payload.updates.len());
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("deleteMember").into()),
                    }
                }
                SpacesCommand::UpdateMemberAccess(args) => {
                    let space_id = validate_positive_id_arg("--space-id", args.space_id)?;
                    let user_id = validate_positive_id_arg("--user-id", args.user_id)?;
                    let role =
                        require_member_access_role(args.admin, args.member, args.public_chats)?;
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::UpdateMemberAccessInput {
                        space_id,
                        user_id,
                        role: Some(role),
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::UpdateMemberAccess,
                            proto::rpc_call::Input::UpdateMemberAccess(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::UpdateMemberAccess(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                println!(
                                    "Updated member access (updates: {}).",
                                    payload.updates.len()
                                );
                            }
                        }
                        _ => {
                            return Err(
                                CliError::unexpected_rpc_result("updateMemberAccess").into()
                            );
                        }
                    }
                }
            },
            Command::Notifications { command } => match command {
                NotificationsCommand::Get => {
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let result = realtime
                        .call_rpc(
                            proto::Method::GetUserSettings,
                            proto::rpc_call::Input::GetUserSettings(
                                proto::GetUserSettingsInput {},
                            ),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::GetUserSettings(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                print_notification_settings(payload.user_settings.as_ref());
                            }
                        }
                        _ => return Err(CliError::unexpected_rpc_result("getUserSettings").into()),
                    }
                }
                NotificationsCommand::Set(args) => {
                    if args.mode.is_none() && !args.silent && !args.sound {
                        return Err(CliError::invalid_args(
                            "Provide at least one of --mode, --silent, or --sound",
                        )
                        .into());
                    }
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let current = fetch_user_settings(&mut realtime).await?;
                    let mut values = notification_settings_values(
                        current
                            .as_ref()
                            .and_then(|settings| settings.notification_settings.as_ref()),
                    );
                    if let Some(mode) = args.mode {
                        values.mode = notification_mode_from_arg(mode);
                        values.disable_dm_notifications =
                            values.mode == proto::notification_settings::Mode::OnlyMentions;
                    }
                    if args.silent {
                        values.silent = true;
                    } else if args.sound {
                        values.silent = false;
                    }

                    let notification_settings = proto::NotificationSettings {
                        mode: Some(values.mode as i32),
                        silent: Some(values.silent),
                        disable_dm_notifications: Some(values.disable_dm_notifications),
                        ..Default::default()
                    };
                    let user_settings = proto::UserSettings {
                        notification_settings: Some(notification_settings),
                    };
                    let input = proto::UpdateUserSettingsInput {
                        user_settings: Some(user_settings),
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::UpdateUserSettings,
                            proto::rpc_call::Input::UpdateUserSettings(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::UpdateUserSettings(payload) => {
                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                println!(
                                    "Notification settings updated (updates: {}).",
                                    payload.updates.len()
                                );
                            }
                        }
                        _ => {
                            return Err(
                                CliError::unexpected_rpc_result("updateUserSettings").into()
                            );
                        }
                    }
                }
            },
            Command::Tasks { command } => match command {
                TasksCommand::CreateLinear(args) => {
                    let chat_id = validate_positive_id_arg("--chat-id", args.chat_id)?;
                    let message_id = validate_message_id_arg("--message-id", args.message_id)?;
                    let space_id =
                        validate_optional_positive_id_arg("--space-id", args.space_id)?;
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;

                    // Get current user id
                    let me = fetch_me(&mut realtime).await?;
                    let from_id = me.id;

                    // Get message to extract text
                    let peer = input_peer_from_args(Some(chat_id), None)?;
                    let message = fetch_message_by_id(&mut realtime, &peer, message_id).await?;

                    let text = message.message.unwrap_or_default();
                    if text.trim().is_empty() {
                        return Err(
                            CliError::invalid_args("Message has no text content").into()
                        );
                    }

                    let api_input = CreateLinearIssueInput {
                        text,
                        message_id,
                        chat_id,
                        from_id,
                        peer_user_id: None,
                        peer_thread_id: Some(chat_id),
                        space_id,
                    };

                    let result = api.create_linear_issue(&token, api_input).await?;

                    if cli.json {
                        output::print_json(&result, json_format)?;
                    } else if let Some(link) = result.link {
                        println!("Created Linear issue: {}", link);
                    } else {
                        println!("Linear issue created.");
                    }
                }
                TasksCommand::CreateNotion(args) => {
                    let chat_id = validate_positive_id_arg("--chat-id", args.chat_id)?;
                    let message_id = validate_message_id_arg("--message-id", args.message_id)?;
                    let space_id = validate_positive_id_arg("--space-id", args.space_id)?;
                    let token = require_token(&auth_store)?;

                    let api_input = CreateNotionTaskInput {
                        space_id,
                        message_id,
                        chat_id,
                        peer_user_id: None,
                        peer_thread_id: Some(chat_id),
                    };

                    let result = api.create_notion_task(&token, api_input).await?;

                    if cli.json {
                        output::print_json(&result, json_format)?;
                    } else {
                        let title_display = result
                            .task_title
                            .map(|t| format!(" \"{}\"", t))
                            .unwrap_or_default();
                        println!("Created Notion task{}: {}", title_display, result.url);
                    }
                }
            },
        }

        Ok::<(), Box<dyn std::error::Error>>(())
    }
    .await;

    // Auto-update check is informational. Only wait for it when:
    // - stdout is a TTY (interactive use)
    // - the command already took "long enough" (avoid a latency tax on fast commands)
    if update_handle.is_some()
        && !cli.json
        && io::stdout().is_terminal()
        && started_at.elapsed() >= Duration::from_millis(900)
    {
        update::finish_update_check(update_handle).await;
    }
    result
}

fn confirm_action(prompt: &str, assume_yes: bool) -> Result<bool, Box<dyn std::error::Error>> {
    if assume_yes {
        return Ok(true);
    }
    if !is_interactive_terminal() {
        return Err(CliError::confirmation_required().into());
    }
    let confirmed = Confirm::new()
        .with_prompt(prompt)
        .default(false)
        .interact()?;
    Ok(confirmed)
}

fn require_stdin_pipe(stdin_is_terminal: bool) -> Result<(), Box<dyn std::error::Error>> {
    if stdin_is_terminal {
        Err(CliError::stdin_not_piped().into())
    } else {
        Ok(())
    }
}

fn resolve_message_caption(
    text: Option<String>,
    stdin: bool,
) -> Result<Option<String>, Box<dyn std::error::Error>> {
    if stdin {
        require_stdin_pipe(std::io::stdin().is_terminal())?;
        use std::io::Read;
        let mut buffer = String::new();
        std::io::stdin().read_to_string(&mut buffer)?;
        let trimmed = buffer.trim();
        if trimmed.is_empty() {
            return Err(CliError::invalid_args("stdin was empty").into());
        }
        return Ok(Some(trimmed.to_string()));
    }

    if let Some(text) = text {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return Err(CliError::invalid_args("message text is empty").into());
        }
        return Ok(Some(trimmed.to_string()));
    }

    Ok(None)
}

async fn send_message(
    realtime: &mut RealtimeClient,
    peer: &proto::InputPeer,
    text: Option<String>,
    media: Option<proto::InputMedia>,
    parse_markdown: bool,
    reply_to_msg_id: Option<i64>,
    entities: Option<proto::MessageEntities>,
) -> Result<proto::SendMessageResult, Box<dyn std::error::Error>> {
    let mut rng = OsRng;
    let random_id: i64 = rng.next_u64() as i64;
    let send_date = current_epoch_seconds() as i64;

    let input = proto::SendMessageInput {
        peer_id: Some(peer.clone()),
        message: text,
        reply_to_msg_id,
        random_id: Some(random_id),
        media,
        temporary_send_date: Some(send_date),
        is_sticker: None,
        has_link: None,
        entities,
        parse_markdown: Some(parse_markdown),
        send_mode: None,
        actions: None,
    };

    let result = realtime
        .call_rpc(
            proto::Method::SendMessage,
            proto::rpc_call::Input::SendMessage(input),
        )
        .await?;

    match result {
        proto::rpc_result::Result::SendMessage(payload) => Ok(payload),
        _ => Err(CliError::unexpected_rpc_result("sendMessage").into()),
    }
}

#[allow(clippy::too_many_arguments)]
async fn send_messages_with_attachments(
    api: &ApiClient,
    realtime: &mut RealtimeClient,
    token: &str,
    peer: &proto::InputPeer,
    caption: Option<String>,
    reply_to_msg_id: Option<i64>,
    mention_entities: Option<proto::MessageEntities>,
    attachments: Vec<PreparedAttachment>,
    peer_summary: Option<PeerSummary>,
    json: bool,
) -> Result<proto::SendMessageResult, Box<dyn std::error::Error>> {
    let total = attachments.len();
    let mut updates = Vec::new();
    for (idx, attachment) in attachments.iter().enumerate() {
        let progress = format!(
            "Uploading ({}/{}) {}...",
            idx + 1,
            total,
            attachment.display_name
        );
        if !json {
            println!("{progress}");
        }

        let upload = api.upload_file(token, attachment.to_upload_input()).await?;

        let media = input_media_from_upload(&upload)?;
        let send = send_message(
            realtime,
            peer,
            caption.clone(),
            Some(media),
            caption.is_some(),
            reply_to_msg_id,
            mention_entities.clone(),
        )
        .await?;
        let updates_len = send.updates.len();
        updates.extend(send.updates);
        if !json {
            println!(
                "Sent {} (updates: {}).",
                attachment.display_name, updates_len
            );
        }
    }

    let _ = (peer_summary, caption);
    Ok(proto::SendMessageResult { updates })
}

async fn handle_messages_export(
    args: MessagesExportArgs,
    config: &Config,
    auth_store: &AuthStore,
    json: bool,
    json_format: output::JsonFormat,
    default_format: MessageExportFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let limit = validate_message_limit(args.limit)?;
    let offset_id = validate_optional_message_id_arg("--offset-id", args.offset_id)?;
    let from_msg_id = validate_optional_message_id_arg("--from-msg-id", args.from_msg_id)?;
    let history_offset_id = from_msg_id.or(offset_id);
    let (since_ts, until_ts) =
        parse_time_filters(args.since.as_deref(), args.until.as_deref(), Utc::now())?;
    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
    let requested_output_path = args.output;
    let output_bundle_dir = requested_output_path
        .as_ref()
        .filter(|path| is_export_output_bundle_dir(path, args.download_media))
        .cloned();
    let format_inference_path = if output_bundle_dir.is_some() {
        None
    } else {
        requested_output_path.as_deref()
    };
    let format = infer_export_format(args.format, format_inference_path, default_format);
    let output_path =
        resolve_export_output_path(requested_output_path, output_bundle_dir.as_deref(), format);
    if let Some(output_path) = output_path.as_ref() {
        validate_output_file_path_arg("--output", output_path)?;
    }
    let media_download = resolve_export_media_download(
        args.download_media,
        args.media_dir,
        args.parallel,
        output_path.as_deref(),
        output_bundle_dir.as_deref(),
    )?;
    if let Some((media_dir, _)) = media_download.as_ref() {
        validate_output_dir_path_arg("--media-dir", media_dir)?;
    }
    let token = require_token(auth_store)?;
    let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;

    let mut messages = if args.message_ids.is_empty() {
        fetch_history_messages(&mut realtime, &peer, history_offset_id, limit).await?
    } else {
        let message_ids = parse_message_id_selectors("--message-id", &args.message_ids)?;
        let (messages, missing_message_ids) =
            fetch_messages_by_ids(&mut realtime, &peer, &message_ids).await?;
        if !missing_message_ids.is_empty() {
            eprintln!(
                "Warning: {} message id(s) were not found: {}",
                missing_message_ids.len(),
                missing_message_ids
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(",")
            );
        }
        messages
    };
    filter_messages_by_time(&mut messages, since_ts, until_ts);

    let (users_by_id, chats_by_id, spaces_by_id) = fetch_export_indexes(&mut realtime).await?;
    let mut warnings = Vec::new();
    let mut related_messages_by_id = messages
        .iter()
        .cloned()
        .map(|message| (message.id, message))
        .collect::<HashMap<_, _>>();
    let missing_reply_ids = collect_missing_reply_ids(&messages, &related_messages_by_id);
    if !missing_reply_ids.is_empty() {
        let (reply_messages, missing_message_ids) =
            fetch_messages_by_ids(&mut realtime, &peer, &missing_reply_ids).await?;
        for message in reply_messages {
            related_messages_by_id.insert(message.id, message);
        }
        if !missing_message_ids.is_empty() {
            warnings.push(format!(
                "Could not resolve {} reply target(s): {}",
                missing_message_ids.len(),
                missing_message_ids
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(",")
            ));
        }
    }

    let mut forward_messages_by_key = HashMap::new();
    for (source_peer, message_ids) in collect_forward_sources(&messages) {
        let Some(input_peer) = input_peer_from_proto_peer(&source_peer) else {
            warnings.push("Could not resolve a forwarded source peer.".to_string());
            continue;
        };
        let (forward_messages, missing_message_ids) =
            fetch_messages_by_ids(&mut realtime, &input_peer, &message_ids).await?;
        for message in forward_messages {
            if let Some(key) = forward_source_key(&source_peer, message.id) {
                forward_messages_by_key.insert(key, message);
            }
        }
        if !missing_message_ids.is_empty() {
            warnings.push(format!(
                "Could not resolve {} forwarded source message(s): {}",
                missing_message_ids.len(),
                missing_message_ids
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(",")
            ));
        }
    }

    let export_peer = export_peer_from_input_peer(&peer, &users_by_id, &chats_by_id);
    let message_count = messages.len();
    let media_download_summary = if let Some((media_dir, parallel)) = media_download.as_ref() {
        download_messages_media(&messages, media_dir, *parallel).await?
    } else {
        MediaDownloadSummary::default()
    };
    for error in &media_download_summary.errors {
        warnings.push(format!(
            "Could not download media for message {}: {}",
            error.message_id, error.error
        ));
    }
    let media_paths_by_message_id = media_download_summary
        .files
        .iter()
        .map(|file| (file.message_id, file.path.clone()))
        .collect::<HashMap<_, _>>();
    let mut bundle = build_message_export_bundle(MessageExportBuildInput {
        peer: export_peer,
        messages,
        users_by_id: &users_by_id,
        chats_by_id: &chats_by_id,
        spaces_by_id: &spaces_by_id,
        related_messages_by_id: &related_messages_by_id,
        forward_messages_by_key: &forward_messages_by_key,
        translations: Vec::new(),
        warnings,
    });
    apply_media_local_paths(&mut bundle, &media_paths_by_message_id);
    let payload_text = render_export(&bundle, format, json_format)?;
    let bytes = payload_text.len();
    let media_file_count = media_download_summary.files.len();
    if let Some(output_path) = output_path {
        if let Some(parent) = output_path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&output_path, payload_text.as_bytes())?;
        if json {
            let output = ExportOutput {
                path: output_path.display().to_string(),
                format: format.as_str().to_string(),
                messages: message_count,
                bytes,
                media_files: media_download_summary.files.clone(),
                skipped_message_ids: media_download_summary.skipped_message_ids.clone(),
                media_errors: media_download_summary.errors.clone(),
            };
            output::print_json(&output, json_format)?;
        } else if let Some((media_dir, _)) = media_download.as_ref() {
            print_export_media_summary(
                message_count,
                format,
                &output_path,
                media_dir,
                &media_download_summary,
            );
        } else {
            println!(
                "Exported {} message(s) as {} to {}.",
                message_count,
                format.as_str(),
                output_path.display()
            );
        }
    } else {
        print!("{payload_text}");
        if let Some((media_dir, _)) = media_download.as_ref() {
            eprintln!(
                "Downloaded {} media file(s) to {}.{}{}",
                media_file_count,
                media_dir.display(),
                skipped_suffix(media_download_summary.skipped_message_ids.len()),
                failed_suffix(media_download_summary.errors.len())
            );
            print_download_errors(&media_download_summary.errors);
        }
    }
    Ok(())
}

fn print_download_batch_summary(output: &DownloadBatchOutput, dir: &Path) {
    println!(
        "Downloaded {} file(s) to {}.{}{}{}",
        output.files.len(),
        dir.display(),
        skipped_suffix(output.skipped_message_ids.len()),
        missing_suffix(output.missing_message_ids.len()),
        failed_suffix(output.errors.len())
    );
    if !output.missing_message_ids.is_empty() {
        eprintln!(
            "Warning: {} message id(s) were not found: {}",
            output.missing_message_ids.len(),
            output
                .missing_message_ids
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>()
                .join(",")
        );
    }
    print_download_errors(&output.errors);
}

fn print_export_media_summary(
    message_count: usize,
    format: MessageExportFormat,
    output_path: &Path,
    media_dir: &Path,
    media_download_summary: &MediaDownloadSummary,
) {
    println!(
        "Exported {} message(s) as {} to {}. Downloaded {} media file(s) to {}.{}{}",
        message_count,
        format.as_str(),
        output_path.display(),
        media_download_summary.files.len(),
        media_dir.display(),
        skipped_suffix(media_download_summary.skipped_message_ids.len()),
        failed_suffix(media_download_summary.errors.len())
    );
    print_download_errors(&media_download_summary.errors);
}

fn skipped_suffix(count: usize) -> String {
    if count == 0 {
        String::new()
    } else {
        format!(" Skipped {count} message(s) without media.")
    }
}

fn missing_suffix(count: usize) -> String {
    if count == 0 {
        String::new()
    } else {
        format!(" Missing {count} message(s).")
    }
}

fn failed_suffix(count: usize) -> String {
    if count == 0 {
        String::new()
    } else {
        format!(" Failed {count} media download(s).")
    }
}

fn print_download_errors(errors: &[DownloadErrorOutput]) {
    for error in errors.iter().take(5) {
        eprintln!(
            "Warning: message {} failed: {}",
            error.message_id, error.error
        );
    }
    if errors.len() > 5 {
        eprintln!(
            "Warning: {} additional media download(s) failed.",
            errors.len() - 5
        );
    }
}

async fn fetch_export_indexes(
    realtime: &mut RealtimeClient,
) -> Result<
    (
        HashMap<i64, proto::User>,
        HashMap<i64, proto::Chat>,
        HashMap<i64, proto::Space>,
    ),
    Box<dyn std::error::Error>,
> {
    let result = realtime
        .call_rpc(
            proto::Method::GetChats,
            proto::rpc_call::Input::GetChats(proto::GetChatsInput {}),
        )
        .await?;
    match result {
        proto::rpc_result::Result::GetChats(payload) => {
            let users = payload
                .users
                .into_iter()
                .map(|user| (user.id, user))
                .collect();
            let chats = payload
                .chats
                .into_iter()
                .map(|chat| (chat.id, chat))
                .collect();
            let spaces = payload
                .spaces
                .into_iter()
                .map(|space| (space.id, space))
                .collect();
            Ok((users, chats, spaces))
        }
        _ => Err(CliError::unexpected_rpc_result("getChats").into()),
    }
}

fn collect_missing_reply_ids(
    messages: &[proto::Message],
    related_messages_by_id: &HashMap<i64, proto::Message>,
) -> Vec<i64> {
    let mut ids = Vec::new();
    for message in messages {
        let Some(reply_to_msg_id) = message.reply_to_msg_id else {
            continue;
        };
        if related_messages_by_id.contains_key(&reply_to_msg_id) || ids.contains(&reply_to_msg_id) {
            continue;
        }
        ids.push(reply_to_msg_id);
    }
    ids
}

fn collect_forward_sources(messages: &[proto::Message]) -> Vec<(proto::Peer, Vec<i64>)> {
    let mut indexes = HashMap::<String, usize>::new();
    let mut groups = Vec::<(proto::Peer, Vec<i64>)>::new();
    for message in messages {
        let Some(forward) = message.fwd_from.as_ref() else {
            continue;
        };
        let Some(peer) = forward.from_peer_id.as_ref() else {
            continue;
        };
        let Some(peer_key) = forward_peer_group_key(peer) else {
            continue;
        };
        let index = if let Some(index) = indexes.get(&peer_key) {
            *index
        } else {
            let index = groups.len();
            groups.push((peer.clone(), Vec::new()));
            indexes.insert(peer_key, index);
            index
        };
        if forward.from_message_id > 0 && !groups[index].1.contains(&forward.from_message_id) {
            groups[index].1.push(forward.from_message_id);
        }
    }
    groups
}

fn forward_peer_group_key(peer: &proto::Peer) -> Option<String> {
    match &peer.r#type {
        Some(proto::peer::Type::Chat(chat)) => Some(format!("chat:{}", chat.chat_id)),
        Some(proto::peer::Type::User(user)) => Some(format!("user:{}", user.user_id)),
        None => None,
    }
}

fn input_peer_from_proto_peer(peer: &proto::Peer) -> Option<proto::InputPeer> {
    match &peer.r#type {
        Some(proto::peer::Type::Chat(chat)) => Some(proto::InputPeer {
            r#type: Some(proto::input_peer::Type::Chat(proto::InputPeerChat {
                chat_id: chat.chat_id,
            })),
        }),
        Some(proto::peer::Type::User(user)) => Some(proto::InputPeer {
            r#type: Some(proto::input_peer::Type::User(proto::InputPeerUser {
                user_id: user.user_id,
            })),
        }),
        None => None,
    }
}

fn export_peer_from_input_peer(
    peer: &proto::InputPeer,
    users_by_id: &HashMap<i64, proto::User>,
    chats_by_id: &HashMap<i64, proto::Chat>,
) -> ExportPeer {
    match &peer.r#type {
        Some(proto::input_peer::Type::Chat(chat)) => ExportPeer {
            peer_type: "chat".to_string(),
            id: chat.chat_id,
            name: chats_by_id
                .get(&chat.chat_id)
                .map(|chat| chat_display_name(chat, users_by_id)),
        },
        Some(proto::input_peer::Type::User(user)) => ExportPeer {
            peer_type: "user".to_string(),
            id: user.user_id,
            name: users_by_id.get(&user.user_id).map(user_display_name),
        },
        Some(proto::input_peer::Type::Self_(_)) => ExportPeer {
            peer_type: "self".to_string(),
            id: 0,
            name: Some("You".to_string()),
        },
        None => ExportPeer {
            peer_type: "unknown".to_string(),
            id: 0,
            name: None,
        },
    }
}

fn require_token(auth_store: &AuthStore) -> Result<String, Box<dyn std::error::Error>> {
    match auth_store.load_token()? {
        Some(token) => Ok(token),
        None => Err(CliError::not_authenticated().into()),
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProtoSchemaFile {
    name: &'static str,
    contents: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProtoSchemaBundle {
    files: Vec<ProtoSchemaFile>,
}

fn bundled_proto_sources() -> ProtoSchemaBundle {
    ProtoSchemaBundle {
        files: vec![ProtoSchemaFile {
            name: "core.proto",
            contents: include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../proto/core.proto")),
        }],
    }
}

fn peer_label_from_input(peer: &proto::InputPeer) -> String {
    match &peer.r#type {
        Some(proto::input_peer::Type::Chat(chat)) => format!("chat {}", chat.chat_id),
        Some(proto::input_peer::Type::User(user)) => format!("user {}", user.user_id),
        Some(proto::input_peer::Type::Self_(_)) => "self".to_string(),
        None => "peer".to_string(),
    }
}

fn invite_target_from_args(
    args: &SpacesInviteArgs,
) -> Result<proto::invite_to_space_input::Via, Box<dyn std::error::Error>> {
    let mut target = None;
    if let Some(user_id) = args.user_id {
        let user_id = validate_positive_id_arg("--user-id", user_id)?;
        target = Some(proto::invite_to_space_input::Via::UserId(user_id));
    }
    if let Some(email) = args.email.as_ref() {
        if target.is_some() {
            return Err(CliError::invalid_args(
                "Provide only one of --user-id, --email, or --phone",
            )
            .into());
        }
        let trimmed = email.trim();
        if trimmed.is_empty() {
            return Err(CliError::invalid_args("Email cannot be empty").into());
        }
        target = Some(proto::invite_to_space_input::Via::Email(
            trimmed.to_string(),
        ));
    }
    if let Some(phone) = args.phone.as_ref() {
        if target.is_some() {
            return Err(CliError::invalid_args(
                "Provide only one of --user-id, --email, or --phone",
            )
            .into());
        }
        let trimmed = phone.trim();
        if trimmed.is_empty() {
            return Err(CliError::invalid_args("Phone number cannot be empty").into());
        }
        target = Some(proto::invite_to_space_input::Via::PhoneNumber(
            trimmed.to_string(),
        ));
    }
    target.ok_or_else(|| CliError::invalid_args("Provide --user-id, --email, or --phone").into())
}

fn invite_role_from_args(
    admin: bool,
    public_chats: bool,
) -> Result<Option<proto::SpaceMemberRole>, Box<dyn std::error::Error>> {
    if admin && public_chats {
        return Err(CliError::invalid_args("Provide only one of --admin or --public-chats").into());
    }
    if admin {
        return Ok(Some(space_member_role_admin()));
    }
    if public_chats {
        return Ok(Some(space_member_role_member(true)));
    }
    Ok(None)
}

fn require_member_access_role(
    admin: bool,
    member: bool,
    public_chats: bool,
) -> Result<proto::SpaceMemberRole, Box<dyn std::error::Error>> {
    if admin && (member || public_chats) {
        return Err(CliError::invalid_args(
            "Provide only one of --admin or --member/--public-chats",
        )
        .into());
    }
    if admin {
        return Ok(space_member_role_admin());
    }
    if !member && !public_chats {
        return Err(
            CliError::invalid_args("Provide --admin or --member (or --public-chats)").into(),
        );
    }
    Ok(space_member_role_member(public_chats))
}

fn space_member_role_member(can_access_public_chats: bool) -> proto::SpaceMemberRole {
    proto::SpaceMemberRole {
        role: Some(proto::space_member_role::Role::Member(
            proto::SpaceMemberOptions {
                can_access_public_chats,
            },
        )),
    }
}

fn space_member_role_admin() -> proto::SpaceMemberRole {
    proto::SpaceMemberRole {
        role: Some(proto::space_member_role::Role::Admin(
            proto::SpaceAdminOptions {},
        )),
    }
}

async fn fetch_me(
    realtime: &mut RealtimeClient,
) -> Result<proto::User, Box<dyn std::error::Error>> {
    let result = realtime
        .call_rpc(
            proto::Method::GetMe,
            proto::rpc_call::Input::GetMe(proto::GetMeInput {}),
        )
        .await?;
    match result {
        proto::rpc_result::Result::GetMe(payload) => payload
            .user
            .ok_or_else(|| CliError::unexpected_api_response("getMe", "missing user").into()),
        _ => Err(CliError::unexpected_rpc_result("getMe").into()),
    }
}

async fn fetch_user_settings(
    realtime: &mut RealtimeClient,
) -> Result<Option<proto::UserSettings>, Box<dyn std::error::Error>> {
    let result = realtime
        .call_rpc(
            proto::Method::GetUserSettings,
            proto::rpc_call::Input::GetUserSettings(proto::GetUserSettingsInput {}),
        )
        .await?;
    match result {
        proto::rpc_result::Result::GetUserSettings(payload) => Ok(payload.user_settings),
        _ => Err(CliError::unexpected_rpc_result("getUserSettings").into()),
    }
}

fn filter_messages_by_time(
    messages: &mut Vec<proto::Message>,
    since_ts: Option<i64>,
    until_ts: Option<i64>,
) {
    if since_ts.is_none() && until_ts.is_none() {
        return;
    }

    messages.retain(|msg| {
        let msg_ts = msg.date;
        let after_since = since_ts.is_none_or(|ts| msg_ts >= ts);
        let before_until = until_ts.is_none_or(|ts| msg_ts <= ts);
        after_since && before_until
    });
}

fn filter_messages_by_list_options(messages: &mut Vec<proto::Message>, args: &MessagesListArgs) {
    if !args.has_media && !args.empty_text && !args.forwarded {
        return;
    }

    messages.retain(|message| {
        (!args.has_media || message_has_any_media(message))
            && (!args.empty_text || message_has_empty_text(message))
            && (!args.forwarded || message.fwd_from.is_some())
    });
}

fn message_has_any_media(message: &proto::Message) -> bool {
    message
        .media
        .as_ref()
        .and_then(|media| media.media.as_ref())
        .is_some()
}

fn message_has_empty_text(message: &proto::Message) -> bool {
    message
        .message
        .as_deref()
        .is_none_or(|text| text.trim().is_empty())
}

fn parse_mention_entities(
    raw_mentions: &[String],
) -> Result<Option<proto::MessageEntities>, Box<dyn std::error::Error>> {
    if raw_mentions.is_empty() {
        return Ok(None);
    }

    let mut entities = Vec::with_capacity(raw_mentions.len());
    for raw in raw_mentions {
        let parts: Vec<&str> = raw.split(':').collect();
        if parts.len() != 3 {
            return Err(CliError::invalid_args(format!(
                "Invalid mention '{raw}'. Use USER_ID:OFFSET:LENGTH (offset/length are UTF-16 units)."
            ))
            .into());
        }
        let user_id: i64 = parts[0]
            .trim()
            .parse()
            .map_err(|_| CliError::invalid_args(format!("Invalid mention user id in '{raw}'")))?;
        let offset: i64 = parts[1]
            .trim()
            .parse()
            .map_err(|_| CliError::invalid_args(format!("Invalid mention offset in '{raw}'")))?;
        let length: i64 = parts[2]
            .trim()
            .parse()
            .map_err(|_| CliError::invalid_args(format!("Invalid mention length in '{raw}'")))?;

        if user_id <= 0 {
            return Err(CliError::invalid_args(format!(
                "Mention user id must be positive in '{raw}'"
            ))
            .into());
        }
        if offset < 0 {
            return Err(
                CliError::invalid_args(format!("Mention offset must be >= 0 in '{raw}'")).into(),
            );
        }
        if length <= 0 {
            return Err(
                CliError::invalid_args(format!("Mention length must be > 0 in '{raw}'")).into(),
            );
        }

        entities.push(proto::MessageEntity {
            r#type: proto::message_entity::Type::Mention as i32,
            offset,
            length,
            entity: Some(proto::message_entity::Entity::Mention(
                proto::message_entity::MessageEntityMention { user_id },
            )),
        });
    }

    Ok(Some(proto::MessageEntities { entities }))
}

fn collect_message_ids(messages: &[proto::Message]) -> Vec<i64> {
    messages.iter().map(|message| message.id).collect()
}

fn translations_in_message_order(
    message_ids: &[i64],
    translations_by_id: &HashMap<i64, proto::MessageTranslation>,
) -> Vec<proto::MessageTranslation> {
    message_ids
        .iter()
        .filter_map(|message_id| translations_by_id.get(message_id).cloned())
        .collect()
}

fn validate_download_parallel(value: usize) -> Result<usize, Box<dyn std::error::Error>> {
    if value == 0 {
        return Err(CliError::invalid_args("--parallel must be greater than 0").into());
    }
    if value > 64 {
        return Err(CliError::invalid_args("--parallel must be 64 or less").into());
    }
    Ok(value)
}

fn is_export_output_bundle_dir(path: &Path, download_media: bool) -> bool {
    path.is_dir() || (download_media && path.extension().is_none())
}

fn resolve_export_output_path(
    output_path: Option<PathBuf>,
    output_bundle_dir: Option<&Path>,
    format: MessageExportFormat,
) -> Option<PathBuf> {
    match (output_path, output_bundle_dir) {
        (Some(_), Some(bundle_dir)) => {
            Some(bundle_dir.join(format!("transcript.{}", format.extension())))
        }
        (Some(path), None) => Some(path),
        (None, _) => None,
    }
}

fn resolve_export_media_download(
    download_media: bool,
    media_dir: Option<PathBuf>,
    parallel: Option<usize>,
    output_path: Option<&Path>,
    output_bundle_dir: Option<&Path>,
) -> Result<Option<(PathBuf, usize)>, Box<dyn std::error::Error>> {
    if !download_media {
        if media_dir.is_some() {
            return Err(CliError::invalid_args("--media-dir requires --download-media").into());
        }
        if parallel.is_some() {
            return Err(CliError::invalid_args(
                "--parallel requires --download-media for export/transcript",
            )
            .into());
        }
        return Ok(None);
    }

    let parallel = validate_download_parallel(parallel.unwrap_or(8))?;
    let media_dir = media_dir.unwrap_or_else(|| {
        output_bundle_dir
            .map(|dir| dir.join("media"))
            .unwrap_or_else(|| default_export_media_dir(output_path))
    });
    Ok(Some((media_dir, parallel)))
}

fn default_export_media_dir(output_path: Option<&Path>) -> PathBuf {
    let Some(output_path) = output_path else {
        return PathBuf::from("inline-media");
    };
    let stem = output_path
        .file_stem()
        .and_then(|value| value.to_str())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("inline");
    let dir_name = format!("{stem}-media");
    output_path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .map(|parent| parent.join(&dir_name))
        .unwrap_or_else(|| PathBuf::from(dir_name))
}

async fn download_messages_media(
    messages: &[proto::Message],
    dir: &Path,
    parallel: usize,
) -> Result<MediaDownloadSummary, Box<dyn std::error::Error>> {
    fs::create_dir_all(dir)?;
    let skipped_message_ids = messages
        .iter()
        .filter(|message| !message_has_downloadable_media(message))
        .map(|message| message.id)
        .collect::<Vec<_>>();
    let downloadable_messages = messages
        .iter()
        .filter(|message| message_has_downloadable_media(message))
        .cloned()
        .collect::<Vec<_>>();
    let requested_order = messages
        .iter()
        .enumerate()
        .map(|(index, message)| (message.id, index))
        .collect::<HashMap<_, _>>();

    let results = stream::iter(downloadable_messages.into_iter())
        .map(|message| {
            let dir = dir.to_path_buf();
            async move {
                let message_id = message.id;
                let output_path = match resolve_batch_download_path(&message, &dir) {
                    Ok(path) => path,
                    Err(error) => {
                        return Err(DownloadErrorOutput {
                            message_id,
                            error: error.to_string(),
                        });
                    }
                };
                match download_message_media(&message, &output_path).await {
                    Ok(bytes) => Ok(DownloadedFileOutput {
                        message_id,
                        path: output_path.display().to_string(),
                        bytes,
                    }),
                    Err(error) => Err(DownloadErrorOutput {
                        message_id,
                        error: error.to_string(),
                    }),
                }
            }
        })
        .buffer_unordered(parallel)
        .collect::<Vec<_>>()
        .await;

    let mut files = Vec::new();
    let mut errors = Vec::new();
    for result in results {
        match result {
            Ok(file) => files.push(file),
            Err(error) => errors.push(error),
        }
    }

    files.sort_by_key(|file| {
        requested_order
            .get(&file.message_id)
            .copied()
            .unwrap_or(usize::MAX)
    });
    errors.sort_by_key(|error| {
        requested_order
            .get(&error.message_id)
            .copied()
            .unwrap_or(usize::MAX)
    });
    Ok(MediaDownloadSummary {
        files,
        skipped_message_ids,
        errors,
    })
}

fn message_has_downloadable_media(message: &proto::Message) -> bool {
    matches!(
        message
            .media
            .as_ref()
            .and_then(|media| media.media.as_ref()),
        Some(proto::message_media::Media::Document(_))
            | Some(proto::message_media::Media::Video(_))
            | Some(proto::message_media::Media::Photo(_))
            | Some(proto::message_media::Media::Voice(_))
    )
}

async fn fetch_message_translations(
    realtime: &mut RealtimeClient,
    peer: &proto::InputPeer,
    message_ids: &[i64],
    language: &str,
) -> Result<HashMap<i64, proto::MessageTranslation>, Box<dyn std::error::Error>> {
    if message_ids.is_empty() {
        return Ok(HashMap::new());
    }

    let input = proto::TranslateMessagesInput {
        peer_id: Some(peer.clone()),
        message_ids: message_ids.to_vec(),
        language: language.to_string(),
    };

    let result = realtime
        .call_rpc(
            proto::Method::TranslateMessages,
            proto::rpc_call::Input::TranslateMessages(input),
        )
        .await?;

    match result {
        proto::rpc_result::Result::TranslateMessages(payload) => Ok(payload
            .translations
            .into_iter()
            .map(|translation| (translation.message_id, translation))
            .collect()),
        _ => Err(CliError::unexpected_rpc_result("translateMessages").into()),
    }
}

fn filter_users_output(output: &mut UserListOutput, filter: Option<&str>) {
    let Some(needle) = normalized_filter(filter) else {
        return;
    };
    output
        .users
        .retain(|user| user_summary_matches_filter(user, &needle));
}

fn filter_users_payload(payload: &mut proto::GetChatsResult, filter: Option<&str>) {
    let Some(needle) = normalized_filter(filter) else {
        return;
    };
    payload
        .users
        .retain(|user| proto_user_matches_filter(user, &needle));
}

fn filter_bots_payload(payload: &mut proto::ListBotsResult, filter: Option<&str>) {
    let Some(needle) = normalized_filter(filter) else {
        return;
    };
    payload
        .bots
        .retain(|bot| proto_user_matches_filter(bot, &needle));
}

fn normalized_filter(filter: Option<&str>) -> Option<String> {
    filter
        .map(str::trim)
        .filter(|filter| !filter.is_empty())
        .map(str::to_lowercase)
}

fn user_summary_matches_filter(user: &UserSummary, needle: &str) -> bool {
    if user.display_name.to_lowercase().contains(needle) {
        return true;
    }
    proto_user_matches_filter(&user.user, needle)
}

fn proto_user_matches_filter(user: &proto::User, needle: &str) -> bool {
    if user_display_name(user).to_lowercase().contains(needle) {
        return true;
    }
    if user
        .first_name
        .as_deref()
        .is_some_and(|first| first.to_lowercase().contains(needle))
    {
        return true;
    }
    if user
        .last_name
        .as_deref()
        .is_some_and(|last| last.to_lowercase().contains(needle))
    {
        return true;
    }
    if user
        .username
        .as_deref()
        .is_some_and(|username| username.to_lowercase().contains(needle))
    {
        return true;
    }
    if user
        .email
        .as_deref()
        .is_some_and(|email| email.to_lowercase().contains(needle))
    {
        return true;
    }
    if user
        .phone_number
        .as_deref()
        .is_some_and(|phone| phone.to_lowercase().contains(needle))
    {
        return true;
    }
    false
}

async fn fetch_message_by_id(
    realtime: &mut RealtimeClient,
    peer: &proto::InputPeer,
    message_id: i64,
) -> Result<proto::Message, Box<dyn std::error::Error>> {
    let (messages, _) = fetch_messages_by_ids(realtime, peer, &[message_id]).await?;
    messages
        .into_iter()
        .next()
        .ok_or_else(|| CliError::invalid_args("Message not found for that peer.").into())
}

async fn fetch_history_messages(
    realtime: &mut RealtimeClient,
    peer: &proto::InputPeer,
    offset_id: Option<i64>,
    limit: Option<i32>,
) -> Result<Vec<proto::Message>, Box<dyn std::error::Error>> {
    let input = proto::GetChatHistoryInput {
        peer_id: Some(peer.clone()),
        offset_id,
        limit,
        ..Default::default()
    };
    let result = realtime
        .call_rpc(
            proto::Method::GetChatHistory,
            proto::rpc_call::Input::GetChatHistory(input),
        )
        .await?;
    match result {
        proto::rpc_result::Result::GetChatHistory(payload) => Ok(payload.messages),
        _ => Err(CliError::unexpected_rpc_result("getChatHistory").into()),
    }
}

async fn fetch_messages_by_ids(
    realtime: &mut RealtimeClient,
    peer: &proto::InputPeer,
    message_ids: &[i64],
) -> Result<(Vec<proto::Message>, Vec<i64>), Box<dyn std::error::Error>> {
    if message_ids.is_empty() {
        return Err(CliError::missing_message_ids().into());
    }

    let input = get_messages_input_for_ids(peer, message_ids);
    let result = realtime
        .call_rpc(
            proto::Method::GetMessages,
            proto::rpc_call::Input::GetMessages(input),
        )
        .await?;
    match result {
        proto::rpc_result::Result::GetMessages(payload) => {
            let mut messages_by_id = payload
                .messages
                .into_iter()
                .map(|message| (message.id, message))
                .collect::<HashMap<_, _>>();
            let mut messages = Vec::new();
            let mut missing_message_ids = Vec::new();
            for message_id in message_ids {
                if let Some(message) = messages_by_id.remove(message_id) {
                    messages.push(message);
                } else {
                    missing_message_ids.push(*message_id);
                }
            }
            Ok((messages, missing_message_ids))
        }
        _ => Err(CliError::unexpected_rpc_result("getMessages").into()),
    }
}

fn get_messages_input_for_ids(
    peer: &proto::InputPeer,
    message_ids: &[i64],
) -> proto::GetMessagesInput {
    proto::GetMessagesInput {
        peer_id: Some(peer.clone()),
        message_ids: message_ids.to_vec(),
    }
}

fn peer_summary_from_input(peer: &proto::InputPeer) -> Option<PeerSummary> {
    match &peer.r#type {
        Some(proto::input_peer::Type::Chat(chat)) => Some(PeerSummary {
            peer_type: "chat".to_string(),
            id: chat.chat_id,
        }),
        Some(proto::input_peer::Type::User(user)) => Some(PeerSummary {
            peer_type: "user".to_string(),
            id: user.user_id,
        }),
        Some(proto::input_peer::Type::Self_(_)) => Some(PeerSummary {
            peer_type: "self".to_string(),
            id: 0,
        }),
        None => None,
    }
}

fn peer_name_from_input(
    peer: &proto::InputPeer,
    users_by_id: &HashMap<i64, proto::User>,
    chats_by_id: &HashMap<i64, proto::Chat>,
) -> Option<String> {
    match &peer.r#type {
        Some(proto::input_peer::Type::User(user)) => users_by_id
            .get(&user.user_id)
            .map(user_display_name)
            .or_else(|| Some(format!("user {}", user.user_id))),
        Some(proto::input_peer::Type::Chat(chat)) => chats_by_id
            .get(&chat.chat_id)
            .map(|chat| chat_display_name(chat, users_by_id))
            .or_else(|| Some(format!("chat {}", chat.chat_id))),
        Some(proto::input_peer::Type::Self_(_)) => Some("You".to_string()),
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
mod cli_parsing_tests {
    use super::*;

    #[test]
    fn parses_whoami_and_me_shortcuts() {
        let cli = Cli::try_parse_from(["inline", "me"]).unwrap();
        assert!(matches!(cli.command, Command::Me));

        let cli = Cli::try_parse_from(["inline", "whoami"]).unwrap();
        assert!(matches!(cli.command, Command::Me));
    }

    #[test]
    fn parses_login_and_logout_shortcuts() {
        let cli = Cli::try_parse_from(["inline", "login", "--email", "agent@example.com"]).unwrap();
        match cli.command {
            Command::Login(args) => assert_eq!(args.email.as_deref(), Some("agent@example.com")),
            _ => panic!("expected login shortcut"),
        }

        let cli = Cli::try_parse_from(["inline", "logout"]).unwrap();
        assert!(matches!(cli.command, Command::Logout));
    }

    #[test]
    fn help_and_version_exit_successfully() {
        let help_err = Cli::try_parse_from(["inline", "--help"]).err().unwrap();
        assert_eq!(help_err.kind(), clap::error::ErrorKind::DisplayHelp);
        assert_eq!(help_err.exit_code(), 0);

        let version_err = Cli::try_parse_from(["inline", "--version"]).err().unwrap();
        assert_eq!(version_err.kind(), clap::error::ErrorKind::DisplayVersion);
        assert_eq!(version_err.exit_code(), 0);
    }

    #[test]
    fn top_level_help_includes_mini_skill_sections() {
        use clap::CommandFactory;

        let mut command = Cli::command();
        let mut output = Vec::new();
        command.write_long_help(&mut output).unwrap();
        let help_text = String::from_utf8(output).unwrap();

        assert!(help_text.contains("Common workflows:"));
        assert!(help_text.contains("inline login"));
        assert!(
            help_text.contains("inline messages get --chat-id 123 --message-id 91,92,100 --json")
        );
        assert!(help_text.contains("Aliases and shortcuts:"));
        assert!(help_text.contains("inline transcript"));
        assert!(help_text.contains("JSON mode:"));
        assert!(
            help_text
                .contains("https://github.com/inline-chat/inline/blob/main/cli/skill/SKILL.md")
        );
    }

    #[test]
    fn logout_output_warns_when_env_token_remains_effective() {
        let output = build_auth_logout_output(true);
        assert!(output.saved_token_cleared);
        assert!(output.effective_token_present);
        assert_eq!(
            output.effective_token_source.as_deref(),
            Some("INLINE_TOKEN")
        );
        assert!(
            output
                .warning
                .as_deref()
                .unwrap_or("")
                .contains("INLINE_TOKEN")
        );
    }

    #[test]
    fn logout_output_reports_no_effective_token_without_env_token() {
        let output = build_auth_logout_output(false);
        assert!(output.saved_token_cleared);
        assert!(!output.effective_token_present);
        assert!(output.effective_token_source.is_none());
        assert!(output.warning.is_none());
    }

    #[tokio::test]
    async fn json_login_fails_before_device_or_state_writes() {
        let root = std::env::temp_dir().join(format!(
            "inline-cli-login-json-test-{}-{}",
            std::process::id(),
            current_epoch_seconds()
        ));
        let secrets_path = root.join("secrets.json");
        let state_path = root.join("state.json");
        let api = ApiClient::new("http://127.0.0.1:9/v1".to_string());
        let auth_store = AuthStore::new(secrets_path.clone(), "http://127.0.0.1:9/v1".to_string());
        let local_db = LocalDb::new(state_path.clone(), "http://127.0.0.1:9/v1".to_string());

        let err = handle_login(
            AuthLoginArgs {
                email: Some("agent@example.com".to_string()),
                phone: None,
            },
            &api,
            &auth_store,
            "ws://127.0.0.1:9/realtime",
            &local_db,
            true,
        )
        .await
        .unwrap_err();

        let cli_err = err.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_err.code, "interactive_required");
        assert!(!root.exists());
        assert!(!secrets_path.exists());
        assert!(!state_path.exists());
    }

    #[test]
    fn login_contact_conflicts_are_structured_invalid_args() {
        let args = AuthLoginArgs {
            email: Some("a@example.com".to_string()),
            phone: Some("+15551234567".to_string()),
        };
        let err = auth_flow::contact_from_args(args)
            .err()
            .expect("expected conflicting contact args to fail");
        let cli_err = err.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--email"));
        assert!(cli_err.message.contains("--phone"));
    }

    #[test]
    fn empty_message_text_is_structured_invalid_args() {
        let err = resolve_message_caption(Some("   ".to_string()), false).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_err.code, "invalid_args");
        assert_eq!(cli_err.message, "message text is empty");
    }

    #[test]
    fn message_list_filters_are_composable() {
        let mut messages = vec![
            proto::Message {
                id: 1,
                message: Some("   ".to_string()),
                media: Some(proto::MessageMedia {
                    media: Some(proto::message_media::Media::Document(
                        proto::MessageDocument {
                            document: Some(proto::Document {
                                id: 10,
                                ..Default::default()
                            }),
                        },
                    )),
                }),
                fwd_from: Some(proto::MessageFwdHeader::default()),
                ..Default::default()
            },
            proto::Message {
                id: 2,
                message: Some("caption".to_string()),
                media: Some(proto::MessageMedia {
                    media: Some(proto::message_media::Media::Document(
                        proto::MessageDocument {
                            document: Some(proto::Document {
                                id: 11,
                                ..Default::default()
                            }),
                        },
                    )),
                }),
                ..Default::default()
            },
            proto::Message {
                id: 3,
                message: None,
                ..Default::default()
            },
        ];
        let args = MessagesListArgs {
            chat_id: Some(1),
            user_id: None,
            limit: None,
            offset_id: None,
            has_media: true,
            empty_text: true,
            forwarded: true,
            translate: None,
            since: None,
            until: None,
        };

        filter_messages_by_list_options(&mut messages, &args);

        assert_eq!(
            messages
                .iter()
                .map(|message| message.id)
                .collect::<Vec<_>>(),
            vec![1]
        );
    }

    #[test]
    fn stdin_terminal_is_structured_stdin_not_piped() {
        let err = require_stdin_pipe(true).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();

        assert_eq!(cli_err.code, "stdin_not_piped");
        assert!(cli_err.hint.as_deref().unwrap_or("").contains("--text"));
        require_stdin_pipe(false).unwrap();
    }

    #[test]
    fn invalid_mentions_are_structured_invalid_args() {
        let err = parse_mention_entities(&["not-a-mention".to_string()]).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("Invalid mention"));
    }

    #[test]
    fn translations_follow_requested_message_order() {
        let translations_by_id: HashMap<i64, proto::MessageTranslation> = [
            (
                2,
                proto::MessageTranslation {
                    message_id: 2,
                    language: "en".to_string(),
                    translation: "second".to_string(),
                    ..Default::default()
                },
            ),
            (
                1,
                proto::MessageTranslation {
                    message_id: 1,
                    language: "en".to_string(),
                    translation: "first".to_string(),
                    ..Default::default()
                },
            ),
        ]
        .into_iter()
        .collect();

        let translations = translations_in_message_order(&[1, 3, 2], &translations_by_id);

        let ids: Vec<i64> = translations
            .iter()
            .map(|translation| translation.message_id)
            .collect();
        assert_eq!(ids, vec![1, 2]);
    }

    #[test]
    fn translated_message_json_keeps_raw_message_fields() {
        let output = TranslatedMessageOutput {
            message: proto::Message {
                id: 7,
                message: Some("hello".to_string()),
                ..Default::default()
            },
            translations: vec![proto::MessageTranslation {
                message_id: 7,
                language: "en".to_string(),
                translation: "hello".to_string(),
                ..Default::default()
            }],
        };

        let value = serde_json::to_value(output).unwrap();

        assert_eq!(value["id"], 7);
        assert_eq!(value["message"], "hello");
        assert_eq!(value["translations"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn translated_history_json_keeps_raw_history_fields() {
        let output = TranslatedChatHistoryOutput {
            payload: proto::GetChatHistoryResult {
                messages: vec![proto::Message {
                    id: 7,
                    message: Some("hello".to_string()),
                    ..Default::default()
                }],
            },
            translations: vec![proto::MessageTranslation {
                message_id: 7,
                language: "en".to_string(),
                translation: "hello".to_string(),
                ..Default::default()
            }],
        };

        let value = serde_json::to_value(output).unwrap();

        assert_eq!(value["messages"].as_array().unwrap().len(), 1);
        assert_eq!(value["messages"][0]["id"], 7);
        assert_eq!(value["translations"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn translated_search_json_keeps_raw_search_fields() {
        let output = TranslatedSearchMessagesOutput {
            payload: proto::SearchMessagesResult {
                messages: vec![proto::Message {
                    id: 8,
                    message: Some("hola".to_string()),
                    ..Default::default()
                }],
            },
            translations: vec![proto::MessageTranslation {
                message_id: 8,
                language: "en".to_string(),
                translation: "hello".to_string(),
                ..Default::default()
            }],
        };

        let value = serde_json::to_value(output).unwrap();

        assert_eq!(value["messages"].as_array().unwrap().len(), 1);
        assert_eq!(value["messages"][0]["id"], 8);
        assert_eq!(value["translations"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn parses_search_shortcut() {
        let cli = Cli::try_parse_from([
            "inline",
            "search",
            "--chat-id",
            "1",
            "--query",
            "foo",
            "--translate",
            "en",
        ])
        .unwrap();
        match cli.command {
            Command::Search(args) => {
                assert_eq!(args.chat_id, Some(1));
                assert_eq!(args.user_id, None);
                assert_eq!(args.query, vec!["foo".to_string()]);
                assert_eq!(args.translate.as_deref(), Some("en"));
            }
            _ => panic!("expected Command::Search"),
        }
    }

    #[test]
    fn parses_transcript_shortcut() {
        let cli = Cli::try_parse_from([
            "inline",
            "transcript",
            "--chat-id",
            "42",
            "--limit",
            "500",
            "--download-media",
            "--media-dir",
            "feedback-media",
            "--parallel",
            "4",
            "--output",
            "feedback.md",
        ])
        .unwrap();

        match cli.command {
            Command::Transcript(args) => {
                assert_eq!(args.chat_id, Some(42));
                assert_eq!(args.limit, Some(500));
                assert_eq!(args.output, Some(PathBuf::from("feedback.md")));
                assert!(args.download_media);
                assert_eq!(args.media_dir, Some(PathBuf::from("feedback-media")));
                assert_eq!(args.parallel, Some(4));
            }
            _ => panic!("expected transcript shortcut"),
        }
    }

    #[test]
    fn parses_schema_proto() {
        let cli = Cli::try_parse_from(["inline", "schema", "proto"]).unwrap();
        assert!(matches!(
            cli.command,
            Command::Schema {
                command: SchemaCommand::Proto
            }
        ));
    }

    #[test]
    fn parses_thread_aliases_to_chats() {
        for alias in ["chat", "thread", "threads"] {
            let cli = Cli::try_parse_from(["inline", alias, "list"]).unwrap();
            assert!(matches!(
                cli.command,
                Command::Chats {
                    command: ChatsCommand::List(_)
                }
            ));
        }
    }

    #[test]
    fn parses_chats_rename() {
        let cli = Cli::try_parse_from([
            "inline",
            "chats",
            "rename",
            "--chat-id",
            "12",
            "--title",
            "New title",
        ])
        .unwrap();
        match cli.command {
            Command::Chats {
                command: ChatsCommand::Rename(args),
            } => {
                assert_eq!(args.chat_id, 12);
                assert_eq!(args.title, "New title");
                assert_eq!(args.emoji, None);
            }
            _ => panic!("expected chats rename"),
        }
    }

    #[test]
    fn parses_messages_forward() {
        let cli = Cli::try_parse_from([
            "inline",
            "messages",
            "forward",
            "--from-chat-id",
            "1",
            "--message-id",
            "10",
            "--message-id",
            "11",
            "--to-chat-id",
            "2",
            "--no-header",
        ])
        .unwrap();
        match cli.command {
            Command::Messages {
                command: MessagesCommand::Forward(args),
            } => {
                assert_eq!(args.from_chat_id, Some(1));
                assert_eq!(args.from_user_id, None);
                assert_eq!(args.message_ids, vec![10, 11]);
                assert_eq!(args.to_chat_id, Some(2));
                assert_eq!(args.to_user_id, None);
                assert!(args.no_header);
            }
            _ => panic!("expected messages forward"),
        }
    }

    #[test]
    fn parses_messages_forward_between_user_peers() {
        let cli = Cli::try_parse_from([
            "inline",
            "messages",
            "forward",
            "--from-user-id",
            "42",
            "--message-id",
            "10",
            "--to-user-id",
            "84",
        ])
        .unwrap();
        match cli.command {
            Command::Messages {
                command: MessagesCommand::Forward(args),
            } => {
                assert_eq!(args.from_chat_id, None);
                assert_eq!(args.from_user_id, Some(42));
                assert_eq!(args.message_ids, vec![10]);
                assert_eq!(args.to_chat_id, None);
                assert_eq!(args.to_user_id, Some(84));
                assert!(!args.no_header);
            }
            _ => panic!("expected messages forward"),
        }
    }

    #[test]
    fn forward_peer_ids_are_structured_invalid_args() {
        let err = validate_positive_id_arg("--from-chat-id", 0).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--from-chat-id"));

        let err = validate_positive_id_arg("--to-user-id", -1).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--to-user-id"));
    }

    #[test]
    fn export_media_download_options_validate_and_default() {
        let (media_dir, parallel) = resolve_export_media_download(
            true,
            None,
            None,
            Some(Path::new("out/feedback.md")),
            None,
        )
        .unwrap()
        .unwrap();
        assert_eq!(media_dir, PathBuf::from("out").join("feedback-media"));
        assert_eq!(parallel, 8);

        let (media_dir, parallel) =
            resolve_export_media_download(true, Some(PathBuf::from("media")), Some(4), None, None)
                .unwrap()
                .unwrap();
        assert_eq!(media_dir, PathBuf::from("media"));
        assert_eq!(parallel, 4);

        let bundle_dir = std::env::temp_dir().join(format!(
            "inline-cli-export-bundle-test-{}-{}",
            std::process::id(),
            current_epoch_seconds()
        ));
        fs::create_dir_all(&bundle_dir).unwrap();
        let output_path = resolve_export_output_path(
            Some(bundle_dir.clone()),
            Some(&bundle_dir),
            MessageExportFormat::Markdown,
        )
        .unwrap();
        assert_eq!(output_path, bundle_dir.join("transcript.md"));
        let (media_dir, _) =
            resolve_export_media_download(true, None, None, Some(&output_path), Some(&bundle_dir))
                .unwrap()
                .unwrap();
        assert_eq!(media_dir, bundle_dir.join("media"));

        let bundle_dir = PathBuf::from("feedback-bundle");
        let output_path = resolve_export_output_path(
            Some(bundle_dir.clone()),
            Some(&bundle_dir),
            MessageExportFormat::Markdown,
        )
        .unwrap();
        assert_eq!(output_path, bundle_dir.join("transcript.md"));

        let err =
            resolve_export_media_download(false, Some(PathBuf::from("media")), None, None, None)
                .unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--download-media"));
    }

    #[test]
    fn parses_typing_commands() {
        let cli = Cli::try_parse_from(["inline", "typing", "start", "--chat-id", "1"]).unwrap();
        assert!(matches!(
            cli.command,
            Command::Typing {
                command: TypingCommand::Start(_)
            }
        ));

        let cli = Cli::try_parse_from(["inline", "typing", "stop", "--user-id", "2"]).unwrap();
        assert!(matches!(
            cli.command,
            Command::Typing {
                command: TypingCommand::Stop(_)
            }
        ));
    }

    #[test]
    fn parses_bots_commands() {
        let cli = Cli::try_parse_from(["inline", "bots", "list"]).unwrap();
        assert!(matches!(
            cli.command,
            Command::Bots {
                command: BotsCommand::List(_)
            }
        ));

        let cli = Cli::try_parse_from([
            "inline",
            "bot",
            "create",
            "--name",
            "My Bot",
            "--username",
            "my_bot",
        ])
        .unwrap();
        match cli.command {
            Command::Bots {
                command: BotsCommand::Create(args),
            } => {
                assert_eq!(args.name, "My Bot");
                assert_eq!(args.username, "my_bot");
                assert_eq!(args.add_to_space, None);
            }
            _ => panic!("expected bots create"),
        }

        let cli =
            Cli::try_parse_from(["inline", "bots", "reveal-token", "--bot-user-id", "9"]).unwrap();
        assert!(matches!(
            cli.command,
            Command::Bots {
                command: BotsCommand::RevealToken(_)
            }
        ));
    }

    #[test]
    fn users_search_aliases_to_list() {
        let cli = Cli::try_parse_from(["inline", "users", "search"]).unwrap();
        assert!(matches!(
            cli.command,
            Command::Users {
                command: UsersCommand::List(_)
            }
        ));
    }

    #[test]
    fn message_text_aliases_parse_for_send_and_edit() {
        let cli = Cli::try_parse_from([
            "inline",
            "messages",
            "send",
            "--chat-id",
            "1",
            "--message",
            "hi",
        ])
        .unwrap();
        match cli.command {
            Command::Messages {
                command: MessagesCommand::Send(args),
            } => assert_eq!(args.text.as_deref(), Some("hi")),
            _ => panic!("expected messages send"),
        }

        let cli = Cli::try_parse_from([
            "inline",
            "messages",
            "send",
            "--chat-id",
            "1",
            "--msg",
            "hi2",
        ])
        .unwrap();
        match cli.command {
            Command::Messages {
                command: MessagesCommand::Send(args),
            } => assert_eq!(args.text.as_deref(), Some("hi2")),
            _ => panic!("expected messages send"),
        }

        let cli = Cli::try_parse_from(["inline", "messages", "send", "--chat-id", "1", "-m", "h"])
            .unwrap();
        match cli.command {
            Command::Messages {
                command: MessagesCommand::Send(args),
            } => assert_eq!(args.text.as_deref(), Some("h")),
            _ => panic!("expected messages send"),
        }

        let cli = Cli::try_parse_from([
            "inline",
            "messages",
            "edit",
            "--chat-id",
            "1",
            "--message-id",
            "2",
            "--msg",
            "updated",
        ])
        .unwrap();
        match cli.command {
            Command::Messages {
                command: MessagesCommand::Edit(args),
            } => assert_eq!(args.text.as_deref(), Some("updated")),
            _ => panic!("expected messages edit"),
        }
    }

    #[test]
    fn peer_args_conflict_at_parse_time() {
        let err = Cli::try_parse_from([
            "inline",
            "messages",
            "list",
            "--chat-id",
            "1",
            "--user-id",
            "2",
        ])
        .err()
        .unwrap();
        assert_eq!(err.kind(), clap::error::ErrorKind::ArgumentConflict);
    }

    #[test]
    fn parses_messages_get_with_user_peer() {
        let cli = Cli::try_parse_from([
            "inline",
            "messages",
            "get",
            "--user-id",
            "42",
            "--message-id",
            "99",
            "--translate",
            "en",
        ])
        .unwrap();

        match cli.command {
            Command::Messages {
                command: MessagesCommand::Get(args),
            } => {
                assert_eq!(args.chat_id, None);
                assert_eq!(args.user_id, Some(42));
                assert_eq!(args.message_ids, vec!["99".to_string()]);
                assert_eq!(args.translate.as_deref(), Some("en"));
            }
            _ => panic!("expected messages get"),
        }
    }

    #[test]
    fn parses_messages_get_selector_values() {
        let cli = Cli::try_parse_from([
            "inline",
            "messages",
            "get",
            "--chat-id",
            "42",
            "--message-id",
            "1,2,4",
            "--message-id",
            "10-12",
        ])
        .unwrap();

        match cli.command {
            Command::Messages {
                command: MessagesCommand::Get(args),
            } => {
                assert_eq!(args.chat_id, Some(42));
                assert_eq!(
                    args.message_ids,
                    vec!["1,2,4".to_string(), "10-12".to_string()]
                );
            }
            _ => panic!("expected messages get"),
        }
    }

    #[test]
    fn parses_messages_download_selector_values() {
        let cli = Cli::try_parse_from([
            "inline",
            "messages",
            "download",
            "--chat-id",
            "42",
            "--message-id",
            "3,7",
            "--message-id",
            "13-14",
            "--dir",
            "./media",
            "--parallel",
            "4",
        ])
        .unwrap();

        match cli.command {
            Command::Messages {
                command: MessagesCommand::Download(args),
            } => {
                assert_eq!(args.chat_id, Some(42));
                assert_eq!(
                    args.message_ids,
                    vec!["3,7".to_string(), "13-14".to_string()]
                );
                assert_eq!(args.dir, Some(PathBuf::from("./media")));
                assert_eq!(args.parallel, 4);
            }
            _ => panic!("expected messages download"),
        }
    }

    #[test]
    fn parses_messages_download_history_window() {
        let cli = Cli::try_parse_from([
            "inline",
            "messages",
            "download",
            "--chat-id",
            "42",
            "--from-msg-id",
            "600",
            "--limit",
            "50",
            "--dir",
            "./media",
            "--parallel",
            "4",
        ])
        .unwrap();

        match cli.command {
            Command::Messages {
                command: MessagesCommand::Download(args),
            } => {
                assert_eq!(args.chat_id, Some(42));
                assert!(args.message_ids.is_empty());
                assert_eq!(args.from_msg_id, Some(600));
                assert_eq!(args.limit, Some(50));
                assert_eq!(args.dir, Some(PathBuf::from("./media")));
                assert_eq!(args.parallel, 4);
            }
            _ => panic!("expected messages download"),
        }

        let err = Cli::try_parse_from([
            "inline",
            "messages",
            "download",
            "--chat-id",
            "42",
            "--message-id",
            "1",
            "--from-msg-id",
            "600",
            "--dir",
            "./media",
        ])
        .err()
        .unwrap();
        assert_eq!(err.kind(), clap::error::ErrorKind::ArgumentConflict);
    }

    #[test]
    fn parses_messages_export_formats_and_selectors() {
        let cli = Cli::try_parse_from([
            "inline",
            "messages",
            "export",
            "--chat-id",
            "42",
            "--message-id",
            "91,92,100",
            "--format",
            "markdown",
            "--output",
            "feedback.md",
            "--download-media",
            "--media-dir",
            "feedback-media",
            "--parallel",
            "4",
        ])
        .unwrap();

        match cli.command {
            Command::Messages {
                command: MessagesCommand::Export(args),
            } => {
                assert_eq!(args.chat_id, Some(42));
                assert_eq!(args.message_ids, vec!["91,92,100".to_string()]);
                assert_eq!(args.format, Some(MessageExportFormat::Markdown));
                assert_eq!(args.output, Some(PathBuf::from("feedback.md")));
                assert!(args.download_media);
                assert_eq!(args.media_dir, Some(PathBuf::from("feedback-media")));
                assert_eq!(args.parallel, Some(4));
            }
            _ => panic!("expected messages export"),
        }
    }

    #[test]
    fn parses_messages_export_history_window() {
        let cli = Cli::try_parse_from([
            "inline",
            "messages",
            "export",
            "--chat-id",
            "42",
            "--from-msg-id",
            "600",
            "--limit",
            "50",
            "--format",
            "markdown",
            "--output",
            "feedback.md",
        ])
        .unwrap();

        match cli.command {
            Command::Messages {
                command: MessagesCommand::Export(args),
            } => {
                assert_eq!(args.chat_id, Some(42));
                assert_eq!(args.from_msg_id, Some(600));
                assert_eq!(args.limit, Some(50));
                assert!(args.message_ids.is_empty());
                assert_eq!(args.format, Some(MessageExportFormat::Markdown));
                assert_eq!(args.output, Some(PathBuf::from("feedback.md")));
            }
            _ => panic!("expected messages export"),
        }
    }

    #[test]
    fn parses_messages_transcript_alias() {
        let cli = Cli::try_parse_from([
            "inline",
            "messages",
            "transcript",
            "--chat-id",
            "42",
            "--limit",
            "500",
            "--download-media",
            "--media-dir",
            "feedback-media",
            "--parallel",
            "4",
            "--output",
            "feedback.md",
        ])
        .unwrap();

        match cli.command {
            Command::Messages {
                command: MessagesCommand::Transcript(args),
            } => {
                assert_eq!(args.chat_id, Some(42));
                assert_eq!(args.limit, Some(500));
                assert_eq!(args.from_msg_id, None);
                assert_eq!(args.output, Some(PathBuf::from("feedback.md")));
                assert!(args.download_media);
                assert_eq!(args.media_dir, Some(PathBuf::from("feedback-media")));
                assert_eq!(args.parallel, Some(4));
            }
            _ => panic!("expected messages transcript"),
        }
    }

    #[test]
    fn destructive_yes_short_aliases_parse() {
        let cli =
            Cli::try_parse_from(["inline", "chats", "delete", "--chat-id", "1", "-y"]).unwrap();
        match cli.command {
            Command::Chats {
                command: ChatsCommand::Delete(args),
            } => assert!(args.yes),
            _ => panic!("expected chats delete"),
        }

        let cli = Cli::try_parse_from([
            "inline",
            "messages",
            "delete",
            "--chat-id",
            "1",
            "--message-id",
            "2",
            "-y",
        ])
        .unwrap();
        match cli.command {
            Command::Messages {
                command: MessagesCommand::Delete(args),
            } => assert!(args.yes),
            _ => panic!("expected messages delete"),
        }

        let cli = Cli::try_parse_from([
            "inline",
            "spaces",
            "delete-member",
            "--space-id",
            "1",
            "--user-id",
            "2",
            "-y",
        ])
        .unwrap();
        match cli.command {
            Command::Spaces {
                command: SpacesCommand::DeleteMember(args),
            } => assert!(args.yes),
            _ => panic!("expected spaces delete-member"),
        }
    }

    #[test]
    fn invite_user_id_is_structured_invalid_args() {
        let args = SpacesInviteArgs {
            space_id: 1,
            user_id: Some(0),
            email: None,
            phone: None,
            admin: false,
            public_chats: false,
        };
        let err = invite_target_from_args(&args).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();

        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--user-id"));
    }

    #[test]
    fn message_get_input_uses_exact_message_id() {
        let peer = input_peer_from_args(Some(123), None).unwrap();
        let input = get_messages_input_for_ids(&peer, &[456]);

        assert_eq!(input.message_ids, vec![456]);
        match input.peer_id.and_then(|peer| peer.r#type) {
            Some(proto::input_peer::Type::Chat(chat)) => assert_eq!(chat.chat_id, 123),
            other => panic!("expected chat peer, got {other:?}"),
        }
    }

    #[test]
    fn message_get_input_accepts_multiple_message_ids() {
        let peer = input_peer_from_args(Some(123), None).unwrap();
        let input = get_messages_input_for_ids(&peer, &[456, 789]);

        assert_eq!(input.message_ids, vec![456, 789]);
        match input.peer_id.and_then(|peer| peer.r#type) {
            Some(proto::input_peer::Type::Chat(chat)) => assert_eq!(chat.chat_id, 123),
            other => panic!("expected chat peer, got {other:?}"),
        }
    }

    #[test]
    fn message_get_input_supports_user_peer() {
        let peer = input_peer_from_args(None, Some(42)).unwrap();
        let input = get_messages_input_for_ids(&peer, &[456]);

        assert_eq!(input.message_ids, vec![456]);
        match input.peer_id.and_then(|peer| peer.r#type) {
            Some(proto::input_peer::Type::User(user)) => assert_eq!(user.user_id, 42),
            other => panic!("expected user peer, got {other:?}"),
        }
    }

    #[test]
    fn user_json_filter_trims_get_chats_payload_users() {
        let mut payload = proto::GetChatsResult {
            users: vec![
                proto::User {
                    id: 1,
                    first_name: Some("Mona".to_string()),
                    username: Some("mona".to_string()),
                    ..Default::default()
                },
                proto::User {
                    id: 2,
                    first_name: Some("Sam".to_string()),
                    username: Some("sam".to_string()),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };

        filter_users_payload(&mut payload, Some("mo"));

        let ids: Vec<i64> = payload.users.iter().map(|user| user.id).collect();
        assert_eq!(ids, vec![1]);
    }

    #[test]
    fn bot_json_filter_trims_list_bots_payload() {
        let mut payload = proto::ListBotsResult {
            bots: vec![
                proto::User {
                    id: 10,
                    first_name: Some("Deploy Bot".to_string()),
                    username: Some("deploy_bot".to_string()),
                    ..Default::default()
                },
                proto::User {
                    id: 11,
                    first_name: Some("Calendar Bot".to_string()),
                    username: Some("calendar_bot".to_string()),
                    ..Default::default()
                },
            ],
        };

        filter_bots_payload(&mut payload, Some("deploy"));

        let ids: Vec<i64> = payload.bots.iter().map(|bot| bot.id).collect();
        assert_eq!(ids, vec![10]);
    }
}
