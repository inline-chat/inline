use std::io;

use sha2::{Digest, Sha256};

use crate::bridge::{
    AgentSetupInstallation, agent_setup_installation, upsert_agent_setup_installation,
};
use crate::config::Config;
use crate::identity::connect_realtime;
use inline_protocol::proto;

use super::catalog::TargetDescriptor;
use super::{AgentsSetupArgs, cli_error};

pub(super) struct ManagedBot {
    pub(super) owner_user_id: i64,
    pub(super) id: i64,
    pub(super) username: String,
    pub(super) name: String,
    pub(super) action: &'static str,
    token: String,
}

impl ManagedBot {
    pub(super) fn token(&self) -> &str {
        &self.token
    }
}

pub(super) async fn ensure_gateway_bot(
    config: &Config,
    owner_auth: inline_client::AuthCredential,
    target: &'static TargetDescriptor,
    instance: &str,
    args: &AgentsSetupArgs,
    configured_bot_id: Option<i64>,
) -> Result<ManagedBot, Box<dyn std::error::Error>> {
    let mut owner = crate::owner_session::OwnerSession::connect(config, owner_auth).await?;
    let owner_user = owner
        .call(proto::GetMeInput {})
        .await?
        .user
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "GetMe returned no user"))?;
    if owner_user.id <= 0 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "owner id is invalid").into());
    }

    let mapping = agent_setup_installation(target.id, instance)?;
    let bots = owner.call(proto::ListBotsInput {}).await?.bots;
    let requested_username = args
        .bot_username
        .as_deref()
        .map(normalize_username)
        .transpose()?;
    let default_username = default_bot_username(target.id, owner_user.id, instance);

    let requested_bot_id = args
        .bot_id
        .or_else(|| mapping.as_ref().map(|mapping| mapping.bot_user_id));
    ensure_configured_bot_compatible(configured_bot_id, requested_bot_id, args.replace)?;

    let selected = if let Some(bot_id) = args.bot_id {
        bots.iter()
            .find(|bot| bot.id == bot_id)
            .cloned()
            .ok_or_else(|| {
                cli_error(
                    "setup_conflict",
                    format!("bot {bot_id} is not owned by the authenticated Inline user"),
                )
            })?
    } else if let Some(mapping) = mapping.as_ref() {
        match bots
            .iter()
            .find(|bot| bot.id == mapping.bot_user_id)
            .cloned()
        {
            Some(bot) => bot,
            None if args.replace => find_bot_by_username(
                &bots,
                requested_username.as_deref().unwrap_or(&default_username),
            )
            .unwrap_or_default(),
            None => {
                return Err(cli_error(
                    "mapped_bot_missing",
                    "the saved setup bot is no longer available; rerun with --replace to create a replacement",
                )
                .into());
            }
        }
    } else if let Some(configured_bot_id) = configured_bot_id {
        match bots.iter().find(|bot| bot.id == configured_bot_id).cloned() {
            Some(bot) => bot,
            None if args.replace => find_bot_by_username(
                &bots,
                requested_username.as_deref().unwrap_or(&default_username),
            )
            .unwrap_or_default(),
            None => {
                return Err(cli_error(
                    "setup_conflict",
                    "the gateway's configured Inline bot is not owned by the authenticated user; rerun with --replace to replace it",
                )
                .into());
            }
        }
    } else {
        find_bot_by_username(
            &bots,
            requested_username.as_deref().unwrap_or(&default_username),
        )
        .unwrap_or_default()
    };

    let requested_name = args
        .bot_name
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty());
    let default_name = || {
        owner_user
            .first_name
            .as_deref()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map_or_else(
                || format!("My {}", target.display_name),
                |first_name| format!("{first_name}'s {}", target.display_name),
            )
    };
    let create_name = requested_name
        .map(str::to_string)
        .unwrap_or_else(default_name);
    let username = requested_username.unwrap_or(default_username);

    let (mut bot, created_token) = if selected.id > 0 {
        if bot_username(&selected) != username && args.bot_username.is_some() {
            return Err(cli_error(
                "setup_conflict",
                "--bot-username does not match the selected existing bot",
            )
            .into());
        }
        (selected, None)
    } else {
        let created = owner
            .call(proto::CreateBotInput {
                name: create_name.clone(),
                username: username.clone(),
                add_to_space: None,
            })
            .await?;
        let bot = created.bot.ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "CreateBot returned no bot")
        })?;
        (bot, Some(created.token))
    };

    if let Some(name) = requested_name
        && bot.first_name.as_deref().unwrap_or_default().trim() != name
    {
        bot = owner
            .call(proto::UpdateBotProfileInput {
                bot_user_id: bot.id,
                name: Some(name.to_string()),
                photo_file_unique_id: None,
            })
            .await?
            .bot
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "UpdateBotProfile returned no bot",
                )
            })?;
    }

    let action = if created_token.is_some() {
        "created"
    } else {
        "reused"
    };
    let token = match created_token {
        Some(token) if !token.trim().is_empty() => token,
        _ => {
            owner
                .call(proto::RevealBotTokenInput {
                    bot_user_id: bot.id,
                })
                .await?
                .token
        }
    };
    if token.trim().is_empty() {
        return Err(
            io::Error::new(io::ErrorKind::InvalidData, "Inline returned no bot token").into(),
        );
    }
    let mut bot_client = connect_realtime(&config.realtime_url, &token).await?;
    let verified = bot_client
        .call(proto::GetMeInput {})
        .await?
        .user
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "bot GetMe returned no user"))?;
    if verified.id != bot.id {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline bot credential resolved to a different bot",
        )
        .into());
    }

    let username = bot_username(&bot);
    upsert_agent_setup_installation(
        owner_user.id,
        AgentSetupInstallation {
            target: target.id.to_string(),
            instance: instance.to_string(),
            bot_user_id: bot.id,
            bot_username: username.clone(),
        },
    )?;
    Ok(ManagedBot {
        owner_user_id: owner_user.id,
        id: bot.id,
        username,
        name: bot
            .first_name
            .as_deref()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .unwrap_or(&create_name)
            .to_string(),
        action,
        token,
    })
}

