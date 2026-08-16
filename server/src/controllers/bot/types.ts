import { t } from "elysia"
import { MAX_FILE_SIZE } from "@in/server/config"
import { TBotMessageEntitiesInput, TBotMessageEntitiesOutput } from "./entities"

const TTargetId = t.Union([t.Number(), t.String()])

const TBotTargetFields = {
  user_id: t.Optional(TTargetId),
  chat_id: t.Optional(TTargetId),
} as const

export const TBotUser = t.Object({
  id: t.Number(),
  is_bot: t.Boolean(),
  username: t.Optional(t.String()),
  first_name: t.Optional(t.String()),
  last_name: t.Optional(t.String()),
})

export const TBotAgent = t.Object({
  id: t.Number(),
  bot_user_id: t.Number(),
  name: t.String({ minLength: 1, maxLength: 256 }),
  handle: t.Optional(t.String({ maxLength: 256 })),
  emoji: t.Optional(t.String({ maxLength: 64 })),
  description: t.Optional(t.String()),
  skill_key: t.Optional(t.String({ maxLength: 256 })),
  instructions: t.Optional(t.String()),
})

export const TCreateAgentInput = t.Object({
  name: t.String({ minLength: 1, maxLength: 256 }),
  handle: t.Optional(t.String({ maxLength: 256 })),
  emoji: t.Optional(t.String({ maxLength: 64 })),
  description: t.Optional(t.String()),
  skill_key: t.Optional(t.String({ maxLength: 256 })),
  instructions: t.Optional(t.String()),
})

export const TGetAgentInput = t.Object({
  agent_id: TTargetId,
})

export const TBotPeer = t.Object({
  user_id: t.Optional(t.Number()),
})

export const TBotCommand = t.Object({
  command: t.String(),
  description: t.String(),
  sort_order: t.Optional(t.Number()),
})

export const TBotFile = t.Object({
  file_id: t.String(),
  file_name: t.Optional(t.String()),
  mime_type: t.Optional(t.String()),
  file_size: t.Optional(t.Number()),
  width: t.Optional(t.Number()),
  height: t.Optional(t.Number()),
  duration: t.Optional(t.Number()),
  download_url: t.Optional(t.String()),
  download_url_expires_at: t.Optional(t.Number()),
})

export const TBotMedia = t.Union([
  t.Object({ type: t.Literal("photo"), file: TBotFile }),
  t.Object({
    type: t.Literal("video"),
    file: TBotFile,
    thumbnail: t.Optional(TBotFile),
    is_animated: t.Optional(t.Boolean()),
    has_audio: t.Optional(t.Boolean()),
  }),
  t.Object({ type: t.Literal("document"), file: TBotFile, thumbnail: t.Optional(TBotFile) }),
  t.Object({ type: t.Literal("voice"), file: TBotFile, waveform_base64: t.Optional(t.String()) }),
  t.Object({ type: t.Literal("nudge") }),
])

export const TBotMessageAction = t.Union([
  t.Object({
    action_id: t.String(),
    text: t.String(),
    type: t.Literal("callback"),
    callback_data: t.String(),
  }),
  t.Object({
    action_id: t.String(),
    text: t.String(),
    type: t.Literal("callback"),
    callback_data_base64: t.String(),
  }),
  t.Object({ action_id: t.String(), text: t.String(), type: t.Literal("callback") }),
  t.Object({
    action_id: t.String(),
    text: t.String(),
    type: t.Literal("copy_text"),
    copy_text: t.String(),
  }),
])

export const TBotMessageReaction = t.Object({
  emoji: t.String(),
  count: t.Number(),
  chosen: t.Boolean(),
})

export const TBotAttachment = t.Object({
  type: t.Literal("url_preview"),
  url: t.String(),
  title: t.Optional(t.String()),
  description: t.Optional(t.String()),
  image: t.Optional(TBotFile),
})

