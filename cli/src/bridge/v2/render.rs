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

use inline_agent_bridge::harness::{
    ApprovalSubject, ChildRef, ClosedBy, CommandAction, Decision, DecisionKind, Envelope, Event,
    FileChangeKind, InputFact, InputId, Interaction, InteractionId, InteractionKind, Item,
    ItemBody, ItemKind, ItemStatus, ItemUpdate, MessageRole, NoticeLevel, OutputMode, QuestionForm,
    TurnPhase,
};
use inline_agent_bridge::{AgentMessagePhase, PlanStepStatus, TurnId, TurnOutcome};
use serde_json::Value;

use super::doc::{ActivityKind, CalloutKind, DiffChange, Doc, DocBuilder, Status};

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

const MAX_DETAIL_CHARS: usize = 4_000;

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
    turn: Option<TurnId>,
    turn_started_ms: u64,
    turn_slots: u32,
    turn_inputs: Vec<InputId>,
    pending_text: Option<(String, String)>,
    final_answer: Option<String>,
    interactions: HashMap<InteractionId, Interaction>,
}

impl Renderer {
    pub(crate) fn new(mode: OutputMode, vocabulary: Vocabulary, agent: impl Into<String>) -> Self {
        Self {
            mode,
            vocabulary,
            agent: agent.into(),
            next_slot: 1,
            slot: None,
            turn: None,
            turn_started_ms: 0,
            turn_slots: 0,
            turn_inputs: Vec::new(),
            pending_text: None,
            final_answer: None,
            interactions: HashMap::new(),
        }
    }

    pub(crate) fn mode(&self) -> OutputMode {
        self.mode
    }

    pub(crate) fn set_mode(&mut self, mode: OutputMode) {
        self.mode = mode;
    }

