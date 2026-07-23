import type { Chat, Dialog, Message, Peer, Space, User } from "@inline-chat/protocol/core"
import {
  chatId,
  compareInlineIds,
  dialogId,
  messageId,
  photoId,
  spaceId,
  userId,
  type ChatID,
  type DialogID,
  type InlineIDInput,
  type UserID,
} from "@inline/ids"
import type { Db } from "../../database"
import {
  DbObjectKind,
  messageKey,
  type Chat as DbChat,
  type Dialog as DbDialog,
  type Message as DbMessage,
  MessageSendingStatus,
  type Space as DbSpace,
  type User as DbUser,
} from "../../database/models"
import { replayDeferredMessageUpdates } from "../updates/deferred-message-updates"

const toSafeNumber = (value: bigint | number | undefined) => {
  if (value == null) return undefined
  const number = typeof value === "bigint" ? Number(value) : value
  if (!Number.isSafeInteger(number)) {
    throw new RangeError(`Unsafe Inline numeric field: ${String(value)}`)
  }
  return number
}

const toId = <T>(
  value: bigint | number | undefined,
  convert: (input: InlineIDInput) => T,
) => (value == null ? undefined : convert(value))

const getPeerUserId = (peer?: Peer) => {
  if (!peer) return undefined
  if (peer.type.oneofKind === "user") {
    return userId(peer.type.user.userId)
  }
  return undefined
}

const getPeerChatId = (peer?: Peer) => {
  if (!peer) return undefined
  if (peer.type.oneofKind === "chat") {
    return chatId(peer.type.chat.chatId)
  }
  return undefined
}

const upsert = <K extends DbObjectKind, O extends DbUser | DbDialog | DbChat | DbMessage | DbSpace>(
  db: Db,
  object: O,
) => {
  const ref = db.ref(object.kind as K, object.id)
  const existing = db.get(ref)
  if (existing) {
    db.update(object)
  } else {
    db.insert(object)
  }
}

export const upsertUser = (db: Db, user: User) => {
  const id = userId(user.id)
  const model: DbUser = {
    kind: DbObjectKind.User,
    id,
    firstName: user.firstName ?? undefined,
    lastName: user.lastName ?? undefined,
    username: user.username ?? undefined,
    email: user.email ?? undefined,
    min: user.min ?? undefined,
    pendingSetup: user.pendingSetup ?? undefined,
    bot: user.bot ?? undefined,
    profilePhoto: user.profilePhoto
      ? {
          photoId: toId(user.profilePhoto.photoId, photoId),
          fileUniqueId: user.profilePhoto.fileUniqueId ?? undefined,
          cdnUrl: user.profilePhoto.cdnUrl ?? undefined,
          strippedThumb:
            user.profilePhoto.strippedThumb ?? undefined,
        }
      : undefined,
  }
  upsert(db, model)
}

export const upsertChat = (db: Db, chat: Chat) => {
  const id = chatId(chat.id)
  const ref = db.ref(DbObjectKind.Chat, id)
  const existing = db.get(ref) as DbChat | undefined
  const model: DbChat = {
    kind: DbObjectKind.Chat,
    id,
    title: chat.title ?? undefined,
    spaceId: toId(chat.spaceId, spaceId),
    description: chat.description ?? undefined,
    emoji: chat.emoji ?? undefined,
    isPublic: chat.isPublic ?? undefined,
    lastMsgId: toId(chat.lastMsgId, messageId),
    date: toSafeNumber(chat.date),
    createdBy: toId(chat.createdBy, userId),
    peerUserId: getPeerUserId(chat.peerId),
    parentChatId: toId(chat.parentChatId, chatId),
    parentMessageId: toId(chat.parentMessageId, messageId),
    untitled: chat.untitled ?? undefined,
    number: chat.number ?? undefined,
    canUpdateInfo: chat.permissions?.canUpdateInfo,
    pinnedMessageIds: existing?.pinnedMessageIds,
  }
  if (existing) {
    db.update(model)
  } else {
    db.insert(model)
  }
}

export const getDialogId = (
  props: { peerUserId: UserID } | { peerThreadId: ChatID },
): DialogID => {
  if ("peerUserId" in props) {
    return dialogId(props.peerUserId)
  }
  const peerThreadId = BigInt(props.peerThreadId)
  return dialogId(peerThreadId < 500n ? peerThreadId : -peerThreadId)
}

