//! Attributed inbound envelopes and their native provenance (spec §5.1 rule 1).
//!
//! Every Inline message reaches the group layer as a [`GroupMessage`] built
//! from structured message facts only: author, conversation, reply target,
//! entities and the surface it was sent from. Text is carried for delivery and
//! never inspected for addressing.

use serde::{Deserialize, Serialize};

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
        /// Opaque reference to the sending agent's work, when known (for
        /// Claude `peer.fromSession`).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        work: Option<String>,
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

/// Who an input speaks for. Only the owner's own voice carries the owner's
/// consent; teammates and agents never consent on the owner's behalf.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Provenance {
    Owner {
        user_id: i64,
    },
    Teammate {
        user_id: i64,
        name: String,
    },
    Agent {
        bot_user_id: i64,
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        work: Option<String>,
    },
    /// Thread traffic delivered as passive context, not addressed input.
    Ambient {
        chat_id: i64,
    },
}

impl Provenance {
    /// Provenance of a message author relative to the agent's owner.
    pub fn of_author(author: &Author, owner_user_id: i64) -> Self {
        match &author.kind {
            AuthorKind::Agent { work, .. } => Self::Agent {
                bot_user_id: author.user_id,
                name: author.display_name.clone(),
                work: work.clone(),
            },
            AuthorKind::Human if author.user_id == owner_user_id => Self::Owner {
                user_id: author.user_id,
            },
            AuthorKind::Human => Self::Teammate {
                user_id: author.user_id,
                name: author.display_name.clone(),
            },
        }
    }

    /// Whether this input may stand for the owner's consent (for example a
    /// harness trust gate that only accepts human input).
    pub const fn speaks_for_owner(&self) -> bool {
        matches!(self, Self::Owner { .. })
    }

    /// Claude's native `origin` for this input.
    pub fn claude_origin(&self) -> ClaudeOrigin {
        match self {
            Self::Owner { .. } => ClaudeOrigin::Human,
            Self::Teammate { .. } | Self::Ambient { .. } => ClaudeOrigin::Channel {
                server: INLINE_CHANNEL_SERVER.to_string(),
            },
            Self::Agent {
                bot_user_id,
                name,
                work,
            } => ClaudeOrigin::Peer {
                from: format!("inline:user/{bot_user_id}"),
                name: Some(name.clone()).filter(|name| !name.trim().is_empty()),
                from_session: work.clone(),
            },
        }
    }

    /// Claude user-message fields: direct input queries, ambient context does
    /// not (`shouldQuery: false`).
    pub fn claude_input(&self) -> ClaudeInputFields {
        ClaudeInputFields {
            origin: self.claude_origin(),
            should_query: !matches!(self, Self::Ambient { .. }),
        }
    }

