import {
  type DbChat,
  type DbMember,
  type DbSpace,
  type DbUser,
  type DbMessage,
  type DbDialog,
} from "@in/server/db/schema"
import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { Log } from "@in/server/utils/log"
import { Type, type TSchema, type StaticEncode } from "@sinclair/typebox"
import { Value } from "@sinclair/typebox/value"

// const BigIntString = Type.Transform(Type.BigInt())
//   .Decode((value) => String(value))
//   .Encode((value) => BigInt(value))

export const TimestampMs = Type.Transform(Type.Integer())
  .Decode((value: number) => new Date(value * 1000))
  .Encode((date: Date) => Math.floor(date.getTime() / 1000))

const Optional = <T extends TSchema>(schema: T) => Type.Union([Type.Null(), Type.Undefined(), schema])
export const TOptional = Optional

const encodeDate = (date: Date | number): number => {
  return typeof date === "number" ? date : Math.floor(date.getTime() / 1000)
}

//INTERNAL TYPES
type UserContext = {
  currentUserId: number
}

/// Space  -------------
export const TSpaceInfo = Type.Object({
  id: Type.Integer(),
  name: Type.String(),
  handle: Optional(Type.String()),
  date: TimestampMs,

  /** Is the current user the creator of the space */
  creator: Type.Boolean(),
})
export type TSpaceInfo = StaticEncode<typeof TSpaceInfo>
export const encodeSpaceInfo = (space: DbSpace, context: UserContext): TSpaceInfo => {
  return Value.Encode(TSpaceInfo, {
    ...space,
    creator: space.creatorId === context.currentUserId,
  })
}

/// User -------------
export const TUserInfo = Type.Object({
  id: Type.Integer(),
  firstName: Optional(Type.String()),
  lastName: Optional(Type.String()),
  username: Optional(Type.String()),
  email: Optional(Type.String()),
  online: Optional(Type.Boolean()),
  lastOnline: Optional(TimestampMs),
  date: TimestampMs,
})
export type TUserInfo = StaticEncode<typeof TUserInfo>
export const encodeUserInfo = (user: DbUser | TUserInfo): TUserInfo => {
  return Value.Encode(TUserInfo, {
    ...user,
    online: user.online,
  })
}

// Member -------------
export const TMemberInfo = Type.Object({
  id: Type.Integer(),
  userId: Type.Integer(),
  spaceId: Type.Integer(),
  role: Type.Union([Type.Literal("owner"), Type.Literal("admin"), Type.Literal("member")]),
  date: TimestampMs,
})
export type TMemberInfo = StaticEncode<typeof TMemberInfo>

export const encodeMemberInfo = (member: DbMember | TMemberInfo): TMemberInfo => {
  return Value.Encode(TMemberInfo, {
    ...member,
  })
}

export const TPeerInfo = Type.Union([
  Type.Object({ userId: Type.Integer() }),
  Type.Object({ threadId: Type.Integer() }),
])
export type TPeerInfo = StaticEncode<typeof TPeerInfo>

export const TInputPeerInfo = Type.Union([
  Type.Object({ userId: Type.Integer() }), // todo: use input id
  Type.Object({ threadId: Type.Integer() }),
])

// Chat -------------
export const TChatInfo = Type.Object({
  id: Type.Integer(),
  type: Type.Union([Type.Literal("private"), Type.Literal("thread")]),
  peer: TPeerInfo,
  lastMsgId: Optional(Type.Integer()),
  date: TimestampMs,

  // For space threads
  title: Optional(Type.String()),
  spaceId: Optional(Type.Integer()),
  publicThread: Optional(Type.Boolean()),
  threadNumber: Optional(Type.Integer()),
  // peerUserId: Optional(Type.Integer()),
  // Maybe if we count threads as channels in telegram, we need to have :
  // readInboxMaxId
  // readOutboxMaxId
  // pts?
})
export type TChatInfo = StaticEncode<typeof TChatInfo>
export const encodeChatInfo = (chat: DbChat, { currentUserId }: { currentUserId: number }): TChatInfo => {
  return Value.Encode(TChatInfo, {
    ...chat,
    peer: chat.spaceId
      ? { threadId: chat.id }
      : { userId: chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId },
  })
}

// PeerNotifySettings
export const TPeerNotifySettings = Type.Object({
  showPreviews: Optional(Type.Boolean()),
  silent: Optional(Type.Boolean()),
  // muteUntil: Optional(Type.Integer()),
})