export const TBotChatLastMessage = t.Object({
  message_id: t.Number(),
  from_id: t.Number(),
  from: TBotUser,
  date: t.Number(),
  text: t.Optional(t.String()),
  entities: t.Optional(TBotMessageEntitiesOutput),
})

const TBotChatBase = t.Object({
  chat_id: t.Number(),
  type: t.Optional(t.Union([t.Literal("user"), t.Literal("thread")])),
  title: t.Optional(t.String()),
  space_id: t.Optional(t.Number()),
  is_public: t.Optional(t.Boolean()),
  parent_chat_id: t.Optional(t.Number()),
  participants: t.Optional(t.Object({ count: t.Number() })),
  last_message_id: t.Optional(t.Number()),
  last_message: t.Optional(TBotChatLastMessage),
  emoji: t.Optional(t.String()),
})

export const TBotMessageLite = t.Object({
  message_id: t.Number(),
  chat_id: t.Number(),
  chat: TBotChatBase,
  peer: TBotPeer,
  from_id: t.Number(),
  from: TBotUser,
  date: t.Number(),
  edit_date: t.Optional(t.Number()),
  text: t.Optional(t.String()),
  entities: t.Optional(TBotMessageEntitiesOutput),
  media: t.Optional(TBotMedia),
  attachments: t.Optional(t.Array(TBotAttachment)),
  actions: t.Optional(t.Array(t.Array(TBotMessageAction))),
  reactions: t.Optional(t.Array(TBotMessageReaction)),
})

export const TBotChat = t.Object({
  ...TBotChatBase.properties,
  parent_message: t.Optional(TBotMessageLite),
})

export const TBotMessage = t.Object({
  message_id: t.Number(),
  chat_id: t.Number(),
  chat: TBotChat,
  peer: TBotPeer,
  from_id: t.Number(),
  from: TBotUser,
  date: t.Number(),
  edit_date: t.Optional(t.Number()),
  text: t.Optional(t.String()),
  entities: t.Optional(TBotMessageEntitiesOutput),
  media: t.Optional(TBotMedia),
  attachments: t.Optional(t.Array(TBotAttachment)),
  actions: t.Optional(t.Array(t.Array(TBotMessageAction))),
  reactions: t.Optional(t.Array(TBotMessageReaction)),
  reply_to_message: t.Optional(TBotMessageLite),
})

export const TSendMessageInput = t.Object({
  ...TBotTargetFields,
  text: t.Optional(t.String()),
  reply_to_message_id: t.Optional(TTargetId),
  entities: t.Optional(TBotMessageEntitiesInput),
  parse_markdown: t.Optional(t.Boolean()),
  media: t.Optional(t.Any()),
  actions: t.Optional(t.Array(t.Array(TBotMessageAction, { maxItems: 8 }), { maxItems: 8 })),
  silent: t.Optional(t.Boolean()),
})

export const TGetChatInput = t.Object({
  ...TBotTargetFields,
})

export const TGetChatHistoryInput = t.Object({
  ...TBotTargetFields,
  limit: t.Optional(t.Number()),
  offset_message_id: t.Optional(TTargetId),
})

export const TGetMessagesInput = t.Object({
  ...TBotTargetFields,
  message_ids: t.Array(TTargetId, { minItems: 1, maxItems: 100 }),
})

export const TSearchMessagesInput = t.Object({
  ...TBotTargetFields,
  query: t.String({ minLength: 1, maxLength: 256 }),
  filter: t.Optional(
    t.Union([
      t.Literal("photo"),
      t.Literal("video"),
      t.Literal("photo_video"),
      t.Literal("document"),
      t.Literal("link"),
      t.Literal("voice"),
    ]),
  ),
  offset_message_id: t.Optional(TTargetId),
  limit: t.Optional(t.Number()),
})

export const TCreateThreadInput = t.Object({
  title: t.Optional(t.String()),
  emoji: t.Optional(t.String()),
  space_id: t.Optional(TTargetId),
  is_public: t.Optional(t.Boolean()),
  participant_ids: t.Optional(t.Array(TTargetId, { maxItems: 50 })),
})

