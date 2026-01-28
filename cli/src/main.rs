mod api;
mod auth;
mod config;
mod dates;
mod output;
mod protocol;
mod realtime;
mod state;
mod update;

use chrono::{DateTime, Utc};
use clap::{ArgAction, Args, Parser, Subcommand, ValueEnum};
use dialoguer::{Confirm, Input, Select};
use futures_util::StreamExt;
use rand::{RngCore, rngs::OsRng};
use serde::Serialize;
use std::cmp::Reverse;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::{env, fs, io};
use tokio::io::AsyncWriteExt;

use crate::api::{
    ApiClient, ApiError, CreateLinearIssueInput, CreateNotionTaskInput, UploadFileInput,
    UploadFileResult, UploadFileType, UploadVideoMetadata,
};
use crate::auth::AuthStore;
use crate::config::Config;
use crate::dates::parse_relative_time;
use crate::output::{
    AttachmentSummary, ChatListItem, ChatListOutput, ChatParticipantSummary,
    ChatParticipantsOutput, MediaSummary, MessageListOutput, MessageSummary, PeerSummary,
    SpaceListOutput, SpaceMemberSummary, SpaceMembersOutput, SpaceSummary, UserListOutput,
    UserSummary,
};
use crate::protocol::proto;
use crate::realtime::RealtimeClient;
use crate::state::LocalDb;

#[cfg(not(target_os = "macos"))]
compile_error!("inline-cli currently supports macOS only.");

const MAX_ATTACHMENT_BYTES: u64 = 200 * 1024 * 1024;

#[derive(Parser)]
#[command(
    name = "inline",
    version,
    about = "Inline CLI",
    disable_version_flag = true,
    propagate_version = true,
    after_help = r#"Docs:
  https://github.com/inline-chat/inline/blob/main/cli/README.md
  https://github.com/inline-chat/inline/blob/main/cli/skill/SKILL.md

Examples:
  inline auth login --email you@example.com
  inline auth me
  inline doctor
  inline chats list
  inline chats participants --chat-id 123
  inline chats create --title "Launch" --space-id 31 --participant 42
  inline chats create-dm --user-id 42
  inline chats update-visibility --chat-id 123 --public
  inline chats update-visibility --chat-id 123 --private --participant 42 --participant 99
  inline chats mark-unread --chat-id 123
  inline chats mark-read --chat-id 123
  inline notifications get
  inline notifications set --mode mentions
  inline spaces list
  inline spaces members --space-id 31
  inline spaces invite --space-id 31 --email you@example.com
  inline users list --json
  inline messages list --chat-id 123
  inline messages list --chat-id 123 --since "yesterday"
  inline messages list --chat-id 123 --since "2h ago" --until "1h ago"
  inline messages list --chat-id 123 --translate en
  inline messages export --chat-id 123 --output ./messages.json
  inline messages export --chat-id 123 --since "1w ago" --output ./recent.json
  inline messages search --chat-id 123 --query "onboarding"
  inline messages search --chat-id 123 --query "urgent" --since "today"
  inline messages get --chat-id 123 --message-id 456
  inline messages send --chat-id 123 --text "hello"
  inline messages send --chat-id 123 --reply-to 456 --text "on it"
  inline messages send --chat-id 123 --text "@Sam hello" --mention 42:0:4
  inline messages edit --chat-id 123 --message-id 456 --text "updated"
  inline messages delete --chat-id 123 --message-id 456
  inline messages add-reaction --chat-id 123 --message-id 456 --emoji "👍"
  inline messages send --chat-id 123 --attach ./photo.jpg --attach ./spec.pdf --text "FYI"
  inline messages download --chat-id 123 --message-id 456
  inline messages send --user-id 42 --stdin
  inline tasks create-linear --chat-id 123 --message-id 456
  inline tasks create-notion --chat-id 123 --message-id 456 --space-id 31

JQ examples:
  inline users list --json | jq -r '.users[] | "\(.id)\t\(.first_name) \(.last_name)\t@\(.username // "")\t\(.email // "")"'
  inline users list --json | jq -r '.users[] | select((.first_name + " " + (.last_name // "") + " " + (.username // "") + " " + (.email // "")) | ascii_downcase | contains("mo")) | "\(.id)\t\(.first_name) \(.last_name)"'
  inline chats list --json | jq -r '.chats[] | "\(.id)\t\(.title // "")\tspace:\(if .space_id == null then "dm" else (.space_id | tostring) end)"'
  inline chats list --json | jq -r '.dialogs[] | select(.unread_count > 0) | "\(.chat_id)\tunread:\(.unread_count)"'
  inline messages list --chat-id 123 --json | jq -r '.messages[] | "\(.id)\t\(.from_id)\t\((.message // "") | gsub("\n"; " ") | .[0:80])"'
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
    #[command(about = "Update the CLI to the latest release")]
    Update,
    #[command(about = "Print diagnostic information about this CLI")]
    Doctor,
    #[command(about = "List chats and threads")]
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
struct AuthLoginArgs {
    #[arg(long, help = "Email address to send the login code to")]
    email: Option<String>,

    #[arg(long, help = "Phone number to send the login code to")]
    phone: Option<String>,
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
    #[command(about = "Mark a chat or DM as unread")]
    MarkUnread(ChatsMarkUnreadArgs),
    #[command(about = "Mark a chat or DM as read")]
    MarkRead(ChatsMarkReadArgs),
    #[command(about = "Delete a chat (space thread)")]
    Delete(ChatsDeleteArgs),
}

#[derive(Args)]
struct ChatsListArgs {
    #[arg(long, help = "Maximum number of chats to return")]
    limit: Option<usize>,

    #[arg(long, help = "Offset into the chat list")]
    offset: Option<usize>,
}

#[derive(Args)]
struct ChatsGetArgs {
    #[arg(long, help = "Chat id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)")]
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
struct ChatsMarkUnreadArgs {
    #[arg(long, help = "Chat id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)")]
    user_id: Option<i64>,
}

#[derive(Args)]
struct ChatsMarkReadArgs {
    #[arg(long, help = "Chat id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)")]
    user_id: Option<i64>,

    #[arg(long, help = "Max message id to mark as read")]
    max_id: Option<i64>,
}

#[derive(Args)]
struct ChatsDeleteArgs {
    #[arg(long, help = "Chat id (space thread)")]
    chat_id: i64,

    #[arg(long, help = "Skip confirmation prompt")]
    yes: bool,
}

#[derive(Subcommand)]
enum UsersCommand {
    #[command(about = "List users that appear in your chats")]
    List(UsersListArgs),
    #[command(about = "Fetch a user by id from the chat list payload")]
    Get(UserGetArgs),
}

#[derive(Args)]
struct UsersListArgs {
    #[arg(long, help = "Filter users by name, username, email, or phone")]
    filter: Option<String>,
}

#[derive(Args)]
struct UserGetArgs {
    #[arg(long, help = "User id")]
    id: i64,
}

#[derive(Subcommand)]
enum MessagesCommand {
    #[command(about = "List messages for a chat or user")]
    List(MessagesListArgs),
    #[command(about = "Search messages in a chat or DM")]
    Search(MessagesSearchArgs),
    #[command(about = "Fetch a single message by id")]
    Get(MessagesGetArgs),
    #[command(about = "Send a message to a chat or user")]
    Send(MessagesSendArgs),
    #[command(about = "Export messages to a JSON file")]
    Export(MessagesExportArgs),
    #[command(about = "Download a message attachment (photo/video/file)")]
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
    #[arg(long, help = "Chat id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)")]
    user_id: Option<i64>,

    #[arg(long, help = "Maximum number of messages to return")]
    limit: Option<i32>,

    #[arg(long, help = "Offset message id for pagination")]
    offset_id: Option<i64>,

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
    #[arg(long, help = "Chat id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)")]
    user_id: Option<i64>,

    #[arg(long, help = "Search query (repeatable)")]
    query: Vec<String>,

    #[arg(long, help = "Maximum number of results to return")]
    limit: Option<i32>,

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
    #[arg(long, help = "Chat id")]
    chat_id: i64,

    #[arg(long, help = "Message id")]
    message_id: i64,

    #[arg(
        long,
        value_name = "LANG",
        help = "Translate message to language code (e.g., en)"
    )]
    translate: Option<String>,
}

#[derive(Args)]
struct MessagesSendArgs {
    #[arg(long, help = "Chat id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)")]
    user_id: Option<i64>,

    #[arg(long, help = "Message text (used as caption for attachments)")]
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
struct MessagesExportArgs {
    #[arg(long, help = "Chat id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)")]
    user_id: Option<i64>,

    #[arg(long, help = "Maximum number of messages to return")]
    limit: Option<i32>,

    #[arg(long, help = "Offset message id for pagination")]
    offset_id: Option<i64>,

    #[arg(long, value_name = "PATH", help = "Output file path")]
    output: PathBuf,

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
struct MessagesDownloadArgs {
    #[arg(long, help = "Chat id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)")]
    user_id: Option<i64>,

    #[arg(long, help = "Message id containing the attachment")]
    message_id: i64,

    #[arg(long, help = "Output file path (defaults to current directory)")]
    output: Option<PathBuf>,

    #[arg(long, help = "Output directory (defaults to current directory)")]
    dir: Option<PathBuf>,
}

#[derive(Args)]
struct MessagesDeleteArgs {
    #[arg(long, help = "Chat id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)")]
    user_id: Option<i64>,

    #[arg(
        long = "message-id",
        value_name = "ID",
        num_args = 1..,
        action = ArgAction::Append,
        help = "Message id to delete (repeatable)"
    )]
    message_ids: Vec<i64>,

    #[arg(long, help = "Skip confirmation prompt")]
    yes: bool,
}

#[derive(Args)]
struct MessagesEditArgs {
    #[arg(long, help = "Chat id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)")]
    user_id: Option<i64>,

    #[arg(long, help = "Message id")]
    message_id: i64,

    #[arg(long, help = "New message text")]
    text: Option<String>,

    #[arg(long, help = "Read message text from stdin")]
    stdin: bool,
}

