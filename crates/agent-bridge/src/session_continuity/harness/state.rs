//! Truthful run state of one session (spec §4.2 `RunState`).

use serde::{Deserialize, Serialize};

use super::{Event, HeldBy, InteractionKind, TurnPhase};

/// What a session is doing, as shown in the work bar and sidebar badges.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum RunState {
    /// No turn is running.
    Idle,
    /// A turn is running.
    Working,
    /// Blocked on someone or something.
    Waiting {
        /// What it waits for.
        on: WaitingOn,
    },
    /// An interrupt was sent and the turn has not ended yet.
    Stopping,
    /// Stopped by Inline's pause; only a direct mention, reply or Resume restarts it.
    Paused,
    /// Another client (terminal, ChatGPT or Claude app) holds the session.
    HeldElsewhere {
        /// Who holds it.
        by: HeldBy,
    },
    /// The machine or bridge is not connected.
    Offline,
    /// Not known yet. Never inferred idle from an unknown event.
    Unknown,
}

/// What a waiting session waits for.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum WaitingOn {
    /// An approval card.
    Approval,
    /// A question card.
    Question,
    /// A native dialog.
    Dialog,
    /// A usage or rate limit.
    Limit {
        /// Unix seconds when the limit resets, when known.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        resets_at: Option<i64>,
    },
    /// The runtime needs setup before it can continue.
    Setup {
        /// Why, with its fix.
        reason: SetupReason,
    },
}

/// Why a runtime needs setup, each with a fix the apps can offer.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "reason", rename_all = "snake_case")]
pub enum SetupReason {
    /// The harness is older than the core floor: "Update Codex/Claude".
    UpdateRuntime {
        /// Core floor version.
        min_version: String,
        /// Version found, when known.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        found: Option<String>,
    },
    /// The harness is newer than this bridge can parse: "Update Inline CLI".
    UpdateInline {
        /// What did not parse.
        detail: String,
    },
    /// The executable chosen at setup is missing.
    ExecutableMissing {
        /// Path chosen at setup.
        path: String,
    },
    /// The executable at the setup path changed identity; never a silent switch.
    ExecutableChanged {
        /// Path chosen at setup.
        path: String,
        /// What changed (version, signature, hash).
        detail: String,
    },
    /// The harness needs the owner to sign in on that machine.
    SignIn,
    /// The session's folder is not available on this machine.
    FolderUnavailable {
        /// Folder path.
        path: String,
    },
    /// Another typed harness startup failure (Claude `cli_version_too_old`,
    /// org or gateway reasons), kept with its native code.
    Harness {
        /// Native failure code.
        code: String,
        /// Human-readable message.
        message: String,
    },
}

/// Folds session events into a [`RunState`].
///
/// Explicit [`Event::State`] reports win. Otherwise only events whose meaning
/// is certain move the state; unknown items and notices never do.
#[derive(Clone, Debug)]
pub struct RunStateTracker {
    state: RunState,
    open_interactions: Vec<(super::InteractionId, WaitingOn)>,
    stopping: bool,
}

impl Default for RunStateTracker {
    fn default() -> Self {
        Self::new(RunState::Unknown)
    }
}

impl RunStateTracker {
    /// Starts from a known state.
    pub fn new(state: RunState) -> Self {
        Self {
            state,
            open_interactions: Vec::new(),
            stopping: false,
        }
    }

    /// The current state.
    pub fn state(&self) -> &RunState {
        &self.state
    }

    /// Marks that an interrupt was sent; the turn's end returns to idle.
    pub fn stopping(&mut self) -> &RunState {
        if matches!(self.state, RunState::Working | RunState::Waiting { .. }) {
            self.stopping = true;
            self.state = RunState::Stopping;
        }
        &self.state
    }

