import {
  Update,
  UserGroup,
  type Peer,
  type UpdateSidecars,
} from "@inline-chat/protocol/core"
import {
  chatId as makeChatId,
  compareInlineIds,
  messageId as makeMessageId,
  spaceId as makeSpaceId,
  userId as makeUserId,
  type MessageID,
} from "@inline/ids"
import type { Db } from "../../database"
import { DbObjectKind, messageKey, MessageSendingStatus } from "../../database/models"
import { DbQueryPlanType } from "../../database/types"
import { updateBucketKey } from "../sync/update-bucket-key"
import { syncBucketId } from "../sync/sync-types"
import {
  getDialogId,
  upsertChat,
  upsertDialog,
  upsertMessage,
  upsertSpace,
  upsertUser,
} from "../transactions/mappers"
import {
  reactionUpdateTargetKey,
  applyResidentReactionUpdate,
} from "./message-reaction-update"
import { replayDeferredMessageUpdates } from "./deferred-message-updates"
import {
  applyResidentMessageAttachmentUpdate,
  messageAttachmentUpdateTargetKey,
} from "./message-attachment-update"

const getPeerChatId = (peer: Peer | undefined) => {
  if (!peer || peer.type.oneofKind !== "chat") return undefined
  return makeChatId(peer.type.chat.chatId)
}

const getPeerUserId = (peer: Peer | undefined) => {
  if (!peer || peer.type.oneofKind !== "user") return undefined
  return makeUserId(peer.type.user.userId)
}

const getChatIdForPeer = (db: Db, peer: Peer | undefined) => {
  const chatId = getPeerChatId(peer)
  if (chatId != null) return chatId

  const peerUserId = getPeerUserId(peer)
  if (peerUserId == null) return undefined

  const matches = db.queryCollection(
    DbQueryPlanType.Objects,
    DbObjectKind.Dialog,
    (dialog) => dialog.peerUserId === peerUserId,
  )
  return matches[0]?.chatId
}

const updateDialogForPeer = (
  db: Db,
  peer: Peer | undefined,
  changes: {
    unreadCount?: number
    unreadMark?: boolean
    readMaxId?: MessageID
    archived?: boolean
  },
) => {
  if (!peer || peer.type.oneofKind === undefined) return false
  const peerThreadId = getPeerChatId(peer)
  const peerUserId = getPeerUserId(peer)
  const dialogId =
    peerThreadId != null
      ? getDialogId({ peerThreadId })
      : peerUserId != null
        ? getDialogId({ peerUserId })
        : undefined
  if (dialogId == null) return false

  const ref = db.ref(DbObjectKind.Dialog, dialogId)
  const existing = db.get(ref)
  if (!existing) return false

  db.update({
    ...existing,
    unreadCount: changes.unreadCount ?? existing.unreadCount,
    unreadMark: changes.unreadMark ?? existing.unreadMark,
    readMaxId: changes.readMaxId ?? existing.readMaxId,
    archived: changes.archived ?? existing.archived,
  })
  return true
}

export type UpdateApplySource = "realtime" | "syncCatchup"

export type UpdateDisposition =
  | "applied"
  | "ephemeral"
  | "syncHint"
  | "deferred"

export type UpdateApplyReport = {
  applied: number
  ephemeral: number
  syncHint: number
  deferred: number
  failed: number
}

export class UpdateApplicationError extends Error {
  readonly updateType: string
  readonly updateIndex: number
  readonly report: UpdateApplyReport

  constructor(
    updateType: string,
    updateIndex: number,
    report: UpdateApplyReport,
    cause: unknown,
  ) {
    super(
      `Failed to apply Inline update ${updateType} at index ${updateIndex}`,
      { cause },
    )
    this.name = "UpdateApplicationError"
    this.updateType = updateType
    this.updateIndex = updateIndex
    this.report = report
  }
}

const emptyReport = (): UpdateApplyReport => ({
  applied: 0,
  ephemeral: 0,
  syncHint: 0,
  deferred: 0,
  failed: 0,
})

