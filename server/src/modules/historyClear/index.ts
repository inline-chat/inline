import type { InputPeer, Update } from "@inline-chat/protocol/core"
import type { ServerUpdate } from "@in/server/protocol/server"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { chats, members, spaces, users, type DbChat } from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { Transaction } from "@in/server/db/types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { persistChatMetadataUpdates, type ChatMetadataUpdate } from "@in/server/modules/chatMetadataUpdates"
import { pushChatMetadataUpdates } from "@in/server/modules/chatMetadataUpdatePush"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { emitReplyThreadParentRepliesUpdateIfNeeded } from "@in/server/modules/subthreads"
import {
  deleteBacklinkMessages,
  getBacklinkMessagesForClearedChatMessages,
  getBacklinkMessagesForClearedSpaceMessages,
} from "@in/server/modules/threadGraph"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import { and, eq, inArray } from "drizzle-orm"
import {
  clearChatHistoryData,
  clearSpaceHistoryData,
  planClearChatHistoryData,
  planClearSpaceHistoryData,
  type ClearChatHistoryPlan,
  type ClearHistoryAccessLoss,
  type ClearHistoryDeletedChat,
  type ClearHistorySideEffects,
  type ClearSpaceHistoryPlan,
} from "./data"

type ClearHistoryOptions = {
  keepLastDays: number
  deleteReplyThreads: boolean
}

export type ClearHistoryInput =
  | (ClearHistoryOptions & {
      peer: InputPeer
      spaceId?: never
    })
  | (ClearHistoryOptions & {
      spaceId: number
      peer?: never
    })

export type ClearHistoryContext = {
  currentUserId: number
  currentSessionId?: number
}

export type ClearHistoryOutput = {
  updates: Update[]
}

type Cutoff = {
  date: Date
  seconds: bigint
}

type ClearHistoryUpdate = {
  inputPeer: InputPeer
  update: UpdateSeqAndDate
  beforeDate?: bigint
  deleteReplyThreads: boolean
  sideEffects: ClearHistorySideEffects
}

type DeletedChatUpdate = ClearHistoryDeletedChat & {
  update: UpdateSeqAndDate
  accessUpdates: { userId: number; update: UpdateSeqAndDate }[]
}

type RemovedChatAccessUpdate = {
  chatId: number
  userId: number
  update: UpdateSeqAndDate
}

const MAX_KEEP_LAST_DAYS = 36_500
const DAY_SECONDS = 24 * 60 * 60
const MAX_CLEAR_HISTORY_PLAN_ATTEMPTS = 3

const log = new Log("modules.historyClear")

class ClearHistoryPlanChanged extends Error {
  constructor() {
    super("History clear plan changed while locking mutation owners")
  }
}

export const clearChatHistory = async (
  input: ClearHistoryInput,
  context: ClearHistoryContext,
): Promise<ClearHistoryOutput> => {
  const cutoff = resolveCutoff(input.keepLastDays)
  const deleteReplyThreads = Boolean(input.deleteReplyThreads)

  if (input.spaceId != null) {
    return clearSpaceHistory({
      spaceId: input.spaceId,
      cutoff,
      deleteReplyThreads,
      context,
    })
  }

  return clearPeerHistory({
    peer: input.peer,
    cutoff,
    deleteReplyThreads,
    context,
  })
}

