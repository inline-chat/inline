//! Session events to Inline messages (spec §6).
//!
//! Pure: the runtime feeds envelopes in order and performs the returned
//! operations (send, edit, reply), coalescing progress edits as today.
//!
//! - **Detailed**: the agent's prose between calls, and the calls between two
//!   pieces of prose as one group titled in the harness's words ("Read 3
//!   files, ran 2 commands"), each call a collapsible row inside it (sub-agent
//!   rows nest their items), plus a separate final answer. Reasoning is never
//!   a row: Codex's headers are the live status, and Claude's thinking that
//!   has text is prose.
//! - **Friendly**: no progress cards; only the harness's short prose updates
//!   (Codex commentary and reasoning summaries, Claude's text between tools and
//!   `SendUserMessage`), then the final answer.
//! - **Steer split**: when a steer is consumed, the current progress message
//!   ends ("Worked for 48s") and the agent's next output starts a new one.
//! - Approvals, questions and errors are cards in both modes.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use inline_agent_bridge::harness::{
    ApprovalSubject, ChildRef, ClosedBy, CommandAction, Decision, DecisionKind, Envelope, Event,
    FieldAnswer, FieldInput, FileChangeKind, FileDiff, InputFact, InputId, Interaction,
    InteractionId, InteractionKind, Item, ItemBody, ItemKind, ItemStatus, ItemUpdate, MessageRole,
    NoticeLevel, OutputMode, QuestionForm, TurnPhase,
};
use inline_agent_bridge::{AgentMessagePhase, PlanStep, TurnId, TurnOutcome};
use serde_json::Value;

pub(crate) use super::blocks::question::{QUESTION_FORM_ID, pick_card, pickable, takes_reply};
use super::blocks::{self, DecisionState, Resolution};
use super::doc::{ActivityKind, CalloutKind, DiffChange, Doc, DocBuilder, Elapsed, Status};
use super::limits;

/// Harness vocabulary for row titles.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Vocabulary {
    Codex,
    Claude,
    OpenCode,
    Amp,
}

/// A model told to "stay quiet" in a followed thread sometimes answers with
/// a marker instead of nothing ("(quiet)", "[no reply]"). Posting it would
/// be the opposite of quiet.
fn is_quiet_marker(text: &str) -> bool {
    let text = text
        .trim()
        .trim_matches(|character: char| {
            matches!(character, '(' | ')' | '[' | ']' | '*' | '_' | '.' | '…')
        })
        .trim()
        .to_ascii_lowercase();
    matches!(
        text.as_str(),
        "quiet"
            | "staying quiet"
            | "stay quiet"
            | "silent"
            | "no reply"
            | "no response"
            | "nothing to add"
    )
}

/// One message operation for the runtime.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum RenderOp {
    /// Create (first time) or silently edit the progress message `slot`.
    Progress { slot: u32, doc: Doc },
    /// Last edit of progress message `slot`; it no longer changes.
    EndProgress { slot: u32, doc: Doc },
    /// A short Friendly update message.
    Update { doc: Doc },
    /// The final answer: a separate message that notifies.
    Final { doc: Doc },
    /// A Codex plan to approve, after the turn that proposed it, with the
    /// `plan_proposal` buttons (approve, keep planning).
    PlanProposal { doc: Doc },
    /// An approval or question card. `form` is set for questions.
    Card {
        interaction: InteractionId,
        doc: Doc,
        actions: Vec<CardAction>,
        form: Option<QuestionForm>,
    },
    /// The card's interaction closed; edit it to its resolution.
    CardClosed {
        interaction: InteractionId,
        doc: Doc,
    },
    /// A warning or error outside a card.
    Notice { doc: Doc },
}

/// One button on a card, carrying the harness's own label.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct CardAction {
    pub decision: String,
    pub label: String,
    pub style: ActionStyle,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ActionStyle {
    Default,
    Primary,
    Destructive,
}

/// A row's detail in the message: the end of its output, as Codex's
/// previews show it.
const MAX_DETAIL_CHARS: usize = 2_000;
/// Diffs one file-change row shows before listing the remaining files by name.
const MAX_ROW_DIFF_CHARS: usize = 8_000;

#[derive(Clone, Debug)]
struct Row {
    id: String,
    kind: ItemKind,
    parent: Option<String>,
    body: Option<ItemBody>,
    status: Status,
    delta: String,
    phase: Option<AgentMessagePhase>,
}

#[derive(Clone, Debug)]
struct Slot {
    id: u32,
    started_ms: u64,
    rows: Vec<Row>,
}

/// Renders one session's stream.
pub(crate) struct Renderer {
    mode: OutputMode,
    vocabulary: Vocabulary,
    agent: String,
    next_slot: u32,
    slot: Option<Slot>,
    /// The time of the envelope being applied.
    now_ms: u64,
    /// The work's folder: paths under it show relative, as the harnesses do.
    folder: Option<PathBuf>,
    turn: Option<TurnId>,
    turn_started_ms: u64,
    turn_slots: u32,
    turn_inputs: Vec<InputId>,
    pending_text: Option<(String, String)>,
    final_answer: Option<String>,
    interactions: HashMap<InteractionId, Interaction>,
    /// The changes an open approval is about, for its card when it closes.
    card_diffs: HashMap<InteractionId, Vec<FileDiff>>,
    /// Answers sent from Inline to an open question, for its card when it
    /// closes. Secret answers are never kept.
    card_answers: HashMap<InteractionId, Vec<FieldAnswer>>,
    /// People who answered cards, by user ID.
    names: HashMap<i64, String>,
    /// The main agent's latest task list this turn, pinned under its
    /// progress (Claude `TodoWrite`, Codex `update_plan`).
    plan: Option<Vec<PlanStep>>,
    /// A plan Codex proposed this turn, to approve after it.
    proposed_plan: Option<String>,
    /// Codex's review this turn, as it wrote it.
    review: Option<String>,
}

impl Renderer {
    pub(crate) fn new(mode: OutputMode, vocabulary: Vocabulary, agent: impl Into<String>) -> Self {
        Self {
            mode,
            vocabulary,
            agent: agent.into(),
            next_slot: 1,
            slot: None,
            now_ms: 0,
            folder: None,
            turn: None,
            turn_started_ms: 0,
            turn_slots: 0,
            turn_inputs: Vec::new(),
            pending_text: None,
            final_answer: None,
            interactions: HashMap::new(),
            card_diffs: HashMap::new(),
            card_answers: HashMap::new(),
            names: HashMap::new(),
            plan: None,
            proposed_plan: None,
            review: None,
        }
    }

    pub(crate) fn mode(&self) -> OutputMode {
        self.mode
    }

    pub(crate) fn vocabulary(&self) -> Vocabulary {
        self.vocabulary
    }

    pub(crate) fn set_mode(&mut self, mode: OutputMode) {
        self.mode = mode;
    }

    /// The folder the work runs in.
    pub(crate) fn set_folder(&mut self, folder: PathBuf) {
        self.folder = Some(folder);
    }

    /// Names a person who answers a card, for its resolution line.
    pub(crate) fn name_user(&mut self, user_id: i64, name: String) {
        self.names.insert(user_id, name);
    }

    /// The answers being sent to an open question, so its closed card keeps
    /// what was asked and what was answered. Secret answers are dropped here.
    pub(crate) fn note_answers(&mut self, interaction: &InteractionId, answers: &[FieldAnswer]) {
        let Some(Interaction {
            kind: InteractionKind::Question { form },
            ..
        }) = self.interactions.get(interaction)
        else {
            return;
        };
        let kept = answers
            .iter()
            .filter(|answer| {
                form.fields.iter().any(|field| {
                    field.id == answer.field && !matches!(field.input, FieldInput::Secret)
                })
            })
            .cloned()
            .collect();
        self.card_answers.insert(interaction.clone(), kept);
    }

    pub(crate) fn apply(&mut self, envelope: &Envelope) -> Vec<RenderOp> {
        let mut ops = Vec::new();
        let now = envelope.at_ms;
        self.now_ms = now;
        match &envelope.event {
            Event::Turn { turn, phase } => match phase {
                TurnPhase::Started { inputs } => {
                    self.turn = Some(turn.clone());
                    self.turn_started_ms = now;
                    self.turn_slots = 0;
                    self.turn_inputs = inputs.clone();
                    self.final_answer = None;
                    self.pending_text = None;
                    self.plan = None;
                    self.proposed_plan = None;
                    self.review = None;
                    // Detailed shows "Working" from the start, as v1 did,
                    // even for a turn that only answers.
                    if self.mode == OutputMode::Detailed {
                        self.open_slot(now);
                        self.push_progress(&mut ops);
                    }
                }
                TurnPhase::Completed {
                    outcome,
                    error,
                    duration_ms,
                    ..
                } => self.complete_turn(*outcome, error.as_deref(), *duration_ms, now, &mut ops),
            },
            Event::Input {
                id,
                fact: InputFact::Consumed { .. },
            } => {
                // The first input is the turn's own; later ones are steers.
                if self.turn_inputs.is_empty() {
                    self.turn_inputs.push(id.clone());
                } else if !self.turn_inputs.contains(id) {
                    self.turn_inputs.push(id.clone());
                    self.flush_pending_update(&mut ops);
                    let elapsed = self.slot_elapsed(now);
                    self.end_slot(elapsed, "Worked for", false, &mut ops);
                }
            }
            Event::Item(item) => self.item(item, now, &mut ops),
            Event::Interaction(interaction) => self.interaction(interaction, &mut ops),
            Event::InteractionClosed { id, by } => {
                if let Some(interaction) = self.interactions.remove(id) {
                    let diffs = self.card_diffs.remove(id).unwrap_or_default();
                    // Answers count only when Inline closed it.
                    let answers = self.card_answers.remove(id).unwrap_or_default();
                    let answers = match by {
                        ClosedBy::Inline { .. } => answers,
                        _ => Vec::new(),
                    };
                    ops.push(RenderOp::CardClosed {
                        interaction: id.clone(),
                        doc: closed_card(
                            &self.agent,
                            &interaction,
                            by,
                            &self.names,
                            &ClosedDetail {
                                diffs: &diffs,
                                answers: &answers,
                            },
                            self.folder.as_deref(),
                        ),
                    });
                }
                self.mark_rows_waiting(None);
            }
            // Errors are shown in both modes; warnings (config, deprecations)
            // stay in the logs instead of becoming chat messages.
            Event::Notice(notice) if notice.level == NoticeLevel::Error => {
                let mut builder = DocBuilder::new();
                let kind = if notice.level == NoticeLevel::Error {
                    CalloutKind::Error
                } else {
                    CalloutKind::Warning
                };
                builder.callout(
                    kind,
                    &notice.code,
                    notice.message.as_deref().unwrap_or_default(),
                );
                ops.push(RenderOp::Notice {
                    doc: builder.finish(),
                });
            }
            // Events were lost: the open progress message may be wrong, so
            // it ends here and the next output starts a fresh one.
            Event::Gap { .. } => {
                let elapsed = self.slot_elapsed(now);
                self.end_slot(
                    elapsed,
                    "Some updates were skipped · worked for",
                    false,
                    &mut ops,
                );
            }
            _ => {}
        }
        ops
    }

    fn item(&mut self, item: &Item, now: u64, ops: &mut Vec<RenderOp>) {
        let id = item.id.to_string();
        // User message echoes are the person's own messages; never re-rendered.
        if let Some(ItemBody::Message {
            role: MessageRole::User | MessageRole::System,
            ..
        }) = item.update.body()
        {
            return;
        }
        self.surfaces(item);
        let is_message = item.kind == ItemKind::Message;
        if self.mode == OutputMode::Friendly {
            self.friendly_item(item, &id, ops);
            return;
        }
        if !is_message {
            self.flush_pending_update(ops);
        }
        self.open_slot(now);
        let slot = self.slot.as_mut().expect("slot");
        let parent = item
            .parent
            .as_ref()
            .map(|child: &ChildRef| child.id.to_string());
        let row = match slot.rows.iter_mut().position(|row| row.id == id) {
            Some(index) => &mut slot.rows[index],
            None => {
                slot.rows.push(Row {
                    id: id.clone(),
                    kind: item.kind,
                    parent,
                    body: None,
                    status: Status::Running,
                    delta: String::new(),
                    phase: None,
                });
                slot.rows.last_mut().expect("row")
            }
        };
        if item.phase.is_some() {
            row.phase = item.phase;
        }
        match &item.update {
            ItemUpdate::Started { body } | ItemUpdate::Updated { body } => {
                row.body = Some(body.clone());
            }
            ItemUpdate::Delta { delta } => row.delta.push_str(&delta.text),
            ItemUpdate::Completed { body, status } => {
                row.body = Some(body.clone());
                row.delta.clear();
                row.status = match status {
                    ItemStatus::Completed => Status::Done,
                    ItemStatus::Failed => Status::Failed,
                    ItemStatus::Declined | ItemStatus::Interrupted => Status::Cancelled,
                    ItemStatus::Unknown => Status::None,
                };
            }
        }
        // Final answers leave the progress message for their own message.
        if row.kind == ItemKind::Message
            && let Some(ItemBody::Message { text, .. }) = &row.body
            && matches!(item.update, ItemUpdate::Completed { .. })
        {
            if row.phase == Some(AgentMessagePhase::FinalAnswer) {
                self.final_answer = Some(text.clone());
            } else if row.phase.is_none() {
                self.pending_text = Some((id.clone(), text.clone()));
            }
        }
        self.push_progress(ops);
    }