const safeProtocolDate = (
  value: bigint | undefined,
  field: string,
): number | undefined => {
  if (value == null) return undefined
  const date = Number(value)
  if (!Number.isSafeInteger(date)) {
    throw new RangeError(`Unsafe ${field}: ${String(value)}`)
  }
  return date
}

const fnv1a64 = (bytes: Uint8Array) => {
  let hash = 0xcbf29ce484222325n
  for (const byte of bytes) {
    hash ^= BigInt(byte)
    hash = BigInt.asUintN(64, hash * 0x100000001b3n)
  }
  return hash.toString(16).padStart(16, "0")
}

const insertDeferredPayload = (
  db: Db,
  input: {
    bucketId: string
    seq?: number
    date?: number
    payloadType: "Update" | "UserGroup"
    updateType: string
    targetKey?: string
    payload: Uint8Array
    identity: string
  },
) => {
  const id = [
    input.bucketId,
    input.seq ?? "_",
    input.date ?? "_",
    input.updateType,
    input.identity,
    fnv1a64(input.payload),
  ].join("|")
  db.replace({
    kind: DbObjectKind.DeferredUpdate,
    id,
    bucketId: input.bucketId,
    seq: input.seq,
    date: input.date,
    payloadType: input.payloadType,
    updateType: input.updateType,
    targetKey: input.targetKey,
    payload: input.payload,
  })
}

const deferUpdate = (db: Db, update: Update) => {
  const updateType = update.update.oneofKind
  if (updateType === undefined) {
    throw new TypeError("Cannot defer an Inline update without a payload")
  }
  const key = updateBucketKey(update)
  insertDeferredPayload(db, {
    bucketId: key ? syncBucketId(key) : "unbucketed",
    seq: update.seq,
    date: safeProtocolDate(update.date, "update.date"),
    payloadType: "Update",
    updateType,
    targetKey:
      reactionUpdateTargetKey(update) ??
      messageAttachmentUpdateTargetKey(update),
    payload: Update.toBinary(update),
    identity: "update",
  })
}

const deferUserGroup = (
  db: Db,
  group: UpdateSidecars["userGroups"][number],
) => {
  const exactSpaceId = makeSpaceId(group.spaceId)
  const payload = UserGroup.toBinary(group)
  insertDeferredPayload(db, {
    bucketId: syncBucketId({
      kind: "space",
      spaceId: exactSpaceId,
    }),
    date: safeProtocolDate(group.date, "userGroup.date"),
    payloadType: "UserGroup",
    updateType: "sidecarUserGroup",
    payload,
    identity: String(group.id),
  })
}

const assertNeverUpdate = (value: never): never => {
  throw new TypeError(`Unhandled Inline update: ${String(value)}`)
}

