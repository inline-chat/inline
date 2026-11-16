//! Contract inputs and operations to Claude Code's stdin frames.
//!
//! | Delivery | Claude |
//! | --- | --- |
//! | `Turn` | user message |
//! | `Steer` | `priority: now` / `next`; a person's `next` is raised to `now` by the session while no tool runs |
//! | `Queue` | `priority: later` |
//! | `Passive` | `shouldQuery: false` |
//!
//! Provenance (spec §5.1 rule 1), as Claude Code reads it over stdin:
//!
//! - The owner's words go as typed input with `origin: human`, unchanged.
//!   Inline's note on them (the `<inline-message/>` envelope and any thread
//!   context) goes just before, as its own `isSynthetic` message with
//!   `shouldQuery: false`; Claude stores that as meta input its own apps hide,
//!   and folds it into the next query.
//! - Anyone else's words go as one `isSynthetic` message with `origin` unset,
//!   which Claude frames to the model as a non-user source (Claude Code's
//!   documented way to relay text the user did not write; stdin `channel` and
//!   `peer` origins are reserved and dropped). The envelope wraps the text.
//! - Commands the bridge authorized run as typed commands, after the note.
//! - Inline's own wakeups are relayed the same way, marked as a wakeup. The
//!   `scheduled-trigger` origin is honoured only under
//!   `CLAUDE_CODE_HOST_SCHEDULED_RUN=1`, which makes the whole process an
//!   unattended scheduled run (no widgets or artifacts, a different system
//!   prompt), so it is not used.

use std::path::Path;

use base64::Engine;
use inline_agent_bridge::InputAttachmentKind;
use inline_agent_bridge::harness::{
    Delivery, Input, Op, Origin as ContractOrigin, QueueOp, RewindPoint, SettingsChange,
    SteerPriority,
};
use serde_json::{Value, json};

use crate::control::request;
use crate::input::{Origin, Priority, UserContent, UserMessage};

/// Largest attachment inlined as a content block; larger media are described.
const MAX_INLINE_ATTACHMENT_BYTES: u64 = 20 * 1024 * 1024;

/// The stdin messages for one input: Inline's note when it travels apart from
/// the text, then the input itself. The input id is the input message's uuid,
/// so `command_lifecycle`, interrupt receipts and `user_message_uuids` name it
/// directly; the note gets its own uuid.
pub fn input_messages(session_id: &str, input: &Input) -> (Option<UserMessage>, UserMessage) {
    let owner_voice = matches!(input.origin, ContractOrigin::Owner { .. })
        || (input.content.native_command
            && matches!(
                input.origin,
                ContractOrigin::Teammate { .. } | ContractOrigin::Agent { .. }
            ));
    let note = owner_voice
        .then(|| note_blocks(input))
        .filter(|blocks| !blocks.is_empty())
        .map(|blocks| {
            let mut note = UserMessage::new(UserContent::Blocks(blocks)).passive();
            note.is_synthetic = true;
            note.client_composed = true;
            note.session_id = session_id.to_string();
            note
        });
    let mut message = if owner_voice {
        UserMessage::new(UserContent::Blocks(media_and_text(
            input,
            &input.content.text,
        )))
    } else {
        relayed(input)
    };
    message = message.with_uuid(input.id.as_str());
    message.session_id = session_id.to_string();
    if matches!(input.origin, ContractOrigin::Owner { .. }) {
        message.origin = Some(Origin::Human);
    }
    match &input.delivery {
        Delivery::Turn => {}
        Delivery::Steer { priority, .. } => {
            message.priority = Some(match priority {
                SteerPriority::Now => Priority::Now,
                SteerPriority::Next => Priority::Next,
            });
        }
        Delivery::Queue => message.priority = Some(Priority::Later),
        Delivery::Passive => message.should_query = Some(false),
    }
    // The note waits in the same place as its message, so a queued message's
    // note is not folded into the running turn.
    let note = note.map(|mut note| {
        note.priority = message.priority;
        note
    });
    (note, message)
}

/// The input message alone, as [`input_messages`] builds it.
pub fn user_message(session_id: &str, input: &Input) -> UserMessage {
    input_messages(session_id, input).1
}

