//! Snapshot-repaired live observation for Codex sessions.
//!
//! Codex does not expose a notification replay cursor. Attachment therefore
//! uses the `thread/resume` response as the authoritative snapshot boundary,
//! then accepts only provider frames sequenced strictly after that response.
//! The observer is fed by the driver's existing JSON-RPC reader; it never
//! claims or competes for the provider stream.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::Path;
use std::sync::{Arc, Mutex as StdMutex};

use futures_util::stream;
use inline_agent_bridge::{
    AgentSessionConnection, AttachSessionRequest, AttachedSession, DetachSessionRequest,
    DriverError, DriverFuture, DriverResult, ProviderInstanceRef, ProviderSessionRef,
    ProviderSurface, SessionActivityKind, SessionActivityStatus, SessionAttachmentId, SessionEvent,
    SessionEventOrigin, SessionEventPayload, SessionItem, SessionItemPayload, SessionItemVersion,
    SessionMessageRole, SessionProjectionAck, SessionProjectionAckTracker, SessionRuntimeState,
    SessionStreamPosition, TurnId, WorkspaceId,
};
use serde_json::Value;
use tokio::io::AsyncWrite;
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::CodexAppServerDriver;
use crate::peer::PeerError;
use crate::protocol::ResumeThreadParams;
use crate::session_catalog::{
    CodexSessionCatalog, bounded_transcript, normalize_turn, stable_item_key,
};
use crate::session_wire::{
    CodexThread, CodexThreadItem, CodexThreadStatus, CodexTurn, ThreadResumeResponse,
};

const MAX_ATTACHMENTS_PER_CONNECTION: usize = 32;
const MAX_BUFFERED_NOTIFICATIONS: usize = 256;
const MAX_BUFFERED_NOTIFICATION_BYTES: usize = 2 * 1024 * 1024;
const SESSION_EVENT_CAPACITY: usize = 256;
const MAX_ACCUMULATED_MESSAGE_BYTES: usize = 64 * 1024;
const MAX_PLAN_STEPS: usize = 32;

#[derive(Clone, Default)]
pub(crate) struct SharedSessionObservers {
    inner: Arc<StdMutex<HashMap<String, SessionObserver>>>,
    claim_only: Arc<StdMutex<HashSet<String>>>,
}

impl std::fmt::Debug for SharedSessionObservers {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SharedSessionObservers")
            .field(
                "attachment_count",
                &self.inner.lock().map(|observers| observers.len()).ok(),
            )
            .field(
                "claim_only_count",
                &self.claim_only.lock().map(|claims| claims.len()).ok(),
            )
            .finish()
    }
}

struct SessionObserver {
    session: ProviderSessionRef,
    attachment_id: SessionAttachmentId,
    sender: mpsc::Sender<DriverResult<SessionEvent>>,
    phase: ObserverPhase,
    ack_tracker: Option<SessionProjectionAckTracker>,
}

enum ObserverPhase {
    Attaching {
        notifications: VecDeque<BufferedNotification>,
        buffered_bytes: usize,
    },
    Live {
        resume_boundary: u64,
        next_sequence: u64,
        normalizer: LiveNormalizer,
    },
    Failed(DriverError),
}

struct BufferedNotification {
    wire_sequence: u64,
    method: String,
    params: Value,
}

impl SharedSessionObservers {
    /// Whether provider traffic belongs to an attached or conservatively
    /// claimed session. Observation-only clients must not answer broadcast
    /// approvals, questions, or tool calls on another controller's behalf.
    pub(crate) fn claims_thread_traffic(&self, params: &Value) -> bool {
        let Some(thread_id) = params.get("threadId").and_then(Value::as_str) else {
            return false;
        };
        self.inner
            .lock()
            .expect("Codex session observers poisoned")
            .contains_key(thread_id)
            || self
                .claim_only
                .lock()
                .expect("Codex session claims poisoned")
                .contains(thread_id)
    }

    fn register(
        &self,
        session: ProviderSessionRef,
        attachment_id: SessionAttachmentId,
    ) -> DriverResult<mpsc::Receiver<DriverResult<SessionEvent>>> {
        let mut observers = self.inner.lock().expect("Codex session observers poisoned");
        let key = session.session_id().to_string();
        if observers.contains_key(&key)
            || self
                .claim_only
                .lock()
                .expect("Codex session claims poisoned")
                .contains(&key)
        {
            return Err(DriverError::Rejected(
                "this Codex connection already observes that session".to_string(),
            ));
        }
        let claim_count = self
            .claim_only
            .lock()
            .expect("Codex session claims poisoned")
            .len();
        if observers.len().saturating_add(claim_count) >= MAX_ATTACHMENTS_PER_CONNECTION {
            return Err(DriverError::Rejected(format!(
                "this Codex connection reached its {MAX_ATTACHMENTS_PER_CONNECTION}-session observation limit"
            )));
        }
        let (sender, receiver) = mpsc::channel(SESSION_EVENT_CAPACITY);
        observers.insert(
            key,
            SessionObserver {
                session,
                attachment_id,
                sender,
                phase: ObserverPhase::Attaching {
                    notifications: VecDeque::new(),
                    buffered_bytes: 0,
                },
                ack_tracker: None,
            },
        );
        Ok(receiver)
    }

    fn activate(
        &self,
        session: &ProviderSessionRef,
        attachment_id: &SessionAttachmentId,
        resume_boundary: u64,
        normalizer: LiveNormalizer,
        initial_state: Option<SessionRuntimeState>,
        position: &SessionStreamPosition,
    ) -> DriverResult<()> {
        let mut observers = self.inner.lock().expect("Codex session observers poisoned");
        let key = session.session_id().as_str();
        let observer = observers.get_mut(key).ok_or_else(|| {
            DriverError::Transient("Codex session attachment ended during resume".to_string())
        })?;
        observer.validate_identity(session, attachment_id)?;
        let buffered = match std::mem::replace(
            &mut observer.phase,
            ObserverPhase::Failed(DriverError::Transient(
                "Codex session attachment activation was interrupted".to_string(),
            )),
        ) {
            ObserverPhase::Attaching { notifications, .. } => notifications,
            ObserverPhase::Failed(error) => return Err(error),
            ObserverPhase::Live { .. } => {
                return Err(DriverError::Protocol(
                    "Codex session attachment was activated twice".to_string(),
                ));
            }
        };
        observer.phase = ObserverPhase::Live {
            resume_boundary,
            next_sequence: 1,
            normalizer,
        };
        observer.ack_tracker = Some(SessionProjectionAckTracker::new(session.clone(), position));
        if let Some(state) = initial_state {
            observer.route_payload(SessionEventPayload::StateChanged { state })?;
        }
        for notification in buffered {
            if let Err(error) = observer.route_live(
                notification.wire_sequence,
                &notification.method,
                &notification.params,
            ) {
                let _ = observer.sender.try_send(Err(error.clone()));
                observer.phase = ObserverPhase::Failed(error.clone());
                return Err(error);
            }
        }
        Ok(())
    }