#[derive(Args)]
struct MessagesReactionArgs {
    #[arg(long, help = "Chat id")]
    chat_id: Option<i64>,

    #[arg(long, help = "User id (for DMs)")]
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
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DownloadOutput {
    path: String,
    bytes: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DoctorOutput {
    system: DoctorSystem,
    config: DoctorConfig,
    paths: DoctorPaths,
    auth: DoctorAuth,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DoctorSystem {
    version: String,
    debug: bool,
    os: String,
    arch: String,
    executable: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DoctorConfig {
    api_base_url: String,
    realtime_url: String,
    release_manifest_url: Option<String>,
    release_install_url: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DoctorPaths {
    data_dir: String,
    data_dir_exists: bool,
    secrets_path: String,
    secrets_exists: bool,
    state_path: String,
    state_exists: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DoctorAuth {
    token_present: bool,
    token_source: Option<String>,
    token_error: Option<String>,
    current_user: Option<proto::User>,
    state_error: Option<String>,
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

#[derive(Clone, Copy, Debug, ValueEnum)]
enum NotificationModeArg {
    All,
    None,
    Mentions,
    #[value(name = "important", alias = "important-only")]
    ImportantOnly,
}

#[derive(Args)]
struct NotificationsSetArgs {
    #[arg(
        long,
        value_name = "MODE",
        value_enum,
        help = "Notification mode: all, none, mentions, important"
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

    #[arg(long, help = "User id to invite")]
    user_id: Option<i64>,

    #[arg(long, help = "Email address to invite")]
    email: Option<String>,

    #[arg(long, help = "Phone number to invite")]
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

    #[arg(long, help = "Skip confirmation prompt")]
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
    if let Err(error) = run().await {
        eprintln!("{error}");
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

fn is_broken_pipe_panic(info: &std::panic::PanicInfo<'_>) -> bool {
    let message = info.to_string();
    message.contains("failed printing to stdout")
        && (message.contains("Broken pipe") || message.contains("broken pipe"))
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();
    let json_format = output::resolve_json_format(cli.pretty, cli.compact);
    let config = Config::load();
    let auth_store = AuthStore::new(config.secrets_path.clone(), config.api_base_url.clone());
    let local_db = LocalDb::new(config.state_path.clone(), config.api_base_url.clone());
    let api = ApiClient::new(config.api_base_url.clone());
    let skip_update_check = matches!(
        &cli.command,
        Command::Auth {
            command: AuthCommand::Login(_)
        } | Command::Update
            | Command::Doctor
    );
    let update_handle = if skip_update_check {
        None
    } else {
        update::spawn_update_check(&config, &local_db, cli.json)
    };

    let result = async {
        match cli.command {
            Command::Auth { command } => match command {
                AuthCommand::Login(args) => {
                    handle_login(args, &api, &auth_store, &config.realtime_url, &local_db).await?;
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
                    auth_store.clear_token()?;
                    local_db.clear_current_user()?;
                    println!("Logged out.");
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
            Command::Chats { command } => match command {
                ChatsCommand::List(args) => {
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
                                    &mut realtime,
                                    current_user.as_ref(),
                                    args.limit,
                                    args.offset,
                                )
                                .await?;
                                output::print_chat_list(&output, false, json_format)?;
                            }
                        }
                        _ => {
                            return Err("Unexpected RPC result for getChats".into());
                        }
                    }
                }
                ChatsCommand::Get(args) => {
                    let token = require_token(&auth_store)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
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
                        _ => return Err("Unexpected RPC result for getChat".into()),
                    }
                }
                ChatsCommand::Participants(args) => {
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::GetChatParticipantsInput {
                        chat_id: args.chat_id,
                    };
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
                                let output = build_chat_participants_output(payload);
                                output::print_chat_participants(&output, false, json_format)?;
                            }
                        }
                        _ => return Err("Unexpected RPC result for getChatParticipants".into()),
                    }
                }
                ChatsCommand::AddParticipant(args) => {
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::AddChatParticipantInput {
                        chat_id: args.chat_id,
                        user_id: args.user_id,
                    };
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
                                println!("Added user {} to chat {}.", args.user_id, args.chat_id);
                            }
                        }
                        _ => return Err("Unexpected RPC result for addChatParticipant".into()),
                    }
                }
                ChatsCommand::RemoveParticipant(args) => {
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::RemoveChatParticipantInput {
                        chat_id: args.chat_id,
                        user_id: args.user_id,
                    };
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
                                println!(
                                    "Removed user {} from chat {}.",
                                    args.user_id, args.chat_id
                                );
                            }
                        }
                        _ => return Err("Unexpected RPC result for removeChatParticipant".into()),
                    }
                }
                ChatsCommand::Create(args) => {
                    let title = args.title.trim();
                    if title.is_empty() {
                        return Err("Chat title cannot be empty".into());
                    }
                    if args.public && !args.participants.is_empty() {
                        return Err("Public chats cannot include explicit participants".into());
                    }
                    if args.space_id.is_none() {
                        if args.public {
                            return Err("Public home threads are not supported yet.".into());
                        }
                        if args.participants.is_empty() {
                            return Err("Provide at least one --participant for a home thread.".into());
                        }
                    }
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
                        title: title.to_string(),
                        space_id: args.space_id,
                        description,
                        emoji,
                        is_public: args.public,
                        participants,
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
                            } else {
                                if let Some(chat) = payload.chat.as_ref() {
                                    println!("Created chat {}.", chat.id);
                                } else {
                                    println!("Created chat.");
                                }
                            }
                        }
                        _ => return Err("Unexpected RPC result for createChat".into()),
                    }
                }
                ChatsCommand::CreateDm(args) => {
                    let token = require_token(&auth_store)?;
                    let payload = api.create_private_chat(&token, args.user_id).await?;
                    if cli.json {
                        output::print_json(&payload, json_format)?;
                    } else {
                        let chat_id = payload.chat.get("id").and_then(|value| value.as_i64());
                        if let Some(chat_id) = chat_id {
                            println!("Created DM chat {} with user {}.", chat_id, args.user_id);
                        } else {
                            println!("Created DM with user {}.", args.user_id);
                        }
                    }
                }
                ChatsCommand::UpdateVisibility(args) => {
                    if args.public == args.private {
                        return Err("Provide --public or --private".into());
                    }
                    if args.public && !args.participants.is_empty() {
                        return Err("Public chats cannot include explicit participants".into());
                    }
                    if args.private && args.participants.is_empty() {
                        return Err("Private chats require at least one participant.".into());
                    }

                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let participants = args
                        .participants
                        .iter()
                        .map(|user_id| proto::InputChatParticipant { user_id: *user_id })
                        .collect();
                    let input = proto::UpdateChatVisibilityInput {
                        chat_id: args.chat_id,
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
                                    println!("Updated chat {} to {}.", args.chat_id, label);
                                }
                            }
                        }
                        _ => return Err("Unexpected RPC result for updateChatVisibility".into()),
                    }
                }
                ChatsCommand::MarkUnread(args) => {
                    let token = require_token(&auth_store)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
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
                        _ => return Err("Unexpected RPC result for markAsUnread".into()),
                    }
                }
                ChatsCommand::MarkRead(args) => {
                    let token = require_token(&auth_store)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let label = peer_label_from_input(&peer);
                    let input = api::ReadMessagesInput {
                        peer_user_id: args.user_id,
                        peer_thread_id: args.chat_id,
                        max_id: args.max_id,
                    };
                    let payload = api.read_messages(&token, input).await?;
                    if cli.json {
                        output::print_json(&payload, json_format)?;
                    } else if let Some(max_id) = args.max_id {
                        println!("Marked {label} as read (max id {max_id}).");
                    } else {
                        println!("Marked {label} as read.");
                    }
                }
                ChatsCommand::Delete(args) => {
                    let prompt = format!("Delete chat {}? This cannot be undone.", args.chat_id);
                    if !confirm_action(&prompt, args.yes)? {
                        println!("Cancelled.");
                        return Ok(());
                    }
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let peer = input_peer_from_args(Some(args.chat_id), None)?;
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
                                println!("Deleted chat {}.", args.chat_id);
                            }
                        }
                        _ => return Err("Unexpected RPC result for deleteChat".into()),
                    }
                }
            },
            Command::Users { command } => match command {
                UsersCommand::List(args) => {
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
                            let mut output = build_user_list(&payload);
                            filter_users_output(&mut output, args.filter.as_deref());
                            if cli.json {
                                output::print_json(&output, json_format)?;
                            } else {
                                output::print_users(&output, false, json_format)?;
                            }
                        }
                        _ => {
                            return Err("Unexpected RPC result for getChats".into());
                        }
                    }
                }
                UsersCommand::Get(args) => {
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
                                    payload.users.iter().find(|user| user.id == args.id)
                                {
                                    output::print_json(user, json_format)?;
                                } else {
                                    return Err("User not found in getChats users list".into());
                                }
                            } else {
                                let output = build_user_list(&payload);
                                if let Some(user) = output
                                    .users
                                    .into_iter()
                                    .find(|user| user.user.id == args.id)
                                {
                                    output::print_users(
                                        &UserListOutput { users: vec![user] },
                                        false,
                                        json_format,
                                    )?;
                                } else {
                                    return Err("User not found in getChats users list".into());
                                }
                            }
                        }
                        _ => {
                            return Err("Unexpected RPC result for getChats".into());
                        }
                    }
                }
            },
            Command::Messages { command } => match command {
                MessagesCommand::List(args) => {
                    let token = require_token(&auth_store)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let peer_summary = peer_summary_from_input(&peer);
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;

                    let input = proto::GetChatHistoryInput {
                        peer_id: Some(peer.clone()),
                        offset_id: args.offset_id,
                        limit: args.limit,
                    };

                    let result = realtime
                        .call_rpc(
                            proto::Method::GetChatHistory,
                            proto::rpc_call::Input::GetChatHistory(input),
                        )
                        .await?;

                    match result {
                        proto::rpc_result::Result::GetChatHistory(mut payload) => {
                            let (since_ts, until_ts) = parse_time_filters(
                                args.since.as_deref(),
                                args.until.as_deref(),
                                Utc::now(),
                            )?;
                            filter_messages_by_time(&mut payload.messages, since_ts, until_ts);

                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
                                let translation_language = args
                                    .translate
                                    .as_deref()
                                    .map(normalize_translation_language)
                                    .transpose()?;
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
                                    _ => return Err("Unexpected RPC result for getChats".into()),
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
                            return Err("Unexpected RPC result for getChatHistory".into());
                        }
                    }
                }
                MessagesCommand::Search(args) => {
                    let token = require_token(&auth_store)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let queries = normalize_search_queries(&args.query)?;
                    let peer_summary = peer_summary_from_input(&peer);
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;

                    let input = proto::SearchMessagesInput {
                        peer_id: Some(peer.clone()),
                        queries,
                        limit: args.limit,
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
                            let (since_ts, until_ts) = parse_time_filters(
                                args.since.as_deref(),
                                args.until.as_deref(),
                                Utc::now(),
                            )?;
                            filter_messages_by_time(&mut payload.messages, since_ts, until_ts);

                            if cli.json {
                                output::print_json(&payload, json_format)?;
                            } else {
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
                                    _ => return Err("Unexpected RPC result for getChats".into()),
                                };
                                let current_user_id =
                                    local_db.load()?.current_user.map(|user| user.id);
                                let output = build_message_list_from_messages(
                                    &payload.messages,
                                    &users_by_id,
                                    current_user_id,
                                    peer_summary,
                                    peer_name_from_input(&peer, &users_by_id, &chats_by_id),
                                    None,
                                );
                                output::print_messages(&output, false, json_format)?;
                            }
                        }
                        _ => {
                            return Err("Unexpected RPC result for searchMessages".into());
                        }
                    }
                }
                MessagesCommand::Get(args) => {
                    let token = require_token(&auth_store)?;
                    let peer = input_peer_from_args(Some(args.chat_id), None)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let message =
                        fetch_message_by_id(&mut realtime, &peer, args.message_id).await?;
                    if cli.json {
                        output::print_json(&message, json_format)?;
                    } else {
                        let translation_language = args
                            .translate
                            .as_deref()
                            .map(normalize_translation_language)
                            .transpose()?;
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
                            _ => return Err("Unexpected RPC result for getChats".into()),
                        };
                        let current_user_id = local_db.load()?.current_user.map(|user| user.id);
                        let summary = message_summary(
                            &message,
                            &users_by_id,
                            current_user_id,
                            current_epoch_seconds() as i64,
                            Some(&translations_by_id),
                        );
                        print_message_detail(&summary, args.chat_id);
                    }
                }
                MessagesCommand::Send(args) => {
                    let token = require_token(&auth_store)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let reply_to = args.reply_to;
                    let caption = resolve_message_caption(args.text, args.stdin)?;
                    let attachments = prepare_attachments(
                        &args.attachments,
                        &config.data_dir,
                        args.force_file,
                        cli.json,
                    )?;

                    let mention_entities = parse_mention_entities(&args.mentions)?;
                    if mention_entities.is_some() && caption.is_none() {
                        return Err("Mentions require --text or --stdin".into());
                    }
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    if attachments.is_empty() {
                        let text = caption
                            .ok_or_else(|| "Provide --text, --stdin, or --attach".to_string())?;
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
                MessagesCommand::Export(args) => {
                    let token = require_token(&auth_store)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::GetChatHistoryInput {
                        peer_id: Some(peer),
                        offset_id: args.offset_id,
                        limit: args.limit,
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::GetChatHistory,
                            proto::rpc_call::Input::GetChatHistory(input),
                        )
                        .await?;
                    match result {
                        proto::rpc_result::Result::GetChatHistory(mut payload) => {
                            let (since_ts, until_ts) = parse_time_filters(
                                args.since.as_deref(),
                                args.until.as_deref(),
                                Utc::now(),
                            )?;
                            filter_messages_by_time(&mut payload.messages, since_ts, until_ts);

                            let output_path = args.output;
                            let payload_text = output::json_string(&payload, json_format)?;
                            if let Some(parent) = output_path.parent() {
                                fs::create_dir_all(parent)?;
                            }
                            fs::write(&output_path, payload_text.as_bytes())?;
                            let message_count = payload.messages.len();
                            let bytes = payload_text.as_bytes().len();
                            if cli.json {
                                let output = ExportOutput {
                                    path: output_path.display().to_string(),
                                    format: "json".to_string(),
                                    messages: message_count,
                                    bytes,
                                };
                                output::print_json(&output, json_format)?;
                            } else {
                                println!(
                                    "Exported {} message(s) to {}.",
                                    message_count,
                                    output_path.display()
                                );
                            }
                        }
                        _ => return Err("Unexpected RPC result for getChatHistory".into()),
                    }
                }
                MessagesCommand::Download(args) => {
                    let token = require_token(&auth_store)?;
                    if args.output.is_some() && args.dir.is_some() {
                        return Err("Provide only one of --output or --dir".into());
                    }
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let message =
                        fetch_message_by_id(&mut realtime, &peer, args.message_id).await?;
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
                }
                MessagesCommand::Delete(args) => {
                    let token = require_token(&auth_store)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let message_count = args.message_ids.len();
                    let prompt = format!(
                        "Delete {} message(s) from {}?",
                        message_count,
                        peer_label_from_input(&peer)
                    );
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
                        _ => return Err("Unexpected RPC result for deleteMessages".into()),
                    }
                }
                MessagesCommand::Edit(args) => {
                    let token = require_token(&auth_store)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let text = resolve_message_caption(args.text, args.stdin)?
                        .ok_or_else(|| "Provide --text or --stdin".to_string())?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::EditMessageInput {
                        message_id: args.message_id,
                        peer_id: Some(peer),
                        text,
                        entities: None,
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
                        _ => return Err("Unexpected RPC result for editMessage".into()),
                    }
                }
                MessagesCommand::AddReaction(args) => {
                    let token = require_token(&auth_store)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let emoji = args.emoji.trim().to_string();
                    if emoji.is_empty() {
                        return Err("Emoji cannot be empty".into());
                    }
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::AddReactionInput {
                        emoji,
                        message_id: args.message_id,
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
                        _ => return Err("Unexpected RPC result for addReaction".into()),
                    }
                }
                MessagesCommand::DeleteReaction(args) => {
                    let token = require_token(&auth_store)?;
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let emoji = args.emoji.trim().to_string();
                    if emoji.is_empty() {
                        return Err("Emoji cannot be empty".into());
                    }
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::DeleteReactionInput {
                        emoji,
                        peer_id: Some(peer),
                        message_id: args.message_id,
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
                        _ => return Err("Unexpected RPC result for deleteReaction".into()),
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
                            return Err("Unexpected RPC result for getChats".into());
                        }
                    }
                }
                SpacesCommand::Members(args) => {
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::GetSpaceMembersInput {
                        space_id: args.space_id,
                    };
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
                        _ => return Err("Unexpected RPC result for getSpaceMembers".into()),
                    }
                }
                SpacesCommand::Invite(args) => {
                    let token = require_token(&auth_store)?;
                    let via = invite_target_from_args(&args)?;
                    let role = invite_role_from_args(args.admin, args.public_chats)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::InviteToSpaceInput {
                        space_id: args.space_id,
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
                                println!("Invited {} to space {}.", name, args.space_id);
                            }
                        }
                        _ => return Err("Unexpected RPC result for inviteToSpace".into()),
                    }
                }
                SpacesCommand::DeleteMember(args) => {
                    let prompt =
                        format!("Remove user {} from space {}?", args.user_id, args.space_id);
                    if !confirm_action(&prompt, args.yes)? {
                        println!("Cancelled.");
                        return Ok(());
                    }
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::DeleteMemberInput {
                        space_id: args.space_id,
                        user_id: args.user_id,
                    };
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
                        _ => return Err("Unexpected RPC result for deleteMember".into()),
                    }
                }
                SpacesCommand::UpdateMemberAccess(args) => {
                    let token = require_token(&auth_store)?;
                    let role =
                        require_member_access_role(args.admin, args.member, args.public_chats)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let input = proto::UpdateMemberAccessInput {
                        space_id: args.space_id,
                        user_id: args.user_id,
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
                        _ => return Err("Unexpected RPC result for updateMemberAccess".into()),
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
                        _ => return Err("Unexpected RPC result for getUserSettings".into()),
                    }
                }
                NotificationsCommand::Set(args) => {
                    if args.mode.is_none() && !args.silent && !args.sound {
                        return Err(
                            "Provide at least one of --mode, --silent, or --sound".into(),
                        );
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
                    }
                    if args.silent {
                        values.silent = true;
                    } else if args.sound {
                        values.silent = false;
                    }

                    let notification_settings = proto::NotificationSettings {
                        mode: Some(values.mode as i32),
                        silent: Some(values.silent),
                        zen_mode_requires_mention: Some(values.zen_requires_mention),
                        zen_mode_uses_default_rules: Some(values.zen_uses_default_rules),
                        zen_mode_custom_rules: Some(values.zen_custom_rules),
                        disable_dm_notifications: Some(values.disable_dm_notifications),
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
                        _ => return Err("Unexpected RPC result for updateUserSettings".into()),
                    }
                }
            },
            Command::Tasks { command } => match command {
                TasksCommand::CreateLinear(args) => {
                    let token = require_token(&auth_store)?;
                    let mut realtime =
                        RealtimeClient::connect(&config.realtime_url, &token).await?;

                    // Get current user id
                    let me = fetch_me(&mut realtime).await?;
                    let from_id = me.id;

                    // Get message to extract text
                    let peer = input_peer_from_args(Some(args.chat_id), None)?;
                    let offset_id = args
                        .message_id
                        .checked_add(1)
                        .ok_or("Message id is too large")?;
                    let input = proto::GetChatHistoryInput {
                        peer_id: Some(peer.clone()),
                        offset_id: Some(offset_id),
                        limit: Some(1),
                    };
                    let result = realtime
                        .call_rpc(
                            proto::Method::GetChatHistory,
                            proto::rpc_call::Input::GetChatHistory(input),
                        )
                        .await?;

                    let message = match result {
                        proto::rpc_result::Result::GetChatHistory(payload) => payload
                            .messages
                            .into_iter()
                            .find(|message| message.id == args.message_id)
                            .ok_or("Message not found")?,
                        _ => return Err("Unexpected RPC result for getChatHistory".into()),
                    };

                    let text = message.message.unwrap_or_default();
                    if text.trim().is_empty() {
                        return Err("Message has no text content".into());
                    }

                    let api_input = CreateLinearIssueInput {
                        text,
                        message_id: args.message_id,
                        chat_id: args.chat_id,
                        from_id,
                        peer_user_id: None,
                        peer_thread_id: Some(args.chat_id),
                        space_id: args.space_id,
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
                    let token = require_token(&auth_store)?;

                    let api_input = CreateNotionTaskInput {
                        space_id: args.space_id,
                        message_id: args.message_id,
                        chat_id: args.chat_id,
                        peer_user_id: None,
                        peer_thread_id: Some(args.chat_id),
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

    update::finish_update_check(update_handle).await;
    result
}

async fn handle_login(
    args: AuthLoginArgs,
    api: &ApiClient,
    auth_store: &AuthStore,
    realtime_url: &str,
    local_db: &LocalDb,
) -> Result<(), Box<dyn std::error::Error>> {
    let device_name = hostname::get()
        .ok()
        .and_then(|name| name.into_string().ok());
    let client_type = "cli";
    let client_version = env!("CARGO_PKG_VERSION");

    let mut contact = contact_from_args(args)?;

    loop {
        let current = match contact.take() {
            Some(value) => value,
            None => prompt_contact()?,
        };

        match &current {
            Contact::Email(email) => {
                api.send_email_code(email).await?;
            }
            Contact::Phone(phone) => {
                api.send_sms_code(phone).await?;
            }
        }

        loop {
            let code = prompt_code()?;
            let result = match &current {
                Contact::Email(email) => {
                    api.verify_email_code(
                        email,
                        &code,
                        client_type,
                        client_version,
                        device_name.as_deref(),
                    )
                    .await
                }
                Contact::Phone(phone) => {
                    api.verify_sms_code(
                        phone,
                        &code,
                        client_type,
                        client_version,
                        device_name.as_deref(),
                    )
                    .await
                }
            };

            match result {
                Ok(result) => {
                    auth_store.store_token(&result.token)?;
                    let mut realtime = RealtimeClient::connect(realtime_url, &result.token).await?;
                    match fetch_me(&mut realtime).await {
                        Ok(me) => {
                            local_db.set_current_user(me.clone())?;
                            let name = user_display_name(&me);
                            println!("Welcome, {}.", name);
                        }
                        Err(error) => {
                            eprintln!("Logged in, but failed to load profile: {error}");
                            println!("Logged in as user {}.", result.user_id);
                        }
                    }
                    return Ok(());
                }
                Err(error) => {
                    print_auth_error(&error);
                    let retry = Select::new()
                        .items(&["Try code again", "Edit email/phone"])
                        .default(0)
                        .interact()?;
                    if retry == 0 {
                        continue;
                    }
                    contact = None;
                    break;
                }
            }
        }
    }
}

fn prompt_code() -> Result<String, Box<dyn std::error::Error>> {
    let code: String = Input::new().with_prompt("Code").interact_text()?;
    Ok(code.trim().to_string())
}

fn contact_from_args(args: AuthLoginArgs) -> Result<Option<Contact>, Box<dyn std::error::Error>> {
    if args.email.is_some() && args.phone.is_some() {
        return Err("Provide only one of --email or --phone".into());
    }

    if let Some(email) = args.email {
        return Ok(Some(Contact::Email(email.trim().to_string())));
    }

    if let Some(phone) = args.phone {
        return Ok(Some(Contact::Phone(phone.trim().to_string())));
    }

    Ok(None)
}

fn prompt_contact() -> Result<Contact, Box<dyn std::error::Error>> {
    let options = ["Email", "Phone"];
    let selection = Select::new().items(&options).default(0).interact()?;

    match selection {
        0 => {
            let email: String = Input::new().with_prompt("Email").interact_text()?;
            Ok(Contact::Email(email.trim().to_string()))
        }
        _ => {
            let phone: String = Input::new()
                .with_prompt("Phone (E.164 recommended)")
                .interact_text()?;
            Ok(Contact::Phone(phone.trim().to_string()))
        }
    }
}

fn confirm_action(prompt: &str, assume_yes: bool) -> Result<bool, Box<dyn std::error::Error>> {
    if assume_yes {
        return Ok(true);
    }
    let confirmed = Confirm::new()
        .with_prompt(prompt)
        .default(false)
        .interact()?;
    Ok(confirmed)
}

fn resolve_message_caption(
    text: Option<String>,
    stdin: bool,
) -> Result<Option<String>, Box<dyn std::error::Error>> {
    if stdin {
        use std::io::Read;
        let mut buffer = String::new();
        std::io::stdin().read_to_string(&mut buffer)?;
        let trimmed = buffer.trim();
        if trimmed.is_empty() {
            return Err("stdin was empty".into());
        }
        return Ok(Some(trimmed.to_string()));
    }

    if let Some(text) = text {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return Err("message text is empty".into());
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
    };

    let result = realtime
        .call_rpc(
            proto::Method::SendMessage,
            proto::rpc_call::Input::SendMessage(input),
        )
        .await?;

    match result {
        proto::rpc_result::Result::SendMessage(payload) => Ok(payload),
        _ => Err("Unexpected RPC result for sendMessage".into()),
    }
}

#[derive(Clone)]
struct PreparedAttachment {
    upload_path: PathBuf,
    display_name: String,
    file_name: String,
    mime_type: Option<String>,
    file_type: UploadFileType,
    video_metadata: Option<UploadVideoMetadata>,
    size_bytes: u64,
    cleanup_path: Option<PathBuf>,
}

impl Drop for PreparedAttachment {
    fn drop(&mut self) {
        if let Some(path) = self.cleanup_path.take() {
            let _ = fs::remove_file(path);
        }
    }
}

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

        let upload = api
            .upload_file(
                token,
                UploadFileInput {
                    path: attachment.upload_path.clone(),
                    file_name: attachment.file_name.clone(),
                    mime_type: attachment.mime_type.clone(),
                    file_type: attachment.file_type.clone(),
                    video_metadata: attachment.video_metadata.clone(),
                },
            )
            .await?;

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
        updates.extend(send.updates.into_iter());
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

fn prepare_attachments(
    paths: &[PathBuf],
    data_dir: &Path,
    force_file: bool,
    quiet: bool,
) -> Result<Vec<PreparedAttachment>, Box<dyn std::error::Error>> {
    if paths.is_empty() {
        return Ok(Vec::new());
    }

    let mut prepared = Vec::with_capacity(paths.len());
    for path in paths {
        let metadata =
            fs::metadata(path).map_err(|_| format!("Attachment not found: {}", path.display()))?;
        if metadata.is_dir() {
            prepared.push(prepare_directory_attachment(path, data_dir, quiet)?);
        } else if metadata.is_file() {
            prepared.push(prepare_file_attachment(
                path,
                metadata.len(),
                force_file,
                quiet,
            )?);
        } else {
            return Err(format!("Attachment is not a file or folder: {}", path.display()).into());
        }
    }

    Ok(prepared)
}

fn prepare_directory_attachment(
    path: &Path,
    data_dir: &Path,
    quiet: bool,
) -> Result<PreparedAttachment, Box<dyn std::error::Error>> {
    if !quiet {
        eprintln!("Zipping folder {}...", path.display());
    }
    let (zip_path, zip_name) = zip_directory(path, data_dir)?;
    let size = fs::metadata(&zip_path)?.len();
    ensure_attachment_size(&zip_name, size, quiet)?;

    Ok(PreparedAttachment {
        upload_path: zip_path.clone(),
        display_name: path.display().to_string(),
        file_name: zip_name,
        mime_type: Some("application/zip".to_string()),
        file_type: UploadFileType::Document,
        video_metadata: None,
        size_bytes: size,
        cleanup_path: Some(zip_path),
    })
}

fn prepare_file_attachment(
    path: &Path,
    size: u64,
    force_file: bool,
    quiet: bool,
) -> Result<PreparedAttachment, Box<dyn std::error::Error>> {
    let display_name = path.display().to_string();
    ensure_attachment_size(&display_name, size, quiet)?;

    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| "Attachment file name is invalid")?
        .to_string();

    let mime_type = mime_guess::from_path(path)
        .first()
        .map(|mime| mime.essence_str().to_string());

    let mut file_type = match mime_type.as_deref() {
        Some(value) if value.starts_with("image/") => UploadFileType::Photo,
        Some(value) if value.starts_with("video/") => UploadFileType::Video,
        _ => UploadFileType::Document,
    };

    if force_file && matches!(file_type, UploadFileType::Photo | UploadFileType::Video) {
        file_type = UploadFileType::Document;
    }

    let mut video_metadata = None;
    if matches!(file_type, UploadFileType::Video) {
        if let Some(metadata) = probe_video_metadata(path) {
            video_metadata = Some(metadata);
        } else if !quiet {
            eprintln!(
                "Warning: could not read video metadata for {}. Uploading as document.",
                display_name
            );
            file_type = UploadFileType::Document;
        }
    }

    Ok(PreparedAttachment {
        upload_path: path.to_path_buf(),
        display_name,
        file_name,
        mime_type,
        file_type,
        video_metadata,
        size_bytes: size,
        cleanup_path: None,
    })
}

fn ensure_attachment_size(
    label: &str,
    size: u64,
    quiet: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    if size > MAX_ATTACHMENT_BYTES {
        let size_label = format_bytes(size as i64);
        if !quiet {
            eprintln!("Attachment {} is {} (limit 200MB).", label, size_label);
        }
        return Err("Attachment exceeds 200MB limit".into());
    }
    Ok(())
}

fn zip_directory(
    dir: &Path,
    data_dir: &Path,
) -> Result<(PathBuf, String), Box<dyn std::error::Error>> {
    fs::create_dir_all(data_dir)?;
    let folder_name = dir
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("folder");
    let zip_name = format!("{}.zip", folder_name);
    let zip_path = data_dir.join(format!("{}-{}.zip", folder_name, current_epoch_seconds()));

    let file = fs::File::create(&zip_path)?;
    let mut zip = zip::ZipWriter::new(file);
    let options = zip::write::FileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .unix_permissions(0o644);

    let mut has_entries = false;
    for entry in walkdir::WalkDir::new(dir)
        .into_iter()
        .filter_map(Result::ok)
    {
        if entry.path() == dir {
            continue;
        }
        if entry.file_type().is_symlink() {
            continue;
        }

        let relative = entry.path().strip_prefix(dir)?;
        let mut name = relative.to_string_lossy().replace('\\', "/");
        if entry.file_type().is_dir() {
            name.push('/');
            zip.add_directory(name, options)?;
            continue;
        }

        if entry.file_type().is_file() {
            has_entries = true;
            zip.start_file(name, options)?;
            let mut input = fs::File::open(entry.path())?;
            io::copy(&mut input, &mut zip)?;
        }
    }

    zip.finish()?;

    if !has_entries {
        return Err("Folder has no files to upload.".into());
    }

    Ok((zip_path, zip_name))
}

fn probe_video_metadata(path: &Path) -> Option<UploadVideoMetadata> {
    let output = std::process::Command::new("ffprobe")
        .arg("-v")
        .arg("error")
        .arg("-select_streams")
        .arg("v:0")
        .arg("-show_entries")
        .arg("stream=width,height,duration")
        .arg("-of")
        .arg("json")
        .arg(path)
        .output();

    let output = match output {
        Ok(output) if output.status.success() => output,
        _ => return None,
    };

    let parsed: FfprobeOutput = serde_json::from_slice(&output.stdout).ok()?;
    let stream = parsed.streams.into_iter().next()?;
    let width = stream.width?;
    let height = stream.height?;
    let duration = stream
        .duration
        .and_then(|value| value.parse::<f64>().ok())?;
    if width <= 0 || height <= 0 {
        return None;
    }
    let duration = duration.ceil() as i32;
    if duration <= 0 {
        return None;
    }

    Some(UploadVideoMetadata {
        width,
        height,
        duration,
    })
}

#[derive(serde::Deserialize)]
struct FfprobeOutput {
    streams: Vec<FfprobeStream>,
}

#[derive(serde::Deserialize)]
struct FfprobeStream {
    width: Option<i32>,
    height: Option<i32>,
    duration: Option<String>,
}

fn input_media_from_upload(
    upload: &UploadFileResult,
) -> Result<proto::InputMedia, Box<dyn std::error::Error>> {
    if let Some(photo_id) = upload.photo_id {
        return Ok(proto::InputMedia {
            media: Some(proto::input_media::Media::Photo(proto::InputMediaPhoto {
                photo_id,
            })),
        });
    }
    if let Some(video_id) = upload.video_id {
        return Ok(proto::InputMedia {
            media: Some(proto::input_media::Media::Video(proto::InputMediaVideo {
                video_id,
            })),
        });
    }
    if let Some(document_id) = upload.document_id {
        return Ok(proto::InputMedia {
            media: Some(proto::input_media::Media::Document(
                proto::InputMediaDocument { document_id },
            )),
        });
    }
    Err("Upload response missing media id".into())
}

fn require_token(auth_store: &AuthStore) -> Result<String, Box<dyn std::error::Error>> {
    match auth_store.load_token()? {
        Some(token) => Ok(token),
        None => Err("No token found. Run `inline auth login` first.".into()),
    }
}

fn input_peer_from_args(
    chat_id: Option<i64>,
    user_id: Option<i64>,
) -> Result<proto::InputPeer, Box<dyn std::error::Error>> {
    match (chat_id, user_id) {
        (Some(_), Some(_)) => Err("Provide only one of --chat-id or --user-id".into()),
        (Some(chat_id), None) => Ok(proto::InputPeer {
            r#type: Some(proto::input_peer::Type::Chat(proto::InputPeerChat {
                chat_id,
            })),
        }),
        (None, Some(user_id)) => Ok(proto::InputPeer {
            r#type: Some(proto::input_peer::Type::User(proto::InputPeerUser {
                user_id,
            })),
        }),
        (None, None) => Err("Provide --chat-id or --user-id".into()),
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
        target = Some(proto::invite_to_space_input::Via::UserId(user_id));
    }
    if let Some(email) = args.email.as_ref() {
        if target.is_some() {
            return Err("Provide only one of --user-id, --email, or --phone".into());
        }
        let trimmed = email.trim();
        if trimmed.is_empty() {
            return Err("Email cannot be empty".into());
        }
        target = Some(proto::invite_to_space_input::Via::Email(
            trimmed.to_string(),
        ));
    }
    if let Some(phone) = args.phone.as_ref() {
        if target.is_some() {
            return Err("Provide only one of --user-id, --email, or --phone".into());
        }
        let trimmed = phone.trim();
        if trimmed.is_empty() {
            return Err("Phone number cannot be empty".into());
        }
        target = Some(proto::invite_to_space_input::Via::PhoneNumber(
            trimmed.to_string(),
        ));
    }
    target.ok_or_else(|| "Provide --user-id, --email, or --phone".into())
}

