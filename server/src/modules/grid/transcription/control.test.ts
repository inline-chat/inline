import { afterEach, describe, expect, spyOn, test } from "bun:test"
import { randomUUID } from "node:crypto"
import { and, eq, sql } from "drizzle-orm"
import { GridTranscriptDestination, GridTranscriptionState } from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { waitForPostCommitHooks } from "@in/server/db/commitHooks"
import {
  chatParticipants,
  chats,
  gridPresence,
  gridRooms,
  gridTranscriptionRuns,
  gridTranscriptionSegments,
  members,
  messages,
  sessions,
  spaces,
  gridTranscriptionSpaceRevisions,
} from "@in/server/db/schema"
import { createGridRoom, getGrid, joinGridRoom, leaveGridRoom } from "@in/server/functions/grid"
import {
  openGridThread,
  setGridTranscription,
  enrollGridRoomHistory,
  listGridTranscripts,
} from "@in/server/functions/gridTranscription"
import { toggleSpaceGrid } from "@in/server/functions/space.settings"
import * as livekit from "@in/server/modules/grid/livekit"
import * as gridRealtime from "@in/server/modules/grid/realtime"
import { clearChatHistory } from "@in/server/modules/historyClear"
import { deleteChat } from "@in/server/functions/messages.deleteChat"
import { handler as leaveSpace } from "@in/server/methods/leaveSpace"
import { revokeSession } from "@in/server/modules/sessions/revokeSession"
import { ensureGridRoomThread, insertGridTranscriptContinuationLink } from "./threads"
import { invalidateGridTranscriptionForHistory } from "./state"
import { handleGridTranscriptionWorkerRequest } from "./worker"

setupTestLifecycle()
const secret = "grid-control-test-secret-0123456789012345"
const original = new Map<string, string | undefined>()
let providerSpy: ReturnType<typeof spyOn<typeof livekit, "getLiveKitGridConfig">> | undefined
function configure() {
  for (const [key, value] of Object.entries({
    GRID_TRANSCRIPTION_ENABLED: "true",
    GRID_TRANSCRIPTION_WORKER_SECRET: secret,
    GRID_TRANSCRIPTION_MODEL: "meeting",
    GRID_TRANSCRIPTION_ALLOWED_CLIENT_VERSIONS: "qualified-test",
  })) {
    if (!original.has(key)) original.set(key, process.env[key])
    process.env[key] = value
  }
  providerSpy = spyOn(livekit, "getLiveKitGridConfig").mockReturnValue({
    serverUrl: "wss://local.test",
    apiKey: "local-test-key",
    apiSecret: "local-test-secret-0123456789",
    provider: "self_hosted",
  })
}
afterEach(async () => {
  await waitForPostCommitHooks()
  providerSpy?.mockRestore()
  providerSpy = undefined
  for (const [key, value] of original) {
    if (value === undefined) delete process.env[key]
    else process.env[key] = value
  }
  original.clear()
})
async function api(action: string, body: unknown, token = secret) {
  return handleGridTranscriptionWorkerRequest(
    new Request(`http://localhost/_internal/grid-transcription/${action}`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify(body),
    }),
  )
}
interface Claimed {
  runId: string
  claimEpoch: number
  runToken: string
  roomId: number
  model: string
  livekit: { serverUrl: string; token: string }
  participants: { identity: string; userId: number; membershipId: string }[]
}
async function fixture(label: string) {
  configure()
  const { space, users } = await testUtils.createSpaceWithMembers(label, [
    `${label}-owner@example.test`,
    `${label}-peer@example.test`,
    `${label}-future@example.test`,
  ] as const)
  await db
    .update(members)
    .set({ role: "owner" })
    .where(and(eq(members.spaceId, space.id), eq(members.userId, users[0].id)))
  const auth = await Promise.all(
    users.map((user) =>
      testUtils.createSessionForUser(user.id, { clientType: "macos", clientVersion: "qualified-test" }),
    ),
  )
  const contexts = users.map((user, i) =>
    testUtils.functionContext({ userId: user.id, sessionId: auth[i]!.session.id }),
  )
  await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, contexts[0]!)
  const created = await createGridRoom({ spaceId: BigInt(space.id), microphoneEnabled: true }, contexts[0]!)
  const roomId = created.grids[0]!.rooms[0]!.id
  await joinGridRoom({ roomId, microphoneEnabled: true }, contexts[1]!)
  await api("heartbeat", { workerId: "control-test", model: "meeting", ready: true })
  const current = async () =>
    (await getGrid({ spaceId: BigInt(space.id) }, contexts[0]!)).grid!.rooms.find((room) => room.id === roomId)!
  const control = async (
    enabled: boolean,
    destination = GridTranscriptDestination.GRID_TRANSCRIPT_LAST,
    transcriptChatId?: bigint,
    actor = 0,
    requestId = randomUUID(),
  ) => {
    const room = (await getGrid({ spaceId: BigInt(space.id) }, contexts[actor]!)).grid!.rooms.find(
      (room) => room.id === roomId,
    )!
    const avatar = room.avatars.find((avatar) => avatar.user?.id === BigInt(users[actor]!.id))!
    return setGridTranscription(
      {
        roomId,
        enabled,
        requestId,
        expectedMembershipId: avatar.membershipId,
        expectedGeneration: room.connection!.generation,
        expectedRunId: room.transcription?.runId,
        expectedRevision: room.transcription?.revision ?? 0,
        destination,
        transcriptChatId,
      },
      contexts[actor]!,
    )
  }
  const claim = async () => {
    const response = await api("claim", { workerId: "control-test" })
    expect(response.status).toBe(200)
    return (await response.json()) as Claimed
  }
  return { space, users, contexts, auth, roomId, current, control, claim }
}