    /// Applies one event and returns the new state when it changed.
    pub fn apply(&mut self, event: &Event) -> Option<RunState> {
        let before = self.state.clone();
        match event {
            Event::State { state } => {
                self.state = state.clone();
                if !matches!(state, RunState::Waiting { .. }) {
                    self.open_interactions.clear();
                }
            }
            Event::Turn { phase, .. } => match phase {
                TurnPhase::Started { .. } => {
                    self.stopping = false;
                    if !matches!(self.state, RunState::Paused) {
                        self.state = RunState::Working;
                    }
                }
                TurnPhase::Completed { .. } => {
                    self.stopping = false;
                    self.open_interactions.clear();
                    if !matches!(self.state, RunState::Paused) {
                        self.state = RunState::Idle;
                    }
                }
            },
            Event::Interaction(interaction) => {
                let on = match &interaction.kind {
                    InteractionKind::Approval { .. } => WaitingOn::Approval,
                    InteractionKind::Question { form } if form.asynchronous => {
                        // An async question does not block the turn.
                        return None;
                    }
                    InteractionKind::Question { .. } => WaitingOn::Question,
                    InteractionKind::Dialog { .. } => WaitingOn::Dialog,
                };
                self.open_interactions
                    .push((interaction.id.clone(), on.clone()));
                if !self.stopping && !matches!(self.state, RunState::Paused) {
                    self.state = RunState::Waiting { on };
                }
            }
            Event::InteractionClosed { id, .. } => {
                self.open_interactions.retain(|(open, _)| open != id);
                if matches!(self.state, RunState::Waiting { .. }) {
                    self.state = match self.open_interactions.last() {
                        Some((_, on)) => RunState::Waiting { on: on.clone() },
                        None => RunState::Working,
                    };
                }
            }
            Event::Held { by: Some(by) } => {
                self.state = RunState::HeldElsewhere { by: by.clone() };
            }
            Event::Held { by: None } => {
                if matches!(self.state, RunState::HeldElsewhere { .. }) {
                    self.state = RunState::Idle;
                }
            }
            _ => {}
        }
        (self.state != before).then(|| self.state.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TurnOutcome;
    use crate::session_continuity::harness::{
        Decision, DecisionId, DecisionKind, Interaction, InteractionId, Item, ItemBody, ItemId,
        ItemUpdate,
    };

    fn turn_started() -> Event {
        Event::Turn {
            turn: crate::TurnId::new("t1").expect("turn"),
            phase: TurnPhase::Started { inputs: vec![] },
        }
    }

    fn approval(id: &str) -> Event {
        Event::Interaction(Interaction {
            id: InteractionId::new(id).expect("id"),
            turn: None,
            item: None,
            parent: None,
            kind: InteractionKind::Approval {
                subject: super::super::ApprovalSubject::Other {
                    title: "Run".to_owned(),
                    detail: None,
                },
                decisions: vec![Decision {
                    id: DecisionId::new("accept").expect("decision"),
                    label: "Yes, proceed".to_owned(),
                    kind: DecisionKind::Accept,
                    description: None,
                    accepts_message: false,
                    native: serde_json::Value::Null,
                }],
            },
            native: serde_json::Value::Null,
        })
    }

    #[test]
    fn interactions_wait_and_close_back_to_working() {
        let mut tracker = RunStateTracker::default();
        assert_eq!(tracker.apply(&turn_started()), Some(RunState::Working));
        assert_eq!(
            tracker.apply(&approval("a1")),
            Some(RunState::Waiting {
                on: WaitingOn::Approval
            })
        );
        assert_eq!(
            tracker.apply(&Event::InteractionClosed {
                id: InteractionId::new("a1").expect("id"),
                by: super::super::ClosedBy::External,
            }),
            Some(RunState::Working)
        );
        assert_eq!(
            tracker.apply(&Event::Turn {
                turn: crate::TurnId::new("t1").expect("turn"),
                phase: TurnPhase::Completed {
                    outcome: TurnOutcome::Completed,
                    inputs_consumed: vec![],
                    error: None,
                    duration_ms: None,
                },
            }),
            Some(RunState::Idle)
        );
    }

    #[test]
    fn unknown_items_never_move_the_state() {
        let mut tracker = RunStateTracker::new(RunState::Working);
        let unknown = Event::Item(Item::new(
            ItemId::new("x").expect("id"),
            None,
            ItemUpdate::Completed {
                body: ItemBody::Unknown {
                    native_type: "futureThing".to_owned(),
                    summary: None,
                },
                status: super::super::ItemStatus::Completed,
            },
            serde_json::Value::Null,
        ));
        assert_eq!(tracker.apply(&unknown), None);
        assert_eq!(tracker.state(), &RunState::Working);
    }

    #[test]
    fn pause_survives_turn_end_and_interrupts_show_stopping() {
        let mut tracker = RunStateTracker::new(RunState::Working);
        assert_eq!(tracker.stopping(), &RunState::Stopping);
        tracker.apply(&Event::State {
            state: RunState::Paused,
        });
        tracker.apply(&Event::Turn {
            turn: crate::TurnId::new("t1").expect("turn"),
            phase: TurnPhase::Completed {
                outcome: TurnOutcome::Interrupted,
                inputs_consumed: vec![],
                error: None,
                duration_ms: None,
            },
        });
        assert_eq!(tracker.state(), &RunState::Paused);
    }
}
