//! One OpenCode session held by this bridge.
//!
//! | Delivery | OpenCode |
//! | --- | --- |
//! | `Turn` | `POST /prompt` (steer; starts an execution when idle) |
//! | `Steer` | `POST /prompt {delivery: "steer"}`: taken at the next step boundary |
//! | `Queue` | `POST /prompt {delivery: "queue"}`: taken when the model finishes, in the same execution |
//! | `Passive` | `POST /synthetic {resume: false}`: context the agent reads with its next step |
//!
//! Every prompt carries an id Inline chose (`msg_…`, OpenCode's own format)
//! and the input id in its metadata. OpenCode admits an id once, so a send
//! whose response was lost is retried with the same id without running twice.
//!
//! The service is shared: the owner's terminal can watch and drive the same
//! session at the same time. Nothing here is exclusive, and releasing a
//! session only stops this bridge from following it.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, Weak};

use inline_agent_bridge::harness::{
    Availability, AvailabilityMatrix, ClosedBy, Delivery, DeliveryKind, Event, EventHub,
    EventStream, HarnessFuture, Input, InputDisposition, InputReceipt, InteractionResponse,
    LiveWork, Op, OpError, OpKind, OpOutcome, QueueEntryId, QueueOp, ReleaseOutcome, Released,
    RewindPoint, RunStateTracker, SendError, Session, SessionKey, SettingsScope,
};
use inline_agent_bridge::{DriverError, InputAttachmentKind, TurnId};
use reqwest::Method;
use serde_json::{Value, json};
use tokio::sync::mpsc;

use crate::api::{Api, ApiError, Query, data};
use crate::events::{BusMessage, EventBus};
use crate::harness::Shared;
use crate::link::Link;
use crate::mapper::{INPUT_METADATA_KEY, Mapper, PendingKind};

const MAX_ATTACHMENT_BYTES: u64 = 20 * 1024 * 1024;
/// A side call waits on the model; the default request timeout is too short.
const GENERATE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(180);

fn ids(items: &[Value]) -> std::collections::HashSet<String> {
    items
        .iter()
        .filter_map(|item| item.get("id").and_then(Value::as_str).map(str::to_owned))
        .collect()
}

pub(crate) struct SessionInner {
    pub(crate) key: SessionKey,
    pub(crate) id: String,
    pub(crate) folder: PathBuf,
    link: Arc<Link>,
    bus: Arc<EventBus>,
    hub: EventHub,
    state: Mutex<SessionState>,
    harness: Weak<Shared>,
    /// This handle's event-bus registration.
    generation: std::sync::atomic::AtomicU64,
}

pub(crate) struct SessionState {
    pub(crate) mapper: Mapper,
    tracker: RunStateTracker,
    released: bool,
}

/// The session handle the bridge holds.
pub(crate) struct OpenCodeSession {
    pub(crate) inner: Arc<SessionInner>,
}

impl Drop for OpenCodeSession {
    fn drop(&mut self) {
        // The handle is the bridge's hold: dropping it stops following.
        self.inner.detach();
    }
}

impl SessionInner {
    pub(crate) fn new(
        key: SessionKey,
        folder: PathBuf,
        link: Arc<Link>,
        bus: Arc<EventBus>,
        harness: Weak<Shared>,
    ) -> Arc<Self> {
        let id = key.session.as_str().to_owned();
        Arc::new(Self {
            hub: EventHub::new(
                key.clone(),
                inline_agent_bridge::harness::DEFAULT_HUB_CAPACITY,
            ),
            state: Mutex::new(SessionState {
                mapper: Mapper::new(id.clone(), Some(folder.clone())),
                tracker: RunStateTracker::new(inline_agent_bridge::harness::RunState::Idle),
                released: false,
            }),
            key,
            id,
            folder,
            link,
            bus,
            harness,
            generation: std::sync::atomic::AtomicU64::new(0),
        })
    }

    pub(crate) fn state(&self) -> std::sync::MutexGuard<'_, SessionState> {
        self.state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    fn api(&self) -> Api {
        self.link.api()
    }

    pub(crate) fn bus(&self) -> Arc<EventBus> {
        self.bus.clone()
    }

    fn path(&self, rest: &str) -> String {
        format!("api/session/{}{rest}", self.id)
    }

    /// Emits events in order, keeping the run state current.
    pub(crate) fn emit_locked(&self, state: &mut SessionState, events: Vec<Event>) {
        for event in events {
            state.tracker.apply(&event);
            self.hub.emit(event);
        }
    }

    /// Applies one native event.
    pub(crate) fn apply(&self, event: &Value) {
        let mut state = self.state();
        if state.released {
            return;
        }
        let events = state.mapper.apply(event);
        self.emit_locked(&mut state, events);
    }

    /// Follows the bus until released.
    pub(crate) fn follow(
        self: &Arc<Self>,
        (mut receiver, generation): (mpsc::UnboundedReceiver<BusMessage>, u64),
    ) {
        self.generation
            .store(generation, std::sync::atomic::Ordering::Release);
        let weak = Arc::downgrade(self);
        tokio::spawn(async move {
            while let Some(message) = receiver.recv().await {
                let Some(inner) = weak.upgrade() else { return };
                match message {
                    BusMessage::Event(event) => inner.apply(&event),
                    BusMessage::Resync => inner.resync().await,
                    BusMessage::Disconnected => {}
                }
            }
        });
    }

