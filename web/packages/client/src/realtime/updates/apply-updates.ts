import {
  Update,
  UserGroup,
  type Peer,
  type UpdateSidecars,
} from "@inline-chat/protocol/core"
import {
  chatId as makeChatId,
  compareInlineIds,
  inlineId,
  messageId as makeMessageId,
  spaceId as makeSpaceId,
  userId as makeUserId,
  type ChatID,
  type MessageID,
} from "@inline/ids"
import type { Db } from "../../database"
import {
  DbObjectKind,
  messageKey,
  MessageSendingStatus,
  spaceMemberKey,
  type DbModels,
  type DeferredUpdate,
} from "../../database/models"
import { DbQueryPlanType } from "../../database/types"
import { updateBucketKey } from "../sync/update-bucket-key"
import { syncBucketId } from "../sync/sync-types"
import {
  applySidecarDialog,
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
import { accountUserId } from "./account-context"
import {
  deleteParticipant,
  deleteParticipantGroup,
  purgeChat,
  purgePublicThreads,
  purgeSpace,
  purgeThreadIfAccessLost,
  putUserGroup,
  reconcileSpaceMember,
  rosterCovers,
  saveParticipant,
  saveParticipantGroup,
  spaceMemberModel,
} from "./membership"
import {
  applyUnreadActivity,
  dialogNotificationMode,
  putDialogFolder,
} from "./dialog-state"
import { applySpaceSettings, applyUserSettings } from "./settings"

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

const dialogForPeer = (
  db: Db,
  peer: Peer | undefined,
): DbModels[DbObjectKind.Dialog] | undefined => {
  if (!peer || peer.type.oneofKind === undefined) return undefined
  const peerThreadId = getPeerChatId(peer)
  const peerUserId = getPeerUserId(peer)
  const dialogId =
    peerThreadId != null
      ? getDialogId({ peerThreadId })
      : peerUserId != null
        ? getDialogId({ peerUserId })
        : undefined
  if (dialogId == null) return undefined
  return db.get(db.ref(DbObjectKind.Dialog, dialogId))
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

type DeferredPayloadInput = {
  bucketId: string
  seq?: number
  date?: number
  payloadType: "Update" | "UserGroup"
  updateType: string
  targetKey?: string
  payload: Uint8Array
  identity: string
}

const deferredRecord = (input: DeferredPayloadInput): DeferredUpdate => {
  const id = [
    input.bucketId,
    input.seq ?? "_",
    input.date ?? "_",
    input.updateType,
    input.identity,
    fnv1a64(input.payload),
  ].join("|")
  return {
    kind: DbObjectKind.DeferredUpdate,
    id,
    bucketId: input.bucketId,
    seq: input.seq,
    date: input.date,
    payloadType: input.payloadType,
    updateType: input.updateType,
    targetKey: input.targetKey,
    payload: input.payload,
  }
}

/**
 * The raw row an update is stored as when the client keeps it for replay
 * (invariant 7). Exported for replay tests and for the upgrade replay.
 */
export const deferredUpdateRecord = (update: Update): DeferredUpdate => {
  const updateType = update.update.oneofKind
  if (updateType === undefined) {
    throw new TypeError("Cannot defer an Inline update without a payload")
  }
  const key = updateBucketKey(update)
  return deferredRecord({
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

const deferUpdate = (db: Db, update: Update) => {
  db.replace(deferredUpdateRecord(update))
}

/** The raw row a sidecar user group was stored as before schema version 4. */
export const deferredUserGroupRecord = (
  group: UpdateSidecars["userGroups"][number],
): DeferredUpdate => {
  const exactSpaceId = makeSpaceId(group.spaceId)
  const payload = UserGroup.toBinary(group)
  return deferredRecord({
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

/**
 * What an update needs to know about the rest of its page: for each chat, the
 * index of the page's last update that grants the account access again. A
 * removal followed by a grant in the same page must not purge the chat
 * (InlineKit's `currentUserRegainsAccess`).
 */
type PageContext = {
  index: number
  lastGrant: Map<string, number>
}

const grantsAccount = (db: Db, update: Update): string | undefined => {
  const self = accountUserId(db)
  switch (update.update.oneofKind) {
    case "userAddedToChat":
      return String(update.update.userAddedToChat.chatId)
    case "participantAdd":
      return self != null &&
        String(update.update.participantAdd.participant?.userId) === self
        ? String(update.update.participantAdd.chatId)
        : undefined
    case "participantGroupAdd": {
      const groupId = update.update.participantGroupAdd.groupParticipant?.groupId
      if (groupId == null || self == null) return undefined
      const group = db.get(db.ref(DbObjectKind.UserGroup, inlineId(groupId)))
      return group && (group.currentUserIsMember || group.userIds.includes(self))
        ? String(update.update.participantGroupAdd.chatId)
        : undefined
    }
    default:
      return undefined
  }
}

const pageContext = (db: Db, updates: readonly Update[]) => {
  const lastGrant = new Map<string, number>()
  updates.forEach((update, index) => {
    const chat = grantsAccount(db, update)
    if (chat != null) lastGrant.set(chat, index)
  })
  return lastGrant
}

const regainsAccess = (page: PageContext | undefined, chatId: bigint) =>
  page != null && (page.lastGrant.get(String(chatId)) ?? -1) > page.index

const applyUpdate = (
  db: Db,
  update: Update,
  source: UpdateApplySource,
  page?: PageContext,
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
      upsertMessage(db, update.update.editMessage.message, {
        replaceBlockContent: true,
      })
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

      const nextMessageKey = messageKey(existing.chatId, messageId)
      db.delete(db.ref(DbObjectKind.Message, existing.id))
      db.insert({
        ...existing,
        id: nextMessageKey,
        messageId,
        randomId: undefined,
        status: MessageSendingStatus.Sent,
      })
      db.migrateResidentMessageWindowKey(
        existing.chatId,
        existing.id,
        nextMessageKey,
      )
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
      // InlineKit `UpdateDeleteChat` -> `deleteLocalChatData`: the same
      // purge as an access loss (messages, dialogs, grants, the chat and
      // its cursor; drafts stay).
      purgeChat(db, chatId)
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

    case "joinSpace": {
      const { space, member } = update.update.joinSpace
      if (!space && !member) {
        deferUpdate(db, update)
        return "deferred"
      }
      if (space) upsertSpace(db, space)
      // The user journal embeds the membership at join time; the space
      // journal may already have moved it on. Keep a stored row, restore a
      // missing one (InlineKit `UpdateJoinSpace.apply`).
      if (member) {
        const model = spaceMemberModel(member)
        if (!db.get(db.ref(DbObjectKind.SpaceMember, model.id))) {
          db.replace(model)
        }
      }
      return "applied"
    }

    case "updatedUser":
      if (!update.update.updatedUser.user) {
        deferUpdate(db, update)
        return "deferred"
      }
      upsertUser(db, update.update.updatedUser.user)
      return "applied"

    case "spaceMemberAdd": {
      const { member, user } = update.update.spaceMemberAdd
      if (!member) {
        deferUpdate(db, update)
        return "deferred"
      }
      if (rosterCovers(db, makeSpaceId(member.spaceId), update.seq)) {
        return "applied"
      }
      if (user) upsertUser(db, user)
      reconcileSpaceMember(db, member)
      return "applied"
    }

    case "spaceMemberUpdate": {
      const member = update.update.spaceMemberUpdate.member
      if (!member) {
        deferUpdate(db, update)
        return "deferred"
      }
      const exactSpaceId = makeSpaceId(member.spaceId)
      if (rosterCovers(db, exactSpaceId, update.seq)) return "applied"
      const write = reconcileSpaceMember(db, member)
      if (
        write.applied &&
        String(member.userId) === accountUserId(db) &&
        (write.previous?.canAccessPublicChats ?? true) &&
        !member.canAccessPublicChats
      ) {
        purgePublicThreads(db, exactSpaceId)
      }
      return "applied"
    }

    case "spaceMemberDelete": {
      const removal = update.update.spaceMemberDelete
      const exactSpaceId = makeSpaceId(removal.spaceId)
      const exactUserId = makeUserId(removal.userId)
      const self = exactUserId === accountUserId(db)
      // A user-bucket copy of the account's own removal carries a user
      // sequence, so the space roster's sequence says nothing about it.
      if (!self && rosterCovers(db, exactSpaceId, update.seq)) return "applied"
      const existing = db.get(
        db.ref(DbObjectKind.SpaceMember, spaceMemberKey(exactSpaceId, exactUserId)),
      )
      if (existing) {
        // A removal of an older membership generation must not remove a
        // later one. Without a member ID, an event older than the stored
        // membership's join date proves the same.
        if (removal.memberId != null) {
          if (String(removal.memberId) !== String(existing.memberId)) return "applied"
        } else {
          const date = safeProtocolDate(update.date, "update.date")
          if (date != null && existing.date > date) return "applied"
        }
        db.delete(db.ref(DbObjectKind.SpaceMember, existing.id))
      }
      if (self) purgeSpace(db, exactSpaceId)
      return "applied"
    }

    case "participantAdd": {
      const { chatId, participant } = update.update.participantAdd
      if (participant) saveParticipant(db, makeChatId(chatId), participant)
      return "applied"
    }

    case "participantDelete": {
      const { chatId, userId } = update.update.participantDelete
      const exactChatId = makeChatId(chatId)
      deleteParticipant(db, exactChatId, makeUserId(userId))
      if (
        String(userId) === accountUserId(db) &&
        !regainsAccess(page, chatId)
      ) {
        purgeThreadIfAccessLost(db, exactChatId)
      }
      return "applied"
    }

    case "participantGroupAdd": {
      const { chatId, groupParticipant } = update.update.participantGroupAdd
      if (groupParticipant) {
        saveParticipantGroup(db, makeChatId(chatId), groupParticipant)
      }
      return "applied"
    }

    case "participantGroupDelete": {
      const { chatId, groupId } = update.update.participantGroupDelete
      const exactChatId = makeChatId(chatId)
      // Only a grant this replica held can be the one the account lost.
      if (
        deleteParticipantGroup(db, exactChatId, inlineId(groupId)) &&
        !regainsAccess(page, chatId)
      ) {
        purgeThreadIfAccessLost(db, exactChatId)
      }
      return "applied"
    }

    case "userAddedToChat": {
      const { chatId, participant, group } = update.update.userAddedToChat
      if (chatId <= 0n) return "applied"
      const exactChatId = makeChatId(chatId)
      if (participant) saveParticipant(db, exactChatId, participant)
      if (group) saveParticipantGroup(db, exactChatId, group)
      return "applied"
    }

    case "userRemovedFromChat": {
      const { chatId } = update.update.userRemovedFromChat
      if (chatId > 0n) purgeChat(db, makeChatId(chatId))
      return "applied"
    }

    case "dialogNotificationSettings": {
      const dialog = dialogForPeer(db, update.update.dialogNotificationSettings.peerId)
      // A dialog not stored yet arrives as a snapshot carrying its settings.
      if (dialog) {
        db.replace({
          ...dialog,
          notificationMode: dialogNotificationMode(
            update.update.dialogNotificationSettings.notificationSettings,
          ),
        })
      }
      return "applied"
    }

    case "dialogTranslation": {
      const dialog = dialogForPeer(db, update.update.dialogTranslation.peerId)
      if (dialog) {
        db.replace({
          ...dialog,
          translationEnabled: update.update.dialogTranslation.enabled,
        })
      }
      return "applied"
    }

    case "dialogFolder": {
      const change = update.update.dialogFolder
      if (change.folderChange.oneofKind === "folder") {
        putDialogFolder(db, change.folderChange.folder)
      }
      // Complete snapshots of every dialog the folder change moved.
      for (const dialog of change.dialogs) upsertDialog(db, dialog)
      if (change.folderChange.oneofKind === "deletedFolderId") {
        const ref = db.ref(
          DbObjectKind.DialogFolder,
          inlineId(change.folderChange.deletedFolderId),
        )
        if (db.get(ref)) db.delete(ref)
      }
      return "applied"
    }

    case "unreadActivity": {
      const dialog = dialogForPeer(db, update.update.unreadActivity.peerId)
      if (dialog) applyUnreadActivity(db, dialog, update.update.unreadActivity)
      return "applied"
    }

    case "updateUserSettings":
      if (!update.update.updateUserSettings.settings) {
        deferUpdate(db, update)
        return "deferred"
      }
      applyUserSettings(db, update.update.updateUserSettings.settings)
      return "applied"

    case "spaceSettings":
      if (update.update.spaceSettings.settings) {
        applySpaceSettings(db, {
          ...update.update.spaceSettings.settings,
          spaceId: update.update.spaceSettings.spaceId,
        })
      }
      return "applied"

    case "spaceProfile": {
      const profile = update.update.spaceProfile
      const ref = db.ref(DbObjectKind.Space, makeSpaceId(profile.spaceId))
      const space = db.get(ref)
      const seq = update.seq ?? 0
      // A profile at or below the stored snapshot's sequence is already in
      // it (InlineKit applies it only when `space.seq <= update.seq`).
      if (space && (space.seq ?? 0) <= seq) {
        db.replace({
          ...space,
          photoFileUniqueId: profile.photoFileUniqueId,
          photoUrl: profile.photoUrl,
          isPro: profile.isPro,
          ...(seq > 0 ? { seq } : {}),
        })
      }
      return "applied"
    }

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

    case "updateReadMaxId": {
      const incoming = makeMessageId(
        update.update.updateReadMaxId.readMaxId,
      )
      const existing = dialogForPeer(
        db,
        update.update.updateReadMaxId.peerId,
      )
      if (
        existing?.readMaxId != null &&
        compareInlineIds(incoming, existing.readMaxId) <= 0
      ) {
        // The read frontier only moves forward (as in InlineKit's
        // `UpdateReadMaxId.apply`). A replayed or reordered read carries the
        // count of its own moment; an equal frontier is already applied and
        // must not erase messages counted since, nor a later mark-unread.
        return "applied"
      }
      if (
        !updateDialogForPeer(
          db,
          update.update.updateReadMaxId.peerId,
          {
            readMaxId: incoming,
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
    }

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

    case "dialogCollapsedMaxId": {
      const peer = update.update.dialogCollapsedMaxId.peerId
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
        collapsedMaxId:
          update.update.dialogCollapsedMaxId.maxId === undefined
            ? undefined
            : makeMessageId(update.update.dialogCollapsedMaxId.maxId),
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
    // Read receipts (acknowledgement cursors) have no web model yet.
    case "acknowledgement":
    // Bridge v2 agent state: the web client does not render it yet.
    case "agentSessionState":
    case "agentParticipation":
    case "agentGrant":
    case "agentRuntime":
    case "agentSettings":
    case "agentSessionControl":
      deferUpdate(db, update)
      return "deferred"

    case "updateComposeAction":
    case "composeSuggestion":
    case "updateUserStatus":
    case "newMessageNotification":
    case "messageActionInvoked":
    case "messageActionAnswered":
    case "botPresence":
      return "ephemeral"

    case "chatSkipPts":
    case "chatHasNewUpdates":
    case "spaceHasNewUpdates":
    case "userHasNewUpdates":
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
    const lastGrant = pageContext(db, updates)
    for (const [index, update] of updates.entries()) {
      const updateType = update.update.oneofKind ?? "undefined"
      try {
        const disposition = applyUpdate(db, update, source, {
          index,
          lastGrant,
        })
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

export type UpdateSidecarReport = UpdateApplyReport & {
  /**
   * Chats whose unread count was taken from a sidecar, with the chat
   * sequence the count is valid through (the sidecar chat's `seq`). A live
   * message at or below that sequence is already in the count.
   */
  countedChats: Array<{ chatId: ChatID; seq: number }>
}

export const applyUpdateSidecars = (
  db: Db,
  sidecars?: UpdateSidecars,
): UpdateSidecarReport => {
  const report: UpdateSidecarReport = {
    ...emptyReport(),
    countedChats: [],
  }
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
      const applied = applySidecarDialog(db, dialog)
      report.applied += 1
      if (!applied?.counted) continue
      const snapshot = sidecars.chats.find(
        (chat) => String(chat.id) === String(applied.chatId),
      )
      if (snapshot?.seq != null && snapshot.seq > 0) {
        report.countedChats.push({
          chatId: applied.chatId,
          seq: snapshot.seq,
        })
      }
    }
    for (const space of sidecars.spaces) {
      upsertSpace(db, space)
      report.applied += 1
    }
    for (const group of sidecars.userGroups) {
      putUserGroup(db, group)
      report.applied += 1
    }
  })
  return report
}
