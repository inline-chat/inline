//! Owner management for bots: profile, photo, avatar, token, settings, and access.

use inline_protocol::proto;
use serde::Serialize;

use crate::attachments::prepare_photo_upload;
use crate::auth::AuthStore;
use crate::config::Config;
use crate::errors::CliError;
use crate::output::{self, JsonFormat, terminal_text, user_display_name};
use crate::validation::validate_positive_id_arg;
use crate::{
    AuthenticatedRealtime, BotsAccessCommand, BotsCommand, confirm_action,
    connect_authenticated_realtime,
};

type CliResult<T = ()> = Result<T, Box<dyn std::error::Error>>;

#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::ValueEnum)]
pub(crate) enum BotOutputMode {
    /// Progress, tool calls, and technical detail.
    Detailed,
    /// No progress or tool chatter, and a plain-language answer.
    Friendly,
    /// Clear the selected preference for this bot or thread.
    Default,
}

impl BotOutputMode {
    /// An explicit reset sends UNSPECIFIED. Omitting the flag only reads settings.
    fn protocol_value(self) -> proto::AgentOutputMode {
        match self {
            Self::Detailed => proto::AgentOutputMode::Detailed,
            Self::Friendly => proto::AgentOutputMode::Friendly,
            Self::Default => proto::AgentOutputMode::Unspecified,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::ValueEnum)]
pub(crate) enum BotGrantOperation {
    /// Start work.
    Invoke,
    /// Steer, queue, stop, pause, and resume work.
    Steer,
    /// Answer approvals as a delegate of the owner.
    Approve,
    /// Change the bot's settings.
    Configure,
}

impl BotGrantOperation {
    fn protocol_value(self) -> proto::AgentGrantOperation {
        match self {
            Self::Invoke => proto::AgentGrantOperation::Invoke,
            Self::Steer => proto::AgentGrantOperation::Steer,
            Self::Approve => proto::AgentGrantOperation::Approve,
            Self::Configure => proto::AgentGrantOperation::Configure,
        }
    }
}

/// Operations a new grant gets when none are given, matching the apps.
const DEFAULT_GRANT_OPERATIONS: [BotGrantOperation; 2] =
    [BotGrantOperation::Invoke, BotGrantOperation::Steer];

fn grant_operations(requested: &[BotGrantOperation]) -> Vec<i32> {
    let requested = if requested.is_empty() {
        &DEFAULT_GRANT_OPERATIONS[..]
    } else {
        requested
    };
    let mut operations: Vec<i32> = Vec::with_capacity(requested.len());
    for operation in requested {
        let value = operation.protocol_value() as i32;
        if !operations.contains(&value) {
            operations.push(value);
        }
    }
    operations
}

fn output_mode_label(value: i32) -> &'static str {
    match proto::AgentOutputMode::try_from(value) {
        Ok(proto::AgentOutputMode::Friendly) => "friendly",
        Ok(proto::AgentOutputMode::Detailed) => "detailed",
        Ok(proto::AgentOutputMode::Unspecified) => "unset",
        Err(_) => "unknown",
    }
}

fn operations_label(operations: &[i32]) -> String {
    let labels: Vec<&str> = operations
        .iter()
        .map(|value| match proto::AgentGrantOperation::try_from(*value) {
            Ok(proto::AgentGrantOperation::Invoke) => "invoke",
            Ok(proto::AgentGrantOperation::Steer) => "steer",
            Ok(proto::AgentGrantOperation::Approve) => "approve",
            Ok(proto::AgentGrantOperation::Configure) => "configure",
            _ => "unknown",
        })
        .collect();
    if labels.is_empty() {
        "-".to_string()
    } else {
        labels.join(", ")
    }
}

fn bot_label(bot: &proto::User) -> String {
    let name = user_display_name(bot);
    match bot.username.as_deref().filter(|value| !value.is_empty()) {
        Some(username) => format!("{} (@{username}, id {})", terminal_text(&name), bot.id),
        None => format!("{} (id {})", terminal_text(&name), bot.id),
    }
}

