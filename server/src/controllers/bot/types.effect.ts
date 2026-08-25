import type {
  BotAttachment as NeutralBotAttachment,
  BotChat as NeutralBotChat,
  BotCommand as NeutralBotCommand,
  BotFile as NeutralBotFile,
  BotMedia as NeutralBotMedia,
  BotMessage as NeutralBotMessage,
  BotMessageAction as NeutralBotMessageAction,
  BotMessageEntityOutput as NeutralBotMessageEntityOutput,
  BotMessageReaction as NeutralBotMessageReaction,
  BotPeer as NeutralBotPeer,
  BotPeerId as NeutralBotPeerId,
  BotRichBlock as NeutralBotRichBlock,
  BotRichMessage as NeutralBotRichMessage,
  BotRichText as NeutralBotRichText,
} from "@inline-chat/bot-api-types"
import { Schema } from "effect"
import { Multipart } from "effect/unstable/http"
import { HttpApiSchema } from "effect/unstable/httpapi"
import {
  BotApiError,
  BotUser,
  botApiSuccess,
} from "../../core/schema/bot"
import {
  ChatId,
  ChatIdFromString,
  MessageId,
  MessageIdFromString,
  SpaceId,
  UserId,
  UserIdFromString,
} from "../../core/schema/identifiers"
import {
  WireNonNegativeInteger,
  WirePositiveInteger,
  WireSafeInteger,
  WireSafeIntegerFromString,
} from "../../core/schema/scalars"

const OptionalString = Schema.optionalKey(Schema.String)
const OptionalWireInteger = Schema.optionalKey(WireSafeInteger)
const OptionalUserId = Schema.optionalKey(UserId)
const OptionalChatId = Schema.optionalKey(ChatId)
const OptionalMessageId = Schema.optionalKey(MessageId)
const OptionalSpaceId = Schema.optionalKey(SpaceId)

export const botTargetFieldDescriptions = {
  user_id:
    "Target a private conversation with this user. Supply exactly one of user_id or chat_id.",
  chat_id:
    "Target this chat. Supply exactly one of chat_id or user_id.",
} as const

export const getChatHistoryFieldDescriptions = {
  ...botTargetFieldDescriptions,
  limit: "Maximum number of messages to return.",
  offset_message_id:
    "Pagination cursor. When supplied, return messages older than this message.",
} as const

const BotTargetFields = {
  user_id: OptionalUserId.annotateKey({
    description: botTargetFieldDescriptions.user_id,
  }),
  chat_id: OptionalChatId.annotateKey({
    description: botTargetFieldDescriptions.chat_id,
  }),
} as const

const BotTargetQueryFields = {
  user_id: Schema.optionalKey(
    UserIdFromString,
  ).annotateKey({
    description: botTargetFieldDescriptions.user_id,
  }),
  chat_id: Schema.optionalKey(
    ChatIdFromString,
  ).annotateKey({
    description: botTargetFieldDescriptions.chat_id,
  }),
} as const

export const BotMessageEntityType = Schema.Literals([
  "mention",
  "text_mention",
  "url",
  "text_link",
  "email",
  "bold",
  "italic",
  "code",
  "pre",
  "phone_number",
  "thread",
  "thread_title",
  "bot_command",
  "group_mention",
]).annotate({
  identifier: "BotMessageEntityType",
  description:
    "Formatting, link, mention, and command metadata attached to a range of message text.",
})

export const BotMessageEntityOutput = Schema.Struct({
  type: Schema.Literals([
    "mention",
    "text_mention",
    "url",
    "text_link",
    "email",
    "bold",
    "italic",
    "code",
    "pre",
    "phone_number",
    "thread",
    "thread_title",
    "bot_command",
    "group_mention",
    "unknown",
  ]).annotateKey({
    description: "Kind of formatting or semantic entity.",
  }),
  offset: WireNonNegativeInteger.annotateKey({
    description:
      "Zero-based UTF-16 code-unit offset where the entity begins in text.",
  }),
  length: WireNonNegativeInteger.annotateKey({
    description:
      "Number of UTF-16 code units covered by the entity.",
  }),
  user: Schema.optionalKey(BotUser).annotateKey({
    description:
      "Referenced user for mention entities.",
  }),
  url: OptionalString.annotateKey({
    description:
      "Destination URL for a text_link entity.",
  }),
  language: OptionalString.annotateKey({
    description:
      "Programming language hint for a preformatted code block.",
  }),
  chat_id: OptionalChatId.annotateKey({
    description:
      "Referenced chat for thread link entities.",
  }),
  space_id: OptionalSpaceId.annotateKey({
    description:
      "Referenced space for thread-title link entities.",
  }),
  title: OptionalString.annotateKey({
    description:
      "Display title for a linked thread or space.",
  }),
  group_id: Schema.optionalKey(WirePositiveInteger).annotateKey({
    description: "Referenced group for a group_mention entity.",
  }),
}).annotate({
  identifier: "BotMessageEntityOutput",
  description:
    "Formatting or semantic metadata found in message text.",
})

export const BotPeer = Schema.Struct({
  user_id: OptionalUserId.annotateKey({
    description:
      "The other user in a user chat. Threads do not include this field.",
  }),
}).annotate({
  identifier: "BotPeer",
  description:
    "Additional peer information retained for user-chat compatibility. Prefer message.chat_id as the conversation identifier.",
})

export const BotPeerId = Schema.Union([
  Schema.Struct({
    user_id: UserId,
    chat_id: Schema.optionalKey(Schema.Never),
  }),
  Schema.Struct({
    user_id: Schema.optionalKey(Schema.Never),
    chat_id: ChatId,
  }),
], { mode: "oneOf" }).annotate({
  identifier: "BotPeerId",
  description:
    "Stable conversation identity: a user ID for a private chat or a chat ID for a thread.",
})

// TODO(effect-cutover): remove `thread_id` after production telemetry shows no
// Bot response consumer has used the deprecated peer alias for 30 days.
// The canonical OpenAPI surface uses `chat_id`.
export const BotPeerCompatibility = Schema.Struct({
  ...BotPeer.fields,
  thread_id: OptionalChatId,
})

