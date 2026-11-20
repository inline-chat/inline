//! Native agent surfaces as typed Inline blocks.
//!
//! Claude and ChatGPT/Codex draw parts of an agent's work as cards of their
//! own: the pinned task list, a plan to approve, an approval, a question,
//! review findings, a suggested task, the next-step box, suggested prompts.
//! A *recipe* turns one native surface into its own Inline block (never a
//! generic card standing in for it), together with the fallback text that
//! apps without the block read instead.
//!
//! # Recipes
//!
//! | Native surface | Recipe | Block | Fixtures |
//! |---|---|---|---|
//! | Claude `TodoWrite`, Codex `update_plan` (`turn/plan/updated`) | [`plan::pinned`] | `steps`, untitled, at the bottom of the progress message | `plan/` |
//! | Claude `ExitPlanMode` approval, Codex proposed plan (`plan` item) | [`plan_proposal::card`] | `plan_proposal` | `plan_proposal/` |
//! | Command, file-change, tool, permission and network approvals | [`approval::card`] | `approval` | `approval/` |
//! | Claude AskUserQuestion, Codex `request_user_input` | [`question::card`] | `form` with header, preview and recommended; one-choice questions as buttons | `question/` |
//! | Codex review mode (`exitedReviewMode`) | [`review::codex`] | `review`, else Markdown | `review/` |
//! | Inline tool `report_findings` | [`review::reported`] | `review` | `report_findings/` |
//! | Inline tool `suggest_thread` | [`task::card`] | `task_suggestion`; Start runs `spawn_thread` | `suggest_thread/` |
//! | Inline tool `ask_next_step` | [`next_step::card`] | `next_step`; a button answers as input | `ask_next_step/` |
//! | Inline tool `suggest_prompts` | [`prompts::card`] | `prompt_suggestions` | `suggest_prompts/` |
//!
//! # Adding the next surface
//!
//! 1. The block is in `proto/core.proto` with its fallback-text contract
//!    (spec Part 3 steps 1–5: proto, exhaustive switches, server, corpus,
//!    views).
//! 2. Add `<surface>.rs` here: a pure function from the harness item,
//!    interaction or tool arguments to a [`Doc`]. Write readable fallback
//!    text with [`DocBuilder`] and record the block's ranges as you go;
//!    labels that only older apps need (`"Command: "`) go in with
//!    [`DocBuilder::push_raw`].
//! 3. Buttons are ordinary `Message.actions` entries that the block names in
//!    `action_ids`, so older apps keep working buttons under the message.
//!    Interaction decisions use [`action_id`]; other buttons use their own
//!    fixed ids. A decision edits the message with [`resolve`] (or the recipe
//!    rebuilt with a [`Resolution`]) and clears the actions.
//! 4. Commit a captured or representative native sample as
//!    `fixtures/<recipe>/<case>.json` and register the recipe in
//!    `golden::RECIPES`. `INLINE_BLOCK_GOLDENS=update cargo test -p
//!    inline-cli --bin inline blocks::` writes `<case>.golden.json` beside
//!    it; read it, then commit both.
//! 5. Wire it up: the renderer for harness surfaces, `tools.rs` (plus the
//!    tool catalog and the agent guide) for Inline tools, and the runtime for
//!    what its buttons do.

use inline_protocol::proto;

use super::doc::{Doc, DocBuilder};

pub(crate) mod approval;
pub(crate) mod markdown;
pub(crate) mod next_step;
pub(crate) mod plan;
pub(crate) mod plan_proposal;
pub(crate) mod prompts;
pub(crate) mod question;
pub(crate) mod review;
pub(crate) mod task;

#[cfg(test)]
mod golden;

pub(crate) use proto::BlockDecisionState as DecisionState;

/// The `Message.actions` id of an interaction's decision `index`, as the
/// work's approval buttons are built.
pub(crate) fn action_id(index: usize) -> String {
    format!("v2-{index}")
}

/// The ids of `count` decision buttons.
pub(crate) fn action_ids(count: usize) -> Vec<String> {
    (0..count).map(action_id).collect()
}

/// Where a request to a person stands, for the block's `state`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Resolution {
    pub state: DecisionState,
    /// Who decided, for "Approved by X".
    pub by: Option<i64>,
    /// The outcome in words, appended as a footer for apps that read only
    /// the text ("Yes, proceed (answered by Dena)").
    pub note: Option<String>,
}

impl Resolution {
    pub(crate) fn pending() -> Self {
        Self {
            state: DecisionState::Pending,
            by: None,
            note: None,
        }
    }

    pub(crate) fn decided(state: DecisionState, by: Option<i64>, note: impl Into<String>) -> Self {
        Self {
            state,
            by,
            note: Some(note.into()),
        }
    }

    pub(crate) fn is_pending(&self) -> bool {
        self.state == DecisionState::Pending
    }

    /// The block's buttons: none once decided.
    pub(crate) fn action_ids(&self, ids: &[String]) -> Vec<String> {
        if self.is_pending() {
            ids.to_vec()
        } else {
            Vec::new()
        }
    }