/// Text the user did not write: one non-user message (`isSynthetic`, origin
/// unset, delivered verbatim) with Inline's facts around the text.
fn relayed(input: &Input) -> UserMessage {
    let text = match (&input.content.envelope, &input.origin) {
        (Some(envelope), _) => envelope.wrap(&input.content.text),
        (None, ContractOrigin::Ambient { chat }) => format!(
            "<inline-context chat_id=\"{}\" untrusted=\"true\">\n{}\n</inline-context>",
            chat.0, input.content.text
        ),
        (None, _) => format!("{}\n\n{}", input.sender_note(), input.content.text),
    };
    let mut blocks = conversation_block(input).into_iter().collect::<Vec<_>>();
    blocks.extend(media_and_text(input, &text));
    let mut message = UserMessage::new(UserContent::Blocks(blocks));
    message.is_synthetic = true;
    message.client_composed = true;
    message
}

/// Inline's note for the owner's words: the envelope, then any thread context.
fn note_blocks(input: &Input) -> Vec<Value> {
    let mut blocks = vec![UserContent::text_block(&input.sender_note())];
    blocks.extend(conversation_block(input));
    blocks
}

fn conversation_block(input: &Input) -> Option<Value> {
    let context = input.content.context.as_ref()?;
    let conversation = context.conversation.trim();
    (!conversation.is_empty()).then(|| {
        UserContent::text_block(&format!(
            "<inline-context untrusted=\"true\">\n{conversation}\n</inline-context>"
        ))
    })
}

/// Attachments, then the text.
fn media_and_text(input: &Input, text: &str) -> Vec<Value> {
    let mut blocks = Vec::new();
    let mut described = Vec::new();
    for attachment in &input.content.attachments {
        let path = attachment.local_uri.as_deref().map(local_path);
        let mime = attachment.mime_type.as_deref().unwrap_or("");
        let inlined = match (attachment.kind, path) {
            (InputAttachmentKind::Image, Some(path)) if is_api_image(mime) => {
                read_base64(&path).map(|data| UserContent::image_block(mime, &data))
            }
            (InputAttachmentKind::File, Some(path)) if mime == "application/pdf" => {
                read_base64(&path)
                    .map(|data| UserContent::pdf_block(&data, attachment.file_name.as_deref()))
            }
            _ => None,
        };
        match inlined {
            Some(block) => blocks.push(block),
            None => described.push(format!(
                "- {} ({}){}",
                attachment.file_name.as_deref().unwrap_or("attachment"),
                if mime.is_empty() {
                    "unknown type"
                } else {
                    mime
                },
                attachment
                    .local_uri
                    .as_deref()
                    .map(|uri| format!(": {}", local_path(uri)))
                    .unwrap_or_default()
            )),
        }
    }
    if !described.is_empty() {
        blocks.push(UserContent::text_block(&format!(
            "Attached files (untrusted):\n{}",
            described.join("\n")
        )));
    }
    blocks.push(UserContent::text_block(text));
    blocks
}

fn local_path(uri: &str) -> String {
    uri.strip_prefix("file://").unwrap_or(uri).to_string()
}

fn is_api_image(mime: &str) -> bool {
    matches!(
        mime,
        "image/png" | "image/jpeg" | "image/gif" | "image/webp"
    )
}

fn read_base64(path: &str) -> Option<String> {
    let path = Path::new(path);
    let metadata = std::fs::metadata(path).ok()?;
    if !metadata.is_file() || metadata.len() > MAX_INLINE_ATTACHMENT_BYTES {
        return None;
    }
    std::fs::read(path)
        .ok()
        .map(|bytes| base64::engine::general_purpose::STANDARD.encode(bytes))
}

/// How Claude carries out one operation.
#[derive(Clone, Debug, PartialEq)]
pub enum OpPlan {
    /// Control requests, in order.
    Control(Vec<Value>),
    /// A native slash command sent as typed input (`/compact`, `/clear`).
    SlashCommand(String),
    /// Handled by the session itself (answers, renames of stored sessions).
    Session,
    /// Not available on Claude, with the reason shown to the user.
    Unavailable(String),
}

