//! Moving a work's publication into a subthread (spec §5.2, §7).
//!
//! `inline.subthread.start` creates the subthread, then asks the server to
//! move the work's canonical publication chat (`MOVE_AGENT_SESSION`). The
//! native session and delivery ledger are unchanged. The output boundary:
//! from the request on, nothing publishes anywhere; held output goes out in
//! the destination once the server confirms, so a retry never publishes in
//! both chats. The source chat keeps one status card linking to the subthread,
//! which later shows the summary. A rejected move publishes the held output in
//! the source instead. An unknown outcome stays fenced and retries; the server
//! operation is idempotent (`moved: false` on a repeat).

use serde::{Deserialize, Serialize};

use crate::harness::ChatId;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PublicationState {
    Publishing {
        chat: ChatId,
        /// The chat holding this work's status card, once moved.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        parent: Option<ChatId>,
    },
    Moving {
        from: ChatId,
        to: ChatId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        parent: Option<ChatId>,
        /// Output produced while the move is unconfirmed, in order.
        held: Vec<String>,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PublicationEvent {
    /// The subthread exists; move the work into it.
    MoveRequested { destination: ChatId },
    /// The server confirmed (`moved` is false on an idempotent repeat).
    MoveConfirmed { destination: ChatId, moved: bool },
    /// The server rejected the move (no access, not a subthread, ...).
    MoveRejected { reason: String },
    /// No answer or a lost reply: the outcome is unknown.
    MoveUnknown,
    /// A session-state update whose peer is a different chat: another client
    /// moved the work.
    RemoteMoved { destination: ChatId },
    /// Something the renderer wants to publish, by its stable output key.
    Output { key: String },
    /// The work's summary for the parent's status card.
    Summary { text: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PublicationEffect {
    /// `MOVE_AGENT_SESSION` to `destination`; also used for retries.
    CallMove {
        destination: ChatId,
    },
    Publish {
        chat: ChatId,
        key: String,
    },
    /// One status card in the source chat linking to the subthread.
    PostParentStatus {
        parent: ChatId,
        subthread: ChatId,
    },
    UpdateParentStatus {
        parent: ChatId,
        summary: String,
    },
    /// Tell the agent (tool result) the move did not happen.
    MoveFailed {
        reason: String,
    },
    /// A second move while one is in flight is refused.
    MoveBusy,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Publication {
    state: PublicationState,
}

impl Publication {
    pub fn new(chat: ChatId) -> Self {
        Self {
            state: PublicationState::Publishing { chat, parent: None },
        }
    }

    pub fn state(&self) -> &PublicationState {
        &self.state
    }

    /// The chat output goes to now, or `None` while a move is fenced.
    pub fn chat(&self) -> Option<ChatId> {
        match self.state {
            PublicationState::Publishing { chat, .. } => Some(chat),
            PublicationState::Moving { .. } => None,
        }
    }

    pub fn handle(&mut self, event: PublicationEvent) -> Vec<PublicationEffect> {
        use PublicationEffect as F;
        use PublicationEvent as E;
        use PublicationState as S;
        let mut effects = Vec::new();
        let state = self.state.clone();
        self.state = match (state, event) {
            (S::Publishing { chat, parent }, E::Output { key }) => {
                effects.push(F::Publish { chat, key });
                S::Publishing { chat, parent }
            }
            (S::Publishing { chat, parent }, E::MoveRequested { destination }) => {
                if destination == chat {
                    S::Publishing { chat, parent }
                } else {
                    effects.push(F::CallMove { destination });
                    S::Moving {
                        from: chat,
                        to: destination,
                        parent,
                        held: Vec::new(),
                    }
                }
            }
            (S::Publishing { chat, parent }, E::RemoteMoved { destination }) => {
                if destination == chat {
                    S::Publishing { chat, parent }
                } else {
                    effects.push(F::PostParentStatus {
                        parent: chat,
                        subthread: destination,
                    });
                    S::Publishing {
                        chat: destination,
                        parent: Some(chat),
                    }
                }
            }
            (
                S::Moving { from, to, held, .. },
                E::MoveConfirmed { destination, .. } | E::RemoteMoved { destination },
            ) if destination == to => {
                effects.push(F::PostParentStatus {
                    parent: from,
                    subthread: to,
                });
                effects.extend(held.into_iter().map(|key| F::Publish { chat: to, key }));
                S::Publishing {
                    chat: to,
                    parent: Some(from),
                }
            }
            (
                S::Moving {
                    from, parent, held, ..
                },
                E::MoveRejected { reason },
            ) => {
                effects.push(F::MoveFailed { reason });
                effects.extend(held.into_iter().map(|key| F::Publish { chat: from, key }));
                S::Publishing { chat: from, parent }
            }
            (state @ S::Moving { .. }, E::MoveUnknown) => {
                if let S::Moving { to, .. } = &state {
                    effects.push(F::CallMove { destination: *to });
                }
                state
            }
            (
                S::Moving {
                    from,
                    to,
                    parent,
                    mut held,
                },
                E::Output { key },
            ) => {
                held.push(key);
                S::Moving {
                    from,
                    to,
                    parent,
                    held,
                }
            }
            (state @ S::Moving { .. }, E::MoveRequested { .. }) => {
                effects.push(F::MoveBusy);
                state
            }
            (
                S::Publishing {
                    chat,
                    parent: Some(parent),
                },
                E::Summary { text },
            ) => {
                effects.push(F::UpdateParentStatus {
                    parent,
                    summary: text,
                });
                S::Publishing {
                    chat,
                    parent: Some(parent),
                }
            }
            (state, _) => state,
        };
        effects
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PARENT: ChatId = ChatId(1);
    const SUB: ChatId = ChatId(2);

    fn output(key: &str) -> PublicationEvent {
        PublicationEvent::Output { key: key.into() }
    }

    fn publish(chat: ChatId, key: &str) -> PublicationEffect {
        PublicationEffect::Publish {
            chat,
            key: key.into(),
        }
    }

    #[test]
    fn output_is_fenced_during_the_move_and_published_once_in_the_destination() {
        let mut work = Publication::new(PARENT);
        assert_eq!(work.handle(output("a")), [publish(PARENT, "a")]);
        assert_eq!(
            work.handle(PublicationEvent::MoveRequested { destination: SUB }),
            [PublicationEffect::CallMove { destination: SUB }]
        );
        assert_eq!(work.chat(), None);
        assert!(work.handle(output("b")).is_empty());
        assert!(work.handle(output("c")).is_empty());
        assert_eq!(
            work.handle(PublicationEvent::MoveConfirmed {
                destination: SUB,
                moved: true
            }),
            [
                PublicationEffect::PostParentStatus {
                    parent: PARENT,
                    subthread: SUB
                },
                publish(SUB, "b"),
                publish(SUB, "c")
            ]
        );
        assert_eq!(work.chat(), Some(SUB));
        assert_eq!(work.handle(output("d")), [publish(SUB, "d")]);
        assert_eq!(
            work.handle(PublicationEvent::Summary {
                text: "Done: 3 fixes".into()
            }),
            [PublicationEffect::UpdateParentStatus {
                parent: PARENT,
                summary: "Done: 3 fixes".into()
            }]
        );
    }

    #[test]
    fn unknown_outcomes_stay_fenced_and_retry_idempotently() {
        let mut work = Publication::new(PARENT);
        work.handle(PublicationEvent::MoveRequested { destination: SUB });
        work.handle(output("b"));
        assert_eq!(
            work.handle(PublicationEvent::MoveUnknown),
            [PublicationEffect::CallMove { destination: SUB }]
        );
        assert_eq!(work.chat(), None);
        // The retry finds it already moved: still confirmed, still one card.
        let effects = work.handle(PublicationEvent::MoveConfirmed {
            destination: SUB,
            moved: false,
        });
        assert_eq!(
            effects
                .iter()
                .filter(|effect| matches!(effect, PublicationEffect::PostParentStatus { .. }))
                .count(),
            1
        );
        assert!(effects.contains(&publish(SUB, "b")));
        assert!(!effects.contains(&publish(PARENT, "b")));
        // A late duplicate confirmation changes nothing.
        assert!(
            work.handle(PublicationEvent::MoveConfirmed {
                destination: SUB,
                moved: false
            })
            .is_empty()
        );
    }

    #[test]
    fn a_rejected_move_publishes_held_output_in_the_source() {
        let mut work = Publication::new(PARENT);
        work.handle(PublicationEvent::MoveRequested { destination: SUB });
        work.handle(output("b"));
        assert_eq!(
            work.handle(PublicationEvent::MoveRejected {
                reason: "no access".into()
            }),
            [
                PublicationEffect::MoveFailed {
                    reason: "no access".into()
                },
                publish(PARENT, "b")
            ]
        );
        assert_eq!(work.chat(), Some(PARENT));
    }

    #[test]
    fn one_move_at_a_time_and_moving_to_itself_is_a_no_op() {
        let mut work = Publication::new(PARENT);
        assert!(
            work.handle(PublicationEvent::MoveRequested {
                destination: PARENT
            })
            .is_empty()
        );
        work.handle(PublicationEvent::MoveRequested { destination: SUB });
        assert_eq!(
            work.handle(PublicationEvent::MoveRequested {
                destination: ChatId(3)
            }),
            [PublicationEffect::MoveBusy]
        );
    }

    #[test]
    fn a_move_made_elsewhere_is_followed() {
        let mut work = Publication::new(PARENT);
        assert_eq!(
            work.handle(PublicationEvent::RemoteMoved { destination: SUB }),
            [PublicationEffect::PostParentStatus {
                parent: PARENT,
                subthread: SUB
            }]
        );
        assert_eq!(work.chat(), Some(SUB));
        // A summary without a parent card has nowhere to go.
        let mut fresh = Publication::new(PARENT);
        assert!(
            fresh
                .handle(PublicationEvent::Summary { text: "x".into() })
                .is_empty()
        );
    }

    #[test]
    fn state_round_trips_for_the_journal() {
        let mut work = Publication::new(PARENT);
        work.handle(PublicationEvent::MoveRequested { destination: SUB });
        work.handle(output("b"));
        let back: Publication =
            serde_json::from_str(&serde_json::to_string(&work).unwrap()).unwrap();
        assert_eq!(back, work);
    }
}
