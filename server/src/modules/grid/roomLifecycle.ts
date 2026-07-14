import type { GridConnection } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { gridPresence, gridRooms, type DbGridRoom } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import {
  enqueueGridConnectionCleanup,
  enqueueGridParticipantRevocation,
} from "@in/server/modules/grid/providerEffects"
import { gridParticipantIdentity } from "@in/server/modules/grid/livekit"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { Log } from "@in/server/utils/log"
import { and, count, eq, gt, inArray, sql } from "drizzle-orm"

const log = new Log("grid.roomLifecycle")

export type GridMutationState = {
  affectedSpaceIds: Set<number>
  changedRoomId?: number
  endedConnections: GridConnection[]
  participantRevocations?: GridParticipantRevocation[]
}

export type GridParticipantRevocation = {
  connection: GridConnection
  userId: number
}

export type GridPresenceRemovalState = GridMutationState & {
  removedPresence: boolean
  activeConnection?: GridConnection
}

/** Serializes global-avatar moves and room connection generations. */
export async function lockGridMutations(tx: Transaction) {
  await tx.execute(sql`select pg_advisory_xact_lock(817263941)`)
}

/**
 * Reconciles durable room metadata from the authoritative leased-presence
 * rows. The returned connection generation has ended and can be retired from
 * the provider after the transaction commits.
 */
export async function reconcileGridRoom(
  tx: Transaction,
  roomId: number,
): Promise<GridConnection | undefined> {
  const startedAt = Date.now()
  const [room] = await tx.select().from(gridRooms).where(eq(gridRooms.id, roomId)).for("update").limit(1)
  if (!room) return

  const [occupancy] = await tx
    .select({ value: count() })
    .from(gridPresence)
    .where(and(eq(gridPresence.roomId, roomId), gt(gridPresence.leaseExpiresAt, new Date())))
  const occupantCount = Number(occupancy?.value ?? 0)
  const nextGeneration = room.connectionStartedAt === null && occupantCount >= 2
    ? room.connectionGeneration + 1
    : room.connectionGeneration
  const endedConnection = activeGridConnection(room)

  if (occupantCount === 0 && room.title === null) {
    await tx.delete(gridRooms).where(eq(gridRooms.id, roomId))
    if (endedConnection) await enqueueGridConnectionCleanup(tx, endedConnection)
    log.debug("GRID_TRACE phase=reconcile_deleted_ephemeral", {
      roomId,
      occupantCount,
      generation: room.connectionGeneration,
      elapsedMs: Date.now() - startedAt,
    })
    return endedConnection
  }

  const now = new Date()
  if (occupantCount < 2) {
    await tx
      .update(gridRooms)
      .set({ locked: occupantCount === 0 ? false : room.locked, connectionStartedAt: null, updatedAt: now })
      .where(eq(gridRooms.id, roomId))
    if (endedConnection) await enqueueGridConnectionCleanup(tx, endedConnection)
    return endedConnection
  }

  if (room.connectionStartedAt === null) {
    await tx
      .update(gridRooms)
      .set({ connectionGeneration: sql`${gridRooms.connectionGeneration} + 1`, connectionStartedAt: now, updatedAt: now })
      .where(eq(gridRooms.id, roomId))
  } else {
    await tx.update(gridRooms).set({ updatedAt: now }).where(eq(gridRooms.id, roomId))
  }
  log.debug("GRID_TRACE phase=reconcile_done", {
    roomId,
    occupantCount,
    previousActive: room.connectionStartedAt !== null,
    active: true,
    generation: nextGeneration,
    elapsedMs: Date.now() - startedAt,
  })
  return undefined
}

export async function clearGridPresenceForSpace(tx: Transaction, spaceId: number) {
  await lockGridMutations(tx)
  const rooms = await tx.select().from(gridRooms).where(eq(gridRooms.spaceId, spaceId))
  if (rooms.length === 0) return []

  const roomIds = rooms.map((room) => room.id)
  const participants = await tx
    .select({
      room: gridRooms,
      userId: gridPresence.userId,
      mediaMembershipId: gridPresence.mediaMembershipId,
    })
    .from(gridPresence)
    .innerJoin(gridRooms, eq(gridRooms.id, gridPresence.roomId))
    .where(inArray(gridPresence.roomId, roomIds))
  for (const participant of participants) {
    const connection = activeGridConnection(participant.room)
    if (connection) {
      await enqueueGridParticipantRevocation(
        tx,
        connection,
        participant.userId,
        gridParticipantIdentity(participant.userId, participant.mediaMembershipId),
      )
    }
  }
  await tx.delete(gridPresence).where(inArray(gridPresence.roomId, roomIds))
  const endedConnections: GridConnection[] = []
  for (const roomId of roomIds) {
    const endedConnection = await reconcileGridRoom(tx, roomId)
    if (endedConnection) endedConnections.push(endedConnection)
  }
  return endedConnections
}