export const BotCommand = Schema.Struct({
  command: Schema.String.check(
    Schema.isMinLength(1),
    Schema.isMaxLength(32),
    Schema.isPattern(/^[a-z0-9_]+$/),
  ).annotateKey({
    description:
      "Command name without a leading slash. Use 1–32 lowercase letters, digits, or underscores.",
  }),
  description: Schema.String.check(
    Schema.isMinLength(1),
    Schema.isMaxLength(256),
  ).annotateKey({
    description:
      "User-facing description shown in the command menu, up to 256 characters.",
  }),
  sort_order: OptionalWireInteger.annotateKey({
    description:
      "Optional order in the command menu. Lower values appear first.",
  }),
}).annotate({
  identifier: "BotCommand",
  description: "A command advertised by the bot.",
})

export const BotChatType = Schema.Literals([
  "user",
  "thread",
]).annotate({
  identifier: "BotChatType",
  description: "Public conversation kind.",
})

export const BotRichText: Schema.Codec<NeutralBotRichText> = Schema.suspend(
  (): Schema.Codec<NeutralBotRichText> => Schema.Union([
    Schema.String,
    Schema.mutable(Schema.Array(BotRichText)),
    Schema.Struct({ type: Schema.Literals(["bold", "italic", "code"]), text: BotRichText }),
    Schema.Struct({ type: Schema.Literal("url"), text: BotRichText, url: Schema.String }),
    Schema.Struct({
      type: Schema.Literal("email_address"),
      text: BotRichText,
      email_address: Schema.String,
    }),
    Schema.Struct({
      type: Schema.Literal("phone_number"),
      text: BotRichText,
      phone_number: Schema.String,
    }),
    Schema.Struct({ type: Schema.Literal("mention"), text: BotRichText, username: Schema.String }),
    Schema.Struct({ type: Schema.Literal("text_mention"), text: BotRichText, user: BotUser }),
    Schema.Struct({
      type: Schema.Literal("bot_command"),
      text: BotRichText,
      bot_command: Schema.String,
    }),
    Schema.Struct({ type: Schema.Literal("chat_link"), text: BotRichText, chat_id: ChatId }),
    Schema.Struct({
      type: Schema.Literal("thread_title"),
      text: BotRichText,
      title: Schema.String,
      space_id: OptionalSpaceId,
    }),
    Schema.Struct({
      type: Schema.Literal("group_mention"),
      text: BotRichText,
      group_id: WirePositiveInteger,
    }),
  ], { mode: "oneOf" }),
).annotate({
  identifier: "BotRichText",
  description: "Recursive rich text following Telegram's text-tree model.",
})

export const BotRichBlock: Schema.Codec<NeutralBotRichBlock> = Schema.suspend(
  (): Schema.Codec<NeutralBotRichBlock> => Schema.Union([
    Schema.Struct({
      type: Schema.Literal("paragraph"),
      text: BotRichText,
      is_rtl: Schema.optionalKey(Schema.Literal(true)),
    }),
    Schema.Struct({
      type: Schema.Literal("heading"),
      text: BotRichText,
      size: WirePositiveInteger,
      is_rtl: Schema.optionalKey(Schema.Literal(true)),
    }),
    Schema.Struct({ type: Schema.Literal("pre"), text: BotRichText, language: OptionalString }),
    Schema.Struct({
      type: Schema.Literal("footer"),
      text: BotRichText,
      is_rtl: Schema.optionalKey(Schema.Literal(true)),
    }),
    Schema.Struct({ type: Schema.Literal("divider") }),
    Schema.Struct({
      type: Schema.Literal("list"),
      items: Schema.mutable(Schema.Array(Schema.Struct({
        label: Schema.String,
        blocks: Schema.mutable(Schema.Array(BotRichBlock)),
        has_checkbox: Schema.optionalKey(Schema.Literal(true)),
        is_checked: Schema.optionalKey(Schema.Literal(true)),
        value: OptionalWireInteger,
      }))),
      is_rtl: Schema.optionalKey(Schema.Literal(true)),
    }),
    Schema.Struct({
      type: Schema.Literal("blockquote"),
      blocks: Schema.mutable(Schema.Array(BotRichBlock)),
      is_rtl: Schema.optionalKey(Schema.Literal(true)),
    }),
    Schema.Struct({ type: Schema.Literal("collage"), blocks: Schema.mutable(Schema.Array(BotRichBlock)) }),
    Schema.Struct({
      type: Schema.Literal("details"),
      summary: BotRichText,
      blocks: Schema.mutable(Schema.Array(BotRichBlock)),
      is_open: Schema.optionalKey(Schema.Literal(true)),
      kind: Schema.optionalKey(Schema.Literal("progress")),
      is_rtl: Schema.optionalKey(Schema.Literal(true)),
    }),
    Schema.Struct({
      type: Schema.Literal("table"),
      cells: Schema.mutable(Schema.Array(Schema.mutable(Schema.Array(Schema.Struct({
        text: BotRichText,
        align: Schema.Literals(["left", "center", "right"]),
        is_header: Schema.optionalKey(Schema.Literal(true)),
      }))))),
      is_bordered: Schema.optionalKey(Schema.Literal(true)),
      is_rtl: Schema.optionalKey(Schema.Literal(true)),
    }),
    Schema.Struct({
      type: Schema.Literal("photo"),
      alt: Schema.optionalKey(BotRichText),
      file: Schema.optionalKey(Schema.suspend(() => BotFile)),
      width: Schema.optionalKey(WireNonNegativeInteger),
      height: Schema.optionalKey(WireNonNegativeInteger),
    }),
  ], { mode: "oneOf" }),
).annotate({
  identifier: "BotRichBlock",
  description: "A structural content block containing recursive rich text or child blocks.",
})

export const BotRichMessage: Schema.Codec<NeutralBotRichMessage> = Schema.Struct({
  blocks: Schema.mutable(Schema.Array(BotRichBlock)),
}).annotate({
  identifier: "BotRichMessage",
  description: "Structural rich content for a message.",
})

export const BotChatLastMessage = Schema.Struct({
  message_id: MessageId.annotateKey({
    description: "Unique identifier for this message within the chat.",
  }),
  from_id: UserId.annotateKey({
    description: "Unique identifier of the message sender.",
  }),
  from: BotUser.annotateKey({
    description: "Basic information about the message sender.",
  }),
  date: WireNonNegativeInteger.annotateKey({
    description:
      "Time the message was sent, as Unix time in seconds.",
  }),
  text: OptionalString.annotateKey({
    description: "Text of the message, when present.",
  }),
  entities: Schema.optionalKey(
    Schema.mutable(Schema.Array(BotMessageEntityOutput)),
  ).annotateKey({
    description:
      "Formatting and semantic entities found in the message text.",
  }),
  rich_message: Schema.optionalKey(BotRichMessage).annotateKey({
    description: "Recursive rich content, when the message has structural blocks.",
  }),
}).annotate({
  identifier: "BotChatLastMessage",
  description:
    "Compact representation of the most recent message in a chat.",
})