    /// Returns whether a live-session attachment claimed this provider frame.
    /// Claimed external traffic must not enter the ordinary turn driver's
    /// bounded unclaimed-event backlog.
    pub(crate) fn route_notification(
        &self,
        wire_sequence: u64,
        method: &str,
        params: &Value,
    ) -> bool {
        let Some(thread_id) = params.get("threadId").and_then(Value::as_str) else {
            return false;
        };
        let mut observers = self.inner.lock().expect("Codex session observers poisoned");
        let mut remove = false;
        let claimed = observers.contains_key(thread_id)
            || self
                .claim_only
                .lock()
                .expect("Codex session claims poisoned")
                .contains(thread_id);
        if let Some(observer) = observers.get_mut(thread_id) {
            let result = match &mut observer.phase {
                ObserverPhase::Attaching {
                    notifications,
                    buffered_bytes,
                } => {
                    let bytes = method
                        .len()
                        .saturating_add(serde_json::to_vec(params).map_or(usize::MAX, |v| v.len()));
                    if notifications.len() >= MAX_BUFFERED_NOTIFICATIONS
                        || buffered_bytes.saturating_add(bytes) > MAX_BUFFERED_NOTIFICATION_BYTES
                    {
                        let error = DriverError::Transient(
                            "Codex emitted too much activity while the session snapshot was loading"
                                .to_string(),
                        );
                        observer.phase = ObserverPhase::Failed(error.clone());
                        let _ = observer.sender.try_send(Err(error));
                        Ok(())
                    } else {
                        *buffered_bytes += bytes;
                        notifications.push_back(BufferedNotification {
                            wire_sequence,
                            method: method.to_string(),
                            params: params.clone(),
                        });
                        Ok(())
                    }
                }
                ObserverPhase::Live { .. } => observer.route_live(wire_sequence, method, params),
                ObserverPhase::Failed(_) => Ok(()),
            };
            if let Err(error) = result {
                let _ = observer.sender.try_send(Err(error));
                remove = true;
            }
        }
        if remove {
            observers.remove(thread_id);
            self.claim_only
                .lock()
                .expect("Codex session claims poisoned")
                .insert(thread_id.to_string());
        }
        claimed
    }

    fn acknowledge(&self, ack: &SessionProjectionAck) -> DriverResult<()> {
        let mut observers = self.inner.lock().expect("Codex session observers poisoned");
        let observer = observers
            .get_mut(ack.session().session_id().as_str())
            .ok_or_else(|| DriverError::Rejected("stale Codex session attachment".to_string()))?;
        observer.validate_identity(ack.session(), ack.attachment_id())?;
        let tracker = observer.ack_tracker.as_mut().ok_or_else(|| {
            DriverError::Transient("Codex session snapshot is not ready".to_string())
        })?;
        tracker
            .acknowledge(ack)
            .map_err(|error| DriverError::Protocol(error.to_string()))
    }

    fn claim_only(
        &self,
        session: &ProviderSessionRef,
        attachment_id: &SessionAttachmentId,
    ) -> DriverResult<()> {
        let mut observers = self.inner.lock().expect("Codex session observers poisoned");
        let key = session.session_id().as_str();
        let observer = observers
            .get(key)
            .ok_or_else(|| DriverError::Rejected("stale Codex session attachment".to_string()))?;
        observer.validate_identity(session, attachment_id)?;
        observers.remove(key);
        self.claim_only
            .lock()
            .expect("Codex session claims poisoned")
            .insert(key.to_string());
        Ok(())
    }

    fn claim_only_if_matches(
        &self,
        session: &ProviderSessionRef,
        attachment_id: &SessionAttachmentId,
    ) {
        let mut observers = self.inner.lock().expect("Codex session observers poisoned");
        let key = session.session_id().as_str();
        if observers
            .get(key)
            .is_some_and(|observer| &observer.attachment_id == attachment_id)
        {
            observers.remove(key);
            self.claim_only
                .lock()
                .expect("Codex session claims poisoned")
                .insert(key.to_string());
        }
    }

    pub(crate) fn fail_all(&self, error: DriverError) {
        let observers =
            std::mem::take(&mut *self.inner.lock().expect("Codex session observers poisoned"));
        self.claim_only
            .lock()
            .expect("Codex session claims poisoned")
            .clear();
        for (_, observer) in observers {
            let _ = observer.sender.try_send(Err(error.clone()));
        }
    }

    #[cfg(test)]
    fn attachment_count(&self) -> usize {
        self.inner
            .lock()
            .expect("Codex session observers poisoned")
            .len()
    }

    #[cfg(test)]
    fn claim_only_count(&self) -> usize {
        self.claim_only
            .lock()
            .expect("Codex session claims poisoned")
            .len()
    }
}

impl SessionObserver {
    fn validate_identity(
        &self,
        session: &ProviderSessionRef,
        attachment_id: &SessionAttachmentId,
    ) -> DriverResult<()> {
        if &self.session != session {
            return Err(DriverError::Protocol(
                "Codex session attachment crossed its provider instance".to_string(),
            ));
        }
        if &self.attachment_id != attachment_id {
            return Err(DriverError::Rejected(
                "stale Codex session attachment".to_string(),
            ));
        }
        Ok(())
    }

