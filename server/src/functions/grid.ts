import type {
  CreateGridRoomInput,
  CreateGridRoomResult,
  DeleteGridRoomInput,
  DeleteGridRoomResult,
  GetGridInput,
  GetGridResult,
  GetGridHomeInput,
  GetGridHomeResult,
  GridHomeSpace,
  Grid,
  GridConnection,
  GridRoom,
  JoinGridRoomInput,
  JoinGridRoomResult,
  LeaveGridRoomInput,
  LeaveGridRoomResult,
  PrepareGridConnectionInput,
  PrepareGridConnectionResult,
  SetGridAvatarMicrophoneEnabledInput,
  SetGridAvatarMicrophoneEnabledResult,
  SetGridRoomLockedInput,
  SetGridRoomLockedResult,
  SetGridRoomTitleInput,
  SetGridRoomTitleResult,
} from "@inline-chat/protocol/core"
import { GridConnectionUnavailableReason } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { SpaceSettingsModel } from "@in/server/db/models/spaceSettings"
import { UsersModel } from "@in/server/db/models/users"
import { gridPresence, gridRooms, members, sessions, spaces, users, type DbGridRoom } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { encodeUser } from "@in/server/realtime/encoders/encodeUser"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { sendMessageToRealtimeSession, sendMessageToRealtimeSpace } from "@in/server/realtime/message"
import { createGridConnectionCredentials, gridParticipantIdentity } from "@in/server/modules/grid/livekit"
import { setGridAvatarMicrophoneState } from "@in/server/modules/grid/avatarState"
import { notifyGridChanged } from "@in/server/modules/grid/realtime"
import {
  activeGridConnection,
  lockGridMutations,
  recordGridParticipantRevocation,
  reconcileGridRoom,
  type GridMutationState,
} from "@in/server/modules/grid/roomLifecycle"
import { Log } from "@in/server/utils/log"
import { and, asc, count, desc, eq, gt, inArray, isNotNull, isNull, lte, sql } from "drizzle-orm"

// Heartbeats are normally 30 seconds apart. Keep enough server-independent
// recovery budget for a user to repair or switch networks without another
// participant's first reconnect nondeterministically expiring their avatar.
const PRESENCE_LEASE_MS = 15 * 60_000
const MAX_ROOM_CAPACITY = 25
const MAX_NAMED_ROOMS_PER_SPACE = 50
const MAX_ROOM_TITLE_LENGTH = 80
const log = new Log("grid")

export async function getGrid(input: GetGridInput, context: FunctionContext): Promise<GetGridResult> {
  const spaceId = positiveId(input.spaceId, RealtimeRpcError.SpaceIdInvalid)
  await AccessGuards.ensureSpaceMember(spaceId, context.currentUserId)

  await refreshPresenceLeases({ spaceId, context })
  return { grid: await buildGrid(spaceId, context) }
}

export async function getGridHome(
  _input: GetGridHomeInput,
  context: FunctionContext,
): Promise<GetGridHomeResult> {
  await refreshPresenceLeases()
  const membershipRows = await db
    .select({ spaceId: members.spaceId })
    .from(members)
    .where(eq(members.userId, context.currentUserId))

  const enabledSpaceIds = (await SpaceSettingsModel.getStoredMany(membershipRows.map(({ spaceId }) => spaceId)))
    .filter(({ gridEnabled }) => gridEnabled)
    .map(({ spaceId }) => spaceId)

  const presenceRows =
    enabledSpaceIds.length === 0
      ? []
      : await db
          .select({ spaceId: gridRooms.spaceId, presence: gridPresence })
          .from(gridPresence)
          .innerJoin(gridRooms, eq(gridRooms.id, gridPresence.roomId))
          .where(
            and(
              inArray(gridRooms.spaceId, enabledSpaceIds),
              gt(gridPresence.leaseExpiresAt, new Date()),
            ),
          )
          .orderBy(desc(gridPresence.joinedAt))

  const userIds = [...new Set(presenceRows.map(({ presence }) => presence.userId))]
  const usersWithPhotos = userIds.length > 0 ? await UsersModel.getUsersWithPhotos(userIds) : []
  const encodedUsers = new Map(
    usersWithPhotos.map(({ user, photoFile }) => [user.id, encodeUser({ user, photoFile, min: true })]),
  )
  const summaries: GridHomeSpace[] = enabledSpaceIds.map((spaceId) => ({
    spaceId: BigInt(spaceId),
    activeAvatarCount: 0,
    recentAvatars: [],
    latestActivityAt: 0n,
  }))
  const summariesBySpaceId = new Map(enabledSpaceIds.map((spaceId, index) => [spaceId, summaries[index]!]))

  for (const { spaceId, presence } of presenceRows) {
    const summary = summariesBySpaceId.get(spaceId)
    const user = encodedUsers.get(presence.userId)
    if (!summary || !user) continue
    summary.activeAvatarCount += 1
    const joinedAt = encodeDateStrict(presence.joinedAt)
    if (summary.latestActivityAt === 0n) summary.latestActivityAt = joinedAt
    if (summary.recentAvatars.length < 4) {
      summary.recentAvatars.push({
        user,
        joinedAt,
        ownedByCurrentSession:
          presence.userId === context.currentUserId && presence.ownerSessionId === context.currentSessionId,
        microphoneEnabled: presence.microphoneEnabled,
        membershipId: presence.mediaMembershipId,
        microphoneRevision: presence.microphoneRevision,
      })
    }
  }

  summaries.sort((a, b) => {
    if ((a.activeAvatarCount > 0) !== (b.activeAvatarCount > 0)) {
      return a.activeAvatarCount > 0 ? -1 : 1
    }
    return Number(b.latestActivityAt - a.latestActivityAt)
  })
  return { spaces: summaries }
}