async function clearPeerHistory(input: {
  peer: InputPeer
  cutoff: Cutoff | undefined
  deleteReplyThreads: boolean
  context: ClearHistoryContext
}): Promise<ClearHistoryOutput> {
  const chat = await ChatModel.getChatFromInputPeer(input.peer, input.context)

  await ensureCanClearHistory(chat, input.context.currentUserId)
  const backlinkMessages = await getBacklinkMessagesForClearedChatMessages({
    chatId: chat.id,
    beforeDate: input.cutoff?.date,
  })
  const planInput = {
    chatId: chat.id,
    beforeDate: input.cutoff?.date,
    deleteReplyThreads: input.deleteReplyThreads,
  }
  let expectedPlan = await db.transaction((tx) => planClearChatHistoryData(tx, planInput))
  let committed: Awaited<ReturnType<typeof clearLockedChatHistory>> | undefined

  for (let attempt = 0; attempt < MAX_CLEAR_HISTORY_PLAN_ATTEMPTS; attempt += 1) {
    try {
      committed = await db.transaction(async (tx) => {
        const lockedUserIds = uniqueSortedUserIds([
          ...expectedPlan.recipientUserIds,
          input.context.currentUserId,
        ])
        const lockedUsers = await tx
          .select({ id: users.id, deleted: users.deleted })
          .from(users)
          .where(inArray(users.id, lockedUserIds))
          .orderBy(users.id)
          .for("update", { noWait: true })
        const actor = lockedUsers.find((user) => user.id === input.context.currentUserId)
        if (!actor || actor.deleted === true) {
          throw RealtimeRpcError.Unauthenticated()
        }

        const lockedChats = await tx
          .select()
          .from(chats)
          .where(inArray(chats.id, expectedPlan.affectedChatIds))
          .orderBy(chats.id)
          .for("update", { noWait: true })
        const lockedChat = lockedChats.find((item) => item.id === chat.id)
        if (!lockedChat) {
          throw RealtimeRpcError.ChatIdInvalid()
        }

        await ensureCanClearHistory(lockedChat, input.context.currentUserId, tx)
        const lockedPlan = await planClearChatHistoryData(tx, planInput)
        if (!sameClearHistoryPlan(expectedPlan, lockedPlan)) {
          throw new ClearHistoryPlanChanged()
        }

        return clearLockedChatHistory({
          tx,
          chat: lockedChat,
          cutoff: input.cutoff,
          deleteReplyThreads: input.deleteReplyThreads,
          lockedUserIds: new Set(lockedUserIds),
        })
      })
      break
    } catch (error) {
      const resourceBusy = isResourceLockUnavailable(error)
      if (!(error instanceof ClearHistoryPlanChanged) && !resourceBusy) throw error
      if (attempt + 1 === MAX_CLEAR_HISTORY_PLAN_ATTEMPTS) {
        throw RealtimeRpcError.InternalError()
      }
      if (resourceBusy) {
        await Bun.sleep(50 * (attempt + 1) + Math.floor(Math.random() * 50))
      }
      expectedPlan = await db.transaction((tx) => planClearChatHistoryData(tx, planInput))
    }
  }

  if (!committed) throw RealtimeRpcError.InternalError()
  const { clearUpdate, sideEffects, metadataChatUpdates, deletedChatUpdates, removedAccessUpdates } = committed

  const { selfUpdates } = await pushClearHistoryUpdates({
    currentUserId: input.context.currentUserId,
    clearUpdates: [
      {
        inputPeer: input.peer,
        update: clearUpdate,
        beforeDate: input.cutoff?.seconds,
        deleteReplyThreads: input.deleteReplyThreads,
        sideEffects,
      },
    ],
  })

  const { selfUpdates: metadataSelfUpdates } = await pushChatMetadataUpdates({
    currentUserId: input.context.currentUserId,
    chatUpdates: metadataChatUpdates,
  })

  const { selfUpdates: deletedSelfUpdates } = await pushDeletedChatUpdates({
    currentUserId: input.context.currentUserId,
    chatUpdates: deletedChatUpdates,
  })

  const { selfUpdates: removedAccessSelfUpdates } = await pushRemovedChatAccessUpdates({
    currentUserId: input.context.currentUserId,
    chatUpdates: removedAccessUpdates,
  })

  await emitReplyThreadParentRepliesUpdateIfNeeded({
    chatId: chat.id,
    currentUserId: input.context.currentUserId,
  })

  const backlinkSelfUpdates = await deleteBacklinkMessages(backlinkMessages, {
    currentUserId: input.context.currentUserId,
  }).catch((error) => {
    log.error("Failed to delete backlink messages for cleared chat history", {
      chatId: chat.id,
      currentUserId: input.context.currentUserId,
      error,
    })
    return []
  })

  return {
    updates: [
      ...selfUpdates,
      ...metadataSelfUpdates,
      ...deletedSelfUpdates,
      ...removedAccessSelfUpdates,
      ...backlinkSelfUpdates,
    ],
  }
}

