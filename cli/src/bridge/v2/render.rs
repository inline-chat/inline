//! Session events to Inline messages (spec §6).
//!
//! Pure: the runtime feeds envelopes in order and performs the returned
//! operations (send, edit, reply), coalescing progress edits as today.
//!
//! - **Detailed**: every item the harness reports, in its own vocabulary and
//!   order, as collapsible rows (sub-agent rows nest their items), plus a
//!   separate final answer.
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
    FieldInput, FileChangeKind, FileDiff, InputFact, InputId, Interaction, InteractionId,
    InteractionKind, Item, ItemBody, ItemKind, ItemStatus, ItemUpdate, MessageRole, NoticeLevel,
    OutputMode, QuestionForm, TurnPhase,
};
use inline_agent_bridge::{AgentMessagePhase, PlanStepStatus, TurnId, TurnOutcome};
use serde_json::Value;

use super::doc::{ActivityKind, CalloutKind, DiffChange, Doc, DocBuilder, Status};
use super::limits;

/// Harness vocabulary for row titles.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Vocabulary {
    Codex,
    Claude,
}

/// One message operation for the runtime.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum RenderOp {
    /// Create (first time) or silently edit the progress message `slot`.
    Progress { slot: u32, doc: Doc },
    /// Last edit of progress message `slot`; it no longer changes. `full`
    /// holds the untruncated detail of rows the message shows cut short.
    EndProgress {
        slot: u32,
        doc: Doc,
        full: Vec<FullDetail>,
    },
    /// A short Friendly update message.
    Update { doc: Doc },
    /// The final answer: a separate message that notifies.
    Final { doc: Doc },
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