export async function createGridRoom(
  input: CreateGridRoomInput,
  context: FunctionContext,
): Promise<CreateGridRoomResult> {
  const startedAt = Date.now()
  const spaceId = positiveId(input.spaceId, RealtimeRpcError.SpaceIdInvalid)
  log.debug("GRID_TRACE phase=create_rpc_start", {
    spaceId,
    userId: context.currentUserId,
    sessionId: context.currentSessionId,
  })
  await ensureGridAvailable(spaceId, context.currentUserId)

  const state = await db.transaction(async (tx) => {
    await lockGridMutations(tx)
    await ensureCurrentSession(tx, context)
    await lockUser(tx, context.currentUserId)

    const state: GridMutationState = {
      affectedSpaceIds: new Set([spaceId]),
      endedConnections: [],
    }
    const existing = await getActivePresenceWithRoom(tx, context.currentUserId, state)
    if (existing && existing.room.spaceId === spaceId && existing.room.title === null) {
      const [occupancy] = await tx
        .select({ value: count() })
        .from(gridPresence)
        .where(and(eq(gridPresence.roomId, existing.room.id), gt(gridPresence.leaseExpiresAt, new Date())))

      if (Number(occupancy?.value ?? 0) === 1) {
        await claimPresence(tx, context, existing.room.id)
        state.changedRoomId = existing.room.id
        return state
      }
    }

    const [room] = await tx
      .insert(gridRooms)
      .values({ spaceId, createdByUserId: context.currentUserId })
      .returning()
    if (!room) throw RealtimeRpcError.InternalError()

    state.changedRoomId = room.id
    await movePresence(tx, context, room, existing, state)
    return state
  })

  await notifyGridChanged(state)
  const [grids, connection] = await Promise.all([
    buildGrids(state.affectedSpaceIds, context),
    state.changedRoomId
      ? credentialsForParticipant(state.changedRoomId, context.currentUserId, context.currentSessionId)
      : undefined,
    state.changedRoomId ? notifyConnectionReady(state.changedRoomId) : undefined,
  ])
  log.debug("GRID_TRACE phase=create_rpc_done", {
    spaceId,
    roomId: state.changedRoomId,
    hasCredentials: connection !== undefined,
    elapsedMs: Date.now() - startedAt,
  })
  return {
    grids,
    connection,
  }
}

export async function joinGridRoom(
  input: JoinGridRoomInput,
  context: FunctionContext,
): Promise<JoinGridRoomResult> {
  const startedAt = Date.now()
  const roomId = positiveId(input.roomId, RealtimeRpcError.BadRequest)
  log.debug("GRID_TRACE phase=join_rpc_start", {
    roomId,
    userId: context.currentUserId,
    sessionId: context.currentSessionId,
  })

  const state = await db.transaction(async (tx) => {
    await lockGridMutations(tx)
    await ensureCurrentSession(tx, context)
    await lockUser(tx, context.currentUserId)

    const [room] = await tx.select().from(gridRooms).where(eq(gridRooms.id, roomId)).for("update").limit(1)
    if (!room) throw RealtimeRpcError.BadRequest()
    await ensureGridAvailable(room.spaceId, context.currentUserId, tx)

    const state: GridMutationState = {
      affectedSpaceIds: new Set([room.spaceId]),
      changedRoomId: room.id,
      endedConnections: [],
    }
    const existing = await getActivePresenceWithRoom(tx, context.currentUserId, state)
    if (existing?.room.id === room.id) {
      await claimPresence(tx, context, room.id)
      return state
    }

    const admin = await isSpaceAdmin(tx, room.spaceId, context.currentUserId)
    if (room.locked && !admin) throw RealtimeRpcError.BadRequest()

    const [occupancy] = await tx
      .select({ value: count() })
      .from(gridPresence)
      .where(and(eq(gridPresence.roomId, room.id), gt(gridPresence.leaseExpiresAt, new Date())))
    if (Number(occupancy?.value ?? 0) >= MAX_ROOM_CAPACITY) throw RealtimeRpcError.BadRequest()

    await movePresence(tx, context, room, existing, state)
    return state
  })

  log.debug("GRID_TRACE phase=join_transaction_done", {
    roomId,
    elapsedMs: Date.now() - startedAt,
  })
  await notifyGridChanged(state)
  const [grids, connection] = await Promise.all([
    buildGrids(state.affectedSpaceIds, context),
    credentialsForParticipant(roomId, context.currentUserId, context.currentSessionId),
    notifyConnectionReady(roomId),
  ])
  log.debug("GRID_TRACE phase=join_rpc_done", {
    roomId,
    generation: connection?.connection?.generation,
    hasCredentials: connection !== undefined,
    elapsedMs: Date.now() - startedAt,
  })
  return {
    grids,
    connection,
  }
}

