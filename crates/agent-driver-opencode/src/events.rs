//! One event connection to the OpenCode service, routed per session.
//!
//! `GET /api/event` is a single SSE stream for the whole service. The bus
//! keeps it open, reconnecting with backoff, and routes each event to the
//! session it names (`data.sessionID`, or `data.form.sessionID` for forms).
//! Sub-agent sessions are children of the session that started them
//! (`session.created` with `parentID`); their events go to the parent, which
//! shows them as child work.
//!
//! The stream is volatile: OpenCode drops a slow subscriber rather than
//! buffering without bound. After every reconnect the bus tells each session
//! to resync, and the session replays the durable log after the last
//! sequence it saw (`/api/experimental/session/{id}/log?after=`). Streaming
//! deltas lost in the gap are covered by the authoritative `*.ended` and
//! `tool.success` snapshots the log keeps.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use futures_util::StreamExt;
use serde_json::Value;
use tokio::sync::{mpsc, watch};

use crate::api::Query;
use crate::link::Link;

const RECONNECT_MIN: Duration = Duration::from_millis(250);
const RECONNECT_MAX: Duration = Duration::from_secs(10);
/// Child links kept for sub-agent sessions, oldest dropped first.
const MAX_CHILDREN: usize = 4096;

/// What a session receives from the bus.
#[derive(Debug, Clone)]
pub enum BusMessage {
    /// One event for the session or one of its children.
    Event(Value),
    /// The stream reconnected; events may have been lost meanwhile.
    Resync,
    /// The service is unreachable right now.
    Disconnected,
}

/// Service-wide notices (catalog changes, service shutdown).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServiceSignal {
    /// Models, agents, commands, skills or config changed.
    CatalogChanged,
    /// The service is shutting down a location or itself.
    Shutdown,
}

/// The routed event connection.
pub struct EventBus {
    routes: Mutex<Routes>,
    connected: watch::Sender<bool>,
    signals: tokio::sync::broadcast::Sender<ServiceSignal>,
    stop: watch::Sender<bool>,
}

#[derive(Default)]
struct Routes {
    sessions: HashMap<String, mpsc::UnboundedSender<BusMessage>>,
    /// Registration generation per session: only the latest may unregister.
    generations: HashMap<String, u64>,
    next_generation: u64,
    /// child session -> parent session
    parents: HashMap<String, String>,
    order: std::collections::VecDeque<String>,
}

impl Routes {
    fn link(&mut self, child: &str, parent: &str) {
        if self
            .parents
            .insert(child.to_owned(), parent.to_owned())
            .is_none()
        {
            self.order.push_back(child.to_owned());
            while self.order.len() > MAX_CHILDREN {
                if let Some(oldest) = self.order.pop_front() {
                    self.parents.remove(&oldest);
                }
            }
        }
    }

    /// The registered session an event for `session` belongs to.
    fn owner(&self, session: &str) -> Option<&String> {
        let mut current = session;
        // Children of children (a sub-agent starting its own sub-agent).
        for _ in 0..8 {
            if self.sessions.contains_key(current) {
                return self.sessions.get_key_value(current).map(|(key, _)| key);
            }
            current = self.parents.get(current)?;
        }
        None
    }
}

impl EventBus {
    /// Starts the connection task.
    pub fn start(link: Arc<Link>) -> Arc<Self> {
        let (connected, _) = watch::channel(false);
        let (signals, _) = tokio::sync::broadcast::channel(64);
        let (stop, stopped) = watch::channel(false);
        let bus = Arc::new(Self {
            routes: Mutex::new(Routes::default()),
            connected,
            signals,
            stop,
        });
        tokio::spawn(run(Arc::downgrade(&bus), link, stopped));
        bus
    }

    fn routes(&self) -> std::sync::MutexGuard<'_, Routes> {
        self.routes
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    /// Routes events for `session` (and its children) to a new receiver,
    /// replacing an earlier registration. The generation names this
    /// registration for [`Self::unregister`].
    pub fn register(&self, session: &str) -> (mpsc::UnboundedReceiver<BusMessage>, u64) {
        let (sender, receiver) = mpsc::unbounded_channel();
        let mut routes = self.routes();
        routes.next_generation += 1;
        let generation = routes.next_generation;
        routes.sessions.insert(session.to_owned(), sender);
        routes.generations.insert(session.to_owned(), generation);
        (receiver, generation)
    }

    /// Records a sub-agent session under its parent before its events arrive.
    pub fn link_child(&self, child: &str, parent: &str) {
        self.routes().link(child, parent);
    }

    /// Stops routing events for `session`, unless a newer registration
    /// replaced this one.
    pub fn unregister(&self, session: &str, generation: u64) {
        let mut routes = self.routes();
        if routes.generations.get(session) == Some(&generation) {
            routes.sessions.remove(session);
            routes.generations.remove(session);
        }
    }

    /// Whether the stream is connected now.
    pub fn is_connected(&self) -> bool {
        *self.connected.borrow()
    }

    /// Waits until the stream is connected or the timeout passes.
    pub async fn wait_connected(&self, timeout: Duration) -> bool {
        let mut receiver = self.connected.subscribe();
        tokio::time::timeout(timeout, receiver.wait_for(|connected| *connected))
            .await
            .is_ok_and(|result| result.is_ok())
    }

    /// Service-wide signals.
    pub fn signals(&self) -> tokio::sync::broadcast::Receiver<ServiceSignal> {
        self.signals.subscribe()
    }

