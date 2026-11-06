//! OpenCode session events to the bridge's session events.
//!
//! | OpenCode | Bridge |
//! | --- | --- |
//! | `session.execution.started` / `succeeded` / `failed` / `interrupted` | `Turn` started / completed |
//! | `session.inbox.enqueued` / `delivered` / `cancelled` | `Queue`, `Input` facts, user `Message` items |
//! | `session.text.*`, `session.reasoning.*` | `Message` / `Reasoning` items with deltas |
//! | `session.tool.*` | `Command`, `FileChange`, `Plan`, `Child` or `Tool` items |
//! | `session.step.ended`, `session.usage.updated` | `Usage` |
//! | `session.compaction.*` | `Usage` items |
//! | `permission.asked` / `replied` | approval `Interaction` / `InteractionClosed` |
//! | `form.created` / `replied` / `cancelled` | question `Interaction` / `InteractionClosed` |
//! | `session.model.selected`, `session.agent.selected` | `Settings` |
//! | `session.renamed` | `Renamed` |
//! | events of a sub-agent session | `Child` updates and items under that child |
//! | anything else | `Notice` (never dropped) |
//!
//! A turn is one OpenCode execution. It is named after the inbox entry that
//! started it, so the id Inline gave a prompt is also the id of the turn it
//! starts; an execution started from another client is named after that
//! client's prompt the same way.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;

use inline_agent_bridge::harness::{
    ApprovalSubject, ChildId, ChildKind, ChildRef, ChildStatus, ChildUpdate, ClosedBy, Decision,
    DecisionId, DecisionKind, DeltaStream, EffectiveSettings, Event, FieldId, FieldInput,
    FieldOption, FileChangeKind, FileDiff, FormField, InputFact, InputId, Interaction,
    InteractionId, InteractionKind, Item, ItemBody, ItemDelta, ItemId, ItemKind, ItemStatus,
    ItemUpdate, MessageRole, Notice, NoticeLevel, QuestionForm, QueueEntryId, QueuedInput,
    RunState, TokenUsage, UsageUpdate, UserId, WaitingOn,
};
use inline_agent_bridge::{DriverSettingOption, PlanStep, PlanStepStatus, TurnId, TurnOutcome};
use serde_json::{Value, json};

use crate::api::bounded;

const MAX_PREVIEW_CHARS: usize = 160;
const MAX_OUTPUT_CHARS: usize = 64_000;
const MAX_TRACKED: usize = 2048;
/// How long an uncorrelated prompt may be taken as the one a command made.
const COMMAND_WINDOW: std::time::Duration = std::time::Duration::from_secs(5);

/// Inline's metadata key on prompts, carrying the input id.
pub const INPUT_METADATA_KEY: &str = "inline.input";

/// One inbox entry this session knows about.
#[derive(Clone, Debug)]
struct InboxEntry {
    input: Option<InputId>,
    preview: String,
    text: String,
    queued: bool,
    /// A person's prompt (`user`), not synthetic context, a compaction or a move.
    user: bool,
}

/// The execution in progress.
#[derive(Clone, Debug)]
struct RunningTurn {
    id: TurnId,
    started_ms: Option<u64>,
    consumed: Vec<InputId>,
}

/// What an approval or question is bound to natively.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PendingKind {
    /// A permission request: reply with `once` / `always` / `reject`.
    Permission,
    /// A form: reply with an answer map, or cancel.
    Form {
        /// Native fields, kept to type the answers.
        fields: Value,
    },
}

/// A pending interaction and the session that must receive the reply.
#[derive(Clone, Debug)]
pub struct Pending {
    /// Native session (the parent or a sub-agent session).
    pub session: String,
    pub kind: PendingKind,
    /// Set while Inline's answer is on its way: OpenCode announces the
    /// reply before the request returns, and the close is Inline's.
    pub answering: Option<(UserId, Option<DecisionId>)>,
}

/// Per-session translation state.
#[derive(Debug)]
pub struct Mapper {
    session: String,
    folder: Option<PathBuf>,
    turn: Option<RunningTurn>,
    /// Native inbox id -> entry, for entries not yet delivered or cancelled.
    inbox: HashMap<String, InboxEntry>,
    inbox_order: VecDeque<String>,
    /// Inbox ids Inline sent, before the service echoes them.
    sent: HashMap<String, InputId>,
    /// Inbox entries delivered while no execution was known yet.
    early: Vec<InputId>,
    tools: HashMap<String, ToolCall>,
    completed: HashSet<String>,
    completed_order: VecDeque<String>,
    pending: HashMap<String, Pending>,
    children: HashMap<String, ChildState>,
    last_seq: Option<u64>,
    total: TokenUsage,
    settings: EffectiveSettings,
    context_window: Option<u64>,
    /// Inline asked the running turn to stop.
    stopping: bool,
    /// A retry is waiting on a rate limit.
    limited: bool,
    /// Inline input -> native inbox id.
    inputs: HashMap<InputId, String>,
    /// Commands sent, in order, waiting for the prompt OpenCode makes of them.
    commands: VecDeque<(InputId, std::time::Instant)>,
    /// Durable sequences applied per sub-agent session.
    child_seq: HashMap<String, u64>,
    /// Head of the log when the session was opened: a resync before any
    /// live durable event replays only what came after it.
    floor: Option<u64>,
}

#[derive(Clone, Debug)]
struct ChildState {
    child: ChildRef,
    title: Option<String>,
    running: bool,
}

#[derive(Clone, Debug)]
struct ToolCall {
    name: String,
    input: Value,
    started: bool,
    child: Option<ChildRef>,
    turn: Option<TurnId>,
}

impl Mapper {
    pub fn new(session: impl Into<String>, folder: Option<PathBuf>) -> Self {
        Self {
            session: session.into(),
            folder,
            turn: None,
            inbox: HashMap::new(),
            inbox_order: VecDeque::new(),
            sent: HashMap::new(),
            early: Vec::new(),
            tools: HashMap::new(),
            completed: HashSet::new(),
            completed_order: VecDeque::new(),
            pending: HashMap::new(),
            children: HashMap::new(),
            last_seq: None,
            total: TokenUsage::default(),
            settings: EffectiveSettings::default(),
            context_window: None,
            stopping: false,
            limited: false,
            inputs: HashMap::new(),
            commands: VecDeque::new(),
            child_seq: HashMap::new(),
            floor: None,
        }
    }

    /// The native session.
    pub fn session(&self) -> &str {
        &self.session
    }

    /// The running turn.
    pub fn turn(&self) -> Option<&TurnId> {
        self.turn.as_ref().map(|turn| &turn.id)
    }

    /// The last durable sequence applied for this session.
    pub fn last_seq(&self) -> Option<u64> {
        self.last_seq
    }

    /// Pending interactions with where their replies go.
    pub fn pending(&self, id: &str) -> Option<&Pending> {
        self.pending.get(id)
    }

    pub fn pending_ids(&self) -> Vec<InteractionId> {
        self.pending
            .keys()
            .filter_map(|id| InteractionId::new(id.as_str()).ok())
            .collect()
    }

    /// Running sub-agents.
    pub fn running_children(&self) -> Vec<ChildRef> {
        self.children
            .values()
            .filter(|child| child.running)
            .map(|child| child.child.clone())
            .collect()
    }

    /// Whether a native session is one of this session's sub-agents.
    pub fn child_session_known(&self, session: &str) -> bool {
        self.children.contains_key(session)
    }

    /// The native session of a child.
    pub fn child_session(&self, child: &ChildRef) -> Option<String> {
        self.children
            .iter()
            .find(|(_, state)| state.child == *child)
            .map(|(session, _)| session.clone())
    }

    /// Queued inbox entries, in order.
    pub fn queue(&self) -> Vec<QueuedInput> {
        self.inbox_order
            .iter()
            .filter_map(|id| {
                let entry = self.inbox.get(id)?;
                if !entry.queued {
                    return None;
                }
                Some(QueuedInput {
                    entry: QueueEntryId::new(id.as_str()).ok()?,
                    input: entry.input.clone(),
                    preview: entry.preview.clone(),
                })
            })
            .collect()
    }

    /// Effective settings as last reported.
    pub fn settings(&self) -> &EffectiveSettings {
        &self.settings
    }

    /// Records the model's context window for usage reports.
    pub fn set_context_window(&mut self, window: Option<u64>) {
        self.context_window = window;
    }