async function clearSpaceHistory(input: {
  spaceId: number
  cutoff: Cutoff | undefined
  deleteReplyThreads: boolean
  context: ClearHistoryContext
}): Promise<ClearHistoryOutput> {
  const spaceId = normalizeSpaceId(input.spaceId)
  await ensureCanClearSpaceHistory(spaceId, input.context.currentUserId)
  const backlinkMessages = await getBacklinkMessagesForClearedSpaceMessages({
    spaceId,
    beforeDate: input.cutoff?.date,
  })
  const planInput = {
    spaceId,
    beforeDate: input.cutoff?.date,
    deleteReplyThreads: input.deleteReplyThreads,
  }
  let expectedPlan = await db.transaction((tx) => planClearSpaceHistoryData(tx, planInput))
  let committed:
    | Awaited<ReturnType<typeof clearLockedSpaceHistory>> & { clearHistoryUpdates: ClearHistoryUpdate[] }
    | undefined

  for (let attempt = 0; attempt < MAX_CLEAR_HISTORY_PLAN_ATTEMPTS; attempt += 1) {
    try {
      committed = await db.transaction(async (tx) => {
        const lockedUserIds = uniqueSortedUserIds([
          ...expectedPlan.recipientUserIds,
          input.context.currentUserId,
        ])
        if (lockedUserIds.length > 0) {
          const lockedUsers = await tx
            .select({ id: users.id, deleted: users.deleted })
            .from(users)
            .where(inArray(users.id, lockedUserIds))
            .orderBy(users.id)
            .for("update")
          const actor = lockedUsers.find((user) => user.id === input.context.currentUserId)
          if (!actor || actor.deleted === true) {
            throw RealtimeRpcError.Unauthenticated()
          }
        }

        // Existing chat/space-first writers can later allocate user sequences.
        // Never wait on their resources while holding the planned user owners:
        // yield this entire transaction and retry instead of creating a cycle.
        const [lockedSpace] = await tx.select().from(spaces).where(eq(spaces.id, spaceId)).for("update", { noWait: true }).limit(1)
        if (!lockedSpace || lockedSpace.deleted !== null) {
          throw RealtimeRpcError.SpaceIdInvalid()
        }

        const [actorMembership] = await tx
          .select({ role: members.role })
          .from(members)
          .where(and(eq(members.spaceId, spaceId), eq(members.userId, input.context.currentUserId)))
          .for("update")
          .limit(1)
        if (actorMembership?.role !== "admin" && actorMembership?.role !== "owner") {
          throw RealtimeRpcError.SpaceAdminRequired()
        }

        if (expectedPlan.affectedChatIds.length > 0) {
          await tx
            .select({ id: chats.id })
            .from(chats)
            .where(inArray(chats.id, expectedPlan.affectedChatIds))
            .orderBy(chats.id)
            .for("update", { noWait: true })
        }

        const lockedPlan = await planClearSpaceHistoryData(tx, planInput)
        if (!sameClearHistoryPlan(expectedPlan, lockedPlan)) {
          throw new ClearHistoryPlanChanged()
        }

        const result = await clearLockedSpaceHistory({
          tx,
          spaceId,
          cutoff: input.cutoff,
          deleteReplyThreads: input.deleteReplyThreads,
          lockedUserIds: new Set(lockedUserIds),
        })

        return {
          ...result,
          clearHistoryUpdates: result.clearUpdates.map((clearUpdate) => ({
            inputPeer: {
              type: {
                oneofKind: "chat" as const,
                chat: { chatId: BigInt(clearUpdate.chat.id) },
              },
            },
            update: clearUpdate.update,
            beforeDate: input.cutoff?.seconds,
            deleteReplyThreads: input.deleteReplyThreads,
            sideEffects: emptyClearHistorySideEffects(),
          })),
        }
      })
      break
    } catch (error) {
      const resourceBusy = isResourceLockUnavailable(error)
      if (!(error instanceof ClearHistoryPlanChanged) && !resourceBusy) throw error
      if (attempt + 1 === MAX_CLEAR_HISTORY_PLAN_ATTEMPTS) {
        throw RealtimeRpcError.InternalError()
      }
      if (resourceBusy) {
        await Bun.sleep(50 * (attempt + 1) + Math.floor(Math.random() * 50))
      }
      // A late recipient can be discovered after a detach/delete has started.
      // Replan only after rollback, never from that partially mutated snapshot.
      expectedPlan = await db.transaction((tx) => planClearSpaceHistoryData(tx, planInput))
    }
  }

  if (!committed) throw RealtimeRpcError.InternalError()
  const { clearHistoryUpdates, metadataChatUpdates, deletedChatUpdates, removedAccessUpdates } = committed

  const { selfUpdates } = await pushClearHistoryUpdates({
    currentUserId: input.context.currentUserId,
    clearUpdates: clearHistoryUpdates,
  })

  const { selfUpdates: metadataSelfUpdates } = await pushChatMetadataUpdates({
    currentUserId: input.context.currentUserId,
    chatUpdates: metadataChatUpdates,
  })

  const { selfUpdates: deletedSelfUpdates } = await pushDeletedChatUpdates({
    currentUserId: input.context.currentUserId,
    chatUpdates: deletedChatUpdates,
  })

  const { selfUpdates: removedAccessSelfUpdates } = await pushRemovedChatAccessUpdates({
    currentUserId: input.context.currentUserId,
    chatUpdates: removedAccessUpdates,
  })

  const backlinkSelfUpdates = await deleteBacklinkMessages(backlinkMessages, {
    currentUserId: input.context.currentUserId,
  }).catch((error) => {
    log.error("Failed to delete backlink messages for cleared space history", {
      spaceId,
      currentUserId: input.context.currentUserId,
      error,
    })
    return []
  })

  return {
    updates: [
      ...selfUpdates,
      ...metadataSelfUpdates,
      ...deletedSelfUpdates,
      ...removedAccessSelfUpdates,
      ...backlinkSelfUpdates,
    ],
  }
}

