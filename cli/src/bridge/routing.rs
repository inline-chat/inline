//! Inline-native message addressing for the local agent bridge.

use super::*;
use inline_client::{ClientStore, DialogFollowMode, MessageRecord};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct MessageRoute {
    pub addressing: Addressing,
    pub bot_authored: bool,
    pub command_target_bot_user_id: Option<i64>,
}

pub(super) fn with_agent_session_thread_addressing(
    mut route: MessageRoute,
    is_agent_session_thread: bool,
) -> MessageRoute {
    if is_agent_session_thread && !route.bot_authored && route.addressing == Addressing::None {
        // A bound session thread is already an explicit, durable destination
        // for this provider. Reuse the existing addressed-conversation policy
        // path so ordinary text and unqualified commands continue that exact
        // session without requiring a mention, reply, or viewer follow flag.
        route.addressing = Addressing::Followed;
    }
    route
}

pub(super) async fn message_sender_is_bot(
    bot_store: &SqliteStore,
    message: &MessageRecord,
) -> Result<bool, Box<dyn std::error::Error>> {
    if let Some(sender_is_bot) = message.metadata.sender_is_bot {
        return Ok(sender_is_bot);
    }
    Ok(bot_store
        .user(message.sender_id)
        .await?
        .is_some_and(|user| user.is_bot == Some(true)))
}

/// Resolves message-local addressing from the bot-visible record and joins it
/// with the owner's viewer-specific native follow state. Missing owner state
/// fails closed for follow-only messages without weakening mention or reply
/// triggers.
pub(super) async fn resolve_message_route(
    message: &MessageRecord,
    owner_dm_chat_id: i64,
    bot_user_id: i64,
    bot_store: &SqliteStore,
    owner_control: Option<&OwnerControl>,
) -> Result<MessageRoute, Box<dyn std::error::Error>> {
    let self_authored = message.is_outgoing || message.sender_id.get() == bot_user_id;
    if self_authored {
        return Ok(MessageRoute {
            addressing: Addressing::None,
            bot_authored: true,
            command_target_bot_user_id: None,
        });
    }

    let sender_is_bot = message_sender_is_bot(bot_store, message).await?;
    let owner_dm_conversation =
        is_owner_dm_conversation(bot_store, message.chat_id.get(), owner_dm_chat_id).await?;
    let exact_mention = message.metadata.entities.iter().any(|entity| {
        entity.kind == "TYPE_MENTION"
            && entity
                .user_id
                .is_some_and(|user_id| user_id.get() == bot_user_id)
    });
    let mentioned = exact_mention || (!sender_is_bot && message.metadata.mentioned == Some(true));
    let command_target_bot_user_id = message.metadata.entities.iter().find_map(|entity| {
        (entity.kind == "TYPE_BOT_COMMAND")
            .then_some(entity.user_id)
            .flatten()
            .map(InlineId::get)
    });
    let mut reply_to_bot = match (sender_is_bot, message.reply_to_message_id) {
        (false, Some(reply_id)) => bot_store
            .message(message.chat_id, reply_id)
            .await?
            .is_some_and(|reply| reply.is_outgoing || reply.sender_id.get() == bot_user_id),
        _ => false,
    };
    let mut followed = if sender_is_bot || owner_dm_conversation {
        false
    } else {
        match owner_control {
            Some(owner) => matches!(
                owner.follow_mode(message.chat_id.get()).await?,
                Some(DialogFollowMode::Following)
            ),
            None => false,
        }
    };
    if !mentioned && starts_with_other_user_mention(message, bot_user_id) {
        reply_to_bot = false;
        followed = false;
    }

    Ok(MessageRoute {
        addressing: AddressSignals {
            owner_dm: !sender_is_bot && owner_dm_conversation,
            mentioned,
            reply_to_bot,
            followed,
        }
        .resolve(),
        bot_authored: sender_is_bot,
        command_target_bot_user_id,
    })
}

