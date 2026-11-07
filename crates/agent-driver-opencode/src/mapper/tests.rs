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
    let done = mapper.apply(&durable(
        6,
        "session.synthetic",
        json!({"text": "<shell ...>", "description": "ffmpeg -i in.mov out.mp4",
        "metadata": {"source": "shell", "shellID": "sh_1", "state": "completed", "exit": 0}}),
    ));
    assert!(matches!(&done[0], Event::Child { update } if update.status == ChildStatus::Completed));
    assert!(matches!(
        &done[1],
        Event::Item(Item {
            update: ItemUpdate::Completed {
                body: ItemBody::Command {
                    exit_code: Some(0),
                    ..
                },
                status: ItemStatus::Completed
            },
            ..
        })
    ));
    assert!(mapper.running_children().is_empty());
}
