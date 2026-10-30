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
    ItemStatus, ItemUpdate, MessageRole, Notice, NoticeLevel, OpError, QuestionForm, QueueEntryId,
    QueuedInput, RunState, TokenUsage, TurnPhase, UsageUpdate, UserId, WaitingOn,
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
}

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
    facts: HashSet<(String, &'static str)>,
    effective: EffectiveSettings,
    tools: HashMap<String, ToolItem>,
    /// Content blocks seen per API message id, for stable block item ids.
    blocks_seen: HashMap<String, usize>,
    /// The API message being streamed, per parent tool use (`""` = main).
    streaming: HashMap<String, String>,
    children: HashMap<String, ChildRef>,
    /// Task tool_use id → child.
    child_by_tool_use: HashMap<String, ChildRef>,
    pending: HashMap<String, PendingAsk>,
    denied_tool_uses: HashSet<String>,
    /// `priority: later` inputs the CLI has not started yet.
    queue: Vec<QueuedInput>,
    /// The latest top-level call's tokens: the context fill the turn's
    /// result reports.
    last_call_usage: Option<TokenUsage>,
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
        self.awaiting_turn.retain(|waiting| waiting != input);
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
                if status.status.is_some() || status.compact_result.is_some() {
                    events.push(notice(
                        NoticeLevel::Info,
                        "status",
                        status_text(status),
                        &message.raw,
                    ));
                }
                events
            }
            MessageKind::CompactBoundary => {
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
            MessageKind::System { subtype } => vec![notice(
                NoticeLevel::Info,
                &format!("system/{subtype}"),
                None,
                &message.raw,
            )],
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
        let mut events = if matches!(state, "started" | "cancelled" | "discarded" | "refused") {
            self.dequeue(uuid)
        } else {
            Vec::new()
        };
        events.extend(self.lifecycle_events(uuid, state));
        events
    }

    fn lifecycle_events(&mut self, uuid: &str, state: &str) -> Vec<Event> {
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

    fn parent(&self, parent_tool_use_id: Option<&str>, agent_id: Option<&str>) -> Option<ChildRef> {
        if let Some(agent) = agent_id
            && let Some(child) = self.children.get(agent)
        {
            return Some(child.clone());
        }
        let tool_use = parent_tool_use_id?;
        if let Some(child) = self.child_by_tool_use.get(tool_use) {
            return Some(child.clone());
        }
        let id = agent_id.unwrap_or(tool_use);
        Some(ChildRef {
            id: ChildId::new(id).ok()?,
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
                    let body = tool_body(block);
                    if matches!(block["name"].as_str(), Some("Task" | "Agent"))
                        && let Ok(child_id) = ChildId::new(id.as_str())
                    {
                        // Until task_started names the task, the tool use stands in.
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
                    self.tools.insert(
                        id,
                        ToolItem {
                            turn: turn.clone(),
                            parent: parent.clone(),
                            body,
                            native: block.clone(),
                        },
                    );
                    events.push(Event::Item(item));
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
        let status = if self.denied_tool_uses.remove(tool_use_id) {
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
        let body = complete_body(tool.body, output, is_error, structured);
        let mut native = block.clone();
        if let Some(structured) = structured
            && let Some(object) = native.as_object_mut()
        {
            object.insert("tool_use_result".into(), structured.clone());
        }
        let _ = tool.native;
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
                }
                if let Some(id) = event["message"]["id"].as_str() {
                    self.streaming.insert(key, id.to_string());
                }
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
        if let Some(mut usage) = result_usage(result) {
            usage.last = self.last_call_usage.take();
            events.push(Event::Usage { usage });
        }
        let consumed: Vec<InputId> = match &result.user_message_uuids {
            Some(uuids) => uuids
                .iter()
                .filter_map(|uuid| InputId::new(uuid.as_str()).ok())
                .collect(),
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
            let dequeued = self.dequeue(input.as_str());
            events.extend(dequeued);
        }
        self.turn_inputs.clear();
        self.streaming.clear();
        let outcome = turn_outcome(result);
        let error = (outcome == TurnOutcome::Failed).then(|| result.error_text());
        // Tool calls an interrupted or failed turn left open ended with it.
        let open: Vec<String> = self
            .tools
            .iter()
            .filter(|_| outcome != TurnOutcome::Completed)
            .filter(|(_, tool)| tool.turn.as_ref() == Some(&turn))
            .map(|(id, _)| id.clone())
            .collect();
        for id in open {
            if let Some(tool) = self.tools.remove(&id) {
                events.push(Event::Item(
                    Item::new(
                        item_id(&id),
                        tool.turn,
                        ItemUpdate::Completed {
                            body: tool.body,
                            status: ItemStatus::Interrupted,
                        },
                        Value::Null,
                    )
                    .with_parent(tool.parent),
                ));
            }
        }
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
            self.child_by_tool_use
                .insert(tool_use.clone(), child.clone());
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
                    .and_then(|agent| self.children.get(agent).cloned());
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
                events: vec![notice(
                    NoticeLevel::Warning,
                    "request_user_dialog",
                    Some(format!(
                        "Claude asked for a {} dialog Inline cannot show",
                        dialog.dialog_kind
                    )),
                    request,
                )],
            },
            IncomingRequest::Elicitation(raw) => RequestMapped::Reply {
                response: Ok(json!({"action": "decline"})),
                events: vec![notice(
                    NoticeLevel::Warning,
                    "elicitation",
                    raw["message"].as_str().map(str::to_string),
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
                    PermissionDecision::answer_questions(input, answers_map(answers)),
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
        self.tools.clear();
        events
    }
}

fn item_id(id: &str) -> ItemId {
    ItemId::new(id)
        .unwrap_or_else(|_| ItemId::new(uuid::Uuid::new_v4().to_string()).expect("uuid id"))
}

fn notice(level: NoticeLevel, code: &str, message: Option<String>, native: &Value) -> Event {
    Event::Notice(Notice {
        level,
        code: code.to_string(),
        message,
        native: native.clone(),
    })
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
        _ => {
            let (name, server) = tool_name(name);
            ItemBody::Tool {
                name,
                server,
                input: input.clone(),
                output: None,
                error: None,
            }
        }
    }
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
        } => ItemBody::Command {
            command,
            cwd,
            actions,
            output: Some(output),
            exit_code: structured
                .and_then(|value| {
                    value["exitCode"]
                        .as_i64()
                        .or_else(|| value["exit_code"].as_i64())
                })
                .and_then(|code| i32::try_from(code).ok()),
            duration_ms,
        },
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
        ItemBody::FileChange { mut changes } => {
            if let Some(patch) = structured.and_then(|value| value["structuredPatch"].as_array())
                && let Some(change) = changes.first_mut()
            {
                change.diff = Some(render_patch(patch));
            }
            ItemBody::FileChange { changes }
        }
        other => other,
    }
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
    if info["status"] == "rejected" {
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
pub(crate) fn plan_usage(response: &Value) -> Vec<DriverUsageWindow> {
    ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
        .into_iter()
        .filter_map(|label| {
            let window = &response["rate_limits"][label];
            Some(usage_window(
                label,
                window["utilization"].as_f64()?,
                window["resets_at"]
                    .as_str()
                    .and_then(|time| chrono::DateTime::parse_from_rfc3339(time).ok())
                    .map(|time| time.timestamp()),
            ))
        })
        .collect()
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

fn question_form(permission: &PermissionRequest) -> QuestionForm {
    QuestionForm {
        title: permission.title.clone(),
        fields: permission
            .questions()
            .into_iter()
            .filter_map(|question| {
                Some(FormField {
                    id: FieldId::new(question.question.as_str()).ok()?,
                    header: question.header.clone(),
                    prompt: question.question.clone(),
                    input: FieldInput::Select {
                        options: question
                            .options
                            .iter()
                            .map(|option| FieldOption {
                                label: option.label.clone(),
                                description: option.description.clone(),
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

fn answers_map(answers: &[FieldAnswer]) -> Map<String, Value> {
    answers
        .iter()
        .map(|answer| {
            (
                answer.field.as_str().to_string(),
                json!(answer.values.join(", ")),
            )
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
        assert!(
            rate_limit(&json!({"status": "allowed", "rateLimitType": "five_hour"})).is_empty()
        );
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
        let mut mapper = ClaudeMapper::new(None);
        let events = mapper.message(&message(json!({"type": "result", "subtype": "success",
            "is_error": true, "result": "Invalid API key · Please run /login", "user_message_uuids": ["0d6a7c1e-1111-4a00-8000-000000000001"]})));
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
}
