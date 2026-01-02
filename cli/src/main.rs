mod api;
mod auth;
mod config;
mod output;
mod protocol;
mod realtime;
mod state;
mod update;

use clap::{ArgAction, Args, Parser, Subcommand};
use dialoguer::{Input, Select};
use rand::{rngs::OsRng, RngCore};
use std::cmp::Reverse;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::{fs, io};

use crate::api::{ApiClient, ApiError, UploadFileInput, UploadFileResult, UploadFileType, UploadVideoMetadata};
use crate::auth::AuthStore;
use crate::config::Config;
use crate::output::{
    AttachmentSummary, ChatListItem, ChatListOutput, MediaSummary, MessageListOutput, MessageSummary,
    PeerSummary, SpaceListOutput, SpaceSummary, UserListOutput, UserSummary,
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
    after_help = "Examples:\n  inline auth login --email you@example.com\n  inline chats list\n  inline spaces list\n  inline users list --json\n  inline messages list --chat-id 123\n  inline messages list --chat-id 123 --translate en\n  inline messages search --chat-id 123 --query \"onboarding\"\n  inline messages get --chat-id 123 --message-id 456\n  inline messages send --chat-id 123 --text \"hello\"\n  inline messages send --chat-id 123 --attach ./photo.jpg --attach ./spec.pdf --text \"FYI\"\n  inline messages download --chat-id 123 --message-id 456\n  inline messages send --user-id 42 --stdin"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,

    #[arg(long, global = true, help = "Output JSON instead of a table")]
    json: bool,
}

#[derive(Subcommand)]
enum Command {
    #[command(about = "Authenticate this CLI")]
    Auth {
        #[command(subcommand)]
        command: AuthCommand,
    },
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
}

#[derive(Subcommand)]
enum AuthCommand {
    #[command(about = "Log in via email or phone code")]
    Login(AuthLoginArgs),
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
}

#[derive(Args)]
struct ChatsListArgs {
    #[arg(long, help = "Maximum number of chats to return")]
    limit: Option<usize>,

    #[arg(long, help = "Offset into the chat list")]
    offset: Option<usize>,
}

#[derive(Subcommand)]
enum UsersCommand {
    #[command(about = "List users that appear in your chats")]
    List,
    #[command(about = "Fetch a user by id from the chat list payload")]
    Get(UserGetArgs),
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
    #[command(about = "Download a message attachment (photo/video/file)")]
    Download(MessagesDownloadArgs),
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

    #[arg(long, value_name = "LANG", help = "Translate messages to language code (e.g., en)")]
    translate: Option<String>,
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
}

#[derive(Args)]
struct MessagesGetArgs {
    #[arg(long, help = "Chat id")]
    chat_id: i64,

    #[arg(long, help = "Message id")]
    message_id: i64,

