import { Schema } from "effect"
import { UnixSeconds, WirePositiveInteger, WireSafeInteger } from "../core/schema/scalars"
import { UserInfo, UserPhoto } from "../modules/auth/identitySchemas.effect"
import {
  ChatInfo,
  DialogInfo,
  MinUserInfo,
  PeerInfo,
  V1InputId,
} from "./v1IdentitySpacesSchemas.effect"

const NullableOptionalString = Schema.optionalKey(Schema.NullOr(Schema.String))
const NullableOptionalBoolean = Schema.optionalKey(Schema.NullOr(Schema.Boolean))
const NullableOptionalInteger = Schema.optionalKey(Schema.NullOr(WireSafeInteger))

export const V1InputPeerInfo = Schema.Union([
  Schema.Struct({ userId: WireSafeInteger }),
  Schema.Struct({ threadId: WireSafeInteger }),
]).annotate({
  identifier: "V1InputPeerInfo",
})
export type V1InputPeerInfo = typeof V1InputPeerInfo.Type

export const ReactionInfo = Schema.Struct({
  id: WirePositiveInteger,
  messageId: WirePositiveInteger,
  chatId: WirePositiveInteger,
  userId: WirePositiveInteger,
  emoji: Schema.String,
  date: UnixSeconds,
}).annotate({
  identifier: "ReactionInfo",
})

export const MessageInfo = Schema.Struct({
  id: WirePositiveInteger,
  randomId: NullableOptionalString,
  peerId: PeerInfo,
  chatId: WirePositiveInteger,
  fromId: WirePositiveInteger,
  text: NullableOptionalString,
  date: UnixSeconds,
  editDate: NullableOptionalInteger,
  mentioned: NullableOptionalBoolean,
  out: NullableOptionalBoolean,
  pinned: NullableOptionalBoolean,
  replyToMsgId: NullableOptionalInteger,
  photo: Schema.optionalKey(Schema.NullOr(Schema.Array(UserPhoto))),
  isSticker: NullableOptionalBoolean,
}).annotate({
  identifier: "MessageInfo",
})

const UpdateMessage = Schema.Struct({ message: MessageInfo })
const UpdateMessageId = Schema.Struct({
  messageId: WirePositiveInteger,
  randomId: Schema.String,
})
const UpdateUserStatus = Schema.Struct({
  userId: WirePositiveInteger,
  online: Schema.Boolean,
  lastOnline: UnixSeconds,
})
const ComposeAction = Schema.Literals([
  "typing",
  "uploadingDocument",
  "uploadingPhoto",
  "uploadingVideo",
  "recordingVoice",
])
const UpdateComposeAction = Schema.Struct({
  userId: WirePositiveInteger,
  peerId: PeerInfo,
  action: Schema.optionalKey(Schema.NullOr(ComposeAction)),
})
const DeleteMessageUpdate = Schema.Struct({
  messageId: WirePositiveInteger,
  peerId: PeerInfo,
})

export const V1Update = Schema.Union([
  Schema.Struct({ newMessage: UpdateMessage }),
  Schema.Struct({ editMessage: UpdateMessage }),
  Schema.Struct({ updateMessageId: UpdateMessageId }),
  Schema.Struct({ updateUserStatus: UpdateUserStatus }),
  Schema.Struct({ updateComposeAction: UpdateComposeAction }),
  Schema.Struct({ deleteMessage: DeleteMessageUpdate }),
]).annotate({
  identifier: "V1Update",
})

const NullablePeerInputFields = {
  peerId: Schema.optionalKey(Schema.NullOr(V1InputPeerInfo)),
  peerUserId: Schema.optionalKey(Schema.NullOr(V1InputId)),
  peerThreadId: Schema.optionalKey(Schema.NullOr(V1InputId)),
} as const
const PeerInputFields = {
  peerId: Schema.optionalKey(V1InputPeerInfo),
  peerUserId: Schema.optionalKey(V1InputId),
  peerThreadId: Schema.optionalKey(V1InputId),
} as const

