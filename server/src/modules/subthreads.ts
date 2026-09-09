import { db } from "@in/server/db"
import { UsersModel } from "@in/server/db/models/users"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { MessageModel, type DbFullMessage } from "@in/server/db/models/messages"
import {
  chats,
  dialogs,
  messages,
  subthreadParentMessages,
  users,
  type DbChat,
  type DbDialog,
  type DbMessage,
} from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { Transaction } from "@in/server/db/types"
import { getUpdateGroup } from "@in/server/modules/updates"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { encodePeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import type { ServerUpdate } from "@in/server/protocol/server"
import {
  MessageSubthread_Kind,
  type MessageReplies,
  type MessageSubthread,
  type Update,
} from "@inline-chat/protocol/core"
import { and, eq, inArray, or, sql } from "drizzle-orm"
import { dialogOpenDefaultsForChat, setDialogOpenForUsers } from "@in/server/modules/dialogOpen"
import {
  getDirectParticipantUserIds as resolveDirectParticipantUserIds,
  getEffectiveAccessUserIds as resolveEffectiveAccessUserIds,
  getInheritedAccessUserIds as resolveInheritedAccessUserIds,
  getTopLevelAccessUserIds as resolveTopLevelAccessUserIds,
} from "@in/server/modules/authorization/threadAccess"
import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"

const log = new Log("modules.subthreads")

export const isLinkedSubthread = (chat: Pick<DbChat, "parentChatId">): boolean => chat.parentChatId != null

export const isReplyThread = (chat: Pick<DbChat, "parentMessageId">): boolean => chat.parentMessageId != null

const RECENT_AUTHOR_LIMIT = 3
const REPLY_THREAD_TITLE_EXCERPT_LENGTH = 60
const LEGACY_REPLY_THREAD_TITLE_EXCERPT_LENGTH = 72
const GENERIC_REPLY_THREAD_TITLE = "Message"

type ReplyThreadTitleAnchor = Pick<DbFullMessage, "text">

export async function getChatById(chatId: number): Promise<DbChat | undefined> {
  return db.select().from(chats).where(eq(chats.id, chatId)).limit(1).then((rows) => rows[0])
}

export async function getAnchorMessageForChat(chat: Pick<DbChat, "parentChatId" | "parentMessageId">): Promise<DbFullMessage | undefined> {
  if (chat.parentChatId == null || chat.parentMessageId == null) {
    return undefined
  }

  const anchorMessages = await MessageModel.getMessagesByIds(chat.parentChatId, [BigInt(chat.parentMessageId)])
  return anchorMessages[0]
}

export function buildDefaultReplyThreadTitle(anchorMessage: ReplyThreadTitleAnchor | undefined): string {
  const normalizedText = anchorMessage?.text?.trim().replace(/\s+/g, " ")
  const excerpt = normalizedText
    ? Array.from(normalizedText).slice(0, REPLY_THREAD_TITLE_EXCERPT_LENGTH).join("")
    : undefined
  if (excerpt && excerpt.length > 0) {
    return excerpt.trim()
  }

  return GENERIC_REPLY_THREAD_TITLE
}

export function isDefaultReplyThreadTitle(
  title: string | null,
  anchorMessage: ReplyThreadTitleAnchor | undefined,
): boolean {
  const normalizedTitle = title?.trim()
  if (!normalizedTitle) {
    return true
  }

  return normalizedTitle === buildDefaultReplyThreadTitle(anchorMessage).trim()
    || normalizedTitle === buildLegacyDefaultReplyThreadTitle(anchorMessage).trim()
}

function buildLegacyDefaultReplyThreadTitle(anchorMessage: ReplyThreadTitleAnchor | undefined): string {
  const excerpt = anchorMessage?.text
    ?.trim()
    .replace(/\s+/g, " ")
    .slice(0, LEGACY_REPLY_THREAD_TITLE_EXCERPT_LENGTH)
  return `Re: ${excerpt || GENERIC_REPLY_THREAD_TITLE}`
}

export async function getReplyThreadAnchorSenderId(
  chat: Pick<DbChat, "parentChatId" | "parentMessageId">,
): Promise<number | undefined> {
  if (chat.parentChatId == null || chat.parentMessageId == null) {
    return undefined
  }

  return MessageModel.getSenderIdForMessage({
    chatId: chat.parentChatId,
    messageId: chat.parentMessageId,
  })
}

export async function getDialogForUser(chatId: number, userId: number): Promise<DbDialog | undefined> {
  return db
    .select()
    .from(dialogs)
    .where(and(eq(dialogs.chatId, chatId), eq(dialogs.userId, userId)))
    .limit(1)
    .then((rows) => rows[0])
}

export async function ensureLinkedSubthreadDialogs(input: {
  chat: Pick<DbChat, "id" | "spaceId" | "type">
  userIds: number[]
  chatListHidden?: boolean
}): Promise<{ dialogs: DbDialog[]; createdDialogs: DbDialog[] }> {
  const activeUserIds = await UsersModel.getActiveUserIds(
    Array.from(new Set(input.userIds.filter((userId) => Number.isSafeInteger(userId) && userId > 0))),
  )

  if (activeUserIds.length === 0) {
    return { dialogs: [], createdDialogs: [] }
  }

  const existingDialogs = await db
    .select()
    .from(dialogs)
    .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, activeUserIds)))

  const existingUserIds = new Set(existingDialogs.map((dialog) => dialog.userId))
  const missingUserIds = activeUserIds.filter((userId) => !existingUserIds.has(userId))

  let createdDialogs: DbDialog[] = []
  if (missingUserIds.length > 0) {
    createdDialogs = await db
      .insert(dialogs)
      .values(
        missingUserIds.map((userId) => ({
          chatId: input.chat.id,
          userId,
          spaceId: input.chat.spaceId ?? null,
          ...dialogOpenDefaultsForChat(input.chat),
          ...(input.chatListHidden === true ? { chatListHidden: true } : {}),
        })),
      )
      .onConflictDoNothing()
      .returning()
  }

  return {
    dialogs: [...existingDialogs, ...createdDialogs],
    createdDialogs,
  }
}

