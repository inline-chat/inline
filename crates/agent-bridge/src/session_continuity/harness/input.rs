//! Inputs: what Inline sends into a session, how, and on whose behalf.
//!
//! Delivery mapping (spec §4.2):
//!
//! | Delivery | Codex | Claude |
//! | --- | --- | --- |
//! | `Turn` | `turn/start` | user message |
//! | `Steer` | `turn/steer {expectedTurnId}` | `priority: now` / `next` |
//! | `Queue` | `thread/queue/add` (experimental) | `priority: later` |
//! | `Passive` | `additionalContext` / `thread/inject_items` | `shouldQuery: false` |
//!
//! Direct input during a turn uses the harness's own default for typing while
//! it works (Codex steer, Claude `next`). Steering is acknowledged only by the
//! agent's own next output; Inline posts no "steered" receipt.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{ChatId, InputId, QueueEntryId, UserId, WorkRef};
use crate::{InputAttachment, TurnContext, TurnId};

/// One input sent to a session.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Input {
    /// Inline-assigned identity, echoed in receipts and delivery facts.
    pub id: InputId,
    /// What the input says.
    pub content: InputContent,
    /// On whose behalf it is sent. Drivers map this to native provenance.
    pub origin: Origin,
    /// How the harness should take it.
    pub delivery: Delivery,
}

/// Text, media and bridge context of one input.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct InputContent {
    /// The author's text. Untrusted when the origin is not the owner.
    pub text: String,
    /// Ordered media descriptors (`localImage` / `localAudio` for Codex,
    /// content blocks or resource descriptors for Claude).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attachments: Vec<InputAttachment>,
    /// Trusted bridge instructions plus untrusted conversation excerpts, kept
    /// apart from the author's intent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<TurnContext>,
}

impl InputContent {
    /// Plain text with no media or context.
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            ..Self::default()
        }
    }
}

/// Native provenance of an input (spec §5.1 rule 1).
///
/// Claude maps owner → `human`, teammate → `channel{inline}`, agent →
/// `peer{from, name, fromSession}`. Codex sends direct input as user input and
/// ambient messages as untrusted `additionalContext`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Origin {
    /// The runtime owner.
    Owner {
        /// Inline user id of the owner.
        user: UserId,
    },
    /// A person the owner granted access to.
    Teammate {
        /// Inline user id of the teammate.
        user: UserId,
    },
    /// Another agent, addressing this one from its own work.
    Agent {
        /// Bot user id of the sending agent.
        bot: UserId,
        /// The sending agent's work.
        work: WorkRef,
    },
    /// Conversation the agent observes but was not addressed by.
    Ambient {
        /// Chat the messages came from.
        chat: ChatId,
    },
    /// A wakeup the harness or Inline scheduled.
    Scheduled,
}

impl Origin {
    /// Only the owner can consent on the owner's behalf; teammates and agents never can.
    pub fn can_consent_for_owner(&self) -> bool {
        matches!(self, Self::Owner { .. })
    }

    /// The Inline user behind the input, when there is one.
    pub fn user(&self) -> Option<UserId> {
        match self {
            Self::Owner { user } | Self::Teammate { user } => Some(*user),
            Self::Agent { bot, .. } => Some(*bot),
            Self::Ambient { .. } | Self::Scheduled => None,
        }
    }
}

/// How an input reaches the harness.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Delivery {
    /// Start a new turn. Only valid while the session is idle.
    Turn,
    /// Join the running turn.
    Steer {
        /// The turn the sender saw running. A mismatch is an error, never a
        /// silent new turn.
        expected_turn: TurnId,
        /// Claude priority. Codex has a single steer and maps both to it.
        priority: SteerPriority,
    },
    /// Hold until the current work ends (`/queue`).
    Queue,
    /// Context the agent observes without starting a turn.
    Passive,
}

impl Delivery {
    /// The availability key for this delivery.
    pub fn kind(&self) -> DeliveryKind {
        match self {
            Self::Turn => DeliveryKind::Turn,
            Self::Steer {
                priority: SteerPriority::Now,
                ..
            } => DeliveryKind::SteerNow,
            Self::Steer {
                priority: SteerPriority::Next,
                ..
            } => DeliveryKind::SteerNext,
            Self::Queue => DeliveryKind::Queue,
            Self::Passive => DeliveryKind::Passive,
        }
    }
}