    fn route_live(&mut self, wire_sequence: u64, method: &str, params: &Value) -> DriverResult<()> {
        let ObserverPhase::Live {
            resume_boundary,
            normalizer,
            ..
        } = &mut self.phase
        else {
            return Ok(());
        };
        if wire_sequence <= *resume_boundary {
            return Ok(());
        }
        let payloads = normalizer.normalize(method, params)?;
        for payload in payloads {
            self.route_payload(payload)?;
        }
        Ok(())
    }

    fn route_payload(&mut self, mut payload: SessionEventPayload) -> DriverResult<()> {
        let ObserverPhase::Live { next_sequence, .. } = &mut self.phase else {
            return Err(DriverError::Protocol(
                "Codex session event was emitted before attachment".to_string(),
            ));
        };
        let sequence = *next_sequence;
        *next_sequence = sequence.checked_add(1).ok_or_else(|| {
            DriverError::Transient("Codex session event sequence exhausted".to_string())
        })?;
        if let SessionEventPayload::Item { item } = &mut payload {
            item.revision =
                SessionItemVersion::from_stream_sequence(sequence).ok_or_else(|| {
                    DriverError::Transient("Codex session item revision exhausted".to_string())
                })?;
        }
        self.sender
            .try_send(Ok(SessionEvent {
                session: self.session.clone(),
                attachment_id: self.attachment_id.clone(),
                sequence,
                checkpoint: None,
                payload,
            }))
            .map_err(|error| match error {
                mpsc::error::TrySendError::Full(_) => {
                    DriverError::Transient("Codex session event consumer fell behind".to_string())
                }
                mpsc::error::TrySendError::Closed(_) => {
                    DriverError::Transient("Codex session event consumer closed".to_string())
                }
            })
    }
}

#[derive(Default)]
struct LiveNormalizer {
    assistant_text: HashMap<(String, String), String>,
}

impl LiveNormalizer {
    fn from_thread(thread: &CodexThread) -> Self {
        let mut normalizer = Self::default();
        for turn in &thread.turns {
            for item in &turn.items {
                if let CodexThreadItem::AgentMessage { id, text, .. } = item {
                    normalizer
                        .assistant_text
                        .insert((turn.id.clone(), id.clone()), truncate_raw_message(text));
                }
            }
        }
        normalizer
    }

    fn normalize(
        &mut self,
        method: &str,
        params: &Value,
    ) -> DriverResult<Vec<SessionEventPayload>> {
        match method {
            "turn/started" => Ok(vec![SessionEventPayload::StateChanged {
                state: SessionRuntimeState::Running,
            }]),
            "turn/completed" => Ok(vec![SessionEventPayload::StateChanged {
                state: SessionRuntimeState::Idle,
            }]),
            "turn/plan/updated" => self.plan_updated(params),
            "item/agentMessage/delta" => self.agent_message_delta(params),
            "item/started" | "item/completed" => self.item(method, params),
            _ => Ok(Vec::new()),
        }
    }

    fn plan_updated(&self, params: &Value) -> DriverResult<Vec<SessionEventPayload>> {
        let turn_id = required_string(params, "turnId", "plan update")?;
        let plan = params
            .get("plan")
            .and_then(Value::as_array)
            .ok_or_else(|| DriverError::Protocol("Codex plan update omitted plan".to_string()))?;
        let mut detail = Vec::with_capacity(plan.len().min(MAX_PLAN_STEPS) + 1);
        if let Some(explanation) = params
            .get("explanation")
            .and_then(Value::as_str)
            .and_then(bounded_transcript)
        {
            detail.push(explanation);
        }
        let mut has_in_progress = false;
        let mut has_pending = false;
        let mut step_count = 0usize;
        for step in plan.iter().take(MAX_PLAN_STEPS) {
            let text = required_string(step, "step", "plan step")?;
            let status = required_string(step, "status", "plan step")?;
            let status = match status {
                "completed" => "completed",
                "inProgress" => {
                    has_in_progress = true;
                    "in progress"
                }
                "pending" => {
                    has_pending = true;
                    "pending"
                }
                _ => {
                    return Err(DriverError::Protocol(
                        "Codex plan update returned an invalid step status".to_string(),
                    ));
                }
            };
            let Some(text) = bounded_transcript(text) else {
                continue;
            };
            detail.push(format!("{status}: {text}"));
            step_count += 1;
        }
        let status = if has_in_progress {
            SessionActivityStatus::Active
        } else if has_pending || step_count == 0 {
            SessionActivityStatus::Waiting
        } else {
            SessionActivityStatus::Completed
        };
        let detail = bounded_transcript(&detail.join("\n"));
        let run_id =
            TurnId::new(turn_id).map_err(|error| DriverError::Protocol(error.to_string()))?;
        let item = SessionItem {
            key: stable_item_key(turn_id, "plan", "current")?,
            revision: SessionItemVersion::snapshot_baseline(),
            run_id: Some(run_id),
            origin: SessionEventOrigin::provider(ProviderSurface::Unknown),
            payload: SessionItemPayload::Activity {
                activity_kind: SessionActivityKind::Plan,
                status,
                title: "Plan".to_string(),
                detail,
            },
        };
        Ok(vec![SessionEventPayload::Item {
            item: Box::new(item),
        }])
    }

    fn agent_message_delta(&mut self, params: &Value) -> DriverResult<Vec<SessionEventPayload>> {
        let turn_id = required_string(params, "turnId", "agent message delta")?;
        let item_id = required_string(params, "itemId", "agent message delta")?;
        let delta = required_string(params, "delta", "agent message delta")?;
        let text = self
            .assistant_text
            .entry((turn_id.to_string(), item_id.to_string()))
            .or_default();
        append_bounded(text, delta);
        let Some(text) = bounded_transcript(text) else {
            return Ok(Vec::new());
        };
        let run_id =
            TurnId::new(turn_id).map_err(|error| DriverError::Protocol(error.to_string()))?;
        let item = SessionItem {
            key: stable_item_key(turn_id, "assistant", item_id)?,
            revision: SessionItemVersion::snapshot_baseline(),
            run_id: Some(run_id),
            origin: SessionEventOrigin::provider(ProviderSurface::Unknown),
            payload: SessionItemPayload::Message {
                role: SessionMessageRole::Assistant,
                text,
                created_at: None,
            },
        };
        Ok(vec![SessionEventPayload::Item {
            item: Box::new(item),
        }])
    }

