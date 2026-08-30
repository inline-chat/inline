use clap::{Command, builder::Resettable};
use std::io::{self, Write};

pub(crate) fn write(
    shell: clap_complete::Shell,
    command: &mut Command,
    mut writer: impl Write,
) -> io::Result<()> {
    // The upstream generators panic on write failures. Keep I/O at our boundary
    // so a consumer closing a pipeline is quiet and other write errors propagate.
    let mut script = Vec::new();
    clap_complete::generate(shell, command, "inline", &mut script);
    match writer.write_all(&script) {
        Err(error) if error.kind() == io::ErrorKind::BrokenPipe => Ok(()),
        result => result,
    }
}

// Static completion generators include hidden entries. Project the public tree
// from the real parser so command names, aliases and value parsers stay in sync.
// This tree is used only for completion, never to parse or validate commands.
pub(crate) fn public_command(source: &Command) -> Command {
    // Build a clone so global arguments and group conflicts can be resolved at
    // every level, without changing the parser used by the caller.
    let mut source = source.clone();
    source.build();
    project_command(&source)
}

fn project_command(source: &Command) -> Command {
    let mut command = Command::new(source.get_name().to_owned())
        .propagate_version(source.is_propagate_version_set())
        .disable_version_flag(source.is_disable_version_flag_set())
        .disable_help_flag(source.is_disable_help_flag_set())
        .disable_help_subcommand(source.is_disable_help_subcommand_set())
        .visible_aliases(source.get_visible_aliases().map(str::to_owned));

    if let Some(about) = source.get_about() {
        command = command.about(about.clone());
    }
    if let Some(version) = source.get_version() {
        command = command.version(version.to_owned());
    }

    // Let clap recreate its generated entries from the public tree. Copying the
    // generated help subtree would make it a normal command and inherit globals.
    for arg in source.get_arguments().filter(|arg| {
        !arg.is_hide_set()
            && (source.is_disable_help_flag_set() || arg.get_id() != "help")
            && (source.is_disable_version_flag_set() || arg.get_id() != "version")
    }) {
        let conflicts = source
            .get_arg_conflicts_with(arg)
            .into_iter()
            .filter(|other| !other.is_hide_set())
            .map(|other| other.get_id().clone())
            .collect::<Vec<_>>();
        // Validation constraints can refer to omitted arguments or derive groups.
        command = command.arg(
            arg.clone()
                .conflicts_with(Resettable::Reset)
                .requires(Resettable::Reset)
                .group(Resettable::Reset)
                .required_unless_present(Resettable::Reset)
                .conflicts_with_all(conflicts),
        );
    }
    for child in source.get_subcommands().filter(|child| {
        !child.is_hide_set()
            && (source.is_disable_help_subcommand_set() || child.get_name() != "help")
    }) {
        command = command.subcommand(project_command(child));
    }
    command
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::{Arg, CommandFactory};

    #[test]
    fn omits_hidden_entries_without_changing_the_real_parser() {
        let source = Command::new("example")
            .arg(Arg::new("public").long("public").conflicts_with("internal"))
            .arg(Arg::new("internal").long("internal").hide(true))
            .subcommand(Command::new("list").visible_alias("ls"))
            .subcommand(Command::new("internal-host").hide(true));
        let projected = public_command(&source);
        assert_eq!(source.get_arguments().count(), 2);
        assert_eq!(source.get_subcommands().count(), 2);
        assert!(
            projected
                .get_arguments()
                .any(|arg| arg.get_id() == "public")
        );
        assert!(
            !projected
                .get_arguments()
                .any(|arg| arg.get_id() == "internal")
        );
        assert!(projected.find_subcommand("internal-host").is_none());
        assert_eq!(
            projected
                .find_subcommand("list")
                .unwrap()
                .get_visible_aliases()
                .collect::<Vec<_>>(),
            vec!["ls"]
        );
        projected.debug_assert();
        source.debug_assert();
    }

    #[test]
    fn public_cli_tree_is_valid() {
        public_command(&crate::Cli::command()).debug_assert();
    }

    #[test]
    fn generated_help_subtree_does_not_inherit_normal_command_flags() {
        let mut command = public_command(&crate::Cli::command());
        command.build();
        let help = command.find_subcommand("help").unwrap();
        let messages = help.find_subcommand("messages").unwrap();
        for command in [help, messages] {
            assert!(!command.get_arguments().any(|arg| arg.is_global_set()));
        }
    }

    #[test]
    fn zsh_preserves_visible_option_conflicts() {
        let mut command = public_command(&crate::Cli::command());
        let mut script = Vec::new();
        write(clap_complete::Shell::Zsh, &mut command, &mut script).unwrap();
        let script = String::from_utf8(script).unwrap();
        for (option, conflict) in [
            ("--pretty[", "--compact"),
            ("--chat-id=", "--user-id"),
            ("--text-file=", "--text"),
        ] {
            let line = script.lines().find(|line| line.contains(option)).unwrap();
            assert!(line.contains(conflict), "{line}");
        }
    }
}
