import {
  type DbChat,
  type DbMember,
  type DbSpace,
  type DbUser,
  type DbMessage,
  type DbDialog,
  type DbFile,
  type DbUserWithPhoto,
} from "@in/server/db/schema"
import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { Log } from "@in/server/utils/log"
import { Type, type TSchema, type StaticEncode } from "@sinclair/typebox"
import { Value } from "@sinclair/typebox/value"
import type { DbReaction } from "../db/schema/reactions"
import { InlineError } from "@in/server/types/errors"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { getSignedUrl } from "@in/server/modules/files/path"

// const BigIntString = Type.Transform(Type.BigInt())
//   .Decode((value) => String(value))
//   .Encode((value) => BigInt(value))

export const TimestampMs = Type.Transform(Type.Integer())
  .Decode((value: number) => new Date(value * 1000))
  .Encode((date: Date) => Math.floor(date.getTime() / 1000))

export const Optional = <T extends TSchema>(schema: T) =>
  Type.Optional(Type.Union([Type.Null(), Type.Undefined(), schema]))
export const TOptional = Optional

const encodeDate = (date: Date | number): number => {
  return typeof date === "number" ? date : Math.floor(date.getTime() / 1000)
}

//INTERNAL TYPES
type UserContext = {
  currentUserId: number
}

// Photo -------------
export const PhotoInfo = Type.Object({
  fileUniqueId: Type.String(),
  width: Type.Number(),
  height: Type.Number(),
  fileSize: Type.Number(),
  mimeType: Type.String(),
  thumbSize: Optional(Type.Union([Type.Literal("i"), Type.Literal("s"), Type.Literal("m"), Type.Literal("h")])),
  bytes: Optional(Type.String()),

  // thumb size?
  // access hash?
  // path?

  temporaryUrl: Optional(Type.String()),
})

