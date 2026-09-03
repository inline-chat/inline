import {
  UpdatesPayload,
  type GetUpdatesStateInput,
  type GetUpdatesStateResult,
} from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { SpaceModel } from "@in/server/db/models/spaces"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { DbChat } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { decodeDate } from "@in/server/realtime/encoders/helpers"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Log } from "@in/server/utils/log"
import { UsersModel } from "@in/server/db/models/users"
import { db } from "@in/server/db"
import {
  UpdateBucket,
  chatParticipantGroups,
  chatParticipants,
  chats as chatsTable,
  members,
  spaces as spacesTable,
  updates as updatesTable,
  userGroupMembers,
  userGroups,
  userNotDeleted,
  users as usersTable,
} from "@in/server/db/schema"
import { and, eq, inArray, isNotNull, isNull, or, sql } from "drizzle-orm"
import { captureUpdateDiscoveryWatermark } from "@in/server/modules/updates/updateDiscoveryBarrier"

const log = new Log("updates.getUpdatesState")
const MAX_UPDATE_HINTS_PER_BATCH = 512
const MAX_UPDATE_HINT_BATCH_BYTES = 1024 * 1024
const MAX_CONCURRENT_CHAT_ACCESS_CHECKS = 16
const MAX_CHAT_ACCESS_QUERY_BATCH = 512

