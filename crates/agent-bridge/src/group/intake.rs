//! Intake rules (spec §5.1 rule 3): who a message is for, and what this agent
//! does with it.
//!
//! - Words never trigger. Only structured Inline addressing counts: mention
//!   entities, a reply, a DM, the agent's work thread, the work bar, or a
//!   command.
//! - The leading run of mentions decides the addressee. If it names others and
//!   not this agent, the agent takes no turn and runs no speak gate, even when
//!   the message replies to it, sits in its thread, or mentions it later. The
//!   message can still arrive as passive context.

use serde::{Deserialize, Serialize};

use super::caps::LoopVerdict;
use super::envelope::{Conversation, GroupMessage, Mention, SentVia};
use super::participation::ParticipationMode;

/// The sender's access to this agent, resolved from server grants and
/// re-checked by the bridge on every input. A mention never grants access.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Access {
    Owner,
    /// Holds an invoke grant (for an agent sender: is one of the owner's own
    /// agents or is granted as a subject).
    Grantee,
    None,
}

impl Access {
    pub const fn may_invoke(self) -> bool {
        !matches!(self, Self::None)
    }
}

/// Why a message is direct input to this agent.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DirectReason {
    /// This agent is in the message's leading run of mentions.
    LeadingMention,
    /// A mention entity of this agent elsewhere in the message.
    Mention,
    /// A reply to one of this agent's messages.
    Reply,
    /// The owner's DM with this agent (or a subthread under it).
    Dm,
    /// A message in this agent's work thread.
    WorkThread,
    /// Sent from this agent's work bar.
    WorkBar,
    /// A command for this agent: `/command@agent`, or an unqualified command in
    /// a message that is otherwise direct input to it.
    Command,
}

/// Who a message is addressed to, from this agent's point of view.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AddresseeKind {
    Me {
        reason: DirectReason,
    },
    /// Addressed to someone else by its leading mentions or command target.
    Others,
    Unaddressed,
}

/// Characters allowed between the mentions of a leading run, besides
/// whitespace: `@alice, @claude: compare` is one run.
const RUN_SEPARATORS: [char; 4] = [',', ':', ';', '&'];

/// The run of mention entities at the very start of the message, in order.
/// Only whitespace and [`RUN_SEPARATORS`] may sit before and between them.
/// Offsets are UTF-16 code units, as Inline stores entities.
pub fn leading_mentions(message: &GroupMessage) -> Vec<Mention> {
    let units = message.text.encode_utf16().collect::<Vec<_>>();
    let mut mentions = message.mentions().collect::<Vec<_>>();
    mentions.sort_by_key(|(offset, _, _)| *offset);

    let mut run = Vec::new();
    let mut cursor = 0_usize;
    for (offset, length, target) in mentions {
        let (offset, length) = (offset as usize, length as usize);
        if offset < cursor {
            // Overlapping or duplicate entity; the earlier one already counted.
            continue;
        }
        let Some(end) = offset.checked_add(length).filter(|end| *end <= units.len()) else {
            break;
        };
        if length == 0 || !is_separator_gap(&units[cursor..offset]) {
            break;
        }
        run.push(target);
        cursor = end;
    }
    run
}

fn is_separator_gap(units: &[u16]) -> bool {
    char::decode_utf16(units.iter().copied()).all(|unit| {
        unit.is_ok_and(|character| character.is_whitespace() || RUN_SEPARATORS.contains(&character))
    })
}

