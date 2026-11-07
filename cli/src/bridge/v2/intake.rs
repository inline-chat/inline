//! Inline messages and grants in the group layer's terms.

use std::collections::HashMap;

use inline_agent_bridge::group::{
    Author, AuthorKind, Conversation, Grants, GroupMessage, Mention, MessageEntity, ReplyRef,
    SentVia,
};
use inline_client::{MessageContent, MessageRecord};
use inline_protocol::proto;

/// What the runtime knows about the message's chat and authors.
pub(crate) struct MessageFacts<'a> {
    pub bot_user_id: i64,
    pub bot_username: &'a str,
    pub conversation: Conversation,
    /// Author of the replied-to message (0 when unknown); `None` without a
    /// reply.
    pub reply_author: Option<i64>,
    /// The replied-to message mentions this message's author.
    pub reply_mentions_author: bool,
    /// For a bot author, the person it acts for, when known.
    pub author_owner: Option<i64>,
    pub author_name: String,
}

pub(crate) fn message_text(content: &MessageContent) -> &str {
    match content {
        MessageContent::Text { text } => text,
        MessageContent::Media { caption, .. } => caption.as_deref().unwrap_or_default(),
        _ => "",
    }
}

pub(crate) fn group_message(message: &MessageRecord, facts: MessageFacts<'_>) -> GroupMessage {
    let text = message_text(&message.content).to_owned();
    let units = text.encode_utf16().collect::<Vec<_>>();
    let entities = message
        .metadata
        .entities
        .iter()
        .filter_map(|entity| {
            let offset = u32::try_from(entity.offset).ok()?;
            let length = u32::try_from(entity.length).ok()?;
            match entity.kind.as_str() {
                "TYPE_MENTION" => Some(MessageEntity::Mention {
                    offset,
                    length,
                    target: Mention::User {
                        user_id: entity.user_id?.get(),
                    },
                }),
                "TYPE_GROUP_MENTION" => Some(MessageEntity::Mention {
                    offset,
                    length,
                    target: Mention::Group,
                }),
                "TYPE_BOT_COMMAND" => {
                    let start = offset as usize;
                    let end = start.checked_add(length as usize)?.min(units.len());
                    let raw = String::from_utf16_lossy(units.get(start..end)?);
                    let (name, text_target) =
                        command_parts(&raw, facts.bot_user_id, facts.bot_username);
                    // Apps insert a bare `/cmd` when one bot offers it and carry
                    // that bot on the entity; the server fills it in for typed
                    // commands too. Prefer it over the `@bot` text suffix.
                    let target = match entity.user_id.map(|id| id.get()) {
                        Some(id) if id == facts.bot_user_id => Some(facts.bot_user_id),
                        Some(_) => Some(-1),
                        None => text_target,
                    };
                    Some(MessageEntity::Command {
                        offset,
                        length,
                        name,
                        target_user_id: target,
                    })
                }
                "TYPE_THREAD" => Some(MessageEntity::Link {
                    chat_id: entity.chat_id?.get(),
                    message_id: None,
                }),
                _ => None,
            }
        })
        .collect();
    let is_bot = message.metadata.sender_is_bot.unwrap_or(false);
    GroupMessage {
        chat_id: message.chat_id.get(),
        message_id: message.message_id.get(),
        author: Author {
            user_id: message.sender_id.get(),
            display_name: facts.author_name,
            kind: if is_bot {
                AuthorKind::Agent {
                    owner_user_id: facts.author_owner,
                    work: None,
                }
            } else {
                AuthorKind::Human
            },
        },
        conversation: facts.conversation,
        via: SentVia::Composer,
        text,
        entities,
        reply_to: message.reply_to_message_id.zip(facts.reply_author).map(
            |(message_id, author)| ReplyRef {
                message_id: message_id.get(),
                author_user_id: author,
                mentions_author: facts.reply_mentions_author,
            },
        ),
        sent_at: message.timestamp,
    }
}

/// Whether a fetched message has a mention entity of `user_id`.
pub(crate) fn mentions_user(message: &proto::Message, user_id: i64) -> bool {
    use proto::message_entity::Entity;
    message.entities.as_ref().is_some_and(|entities| {
        entities.entities.iter().any(|entity| {
            matches!(&entity.entity, Some(Entity::Mention(mention)) if mention.user_id == user_id)
        })
    })
}

/// `/stop@claude_bot` → (`stop`, target). A suffix naming another bot gets a
/// target that is never this bot, so the command is for someone else.
fn command_parts(raw: &str, bot_user_id: i64, bot_username: &str) -> (String, Option<i64>) {
    let raw = raw.trim().trim_start_matches('/');
    match raw.split_once('@') {
        Some((name, username)) if username.eq_ignore_ascii_case(bot_username) => {
            (name.to_ascii_lowercase(), Some(bot_user_id))
        }
        Some((name, _)) => (name.to_ascii_lowercase(), Some(-1)),
        None => (raw.to_ascii_lowercase(), None),
    }
}