/// The untruncated detail of one row whose message shows only its end.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FullDetail {
    pub title: String,
    pub text: String,
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
/// previews show it. Full output keeps the rest.
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
    /// People who answered cards, by user ID.
    names: HashMap<i64, String>,
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
            names: HashMap::new(),
        }
    }

    pub(crate) fn mode(&self) -> OutputMode {
        self.mode
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
                    self.end_slot(elapsed, "Worked for", &mut ops);
                }
            }
            Event::Item(item) => self.item(item, now, &mut ops),
            Event::Interaction(interaction) => self.interaction(interaction, &mut ops),
            Event::InteractionClosed { id, by } => {
                if let Some(interaction) = self.interactions.remove(id) {
                    ops.push(RenderOp::CardClosed {
                        interaction: id.clone(),
                        doc: closed_card(&interaction, by, &self.names),
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
                self.end_slot(elapsed, "Some updates were skipped · worked for", &mut ops);
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
        let finished = tops
            .iter()
            .take_while(|&&index| {
                !matches!(slot.rows[index].status, Status::Running | Status::Waiting)
            })
            .count();
        // A longer prefix is never smaller, so the longest that fits is found
        // by bisection.
        let fits = |count: usize| {
            let part = subset(slot, &tops[..count]);
            limits::progress_fits(&self.ended_doc(&part, &summary))
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
            doc: self.ended_doc(&kept, &summary),
            full: self.full_details(&kept),
        });
        self.next_slot += 1;
        self.turn_slots += 1;
        self.slot = Some(carried);
        true
    }

    /// A finished message: closed, under its summary.
    fn ended_doc(&self, slot: &Slot, summary: &str) -> Doc {
        let mut builder = DocBuilder::new();
        if slot.rows.is_empty() {
            builder.footer(summary);
        } else {
            builder.progress(summary, false, |inner| self.write_slot(inner, slot));
        }
        builder.finish()
    }

    fn full_details(&self, slot: &Slot) -> Vec<FullDetail> {
        slot.rows
            .iter()
            .filter_map(|row| {
                let body = row.body.as_ref()?;
                let text = row_full_text(body, &row.delta)?;
                Some(FullDetail {
                    title: row_title(self.vocabulary, self.folder.as_deref(), body).0,
                    text,
                })
            })
            .collect()
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
            ItemBody::Reasoning { summary, .. } if !summary.is_empty() => {
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
            InteractionKind::Dialog { .. } => {}
            InteractionKind::Approval { subject, decisions } => {
                self.mark_rows_waiting(interaction.item.as_ref().map(ToString::to_string));
                ops.push(RenderOp::Card {
                    interaction: interaction.id.clone(),
                    doc: approval_card(&self.agent, subject),
                    actions: decisions.iter().map(card_action).collect(),
                    form: None,
                });
                self.interactions
                    .insert(interaction.id.clone(), interaction.clone());
            }
            InteractionKind::Question { form } => {
                ops.push(RenderOp::Card {
                    interaction: interaction.id.clone(),
                    doc: question_card(&self.agent, form),
                    actions: Vec::new(),
                    form: Some(form.clone()),
                });
                self.interactions
                    .insert(interaction.id.clone(), interaction.clone());
            }
        }
        self.push_progress(ops);
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

    fn end_slot(&mut self, elapsed_ms: u64, verb: &str, ops: &mut Vec<RenderOp>) {
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
            )
        } else {
            self.ended_doc(&slot, &summary)
        };
        ops.push(RenderOp::EndProgress {
            slot: id,
            doc,
            full: self.full_details(&slot),
        });
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
        self.end_slot(elapsed, verb, ops);
        self.turn_slots = 0;
        if let Some(text) = self.final_answer.take()
            && !text.trim().is_empty()
        {
            ops.push(RenderOp::Final {
                doc: Doc::markdown(&text),
            });
        }
        if let Some(error) = error
            && matches!(
                outcome,
                TurnOutcome::Failed | TurnOutcome::AuthenticationRequired
            )
        {
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
        builder.progress("Working", true, |inner| self.write_rows(inner));
        builder.finish()
    }

    fn write_rows(&self, builder: &mut DocBuilder) {
        if let Some(slot) = &self.slot {
            self.write_slot(builder, slot);
        }
    }

    /// Top-level rows in phases and runs, as v1 and Codex draw a turn: a
    /// reasoning summary heads the work that follows it, and runs of
    /// exploration, finished commands and edits fold into one row each.
    fn write_slot(&self, builder: &mut DocBuilder, slot: &Slot) {
        let rows: Vec<&Row> = slot
            .rows
            .iter()
            .filter(|row| row.parent.is_none() && shows(row))
            .collect();
        let mut start = 0;
        while start < rows.len() {
            let end = rows[start + 1..]
                .iter()
                .position(|row| starts_phase(row))
                .map_or(rows.len(), |offset| start + 1 + offset);
            if starts_phase(rows[start]) && end > start + 1 {
                self.write_phase(builder, slot, rows[start], &rows[start + 1..end]);
            } else if starts_phase(rows[start]) {
                self.write_row(builder, slot, rows[start]);
            } else {
                self.write_runs(builder, slot, &rows[start..end]);
            }
            start = end;
        }
    }

    fn write_phase(&self, builder: &mut DocBuilder, slot: &Slot, head: &Row, rows: &[&Row]) {
        let Some(ItemBody::Reasoning { summary, .. }) = &head.body else {
            return;
        };
        let text = summary.join("\n\n");
        let title = first_line(&text, 80);
        let busy = std::iter::once(head)
            .chain(rows.iter().copied())
            .any(|row| matches!(row.status, Status::Running | Status::Waiting));
        let status = if busy { Status::Running } else { Status::Done };
        builder.disclosure(&title, None, ActivityKind::Reasoning, status, |inner| {
            if text.trim() != title {
                inner.paragraph(&tail(&text));
            }
            self.write_runs(inner, slot, rows);
        });
    }

    fn write_runs(&self, builder: &mut DocBuilder, slot: &Slot, rows: &[&Row]) {
        let mut index = 0;
        while index < rows.len() {
            let fold = self.fold_of(rows[index]);
            let mut end = index + 1;
            if fold != Fold::None {
                while end < rows.len() && self.fold_of(rows[end]) == fold {
                    end += 1;
                }
            }
            let run = &rows[index..end];
            match fold {
                Fold::Explore if self.vocabulary == Vocabulary::Codex || run.len() > 1 => {
                    self.write_explore(builder, run);
                }
                Fold::Command if run.len() > 1 => {
                    let total: u64 = run
                        .iter()
                        .filter_map(|row| match &row.body {
                            Some(ItemBody::Command { duration_ms, .. }) => *duration_ms,
                            _ => None,
                        })
                        .sum();
                    let meta = (total > 0).then(|| elapsed_text(total.max(1000)));
                    let title = format!("Ran {} commands", run.len());
                    builder.disclosure(
                        &title,
                        meta.as_deref(),
                        ActivityKind::Command,
                        Status::Done,
                        |inner| {
                            for row in run {
                                self.write_row(inner, slot, row);
                            }
                        },
                    );
                }
                Fold::Edit if run.len() > 1 => {
                    let changes: Vec<&FileDiff> = run
                        .iter()
                        .filter_map(|row| match &row.body {
                            Some(ItemBody::FileChange { changes }) => Some(changes.iter()),
                            _ => None,
                        })
                        .flatten()
                        .collect();
                    let (added, removed) = changes
                        .iter()
                        .map(|change| line_counts(change))
                        .fold((0, 0), |(a, r), (added, removed)| (a + added, r + removed));
                    let files = changes
                        .iter()
                        .map(|change| &change.path)
                        .collect::<std::collections::HashSet<_>>()
                        .len();
                    let title = if files == 1 {
                        "Edited 1 file".to_owned()
                    } else {
                        format!("Edited {files} files")
                    };
                    builder.disclosure(
                        &title,
                        counts_meta(added, removed).as_deref(),
                        ActivityKind::Edit,
                        Status::Done,
                        |inner| {
                            for row in run {
                                self.write_row(inner, slot, row);
                            }
                        },
                    );
                }
                _ => {
                    for row in run {
                        self.write_row(builder, slot, row);
                    }
                }
            }
            index = end;
        }
    }

    fn fold_of(&self, row: &Row) -> Fold {
        match &row.body {
            Some(body) if is_exploration(body) => Fold::Explore,
            Some(ItemBody::Command {
                exit_code: Some(0), ..
            }) if row.status == Status::Done => Fold::Command,
            Some(ItemBody::FileChange { .. }) if row.status == Status::Done => Fold::Edit,
            _ => Fold::None,
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
            Vocabulary::Codex => (
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
            builder.paragraph(&text);
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
                    inner.code(&tail(&row.delta), None);
                },
            );
            return;
        };
        let (title, meta, activity) = row_title(self.vocabulary, self.folder.as_deref(), &body);
        let children: Vec<&Row> = match &body {
            ItemBody::Child { child, .. } => slot
                .rows
                .iter()
                .filter(|candidate| candidate.parent.as_deref() == Some(child.id.as_str()))
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

/// How a row joins its neighbours in a run.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Fold {
    Explore,
    Command,
    Edit,
    None,
}

/// Rows a message shows: an answer or a text still in doubt is not one.
fn shows(row: &Row) -> bool {
    !(row.kind == ItemKind::Message
        && (row.phase == Some(AgentMessagePhase::FinalAnswer)
            || row.phase.is_none() && row.body.is_some()))
}

fn starts_phase(row: &Row) -> bool {
    matches!(&row.body, Some(ItemBody::Reasoning { summary, .. }) if !summary.is_empty())
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

/// The start of a long text, such as a command a card shows in full.
fn head(text: &str) -> String {
    if text.chars().count() <= MAX_DETAIL_CHARS {
        return text.to_owned();
    }
    let shown: String = text.chars().take(MAX_DETAIL_CHARS).collect();
    format!("{shown}…")
}

/// Paths one per line, the first 50 of a long list and a count of the rest.
fn path_list(paths: &[std::path::PathBuf]) -> String {
    const SHOWN: usize = 50;
    let mut lines: Vec<String> = paths
        .iter()
        .take(SHOWN)
        .map(|path| path.display().to_string())
        .collect();
    if paths.len() > SHOWN {
        lines.push(format!("and {} more", paths.len() - SHOWN));
    }
    lines.join("\n")
}

/// The end of a long text from a line start, with the hidden line count, as
/// Codex's output previews show it ("… +120 lines").
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
                Vocabulary::Codex if exploring => (
                    "Explored".to_owned(),
                    Some(explore_meta(actions)),
                    ActivityKind::Explore,
                ),
                Vocabulary::Codex => (
                    format!("Ran {}", first_line(command, 80)),
                    meta,
                    ActivityKind::Command,
                ),
                Vocabulary::Claude => (
                    format!("Bash {}", first_line(command, 80)),
                    meta,
                    ActivityKind::Command,
                ),
            }
        }
        ItemBody::FileChange { changes } => {
            let title = match changes.as_slice() {
                [only] => {
                    let verb = match (vocabulary, &only.change) {
                        (Vocabulary::Codex, FileChangeKind::Add) => "Added",
                        (Vocabulary::Codex, FileChangeKind::Delete) => "Deleted",
                        (Vocabulary::Codex, _) => "Edited",
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
            server,
            input,
            ..
        } => {
            let argument = ["file_path", "path", "pattern", "query", "url", "command"]
                .iter()
                .find_map(|key| input.get(*key).and_then(Value::as_str))
                .map(|argument| first_line(&relative(argument, folder), 60));
            let title = match (vocabulary, server) {
                (Vocabulary::Codex, Some(server)) => format!("Called {server}.{name}"),
                _ => match argument {
                    Some(argument) => format!("{name} {argument}"),
                    None => name.clone(),
                },
            };
            let activity = match name.as_str() {
                "Read" | "view_image" => ActivityKind::Read,
                "Grep" | "Glob" => ActivityKind::Search,
                "WebFetch" | "WebSearch" | "web_search" => ActivityKind::Web,
                _ => ActivityKind::Tool,
            };
            (title, None, activity)
        }
        ItemBody::Plan { .. } => (
            match vocabulary {
                Vocabulary::Codex => "Updated Plan",
                Vocabulary::Claude => "Update Todos",
            }
            .to_owned(),
            None,
            ActivityKind::Unspecified,
        ),
        ItemBody::Child { action, prompt, .. } => {
            let label = match vocabulary {
                Vocabulary::Codex => "Sub-agent",
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
            builder.code(&format!("$ {command}"), Some("sh"));
            let output = output.as_deref().unwrap_or(delta);
            builder.code(&tail(output), None);
            if let Some(code) = exit_code.filter(|code| *code != 0) {
                builder.paragraph(&format!("Exit code {code}"));
            }
        }
        ItemBody::FileChange { changes } => {
            // Past a budget, later files list by name; Full output has all.
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
                    .map(tail);
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
                    &tail(&serde_json::to_string_pretty(input).unwrap_or_default()),
                    Some("json"),
                );
            }
            if let Some(output) = output.as_deref().or((!delta.is_empty()).then_some(delta)) {
                builder.code(&tail(output), None);
            }
            if let Some(error) = error {
                builder.paragraph(error);
            }
        }
        ItemBody::Plan {
            explanation,
            steps,
            text,
        } => {
            if let Some(explanation) = explanation {
                builder.paragraph(explanation);
            }
            if !steps.is_empty() {
                let steps: Vec<(String, Status)> = steps
                    .iter()
                    .map(|step| {
                        (
                            step.text.clone(),
                            match step.status {
                                PlanStepStatus::Completed => Status::Done,
                                PlanStepStatus::InProgress => Status::Running,
                                PlanStepStatus::Pending => Status::None,
                            },
                        )
                    })
                    .collect();
                builder.steps(&steps);
            }
            if let Some(text) = text.as_deref().or((!delta.is_empty()).then_some(delta)) {
                builder.paragraph(&tail(text));
            }
        }
        ItemBody::Error { message } => builder.paragraph(message),
        _ => {}
    }
}

/// A row's whole detail as plain text, when its message shows only the end.
fn row_full_text(body: &ItemBody, delta: &str) -> Option<String> {
    let long = |text: &str| text.chars().count() > MAX_DETAIL_CHARS;
    match body {
        ItemBody::Command {
            command, output, ..
        } => {
            let output = output.as_deref().unwrap_or(delta);
            long(output).then(|| format!("$ {command}\n\n{output}"))
        }
        ItemBody::FileChange { changes } => changes
            .iter()
            .any(|change| change.diff.as_deref().is_some_and(long))
            .then(|| {
                changes
                    .iter()
                    .map(|change| {
                        format!(
                            "--- {}\n{}",
                            change.path.display(),
                            change.diff.as_deref().unwrap_or("")
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("\n\n")
            }),
        ItemBody::Reasoning { summary, .. } => {
            let text = if summary.is_empty() {
                delta.to_owned()
            } else {
                summary.join("\n\n")
            };
            long(&text).then_some(text)
        }
        ItemBody::Tool { input, output, .. } => {
            let input = if input.is_null() {
                String::new()
            } else {
                serde_json::to_string_pretty(input).unwrap_or_default()
            };
            let output = output
                .as_deref()
                .or((!delta.is_empty()).then_some(delta))
                .unwrap_or("");
            (long(&input) || long(output)).then(|| format!("{input}\n\n{output}"))
        }
        ItemBody::Plan { text, .. } => {
            let text = text.as_deref().or((!delta.is_empty()).then_some(delta))?;
            long(text).then(|| text.to_owned())
        }
        _ => None,
    }
}

fn card_action(decision: &Decision) -> CardAction {
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

/// Full details for everyone in the thread (Oct 24: no premature filtering).
fn approval_card(agent: &str, subject: &ApprovalSubject) -> Doc {
    let mut builder = DocBuilder::new();
    match subject {
        ApprovalSubject::Command {
            command,
            cwd,
            reason,
            network_host,
            permissions,
        } => {
            builder.paragraph(&format!("{agent} wants to run a command"));
            builder.fields(&[
                ("Command", head(command), true),
                (
                    "Folder",
                    cwd.as_ref()
                        .map(|cwd| cwd.display().to_string())
                        .unwrap_or_default(),
                    true,
                ),
                ("Host", network_host.clone().unwrap_or_default(), true),
                (
                    "Permissions",
                    permissions.clone().unwrap_or_default(),
                    false,
                ),
                ("Reason", reason.clone().unwrap_or_default(), false),
            ]);
        }
        ApprovalSubject::FileChange {
            paths,
            reason,
            grant_root,
        } => {
            builder.paragraph(&format!("{agent} wants to edit files"));
            builder.fields(&[
                ("Files", path_list(paths), true),
                (
                    "Write access to",
                    grant_root
                        .as_ref()
                        .map(|root| root.display().to_string())
                        .unwrap_or_default(),
                    true,
                ),
                ("Reason", reason.clone().unwrap_or_default(), false),
            ]);
        }
        ApprovalSubject::Permissions { summary, reason } => {
            builder.paragraph(&format!("{agent} asks for more permissions"));
            builder.fields(&[
                ("Permissions", summary.clone(), false),
                ("Reason", reason.clone().unwrap_or_default(), false),
            ]);
        }
        ApprovalSubject::Tool {
            name,
            input,
            reason,
        } => {
            builder.paragraph(&format!("{agent} wants to use {name}"));
            builder.fields(&[("Reason", reason.clone().unwrap_or_default(), false)]);
            if !input.is_null() {
                builder.code(
                    &tail(&serde_json::to_string_pretty(input).unwrap_or_default()),
                    Some("json"),
                );
            }
        }
        ApprovalSubject::Other { title, detail } => {
            builder.paragraph(&format!("{agent}: {title}"));
            if let Some(detail) = detail {
                builder.paragraph(detail);
            }
        }
    }
    builder.finish()
}

/// Form ID of a question card; one form per card message.
pub(crate) const QUESTION_FORM_ID: &str = "q";

/// Most options a question shows as buttons.
const MAX_PICK_OPTIONS: usize = 8;

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
    builder.paragraph(&if count > 1 {
        format!("{}/{count}. {}", field + 1, question.prompt)
    } else {
        question.prompt.clone()
    });
    if let FieldInput::Select { options, .. } = &question.input {
        for option in options {
            if let Some(description) = option
                .description
                .as_deref()
                .filter(|text| !text.trim().is_empty())
            {
                builder.paragraph(&format!("• {}: {description}", option.label));
            }
        }
    }
    if takes_reply(form, field) {
        builder.footer("Or reply to this message with your own answer.");
    }
    builder.finish()
}

fn question_card(agent: &str, form: &QuestionForm) -> Doc {
    if pickable(form) {
        return pick_card(agent, form, 0, &[]);
    }
    let mut builder = DocBuilder::new();
    if form.title.is_none() {
        builder.paragraph(&format!("{agent} has a question"));
    }
    // Anyone with access to the agent can answer its questions.
    builder.form(
        QUESTION_FORM_ID,
        form,
        inline_protocol::proto::AgentGrantRequirement::Access,
    );
    builder.finish()
}

fn closed_card(interaction: &Interaction, by: &ClosedBy, names: &HashMap<i64, String>) -> Doc {
    let mut builder = DocBuilder::new();
    let resolution = match by {
        ClosedBy::Inline { user, decision } => {
            let label = decision
                .as_ref()
                .and_then(|decision| match &interaction.kind {
                    InteractionKind::Approval { decisions, .. } => decisions
                        .iter()
                        .find(|candidate| &candidate.id == decision)
                        .map(|candidate| candidate.label.clone()),
                    _ => None,
                });
            let name = names
                .get(&user.0)
                .cloned()
                .unwrap_or_else(|| format!("user {}", user.0));
            match label {
                Some(label) => format!("{label} (answered by {name})"),
                None => format!("Answered by {name}"),
            }
        }
        ClosedBy::External => "Answered outside Inline".to_owned(),
        ClosedBy::Cancelled => "No longer needed".to_owned(),
    };
    builder.footer(&resolution);
    builder.finish()
}

#[cfg(test)]
mod tests {
    use inline_agent_bridge::harness::{DeltaStream, ItemDelta, ItemId, SessionKey, TurnPhase};
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
        assert_eq!(doc.text, "Working");
        let working = outer(doc);
        assert_eq!(
            working.kind,
            inline_protocol::proto::block_disclosure::Kind::Progress as i32
        );
        assert_eq!(working.initially_open, Some(true));
        let RenderOp::Progress { doc, .. } = &ops[1] else {
            panic!("rows edit the same message");
        };
        assert!(
            doc.text.starts_with(
                "Working
Ran cargo test"
            ),
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
    fn long_output_is_kept_whole_for_the_full_output_button() {
        let mut renderer = Renderer::new(OutputMode::Detailed, Vocabulary::Codex, "Codex");
        let long = format!("FIRST LINE\n{}", "x".repeat(MAX_DETAIL_CHARS + 10));
        let ops = run(
            &mut renderer,
            vec![
                (0, turn(TurnPhase::Started { inputs: vec![] })),
                (
                    1_000,
                    completed(
                        "c1",
                        ItemBody::Command {
                            command: "cargo test".to_owned(),
                            cwd: None,
                            actions: Vec::new(),
                            output: Some(long.clone()),
                            exit_code: Some(0),
                            duration_ms: Some(1200),
                        },
                        None,
                    ),
                ),
                (
                    2_000,
                    turn(TurnPhase::Completed {
                        outcome: TurnOutcome::Completed,
                        inputs_consumed: vec![],
                        error: None,
                        duration_ms: None,
                    }),
                ),
            ],
        );
        let (doc, full) = ops
            .iter()
            .find_map(|op| match op {
                RenderOp::EndProgress { doc, full, .. } => Some((doc, full)),
                _ => None,
            })
            .expect("end");
        assert!(
            !doc.text.contains("FIRST LINE"),
            "the message shows only the end"
        );
        assert_eq!(full.len(), 1);
        assert!(full[0].text.contains("FIRST LINE"));
        assert!(full[0].text.ends_with(&long));
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
    fn codex_work_nests_under_its_reasoning_and_runs_fold_in_codex_words() {
        let text = codex_turn(true);
        assert!(text.starts_with("Worked for 2m 14s\n"), "{text}");
        for expected in [
            "Tracing the lock error",
            "Explored",
            "Read helpers.rs, bridge.rs",
            // A search that found nothing exits 1 and is not a failure.
            "Search try_lock in cli/src\n",
            "Fixing the retry",
            "Edited cli/src/bridge/backoff.rs · +2 −1",
            "Ran cargo test -p inline-cli · exit 101",
            "Ran 2 commands",
        ] {
            assert!(text.contains(expected), "missing {expected:?} in:\n{text}");
        }
        assert!(
            !text.contains("/work/"),
            "paths are relative to the folder:\n{text}"
        );
        assert!(!text.contains("failed"), "the later run fixed it:\n{text}");
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
        assert!(
            matches!(&ops[0], RenderOp::CardClosed { doc, .. } if doc.text == "Yes, proceed (answered by user 7)")
        );
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
