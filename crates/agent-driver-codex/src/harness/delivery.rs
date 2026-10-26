//! Contract inputs and operations to Codex app-server requests (spec §4.2).
//!
//! | Delivery | Codex |
//! | --- | --- |
//! | Turn | `turn/start` |
//! | Steer | `turn/steer {expectedTurnId}` (now and next both map to it) |
//! | Queue | `thread/queue/add` |
//! | Passive | `additionalContext` on the next turn, or `thread/inject_items` |

use inline_agent_bridge::harness::{
    ChildKind, Delivery, GoalOp, Input, InputContent, Op, OpError, Origin, QueueOp, ReviewTarget,
    SettingsScope,
};
use inline_agent_bridge::{InputAttachmentKind, TurnId};
use serde_json::{Map, Value, json};

use super::mapper::client_message_id;

/// One app-server request.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Request {
    pub method: &'static str,
    pub params: Value,
}

/// The request that delivers an input. `active_turn` is the running turn the
/// session knows of; a steer naming another turn is a mismatch for the caller.
pub(crate) fn input_request(thread: &str, input: &Input) -> Request {
    let client_id = client_message_id(&input.id);
    match &input.delivery {
        Delivery::Turn => {
            let mut params = json!({
                "threadId": thread,
                "input": user_input(&input.content),
                "clientUserMessageId": client_id,
            });
            add_context(&mut params, &input.content, &input.origin);
            Request {
                method: "turn/start",
                params,
            }
        }
        Delivery::Steer { expected_turn, .. } => {
            let mut params = json!({
                "threadId": thread,
                "input": user_input(&input.content),
                "clientUserMessageId": client_id,
                "expectedTurnId": expected_turn.as_str(),
            });
            add_context(&mut params, &input.content, &input.origin);
            Request {
                method: "turn/steer",
                params,
            }
        }
        Delivery::Queue => Request {
            method: "thread/queue/add",
            params: json!({
                "threadId": thread,
                "input": user_input(&input.content),
                "clientUserMessageId": client_id,
            }),
        },
        Delivery::Passive => Request {
            method: "thread/inject_items",
            params: json!({
                "threadId": thread,
                "items": [passive_item(&input.content, &input.origin)],
            }),
        },
    }
}

/// Codex `UserInput` parts: text first, then local media.
fn user_input(content: &InputContent) -> Vec<Value> {
    let mut parts = Vec::new();
    if !content.text.is_empty() {
        parts.push(json!({"type": "text", "text": content.text}));
    }
    for attachment in &content.attachments {
        let local = attachment
            .local_uri
            .as_deref()
            .and_then(|uri| uri.strip_prefix("file://"));
        match (attachment.kind, local) {
            (InputAttachmentKind::Image, Some(path)) => {
                parts.push(json!({"type": "localImage", "path": path}));
            }
            (InputAttachmentKind::Audio, Some(path)) => {
                parts.push(json!({"type": "localAudio", "path": path}));
            }
            (InputAttachmentKind::Image, None) => {
                parts.push(json!({"type": "image", "url": attachment.uri}));
            }
            _ => {
                // Other media reach Codex as an untrusted local resource descriptor.
                let name = attachment.file_name.as_deref().unwrap_or("attachment");
                let location = local.unwrap_or(&attachment.uri);
                parts.push(json!({
                    "type": "text",
                    "text": format!("[Attached file: {name} at {location}]"),
                }));
            }
        }
    }
    parts
}