    /// Items that are their own surface: the task list pinned under the
    /// progress, a Codex plan to approve, a Codex review.
    fn surfaces(&mut self, item: &Item) {
        let Some(body) = item.update.body() else {
            return;
        };
        match body {
            ItemBody::Plan { steps, .. } if item.parent.is_none() && !steps.is_empty() => {
                self.plan = Some(steps.clone());
            }
            ItemBody::Plan {
                steps,
                text: Some(text),
                ..
            } if self.vocabulary == Vocabulary::Codex
                && item.parent.is_none()
                && steps.is_empty()
                && !text.trim().is_empty()
                && matches!(item.update, ItemUpdate::Completed { .. }) =>
            {
                self.proposed_plan = Some(text.clone());
            }
            ItemBody::Review { text } if item.parent.is_none() && !text.trim().is_empty() => {
                self.review = Some(text.clone());
            }
            _ => {}
        }
    }

    fn open_slot(&mut self, now: u64) {
        if self.slot.is_none() {
            self.slot = Some(Slot {
                id: self.next_slot,
                started_ms: now,
                rows: Vec::new(),
            });
            self.next_slot += 1;
            self.turn_slots += 1;
        }
    }

    /// Creates or edits the open progress message. Near a server limit the
    /// message ends and the rest continues in a new one.
    fn push_progress(&mut self, ops: &mut Vec<RenderOp>) {
        let Some(id) = self.slot.as_ref().map(|slot| slot.id) else {
            return;
        };
        let doc = self.progress_doc();
        if limits::progress_fits(&doc) || !self.split_slot(ops) {
            ops.push(RenderOp::Progress { slot: id, doc });
            return;
        }
        if let Some(slot) = &self.slot {
            ops.push(RenderOp::Progress {
                slot: slot.id,
                doc: self.progress_doc(),
            });
        }
    }

    /// Ends the open message with the longest run of finished rows that fits,
    /// and opens a new one with the rest. False when no finished row leads.
    fn split_slot(&mut self, ops: &mut Vec<RenderOp>) -> bool {
        let Some(slot) = self.slot.as_ref() else {
            return false;
        };
        let elapsed = self.slot_elapsed(self.now_ms);
        let summary = format!("Worked for {} · continued below", elapsed_text(elapsed));
        let tops: Vec<usize> = slot
            .rows
            .iter()
            .enumerate()
            .filter(|(_, row)| row.parent.is_none())
            .map(|(index, _)| index)
            .collect();
        // A row the message doesn't show (Codex's plan, which never
        // completes) doesn't hold the split back.
        let finished = tops
            .iter()
            .take_while(|&&index| {
                let row = &slot.rows[index];
                !matches!(row.status, Status::Running | Status::Waiting) || !self.shows(row)
            })
            .count();
        // A longer prefix is never smaller, so the longest that fits is found
        // by bisection.
        let fits = |count: usize| {
            let part = subset(slot, &tops[..count]);
            limits::progress_fits(&self.ended_doc(&part, &summary, false))
        };
        let (mut low, mut high) = (0, finished);
        while low < high {
            let middle = (low + high).div_ceil(2);
            if fits(middle) {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        if low == 0 {
            return false;
        }
        let kept = subset(slot, &tops[..low]);
        let carried = Slot {
            id: self.next_slot,
            started_ms: self.now_ms,
            rows: slot
                .rows
                .iter()
                .filter(|row| !kept.rows.iter().any(|kept| kept.id == row.id))
                .cloned()
                .collect(),
        };
        ops.push(RenderOp::EndProgress {
            slot: slot.id,
            doc: self.ended_doc(&kept, &summary, false),
        });
        self.next_slot += 1;
        self.turn_slots += 1;
        self.slot = Some(carried);
        true
    }

    /// A finished message: closed, under its summary, and with `plan` the
    /// turn's task list under it, compact.
    fn ended_doc(&self, slot: &Slot, summary: &str, plan: bool) -> Doc {
        let mut builder = DocBuilder::new();
        if slot.rows.is_empty() {
            builder.footer(summary);
        } else {
            builder.progress(summary, false, None, |inner| self.write_slot(inner, slot));
        }
        if plan && let Some(steps) = &self.plan {
            blocks::plan::pinned(&mut builder, steps, true);
        }
        builder.finish()
    }

    fn friendly_item(&mut self, item: &Item, id: &str, ops: &mut Vec<RenderOp>) {
        let ItemUpdate::Completed { body, .. } = &item.update else {
            return;
        };
        match body {
            ItemBody::Message { text, .. } => match item.phase {
                Some(AgentMessagePhase::FinalAnswer) => self.final_answer = Some(text.clone()),
                Some(AgentMessagePhase::Commentary) => ops.push(update(text)),
                _ => {
                    self.flush_pending_update(ops);
                    self.pending_text = Some((id.to_owned(), text.clone()));
                }
            },
            ItemBody::Reasoning { summary, .. } if has_text(summary) => {
                self.flush_pending_update(ops);
                ops.push(update(&summary.join("\n\n")));
            }
            ItemBody::Tool { name, input, .. } if name == "SendUserMessage" => {
                self.flush_pending_update(ops);
                if let Some(message) = input.get("message").and_then(Value::as_str) {
                    ops.push(update(message));
                }
            }
            _ => self.flush_pending_update(ops),
        }
    }

    /// A held text was not the turn's last, so it was an update.
    fn flush_pending_update(&mut self, ops: &mut Vec<RenderOp>) {
        if let Some((id, text)) = self.pending_text.take() {
            if self.mode == OutputMode::Friendly {
                ops.push(update(&text));
            } else if let Some(slot) = &mut self.slot
                && let Some(row) = slot.rows.iter_mut().find(|row| row.id == id)
            {
                row.phase = Some(AgentMessagePhase::Commentary);
            }
        }
    }

    fn interaction(&mut self, interaction: &Interaction, ops: &mut Vec<RenderOp>) {
        match &interaction.kind {
            // Inline has no card for it. Codex cancels it; OpenCode keeps it
            // open in its own app. Either way the chat says so.
            InteractionKind::Dialog { dialog } => {
                let next = match self.vocabulary {
                    Vocabulary::OpenCode => "Answer it in OpenCode.",
                    _ => "It was cancelled.",
                };
                let mut builder = DocBuilder::new();
                builder.callout(
                    CalloutKind::Warning,
                    "Inline can't show this request yet",
                    &format!("{} asked for `{dialog}`. {next}", self.agent),
                );
                ops.push(RenderOp::Notice {
                    doc: builder.finish(),
                });
            }
            InteractionKind::Approval { subject, decisions } => {
                self.mark_rows_waiting(interaction.item.as_ref().map(ToString::to_string));
                let actions = card_actions(subject, decisions);
                let diffs = self.item_diffs(interaction.item.as_ref().map(ToString::to_string));
                let doc = blocks::approval::card(
                    &self.agent,
                    subject,
                    &diffs,
                    self.folder.as_deref(),
                    &blocks::action_ids(actions.len()),
                    &Resolution::pending(),
                );
                ops.push(RenderOp::Card {
                    interaction: interaction.id.clone(),
                    doc,
                    actions,
                    form: None,
                });
                self.card_diffs.insert(interaction.id.clone(), diffs);
                self.interactions
                    .insert(interaction.id.clone(), interaction.clone());
            }
            InteractionKind::Question { form } => {
                ops.push(RenderOp::Card {
                    interaction: interaction.id.clone(),
                    doc: blocks::question::card(&self.agent, form),
                    actions: Vec::new(),
                    form: Some(form.clone()),
                });
                self.interactions
                    .insert(interaction.id.clone(), interaction.clone());
            }
        }
        self.push_progress(ops);
    }

    /// The changes of the item an approval is about, when the harness
    /// reported them (a Codex file change before its approval).
    fn item_diffs(&self, item: Option<String>) -> Vec<FileDiff> {
        let Some(item) = item else {
            return Vec::new();
        };
        self.slot
            .iter()
            .flat_map(|slot| &slot.rows)
            .find(|row| row.id == item)
            .and_then(|row| match &row.body {
                Some(ItemBody::FileChange { changes }) => Some(changes.clone()),
                _ => None,
            })
            .unwrap_or_default()
    }

    fn mark_rows_waiting(&mut self, item: Option<String>) {
        if let Some(slot) = &mut self.slot {
            for row in &mut slot.rows {
                if item.as_deref() == Some(row.id.as_str()) {
                    row.status = Status::Waiting;
                } else if item.is_none() && row.status == Status::Waiting {
                    row.status = Status::Running;
                }
            }
        }
    }

    fn end_slot(&mut self, elapsed_ms: u64, verb: &str, plan: bool, ops: &mut Vec<RenderOp>) {
        let Some(id) = self.slot.as_ref().map(|slot| slot.id) else {
            return;
        };
        let Some(slot) = self.slot.take() else {
            return;
        };
        // Codex notes failures on a collapsed group; a failure a later run
        // fixed is not one.
        let failed = unresolved_failures(&slot);
        let summary = match failed {
            0 => format!("{verb} {}", elapsed_text(elapsed_ms)),
            count => format!("{verb} {} · {count} failed", elapsed_text(elapsed_ms)),
        };
        let mut rows = DocBuilder::new();
        self.write_slot(&mut rows, &slot);
        // Nothing but the answer happened: a quiet "Worked for 2s" line, as
        // v1 left it, and the answer follows.
        let doc = if rows.is_empty() {
            self.ended_doc(
                &Slot {
                    rows: Vec::new(),
                    ..slot.clone()
                },
                &summary,
                plan,
            )
        } else {
            self.ended_doc(&slot, &summary, plan)
        };
        ops.push(RenderOp::EndProgress { slot: id, doc });
    }

    fn slot_elapsed(&self, now: u64) -> u64 {
        self.slot
            .as_ref()
            .map_or(0, |slot| now.saturating_sub(slot.started_ms))
    }

    fn complete_turn(
        &mut self,
        outcome: TurnOutcome,
        error: Option<&str>,
        duration_ms: Option<u64>,
        now: u64,
        ops: &mut Vec<RenderOp>,
    ) {
        // The last held text is the answer when the harness names no final phase.
        if self.final_answer.is_none()
            && let Some((id, text)) = self.pending_text.take()
        {
            if let Some(slot) = &mut self.slot {
                slot.rows.retain(|row| row.id != id);
            }
            self.final_answer = Some(text);
        }
        let verb = match outcome {
            TurnOutcome::Interrupted => "Stopped after",
            TurnOutcome::Failed | TurnOutcome::ConnectionLost => "Failed after",
            _ => "Worked for",
        };
        // One progress message for the whole turn uses the turn's own time.
        let elapsed = if self.turn_slots <= 1 {
            duration_ms.unwrap_or_else(|| now.saturating_sub(self.turn_started_ms))
        } else {
            self.slot_elapsed(now)
        };
        self.end_slot(elapsed, verb, true, ops);
        self.turn_slots = 0;
        let answer = self
            .final_answer
            .take()
            .filter(|text| !text.trim().is_empty() && !is_quiet_marker(text));
        // Codex repeats its review as the answer: it goes out once, as a
        // review block.
        match (self.review.take(), answer) {
            (Some(review), Some(answer)) if review.trim() == answer.trim() => {
                ops.push(RenderOp::Final {
                    doc: blocks::review::codex(&review, self.folder.as_deref()),
                });
            }
            (review, answer) => {
                if let Some(review) = review {
                    ops.push(RenderOp::Final {
                        doc: blocks::review::codex(&review, self.folder.as_deref()),
                    });
                }
                if let Some(answer) = answer {
                    ops.push(RenderOp::Final {
                        doc: Doc::markdown(&answer),
                    });
                }
            }
        }
        if let Some(plan) = self.proposed_plan.take()
            && outcome == TurnOutcome::Completed
        {
            ops.push(RenderOp::PlanProposal {
                doc: blocks::plan_proposal::card(
                    &self.agent,
                    &plan,
                    &[
                        blocks::plan_proposal::APPROVE.to_owned(),
                        blocks::plan_proposal::KEEP_PLANNING.to_owned(),
                    ],
                    &Resolution::pending(),
                ),
            });
        }
        if let Some(error) = error
            && matches!(
                outcome,
                TurnOutcome::Failed | TurnOutcome::AuthenticationRequired
            )
        {
            // The person sees the callout; log it too so a provider that keeps
            // failing (expired login, usage limit, crash) reaches Sentry.
            if outcome == TurnOutcome::AuthenticationRequired {
                log::warn!(target: "inline::bridge::v2", "provider login failed: {error}");
            } else {
                log::warn!(target: "inline::bridge::v2", "turn failed: {error}");
            }
            let mut builder = DocBuilder::new();
            builder.callout(CalloutKind::Error, "The turn failed", error);
            ops.push(RenderOp::Notice {
                doc: builder.finish(),
            });
        }
        self.turn = None;
        self.turn_inputs.clear();
    }

    fn progress_doc(&self) -> Doc {
        let mut builder = DocBuilder::new();
        let elapsed = self.slot.as_ref().map(|slot| {
            (
                (slot.started_ms / 1000) as i64,
                elapsed_text(self.now_ms.saturating_sub(slot.started_ms)),
            )
        });
        let elapsed = elapsed.as_ref().map(|(started_at, text)| Elapsed {
            started_at: *started_at,
            text,
        });
        builder.progress(&self.status_line(), true, elapsed, |inner| {
            self.write_rows(inner)
        });
        if let Some(steps) = &self.plan {
            blocks::plan::pinned(&mut builder, steps, false);
        }
        builder.finish()
    }

    fn write_rows(&self, builder: &mut DocBuilder) {
        if let Some(slot) = &self.slot {
            self.write_slot(builder, slot);
        }
    }

    /// Top-level rows as Claude Code and Codex draw a turn: the agent's own
    /// prose stays as text, and the calls between two pieces of prose form
    /// one group titled in the harness's words. Reasoning never splits a
    /// group: Claude's thinking that has text is written for the reader, so
    /// it is prose, and Codex's reasoning headers are the live status.
    fn write_slot(&self, builder: &mut DocBuilder, slot: &Slot) {
        let mut group: Vec<&Row> = Vec::new();
        for row in slot
            .rows
            .iter()
            .filter(|row| row.parent.is_none() && self.shows(row))
        {
            if self.is_prose(row) {
                self.write_group(builder, slot, &group);
                group.clear();
                self.write_row(builder, slot, row);
            } else {
                group.push(row);
            }
        }
        self.write_group(builder, slot, &group);
    }

    /// One group: a lone call, or one run of reads and searches, as itself;
    /// more under a title such as "Read 3 files, ran 2 commands".
    fn write_group(&self, builder: &mut DocBuilder, slot: &Slot, rows: &[&Row]) {
        let units = units(rows);
        let running = rows
            .iter()
            .any(|row| matches!(row.status, Status::Running | Status::Waiting));
        let title = (units.len() > 1)
            .then(|| group_title(self.vocabulary, rows, running))
            .filter(|title| !title.is_empty());
        let Some(title) = title else {
            for unit in &units {
                self.write_unit(builder, slot, unit);
            }
            return;
        };
        let (added, removed) = rows
            .iter()
            .filter_map(|row| match &row.body {
                Some(ItemBody::FileChange { changes }) => Some(changes.iter()),
                _ => None,
            })
            .flatten()
            .map(line_counts)
            .fold((0, 0), |(a, r), (added, removed)| (a + added, r + removed));
        let status = if rows.iter().any(|row| row.status == Status::Waiting) {
            Status::Waiting
        } else if running {
            Status::Running
        } else {
            Status::Done
        };
        builder.disclosure(
            &title,
            counts_meta(added, removed).as_deref(),
            self.group_activity(rows),
            status,
            |inner| {
                for unit in &units {
                    self.write_unit(inner, slot, unit);
                }
            },
        );
    }

    /// A run of reads and searches folds into one row as the harness folds
    /// it (Claude Code leaves a lone read as its own row); any other call is
    /// its own row.
    fn write_unit(&self, builder: &mut DocBuilder, slot: &Slot, unit: &[&Row]) {
        if explores(unit) && (self.vocabulary != Vocabulary::Claude || unit.len() > 1) {
            self.write_explore(builder, unit);
        } else {
            for row in unit {
                self.write_row(builder, slot, row);
            }
        }
    }

    /// The group's icon: its rows' kind when they share one.
    fn group_activity(&self, rows: &[&Row]) -> ActivityKind {
        let mut kinds = rows
            .iter()
            .filter_map(|row| row.body.as_ref().map(activity));
        let Some(first) = kinds.next() else {
            return ActivityKind::Unspecified;
        };
        if kinds.all(|kind| kind == first) {
            first
        } else {
            ActivityKind::Unspecified
        }
    }

    /// Rows a message shows: an answer, a text still in doubt, or reasoning
    /// is not one, except Claude's thinking that has text, which is an
    /// update written for the reader (Claude Code omits its real thinking).
    fn shows(&self, row: &Row) -> bool {
        let held_message = row.kind == ItemKind::Message
            && (row.phase == Some(AgentMessagePhase::FinalAnswer)
                || row.phase.is_none() && row.body.is_some());
        let hidden_reasoning = row.kind == ItemKind::Reasoning
            && (self.vocabulary != Vocabulary::Claude || reasoning_text(row).is_none());
        // The main agent's task list is pinned under the rows instead; a
        // review goes out as its own message.
        let pinned_plan = row.parent.is_none()
            && matches!(&row.body, Some(ItemBody::Plan { steps, .. }) if !steps.is_empty());
        let review = row.kind == ItemKind::Review;
        !(held_message || hidden_reasoning || pinned_plan || review)
    }

    /// The agent's text between calls: commentary, and Claude's thinking
    /// that has text.
    fn is_prose(&self, row: &Row) -> bool {
        row.kind == ItemKind::Message
            || self.vocabulary == Vocabulary::Claude && row.kind == ItemKind::Reasoning
    }

    /// The live status while working: Codex's latest reasoning header, as
    /// its status line shows it, or "Thinking" while Claude thinks.
    fn status_line(&self) -> String {
        let Some(slot) = &self.slot else {
            return "Working".to_owned();
        };
        let mut tops = slot.rows.iter().filter(|row| row.parent.is_none());
        match self.vocabulary {
            Vocabulary::Claude => match tops.next_back() {
                Some(row)
                    if row.kind == ItemKind::Reasoning
                        && row.status == Status::Running
                        && reasoning_text(row).is_none() =>
                {
                    "Thinking".to_owned()
                }
                _ => "Working".to_owned(),
            },
            _ => tops
                .rev()
                .filter(|row| row.kind == ItemKind::Reasoning)
                .find_map(reasoning_header)
                .unwrap_or_else(|| "Working".to_owned()),
        }
    }

    /// One row for a run of reads, searches and listings, in the harness's
    /// words: Codex's "Explored" with its Read, Search and List lines, or
    /// Claude Code's "Searched for 2 patterns, read 3 files".
    fn write_explore(&self, builder: &mut DocBuilder, run: &[&Row]) {
        let running = run
            .iter()
            .any(|row| matches!(row.status, Status::Running | Status::Waiting));
        let failed = run.iter().filter(|row| explore_failed(row)).count();
        let folder = self.folder.as_deref();
        let (title, lines) = match self.vocabulary {
            Vocabulary::Codex | Vocabulary::OpenCode | Vocabulary::Amp => (
                if running { "Exploring" } else { "Explored" }.to_owned(),
                codex_explore_lines(run, folder),
            ),
            Vocabulary::Claude => (
                claude_explore_title(run, running),
                run.iter()
                    .filter_map(|row| row.body.as_ref())
                    .map(|body| row_title(self.vocabulary, folder, body).0)
                    .collect(),
            ),
        };
        let meta = match failed {
            0 => None,
            count => Some(format!("{count} failed")),
        };
        let status = if running {
            Status::Running
        } else {
            Status::Done
        };
        builder.disclosure(
            &title,
            meta.as_deref(),
            ActivityKind::Explore,
            status,
            |inner| {
                for line in &lines {
                    inner.paragraph(line);
                }
            },
        );
    }

    fn write_row(&self, builder: &mut DocBuilder, slot: &Slot, row: &Row) {
        if row.kind == ItemKind::Message {
            if row.phase == Some(AgentMessagePhase::FinalAnswer)
                || row.phase.is_none() && row.body.is_some()
            {
                return;
            }
            let text = match &row.body {
                Some(ItemBody::Message { text, .. }) => text.clone(),
                _ => row.delta.clone(),
            };
            // A widget streams as its title; its HTML belongs to the answer.
            // Prose is Markdown, styled here as Inline styles an answer.
            blocks::markdown::write(builder, &inline_agent_bridge::widget::preview(&text));
            return;
        }
        // Claude's thinking that has text is an update, so it reads as prose.
        if row.kind == ItemKind::Reasoning {
            if let Some(text) = reasoning_text(row) {
                blocks::markdown::write(builder, &tail(&text));
            }
            return;
        }
        let Some(body) = row.body.clone() else {
            // Streaming before the first snapshot: show the text as it grows.
            let label = match row.kind {
                ItemKind::Command => "Running a command",
                ItemKind::Reasoning => "Thinking",
                ItemKind::FileChange => "Editing files",
                ItemKind::Plan => "Plan",
                _ => "Working",
            };
            builder.disclosure(
                label,
                None,
                ActivityKind::Unspecified,
                row.status,
                |inner| {
                    if row.kind == ItemKind::Reasoning {
                        inner.paragraph(&tail(&row.delta));
                    } else {
                        inner.code(&tail(&row.delta), None);
                    }
                },
            );
            return;
        };
        let (title, meta, activity) = row_title(self.vocabulary, self.folder.as_deref(), &body);
        let children: Vec<&Row> = match &body {
            ItemBody::Child { child, .. } => slot
                .rows
                .iter()
                .filter(|candidate| {
                    candidate.parent.as_deref() == Some(child.id.as_str()) && self.shows(candidate)
                })
                .collect(),
            _ => Vec::new(),
        };
        builder.disclosure(&title, meta.as_deref(), activity, row.status, |inner| {
            row_detail(inner, &body, &row.delta, self.folder.as_deref());
            for child in children {
                self.write_row(inner, slot, child);
            }
        });
    }
}

/// Rows in order, with each run of reads, searches and listings together.
fn units<'a>(rows: &[&'a Row]) -> Vec<Vec<&'a Row>> {
    let mut units: Vec<Vec<&Row>> = Vec::new();
    for &row in rows {
        match units.last_mut() {
            Some(last) if explores(&[row]) && explores(last) => last.push(row),
            _ => units.push(vec![row]),
        }
    }
    units
}

