use inline_agent_bridge::harness::{FieldAnswer, TurnPhase};

use super::*;

const SESSION: &str = "ses_main";

fn durable(seq: u64, kind: &str, data: Value) -> Value {
    let mut data = data;
    if data.get("sessionID").is_none() {
        data["sessionID"] = json!(SESSION);
    }
    json!({
        "id": format!("evt_{seq}"),
        "created": 1_700_000_000_000u64 + seq * 1000,
        "type": kind,
        "durable": {"aggregateID": SESSION, "seq": seq, "version": 1},
        "data": data,
    })
}

fn volatile(kind: &str, data: Value) -> Value {
    let mut data = data;
    if data.get("sessionID").is_none() {
        data["sessionID"] = json!(SESSION);
    }
    json!({"id": "evt_v", "created": 1, "type": kind, "data": data})
}

fn mapper() -> Mapper {
    Mapper::new(SESSION, Some(PathBuf::from("/work/app")))
}

fn input(id: &str) -> InputId {
    InputId::new(id).unwrap()
}

fn enqueue(seq: u64, inbox: &str, text: &str, delivery: &str) -> Value {
    durable(
        seq,
        "session.inbox.enqueued",
        json!({"inboxID": inbox, "item": {"type": "user", "delivery": delivery, "payload": {"text": text}}}),
    )
}

#[test]
fn an_inline_prompt_names_its_turn_and_is_consumed_by_it() {
    let mut mapper = mapper();
    mapper.expect("msg_a", input("in-1"));
    assert!(
        mapper
            .apply(&enqueue(1, "msg_a", "fix the build", "steer"))
            .is_empty()
    );
    let started = mapper.apply(&durable(2, "session.execution.started", json!({})));
    assert_eq!(
        started,
        vec![Event::Turn {
            turn: TurnId::new("msg_a").unwrap(),
            phase: TurnPhase::Started { inputs: vec![] },
        }]
    );
    let delivered = mapper.apply(&durable(
        3,
        "session.inbox.delivered",
        json!({"inboxID": "msg_a"}),
    ));
    assert!(matches!(
        &delivered[0],
        Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Message { role: MessageRole::User, input: Some(id), .. }, .. }, .. }) if id.as_str() == "in-1"
    ));
    assert_eq!(
        delivered[1],
        Event::Input {
            id: input("in-1"),
            fact: InputFact::Consumed {
                turn: TurnId::new("msg_a").unwrap()
            }
        }
    );
    let ended = mapper.apply(&durable(9, "session.execution.succeeded", json!({})));
    assert_eq!(
        ended,
        vec![Event::Turn {
            turn: TurnId::new("msg_a").unwrap(),
            phase: TurnPhase::Completed {
                outcome: TurnOutcome::Completed,
                inputs_consumed: vec![input("in-1")],
                error: None,
                duration_ms: Some(7000),
            },
        }]
    );
    assert!(mapper.turn().is_none());
}

#[test]
fn a_terminal_prompt_correlates_through_metadata_and_shows_as_user_text() {
    let mut mapper = mapper();
    mapper.apply(&durable(
        1,
        "session.inbox.enqueued",
        json!({"inboxID": "msg_t", "item": {"type": "user", "delivery": "steer",
            "payload": {"text": "from the terminal", "metadata": {"inline.input": "in-9"}}}}),
    ));
    mapper.apply(&durable(2, "session.execution.started", json!({})));
    let delivered = mapper.apply(&durable(
        3,
        "session.inbox.delivered",
        json!({"inboxID": "msg_t"}),
    ));
    assert_eq!(delivered.len(), 2);
    let mut other = Mapper::new(SESSION, None);
    other.apply(&enqueue(1, "msg_x", "typed in the TUI", "steer"));
    other.apply(&durable(2, "session.execution.started", json!({})));
    let delivered = other.apply(&durable(
        3,
        "session.inbox.delivered",
        json!({"inboxID": "msg_x"}),
    ));
    // Uncorrelated: shown, with no input fact.
    assert_eq!(delivered.len(), 1);
    assert_eq!(other.turn().unwrap().as_str(), "msg_x");
}

#[test]
fn steers_and_queued_prompts_run_inside_the_same_execution() {
    let mut mapper = mapper();
    mapper.expect("msg_a", input("in-1"));
    mapper.apply(&enqueue(1, "msg_a", "first", "steer"));
    mapper.apply(&durable(2, "session.execution.started", json!({})));
    mapper.apply(&durable(
        3,
        "session.inbox.delivered",
        json!({"inboxID": "msg_a"}),
    ));
    mapper.expect("msg_q", input("in-q"));
    let queued = mapper.apply(&enqueue(4, "msg_q", "then this", "queue"));
    assert!(
        matches!(&queued[0], Event::Queue { entries } if entries.len() == 1 && entries[0].input.as_ref().unwrap().as_str() == "in-q")
    );
    assert_eq!(mapper.queue()[0].preview, "then this");
    mapper.expect("msg_s", input("in-s"));
    assert!(
        mapper
            .apply(&enqueue(5, "msg_s", "also check docs", "steer"))
            .is_empty()
    );
    let steered = mapper.apply(&durable(
        6,
        "session.inbox.delivered",
        json!({"inboxID": "msg_s"}),
    ));
    assert!(steered.contains(&Event::Input {
        id: input("in-s"),
        fact: InputFact::Consumed {
            turn: TurnId::new("msg_a").unwrap()
        }
    }));
    let drained = mapper.apply(&durable(
        7,
        "session.inbox.delivered",
        json!({"inboxID": "msg_q"}),
    ));
    assert!(matches!(drained.last(), Some(Event::Queue { entries }) if entries.is_empty()));
    let ended = mapper.apply(&durable(8, "session.execution.succeeded", json!({})));
    assert!(matches!(
        &ended[0],
        Event::Turn { phase: TurnPhase::Completed { inputs_consumed, .. }, .. } if inputs_consumed.len() == 3
    ));
}

#[test]
fn cancelled_inbox_entries_report_their_inputs() {
    let mut mapper = mapper();
    mapper.apply(&durable(1, "session.execution.started", json!({})));
    mapper.expect("msg_q", input("in-q"));
    mapper.apply(&enqueue(2, "msg_q", "later", "queue"));
    let cancelled = mapper.apply(&durable(
        3,
        "session.inbox.cancelled",
        json!({"inboxID": "msg_q"}),
    ));
    assert_eq!(
        cancelled[0],
        Event::Input {
            id: input("in-q"),
            fact: InputFact::Cancelled
        }
    );
    assert!(mapper.queue().is_empty());
}

#[test]
fn text_streams_then_completes_and_late_deltas_are_dropped() {
    let mut mapper = mapper();
    mapper.apply(&durable(1, "session.execution.started", json!({})));
    let part = json!({"assistantMessageID": "msg_r", "ordinal": 0});
    let started = mapper.apply(&durable(2, "session.text.started", part.clone()));
    assert!(matches!(
        &started[0],
        Event::Item(Item {
            update: ItemUpdate::Started { .. },
            ..
        })
    ));
    let mut delta = part.clone();
    delta["delta"] = json!("Hel");
    let streamed = mapper.apply(&volatile("session.text.delta", delta.clone()));
    assert!(
        matches!(&streamed[0], Event::Item(Item { id, kind: ItemKind::Message, update: ItemUpdate::Delta { .. }, .. }) if id.as_str() == "msg_r:text:0")
    );
    let mut ended = part.clone();
    ended["text"] = json!("Hello");
    let completed = mapper.apply(&durable(3, "session.text.ended", ended));
    assert!(
        matches!(&completed[0], Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Message { text, .. }, .. }, .. }) if text == "Hello")
    );
    assert!(
        mapper
            .apply(&volatile("session.text.delta", delta))
            .is_empty()
    );
}

#[test]
fn reasoning_keeps_its_text() {
    let mut mapper = mapper();
    let part = json!({"assistantMessageID": "msg_r", "ordinal": 1, "delta": "think", "text": "thinking it through"});
    let delta = mapper.apply(&volatile("session.reasoning.delta", part.clone()));
    assert!(
        matches!(&delta[0], Event::Item(Item { kind: ItemKind::Reasoning, update: ItemUpdate::Delta { delta }, .. }) if delta.stream == DeltaStream::ReasoningContent)
    );
    let ended = mapper.apply(&durable(1, "session.reasoning.ended", part));
    assert!(
        matches!(&ended[0], Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Reasoning { content, .. }, .. }, .. }) if content == &vec!["thinking it through".to_owned()])
    );
}

#[test]
fn replayed_durable_events_are_skipped() {
    let mut mapper = mapper();
    mapper.apply(&durable(5, "session.execution.started", json!({})));
    assert!(
        mapper
            .apply(&durable(5, "session.execution.started", json!({})))
            .is_empty()
    );
    assert!(
        mapper
            .apply(&durable(3, "session.execution.succeeded", json!({})))
            .is_empty()
    );
    assert_eq!(mapper.last_seq(), Some(5));
}