export const getUpdatesState = async (
  input: GetUpdatesStateInput,
  context: FunctionContext,
): Promise<GetUpdatesStateResult> => {
  const startedAt = performance.now()
  // CLI 0.7.8 encoded its brand-new local cursor sentinel as date=0. Keep
  // accepting that released bootstrap shape as a fresh checkpoint while new
  // clients use the canonical absent date.
  const requestedDate = input.date === 0n ? undefined : input.date
  if (requestedDate !== undefined && requestedDate < 0n) {
    throw RealtimeRpcError.BadRequest()
  }

  // The exclusive fence drains every durable writer that already holds the
  // shared side, then commits immediately. Resource and access scans happen
  // after it is released. If the lock or DB clock read fails, this RPC rejects
  // and therefore cannot advance the client's checkpoint.
  const scanStartedAt = await captureUpdateDiscoveryWatermark()
  const scanStartDate = floorWireDate(scanStartedAt)

  const user = await UsersModel.getUserById(context.currentUserId)
  if (!user) {
    throw RealtimeRpcError.InternalError()
  }
  const latestUserUpdate = await db.query.updates.findFirst({
    columns: {
      seq: true,
    },
    where: {
      bucket: UpdateBucket.User,
      entityId: context.currentUserId,
    },
    orderBy: {
      seq: "desc",
    },
  })
  const userSeq = Math.max(user.updateSeq ?? 0, latestUserUpdate?.seq ?? 0)

  if (requestedDate !== undefined && requestedDate > scanStartDate) {
    // A future cursor cannot be clamped and scanned from "now": that would
    // silently skip history before the clamped date. Current Sync recognizes a
    // lower date as an explicit account-repair checkpoint; older clients keep
    // their monotonic cursor instead of accepting a lossy checkpoint and need
    // their existing reset/account-repair flow. The lower date is the repair
    // marker; no bucket work was discovered, so updatesFound stays false.
    return {
      date: scanStartDate,
      updatesFound: false,
      seq: userSeq,
    }
  }

  // An absent date requests a fresh checkpoint. Snapshot RPCs seed the resource
  // buckets independently, so bootstrap must not discover or replay old work.
  if (requestedDate === undefined) {
    logGetUpdatesStateTiming({
      result: "checkpoint",
      totalMs: elapsedMs(startedAt),
      chats: 0,
      spaces: 0,
      pushed: 0,
    })
    return {
      date: scanStartDate,
      updatesFound: false,
      seq: userSeq,
    }
  }

  // Discovery is inclusive. The cursor has already been validated not to be
  // newer than the scan-start watermark, so same-second work can be found on a
  // subsequent scan even when this scan crosses a second boundary.
  const userLocalDate = decodeDate(requestedDate)

  // check latest changes of chats from this user's dialogs for changes compared to date
  // get a list of dialogs for this user
  const chatsStartedAt = performance.now()
  let { chats } = await ChatModel.getUserChats({
    userId: context.currentUserId,
    where: {
      lastUpdateAtGreaterThanEqual: userLocalDate,
    },
  })
  chats = await filterAccessibleChats(chats, context.currentUserId)
  const chatsMs = elapsedMs(chatsStartedAt)

  // Get spaces that have been updated
  const spacesStartedAt = performance.now()
  let spaces = await SpaceModel.getSpacesAfterUpdateDate({
    userId: context.currentUserId,
    lastUpdateDateGreaterThanEqual: userLocalDate,
  })
  const spacesMs = elapsedMs(spacesStartedAt)

  // Find latest update date for chats
  let latestChatUpdateTs = chats.reduce((max, chat) => {
    return Math.max(max, chat.lastUpdateDate?.getTime() ?? 0)
  }, 0)

  // Find latest update date for spaces
  let latestSpaceUpdateTs = spaces.reduce((max, space) => {
    return Math.max(max, space.lastUpdateDate?.getTime() ?? 0)
  }, 0)

  let latestUpdateTs = Math.max(latestChatUpdateTs, latestSpaceUpdateTs)
  // If there are no updates, advance the cursor to (at least) "now" to avoid
  // repeatedly re-scanning from an old date on every reconnect.
  if (latestUpdateTs === 0) {
    logGetUpdatesStateTiming({
      result: "empty",
      totalMs: elapsedMs(startedAt),
      chatsMs,
      spacesMs,
      chats: chats.length,
      spaces: spaces.length,
      pushed: 0,
    })
    return {
      date: scanStartDate,
      updatesFound: false,
      seq: userSeq,
    }
  }

  const durableSeqs = await getDurableSeqsByTarget(
    chats.filter((chat) => chat.lastUpdateDate).map((chat) => chat.id),
    spaces.filter((space) => space.lastUpdateDate).map((space) => space.id),
  )

  const updatesToPush: Parameters<typeof RealtimeUpdates.pushToUser>[1] = []

  // Publish updates for chats
  for (let chat of chats) {
    if (!chat.lastUpdateDate) {
      continue
    }

    updatesToPush.push({
      update: {
        oneofKind: "chatHasNewUpdates",
        chatHasNewUpdates: {
          chatId: BigInt(chat.id),
          // PTS should not be null here
          updateSeq: reconcileTargetSeq(UpdateBucket.Chat, chat.id, chat.updateSeq, durableSeqs),
          peerId: Encoders.peerFromChat(chat, {
            currentUserId: context.currentUserId,
          }),
        },
      },
    })
  }

  // Publish updates for spaces
  for (let space of spaces) {
    if (!space.lastUpdateDate) {
      continue
    }
    updatesToPush.push({
      update: {
        oneofKind: "spaceHasNewUpdates",
        spaceHasNewUpdates: {
          spaceId: BigInt(space.id),
          // Zero is the existing "fetch authoritatively" sentinel. A changed
          // bucket must never disappear merely because its cached counter is
          // temporarily absent or being repaired.
          updateSeq: reconcileTargetSeq(UpdateBucket.Space, space.id, space.updateSeq, durableSeqs),
        },
      },
    })
  }

  if (updatesToPush.length > 0) {
    await pushBoundedUpdateHints(context.currentUserId, updatesToPush)
  }

  logGetUpdatesStateTiming({
    result: "updates",
    totalMs: elapsedMs(startedAt),
    chatsMs,
    spacesMs,
    chats: chats.length,
    spaces: spaces.length,
    pushed: updatesToPush.length,
  })

  return {
    // This is a complete scan: every changed target was materialized and its
    // hint was emitted before the checkpoint is returned. A fixed watermark
    // makes an immediate inclusive follow-up converge without skipping a
    // target that changed during either resource scan.
    date: scanStartDate,
    updatesFound: true,
    seq: userSeq,
  }
}

const floorWireDate = (date: Date): bigint => BigInt(Math.floor(date.getTime() / 1000))

const reconcileTargetSeq = (
  bucket: UpdateBucket,
  entityId: number,
  cachedSeq: number | null | undefined,
  durableSeqs: Map<string, number>,
): number => Math.max(cachedSeq ?? 0, durableSeqs.get(`${bucket}:${entityId}`) ?? 0)