export const AddReactionInput = Schema.Struct({
  messageId: V1InputId,
  chatId: V1InputId,
  emoji: Schema.String,
}).annotate({ identifier: "AddReactionInput" })
export type AddReactionInput = typeof AddReactionInput.Type
export const AddReactionResult = Schema.Struct({
  reaction: ReactionInfo,
}).annotate({ identifier: "AddReactionResult" })
export type AddReactionResult = typeof AddReactionResult.Type

export const CreatePrivateChatInput = Schema.Struct({
  // FIXME(effect-cutover): require a peer access hash once supported clients can supply it, preventing unsolicited chat creation.
  userId: Schema.String,
}).annotate({ identifier: "CreatePrivateChatInput" })
export type CreatePrivateChatInput = typeof CreatePrivateChatInput.Type
export const CreatePrivateChatResult = Schema.Struct({
  chat: ChatInfo,
  dialog: DialogInfo,
  // TODO(effect-cutover): remove the deprecated `user` field after client telemetry proves no supported client reads it.
  user: MinUserInfo,
}).annotate({ identifier: "CreatePrivateChatResult" })
export type CreatePrivateChatResult = typeof CreatePrivateChatResult.Type

export const CreateThreadInput = Schema.Struct({
  title: Schema.String,
  spaceId: V1InputId,
  emoji: Schema.optionalKey(Schema.String),
}).annotate({ identifier: "CreateThreadInput" })
export type CreateThreadInput = typeof CreateThreadInput.Type
export const CreateThreadResult = Schema.Struct({
  chat: ChatInfo,
}).annotate({ identifier: "CreateThreadResult" })
export type CreateThreadResult = typeof CreateThreadResult.Type

export const DeleteMessageInput = Schema.Struct({
  messageId: V1InputId,
  chatId: V1InputId,
  peerUserId: Schema.optionalKey(V1InputId),
  peerThreadId: Schema.optionalKey(V1InputId),
}).annotate({ identifier: "DeleteMessageInput" })
export type DeleteMessageInput = typeof DeleteMessageInput.Type

export const GetAlphaTextInput = Schema.Struct({}).annotate({ identifier: "GetAlphaTextInput" })
export type GetAlphaTextInput = typeof GetAlphaTextInput.Type
export const GetAlphaTextResult = Schema.String.annotate({ identifier: "GetAlphaTextResult" })
export type GetAlphaTextResult = typeof GetAlphaTextResult.Type

export const GetChatHistoryInput = Schema.Struct({
  ...PeerInputFields,
  limit: Schema.optionalKey(WireSafeInteger),
}).annotate({ identifier: "GetChatHistoryInput" })
export type GetChatHistoryInput = typeof GetChatHistoryInput.Type
export const GetChatHistoryResult = Schema.Struct({
  messages: Schema.Array(MessageInfo),
}).annotate({ identifier: "GetChatHistoryResult" })
export type GetChatHistoryResult = typeof GetChatHistoryResult.Type

export const GetDialogsInput = Schema.Struct({
  spaceId: V1InputId,
}).annotate({ identifier: "GetDialogsInput" })
export type GetDialogsInput = typeof GetDialogsInput.Type
export const GetDialogsResult = Schema.Struct({
  dialogs: Schema.Array(DialogInfo),
  chats: Schema.Array(ChatInfo),
  messages: Schema.Array(MessageInfo),
  users: Schema.Array(UserInfo),
}).annotate({ identifier: "GetDialogsResult" })
export type GetDialogsResult = typeof GetDialogsResult.Type

export const GetDraftInput = Schema.Struct({
  peerUserId: Schema.optionalKey(V1InputId),
}).annotate({ identifier: "GetDraftInput" })
export type GetDraftInput = typeof GetDraftInput.Type
export const GetDraftResult = Schema.Struct({
  draft: Schema.String,
}).annotate({ identifier: "GetDraftResult" })
export type GetDraftResult = typeof GetDraftResult.Type