export const upsertDialog = (db: Db, dialog: Dialog) => {
  const exactChatId =
    toId(dialog.chatId, chatId) ?? getPeerChatId(dialog.peer)
  if (exactChatId == null) return
  const peerUserId = getPeerUserId(dialog.peer)
  const peerThreadId = getPeerChatId(dialog.peer)
  const id =
    peerUserId != null
      ? getDialogId({ peerUserId })
      : getDialogId({ peerThreadId: peerThreadId ?? exactChatId })
  const existing = db.get(db.ref(DbObjectKind.Dialog, id))
  const open = dialog.open !== undefined ? dialog.open : existing?.open
  const chatListHidden =
    dialog.chatListHidden !== undefined
      ? dialog.chatListHidden
      : dialog.sidebarVisible !== undefined
        ? !dialog.sidebarVisible
        : existing?.chatListHidden

  const model: DbDialog = {
    kind: DbObjectKind.Dialog,
    id,
    chatId: exactChatId,
    peerUserId,
    peerThreadId,
    spaceId: toId(dialog.spaceId, spaceId),
    archived: dialog.archived ?? undefined,
    pinned: dialog.pinned ?? undefined,
    readMaxId: toId(dialog.readMaxId, messageId),
    unreadCount: dialog.unreadCount ?? undefined,
    unreadMark: dialog.unreadMark ?? undefined,
    open,
    order:
      dialog.open === false
        ? undefined
        : dialog.order ?? existing?.order,
    pinnedOrder: dialog.pinnedOrder ?? existing?.pinnedOrder,
    chatListHidden,
    followMode: dialog.followMode ?? existing?.followMode,
  }
  if (existing) {
    db.replace(model)
  } else {
    db.insert(model)
  }
}

export const upsertSpace = (db: Db, space: Space) => {
  const id = spaceId(space.id)
  const date = toSafeNumber(space.date)
  if (date == null) return

  upsert(db, {
    kind: DbObjectKind.Space,
    id,
    name: space.name,
    creator: space.creator,
    date,
    isPublic: space.isPublic,
  })
}

export const messageModel = (message: Message): DbMessage => {
  const exactMessageId = messageId(message.id)
  const exactChatId = chatId(message.chatId)
  return {
    kind: DbObjectKind.Message,
    id: messageKey(exactChatId, exactMessageId),
    messageId: exactMessageId,
    fromId: userId(message.fromId),
    peerUserId: getPeerUserId(message.peerId),
    chatId: exactChatId,
    message: message.message ?? undefined,
    out: message.out,
    date: toSafeNumber(message.date),
    mentioned: message.mentioned ?? undefined,
    replyToMsgId: toId(message.replyToMsgId, messageId),
    groupedId: message.groupedId,
    editDate: toSafeNumber(message.editDate),
    isSticker: message.isSticker ?? undefined,
    hasLink: message.hasLink ?? undefined,
    rev: message.rev,
    media: message.media,
    attachments: message.attachments,
    reactions: message.reactions,
    entities: message.entities,
    sendMode: message.sendMode,
    fwdFrom: message.fwdFrom,
    replies: message.replies,
    actions: message.actions,
    serviceMessage: message.serviceMessage,
    status: message.out ? MessageSendingStatus.Sent : undefined,
  }
}

export const upsertMessage = (db: Db, message: Message) => {
  const model = messageModel(message)
  const existing = db.get(
    db.ref(DbObjectKind.Message, model.id),
  )
  if (existing?.reactionIntents?.length) {
    model.reactionIntents = existing.reactionIntents
  }
  upsert(db, model)
  replayDeferredMessageUpdates(db, model.id)

  const chatRef = db.ref(DbObjectKind.Chat, model.chatId)
  const chat = db.get(chatRef)
  if (
    chat &&
    (chat.lastMsgId == null ||
      compareInlineIds(model.messageId, chat.lastMsgId) >= 0)
  ) {
    db.update({
      ...chat,
      lastMsgId: model.messageId,
      date: model.date ?? chat.date,
    })
  }
}