#[test]
fn shell_calls_become_commands_with_output_and_exit() {
    let mut mapper = mapper();
    mapper.apply(&durable(1, "session.execution.started", json!({})));
    let base = json!({"assistantMessageID": "msg_r", "id": "call_1"});
    let mut started = base.clone();
    started["name"] = json!("shell");
    mapper.apply(&durable(2, "session.tool.input.started", started));
    let mut called = base.clone();
    called["input"] = json!({"command": "cargo test", "workdir": "/work/app"});
    called["executed"] = json!(true);
    let updated = mapper.apply(&durable(3, "session.tool.called", called));
    assert!(
        matches!(&updated[0], Event::Item(Item { update: ItemUpdate::Updated { body: ItemBody::Command { command, .. } }, .. }) if command == "cargo test")
    );
    let mut success = base.clone();
    success["content"] = json!([{"type": "text", "text": "ok: 12 passed"}]);
    success["metadata"] = json!({"status": "completed", "exit": 0, "truncated": false});
    success["executed"] = json!(true);
    let done = mapper.apply(&durable(4, "session.tool.success", success));
    match &done[0] {
        Event::Item(Item {
            update:
                ItemUpdate::Completed {
                    body:
                        ItemBody::Command {
                            output,
                            exit_code,
                            cwd,
                            ..
                        },
                    status: ItemStatus::Completed,
                },
            ..
        }) => {
            assert_eq!(output.as_deref(), Some("ok: 12 passed"));
            assert_eq!(*exit_code, Some(0));
            assert_eq!(cwd.as_deref(), Some(std::path::Path::new("/work/app")));
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn edits_report_their_diffs_relative_to_the_folder() {
    let body = tool_body(
        "edit",
        &json!({"path": "/work/app/src/main.rs", "oldString": "a", "newString": "b"}),
        Some("Edited"),
        Some(
            &json!({"files": [{"file": "src/main.rs", "patch": "@@ -1 +1 @@\n-a\n+b", "additions": 1, "deletions": 1, "status": "modified"}]}),
        ),
        None,
        Some(&PathBuf::from("/work/app")),
    );
    match body {
        ItemBody::FileChange { changes } => {
            assert_eq!(changes[0].path, PathBuf::from("src/main.rs"));
            assert!(changes[0].diff.as_deref().unwrap().contains("+b"));
        }
        other => panic!("{other:?}"),
    }
    let written = tool_body(
        "write",
        &json!({"path": "/work/app/NEW.md", "content": "hi"}),
        None,
        None,
        None,
        Some(&PathBuf::from("/work/app")),
    );
    assert!(
        matches!(written, ItemBody::FileChange { changes } if changes[0].change == FileChangeKind::Add && changes[0].path == std::path::Path::new("NEW.md"))
    );
}

#[test]
fn todos_become_a_plan_and_subagents_a_child() {
    let plan = tool_body(
        "todowrite",
        &json!({"todos": [{"content": "Read code", "status": "completed"}, {"content": "Fix", "status": "in_progress"}]}),
        None,
        None,
        None,
        None,
    );
    assert!(
        matches!(plan, ItemBody::Plan { steps, .. } if steps.len() == 2 && steps[1].status == PlanStepStatus::InProgress)
    );
    let child = tool_body(
        "subagent",
        &json!({"agent": "explore", "description": "Map the auth code", "prompt": "..."}),
        None,
        Some(&json!({"sessionID": "ses_child", "status": "running"})),
        None,
        None,
    );
    assert!(
        matches!(child, ItemBody::Child { child, action, .. } if child.id.as_str() == "ses_child" && action.as_deref() == Some("explore"))
    );
    let mcp = tool_body(
        "inline_send_message",
        &json!({"text": "hi"}),
        None,
        None,
        None,
        None,
    );
    assert!(
        matches!(mcp, ItemBody::Tool { name, server, .. } if name == "send_message" && server.as_deref() == Some("inline"))
    );
}

#[test]
fn subagent_sessions_show_as_child_work() {
    let mut mapper = mapper();
    mapper.apply(&durable(1, "session.execution.started", json!({})));
    let created = mapper.apply(&json!({
        "type": "session.created",
        "durable": {"aggregateID": "ses_child", "seq": 1, "version": 1},
        "data": {"sessionID": "ses_child", "parentID": SESSION, "title": "Map the auth code"}
    }));
    assert!(
        matches!(&created[0], Event::Child { update } if update.status == ChildStatus::Started && update.title.as_deref() == Some("Map the auth code"))
    );
    assert!(mapper.child_session_known("ses_child"));
    let running = mapper
        .apply(&json!({"type": "session.execution.started", "data": {"sessionID": "ses_child"}}));
    assert!(
        matches!(&running[0], Event::Child { update } if update.status == ChildStatus::Running)
    );
    assert_eq!(mapper.running_children().len(), 1);
    let tool = mapper.apply(&json!({"type": "session.tool.input.started", "data": {"sessionID": "ses_child", "assistantMessageID": "msg_c", "id": "call_c", "name": "read"}}));
    assert!(
        matches!(&tool[0], Event::Item(Item { parent: Some(parent), .. }) if parent.id.as_str() == "ses_child")
    );
    // The parent's durable sequence is untouched by the child's.
    assert_eq!(mapper.last_seq(), Some(1));
    let done = mapper
        .apply(&json!({"type": "session.execution.succeeded", "data": {"sessionID": "ses_child"}}));
    // The child's still-open read closes first, then the child ends.
    assert!(matches!(
        &done[0],
        Event::Item(Item {
            update: ItemUpdate::Completed {
                status: ItemStatus::Interrupted,
                ..
            },
            ..
        })
    ));
    assert!(
        matches!(done.last(), Some(Event::Child { update }) if update.status == ChildStatus::Completed)
    );
    assert!(mapper.running_children().is_empty());
}

#[test]
fn permissions_become_approvals_with_opencode_decisions() {
    let mut mapper = mapper();
    mapper.apply(&durable(1, "session.execution.started", json!({})));
    let asked = mapper.apply(&volatile(
        "permission.asked",
        json!({"id": "per_1", "action": "shell", "resources": ["git push"], "save": ["git push *"],
               "source": {"type": "tool", "messageID": "msg_r", "id": "call_9"}}),
    ));
    match &asked[0] {
        Event::Interaction(Interaction {
            id,
            item,
            kind: InteractionKind::Approval { subject, decisions },
            ..
        }) => {
            assert_eq!(id.as_str(), "per_1");
            assert_eq!(item.as_ref().unwrap().as_str(), "call_9");
            assert!(
                matches!(subject, ApprovalSubject::Command { command, .. } if command == "git push")
            );
            let ids: Vec<&str> = decisions
                .iter()
                .map(|decision| decision.id.as_str())
                .collect();
            assert_eq!(ids, vec!["once", "always", "reject", "stop"]);
            assert!(
                decisions[1]
                    .description
                    .as_deref()
                    .unwrap()
                    .contains("git push *")
            );
            assert!(decisions[2].accepts_message);
        }
        other => panic!("{other:?}"),
    }
    assert!(mapper.is_pending("per_1"));
    // A repeat (resync) does not ask twice.
    assert!(
        mapper
            .apply(&volatile(
                "permission.asked",
                json!({"id": "per_1", "action": "shell", "resources": []})
            ))
            .is_empty()
    );
    let replied = mapper.apply(&volatile(
        "permission.replied",
        json!({"requestID": "per_1", "reply": "once"}),
    ));
    assert!(matches!(
        &replied[0],
        Event::InteractionClosed {
            by: ClosedBy::External,
            ..
        }
    ));
}

#[test]
fn interrupted_turns_close_their_open_work() {
    let mut mapper = mapper();
    mapper.apply(&durable(1, "session.execution.started", json!({})));
    mapper.apply(&durable(
        2,
        "session.tool.input.started",
        json!({"assistantMessageID": "m", "id": "call_1", "name": "shell"}),
    ));
    mapper.apply(&volatile(
        "permission.asked",
        json!({"id": "per_1", "action": "shell", "resources": ["rm -rf build"]}),
    ));
    mapper.stopping();
    let ended = mapper.apply(&durable(
        3,
        "session.execution.interrupted",
        json!({"reason": "shutdown"}),
    ));
    assert!(matches!(
        &ended[0],
        Event::Item(Item {
            update: ItemUpdate::Completed {
                status: ItemStatus::Interrupted,
                ..
            },
            ..
        })
    ));
    assert!(matches!(
        &ended[1],
        Event::InteractionClosed {
            by: ClosedBy::Cancelled,
            ..
        }
    ));
    assert!(matches!(
        &ended[2],
        Event::Turn {
            phase: TurnPhase::Completed {
                outcome: TurnOutcome::Interrupted,
                error: None,
                ..
            },
            ..
        }
    ));
    // Unrequested, the reason is shown.
    mapper.apply(&durable(4, "session.execution.started", json!({})));
    let ended = mapper.apply(&durable(
        5,
        "session.execution.interrupted",
        json!({"reason": "inactivity"}),
    ));
    assert!(matches!(
        &ended[0],
        Event::Turn {
            phase: TurnPhase::Completed { error: Some(_), .. },
            ..
        }
    ));
}

#[test]
fn failures_and_retries_are_reported() {
    let mut mapper = mapper();
    mapper.apply(&durable(1, "session.execution.started", json!({})));
    let retry = mapper.apply(&durable(
        2,
        "session.retry.scheduled",
        json!({
            "assistantMessageID": "m", "attempt": 2, "at": 1_800_000_000_000i64,
            "error": {"type": "RateLimitError", "message": "Too many requests", "status": 429}
        }),
    ));
    assert!(matches!(
        &retry[1],
        Event::State {
            state: RunState::Waiting {
                on: WaitingOn::Limit {
                    resets_at: Some(1_800_000_000)
                }
            }
        }
    ));
    let resumed = mapper.apply(&durable(3, "session.step.started", json!({"assistantMessageID": "m2", "agent": "build", "model": {"providerID": "p", "id": "m"}})));
    assert_eq!(
        resumed[0],
        Event::State {
            state: RunState::Working
        }
    );
    let failed = mapper.apply(&durable(
        4,
        "session.execution.failed",
        json!({"error": {"type": "ProviderError", "message": "context too long"}}),
    ));
    assert!(matches!(
        failed.last(),
        Some(Event::Turn { phase: TurnPhase::Completed { outcome: TurnOutcome::Failed, error: Some(error), .. }, .. }) if error == "context too long"
    ));
}

#[test]
fn usage_reports_steps_and_session_totals() {
    let mut mapper = mapper();
    mapper.set_context_window(Some(200_000));
    let step = mapper.apply(&durable(1, "session.step.ended", json!({
        "assistantMessageID": "m", "finish": "stop", "cost": 0.01,
        "tokens": {"input": 100, "output": 20, "reasoning": 5, "cache": {"read": 1000, "write": 0}}
    })));
    match &step[0] {
        Event::Usage { usage } => {
            let last = usage.last.unwrap();
            assert_eq!(
                (last.input, last.cached_input, last.output, last.total),
                (1100, 1000, 20, 1125)
            );
            assert_eq!(usage.context_window, Some(200_000));
        }
        other => panic!("{other:?}"),
    }
    let total = mapper.apply(&volatile("session.usage.updated", json!({"cost": 1, "tokens": {"input": 1, "output": 2, "reasoning": 0, "cache": {"read": 0, "write": 0}}})));
    assert!(matches!(&total[0], Event::Usage { usage } if usage.total.unwrap().total == 3));
}

#[test]
fn settings_follow_model_and_agent_changes() {
    let mut mapper = mapper();
    let model = mapper.apply(&durable(
        1,
        "session.model.selected",
        json!({"model": {"providerID": "anthropic", "id": "claude", "variant": "high"}}),
    ));
    assert!(
        matches!(&model[0], Event::Settings { effective } if effective.model.as_ref().unwrap().value == "anthropic/claude" && effective.effort.as_deref() == Some("high"))
    );
    let agent = mapper.apply(&durable(
        2,
        "session.agent.selected",
        json!({"agent": "plan"}),
    ));
    assert!(
        matches!(&agent[0], Event::Settings { effective } if effective.mode.as_deref() == Some("plan"))
    );
    let renamed = mapper.apply(&durable(3, "session.renamed", json!({"title": "Auth fix"})));
    assert_eq!(
        renamed,
        vec![Event::Renamed {
            title: "Auth fix".into()
        }]
    );
}

#[test]
fn question_forms_round_trip_typed_answers() {
    let mut mapper = mapper();
    let form = json!({
        "id": "frm_1", "sessionID": SESSION, "title": "Choose",
        "metadata": {"kind": "question"},
        "fields": [
            {"key": "q0", "type": "string", "title": "Database", "description": "Which database?",
             "options": [{"value": "pg", "label": "Postgres"}, {"value": "lite", "label": "SQLite"}], "custom": true},
            {"key": "q1", "type": "multiselect", "title": "Targets",
             "options": [{"value": "mac", "label": "macOS"}, {"value": "ios", "label": "iOS"}]},
            {"key": "q2", "type": "boolean", "title": "Migrate now?"},
            {"key": "q3", "type": "integer", "title": "Workers"}
        ]
    });
    let created = mapper.apply(&volatile("form.created", json!({"form": form.clone()})));
    match &created[0] {
        Event::Interaction(Interaction {
            kind: InteractionKind::Question { form },
            ..
        }) => {
            assert_eq!(form.fields.len(), 4);
            assert!(matches!(
                &form.fields[0].input,
                FieldInput::Select {
                    allow_other: true,
                    multiple: false,
                    ..
                }
            ));
            assert_eq!(form.fields[0].prompt, "Which database?");
            assert!(matches!(
                &form.fields[1].input,
                FieldInput::Select { multiple: true, .. }
            ));
        }
        other => panic!("{other:?}"),
    }
    let answer = |field: &str, values: &[&str]| FieldAnswer {
        field: FieldId::new(field).unwrap(),
        values: values.iter().map(|value| value.to_string()).collect(),
    };
    let answers = form_answer(
        &form["fields"],
        &[
            answer("q0", &["Postgres"]),
            answer("q1", &["macOS", "iOS"]),
            answer("q2", &["yes"]),
            answer("q3", &["4"]),
        ],
    )
    .unwrap();
    assert_eq!(
        answers,
        json!({"q0": "pg", "q1": ["mac", "ios"], "q2": true, "q3": 4})
    );
    assert!(form_answer(&form["fields"], &[answer("q3", &["many"])]).is_err());
    // A custom answer passes through as typed.
    assert_eq!(
        form_answer(&form["fields"], &[answer("q0", &["DuckDB"])]).unwrap()["q0"],
        "DuckDB"
    );
}

#[test]
fn forms_inline_cannot_render_stay_pending_as_dialogs() {
    let mut mapper = mapper();
    let created = mapper.apply(&volatile(
        "form.created",
        json!({"form": {"id": "frm_2", "sessionID": SESSION, "title": "Connect",
            "fields": [{"key": "auth", "type": "external", "url": "https://example.com/oauth"}]}}),
    ));
    assert!(matches!(
        &created[0],
        Event::Interaction(Interaction {
            kind: InteractionKind::Dialog { .. },
            ..
        })
    ));
    assert!(mapper.is_pending("frm_2"));
}

#[test]
fn unknown_events_are_kept_as_notices() {
    let mut mapper = mapper();
    let events = mapper.apply(&volatile("session.something.new", json!({})));
    assert!(
        matches!(&events[0], Event::Notice(Notice { code, .. }) if code == "session.something.new")
    );
}

#[test]
fn delivered_before_the_execution_is_known_joins_its_start() {
    let mut mapper = mapper();
    mapper.expect("msg_a", input("in-1"));
    mapper.apply(&enqueue(1, "msg_a", "go", "steer"));
    // Out of order across a resync: delivery seen first.
    mapper.apply(&durable(
        2,
        "session.inbox.delivered",
        json!({"inboxID": "msg_a"}),
    ));
    let started = mapper.apply(&durable(3, "session.execution.started", json!({})));
    assert!(
        matches!(&started[0], Event::Turn { phase: TurnPhase::Started { inputs }, .. } if inputs == &vec![input("in-1")])
    );
}

#[test]
fn seeded_inbox_restores_the_queue_on_resume() {
    let mut mapper = mapper();
    mapper.resume_turn(TurnId::new("msg_run").unwrap());
    let events = mapper.seed_inbox(&json!([
        {"id": "msg_q", "type": "user", "delivery": "queue", "payload": {"text": "after this", "metadata": {"inline.input": "in-q"}}}
    ]));
    assert!(
        matches!(&events[0], Event::Queue { entries } if entries.len() == 1 && entries[0].input.as_ref().unwrap().as_str() == "in-q")
    );
    assert_eq!(
        mapper.inbox_of(&input("in-q")).map(String::as_str),
        Some("msg_q")
    );
}

#[test]
fn an_answer_from_inline_keeps_its_attribution_when_opencode_announces_it_first() {
    let mut mapper = mapper();
    mapper.apply(&durable(1, "session.execution.started", json!({})));
    mapper.apply(&volatile(
        "permission.asked",
        json!({"id": "per_1", "action": "shell", "resources": ["ls"]}),
    ));
    mapper.answering("per_1", UserId(7), Some(DecisionId::new("once").unwrap()));
    let closed = mapper.apply(&volatile(
        "permission.replied",
        json!({"requestID": "per_1", "reply": "once"}),
    ));
    assert_eq!(
        closed,
        vec![Event::InteractionClosed {
            id: InteractionId::new("per_1").unwrap(),
            by: ClosedBy::Inline {
                user: UserId(7),
                decision: Some(DecisionId::new("once").unwrap()),
            },
        }]
    );
    // The request's own close then has nothing left to close.
    assert!(mapper.close("per_1", ClosedBy::External).is_none());
}

#[test]
fn synthetic_context_never_names_a_turn() {
    let mut mapper = mapper();
    mapper.apply(&durable(
        1,
        "session.inbox.enqueued",
        json!({"inboxID": "msg_ctx", "item": {"type": "synthetic", "delivery": "steer", "payload": {"text": "context"}}}),
    ));
    mapper.apply(&enqueue(2, "msg_user", "do it", "steer"));
    let started = mapper.apply(&durable(3, "session.execution.started", json!({})));
    assert!(matches!(&started[0], Event::Turn { turn, .. } if turn.as_str() == "msg_user"));
}

#[test]
fn commands_correlate_with_the_prompt_they_make_and_can_be_withdrawn() {
    let mut mapper = mapper();
    mapper.expect_command(input("in-cmd"));
    mapper.apply(&enqueue(1, "msg_cmd", "Create AGENTS.md", "steer"));
    assert_eq!(
        mapper.inbox_of(&input("in-cmd")).map(String::as_str),
        Some("msg_cmd")
    );
    // A withdrawn expectation never claims a later prompt from another client.
    mapper.expect_command(input("in-gone"));
    mapper.forget_command(&input("in-gone"));
    mapper.apply(&enqueue(2, "msg_tui", "from the terminal", "steer"));
    assert!(mapper.inbox_of(&input("in-gone")).is_none());
}

#[test]
fn resync_replays_after_the_floor_until_live_events_arrive() {
    let mut mapper = mapper();
    assert_eq!(mapper.replay_after(), None);
    mapper.set_floor(Some(40));
    assert_eq!(mapper.replay_after(), Some(40));
    mapper.apply(&durable(41, "session.renamed", json!({"title": "x"})));
    assert_eq!(mapper.replay_after(), Some(41));
}

#[test]
fn sub_agent_events_are_deduplicated_by_their_own_sequence() {
    let mut mapper = mapper();
    let child = |seq: u64| {
        json!({"type": "session.execution.started",
               "durable": {"aggregateID": "ses_child", "seq": seq, "version": 1},
               "data": {"sessionID": "ses_child"}})
    };
    assert!(mapper.adopt_child("ses_child", None, false));
    assert!(!mapper.adopt_child("ses_child", Some("Explore".into()), false));
    assert_eq!(mapper.apply(&child(3)).len(), 1);
    assert!(mapper.apply(&child(3)).is_empty());
    assert_eq!(mapper.child_seq("ses_child"), Some(3));
    assert!(mapper.last_seq().is_none());
    let idle = mapper.child_idle("ses_child");
    assert!(matches!(&idle[0], Event::Child { update } if update.status == ChildStatus::Completed));
    assert!(mapper.child_idle("ses_child").is_empty());
}

#[test]
fn restored_settings_allow_an_effort_only_change() {
    let mut mapper = mapper();
    mapper.set_settings(EffectiveSettings {
        model: Some(DriverSettingOption {
            value: "anthropic/sonnet".into(),
            label: "anthropic/sonnet".into(),
            description: None,
            disabled: false,
        }),
        ..Default::default()
    });
    assert_eq!(
        mapper.settings().model.as_ref().unwrap().value,
        "anthropic/sonnet"
    );
    let event = mapper.set_permission_mode("ask".into());
    assert!(
        matches!(event, Event::Settings { effective } if effective.permission_mode.as_deref() == Some("ask") && effective.model.is_some())
    );
}

#[test]
fn credential_questions_are_asked_as_secrets() {
    let form = json!({"id": "frm_s", "title": "Access", "fields": [
        {"key": "q0", "type": "string", "title": "GitHub", "description": "Paste a GitHub personal access token (PAT) with repo scope"},
        {"key": "q1", "type": "string", "title": "Branch", "description": "Which branch should I push to?"},
        {"key": "q2", "type": "string", "title": "API key for Stripe"}
    ]});
    let form = question_form(&form).unwrap();
    assert_eq!(form.fields[0].input, FieldInput::Secret);
    assert!(matches!(form.fields[1].input, FieldInput::Text { .. }));
    assert_eq!(form.fields[2].input, FieldInput::Secret);
}

#[test]
fn a_finished_sub_agent_leaves_no_tool_working() {
    let mut mapper = mapper();
    mapper.apply(&durable(1, "session.execution.started", json!({})));
    mapper.apply(&json!({"type": "session.created", "data": {"sessionID": "ses_child", "parentID": SESSION}}));
    mapper.apply(&json!({"type": "session.tool.input.started", "data": {"sessionID": "ses_child", "assistantMessageID": "m", "id": "call_c", "name": "shell"}}));
    mapper.apply(&json!({"type": "permission.asked", "data": {"id": "per_c", "sessionID": "ses_child", "action": "shell", "resources": ["ffmpeg"]}}));
    let ended = mapper.apply(&json!({"type": "session.execution.interrupted", "data": {"sessionID": "ses_child", "reason": "user"}}));
    assert!(ended.iter().any(|event| matches!(event, Event::Item(Item { id, parent: Some(_), update: ItemUpdate::Completed { status: ItemStatus::Interrupted, .. }, .. }) if id.as_str() == "call_c")));
    assert!(ended.iter().any(|event| matches!(
        event,
        Event::InteractionClosed {
            by: ClosedBy::Cancelled,
            ..
        }
    )));
    assert!(
        matches!(ended.last(), Some(Event::Child { update }) if update.status == ChildStatus::Stopped)
    );
    // A late success for the closed call does not reopen it.
    assert!(mapper.apply(&json!({"type": "session.tool.success", "data": {"sessionID": "ses_child", "assistantMessageID": "m", "id": "call_c", "content": [{"type": "text", "text": "x"}]}})).is_empty());
}

#[test]
fn tools_left_open_close_with_the_turn_whatever_turn_saw_them() {
    let mut mapper = mapper();
    // Seen before the execution was known (stream joined mid-turn).
    mapper.apply(&durable(
        1,
        "session.tool.input.started",
        json!({"assistantMessageID": "m", "id": "call_early", "name": "shell"}),
    ));
    mapper.apply(&durable(2, "session.execution.started", json!({})));
    let ended = mapper.apply(&durable(3, "session.execution.succeeded", json!({})));
    assert!(ended.iter().any(|event| matches!(event, Event::Item(Item { id, update: ItemUpdate::Completed { status: ItemStatus::Interrupted, .. }, .. }) if id.as_str() == "call_early")));
}

#[test]
fn a_background_shell_stays_live_work_until_its_notification() {
    let mut mapper = mapper();
    mapper.apply(&durable(1, "session.execution.started", json!({})));
    mapper.apply(&durable(
        2,
        "session.tool.input.started",
        json!({"assistantMessageID": "m", "id": "call_bg", "name": "shell"}),
    ));
    mapper.apply(&durable(3, "session.tool.called", json!({"assistantMessageID": "m", "id": "call_bg", "input": {"command": "ffmpeg -i in.mov out.mp4", "background": true}, "executed": true})));
    let moved = mapper.apply(&durable(4, "session.tool.success", json!({"assistantMessageID": "m", "id": "call_bg",
        "content": [{"type": "text", "text": "Command moved to the background (shell ID: sh_1)."}],
        "metadata": {"status": "running", "shellID": "sh_1", "truncated": false}, "executed": true})));
    assert!(
        matches!(moved.last(), Some(Event::Child { update }) if update.child.kind == ChildKind::BackgroundTask
        && update.status == ChildStatus::Running && update.title.as_deref() == Some("ffmpeg -i in.mov out.mp4"))
    );
    mapper.apply(&durable(5, "session.execution.succeeded", json!({})));
    // The turn ended; the encode is still live work.
    assert_eq!(mapper.running_children().len(), 1);
    // OpenCode 2.4.0: the command's end is a synthetic inbox entry, sent
    // when the job settles; it ends the child at once.
    let ended = mapper.apply(&shell_notice(
        6,
        "msg_shell",
        "<background-result kind=\"shell\" id=\"sh_1\" state=\"completed\" command=\"ffmpeg -i in.mov out.mp4\">\nframe=120\nvideo:2MB\n\nExit code: 1\n</background-result>",
        json!({"source": "shell", "shellID": "sh_1", "jobID": "sh_1", "state": "completed", "truncated": false, "exit": 1}),
    ));
    assert!(
        matches!(&ended[..], [Event::Child { update }] if update.status == ChildStatus::Completed && update.child.kind == ChildKind::BackgroundTask)
    );
    assert!(mapper.running_children().is_empty());
    // The notice is the child's result, never Inline's input to withdraw.
    assert!(mapper.pending_inbox().is_empty());
    // It wakes the session into a run named after it.
    let woke = mapper.apply(&durable(7, "session.execution.started", json!({})));
    assert!(matches!(&woke[0], Event::Turn { turn, .. } if turn.as_str() == "msg_shell"));
    let delivered = mapper.apply(&durable(
        8,
        "session.inbox.delivered",
        json!({"inboxID": "msg_shell"}),
    ));
    assert_eq!(user_messages(&delivered), 0);
    match &delivered[..] {
        [
            Event::Item(Item {
                id,
                turn: Some(turn),
                update:
                    ItemUpdate::Completed {
                        body:
                            ItemBody::Command {
                                command,
                                output,
                                exit_code,
                                ..
                            },
                        status: ItemStatus::Completed,
                    },
                ..
            }),
        ] => {
            assert_eq!(id.as_str(), "msg_shell");
            assert_eq!(turn.as_str(), "msg_shell");
            assert_eq!(command, "ffmpeg -i in.mov out.mp4");
            // The wrapper and the notice for the model are gone.
            assert_eq!(output.as_deref(), Some("frame=120\nvideo:2MB"));
            assert_eq!(*exit_code, Some(1));
        }
        other => panic!("{other:?}"),
    }
}

fn shell_notice(seq: u64, inbox: &str, text: &str, metadata: Value) -> Value {
    durable(
        seq,
        "session.inbox.enqueued",
        json!({"inboxID": inbox, "item": {"type": "synthetic", "delivery": "steer", "payload": {
            "text": text, "description": "ffmpeg -i in.mov out.mp4", "metadata": metadata}}}),
    )
}

/// Moves `shell` to the background in a turn that then ends.
fn backgrounded(mapper: &mut Mapper, shell: &str) {
    mapper.apply(&durable(1, "session.execution.started", json!({})));
    mapper.apply(&durable(
        2,
        "session.tool.called",
        json!({"assistantMessageID": "m", "id": "call_bg", "name": "shell",
        "input": {"command": "ffmpeg -i in.mov out.mp4"}, "executed": true}),
    ));
    let moved = mapper.apply(&durable(3, "session.tool.success", json!({"assistantMessageID": "m", "id": "call_bg",
        "content": [{"type": "text", "text": format!("Command moved to the background (shell ID: {shell}).\nOutput is streaming to: /tmp/{shell}.log")},
                    {"type": "text", "text": "You will be notified automatically when the command finishes. DO NOT poll for completion."}],
        "metadata": {"status": "running", "shellID": shell, "truncated": false}, "executed": true})));
    // The call shows what it printed, not the instruction for the model.
    assert!(moved.iter().any(|event| matches!(event, Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Command { output: Some(output), .. }, .. }, .. })
        if output.starts_with("Command moved to the background") && !output.contains("DO NOT poll"))));
    mapper.apply(&durable(4, "session.execution.succeeded", json!({})));
    assert_eq!(mapper.running_children().len(), 1);
}

