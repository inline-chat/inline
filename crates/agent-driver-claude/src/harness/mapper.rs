//! Claude Code stream-json to the session contract.
//!
//! Pure and synchronous: the session feeds it every stdout frame, every
//! control request the CLI sends and every receipt, and emits what it
//! returns. Every native frame lands in the stream; anything without a typed
//! home becomes a [`Notice`] with its payload, never dropped and never read
//! as idle.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;

use inline_agent_bridge::harness::{
    ApprovalSubject, ChildId, ChildKind, ChildRef, ChildStatus, ChildUpdate, ClosedBy, Decision,
    DecisionId, DecisionKind, DeltaStream, EffectiveSettings, Event, FieldAnswer, FieldId,
    FieldInput, FieldOption, FileChangeKind, FileDiff, FormField, InputFact, InputId, Interaction,
    InteractionId, InteractionKind, InteractionResponse, Item, ItemBody, ItemDelta, ItemId,
    ItemStatus, ItemUpdate, LIVE_STATUS_NOTICE, MessageRole, Notice, NoticeLevel, OpError,
    QuestionForm, QueueEntryId, QueuedInput, RunState, TokenUsage, TurnPhase, UsageUpdate, UserId,
    WaitingOn,
};
use inline_agent_bridge::{
    AgentMessagePhase, DriverSettingOption, DriverUsageWindow, PlanStep, PlanStepStatus, TurnId,
    TurnOutcome,
};
use serde_json::{Map, Value, json};

use crate::control::{IncomingRequest, InterruptReceipt, PermissionDecision, PermissionRequest};
use crate::wire::{AssistantMessage, CliMessage, MessageKind, ResultMessage, TaskEvent, UserFrame};

/// Decision ids Inline offers for a Claude permission ask.
pub const ALLOW: &str = "allow";
pub const DENY: &str = "deny";
const SUGGESTION_PREFIX: &str = "allow:suggestion:";

/// What to answer the CLI with, plus the events the answer produces.
#[derive(Debug, PartialEq)]
pub struct AnswerPlan {
    pub request_id: String,
    pub response: Value,
    pub events: Vec<Event>,
}

/// How one CLI control request is handled.
#[derive(Debug, PartialEq)]
pub enum RequestMapped {
    /// An interaction opened; the answer comes from [`ClaudeMapper::answer`].
    Interaction(Vec<Event>),
    /// Reply now and emit the events (unsupported dialogs, elicitations).
    Reply {
        response: Result<Value, String>,
        events: Vec<Event>,
    },
    /// Answered elsewhere (MCP, hooks).
    NotMine,
}

#[derive(Clone, Debug)]
struct PendingAsk {
    request: PermissionRequest,
    decisions: Vec<Decision>,
}

#[derive(Clone, Debug)]
struct ToolItem {
    turn: Option<TurnId>,
    parent: Option<ChildRef>,
    body: ItemBody,
    native: Value,
    name: String,
    started: tokio::time::Instant,
}

/// One entry of Claude's task list (TaskCreate, TaskUpdate, TaskList).
#[derive(Clone, Debug, PartialEq)]
struct ClaudeTask {
    id: String,
    text: String,
    status: PlanStepStatus,
}

/// Claude Code's task tools: the default task list since 2.1.3xx, which
/// TodoWrite only replaces when the todo tools are turned on.
const TASK_TOOLS: [&str; 3] = ["TaskCreate", "TaskUpdate", "TaskList"];

/// Text kept from a server-side tool's result (web search hits, an
/// advisor's note), as much as a row's detail shows.
const MAX_SERVER_RESULT_CHARS: usize = 2_000;

/// Folds one session's frames into contract events.
#[derive(Clone, Debug, Default)]
pub struct ClaudeMapper {
    cwd: Option<PathBuf>,
    turn: Option<TurnId>,
    turn_inputs: Vec<InputId>,
    /// Inputs sent as new turns, oldest first, for CLIs without lifecycle frames.
    awaiting_turn: VecDeque<InputId>,
    /// Inputs this mapper saw sent (uuids Inline owns).
    sent: HashSet<String>,
    /// Passive inputs: their lifecycle never opens a turn.
    passive: HashSet<String>,
    /// Inline's notes sent ahead of an input: never an input of their own.
    notes: HashSet<String>,
    facts: HashSet<(String, &'static str)>,
    effective: EffectiveSettings,
    tools: HashMap<String, ToolItem>,
    /// Content blocks seen per API message id, for stable block item ids.
    blocks_seen: HashMap<String, usize>,
    /// The API message being streamed, per parent tool use (`""` = main).
    streaming: HashMap<String, String>,
    children: HashMap<String, ChildRef>,
    /// Agent/Task tool_use id → the child its nested frames belong to. The
    /// first one wins, so a sub-agent's rows keep the parent they started
    /// under when `task_started` later names the task.
    child_by_tool_use: HashMap<String, ChildRef>,
    /// Task id → the tool_use id that started it, for frames that carry
    /// only an `agent_id`.
    task_tool_use: HashMap<String, String>,
    /// Claude's task list, shared by the session and its sub-agents.
    tasks: Vec<ClaudeTask>,
    /// TaskCreate calls without a result yet, in order: (tool_use id, subject).
    pending_task_creates: Vec<(String, String)>,
    pending: HashMap<String, PendingAsk>,
    denied_tool_uses: HashSet<String>,
    /// `priority: later` inputs the CLI has not started yet.
    queue: Vec<QueuedInput>,
    /// The latest top-level call's tokens: the context fill the turn's
    /// result reports.
    last_call_usage: Option<TokenUsage>,
    /// Steers written and not yet taken by the CLI.
    unread_steers: HashSet<String>,
    /// The running turn was cut for a steer: its end is not a stop.
    superseded: bool,
    /// A top-level tool call is streaming, before its `assistant` frame.
    tool_call_starting: bool,
    compacting: bool,
    /// The running turn is a native command (`/compact`, `/clear`).
    command_turn: bool,
    /// The turn the latest `result` ended: what a prompt suggestion follows.
    ended_turn: Option<TurnId>,
}

impl ClaudeMapper {
    pub fn new(cwd: Option<PathBuf>) -> Self {
        Self {
            cwd,
            ..Self::default()
        }
    }

    /// The running turn, if any.
    pub fn turn(&self) -> Option<&TurnId> {
        self.turn.as_ref()
    }

    /// Running children and background tasks.
    pub fn live_children(&self) -> Vec<ChildRef> {
        self.children.values().cloned().collect()
    }

    pub fn pending_interactions(&self) -> Vec<InteractionId> {
        self.pending
            .keys()
            .filter_map(|id| InteractionId::new(id.as_str()).ok())
            .collect()
    }

    pub fn queue(&self) -> &[QueuedInput] {
        &self.queue
    }

    /// Records a queued input and returns the new queue.
    pub fn queued(&mut self, input: &InputId, text: &str) -> Vec<Event> {
        let Ok(entry) = QueueEntryId::new(input.as_str()) else {
            return Vec::new();
        };
        let preview: String = text.chars().take(200).collect();
        self.queue.push(QueuedInput {
            entry,
            input: Some(input.clone()),
            preview,
        });
        vec![Event::Queue {
            entries: self.queue.clone(),
        }]
    }

    fn dequeue(&mut self, input: &str) -> Vec<Event> {
        let before = self.queue.len();
        self.queue.retain(|queued| queued.entry.as_str() != input);
        if self.queue.len() == before {
            return Vec::new();
        }
        vec![Event::Queue {
            entries: self.queue.clone(),
        }]
    }

    pub fn effective(&self) -> &EffectiveSettings {
        &self.effective
    }

    /// Whether a person's steer may cut the running turn with `priority: now`:
    /// the model is working and nothing would be lost. A `now` during a tool
    /// call aborts it (a command that just started is killed), so those steers
    /// go as `next` and [`Self::detachable_tools`] clears the way instead. The
    /// other blockers follow Claude Code Desktop's.
    pub fn steer_can_cut(&self) -> bool {
        self.turn.is_some()
            && !self.tool_call_starting
            && !self.compacting
            && !self.command_turn
            && self.pending.is_empty()
            && self.unread_steers.is_empty()
            && !self.main_tools().any(|_| true)
    }

    /// Records a steer written to stdin, `cut` when it stops the running turn.
    pub fn sent_steer(&mut self, input: &InputId, cut: bool) {
        self.unread_steers.insert(input.as_str().to_string());
        self.superseded |= cut;
    }

    /// Whether a steer is still waiting for the CLI to take it.
    pub fn has_unread_steer(&self) -> bool {
        !self.unread_steers.is_empty()
    }

    /// Foreground work of the running turn at least `min_age` old that Claude
    /// can move to the background, so a waiting steer lands without killing it.
    pub fn detachable_tools(&self, min_age: std::time::Duration) -> Vec<String> {
        self.main_tools()
            .filter(|(_, tool)| {
                matches!(tool.name.as_str(), "Bash" | "PowerShell" | "Agent" | "Task")
                    && tool.started.elapsed() >= min_age
            })
            .map(|(id, _)| id.clone())
            .collect()
    }

    /// Records a native command that starts a turn.
    pub fn sent_command(&mut self) {
        self.command_turn = true;
    }

    /// A person asked to stop: the turn's end is a stop whatever was steered.
    pub fn stop_requested(&mut self) {
        self.superseded = false;
    }

    fn main_tools(&self) -> impl Iterator<Item = (&String, &ToolItem)> {
        self.tools.iter().filter(|(_, tool)| {
            tool.parent.is_none() && tool.turn.is_some() && tool.turn == self.turn
        })
    }

    /// Records an input written to stdin.
    pub fn sent(&mut self, input: &InputId, starts_turn: bool) {
        self.sent.insert(input.as_str().to_string());
        self.passive.remove(input.as_str());
        if starts_turn {
            self.awaiting_turn.push_back(input.clone());
        }
    }

    /// Undoes [`Self::sent`] for an input that never reached stdin.
    pub fn forget_sent(&mut self, input: &InputId) {
        self.sent.remove(input.as_str());
        self.passive.remove(input.as_str());
        self.unread_steers.remove(input.as_str());
        self.awaiting_turn.retain(|waiting| waiting != input);
    }

    /// Records Inline's note written just before an input (its own uuid).
    pub fn sent_note(&mut self, uuid: &str) {
        self.notes.insert(uuid.to_string());
    }

    /// Records passive context written to stdin (`shouldQuery: false`).
    pub fn sent_passive(&mut self, input: &InputId) {
        self.sent.insert(input.as_str().to_string());
        self.passive.insert(input.as_str().to_string());
    }

    /// One stdout message.
    pub fn message(&mut self, message: &CliMessage) -> Vec<Event> {
        match &message.kind {
            MessageKind::Init(init) => {
                if let Some(model) = &init.model {
                    self.effective.model = Some(DriverSettingOption {
                        value: model.clone(),
                        label: model.clone(),
                        description: None,
                        disabled: false,
                    });
                }
                if init.permission_mode.is_some() {
                    self.effective.permission_mode = init.permission_mode.clone();
                }
                if init.effort.is_some() {
                    self.effective.effort = init.effort.clone();
                }
                if let Some(cwd) = &init.cwd {
                    self.effective.folder = Some(PathBuf::from(cwd));
                    self.cwd.get_or_insert_with(|| PathBuf::from(cwd));
                }
                vec![Event::Settings {
                    effective: self.effective.clone(),
                }]
            }
            MessageKind::CommandLifecycle(lifecycle) => {
                self.lifecycle(&lifecycle.command_uuid, &lifecycle.state)
            }
            MessageKind::Assistant(assistant) => self.assistant(assistant, &message.raw),
            MessageKind::User(user) => self.user(user),
            MessageKind::StreamEvent(stream) => {
                self.stream_event(stream.parent_tool_use_id.as_deref(), &stream.event)
            }
            MessageKind::Result(result) => self.result(result),
            MessageKind::Task(task) => self.task(task, &message.raw),
            MessageKind::Status(status) => {
                let mut events = Vec::new();
                if let Some(mode) = &status.permission_mode
                    && self.effective.permission_mode.as_ref() != Some(mode)
                {
                    self.effective.permission_mode = Some(mode.clone());
                    events.push(Event::Settings {
                        effective: self.effective.clone(),
                    });
                }
                self.compacting = status.status.as_deref() == Some("compacting");
                if status.compact_result.as_deref() == Some("failed") {
                    // Only errors reach the chat; a failed /compact must.
                    events.push(notice(
                        NoticeLevel::Error,
                        "Compaction failed",
                        Some(compaction_failed_text(status.compact_error.as_deref())),
                        &message.raw,
                    ));
                } else if status.status.is_some() || status.compact_result.is_some() {
                    // "Compacting context" heads the progress while it runs;
                    // its end clears it.
                    events.push(notice(
                        NoticeLevel::Info,
                        LIVE_STATUS_NOTICE,
                        status_text(status),
                        &message.raw,
                    ));
                }
                events
            }
            MessageKind::CompactBoundary => {
                // The context's size after compaction: what the turn's
                // result reports as the fill, not the call before it.
                if let Some(tokens) = message.raw["compact_metadata"]["post_tokens"].as_u64() {
                    self.last_call_usage = Some(TokenUsage {
                        input: tokens,
                        cached_input: 0,
                        output: 0,
                        reasoning: 0,
                        total: tokens,
                    });
                }
                let id = message.uuid().unwrap_or("compact");
                vec![Event::Item(Item::new(
                    item_id(id),
                    self.turn.clone(),
                    ItemUpdate::Completed {
                        body: ItemBody::Usage {
                            label: "Context compacted".into(),
                        },
                        status: ItemStatus::Completed,
                    },
                    message.raw.clone(),
                ))]
            }
            MessageKind::RateLimit(limit) => rate_limit(&limit.rate_limit_info),
            // Host-only run-state signal; live work reads it from the client.
            MessageKind::SessionState(_) => Vec::new(),
            MessageKind::BackgroundTasksChanged => {
                vec![notice(
                    NoticeLevel::Info,
                    "system/background_tasks_changed",
                    None,
                    &message.raw,
                )]
            }
            MessageKind::System { subtype } => vec![system_notice(subtype, &message.raw)],
            MessageKind::PromptSuggestion(suggestion) => {
                let text = suggestion.suggestion.trim();
                // It follows the turn that just ended; one arriving after a
                // newer turn started is stale.
                if text.is_empty() || self.turn.is_some() {
                    return Vec::new();
                }
                vec![Event::PromptSuggestion {
                    turn: self.ended_turn.clone(),
                    text: text.to_owned(),
                }]
            }
            MessageKind::Other { message_type } => {
                vec![notice(NoticeLevel::Info, message_type, None, &message.raw)]
            }
        }
    }

    fn open_turn(&mut self, id: TurnId, inputs: Vec<InputId>) -> Vec<Event> {
        self.turn = Some(id.clone());
        self.turn_inputs = inputs.clone();
        for input in &inputs {
            self.awaiting_turn.retain(|waiting| waiting != input);
        }
        vec![Event::Turn {
            turn: id,
            phase: TurnPhase::Started { inputs },
        }]
    }

    /// Opens a turn for main-thread activity that arrived without a
    /// lifecycle frame (older CLIs, turns the CLI starts itself).
    fn ensure_turn(&mut self, fallback: Option<&str>) -> Vec<Event> {
        if self.turn.is_some() {
            return Vec::new();
        }
        if let Some(input) = self.awaiting_turn.pop_front()
            && let Ok(turn) = TurnId::new(input.as_str())
        {
            return self.open_turn(turn, vec![input]);
        }
        let id = fallback
            .map(str::to_string)
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        match TurnId::new(id) {
            Ok(turn) => self.open_turn(turn, Vec::new()),
            Err(_) => Vec::new(),
        }
    }

