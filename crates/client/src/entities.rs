//! Validation and lossless conversion of outgoing native text entities.

use std::collections::HashSet;

use crate::{BackendError, BackendResult, ClientErrorCategory, MessageEntityRecord};
use inline_sdk::proto;

fn invalid(message: &'static str) -> BackendError {
    BackendError::new(ClientErrorCategory::InvalidInput, message)
}

/// Validates explicit entities before session, transaction, or upload work.
/// Ranges use UTF-16 code units and must begin/end at Unicode scalar boundaries.
pub(crate) fn validate_entities(
    text: &str,
    entities: &[MessageEntityRecord],
    parse_markdown: bool,
) -> BackendResult<()> {
    if entities.len() > 1024 {
        return Err(invalid("too many message entities"));
    }
    if parse_markdown && !entities.is_empty() {
        return Err(invalid(
            "explicit entities cannot be combined with Markdown parsing",
        ));
    }
    let mut boundaries = HashSet::from([0_i64]);
    let mut offset = 0_i64;
    for ch in text.chars() {
        offset += ch.len_utf16() as i64;
        boundaries.insert(offset);
    }
    for entity in entities {
        let end = entity
            .offset
            .checked_add(entity.length)
            .ok_or_else(|| invalid("message entity range overflow"))?;
        if entity.offset < 0
            || entity.length <= 0
            || !boundaries.contains(&entity.offset)
            || !boundaries.contains(&end)
        {
            return Err(invalid(
                "message entity range is outside text or splits a Unicode scalar",
            ));
        }
        let kind = proto::message_entity::Type::from_str_name(&entity.kind)
            .ok_or_else(|| invalid("unsupported outgoing message entity kind"))?;
        use proto::message_entity::Type as T;
        if matches!(kind, T::Unspecified | T::ThreadTitle) {
            return Err(invalid("unsupported outgoing message entity kind"));
        }
        let has_user = entity.user_id.is_some();
        let has_agent = entity.agent_id.is_some();
        let has_group = entity.group_id.is_some();
        let has_chat = entity.chat_id.is_some();
        let has_value = entity.value.is_some();
        let positive = |id: Option<crate::InlineId>| id.is_some_and(|id| id.get() > 0);
        let valid_payload = match kind {
            T::Mention => {
                positive(entity.user_id)
                    && (!has_agent || positive(entity.agent_id))
                    && !has_group
                    && !has_chat
                    && !has_value
            }
            T::BotCommand => {
                positive(entity.user_id) && !has_agent && !has_group && !has_chat && !has_value
            }
            T::GroupMention => {
                positive(entity.group_id) && !has_user && !has_agent && !has_chat && !has_value
            }
            T::Thread => {
                positive(entity.chat_id) && !has_user && !has_agent && !has_group && !has_value
            }
            T::TextUrl => {
                entity.value.as_ref().is_some_and(|value| {
                    !value.trim().is_empty() && !value.chars().any(char::is_control)
                }) && !has_user
                    && !has_agent
                    && !has_group
                    && !has_chat
            }
            T::Pre => !has_user && !has_agent && !has_group && !has_chat,
            T::Url
            | T::Email
            | T::Bold
            | T::Italic
            | T::UsernameMention
            | T::Code
            | T::PhoneNumber
            | T::Underline
            | T::Strikethrough
            | T::Highlight
            | T::Math
            | T::Blockquote => !has_user && !has_agent && !has_group && !has_chat && !has_value,
            T::Unspecified | T::ThreadTitle => false,
        };
        if !valid_payload {
            return Err(invalid("message entity payload does not match its kind"));
        }
    }
    Ok(())
}