#[test]
fn shell_notices_of_2_2_and_cancelled_shells_read_as_their_command() {
    // 2.2.5 wraps the result in `<shell …>` and words its notice differently.
    let mut mapper = mapper();
    backgrounded(&mut mapper, "sh_2");
    let ended = mapper.apply(&shell_notice(
        5,
        "msg_old",
        "<shell id=\"sh_2\" state=\"completed\" command=\"make\">\nbuild failed\n\nExited with code 2\n</shell>",
        json!({"source": "shell", "shellID": "sh_2", "state": "completed", "truncated": false, "exit": 2}),
    ));
    assert!(
        matches!(&ended[0], Event::Child { update } if update.status == ChildStatus::Completed)
    );
    mapper.apply(&durable(6, "session.execution.started", json!({})));
    let delivered = mapper.apply(&durable(
        7,
        "session.inbox.delivered",
        json!({"inboxID": "msg_old"}),
    ));
    assert!(
        matches!(&delivered[..], [Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Command { output: Some(output), exit_code: Some(2), .. }, .. }, .. })] if output == "build failed")
    );

    // A stopped command: the child is stopped, the row interrupted, and
    // "Cancelled" is no output.
    let mut mapper = self::mapper();
    backgrounded(&mut mapper, "sh_3");
    let ended = mapper.apply(&shell_notice(
        5,
        "msg_cancel",
        "<background-result kind=\"shell\" id=\"sh_3\" state=\"cancelled\" command=\"make\">\nCancelled\n</background-result>",
        json!({"source": "shell", "shellID": "sh_3", "state": "cancelled"}),
    ));
    assert!(matches!(&ended[0], Event::Child { update } if update.status == ChildStatus::Stopped));
    mapper.apply(&durable(6, "session.execution.started", json!({})));
    let delivered = mapper.apply(&durable(
        7,
        "session.inbox.delivered",
        json!({"inboxID": "msg_cancel"}),
    ));
    assert!(matches!(
        &delivered[..],
        [Event::Item(Item {
            update: ItemUpdate::Completed {
                body: ItemBody::Command { output: None, .. },
                status: ItemStatus::Interrupted
            },
            ..
        })]
    ));
}