async fn is_owner_dm_conversation(
    bot_store: &SqliteStore,
    chat_id: i64,
    owner_dm_chat_id: i64,
) -> Result<bool, Box<dyn std::error::Error>> {
    let mut current_chat_id = chat_id;
    let mut visited = HashSet::new();
    for _ in 0..16 {
        if current_chat_id == owner_dm_chat_id {
            return Ok(true);
        }
        if !visited.insert(current_chat_id) {
            return Ok(false);
        }
        let Some(dialog) = bot_store.dialog(InlineId::new(current_chat_id)).await? else {
            return Ok(false);
        };
        let Some(parent_chat_id) = dialog
            .parent_message_id
            .and(dialog.parent_chat_id)
            .map(InlineId::get)
        else {
            return Ok(false);
        };
        current_chat_id = parent_chat_id;
    }
    Ok(false)
}

pub(super) fn starts_with_other_user_mention(message: &MessageRecord, bot_user_id: i64) -> bool {
    let Some(entity) = message
        .metadata
        .entities
        .iter()
        .filter(|entity| entity.offset >= 0)
        .min_by_key(|entity| entity.offset)
    else {
        return false;
    };
    if entity.kind != "TYPE_MENTION"
        || entity
            .user_id
            .is_none_or(|user_id| user_id.get() == bot_user_id)
    {
        return false;
    }
    let MessageContent::Text { text } = &message.content else {
        return false;
    };
    let Ok(offset) = usize::try_from(entity.offset) else {
        return false;
    };
    let prefix = text.encode_utf16().take(offset).collect::<Vec<_>>();
    String::from_utf16(&prefix).is_ok_and(|prefix| prefix.trim().is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use inline_client::{DialogRecord, MessageEntityRecord, MessageMetadata};

    fn message(chat_id: i64, sender_id: i64) -> MessageRecord {
        MessageRecord {
            chat_id: InlineId::new(chat_id),
            message_id: InlineId::new(20),
            sender_id: InlineId::new(sender_id),
            timestamp: 10,
            is_outgoing: false,
            content: MessageContent::Text {
                text: "fix it".to_string(),
            },
            reply_to_message_id: None,
            metadata: MessageMetadata::default(),
            transaction: None,
        }
    }

    #[tokio::test]
    async fn owner_dm_is_addressed_and_bot_messages_are_rejected() {
        let store = SqliteStore::open_in_memory().expect("store");
        let route = resolve_message_route(&message(11, 7), 11, 99, &store, None)
            .await
            .expect("route");
        assert_eq!(route.addressing, Addressing::OwnerDm);

        let mut authored = message(11, 99);
        authored.metadata.mentioned = Some(true);
        let route = resolve_message_route(&authored, 11, 99, &store, None)
            .await
            .expect("route");
        assert!(route.bot_authored);
        assert_eq!(route.addressing, Addressing::None);
    }

    #[tokio::test]
    async fn anchored_owner_dm_descendants_are_owner_conversations() {
        let store = SqliteStore::open_in_memory().expect("store");
        store
            .record_dialog(DialogRecord {
                parent_chat_id: Some(InlineId::new(11)),
                parent_message_id: Some(InlineId::new(20)),
                ..DialogRecord::new(InlineId::new(12))
            })
            .await
            .expect("reply thread");
        store
            .record_dialog(DialogRecord {
                parent_chat_id: Some(InlineId::new(12)),
                parent_message_id: Some(InlineId::new(21)),
                ..DialogRecord::new(InlineId::new(13))
            })
            .await
            .expect("nested reply thread");

        for chat_id in [12, 13] {
            let route = resolve_message_route(&message(chat_id, 7), 11, 99, &store, None)
                .await
                .expect("route");
            assert_eq!(route.addressing, Addressing::OwnerDm);
        }
    }

    #[tokio::test]
    async fn unrelated_reply_threads_do_not_become_owner_dms() {
        let store = SqliteStore::open_in_memory().expect("store");
        store
            .record_dialog(DialogRecord {
                parent_chat_id: Some(InlineId::new(44)),
                parent_message_id: Some(InlineId::new(20)),
                ..DialogRecord::new(InlineId::new(45))
            })
            .await
            .expect("reply thread");
        let route = resolve_message_route(&message(45, 7), 11, 99, &store, None)
            .await
            .expect("route");
        assert_eq!(route.addressing, Addressing::None);
    }

    #[test]
    fn bound_agent_session_thread_addresses_plain_user_traffic() {
        let plain = MessageRoute {
            addressing: Addressing::None,
            bot_authored: false,
            command_target_bot_user_id: None,
        };
        assert_eq!(
            with_agent_session_thread_addressing(plain, true).addressing,
            Addressing::Followed
        );
        assert_eq!(
            with_agent_session_thread_addressing(plain, false).addressing,
            Addressing::None
        );

        let bot = MessageRoute {
            bot_authored: true,
            ..plain
        };
        assert_eq!(
            with_agent_session_thread_addressing(bot, true).addressing,
            Addressing::None
        );
    }

    #[tokio::test]
    async fn direct_entity_mention_addresses_only_this_bot() {
        let store = SqliteStore::open_in_memory().expect("store");
        let mut incoming = message(12, 7);
        incoming.metadata.entities = vec![MessageEntityRecord {
            kind: "TYPE_MENTION".to_string(),
            offset: 0,
            length: 4,
            user_id: Some(InlineId::new(99)),
            agent_id: None,
            group_id: None,
            chat_id: None,
            value: None,
        }];
        let route = resolve_message_route(&incoming, 11, 99, &store, None)
            .await
            .expect("route");
        assert_eq!(route.addressing, Addressing::Mention);

        incoming.metadata.entities[0].user_id = Some(InlineId::new(100));
        let route = resolve_message_route(&incoming, 11, 99, &store, None)
            .await
            .expect("route");
        assert_eq!(route.addressing, Addressing::None);
    }

    #[tokio::test]
    async fn structured_bot_command_target_is_preserved_independently_of_mentions() {
        let store = SqliteStore::open_in_memory().expect("store");
        let mut incoming = message(12, 7);
        incoming.metadata.entities = vec![MessageEntityRecord {
            kind: "TYPE_BOT_COMMAND".to_string(),
            offset: 0,
            length: 5,
            user_id: Some(InlineId::new(99)),
            agent_id: None,
            group_id: None,
            chat_id: None,
            value: None,
        }];

        let route = resolve_message_route(&incoming, 11, 99, &store, None)
            .await
            .expect("route");
        assert_eq!(route.addressing, Addressing::None);
        assert_eq!(route.command_target_bot_user_id, Some(99));
    }

    #[tokio::test]
    async fn exact_reply_lookup_detects_a_bot_message() {
        let store = SqliteStore::open_in_memory().expect("store");
        let mut bot_reply = message(12, 99);
        bot_reply.message_id = InlineId::new(19);
        bot_reply.is_outgoing = true;
        store.record_message(bot_reply).await.expect("record reply");

        let mut incoming = message(12, 7);
        incoming.reply_to_message_id = Some(InlineId::new(19));
        let route = resolve_message_route(&incoming, 11, 99, &store, None)
            .await
            .expect("route");
        assert_eq!(route.addressing, Addressing::ReplyToBot);

        incoming.content = MessageContent::Text {
            text: "  @Ada please answer".to_string(),
        };
        incoming.metadata.entities = vec![MessageEntityRecord {
            kind: "TYPE_MENTION".to_string(),
            offset: 2,
            length: 4,
            user_id: Some(InlineId::new(77)),
            agent_id: None,
            group_id: None,
            chat_id: None,
            value: None,
        }];
        let route = resolve_message_route(&incoming, 11, 99, &store, None)
            .await
            .expect("route");
        assert_eq!(route.addressing, Addressing::None);

        incoming.content = MessageContent::Text {
            text: "😀 @Ada please answer".to_string(),
        };
        incoming.metadata.entities[0].offset = 3;
        let route = resolve_message_route(&incoming, 11, 99, &store, None)
            .await
            .expect("route");
        assert_eq!(route.addressing, Addressing::ReplyToBot);

        incoming.reply_to_message_id = Some(InlineId::new(18));
        let route = resolve_message_route(&incoming, 11, 99, &store, None)
            .await
            .expect("route");
        assert_eq!(route.addressing, Addressing::None);
    }

    #[tokio::test]
    async fn other_bots_require_an_exact_mention_to_this_bot() {
        let store = SqliteStore::open_in_memory().expect("store");
        let mut other_bot = message(11, 77);
        other_bot.metadata.sender_is_bot = Some(true);
        other_bot.metadata.mentioned = Some(true);

        let route = resolve_message_route(&other_bot, 11, 99, &store, None)
            .await
            .expect("route");
        assert!(route.bot_authored);
        assert_eq!(route.addressing, Addressing::None);

        other_bot.metadata.entities = vec![MessageEntityRecord {
            kind: "TYPE_BOT_COMMAND".to_string(),
            offset: 0,
            length: 7,
            user_id: Some(InlineId::new(99)),
            agent_id: None,
            group_id: None,
            chat_id: None,
            value: None,
        }];
        let route = resolve_message_route(&other_bot, 11, 99, &store, None)
            .await
            .expect("route");
        assert_eq!(route.addressing, Addressing::None);
        assert_eq!(route.command_target_bot_user_id, Some(99));

        other_bot.metadata.entities = vec![MessageEntityRecord {
            kind: "TYPE_MENTION".to_string(),
            offset: 0,
            length: 4,
            user_id: Some(InlineId::new(99)),
            agent_id: None,
            group_id: None,
            chat_id: None,
            value: None,
        }];
        let route = resolve_message_route(&other_bot, 11, 99, &store, None)
            .await
            .expect("route");
        assert!(route.bot_authored);
        assert_eq!(route.addressing, Addressing::Mention);
        let policy = OperatorPolicy::from_allowed(7, [77]).expect("allow bot operator");
        assert!(matches!(
            TriggerResolver.resolve(
                &policy,
                InboundEnvelope {
                    event_id: "bot-mention".to_string(),
                    chat_id: 11,
                    message_id: 20,
                    sender_user_id: 77,
                    text: "fix it".to_string(),
                    duplicate: false,
                    bot_authored: route.bot_authored,
                    addressing: route.addressing,
                    command: None,
                    action: None,
                },
            ),
            TriggerDecision::Direction {
                addressing: Addressing::Mention,
                ..
            }
        ));

        let mut unrelated_bot_message = message(11, 66);
        unrelated_bot_message.message_id = InlineId::new(18);
        unrelated_bot_message.metadata.sender_is_bot = Some(true);
        store
            .record_message(unrelated_bot_message)
            .await
            .expect("other bot message");
        other_bot.metadata.entities.clear();
        other_bot.reply_to_message_id = Some(InlineId::new(18));
        let route = resolve_message_route(&other_bot, 11, 99, &store, None)
            .await
            .expect("route");
        assert_eq!(route.addressing, Addressing::None);

        let mut own_message = message(11, 99);
        own_message.message_id = InlineId::new(19);
        own_message.is_outgoing = true;
        store
            .record_message(own_message)
            .await
            .expect("own message");
        other_bot.reply_to_message_id = Some(InlineId::new(19));
        let route = resolve_message_route(&other_bot, 11, 99, &store, None)
            .await
            .expect("route");
        assert_eq!(route.addressing, Addressing::None);
    }

    #[tokio::test]
    async fn stored_bot_identity_is_used_when_message_metadata_is_absent() {
        let store = SqliteStore::open_in_memory().expect("store");
        store
            .record_users(vec![inline_client::UserRecord {
                user_id: InlineId::new(77),
                display_name: Some("Bot B".to_string()),
                username: Some("bot_b".to_string()),
                first_name: Some("Bot B".to_string()),
                last_name: None,
                avatar_url: None,
                is_bot: Some(true),
            }])
            .await
            .expect("bot user");
        let mut other_bot = message(11, 77);

        let route = resolve_message_route(&other_bot, 11, 99, &store, None)
            .await
            .expect("route");
        assert_eq!(route.addressing, Addressing::None);

        other_bot.metadata.entities = vec![MessageEntityRecord {
            kind: "TYPE_MENTION".to_string(),
            offset: 0,
            length: 4,
            user_id: Some(InlineId::new(99)),
            agent_id: None,
            group_id: None,
            chat_id: None,
            value: None,
        }];
        let route = resolve_message_route(&other_bot, 11, 99, &store, None)
            .await
            .expect("route");
        assert!(route.bot_authored);
        assert_eq!(route.addressing, Addressing::Mention);
    }
}