/// A call's kind, for a group's icon; reads and searches are exploring.
fn activity(body: &ItemBody) -> ActivityKind {
    match body {
        _ if is_exploration(body) => ActivityKind::Explore,
        ItemBody::Command { .. } => ActivityKind::Command,
        ItemBody::FileChange { .. } => ActivityKind::Edit,
        ItemBody::Tool {
            name, server: None, ..
        } if is_agent_tool(name) => ActivityKind::Agent,
        ItemBody::Tool { name, .. } => tool_activity(name),
        ItemBody::Child { .. } => ActivityKind::Agent,
        _ => ActivityKind::Unspecified,
    }
}

/// Claude Code's sub-agent tool (`Task` before it was renamed `Agent`).
fn is_agent_tool(name: &str) -> bool {
    matches!(name, "Agent" | "Task")
}

fn tool_activity(name: &str) -> ActivityKind {
    match name {
        "Read" | "view_image" => ActivityKind::Read,
        "Grep" | "Glob" => ActivityKind::Search,
        "WebFetch" | "WebSearch" | "web_search" => ActivityKind::Web,
        _ => ActivityKind::Tool,
    }
}

fn explores(rows: &[&Row]) -> bool {
    rows.iter()
        .all(|row| row.body.as_ref().is_some_and(is_exploration))
}

/// A group's title in the harness's words: Claude Code counts ("Edited 2
/// files, read 3 files, ran 4 commands…" while live), the Codex app names
/// the kinds ("Read files, edited files, ran commands").
fn group_title(vocabulary: Vocabulary, rows: &[&Row], running: bool) -> String {
    let mut tally = Tally::default();
    for row in rows {
        tally.add(row);
    }
    let parts = match vocabulary {
        Vocabulary::Claude => tally.claude(running),
        Vocabulary::Codex | Vocabulary::OpenCode | Vocabulary::Amp => tally.codex(running),
    };
    let line = parts.join(", ");
    let mut title = line
        .get(..1)
        .map(|first| first.to_uppercase() + &line[1..])
        .unwrap_or(line);
    if running && vocabulary == Vocabulary::Claude && !title.is_empty() {
        title.push('…');
    }
    title
}

/// What a group did, by kind.
#[derive(Default)]
struct Tally {
    files: Vec<PathBuf>,
    searches: usize,
    reads: usize,
    lists: usize,
    /// MCP calls by server, in first-call order.
    servers: Vec<(String, usize)>,
    agents: usize,
    loads: usize,
    tools: usize,
    commands: usize,
}

impl Tally {
    fn add(&mut self, row: &Row) {
        let Some(body) = &row.body else {
            return;
        };
        match body {
            ItemBody::FileChange { changes } => {
                for change in changes {
                    if !self.files.contains(&change.path) {
                        self.files.push(change.path.clone());
                    }
                }
            }
            ItemBody::Command { actions, .. } if is_exploration(body) => {
                for action in actions {
                    match action {
                        CommandAction::Read { .. } => self.reads += 1,
                        CommandAction::Search { .. } => self.searches += 1,
                        CommandAction::ListFiles { .. } => self.lists += 1,
                        CommandAction::Unknown { .. } => {}
                    }
                }
            }
            ItemBody::Command { .. } => self.commands += 1,
            ItemBody::Tool {
                server: Some(server),
                ..
            } => match self.servers.iter_mut().find(|(name, _)| name == server) {
                Some((_, count)) => *count += 1,
                None => self.servers.push((server.clone(), 1)),
            },
            ItemBody::Tool { name, .. } if is_agent_tool(name) => self.agents += 1,
            ItemBody::Tool { name, .. } => match name.as_str() {
                "Grep" | "Glob" => self.searches += 1,
                "Read" => self.reads += 1,
                "LS" => self.lists += 1,
                "ToolSearch" => self.loads += 1,
                _ => self.tools += 1,
            },
            ItemBody::Child { .. } => self.agents += 1,
            ItemBody::Plan { .. } => self.tools += 1,
            _ => {}
        }
    }

    /// Claude Code's order and words: "edited 2 files, searched for 1
    /// pattern, read 3 files, called inline 2 times, ran 4 commands".
    fn claude(&self, running: bool) -> Vec<String> {
        let counted = |count: usize, (live, done): (&str, &str), one: &str, many: &str| {
            (count > 0).then(|| {
                let verb = if running { live } else { done };
                let noun = if count == 1 { one } else { many };
                format!("{verb} {count} {noun}")
            })
        };
        let mut parts: Vec<Option<String>> = vec![
            counted(self.files.len(), ("editing", "edited"), "file", "files"),
            counted(
                self.searches,
                ("searching for", "searched for"),
                "pattern",
                "patterns",
            ),
            counted(self.reads, ("reading", "read"), "file", "files"),
            counted(
                self.lists,
                ("listing", "listed"),
                "directory",
                "directories",
            ),
        ];
        for (server, count) in &self.servers {
            let verb = if running { "calling" } else { "called" };
            let times = if *count == 1 {
                "once".to_owned()
            } else {
                format!("{count} times")
            };
            parts.push(Some(format!("{verb} {server} {times}")));
        }
        parts.push(counted(self.agents, ("running", "ran"), "agent", "agents"));
        let loaded = if running {
            "loading tools"
        } else {
            "loaded tools"
        };
        parts.push((self.loads > 0).then(|| loaded.to_owned()));
        parts.push(counted(self.tools, ("calling", "called"), "tool", "tools"));
        parts.push(counted(
            self.commands,
            ("running", "ran"),
            "command",
            "commands",
        ));
        parts.into_iter().flatten().collect()
    }

