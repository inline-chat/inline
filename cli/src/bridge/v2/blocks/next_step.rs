//! Inline tool `ask_next_step`: Claude's end-of-turn `wrap_up` box.
//!
//! The recap of what the turn did, then the one decision the agent waits on
//! with one or two answers as buttons. A press goes back to the agent as the
//! person's input, as a reply to the card, and the card loses its buttons.

use inline_protocol::proto;

use crate::bridge::v2::doc::{Doc, DocBuilder};

/// Most answers the box offers.
pub(crate) const MAX_OPTIONS: usize = 2;

/// The button id of answer `index`.
pub(crate) fn option_id(index: usize) -> String {
    format!("next-{index}")
}

/// The box; `options` are the answers' labels.
pub(crate) fn card(recap: &str, question: Option<&str>, options: &[String]) -> Doc {
    let mut builder = DocBuilder::new();
    let recap = builder.span(recap.trim());
    let question = question
        .map(str::trim)
        .filter(|question| !question.is_empty())
        .map(|question| builder.span(question));
    let action_ids = (0..options.len().min(MAX_OPTIONS)).map(option_id).collect();
    builder.push_block(proto::block::Kind::NextStep(proto::BlockNextStep {
        recap: Some(recap),
        blocking: question.is_some(),
        question,
        action_ids,
        is_rtl: None,
    }));
    builder.finish()
}

#[cfg(test)]
pub(super) fn sample(input: &serde_json::Value) -> Vec<super::golden::Message> {
    use super::golden::{Message, button};
    use crate::bridge::v2::render::ActionStyle;

    let options: Vec<String> = input["options"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|option| option.as_str().map(str::to_owned))
        .collect();
    let mut doc = card(
        input["recap"].as_str().expect("recap"),
        input["question"].as_str(),
        &options,
    );
    let buttons = options
        .iter()
        .enumerate()
        .map(|(index, label)| {
            let style = if index == 0 {
                ActionStyle::Primary
            } else {
                ActionStyle::Default
            };
            button(&option_id(index), label, style)
        })
        .collect();
    let open = doc.clone();
    super::resolve(
        &mut doc,
        super::DecisionState::Accepted,
        Some(7),
        None,
        Some(&format!("{} (answered by Dena)", options[0])),
    );
    vec![
        Message::new("open", open, buttons),
        Message::new("answered", doc, Vec::new()),
    ]
}
