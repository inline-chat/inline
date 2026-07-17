import type {
  BotChat as NeutralBotChat,
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
  WireNonNegativeInteger,
  WirePositiveInteger,
  WireSafeInteger,
} from "../../core/schema/scalars"

const OptionalString = Schema.optionalKey(Schema.String)
const OptionalWireInteger = Schema.optionalKey(WireSafeInteger)
const BotInputId = Schema.Union([
  WireSafeInteger,
  Schema.String,
]).annotate({
  identifier: "BotInputId",
  description:
    "An Inline identifier encoded as a JSON-safe integer or an integer string.",
})

const BotTargetFields = {
  user_id: Schema.optionalKey(BotInputId),
  chat_id: Schema.optionalKey(BotInputId),
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
})

export const BotMessageEntityInput = Schema.Struct({
  type: BotMessageEntityType,
  offset: BotInputId,
  length: BotInputId,
  user_id: Schema.optionalKey(BotInputId),
  url: OptionalString,
  language: OptionalString,
  chat_id: Schema.optionalKey(BotInputId),
  space_id: Schema.optionalKey(BotInputId),
  title: OptionalString,
}).annotate({
  identifier: "BotMessageEntityInput",
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
  ]),
  offset: WireSafeInteger,
  length: WireSafeInteger,
  user: Schema.optionalKey(BotUser),
  url: OptionalString,
  language: OptionalString,
  chat_id: OptionalWireInteger,
  space_id: OptionalWireInteger,
  title: OptionalString,
}).annotate({
  identifier: "BotMessageEntityOutput",
})

export const BotPeer = Schema.Struct({
  user_id: OptionalWireInteger,
}).annotate({
  identifier: "BotPeer",
})

// TODO(effect-cutover): remove `thread_id` after production telemetry shows no
// Bot response consumer has used the deprecated peer alias for 30 days.
// The canonical OpenAPI surface uses `chat_id`.
export const BotPeerCompatibility = Schema.Struct({
  ...BotPeer.fields,
  thread_id: OptionalWireInteger,
})

export const BotCommand = Schema.Struct({
  command: Schema.String,
  description: Schema.String,
  sort_order: OptionalWireInteger,
}).annotate({
  identifier: "BotCommand",
})

export const BotChatLastMessage = Schema.Struct({
  message_id: WirePositiveInteger,
  from_id: WirePositiveInteger,
  from: BotUser,
  date: WireNonNegativeInteger,
  text: OptionalString,
  entities: Schema.optionalKey(
    Schema.mutable(Schema.Array(BotMessageEntityOutput)),
  ),
}).annotate({
  identifier: "BotChatLastMessage",
})

export const BotChat = Schema.Struct({
  chat_id: WirePositiveInteger,
  title: OptionalString,
  space_id: OptionalWireInteger,
  is_public: Schema.optionalKey(Schema.Boolean),
  last_message_id: OptionalWireInteger,
  last_message: Schema.optionalKey(BotChatLastMessage),
  emoji: OptionalString,
}).annotate({
  identifier: "BotChat",
})

export const BotMessageLite = Schema.Struct({
  message_id: WirePositiveInteger,
  chat_id: WirePositiveInteger,
  chat: BotChat,
  peer: BotPeer,
  from_id: WirePositiveInteger,
  from: BotUser,
  date: WireNonNegativeInteger,
  text: OptionalString,
  entities: Schema.optionalKey(
    Schema.mutable(Schema.Array(BotMessageEntityOutput)),
  ),
}).annotate({
  identifier: "BotMessageLite",
})

export const BotMessage = Schema.Struct({
  ...BotMessageLite.fields,
  reply_to_message: Schema.optionalKey(BotMessageLite),
}).annotate({
  identifier: "BotMessage",
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
  text: Schema.String,
  reply_to_message_id: Schema.optionalKey(BotInputId),
  entities: Schema.optionalKey(
    Schema.Array(BotMessageEntityInput),
  ),
  parse_markdown: Schema.optionalKey(Schema.Boolean),
}).annotate({
  identifier: "SendMessageInput",
})

export const GetChatInput = Schema.Struct({
  ...BotTargetFields,
}).annotate({
  identifier: "GetChatInput",
})

export const GetChatHistoryInput = Schema.Struct({
  ...BotTargetFields,
  limit: Schema.optionalKey(WireSafeInteger),
  offset_message_id: Schema.optionalKey(BotInputId),
}).annotate({
  identifier: "GetChatHistoryInput",
})

export const EditMessageTextInput = Schema.Struct({
  ...BotTargetFields,
  message_id: BotInputId,
  text: Schema.String,
  entities: Schema.optionalKey(
    Schema.Array(BotMessageEntityInput),
  ),
  parse_markdown: Schema.optionalKey(Schema.Boolean),
}).annotate({
  identifier: "EditMessageTextInput",
})

export const DeleteMessageInput = Schema.Struct({
  ...BotTargetFields,
  message_id: BotInputId,
}).annotate({
  identifier: "DeleteMessageInput",
})

export const SendReactionInput = Schema.Struct({
  ...BotTargetFields,
  message_id: BotInputId,
  emoji: Schema.String,
}).annotate({
  identifier: "SendReactionInput",
})

export const SetMyCommandsInput = Schema.Struct({
  commands: Schema.Array(BotCommand),
}).annotate({
  identifier: "SetMyCommandsInput",
})

export const BotEmptyResult = Schema.Struct({}).annotate({
  identifier: "BotEmptyResult",
})
export const BotGetChatResult = Schema.Struct({
  chat: BotChat,
}).annotate({
  identifier: "BotGetChatResult",
})
export const BotGetChatHistoryResult = Schema.Struct({
  messages: Schema.mutable(Schema.Array(BotMessage)),
}).annotate({
  identifier: "BotGetChatHistoryResult",
})
export const BotGetChatHistoryRuntimeResult = Schema.Struct({
  messages: Schema.mutable(
    Schema.Array(BotMessageCompatibility),
  ),
})
export const BotMessageResult = Schema.Struct({
  message: BotMessage,
}).annotate({
  identifier: "BotMessageResult",
})
export const BotMessageRuntimeResult = Schema.Struct({
  message: BotMessageCompatibility,
})
export const BotGetMyCommandsResult = Schema.Struct({
  commands: Schema.mutable(Schema.Array(BotCommand)),
}).annotate({
  identifier: "BotGetMyCommandsResult",
})

export const BotGetChatSuccess = botApiSuccess(
  BotGetChatResult,
).annotate({
  identifier: "BotGetChatSuccess",
})
export const BotGetChatHistorySuccess = botApiSuccess(
  BotGetChatHistoryResult,
).annotate({
  identifier: "BotGetChatHistorySuccess",
})
export const BotMessageSuccess = botApiSuccess(
  BotMessageResult,
).annotate({
  identifier: "BotMessageSuccess",
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
})
export const BotEmptySuccess = botApiSuccess(
  BotEmptyResult,
).annotate({
  identifier: "BotEmptySuccess",
})

export const botApiErrorAt = (status: number) =>
  BotApiError.pipe(HttpApiSchema.status(status))

export const botApiErrors = [
  botApiErrorAt(400),
  botApiErrorAt(401),
  botApiErrorAt(403),
  botApiErrorAt(404),
  botApiErrorAt(500),
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