    fn lifecycle(&mut self, uuid: &str, state: &str) -> Vec<Event> {
        if state != "queued" {
            self.unread_steers.remove(uuid);
        }
        let mut events = if matches!(state, "started" | "cancelled" | "discarded" | "refused") {
            self.dequeue(uuid)
        } else {
            Vec::new()
        };
        events.extend(self.lifecycle_events(uuid, state));
        events
    }

    fn lifecycle_events(&mut self, uuid: &str, state: &str) -> Vec<Event> {
        if self.notes.contains(uuid) {
            if !matches!(state, "queued" | "started") {
                self.notes.remove(uuid);
            }
            return Vec::new();
        }
        let input = InputId::new(uuid).ok();
        match state {
            "started" => {
                if self.turn.is_none()
                    && !self.passive.contains(uuid)
                    && let Ok(turn) = TurnId::new(uuid)
                {
                    return self.open_turn(turn, input.into_iter().collect());
                }
                if let Some(input) = input
                    && !self.turn_inputs.contains(&input)
                {
                    self.turn_inputs.push(input);
                }
                Vec::new()
            }
            // An input the running turn already took is reported cancelled
            // when an interrupt or a steer-now aborts that turn; it was
            // consumed, not dropped (labs, 2.1.292 and 2.1.310).
            "cancelled"
                if input.as_ref().is_some_and(|input| {
                    self.turn_inputs.contains(input)
                        || self
                            .facts
                            .contains(&(input.as_str().to_string(), "consumed"))
                }) =>
            {
                Vec::new()
            }
            "cancelled" => {
                input.map_or_else(Vec::new, |input| self.fact(input, InputFact::Cancelled))
            }
            "discarded" | "refused" => input.map_or_else(Vec::new, |input| {
                self.fact(
                    input,
                    InputFact::Rejected {
                        reason: state.to_string(),
                    },
                )
            }),
            _ => Vec::new(),
        }
    }

    fn fact(&mut self, input: InputId, fact: InputFact) -> Vec<Event> {
        let key = match fact {
            InputFact::Consumed { .. } => "consumed",
            InputFact::Cancelled => "cancelled",
            InputFact::Rejected { .. } => "rejected",
        };
        if !self.facts.insert((input.as_str().to_string(), key)) {
            return Vec::new();
        }
        self.awaiting_turn.retain(|waiting| waiting != &input);
        vec![Event::Input { id: input, fact }]
    }

    /// The interrupt receipt: cancelled inputs become facts.
    pub fn interrupt_receipt(&mut self, receipt: &InterruptReceipt) -> Vec<Event> {
        receipt
            .cancelled
            .iter()
            .flatten()
            .filter_map(|uuid| InputId::new(uuid.as_str()).ok())
            .flat_map(|input| {
                let mut events = self.dequeue(input.as_str());
                events.extend(self.fact(input, InputFact::Cancelled));
                events
            })
            .collect()
    }

    /// The sub-agent a nested frame belongs to: the Agent/Task tool use that
    /// started it, so its rows keep one parent before and after
    /// `task_started` names the task (the Agent row nests them).
    fn parent(&self, parent_tool_use_id: Option<&str>, agent_id: Option<&str>) -> Option<ChildRef> {
        let tool_use = parent_tool_use_id.or_else(|| {
            agent_id
                .and_then(|agent| self.task_tool_use.get(agent))
                .map(String::as_str)
        });
        let Some(tool_use) = tool_use else {
            return agent_id.and_then(|agent| self.children.get(agent).cloned());
        };
        if let Some(child) = self.child_by_tool_use.get(tool_use) {
            return Some(child.clone());
        }
        Some(ChildRef {
            id: ChildId::new(tool_use).ok()?,
            kind: ChildKind::Subagent,
        })
    }

    fn block_index(&mut self, message_id: &str) -> usize {
        let seen = self.blocks_seen.entry(message_id.to_string()).or_insert(0);
        let index = *seen;
        *seen += 1;
        index
    }

    fn assistant(&mut self, assistant: &AssistantMessage, raw: &Value) -> Vec<Event> {
        let mut events = Vec::new();
        let parent = self.parent(
            assistant.parent_tool_use_id.as_deref(),
            assistant.agent_id.as_deref(),
        );
        if parent.is_none() {
            events.extend(self.ensure_turn(assistant.uuid.as_deref()));
        }
        if let Some(model) = &assistant.message.model
            && parent.is_none()
            && self
                .effective
                .model
                .as_ref()
                .is_none_or(|current| &current.value != model)
            && model != "<synthetic>"
        {
            self.effective.model = Some(DriverSettingOption {
                value: model.clone(),
                label: model.clone(),
                description: None,
                disabled: false,
            });
            events.push(Event::Settings {
                effective: self.effective.clone(),
            });
        }
        // The latest top-level call's usage is how full the context is.
        if parent.is_none()
            && let Some(last) = assistant.message.usage.as_ref().and_then(call_usage)
        {
            self.last_call_usage = Some(last);
        }
        let message_id = assistant
            .message
            .id
            .clone()
            .or_else(|| assistant.uuid.clone())
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        let turn = if parent.is_none() {
            self.turn.clone()
        } else {
            None
        };
        for block in &assistant.message.content {
            let index = self.block_index(&message_id);
            let block_type = block["type"].as_str().unwrap_or("");
            match block_type {
                "text" => events.push(Event::Item(
                    Item::new(
                        item_id(&format!("{message_id}:{index}")),
                        turn.clone(),
                        ItemUpdate::Completed {
                            body: ItemBody::Message {
                                role: MessageRole::Assistant,
                                text: block["text"].as_str().unwrap_or("").to_string(),
                                input: None,
                            },
                            status: ItemStatus::Completed,
                        },
                        block.clone(),
                    )
                    .with_parent(parent.clone()),
                )),
                "thinking" | "redacted_thinking" => {
                    let summary: Vec<String> = block["thinking"]
                        .as_str()
                        .filter(|text| !text.is_empty())
                        .map(|text| vec![text.to_string()])
                        .unwrap_or_default();
                    events.push(Event::Item(
                        Item::new(
                            item_id(&format!("{message_id}:{index}")),
                            turn.clone(),
                            ItemUpdate::Completed {
                                body: ItemBody::Reasoning {
                                    summary,
                                    content: Vec::new(),
                                },
                                status: ItemStatus::Completed,
                            },
                            block.clone(),
                        )
                        .with_parent(parent.clone()),
                    ));
                }
                "tool_use" | "server_tool_use" | "mcp_tool_use" => {
                    let id = block["id"].as_str().unwrap_or_default().to_string();
                    let name = block["name"].as_str().unwrap_or_default();
                    let body = if TASK_TOOLS.contains(&name) {
                        self.task_tool_started(&id, name, &block["input"])
                            .unwrap_or_else(|| tool_body(block))
                    } else {
                        tool_body(block)
                    };
                    if matches!(name, "Task" | "Agent")
                        && let Ok(child_id) = ChildId::new(id.as_str())
                    {
                        // The sub-agent's own frames nest under this tool use.
                        self.child_by_tool_use
                            .entry(id.clone())
                            .or_insert(ChildRef {
                                id: child_id,
                                kind: ChildKind::Subagent,
                            });
                    }
                    let item = Item::new(
                        item_id(&id),
                        turn.clone(),
                        ItemUpdate::Started { body: body.clone() },
                        block.clone(),
                    )
                    .with_parent(parent.clone());
                    // A friendly-mode update is a message, not progress.
                    let item = if block["name"] == "SendUserMessage" {
                        item.with_phase(Some(AgentMessagePhase::Commentary))
                    } else {
                        item
                    };
                    if parent.is_none() {
                        self.tool_call_starting = false;
                    }
                    self.tools.insert(
                        id,
                        ToolItem {
                            turn: turn.clone(),
                            parent: parent.clone(),
                            body,
                            native: block.clone(),
                            name: block["name"].as_str().unwrap_or_default().to_string(),
                            started: tokio::time::Instant::now(),
                        },
                    );
                    events.push(Event::Item(item));
                }
                // A server-side tool's result (web search, advisor, code
                // execution, MCP connector) completes its call.
                kind if kind.ends_with("_tool_result")
                    && block["tool_use_id"]
                        .as_str()
                        .is_some_and(|id| self.tools.contains_key(id)) =>
                {
                    let tool_use_id = block["tool_use_id"].as_str().unwrap_or_default();
                    let (output, is_error) = server_tool_result(block);
                    events.extend(self.finish_tool(tool_use_id, output, is_error, None, block));
                }
                _ => events.push(Event::Item(
                    Item::new(
                        item_id(&format!("{message_id}:{index}")),
                        turn.clone(),
                        ItemUpdate::Completed {
                            body: ItemBody::Unknown {
                                native_type: block_type.to_string(),
                                summary: None,
                            },
                            status: ItemStatus::Completed,
                        },
                        block.clone(),
                    )
                    .with_parent(parent.clone()),
                )),
            }
        }
        if let Some(error) = &assistant.error {
            events.push(notice(
                NoticeLevel::Warning,
                "assistant/error",
                error.as_str().map(str::to_string),
                raw,
            ));
        }
        events
    }

    fn user(&mut self, user: &UserFrame) -> Vec<Event> {
        if user.is_replay == Some(true) {
            return Vec::new();
        }
        let parent = self.parent(user.parent_tool_use_id.as_deref(), user.agent_id.as_deref());
        let mut events = Vec::new();
        let blocks: Vec<Value> = match &user.message["content"] {
            Value::Array(blocks) => blocks.clone(),
            Value::String(text) => vec![json!({"type": "text", "text": text})],
            _ => Vec::new(),
        };
        let mut texts = Vec::new();
        for block in &blocks {
            match block["type"].as_str() {
                Some("tool_result") => {
                    let tool_use_id = block["tool_use_id"].as_str().unwrap_or_default();
                    events.extend(self.tool_result(
                        tool_use_id,
                        block,
                        user.tool_use_result.as_ref(),
                    ));
                }
                Some("text") => {
                    if let Some(text) = block["text"].as_str() {
                        texts.push(text.to_string());
                    }
                }
                _ => {}
            }
        }
        if !texts.is_empty() && user.is_synthetic != Some(true) {
            let id = user
                .uuid
                .clone()
                .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
            let input = InputId::new(id.as_str())
                .ok()
                .filter(|_| self.sent.contains(&id));
            events.push(Event::Item(
                Item::new(
                    item_id(&id),
                    if parent.is_none() {
                        self.turn.clone()
                    } else {
                        None
                    },
                    ItemUpdate::Completed {
                        body: ItemBody::Message {
                            role: MessageRole::User,
                            text: texts.join("\n"),
                            input,
                        },
                        status: ItemStatus::Completed,
                    },
                    user.message.clone(),
                )
                .with_parent(parent),
            ));
        }
        events
    }

    fn tool_result(
        &mut self,
        tool_use_id: &str,
        block: &Value,
        structured: Option<&Value>,
    ) -> Vec<Event> {
        let output = result_text(&block["content"]);
        let is_error = block["is_error"].as_bool().unwrap_or(false);
        self.finish_tool(tool_use_id, output, is_error, structured, block)
    }

    /// Completes a tool call with its result, from a user `tool_result` or a
    /// server-side `*_tool_result` block.
    fn finish_tool(
        &mut self,
        tool_use_id: &str,
        output: String,
        is_error: bool,
        structured: Option<&Value>,
        block: &Value,
    ) -> Vec<Event> {
        let declined = self.denied_tool_uses.remove(tool_use_id);
        let status = if declined {
            ItemStatus::Declined
        } else if is_error && output.contains("[Request interrupted by user") {
            ItemStatus::Interrupted
        } else if is_error {
            ItemStatus::Failed
        } else {
            ItemStatus::Completed
        };
        let Some(tool) = self.tools.remove(tool_use_id) else {
            return vec![Event::Item(Item::new(
                item_id(tool_use_id),
                self.turn.clone(),
                ItemUpdate::Completed {
                    body: ItemBody::Unknown {
                        native_type: "tool_result".into(),
                        summary: Some(output),
                    },
                    status,
                },
                block.clone(),
            ))];
        };
        let body = if TASK_TOOLS.contains(&tool.name.as_str()) {
            // The task list after the call; a failed call shows as the tool.
            match self.task_tool_finished(
                tool_use_id,
                &tool.name,
                &tool.native["input"],
                structured,
                &output,
                is_error || declined,
            ) {
                Some(steps) => plan_body(steps),
                None => complete_body(tool_body(&tool.native), output, is_error, structured),
            }
        } else {
            complete_body(tool.body, output, is_error, structured)
        };
        let mut native = block.clone();
        if let Some(structured) = structured
            && let Some(object) = native.as_object_mut()
        {
            object.insert("tool_use_result".into(), structured.clone());
        }
        vec![Event::Item(
            Item::new(
                item_id(tool_use_id),
                tool.turn,
                ItemUpdate::Completed { body, status },
                native,
            )
            .with_parent(tool.parent),
        )]
    }

    fn stream_event(&mut self, parent_tool_use_id: Option<&str>, event: &Value) -> Vec<Event> {
        let key = parent_tool_use_id.unwrap_or("").to_string();
        let mut events = Vec::new();
        match event["type"].as_str() {
            Some("message_start") => {
                if parent_tool_use_id.is_none() {
                    events.extend(self.ensure_turn(None));
                    self.tool_call_starting = false;
                }
                if let Some(id) = event["message"]["id"].as_str() {
                    self.streaming.insert(key, id.to_string());
                }
            }
            Some("content_block_start")
                if parent_tool_use_id.is_none()
                    && event["content_block"]["type"]
                        .as_str()
                        .is_some_and(|kind| kind.ends_with("tool_use")) =>
            {
                self.tool_call_starting = true;
            }
            Some("content_block_delta") => {
                let Some(message_id) = self.streaming.get(&key).cloned() else {
                    return events;
                };
                let index = event["index"].as_u64().unwrap_or(0);
                let (stream, text, kind) = match event["delta"]["type"].as_str() {
                    Some("text_delta") => (
                        DeltaStream::Text,
                        event["delta"]["text"].as_str(),
                        inline_agent_bridge::harness::ItemKind::Message,
                    ),
                    Some("thinking_delta") => (
                        DeltaStream::ReasoningSummary,
                        event["delta"]["thinking"].as_str(),
                        inline_agent_bridge::harness::ItemKind::Reasoning,
                    ),
                    _ => return events,
                };
                let Some(text) = text.filter(|text| !text.is_empty()) else {
                    return events;
                };
                let parent = self.parent(parent_tool_use_id, None);
                let turn = if parent.is_none() {
                    self.turn.clone()
                } else {
                    None
                };
                events.push(Event::Item(
                    Item::new(
                        item_id(&format!("{message_id}:{index}")),
                        turn,
                        ItemUpdate::Delta {
                            delta: ItemDelta {
                                stream,
                                index: None,
                                text: text.to_string(),
                            },
                        },
                        Value::Null,
                    )
                    .with_kind(kind)
                    .with_parent(parent),
                ));
            }
            _ => {}
        }
        events
    }