export const GetPrivateChatsInput = Schema.Struct({}).annotate({ identifier: "GetPrivateChatsInput" })
export type GetPrivateChatsInput = typeof GetPrivateChatsInput.Type
export const GetPrivateChatsResult = Schema.Struct({
  messages: Schema.Array(MessageInfo),
  chats: Schema.Array(ChatInfo),
  dialogs: Schema.Array(DialogInfo),
  peerUsers: Schema.Array(UserInfo),
}).annotate({ identifier: "GetPrivateChatsResult" })
export type GetPrivateChatsResult = typeof GetPrivateChatsResult.Type

export const ReadMessagesInput = Schema.Struct({
  peerUserId: Schema.optionalKey(V1InputId),
  peerThreadId: Schema.optionalKey(V1InputId),
  maxId: Schema.optionalKey(WireSafeInteger),
}).annotate({ identifier: "ReadMessagesInput" })
export type ReadMessagesInput = typeof ReadMessagesInput.Type
export const ReadMessagesResult = Schema.Struct({}).annotate({ identifier: "ReadMessagesResult" })
export type ReadMessagesResult = typeof ReadMessagesResult.Type

export const SendComposeActionInput = Schema.Struct({
  action: Schema.optionalKey(Schema.NullOr(ComposeAction)),
  ...NullablePeerInputFields,
}).annotate({ identifier: "SendComposeActionInput" })
export type SendComposeActionInput = typeof SendComposeActionInput.Type

export const SendMessageInput = Schema.Struct({
  ...NullablePeerInputFields,
  text: Schema.optionalKey(Schema.NullOr(Schema.String)),
  replyToMessageId: Schema.optionalKey(Schema.NullOr(V1InputId)),
  randomId: Schema.optionalKey(Schema.NullOr(Schema.String)),
  fileUniqueId: Schema.optionalKey(Schema.NullOr(Schema.String)),
  isSticker: Schema.optionalKey(Schema.NullOr(Schema.Boolean)),
  parseMarkdown: Schema.optionalKey(Schema.NullOr(Schema.Boolean)),
}).annotate({ identifier: "SendMessageInput" })
export type SendMessageInput = typeof SendMessageInput.Type
export const SendMessageResult = Schema.Struct({
  message: MessageInfo,
  updates: Schema.Array(V1Update),
}).annotate({ identifier: "SendMessageResult" })
export type SendMessageResult = typeof SendMessageResult.Type

// TODO(effect-cutover): remove the dated compatibility method after supported clients use the canonical sendMessage contract.
export const SendMessage20250509Input = Schema.Struct({
  ...NullablePeerInputFields,
  text: Schema.optionalKey(Schema.NullOr(Schema.String)),
  photoId: Schema.optionalKey(Schema.NullOr(V1InputId)),
}).annotate({ identifier: "SendMessage20250509Input" })
export type SendMessage20250509Input = typeof SendMessage20250509Input.Type
export const SendMessage20250509Result = Schema.Struct({}).annotate({
  identifier: "SendMessage20250509Result",
})
export type SendMessage20250509Result = typeof SendMessage20250509Result.Type

const DialogOrder = Schema.String.check(
  Schema.isMinLength(1),
  Schema.isMaxLength(128),
  Schema.isPattern(/^[0-9A-Za-z]+$/),
)

export const UpdateDialogInput = Schema.Struct({
  pinned: Schema.optionalKey(Schema.Boolean),
  peerId: Schema.optionalKey(V1InputId),
  peerUserId: Schema.optionalKey(V1InputId),
  peerThreadId: Schema.optionalKey(V1InputId),
  draft: Schema.optionalKey(Schema.String),
  archived: Schema.optionalKey(Schema.Boolean),
  order: Schema.optionalKey(DialogOrder),
  pinnedOrder: Schema.optionalKey(DialogOrder),
}).annotate({ identifier: "UpdateDialogInput" })
export type UpdateDialogInput = typeof UpdateDialogInput.Type
export const UpdateDialogResult = Schema.Struct({
  dialog: DialogInfo,
}).annotate({ identifier: "UpdateDialogResult" })
export type UpdateDialogResult = typeof UpdateDialogResult.Type

export const V1MessagingEmptyResult = Schema.Undefined