export async function leaveGridRoom(
  input: LeaveGridRoomInput,
  context: FunctionContext,
): Promise<LeaveGridRoomResult> {
  const expectedRoomId = positiveId(input.expectedRoomId, RealtimeRpcError.BadRequest)

  const state = await db.transaction(async (tx) => {
    await lockGridMutations(tx)
    await lockUser(tx, context.currentUserId)
    const existing = await getPresenceWithRoom(tx, context.currentUserId)
    if (!existing || existing.room.id !== expectedRoomId || existing.presence.ownerSessionId !== context.currentSessionId) {
      return { affectedSpaceIds: new Set<number>(), endedConnections: [] }
    }

    const activeConnection = activeGridConnection(existing.room)
    await tx.delete(gridPresence).where(eq(gridPresence.userId, context.currentUserId))
    const endedConnection = await reconcileGridRoom(tx, existing.room.id)
    const state: GridMutationState = {
      affectedSpaceIds: new Set([existing.room.spaceId]),
      changedRoomId: existing.room.id,
      endedConnections: endedConnection ? [endedConnection] : [],
    }
    if (activeConnection) {
      await recordGridParticipantRevocation(
        tx,
        state,
        activeConnection,
        context.currentUserId,
        existing.presence.mediaMembershipId,
      )
    }
    return state
  })

  await notifyGridChanged(state)
  return { grids: await buildGrids(state.affectedSpaceIds, context) }
}

export async function setGridRoomTitle(
  input: SetGridRoomTitleInput,
  context: FunctionContext,
): Promise<SetGridRoomTitleResult> {
  const roomId = positiveId(input.roomId, RealtimeRpcError.BadRequest)
  const normalizedTitle = normalizeTitle(input.title)

  const spaceId = await db.transaction(async (tx) => {
    await lockGridMutations(tx)
    const room = await getLockedRoom(tx, roomId)
    await ensureGridAvailable(room.spaceId, context.currentUserId, tx)
    await ensureCanRenameRoom(tx, room.spaceId, context.currentUserId)

    if (normalizedTitle && room.title === null) {
      const [namedRoomCount] = await tx
        .select({ value: count() })
        .from(gridRooms)
        .where(and(eq(gridRooms.spaceId, room.spaceId), isNotNull(gridRooms.title)))
      if (Number(namedRoomCount?.value ?? 0) >= MAX_NAMED_ROOMS_PER_SPACE) throw RealtimeRpcError.BadRequest()
    }

    try {
      await tx.update(gridRooms).set({ title: normalizedTitle, updatedAt: new Date() }).where(eq(gridRooms.id, room.id))
    } catch (error) {
      if (isUniqueViolation(error)) throw RealtimeRpcError.BadRequest()
      throw error
    }
    await reconcileGridRoom(tx, room.id)
    return room.spaceId
  })

  await notifyGridChanged({ affectedSpaceIds: new Set([spaceId]), changedRoomId: roomId, endedConnections: [] })
  return { grid: await buildGrid(spaceId, context) }
}

export async function setGridRoomLocked(
  input: SetGridRoomLockedInput,
  context: FunctionContext,
): Promise<SetGridRoomLockedResult> {
  const roomId = positiveId(input.roomId, RealtimeRpcError.BadRequest)

  const spaceId = await db.transaction(async (tx) => {
    await lockGridMutations(tx)
    const room = await getLockedRoom(tx, roomId)
    await ensureGridAvailable(room.spaceId, context.currentUserId, tx)
    const admin = await isSpaceAdmin(tx, room.spaceId, context.currentUserId)
    const publicSpace = await isPublicSpace(tx, room.spaceId)
    const [presence] = await tx
      .select({ userId: gridPresence.userId })
      .from(gridPresence)
      .where(
        and(
          eq(gridPresence.roomId, room.id),
          eq(gridPresence.userId, context.currentUserId),
          eq(gridPresence.ownerSessionId, context.currentSessionId),
          gt(gridPresence.leaseExpiresAt, new Date()),
        ),
      )
      .limit(1)
    if (publicSpace ? !admin : !presence) throw RealtimeRpcError.BadRequest()

    const [occupancy] = await tx
      .select({ value: count() })
      .from(gridPresence)
      .where(and(eq(gridPresence.roomId, room.id), gt(gridPresence.leaseExpiresAt, new Date())))
    if (input.locked && Number(occupancy?.value ?? 0) === 0) throw RealtimeRpcError.BadRequest()

    await tx.update(gridRooms).set({ locked: input.locked, updatedAt: new Date() }).where(eq(gridRooms.id, room.id))
    return room.spaceId
  })

  await notifyGridChanged({ affectedSpaceIds: new Set([spaceId]), changedRoomId: roomId, endedConnections: [] })
  return { grid: await buildGrid(spaceId, context) }
}