    /// The Codex app's kind words, without counts.
    fn codex(&self, running: bool) -> Vec<String> {
        let word = |count: usize, (live, done): (&str, &str), one: &str, many: &str| {
            (count > 0).then(|| {
                let verb = if running { live } else { done };
                let noun = if count == 1 { one } else { many };
                format!("{verb} {noun}")
            })
        };
        let calls =
            self.servers.iter().map(|(_, count)| count).sum::<usize>() + self.loads + self.tools;
        [
            word(
                self.reads + self.searches + self.lists,
                ("reading", "read"),
                "a file",
                "files",
            ),
            word(self.files.len(), ("editing", "edited"), "a file", "files"),
            word(self.commands, ("running", "ran"), "a command", "commands"),
            word(self.agents, ("running", "ran"), "an agent", "agents"),
            word(calls, ("calling", "called"), "a tool", "tools"),
        ]
        .into_iter()
        .flatten()
        .collect()
    }
}

/// Reasoning text, summary or streamed, when it has any.
fn reasoning_text(row: &Row) -> Option<String> {
    let text = match &row.body {
        Some(ItemBody::Reasoning { summary, .. }) if has_text(summary) => summary.join("\n\n"),
        _ => row.delta.clone(),
    };
    (!text.trim().is_empty()).then_some(text)
}

/// The header a reasoning summary leads with: its last bold title
/// ("**Tracing the lock error**"), or its first line.
fn reasoning_header(row: &Row) -> Option<String> {
    let text = reasoning_text(row)?;
    let segments: Vec<&str> = text.split("**").collect();
    let bold = (1..segments.len().saturating_sub(1))
        .step_by(2)
        .rev()
        .map(|index| segments[index].trim())
        .find(|segment| !segment.is_empty());
    let header = match bold {
        Some(bold) => first_line(bold, 80),
        None => first_line(&text, 80),
    };
    (!header.is_empty()).then_some(header)
}

fn has_text(parts: &[String]) -> bool {
    parts.iter().any(|part| !part.trim().is_empty())
}

/// Reads, searches and listings: Codex's parsed command actions, Claude's
/// Read, Grep, Glob and LS tools.
fn is_exploration(body: &ItemBody) -> bool {
    match body {
        ItemBody::Command { actions, .. } => {
            !actions.is_empty()
                && actions
                    .iter()
                    .all(|action| !matches!(action, CommandAction::Unknown { .. }))
        }
        ItemBody::Tool {
            name, server: None, ..
        } => matches!(name.as_str(), "Read" | "Grep" | "Glob" | "LS"),
        _ => false,
    }
}

/// A failed read or search. A search that found nothing exits 1, which
/// Codex does not count as a failure.
fn explore_failed(row: &Row) -> bool {
    match &row.body {
        Some(ItemBody::Command {
            exit_code: Some(code),
            actions,
            ..
        }) if *code != 0 => {
            !(*code == 1
                && actions
                    .iter()
                    .any(|action| matches!(action, CommandAction::Search { .. })))
        }
        Some(ItemBody::Tool { error: Some(_), .. }) => true,
        _ => row.status == Status::Failed,
    }
}

/// Codex's exploring lines: consecutive reads merge into one "Read a, b".
fn codex_explore_lines(run: &[&Row], folder: Option<&Path>) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    let mut reads: Vec<String> = Vec::new();
    let flush = |reads: &mut Vec<String>, lines: &mut Vec<String>| {
        if !reads.is_empty() {
            lines.push(format!("Read {}", reads.join(", ")));
            reads.clear();
        }
    };
    for row in run {
        let Some(ItemBody::Command {
            actions, exit_code, ..
        }) = &row.body
        else {
            continue;
        };
        let failed = explore_failed(row);
        for action in actions {
            match action {
                CommandAction::Read { path } if !failed => {
                    let name = Path::new(path)
                        .file_name()
                        .map_or_else(|| path.clone(), |name| name.to_string_lossy().into_owned());
                    if !reads.contains(&name) {
                        reads.push(name);
                    }
                }
                CommandAction::Read { path } => {
                    flush(&mut reads, &mut lines);
                    lines.push(format!("Read {}", relative(path, folder)));
                }
                CommandAction::Search { query, path } => {
                    flush(&mut reads, &mut lines);
                    lines.push(match (query, path) {
                        (Some(query), Some(path)) => {
                            format!("Search {query} in {}", relative(path, folder))
                        }
                        (Some(query), None) => format!("Search {query}"),
                        (None, Some(path)) => format!("Search in {}", relative(path, folder)),
                        (None, None) => "Search".to_owned(),
                    });
                }
                CommandAction::ListFiles { path } => {
                    flush(&mut reads, &mut lines);
                    lines.push(format!(
                        "List {}",
                        path.as_deref()
                            .map_or_else(|| ".".to_owned(), |path| relative(path, folder))
                    ));
                }
                CommandAction::Unknown { .. } => {}
            }
        }
        if failed {
            flush(&mut reads, &mut lines);
            if let (Some(code), Some(last)) = (exit_code, lines.last_mut()) {
                last.push_str(&format!(" (exit {code})"));
            }
        }
    }
    flush(&mut reads, &mut lines);
    lines
}

/// Claude Code's collapsed line: "Searched for 2 patterns, read 3 files,
/// listed 1 directory", or "Searching for 2 patterns, reading 1 file…".
fn claude_explore_title(run: &[&Row], running: bool) -> String {
    let (mut searches, mut reads, mut lists) = (0, 0, 0);
    for row in run {
        if let Some(ItemBody::Tool { name, .. }) = &row.body {
            match name.as_str() {
                "Grep" | "Glob" => searches += 1,
                "Read" => reads += 1,
                "LS" => lists += 1,
                _ => {}
            }
        }
    }
    let mut parts: Vec<String> = Vec::new();
    for (count, active, done, one, many) in [
        (
            searches,
            "searching for",
            "searched for",
            "pattern",
            "patterns",
        ),
        (reads, "reading", "read", "file", "files"),
        (lists, "listing", "listed", "directory", "directories"),
    ] {
        if count == 0 {
            continue;
        }
        let word = if running { active } else { done };
        let noun = if count == 1 { one } else { many };
        parts.push(format!("{word} {count} {noun}"));
    }
    let line = parts.join(", ");
    let mut title = line
        .get(..1)
        .map(|first| first.to_uppercase() + &line[1..])
        .unwrap_or(line);
    if running {
        title.push('…');
    }
    title
}

/// Failed commands no later command with the same text fixed.
fn unresolved_failures(slot: &Slot) -> usize {
    let commands: Vec<(&str, i32)> = slot
        .rows
        .iter()
        .filter_map(|row| match &row.body {
            Some(
                body @ ItemBody::Command {
                    command,
                    exit_code: Some(code),
                    ..
                },
            ) if !is_exploration(body) => Some((command.as_str(), *code)),
            _ => None,
        })
        .collect();
    commands
        .iter()
        .enumerate()
        .filter(|(index, (command, code))| {
            *code != 0
                && !commands[index + 1..]
                    .iter()
                    .any(|(later, code)| later == command && *code == 0)
        })
        .count()
}

/// A path under the work's folder, relative to it.
fn relative(path: &str, folder: Option<&Path>) -> String {
    folder
        .and_then(|folder| Path::new(path).strip_prefix(folder).ok())
        .filter(|path| !path.as_os_str().is_empty())
        .map_or_else(|| path.to_owned(), |path| path.display().to_string())
}

/// Lines added and removed, as Codex counts a change.
fn line_counts(change: &FileDiff) -> (usize, usize) {
    let Some(diff) = change.diff.as_deref() else {
        return (0, 0);
    };
    let hunks = diff.lines().any(|line| line.starts_with("@@"));
    match change.change {
        FileChangeKind::Add if !hunks => (diff.lines().count(), 0),
        FileChangeKind::Delete if !hunks => (0, diff.lines().count()),
        _ => diff.lines().fold((0, 0), |(added, removed), line| {
            if line.starts_with("+++") || line.starts_with("---") {
                (added, removed)
            } else if line.starts_with('+') {
                (added + 1, removed)
            } else if line.starts_with('-') {
                (added, removed + 1)
            } else {
                (added, removed)
            }
        }),
    }
}

fn counts_meta(added: usize, removed: usize) -> Option<String> {
    (added + removed > 0).then(|| format!("+{added} −{removed}"))
}

/// The given top-level rows with every row nested under them, in order.
fn subset(slot: &Slot, tops: &[usize]) -> Slot {
    let mut keep: Vec<bool> = vec![false; slot.rows.len()];
    let mut parents: Vec<String> = Vec::new();
    for &index in tops {
        keep[index] = true;
        if let Some(ItemBody::Child { child, .. }) = &slot.rows[index].body {
            parents.push(child.id.to_string());
        }
    }
    // Children of kept sub-agents, and theirs, until nothing new joins.
    while let Some(parent) = parents.pop() {
        for (index, row) in slot.rows.iter().enumerate() {
            if !keep[index] && row.parent.as_deref() == Some(parent.as_str()) {
                keep[index] = true;
                if let Some(ItemBody::Child { child, .. }) = &row.body {
                    parents.push(child.id.to_string());
                }
            }
        }
    }
    Slot {
        id: slot.id,
        started_ms: slot.started_ms,
        rows: slot
            .rows
            .iter()
            .zip(keep)
            .filter(|(_, keep)| *keep)
            .map(|(row, _)| row.clone())
            .collect(),
    }
}

fn update(text: &str) -> RenderOp {
    RenderOp::Update {
        doc: Doc::markdown(text),
    }
}

fn elapsed_text(ms: u64) -> String {
    let seconds = ms / 1000;
    if seconds < 60 {
        format!("{}s", seconds.max(1))
    } else if seconds < 3600 {
        format!("{}m {}s", seconds / 60, seconds % 60)
    } else {
        format!("{}h {}m", seconds / 3600, (seconds % 3600) / 60)
    }
}

fn first_line(text: &str, max: usize) -> String {
    let line = text
        .lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("")
        .trim();
    let line = line.trim_matches('*').trim();
    if line.chars().count() > max {
        format!("{}…", line.chars().take(max).collect::<String>())
    } else {
        line.to_owned()
    }
}

/// The end of a long text from a line start, with the hidden line count, as
/// Codex's output previews show it ("… +120 lines").
/// Hides credentials (assignments, auth headers, secret flags, URL
/// passwords) and local paths before agent work is shown in a chat that
/// people other than the owner may read.
fn scrub(text: &str) -> String {
    inline_agent_bridge::sanitize_diagnostic_text(text).unwrap_or_default()
}

fn tail(text: &str) -> String {
    let count = text.chars().count();
    if count <= MAX_DETAIL_CHARS {
        return text.to_owned();
    }
    let cut = text
        .char_indices()
        .nth(count - MAX_DETAIL_CHARS)
        .map_or(0, |(index, _)| index);
    let start = match text[cut..].find('\n') {
        Some(offset) if cut + offset + 1 < text.len() => cut + offset + 1,
        _ => cut,
    };
    let hidden = text[..start].lines().count().max(1);
    let noun = if hidden == 1 { "line" } else { "lines" };
    format!("… +{hidden} {noun}\n{}", &text[start..])
}

