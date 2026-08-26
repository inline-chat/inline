//! Pure snapshot-plus-stream reconciliation and acknowledgement barriers.

use std::collections::HashMap;

use thiserror::Error;

use super::{
    ProviderSessionRef, SessionAttachmentId, SessionCheckpoint, SessionContractError, SessionEvent,
    SessionEventOrigin, SessionEventPayload, SessionInputCorrelation, SessionItem, SessionItemKey,
    SessionItemVersion, SessionRuntimeState, SessionSnapshot, SessionStreamPosition,
};
use crate::DirectionId;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionPhase {
    Snapshotting,
    Replaying,
    Live,
    Repairing,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionProjectionAck {
    session: ProviderSessionRef,
    attachment_id: SessionAttachmentId,
    through_sequence: u64,
    checkpoint: Option<SessionCheckpoint>,
}

impl SessionProjectionAck {
    pub fn session(&self) -> &ProviderSessionRef {
        &self.session
    }

    pub fn attachment_id(&self) -> &SessionAttachmentId {
        &self.attachment_id
    }

    pub fn through_sequence(&self) -> u64 {
        self.through_sequence
    }

    pub fn checkpoint(&self) -> Option<&SessionCheckpoint> {
        self.checkpoint.as_ref()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionRepairReason {
    SequenceGap {
        expected_sequence: u64,
        actual_sequence: u64,
    },
    ProviderReportedGap {
        expected_sequence: u64,
        actual_sequence: u64,
    },
    SequenceExhausted,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionReduceAction {
    Upsert {
        item: Box<SessionItem>,
        ack: SessionProjectionAck,
    },
    IgnoreStaleItem {
        key: SessionItemKey,
        ack: SessionProjectionAck,
    },
    SuppressConfirmedInlineEcho {
        key: SessionItemKey,
        direction_id: DirectionId,
        ack: SessionProjectionAck,
    },
    Remove {
        key: SessionItemKey,
        ack: SessionProjectionAck,
    },
    IgnoreDuplicateSequence {
        sequence: u64,
    },
    StateChanged {
        state: SessionRuntimeState,
        ack: SessionProjectionAck,
    },
    Checkpoint {
        ack: SessionProjectionAck,
    },
    ControlRequested {
        request: Box<super::SessionControlRequest>,
        ack: SessionProjectionAck,
    },
    ControlClosed {
        context: super::SessionControlContext,
        request_id: super::SessionControlId,
        ack: SessionProjectionAck,
    },
    RepairRequired {
        reason: SessionRepairReason,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SnapshotMerge {
    pub upserts: Vec<SessionItem>,
    pub suppressed_inline_echoes: Vec<(SessionItemKey, DirectionId)>,
    pub ack: SessionProjectionAck,
}

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum SessionReduceError {
    #[error("session event belongs to a different provider session")]
    SessionMismatch,
    #[error("session event belongs to a stale or different attachment")]
    AttachmentMismatch,
    #[error("attached snapshot and stream position disagree on their provider checkpoint")]
    CheckpointMismatch,
    #[error("session reducer cannot accept live events while snapshotting")]
    SnapshotIncomplete,
    #[error("session reducer requires snapshot repair before accepting more events")]
    RepairRequired,
    #[error(transparent)]
    InvalidContract(#[from] SessionContractError),
}

#[derive(Clone, Debug)]
pub struct SessionRevisionReducer {
    session: ProviderSessionRef,
    attachment_id: SessionAttachmentId,
    phase: SessionPhase,
    revisions: HashMap<SessionItemKey, u64>,
    expected_sequence: Option<u64>,
    effective_checkpoint: Option<SessionCheckpoint>,
}

impl SessionRevisionReducer {
    pub fn new(session: ProviderSessionRef, attachment_id: SessionAttachmentId) -> Self {
        Self {
            session,
            attachment_id,
            phase: SessionPhase::Snapshotting,
            revisions: HashMap::new(),
            expected_sequence: None,
            effective_checkpoint: None,
        }
    }

    pub fn phase(&self) -> SessionPhase {
        self.phase
    }

    pub fn merge_snapshot(
        &mut self,
        snapshot: SessionSnapshot,
        position: SessionStreamPosition,
        replay_follows: bool,
    ) -> Result<SnapshotMerge, SessionReduceError> {
        if snapshot.session() != &self.session {
            return Err(SessionReduceError::SessionMismatch);
        }

        if position.attachment_id != self.attachment_id {
            return Err(SessionReduceError::AttachmentMismatch);
        }

        let (snapshot_session, items, snapshot_checkpoint) = snapshot.into_parts();
        debug_assert_eq!(snapshot_session, self.session);
        if let (Some(snapshot_checkpoint), Some(position_checkpoint)) =
            (&snapshot_checkpoint, &position.checkpoint)
            && snapshot_checkpoint != position_checkpoint
        {
            return Err(SessionReduceError::CheckpointMismatch);
        }

        let mut upserts = Vec::new();
        let mut suppressed_inline_echoes = Vec::new();
        for item in items {
            item.validate_text()?;
            if self.accept_version(&item.key, item.revision) {
                if let Some(direction_id) = item.confirmed_inline_echo().cloned() {
                    suppressed_inline_echoes.push((item.key, direction_id));
                } else {
                    upserts.push(item);
                }
            }
        }
        self.expected_sequence = position.last_applied_sequence.checked_add(1);
        if self.expected_sequence.is_none() {
            self.phase = SessionPhase::Repairing;
            return Err(SessionReduceError::RepairRequired);
        }
        self.phase = if replay_follows {
            SessionPhase::Replaying
        } else {
            SessionPhase::Live
        };
        self.effective_checkpoint = position.checkpoint.or(snapshot_checkpoint);
        Ok(SnapshotMerge {
            upserts,
            suppressed_inline_echoes,
            ack: SessionProjectionAck {
                session: self.session.clone(),
                attachment_id: self.attachment_id.clone(),
                through_sequence: position.last_applied_sequence,
                checkpoint: self.effective_checkpoint.clone(),
            },
        })
    }

    pub fn finish_replay(
        &mut self,
        terminal_position: SessionStreamPosition,
    ) -> Result<(), SessionReduceError> {
        if terminal_position.attachment_id != self.attachment_id {
            return Err(SessionReduceError::AttachmentMismatch);
        }
        if self.phase != SessionPhase::Replaying {
            return Ok(());
        }
        let last_applied = self
            .expected_sequence
            .and_then(|sequence| sequence.checked_sub(1))
            .ok_or(SessionReduceError::RepairRequired)?;
        if terminal_position.last_applied_sequence != last_applied {
            self.phase = SessionPhase::Repairing;
            return Err(SessionReduceError::RepairRequired);
        }
        self.effective_checkpoint = terminal_position
            .checkpoint
            .or_else(|| self.effective_checkpoint.clone());
        self.phase = SessionPhase::Live;
        Ok(())
    }

    pub fn apply_event(
        &mut self,
        event: SessionEvent,
    ) -> Result<SessionReduceAction, SessionReduceError> {
        if event.session != self.session {
            return Err(SessionReduceError::SessionMismatch);
        }
        if event.attachment_id != self.attachment_id {
            return Err(SessionReduceError::AttachmentMismatch);
        }
        match self.phase {
            SessionPhase::Snapshotting => return Err(SessionReduceError::SnapshotIncomplete),
            SessionPhase::Repairing => return Err(SessionReduceError::RepairRequired),
            SessionPhase::Replaying | SessionPhase::Live => {}
        }

        if let Some(expected) = self.expected_sequence {
            if event.sequence < expected {
                return Ok(SessionReduceAction::IgnoreDuplicateSequence {
                    sequence: event.sequence,
                });
            }
            if event.sequence > expected {
                self.phase = SessionPhase::Repairing;
                return Ok(SessionReduceAction::RepairRequired {
                    reason: SessionRepairReason::SequenceGap {
                        expected_sequence: expected,
                        actual_sequence: event.sequence,
                    },
                });
            }
        }
        let Some(next_sequence) = event.sequence.checked_add(1) else {
            self.phase = SessionPhase::Repairing;
            return Ok(SessionReduceAction::RepairRequired {
                reason: SessionRepairReason::SequenceExhausted,
            });
        };
        self.expected_sequence = Some(next_sequence);

        let effective_checkpoint = event
            .checkpoint
            .clone()
            .or_else(|| self.effective_checkpoint.clone());
        let ack = SessionProjectionAck {
            session: self.session.clone(),
            attachment_id: self.attachment_id.clone(),
            through_sequence: event.sequence,
            checkpoint: effective_checkpoint.clone(),
        };
        match event.payload {
            SessionEventPayload::Item { item } => {
                self.effective_checkpoint = effective_checkpoint;
                item.validate_text()?;
                let key = item.key.clone();
                if !self.accept_version(&item.key, item.revision) {
                    Ok(SessionReduceAction::IgnoreStaleItem { key, ack })
                } else if let Some(direction_id) = item.confirmed_inline_echo().cloned() {
                    Ok(SessionReduceAction::SuppressConfirmedInlineEcho {
                        key,
                        direction_id,
                        ack,
                    })
                } else {
                    Ok(SessionReduceAction::Upsert { item, ack })
                }
            }
            SessionEventPayload::StateChanged { state } => {
                self.effective_checkpoint = effective_checkpoint;
                Ok(SessionReduceAction::StateChanged { state, ack })
            }
            SessionEventPayload::Gap {
                expected_sequence,
                actual_sequence,
            } => {
                self.phase = SessionPhase::Repairing;
                Ok(SessionReduceAction::RepairRequired {
                    reason: SessionRepairReason::ProviderReportedGap {
                        expected_sequence,
                        actual_sequence,
                    },
                })
            }
            SessionEventPayload::Removed { key, revision } => {
                self.effective_checkpoint = effective_checkpoint;
                if self.accept_version(&key, revision) {
                    Ok(SessionReduceAction::Remove { key, ack })
                } else {
                    Ok(SessionReduceAction::IgnoreStaleItem { key, ack })
                }
            }
            SessionEventPayload::ControlRequested { request } => {
                request.validate()?;
                self.validate_control_context(request.context())?;
                self.effective_checkpoint = effective_checkpoint;
                Ok(SessionReduceAction::ControlRequested { request, ack })
            }
            SessionEventPayload::ControlClosed {
                context,
                request_id,
            } => {
                self.validate_control_context(&context)?;
                self.effective_checkpoint = effective_checkpoint;
                Ok(SessionReduceAction::ControlClosed {
                    context,
                    request_id,
                    ack,
                })
            }
            SessionEventPayload::Checkpoint => {
                self.effective_checkpoint = effective_checkpoint;
                Ok(SessionReduceAction::Checkpoint { ack })
            }
        }
    }

    fn validate_control_context(
        &self,
        context: &super::SessionControlContext,
    ) -> Result<(), SessionReduceError> {
        if context.session != self.session {
            return Err(SessionReduceError::SessionMismatch);
        }
        if context.attachment_id != self.attachment_id {
            return Err(SessionReduceError::AttachmentMismatch);
        }
        Ok(())
    }

    fn accept_version(&mut self, key: &SessionItemKey, revision: SessionItemVersion) -> bool {
        let revision = revision.get();
        match self.revisions.get(key) {
            Some(previous) if *previous >= revision => false,
            _ => {
                self.revisions.insert(key.clone(), revision);
                true
            }
        }
    }
}

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum SessionAckError {
    #[error("projection acknowledgement belongs to another provider session")]
    SessionMismatch,
    #[error("projection acknowledgement belongs to a stale attachment")]
    AttachmentMismatch,
    #[error("projection acknowledgement is not the next contiguous sequence")]
    OutOfOrder,
    #[error("projection acknowledgement dropped an effective provider checkpoint")]
    CheckpointRegression,
    #[error("projection acknowledgement sequence is exhausted")]
    SequenceExhausted,
}

#[derive(Clone, Debug)]
pub struct SessionProjectionAckTracker {
    session: ProviderSessionRef,
    attachment_id: SessionAttachmentId,
    expected_sequence: u64,
    effective_checkpoint: Option<SessionCheckpoint>,
}

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum SessionEchoError {
    #[error("session input correlation is already registered")]
    DuplicateCorrelation,
    #[error("session input correlation was not confirmed by a bridge-owned send")]
    UnknownCorrelation,
}

#[derive(Clone, Debug, Default)]
pub struct SessionEchoCorrelator {
    directions: HashMap<SessionInputCorrelation, DirectionId>,
}

impl SessionEchoCorrelator {
    /// Registers only a provider-confirmed send correlation. Text or ordering
    /// heuristics must never be used to populate this map.
    pub fn register(
        &mut self,
        correlation: SessionInputCorrelation,
        direction_id: DirectionId,
    ) -> Result<(), SessionEchoError> {
        if self.directions.contains_key(&correlation) {
            return Err(SessionEchoError::DuplicateCorrelation);
        }
        self.directions.insert(correlation, direction_id);
        Ok(())
    }

    pub fn confirm(
        &mut self,
        correlation: SessionInputCorrelation,
    ) -> Result<SessionEventOrigin, SessionEchoError> {
        let direction_id = self
            .directions
            .remove(&correlation)
            .ok_or(SessionEchoError::UnknownCorrelation)?;
        Ok(SessionEventOrigin::confirmed_inline_echo(
            direction_id,
            correlation,
        ))
    }
}

impl SessionProjectionAckTracker {
    pub fn new(session: ProviderSessionRef, position: &SessionStreamPosition) -> Self {
        Self {
            session,
            attachment_id: position.attachment_id.clone(),
            expected_sequence: position.last_applied_sequence,
            effective_checkpoint: None,
        }
    }

    /// Accepts exactly one contiguous high-water acknowledgement. Callers run
    /// this only after every Inline projection through the supplied sequence
    /// has been durably acknowledged.
    pub fn acknowledge(&mut self, ack: &SessionProjectionAck) -> Result<(), SessionAckError> {
        if ack.session != self.session {
            return Err(SessionAckError::SessionMismatch);
        }
        if ack.attachment_id != self.attachment_id {
            return Err(SessionAckError::AttachmentMismatch);
        }
        if ack.through_sequence != self.expected_sequence {
            return Err(SessionAckError::OutOfOrder);
        }
        if self.effective_checkpoint.is_some() && ack.checkpoint.is_none() {
            return Err(SessionAckError::CheckpointRegression);
        }
        let next_sequence = self
            .expected_sequence
            .checked_add(1)
            .ok_or(SessionAckError::SequenceExhausted)?;
        self.effective_checkpoint = ack
            .checkpoint
            .clone()
            .or_else(|| self.effective_checkpoint.clone());
        self.expected_sequence = next_sequence;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{DirectionId, InstallationId, ProviderId, ProviderSessionId};

    use super::super::{
        HistoryWindow, ProviderInstanceRef, ProviderSurface, SessionEventOrigin,
        SessionItemPayload, SessionItemVersion, SessionMessageRole,
    };

    fn provider_session(provider_id: &str, id: &str) -> ProviderSessionRef {
        ProviderSessionRef::new(
            ProviderInstanceRef::new(
                InstallationId::new("install-1").expect("installation"),
                ProviderId::new(provider_id).expect("provider"),
            )
            .expect("provider instance"),
            ProviderSessionId::new(id).expect("session"),
        )
        .expect("provider session")
    }

    fn session(id: &str) -> ProviderSessionRef {
        provider_session("codex", id)
    }

    fn attachment(id: &str) -> SessionAttachmentId {
        SessionAttachmentId::new(id).expect("attachment")
    }

    fn position(attachment_id: SessionAttachmentId, sequence: u64) -> SessionStreamPosition {
        SessionStreamPosition {
            attachment_id,
            last_applied_sequence: sequence,
            checkpoint: SessionCheckpoint::new("snapshot-1").ok(),
        }
    }

    fn item(key: &str, revision: u64) -> SessionItem {
        SessionItem {
            key: SessionItemKey::new(key).expect("key"),
            revision: SessionItemVersion::new(revision),
            run_id: None,
            origin: SessionEventOrigin::provider(ProviderSurface::Remote),
            payload: SessionItemPayload::Message {
                role: SessionMessageRole::User,
                text: "continue".to_owned(),
                created_at: None,
            },
        }
    }

    fn snapshot(session: ProviderSessionRef, items: Vec<SessionItem>) -> SessionSnapshot {
        SessionSnapshot::new(
            session,
            items,
            SessionCheckpoint::new("snapshot-1").ok(),
            false,
            false,
            HistoryWindow::default(),
        )
        .expect("snapshot")
    }

    #[test]
    fn snapshot_and_live_events_only_upsert_newer_item_revisions() {
        let session = session("thread-1");
        let attachment_id = attachment("attachment-1");
        let mut reducer = SessionRevisionReducer::new(session.clone(), attachment_id.clone());
        let merged = reducer
            .merge_snapshot(
                snapshot(session.clone(), vec![item("message-1", 2)]),
                position(attachment_id.clone(), 9),
                false,
            )
            .expect("snapshot");
        assert_eq!(merged.upserts.len(), 1);

        let stale = reducer
            .apply_event(SessionEvent {
                session: session.clone(),
                attachment_id: attachment_id.clone(),
                sequence: 10,
                checkpoint: None,
                payload: SessionEventPayload::Item {
                    item: Box::new(item("message-1", 1)),
                },
            })
            .expect("stale event");
        assert!(matches!(stale, SessionReduceAction::IgnoreStaleItem { .. }));

        let current = reducer
            .apply_event(SessionEvent {
                session,
                attachment_id,
                sequence: 11,
                checkpoint: None,
                payload: SessionEventPayload::Item {
                    item: Box::new(item("message-1", 3)),
                },
            })
            .expect("new event");
        assert!(matches!(current, SessionReduceAction::Upsert { .. }));
    }

    #[test]
    fn sequence_gap_stops_projection_until_snapshot_repair() {
        let session = session("thread-1");
        let attachment_id = attachment("attachment-1");
        let mut reducer = SessionRevisionReducer::new(session.clone(), attachment_id.clone());
        reducer
            .merge_snapshot(
                snapshot(session.clone(), Vec::new()),
                position(attachment_id.clone(), 2),
                false,
            )
            .expect("snapshot");
        reducer
            .apply_event(SessionEvent {
                session: session.clone(),
                attachment_id: attachment_id.clone(),
                sequence: 3,
                checkpoint: None,
                payload: SessionEventPayload::Checkpoint,
            })
            .expect("first event");

        let gap = reducer
            .apply_event(SessionEvent {
                session: session.clone(),
                attachment_id: attachment_id.clone(),
                sequence: 5,
                checkpoint: None,
                payload: SessionEventPayload::Checkpoint,
            })
            .expect("gap");
        assert_eq!(
            gap,
            SessionReduceAction::RepairRequired {
                reason: SessionRepairReason::SequenceGap {
                    expected_sequence: 4,
                    actual_sequence: 5,
                }
            }
        );
        assert_eq!(reducer.phase(), SessionPhase::Repairing);
        assert_eq!(
            reducer.apply_event(SessionEvent {
                session,
                attachment_id,
                sequence: 6,
                checkpoint: None,
                payload: SessionEventPayload::Checkpoint,
            }),
            Err(SessionReduceError::RepairRequired)
        );
    }

    #[test]
    fn confirmed_inline_echo_is_suppressed_after_provider_correlation() {
        let session = session("thread-1");
        let attachment_id = attachment("attachment-1");
        let mut reducer = SessionRevisionReducer::new(session.clone(), attachment_id.clone());
        reducer
            .merge_snapshot(
                snapshot(session.clone(), Vec::new()),
                position(attachment_id.clone(), 4),
                false,
            )
            .expect("snapshot");
        let direction_id = DirectionId::new("direction-1").expect("direction");
        let correlation = SessionInputCorrelation::new("turn-1").expect("correlation");
        let mut correlator = SessionEchoCorrelator::default();
        correlator
            .register(correlation.clone(), direction_id.clone())
            .expect("register correlation");
        let mut echo = item("message-echo", 1);
        echo.origin = correlator.confirm(correlation).expect("confirmed echo");
        let action = reducer
            .apply_event(SessionEvent {
                session,
                attachment_id,
                sequence: 5,
                checkpoint: None,
                payload: SessionEventPayload::Item {
                    item: Box::new(echo),
                },
            })
            .expect("echo");
        assert!(matches!(
            action,
            SessionReduceAction::SuppressConfirmedInlineEcho {
                direction_id: actual,
                ..
            } if actual == direction_id
        ));
    }

    #[test]
    fn origin_serialization_retains_confirmed_direction_identity() {
        let direction_id = DirectionId::new("direction-1").expect("direction");
        let correlation = SessionInputCorrelation::new("turn-1").expect("correlation");
        let mut correlator = SessionEchoCorrelator::default();
        correlator
            .register(correlation.clone(), direction_id)
            .expect("register");
        let origin = correlator.confirm(correlation).expect("confirm");
        let encoded = serde_json::to_string(&origin).expect("encode origin");
        assert!(encoded.contains("direction-1"));
    }

    #[test]
    fn mismatched_provider_instance_is_rejected() {
        let attachment_id = attachment("attachment-1");
        let mut reducer = SessionRevisionReducer::new(session("thread-1"), attachment_id.clone());
        assert_eq!(
            reducer.merge_snapshot(
                snapshot(provider_session("claude", "thread-1"), Vec::new()),
                position(attachment_id, 0),
                false,
            ),
            Err(SessionReduceError::SessionMismatch)
        );
    }

    #[test]
    fn snapshot_high_water_rejects_a_missing_first_live_event() {
        let session = session("thread-1");
        let attachment_id = attachment("attachment-1");
        let mut reducer = SessionRevisionReducer::new(session.clone(), attachment_id.clone());
        let merged = reducer
            .merge_snapshot(
                snapshot(session.clone(), Vec::new()),
                position(attachment_id.clone(), 8),
                false,
            )
            .expect("snapshot");
        assert_eq!(merged.ack.session(), &session);
        assert_eq!(merged.ack.attachment_id(), &attachment_id);

        let action = reducer
            .apply_event(SessionEvent {
                session,
                attachment_id,
                sequence: 10,
                checkpoint: None,
                payload: SessionEventPayload::Checkpoint,
            })
            .expect("gap action");
        assert!(matches!(
            action,
            SessionReduceAction::RepairRequired {
                reason: SessionRepairReason::SequenceGap {
                    expected_sequence: 9,
                    actual_sequence: 10,
                }
            }
        ));
    }

    #[test]
    fn stale_attachment_events_cannot_enter_a_new_reducer_epoch() {
        let session = session("thread-1");
        let current_attachment = attachment("attachment-current");
        let mut reducer = SessionRevisionReducer::new(session.clone(), current_attachment.clone());
        reducer
            .merge_snapshot(
                snapshot(session.clone(), Vec::new()),
                position(current_attachment, 0),
                false,
            )
            .expect("snapshot");
        assert_eq!(
            reducer.apply_event(SessionEvent {
                session,
                attachment_id: attachment("attachment-stale"),
                sequence: 1,
                checkpoint: None,
                payload: SessionEventPayload::Checkpoint,
            }),
            Err(SessionReduceError::AttachmentMismatch)
        );
    }

    #[test]
    fn projection_acknowledgements_are_attachment_scoped_and_contiguous() {
        let session = session("thread-1");
        let attachment_id = attachment("attachment-1");
        let baseline = position(attachment_id.clone(), 3);
        let mut reducer = SessionRevisionReducer::new(session.clone(), attachment_id.clone());
        let snapshot_ack = reducer
            .merge_snapshot(
                snapshot(session.clone(), Vec::new()),
                baseline.clone(),
                false,
            )
            .expect("snapshot")
            .ack;
        let ack_four = match reducer
            .apply_event(SessionEvent {
                session: session.clone(),
                attachment_id: attachment_id.clone(),
                sequence: 4,
                checkpoint: None,
                payload: SessionEventPayload::Checkpoint,
            })
            .expect("sequence four")
        {
            SessionReduceAction::Checkpoint { ack } => ack,
            action => panic!("unexpected action: {action:?}"),
        };
        let ack_five = match reducer
            .apply_event(SessionEvent {
                session: session.clone(),
                attachment_id,
                sequence: 5,
                checkpoint: None,
                payload: SessionEventPayload::Checkpoint,
            })
            .expect("sequence five")
        {
            SessionReduceAction::Checkpoint { ack } => ack,
            action => panic!("unexpected action: {action:?}"),
        };

        let mut tracker = SessionProjectionAckTracker::new(session, &baseline);
        assert_eq!(
            tracker.acknowledge(&ack_five),
            Err(SessionAckError::OutOfOrder)
        );
        tracker.acknowledge(&snapshot_ack).expect("snapshot ack");
        assert!(ack_four.checkpoint().is_some());
        tracker.acknowledge(&ack_four).expect("sequence four ack");
        tracker.acknowledge(&ack_five).expect("sequence five ack");
        assert_eq!(
            tracker.acknowledge(&ack_five),
            Err(SessionAckError::OutOfOrder)
        );
        let mut stale = ack_five;
        stale.attachment_id = attachment("attachment-stale");
        assert_eq!(
            tracker.acknowledge(&stale),
            Err(SessionAckError::AttachmentMismatch)
        );
    }

    #[test]
    fn externally_started_controls_keep_session_attachment_and_controller_identity() {
        let session = session("thread-1");
        let attachment_id = attachment("attachment-1");
        let mut reducer = SessionRevisionReducer::new(session.clone(), attachment_id.clone());
        reducer
            .merge_snapshot(
                snapshot(session.clone(), Vec::new()),
                position(attachment_id.clone(), 0),
                false,
            )
            .expect("snapshot");
        let context = super::super::SessionControlContext {
            session: session.clone(),
            attachment_id: attachment_id.clone(),
            controller_epoch: super::super::SessionControllerEpoch::new("controller-1")
                .expect("controller"),
        };
        let request = super::super::SessionControlRequest::approval(
            context.clone(),
            super::super::SessionControlId::new("approval-1").expect("approval"),
            "Allow the command?".to_owned(),
            vec![
                super::super::SessionControlOption::new(
                    super::super::SessionControlId::new("allow").expect("option"),
                    "Allow".to_owned(),
                )
                .expect("option"),
            ],
        )
        .expect("request");
        let action = reducer
            .apply_event(SessionEvent {
                session,
                attachment_id,
                sequence: 1,
                checkpoint: None,
                payload: SessionEventPayload::ControlRequested {
                    request: Box::new(request),
                },
            })
            .expect("control");
        assert!(matches!(
            action,
            SessionReduceAction::ControlRequested { request, .. }
                if request.context() == &context
        ));
    }

    #[test]
    fn replay_only_becomes_live_at_the_verified_terminal_position() {
        let session = session("thread-1");
        let attachment_id = attachment("attachment-1");
        let mut reducer = SessionRevisionReducer::new(session.clone(), attachment_id.clone());
        reducer
            .merge_snapshot(
                snapshot(session.clone(), Vec::new()),
                position(attachment_id.clone(), 7),
                true,
            )
            .expect("snapshot");
        reducer
            .apply_event(SessionEvent {
                session,
                attachment_id: attachment_id.clone(),
                sequence: 8,
                checkpoint: None,
                payload: SessionEventPayload::Checkpoint,
            })
            .expect("replay event");
        assert_eq!(reducer.phase(), SessionPhase::Replaying);
        reducer
            .finish_replay(position(attachment_id, 8))
            .expect("terminal replay position");
        assert_eq!(reducer.phase(), SessionPhase::Live);
    }
}