const applyUpdate = (
  db: Db,
  update: Update,
  source: UpdateApplySource,
): UpdateDisposition => {
  switch (update.update.oneofKind) {
    case "newMessage": {
      const protocolMessage = update.update.newMessage.message
      if (!protocolMessage) {
        deferUpdate(db, update)
        return "deferred"
      }
      const chatId = makeChatId(protocolMessage.chatId)
      const messageId = makeMessageId(protocolMessage.id)
      const existed =
        db.get(
          db.ref(
            DbObjectKind.Message,
            messageKey(chatId, messageId),
          ),
        ) != null
      upsertMessage(db, protocolMessage)

      if (
        source === "realtime" &&
        !existed &&
        !protocolMessage.out
      ) {
        const dialog = db
          .queryCollection(
            DbQueryPlanType.Objects,
            DbObjectKind.Dialog,
            (candidate) => candidate.chatId === chatId,
          )
          .at(0)
        if (
          dialog &&
          (dialog.readMaxId == null ||
            compareInlineIds(messageId, dialog.readMaxId) > 0)
        ) {
          db.update({
            ...dialog,
            unreadCount: (dialog.unreadCount ?? 0) + 1,
          })
        }
      }
      return "applied"
    }

    case "editMessage":
      if (!update.update.editMessage.message) {
        deferUpdate(db, update)
        return "deferred"
      }
      upsertMessage(db, update.update.editMessage.message)
      return "applied"

    case "deleteMessages": {
      const chatId = getChatIdForPeer(
        db,
        update.update.deleteMessages.peerId,
      )
      if (chatId == null) {
        deferUpdate(db, update)
        return "deferred"
      }
      const deletedIds = new Set<MessageID>()
      for (const protocolMessageId of update.update.deleteMessages.messageIds) {
        const id = makeMessageId(protocolMessageId)
        deletedIds.add(id)
        db.delete(
          db.ref(
            DbObjectKind.Message,
            messageKey(chatId, id),
          ),
        )
      }
      const chatRef = db.ref(DbObjectKind.Chat, chatId)
      const chat = db.get(chatRef)
      if (chat?.lastMsgId != null && deletedIds.has(chat.lastMsgId)) {
        const previous = db
          .queryCollection(
            DbQueryPlanType.Objects,
            DbObjectKind.Message,
            (message) =>
              message.chatId === chatId &&
              !deletedIds.has(message.messageId),
          )
          .sort(
            (left, right) =>
              compareInlineIds(right.messageId, left.messageId),
          )
          .at(0)
        db.replace({
          ...chat,
          lastMsgId: previous?.messageId,
          date: previous?.date ?? chat.date,
        })
      }
      return "applied"
    }

    case "updateMessageId": {
      const messageId = makeMessageId(
        update.update.updateMessageId.messageId,
      )
      const randomId = update.update.updateMessageId.randomId
      const existing = db
        .queryCollection(
          DbQueryPlanType.Objects,
          DbObjectKind.Message,
          (message) => message.randomId === randomId,
        )
        .at(0)

      if (!existing) {
        deferUpdate(db, update)
        return "deferred"
      }
      if (existing.messageId === messageId) return "applied"

      db.delete(db.ref(DbObjectKind.Message, existing.id))
      db.insert({
        ...existing,
        id: messageKey(existing.chatId, messageId),
        messageId,
        randomId: undefined,
        status: MessageSendingStatus.Sent,
      })
      const chatRef = db.ref(DbObjectKind.Chat, existing.chatId)
      const chat = db.get(chatRef)
      if (chat?.lastMsgId === existing.messageId) {
        db.update({
          ...chat,
          lastMsgId: messageId,
        })
      }
      return "applied"
    }

    case "newChat": {
      const chat = update.update.newChat.chat
      const user = update.update.newChat.user
      if (chat) upsertChat(db, chat)
      if (user) upsertUser(db, user)
      if (!chat && !user) {
        deferUpdate(db, update)
        return "deferred"
      }
      return "applied"
    }

    case "deleteChat": {
      const chatId = getChatIdForPeer(
        db,
        update.update.deleteChat.peerId,
      )
      if (chatId == null) {
        deferUpdate(db, update)
        return "deferred"
      }
      db.clearMessagesForChat(chatId)
      db.delete(db.ref(DbObjectKind.Chat, chatId))
      const dialogs = db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.Dialog,
        (dialog) => dialog.chatId === chatId,
      )
      for (const dialog of dialogs) {
        db.delete(db.ref(DbObjectKind.Dialog, dialog.id))
      }
      return "applied"
    }

    case "chatOpen": {
      const { user, chat, dialog } = update.update.chatOpen
      if (user) upsertUser(db, user)
      if (chat) upsertChat(db, chat)
      if (dialog) upsertDialog(db, dialog)
      if (!user && !chat && !dialog) {
        deferUpdate(db, update)
        return "deferred"
      }
      return "applied"
    }

    case "chatMoved":
      if (!update.update.chatMoved.chat) {
        deferUpdate(db, update)
        return "deferred"
      }
      upsertChat(db, update.update.chatMoved.chat)
      return "applied"

    case "joinSpace":
      if (update.update.joinSpace.space) {
        upsertSpace(db, update.update.joinSpace.space)
      }
      // Membership has no lean materialized model yet.
      deferUpdate(db, update)
      return "deferred"

    case "updatedUser":
      if (!update.update.updatedUser.user) {
        deferUpdate(db, update)
        return "deferred"
      }
      upsertUser(db, update.update.updatedUser.user)
      return "applied"

    case "spaceMemberAdd":
      if (update.update.spaceMemberAdd.user) {
        upsertUser(db, update.update.spaceMemberAdd.user)
      }
      deferUpdate(db, update)
      return "deferred"

    case "chatVisibility": {
      const chatId = makeChatId(update.update.chatVisibility.chatId)
      const ref = db.ref(DbObjectKind.Chat, chatId)
      const existing = db.get(ref)
      if (!existing) {
        deferUpdate(db, update)
        return "deferred"
      }
      db.replace({
        ...existing,
        isPublic: update.update.chatVisibility.isPublic,
      })
      return "applied"
    }

    case "chatInfo": {
      const chatId = makeChatId(update.update.chatInfo.chatId)
      const ref = db.ref(DbObjectKind.Chat, chatId)
      const existing = db.get(ref)
      if (!existing) {
        deferUpdate(db, update)
        return "deferred"
      }
      const nextTitle = update.update.chatInfo.title
      const nextEmoji = update.update.chatInfo.emoji
      db.replace({
        ...existing,
        title: nextTitle ?? existing.title,
        emoji:
          nextEmoji !== undefined
            ? nextEmoji.length > 0
              ? nextEmoji
              : undefined
            : existing.emoji,
        untitled: update.update.chatInfo.untitled ?? existing.untitled,
      })
      return "applied"
    }

    case "chatPermissions": {
      const chatId = makeChatId(update.update.chatPermissions.chatId)
      const ref = db.ref(DbObjectKind.Chat, chatId)
      const existing = db.get(ref)
      if (!existing) {
        deferUpdate(db, update)
        return "deferred"
      }
      db.replace({
        ...existing,
        canUpdateInfo:
          update.update.chatPermissions.permissions?.canUpdateInfo ??
          existing.canUpdateInfo,
      })
      return "applied"
    }

    case "pinnedMessages": {
      const chatId = getChatIdForPeer(
        db,
        update.update.pinnedMessages.peerId,
      )
      if (chatId == null) {
        deferUpdate(db, update)
        return "deferred"
      }
      const ref = db.ref(DbObjectKind.Chat, chatId)
      const existing = db.get(ref)
      if (!existing) {
        deferUpdate(db, update)
        return "deferred"
      }
      db.update({
        ...existing,
        pinnedMessageIds:
          update.update.pinnedMessages.messageIds.map((id) =>
            makeMessageId(id),
          ),
      })
      return "applied"
    }

    case "updateReadMaxId":
      if (
        !updateDialogForPeer(
          db,
          update.update.updateReadMaxId.peerId,
          {
            readMaxId: makeMessageId(
              update.update.updateReadMaxId.readMaxId,
            ),
            unreadCount:
              update.update.updateReadMaxId.unreadCount,
            unreadMark: false,
          },
        )
      ) {
        deferUpdate(db, update)
        return "deferred"
      }
      return "applied"

    case "markAsUnread":
      if (
        !updateDialogForPeer(
          db,
          update.update.markAsUnread.peerId,
          {
            unreadMark: update.update.markAsUnread.unreadMark,
          },
        )
      ) {
        deferUpdate(db, update)
        return "deferred"
      }
      return "applied"

    case "dialogArchived":
      if (
        !updateDialogForPeer(
          db,
          update.update.dialogArchived.peerId,
          {
            archived: update.update.dialogArchived.archived,
          },
        )
      ) {
        deferUpdate(db, update)
        return "deferred"
      }
      return "applied"

    case "dialogFollowMode": {
      const peer = update.update.dialogFollowMode.peerId
      if (!peer || peer.type.oneofKind === undefined) {
        deferUpdate(db, update)
        return "deferred"
      }
      const peerThreadId = getPeerChatId(peer)
      const peerUserId = getPeerUserId(peer)
      const dialogId =
        peerThreadId != null
          ? getDialogId({ peerThreadId })
          : peerUserId != null
            ? getDialogId({ peerUserId })
            : undefined
      if (dialogId == null) {
        deferUpdate(db, update)
        return "deferred"
      }
      const ref = db.ref(DbObjectKind.Dialog, dialogId)
      const existing = db.get(ref)
      if (!existing) {
        deferUpdate(db, update)
        return "deferred"
      }
      db.replace({
        ...existing,
        followMode: update.update.dialogFollowMode.followMode,
      })
      return "applied"
    }

    case "clearChatHistory": {
      if (
        update.update.clearChatHistory.target.oneofKind !==
        "peerId"
      ) {
        deferUpdate(db, update)
        return "deferred"
      }
      const chatId = getChatIdForPeer(
        db,
        update.update.clearChatHistory.target.peerId,
      )
      if (chatId == null) {
        deferUpdate(db, update)
        return "deferred"
      }
      db.clearMessagesForChat(chatId)
      const chatRef = db.ref(DbObjectKind.Chat, chatId)
      const chat = db.get(chatRef)
      if (chat) {
        db.replace({
          ...chat,
          lastMsgId: undefined,
        })
      }
      return "applied"
    }

    case "updateReaction": {
      const targetKey = reactionUpdateTargetKey(update)
      if (!targetKey) {
        deferUpdate(db, update)
        return "deferred"
      }
      replayDeferredMessageUpdates(db, targetKey)
      if (
        applyResidentReactionUpdate(db, update) !== "applied"
      ) {
        deferUpdate(db, update)
        return "deferred"
      }
      return "applied"
    }

    case "deleteReaction": {
      const targetKey = reactionUpdateTargetKey(update)
      if (!targetKey) {
        deferUpdate(db, update)
        return "deferred"
      }
      replayDeferredMessageUpdates(db, targetKey)
      if (
        applyResidentReactionUpdate(db, update) !== "applied"
      ) {
        deferUpdate(db, update)
        return "deferred"
      }
      return "applied"
    }

    case "messageAttachment": {
      const targetKey = messageAttachmentUpdateTargetKey(update)
      if (!targetKey) {
        deferUpdate(db, update)
        return "deferred"
      }
      replayDeferredMessageUpdates(db, targetKey)
      if (
        applyResidentMessageAttachmentUpdate(db, update) !==
        "applied"
      ) {
        deferUpdate(db, update)
        return "deferred"
      }
      return "applied"
    }
    case "participantAdd":
    case "participantDelete":
    case "spaceMemberDelete":
    case "spaceMemberUpdate":
    case "updateUserSettings":
    case "dialogNotificationSettings":
    case "participantGroupAdd":
    case "participantGroupDelete":
    case "spaceSettings":
      deferUpdate(db, update)
      return "deferred"

    case "updateComposeAction":
    case "updateUserStatus":
    case "newMessageNotification":
    case "messageActionInvoked":
    case "messageActionAnswered":
    case "botPresence":
      return "ephemeral"

    case "chatSkipPts":
    case "chatHasNewUpdates":
    case "spaceHasNewUpdates":
      return "syncHint"

    case undefined:
      throw new TypeError("Inline update is missing its oneof payload")

    default:
      return assertNeverUpdate(update.update)
  }
}