    /// Records an inbox id Inline is about to send, so the echo correlates
    /// even when it arrives before the HTTP response.
    pub fn expect(&mut self, inbox: &str, input: InputId) {
        self.inputs.insert(input.clone(), inbox.to_owned());
        self.sent.insert(inbox.to_owned(), input);
        bound(&mut self.sent);
        bound_inputs(&mut self.inputs);
    }

    /// The native message id an Inline input was sent as.
    pub fn inbox_of(&self, input: &InputId) -> Option<&String> {
        self.inputs.get(input)
    }

    /// Marks that Inline asked the running turn to stop.
    pub fn stopping(&mut self) {
        if self.turn.is_some() {
            self.stopping = true;
        }
    }

    /// Pending inbox ids, steers and queued alike.
    pub fn pending_inbox(&self) -> Vec<String> {
        self.inbox_order.clone().into()
    }

    /// Records a command Inline sent: OpenCode turns it into a prompt with
    /// its own id, and the next uncorrelated user prompt is that one.
    pub fn expect_command(&mut self, input: InputId) {
        self.commands
            .push_back((input, std::time::Instant::now() + COMMAND_WINDOW));
        while self.commands.len() > 16 {
            self.commands.pop_front();
        }
    }

    /// Forgets a command whose send failed or whose prompt never came.
    pub fn forget_command(&mut self, input: &InputId) {
        self.commands.retain(|(pending, _)| pending != input);
    }

    fn take_command(&mut self) -> Option<InputId> {
        let now = std::time::Instant::now();
        self.commands.retain(|(_, deadline)| *deadline > now);
        self.commands.pop_front().map(|(input, _)| input)
    }

    /// The log head read when the session opened.
    pub fn set_floor(&mut self, seq: Option<u64>) {
        self.floor = seq;
    }

    /// Where a resync replays from: the last applied event, else the floor.
    pub fn replay_after(&self) -> Option<u64> {
        self.last_seq.or(self.floor)
    }

    /// The last durable sequence applied for a sub-agent session.
    pub fn child_seq(&self, session: &str) -> Option<u64> {
        self.child_seq.get(session).copied()
    }

    /// Known sub-agent sessions with whether they run.
    pub fn children(&self) -> Vec<(String, bool)> {
        self.children
            .iter()
            .map(|(session, state)| (session.clone(), state.running))
            .collect()
    }

    /// Replaces the effective settings (read when the session opened).
    pub fn set_settings(&mut self, settings: EffectiveSettings) {
        self.settings = settings;
    }

    /// Records a permission preset Inline applied.
    pub fn set_permission_mode(&mut self, mode: String) -> Event {
        self.settings.permission_mode = Some(mode);
        Event::Settings {
            effective: self.settings.clone(),
        }
    }

    /// Forgets an inbox id whose send failed before the service saw it.
    pub fn forget(&mut self, inbox: &str) {
        if let Some(input) = self.sent.remove(inbox)
            && self.inputs.get(&input).map(String::as_str) == Some(inbox)
        {
            self.inputs.remove(&input);
        }
    }

    /// Whether an interaction is still pending.
    pub fn is_pending(&self, id: &str) -> bool {
        self.pending.contains_key(id)
    }

    /// Marks a pending interaction answered by Inline; returns its event.
    pub fn close(&mut self, id: &str, by: ClosedBy) -> Option<Event> {
        self.pending.remove(id)?;
        Some(Event::InteractionClosed {
            id: InteractionId::new(id).ok()?,
            by,
        })
    }

    /// Applies one native event. Durable events at or before the last applied
    /// sequence are duplicates (replayed after a resync) and are skipped.
    pub fn apply(&mut self, event: &Value) -> Vec<Event> {
        let kind = event
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let data = event.get("data").cloned().unwrap_or(Value::Null);
        let session = data
            .get("sessionID")
            .or_else(|| data.pointer("/form/sessionID"))
            .and_then(Value::as_str)
            .unwrap_or(self.session.as_str())
            .to_owned();
        if session == self.session
            && let Some(seq) = event.pointer("/durable/seq").and_then(Value::as_u64)
        {
            if self.last_seq.is_some_and(|last| seq <= last) {
                return Vec::new();
            }
            self.last_seq = Some(seq);
        }
        if session != self.session {
            if let Some(seq) = event.pointer("/durable/seq").and_then(Value::as_u64) {
                if self
                    .child_seq
                    .get(&session)
                    .is_some_and(|last| seq <= *last)
                {
                    return Vec::new();
                }
                self.child_seq.insert(session.clone(), seq);
            }
            return self.apply_child(kind, &session, &data, event);
        }
        match kind {
            "session.execution.started" => self.execution_started(event),
            "session.execution.succeeded" => {
                self.execution_ended(TurnOutcome::Completed, None, event)
            }
            "session.execution.failed" => {
                let error = data.get("error").map(error_text);
                let outcome = match data.pointer("/error/type").and_then(Value::as_str) {
                    Some(kind) if kind.contains("Auth") || kind.contains("auth") => {
                        TurnOutcome::AuthenticationRequired
                    }
                    _ => TurnOutcome::Failed,
                };
                self.execution_ended(outcome, error, event)
            }
            "session.execution.interrupted" => {
                let reason = data.get("reason").and_then(Value::as_str);
                // A rejected approval without feedback also ends the step
                // and reports `shutdown`; only an unrequested stop says why.
                let error = match reason {
                    _ if self.stopping => None,
                    Some("inactivity") => {
                        Some("OpenCode stopped the turn after inactivity".to_owned())
                    }
                    Some("shutdown") => Some("OpenCode stopped the turn".to_owned()),
                    Some("superseded") => {
                        Some("Another OpenCode client took over the turn".to_owned())
                    }
                    _ => None,
                };
                self.execution_ended(TurnOutcome::Interrupted, error, event)
            }
            "session.inbox.enqueued" => self.inbox_enqueued(&data),
            "session.inbox.delivered" => self.inbox_delivered(&data, event),
            "session.inbox.cancelled" => self.inbox_cancelled(&data),
            "session.inbox.delivery.changed" => {
                if let (Some(id), Some(delivery)) = (
                    data.get("inboxID").and_then(Value::as_str),
                    data.get("delivery").and_then(Value::as_str),
                ) && let Some(entry) = self.inbox.get_mut(id)
                {
                    entry.queued = delivery == "queue";
                }
                vec![Event::Queue {
                    entries: self.queue(),
                }]
            }
            "session.text.started" => self.text(&data, event, None),
            "session.text.delta" => {
                self.delta(&data, event, "text", DeltaStream::Text, ItemKind::Message)
            }
            "session.text.ended" => {
                let text = data
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                self.text(&data, event, Some(text))
            }
            "session.reasoning.started" => self.reasoning(&data, event, None),
            "session.reasoning.delta" => self.delta(
                &data,
                event,
                "reasoning",
                DeltaStream::ReasoningContent,
                ItemKind::Reasoning,
            ),
            "session.reasoning.ended" => {
                let text = data
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                self.reasoning(&data, event, Some(text))
            }
            "session.tool.input.started" => self.tool_input_started(&data, event, None),
            "session.tool.input.delta" | "session.tool.input.ended" => Vec::new(),
            "session.tool.called" => self.tool_called(&data, event, None),
            "session.tool.progress" => self.tool_progress(&data, event, None),
            "session.tool.success" => self.tool_finished(&data, event, ItemStatus::Completed, None),
            "session.tool.failed" => {
                let status = if is_rejection(&data) {
                    ItemStatus::Declined
                } else if self.turn.is_none() {
                    ItemStatus::Interrupted
                } else {
                    ItemStatus::Failed
                };
                self.tool_finished(&data, event, status, None)
            }
            "session.step.started" => self.step_started(&data),
            "session.step.ended" => self.step_ended(&data),
            // A stop Inline asked for, or the end of a rejected approval,
            // fails the step on purpose; the turn's end says enough.
            "session.step.failed" if self.stopping || self.turn.is_none() => Vec::new(),
            "session.step.failed" => {
                let message = data.get("error").map(error_text).unwrap_or_default();
                vec![Event::Notice(Notice {
                    level: NoticeLevel::Warning,
                    code: kind.to_owned(),
                    message: Some(message),
                    native: event.clone(),
                })]
            }
            "session.usage.updated" => self.usage_total(&data),
            "session.retry.scheduled" => self.retry(&data, event),
            "session.status" => self.status(&data),
            "session.compaction.started" => vec![Event::Item(Item::new(
                item_id(&format!("compaction:{}", event_id(event))),
                self.turn().cloned(),
                ItemUpdate::Started {
                    body: ItemBody::Usage {
                        label: "Compacting context".to_owned(),
                    },
                },
                event.clone(),
            ))],
            "session.compaction.ended" | "session.compaction.failed" => {
                let failed = kind.ends_with("failed");
                vec![Event::Item(Item::new(
                    item_id(&format!("compaction:{}", event_id(event))),
                    self.turn().cloned(),
                    ItemUpdate::Completed {
                        body: if failed {
                            ItemBody::Error {
                                message: format!(
                                    "Compaction failed: {}",
                                    data.get("error").map(error_text).unwrap_or_default()
                                ),
                            }
                        } else {
                            ItemBody::Usage {
                                label: "Context compacted".to_owned(),
                            }
                        },
                        status: if failed {
                            ItemStatus::Failed
                        } else {
                            ItemStatus::Completed
                        },
                    },
                    event.clone(),
                ))]
            }
            "session.shell.started" | "session.shell.ended" => self.shell(&data, event),
            "session.synthetic" => vec![Event::Item(Item::new(
                item_id(&format!("synthetic:{}", event_id(event))),
                self.turn().cloned(),
                ItemUpdate::Completed {
                    body: ItemBody::Message {
                        role: MessageRole::System,
                        text: data
                            .get("description")
                            .or_else(|| data.get("text"))
                            .and_then(Value::as_str)
                            .map(|text| bounded(text, MAX_PREVIEW_CHARS))
                            .unwrap_or_default(),
                        input: None,
                    },
                    status: ItemStatus::Completed,
                },
                event.clone(),
            ))],
            "session.skill.activated" => vec![Event::Notice(Notice {
                level: NoticeLevel::Info,
                code: kind.to_owned(),
                message: data
                    .get("name")
                    .and_then(Value::as_str)
                    .map(|name| format!("Using skill {name}")),
                native: event.clone(),
            })],
            "session.renamed" => data
                .get("title")
                .and_then(Value::as_str)
                .map(|title| Event::Renamed {
                    title: title.to_owned(),
                })
                .into_iter()
                .collect(),
            "session.model.selected" => {
                let reference = data.get("model").cloned().unwrap_or_default();
                self.settings.model =
                    crate::catalog::model_value(&reference).map(|value| DriverSettingOption {
                        label: value.clone(),
                        value,
                        description: None,
                        disabled: false,
                    });
                self.settings.effort = reference
                    .get("variant")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                vec![Event::Settings {
                    effective: self.settings.clone(),
                }]
            }
            "session.agent.selected" => {
                self.settings.mode = data.get("agent").and_then(Value::as_str).map(str::to_owned);
                vec![Event::Settings {
                    effective: self.settings.clone(),
                }]
            }
            "session.moved" => {
                self.folder = data
                    .pointer("/location/directory")
                    .and_then(Value::as_str)
                    .map(PathBuf::from);
                self.settings.folder = self.folder.clone();
                vec![Event::Settings {
                    effective: self.settings.clone(),
                }]
            }
            "permission.asked" => self.permission_asked(&data, event, None),
            "permission.replied" => self.interaction_settled(data.get("requestID")),
            "form.created" => self.form_created(&data, event, None),
            "form.replied" | "form.cancelled" => self.interaction_settled(data.get("id")),
            // Bookkeeping with no user-visible meaning: this session's own
            // creation, Inline's guide being attached, compaction streaming
            // (its summary arrives whole), and the deprecated idle signal.
            "session.idle"
            | "session.step.streamed"
            | "session.created"
            | "session.instructions.updated"
            | "session.compaction.delta"
            | "session.viewed"
            | "session.metadata.updated"
            | "session.permissions" => Vec::new(),
            "session.message.content.updated" => Vec::new(),
            _ => vec![Event::Notice(Notice {
                level: NoticeLevel::Info,
                code: kind.to_owned(),
                message: None,
                native: event.clone(),
            })],
        }
    }