/// Row summary, meta and activity in the harness's own vocabulary.
fn row_title(
    vocabulary: Vocabulary,
    folder: Option<&Path>,
    body: &ItemBody,
) -> (String, Option<String>, ActivityKind) {
    match body {
        ItemBody::Command {
            command,
            actions,
            duration_ms,
            exit_code,
            ..
        } => {
            let time = duration_ms.map(|ms| elapsed_text(ms.max(1000)));
            let meta = match (exit_code.filter(|code| *code != 0), time) {
                (Some(code), Some(time)) => Some(format!("exit {code} · {time}")),
                (Some(code), None) => Some(format!("exit {code}")),
                (None, time) => time,
            };
            let exploring = !actions.is_empty()
                && actions
                    .iter()
                    .all(|action| !matches!(action, CommandAction::Unknown { .. }));
            match vocabulary {
                Vocabulary::Codex | Vocabulary::OpenCode | Vocabulary::Amp if exploring => (
                    "Explored".to_owned(),
                    Some(explore_meta(actions)),
                    ActivityKind::Explore,
                ),
                Vocabulary::Codex | Vocabulary::OpenCode | Vocabulary::Amp => (
                    format!("Ran {}", first_line(&scrub(command), 80)),
                    meta,
                    ActivityKind::Command,
                ),
                Vocabulary::Claude => (
                    format!("Bash {}", first_line(&scrub(command), 80)),
                    meta,
                    ActivityKind::Command,
                ),
            }
        }
        ItemBody::FileChange { changes } => {
            let title = match changes.as_slice() {
                [only] => {
                    let verb = match (vocabulary, &only.change) {
                        (
                            Vocabulary::Codex | Vocabulary::OpenCode | Vocabulary::Amp,
                            FileChangeKind::Add,
                        ) => "Added",
                        (
                            Vocabulary::Codex | Vocabulary::OpenCode | Vocabulary::Amp,
                            FileChangeKind::Delete,
                        ) => "Deleted",
                        (Vocabulary::Codex | Vocabulary::OpenCode | Vocabulary::Amp, _) => "Edited",
                        (Vocabulary::Claude, FileChangeKind::Add) => "Write",
                        (Vocabulary::Claude, _) => "Edit",
                    };
                    format!(
                        "{verb} {}",
                        relative(&only.path.display().to_string(), folder)
                    )
                }
                many => format!("Edited {} files", many.len()),
            };
            let (added, removed) = changes
                .iter()
                .map(line_counts)
                .fold((0, 0), |(a, r), (added, removed)| (a + added, r + removed));
            let activity = if changes
                .iter()
                .all(|change| change.change == FileChangeKind::Delete)
                && !changes.is_empty()
            {
                ActivityKind::Delete
            } else {
                ActivityKind::Edit
            };
            (title, counts_meta(added, removed), activity)
        }
        ItemBody::Reasoning { summary, .. } => {
            let title = summary
                .first()
                .map(|summary| first_line(summary, 80))
                .filter(|title| !title.is_empty())
                .unwrap_or_else(|| "Thinking".to_owned());
            (title, None, ActivityKind::Reasoning)
        }
        ItemBody::Tool {
            name,
            server: None,
            input,
            ..
        } if is_agent_tool(name) => {
            // Claude's sub-agent: named by the description it was given.
            let about = ["description", "prompt"]
                .iter()
                .find_map(|key| input.get(*key).and_then(Value::as_str))
                .map(|about| first_line(&scrub(about), 70))
                .filter(|about| !about.is_empty());
            let title = match about {
                Some(about) => format!("{name}: {about}"),
                None => name.clone(),
            };
            (title, None, ActivityKind::Agent)
        }
        ItemBody::Tool {
            name,
            server,
            input,
            ..
        } => {
            let argument = ["file_path", "path", "pattern", "query", "url", "command"]
                .iter()
                .find_map(|key| input.get(*key).and_then(Value::as_str))
                .map(|argument| first_line(&scrub(&relative(argument, folder)), 60));
            let title = match (vocabulary, server) {
                (Vocabulary::Codex | Vocabulary::OpenCode | Vocabulary::Amp, Some(server)) => {
                    format!("Called {server}.{name}")
                }
                _ => match argument {
                    Some(argument) => format!("{name} {argument}"),
                    None => name.clone(),
                },
            };
            (title, None, tool_activity(name))
        }
        ItemBody::Plan { steps, .. } if steps.is_empty() => (
            "Proposed a plan".to_owned(),
            None,
            ActivityKind::Unspecified,
        ),
        ItemBody::Plan { .. } => (
            match vocabulary {
                Vocabulary::Codex | Vocabulary::OpenCode | Vocabulary::Amp => "Updated Plan",
                Vocabulary::Claude => "Update Todos",
            }
            .to_owned(),
            None,
            ActivityKind::Unspecified,
        ),
        ItemBody::Review { .. } => ("Reviewed".to_owned(), None, ActivityKind::Unspecified),
        ItemBody::Child { action, prompt, .. } => {
            let label = match vocabulary {
                Vocabulary::Codex | Vocabulary::OpenCode | Vocabulary::Amp => "Sub-agent",
                Vocabulary::Claude => "Task",
            };
            let title = match prompt {
                Some(prompt) => format!("{label}: {}", first_line(prompt, 70)),
                None => label.to_owned(),
            };
            (title, action.clone(), ActivityKind::Agent)
        }
        ItemBody::Usage { label } => (label.clone(), None, ActivityKind::Unspecified),
        ItemBody::Error { message } => (first_line(message, 80), None, ActivityKind::Unspecified),
        ItemBody::Message { text, .. } => (first_line(text, 80), None, ActivityKind::Unspecified),
        ItemBody::Unknown {
            native_type,
            summary,
        } => (
            summary.clone().unwrap_or_else(|| native_type.clone()),
            Some(native_type.clone()),
            ActivityKind::Unspecified,
        ),
    }
}

fn explore_meta(actions: &[CommandAction]) -> String {
    let (mut reads, mut searches, mut lists) = (0, 0, 0);
    for action in actions {
        match action {
            CommandAction::Read { .. } => reads += 1,
            CommandAction::Search { .. } => searches += 1,
            CommandAction::ListFiles { .. } => lists += 1,
            CommandAction::Unknown { .. } => {}
        }
    }
    let mut parts = Vec::new();
    if reads > 0 {
        parts.push(format!("{reads} read"));
    }
    if searches > 0 {
        parts.push(format!("{searches} search"));
    }
    if lists > 0 {
        parts.push(format!("{lists} list"));
    }
    parts.join(", ")
}

/// The detail view: full command output, diffs, reasoning and tool payloads.
fn row_detail(builder: &mut DocBuilder, body: &ItemBody, delta: &str, folder: Option<&Path>) {
    match body {
        ItemBody::Command {
            command,
            actions,
            output,
            exit_code,
            ..
        } => {
            for action in actions {
                match action {
                    CommandAction::Read { path } => builder.paragraph(&format!("Read {path}")),
                    CommandAction::Search { query, path } => builder.paragraph(&format!(
                        "Search {}{}",
                        query.as_deref().unwrap_or(""),
                        path.as_deref()
                            .map(|path| format!(" in {path}"))
                            .unwrap_or_default()
                    )),
                    CommandAction::ListFiles { path } => {
                        builder.paragraph(&format!("List {}", path.as_deref().unwrap_or(".")));
                    }
                    CommandAction::Unknown { .. } => {}
                }
            }
            builder.code(&format!("$ {}", scrub(command)), Some("sh"));
            let output = output.as_deref().unwrap_or(delta);
            builder.code(&tail(&scrub(output)), None);
            if let Some(code) = exit_code.filter(|code| *code != 0) {
                builder.paragraph(&format!("Exit code {code}"));
            }
        }
        ItemBody::FileChange { changes } => {
            // Past a budget, later files list by name.
            let mut shown = 0;
            for change in changes {
                let kind = match &change.change {
                    FileChangeKind::Add => DiffChange::Added,
                    FileChangeKind::Delete => DiffChange::Deleted,
                    FileChangeKind::Update { moved_to: Some(_) } => DiffChange::Renamed,
                    FileChangeKind::Update { moved_to: None } => DiffChange::Modified,
                };
                let diff = change
                    .diff
                    .as_deref()
                    .filter(|_| shown < MAX_ROW_DIFF_CHARS)
                    .map(|diff| tail(&scrub(diff)));
                shown += diff.as_deref().map_or(0, str::len);
                builder.diff(
                    &relative(&change.path.display().to_string(), folder),
                    kind,
                    diff.as_deref(),
                );
            }
        }
        ItemBody::Reasoning { summary, .. } => {
            let text = if summary.is_empty() {
                delta.to_owned()
            } else {
                summary.join("\n\n")
            };
            builder.paragraph(&tail(&text));
        }
        ItemBody::Tool {
            input,
            output,
            error,
            ..
        } => {
            if !input.is_null() {
                builder.code(
                    &tail(&scrub(
                        &serde_json::to_string_pretty(input).unwrap_or_default(),
                    )),
                    Some("json"),
                );
            }
            if let Some(output) = output.as_deref().or((!delta.is_empty()).then_some(delta)) {
                builder.code(&tail(&scrub(output)), None);
            }
            if let Some(error) = error {
                builder.paragraph(&scrub(error));
            }
        }
        ItemBody::Plan {
            explanation,
            steps,
            text,
        } => {
            // A sub-agent's task list; the main agent's is pinned instead.
            if let Some(explanation) = explanation {
                builder.paragraph(explanation);
            }
            blocks::plan::pinned(builder, steps, false);
            // A proposed plan's text is on its card; only a streaming one
            // shows here.
            if text.as_deref().is_none_or(|text| text.trim().is_empty()) && !delta.is_empty() {
                builder.paragraph(&tail(delta));
            }
        }
        ItemBody::Error { message } => builder.paragraph(message),
        _ => {}
    }
}

/// An approval's buttons: a plan's read Approve and Keep planning.
fn card_actions(subject: &ApprovalSubject, decisions: &[Decision]) -> Vec<CardAction> {
    match subject {
        ApprovalSubject::Plan { .. } => blocks::plan_proposal::actions(decisions),
        _ => decisions.iter().map(card_action).collect(),
    }
}

pub(crate) fn card_action(decision: &Decision) -> CardAction {
    CardAction {
        decision: decision.id.to_string(),
        label: decision.label.clone(),
        style: match decision.kind {
            DecisionKind::Accept => ActionStyle::Primary,
            DecisionKind::Cancel | DecisionKind::DeclineAndRemember => ActionStyle::Destructive,
            _ => ActionStyle::Default,
        },
    }
}

/// What a closed card keeps from while it was open.
struct ClosedDetail<'a> {
    /// The changes an approval was about.
    diffs: &'a [FileDiff],
    /// The answers Inline sent to a question, secrets left out.
    answers: &'a [FieldAnswer],
}

/// A card whose interaction closed: an approval or plan keeps its block,
/// decided, with the outcome under it; a question keeps what it asked and
/// the answers, with the outcome under them.
fn closed_card(
    agent: &str,
    interaction: &Interaction,
    by: &ClosedBy,
    names: &HashMap<i64, String>,
    detail: &ClosedDetail<'_>,
    folder: Option<&Path>,
) -> Doc {
    let decided = match (by, &interaction.kind) {
        (
            ClosedBy::Inline {
                decision: Some(decision),
                ..
            },
            InteractionKind::Approval {
                subject, decisions, ..
            },
        ) => decisions
            .iter()
            .zip(card_actions(subject, decisions))
            .find(|(candidate, _)| &candidate.id == decision)
            .map(|(candidate, action)| (candidate.kind, action.label)),
        _ => None,
    };
    let (state, user, resolution) = match by {
        ClosedBy::Inline { user, .. } => {
            let name = names
                .get(&user.0)
                .cloned()
                .unwrap_or_else(|| format!("user {}", user.0));
            match &decided {
                Some((kind, label)) => (
                    decision_state(*kind),
                    Some(user.0),
                    format!("{label} (answered by {name})"),
                ),
                None => (
                    DecisionState::Unspecified,
                    Some(user.0),
                    format!("Answered by {name}"),
                ),
            }
        }
        ClosedBy::External => (
            DecisionState::Unspecified,
            None,
            "Answered outside Inline".to_owned(),
        ),
        ClosedBy::Cancelled => (DecisionState::Expired, None, "No longer needed".to_owned()),
    };
    match &interaction.kind {
        InteractionKind::Approval { subject, .. } => blocks::approval::card(
            agent,
            subject,
            detail.diffs,
            folder,
            &[],
            &Resolution {
                state,
                by: user,
                note: Some(resolution),
            },
        ),
        InteractionKind::Question { form } => {
            blocks::question::closed_card(agent, form, detail.answers, &resolution)
        }
        InteractionKind::Dialog { .. } => {
            let mut builder = DocBuilder::new();
            builder.footer(&resolution);
            builder.finish()
        }
    }
}

fn decision_state(kind: DecisionKind) -> DecisionState {
    match kind {
        DecisionKind::Accept | DecisionKind::AcceptForSession | DecisionKind::AcceptAndRemember => {
            DecisionState::Accepted
        }
        DecisionKind::Decline | DecisionKind::DeclineAndRemember | DecisionKind::Cancel => {
            DecisionState::Declined
        }
        DecisionKind::Other => DecisionState::Unspecified,
    }
}

#[cfg(test)]
mod quiet_tests {
    use super::*;

    #[test]
    fn quiet_markers_are_not_answers() {
        for text in [
            "(quiet)",
            " [no reply] ",
            "*staying quiet*",
            "Quiet.",
            "(nothing to add)",
        ] {
            assert!(is_quiet_marker(text), "{text}");
        }
        for text in [
            "Quiet hours start at 9.",
            "No reply from the server yet",
            "ok",
        ] {
            assert!(!is_quiet_marker(text), "{text}");
        }
    }

    #[test]
    fn a_quiet_turn_posts_no_answer() {
        let mut renderer = Renderer::new(OutputMode::Friendly, Vocabulary::OpenCode, "OpenCode");
        renderer.final_answer = Some("(quiet)".to_owned());
        renderer.turn = Some(TurnId::new("t").unwrap());
        let mut ops = Vec::new();
        renderer.complete_turn(TurnOutcome::Completed, None, None, 0, &mut ops);
        assert!(
            !ops.iter().any(|op| matches!(op, RenderOp::Final { .. })),
            "{ops:?}"
        );
        renderer.final_answer = Some("Done.".to_owned());
        let mut ops = Vec::new();
        renderer.complete_turn(TurnOutcome::Completed, None, None, 0, &mut ops);
        assert!(ops.iter().any(|op| matches!(op, RenderOp::Final { .. })));
    }
}

#[cfg(test)]
mod tests {
    use inline_agent_bridge::harness::{
        DeltaStream, FieldInput, ItemDelta, ItemId, SessionKey, TurnPhase,
    };
    use inline_agent_bridge::{ProviderId, ProviderSessionId};

    use super::*;

    fn envelope(seq: u64, at_ms: u64, event: Event) -> Envelope {
        Envelope {
            session: SessionKey {
                provider: ProviderId::new("codex").expect("provider"),
                session: ProviderSessionId::new("thr").expect("session"),
            },
            seq,
            checkpoint: None,
            at_ms,
            event,
        }
    }

    fn turn(phase: TurnPhase) -> Event {
        Event::Turn {
            turn: TurnId::new("t1").expect("turn"),
            phase,
        }
    }

    fn consumed(id: &str) -> Event {
        Event::Input {
            id: InputId::new(id).expect("input"),
            fact: InputFact::Consumed {
                turn: TurnId::new("t1").expect("turn"),
            },
        }
    }