export async function deleteGridRoom(
  input: DeleteGridRoomInput,
  context: FunctionContext,
): Promise<DeleteGridRoomResult> {
  const roomId = positiveId(input.roomId, RealtimeRpcError.BadRequest)

  const spaceId = await db.transaction(async (tx) => {
    await lockGridMutations(tx)
    const room = await getLockedRoom(tx, roomId)
    await ensureGridAvailable(room.spaceId, context.currentUserId, tx)
    await ensureCreatorOrAdmin(tx, room, context.currentUserId)

    const [occupancy] = await tx
      .select({ value: count() })
      .from(gridPresence)
      .where(and(eq(gridPresence.roomId, room.id), gt(gridPresence.leaseExpiresAt, new Date())))
    if (Number(occupancy?.value ?? 0) !== 0) throw RealtimeRpcError.BadRequest()

    await tx.delete(gridRooms).where(eq(gridRooms.id, room.id))
    return room.spaceId
  })

  await notifyGridChanged({ affectedSpaceIds: new Set([spaceId]), changedRoomId: roomId, endedConnections: [] })
  return { grid: await buildGrid(spaceId, context) }
}

export async function prepareGridConnection(
  input: PrepareGridConnectionInput,
  context: FunctionContext,
): Promise<PrepareGridConnectionResult> {
  const startedAt = Date.now()
  const roomId = positiveId(input.roomId, RealtimeRpcError.BadRequest)
  log.debug("GRID_TRACE phase=prepare_rpc_start", {
    roomId,
    generation: input.generation,
    userId: context.currentUserId,
    sessionId: context.currentSessionId,
  })
  const preparation = await db.transaction(async (tx) => {
    await lockGridMutations(tx)
    await ensureCurrentSession(tx, context)

    const [row] = await tx
      .select({ room: gridRooms, presence: gridPresence, user: users })
      .from(gridRooms)
      .innerJoin(
        gridPresence,
        and(eq(gridPresence.roomId, gridRooms.id), eq(gridPresence.userId, context.currentUserId)),
      )
      .innerJoin(users, eq(users.id, gridPresence.userId))
      .where(
        and(
          eq(gridRooms.id, roomId),
          eq(gridRooms.connectionGeneration, input.generation),
          eq(gridPresence.ownerSessionId, context.currentSessionId),
          gt(gridPresence.leaseExpiresAt, new Date()),
        ),
      )
      .for("update")
      .limit(1)

    if (!row || !row.room.connectionStartedAt) return { active: false as const }
    await ensureGridAvailable(row.room.spaceId, context.currentUserId, tx)
    const connection = encodeRoom(row.room).connection
    if (!connection) return { active: false as const }
    return {
      active: true as const,
      connection,
      userId: row.user.id,
      displayName: displayName(row.user),
      participantIdentity: gridParticipantIdentity(row.user.id, row.presence.mediaMembershipId),
      mediaMembershipId: row.presence.mediaMembershipId,
      spaceId: row.room.spaceId,
    }
  })

  if (!preparation.active) {
    log.debug("GRID_TRACE phase=prepare_rpc_unavailable", {
      roomId,
      generation: input.generation,
      elapsedMs: Date.now() - startedAt,
    })
    return { unavailableReason: GridConnectionUnavailableReason.NOT_ACTIVE }
  }
  let credentials
  try {
    credentials = await createGridConnectionCredentials({
      connection: preparation.connection,
      userId: preparation.userId,
      displayName: preparation.displayName,
      participantIdentity: preparation.participantIdentity,
    })
  } catch (error) {
    Log.shared.warn("Failed to mint prepared Grid connection credentials", {
      roomId,
      generation: input.generation,
      userId: context.currentUserId,
      error,
    })
    credentials = undefined
  }
  if (credentials) {
    const stillActive = await gridCredentialAuthorityIsActive({
      roomId,
      generation: input.generation,
      spaceId: preparation.spaceId,
      userId: context.currentUserId,
      sessionId: context.currentSessionId,
      mediaMembershipId: preparation.mediaMembershipId,
    })
    if (!stillActive) {
      log.debug("GRID_TRACE phase=prepare_rpc_stale_after_mint", {
        roomId,
        generation: input.generation,
        elapsedMs: Date.now() - startedAt,
      })
      return { unavailableReason: GridConnectionUnavailableReason.NOT_ACTIVE }
    }
  }
  log.debug("GRID_TRACE phase=prepare_rpc_done", {
    roomId,
    generation: input.generation,
    hasCredentials: credentials !== undefined,
    elapsedMs: Date.now() - startedAt,
  })
  return credentials
    ? { connection: credentials, unavailableReason: GridConnectionUnavailableReason.UNSPECIFIED }
    : { unavailableReason: GridConnectionUnavailableReason.PROVIDER_UNAVAILABLE }
}

async function gridCredentialAuthorityIsActive(input: {
  roomId: number
  generation: number
  spaceId: number
  userId: number
  sessionId: number
  mediaMembershipId: string
}): Promise<boolean> {
  return db.transaction(async (tx) => {
    await lockGridMutations(tx)
    const [active] = await tx
      .select({ roomId: gridRooms.id })
      .from(gridRooms)
      .innerJoin(
        gridPresence,
        and(
          eq(gridPresence.roomId, gridRooms.id),
          eq(gridPresence.userId, input.userId),
          eq(gridPresence.ownerSessionId, input.sessionId),
          eq(gridPresence.mediaMembershipId, input.mediaMembershipId),
          gt(gridPresence.leaseExpiresAt, new Date()),
        ),
      )
      .innerJoin(
        members,
        and(
          eq(members.spaceId, gridRooms.spaceId),
          eq(members.userId, gridPresence.userId),
        ),
      )
      .innerJoin(
        sessions,
        and(
          eq(sessions.id, gridPresence.ownerSessionId),
          eq(sessions.userId, gridPresence.userId),
          isNull(sessions.revoked),
        ),
      )
      .where(
        and(
          eq(gridRooms.id, input.roomId),
          eq(gridRooms.spaceId, input.spaceId),
          eq(gridRooms.connectionGeneration, input.generation),
          isNotNull(gridRooms.connectionStartedAt),
        ),
      )
      .limit(1)
    if (!active) return false
    return (await SpaceSettingsModel.getStored(input.spaceId, tx)).gridEnabled
  })
}