const BotChatBase = Schema.Struct({
  chat_id: ChatId.annotateKey({
    description: "Unique identifier for this chat.",
  }),
  type: BotChatType.annotateKey({
    description: "Conversation kind.",
  }),
  title: OptionalString.annotateKey({
    description: "Display title of the chat.",
  }),
  space_id: OptionalSpaceId.annotateKey({
    description: "Space that contains the chat, when applicable.",
  }),
  is_public: Schema.optionalKey(
    Schema.Boolean,
  ).annotateKey({
    description: "Whether the chat is public.",
  }),
  parent_chat_id: OptionalChatId.annotateKey({
    description: "Structural parent for a nested or reply thread.",
  }),
  number: Schema.optionalKey(WirePositiveInteger).annotateKey({
    description: "Human-facing thread number within its space or home scope.",
  }),
  participants: Schema.optionalKey(
    Schema.Struct({
      count: WireNonNegativeInteger,
    }),
  ).annotateKey({
    description: "Safe aggregate participant information.",
  }),
  last_message_id: OptionalMessageId.annotateKey({
    description:
      "Identifier of the latest known message in the chat.",
  }),
  last_message: Schema.optionalKey(
    BotChatLastMessage,
  ).annotateKey({
    description:
      "Latest message, when it is available to the bot.",
  }),
  emoji: OptionalString.annotateKey({
    description: "Emoji used as the chat's icon.",
  }),
}).annotate({
  description:
    "Non-recursive chat fields used inside an embedded message.",
})

export const BotFile = Schema.Struct({
  file_id: Schema.String,
  file_name: OptionalString,
  mime_type: OptionalString,
  file_size: Schema.optionalKey(WireNonNegativeInteger),
  width: Schema.optionalKey(WireNonNegativeInteger),
  height: Schema.optionalKey(WireNonNegativeInteger),
  duration: Schema.optionalKey(WireNonNegativeInteger),
  download_url: OptionalString,
  download_url_expires_at: Schema.optionalKey(WireNonNegativeInteger),
}).annotate({
  identifier: "BotFile",
  description: "Reusable file metadata. File identifiers and URLs are opaque.",
})

export const BotMedia = Schema.Union([
  Schema.Struct({ type: Schema.Literal("photo"), file: BotFile }),
  Schema.Struct({
    type: Schema.Literal("video"),
    file: BotFile,
    thumbnail: Schema.optionalKey(BotFile),
    is_animated: Schema.optionalKey(Schema.Boolean),
    has_audio: Schema.optionalKey(Schema.Boolean),
  }),
  Schema.Struct({
    type: Schema.Literal("document"),
    file: BotFile,
    thumbnail: Schema.optionalKey(BotFile),
  }),
  Schema.Struct({
    type: Schema.Literal("voice"),
    file: BotFile,
    waveform_base64: OptionalString,
  }),
  Schema.Struct({ type: Schema.Literal("nudge") }),
]).annotate({
  identifier: "BotMedia",
  description: "One media item attached to a message.",
})

export const BotMessageAction = Schema.Union([
  Schema.Struct({
    action_id: Schema.String,
    text: Schema.String,
    type: Schema.Literal("callback"),
    callback_data: Schema.String,
    callback_data_base64: Schema.optionalKey(Schema.Never),
  }),
  Schema.Struct({
    action_id: Schema.String,
    text: Schema.String,
    type: Schema.Literal("callback"),
    callback_data: Schema.optionalKey(Schema.Never),
    callback_data_base64: Schema.String,
  }),
  Schema.Struct({
    action_id: Schema.String,
    text: Schema.String,
    type: Schema.Literal("callback"),
    callback_data: Schema.optionalKey(Schema.Never),
    callback_data_base64: Schema.optionalKey(Schema.Never),
  }),
  Schema.Struct({
    action_id: Schema.String,
    text: Schema.String,
    type: Schema.Literal("copy_text"),
    copy_text: Schema.String,
    callback_data: Schema.optionalKey(Schema.Never),
    callback_data_base64: Schema.optionalKey(Schema.Never),
  }),
]).annotate({
  identifier: "BotMessageAction",
  description: "Interactive message action.",
})

export const BotReaction = Schema.Struct({
  emoji: Schema.String,
}).annotate({ identifier: "BotReaction" })

export const BotMessageReaction = Schema.Struct({
  ...BotReaction.fields,
  count: WireNonNegativeInteger,
  chosen: Schema.Boolean,
}).annotate({ identifier: "BotMessageReaction" })

export const BotAttachment = Schema.Struct({
  type: Schema.Literal("url_preview"),
  url: Schema.String,
  title: OptionalString,
  description: OptionalString,
  image: Schema.optionalKey(BotFile),
}).annotate({
  identifier: "BotAttachment",
  description: "Structured attachment shown with a message.",
})

export const BotMessageReference = Schema.Struct({
  message_id: MessageId.annotateKey({
    description: "Unique identifier for this message within the chat.",
  }),
  peer_id: BotPeerId.annotateKey({
    description: "Required peer identity used to address this conversation.",
  }),
  chat_id: OptionalChatId.annotateKey({
    description: "Deprecated compatibility alias. Prefer peer_id.chat_id.",
  }),
  peer: Schema.optionalKey(BotPeer).annotateKey({
    description:
      "Deprecated compatibility peer. Prefer peer_id.",
  }),
  from_id: UserId.annotateKey({
    description: "Unique identifier of the message sender.",
  }),
  from: BotUser.annotateKey({
    description: "Basic information about the message sender.",
  }),
  date: WireNonNegativeInteger.annotateKey({
    description:
      "Time the message was sent, as Unix time in seconds.",
  }),
  edit_date: Schema.optionalKey(WireNonNegativeInteger).annotateKey({
    description: "Time of the latest edit, as Unix time in seconds.",
  }),
  text: OptionalString.annotateKey({
    description: "Text of the message, when present.",
  }),
  entities: Schema.optionalKey(
    Schema.mutable(Schema.Array(BotMessageEntityOutput)),
  ).annotateKey({
    description:
      "Formatting and semantic entities found in the message text.",
  }),
  rich_message: Schema.optionalKey(BotRichMessage).annotateKey({
    description:
      "Recursive structural content. When present, this is the semantic rich-content source instead of entities.",
  }),
  media: Schema.optionalKey(BotMedia).annotateKey({
    description: "Media attached to the message.",
  }),
  attachments: Schema.optionalKey(
    Schema.mutable(Schema.Array(BotAttachment)),
  ).annotateKey({
    description: "Structured attachments associated with the message.",
  }),
  actions: Schema.optionalKey(
    Schema.mutable(
      Schema.Array(Schema.mutable(Schema.Array(BotMessageAction))),
    ),
  ).annotateKey({
    description: "Rows of interactive message actions.",
  }),
  reactions: Schema.optionalKey(
    Schema.mutable(Schema.Array(BotMessageReaction)),
  ).annotateKey({
    description: "Aggregated reactions on the message.",
  }),
}).annotate({
  identifier: "BotMessageReference",
  description:
    "A message without its replied-to message attached.",
})