    fn result(&mut self, result: &ResultMessage) -> Vec<Event> {
        let mut events = Vec::new();
        match result_usage(result) {
            Some(mut usage) => {
                usage.last = self.last_call_usage.take();
                events.push(Event::Usage { usage });
            }
            // A native command's result may carry no usage; the fill it
            // left (a compaction's) still counts.
            None => {
                if let Some(last) = self.last_call_usage.take() {
                    events.push(Event::Usage {
                        usage: UsageUpdate {
                            last: Some(last),
                            ..UsageUpdate::default()
                        },
                    });
                }
            }
        }
        let consumed: Vec<InputId> = match &result.user_message_uuids {
            Some(uuids) => {
                let notes_only =
                    !uuids.is_empty() && uuids.iter().all(|uuid| self.notes.contains(uuid));
                let consumed = uuids
                    .iter()
                    .filter(|uuid| !self.notes.remove(uuid.as_str()))
                    .filter_map(|uuid| InputId::new(uuid.as_str()).ok())
                    .collect();
                // A note on its own (an idle `shouldQuery: false`) is no turn.
                if notes_only && self.turn.is_none() {
                    return events;
                }
                consumed
            }
            None => self.turn_inputs.clone(),
        };
        let turn = match self.turn.take() {
            Some(turn) => turn,
            None => {
                // A turn with no frames (passive input, an aborted first turn).
                let id = consumed
                    .first()
                    .map(|input| input.as_str().to_string())
                    .or_else(|| result.uuid.clone())
                    .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
                let Ok(turn) = TurnId::new(id) else {
                    return events;
                };
                if result.num_turns == Some(0) && !result.is_error {
                    // shouldQuery:false only: no model call, no turn.
                    for input in consumed {
                        self.awaiting_turn.retain(|waiting| waiting != &input);
                    }
                    return events;
                }
                turn
            }
        };
        for input in &consumed {
            self.awaiting_turn.retain(|waiting| waiting != input);
            self.facts.insert((input.as_str().to_string(), "consumed"));
            self.unread_steers.remove(input.as_str());
            let dequeued = self.dequeue(input.as_str());
            events.extend(dequeued);
        }
        self.turn_inputs.clear();
        self.streaming.clear();
        self.ended_turn = Some(turn.clone());
        let outcome = turn_outcome(result);
        let superseded = std::mem::take(&mut self.superseded);
        self.tool_call_starting = false;
        self.compacting = false;
        self.command_turn = false;
        let error = (outcome == TurnOutcome::Failed).then(|| result.error_text());
        // Tool calls the turn left open ended with it: cut short when the
        // turn did not complete. A completed turn ends the server-side calls
        // (web search, advisor, MCP connectors) as done: their results come
        // as content blocks, which a newer API may shape differently.
        if outcome == TurnOutcome::Completed {
            events.extend(self.close_tools(
                |tool| tool.turn.as_ref() == Some(&turn) && is_server_tool(tool),
                ItemStatus::Completed,
            ));
        } else {
            events.extend(self.close_tools(
                |tool| tool.turn.as_ref() == Some(&turn),
                ItemStatus::Interrupted,
            ));
        }
        self.pending_task_creates.clear();
        // Cut for a steer, the turn did not stop: the steer carries on.
        let outcome = if superseded && outcome == TurnOutcome::Interrupted {
            TurnOutcome::Completed
        } else {
            outcome
        };
        events.push(Event::Turn {
            turn,
            phase: TurnPhase::Completed {
                outcome,
                inputs_consumed: consumed,
                error,
                duration_ms: result.duration_ms,
            },
        });
        if outcome == TurnOutcome::AuthenticationRequired {
            events.push(Event::State {
                state: RunState::Waiting {
                    on: WaitingOn::Setup {
                        reason: inline_agent_bridge::harness::SetupReason::SignIn,
                    },
                },
            });
        }
        if let Some(reason) = result.startup_failure_reason.as_deref() {
            events.push(Event::State {
                state: RunState::Waiting {
                    on: WaitingOn::Setup {
                        reason: super::setup_reason(reason, &result.error_text()),
                    },
                },
            });
        }
        events
    }

    fn task(&mut self, task: &TaskEvent, raw: &Value) -> Vec<Event> {
        let Ok(id) = ChildId::new(task.task_id.as_str()) else {
            return vec![notice(
                NoticeLevel::Info,
                &format!("system/{}", task.subtype),
                None,
                raw,
            )];
        };
        let child = match self.children.get(&task.task_id) {
            Some(child) => child.clone(),
            None => {
                let child = ChildRef {
                    id,
                    kind: child_kind(task, raw),
                };
                self.children.insert(task.task_id.clone(), child.clone());
                child
            }
        };
        if let Some(tool_use) = &task.tool_use_id {
            // The Agent tool use, when it was seen, stays the parent.
            self.child_by_tool_use
                .entry(tool_use.clone())
                .or_insert_with(|| child.clone());
            self.task_tool_use
                .insert(task.task_id.clone(), tool_use.clone());
        }
        let (status, title) = match task.subtype.as_str() {
            "task_started" => (ChildStatus::Started, task.description.clone()),
            "task_progress" => (ChildStatus::Running, task.description.clone()),
            "task_notification" => (
                child_status(task.status.as_deref()),
                task.summary.clone().or_else(|| task.description.clone()),
            ),
            _ => (child_status(task.effective_status()), None),
        };
        if matches!(
            status,
            ChildStatus::Completed | ChildStatus::Failed | ChildStatus::Stopped
        ) {
            self.children.remove(&task.task_id);
            self.task_tool_use.remove(&task.task_id);
        }
        vec![Event::Child {
            update: ChildUpdate {
                child,
                status,
                title,
                accepts_direct_input: false,
                native: raw.clone(),
            },
        }]
    }

    /// A control request from the CLI.
    pub fn request(&mut self, request_id: &str, request: &Value) -> RequestMapped {
        match IncomingRequest::parse(request) {
            IncomingRequest::CanUseTool(permission) => {
                let Ok(id) = InteractionId::new(request_id) else {
                    return RequestMapped::Reply {
                        response: Ok(PermissionDecision::deny("invalid request id")
                            .to_value(&permission.input)),
                        events: Vec::new(),
                    };
                };
                let parent = permission
                    .agent_id
                    .as_deref()
                    .and_then(|agent| self.parent(None, Some(agent)));
                let item = permission
                    .tool_use_id
                    .as_deref()
                    .and_then(|id| ItemId::new(id).ok());
                let (kind, decisions) = if permission.is_ask_user_question() {
                    (
                        InteractionKind::Question {
                            form: question_form(&permission),
                        },
                        Vec::new(),
                    )
                } else {
                    let decisions = approval_decisions(&permission, self.cwd.as_deref());
                    (
                        InteractionKind::Approval {
                            subject: approval_subject(&permission, self.cwd.as_deref()),
                            decisions: decisions.clone(),
                        },
                        decisions,
                    )
                };
                self.pending.insert(
                    request_id.to_string(),
                    PendingAsk {
                        request: permission,
                        decisions,
                    },
                );
                RequestMapped::Interaction(vec![Event::Interaction(Interaction {
                    id,
                    turn: if parent.is_none() {
                        self.turn.clone()
                    } else {
                        None
                    },
                    item,
                    parent,
                    kind,
                    native: request.clone(),
                })])
            }
            IncomingRequest::UserDialog(dialog) => RequestMapped::Reply {
                // Undeclared kinds are never answered "cancelled" (that is a
                // real settlement); an error is discarded and the CLI times out.
                response: Err(format!(
                    "dialog kind {} is not supported",
                    dialog.dialog_kind
                )),
                // Shown in the chat: the person should know Claude asked.
                events: vec![notice(
                    NoticeLevel::Error,
                    "Request declined",
                    Some(format!(
                        "Claude asked for a {} dialog Inline can't show yet, so it was declined.",
                        dialog.dialog_kind
                    )),
                    request,
                )],
            },
            IncomingRequest::Elicitation(raw) => RequestMapped::Reply {
                // Nobody was asked, so it is dismissed ("cancel"), never a
                // person's explicit "no" ("decline").
                response: Ok(json!({"action": "cancel"})),
                // Shown in the chat: cancelling silently left people wondering
                // why the tool didn't run.
                events: vec![notice(
                    NoticeLevel::Error,
                    "Request cancelled",
                    Some(elicitation_cancelled_text(&raw)),
                    request,
                )],
            },
            IncomingRequest::McpMessage { .. } | IncomingRequest::HookCallback(_) => {
                RequestMapped::NotMine
            }
            IncomingRequest::Other { subtype, .. } => RequestMapped::Reply {
                response: Err(format!("Unsupported control request subtype: {subtype}")),
                events: vec![notice(
                    NoticeLevel::Info,
                    &format!("control_request/{subtype}"),
                    None,
                    request,
                )],
            },
        }
    }

    /// The CLI withdrew a request.
    pub fn cancelled(&mut self, request_id: &str) -> Vec<Event> {
        if self.pending.remove(request_id).is_none() {
            return Vec::new();
        }
        InteractionId::new(request_id)
            .map(|id| {
                vec![Event::InteractionClosed {
                    id,
                    by: ClosedBy::Cancelled,
                }]
            })
            .unwrap_or_default()
    }

    /// Answers a pending interaction.
    pub fn answer(
        &mut self,
        interaction: &InteractionId,
        response: &InteractionResponse,
        by: UserId,
    ) -> Result<AnswerPlan, OpError> {
        let pending = self
            .pending
            .get(interaction.as_str())
            .cloned()
            .ok_or(OpError::InteractionNotPending)?;
        let input = &pending.request.input;
        let (decision, picked) = match response {
            InteractionResponse::Decision { decision, message } => {
                let offered = pending
                    .decisions
                    .iter()
                    .find(|offered| &offered.id == decision)
                    .ok_or_else(|| {
                        OpError::InvalidResponse(format!("decision {decision} was not offered"))
                    })?;
                let decision_value = if offered.id.as_str() == DENY {
                    PermissionDecision::deny(
                        message
                            .clone()
                            .filter(|text| !text.trim().is_empty())
                            .unwrap_or_else(|| {
                                "The user doesn't want to proceed with this tool use.".into()
                            }),
                    )
                } else {
                    PermissionDecision::Allow {
                        updated_input: None,
                        updated_permissions: offered.native["updatedPermissions"]
                            .as_array()
                            .cloned()
                            .unwrap_or_default(),
                    }
                };
                (decision_value, Some(decision.clone()))
            }
            InteractionResponse::Answers { answers } => {
                if !pending.request.is_ask_user_question() {
                    return Err(OpError::InvalidResponse(
                        "this interaction takes a decision".into(),
                    ));
                }
                (
                    PermissionDecision::answer_questions(
                        input,
                        answers_map(&pending.request, answers),
                    ),
                    None,
                )
            }
            InteractionResponse::Cancel => (
                PermissionDecision::deny("The user dismissed this request."),
                None,
            ),
        };
        if matches!(decision, PermissionDecision::Deny { .. })
            && let Some(tool_use) = &pending.request.tool_use_id
        {
            self.denied_tool_uses.insert(tool_use.clone());
        }
        self.pending.remove(interaction.as_str());
        Ok(AnswerPlan {
            request_id: interaction.as_str().to_string(),
            response: decision.to_value(input),
            events: vec![Event::InteractionClosed {
                id: interaction.clone(),
                by: ClosedBy::Inline {
                    user: by,
                    decision: picked,
                },
            }],
        })
    }

    /// Everything still open when the process goes away.
    pub fn connection_lost(&mut self) -> Vec<Event> {
        let mut events: Vec<Event> = self
            .pending
            .drain()
            .filter_map(|(id, _)| InteractionId::new(id).ok())
            .map(|id| Event::InteractionClosed {
                id,
                by: ClosedBy::Cancelled,
            })
            .collect();
        // Every call still open died with the process.
        events.extend(self.close_tools(|_| true, ItemStatus::Interrupted));
        self.pending_task_creates.clear();
        if let Some(turn) = self.turn.take() {
            events.push(Event::Turn {
                turn,
                phase: TurnPhase::Completed {
                    outcome: TurnOutcome::ConnectionLost,
                    inputs_consumed: std::mem::take(&mut self.turn_inputs),
                    error: None,
                    duration_ms: None,
                },
            });
        }
        events
    }

    /// Ends the open tool calls `which` picks, in the order they started.
    fn close_tools(&mut self, which: impl Fn(&ToolItem) -> bool, status: ItemStatus) -> Vec<Event> {
        let mut open: Vec<(String, ToolItem)> = self
            .tools
            .iter()
            .filter(|(_, tool)| which(tool))
            .map(|(id, tool)| (id.clone(), tool.clone()))
            .collect();
        open.sort_by_key(|(_, tool)| tool.started);
        open.into_iter()
            .map(|(id, tool)| {
                self.tools.remove(&id);
                Event::Item(
                    Item::new(
                        item_id(&id),
                        tool.turn,
                        ItemUpdate::Completed {
                            body: tool.body,
                            status,
                        },
                        Value::Null,
                    )
                    .with_parent(tool.parent),
                )
            })
            .collect()
    }

    /// The body a task tool starts with: the task list as the call would
    /// leave it, or `None` to show the call itself.
    fn task_tool_started(&mut self, id: &str, name: &str, input: &Value) -> Option<ItemBody> {
        let mut tasks = self.tasks.clone();
        match name {
            "TaskCreate" => {
                let subject = trimmed(&input["subject"])?;
                self.pending_task_creates
                    .push((id.to_string(), subject.to_string()));
            }
            // An unknown task (one from before this process) shows as the call.
            "TaskUpdate" if !apply_task_update(&mut tasks, input, None) => return None,
            _ => {}
        }
        let steps = self.task_steps(&tasks);
        (!steps.is_empty()).then(|| plan_body(steps))
    }

    /// Applies a finished task tool to the list. The steps to show, or
    /// `None` when the call failed or left nothing to list.
    fn task_tool_finished(
        &mut self,
        id: &str,
        name: &str,
        input: &Value,
        structured: Option<&Value>,
        output: &str,
        failed: bool,
    ) -> Option<Vec<PlanStep>> {
        self.pending_task_creates
            .retain(|(pending, _)| pending != id);
        if failed {
            return None;
        }
        match name {
            "TaskCreate" => {
                let created = structured.map(|value| &value["task"]);
                let from_text = created_task_from_text(output);
                let task_id = created
                    .and_then(|task| trimmed(&task["id"]))
                    .map(str::to_string)
                    .or_else(|| from_text.as_ref().map(|(id, _)| id.clone()))?;
                let text = created
                    .and_then(|task| trimmed(&task["subject"]))
                    .map(str::to_string)
                    .or_else(|| from_text.map(|(_, subject)| subject))
                    .or_else(|| trimmed(&input["subject"]).map(str::to_string))?;
                let task = ClaudeTask {
                    id: task_id,
                    text,
                    status: PlanStepStatus::Pending,
                };
                match self.tasks.iter_mut().find(|known| known.id == task.id) {
                    Some(known) => *known = task,
                    None => self.tasks.push(task),
                }
            }
            "TaskUpdate" => {
                // A result without structure is the subagent's text.
                let succeeded = match structured {
                    Some(result) if result.is_object() => result["success"] != false,
                    _ => output.starts_with("Updated task #"),
                };
                if !succeeded {
                    return None;
                }
                apply_task_update(&mut self.tasks, input, structured);
            }
            "TaskList" => {
                let listed = structured.and_then(|value| value["tasks"].as_array())?;
                self.tasks = listed
                    .iter()
                    .filter_map(|task| {
                        Some(ClaudeTask {
                            id: trimmed(&task["id"])?.to_string(),
                            text: trimmed(&task["subject"])?.to_string(),
                            status: task_status(&task["status"])?,
                        })
                    })
                    .collect();
            }
            _ => return None,
        }
        let steps = self.task_steps(&self.tasks);
        (!steps.is_empty()).then_some(steps)
    }