    /// Where Codex receives this input. Direct input is user input with its
    /// sender metadata as untrusted context; ambient traffic is untrusted
    /// `additionalContext` only.
    pub const fn codex_placement(&self) -> CodexPlacement {
        match self {
            Self::Ambient { .. } => CodexPlacement::UntrustedContextOnly,
            _ => CodexPlacement::UserInputWithUntrustedSender,
        }
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

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexPlacement {
    /// `input` carries the message; sender metadata goes in an `untrusted`
    /// `additionalContext` entry.
    UserInputWithUntrustedSender,
    /// Only an `untrusted` `additionalContext` entry (or `thread/inject_items`).
    UntrustedContextOnly,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn author(user_id: i64, kind: AuthorKind) -> Author {
        Author {
            user_id,
            display_name: format!("user {user_id}"),
            kind,
        }
    }

    #[test]
    fn provenance_follows_owner_teammate_and_agent() {
        assert_eq!(
            Provenance::of_author(&author(7, AuthorKind::Human), 7),
            Provenance::Owner { user_id: 7 }
        );
        assert!(matches!(
            Provenance::of_author(&author(8, AuthorKind::Human), 7),
            Provenance::Teammate { user_id: 8, .. }
        ));
        // A bot account is an agent even when its id equals the owner's
        // number space; ownership never upgrades it to the owner's voice.
        let agent = Provenance::of_author(
            &author(
                7,
                AuthorKind::Agent {
                    owner_user_id: Some(7),
                    work: None,
                },
            ),
            7,
        );
        assert!(matches!(agent, Provenance::Agent { bot_user_id: 7, .. }));
        assert!(!agent.speaks_for_owner());
    }

    #[test]
    fn only_the_owner_speaks_for_the_owner() {
        assert!(Provenance::Owner { user_id: 7 }.speaks_for_owner());
        assert!(
            !Provenance::Teammate {
                user_id: 8,
                name: "Sara".into()
            }
            .speaks_for_owner()
        );
        assert!(!Provenance::Ambient { chat_id: 1 }.speaks_for_owner());
    }

    #[test]
    fn claude_origin_matches_the_native_wire_shape() {
        assert_eq!(
            serde_json::to_value(Provenance::Owner { user_id: 7 }.claude_input()).unwrap(),
            json!({"origin": {"kind": "human"}, "shouldQuery": true})
        );
        assert_eq!(
            serde_json::to_value(
                Provenance::Teammate {
                    user_id: 8,
                    name: "Sara".into()
                }
                .claude_input()
            )
            .unwrap(),
            json!({"origin": {"kind": "channel", "server": "inline"}, "shouldQuery": true})
        );
        assert_eq!(
            serde_json::to_value(
                Provenance::Agent {
                    bot_user_id: 41,
                    name: "Mo's Codex · MacBook".into(),
                    work: Some("inline:work/9".into()),
                }
                .claude_input()
            )
            .unwrap(),
            json!({
                "origin": {
                    "kind": "peer",
                    "from": "inline:user/41",
                    "name": "Mo's Codex · MacBook",
                    "fromSession": "inline:work/9"
                },
                "shouldQuery": true
            })
        );
        assert_eq!(
            serde_json::to_value(Provenance::Ambient { chat_id: 3 }.claude_input()).unwrap(),
            json!({"origin": {"kind": "channel", "server": "inline"}, "shouldQuery": false})
        );
    }

    #[test]
    fn peer_origin_omits_blank_names_and_unknown_sessions() {
        let origin = Provenance::Agent {
            bot_user_id: 41,
            name: "  ".into(),
            work: None,
        }
        .claude_origin();
        assert_eq!(
            serde_json::to_value(origin).unwrap(),
            json!({"kind": "peer", "from": "inline:user/41"})
        );
    }

    #[test]
    fn codex_keeps_ambient_traffic_out_of_user_input() {
        assert_eq!(
            Provenance::Owner { user_id: 7 }.codex_placement(),
            CodexPlacement::UserInputWithUntrustedSender
        );
        assert_eq!(
            Provenance::Agent {
                bot_user_id: 41,
                name: "Codex".into(),
                work: None
            }
            .codex_placement(),
            CodexPlacement::UserInputWithUntrustedSender
        );
        assert_eq!(
            Provenance::Ambient { chat_id: 3 }.codex_placement(),
            CodexPlacement::UntrustedContextOnly
        );
    }

    #[test]
    fn message_round_trips_through_serde() {
        let message = GroupMessage {
            chat_id: 1,
            message_id: 2,
            author: author(8, AuthorKind::Human),
            conversation: Conversation::Group,
            via: SentVia::Composer,
            text: "@claude look".into(),
            entities: vec![
                MessageEntity::Mention {
                    offset: 0,
                    length: 7,
                    target: Mention::User { user_id: 99 },
                },
                MessageEntity::Link {
                    chat_id: 5,
                    message_id: None,
                },
            ],
            reply_to: Some(ReplyRef {
                message_id: 1,
                author_user_id: 99,
            }),
            sent_at: 10,
        };
        let value = serde_json::to_value(&message).unwrap();
        let back: GroupMessage = serde_json::from_value(value).unwrap();
        assert_eq!(back, message);
        assert!(back.mentions_user(99));
        assert_eq!(back.links().collect::<Vec<_>>(), [(5, None)]);
    }
}