export const BotChat = Schema.Struct({
  ...BotChatBase.fields,
  parent_message: Schema.optionalKey(
    BotMessageReference,
  ).annotateKey({
    description:
      "Message anchoring this reply thread. Its chat omits parent_message and it has no reply_to_message.",
  }),
}).annotate({
  identifier: "BotChat",
  description:
    "Information about an Inline user chat or thread.",
})

export const BotEventChat = Schema.Struct({
  ...BotChat.fields,
  type: BotChatType,
}).annotate({
  identifier: "BotEventChat",
  description: "Chat snapshot embedded in a bot update.",
})

export const BotMessage = Schema.Struct({
  ...BotMessageReference.fields,
  chat: Schema.optionalKey(BotChat).annotateKey({
    description:
      "Expanded containing chat when useful in this response. Repeated history and nested messages may omit it.",
  }),
  reply_to_message: Schema.optionalKey(
    BotMessageReference,
  ).annotateKey({
    description:
      "Original message when this message is a reply.",
  }),
}).annotate({
  identifier: "BotMessage",
  description: "A message returned by the Inline Bot API.",
})

export const BotEventMessage = Schema.Struct({
  ...BotMessage.fields,
  chat: BotEventChat,
}).annotate({
  identifier: "BotEventMessage",
  description: "Message snapshot embedded in a bot update.",
})

export const BotActivationReason = Schema.Literals([
  "direct",
  "all",
  "mention",
  "reply",
  "command",
  "action",
]).annotate({ identifier: "BotActivationReason" })

export const BotUpdateKey = Schema.Literals([
  "message",
  "edited_message",
  "message_reaction",
  "message_action",
  "bot_participation",
]).annotate({ identifier: "BotUpdateKey" })

export const BotMessageTrigger = Schema.Literals([
  "all",
  "mentions",
]).annotate({ identifier: "BotMessageTrigger" })

export const BotParticipationChange = Schema.Struct({
  chat: BotEventChat,
  actor: Schema.optionalKey(BotUser),
  date: WireNonNegativeInteger,
  status: Schema.Literals(["added", "removed"]),
}).annotate({ identifier: "BotParticipationChange" })

const BotUpdateBaseFields = {
  update_id: WirePositiveInteger,
  activation_reason: Schema.optionalKey(BotActivationReason),
} as const

const BotActionInvocation = Schema.Union([
  Schema.Struct({
    action_id: Schema.String,
    callback_data: Schema.String,
    callback_data_base64: Schema.optionalKey(Schema.Never),
  }),
  Schema.Struct({
    action_id: Schema.String,
    callback_data: Schema.optionalKey(Schema.Never),
    callback_data_base64: Schema.String,
  }),
  Schema.Struct({
    action_id: Schema.String,
    callback_data: Schema.optionalKey(Schema.Never),
    callback_data_base64: Schema.optionalKey(Schema.Never),
  }),
])

export const BotUpdate = Schema.Union([
  Schema.Struct({ ...BotUpdateBaseFields, message: BotEventMessage }),
  Schema.Struct({ ...BotUpdateBaseFields, edited_message: BotEventMessage }),
  Schema.Struct({
    ...BotUpdateBaseFields,
    message_reaction: Schema.Struct({
      chat: BotEventChat,
      message_id: MessageId,
      actor: BotUser,
      date: WireNonNegativeInteger,
      old_reaction: Schema.mutable(Schema.Array(BotReaction)),
      new_reaction: Schema.mutable(Schema.Array(BotReaction)),
    }),
  }),
  Schema.Struct({
    ...BotUpdateBaseFields,
    message_action: Schema.Struct({
      interaction_id: WirePositiveInteger,
      chat: BotEventChat,
      message_id: MessageId,
      actor: BotUser,
      date: WireNonNegativeInteger,
      action: BotActionInvocation,
    }),
  }),
  Schema.Struct({
    ...BotUpdateBaseFields,
    bot_participation: BotParticipationChange,
  }),
], { mode: "oneOf" }).annotate({
  identifier: "BotUpdate",
  description: "One durable event from the authenticated bot's update stream.",
})

export const BotMessageReferenceCompatibility = Schema.Struct({
  ...BotMessageReference.fields,
  peer: Schema.optionalKey(BotPeerCompatibility),
})

export const BotMessageCompatibility = Schema.Struct({
  ...BotMessage.fields,
  peer: Schema.optionalKey(BotPeerCompatibility),
  reply_to_message: Schema.optionalKey(
    BotMessageReferenceCompatibility,
  ),
})

export const SendMessageInput = Schema.Struct({
  ...BotTargetFields,
  text: Schema.optionalKey(Schema.String).annotateKey({
    description: "Text of the message to send.",
  }),
  reply_to_message_id: Schema.optionalKey(
    MessageId,
  ).annotateKey({
    description:
      "Message to reply to in the target chat.",
  }),
  parse_markdown: Schema.optionalKey(
    Schema.Boolean,
  ).annotateKey({
    description:
      "Parse supported Markdown formatting from text.",
  }),
  media: Schema.optionalKey(Schema.Union([
    Schema.Struct({ type: Schema.Literal("nudge") }),
    Schema.Struct({
      type: Schema.Literals(["photo", "video", "document", "voice"]),
      file_id: Schema.String.check(Schema.isMinLength(1)),
    }),
  ], { mode: "oneOf" })),
  actions: Schema.optionalKey(
    Schema.Array(Schema.Array(BotMessageAction).check(Schema.isMaxLength(8))).check(Schema.isMaxLength(8)),
  ),
  silent: Schema.optionalKey(Schema.Boolean),
}).annotate({
  identifier: "SendMessageInput",
  description:
    "Parameters for sending a text message. Exactly one target field is required.",
})