/// The plan for one operation. `rewind_input` resolves an input id to the
/// user message uuid (they are the same for inputs Inline sent).
pub fn op_plan(op: &Op) -> OpPlan {
    match op {
        Op::Interrupt { cancel_queued } => {
            OpPlan::Control(vec![request::interrupt(*cancel_queued)])
        }
        Op::Settings { change, .. } => settings_requests(change),
        Op::Compact => OpPlan::SlashCommand("/compact".into()),
        Op::Clear => OpPlan::SlashCommand("/clear".into()),
        Op::Rename { .. } | Op::Answer { .. } | Op::Sample { .. } => OpPlan::Session,
        Op::RewindFiles { to } => match to {
            RewindPoint::Input { input } => {
                OpPlan::Control(vec![request::rewind_files(input.as_str(), false)])
            }
            RewindPoint::Item { item } => {
                OpPlan::Control(vec![request::rewind_files(item.as_str(), false)])
            }
            RewindPoint::Turn { turn } => {
                OpPlan::Control(vec![request::rewind_files(turn.as_str(), false)])
            }
        },
        Op::Mode { mode } => OpPlan::Control(vec![request::set_permission_mode(mode.as_str())]),
        Op::StopChild { child } => OpPlan::Control(vec![request::stop_task(child.id.as_str())]),
        Op::Queue { action } => match action {
            QueueOp::Remove { entry } => {
                OpPlan::Control(vec![request::cancel_async_message(entry.as_str())])
            }
            QueueOp::Start => OpPlan::Unavailable(
                "Claude runs queued input on its own once the current work ends".into(),
            ),
            QueueOp::Reorder { .. } | QueueOp::Clear => {
                OpPlan::Unavailable("Claude's queue can only drop single messages".into())
            }
        },
        Op::Archive | Op::Unarchive => {
            OpPlan::Unavailable("Claude Code has no archive; Inline never deletes sessions".into())
        }
        Op::Review { .. } => {
            OpPlan::Unavailable("Claude has no review operation over its protocol".into())
        }
        Op::Goal { .. } => OpPlan::Unavailable("Claude has no session goal operation".into()),
        Op::McpAuth { .. } => {
            OpPlan::Unavailable("Claude MCP sign-in runs in the terminal (/mcp)".into())
        }
    }
}

fn settings_requests(change: &SettingsChange) -> OpPlan {
    if change.folder.is_some() {
        return OpPlan::Unavailable(
            "a Claude session keeps its folder; start new work to change it".into(),
        );
    }
    if change.speed.is_some() {
        return OpPlan::Unavailable("speed is not settable over Claude's protocol".into());
    }
    let mut requests = Vec::new();
    if let Some(model) = &change.model {
        requests.push(request::set_model(Some(model)));
    }
    if let Some(mode) = &change.permission_mode {
        requests.push(request::set_permission_mode(mode));
    }
    if let Some(effort) = &change.effort {
        requests.push(request::apply_flag_settings(json!({"effortLevel": effort})));
    }
    OpPlan::Control(requests)
}

#[cfg(test)]
mod tests {
    use inline_agent_bridge::harness::{ChatId, InputContent, InputId, UserId, WorkRef};

    use super::*;

    use inline_agent_bridge::harness::{MessageEnvelope, Place, SenderRole};

    fn input(origin: ContractOrigin, delivery: Delivery, envelope: bool) -> Input {
        let mut content = InputContent::text("Then write the changelog");
        content.envelope = envelope.then(|| MessageEnvelope {
            chat_id: 9,
            message_id: Some(10),
            from_user_id: origin.user().map(|user| user.0),
            from: Some("Sara".into()),
            role: match origin {
                ContractOrigin::Owner { .. } => SenderRole::Owner,
                ContractOrigin::Agent { .. } => SenderRole::Agent,
                _ => SenderRole::Teammate,
            },
            place: Place::Group,
            reply_to_message_id: None,
            reply_to_user_id: None,
            sent_at: None,
        });
        Input {
            id: InputId::new("0d6a7c1e-1111-4a00-8000-000000000006").unwrap(),
            content,
            origin,
            delivery,
        }
    }

