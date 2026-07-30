import type {
  BotChat as NeutralBotChat,
  BotCapability as NeutralBotCapability,
  BotCommand as NeutralBotCommand,
  BotMessage as NeutralBotMessage,
  BotMessageEntityOutput as NeutralBotMessageEntityOutput,
  BotMessageLite as NeutralBotMessageLite,
  BotPeer as NeutralBotPeer,
} from "@inline-chat/bot-api-types"
import { Schema } from "effect"
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
  "url",
  "text_link",
  "email",
  "bold",
  "italic",
  "username_mention",
  "code",
  "pre",
  "phone_number",
  "thread",
  "thread_title",
  "bot_command",
]).annotate({
  identifier: "BotMessageEntityType",
  description:
    "Formatting, link, mention, and command metadata attached to a range of message text.",
})

export const BotMessageEntityInput = Schema.Struct({
  type: BotMessageEntityType.annotateKey({
    description: "Kind of formatting or semantic entity.",
  }),
  offset: WireNonNegativeInteger.annotateKey({
    description:
      "Zero-based offset where the entity begins in the message text.",
  }),
  length: WireNonNegativeInteger.annotateKey({
    description:
      "Number of text units covered by the entity.",
  }),
  user_id: OptionalUserId.annotateKey({
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
}).annotate({
  identifier: "BotMessageEntityInput",
  description:
    "Formatting or semantic metadata to apply to part of outgoing message text.",
})

export const BotMessageEntityOutput = Schema.Struct({
  type: Schema.Literals([
    "mention",
    "url",
    "text_link",
    "email",
    "bold",
    "italic",
    "username_mention",
    "code",
    "pre",
    "phone_number",
    "thread",
    "thread_title",
    "bot_command",
    "unknown",
  ]).annotateKey({
    description: "Kind of formatting or semantic entity.",
  }),
  offset: WireNonNegativeInteger.annotateKey({
    description:
      "Zero-based offset where the entity begins in the message text.",
  }),
  length: WireNonNegativeInteger.annotateKey({
    description:
      "Number of text units covered by the entity.",
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
}).annotate({
  identifier: "BotMessageEntityOutput",
  description:
    "Formatting or semantic metadata found in message text.",
})

export const BotPeer = Schema.Struct({
  user_id: OptionalUserId.annotateKey({
    description:
      "The other user in a private conversation. Group chats do not include this field.",
  }),
}).annotate({
  identifier: "BotPeer",
  description:
    "Additional peer information retained for private-chat compatibility. Prefer message.chat_id as the conversation identifier.",
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

export const BotCapability = Schema.Struct({
  kind: Schema.Literal("chat_settings"),
  version: Schema.Literal(1),
}).annotate({
  identifier: "BotCapability",
  description: "A versioned capability advertised by the bot.",
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
}).annotate({
  identifier: "BotChatLastMessage",
  description:
    "Compact representation of the most recent message in a chat.",
})

export const BotChat = Schema.Struct({
  chat_id: ChatId.annotateKey({
    description: "Unique identifier for this chat.",
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
  identifier: "BotChat",
  description:
    "Information about an Inline private conversation, group, or thread.",
})

export const BotMessageLite = Schema.Struct({
  message_id: MessageId.annotateKey({
    description: "Unique identifier for this message within the chat.",
  }),
  chat_id: ChatId.annotateKey({
    description: "Identifier of the chat containing the message.",
  }),
  chat: BotChat.annotateKey({
    description: "Information about the containing chat.",
  }),
  peer: BotPeer.annotateKey({
    description:
      "Additional private-chat peer information. Prefer chat_id for addressing the conversation.",
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
}).annotate({
  identifier: "BotMessageLite",
  description:
    "A message without its replied-to message attached.",
})

export const BotMessage = Schema.Struct({
  ...BotMessageLite.fields,
  reply_to_message: Schema.optionalKey(
    BotMessageLite,
  ).annotateKey({
    description:
      "Original message when this message is a reply.",
  }),
}).annotate({
  identifier: "BotMessage",
  description: "A message returned by the Inline Bot API.",
})

export const BotMessageLiteCompatibility = Schema.Struct({
  ...BotMessageLite.fields,
  peer: BotPeerCompatibility,
})

export const BotMessageCompatibility = Schema.Struct({
  ...BotMessageLiteCompatibility.fields,
  reply_to_message: Schema.optionalKey(
    BotMessageLiteCompatibility,
  ),
})

export const SendMessageInput = Schema.Struct({
  ...BotTargetFields,
  text: Schema.String.annotateKey({
    description: "Text of the message to send.",
  }),
  reply_to_message_id: Schema.optionalKey(
    MessageId,
  ).annotateKey({
    description:
      "Message to reply to in the target chat.",
  }),
  entities: Schema.optionalKey(
    Schema.Array(BotMessageEntityInput),
  ).annotateKey({
    description:
      "Explicit formatting and semantic entities in text.",
  }),
  parse_markdown: Schema.optionalKey(
    Schema.Boolean,
  ).annotateKey({
    description:
      "Parse supported Markdown formatting from text.",
  }),
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

export const EditMessageTextInput = Schema.Struct({
  ...BotTargetFields,
  message_id: MessageId.annotateKey({
    description: "Message to edit in the target chat.",
  }),
  text: Schema.String.annotateKey({
    description: "New text for the message.",
  }),
  entities: Schema.optionalKey(
    Schema.Array(BotMessageEntityInput),
  ).annotateKey({
    description:
      "Explicit formatting and semantic entities in the new text.",
  }),
  parse_markdown: Schema.optionalKey(
    Schema.Boolean,
  ).annotateKey({
    description:
      "Parse supported Markdown formatting from the new text.",
  }),
}).annotate({
  identifier: "EditMessageTextInput",
  description:
    "Parameters for editing a text message. Exactly one target field is required.",
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

export const SetMyCapabilitiesInput = Schema.Struct({
  capabilities: Schema.Array(BotCapability).check(Schema.isMaxLength(100)),
}).annotate({
  identifier: "SetMyCapabilitiesInput",
  description: "Complete capability list for the authenticated bot.",
})

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

export const BotGetMyCapabilitiesResult = Schema.Struct({
  capabilities: Schema.mutable(Schema.Array(BotCapability)),
}).annotate({
  identifier: "BotGetMyCapabilitiesResult",
  description: "The authenticated bot's capability list.",
})

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
  title: "Product",
  space_id: exampleSpaceId,
  is_public: false,
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
export const BotGetChatHistorySuccess = botApiSuccess(
  BotGetChatHistoryResult,
).annotate({
  identifier: "BotGetChatHistorySuccess",
  description: "Successful getChatHistory response.",
  examples: [
    {
      ok: true,
      result: {
        messages: [exampleMessage],
      },
    },
  ],
})
export const BotMessageSuccess = botApiSuccess(
  BotMessageResult,
).annotate({
  identifier: "BotMessageSuccess",
  description:
    "Successful sendMessage or editMessageText response.",
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
export const BotGetMyCapabilitiesSuccess = botApiSuccess(
  BotGetMyCapabilitiesResult,
).annotate({
  identifier: "BotGetMyCapabilitiesSuccess",
  description: "Successful bot capability response.",
  examples: [{ ok: true, result: { capabilities: [{ kind: "chat_settings", version: 1 }] } }],
})
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
type _BotCommandMatchesNeutral = Assert<
  Extends<typeof BotCommand.Type, NeutralBotCommand>
>
type _BotCapabilityMatchesNeutral = Assert<
  Extends<typeof BotCapability.Type, NeutralBotCapability>
>
type _BotEntityMatchesNeutral = Assert<
  Extends<
    typeof BotMessageEntityOutput.Type,
    NeutralBotMessageEntityOutput
  >
>
type _BotChatMatchesNeutral = Assert<
  Extends<typeof BotChat.Type, NeutralBotChat>
>
type _BotMessageLiteMatchesNeutral = Assert<
  Extends<typeof BotMessageLite.Type, NeutralBotMessageLite>
>
type _BotMessageMatchesNeutral = Assert<
  Extends<typeof BotMessage.Type, NeutralBotMessage>
>