    fn item(&mut self, method: &str, params: &Value) -> DriverResult<Vec<SessionEventPayload>> {
        let turn_id = required_string(params, "turnId", method)?;
        let item_value = params
            .get("item")
            .cloned()
            .ok_or_else(|| DriverError::Protocol(format!("Codex {method} omitted its item")))?;
        let item: CodexThreadItem = serde_json::from_value(item_value).map_err(|error| {
            DriverError::Protocol(format!("Codex {method} returned an invalid item: {error}"))
        })?;
        if let CodexThreadItem::AgentMessage { id, text, .. } = &item {
            self.assistant_text.insert(
                (turn_id.to_string(), id.clone()),
                truncate_raw_message(text),
            );
        }
        let timestamp = params
            .get(if method == "item/started" {
                "startedAtMs"
            } else {
                "completedAtMs"
            })
            .and_then(Value::as_i64)
            .filter(|timestamp| *timestamp >= 0)
            .map(|timestamp| timestamp / 1000);
        let turn = CodexTurn {
            id: turn_id.to_string(),
            items: vec![item],
            items_view: crate::session_wire::TurnItemsView::Full,
            started_at: (method == "item/started").then_some(timestamp).flatten(),
            completed_at: (method == "item/completed").then_some(timestamp).flatten(),
        };
        let normalized = normalize_turn(turn)?;
        Ok(normalized
            .into_iter()
            .map(|item| SessionEventPayload::Item {
                item: Box::new(item),
            })
            .collect())
    }
}

fn required_string<'a>(params: &'a Value, field: &str, context: &str) -> DriverResult<&'a str> {
    params
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| DriverError::Protocol(format!("Codex {context} omitted {field}")))
}

fn append_bounded(target: &mut String, delta: &str) {
    if target.len() >= MAX_ACCUMULATED_MESSAGE_BYTES {
        return;
    }
    let remaining = MAX_ACCUMULATED_MESSAGE_BYTES - target.len();
    if delta.len() <= remaining {
        target.push_str(delta);
        return;
    }
    let mut end = remaining;
    while !delta.is_char_boundary(end) {
        end -= 1;
    }
    target.push_str(&delta[..end]);
}

fn truncate_raw_message(value: &str) -> String {
    if value.len() <= MAX_ACCUMULATED_MESSAGE_BYTES {
        return value.to_string();
    }
    let mut end = MAX_ACCUMULATED_MESSAGE_BYTES;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_string()
}

/// A workspace-scoped live connection over one initialized Codex app-server
/// client. It is capability-dark until the Inline thread projection owns its
/// durable acknowledgement and ambiguous-send recovery path.
pub struct CodexSessionConnection<W> {
    driver: CodexAppServerDriver<W>,
    catalog: CodexSessionCatalog<CodexAppServerDriver<W>>,
    observers: SharedSessionObservers,
}

impl<W> std::fmt::Debug for CodexSessionConnection<W> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CodexSessionConnection")
            .field("driver", &self.driver)
            .field("catalog", &self.catalog)
            .finish_non_exhaustive()
    }
}

impl<W> CodexSessionConnection<W>
where
    W: AsyncWrite + Unpin + Send + 'static,
{
    pub fn new(
        driver: CodexAppServerDriver<W>,
        provider: ProviderInstanceRef,
        workspace_id: WorkspaceId,
        workspace_path: &Path,
    ) -> DriverResult<Self> {
        let catalog =
            CodexSessionCatalog::new(driver.clone(), provider, workspace_id, workspace_path)?;
        let observers = driver.session_observers();
        Ok(Self {
            driver,
            catalog,
            observers,
        })
    }

    async fn cleanup_subscription(&self, session: &ProviderSessionRef) {
        if self
            .catalog
            .unsubscribe_prevalidated_current_connection(session)
            .await
            .is_err()
        {
            log::debug!("Codex attachment cleanup could not confirm unsubscribe");
        }
        // Keep the claim until this provider connection closes. Responses are
        // routed directly to request waiters while notifications travel
        // through the bounded dispatcher queue, so even a successful
        // unsubscribe can overtake earlier notifications. A timed-out resume
        // can also finish after unsubscribe. Retaining the tombstone is the
        // minimal fail-closed rule until an ordered dispatcher barrier exists.
    }
}

impl<W> AgentSessionConnection for CodexSessionConnection<W>
where
    W: AsyncWrite + Unpin + Send + 'static,
{
    fn attach_session<'a>(
        &'a self,
        request: AttachSessionRequest,
    ) -> DriverFuture<'a, AttachedSession> {
        Box::pin(async move {
            self.catalog.validate_workspace(&request.workspace_id)?;
            self.catalog
                .validate_session_for_attachment(&request.session)
                .await?;
            let attachment_id = SessionAttachmentId::new(Uuid::new_v4().to_string())
                .map_err(|error| DriverError::Protocol(error.to_string()))?;
            let receiver = self
                .observers
                .register(request.session.clone(), attachment_id.clone())?;
            let resume = self
                .driver
                .session_request_with_wire_sequence(
                    "thread/resume",
                    serde_json::to_value(ResumeThreadParams {
                        thread_id: request.session.session_id().to_string(),
                        cwd: None,
                        config: None,
                    })
                    .map_err(|error| DriverError::Protocol(error.to_string()))?,
                )
                .await;
            let (resume, resume_boundary) = match resume {
                Ok(response) => response,
                Err(error) => {
                    self.observers
                        .claim_only_if_matches(&request.session, &attachment_id);
                    self.cleanup_subscription(&request.session).await;
                    return Err(peer_error(error));
                }
            };
            let response: ThreadResumeResponse = match serde_json::from_value(resume) {
                Ok(response) => response,
                Err(error) => {
                    self.observers
                        .claim_only_if_matches(&request.session, &attachment_id);
                    self.cleanup_subscription(&request.session).await;
                    return Err(DriverError::Protocol(format!(
                        "Codex thread/resume returned an invalid stable response: {error}"
                    )));
                }
            };
            if let Err(error) = self
                .catalog
                .validate_thread_scope(&request.session, &response.thread)
            {
                self.observers
                    .claim_only_if_matches(&request.session, &attachment_id);
                self.cleanup_subscription(&request.session).await;
                return Err(error);
            }
            let normalizer = LiveNormalizer::from_thread(&response.thread);
            let initial_state = Some(runtime_state(&response.thread.status));
            let snapshot = match self.catalog.snapshot(
                request.session.clone(),
                response.thread,
                request.history,
            ) {
                Ok(snapshot) => snapshot,
                Err(error) => {
                    self.observers
                        .claim_only_if_matches(&request.session, &attachment_id);
                    self.cleanup_subscription(&request.session).await;
                    return Err(error);
                }
            };
            let position = SessionStreamPosition {
                attachment_id: attachment_id.clone(),
                last_applied_sequence: 0,
                checkpoint: None,
            };
            if let Err(error) = self.observers.activate(
                &request.session,
                &attachment_id,
                resume_boundary,
                normalizer,
                initial_state,
                &position,
            ) {
                self.observers
                    .claim_only_if_matches(&request.session, &attachment_id);
                self.cleanup_subscription(&request.session).await;
                return Err(error);
            }
            let events = Box::pin(stream::unfold(receiver, |mut receiver| async move {
                receiver.recv().await.map(|event| (event, receiver))
            }));
            Ok(AttachedSession {
                snapshot,
                position,
                controller_epoch: None,
                events,
            })
        })
    }

    fn acknowledge_projection<'a>(&'a self, ack: SessionProjectionAck) -> DriverFuture<'a, ()> {
        Box::pin(async move { self.observers.acknowledge(&ack) })
    }

    fn detach_session<'a>(&'a self, request: DetachSessionRequest) -> DriverFuture<'a, ()> {
        Box::pin(async move {
            self.observers
                .claim_only(&request.session, &request.attachment_id)?;
            let result = self
                .catalog
                .unsubscribe_prevalidated_current_connection(&request.session)
                .await;
            result?;
            Ok(())
        })
    }
}

