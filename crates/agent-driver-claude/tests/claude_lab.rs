//! Labs: the real `claude` against a fake Messages API (spec §13).
//!
//! Ignored by default; see `support/mod.rs` for how to run them. Each
//! scenario records every frame and every API call as evidence, and asserts
//! only what the bridge relies on.

mod support;

use std::sync::Arc;
use std::time::Duration;

use inline_agent_driver_claude::{
    ClaudeClient, InitializeRequest, PermissionDecision, PermissionRequest, Priority,
    SessionStart, UserMessage,
};
use serde_json::{Map, Value, json};
use support::{Lab, Policy, allow_all};

const TURN: Duration = Duration::from_secs(60);

fn sleep_tool(seconds: u32, tag: &str) -> String {
    format!(r#"@tool Bash {{"command":"sleep {seconds}; echo {tag}","description":"lab sleep"}}"#)
}

async fn wait_tool_use(lab: &Lab) -> bool {
    lab.recorder
        .wait_for("assistant tool_use", TURN, |frames| {
            frames.iter().any(|frame| {
                frame["type"] == "assistant"
                    && frame["message"]["content"]
                        .as_array()
                        .is_some_and(|blocks| blocks.iter().any(|block| block["type"] == "tool_use"))
            })
        })
        .await
}

async fn start_bypass(lab: &Lab) -> ClaudeClient {
    let options = lab.options(SessionStart::new_session());
    let (client, _) = lab
        .connect(&options, allow_all(), InitializeRequest::default())
        .await;
    client
}

fn result_summary(lab: &Lab) -> Vec<Value> {
    lab.recorder
        .results()
        .iter()
        .map(|result| {
            json!({
                "subtype": result["subtype"],
                "is_error": result["is_error"],
                "num_turns": result["num_turns"],
                "terminal_reason": result["terminal_reason"],
                "stop_reason": result["stop_reason"],
                "user_message_uuids": result["user_message_uuids"],
                "result": result["result"],
            })
        })
        .collect()
}

fn api_parts(lab: &Lab) -> Vec<Value> {
    lab.api
        .conversation_calls()
        .iter()
        .map(|call| json!(call.last_user_parts()))
        .collect()
}

async fn finish(lab: &Lab, client: &ClaudeClient) {
    let exit = client.close().await;
    lab.note(json!({"closed": exit.map(|exit| exit.describe())}));
    lab.save();
}

#[tokio::test]
#[ignore = "lab: needs CLAUDE_LAB_BIN"]
async fn lab_turn_text() {
    let Some(lab) = Lab::start("turn_text").await else {
        return;
    };
    let client = start_bypass(&lab).await;
    lab.send(&client, &UserMessage::text("hello lab").with_uuid("t1"))
        .await;
    assert!(lab.recorder.wait_results(1, TURN).await);
    let init = lab.recorder.of("system", Some("init"));
    lab.note(json!({"observed": {
        "results": result_summary(&lab),
        "lifecycle_t1": lab.recorder.lifecycle("t1"),
        "init_capabilities": init.first().map(|frame| frame["capabilities"].clone()),
        "init_tools": init.first().map(|frame| frame["tools"].clone()),
        "init_permission_mode": init.first().map(|frame| frame["permissionMode"].clone()),
        "session_state": lab.recorder.of("system", Some("session_state_changed")).iter().map(|frame| frame["state"].clone()).collect::<Vec<_>>(),
    }}));
    finish(&lab, &client).await;
    let result = &lab.recorder.results()[0];
    assert_eq!(result["subtype"], "success");
    assert!(result["result"].as_str().unwrap_or_default().contains("FAKE-OK"));
}

fn approval_policy() -> Policy {
    Arc::new(|request: &PermissionRequest| {
        let command = request.input["command"].as_str().unwrap_or_default();
        if command.contains("deny-me") {
            PermissionDecision::deny("lab says no")
        } else if command.contains("remember") {
            PermissionDecision::Allow {
                updated_input: None,
                updated_permissions: request.permission_suggestions.clone(),
            }
        } else {
            PermissionDecision::allow()
        }
    })
}

#[tokio::test]
#[ignore = "lab: needs CLAUDE_LAB_BIN"]
async fn lab_approvals() {
    let Some(lab) = Lab::start("approvals").await else {
        return;
    };
    let mut options = lab.options(SessionStart::new_session());
    options.permission_mode = lab.ask_mode().into();
    let (client, _) = lab
        .connect(&options, approval_policy(), InitializeRequest::default())
        .await;
    let prompts = [
        ("a1", r#"@tool Bash {"command":"echo approved-1","description":"lab"}"#),
        ("a2", r#"@tool Bash {"command":"echo deny-me","description":"lab"}"#),
        ("a3", r#"@tool Bash {"command":"echo remember-1","description":"lab"}"#),
        ("a4", r#"@tool Bash {"command":"echo remember-1","description":"lab"}"#),
    ];
    for (index, (uuid, prompt)) in prompts.iter().enumerate() {
        lab.send(&client, &UserMessage::text(*prompt).with_uuid(*uuid))
            .await;
        assert!(lab.recorder.wait_results(index + 1, TURN).await, "{uuid}");
    }
    let asks: Vec<Value> = lab
        .recorder
        .entries()
        .into_iter()
        .filter(|entry| entry["dir"] == "control")
        .map(|entry| entry["frame"].clone())
        .collect();
    lab.note(json!({"observed": {"asks": asks.len(), "results": result_summary(&lab)}}));
    finish(&lab, &client).await;
    let results = lab.recorder.results();
    assert!(results[0]["result"].as_str().unwrap().contains("approved-1"));
    assert!(results[1]["result"].as_str().unwrap().contains("lab says no"));
    // The third ask applied the suggested rule; the fourth ran unasked.
    assert_eq!(asks.len(), 3, "asks: {asks:#?}");
}

#[tokio::test]
#[ignore = "lab: needs CLAUDE_LAB_BIN"]
async fn lab_ask_user_question() {
    let Some(lab) = Lab::start("ask_user_question").await else {
        return;
    };
    let policy: Policy = Arc::new(|request: &PermissionRequest| {
        if !request.is_ask_user_question() {
            return PermissionDecision::allow();
        }
        let mut answers = Map::new();
        for question in request.questions() {
            let label = question
                .options
                .last()
                .map(|option| option.label.clone())
                .unwrap_or_default();
            answers.insert(question.question, json!(label));
        }
        PermissionDecision::answer_questions(&request.input, answers)
    });
    // Bypass permissions, the owner's default: the question must still ask.
    let options = lab.options(SessionStart::new_session());
    let (client, _) = lab
        .connect(&options, policy, InitializeRequest::default())
        .await;
    let question = json!({"questions": [{
        "question": "Which color?",
        "header": "Color",
        "options": [
            {"label": "Red", "description": "warm"},
            {"label": "Blue", "description": "cool"}
        ],
        "multiSelect": false
    }]});
    lab.send(
        &client,
        &UserMessage::text(format!("@tool AskUserQuestion {question}")).with_uuid("q1"),
    )
    .await;
    assert!(lab.recorder.wait_results(1, TURN).await);
    lab.note(json!({"observed": {"results": result_summary(&lab), "api": api_parts(&lab)}}));
    finish(&lab, &client).await;
    let result = &lab.recorder.results()[0];
    assert!(
        result["result"].as_str().unwrap_or_default().contains("Blue"),
        "{result:#}"
    );
}

async fn steer(lab_name: &str, priority: Priority) {
    let Some(lab) = Lab::start(lab_name).await else {
        return;
    };
    let client = start_bypass(&lab).await;
    lab.send(
        &client,
        &UserMessage::text(sleep_tool(4, "slept")).with_uuid("t1"),
    )
    .await;
    assert!(wait_tool_use(&lab).await);
    tokio::time::sleep(Duration::from_millis(500)).await;
    lab.send(
        &client,
        &UserMessage::text(format!("STEER-{}-1", priority.as_str().to_uppercase()))
            .with_uuid("s1")
            .with_priority(priority),
    )
    .await;
    let expected = if priority == Priority::Next { 1 } else { 2 };
    lab.recorder.wait_results(expected, TURN).await;
    // Any further turn the CLI owes.
    lab.recorder.wait_results(expected + 1, Duration::from_secs(5)).await;
    lab.note(json!({"observed": {
        "lifecycle_t1": lab.recorder.lifecycle("t1"),
        "lifecycle_s1": lab.recorder.lifecycle("s1"),
        "results": result_summary(&lab),
        "api": api_parts(&lab),
    }}));
    finish(&lab, &client).await;
    assert!(!lab.recorder.results().is_empty());
}

#[tokio::test]
#[ignore = "lab: needs CLAUDE_LAB_BIN"]
async fn lab_steer_next() {
    steer("steer_next", Priority::Next).await;
}

#[tokio::test]
#[ignore = "lab: needs CLAUDE_LAB_BIN"]
async fn lab_steer_now() {
    steer("steer_now", Priority::Now).await;
}

#[tokio::test]
#[ignore = "lab: needs CLAUDE_LAB_BIN"]
async fn lab_queue_later() {
    steer("queue_later", Priority::Later).await;
}

#[tokio::test]
#[ignore = "lab: needs CLAUDE_LAB_BIN"]
async fn lab_passive_idle() {
    let Some(lab) = Lab::start("passive_idle").await else {
        return;
    };
    let client = start_bypass(&lab).await;
    lab.send(
        &client,
        &UserMessage::text("PASSIVE-IDLE-1").with_uuid("p1").passive(),
    )
    .await;
    lab.recorder.wait_results(1, Duration::from_secs(10)).await;
    let calls_after_passive = lab.api.conversation_calls().len();
    let results_after_passive = lab.recorder.results().len();
    lab.send(&client, &UserMessage::text("after passive").with_uuid("q1"))
        .await;
    assert!(
        lab.recorder
            .wait_results(results_after_passive + 1, TURN)
            .await
    );
    lab.note(json!({"observed": {
        "calls_after_passive": calls_after_passive,
        "lifecycle_p1": lab.recorder.lifecycle("p1"),
        "results": result_summary(&lab),
        "api": api_parts(&lab),
    }}));
    finish(&lab, &client).await;
    assert_eq!(calls_after_passive, 0, "passive input must not call the model");
    let last_call = lab.api.conversation_calls().last().cloned().unwrap();
    let seen = serde_json::to_string(&last_call.body["messages"]).unwrap();
    assert!(seen.contains("PASSIVE-IDLE-1"), "passive text reached the next turn");
}

#[tokio::test]
#[ignore = "lab: needs CLAUDE_LAB_BIN"]
async fn lab_passive_during_turn() {
    let Some(lab) = Lab::start("passive_during_turn").await else {
        return;
    };
    let client = start_bypass(&lab).await;
    lab.send(
        &client,
        &UserMessage::text(sleep_tool(4, "slept")).with_uuid("t1"),
    )
    .await;
    assert!(wait_tool_use(&lab).await);
    lab.send(
        &client,
        &UserMessage::text("PASSIVE-MID-1").with_uuid("p1").passive(),
    )
    .await;
    assert!(lab.recorder.wait_results(1, TURN).await);
    lab.recorder.wait_results(2, Duration::from_secs(5)).await;
    let results_before = lab.recorder.results().len();
    lab.send(&client, &UserMessage::text("next turn").with_uuid("q1"))
        .await;
    assert!(lab.recorder.wait_results(results_before + 1, TURN).await);
    let first_seen = lab
        .api
        .conversation_calls()
        .iter()
        .position(|call| serde_json::to_string(&call.body["messages"]).unwrap().contains("PASSIVE-MID-1"));
    lab.note(json!({"observed": {
        "first_call_with_passive": first_seen,
        "calls": lab.api.conversation_calls().len(),
        "lifecycle_p1": lab.recorder.lifecycle("p1"),
        "results": result_summary(&lab),
        "api": api_parts(&lab),
    }}));
    finish(&lab, &client).await;
}

async fn interrupt_with(lab_name: &str, cancel_queued: bool) {
    let Some(lab) = Lab::start(lab_name).await else {
        return;
    };
    let client = start_bypass(&lab).await;
    lab.send(
        &client,
        &UserMessage::text(sleep_tool(6, "slept")).with_uuid("t1"),
    )
    .await;
    assert!(wait_tool_use(&lab).await);
    for uuid in ["l1", "l2"] {
        lab.send(
            &client,
            &UserMessage::text(format!("QUEUED-{uuid}"))
                .with_uuid(uuid)
                .with_priority(Priority::Later),
        )
        .await;
    }
    tokio::time::sleep(Duration::from_millis(300)).await;
    let started = std::time::Instant::now();
    let receipt = client.interrupt(cancel_queued).await;
    let receipt_ms = started.elapsed().as_millis() as u64;
    lab.note(json!({"interrupt": {
        "cancel_queued": cancel_queued,
        "receipt": format!("{receipt:?}"),
        "ms": receipt_ms,
    }}));
    assert!(lab.recorder.wait_results(1, TURN).await);
    // Queued input that survives runs next; give it time to show.
    lab.recorder.wait_results(3, Duration::from_secs(10)).await;
    lab.note(json!({"observed": {
        "lifecycle_t1": lab.recorder.lifecycle("t1"),
        "lifecycle_l1": lab.recorder.lifecycle("l1"),
        "lifecycle_l2": lab.recorder.lifecycle("l2"),
        "results": result_summary(&lab),
        "api": api_parts(&lab),
    }}));
    finish(&lab, &client).await;
    let receipt = receipt.expect("interrupt receipt");
    if cancel_queued && let Some(cancelled) = receipt.cancelled {
        assert!(cancelled.contains(&"l1".to_string()));
    }
}

#[tokio::test]
#[ignore = "lab: needs CLAUDE_LAB_BIN"]
async fn lab_interrupt_plain() {
    interrupt_with("interrupt_plain", false).await;
}

#[tokio::test]
#[ignore = "lab: needs CLAUDE_LAB_BIN"]
async fn lab_interrupt_cancel_queued() {
    interrupt_with("interrupt_cancel_queued", true).await;
}

async fn agent_tool_name(lab: &Lab, client: &ClaudeClient) -> String {
    lab.send(client, &UserMessage::text("list tools").with_uuid("w0"))
        .await;
    assert!(lab.recorder.wait_results(1, TURN).await);
    let tools = lab.recorder.of("system", Some("init"))[0]["tools"].clone();
    let names: Vec<&str> = tools
        .as_array()
        .map(|tools| tools.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    if names.contains(&"Agent") { "Agent" } else { "Task" }.to_string()
}

async fn subagent(lab_name: &str, background: bool) {
    let Some(lab) = Lab::start(lab_name).await else {
        return;
    };
    let client = start_bypass(&lab).await;
    let tool = agent_tool_name(&lab, &client).await;
    let prompt = if background {
        "@sleep 3000\n@text SUB-BG-OK"
    } else {
        "@text SUB-OK"
    };
    let mut input = json!({
        "description": "lab subagent",
        "prompt": prompt,
        "subagent_type": "general-purpose",
    });
    if background {
        input["run_in_background"] = json!(true);
    }
    lab.send(
        &client,
        &UserMessage::text(format!("@tool {tool} {input}")).with_uuid("a1"),
    )
    .await;
    assert!(lab.recorder.wait_results(2, TURN).await);
    if background {
        lab.recorder
            .wait_for("task_notification", TURN, |frames| {
                frames.iter().any(|frame| frame["subtype"] == "task_notification")
            })
            .await;
        // The parent continues on its own once the agent reports.
        lab.recorder.wait_results(3, Duration::from_secs(20)).await;
    }
    let tasks: Vec<Value> = lab
        .recorder
        .frames()
        .into_iter()
        .filter(|frame| {
            frame["type"] == "system"
                && frame["subtype"]
                    .as_str()
                    .is_some_and(|subtype| subtype.starts_with("task_") || subtype == "background_tasks_changed")
        })
        .collect();
    let sub_messages = lab
        .recorder
        .frames()
        .into_iter()
        .filter(|frame| !frame["parent_tool_use_id"].is_null() && frame.get("parent_tool_use_id").is_some())
        .count();
    lab.note(json!({"observed": {
        "tool": tool,
        "task_frames": tasks,
        "subagent_messages": sub_messages,
        "results": result_summary(&lab),
        "api": api_parts(&lab),
    }}));
    finish(&lab, &client).await;
}

#[tokio::test]
#[ignore = "lab: needs CLAUDE_LAB_BIN"]
async fn lab_subagent_foreground() {
    subagent("subagent_foreground", false).await;
}

#[tokio::test]
#[ignore = "lab: needs CLAUDE_LAB_BIN"]
async fn lab_subagent_background() {
    subagent("subagent_background", true).await;
}

#[tokio::test]
#[ignore = "lab: needs CLAUDE_LAB_BIN"]
async fn lab_brief_mode() {
    let Some(lab) = Lab::start("brief_mode").await else {
        return;
    };
    let mut options = lab.options(SessionStart::new_session());
    options.brief = true;
    let (client, _) = lab
        .connect(&options, allow_all(), InitializeRequest::default())
        .await;
    lab.send(&client, &UserMessage::text("hello brief").with_uuid("b0"))
        .await;
    assert!(lab.recorder.wait_results(1, TURN).await);
    let definition = lab
        .api
        .conversation_calls()
        .first()
        .and_then(|call| {
            call.body["tools"]
                .as_array()?
                .iter()
                .find(|tool| tool["name"] == "SendUserMessage")
                .cloned()
        });
    lab.note(json!({"send_user_message_tool": definition}));
    let Some(definition) = definition else {
        finish(&lab, &client).await;
        panic!("--brief offers no SendUserMessage tool");
    };
    // Fill every required string property with the update text.
    let mut input = Map::new();
    let schema = &definition["input_schema"];
    for name in schema["required"].as_array().into_iter().flatten() {
        let Some(name) = name.as_str() else { continue };
        let property = &schema["properties"][name];
        let value = match property["type"].as_str() {
            Some("string") => match property["enum"].as_array().and_then(|values| values.first()) {
                Some(first) => first.clone(),
                None => json!("BRIEF-UPDATE-1"),
            },
            Some("array") => json!([]),
            Some("boolean") => json!(false),
            _ => json!("BRIEF-UPDATE-1"),
        };
        input.insert(name.to_string(), value);
    }
    lab.send(
        &client,
        &UserMessage::text(format!("@tool SendUserMessage {}", Value::Object(input)))
            .with_uuid("b1"),
    )
    .await;
    assert!(lab.recorder.wait_results(2, TURN).await);
    let init = lab.recorder.of("system", Some("init"));
    lab.note(json!({"observed": {
        "init_tools_has_send_user_message": init.first().map(|frame| frame["tools"].as_array().is_some_and(|tools| tools.iter().any(|tool| tool == "SendUserMessage"))),
        "results": result_summary(&lab),
        "api": api_parts(&lab),
    }}));
    finish(&lab, &client).await;
}

/// Resumes `session_id` in `lab` and returns (turn finished, messages sent).
async fn resume_and_check(lab: &Lab, session_id: &str) -> (bool, usize) {
    let before = lab.recorder.results().len();
    let calls_before = lab.api.conversation_calls().len();
    let options = lab.options(SessionStart::Resume {
        session_id: session_id.to_string(),
    });
    let (client, _) = lab
        .connect(&options, allow_all(), InitializeRequest::default())
        .await;
    lab.send(&client, &UserMessage::text("RESUMED-1").with_uuid("r1"))
        .await;
    let resumed = lab.recorder.wait_results(before + 1, TURN).await;
    let calls = lab.api.conversation_calls();
    let history = calls
        .get(calls_before..)
        .and_then(|new_calls| new_calls.last())
        .map_or(0, |call| call.body["messages"].as_array().map_or(0, Vec::len));
    let init_sessions: Vec<Value> = lab
        .recorder
        .of("system", Some("init"))
        .iter()
        .map(|frame| frame["session_id"].clone())
        .collect();
    lab.note(json!({"observed": {
        "session_id": session_id,
        "init_session_ids": init_sessions,
        "history_messages_sent": history,
        "results": result_summary(lab),
    }}));
    finish(lab, &client).await;
    assert_eq!(init_sessions.last().cloned(), Some(json!(session_id)));
    (resumed, history)
}

/// 13.5 (synthetic): a session written with the ACP adapter's entry point
/// (`sdk-ts`, no `CLAUDE_CONFIG_DIR` override) resumes under Inline's.
#[tokio::test]
#[ignore = "lab: needs CLAUDE_LAB_BIN"]
async fn lab_resume_sdk_ts_session() {
    let Some(lab) = Lab::start("resume_sdk_ts_session").await else {
        return;
    };
    let session_id = uuid::Uuid::new_v4().to_string();
    let mut options = lab.options(SessionStart::New {
        session_id: session_id.clone(),
    });
    options.entrypoint = "sdk-ts".into();
    let (client, _) = lab
        .connect(&options, allow_all(), InitializeRequest::default())
        .await;
    lab.send(&client, &UserMessage::text("ACP-ERA-1").with_uuid("e1"))
        .await;
    assert!(lab.recorder.wait_results(1, TURN).await);
    client.close().await;
    let (resumed, history) = resume_and_check(&lab, &session_id).await;
    assert!(resumed);
    assert!(history >= 3, "resume carried the earlier turn");
}

/// 13.5 (real transcript): `CLAUDE_LAB_ACP_SESSION` names a `.jsonl` the
/// ACP adapter wrote; it is copied into the lab's isolated config dir and
/// resumed against the fake API.
#[tokio::test]
#[ignore = "lab: needs CLAUDE_LAB_BIN and CLAUDE_LAB_ACP_SESSION"]
async fn lab_resume_acp_transcript() {
    let Some(source) = std::env::var_os("CLAUDE_LAB_ACP_SESSION").filter(|value| !value.is_empty())
    else {
        return;
    };
    let Some(lab) = Lab::start("resume_acp_transcript").await else {
        return;
    };
    let source = std::path::PathBuf::from(source);
    let session_id = source
        .file_stem()
        .expect("session file name")
        .to_string_lossy()
        .into_owned();
    for cwd in [
        lab.work_dir.path().to_path_buf(),
        std::fs::canonicalize(lab.work_dir.path()).unwrap(),
    ] {
        let project = lab.projects_dir().join(sanitize(&support::path_text(&cwd)));
        std::fs::create_dir_all(&project).unwrap();
        std::fs::copy(&source, project.join(format!("{session_id}.jsonl"))).unwrap();
    }
    lab.note(json!({"acp_session": support::path_text(&source)}));
    let (resumed, history) = resume_and_check(&lab, &session_id).await;
    assert!(resumed);
    assert!(history >= 3, "resume carried the ACP-era turns");
}

fn sanitize(path: &str) -> String {
    path.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}