/// Bridge instructions are application context; conversation excerpts and
/// non-owner provenance are untrusted (spec §5.1 rule 1).
fn add_context(params: &mut Value, content: &InputContent, origin: &Origin) {
    let mut context = Map::new();
    if let Some(turn_context) = &content.context {
        if !turn_context.instructions.trim().is_empty() {
            context.insert(
                "inline.instructions".to_owned(),
                json!({"value": turn_context.instructions, "kind": "application"}),
            );
        }
        if !turn_context.conversation.trim().is_empty() {
            context.insert(
                "inline.conversation".to_owned(),
                json!({"value": turn_context.conversation, "kind": "untrusted"}),
            );
        }
    }
    if let Some(provenance) = provenance(origin) {
        context.insert(
            "inline.sender".to_owned(),
            json!({"value": provenance, "kind": "untrusted"}),
        );
    }
    if !context.is_empty() {
        params["additionalContext"] = Value::Object(context);
    }
}

fn provenance(origin: &Origin) -> Option<String> {
    match origin {
        Origin::Owner { .. } => None,
        Origin::Teammate { user } => Some(format!(
            "Sent by Inline user {} (a teammate, not the owner).",
            user.0
        )),
        Origin::Agent { bot, work } => Some(format!(
            "Sent by Inline agent {} from chat {}.",
            bot.0, work.chat.0
        )),
        Origin::Ambient { chat } => Some(format!(
            "Conversation in Inline chat {} that did not address you.",
            chat.0
        )),
        Origin::Scheduled => Some("Scheduled wakeup.".to_owned()),
    }
}

/// Passive context as one untrusted developer-visible message item.
fn passive_item(content: &InputContent, origin: &Origin) -> Value {
    let mut text = String::new();
    if let Some(provenance) = provenance(origin) {
        text.push_str(&provenance);
        text.push_str("\n\n");
    }
    text.push_str(&content.text);
    json!({
        "type": "message",
        "role": "user",
        "content": [{"type": "input_text", "text": text}],
    })
}

/// Turn facts an operation may need.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct TurnFacts<'a> {
    /// The running turn.
    pub active: Option<&'a TurnId>,
    /// The latest completed, failed or interrupted turn.
    pub last_finished: Option<&'a TurnId>,
}

/// The request for one operation, given the thread, its turns and its
/// effective model (Codex collaboration modes carry the model).
/// Why Codex offers no file undo.
pub(crate) const CODEX_NO_FILE_UNDO: &str =
    "Codex can revert conversation history but not files; undo file changes is not available";

