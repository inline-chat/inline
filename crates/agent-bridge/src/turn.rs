use std::collections::VecDeque;

use serde::{Deserialize, Serialize};

use crate::{Direction, DirectionId, QueueItemId, SteeringSupport, TurnId};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RunState {
    Idle,
    Starting {
        direction_id: DirectionId,
        stop_requested: bool,
    },
    Running {
        turn_id: TurnId,
    },
    Stopping {
        turn_id: TurnId,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DirectionDisposition {
    Started,
    Steered,
    Queued,
    QueuedBecauseSteeringUnsupported,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Acknowledgement {
    Working,
    Steering,
    Queued,
    QueuedBecauseSteeringUnsupported,
    StartingQueued,
    Stopping,
    NothingRunning,
    RemovedFromQueue,
    AlreadyStarted,
}

impl Acknowledgement {
    /// Stable Inline-native copy shared by slash-command and settings surfaces.
    pub const fn message(self) -> &'static str {
        match self {
            Self::Working => crate::WORKING_STATUS,
            Self::Steering => "Steering the current run.",
            Self::Queued => "Queued for next.",
            Self::QueuedBecauseSteeringUnsupported => {
                "This agent can't steer, so I queued that for next."
            }
            Self::StartingQueued => "Starting the next queued request.",
            Self::Stopping => "Stop requested.",
            Self::NothingRunning => "Nothing is running.",
            Self::RemovedFromQueue => "Removed from queue.",
            Self::AlreadyStarted => "Already started.",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CoordinatorEffect {
    Acknowledge {
        acknowledgement: Acknowledgement,
    },
    StartTurn {
        direction: Direction,
    },
    SteerTurn {
        turn_id: TurnId,
        direction: Direction,
    },
    PersistQueue {
        queue_id: QueueItemId,
        direction: Direction,
    },
    CancelTurn {
        turn_id: TurnId,
    },
    RemoveQueue {
        queue_id: QueueItemId,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct QueuedDirection {
    queue_id: QueueItemId,
    direction: Direction,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnCoordinator {
    state: RunState,
    queue: VecDeque<QueuedDirection>,
}

impl Default for TurnCoordinator {
    fn default() -> Self {
        Self {
            state: RunState::Idle,
            queue: VecDeque::new(),
        }
    }
}

impl TurnCoordinator {
    /// Reconstructs the in-memory decision state for a provider turn whose
    /// durable inbox record has already been attached to `turn_id`.
    pub fn running(turn_id: TurnId) -> Self {
        Self {
            state: RunState::Running { turn_id },
            queue: VecDeque::new(),
        }
    }

    pub fn state(&self) -> &RunState {
        &self.state
    }

    pub fn queue_len(&self) -> usize {
        self.queue.len()
    }

    pub fn has_queued_direction(&self, queue_id: &QueueItemId) -> bool {
        self.queue.iter().any(|queued| &queued.queue_id == queue_id)
    }

    /// Mirrors a successful durable attachment enrichment into the in-memory
    /// queue without allowing a duplicate delivery to replace prior content.
    pub fn enrich_queued_attachments(
        &mut self,
        queue_id: &QueueItemId,
        direction: &Direction,
    ) -> bool {
        let Some(queued) = self
            .queue
            .iter_mut()
            .find(|queued| &queued.queue_id == queue_id)
        else {
            return false;
        };
        if queued.direction.id != direction.id
            || !queued.direction.attachments.is_empty()
            || direction.attachments.is_empty()
        {
            return false;
        }
        queued.direction.attachments = direction.attachments.clone();
        true
    }

    pub fn accept_direction(
        &mut self,
        direction: Direction,
        explicit_queue: bool,
        steering: SteeringSupport,
        queue_id: QueueItemId,
    ) -> (DirectionDisposition, Vec<CoordinatorEffect>) {
        if matches!(self.state, RunState::Idle) {
            self.state = RunState::Starting {
                direction_id: direction.id.clone(),
                stop_requested: false,
            };
            return (
                DirectionDisposition::Started,
                vec![
                    CoordinatorEffect::Acknowledge {
                        acknowledgement: Acknowledgement::Working,
                    },
                    CoordinatorEffect::StartTurn { direction },
                ],
            );
        }

        if !explicit_queue
            && matches!(self.state, RunState::Running { .. })
            && !matches!(steering, SteeringSupport::Unsupported)
        {
            let RunState::Running { turn_id } = &self.state else {
                unreachable!("running state checked above")
            };
            return (
                DirectionDisposition::Steered,
                vec![
                    CoordinatorEffect::Acknowledge {
                        acknowledgement: Acknowledgement::Steering,
                    },
                    CoordinatorEffect::SteerTurn {
                        turn_id: turn_id.clone(),
                        direction,
                    },
                ],
            );
        }

        let unsupported_fallback = !explicit_queue
            && matches!(self.state, RunState::Running { .. })
            && matches!(steering, SteeringSupport::Unsupported);
        if !self.has_queued_direction(&queue_id) {
            self.queue.push_back(QueuedDirection {
                queue_id: queue_id.clone(),
                direction: direction.clone(),
            });
        }
        let acknowledgement = if unsupported_fallback {
            Acknowledgement::QueuedBecauseSteeringUnsupported
        } else {
            Acknowledgement::Queued
        };
        let disposition = if unsupported_fallback {
            DirectionDisposition::QueuedBecauseSteeringUnsupported
        } else {
            DirectionDisposition::Queued
        };
        (
            disposition,
            vec![
                CoordinatorEffect::Acknowledge { acknowledgement },
                CoordinatorEffect::PersistQueue {
                    queue_id,
                    direction,
                },
            ],
        )
    }

    pub fn mark_turn_started(&mut self, turn_id: TurnId) -> Vec<CoordinatorEffect> {
        match &self.state {
            RunState::Starting { stop_requested, .. } if *stop_requested => {
                self.state = RunState::Stopping {
                    turn_id: turn_id.clone(),
                };
                vec![CoordinatorEffect::CancelTurn { turn_id }]
            }
            RunState::Starting { .. } => {
                self.state = RunState::Running { turn_id };
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    /// Converts a failed native steering attempt into the same durable queue
    /// effects used when steering is not supported at all.
    pub fn queue_after_failed_steer(
        &mut self,
        direction: Direction,
        queue_id: QueueItemId,
    ) -> Vec<CoordinatorEffect> {
        if !self.queue.iter().any(|queued| queued.queue_id == queue_id) {
            self.queue.push_back(QueuedDirection {
                queue_id: queue_id.clone(),
                direction: direction.clone(),
            });
        }
        vec![
            CoordinatorEffect::Acknowledge {
                acknowledgement: Acknowledgement::QueuedBecauseSteeringUnsupported,
            },
            CoordinatorEffect::PersistQueue {
                queue_id,
                direction,
            },
        ]
    }

    pub fn stop(&mut self) -> Vec<CoordinatorEffect> {
        match &self.state {
            RunState::Idle => vec![CoordinatorEffect::Acknowledge {
                acknowledgement: Acknowledgement::NothingRunning,
            }],
            RunState::Starting { direction_id, .. } => {
                self.state = RunState::Starting {
                    direction_id: direction_id.clone(),
                    stop_requested: true,
                };
                vec![CoordinatorEffect::Acknowledge {
                    acknowledgement: Acknowledgement::Stopping,
                }]
            }
            RunState::Running { turn_id } => {
                let turn_id = turn_id.clone();
                self.state = RunState::Stopping {
                    turn_id: turn_id.clone(),
                };
                vec![
                    CoordinatorEffect::Acknowledge {
                        acknowledgement: Acknowledgement::Stopping,
                    },
                    CoordinatorEffect::CancelTurn { turn_id },
                ]
            }
            RunState::Stopping { .. } => vec![CoordinatorEffect::Acknowledge {
                acknowledgement: Acknowledgement::Stopping,
            }],
        }
    }

    pub fn complete_turn(&mut self, turn_id: &TurnId) -> Vec<CoordinatorEffect> {
        let matches_current = match &self.state {
            RunState::Running { turn_id: current } | RunState::Stopping { turn_id: current } => {
                current == turn_id
            }
            RunState::Idle | RunState::Starting { .. } => false,
        };
        if !matches_current {
            return Vec::new();
        }

        let Some(next) = self.queue.pop_front() else {
            self.state = RunState::Idle;
            return Vec::new();
        };
        self.state = RunState::Starting {
            direction_id: next.direction.id.clone(),
            stop_requested: false,
        };
        vec![
            CoordinatorEffect::Acknowledge {
                acknowledgement: Acknowledgement::StartingQueued,
            },
            CoordinatorEffect::StartTurn {
                direction: next.direction,
            },
        ]
    }

    pub fn undo_queue(&mut self, queue_id: &QueueItemId) -> Vec<CoordinatorEffect> {
        let Some(position) = self
            .queue
            .iter()
            .position(|queued| &queued.queue_id == queue_id)
        else {
            return vec![CoordinatorEffect::Acknowledge {
                acknowledgement: Acknowledgement::AlreadyStarted,
            }];
        };
        let removed = self.queue.remove(position).expect("queued position exists");
        vec![
            CoordinatorEffect::RemoveQueue {
                queue_id: removed.queue_id,
            },
            CoordinatorEffect::Acknowledge {
                acknowledgement: Acknowledgement::RemovedFromQueue,
            },
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn direction(id: &str) -> Direction {
        Direction::new(DirectionId::new(id).expect("direction id"), id)
    }

    fn file_attachment() -> crate::InputAttachment {
        crate::InputAttachment {
            kind: crate::InputAttachmentKind::File,
            uri: "https://cdn.inline.chat/file.txt".to_string(),
            local_uri: None,
            mime_type: Some("text/plain".to_string()),
            file_name: Some("file.txt".to_string()),
            size_bytes: Some(4),
            width: None,
            height: None,
            duration_ms: None,
        }
    }

    fn queue_id(id: &str) -> QueueItemId {
        QueueItemId::new(id).expect("queue id")
    }

    #[test]
    fn idle_direction_starts_immediately() {
        let mut coordinator = TurnCoordinator::default();
        let (disposition, effects) = coordinator.accept_direction(
            direction("d1"),
            false,
            SteeringSupport::Native,
            queue_id("q1"),
        );
        assert_eq!(disposition, DirectionDisposition::Started);
        assert!(matches!(coordinator.state(), RunState::Starting { .. }));
        assert!(matches!(effects[1], CoordinatorEffect::StartTurn { .. }));
    }

    #[test]
    fn running_direction_steers_when_supported() {
        let mut coordinator = TurnCoordinator::default();
        coordinator.accept_direction(
            direction("d1"),
            false,
            SteeringSupport::Native,
            queue_id("q1"),
        );
        coordinator.mark_turn_started(TurnId::new("t1").expect("turn id"));
        let (disposition, effects) = coordinator.accept_direction(
            direction("d2"),
            false,
            SteeringSupport::Native,
            queue_id("q2"),
        );
        assert_eq!(disposition, DirectionDisposition::Steered);
        assert!(matches!(effects[1], CoordinatorEffect::SteerTurn { .. }));
        assert_eq!(coordinator.queue_len(), 0);
    }

    #[test]
    fn unsupported_steer_is_queued_with_explicit_feedback() {
        let mut coordinator = TurnCoordinator::default();
        coordinator.accept_direction(
            direction("d1"),
            false,
            SteeringSupport::Unsupported,
            queue_id("q1"),
        );
        coordinator.mark_turn_started(TurnId::new("t1").expect("turn id"));
        let (disposition, effects) = coordinator.accept_direction(
            direction("d2"),
            false,
            SteeringSupport::Unsupported,
            queue_id("q2"),
        );
        assert_eq!(
            disposition,
            DirectionDisposition::QueuedBecauseSteeringUnsupported
        );
        assert_eq!(coordinator.queue_len(), 1);
        assert_eq!(
            effects[0],
            CoordinatorEffect::Acknowledge {
                acknowledgement: Acknowledgement::QueuedBecauseSteeringUnsupported
            }
        );
    }

    #[test]
    fn duplicate_queue_delivery_does_not_duplicate_in_memory_work() {
        let mut coordinator = TurnCoordinator::running(TurnId::new("t1").expect("turn id"));
        let queue_id = queue_id("q2");
        coordinator.accept_direction(
            direction("d2"),
            true,
            SteeringSupport::Native,
            queue_id.clone(),
        );
        coordinator.accept_direction(
            direction("d2"),
            true,
            SteeringSupport::Native,
            queue_id.clone(),
        );
        assert!(coordinator.has_queued_direction(&queue_id));
        assert_eq!(coordinator.queue_len(), 1);
    }

    #[test]
    fn queued_direction_monotonically_gains_hydrated_attachments() {
        let turn_id = TurnId::new("t1").expect("turn id");
        let mut coordinator = TurnCoordinator::running(turn_id.clone());
        let queue_id = queue_id("q2");
        coordinator.accept_direction(
            direction("d2"),
            true,
            SteeringSupport::Native,
            queue_id.clone(),
        );
        let mut hydrated = direction("d2");
        hydrated.attachments.push(file_attachment());
        assert!(coordinator.enrich_queued_attachments(&queue_id, &hydrated));
        assert!(!coordinator.enrich_queued_attachments(&queue_id, &hydrated));

        let effects = coordinator.complete_turn(&turn_id);
        let CoordinatorEffect::StartTurn { direction } = &effects[1] else {
            panic!("queued direction should start")
        };
        assert_eq!(direction.attachments, hydrated.attachments);
    }

    #[test]
    fn queued_direction_can_be_undone_before_start() {
        let mut coordinator = TurnCoordinator::default();
        coordinator.accept_direction(
            direction("d1"),
            false,
            SteeringSupport::Native,
            queue_id("q1"),
        );
        coordinator.mark_turn_started(TurnId::new("t1").expect("turn id"));
        coordinator.accept_direction(
            direction("d2"),
            true,
            SteeringSupport::Native,
            queue_id("q2"),
        );
        let effects = coordinator.undo_queue(&queue_id("q2"));
        assert_eq!(coordinator.queue_len(), 0);
        assert!(matches!(effects[0], CoordinatorEffect::RemoveQueue { .. }));
    }

    #[test]
    fn stop_while_starting_cancels_as_soon_as_turn_id_arrives() {
        let mut coordinator = TurnCoordinator::default();
        coordinator.accept_direction(
            direction("d1"),
            false,
            SteeringSupport::Native,
            queue_id("q1"),
        );
        coordinator.stop();
        let effects = coordinator.mark_turn_started(TurnId::new("t1").expect("turn id"));
        assert!(matches!(effects[0], CoordinatorEffect::CancelTurn { .. }));
        assert!(matches!(coordinator.state(), RunState::Stopping { .. }));
    }

    #[test]
    fn failed_steer_queues_once_and_completion_advances_it() {
        let mut coordinator = TurnCoordinator::running(TurnId::new("t1").expect("turn id"));
        let effects = coordinator.queue_after_failed_steer(direction("d2"), queue_id("q2"));
        assert!(matches!(effects[1], CoordinatorEffect::PersistQueue { .. }));
        assert_eq!(coordinator.queue_len(), 1);

        let effects = coordinator.complete_turn(&TurnId::new("t1").expect("turn id"));
        assert!(matches!(effects[1], CoordinatorEffect::StartTurn { .. }));
        assert!(matches!(coordinator.state(), RunState::Starting { .. }));
    }

    #[test]
    fn completion_wins_once_against_stop_and_late_completion() {
        let turn_id = TurnId::new("t1").expect("turn id");
        let mut coordinator = TurnCoordinator::running(turn_id.clone());
        assert!(matches!(
            coordinator.stop()[1],
            CoordinatorEffect::CancelTurn { .. }
        ));
        assert!(coordinator.complete_turn(&turn_id).is_empty());
        assert_eq!(coordinator.state(), &RunState::Idle);
        assert!(coordinator.complete_turn(&turn_id).is_empty());
        assert_eq!(
            coordinator.stop(),
            vec![CoordinatorEffect::Acknowledge {
                acknowledgement: Acknowledgement::NothingRunning
            }]
        );
    }

    #[test]
    fn completion_serializes_queue_undo_stop_and_late_steer_effects() {
        let first_turn = TurnId::new("t1").expect("first turn");
        let mut coordinator = TurnCoordinator::running(first_turn.clone());

        let (queued, _) = coordinator.accept_direction(
            direction("d2"),
            true,
            SteeringSupport::Native,
            queue_id("q2"),
        );
        assert_eq!(queued, DirectionDisposition::Queued);
        assert!(matches!(
            coordinator.undo_queue(&queue_id("q2"))[0],
            CoordinatorEffect::RemoveQueue { .. }
        ));

        let (queued, _) = coordinator.accept_direction(
            direction("d3"),
            true,
            SteeringSupport::Native,
            queue_id("q3"),
        );
        assert_eq!(queued, DirectionDisposition::Queued);
        assert!(matches!(
            coordinator.stop()[1],
            CoordinatorEffect::CancelTurn { .. }
        ));

        let completion = coordinator.complete_turn(&first_turn);
        assert!(matches!(completion[1], CoordinatorEffect::StartTurn { .. }));
        assert!(matches!(coordinator.state(), RunState::Starting { .. }));
        assert_eq!(
            coordinator.undo_queue(&queue_id("q3")),
            vec![CoordinatorEffect::Acknowledge {
                acknowledgement: Acknowledgement::AlreadyStarted
            }]
        );
        assert!(coordinator.complete_turn(&first_turn).is_empty());

        let second_turn = TurnId::new("t2").expect("second turn");
        coordinator.mark_turn_started(second_turn.clone());
        let (steered, effects) = coordinator.accept_direction(
            direction("d4"),
            false,
            SteeringSupport::Native,
            queue_id("q4"),
        );
        assert_eq!(steered, DirectionDisposition::Steered);
        assert!(matches!(
            &effects[1],
            CoordinatorEffect::SteerTurn { turn_id, .. } if turn_id == &second_turn
        ));
        assert_eq!(coordinator.queue_len(), 0);
    }

    #[test]
    fn acknowledgements_have_stable_inline_native_copy() {
        assert_eq!(Acknowledgement::Working.message(), "Working...");
        assert_eq!(
            Acknowledgement::Steering.message(),
            "Steering the current run."
        );
        assert_eq!(Acknowledgement::Queued.message(), "Queued for next.");
        assert_eq!(
            Acknowledgement::QueuedBecauseSteeringUnsupported.message(),
            "This agent can't steer, so I queued that for next."
        );
        assert_eq!(Acknowledgement::Stopping.message(), "Stop requested.");
        assert_eq!(
            Acknowledgement::AlreadyStarted.message(),
            "Already started."
        );
    }
}