    /// Repairs after events may have been lost: replays the durable log of
    /// the session and its sub-agents after what was last seen, and re-reads
    /// what is not durable (pending approvals and questions).
    pub(crate) async fn resync(&self) {
        let after = self.state().mapper.replay_after();
        self.replay(&self.id, after).await;
        self.resync_children().await;
        self.refresh_interactions().await;
    }

    async fn replay(&self, session: &str, after: Option<u64>) {
        let query = Query::new().maybe("after", after).with("follow", false);
        match self
            .api()
            .sse(&format!("api/experimental/session/{session}/log"), query)
            .await
        {
            Ok(stream) => {
                let mut stream = Box::pin(stream);
                while let Some(item) = futures_util::StreamExt::next(&mut stream).await {
                    match item {
                        Ok(event)
                            if event.get("type").and_then(Value::as_str) == Some("log.synced") =>
                        {
                            break;
                        }
                        Ok(event) => self.apply(&event),
                        Err(error) => {
                            log::warn!(target: "inline::opencode", "log replay for {session} failed: {error}");
                            break;
                        }
                    }
                }
            }
            Err(error) => {
                log::warn!(target: "inline::opencode", "log replay for {session} unavailable: {error}");
            }
        }
    }

    /// Finds sub-agents started while the stream was down, replays the ones
    /// that run or are new, and ends the ones that stopped meanwhile.
    async fn resync_children(&self) {
        let api = self.api();
        let active = api
            .get("api/session/active", Query::new())
            .await
            .map(data)
            .ok();
        let mut parents = vec![self.id.clone()];
        let mut seen = 0;
        while let Some(parent) = parents.pop() {
            // Sub-agents nest a few levels at most.
            seen += 1;
            if seen > 32 {
                break;
            }
            let Ok(children) = api
                .get(
                    "api/session",
                    Query::new().with("parentID", &parent).with("limit", 50),
                )
                .await
            else {
                continue;
            };
            for child in data(children).as_array().cloned().unwrap_or_default() {
                let Some(id) = child.get("id").and_then(Value::as_str).map(str::to_owned) else {
                    continue;
                };
                let running = active
                    .as_ref()
                    .is_some_and(|active| active.get(&id).is_some());
                self.bus.link_child(&id, &parent);
                let (new, after, was_running) = {
                    let mut state = self.state();
                    let known_running = state
                        .mapper
                        .children()
                        .iter()
                        .any(|(session, running)| *session == id && *running);
                    let new = state.mapper.adopt_child(
                        &id,
                        child
                            .get("title")
                            .and_then(Value::as_str)
                            .map(str::to_owned),
                        running,
                    );
                    (new, state.mapper.child_seq(&id), known_running)
                };
                if new || was_running || running {
                    self.replay(&id, after).await;
                }
                if !running && active.is_some() {
                    let mut state = self.state();
                    let events = state.mapper.child_idle(&id);
                    self.emit_locked(&mut state, events);
                }
                parents.push(id);
            }
        }
    }

    /// Reconciles pending permissions and forms with the service, for the
    /// session and its running sub-agents. Each kind is reconciled only
    /// when its own listing succeeded.
    pub(crate) async fn refresh_interactions(&self) {
        let mut sessions = vec![self.id.clone()];
        sessions.extend(
            self.state()
                .mapper
                .children()
                .into_iter()
                .filter(|(_, running)| *running)
                .map(|(session, _)| session),
        );
        let api = self.api();
        for session in sessions {
            let base = format!("api/session/{session}");
            let (permission_path, form_path) =
                (format!("{base}/permission"), format!("{base}/form"));
            let (permissions, forms) = tokio::join!(
                api.get(&permission_path, Query::new()),
                api.get(&form_path, Query::new()),
            );
            let permissions = permissions.ok().map(|value| {
                let requests = data(value).as_array().cloned().unwrap_or_default();
                for request in &requests {
                    let mut request = request.clone();
                    if request.get("sessionID").is_none() {
                        request["sessionID"] = json!(session);
                    }
                    self.apply(&json!({"type": "permission.asked", "data": request}));
                }
                ids(&requests)
            });
            let forms = forms.ok().map(|value| {
                let forms = data(value).as_array().cloned().unwrap_or_default();
                for form in &forms {
                    let mut form = form.clone();
                    if form.get("sessionID").is_none() {
                        form["sessionID"] = json!(session);
                    }
                    self.apply(&json!({"type": "form.created", "data": {"form": form}}));
                }
                ids(&forms)
            });
            // Answered or withdrawn while the stream was down.
            let mut state = self.state();
            let stale: Vec<String> = state
                .mapper
                .pending_ids()
                .into_iter()
                .map(|id| id.as_str().to_owned())
                .filter(|id| {
                    state.mapper.pending(id).is_some_and(|pending| {
                        pending.session == session
                            && pending.answering.is_none()
                            && match pending.kind {
                                PendingKind::Permission => {
                                    permissions.as_ref().is_some_and(|live| !live.contains(id))
                                }
                                PendingKind::Form { .. } => {
                                    forms.as_ref().is_some_and(|live| !live.contains(id))
                                }
                            }
                    })
                })
                .collect();
            let events: Vec<Event> = stale
                .iter()
                .filter_map(|id| state.mapper.close(id, ClosedBy::External))
                .collect();
            self.emit_locked(&mut state, events);
        }
    }

