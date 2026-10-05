import { randomUUID } from "node:crypto"
import {
  GridTranscriptDestination,
  type OpenGridThreadInput,
  type OpenGridThreadResult,
  type SetGridTranscriptionInput,
  type SetGridTranscriptionResult,
  type ListGridTranscriptsInput,
  type ListGridTranscriptsResult,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import {
  chats,
  members,
  sessions,
  spaces,
  users,
  gridPresence,
  gridRooms,
  gridTranscriptionRuns,
  type DbGridTranscriptionRun,
} from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import type { FunctionContext } from "./_types"
import { getGrid } from "./grid"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { lockGridMutations } from "@in/server/modules/grid/roomLifecycle"
import { getLiveKitGridConfig, durableLiveKitProviderTarget } from "@in/server/modules/grid/livekit"
import { notifyGridSpaceChanged } from "@in/server/modules/grid/realtime"
import { SpaceSettingsModel } from "@in/server/db/models/spaceSettings"
import {
  captureStates,
  gridTranscriptionRetirementReasons,
  GRID_TRANSCRIPTION_MAX_MS,
  GRID_TRANSCRIPTION_MAX_SPEAKERS,
  intactDestination,
  latestRoomTranscription,
  stopGridTranscription,
  transcriptionAvailable,
  transcriptionConfig,
  supportedGridTranscriptionSession,
} from "@in/server/modules/grid/transcription/state"
import {
  ensureGridRoomThread,
  createGridTranscriptDestination,
  grantGridTranscriptUsers,
  insertGridTranscriptContinuationLink,
} from "@in/server/modules/grid/transcription/threads"
import { insertGridTranscriptMessage } from "@in/server/modules/grid/transcription/messages"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, eq, gt, inArray, isNull, desc, or, notInArray } from "drizzle-orm"

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
function id(value: bigint) {
  const n = Number(value)
  if (!Number.isSafeInteger(n) || n <= 0) throw RealtimeRpcError.BadRequest()
  return n
}
function uuid(value: string) {
  if (!uuidPattern.test(value)) throw RealtimeRpcError.BadRequest()
  return value.toLowerCase()
}
async function roomAuthority(tx: Transaction, roomId: number, context: FunctionContext, membershipId?: string) {
  const [row] = await tx
    .select({ room: gridRooms, presence: gridPresence, session: sessions })
    .from(gridRooms)
    .innerJoin(
      gridPresence,
      and(
        eq(gridPresence.roomId, gridRooms.id),
        eq(gridPresence.userId, context.currentUserId),
        eq(gridPresence.ownerSessionId, context.currentSessionId),
        gt(gridPresence.leaseExpiresAt, new Date()),
      ),
    )
    .innerJoin(members, and(eq(members.spaceId, gridRooms.spaceId), eq(members.userId, context.currentUserId)))
    .innerJoin(spaces, and(eq(spaces.id, gridRooms.spaceId), isNull(spaces.deleted)))
    .innerJoin(
      sessions,
      and(
        eq(sessions.id, context.currentSessionId),
        eq(sessions.userId, context.currentUserId),
        isNull(sessions.revoked),
      ),
    )
    .where(
      and(eq(gridRooms.id, roomId), membershipId ? eq(gridPresence.mediaMembershipId, uuid(membershipId)) : undefined),
    )
    .limit(1)
  if (!row || !(await SpaceSettingsModel.getStored(row.room.spaceId, tx)).gridEnabled)
    throw RealtimeRpcError.BadRequest()
  return row
}
async function occupants(tx: Transaction, roomId: number) {
  return tx
    .select({ userId: gridPresence.userId, clientType: sessions.clientType, clientVersion: sessions.clientVersion })
    .from(gridPresence)
    .innerJoin(users, and(eq(users.id, gridPresence.userId), eq(users.bot, false)))
    .innerJoin(sessions, and(eq(sessions.id, gridPresence.ownerSessionId), isNull(sessions.revoked)))
    .where(and(eq(gridPresence.roomId, roomId), gt(gridPresence.leaseExpiresAt, new Date())))
}
/** Lock every associated chat before grants/runs, including cross-room continuation targets. */
export async function enrollGridRoomHistory(
  tx: Transaction,
  roomId: number,
  userIds: number[],
  extraChatIds: number[] = [],
) {
  const [room] = await tx.select().from(gridRooms).where(eq(gridRooms.id, roomId)).limit(1)
  if (!room) return
  const candidates =
    room.roomThreadId === null
      ? []
      : await tx.select().from(gridTranscriptionRuns).where(eq(gridTranscriptionRuns.sourceRoomId, roomId))
  const chatIds = [
    ...new Set([
      ...extraChatIds,
      ...(room.roomThreadId === null ? [] : [room.roomThreadId]),
      ...candidates.flatMap((run) => [run.roomChatId, run.destinationParentChatId, run.transcriptChatId]),
    ]),
  ].sort((a, b) => a - b)
  const locked = chatIds.length
    ? await tx.select().from(chats).where(inArray(chats.id, chatIds)).orderBy(chats.id).for("update")
    : []
  const boundParent = locked.find((chat) => chat.id === room.roomThreadId)
  const parents = new Set<number>()
  if (
    boundParent &&
    boundParent.type === "thread" &&
    boundParent.spaceId === room.spaceId &&
    boundParent.publicThread === false &&
    boundParent.parentChatId === null
  )
    parents.add(boundParent.id)
  else if (room.roomThreadId !== null)
    await tx.update(gridRooms).set({ roomThreadId: null }).where(eq(gridRooms.id, room.id))
  // History may have retired while waiting for chat ownership; refresh its durable reasons.
  const runs = candidates.length
    ? await tx.select().from(gridTranscriptionRuns).where(eq(gridTranscriptionRuns.sourceRoomId, roomId))
    : []
  for (const run of runs) if (await intactDestination(tx, run)) parents.add(run.destinationParentChatId)
  await grantGridTranscriptUsers(tx, { chatIds: [...parents], userIds })
}
export async function openGridThread(
  input: OpenGridThreadInput,
  context: FunctionContext,
): Promise<OpenGridThreadResult> {
  const result = await db.transaction(async (tx) => {
    await lockGridMutations(tx)
    const { room } = await roomAuthority(tx, id(input.roomId), context, uuid(input.expectedMembershipId))
    const userIds = (await occupants(tx, room.id)).map((r) => r.userId)
    await enrollGridRoomHistory(tx, room.id, userIds)
    const chatId = await ensureGridRoomThread(tx, {
      room,
      actorUserId: context.currentUserId,
      participantUserIds: userIds,
    })
    await enrollGridRoomHistory(tx, room.id, userIds)
    return { chatId, spaceId: room.spaceId }
  })
  await notifyGridSpaceChanged(result.spaceId)
  return { chatId: BigInt(result.chatId), updates: [] }
}
async function canChooseDestination(
  tx: Transaction,
  run: DbGridTranscriptionRun,
  userId: number,
  requireSharing: boolean,
) {
  if (!(await intactDestination(tx, run))) return false
  const [child] = await tx.select().from(chats).where(eq(chats.id, run.transcriptChatId)).limit(1)
  const [parent] = await tx.select().from(chats).where(eq(chats.id, run.destinationParentChatId)).limit(1)
  if (!child || !parent) return false
  try {
    await AccessGuards.ensureChatAccess(child, userId, tx)
  } catch (error) {
    if (RealtimeRpcError.is(error)) return false
    throw error
  }
  if (!requireSharing || parent.createdBy === userId) return true
  const [member] = await tx
    .select()
    .from(members)
    .where(and(eq(members.spaceId, run.spaceId), eq(members.userId, userId)))
    .limit(1)
  return member?.role === "owner" || member?.role === "admin"
}
export async function listGridTranscripts(
  input: ListGridTranscriptsInput,
  context: FunctionContext,
): Promise<ListGridTranscriptsResult> {
  return db.transaction(async (tx) => {
    await lockGridMutations(tx)
    const { room } = await roomAuthority(tx, id(input.roomId), context)
    const retained = or(
      isNull(gridTranscriptionRuns.interruptionReason),
      notInArray(gridTranscriptionRuns.interruptionReason, [...gridTranscriptionRetirementReasons]),
    )
    const latest = tx.$with("grid_transcript_candidates").as(
      tx
        .selectDistinctOn([gridTranscriptionRuns.transcriptChatId])
        .from(gridTranscriptionRuns)
        .where(and(eq(gridTranscriptionRuns.spaceId, room.spaceId), retained))
        .orderBy(gridTranscriptionRuns.transcriptChatId, desc(gridTranscriptionRuns.createdAt)),
    )
    // Bound work to the latest 100 distinct retained transcripts, then return
    // at most 20 that the actor can read and legitimately share/continue.
    const rows = await tx.with(latest).select().from(latest).orderBy(desc(latest.createdAt)).limit(100)
    const acceptedRows = rows.length
      ? await tx
          .selectDistinctOn([gridTranscriptionRuns.transcriptChatId])
          .from(gridTranscriptionRuns)
          .where(
            and(
              eq(gridTranscriptionRuns.sourceRoomId, room.id),
              inArray(
                gridTranscriptionRuns.transcriptChatId,
                rows.map((run) => run.transcriptChatId),
              ),
              retained,
            ),
          )
          .orderBy(gridTranscriptionRuns.transcriptChatId, desc(gridTranscriptionRuns.createdAt))
      : []
    const acceptedByChat = new Map(acceptedRows.map((run) => [run.transcriptChatId, run]))
    const seen = new Set<number>()
    const transcripts: ListGridTranscriptsResult["transcripts"] = []
    for (const run of rows) {
      const accepted = acceptedByChat.get(run.transcriptChatId)
      const representative =
        accepted && (await canChooseDestination(tx, accepted, context.currentUserId, false)) ? accepted : run
      if (
        seen.has(run.transcriptChatId) ||
        !(await canChooseDestination(
          tx,
          representative,
          context.currentUserId,
          representative.sourceRoomId !== room.id,
        ))
      )
        continue
      seen.add(run.transcriptChatId)
      const [chat] = await tx.select().from(chats).where(eq(chats.id, run.transcriptChatId)).limit(1)
      const [active] = await tx
        .select({ id: gridTranscriptionRuns.id })
        .from(gridTranscriptionRuns)
        .where(
          and(
            eq(gridTranscriptionRuns.transcriptChatId, run.transcriptChatId),
            inArray(gridTranscriptionRuns.state, [...captureStates]),
          ),
        )
        .limit(1)
      transcripts.push({
        transcriptChatId: BigInt(run.transcriptChatId),
        title: chat?.title ?? "Transcript",
        busy: !!active,
      })
      if (transcripts.length === 20) break
    }
    return { transcripts }
  })
}
export async function setGridTranscription(
  input: SetGridTranscriptionInput,
  context: FunctionContext,
): Promise<SetGridTranscriptionResult> {
  const requestId = uuid(input.requestId)
  const spaceId = await db.transaction(async (tx) => {
    await lockGridMutations(tx)
    const { room, session } = await roomAuthority(tx, id(input.roomId), context, uuid(input.expectedMembershipId))
    const [duplicate] = await tx
      .select()
      .from(gridTranscriptionRuns)
      .where(
        and(
          eq(gridTranscriptionRuns.actorUserId, context.currentUserId),
          eq(gridTranscriptionRuns.requestId, requestId),
        ),
      )
      .limit(1)
    if (duplicate) {
      if (duplicate.sourceRoomId !== room.id) throw RealtimeRpcError.BadRequest()
      return room.spaceId
    }
    const previous = await latestRoomTranscription(tx, room.id)
    if (
      !input.enabled &&
      previous &&
      previous.id === input.expectedRunId &&
      (previous.state === "stopped" || previous.state === "interrupted" || previous.state === "stopping")
    )
      return room.spaceId
    if ((previous?.id ?? undefined) !== input.expectedRunId || (previous?.revision ?? 0) !== input.expectedRevision)
      throw RealtimeRpcError.BadRequest()
    if (!input.enabled) {
      await stopGridTranscription(tx, room.id, "user_stop")
      return room.spaceId
    }
    if (
      !supportedGridTranscriptionSession(session) ||
      !(await transcriptionAvailable(tx)) ||
      !getLiveKitGridConfig() ||
      !room.connectionStartedAt ||
      room.connectionGeneration !== input.expectedGeneration
    )
      throw RealtimeRpcError.BadRequest()
    const busy = await tx
      .select({ id: gridTranscriptionRuns.id })
      .from(gridTranscriptionRuns)
      .where(inArray(gridTranscriptionRuns.state, [...captureStates]))
      .limit(1)
    if (busy.length) throw RealtimeRpcError.BadRequest()
    const roster = await occupants(tx, room.id)
    if (!roster.every(supportedGridTranscriptionSession)) throw RealtimeRpcError.BadRequest()
    const userIds = roster.map((r) => r.userId)
    if (userIds.length < 2 || userIds.length > GRID_TRANSCRIPTION_MAX_SPEAKERS) throw RealtimeRpcError.BadRequest()
    const runId = randomUUID()
    let destination: { transcriptChatId: number; destinationParentChatId: number; originalAnchorId: number }
    let roomLinkMessageId: number | undefined
    let chosen = input.destination === GridTranscriptDestination.GRID_TRANSCRIPT_LAST ? previous : undefined
    let requireSharing = chosen ? chosen.sourceRoomId !== room.id : false
    if (input.destination === GridTranscriptDestination.GRID_TRANSCRIPT_EXISTING) {
      if (!input.transcriptChatId) throw RealtimeRpcError.BadRequest()
      const candidates = await tx
        .select()
        .from(gridTranscriptionRuns)
        .where(
          and(
            eq(gridTranscriptionRuns.spaceId, room.spaceId),
            eq(gridTranscriptionRuns.transcriptChatId, id(input.transcriptChatId)),
          ),
        )
        .orderBy(desc(gridTranscriptionRuns.createdAt))
      // An intact accepted room link carries continuing authority, even if a newer run came from another room.
      chosen = undefined
      for (const candidate of candidates)
        if (
          candidate.sourceRoomId === room.id &&
          (await canChooseDestination(tx, candidate, context.currentUserId, false))
        ) {
          chosen = candidate
          break
        }
      requireSharing = !chosen
      if (!chosen)
        for (const candidate of candidates)
          if (await canChooseDestination(tx, candidate, context.currentUserId, true)) {
            chosen = candidate
            break
          }
      if (!chosen) throw RealtimeRpcError.BadRequest()
    }
    await enrollGridRoomHistory(
      tx,
      room.id,
      userIds,
      chosen ? [chosen.roomChatId, chosen.destinationParentChatId, chosen.transcriptChatId] : [],
    )
    const refreshedPrevious = await latestRoomTranscription(tx, room.id)
    if (
      (refreshedPrevious?.id ?? undefined) !== input.expectedRunId ||
      (refreshedPrevious?.revision ?? 0) !== input.expectedRevision
    )
      throw RealtimeRpcError.BadRequest()
    if (chosen) {
      const [fresh] = await tx
        .select()
        .from(gridTranscriptionRuns)
        .where(eq(gridTranscriptionRuns.id, chosen.id))
        .limit(1)
      chosen = fresh
    }
    const roomChatId = await ensureGridRoomThread(tx, {
      room,
      actorUserId: context.currentUserId,
      participantUserIds: userIds,
    })
    if (
      input.destination === GridTranscriptDestination.GRID_TRANSCRIPT_EXISTING &&
      (!chosen || !(await canChooseDestination(tx, chosen, context.currentUserId, requireSharing)))
    )
      throw RealtimeRpcError.BadRequest()
    if (chosen && (await canChooseDestination(tx, chosen, context.currentUserId, requireSharing))) {
      destination = {
        transcriptChatId: chosen.transcriptChatId,
        destinationParentChatId: chosen.destinationParentChatId,
        originalAnchorId: chosen.originalAnchorId,
      }
      if (requireSharing)
        roomLinkMessageId = await insertGridTranscriptContinuationLink(tx, {
          roomChatId,
          transcriptChatId: chosen.transcriptChatId,
          actorUserId: context.currentUserId,
          runId,
          title: "Transcript",
        })
      else roomLinkMessageId = chosen.roomLinkMessageId ?? undefined
      await grantGridTranscriptUsers(tx, { chatIds: [chosen.destinationParentChatId], userIds })
    } else
      destination = await createGridTranscriptDestination(tx, {
        roomChatId,
        spaceId: room.spaceId,
        actorUserId: context.currentUserId,
        participantUserIds: userIds,
        title: "Transcript",
        runId,
      })
    if (chosen)
      await insertGridTranscriptMessage(tx, {
        chatId: destination.transcriptChatId,
        actorUserId: context.currentUserId,
        runId,
        segmentId: "started",
        kind: "started",
        text: "Transcription started",
      })
    await tx.insert(gridTranscriptionRuns).values({
      id: runId,
      sourceRoomId: room.id,
      spaceId: room.spaceId,
      roomChatId,
      ...destination,
      roomLinkMessageId,
      actorUserId: context.currentUserId,
      requestId,
      model: transcriptionConfig().model,
      state: "starting",
      generation: room.connectionGeneration,
      providerTarget: durableLiveKitProviderTarget(),
      expiresAt: new Date(Date.now() + GRID_TRANSCRIPTION_MAX_MS),
    })
    return room.spaceId
  })
  await notifyGridSpaceChanged(spaceId)
  return { grid: (await getGrid({ spaceId: BigInt(spaceId) }, context)).grid, updates: [] }
}