    /// Closes the connection.
    pub fn shutdown(&self) {
        let _ = self.stop.send(true);
    }

    fn dispatch(&self, event: Value) {
        let kind = event
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        match kind {
            "model.updated"
            | "agent.updated"
            | "command.updated"
            | "skill.updated"
            | "config.updated"
            | "provider.updated"
            | "credential.updated"
            | "credential.switched"
            | "models-dev.refreshed" => {
                let _ = self.signals.send(ServiceSignal::CatalogChanged);
                return;
            }
            "location.shutdown" => {
                let _ = self.signals.send(ServiceSignal::Shutdown);
                return;
            }
            _ => {}
        }
        let Some(session) = session_of(&event) else {
            return;
        };
        let mut routes = self.routes();
        if kind == "session.created"
            && let Some(parent) = event.pointer("/data/parentID").and_then(Value::as_str)
        {
            routes.link(&session, parent);
        }
        let Some(owner) = routes.owner(&session).cloned() else {
            return;
        };
        if let Some(sender) = routes.sessions.get(&owner)
            && sender.send(BusMessage::Event(event)).is_err()
        {
            routes.sessions.remove(&owner);
        }
    }

    fn broadcast(&self, message: BusMessage) {
        let mut routes = self.routes();
        routes
            .sessions
            .retain(|_, sender| sender.send(message.clone()).is_ok());
    }
}

impl Drop for EventBus {
    fn drop(&mut self) {
        let _ = self.stop.send(true);
    }
}

/// The session an event belongs to.
pub fn session_of(event: &Value) -> Option<String> {
    event
        .pointer("/data/sessionID")
        .or_else(|| event.pointer("/data/form/sessionID"))
        .or_else(|| {
            event.pointer("/data/info/id").filter(|_| {
                event
                    .get("type")
                    .and_then(Value::as_str)
                    .is_some_and(|kind| kind.starts_with("session."))
            })
        })
        .and_then(Value::as_str)
        .map(str::to_owned)
}

/// Failed connections before the link looks for a restarted service.
const REDISCOVER_AFTER: u32 = 3;

async fn run(bus: Weak<EventBus>, link: Arc<Link>, mut stopped: watch::Receiver<bool>) {
    let mut delay = RECONNECT_MIN;
    let mut first = true;
    let mut failures = 0u32;
    loop {
        if *stopped.borrow() {
            return;
        }
        if failures >= REDISCOVER_AFTER {
            failures = 0;
            match link.rediscover().await {
                Ok(true) => {
                    log::info!(target: "inline::opencode", "OpenCode service moved; reconnecting")
                }
                Ok(false) => {}
                Err(error) => {
                    log::warn!(target: "inline::opencode", "OpenCode service unavailable: {error}")
                }
            }
        }
        let connection = link.api().sse("api/event", Query::new()).await;
        match connection {
            Ok(stream) => {
                let mut stream = Box::pin(stream);
                let mut announced = false;
                loop {
                    let next = tokio::select! {
                        _ = async { let _ = stopped.wait_for(|stop| *stop).await; } => return,
                        next = stream.next() => next,
                    };
                    let Some(bus) = bus.upgrade() else { return };
                    match next {
                        Some(Ok(event)) => {
                            if !announced {
                                failures = 0;
                                // The first event (`server.connected`) proves
                                // the subscription is live; anything after it
                                // reaches us, so a resync now is complete.
                                announced = true;
                                delay = RECONNECT_MIN;
                                let _ = bus.connected.send(true);
                                if !first {
                                    bus.broadcast(BusMessage::Resync);
                                }
                                first = false;
                            }
                            bus.dispatch(event);
                        }
                        Some(Err(error)) => {
                            log::debug!(target: "inline::opencode", "event stream error: {error}");
                            break;
                        }
                        None => break,
                    }
                }
            }
            Err(error) => {
                log::debug!(target: "inline::opencode", "event stream unavailable: {error}");
            }
        }
        failures += 1;
        if let Some(bus) = bus.upgrade() {
            if bus.connected.send_replace(false) {
                bus.broadcast(BusMessage::Disconnected);
            }
        } else {
            return;
        }
        tokio::select! {
            _ = async { let _ = stopped.wait_for(|stop| *stop).await; } => return,
            _ = tokio::time::sleep(delay) => {}
        }
        delay = (delay * 2).min(RECONNECT_MAX);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn events_name_their_session() {
        assert_eq!(
            session_of(&json!({"type": "session.text.delta", "data": {"sessionID": "ses_a"}}))
                .as_deref(),
            Some("ses_a")
        );
        assert_eq!(
            session_of(&json!({"type": "form.created", "data": {"form": {"sessionID": "ses_b"}}}))
                .as_deref(),
            Some("ses_b")
        );
        assert!(session_of(&json!({"type": "server.connected", "data": {}})).is_none());
    }

    #[test]
    fn children_route_to_their_registered_ancestor() {
        let mut routes = Routes::default();
        let (sender, _receiver) = mpsc::unbounded_channel();
        routes.sessions.insert("ses_parent".into(), sender);
        routes.link("ses_child", "ses_parent");
        routes.link("ses_grandchild", "ses_child");
        assert_eq!(
            routes.owner("ses_grandchild").map(String::as_str),
            Some("ses_parent")
        );
        assert_eq!(
            routes.owner("ses_parent").map(String::as_str),
            Some("ses_parent")
        );
        assert!(routes.owner("ses_other").is_none());
    }
}