    fn completed(id: &str, body: ItemBody, phase: Option<AgentMessagePhase>) -> Event {
        Event::Item(
            Item::new(
                ItemId::new(id).expect("id"),
                None,
                ItemUpdate::Completed {
                    body,
                    status: ItemStatus::Completed,
                },
                Value::Null,
            )
            .with_phase(phase),
        )
    }

    fn command(id: &str) -> Event {
        completed(
            id,
            ItemBody::Command {
                command: "cargo test".to_owned(),
                cwd: None,
                actions: Vec::new(),
                output: Some("ok".to_owned()),
                exit_code: Some(0),
                duration_ms: Some(1200),
            },
            None,
        )
    }

    fn message(text: &str) -> ItemBody {
        ItemBody::Message {
            role: MessageRole::Assistant,
            text: text.to_owned(),
            input: None,
        }
    }

    fn run(renderer: &mut Renderer, events: Vec<(u64, Event)>) -> Vec<RenderOp> {
        events
            .into_iter()
            .enumerate()
            .flat_map(|(index, (at, event))| renderer.apply(&envelope(index as u64 + 1, at, event)))
            .collect()
    }

    #[test]
    fn a_steer_ends_the_progress_message_and_the_next_output_starts_another() {
        let mut renderer = Renderer::new(OutputMode::Detailed, Vocabulary::Codex, "Codex");
        let ops = run(
            &mut renderer,
            vec![
                (0, turn(TurnPhase::Started { inputs: vec![] })),
                (0, consumed("in-1")),
                (1_000, command("c1")),
                (48_000, consumed("in-2")),
                (50_000, command("c2")),
                (
                    60_000,
                    completed("a1", message("Done."), Some(AgentMessagePhase::FinalAnswer)),
                ),
                (
                    60_000,
                    turn(TurnPhase::Completed {
                        outcome: TurnOutcome::Completed,
                        inputs_consumed: vec![],
                        error: None,
                        duration_ms: None,
                    }),
                ),
            ],
        );
        let ended: Vec<(u32, String)> = ops
            .iter()
            .filter_map(|op| match op {
                RenderOp::EndProgress { slot, doc, .. } => Some((*slot, doc.text.clone())),
                _ => None,
            })
            .collect();
        assert_eq!(ended.len(), 2);
        assert_eq!(ended[0].0, 1);
        assert!(ended[0].1.starts_with("Worked for 48s"), "{}", ended[0].1);
        assert_eq!(ended[1].0, 2);
        assert!(ended[1].1.contains("Ran cargo test"));
        assert!(
            !ended[1].1.contains("Done."),
            "the final answer is its own message"
        );
        assert!(matches!(ops.last(), Some(RenderOp::Final { doc }) if doc.text == "Done."));
    }

    fn outer(doc: &Doc) -> &inline_protocol::proto::BlockDisclosure {
        match doc.blocks[0].kind.as_ref() {
            Some(inline_protocol::proto::block::Kind::Disclosure(disclosure)) => disclosure,
            other => panic!("expected the progress row, got {other:?}"),
        }
    }

    #[test]
    fn progress_opens_as_working_at_the_turn_start_and_closes_to_its_time() {
        let mut renderer = Renderer::new(OutputMode::Detailed, Vocabulary::Codex, "Codex");
        let ops = run(
            &mut renderer,
            vec![
                (0, turn(TurnPhase::Started { inputs: vec![] })),
                (1_000, command("c1")),
                (
                    8_000,
                    turn(TurnPhase::Completed {
                        outcome: TurnOutcome::Completed,
                        inputs_consumed: vec![],
                        error: None,
                        duration_ms: Some(8_000),
                    }),
                ),
            ],
        );
        let RenderOp::Progress { slot: 1, doc } = &ops[0] else {
            panic!("the turn start posts Working: {ops:?}");
        };
        assert_eq!(doc.text, "Working · 1s");
        let working = outer(doc);
        assert_eq!(
            working.kind,
            inline_protocol::proto::block_disclosure::Kind::Progress as i32
        );
        assert_eq!(working.initially_open, Some(true));
        assert_eq!(working.started_at, Some(0));
        assert!(working.meta.is_some(), "the time as of this edit");
        let RenderOp::Progress { doc, .. } = &ops[1] else {
            panic!("rows edit the same message");
        };
        assert!(
            doc.text.starts_with("Working · ") && doc.text.contains("\nRan cargo test"),
            "{}",
            doc.text
        );
        assert_eq!(outer(doc).children.len(), 1);
        let RenderOp::EndProgress { slot: 1, doc, .. } = &ops[2] else {
            panic!("the turn end closes it: {ops:?}");
        };
        assert!(doc.text.starts_with("Worked for 8s"), "{}", doc.text);
        let done = outer(doc);
        assert_eq!(
            done.kind,
            inline_protocol::proto::block_disclosure::Kind::Default as i32
        );
        assert_eq!(done.initially_open, Some(false));
        assert_eq!(done.children.len(), 1);
    }

    #[test]
    fn friendly_mode_posts_only_prose_updates_then_the_answer() {
        let mut renderer = Renderer::new(OutputMode::Friendly, Vocabulary::Claude, "Claude");
        let ops = run(
            &mut renderer,
            vec![
                (0, turn(TurnPhase::Started { inputs: vec![] })),
                (
                    1,
                    completed("m1:0", message("Looking at the parser first."), None),
                ),
                (2, command("toolu_1")),
                (3, completed("m2:0", message("Fixed it."), None)),
                (
                    4,
                    turn(TurnPhase::Completed {
                        outcome: TurnOutcome::Completed,
                        inputs_consumed: vec![],
                        error: None,
                        duration_ms: Some(4),
                    }),
                ),
            ],
        );
        assert_eq!(
            ops,
            vec![
                update("Looking at the parser first."),
                RenderOp::Final {
                    doc: Doc::markdown("Fixed it."),
                },
            ]
        );
    }

    fn ran(index: &str, output: Option<String>) -> ItemBody {
        ItemBody::Command {
            command: format!("cargo test -p crate{index}"),
            cwd: None,
            actions: Vec::new(),
            exit_code: output.as_ref().map(|_| 0),
            duration_ms: output.as_ref().map(|_| 1000),
            output,
        }
    }

    #[test]
    fn a_long_turn_continues_in_new_messages_before_the_server_limits() {
        let mut renderer = Renderer::new(OutputMode::Detailed, Vocabulary::Codex, "Codex");
        let output = (0..400)
            .map(|line| format!("test result line {line}: ok"))
            .collect::<Vec<_>>()
            .join("\n");
        let mut events = vec![(0, turn(TurnPhase::Started { inputs: vec![] }))];
        for index in 0..300u64 {
            events.push((
                index + 1,
                completed(
                    &format!("c{index}"),
                    ran(&index.to_string(), Some(output.clone())),
                    None,
                ),
            ));
        }
        // Still running when its message would end: it moves to the next one.
        events.push((
            400,
            Event::Item(Item::new(
                ItemId::new("live").expect("id"),
                None,
                ItemUpdate::Started {
                    body: ran("live", None),
                },
                Value::Null,
            )),
        ));
        events.push((401, completed("live", ran("live", Some("ok".into())), None)));
        events.push((
            500,
            turn(TurnPhase::Completed {
                outcome: TurnOutcome::Completed,
                inputs_consumed: vec![],
                error: None,
                duration_ms: Some(500),
            }),
        ));
        let ops = run(&mut renderer, events);
        let mut ended = Vec::new();
        for op in &ops {
            match op {
                RenderOp::Progress { doc, .. } => {
                    assert!(limits::Size::of(doc).fits(), "{:?}", limits::Size::of(doc));
                }
                RenderOp::EndProgress { doc, .. } => {
                    assert!(limits::Size::of(doc).fits(), "{:?}", limits::Size::of(doc));
                    ended.push(doc.text.clone());
                }
                _ => {}
            }
        }
        assert!(ended.len() > 1, "the turn spans several messages");
        assert!(ended[0].starts_with("Worked for") && ended[0].contains("continued below"));
        let all = ended.concat();
        assert_eq!(
            all.matches("Ran cargo test -p crate").count(),
            301,
            "each row once"
        );
        assert!(
            ended
                .last()
                .expect("last")
                .contains("Ran cargo test -p cratelive")
        );
    }

    #[test]
    fn long_output_shows_its_end_with_the_hidden_line_count() {
        let text = (0..1000)
            .map(|line| format!("line {line}"))
            .collect::<Vec<_>>()
            .join("\n");
        let shown = tail(&text);
        assert!(shown.starts_with("… +"), "{shown}");
        assert!(shown.ends_with("line 999"));
        assert!(
            shown
                .lines()
                .nth(1)
                .expect("first kept")
                .starts_with("line ")
        );
        assert!(shown.chars().count() <= MAX_DETAIL_CHARS + 20);
    }

    fn reasoning(id: &str, text: &str) -> Event {
        completed(
            id,
            ItemBody::Reasoning {
                summary: vec![text.to_owned()],
                content: Vec::new(),
            },
            None,
        )
    }

    fn explore(id: &str, actions: Vec<CommandAction>, exit_code: i32) -> Event {
        completed(
            id,
            ItemBody::Command {
                command: "rg".to_owned(),
                cwd: None,
                actions,
                output: Some(String::new()),
                exit_code: Some(exit_code),
                duration_ms: Some(100),
            },
            None,
        )
    }

    fn shell(id: &str, command: &str, exit_code: i32) -> Event {
        completed(
            id,
            ItemBody::Command {
                command: command.to_owned(),
                cwd: None,
                actions: Vec::new(),
                output: Some("output".to_owned()),
                exit_code: Some(exit_code),
                duration_ms: Some(2000),
            },
            None,
        )
    }

    fn edited(id: &str, path: &str) -> Event {
        completed(
            id,
            ItemBody::FileChange {
                changes: vec![FileDiff {
                    path: path.into(),
                    change: FileChangeKind::Update { moved_to: None },
                    diff: Some("@@ -1 +1,2 @@\n-old\n+new\n+more".to_owned()),
                }],
            },
            None,
        )
    }

    fn ended_text(ops: &[RenderOp]) -> String {
        ops.iter()
            .find_map(|op| match op {
                RenderOp::EndProgress { doc, .. } => Some(doc.text.clone()),
                _ => None,
            })
            .expect("end")
    }

    #[test]
    fn thinking_without_text_draws_no_row() {
        let mut renderer = Renderer::new(OutputMode::Detailed, Vocabulary::Claude, "Claude");
        let ops = run(
            &mut renderer,
            vec![
                (0, turn(TurnPhase::Started { inputs: vec![] })),
                (1, reasoning("m1:0", "")),
                (2, command("toolu_1")),
                (3, reasoning("m2:0", "Checking the diff")),
                (4, command("toolu_2")),
                (
                    5,
                    turn(TurnPhase::Completed {
                        outcome: TurnOutcome::Completed,
                        inputs_consumed: vec![],
                        error: None,
                        duration_ms: Some(5),
                    }),
                ),
            ],
        );
        let text = ended_text(&ops);
        assert!(!text.contains("Thinking"), "{text}");
        assert!(text.contains("Checking the diff"), "{text}");
    }

    fn codex_turn(fixed: bool) -> String {
        let mut renderer = Renderer::new(OutputMode::Detailed, Vocabulary::Codex, "Codex");
        renderer.set_folder("/work".into());
        let mut events = vec![
            (0, turn(TurnPhase::Started { inputs: vec![] })),
            (1, reasoning("r1", "Tracing the lock error")),
            (
                2,
                explore(
                    "e1",
                    vec![CommandAction::Read {
                        path: "/work/cli/src/helpers.rs".into(),
                    }],
                    0,
                ),
            ),
            (
                3,
                explore(
                    "e2",
                    vec![CommandAction::Read {
                        path: "/work/cli/src/bridge.rs".into(),
                    }],
                    0,
                ),
            ),
            (
                4,
                explore(
                    "e3",
                    vec![CommandAction::Search {
                        query: Some("try_lock".into()),
                        path: Some("/work/cli/src".into()),
                    }],
                    1,
                ),
            ),
            (5, reasoning("r2", "Fixing the retry")),
            (6, edited("f1", "/work/cli/src/bridge/backoff.rs")),
            (7, shell("c1", "cargo test -p inline-cli", 101)),
        ];
        if fixed {
            events.push((8, shell("c2", "cargo test -p inline-cli", 0)));
            events.push((9, shell("c3", "cargo fmt", 0)));
        }
        events.push((
            10,
            turn(TurnPhase::Completed {
                outcome: TurnOutcome::Completed,
                inputs_consumed: vec![],
                error: None,
                duration_ms: Some(134_000),
            }),
        ));
        ended_text(&run(&mut renderer, events))
    }

    #[test]
    fn detailed_work_never_shows_credentials() {
        let mut renderer = Renderer::new(OutputMode::Detailed, Vocabulary::Codex, "Codex");
        let ops = run(
            &mut renderer,
            vec![
                (0, turn(TurnPhase::Started { inputs: vec![] })),
                (
                    1,
                    completed(
                        "c1",
                        ItemBody::Command {
                            command: "curl -H 'Authorization: Bearer abcdefghijklmnop' https://api.example.com".to_owned(),
                            cwd: None,
                            actions: Vec::new(),
                            output: Some("API_TOKEN=supersecretoutput1".to_owned()),
                            exit_code: Some(0),
                            duration_ms: Some(10),
                        },
                        None,
                    ),
                ),
                (
                    2,
                    completed(
                        "f1",
                        ItemBody::FileChange {
                            changes: vec![FileDiff {
                                path: "/work/.env.example".into(),
                                change: FileChangeKind::Update { moved_to: None },
                                diff: Some(
                                    "@@ -1 +1 @@\n-API_TOKEN=supersecretold2\n+API_TOKEN=supersecretnew3"
                                        .to_owned(),
                                ),
                            }],
                        },
                        None,
                    ),
                ),
                (
                    3,
                    turn(TurnPhase::Completed {
                        outcome: TurnOutcome::Completed,
                        inputs_consumed: vec![],
                        error: None,
                        duration_ms: Some(1_000),
                    }),
                ),
            ],
        );
        let sent = format!("{ops:?}");
        assert!(sent.contains("API_TOKEN"), "{sent}");
        for secret in [
            "abcdefghijklmnop",
            "supersecretoutput1",
            "supersecretold2",
            "supersecretnew3",
        ] {
            assert!(!sent.contains(secret), "{secret} reached the chat: {sent}");
        }
    }