/// Classifies the addressee of `message` for the agent `bot_user_id`.
pub fn classify_addressee(message: &GroupMessage, bot_user_id: i64) -> AddresseeKind {
    let me = Mention::User {
        user_id: bot_user_id,
    };
    let leading = leading_mentions(message);
    if !leading.is_empty() {
        return if leading.contains(&me) {
            AddresseeKind::Me {
                reason: if message.command().is_some() {
                    DirectReason::Command
                } else {
                    DirectReason::LeadingMention
                },
            }
        } else {
            AddresseeKind::Others
        };
    }

    let command = message.command();
    match command {
        Some((_, Some(target))) if target == bot_user_id => {
            return AddresseeKind::Me {
                reason: DirectReason::Command,
            };
        }
        Some((_, Some(_))) => return AddresseeKind::Others,
        _ => {}
    }

    let human = !message.author.kind.is_agent();
    let reason = if message.mentions_user(bot_user_id) {
        Some(DirectReason::Mention)
    } else if message
        .reply_to
        .is_some_and(|reply| reply.author_user_id == bot_user_id)
    {
        Some(DirectReason::Reply)
    } else if human && message.via == SentVia::WorkBar {
        Some(DirectReason::WorkBar)
    } else if human && message.conversation == Conversation::Dm {
        Some(DirectReason::Dm)
    } else if human && message.conversation == Conversation::WorkThread {
        Some(DirectReason::WorkThread)
    } else {
        None
    };

    match (reason, command) {
        (Some(_), Some(_)) => AddresseeKind::Me {
            reason: DirectReason::Command,
        },
        (Some(reason), None) => AddresseeKind::Me { reason },
        // An unqualified command with no other addressing is for no one in
        // particular; several agents may share the thread.
        (None, _) => AddresseeKind::Unaddressed,
    }
}

/// Everything intake needs besides the message.
#[derive(Clone, Copy, Debug)]
pub struct IntakeFacts<'a> {
    pub message: &'a GroupMessage,
    pub bot_user_id: i64,
    pub access: Access,
    /// This agent's participation in the message's thread; `None` when it has
    /// not joined.
    pub participation: Option<ParticipationMode>,
    /// The agent-only loop guard's verdict for this thread, recorded with this
    /// message counted. Only consulted for agent senders addressing this agent.
    pub loop_verdict: LoopVerdict,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ObserveReason {
    AddressedToOthers,
    Unaddressed,
    /// Direct input from a sender without access: context only, never a turn.
    NotGranted,
    /// An agent addressed this agent after the loop cap was reached.
    LoopCapReached,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SkipReason {
    SelfAuthored,
    NotParticipating,
    Muted,
    NotGranted,
    LoopCapReached,
}

/// What the agent does with one message.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum IntakeDecision {
    /// Direct input: start work, steer it, queue with `/queue`, or run the
    /// command. Also restarts paused work. `join` is set when the agent was
    /// not participating yet (a mention joins it in active mode).
    Act { reason: DirectReason, join: bool },
    /// Passive context at the next native boundary. `consider` marks an
    /// unaddressed human message the speak gate may evaluate.
    Observe {
        reason: ObserveReason,
        consider: bool,
    },
    /// Neither a turn nor passive context.
    Skip { reason: SkipReason },
}

impl IntakeDecision {
    /// Whether the owner (and, for the loop cap, the other agent's owner)
    /// should see a notice about this message.
    pub const fn needs_notice(&self) -> bool {
        matches!(
            self,
            Self::Observe {
                reason: ObserveReason::NotGranted | ObserveReason::LoopCapReached,
                ..
            } | Self::Skip {
                reason: SkipReason::NotGranted | SkipReason::LoopCapReached,
            }
        )
    }
}

