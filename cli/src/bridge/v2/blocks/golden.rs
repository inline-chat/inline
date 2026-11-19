//! Golden tests for the recipes.
//!
//! Each recipe has native samples in `fixtures/<recipe>/<case>.json`:
//!
//! ```json
//! { "source": "where the sample comes from",
//!   "native": { "the native frame or tool call, for reference" },
//!   "input": { "what the recipe takes: harness events, an interaction, tool arguments" } }
//! ```
//!
//! The recipe's messages are compared with `<case>.golden.json` beside it:
//! the fallback text, the blocks with every range replaced by the text it
//! covers, and the buttons. `INLINE_BLOCK_GOLDENS=update` rewrites goldens.
//! Every message must also hold Inline's rules: ranges inside the text,
//! top-level blocks in order without overlapping, and every button a block
//! names among the message's actions.

use std::path::{Path, PathBuf};

use inline_agent_bridge::harness::{Envelope, Event, OutputMode, SessionKey};
use inline_agent_bridge::{ProviderId, ProviderSessionId};
use inline_protocol::proto;
use serde_json::{Map, Value, json};

use super::slice;
use crate::bridge::v2::doc::Doc;
use crate::bridge::v2::render::{ActionStyle, CardAction, RenderOp, Renderer, Vocabulary};

/// Recipe name (its fixtures folder) → its sample runner.
type Sample = fn(&Value) -> Vec<Message>;

const RECIPES: &[(&str, Sample)] = &[
    ("plan", rendered),
    ("plan_proposal", super::plan_proposal::sample),
    ("approval", super::approval::sample),
    ("question", super::question::sample),
    ("review", rendered),
    ("report_findings", super::review::sample_reported),
    ("suggest_thread", super::task::sample),
    ("ask_next_step", super::next_step::sample),
    ("suggest_prompts", super::prompts::sample),
];

/// One message a recipe produced.
pub(super) struct Message {
    label: String,
    doc: Doc,
    buttons: Vec<Button>,
}

impl Message {
    pub(super) fn new(label: &str, doc: Doc, buttons: Vec<Button>) -> Self {
        Self {
            label: label.to_owned(),
            doc,
            buttons,
        }
    }
}

pub(super) struct Button {
    id: String,
    label: String,
    style: ActionStyle,
}

pub(super) fn button(id: &str, label: &str, style: ActionStyle) -> Button {
    Button {
        id: id.to_owned(),
        label: label.to_owned(),
        style,
    }
}

/// Decision buttons under their ids.
pub(super) fn buttons(ids: &[String], actions: &[CardAction]) -> Vec<Button> {
    ids.iter()
        .zip(actions)
        .map(|(id, action)| button(id, &action.label, action.style))
        .collect()
}