    fn detach(&self) {
        let mut state = self.state();
        if !state.released {
            state.released = true;
            self.bus.unregister(
                &self.id,
                self.generation.load(std::sync::atomic::Ordering::Acquire),
            );
            if let Some(harness) = self.harness.upgrade() {
                harness.forget(&self.id, self);
            }
        }
    }

    pub(crate) fn binding(&self, session: &str) -> Option<(String, Option<TurnId>)> {
        let state = self.state();
        if state.released {
            return None;
        }
        let turn = state.mapper.turn().cloned();
        if session == self.id || state.mapper.child_session_known(session) {
            return Some((self.id.clone(), turn));
        }
        None
    }

    async fn post_prompt(&self, path: &str, body: Value) -> Result<Option<Value>, ApiError> {
        post_idempotent(&self.api(), path, body).await
    }
}

impl Session for OpenCodeSession {
    fn key(&self) -> &SessionKey {
        &self.inner.key
    }

    fn availability(&self) -> AvailabilityMatrix {
        availability()
    }

    fn events(&self) -> EventStream {
        self.inner.hub.subscribe()
    }

    fn send<'a>(&'a self, input: Input) -> HarnessFuture<'a, InputReceipt, SendError> {
        Box::pin(async move {
            let inner = &self.inner;
            let message_id = crate::ids::message_id();
            {
                let mut state = inner.state();
                if state.released {
                    return Err(SendError::Driver(DriverError::Unavailable(
                        "the session was released".to_owned(),
                    )));
                }
                let active = state.mapper.turn().cloned();
                match (&input.delivery, &active) {
                    (Delivery::Turn, Some(active)) => {
                        return Err(SendError::Busy {
                            active: active.clone(),
                        });
                    }
                    (Delivery::Steer { expected_turn, .. }, active)
                        if active.as_ref() != Some(expected_turn) =>
                    {
                        return Err(SendError::TurnMismatch {
                            active: active.clone(),
                        });
                    }
                    _ => {}
                }
                state.mapper.expect(&message_id, input.id.clone());
            }
            // An advertised OpenCode command runs through `/command`, which
            // expands its template and prompts with an id of its own.
            let command = slash_command(&input.content.text)
                .map(|(name, arguments)| (name.to_owned(), arguments.to_owned()));
            if let Some((name, arguments)) = command
                && !matches!(input.delivery, Delivery::Passive)
                && let Some(harness) = inner.harness.upgrade()
                && harness.has_command(&inner.folder, &name).await
            {
                inner.state().mapper.forget(&message_id);
                return inner.send_command(input, name, arguments).await;
            }
            let text = prompt_text(&input);
            let (path, body) = match &input.delivery {
                Delivery::Passive => (
                    inner.path("/synthetic"),
                    json!({
                        "id": message_id,
                        "text": text,
                        "description": "Inline conversation",
                        "metadata": {INPUT_METADATA_KEY: input.id.as_str()},
                        "delivery": "steer",
                        "resume": false,
                    }),
                ),
                delivery => (
                    inner.path("/prompt"),
                    json!({
                        "id": message_id,
                        "text": text,
                        "files": files(&input),
                        "metadata": {INPUT_METADATA_KEY: input.id.as_str()},
                        "delivery": if matches!(delivery, Delivery::Queue) { "queue" } else { "steer" },
                    }),
                ),
            };
            let result = inner.post_prompt(&path, body).await;
            let native = match result {
                Ok(native) => native.map(data).unwrap_or(Value::Null),
                Err(error) => {
                    if error.outcome_unknown() {
                        return Err(SendError::Unknown(error.to_string()));
                    }
                    inner.state().mapper.forget(&message_id);
                    return Err(match error.status() {
                        Some(404) => {
                            SendError::Rejected("the OpenCode session no longer exists".to_owned())
                        }
                        _ => SendError::Rejected(error.to_string()),
                    });
                }
            };
            let turn = || {
                TurnId::new(message_id.as_str())
                    .map_err(|error| SendError::Driver(DriverError::Protocol(error.to_string())))
            };
            let disposition = match &input.delivery {
                Delivery::Turn => InputDisposition::Started { turn: turn()? },
                Delivery::Steer { expected_turn, .. } => InputDisposition::Steered {
                    turn: expected_turn.clone(),
                },
                Delivery::Queue => InputDisposition::Queued {
                    entry: QueueEntryId::new(message_id.as_str()).ok(),
                },
                Delivery::Passive => InputDisposition::Absorbed,
            };
            Ok(InputReceipt {
                input: input.id,
                disposition,
                native,
                acceptance: inline_agent_bridge::harness::Acceptance::Accepted,
            })
        })
    }

    fn control<'a>(&'a self, op: Op) -> HarnessFuture<'a, OpOutcome, OpError> {
        Box::pin(async move { self.inner.control(op).await })
    }

    fn live_work(&self) -> LiveWork {
        let state = self.inner.state();
        LiveWork {
            turn: state.mapper.turn().cloned(),
            children: state.mapper.running_children(),
            interactions: state.mapper.pending_ids(),
            queued: state.mapper.queue(),
            wakeups: Vec::new(),
        }
    }

    fn release<'a>(&'a self) -> HarnessFuture<'a, Released, OpError> {
        Box::pin(async move {
            let pending_inputs = self
                .inner
                .state()
                .mapper
                .queue()
                .into_iter()
                .filter_map(|queued| queued.input)
                .collect();
            self.inner.detach();
            Ok(Released {
                key: self.inner.key.clone(),
                // Nothing is held natively: the shared service keeps the
                // session open to every client.
                outcome: ReleaseOutcome::NativeReleased,
                cancelled_interactions: Vec::new(),
                pending_inputs,
                stopped_children: Vec::new(),
            })
        })
    }
}