export async function removeGridMemberPresence(
  spaceId: number,
  userId: number,
): Promise<GridPresenceRemovalState> {
  return removeGridPresence({ spaceId, userId })
}

/**
 * Transactional form used by Space-member removal so membership, Grid
 * presence, and durable provider revocation commit as one authority change.
 */
export async function removeGridMemberPresenceInTransaction(
  tx: Transaction,
  spaceId: number,
  userId: number,
): Promise<GridPresenceRemovalState> {
  await lockGridMutations(tx)
  return removeGridPresenceInTransaction(tx, { spaceId, userId })
}

export async function removeGridSessionPresence(
  userId: number,
  ownerSessionId: number,
): Promise<GridPresenceRemovalState> {
  return removeGridPresence({ userId, ownerSessionId })
}

/**
 * Transactional form used by session termination so authentication and Grid
 * media ownership change atomically under the same mutation lock.
 */
export async function removeGridSessionPresenceInTransaction(
  tx: Transaction,
  userId: number,
  ownerSessionId: number,
): Promise<GridPresenceRemovalState> {
  await lockGridMutations(tx)
  return removeGridPresenceInTransaction(tx, { userId, ownerSessionId })
}

async function removeGridPresence(input: {
  userId: number
  spaceId?: number
  ownerSessionId?: number
}): Promise<GridPresenceRemovalState> {
  return db.transaction(async (tx) => {
    await lockGridMutations(tx)
    return removeGridPresenceInTransaction(tx, input)
  })
}

async function removeGridPresenceInTransaction(
  tx: Transaction,
  input: {
    userId: number
    spaceId?: number
    ownerSessionId?: number
  },
): Promise<GridPresenceRemovalState> {
  const conditions = [eq(gridPresence.userId, input.userId)]
  if (input.spaceId !== undefined) conditions.push(eq(gridRooms.spaceId, input.spaceId))
  if (input.ownerSessionId !== undefined) {
    conditions.push(eq(gridPresence.ownerSessionId, input.ownerSessionId))
  }
  const [row] = await tx
    .select({ room: gridRooms, presence: gridPresence })
    .from(gridPresence)
    .innerJoin(gridRooms, eq(gridRooms.id, gridPresence.roomId))
    .where(and(...conditions))
    .limit(1)

  if (!row) {
    return {
      affectedSpaceIds: new Set<number>(),
      changedRoomId: undefined,
      endedConnections: [],
      removedPresence: false,
      activeConnection: undefined,
    }
  }

  const deleteConditions = [
    eq(gridPresence.userId, input.userId),
    eq(gridPresence.roomId, row.room.id),
  ]
  if (input.ownerSessionId !== undefined) {
    deleteConditions.push(eq(gridPresence.ownerSessionId, input.ownerSessionId))
  }
  const activeConnection = activeGridConnection(row.room)
  await tx.delete(gridPresence).where(and(...deleteConditions))
  if (activeConnection) {
    await enqueueGridParticipantRevocation(
      tx,
      activeConnection,
      input.userId,
      gridParticipantIdentity(input.userId, row.presence.mediaMembershipId),
    )
  }
  const endedConnection = await reconcileGridRoom(tx, row.room.id)
  return {
    affectedSpaceIds: new Set([row.room.spaceId]),
    changedRoomId: row.room.id,
    endedConnections: endedConnection ? [endedConnection] : [],
    removedPresence: true,
    activeConnection,
  }
}

export async function recordGridParticipantRevocation(
  tx: Transaction,
  state: GridMutationState,
  connection: GridConnection,
  userId: number,
  mediaMembershipId: string,
): Promise<void> {
  await enqueueGridParticipantRevocation(
    tx,
    connection,
    userId,
    gridParticipantIdentity(userId, mediaMembershipId),
  )
  state.participantRevocations ??= []
  state.participantRevocations.push({ connection, userId })
}

export function activeGridConnection(room: DbGridRoom): GridConnection | undefined {
  if (!room.connectionStartedAt) return undefined
  return {
    roomId: BigInt(room.id),
    generation: room.connectionGeneration,
    startedAt: encodeDateStrict(room.connectionStartedAt),
  }
}