    // MARK: turns

    fn execution_started(&mut self, event: &Value) -> Vec<Event> {
        let mut events = Vec::new();
        if let Some(previous) = self.turn.take() {
            // A start without the previous end: the end was lost.
            events.push(turn_completed(
                previous,
                TurnOutcome::ConnectionLost,
                None,
                None,
            ));
        }
        // Named after the oldest person's prompt waiting to run (synthetic
        // context and compactions do not start turns); otherwise the event.
        let first = self
            .inbox_order
            .iter()
            .find(|id| {
                self.inbox
                    .get(*id)
                    .is_some_and(|entry| entry.user && !entry.queued)
            })
            .or_else(|| {
                self.inbox_order
                    .iter()
                    .find(|id| self.inbox.get(*id).is_some_and(|entry| entry.user))
            })
            .cloned();
        let id = first
            .and_then(|id| TurnId::new(id).ok())
            .or_else(|| TurnId::new(event_id(event)).ok())
            .unwrap_or_else(|| TurnId::new("turn").expect("static turn id"));
        let started_ms = event.get("created").and_then(Value::as_u64);
        let inputs = std::mem::take(&mut self.early);
        events.push(Event::Turn {
            turn: id.clone(),
            phase: inline_agent_bridge::harness::TurnPhase::Started {
                inputs: inputs.clone(),
            },
        });
        self.stopping = false;
        self.turn = Some(RunningTurn {
            id,
            started_ms,
            consumed: inputs,
        });
        events
    }

    fn execution_ended(
        &mut self,
        outcome: TurnOutcome,
        error: Option<String>,
        event: &Value,
    ) -> Vec<Event> {
        let Some(turn) = self.turn.take() else {
            return Vec::new();
        };
        self.stopping = false;
        let ended = event.get("created").and_then(Value::as_u64);
        let duration = match (turn.started_ms, ended) {
            (Some(start), Some(end)) if end >= start => Some(end - start),
            _ => None,
        };
        let mut events = Vec::new();
        // Tools still open when the execution ends did not finish, whatever
        // turn they were first seen under.
        events.extend(self.close_open_tools(None, Some(turn.id.clone())));
        // Interactions die with their turn.
        let closed: Vec<String> = self
            .pending
            .iter()
            .filter(|(_, pending)| pending.session == self.session)
            .map(|(id, _)| id.clone())
            .collect();
        for id in closed {
            if let Some(event) = self.close(&id, ClosedBy::Cancelled) {
                events.push(event);
            }
        }
        events.push(turn_completed(turn, outcome, error, duration));
        events
    }

    // MARK: inbox

    fn inbox_enqueued(&mut self, data: &Value) -> Vec<Event> {
        let Some(id) = data.get("inboxID").and_then(Value::as_str) else {
            return Vec::new();
        };
        let item = data.get("item").cloned().unwrap_or_default();
        let text = item
            .pointer("/payload/text")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let kind = item.get("type").and_then(Value::as_str).unwrap_or("user");
        let input = self
            .sent
            .remove(id)
            .or_else(|| {
                item.pointer(&format!(
                    "/payload/metadata/{}",
                    INPUT_METADATA_KEY.replace('/', "~1")
                ))
                .and_then(Value::as_str)
                .and_then(|input| InputId::new(input).ok())
            })
            .or_else(|| (kind == "user").then(|| self.take_command()).flatten());
        if let Some(input) = &input {
            self.inputs.insert(input.clone(), id.to_owned());
            bound_inputs(&mut self.inputs);
        }
        let preview = match kind {
            "compaction" => "Compact context".to_owned(),
            "move" => "Move session".to_owned(),
            _ => bounded(
                text.split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ")
                    .as_str(),
                MAX_PREVIEW_CHARS,
            ),
        };
        let queued =
            item.get("delivery").and_then(Value::as_str) == Some("queue") && self.turn.is_some();
        self.inbox.insert(
            id.to_owned(),
            InboxEntry {
                input,
                preview,
                text,
                queued,
                user: kind == "user",
            },
        );
        self.inbox_order.push_back(id.to_owned());
        if queued {
            vec![Event::Queue {
                entries: self.queue(),
            }]
        } else {
            Vec::new()
        }
    }

