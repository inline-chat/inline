import { db } from "@in/server/db"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { MessageModel, type DbFullMessage } from "@in/server/db/models/messages"
import { chatParticipants, chats, dialogs, members, messages, type DbChat, type DbDialog } from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { getUpdateGroup } from "@in/server/modules/updates"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { encodePeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import type { MessageReplies, Update } from "@inline-chat/protocol/core"
import { and, eq, inArray, sql } from "drizzle-orm"

export const isLinkedSubthread = (chat: Pick<DbChat, "parentChatId">): boolean => chat.parentChatId != null

export const isReplyThread = (chat: Pick<DbChat, "parentMessageId">): boolean => chat.parentMessageId != null

const RECENT_REPLIER_LIMIT = 3

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

export function buildDefaultReplyThreadTitle(anchorMessage: DbFullMessage | undefined): string {
  const excerpt = anchorMessage?.text?.trim().replace(/\s+/g, " ").slice(0, 72)
  if (excerpt && excerpt.length > 0) {
    return `Re: ${excerpt}`
  }

  return "Re: Message"
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
  chat: Pick<DbChat, "id" | "spaceId">
  userIds: number[]
  sidebarVisible: boolean
}): Promise<{ dialogs: DbDialog[]; createdDialogs: DbDialog[] }> {
  const uniqueUserIds = Array.from(
    new Set(input.userIds.filter((userId) => Number.isSafeInteger(userId) && userId > 0)),
  )

  if (uniqueUserIds.length === 0) {
    return { dialogs: [], createdDialogs: [] }
  }

  const existingDialogs = await db
    .select()
    .from(dialogs)
    .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, uniqueUserIds)))

  const existingUserIds = new Set(existingDialogs.map((dialog) => dialog.userId))
  const missingUserIds = uniqueUserIds.filter((userId) => !existingUserIds.has(userId))

  let createdDialogs: DbDialog[] = []
  if (missingUserIds.length > 0) {
    createdDialogs = await db
      .insert(dialogs)
      .values(
        missingUserIds.map((userId) => ({
          chatId: input.chat.id,
          userId,
          spaceId: input.chat.spaceId ?? null,
          sidebarVisible: input.sidebarVisible,
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

export async function promoteLinkedSubthreadDialogsToSidebar(input: {
  chat: Pick<DbChat, "id" | "spaceId">
  userIds: number[]
}): Promise<{ dialogs: DbDialog[]; activatedDialogs: DbDialog[] }> {
  const uniqueUserIds = Array.from(
    new Set(input.userIds.filter((userId) => Number.isSafeInteger(userId) && userId > 0)),
  )

  if (uniqueUserIds.length === 0) {
    return { dialogs: [], activatedDialogs: [] }
  }

  const existingDialogs = await db
    .select()
    .from(dialogs)
    .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, uniqueUserIds)))

  const hiddenDialogUserIds = existingDialogs
    .filter((dialog) => dialog.sidebarVisible === false)
    .map((dialog) => dialog.userId)
  const existingUserIds = new Set(existingDialogs.map((dialog) => dialog.userId))
  const missingUserIds = uniqueUserIds.filter((userId) => !existingUserIds.has(userId))

  let promotedDialogs: DbDialog[] = []
  if (hiddenDialogUserIds.length > 0) {
    promotedDialogs = await db
      .update(dialogs)
      .set({ sidebarVisible: true })
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
          sidebarVisible: true,
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

export async function getMessageRepliesMap(input: {
  parentChatId: number
  parentMessageIds: number[]
  userId: number
}): Promise<Map<number, MessageReplies>> {
  const uniqueParentMessageIds = Array.from(new Set(input.parentMessageIds.filter((messageId) => messageId > 0)))
  const repliesMap = new Map<number, MessageReplies>()

  if (uniqueParentMessageIds.length === 0) {
    return repliesMap
  }

  const childThreads = await db
    .select({
      chatId: chats.id,
      parentMessageId: chats.parentMessageId,
    })
    .from(chats)
    .where(
      and(
        eq(chats.parentChatId, input.parentChatId),
        inArray(chats.parentMessageId, uniqueParentMessageIds),
      ),
    )

  if (childThreads.length === 0) {
    return repliesMap
  }

  const chatIds = childThreads.map((thread) => thread.chatId)

  const replyCounts = await db
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
  })
  const unreadCountByChatId = new Map(unreadCounts.map((row) => [row.chatId, row.unreadCount]))

  const unreadMarks = await db
    .select({
      chatId: dialogs.chatId,
      unreadMark: dialogs.unreadMark,
    })
    .from(dialogs)
    .where(and(eq(dialogs.userId, input.userId), inArray(dialogs.chatId, chatIds)))

  const unreadMarkByChatId = new Map(unreadMarks.map((row) => [row.chatId, row.unreadMark === true]))

  const recentReplierRows = await db.execute<{ chatId: number; fromId: number }>(sql`
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
    where "rank" <= ${RECENT_REPLIER_LIMIT}
    order by "chatId", "rank"
  `)

  const recentReplierIdsByChatId = new Map<number, bigint[]>()
  for (const row of recentReplierRows) {
    const existing = recentReplierIdsByChatId.get(row.chatId) ?? []
    if (existing.length >= RECENT_REPLIER_LIMIT) {
      continue
    }
    existing.push(BigInt(row.fromId))
    recentReplierIdsByChatId.set(row.chatId, existing)
  }

  for (const childThread of childThreads) {
    if (childThread.parentMessageId == null) {
      continue
    }

    repliesMap.set(childThread.parentMessageId, {
      chatId: BigInt(childThread.chatId),
      replyCount: replyCountByChatId.get(childThread.chatId) ?? 0,
      hasUnread:
        (unreadCountByChatId.get(childThread.chatId) ?? 0) > 0 ||
        unreadMarkByChatId.get(childThread.chatId) === true,
      recentReplierUserIds: recentReplierIdsByChatId.get(childThread.chatId) ?? [],
    })
  }

  return repliesMap
}

export async function getDirectParticipantUserIds(chatId: number): Promise<number[]> {
  const participants = await db
    .select({ userId: chatParticipants.userId })
    .from(chatParticipants)
    .where(eq(chatParticipants.chatId, chatId))

  return participants.map((participant) => participant.userId)
}

export async function getTopLevelAccessUserIds(chat: DbChat): Promise<number[]> {
  if (chat.type === "private") {
    if (chat.minUserId == null || chat.maxUserId == null) {
      return []
    }

    if (chat.minUserId === chat.maxUserId) {
      return [chat.minUserId]
    }

    return [chat.minUserId, chat.maxUserId]
  }

  if (chat.spaceId == null) {
    return getDirectParticipantUserIds(chat.id)
  }

  if (chat.publicThread) {
    const publicMembers = await db
      .select({ userId: members.userId })
      .from(members)
      .where(and(eq(members.spaceId, chat.spaceId), eq(members.canAccessPublicChats, true)))

    return publicMembers.map((member) => member.userId)
  }

  return getDirectParticipantUserIds(chat.id)
}

export async function getInheritedAccessUserIds(chat: DbChat): Promise<number[]> {
  if (chat.parentChatId == null) {
    return getTopLevelAccessUserIds(chat)
  }

  const parentChat = await getChatById(chat.parentChatId)
  if (!parentChat) {
    return []
  }

  return getInheritedAccessUserIds(parentChat)
}

export async function getEffectiveAccessUserIds(chat: DbChat): Promise<number[]> {
  const [directUserIds, inheritedUserIds] = await Promise.all([
    getDirectParticipantUserIds(chat.id),
    getInheritedAccessUserIds(chat),
  ])

  return Array.from(new Set([...directUserIds, ...inheritedUserIds]))
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
    const replies = (
      await getMessageRepliesMap({
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
            replies,
          }),
        },
      },
    }

    RealtimeUpdates.pushToUser(userId, [editMessageUpdate])
  }
}

