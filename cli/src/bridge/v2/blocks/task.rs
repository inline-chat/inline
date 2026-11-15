//! Inline tool `suggest_thread`: Claude's `start_session` "New task" card.
//!
//! The agent proposes work to run on its own, in a new task subthread of the
//! owner's DM. Start runs the `spawn_thread` path with the card's title and
//! brief (read back from the message, so it survives a restart) and edits the
//! card to accepted with the thread it started in; Dismiss declines it.

use inline_protocol::proto;

use super::{Resolution, chat_peer, slice};
use crate::bridge::v2::doc::{Doc, DocBuilder};

pub(crate) const START: &str = "task-start";
pub(crate) const DISMISS: &str = "task-dismiss";
pub(crate) const START_LABEL: &str = "Start";
pub(crate) const DISMISS_LABEL: &str = "Dismiss";

/// The suggestion card; `started` is the thread it started in.
pub(crate) fn card(
    title: &str,
    brief: Option<&str>,
    resolution: &Resolution,
    started: Option<i64>,
) -> Doc {
    let mut builder = DocBuilder::new();
    builder.push_raw("Suggested task: ");
    let title = builder.inline_span(title.trim());
    builder.newline();
    let brief = brief
        .map(str::trim)
        .filter(|brief| !brief.is_empty())
        .map(|brief| builder.span(brief));
    builder.push_block(proto::block::Kind::TaskSuggestion(
        proto::BlockTaskSuggestion {
            title: Some(title),
            brief,
            state: resolution.state as i32,
            started_peer: started.map(chat_peer),
            expires_at: None,
            action_ids: resolution.action_ids(&[START.to_owned(), DISMISS.to_owned()]),
            is_rtl: None,
        },
    ));
    resolution.write_note(&mut builder);
    builder.finish()
}

/// The title and brief of the suggestion a sent message holds.
pub(crate) fn read(doc: &Doc) -> Option<(String, Option<String>)> {
    doc.blocks.iter().find_map(|block| match &block.kind {
        Some(proto::block::Kind::TaskSuggestion(task)) => Some((
            slice(&doc.text, task.title.as_ref()?)?,
            task.brief
                .as_ref()
                .and_then(|brief| slice(&doc.text, brief)),
        )),
        _ => None,
    })
}

#[cfg(test)]
pub(super) fn sample(input: &serde_json::Value) -> Vec<super::golden::Message> {
    use super::DecisionState;
    use super::golden::{Message, button};
    use crate::bridge::v2::render::ActionStyle;

    let title = input["title"].as_str().expect("title");
    let brief = input["brief"].as_str();
    let open = card(title, brief, &Resolution::pending(), None);
    assert_eq!(
        read(&open),
        Some((title.to_owned(), brief.map(str::to_owned))),
        "Start reads the card back"
    );
    let started = card(
        title,
        brief,
        &Resolution::decided(DecisionState::Accepted, Some(7), "Started by Dena"),
        Some(4242),
    );
    vec![
        Message::new(
            "open",
            open,
            vec![
                button(START, START_LABEL, ActionStyle::Primary),
                button(DISMISS, DISMISS_LABEL, ActionStyle::Default),
            ],
        ),
        Message::new("started", started, Vec::new()),
    ]
}