export async function promoteLinkedSubthreadDialogsToChatList(input: {
  chat: Pick<DbChat, "id" | "spaceId" | "type">
  userIds: number[]
}): Promise<{ dialogs: DbDialog[]; activatedDialogs: DbDialog[] }> {
  const activeUserIds = await UsersModel.getActiveUserIds(
    Array.from(new Set(input.userIds.filter((userId) => Number.isSafeInteger(userId) && userId > 0))),
  )

  if (activeUserIds.length === 0) {
    return { dialogs: [], activatedDialogs: [] }
  }

  const existingDialogs = await db
    .select()
    .from(dialogs)
    .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, activeUserIds)))

  const hiddenDialogUserIds = existingDialogs
    .filter((dialog) => dialog.chatListHidden)
    .map((dialog) => dialog.userId)
  const existingUserIds = new Set(existingDialogs.map((dialog) => dialog.userId))
  const missingUserIds = activeUserIds.filter((userId) => !existingUserIds.has(userId))

  let promotedDialogs: DbDialog[] = []
  if (hiddenDialogUserIds.length > 0) {
    promotedDialogs = await db
      .update(dialogs)
      .set({ chatListHidden: null })
      .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, hiddenDialogUserIds)))
      .returning()
  }

  let createdDialogs: DbDialog[] = []
  if (missingUserIds.length > 0) {
    createdDialogs = await db
      .insert(dialogs)
      .values(
        missingUserIds.map((userId) => ({
          chatId: input.chat.id,
          userId,
          spaceId: input.chat.spaceId ?? null,
          ...dialogOpenDefaultsForChat(input.chat),
        })),
      )
      .onConflictDoNothing()
      .returning()
  }

  const dialogsByUserId = new Map<number, DbDialog>()
  existingDialogs.forEach((dialog) => dialogsByUserId.set(dialog.userId, dialog))
  promotedDialogs.forEach((dialog) => dialogsByUserId.set(dialog.userId, dialog))
  createdDialogs.forEach((dialog) => dialogsByUserId.set(dialog.userId, dialog))

  return {
    dialogs: Array.from(dialogsByUserId.values()),
    activatedDialogs: [...promotedDialogs, ...createdDialogs],
  }
}

