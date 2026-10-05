import { createHmac, timingSafeEqual } from "node:crypto"
import { Schema } from "effect"
import { AccessToken } from "livekit-server-sdk"
import { db } from "@in/server/db"
import {
  chats,
  gridPresence,
  gridRooms,
  gridTranscriptionRuns,
  gridTranscriptionSegments,
  gridTranscriptionWorker,
  members,
  sessions,
  spaces,
  users,
  type DbGridTranscriptionRun,
} from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import {
  getLiveKitGridConfig,
  gridParticipantIdentity,
  providerRoomName,
  durableLiveKitProviderTarget,
} from "@in/server/modules/grid/livekit"
import { lockGridMutations } from "@in/server/modules/grid/roomLifecycle"
import { notifyGridSpaceChanged } from "@in/server/modules/grid/realtime"
import { SpaceSettingsModel } from "@in/server/db/models/spaceSettings"
import {
  GRID_TRANSCRIPTION_LEASE_MS,
  GRID_TRANSCRIPTION_MAX_SPEAKERS,
  intactDestination,
  transcriptionConfig,
  supportedGridTranscriptionSession,
} from "./state"
import { insertGridTranscriptMessage } from "./messages"
import { and, asc, eq, gt, inArray, isNull, sql, count, or } from "drizzle-orm"