export async function setGridAvatarMicrophoneEnabled(
  input: SetGridAvatarMicrophoneEnabledInput,
  context: FunctionContext,
): Promise<SetGridAvatarMicrophoneEnabledResult> {
  const roomId = positiveId(input.expectedRoomId, RealtimeRpcError.BadRequest)
  const stateUpdate = await db.transaction(async (tx) => {
    await lockGridMutations(tx)
    const [row] = await tx
      .select({ spaceId: gridRooms.spaceId })
      .from(gridPresence)
      .innerJoin(gridRooms, eq(gridRooms.id, gridPresence.roomId))
      .where(
        and(
          eq(gridPresence.userId, context.currentUserId),
          eq(gridPresence.ownerSessionId, context.currentSessionId),
          eq(gridPresence.roomId, roomId),
          gt(gridPresence.leaseExpiresAt, new Date()),
        ),
      )
      .limit(1)
    if (!row) throw RealtimeRpcError.BadRequest()
    await ensureGridAvailable(row.spaceId, context.currentUserId, tx)
    const updated = await setGridAvatarMicrophoneState(tx, {
      userId: context.currentUserId,
      ownerSessionId: context.currentSessionId,
      roomId,
      enabled: input.enabled,
    })
    if (!updated) throw RealtimeRpcError.BadRequest()
    return { spaceId: row.spaceId, ...updated }
  })
  await sendMessageToRealtimeSpace(stateUpdate.spaceId, {
    oneofKind: "grid",
    grid: {
      event: {
        oneofKind: "avatarStateChanged",
        avatarStateChanged: {
          spaceId: BigInt(stateUpdate.spaceId),
          roomId: BigInt(roomId),
          userId: BigInt(context.currentUserId),
          microphoneEnabled: input.enabled,
          membershipId: stateUpdate.membershipId,
          microphoneRevision: stateUpdate.revision,
        },
      },
    },
  })
  log.debug("GRID_TRACE phase=avatar_microphone_changed", {
    spaceId: stateUpdate.spaceId,
    roomId,
    userId: context.currentUserId,
    sessionId: context.currentSessionId,
    enabled: input.enabled,
  })
  return { enabled: input.enabled }
}

async function movePresence(
  tx: Transaction,
  context: FunctionContext,
  targetRoom: DbGridRoom,
  existing: Awaited<ReturnType<typeof getPresenceWithRoom>>,
  state: GridMutationState,
) {
  if (existing) {
    state.affectedSpaceIds.add(existing.room.spaceId)
  }

  if (existing && existing.room.id !== targetRoom.id) {
    const connection = activeGridConnection(existing.room)
    if (connection) {
      await recordGridParticipantRevocation(
        tx,
        state,
        connection,
        context.currentUserId,
        existing.presence.mediaMembershipId,
      )
    }
  }

  await claimPresence(tx, context, targetRoom.id)

  if (existing && existing.room.id !== targetRoom.id) {
    const endedConnection = await reconcileGridRoom(tx, existing.room.id)
    if (endedConnection) state.endedConnections.push(endedConnection)
  }
  const endedConnection = await reconcileGridRoom(tx, targetRoom.id)
  if (endedConnection) state.endedConnections.push(endedConnection)
}

async function claimPresence(tx: Transaction, context: FunctionContext, roomId: number) {
  const now = new Date()
  await tx
    .insert(gridPresence)
    .values({
      userId: context.currentUserId,
      roomId,
      ownerSessionId: context.currentSessionId,
      joinedAt: now,
      leaseExpiresAt: new Date(now.getTime() + PRESENCE_LEASE_MS),
    })
    .onConflictDoUpdate({
      target: gridPresence.userId,
      set: {
        roomId,
        ownerSessionId: context.currentSessionId,
        joinedAt: sql`case when ${gridPresence.roomId} = ${roomId} and ${gridPresence.ownerSessionId} = ${context.currentSessionId} then ${gridPresence.joinedAt} else now() end`,
        mediaMembershipId: sql`case when ${gridPresence.roomId} = ${roomId} and ${gridPresence.ownerSessionId} = ${context.currentSessionId} then ${gridPresence.mediaMembershipId} else gen_random_uuid() end`,
        microphoneEnabled: sql`case when ${gridPresence.ownerSessionId} = ${context.currentSessionId} then ${gridPresence.microphoneEnabled} else false end`,
        microphoneRevision: sql`case when ${gridPresence.roomId} = ${roomId} and ${gridPresence.ownerSessionId} = ${context.currentSessionId} then ${gridPresence.microphoneRevision} else 0 end`,
        leaseExpiresAt: new Date(now.getTime() + PRESENCE_LEASE_MS),
      },
    })
}