export async function showAndOpenLinkedSubthreadDialogs(input: {
  chat: Pick<DbChat, "id" | "spaceId" | "type" | "minUserId" | "maxUserId" | "parentChatId" | "parentMessageId">
  userIds: number[]
}): Promise<{ dialogs: DbDialog[]; changedDialogs: DbDialog[] }> {
  const { dialogs: openedDialogs, changedDialogs: openChangedDialogs } = await setDialogOpenForUsers({
    chat: input.chat,
    userIds: input.userIds,
    open: true,
    showInChatList: false,
  })

  const { activatedDialogs } = await promoteLinkedSubthreadDialogsToChatList({
    chat: input.chat,
    userIds: input.userIds,
  })

  const dialogsByUserId = new Map(openedDialogs.map((dialog) => [dialog.userId, dialog]))
  activatedDialogs.forEach((dialog) => dialogsByUserId.set(dialog.userId, dialog))

  const changedUserIds = new Set([
    ...activatedDialogs.map((dialog) => dialog.userId),
    ...openChangedDialogs.map((dialog) => dialog.userId),
  ])

  return {
    dialogs: Array.from(dialogsByUserId.values()),
    changedDialogs: Array.from(changedUserIds)
      .map((userId) => dialogsByUserId.get(userId))
      .filter((dialog): dialog is DbDialog => dialog != null),
  }
}

export type MessageThreadProjection = {
  subthread: MessageSubthread
  replies?: MessageReplies
}

type ChildThreadProjection = {
  chatId: number
  parentChatId: number
  parentMessageId: number
  kind: MessageSubthread_Kind.REPLY | MessageSubthread_Kind.SUBTHREAD
  title: string | null
  isUntitled: boolean | null
  autoTitleGenerated: boolean | null
  anchorMessage?: ReplyThreadTitleAnchor
}

type StoredReplyThreadAnchor = {
  text: DbMessage["text"]
  textEncrypted: DbMessage["textEncrypted"]
  textIv: DbMessage["textIv"]
  textTag: DbMessage["textTag"]
}

type ThreadActivity = {
  messageCount: number
  hasUnread: boolean
  recentAuthorUserIds: bigint[]
}

export async function getMessageThreadProjectionsMap(input: {
  parentChatId: number
  parentMessageIds: number[]
  userId: number
  tx?: Transaction
}): Promise<Map<number, MessageThreadProjection>> {
  const uniqueParentMessageIds = Array.from(new Set(input.parentMessageIds.filter((messageId) => messageId > 0)))
  if (uniqueParentMessageIds.length === 0) {
    return new Map()
  }

  const projections = await getMessageThreadProjectionsByParent({
    parentMessages: uniqueParentMessageIds.map((messageId) => ({
      chatId: input.parentChatId,
      messageId,
    })),
    userId: input.userId,
    tx: input.tx,
  })

  return projections.get(input.parentChatId) ?? new Map()
}