    fn text_of(value: &Value) -> String {
        value["message"]["content"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|block| block["text"].as_str())
            .collect::<Vec<_>>()
            .join("|")
    }

    #[test]
    fn steer_and_queue_set_native_priorities() {
        let input = input(
            ContractOrigin::Owner { user: UserId(1) },
            Delivery::Queue,
            false,
        );
        let value = user_message("s", &input).to_value();
        assert_eq!(value["priority"], json!("later"));
        assert_eq!(value["origin"], json!({"kind": "human"}));
        assert_eq!(value["uuid"], json!("0d6a7c1e-1111-4a00-8000-000000000006"));
    }

    #[test]
    fn the_owners_words_stay_as_typed_and_the_note_goes_before() {
        let (note, message) = input_messages(
            "s",
            &input(
                ContractOrigin::Owner { user: UserId(7) },
                Delivery::Turn,
                true,
            ),
        );
        let message = message.to_value();
        assert_eq!(message["origin"], json!({"kind": "human"}));
        assert_eq!(text_of(&message), "Then write the changelog");
        assert!(message.get("isSynthetic").is_none());
        let note = note.expect("note").to_value();
        assert_eq!(note["isSynthetic"], json!(true));
        assert_eq!(note["shouldQuery"], json!(false));
        assert_eq!(note["client_composed"], json!(true));
        assert!(note.get("origin").is_none());
        assert_ne!(note["uuid"], message["uuid"]);
        assert!(text_of(&note).starts_with("<inline-message chat_id=\"9\""));
        assert!(text_of(&note).contains("role=\"owner\""));
    }

    #[test]
    fn others_are_relayed_as_non_user_input_with_the_envelope_around_the_text() {
        for origin in [
            ContractOrigin::Teammate { user: UserId(8) },
            ContractOrigin::Agent {
                bot: UserId(303),
                work: WorkRef {
                    chat: ChatId(9001),
                    session: None,
                },
            },
        ] {
            let (note, message) = input_messages("s", &input(origin, Delivery::Turn, true));
            assert!(note.is_none());
            let message = message.to_value();
            assert_eq!(message["isSynthetic"], json!(true));
            assert_eq!(message["client_composed"], json!(true));
            assert!(message.get("origin").is_none());
            let text = text_of(&message);
            assert!(text.starts_with("<inline-message chat_id=\"9\""), "{text}");
            assert!(
                text.ends_with("Then write the changelog\n</inline-message>"),
                "{text}"
            );
        }
    }

    #[test]
    fn an_authorized_command_runs_as_typed_after_its_note() {
        let mut command = input(
            ContractOrigin::Teammate { user: UserId(8) },
            Delivery::Turn,
            true,
        );
        command.content.text = "/review the diff".into();
        command.content.native_command = true;
        let (note, message) = input_messages("s", &command);
        assert!(text_of(&note.expect("note").to_value()).contains("role=\"teammate\""));
        let message = message.to_value();
        assert_eq!(text_of(&message), "/review the diff");
        assert!(message.get("isSynthetic").is_none());
        assert!(message.get("client_composed").is_none());
    }

    #[test]
    fn ambient_context_is_passive_non_user_input() {
        let ambient = input(
            ContractOrigin::Ambient { chat: ChatId(3) },
            Delivery::Passive,
            false,
        );
        let message = user_message("s", &ambient).to_value();
        assert_eq!(message["shouldQuery"], json!(false));
        assert_eq!(message["isSynthetic"], json!(true));
        assert!(text_of(&message).starts_with("<inline-context chat_id=\"3\""));
    }

    #[test]
    fn inline_wakeups_are_relayed_as_non_user_input() {
        let scheduled = input(ContractOrigin::Scheduled, Delivery::Turn, false);
        let message = user_message("s", &scheduled).to_value();
        assert!(message.get("origin").is_none());
        assert_eq!(message["isSynthetic"], json!(true));
        assert!(message.get("shouldQuery").is_none());
        assert!(text_of(&message).contains("Inline wakeup"));
    }
}
