//! Operation permissions (spec §7): one table, kept intact through intake,
//! admission and execution.
//!
//! | Operation | Needs |
//! | --- | --- |
//! | start work | INVOKE |
//! | steer, queue, stop, pause, resume | STEER |
//! | approve | APPROVE (owner + delegates) |
//! | answer a question | any grant |
//! | participation mode, output-mode override, agent settings | CONFIGURE |
//! | hand back an answer this agent asked for | nothing |
//!
//! The owner always qualifies. A mention or a passive message is never
//! authority. Another agent acts for its owner: it holds its own grants plus
//! what its owner may delegate, using and steering only
//! ([`Grants::acting_for`]). Callers recheck with the sender's current grants after any wait:
//! pending input, replay, queue admission and action claims.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Operation {
    StartWork,
    Steer,
    Queue,
    Stop,
    Pause,
    Resume,
    Approve,
    Answer,
    Configure,
    /// The answer to a request this agent made: a reply to its message from
    /// someone that message mentioned. The agent asked, so no grant is needed.
    HandBack,
}

/// One sender's grants on this agent, from the server's `agent_grants` rows
/// (re-read by the bridge on every input). No rows means no grants.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Grants {
    #[serde(default)]
    pub owner: bool,
    #[serde(default)]
    pub invoke: bool,
    #[serde(default)]
    pub steer: bool,
    #[serde(default)]
    pub approve: bool,
    #[serde(default)]
    pub configure: bool,
}

impl Grants {
    pub const NONE: Self = Self {
        owner: false,
        invoke: false,
        steer: false,
        approve: false,
        configure: false,
    };

    pub const OWNER: Self = Self {
        owner: true,
        ..Self::NONE
    };

    /// What today's `allowed_user_ids` migrate to (spec §7).
    pub const MIGRATED_ALLOWLIST: Self = Self {
        invoke: true,
        steer: true,
        ..Self::NONE
    };

    pub const fn any(self) -> bool {
        self.owner || self.invoke || self.steer || self.approve || self.configure
    }

    pub const fn permits(self, operation: Operation) -> bool {
        if self.owner {
            return true;
        }
        match operation {
            Operation::StartWork => self.invoke,
            Operation::Steer
            | Operation::Queue
            | Operation::Stop
            | Operation::Pause
            | Operation::Resume => self.steer,
            Operation::Approve => self.approve,
            Operation::Answer => self.any(),
            Operation::Configure => self.configure,
            Operation::HandBack => true,
        }
    }

    /// Both sets of grants.
    pub const fn union(self, other: Self) -> Self {
        Self {
            owner: self.owner || other.owner,
            invoke: self.invoke || other.invoke,
            steer: self.steer || other.steer,
            approve: self.approve || other.approve,
            configure: self.configure || other.configure,
        }
    }

    /// What a person can pass on to a bot acting for them: using and steering
    /// what they may use and steer. Never ownership, approval or settings.
    pub const fn delegable(self) -> Self {
        Self {
            invoke: self.owner || self.invoke,
            steer: self.owner || self.steer,
            ..Self::NONE
        }
    }