    fn inbox_delivered(&mut self, data: &Value, event: &Value) -> Vec<Event> {
        let Some(id) = data.get("inboxID").and_then(Value::as_str) else {
            return Vec::new();
        };
        let entry = self.inbox.remove(id);
        self.inbox_order.retain(|entry| entry != id);
        let mut events = Vec::new();
        let was_queued = entry.as_ref().is_some_and(|entry| entry.queued);
        let input = entry
            .as_ref()
            .and_then(|entry| entry.input.clone())
            .or_else(|| self.sent.remove(id));
        if let Some(entry) = &entry
            && !entry.text.is_empty()
        {
            events.push(Event::Item(Item::new(
                item_id(id),
                self.turn().cloned(),
                ItemUpdate::Completed {
                    body: ItemBody::Message {
                        role: MessageRole::User,
                        text: entry.text.clone(),
                        input: input.clone(),
                    },
                    status: ItemStatus::Completed,
                },
                event.clone(),
            )));
        }
        if let Some(input) = input {
            match self.turn.as_mut() {
                Some(turn) => {
                    turn.consumed.push(input.clone());
                    events.push(Event::Input {
                        id: input,
                        fact: InputFact::Consumed {
                            turn: turn.id.clone(),
                        },
                    });
                }
                None => self.early.push(input),
            }
        }
        if was_queued {
            events.push(Event::Queue {
                entries: self.queue(),
            });
        }
        events
    }

    fn inbox_cancelled(&mut self, data: &Value) -> Vec<Event> {
        let Some(id) = data.get("inboxID").and_then(Value::as_str) else {
            return Vec::new();
        };
        let entry = self.inbox.remove(id);
        self.inbox_order.retain(|entry| entry != id);
        let mut events = Vec::new();
        if let Some(input) = entry
            .as_ref()
            .and_then(|entry| entry.input.clone())
            .or_else(|| self.sent.remove(id))
        {
            events.push(Event::Input {
                id: input,
                fact: InputFact::Cancelled,
            });
        }
        events.push(Event::Queue {
            entries: self.queue(),
        });
        events
    }

    // MARK: text and reasoning

    fn text(&mut self, data: &Value, event: &Value, text: Option<String>) -> Vec<Event> {
        let id = part_id(data, "text");
        if self.completed.contains(&id) {
            return Vec::new();
        }
        let body = ItemBody::Message {
            role: MessageRole::Assistant,
            text: text.clone().unwrap_or_default(),
            input: None,
        };
        let update = match text {
            Some(_) => {
                self.complete(&id);
                ItemUpdate::Completed {
                    body,
                    status: ItemStatus::Completed,
                }
            }
            None => ItemUpdate::Started { body },
        };
        vec![Event::Item(Item::new(
            item_id(&id),
            self.turn().cloned(),
            update,
            event.clone(),
        ))]
    }

    fn reasoning(&mut self, data: &Value, event: &Value, text: Option<String>) -> Vec<Event> {
        let id = part_id(data, "reasoning");
        if self.completed.contains(&id) {
            return Vec::new();
        }
        let body = ItemBody::Reasoning {
            summary: Vec::new(),
            content: text
                .clone()
                .into_iter()
                .filter(|text| !text.is_empty())
                .collect(),
        };
        let update = match text {
            Some(_) => {
                self.complete(&id);
                ItemUpdate::Completed {
                    body,
                    status: ItemStatus::Completed,
                }
            }
            None => ItemUpdate::Started { body },
        };
        vec![Event::Item(Item::new(
            item_id(&id),
            self.turn().cloned(),
            update,
            event.clone(),
        ))]
    }

    fn delta(
        &mut self,
        data: &Value,
        _event: &Value,
        part: &str,
        stream: DeltaStream,
        kind: ItemKind,
    ) -> Vec<Event> {
        let id = part_id(data, part);
        let Some(text) = data
            .get("delta")
            .and_then(Value::as_str)
            .filter(|text| !text.is_empty())
        else {
            return Vec::new();
        };
        // A delta replayed after its item completed would duplicate text.
        if self.completed.contains(&id) {
            return Vec::new();
        }
        vec![Event::Item(
            Item::new(
                item_id(&id),
                self.turn().cloned(),
                ItemUpdate::Delta {
                    delta: ItemDelta {
                        stream,
                        index: None,
                        text: text.to_owned(),
                    },
                },
                Value::Null,
            )
            .with_kind(kind),
        )]
    }

    fn complete(&mut self, id: &str) {
        if self.completed.insert(id.to_owned()) {
            self.completed_order.push_back(id.to_owned());
            while self.completed_order.len() > MAX_TRACKED {
                if let Some(oldest) = self.completed_order.pop_front() {
                    self.completed.remove(&oldest);
                }
            }
        }
    }

    // MARK: tools

    fn tool_input_started(
        &mut self,
        data: &Value,
        event: &Value,
        child: Option<ChildRef>,
    ) -> Vec<Event> {
        let Some(id) = data.get("id").and_then(Value::as_str).map(str::to_owned) else {
            return Vec::new();
        };
        if self.completed.contains(&id) {
            return Vec::new();
        }
        let name = data
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("tool")
            .to_owned();
        let call = self.tools.entry(id.clone()).or_insert_with(|| ToolCall {
            name: name.clone(),
            input: Value::Null,
            started: false,
            child: child.clone(),
            turn: None,
        });
        if call.started {
            return Vec::new();
        }
        call.started = true;
        call.turn = self.turn.as_ref().map(|turn| turn.id.clone());
        let body = tool_body(&name, &Value::Null, None, None, None, self.folder.as_ref());
        vec![Event::Item(
            Item::new(
                item_id(&id),
                call.turn.clone(),
                ItemUpdate::Started { body },
                event.clone(),
            )
            .with_parent(child),
        )]
    }

    fn tool_called(&mut self, data: &Value, event: &Value, child: Option<ChildRef>) -> Vec<Event> {
        let Some(id) = data.get("id").and_then(Value::as_str).map(str::to_owned) else {
            return Vec::new();
        };
        if self.completed.contains(&id) {
            return Vec::new();
        }
        let mut events = Vec::new();
        if !self.tools.get(&id).is_some_and(|call| call.started) {
            let name = data.get("name").and_then(Value::as_str).unwrap_or("tool");
            events.extend(self.tool_input_started(
                &json!({"id": id, "name": name}),
                event,
                child.clone(),
            ));
        }
        let Some(call) = self.tools.get_mut(&id) else {
            return events;
        };
        call.input = data.get("input").cloned().unwrap_or(Value::Null);
        let body = tool_body(
            &call.name,
            &call.input,
            None,
            None,
            None,
            self.folder.as_ref(),
        );
        events.push(Event::Item(
            Item::new(
                item_id(&id),
                call.turn.clone(),
                ItemUpdate::Updated { body },
                event.clone(),
            )
            .with_parent(child),
        ));
        events
    }

    fn tool_progress(
        &mut self,
        data: &Value,
        event: &Value,
        child: Option<ChildRef>,
    ) -> Vec<Event> {
        let Some(id) = data.get("id").and_then(Value::as_str) else {
            return Vec::new();
        };
        if self.completed.contains(id) {
            return Vec::new();
        }
        let Some(call) = self.tools.get(id) else {
            return Vec::new();
        };
        let metadata = data.get("metadata").cloned().unwrap_or(Value::Null);
        let output = metadata
            .get("output")
            .and_then(Value::as_str)
            .map(|text| tail(text, MAX_OUTPUT_CHARS));
        let body = tool_body(
            &call.name,
            &call.input,
            output.as_deref(),
            Some(&metadata),
            None,
            self.folder.as_ref(),
        );
        vec![Event::Item(
            Item::new(
                item_id(id),
                call.turn.clone(),
                ItemUpdate::Updated { body },
                event.clone(),
            )
            .with_parent(child),
        )]
    }

    fn tool_finished(
        &mut self,
        data: &Value,
        event: &Value,
        status: ItemStatus,
        child: Option<ChildRef>,
    ) -> Vec<Event> {
        let Some(id) = data.get("id").and_then(Value::as_str).map(str::to_owned) else {
            return Vec::new();
        };
        if self.completed.contains(&id) {
            return Vec::new();
        }
        let call = self.tools.remove(&id).unwrap_or(ToolCall {
            name: data
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("tool")
                .to_owned(),
            input: Value::Null,
            started: false,
            child: child.clone(),
            turn: self.turn().cloned(),
        });
        self.complete(&id);
        let output = content_text(data.get("content"));
        let metadata = data.get("metadata").cloned();
        let error = data.get("error").map(error_text);
        let mut events = Vec::new();
        let body = tool_body(
            &call.name,
            &call.input,
            output.as_deref(),
            metadata.as_ref(),
            error.as_deref(),
            self.folder.as_ref(),
        );
        events.push(Event::Item(
            Item::new(
                item_id(&id),
                call.turn.clone().or_else(|| self.turn().cloned()),
                ItemUpdate::Completed { body, status },
                event.clone(),
            )
            .with_parent(child),
        ));
        events
    }