#[test]
fn a_shell_notice_missed_while_disconnected_ends_its_child_in_a_run_of_its_own() {
    let at = now();
    let mut mapper = mapper().with_opened_ms(at - 10_000);
    backgrounded(&mut mapper, "sh_4");
    let messages = vec![
        json!({"id": "msg_idle", "type": "idle", "outcome": "succeeded", "time": {"created": at + 3}}),
        json!({"id": "msg_shell", "type": "synthetic", "description": "ffmpeg -i in.mov out.mp4",
               "text": "<background-result kind=\"shell\" id=\"sh_4\" state=\"completed\" command=\"ffmpeg\">\ndone\n</background-result>",
               "metadata": {"source": "shell", "shellID": "sh_4", "state": "completed", "truncated": false, "exit": 0},
               "time": {"created": at + 1}}),
    ];
    let events = mapper.reconcile(&messages, false);
    // The child ends with the notice, then the notice's run starts.
    assert!(
        matches!(&events[..2], [Event::Child { update }, Event::Turn { turn, phase: TurnPhase::Started { .. } }]
        if update.status == ChildStatus::Completed && turn.as_str() == "msg_shell"),
        "{events:?}"
    );
    assert!(events.iter().any(|event| matches!(event, Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Command { output: Some(output), exit_code: Some(0), .. }, .. }, .. }) if output == "done")));
    assert_eq!(user_messages(&events), 0);
    assert!(mapper.running_children().is_empty());
    assert!(mapper.reconcile(&messages, false).is_empty());
}