export const GetChatInput = Schema.Struct({
  ...BotTargetQueryFields,
}).annotate({
  identifier: "GetChatInput",
  description:
    "Selects a chat or private conversation. Exactly one target field is required.",
})

export const GetChatHistoryInput = Schema.Struct({
  ...BotTargetQueryFields,
  limit: Schema.optionalKey(
    WireSafeIntegerFromString,
  ).annotateKey({
    description: getChatHistoryFieldDescriptions.limit,
  }),
  offset_message_id: Schema.optionalKey(
    MessageIdFromString,
  ).annotateKey({
    description:
      getChatHistoryFieldDescriptions.offset_message_id,
  }),
}).annotate({
  identifier: "GetChatHistoryInput",
  description:
    "Selects a conversation and an optional page of older messages.",
})

export const GetMessagesInput = Schema.Struct({
  ...BotTargetFields,
  message_ids: Schema.Array(MessageId).check(
    Schema.isMinLength(1),
    Schema.isMaxLength(100),
  ),
}).annotate({
  identifier: "GetMessagesInput",
  description: "Selects up to 100 exact messages in one conversation.",
})

export const BotSearchFilter = Schema.Literals([
  "photo",
  "video",
  "photo_video",
  "document",
  "link",
  "voice",
]).annotate({ identifier: "BotSearchFilter" })

export const SearchMessagesInput = Schema.Struct({
  ...BotTargetFields,
  query: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(256)),
  filter: Schema.optionalKey(BotSearchFilter),
  offset_message_id: OptionalMessageId,
  limit: Schema.optionalKey(
    WireSafeInteger.check(Schema.isBetween({ minimum: 1, maximum: 100 })),
  ),
}).annotate({
  identifier: "SearchMessagesInput",
  description: "Searches messages within exactly one accessible chat.",
})

const OptionalParticipantIds = Schema.optionalKey(
  Schema.Array(UserId).check(Schema.isMaxLength(50)),
)

export const CreateThreadInput = Schema.Struct({
  title: OptionalString,
  emoji: OptionalString,
  space_id: OptionalSpaceId,
  is_public: Schema.optionalKey(Schema.Boolean),
  participants: OptionalParticipantIds,
}).annotate({
  identifier: "CreateThreadInput",
  description: "Creates a normal Inline thread using existing access rules.",
})

export const CreateReplyThreadInput = Schema.Struct({
  chat_id: ChatId,
  message_id: MessageId,
  title: OptionalString,
  emoji: OptionalString,
  participants: OptionalParticipantIds,
}).annotate({
  identifier: "CreateReplyThreadInput",
  description: "Creates or returns the reply thread anchored to a message.",
})

export const EditMessageTextInput = Schema.Struct({
  ...BotTargetFields,
  message_id: MessageId.annotateKey({
    description: "Message to edit in the target chat.",
  }),
  text: Schema.String.annotateKey({
    description: "New text for the message.",
  }),
  parse_markdown: Schema.optionalKey(
    Schema.Boolean,
  ).annotateKey({
    description:
      "Parse supported Markdown formatting from the new text.",
  }),
  actions: Schema.optionalKey(
    Schema.Array(Schema.Array(BotMessageAction).check(Schema.isMaxLength(8))).check(Schema.isMaxLength(8)),
  ),
}).annotate({
  identifier: "EditMessageTextInput",
  description:
    "Parameters for editing a text message. Exactly one target field is required.",
})

export const EditMessageActionsInput = Schema.Struct({
  ...BotTargetFields,
  message_id: MessageId,
  actions: Schema.Array(
    Schema.Array(BotMessageAction).check(Schema.isMaxLength(8)),
  ).check(Schema.isMaxLength(8)),
}).annotate({
  identifier: "EditMessageActionsInput",
  description:
    "Replaces all actions on a bot-authored message. An empty array clears them without changing text.",
})

export const DeleteMessageInput = Schema.Struct({
  ...BotTargetFields,
  message_id: MessageId.annotateKey({
    description: "Message to delete in the target chat.",
  }),
}).annotate({
  identifier: "DeleteMessageInput",
  description:
    "Parameters for deleting a message. Exactly one target field is required.",
})

export const DeleteMessagesInput = Schema.Struct({
  ...BotTargetFields,
  message_ids: Schema.Array(MessageId).check(
    Schema.isMinLength(1),
    Schema.isMaxLength(100),
  ),
}).annotate({
  identifier: "DeleteMessagesInput",
  description:
    "Deletes up to 100 messages. Missing message IDs are skipped, matching Telegram's batch behavior.",
})

export const SendReactionInput = Schema.Struct({
  ...BotTargetFields,
  message_id: MessageId.annotateKey({
    description: "Message to react to in the target chat.",
  }),
  emoji: Schema.String.annotateKey({
    description: "Emoji reaction to add or update.",
  }),
}).annotate({
  identifier: "SendReactionInput",
  description:
    "Parameters for reacting to a message. Exactly one target field is required.",
})

export const DeleteReactionInput = SendReactionInput.annotate({
  identifier: "DeleteReactionInput",
  description: "Removes the bot's own reaction from a message.",
})

export const AnswerMessageActionInput = Schema.Struct({
  interaction_id: MessageId,
  text: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(200))),
}).annotate({ identifier: "AnswerMessageActionInput" })

export const BotChatAction = Schema.Literals([
  "typing",
  "upload_photo",
  "upload_video",
  "upload_document",
  "record_voice",
  "cancel",
]).annotate({ identifier: "BotChatAction" })

export const SendChatActionInput = Schema.Struct({
  ...BotTargetFields,
  action: BotChatAction,
}).annotate({ identifier: "SendChatActionInput" })

export const GetFileInput = Schema.Struct({
  file_id: Schema.String.check(Schema.isMinLength(1)),
}).annotate({ identifier: "GetFileInput" })

