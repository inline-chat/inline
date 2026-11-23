//! Codex app-server wire to session contract.
//!
//! Pure and synchronous: the session feeds it every notification and server
//! request for its thread (and its sub-agent threads) and writes what it
//! returns. Every native event lands in the stream; anything without a typed
//! home becomes a [`Notice`] with its payload, never dropped and never read as
//! idle.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use inline_agent_bridge::harness::{
    ApprovalSubject, ChildKind, ChildRef, ChildStatus, ChildUpdate, ClosedBy, CommandAction,
    Decision, DeltaStream, EffectiveSettings, Event, FieldId, FieldInput, FieldOption,
    FileChangeKind, FileDiff, FormField, InputFact, InputId, Interaction, InteractionId,
    InteractionKind, InteractionResponse, Item, ItemBody, ItemDelta, ItemId, ItemKind, ItemStatus,
    ItemUpdate, MessageRole, Notice, NoticeLevel, OpError, QuestionForm, RunState, TokenUsage,
    TurnPhase, UsageUpdate, UserId, WaitingOn,
};
use inline_agent_bridge::{
    AgentMessagePhase, DriverSettingOption, PlanStep, PlanStepStatus, TurnId, TurnOutcome,
};
use serde_json::{Map, Value, json};

use super::decisions;
use crate::protocol::normalize_usage_limits;

/// Prefix of `clientUserMessageId` values that carry an Inline input id.
pub(crate) const CLIENT_MESSAGE_PREFIX: &str = "inline-agent-bridge:v2:";

/// The Codex `clientUserMessageId` for an Inline input.
pub(crate) fn client_message_id(input: &InputId) -> String {
    format!("{CLIENT_MESSAGE_PREFIX}{input}")
}

fn input_from_client_id(client_id: Option<&str>) -> Option<InputId> {
    InputId::new(client_id?.strip_prefix(CLIENT_MESSAGE_PREFIX)?).ok()
}

/// Events from one notification, plus follow-ups the session must run.
#[derive(Debug, Default, PartialEq)]
pub(crate) struct Mapped {
    pub events: Vec<Event>,
    /// `thread/queue/changed`: the session lists the queue and emits it.
    pub refresh_queue: bool,
}

/// What to do with one server request.
#[derive(Debug, PartialEq)]
pub(crate) enum RequestMapped {
    /// An interaction opened; the answer comes from [`CodexMapper::answer`].
    Interaction(Vec<Event>),
    /// Reply now (unknown dialogs are cancelled safely), and emit the events.
    Reply {
        result: Result<Value, (i64, String)>,
        events: Vec<Event>,
    },
    /// A dynamic tool call for Inline's host tools.
    HostTool,
    /// Not for this session (connection-level request).
    NotMine,
}

/// How to deliver an answer.
#[derive(Debug, PartialEq)]
pub(crate) enum AnswerPlan {
    /// Respond to the pending JSON-RPC request.
    Respond {
        rpc_id: Value,
        result: Value,
        events: Vec<Event>,
        /// Text to send as the next input ("tell Codex what to do differently").
        follow_up: Option<String>,
    },
    /// Async questions are answered with ordinary input.
    SendInput { text: String, events: Vec<Event> },
}

#[derive(Debug, Clone)]
enum Pending {
    Command,
    FileChange,
    Permissions,
    ElicitationUrl,
    ElicitationForm,
    /// A message-only form (Codex asking to run an MCP tool): answered with
    /// the picked decision's native response.
    ElicitationApproval,
    UserInput,
    AsyncQuestions,
}

#[derive(Debug, Clone)]
struct PendingRequest {
    rpc_id: Value,
    turn: Option<TurnId>,
    params: Value,
    kind: Pending,
    decisions: Vec<Decision>,
}

#[derive(Debug, Clone)]
struct ItemMemo {
    paths: Vec<PathBuf>,
}

/// Per-session translation state.
#[derive(Debug)]
pub(crate) struct CodexMapper {
    thread: String,
    active_turn: Option<TurnId>,
    /// The main thread's latest completed, failed or interrupted turn
    /// (`thread/sample` names it as `expectedTurnId`).
    last_finished_turn: Option<TurnId>,
    consumed: HashMap<TurnId, Vec<InputId>>,
    seen_inputs: HashSet<InputId>,
    items: HashMap<String, ItemMemo>,
    requests: HashMap<String, PendingRequest>,
    answered: HashSet<String>,
    children: HashMap<String, ChildRef>,
    /// A sub-agent thread's running turn, for its requests that name none.
    child_turns: HashMap<String, TurnId>,
    /// When the account's exhausted limit window resets, from the latest
    /// `account/rateLimits/updated`.
    limit_resets_at: Option<i64>,
    /// The app-server connection ended; no turn can finish natively anymore.
    lost: bool,
}

impl CodexMapper {
    pub(crate) fn new(thread: impl Into<String>) -> Self {
        Self {
            thread: thread.into(),
            active_turn: None,
            last_finished_turn: None,
            consumed: HashMap::new(),
            seen_inputs: HashSet::new(),
            items: HashMap::new(),
            requests: HashMap::new(),
            answered: HashSet::new(),
            children: HashMap::new(),
            child_turns: HashMap::new(),
            limit_resets_at: None,
            lost: false,
        }
    }

    /// The running turn on the main thread.
    pub(crate) fn active_turn(&self) -> Option<&TurnId> {
        self.active_turn.as_ref()
    }

    /// The main thread's latest finished turn.
    pub(crate) fn last_finished_turn(&self) -> Option<&TurnId> {
        self.last_finished_turn.as_ref()
    }

    /// Restores turn facts from a `thread/resume` or `thread/fork` response.
    pub(crate) fn restore_turns(&mut self, active: Option<TurnId>, finished: Option<TurnId>) {
        self.active_turn = active;
        if finished.is_some() {
            self.last_finished_turn = finished;
        }
    }