async function admittedReplacement(label: string) {
  const f = await fixture(label)
  await joinGridRoom({ roomId: f.roomId, microphoneEnabled: true }, f.contexts[2]!)
  // Keep two occupants active after Leave/revocation so a room-wide stop cannot
  // mask whether session cleanup invalidates the correct admitted membership.
  providerSpy!.mockReturnValue({
    serverUrl: "wss://local.test",
    apiKey: "local-test-key",
    apiSecret: "local-test-secret-0123456789",
    provider: "cloud",
  })
  const [oldPresence] = await db.select().from(gridPresence).where(eq(gridPresence.userId, f.users[1].id))
  const replacement = await testUtils.createSessionForUser(f.users[1].id, {
    clientType: "macos",
    clientVersion: "qualified-test",
  })
  const context = testUtils.functionContext({ userId: f.users[1].id, sessionId: replacement.session.id })
  await joinGridRoom({ roomId: f.roomId, microphoneEnabled: true }, context)
  const [presence] = await db.select().from(gridPresence).where(eq(gridPresence.userId, f.users[1].id))
  expect(presence!.ownerSessionId).toBe(replacement.session.id)
  expect(presence!.mediaMembershipId).not.toBe(oldPresence!.mediaMembershipId)
  await f.control(true)
  const claim = await f.claim()
  const speaker = claim.participants.find((participant) => participant.userId === f.users[1].id)!
  expect(speaker.membershipId).toBe(presence!.mediaMembershipId)
  let turn = 0
  const admit = async (participantIdentity: string) => {
    const response = await api("admit", {
      participantIdentity,
      trackSid: `TR-session-${++turn}`,
      sourceTurnKey: `session-turn-${turn}`,
    }, claim.runToken)
    expect(response.status).toBe(200)
    return ((await response.json()) as { segmentId: string }).segmentId
  }
  const segmentId = await admit(speaker.identity)
  const segment = async (id = segmentId) =>
    (await db.select().from(gridTranscriptionSegments).where(eq(gridTranscriptionSegments.id, id)))[0]!
  const final = async (id = segmentId) => {
    const response = await api("final", { segmentId: id, text: "An admitted turn" }, claim.runToken)
    expect(response.status).toBe(200)
    return (await response.json()) as { messageId: number | null }
  }
  const revoke = (sessionId: number) => revokeSession({
    actor: "user",
    actorUserId: f.users[1].id,
    targetUserId: f.users[1].id,
    sessionId,
  })
  return { ...f, context, replacement, presence: presence!, claim, admit, segment, final, revoke }
}

async function admitRejoinedMembership(f: Awaited<ReturnType<typeof admittedReplacement>>) {
  await leaveGridRoom({ expectedRoomId: f.roomId }, f.context)
  expect((await f.segment()).state).toBe("admitted")
  await joinGridRoom({ roomId: f.roomId, microphoneEnabled: true }, f.context)
  const renewed = (await (await api("renew", {}, f.claim.runToken)).json()) as {
    participants: Claimed["participants"]
  }
  const speaker = renewed.participants.find((participant) => participant.userId === f.users[1].id)!
  expect(speaker.membershipId).not.toBe(f.presence.mediaMembershipId)
  return f.admit(speaker.identity)
}