#[test]
fn synthetic_context_is_never_shown_as_a_user_prompt() {
    let mut mapper = mapper();
    mapper.apply(&durable(1, "session.execution.started", json!({})));
    mapper.apply(&durable(
        2,
        "session.inbox.enqueued",
        json!({"inboxID": "msg_note", "item": {"type": "synthetic", "delivery": "steer",
            "payload": {"text": "<inline-message from=\"Mo\">context</inline-message>", "metadata": {"inline.input": "in-p"}}}}),
    ));
    let delivered = mapper.apply(&durable(
        3,
        "session.inbox.delivered",
        json!({"inboxID": "msg_note"}),
    ));
    assert_eq!(user_messages(&delivered), 0);
    // Inline's passive input is still consumed by the turn.
    assert!(matches!(&delivered[..], [Event::Input { id, .. }] if id.as_str() == "in-p"));
}

#[test]
fn a_compaction_completes_the_row_it_started() {
    let mut mapper = mapper();
    mapper.apply(&durable(1, "session.execution.started", json!({})));
    let started = mapper.apply(&durable(
        2,
        "session.compaction.started",
        json!({"reason": "auto"}),
    ));
    let Event::Item(Item { id: opened, .. }) = &started[0] else {
        panic!("{started:?}");
    };
    // Background compaction may end after the turn that saw it start.
    mapper.apply(&durable(3, "session.execution.succeeded", json!({})));
    let ended = mapper.apply(&durable(
        4,
        "session.compaction.ended",
        json!({"reason": "auto", "text": "summary"}),
    ));
    assert!(
        matches!(&ended[..], [Event::Item(Item { id, turn: Some(turn), update: ItemUpdate::Completed { status: ItemStatus::Completed, .. }, .. })]
        if id == opened && turn.as_str() == "evt_1")
    );
    mapper.apply(&durable(
        5,
        "session.compaction.started",
        json!({"reason": "manual"}),
    ));
    let failed = mapper.apply(&durable(
        6,
        "session.compaction.failed",
        json!({"reason": "manual", "error": {"type": "unknown", "message": "too long"}}),
    ));
    assert!(
        matches!(&failed[..], [Event::Item(Item { id, update: ItemUpdate::Completed { status: ItemStatus::Failed, .. }, .. })] if id.as_str() == "compaction:evt_5")
    );
}

#[test]
fn shell_output_leaves_out_the_notices_for_the_model() {
    let mut mapper = mapper();
    mapper.apply(&durable(1, "session.execution.started", json!({})));
    mapper.apply(&durable(
        2,
        "session.tool.called",
        json!({"assistantMessageID": "m", "id": "call_t", "name": "shell",
        "input": {"command": "cargo test"}, "executed": true}),
    ));
    let done = mapper.apply(&durable(3, "session.tool.success", json!({"assistantMessageID": "m", "id": "call_t",
        "content": [{"type": "text", "text": "test result: FAILED"}, {"type": "text", "text": "Exit code: 101"}],
        "metadata": {"status": "completed", "exit": 101, "truncated": false}, "executed": true})));
    assert!(
        matches!(&done[..], [Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Command { output: Some(output), exit_code: Some(101), .. }, .. }, .. })] if output == "test result: FAILED")
    );
    // A call the user stopped: its error is the output so far, then its notice.
    mapper.apply(&durable(
        4,
        "session.tool.called",
        json!({"assistantMessageID": "m", "id": "call_s", "name": "shell",
        "input": {"command": "sleep 100"}, "executed": true}),
    ));
    let notice =
        "[full output saved to /tmp/sh.log]\n\nCommand interrupted by the user (shell ID: sh_9).";
    let stopped = mapper.apply(&durable(5, "session.tool.failed", json!({"assistantMessageID": "m", "id": "call_s",
        "error": {"type": "unknown", "message": format!("tick 1\ntick 2\n\n{notice}")},
        "metadata": {"interrupted": true, "truncated": false, "shellID": "sh_9", "notice": notice}, "executed": true})));
    assert!(
        matches!(&stopped[..], [Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Command { output: Some(output), .. }, .. }, .. })] if output == "tick 1\ntick 2")
    );
}

