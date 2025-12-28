import type { Peer, Update } from "@in/protocol/core"
import type { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { DbQueryPlanType } from "../../database/types"
import { upsertChat, upsertDialog, upsertMessage, upsertUser } from "../transactions/mappers"

const toNumber = (value: bigint | number | undefined) => {
  if (value == null) return undefined
  return typeof value === "bigint" ? Number(value) : value
}

const getPeerChatId = (peer: Peer | undefined) => {
  if (!peer || peer.type.oneofKind !== "chat") return undefined
  return toNumber(peer.type.chat.chatId)
}

const getPeerUserId = (peer: Peer | undefined) => {
  if (!peer || peer.type.oneofKind !== "user") return undefined
  return toNumber(peer.type.user.userId)
}

const updateDialogForPeer = (db: Db, peer: Peer | undefined, changes: {
  unreadCount?: number
  unreadMark?: boolean
  readMaxId?: number
}) => {
  if (!peer || peer.type.oneofKind === undefined) return
  const dialogId = peer.type.oneofKind === "chat" ? getPeerChatId(peer) : getPeerUserId(peer)
  if (dialogId == null) return

  const ref = db.ref(DbObjectKind.Dialog, dialogId)
  const existing = db.get(ref)
  if (!existing) return

  db.update({
    ...existing,
    unreadCount: changes.unreadCount ?? existing.unreadCount,
    unreadMark: changes.unreadMark ?? existing.unreadMark,
    readMaxId: changes.readMaxId ?? existing.readMaxId,
  })
}

export const applyUpdates = (db: Db, updates: Update[]) => {
  db.batch(() => {
    for (const update of updates) {
      switch (update.update.oneofKind) {
      case "newMessage":
        if (update.update.newMessage.message) {
          upsertMessage(db, update.update.newMessage.message)
        }
        break

      case "editMessage":
        if (update.update.editMessage.message) {
          upsertMessage(db, update.update.editMessage.message)
        }
        break

      case "deleteMessages":
        for (const messageId of update.update.deleteMessages.messageIds) {
          const id = toNumber(messageId)
          if (id == null) continue
          db.delete(db.ref(DbObjectKind.Message, id))
        }
        break

      case "updateMessageId": {
        const messageId = toNumber(update.update.updateMessageId.messageId)
        if (messageId == null) break
        const randomId = update.update.updateMessageId.randomId

        const matches = db.queryCollection(
          DbQueryPlanType.Objects,
          DbObjectKind.Message,
          (message) => message.randomId === randomId,
        )

        const existing = matches[0]
        if (!existing || existing.id === messageId) break

        db.delete(db.ref(DbObjectKind.Message, existing.id))
        db.insert({
          ...existing,
          id: messageId,
          randomId: undefined,
        })
        break
      }

      case "newChat":
        if (update.update.newChat.chat) {
          upsertChat(db, update.update.newChat.chat)
        }
        if (update.update.newChat.user) {
          upsertUser(db, update.update.newChat.user)
        }
        // TODO: create or update dialog entries when server sends dialog payloads.
        break

      case "deleteChat": {
        const chatId = getPeerChatId(update.update.deleteChat.peerId)
        if (chatId == null) break
        db.delete(db.ref(DbObjectKind.Chat, chatId))
        db.delete(db.ref(DbObjectKind.Dialog, chatId))
        break
      }

      case "updateReadMaxId":
        updateDialogForPeer(db, update.update.updateReadMaxId.peerId, {
          readMaxId: toNumber(update.update.updateReadMaxId.readMaxId),
          unreadCount: update.update.updateReadMaxId.unreadCount,
        })
        break

      case "markAsUnread":
        updateDialogForPeer(db, update.update.markAsUnread.peerId, {
          unreadMark: update.update.markAsUnread.unreadMark,
        })
        break

      case "participantAdd":
      case "participantDelete":
      case "messageAttachment":
      case "updateReaction":
      case "deleteReaction":
      case "spaceMemberDelete":
      case "spaceMemberAdd":
      case "joinSpace":
      case "updateComposeAction":
      case "updateUserStatus":
      case "updateUserSettings":
      case "newMessageNotification":
      case "chatSkipPts":
      case "chatHasNewUpdates":
      case "spaceHasNewUpdates":
      case "spaceMemberUpdate":
        // TODO: apply these update kinds to local caches.
        break

        default:
          break
      }
    }
  })
}
