//! Attributed inbound envelopes and their native provenance (spec §5.1 rule 1).
//!
//! Every Inline message reaches the group layer as a [`GroupMessage`] built
//! from structured message facts only: author, conversation, reply target,
//! entities and the surface it was sent from. Text is carried for delivery and
//! never inspected for addressing.

use serde::{Deserialize, Serialize};

use crate::harness::{ChatId, Origin, UserId, WorkRef};

/// Channel server name stamped on Claude `origin` for teammate input.
pub const INLINE_CHANNEL_SERVER: &str = "inline";

/// Who wrote a message, as resolved by the transport from Inline user state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Author {
    pub user_id: i64,
    /// Display name as Inline shows it. Untrusted: it never enters trusted
    /// instructions.
    pub display_name: String,
    pub kind: AuthorKind,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AuthorKind {
    Human,
    /// Any bot account, including agents run by other bridges.
    Agent {
        /// The agent's owner when the transport knows it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        owner_user_id: Option<i64>,
        /// The sending agent's work, when the transport knows it (for Claude
        /// `peer.fromSession`). Defaults to the message's chat.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        work: Option<WorkRef>,
    },
}

impl AuthorKind {
    pub const fn is_agent(&self) -> bool {
        matches!(self, Self::Agent { .. })
    }
}

/// Where the message was posted, relative to this agent.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Conversation {
    /// The owner's DM with this agent, or a subthread under it.
    Dm,
    /// A thread whose canonical publication belongs to this agent's work
    /// (its session thread or a subthread it started).
    WorkThread,
    /// Any other thread or group chat.
    Group,
}

/// Inline surface the message was composed in.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SentVia {
    #[default]
    Composer,
    /// The agent work bar for this agent's work.
    WorkBar,
}

/// The target of a structured mention entity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Mention {
    /// A user or bot mention entity.
    User { user_id: i64 },
    /// A group-style mention (a user group, everyone) that names other people
    /// without naming this agent individually.
    Group,
}

/// A structured entity, with offsets in UTF-16 code units as Inline stores
/// them.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum MessageEntity {
    Mention {
        offset: u32,
        length: u32,
        target: Mention,
    },
    /// A bot command entity; `target_user_id` is set for `/command@bot`.
    Command {
        offset: u32,
        length: u32,
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target_user_id: Option<i64>,
    },
    /// A link to an Inline thread or message.
    Link {
        chat_id: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message_id: Option<i64>,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReplyRef {
    pub message_id: i64,
    pub author_user_id: i64,
}

/// One inbound Inline message with the facts the group layer needs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct GroupMessage {
    pub chat_id: i64,
    pub message_id: i64,
    pub author: Author,
    pub conversation: Conversation,
    #[serde(default)]
    pub via: SentVia,
    pub text: String,
    #[serde(default)]
    pub entities: Vec<MessageEntity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<ReplyRef>,
    /// Unix seconds.
    pub sent_at: i64,
}

impl GroupMessage {
    pub fn mentions(&self) -> impl Iterator<Item = (u32, u32, Mention)> + '_ {
        self.entities.iter().filter_map(|entity| match entity {
            MessageEntity::Mention {
                offset,
                length,
                target,
            } => Some((*offset, *length, *target)),
            _ => None,
        })
    }

    pub fn mentions_user(&self, user_id: i64) -> bool {
        self.mentions()
            .any(|(_, _, target)| target == Mention::User { user_id })
    }

    pub fn command(&self) -> Option<(&str, Option<i64>)> {
        self.entities.iter().find_map(|entity| match entity {
            MessageEntity::Command {
                name,
                target_user_id,
                ..
            } => Some((name.as_str(), *target_user_id)),
            _ => None,
        })
    }

    pub fn links(&self) -> impl Iterator<Item = (i64, Option<i64>)> + '_ {
        self.entities.iter().filter_map(|entity| match entity {
            MessageEntity::Link {
                chat_id,
                message_id,
            } => Some((*chat_id, *message_id)),
            _ => None,
        })
    }
}

/// The contract [`Origin`] of a message author, relative to the agent's owner.
/// A bot account is always an agent, never the owner's voice.
pub fn origin_of(message: &GroupMessage, owner_user_id: i64) -> Origin {
    let author = &message.author;
    match &author.kind {
        AuthorKind::Agent { work, .. } => Origin::Agent {
            bot: UserId(author.user_id),
            work: work.clone().unwrap_or(WorkRef {
                chat: ChatId(message.chat_id),
                session: None,
            }),
        },
        AuthorKind::Human if author.user_id == owner_user_id => Origin::Owner {
            user: UserId(author.user_id),
        },
        AuthorKind::Human => Origin::Teammate {
            user: UserId(author.user_id),
        },
    }
}

/// Claude Code's `SDKMessageOrigin`, as the installed CLI reads it:
/// `{kind:"human"}`, `{kind:"channel",server}`,
/// `{kind:"peer",from,name?,fromSession?}`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ClaudeOrigin {
    Human,
    Channel {
        server: String,
    },
    Peer {
        from: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        #[serde(
            rename = "fromSession",
            default,
            skip_serializing_if = "Option::is_none"
        )]
        from_session: Option<String>,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClaudeInputFields {
    pub origin: ClaudeOrigin,
    #[serde(rename = "shouldQuery")]
    pub should_query: bool,
}