    #[arg(long, value_name = "LANG", help = "Translate message to language code (e.g., en)")]
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

#[derive(Subcommand)]
enum SpacesCommand {
    #[command(about = "List spaces referenced in your chats")]
    List,
}

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();
    let config = Config::load();
    let auth_store = AuthStore::new(config.secrets_path.clone(), config.api_base_url.clone());
    let local_db = LocalDb::new(config.state_path.clone(), config.api_base_url.clone());
    let api = ApiClient::new(config.api_base_url.clone());
    let skip_update_check = matches!(&cli.command, Command::Auth { command: AuthCommand::Login(_) });
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
                AuthCommand::Logout => {
                    auth_store.clear_token()?;
                    local_db.clear_current_user()?;
                    println!("Logged out.");
                }
            },
            Command::Chats { command } => match command {
                ChatsCommand::List(args) => {
                    let token = require_token(&auth_store)?;
                    let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let result = realtime
                        .call_rpc(proto::Method::GetChats, proto::rpc_call::Input::GetChats(proto::GetChatsInput {}))
                        .await?;

                    match result {
                        proto::rpc_result::Result::GetChats(payload) => {
                            if cli.json {
                                if args.limit.is_some() || args.offset.is_some() {
                                    let payload = apply_chat_list_limits(payload, args.limit, args.offset);
                                    output::print_json(&payload)?;
                                } else {
                                    output::print_json(&payload)?;
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
                                output::print_chat_list(&output, false)?;
                            }
                        }
                        _ => {
                            return Err("Unexpected RPC result for getChats".into());
                        }
                    }
                }
            },
            Command::Users { command } => match command {
                UsersCommand::List => {
                    let token = require_token(&auth_store)?;
                    let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let result = realtime
                        .call_rpc(proto::Method::GetChats, proto::rpc_call::Input::GetChats(proto::GetChatsInput {}))
                        .await?;

                    match result {
                        proto::rpc_result::Result::GetChats(payload) => {
                            if cli.json {
                                output::print_json(&payload)?;
                            } else {
                                let output = build_user_list(&payload);
                                output::print_users(&output, false)?;
                            }
                        }
                        _ => {
                            return Err("Unexpected RPC result for getChats".into());
                        }
                    }
                }
                UsersCommand::Get(args) => {
                    let token = require_token(&auth_store)?;
                    let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let result = realtime
                        .call_rpc(proto::Method::GetChats, proto::rpc_call::Input::GetChats(proto::GetChatsInput {}))
                        .await?;

                    match result {
                        proto::rpc_result::Result::GetChats(payload) => {
                            if cli.json {
                                if let Some(user) = payload.users.iter().find(|user| user.id == args.id) {
                                    output::print_json(user)?;
                                } else {
                                    return Err("User not found in getChats users list".into());
                                }
                            } else {
                                let output = build_user_list(&payload);
                                if let Some(user) = output.users.into_iter().find(|user| user.user.id == args.id) {
                                    output::print_users(&UserListOutput { users: vec![user] }, false)?;
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
                    let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;

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
                        proto::rpc_result::Result::GetChatHistory(payload) => {
                            if cli.json {
                                output::print_json(&payload)?;
                            } else {
                                let translation_language =
                                    args.translate.as_deref().map(normalize_translation_language).transpose()?;
                                let translations_by_id = if let Some(language) = translation_language.as_deref() {
                                    let message_ids = collect_message_ids(&payload.messages);
                                    fetch_message_translations(&mut realtime, &peer, &message_ids, language).await?
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
                                let current_user_id = local_db.load()?.current_user.map(|user| user.id);
                                let output = build_message_list(
                                    payload,
                                    &users_by_id,
                                    current_user_id,
                                    peer_summary,
                                    peer_name_from_input(&peer, &users_by_id, &chats_by_id),
                                    Some(&translations_by_id),
                                );
                                output::print_messages(&output, false)?;
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
                    let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;

                    let input = proto::SearchMessagesInput {
                        peer_id: Some(peer.clone()),
                        queries,
                        limit: args.limit,
                    };

                    let result = realtime
                        .call_rpc(
                            proto::Method::SearchMessages,
                            proto::rpc_call::Input::SearchMessages(input),
                        )
                        .await?;

                    match result {
                        proto::rpc_result::Result::SearchMessages(payload) => {
                            if cli.json {
                                output::print_json(&payload)?;
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
                                let current_user_id = local_db.load()?.current_user.map(|user| user.id);
                                let output = build_message_list_from_messages(
                                    &payload.messages,
                                    &users_by_id,
                                    current_user_id,
                                    peer_summary,
                                    peer_name_from_input(&peer, &users_by_id, &chats_by_id),
                                    None,
                                );
                                output::print_messages(&output, false)?;
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
                    let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let message = fetch_message_by_id(&mut realtime, &peer, args.message_id).await?;
                    if cli.json {
                        output::print_json(&message)?;
                    } else {
                        let translation_language =
                            args.translate.as_deref().map(normalize_translation_language).transpose()?;
                        let translations_by_id = if let Some(language) = translation_language.as_deref() {
                            fetch_message_translations(&mut realtime, &peer, &[message.id], language).await?
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
                    let caption = resolve_message_caption(args.text, args.stdin)?;
                    let attachments = prepare_attachments(
                        &args.attachments,
                        &config.data_dir,
                        args.force_file,
                        cli.json,
                    )?;

                    let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;
                    if attachments.is_empty() {
                        let text = caption
                            .ok_or_else(|| "Provide --text, --stdin, or --attach".to_string())?;
                        let payload = send_message(&mut realtime, &peer, Some(text), None, true).await?;
                        if cli.json {
                            output::print_json(&payload)?;
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
                            attachments,
                            peer_summary,
                            cli.json,
                        )
                        .await?;
                        if cli.json {
                            output::print_json(&output)?;
                        }
                    }
                }
                MessagesCommand::Download(args) => {
                    let token = require_token(&auth_store)?;
                    if args.output.is_some() && args.dir.is_some() {
                        return Err("Provide only one of --output or --dir".into());
                    }
                    let peer = input_peer_from_args(args.chat_id, args.user_id)?;
                    let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let message = fetch_message_by_id(&mut realtime, &peer, args.message_id).await?;
                    let output_path = resolve_download_path(&message, args.output, args.dir)?;
                    download_message_media(&message, &output_path).await?;
                    println!("Downloaded to {}", output_path.display());
                }
            },
            Command::Spaces { command } => match command {
                SpacesCommand::List => {
                    let token = require_token(&auth_store)?;
                    let mut realtime = RealtimeClient::connect(&config.realtime_url, &token).await?;
                    let result = realtime
                        .call_rpc(proto::Method::GetChats, proto::rpc_call::Input::GetChats(proto::GetChatsInput {}))
                        .await?;

                    match result {
                        proto::rpc_result::Result::GetChats(payload) => {
                            if cli.json {
                                output::print_json(&payload)?;
                            } else {
                                let output = build_space_list(&payload);
                                output::print_spaces(&output, false)?;
                            }
                        }
                        _ => {
                            return Err("Unexpected RPC result for getChats".into());
                        }
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
    let device_name = hostname::get().ok().and_then(|name| name.into_string().ok());
    let client_type = "macos";
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
                    api.verify_email_code(email, &code, client_type, client_version, device_name.as_deref())
                        .await
                }
                Contact::Phone(phone) => {
                    api.verify_sms_code(phone, &code, client_type, client_version, device_name.as_deref())
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
            let phone: String = Input::new().with_prompt("Phone (E.164 recommended)").interact_text()?;
            Ok(Contact::Phone(phone.trim().to_string()))
        }
    }
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
) -> Result<proto::SendMessageResult, Box<dyn std::error::Error>> {
    let mut rng = OsRng;
    let random_id: i64 = rng.next_u64() as i64;
    let send_date = current_epoch_seconds() as i64;

    let input = proto::SendMessageInput {
        peer_id: Some(peer.clone()),
        message: text,
        reply_to_msg_id: None,
        random_id: Some(random_id),
        media,
        temporary_send_date: Some(send_date),
        is_sticker: None,
        entities: None,
        parse_markdown: Some(parse_markdown),
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
        )
        .await?;
        let updates_len = send.updates.len();
        updates.extend(send.updates.into_iter());
        if !json {
            println!("Sent {} (updates: {}).", attachment.display_name, updates_len);
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
        let metadata = fs::metadata(path).map_err(|_| format!("Attachment not found: {}", path.display()))?;
        if metadata.is_dir() {
            prepared.push(prepare_directory_attachment(path, data_dir, quiet)?);
        } else if metadata.is_file() {
            prepared.push(prepare_file_attachment(path, metadata.len(), force_file, quiet)?);
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

fn ensure_attachment_size(label: &str, size: u64, quiet: bool) -> Result<(), Box<dyn std::error::Error>> {
    if size > MAX_ATTACHMENT_BYTES {
        let size_label = format_bytes(size as i64);
        if !quiet {
            eprintln!(
                "Attachment {} is {} (limit 200MB).",
                label, size_label
            );
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
    let zip_path = data_dir.join(format!(
        "{}-{}.zip",
        folder_name,
        current_epoch_seconds()
    ));

    let file = fs::File::create(&zip_path)?;
    let mut zip = zip::ZipWriter::new(file);
    let options = zip::write::FileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .unix_permissions(0o644);

    let mut has_entries = false;
    for entry in walkdir::WalkDir::new(dir).into_iter().filter_map(Result::ok) {
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
    let duration = stream.duration.and_then(|value| value.parse::<f64>().ok())?;
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

fn input_media_from_upload(upload: &UploadFileResult) -> Result<proto::InputMedia, Box<dyn std::error::Error>> {
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
            r#type: Some(proto::input_peer::Type::Chat(proto::InputPeerChat { chat_id })),
        }),
        (None, Some(user_id)) => Ok(proto::InputPeer {
            r#type: Some(proto::input_peer::Type::User(proto::InputPeerUser { user_id })),
        }),
        (None, None) => Err("Provide --chat-id or --user-id".into()),
    }
}

async fn fetch_me(
    realtime: &mut RealtimeClient,
) -> Result<proto::User, Box<dyn std::error::Error>> {
    let result = realtime
        .call_rpc(proto::Method::GetMe, proto::rpc_call::Input::GetMe(proto::GetMeInput {}))
        .await?;
    match result {
        proto::rpc_result::Result::GetMe(payload) => payload.user.ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::Other, "getMe returned no user").into()
        }),
        _ => Err("Unexpected RPC result for getMe".into()),
    }
}

fn apply_chat_list_limits(
    mut payload: proto::GetChatsResult,
    limit: Option<usize>,
    offset: Option<usize>,
) -> proto::GetChatsResult {
    let offset = offset.unwrap_or(0);
    let limit = limit.unwrap_or(payload.chats.len());
    payload.chats = payload
        .chats
        .into_iter()
        .skip(offset)
        .take(limit)
        .collect();
    payload
}

async fn build_chat_list(
    result: proto::GetChatsResult,
    realtime: &mut RealtimeClient,
    current_user: Option<&proto::User>,
    limit: Option<usize>,
    offset: Option<usize>,
) -> Result<ChatListOutput, Box<dyn std::error::Error>> {
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
    for chat in &result.chats {
        let peer_key = chat.peer_id.as_ref().and_then(peer_key_from_peer);
        let dialog = peer_key
            .as_ref()
            .and_then(|key| dialog_by_peer.get(key))
            .or_else(|| dialog_by_chat_id.get(&chat.id))
            .cloned();
        let unread_count = dialog.as_ref().and_then(|dialog| dialog.unread_count);

        let mut last_message = chat.last_msg_id.and_then(|id| {
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
            match fetch_last_message(realtime, chat.peer_id.as_ref()).await {
                Ok(message) => {
                    last_message = message;
                }
                Err(error) => {
                    eprintln!("Failed to load last message for chat {}: {error}", chat.id);
                }
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
        let last_message_relative_date = last_message_summary.as_ref().map(|summary| summary.relative_date.clone());

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

    items.sort_by_key(|item| Reverse(item.last_message.as_ref().map(|message| message.message.date).unwrap_or(0)));

    let offset = offset.unwrap_or(0);
    let limit = limit.unwrap_or(items.len());
    let items = items
        .into_iter()
        .skip(offset)
        .take(limit)
        .collect();

    Ok(ChatListOutput { items, raw: result })
}

fn build_user_list(result: &proto::GetChatsResult) -> UserListOutput {
    let users = result
        .users
        .iter()
        .map(|user| user_summary(user))
        .collect();
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
        .map(|message| message_summary(message, users_by_id, current_user_id, now, translations_by_id))
        .collect();
    MessageListOutput { items, peer, peer_name }
}

fn normalize_search_queries(queries: &[String]) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let normalized: Vec<String> = queries
        .iter()
        .map(|query| query.trim())
        .filter(|query| !query.is_empty())
        .map(|query| query.to_string())
        .collect();

    if normalized.is_empty() {
        return Err("Provide --query (repeatable)".into());
    }

    Ok(normalized)
}

fn normalize_translation_language(language: &str) -> Result<String, Box<dyn std::error::Error>> {
    let trimmed = language.trim();
    if trimmed.is_empty() {
        return Err("Provide a language code for --translate".into());
    }
    Ok(trimmed.to_string())
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
    let translation = translations_by_id.and_then(|translations| translations.get(&message.id)).cloned();
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

fn space_summary(space: &proto::Space) -> SpaceSummary {
    SpaceSummary {
        display_name: space.name.clone(),
        space: space.clone(),
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
        Ok(proto::message_attachment_external_task::Status::InProgress) => "in_progress".to_string(),
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

fn best_photo_size(photo: &proto::Photo) -> (Option<String>, Option<i32>, Option<i32>, Option<i32>) {
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

async fn fetch_last_message(
    realtime: &mut RealtimeClient,
    peer: Option<&proto::Peer>,
) -> Result<Option<proto::Message>, Box<dyn std::error::Error>> {
    let peer = match peer {
        Some(peer) => peer,
        None => return Ok(None),
    };
    let input_peer = match input_peer_from_peer(peer) {
        Some(value) => value,
        None => return Ok(None),
    };
    let input = proto::GetChatHistoryInput {
        peer_id: Some(input_peer),
        offset_id: None,
        limit: Some(1),
    };
    let result = realtime
        .call_rpc(
            proto::Method::GetChatHistory,
            proto::rpc_call::Input::GetChatHistory(input),
        )
        .await?;
    match result {
        proto::rpc_result::Result::GetChatHistory(payload) => Ok(payload.messages.into_iter().next()),
        _ => Err("Unexpected RPC result for getChatHistory".into()),
    }
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
                if let Some(message) = payload.messages.into_iter().find(|msg| msg.id == message_id) {
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
) -> Result<(), Box<dyn std::error::Error>> {
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
        None => (None, "media"),
    };
    let url = match url {
        Some(url) if !url.trim().is_empty() => url,
        _ => return Err(format!("No CDN URL available for {description}.").into()),
    };

    if let Some(parent) = output_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let response = reqwest::get(url).await?;
    if !response.status().is_success() {
        return Err(format!("Download failed with status {}", response.status()).into());
    }
    let bytes = response.bytes().await?;
    std::fs::write(output_path, &bytes)?;
    Ok(())
}

fn media_file_name(media: &proto::MessageMedia) -> Option<String> {
    match &media.media {
        Some(proto::message_media::Media::Document(document)) => {
            document
                .document
                .as_ref()
                .and_then(|doc| sanitize_file_name(&doc.file_name))
        }
        Some(proto::message_media::Media::Video(video)) => {
            video
                .video
                .as_ref()
                .map(|video| format!("video-{}.mp4", video.id))
        }
        Some(proto::message_media::Media::Photo(photo)) => {
            let photo = photo.photo.as_ref()?;
            let ext = match proto::photo::Format::try_from(photo.format) {
                Ok(proto::photo::Format::Png) => "png",
                Ok(proto::photo::Format::Jpeg) => "jpg",
                _ => "jpg",
            };
            Some(format!("photo-{}.{}", photo.id, ext))
        }
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
