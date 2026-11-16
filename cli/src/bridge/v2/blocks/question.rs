//! Claude AskUserQuestion, Codex `request_user_input`: questions.
//!
//! A form block, each field with its header chip ("Auth method"), each
//! option with its preview (Claude only; shown monospaced while focused) and
//! the option Claude marks "(Recommended)". Questions that each pick one of a
//! few options are asked one at a time with message buttons instead, which
//! every Inline app draws; a reply to the card answers in the person's own
//! words where the harness takes one.

use inline_agent_bridge::harness::{FieldAnswer, FieldInput, QuestionForm};
use inline_protocol::proto;

use super::head;
use crate::bridge::v2::doc::{Doc, DocBuilder};

/// Form ID of a question card; one form per card message.
pub(crate) const QUESTION_FORM_ID: &str = "q";

/// Most options a question shows as buttons.
const MAX_PICK_OPTIONS: usize = 8;
/// A preview a button card shows before cutting it.
const MAX_PREVIEW_CHARS: usize = 1_500;

/// Every question picks one option, so the card can ask them one at a time
/// with message buttons, which every Inline app already shows. Other forms
/// stay forms until every app draws them.
pub(crate) fn pickable(form: &QuestionForm) -> bool {
    !form.fields.is_empty()
        && form.fields.iter().all(|field| {
            matches!(&field.input, FieldInput::Select { options, multiple: false, .. }
                if !options.is_empty() && options.len() <= MAX_PICK_OPTIONS)
        })
}

/// Whether the question `field` also takes an answer in the person's own
/// words: a reply to the card.
pub(crate) fn takes_reply(form: &QuestionForm, field: usize) -> bool {
    matches!(
        form.fields.get(field).map(|field| &field.input),
        Some(FieldInput::Select {
            allow_other: true,
            ..
        })
    )
}

/// The card that asks `form`.
pub(crate) fn card(agent: &str, form: &QuestionForm) -> Doc {
    if pickable(form) {
        return pick_card(agent, form, 0, &[]);
    }
    let mut builder = DocBuilder::new();
    if form.title.is_none() {
        builder.paragraph(&format!("{agent} has a question"));
    }
    // Anyone with access to the agent can answer its questions.
    builder.form(QUESTION_FORM_ID, form, proto::AgentGrantRequirement::Access);
    builder.finish()
}

/// A pickable form's card while question `field` is open, with the answers
/// already given above it. The buttons carry the options.
pub(crate) fn pick_card(
    agent: &str,
    form: &QuestionForm,
    field: usize,
    answered: &[String],
) -> Doc {
    let mut builder = DocBuilder::new();
    let count = form.fields.len();
    builder.paragraph(&match (&form.title, count) {
        (Some(title), _) => title.clone(),
        (None, 1) => format!("{agent} has a question"),
        (None, count) => format!("{agent} has {count} questions"),
    });
    for (question, answer) in form.fields.iter().zip(answered) {
        builder.paragraph(&format!("{}: {answer}", question.prompt));
    }
    let Some(question) = form.fields.get(field) else {
        return builder.finish();
    };
    let header = question
        .header
        .as_deref()
        .map(str::trim)
        .filter(|header| !header.is_empty() && *header != question.prompt.trim())
        .map(|header| format!("{header} · "))
        .unwrap_or_default();
    builder.paragraph(&if count > 1 {
        format!("{}/{count}. {header}{}", field + 1, question.prompt)
    } else {
        format!("{header}{}", question.prompt)
    });
    if let FieldInput::Select { options, .. } = &question.input {
        for option in options {
            let description = option
                .description
                .as_deref()
                .filter(|text| !text.trim().is_empty());
            let preview = option
                .preview
                .as_deref()
                .filter(|text| !text.trim().is_empty());
            match description {
                Some(description) => {
                    builder.paragraph(&format!("• {}: {description}", option.label));
                }
                None if preview.is_some() => builder.paragraph(&format!("• {}", option.label)),
                None => {}
            }
            if let Some(preview) = preview {
                builder.code(&head(preview, MAX_PREVIEW_CHARS), None);
            }
        }
    }
    if takes_reply(form, field) {
        builder.footer("Or reply to this message with your own answer.");
    }
    builder.finish()
}

/// The card once the question closed: what it asked, each answer Inline sent
/// beside its question, and `resolution` ("Answered by Mo") under them. A
/// question without an answer (cancelled, answered elsewhere, or secret) shows
/// only its text.
pub(crate) fn closed_card(
    agent: &str,
    form: &QuestionForm,
    answers: &[FieldAnswer],
    resolution: &str,
) -> Doc {
    let mut builder = DocBuilder::new();
    let count = form.fields.len();
    builder.paragraph(&match (&form.title, count) {
        (Some(title), _) => title.clone(),
        (None, 1) => format!("{agent} asked a question"),
        (None, count) => format!("{agent} asked {count} questions"),
    });
    for field in &form.fields {
        let answer = answers
            .iter()
            .find(|answer| answer.field == field.id)
            .map(|answer| {
                answer
                    .values
                    .iter()
                    .map(|value| value.trim())
                    .filter(|value| !value.is_empty())
                    .collect::<Vec<_>>()
                    .join(", ")
            })
            .filter(|answer| !answer.is_empty());
        let prompt = field.prompt.trim();
        builder.paragraph(&match answer {
            Some(answer) => format!("{prompt}: {answer}"),
            None => prompt.to_owned(),
        });
    }
    builder.footer(resolution);
    builder.finish()
}

#[cfg(test)]
pub(super) fn sample(input: &serde_json::Value) -> Vec<super::golden::Message> {
    use super::golden::Message;

    let form: QuestionForm = serde_json::from_value(input["form"].clone()).expect("form");
    let agent = input["agent"].as_str().unwrap_or("Claude");
    let mut messages = vec![Message::new("card", card(agent, &form), Vec::new())];
    // The form block too, as apps that draw forms will get it.
    let mut builder = DocBuilder::new();
    builder.form(
        QUESTION_FORM_ID,
        &form,
        proto::AgentGrantRequirement::Access,
    );
    messages.push(Message::new("form", builder.finish(), Vec::new()));
    messages
}