const getDurableSeqsByTarget = async (
  chatIds: number[],
  spaceIds: number[],
): Promise<Map<string, number>> => {
  const uniqueChatIds = Array.from(new Set(chatIds))
  const uniqueSpaceIds = Array.from(new Set(spaceIds))
  if (uniqueChatIds.length === 0 && uniqueSpaceIds.length === 0) {
    return new Map()
  }

  const targets = [
    ...uniqueChatIds.map((entityId) => ({ bucket: UpdateBucket.Chat, entityId })),
    ...uniqueSpaceIds.map((entityId) => ({ bucket: UpdateBucket.Space, entityId })),
  ]
  const durableSeqs = new Map<string, number>()
  for (let offset = 0; offset < targets.length; offset += MAX_CHAT_ACCESS_QUERY_BATCH) {
    const batch = targets.slice(offset, offset + MAX_CHAT_ACCESS_QUERY_BATCH)
    const batchChatIds = batch.filter((target) => target.bucket === UpdateBucket.Chat).map((target) => target.entityId)
    const batchSpaceIds = batch.filter((target) => target.bucket === UpdateBucket.Space).map((target) => target.entityId)
    const targetWhere = batchChatIds.length > 0 && batchSpaceIds.length > 0
      ? or(
          and(eq(updatesTable.bucket, UpdateBucket.Chat), inArray(updatesTable.entityId, batchChatIds)),
          and(eq(updatesTable.bucket, UpdateBucket.Space), inArray(updatesTable.entityId, batchSpaceIds)),
        )
      : batchChatIds.length > 0
        ? and(eq(updatesTable.bucket, UpdateBucket.Chat), inArray(updatesTable.entityId, batchChatIds))
        : and(eq(updatesTable.bucket, UpdateBucket.Space), inArray(updatesTable.entityId, batchSpaceIds))

    const rows = await db
      .select({
        bucket: updatesTable.bucket,
        entityId: updatesTable.entityId,
        maxSeq: sql<number>`max(${updatesTable.seq})`,
      })
      .from(updatesTable)
      .where(targetWhere)
      .groupBy(updatesTable.bucket, updatesTable.entityId)
    for (const row of rows) {
      durableSeqs.set(`${row.bucket}:${row.entityId}`, Number(row.maxSeq))
    }
  }

  return durableSeqs
}

const pushBoundedUpdateHints = async (
  userId: number,
  updates: Parameters<typeof RealtimeUpdates.pushToUser>[1],
): Promise<void> => {
  let offset = 0
  while (offset < updates.length) {
    let batch = updates.slice(offset, offset + MAX_UPDATE_HINTS_PER_BATCH)
    let encodedBytes = UpdatesPayload.toBinary({ updates: batch }).length
    while (encodedBytes > MAX_UPDATE_HINT_BATCH_BYTES && batch.length > 1) {
      batch = batch.slice(0, Math.ceil(batch.length / 2))
      encodedBytes = UpdatesPayload.toBinary({ updates: batch }).length
    }
    if (encodedBytes > MAX_UPDATE_HINT_BATCH_BYTES) {
      throw new RangeError("Realtime update hint exceeds the bounded batch size")
    }
    await RealtimeUpdates.pushToUser(userId, batch)
    offset += batch.length
  }
}

type GetUpdatesStateTiming = {
  result: "checkpoint" | "empty" | "updates"
  totalMs: number
  chatsMs?: number
  spacesMs?: number
  chats: number
  spaces: number
  pushed: number
}

const elapsedMs = (startedAt: number): number =>
  Math.round((performance.now() - startedAt) * 10) / 10

const logGetUpdatesStateTiming = (timing: GetUpdatesStateTiming): void => {
  const message = "getUpdatesState timing"
  if (timing.totalMs >= 500) {
    log.warn(message, timing)
  } else {
    log.debug(message, timing)
  }
}

const filterAccessibleChats = async (chats: DbChat[], userId: number): Promise<DbChat[]> => {
  const knownAccessibleChatIds = await findKnownAccessibleChatIds(chats, userId)
  const chatsRequiringGuard = chats.filter((chat) => !knownAccessibleChatIds.has(chat.id))
  if (chatsRequiringGuard.length === 0) {
    return chats
  }

  const accessible = Array.from<DbChat | undefined>({ length: chatsRequiringGuard.length })
  let nextIndex = 0
  const workerCount = Math.min(chatsRequiringGuard.length, MAX_CONCURRENT_CHAT_ACCESS_CHECKS)

  await Promise.all(Array.from({ length: workerCount }, async () => {
    while (nextIndex < chatsRequiringGuard.length) {
      const index = nextIndex
      nextIndex += 1
      const chat = chatsRequiringGuard[index]
      if (!chat) continue
      try {
        await AccessGuards.ensureChatAccess(chat, userId)
        accessible[index] = chat
      } catch (error) {
        if (isExpectedAccessError(error)) {
          continue
        }
        throw error
      }
    }
  }))

  const guardedAccessibleIds = new Set(
    accessible.filter((chat): chat is DbChat => chat !== undefined).map((chat) => chat.id),
  )
  return chats.filter((chat) => knownAccessibleChatIds.has(chat.id) || guardedAccessibleIds.has(chat.id))
}