/// The bot's agent settings. Servers without the settings read mirror the
/// default output mode on the bot's runtime; absent both, it is the default.
async fn read_agent_settings(
    realtime: &mut AuthenticatedRealtime,
    bot_user_id: i64,
) -> CliResult<Option<proto::AgentSettings>> {
    match realtime
        .call(proto::GetAgentSettingsInput { bot_user_id })
        .await
    {
        Ok(payload) => Ok(payload.settings),
        Err(_) => {
            let runtime = realtime
                .call(proto::GetAgentRuntimeInput { bot_user_id })
                .await?
                .runtime;
            Ok(Some(proto::AgentSettings {
                bot_user_id,
                default_output_mode: runtime
                    .map(|runtime| runtime.default_output_mode)
                    .unwrap_or_default(),
                ..Default::default()
            }))
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadOutputModeOutput {
    bot_user_id: i64,
    chat_id: i64,
    /// Absent when the thread uses the bot's default.
    output_mode: Option<&'static str>,
    default_output_mode: &'static str,
}

fn chat_peer(chat_id: i64) -> proto::InputPeer {
    proto::InputPeer {
        r#type: Some(proto::input_peer::Type::Chat(proto::InputPeerChat {
            chat_id,
        })),
    }
}

/// The thread's override for one bot, if any.
async fn read_thread_output_mode(
    realtime: &mut AuthenticatedRealtime,
    bot_user_id: i64,
    chat_id: i64,
) -> CliResult<Option<i32>> {
    let payload = realtime
        .call(proto::GetAgentParticipationsInput {
            peer_id: Some(chat_peer(chat_id)),
        })
        .await?;
    Ok(payload
        .participations
        .into_iter()
        .find(|participation| participation.bot_user_id == bot_user_id)
        .and_then(|participation| participation.output_mode)
        .filter(|mode| *mode != proto::AgentOutputMode::Unspecified as i32))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BotDetailsOutput {
    bot: proto::User,
    settings: Option<proto::AgentSettings>,
    grants: Vec<proto::AgentGrant>,
}

async fn find_owned_bot(
    realtime: &mut AuthenticatedRealtime,
    bot_user_id: i64,
) -> CliResult<proto::User> {
    let payload = realtime.call(proto::ListBotsInput {}).await?;
    payload
        .bots
        .into_iter()
        .find(|bot| bot.id == bot_user_id)
        .ok_or_else(|| {
            CliError::invalid_args(format!(
                "No bot you own has user id {bot_user_id}. Run `inline bots list` to see your bots."
            ))
            .into()
        })
}

fn print_profile_result(
    payload: &proto::UpdateBotProfileResult,
    action: &str,
    json: bool,
    json_format: JsonFormat,
) -> CliResult {
    if json {
        output::print_json(payload, json_format)?;
    } else if let Some(bot) = payload.bot.as_ref() {
        println!("{action} for {}.", bot_label(bot));
    } else {
        println!("{action}.");
    }
    Ok(())
}

fn print_grants(grants: &[proto::AgentGrant]) {
    if grants.is_empty() {
        println!("Access: owner only");
        return;
    }
    println!("Access:");
    for grant in grants {
        println!(
            "  {}: {}",
            subject_label(grant.subject.as_ref(), grant.user_id),
            operations_label(&grant.operations)
        );
    }
}

fn subject_label(subject: Option<&proto::AccessSubject>, user_id: i64) -> String {
    use proto::access_subject::Subject;
    match subject.and_then(|subject| subject.subject.clone()) {
        Some(Subject::SpaceId(id)) => format!("space {id}"),
        Some(Subject::GroupId(id)) => format!("group {id}"),
        Some(Subject::UserId(id)) => format!("user {id}"),
        None => format!("user {user_id}"),
    }
}

/// The grant's subject from `--user-id`, `--space-id` or `--group-id` (exactly one).
fn access_subject(args: &crate::BotsAccessSubjectArgs) -> CliResult<proto::AccessSubject> {
    use proto::access_subject::Subject;
    let subject = match (args.user_id, args.space_id, args.group_id) {
        (Some(id), None, None) => Subject::UserId(validate_positive_id_arg("--user-id", id)?),
        (None, Some(id), None) => Subject::SpaceId(validate_positive_id_arg("--space-id", id)?),
        (None, None, Some(id)) => Subject::GroupId(validate_positive_id_arg("--group-id", id)?),
        _ => {
            return Err(CliError::invalid_args(
                "Pass exactly one of --user-id, --space-id or --group-id.",
            )
            .into());
        }
    };
    Ok(proto::AccessSubject {
        subject: Some(subject),
    })
}

/// Handles every bots subcommand except list, create, and reveal-token.
pub(crate) async fn handle_bot_management(
    command: BotsCommand,
    config: &Config,
    auth_store: &AuthStore,
    json: bool,
    json_format: JsonFormat,
) -> CliResult {
    match command {
        BotsCommand::List(_) | BotsCommand::Create(_) | BotsCommand::RevealToken(_) => {
            unreachable!("handled in main")
        }
        BotsCommand::Get(args) => {
            let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
            let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
            let bot = find_owned_bot(&mut realtime, bot_user_id).await?;
            let settings = read_agent_settings(&mut realtime, bot_user_id).await?;
            let grants = realtime
                .call(proto::ListAgentGrantsInput {
                    bot_user_id,
                    include_all_subjects: Some(true),
                })
                .await?
                .grants;
            if json {
                output::print_json(
                    &BotDetailsOutput {
                        bot,
                        settings,
                        grants,
                    },
                    json_format,
                )?;
            } else {
                println!("Bot: {}", bot_label(&bot));
                let photo = bot
                    .profile_photo
                    .as_ref()
                    .is_some_and(|photo| photo.photo_id.is_some() || photo.cdn_url.is_some());
                println!("Photo: {}", if photo { "set" } else { "none" });
                match bot.bot_avatar.as_ref() {
                    Some(avatar) => println!("Avatar: {}", terminal_text(&avatar.display_name)),
                    None => println!("Avatar: none"),
                }
                let mode = settings
                    .as_ref()
                    .map(|settings| settings.default_output_mode)
                    .unwrap_or_default();
                println!("Output mode: {}", output_mode_label(mode));
                print_grants(&grants);
            }
        }
        BotsCommand::Update(args) => {
            let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
            let name = args
                .name
                .as_deref()
                .map(str::trim)
                .map(|name| {
                    if name.is_empty() {
                        Err(CliError::invalid_args("Bot name cannot be empty"))
                    } else {
                        Ok(name.to_string())
                    }
                })
                .transpose()?;
            let username = args
                .username
                .as_deref()
                .map(|username| username.trim().trim_start_matches('@'))
                .map(|username| {
                    if username.is_empty() {
                        Err(CliError::invalid_args("Bot username cannot be empty"))
                    } else if !username.to_lowercase().ends_with("bot") {
                        Err(CliError::invalid_args("Bot username must end with \"bot\""))
                    } else {
                        Ok(username.to_string())
                    }
                })
                .transpose()?;
            let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
            let payload = realtime
                .call(proto::UpdateBotProfileInput {
                    bot_user_id,
                    name,
                    photo_file_unique_id: None,
                    username,
                })
                .await?;
            print_profile_result(&payload, "Updated profile", json, json_format)?;
        }
        BotsCommand::SetPhoto(args) => {
            let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
            let upload_input = prepare_photo_upload(&args.file)?;
            let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
            if !json {
                println!(
                    "Uploading {}...",
                    terminal_text(&args.file.display().to_string())
                );
            }
            let upload = realtime.upload(upload_input).await?;
            let payload = realtime
                .call(proto::UpdateBotProfileInput {
                    bot_user_id,
                    name: None,
                    photo_file_unique_id: Some(upload.file_unique_id),
                    username: None,
                })
                .await?;
            print_profile_result(&payload, "Set photo", json, json_format)?;
        }
        BotsCommand::RemovePhoto(args) => {
            let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
            let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
            // An empty file id clears the photo, as the apps do.
            let payload = realtime
                .call(proto::UpdateBotProfileInput {
                    bot_user_id,
                    name: None,
                    photo_file_unique_id: Some(String::new()),
                    username: None,
                })
                .await?;
            print_profile_result(&payload, "Removed photo", json, json_format)?;
        }
        BotsCommand::ClearAvatar(args) => {
            let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
            let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
            let payload = realtime
                .call(proto::ClearBotAvatarInput { bot_user_id })
                .await?;
            if json {
                output::print_json(&payload, json_format)?;
            } else if let Some(bot) = payload.bot.as_ref() {
                println!("Cleared avatar for {}.", bot_label(bot));
            } else {
                println!("Cleared avatar.");
            }
        }
        BotsCommand::RotateToken(args) => {
            let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
            if json && !args.yes {
                return Err(CliError::confirmation_required().into());
            }
            if !confirm_action(
                &format!(
                    "Rotate the token for bot {bot_user_id}? The current token stops working."
                ),
                args.yes,
            )? {
                println!("Cancelled.");
                return Ok(());
            }
            let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
            let payload = realtime
                .call(proto::RotateBotTokenInput { bot_user_id })
                .await?;
            if json {
                output::print_json(&payload, json_format)?;
            } else {
                println!("{}", payload.token);
            }
        }
        BotsCommand::Delete(args) => {
            let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
            if json && !args.yes {
                return Err(CliError::confirmation_required().into());
            }
            if !confirm_action(
                &format!("Delete bot {bot_user_id}? Its token stops working."),
                args.yes,
            )? {
                println!("Cancelled.");
                return Ok(());
            }
            let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
            let payload = realtime.call(proto::DeleteBotInput { bot_user_id }).await?;
            if json {
                output::print_json(&payload, json_format)?;
            } else {
                println!("Deleted bot {}.", payload.bot_user_id);
            }
        }
        BotsCommand::Settings(args) => {
            let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
            let chat_id = args
                .chat_id
                .map(|chat_id| validate_positive_id_arg("--chat-id", chat_id))
                .transpose()?;
            let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
            if let Some(chat_id) = chat_id {
                if let Some(mode) = args.output_mode {
                    realtime
                        .call(proto::SetAgentParticipationInput {
                            peer_id: Some(chat_peer(chat_id)),
                            bot_user_id,
                            output_mode: Some(mode.protocol_value() as i32),
                            ..Default::default()
                        })
                        .await?;
                }
                let thread_mode =
                    read_thread_output_mode(&mut realtime, bot_user_id, chat_id).await?;
                let default_mode = read_agent_settings(&mut realtime, bot_user_id)
                    .await?
                    .map(|settings| settings.default_output_mode)
                    .unwrap_or_default();
                if json {
                    output::print_json(
                        &ThreadOutputModeOutput {
                            bot_user_id,
                            chat_id,
                            output_mode: thread_mode.map(output_mode_label),
                            default_output_mode: output_mode_label(default_mode),
                        },
                        json_format,
                    )?;
                } else {
                    match thread_mode {
                        Some(mode) => {
                            println!("Output mode in chat {chat_id}: {}", output_mode_label(mode))
                        }
                        None => println!(
                            "Output mode in chat {chat_id}: bot default ({})",
                            output_mode_label(default_mode)
                        ),
                    }
                }
                return Ok(());
            }
            let settings = match args.output_mode {
                None => {
                    let settings = read_agent_settings(&mut realtime, bot_user_id).await?;
                    if json {
                        return Ok(output::print_json(
                            &proto::GetAgentSettingsResult { settings },
                            json_format,
                        )?);
                    }
                    settings
                }
                Some(mode) => {
                    let payload = match realtime
                        .call(proto::UpdateAgentSettingsInput {
                            bot_user_id,
                            default_output_mode: Some(mode.protocol_value() as i32),
                        })
                        .await
                    {
                        Ok(payload) => payload,
                        Err(error) => {
                            // Older servers keep the default on the agent runtime only.
                            let runtime = realtime
                                .call(proto::GetAgentRuntimeInput { bot_user_id })
                                .await
                                .ok()
                                .and_then(|payload| payload.runtime);
                            if runtime.is_none() {
                                return Err(CliError::invalid_args(format!(
                                    "Bot {bot_user_id} hasn't connected an agent yet. Output mode applies to agent bots; set one up with `inline agents`, then try again."
                                ))
                                .into());
                            }
                            return Err(error);
                        }
                    };
                    if json {
                        return Ok(output::print_json(&payload, json_format)?);
                    }
                    // Servers before the settings read return only the runtime.
                    payload.settings.or_else(|| {
                        payload.runtime.map(|runtime| proto::AgentSettings {
                            bot_user_id,
                            default_output_mode: runtime.default_output_mode,
                            ..Default::default()
                        })
                    })
                }
            };
            let mode = settings
                .as_ref()
                .map(|settings| settings.default_output_mode)
                .unwrap_or_default();
            println!("Output mode: {}", output_mode_label(mode));
        }
        BotsCommand::Access { command } => match command {
            BotsAccessCommand::List(args) => {
                let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
                let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
                let payload = realtime
                    .call(proto::ListAgentGrantsInput {
                        bot_user_id,
                        include_all_subjects: Some(true),
                    })
                    .await?;
                if json {
                    output::print_json(&payload, json_format)?;
                } else {
                    print_grants(&payload.grants);
                }
            }
            BotsAccessCommand::Grant(args) => {
                let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
                let subject = access_subject(&args.subject)?;
                let label = subject_label(Some(&subject), 0);
                let operations = grant_operations(&args.operations);
                let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
                let payload = realtime
                    .call(proto::SetAgentGrantInput {
                        bot_user_id,
                        user_id: args.subject.user_id.unwrap_or_default(),
                        operations,
                        subject: Some(subject),
                    })
                    .await?;
                if json {
                    output::print_json(&payload, json_format)?;
                } else {
                    let operations = payload
                        .grant
                        .as_ref()
                        .map(|grant| operations_label(&grant.operations))
                        .unwrap_or_else(|| "-".to_string());
                    println!("Granted {label} access to bot {bot_user_id}: {operations}.");
                }
            }
            BotsAccessCommand::Revoke(args) => {
                let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
                let subject = access_subject(&args.subject)?;
                let label = subject_label(Some(&subject), 0);
                let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
                let payload = realtime
                    .call(proto::DeleteAgentGrantInput {
                        bot_user_id,
                        user_id: args.subject.user_id.unwrap_or_default(),
                        subject: Some(subject),
                    })
                    .await?;
                if json {
                    output::print_json(&payload, json_format)?;
                } else {
                    println!("Revoked {label}'s access to bot {bot_user_id}.");
                }
            }
        },
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grant_operations_default_to_invoke_and_steer() {
        assert_eq!(
            grant_operations(&[]),
            vec![
                proto::AgentGrantOperation::Invoke as i32,
                proto::AgentGrantOperation::Steer as i32
            ]
        );
    }

    #[test]
    fn grant_operations_dedupe_in_order() {
        assert_eq!(
            grant_operations(&[
                BotGrantOperation::Approve,
                BotGrantOperation::Invoke,
                BotGrantOperation::Approve,
            ]),
            vec![
                proto::AgentGrantOperation::Approve as i32,
                proto::AgentGrantOperation::Invoke as i32
            ]
        );
    }

    #[test]
    fn labels_preserve_an_unset_output_preference() {
        assert_eq!(output_mode_label(0), "unset");
        assert_eq!(
            output_mode_label(BotOutputMode::Detailed.protocol_value() as i32),
            "detailed"
        );
        assert_eq!(
            BotOutputMode::Default.protocol_value(),
            proto::AgentOutputMode::Unspecified
        );
        assert_eq!(
            output_mode_label(proto::AgentOutputMode::Friendly as i32),
            "friendly"
        );
        assert_eq!(
            operations_label(&[
                proto::AgentGrantOperation::Invoke as i32,
                proto::AgentGrantOperation::Configure as i32
            ]),
            "invoke, configure"
        );
        assert_eq!(operations_label(&[]), "-");
    }
}
