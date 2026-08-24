use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{Direction, DirectionId};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OperatorPolicy {
    owner_user_id: i64,
    allowed_user_ids: BTreeSet<i64>,
}

impl OperatorPolicy {
    pub fn owner_only(owner_user_id: i64) -> Self {
        Self {
            owner_user_id,
            allowed_user_ids: BTreeSet::from([owner_user_id]),
        }
    }

    pub fn from_allowed(
        owner_user_id: i64,
        allowed_user_ids: impl IntoIterator<Item = i64>,
    ) -> Result<Self, OperatorPolicyError> {
        if owner_user_id <= 0 {
            return Err(OperatorPolicyError::InvalidOwner);
        }
        let mut allowed_user_ids = allowed_user_ids.into_iter().collect::<BTreeSet<_>>();
        if allowed_user_ids.iter().any(|user_id| *user_id <= 0) {
            return Err(OperatorPolicyError::InvalidUser);
        }
        allowed_user_ids.insert(owner_user_id);
        Ok(Self {
            owner_user_id,
            allowed_user_ids,
        })
    }

    pub fn owner_user_id(&self) -> i64 {
        self.owner_user_id
    }

    pub fn allows(&self, user_id: i64) -> bool {
        self.allowed_user_ids.contains(&user_id)
    }

    pub fn add(&mut self, user_id: i64) -> bool {
        self.allowed_user_ids.insert(user_id)
    }

    pub fn remove(&mut self, user_id: i64) -> Result<bool, OperatorPolicyError> {
        if user_id == self.owner_user_id {
            return Err(OperatorPolicyError::CannotRemoveOwner);
        }
        Ok(self.allowed_user_ids.remove(&user_id))
    }

    pub fn allowed_user_ids(&self) -> impl Iterator<Item = i64> + '_ {
        self.allowed_user_ids.iter().copied()
    }
}

#[derive(Clone, Copy, Debug, Error, PartialEq, Eq)]
pub enum OperatorPolicyError {
    #[error("the bridge owner user ID must be positive")]
    InvalidOwner,
    #[error("operator user IDs must be positive")]
    InvalidUser,
    #[error("the bridge owner cannot be removed from the operator allowlist")]
    CannotRemoveOwner,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Addressing {
    OwnerDm,
    Mention,
    ReplyToBot,
    Followed,
    None,
}

/// Provider-neutral facts used to classify how an Inline message addresses
/// this bot. Transport adapters resolve these facts from native message and
/// viewer state; providers never participate in addressing decisions.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AddressSignals {
    pub owner_dm: bool,
    pub mentioned: bool,
    pub reply_to_bot: bool,
    pub followed: bool,
}