    #[test]
    fn codex_work_groups_between_commentary_in_codex_words() {
        let text = codex_turn(true);
        assert!(text.starts_with("Worked for 2m 14s\n"), "{text}");
        for expected in [
            "Read files, edited a file, ran commands · +2 −1",
            "Explored",
            "Read helpers.rs, bridge.rs",
            // A search that found nothing exits 1 and is not a failure.
            "Search try_lock in cli/src\n",
            "Edited cli/src/bridge/backoff.rs · +2 −1",
            "Ran cargo test -p inline-cli · exit 101",
            "Ran cargo fmt",
        ] {
            assert!(text.contains(expected), "missing {expected:?} in:\n{text}");
        }
        // Reasoning headers are the live status, never rows.
        for absent in [
            "Tracing the lock error",
            "Fixing the retry",
            "Ran 2 commands",
        ] {
            assert!(!text.contains(absent), "{absent:?} in:\n{text}");
        }
        assert!(
            !text.contains("/work/"),
            "paths are relative to the folder:\n{text}"
        );
        assert!(!text.contains("failed"), "the later run fixed it:\n{text}");
    }

    fn started(id: &str, body: ItemBody) -> Event {
        Event::Item(Item::new(
            ItemId::new(id).expect("id"),
            None,
            ItemUpdate::Started { body },
            Value::Null,
        ))
    }

    fn working_title(ops: &[RenderOp]) -> String {
        let doc = ops
            .iter()
            .rev()
            .find_map(|op| match op {
                RenderOp::Progress { doc, .. } => Some(doc),
                _ => None,
            })
            .expect("progress");
        doc.text.lines().next().unwrap_or_default().to_owned()
    }

    #[test]
    fn codex_shows_its_latest_reasoning_header_as_the_live_status() {
        let mut renderer = Renderer::new(OutputMode::Detailed, Vocabulary::Codex, "Codex");
        let ops = run(
            &mut renderer,
            vec![
                (0, turn(TurnPhase::Started { inputs: vec![] })),
                (
                    1_000,
                    reasoning(
                        "r1",
                        "**Tracing the lock error**\n\nThe retry holds the lock across the await.",
                    ),
                ),
                (2_000, started("c1", ran("1", None))),
            ],
        );
        assert!(
            working_title(&ops).starts_with("Tracing the lock error · "),
            "{ops:?}"
        );
        let doc = match ops.last() {
            Some(RenderOp::Progress { doc, .. }) => doc,
            other => panic!("{other:?}"),
        };
        assert!(!doc.text.contains("holds the lock"), "{}", doc.text);
    }

    #[test]
    fn claude_shows_thinking_while_it_thinks_without_text() {
        let mut renderer = Renderer::new(OutputMode::Detailed, Vocabulary::Claude, "Claude");
        let thinking = ItemBody::Reasoning {
            summary: Vec::new(),
            content: Vec::new(),
        };
        let ops = run(
            &mut renderer,
            vec![
                (0, turn(TurnPhase::Started { inputs: vec![] })),
                (1_000, started("m1:0", thinking)),
            ],
        );
        assert!(working_title(&ops).starts_with("Thinking · "), "{ops:?}");
        let ops = run(&mut renderer, vec![(2_000, command("toolu_1"))]);
        assert!(working_title(&ops).starts_with("Working · "), "{ops:?}");
    }

    #[test]
    fn claude_prose_splits_its_work_into_groups_titled_with_counts() {
        let mut renderer = Renderer::new(OutputMode::Detailed, Vocabulary::Claude, "Claude");
        renderer.set_folder("/work".into());
        let tool = |id: &str, name: &str, input: Value| {
            completed(
                id,
                ItemBody::Tool {
                    name: name.to_owned(),
                    server: None,
                    input,
                    output: Some("ok".to_owned()),
                    error: None,
                },
                None,
            )
        };
        let ops = run(
            &mut renderer,
            vec![
                (0, turn(TurnPhase::Started { inputs: vec![] })),
                (
                    1,
                    tool("t1", "Grep", serde_json::json!({"pattern": "try_lock"})),
                ),
                (
                    2,
                    tool(
                        "t2",
                        "Read",
                        serde_json::json!({"file_path": "/work/cli/src/helpers.rs"}),
                    ),
                ),
                (
                    3,
                    tool(
                        "t3",
                        "Read",
                        serde_json::json!({"file_path": "/work/cli/src/bridge.rs"}),
                    ),
                ),
                (4, shell("t4", "cargo test", 101)),
                (
                    5,
                    completed(
                        "m1:0",
                        message("The retry holds the lock. Fixing it."),
                        None,
                    ),
                ),
                (6, edited("t5", "/work/cli/src/bridge/backoff.rs")),
                (7, shell("t6", "cargo test", 0)),
                // Thinking that has text is written for the reader.
                (8, reasoning("m2:0", "Tests pass. Checking the formatting.")),
                (9, shell("t7", "cargo fmt --check", 0)),
                (10, completed("m3:0", message("Fixed."), None)),
                (
                    11,
                    turn(TurnPhase::Completed {
                        outcome: TurnOutcome::Completed,
                        inputs_consumed: vec![],
                        error: None,
                        duration_ms: Some(11_000),
                    }),
                ),
            ],
        );
        let text = ended_text(&ops);
        let expected = [
            "Searched for 1 pattern, read 2 files, ran 1 command",
            "Searched for 1 pattern, read 2 files",
            "Read cli/src/helpers.rs",
            "Bash cargo test · exit 101",
            "The retry holds the lock. Fixing it.",
            "Edited 1 file, ran 1 command · +2 −1",
            "Edit cli/src/bridge/backoff.rs · +2 −1",
            "Tests pass. Checking the formatting.",
            "Bash cargo fmt --check",
        ];
        let mut from = 0;
        for line in expected {
            let at = text[from..]
                .find(line)
                .unwrap_or_else(|| panic!("missing {line:?} after {from} in:\n{text}"));
            from += at + line.len();
        }
        assert!(!text.contains("Fixed."), "the answer is its own message");
        assert!(matches!(ops.last(), Some(RenderOp::Final { doc }) if doc.text == "Fixed."));
    }

