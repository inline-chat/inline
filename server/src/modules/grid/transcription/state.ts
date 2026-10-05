import { GridTranscriptionState, type GridTranscription } from "@inline-chat/protocol/core"
import {
  gridTranscriptionRuns,
  gridTranscriptionSegments,
  gridTranscriptionWorker,
  chats,
  messages,
  type DbGridTranscriptionRun,
} from "@in/server/db/schema"
import { getLiveKitGridConfig } from "@in/server/modules/grid/livekit"
import { insertGridTranscriptMessage } from "./messages"
import type { Transaction } from "@in/server/db/types"
import { and, eq, inArray, gt, desc, or, sql, lt, isNull, lte } from "drizzle-orm"

export const gridTranscriptionRetirementReasons = [
  "history_changed",
  "history_cleared",
  "message_deleted",
  "chat_deleted",
  "chat_moved",
  "access_revoked",
  "space_deleted",
] as const
export const captureStates = ["starting", "active", "stopping"] as const
export const GRID_TRANSCRIPTION_LEASE_MS = 15_000
export const GRID_TRANSCRIPTION_MAX_MS = 2 * 60 * 60_000
export const GRID_TRANSCRIPTION_MAX_SPEAKERS = 8
export function transcriptionConfig() {
  const secret = process.env["GRID_TRANSCRIPTION_WORKER_SECRET"]
  const model = process.env["GRID_TRANSCRIPTION_MODEL"] ?? "meeting"
  const allowedClientVersions = (process.env["GRID_TRANSCRIPTION_ALLOWED_CLIENT_VERSIONS"] ?? "")
    .split(",")
    .map((v) => v.trim())
    .filter(Boolean)
  return {
    enabled:
      process.env["GRID_TRANSCRIPTION_ENABLED"] === "true" &&
      !!secret &&
      secret.length >= 32 &&
      (model === "meeting" || model === "standard"),
    secret,
    model,
    allowedClientVersions,
  }
}
export async function transcriptionAvailable(tx: Transaction) {
  if (!transcriptionConfig().enabled || !transcriptionConfig().allowedClientVersions.length || !getLiveKitGridConfig())
    return false
  const [worker] = await tx
    .select()
    .from(gridTranscriptionWorker)
    .where(
      and(
        eq(gridTranscriptionWorker.model, transcriptionConfig().model),
        gt(gridTranscriptionWorker.heartbeatAt, new Date(Date.now() - GRID_TRANSCRIPTION_LEASE_MS)),
      ),
    )
    .limit(1)
  return !!worker
}
export async function latestRoomTranscription(tx: Transaction, roomId: number) {
  const [run] = await tx
    .select()
    .from(gridTranscriptionRuns)
    .where(eq(gridTranscriptionRuns.sourceRoomId, roomId))
    .orderBy(desc(gridTranscriptionRuns.createdAt))
    .limit(1)
  return run
}
/** Lock chats, runs, then segments consistently with final and history mutations. */
export async function invalidateGridTranscriptionForSpeaker(
  tx: Transaction,
  userId: number,
  spaceId?: number,
  membershipId?: string,
) {
  const runs = await tx
    .select()
    .from(gridTranscriptionRuns)
    .where(
      and(
        spaceId === undefined ? undefined : eq(gridTranscriptionRuns.spaceId, spaceId),
        inArray(gridTranscriptionRuns.state, [...captureStates]),
      ),
    )
  const chatIds = [...new Set(runs.flatMap((r) => [r.destinationParentChatId, r.transcriptChatId]))].sort(
    (a, b) => a - b,
  )
  if (chatIds.length)
    await tx.select({ id: chats.id }).from(chats).where(inArray(chats.id, chatIds)).orderBy(chats.id).for("update")
  if (runs.length) {
    await tx
      .select({ id: gridTranscriptionRuns.id })
      .from(gridTranscriptionRuns)
      .where(
        inArray(
          gridTranscriptionRuns.id,
          runs.map((r) => r.id),
        ),
      )
      .orderBy(gridTranscriptionRuns.id)
      .for("update")
    await tx
      .update(gridTranscriptionSegments)
      .set({ state: "discarded" })
      .where(
        and(
          eq(gridTranscriptionSegments.speakerUserId, userId),
          membershipId === undefined ? undefined : eq(gridTranscriptionSegments.membershipId, membershipId),
          inArray(
            gridTranscriptionSegments.runId,
            runs.map((r) => r.id),
          ),
          eq(gridTranscriptionSegments.state, "admitted"),
        ),
      )
  }
}
export function supportedGridTranscriptionSession(session: {
  clientType: string | null
  clientVersion: string | null
}) {
  return (
    session.clientType === "macos" &&
    session.clientVersion !== null &&
    transcriptionConfig().allowedClientVersions.includes(session.clientVersion)
  )
}
/** Unclaimed runs can retire safely; claimed unknown capture retains its global slot. */
export async function retireUnclaimedGridTranscriptions(tx: Transaction) {
  if (!transcriptionConfig().enabled) return
  const overdue = await tx
    .select()
    .from(gridTranscriptionRuns)
    .where(
      and(
        inArray(gridTranscriptionRuns.state, ["starting", "active"]),
        or(
          and(
            isNull(gridTranscriptionRuns.workerId),
            lt(gridTranscriptionRuns.createdAt, new Date(Date.now() - 30_000)),
          ),
          lte(gridTranscriptionRuns.expiresAt, new Date()),
          lte(gridTranscriptionRuns.leaseExpiresAt, new Date()),
        ),
      ),
    )
  const chatIds = [...new Set(overdue.flatMap((run) => [run.destinationParentChatId, run.transcriptChatId]))].sort(
    (a, b) => a - b,
  )
  if (chatIds.length)
    await tx.select({ id: chats.id }).from(chats).where(inArray(chats.id, chatIds)).orderBy(chats.id).for("update")
  if (overdue.length)
    await tx
      .select({ id: gridTranscriptionRuns.id })
      .from(gridTranscriptionRuns)
      .where(
        inArray(
          gridTranscriptionRuns.id,
          overdue.map((run) => run.id),
        ),
      )
      .orderBy(gridTranscriptionRuns.id)
      .for("update")
  for (const run of overdue) {
    const state = run.workerId === null ? "interrupted" : "stopping"
    const reason = run.workerId === null ? "start_timeout" : "capture_timeout"
    const changed = await tx
      .update(gridTranscriptionRuns)
      .set({
        state,
        interruptionReason: reason,
        stopRequestedAt: new Date(),
        revision: sql`${gridTranscriptionRuns.revision} + 1`,
      })
      .where(
        and(
          eq(gridTranscriptionRuns.id, run.id),
          inArray(gridTranscriptionRuns.state, ["starting", "active"]),
          or(
            and(
              isNull(gridTranscriptionRuns.workerId),
              lt(gridTranscriptionRuns.createdAt, new Date(Date.now() - 30_000)),
            ),
            lte(gridTranscriptionRuns.expiresAt, new Date()),
            lte(gridTranscriptionRuns.leaseExpiresAt, new Date()),
          ),
        ),
      )
      .returning()
    if (!changed.length) continue
    await tx
      .update(gridTranscriptionSegments)
      .set({ state: "discarded" })
      .where(and(eq(gridTranscriptionSegments.runId, run.id), eq(gridTranscriptionSegments.state, "admitted")))
    if (state === "interrupted" && (await intactDestination(tx, run)))
      await insertGridTranscriptMessage(tx, {
        chatId: run.transcriptChatId,
        actorUserId: run.actorUserId,
        runId: run.id,
        segmentId: "interrupted",
        kind: "interrupted",
        text: "Transcription interrupted",
      })
  }
}
export function encodeGridTranscription(run: DbGridTranscriptionRun, canRead: boolean): GridTranscription {
  const state =
    {
      starting: GridTranscriptionState.GRID_TRANSCRIPTION_STARTING,
      active: GridTranscriptionState.GRID_TRANSCRIPTION_ACTIVE,
      stopping: GridTranscriptionState.GRID_TRANSCRIPTION_STOPPING,
      stopped: GridTranscriptionState.GRID_TRANSCRIPTION_STOPPED,
      interrupted: GridTranscriptionState.GRID_TRANSCRIPTION_INTERRUPTED,
    }[run.state] ?? GridTranscriptionState.GRID_TRANSCRIPTION_INTERRUPTED
  return {
    runId: run.id,
    state,
    transcriptChatId: canRead ? BigInt(run.transcriptChatId) : undefined,
    revision: run.revision,
  }
}
export async function stopGridTranscription(tx: Transaction, roomId: number, reason: string, discard = false) {
  const runs = await tx
    .select({ parentId: gridTranscriptionRuns.destinationParentChatId, chatId: gridTranscriptionRuns.transcriptChatId })
    .from(gridTranscriptionRuns)
    .where(
      and(eq(gridTranscriptionRuns.sourceRoomId, roomId), inArray(gridTranscriptionRuns.state, [...captureStates])),
    )
  const chatIds = [...new Set(runs.flatMap((r) => [r.parentId, r.chatId]))].sort((a, b) => a - b)
  if (chatIds.length)
    await tx.select({ id: chats.id }).from(chats).where(inArray(chats.id, chatIds)).orderBy(chats.id).for("update")
  const changed = await tx
    .update(gridTranscriptionRuns)
    .set({
      state: sql`CASE WHEN ${gridTranscriptionRuns.workerId} IS NULL THEN ${reason === "user_stop" ? "stopped" : "interrupted"} ELSE 'stopping' END`,
      stopRequestedAt: sql`COALESCE(${gridTranscriptionRuns.stopRequestedAt}, ${new Date().toISOString()}::timestamp)`,
      interruptionReason: sql`CASE WHEN ${inArray(gridTranscriptionRuns.interruptionReason, [...gridTranscriptionRetirementReasons])} THEN ${gridTranscriptionRuns.interruptionReason} ELSE ${reason} END`,
      revision: sql`${gridTranscriptionRuns.revision} + 1`,
    })
    .where(
      and(
        eq(gridTranscriptionRuns.sourceRoomId, roomId),
        inArray(gridTranscriptionRuns.state, discard ? [...captureStates] : ["starting", "active"]),
      ),
    )
    .returning()
  for (const run of changed)
    if (run.workerId === null && (await intactDestination(tx, run)))
      await insertGridTranscriptMessage(tx, {
        chatId: run.transcriptChatId,
        actorUserId: run.actorUserId,
        runId: run.id,
        segmentId: "stopped",
        kind: reason === "user_stop" ? "stopped" : "interrupted",
        text: reason === "user_stop" ? "Transcription stopped" : "Transcription interrupted",
      })
  if (discard && changed.length)
    await tx
      .update(gridTranscriptionSegments)
      .set({ state: "discarded" })
      .where(
        and(
          inArray(
            gridTranscriptionSegments.runId,
            changed.map((r) => r.id),
          ),
          eq(gridTranscriptionSegments.state, "admitted"),
        ),
      )
}
/** Caller holds ordinary chat locks before changing runs; prevents late finals refilling cleared history. */
export async function invalidateGridTranscriptionForHistory(
  tx: Transaction,
  input: { chatIds?: number[]; messageRefs?: { chatId: number; messageId: number }[]; reason?: string },
) {
  const conditions = []
  if (input.chatIds?.length)
    conditions.push(
      inArray(gridTranscriptionRuns.transcriptChatId, input.chatIds),
      inArray(gridTranscriptionRuns.destinationParentChatId, input.chatIds),
      inArray(gridTranscriptionRuns.roomChatId, input.chatIds),
    )
  for (const ref of input.messageRefs ?? [])
    conditions.push(
      and(
        eq(gridTranscriptionRuns.destinationParentChatId, ref.chatId),
        eq(gridTranscriptionRuns.originalAnchorId, ref.messageId),
      ),
      and(eq(gridTranscriptionRuns.roomChatId, ref.chatId), eq(gridTranscriptionRuns.roomLinkMessageId, ref.messageId)),
    )
  if (!conditions.length) return
  await tx
    .select({ id: gridTranscriptionRuns.id })
    .from(gridTranscriptionRuns)
    .where(or(...conditions))
    .orderBy(gridTranscriptionRuns.id)
    .for("update")
  const changed = await tx
    .update(gridTranscriptionRuns)
    .set({
      state: sql`CASE WHEN ${gridTranscriptionRuns.state} IN ('starting', 'active', 'stopping') THEN CASE WHEN ${gridTranscriptionRuns.workerId} IS NULL THEN 'interrupted' ELSE 'stopping' END ELSE ${gridTranscriptionRuns.state} END`,
      stopRequestedAt: sql`COALESCE(${gridTranscriptionRuns.stopRequestedAt}, ${new Date().toISOString()}::timestamp)`,
      interruptionReason: input.reason ?? "history_changed",
      revision: sql`${gridTranscriptionRuns.revision} + 1`,
    })
    .where(or(...conditions))
    .returning({ id: gridTranscriptionRuns.id })
  // Historical associations are checked against their visible links, not hidden grants.
  if (changed.length)
    await tx
      .update(gridTranscriptionSegments)
      .set({ state: "discarded" })
      .where(
        and(
          inArray(
            gridTranscriptionSegments.runId,
            changed.map((r) => r.id),
          ),
          eq(gridTranscriptionSegments.state, "admitted"),
        ),
      )
}
export async function intactDestination(tx: Transaction, run: DbGridTranscriptionRun) {
  if (gridTranscriptionRetirementReasons.some((reason) => reason === run.interruptionReason)) return false
  const [parent] = await tx.select().from(chats).where(eq(chats.id, run.destinationParentChatId)).limit(1)
  const [source] = await tx.select().from(chats).where(eq(chats.id, run.roomChatId)).limit(1)
  if (
    !source ||
    source.type !== "thread" ||
    source.spaceId !== run.spaceId ||
    source.publicThread !== false ||
    source.parentChatId !== null
  )
    return false
  const [child] = await tx.select().from(chats).where(eq(chats.id, run.transcriptChatId)).limit(1)
  const [anchor] = await tx
    .select({ id: messages.messageId })
    .from(messages)
    .where(and(eq(messages.chatId, run.destinationParentChatId), eq(messages.messageId, run.originalAnchorId)))
    .limit(1)
  if (
    !parent ||
    !child ||
    !anchor ||
    parent.spaceId !== run.spaceId ||
    parent.publicThread !== false ||
    parent.parentChatId !== null ||
    child.spaceId !== run.spaceId ||
    child.parentChatId !== parent.id ||
    child.parentMessageId !== run.originalAnchorId
  )
    return false
  if (run.roomLinkMessageId !== null) {
    const [link] = await tx
      .select({ id: messages.messageId })
      .from(messages)
      .where(and(eq(messages.chatId, run.roomChatId), eq(messages.messageId, run.roomLinkMessageId)))
      .limit(1)
    if (!link) return false
  }
  return true
}