export const GetUpdatesInput = Schema.Struct({
  offset: Schema.optionalKey(MessageIdFromString),
  limit: Schema.optionalKey(WireSafeIntegerFromString),
  timeout: Schema.optionalKey(WireSafeIntegerFromString),
  message_trigger: Schema.optionalKey(BotMessageTrigger),
  allowed_updates: Schema.optionalKey(Schema.Union([Schema.String, Schema.Array(BotUpdateKey)])),
}).annotate({ identifier: "GetUpdatesInput" })

export const SetWebhookInput = Schema.Struct({
  url: Schema.String,
  secret_token: Schema.optionalKey(
    Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(256)),
  ),
  message_trigger: Schema.optionalKey(BotMessageTrigger),
  allowed_updates: Schema.optionalKey(Schema.Array(BotUpdateKey)),
  drop_pending_updates: Schema.optionalKey(Schema.Boolean),
}).annotate({ identifier: "SetWebhookInput" })

export const DeleteWebhookInput = Schema.Struct({
  drop_pending_updates: Schema.optionalKey(Schema.Boolean),
}).annotate({ identifier: "DeleteWebhookInput" })

export const SetMyCommandsInput = Schema.Struct({
  commands: Schema.Array(BotCommand).check(
    Schema.isMaxLength(100),
  ).annotateKey({
    description:
      "Complete replacement list of up to 100 commands. Send an empty array to clear it.",
  }),
}).annotate({
  identifier: "SetMyCommandsInput",
  description: "Commands to publish for the authenticated bot.",
})

export const ForwardMessageInput = Schema.Struct({
  chat_id: ChatId,
  from_chat_id: ChatId,
  message_id: MessageId,
}).annotate({ identifier: "ForwardMessageInput" })

export const ForwardMessagesInput = Schema.Struct({
  chat_id: ChatId,
  from_chat_id: ChatId,
  message_ids: Schema.Array(MessageId).check(
    Schema.isMinLength(1),
    Schema.isMaxLength(100),
  ),
}).annotate({
  identifier: "ForwardMessagesInput",
  description:
    "Forwards up to 100 messages and returns the new IDs. Missing source IDs are skipped.",
})

export const PinMessageInput = Schema.Struct({
  chat_id: ChatId,
  message_id: MessageId,
}).annotate({ identifier: "PinMessageInput" })

export const GetChatParticipantInput = Schema.Struct({
  chat_id: ChatIdFromString,
  user_id: UserIdFromString,
}).annotate({ identifier: "GetChatParticipantInput" })

export const GetChatParticipantCountInput = Schema.Struct({
  chat_id: ChatIdFromString,
}).annotate({ identifier: "GetChatParticipantCountInput" })

export const ThreadParticipantMutationInput = Schema.Struct({
  chat_id: ChatId,
  user_id: UserId,
}).annotate({ identifier: "ThreadParticipantMutationInput" })

export const SetThreadTitleInput = Schema.Struct({
  chat_id: ChatId,
  title: Schema.optionalKey(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(256))),
  emoji: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(20))),
}).annotate({ identifier: "SetThreadTitleInput" })

export const GetSpaceInput = Schema.Struct({
  space_id: SpaceId,
}).annotate({
  identifier: "GetSpaceInput",
  description: "Returns one accessible space and only the bot's own membership.",
})

export const BotSpaceMember = Schema.Struct({
  id: WirePositiveInteger,
  space_id: SpaceId,
  user_id: UserId,
  role: Schema.optionalKey(Schema.Literals(["owner", "admin", "member"])),
  date: WireNonNegativeInteger,
  can_access_public_chats: Schema.Boolean,
}).annotate({ identifier: "BotSpaceMember" })

export const BotSpace = Schema.Struct({
  id: SpaceId,
  name: Schema.String,
  is_public: Schema.optionalKey(Schema.Boolean),
  handle: OptionalString,
}).annotate({ identifier: "BotSpace" })

export const BotChatParticipant = Schema.Struct({
  user: BotUser,
  member: Schema.optionalKey(BotSpaceMember),
}).annotate({ identifier: "BotChatParticipant" })

export const BotUploadFilePayload = Schema.Struct({
  type: Schema.Literals(["photo", "video", "document", "voice"]),
  file: Multipart.SingleFileSchema,
  thumbnail: Schema.optional(Multipart.SingleFileSchema),
  width: Schema.optionalKey(Schema.String),
  height: Schema.optionalKey(Schema.String),
  duration: Schema.optionalKey(Schema.String),
  is_animated: Schema.optionalKey(Schema.String),
  has_audio: Schema.optionalKey(Schema.String),
  waveform_base64: Schema.optionalKey(Schema.String),
}).pipe(HttpApiSchema.asMultipart()).annotate({ identifier: "BotUploadFilePayload" })