impl AddressSignals {
    /// Applies the stable v1 addressing precedence. Explicit message-local
    /// addressing wins over viewer follow state, including when the owner has
    /// explicitly unfollowed the conversation.
    pub const fn resolve(self) -> Addressing {
        if self.owner_dm {
            Addressing::OwnerDm
        } else if self.mentioned {
            Addressing::Mention
        } else if self.reply_to_bot {
            Addressing::ReplyToBot
        } else if self.followed {
            Addressing::Followed
        } else {
            Addressing::None
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommandInvocation {
    pub name: String,
    pub arguments: String,
    /// Whether the command used Inline's `/command@bot` form. This remains
    /// distinct from `targets_this_bot` so an explicit target for another bot
    /// cannot be mistaken for an unqualified command in an owner DM.
    #[serde(default)]
    pub explicit_target: bool,
    pub targets_this_bot: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActionInvocation {
    pub interaction_id: i64,
    pub action_id: String,
    pub data: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboundEnvelope {
    pub event_id: String,
    pub chat_id: i64,
    pub message_id: i64,
    pub sender_user_id: i64,
    pub text: String,
    pub duplicate: bool,
    /// Whether the sender is any bot account, including this bridge bot.
    /// Bot-authored message directions require exact mention addressing.
    pub bot_authored: bool,
    pub addressing: Addressing,
    pub command: Option<CommandInvocation>,
    pub action: Option<ActionInvocation>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IgnoreReason {
    Duplicate,
    BotAuthored,
    Unauthorized,
    Malformed,
    CommandTargetsAnotherBot,
    NotAddressed,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TriggerDecision {
    Ignore {
        reason: IgnoreReason,
    },
    Action {
        invocation: ActionInvocation,
    },
    Command {
        invocation: CommandInvocation,
    },
    Direction {
        direction: Direction,
        addressing: Addressing,
    },
}

#[derive(Clone, Copy, Debug, Default)]
pub struct TriggerResolver;

impl TriggerResolver {
    pub fn resolve(&self, policy: &OperatorPolicy, envelope: InboundEnvelope) -> TriggerDecision {
        if envelope.duplicate {
            return TriggerDecision::Ignore {
                reason: IgnoreReason::Duplicate,
            };
        }
        if envelope.bot_authored && !matches!(envelope.addressing, Addressing::Mention) {
            return TriggerDecision::Ignore {
                reason: IgnoreReason::BotAuthored,
            };
        }
        if !envelope.bot_authored && !policy.allows(envelope.sender_user_id) {
            return TriggerDecision::Ignore {
                reason: IgnoreReason::Unauthorized,
            };
        }
        if let Some(invocation) = envelope.action {
            return TriggerDecision::Action { invocation };
        }
        if let Some(invocation) = envelope.command {
            return if invocation.targets_this_bot
                || (!invocation.explicit_target
                    && matches!(
                        envelope.addressing,
                        Addressing::OwnerDm
                            | Addressing::Mention
                            | Addressing::ReplyToBot
                            | Addressing::Followed
                    ))
            {
                TriggerDecision::Command { invocation }
            } else {
                TriggerDecision::Ignore {
                    reason: IgnoreReason::CommandTargetsAnotherBot,
                }
            };
        }
        if matches!(envelope.addressing, Addressing::None) {
            return TriggerDecision::Ignore {
                reason: IgnoreReason::NotAddressed,
            };
        }

        let Ok(direction_id) = DirectionId::new(envelope.event_id) else {
            return TriggerDecision::Ignore {
                reason: IgnoreReason::Malformed,
            };
        };

        TriggerDecision::Direction {
            direction: Direction::new(direction_id, envelope.text),
            addressing: envelope.addressing,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn message(sender_user_id: i64, addressing: Addressing) -> InboundEnvelope {
        InboundEnvelope {
            event_id: "event-1".to_string(),
            chat_id: 10,
            message_id: 11,
            sender_user_id,
            text: "fix the tests".to_string(),
            duplicate: false,
            bot_authored: false,
            addressing,
            command: None,
            action: None,
        }
    }

    #[test]
    fn owner_is_seeded_and_cannot_be_removed() {
        let mut policy = OperatorPolicy::owner_only(7);
        assert!(policy.allows(7));
        assert_eq!(
            policy.remove(7),
            Err(OperatorPolicyError::CannotRemoveOwner)
        );
    }

    #[test]
    fn persisted_allowlist_is_validated_and_always_contains_owner() {
        let policy = OperatorPolicy::from_allowed(7, [8, 8]).expect("valid policy");
        assert_eq!(policy.allowed_user_ids().collect::<Vec<_>>(), [7, 8]);
        assert_eq!(
            OperatorPolicy::from_allowed(0, [8]),
            Err(OperatorPolicyError::InvalidOwner)
        );
        assert_eq!(
            OperatorPolicy::from_allowed(7, [-1]),
            Err(OperatorPolicyError::InvalidUser)
        );
    }

    #[test]
    fn authorization_precedes_triggering() {
        let policy = OperatorPolicy::owner_only(7);
        let decision = TriggerResolver.resolve(&policy, message(8, Addressing::Mention));
        assert_eq!(
            decision,
            TriggerDecision::Ignore {
                reason: IgnoreReason::Unauthorized
            }
        );
    }

    #[test]
    fn owner_dm_becomes_direction() {
        let policy = OperatorPolicy::owner_only(7);
        let decision = TriggerResolver.resolve(&policy, message(7, Addressing::OwnerDm));
        assert!(matches!(
            decision,
            TriggerDecision::Direction {
                addressing: Addressing::OwnerDm,
                ..
            }
        ));
    }

    #[test]
    fn bot_authored_messages_require_an_explicit_mention() {
        let policy = OperatorPolicy::owner_only(7);
        for addressing in [
            Addressing::OwnerDm,
            Addressing::ReplyToBot,
            Addressing::Followed,
            Addressing::None,
        ] {
            let mut envelope = message(8, addressing);
            envelope.bot_authored = true;
            assert_eq!(
                TriggerResolver.resolve(&policy, envelope),
                TriggerDecision::Ignore {
                    reason: IgnoreReason::BotAuthored
                }
            );
        }

        let mut envelope = message(8, Addressing::Mention);
        envelope.bot_authored = true;
        assert!(matches!(
            TriggerResolver.resolve(&policy, envelope),
            TriggerDecision::Direction {
                addressing: Addressing::Mention,
                ..
            }
        ));
    }

    #[test]
    fn blank_event_id_is_ignored_as_malformed() {
        let policy = OperatorPolicy::owner_only(7);
        let mut envelope = message(7, Addressing::OwnerDm);
        envelope.event_id.clear();
        assert_eq!(
            TriggerResolver.resolve(&policy, envelope),
            TriggerDecision::Ignore {
                reason: IgnoreReason::Malformed
            }
        );
    }

    #[test]
    fn group_command_must_target_this_bot() {
        let policy = OperatorPolicy::owner_only(7);
        let mut envelope = message(7, Addressing::None);
        envelope.command = Some(CommandInvocation {
            name: "status".to_string(),
            arguments: String::new(),
            explicit_target: true,
            targets_this_bot: false,
        });
        assert_eq!(
            TriggerResolver.resolve(&policy, envelope),
            TriggerDecision::Ignore {
                reason: IgnoreReason::CommandTargetsAnotherBot
            }
        );
    }

    #[test]
    fn active_conversation_can_target_an_unqualified_command() {
        let policy = OperatorPolicy::owner_only(7);
        for addressing in [
            Addressing::OwnerDm,
            Addressing::Mention,
            Addressing::ReplyToBot,
            Addressing::Followed,
        ] {
            let mut envelope = message(7, addressing);
            envelope.command = Some(CommandInvocation {
                name: "status".to_string(),
                arguments: String::new(),
                explicit_target: false,
                targets_this_bot: false,
            });
            assert!(matches!(
                TriggerResolver.resolve(&policy, envelope),
                TriggerDecision::Command { .. }
            ));
        }
    }

    #[test]
    fn explicit_addressing_precedes_follow_state() {
        assert_eq!(
            AddressSignals {
                mentioned: true,
                reply_to_bot: true,
                followed: true,
                ..AddressSignals::default()
            }
            .resolve(),
            Addressing::Mention
        );
        assert_eq!(
            AddressSignals {
                reply_to_bot: true,
                followed: true,
                ..AddressSignals::default()
            }
            .resolve(),
            Addressing::ReplyToBot
        );
    }

    #[test]
    fn owner_dm_and_followed_messages_are_distinct() {
        assert_eq!(
            AddressSignals {
                owner_dm: true,
                followed: true,
                ..AddressSignals::default()
            }
            .resolve(),
            Addressing::OwnerDm
        );
        assert_eq!(
            AddressSignals {
                followed: true,
                ..AddressSignals::default()
            }
            .resolve(),
            Addressing::Followed
        );
        assert_eq!(AddressSignals::default().resolve(), Addressing::None);
    }

    #[test]
    fn address_signal_truth_table_has_stable_precedence() {
        for mask in 0_u8..16 {
            let signals = AddressSignals {
                owner_dm: mask & 0b1000 != 0,
                mentioned: mask & 0b0100 != 0,
                reply_to_bot: mask & 0b0010 != 0,
                followed: mask & 0b0001 != 0,
            };
            let expected = if signals.owner_dm {
                Addressing::OwnerDm
            } else if signals.mentioned {
                Addressing::Mention
            } else if signals.reply_to_bot {
                Addressing::ReplyToBot
            } else if signals.followed {
                Addressing::Followed
            } else {
                Addressing::None
            };
            assert_eq!(signals.resolve(), expected, "signal mask {mask:04b}");
        }
    }

    #[test]
    fn trigger_truth_table_covers_authorization_addressing_commands_and_actions() {
        let policy = OperatorPolicy::from_allowed(7, [8]).expect("policy");
        for sender in [7, 8, 9] {
            for addressing in [
                Addressing::OwnerDm,
                Addressing::Mention,
                Addressing::ReplyToBot,
                Addressing::Followed,
                Addressing::None,
            ] {
                let ordinary = TriggerResolver.resolve(&policy, message(sender, addressing));
                if sender == 9 {
                    assert_eq!(
                        ordinary,
                        TriggerDecision::Ignore {
                            reason: IgnoreReason::Unauthorized
                        }
                    );
                } else if addressing == Addressing::None {
                    assert_eq!(
                        ordinary,
                        TriggerDecision::Ignore {
                            reason: IgnoreReason::NotAddressed
                        }
                    );
                } else {
                    assert!(matches!(
                        ordinary,
                        TriggerDecision::Direction {
                            addressing: actual,
                            ..
                        } if actual == addressing
                    ));
                }

                let mut unqualified = message(sender, addressing);
                unqualified.command = Some(CommandInvocation {
                    name: "status".to_string(),
                    arguments: String::new(),
                    explicit_target: false,
                    targets_this_bot: false,
                });
                let unqualified = TriggerResolver.resolve(&policy, unqualified);
                let unqualified_targets = matches!(
                    addressing,
                    Addressing::OwnerDm
                        | Addressing::Mention
                        | Addressing::ReplyToBot
                        | Addressing::Followed
                );
                if sender == 9 {
                    assert!(matches!(
                        unqualified,
                        TriggerDecision::Ignore {
                            reason: IgnoreReason::Unauthorized
                        }
                    ));
                } else if unqualified_targets {
                    assert!(matches!(unqualified, TriggerDecision::Command { .. }));
                } else {
                    assert!(matches!(
                        unqualified,
                        TriggerDecision::Ignore {
                            reason: IgnoreReason::CommandTargetsAnotherBot
                        }
                    ));
                }

                let mut targeted = message(sender, addressing);
                targeted.command = Some(CommandInvocation {
                    name: "status".to_string(),
                    arguments: String::new(),
                    explicit_target: true,
                    targets_this_bot: true,
                });
                let targeted = TriggerResolver.resolve(&policy, targeted);
                if sender == 9 {
                    assert!(matches!(
                        targeted,
                        TriggerDecision::Ignore {
                            reason: IgnoreReason::Unauthorized
                        }
                    ));
                } else {
                    assert!(matches!(targeted, TriggerDecision::Command { .. }));
                }

                let mut other_bot = message(sender, addressing);
                other_bot.command = Some(CommandInvocation {
                    name: "status".to_string(),
                    arguments: String::new(),
                    explicit_target: true,
                    targets_this_bot: false,
                });
                let other_bot = TriggerResolver.resolve(&policy, other_bot);
                if sender == 9 {
                    assert!(matches!(
                        other_bot,
                        TriggerDecision::Ignore {
                            reason: IgnoreReason::Unauthorized
                        }
                    ));
                } else {
                    assert!(matches!(
                        other_bot,
                        TriggerDecision::Ignore {
                            reason: IgnoreReason::CommandTargetsAnotherBot
                        }
                    ));
                }

                let mut action = message(sender, addressing);
                action.action = Some(ActionInvocation {
                    interaction_id: 1,
                    action_id: "approve".to_string(),
                    data: vec![1, 2, 3],
                });
                let action = TriggerResolver.resolve(&policy, action);
                if sender == 9 {
                    assert!(matches!(
                        action,
                        TriggerDecision::Ignore {
                            reason: IgnoreReason::Unauthorized
                        }
                    ));
                } else {
                    assert!(matches!(action, TriggerDecision::Action { .. }));
                }
            }
        }
    }

    #[test]
    fn duplicate_check_precedes_an_explicit_bot_mention() {
        let policy = OperatorPolicy::owner_only(7);
        let mut envelope = message(7, Addressing::Mention);
        envelope.duplicate = true;
        envelope.bot_authored = true;
        envelope.action = Some(ActionInvocation {
            interaction_id: 1,
            action_id: "approve".to_string(),
            data: Vec::new(),
        });
        assert_eq!(
            TriggerResolver.resolve(&policy, envelope),
            TriggerDecision::Ignore {
                reason: IgnoreReason::Duplicate
            }
        );

        let mut envelope = message(8, Addressing::Mention);
        envelope.bot_authored = true;
        envelope.command = Some(CommandInvocation {
            name: "status".to_string(),
            arguments: String::new(),
            explicit_target: true,
            targets_this_bot: true,
        });
        assert!(matches!(
            TriggerResolver.resolve(&policy, envelope),
            TriggerDecision::Command { .. }
        ));
    }
}