export async function getMessageThreadProjectionsByParent(input: {
  parentMessages: { chatId: number; messageId: number }[]
  userId: number
  tx?: Transaction
}): Promise<Map<number, Map<number, MessageThreadProjection>>> {
  const parentMessages = Array.from(
    new Map(
      input.parentMessages
        .filter(({ chatId, messageId }) => chatId > 0 && messageId > 0)
        .map((message) => [`${message.chatId}:${message.messageId}`, message]),
    ).values(),
  )
  const projectionsByParent = new Map<number, Map<number, MessageThreadProjection>>()
  if (parentMessages.length === 0) {
    return projectionsByParent
  }

  const query = input.tx ?? db
  const replyParentFilter = or(...parentMessages.map(({ chatId, messageId }) => and(
    eq(chats.parentChatId, chatId),
    eq(chats.parentMessageId, messageId),
  )))
  const placedParentFilter = or(...parentMessages.map(({ chatId, messageId }) => and(
    eq(messages.chatId, chatId),
    eq(messages.messageId, messageId),
  )))

  const replyThreads = await query
    .select({
      chatId: chats.id,
      parentChatId: chats.parentChatId,
      parentMessageId: chats.parentMessageId,
      title: chats.title,
      isUntitled: chats.isUntitled,
      autoTitleGenerated: chats.autoTitleGenerated,
      anchorText: messages.text,
      anchorTextEncrypted: messages.textEncrypted,
      anchorTextIv: messages.textIv,
      anchorTextTag: messages.textTag,
    })
    .from(chats)
    .leftJoin(messages, and(eq(messages.chatId, chats.parentChatId), eq(messages.messageId, chats.parentMessageId)))
    .where(replyParentFilter)

  const placedSubthreads = await query
    .select({
      chatId: chats.id,
      parentChatId: messages.chatId,
      parentMessageId: messages.messageId,
      title: chats.title,
      isUntitled: chats.isUntitled,
      autoTitleGenerated: chats.autoTitleGenerated,
    })
    .from(subthreadParentMessages)
    .innerJoin(messages, eq(messages.globalId, subthreadParentMessages.parentMessageGlobalId))
    .innerJoin(chats, eq(chats.id, subthreadParentMessages.childChatId))
    .where(placedParentFilter)

  const childThreads: ChildThreadProjection[] = [
    ...replyThreads.flatMap((thread): ChildThreadProjection[] =>
      thread.parentChatId == null || thread.parentMessageId == null ? [] : [{
        chatId: thread.chatId,
        parentChatId: thread.parentChatId,
        parentMessageId: thread.parentMessageId,
        kind: MessageSubthread_Kind.REPLY,
        title: thread.title,
        isUntitled: thread.isUntitled,
        autoTitleGenerated: thread.autoTitleGenerated,
        anchorMessage: thread.isUntitled === true && thread.autoTitleGenerated == null
          ? {
              text: storedReplyThreadAnchorText({
                text: thread.anchorText,
                textEncrypted: thread.anchorTextEncrypted,
                textIv: thread.anchorTextIv,
                textTag: thread.anchorTextTag,
              }),
            }
          : undefined,
      }]),
    ...placedSubthreads.map((thread): ChildThreadProjection => ({
      ...thread,
      kind: MessageSubthread_Kind.SUBTHREAD,
    })),
  ]

  if (childThreads.length === 0) {
    return projectionsByParent
  }

  const activityByChatId = await getThreadActivityByChatId({
    chatIds: childThreads.map((thread) => thread.chatId),
    userId: input.userId,
    tx: input.tx,
  })

  for (const childThread of childThreads) {
    const activity = activityByChatId.get(childThread.chatId) ?? emptyThreadActivity
    const title = normalizedTitle(childThread.title)
    const subthread: MessageSubthread = {
      chatId: BigInt(childThread.chatId),
      kind: childThread.kind,
      title: childThread.kind === MessageSubthread_Kind.SUBTHREAD
        ? title ?? GENERIC_SUBTHREAD_TITLE
        : usableReplyThreadTitle(childThread),
      messageCount: activity.messageCount,
      hasUnread: activity.hasUnread,
      recentAuthorUserIds: activity.recentAuthorUserIds,
    }

    let parentProjections = projectionsByParent.get(childThread.parentChatId)
    if (!parentProjections) {
      parentProjections = new Map()
      projectionsByParent.set(childThread.parentChatId, parentProjections)
    }
    parentProjections.set(childThread.parentMessageId, {
      subthread,
      replies: childThread.kind === MessageSubthread_Kind.REPLY
        ? {
            chatId: subthread.chatId,
            replyCount: subthread.messageCount,
            hasUnread: subthread.hasUnread,
            recentReplierUserIds: subthread.recentAuthorUserIds,
          }
        : undefined,
    })
  }

  return projectionsByParent
}

export async function getMessageRepliesMap(input: {
  parentChatId: number
  parentMessageIds: number[]
  userId: number
}): Promise<Map<number, MessageReplies>> {
  const projections = await getMessageThreadProjectionsMap(input)
  return new Map(
    Array.from(projections.entries()).flatMap(([messageId, projection]) =>
      projection.replies ? [[messageId, projection.replies] as const] : []
    ),
  )
}