async function clearLockedChatHistory(input: {
  tx: Transaction
  chat: DbChat
  cutoff: Cutoff | undefined
  deleteReplyThreads: boolean
  lockedUserIds: ReadonlySet<number>
}): Promise<{
  clearUpdate: UpdateSeqAndDate
  sideEffects: ClearHistorySideEffects
  metadataChatUpdates: ChatMetadataUpdate[]
  deletedChatUpdates: DeletedChatUpdate[]
  removedAccessUpdates: RemovedChatAccessUpdate[]
}> {
  let deletedChatUpdates: DeletedChatUpdate[] = []

  const result = await clearChatHistoryData(
    input.tx,
    {
      chatId: input.chat.id,
      beforeDate: input.cutoff?.date,
      deleteReplyThreads: input.deleteReplyThreads,
    },
    {
      beforeDeleteChats: async (deletedChats) => {
        ensurePlannedUsers(deletedChats.flatMap((chat) => chat.userIds), input.lockedUserIds)
        deletedChatUpdates = await persistDeletedChatUpdates(input.tx, deletedChats)
      },
    },
  )

  const updatePayload: ServerUpdate["update"] = {
    oneofKind: "clearChatHistory",
    clearChatHistory: {
      chatId: BigInt(input.chat.id),
      beforeDate: input.cutoff?.seconds,
      deleteReplyThreads: input.deleteReplyThreads,
      deletedChatIds: result.deletedChatIds.map(BigInt),
      orphanedChatIds: result.orphanedChatIds.map(BigInt),
      detachedChatIds: result.detachedChatIds.map(BigInt),
    },
  }

  const clearUpdate = await UpdatesModel.insertUpdate(input.tx, {
    update: updatePayload,
    bucket: UpdateBucket.Chat,
    entity: input.chat,
  })

  await input.tx
    .update(chats)
    .set({
      lastMsgId: result.lastMsgId,
      updateSeq: clearUpdate.seq,
      lastUpdateDate: clearUpdate.date,
    })
    .where(eq(chats.id, input.chat.id))

  const metadataChatUpdates = await persistChatMetadataUpdates(input.tx, result.orphanedChatIds)

  const removedAccessUpdates = await persistRemovedChatAccessUpdates(
    input.tx,
    result.detachedAccessLosses,
  )

  return { clearUpdate, sideEffects: result, metadataChatUpdates, deletedChatUpdates, removedAccessUpdates }
}