impl SessionInner {
    async fn send_command(
        &self,
        input: Input,
        name: String,
        arguments: String,
    ) -> Result<InputReceipt, SendError> {
        let delivery = match &input.delivery {
            Delivery::Queue => "queue",
            _ => "steer",
        };
        self.state().mapper.expect_command(input.id.clone());
        let result = self
            .api()
            .post(
                &self.path("/command"),
                json!({"name": name, "text": arguments, "files": files(&input), "delivery": delivery}),
            )
            .await;
        if let Err(error) = result {
            self.state().mapper.forget_command(&input.id);
            // A command is not idempotent: never retried.
            return Err(if error.outcome_unknown() {
                SendError::Unknown(error.to_string())
            } else {
                SendError::Rejected(error.to_string())
            });
        }
        // The prompt it made is already on its way through the stream.
        let mut inbox = None;
        for _ in 0..120 {
            if let Some(found) = self.state().mapper.inbox_of(&input.id).cloned() {
                inbox = Some(found);
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        }
        let Some(inbox) = inbox else {
            // Not every command prompts; never let this one claim a later
            // prompt from another client.
            self.state().mapper.forget_command(&input.id);
            return Ok(InputReceipt {
                input: input.id,
                disposition: InputDisposition::Queued { entry: None },
                native: Value::Null,
                acceptance: inline_agent_bridge::harness::Acceptance::Written,
            });
        };
        let disposition = match &input.delivery {
            Delivery::Turn => InputDisposition::Started {
                turn: TurnId::new(inbox.as_str())
                    .map_err(|error| SendError::Driver(DriverError::Protocol(error.to_string())))?,
            },
            Delivery::Steer { expected_turn, .. } => InputDisposition::Steered {
                turn: expected_turn.clone(),
            },
            _ => InputDisposition::Queued {
                entry: QueueEntryId::new(inbox.as_str()).ok(),
            },
        };
        Ok(InputReceipt {
            input: input.id,
            disposition,
            native: json!({"command": name}),
            acceptance: inline_agent_bridge::harness::Acceptance::Accepted,
        })
    }

    async fn control(&self, op: Op) -> Result<OpOutcome, OpError> {
        let availability = availability().op(op.kind());
        if !availability.is_supported() {
            return Err(OpError::Unavailable(availability));
        }
        let api = self.api();
        match op {
            Op::Interrupt { cancel_queued } => {
                {
                    let mut state = self.state();
                    state.mapper.stopping();
                    state.tracker.stopping();
                }
                if cancel_queued {
                    let pending = self.state().mapper.pending_inbox();
                    for entry in pending {
                        let _ = api
                            .send(
                                Method::DELETE,
                                &self.path(&format!("/inbox/{entry}")),
                                Query::new(),
                                None,
                            )
                            .await;
                    }
                }
                let native = api
                    .send(Method::POST, &self.path("/interrupt"), Query::new(), None)
                    .await
                    .map_err(op_error)?
                    .unwrap_or_default();
                // Nothing ran: a turn this bridge still shows was lost.
                if native.get("interrupted").and_then(Value::as_bool) == Some(false) {
                    let mut state = self.state();
                    let events = state
                        .mapper
                        .abandon_turn(inline_agent_bridge::TurnOutcome::Interrupted);
                    self.emit_locked(&mut state, events);
                }
                Ok(OpOutcome::Accepted { native })
            }
            Op::Queue { action } => match action {
                QueueOp::Remove { entry } => {
                    // OpenCode answers 204 for an entry that already ran.
                    let queued = self
                        .state()
                        .mapper
                        .pending_inbox()
                        .iter()
                        .any(|pending| pending == entry.as_str());
                    if !queued {
                        return Err(OpError::NotQueued);
                    }
                    match api
                        .send(
                            Method::DELETE,
                            &self.path(&format!("/inbox/{}", entry.as_str())),
                            Query::new(),
                            None,
                        )
                        .await
                    {
                        Ok(_) => Ok(OpOutcome::accepted()),
                        Err(error) if error.is_not_found() || error.is_conflict() => {
                            Err(OpError::NotQueued)
                        }
                        Err(error) => Err(op_error(error)),
                    }
                }
                QueueOp::Clear => {
                    let entries = self.state().mapper.queue();
                    for entry in entries {
                        let _ = api
                            .send(
                                Method::DELETE,
                                &self.path(&format!("/inbox/{}", entry.entry.as_str())),
                                Query::new(),
                                None,
                            )
                            .await;
                    }
                    Ok(OpOutcome::accepted())
                }
                QueueOp::Start | QueueOp::Reorder { .. } => {
                    unreachable!("filtered by availability")
                }
            },
            Op::Settings { change, scope } => {
                if scope != SettingsScope::Thread {
                    return Err(OpError::Unavailable(availability_for_scope(scope)));
                }
                if change.folder.is_some() {
                    return Err(OpError::Unavailable(Availability::unavailable(
                        "an OpenCode session keeps its folder; start new work to change it",
                    )));
                }
                if change.speed.is_some() {
                    return Err(OpError::Unavailable(Availability::unavailable(
                        "OpenCode has no speed setting",
                    )));
                }
                let mut native = Vec::new();
                if change.model.is_some() || change.effort.is_some() {
                    let current = self
                        .state()
                        .mapper
                        .settings()
                        .model
                        .as_ref()
                        .map(|model| model.value.clone());
                    let model = change.model.clone().or(current).ok_or_else(|| {
                        OpError::Rejected("choose a model before its reasoning level".to_owned())
                    })?;
                    let reference = crate::catalog::model_ref(&model, change.effort.as_deref())
                        .ok_or_else(|| {
                            OpError::Rejected(format!("{model} is not an OpenCode model"))
                        })?;
                    api.post(&self.path("/model"), json!({"model": reference}))
                        .await
                        .map_err(op_error)?;
                    if let Some(harness) = self.harness.upgrade() {
                        let window = harness.context_window(&self.folder, &model).await;
                        self.state().mapper.set_context_window(window);
                    }
                    native.push(json!({"model": model}));
                }
                if let Some(mode) = &change.permission_mode {
                    let rules = crate::catalog::permission_rules(mode).ok_or_else(|| {
                        OpError::Rejected(format!("unknown permission mode {mode}"))
                    })?;
                    api.send(
                        Method::PATCH,
                        &self.path(""),
                        Query::new(),
                        Some(json!({"permissions": rules})),
                    )
                    .await
                    .map_err(op_error)?;
                    let mut state = self.state();
                    let event = state.mapper.set_permission_mode(mode.clone());
                    self.emit_locked(&mut state, vec![event]);
                    native.push(json!({"permission_mode": mode}));
                }
                Ok(OpOutcome::Accepted {
                    native: json!(native),
                })
            }
            Op::Compact => {
                let id = crate::ids::message_id();
                let native = api
                    .post(&self.path("/compact"), json!({"id": id}))
                    .await
                    .map_err(op_error)?
                    .map(data)
                    .unwrap_or_default();
                Ok(OpOutcome::Accepted { native })
            }
            Op::Rename { title } => {
                api.send(
                    Method::PATCH,
                    &self.path(""),
                    Query::new(),
                    Some(json!({"title": title})),
                )
                .await
                .map_err(op_error)?;
                Ok(OpOutcome::accepted())
            }
            Op::Archive | Op::Unarchive => {
                let archived = matches!(op, Op::Archive);
                api.send(
                    Method::PATCH,
                    &self.path(""),
                    Query::new(),
                    Some(json!({"archived": archived})),
                )
                .await
                .map_err(op_error)?;
                Ok(OpOutcome::accepted())
            }
            Op::RewindFiles { to } => {
                let message = {
                    let state = self.state();
                    match &to {
                        RewindPoint::Input { input } => state.mapper.inbox_of(input).cloned(),
                        RewindPoint::Item { item } => Some(item.as_str().to_owned()),
                        RewindPoint::Turn { turn } => Some(turn.as_str().to_owned()),
                    }
                }
                .filter(|id| crate::ids::is_message_id(id))
                .ok_or_else(|| {
                    OpError::Rejected(
                        "OpenCode can only undo back to one of its messages".to_owned(),
                    )
                })?;
                let native = api
                    .post(
                        &self.path("/revert/stage"),
                        json!({"messageID": message, "files": true}),
                    )
                    .await
                    .map_err(|error| {
                        if error.is_busy() {
                            OpError::Rejected(
                                "wait for OpenCode to finish before undoing".to_owned(),
                            )
                        } else {
                            op_error(error)
                        }
                    })?
                    .map(data)
                    .unwrap_or_default();
                Ok(OpOutcome::Accepted { native })
            }
            Op::Mode { mode } => {
                api.post(&self.path("/agent"), json!({"agent": mode.as_str()}))
                    .await
                    .map_err(op_error)?;
                Ok(OpOutcome::accepted())
            }
            Op::StopChild { child } => {
                let session = self
                    .state()
                    .mapper
                    .child_session(&child)
                    .unwrap_or_else(|| child.id.as_str().to_owned());
                let native = api
                    .send(
                        Method::POST,
                        &format!("api/session/{session}/interrupt"),
                        Query::new(),
                        None,
                    )
                    .await
                    .map_err(op_error)?
                    .unwrap_or_default();
                Ok(OpOutcome::Accepted { native })
            }
            Op::Answer {
                interaction,
                response,
                by,
            } => self.answer(&api, interaction.as_str(), response, by).await,
            Op::Sample { prompt } => {
                let reply = api
                    .post_with_timeout(
                        &self.path("/generate"),
                        json!({"prompt": prompt}),
                        GENERATE_TIMEOUT,
                    )
                    .await
                    .map_err(op_error)?
                    .map(data)
                    .unwrap_or_default();
                Ok(OpOutcome::Sampled {
                    text: reply
                        .get("text")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned(),
                })
            }
            Op::Clear | Op::Review { .. } | Op::Goal { .. } | Op::McpAuth { .. } => {
                unreachable!("filtered by availability")
            }
        }
    }

    async fn answer(
        &self,
        api: &Api,
        interaction: &str,
        response: InteractionResponse,
        by: inline_agent_bridge::harness::UserId,
    ) -> Result<OpOutcome, OpError> {
        let pending = self
            .state()
            .mapper
            .pending(interaction)
            .cloned()
            .ok_or(OpError::InteractionNotPending)?;
        let base = format!("api/session/{}", pending.session);
        // OpenCode announces the reply before the request returns; the close
        // that announcement causes is Inline's.
        let attributed = match &response {
            InteractionResponse::Decision { decision, .. } => Some(decision.clone()),
            _ => None,
        };
        self.state().mapper.answering(interaction, by, attributed);
        let (result, decision) = match (&pending.kind, response) {
            (PendingKind::Permission, InteractionResponse::Decision { decision, message }) => {
                let (native, message) = match decision.as_str() {
                    "once" | "always" => (decision.as_str(), None),
                    // A reason lets the model continue; without one OpenCode
                    // stops the step, which is what "Reject and stop" means.
                    "reject" => (
                        "reject",
                        Some(message.filter(|text| !text.trim().is_empty()).unwrap_or_else(|| {
                            "The user rejected this. Do not retry it; continue another way or ask.".to_owned()
                        })),
                    ),
                    "stop" => ("reject", None),
                    other => {
                        self.state().mapper.not_answering(interaction);
                        return Err(OpError::InvalidResponse(format!("unknown decision {other}")));
                    }
                };
                let mut body = json!({"decision": native});
                if let Some(message) = message {
                    body["message"] = json!(message);
                }
                if decision.as_str() == "stop" {
                    self.state().mapper.stopping();
                }
                (
                    api.post(&format!("{base}/permission/{interaction}/reply"), body)
                        .await,
                    Some(decision),
                )
            }
            (PendingKind::Permission, InteractionResponse::Cancel) => {
                self.state().mapper.stopping();
                (
                    api.post(
                        &format!("{base}/permission/{interaction}/reply"),
                        json!({"decision": "reject"}),
                    )
                    .await,
                    None,
                )
            }
            (PendingKind::Form { fields }, InteractionResponse::Answers { answers }) => {
                let answer = match crate::mapper::form_answer(fields, &answers) {
                    Ok(answer) => answer,
                    Err(error) => {
                        self.state().mapper.not_answering(interaction);
                        return Err(OpError::InvalidResponse(error));
                    }
                };
                (
                    api.post(
                        &format!("{base}/form/{interaction}/reply"),
                        json!({"answer": answer}),
                    )
                    .await,
                    None,
                )
            }
            (PendingKind::Form { .. }, InteractionResponse::Cancel) => (
                api.send(
                    Method::DELETE,
                    &format!("{base}/form/{interaction}"),
                    Query::new().with("message", "The user dismissed the question."),
                    None,
                )
                .await,
                None,
            ),
            (_, other) => {
                self.state().mapper.not_answering(interaction);
                return Err(OpError::InvalidResponse(format!(
                    "this interaction does not take {other:?}"
                )));
            }
        };
        match result {
            Ok(native) => {
                let mut state = self.state();
                let events: Vec<Event> = state
                    .mapper
                    .close(interaction, ClosedBy::Inline { user: by, decision })
                    .into_iter()
                    .collect();
                self.emit_locked(&mut state, events);
                Ok(OpOutcome::Accepted {
                    native: native.unwrap_or_default(),
                })
            }
            Err(error) if error.is_not_found() || error.is_conflict() => {
                let mut state = self.state();
                let events: Vec<Event> = state
                    .mapper
                    .close(interaction, ClosedBy::External)
                    .into_iter()
                    .collect();
                self.emit_locked(&mut state, events);
                Err(OpError::InteractionNotPending)
            }
            Err(error) => {
                self.state().mapper.not_answering(interaction);
                Err(op_error(error))
            }
        }
    }
}

/// Posts a prompt whose `msg_` id OpenCode admits once: a send whose
/// response was lost in transport is retried once with the same id.
async fn post_idempotent(api: &Api, path: &str, body: Value) -> Result<Option<Value>, ApiError> {
    match api.post(path, body.clone()).await {
        Err(error @ ApiError::Transport(_)) => {
            log::debug!(target: "inline::opencode", "prompt send failed, retrying once: {error}");
            api.post(path, body).await
        }
        other => other,
    }
}

fn op_error(error: ApiError) -> OpError {
    if error.outcome_unknown() {
        OpError::Unknown(error.to_string())
    } else {
        OpError::Rejected(error.to_string())
    }
}

fn availability_for_scope(scope: SettingsScope) -> Availability {
    match scope {
        SettingsScope::Turn => {
            Availability::unavailable("OpenCode settings apply from the next message on")
        }
        SettingsScope::Persisted => Availability::unavailable("defaults are set in Agent Settings"),
        SettingsScope::Thread => Availability::Supported,
    }
}

/// What a native OpenCode session can do.
pub fn availability() -> AvailabilityMatrix {
    let mut matrix = AvailabilityMatrix::default();
    for kind in DeliveryKind::ALL {
        matrix = matrix.with_delivery(kind, Availability::Supported);
    }
    let unavailable = Availability::unavailable;
    matrix
        .with_op(OpKind::Interrupt, Availability::Supported)
        .with_op(OpKind::InterruptCancelQueued, Availability::Supported)
        .with_op(
            OpKind::QueueStart,
            unavailable("OpenCode runs queued messages on its own when the current one finishes"),
        )
        .with_op(OpKind::QueueEdit, Availability::Supported)
        .with_op(OpKind::SettingsThread, Availability::Supported)
        .with_op(
            OpKind::SettingsTurn,
            availability_for_scope(SettingsScope::Turn),
        )
        .with_op(
            OpKind::SettingsPersisted,
            availability_for_scope(SettingsScope::Persisted),
        )
        .with_op(OpKind::Compact, Availability::Supported)
        .with_op(OpKind::Rename, Availability::Supported)
        .with_op(OpKind::Archive, Availability::Supported)
        .with_op(
            OpKind::Clear,
            unavailable("OpenCode has no clear; use /new for a fresh conversation"),
        )
        .with_op(OpKind::RewindFiles, Availability::Supported)
        .with_op(OpKind::Mode, Availability::Supported)
        .with_op(
            OpKind::Review,
            unavailable("OpenCode has no review operation; ask for a review instead"),
        )
        .with_op(OpKind::Goal, unavailable("OpenCode has no session goal"))
        .with_op(OpKind::StopChild, Availability::Supported)
        .with_op(OpKind::Answer, Availability::Supported)
        .with_op(OpKind::Sample, Availability::Supported)
        .with_op(
            OpKind::McpAuth,
            unavailable("connect MCP servers in OpenCode (`opencode mcp`)"),
        )
}

/// `/name rest` → (`name`, `rest`).
fn slash_command(text: &str) -> Option<(&str, &str)> {
    let text = text.trim_start().strip_prefix('/')?;
    let (name, rest) = text.split_once(char::is_whitespace).unwrap_or((text, ""));
    (!name.is_empty() && !name.contains('/')).then_some((name, rest.trim()))
}

/// The prompt text: Inline's per-input instructions and untrusted
/// conversation excerpts, kept apart from the author's own words.
fn prompt_text(input: &Input) -> String {
    let mut parts = Vec::new();
    if let Some(context) = &input.content.context {
        if !context.instructions.trim().is_empty() {
            parts.push(format!(
                "<inline-instructions>\n{}\n</inline-instructions>",
                context.instructions.trim()
            ));
        }
        if !context.conversation.trim().is_empty() {
            parts.push(format!(
                "<inline-context untrusted=\"true\">\n{}\n</inline-context>",
                context.conversation.trim()
            ));
        }
    }
    let described: Vec<String> = input
        .content
        .attachments
        .iter()
        .filter(|attachment| attachable(attachment).is_none())
        .map(|attachment| {
            format!(
                "- {} ({}){}",
                attachment.file_name.as_deref().unwrap_or("attachment"),
                attachment.mime_type.as_deref().unwrap_or("unknown type"),
                attachment
                    .local_uri
                    .as_deref()
                    .map(|uri| format!(": {}", uri.strip_prefix("file://").unwrap_or(uri)))
                    .unwrap_or_default()
            )
        })
        .collect();
    if !described.is_empty() {
        parts.push(format!(
            "Attached files (untrusted):\n{}",
            described.join("\n")
        ));
    }
    parts.push(input.content.text.clone());
    parts.join("\n\n")
}

/// The `file://` URI OpenCode reads itself, for media a model can take.
fn attachable(attachment: &inline_agent_bridge::InputAttachment) -> Option<String> {
    let uri = attachment.local_uri.as_deref()?;
    let path = PathBuf::from(uri.strip_prefix("file://").unwrap_or(uri));
    let metadata = std::fs::metadata(&path).ok()?;
    if !metadata.is_file() || metadata.len() > MAX_ATTACHMENT_BYTES {
        return None;
    }
    let mime = attachment.mime_type.as_deref().unwrap_or("");
    let takes = match attachment.kind {
        InputAttachmentKind::Image => true,
        InputAttachmentKind::File => {
            mime == "application/pdf" || mime.starts_with("text/") || mime.is_empty()
        }
        InputAttachmentKind::Audio | InputAttachmentKind::Video => false,
    };
    takes
        .then(|| url::Url::from_file_path(&path).ok().map(String::from))
        .flatten()
}

fn files(input: &Input) -> Vec<Value> {
    input
        .content
        .attachments
        .iter()
        .filter_map(|attachment| {
            let uri = attachable(attachment)?;
            let mut file = json!({"uri": uri});
            if let Some(name) = &attachment.file_name {
                file["name"] = json!(name);
            }
            Some(file)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A server that drops the first request without answering, then
    /// answers every later one.
    async fn flaky_server() -> (url::Url, Arc<std::sync::atomic::AtomicUsize>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let seen = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = seen.clone();
        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    return;
                };
                let attempt = counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let mut buffer = vec![0u8; 8192];
                let _ = socket.read(&mut buffer).await;
                if attempt == 0 {
                    drop(socket);
                    continue;
                }
                let body = r#"{"data":{"id":"msg_1"}}"#;
                let response = format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = socket.write_all(response.as_bytes()).await;
            }
        });
        (
            url::Url::parse(&format!("http://{address}/")).unwrap(),
            seen,
        )
    }

    #[tokio::test]
    async fn a_prompt_lost_in_transport_is_retried_once_with_the_same_id() {
        let (url, seen) = flaky_server().await;
        let api = Api::new(crate::service::Endpoint::open(url)).unwrap();
        let reply = post_idempotent(&api, "api/session/ses/prompt", json!({"id": "msg_1"}))
            .await
            .expect("retried");
        assert_eq!(reply.map(data).unwrap()["id"], "msg_1");
        assert_eq!(seen.load(std::sync::atomic::Ordering::SeqCst), 2);
    }

    fn inner() -> Arc<SessionInner> {
        let api = Api::new(crate::service::Endpoint::open(
            url::Url::parse("http://127.0.0.1:9/").unwrap(),
        ))
        .unwrap();
        let link = Arc::new(Link::fixed(
            api,
            crate::service::ServerInfo {
                version: "2.2.5".into(),
                pid: 1,
            },
            crate::service::ServiceConfig::new("/nonexistent"),
        ));
        let bus = EventBus::start(link.clone());
        SessionInner::new(
            SessionKey {
                provider: inline_agent_bridge::ProviderId::new("opencode").unwrap(),
                session: inline_agent_bridge::ProviderSessionId::new("ses_parent").unwrap(),
            },
            PathBuf::from("/work"),
            link,
            bus,
            Weak::new(),
        )
    }

    #[tokio::test]
    async fn sub_agent_tool_calls_bind_to_their_inline_session() {
        let inner = inner();
        assert_eq!(
            inner
                .binding("ses_parent")
                .map(|(session, _)| session)
                .as_deref(),
            Some("ses_parent")
        );
        assert!(inner.binding("ses_child").is_none());
        inner.state().mapper.adopt_child("ses_child", None, true);
        assert_eq!(
            inner
                .binding("ses_child")
                .map(|(session, _)| session)
                .as_deref(),
            Some("ses_parent")
        );
        assert!(inner.binding("ses_tui").is_none());
        inner.detach();
        assert!(
            inner.binding("ses_parent").is_none(),
            "a released session binds nothing"
        );
    }
    use inline_agent_bridge::harness::{InputContent, InputId, Origin, UserId};

    #[test]
    fn prompt_text_separates_context_from_the_author() {
        let input = Input {
            id: InputId::new("in-1").unwrap(),
            content: InputContent {
                text: "fix it".into(),
                attachments: Vec::new(),
                context: Some(inline_agent_bridge::TurnContext {
                    instructions: String::new(),
                    conversation: "Ana: the build is red".into(),
                }),
            },
            origin: Origin::Owner { user: UserId(1) },
            delivery: Delivery::Turn,
        };
        assert_eq!(
            prompt_text(&input),
            "<inline-context untrusted=\"true\">\nAna: the build is red\n</inline-context>\n\nfix it"
        );
    }

    #[test]
    fn slash_commands_split_name_and_arguments() {
        assert_eq!(slash_command("/init"), Some(("init", "")));
        assert_eq!(
            slash_command("  /review  main branch "),
            Some(("review", "main branch"))
        );
        assert_eq!(slash_command("/usr/bin/env is a path"), None);
        assert_eq!(slash_command("hello"), None);
    }

    #[test]
    fn availability_declares_every_delivery_and_operation() {
        let matrix = availability();
        for kind in DeliveryKind::ALL {
            assert!(matrix.delivery(kind).is_supported());
        }
        for kind in OpKind::ALL {
            assert!(matrix.ops.contains_key(&kind), "{kind:?}");
        }
        assert!(!matrix.op(OpKind::Clear).is_supported());
        assert!(matrix.op(OpKind::Sample).is_supported());
    }
}
