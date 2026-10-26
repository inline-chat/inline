//! Every contract fixture decodes into the session contract and re-encodes to
//! the same JSON, so a contract change that breaks a recorded mapping fails here.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use inline_agent_bridge::harness::{
    DeliveryKind, Event, Input, InteractionKind, InteractionResponse, Op,
};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

fn fixture_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/harness")
}

fn fixtures() -> Vec<(PathBuf, Value)> {
    let mut files = Vec::new();
    for provider in std::fs::read_dir(fixture_root()).expect("fixture root") {
        let provider = provider.expect("provider dir").path();
        if !provider.is_dir() {
            continue;
        }
        for file in std::fs::read_dir(&provider).expect("provider fixtures") {
            let path = file.expect("fixture").path();
            if path
                .extension()
                .is_some_and(|extension| extension == "json")
            {
                let text = std::fs::read_to_string(&path).expect("read fixture");
                let value = serde_json::from_str(&text)
                    .unwrap_or_else(|error| panic!("{}: invalid JSON: {error}", path.display()));
                files.push((path, value));
            }
        }
    }
    files.sort_by(|left, right| left.0.cmp(&right.0));
    assert!(!files.is_empty(), "no contract fixtures found");
    files
}

/// Drops nulls so optional fields may be omitted or written as null.
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

fn round_trip<T: DeserializeOwned + Serialize>(path: &Path, context: &str, value: &Value) -> T {
    let decoded: T = serde_json::from_value(value.clone())
        .unwrap_or_else(|error| panic!("{}: {context}: does not decode: {error}", path.display()));
    let encoded = serde_json::to_value(&decoded).expect("encode");
    assert_eq!(
        strip_nulls(&encoded),
        strip_nulls(value),
        "{}: {context}: re-encodes differently (unknown or misspelled field?)",
        path.display()
    );
    decoded
}

fn entries<'a>(fixture: &'a Value, key: &str) -> &'a [Value] {
    fixture
        .get(key)
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice)
}

fn name(entry: &Value) -> &str {
    entry
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("<unnamed>")
}

#[test]
fn every_fixture_decodes_into_the_contract_and_round_trips() {
    for (path, fixture) in fixtures() {
        let provider = fixture["provider"].as_str().expect("provider");
        assert!(
            path.parent()
                .and_then(Path::file_name)
                .is_some_and(|dir| dir == provider),
            "{}: provider does not match its folder",
            path.display()
        );
        assert!(
            fixture["recorded"].is_boolean(),
            "{}: recorded flag",
            path.display()
        );

        for delivery in entries(&fixture, "deliveries") {
            let input: Input = round_trip(&path, name(delivery), &delivery["input"]);
            assert!(
                !entries(delivery, "native").is_empty(),
                "{}: {}: no native frames",
                path.display(),
                name(delivery)
            );
            let _ = input;
        }
        for op in entries(&fixture, "ops") {
            let _: Op = round_trip(&path, name(op), &op["op"]);
        }

        let mut decisions_by_interaction = std::collections::BTreeMap::new();
        for step in entries(&fixture, "steps") {
            for event in entries(step, "events") {
                let event: Event = round_trip(&path, name(step), event);
                if let Event::Interaction(interaction) = &event {
                    let decisions: BTreeSet<String> = match &interaction.kind {
                        InteractionKind::Approval { decisions, .. } => decisions
                            .iter()
                            .map(|decision| decision.id.as_str().to_owned())
                            .collect(),
                        _ => BTreeSet::new(),
                    };
                    decisions_by_interaction.insert(interaction.id.as_str().to_owned(), decisions);
                }
            }
        }

        for response in entries(&fixture, "responses") {
            let decoded: InteractionResponse =
                round_trip(&path, name(response), &response["response"]);
            let interaction = response["interaction"].as_str().expect("interaction id");
            let decisions = decisions_by_interaction
                .get(interaction)
                .unwrap_or_else(|| {
                    panic!(
                        "{}: {}: answers an interaction no step opened",
                        path.display(),
                        name(response)
                    )
                });
            if let InteractionResponse::Decision { decision, .. } = decoded {
                assert!(
                    decisions.contains(decision.as_str()),
                    "{}: {}: picks a decision the interaction did not advertise",
                    path.display(),
                    name(response)
                );
            }
        }
    }
}

#[test]
fn claude_fixtures_cover_every_delivery() {
    let mut covered = BTreeSet::new();
    for (path, fixture) in fixtures() {
        if fixture["provider"] != "claude" {
            continue;
        }
        for delivery in entries(&fixture, "deliveries") {
            let input: Input = round_trip(&path, name(delivery), &delivery["input"]);
            covered.insert(input.delivery.kind());
        }
    }
    let all: BTreeSet<DeliveryKind> = DeliveryKind::ALL.into_iter().collect();
    assert_eq!(covered, all);
}