fn find_bot_by_username(bots: &[proto::User], username: &str) -> Option<proto::User> {
    bots.iter()
        .find(|bot| bot.username.as_deref() == Some(username))
        .cloned()
}

fn bot_username(bot: &proto::User) -> String {
    bot.username
        .as_deref()
        .unwrap_or_default()
        .trim_start_matches('@')
        .to_string()
}

pub(super) fn normalize_username(value: &str) -> Result<String, Box<dyn std::error::Error>> {
    let value = value.trim();
    let value = value.strip_prefix('@').unwrap_or(value);
    let valid = value.len() <= 256
        && value.ends_with("bot")
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_');
    if !valid {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "bot username must use letters, numbers, or underscores and end in bot",
        )
        .into());
    }
    Ok(value.to_string())
}

fn ensure_configured_bot_compatible(
    configured_bot_id: Option<i64>,
    requested_bot_id: Option<i64>,
    replace: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    if configured_bot_id
        .zip(requested_bot_id)
        .is_some_and(|(configured_bot_id, requested_bot_id)| configured_bot_id != requested_bot_id)
        && !replace
    {
        return Err(cli_error(
            "setup_conflict",
            "the gateway is configured for a different Inline bot; rerun with --replace to change it",
        )
        .into());
    }
    Ok(())
}

fn default_bot_username(target: &str, owner_user_id: i64, instance: &str) -> String {
    let digest = Sha256::digest(instance.as_bytes());
    let suffix = digest[..3]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    format!("inline_{target}_{owner_user_id}_{suffix}_bot")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_username_is_stable_and_bot_suffixed() {
        assert_eq!(
            default_bot_username("hermes", 42, "default"),
            "inline_hermes_42_37a8ee_bot"
        );
    }

    #[test]
    fn username_normalization_accepts_at_prefix() {
        assert_eq!(normalize_username("@my_bot").unwrap(), "my_bot");
        assert!(normalize_username("@@my_bot").is_err());
        assert!(normalize_username("not-an-agent").is_err());
    }

    #[test]
    fn gateway_bot_conflicts_require_replace() {
        ensure_configured_bot_compatible(Some(42), Some(42), false)
            .expect("matching bot is compatible");
        assert!(ensure_configured_bot_compatible(Some(42), Some(43), false).is_err());
        ensure_configured_bot_compatible(Some(42), Some(43), true)
            .expect("explicit replacement is allowed");
    }
}
