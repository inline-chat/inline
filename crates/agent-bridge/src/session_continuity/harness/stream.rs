//! Sequencing and fan-out for session streams.
//!
//! [`EventHub`] is what drivers emit into: it stamps each event with the next
//! sequence number and fans it out to every subscriber. A subscriber that
//! falls behind gets one [`Event::Gap`] instead of silently missing events.
//! [`StreamCursor`] is the consumer side: it accepts the next sequence,
//! ignores duplicates and reports gaps so the journal can repair.

use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::sync::broadcast;

use super::{Envelope, Event, EventStream, SessionKey};
use crate::SessionCheckpoint;

/// Default number of envelopes a slow subscriber may lag before a gap.
pub const DEFAULT_HUB_CAPACITY: usize = 4096;

/// Sequenced fan-out for one session stream.
#[derive(Debug)]
pub struct EventHub {
    key: SessionKey,
    sender: broadcast::Sender<Envelope>,
    state: Mutex<HubState>,
}

#[derive(Debug)]
struct HubState {
    next_seq: u64,
    checkpoint: Option<SessionCheckpoint>,
    /// Receives from the hub's creation, for the first subscriber: a driver
    /// can emit while opening (resume can start a turn or ask for approval)
    /// before anyone has called `events()`.
    initial: Option<(broadcast::Receiver<Envelope>, u64)>,
}

impl EventHub {
    /// A hub whose first event gets sequence 1.
    pub fn new(key: SessionKey, capacity: usize) -> Self {
        Self::starting_after(key, capacity, 0)
    }

    /// A hub that continues after `last_seq` (reattach after a journal replay).
    pub fn starting_after(key: SessionKey, capacity: usize, last_seq: u64) -> Self {
        let (sender, receiver) = broadcast::channel(capacity.max(16));
        let first = last_seq.saturating_add(1);
        Self {
            key,
            sender,
            state: Mutex::new(HubState {
                next_seq: first,
                checkpoint: None,
                initial: Some((receiver, first)),
            }),
        }
    }

    /// The session this hub serves.
    pub fn key(&self) -> &SessionKey {
        &self.key
    }

    /// Records the native resume cursor carried by later envelopes.
    pub fn set_checkpoint(&self, checkpoint: Option<SessionCheckpoint>) {
        self.state.lock().expect("event hub poisoned").checkpoint = checkpoint;
    }

    /// Sequences and publishes one event, returning its envelope.
    pub fn emit(&self, event: Event) -> Envelope {
        let mut state = self.state.lock().expect("event hub poisoned");
        let envelope = Envelope {
            session: self.key.clone(),
            seq: state.next_seq,
            checkpoint: state.checkpoint.clone(),
            at_ms: now_ms(),
            event,
        };
        state.next_seq = state.next_seq.saturating_add(1);
        // Sending while holding the lock keeps fan-out order equal to sequence order.
        let _ = self.sender.send(envelope.clone());
        envelope
    }

    /// Sequence the next event will get.
    pub fn next_seq(&self) -> u64 {
        self.state.lock().expect("event hub poisoned").next_seq
    }

    /// Subscribes from the next event on.
    /// A stream of envelopes. The first subscriber also gets everything
    /// emitted since the hub was created; later ones start now.
    pub fn subscribe(&self) -> EventStream {
        let (receiver, expected) = {
            let mut state = self.state.lock().expect("event hub poisoned");
            match state.initial.take() {
                Some(initial) => initial,
                None => (self.sender.subscribe(), state.next_seq),
            }
        };
        let key = self.key.clone();
        Box::pin(futures_util::stream::unfold(
            (receiver, key, expected, None::<Envelope>),
            |(mut receiver, key, expected, pending)| async move {
                if let Some(envelope) = pending {
                    let next = envelope.seq.saturating_add(1);
                    return Some((envelope, (receiver, key, next, None)));
                }
                match receiver.recv().await {
                    Ok(envelope) => {
                        let next = envelope.seq.saturating_add(1);
                        Some((envelope, (receiver, key, next, None)))
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        // Resume at the oldest retained envelope: report the hole
                        // first, then deliver that envelope.
                        let envelope = receiver.recv().await.ok()?;
                        let gap = Envelope {
                            session: key.clone(),
                            seq: envelope.seq,
                            checkpoint: envelope.checkpoint.clone(),
                            at_ms: envelope.at_ms,
                            event: Event::Gap {
                                expected,
                                actual: envelope.seq,
                            },
                        };
                        Some((gap, (receiver, key, expected, Some(envelope))))
                    }
                    Err(broadcast::error::RecvError::Closed) => None,
                }
            },
        ))
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

/// Consumer-side sequence check.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StreamCursor {
    last: u64,
}

/// Result of checking one envelope against a [`StreamCursor`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CursorStep {
    /// The next sequence: apply it.
    Next,
    /// Already applied: skip it.
    Duplicate,
    /// Events were lost: repair from a snapshot before applying.
    Gap {
        /// Sequence expected.
        expected: u64,
        /// Sequence received.
        actual: u64,
    },
}