fn peer_error(error: PeerError) -> DriverError {
    match error {
        PeerError::Io(error) => DriverError::Unavailable(error.to_string()),
        PeerError::Remote(error) => DriverError::Rejected(match error.code {
            Some(code) => format!("Codex rejected session attachment (code {code})"),
            None => "Codex rejected session attachment".to_string(),
        }),
        PeerError::Closed => DriverError::ProcessExited("Codex app-server closed".to_string()),
        PeerError::Json(error) => DriverError::Protocol(error.to_string()),
        PeerError::InvalidMessage(error) => DriverError::Protocol(error),
        PeerError::IncomingAlreadyClaimed => DriverError::Protocol(
            "Codex app-server incoming stream already has an owner".to_string(),
        ),
        PeerError::Timeout(method) => DriverError::Transient(format!("Codex {method} timed out")),
    }
}

fn runtime_state(status: &CodexThreadStatus) -> SessionRuntimeState {
    match status {
        CodexThreadStatus::Active { .. } => SessionRuntimeState::Running,
        CodexThreadStatus::Idle | CodexThreadStatus::NotLoaded => SessionRuntimeState::Idle,
        CodexThreadStatus::SystemError => SessionRuntimeState::Unavailable,
        CodexThreadStatus::Unknown => SessionRuntimeState::Unavailable,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use inline_agent_bridge::{
        AgentSessionConnection, HistoryWindow, InstallationId, ProviderId, ProviderSessionId,
        SessionEventPayload,
    };
    use serde_json::json;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    fn provider() -> ProviderInstanceRef {
        ProviderInstanceRef::new(
            InstallationId::new("codex-local").expect("installation"),
            ProviderId::new("codex").expect("provider"),
        )
        .expect("provider")
    }

    fn session(provider: &ProviderInstanceRef) -> ProviderSessionRef {
        ProviderSessionRef::new(
            provider.clone(),
            ProviderSessionId::new("thread-1").expect("session id"),
        )
        .expect("session")
    }

    fn resume_response(cwd: &str) -> Value {
        json!({
            "thread": {
                "id": "thread-1",
                "preview": "hello",
                "updatedAt": 1,
                "status": { "type": "idle" },
                "cwd": cwd,
                "source": "cli",
                "turns": [{
                    "id": "turn-1",
                    "items": [{
                        "type": "agentMessage",
                        "id": "message-1",
                        "text": "before"
                    }]
                }]
            }
        })
    }

    #[tokio::test]
    async fn resume_snapshot_is_an_ordered_boundary_for_live_deltas() {
        let workspace = tempfile::tempdir().expect("workspace");
        let cwd = workspace.path().to_string_lossy().to_string();
        let (client, server) = tokio::io::duplex(64 * 1024);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = crate::CodexPeer::new(client_reader, client_writer, 64);
        let (release_server, wait_for_assertions) = tokio::sync::oneshot::channel();
        let server_task = tokio::spawn({
            let cwd = cwd.clone();
            async move {
                let (reader, mut writer) = tokio::io::split(server);
                let mut lines = BufReader::new(reader).lines();
                let initialize: Value =
                    serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
                writer
                    .write_all(
                        format!(
                            "{{\"id\":{},\"result\":{{\"userAgent\":\"codex/0.150.0-alpha.8\"}}}}\n",
                            initialize["id"]
                        )
                        .as_bytes(),
                    )
                    .await
                    .unwrap();
                let _initialized = lines.next_line().await.unwrap().unwrap();
                let read: Value =
                    serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
                assert_eq!(read["method"], "thread/read");
                writer
                    .write_all(
                        format!(
                            "{{\"id\":{},\"result\":{}}}\n",
                            read["id"],
                            resume_response(&cwd)
                        )
                        .as_bytes(),
                    )
                    .await
                    .unwrap();
                let resume: Value =
                    serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
                assert_eq!(resume["method"], "thread/resume");
                writer
                    .write_all(b"{\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"itemId\":\"message-1\",\"delta\":\"stale\"}}\n")
                    .await
                    .unwrap();
                writer
                    .write_all(
                        format!(
                            "{{\"id\":{},\"result\":{}}}\n",
                            resume["id"],
                            resume_response(&cwd)
                        )
                        .as_bytes(),
                    )
                    .await
                    .unwrap();
                writer
                    .write_all(b"{\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"itemId\":\"message-1\",\"delta\":\" after\"}}\n")
                    .await
                    .unwrap();
                writer
                    .write_all(b"{\"id\":\"external-tool\",\"method\":\"item/tool/call\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"callId\":\"call-1\",\"tool\":\"external\",\"arguments\":{}}}\n")
                    .await
                    .unwrap();
                assert!(
                    tokio::time::timeout(std::time::Duration::from_millis(100), lines.next_line())
                        .await
                        .is_err(),
                    "observation-only attachment answered a broadcast server request"
                );
                let _ = wait_for_assertions.await;
            }
        });
        let driver = CodexAppServerDriver::initialize(peer, "0.7.4")
            .await
            .expect("driver");
        let provider = provider();
        let connection = CodexSessionConnection::new(
            driver.clone(),
            provider.clone(),
            WorkspaceId::new("workspace-1").expect("workspace id"),
            workspace.path(),
        )
        .expect("connection");
        let mut attached = connection
            .attach_session(AttachSessionRequest {
                session: session(&provider),
                workspace_id: WorkspaceId::new("workspace-1").unwrap(),
                after: None,
                history: HistoryWindow::default(),
            })
            .await
            .expect("attach");
        assert_eq!(attached.snapshot.items().len(), 1);
        let initial_state = futures_util::StreamExt::next(&mut attached.events)
            .await
            .expect("initial state")
            .expect("valid state");
        assert!(matches!(
            initial_state.payload,
            SessionEventPayload::StateChanged {
                state: SessionRuntimeState::Idle
            }
        ));
        assert_eq!(initial_state.sequence, 1);
        let event = futures_util::StreamExt::next(&mut attached.events)
            .await
            .expect("live event")
            .expect("valid event");
        let SessionEventPayload::Item { item } = event.payload else {
            panic!("expected item");
        };
        let SessionItemPayload::Message { text, .. } = item.payload else {
            panic!("expected message");
        };
        assert_eq!(text, "before after");
        assert_eq!(event.sequence, 2);
        let _ = release_server.send(());
        server_task.await.expect("server");
    }

    #[tokio::test]
    async fn attachment_scope_is_validated_before_resume_can_subscribe() {
        let workspace = tempfile::tempdir().expect("workspace");
        let outside = tempfile::tempdir().expect("outside workspace");
        let outside_cwd = outside.path().to_string_lossy().to_string();
        let (client, server) = tokio::io::duplex(64 * 1024);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = crate::CodexPeer::new(client_reader, client_writer, 64);
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(server);
            let mut lines = BufReader::new(reader).lines();
            let initialize: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            writer
                .write_all(
                    format!(
                        "{{\"id\":{},\"result\":{{\"userAgent\":\"codex/0.150.0-alpha.8\"}}}}\n",
                        initialize["id"]
                    )
                    .as_bytes(),
                )
                .await
                .unwrap();
            let _initialized = lines.next_line().await.unwrap().unwrap();
            let read: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            assert_eq!(read["method"], "thread/read");
            writer
                .write_all(
                    format!(
                        "{{\"id\":{},\"result\":{}}}\n",
                        read["id"],
                        resume_response(&outside_cwd)
                    )
                    .as_bytes(),
                )
                .await
                .unwrap();
            tokio::time::timeout(std::time::Duration::from_millis(100), lines.next_line())
                .await
                .is_err()
        });
        let driver = CodexAppServerDriver::initialize(peer, "0.7.4")
            .await
            .expect("driver");
        let provider = provider();
        let connection = CodexSessionConnection::new(
            driver,
            provider.clone(),
            WorkspaceId::new("workspace-1").expect("workspace id"),
            workspace.path(),
        )
        .expect("connection");
        assert!(matches!(
            connection
                .attach_session(AttachSessionRequest {
                    session: session(&provider),
                    workspace_id: WorkspaceId::new("workspace-1").unwrap(),
                    after: None,
                    history: HistoryWindow::default(),
                })
                .await,
            Err(DriverError::Protocol(_))
        ));
        assert!(server_task.await.expect("server"), "resume was sent");
    }

    #[test]
    fn detached_session_stays_claimed_until_connection_close() {
        let observers = SharedSessionObservers::default();
        let provider = provider();
        let session = session(&provider);
        let attachment = SessionAttachmentId::new("attachment-1").unwrap();
        let _receiver = observers
            .register(session.clone(), attachment.clone())
            .expect("register");
        observers
            .claim_only(&session, &attachment)
            .expect("detach claim");

        assert_eq!(observers.attachment_count(), 0);
        assert_eq!(observers.claim_only_count(), 1);
        assert!(observers.route_notification(
            1,
            "turn/started",
            &json!({ "threadId": "thread-1" }),
        ));
        assert!(observers.claims_thread_traffic(&json!({ "threadId": "thread-1" })));
        assert!(matches!(
            observers.register(
                session.clone(),
                SessionAttachmentId::new("attachment-2").unwrap()
            ),
            Err(DriverError::Rejected(_))
        ));

        observers.fail_all(DriverError::ProcessExited("closed".to_string()));
        assert_eq!(observers.claim_only_count(), 0);
    }

    #[test]
    fn live_plan_updates_are_stable_bounded_activity_upserts() {
        let mut normalizer = LiveNormalizer::default();
        let payloads = normalizer
            .normalize(
                "turn/plan/updated",
                &json!({
                    "threadId": "thread-1",
                    "turnId": "turn-1",
                    "explanation": "Implement and verify",
                    "plan": [
                        { "step": "Implement", "status": "completed" },
                        { "step": "Verify", "status": "inProgress" }
                    ]
                }),
            )
            .expect("plan update");
        let SessionEventPayload::Item { item } = &payloads[0] else {
            panic!("expected plan item");
        };
        let snapshot_plan = normalize_turn(CodexTurn {
            id: "turn-1".to_string(),
            items: vec![CodexThreadItem::Plan {
                id: "provider-plan-item".to_string(),
                text: "Implement then verify".to_string(),
            }],
            items_view: crate::session_wire::TurnItemsView::Full,
            started_at: None,
            completed_at: Some(1),
        })
        .expect("snapshot plan");
        assert_eq!(
            item.key, snapshot_plan[0].key,
            "live and repaired plans must upsert one per-turn item"
        );
        assert_eq!(
            item.origin.provider_surface(),
            Some(ProviderSurface::Unknown)
        );
        assert!(matches!(
            item.payload,
            SessionItemPayload::Activity {
                activity_kind: SessionActivityKind::Plan,
                status: SessionActivityStatus::Active,
                ..
            }
        ));
    }

    #[test]
    fn provider_rejection_text_is_not_exposed() {
        let error = peer_error(PeerError::Remote(crate::peer::RemoteError {
            code: Some(-32600),
            message: "thread secret-thread-id already has an active writer".to_string(),
        }));
        let message = error.to_string();
        assert!(message.contains("-32600"));
        assert!(!message.contains("secret-thread-id"));
        assert!(!message.contains("active writer"));
    }

    #[test]
    fn attach_buffer_is_bounded_and_fails_closed() {
        let observers = SharedSessionObservers::default();
        let provider = provider();
        let session = session(&provider);
        let attachment = SessionAttachmentId::new("attachment-1").unwrap();
        let _receiver = observers
            .register(session.clone(), attachment.clone())
            .expect("register");
        for sequence in 1..=MAX_BUFFERED_NOTIFICATIONS as u64 + 1 {
            observers.route_notification(
                sequence,
                "turn/started",
                &json!({ "threadId": "thread-1" }),
            );
        }
        assert_eq!(observers.attachment_count(), 1);
        let position = SessionStreamPosition {
            attachment_id: attachment.clone(),
            last_applied_sequence: 0,
            checkpoint: None,
        };
        assert!(matches!(
            observers.activate(
                &session,
                &attachment,
                MAX_BUFFERED_NOTIFICATIONS as u64 + 2,
                LiveNormalizer::default(),
                None,
                &position,
            ),
            Err(DriverError::Transient(_))
        ));
    }

    #[test]
    fn independent_clients_can_observe_the_same_provider_session() {
        let provider = provider();
        let session = session(&provider);
        let first = SharedSessionObservers::default();
        let second = SharedSessionObservers::default();
        let first_attachment = SessionAttachmentId::new("attachment-first").unwrap();
        let second_attachment = SessionAttachmentId::new("attachment-second").unwrap();
        let mut first_events = first
            .register(session.clone(), first_attachment.clone())
            .expect("first client");
        let mut second_events = second
            .register(session.clone(), second_attachment.clone())
            .expect("second client");
        first
            .activate(
                &session,
                &first_attachment,
                10,
                LiveNormalizer::default(),
                None,
                &SessionStreamPosition {
                    attachment_id: first_attachment.clone(),
                    last_applied_sequence: 0,
                    checkpoint: None,
                },
            )
            .unwrap();
        second
            .activate(
                &session,
                &second_attachment,
                20,
                LiveNormalizer::default(),
                None,
                &SessionStreamPosition {
                    attachment_id: second_attachment.clone(),
                    last_applied_sequence: 0,
                    checkpoint: None,
                },
            )
            .unwrap();
        let params = json!({
            "threadId": "thread-1",
            "turnId": "turn-1",
            "itemId": "message-1",
            "delta": "hello"
        });
        assert!(first.route_notification(11, "item/agentMessage/delta", &params));
        assert!(second.route_notification(21, "item/agentMessage/delta", &params));
        let first_event = first_events.try_recv().unwrap().unwrap();
        let second_event = second_events.try_recv().unwrap().unwrap();
        assert_eq!(first_event.sequence, 1);
        assert_eq!(second_event.sequence, 1);
        assert_ne!(first_event.attachment_id, second_event.attachment_id);
    }

    #[test]
    fn reconnect_repairs_from_a_fresh_snapshot_without_a_fake_cursor() {
        let provider = provider();
        let session = session(&provider);
        let first = SharedSessionObservers::default();
        let first_attachment = SessionAttachmentId::new("attachment-before-gap").unwrap();
        let _first_events = first
            .register(session.clone(), first_attachment.clone())
            .unwrap();
        first
            .activate(
                &session,
                &first_attachment,
                3,
                LiveNormalizer::default(),
                None,
                &SessionStreamPosition {
                    attachment_id: first_attachment.clone(),
                    last_applied_sequence: 0,
                    checkpoint: None,
                },
            )
            .unwrap();
        first.fail_all(DriverError::ProcessExited("gap".to_string()));

        let repaired_thread =
            serde_json::from_value::<ThreadResumeResponse>(resume_response("/tmp"))
                .unwrap()
                .thread;
        let repaired = SharedSessionObservers::default();
        let repaired_attachment = SessionAttachmentId::new("attachment-after-gap").unwrap();
        let mut repaired_events = repaired
            .register(session.clone(), repaired_attachment.clone())
            .unwrap();
        repaired
            .activate(
                &session,
                &repaired_attachment,
                30,
                LiveNormalizer::from_thread(&repaired_thread),
                None,
                &SessionStreamPosition {
                    attachment_id: repaired_attachment.clone(),
                    last_applied_sequence: 0,
                    checkpoint: None,
                },
            )
            .unwrap();
        assert!(repaired.route_notification(
            31,
            "item/agentMessage/delta",
            &json!({
                "threadId": "thread-1",
                "turnId": "turn-1",
                "itemId": "message-1",
                "delta": " after repair"
            }),
        ));
        let event = repaired_events.try_recv().unwrap().unwrap();
        let SessionEventPayload::Item { item } = event.payload else {
            panic!("expected repaired item");
        };
        let SessionItemPayload::Message { text, .. } = item.payload else {
            panic!("expected repaired message");
        };
        assert_eq!(text, "before after repair");
        assert_eq!(event.sequence, 1);
    }

    #[test]
    fn a_slow_live_consumer_is_detached_instead_of_blocking_the_reader() {
        let observers = SharedSessionObservers::default();
        let provider = provider();
        let session = session(&provider);
        let attachment = SessionAttachmentId::new("attachment-slow").unwrap();
        let _receiver = observers
            .register(session.clone(), attachment.clone())
            .unwrap();
        observers
            .activate(
                &session,
                &attachment,
                1,
                LiveNormalizer::default(),
                None,
                &SessionStreamPosition {
                    attachment_id: attachment.clone(),
                    last_applied_sequence: 0,
                    checkpoint: None,
                },
            )
            .unwrap();
        for wire_sequence in 2..=SESSION_EVENT_CAPACITY as u64 + 2 {
            assert!(observers.route_notification(
                wire_sequence,
                "turn/started",
                &json!({ "threadId": "thread-1" }),
            ));
        }
        assert_eq!(observers.attachment_count(), 0);
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    #[ignore = "attaches to the authenticated user's installed Codex session catalog"]
    async fn installed_chatgpt_app_server_resumes_and_detaches_a_real_session() {
        use crate::{
            CodexAppServerTransport, CodexLaunchConfig, CodexVersionPolicy, spawn_codex_driver,
        };
        use inline_agent_bridge::{AgentDriver, DetachSessionRequest, ProviderSessionId};

        let spawned = spawn_codex_driver(
            CodexLaunchConfig {
                executable: "/Applications/ChatGPT.app/Contents/Resources/codex".into(),
                transport: CodexAppServerTransport::SharedLocal,
                version_policy: CodexVersionPolicy::Compatible,
                incoming_capacity: 256,
                ..CodexLaunchConfig::default()
            },
            "session-connection-test",
        )
        .await
        .expect("connect to shared app-server");
        let driver = spawned.driver;
        let any_page: crate::session_wire::ThreadListResponse = serde_json::from_value(
            driver
                .session_catalog_request(
                    "thread/list",
                    json!({
                        "limit": 20,
                        "sortKey": "updated_at",
                        "sortDirection": "desc",
                        "archived": false
                    }),
                )
                .await
                .expect("list any stored session"),
        )
        .expect("stable list response");
        let provider = provider();
        let workspace = WorkspaceId::new("real-workspace").unwrap();
        let mut attached_one = false;
        let mut attempted_sessions = std::collections::HashSet::new();
        for stored in any_page.data {
            if !attempted_sessions.insert(stored.id.clone()) {
                continue;
            }
            let session = ProviderSessionRef::new(
                provider.clone(),
                ProviderSessionId::new(stored.id).expect("session id"),
            )
            .expect("session");
            let connection = CodexSessionConnection::new(
                driver.clone(),
                provider.clone(),
                workspace.clone(),
                Path::new(&stored.cwd),
            )
            .expect("connection");
            let attached = match connection
                .attach_session(AttachSessionRequest {
                    session: session.clone(),
                    workspace_id: workspace.clone(),
                    after: None,
                    history: HistoryWindow::new(5, 32 * 1024),
                })
                .await
            {
                Ok(attached) => attached,
                // Another app-server process can authoritatively hold the
                // rollout writer. Shared observation works only after that
                // process releases the session or when it is loaded by this
                // shared host; keep searching for an attachable stored thread.
                Err(DriverError::Rejected(message))
                    if message == "Codex rejected session attachment (code -32600)" =>
                {
                    continue;
                }
                Err(error) => panic!("unexpected real attachment failure: {error}"),
            };
            assert_eq!(attached.snapshot.session(), &session);
            connection
                .detach_session(DetachSessionRequest {
                    session,
                    attachment_id: attached.position.attachment_id,
                })
                .await
                .expect("detach real session");
            attached_one = true;
            break;
        }
        assert!(attached_one, "no stored Codex session was attachable");
        driver.shutdown().await.expect("detach shared client");
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    #[ignore = "loads a real stored Codex session across two private app-server epochs"]
    async fn installed_private_epochs_enforce_and_release_the_session_writer() {
        use crate::{
            CodexAppServerTransport, CodexLaunchConfig, CodexVersionPolicy, spawn_codex_driver,
        };
        use inline_agent_bridge::{
            AgentDriver, DriverError, ProviderSessionId, ResumeSessionSpec, SessionReplay,
        };

        fn launch_config() -> CodexLaunchConfig {
            CodexLaunchConfig {
                executable: "/Applications/ChatGPT.app/Contents/Resources/codex".into(),
                transport: CodexAppServerTransport::PrivateStdio,
                version_policy: CodexVersionPolicy::Compatible,
                incoming_capacity: 256,
                ..CodexLaunchConfig::default()
            }
        }

        let first = spawn_codex_driver(launch_config(), "exclusive-session-writer-test")
            .await
            .expect("start first private app-server");
        let any_page: crate::session_wire::ThreadListResponse = serde_json::from_value(
            first
                .driver
                .session_catalog_request(
                    "thread/list",
                    json!({
                        "limit": 20,
                        "sortKey": "updated_at",
                        "sortDirection": "desc",
                        "archived": false
                    }),
                )
                .await
                .expect("list stored sessions"),
        )
        .expect("stable list response");

        let mut owned_session = None;
        for stored in any_page.data {
            let spec = ResumeSessionSpec {
                session_id: ProviderSessionId::new(stored.id).expect("session id"),
                cwd: stored.cwd.into(),
                replay: SessionReplay::None,
            };
            match first.driver.resume_session(spec.clone()).await {
                Ok(()) => {
                    owned_session = Some(spec);
                    break;
                }
                Err(DriverError::SessionBusy(_)) => continue,
                Err(error) => panic!("unexpected first resume failure: {error}"),
            }
        }
        let owned_session = owned_session.expect("no stored Codex session was available");

        let second = spawn_codex_driver(launch_config(), "exclusive-session-writer-test")
            .await
            .expect("start second private app-server");
        assert!(matches!(
            second.driver.resume_session(owned_session.clone()).await,
            Err(DriverError::SessionBusy(message))
                if message == "Close this session in the other Codex app or CLI, then try again."
        ));

        first
            .driver
            .shutdown()
            .await
            .expect("release first private app-server");
        let mut resumed_after_release = false;
        for _ in 0..20 {
            match second.driver.resume_session(owned_session.clone()).await {
                Ok(()) => {
                    resumed_after_release = true;
                    break;
                }
                Err(DriverError::SessionBusy(_)) => {
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                }
                Err(error) => panic!("unexpected second resume failure: {error}"),
            }
        }
        assert!(
            resumed_after_release,
            "second private app-server did not acquire the released session writer"
        );
        second
            .driver
            .shutdown()
            .await
            .expect("stop second private app-server");
    }
}