/// Harness events through the renderer: the messages a turn leaves, each at
/// its last edit, plus the progress messages as they stood after each event
/// listed in `snapshots`. Input: `{"vocabulary", "agent", "folder"?,
/// "snapshots"?: [index], "events": [Event]}`.
pub(super) fn rendered(input: &Value) -> Vec<Message> {
    let vocabulary = match input["vocabulary"].as_str() {
        Some("claude") => Vocabulary::Claude,
        _ => Vocabulary::Codex,
    };
    let agent = input["agent"].as_str().unwrap_or("Codex");
    let mut renderer = Renderer::new(OutputMode::Detailed, vocabulary, agent);
    if let Some(folder) = input["folder"].as_str() {
        renderer.set_folder(folder.into());
    }
    let session = SessionKey {
        provider: ProviderId::new("golden").expect("provider"),
        session: ProviderSessionId::new("golden").expect("session"),
    };
    let mut messages: Vec<Message> = Vec::new();
    let mut snapshots: Vec<Message> = Vec::new();
    let events = input["events"].as_array().expect("events");
    let snapshot_after: Vec<u64> = input["snapshots"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_u64)
        .collect();
    for (index, event) in events.iter().enumerate() {
        let event: Event = serde_json::from_value(event.clone())
            .unwrap_or_else(|error| panic!("event {index}: {error}"));
        let envelope = Envelope {
            session: session.clone(),
            seq: index as u64 + 1,
            checkpoint: None,
            at_ms: 1_000 * (index as u64 + 1),
            event,
        };
        for op in renderer.apply(&envelope) {
            let (label, doc, buttons) = match op {
                RenderOp::Progress { slot, doc } => (format!("progress {slot}"), doc, Vec::new()),
                RenderOp::EndProgress { slot, doc } => {
                    (format!("progress {slot}"), doc, Vec::new())
                }
                RenderOp::Update { doc } => ("update".to_owned(), doc, Vec::new()),
                RenderOp::Final { doc } => ("final".to_owned(), doc, Vec::new()),
                RenderOp::Notice { doc } => ("notice".to_owned(), doc, Vec::new()),
                RenderOp::PlanProposal { doc } => (
                    "plan proposal".to_owned(),
                    doc,
                    vec![
                        button(
                            super::plan_proposal::APPROVE,
                            super::plan_proposal::APPROVE_LABEL,
                            ActionStyle::Primary,
                        ),
                        button(
                            super::plan_proposal::KEEP_PLANNING,
                            super::plan_proposal::KEEP_PLANNING_LABEL,
                            ActionStyle::Default,
                        ),
                    ],
                ),
                RenderOp::Card {
                    interaction,
                    doc,
                    actions,
                    ..
                } => (
                    format!("card {interaction}"),
                    doc,
                    buttons(&super::action_ids(actions.len()), &actions),
                ),
                RenderOp::CardClosed { interaction, doc } => {
                    (format!("card {interaction}"), doc, Vec::new())
                }
            };
            // An edit replaces the message it edits.
            match messages.iter_mut().find(|message| message.label == label) {
                Some(message) => *message = Message::new(&label, doc, buttons),
                None => messages.push(Message::new(&label, doc, buttons)),
            }
        }
        if snapshot_after.contains(&(index as u64)) {
            for message in messages
                .iter()
                .filter(|message| message.label.starts_with("progress"))
            {
                snapshots.push(Message::new(
                    &format!("{} · live after event {index}", message.label),
                    message.doc.clone(),
                    Vec::new(),
                ));
            }
        }
    }
    snapshots.extend(messages);
    snapshots
}

/// A message as its golden: text, readable blocks, buttons.
fn project(message: &Message) -> Value {
    let blocks = serde_json::to_value(&message.doc.blocks).expect("blocks");
    let mut value = json!({
        "label": message.label,
        "text": message.doc.text,
        "markdown": message.doc.markdown,
        "blocks": readable(&blocks, &message.doc.text, None),
    });
    if !message.doc.entities.is_empty() {
        // Each style as its kind and the text it covers.
        value["styles"] = message
            .doc
            .entities
            .iter()
            .map(|entity| {
                let kind = inline_protocol::proto::message_entity::Type::try_from(entity.r#type)
                    .map_or_else(|_| entity.r#type.to_string(), |kind| {
                        format!("{kind:?}").to_lowercase()
                    });
                let span = inline_protocol::proto::BlockText {
                    offset: entity.offset,
                    length: entity.length,
                    ..Default::default()
                };
                json!({ kind: slice(&message.doc.text, &span).unwrap_or_else(|| "<out of range>".into()) })
            })
            .collect();
    }
    if !message.buttons.is_empty() {
        value["buttons"] = message
            .buttons
            .iter()
            .map(|button| {
                json!({
                    "id": button.id,
                    "label": button.label,
                    "style": format!("{:?}", button.style).to_lowercase(),
                })
            })
            .collect();
    }
    value
}

/// Ranges become the text they cover, enums their names, and unset fields
/// go, so a golden reads like the message.
fn readable(value: &Value, text: &str, key: Option<&str>) -> Value {
    match value {
        Value::Object(map) => {
            if let Some(span) = as_span(map) {
                return Value::String(
                    slice(text, &span).unwrap_or_else(|| "<out of range>".into()),
                );
            }
            // A oneof (`{"kind": {"Steps": {...}}}`) reads as `{"steps": {...}}`.
            if map.len() == 1
                && let Some((name, inner)) = map.iter().next()
                && name.chars().next().is_some_and(char::is_uppercase)
            {
                return json!({ snake(name): readable(inner, text, None) });
            }
            let mut out = Map::new();
            for (name, inner) in map {
                if name == "kind"
                    && let Value::Object(oneof) = inner
                {
                    for (variant, inner) in oneof {
                        out.insert(snake(variant), readable(inner, text, None));
                    }
                    continue;
                }
                let inner = readable(inner, text, Some(name));
                if is_unset(&inner) {
                    continue;
                }
                out.insert(name.clone(), inner);
            }
            Value::Object(out)
        }
        Value::Array(items) => {
            Value::Array(items.iter().map(|item| readable(item, text, key)).collect())
        }
        Value::Number(number) => match (key, number.as_i64()) {
            // Unset scalars and unspecified enums.
            (_, Some(0)) => Value::Null,
            (Some(key), Some(raw)) => enum_name(key, raw as i32).map_or(value.clone(), Value::from),
            _ => value.clone(),
        },
        other => other.clone(),
    }
}