impl StreamCursor {
    /// A cursor that has applied everything through `last` (0 = nothing).
    pub fn after(last: u64) -> Self {
        Self { last }
    }

    /// Last applied sequence.
    pub fn last(&self) -> u64 {
        self.last
    }

    /// Checks an envelope and advances on [`CursorStep::Next`]. A gap event
    /// from the hub is itself reported as a gap.
    pub fn observe(&mut self, envelope: &Envelope) -> CursorStep {
        if let Event::Gap { expected, actual } = envelope.event {
            self.last = actual.saturating_sub(1);
            return CursorStep::Gap { expected, actual };
        }
        let expected = self.last.saturating_add(1);
        if envelope.seq < expected {
            CursorStep::Duplicate
        } else if envelope.seq == expected {
            self.last = envelope.seq;
            CursorStep::Next
        } else {
            let step = CursorStep::Gap {
                expected,
                actual: envelope.seq,
            };
            self.last = envelope.seq;
            step
        }
    }
}

#[cfg(test)]
mod tests {
    use futures_util::StreamExt;

    use super::*;
    use crate::session_continuity::harness::{Notice, NoticeLevel, RunState};
    use crate::{ProviderId, ProviderSessionId};

    fn key() -> SessionKey {
        SessionKey {
            provider: ProviderId::new("codex").expect("provider"),
            session: ProviderSessionId::new("thread-1").expect("session"),
        }
    }

    fn notice(code: &str) -> Event {
        Event::Notice(Notice {
            level: NoticeLevel::Info,
            code: code.to_owned(),
            message: None,
            native: serde_json::Value::Null,
        })
    }

    #[tokio::test]
    async fn subscribers_see_strictly_increasing_sequences() {
        let hub = EventHub::new(key(), 16);
        let mut stream = hub.subscribe();
        hub.emit(Event::State {
            state: RunState::Working,
        });
        hub.emit(notice("a"));
        let first = stream.next().await.expect("first");
        let second = stream.next().await.expect("second");
        assert_eq!((first.seq, second.seq), (1, 2));
        let mut cursor = StreamCursor::after(0);
        assert_eq!(cursor.observe(&first), CursorStep::Next);
        assert_eq!(cursor.observe(&second), CursorStep::Next);
        assert_eq!(cursor.observe(&first), CursorStep::Duplicate);
    }

    #[tokio::test]
    async fn the_first_subscriber_sees_events_emitted_while_opening() {
        let hub = EventHub::new(key(), 16);
        hub.emit(notice("during-open"));
        let mut first = hub.subscribe();
        let mut later = hub.subscribe();
        hub.emit(notice("after"));
        assert_eq!(first.next().await.expect("early").seq, 1);
        assert_eq!(first.next().await.expect("late").seq, 2);
        assert_eq!(later.next().await.expect("late only").seq, 2);
    }

    #[tokio::test]
    async fn a_lagging_subscriber_gets_a_gap_marker() {
        let hub = EventHub::new(key(), 16);
        let mut stream = hub.subscribe();
        for index in 0..40 {
            hub.emit(notice(&format!("n{index}")));
        }
        let gap = stream.next().await.expect("gap");
        match gap.event {
            Event::Gap { expected, actual } => {
                assert_eq!(expected, 1);
                assert!(actual > 1);
            }
            other => panic!("expected gap, got {other:?}"),
        }
        let mut cursor = StreamCursor::after(0);
        assert!(matches!(cursor.observe(&gap), CursorStep::Gap { .. }));
        let next = stream.next().await.expect("next after gap");
        assert_eq!(cursor.observe(&next), CursorStep::Next);
    }

    #[test]
    fn cursor_reports_skipped_sequences() {
        let hub = EventHub::starting_after(key(), 16, 9);
        assert_eq!(hub.next_seq(), 10);
        let envelope = hub.emit(notice("x"));
        let mut cursor = StreamCursor::after(7);
        assert_eq!(
            cursor.observe(&envelope),
            CursorStep::Gap {
                expected: 8,
                actual: 10
            }
        );
        assert_eq!(cursor.last(), 10);
    }
}