async function clearLockedSpaceHistory(input: {
  tx: Transaction
  spaceId: number
  cutoff: Cutoff | undefined
  deleteReplyThreads: boolean
  lockedUserIds: ReadonlySet<number>
}): Promise<{
  clearUpdates: { chat: DbChat; update: UpdateSeqAndDate }[]
  sideEffects: ClearHistorySideEffects
  metadataChatUpdates: ChatMetadataUpdate[]
  deletedChatUpdates: DeletedChatUpdate[]
  removedAccessUpdates: RemovedChatAccessUpdate[]
}> {
  let deletedChatUpdates: DeletedChatUpdate[] = []

  const result = await clearSpaceHistoryData(
    input.tx,
    {
      spaceId: input.spaceId,
      beforeDate: input.cutoff?.date,
      deleteReplyThreads: input.deleteReplyThreads,
    },
    {
      beforeDeleteChats: async (deletedChats) => {
        ensurePlannedUsers(deletedChats.flatMap((chat) => chat.userIds), input.lockedUserIds)
        deletedChatUpdates = await persistDeletedChatUpdates(input.tx, deletedChats)
      },
    },
  )

  const metadataChatUpdates = await persistChatMetadataUpdates(input.tx, [
    ...result.orphanedChatIds,
    ...result.detachedChatIds,
  ])
  const removedAccessUpdates = await persistRemovedChatAccessUpdates(
    input.tx,
    result.detachedAccessLosses.map((loss) => {
      ensurePlannedUsers(loss.userIds, input.lockedUserIds)
      return loss
    }),
  )

  const clearUpdates: { chat: DbChat; update: UpdateSeqAndDate }[] = []
  const survivingChats = await input.tx
    .select()
    .from(chats)
    .where(eq(chats.spaceId, input.spaceId))
    .orderBy(chats.id)

  // TODO(sync-v3-scale): Batch per-chat update insertion and cursor writes,
  // then batch recipient projection before large spaces make this admin path hot.
  for (const chat of survivingChats) {
    const update = await UpdatesModel.insertUpdate(input.tx, {
      update: {
        oneofKind: "clearChatHistory",
        clearChatHistory: {
          chatId: BigInt(chat.id),
          beforeDate: input.cutoff?.seconds,
          deleteReplyThreads: input.deleteReplyThreads,
          deletedChatIds: [],
          orphanedChatIds: [],
          detachedChatIds: [],
        },
      },
      bucket: UpdateBucket.Chat,
      entity: chat,
    })
    await input.tx
      .update(chats)
      .set({ updateSeq: update.seq, lastUpdateDate: update.date })
      .where(eq(chats.id, chat.id))
    clearUpdates.push({ chat, update })
  }

  return { clearUpdates, sideEffects: result, metadataChatUpdates, deletedChatUpdates, removedAccessUpdates }
}