    /// Completes, as interrupted, the tools still open for the main agent
    /// (`child` `None`) or one sub-agent, so no row stays "working".
    fn close_open_tools(&mut self, child: Option<&ChildRef>, turn: Option<TurnId>) -> Vec<Event> {
        let open: Vec<String> = self
            .tools
            .iter()
            .filter(|(_, call)| call.child.as_ref() == child)
            .map(|(id, _)| id.clone())
            .collect();
        let mut events = Vec::new();
        for id in open {
            let Some(call) = self.tools.remove(&id) else {
                continue;
            };
            self.complete(&id);
            events.push(Event::Item(
                Item::new(
                    item_id(&id),
                    turn.clone().or(call.turn.clone()),
                    ItemUpdate::Completed {
                        body: tool_body(
                            &call.name,
                            &call.input,
                            None,
                            None,
                            None,
                            self.folder.as_ref(),
                        ),
                        status: ItemStatus::Interrupted,
                    },
                    Value::Null,
                )
                .with_parent(call.child.clone()),
            ));
        }
        events
    }

    // MARK: steps and usage

    fn step_started(&mut self, data: &Value) -> Vec<Event> {
        let mut events = Vec::new();
        if std::mem::take(&mut self.limited) && self.turn.is_some() {
            events.push(Event::State {
                state: RunState::Working,
            });
        }
        let mut changed = false;
        if let Some(model) = data.get("model") {
            let value = crate::catalog::model_value(model);
            if self.settings.model.as_ref().map(|model| &model.value) != value.as_ref() {
                self.settings.model = value.map(|value| DriverSettingOption {
                    label: value.clone(),
                    value,
                    description: None,
                    disabled: false,
                });
                changed = true;
            }
            let effort = model
                .get("variant")
                .and_then(Value::as_str)
                .map(str::to_owned);
            if self.settings.effort != effort {
                self.settings.effort = effort;
                changed = true;
            }
        }
        let agent = data.get("agent").and_then(Value::as_str).map(str::to_owned);
        if agent.is_some() && self.settings.mode != agent {
            self.settings.mode = agent;
            changed = true;
        }
        if changed {
            events.push(Event::Settings {
                effective: self.settings.clone(),
            });
        }
        events
    }

    fn step_ended(&mut self, data: &Value) -> Vec<Event> {
        let Some(tokens) = data.get("tokens").map(tokens) else {
            return Vec::new();
        };
        vec![Event::Usage {
            usage: UsageUpdate {
                last: Some(tokens),
                total: None,
                context_window: self.context_window,
                limits: Vec::new(),
            },
        }]
    }

    fn usage_total(&mut self, data: &Value) -> Vec<Event> {
        let Some(total) = data.get("tokens").map(tokens) else {
            return Vec::new();
        };
        self.total = total;
        vec![Event::Usage {
            usage: UsageUpdate {
                last: None,
                total: Some(total),
                context_window: self.context_window,
                limits: Vec::new(),
            },
        }]
    }

    fn retry(&mut self, data: &Value, event: &Value) -> Vec<Event> {
        let attempt = data.get("attempt").and_then(Value::as_u64).unwrap_or(1);
        let message = data.get("error").map(error_text).unwrap_or_default();
        let at = data.get("at").and_then(Value::as_i64);
        let mut events = vec![Event::Notice(Notice {
            level: NoticeLevel::Warning,
            code: "session.retry.scheduled".to_owned(),
            message: Some(format!("Retrying (attempt {attempt}): {message}")),
            native: event.clone(),
        })];
        if is_rate_limit(data.get("error")) {
            self.limited = true;
            events.push(Event::State {
                state: RunState::Waiting {
                    on: WaitingOn::Limit {
                        resets_at: at.map(crate::catalog::milliseconds_to_seconds),
                    },
                },
            });
        }
        events
    }

    /// `session.status` is defined but not published by 2.2.5; a future
    /// `busy` after a rate-limit wait means work resumed.
    fn status(&mut self, data: &Value) -> Vec<Event> {
        match data.pointer("/status/type").and_then(Value::as_str) {
            Some("busy") if self.turn.is_some() && std::mem::take(&mut self.limited) => {
                vec![Event::State {
                    state: RunState::Working,
                }]
            }
            _ => Vec::new(),
        }
    }

    fn shell(&mut self, data: &Value, event: &Value) -> Vec<Event> {
        let Some(shell) = data.get("shell") else {
            return Vec::new();
        };
        let Some(id) = shell.get("id").and_then(Value::as_str) else {
            return Vec::new();
        };
        let ended = event.get("type").and_then(Value::as_str) == Some("session.shell.ended");
        let body = ItemBody::Command {
            command: shell
                .get("command")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            cwd: shell.get("cwd").and_then(Value::as_str).map(PathBuf::from),
            actions: Vec::new(),
            output: data
                .pointer("/output/output")
                .and_then(Value::as_str)
                .map(|text| tail(text, MAX_OUTPUT_CHARS)),
            exit_code: shell
                .get("exit")
                .and_then(Value::as_i64)
                .and_then(|code| i32::try_from(code).ok()),
            duration_ms: match (
                shell.pointer("/time/started").and_then(Value::as_u64),
                shell.pointer("/time/completed").and_then(Value::as_u64),
            ) {
                (Some(start), Some(end)) if end >= start => Some(end - start),
                _ => None,
            },
        };
        let status = match shell.get("status").and_then(Value::as_str) {
            Some("exited") if shell.get("exit").and_then(Value::as_i64).unwrap_or(0) == 0 => {
                ItemStatus::Completed
            }
            Some("killed") => ItemStatus::Interrupted,
            _ => ItemStatus::Failed,
        };
        let update = if ended {
            ItemUpdate::Completed { body, status }
        } else {
            ItemUpdate::Started { body }
        };
        vec![Event::Item(Item::new(
            item_id(&format!("shell:{id}")),
            self.turn().cloned(),
            update,
            event.clone(),
        ))]
    }

    // MARK: interactions

    fn permission_asked(
        &mut self,
        data: &Value,
        event: &Value,
        child: Option<ChildRef>,
    ) -> Vec<Event> {
        let Some(id) = data.get("id").and_then(Value::as_str) else {
            return Vec::new();
        };
        if self.pending.contains_key(id) {
            return Vec::new();
        }
        let Ok(interaction) = InteractionId::new(id) else {
            return Vec::new();
        };
        let session = data
            .get("sessionID")
            .and_then(Value::as_str)
            .unwrap_or(&self.session)
            .to_owned();
        self.pending.insert(
            id.to_owned(),
            Pending {
                session,
                kind: PendingKind::Permission,
                answering: None,
            },
        );
        let item = data
            .pointer("/source/id")
            .and_then(Value::as_str)
            .and_then(|id| ItemId::new(id).ok());
        vec![Event::Interaction(Interaction {
            id: interaction,
            turn: self.turn().cloned(),
            item,
            parent: child,
            kind: InteractionKind::Approval {
                subject: permission_subject(data, self.folder.as_ref()),
                decisions: permission_decisions(data),
            },
            native: event.clone(),
        })]
    }

    fn form_created(&mut self, data: &Value, event: &Value, child: Option<ChildRef>) -> Vec<Event> {
        let Some(form) = data.get("form") else {
            return Vec::new();
        };
        let Some(id) = form.get("id").and_then(Value::as_str) else {
            return Vec::new();
        };
        if self.pending.contains_key(id) {
            return Vec::new();
        }
        let Ok(interaction) = InteractionId::new(id) else {
            return Vec::new();
        };
        let fields = form.get("fields").cloned().unwrap_or_default();
        let session = form
            .get("sessionID")
            .and_then(Value::as_str)
            .unwrap_or(&self.session)
            .to_owned();
        let Some(question) = question_form(form) else {
            // A form Inline cannot show is still pending; the owner answers
            // it in OpenCode or it is cancelled.
            self.pending.insert(
                id.to_owned(),
                Pending {
                    session,
                    kind: PendingKind::Form { fields },
                    answering: None,
                },
            );
            return vec![Event::Interaction(Interaction {
                id: interaction,
                turn: self.turn().cloned(),
                item: None,
                parent: child,
                kind: InteractionKind::Dialog {
                    dialog: "form".to_owned(),
                },
                native: event.clone(),
            })];
        };
        self.pending.insert(
            id.to_owned(),
            Pending {
                session,
                kind: PendingKind::Form { fields },
                answering: None,
            },
        );
        vec![Event::Interaction(Interaction {
            id: interaction,
            turn: self.turn().cloned(),
            item: None,
            parent: child,
            kind: InteractionKind::Question { form: question },
            native: event.clone(),
        })]
    }