export type PhotoInfo = StaticEncode<typeof PhotoInfo>
export const encodePhotoInfo = (file: DbFile): PhotoInfo => {
  if (file.fileType !== "photo") {
    Log.shared.error("File is not a photo given to encodePhotoInfo")
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }

  const path =
    file.pathEncrypted && file.pathIv && file.pathTag
      ? decrypt({ encrypted: file.pathEncrypted, iv: file.pathIv, authTag: file.pathTag })
      : null

  const url = path ? getSignedUrl(path) : null

  return Value.Encode(PhotoInfo, {
    fileUniqueId: file.fileUniqueId,
    width: file.width,
    height: file.height,
    fileSize: file.fileSize,
    mimeType: file.mimeType,
    temporaryUrl: url,
    thumbSize: null,
  } as PhotoInfo)
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
export const TMinUserInfo = Type.Object({
  id: Type.Integer(),
  firstName: Optional(Type.String()),
  lastName: Optional(Type.String()),
  username: Optional(Type.String()),
  online: Optional(Type.Boolean()),
  lastOnline: Optional(TimestampMs),
  pendingSetup: Optional(Type.Boolean()),
  date: TimestampMs,
  photo: Optional(Type.Array(PhotoInfo)),
})
export type TMinUserInfo = StaticEncode<typeof TMinUserInfo>
export const TUserInfo = Type.Object({
  id: Type.Integer(),
  firstName: Optional(Type.String()),
  lastName: Optional(Type.String()),
  username: Optional(Type.String()),
  email: Optional(Type.String()),
  phoneNumber: Optional(Type.String()),
  pendingSetup: Optional(Type.Boolean()),
  online: Optional(Type.Boolean()),
  lastOnline: Optional(TimestampMs),
  timeZone: Optional(Type.String()),
  date: TimestampMs,
  photo: Optional(Type.Array(PhotoInfo)),
})
export type TUserInfo = StaticEncode<typeof TUserInfo>
export const encodeUserInfo = (user: DbUser | TUserInfo, context?: { photoFile?: DbFile | undefined }): TUserInfo => {
  let photo: [PhotoInfo] | undefined = undefined
  if (context?.photoFile && context.photoFile.fileType === "photo") {
    photo = [encodePhotoInfo(context.photoFile)]
  }

  return Value.Encode(TUserInfo, {
    ...user,
    photo,
  })
}

export const encodeFullUserInfo = (user: DbUserWithPhoto): TUserInfo => {
  let photo: PhotoInfo[] | undefined
  if (user.photo && user.photo.fileType === "photo") {
    photo = [encodePhotoInfo(user.photo)]
  }

  user.photo?.thumbs?.forEach((thumb) => {
    photo?.push(encodePhotoInfo(thumb))
  })

  return Value.Encode(TUserInfo, {
    ...user,
    photo,
  })
}

// No email or phone number, just public info. used in search results
export const encodeMinUserInfo = (
  user: DbUser | TUserInfo,
  context?: { photoFile?: DbFile | undefined },
): TMinUserInfo => {
  let photo: [PhotoInfo] | undefined = undefined
  if (context?.photoFile && context.photoFile.fileType === "photo") {
    photo = [encodePhotoInfo(context.photoFile)]
  }

  return Value.Encode(TMinUserInfo, {
    id: user.id,
    firstName: user.firstName,
    lastName: user.lastName,
    username: user.username,
    online: user.online,
    lastOnline: user.lastOnline,
    date: user.date,
    photo,
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
  emoji: Optional(Type.String()),
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
  chatId: Optional(Type.Integer()),
  pinned: Optional(Type.Boolean()),
  spaceId: Optional(Type.Integer()),
  unreadCount: Optional(Type.Integer()),
  readInboxMaxId: Optional(Type.Integer()),
  draft: Optional(Type.String()),
  archived: Optional(Type.Boolean()),
  // lastMsgId: Optional(Type.Integer()),
  // unreadMentionsCount: Optional(Type.Integer()), // https://core.telegram.org/api/mentions
  // unreadReactionsCount: Optional(Type.Integer()),
  // pinnedMsgId: Optional(Type.Integer()),
  // peerNotifySettings: Optional(TPeerNotifySettings),
})
export type TDialogInfo = StaticEncode<typeof TDialogInfo>
export const encodeDialogInfo = (dialog: DbDialog & { unreadCount: number }): TDialogInfo => {
  return Value.Encode(TDialogInfo, {
    peerId: dialog.peerUserId ? { userId: dialog.peerUserId } : { threadId: dialog.chatId },
    chatId: dialog.chatId,
    pinned: dialog.pinned,
    spaceId: dialog.spaceId,
    readInboxMaxId: dialog.readInboxMaxId,
    draft: dialog.draft,
    archived: dialog.archived,
    unreadCount: dialog.unreadCount,
  })
}

// Reaction -------------
export const TReactionInfo = Type.Object({
  id: Type.Integer(),
  messageId: Type.Integer(),
  chatId: Type.Integer(),
  userId: Type.Integer(),
  emoji: Type.String(),
  date: TimestampMs,
})

export type TReactionInfo = StaticEncode<typeof TReactionInfo>
export const encodeReactionInfo = (reaction: DbReaction): TReactionInfo => {
  return Value.Encode(TReactionInfo, {
    ...reaction,
  })
}

// Message -------------
export const TMessageInfo = Type.Object({
  id: Type.Integer(),
  randomId: Optional(Type.String()),
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
  replyToMsgId: Optional(Type.Integer()),
  // reactionIds: Optional(Type.Array(Type.Integer())),
  photo: Optional(Type.Array(PhotoInfo)),
  isSticker: Optional(Type.Boolean()),
})

export type TMessageInfo = StaticEncode<typeof TMessageInfo>
export const encodeMessageInfo = (
  message: DbMessage,
  context: { currentUserId: number; peerId: StaticEncode<typeof TPeerInfo>; files: DbFile[] | null },
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

  let photo: PhotoInfo | undefined = undefined
  if (message.fileId) {
    const ogPhotoFile = context.files?.find((file) => file.fileType === "photo")

    if (ogPhotoFile) {
      photo = encodePhotoInfo(ogPhotoFile) ?? undefined
    }
  }

  let out = message.fromId === context.currentUserId
  return Value.Encode(
    TMessageInfo,
    Value.Clean(TMessageInfo, {
      ...message,
      text,
      id: message.messageId,
      randomId: out && message.randomId ? message.randomId.toString() : undefined,
      out: out,
      peerId: context.peerId,
      mentioned: false,
      pinned: false,
      photo: photo ? [photo] : undefined,
    }),
  )
}

export const TComposeAction = Type.Union([
  Type.Literal("typing"),
  Type.Literal("uploadingDocument"),
  Type.Literal("uploadingPhoto"),
  Type.Literal("uploadingVideo"),
])
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

export const TDeleteMessageUpdate = Type.Object({
  messageId: Type.Integer(),
  peerId: TPeerInfo,
})
export type TDeleteMessageUpdate = StaticEncode<typeof TDeleteMessageUpdate>

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
  Type.Object({
    deleteMessage: TDeleteMessageUpdate,
  }),
])

export type TUpdateInfo = StaticEncode<typeof TUpdate>