    /// The task list as steps, with creations still waiting for their id.
    fn task_steps(&self, tasks: &[ClaudeTask]) -> Vec<PlanStep> {
        tasks
            .iter()
            .map(|task| PlanStep {
                text: task.text.clone(),
                status: task.status,
            })
            .chain(
                self.pending_task_creates
                    .iter()
                    .map(|(_, subject)| PlanStep {
                        text: subject.clone(),
                        status: PlanStepStatus::Pending,
                    }),
            )
            .collect()
    }
}

/// A call the API runs itself, whose result arrives in assistant content.
fn is_server_tool(tool: &ToolItem) -> bool {
    matches!(
        tool.native["type"].as_str(),
        Some("server_tool_use" | "mcp_tool_use")
    )
}

fn trimmed(value: &Value) -> Option<&str> {
    value
        .as_str()
        .map(str::trim)
        .filter(|text| !text.is_empty())
}

fn task_status(value: &Value) -> Option<PlanStepStatus> {
    match value.as_str()? {
        "pending" => Some(PlanStepStatus::Pending),
        "in_progress" => Some(PlanStepStatus::InProgress),
        "completed" => Some(PlanStepStatus::Completed),
        _ => None,
    }
}

/// TaskUpdate's effect on a known task: a new subject or status, or its
/// removal. Whether the task was known.
fn apply_task_update(tasks: &mut Vec<ClaudeTask>, input: &Value, result: Option<&Value>) -> bool {
    let Some(id) = trimmed(&input["taskId"]).or_else(|| result.and_then(|r| trimmed(&r["taskId"])))
    else {
        return false;
    };
    let Some(index) = tasks.iter().position(|task| task.id == id) else {
        return false;
    };
    if input["status"] == "deleted" {
        tasks.remove(index);
        return true;
    }
    let task = &mut tasks[index];
    if let Some(text) = trimmed(&input["subject"]) {
        task.text = text.to_string();
    }
    if let Some(status) = task_status(&input["status"]) {
        task.status = status;
    }
    true
}

/// A subagent's TaskCreate result has only text:
/// "Task #3 created successfully: <subject>".
fn created_task_from_text(output: &str) -> Option<(String, String)> {
    let rest = output.trim().strip_prefix("Task #")?;
    let (id, subject) = rest.split_once(" created successfully: ")?;
    let (id, subject) = (id.trim(), subject.trim());
    (!id.is_empty() && !id.contains(char::is_whitespace) && !subject.is_empty())
        .then(|| (id.to_string(), subject.to_string()))
}

fn plan_body(steps: Vec<PlanStep>) -> ItemBody {
    ItemBody::Plan {
        explanation: None,
        steps,
        text: None,
    }
}

fn item_id(id: &str) -> ItemId {
    ItemId::new(id)
        .unwrap_or_else(|_| ItemId::new(uuid::Uuid::new_v4().to_string()).expect("uuid id"))
}

/// What a cancelled MCP elicitation asked, for the chat.
fn elicitation_cancelled_text(raw: &Value) -> String {
    let server = raw["mcp_server_name"]
        .as_str()
        .or_else(|| raw["server_name"].as_str())
        .filter(|name| !name.trim().is_empty());
    let asked = raw["message"]
        .as_str()
        .map(|message| message.trim().chars().take(160).collect::<String>())
        .filter(|message| !message.is_empty());
    let from = server.map_or_else(
        || "An MCP server".to_owned(),
        |name| format!("The {name} MCP server"),
    );
    match asked {
        Some(asked) => format!(
            "{from} asked for input Inline can't show yet, so it was cancelled: \u{201c}{asked}\u{201d}"
        ),
        None => format!("{from} asked for input Inline can't show yet, so it was cancelled."),
    }
}

/// The first `max` characters of a trimmed text, marked when cut.
fn clip(text: &str, max: usize) -> String {
    let text = text.trim();
    match text.char_indices().nth(max) {
        Some((end, _)) => format!("{}\u{2026}", text[..end].trim_end()),
        None => text.to_string(),
    }
}

fn compaction_failed_text(error: Option<&str>) -> String {
    match error.map(str::trim).filter(|error| !error.is_empty()) {
        Some(error) => format!("Claude couldn't compact the context: {}", clip(error, 300)),
        None => "Claude couldn't compact the context.".to_string(),
    }
}

/// A `system` frame without a typed home. Only errors reach the chat, so
/// the ones that stop Claude are raised to errors with a human title; the
/// rest stay info notices for the logs.
fn system_notice(subtype: &str, raw: &Value) -> Event {
    let content = raw["content"]
        .as_str()
        .map(str::trim)
        .filter(|text| !text.is_empty());
    match subtype {
        "model_refusal_no_fallback" => notice(
            NoticeLevel::Error,
            "Claude declined to respond",
            Some(
                content
                    .or_else(|| trimmed(&raw["api_refusal_explanation"]))
                    .map_or_else(
                        || "The model stopped without an answer, and no fallback model could retry it.".to_string(),
                        |text| clip(text, 300),
                    ),
            ),
            raw,
        ),
        // A Stop hook ended the turn.
        "informational" if raw["prevent_continuation"] == true => notice(
            NoticeLevel::Error,
            "Stopped by a hook",
            Some(content.map_or_else(
                || "A hook stopped Claude from continuing.".to_string(),
                |text| clip(text, 300),
            )),
            raw,
        ),
        // A UserPromptSubmit hook blocked, stopped or dropped the message.
        "informational" if raw["prompt_submit_outcome"]["kind"].is_string() => notice(
            NoticeLevel::Error,
            "Message blocked by a hook",
            Some(content.map_or_else(
                || "A hook kept this message from reaching Claude.".to_string(),
                |text| clip(text, 300),
            )),
            raw,
        ),
        // Claude Code retries a failed API call (overloaded, rate limited):
        // the progress says so instead of a silent "Working".
        "api_retry" => notice(NoticeLevel::Info, LIVE_STATUS_NOTICE, Some(retry_text(raw)), raw),
        _ => notice(NoticeLevel::Info, &format!("system/{subtype}"), None, raw),
    }
}

fn notice(level: NoticeLevel, code: &str, message: Option<String>, native: &Value) -> Event {
    Event::Notice(Notice {
        level,
        code: code.to_string(),
        message,
        native: native.clone(),
    })
}

/// "Retrying (3/10) · overloaded", from an `api_retry` frame.
fn retry_text(raw: &Value) -> String {
    let attempt = raw["attempt"].as_u64();
    let max = raw["max_retries"].as_u64();
    let count = match (attempt, max) {
        (Some(attempt), Some(max)) => format!(" ({attempt}/{max})"),
        (Some(attempt), None) => format!(" ({attempt})"),
        _ => String::new(),
    };
    let reason = match raw["error_status"].as_u64() {
        Some(529) => Some("overloaded".to_owned()),
        Some(429) => Some("rate limited".to_owned()),
        Some(status) if status >= 500 => Some("server error".to_owned()),
        _ => raw["error"].as_str().map(|error| clip(error, 60)),
    };
    match reason {
        Some(reason) => format!("Retrying{count} · {reason}"),
        None => format!("Retrying{count}"),
    }
}

fn status_text(status: &crate::wire::StatusMessage) -> Option<String> {
    match (status.status.as_deref(), status.compact_result.as_deref()) {
        (Some("compacting"), _) => Some("Compacting context".into()),
        (_, Some("failed")) => Some(format!(
            "Compaction failed{}",
            status
                .compact_error
                .as_deref()
                .map(|error| format!(": {error}"))
                .unwrap_or_default()
        )),
        _ => None,
    }
}

/// Tool name and server: `mcp__server__tool` keeps the server apart.
fn tool_name(name: &str) -> (String, Option<String>) {
    if let Some(rest) = name.strip_prefix("mcp__")
        && let Some((server, tool)) = rest.split_once("__")
    {
        return (tool.to_string(), Some(server.to_string()));
    }
    (name.to_string(), None)
}

fn tool_body(block: &Value) -> ItemBody {
    let name = block["name"].as_str().unwrap_or("tool");
    let input = &block["input"];
    match name {
        "Bash" => ItemBody::Command {
            command: input["command"].as_str().unwrap_or("").to_string(),
            cwd: None,
            actions: Vec::new(),
            output: None,
            exit_code: None,
            duration_ms: None,
        },
        "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => {
            let path = input["file_path"]
                .as_str()
                .or_else(|| input["notebook_path"].as_str())
                .unwrap_or("");
            ItemBody::FileChange {
                changes: vec![FileDiff {
                    path: PathBuf::from(path),
                    change: if name == "Write" {
                        FileChangeKind::Add
                    } else {
                        FileChangeKind::Update { moved_to: None }
                    },
                    diff: None,
                }],
            }
        }
        "TodoWrite" => ItemBody::Plan {
            explanation: None,
            steps: input["todos"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|todo| PlanStep {
                    text: todo["content"].as_str().unwrap_or("").to_string(),
                    status: match todo["status"].as_str() {
                        Some("in_progress") => PlanStepStatus::InProgress,
                        Some("completed") => PlanStepStatus::Completed,
                        _ => PlanStepStatus::Pending,
                    },
                })
                .collect(),
            text: None,
        },
        "ExitPlanMode" => ItemBody::Plan {
            explanation: None,
            steps: Vec::new(),
            text: input["plan"].as_str().map(str::to_string),
        },
        // A sub-agent: its own rows nest under this one by its tool use id
        // (see `ClaudeMapper::parent`).
        "Agent" | "Task" => match block["id"].as_str().and_then(|id| ChildId::new(id).ok()) {
            Some(id) => ItemBody::Child {
                child: ChildRef {
                    id,
                    kind: ChildKind::Subagent,
                },
                action: trimmed(&input["subagent_type"]).map(str::to_string),
                prompt: trimmed(&input["description"])
                    .or_else(|| trimmed(&input["prompt"]))
                    .map(str::to_string),
                output: None,
            },
            None => generic_tool(name, input),
        },
        "SendUserMessage" => ItemBody::Message {
            role: MessageRole::Assistant,
            text: input["message"]
                .as_str()
                .or_else(|| input["text"].as_str())
                .or_else(|| input["content"].as_str())
                .unwrap_or("")
                .to_string(),
            input: None,
        },
        _ => generic_tool(name, input),
    }
}

fn generic_tool(name: &str, input: &Value) -> ItemBody {
    let (name, server) = tool_name(name);
    ItemBody::Tool {
        name,
        server,
        input: input.clone(),
        output: None,
        error: None,
    }
}

/// What a sub-agent reported, without the frame Claude Code puts around it
/// for the model (the hand-back note, tools-used and harness notes, agent id
/// and usage). A background launch has reported nothing yet.
fn subagent_report(output: &str, is_error: bool, structured: Option<&Value>) -> Option<String> {
    let parts: Vec<String> = match structured
        .and_then(|value| value.get("status"))
        .and_then(Value::as_str)
    {
        Some("completed") => structured
            .and_then(|value| value["content"].as_array())
            .into_iter()
            .flatten()
            .filter_map(|part| part.get("text").and_then(Value::as_str))
            .map(str::to_owned)
            .collect(),
        Some("async_launched" | "remote_launched") => return None,
        _ if output.trim_start().starts_with("Async agent launched") => return None,
        _ if is_error => {
            let text = output.trim();
            return (!text.is_empty()).then(|| text.to_owned());
        }
        _ => vec![output.to_owned()],
    };
    // Claude Code can hand the report back twice, once inside its frame.
    let mut kept: Vec<String> = Vec::new();
    for part in parts {
        if let Some(report) = unframed_report(&part)
            && !kept.contains(&report)
        {
            kept.push(report);
        }
    }
    (!kept.is_empty()).then(|| kept.join("\n\n"))
}

fn unframed_report(text: &str) -> Option<String> {
    let is_frame = |line: &str| {
        let line = line.trim();
        line.is_empty()
            || line.starts_with("<tools-used")
            || line.starts_with("[Harness note")
            || line.starts_with("agentId:")
    };
    let text = text
        .find("The report follows:")
        .map_or(text, |index| &text[index + "The report follows:".len()..]);
    let mut lines: Vec<&str> = text.lines().collect();
    if let Some(usage) = lines
        .iter()
        .rposition(|line| line.trim_start().starts_with("<usage>"))
    {
        lines.truncate(usage);
    }
    while lines.last().is_some_and(|line| is_frame(line)) {
        lines.pop();
    }
    while lines.first().is_some_and(|line| is_frame(line)) {
        lines.remove(0);
    }
    // Claude Code indents the report; it reads unindented.
    let indent = lines
        .iter()
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.len() - line.trim_start_matches(' ').len())
        .min()
        .unwrap_or(0);
    let text = lines
        .iter()
        .map(|line| {
            if line.len() >= indent && line[..indent].bytes().all(|byte| byte == b' ') {
                &line[indent..]
            } else {
                line.trim_start()
            }
        })
        .collect::<Vec<_>>()
        .join("\n");
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

fn complete_body(
    body: ItemBody,
    output: String,
    is_error: bool,
    structured: Option<&Value>,
) -> ItemBody {
    match body {
        ItemBody::Command {
            command,
            cwd,
            actions,
            duration_ms,
            ..
        } => {
            let (exit_code, output) = command_exit(output, is_error, structured);
            ItemBody::Command {
                command,
                cwd,
                actions,
                output: Some(output),
                exit_code,
                duration_ms,
            }
        }
        ItemBody::Tool {
            name,
            server,
            input,
            ..
        } => ItemBody::Tool {
            name,
            server,
            input,
            output: (!is_error).then(|| output.clone()),
            error: is_error.then_some(output),
        },
        // The sub-agent's final report (or why it failed).
        ItemBody::Child {
            child,
            action,
            prompt,
            ..
        } => ItemBody::Child {
            child,
            action,
            prompt,
            output: subagent_report(&output, is_error, structured),
        },
        ItemBody::FileChange { mut changes } => {
            if let Some(structured) = structured
                && let Some(change) = changes.first_mut()
            {
                // Write says whether it created the file or replaced one.
                match structured["type"].as_str() {
                    Some("create") => change.change = FileChangeKind::Add,
                    Some("update") => change.change = FileChangeKind::Update { moved_to: None },
                    _ => {}
                }
                let patch = structured["structuredPatch"]
                    .as_array()
                    .filter(|patch| !patch.is_empty());
                if let Some(patch) = patch {
                    change.diff = Some(render_patch(patch));
                } else if structured["type"] == "create"
                    && let Some(content) = structured["content"].as_str()
                    && !content.is_empty()
                {
                    // A new file has no patch: every line is added, as
                    // Claude Write approvals show it.
                    change.diff = Some(added_lines(content));
                }
            }
            ItemBody::FileChange { changes }
        }
        other => other,
    }
}

/// A Bash call's exit code and output. Claude reports no code: a failure is
/// an error result whose text starts `Exit code N`, which is dropped from
/// the output. A plain success is 0; an interrupted, backgrounded or
/// reinterpreted run ("No matches found" is grep's 1) has no known code.
fn command_exit(
    output: String,
    is_error: bool,
    structured: Option<&Value>,
) -> (Option<i32>, String) {
    if is_error {
        let parsed = output.strip_prefix("Exit code ").and_then(|rest| {
            let (code, rest) = rest.split_once('\n').unwrap_or((rest, ""));
            Some((code.trim().parse::<i32>().ok()?, rest.to_string()))
        });
        return match parsed {
            Some((code, rest)) => (Some(code), rest),
            None => (None, output),
        };
    }
    let clean_success = structured.is_some_and(|result| {
        result.get("stdout").is_some()
            && result["interrupted"] != true
            && [
                "backgroundTaskId",
                "backgroundedByUser",
                "timedOutAfterMs",
                "returnCodeInterpretation",
            ]
            .iter()
            .all(|key| {
                result
                    .get(*key)
                    .is_none_or(|value| value.is_null() || value == false)
            })
    });
    (clean_success.then_some(0), output)
}

fn added_lines(content: &str) -> String {
    content.lines().fold(String::new(), |mut diff, line| {
        diff.push('+');
        diff.push_str(line);
        diff.push('\n');
        diff
    })
}

