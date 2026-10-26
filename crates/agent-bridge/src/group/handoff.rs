//! Out-of-Inline handoff instructions (spec §4.6): "Continue in terminal"
//! and "Open in ChatGPT / Claude app", shown after the session is released.

use std::path::Path;

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HandoffProvider {
    Codex,
    Claude,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HandoffTarget {
    Terminal,
    /// The ChatGPT app for Codex, the Claude desktop app for Claude. Only
    /// offered when the viewer is on the session's machine.
    App,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HandoffInstruction {
    /// A shell command to run on the session's machine.
    Command { command: String },
    /// A link that opens the session in the app.
    Url { url: String },
}

/// The native way to pick the session up elsewhere. Commands change to the
/// session's folder first, since Claude resolves sessions per project folder.
pub fn handoff_instruction(
    provider: HandoffProvider,
    target: HandoffTarget,
    session_id: &str,
    folder: Option<&Path>,
) -> HandoffInstruction {
    let id = shell_quote(session_id);
    let command = match (provider, target) {
        (HandoffProvider::Codex, HandoffTarget::App) => {
            return HandoffInstruction::Url {
                url: format!("codex://threads/{}", url_segment(session_id)),
            };
        }
        (HandoffProvider::Codex, HandoffTarget::Terminal) => format!("codex resume {id}"),
        (HandoffProvider::Claude, HandoffTarget::Terminal) => format!("claude --resume {id}"),
        (HandoffProvider::Claude, HandoffTarget::App) => {
            format!("claude --desktop --resume {id}")
        }
    };
    let command = match folder {
        Some(folder) => format!("cd {} && {command}", shell_quote(&folder.to_string_lossy())),
        None => command,
    };
    HandoffInstruction::Command { command }
}

fn is_plain(value: &str) -> bool {
    !value.is_empty()
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.' | '/' | ':')
        })
}

fn shell_quote(value: &str) -> String {
    if is_plain(value) {
        value.to_string()
    } else {
        format!("'{}'", value.replace('\'', r"'\''"))
    }
}

fn url_segment(value: &str) -> String {
    value
        .bytes()
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.') {
                (byte as char).to_string()
            } else {
                format!("%{byte:02X}")
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "019a2b3c-4d5e-7f00-8123-456789abcdef";

    fn command(instruction: HandoffInstruction) -> String {
        match instruction {
            HandoffInstruction::Command { command } => command,
            other => panic!("expected a command, got {other:?}"),
        }
    }

    #[test]
    fn terminal_commands_resume_in_the_session_folder() {
        assert_eq!(
            command(handoff_instruction(
                HandoffProvider::Codex,
                HandoffTarget::Terminal,
                ID,
                Some(Path::new("/Users/mo/dev/inline"))
            )),
            format!("cd /Users/mo/dev/inline && codex resume {ID}")
        );
        assert_eq!(
            command(handoff_instruction(
                HandoffProvider::Claude,
                HandoffTarget::Terminal,
                ID,
                Some(Path::new("/Users/mo/My Projects/it's"))
            )),
            format!("cd '/Users/mo/My Projects/it'\\''s' && claude --resume {ID}")
        );
        assert_eq!(
            command(handoff_instruction(
                HandoffProvider::Claude,
                HandoffTarget::App,
                ID,
                None
            )),
            format!("claude --desktop --resume {ID}")
        );
    }

    #[test]
    fn codex_app_handoff_is_a_thread_link() {
        assert_eq!(
            handoff_instruction(HandoffProvider::Codex, HandoffTarget::App, ID, None),
            HandoffInstruction::Url {
                url: format!("codex://threads/{ID}")
            }
        );
        assert_eq!(
            handoff_instruction(HandoffProvider::Codex, HandoffTarget::App, "a b/c", None),
            HandoffInstruction::Url {
                url: "codex://threads/a%20b%2Fc".into()
            }
        );
    }

    #[test]
    fn hostile_ids_are_quoted() {
        assert_eq!(
            command(handoff_instruction(
                HandoffProvider::Codex,
                HandoffTarget::Terminal,
                "x; rm -rf ~",
                None
            )),
            "codex resume 'x; rm -rf ~'"
        );
    }
}