/// Applies the intake rules to one message.
pub fn decide_intake(facts: IntakeFacts<'_>) -> IntakeDecision {
    let message = facts.message;
    if message.author.user_id == facts.bot_user_id {
        return IntakeDecision::Skip {
            reason: SkipReason::SelfAuthored,
        };
    }
    let observes = matches!(
        facts.participation,
        Some(ParticipationMode::Active | ParticipationMode::MentionsOnly)
    );
    let observe_or_skip = |observe: ObserveReason, skip: SkipReason| {
        if observes {
            IntakeDecision::Observe {
                reason: observe,
                consider: false,
            }
        } else {
            IntakeDecision::Skip { reason: skip }
        }
    };
    let ambient_skip = if facts.participation.is_some() {
        SkipReason::Muted
    } else {
        SkipReason::NotParticipating
    };
    let agent_sender = message.author.kind.is_agent();

    match classify_addressee(message, facts.bot_user_id) {
        AddresseeKind::Me { reason } => {
            if !facts.access.may_invoke() {
                return observe_or_skip(ObserveReason::NotGranted, SkipReason::NotGranted);
            }
            if agent_sender && matches!(facts.loop_verdict, LoopVerdict::CapReached { .. }) {
                return observe_or_skip(ObserveReason::LoopCapReached, SkipReason::LoopCapReached);
            }
            IntakeDecision::Act {
                reason,
                join: facts.participation.is_none(),
            }
        }
        AddresseeKind::Others => observe_or_skip(ObserveReason::AddressedToOthers, ambient_skip),
        AddresseeKind::Unaddressed => {
            let consider = !agent_sender
                && facts.access.may_invoke()
                && facts.participation == Some(ParticipationMode::Active);
            match observe_or_skip(ObserveReason::Unaddressed, ambient_skip) {
                IntakeDecision::Observe { reason, .. } => {
                    IntakeDecision::Observe { reason, consider }
                }
                other => other,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::group::envelope::{Author, AuthorKind, MessageEntity, ReplyRef};

    const ME: i64 = 99;
    const OWNER: i64 = 7;
    const ALICE: i64 = 8;
    const OTHER_BOT: i64 = 41;

    fn human(user_id: i64) -> Author {
        Author {
            user_id,
            display_name: format!("human {user_id}"),
            kind: AuthorKind::Human,
        }
    }

    fn agent(user_id: i64) -> Author {
        Author {
            user_id,
            display_name: format!("agent {user_id}"),
            kind: AuthorKind::Agent {
                owner_user_id: Some(OWNER),
                work: None,
            },
        }
    }

    fn message(author: Author, conversation: Conversation, text: &str) -> GroupMessage {
        GroupMessage {
            chat_id: 1,
            message_id: 10,
            author,
            conversation,
            via: SentVia::Composer,
            text: text.to_string(),
            entities: Vec::new(),
            reply_to: None,
            sent_at: 0,
        }
    }

    /// Adds a mention entity covering the first occurrence of `needle`.
    fn mention(mut message: GroupMessage, needle: &str, user_id: i64) -> GroupMessage {
        let byte = message.text.find(needle).expect("needle in text");
        let offset = message.text[..byte].encode_utf16().count() as u32;
        let length = needle.encode_utf16().count() as u32;
        message.entities.push(MessageEntity::Mention {
            offset,
            length,
            target: Mention::User { user_id },
        });
        message
    }

    fn reply_to(mut message: GroupMessage, author_user_id: i64) -> GroupMessage {
        message.reply_to = Some(ReplyRef {
            message_id: 5,
            author_user_id,
        });
        message
    }

    fn command(mut message: GroupMessage, name: &str, target: Option<i64>) -> GroupMessage {
        message.entities.push(MessageEntity::Command {
            offset: 0,
            length: name.len() as u32 + 1,
            name: name.to_string(),
            target_user_id: target,
        });
        message
    }

    fn facts(message: &GroupMessage) -> IntakeFacts<'_> {
        IntakeFacts {
            message,
            bot_user_id: ME,
            access: Access::Owner,
            participation: Some(ParticipationMode::Active),
            loop_verdict: LoopVerdict::Allowed { hops: 0 },
        }
    }

    fn me(reason: DirectReason) -> AddresseeKind {
        AddresseeKind::Me { reason }
    }

    #[test]
    fn words_never_trigger() {
        for text in [
            "claude can you look",
            "hey codex",
            "@claude fix it",
            "hermes?",
        ] {
            let message = message(human(OWNER), Conversation::Group, text);
            assert_eq!(
                classify_addressee(&message, ME),
                AddresseeKind::Unaddressed,
                "{text}"
            );
        }
    }

    #[test]
    fn leading_run_collects_adjacent_mentions_with_separators() {
        let message = mention(
            mention(
                message(
                    human(OWNER),
                    Conversation::Group,
                    "  @alice, @claude: compare",
                ),
                "@alice",
                ALICE,
            ),
            "@claude",
            ME,
        );
        assert_eq!(
            leading_mentions(&message),
            [
                Mention::User { user_id: ALICE },
                Mention::User { user_id: ME }
            ]
        );
        assert_eq!(
            classify_addressee(&message, ME),
            me(DirectReason::LeadingMention)
        );
    }

    #[test]
    fn leading_run_stops_at_the_first_word() {
        let message = mention(
            mention(
                message(
                    human(OWNER),
                    Conversation::Group,
                    "@alice compare with @claude",
                ),
                "@alice",
                ALICE,
            ),
            "@claude",
            ME,
        );
        assert_eq!(
            leading_mentions(&message),
            [Mention::User { user_id: ALICE }]
        );
        assert_eq!(classify_addressee(&message, ME), AddresseeKind::Others);
    }

    #[test]
    fn leading_mentions_of_others_win_over_reply_thread_and_later_mention() {
        let base = mention(
            message(
                human(OWNER),
                Conversation::WorkThread,
                "@alice what do you think, @claude?",
            ),
            "@alice",
            ALICE,
        );
        let with_later_mention = mention(base.clone(), "@claude", ME);
        let replying = reply_to(with_later_mention.clone(), ME);
        let from_work_bar = GroupMessage {
            via: SentVia::WorkBar,
            ..replying.clone()
        };
        let in_dm = GroupMessage {
            conversation: Conversation::Dm,
            ..base.clone()
        };
        for message in [base, with_later_mention, replying, from_work_bar, in_dm] {
            assert_eq!(classify_addressee(&message, ME), AddresseeKind::Others);
            assert_eq!(
                decide_intake(facts(&message)),
                IntakeDecision::Observe {
                    reason: ObserveReason::AddressedToOthers,
                    consider: false
                }
            );
        }
    }

    #[test]
    fn group_mentions_in_the_leading_run_address_others() {
        let mut message = message(human(OWNER), Conversation::Group, "@team please review");
        message.entities.push(MessageEntity::Mention {
            offset: 0,
            length: 5,
            target: Mention::Group,
        });
        assert_eq!(classify_addressee(&message, ME), AddresseeKind::Others);
    }

    #[test]
    fn a_mention_after_text_is_direct_input() {
        let message = mention(
            message(
                human(OWNER),
                Conversation::Group,
                "can you check this @claude",
            ),
            "@claude",
            ME,
        );
        assert_eq!(classify_addressee(&message, ME), me(DirectReason::Mention));
    }

    #[test]
    fn utf16_offsets_handle_non_bmp_text() {
        // "🙂" is two UTF-16 units; the mention after it is not leading.
        let text = "🙂 @claude hi";
        let leading = mention(
            message(human(OWNER), Conversation::Group, "@claude 🙂 hi"),
            "@claude",
            ME,
        );
        assert_eq!(leading_mentions(&leading), [Mention::User { user_id: ME }]);
        let trailing = mention(
            message(human(OWNER), Conversation::Group, text),
            "@claude",
            ME,
        );
        assert!(leading_mentions(&trailing).is_empty());
        assert_eq!(classify_addressee(&trailing, ME), me(DirectReason::Mention));
    }

    #[test]
    fn malformed_entities_end_the_run_safely() {
        let mut message = message(human(OWNER), Conversation::Group, "@x");
        message.entities.push(MessageEntity::Mention {
            offset: 0,
            length: 50,
            target: Mention::User { user_id: ALICE },
        });
        assert!(leading_mentions(&message).is_empty());
        message.entities = vec![MessageEntity::Mention {
            offset: 0,
            length: 0,
            target: Mention::User { user_id: ALICE },
        }];
        assert!(leading_mentions(&message).is_empty());
    }

    #[test]
    fn structured_direct_reasons_for_humans() {
        let dm = message(human(OWNER), Conversation::Dm, "fix it");
        assert_eq!(classify_addressee(&dm, ME), me(DirectReason::Dm));
        let work = message(human(ALICE), Conversation::WorkThread, "and the docs");
        assert_eq!(classify_addressee(&work, ME), me(DirectReason::WorkThread));
        let bar = GroupMessage {
            via: SentVia::WorkBar,
            ..message(human(ALICE), Conversation::Group, "go on")
        };
        assert_eq!(classify_addressee(&bar, ME), me(DirectReason::WorkBar));
        let reply = reply_to(message(human(ALICE), Conversation::Group, "why?"), ME);
        assert_eq!(classify_addressee(&reply, ME), me(DirectReason::Reply));
        let reply_other = reply_to(message(human(ALICE), Conversation::Group, "why?"), OWNER);
        assert_eq!(
            classify_addressee(&reply_other, ME),
            AddresseeKind::Unaddressed
        );
    }

    #[test]
    fn agents_need_a_mention_or_reply() {
        for conversation in [
            Conversation::Dm,
            Conversation::WorkThread,
            Conversation::Group,
        ] {
            let plain = message(agent(OTHER_BOT), conversation, "done");
            assert_eq!(classify_addressee(&plain, ME), AddresseeKind::Unaddressed);
        }
        let bar = GroupMessage {
            via: SentVia::WorkBar,
            ..message(agent(OTHER_BOT), Conversation::Group, "x")
        };
        assert_eq!(classify_addressee(&bar, ME), AddresseeKind::Unaddressed);
        let mentioned = mention(
            message(
                agent(OTHER_BOT),
                Conversation::Group,
                "@claude please review",
            ),
            "@claude",
            ME,
        );
        assert_eq!(
            classify_addressee(&mentioned, ME),
            me(DirectReason::LeadingMention)
        );
        let replied = reply_to(message(agent(OTHER_BOT), Conversation::Group, "result"), ME);
        assert_eq!(classify_addressee(&replied, ME), me(DirectReason::Reply));
    }

    #[test]
    fn commands_need_a_target_or_direct_addressing() {
        let targeted = command(
            message(human(OWNER), Conversation::Group, "/status@claude"),
            "status",
            Some(ME),
        );
        assert_eq!(classify_addressee(&targeted, ME), me(DirectReason::Command));
        let other = command(
            message(human(OWNER), Conversation::Dm, "/status@codex"),
            "status",
            Some(OTHER_BOT),
        );
        assert_eq!(classify_addressee(&other, ME), AddresseeKind::Others);
        let unqualified_group = command(
            message(human(OWNER), Conversation::Group, "/status"),
            "status",
            None,
        );
        assert_eq!(
            classify_addressee(&unqualified_group, ME),
            AddresseeKind::Unaddressed
        );
        let unqualified_dm = command(
            message(human(OWNER), Conversation::Dm, "/status"),
            "status",
            None,
        );
        assert_eq!(
            classify_addressee(&unqualified_dm, ME),
            me(DirectReason::Command)
        );
    }

    #[test]
    fn self_authored_messages_are_skipped() {
        let own = message(agent(ME), Conversation::Group, "final answer");
        assert_eq!(
            decide_intake(facts(&own)),
            IntakeDecision::Skip {
                reason: SkipReason::SelfAuthored
            }
        );
    }

    #[test]
    fn direct_input_acts_and_joins_when_not_participating() {
        let message = mention(
            message(human(ALICE), Conversation::Group, "@claude help"),
            "@claude",
            ME,
        );
        let mut joining = facts(&message);
        joining.access = Access::Grantee;
        joining.participation = None;
        assert_eq!(
            decide_intake(joining),
            IntakeDecision::Act {
                reason: DirectReason::LeadingMention,
                join: true
            }
        );
        // Muted agents still take direct input, without rejoining.
        joining.participation = Some(ParticipationMode::Muted);
        assert_eq!(
            decide_intake(joining),
            IntakeDecision::Act {
                reason: DirectReason::LeadingMention,
                join: false
            }
        );
    }

    #[test]
    fn a_mention_never_grants_access() {
        let message = mention(
            message(human(ALICE), Conversation::Group, "@claude delete it"),
            "@claude",
            ME,
        );
        let mut ungranted = facts(&message);
        ungranted.access = Access::None;
        let decision = decide_intake(ungranted);
        assert_eq!(
            decision,
            IntakeDecision::Observe {
                reason: ObserveReason::NotGranted,
                consider: false
            }
        );
        assert!(decision.needs_notice());
        ungranted.participation = None;
        assert_eq!(
            decide_intake(ungranted),
            IntakeDecision::Skip {
                reason: SkipReason::NotGranted
            }
        );
    }

    #[test]
    fn unaddressed_humans_are_considered_only_in_active_mode_with_access() {
        let message = message(
            human(ALICE),
            Conversation::Group,
            "anyone know why CI fails?",
        );
        let mut active = facts(&message);
        active.access = Access::Grantee;
        assert_eq!(
            decide_intake(active),
            IntakeDecision::Observe {
                reason: ObserveReason::Unaddressed,
                consider: true
            }
        );
        let mut mentions_only = active;
        mentions_only.participation = Some(ParticipationMode::MentionsOnly);
        assert_eq!(
            decide_intake(mentions_only),
            IntakeDecision::Observe {
                reason: ObserveReason::Unaddressed,
                consider: false
            }
        );
        let mut ungranted = active;
        ungranted.access = Access::None;
        assert_eq!(
            decide_intake(ungranted),
            IntakeDecision::Observe {
                reason: ObserveReason::Unaddressed,
                consider: false
            }
        );
        let mut muted = active;
        muted.participation = Some(ParticipationMode::Muted);
        assert_eq!(
            decide_intake(muted),
            IntakeDecision::Skip {
                reason: SkipReason::Muted
            }
        );
        let mut absent = active;
        absent.participation = None;
        assert_eq!(
            decide_intake(absent),
            IntakeDecision::Skip {
                reason: SkipReason::NotParticipating
            }
        );
    }

    #[test]
    fn agent_messages_not_addressed_to_me_are_observed_only() {
        let message = message(agent(OTHER_BOT), Conversation::Group, "I updated the docs");
        assert_eq!(
            decide_intake(facts(&message)),
            IntakeDecision::Observe {
                reason: ObserveReason::Unaddressed,
                consider: false
            }
        );
    }

    #[test]
    fn agent_messages_addressed_to_me_act_within_the_loop_cap() {
        let message = mention(
            message(agent(OTHER_BOT), Conversation::Group, "@claude your turn"),
            "@claude",
            ME,
        );
        let mut agent_facts = facts(&message);
        agent_facts.access = Access::Grantee;
        assert!(matches!(
            decide_intake(agent_facts),
            IntakeDecision::Act { .. }
        ));
        agent_facts.loop_verdict = LoopVerdict::CapReached {
            hops: 31,
            limit: 30,
            notify_owners: true,
        };
        let capped = decide_intake(agent_facts);
        assert_eq!(
            capped,
            IntakeDecision::Observe {
                reason: ObserveReason::LoopCapReached,
                consider: false
            }
        );
        assert!(capped.needs_notice());

        // Humans are never subject to the agent-only loop cap.
        let human_message = mention(message_from_human_in_group("@claude go"), "@claude", ME);
        let mut human_facts = facts(&human_message);
        human_facts.loop_verdict = agent_facts.loop_verdict;
        assert!(matches!(
            decide_intake(human_facts),
            IntakeDecision::Act { .. }
        ));
    }

    fn message_from_human_in_group(text: &str) -> GroupMessage {
        message(human(OWNER), Conversation::Group, text)
    }

    #[test]
    fn decision_table_over_senders_modes_and_addressing() {
        let modes = [
            None,
            Some(ParticipationMode::Active),
            Some(ParticipationMode::MentionsOnly),
            Some(ParticipationMode::Muted),
        ];
        let accesses = [Access::Owner, Access::Grantee, Access::None];
        for agent_sender in [false, true] {
            let author = if agent_sender {
                agent(OTHER_BOT)
            } else {
                human(ALICE)
            };
            let direct = mention(
                message(author.clone(), Conversation::Group, "@claude x"),
                "@claude",
                ME,
            );
            let others = mention(
                message(author.clone(), Conversation::Group, "@alice x"),
                "@alice",
                ALICE,
            );
            let ambient = message(author.clone(), Conversation::Group, "x");
            for participation in modes {
                for access in accesses {
                    let mut f = facts(&direct);
                    f.access = access;
                    f.participation = participation;
                    let decision = decide_intake(f);
                    if access.may_invoke() {
                        assert!(matches!(decision, IntakeDecision::Act { .. }));
                    } else {
                        assert!(!matches!(decision, IntakeDecision::Act { .. }));
                    }

                    for ambient_message in [&others, &ambient] {
                        let mut f = facts(ambient_message);
                        f.access = access;
                        f.participation = participation;
                        let decision = decide_intake(f);
                        assert!(!matches!(decision, IntakeDecision::Act { .. }));
                        let observes = matches!(
                            participation,
                            Some(ParticipationMode::Active | ParticipationMode::MentionsOnly)
                        );
                        assert_eq!(matches!(decision, IntakeDecision::Observe { .. }), observes);
                        let considers =
                            matches!(decision, IntakeDecision::Observe { consider: true, .. });
                        assert_eq!(
                            considers,
                            std::ptr::eq(ambient_message, &ambient)
                                && !agent_sender
                                && access.may_invoke()
                                && participation == Some(ParticipationMode::Active)
                        );
                    }
                }
            }
        }
    }
}