pub(crate) fn op_request(
    thread: &str,
    turns: TurnFacts<'_>,
    model: Option<&str>,
    op: &Op,
) -> Result<Request, OpError> {
    let active_turn = turns.active;
    let thread_only = |method| Request {
        method,
        params: json!({"threadId": thread}),
    };
    Ok(match op {
        Op::Interrupt { .. } => {
            let turn =
                active_turn.ok_or_else(|| OpError::Rejected("no turn is running".to_owned()))?;
            Request {
                method: "turn/interrupt",
                params: json!({"threadId": thread, "turnId": turn.as_str()}),
            }
        }
        Op::Queue { action } => match action {
            QueueOp::Start => thread_only("thread/queue/start"),
            QueueOp::Remove { entry } => Request {
                method: "thread/queue/delete",
                params: json!({"threadId": thread, "queuedSubmissionId": entry.as_str()}),
            },
            QueueOp::Reorder { .. } | QueueOp::Clear => {
                // Both need the current queue; the session lists it first.
                return Err(OpError::Rejected(
                    "reorder and clear need the current queue".to_owned(),
                ));
            }
        },
        Op::Settings { change, scope } => {
            let mut params = Map::new();
            params.insert("threadId".to_owned(), json!(thread));
            if let Some(model) = &change.model {
                params.insert("model".to_owned(), json!(model));
            }
            if let Some(effort) = &change.effort {
                params.insert("effort".to_owned(), json!(effort));
            }
            if let Some(speed) = &change.speed {
                params.insert("serviceTier".to_owned(), json!(speed));
            }
            match scope {
                SettingsScope::Turn => {
                    let turn = active_turn
                        .ok_or_else(|| OpError::Rejected("no turn is running".to_owned()))?;
                    params.insert("turnId".to_owned(), json!(turn.as_str()));
                    Request {
                        method: "turn/settings/update",
                        params: Value::Object(params),
                    }
                }
                SettingsScope::Thread => {
                    if let Some(mode) = &change.permission_mode {
                        params.insert("permissions".to_owned(), json!(mode));
                    }
                    if let Some(folder) = &change.folder {
                        params.insert("cwd".to_owned(), json!(folder));
                    }
                    Request {
                        method: "thread/settings/update",
                        params: Value::Object(params),
                    }
                }
                SettingsScope::Persisted => {
                    let mut edits = Vec::new();
                    if let Some(model) = &change.model {
                        edits.push(
                            json!({"keyPath": "model", "value": model, "mergeStrategy": "replace"}),
                        );
                    }
                    if let Some(effort) = &change.effort {
                        edits.push(json!({"keyPath": "model_reasoning_effort", "value": effort, "mergeStrategy": "replace"}));
                    }
                    if let Some(speed) = &change.speed {
                        edits.push(json!({"keyPath": "service_tier", "value": speed, "mergeStrategy": "replace"}));
                    }
                    Request {
                        method: "config/batchWrite",
                        params: json!({"edits": edits}),
                    }
                }
            }
        }
        Op::Compact => thread_only("thread/compact/start"),
        Op::Rename { title } => Request {
            method: "thread/name/set",
            params: json!({"threadId": thread, "name": title}),
        },
        Op::Archive => thread_only("thread/archive"),
        Op::Unarchive => thread_only("thread/unarchive"),
        Op::Clear => {
            return Err(OpError::Unavailable(
                inline_agent_bridge::harness::Availability::unavailable(
                    "Codex has no clear; use /new for a fresh session",
                ),
            ));
        }
        // `thread/revert` removes conversation history and leaves files as
        // they are, so it is not a file undo.
        Op::RewindFiles { .. } => {
            return Err(OpError::Unavailable(
                inline_agent_bridge::harness::Availability::unavailable(CODEX_NO_FILE_UNDO),
            ));
        }
        Op::Mode { mode } => {
            let model = model.ok_or_else(|| {
                OpError::Rejected("the session's model is not known yet".to_owned())
            })?;
            Request {
                method: "thread/settings/update",
                params: json!({
                    "threadId": thread,
                    "collaborationMode": {"mode": mode.as_str(), "settings": {"model": model}},
                }),
            }
        }
        Op::Review { target } => Request {
            method: "review/start",
            params: json!({"threadId": thread, "target": review_target(target)}),
        },
        Op::Goal { action } => match action {
            GoalOp::Set { objective } => Request {
                method: "thread/goal/set",
                params: json!({"threadId": thread, "objective": objective, "origin": "user"}),
            },
            GoalOp::Clear => Request {
                method: "thread/goal/clear",
                params: json!({"threadId": thread, "origin": "user"}),
            },
        },
        // Background terminals stop by process ID through the parent thread.
        // Sub-agents are threads of their own with no qualified stop yet.
        Op::StopChild { child } => match child.kind {
            ChildKind::BackgroundTask => Request {
                method: "thread/backgroundTerminals/terminate",
                params: json!({"threadId": thread, "processId": child.id.as_str()}),
            },
            ChildKind::Subagent | ChildKind::Unknown => {
                return Err(OpError::Unavailable(
                    inline_agent_bridge::harness::Availability::unavailable(
                        "Codex sub-agents stop with their parent's turn",
                    ),
                ));
            }
        },
        // The sample reads the session as of its latest finished turn and is
        // rejected while a turn runs.
        Op::Sample { prompt } => {
            if active_turn.is_some() {
                return Err(OpError::Rejected("a turn is running".to_owned()));
            }
            let expected = turns.last_finished.ok_or_else(|| {
                OpError::Rejected("the session has no finished turn yet".to_owned())
            })?;
            Request {
                method: "thread/sample",
                params: json!({"threadId": thread, "prompt": prompt, "expectedTurnId": expected.as_str()}),
            }
        }
        Op::McpAuth { server } => Request {
            method: "mcpServer/oauth/login",
            params: json!({"name": server, "threadId": thread}),
        },
        Op::Answer { .. } => {
            return Err(OpError::InvalidResponse(
                "answers go through the mapper".to_owned(),
            ));
        }
    })
}

