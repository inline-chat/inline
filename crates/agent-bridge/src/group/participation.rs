//! Participation modes per (thread, agent) (spec §5.1 rule 2).
//!
//! A mention or invite from someone with access joins the agent in active
//! mode. Participation lasts until muted or removed. The owner and grantees
//! change the mode; the server's record (with its revision) is authoritative.

use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::intake::Access;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ParticipationMode {
    /// Observes the thread and considers unaddressed human messages.
    #[default]
    Active,
    /// Observes the thread; acts only on direct input.
    MentionsOnly,
    /// No ambient evaluation and no passive context; direct input still acts.
    Muted,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Participation {
    pub chat_id: i64,
    pub mode: ParticipationMode,
    pub joined_by: i64,
    /// Server revision; a remote record only replaces a lower revision.
    pub revision: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ParticipationChange {
    /// A mention or invite. Joining never changes an existing mode, so a
    /// mention does not unmute.
    Join {
        chat_id: i64,
        by: i64,
    },
    SetMode {
        chat_id: i64,
        mode: ParticipationMode,
        by: i64,
    },
    Remove {
        by: i64,
    },
    /// The server's record for this (thread, agent); `None` means removed at
    /// that revision.
    Remote {
        record: Option<Participation>,
        revision: u64,
    },
}

#[derive(Clone, Copy, Debug, Error, PartialEq, Eq)]
pub enum ParticipationError {
    #[error("only the owner and people with access can change an agent's participation")]
    NotGranted,
    #[error("the agent does not participate in this thread")]
    NotParticipating,
    #[error("the participation update is older than the current record")]
    Stale,
}

/// Applies one change. `actor_access` is the access of whoever made a local
/// change; remote records are already authorized by the server.
pub fn apply_participation_change(
    current: Option<&Participation>,
    change: ParticipationChange,
    actor_access: Access,
) -> Result<Option<Participation>, ParticipationError> {
    let next_revision = current.map_or(1, |current| current.revision + 1);
    match change {
        ParticipationChange::Remote { record, revision } => {
            if current.is_some_and(|current| current.revision >= revision) {
                return Err(ParticipationError::Stale);
            }
            Ok(record.map(|record| Participation { revision, ..record }))
        }
        _ if !actor_access.may_invoke() => Err(ParticipationError::NotGranted),
        ParticipationChange::Join { chat_id, by } => Ok(Some(match current {
            Some(current) => *current,
            None => Participation {
                chat_id,
                mode: ParticipationMode::Active,
                joined_by: by,
                revision: next_revision,
            },
        })),
        ParticipationChange::SetMode { chat_id, mode, by } => Ok(Some(match current {
            Some(current) if current.mode == mode => *current,
            Some(current) => Participation {
                mode,
                revision: next_revision,
                ..*current
            },
            None => Participation {
                chat_id,
                mode,
                joined_by: by,
                revision: next_revision,
            },
        })),
        ParticipationChange::Remove { .. } => match current {
            Some(_) => Ok(None),
            None => Err(ParticipationError::NotParticipating),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn joined() -> Participation {
        apply_participation_change(
            None,
            ParticipationChange::Join { chat_id: 3, by: 8 },
            Access::Grantee,
        )
        .unwrap()
        .unwrap()
    }

    #[test]
    fn a_mention_joins_in_active_mode() {
        let record = joined();
        assert_eq!(record.mode, ParticipationMode::Active);
        assert_eq!(record.joined_by, 8);
        assert_eq!(record.revision, 1);
    }

    #[test]
    fn joining_without_access_is_refused() {
        assert_eq!(
            apply_participation_change(
                None,
                ParticipationChange::Join { chat_id: 3, by: 9 },
                Access::None,
            ),
            Err(ParticipationError::NotGranted)
        );
    }

    #[test]
    fn a_mention_does_not_unmute() {
        let muted = apply_participation_change(
            Some(&joined()),
            ParticipationChange::SetMode {
                chat_id: 3,
                mode: ParticipationMode::Muted,
                by: 7,
            },
            Access::Owner,
        )
        .unwrap()
        .unwrap();
        assert_eq!(muted.revision, 2);
        let after_mention = apply_participation_change(
            Some(&muted),
            ParticipationChange::Join { chat_id: 3, by: 8 },
            Access::Grantee,
        )
        .unwrap()
        .unwrap();
        assert_eq!(after_mention, muted);
    }

    #[test]
    fn mode_changes_and_removal_need_access() {
        let record = joined();
        for change in [
            ParticipationChange::SetMode {
                chat_id: 3,
                mode: ParticipationMode::MentionsOnly,
                by: 9,
            },
            ParticipationChange::Remove { by: 9 },
        ] {
            assert_eq!(
                apply_participation_change(Some(&record), change, Access::None),
                Err(ParticipationError::NotGranted)
            );
        }
        assert_eq!(
            apply_participation_change(
                Some(&record),
                ParticipationChange::Remove { by: 7 },
                Access::Owner
            ),
            Ok(None)
        );
        assert_eq!(
            apply_participation_change(None, ParticipationChange::Remove { by: 7 }, Access::Owner),
            Err(ParticipationError::NotParticipating)
        );
    }

    #[test]
    fn setting_the_same_mode_keeps_the_revision() {
        let record = joined();
        assert_eq!(
            apply_participation_change(
                Some(&record),
                ParticipationChange::SetMode {
                    chat_id: 3,
                    mode: ParticipationMode::Active,
                    by: 7,
                },
                Access::Owner,
            ),
            Ok(Some(record))
        );
    }

    #[test]
    fn remote_records_apply_by_revision() {
        let record = joined();
        let newer = Participation {
            mode: ParticipationMode::MentionsOnly,
            ..record
        };
        assert_eq!(
            apply_participation_change(
                Some(&record),
                ParticipationChange::Remote {
                    record: Some(newer),
                    revision: 5,
                },
                Access::None,
            ),
            Ok(Some(Participation {
                revision: 5,
                ..newer
            }))
        );
        assert_eq!(
            apply_participation_change(
                Some(&Participation {
                    revision: 5,
                    ..newer
                }),
                ParticipationChange::Remote {
                    record: None,
                    revision: 5,
                },
                Access::None,
            ),
            Err(ParticipationError::Stale)
        );
        assert_eq!(
            apply_participation_change(
                Some(&record),
                ParticipationChange::Remote {
                    record: None,
                    revision: 6,
                },
                Access::None,
            ),
            Ok(None)
        );
    }
}
