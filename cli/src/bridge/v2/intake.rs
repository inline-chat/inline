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
    /// Author of the replied-to message, when it is known locally.
    pub reply_author: Option<i64>,
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
                    // A pasted transcript can carry command entities far
                    // inside its tool output. Only a command at the start,
                    // optionally after structured mentions, is an action.
                    if !has_command_prefix(message, &units, start) {
                        return None;
                    }
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
                    owner_user_id: None,
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
            },
        ),
        sent_at: message.timestamp,
    }
}

fn has_command_prefix(message: &MessageRecord, units: &[u16], start: usize) -> bool {
    let Some(prefix) = units.get(..start) else {
        return false;
    };
    let mut prefix = prefix.to_vec();
    let mut mentioned = false;
    for entity in &message.metadata.entities {
        if matches!(entity.kind.as_str(), "TYPE_CODE" | "TYPE_PRE")
            && entity.offset >= 0
            && entity.length > 0
            && entity.offset as u64 <= start as u64
            && (start as u64) < (entity.offset as u64).saturating_add(entity.length as u64)
        {
            return false;
        }
        if !matches!(entity.kind.as_str(), "TYPE_MENTION" | "TYPE_GROUP_MENTION") {
            continue;
        }
        let (Ok(offset), Ok(length)) = (
            usize::try_from(entity.offset),
            usize::try_from(entity.length),
        ) else {
            continue;
        };
        if let Some(end) = offset.checked_add(length)
            && let Some(mention) = prefix.get_mut(offset..end)
        {
            mention.fill(u16::from(b' '));
            mentioned = true;
        }
    }
    String::from_utf16(&prefix).is_ok_and(|prefix| {
        prefix.chars().all(|character| {
            character.is_whitespace() || (mentioned && matches!(character, ',' | ':' | ';' | '&'))
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
    fn pasted_command_examples_are_content() {
        for text in [
            "Working\n2588: * command: /model <name>, the /config Model row",
            "Please explain /stop without stopping this run",
            "```\n/model opus\n```",
        ] {
            let start = text.find('/').unwrap();
            let command = text[start..].split_whitespace().next().unwrap();
            let message = group_message(
                &record(
                    text,
                    vec![entity(
                        "TYPE_BOT_COMMAND",
                        start as i64,
                        command.len() as i64,
                        None,
                    )],
                ),
                facts(),
            );
            assert_eq!(message.command(), None, "{text}");
        }
    }

    #[test]
    fn commands_after_leading_mentions_still_work_with_utf16_offsets() {
        let text = "  @🤖 /model opus";
        let offset = text[..text.find('/').unwrap()].encode_utf16().count() as i64;
        let message = group_message(
            &record(
                text,
                vec![
                    entity("TYPE_MENTION", 2, 3, Some(BOT)),
                    entity("TYPE_BOT_COMMAND", offset, 6, None),
                ],
            ),
            facts(),
        );
        assert_eq!(message.command(), Some(("model", None)));
    }

    #[test]
    fn a_literal_command_in_a_code_block_is_not_an_action() {
        for kind in ["TYPE_CODE", "TYPE_PRE"] {
            let message = group_message(
                &record(
                    "/stop",
                    vec![
                        entity("TYPE_BOT_COMMAND", 0, 5, None),
                        entity(kind, 0, 5, None),
                    ],
                ),
                facts(),
            );
            assert_eq!(message.command(), None);
        }
    }

    #[test]
    fn leading_mention_separators_keep_commands_actionable() {
        for prefix in ["@Codex: ", "@Codex; ", "@Alice, @Codex & "] {
            let text = format!("{prefix}/stop");
            let mentions: Vec<_> = ["@Alice", "@Codex"]
                .into_iter()
                .filter_map(|name| {
                    prefix.find(name).map(|offset| {
                        entity("TYPE_MENTION", offset as i64, name.len() as i64, Some(BOT))
                    })
                })
                .chain(std::iter::once(entity(
                    "TYPE_BOT_COMMAND",
                    prefix.len() as i64,
                    5,
                    None,
                )))
                .collect();
            assert_eq!(
                group_message(&record(&text, mentions), facts()).command(),
                Some(("stop", None))
            );
        }
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
