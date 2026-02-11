import { t } from "elysia"
import { TBotMessageEntitiesInput, TBotMessageEntitiesOutput } from "./entities"

const TTargetId = t.Union([t.Number(), t.String()])

const TBotTargetFields = {
  // Canonical bot API targeting fields.
  user_id: t.Optional(TTargetId),
  chat_id: t.Optional(TTargetId),

  // Deprecated aliases kept for alpha compatibility.
  peer_user_id: t.Optional(TTargetId),
  peer_thread_id: t.Optional(TTargetId),
} as const

export const TBotUser = t.Object({
  id: t.Number(),
  is_bot: t.Boolean(),
  username: t.Optional(t.String()),
  first_name: t.Optional(t.String()),
  last_name: t.Optional(t.String()),
})

export const TBotPeer = t.Object({
  user_id: t.Optional(t.Number()),
  thread_id: t.Optional(t.Number()),
})

export const TBotChat = t.Object({
  chat_id: t.Number(),
  title: t.Optional(t.String()),
  space_id: t.Optional(t.Number()),
  is_public: t.Optional(t.Boolean()),
  last_message_id: t.Optional(t.Number()),
  last_message: t.Optional(
    t.Object({
      message_id: t.Number(),
      from_id: t.Number(),
      from: TBotUser,
      date: t.Number(),
      text: t.Optional(t.String()),
      entities: t.Optional(TBotMessageEntitiesOutput),
    }),
  ),
  emoji: t.Optional(t.String()),
})

export const TBotMessageLite = t.Object({
  message_id: t.Number(),
  chat_id: t.Number(),
  chat: TBotChat,
  peer: TBotPeer,
  from_id: t.Number(),
  from: TBotUser,
  date: t.Number(),
  text: t.Optional(t.String()),
  entities: t.Optional(TBotMessageEntitiesOutput),
})

export const TBotMessage = t.Object({
  message_id: t.Number(),
  chat_id: t.Number(),
  chat: TBotChat,
  peer: TBotPeer,
  from_id: t.Number(),
  from: TBotUser,
  date: t.Number(),
  text: t.Optional(t.String()),
  entities: t.Optional(TBotMessageEntitiesOutput),
  reply_to_message: t.Optional(TBotMessageLite),
})

export const TSendMessageInput = t.Object({
  ...TBotTargetFields,
  text: t.String(),
  reply_to_message_id: t.Optional(TTargetId),
  entities: t.Optional(TBotMessageEntitiesInput),
})

export const TGetChatInput = t.Object({
  ...TBotTargetFields,
})

export const TGetChatHistoryInput = t.Object({
  ...TBotTargetFields,
  limit: t.Optional(t.Number()),
  offset_message_id: t.Optional(TTargetId),
})

export const TEditMessageTextInput = t.Object({
  ...TBotTargetFields,
  message_id: TTargetId,
  text: t.String(),
  entities: t.Optional(TBotMessageEntitiesInput),
})

export const TDeleteMessageInput = t.Object({
  ...TBotTargetFields,
  message_id: TTargetId,
})

export const TSendReactionInput = t.Object({
  ...TBotTargetFields,
  message_id: TTargetId,
  emoji: t.String(),
})