/// Grants by user from `listAgentGrants`. The owner is never in the list.
pub(crate) fn grants_by_user(result: &proto::ListAgentGrantsResult) -> HashMap<i64, Grants> {
    use proto::AgentGrantOperation as Operation;
    result
        .grants
        .iter()
        .map(|grant| {
            let mut grants = Grants::NONE;
            for operation in &grant.operations {
                match Operation::try_from(*operation) {
                    Ok(Operation::Invoke) => grants.invoke = true,
                    Ok(Operation::Steer) => grants.steer = true,
                    Ok(Operation::Approve) => grants.approve = true,
                    Ok(Operation::Configure) => grants.configure = true,
                    _ => {}
                }
            }
            (grant.user_id, grants)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use inline_agent_bridge::group::{AddresseeKind, DirectReason, classify_addressee};
    use inline_client::{InlineId, MessageEntityRecord, MessageMetadata};

    const BOT: i64 = 99;

    fn record(text: &str, entities: Vec<MessageEntityRecord>) -> MessageRecord {
        MessageRecord {
            chat_id: InlineId::new(5),
            message_id: InlineId::new(10),
            sender_id: InlineId::new(7),
            timestamp: 1,
            is_outgoing: false,
            content: MessageContent::Text {
                text: text.to_owned(),
            },
            reply_to_message_id: None,
            metadata: MessageMetadata {
                entities,
                ..Default::default()
            },
            transaction: None,
        }
    }

    fn entity(kind: &str, offset: i64, length: i64, user_id: Option<i64>) -> MessageEntityRecord {
        MessageEntityRecord {
            kind: kind.to_owned(),
            offset,
            length,
            user_id: user_id.map(InlineId::new),
            agent_id: None,
            group_id: None,
            chat_id: None,
            value: None,
        }
    }

    fn facts() -> MessageFacts<'static> {
        MessageFacts {
            bot_user_id: BOT,
            bot_username: "codex_bot",
            conversation: Conversation::Group,
            reply_author: None,
            reply_mentions_author: false,
            author_owner: None,
            author_name: "Mo".into(),
        }
    }

    #[test]
    fn a_leading_mention_of_another_user_is_for_them() {
        let message = group_message(
            &record(
                "@dena can you check @codex",
                vec![
                    entity("TYPE_MENTION", 0, 5, Some(8)),
                    entity("TYPE_MENTION", 20, 6, Some(BOT)),
                ],
            ),
            facts(),
        );
        assert_eq!(classify_addressee(&message, BOT), AddresseeKind::Others);
    }

    #[test]
    fn commands_keep_their_target() {
        let message = group_message(
            &record(
                "/stop@codex_bot",
                vec![entity("TYPE_BOT_COMMAND", 0, 15, None)],
            ),
            facts(),
        );
        assert_eq!(message.command(), Some(("stop", Some(BOT))));
        let other = group_message(
            &record(
                "/stop@claude_bot",
                vec![entity("TYPE_BOT_COMMAND", 0, 16, None)],
            ),
            facts(),
        );
        assert_eq!(classify_addressee(&other, BOT), AddresseeKind::Others);
    }

    #[test]
    fn bare_commands_use_the_entity_target() {
        let text = "/allowlist @dena @vlad";
        let mine = group_message(
            &record(
                text,
                vec![
                    entity("TYPE_BOT_COMMAND", 0, 10, Some(BOT)),
                    entity("TYPE_MENTION", 11, 5, Some(8)),
                    entity("TYPE_MENTION", 17, 5, Some(9)),
                ],
            ),
            facts(),
        );
        assert_eq!(mine.command(), Some(("allowlist", Some(BOT))));
        assert_eq!(
            classify_addressee(&mine, BOT),
            AddresseeKind::Me {
                reason: DirectReason::Command
            }
        );

        let theirs = group_message(
            &record(text, vec![entity("TYPE_BOT_COMMAND", 0, 10, Some(42))]),
            facts(),
        );
        assert_eq!(classify_addressee(&theirs, BOT), AddresseeKind::Others);
    }

    #[test]
    fn bot_authors_carry_their_owner_and_replies_their_hand_back_fact() {
        let mut bot_record = record("The tests pass.", Vec::new());
        bot_record.metadata.sender_is_bot = Some(true);
        bot_record.reply_to_message_id = Some(InlineId::new(4));
        let message = group_message(
            &bot_record,
            MessageFacts {
                reply_author: Some(BOT),
                reply_mentions_author: true,
                author_owner: Some(3),
                ..facts()
            },
        );
        assert_eq!(
            message.author.kind,
            AuthorKind::Agent {
                owner_user_id: Some(3),
                work: None
            }
        );
        assert_eq!(
            message.reply_to,
            Some(ReplyRef {
                message_id: 4,
                author_user_id: BOT,
                mentions_author: true,
            })
        );
        assert!(inline_agent_bridge::group::is_hand_back(&message, BOT));
    }

    #[test]
    fn fetched_mentions_are_read_from_entities() {
        let replied = proto::Message {
            id: 4,
            from_id: BOT,
            entities: Some(proto::MessageEntities {
                entities: vec![proto::MessageEntity {
                    r#type: proto::message_entity::Type::Mention as i32,
                    offset: 0,
                    length: 6,
                    entity: Some(proto::message_entity::Entity::Mention(
                        proto::message_entity::MessageEntityMention {
                            user_id: 41,
                            agent_id: None,
                        },
                    )),
                }],
            }),
            ..Default::default()
        };
        assert!(mentions_user(&replied, 41));
        assert!(!mentions_user(&replied, 42));
        assert!(!mentions_user(&proto::Message::default(), 41));
    }

    #[test]
    fn grants_map_operations() {
        let result = proto::ListAgentGrantsResult {
            grants: vec![proto::AgentGrant {
                user_id: 8,
                operations: vec![
                    proto::AgentGrantOperation::Invoke as i32,
                    proto::AgentGrantOperation::Approve as i32,
                ],
                ..Default::default()
            }],
            ..Default::default()
        };
        let grants = grants_by_user(&result);
        assert!(grants[&8].invoke && grants[&8].approve && !grants[&8].steer);
    }
}