const boundedString = (max: number) => Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(max))
const identitySchema = Schema.Struct({ workerId: boundedString(80) })
const heartbeatSchema = Schema.Struct({
  workerId: boundedString(80),
  model: Schema.Literals(["meeting", "standard"]),
  ready: Schema.Boolean,
})
const admissionSchema = Schema.Struct({
  participantIdentity: boundedString(128),
  trackSid: boundedString(128),
  sourceTurnKey: boundedString(128),
})
const finalSchema = Schema.Struct({
  segmentId: Schema.String.check(Schema.isUUID()),
  text: Schema.String.check(Schema.isMaxLength(32768)),
})
const stoppedSchema = Schema.Struct({ reason: Schema.optional(boundedString(80)) })
const tokenSchema = Schema.Struct({
  runId: Schema.String.check(Schema.isUUID()),
  epoch: Schema.Int.check(Schema.isGreaterThan(0)),
  expiresAt: Schema.Int,
})
class WorkerRequestError extends Error {
  constructor(readonly status: number) {
    super("Grid transcription request rejected")
  }
}
function equal(a: string, b: string) {
  const aa = Buffer.from(a)
  const bb = Buffer.from(b)
  return aa.length === bb.length && timingSafeEqual(aa, bb)
}
function sign(body: string, secret: string) {
  return createHmac("sha256", secret).update(body).digest("base64url")
}
function runToken(run: DbGridTranscriptionRun, secret: string) {
  const body = Buffer.from(
    JSON.stringify({ runId: run.id, epoch: run.claimEpoch, expiresAt: run.expiresAt.getTime() + 30_000 }),
  ).toString("base64url")
  return `${body}.${sign(body, secret)}`
}
function decodeRunToken(token: string, secret: string, allowExpired = false) {
  const [body, signature] = token.split(".")
  if (!body || !signature || !equal(signature, sign(body, secret))) throw new WorkerRequestError(401)
  const authority = Schema.decodeUnknownSync(tokenSchema)(JSON.parse(Buffer.from(body, "base64url").toString("utf8")))
  if (!allowExpired && authority.expiresAt < Date.now()) throw new WorkerRequestError(401)
  return authority
}
async function currentParticipants(tx: Transaction, run: DbGridTranscriptionRun) {
  const rows = await tx
    .select({
      userId: gridPresence.userId,
      membershipId: gridPresence.mediaMembershipId,
      clientType: sessions.clientType,
      clientVersion: sessions.clientVersion,
    })
    .from(gridPresence)
    .innerJoin(members, and(eq(members.userId, gridPresence.userId), eq(members.spaceId, run.spaceId)))
    .innerJoin(users, and(eq(users.id, gridPresence.userId), eq(users.bot, false)))
    .innerJoin(sessions, and(eq(sessions.id, gridPresence.ownerSessionId), isNull(sessions.revoked)))
    .where(and(eq(gridPresence.roomId, run.sourceRoomId), gt(gridPresence.leaseExpiresAt, new Date())))
  return rows.map((row) => ({
    userId: row.userId,
    membershipId: row.membershipId,
    identity: gridParticipantIdentity(row.userId, row.membershipId),
    qualified: supportedGridTranscriptionSession(row),
  }))
}
async function captureAuthority(tx: Transaction, run: DbGridTranscriptionRun) {
  const [room] = await tx.select().from(gridRooms).where(eq(gridRooms.id, run.sourceRoomId)).limit(1)
  const [space] = await tx
    .select({ id: spaces.id })
    .from(spaces)
    .where(and(eq(spaces.id, run.spaceId), isNull(spaces.deleted)))
    .limit(1)
  const participants = await currentParticipants(tx, run)
  return {
    participants,
    valid:
      !!room &&
      !!space &&
      room.connectionStartedAt !== null &&
      room.connectionGeneration === run.generation &&
      run.providerTarget === durableLiveKitProviderTarget() &&
      participants.length >= 2 &&
      participants.length <= GRID_TRANSCRIPTION_MAX_SPEAKERS &&
      participants.every((p) => p.qualified) &&
      run.expiresAt.getTime() > Date.now() &&
      (await SpaceSettingsModel.getStored(run.spaceId, tx)).gridEnabled &&
      (await intactDestination(tx, run)),
  }
}
function wireParticipants(participants: Awaited<ReturnType<typeof currentParticipants>>) {
  return participants.map(({ identity, userId, membershipId }) => ({ identity, userId, membershipId }))
}
async function lockedRun(tx: Transaction, authority: { runId: string; epoch: number }) {
  const [run] = await tx
    .select()
    .from(gridTranscriptionRuns)
    .where(and(eq(gridTranscriptionRuns.id, authority.runId), eq(gridTranscriptionRuns.claimEpoch, authority.epoch)))
    .for("update")
    .limit(1)
  if (!run) throw new WorkerRequestError(409)
  return run
}
async function readBody(request: Request): Promise<unknown> {
  const reader = request.body?.getReader()
  if (!reader) throw new WorkerRequestError(400)
  const chunks: Uint8Array[] = []
  let size = 0
  try {
    while (true) {
      const next = await reader.read()
      if (next.done) break
      size += next.value.byteLength
      if (size > 262_144) {
        await reader.cancel()
        throw new WorkerRequestError(413)
      }
      chunks.push(next.value)
    }
  } finally {
    reader.releaseLock()
  }
  const bytes = new Uint8Array(size)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  return JSON.parse(new TextDecoder().decode(bytes))
}
/** Authenticated internal route only. Never logs body, credentials, audio or text. */
export async function handleGridTranscriptionWorkerRequest(request: Request): Promise<Response> {
  const config = transcriptionConfig()
  const action = new URL(request.url).pathname.split("/").at(-1)
  if (!config.secret || config.secret.length < 32 || (!config.enabled && action !== "stopped" && action !== "claim"))
    return Response.json({ error: "unavailable" }, { status: 503 })
  if (request.method !== "POST") return new Response(null, { status: 405 })
  if (Number(request.headers.get("content-length") ?? 0) > 262144) return new Response(null, { status: 413 })
  try {
    const token = request.headers.get("authorization")?.replace(/^Bearer /, "") ?? ""
    if (action === "heartbeat" || action === "claim") {
      if (!equal(token, config.secret)) throw new WorkerRequestError(401)
      const raw = await readBody(request)
      const { workerId } = Schema.decodeUnknownSync(identitySchema)(raw)
      if (action === "heartbeat") {
        const heartbeat = Schema.decodeUnknownSync(heartbeatSchema)(raw)
        const heartbeatAt = heartbeat.ready ? new Date() : new Date(0)
        await db
          .insert(gridTranscriptionWorker)
          .values({ id: 1, workerId, model: heartbeat.model, heartbeatAt })
          .onConflictDoUpdate({
            target: gridTranscriptionWorker.id,
            set: { workerId, model: heartbeat.model, heartbeatAt },
          })
        return Response.json({ ready: heartbeat.ready })
      }
      const livekit = getLiveKitGridConfig()
      const claimed = await db.transaction(async (tx) => {
        await lockGridMutations(tx)
        const [run] = await tx
          .select()
          .from(gridTranscriptionRuns)
          .where(
            and(
              or(
                and(eq(gridTranscriptionRuns.state, "starting"), isNull(gridTranscriptionRuns.workerId)),
                and(
                  inArray(gridTranscriptionRuns.state, ["starting", "stopping"]),
                  eq(gridTranscriptionRuns.workerId, workerId),
                ),
              ),
            ),
          )
          .orderBy(asc(gridTranscriptionRuns.createdAt))
          .for("update")
          .limit(1)
        if (!run) return undefined
        const [readyWorker] = await tx
          .select()
          .from(gridTranscriptionWorker)
          .where(
            and(
              eq(gridTranscriptionWorker.id, 1),
              eq(gridTranscriptionWorker.workerId, workerId),
              eq(gridTranscriptionWorker.model, run.model),
              gt(gridTranscriptionWorker.heartbeatAt, new Date(Date.now() - GRID_TRANSCRIPTION_LEASE_MS)),
            ),
          )
          .limit(1)
        const owned = run.workerId === workerId
        if (!owned && (!config.enabled || !livekit || !readyWorker)) throw new WorkerRequestError(409)
        const authority = await captureAuthority(tx, run)
        if (owned && run.state === "stopping") return { run, stopImmediately: true as const }
        if (
          owned &&
          (!config.enabled ||
            !livekit ||
            !readyWorker ||
            !authority.valid ||
            !run.leaseExpiresAt ||
            run.leaseExpiresAt.getTime() <= Date.now())
        ) {
          const [stopping] = await tx
            .update(gridTranscriptionRuns)
            .set({
              state: "stopping",
              stopRequestedAt: run.stopRequestedAt ?? new Date(),
              interruptionReason: run.interruptionReason ?? "start_unavailable",
              revision: sql`${gridTranscriptionRuns.revision} + 1`,
            })
            .where(eq(gridTranscriptionRuns.id, run.id))
            .returning()
          if (!stopping) throw new WorkerRequestError(409)
          return { run: stopping, stopImmediately: true as const }
        }
        if (!livekit) throw new WorkerRequestError(503)
        if (!authority.valid || (!owned && run.createdAt.getTime() < Date.now() - 30_000)) {
          await tx
            .update(gridTranscriptionRuns)
            .set({
              state: run.workerId === null ? "interrupted" : "stopping",
              stopRequestedAt: new Date(),
              interruptionReason: run.interruptionReason ?? "start_unavailable",
              revision: sql`${gridTranscriptionRuns.revision} + 1`,
            })
            .where(eq(gridTranscriptionRuns.id, run.id))
          return undefined
        }
        const [updated] = await tx
          .update(gridTranscriptionRuns)
          .set({
            workerId,
            claimEpoch: run.claimEpoch || 1,
            leaseExpiresAt: new Date(Date.now() + GRID_TRANSCRIPTION_LEASE_MS),
            revision: sql`${gridTranscriptionRuns.revision} + 1`,
          })
          .where(eq(gridTranscriptionRuns.id, run.id))
          .returning()
        if (!updated) return undefined
        const credential = new AccessToken(livekit.apiKey, livekit.apiSecret, {
          identity: `inline-grid-transcription-${updated.id}-${updated.claimEpoch}`,
          name: "Inline transcription",
          ttl: 60,
        })
        credential.addGrant({
          roomJoin: true,
          room: providerRoomName({ roomId: BigInt(updated.sourceRoomId), generation: updated.generation }),
          canPublish: false,
          canSubscribe: true,
          canPublishData: false,
          canUpdateOwnMetadata: false,
        })
        return {
          run: updated,
          participants: authority.participants,
          livekitToken: await credential.toJwt(),
          serverUrl: livekit.serverUrl,
          stopImmediately: false as const,
        }
      })
      if (!claimed) return new Response(null, { status: 204 })
      await notifyGridSpaceChanged(claimed.run.spaceId)
      if (claimed.stopImmediately)
        return Response.json({
          runId: claimed.run.id,
          claimEpoch: claimed.run.claimEpoch,
          runToken: runToken(claimed.run, config.secret),
          stopImmediately: true,
        })
      return Response.json({
        runId: claimed.run.id,
        claimEpoch: claimed.run.claimEpoch,
        runToken: runToken(claimed.run, config.secret),
        roomId: claimed.run.sourceRoomId,
        generation: claimed.run.generation,
        providerTarget: claimed.run.providerTarget,
        livekit: { serverUrl: claimed.serverUrl, token: claimed.livekitToken },
        model: claimed.run.model,
        leaseMs: GRID_TRANSCRIPTION_LEASE_MS,
        expiresAt: claimed.run.expiresAt.toISOString(),
        participants: wireParticipants(claimed.participants),
      })
    }
    const authority = decodeRunToken(token, config.secret, action === "stopped")
    if (action === "renew") {
      const result = await db.transaction(async (tx) => {
        const run = await lockedRun(tx, authority)
        const active = await captureAuthority(tx, run)
        const canRenew =
          (run.state === "active" || run.state === "starting") &&
          !!run.leaseExpiresAt &&
          run.leaseExpiresAt.getTime() > Date.now() &&
          active.valid
        const leaseExpiresAt = new Date(Date.now() + GRID_TRANSCRIPTION_LEASE_MS)
        const stateChanged = !canRenew && (run.state === "active" || run.state === "starting")
        if (canRenew)
          await tx.update(gridTranscriptionRuns).set({ leaseExpiresAt }).where(eq(gridTranscriptionRuns.id, run.id))
        else if (stateChanged)
          await tx
            .update(gridTranscriptionRuns)
            .set({
              state: "stopping",
              stopRequestedAt: new Date(),
              interruptionReason: "authority_lost",
              revision: sql`${gridTranscriptionRuns.revision} + 1`,
            })
            .where(eq(gridTranscriptionRuns.id, run.id))
        return {
          state: canRenew ? "active" : run.state === "stopped" || run.state === "interrupted" ? "stopped" : "stopping",
          allowFinalFlush:
            run.state === "stopping" &&
            run.interruptionReason === "user_stop" &&
            active.valid &&
            !!run.stopRequestedAt &&
            Date.now() - run.stopRequestedAt.getTime() <= 5000 &&
            !!run.leaseExpiresAt &&
            run.leaseExpiresAt.getTime() > Date.now(),
          leaseExpiresAt: (canRenew ? leaseExpiresAt : (run.leaseExpiresAt ?? new Date())).toISOString(),
          participants: wireParticipants(active.participants),
          spaceId: run.spaceId,
          stateChanged,
        }
      })
      const { spaceId, stateChanged, ...response } = result
      if (stateChanged) await notifyGridSpaceChanged(spaceId)
      return Response.json(response)
    }
    if (action === "admit") {
      const input = Schema.decodeUnknownSync(admissionSchema)(await readBody(request))
      const result = await db.transaction(async (tx) => {
        const run = await lockedRun(tx, authority)
        const active = await captureAuthority(tx, run)
        const speaker = active.participants.find((p) => p.identity === input.participantIdentity)
        if (
          !active.valid ||
          !speaker ||
          !run.leaseExpiresAt ||
          run.leaseExpiresAt.getTime() <= Date.now() ||
          (run.state !== "starting" && run.state !== "active")
        )
          throw new WorkerRequestError(409)
        const [existing] = await tx
          .select()
          .from(gridTranscriptionSegments)
          .where(
            and(
              eq(gridTranscriptionSegments.runId, run.id),
              eq(gridTranscriptionSegments.trackSid, input.trackSid),
              eq(gridTranscriptionSegments.sourceTurnKey, input.sourceTurnKey),
            ),
          )
          .limit(1)
        if (existing) {
          if (
            existing.claimEpoch !== run.claimEpoch ||
            existing.speakerUserId !== speaker.userId ||
            existing.membershipId !== speaker.membershipId ||
            existing.state !== "admitted"
          )
            throw new WorkerRequestError(409)
          return { segmentId: existing.id, spaceId: run.spaceId }
        }
        const pending = await tx
          .select({ trackSid: gridTranscriptionSegments.trackSid, value: count() })
          .from(gridTranscriptionSegments)
          .where(and(eq(gridTranscriptionSegments.runId, run.id), eq(gridTranscriptionSegments.state, "admitted")))
          .groupBy(gridTranscriptionSegments.trackSid)
        if (
          pending.reduce((sum, p) => sum + Number(p.value), 0) >= 64 ||
          Number(pending.find((p) => p.trackSid === input.trackSid)?.value ?? 0) >= 2
        )
          throw new WorkerRequestError(409)
        const [segment] = await tx
          .insert(gridTranscriptionSegments)
          .values({
            runId: run.id,
            claimEpoch: run.claimEpoch,
            speakerUserId: speaker.userId,
            membershipId: speaker.membershipId,
            trackSid: input.trackSid,
            sourceTurnKey: input.sourceTurnKey,
          })
          .returning({ id: gridTranscriptionSegments.id })
        if (!segment) throw new WorkerRequestError(409)
        if (run.state === "starting")
          await tx
            .update(gridTranscriptionRuns)
            .set({ state: "active", revision: sql`${gridTranscriptionRuns.revision} + 1` })
            .where(eq(gridTranscriptionRuns.id, run.id))
        return { segmentId: segment.id, spaceId: run.spaceId }
      })
      await notifyGridSpaceChanged(result.spaceId)
      return Response.json({ segmentId: result.segmentId })
    }
    if (action === "final") {
      const input = Schema.decodeUnknownSync(finalSchema)(await readBody(request))
      if (Buffer.byteLength(input.text, "utf8") > 32768) throw new WorkerRequestError(413)
      const saved = await db.transaction(async (tx) => {
        // History mutations lock chats before runs. Do the same here.
        const [target] = await tx
          .select({
            chatId: gridTranscriptionRuns.transcriptChatId,
            parentId: gridTranscriptionRuns.destinationParentChatId,
          })
          .from(gridTranscriptionRuns)
          .where(eq(gridTranscriptionRuns.id, authority.runId))
          .limit(1)
        if (!target) throw new WorkerRequestError(409)
        await tx
          .select({ id: chats.id })
          .from(chats)
          .where(inArray(chats.id, [target.parentId, target.chatId]))
          .orderBy(asc(chats.id))
          .for("update")
        const run = await lockedRun(tx, authority)
        const [segment] = await tx
          .select()
          .from(gridTranscriptionSegments)
          .where(
            and(
              eq(gridTranscriptionSegments.id, input.segmentId),
              eq(gridTranscriptionSegments.runId, run.id),
              eq(gridTranscriptionSegments.claimEpoch, run.claimEpoch),
            ),
          )
          .for("update")
          .limit(1)
        if (!segment) throw new WorkerRequestError(409)
        if (segment.state !== "admitted") return { messageId: segment.messageId, inserted: undefined }
        const [member] = await tx
          .select({ id: members.id })
          .from(members)
          .where(and(eq(members.spaceId, run.spaceId), eq(members.userId, segment.speakerUserId)))
          .limit(1)
        const current = await captureAuthority(tx, run)
        const allowed =
          !!member &&
          current.valid &&
          !!run.leaseExpiresAt &&
          run.leaseExpiresAt.getTime() > Date.now() &&
          run.expiresAt.getTime() > Date.now() &&
          (run.state === "active" ||
            run.state === "starting" ||
            (run.state === "stopping" &&
              run.interruptionReason === "user_stop" &&
              !!run.stopRequestedAt &&
              Date.now() - run.stopRequestedAt.getTime() <= 5000))
        if (!allowed || !input.text.trim()) {
          await tx
            .update(gridTranscriptionSegments)
            .set({ state: "discarded" })
            .where(eq(gridTranscriptionSegments.id, segment.id))
          return { messageId: null, inserted: undefined }
        }
        const inserted = await insertGridTranscriptMessage(tx, {
          chatId: run.transcriptChatId,
          actorUserId: run.actorUserId,
          runId: run.id,
          segmentId: segment.id,
          speakerUserId: segment.speakerUserId,
          kind: "turn",
          text: input.text.trim(),
        })
        await tx
          .update(gridTranscriptionSegments)
          .set({ state: "finalized", messageId: inserted.message.messageId })
          .where(eq(gridTranscriptionSegments.id, segment.id))
        return { messageId: inserted.message.messageId, inserted }
      })
      return Response.json({ messageId: saved.messageId })
    }
    if (action === "stopped") {
      Schema.decodeUnknownSync(stoppedSchema)(await readBody(request))
      const spaceId = await db.transaction(async (tx) => {
        const [target] = await tx
          .select({
            chatId: gridTranscriptionRuns.transcriptChatId,
            parentId: gridTranscriptionRuns.destinationParentChatId,
          })
          .from(gridTranscriptionRuns)
          .where(eq(gridTranscriptionRuns.id, authority.runId))
          .limit(1)
        if (!target) throw new WorkerRequestError(409)
        await tx
          .select({ id: chats.id })
          .from(chats)
          .where(inArray(chats.id, [target.parentId, target.chatId]))
          .orderBy(asc(chats.id))
          .for("update")
        const run = await lockedRun(tx, authority)
        if (run.state !== "stopped" && run.state !== "interrupted") {
          if (await intactDestination(tx, run))
            await insertGridTranscriptMessage(tx, {
              chatId: run.transcriptChatId,
              actorUserId: run.actorUserId,
              runId: run.id,
              segmentId: "stopped",
              kind: run.interruptionReason === "user_stop" ? "stopped" : "interrupted",
              text: run.interruptionReason === "user_stop" ? "Transcription stopped" : "Transcription interrupted",
            })
          await tx
            .update(gridTranscriptionRuns)
            .set({
              state: run.interruptionReason === "user_stop" ? "stopped" : "interrupted",
              revision: sql`${gridTranscriptionRuns.revision} + 1`,
            })
            .where(eq(gridTranscriptionRuns.id, run.id))
          await tx
            .update(gridTranscriptionSegments)
            .set({ state: "discarded" })
            .where(and(eq(gridTranscriptionSegments.runId, run.id), eq(gridTranscriptionSegments.state, "admitted")))
        }
        return run.spaceId
      })
      await notifyGridSpaceChanged(spaceId)
      return Response.json({ stopped: true })
    }
    return new Response(null, { status: 404 })
  } catch (error) {
    if (error instanceof WorkerRequestError) return Response.json({ error: "rejected" }, { status: error.status })
    if (Schema.isSchemaError(error) || error instanceof SyntaxError)
      return Response.json({ error: "invalid_request" }, { status: 400 })
    return Response.json({ error: "request_failed" }, { status: 500 })
  }
}