fn invite_role_from_args(
    admin: bool,
    public_chats: bool,
) -> Result<Option<proto::SpaceMemberRole>, Box<dyn std::error::Error>> {
    if admin && public_chats {
        return Err("Provide only one of --admin or --public-chats".into());
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
        return Err("Provide only one of --admin or --member/--public-chats".into());
    }
    if admin {
        return Ok(space_member_role_admin());
    }
    if !member && !public_chats {
        return Err("Provide --admin or --member (or --public-chats)".into());
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
        proto::rpc_result::Result::GetMe(payload) => payload.user.ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::Other, "getMe returned no user").into()
        }),
        _ => Err("Unexpected RPC result for getMe".into()),
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
        _ => Err("Unexpected RPC result for getUserSettings".into()),
    }
}

struct NotificationSettingsValues {
    mode: proto::notification_settings::Mode,
    silent: bool,
    zen_requires_mention: bool,
    zen_uses_default_rules: bool,
    zen_custom_rules: String,
    disable_dm_notifications: bool,
}

fn notification_settings_values(
    settings: Option<&proto::NotificationSettings>,
) -> NotificationSettingsValues {
    let mode = match settings
        .and_then(|value| value.mode)
        .and_then(|value| proto::notification_settings::Mode::try_from(value).ok())
    {
        Some(proto::notification_settings::Mode::All) => proto::notification_settings::Mode::All,
        Some(proto::notification_settings::Mode::None) => proto::notification_settings::Mode::None,
        Some(proto::notification_settings::Mode::Mentions) => {
            proto::notification_settings::Mode::Mentions
        }
        Some(proto::notification_settings::Mode::ImportantOnly) => {
            proto::notification_settings::Mode::ImportantOnly
        }
        _ => proto::notification_settings::Mode::All,
    };
    let silent = settings.and_then(|value| value.silent).unwrap_or(false);
    let zen_requires_mention = settings
        .and_then(|value| value.zen_mode_requires_mention)
        .unwrap_or(true);
    let zen_uses_default_rules = settings
        .and_then(|value| value.zen_mode_uses_default_rules)
        .unwrap_or(true);
    let zen_custom_rules = settings
        .and_then(|value| value.zen_mode_custom_rules.clone())
        .unwrap_or_default();
    let disable_dm_notifications = settings
        .and_then(|value| value.disable_dm_notifications)
        .unwrap_or(false);

    NotificationSettingsValues {
        mode,
        silent,
        zen_requires_mention,
        zen_uses_default_rules,
        zen_custom_rules,
        disable_dm_notifications,
    }
}

