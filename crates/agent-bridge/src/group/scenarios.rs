//! Stage 3 scenarios at the group-layer level: two humans and two agents in
//! one thread through the §5 rules, delegation round trips and the loop cap.
//! Each agent runs its own copy of the rules, as each bridge does.

use std::collections::BTreeMap;

use super::caps::LoopGuards;
use super::envelope::{
    Author, AuthorKind, Conversation, GroupMessage, Mention, MessageEntity, ReplyRef, SentVia,
};
use super::intake::{
    DirectReason, IntakeDecision, IntakeFacts, ObserveReason, SkipReason, WorkPhase, decide_intake,
};
use super::participation::ParticipationMode;
use super::permissions::{Grants, Operation};

const MO: i64 = 7;
const SARA: i64 = 8;
const CODEX: i64 = 41; // Mo's agent
const CLAUDE: i64 = 42; // Sara's agent
const THREAD: i64 = 100;

struct Bridge {
    bot: i64,
    owner: i64,
    grants: BTreeMap<i64, Grants>,
    mode: Option<ParticipationMode>,
    loops: LoopGuards,
    work: WorkPhase,
}

impl Bridge {
    fn new(bot: i64, owner: i64) -> Self {
        Self {
            bot,
            owner,
            grants: BTreeMap::new(),
            mode: Some(ParticipationMode::Active),
            loops: LoopGuards::new(4),
            work: WorkPhase::None,
        }
    }

    fn grant(mut self, user: i64, grants: Grants) -> Self {
        self.grants.insert(user, grants);
        self
    }

    fn see(&mut self, message: &GroupMessage) -> IntakeDecision {
        let verdict = self
            .loops
            .record(message.chat_id, message.author.kind.is_agent());
        let grants = if message.author.user_id == self.owner && !message.author.kind.is_agent() {
            Grants::OWNER
        } else {
            self.grants
                .get(&message.author.user_id)
                .copied()
                .unwrap_or_default()
        };
        decide_intake(IntakeFacts {
            message,
            bot_user_id: self.bot,
            grants,
            participation: self.mode,
            loop_verdict: verdict,
            work: self.work,
        })
    }
}

struct Thread {
    next_id: i64,
}

impl Thread {
    fn new() -> Self {
        Self { next_id: 1 }
    }

    /// A message; `@name` tokens listed in `mentions` become entities.
    fn post(
        &mut self,
        author: i64,
        agent: bool,
        text: &str,
        mentions: &[(&str, i64)],
        reply_to: Option<(i64, i64)>,
    ) -> GroupMessage {
        let message_id = self.next_id;
        self.next_id += 1;
        let entities = mentions
            .iter()
            .map(|(needle, user_id)| {
                let byte = text.find(needle).expect("mention in text");
                MessageEntity::Mention {
                    offset: text[..byte].encode_utf16().count() as u32,
                    length: needle.encode_utf16().count() as u32,
                    target: Mention::User { user_id: *user_id },
                }
            })
            .collect();
        GroupMessage {
            chat_id: THREAD,
            message_id,
            author: Author {
                user_id: author,
                display_name: format!("user {author}"),
                kind: if agent {
                    AuthorKind::Agent {
                        owner_user_id: None,
                        work: None,
                    }
                } else {
                    AuthorKind::Human
                },
            },
            conversation: Conversation::Group,
            via: SentVia::Composer,
            text: text.into(),
            entities,
            reply_to: reply_to.map(|(message_id, author_user_id)| ReplyRef {
                message_id,
                author_user_id,
            }),
            sent_at: message_id,
        }
    }
}

fn acts(decision: IntakeDecision) -> bool {
    matches!(decision, IntakeDecision::Act { .. })
}

fn bridges() -> (Bridge, Bridge) {
    // Mo shares Codex with Sara (invoke + steer); Sara shares Claude with Mo,
    // and both owners let the other's agent invoke theirs.
    let codex = Bridge::new(CODEX, MO)
        .grant(SARA, Grants::MIGRATED_ALLOWLIST)
        .grant(CLAUDE, Grants::MIGRATED_ALLOWLIST);
    let claude = Bridge::new(CLAUDE, SARA)
        .grant(MO, Grants::MIGRATED_ALLOWLIST)
        .grant(CODEX, Grants::MIGRATED_ALLOWLIST);
    (codex, claude)
}