/// Claude's native fields for an input with this origin. `agent_name` is the
/// sending agent's display name (untrusted, informational). Ambient context
/// never queries (`shouldQuery: false`).
pub fn claude_input(origin: &Origin, agent_name: Option<&str>) -> ClaudeInputFields {
    let channel = || ClaudeOrigin::Channel {
        server: INLINE_CHANNEL_SERVER.to_string(),
    };
    let claude_origin = match origin {
        Origin::Owner { .. } => ClaudeOrigin::Human,
        Origin::Teammate { .. } | Origin::Ambient { .. } | Origin::Scheduled => channel(),
        Origin::Agent { bot, work } => ClaudeOrigin::Peer {
            from: format!("inline:user/{}", bot.0),
            name: agent_name
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .map(str::to_string),
            from_session: Some(match &work.session {
                Some(session) => session.as_str().to_string(),
                None => format!("inline:chat/{}", work.chat.0),
            }),
        },
    };
    ClaudeInputFields {
        origin: claude_origin,
        should_query: !matches!(origin, Origin::Ambient { .. }),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexPlacement {
    /// `input` carries the message; sender metadata goes in an `untrusted`
    /// `additionalContext` entry.
    UserInputWithUntrustedSender,
    /// Only an `untrusted` `additionalContext` entry (or `thread/inject_items`).
    UntrustedContextOnly,
}

/// Where Codex receives an input with this origin.
pub const fn codex_placement(origin: &Origin) -> CodexPlacement {
    match origin {
        Origin::Ambient { .. } => CodexPlacement::UntrustedContextOnly,
        _ => CodexPlacement::UserInputWithUntrustedSender,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn message(user_id: i64, kind: AuthorKind) -> GroupMessage {
        GroupMessage {
            chat_id: 3,
            message_id: 2,
            author: Author {
                user_id,
                display_name: format!("user {user_id}"),
                kind,
            },
            conversation: Conversation::Group,
            via: SentVia::Composer,
            text: "hi".into(),
            entities: Vec::new(),
            reply_to: None,
            sent_at: 0,
        }
    }

    #[test]
    fn origin_follows_owner_teammate_and_agent() {
        assert_eq!(
            origin_of(&message(7, AuthorKind::Human), 7),
            Origin::Owner { user: UserId(7) }
        );
        assert_eq!(
            origin_of(&message(8, AuthorKind::Human), 7),
            Origin::Teammate { user: UserId(8) }
        );
        // A bot with the owner's number is still an agent, never the owner.
        let agent = origin_of(
            &message(
                7,
                AuthorKind::Agent {
                    owner_user_id: Some(7),
                    work: None,
                },
            ),
            7,
        );
        assert_eq!(
            agent,
            Origin::Agent {
                bot: UserId(7),
                work: WorkRef {
                    chat: ChatId(3),
                    session: None
                }
            }
        );
        assert!(!agent.can_consent_for_owner());
    }

    #[test]
    fn claude_origin_matches_the_native_wire_shape() {
        let fields =
            |origin: Origin, name| serde_json::to_value(claude_input(&origin, name)).unwrap();
        assert_eq!(
            fields(Origin::Owner { user: UserId(7) }, None),
            json!({"origin": {"kind": "human"}, "shouldQuery": true})
        );
        assert_eq!(
            fields(Origin::Teammate { user: UserId(8) }, None),
            json!({"origin": {"kind": "channel", "server": "inline"}, "shouldQuery": true})
        );
        assert_eq!(
            fields(
                Origin::Agent {
                    bot: UserId(41),
                    work: WorkRef {
                        chat: ChatId(9),
                        session: Some(crate::ProviderSessionId::new("thr_1").unwrap())
                    }
                },
                Some("Mo's Codex · MacBook")
            ),
            json!({
                "origin": {
                    "kind": "peer",
                    "from": "inline:user/41",
                    "name": "Mo's Codex · MacBook",
                    "fromSession": "thr_1"
                },
                "shouldQuery": true
            })
        );
        assert_eq!(
            fields(
                Origin::Agent {
                    bot: UserId(41),
                    work: WorkRef {
                        chat: ChatId(9),
                        session: None
                    }
                },
                Some("  ")
            ),
            json!({
                "origin": {"kind": "peer", "from": "inline:user/41", "fromSession": "inline:chat/9"},
                "shouldQuery": true
            })
        );
        assert_eq!(
            fields(Origin::Ambient { chat: ChatId(3) }, None),
            json!({"origin": {"kind": "channel", "server": "inline"}, "shouldQuery": false})
        );
    }

    #[test]
    fn codex_keeps_ambient_traffic_out_of_user_input() {
        assert_eq!(
            codex_placement(&Origin::Owner { user: UserId(7) }),
            CodexPlacement::UserInputWithUntrustedSender
        );
        assert_eq!(
            codex_placement(&Origin::Ambient { chat: ChatId(3) }),
            CodexPlacement::UntrustedContextOnly
        );
    }

    #[test]
    fn message_round_trips_through_serde() {
        let mut message = message(8, AuthorKind::Human);
        message.entities = vec![
            MessageEntity::Mention {
                offset: 0,
                length: 7,
                target: Mention::User { user_id: 99 },
            },
            MessageEntity::Link {
                chat_id: 5,
                message_id: None,
            },
        ];
        message.reply_to = Some(ReplyRef {
            message_id: 1,
            author_user_id: 99,
        });
        let back: GroupMessage =
            serde_json::from_value(serde_json::to_value(&message).unwrap()).unwrap();
        assert_eq!(back, message);
        assert!(back.mentions_user(99));
        assert_eq!(back.links().collect::<Vec<_>>(), [(5, None)]);
    }
}