    /// An agent sender's grants on this agent: its own, plus what the person
    /// it acts for may delegate. `owner` is that person's grants (the owner of
    /// this agent has [`Grants::OWNER`], so same-owner agents may use and
    /// steer each other); `None` when the sender's owner is unknown.
    pub const fn acting_for(own: Self, owner: Option<Self>) -> Self {
        match owner {
            Some(owner) => own.union(owner.delegable()),
            None => own,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Admission {
    Admitted,
    Denied { needs: Operation },
}

/// Checks `operation` against the sender's grants as they are now.
pub const fn admit(grants: Grants, operation: Operation) -> Admission {
    if grants.permits(operation) {
        Admission::Admitted
    } else {
        Admission::Denied { needs: operation }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [Operation; 9] = [
        Operation::StartWork,
        Operation::Steer,
        Operation::Queue,
        Operation::Stop,
        Operation::Pause,
        Operation::Resume,
        Operation::Approve,
        Operation::Answer,
        Operation::Configure,
    ];

    fn allowed(grants: Grants) -> Vec<Operation> {
        ALL.into_iter().filter(|op| grants.permits(*op)).collect()
    }

    #[test]
    fn the_owner_may_do_everything_and_nobody_else_by_default() {
        assert_eq!(allowed(Grants::OWNER), ALL);
        assert!(allowed(Grants::NONE).is_empty());
        assert!(allowed(Grants::default()).is_empty());
    }

    #[test]
    fn each_grant_unlocks_only_its_row() {
        let invoke = Grants {
            invoke: true,
            ..Grants::NONE
        };
        assert_eq!(allowed(invoke), [Operation::StartWork, Operation::Answer]);

        let steer = Grants {
            steer: true,
            ..Grants::NONE
        };
        assert_eq!(
            allowed(steer),
            [
                Operation::Steer,
                Operation::Queue,
                Operation::Stop,
                Operation::Pause,
                Operation::Resume,
                Operation::Answer
            ]
        );

        let approve = Grants {
            approve: true,
            ..Grants::NONE
        };
        assert_eq!(allowed(approve), [Operation::Approve, Operation::Answer]);

        let configure = Grants {
            configure: true,
            ..Grants::NONE
        };
        assert_eq!(
            allowed(configure),
            [Operation::Answer, Operation::Configure]
        );
    }

    #[test]
    fn agents_inherit_only_use_and_steer_from_the_person_they_act_for() {
        let use_and_steer = Grants::MIGRATED_ALLOWLIST;
        // Same owner: this agent's owner may do everything, the other agent
        // only uses and steers.
        assert_eq!(
            Grants::acting_for(Grants::NONE, Some(Grants::OWNER)),
            use_and_steer
        );
        // The other agent's owner holds a grant: capped to use and steer.
        let full = Grants {
            invoke: true,
            steer: true,
            approve: true,
            configure: true,
            ..Grants::NONE
        };
        let inherited = Grants::acting_for(Grants::NONE, Some(full));
        assert_eq!(inherited, use_and_steer);
        assert!(!inherited.permits(Operation::Approve));
        assert!(!inherited.permits(Operation::Configure));
        let invoke_only = Grants {
            invoke: true,
            ..Grants::NONE
        };
        assert_eq!(
            Grants::acting_for(Grants::NONE, Some(invoke_only)),
            invoke_only
        );
        // The agent's own grants stay whole, approval included.
        let approve = Grants {
            approve: true,
            ..Grants::NONE
        };
        let both = Grants::acting_for(approve, Some(invoke_only));
        assert!(both.permits(Operation::Approve) && both.permits(Operation::StartWork));
        assert!(!both.permits(Operation::Steer));
        // An owner without grants, or an unknown owner, passes nothing on.
        assert_eq!(Grants::acting_for(approve, Some(Grants::NONE)), approve);
        assert_eq!(Grants::acting_for(Grants::NONE, None), Grants::NONE);
    }

    #[test]
    fn a_hand_back_needs_no_grant() {
        assert!(Grants::NONE.permits(Operation::HandBack));
    }

    #[test]
    fn migrated_allowlist_entries_invoke_and_steer_but_never_approve() {
        let grants = Grants::MIGRATED_ALLOWLIST;
        assert!(grants.permits(Operation::StartWork));
        assert!(grants.permits(Operation::Pause));
        assert!(!grants.permits(Operation::Approve));
        assert!(!grants.permits(Operation::Configure));
    }

    #[test]
    fn admission_names_the_missing_operation() {
        assert_eq!(
            admit(Grants::OWNER, Operation::Approve),
            Admission::Admitted
        );
        assert_eq!(
            admit(Grants::MIGRATED_ALLOWLIST, Operation::Approve),
            Admission::Denied {
                needs: Operation::Approve
            }
        );
    }

    #[test]
    fn missing_fields_deserialize_as_no_grant() {
        let grants: Grants = serde_json::from_str(r#"{"steer":true}"#).unwrap();
        assert_eq!(
            grants,
            Grants {
                steer: true,
                ..Grants::NONE
            }
        );
    }
}