#[test]
fn approvals_show_the_call_s_command_diff_and_arguments() {
    let mut mapper = mapper();
    mapper.apply(&durable(1, "session.execution.started", json!({})));
    // Shell: the command line as the model wrote it, not its subcommands.
    mapper.apply(&durable(2, "session.tool.called", json!({"assistantMessageID": "m", "id": "call_sh", "name": "shell",
        "input": {"command": "cargo test 2>&1 | tail -5", "workdir": "/work/app/crates"}, "executed": true})));
    let asked = mapper.apply(&volatile(
        "permission.asked",
        json!({"id": "per_sh", "action": "shell", "resources": ["cargo test", "tail -5"],
               "source": {"type": "tool", "messageID": "m", "id": "call_sh"}}),
    ));
    match &asked[..] {
        [
            Event::Interaction(Interaction {
                kind:
                    InteractionKind::Approval {
                        subject: ApprovalSubject::Command { command, cwd, .. },
                        decisions,
                    },
                ..
            }),
        ] => {
            assert_eq!(command, "cargo test 2>&1 | tail -5");
            assert_eq!(
                cwd.as_deref(),
                Some(std::path::Path::new("/work/app/crates"))
            );
            // Nothing to save: "always" would only allow once.
            let ids: Vec<&str> = decisions
                .iter()
                .map(|decision| decision.id.as_str())
                .collect();
            assert_eq!(ids, vec!["once", "reject", "stop"]);
        }
        other => panic!("{other:?}"),
    }

    // Edit: the preview diff goes on the call the card is about.
    mapper.apply(&durable(
        3,
        "session.tool.called",
        json!({"assistantMessageID": "m", "id": "call_ed", "name": "edit",
        "input": {"path": "src/main.rs", "oldString": "a", "newString": "b"}, "executed": true}),
    ));
    let asked = mapper.apply(&volatile(
        "permission.asked",
        json!({"id": "per_ed", "action": "edit", "resources": ["src/main.rs"], "save": ["src/main.rs"],
               "metadata": {"files": [{"file": "src/main.rs", "patch": "@@ -1 +1 @@\n-a\n+b", "status": "modified", "additions": 1, "deletions": 1}]},
               "source": {"type": "tool", "messageID": "m", "id": "call_ed"}}),
    ));
    match &asked[..] {
        [
            Event::Item(Item {
                id,
                update:
                    ItemUpdate::Updated {
                        body: ItemBody::FileChange { changes },
                    },
                ..
            }),
            Event::Interaction(Interaction {
                item: Some(item),
                kind:
                    InteractionKind::Approval {
                        subject: ApprovalSubject::FileChange { paths, .. },
                        ..
                    },
                ..
            }),
        ] => {
            assert_eq!(id, item);
            assert_eq!(paths, &vec![PathBuf::from("src/main.rs")]);
            assert_eq!(changes[0].path, PathBuf::from("src/main.rs"));
            assert!(changes[0].diff.as_deref().unwrap().contains("+b"));
        }
        other => panic!("{other:?}"),
    }

    // MCP: the tool's arguments, not its `*` resource.
    let asked = mapper.apply(&volatile(
        "permission.asked",
        json!({"id": "per_mcp", "action": "github_create_issue", "resources": ["*"], "save": ["*"],
               "metadata": {"input": {"title": "Flaky test"}}}),
    ));
    assert!(
        matches!(&asked[..], [Event::Interaction(Interaction { kind: InteractionKind::Approval { subject: ApprovalSubject::Tool { name, input, .. }, decisions }, .. })]
        if name == "github_create_issue" && input == &json!({"title": "Flaky test"}) && decisions.len() == 4)
    );
}

#[test]
fn reads_and_searches_are_commands_with_parsed_actions() {
    let folder = PathBuf::from("/work/app");
    let read = tool_body(
        "read",
        &json!({"path": "/work/app/src/main.rs", "offset": 10}),
        Some("10: fn main() {}"),
        None,
        None,
        Some(&folder),
    );
    assert!(
        matches!(&read, ItemBody::Command { actions, .. } if actions == &vec![CommandAction::Read { path: "src/main.rs".into() }])
    );
    let grep = tool_body(
        "grep",
        &json!({"pattern": "try_lock", "path": "src"}),
        None,
        None,
        None,
        Some(&folder),
    );
    assert!(
        matches!(&grep, ItemBody::Command { actions, command, .. } if command == "grep try_lock src"
        && actions == &vec![CommandAction::Search { query: Some("try_lock".into()), path: Some("src".into()) }])
    );
    let glob = tool_body(
        "glob",
        &json!({"pattern": "**/*.rs"}),
        None,
        None,
        None,
        Some(&folder),
    );
    assert!(
        matches!(&glob, ItemBody::Command { actions, .. } if actions == &vec![CommandAction::Search { query: Some("**/*.rs".into()), path: None }])
    );
    // Before its input streams in, a read is still a read.
    assert!(matches!(
        tool_body("read", &Value::Null, None, None, None, None),
        ItemBody::Command { actions, .. } if matches!(actions[..], [CommandAction::Read { .. }])
    ));
    assert!(matches!(
        tool_body("webfetch", &json!({"url": "https://example.com"}), None, None, None, None),
        ItemBody::Tool { name, .. } if name == "WebFetch"
    ));
    assert!(matches!(
        tool_body("websearch", &json!({"query": "rust"}), None, None, None, None),
        ItemBody::Tool { name, .. } if name == "WebSearch"
    ));
}

#[test]
fn a_write_over_an_existing_file_is_an_edit() {
    let folder = PathBuf::from("/work/app");
    let input = json!({"path": "README.md", "content": "hi"});
    let change = |output: Option<&str>| match tool_body(
        "write",
        &input,
        output,
        None,
        None,
        Some(&folder),
    ) {
        ItemBody::FileChange { changes } => changes[0].change.clone(),
        other => panic!("{other:?}"),
    };
    assert_eq!(
        change(Some("Wrote file successfully: README.md")),
        FileChangeKind::Update { moved_to: None }
    );
    assert_eq!(
        change(Some("Created file successfully: README.md")),
        FileChangeKind::Add
    );
}

#[test]
fn questions_name_the_call_that_asked() {
    let mut mapper = mapper();
    mapper.apply(&durable(1, "session.execution.started", json!({})));
    let asked = mapper.apply(&volatile(
        "form.created",
        json!({"form": {"id": "frm_1", "sessionID": SESSION, "title": "Questions",
            "metadata": {"kind": "question", "tool": {"messageID": "m", "id": "call_q"}},
            "fields": [{"key": "q0", "type": "string", "title": "Branch?"}]}}),
    ));
    assert!(
        matches!(&asked[..], [Event::Interaction(Interaction { item: Some(item), kind: InteractionKind::Question { .. }, .. })] if item.as_str() == "call_q")
    );
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

/// Messages as `GET /message?order=desc` lists them.
fn missed_turn(at: u64) -> Vec<Value> {
    vec![
        json!({"id": "msg_idle", "type": "idle", "outcome": "succeeded", "time": {"created": at + 3}}),
        json!({"id": "msg_a1", "type": "assistant", "time": {"created": at + 2}, "content": [
            {"type": "reasoning", "text": "Checking"},
            {"type": "tool", "id": "call_1", "name": "shell", "state": {"status": "completed",
                "input": {"command": "ls"}, "content": [{"type": "text", "text": "a.txt"}], "metadata": {"exit": 0}}, "time": {"created": at}},
            {"type": "text", "text": "One file: a.txt"}
        ]}),
        json!({"id": "msg_u1", "type": "user", "text": "list files", "metadata": {"inline.input": "in-1"}, "time": {"created": at + 1}}),
        json!({"id": "msg_old", "type": "assistant", "time": {"created": at - 60_000}, "content": [{"type": "text", "text": "old history"}]}),
    ]
}

#[test]
fn a_turn_missed_while_disconnected_is_rebuilt_from_the_messages() {
    let mut mapper = mapper();
    let events = mapper.reconcile(&missed_turn(now()), false);
    let kinds: Vec<String> = events
        .iter()
        .map(|event| match event {
            Event::Turn {
                turn,
                phase: TurnPhase::Started { .. },
            } => format!("start:{}", turn.as_str()),
            Event::Turn {
                phase:
                    TurnPhase::Completed {
                        outcome,
                        inputs_consumed,
                        ..
                    },
                ..
            } => {
                format!("end:{outcome:?}:{}", inputs_consumed.len())
            }
            Event::Input { id, .. } => format!("input:{}", id.as_str()),
            _ => String::new(),
        })
        .filter(|kind| !kind.is_empty())
        .collect();
    assert_eq!(
        kinds,
        vec!["start:msg_u1", "input:in-1", "end:Completed:1"],
        "{events:?}"
    );
    let texts: Vec<&str> = events
        .iter()
        .filter_map(|event| match event {
            Event::Item(Item {
                update:
                    ItemUpdate::Completed {
                        body:
                            ItemBody::Message {
                                role: MessageRole::Assistant,
                                text,
                                ..
                            },
                        ..
                    },
                ..
            }) => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(
        texts,
        vec!["One file: a.txt"],
        "history from before Inline followed is never news"
    );
    assert!(events.iter().any(|event| matches!(event, Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Command { output: Some(output), .. }, .. }, .. }) if output == "a.txt")));
    // A second reconciliation adds nothing.
    assert!(mapper.reconcile(&missed_turn(now()), false).is_empty());
}

