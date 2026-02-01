import type { Chat, Dialog, Message, Peer, User } from "@in/protocol/core"
import type { Db } from "../../database"
import {
  DbObjectKind,
  type Chat as DbChat,
  type Dialog as DbDialog,
  type Message as DbMessage,
  type User as DbUser,
} from "../../database/models"

const toNumber = (value: bigint | number | undefined) => {
  if (value == null) return undefined
  return typeof value === "bigint" ? Number(value) : value
}

const getPeerUserId = (peer?: Peer) => {
  if (!peer) return undefined
  if (peer.type.oneofKind === "user") {
    return toNumber(peer.type.user.userId)
  }
  return undefined
}

const getPeerChatId = (peer?: Peer) => {
  if (!peer) return undefined
  if (peer.type.oneofKind === "chat") {
    return toNumber(peer.type.chat.chatId)
  }
  return undefined
}

const upsert = <K extends DbObjectKind, O extends DbUser | DbDialog | DbChat | DbMessage>(db: Db, object: O) => {
  const ref = db.ref(object.kind as K, object.id)
  const existing = db.get(ref)
  if (existing) {
    db.update(object)
  } else {
    db.insert(object)
  }
}

export const upsertUser = (db: Db, user: User) => {
  const id = toNumber(user.id)
  if (id == null) return
  const model: DbUser = {
    kind: DbObjectKind.User,
    id,
    firstName: user.firstName ?? undefined,
    lastName: user.lastName ?? undefined,
    username: user.username ?? undefined,
    email: user.email ?? undefined,
    min: user.min ?? undefined,
    profilePhoto: user.profilePhoto
      ? {
          photoId: toNumber(user.profilePhoto.photoId),
          fileUniqueId: user.profilePhoto.fileUniqueId ?? undefined,
          cdnUrl: user.profilePhoto.cdnUrl ?? undefined,
        }
      : undefined,
  }
  upsert(db, model)
}

export const upsertChat = (db: Db, chat: Chat) => {
  const id = toNumber(chat.id)
  if (id == null) return
  const ref = db.ref(DbObjectKind.Chat, id)
  const existing = db.get(ref) as DbChat | undefined
  const model: DbChat = {
    kind: DbObjectKind.Chat,
    id,
    title: chat.title ?? undefined,
    spaceId: toNumber(chat.spaceId),
    emoji: chat.emoji ?? undefined,
    isPublic: chat.isPublic ?? undefined,
    lastMsgId: toNumber(chat.lastMsgId),
    pinnedMessageIds: existing?.pinnedMessageIds,
  }
  if (existing) {
    db.update(model)
  } else {
    db.insert(model)
  }
}

const getDialogId = (props: { peerUserId: number } | { peerThreadId: number }) => {
  if ("peerUserId" in props) {
    return props.peerUserId
  }
  if ("peerThreadId" in props) {
    return props.peerThreadId * -1
  }
}

export const upsertDialog = (db: Db, dialog: Dialog) => {
  const chatId = toNumber(dialog.chatId) ?? getPeerChatId(dialog.peer)
  if (chatId == null) return
  const peerUserId = getPeerUserId(dialog.peer)
  const id = peerUserId ? getDialogId({ peerUserId }) : getDialogId({ peerThreadId: chatId })
  if (id == null) return

  const model: DbDialog = {
    kind: DbObjectKind.Dialog,
    id,
    chatId: chatId,
    peerUserId,
    spaceId: toNumber(dialog.spaceId),
    archived: dialog.archived ?? undefined,
    pinned: dialog.pinned ?? undefined,
    readMaxId: toNumber(dialog.readMaxId),
    unreadCount: dialog.unreadCount ?? undefined,
    unreadMark: dialog.unreadMark ?? undefined,
  }
  upsert(db, model)
}

export const upsertMessage = (db: Db, message: Message) => {
  const id = toNumber(message.id)
  if (id == null) return
  // TODO: use a synthetic message ID so it doesn't change when randomId / ID is updated
  const model: DbMessage = {
    kind: DbObjectKind.Message,
    id,
    fromId: toNumber(message.fromId) ?? 0,
    peerUserId: getPeerUserId(message.peerId),
    chatId: toNumber(message.chatId) ?? 0,
    message: message.message ?? undefined,
    out: message.out,
    date: toNumber(message.date),
    mentioned: message.mentioned ?? undefined,
    replyToMsgId: toNumber(message.replyToMsgId),
    editDate: toNumber(message.editDate),
    isSticker: message.isSticker ?? undefined,
  }
  upsert(db, model)
}