fn render_patch(hunks: &[Value]) -> String {
    let mut out = String::new();
    for hunk in hunks {
        out.push_str(&format!(
            "@@ -{},{} +{},{} @@\n",
            hunk["oldStart"], hunk["oldLines"], hunk["newStart"], hunk["newLines"]
        ));
        for line in hunk["lines"].as_array().into_iter().flatten() {
            if let Some(line) = line.as_str() {
                out.push_str(line);
                out.push('\n');
            }
        }
    }
    out
}

/// A server-side tool result block's short text and whether it failed:
/// the hits of a web search, the page a fetch read, an advisor's note,
/// code execution output, an MCP connector's text.
fn server_tool_result(block: &Value) -> (String, bool) {
    let content = &block["content"];
    let kind = content["type"].as_str().unwrap_or("");
    let is_error = block["is_error"] == true || kind.ends_with("_error");
    let text = if kind.ends_with("_error") {
        content["error_code"]
            .as_str()
            .map(|code| code.replace('_', " "))
            .unwrap_or_default()
    } else {
        match content {
            Value::Array(items) => items
                .iter()
                .filter_map(|item| match item["type"].as_str() {
                    Some("web_search_result") => {
                        let url = item["url"].as_str().unwrap_or_default();
                        Some(match trimmed(&item["title"]) {
                            Some(title) => format!("{title} ({url})"),
                            None => url.to_string(),
                        })
                    }
                    _ => item["text"].as_str().map(str::to_string),
                })
                .collect::<Vec<_>>()
                .join("\n"),
            Value::Object(_) => match kind {
                "advisor_result" => content["text"].as_str().unwrap_or_default().to_string(),
                "web_fetch_result" => content["url"].as_str().unwrap_or_default().to_string(),
                "tool_search_tool_search_result" => content["tool_references"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|reference| reference["tool_name"].as_str())
                    .collect::<Vec<_>>()
                    .join(", "),
                // Code execution: its streams.
                _ => [&content["stdout"], &content["stderr"]]
                    .into_iter()
                    .filter_map(|stream| trimmed(stream))
                    .collect::<Vec<_>>()
                    .join("\n"),
            },
            Value::String(text) => text.clone(),
            _ => String::new(),
        }
    };
    (clip(&text, MAX_SERVER_RESULT_CHARS), is_error)
}