#[test]
fn reconciling_after_partial_live_output_adds_only_what_was_missed() {
    let mut mapper = mapper();
    mapper.expect("msg_u1", input("in-1"));
    mapper.apply(&enqueue(1, "msg_u1", "list files", "steer"));
    mapper.apply(&durable(2, "session.execution.started", json!({})));
    mapper.apply(&durable(
        3,
        "session.inbox.delivered",
        json!({"inboxID": "msg_u1"}),
    ));
    mapper.apply(&durable(
        4,
        "session.step.started",
        json!({"assistantMessageID": "msg_a1", "agent": "build"}),
    ));
    mapper.apply(&durable(
        5,
        "session.reasoning.ended",
        json!({"assistantMessageID": "msg_a1", "ordinal": 0, "text": "Checking"}),
    ));
    // The stream drops here; the step finishes and the turn ends.
    let events = mapper.reconcile(&missed_turn(now()), false);
    // The step was seen starting; its tool, final text and the turn's end
    // were not. The reasoning shown live is not repeated.
    assert!(
        matches!(
            events.last(),
            Some(Event::Turn {
                phase: TurnPhase::Completed {
                    outcome: TurnOutcome::Completed,
                    ..
                },
                ..
            })
        ),
        "{events:?}"
    );
    assert!(!events.iter().any(|event| matches!(
        event,
        Event::Turn {
            phase: TurnPhase::Started { .. },
            ..
        }
    )));
    assert!(!events.iter().any(|event| matches!(
        event,
        Event::Item(Item {
            kind: ItemKind::Reasoning,
            ..
        })
    )));
    assert!(events.iter().any(|event| matches!(event, Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Message { text, .. }, .. }, .. }) if text == "One file: a.txt")));
    assert!(events.iter().any(|event| matches!(
        event,
        Event::Item(Item {
            update: ItemUpdate::Completed {
                body: ItemBody::Command { .. },
                ..
            },
            ..
        })
    )));
    assert!(mapper.reconcile(&missed_turn(now()), false).is_empty());
}

#[test]
fn a_session_still_running_keeps_its_turn_and_nothing_before_the_anchor_replays() {
    let mut mapper = mapper();
    mapper.anchor("msg_u1");
    let at = now();
    let messages = vec![
        json!({"id": "msg_a2", "type": "assistant", "time": {"created": at + 5}, "content": [{"type": "text", "text": "Working on it"}]}),
        json!({"id": "msg_u2", "type": "user", "text": "next", "time": {"created": at + 4}}),
        json!({"id": "msg_u1", "type": "user", "text": "first", "time": {"created": at}}),
    ];
    let events = mapper.reconcile(&messages, true);
    assert!(
        matches!(&events[0], Event::Turn { turn, phase: TurnPhase::Started { .. } } if turn.as_str() == "msg_u2"),
        "{events:?}"
    );
    assert!(mapper.turn().is_some(), "still running");
    // msg_a2 is still streaming: its partial text is not frozen.
    assert!(!events.iter().any(|event| matches!(event, Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Message { text, .. }, .. }, .. }) if text == "Working on it")));
    assert!(!events.iter().any(|event| matches!(event, Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Message { text, .. }, .. }, .. }) if text == "first")));
}

fn child_event(seq: u64, kind: &str, data: Value) -> Value {
    let mut data = data;
    data["sessionID"] = json!("ses_child");
    json!({"id": format!("evt_c{seq}"), "created": 1_700_000_100_000u64 + seq, "type": kind,
           "durable": {"aggregateID": "ses_child", "seq": seq, "version": 1}, "data": data})
}

fn report(seq: u64, inbox: &str, state: &str) -> Value {
    durable(
        seq,
        "session.inbox.enqueued",
        json!({"inboxID": inbox, "item": {"type": "synthetic", "delivery": "steer", "payload": {
            "text": format!("<subagent sessionID=\"ses_child\" state=\"{state}\" description=\"List files\">\na.txt\n</subagent>"),
            "description": "List files",
            "metadata": {"source": "subagent", "childID": "ses_child", "agent": "Explore", "state": state}}}}),
    )
}

fn user_messages(events: &[Event]) -> usize {
    events
        .iter()
        .filter(|event| {
            matches!(
                event,
                Event::Item(Item {
                    update: ItemUpdate::Completed {
                        body: ItemBody::Message {
                            role: MessageRole::User,
                            ..
                        },
                        ..
                    },
                    ..
                })
            )
        })
        .count()
}

/// OpenCode 2.3.0, recorded: the `subagent` tool returns the child's session
/// at once, the parent's run ends while the child works, and the child's
/// report wakes the parent into a run of its own.
#[test]
fn a_background_sub_agent_reports_back_in_a_run_of_its_own() {
    let mut mapper = mapper();
    mapper.expect("msg_a", input("in-1"));
    mapper.apply(&enqueue(
        1,
        "msg_a",
        "map the repo with a subagent",
        "steer",
    ));
    mapper.apply(&durable(2, "session.execution.started", json!({})));
    mapper.apply(&durable(
        3,
        "session.inbox.delivered",
        json!({"inboxID": "msg_a"}),
    ));
    mapper.apply(&durable(
        4,
        "session.tool.input.started",
        json!({"assistantMessageID": "msg_s1", "id": "call_sub", "name": "subagent"}),
    ));
    mapper.apply(&durable(5, "session.tool.called", json!({"assistantMessageID": "msg_s1", "id": "call_sub",
        "input": {"agent": "explore", "description": "List files", "prompt": "List the files."}, "executed": true})));
    let created = mapper.apply(&json!({"type": "session.created", "durable": {"aggregateID": "ses_child", "seq": 0, "version": 1},
        "data": {"sessionID": "ses_child", "parentID": SESSION, "title": "List files"}}));
    assert!(
        matches!(&created[0], Event::Child { update } if update.status == ChildStatus::Started)
    );
    let returned = mapper.apply(&durable(6, "session.tool.success", json!({"assistantMessageID": "msg_s1", "id": "call_sub",
        "content": [{"type": "text", "text": "The subagent is working in the background (sessionID: ses_child)."}],
        "metadata": {"sessionID": "ses_child", "status": "running", "truncated": false}, "executed": true})));
    assert!(
        matches!(&returned[0], Event::Item(Item { update: ItemUpdate::Completed { body: ItemBody::Child { child, .. }, .. }, .. }) if child.id.as_str() == "ses_child")
    );
    mapper.apply(&child_event(1, "session.execution.started", json!({})));

    // The parent's run ends while the child still works: the turn completes,
    // the child stays live work.
    let ended = mapper.apply(&durable(7, "session.execution.succeeded", json!({})));
    assert!(
        matches!(ended.last(), Some(Event::Turn { turn, phase: TurnPhase::Completed { outcome: TurnOutcome::Completed, inputs_consumed, .. } })
        if turn.as_str() == "msg_a" && inputs_consumed == &vec![input("in-1")])
    );
    assert!(mapper.turn().is_none());
    assert_eq!(mapper.running_children().len(), 1);

    // The child's work streams under it with no parent turn.
    let answer = mapper.apply(&child_event(
        2,
        "session.text.ended",
        json!({"assistantMessageID": "msg_c1", "ordinal": 0, "text": "a.txt"}),
    ));
    assert!(
        matches!(&answer[0], Event::Item(Item { turn: None, parent: Some(parent), .. }) if parent.id.as_str() == "ses_child")
    );
    let done = mapper.apply(&child_event(3, "session.execution.succeeded", json!({})));
    assert!(
        matches!(done.last(), Some(Event::Child { update }) if update.status == ChildStatus::Completed)
    );
    assert!(mapper.running_children().is_empty());

    // The report wakes the parent: a turn named after the report, with no
    // Inline input, and the report is never shown as a user prompt.
    assert!(
        mapper
            .apply(&report(8, "msg_report", "completed"))
            .is_empty()
    );
    assert!(mapper.pending_inbox().is_empty());
    let woke = mapper.apply(&durable(9, "session.execution.started", json!({})));
    assert_eq!(
        woke,
        vec![Event::Turn {
            turn: TurnId::new("msg_report").unwrap(),
            phase: TurnPhase::Started { inputs: vec![] },
        }]
    );
    let delivered = mapper.apply(&durable(
        10,
        "session.inbox.delivered",
        json!({"inboxID": "msg_report"}),
    ));
    assert_eq!(user_messages(&delivered), 0);
    assert!(
        !delivered
            .iter()
            .any(|event| matches!(event, Event::Input { .. }))
    );
    assert!(matches!(&delivered[..], [Event::Item(Item {
        turn: Some(turn),
        parent: Some(parent),
        update: ItemUpdate::Completed { body: ItemBody::Message { role: MessageRole::System, text, .. }, .. },
        ..
    })] if turn.as_str() == "msg_report" && parent.id.as_str() == "ses_child" && text == "List files reported back"));
    let summary = mapper.apply(&durable(
        11,
        "session.text.ended",
        json!({"assistantMessageID": "msg_s2", "ordinal": 0, "text": "One file: a.txt"}),
    ));
    assert!(
        matches!(&summary[0], Event::Item(Item { turn: Some(turn), .. }) if turn.as_str() == "msg_report")
    );
    let closed = mapper.apply(&durable(12, "session.execution.succeeded", json!({})));
    assert!(
        matches!(closed.last(), Some(Event::Turn { turn, phase: TurnPhase::Completed { outcome: TurnOutcome::Completed, inputs_consumed, .. } })
        if turn.as_str() == "msg_report" && inputs_consumed.is_empty())
    );
}