const findKnownAccessibleChatIds = async (chats: DbChat[], userId: number): Promise<Set<number>> => {
  const knownAccessibleChatIds = new Set<number>()
  const publicSpaceIds = new Set<number>()
  const grantChatIds: number[] = []

  for (const chat of chats) {
    // Linked subthreads can outlive membership in the dialog catalog. Their
    // owning-space and inherited-root rules must pass the complete guard;
    // retained direct/group grants alone are not sufficient authority.
    if (chat.parentChatId != null) continue
    if (chat.type === "private" && (chat.minUserId === userId || chat.maxUserId === userId)) {
      // AccessGuards.ensureChatAccess returns immediately for a matching DM.
      knownAccessibleChatIds.add(chat.id)
    } else if (
      chat.type === "thread" &&
      chat.parentChatId == null &&
      chat.spaceId != null &&
      chat.publicThread
    ) {
      publicSpaceIds.add(chat.spaceId)
    } else if (chat.type !== "private") {
      grantChatIds.push(chat.id)
    }
  }

  for (let offset = 0; offset < grantChatIds.length; offset += MAX_CHAT_ACCESS_QUERY_BATCH) {
    const batchChatIds = grantChatIds.slice(offset, offset + MAX_CHAT_ACCESS_QUERY_BATCH)
    const [directRows, groupRows] = await Promise.all([
      db
        .selectDistinct({ chatId: chatParticipants.chatId })
        .from(chatParticipants)
        .innerJoin(chatsTable, eq(chatParticipants.chatId, chatsTable.id))
        .leftJoin(spacesTable, eq(chatsTable.spaceId, spacesTable.id))
        .leftJoin(
          members,
          and(eq(members.spaceId, chatsTable.spaceId), eq(members.userId, userId)),
        )
        .where(
          and(
            inArray(chatParticipants.chatId, batchChatIds),
            eq(chatParticipants.userId, userId),
            or(
              isNull(chatsTable.spaceId),
              and(isNull(spacesTable.deleted), isNotNull(members.userId)),
            ),
          ),
        ),
      db
        .selectDistinct({ chatId: chatParticipantGroups.chatId })
        .from(chatParticipantGroups)
        .innerJoin(chatsTable, eq(chatParticipantGroups.chatId, chatsTable.id))
        .innerJoin(userGroups, eq(chatParticipantGroups.groupId, userGroups.id))
        .innerJoin(userGroupMembers, eq(chatParticipantGroups.groupId, userGroupMembers.groupId))
        .innerJoin(members, and(eq(members.spaceId, userGroups.spaceId), eq(members.userId, userGroupMembers.userId)))
        .innerJoin(usersTable, eq(usersTable.id, userGroupMembers.userId))
        .innerJoin(spacesTable, eq(spacesTable.id, userGroups.spaceId))
        .where(
          and(
            inArray(chatParticipantGroups.chatId, batchChatIds),
            eq(userGroupMembers.userId, userId),
            eq(chatsTable.spaceId, userGroups.spaceId),
            isNull(spacesTable.deleted),
            userNotDeleted(),
          ),
        ),
    ])
    for (const row of directRows) knownAccessibleChatIds.add(row.chatId)
    for (const row of groupRows) knownAccessibleChatIds.add(row.chatId)
  }

  const publicSpaceIdList = Array.from(publicSpaceIds)
  for (let offset = 0; offset < publicSpaceIdList.length; offset += MAX_CHAT_ACCESS_QUERY_BATCH) {
    const batchSpaceIds = publicSpaceIdList.slice(offset, offset + MAX_CHAT_ACCESS_QUERY_BATCH)
    const memberRows = await db
      .select({ spaceId: members.spaceId })
      .from(members)
      .innerJoin(spacesTable, eq(members.spaceId, spacesTable.id))
      .where(
        and(
          inArray(members.spaceId, batchSpaceIds),
          eq(members.userId, userId),
          eq(members.canAccessPublicChats, true),
          isNull(spacesTable.deleted),
        ),
      )
    const accessibleSpaceIds = new Set(memberRows.map((row) => row.spaceId))
    for (const chat of chats) {
      if (chat.spaceId != null && accessibleSpaceIds.has(chat.spaceId) && chat.publicThread && chat.parentChatId == null) {
        knownAccessibleChatIds.add(chat.id)
      }
    }
  }

  return knownAccessibleChatIds
}

const isExpectedAccessError = (error: unknown): boolean =>
  RealtimeRpcError.is(error, RealtimeRpcError.Code.PEER_ID_INVALID) ||
  RealtimeRpcError.is(error, RealtimeRpcError.Code.SPACE_ID_INVALID)