// Dialog -------------
// Telegram Ref: https://core.telegram.org/constructor/dialog
export const TDialogInfo = Type.Object({
  peerId: TPeerInfo,
  pinned: Optional(Type.Boolean()),
  spaceId: Optional(Type.Integer()),
  unreadCount: Optional(Type.Integer()),
  readInboxMaxId: Optional(Type.Integer()),
  readOutboxMaxId: Optional(Type.Integer()),
  // lastMsgId: Optional(Type.Integer()),
  // unreadMentionsCount: Optional(Type.Integer()), // https://core.telegram.org/api/mentions
  // unreadReactionsCount: Optional(Type.Integer()),
  // pinnedMsgId: Optional(Type.Integer()),
  // peerNotifySettings: Optional(TPeerNotifySettings),
})
export type TDialogInfo = StaticEncode<typeof TDialogInfo>
export const encodeDialogInfo = (dialog: DbDialog): TDialogInfo => {
  return Value.Encode(TDialogInfo, {
    peerId: dialog.peerUserId ? { userId: dialog.peerUserId } : { threadId: dialog.chatId },
    pinned: dialog.pinned,
    spaceId: dialog.spaceId,
    unreadCount: 0,
    readInboxMaxId: dialog.readInboxMaxId,
    readOutboxMaxId: dialog.readOutboxMaxId,
  })
}

// Message -------------
export const TMessageInfo = Type.Object({
  id: Type.Integer(),
  peerId: TPeerInfo,
  chatId: Type.Integer(),
  fromId: Type.Integer(),
  text: Optional(Type.String()),
  date: TimestampMs,
  editDate: Optional(TimestampMs),
  // https://core.telegram.org/api/mentions
  mentioned: Optional(Type.Boolean()),
  out: Optional(Type.Boolean()),
  pinned: Optional(Type.Boolean()),
})

export type TMessageInfo = StaticEncode<typeof TMessageInfo>
export const encodeMessageInfo = (
  message: DbMessage,
  context: { currentUserId: number; peerId: StaticEncode<typeof TPeerInfo> },
): TMessageInfo => {
  // const errors = Value.Errors(TMessageInfo, {
  //   ...message,
  //   id: message.messageId,
  //   out: message.fromId === context.currentUserId,
  //   date: encodeDate(message.date),
  //   editDate: message.editDate ? encodeDate(message.editDate) : null,
  //   peerId: context.peerId,
  //   chatId: message.chatId,
  //   mentioned: false,
  //   pinned: false,
  // })
  // for (const error of errors) {
  //   Log.shared.error("Errors", error)
  // }

  // Decrypt text if it exists
  let text = message.text ? message.text : null
  if (message.textEncrypted && message.textIv && message.textTag) {
    const decryptedText = decryptMessage({
      encrypted: message.textEncrypted,
      iv: message.textIv,
      authTag: message.textTag,
    })
    text = decryptedText
  }

  return Value.Encode(
    TMessageInfo,
    Value.Clean(TMessageInfo, {
      ...message,
      text,
      id: message.messageId,
      out: message.fromId === context.currentUserId,
      peerId: context.peerId,
      mentioned: false,
      pinned: false,
    }),
  )
}

export const TComposeAction = Type.Union([Type.Literal("typing")])
export type TComposeAction = StaticEncode<typeof TComposeAction>

// # Updates
// To add updates, just add a new object to the union. With exactly one property: eg. "newMessage", "editedMessage", "deletedMessage" etc.
// then include any required fields in a object a the value of the property.
const UpdateBase = {
  // updateId: Type.Integer(),
} as const

export const TNewMessageUpdate = Type.Object({
  message: TMessageInfo,
})

export const TMessageEditedUpdate = Type.Object({
  message: TMessageInfo,
})

export const TUpdateMessageIdUpdate = Type.Object({
  messageId: Type.Integer(),
  randomId: Type.String(),
})
export type TUpdateMessageIdUpdate = StaticEncode<typeof TUpdateMessageIdUpdate>

export const TUpdateUserStatus = Type.Object({
  userId: Type.Integer(),
  online: Type.Boolean(),
  lastOnline: TimestampMs,
})
export type TUpdateUserStatus = StaticEncode<typeof TUpdateUserStatus>

export const TUpdateComposeAction = Type.Object({
  userId: Type.Integer(),
  peerId: TPeerInfo, // where user is typing
  action: TOptional(TComposeAction),
})
export type TUpdateComposeAction = StaticEncode<typeof TUpdateComposeAction>

//
export const TUpdate = Type.Union([
  // Updates
  Type.Object({
    newMessage: TNewMessageUpdate,
  }),
  Type.Object({
    editMessage: TMessageEditedUpdate,
  }),
  Type.Object({
    updateMessageId: TUpdateMessageIdUpdate,
  }),
  Type.Object({
    updateUserStatus: TUpdateUserStatus,
  }),
  Type.Object({
    updateComposeAction: TUpdateComposeAction,
  }),
])

export type TUpdateInfo = StaticEncode<typeof TUpdate>
