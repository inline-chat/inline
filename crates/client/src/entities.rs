//! Checked outbound conversion; incoming unknown entities remain lossless records.
use inline_sdk::proto;

use crate::{BackendError, BackendResult, ClientErrorCategory, MessageEntityRecord};

pub(crate) fn to_proto(
    text: &str,
    entities: &[MessageEntityRecord],
) -> BackendResult<Option<proto::MessageEntities>> {
    use proto::message_entity::{Entity, Type};
    if entities.is_empty() {
        return Ok(None);
    }
    // Both ends must land on Unicode scalar boundaries in UTF-16 coordinates.
    let mut boundaries = std::collections::HashSet::from([0_i64]);
    let mut end = 0_i64;
    for scalar in text.chars() {
        end += scalar.len_utf16() as i64;
        boundaries.insert(end);
    }
    let invalid = || {
        BackendError::new(
            ClientErrorCategory::InvalidInput,
            "invalid message entity range or payload",
        )
    };
    let mut converted = Vec::with_capacity(entities.len());
    for entity in entities {
        let range_end = entity
            .offset
            .checked_add(entity.length)
            .ok_or_else(invalid)?;
        if entity.offset < 0
            || entity.length <= 0
            || !boundaries.contains(&entity.offset)
            || !boundaries.contains(&range_end)
        {
            return Err(invalid());
        }
        let kind = Type::from_str_name(&entity.kind).ok_or_else(|| {
            BackendError::new(
                ClientErrorCategory::Unsupported,
                "unsupported outbound entity kind",
            )
        })?;
        let positive = |id: Option<crate::InlineId>| {
            id.filter(|id| id.get() > 0)
                .map(crate::InlineId::get)
                .ok_or_else(invalid)
        };
        let payload = match kind {
            Type::Mention => Some(Entity::Mention(
                proto::message_entity::MessageEntityMention {
                    user_id: positive(entity.user_id)?,
                    agent_id: entity.agent_id.map(|id| positive(Some(id))).transpose()?,
                },
            )),
            Type::GroupMention => Some(Entity::GroupMention(
                proto::message_entity::MessageEntityGroupMention {
                    group_id: positive(entity.group_id)?,
                },
            )),
            Type::Thread => Some(Entity::Thread(proto::message_entity::MessageEntityThread {
                chat_id: positive(entity.chat_id)?,
            })),
            Type::BotCommand => entity
                .user_id
                .map(|id| {
                    positive(Some(id)).map(|bot_user_id| {
                        Entity::BotCommand(proto::message_entity::MessageEntityBotCommand {
                            bot_user_id,
                        })
                    })
                })
                .transpose()?,
            Type::TextUrl => Some(Entity::TextUrl(
                proto::message_entity::MessageEntityTextUrl {
                    url: entity
                        .value
                        .clone()
                        .filter(|v| !v.trim().is_empty())
                        .ok_or_else(invalid)?,
                },
            )),
            Type::Pre => Some(Entity::Pre(proto::message_entity::MessageEntityPre {
                language: entity.value.clone().unwrap_or_default(),
            })),
            Type::Url
            | Type::Email
            | Type::Bold
            | Type::Italic
            | Type::UsernameMention
            | Type::Code
            | Type::PhoneNumber
            | Type::Underline
            | Type::Strikethrough
            | Type::Highlight
            | Type::Math
            | Type::Blockquote => None,
            // Thread-title entities need a space ID absent from the current DTO.
            // Range-only Math above represents inline math, never a display flag.
            Type::ThreadTitle | Type::Unspecified => {
                return Err(BackendError::new(
                    ClientErrorCategory::Unsupported,
                    "entity payload cannot be represented faithfully",
                ));
            }
        };
        // Reject mismatched identities rather than silently changing addressing.
        if (entity.user_id.is_some() && !matches!(kind, Type::Mention | Type::BotCommand))
            || (entity.agent_id.is_some() && kind != Type::Mention)
            || (entity.group_id.is_some() && kind != Type::GroupMention)
            || (entity.chat_id.is_some() && kind != Type::Thread)
            || (entity.value.is_some() && !matches!(kind, Type::TextUrl | Type::Pre))
        {
            return Err(invalid());
        }
        converted.push(proto::MessageEntity {
            r#type: kind as i32,
            offset: entity.offset,
            length: entity.length,
            entity: payload,
        });
    }
    Ok(Some(proto::MessageEntities {
        entities: converted,
    }))
}
