//! Runs the Codex contract fixtures in `crates/agent-bridge/tests/fixtures/harness/codex`
//! through the real mapper and delivery code.

use std::path::Path;

use inline_agent_bridge::harness::{Event, Input, InteractionId, InteractionResponse, UserId};
use serde_json::Value;

use super::delivery::input_request;
use super::mapper::{AnswerPlan, CodexMapper, RequestMapped};

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

#[test]
fn codex_fixtures_match_the_mapper() {
    let dir =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../agent-bridge/tests/fixtures/harness/codex");
    let mut ran = 0;
    for file in std::fs::read_dir(&dir).expect("codex fixtures") {
        let path = file.expect("fixture").path();
        if path.extension().is_none_or(|extension| extension != "json") {
            continue;
        }
        let fixture: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).expect("read")).expect("json");
        let name = path.display();

        for delivery in entries(&fixture, "deliveries") {
            let input: Input = serde_json::from_value(delivery["input"].clone()).expect("input");
            let request = input_request("thr-1", &input);
            let native = serde_json::json!({"method": request.method, "params": request.params});
            assert_eq!(
                strip_nulls(&native),
                strip_nulls(&delivery["native"][0]),
                "{name}: delivery `{}`",
                delivery["name"]
            );
        }

        let mut mapper = CodexMapper::new("thr-1");
        for step in entries(&fixture, "steps") {
            let native = &step["native"];
            let method = native["method"].as_str().expect("method");
            let params = native.get("params").cloned().unwrap_or(Value::Null);
            let events = match native.get("id") {
                Some(id) => match mapper.server_request(id, method, &params) {
                    RequestMapped::Interaction(events) | RequestMapped::Reply { events, .. } => {
                        events
                    }
                    other => panic!("{name}: step `{}` mapped to {other:?}", step["name"]),
                },
                None => mapper.notification(method, &params).events,
            };
            assert_eq!(
                events_json(&events),
                strip_nulls(&step["events"]),
                "{name}: step `{}`",
                step["name"]
            );
            ran += 1;

            for response in entries(&fixture, "responses")
                .iter()
                .filter(|response| response["after_step"] == step["name"])
            {
                let interaction =
                    InteractionId::new(response["interaction"].as_str().expect("id")).expect("id");
                let answer: InteractionResponse =
                    serde_json::from_value(response["response"].clone()).expect("response");
                let by = UserId(response["by"].as_i64().unwrap_or(1));
                match mapper.answer(&interaction, &answer, by).expect("answer") {
                    AnswerPlan::Respond {
                        rpc_id,
                        result,
                        events,
                        ..
                    } => {
                        assert_eq!(
                            serde_json::json!({"id": rpc_id, "result": result}),
                            response["native"],
                            "{name}: response `{}`",
                            response["name"]
                        );
                        assert_eq!(
                            events_json(&events),
                            strip_nulls(&response["events"]),
                            "{name}: response events `{}`",
                            response["name"]
                        );
                    }
                    other => panic!("{name}: unexpected plan {other:?}"),
                }
            }
        }
    }
    assert!(ran > 0, "no Codex fixture steps ran");
}