    #[test]
    fn claude_sub_agents_count_as_agents_and_prose_keeps_its_styles() {
        let mut renderer = Renderer::new(OutputMode::Detailed, Vocabulary::Claude, "Claude");
        renderer.set_folder("/work".into());
        let agent = |id: &str, description: &str| {
            completed(
                id,
                ItemBody::Tool {
                    name: "Agent".to_owned(),
                    server: None,
                    input: serde_json::json!({
                        "description": description,
                        "prompt": "Read the server for small fixes.",
                        "subagent_type": "general-purpose",
                    }),
                    output: Some("launched".to_owned()),
                    error: None,
                },
                None,
            )
        };
        let ops = run(
            &mut renderer,
            vec![
                (0, turn(TurnPhase::Started { inputs: vec![] })),
                (1, agent("t1", "Server sweep")),
                (2, agent("t2", "Apple sweep")),
                (
                    3,
                    completed(
                        "m1:0",
                        message("The `app_error` issue is **not** new."),
                        None,
                    ),
                ),
                (4, agent("t3", "Sentry check")),
                (5, completed("m2:0", message("Done."), None)),
                (
                    6,
                    turn(TurnPhase::Completed {
                        outcome: TurnOutcome::Completed,
                        inputs_consumed: vec![],
                        error: None,
                        duration_ms: Some(3_000),
                    }),
                ),
            ],
        );
        let doc = ops
            .iter()
            .find_map(|op| match op {
                RenderOp::EndProgress { doc, .. } => Some(doc),
                _ => None,
            })
            .expect("end");
        for line in [
            "Ran 2 agents",
            "Agent: Server sweep",
            "Agent: Apple sweep",
            "The app_error issue is not new.",
            "Agent: Sentry check",
        ] {
            assert!(
                doc.text.contains(line),
                "missing {line:?} in:\n{}",
                doc.text
            );
        }
        assert!(!doc.text.contains("Called"), "{}", doc.text);
        let styled: Vec<(i32, String)> = doc
            .entities
            .iter()
            .map(|entity| {
                let text: String = doc
                    .text
                    .encode_utf16()
                    .skip(entity.offset as usize)
                    .take(entity.length as usize)
                    .map(|unit| char::from_u32(unit.into()).unwrap_or('?'))
                    .collect();
                (entity.r#type, text)
            })
            .collect();
        use inline_protocol::proto::message_entity::Type;
        assert_eq!(
            styled,
            [
                (Type::Code as i32, "app_error".to_owned()),
                (Type::Bold as i32, "not".to_owned()),
            ]
        );
    }

    #[test]
    fn an_unfixed_failure_shows_on_the_collapsed_summary() {
        let text = codex_turn(false);
        assert!(text.starts_with("Worked for 2m 14s · 1 failed\n"), "{text}");
    }

    #[test]
    fn claude_reads_and_searches_fold_into_one_line_in_claude_words() {
        let mut renderer = Renderer::new(OutputMode::Detailed, Vocabulary::Claude, "Claude");
        renderer.set_folder("/work".into());
        let tool = |id: &str, name: &str, input: Value| {
            completed(
                id,
                ItemBody::Tool {
                    name: name.to_owned(),
                    server: None,
                    input,
                    output: Some("ok".to_owned()),
                    error: None,
                },
                None,
            )
        };
        let ops = run(
            &mut renderer,
            vec![
                (0, turn(TurnPhase::Started { inputs: vec![] })),
                (
                    1,
                    tool("t1", "Grep", serde_json::json!({"pattern": "try_lock"})),
                ),
                (
                    2,
                    tool(
                        "t2",
                        "Read",
                        serde_json::json!({"file_path": "/work/cli/src/helpers.rs"}),
                    ),
                ),
                (
                    3,
                    tool(
                        "t3",
                        "Read",
                        serde_json::json!({"file_path": "/work/cli/src/bridge.rs"}),
                    ),
                ),
                (
                    4,
                    turn(TurnPhase::Completed {
                        outcome: TurnOutcome::Completed,
                        inputs_consumed: vec![],
                        error: None,
                        duration_ms: Some(5_000),
                    }),
                ),
            ],
        );
        let text = ended_text(&ops);
        assert!(
            text.contains("Searched for 1 pattern, read 2 files"),
            "{text}"
        );
        assert!(text.contains("Read cli/src/helpers.rs"), "{text}");
    }

    #[test]
    fn answers_and_updates_go_out_as_markdown_for_inline_to_parse() {
        let mut renderer = Renderer::new(OutputMode::Friendly, Vocabulary::Codex, "Codex");
        let answer = "## Fixed\n\n- `backoff.rs` caps at 30s\n\n```sh\ncargo test\n```";
        let ops = run(
            &mut renderer,
            vec![
                (0, turn(TurnPhase::Started { inputs: vec![] })),
                (
                    1,
                    completed(
                        "m1",
                        message("**Looking** at it."),
                        Some(AgentMessagePhase::Commentary),
                    ),
                ),
                (
                    2,
                    completed("m2", message(answer), Some(AgentMessagePhase::FinalAnswer)),
                ),
                (
                    3,
                    turn(TurnPhase::Completed {
                        outcome: TurnOutcome::Completed,
                        inputs_consumed: vec![],
                        error: None,
                        duration_ms: Some(3),
                    }),
                ),
            ],
        );
        let docs: Vec<&Doc> = ops
            .iter()
            .filter_map(|op| match op {
                RenderOp::Update { doc } | RenderOp::Final { doc } => Some(doc),
                _ => None,
            })
            .collect();
        assert_eq!(docs.len(), 2);
        for doc in docs {
            assert!(doc.markdown, "prose must reach Inline as Markdown");
            assert!(doc.blocks.is_empty(), "Inline builds the blocks itself");
        }
        assert!(matches!(ops.last(), Some(RenderOp::Final { doc }) if doc.text == answer));
    }

    fn question(
        prompt: &str,
        options: &[&str],
        allow_other: bool,
    ) -> inline_agent_bridge::harness::FormField {
        inline_agent_bridge::harness::FormField {
            id: inline_agent_bridge::harness::FieldId::new(prompt).expect("id"),
            header: None,
            prompt: prompt.to_owned(),
            input: FieldInput::Select {
                options: options
                    .iter()
                    .map(|label| inline_agent_bridge::harness::FieldOption {
                        label: (*label).to_owned(),
                        description: Some(format!("{label} details")),
                        preview: None,
                    })
                    .collect(),
                multiple: false,
                allow_other,
            },
            required: true,
        }
    }

    #[test]
    fn one_choice_questions_ask_one_at_a_time_with_their_answers_above() {
        let form = QuestionForm {
            title: None,
            fields: vec![
                question("Scope", &["Only the CLI", "CLI and server"], true),
                question("Run tests after", &["Yes", "No"], false),
            ],
            asynchronous: false,
            auto_resolution_ms: None,
        };
        assert!(pickable(&form));
        let first = pick_card("Claude", &form, 0, &[]);
        assert!(first.text.starts_with("Claude has 2 questions"));
        assert!(first.text.contains("1/2. Scope"));
        assert!(first.text.contains("Only the CLI: Only the CLI details"));
        assert!(
            first.text.contains("reply to this message"),
            "Claude takes its own words"
        );
        let second = pick_card("Claude", &form, 1, &["Only the CLI".to_owned()]);
        assert!(second.text.contains("Scope: Only the CLI"));
        assert!(second.text.contains("2/2. Run tests after"));
        assert!(!second.text.contains("reply to this message"));
        // Many choices, or several at once, stay a form.
        let mut multiple = form.clone();
        if let FieldInput::Select { multiple: many, .. } = &mut multiple.fields[0].input {
            *many = true;
        }
        assert!(!pickable(&multiple));
    }

    #[test]
    fn a_closed_question_keeps_what_it_asked_and_the_answers_sent() {
        use inline_agent_bridge::harness::{FieldId, FormField};
        let mut renderer = Renderer::new(OutputMode::Friendly, Vocabulary::Claude, "Claude");
        let form = QuestionForm {
            title: None,
            fields: vec![
                question("Scope", &["Only the CLI", "CLI and server"], true),
                FormField {
                    id: FieldId::new("token").expect("id"),
                    header: None,
                    prompt: "API token".to_owned(),
                    input: FieldInput::Secret,
                    required: true,
                },
                question("Run tests after", &["Yes", "No"], false),
            ],
            asynchronous: false,
            auto_resolution_ms: None,
        };
        let id = InteractionId::new("q1").expect("id");
        run(
            &mut renderer,
            vec![(
                0,
                Event::Interaction(Interaction {
                    id: id.clone(),
                    turn: None,
                    item: None,
                    parent: None,
                    kind: InteractionKind::Question { form },
                    native: Value::Null,
                }),
            )],
        );
        renderer.name_user(7, "Mo".to_owned());
        renderer.note_answers(
            &id,
            &[
                FieldAnswer {
                    field: FieldId::new("Scope").expect("id"),
                    values: vec!["Only the CLI".to_owned()],
                },
                FieldAnswer {
                    field: FieldId::new("token").expect("id"),
                    values: vec!["sk-secret".to_owned()],
                },
            ],
        );
        let ops = run(
            &mut renderer,
            vec![(
                1,
                Event::InteractionClosed {
                    id,
                    by: ClosedBy::Inline {
                        user: inline_agent_bridge::harness::UserId(7),
                        decision: None,
                    },
                },
            )],
        );
        let RenderOp::CardClosed { doc, .. } = &ops[0] else {
            panic!("expected the card closed");
        };
        assert_eq!(
            doc.text,
            "Claude asked 3 questions\nScope: Only the CLI\nAPI token\nRun tests after\nAnswered by Mo"
        );
        assert!(
            !doc.text.contains("sk-secret"),
            "secrets never reach the chat"
        );
    }

    #[test]
    fn a_dialog_inline_cannot_show_leaves_a_notice() {
        for (vocabulary, next) in [
            (Vocabulary::Codex, "It was cancelled."),
            (Vocabulary::OpenCode, "Answer it in OpenCode."),
        ] {
            let mut renderer = Renderer::new(OutputMode::Friendly, vocabulary, "Agent");
            let ops = run(
                &mut renderer,
                vec![(
                    0,
                    Event::Interaction(Interaction {
                        id: InteractionId::new("d1").expect("id"),
                        turn: None,
                        item: None,
                        parent: None,
                        kind: InteractionKind::Dialog {
                            dialog: "item/tool/call".to_owned(),
                        },
                        native: Value::Null,
                    }),
                )],
            );
            let Some(RenderOp::Notice { doc }) = ops.first() else {
                panic!("expected a notice, got {ops:?}");
            };
            assert!(
                doc.text.contains("Agent asked for `item/tool/call`"),
                "{}",
                doc.text
            );
            assert!(doc.text.ends_with(next), "{}", doc.text);
        }
    }

    #[test]
    fn approvals_carry_the_harness_labels_and_close_to_their_resolution() {
        let mut renderer = Renderer::new(OutputMode::Friendly, Vocabulary::Codex, "Codex");
        let interaction = Interaction {
            id: InteractionId::new("41").expect("id"),
            turn: None,
            item: None,
            parent: None,
            kind: InteractionKind::Approval {
                subject: ApprovalSubject::Command {
                    command: "cargo test".to_owned(),
                    cwd: Some("/work".into()),
                    reason: None,
                    network_host: None,
                    permissions: None,
                },
                decisions: vec![Decision {
                    id: inline_agent_bridge::harness::DecisionId::new("accept").expect("id"),
                    label: "Yes, proceed".to_owned(),
                    kind: DecisionKind::Accept,
                    description: None,
                    accepts_message: false,
                    native: Value::Null,
                }],
            },
            native: Value::Null,
        };
        let ops = run(&mut renderer, vec![(0, Event::Interaction(interaction))]);
        let RenderOp::Card { doc, actions, .. } = &ops[0] else {
            panic!("expected a card");
        };
        assert_eq!(
            doc.text,
            "Codex wants to run a command\nCommand: cargo test\nFolder: /work"
        );
        assert_eq!(actions[0].label, "Yes, proceed");
        assert_eq!(actions[0].style, ActionStyle::Primary);
        let ops = run(
            &mut renderer,
            vec![(
                1,
                Event::InteractionClosed {
                    id: InteractionId::new("41").expect("id"),
                    by: ClosedBy::Inline {
                        user: inline_agent_bridge::harness::UserId(7),
                        decision: Some(
                            inline_agent_bridge::harness::DecisionId::new("accept").expect("id"),
                        ),
                    },
                },
            )],
        );
        // The card keeps its approval, decided, with the outcome under it.
        let RenderOp::CardClosed { doc, .. } = &ops[0] else {
            panic!("expected the card closed");
        };
        assert_eq!(
            doc.text,
            "Codex wants to run a command\nCommand: cargo test\nFolder: /work\nYes, proceed (answered by user 7)"
        );
        let Some(inline_protocol::proto::block::Kind::Approval(approval)) = &doc.blocks[0].kind
        else {
            panic!("expected an approval");
        };
        assert_eq!(approval.state, DecisionState::Accepted as i32);
        assert_eq!(approval.decided_by_user_id, Some(7));
        assert!(approval.action_ids.is_empty());
    }

    fn ended(outcome: TurnOutcome) -> Event {
        turn(TurnPhase::Completed {
            outcome,
            inputs_consumed: vec![],
            error: None,
            duration_ms: None,
        })
    }

    #[test]
    fn a_codex_plan_is_offered_for_approval_only_after_a_completed_turn() {
        let plan = || {
            completed(
                "item-p1",
                ItemBody::Plan {
                    explanation: None,
                    steps: Vec::new(),
                    text: Some("- Pin the plan".to_owned()),
                },
                None,
            )
        };
        for (outcome, offered) in [
            (TurnOutcome::Completed, true),
            (TurnOutcome::Interrupted, false),
        ] {
            let mut renderer = Renderer::new(OutputMode::Friendly, Vocabulary::Codex, "Codex");
            let ops = run(
                &mut renderer,
                vec![
                    (0, turn(TurnPhase::Started { inputs: vec![] })),
                    (1, plan()),
                    (2, ended(outcome)),
                ],
            );
            assert_eq!(
                ops.iter()
                    .any(|op| matches!(op, RenderOp::PlanProposal { .. })),
                offered,
                "{outcome:?}"
            );
        }
        // Claude's plan is approved through its permission request instead.
        let mut renderer = Renderer::new(OutputMode::Friendly, Vocabulary::Claude, "Claude");
        let ops = run(
            &mut renderer,
            vec![
                (0, turn(TurnPhase::Started { inputs: vec![] })),
                (1, plan()),
                (2, ended(TurnOutcome::Completed)),
            ],
        );
        assert!(
            !ops.iter()
                .any(|op| matches!(op, RenderOp::PlanProposal { .. }))
        );
    }

    #[test]
    fn a_withdrawn_approval_reads_expired_and_keeps_no_buttons() {
        let mut renderer = Renderer::new(OutputMode::Friendly, Vocabulary::Claude, "Claude");
        let interaction = Interaction {
            id: InteractionId::new("req-plan-1").expect("id"),
            turn: None,
            item: None,
            parent: None,
            kind: InteractionKind::Approval {
                subject: ApprovalSubject::Plan {
                    plan: "# Fix it\n\n1. Read\n2. Fix".to_owned(),
                },
                decisions: vec![Decision {
                    id: inline_agent_bridge::harness::DecisionId::new("allow").expect("id"),
                    label: "Yes".to_owned(),
                    kind: DecisionKind::Accept,
                    description: None,
                    accepts_message: false,
                    native: Value::Null,
                }],
            },
            native: Value::Null,
        };
        let ops = run(&mut renderer, vec![(0, Event::Interaction(interaction))]);
        let RenderOp::Card { doc, actions, .. } = &ops[0] else {
            panic!("expected a card");
        };
        assert_eq!(actions[0].label, "Approve");
        assert!(matches!(
            &doc.blocks[0].kind,
            Some(inline_protocol::proto::block::Kind::PlanProposal(plan)) if plan.action_ids == ["v2-0"]
        ));
        let ops = run(
            &mut renderer,
            vec![(
                1,
                Event::InteractionClosed {
                    id: InteractionId::new("req-plan-1").expect("id"),
                    by: ClosedBy::Cancelled,
                },
            )],
        );
        let RenderOp::CardClosed { doc, .. } = &ops[0] else {
            panic!("expected the card closed");
        };
        let Some(inline_protocol::proto::block::Kind::PlanProposal(plan)) = &doc.blocks[0].kind
        else {
            panic!("expected the plan");
        };
        assert_eq!(plan.state, DecisionState::Expired as i32);
        assert!(plan.action_ids.is_empty());
        assert!(doc.text.ends_with("No longer needed"));
    }

    #[test]
    fn an_answer_that_streamed_into_progress_leaves_its_time_and_the_answer() {
        // Claude names no final phase: the text streams into progress, then
        // turns out to be the answer.
        let mut renderer = Renderer::new(OutputMode::Detailed, Vocabulary::Claude, "Claude");
        let delta = Event::Item(
            Item::new(
                ItemId::new("m1").expect("id"),
                None,
                ItemUpdate::Delta {
                    delta: ItemDelta {
                        stream: DeltaStream::Text,
                        index: None,
                        text: "Hel".to_owned(),
                    },
                },
                Value::Null,
            )
            .with_kind(ItemKind::Message),
        );
        let ops = run(
            &mut renderer,
            vec![
                (0, turn(TurnPhase::Started { inputs: vec![] })),
                (10, delta),
                (20, completed("m1", message("Hello"), None)),
                (
                    30,
                    turn(TurnPhase::Completed {
                        outcome: TurnOutcome::Completed,
                        inputs_consumed: vec![],
                        error: None,
                        duration_ms: None,
                    }),
                ),
            ],
        );
        assert!(matches!(
            ops.first(),
            Some(RenderOp::Progress { slot: 1, .. })
        ));
        assert!(
            ops.iter().any(|op| matches!(
                op,
                RenderOp::EndProgress { slot: 1, doc, .. } if doc.text == "Worked for 1s"
            )),
            "{ops:?}"
        );
        assert!(matches!(ops.last(), Some(RenderOp::Final { doc }) if doc.text == "Hello"));
    }

    #[test]
    fn a_streaming_widget_shows_in_progress_only_by_its_title() {
        let mut renderer = Renderer::new(OutputMode::Detailed, Vocabulary::Claude, "Claude");
        let delta = |text: &str| {
            Event::Item(
                Item::new(
                    ItemId::new("m1").expect("id"),
                    None,
                    ItemUpdate::Delta {
                        delta: ItemDelta {
                            stream: DeltaStream::Text,
                            index: None,
                            text: text.to_owned(),
                        },
                    },
                    Value::Null,
                )
                .with_kind(ItemKind::Message),
            )
        };
        let ops = run(
            &mut renderer,
            vec![
                (0, turn(TurnPhase::Started { inputs: vec![] })),
                (10, delta("Chart:\n\n<iframe title=\"Q3\">\n<div>")),
                (5_000, delta("</div>\n</iframe>\n\nAfter.")),
            ],
        );
        let progress: Vec<&str> = ops
            .iter()
            .filter_map(|op| match op {
                RenderOp::Progress { doc, .. } => Some(doc.text.as_str()),
                _ => None,
            })
            .collect();
        assert!(!progress.is_empty(), "{ops:?}");
        assert!(
            progress.iter().all(|text| !text.contains('<')),
            "{progress:?}"
        );
        assert!(
            progress.last().expect("last").contains("[Widget: Q3]"),
            "{progress:?}"
        );
    }

    #[test]
    fn deltas_stream_into_their_row_and_unknown_items_render_generically() {
        let mut renderer = Renderer::new(OutputMode::Detailed, Vocabulary::Codex, "Codex");
        let delta = Event::Item(
            Item::new(
                ItemId::new("c1").expect("id"),
                None,
                ItemUpdate::Delta {
                    delta: ItemDelta {
                        stream: DeltaStream::Output,
                        index: None,
                        text: "compiling".to_owned(),
                    },
                },
                Value::Null,
            )
            .with_kind(ItemKind::Command),
        );
        let unknown = completed(
            "x1",
            ItemBody::Unknown {
                native_type: "hologram".to_owned(),
                summary: None,
            },
            None,
        );
        let ops = run(&mut renderer, vec![(0, delta), (1, unknown)]);
        let RenderOp::Progress { doc, .. } = ops.last().expect("progress") else {
            panic!("expected progress");
        };
        assert!(doc.text.contains("compiling"));
        assert!(doc.text.contains("hologram · hologram"));
    }
}