    fn interaction_settled(&mut self, id: Option<&Value>) -> Vec<Event> {
        let Some(id) = id.and_then(Value::as_str) else {
            return Vec::new();
        };
        let by = match self
            .pending
            .get(id)
            .and_then(|pending| pending.answering.clone())
        {
            Some((user, decision)) => ClosedBy::Inline { user, decision },
            None => ClosedBy::External,
        };
        self.close(id, by).into_iter().collect()
    }

    /// Marks an interaction as being answered from Inline.
    pub fn answering(&mut self, id: &str, by: UserId, decision: Option<DecisionId>) {
        if let Some(pending) = self.pending.get_mut(id) {
            pending.answering = Some((by, decision));
        }
    }

    /// Clears an answer that did not go through.
    pub fn not_answering(&mut self, id: &str) {
        if let Some(pending) = self.pending.get_mut(id) {
            pending.answering = None;
        }
    }

    // MARK: sub-agents

    fn apply_child(
        &mut self,
        kind: &str,
        session: &str,
        data: &Value,
        event: &Value,
    ) -> Vec<Event> {
        let child = self
            .children
            .entry(session.to_owned())
            .or_insert_with(|| ChildState {
                child: ChildRef {
                    id: ChildId::new(session)
                        .unwrap_or_else(|_| ChildId::new("child").expect("static id")),
                    kind: ChildKind::Subagent,
                },
                title: None,
                running: false,
            })
            .clone();
        let parent = Some(child.child.clone());
        let update = |state: &mut Self, status: ChildStatus, title: Option<String>| {
            if let Some(entry) = state.children.get_mut(session) {
                entry.running = matches!(
                    status,
                    ChildStatus::Started | ChildStatus::Running | ChildStatus::Waiting
                );
                if title.is_some() {
                    entry.title = title;
                }
            }
            let entry = state.children.get(session).cloned();
            vec![Event::Child {
                update: ChildUpdate {
                    child: child.child.clone(),
                    status,
                    title: entry.and_then(|entry| entry.title),
                    accepts_direct_input: false,
                    native: event.clone(),
                },
            }]
        };
        match kind {
            "session.created" => {
                let title = data.get("title").and_then(Value::as_str).map(str::to_owned);
                update(self, ChildStatus::Started, title)
            }
            "session.renamed" => {
                let title = data.get("title").and_then(Value::as_str).map(str::to_owned);
                let status = if child.running {
                    ChildStatus::Running
                } else {
                    ChildStatus::Completed
                };
                update(self, status, title)
            }
            "session.execution.started" => update(self, ChildStatus::Running, None),
            "session.execution.succeeded"
            | "session.execution.failed"
            | "session.execution.interrupted" => {
                let turn = self.turn().cloned();
                let mut events = self.close_open_tools(Some(&child.child), turn);
                // A sub-agent's approvals and questions end with it.
                let closed: Vec<String> = self
                    .pending
                    .iter()
                    .filter(|(_, pending)| pending.session == session)
                    .map(|(id, _)| id.clone())
                    .collect();
                for id in closed {
                    events.extend(self.close(&id, ClosedBy::Cancelled));
                }
                let status = match kind {
                    "session.execution.succeeded" => ChildStatus::Completed,
                    "session.execution.failed" => ChildStatus::Failed,
                    _ => ChildStatus::Stopped,
                };
                events.extend(update(self, status, None));
                events
            }
            "session.text.ended" => {
                let id = format!("{session}:{}", part_id(data, "text"));
                if self.completed.contains(&id) {
                    return Vec::new();
                }
                self.complete(&id);
                vec![Event::Item(
                    Item::new(
                        item_id(&id),
                        self.turn().cloned(),
                        ItemUpdate::Completed {
                            body: ItemBody::Message {
                                role: MessageRole::Assistant,
                                text: data
                                    .get("text")
                                    .and_then(Value::as_str)
                                    .unwrap_or_default()
                                    .to_owned(),
                                input: None,
                            },
                            status: ItemStatus::Completed,
                        },
                        event.clone(),
                    )
                    .with_parent(parent),
                )]
            }
            "session.tool.input.started" => self.tool_input_started(data, event, parent),
            "session.tool.called" => self.tool_called(data, event, parent),
            "session.tool.progress" => self.tool_progress(data, event, parent),
            "session.tool.success" => {
                self.tool_finished(data, event, ItemStatus::Completed, parent)
            }
            "session.tool.failed" => {
                let status = if is_rejection(data) {
                    ItemStatus::Declined
                } else {
                    ItemStatus::Failed
                };
                self.tool_finished(data, event, status, parent)
            }
            "permission.asked" => self.permission_asked(data, event, parent),
            "permission.replied" => self.interaction_settled(data.get("requestID")),
            "form.created" => self.form_created(data, event, parent),
            "form.replied" | "form.cancelled" => self.interaction_settled(data.get("id")),
            // Child streaming, usage and inbox detail stays in the child.
            _ => Vec::new(),
        }
    }

    /// Records a sub-agent session found while reading state (open or
    /// resync). Returns whether it was new.
    pub fn adopt_child(&mut self, session: &str, title: Option<String>, running: bool) -> bool {
        if let Some(state) = self.children.get_mut(session) {
            if title.is_some() {
                state.title = title;
            }
            return false;
        }
        let Ok(id) = ChildId::new(session) else {
            return false;
        };
        self.children.insert(
            session.to_owned(),
            ChildState {
                child: ChildRef {
                    id,
                    kind: ChildKind::Subagent,
                },
                title,
                running,
            },
        );
        true
    }

    /// A sub-agent the service no longer runs, though its end was not seen.
    pub fn child_idle(&mut self, session: &str) -> Vec<Event> {
        let Some(state) = self.children.get_mut(session).filter(|state| state.running) else {
            return Vec::new();
        };
        state.running = false;
        vec![Event::Child {
            update: ChildUpdate {
                child: state.child.clone(),
                status: ChildStatus::Completed,
                title: state.title.clone(),
                accepts_direct_input: false,
                native: Value::Null,
            },
        }]
    }

    /// Rebuilds the running turn when a session is opened mid-execution.
    pub fn resume_turn(&mut self, turn: TurnId) -> Event {
        self.turn = Some(RunningTurn {
            id: turn.clone(),
            started_ms: None,
            consumed: Vec::new(),
        });
        Event::Turn {
            turn,
            phase: inline_agent_bridge::harness::TurnPhase::Started { inputs: Vec::new() },
        }
    }

    /// Ends a turn the service can no longer report (its stream was lost and
    /// the session is idle now).
    pub fn abandon_turn(&mut self, outcome: TurnOutcome) -> Vec<Event> {
        match self.turn.take() {
            Some(turn) => vec![turn_completed(turn, outcome, None, None)],
            None => Vec::new(),
        }
    }

    /// Seeds inbox entries read while opening the session.
    pub fn seed_inbox(&mut self, entries: &Value) -> Vec<Event> {
        for entry in entries.as_array().into_iter().flatten() {
            let Some(id) = entry.get("id").and_then(Value::as_str) else {
                continue;
            };
            if self.inbox.contains_key(id) {
                continue;
            }
            self.inbox_enqueued(&json!({
                "inboxID": id,
                "item": {
                    "type": entry.get("type").cloned().unwrap_or(json!("user")),
                    "payload": entry.get("payload").cloned().unwrap_or_default(),
                    "delivery": entry.get("delivery").cloned().unwrap_or(json!("steer")),
                }
            }));
        }
        vec![Event::Queue {
            entries: self.queue(),
        }]
    }
}

fn turn_completed(
    turn: RunningTurn,
    outcome: TurnOutcome,
    error: Option<String>,
    duration_ms: Option<u64>,
) -> Event {
    Event::Turn {
        turn: turn.id,
        phase: inline_agent_bridge::harness::TurnPhase::Completed {
            outcome,
            inputs_consumed: turn.consumed,
            error,
            duration_ms,
        },
    }
}