const GENERIC_SUBTHREAD_TITLE = "New subthread"
const emptyThreadActivity: ThreadActivity = {
  messageCount: 0,
  hasUnread: false,
  recentAuthorUserIds: [],
}

const normalizedTitle = (title: string | null): string | undefined => {
  const normalized = title?.trim()
  return normalized ? normalized : undefined
}

const storedReplyThreadAnchorText = (anchor: StoredReplyThreadAnchor): string | null => {
  if (anchor.textEncrypted && anchor.textIv && anchor.textTag) {
    return decryptMessage({
      encrypted: anchor.textEncrypted,
      iv: anchor.textIv,
      authTag: anchor.textTag,
    })
  }

  return anchor.text
}

const usableReplyThreadTitle = (thread: ChildThreadProjection): string | undefined => {
  const title = normalizedTitle(thread.title)
  if (!title) {
    return undefined
  }

  if (thread.autoTitleGenerated === true || thread.isUntitled !== true) {
    return title
  }

  if (thread.autoTitleGenerated === false) {
    return undefined
  }

  // Pre-completion-bit rows can only be classified against their exact anchor placeholder.
  return isDefaultReplyThreadTitle(title, thread.anchorMessage) ? undefined : title
}

async function getThreadActivityByChatId(input: {
  chatIds: number[]
  userId: number
  tx?: Transaction
}): Promise<Map<number, ThreadActivity>> {
  const chatIds = Array.from(new Set(input.chatIds))
  const activityByChatId = new Map<number, ThreadActivity>()
  if (chatIds.length === 0) {
    return activityByChatId
  }

  const query = input.tx ?? db
  const replyCounts = await query
    .select({
      chatId: messages.chatId,
      replyCount: sql<number>`count(*)::int`,
    })
    .from(messages)
    .where(inArray(messages.chatId, chatIds))
    .groupBy(messages.chatId)

  const replyCountByChatId = new Map(replyCounts.map((row) => [row.chatId, row.replyCount]))

  const unreadCounts = await DialogsModel.getBatchUnreadCounts({
    userId: input.userId,
    chatIds,
    tx: input.tx,
  })
  const unreadCountByChatId = new Map(unreadCounts.map((row) => [row.chatId, row.unreadCount]))

  const unreadMarks = await query
    .select({
      chatId: dialogs.chatId,
      unreadMark: dialogs.unreadMark,
    })
    .from(dialogs)
    .where(and(eq(dialogs.userId, input.userId), inArray(dialogs.chatId, chatIds)))

  const unreadMarkByChatId = new Map(unreadMarks.map((row) => [row.chatId, row.unreadMark === true]))

  const recentReplierRows = await query.execute<{ chatId: number; fromId: number }>(sql`
    with distinct_recent_repliers as (
      select distinct on (${messages.chatId}, ${messages.fromId})
        ${messages.chatId} as "chatId",
        ${messages.fromId} as "fromId",
        ${messages.messageId} as "messageId"
      from ${messages}
      where ${inArray(messages.chatId, chatIds)}
      order by ${messages.chatId}, ${messages.fromId}, ${messages.messageId} desc
    ),
    ranked_recent_repliers as (
      select
        "chatId",
        "fromId",
        row_number() over (partition by "chatId" order by "messageId" desc) as "rank"
      from distinct_recent_repliers
    )
    select
      "chatId",
      "fromId"
    from ranked_recent_repliers
    where "rank" <= ${RECENT_AUTHOR_LIMIT}
    order by "chatId", "rank"
  `)

  const recentReplierIdsByChatId = new Map<number, bigint[]>()
  for (const row of recentReplierRows) {
    const existing = recentReplierIdsByChatId.get(row.chatId) ?? []
    if (existing.length >= RECENT_AUTHOR_LIMIT) {
      continue
    }
    existing.push(BigInt(row.fromId))
    recentReplierIdsByChatId.set(row.chatId, existing)
  }

  for (const chatId of chatIds) {
    activityByChatId.set(chatId, {
      messageCount: replyCountByChatId.get(chatId) ?? 0,
      hasUnread:
        (unreadCountByChatId.get(chatId) ?? 0) > 0 ||
        unreadMarkByChatId.get(chatId) === true,
      recentAuthorUserIds: recentReplierIdsByChatId.get(chatId) ?? [],
    })
  }

  return activityByChatId
}