export const BotEmptyResult = Schema.Record(
  Schema.String,
  Schema.Never,
).annotate({
  identifier: "BotEmptyResult",
  description:
    "Empty result returned when an action completes successfully.",
})
// The record produces the exact OpenAPI `{}` shape. Keep the empty Struct for
// runtime decoding because its type composes with the other operation results.
const BotEmptyRuntimeResult = Schema.Struct({})
export const BotGetChatResult = Schema.Struct({
  chat: BotChat.annotateKey({
    description: "The requested chat.",
  }),
}).annotate({
  identifier: "BotGetChatResult",
  description: "Information about the requested chat.",
})
export const BotGetSpaceResult = Schema.Struct({
  space: BotSpace,
  membership: BotSpaceMember,
  settings: Schema.Struct({ grid_enabled: Schema.Boolean }),
}).annotate({
  identifier: "BotGetSpaceResult",
  description: "An accessible space, the bot's membership, and bot-relevant settings.",
})
export const BotGetChatHistoryResult = Schema.Struct({
  messages: Schema.mutable(
    Schema.Array(BotMessage),
  ).annotateKey({
    description:
      "Messages in the requested history page.",
  }),
}).annotate({
  identifier: "BotGetChatHistoryResult",
  description: "A page of messages from a chat.",
})
export const BotGetChatHistoryRuntimeResult = Schema.Struct({
  messages: Schema.mutable(
    Schema.Array(BotMessageCompatibility),
  ),
})
export const BotMessagesResult = Schema.Struct({
  messages: Schema.mutable(Schema.Array(BotMessage)),
}).annotate({
  identifier: "BotMessagesResult",
  description: "Messages returned by an exact read or search.",
})
export const BotMessagesRuntimeResult = Schema.Struct({
  messages: Schema.mutable(Schema.Array(BotMessageCompatibility)),
})
export const BotCreateThreadResult = Schema.Struct({
  chat: BotChat,
}).annotate({
  identifier: "BotCreateThreadResult",
  description: "The created or existing thread.",
})
export const BotGetFileResult = Schema.Struct({ file: BotFile }).annotate({
  identifier: "BotGetFileResult",
})
export const BotGetUpdatesResult = Schema.mutable(Schema.Array(BotUpdate)).annotate({
  identifier: "BotGetUpdatesResult",
})
export const BotWebhookInfo = Schema.Struct({
  url: Schema.String,
  pending_update_count: WireNonNegativeInteger,
  allowed_updates: Schema.mutable(Schema.Array(BotUpdateKey)),
  message_trigger: BotMessageTrigger,
  last_error_date: Schema.optionalKey(WireNonNegativeInteger),
  last_error_message: OptionalString,
  dropped_update_count: WireNonNegativeInteger,
}).annotate({ identifier: "BotWebhookInfo" })
export const BotMessageResult = Schema.Struct({
  message: BotMessage.annotateKey({
    description: "The sent or updated message.",
  }),
}).annotate({
  identifier: "BotMessageResult",
  description: "A message returned after a successful mutation.",
})
export const BotMessageRuntimeResult = Schema.Struct({
  message: BotMessageCompatibility,
})
export const BotForwardMessagesResult = Schema.Struct({
  message_ids: Schema.mutable(Schema.Array(MessageId)),
}).annotate({
  identifier: "BotForwardMessagesResult",
  description: "New message IDs, in the same order as the source messages that were forwarded.",
})
export const BotGetMyCommandsResult = Schema.Struct({
  commands: Schema.mutable(
    Schema.Array(BotCommand),
  ).annotateKey({
    description:
      "Commands currently published by the bot, in display order.",
  }),
}).annotate({
  identifier: "BotGetMyCommandsResult",
  description: "The authenticated bot's command list.",
})

export const BotGetChatParticipantResult = Schema.Struct({ participant: BotChatParticipant }).annotate({ identifier: "BotGetChatParticipantResult" })
export const BotGetChatParticipantCountResult = Schema.Struct({ count: WireNonNegativeInteger }).annotate({ identifier: "BotGetChatParticipantCountResult" })

const exampleBotUserId = UserId.make(284_901)
const exampleMemberId = UserId.make(391_204)
const exampleSpaceId = SpaceId.make(912)
const exampleChatId = ChatId.make(73_142)
const examplePrivateChatId = ChatId.make(73_143)
const examplePreviousMessageId =
  MessageId.make(1_807)
const exampleMessageId = MessageId.make(1_808)
const exampleMessageDate = 1_784_332_860
const exampleMessageText =
  "Deployment finished successfully."
const exampleMessageEntities: Array<
  typeof BotMessageEntityOutput.Type
> = [
  {
    type: "bold",
    offset: 0,
    length: 10,
  },
]

const exampleBotUser: typeof BotUser.Type = {
  id: exampleBotUserId,
  is_bot: true,
  username: "deploy_bot",
  first_name: "Deploy Bot",
}

const exampleMember: typeof BotUser.Type = {
  id: exampleMemberId,
  is_bot: false,
  username: "maya",
  first_name: "Maya",
  last_name: "Chen",
}

const exampleChat: typeof BotChat.Type = {
  chat_id: exampleChatId,
  type: "thread",
  title: "Product",
  space_id: exampleSpaceId,
  is_public: false,
  number: 42,
  last_message_id: examplePreviousMessageId,
  last_message: {
    message_id: examplePreviousMessageId,
    from_id: exampleMember.id,
    from: exampleMember,
    date: 1_784_332_800,
    text: "Can you deploy the latest build?",
  },
  emoji: "🚀",
}

const examplePrivateChat: typeof BotChat.Type = {
  chat_id: examplePrivateChatId,
  type: "user",
  title: "Maya Chen",
  is_public: false,
  last_message_id: exampleMessageId,
  last_message: {
    message_id: exampleMessageId,
    from_id: exampleBotUser.id,
    from: exampleBotUser,
    date: exampleMessageDate,
    text: exampleMessageText,
    entities: exampleMessageEntities,
  },
}

const exampleMessage: typeof BotMessage.Type = {
  message_id: exampleMessageId,
  peer_id: { user_id: exampleMember.id },
  chat_id: examplePrivateChat.chat_id,
  chat: examplePrivateChat,
  peer: {
    user_id: exampleMember.id,
  },
  from_id: exampleBotUser.id,
  from: exampleBotUser,
  date: exampleMessageDate,
  text: exampleMessageText,
  entities: exampleMessageEntities,
}

const exampleHistoryMessage: typeof BotMessage.Type = {
  message_id: exampleMessage.message_id,
  peer_id: exampleMessage.peer_id,
  chat_id: exampleMessage.chat_id,
  peer: exampleMessage.peer,
  from_id: exampleMessage.from_id,
  from: exampleMessage.from,
  date: exampleMessage.date,
  text: exampleMessage.text,
  entities: exampleMessage.entities,
}