fn bound<V>(map: &mut HashMap<String, V>) {
    if map.len() > MAX_TRACKED {
        let excess: Vec<String> = map.keys().take(map.len() - MAX_TRACKED).cloned().collect();
        for key in excess {
            map.remove(&key);
        }
    }
}

fn bound_inputs(map: &mut HashMap<InputId, String>) {
    if map.len() > MAX_TRACKED {
        let excess: Vec<InputId> = map.keys().take(map.len() - MAX_TRACKED).cloned().collect();
        for key in excess {
            map.remove(&key);
        }
    }
}

fn item_id(id: &str) -> ItemId {
    ItemId::new(id).unwrap_or_else(|_| ItemId::new("item").expect("static item id"))
}

fn event_id(event: &Value) -> String {
    event
        .get("id")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| {
            event
                .pointer("/durable/seq")
                .and_then(Value::as_u64)
                .map(|seq| format!("seq-{seq}"))
        })
        .unwrap_or_else(|| "event".to_owned())
}

/// `msg_x:text:0`.
fn part_id(data: &Value, part: &str) -> String {
    format!(
        "{}:{part}:{}",
        data.get("assistantMessageID")
            .and_then(Value::as_str)
            .unwrap_or("message"),
        data.get("ordinal").and_then(Value::as_u64).unwrap_or(0)
    )
}

fn tokens(value: &Value) -> TokenUsage {
    let get = |pointer: &str| value.pointer(pointer).and_then(Value::as_u64).unwrap_or(0);
    let input = get("/input");
    let output = get("/output");
    let reasoning = get("/reasoning");
    let cache_read = get("/cache/read");
    let cache_write = get("/cache/write");
    TokenUsage {
        input: input + cache_read + cache_write,
        cached_input: cache_read,
        output,
        reasoning,
        total: input + cache_read + cache_write + output + reasoning,
    }
}

/// A concise error message from `SessionStructuredError`.
pub fn error_text(error: &Value) -> String {
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .or_else(|| error.as_str())
        .unwrap_or("OpenCode reported an error");
    bounded(message.trim(), 500)
}

fn is_rate_limit(error: Option<&Value>) -> bool {
    let Some(error) = error else { return false };
    error.get("status").and_then(Value::as_u64) == Some(429)
        || error
            .get("type")
            .and_then(Value::as_str)
            .is_some_and(|kind| kind.to_ascii_lowercase().contains("rate"))
}

fn is_rejection(data: &Value) -> bool {
    data.pointer("/error/type")
        .and_then(Value::as_str)
        .is_some_and(|kind| {
            let kind = kind.to_ascii_lowercase();
            kind.contains("reject") || kind.contains("denied") || kind.contains("permission")
        })
}

fn content_text(content: Option<&Value>) -> Option<String> {
    let parts: Vec<String> = content?
        .as_array()?
        .iter()
        .filter_map(|part| match part.get("type").and_then(Value::as_str) {
            Some("text") => part.get("text").and_then(Value::as_str).map(str::to_owned),
            Some("file") => Some(format!(
                "[{}]",
                part.get("name")
                    .or_else(|| part.get("uri"))
                    .and_then(Value::as_str)
                    .unwrap_or("file")
            )),
            _ => None,
        })
        .collect();
    (!parts.is_empty()).then(|| tail(&parts.join("\n"), MAX_OUTPUT_CHARS))
}

fn tail(text: &str, max: usize) -> String {
    let count = text.chars().count();
    if count <= max {
        return text.to_owned();
    }
    format!("…{}", text.chars().skip(count - max).collect::<String>())
}

fn string<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_str))
        .filter(|text| !text.is_empty())
}

fn relative(path: &str, folder: Option<&PathBuf>) -> PathBuf {
    let path = PathBuf::from(path);
    match folder {
        Some(folder) if path.is_absolute() => {
            path.strip_prefix(folder).map(PathBuf::from).unwrap_or(path)
        }
        _ => path,
    }
}

/// The normalized body of one tool call.
pub fn tool_body(
    name: &str,
    input: &Value,
    output: Option<&str>,
    metadata: Option<&Value>,
    error: Option<&str>,
    folder: Option<&PathBuf>,
) -> ItemBody {
    let lower = name.to_ascii_lowercase();
    match lower.as_str() {
        "shell" | "bash" | "sh" => ItemBody::Command {
            command: string(input, &["command", "cmd"])
                .unwrap_or_default()
                .to_owned(),
            cwd: string(input, &["workdir", "cwd", "directory"]).map(PathBuf::from),
            actions: Vec::new(),
            output: output
                .map(str::to_owned)
                .or_else(|| {
                    metadata
                        .and_then(|metadata| metadata.get("output"))
                        .and_then(Value::as_str)
                        .map(|text| tail(text, MAX_OUTPUT_CHARS))
                })
                .or_else(|| error.map(str::to_owned)),
            exit_code: metadata
                .and_then(|metadata| metadata.get("exit").or_else(|| metadata.get("exitCode")))
                .filter(|_| output.is_some() || error.is_some())
                .and_then(Value::as_i64)
                .and_then(|code| i32::try_from(code).ok()),
            duration_ms: None,
        },
        "edit" | "write" | "patch" | "apply_patch" | "multiedit" | "multi_edit" => {
            let mut changes = Vec::new();
            if let Some(files) = metadata
                .and_then(|metadata| metadata.get("files").or_else(|| metadata.get("filediff")))
                .and_then(Value::as_array)
            {
                for file in files {
                    if let Some(path) = string(file, &["file", "filePath", "path"]) {
                        changes.push(FileDiff {
                            path: relative(path, folder),
                            change: match file.get("status").and_then(Value::as_str) {
                                Some("added") => FileChangeKind::Add,
                                Some("deleted") => FileChangeKind::Delete,
                                _ => FileChangeKind::Update { moved_to: None },
                            },
                            diff: string(file, &["patch", "diff"]).map(str::to_owned),
                        });
                    }
                }
            }
            if changes.is_empty()
                && let Some(path) = string(input, &["filePath", "file_path", "path", "file"])
            {
                changes.push(FileDiff {
                    path: relative(path, folder),
                    change: if lower == "write" {
                        FileChangeKind::Add
                    } else {
                        FileChangeKind::Update { moved_to: None }
                    },
                    diff: metadata
                        .and_then(|metadata| metadata.get("diff"))
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                });
            }
            if changes.is_empty() {
                return generic_tool(name, input, output, error);
            }
            ItemBody::FileChange { changes }
        }
        "todowrite" | "todo_write" | "todo" => {
            let todos = input
                .get("todos")
                .or_else(|| metadata.and_then(|metadata| metadata.get("todos")))
                .and_then(Value::as_array);
            match todos {
                Some(todos) => ItemBody::Plan {
                    explanation: None,
                    steps: todos
                        .iter()
                        .filter_map(|todo| {
                            let text = string(todo, &["content", "text", "title"])?;
                            Some(PlanStep {
                                text: bounded(text, 300),
                                status: match todo.get("status").and_then(Value::as_str) {
                                    Some("completed" | "done" | "cancelled") => {
                                        PlanStepStatus::Completed
                                    }
                                    Some("in_progress" | "in-progress" | "active") => {
                                        PlanStepStatus::InProgress
                                    }
                                    _ => PlanStepStatus::Pending,
                                },
                            })
                        })
                        .collect(),
                    text: None,
                },
                None => generic_tool(name, input, output, error),
            }
        }
        "subagent" | "task" => {
            let session = metadata
                .and_then(|metadata| {
                    metadata
                        .get("sessionID")
                        .or_else(|| metadata.get("sessionId"))
                })
                .and_then(Value::as_str);
            match session.and_then(|session| ChildId::new(session).ok()) {
                Some(id) => ItemBody::Child {
                    child: ChildRef {
                        id,
                        kind: ChildKind::Subagent,
                    },
                    action: string(input, &["agent", "subagent_type"]).map(str::to_owned),
                    prompt: string(input, &["description", "prompt"])
                        .map(|text| bounded(text, 300)),
                },
                None => generic_tool(name, input, output, error),
            }
        }
        _ => generic_tool(name, input, output, error),
    }
}

fn generic_tool(name: &str, input: &Value, output: Option<&str>, error: Option<&str>) -> ItemBody {
    let (server, tool) = match name.split_once('_') {
        // Client MCP and MCP servers are `<server>_<tool>`.
        Some((server, tool)) if server == crate::tools::SERVER_NAME => {
            (Some(server.to_owned()), tool.to_owned())
        }
        _ => (None, name.to_owned()),
    };
    ItemBody::Tool {
        name: tool,
        server,
        input: input.clone(),
        output: output.map(str::to_owned),
        error: error.map(str::to_owned),
    }
}

