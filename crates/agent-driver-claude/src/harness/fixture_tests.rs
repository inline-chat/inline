//! Runs the Claude contract fixtures in
//! `crates/agent-bridge/tests/fixtures/harness/claude` through the real
//! mapper and delivery code.

use std::path::Path;

use inline_agent_bridge::harness::{Event, Input, InteractionId, InteractionResponse, Op, UserId};
use serde_json::{Value, json};

use super::delivery::{OpPlan, op_plan, user_message};
use super::mapper::{ClaudeMapper, RequestMapped};
use crate::control::InterruptReceipt;
use crate::wire::CliMessage;

fn strip_nulls(value: &Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .filter(|(_, value)| !value.is_null())
                .map(|(key, value)| (key.clone(), strip_nulls(value)))
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.iter().map(strip_nulls).collect()),
        other => other.clone(),
    }
}

fn events_json(events: &[Event]) -> Value {
    strip_nulls(&serde_json::to_value(events).expect("encode events"))
}

fn entries<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value
        .get(key)
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice)
}

/// Feeds one native frame to the mapper the way the session does.
fn feed(mapper: &mut ClaudeMapper, native: &Value) -> Vec<Event> {
    match native["type"].as_str() {
        Some("control_request") => {
            let id = native["request_id"].as_str().expect("request id");
            match mapper.request(id, &native["request"]) {
                RequestMapped::Interaction(events) | RequestMapped::Reply { events, .. } => events,
                RequestMapped::NotMine => Vec::new(),
            }
        }
        Some("control_cancel_request") => {
            mapper.cancelled(native["request_id"].as_str().expect("request id"))
        }
        Some("control_response") => {
            let receipt: InterruptReceipt =
                serde_json::from_value(native["response"]["response"].clone()).unwrap_or_default();
            mapper.interrupt_receipt(&receipt)
        }
        _ => mapper.message(&CliMessage::from_value(native.clone())),
    }
}

#[test]
fn claude_fixtures_match_the_mapper() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../agent-bridge/tests/fixtures/harness/claude");
    let mut ran = 0;
    let mut paths: Vec<_> = std::fs::read_dir(&dir)
        .expect("claude fixtures")
        .map(|entry| entry.expect("fixture").path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "json"))
        .collect();
    paths.sort();
    for path in paths {
        let fixture: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).expect("read")).expect("json");
        let name = path.display();
        let session_id = "5b1f8c1e-7d1a-4c55-9a0e-2f3c4d5e6f70";

        for delivery in entries(&fixture, "deliveries") {
            let input: Input = serde_json::from_value(delivery["input"].clone()).expect("input");
            assert_eq!(
                strip_nulls(&user_message(session_id, &input).to_value()),
                strip_nulls(&delivery["native"][0]),
                "{name}: delivery `{}`",
                delivery["name"]
            );
            ran += 1;
        }

        for op in entries(&fixture, "ops") {
            let decoded: Op = serde_json::from_value(op["op"].clone()).expect("op");
            let OpPlan::Control(requests) = op_plan(&decoded) else {
                panic!("{name}: op `{}` is not a control request", op["name"]);
            };
            let expected: Vec<Value> = entries(op, "native")
                .iter()
                .map(|native| native["request"].clone())
                .collect();
            assert_eq!(requests, expected, "{name}: op `{}`", op["name"]);
            ran += 1;
        }

        let mut mapper = ClaudeMapper::new(None);
        for step in entries(&fixture, "steps") {
            let events = feed(&mut mapper, &step["native"]);
            assert_eq!(
                events_json(&events),
                strip_nulls(&step["events"]),
                "{name}: step `{}`",
                step["name"]
            );
            ran += 1;
        }

        for response in entries(&fixture, "responses") {
            // Each response answers the interaction as the steps left it.
            let mut answering = mapper.clone();
            let interaction =
                InteractionId::new(response["interaction"].as_str().expect("id")).expect("id");
            let answer: InteractionResponse =
                serde_json::from_value(response["response"].clone()).expect("response");
            let plan = answering
                .answer(&interaction, &answer, UserId(response["by"].as_i64().unwrap_or(1)))
                .unwrap_or_else(|error| panic!("{name}: response `{}`: {error}", response["name"]));
            assert_eq!(
                json!({"type": "control_response", "response": {
                    "subtype": "success", "request_id": plan.request_id, "response": plan.response
                }}),
                response["native"],
                "{name}: response `{}`",
                response["name"]
            );
            ran += 1;
        }
    }
    assert!(ran > 0, "no Claude fixture entries ran");
}