async function persistDeletedChatUpdates(
  tx: Transaction,
  deletedChats: ClearHistoryDeletedChat[],
): Promise<DeletedChatUpdate[]> {
  const updates: DeletedChatUpdate[] = []

  for (const deletedChat of deletedChats) {
    const update = await UpdatesModel.insertUpdate(tx, {
      update: {
        oneofKind: "deleteChat",
        deleteChat: {
          chatId: BigInt(deletedChat.chat.id),
        },
      },
      bucket: UpdateBucket.Chat,
      entity: deletedChat.chat,
    })

    updates.push({
      ...deletedChat,
      userIds: uniqueUserIds(deletedChat.userIds),
      update,
      accessUpdates: [],
    })
  }

  const inputs = updates.flatMap((chatUpdate) =>
      chatUpdate.userIds.map((userId) => ({
        chatId: chatUpdate.chat.id,
        userId,
        update: {
          oneofKind: "userRemovedFromChat" as const,
          userRemovedFromChat: {
            chatId: BigInt(chatUpdate.chat.id),
          },
        },
      })),
    )
  const userUpdates = await UserBucketUpdates.enqueueMany(inputs, { tx })

  const updateByChatId = new Map(updates.map((item) => [item.chat.id, item]))
  for (const [index, input] of inputs.entries()) {
    updateByChatId.get(input.chatId)?.accessUpdates.push({
      userId: input.userId,
      update: userUpdates[index]!,
    })
  }

  return updates
}

async function persistRemovedChatAccessUpdates(
  tx: Transaction,
  losses: ClearHistoryAccessLoss[],
): Promise<RemovedChatAccessUpdate[]> {
  const inputs = losses.flatMap((loss) =>
    uniqueUserIds(loss.userIds).map((userId) => ({
      chatId: loss.chatId,
      userId,
      update: {
        oneofKind: "userRemovedFromChat" as const,
        userRemovedFromChat: {
          chatId: BigInt(loss.chatId),
        },
      },
    })),
  )

  const userUpdates = await UserBucketUpdates.enqueueMany(inputs, { tx })

  return inputs.map((input, index) => ({
    chatId: input.chatId,
    userId: input.userId,
    update: userUpdates[index]!,
  }))
}