export const BotGetChatSuccess = botApiSuccess(
  BotGetChatResult,
).annotate({
  identifier: "BotGetChatSuccess",
  description: "Successful getChat response.",
  examples: [
    {
      ok: true,
      result: {
        chat: exampleChat,
      },
    },
  ],
})
export const BotGetSpaceSuccess = botApiSuccess(BotGetSpaceResult).annotate({
  identifier: "BotGetSpaceSuccess",
  description: "Successful getSpace response.",
})
export const BotGetChatHistorySuccess = botApiSuccess(
  BotGetChatHistoryResult,
).annotate({
  identifier: "BotGetChatHistorySuccess",
  description: "Successful getChatHistory response.",
  examples: [
    {
      ok: true,
      result: {
        messages: [exampleHistoryMessage],
      },
    },
  ],
})
export const BotMessageSuccess = botApiSuccess(
  BotMessageResult,
).annotate({
  identifier: "BotMessageSuccess",
  description:
    "Successful sendMessage, editMessageText, or editMessageActions response.",
  examples: [
    {
      ok: true,
      result: {
        message: exampleMessage,
      },
    },
  ],
})
export const BotMessageRuntimeSuccess = botApiSuccess(
  BotMessageRuntimeResult,
)
export const BotGetChatHistoryRuntimeSuccess = botApiSuccess(
  BotGetChatHistoryRuntimeResult,
)
export const BotMessagesSuccess = botApiSuccess(BotMessagesResult).annotate({
  identifier: "BotMessagesSuccess",
  description: "Successful exact-message read or search response.",
})
export const BotMessagesRuntimeSuccess = botApiSuccess(BotMessagesRuntimeResult)
export const BotForwardMessagesSuccess = botApiSuccess(BotForwardMessagesResult).annotate({
  identifier: "BotForwardMessagesSuccess",
})
export const BotCreateThreadSuccess = botApiSuccess(BotCreateThreadResult).annotate({
  identifier: "BotCreateThreadSuccess",
  description: "Successful normal or reply-thread creation response.",
})
export const BotGetFileSuccess = botApiSuccess(BotGetFileResult).annotate({
  identifier: "BotGetFileSuccess",
})
export const BotGetUpdatesSuccess = botApiSuccess(BotGetUpdatesResult).annotate({
  identifier: "BotGetUpdatesSuccess",
})
export const BotWebhookInfoSuccess = botApiSuccess(BotWebhookInfo).annotate({
  identifier: "BotWebhookInfoSuccess",
})
export const BotTrueSuccess = botApiSuccess(Schema.Literal(true)).annotate({
  identifier: "BotTrueSuccess",
})
export const BotGetMyCommandsSuccess = botApiSuccess(
  BotGetMyCommandsResult,
).annotate({
  identifier: "BotGetMyCommandsSuccess",
  description: "Successful getMyCommands response.",
  examples: [
    {
      ok: true,
      result: {
        commands: [
          {
            command: "deploy",
            description: "Deploy the latest build",
            sort_order: 10,
          },
          {
            command: "status",
            description: "Show the current deployment status",
            sort_order: 20,
          },
        ],
      },
    },
  ],
})
export const BotGetChatParticipantSuccess = botApiSuccess(BotGetChatParticipantResult).annotate({ identifier: "BotGetChatParticipantSuccess" })
export const BotGetChatParticipantCountSuccess = botApiSuccess(BotGetChatParticipantCountResult).annotate({ identifier: "BotGetChatParticipantCountSuccess" })
export const BotEmptySuccess = botApiSuccess(
  BotEmptyResult,
).annotate({
  identifier: "BotEmptySuccess",
  description:
    "Successful response for an action with no return value.",
  examples: [
    {
      ok: true,
      result: {},
    },
  ],
})
export const BotEmptyRuntimeSuccess = botApiSuccess(
  BotEmptyRuntimeResult,
)

export const botApiErrorAt = (
  status: number,
  identifier: string,
  description: string,
  example: {
    readonly ok: false
    readonly error: string
    readonly error_code: number
    readonly description: string
  },
) =>
  BotApiError.pipe(
    HttpApiSchema.status(status),
  ).annotate({
    identifier,
    description,
    examples: [example],
  })

export const botApiErrors = [
  botApiErrorAt(
    400,
    "BotBadRequestError",
    "The request parameters are missing or invalid.",
    {
      ok: false,
      error: "CHAT_ID_INVALID",
      error_code: 400,
      description: "The chat id is invalid",
    },
  ),
  botApiErrorAt(
    401,
    "BotUnauthorizedError",
    "The bot token is missing or invalid.",
    {
      ok: false,
      error: "UNAUTHORIZED",
      error_code: 401,
      description: "Unauthorized",
    },
  ),
  botApiErrorAt(
    403,
    "BotForbiddenError",
    "The bot is not allowed to perform this action.",
    {
      ok: false,
      error: "FORBIDDEN",
      error_code: 403,
      description: "Forbidden",
    },
  ),
  botApiErrorAt(
    404,
    "BotNotFoundError",
    "The requested method or resource was not found.",
    {
      ok: false,
      error: "METHOD_NOT_FOUND",
      error_code: 404,
      description: "Method not found",
    },
  ),
  botApiErrorAt(
    500,
    "BotInternalServerError",
    "The server could not complete the request.",
    {
      ok: false,
      error: "SERVER_ERROR",
      error_code: 500,
      description: "Server error",
    },
  ),
] as const

type Assert<T extends true> = T
type Extends<Left, Right> = [Left] extends [Right]
  ? true
  : false

type _BotPeerMatchesNeutral = Assert<
  Extends<typeof BotPeer.Type, NeutralBotPeer>
>
type _BotPeerIdMatchesNeutral = Assert<
  Extends<typeof BotPeerId.Type, NeutralBotPeerId>
>
type _BotRichTextMatchesNeutral = Assert<
  Extends<typeof BotRichText.Type, NeutralBotRichText>
>
type _BotRichBlockMatchesNeutral = Assert<
  Extends<typeof BotRichBlock.Type, NeutralBotRichBlock>
>
type _BotRichMessageMatchesNeutral = Assert<
  Extends<typeof BotRichMessage.Type, NeutralBotRichMessage>
>
type _BotCommandMatchesNeutral = Assert<
  Extends<typeof BotCommand.Type, NeutralBotCommand>
>
type _BotEntityMatchesNeutral = Assert<
  Extends<
    typeof BotMessageEntityOutput.Type,
    NeutralBotMessageEntityOutput
  >
>
type _BotFileMatchesNeutral = Assert<
  Extends<typeof BotFile.Type, NeutralBotFile>
>
type _BotMediaMatchesNeutral = Assert<
  Extends<typeof BotMedia.Type, NeutralBotMedia>
>
type _BotActionMatchesNeutral = Assert<
  Extends<typeof BotMessageAction.Type, NeutralBotMessageAction>
>
type _BotReactionMatchesNeutral = Assert<
  Extends<typeof BotMessageReaction.Type, NeutralBotMessageReaction>
>
type _BotAttachmentMatchesNeutral = Assert<
  Extends<typeof BotAttachment.Type, NeutralBotAttachment>
>
type _BotChatMatchesNeutral = Assert<
  Extends<typeof BotChat.Type, NeutralBotChat>
>
type _BotMessageReferenceMatchesNeutral = Assert<
  Extends<
    typeof BotMessageReference.Type,
    Omit<NeutralBotMessage, "chat" | "reply_to_message">
  >
>
type _BotMessageMatchesNeutral = Assert<
  Extends<typeof BotMessage.Type, NeutralBotMessage>
>
