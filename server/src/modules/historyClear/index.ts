import type { InputPeer, Update } from "@inline-chat/protocol/core"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { chats, members, spaces, type DbChat } from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { Transaction } from "@in/server/db/types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { persistChatMetadataUpdates, type ChatMetadataUpdate } from "@in/server/modules/chatMetadataUpdates"
import { pushChatMetadataUpdates } from "@in/server/modules/chatMetadataUpdatePush"
import { getUpdateGroupForSpace, getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { emitReplyThreadParentRepliesUpdateIfNeeded } from "@in/server/modules/subthreads"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import { and, eq } from "drizzle-orm"
import {
  clearChatHistoryData,
  clearSpaceHistoryData,
  type ClearHistoryAccessLoss,
  type ClearHistoryDeletedChat,
  type ClearHistorySideEffects,
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
  inputPeer?: InputPeer
  spaceId?: number
  update: UpdateSeqAndDate
  beforeDate?: bigint
  deleteReplyThreads: boolean
  sideEffects: ClearHistorySideEffects
}

type DeletedChatUpdate = ClearHistoryDeletedChat & {
  update: UpdateSeqAndDate
}

type RemovedChatAccessUpdate = {
  chatId: number
  userId: number
  update: UpdateSeqAndDate
}

const MAX_KEEP_LAST_DAYS = 36_500
const DAY_SECONDS = 24 * 60 * 60

const log = new Log("modules.historyClear")

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

  const { clearUpdate, sideEffects, metadataChatUpdates, deletedChatUpdates, removedAccessUpdates } =
    await db.transaction(async (tx) => {
      const [lockedChat] = await tx.select().from(chats).where(eq(chats.id, chat.id)).for("update").limit(1)
      if (!lockedChat) {
        throw RealtimeRpcError.ChatIdInvalid()
      }

      return clearLockedChatHistory({
        tx,
        chat: lockedChat,
        cutoff: input.cutoff,
        deleteReplyThreads: input.deleteReplyThreads,
      })
    })

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

  return {
    updates: [...selfUpdates, ...metadataSelfUpdates, ...deletedSelfUpdates, ...removedAccessSelfUpdates],
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

  const { clearUpdate, sideEffects, metadataChatUpdates, deletedChatUpdates, removedAccessUpdates } = await db.transaction(
    async (tx) => {
      const [lockedSpace] = await tx.select().from(spaces).where(eq(spaces.id, spaceId)).for("update").limit(1)
      if (!lockedSpace) {
        throw RealtimeRpcError.SpaceIdInvalid()
      }

      const { sideEffects, metadataChatUpdates, deletedChatUpdates, removedAccessUpdates } = await clearLockedSpaceHistory({
        tx,
        spaceId,
        cutoff: input.cutoff,
        deleteReplyThreads: input.deleteReplyThreads,
      })

      const updatePayload: ServerUpdate["update"] = {
        oneofKind: "spaceClearHistory",
        spaceClearHistory: {
          spaceId: BigInt(spaceId),
          beforeDate: input.cutoff?.seconds,
          deleteReplyThreads: input.deleteReplyThreads,
          deletedChatIds: sideEffects.deletedChatIds.map(BigInt),
          orphanedChatIds: sideEffects.orphanedChatIds.map(BigInt),
          detachedChatIds: sideEffects.detachedChatIds.map(BigInt),
        },
      }

      const update = await UpdatesModel.insertUpdate(tx, {
        update: updatePayload,
        bucket: UpdateBucket.Space,
        entity: lockedSpace,
      })

      await tx
        .update(spaces)
        .set({
          updateSeq: update.seq,
          lastUpdateDate: update.date,
        })
        .where(eq(spaces.id, spaceId))

      return { clearUpdate: update, sideEffects, metadataChatUpdates, deletedChatUpdates, removedAccessUpdates }
    },
  )

  const { selfUpdates } = await pushClearHistoryUpdates({
    currentUserId: input.context.currentUserId,
    clearUpdates: [
      {
        spaceId,
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

  return {
    updates: [...selfUpdates, ...metadataSelfUpdates, ...deletedSelfUpdates, ...removedAccessSelfUpdates],
  }
}

async function clearLockedChatHistory(input: {
  tx: Transaction
  chat: DbChat
  cutoff: Cutoff | undefined
  deleteReplyThreads: boolean
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

  const removedAccessUpdates = await persistRemovedChatAccessUpdates(input.tx, result.detachedAccessLosses)

  return { clearUpdate, sideEffects: result, metadataChatUpdates, deletedChatUpdates, removedAccessUpdates }
}

async function clearLockedSpaceHistory(input: {
  tx: Transaction
  spaceId: number
  cutoff: Cutoff | undefined
  deleteReplyThreads: boolean
}): Promise<{
  sideEffects: ClearHistorySideEffects
  metadataChatUpdates: ChatMetadataUpdate[]
  deletedChatUpdates: DeletedChatUpdate[]
  removedAccessUpdates: RemovedChatAccessUpdate[]
}> {
  await input.tx.select({ id: chats.id }).from(chats).where(eq(chats.spaceId, input.spaceId)).for("update")

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
        deletedChatUpdates = await persistDeletedChatUpdates(input.tx, deletedChats)
      },
    },
  )

  const metadataChatUpdates = await persistChatMetadataUpdates(input.tx, [
    ...result.orphanedChatIds,
    ...result.detachedChatIds,
  ])
  const removedAccessUpdates = await persistRemovedChatAccessUpdates(input.tx, result.detachedAccessLosses)

  return { sideEffects: result, metadataChatUpdates, deletedChatUpdates, removedAccessUpdates }
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
    })
  }

  await UserBucketUpdates.enqueueMany(
    updates.flatMap((chatUpdate) =>
      chatUpdate.userIds.map((userId) => ({
        userId,
        update: {
          oneofKind: "userChatParticipantDelete" as const,
          userChatParticipantDelete: {
            chatId: BigInt(chatUpdate.chat.id),
          },
        },
      })),
    ),
    { tx },
  )

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
        oneofKind: "userChatParticipantDelete" as const,
        userChatParticipantDelete: {
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

async function ensureCanClearHistory(chat: DbChat, currentUserId: number): Promise<void> {
  if (chat.type === "private") {
    try {
      await AccessGuards.ensureChatAccess(chat, currentUserId)
    } catch (error) {
      log.error("clearChatHistory blocked: chat access denied", {
        chatId: chat.id,
        currentUserId,
        error,
      })
      throw error
    }

    return
  }

  if (chat.type !== "thread") {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  if (chat.spaceId != null) {
    const [member] = await db
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
  const [space] = await db.select({ id: spaces.id }).from(spaces).where(eq(spaces.id, spaceId)).limit(1)
  if (!space) {
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
    if (clearUpdate.spaceId != null) {
      const updateGroup = await getUpdateGroupForSpace(clearUpdate.spaceId, { currentUserId })
      const update = buildClearHistoryUpdate({
        spaceId: clearUpdate.spaceId,
        update: clearUpdate.update,
        beforeDate: clearUpdate.beforeDate,
        deleteReplyThreads: clearUpdate.deleteReplyThreads,
        sideEffects: clearUpdate.sideEffects,
      })

      updateGroup.userIds.forEach((userId) => {
        RealtimeUpdates.pushToUser(userId, [update])
        if (userId === currentUserId) {
          selfUpdates.push(update)
        }
      })
      continue
    }

    if (!clearUpdate.inputPeer) {
      continue
    }

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
    const update = buildParticipantDeleteUpdate(chatUpdate)
    RealtimeUpdates.pushToUser(chatUpdate.userId, [update])

    if (chatUpdate.userId === currentUserId) {
      selfUpdates.push(update)
    }
  }

  return { selfUpdates }
}

function buildClearHistoryUpdate(input: {
  inputPeer?: InputPeer
  spaceId?: number
  currentUserId?: number
  update: UpdateSeqAndDate
  beforeDate?: bigint
  deleteReplyThreads: boolean
  sideEffects: ClearHistorySideEffects
}): Update {
  const target =
    input.spaceId != null
      ? {
          oneofKind: "spaceId" as const,
          spaceId: BigInt(input.spaceId),
        }
      : buildPeerClearHistoryTarget(input.inputPeer, input.currentUserId)

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

function buildParticipantDeleteUpdate(input: RemovedChatAccessUpdate): Update {
  return {
    seq: input.update.seq,
    date: encodeDateStrict(input.update.date),
    update: {
      oneofKind: "participantDelete",
      participantDelete: {
        chatId: BigInt(input.chatId),
        userId: BigInt(input.userId),
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