    /// The outcome line under the block.
    pub(crate) fn write_note(&self, builder: &mut DocBuilder) {
        if let Some(note) = self.note.as_deref().filter(|note| !note.trim().is_empty()) {
            builder.footer(note);
        }
    }
}

/// Whether a decision block (plan proposal, approval, task suggestion, next
/// step) still waits on someone: pending, with live buttons. Decided,
/// expired and superseded blocks have none.
fn waiting(kind: &proto::block::Kind) -> bool {
    use proto::block::Kind;
    let pending = |state: i32, action_ids: &[String]| {
        state == DecisionState::Pending as i32 && !action_ids.is_empty()
    };
    match kind {
        Kind::PlanProposal(plan) => pending(plan.state, &plan.action_ids),
        Kind::Approval(approval) => pending(approval.state, &approval.action_ids),
        Kind::TaskSuggestion(task) => pending(task.state, &task.action_ids),
        Kind::NextStep(next) => !next.action_ids.is_empty(),
        _ => false,
    }
}

/// The message holds a decision block that still waits on someone, so a
/// button press on it may act. A second press, or one on a card a newer
/// plan replaced, finds none.
pub(crate) fn is_pending(doc: &Doc) -> bool {
    doc.blocks
        .iter()
        .any(|block| block.kind.as_ref().is_some_and(waiting))
}

/// Edits a sent message's decision block (plan proposal, approval, task
/// suggestion, next step) to its outcome: the new state, who decided, no
/// buttons (send it with the message's actions cleared), and `note` as a
/// footer for apps that read only the text. `started` is the thread a task
/// suggestion started in. Only a block still pending is decided, so the
/// first decision wins and deciding again adds no second footer. False when
/// the message holds no pending decision block.
pub(crate) fn resolve(
    doc: &mut Doc,
    state: DecisionState,
    by: Option<i64>,
    started: Option<i64>,
    note: Option<&str>,
) -> bool {
    use proto::block::Kind;
    let mut found = false;
    for block in &mut doc.blocks {
        if !block.kind.as_ref().is_some_and(waiting) {
            continue;
        }
        match &mut block.kind {
            Some(Kind::PlanProposal(plan)) => {
                plan.state = state as i32;
                plan.decided_by_user_id = by;
                plan.action_ids.clear();
                found = true;
            }
            Some(Kind::Approval(approval)) => {
                approval.state = state as i32;
                approval.decided_by_user_id = by;
                approval.action_ids.clear();
                found = true;
            }
            Some(Kind::TaskSuggestion(task)) => {
                task.state = state as i32;
                if let Some(chat_id) = started {
                    task.started_peer = Some(chat_peer(chat_id));
                }
                task.action_ids.clear();
                found = true;
            }
            Some(Kind::NextStep(next)) => {
                next.action_ids.clear();
                next.blocking = false;
                found = true;
            }
            _ => {}
        }
    }
    if found && let Some(note) = note {
        doc.append_footer(note);
    }
    found
}

/// The text a block range covers.
pub(crate) fn slice(text: &str, span: &proto::BlockText) -> Option<String> {
    let units: Vec<u16> = text.encode_utf16().collect();
    let start = usize::try_from(span.offset).ok()?;
    let end = start.checked_add(usize::try_from(span.length).ok()?)?;
    String::from_utf16(units.get(start..end)?).ok()
}

pub(crate) fn chat_peer(chat_id: i64) -> proto::Peer {
    proto::Peer {
        r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id })),
    }
}

/// A sent message as a [`Doc`] to edit.
pub(crate) fn message_doc(message: &proto::Message) -> Doc {
    Doc {
        text: message.message.clone().unwrap_or_default(),
        blocks: message
            .block_content
            .as_ref()
            .map(|content| content.blocks.clone())
            .unwrap_or_default(),
        markdown: false,
        entities: message
            .entities
            .as_ref()
            .map(|entities| entities.entities.clone())
            .unwrap_or_default(),
    }
}

/// The first line of `text`, at most `max` characters.
pub(crate) fn clip(text: &str, max: usize) -> String {
    let line = text
        .lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("")
        .trim();
    if line.chars().count() > max {
        format!("{}…", line.chars().take(max).collect::<String>())
    } else {
        line.to_owned()
    }
}

/// At most `max` characters of a long text, marked where it was cut.
pub(crate) fn head(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_owned();
    }
    let shown: String = text.chars().take(max).collect();
    format!("{shown}…")
}

/// The longest prefix of `text` within `max` UTF-16 units, cut on a
/// character boundary: Inline counts its limits in UTF-16, so a character
/// outside the BMP counts twice.
pub(crate) fn utf16_prefix(text: &str, max: usize) -> &str {
    let mut units = 0;
    for (index, character) in text.char_indices() {
        units += character.len_utf16();
        if units > max {
            return &text[..index];
        }
    }
    text
}