/// Converts already-validated records without changing addressing identity.
pub(crate) fn entities_to_proto(entities: &[MessageEntityRecord]) -> proto::MessageEntities {
    use proto::message_entity::{Entity, Type as T};
    proto::MessageEntities {
        entities: entities
            .iter()
            .map(|record| {
                let kind = T::from_str_name(&record.kind).expect("validated outgoing entity kind");
                let entity = match kind {
                    T::Mention => Some(Entity::Mention(
                        proto::message_entity::MessageEntityMention {
                            user_id: record.user_id.expect("validated mention user").get(),
                            agent_id: record.agent_id.map(crate::InlineId::get),
                        },
                    )),
                    T::BotCommand => Some(Entity::BotCommand(
                        proto::message_entity::MessageEntityBotCommand {
                            bot_user_id: record.user_id.expect("validated command bot").get(),
                        },
                    )),
                    T::GroupMention => Some(Entity::GroupMention(
                        proto::message_entity::MessageEntityGroupMention {
                            group_id: record.group_id.expect("validated mention group").get(),
                        },
                    )),
                    T::Thread => Some(Entity::Thread(proto::message_entity::MessageEntityThread {
                        chat_id: record.chat_id.expect("validated thread").get(),
                    })),
                    T::TextUrl => Some(Entity::TextUrl(
                        proto::message_entity::MessageEntityTextUrl {
                            url: record.value.clone().expect("validated text URL"),
                        },
                    )),
                    T::Pre => Some(Entity::Pre(proto::message_entity::MessageEntityPre {
                        language: record.value.clone().unwrap_or_default(),
                    })),
                    _ => None,
                };
                proto::MessageEntity {
                    r#type: kind as i32,
                    offset: record.offset,
                    length: record.length,
                    entity,
                }
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn style(offset: i64, length: i64) -> MessageEntityRecord {
        MessageEntityRecord {
            kind: "TYPE_BOLD".into(),
            offset,
            length,
            user_id: None,
            agent_id: None,
            group_id: None,
            chat_id: None,
            value: None,
        }
    }
    #[test]
    fn utf16_ranges_require_scalar_boundaries_and_reject_overflow() {
        for entity in [
            style(-1, 1),
            style(1, 1),
            style(0, 1),
            style(0, 0),
            style(0, 4),
            style(i64::MAX, 1),
        ] {
            assert!(validate_entities("😀a", &[entity], false).is_err());
        }
        assert!(validate_entities("😀a", &[style(0, 2), style(2, 1)], false).is_ok());
        assert!(validate_entities("😀a", &[style(0, 2)], true).is_err());
    }
    #[test]
    fn mention_payload_preserves_agent_identity_and_rejects_mismatch() {
        let mut entity = style(0, 2);
        entity.kind = "TYPE_MENTION".into();
        entity.user_id = Some(crate::InlineId::new(7));
        entity.agent_id = Some(crate::InlineId::new(8));
        validate_entities("😀", &[entity.clone()], false).unwrap();
        let converted = entities_to_proto(&[entity.clone()]);
        assert!(
            matches!(&converted.entities[0].entity, Some(proto::message_entity::Entity::Mention(mention)) if mention.user_id == 7 && mention.agent_id == Some(8))
        );
        entity.group_id = Some(crate::InlineId::new(9));
        assert!(validate_entities("😀", &[entity], false).is_err());
    }

    #[test]
    fn unsupported_kinds_and_payloads_are_rejected_before_conversion() {
        for kind in [
            "TYPE_UNKNOWN_999",
            "TYPE_UNSPECIFIED",
            "TYPE_THREAD_TITLE",
            "bold",
        ] {
            let mut entity = style(0, 2);
            entity.kind = kind.into();
            assert!(validate_entities("😀", &[entity], false).is_err(), "{kind}");
        }
        for kind in [
            "TYPE_MENTION",
            "TYPE_BOT_COMMAND",
            "TYPE_GROUP_MENTION",
            "TYPE_THREAD",
            "TYPE_TEXT_URL",
        ] {
            let mut entity = style(0, 2);
            entity.kind = kind.into();
            assert!(validate_entities("😀", &[entity], false).is_err(), "{kind}");
        }
        let mut entity = style(0, 2);
        entity.value = Some("unexpected payload".into());
        assert!(validate_entities("😀", &[entity], false).is_err());
        assert!(validate_entities("😀", &vec![style(0, 2); 1025], false).is_err());
    }

    #[test]
    fn supported_typed_payloads_survive_proto_conversion() {
        use proto::message_entity::Entity;
        let mut command = style(0, 2);
        command.kind = "TYPE_BOT_COMMAND".into();
        command.user_id = Some(crate::InlineId::new(7));
        let mut group = style(0, 2);
        group.kind = "TYPE_GROUP_MENTION".into();
        group.group_id = Some(crate::InlineId::new(8));
        let mut thread = style(0, 2);
        thread.kind = "TYPE_THREAD".into();
        thread.chat_id = Some(crate::InlineId::new(9));
        let mut link = style(0, 2);
        link.kind = "TYPE_TEXT_URL".into();
        link.value = Some("https://inline.chat/path".into());
        let mut pre = style(0, 2);
        pre.kind = "TYPE_PRE".into();
        pre.value = Some("rust".into());
        let entities = [command, group, thread, link, pre];
        validate_entities("😀", &entities, false).unwrap();
        let converted = entities_to_proto(&entities);
        assert!(
            matches!(&converted.entities[0].entity, Some(Entity::BotCommand(value)) if value.bot_user_id == 7)
        );
        assert!(
            matches!(&converted.entities[1].entity, Some(Entity::GroupMention(value)) if value.group_id == 8)
        );
        assert!(
            matches!(&converted.entities[2].entity, Some(Entity::Thread(value)) if value.chat_id == 9)
        );
        assert!(
            matches!(&converted.entities[3].entity, Some(Entity::TextUrl(value)) if value.url == "https://inline.chat/path")
        );
        assert!(
            matches!(&converted.entities[4].entity, Some(Entity::Pre(value)) if value.language == "rust")
        );
        for entity in converted.entities {
            assert_eq!((entity.offset, entity.length), (0, 2));
        }
    }
}