/// Steer urgency, following Claude's `priority`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SteerPriority {
    /// Interrupt the current step (Claude `now`).
    Now,
    /// Take effect at the next model call (Claude `next`, the default while typing).
    Next,
}

/// Fieldless key used by availability tables.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeliveryKind {
    /// [`Delivery::Turn`].
    Turn,
    /// [`Delivery::Steer`] with [`SteerPriority::Now`].
    SteerNow,
    /// [`Delivery::Steer`] with [`SteerPriority::Next`].
    SteerNext,
    /// [`Delivery::Queue`].
    Queue,
    /// [`Delivery::Passive`].
    Passive,
}

impl DeliveryKind {
    /// Every delivery kind, in a stable order.
    pub const ALL: [Self; 5] = [
        Self::Turn,
        Self::SteerNow,
        Self::SteerNext,
        Self::Queue,
        Self::Passive,
    ];
}

/// Native acceptance of one input. Consumption is reported later as an
/// [`Event::Input`](super::Event::Input) fact.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InputReceipt {
    /// The input this receipt is for.
    pub input: InputId,
    /// What the harness did with it.
    pub disposition: InputDisposition,
    /// Native response, kept for the journal.
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub native: Value,
    /// How far the harness confirmed it.
    #[serde(default)]
    pub acceptance: Acceptance,
}

/// How far a harness confirmed an input it did not refuse.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Acceptance {
    /// The harness acknowledged it.
    #[default]
    Accepted,
    /// Only the write is known (a CLI without acknowledgements): it stays
    /// unconfirmed until the harness shows consuming it.
    Written,
}

/// What the harness did with an accepted input.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum InputDisposition {
    /// A new turn started for it.
    Started {
        /// Native turn id.
        turn: TurnId,
    },
    /// The running turn accepted it. Visible acknowledgment comes only from
    /// the agent's next output.
    Steered {
        /// Native turn id that took the steer.
        turn: TurnId,
    },
    /// The harness queued it.
    Queued {
        /// Native queue entry, when the harness names one.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        entry: Option<QueueEntryId>,
    },
    /// Passive context was accepted without starting a turn.
    Absorbed,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deliveries_round_trip_with_stable_tags() {
        let steer = Delivery::Steer {
            expected_turn: TurnId::new("turn-1").expect("turn"),
            priority: SteerPriority::Next,
        };
        let encoded = serde_json::to_value(&steer).expect("encode");
        assert_eq!(
            encoded,
            serde_json::json!({"kind":"steer","expected_turn":"turn-1","priority":"next"})
        );
        assert_eq!(
            serde_json::from_value::<Delivery>(encoded).expect("decode"),
            steer
        );
        assert_eq!(steer.kind(), DeliveryKind::SteerNext);
    }

    #[test]
    fn only_the_owner_consents_for_the_owner() {
        let owner = Origin::Owner { user: UserId(1) };
        let teammate = Origin::Teammate { user: UserId(2) };
        let agent = Origin::Agent {
            bot: UserId(3),
            work: WorkRef {
                chat: ChatId(9),
                session: None,
            },
        };
        assert!(owner.can_consent_for_owner());
        assert!(!teammate.can_consent_for_owner());
        assert!(!agent.can_consent_for_owner());
        assert_eq!(agent.user(), Some(UserId(3)));
        assert_eq!(Origin::Ambient { chat: ChatId(9) }.user(), None);
    }

    #[test]
    fn input_round_trips_with_optional_fields_omitted() {
        let input = Input {
            id: InputId::new("in-1").expect("id"),
            content: InputContent::text("fix the build"),
            origin: Origin::Owner { user: UserId(7) },
            delivery: Delivery::Turn,
        };
        let encoded = serde_json::to_value(&input).expect("encode");
        assert_eq!(
            encoded,
            serde_json::json!({
                "id": "in-1",
                "content": {"text": "fix the build"},
                "origin": {"kind": "owner", "user": 7},
                "delivery": {"kind": "turn"}
            })
        );
        assert_eq!(
            serde_json::from_value::<Input>(encoded).expect("decode"),
            input
        );
    }
}