    /// Inline inputs a resumed thread's turns already consumed, from the
    /// `thread/*` response, so the bridge settles any it was unsure of
    /// instead of resending them.
    pub(crate) fn restore_inputs(&mut self, response: &Value) -> Vec<Event> {
        let mut events = Vec::new();
        // A still-unconfirmed input can predate the latest turns.
        for turn in response
            .pointer("/thread/turns")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .rev()
        {
            let Some(id) = turn_id(turn.get("id")) else {
                continue;
            };
            for item in turn
                .get("items")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                if let (
                    ItemBody::Message {
                        role: MessageRole::User,
                        input: Some(input),
                        ..
                    },
                    _,
                    _,
                ) = item_body(item)
                    && self.seen_inputs.insert(input.clone())
                {
                    events.push(Event::Input {
                        id: input,
                        fact: InputFact::Consumed { turn: id.clone() },
                    });
                }
            }
        }
        events
    }

    /// Records the turn returned by `turn/start` before its notification
    /// arrives. A turn that already finished stays finished, and one whose
    /// connection ended before the reply was handled completes as
    /// `ConnectionLost` right away (returned for the caller to emit).
    pub(crate) fn turn_started_by_request(&mut self, turn: TurnId) -> Vec<Event> {
        if self.last_finished_turn.as_ref() == Some(&turn) {
            return Vec::new();
        }
        if self.lost {
            self.last_finished_turn = Some(turn.clone());
            return vec![connection_lost_turn(
                turn.clone(),
                self.consumed.remove(&turn).unwrap_or_default(),
            )];
        }
        self.active_turn = Some(turn);
        Vec::new()
    }

    /// Pending interactions, for `live_work`.
    pub(crate) fn pending_interactions(&self) -> Vec<InteractionId> {
        let mut ids: Vec<_> = self
            .requests
            .keys()
            .filter_map(|id| InteractionId::new(id.clone()).ok())
            .collect();
        ids.sort();
        ids
    }

    /// Live sub-agent threads, for `live_work`.
    pub(crate) fn children(&self) -> Vec<ChildRef> {
        let mut children: Vec<_> = self.children.values().cloned().collect();
        children.sort_by(|left, right| left.id.cmp(&right.id));
        children
    }

    /// Whether a message for `thread_id` belongs to this session, and under which child.
    pub(crate) fn owns_thread(&self, thread_id: Option<&str>) -> bool {
        match thread_id {
            None => true,
            Some(thread) => thread == self.thread || self.children.contains_key(thread),
        }
    }

    fn parent_of(&self, params: &Value) -> Option<ChildRef> {
        let thread = params.get("threadId").and_then(Value::as_str)?;
        if thread == self.thread {
            None
        } else {
            self.children.get(thread).cloned()
        }
    }

    /// Maps one notification.
    pub(crate) fn notification(&mut self, method: &str, params: &Value) -> Mapped {
        let mut mapped = Mapped::default();
        if !self.owns_thread(params.get("threadId").and_then(Value::as_str)) {
            return mapped;
        }
        let parent = self.parent_of(params);
        let events = &mut mapped.events;
        match method {
            "turn/started" => {
                let Some(turn) = turn_id(params.pointer("/turn/id")) else {
                    events.push(notice(NoticeLevel::Warning, method, params));
                    return mapped;
                };
                if let Some(child) = parent {
                    self.child_turns
                        .insert(child.id.as_str().to_owned(), turn.clone());
                    events.push(child_update(child, ChildStatus::Running, None, params));
                } else {
                    self.active_turn = Some(turn.clone());
                    events.push(Event::Turn {
                        turn,
                        phase: TurnPhase::Started { inputs: Vec::new() },
                    });
                }
            }
            "turn/completed" => self.turn_completed(params, parent, events),
            "item/started" | "item/completed" => {
                self.item_event(method == "item/completed", params, parent, events);
            }
            "item/agentMessage/delta" => {
                push_delta(
                    events,
                    params,
                    ItemKind::Message,
                    DeltaStream::Text,
                    None,
                    parent,
                );
            }
            "item/plan/delta" => {
                push_delta(
                    events,
                    params,
                    ItemKind::Plan,
                    DeltaStream::Plan,
                    None,
                    parent,
                );
            }
            "item/reasoning/summaryTextDelta" => push_delta(
                events,
                params,
                ItemKind::Reasoning,
                DeltaStream::ReasoningSummary,
                index(params, "summaryIndex"),
                parent,
            ),
            "item/reasoning/textDelta" => push_delta(
                events,
                params,
                ItemKind::Reasoning,
                DeltaStream::ReasoningContent,
                index(params, "contentIndex"),
                parent,
            ),
            // A structural marker; the next summary delta carries its index.
            "item/reasoning/summaryPartAdded" => {}
            "item/commandExecution/outputDelta" => {
                push_delta(
                    events,
                    params,
                    ItemKind::Command,
                    DeltaStream::Output,
                    None,
                    parent,
                );
            }
            "item/fileChange/outputDelta" => {
                push_delta(
                    events,
                    params,
                    ItemKind::FileChange,
                    DeltaStream::Output,
                    None,
                    parent,
                );
            }
            "item/mcpToolCall/progress" => {
                if let (Some(item), Some(message)) = (
                    item_id(params.get("itemId")),
                    params.get("message").and_then(Value::as_str),
                ) {
                    events.push(Event::Item(
                        Item::new(
                            item,
                            turn_id(params.get("turnId")),
                            ItemUpdate::Delta {
                                delta: ItemDelta {
                                    stream: DeltaStream::Output,
                                    index: None,
                                    text: format!("{message}\n"),
                                },
                            },
                            Value::Null,
                        )
                        .with_kind(ItemKind::Tool)
                        .with_parent(parent),
                    ));
                }
            }
            "item/fileChange/patchUpdated" => {
                if let Some(item) = item_id(params.get("itemId")) {
                    let changes = file_changes(params.get("changes"));
                    self.remember_paths(item.as_str(), &changes);
                    events.push(Event::Item(
                        Item::new(
                            item,
                            turn_id(params.get("turnId")),
                            ItemUpdate::Updated {
                                body: ItemBody::FileChange { changes },
                            },
                            params.clone(),
                        )
                        .with_parent(parent),
                    ));
                }
            }
            "turn/plan/updated" => {
                let turn = turn_id(params.get("turnId"));
                let id = ItemId::new(format!(
                    "turn-plan:{}",
                    turn.as_ref().map_or("unknown", TurnId::as_str)
                ))
                .expect("plan item id");
                let steps = params
                    .get("plan")
                    .and_then(Value::as_array)
                    .map(|steps| steps.iter().filter_map(plan_step).collect())
                    .unwrap_or_default();
                events.push(Event::Item(
                    Item::new(
                        id,
                        turn,
                        ItemUpdate::Updated {
                            body: ItemBody::Plan {
                                explanation: string(params.get("explanation")),
                                steps,
                                text: None,
                            },
                        },
                        params.clone(),
                    )
                    .with_parent(parent),
                ));
            }
            "thread/tokenUsage/updated" => {
                let usage = params.get("tokenUsage").unwrap_or(&Value::Null);
                events.push(Event::Usage {
                    usage: UsageUpdate {
                        last: token_usage(usage.get("last")),
                        total: token_usage(usage.get("total")),
                        context_window: usage.get("modelContextWindow").and_then(Value::as_u64),
                        limits: Vec::new(),
                    },
                });
            }
            "account/rateLimits/updated" => {
                let limits = normalize_usage_limits(params);
                self.limit_resets_at = limits
                    .iter()
                    .filter(|window| window.used_percent >= 100)
                    .filter_map(|window| window.resets_at)
                    .max();
                if !limits.is_empty() {
                    events.push(Event::Usage {
                        usage: UsageUpdate {
                            limits,
                            ..UsageUpdate::default()
                        },
                    });
                }
            }
            // A sub-agent's thread can ask for approval before the spawn
            // item that names it arrives; its start names its parent.
            "thread/started" => {
                if let (Some(thread), Some(parent_thread)) = (
                    string(params.pointer("/thread/id")),
                    string(params.pointer("/thread/parentThreadId")),
                ) && thread != self.thread
                    && self.owns_thread(Some(&parent_thread))
                    && !self.children.contains_key(&thread)
                    && let Ok(id) = inline_agent_bridge::harness::ChildId::new(thread.clone())
                {
                    self.children.insert(
                        thread,
                        ChildRef {
                            id,
                            kind: ChildKind::Subagent,
                        },
                    );
                }
                events.push(notice(NoticeLevel::Info, method, params));
            }
            "thread/status/changed" if parent.is_none() => {
                match params.pointer("/status/type").and_then(Value::as_str) {
                    Some("idle") => events.push(Event::State {
                        state: RunState::Idle,
                    }),
                    Some("active") => {
                        let flags = params
                            .pointer("/status/activeFlags")
                            .and_then(Value::as_array)
                            .cloned()
                            .unwrap_or_default();
                        let state = if flags.iter().any(|flag| flag == "waitingOnApproval") {
                            RunState::Waiting {
                                on: WaitingOn::Approval,
                            }
                        } else if flags.iter().any(|flag| flag == "waitingOnUserInput") {
                            RunState::Waiting {
                                on: WaitingOn::Question,
                            }
                        } else {
                            RunState::Working
                        };
                        events.push(Event::State { state });
                    }
                    Some("systemError") => {
                        let mut event = notice(NoticeLevel::Error, method, params);
                        if let Event::Notice(notice) = &mut event {
                            notice.message = string(params.pointer("/status/message"))
                                .or_else(|| string(params.pointer("/status/error/message")))
                                .or_else(|| Some("Codex reported a system error".to_owned()));
                        }
                        events.push(event);
                    }
                    _ => events.push(notice(NoticeLevel::Info, method, params)),
                }
            }
            "serverRequest/resolved" => {
                let Some(id) = request_id_string(params.get("requestId")) else {
                    return mapped;
                };
                if self.answered.remove(&id) {
                    return mapped;
                }
                if self.requests.remove(&id).is_some()
                    && let Ok(id) = InteractionId::new(id)
                {
                    events.push(Event::InteractionClosed {
                        id,
                        by: ClosedBy::External,
                    });
                }
            }
            "thread/name/updated" if parent.is_none() => {
                if let Some(title) = string(params.get("threadName")) {
                    events.push(Event::Renamed { title });
                }
            }
            "thread/settings/updated" if parent.is_none() => {
                events.push(Event::Settings {
                    effective: effective_settings(
                        params.get("threadSettings").unwrap_or(&Value::Null),
                    ),
                });
            }
            "thread/queue/changed" if parent.is_none() => mapped.refresh_queue = true,
            // Codex unloaded the thread: native ownership is released.
            "thread/closed" if parent.is_none() => events.push(Event::State {
                state: RunState::Released,
            }),
            "thread/compacted" => {
                let id = ItemId::new(format!(
                    "compaction:{}",
                    params
                        .get("turnId")
                        .and_then(Value::as_str)
                        .unwrap_or("thread")
                ))
                .expect("compaction id");
                events.push(Event::Item(
                    Item::new(
                        id,
                        turn_id(params.get("turnId")),
                        ItemUpdate::Completed {
                            body: ItemBody::Usage {
                                label: "Context compacted".to_owned(),
                            },
                            status: ItemStatus::Completed,
                        },
                        params.clone(),
                    )
                    .with_parent(parent),
                ));
            }
            "error" => {
                let level = if params.get("willRetry").and_then(Value::as_bool) == Some(true) {
                    NoticeLevel::Warning
                } else {
                    NoticeLevel::Error
                };
                let mut event = notice(level, method, params);
                if let Event::Notice(notice) = &mut event {
                    notice.message = string(params.pointer("/error/message"));
                }
                events.push(event);
            }
            "warning" | "configWarning" | "deprecationNotice" | "guardianWarning" => {
                let mut event = notice(NoticeLevel::Warning, method, params);
                if let Event::Notice(notice) = &mut event {
                    notice.message =
                        string(params.get("message")).or_else(|| string(params.get("summary")));
                }
                events.push(event);
            }
            _ => events.push(notice(NoticeLevel::Info, method, params)),
        }
        mapped
    }

    fn turn_completed(
        &mut self,
        params: &Value,
        parent: Option<ChildRef>,
        events: &mut Vec<Event>,
    ) {
        let Some(turn) = turn_id(params.pointer("/turn/id")) else {
            events.push(notice(NoticeLevel::Warning, "turn/completed", params));
            return;
        };
        let status = params
            .pointer("/turn/status")
            .and_then(Value::as_str)
            .unwrap_or("");
        let error_info = params
            .pointer("/turn/error/codexErrorInfo")
            .and_then(|info| {
                info.as_str()
                    .or_else(|| info.as_object()?.keys().next().map(String::as_str))
            });
        let outcome = match (status, error_info) {
            (_, Some("unauthorized")) => TurnOutcome::AuthenticationRequired,
            ("completed", _) => TurnOutcome::Completed,
            ("interrupted", _) => TurnOutcome::Interrupted,
            _ => TurnOutcome::Failed,
        };
        // Out of usage: the work waits on the limit until it resets.
        if parent.is_none()
            && matches!(error_info, Some("usageLimitExceeded" | "rateLimitExceeded"))
        {
            events.push(Event::State {
                state: RunState::Waiting {
                    on: WaitingOn::Limit {
                        resets_at: self.limit_resets_at,
                    },
                },
            });
        }
        // Codex withdraws a thread's blocking requests when its turn ends,
        // a sub-agent's included; closed here they read as no longer needed,
        // not as answered elsewhere.
        let mut closed: Vec<String> = self
            .requests
            .iter()
            .filter(|(_, request)| {
                request.turn.as_ref() == Some(&turn)
                    && !matches!(request.kind, Pending::AsyncQuestions)
            })
            .map(|(id, _)| id.clone())
            .collect();
        closed.sort();
        for id in closed {
            self.requests.remove(&id);
            if let Ok(id) = InteractionId::new(id) {
                events.push(Event::InteractionClosed {
                    id,
                    by: ClosedBy::Cancelled,
                });
            }
        }
        if let Some(child) = parent {
            if self.child_turns.get(child.id.as_str()) == Some(&turn) {
                self.child_turns.remove(child.id.as_str());
            }
            let status = match outcome {
                TurnOutcome::Completed => ChildStatus::Completed,
                TurnOutcome::Interrupted => ChildStatus::Stopped,
                _ => ChildStatus::Failed,
            };
            events.push(child_update(child, status, None, params));
            return;
        }
        if self.active_turn.as_ref() == Some(&turn) {
            self.active_turn = None;
        }
        if parent.is_none() {
            self.last_finished_turn = Some(turn.clone());
        }
        let error = params
            .pointer("/turn/error/message")
            .and_then(Value::as_str)
            .map(|message| message.split_whitespace().collect::<Vec<_>>().join(" "))
            .filter(|message| !message.is_empty());
        events.push(Event::Turn {
            phase: TurnPhase::Completed {
                outcome,
                inputs_consumed: self.consumed.remove(&turn).unwrap_or_default(),
                error,
                duration_ms: params.pointer("/turn/durationMs").and_then(Value::as_u64),
            },
            turn,
        });
    }

    fn item_event(
        &mut self,
        completed: bool,
        params: &Value,
        parent: Option<ChildRef>,
        events: &mut Vec<Event>,
    ) {
        let Some(item) = params.get("item") else {
            events.push(notice(NoticeLevel::Warning, "item", params));
            return;
        };
        let Some(id) = item_id(item.get("id")) else {
            events.push(notice(NoticeLevel::Warning, "item", params));
            return;
        };
        let turn = turn_id(params.get("turnId"));
        let (body, status, phase) = item_body(item);

        if let ItemBody::FileChange { changes } = &body {
            self.remember_paths(id.as_str(), changes);
        } else {
            self.items
                .insert(id.as_str().to_owned(), ItemMemo { paths: Vec::new() });
        }

        // A user message echo is the consumption fact for its Inline input.
        if let ItemBody::Message {
            role: MessageRole::User,
            input: Some(input),
            ..
        } = &body
            && parent.is_none()
            && self.seen_inputs.insert(input.clone())
            && let Some(turn) = turn.clone().or_else(|| self.active_turn.clone())
        {
            self.consumed
                .entry(turn.clone())
                .or_default()
                .push(input.clone());
            events.push(Event::Input {
                id: input.clone(),
                fact: InputFact::Consumed { turn },
            });
        }

        // Sub-agent spawns register their threads so their events nest here.
        for child in child_refs(item) {
            self.children
                .insert(child.id.as_str().to_owned(), child.clone());
            let status = child_status_from_item(item, child.id.as_str(), completed);
            events.push(child_update(
                child,
                status,
                string(item.get("prompt")).or_else(|| string(item.get("agentPath"))),
                item,
            ));
        }

        let update = if completed {
            ItemUpdate::Completed {
                body: body.clone(),
                status,
            }
        } else {
            ItemUpdate::Started { body: body.clone() }
        };
        events.push(Event::Item(
            Item::new(id.clone(), turn.clone(), update, item.clone())
                .with_parent(parent.clone())
                .with_phase(phase),
        ));

        // Async questions on a completed message open a question card.
        if completed
            && parent.is_none()
            && let Some(questions) = item.get("questions").and_then(Value::as_array)
            && !questions.is_empty()
        {
            let fields: Vec<FormField> = questions
                .iter()
                .enumerate()
                .filter_map(|(index, question)| {
                    let title = string(question.get("title"))?;
                    let options: Vec<FieldOption> = question
                        .get("options")
                        .and_then(Value::as_array)
                        .map(|options| {
                            options
                                .iter()
                                .filter_map(|option| string(Some(option)))
                                .map(|label| FieldOption {
                                    label,
                                    description: None,
                                    preview: None,
                                })
                                .collect()
                        })
                        .unwrap_or_default();
                    let input = if options.is_empty() {
                        FieldInput::Text {
                            multiline: true,
                            default: None,
                        }
                    } else {
                        FieldInput::Select {
                            options,
                            multiple: false,
                            allow_other: true,
                        }
                    };
                    Some(FormField {
                        id: FieldId::new(format!("q{index}")).expect("field id"),
                        header: None,
                        prompt: title,
                        input,
                        required: false,
                    })
                })
                .collect();
            if !fields.is_empty() {
                let interaction = format!("questions:{id}");
                self.requests.insert(
                    interaction.clone(),
                    PendingRequest {
                        rpc_id: Value::Null,
                        turn: turn.clone(),
                        params: item.clone(),
                        kind: Pending::AsyncQuestions,
                        decisions: Vec::new(),
                    },
                );
                events.push(Event::Interaction(Interaction {
                    id: InteractionId::new(interaction).expect("interaction id"),
                    turn,
                    item: Some(id),
                    parent: None,
                    kind: InteractionKind::Question {
                        form: QuestionForm {
                            title: None,
                            fields,
                            asynchronous: true,
                            auto_resolution_ms: None,
                        },
                    },
                    native: item.clone(),
                }));
            }
        }
    }

    fn remember_paths(&mut self, item: &str, changes: &[FileDiff]) {
        self.items.insert(
            item.to_owned(),
            ItemMemo {
                paths: changes.iter().map(|change| change.path.clone()).collect(),
            },
        );
    }

    /// Maps one server request.
    pub(crate) fn server_request(
        &mut self,
        rpc_id: &Value,
        method: &str,
        params: &Value,
    ) -> RequestMapped {
        if !self.owns_thread(params.get("threadId").and_then(Value::as_str)) {
            return RequestMapped::NotMine;
        }
        let Some(id) = request_id_string(Some(rpc_id)) else {
            return RequestMapped::NotMine;
        };
        let mut turn = turn_id(params.get("turnId"));
        let item = item_id(params.get("itemId"));
        let parent = self.parent_of(params);
        // An elicitation's `turnId` is nullable. Codex withdraws a thread's
        // requests when its turn ends, so one seen during a thread's turn
        // belongs to it, and its card closes with it.
        if turn.is_none() && method == "mcpServer/elicitation/request" {
            turn = match &parent {
                None => self.active_turn.clone(),
                Some(child) => self.child_turns.get(child.id.as_str()).cloned(),
            };
        }
        let (kind, pending, decisions) = match method {
            "item/commandExecution/requestApproval" => {
                let decisions = decisions::command_decisions(params);
                (
                    InteractionKind::Approval {
                        subject: ApprovalSubject::Command {
                            command: command_text(params.get("command")).unwrap_or_default(),
                            cwd: string(params.get("cwd")).map(PathBuf::from),
                            reason: string(params.get("reason")),
                            network_host: string(params.pointer("/networkApprovalContext/host")),
                            permissions: permissions_summary(params.get("additionalPermissions")),
                        },
                        decisions: decisions.clone(),
                    },
                    Pending::Command,
                    decisions,
                )
            }
            "item/fileChange/requestApproval" => {
                let decisions = decisions::file_change_decisions();
                let paths = item
                    .as_ref()
                    .and_then(|item| self.items.get(item.as_str()))
                    .map(|memo| memo.paths.clone())
                    .unwrap_or_default();
                (
                    InteractionKind::Approval {
                        subject: ApprovalSubject::FileChange {
                            paths,
                            reason: string(params.get("reason")),
                            grant_root: string(params.get("grantRoot")).map(PathBuf::from),
                        },
                        decisions: decisions.clone(),
                    },
                    Pending::FileChange,
                    decisions,
                )
            }
            "item/permissions/requestApproval" => {
                let decisions = decisions::permissions_decisions();
                (
                    InteractionKind::Approval {
                        subject: ApprovalSubject::Permissions {
                            summary: permissions_summary(params.get("permissions"))
                                .unwrap_or_else(|| "Additional permissions".to_owned()),
                            reason: string(params.get("reason")),
                        },
                        decisions: decisions.clone(),
                    },
                    Pending::Permissions,
                    decisions,
                )
            }
            "item/tool/requestUserInput" => match user_input_form(params) {
                Some(form) => (
                    InteractionKind::Question { form },
                    Pending::UserInput,
                    Vec::new(),
                ),
                None => return self.cancel_dialog(id, method, params),
            },
            "mcpServer/elicitation/request" => match params.get("mode").and_then(Value::as_str) {
                Some("form") if is_message_only(params) => {
                    let decisions = decisions::message_only_decisions(params);
                    (
                        InteractionKind::Approval {
                            subject: message_only_subject(params),
                            decisions: decisions.clone(),
                        },
                        Pending::ElicitationApproval,
                        decisions,
                    )
                }
                Some("form") => match elicitation_form(params) {
                    Some(form) => (
                        InteractionKind::Question { form },
                        Pending::ElicitationForm,
                        Vec::new(),
                    ),
                    None => return self.cancel_dialog(id, method, params),
                },
                Some("url") => {
                    let decisions = decisions::elicitation_decisions();
                    (
                        InteractionKind::Approval {
                            subject: ApprovalSubject::Other {
                                title: string(params.get("message"))
                                    .unwrap_or_else(|| "Open a link to continue".to_owned()),
                                detail: string(params.get("url")),
                            },
                            decisions: decisions.clone(),
                        },
                        Pending::ElicitationUrl,
                        decisions,
                    )
                }
                _ => return self.cancel_dialog(id, method, params),
            },
            "item/tool/call" => return RequestMapped::HostTool,
            "account/chatgptAuthTokens/refresh" | "attestation/generate" | "currentTime/read" => {
                return RequestMapped::NotMine;
            }
            _ => return self.cancel_dialog(id, method, params),
        };
        self.requests.insert(
            id.clone(),
            PendingRequest {
                rpc_id: rpc_id.clone(),
                turn: turn.clone(),
                params: params.clone(),
                kind: pending,
                decisions,
            },
        );
        RequestMapped::Interaction(vec![Event::Interaction(Interaction {
            id: InteractionId::new(id).expect("request id"),
            turn,
            item,
            parent,
            kind,
            native: params.clone(),
        })])
    }

    /// Unknown dialog kinds are cancelled safely with a visible notice (spec §4.2).
    fn cancel_dialog(&mut self, id: String, method: &str, params: &Value) -> RequestMapped {
        let mut events = Vec::new();
        if let Ok(interaction) = InteractionId::new(id) {
            events.push(Event::Interaction(Interaction {
                id: interaction.clone(),
                turn: turn_id(params.get("turnId")),
                item: item_id(params.get("itemId")),
                parent: self.parent_of(params),
                kind: InteractionKind::Dialog {
                    dialog: method.to_owned(),
                },
                native: params.clone(),
            }));
            events.push(Event::InteractionClosed {
                id: interaction,
                by: ClosedBy::Cancelled,
            });
        }
        let mut warning = notice(NoticeLevel::Warning, method, params);
        if let Event::Notice(notice) = &mut warning {
            notice.message = Some(format!(
                "Codex asked for `{method}`, which Inline cannot show yet; it was cancelled."
            ));
        }
        events.push(warning);
        RequestMapped::Reply {
            result: Err((-32601, format!("{method} is not supported by Inline"))),
            events,
        }
    }

    /// Builds the native answer to a pending interaction. Claimed once.
    pub(crate) fn answer(
        &mut self,
        interaction: &InteractionId,
        response: &InteractionResponse,
        by: UserId,
    ) -> Result<AnswerPlan, OpError> {
        let request = self
            .requests
            .get(interaction.as_str())
            .cloned()
            .ok_or(OpError::InteractionNotPending)?;
        let (picked, message) = match response {
            InteractionResponse::Decision { decision, message } => {
                let picked = request
                    .decisions
                    .iter()
                    .find(|candidate| &candidate.id == decision)
                    .cloned()
                    .ok_or_else(|| {
                        OpError::InvalidResponse(format!("`{decision}` was not offered"))
                    })?;
                (Some(picked), message.clone())
            }
            _ => (None, None),
        };
        let decision_id = picked.as_ref().map(|decision| decision.id.clone());
        let follow_up = message
            .filter(|message| !message.trim().is_empty())
            .filter(|_| {
                picked
                    .as_ref()
                    .is_some_and(|decision| decision.accepts_message)
            });

        let result = match (&request.kind, response) {
            (Pending::Command | Pending::FileChange, InteractionResponse::Decision { .. }) => {
                json!({"decision": picked.as_ref().expect("picked").native})
            }
            (Pending::Command | Pending::FileChange, InteractionResponse::Cancel) => {
                json!({"decision": "cancel"})
            }
            (Pending::Permissions, InteractionResponse::Decision { .. }) => {
                let mut result = picked.as_ref().expect("picked").native.clone();
                if let Some(object) = result.as_object_mut()
                    && !object.contains_key("permissions")
                {
                    object.insert(
                        "permissions".to_owned(),
                        request
                            .params
                            .get("permissions")
                            .cloned()
                            .unwrap_or(json!({})),
                    );
                }
                result
            }
            (Pending::Permissions, InteractionResponse::Cancel) => {
                json!({"scope": "turn", "permissions": {}})
            }
            (Pending::ElicitationUrl, InteractionResponse::Decision { .. }) => {
                json!({"action": picked.as_ref().expect("picked").native})
            }
            (Pending::ElicitationApproval, InteractionResponse::Decision { .. }) => {
                picked.as_ref().expect("picked").native.clone()
            }
            (
                Pending::ElicitationUrl | Pending::ElicitationForm | Pending::ElicitationApproval,
                InteractionResponse::Cancel,
            ) => {
                json!({"action": "cancel"})
            }
            (Pending::ElicitationForm, InteractionResponse::Answers { answers }) => {
                let schema = request
                    .params
                    .pointer("/requestedSchema/properties")
                    .and_then(Value::as_object)
                    .cloned()
                    .unwrap_or_default();
                let mut content = Map::new();
                for answer in answers {
                    let kind = schema
                        .get(answer.field.as_str())
                        .and_then(|field| field.get("type"))
                        .and_then(Value::as_str)
                        .unwrap_or("string");
                    content.insert(
                        answer.field.as_str().to_owned(),
                        typed_answer(kind, &answer.values),
                    );
                }
                json!({"action": "accept", "content": content})
            }
            (Pending::UserInput, InteractionResponse::Answers { answers }) => {
                let mut map = Map::new();
                for answer in answers {
                    map.insert(
                        answer.field.as_str().to_owned(),
                        json!({"answers": answer.values}),
                    );
                }
                json!({"answers": map})
            }
            (Pending::UserInput, InteractionResponse::Cancel) => json!({"answers": {}}),
            (Pending::AsyncQuestions, InteractionResponse::Answers { answers }) => {
                let questions = request
                    .params
                    .get("questions")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                let text = answers
                    .iter()
                    .filter(|answer| !answer.values.is_empty())
                    .map(|answer| {
                        let title = answer
                            .field
                            .as_str()
                            .strip_prefix('q')
                            .and_then(|index| index.parse::<usize>().ok())
                            .and_then(|index| questions.get(index))
                            .and_then(|question| string(question.get("title")))
                            .unwrap_or_else(|| answer.field.to_string());
                        format!("{title}\n{}", answer.values.join(", "))
                    })
                    .collect::<Vec<_>>()
                    .join("\n\n");
                self.requests.remove(interaction.as_str());
                return Ok(AnswerPlan::SendInput {
                    text,
                    events: vec![Event::InteractionClosed {
                        id: interaction.clone(),
                        by: ClosedBy::Inline {
                            user: by,
                            decision: None,
                        },
                    }],
                });
            }
            (Pending::AsyncQuestions, InteractionResponse::Cancel) => {
                self.requests.remove(interaction.as_str());
                return Ok(AnswerPlan::SendInput {
                    text: String::new(),
                    events: vec![Event::InteractionClosed {
                        id: interaction.clone(),
                        by: ClosedBy::Cancelled,
                    }],
                });
            }
            _ => {
                return Err(OpError::InvalidResponse(
                    "the response does not fit this interaction".to_owned(),
                ));
            }
        };
        self.requests.remove(interaction.as_str());
        self.answered.insert(interaction.as_str().to_owned());
        let by = if matches!(response, InteractionResponse::Cancel) {
            ClosedBy::Cancelled
        } else {
            ClosedBy::Inline {
                user: by,
                decision: decision_id,
            }
        };
        Ok(AnswerPlan::Respond {
            rpc_id: request.rpc_id,
            result,
            events: vec![Event::InteractionClosed {
                id: interaction.clone(),
                by,
            }],
            follow_up,
        })
    }

    /// Marks every pending request cancelled (connection lost, release).
    pub(crate) fn cancel_all(&mut self) -> Vec<Event> {
        let mut ids: Vec<_> = self.requests.drain().map(|(id, _)| id).collect();
        ids.sort();
        ids.into_iter()
            .filter_map(|id| InteractionId::new(id).ok())
            .map(|id| Event::InteractionClosed {
                id,
                by: ClosedBy::Cancelled,
            })
            .collect()
    }

    /// Everything still open when the app-server connection ends: pending
    /// interactions close and the running turn completes as `ConnectionLost`,
    /// since Codex can no longer report its end.
    pub(crate) fn connection_lost(&mut self) -> Vec<Event> {
        self.lost = true;
        let mut events = self.cancel_all();
        if let Some(turn) = self.active_turn.take() {
            self.last_finished_turn = Some(turn.clone());
            let consumed = self.consumed.remove(&turn).unwrap_or_default();
            events.push(connection_lost_turn(turn, consumed));
        }
        events
    }
}