    pub(crate) fn apply(&mut self, envelope: &Envelope) -> Vec<RenderOp> {
        let mut ops = Vec::new();
        let now = envelope.at_ms;
        match &envelope.event {
            Event::Turn { turn, phase } => match phase {
                TurnPhase::Started { inputs } => {
                    self.turn = Some(turn.clone());
                    self.turn_started_ms = now;
                    self.turn_slots = 0;
                    self.turn_inputs = inputs.clone();
                    self.final_answer = None;
                    self.pending_text = None;
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
                        doc: closed_card(&interaction, by),
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
        if self.slot.is_none() {
            self.slot = Some(Slot {
                id: self.next_slot,
                started_ms: now,
                rows: Vec::new(),
            });
            self.next_slot += 1;
            self.turn_slots += 1;
        }
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
        let doc = self.progress_doc();
        if let Some(slot) = &self.slot
            && !doc.is_empty()
        {
            ops.push(RenderOp::Progress { slot: slot.id, doc });
        }
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
        if let Some(slot) = &self.slot {
            let doc = self.progress_doc();
            if !doc.is_empty() {
                ops.push(RenderOp::Progress { slot: slot.id, doc });
            }
        }
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
        let mut builder = DocBuilder::new();
        self.write_rows(&mut builder);
        if builder.is_empty() {
            // Nothing but the final answer happened: no progress message.
            self.slot = None;
            return;
        }
        builder.footer(&format!("{verb} {}", elapsed_text(elapsed_ms)));
        let full = self
            .slot
            .as_ref()
            .map(|slot| {
                slot.rows
                    .iter()
                    .filter_map(|row| {
                        let body = row.body.as_ref()?;
                        let text = row_full_text(body, &row.delta)?;
                        Some(FullDetail {
                            title: row_title(self.vocabulary, body).0,
                            text,
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        self.slot = None;
        ops.push(RenderOp::EndProgress {
            slot: id,
            doc: builder.finish(),
            full,
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
            let mut builder = DocBuilder::new();
            builder.paragraph(&text);
            ops.push(RenderOp::Final {
                doc: builder.finish(),
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
        self.write_rows(&mut builder);
        builder.finish()
    }

    fn write_rows(&self, builder: &mut DocBuilder) {
        let Some(slot) = &self.slot else {
            return;
        };
        for row in slot.rows.iter().filter(|row| row.parent.is_none()) {
            self.write_row(builder, slot, row);
        }
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
        let (title, meta, activity) = row_title(self.vocabulary, &body);
        let children: Vec<&Row> = match &body {
            ItemBody::Child { child, .. } => slot
                .rows
                .iter()
                .filter(|candidate| candidate.parent.as_deref() == Some(child.id.as_str()))
                .collect(),
            _ => Vec::new(),
        };
        builder.disclosure(&title, meta.as_deref(), activity, row.status, |inner| {
            row_detail(inner, &body, &row.delta);
            for child in children {
                self.write_row(inner, slot, child);
            }
        });
    }
}

fn update(text: &str) -> RenderOp {
    let mut builder = DocBuilder::new();
    builder.paragraph(text);
    RenderOp::Update {
        doc: builder.finish(),
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

fn tail(text: &str) -> String {
    let count = text.chars().count();
    if count <= MAX_DETAIL_CHARS {
        text.to_owned()
    } else {
        format!(
            "…\n{}",
            text.chars()
                .skip(count - MAX_DETAIL_CHARS)
                .collect::<String>()
        )
    }
}

/// Row summary, meta and activity in the harness's own vocabulary.
fn row_title(vocabulary: Vocabulary, body: &ItemBody) -> (String, Option<String>, ActivityKind) {
    match body {
        ItemBody::Command {
            command,
            actions,
            duration_ms,
            ..
        } => {
            let meta = duration_ms.map(|ms| elapsed_text(ms.max(1000)));
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
            let verb = match vocabulary {
                Vocabulary::Codex => "Edited",
                Vocabulary::Claude => "Edit",
            };
            let title = match changes.as_slice() {
                [only] => format!("{verb} {}", only.path.display()),
                many => format!("{verb} {} files", many.len()),
            };
            let activity = if changes
                .iter()
                .all(|change| change.change == FileChangeKind::Delete)
                && !changes.is_empty()
            {
                ActivityKind::Delete
            } else {
                ActivityKind::Edit
            };
            (title, None, activity)
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
                .map(|argument| first_line(argument, 60));
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
        ItemBody::Plan { .. } => ("Plan".to_owned(), None, ActivityKind::Unspecified),
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
fn row_detail(builder: &mut DocBuilder, body: &ItemBody, delta: &str) {
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
            for change in changes {
                let kind = match &change.change {
                    FileChangeKind::Add => DiffChange::Added,
                    FileChangeKind::Delete => DiffChange::Deleted,
                    FileChangeKind::Update { moved_to: Some(_) } => DiffChange::Renamed,
                    FileChangeKind::Update { moved_to: None } => DiffChange::Modified,
                };
                builder.diff(
                    &change.path.display().to_string(),
                    kind,
                    change.diff.as_deref().map(tail).as_deref(),
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
                ("Command", command.clone(), true),
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
                (
                    "Files",
                    paths
                        .iter()
                        .map(|path| path.display().to_string())
                        .collect::<Vec<_>>()
                        .join("\n"),
                    true,
                ),
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

fn question_card(agent: &str, form: &QuestionForm) -> Doc {
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

fn closed_card(interaction: &Interaction, by: &ClosedBy) -> Doc {
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
            match label {
                Some(label) => format!("{label} (answered by user {})", user.0),
                None => format!("Answered by user {}", user.0),
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
        assert!(ended[0].1.ends_with("Worked for 47s"), "{}", ended[0].1);
        assert_eq!(ended[1].0, 2);
        assert!(ended[1].1.contains("Ran cargo test"));
        assert!(
            !ended[1].1.contains("Done."),
            "the final answer is its own message"
        );
        assert!(matches!(ops.last(), Some(RenderOp::Final { doc }) if doc.text == "Done."));
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
                    doc: {
                        let mut builder = DocBuilder::new();
                        builder.paragraph("Fixed it.");
                        builder.finish()
                    }
                },
            ]
        );
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