fn result_text(content: &Value) -> String {
    match content {
        Value::String(text) => text.clone(),
        Value::Array(items) => items
            .iter()
            .filter_map(|item| item["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n"),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

/// One API call's tokens, from an assistant message's or a result's usage.
fn call_usage(usage: &Value) -> Option<TokenUsage> {
    usage.as_object()?;
    let number = |key: &str| usage[key].as_u64().unwrap_or(0);
    let input = number("input_tokens");
    let cached = number("cache_read_input_tokens");
    let created = number("cache_creation_input_tokens");
    let output = number("output_tokens");
    Some(TokenUsage {
        input: input + created,
        cached_input: cached,
        output,
        reasoning: 0,
        total: input + created + cached + output,
    })
}

/// The turn's summed tokens and the model's context window. The sum covers
/// every call of the turn, so it is the turn's total, not the context fill.
fn result_usage(result: &ResultMessage) -> Option<UsageUpdate> {
    let total = call_usage(result.usage.as_ref()?)?;
    let context_window = result
        .model_usage
        .as_ref()
        .and_then(Value::as_object)
        .and_then(|models| {
            models
                .values()
                .filter_map(|model| model["contextWindow"].as_u64())
                .max()
        });
    Some(UsageUpdate {
        last: None,
        total: Some(total),
        context_window,
        limits: Vec::new(),
    })
}

fn rate_limit(info: &Value) -> Vec<Event> {
    let resets_at = info["resetsAt"].as_i64();
    // Every event carries the 5-hour and weekly windows together; the top
    // level only names the limit closest to its cap, and its utilization is
    // absent unless that limit is near it.
    let mut limits: Vec<DriverUsageWindow> = info["unifiedWindows"]
        .as_object()
        .into_iter()
        .flatten()
        .filter_map(|(label, window)| {
            Some(usage_window(
                label,
                window["utilization"].as_f64()? * 100.0,
                window["resetsAt"].as_i64(),
            ))
        })
        .collect();
    let label = info["rateLimitType"].as_str().unwrap_or("rate_limit");
    if let Some(utilization) = info["utilization"].as_f64()
        && !limits.iter().any(|window| window.label == label)
    {
        limits.push(usage_window(label, utilization * 100.0, resets_at));
    }
    let mut events = Vec::new();
    if !limits.is_empty() {
        events.push(Event::Usage {
            usage: UsageUpdate {
                limits,
                ..UsageUpdate::default()
            },
        });
    }
    // A rejected window blocks only when no extra usage covers it: on
    // overage Claude keeps working.
    let overage = matches!(
        info["overageStatus"].as_str(),
        Some("allowed" | "allowed_warning")
    ) || info["isUsingOverage"] == true
        || info["overageInUse"] == true;
    if info["status"] == "rejected" && !overage {
        events.push(Event::State {
            state: RunState::Waiting {
                on: WaitingOn::Limit { resets_at },
            },
        });
    }
    events
}

fn usage_window(label: &str, percent: f64, resets_at: Option<i64>) -> DriverUsageWindow {
    DriverUsageWindow {
        label: label.to_string(),
        used_percent: percent.round().clamp(0.0, 100.0) as u8,
        window_minutes: match label {
            "five_hour" => Some(300),
            label if label.starts_with("seven_day") => Some(10_080),
            _ => None,
        },
        resets_at,
    }
}

/// The plan limits in a `get_usage` answer, which unlike `rate_limit_event`
/// reads percents as 0-100 and resets as ISO 8601.
///
/// Weekly limits of one model family (Fable today) arrive in `model_scoped`
/// under their display name rather than as a named `seven_day_*` key; each
/// becomes `seven_day_<name>`, so a new model's limit shows without a change
/// here.
pub(crate) fn plan_usage(response: &Value) -> Vec<DriverUsageWindow> {
    let limits = &response["rate_limits"];
    let mut windows: Vec<DriverUsageWindow> = [
        "five_hour",
        "seven_day",
        "seven_day_opus",
        "seven_day_sonnet",
    ]
    .into_iter()
    .filter_map(|label| plan_window(label, &limits[label]))
    .collect();
    for scoped in limits["model_scoped"].as_array().into_iter().flatten() {
        let Some(name) = scoped["display_name"].as_str() else {
            continue;
        };
        let slug: String = name
            .trim()
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() {
                    c.to_ascii_lowercase()
                } else {
                    '_'
                }
            })
            .collect();
        if slug.is_empty() {
            continue;
        }
        let label = format!("seven_day_{slug}");
        if windows.iter().any(|window| window.label == label) {
            continue;
        }
        windows.extend(plan_window(&label, scoped));
    }
    windows
}

fn plan_window(label: &str, window: &Value) -> Option<DriverUsageWindow> {
    Some(usage_window(
        label,
        window["utilization"].as_f64()?,
        window["resets_at"]
            .as_str()
            .and_then(|time| chrono::DateTime::parse_from_rfc3339(time).ok())
            .map(|time| time.timestamp()),
    ))
}

fn turn_outcome(result: &ResultMessage) -> TurnOutcome {
    let reason = result.terminal_reason.as_deref().unwrap_or("");
    if reason.starts_with("aborted") || reason == "interrupted" {
        return TurnOutcome::Interrupted;
    }
    match result.subtype.as_str() {
        "error_max_turns" => TurnOutcome::TurnLimit,
        _ if result.stop_reason.as_deref() == Some("max_tokens") && !result.is_error => {
            TurnOutcome::TokenLimit
        }
        _ if result.is_error && needs_sign_in(result) => TurnOutcome::AuthenticationRequired,
        _ if result.is_error => TurnOutcome::Failed,
        _ => TurnOutcome::Completed,
    }
}

/// Claude's own wording for an expired or missing sign-in.
fn needs_sign_in(result: &ResultMessage) -> bool {
    let text = result.error_text().to_ascii_lowercase();
    result.api_error_status.as_ref().and_then(Value::as_u64) == Some(401)
        || text.contains("/login")
        || text.contains("authentication_error")
        || text.contains("invalid api key")
        || text.contains("oauth token has expired")
        || text.contains("oauth session expired")
        || text.contains("failed to authenticate")
        || text.contains("not logged in")
}

fn child_kind(task: &TaskEvent, raw: &Value) -> ChildKind {
    let task_type = task.task_type.as_deref().unwrap_or("");
    if task_type.contains("bash") || task_type.contains("shell") || task_type.contains("monitor") {
        ChildKind::BackgroundTask
    } else if task_type.contains("agent")
        || task_type.contains("workflow")
        || raw.get("subagent_type").is_some()
        || task_type.is_empty()
    {
        ChildKind::Subagent
    } else {
        ChildKind::Unknown
    }
}

fn child_status(status: Option<&str>) -> ChildStatus {
    match status {
        Some("running" | "pending") => ChildStatus::Running,
        Some("completed") => ChildStatus::Completed,
        Some("failed") => ChildStatus::Failed,
        Some("stopped" | "killed") => ChildStatus::Stopped,
        Some("waiting" | "paused") => ChildStatus::Waiting,
        _ => ChildStatus::Unknown,
    }
}

/// A question's field ID: its position, since its text may hold newlines or
/// be longer than an ID may be (such a question used to be dropped, which
/// could leave nothing to answer). Answers map back to the text Claude keys
/// them by in `answers_map`.
fn question_field(index: usize) -> Option<FieldId> {
    FieldId::new(format!("q{index}")).ok()
}

fn question_form(permission: &PermissionRequest) -> QuestionForm {
    QuestionForm {
        title: permission.title.clone(),
        fields: permission
            .questions()
            .into_iter()
            .enumerate()
            .filter_map(|(index, question)| {
                Some(FormField {
                    id: question_field(index)?,
                    header: question.header.clone(),
                    prompt: question.question.clone(),
                    input: FieldInput::Select {
                        options: question
                            .options
                            .iter()
                            .map(|option| FieldOption {
                                label: option.label.clone(),
                                description: option.description.clone(),
                                preview: option.preview.clone(),
                            })
                            .collect(),
                        multiple: question.multi_select,
                        // Claude's own question UI always offers "Other".
                        allow_other: true,
                    },
                    required: true,
                })
            })
            .collect(),
        asynchronous: false,
        auto_resolution_ms: None,
    }
}

/// Claude keys answers by question text.
fn answers_map(permission: &PermissionRequest, answers: &[FieldAnswer]) -> Map<String, Value> {
    let questions = permission.questions();
    answers
        .iter()
        .map(|answer| {
            let key = answer
                .field
                .as_str()
                .strip_prefix('q')
                .and_then(|index| index.parse::<usize>().ok())
                .and_then(|index| questions.get(index))
                .map_or_else(
                    || answer.field.as_str().to_string(),
                    |question| question.question.clone(),
                );
            (key, json!(answer.values.join(", ")))
        })
        .collect()
}

fn approval_subject(
    permission: &PermissionRequest,
    cwd: Option<&std::path::Path>,
) -> ApprovalSubject {
    let reason = permission
        .decision_reason
        .clone()
        .or_else(|| permission.description.clone());
    let input = &permission.input;
    match permission.tool_name.as_str() {
        // Claude's plan approval: the plan itself, not a tool call.
        "ExitPlanMode" if input["plan"].is_string() => ApprovalSubject::Plan {
            plan: input["plan"].as_str().unwrap_or_default().to_string(),
        },
        "Bash" => ApprovalSubject::Command {
            command: input["command"].as_str().unwrap_or("").to_string(),
            cwd: cwd.map(PathBuf::from),
            reason,
            network_host: None,
            permissions: None,
        },
        // Edits keep their full input so the card shows what is written.
        name => ApprovalSubject::Tool {
            name: permission
                .display_name
                .clone()
                .unwrap_or_else(|| name.to_string()),
            input: input.clone(),
            reason: permission.title.clone().or(reason),
        },
    }
}

/// Claude's own choices: allow once, each suggested permission update, and
/// deny with a message.
fn approval_decisions(
    permission: &PermissionRequest,
    cwd: Option<&std::path::Path>,
) -> Vec<Decision> {
    let mut decisions = vec![Decision {
        id: DecisionId::new(ALLOW).expect("decision id"),
        label: "Yes".into(),
        kind: DecisionKind::Accept,
        description: None,
        accepts_message: false,
        native: json!({"behavior": "allow"}),
    }];
    if permission.suppress_always_allow_rule != Some(true) {
        for (index, suggestion) in permission.permission_suggestions.iter().enumerate() {
            // A deny rule only travels with an allow answer, which would run
            // the tool the person just refused; "No" covers this one call.
            if suggestion["behavior"] == "deny" {
                continue;
            }
            let Ok(id) = DecisionId::new(format!("{SUGGESTION_PREFIX}{index}")) else {
                continue;
            };
            decisions.push(Decision {
                id,
                label: suggestion_label(suggestion, cwd),
                kind: DecisionKind::AcceptAndRemember,
                description: None,
                accepts_message: false,
                native: json!({"behavior": "allow", "updatedPermissions": [suggestion]}),
            });
        }
    }
    decisions.push(Decision {
        id: DecisionId::new(DENY).expect("decision id"),
        label: "No, and tell Claude what to do differently".into(),
        kind: DecisionKind::Decline,
        description: None,
        accepts_message: true,
        native: json!({"behavior": "deny"}),
    });
    decisions
}

fn suggestion_label(suggestion: &Value, cwd: Option<&std::path::Path>) -> String {
    let place = cwd
        .map(|cwd| format!(" in {}", cwd.display()))
        .unwrap_or_default();
    match suggestion["type"].as_str() {
        Some("addRules") => {
            let rules: Vec<String> = suggestion["rules"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|rule| {
                    let tool = rule["toolName"].as_str().unwrap_or("this tool");
                    match (tool, rule["ruleContent"].as_str()) {
                        ("Bash", Some(content)) => format!("{content} commands"),
                        (tool, Some(content)) => format!("{tool}({content})"),
                        (tool, None) => tool.to_string(),
                    }
                })
                .collect();
            if suggestion["behavior"] == "deny" {
                format!("No, and always deny {}{place}", rules.join(", "))
            } else {
                format!("Yes, and don't ask again for {}{place}", rules.join(", "))
            }
        }
        Some("addDirectories") => {
            let directories: Vec<&str> = suggestion["directories"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .collect();
            format!("Yes, and always allow access to {}", directories.join(", "))
        }
        Some("setMode") => match suggestion["mode"].as_str() {
            Some("acceptEdits") => "Yes, and auto-accept edits".into(),
            Some("bypassPermissions") => "Yes, and bypass permissions".into(),
            Some(mode) => format!("Yes, and switch to {mode} mode"),
            None => "Yes, and change the permission mode".into(),
        },
        _ => "Yes, and remember this choice".into(),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn message(value: Value) -> CliMessage {
        CliMessage::from_value(value)
    }

    #[test]
    fn rate_limit_events_report_both_windows_at_their_real_usage() {
        let events = rate_limit(&json!({
            "status": "allowed",
            "rateLimitType": "five_hour",
            "resetsAt": 1793369400,
            "unifiedWindows": {
                "five_hour": {"utilization": 0.13, "resetsAt": 1793369400},
                "seven_day": {"utilization": 0.54, "resetsAt": 1793685600}
            }
        }));
        let [Event::Usage { usage }] = events.as_slice() else {
            panic!("{events:?}");
        };
        let readings: Vec<_> = usage
            .limits
            .iter()
            .map(|window| {
                (
                    window.label.as_str(),
                    window.used_percent,
                    window.window_minutes,
                    window.resets_at,
                )
            })
            .collect();
        assert_eq!(
            readings,
            [
                ("five_hour", 13, Some(300), Some(1793369400)),
                ("seven_day", 54, Some(10_080), Some(1793685600)),
            ]
        );
    }

    #[test]
    fn rate_limit_events_without_a_reading_invent_no_usage() {
        assert!(rate_limit(&json!({"status": "allowed", "rateLimitType": "five_hour"})).is_empty());
    }

    #[test]
    fn plan_usage_reads_the_get_usage_answer() {
        let windows = plan_usage(&json!({"rate_limits": {
            "five_hour": {"utilization": 14, "resets_at": "2026-10-30T14:10:00.012432+00:00"},
            "seven_day": {"utilization": 54, "resets_at": "2026-11-03T06:00:00+00:00"},
            "seven_day_opus": null,
            "extra_usage": {"utilization": null}
        }}));
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].used_percent, 14);
        assert_eq!(windows[0].window_minutes, Some(300));
        assert_eq!(windows[1].label, "seven_day");
        assert_eq!(windows[1].resets_at, Some(1793685600));
        assert!(plan_usage(&json!({"rate_limits": null})).is_empty());
    }

    #[test]
    fn plan_usage_reads_model_scoped_weekly_limits() {
        let windows = plan_usage(&json!({"rate_limits": {
            "five_hour": {"utilization": 3, "resets_at": "2026-11-10T14:20:00+00:00"},
            "seven_day": {"utilization": 20, "resets_at": "2026-11-17T06:00:00+00:00"},
            "seven_day_opus": {"utilization": 40, "resets_at": "2026-11-17T06:00:00+00:00"},
            "model_scoped": [
                {"display_name": "Fable", "utilization": 37, "resets_at": "2026-11-17T06:00:00+00:00"},
                {"display_name": "Opus", "utilization": 99, "resets_at": "2026-11-17T06:00:00+00:00"},
                {"display_name": "No reading"}
            ]
        }}));
        let labels: Vec<&str> = windows.iter().map(|window| window.label.as_str()).collect();
        assert_eq!(
            labels,
            [
                "five_hour",
                "seven_day",
                "seven_day_opus",
                "seven_day_fable"
            ]
        );
        assert_eq!(windows[2].used_percent, 40);
        assert_eq!(windows[3].used_percent, 37);
        assert_eq!(windows[3].window_minutes, Some(10_080));
        assert_eq!(windows[3].resets_at, Some(1794895200));
    }

    #[test]
    fn turns_open_without_lifecycle_frames_from_the_oldest_sent_input() {
        let mut mapper = ClaudeMapper::new(None);
        let input = InputId::new("0d6a7c1e-1111-4a00-8000-000000000001").unwrap();
        mapper.sent(&input, true);
        let events = mapper.message(&message(json!({"type": "assistant", "uuid": "a1",
            "message": {"id": "m1", "content": [{"type": "text", "text": "hi"}]}})));
        assert!(matches!(&events[0], Event::Turn { turn, .. } if turn.as_str() == input.as_str()));
        let events = mapper.message(&message(json!({"type": "result", "subtype": "success",
            "is_error": false, "duration_ms": 5})));
        let Event::Turn {
            phase:
                TurnPhase::Completed {
                    inputs_consumed,
                    outcome,
                    ..
                },
            ..
        } = events.last().unwrap()
        else {
            panic!("turn completed");
        };
        assert_eq!(inputs_consumed, &[input]);
        assert_eq!(*outcome, TurnOutcome::Completed);
    }

    #[test]
    fn prompt_suggestions_follow_the_ended_turn() {
        let mut mapper = ClaudeMapper::new(None);
        let input = InputId::new("0d6a7c1e-1111-4a00-8000-000000000002").unwrap();
        mapper.sent(&input, true);
        mapper.message(&message(json!({"type": "assistant", "uuid": "a1",
            "message": {"id": "m1", "content": [{"type": "text", "text": "fixed"}]}})));
        mapper.message(&message(json!({"type": "result", "subtype": "success",
            "is_error": false, "duration_ms": 5})));
        let events = mapper.message(&message(json!({"type": "prompt_suggestion",
            "suggestion": " run the tests ", "uuid": "s1", "session_id": "x"})));
        let [Event::PromptSuggestion { turn, text }] = events.as_slice() else {
            panic!("{events:?}");
        };
        assert_eq!(turn.as_ref().map(TurnId::as_str), Some(input.as_str()));
        assert_eq!(text, "run the tests");
        assert!(
            mapper
                .message(&message(
                    json!({"type": "prompt_suggestion", "suggestion": "  "})
                ))
                .is_empty()
        );
    }

    #[test]
    fn prompt_suggestions_during_a_newer_turn_are_stale() {
        let mut mapper = ClaudeMapper::new(None);
        let input = InputId::new("0d6a7c1e-1111-4a00-8000-000000000003").unwrap();
        mapper.sent(&input, true);
        mapper.message(&message(json!({"type": "assistant", "uuid": "a1",
            "message": {"id": "m1", "content": [{"type": "text", "text": "working"}]}})));
        let events = mapper.message(&message(
            json!({"type": "prompt_suggestion", "suggestion": "yes"}),
        ));
        assert!(events.is_empty(), "{events:?}");
    }

    #[test]
    fn passive_input_alone_opens_no_turn() {
        let mut mapper = ClaudeMapper::new(None);
        let events = mapper.message(&message(json!({"type": "result", "subtype": "success",
            "is_error": false, "num_turns": 0, "user_message_uuids": ["0d6a7c1e-1111-4a00-8000-000000000009"]})));
        assert!(
            events
                .iter()
                .all(|event| !matches!(event, Event::Turn { .. }))
        );
    }

    #[test]
    fn one_block_per_frame_keeps_distinct_item_ids() {
        let mut mapper = ClaudeMapper::new(None);
        let first = mapper.message(&message(json!({"type": "assistant", "uuid": "a1",
            "message": {"id": "m1", "content": [{"type": "thinking", "thinking": "hmm"}]}})));
        let second = mapper.message(&message(json!({"type": "assistant", "uuid": "a2",
            "message": {"id": "m1", "content": [{"type": "text", "text": "done"}]}})));
        let id = |events: &[Event]| match events.last() {
            Some(Event::Item(item)) => item.id.as_str().to_string(),
            other => panic!("{other:?}"),
        };
        assert_eq!(id(&first), "m1:0");
        assert_eq!(id(&second), "m1:1");
    }

    #[test]
    fn an_expired_sign_in_is_a_setup_state() {
        for text in [
            "Invalid API key · Please run /login",
            "Failed to authenticate: OAuth session expired and could not be refreshed",
        ] {
            let mut mapper = ClaudeMapper::new(None);
            let events = mapper.message(&message(json!({"type": "result", "subtype": "success",
                "is_error": true, "result": text, "user_message_uuids": ["0d6a7c1e-1111-4a00-8000-000000000001"]})));
            assert_sign_in_required(&events);
        }
    }

    fn assert_sign_in_required(events: &[Event]) {
        assert!(events.iter().any(|event| matches!(
            event,
            Event::State {
                state: RunState::Waiting {
                    on: WaitingOn::Setup { .. }
                }
            }
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            Event::Turn {
                phase: TurnPhase::Completed {
                    outcome: TurnOutcome::AuthenticationRequired,
                    ..
                },
                ..
            }
        )));
    }

    #[test]
    fn an_aborted_turns_own_input_is_consumed_not_cancelled() {
        let mut mapper = ClaudeMapper::new(None);
        let t1 = "0d6a7c1e-1111-4a00-8000-000000000001";
        mapper.sent(&InputId::new(t1).unwrap(), true);
        mapper.message(&message(
            json!({"type": "command_lifecycle", "command_uuid": t1, "state": "started"}),
        ));
        let events = mapper.message(&message(
            json!({"type": "command_lifecycle", "command_uuid": t1, "state": "cancelled"}),
        ));
        assert!(events.is_empty(), "{events:?}");
        let events = mapper.message(&message(
            json!({"type": "result", "subtype": "success", "is_error": false,
            "terminal_reason": "aborted_tools", "user_message_uuids": [t1]}),
        ));
        assert!(matches!(
            events.last(),
            Some(Event::Turn {
                phase: TurnPhase::Completed {
                    outcome: TurnOutcome::Interrupted,
                    ..
                },
                ..
            })
        ));
    }

    #[test]
    fn a_note_never_opens_ends_or_joins_a_turn() {
        let mut mapper = ClaudeMapper::new(None);
        let note = "0d6a7c1e-1111-4a00-8000-0000000000a1";
        let t1 = "0d6a7c1e-1111-4a00-8000-0000000000a2";
        mapper.sent_note(note);
        let idle = mapper.message(&message(
            json!({"type": "command_lifecycle", "command_uuid": note, "state": "started"}),
        ));
        assert!(idle.is_empty(), "{idle:?}");
        mapper.sent_note(note);
        mapper.sent(&InputId::new(t1).unwrap(), true);
        let mut events = mapper.message(&message(
            json!({"type": "command_lifecycle", "command_uuid": t1, "state": "started"}),
        ));
        events.extend(mapper.message(&message(
            json!({"type": "result", "subtype": "success", "is_error": false,
            "num_turns": 1, "user_message_uuids": [note, t1]}),
        )));
        let started = events.iter().find_map(|event| match event {
            Event::Turn {
                turn,
                phase: TurnPhase::Started { .. },
            } => Some(turn.as_str().to_string()),
            _ => None,
        });
        assert_eq!(started.as_deref(), Some(t1));
        let consumed = events.iter().find_map(|event| match event {
            Event::Turn {
                phase:
                    TurnPhase::Completed {
                        inputs_consumed, ..
                    },
                ..
            } => Some(inputs_consumed.clone()),
            _ => None,
        });
        assert_eq!(consumed, Some(vec![InputId::new(t1).unwrap()]));

        mapper.sent_note(note);
        let alone = mapper.message(&message(
            json!({"type": "result", "subtype": "success", "is_error": false,
            "num_turns": 0, "user_message_uuids": [note]}),
        ));
        assert!(
            alone
                .iter()
                .all(|event| !matches!(event, Event::Turn { .. })),
            "{alone:?}"
        );
    }

    #[test]
    fn passive_input_lifecycle_opens_no_turn() {
        let mut mapper = ClaudeMapper::new(None);
        let p1 = "0d6a7c1e-1111-4a00-8000-000000000007";
        mapper.sent_passive(&InputId::new(p1).unwrap());
        let mut events = mapper.message(&message(
            json!({"type": "command_lifecycle", "command_uuid": p1, "state": "started"}),
        ));
        events.extend(mapper.message(&message(
            json!({"type": "result", "subtype": "success", "is_error": false,
            "num_turns": 0, "user_message_uuids": [p1]}),
        )));
        assert!(
            events
                .iter()
                .all(|event| !matches!(event, Event::Turn { .. })),
            "{events:?}"
        );
    }

    #[test]
    fn denied_tools_complete_as_declined() {
        let mut mapper = ClaudeMapper::new(Some("/w".into()));
        mapper.message(&message(json!({"type": "assistant", "uuid": "a1",
            "message": {"id": "m1", "content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "rm -rf /"}}]}})));
        let RequestMapped::Interaction(_) = mapper.request(
            "r1",
            &json!({"subtype": "can_use_tool",
            "tool_name": "Bash", "input": {"command": "rm -rf /"}, "tool_use_id": "t1"}),
        ) else {
            panic!("interaction");
        };
        let plan = mapper
            .answer(
                &InteractionId::new("r1").unwrap(),
                &InteractionResponse::Decision {
                    decision: DecisionId::new(DENY).unwrap(),
                    message: Some("no".into()),
                },
                UserId(1),
            )
            .unwrap();
        assert_eq!(plan.response, json!({"behavior": "deny", "message": "no"}));
        let events = mapper.message(&message(json!({"type": "user", "uuid": "u1",
            "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "no", "is_error": true}]}})));
        let Event::Item(item) = &events[0] else {
            panic!()
        };
        assert!(matches!(
            item.update,
            ItemUpdate::Completed {
                status: ItemStatus::Declined,
                ..
            }
        ));
        assert!(
            mapper
                .answer(
                    &InteractionId::new("r1").unwrap(),
                    &InteractionResponse::Cancel,
                    UserId(1)
                )
                .is_err()
        );
    }

    #[test]
    fn a_long_or_multiline_question_keeps_its_field_and_its_answer_key() {
        let mut mapper = ClaudeMapper::new(None);
        let long = format!("Which plan?\n{}", "detail ".repeat(400));
        let RequestMapped::Interaction(events) = mapper.request(
            "q1",
            &json!({"subtype": "can_use_tool", "tool_name": "AskUserQuestion", "tool_use_id": "t1",
                "input": {"questions": [
                    {"question": long, "header": "Plan", "multiSelect": false,
                        "options": [{"label": "A", "description": ""}, {"label": "B", "description": ""}]},
                    {"question": "Ship it?", "header": "Ship", "multiSelect": false,
                        "options": [{"label": "Yes", "description": ""}, {"label": "No", "description": ""}]}
                ]}}),
        ) else {
            panic!("interaction");
        };
        let Some(Event::Interaction(interaction)) = events.last() else {
            panic!("interaction event");
        };
        let InteractionKind::Question { form } = &interaction.kind else {
            panic!("question");
        };
        // Both questions are asked, the long one included.
        assert_eq!(form.fields.len(), 2);
        let plan = mapper
            .answer(
                &InteractionId::new("q1").unwrap(),
                &InteractionResponse::Answers {
                    answers: form
                        .fields
                        .iter()
                        .zip(["B", "Yes"])
                        .map(|(field, value)| FieldAnswer {
                            field: field.id.clone(),
                            values: vec![value.into()],
                        })
                        .collect(),
                },
                UserId(1),
            )
            .unwrap();
        // Claude reads answers keyed by the full question text.
        assert_eq!(
            plan.response["updatedInput"]["answers"][long.as_str()],
            json!("B")
        );
        assert_eq!(
            plan.response["updatedInput"]["answers"]["Ship it?"],
            json!("Yes")
        );
    }

    #[test]
    fn a_deny_rule_suggestion_is_not_offered_as_an_answer_that_allows() {
        let mut mapper = ClaudeMapper::new(None);
        let RequestMapped::Interaction(events) = mapper.request(
            "r1",
            &json!({"subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": "t1",
            "input": {"command": "rm -rf build"},
            "permission_suggestions": [
                {"type": "addRules", "behavior": "deny", "destination": "localSettings",
                    "rules": [{"toolName": "Bash", "ruleContent": "rm -rf:*"}]},
                {"type": "addRules", "behavior": "allow", "destination": "localSettings",
                    "rules": [{"toolName": "Bash", "ruleContent": "make:*"}]}
            ]}),
        ) else {
            panic!("interaction");
        };
        let Some(Event::Interaction(interaction)) = events.last() else {
            panic!("interaction event");
        };
        let InteractionKind::Approval { decisions, .. } = &interaction.kind else {
            panic!("approval");
        };
        let labels: Vec<&str> = decisions
            .iter()
            .map(|decision| decision.label.as_str())
            .collect();
        assert!(
            labels.iter().all(|label| !label.contains("always deny")),
            "{labels:?}"
        );
        assert!(
            labels.iter().any(|label| label.contains("make:*")),
            "{labels:?}"
        );
    }

    #[test]
    fn an_mcp_form_nobody_saw_is_cancelled_and_shown_in_the_chat() {
        let mut mapper = ClaudeMapper::new(None);
        let RequestMapped::Reply { response, events } = mapper.request(
            "e1",
            &json!({"subtype": "elicitation", "mcp_server_name": "coolify",
                "message": "Confirm the deploy?", "mode": "form", "requested_schema": {}}),
        ) else {
            panic!("reply");
        };
        // Dismissed, not a person's explicit "no".
        assert_eq!(response.unwrap(), json!({"action": "cancel"}));
        let Some(Event::Notice(notice)) = events.first() else {
            panic!("notice");
        };
        // Only errors reach the chat; this one must.
        assert_eq!(notice.level, NoticeLevel::Error);
        assert_eq!(notice.code, "Request cancelled");
        let text = notice.message.as_deref().unwrap_or_default();
        assert!(
            text.contains("coolify")
                && text.contains("Confirm the deploy?")
                && text.contains("Inline can't show yet, so it was cancelled"),
            "{text}"
        );
    }

    fn completed(events: &[Event], id: &str) -> (ItemBody, ItemStatus, Option<ChildRef>) {
        events
            .iter()
            .find_map(|event| match event {
                Event::Item(item) if item.id.as_str() == id => match &item.update {
                    ItemUpdate::Completed { body, status } => {
                        Some((body.clone(), *status, item.parent.clone()))
                    }
                    _ => None,
                },
                _ => None,
            })
            .unwrap_or_else(|| panic!("{id} completed in {events:?}"))
    }

    fn started(events: &[Event], id: &str) -> (ItemBody, Option<ChildRef>) {
        events
            .iter()
            .find_map(|event| match event {
                Event::Item(item) if item.id.as_str() == id => match &item.update {
                    ItemUpdate::Started { body } => Some((body.clone(), item.parent.clone())),
                    _ => None,
                },
                _ => None,
            })
            .unwrap_or_else(|| panic!("{id} started in {events:?}"))
    }

    fn tool_use(id: &str, name: &str, input: Value) -> CliMessage {
        message(json!({"type": "assistant", "uuid": format!("a-{id}"),
            "message": {"id": format!("msg-{id}"), "role": "assistant",
                "content": [{"type": "tool_use", "id": id, "name": name, "input": input}]}}))
    }

    fn tool_result(id: &str, content: &str, is_error: bool, structured: Value) -> CliMessage {
        message(json!({"type": "user", "uuid": format!("u-{id}"),
            "tool_use_result": structured,
            "message": {"role": "user", "content": [{"type": "tool_result",
                "tool_use_id": id, "content": content, "is_error": is_error}]}}))
    }

    #[test]
    fn a_failed_bash_carries_its_exit_code_and_a_clean_success_exits_zero() {
        let mut mapper = running_turn("0d6a7c1e-1111-4a00-8000-000000000001");
        mapper.message(&tool_use("b1", "Bash", json!({"command": "cargo test"})));
        let events = mapper.message(&tool_result(
            "b1",
            "Exit code 101\nerror[E0308]: mismatched types",
            true,
            json!("Error: Exit code 101\nerror[E0308]: mismatched types"),
        ));
        let (
            ItemBody::Command {
                exit_code, output, ..
            },
            status,
            _,
        ) = completed(&events, "b1")
        else {
            panic!("command");
        };
        assert_eq!(status, ItemStatus::Failed);
        assert_eq!(exit_code, Some(101));
        assert_eq!(output.as_deref(), Some("error[E0308]: mismatched types"));

        // "Exit code 1" with no output at all.
        mapper.message(&tool_use("b2", "Bash", json!({"command": "false"})));
        let events = mapper.message(&tool_result("b2", "Exit code 1", true, Value::Null));
        let (
            ItemBody::Command {
                exit_code, output, ..
            },
            ..,
        ) = completed(&events, "b2")
        else {
            panic!("command");
        };
        assert_eq!((exit_code, output.as_deref()), (Some(1), Some("")));

        let success = |extra: Value| {
            let mut structured = json!({"stdout": "ok", "stderr": "", "interrupted": false,
                "isImage": false, "noOutputExpected": false});
            structured
                .as_object_mut()
                .unwrap()
                .extend(extra.as_object().unwrap().clone());
            structured
        };
        mapper.message(&tool_use("b3", "Bash", json!({"command": "true"})));
        let events = mapper.message(&tool_result("b3", "ok", false, success(json!({}))));
        let (ItemBody::Command { exit_code, .. }, ..) = completed(&events, "b3") else {
            panic!("command");
        };
        assert_eq!(exit_code, Some(0));

        // A search that found nothing exited 1; a backgrounded run has no code yet.
        for (id, extra) in [
            (
                "b4",
                json!({"returnCodeInterpretation": "No matches found"}),
            ),
            ("b5", json!({"backgroundTaskId": "bg1"})),
            ("b6", json!({"interrupted": true})),
        ] {
            mapper.message(&tool_use(id, "Bash", json!({"command": "x"})));
            let events = mapper.message(&tool_result(id, "", false, success(extra)));
            let (ItemBody::Command { exit_code, .. }, ..) = completed(&events, id) else {
                panic!("command");
            };
            assert_eq!(exit_code, None, "{id}");
        }

        // An error without the prefix keeps its text and has no code.
        mapper.message(&tool_use("b7", "Bash", json!({"command": "x"})));
        let events = mapper.message(&tool_result("b7", "Denied by the hook.", true, Value::Null));
        let (
            ItemBody::Command {
                exit_code, output, ..
            },
            ..,
        ) = completed(&events, "b7")
        else {
            panic!("command");
        };
        assert_eq!(
            (exit_code, output.as_deref()),
            (None, Some("Denied by the hook."))
        );
    }

    #[test]
    fn write_shows_a_new_file_as_added_lines_and_a_rewrite_as_an_update() {
        let mut mapper = running_turn("0d6a7c1e-1111-4a00-8000-000000000001");
        mapper.message(&tool_use(
            "w1",
            "Write",
            json!({"file_path": "/w/new.md", "content": "# Title\n\nBody\n"}),
        ));
        let events = mapper.message(&tool_result(
            "w1",
            "File created successfully at: /w/new.md",
            false,
            json!({"type": "create", "filePath": "/w/new.md", "content": "# Title\n\nBody\n",
                "structuredPatch": [], "originalFile": null}),
        ));
        let (ItemBody::FileChange { changes }, ..) = completed(&events, "w1") else {
            panic!("file change");
        };
        assert_eq!(changes[0].change, FileChangeKind::Add);
        assert_eq!(changes[0].diff.as_deref(), Some("+# Title\n+\n+Body\n"));

        mapper.message(&tool_use(
            "w2",
            "Write",
            json!({"file_path": "/w/old.md", "content": "new\n"}),
        ));
        let events = mapper.message(&tool_result(
            "w2",
            "The file /w/old.md has been updated.",
            false,
            json!({"type": "update", "filePath": "/w/old.md", "content": "new\n",
                "originalFile": "old\n", "structuredPatch": [{"oldStart": 1, "oldLines": 1,
                    "newStart": 1, "newLines": 1, "lines": ["-old", "+new"]}]}),
        ));
        let (ItemBody::FileChange { changes }, ..) = completed(&events, "w2") else {
            panic!("file change");
        };
        assert_eq!(changes[0].change, FileChangeKind::Update { moved_to: None });
        assert_eq!(
            changes[0].diff.as_deref(),
            Some("@@ -1,1 +1,1 @@\n-old\n+new\n")
        );
    }

    #[test]
    fn a_rejected_window_covered_by_extra_usage_is_no_limit() {
        let waits = |info: Value| {
            rate_limit(&info).iter().any(|event| {
                matches!(
                    event,
                    Event::State {
                        state: RunState::Waiting {
                            on: WaitingOn::Limit { .. }
                        }
                    }
                )
            })
        };
        let rejected = |extra: Value| {
            let mut info = json!({"status": "rejected", "rateLimitType": "five_hour",
                "resetsAt": 1793369400});
            info.as_object_mut()
                .unwrap()
                .extend(extra.as_object().unwrap().clone());
            info
        };
        assert!(waits(rejected(json!({}))));
        assert!(waits(rejected(
            json!({"overageStatus": "rejected", "isUsingOverage": false})
        )));
        assert!(!waits(rejected(json!({"overageStatus": "allowed"}))));
        assert!(!waits(rejected(
            json!({"overageStatus": "allowed_warning"})
        )));
        assert!(!waits(rejected(json!({"isUsingOverage": true}))));
        assert!(!waits(rejected(json!({"overageInUse": true}))));
    }

    #[test]
    fn server_side_tool_results_complete_their_call() {
        let t1 = "0d6a7c1e-1111-4a00-8000-000000000001";
        let mut mapper = running_turn(t1);
        let block = |content: Value| {
            message(json!({"type": "assistant", "uuid": "a-s",
                "message": {"id": "msg-s", "role": "assistant", "content": [content]}}))
        };
        mapper.message(&block(
            json!({"type": "server_tool_use", "id": "srvtoolu_1",
            "name": "web_search", "input": {"query": "rust 2024 edition"}}),
        ));
        assert!(!mapper.steer_can_cut(), "a server tool runs");
        let events = mapper.message(&block(json!({"type": "web_search_tool_result",
            "tool_use_id": "srvtoolu_1", "content": [
                {"type": "web_search_result", "title": "Rust 2024", "url": "https://blog.rust-lang.org/2024",
                    "encrypted_content": "x"},
                {"type": "web_search_result", "url": "https://doc.rust-lang.org/edition-guide"}
            ]})));
        // No unknown row: the call itself completes.
        assert_eq!(events.len(), 1, "{events:?}");
        let (ItemBody::Tool { name, output, .. }, status, _) = completed(&events, "srvtoolu_1")
        else {
            panic!("tool");
        };
        assert_eq!(
            (name.as_str(), status),
            ("web_search", ItemStatus::Completed)
        );
        assert_eq!(
            output.as_deref(),
            Some(
                "Rust 2024 (https://blog.rust-lang.org/2024)\nhttps://doc.rust-lang.org/edition-guide"
            )
        );
        assert!(mapper.steer_can_cut());

        mapper.message(&block(
            json!({"type": "server_tool_use", "id": "srvtoolu_2",
            "name": "advisor", "input": {}}),
        ));
        let events = mapper.message(&block(json!({"type": "advisor_tool_result",
            "tool_use_id": "srvtoolu_2", "content": {"type": "advisor_result", "text": "Check the lock order."}})));
        let (ItemBody::Tool { output, .. }, ..) = completed(&events, "srvtoolu_2") else {
            panic!("tool");
        };
        assert_eq!(output.as_deref(), Some("Check the lock order."));

        mapper.message(&block(
            json!({"type": "server_tool_use", "id": "srvtoolu_3",
            "name": "web_fetch", "input": {"url": "https://example.com"}}),
        ));
        let events = mapper.message(&block(json!({"type": "web_fetch_tool_result",
            "tool_use_id": "srvtoolu_3", "content": {"type": "web_fetch_tool_result_error",
                "error_code": "url_not_accessible"}})));
        let (ItemBody::Tool { error, .. }, status, _) = completed(&events, "srvtoolu_3") else {
            panic!("tool");
        };
        assert_eq!(status, ItemStatus::Failed);
        assert_eq!(error.as_deref(), Some("url not accessible"));

        // One whose result never came is closed when the turn completes.
        mapper.message(&block(
            json!({"type": "server_tool_use", "id": "srvtoolu_4",
            "name": "web_search", "input": {"query": "q"}}),
        ));
        let events = mapper.message(&message(json!({"type": "result", "subtype": "success",
            "is_error": false, "user_message_uuids": [t1]})));
        let (_, status, _) = completed(&events, "srvtoolu_4");
        assert_eq!(status, ItemStatus::Completed);
        assert!(matches!(events.last(), Some(Event::Turn { .. })));
    }

    #[test]
    fn calls_open_when_the_process_exits_are_interrupted() {
        let mut mapper = running_turn("0d6a7c1e-1111-4a00-8000-000000000001");
        mapper.message(&tool_use("b1", "Bash", json!({"command": "sleep 100"})));
        let events = mapper.connection_lost();
        let (_, status, _) = completed(&events, "b1");
        assert_eq!(status, ItemStatus::Interrupted);
        assert!(matches!(
            events.last(),
            Some(Event::Turn {
                phase: TurnPhase::Completed {
                    outcome: TurnOutcome::ConnectionLost,
                    ..
                },
                ..
            })
        ));
    }

    #[test]
    fn failures_that_stop_claude_reach_the_chat_as_errors() {
        let mut mapper = ClaudeMapper::new(None);
        let level = |events: &[Event]| match events {
            [Event::Notice(notice)] => (notice.level, notice.code.clone(), notice.message.clone()),
            other => panic!("{other:?}"),
        };
        let (lvl, code, text) = level(&mapper.message(&message(json!({"type": "system",
            "subtype": "status", "status": null, "compact_result": "failed",
            "compact_error": "Not enough messages to compact."}))));
        assert_eq!(
            (lvl, code.as_str()),
            (NoticeLevel::Error, "Compaction failed")
        );
        assert_eq!(
            text.as_deref(),
            Some("Claude couldn't compact the context: Not enough messages to compact.")
        );

        let (lvl, code, text) = level(&mapper.message(&message(json!({"type": "system",
            "subtype": "model_refusal_no_fallback", "original_model": "claude-fable-5",
            "request_id": null, "content": "", "api_refusal_explanation": "This request was declined."}))));
        assert_eq!(
            (lvl, code.as_str()),
            (NoticeLevel::Error, "Claude declined to respond")
        );
        assert_eq!(text.as_deref(), Some("This request was declined."));

        let (lvl, code, text) = level(&mapper.message(&message(json!({"type": "system",
            "subtype": "informational", "level": "warning", "prevent_continuation": true,
            "content": "Stop hook: tests must pass before you finish."}))));
        assert_eq!(
            (lvl, code.as_str()),
            (NoticeLevel::Error, "Stopped by a hook")
        );
        assert_eq!(
            text.as_deref(),
            Some("Stop hook: tests must pass before you finish.")
        );

        let (lvl, code, _) = level(&mapper.message(&message(json!({"type": "system",
            "subtype": "informational", "level": "warning", "content": "Blocked: no secrets.",
            "prompt_submit_outcome": {"kind": "blocked_by_hook", "prompt_kept": true}}))));
        assert_eq!(
            (lvl, code.as_str()),
            (NoticeLevel::Error, "Message blocked by a hook")
        );

        // Plain banners and the retried refusal stay in the logs.
        for raw in [
            json!({"type": "system", "subtype": "informational", "level": "notice", "content": "Saved."}),
            json!({"type": "system", "subtype": "model_refusal_fallback", "content": "Retrying"}),
            json!({"type": "system", "subtype": "status", "status": "compacting"}),
        ] {
            let (lvl, ..) = level(&mapper.message(&message(raw)));
            assert_eq!(lvl, NoticeLevel::Info);
        }
    }

    #[test]
    fn compaction_reports_the_context_left_after_it() {
        let t1 = "0d6a7c1e-1111-4a00-8000-000000000001";
        let mut mapper = running_turn(t1);
        mapper.message(&message(json!({"type": "assistant", "uuid": "a1",
            "message": {"id": "m1", "content": [{"type": "text", "text": "long"}],
                "usage": {"input_tokens": 10, "cache_read_input_tokens": 179_000, "output_tokens": 990}}})));
        mapper.message(&message(
            json!({"type": "system", "subtype": "compact_boundary",
            "uuid": "c1", "compact_metadata": {"trigger": "manual", "pre_tokens": 180_000,
                "post_tokens": 22_000}}),
        ));
        let events = mapper.message(&message(json!({"type": "result", "subtype": "success",
            "is_error": false, "user_message_uuids": [t1],
            "usage": {"input_tokens": 0, "output_tokens": 0}})));
        let Some(Event::Usage { usage }) = events.first() else {
            panic!("{events:?}");
        };
        assert_eq!(usage.last.map(|last| last.total), Some(22_000));

        // Also when the command's result carries no usage of its own.
        let mut mapper = running_turn(t1);
        mapper.message(&message(
            json!({"type": "system", "subtype": "compact_boundary",
            "uuid": "c2", "compact_metadata": {"trigger": "manual", "pre_tokens": 90_000,
                "post_tokens": 9_000}}),
        ));
        let events = mapper.message(&message(json!({"type": "result", "subtype": "success",
            "is_error": false, "user_message_uuids": [t1]})));
        let Some(Event::Usage { usage }) = events.first() else {
            panic!("{events:?}");
        };
        assert_eq!(usage.last.map(|last| last.total), Some(9_000));
        assert!(usage.total.is_none());
    }

    fn pinned_steps(body: &ItemBody) -> Vec<(String, PlanStepStatus)> {
        match body {
            ItemBody::Plan { steps, .. } => steps
                .iter()
                .map(|step| (step.text.clone(), step.status))
                .collect(),
            other => panic!("plan, got {other:?}"),
        }
    }

    #[test]
    fn task_tools_keep_the_plan_like_todo_write() {
        let mut mapper = running_turn("0d6a7c1e-1111-4a00-8000-000000000001");
        // Two creations in one message: ids arrive only with the results.
        let started_1 = mapper.message(&tool_use(
            "c1",
            "TaskCreate",
            json!({"subject": "Read the parser", "description": "…", "activeForm": "Reading"}),
        ));
        let started_2 = mapper.message(&tool_use(
            "c2",
            "TaskCreate",
            json!({"subject": "Fix tokenize()", "description": "…"}),
        ));
        assert_eq!(
            pinned_steps(&started(&started_1, "c1").0),
            [("Read the parser".into(), PlanStepStatus::Pending)]
        );
        assert_eq!(
            pinned_steps(&started(&started_2, "c2").0),
            [
                ("Read the parser".into(), PlanStepStatus::Pending),
                ("Fix tokenize()".into(), PlanStepStatus::Pending)
            ]
        );
        let events = mapper.message(&tool_result(
            "c1",
            "Task #1 created successfully: Read the parser",
            false,
            json!({"task": {"id": "1", "subject": "Read the parser"}}),
        ));
        assert_eq!(pinned_steps(&completed(&events, "c1").0).len(), 2);
        // A subagent-style text-only result still names the task.
        mapper.message(&tool_result(
            "c2",
            "Task #2 created successfully: Fix tokenize()",
            false,
            Value::Null,
        ));

        let events = mapper.message(&tool_use(
            "u1",
            "TaskUpdate",
            json!({"taskId": "1", "status": "completed"}),
        ));
        assert_eq!(
            pinned_steps(&started(&events, "u1").0)[0],
            ("Read the parser".into(), PlanStepStatus::Completed)
        );
        mapper.message(&tool_result(
            "u1",
            "Updated task #1 status",
            false,
            json!({"success": true, "taskId": "1", "updatedFields": ["status"]}),
        ));
        mapper.message(&tool_use(
            "u2",
            "TaskUpdate",
            json!({"taskId": "2", "status": "in_progress", "subject": "Fix tokenize() on blank input"}),
        ));
        let events = mapper.message(&tool_result(
            "u2",
            "Updated task #2 subject, status",
            false,
            json!({"success": true, "taskId": "2", "updatedFields": ["subject", "status"]}),
        ));
        let (body, status, _) = completed(&events, "u2");
        assert_eq!(status, ItemStatus::Completed);
        assert_eq!(
            pinned_steps(&body),
            [
                ("Read the parser".into(), PlanStepStatus::Completed),
                (
                    "Fix tokenize() on blank input".into(),
                    PlanStepStatus::InProgress
                )
            ]
        );

        // A failed update changes nothing and shows as the call itself.
        mapper.message(&tool_use(
            "u3",
            "TaskUpdate",
            json!({"taskId": "2", "status": "completed"}),
        ));
        let events = mapper.message(&tool_result(
            "u3",
            "Task not found",
            false,
            json!({"success": false, "taskId": "2", "updatedFields": [], "error": "Task not found"}),
        ));
        assert!(matches!(completed(&events, "u3").0, ItemBody::Tool { .. }));
        mapper.message(&tool_use("u4", "TaskUpdate", json!({"taskId": "9"})));
        let events = mapper.message(&tool_result("u4", "<tool_use_error>…", true, Value::Null));
        assert!(matches!(completed(&events, "u4").0, ItemBody::Tool { .. }));

        // Deleting drops the step; TaskList replaces the whole list.
        mapper.message(&tool_use(
            "u5",
            "TaskUpdate",
            json!({"taskId": "1", "status": "deleted"}),
        ));
        let events = mapper.message(&tool_result(
            "u5",
            "Updated task #1 deleted",
            false,
            json!({"success": true, "taskId": "1", "updatedFields": ["deleted"]}),
        ));
        assert_eq!(
            pinned_steps(&completed(&events, "u5").0),
            [(
                "Fix tokenize() on blank input".into(),
                PlanStepStatus::InProgress
            )]
        );
        mapper.message(&tool_use("l1", "TaskList", json!({})));
        let events = mapper.message(&tool_result(
            "l1",
            "#2 [completed] Fix tokenize()\n#3 [pending] Ship",
            false,
            json!({"tasks": [
                {"id": "2", "subject": "Fix tokenize()", "status": "completed", "blockedBy": []},
                {"id": "3", "subject": "Ship", "status": "pending", "blockedBy": []}
            ]}),
        ));
        assert_eq!(
            pinned_steps(&completed(&events, "l1").0),
            [
                ("Fix tokenize()".into(), PlanStepStatus::Completed),
                ("Ship".into(), PlanStepStatus::Pending)
            ]
        );
    }

    #[test]
    fn a_sub_agent_keeps_one_parent_and_its_tool_is_the_row_that_nests_it() {
        let mut mapper = running_turn("0d6a7c1e-1111-4a00-8000-000000000001");
        let events = mapper.message(&tool_use(
            "toolu_agent",
            "Agent",
            json!({"description": "Audit the parser tests", "subagent_type": "Explore",
                "prompt": "Find the tests…"}),
        ));
        let (
            ItemBody::Child {
                child,
                action,
                prompt,
                ..
            },
            parent,
        ) = started(&events, "toolu_agent")
        else {
            panic!("child");
        };
        assert!(parent.is_none());
        assert_eq!(child.id.as_str(), "toolu_agent");
        assert_eq!(action.as_deref(), Some("Explore"));
        assert_eq!(prompt.as_deref(), Some("Audit the parser tests"));

        let nested = |id: &str, agent_id: Option<&str>| {
            message(json!({"type": "assistant", "uuid": format!("a-{id}"),
                "parent_tool_use_id": "toolu_agent", "agent_id": agent_id,
                "message": {"id": format!("msg-{id}"), "role": "assistant",
                    "content": [{"type": "tool_use", "id": id, "name": "Grep", "input": {}}]}}))
        };
        // Before task_started names the task, and after it.
        let before = mapper.message(&nested("toolu_g1", None));
        mapper.message(&message(
            json!({"type": "system", "subtype": "task_started",
            "task_id": "a7f3", "tool_use_id": "toolu_agent", "description": "Audit",
            "task_type": "local_agent"}),
        ));
        let after = mapper.message(&nested("toolu_g2", Some("a7f3")));
        let parent_of = |events: &[Event], id: &str| {
            started(events, id)
                .1
                .map(|parent| parent.id.as_str().to_string())
        };
        assert_eq!(
            parent_of(&before, "toolu_g1").as_deref(),
            Some("toolu_agent")
        );
        assert_eq!(
            parent_of(&after, "toolu_g2").as_deref(),
            Some("toolu_agent")
        );

        // A permission ask from the sub-agent names the same parent.
        let RequestMapped::Interaction(events) = mapper.request(
            "r1",
            &json!({"subtype": "can_use_tool", "tool_name": "Bash", "agent_id": "a7f3",
                "input": {"command": "ls"}, "tool_use_id": "toolu_b9"}),
        ) else {
            panic!("interaction");
        };
        let Some(Event::Interaction(interaction)) = events.first() else {
            panic!("interaction");
        };
        assert_eq!(
            interaction.parent.as_ref().map(|parent| parent.id.as_str()),
            Some("toolu_agent")
        );

        // The tool's result completes the row as a child row.
        let events = mapper.message(&tool_result(
            "toolu_agent",
            "Two tests.",
            false,
            Value::Null,
        ));
        let (body, status, _) = completed(&events, "toolu_agent");
        assert!(matches!(body, ItemBody::Child { .. }));
        assert_eq!(status, ItemStatus::Completed);
    }

    fn running_turn(t1: &str) -> ClaudeMapper {
        let mut mapper = ClaudeMapper::new(None);
        mapper.sent(&InputId::new(t1).unwrap(), true);
        mapper.message(&message(
            json!({"type": "command_lifecycle", "command_uuid": t1, "state": "started"}),
        ));
        mapper
    }

    fn steer_tool_use(id: &str, name: &str) -> Value {
        json!({"type": "assistant", "uuid": format!("a-{id}"), "parent_tool_use_id": null,
            "message": {"id": format!("msg-{id}"), "role": "assistant",
                "content": [{"type": "tool_use", "id": id, "name": name, "input": {}}]}})
    }

    #[test]
    fn a_steer_cuts_only_while_the_model_works() {
        let t1 = "0d6a7c1e-1111-4a00-8000-000000000001";
        let s1 = InputId::new("0d6a7c1e-1111-4a00-8000-000000000002").unwrap();
        let mut mapper = ClaudeMapper::new(None);
        assert!(!mapper.steer_can_cut(), "no turn runs");
        mapper = running_turn(t1);
        assert!(mapper.steer_can_cut());

        // From the first streamed block of a tool call until its result.
        mapper.message(&message(json!({"type": "stream_event", "event": {
            "type": "content_block_start", "index": 0,
            "content_block": {"type": "tool_use", "id": "toolu_1", "name": "Bash"}}})));
        assert!(!mapper.steer_can_cut(), "a tool call is starting");
        mapper.message(&message(steer_tool_use("toolu_1", "Bash")));
        assert!(!mapper.steer_can_cut(), "a tool runs");
        mapper.message(&message(json!({"type": "user", "parent_tool_use_id": null,
            "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"}]}})));
        assert!(mapper.steer_can_cut());

        // A steer the CLI has not taken holds back the next one.
        mapper.sent_steer(&s1, false);
        assert!(!mapper.steer_can_cut());
        assert!(mapper.has_unread_steer());
        mapper.message(&message(
            json!({"type": "command_lifecycle", "command_uuid": s1.as_str(), "state": "queued"}),
        ));
        assert!(mapper.has_unread_steer());
        mapper.message(&message(
            json!({"type": "command_lifecycle", "command_uuid": s1.as_str(), "state": "started"}),
        ));
        assert!(!mapper.has_unread_steer());
        assert!(mapper.steer_can_cut());

        // Compaction and native commands are never cut.
        mapper.message(&message(
            json!({"type": "system", "subtype": "status", "status": "compacting"}),
        ));
        assert!(!mapper.steer_can_cut());
        mapper.message(&message(
            json!({"type": "system", "subtype": "status", "status": null}),
        ));
        assert!(mapper.steer_can_cut());
        mapper.sent_command();
        assert!(!mapper.steer_can_cut());
    }

    #[test]
    fn only_old_enough_commands_and_agents_are_detached() {
        let mut mapper = running_turn("0d6a7c1e-1111-4a00-8000-000000000001");
        mapper.message(&message(steer_tool_use("toolu_bash", "Bash")));
        mapper.message(&message(steer_tool_use("toolu_agent", "Agent")));
        mapper.message(&message(steer_tool_use("toolu_read", "Read")));
        assert!(
            mapper
                .detachable_tools(std::time::Duration::from_secs(3600))
                .is_empty(),
            "too young"
        );
        let mut tools = mapper.detachable_tools(std::time::Duration::ZERO);
        tools.sort();
        assert_eq!(tools, vec!["toolu_agent", "toolu_bash"]);
    }

    fn aborted_outcome(mapper: &mut ClaudeMapper, input: &str) -> TurnOutcome {
        let events = mapper.message(&message(
            json!({"type": "result", "subtype": "success", "is_error": false,
            "terminal_reason": "aborted_streaming", "user_message_uuids": [input]}),
        ));
        match events.last() {
            Some(Event::Turn {
                phase: TurnPhase::Completed { outcome, .. },
                ..
            }) => *outcome,
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_turn_cut_for_a_steer_is_not_a_stop() {
        let t1 = "0d6a7c1e-1111-4a00-8000-000000000001";
        let s1 = InputId::new("0d6a7c1e-1111-4a00-8000-000000000002").unwrap();
        let mut mapper = running_turn(t1);
        mapper.sent_steer(&s1, true);
        assert_eq!(aborted_outcome(&mut mapper, t1), TurnOutcome::Completed);

        // Only that turn, and not when the person stopped it meanwhile.
        let mut mapper = running_turn(t1);
        assert_eq!(aborted_outcome(&mut mapper, t1), TurnOutcome::Interrupted);
        let mut mapper = running_turn(t1);
        mapper.sent_steer(&s1, true);
        mapper.stop_requested();
        assert_eq!(aborted_outcome(&mut mapper, t1), TurnOutcome::Interrupted);
    }

    #[test]
    fn a_sub_agents_report_drops_the_frame_claude_code_adds_for_the_model() {
        let framed = "  <tools-used-before-summary>WebFetch</tools-used-before-summary>\n  \n  [Harness note, not part of the agent's report: nothing saved.]\n[Subagent hand-back] The text below is the final report. The report follows:\n  Rust 1.100.0 is the latest.\n  \n  - Announced Nov 12.\nagentId: a82239ca2d80aac4e (use SendMessage to continue)\n<usage>subagent_tokens: 17093\ntool_uses: 2</usage>";
        assert_eq!(
            subagent_report(framed, false, None).as_deref(),
            Some("Rust 1.100.0 is the latest.\n\n- Announced Nov 12.")
        );
        // The structured result carries the report alone.
        let structured = json!({"status": "completed", "agentId": "a1",
            "content": [{"type": "text", "text": "Found 2 callers."}]});
        assert_eq!(
            subagent_report(framed, false, Some(&structured)).as_deref(),
            Some("Found 2 callers.")
        );
        // The report again inside the frame is one report.
        let twice = json!({"status": "completed", "content": [
            {"type": "text", "text": "Rust 1.100.0 is the latest."},
            {"type": "text", "text": "<tools-used-before-summary>WebFetch</tools-used-before-summary>\nRust 1.100.0 is the latest.\n[Harness note, not part of the agent's report: no files.]"}
        ]});
        assert_eq!(
            subagent_report("", false, Some(&twice)).as_deref(),
            Some("Rust 1.100.0 is the latest.")
        );
        // A background launch has nothing to report yet.
        let launched = json!({"status": "async_launched", "agentId": "a2"});
        assert_eq!(
            subagent_report("Async agent launched successfully.", false, Some(&launched)),
            None
        );
        assert_eq!(
            subagent_report("Async agent launched successfully. (internal)", false, None),
            None
        );
    }

    #[test]
    fn retries_and_compaction_head_the_progress_while_they_last() {
        let live = |events: Vec<Event>| match events.as_slice() {
            [Event::Notice(notice)] if notice.code == LIVE_STATUS_NOTICE => notice.message.clone(),
            other => panic!("{other:?}"),
        };
        assert_eq!(
            live(vec![system_notice(
                "api_retry",
                &json!({"type": "system", "subtype": "api_retry", "attempt": 3, "max_retries": 10, "error_status": 529})
            )]),
            Some("Retrying (3/10) · overloaded".to_owned())
        );
        let mut mapper = ClaudeMapper::new(None);
        let compacting = mapper.message(&message(json!({"type": "system", "subtype": "status", "status": "compacting", "session_id": "s1"})));
        assert_eq!(live(compacting), Some("Compacting context".to_owned()));
        let done = mapper.message(&message(json!({"type": "system", "subtype": "status", "status": null, "compact_result": "success", "session_id": "s1"})));
        assert_eq!(live(done), None);
    }
}
