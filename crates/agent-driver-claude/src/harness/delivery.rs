//! Contract inputs and operations to Claude Code's stdin frames.
//!
//! | Delivery | Claude |
//! | --- | --- |
//! | `Turn` | user message |
//! | `Steer` | `priority: now` / `next` |
//! | `Queue` | `priority: later` |
//! | `Passive` | `shouldQuery: false` |
//!
//! Provenance (spec §5.1 rule 1): owner → `human`, teammate and ambient
//! conversation → `channel{inline}`, another agent → `peer`.

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

/// The `channel` server name Inline input carries.
pub const INLINE_CHANNEL: &str = "inline";

/// Largest attachment inlined as a content block; larger media are described.
const MAX_INLINE_ATTACHMENT_BYTES: u64 = 20 * 1024 * 1024;

/// The stdin user message for one input. The input id is the message uuid,
/// so `command_lifecycle`, interrupt receipts and `user_message_uuids` name
/// it directly.
pub fn user_message(session_id: &str, input: &Input) -> UserMessage {
    let mut message = UserMessage::new(UserContent::Blocks(content_blocks(input)))
        .with_uuid(input.id.as_str())
        .with_origin(origin(&input.origin));
    message.session_id = session_id.to_string();
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
    message
}

pub fn origin(origin: &ContractOrigin) -> Origin {
    match origin {
        ContractOrigin::Owner { .. } => Origin::Human,
        ContractOrigin::Teammate { .. } | ContractOrigin::Ambient { .. } => Origin::Channel {
            server: INLINE_CHANNEL.into(),
        },
        ContractOrigin::Agent { bot, work } => Origin::Peer {
            from: format!("inline:user:{}", bot.0),
            name: None,
            from_session: Some(format!("inline:chat:{}", work.chat.0)),
        },
        ContractOrigin::Scheduled => Origin::TaskNotification {
            subkind: Some("scheduled-trigger".into()),
        },
    }
}

fn content_blocks(input: &Input) -> Vec<Value> {
    let mut blocks = Vec::new();
    if let Some(context) = &input.content.context {
        if !context.conversation.trim().is_empty() {
            blocks.push(UserContent::text_block(&format!(
                "<inline-context untrusted=\"true\">\n{}\n</inline-context>",
                context.conversation
            )));
        }
    }
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
    blocks.push(UserContent::text_block(&input.content.text));
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

    #[test]
    fn steer_and_queue_set_native_priorities() {
        let input = Input {
            id: InputId::new("0d6a7c1e-1111-4a00-8000-000000000006").unwrap(),
            content: InputContent::text("Then write the changelog"),
            origin: ContractOrigin::Owner { user: UserId(1) },
            delivery: Delivery::Queue,
        };
        let value = user_message("s", &input).to_value();
        assert_eq!(value["priority"], json!("later"));
        assert_eq!(value["origin"], json!({"kind": "human"}));
        assert_eq!(value["uuid"], json!("0d6a7c1e-1111-4a00-8000-000000000006"));
    }

    #[test]
    fn agents_are_peers_with_their_work() {
        let origin = origin(&ContractOrigin::Agent {
            bot: UserId(303),
            work: WorkRef {
                chat: ChatId(9001),
                session: None,
            },
        });
        assert_eq!(
            origin.to_value(),
            json!({"kind": "peer", "from": "inline:user:303", "fromSession": "inline:chat:9001"})
        );
    }
}