export async function emitReplyThreadParentRepliesUpdateIfNeeded(input: {
  chatId: number
  currentUserId: number
}): Promise<void> {
  const chat = await getChatById(input.chatId)
  if (!chat || chat.parentChatId == null || chat.parentMessageId == null) {
    return
  }

  const update = await persistMessageRepliesUpdate({
    parentChatId: chat.parentChatId,
    parentMessageId: chat.parentMessageId,
  })

  await pushMessageRepliesUpdate({
    parentChatId: chat.parentChatId,
    parentMessageId: chat.parentMessageId,
    currentUserId: input.currentUserId,
    update,
  })
}

export async function emitSidebarChatOpenUpdates(input: {
  chat: DbChat
  dialogs: DbDialog[]
}): Promise<void> {
  const uniqueDialogs = Array.from(
    new Map(
      input.dialogs
        .filter((dialog) => dialog.sidebarVisible)
        .map((dialog) => [dialog.userId, dialog]),
    ).values(),
  )

  if (uniqueDialogs.length === 0) {
    return
  }

  const preparedUpdates = await Promise.all(
    uniqueDialogs.map(async (dialog) => {
      const unreadCount = await DialogsModel.getUnreadCount(dialog.chatId, dialog.userId)
      return {
        dialog,
        unreadCount,
        chat: Encoders.chat(input.chat, { encodingForUserId: dialog.userId }),
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
  )

  preparedUpdates.forEach((prepared, index) => {
    const persisted = userUpdates[index]
    if (!persisted) {
      return
    }

    RealtimeUpdates.pushToUser(prepared.dialog.userId, [
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
    ])
  })
}