fn notification_mode_from_arg(
    mode: NotificationModeArg,
) -> proto::notification_settings::Mode {
    match mode {
        NotificationModeArg::All => proto::notification_settings::Mode::All,
        NotificationModeArg::None => proto::notification_settings::Mode::None,
        NotificationModeArg::Mentions => proto::notification_settings::Mode::Mentions,
        NotificationModeArg::ImportantOnly => {
            proto::notification_settings::Mode::ImportantOnly
        }
    }
}

fn notification_mode_label(mode: proto::notification_settings::Mode) -> &'static str {
    match mode {
        proto::notification_settings::Mode::All => "all",
        proto::notification_settings::Mode::None => "none",
        proto::notification_settings::Mode::Mentions => "mentions",
        proto::notification_settings::Mode::ImportantOnly => "important",
        _ => "all",
    }
}

fn print_notification_settings(settings: Option<&proto::UserSettings>) {
    let values = notification_settings_values(
        settings.and_then(|value| value.notification_settings.as_ref()),
    );
    println!("Notification settings");
    println!("  mode: {}", notification_mode_label(values.mode));
    println!("  silent: {}", if values.silent { "yes" } else { "no" });
    println!(
        "  disable dm notifications: {}",
        if values.disable_dm_notifications { "yes" } else { "no" }
    );
    println!(
        "  zen requires mention: {}",
        if values.zen_requires_mention { "yes" } else { "no" }
    );
    println!(
        "  zen uses default rules: {}",
        if values.zen_uses_default_rules { "yes" } else { "no" }
    );
    if values.zen_custom_rules.is_empty() {
        println!("  zen custom rules: -");
    } else {
        println!("  zen custom rules: {}", values.zen_custom_rules);
    }
}

