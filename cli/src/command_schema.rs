use clap::{Arg, ArgAction, Command};
use serde::Serialize;

use crate::errors::CliError;
use crate::output::{self, JsonFormat};

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CommandSchema {
    schema_version: u8,
    cli_version: &'static str,
    path: Vec<String>,
    name: String,
    about: Option<String>,
    aliases: Vec<String>,
    usage: String,
    arguments: Vec<ArgumentSchema>,
    subcommands: Vec<SubcommandSchema>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ArgumentSchema {
    id: String,
    long: Option<String>,
    short: Option<char>,
    aliases: Vec<String>,
    value_names: Vec<String>,
    help: Option<String>,
    required: bool,
    global: bool,
    action: &'static str,
    min_values: usize,
    max_values: Option<usize>,
    possible_values: Vec<String>,
    default_values: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SubcommandSchema {
    name: String,
    about: Option<String>,
    aliases: Vec<String>,
}

pub(crate) fn print_command_schema(
    mut root: Command,
    requested_path: &[String],
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    root.build();
    let (command, path) = resolve_command(&root, requested_path)?;
    output::print_json(&command_schema(command, path), json_format)?;
    Ok(())
}

fn resolve_command<'a>(
    root: &'a Command,
    requested_path: &[String],
) -> Result<(&'a Command, Vec<String>), CliError> {
    let mut command = root;
    let mut path = vec![root.get_name().to_string()];
    for segment in requested_path {
        let Some(next) = command
            .find_subcommand(segment)
            .filter(|subcommand| !subcommand.is_hide_set())
        else {
            let available = command
                .get_subcommands()
                .filter(|subcommand| !subcommand.is_hide_set())
                .map(Command::get_name)
                .collect::<Vec<_>>();
            return Err(CliError {
                code: "unknown_command_path",
                message: format!(
                    "Unknown command segment {segment:?} below `{}`",
                    path.join(" ")
                ),
                hint: (!available.is_empty())
                    .then(|| format!("Available subcommands: {}", available.join(", "))),
                examples: vec![if path.len() == 1 {
                    "inline schema commands".to_string()
                } else {
                    format!("inline schema commands {}", path[1..].join(" "))
                }],
            });
        };
        path.push(next.get_name().to_string());
        command = next;
    }
    Ok((command, path))
}

fn command_schema(command: &Command, path: Vec<String>) -> CommandSchema {
    let mut usage_command = command.clone();
    let usage = usage_command.render_usage().to_string();
    CommandSchema {
        schema_version: 1,
        cli_version: env!("CARGO_PKG_VERSION"),
        path,
        name: command.get_name().to_string(),
        about: command_about(command),
        aliases: command.get_visible_aliases().map(str::to_string).collect(),
        usage: usage.trim().to_string(),
        arguments: command
            .get_arguments()
            .filter(|argument| !argument.is_hide_set())
            .map(argument_schema)
            .collect(),
        subcommands: command
            .get_subcommands()
            .filter(|subcommand| !subcommand.is_hide_set())
            .map(|subcommand| SubcommandSchema {
                name: subcommand.get_name().to_string(),
                about: command_about(subcommand),
                aliases: subcommand
                    .get_visible_aliases()
                    .map(str::to_string)
                    .collect(),
            })
            .collect(),
    }
}

fn command_about(command: &Command) -> Option<String> {
    command
        .get_long_about()
        .or_else(|| command.get_about())
        .map(ToString::to_string)
}

fn argument_schema(argument: &Arg) -> ArgumentSchema {
    let values = argument.get_num_args().unwrap_or_default();
    let max_values = values.max_values();
    ArgumentSchema {
        id: argument.get_id().as_str().to_string(),
        long: argument.get_long().map(str::to_string),
        short: argument.get_short(),
        aliases: argument
            .get_visible_aliases()
            .unwrap_or_default()
            .into_iter()
            .map(str::to_string)
            .collect(),
        value_names: argument
            .get_value_names()
            .unwrap_or_default()
            .iter()
            .map(ToString::to_string)
            .collect(),
        help: argument
            .get_long_help()
            .or_else(|| argument.get_help())
            .map(ToString::to_string),
        required: argument.is_required_set(),
        global: argument.is_global_set(),
        action: action_name(argument.get_action()),
        min_values: values.min_values(),
        max_values: (max_values != usize::MAX).then_some(max_values),
        possible_values: argument
            .get_possible_values()
            .into_iter()
            .filter(|value| !value.is_hide_set())
            .map(|value| value.get_name().to_string())
            .collect(),
        default_values: argument
            .get_default_values()
            .iter()
            .map(|value| value.to_string_lossy().into_owned())
            .collect(),
    }
}

fn action_name(action: &ArgAction) -> &'static str {
    match action {
        ArgAction::Set => "set",
        ArgAction::Append => "append",
        ArgAction::SetTrue => "set_true",
        ArgAction::SetFalse => "set_false",
        ArgAction::Count => "count",
        ArgAction::Help => "help",
        ArgAction::HelpShort => "help_short",
        ArgAction::HelpLong => "help_long",
        ArgAction::Version => "version",
        _ => "other",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::{Arg, Command};

    fn fixture() -> Command {
        Command::new("inline")
            .arg(
                Arg::new("json")
                    .long("json")
                    .global(true)
                    .action(ArgAction::SetTrue),
            )
            .subcommand(
                Command::new("messages")
                    .visible_alias("message")
                    .alias("msg-hidden")
                    .about("Read and send messages")
                    .subcommand(
                        Command::new("send").arg(
                            Arg::new("chat_id")
                                .long("chat-id")
                                .required(true)
                                .value_name("ID"),
                        ),
                    ),
            )
            .subcommand(Command::new("internal").hide(true))
    }

    #[test]
    fn resolves_aliases_but_reports_the_canonical_path() {
        let mut root = fixture();
        root.build();
        let (command, path) =
            resolve_command(&root, &["message".to_string(), "send".to_string()]).unwrap();

        assert_eq!(command.get_name(), "send");
        assert_eq!(path, ["inline", "messages", "send"]);
    }

    #[test]
    fn schema_hides_internal_commands_and_describes_flags() {
        let mut root = fixture();
        root.build();
        let schema = command_schema(&root, vec!["inline".to_string()]);

        assert!(
            schema
                .subcommands
                .iter()
                .any(|command| command.name == "messages")
        );
        let messages = schema
            .subcommands
            .iter()
            .find(|command| command.name == "messages")
            .unwrap();
        assert_eq!(messages.aliases, ["message"]);
        assert!(
            !schema
                .subcommands
                .iter()
                .any(|command| command.name == "internal")
        );
        assert!(
            schema
                .arguments
                .iter()
                .any(|argument| argument.long.as_deref() == Some("json"))
        );
    }

    #[test]
    fn unknown_paths_return_available_subcommands() {
        let mut root = fixture();
        root.build();
        let error = resolve_command(&root, &["missing".to_string()]).unwrap_err();

        assert_eq!(error.code, "unknown_command_path");
        assert!(
            error
                .hint
                .as_deref()
                .unwrap_or_default()
                .contains("messages")
        );
        assert!(
            !error
                .hint
                .as_deref()
                .unwrap_or_default()
                .contains("internal")
        );
    }
}
