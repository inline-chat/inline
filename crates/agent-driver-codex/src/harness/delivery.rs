//! Contract inputs and operations to Codex app-server requests (spec §4.2).
//!
//! | Delivery | Codex |
//! | --- | --- |
//! | Turn | `turn/start` |
//! | Steer | `turn/steer {expectedTurnId}` (now and next both map to it) |
//! | Queue | `thread/inject_items` (Inline's note), then `thread/queue/add` |
//! | Passive | `thread/inject_items` (untrusted context) |

use inline_agent_bridge::harness::{
    ChildKind, Delivery, ForkPoint, GoalOp, Input, InputContent, Op, OpError, OpenMode, OpenSpec,
    QueueOp, ReviewTarget, SettingsScope,
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

/// The request that starts, resumes or forks a thread. `dynamic_tools` are
/// Inline's tools, offered to a new thread.
pub(crate) fn open_request(spec: &OpenSpec, dynamic_tools: Option<Value>) -> Request {
    let mut config = crate::driver::inline_thread_config();
    // `thread/start` and `thread/resume` take no effort of their own.
    if let Some(effort) = &spec.settings.effort {
        config.insert("model_reasoning_effort".to_owned(), json!(effort));
    }
    let mut params = json!({
        "cwd": spec.folder,
        "config": config,
    });
    if let Some(model) = &spec.settings.model {
        params["model"] = json!(model);
    }
    if let Some(permissions) = &spec.settings.permission_mode {
        params["permissions"] = json!(permissions);
    }
    if let Some(speed) = &spec.settings.speed {
        params["serviceTier"] = json!(speed);
    }
    if let Some(instructions) = &spec.instructions {
        params["developerInstructions"] = json!(instructions);
    }
    let method = match &spec.mode {
        OpenMode::Start => {
            if let Some(tools) = dynamic_tools {
                params["dynamicTools"] = tools;
            }
            "thread/start"
        }
        OpenMode::Resume { session } => {
            params["threadId"] = json!(session.as_str());
            "thread/resume"
        }
        OpenMode::Fork { session, at } => {
            params["threadId"] = json!(session.as_str());
            if let Some(ForkPoint::Turn { turn }) = at {
                params["lastTurnId"] = json!(turn.as_str());
            }
            "thread/fork"
        }
    };
    Request { method, params }
}

/// The requests that deliver an input: Inline's hidden note for a queued
/// input (the queue takes no `additionalContext`), then the input itself.
pub(crate) fn input_request(thread: &str, input: &Input) -> (Option<Request>, Request) {
    let client_id = client_message_id(&input.id);
    match &input.delivery {
        Delivery::Turn => {
            let mut params = json!({
                "threadId": thread,
                "input": user_input(&input.content),
                "clientUserMessageId": client_id,
            });
            add_context(&mut params, input);
            (
                None,
                Request {
                    method: "turn/start",
                    params,
                },
            )
        }
        Delivery::Steer { expected_turn, .. } => {
            let mut params = json!({
                "threadId": thread,
                "input": user_input(&input.content),
                "clientUserMessageId": client_id,
                "expectedTurnId": expected_turn.as_str(),
            });
            add_context(&mut params, input);
            (
                None,
                Request {
                    method: "turn/steer",
                    params,
                },
            )
        }
        // Who sent it and the thread around it go ahead of it as hidden
        // items, so the queued text stays what the person typed.
        Delivery::Queue => (
            Some(Request {
                method: "thread/inject_items",
                params: json!({"threadId": thread, "items": note_items(input)}),
            }),
            Request {
                method: "thread/queue/add",
                params: json!({
                    "threadId": thread,
                    "input": user_input(&input.content),
                    "clientUserMessageId": client_id,
                }),
            },
        ),
        Delivery::Passive => (
            None,
            Request {
                method: "thread/inject_items",
                params: json!({
                    "threadId": thread,
                    "items": [passive_item(input)],
                }),
            },
        ),
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

/// Bridge instructions and Inline's note on the sender are application
/// context (developer messages Codex's own clients never show); conversation
/// excerpts are untrusted (spec §5.1 rule 1). `inline.message` is sent for
/// every sender: its value names the message, so it changes every input and
/// no earlier sender lingers.
fn add_context(params: &mut Value, input: &Input) {
    let mut context = Map::new();
    context.insert(
        "inline.message".to_owned(),
        json!({"value": input.sender_note(), "kind": "application"}),
    );
    if let Some(turn_context) = &input.content.context {
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
    params["additionalContext"] = Value::Object(context);
}

/// Inline's note on a queued input as injected items: the sender as a
/// developer message, the thread around it as untrusted context.
fn note_items(input: &Input) -> Vec<Value> {
    let mut items = vec![json!({
        "type": "message",
        "role": "developer",
        "content": [{"type": "input_text", "text": input.sender_note()}],
    })];
    if let Some(conversation) = input
        .content
        .context
        .as_ref()
        .map(|context| context.conversation.trim())
        .filter(|conversation| !conversation.is_empty())
    {
        items.push(untrusted_item(conversation));
    }
    items
}

/// Passive context: one message item marked as untrusted thread context, so
/// the model never reads it as the owner's words.
fn passive_item(input: &Input) -> Value {
    untrusted_item(&format!(
        "{}\n\n{}",
        input.sender_note(),
        input.content.text
    ))
}

fn untrusted_item(text: &str) -> Value {
    json!({
        "type": "message",
        "role": "user",
        "content": [{"type": "input_text",
            "text": format!("<inline-context untrusted=\"true\">\n{text}\n</inline-context>")}],
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
    use inline_agent_bridge::harness::{ChatId, InputId, Origin, SteerPriority, UserId, WorkRef};
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
        let (note, turn) = input_request("t1", &input(Delivery::Turn, owner.clone()));
        assert!(note.is_none());
        assert_eq!(turn.method, "turn/start");
        assert_eq!(
            turn.params,
            json!({
                "threadId": "t1",
                "input": [{"type": "text", "text": "fix it"}],
                "clientUserMessageId": "inline-agent-bridge:v2:in-1",
                "additionalContext": {"inline.message": {
                    "value": "<inline-message from_user_id=\"1\" role=\"owner\"/>",
                    "kind": "application"
                }}
            })
        );
        let (_, steer) = input_request(
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
        let (note, queued) = input_request("t1", &input(Delivery::Queue, owner));
        assert_eq!(note.expect("note").method, "thread/inject_items");
        assert_eq!(queued.method, "thread/queue/add");
        let (_, passive) = input_request(
            "t1",
            &input(Delivery::Passive, Origin::Ambient { chat: ChatId(5) }),
        );
        assert_eq!(passive.method, "thread/inject_items");
        assert!(
            passive.params["items"][0]["content"][0]["text"]
                .as_str()
                .expect("text")
                .starts_with("<inline-context untrusted=\"true\">\nConversation in Inline chat 5")
        );
        assert_eq!(passive.params["items"][0]["role"], "user");
    }

    #[test]
    fn the_sender_is_application_context_and_the_conversation_untrusted() {
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
        let (_, request) = input_request("t1", &agent);
        let context = &request.params["additionalContext"];
        assert_eq!(context["inline.instructions"]["kind"], "application");
        assert_eq!(context["inline.conversation"]["kind"], "untrusted");
        assert_eq!(context["inline.message"]["kind"], "application");
        assert_eq!(
            context["inline.message"]["value"],
            "<inline-message chat_id=\"3\" from_user_id=\"7\" role=\"agent\"/>"
        );
        assert!(context.get("inline.sender").is_none());
        assert_eq!(
            request.params["input"],
            json!([{"type": "text", "text": "fix it"}])
        );
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
        let (_, request) = input_request("t1", &with_image);
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

    /// Every parameter the driver sends must exist in the installed Codex's
    /// protocol. Codex ignores unknown ones, so a renamed or missing field
    /// fails silently (the reasoning effort did, on `thread/start`). Methods
    /// a version lacks are the manifest's business and are skipped here.
    /// Harness compatibility CI runs it against each Codex version with
    /// `INLINE_CODEX_SCHEMA_DIR` set to `codex app-server
    /// generate-json-schema --experimental --out <dir>`.
    #[test]
    #[ignore = "needs INLINE_CODEX_SCHEMA_DIR"]
    fn request_params_exist_in_the_installed_schema() {
        use inline_agent_bridge::ProviderSessionId;
        use inline_agent_bridge::harness::{ModeId, OutputMode, SettingsChange};

        let dir = std::env::var("INLINE_CODEX_SCHEMA_DIR").expect("INLINE_CODEX_SCHEMA_DIR");
        let schema: Value = serde_json::from_str(
            &std::fs::read_to_string(std::path::Path::new(&dir).join("ClientRequest.json"))
                .expect("ClientRequest.json"),
        )
        .expect("schema");
        let definitions = &schema["definitions"];
        // Property names of a definition, through `$ref`, `allOf` and `anyOf`.
        fn properties(definition: &Value, definitions: &Value, out: &mut Vec<String>) {
            if let Some(reference) = definition["$ref"].as_str()
                && let Some(name) = reference.rsplit('/').next()
            {
                properties(&definitions[name], definitions, out);
            }
            if let Some(map) = definition["properties"].as_object() {
                out.extend(map.keys().cloned());
            }
            for key in ["allOf", "anyOf", "oneOf"] {
                for part in definition[key].as_array().into_iter().flatten() {
                    properties(part, definitions, out);
                }
            }
        }
        let accepted = |method: &str| -> Option<Vec<String>> {
            let variant = schema["oneOf"].as_array()?.iter().find(|variant| {
                variant
                    .pointer("/properties/method/enum/0")
                    .and_then(Value::as_str)
                    == Some(method)
            })?;
            let mut out = Vec::new();
            properties(&variant["properties"]["params"], definitions, &mut out);
            Some(out)
        };

        let settings = SettingsChange {
            model: Some("gpt-5".to_owned()),
            effort: Some("low".to_owned()),
            speed: Some("fast".to_owned()),
            permission_mode: Some("default".to_owned()),
            folder: Some("/tmp/project".into()),
        };
        let spec = |mode| OpenSpec {
            mode,
            folder: "/tmp/project".into(),
            settings: settings.clone(),
            instructions: Some("guide".to_owned()),
            title: None,
            after: None,
            output_mode: OutputMode::Detailed,
        };
        let session = ProviderSessionId::new("thread-1").expect("id");
        let turn = TurnId::new("turn-1").expect("id");
        let mut requests = vec![
            open_request(&spec(OpenMode::Start), Some(json!([]))),
            open_request(
                &spec(OpenMode::Resume {
                    session: session.clone(),
                }),
                None,
            ),
            open_request(
                &spec(OpenMode::Fork {
                    session,
                    at: Some(ForkPoint::Turn { turn: turn.clone() }),
                }),
                None,
            ),
        ];
        // A teammate's input with context: provenance and both context kinds.
        let origin = Origin::Teammate { user: UserId(2) };
        for delivery in [
            Delivery::Turn,
            Delivery::Steer {
                expected_turn: turn.clone(),
                priority: SteerPriority::Next,
            },
            Delivery::Queue,
            Delivery::Passive,
        ] {
            let mut input = input(delivery, origin.clone());
            input.content.context = Some(TurnContext {
                instructions: "trusted".to_owned(),
                conversation: "untrusted".to_owned(),
            });
            let (note, request) = input_request("thread-1", &input);
            requests.extend(note);
            requests.push(request);
        }
        let running = TurnFacts {
            active: Some(&turn),
            last_finished: Some(&turn),
        };
        let idle = TurnFacts {
            active: None,
            last_finished: Some(&turn),
        };
        let ops = [
            (
                running,
                Op::Interrupt {
                    cancel_queued: false,
                },
            ),
            (
                running,
                Op::Queue {
                    action: QueueOp::Start,
                },
            ),
            (
                running,
                Op::Settings {
                    change: settings.clone(),
                    scope: SettingsScope::Thread,
                },
            ),
            (
                running,
                Op::Settings {
                    change: settings.clone(),
                    scope: SettingsScope::Turn,
                },
            ),
            (idle, Op::Compact),
            (
                idle,
                Op::Rename {
                    title: "Title".to_owned(),
                },
            ),
            (idle, Op::Archive),
            (idle, Op::Unarchive),
            (
                idle,
                Op::Mode {
                    mode: ModeId::new("plan").expect("id"),
                },
            ),
            (
                idle,
                Op::Goal {
                    action: GoalOp::Set {
                        objective: "ship".to_owned(),
                    },
                },
            ),
            (
                idle,
                Op::Goal {
                    action: GoalOp::Clear,
                },
            ),
            (
                idle,
                Op::Sample {
                    prompt: "speak?".to_owned(),
                },
            ),
        ];
        for (turns, op) in &ops {
            requests.push(op_request("thread-1", *turns, Some("gpt-5"), op).expect("request"));
        }

        // Optional fields newer than the floor, which the floor ignores
        // harmlessly. Tolerated only when CI checks the floor itself.
        const NEWER_THAN_FLOOR: &[(&str, &str)] = &[
            ("thread/goal/set", "origin"),
            ("thread/goal/clear", "origin"),
        ];
        let floor = std::env::var("INLINE_CODEX_SCHEMA_FLOOR").is_ok_and(|value| value == "true");
        let mut unknown = Vec::new();
        for request in &requests {
            let Some(accepted) = accepted(request.method) else {
                eprintln!(
                    "{} is not in this Codex; the manifest gates it",
                    request.method
                );
                continue;
            };
            for key in request
                .params
                .as_object()
                .into_iter()
                .flat_map(|params| params.keys())
            {
                let tolerated = floor && NEWER_THAN_FLOOR.contains(&(request.method, key.as_str()));
                if !accepted.contains(key) && !tolerated {
                    unknown.push(format!("{} {key}", request.method));
                }
            }
        }
        assert!(
            unknown.is_empty(),
            "parameters this Codex does not know (it would ignore them): {unknown:#?}"
        );
    }

    #[test]
    fn queued_input_keeps_its_text_and_sends_its_note_hidden_ahead() {
        let mut queued = input(Delivery::Queue, Origin::Teammate { user: UserId(2) });
        queued.content.context = Some(TurnContext {
            instructions: String::new(),
            conversation: "Ada: the build is red".to_owned(),
        });
        let (note, request) = input_request("t1", &queued);
        assert_eq!(
            request.params["input"],
            json!([{"type": "text", "text": "fix it"}])
        );
        let note = note.expect("note");
        let items = note.params["items"].as_array().unwrap();
        assert_eq!(items[0]["role"], "developer");
        assert!(
            items[0]["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("role=\"teammate\"")
        );
        assert_eq!(items[1]["role"], "user");
        assert!(
            items[1]["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("untrusted=\"true\">\nAda: the build is red")
        );
    }
}