fn apply_chat_list_limits(
    mut payload: proto::GetChatsResult,
    limit: Option<usize>,
    offset: Option<usize>,
) -> proto::GetChatsResult {
    let offset = offset.unwrap_or(0);
    let limit = limit.unwrap_or(payload.chats.len());
    payload.chats = payload.chats.into_iter().skip(offset).take(limit).collect();
    payload
}

async fn build_chat_list(
    result: proto::GetChatsResult,
    realtime: &mut RealtimeClient,
    current_user: Option<&proto::User>,
    limit: Option<usize>,
    offset: Option<usize>,
) -> Result<ChatListOutput, Box<dyn std::error::Error>> {
    struct MissingLastMessage {
        index: usize,
        peer: proto::InputPeer,
    }

    let now = current_epoch_seconds() as i64;
    let current_user_id = current_user.map(|user| user.id);
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

    let mut items = Vec::with_capacity(result.chats.len());
    let mut missing_last_messages: Vec<MissingLastMessage> = Vec::new();
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
        if last_message.is_none() {
            if let Some(peer) = chat.peer_id.as_ref().and_then(input_peer_from_peer) {
                missing_last_messages.push(MissingLastMessage {
                    index: items.len(),
                    peer,
                });
            }
        }
        let last_message_summary = last_message
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

        items.push(ChatListItem {
            chat: chat.clone(),
            dialog,
            peer,
            display_name,
            space,
            space_name,
            unread_count,
            last_message: last_message_summary,
            last_message_line,
            last_message_relative_date,
        });
    }

    if !missing_last_messages.is_empty() {
        let peers: Vec<proto::InputPeer> = missing_last_messages
            .iter()
            .map(|missing| missing.peer.clone())
            .collect();
        match fetch_last_messages(realtime, &peers).await {
            Ok(messages) => {
                for (missing, message) in missing_last_messages.iter().zip(messages) {
                    let Some(message) = message else { continue };
                    let summary =
                        message_summary(&message, &users_by_id, current_user_id, now, None);
                    let line = if summary.preview.is_empty() {
                        summary.sender_name.clone()
                    } else {
                        format!("{}: {}", summary.sender_name, summary.preview)
                    };
                    if let Some(item) = items.get_mut(missing.index) {
                        item.last_message = Some(summary.clone());
                        item.last_message_line = Some(line);
                        item.last_message_relative_date = Some(summary.relative_date.clone());
                    }
                }
            }
            Err(error) => {
                eprintln!("Failed to load last messages: {error}");
            }
        }
    }

    items.sort_by_key(|item| {
        Reverse(
            item.last_message
                .as_ref()
                .map(|message| message.message.date)
                .unwrap_or(0),
        )
    });

    let offset = offset.unwrap_or(0);
    let limit = limit.unwrap_or(items.len());
    let items = items.into_iter().skip(offset).take(limit).collect();

    Ok(ChatListOutput { items, raw: result })
}