export const applyUpdates = (
  db: Db,
  updates: Update[],
  source: UpdateApplySource = "realtime",
): UpdateApplyReport => {
  const report = emptyReport()
  db.batch(() => {
    for (const [index, update] of updates.entries()) {
      const updateType = update.update.oneofKind ?? "undefined"
      try {
        const disposition = applyUpdate(db, update, source)
        report[disposition] += 1
      } catch (cause) {
        report.failed += 1
        throw new UpdateApplicationError(
          updateType,
          index,
          { ...report },
          cause,
        )
      }
    }
  })
  return report
}

export const applyUpdateSidecars = (
  db: Db,
  sidecars?: UpdateSidecars,
): UpdateApplyReport => {
  const report = emptyReport()
  if (!sidecars) return report

  db.batch(() => {
    for (const user of sidecars.users) {
      upsertUser(db, user)
      report.applied += 1
    }
    for (const chat of sidecars.chats) {
      upsertChat(db, chat)
      report.applied += 1
    }
    for (const dialog of sidecars.dialogs) {
      upsertDialog(db, dialog)
      report.applied += 1
    }
    for (const space of sidecars.spaces) {
      upsertSpace(db, space)
      report.applied += 1
    }
    for (const group of sidecars.userGroups) {
      deferUserGroup(db, group)
      report.deferred += 1
    }
  })
  return report
}