async function refreshPresenceLeases(input?: { spaceId: number; context: FunctionContext }) {
  const affected = await db.transaction(async (tx) => {
    await lockGridMutations(tx)

    // Selection and deletion must use exactly the same cutoff so every deleted
    // presence has a corresponding room reconciliation/provider revocation.
    const cutoff = new Date()
    const expired = await tx
      .select({
        room: gridRooms,
        userId: gridPresence.userId,
        mediaMembershipId: gridPresence.mediaMembershipId,
      })
      .from(gridPresence)
      .innerJoin(gridRooms, eq(gridRooms.id, gridPresence.roomId))
      .where(lte(gridPresence.leaseExpiresAt, cutoff))
    if (expired.length > 0) {
      await tx.delete(gridPresence).where(lte(gridPresence.leaseExpiresAt, cutoff))
    }
    const endedConnections: GridConnection[] = []
    for (const roomId of new Set(expired.map(({ room }) => room.id))) {
      const endedConnection = await reconcileGridRoom(tx, roomId)
      if (endedConnection) endedConnections.push(endedConnection)
    }
    if (input) await renewOwnedPresence(tx, input.spaceId, input.context, cutoff)
    const state: GridMutationState = {
      affectedSpaceIds: new Set(expired.map(({ room }) => room.spaceId)),
      endedConnections,
    }
    for (const { room, userId, mediaMembershipId } of expired) {
      const connection = activeGridConnection(room)
      if (connection) {
        await recordGridParticipantRevocation(tx, state, connection, userId, mediaMembershipId)
      }
    }
    return state
  })
  if (affected.affectedSpaceIds.size > 0) await notifyGridChanged(affected)
}

async function renewOwnedPresence(
  tx: Transaction,
  spaceId: number,
  context: FunctionContext,
  cutoff: Date,
) {
  const [presence] = await tx
    .select({ roomId: gridPresence.roomId })
    .from(gridPresence)
    .innerJoin(gridRooms, and(eq(gridRooms.id, gridPresence.roomId), eq(gridRooms.spaceId, spaceId)))
    .where(
      and(
        eq(gridPresence.userId, context.currentUserId),
        eq(gridPresence.ownerSessionId, context.currentSessionId),
        gt(gridPresence.leaseExpiresAt, cutoff),
      ),
    )
    .limit(1)
  if (!presence) return

  await tx
    .update(gridPresence)
    .set({ leaseExpiresAt: new Date(Date.now() + PRESENCE_LEASE_MS) })
    .where(
      and(
        eq(gridPresence.userId, context.currentUserId),
        eq(gridPresence.ownerSessionId, context.currentSessionId),
        eq(gridPresence.roomId, presence.roomId),
        gt(gridPresence.leaseExpiresAt, cutoff),
      ),
    )
}

async function buildGrids(spaceIds: Set<number>, context: FunctionContext): Promise<Grid[]> {
  return Promise.all([...spaceIds].sort((a, b) => a - b).map((spaceId) => buildGrid(spaceId, context)))
}

async function buildGrid(spaceId: number, context: FunctionContext): Promise<Grid> {
  // Snapshot content and its revision are read under the same lock used by
  // every Grid mutation. A response can therefore be older than a later
  // response, but it can never label old content with a newer revision.
  const snapshot = await db.transaction(async (tx) => {
    await lockGridMutations(tx)
    const settings = await SpaceSettingsModel.getStored(spaceId, tx)
    const [space] = await tx
      .select({ revision: spaces.gridRevision })
      .from(spaces)
      .where(eq(spaces.id, spaceId))
      .limit(1)
    if (!space) throw RealtimeRpcError.SpaceIdInvalid()

    const roomRows = settings.gridEnabled
      ? await tx
          .select({ room: gridRooms, presence: gridPresence })
          .from(gridRooms)
          .leftJoin(
            gridPresence,
            and(eq(gridPresence.roomId, gridRooms.id), gt(gridPresence.leaseExpiresAt, new Date())),
          )
          .where(eq(gridRooms.spaceId, spaceId))
          .orderBy(asc(gridRooms.createdAt), asc(gridRooms.id), asc(gridPresence.joinedAt))
      : []
    return { settings, revision: space.revision, roomRows }
  })

  if (!snapshot.settings.gridEnabled) {
    return {
      spaceId: BigInt(spaceId),
      enabled: false,
      rooms: [],
      revision: BigInt(snapshot.revision),
    }
  }

  const { roomRows } = snapshot

  const userIds = [...new Set(roomRows.flatMap((row) => (row.presence ? [row.presence.userId] : [])))]
  const usersWithPhotos = userIds.length > 0 ? await UsersModel.getUsersWithPhotos(userIds) : []
  const encodedUsers = new Map(
    usersWithPhotos.map(({ user, photoFile }) => [user.id, encodeUser({ user, photoFile, min: true })]),
  )
  const rooms = new Map<number, GridRoom>()
  let currentRoomId: bigint | undefined

  for (const row of roomRows) {
    let room = rooms.get(row.room.id)
    if (!room) {
      room = encodeRoom(row.room)
      rooms.set(row.room.id, room)
    }
    if (row.presence) {
      const user = encodedUsers.get(row.presence.userId)
      if (!user) continue
      const ownedByCurrentSession =
        row.presence.userId === context.currentUserId && row.presence.ownerSessionId === context.currentSessionId
      room.avatars.push({
        user,
        joinedAt: encodeDateStrict(row.presence.joinedAt),
        ownedByCurrentSession,
        microphoneEnabled: row.presence.microphoneEnabled,
        membershipId: row.presence.mediaMembershipId,
        microphoneRevision: row.presence.microphoneRevision,
      })
      if (ownedByCurrentSession) currentRoomId = BigInt(row.room.id)
    }
  }

  return {
    spaceId: BigInt(spaceId),
    enabled: true,
    rooms: [...rooms.values()],
    currentRoomId,
    revision: BigInt(snapshot.revision),
  }
}