fn build_user_list(result: &proto::GetChatsResult) -> UserListOutput {
    let users = result.users.iter().map(|user| user_summary(user)).collect();
    UserListOutput { users }
}

fn build_space_list(result: &proto::GetChatsResult) -> SpaceListOutput {
    let spaces = result
        .spaces
        .iter()
        .map(|space| space_summary(space))
        .collect();
    SpaceListOutput { spaces }
}

fn build_space_members_output(result: proto::GetSpaceMembersResult) -> SpaceMembersOutput {
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

fn build_chat_participants_output(
    result: proto::GetChatParticipantsResult,
) -> ChatParticipantsOutput {
    let now = current_epoch_seconds() as i64;
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

fn build_message_list(
    result: proto::GetChatHistoryResult,
    users_by_id: &HashMap<i64, proto::User>,
    current_user_id: Option<i64>,
    peer: Option<PeerSummary>,
    peer_name: Option<String>,
    translations_by_id: Option<&HashMap<i64, proto::MessageTranslation>>,
) -> MessageListOutput {
    build_message_list_from_messages(
        &result.messages,
        users_by_id,
        current_user_id,
        peer,
        peer_name,
        translations_by_id,
    )
}

fn build_message_list_from_messages(
    messages: &[proto::Message],
    users_by_id: &HashMap<i64, proto::User>,
    current_user_id: Option<i64>,
    peer: Option<PeerSummary>,
    peer_name: Option<String>,
    translations_by_id: Option<&HashMap<i64, proto::MessageTranslation>>,
) -> MessageListOutput {
    let now = current_epoch_seconds() as i64;
    let items = messages
        .iter()
        .map(|message| {
            message_summary(
                message,
                users_by_id,
                current_user_id,
                now,
                translations_by_id,
            )
        })
        .collect();
    MessageListOutput {
        items,
        peer,
        peer_name,
    }
}

fn normalize_search_queries(queries: &[String]) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let normalized: Vec<String> = queries
        .iter()
        .map(|query| query.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|query| !query.is_empty())
        .collect();

    if normalized.is_empty() {
        return Err("Provide --query (repeatable)".into());
    }

    Ok(normalized)
}

fn parse_time_filters(
    since: Option<&str>,
    until: Option<&str>,
    now: DateTime<Utc>,
) -> Result<(Option<i64>, Option<i64>), Box<dyn std::error::Error>> {
    let since_ts = since
        .map(|value| parse_relative_time(value, now))
        .transpose()
        .map_err(|e| format!("invalid --since: {e}"))?;
    let until_ts = until
        .map(|value| parse_relative_time(value, now))
        .transpose()
        .map_err(|e| format!("invalid --until: {e}"))?;

    if let (Some(s), Some(u)) = (since_ts, until_ts) {
        if u < s {
            return Err("--until must be on or after --since".into());
        }
    }

    Ok((since_ts, until_ts))
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
        let after_since = since_ts.map_or(true, |ts| msg_ts >= ts);
        let before_until = until_ts.map_or(true, |ts| msg_ts <= ts);
        after_since && before_until
    });
}

fn normalize_translation_language(language: &str) -> Result<String, Box<dyn std::error::Error>> {
    let trimmed = language.trim();
    if trimmed.is_empty() {
        return Err("Provide a language code for --translate".into());
    }
    Ok(trimmed.to_string())
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
            return Err(format!(
                "Invalid mention '{raw}'. Use USER_ID:OFFSET:LENGTH (offset/length are UTF-16 units)."
            )
            .into());
        }
        let user_id: i64 = parts[0]
            .trim()
            .parse()
            .map_err(|_| format!("Invalid mention user id in '{raw}'"))?;
        let offset: i64 = parts[1]
            .trim()
            .parse()
            .map_err(|_| format!("Invalid mention offset in '{raw}'"))?;
        let length: i64 = parts[2]
            .trim()
            .parse()
            .map_err(|_| format!("Invalid mention length in '{raw}'"))?;

        if user_id <= 0 {
            return Err(format!("Mention user id must be positive in '{raw}'").into());
        }
        if offset < 0 {
            return Err(format!("Mention offset must be >= 0 in '{raw}'").into());
        }
        if length <= 0 {
            return Err(format!("Mention length must be > 0 in '{raw}'").into());
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
        _ => Err("Unexpected RPC result for translateMessages".into()),
    }
}