/// `text` within `max` UTF-16 units, ending in "…" where it was cut.
pub(crate) fn fit_utf16(text: &str, max: usize) -> String {
    if text.encode_utf16().count() <= max {
        return text.to_owned();
    }
    let mut shown = utf16_prefix(text, max.saturating_sub(1)).to_owned();
    shown.push('…');
    shown
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decided_doc() -> Doc {
        let doc = plan_proposal::card(
            "Claude",
            "# Fix the parser\n\n1. Read it\n2. Fix it",
            &action_ids(2),
            &Resolution::pending(),
        );
        assert!(matches!(
            &doc.blocks[0].kind,
            Some(proto::block::Kind::PlanProposal(plan)) if plan.action_ids == ["v2-0", "v2-1"]
        ));
        doc
    }

    #[test]
    fn resolving_sets_the_state_and_who_and_drops_the_buttons() {
        let mut doc = decided_doc();
        let before = doc.text.clone();
        assert!(resolve(
            &mut doc,
            DecisionState::Accepted,
            Some(7),
            None,
            Some("Approved by Dena")
        ));
        let Some(proto::block::Kind::PlanProposal(plan)) = &doc.blocks[0].kind else {
            panic!("plan");
        };
        assert_eq!(plan.state, DecisionState::Accepted as i32);
        assert_eq!(plan.decided_by_user_id, Some(7));
        assert!(plan.action_ids.is_empty());
        // The text keeps every earlier range and gains the outcome.
        assert_eq!(doc.text, format!("{before}\nApproved by Dena"));
        let Some(proto::block::Kind::Footer(footer)) = &doc.blocks[1].kind else {
            panic!("footer");
        };
        assert_eq!(
            slice(&doc.text, footer).as_deref(),
            Some("Approved by Dena")
        );
    }

    #[test]
    fn a_decided_block_is_never_decided_again() {
        let mut doc = decided_doc();
        assert!(is_pending(&doc));
        assert!(resolve(
            &mut doc,
            DecisionState::Accepted,
            Some(7),
            None,
            Some("Approved by Dena")
        ));
        assert!(!is_pending(&doc));
        let decided = doc.clone();
        // A second press, a Keep planning after Approve, or superseding a
        // card already approved: nothing changes, no second footer.
        for state in [
            DecisionState::Accepted,
            DecisionState::Declined,
            DecisionState::Superseded,
        ] {
            assert!(!resolve(&mut doc, state, Some(8), None, Some("Again")));
            assert_eq!(doc, decided);
        }
    }

    #[test]
    fn a_superseded_plan_loses_its_buttons() {
        let mut doc = decided_doc();
        assert!(resolve(
            &mut doc,
            DecisionState::Superseded,
            None,
            None,
            Some("Replaced by a newer plan")
        ));
        let Some(proto::block::Kind::PlanProposal(plan)) = &doc.blocks[0].kind else {
            panic!("plan");
        };
        assert_eq!(plan.state, DecisionState::Superseded as i32);
        assert!(plan.action_ids.is_empty());
        assert!(!is_pending(&doc));
    }

    #[test]
    fn an_answered_next_step_is_answered_once() {
        let mut doc = next_step::card("Fixed it.", Some("Commit?"), &["Commit".to_owned()]);
        assert!(is_pending(&doc));
        assert!(resolve(
            &mut doc,
            DecisionState::Accepted,
            Some(7),
            None,
            Some("Commit (answered by Dena)")
        ));
        let answered = doc.clone();
        assert!(!is_pending(&doc));
        assert!(!resolve(
            &mut doc,
            DecisionState::Accepted,
            Some(7),
            None,
            Some("Commit (answered by Dena)")
        ));
        assert_eq!(doc, answered);
    }

    #[test]
    fn utf16_cuts_count_units_and_keep_characters_whole() {
        assert_eq!(utf16_prefix("a😀b", 2), "a");
        assert_eq!(utf16_prefix("a😀b", 3), "a😀");
        assert_eq!(utf16_prefix("abc", 10), "abc");
        let label = "😀".repeat(40);
        let fitted = fit_utf16(&label, 64);
        assert!(fitted.encode_utf16().count() <= 64);
        assert!(fitted.ends_with('…'));
        assert_eq!(fitted.chars().filter(|c| *c == '😀').count(), 31);
        assert_eq!(fit_utf16("Approve", 64), "Approve");
    }

    #[test]
    fn resolving_a_task_names_its_thread_and_a_message_without_one_is_left() {
        let mut doc = task::card(
            "Profile the sidebar",
            Some("Find why it lags"),
            &Resolution::pending(),
            None,
        );
        assert!(resolve(
            &mut doc,
            DecisionState::Accepted,
            Some(7),
            Some(42),
            None
        ));
        let Some(proto::block::Kind::TaskSuggestion(task)) = &doc.blocks[0].kind else {
            panic!("task");
        };
        assert_eq!(task.started_peer, Some(chat_peer(42)));
        assert_eq!(task.state, DecisionState::Accepted as i32);
        let mut plain = Doc::default();
        plain.append_paragraph("hello");
        assert!(!resolve(
            &mut plain,
            DecisionState::Declined,
            None,
            None,
            Some("no")
        ));
        assert_eq!(plain.text, "hello");
    }
}