fn review_target(target: &ReviewTarget) -> Value {
    match target {
        ReviewTarget::UncommittedChanges => json!({"type": "uncommittedChanges"}),
        ReviewTarget::BaseBranch { branch } => json!({"type": "baseBranch", "branch": branch}),
        ReviewTarget::Commit { sha, title } => {
            let mut target = json!({"type": "commit", "sha": sha});
            if let Some(title) = title {
                target["title"] = json!(title);
            }
            target
        }
        ReviewTarget::Custom { instructions } => {
            json!({"type": "custom", "instructions": instructions})
        }
    }
}

#[cfg(test)]
mod tests {
    use inline_agent_bridge::harness::{ChatId, InputId, SteerPriority, UserId, WorkRef};
    use inline_agent_bridge::{InputAttachment, TurnContext};

    use super::*;

    fn input(delivery: Delivery, origin: Origin) -> Input {
        Input {
            id: InputId::new("in-1").expect("id"),
            content: InputContent::text("fix it"),
            origin,
            delivery,
        }
    }

    #[test]
    fn deliveries_map_to_the_codex_table() {
        let owner = Origin::Owner { user: UserId(1) };
        let turn = input_request("t1", &input(Delivery::Turn, owner.clone()));
        assert_eq!(turn.method, "turn/start");
        assert_eq!(
            turn.params,
            json!({
                "threadId": "t1",
                "input": [{"type": "text", "text": "fix it"}],
                "clientUserMessageId": "inline-agent-bridge:v2:in-1"
            })
        );
        let steer = input_request(
            "t1",
            &input(
                Delivery::Steer {
                    expected_turn: TurnId::new("turn-9").expect("turn"),
                    priority: SteerPriority::Now,
                },
                owner.clone(),
            ),
        );
        assert_eq!(steer.method, "turn/steer");
        assert_eq!(steer.params["expectedTurnId"], "turn-9");
        assert_eq!(
            input_request("t1", &input(Delivery::Queue, owner)).method,
            "thread/queue/add"
        );
        let passive = input_request(
            "t1",
            &input(Delivery::Passive, Origin::Ambient { chat: ChatId(5) }),
        );
        assert_eq!(passive.method, "thread/inject_items");
        assert!(
            passive.params["items"][0]["content"][0]["text"]
                .as_str()
                .expect("text")
                .starts_with("Conversation in Inline chat 5")
        );
    }

    #[test]
    fn non_owner_provenance_and_conversation_are_untrusted_context() {
        let mut agent = input(
            Delivery::Turn,
            Origin::Agent {
                bot: UserId(7),
                work: WorkRef {
                    chat: ChatId(3),
                    session: None,
                },
            },
        );
        agent.content.context = Some(TurnContext {
            instructions: "You are Mo's Codex in Inline.".to_owned(),
            conversation: "[alice] ship it".to_owned(),
        });
        let request = input_request("t1", &agent);
        let context = &request.params["additionalContext"];
        assert_eq!(context["inline.instructions"]["kind"], "application");
        assert_eq!(context["inline.conversation"]["kind"], "untrusted");
        assert_eq!(context["inline.sender"]["kind"], "untrusted");
    }

