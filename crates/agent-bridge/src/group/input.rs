//! Contract inputs from group decisions (spec §4.2, §5.1).
//!
//! - Direct input starts a turn while the work is idle, and steers the running
//!   turn otherwise, following the harness's default for typing while it works
//!   (Codex steer, Claude `next`). `/queue` queues.
//! - Other commands are typed operations, not inputs.
//! - Observed messages are batched ([`super::PassiveBatch`]) and sent as one
//!   `Passive` input with an `Ambient` origin.

use super::context::PassiveContext;
use super::envelope::{GroupMessage, MessageEntity, origin_of};
use super::intake::IntakeDecision;
use super::permissions::Operation;
use crate::TurnContext;
use crate::TurnId;
use crate::harness::{ChatId, Delivery, Input, InputContent, InputId, Origin, SteerPriority};

/// The input for a direct message, or `None` when the decision is not to act
/// or the message is a command other than `/queue`. `running_turn` is the
/// turn the bridge last saw running; `context` carries the trusted guide and
/// untrusted join context or sender metadata.
pub fn direct_input(
    decision: &IntakeDecision,
    message: &GroupMessage,
    owner_user_id: i64,
    id: InputId,
    running_turn: Option<&TurnId>,
    context: Option<TurnContext>,
) -> Option<Input> {
    let IntakeDecision::Act { required, .. } = decision else {
        return None;
    };
    let delivery = match (required, message.command()) {
        (Operation::Queue, _) => Delivery::Queue,
        (_, Some(_)) => return None,
        _ => match running_turn {
            Some(turn) => Delivery::Steer {
                expected_turn: turn.clone(),
                priority: SteerPriority::Next,
            },
            None => Delivery::Turn,
        },
    };
    let text = match delivery {
        Delivery::Queue => without_commands(message),
        _ => message.text.clone(),
    };
    Some(Input {
        id,
        content: InputContent {
            text,
            attachments: Vec::new(),
            context,
        },
        origin: origin_of(message, owner_user_id),
        delivery,
    })
}

/// One passive input for a drained batch of observed messages.
pub fn passive_input(batch: PassiveContext, id: InputId) -> Input {
    Input {
        id,
        content: InputContent::text(batch.text),
        origin: Origin::Ambient {
            chat: ChatId(batch.chat_id),
        },
        delivery: Delivery::Passive,
    }
}

/// The message text with command entities cut out (`/queue and the docs` →
/// `and the docs`).
fn without_commands(message: &GroupMessage) -> String {
    let mut spans = message
        .entities
        .iter()
        .filter_map(|entity| match entity {
            MessageEntity::Command { offset, length, .. } => {
                Some((*offset as usize, *offset as usize + *length as usize))
            }
            _ => None,
        })
        .collect::<Vec<_>>();
    spans.sort_unstable();
    let units = message.text.encode_utf16().collect::<Vec<_>>();
    let mut kept = Vec::with_capacity(units.len());
    let mut cursor = 0;
    for (start, end) in spans {
        let (start, end) = (start.min(units.len()), end.min(units.len()));
        if start >= cursor {
            kept.extend_from_slice(&units[cursor..start]);
            cursor = end;
        }
    }
    kept.extend_from_slice(&units[cursor.min(units.len())..]);
    String::from_utf16_lossy(&kept).trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::group::envelope::{Author, AuthorKind, Conversation, Mention, SentVia};
    use crate::group::intake::DirectReason;
    use crate::harness::UserId;

    fn message(text: &str) -> GroupMessage {
        GroupMessage {
            chat_id: 3,
            message_id: 10,
            author: Author {
                user_id: 8,
                display_name: "Sara".into(),
                kind: AuthorKind::Human,
            },
            conversation: Conversation::Group,
            via: SentVia::Composer,
            text: text.into(),
            entities: vec![MessageEntity::Mention {
                offset: 0,
                length: 7,
                target: Mention::User { user_id: 99 },
            }],
            reply_to: None,
            sent_at: 0,
        }
    }

    fn act(required: Operation) -> IntakeDecision {
        IntakeDecision::Act {
            reason: DirectReason::LeadingMention,
            join: false,
            required,
        }
    }

    fn id() -> InputId {
        InputId::new("in-1").unwrap()
    }

    #[test]
    fn idle_work_starts_a_turn_and_running_work_is_steered() {
        let message = message("@claude fix the tests");
        let input =
            direct_input(&act(Operation::StartWork), &message, 7, id(), None, None).expect("input");
        assert_eq!(input.delivery, Delivery::Turn);
        assert_eq!(input.origin, Origin::Teammate { user: UserId(8) });
        assert_eq!(input.content.text, "@claude fix the tests");

        let turn = TurnId::new("turn-4").unwrap();
        let input = direct_input(&act(Operation::Steer), &message, 7, id(), Some(&turn), None)
            .expect("input");
        assert_eq!(
            input.delivery,
            Delivery::Steer {
                expected_turn: turn,
                priority: SteerPriority::Next
            }
        );
    }

    #[test]
    fn queue_strips_the_command_and_other_commands_are_not_inputs() {
        let mut queued = message("@claude /queue and the docs");
        queued.entities.push(MessageEntity::Command {
            offset: 8,
            length: 6,
            name: "queue".into(),
            target_user_id: None,
        });
        let input =
            direct_input(&act(Operation::Queue), &queued, 7, id(), None, None).expect("input");
        assert_eq!(input.delivery, Delivery::Queue);
        assert_eq!(input.content.text, "@claude  and the docs");

        let mut status = message("@claude /status");
        status.entities.push(MessageEntity::Command {
            offset: 8,
            length: 7,
            name: "status".into(),
            target_user_id: None,
        });
        assert!(direct_input(&act(Operation::StartWork), &status, 7, id(), None, None).is_none());
    }

    #[test]
    fn non_act_decisions_produce_no_direct_input() {
        let decision = IntakeDecision::Observe {
            reason: crate::group::intake::ObserveReason::Unaddressed,
            consider: true,
        };
        assert!(direct_input(&decision, &message("hi"), 7, id(), None, None).is_none());
    }

    #[test]
    fn passive_batches_are_ambient_and_passive() {
        let input = passive_input(
            PassiveContext {
                chat_id: 3,
                text: "New messages…".into(),
                included_message_ids: vec![1],
                omitted: 0,
            },
            id(),
        );
        assert_eq!(input.delivery, Delivery::Passive);
        assert_eq!(input.origin, Origin::Ambient { chat: ChatId(3) });
        assert!(!input.origin.can_consent_for_owner());
    }
}