export async function getDirectParticipantUserIds(chatId: number): Promise<number[]> {
  return resolveDirectParticipantUserIds(chatId)
}

export async function getTopLevelAccessUserIds(chat: DbChat): Promise<number[]> {
  return resolveTopLevelAccessUserIds(chat)
}

export async function getInheritedAccessUserIds(chat: DbChat): Promise<number[]> {
  return resolveInheritedAccessUserIds(chat)
}

export async function getEffectiveAccessUserIds(chat: DbChat): Promise<number[]> {
  return resolveEffectiveAccessUserIds(chat)
}

export async function persistMessageRepliesUpdate(input: {
  parentChatId: number
  parentMessageId: number
}): Promise<UpdateSeqAndDate> {
  const updatePayload: ServerUpdate["update"] = {
    oneofKind: "editMessage",
    editMessage: {
      chatId: BigInt(input.parentChatId),
      msgId: BigInt(input.parentMessageId),
    },
  }

  return db.transaction(async (tx): Promise<UpdateSeqAndDate> => {
    const [parentChat] = await tx.select().from(chats).where(eq(chats.id, input.parentChatId)).for("update").limit(1)

    if (!parentChat) {
      throw RealtimeRpcError.ChatIdInvalid()
    }

    const update = await UpdatesModel.insertUpdate(tx, {
      update: updatePayload,
      bucket: UpdateBucket.Chat,
      entity: parentChat,
    })

    await tx
      .update(chats)
      .set({
        updateSeq: update.seq,
        lastUpdateDate: update.date,
      })
      .where(eq(chats.id, input.parentChatId))

    return update
  })
}

export async function pushMessageRepliesUpdate(input: {
  parentChatId: number
  parentMessageId: number
  currentUserId: number
  update: UpdateSeqAndDate
}): Promise<void> {
  const [parentChat, parentMessage] = await Promise.all([
    getChatById(input.parentChatId),
    MessageModel.getMessagesByIds(input.parentChatId, [BigInt(input.parentMessageId)]).then((rows) => rows[0]),
  ])

  if (!parentChat || !parentMessage) {
    return
  }

  const updateGroup = await getUpdateGroup({ threadId: input.parentChatId }, { currentUserId: input.currentUserId })

  for (const userId of updateGroup.userIds) {
    const threadProjection = (
      await getMessageThreadProjectionsMap({
        parentChatId: input.parentChatId,
        parentMessageIds: [input.parentMessageId],
        userId,
      })
    ).get(input.parentMessageId)

    const editMessageUpdate: Update = {
      seq: input.update.seq,
      date: encodeDateStrict(input.update.date),
      update: {
        oneofKind: "editMessage",
        editMessage: {
          message: Encoders.fullMessage({
            message: parentMessage,
            encodingForUserId: userId,
            encodingForPeer: {
              inputPeer: encodePeerFromChat(parentChat, { currentUserId: userId }),
            },
            replies: threadProjection?.replies,
            subthread: threadProjection?.subthread,
          }),
        },
      },
    }

    RealtimeUpdates.pushToUser(userId, [editMessageUpdate])
  }
}

export type SubthreadParentMessageRef = {
  parentChatId: number
  parentMessageId: number
}

export async function getSubthreadParentMessageRef(
  childChatId: number,
): Promise<SubthreadParentMessageRef | undefined> {
  const [row] = await db
    .select({
      parentChatId: messages.chatId,
      parentMessageId: messages.messageId,
    })
    .from(subthreadParentMessages)
    .innerJoin(messages, eq(messages.globalId, subthreadParentMessages.parentMessageGlobalId))
    .where(eq(subthreadParentMessages.childChatId, childChatId))
    .limit(1)

  return row
}

export async function isSubthreadParentMessage(globalId: bigint): Promise<boolean> {
  const [row] = await db
    .select({ childChatId: subthreadParentMessages.childChatId })
    .from(subthreadParentMessages)
    .where(eq(subthreadParentMessages.parentMessageGlobalId, globalId))
    .limit(1)
  return row != null
}