export const TCreateReplyThreadInput = t.Object({
  chat_id: TTargetId,
  message_id: TTargetId,
  title: t.Optional(t.String()),
  emoji: t.Optional(t.String()),
  participant_ids: t.Optional(t.Array(TTargetId, { maxItems: 50 })),
})

export const TEditMessageTextInput = t.Object({
  ...TBotTargetFields,
  message_id: TTargetId,
  text: t.String(),
  entities: t.Optional(TBotMessageEntitiesInput),
  parse_markdown: t.Optional(t.Boolean()),
  actions: t.Optional(t.Array(t.Array(TBotMessageAction, { maxItems: 8 }), { maxItems: 8 })),
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

export const TAnswerMessageActionInput = t.Object({
  interaction_id: TTargetId,
  text: t.Optional(t.String({ maxLength: 200 })),
})

export const TSendChatActionInput = t.Object({
  ...TBotTargetFields,
  action: t.Union([
    t.Literal("typing"), t.Literal("upload_photo"), t.Literal("upload_video"),
    t.Literal("upload_document"), t.Literal("record_voice"), t.Literal("cancel"),
  ]),
})

export const TGetFileInput = t.Object({ file_id: t.String() })
export const TGetUpdatesInput = t.Object({
  offset: t.Optional(TTargetId),
  limit: t.Optional(t.Number({ minimum: 1, maximum: 100 })),
  timeout: t.Optional(t.Number({ minimum: 0, maximum: 50 })),
  message_trigger: t.Optional(t.Union([t.Literal("all"), t.Literal("mentions")])),
  allowed_updates: t.Optional(t.Union([t.String(), t.Array(t.String())])),
})
export const TSetWebhookInput = t.Object({
  url: t.String(),
  secret_token: t.Optional(t.String({ maxLength: 256 })),
  message_trigger: t.Optional(t.Union([t.Literal("all"), t.Literal("mentions")])),
  allowed_updates: t.Optional(t.Array(t.String())),
  drop_pending_updates: t.Optional(t.Boolean()),
})
export const TDeleteWebhookInput = t.Object({ drop_pending_updates: t.Optional(t.Boolean()) })

export const TSetMyCommandsInput = t.Object({
  commands: t.Array(TBotCommand),
})

export const TForwardMessageInput = t.Object({
  chat_id: TTargetId,
  from_chat_id: TTargetId,
  message_id: TTargetId,
})

export const TPinMessageInput = t.Object({
  chat_id: TTargetId,
  message_id: TTargetId,
})

export const TGetChatParticipantInput = t.Object({
  chat_id: TTargetId,
  user_id: TTargetId,
})

export const TGetChatParticipantCountInput = t.Object({ chat_id: TTargetId })

export const TSetThreadTitleInput = t.Object({
  chat_id: TTargetId,
  title: t.String({ minLength: 1, maxLength: 256 }),
})

export const TBotSpaceMember = t.Object({
  id: t.Number(),
  space_id: t.Number(),
  user_id: t.Number(),
  role: t.Optional(t.Union([t.Literal("owner"), t.Literal("admin"), t.Literal("member")])),
  date: t.Number(),
  can_access_public_chats: t.Boolean(),
})

export const TBotChatParticipant = t.Object({
  user: TBotUser,
  member: t.Optional(TBotSpaceMember),
})

export const TBotUploadFileInput = t.Object({
  type: t.Union([t.Literal("photo"), t.Literal("video"), t.Literal("document"), t.Literal("voice")]),
  file: t.File({ maxItems: 1, maxSize: MAX_FILE_SIZE }),
  thumbnail: t.Optional(t.File({ maxItems: 1, maxSize: MAX_FILE_SIZE })),
  width: t.Optional(t.String()),
  height: t.Optional(t.String()),
  duration: t.Optional(t.String()),
  is_animated: t.Optional(t.String()),
  has_audio: t.Optional(t.String()),
  waveform_base64: t.Optional(t.String()),
})