fn print_message_detail(summary: &MessageSummary, chat_id: i64) {
    println!("Message {} (chat {})", summary.message.id, chat_id);
    println!("from: {}", summary.sender_name);
    println!("when: {} ({})", summary.relative_date, summary.message.date);
    let text = summary
        .message
        .message
        .as_deref()
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .unwrap_or("<non-text>");
    println!("text: {}", text);

    if let Some(translation) = &summary.translation {
        let translated = translation.translation.trim();
        if translated.is_empty() {
            println!("translation ({}): <empty>", translation.language);
        } else {
            println!("translation ({}): {}", translation.language, translated);
        }
    } else {
        println!("translation: -");
    }

    if let Some(media) = &summary.media {
        println!("media: {}", format_media_detail(media));
    } else {
        println!("media: -");
    }

    if summary.attachments.is_empty() {
        println!("attachments: -");
    } else {
        println!("attachments:");
        for attachment in &summary.attachments {
            println!("  - {}", format_attachment_detail(attachment));
        }
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

fn message_summary(
    message: &proto::Message,
    users_by_id: &HashMap<i64, proto::User>,
    current_user_id: Option<i64>,
    now: i64,
    translations_by_id: Option<&HashMap<i64, proto::MessageTranslation>>,
) -> MessageSummary {
    let media = message_media_summary(message);
    let attachments = message_attachment_summaries(message);
    let translation = translations_by_id
        .and_then(|translations| translations.get(&message.id))
        .cloned();
    let preview = message_preview(message, media.as_ref(), &attachments, translation.as_ref());
    let sender = users_by_id.get(&message.from_id).map(user_summary);
    let sender_name = if message.out || current_user_id == Some(message.from_id) {
        "You".to_string()
    } else if let Some(sender) = &sender {
        sender.display_name.clone()
    } else {
        format!("user {}", message.from_id)
    };
    let relative_date = format_relative_date(message.date, now);
    MessageSummary {
        message: message.clone(),
        preview,
        translation,
        sender,
        sender_name,
        relative_date,
        media,
        attachments,
    }
}

fn user_summary(user: &proto::User) -> UserSummary {
    UserSummary {
        display_name: user_display_name(user),
        user: user.clone(),
    }
}

fn filter_users_output(output: &mut UserListOutput, filter: Option<&str>) {
    let Some(filter) = filter.map(str::trim).filter(|filter| !filter.is_empty()) else {
        return;
    };
    let needle = filter.to_lowercase();
    output.users.retain(|user| user_matches_filter(user, &needle));
}

fn user_matches_filter(user: &UserSummary, needle: &str) -> bool {
    if user.display_name.to_lowercase().contains(needle) {
        return true;
    }
    if let Some(first) = user.user.first_name.as_deref() {
        if first.to_lowercase().contains(needle) {
            return true;
        }
    }
    if let Some(last) = user.user.last_name.as_deref() {
        if last.to_lowercase().contains(needle) {
            return true;
        }
    }
    if let Some(username) = user.user.username.as_deref() {
        if username.to_lowercase().contains(needle) {
            return true;
        }
    }
    if let Some(email) = user.user.email.as_deref() {
        if email.to_lowercase().contains(needle) {
            return true;
        }
    }
    if let Some(phone) = user.user.phone_number.as_deref() {
        if phone.to_lowercase().contains(needle) {
            return true;
        }
    }
    false
}

fn space_summary(space: &proto::Space) -> SpaceSummary {
    SpaceSummary {
        display_name: space.name.clone(),
        space: space.clone(),
    }
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

fn user_display_name(user: &proto::User) -> String {
    let mut parts = Vec::new();
    if let Some(first) = user.first_name.as_deref() {
        if !first.trim().is_empty() {
            parts.push(first.trim());
        }
    }
    if let Some(last) = user.last_name.as_deref() {
        if !last.trim().is_empty() {
            parts.push(last.trim());
        }
    }
    if !parts.is_empty() {
        return parts.join(" ");
    }
    if let Some(username) = user.username.as_deref() {
        if !username.trim().is_empty() {
            return format!("@{}", username.trim());
        }
    }
    if let Some(email) = user.email.as_deref() {
        if !email.trim().is_empty() {
            return email.trim().to_string();
        }
    }
    if let Some(phone) = user.phone_number.as_deref() {
        if !phone.trim().is_empty() {
            return phone.trim().to_string();
        }
    }
    format!("user {}", user.id)
}

fn chat_display_name(chat: &proto::Chat, users_by_id: &HashMap<i64, proto::User>) -> String {
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

fn print_chat_details(chat: &proto::Chat, dialog: Option<&proto::Dialog>) {
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

    println!("Chat {}: {}", chat.id, name);
    if let Some(space_id) = chat.space_id {
        println!("  space: {}", space_id);
    }
    if let Some(is_public) = chat.is_public {
        println!("  public: {}", if is_public { "yes" } else { "no" });
    }
    if let Some(description) = chat.description.as_deref() {
        let trimmed = description.trim();
        if !trimmed.is_empty() {
            println!("  description: {}", trimmed);
        }
    }
    if let Some(dialog) = dialog {
        if let Some(unread_count) = dialog.unread_count {
            println!("  unread: {}", unread_count);
        }
        if let Some(read_max_id) = dialog.read_max_id {
            println!("  read max id: {}", read_max_id);
        }
        if let Some(unread_mark) = dialog.unread_mark {
            println!(
                "  unread mark: {}",
                if unread_mark { "yes" } else { "no" }
            );
        }
    }
}

fn message_preview(
    message: &proto::Message,
    media: Option<&MediaSummary>,
    attachments: &[AttachmentSummary],
    translation: Option<&proto::MessageTranslation>,
) -> String {
    let mut parts = Vec::new();
    let mut original_text = None;
    if let Some(text) = message.message.as_deref() {
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            let normalized = normalize_preview_text(trimmed);
            original_text = Some(normalized.clone());
            parts.push(normalized);
        }
    }

    if let Some(translation) = translation {
        let trimmed = translation.translation.trim();
        if !trimmed.is_empty() {
            let normalized = normalize_preview_text(trimmed);
            if original_text.as_deref() != Some(normalized.as_str()) {
                parts.push(format!("tr({}): {}", translation.language, normalized));
            }
        }
    }

    if let Some(media) = media {
        parts.push(media_preview(media));
    }

    for attachment in attachments {
        parts.push(attachment_preview(attachment));
    }

    if parts.is_empty() {
        return "<non-text>".to_string();
    }

    parts.join(" ")
}

fn normalize_preview_text(value: &str) -> String {
    value
        .replace('\n', " ")
        .replace('\r', " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn message_media_summary(message: &proto::Message) -> Option<MediaSummary> {
    let media = message.media.as_ref()?;
    match &media.media {
        Some(proto::message_media::Media::Document(document)) => {
            let document = document.document.as_ref()?;
            Some(MediaSummary {
                kind: "document".to_string(),
                file_name: Some(document.file_name.clone()),
                mime_type: Some(document.mime_type.clone()),
                size: Some(document.size),
                duration: None,
                width: None,
                height: None,
                url: document.cdn_url.clone(),
            })
        }
        Some(proto::message_media::Media::Video(video)) => {
            let video = video.video.as_ref()?;
            Some(MediaSummary {
                kind: "video".to_string(),
                file_name: None,
                mime_type: None,
                size: Some(video.size),
                duration: Some(video.duration),
                width: Some(video.w),
                height: Some(video.h),
                url: video.cdn_url.clone(),
            })
        }
        Some(proto::message_media::Media::Photo(photo)) => {
            let photo = photo.photo.as_ref()?;
            let (url, size, width, height) = best_photo_size(photo);
            Some(MediaSummary {
                kind: "photo".to_string(),
                file_name: None,
                mime_type: None,
                size,
                duration: None,
                width,
                height,
                url,
            })
        }
        Some(proto::message_media::Media::Nudge(_)) => Some(MediaSummary {
            kind: "nudge".to_string(),
            file_name: None,
            mime_type: None,
            size: None,
            duration: None,
            width: None,
            height: None,
            url: None,
        }),
        None => None,
    }
}

fn message_attachment_summaries(message: &proto::Message) -> Vec<AttachmentSummary> {
    let mut items = Vec::new();
    if let Some(attachments) = message.attachments.as_ref() {
        for attachment in &attachments.attachments {
            match &attachment.attachment {
                Some(proto::message_attachment::Attachment::UrlPreview(preview)) => {
                    items.push(AttachmentSummary {
                        kind: "url_preview".to_string(),
                        title: preview.title.clone(),
                        url: preview.url.clone(),
                        site_name: preview.site_name.clone(),
                        application: None,
                        status: None,
                        number: None,
                        assigned_user_id: None,
                    });
                }
                Some(proto::message_attachment::Attachment::ExternalTask(task)) => {
                    items.push(AttachmentSummary {
                        kind: "external_task".to_string(),
                        title: Some(task.title.clone()),
                        url: Some(task.url.clone()),
                        site_name: None,
                        application: Some(task.application.clone()),
                        status: Some(format_external_status(task.status)),
                        number: Some(task.number.clone()),
                        assigned_user_id: Some(task.assigned_user_id),
                    });
                }
                None => {}
            }
        }
    }
    items
}

fn format_external_status(status: i32) -> String {
    match proto::message_attachment_external_task::Status::try_from(status) {
        Ok(proto::message_attachment_external_task::Status::Backlog) => "backlog".to_string(),
        Ok(proto::message_attachment_external_task::Status::Todo) => "todo".to_string(),
        Ok(proto::message_attachment_external_task::Status::InProgress) => {
            "in_progress".to_string()
        }
        Ok(proto::message_attachment_external_task::Status::Done) => "done".to_string(),
        Ok(proto::message_attachment_external_task::Status::Cancelled) => "cancelled".to_string(),
        _ => "unknown".to_string(),
    }
}

fn media_preview(media: &MediaSummary) -> String {
    match media.kind.as_str() {
        "document" => {
            let mut label = String::from("[file");
            if let Some(name) = &media.file_name {
                label.push_str(&format!(": {}", name));
            }
            if let Some(mime) = &media.mime_type {
                label.push_str(&format!(" {}", mime));
            }
            if let Some(size) = media.size {
                label.push_str(&format!(" {}", format_bytes(size as i64)));
            }
            label.push(']');
            label
        }
        "video" => {
            let mut label = String::from("[video");
            if let Some(duration) = media.duration {
                label.push_str(&format!(" {}s", duration));
            }
            if let Some(size) = media.size {
                label.push_str(&format!(" {}", format_bytes(size as i64)));
            }
            label.push(']');
            label
        }
        "photo" => "[photo]".to_string(),
        _ => "[media]".to_string(),
    }
}

fn attachment_preview(attachment: &AttachmentSummary) -> String {
    match attachment.kind.as_str() {
        "url_preview" => {
            if let Some(title) = &attachment.title {
                format!("[link: {}]", title)
            } else if let Some(site) = &attachment.site_name {
                format!("[link: {}]", site)
            } else if let Some(url) = &attachment.url {
                format!("[link: {}]", url)
            } else {
                "[link]".to_string()
            }
        }
        "external_task" => {
            let mut label = String::from("[task");
            if let Some(app) = &attachment.application {
                label.push_str(&format!(" {}", app));
            }
            if let Some(title) = &attachment.title {
                label.push_str(&format!(": {}", title));
            }
            label.push(']');
            label
        }
        _ => "[attachment]".to_string(),
    }
}

fn best_photo_size(
    photo: &proto::Photo,
) -> (Option<String>, Option<i32>, Option<i32>, Option<i32>) {
    let mut best: Option<(&proto::PhotoSize, i64)> = None;
    for size in &photo.sizes {
        if size.cdn_url.is_none() {
            continue;
        }
        let area = size.w as i64 * size.h as i64;
        if best.map_or(true, |(_, best_area)| area > best_area) {
            best = Some((size, area));
        }
    }
    if let Some((size, _)) = best {
        return (
            size.cdn_url.clone(),
            Some(size.size),
            Some(size.w),
            Some(size.h),
        );
    }
    (None, None, None, None)
}

fn format_relative_date(timestamp: i64, now: i64) -> String {
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

fn format_bytes(bytes: i64) -> String {
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

async fn fetch_last_messages(
    realtime: &mut RealtimeClient,
    peers: &[proto::InputPeer],
) -> Result<Vec<Option<proto::Message>>, Box<dyn std::error::Error>> {
    if peers.is_empty() {
        return Ok(Vec::new());
    }

    let calls = peers
        .iter()
        .cloned()
        .map(|peer| {
            let input = proto::GetChatHistoryInput {
                peer_id: Some(peer),
                offset_id: None,
                limit: Some(1),
            };
            (
                proto::Method::GetChatHistory,
                proto::rpc_call::Input::GetChatHistory(input),
            )
        })
        .collect();

    let results = realtime.call_rpc_batch(calls).await?;
    let mut messages = Vec::with_capacity(results.len());
    for result in results {
        match result {
            proto::rpc_result::Result::GetChatHistory(payload) => {
                messages.push(payload.messages.into_iter().next());
            }
            _ => return Err("Unexpected RPC result for getChatHistory".into()),
        }
    }
    Ok(messages)
}

async fn fetch_message_by_id(
    realtime: &mut RealtimeClient,
    peer: &proto::InputPeer,
    message_id: i64,
) -> Result<proto::Message, Box<dyn std::error::Error>> {
    let candidates = [message_id + 1, message_id];
    for offset_id in candidates {
        let input = proto::GetChatHistoryInput {
            peer_id: Some(peer.clone()),
            offset_id: Some(offset_id),
            limit: Some(20),
        };
        let result = realtime
            .call_rpc(
                proto::Method::GetChatHistory,
                proto::rpc_call::Input::GetChatHistory(input),
            )
            .await?;
        match result {
            proto::rpc_result::Result::GetChatHistory(payload) => {
                if let Some(message) = payload
                    .messages
                    .into_iter()
                    .find(|msg| msg.id == message_id)
                {
                    return Ok(message);
                }
            }
            _ => return Err("Unexpected RPC result for getChatHistory".into()),
        }
    }
    Err("Message not found in recent history for that peer.".into())
}

fn resolve_download_path(
    message: &proto::Message,
    output: Option<PathBuf>,
    dir: Option<PathBuf>,
) -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Some(output) = output {
        return Ok(output);
    }
    let file_name = message
        .media
        .as_ref()
        .and_then(media_file_name)
        .unwrap_or_else(|| format!("message-{}.bin", message.id));
    let base_dir = dir.unwrap_or_else(|| PathBuf::from("."));
    Ok(base_dir.join(file_name))
}

async fn download_message_media(
    message: &proto::Message,
    output_path: &PathBuf,
) -> Result<u64, Box<dyn std::error::Error>> {
    let Some(media) = message.media.as_ref() else {
        return Err("Message has no downloadable media.".into());
    };
    let (url, description) = match &media.media {
        Some(proto::message_media::Media::Document(document)) => {
            let document = document.document.as_ref();
            (document.and_then(|doc| doc.cdn_url.clone()), "document")
        }
        Some(proto::message_media::Media::Video(video)) => {
            let video = video.video.as_ref();
            (video.and_then(|vid| vid.cdn_url.clone()), "video")
        }
        Some(proto::message_media::Media::Photo(photo)) => {
            let photo = photo.photo.as_ref();
            let (url, _, _, _) = match photo {
                Some(photo) => best_photo_size(photo),
                None => (None, None, None, None),
            };
            (url, "photo")
        }
        Some(proto::message_media::Media::Nudge(_)) => (None, "nudge"),
        None => (None, "media"),
    };
    let url = match url {
        Some(url) if !url.trim().is_empty() => url,
        _ => return Err(format!("No CDN URL available for {description}.").into()),
    };

    if let Some(parent) = output_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let client = reqwest::Client::new();
    let response = client.get(url).send().await?;
    if !response.status().is_success() {
        return Err(format!("Download failed with status {}", response.status()).into());
    }

    let mut file = tokio::fs::File::create(output_path).await?;
    let mut total = 0u64;
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        file.write_all(&chunk).await?;
        total += chunk.len() as u64;
    }
    file.flush().await?;
    Ok(total)
}

fn media_file_name(media: &proto::MessageMedia) -> Option<String> {
    match &media.media {
        Some(proto::message_media::Media::Document(document)) => document
            .document
            .as_ref()
            .and_then(|doc| sanitize_file_name(&doc.file_name)),
        Some(proto::message_media::Media::Video(video)) => video
            .video
            .as_ref()
            .map(|video| format!("video-{}.mp4", video.id)),
        Some(proto::message_media::Media::Photo(photo)) => {
            let photo = photo.photo.as_ref()?;
            let ext = match proto::photo::Format::try_from(photo.format) {
                Ok(proto::photo::Format::Png) => "png",
                Ok(proto::photo::Format::Jpeg) => "jpg",
                _ => "jpg",
            };
            Some(format!("photo-{}.{}", photo.id, ext))
        }
        Some(proto::message_media::Media::Nudge(_)) => None,
        None => None,
    }
}

fn sanitize_file_name(name: &str) -> Option<String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return None;
    }
    let file_name = std::path::Path::new(trimmed)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(trimmed);
    Some(file_name.to_string())
}

fn input_peer_from_peer(peer: &proto::Peer) -> Option<proto::InputPeer> {
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

#[derive(Clone, Hash, PartialEq, Eq)]
enum PeerKey {
    Chat(i64),
    User(i64),
}

#[derive(Clone, Hash, PartialEq, Eq)]
struct MessageKey {
    peer: PeerKey,
    id: i64,
}

fn peer_key_from_peer(peer: &proto::Peer) -> Option<PeerKey> {
    match &peer.r#type {
        Some(proto::peer::Type::Chat(chat)) => Some(PeerKey::Chat(chat.chat_id)),
        Some(proto::peer::Type::User(user)) => Some(PeerKey::User(user.user_id)),
        None => None,
    }
}

#[derive(Clone)]
enum Contact {
    Email(String),
    Phone(String),
}

fn current_epoch_seconds() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn build_doctor_output(
    config: &Config,
    auth_store: &AuthStore,
    local_db: &LocalDb,
) -> DoctorOutput {
    let debug = cfg!(debug_assertions);
    let executable = env::current_exe()
        .ok()
        .map(|path| path.display().to_string());

    let env_token = env::var("INLINE_TOKEN")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let mut token_present = false;
    let mut token_source = None;
    let mut token_error = None;

    if env_token.is_some() {
        token_present = true;
        token_source = Some("INLINE_TOKEN".to_string());
    } else {
        match auth_store.load_token() {
            Ok(Some(_)) => {
                token_present = true;
                token_source = Some("secrets_file".to_string());
            }
            Ok(None) => {}
            Err(err) => {
                token_error = Some(err.to_string());
            }
        }
    }

    let (current_user, state_error) = match local_db.load() {
        Ok(state) => (state.current_user, None),
        Err(err) => (None, Some(err.to_string())),
    };

    DoctorOutput {
        system: DoctorSystem {
            version: env!("CARGO_PKG_VERSION").to_string(),
            debug,
            os: env::consts::OS.to_string(),
            arch: env::consts::ARCH.to_string(),
            executable,
        },
        config: DoctorConfig {
            api_base_url: config.api_base_url.clone(),
            realtime_url: config.realtime_url.clone(),
            release_manifest_url: config.release_manifest_url.clone(),
            release_install_url: config.release_install_url.clone(),
        },
        paths: DoctorPaths {
            data_dir: config.data_dir.display().to_string(),
            data_dir_exists: config.data_dir.exists(),
            secrets_path: config.secrets_path.display().to_string(),
            secrets_exists: config.secrets_path.exists(),
            state_path: config.state_path.display().to_string(),
            state_exists: config.state_path.exists(),
        },
        auth: DoctorAuth {
            token_present,
            token_source,
            token_error,
            current_user,
            state_error,
        },
    }
}

fn print_doctor(output: &DoctorOutput) {
    println!("System");
    println!("  version: {}", output.system.version);
    println!(
        "  debug build: {}",
        if output.system.debug { "yes" } else { "no" }
    );
    println!("  os: {}", output.system.os);
    println!("  arch: {}", output.system.arch);
    println!(
        "  executable: {}",
        output.system.executable.as_deref().unwrap_or("-")
    );

    println!("Config");
    println!("  api base url: {}", output.config.api_base_url);
    println!("  realtime url: {}", output.config.realtime_url);
    println!(
        "  release manifest url: {}",
        output.config.release_manifest_url.as_deref().unwrap_or("-")
    );
    println!(
        "  release install url: {}",
        output.config.release_install_url.as_deref().unwrap_or("-")
    );

    println!("Paths");
    println!(
        "  data dir: {} ({})",
        output.paths.data_dir,
        if output.paths.data_dir_exists {
            "exists"
        } else {
            "missing"
        }
    );
    println!(
        "  secrets file: {} ({})",
        output.paths.secrets_path,
        if output.paths.secrets_exists {
            "exists"
        } else {
            "missing"
        }
    );
    println!(
        "  state file: {} ({})",
        output.paths.state_path,
        if output.paths.state_exists {
            "exists"
        } else {
            "missing"
        }
    );

    println!("Auth");
    if output.auth.token_present {
        if let Some(source) = &output.auth.token_source {
            println!("  token: present ({source})");
        } else {
            println!("  token: present");
        }
    } else {
        println!("  token: absent");
    }

    if let Some(user) = &output.auth.current_user {
        println!(
            "  current user: {} (id {})",
            user_display_name(user),
            user.id
        );
    } else {
        println!("  current user: -");
    }

    if let Some(error) = &output.auth.token_error {
        println!("  token error: {}", error);
    }
    if let Some(error) = &output.auth.state_error {
        println!("  state error: {}", error);
    }
}

fn print_auth_user(user: &proto::User) {
    let name = user_display_name(user);
    println!("Logged in as {} (id {}).", name, user.id);

    if let Some(username) = user.username.as_deref() {
        let trimmed = username.trim();
        if !trimmed.is_empty() {
            println!("username: @{}", trimmed);
        }
    }

    if let Some(email) = user.email.as_deref() {
        let trimmed = email.trim();
        if !trimmed.is_empty() {
            println!("email: {}", trimmed);
        }
    }

    if let Some(phone) = user.phone_number.as_deref() {
        let trimmed = phone.trim();
        if !trimmed.is_empty() {
            println!("phone: {}", trimmed);
        }
    }
}

fn print_auth_error(error: &ApiError) {
    match error {
        ApiError::Api { error, description } => {
            eprintln!("Could not verify code: {error}. {description}");
        }
        ApiError::Status(status) => {
            eprintln!("Could not verify code (server status {status}).");
        }
        ApiError::Http(err) => {
            eprintln!("Network error while verifying code: {err}");
        }
        ApiError::Io(err) => {
            eprintln!("Local IO error while verifying code: {err}");
        }
    }
}