fn connection_lost_turn(turn: TurnId, inputs_consumed: Vec<InputId>) -> Event {
    Event::Turn {
        turn,
        phase: TurnPhase::Completed {
            outcome: TurnOutcome::ConnectionLost,
            inputs_consumed,
            error: None,
            duration_ms: None,
        },
    }
}

fn typed_answer(kind: &str, values: &[String]) -> Value {
    let first = values.first().cloned().unwrap_or_default();
    match kind {
        "boolean" => Value::Bool(matches!(first.as_str(), "true" | "yes" | "on" | "1")),
        "number" | "integer" => first
            .parse::<f64>()
            .ok()
            .and_then(serde_json::Number::from_f64)
            .map_or(Value::String(first), Value::Number),
        "array" => Value::Array(values.iter().cloned().map(Value::String).collect()),
        _ => Value::String(first),
    }
}

fn user_input_form(params: &Value) -> Option<QuestionForm> {
    let questions = params.get("questions")?.as_array()?;
    let fields = questions
        .iter()
        .map(|question| {
            let id = FieldId::new(string(question.get("id"))?).ok()?;
            let prompt = string(question.get("question"))?;
            let secret = question.get("isSecret").and_then(Value::as_bool) == Some(true);
            let allow_other = question.get("isOther").and_then(Value::as_bool) == Some(true);
            let options: Vec<FieldOption> = question
                .get("options")
                .and_then(Value::as_array)
                .map(|options| {
                    options
                        .iter()
                        .filter_map(|option| {
                            Some(FieldOption {
                                label: string(option.get("label"))?,
                                description: string(option.get("description")),
                                preview: None,
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            let input = if secret {
                FieldInput::Secret
            } else if options.is_empty() {
                FieldInput::Text {
                    multiline: true,
                    default: None,
                }
            } else {
                FieldInput::Select {
                    options,
                    multiple: false,
                    allow_other,
                }
            };
            Some(FormField {
                id,
                header: string(question.get("header")),
                prompt,
                input,
                required: true,
            })
        })
        .collect::<Option<Vec<_>>>()?;
    if fields.is_empty() {
        return None;
    }
    Some(QuestionForm {
        title: None,
        fields,
        asynchronous: params.get("isBlocking").and_then(Value::as_bool) == Some(false),
        auto_resolution_ms: params.get("autoResolutionMs").and_then(Value::as_u64),
    })
}

/// A form that asks for nothing but a yes or no: no schema, or an object
/// schema with no properties. Codex asks to run an MCP tool this way.
fn is_message_only(params: &Value) -> bool {
    match params.get("requestedSchema") {
        None | Some(Value::Null) => true,
        Some(schema) => schema
            .get("properties")
            .and_then(Value::as_object)
            .is_some_and(Map::is_empty),
    }
}

/// Arguments a tool approval shows, at most.
const MAX_TOOL_PARAMS: usize = 12;
/// Characters of one text argument a tool approval shows.
const MAX_TOOL_PARAM_CHARS: usize = 600;
/// Items of an array, or entries of an object, inside an argument.
const MAX_TOOL_PARAM_ITEMS: usize = 8;
/// Nesting kept inside an argument; deeper values read `…`.
const MAX_TOOL_PARAM_DEPTH: usize = 3;

/// What a message-only elicitation asks. Codex's tool approval is the tool,
/// named as other agents' tool cards name it (`server · tool`), with its
/// arguments; Codex's message is kept when it says more than the generic
/// question.
fn message_only_subject(params: &Value) -> ApprovalSubject {
    let message = string(params.get("message")).map(|message| sanitized(&message, 2_000));
    let tool = params
        .pointer("/_meta/tool_title")
        .or_else(|| params.pointer("/_meta/tool_name"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|tool| !tool.is_empty());
    match tool {
        Some(tool) if decisions::is_tool_approval(params) => {
            let tool = sanitized(tool, 120);
            let name = match string(params.get("serverName")) {
                Some(server) => format!("{} · {tool}", sanitized(&server, 120)),
                None => tool.clone(),
            };
            // "Allow the x MCP server to run tool "y"?" (by the tool's raw
            // name) says nothing the card does not; a consequential tool's
            // own message does.
            let raw = params
                .pointer("/_meta/tool_name")
                .and_then(Value::as_str)
                .map(|raw| sanitized(raw, 120));
            let generic = |message: &String| {
                message.starts_with("Allow ")
                    && [Some(&tool), raw.as_ref()]
                        .into_iter()
                        .flatten()
                        .any(|name| message.ends_with(&format!("run tool \"{name}\"?")))
            };
            ApprovalSubject::Tool {
                name,
                input: tool_params(params),
                reason: message.filter(|message| !generic(message)),
            }
        }
        _ => ApprovalSubject::Other {
            title: message.unwrap_or_else(|| "Allow this request?".to_owned()),
            detail: None,
        },
    }
}

/// The arguments of an MCP tool Codex asks to run, as the Codex TUI picks
/// them (`tool_params_display` names, else `tool_params` by name), bounded
/// and with control and direction-override characters removed. Codex sends
/// the whole call; a card shows enough to decide on.
fn tool_params(params: &Value) -> Value {
    let Some(meta) = params.get("_meta") else {
        return Value::Null;
    };
    let mut rows: Vec<(String, &Value)> = meta
        .get("tool_params_display")
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter_map(|row| {
                    let name =
                        string(row.get("display_name")).or_else(|| string(row.get("name")))?;
                    Some((name, row.get("value")?))
                })
                .collect()
        })
        .unwrap_or_default();
    if rows.is_empty() {
        rows = meta
            .get("tool_params")
            .and_then(Value::as_object)
            .map(|object| {
                object
                    .iter()
                    .map(|(name, value)| (name.clone(), value))
                    .collect()
            })
            .unwrap_or_default();
        rows.sort_by(|left, right| left.0.cmp(&right.0));
    }
    if rows.is_empty() {
        return Value::Null;
    }
    let total = rows.len();
    let mut shown = Map::new();
    for (name, value) in rows.into_iter().take(MAX_TOOL_PARAMS) {
        shown.insert(sanitized(&name, 120), bounded(value, 0));
    }
    if total > MAX_TOOL_PARAMS {
        shown.insert(
            "…".to_owned(),
            json!(format!("{} more", total - MAX_TOOL_PARAMS)),
        );
    }
    Value::Object(shown)
}

fn bounded(value: &Value, depth: usize) -> Value {
    match value {
        Value::String(text) => Value::String(sanitized(text, MAX_TOOL_PARAM_CHARS)),
        Value::Array(_) | Value::Object(_) if depth >= MAX_TOOL_PARAM_DEPTH => json!("…"),
        Value::Array(items) => {
            let mut shown: Vec<Value> = items
                .iter()
                .take(MAX_TOOL_PARAM_ITEMS)
                .map(|item| bounded(item, depth + 1))
                .collect();
            if items.len() > MAX_TOOL_PARAM_ITEMS {
                shown.push(json!(format!(
                    "… {} more",
                    items.len() - MAX_TOOL_PARAM_ITEMS
                )));
            }
            Value::Array(shown)
        }
        Value::Object(object) => {
            let mut shown: Map<String, Value> = object
                .iter()
                .take(MAX_TOOL_PARAM_ITEMS)
                .map(|(key, value)| (sanitized(key, 120), bounded(value, depth + 1)))
                .collect();
            if object.len() > MAX_TOOL_PARAM_ITEMS {
                shown.insert(
                    "…".to_owned(),
                    json!(format!("{} more", object.len() - MAX_TOOL_PARAM_ITEMS)),
                );
            }
            Value::Object(shown)
        }
        other => other.clone(),
    }
}

/// `text` without control characters (newlines and tabs stay) or bidi
/// overrides that could disguise it, cut to `max` characters.
fn sanitized(text: &str, max: usize) -> String {
    let mut clean = text
        .chars()
        .filter(|character| {
            (!character.is_control() || matches!(character, '\n' | '\t'))
                && !matches!(character, '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}')
        })
        .take(max + 1)
        .collect::<String>();
    if clean.chars().count() > max {
        clean = clean.chars().take(max).collect();
        clean.push('…');
    }
    clean
}

fn elicitation_form(params: &Value) -> Option<QuestionForm> {
    let schema = params.get("requestedSchema")?;
    let required: HashSet<&str> = schema
        .get("required")
        .and_then(Value::as_array)
        .map(|required| required.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let properties = schema.get("properties")?.as_object()?;
    let mut fields = Vec::new();
    for (name, property) in properties {
        let options = enum_options(property);
        let input = match property.get("type").and_then(Value::as_str) {
            _ if !options.is_empty() => FieldInput::Select {
                options,
                multiple: property.get("type").and_then(Value::as_str) == Some("array"),
                allow_other: false,
            },
            Some("boolean") => FieldInput::Toggle {
                default: property.get("default").and_then(Value::as_bool),
            },
            Some("number" | "integer") => FieldInput::Number {
                default: property.get("default").and_then(Value::as_number).cloned(),
                min: property.get("minimum").and_then(Value::as_number).cloned(),
                max: property.get("maximum").and_then(Value::as_number).cloned(),
            },
            _ => FieldInput::Text {
                multiline: false,
                default: string(property.get("default")),
            },
        };
        fields.push(FormField {
            id: FieldId::new(name.clone()).ok()?,
            header: string(property.get("title")),
            prompt: string(property.get("description"))
                .or_else(|| string(property.get("title")))
                .unwrap_or_else(|| name.clone()),
            input,
            required: required.contains(name.as_str()),
        });
    }
    Some(QuestionForm {
        title: string(params.get("message")),
        fields,
        asynchronous: false,
        auto_resolution_ms: None,
    })
}

fn enum_options(property: &Value) -> Vec<FieldOption> {
    let from = |values: Option<&Value>, titles: Option<&Value>| -> Vec<FieldOption> {
        let titles = titles.and_then(Value::as_array);
        values
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .enumerate()
                    .filter_map(|(index, value)| {
                        Some(FieldOption {
                            label: string(Some(value))?,
                            description: titles
                                .and_then(|titles| titles.get(index))
                                .and_then(|title| string(Some(title))),
                            preview: None,
                        })
                    })
                    .collect()
            })
            .unwrap_or_default()
    };
    let direct = from(property.get("enum"), property.get("enumNames"));
    if !direct.is_empty() {
        return direct;
    }
    // Titled choices: `oneOf` for one, `items.anyOf` for several (MCP
    // 2025-11-25 `TitledSingleSelectEnumSchema` / `TitledMultiSelectEnumSchema`).
    let titled = |choices: &Vec<Value>| -> Vec<FieldOption> {
        choices
            .iter()
            .filter_map(|option| {
                Some(FieldOption {
                    label: string(option.get("const"))?,
                    description: string(option.get("title")),
                    preview: None,
                })
            })
            .collect()
    };
    for pointer in ["/oneOf", "/anyOf", "/items/anyOf", "/items/oneOf"] {
        if let Some(choices) = property.pointer(pointer).and_then(Value::as_array) {
            let options = titled(choices);
            if !options.is_empty() {
                return options;
            }
        }
    }
    from(property.pointer("/items/enum"), None)
}

/// Normalized body, status and message phase of one Codex `ThreadItem`.
pub(crate) fn item_body(item: &Value) -> (ItemBody, ItemStatus, Option<AgentMessagePhase>) {
    let kind = item.get("type").and_then(Value::as_str).unwrap_or("");
    let status = item_status(item.get("status"));
    let body = match kind {
        "userMessage" => ItemBody::Message {
            role: MessageRole::User,
            text: user_text(item.get("content")),
            input: input_from_client_id(item.get("clientId").and_then(Value::as_str)),
        },
        "hookPrompt" => ItemBody::Message {
            role: MessageRole::System,
            text: item
                .get("fragments")
                .and_then(Value::as_array)
                .map(|fragments| {
                    fragments
                        .iter()
                        .filter_map(|fragment| string(fragment.get("text")))
                        .collect::<Vec<_>>()
                        .join("\n")
                })
                .unwrap_or_default(),
            input: None,
        },
        "agentMessage" => ItemBody::Message {
            role: MessageRole::Assistant,
            text: string(item.get("text")).unwrap_or_default(),
            input: None,
        },
        "plan" => ItemBody::Plan {
            explanation: None,
            steps: Vec::new(),
            text: string(item.get("text")),
        },
        "reasoning" => ItemBody::Reasoning {
            summary: strings(item.get("summary")),
            content: strings(item.get("content")),
        },
        "commandExecution" => ItemBody::Command {
            command: command_text(item.get("command")).unwrap_or_default(),
            cwd: string(item.get("cwd")).map(PathBuf::from),
            actions: item
                .get("commandActions")
                .and_then(Value::as_array)
                .map(|actions| actions.iter().map(command_action).collect())
                .unwrap_or_default(),
            output: string(item.get("aggregatedOutput")),
            exit_code: item
                .get("exitCode")
                .and_then(Value::as_i64)
                .and_then(|code| i32::try_from(code).ok()),
            duration_ms: item.get("durationMs").and_then(Value::as_u64),
        },
        "fileChange" => ItemBody::FileChange {
            changes: file_changes(item.get("changes")),
        },
        "mcpToolCall" => ItemBody::Tool {
            name: string(item.get("tool")).unwrap_or_else(|| "tool".to_owned()),
            server: string(item.get("server")),
            input: item.get("arguments").cloned().unwrap_or(Value::Null),
            output: mcp_result_text(item.get("result")),
            error: string(item.pointer("/error/message")),
        },
        "dynamicToolCall" => ItemBody::Tool {
            name: string(item.get("tool")).unwrap_or_else(|| "tool".to_owned()),
            server: string(item.get("namespace")),
            input: item.get("arguments").cloned().unwrap_or(Value::Null),
            output: item
                .get("contentItems")
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| string(item.get("text")))
                        .collect::<Vec<_>>()
                        .join("\n")
                })
                .filter(|text| !text.is_empty()),
            error: None,
        },
        "functionCallOutput" => ItemBody::Tool {
            name: string(item.get("name")).unwrap_or_else(|| "function".to_owned()),
            server: string(item.get("namespace")),
            input: Value::Null,
            output: item
                .get("output")
                .map(|output| string(Some(output)).unwrap_or_else(|| output.to_string())),
            error: None,
        },
        "collabAgentToolCall" => {
            let child = child_refs(item).into_iter().next().unwrap_or(ChildRef {
                id: inline_agent_bridge::harness::ChildId::new(
                    string(item.get("id")).unwrap_or_else(|| "collab".to_owned()),
                )
                .expect("child id"),
                kind: ChildKind::Subagent,
            });
            ItemBody::Child {
                child,
                action: string(item.get("tool")),
                prompt: string(item.get("prompt")),
            }
        }
        "subAgentActivity" => match child_refs(item).into_iter().next() {
            Some(child) => ItemBody::Child {
                child,
                action: string(item.get("kind")),
                prompt: string(item.get("agentPath")),
            },
            None => unknown_body(kind, item),
        },
        "webSearch" => ItemBody::Tool {
            name: "web_search".to_owned(),
            server: None,
            input: json!({"query": item.get("query").cloned().unwrap_or(Value::Null)}),
            output: None,
            error: None,
        },
        "imageView" => ItemBody::Tool {
            name: "view_image".to_owned(),
            server: None,
            input: json!({"path": item.get("path").cloned().unwrap_or(Value::Null)}),
            output: None,
            error: None,
        },
        "sleep" => ItemBody::Tool {
            name: "sleep".to_owned(),
            server: None,
            input: Value::Null,
            output: None,
            error: None,
        },
        "imageGeneration" => ItemBody::Tool {
            name: "image_generation".to_owned(),
            server: None,
            input: Value::Null,
            output: string(item.get("revisedPrompt")),
            error: None,
        },
        "exitedReviewMode" => ItemBody::Review {
            text: string(item.get("review")).unwrap_or_default(),
        },
        "enteredReviewMode" => ItemBody::Message {
            role: MessageRole::System,
            text: string(item.get("review")).unwrap_or_default(),
            input: None,
        },
        "contextCompaction" => ItemBody::Usage {
            label: "Context compacted".to_owned(),
        },
        other => unknown_body(other, item),
    };
    let phase = (kind == "agentMessage")
        .then(|| match item.get("phase").and_then(Value::as_str) {
            Some("commentary") => Some(AgentMessagePhase::Commentary),
            Some("final_answer" | "finalAnswer") => Some(AgentMessagePhase::FinalAnswer),
            Some(_) => Some(AgentMessagePhase::Unknown),
            None => None,
        })
        .flatten();
    (body, status, phase)
}

fn unknown_body(kind: &str, item: &Value) -> ItemBody {
    ItemBody::Unknown {
        native_type: if kind.is_empty() {
            "unknown".to_owned()
        } else {
            kind.to_owned()
        },
        summary: string(item.get("title"))
            .or_else(|| string(item.get("text")))
            .map(|text| text.chars().take(240).collect()),
    }
}

fn item_status(status: Option<&Value>) -> ItemStatus {
    match status.and_then(Value::as_str) {
        None | Some("completed") => ItemStatus::Completed,
        Some("failed") => ItemStatus::Failed,
        Some("declined") => ItemStatus::Declined,
        Some("interrupted" | "cancelled" | "canceled") => ItemStatus::Interrupted,
        Some(_) => ItemStatus::Unknown,
    }
}

fn child_refs(item: &Value) -> Vec<ChildRef> {
    let mut threads: Vec<String> = Vec::new();
    match item.get("type").and_then(Value::as_str) {
        Some("collabAgentToolCall") => {
            threads.extend(strings(item.get("receiverThreadIds")));
        }
        Some("subAgentActivity") => {
            threads.extend(string(item.get("agentThreadId")));
        }
        _ => {}
    }
    threads
        .into_iter()
        .filter_map(|thread| {
            Some(ChildRef {
                id: inline_agent_bridge::harness::ChildId::new(thread).ok()?,
                kind: ChildKind::Subagent,
            })
        })
        .collect()
}

fn child_status_from_item(item: &Value, thread: &str, completed: bool) -> ChildStatus {
    let state = item
        .get("agentsStates")
        .and_then(|states| states.get(thread))
        .and_then(|state| state.get("status"))
        .and_then(Value::as_str);
    match state {
        Some("pendingInit" | "running") => ChildStatus::Running,
        Some("completed") => ChildStatus::Completed,
        Some("errored" | "notFound") => ChildStatus::Failed,
        Some("shutdown" | "interrupted") => ChildStatus::Stopped,
        Some(_) => ChildStatus::Unknown,
        None if completed => ChildStatus::Running,
        None => ChildStatus::Started,
    }
}

fn child_update(
    child: ChildRef,
    status: ChildStatus,
    title: Option<String>,
    native: &Value,
) -> Event {
    Event::Child {
        update: ChildUpdate {
            child,
            status,
            title,
            accepts_direct_input: false,
            native: native.clone(),
        },
    }
}

fn push_delta(
    events: &mut Vec<Event>,
    params: &Value,
    kind: ItemKind,
    stream: DeltaStream,
    index: Option<u32>,
    parent: Option<ChildRef>,
) {
    let (Some(item), Some(text)) = (
        item_id(params.get("itemId")),
        params.get("delta").and_then(Value::as_str),
    ) else {
        events.push(notice(NoticeLevel::Warning, "delta", params));
        return;
    };
    events.push(Event::Item(
        Item::new(
            item,
            turn_id(params.get("turnId")),
            ItemUpdate::Delta {
                delta: ItemDelta {
                    stream,
                    index,
                    text: text.to_owned(),
                },
            },
            Value::Null,
        )
        .with_kind(kind)
        .with_parent(parent),
    ));
}

fn index(params: &Value, key: &str) -> Option<u32> {
    params
        .get(key)
        .and_then(Value::as_u64)
        .and_then(|index| u32::try_from(index).ok())
}

fn plan_step(step: &Value) -> Option<PlanStep> {
    Some(PlanStep {
        text: string(step.get("step"))?,
        status: match step.get("status").and_then(Value::as_str) {
            Some("completed") => PlanStepStatus::Completed,
            Some("inProgress" | "in_progress") => PlanStepStatus::InProgress,
            _ => PlanStepStatus::Pending,
        },
    })
}

fn file_changes(changes: Option<&Value>) -> Vec<FileDiff> {
    changes
        .and_then(Value::as_array)
        .map(|changes| {
            changes
                .iter()
                .filter_map(|change| {
                    let path = PathBuf::from(string(change.get("path"))?);
                    let change_kind = match change.pointer("/kind/type").and_then(Value::as_str) {
                        Some("add") => FileChangeKind::Add,
                        Some("delete") => FileChangeKind::Delete,
                        _ => FileChangeKind::Update {
                            moved_to: string(change.pointer("/kind/move_path"))
                                .or_else(|| string(change.pointer("/kind/movePath")))
                                .map(PathBuf::from),
                        },
                    };
                    Some(FileDiff {
                        path,
                        change: change_kind,
                        diff: string(change.get("diff")),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

fn command_action(action: &Value) -> CommandAction {
    match action.get("type").and_then(Value::as_str) {
        Some("read") => CommandAction::Read {
            path: string(action.get("path")).unwrap_or_default(),
        },
        Some("listFiles") => CommandAction::ListFiles {
            path: string(action.get("path")),
        },
        Some("search") => CommandAction::Search {
            query: string(action.get("query")),
            path: string(action.get("path")),
        },
        _ => CommandAction::Unknown {
            command: string(action.get("command")).unwrap_or_default(),
        },
    }
}

fn mcp_result_text(result: Option<&Value>) -> Option<String> {
    let content = result?.get("content")?.as_array()?;
    let text = content
        .iter()
        .filter_map(|block| string(block.get("text")))
        .collect::<Vec<_>>()
        .join("\n");
    (!text.is_empty()).then_some(text)
}

fn user_text(content: Option<&Value>) -> String {
    content
        .and_then(Value::as_array)
        .map(|parts| {
            parts
                .iter()
                .filter_map(|part| match part.get("type").and_then(Value::as_str) {
                    Some("text") => string(part.get("text")),
                    Some("localImage" | "image") => Some("[image]".to_owned()),
                    Some("localAudio" | "audio") => Some("[audio]".to_owned()),
                    _ => None,
                })
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

fn effective_settings(settings: &Value) -> EffectiveSettings {
    EffectiveSettings {
        model: string(settings.get("model")).map(|model| DriverSettingOption {
            value: model.clone(),
            label: model,
            description: None,
            disabled: false,
        }),
        effort: string(settings.get("effort")),
        speed: string(settings.get("serviceTier")),
        permission_mode: string(settings.pointer("/activePermissionProfile/id"))
            .or_else(|| string(settings.get("approvalPolicy"))),
        mode: string(settings.pointer("/collaborationMode/mode")),
        folder: string(settings.get("cwd")).map(PathBuf::from),
    }
}

fn token_usage(value: Option<&Value>) -> Option<TokenUsage> {
    let value = value?;
    let field = |key: &str| value.get(key).and_then(Value::as_u64).unwrap_or(0);
    Some(TokenUsage {
        input: field("inputTokens"),
        cached_input: field("cachedInputTokens"),
        output: field("outputTokens"),
        reasoning: field("reasoningOutputTokens"),
        total: field("totalTokens"),
    })
}

fn permissions_summary(permissions: Option<&Value>) -> Option<String> {
    let permissions = permissions.filter(|value| !value.is_null())?;
    let mut parts = Vec::new();
    if permissions
        .pointer("/network/enabled")
        .and_then(Value::as_bool)
        == Some(true)
    {
        parts.push("network".to_owned());
    }
    let file_system = permissions.get("fileSystem");
    for (key, label) in [("read", "read"), ("write", "write")] {
        let paths = strings(file_system.and_then(|fs| fs.get(key)));
        if !paths.is_empty() {
            parts.push(format!("{label} {}", paths.join(", ")));
        }
    }
    if let Some(entries) = file_system
        .and_then(|fs| fs.get("entries"))
        .and_then(Value::as_array)
    {
        for entry in entries {
            let access = entry
                .get("access")
                .and_then(Value::as_str)
                .unwrap_or("access");
            let path = string(entry.pointer("/path/path"))
                .or_else(|| string(entry.pointer("/path/pattern")))
                .or_else(|| string(entry.pointer("/path/value")))
                .unwrap_or_else(|| entry.get("path").map(Value::to_string).unwrap_or_default());
            parts.push(format!("{access} {path}"));
        }
    }
    (!parts.is_empty()).then(|| parts.join("; "))
}

fn command_text(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(text) => Some(text.clone()),
        Value::Array(parts) => {
            let parts: Vec<String> = parts.iter().filter_map(|part| string(Some(part))).collect();
            Some(decisions::strip_bash_lc_and_escape(&parts))
        }
        _ => None,
    }
}

/// The notice for a thread's request no session took: Codex hears it was
/// refused, and the chat says so (an error notice, so it is shown, titled as
/// Claude's declined requests are). `None` for connection-level requests,
/// which name no thread.
pub(crate) fn unowned_request_notice(method: &str, params: &Value) -> Option<Event> {
    params.get("threadId").and_then(Value::as_str)?;
    Some(Event::Notice(Notice {
        level: NoticeLevel::Error,
        code: "Request declined".to_owned(),
        message: Some(format!(
            "Codex asked for `{}` from a sub-agent Inline hadn't seen yet, so it was declined.",
            sanitized(method, 80)
        )),
        native: params.clone(),
    }))
}

fn notice(level: NoticeLevel, code: &str, native: &Value) -> Event {
    Event::Notice(Notice {
        level,
        code: code.to_owned(),
        message: None,
        native: native.clone(),
    })
}

fn request_id_string(id: Option<&Value>) -> Option<String> {
    match id? {
        Value::String(id) => Some(id.clone()),
        Value::Number(id) => Some(id.to_string()),
        _ => None,
    }
}

fn turn_id(value: Option<&Value>) -> Option<TurnId> {
    TurnId::new(value?.as_str()?).ok()
}

fn item_id(value: Option<&Value>) -> Option<ItemId> {
    ItemId::new(value?.as_str()?).ok()
}

fn string(value: Option<&Value>) -> Option<String> {
    value?
        .as_str()
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

fn strings(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(|item| string(Some(item))).collect())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use inline_agent_bridge::harness::DecisionId;

    use super::*;

    #[test]
    fn decision_ids_are_answered_with_their_native_value_and_claimed_once() {
        let mut mapper = CodexMapper::new("thread-1");
        let mapped = mapper.server_request(
            &json!(7),
            "item/commandExecution/requestApproval",
            &json!({
                "threadId": "thread-1",
                "turnId": "turn-1",
                "itemId": "cmd-1",
                "command": "cargo test",
                "availableDecisions": [
                    "accept",
                    {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["cargo", "test"]}},
                    "cancel"
                ]
            }),
        );
        assert!(matches!(mapped, RequestMapped::Interaction(_)));
        let interaction = InteractionId::new("7").expect("id");
        let plan = mapper
            .answer(
                &interaction,
                &InteractionResponse::Decision {
                    decision: DecisionId::new("acceptWithExecpolicyAmendment:1").expect("id"),
                    message: None,
                },
                UserId(1),
            )
            .expect("answer");
        match plan {
            AnswerPlan::Respond { rpc_id, result, .. } => {
                assert_eq!(rpc_id, json!(7));
                assert_eq!(
                    result,
                    json!({"decision": {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["cargo", "test"]}}})
                );
            }
            other => panic!("unexpected plan {other:?}"),
        }
        assert_eq!(
            mapper.answer(&interaction, &InteractionResponse::Cancel, UserId(1)),
            Err(OpError::InteractionNotPending)
        );
        // The later resolved notification is ours; it closes nothing twice.
        let mapped = mapper.notification(
            "serverRequest/resolved",
            &json!({"threadId": "thread-1", "requestId": 7}),
        );
        assert!(mapped.events.is_empty());
    }

    /// Codex asking to run an MCP tool (codex-rs `core/src/mcp_tool_call.rs`
    /// `build_mcp_tool_approval_elicitation_request`), as app-server sends it.
    fn mcp_tool_approval(turn: Value, meta: Value) -> Value {
        let mut meta_object = json!({
            "codex_approval_kind": "mcp_tool_call",
            "persist": ["session", "always"],
            "tool_name": "execute",
            "tool_params": {"code": "async () => 1", "account": "acme"}
        });
        if let (Some(base), Some(extra)) = (meta_object.as_object_mut(), meta.as_object()) {
            base.extend(extra.clone());
        }
        json!({
            "threadId": "thread-1",
            "turnId": turn,
            "serverName": "cloudflare-api",
            "mode": "form",
            "message": "Allow the cloudflare-api MCP server to run tool \"execute\"?",
            "requestedSchema": {"type": "object", "properties": {}},
            "_meta": meta_object
        })
    }

    fn approval_of(mapped: RequestMapped) -> (ApprovalSubject, Vec<Decision>) {
        let RequestMapped::Interaction(events) = mapped else {
            panic!("expected an interaction, got {mapped:?}");
        };
        match events.into_iter().next() {
            Some(Event::Interaction(Interaction {
                kind: InteractionKind::Approval { subject, decisions },
                ..
            })) => (subject, decisions),
            other => panic!("expected an approval, got {other:?}"),
        }
    }

    fn respond(mapper: &mut CodexMapper, id: &str, decision: &str) -> Value {
        match mapper.answer(
            &InteractionId::new(id).expect("id"),
            &InteractionResponse::Decision {
                decision: DecisionId::new(decision).expect("id"),
                message: None,
            },
            UserId(1),
        ) {
            Ok(AnswerPlan::Respond { result, events, .. }) => {
                assert!(matches!(
                    events.as_slice(),
                    [Event::InteractionClosed {
                        by: ClosedBy::Inline { .. },
                        ..
                    }]
                ));
                result
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    /// Live repro (Nov 23): Codex asked to run coolify's `manage_notifications`
    /// and Inline showed only the message, with nothing to press, while
    /// Codex waited. The message-only form was a question with no fields.
    #[test]
    fn the_message_only_tool_approval_form_is_never_a_fieldless_question() {
        let mut mapper = CodexMapper::new("thread-1");
        let mapped = mapper.server_request(
            &json!(0),
            "mcpServer/elicitation/request",
            &json!({
                "threadId": "thread-1",
                "turnId": "turn-1",
                "serverName": "coolify",
                "mode": "form",
                "message": "Allow the coolify MCP server to run tool \"manage_notifications\"?",
                "requestedSchema": {"type": "object", "properties": {}},
                "_meta": {
                    "codex_approval_kind": "mcp_tool_call",
                    "persist": ["session", "always"],
                    "tool_name": "manage_notifications",
                    "tool_params": {"action": "list"}
                }
            }),
        );
        let (subject, decisions) = approval_of(mapped);
        assert_eq!(
            subject,
            ApprovalSubject::Tool {
                name: "coolify · manage_notifications".to_owned(),
                input: json!({"action": "list"}),
                reason: None,
            }
        );
        let labels: Vec<&str> = decisions.iter().map(|d| d.label.as_str()).collect();
        assert_eq!(
            labels,
            ["Allow", "Allow for this session", "Always allow", "Cancel"]
        );
        // Codex is waiting on this request until Inline answers it.
        assert_eq!(
            respond(&mut mapper, "0", "accept"),
            json!({"action": "accept", "content": null})
        );
    }

    #[test]
    fn an_mcp_tool_approval_is_a_tool_card_and_allow_answers_codex() {
        let mut mapper = CodexMapper::new("thread-1");
        let (subject, decisions) = approval_of(mapper.server_request(
            &json!(9),
            "mcpServer/elicitation/request",
            &mcp_tool_approval(json!("turn-1"), json!({})),
        ));
        assert_eq!(
            subject,
            ApprovalSubject::Tool {
                name: "cloudflare-api · execute".to_owned(),
                input: json!({"account": "acme", "code": "async () => 1"}),
                // Codex's generic question adds nothing to the card.
                reason: None,
            }
        );
        let ids: Vec<&str> = decisions.iter().map(|d| d.id.as_str()).collect();
        assert_eq!(
            ids,
            ["accept", "acceptForSession", "acceptAlways", "cancel"]
        );

        assert_eq!(
            respond(&mut mapper, "9", "accept"),
            json!({"action": "accept", "content": null})
        );
        // Claimed once: a second tap finds nothing pending.
        assert_eq!(
            mapper.answer(
                &InteractionId::new("9").expect("id"),
                &InteractionResponse::Decision {
                    decision: DecisionId::new("accept").expect("id"),
                    message: None,
                },
                UserId(1),
            ),
            Err(OpError::InteractionNotPending)
        );

        // Allow for this session asks Codex to remember it.
        mapper.server_request(
            &json!(10),
            "mcpServer/elicitation/request",
            &mcp_tool_approval(json!("turn-1"), json!({})),
        );
        assert_eq!(
            respond(&mut mapper, "10", "acceptForSession"),
            json!({"action": "accept", "content": null, "_meta": {"persist": "session"}})
        );

        // A titled tool is named by its title; the generic question still
        // names the raw tool and adds nothing.
        let (subject, _) = approval_of(mapper.server_request(
            &json!(13),
            "mcpServer/elicitation/request",
            &mcp_tool_approval(json!("turn-1"), json!({"tool_title": "Run code"})),
        ));
        assert!(matches!(
            subject,
            ApprovalSubject::Tool { ref name, reason: None, .. } if name == "cloudflare-api · Run code"
        ));
    }

    #[test]
    fn denying_an_mcp_tool_cancels_that_call_as_the_persons_choice() {
        let mut mapper = CodexMapper::new("thread-1");
        let (subject, decisions) = approval_of(
            mapper.server_request(
                &json!("e-1"),
                "mcpServer/elicitation/request",
                &mcp_tool_approval(
                    json!("turn-1"),
                    json!({
                        "persist": null,
                        "tool_title": "Send email",
                        "tool_params_display": [
                            {"name": "to", "display_name": "To", "value": "pat@example.com"},
                            {"name": "subject", "display_name": "Subject", "value": "Hi"}
                        ]
                    }),
                )
                .as_object()
                .map(|params| {
                    let mut params = params.clone();
                    params.insert(
                        "message".to_owned(),
                        json!("Allow Gmail to send an email to pat@example.com?"),
                    );
                    Value::Object(params)
                })
                .expect("object"),
            ),
        );
        // A consequential tool's own message is the reason; the display
        // names Codex rendered win over the raw arguments.
        assert_eq!(
            subject,
            ApprovalSubject::Tool {
                name: "cloudflare-api · Send email".to_owned(),
                input: json!({"To": "pat@example.com", "Subject": "Hi"}),
                reason: Some("Allow Gmail to send an email to pat@example.com?".to_owned()),
            }
        );
        let labels: Vec<&str> = decisions.iter().map(|d| d.label.as_str()).collect();
        assert_eq!(labels, ["Allow", "Cancel"]);
        assert_eq!(
            respond(&mut mapper, "e-1", "cancel"),
            json!({
                "action": "cancel",
                "content": null,
                "_meta": {"codex_approval_cancellation_reason": "user"},
            })
        );
    }

    #[test]
    fn an_unanswered_mcp_tool_card_closes_when_its_turn_ends() {
        let mut mapper = CodexMapper::new("thread-1");
        mapper.notification(
            "turn/started",
            &json!({"threadId": "thread-1", "turn": {"id": "turn-1"}}),
        );
        // app-server could not correlate the turn: the elicitation still
        // belongs to the running one.
        approval_of(mapper.server_request(
            &json!(11),
            "mcpServer/elicitation/request",
            &mcp_tool_approval(Value::Null, json!({})),
        ));
        let mapped = mapper.notification(
            "turn/completed",
            &json!({"threadId": "thread-1", "turn": {"id": "turn-1", "status": "interrupted"}}),
        );
        assert!(mapped.events.iter().any(|event| matches!(
            event,
            Event::InteractionClosed { id, by: ClosedBy::Cancelled } if id.as_str() == "11"
        )));
        // A tap on the stale card reaches nothing.
        assert_eq!(
            mapper.answer(
                &InteractionId::new("11").expect("id"),
                &InteractionResponse::Decision {
                    decision: DecisionId::new("accept").expect("id"),
                    message: None,
                },
                UserId(1),
            ),
            Err(OpError::InteractionNotPending)
        );
        // Withdrawn by Codex before anyone answered: no second close.
        let mapped = mapper.notification(
            "serverRequest/resolved",
            &json!({"threadId": "thread-1", "requestId": 11}),
        );
        assert!(mapped.events.is_empty());
    }

    #[test]
    fn a_sub_agent_asks_before_its_spawn_item_and_its_card_closes_with_its_turn() {
        let mut mapper = CodexMapper::new("thread-1");
        mapper.notification(
            "thread/started",
            &json!({"thread": {"id": "child-1", "parentThreadId": "thread-1"}}),
        );
        mapper.notification(
            "turn/started",
            &json!({"threadId": "child-1", "turn": {"id": "child-turn-1"}}),
        );
        let mut params = mcp_tool_approval(Value::Null, json!({}));
        params["threadId"] = json!("child-1");
        let RequestMapped::Interaction(events) =
            mapper.server_request(&json!(15), "mcpServer/elicitation/request", &params)
        else {
            panic!("the sub-agent's request is this session's");
        };
        assert!(matches!(
            events.first(),
            Some(Event::Interaction(Interaction { parent: Some(child), .. }))
                if child.id.as_str() == "child-1"
        ));
        let mapped = mapper.notification(
            "turn/completed",
            &json!({"threadId": "child-1", "turn": {"id": "child-turn-1", "status": "interrupted"}}),
        );
        assert!(mapped.events.iter().any(|event| matches!(
            event,
            Event::InteractionClosed { id, by: ClosedBy::Cancelled } if id.as_str() == "15"
        )));
        // Codex's later resolved notice is not "answered outside Inline".
        assert!(
            mapper
                .notification(
                    "serverRequest/resolved",
                    &json!({"threadId": "child-1", "requestId": 15}),
                )
                .events
                .is_empty()
        );
        // Someone else's thread stays someone else's.
        mapper.notification(
            "thread/started",
            &json!({"thread": {"id": "stranger", "parentThreadId": "other"}}),
        );
        assert!(!mapper.owns_thread(Some("stranger")));
    }

    #[test]
    fn a_refused_request_from_an_unknown_thread_is_said_aloud() {
        let Some(Event::Notice(notice)) = unowned_request_notice(
            "mcpServer/elicitation/request",
            &json!({"threadId": "child-9", "mode": "form"}),
        ) else {
            panic!("expected a notice");
        };
        // Errors are what the chat shows.
        assert_eq!(notice.level, NoticeLevel::Error);
        assert_eq!(notice.code, "Request declined");
        assert!(
            notice
                .message
                .as_deref()
                .is_some_and(|text| text.contains("mcpServer/elicitation/request"))
        );
        assert!(unowned_request_notice("currentTime/read", &json!({})).is_none());
    }

    #[test]
    fn tool_arguments_on_a_card_are_bounded_and_cleaned() {
        let long = "x".repeat(MAX_TOOL_PARAM_CHARS + 50);
        let mut many = Map::new();
        for index in 0..MAX_TOOL_PARAMS + 3 {
            many.insert(format!("p{index:02}"), json!(index));
        }
        many.insert("body".to_owned(), json!(long));
        many.insert(
            "evil".to_owned(),
            json!("safe\u{202E}gpj.exe\u{1b}[2J\nnext"),
        );
        many.insert(
            "deep".to_owned(),
            json!({"a": {"b": {"c": {"d": 1}}}, "list": (0..20).collect::<Vec<_>>()}),
        );
        let input = tool_params(&json!({"_meta": {"tool_params": many}}));
        let object = input.as_object().expect("object");
        assert_eq!(object.len(), MAX_TOOL_PARAMS + 1);
        assert_eq!(object["…"], json!("6 more"));
        let body = object["body"].as_str().expect("text");
        assert_eq!(body.chars().count(), MAX_TOOL_PARAM_CHARS + 1);
        assert!(body.ends_with('…'));
        assert_eq!(object["evil"], json!("safegpj.exe[2J\nnext"));
        assert_eq!(object["deep"]["a"]["b"], json!({"c": "…"}));
        let list = object["deep"]["list"].as_array().expect("list");
        assert_eq!(list.len(), MAX_TOOL_PARAM_ITEMS + 1);
        assert_eq!(list[MAX_TOOL_PARAM_ITEMS], json!("… 12 more"));
        // No arguments: nothing to show.
        assert_eq!(tool_params(&json!({"_meta": {}})), Value::Null);
    }

    #[test]
    fn a_titled_multi_select_is_a_choice_answered_with_its_values() {
        let mut mapper = CodexMapper::new("thread-1");
        let mapped = mapper.server_request(
            &json!(14),
            "mcpServer/elicitation/request",
            &json!({
                "threadId": "thread-1",
                "turnId": "turn-1",
                "serverName": "deploy",
                "mode": "form",
                "message": "Where should it deploy?",
                "requestedSchema": {"type": "object", "properties": {"regions": {
                    "type": "array",
                    "title": "Regions",
                    "items": {"anyOf": [
                        {"const": "fra", "title": "Frankfurt"},
                        {"const": "iad", "title": "Virginia"}
                    ]}
                }}}
            }),
        );
        let RequestMapped::Interaction(events) = mapped else {
            panic!("expected an interaction");
        };
        let Some(Event::Interaction(Interaction {
            kind: InteractionKind::Question { form },
            ..
        })) = events.first()
        else {
            panic!("expected a question");
        };
        let FieldInput::Select {
            options, multiple, ..
        } = &form.fields[0].input
        else {
            panic!("expected a choice, got {:?}", form.fields[0].input);
        };
        assert!(*multiple);
        let labels: Vec<(&str, Option<&str>)> = options
            .iter()
            .map(|option| (option.label.as_str(), option.description.as_deref()))
            .collect();
        assert_eq!(
            labels,
            [("fra", Some("Frankfurt")), ("iad", Some("Virginia"))]
        );
        let plan = mapper
            .answer(
                &InteractionId::new("14").expect("id"),
                &InteractionResponse::Answers {
                    answers: vec![inline_agent_bridge::harness::FieldAnswer {
                        field: FieldId::new("regions").expect("id"),
                        values: vec!["fra".to_owned(), "iad".to_owned()],
                    }],
                },
                UserId(1),
            )
            .expect("answer");
        let AnswerPlan::Respond { result, .. } = plan else {
            panic!("expected a response");
        };
        assert_eq!(
            result,
            json!({"action": "accept", "content": {"regions": ["fra", "iad"]}})
        );
    }

    #[test]
    fn a_message_only_request_that_is_not_a_tool_is_an_allow_or_deny_card() {
        let mut mapper = CodexMapper::new("thread-1");
        let (subject, decisions) = approval_of(mapper.server_request(
            &json!(12),
            "mcpServer/elicitation/request",
            &json!({
                "threadId": "thread-1",
                "turnId": "turn-1",
                "serverName": "notes",
                "mode": "form",
                "message": "Share your notes with this server?",
                "requestedSchema": {"type": "object", "properties": {}}
            }),
        ));
        assert_eq!(
            subject,
            ApprovalSubject::Other {
                title: "Share your notes with this server?".to_owned(),
                detail: None,
            }
        );
        assert_eq!(decisions.len(), 3);
        assert_eq!(
            respond(&mut mapper, "12", "decline"),
            json!({"action": "decline", "content": null})
        );
    }

    #[test]
    fn decisions_that_were_not_offered_are_rejected() {
        let mut mapper = CodexMapper::new("thread-1");
        mapper.server_request(
            &json!("r1"),
            "item/fileChange/requestApproval",
            &json!({"threadId": "thread-1", "turnId": "t", "itemId": "fc"}),
        );
        let result = mapper.answer(
            &InteractionId::new("r1").expect("id"),
            &InteractionResponse::Decision {
                decision: DecisionId::new("decline").expect("id"),
                message: None,
            },
            UserId(1),
        );
        assert!(matches!(result, Err(OpError::InvalidResponse(_))));
    }

    #[test]
    fn other_threads_are_ignored_and_unknown_requests_are_cancelled_visibly() {
        let mut mapper = CodexMapper::new("thread-1");
        assert!(
            mapper
                .notification(
                    "turn/started",
                    &json!({"threadId": "other", "turn": {"id": "x"}})
                )
                .events
                .is_empty()
        );
        match mapper.server_request(&json!(3), "future/dialog", &json!({"threadId": "thread-1"})) {
            RequestMapped::Reply { result, events } => {
                assert!(result.is_err());
                assert!(matches!(events[0], Event::Interaction(_)));
                assert!(matches!(
                    events[1],
                    Event::InteractionClosed {
                        by: ClosedBy::Cancelled,
                        ..
                    }
                ));
                assert!(matches!(events[2], Event::Notice(_)));
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn a_usage_limit_failure_waits_on_the_limit_until_it_resets() {
        let mut mapper = CodexMapper::new("thread-1");
        mapper.notification(
            "account/rateLimits/updated",
            &json!({"rateLimits": {"limitId": "codex",
                "primary": {"usedPercent": 100, "windowDurationMins": 300, "resetsAt": 1_800_000_000},
                "secondary": {"usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1_900_000_000}}}),
        );
        let mapped = mapper.notification(
            "turn/completed",
            &json!({"threadId": "thread-1", "turn": {"id": "turn-1", "status": "failed",
                "error": {"message": "You've hit your usage limit.", "codexErrorInfo": "usageLimitExceeded"}}}),
        );
        assert!(mapped.events.iter().any(|event| matches!(
            event,
            Event::State {
                state: RunState::Waiting {
                    on: WaitingOn::Limit {
                        resets_at: Some(1_800_000_000)
                    }
                }
            }
        )));
        // Any other failure is just a failure.
        let mapped = mapper.notification(
            "turn/completed",
            &json!({"threadId": "thread-1", "turn": {"id": "turn-2", "status": "failed",
                "error": {"message": "boom", "codexErrorInfo": "internalServerError"}}}),
        );
        assert!(
            !mapped
                .events
                .iter()
                .any(|event| matches!(event, Event::State { .. }))
        );
    }

    #[test]
    fn a_resumed_thread_reports_the_inline_inputs_it_consumed() {
        let mut mapper = CodexMapper::new("thread-1");
        let input = InputId::new("in-7").unwrap();
        let response = json!({"thread": {"turns": [{"id": "turn-1", "status": "completed",
            "items": [{"type": "userMessage", "id": "u1", "clientId": client_message_id(&input),
                "content": [{"type": "text", "text": "hi"}]},
                {"type": "userMessage", "id": "u2", "content": []}]}]}});
        let events = mapper.restore_inputs(&response);
        assert_eq!(
            events,
            vec![Event::Input {
                id: input,
                fact: InputFact::Consumed {
                    turn: TurnId::new("turn-1").unwrap()
                }
            }]
        );
        // Reported once.
        assert!(mapper.restore_inputs(&response).is_empty());
    }
}

#[cfg(test)]
mod recovery_history_tests {
    use super::*;

    #[test]
    fn consumed_input_before_twenty_recent_turns_is_restored() {
        let mut mapper = CodexMapper::new("review-thread");
        let input = InputId::new("already-consumed").unwrap();
        let mut turns = vec![
            json!({"id":"turn-0", "status":"completed", "items":[{"type":"userMessage", "id":"u1", "clientId":client_message_id(&input), "content":[]} ]}),
        ];
        for n in 1..=20 {
            turns.push(json!({"id":format!("turn-{n}"), "status":"completed", "items":[]}));
        }
        assert!(
            !mapper
                .restore_inputs(&json!({"thread":{"turns":turns}}))
                .is_empty()
        );
    }
}