async function ensureCanClearHistory(
  chat: DbChat,
  currentUserId: number,
  query: Pick<Transaction, "select"> | typeof db = db,
): Promise<void> {
  if (chat.type === "private") {
    await AccessGuards.ensureChatAccess(chat, currentUserId, query)
    return
  }

  if (chat.type !== "thread") {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  if (chat.spaceId != null) {
    const [member] = await query
      .select({ role: members.role })
      .from(members)
      .where(and(eq(members.spaceId, chat.spaceId), eq(members.userId, currentUserId)))
      .limit(1)

    if (member && (chat.createdBy === currentUserId || member.role === "admin" || member.role === "owner")) {
      return
    }

    throw RealtimeRpcError.SpaceAdminRequired()
  }

  if (chat.createdBy === currentUserId) {
    return
  }

  throw new RealtimeRpcError(RealtimeRpcError.Code.UNAUTHENTICATED, "Not allowed", 403)
}

async function ensureCanClearSpaceHistory(spaceId: number, currentUserId: number): Promise<void> {
  const [space] = await db.select({ id: spaces.id, deleted: spaces.deleted }).from(spaces).where(eq(spaces.id, spaceId)).limit(1)
  if (!space || space.deleted !== null) {
    throw RealtimeRpcError.SpaceIdInvalid()
  }

  const [member] = await db
    .select({ role: members.role })
    .from(members)
    .where(and(eq(members.spaceId, spaceId), eq(members.userId, currentUserId)))
    .limit(1)

  if (member?.role === "admin" || member?.role === "owner") {
    return
  }

  throw RealtimeRpcError.SpaceAdminRequired()
}

function resolveCutoff(keepLastDays: number): Cutoff | undefined {
  if (!Number.isSafeInteger(keepLastDays) || keepLastDays < 0 || keepLastDays > MAX_KEEP_LAST_DAYS) {
    throw RealtimeRpcError.BadRequest()
  }

  if (keepLastDays === 0) {
    return undefined
  }

  const seconds = Math.floor(Date.now() / 1000) - keepLastDays * DAY_SECONDS
  return {
    date: new Date(seconds * 1000),
    seconds: BigInt(seconds),
  }
}

function normalizeSpaceId(spaceId: number): number {
  if (!Number.isSafeInteger(spaceId) || spaceId <= 0) {
    throw RealtimeRpcError.SpaceIdInvalid()
  }

  return spaceId
}

const pushClearHistoryUpdates = async ({
  currentUserId,
  clearUpdates,
}: {
  currentUserId: number
  clearUpdates: ClearHistoryUpdate[]
}): Promise<{ selfUpdates: Update[] }> => {
  let selfUpdates: Update[] = []

  for (const clearUpdate of clearUpdates) {
    const inputPeer = clearUpdate.inputPeer
    const updateGroup = await getUpdateGroupFromInputPeer(inputPeer, { currentUserId })

    if (updateGroup.type === "dmUsers") {
      updateGroup.userIds.forEach((userId) => {
        const encodingForInputPeer: InputPeer =
          userId === currentUserId
            ? inputPeer
            : { type: { oneofKind: "user", user: { userId: BigInt(currentUserId) } } }

        const update = buildClearHistoryUpdate({
          inputPeer: encodingForInputPeer,
          currentUserId,
          update: clearUpdate.update,
          beforeDate: clearUpdate.beforeDate,
          deleteReplyThreads: clearUpdate.deleteReplyThreads,
          sideEffects: clearUpdate.sideEffects,
        })

        RealtimeUpdates.pushToUser(userId, [update])
        if (userId === currentUserId) {
          selfUpdates.push(update)
        }
      })
    } else if (updateGroup.type === "threadUsers") {
      updateGroup.userIds.forEach((userId) => {
        const update = buildClearHistoryUpdate({
          inputPeer,
          currentUserId,
          update: clearUpdate.update,
          beforeDate: clearUpdate.beforeDate,
          deleteReplyThreads: clearUpdate.deleteReplyThreads,
          sideEffects: clearUpdate.sideEffects,
        })

        RealtimeUpdates.pushToUser(userId, [update])
        if (userId === currentUserId) {
          selfUpdates.push(update)
        }
      })
    }
  }

  return { selfUpdates }
}

const pushDeletedChatUpdates = async ({
  currentUserId,
  chatUpdates,
}: {
  currentUserId: number
  chatUpdates: DeletedChatUpdate[]
}): Promise<{ selfUpdates: Update[] }> => {
  const selfUpdates: Update[] = []

  for (const chatUpdate of chatUpdates) {
    for (const userId of chatUpdate.userIds) {
      const update = buildDeleteChatUpdate({
        chat: chatUpdate.chat,
        update: chatUpdate.update,
        userId,
      })

      RealtimeUpdates.pushToUser(userId, [update])
      if (userId === currentUserId) {
        selfUpdates.push(update)
      }
    }

    for (const accessUpdate of chatUpdate.accessUpdates) {
      const update = buildAccessRemovedUpdate({
        chatId: chatUpdate.chat.id,
        userId: accessUpdate.userId,
        update: accessUpdate.update,
      })
      RealtimeUpdates.pushToUser(accessUpdate.userId, [update])
      if (accessUpdate.userId === currentUserId) selfUpdates.push(update)
    }
  }

  return { selfUpdates }
}

const pushRemovedChatAccessUpdates = async ({
  currentUserId,
  chatUpdates,
}: {
  currentUserId: number
  chatUpdates: RemovedChatAccessUpdate[]
}): Promise<{ selfUpdates: Update[] }> => {
  const selfUpdates: Update[] = []

  for (const chatUpdate of chatUpdates) {
    const update = buildAccessRemovedUpdate(chatUpdate)
    RealtimeUpdates.pushToUser(chatUpdate.userId, [update])

    if (chatUpdate.userId === currentUserId) {
      selfUpdates.push(update)
    }
  }

  return { selfUpdates }
}

function buildClearHistoryUpdate(input: {
  inputPeer: InputPeer
  currentUserId?: number
  update: UpdateSeqAndDate
  beforeDate?: bigint
  deleteReplyThreads: boolean
  sideEffects: ClearHistorySideEffects
}): Update {
  const target = buildPeerClearHistoryTarget(input.inputPeer, input.currentUserId)

  return {
    seq: input.update.seq,
    date: encodeDateStrict(input.update.date),
    update: {
      oneofKind: "clearChatHistory",
      clearChatHistory: {
        target,
        beforeDate: input.beforeDate,
        deleteReplyThreads: input.deleteReplyThreads,
        deletedChatIds: input.sideEffects.deletedChatIds.map(BigInt),
        orphanedChatIds: input.sideEffects.orphanedChatIds.map(BigInt),
        detachedChatIds: input.sideEffects.detachedChatIds.map(BigInt),
      },
    },
  }
}

function buildAccessRemovedUpdate(input: RemovedChatAccessUpdate): Update {
  return {
    seq: input.update.seq,
    date: encodeDateStrict(input.update.date),
    update: {
      oneofKind: "userRemovedFromChat" as const,
      userRemovedFromChat: {
        chatId: BigInt(input.chatId),
      },
    },
  }
}

function buildDeleteChatUpdate(input: { chat: DbChat; update: UpdateSeqAndDate; userId: number }): Update {
  return {
    seq: input.update.seq,
    date: encodeDateStrict(input.update.date),
    update: {
      oneofKind: "deleteChat",
      deleteChat: {
        peerId: Encoders.peerFromChat(input.chat, { currentUserId: input.userId }),
      },
    },
  }
}

function uniqueUserIds(userIds: number[]): number[] {
  return Array.from(new Set(userIds))
}

function uniqueSortedUserIds(userIds: number[]): number[] {
  return uniqueUserIds(userIds).sort((left, right) => left - right)
}

function sameClearHistoryPlan(
  left: ClearChatHistoryPlan | ClearSpaceHistoryPlan,
  right: ClearChatHistoryPlan | ClearSpaceHistoryPlan,
): boolean {
  return sameIds(left.affectedChatIds, right.affectedChatIds) && sameIds(left.recipientUserIds, right.recipientUserIds)
}

function sameIds(left: number[], right: number[]): boolean {
  return left.length === right.length && left.every((id, index) => id === right[index])
}

function ensurePlannedUsers(userIds: number[], lockedUserIds: ReadonlySet<number>): void {
  if (userIds.some((userId) => !lockedUserIds.has(userId))) {
    throw new ClearHistoryPlanChanged()
  }
}

function isResourceLockUnavailable(error: unknown): boolean {
  let current = error
  for (let depth = 0; depth < 4 && typeof current === "object" && current !== null; depth += 1) {
    if ("code" in current && current.code === "55P03") return true
    current = "cause" in current ? current.cause : undefined
  }
  return false
}

function emptyClearHistorySideEffects(): ClearHistorySideEffects {
  return {
    deletedChatIds: [],
    orphanedChatIds: [],
    detachedChatIds: [],
    deletedChats: [],
    detachedAccessLosses: [],
  }
}

function buildPeerClearHistoryTarget(inputPeer: InputPeer | undefined, currentUserId: number | undefined) {
  if (!inputPeer || currentUserId == null) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  return {
    oneofKind: "peerId" as const,
    peerId: Encoders.peerFromInputPeer({
      inputPeer,
      currentUserId,
    }),
  }
}
