use thiserror::Error;

use crate::CommandInvocation;

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum CommandParseError {
    #[error("a slash command must include a command name")]
    MissingName,
    #[error("slash command names may contain only lowercase letters, digits, and underscores")]
    InvalidName,
    #[error("a slash command may target at most one bot username")]
    InvalidTarget,
}

/// Parses Inline's `/command`, `/command args`, and
/// `/command@bot_username args` forms without interpreting the arguments.
pub fn parse_command(
    text: &str,
    bot_username: &str,
) -> Result<Option<CommandInvocation>, CommandParseError> {
    let text = text.trim();
    let Some(command_text) = text.strip_prefix('/') else {
        return Ok(None);
    };
    let (head, arguments) = command_text
        .split_once(char::is_whitespace)
        .map_or((command_text, ""), |(head, arguments)| {
            (head, arguments.trim())
        });
    if head.is_empty() {
        return Err(CommandParseError::MissingName);
    }
    let mut parts = head.split('@');
    let name = parts.next().unwrap_or_default();
    let target = parts.next();
    if parts.next().is_some() || target.is_some_and(str::is_empty) {
        return Err(CommandParseError::InvalidTarget);
    }
    if name.is_empty()
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
    {
        return Err(CommandParseError::InvalidName);
    }
    let bot_username = bot_username.trim().trim_start_matches('@');
    Ok(Some(CommandInvocation {
        name: name.to_string(),
        arguments: arguments.to_string(),
        explicit_target: target.is_some(),
        targets_this_bot: target.is_some_and(|target| {
            !bot_username.is_empty() && target.eq_ignore_ascii_case(bot_username)
        }),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_plain_targeted_and_argument_commands() {
        assert_eq!(
            parse_command("/status", "mo_codex_bot").unwrap(),
            Some(CommandInvocation {
                name: "status".to_string(),
                arguments: String::new(),
                explicit_target: false,
                targets_this_bot: false,
            })
        );
        assert_eq!(
            parse_command(" /queue@MO_CODEX_BOT   fix the tests  ", "@mo_codex_bot").unwrap(),
            Some(CommandInvocation {
                name: "queue".to_string(),
                arguments: "fix the tests".to_string(),
                explicit_target: true,
                targets_this_bot: true,
            })
        );
        assert_eq!(parse_command("ordinary text", "bot").unwrap(), None);
    }

    #[test]
    fn rejects_ambiguous_or_noncanonical_commands() {
        assert_eq!(
            parse_command("/", "bot"),
            Err(CommandParseError::MissingName)
        );
        assert_eq!(
            parse_command("/Status", "bot"),
            Err(CommandParseError::InvalidName)
        );
        assert_eq!(
            parse_command("/status@a@b", "bot"),
            Err(CommandParseError::InvalidTarget)
        );
    }
}