function encodeRoom(room: DbGridRoom): GridRoom {
  return {
    id: BigInt(room.id),
    spaceId: BigInt(room.spaceId),
    createdByUserId: BigInt(room.createdByUserId),
    title: room.title ?? undefined,
    locked: room.locked,
    createdAt: encodeDateStrict(room.createdAt),
    updatedAt: encodeDateStrict(room.updatedAt),
    avatars: [],
    connection: room.connectionStartedAt
      ? {
          roomId: BigInt(room.id),
          generation: room.connectionGeneration,
          startedAt: encodeDateStrict(room.connectionStartedAt),
        }
      : undefined,
  }
}

async function getPresenceWithRoom(tx: Transaction, userId: number) {
  const [row] = await tx
    .select({ presence: gridPresence, room: gridRooms })
    .from(gridPresence)
    .innerJoin(gridRooms, eq(gridRooms.id, gridPresence.roomId))
    .where(eq(gridPresence.userId, userId))
    .limit(1)
  return row
}

async function getActivePresenceWithRoom(
  tx: Transaction,
  userId: number,
  state: GridMutationState,
) {
  const existing = await getPresenceWithRoom(tx, userId)
  if (!existing || existing.presence.leaseExpiresAt > new Date()) return existing

  const activeConnection = activeGridConnection(existing.room)
  await tx.delete(gridPresence).where(eq(gridPresence.userId, userId))
  state.affectedSpaceIds.add(existing.room.spaceId)
  const endedConnection = await reconcileGridRoom(tx, existing.room.id)
  if (endedConnection) state.endedConnections.push(endedConnection)
  if (activeConnection) {
    await recordGridParticipantRevocation(
      tx,
      state,
      activeConnection,
      userId,
      existing.presence.mediaMembershipId,
    )
  }
  return undefined
}

async function getLockedRoom(tx: Transaction, roomId: number): Promise<DbGridRoom> {
  const [room] = await tx.select().from(gridRooms).where(eq(gridRooms.id, roomId)).for("update").limit(1)
  if (!room) throw RealtimeRpcError.BadRequest()
  return room
}

async function ensureGridAvailable(spaceId: number, userId: number, tx?: Transaction) {
  if (!tx) await AccessGuards.ensureSpaceMember(spaceId, userId)
  else {
    const [member] = await tx
      .select({ id: members.id })
      .from(members)
      .where(and(eq(members.spaceId, spaceId), eq(members.userId, userId)))
      .limit(1)
    if (!member) throw RealtimeRpcError.SpaceIdInvalid()
  }
  const settings = await SpaceSettingsModel.getStored(spaceId, tx)
  if (!settings.gridEnabled) throw RealtimeRpcError.BadRequest()
}

async function ensureCurrentSession(tx: Transaction, context: FunctionContext) {
  const [session] = await tx
    .select({ id: sessions.id })
    .from(sessions)
    .where(
      and(
        eq(sessions.id, context.currentSessionId),
        eq(sessions.userId, context.currentUserId),
        sql`${sessions.revoked} is null`,
      ),
    )
    .for("update")
    .limit(1)
  if (!session) throw RealtimeRpcError.Unauthenticated()
}

async function lockUser(tx: Transaction, userId: number) {
  const [user] = await tx.select({ id: users.id }).from(users).where(eq(users.id, userId)).for("update").limit(1)
  if (!user) throw RealtimeRpcError.UserIdInvalid()
}

async function isSpaceAdmin(tx: Transaction, spaceId: number, userId: number): Promise<boolean> {
  const [member] = await tx
    .select({ role: members.role })
    .from(members)
    .where(and(eq(members.spaceId, spaceId), eq(members.userId, userId)))
    .limit(1)
  return member?.role === "owner" || member?.role === "admin"
}

async function isPublicSpace(tx: Transaction, spaceId: number): Promise<boolean> {
  const [space] = await tx
    .select({ isPublic: spaces.isPublic })
    .from(spaces)
    .where(eq(spaces.id, spaceId))
    .limit(1)
  if (!space) throw RealtimeRpcError.SpaceIdInvalid()
  return space.isPublic
}

async function ensureCanRenameRoom(tx: Transaction, spaceId: number, userId: number) {
  if (!(await isPublicSpace(tx, spaceId))) return
  if (!(await isSpaceAdmin(tx, spaceId, userId))) throw RealtimeRpcError.BadRequest()
}

async function ensureCreatorOrAdmin(tx: Transaction, room: DbGridRoom, userId: number) {
  if (room.createdByUserId === userId) return
  if (!(await isSpaceAdmin(tx, room.spaceId, userId))) throw RealtimeRpcError.BadRequest()
}