#[test]
fn two_humans_two_agents_follow_the_section_five_rules() {
    let (mut codex, mut claude) = bridges();
    let mut thread = Thread::new();

    // "@Codex @Claude compare": both are in the leading run, both act.
    let both = thread.post(
        MO,
        false,
        "@codex @claude compare",
        &[("@codex", CODEX), ("@claude", CLAUDE)],
        None,
    );
    assert!(acts(codex.see(&both)));
    assert!(acts(claude.see(&both)));

    // Sara addresses Mo by leading mention, naming Codex later: Codex stays
    // quiet and only observes.
    let to_mo = thread.post(
        SARA,
        false,
        "@mo should @codex do this?",
        &[("@mo", MO), ("@codex", CODEX)],
        None,
    );
    assert_eq!(
        codex.see(&to_mo),
        IntakeDecision::Observe {
            reason: ObserveReason::AddressedToOthers,
            consider: false
        }
    );
    assert!(!acts(claude.see(&to_mo)));

    // An unaddressed question is considered by both active agents.
    let question = thread.post(SARA, false, "why is CI red?", &[], None);
    assert_eq!(
        codex.see(&question),
        IntakeDecision::Observe {
            reason: ObserveReason::Unaddressed,
            consider: true
        }
    );
    assert!(matches!(
        claude.see(&question),
        IntakeDecision::Observe { consider: true, .. }
    ));

    // Mentions-only: observed, never considered.
    claude.mode = Some(ParticipationMode::MentionsOnly);
    assert!(matches!(
        claude.see(&question),
        IntakeDecision::Observe {
            consider: false,
            ..
        }
    ));
}

#[test]
fn opt_in_access_holds_for_people_and_agents() {
    let mut codex = Bridge::new(CODEX, MO);
    let mut thread = Thread::new();
    // Sara has no grant on Mo's Codex: her mention is context only.
    let ask = thread.post(SARA, false, "@codex deploy", &[("@codex", CODEX)], None);
    assert_eq!(
        codex.see(&ask),
        IntakeDecision::Observe {
            reason: ObserveReason::NotGranted,
            consider: false
        }
    );
    // Nor can an ungranted agent drive it.
    let bot = thread.post(CLAUDE, true, "@codex deploy", &[("@codex", CODEX)], None);
    assert!(!acts(codex.see(&bot)));
    // A steer-only grant cannot start work, only steer it.
    codex.grants.insert(
        SARA,
        Grants {
            steer: true,
            ..Grants::NONE
        },
    );
    assert!(!acts(codex.see(&ask)));
    codex.work = WorkPhase::Running;
    assert_eq!(
        codex.see(&ask),
        IntakeDecision::Act {
            reason: DirectReason::LeadingMention,
            join: false,
            required: Operation::Steer
        }
    );
}

#[test]
fn delegation_round_trip_wakes_each_agent_once() {
    let (mut codex, mut claude) = bridges();
    let mut thread = Thread::new();
    let ask = thread.post(MO, false, "@codex ship the fix", &[("@codex", CODEX)], None);
    assert!(acts(codex.see(&ask)));
    assert!(!acts(claude.see(&ask)));

    // Codex delegates review with a brief mentioning Claude.
    let brief = thread.post(
        CODEX,
        true,
        "@claude please review the diff",
        &[("@claude", CLAUDE)],
        None,
    );
    assert_eq!(
        codex.see(&brief),
        IntakeDecision::Skip {
            reason: SkipReason::SelfAuthored
        }
    );
    assert!(acts(claude.see(&brief)));

    // Claude's final answer replies to the brief: Codex acts on the result.
    let result = thread.post(
        CLAUDE,
        true,
        "Looks good, one nit",
        &[],
        Some((brief.message_id, CODEX)),
    );
    assert_eq!(
        codex.see(&result),
        IntakeDecision::Act {
            reason: DirectReason::Reply,
            join: false,
            required: Operation::StartWork
        }
    );
    assert!(!acts(claude.see(&result)));

    // Codex's final answer replies to Mo: nobody else wakes.
    let done = thread.post(CODEX, true, "Shipped", &[], Some((ask.message_id, MO)));
    assert!(!acts(claude.see(&done)));
}

#[test]
fn agent_ping_pong_stops_at_the_loop_cap_and_a_human_resets_it() {
    let (mut codex, mut claude) = bridges();
    let mut thread = Thread::new();
    let mut acted = 0;
    let mut capped = false;
    for hop in 0..10 {
        let (author, target, name) = if hop % 2 == 0 {
            (CODEX, CLAUDE, "@claude")
        } else {
            (CLAUDE, CODEX, "@codex")
        };
        let message = thread.post(
            author,
            true,
            &format!("{name} your turn"),
            &[(name, target)],
            None,
        );
        let (sender, receiver) = if author == CODEX {
            (&mut codex, &mut claude)
        } else {
            (&mut claude, &mut codex)
        };
        sender.see(&message);
        match receiver.see(&message) {
            IntakeDecision::Act { .. } => acted += 1,
            IntakeDecision::Observe {
                reason: ObserveReason::LoopCapReached,
                ..
            } => capped = true,
            other => panic!("unexpected {other:?}"),
        }
    }
    // Cap of 4 hops in this test: the 5th agent-only message stops.
    assert_eq!(acted, 4);
    assert!(capped);

    let human = thread.post(MO, false, "ok, keep going", &[], None);
    codex.see(&human);
    claude.see(&human);
    let again = thread.post(CODEX, true, "@claude next", &[("@claude", CLAUDE)], None);
    codex.see(&again);
    assert!(acts(claude.see(&again)));
}