fn as_span(map: &Map<String, Value>) -> Option<proto::BlockText> {
    let keys_ok = map
        .keys()
        .all(|key| matches!(key.as_str(), "offset" | "length" | "is_rtl"));
    (keys_ok && map.contains_key("offset") && map.contains_key("length")).then(|| {
        proto::BlockText {
            offset: map["offset"].as_i64().unwrap_or(-1),
            length: map["length"].as_i64().unwrap_or(-1),
            is_rtl: None,
        }
    })
}

fn is_unset(value: &Value) -> bool {
    match value {
        Value::Null | Value::Bool(false) => true,
        Value::Array(items) => items.is_empty(),
        Value::Object(map) => map.is_empty(),
        Value::Number(number) => number.as_i64() == Some(0),
        _ => false,
    }
}

fn enum_name(key: &str, raw: i32) -> Option<String> {
    use proto::{block_approval, block_review, block_review_finding};
    let name = match key {
        "state" => proto::BlockDecisionState::try_from(raw).ok()?.as_str_name(),
        "status" => proto::BlockStatus::try_from(raw).ok()?.as_str_name(),
        "subject" => block_approval::Subject::try_from(raw).ok()?.as_str_name(),
        "verdict" => block_review::Verdict::try_from(raw).ok()?.as_str_name(),
        "priority" => block_review_finding::Priority::try_from(raw)
            .ok()?
            .as_str_name(),
        "confidence" => block_review_finding::Confidence::try_from(raw)
            .ok()?
            .as_str_name(),
        "outcome" => block_review_finding::Outcome::try_from(raw)
            .ok()?
            .as_str_name(),
        "change" => proto::block_diff::Change::try_from(raw).ok()?.as_str_name(),
        "required_grant" => proto::AgentGrantRequirement::try_from(raw)
            .ok()?
            .as_str_name(),
        "activity_kind" => proto::block_disclosure::ActivityKind::try_from(raw)
            .ok()?
            .as_str_name(),
        _ => return None,
    };
    Some(name.to_owned())
}

fn snake(name: &str) -> String {
    let mut out = String::new();
    for (index, character) in name.chars().enumerate() {
        if character.is_uppercase() {
            if index > 0 {
                out.push('_');
            }
            out.extend(character.to_lowercase());
        } else {
            out.push(character);
        }
    }
    out
}

/// Inline's rules every recipe message keeps.
fn check(message: &Message, case: &str) {
    let doc = &message.doc;
    if doc.markdown {
        assert!(doc.blocks.is_empty(), "{case}: Markdown carries no blocks");
        return;
    }
    let size = crate::bridge::v2::limits::Size::of(doc);
    assert!(size.fits(), "{case}: over Inline's limits: {size:?}");
    let utf16 = doc.text.encode_utf16().count() as i64;
    let blocks = serde_json::to_value(&doc.blocks).expect("blocks");
    let mut spans = Vec::new();
    collect_spans(&blocks, &mut spans);
    assert!(doc.entities.len() <= 1_024, "{case}: too many styles");
    for entity in &doc.entities {
        assert!(
            entity.offset >= 0 && entity.length > 0 && entity.offset + entity.length <= utf16,
            "{case}/{}: style {}+{} outside {utf16} units",
            message.label,
            entity.offset,
            entity.length
        );
    }
    for (offset, length) in &spans {
        assert!(
            *offset >= 0 && *length > 0 && offset + length <= utf16,
            "{case}/{}: range {offset}+{length} outside {utf16} units",
            message.label
        );
    }
    // Top-level blocks cover ascending, separate parts of the text.
    let mut end = 0;
    for block in &blocks.as_array().cloned().unwrap_or_default() {
        let mut spans = Vec::new();
        collect_spans(block, &mut spans);
        let Some(start) = spans.iter().map(|(offset, _)| *offset).min() else {
            continue;
        };
        assert!(start >= end, "{case}/{}: blocks overlap", message.label);
        end = spans
            .iter()
            .map(|(offset, length)| offset + length)
            .max()
            .unwrap_or(end);
    }
    let named = named_actions(&blocks);
    for id in named {
        assert!(
            message.buttons.iter().any(|button| button.id == id),
            "{case}/{}: block names action {id} the message lacks",
            message.label
        );
    }
}