export async function emitMessageSubthreadUpdateIfNeeded(input: {
  chatId: number
  currentUserId: number
}): Promise<void> {
  const chat = await getChatById(input.chatId)
  if (!chat || chat.parentChatId == null) {
    return
  }

  const parentMessage = chat.parentMessageId != null
    ? { parentChatId: chat.parentChatId, parentMessageId: chat.parentMessageId }
    : await getSubthreadParentMessageRef(chat.id)

  if (!parentMessage) {
    return
  }

  const update = await persistMessageRepliesUpdate({
    parentChatId: parentMessage.parentChatId,
    parentMessageId: parentMessage.parentMessageId,
  })

  await pushMessageRepliesUpdate({
    parentChatId: parentMessage.parentChatId,
    parentMessageId: parentMessage.parentMessageId,
    currentUserId: input.currentUserId,
    update,
  })
}

export function queueSubthreadParentUpdate(input: {
  chatId: number
  currentUserId: number
  reason: string
}): void {
  queueMicrotask(() => {
    void emitMessageSubthreadUpdateIfNeeded(input).catch((error) => {
      log.warn("Failed to refresh subthread parent card", {
        chatId: input.chatId,
        reason: input.reason,
        error,
      })
    })
  })
}

export const emitReplyThreadParentRepliesUpdateIfNeeded = emitMessageSubthreadUpdateIfNeeded

export async function emitChatListOpenUpdates(input: {
  chat: DbChat
  dialogs: DbDialog[]
  skipSessionId?: number
}): Promise<void> {
  // The caller's DbDialog is a post-commit snapshot and may already be stale.
  // Use it only to identify affected users; the projection transaction below
  // locks users, rereads dialogs, and enqueues the authoritative snapshot.
  const userIds = Array.from(new Set(input.dialogs.map((dialog) => dialog.userId))).sort((a, b) => a - b)
  if (userIds.length === 0) {
    return
  }

  // Permission encoding may query related data, so keep it outside the row
  // lock. The dialog itself is always reread and encoded inside the owner tx.
  const chatsByUserId = await Encoders.chatForUsers(input.chat, userIds)
  const projection = await db.transaction(async (tx) => {
    // All callers use this users -> dialogs order. Lock each user explicitly
    // so multi-user batches acquire owners deterministically.
    for (const userId of userIds) {
      await tx.select({ id: users.id }).from(users).where(eq(users.id, userId)).for("update").limit(1)
    }

    const freshDialogs = await tx
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, userIds)))
    const visibleDialogs = freshDialogs.filter((dialog) => !dialog.chatListHidden)
    const preparedUpdates = await Promise.all(
      visibleDialogs.map(async (dialog) => {
        const unreadCount = await DialogsModel.getUnreadCount(dialog.chatId, dialog.userId, tx)
        return {
          dialog,
          chat: chatsByUserId.get(dialog.userId),
          encodedDialog: Encoders.dialog(dialog, { unreadCount }),
        }
      }),
    )

    const userUpdates = await UserBucketUpdates.enqueueMany(
      preparedUpdates.map((prepared) => ({
        userId: prepared.dialog.userId,
        update: {
          oneofKind: "userChatOpen" as const,
          userChatOpen: {
            chat: prepared.chat,
            dialog: prepared.encodedDialog,
          },
        },
      })),
      { tx },
    )

    return { preparedUpdates, userUpdates }
  })

  projection.preparedUpdates.forEach((prepared, index) => {
    const persisted = projection.userUpdates[index]
    if (!persisted) {
      return
    }

    const pushOptions = input.skipSessionId !== undefined ? { skipSessionId: input.skipSessionId } : undefined

    RealtimeUpdates.pushToUser(
      prepared.dialog.userId,
      [
        {
          seq: persisted.seq,
          date: encodeDateStrict(persisted.date),
          update: {
            oneofKind: "chatOpen",
            chatOpen: {
              chat: prepared.chat,
              dialog: prepared.encodedDialog,
            },
          },
        },
      ],
      pushOptions,
    )
  })
}