    #[test]
    fn local_media_stays_native() {
        let mut with_image = input(Delivery::Turn, Origin::Owner { user: UserId(1) });
        with_image.content.attachments = vec![InputAttachment {
            kind: InputAttachmentKind::Image,
            uri: "https://cdn.inline.chat/a.png".to_owned(),
            local_uri: Some("file:///tmp/inline/a.png".to_owned()),
            mime_type: Some("image/png".to_owned()),
            file_name: Some("a.png".to_owned()),
            size_bytes: Some(3),
            width: None,
            height: None,
            duration_ms: None,
        }];
        let request = input_request("t1", &with_image);
        assert_eq!(
            request.params["input"][1],
            json!({"type": "localImage", "path": "/tmp/inline/a.png"})
        );
    }

    #[test]
    fn ops_map_to_codex_methods_and_unsupported_ones_say_why() {
        let turn = TurnId::new("turn-1").expect("turn");
        let interrupt = op_request(
            "t1",
            TurnFacts {
                active: Some(&turn),
                last_finished: None,
            },
            None,
            &Op::Interrupt {
                cancel_queued: false,
            },
        )
        .expect("interrupt");
        assert_eq!(interrupt.method, "turn/interrupt");
        assert_eq!(interrupt.params["turnId"], "turn-1");
        assert!(
            op_request(
                "t1",
                TurnFacts {
                    active: None,
                    last_finished: None
                },
                None,
                &Op::Interrupt {
                    cancel_queued: false
                }
            )
            .is_err()
        );
        assert_eq!(
            op_request(
                "t1",
                TurnFacts {
                    active: None,
                    last_finished: None
                },
                None,
                &Op::Queue {
                    action: QueueOp::Start
                }
            )
            .expect("start")
            .method,
            "thread/queue/start"
        );
        assert!(matches!(
            op_request(
                "t1",
                TurnFacts {
                    active: None,
                    last_finished: None
                },
                None,
                &Op::Clear
            ),
            Err(OpError::Unavailable(_))
        ));
        let review = op_request(
            "t1",
            TurnFacts {
                active: None,
                last_finished: None,
            },
            None,
            &Op::Review {
                target: ReviewTarget::BaseBranch {
                    branch: "main".to_owned(),
                },
            },
        )
        .expect("review");
        assert_eq!(
            review.params["target"],
            json!({"type": "baseBranch", "branch": "main"})
        );
    }

    #[test]
    fn sample_names_the_finished_turn_and_undo_and_subagent_stop_say_why() {
        let finished = TurnId::new("turn-9").expect("turn");
        let sample = Op::Sample {
            prompt: "Should I speak?".to_owned(),
        };
        let request = op_request(
            "t1",
            TurnFacts {
                active: None,
                last_finished: Some(&finished),
            },
            None,
            &sample,
        )
        .expect("sample");
        assert_eq!(request.params["expectedTurnId"], "turn-9");
        assert!(matches!(
            op_request("t1", TurnFacts::default(), None, &sample),
            Err(OpError::Rejected(_))
        ));
        assert!(matches!(
            op_request(
                "t1",
                TurnFacts {
                    active: Some(&finished),
                    last_finished: Some(&finished),
                },
                None,
                &sample
            ),
            Err(OpError::Rejected(_))
        ));
        let rewind = Op::RewindFiles {
            to: inline_agent_bridge::harness::RewindPoint::Turn {
                turn: finished.clone(),
            },
        };
        assert!(matches!(
            op_request("t1", TurnFacts::default(), None, &rewind),
            Err(OpError::Unavailable(_))
        ));
        let child = |kind| Op::StopChild {
            child: inline_agent_bridge::harness::ChildRef {
                id: inline_agent_bridge::harness::ChildId::new("c1").expect("child"),
                kind,
            },
        };
        assert_eq!(
            op_request(
                "t1",
                TurnFacts::default(),
                None,
                &child(ChildKind::BackgroundTask)
            )
            .expect("terminal")
            .method,
            "thread/backgroundTerminals/terminate"
        );
        assert!(matches!(
            op_request(
                "t1",
                TurnFacts::default(),
                None,
                &child(ChildKind::Subagent)
            ),
            Err(OpError::Unavailable(_))
        ));
    }
}