describe("Grid transcription control and worker authorization", () => {
  test("stale session cleanup preserves the replacement owner's admitted final", async () => {
    const f = await admittedReplacement("stale-session-transcript")
    await f.revoke(f.auth[1]!.session.id)
    const [presence] = await db.select().from(gridPresence).where(eq(gridPresence.userId, f.users[1].id))
    expect(presence).toMatchObject({
      ownerSessionId: f.replacement.session.id,
      mediaMembershipId: f.presence.mediaMembershipId,
    })
    expect((await f.segment()).state).toBe("admitted")
    expect((await f.current()).transcription?.state).toBe(GridTranscriptionState.GRID_TRANSCRIPTION_ACTIVE)
    expect((await f.final()).messageId).toBeGreaterThan(0)
    expect((await f.segment()).state).toBe("finalized")
  })

  test("cloud owner takeover stops admitted capture without requiring a media generation change", async () => {
    const f = await fixture("cloud-capture-takeover")
    providerSpy!.mockReturnValue({
      serverUrl: "wss://local.test",
      apiKey: "local-test-key",
      apiSecret: "local-test-secret-0123456789",
      provider: "cloud",
    })
    await f.control(true)
    const claim = await f.claim()
    const generation = (await f.current()).connection!.generation
    const oldSpeaker = claim.participants.find((participant) => participant.userId === f.users[1].id)!
    const admission = { participantIdentity: oldSpeaker.identity, trackSid: "TR-cloud-takeover", sourceTurnKey: "old-turn" }
    const admitted = await api("admit", admission, claim.runToken)
    expect(admitted.status).toBe(200)
    const { segmentId } = (await admitted.json()) as { segmentId: string }
    const replacement = await testUtils.createSessionForUser(f.users[1].id, {
      clientType: "macos",
      clientVersion: "qualified-test",
    })
    const context = testUtils.functionContext({ userId: f.users[1].id, sessionId: replacement.session.id })
    const joined = await joinGridRoom({ roomId: f.roomId, microphoneEnabled: true }, context)
    const room = joined.grids[0]!.rooms.find((value) => value.id === f.roomId)!
    expect(room.connection!.generation).toBe(generation)
    const [run] = await db.select().from(gridTranscriptionRuns).where(eq(gridTranscriptionRuns.id, claim.runId))
    expect(run).toMatchObject({ state: "stopping", interruptionReason: "authority_lost" })
    const [segment] = await db.select().from(gridTranscriptionSegments).where(eq(gridTranscriptionSegments.id, segmentId))
    expect(segment!.state).toBe("discarded")
    expect((await api("admit", { ...admission, sourceTurnKey: "late-old-turn" }, claim.runToken)).status).toBe(409)
    const [presence] = await db.select().from(gridPresence).where(eq(gridPresence.userId, f.users[1].id))
    expect(presence!.mediaMembershipId).not.toBe(oldSpeaker.membershipId)
    const identity = livekit.gridParticipantIdentity(f.users[1].id, presence!.mediaMembershipId)
    expect((await api("admit", { ...admission, participantIdentity: identity, sourceTurnKey: "new-turn" }, claim.runToken)).status).toBe(409)
    const final = await api("final", { segmentId, text: "Must not survive ownership replacement" }, claim.runToken)
    expect(final.status).toBe(200)
    expect(await final.json()).toEqual({ messageId: null })
    expect(await db.select().from(messages).where(eq(messages.chatId, run!.transcriptChatId))).toHaveLength(0)
    expect((await (await api("renew", {}, claim.runToken)).json()) as object).toMatchObject({
      state: "stopping",
      allowFinalFlush: false,
    })
  })

  test("matching session cleanup discards its membership and preserves an earlier ordinary Leave final", async () => {
    const f = await admittedReplacement("matching-session-transcript")
    const currentSegmentId = await admitRejoinedMembership(f)
    await f.revoke(f.replacement.session.id)
    expect(await db.select().from(gridPresence).where(eq(gridPresence.userId, f.users[1].id))).toHaveLength(0)
    expect((await f.segment(currentSegmentId)).state).toBe("discarded")
    expect((await f.final(currentSegmentId)).messageId).toBeNull()
    expect((await f.segment()).state).toBe("admitted")
    expect((await f.final()).messageId).toBeGreaterThan(0)
  })

  test("current-presence Space revocation discards speech from earlier and current memberships", async () => {
    const f = await admittedReplacement("current-space-transcript")
    const currentSegmentId = await admitRejoinedMembership(f)
    await leaveSpace({ spaceId: f.space.id }, { ...f.context, ip: undefined })
    expect((await f.segment()).state).toBe("discarded")
    expect((await f.segment(currentSegmentId)).state).toBe("discarded")
    expect((await f.final()).messageId).toBeNull()
    expect((await f.final(currentSegmentId)).messageId).toBeNull()
  })

  for (const kind of ["session", "Space"] as const) {
    test(`absent-presence ${kind} revocation discards previously admitted speech`, async () => {
      const f = await admittedReplacement(`absent-${kind.toLowerCase()}-transcript`)
      await leaveGridRoom({ expectedRoomId: f.roomId }, f.context)
      expect((await f.segment()).state).toBe("admitted")
      if (kind === "session") await f.revoke(f.replacement.session.id)
      else await leaveSpace({ spaceId: f.space.id }, { ...f.context, ip: undefined })
      expect((await f.segment()).state).toBe("discarded")
      expect((await f.final()).messageId).toBeNull()
      const [run] = await db.select().from(gridTranscriptionRuns).where(eq(gridTranscriptionRuns.id, f.claim.runId))
      expect(await db.select().from(messages).where(eq(messages.chatId, run!.transcriptChatId))).toHaveLength(0)
    })
  }

  test("lazy private parent grants current and later room occupants while empty unclaimed Stop is terminal", async () => {
    const f = await fixture("lazy-control")
    expect((await f.current()).roomThreadId).toBeUndefined()
    const presence = (await db.select().from(gridPresence).where(eq(gridPresence.userId, f.users[0].id)))[0]!
    const opened = await openGridThread(
      { roomId: f.roomId, expectedMembershipId: presence.mediaMembershipId },
      f.contexts[0]!,
    )
    const parent = (
      await db
        .select()
        .from(chats)
        .where(eq(chats.id, Number(opened.chatId)))
    )[0]!
    expect(parent).toMatchObject({ publicThread: false, parentChatId: null })
    expect(
      (await db.select().from(chatParticipants).where(eq(chatParticipants.chatId, parent.id)))
        .map((p) => p.userId)
        .sort(),
    ).toEqual([f.users[0].id, f.users[1].id].sort())
    await f.control(true)
    const first = (await f.current()).transcription!
    expect(first.state).toBe(GridTranscriptionState.GRID_TRANSCRIPTION_STARTING)
    await f.control(false)
    expect((await f.current()).transcription?.state).toBe(GridTranscriptionState.GRID_TRANSCRIPTION_STOPPED)
    await joinGridRoom({ roomId: f.roomId }, f.contexts[2]!)
    expect(
      await db
        .select()
        .from(chatParticipants)
        .where(and(eq(chatParticipants.chatId, parent.id), eq(chatParticipants.userId, f.users[2].id))),
    ).toHaveLength(1)
    await f.control(true)
    expect((await f.current()).transcription?.runId).not.toBe(first.runId)
    expect((await f.current()).transcription?.transcriptChatId).toBe(first.transcriptChatId)
  })

  test("claim wire binds exact membership, rejects unknown admission and bounds retries, then final is idempotent", async () => {
    const f = await fixture("claim-control")
    const requestId = randomUUID()
    await f.control(true, GridTranscriptDestination.GRID_TRANSCRIPT_NEW, undefined, 0, requestId)
    await f.control(true, GridTranscriptDestination.GRID_TRANSCRIPT_NEW, undefined, 0, requestId)
    expect(await db.select().from(gridTranscriptionRuns)).toHaveLength(1)
    const claim = await f.claim()
    expect(claim).toMatchObject({ roomId: Number(f.roomId), model: "meeting", claimEpoch: 1 })
    expect(claim.participants).toHaveLength(2)
    const jwt = JSON.parse(Buffer.from(claim.livekit.token.split(".")[1]!, "base64url").toString("utf8")) as {
      video: { canPublish: boolean; canSubscribe: boolean; room: string }
    }
    expect(jwt.video).toMatchObject({ canPublish: false, canSubscribe: true })
    expect(jwt.video.room).toBe(`inline-grid-${f.roomId}-1`)
    expect(
      (await api("admit", { participantIdentity: "unknown", trackSid: "TR-one", sourceTurnKey: "one" }, claim.runToken))
        .status,
    ).toBe(409)
    const input = { participantIdentity: claim.participants[0]!.identity, trackSid: "TR-one", sourceTurnKey: "one" }
    const admitted = await api("admit", input, claim.runToken)
    expect(admitted.status).toBe(200)
    const ticket = (await admitted.json()) as { segmentId: string }
    expect(await (await api("admit", input, claim.runToken)).json()).toEqual(ticket)
    expect((await api("admit", { ...input, sourceTurnKey: "two" }, claim.runToken)).status).toBe(200)
    expect((await api("admit", { ...input, sourceTurnKey: "three" }, claim.runToken)).status).toBe(409)
    const finish = () => api("final", { segmentId: ticket.segmentId, text: "A verified turn" }, claim.runToken)
    const responses = await Promise.all([finish(), finish()])
    expect(responses.map((response) => response.status)).toEqual([200, 200])
    const finals = await Promise.all(responses.map((response) => response.json()))
    expect(finals[0]).toEqual(finals[1])
    const run = (await db.select().from(gridTranscriptionRuns))[0]!
    expect(await db.select().from(messages).where(eq(messages.chatId, run.transcriptChatId))).toHaveLength(1)
    expect((await api("admit", input, claim.runToken)).status).toBe(409)
    await f.control(false)
    expect((await (await api("renew", {}, claim.runToken)).json()) as object).toMatchObject({
      state: "stopping",
      allowFinalFlush: true,
    })
    await leaveGridRoom({ expectedRoomId: f.roomId }, f.contexts[1]!)
    expect((await (await api("renew", {}, claim.runToken)).json()) as object).toMatchObject({
      state: "stopping",
      allowFinalFlush: false,
    })
    expect(
      (
        await db
          .select()
          .from(gridTranscriptionSegments)
          .where(and(eq(gridTranscriptionSegments.runId, run.id), eq(gridTranscriptionSegments.sourceTurnKey, "two")))
      )[0]?.state,
    ).toBe("discarded")
    expect((await api("stopped", {}, claim.runToken)).status).toBe(200)
    expect((await db.select().from(gridTranscriptionRuns))[0]?.state).toBe("interrupted")
  })

  test("legacy participant blocks disclosure-qualified availability and cannot start", async () => {
    const f = await fixture("cohort-control")
    expect((await f.current()).transcriptionAvailable).toBe(true)
    await db.update(sessions).set({ clientVersion: "legacy" }).where(eq(sessions.id, f.auth[1]!.session.id))
    expect((await f.current()).transcriptionAvailable).toBe(false)
    await expect(f.control(true)).rejects.toThrow()
    expect(await db.select().from(gridTranscriptionRuns)).toHaveLength(0)
  })

  test("picker counts distinct transcripts and retains an intact origin after a newer cross-room link is retired", async () => {
    const f = await fixture("picker-distinct")
    await f.control(true)
    await f.control(false)
    const origin = (await db.select().from(gridTranscriptionRuns))[0]!
    await f.control(true, GridTranscriptDestination.GRID_TRANSCRIPT_NEW)
    await f.control(false)
    const repeated = (await db.select().from(gridTranscriptionRuns)).find((run) => run.id !== origin.id)!
    const now = Date.now()
    await db.insert(gridTranscriptionRuns).values(
      Array.from({ length: 105 }, (_, index) => ({
        ...repeated,
        id: randomUUID(),
        requestId: randomUUID(),
        createdAt: new Date(now + index),
      })),
    )
    const [otherRoom] = await db
      .insert(gridRooms)
      .values({ spaceId: f.space.id, createdByUserId: f.users[0].id, title: "Earlier transcript source" })
      .returning()
    await db.insert(gridTranscriptionRuns).values({
      ...origin,
      id: randomUUID(),
      requestId: randomUUID(),
      sourceRoomId: otherRoom!.id,
      roomLinkMessageId: 999999,
      interruptionReason: "message_deleted",
      createdAt: new Date(now + 1_000),
    })
    const listed = await listGridTranscripts({ roomId: f.roomId }, f.contexts[0]!)
    expect(listed.transcripts.map((entry) => Number(entry.transcriptChatId)).sort()).toEqual(
      [origin.transcriptChatId, repeated.transcriptChatId].sort(),
    )
    expect(listed.transcripts.every((entry) => !entry.busy)).toBe(true)
  })

  test("lease-only renewals keep Grid revision and hints quiet while authority loss publishes once", async () => {
    const f = await fixture("lease-only-renewal")
    await f.control(true)
    const claim = await f.claim()
    const notify = spyOn(gridRealtime, "notifyGridSpaceChanged").mockResolvedValue(undefined)
    try {
      const before = (await db.select().from(gridTranscriptionSpaceRevisions))[0]!.revision
      for (let index = 0; index < 3; index++) expect((await api("renew", {}, claim.runToken)).status).toBe(200)
      expect(notify).not.toHaveBeenCalled()
      expect((await db.select().from(gridTranscriptionSpaceRevisions))[0]!.revision).toBe(before)
      await db
        .update(gridTranscriptionRuns)
        .set({ leaseExpiresAt: new Date(Date.now() - 1000) })
        .where(eq(gridTranscriptionRuns.id, claim.runId))
      expect(await (await api("renew", {}, claim.runToken)).json()).toMatchObject({
        state: "stopping",
        allowFinalFlush: false,
      })
      expect(notify).toHaveBeenCalledTimes(1)
      expect((await db.select().from(gridTranscriptionSpaceRevisions))[0]!.revision).toBe(before + 1n)
      expect((await api("renew", {}, claim.runToken)).status).toBe(200)
      expect(notify).toHaveBeenCalledTimes(1)
    } finally {
      notify.mockRestore()
    }
  })

  test("clear of a stopped child permanently retires continuation while preserving readable ordinary history access", async () => {
    const f = await fixture("retired-control")
    await f.control(true)
    const before = (await f.current()).transcription!
    await f.control(false)
    await clearChatHistory(
      {
        peer: { type: { oneofKind: "chat", chat: { chatId: before.transcriptChatId! } } },
        keepLastDays: 0,
        deleteReplyThreads: false,
      },
      { currentUserId: f.users[0].id },
    )
    await expect(
      f.control(true, GridTranscriptDestination.GRID_TRANSCRIPT_EXISTING, before.transcriptChatId),
    ).rejects.toThrow()
    await f.control(true)
    expect((await f.current()).transcription?.transcriptChatId).not.toBe(before.transcriptChatId)
  })

  test("clear then media generation loss cannot restore a retired association", async () => {
    const f = await fixture("sticky-retirement")
    await f.control(true)
    const first = (await f.current()).transcription!
    const claim = await f.claim()
    await clearChatHistory(
      {
        peer: { type: { oneofKind: "chat", chat: { chatId: first.transcriptChatId! } } },
        keepLastDays: 0,
        deleteReplyThreads: false,
      },
      { currentUserId: f.users[0].id },
    )
    await leaveGridRoom({ expectedRoomId: f.roomId }, f.contexts[1]!)
    expect(
      (await db.select().from(gridTranscriptionRuns).where(eq(gridTranscriptionRuns.id, first.runId)))[0],
    ).toMatchObject({ state: "stopping", interruptionReason: "history_cleared" })
    expect((await api("stopped", {}, claim.runToken)).status).toBe(200)
    await joinGridRoom({ roomId: f.roomId, microphoneEnabled: true }, f.contexts[1]!)
    await f.control(true)
    expect((await f.current()).transcription?.transcriptChatId).not.toBe(first.transcriptChatId)
  })

  test("lost claim response can retry within one boot and disabled gate still accepts actual containment", async () => {
    const f = await fixture("claim-retry")
    await f.control(true)
    const first = await f.claim()
    const replay = await f.claim()
    expect(replay).toMatchObject({ runId: first.runId, claimEpoch: first.claimEpoch })
    expect((await api("claim", { workerId: "other-boot" })).status).toBe(204)
    await f.control(false)
    process.env["GRID_TRANSCRIPTION_ENABLED"] = "false"
    expect((await api("renew", {}, first.runToken)).status).toBe(503)
    expect((await api("stopped", {}, first.runToken)).status).toBe(200)
    expect(
      (await db.select().from(gridTranscriptionRuns).where(eq(gridTranscriptionRuns.id, first.runId)))[0]?.state,
    ).toBe("stopped")
  })

  test("an expired owned claim or false readiness yields only no-child containment authority", async () => {
    const f = await fixture("expired-owned-claim")
    await f.control(true)
    const claimed = await f.claim()
    await db
      .update(gridTranscriptionRuns)
      .set({ leaseExpiresAt: new Date(Date.now() - 1) })
      .where(eq(gridTranscriptionRuns.id, claimed.runId))
    const response = await api("claim", { workerId: "control-test" })
    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({
      runId: claimed.runId,
      claimEpoch: claimed.claimEpoch,
      stopImmediately: true,
    })
    expect(
      (await db.select().from(gridTranscriptionRuns).where(eq(gridTranscriptionRuns.id, claimed.runId)))[0]?.state,
    ).toBe("stopping")
    expect((await api("stopped", {}, claimed.runToken)).status).toBe(200)
    await f.control(true)
    const next = await f.claim()
    await api("heartbeat", { workerId: "control-test", model: "meeting", ready: false })
    expect(await (await api("claim", { workerId: "control-test" })).json()).toMatchObject({
      runId: next.runId,
      stopImmediately: true,
    })
    expect((await api("stopped", {}, next.runToken)).status).toBe(200)
  })

  test("presence Space ownership and parent-chat run retirement do not deadlock", async () => {
    const f = await fixture("counter-lock-order")
    await f.control(true)
    const run = (await db.select().from(gridTranscriptionRuns))[0]!
    const parentHeld = Promise.withResolvers<void>()
    const spaceHeld = Promise.withResolvers<void>()
    const before = (await f.current()).transcription!
    const retire = db.transaction(async (tx) => {
      await tx.execute(sql`set local statement_timeout = '5s'`)
      await tx.select({ id: chats.id }).from(chats).where(eq(chats.id, run.destinationParentChatId)).for("update")
      parentHeld.resolve()
      await spaceHeld.promise
      // The real revision trigger must complete without requesting the Space
      // row held by the presence transaction waiting for this parent.
      await tx
        .update(gridTranscriptionRuns)
        .set({ state: "stopped", revision: sql`${gridTranscriptionRuns.revision} + 1` })
        .where(eq(gridTranscriptionRuns.id, run.id))
    })
    const join = db.transaction(async (tx) => {
      try {
        await parentHeld.promise
        await tx.execute(sql`set local statement_timeout = '5s'`)
        await tx
          .update(gridPresence)
          .set({ microphoneRevision: sql`${gridPresence.microphoneRevision} + 1` })
          .where(eq(gridPresence.userId, f.users[1].id))
        spaceHeld.resolve()
        await enrollGridRoomHistory(tx, Number(f.roomId), [f.users[2].id])
      } finally {
        spaceHeld.resolve()
      }
    })
    await Promise.all([retire, join])
    expect(
      (
        await db
          .select()
          .from(gridTranscriptionSpaceRevisions)
          .where(eq(gridTranscriptionSpaceRevisions.spaceId, f.space.id))
      )[0]?.revision,
    ).toBeGreaterThan(1n)
    expect((await f.current()).transcription?.revision).toBeGreaterThan(before.revision)
    expect(
      await db
        .select()
        .from(chatParticipants)
        .where(
          and(eq(chatParticipants.chatId, run.destinationParentChatId), eq(chatParticipants.userId, f.users[2].id)),
        ),
    ).toHaveLength(1)
    // Retained counters have no Space FK: normal Space ownership is separate.
    expect((await db.select().from(spaces).where(eq(spaces.id, f.space.id)))[0]).toBeDefined()
  })

  test("all historical runs are owned before taking a shared counter during cross-room clear", async () => {
    const f = await fixture("multi-run-counter-order")
    await f.control(true)
    await f.control(false)
    const originalRun = (await db.select().from(gridTranscriptionRuns))[0]!
    const [sourceRoom] = await db
      .insert(gridRooms)
      .values({ spaceId: f.space.id, createdByUserId: f.users[0].id, title: "Other source" })
      .returning()
    if (!sourceRoom) throw new Error("Source room missing")
    const historicalId = "00000000-0000-4000-8000-000000000001"
    const activeId = "00000000-0000-4000-8000-000000000002"
    const sourceParent = await db.transaction(async (tx) => {
      const roomChatId = await ensureGridRoomThread(tx, {
        room: sourceRoom,
        actorUserId: f.users[0].id,
        participantUserIds: [f.users[0].id, f.users[1].id],
      })
      const linkId = await insertGridTranscriptContinuationLink(tx, {
        roomChatId,
        transcriptChatId: originalRun.transcriptChatId,
        actorUserId: f.users[0].id,
        runId: historicalId,
        title: "Earlier transcript",
      })
      const base = {
        sourceRoomId: sourceRoom.id,
        spaceId: f.space.id,
        roomChatId,
        transcriptChatId: originalRun.transcriptChatId,
        destinationParentChatId: originalRun.destinationParentChatId,
        originalAnchorId: originalRun.originalAnchorId,
        roomLinkMessageId: linkId,
        actorUserId: f.users[0].id,
        model: "meeting",
        generation: 1,
        providerTarget: livekit.durableLiveKitProviderTarget(),
        expiresAt: new Date(Date.now() + 60_000),
      }
      await tx
        .insert(gridTranscriptionRuns)
        .values({ ...base, id: historicalId, requestId: randomUUID(), state: "stopped" })
      await tx.insert(gridTranscriptionRuns).values({
        ...base,
        id: activeId,
        requestId: randomUUID(),
        state: "active",
        workerId: "existing-worker",
        claimEpoch: 1,
        leaseExpiresAt: new Date(Date.now() + 60_000),
      })
      return roomChatId
    })
    const activeOwned = Promise.withResolvers<void>()
    const finishActive = Promise.withResolvers<void>()
    let workerPid = 0
    const stopped = db.transaction(async (tx) => {
      const [backend] = await tx.execute<{ pid: number }>(sql`select pg_backend_pid() as pid`)
      workerPid = backend!.pid
      await tx.execute(sql`set local statement_timeout = '5s'`)
      await tx
        .select({ id: chats.id })
        .from(chats)
        .where(eq(chats.id, originalRun.destinationParentChatId))
        .for("update")
      await tx
        .select({ id: gridTranscriptionRuns.id })
        .from(gridTranscriptionRuns)
        .where(eq(gridTranscriptionRuns.id, activeId))
        .for("update")
      activeOwned.resolve()
      await finishActive.promise
      await tx
        .update(gridTranscriptionRuns)
        .set({ state: "stopped", revision: sql`${gridTranscriptionRuns.revision} + 1` })
        .where(eq(gridTranscriptionRuns.id, activeId))
    })
    await activeOwned.promise
    const clearing = db.transaction(async (tx) => {
      await tx.execute(sql`set local statement_timeout = '5s'`)
      await tx.select({ id: chats.id }).from(chats).where(eq(chats.id, sourceParent)).for("update")
      await invalidateGridTranscriptionForHistory(tx, { chatIds: [sourceParent], reason: "history_cleared" })
    })
    try {
      let blocked = false
      const deadline = performance.now() + 3_000
      while (performance.now() < deadline) {
        const [row] = await db.execute<{ blocked: boolean }>(
          sql`select exists(select 1 from pg_stat_activity where ${workerPid} = any(pg_blocking_pids(pid))) as blocked`,
        )
        if (row?.blocked) {
          blocked = true
          break
        }
        await Bun.sleep(10)
      }
      expect(blocked).toBe(true)
      finishActive.resolve()
      await Promise.all([stopped, clearing])
    } finally {
      finishActive.resolve()
      await Promise.allSettled([stopped, clearing])
    }
    expect(
      (
        await db.select().from(gridTranscriptionRuns).where(eq(gridTranscriptionRuns.sourceRoomId, sourceRoom.id))
      ).every((run) => run.interruptionReason === "history_cleared"),
    ).toBe(true)
  })

  test("deleting the retained room parent recreates a fresh private binding on explicit Open and Start", async () => {
    const f = await fixture("deleted-room-parent")
    await f.control(true)
    await f.control(false)
    const run = (await db.select().from(gridTranscriptionRuns))[0]!
    const peer = { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(run.roomChatId) } } }
    await clearChatHistory({ peer, keepLastDays: 0, deleteReplyThreads: true }, { currentUserId: f.users[0].id })
    await deleteChat({ peer }, f.contexts[0]!)
    expect((await f.current()).roomThreadId).toBeUndefined()
    const presence = (await db.select().from(gridPresence).where(eq(gridPresence.userId, f.users[0].id)))[0]!
    const reopened = await openGridThread(
      { roomId: f.roomId, expectedMembershipId: presence.mediaMembershipId },
      f.contexts[0]!,
    )
    expect(reopened.chatId).not.toBe(BigInt(run.roomChatId))
    expect(
      (
        await db
          .select()
          .from(chats)
          .where(eq(chats.id, Number(reopened.chatId)))
      )[0],
    ).toMatchObject({ publicThread: false, spaceId: f.space.id, parentChatId: null })
    await f.control(true)
    expect((await f.current()).transcription?.transcriptChatId).not.toBe(BigInt(run.transcriptChatId))
  })

  test("empty and stale membership fences cannot open or control a replacement membership", async () => {
    const f = await fixture("member-fence")
    const old = (await db.select().from(gridPresence).where(eq(gridPresence.userId, f.users[0].id)))[0]!
    await expect(openGridThread({ roomId: f.roomId, expectedMembershipId: "" }, f.contexts[0]!)).rejects.toThrow()
    await db.update(gridPresence).set({ mediaMembershipId: randomUUID() }).where(eq(gridPresence.userId, f.users[0].id))
    await expect(
      openGridThread({ roomId: f.roomId, expectedMembershipId: old.mediaMembershipId }, f.contexts[0]!),
    ).rejects.toThrow()
    await expect(
      setGridTranscription(
        {
          roomId: f.roomId,
          enabled: true,
          requestId: randomUUID(),
          expectedMembershipId: "",
          expectedGeneration: 1,
          expectedRevision: 0,
          destination: GridTranscriptDestination.GRID_TRANSCRIPT_NEW,
        },
        f.contexts[0]!,
      ),
    ).rejects.toThrow()
    expect(await db.select().from(gridTranscriptionRuns)).toHaveLength(0)
  })

  test("worker request authentication and chunk body limits reject before mutating", async () => {
    configure()
    expect((await api("heartbeat", { workerId: "test", model: "meeting", ready: true }, "wrong-secret")).status).toBe(
      401,
    )
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array(150_000))
        controller.enqueue(new Uint8Array(150_000))
        controller.close()
      },
    })
    const request = new Request("http://localhost/_internal/grid-transcription/heartbeat", {
      method: "POST",
      headers: { authorization: `Bearer ${secret}` },
      body,
      duplex: "half",
    } as RequestInit)
    expect((await handleGridTranscriptionWorkerRequest(request)).status).toBe(413)
    expect((await api("heartbeat", { workerId: "test", model: "unknown", ready: true })).status).toBe(400)
  })
})