fn permission_subject(data: &Value, folder: Option<&PathBuf>) -> ApprovalSubject {
    let action = data
        .get("action")
        .and_then(Value::as_str)
        .unwrap_or("permission");
    let resources: Vec<&str> = data
        .get("resources")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let reason = data
        .get("message")
        .and_then(Value::as_str)
        .map(|text| bounded(text, 500));
    let metadata = data.get("metadata").cloned().unwrap_or_default();
    match action {
        "shell" | "bash" => ApprovalSubject::Command {
            command: string(&metadata, &["command"])
                .map(str::to_owned)
                .unwrap_or_else(|| resources.join(" && ")),
            cwd: string(&metadata, &["cwd", "workdir"]).map(PathBuf::from),
            reason,
            network_host: None,
            permissions: None,
        },
        "edit" | "write" | "patch" => ApprovalSubject::FileChange {
            paths: {
                let from_diffs: Vec<PathBuf> = metadata
                    .get("files")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|file| string(file, &["file", "path"]))
                    .map(|path| relative(path, folder))
                    .collect();
                if from_diffs.is_empty() {
                    resources
                        .iter()
                        .map(|path| relative(path, folder))
                        .collect()
                } else {
                    from_diffs
                }
            },
            reason,
            grant_root: None,
        },
        "external_directory" => ApprovalSubject::Permissions {
            summary: format!("Access {}", resources.join(", ")),
            reason,
        },
        _ => ApprovalSubject::Tool {
            name: action.to_owned(),
            input: if resources.is_empty() {
                metadata
            } else {
                json!({"resources": resources})
            },
            reason,
        },
    }
}

fn permission_decisions(data: &Value) -> Vec<Decision> {
    let save: Vec<&str> = data
        .get("save")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let decision = |id: &str,
                    label: String,
                    kind: DecisionKind,
                    description: Option<String>,
                    message: bool| Decision {
        id: DecisionId::new(id).expect("static decision id"),
        label,
        kind,
        description,
        accepts_message: message,
        native: json!(id),
    };
    let mut decisions = vec![decision(
        "once",
        "Allow once".to_owned(),
        DecisionKind::Accept,
        None,
        false,
    )];
    decisions.push(decision(
        "always",
        "Always allow".to_owned(),
        DecisionKind::AcceptAndRemember,
        (!save.is_empty()).then(|| format!("Saves: {}", bounded(&save.join(", "), 200))),
        false,
    ));
    decisions.push(decision(
        "reject",
        "Reject".to_owned(),
        DecisionKind::Decline,
        Some("Tell OpenCode what to do instead".to_owned()),
        true,
    ));
    decisions.push(decision(
        "stop",
        "Reject and stop".to_owned(),
        DecisionKind::Cancel,
        None,
        false,
    ));
    decisions
}

/// A form Inline can show as question cards, or `None`.
pub fn question_form(form: &Value) -> Option<QuestionForm> {
    let fields = form.get("fields")?.as_array()?;
    let mut out = Vec::new();
    for field in fields {
        if field
            .get("hidden")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            continue;
        }
        // Conditional fields would need live re-evaluation.
        if field
            .get("when")
            .is_some_and(|when| when.as_array().is_some_and(|when| !when.is_empty()))
        {
            return None;
        }
        let key = field.get("key")?.as_str()?;
        let prompt = string(field, &["description", "title"])
            .unwrap_or(key)
            .to_owned();
        let header = field
            .get("title")
            .and_then(Value::as_str)
            .filter(|title| Some(*title) != Some(prompt.as_str()))
            .map(str::to_owned);
        let options = |field: &Value| -> Vec<FieldOption> {
            field
                .get("options")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|option| {
                    Some(FieldOption {
                        label: option
                            .get("label")
                            .or_else(|| option.get("value"))?
                            .as_str()?
                            .to_owned(),
                        description: option
                            .get("description")
                            .and_then(Value::as_str)
                            .map(str::to_owned),
                    })
                })
                .collect()
        };
        let custom = field
            .get("custom")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let input = match field.get("type").and_then(Value::as_str)? {
            "string" if field.get("options").is_some() => FieldInput::Select {
                options: options(field),
                multiple: false,
                allow_other: custom,
            },
            "string" if looks_secret(field) => FieldInput::Secret,
            "string" => FieldInput::Text {
                multiline: field
                    .get("maxLength")
                    .and_then(Value::as_u64)
                    .is_none_or(|max| max > 200),
                default: field
                    .get("default")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
            },
            "multiselect" => FieldInput::Select {
                options: options(field),
                multiple: true,
                allow_other: custom,
            },
            "boolean" => FieldInput::Toggle {
                default: field.get("default").and_then(Value::as_bool),
            },
            "number" | "integer" => FieldInput::Number {
                default: field.get("default").and_then(Value::as_number).cloned(),
                min: field.get("minimum").and_then(Value::as_number).cloned(),
                max: field.get("maximum").and_then(Value::as_number).cloned(),
            },
            // External fields (OAuth links and the like) open in OpenCode.
            _ => return None,
        };
        out.push(FormField {
            id: FieldId::new(key).ok()?,
            header,
            prompt,
            input,
            required: field
                .get("required")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        });
    }
    if out.is_empty() {
        return None;
    }
    Some(QuestionForm {
        title: form.get("title").and_then(Value::as_str).map(str::to_owned),
        fields: out,
        asynchronous: false,
        auto_resolution_ms: None,
    })
}

/// A free-text field asking for a credential. OpenCode's question tool has
/// no secret flag, so the model's own wording decides: the answer is then
/// relayed without being stored or shown, never pasted into the thread.
fn looks_secret(field: &Value) -> bool {
    let text = ["key", "title", "description", "placeholder"]
        .iter()
        .filter_map(|key| field.get(*key).and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_lowercase();
    let words: Vec<&str> = text
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter(|word| !word.is_empty())
        .collect();
    let has = |word: &str| words.contains(&word);
    has("password")
        || has("passphrase")
        || has("passcode")
        || has("secret")
        || has("token")
        || has("pat")
        || has("apikey")
        || has("credential")
        || has("credentials")
        || (has("api") && has("key"))
        || (has("private") && has("key"))
        || (has("access") && has("key"))
        || field.get("format").and_then(Value::as_str) == Some("password")
}

/// Turns question answers into OpenCode's answer map, typed per field.
pub fn form_answer(
    fields: &Value,
    answers: &[inline_agent_bridge::harness::FieldAnswer],
) -> Result<Value, String> {
    let mut out = serde_json::Map::new();
    for answer in answers {
        let key = answer.field.as_str();
        let field = fields
            .as_array()
            .into_iter()
            .flatten()
            .find(|field| field.get("key").and_then(Value::as_str) == Some(key))
            .ok_or_else(|| format!("unknown field {key}"))?;
        // Options answer with their value, shown by label.
        let value_of = |label: &str| -> String {
            field
                .get("options")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .find(|option| option.get("label").and_then(Value::as_str) == Some(label))
                .and_then(|option| option.get("value").and_then(Value::as_str))
                .unwrap_or(label)
                .to_owned()
        };
        let value = match field.get("type").and_then(Value::as_str) {
            Some("multiselect") => json!(
                answer
                    .values
                    .iter()
                    .map(|label| value_of(label))
                    .collect::<Vec<_>>()
            ),
            Some("boolean") => {
                let text = answer
                    .values
                    .first()
                    .map(String::as_str)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                json!(matches!(text.as_str(), "true" | "yes" | "on" | "1"))
            }
            Some("number") => json!(
                answer
                    .values
                    .first()
                    .and_then(|text| text.trim().parse::<f64>().ok())
                    .ok_or_else(|| format!("{key} needs a number"))?
            ),
            Some("integer") => json!(
                answer
                    .values
                    .first()
                    .and_then(|text| text.trim().parse::<i64>().ok())
                    .ok_or_else(|| format!("{key} needs a whole number"))?
            ),
            _ => json!(
                answer
                    .values
                    .first()
                    .map(|label| value_of(label))
                    .unwrap_or_default()
            ),
        };
        out.insert(key.to_owned(), value);
    }
    Ok(Value::Object(out))
}

#[cfg(test)]
mod tests;