async function credentialsForParticipant(roomId: number, userId: number, sessionId: number) {
  const startedAt = Date.now()
  const [row] = await db
    .select({ room: gridRooms, presence: gridPresence, user: users })
    .from(gridRooms)
    .innerJoin(
      gridPresence,
      and(
        eq(gridPresence.roomId, gridRooms.id),
        eq(gridPresence.userId, userId),
        eq(gridPresence.ownerSessionId, sessionId),
        gt(gridPresence.leaseExpiresAt, new Date()),
      ),
    )
    .innerJoin(users, eq(users.id, gridPresence.userId))
    .where(eq(gridRooms.id, roomId))
    .limit(1)
  const connection = row ? encodeRoom(row.room).connection : undefined
  if (!row || !connection) {
    log.debug("GRID_TRACE phase=participant_credentials_unavailable", {
      roomId,
      userId,
      sessionId,
      elapsedMs: Date.now() - startedAt,
    })
    return undefined
  }
  let credentials
  try {
    credentials = await createGridConnectionCredentials({
      connection,
      userId,
      displayName: displayName(row.user),
      participantIdentity: gridParticipantIdentity(userId, row.presence.mediaMembershipId),
    })
  } catch (error) {
    Log.shared.warn("Failed to mint committed Grid participant credentials", {
      roomId,
      generation: connection.generation,
      userId,
      sessionId,
      error,
    })
    return undefined
  }
  if (
    credentials
    && !(await gridCredentialAuthorityIsActive({
      roomId,
      generation: connection.generation,
      spaceId: row.room.spaceId,
      userId,
      sessionId,
      mediaMembershipId: row.presence.mediaMembershipId,
    }))
  ) {
    log.debug("GRID_TRACE phase=participant_credentials_stale_after_mint", {
      roomId,
      generation: connection.generation,
      userId,
      sessionId,
      elapsedMs: Date.now() - startedAt,
    })
    return undefined
  }
  log.debug("GRID_TRACE phase=participant_credentials_done", {
    roomId,
    generation: connection.generation,
    userId,
    sessionId,
    hasCredentials: credentials !== undefined,
    elapsedMs: Date.now() - startedAt,
  })
  return credentials
}

async function notifyConnectionReady(roomId: number) {
  try {
    await notifyConnectionReadyUnchecked(roomId)
  } catch (error) {
    // The committed room state remains authoritative. Participants can request
    // credentials again through PrepareGridConnection after refetch/reconnect.
    Log.shared.warn("Failed to send Grid connection-ready notification", { roomId, error })
  }
}

async function notifyConnectionReadyUnchecked(roomId: number) {
  const startedAt = Date.now()
  const rows = await db
    .select({ room: gridRooms, presence: gridPresence, user: users })
    .from(gridRooms)
    .innerJoin(
      gridPresence,
      and(eq(gridPresence.roomId, gridRooms.id), gt(gridPresence.leaseExpiresAt, new Date())),
    )
    .innerJoin(users, eq(users.id, gridPresence.userId))
    .where(eq(gridRooms.id, roomId))
  const connection = rows[0] ? encodeRoom(rows[0].room).connection : undefined
  if (!connection) {
    log.debug("GRID_TRACE phase=ready_push_skipped", {
      roomId,
      participantCount: rows.length,
      elapsedMs: Date.now() - startedAt,
    })
    return
  }

  await Promise.all(
    rows.map(async (row) => {
      const credentials = await createGridConnectionCredentials({
        connection,
        userId: row.user.id,
        displayName: displayName(row.user),
        participantIdentity: gridParticipantIdentity(row.user.id, row.presence.mediaMembershipId),
      })
      if (!credentials) return
      const stillActive = await gridCredentialAuthorityIsActive({
        roomId,
        generation: connection.generation,
        spaceId: row.room.spaceId,
        userId: row.user.id,
        sessionId: row.presence.ownerSessionId,
        mediaMembershipId: row.presence.mediaMembershipId,
      })
      if (!stillActive) {
        log.debug("GRID_TRACE phase=ready_push_stale_after_mint", {
          roomId,
          generation: connection.generation,
          userId: row.user.id,
          sessionId: row.presence.ownerSessionId,
        })
        return
      }
      await sendMessageToRealtimeSession(row.user.id, row.presence.ownerSessionId, {
        oneofKind: "grid",
        grid: {
          event: {
            oneofKind: "connectionReady",
            connectionReady: { credentials },
          },
        },
      })
    }),
  )
  log.debug("GRID_TRACE phase=ready_push_done", {
    roomId,
    generation: connection.generation,
    participantCount: rows.length,
    elapsedMs: Date.now() - startedAt,
  })
}

function displayName(user: { firstName: string | null; lastName: string | null; username: string | null }): string {
  return [user.firstName, user.lastName].filter(Boolean).join(" ") || user.username || "Inline member"
}

function normalizeTitle(value: string): string | null {
  const title = value.trim().replace(/\s+/g, " ")
  if (title.length === 0) return null
  if (title.length > MAX_ROOM_TITLE_LENGTH) throw RealtimeRpcError.BadRequest()
  return title
}

function positiveId(value: bigint, error: () => RealtimeRpcError): number {
  const id = Number(value)
  if (!Number.isSafeInteger(id) || id <= 0) throw error()
  return id
}

function isUniqueViolation(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && error.code === "23505"
}