fn collect_spans(value: &Value, out: &mut Vec<(i64, i64)>) {
    match value {
        Value::Object(map) => {
            if let Some(span) = as_span(map) {
                out.push((span.offset, span.length));
                return;
            }
            for inner in map.values() {
                collect_spans(inner, out);
            }
        }
        Value::Array(items) => items.iter().for_each(|item| collect_spans(item, out)),
        _ => {}
    }
}

fn named_actions(value: &Value) -> Vec<String> {
    fn walk(value: &Value, ids: &mut Vec<String>) {
        match value {
            Value::Object(map) => {
                for (key, inner) in map {
                    match (key.as_str(), inner) {
                        ("action_ids", Value::Array(items)) => {
                            ids.extend(items.iter().filter_map(Value::as_str).map(str::to_owned));
                        }
                        ("action_id", Value::String(id)) => ids.push(id.clone()),
                        _ => walk(inner, ids),
                    }
                }
            }
            Value::Array(items) => items.iter().for_each(|item| walk(item, ids)),
            _ => {}
        }
    }
    let mut ids = Vec::new();
    walk(value, &mut ids);
    ids
}

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src/bridge/v2/blocks/fixtures")
}

fn cases(recipe: &str) -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = std::fs::read_dir(fixtures().join(recipe))
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .map(|entry| entry.path())
                .filter(|path| {
                    path.extension()
                        .is_some_and(|extension| extension == "json")
                        && !path.to_string_lossy().ends_with(".golden.json")
                })
                .collect()
        })
        .unwrap_or_default();
    paths.sort();
    paths
}

#[test]
fn every_recipe_matches_its_goldens() {
    let update = std::env::var("INLINE_BLOCK_GOLDENS").as_deref() == Ok("update");
    let mut failures = Vec::new();
    for (recipe, sample) in RECIPES {
        let paths = cases(recipe);
        assert!(!paths.is_empty(), "recipe {recipe} has no fixtures");
        for path in paths {
            let case = format!("{recipe}/{}", path.file_stem().unwrap().to_string_lossy());
            let fixture: Value = serde_json::from_str(
                &std::fs::read_to_string(&path).unwrap_or_else(|error| panic!("{case}: {error}")),
            )
            .unwrap_or_else(|error| panic!("{case}: {error}"));
            assert!(
                fixture.get("source").is_some() && fixture.get("native").is_some(),
                "{case}: a fixture names its source and keeps the native sample"
            );
            let messages = sample(&fixture["input"]);
            assert!(!messages.is_empty(), "{case}: no messages");
            for message in &messages {
                check(message, &case);
            }
            let actual = Value::Array(messages.iter().map(project).collect());
            let golden_path = path.with_extension("golden.json");
            let pretty = serde_json::to_string_pretty(&actual).expect("golden") + "\n";
            if update {
                std::fs::write(&golden_path, &pretty).expect("write golden");
                continue;
            }
            match std::fs::read_to_string(&golden_path) {
                Ok(expected) if expected == pretty => {}
                Ok(_) => failures.push(format!("{case}: differs from its golden")),
                Err(_) => failures.push(format!("{case}: no golden")),
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{}\nRun with INLINE_BLOCK_GOLDENS=update, then read the diff.",
        failures.join("\n")
    );
}

#[test]
fn every_fixture_folder_is_a_recipe() {
    for entry in std::fs::read_dir(fixtures()).expect("fixtures") {
        let name = entry
            .expect("entry")
            .file_name()
            .to_string_lossy()
            .into_owned();
        assert!(
            RECIPES.iter().any(|(recipe, _)| *recipe == name),
            "fixtures/{name} has no recipe in golden::RECIPES"
        );
    }
}