#[test]
fn a_report_steered_into_a_running_turn_stays_in_it_and_ends_a_missed_child() {
    let mut mapper = mapper();
    mapper.apply(&enqueue(1, "msg_a", "keep going", "steer"));
    mapper.apply(&durable(2, "session.execution.started", json!({})));
    mapper.apply(&durable(
        3,
        "session.inbox.delivered",
        json!({"inboxID": "msg_a"}),
    ));
    assert!(mapper.adopt_child("ses_child", Some("List files".into()), true));
    // A user prompt queued behind the run is Inline's to withdraw; the
    // report is not.
    mapper.apply(&enqueue(4, "msg_q", "then this", "queue"));
    mapper.apply(&report(5, "msg_report", "error"));
    assert_eq!(mapper.pending_inbox(), vec!["msg_q".to_owned()]);
    let delivered = mapper.apply(&durable(
        6,
        "session.inbox.delivered",
        json!({"inboxID": "msg_report"}),
    ));
    // The child's own end was not seen: the report ends it.
    assert!(
        matches!(&delivered[0], Event::Child { update } if update.status == ChildStatus::Failed)
    );
    assert!(
        matches!(&delivered[1], Event::Item(Item { turn: Some(turn), update: ItemUpdate::Completed { body: ItemBody::Message { role: MessageRole::System, text, .. }, .. }, .. })
        if turn.as_str() == "msg_a" && text == "List files failed")
    );
    assert!(mapper.running_children().is_empty());
}

#[test]
fn a_report_run_missed_while_disconnected_is_rebuilt_as_its_own_turn() {
    let at = now();
    let mut mapper = mapper().with_opened_ms(at);
    let messages = vec![
        json!({"id": "msg_idle2", "type": "idle", "outcome": "succeeded", "time": {"created": at + 4}}),
        json!({"id": "msg_a2", "type": "assistant", "time": {"created": at + 3, "completed": at + 3}, "content": [
            {"type": "text", "text": "One file: a.txt"}]}),
        json!({"id": "msg_report", "type": "synthetic", "text": "<subagent ...>", "description": "List files",
               "metadata": {"source": "subagent", "childID": "ses_child", "agent": "Explore", "state": "completed"},
               "time": {"created": at + 2}}),
    ];
    let events = mapper.reconcile(&messages, false);
    assert!(
        matches!(&events[0], Event::Turn { turn, phase: TurnPhase::Started { .. } } if turn.as_str() == "msg_report")
    );
    assert_eq!(user_messages(&events), 0);
    assert!(
        matches!(events.last(), Some(Event::Turn { turn, phase: TurnPhase::Completed { outcome: TurnOutcome::Completed, .. } }) if turn.as_str() == "msg_report")
    );
    // Seen once: a second reconciliation adds nothing.
    assert!(mapper.reconcile(&messages, false).is_empty());
}

/// A sub-agent of this session, running, that Inline then stopped: OpenCode
/// interrupted it.
fn stopped_child(mapper: &mut Mapper) {
    assert!(mapper.adopt_child("ses_child", Some("List files".into()), true));
    mapper.stopping_children(["ses_child".to_owned()]);
    let ended = mapper.apply(&child_event(1, "session.execution.interrupted", json!({})));
    assert!(
        matches!(ended.last(), Some(Event::Child { update }) if update.status == ChildStatus::Stopped)
    );
    assert!(mapper.running_children().is_empty());
}

#[test]
fn a_run_woken_only_by_a_stopped_child_is_handed_back_to_stop() {
    let mut mapper = mapper();
    stopped_child(&mut mapper);
    // The interrupted child still reports, and the report wakes the idle
    // parent.
    mapper.apply(&report(1, "msg_report", "cancelled"));
    let woke = mapper.apply(&durable(2, "session.execution.started", json!({})));
    let turn = TurnId::new("msg_report").unwrap();
    assert!(matches!(&woke[0], Event::Turn { turn: started, .. } if *started == turn));
    assert_eq!(
        mapper.take_stop_wakes(),
        vec![(SESSION.to_owned(), Some(turn.clone()))]
    );
    assert!(mapper.take_stop_wakes().is_empty(), "handed back once");
    assert!(mapper.stop_wake_holds(SESSION, Some(&turn)));
    // Stopped on purpose: the turn ends without an error.
    let ended = mapper.apply(&durable(
        3,
        "session.execution.interrupted",
        json!({"reason": "user"}),
    ));
    assert!(matches!(
        ended.last(),
        Some(Event::Turn {
            phase: TurnPhase::Completed {
                outcome: TurnOutcome::Interrupted,
                error: None,
                ..
            },
            ..
        })
    ));
    // The report stays parked, and the next prompt's run reads it.
    assert!(mapper.was_stopped("ses_child"));
    mapper.apply(&enqueue(4, "msg_b", "what next?", "steer"));
    mapper.apply(&durable(5, "session.execution.started", json!({})));
    assert!(mapper.take_stop_wakes().is_empty());
    mapper.apply(&durable(
        6,
        "session.inbox.delivered",
        json!({"inboxID": "msg_report"}),
    ));
    assert!(
        !mapper.was_stopped("ses_child"),
        "read: it wakes nothing again"
    );
}

#[test]
fn a_wake_with_a_prompt_or_a_live_childs_report_runs() {
    let mut mapper = mapper();
    stopped_child(&mut mapper);
    // A prompt waiting next to the stopped child's report.
    mapper.apply(&report(1, "msg_report", "cancelled"));
    mapper.apply(&enqueue(2, "msg_b", "go on", "steer"));
    mapper.apply(&durable(3, "session.execution.started", json!({})));
    assert!(mapper.take_stop_wakes().is_empty());
    mapper.apply(&durable(
        4,
        "session.inbox.delivered",
        json!({"inboxID": "msg_b"}),
    ));
    mapper.apply(&durable(5, "session.execution.succeeded", json!({})));

    // Another sub-agent, never stopped, reports next to it.
    let mut mapper = self::mapper();
    stopped_child(&mut mapper);
    mapper.apply(&report(1, "msg_report", "cancelled"));
    mapper.apply(&durable(2, "session.inbox.enqueued", json!({"inboxID": "msg_other", "item": {"type": "synthetic", "delivery": "steer", "payload": {
        "text": "<subagent sessionID=\"ses_other\" state=\"completed\">\ndone\n</subagent>",
        "metadata": {"source": "subagent", "childID": "ses_other", "state": "completed"}}}})));
    mapper.apply(&durable(3, "session.execution.started", json!({})));
    assert!(mapper.take_stop_wakes().is_empty());
}

#[test]
fn a_prompt_that_joins_a_stopped_wake_keeps_it_running() {
    let mut mapper = mapper();
    stopped_child(&mut mapper);
    mapper.apply(&report(1, "msg_report", "cancelled"));
    mapper.apply(&durable(2, "session.execution.started", json!({})));
    let wakes = mapper.take_stop_wakes();
    let turn = wakes[0].1.clone();
    // Someone steers into it before Inline's interrupt goes out.
    mapper.apply(&enqueue(3, "msg_b", "and also", "steer"));
    assert!(!mapper.stop_wake_holds(SESSION, turn.as_ref()));
}

#[test]
fn a_stopped_sub_agent_woken_again_is_handed_back_unless_given_new_work() {
    let mut mapper = mapper();
    stopped_child(&mut mapper);
    // Its own background shell's notice wakes it again.
    mapper.apply(&child_event(2, "session.execution.started", json!({})));
    assert_eq!(
        mapper.take_stop_wakes(),
        vec![("ses_child".to_owned(), None)]
    );
    assert!(mapper.stop_wake_holds("ses_child", None));
    mapper.apply(&child_event(3, "session.execution.interrupted", json!({})));
    assert!(!mapper.stop_wake_holds("ses_child", None), "it stopped");

    // The parent sends it a follow-up: its work and reports count again.
    mapper.apply(&enqueue(4, "msg_b", "ask it again", "steer"));
    mapper.apply(&durable(5, "session.execution.started", json!({})));
    mapper.apply(&durable(
        6,
        "session.tool.input.started",
        json!({"assistantMessageID": "msg_s3", "id": "call_again", "name": "subagent"}),
    ));
    mapper.apply(&durable(7, "session.tool.called", json!({"assistantMessageID": "msg_s3", "id": "call_again",
        "input": {"agent": "explore", "description": "List files", "prompt": "And the tests?", "sessionID": "ses_child"}, "executed": true})));
    assert!(!mapper.was_stopped("ses_child"));
    mapper.apply(&child_event(4, "session.execution.started", json!({})));
    assert!(mapper.take_stop_wakes().is_empty());
}

#[test]
fn a_shell_stopped_without_a_notice_ends_its_child() {
    let mut mapper = mapper();
    backgrounded(&mut mapper, "sh_1");
    assert_eq!(mapper.running_shells(), vec!["sh_1".to_owned()]);
    let ended = mapper.shell_stopped("sh_1");
    assert!(
        matches!(&ended[..], [Event::Child { update }] if update.status == ChildStatus::Stopped && update.child.kind == ChildKind::BackgroundTask)
    );
    assert!(mapper.running_children().is_empty());
    assert!(mapper.shell_stopped("sh_1").is_empty());
}

#[test]
fn queued_prompts_still_parked_in_an_idle_session_are_its_queue() {
    // After a stop, queued prompts wait for the next start.
    let mut mapper = mapper();
    let events = mapper.seed_inbox(&json!([
        {"id": "msg_q", "type": "user", "delivery": "queue", "payload": {"text": "after this"}},
        {"id": "msg_s", "type": "synthetic", "delivery": "steer", "payload": {"text": "context"}}
    ]));
    assert!(
        matches!(&events[0], Event::Queue { entries } if entries.len() == 1 && entries[0].entry.as_str() == "msg_q")
    );
    // A queued prompt sent to an idle session starts it instead.
    let mut mapper = self::mapper();
    mapper.apply(&enqueue(1, "msg_q", "now", "queue"));
    assert!(mapper.queue().is_empty());
}
