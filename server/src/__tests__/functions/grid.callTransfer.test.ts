import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test"
import { randomUUID } from "node:crypto"
import { db } from "@in/server/db"
import {
  gridPresence,
  gridProviderEffects,
  gridTranscriptionRuns,
  gridTranscriptionSegments,
  members,
  messages,
} from "@in/server/db/schema"
import { waitForPostCommitHooks } from "@in/server/db/commitHooks"
import {
  createGridRoom,
  getGrid,
  getGridHome,
  joinGridRoom,
  leaveGridRoom,
  moveGridCallHere,
  prepareGridConnection,
  setGridAvatarMicrophoneEnabled,
  setGridRoomTitle,
} from "@in/server/functions/grid"
import { toggleSpaceGrid } from "@in/server/functions/space.settings"
import { setGridTranscription } from "@in/server/functions/gridTranscription"
import * as livekit from "@in/server/modules/grid/livekit"
import { handleGridTranscriptionWorkerRequest } from "@in/server/modules/grid/transcription/worker"
import { GridConnectionUnavailableReason, GridTranscriptDestination } from "@inline-chat/protocol/core"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

describe("Grid call ownership", () => {
  setupTestLifecycle()
  const originalActivation = process.env["GRID_CALL_TRANSFER_ENABLED"]
  beforeEach(() => {
    process.env["GRID_CALL_TRANSFER_ENABLED"] = "true"
  })
  afterEach(() => {
    process.env["GRID_CALL_TRANSFER_ENABLED"] = originalActivation ?? ""
  })

  test("defaults off without changing legacy ownership or renewal, and checks supplied fences", async () => {
    process.env["GRID_CALL_TRANSFER_ENABLED"] = ""
    const { space, contexts } = await fixture(1)
    const created = await createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)
    expect(created.grids[0]?.callTransferEnabled).toBe(false)
    expect((await getGridHome({}, contexts[0]!)).callTransferEnabled).toBe(false)
    const call = created.currentCall!
    await expect(
      moveGridCallHere({ callId: call.callId, expectedMembershipId: call.membershipId }, contexts[0]!),
    ).rejects.toThrow()
    await expect(
      setGridAvatarMicrophoneEnabled(
        {
          expectedRoomId: call.roomId,
          expectedMembershipId: randomUUID(),
          enabled: true,
        },
        contexts[0]!,
      ),
    ).rejects.toThrow()
    const shortenedLease = new Date(Date.now() + 60_000)
    await db
      .update(gridPresence)
      .set({ leaseExpiresAt: shortenedLease })
      .where(eq(gridPresence.userId, contexts[0]!.currentUserId))
    await getGrid({ spaceId: BigInt(space.id) }, contexts[0]!)
    expect((await ownPresence(contexts[0]!)).leaseExpiresAt.getTime()).toBeGreaterThan(shortenedLease.getTime())
  })

  test("activation rejects legacy mutations and Prepare, including an unfenced initial join", async () => {
    const { space, contexts } = await fixture(2)
    await expect(createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)).rejects.toThrow()
    const created = await createGridRoom({ spaceId: BigInt(space.id), expectedMembershipId: "" }, contexts[0]!)
    const call = created.currentCall!
    await expect(joinGridRoom({ roomId: call.roomId }, contexts[1]!)).rejects.toThrow()
    const joined = await joinGridRoom({ roomId: call.roomId, expectedMembershipId: "" }, contexts[1]!)
    const generation = joined.grids[0]!.rooms[0]!.connection!.generation
    await expect(joinGridRoom({ roomId: call.roomId }, contexts[0]!)).rejects.toThrow()
    await expect(createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)).rejects.toThrow()
    await expect(
      setGridAvatarMicrophoneEnabled({ expectedRoomId: call.roomId, enabled: true }, contexts[0]!),
    ).rejects.toThrow()
    await expect(leaveGridRoom({ expectedRoomId: call.roomId }, contexts[0]!)).rejects.toThrow()
    await expect(prepareGridConnection({ roomId: call.roomId, generation }, contexts[0]!)).rejects.toThrow()
    expect((await ownPresence(contexts[0]!)).mediaMembershipId).toBe(call.membershipId)
  })

  test("OFF exact-fenced legacy Join can replace a foreign device while stale Join/Create remain rejected", async () => {
    const { space, contexts, created, targetContext, generation } = await activeCall()
    process.env["GRID_CALL_TRANSFER_ENABLED"] = ""
    const old = created.currentCall!
    const joined = await joinGridRoom(
      { roomId: old.roomId, expectedMembershipId: old.membershipId },
      targetContext,
    )
    const current = joined.currentCall!
    expect((await ownPresence(contexts[0]!)).ownerSessionId).toBe(targetContext.currentSessionId)
    expect(current.membershipId).not.toBe(old.membershipId)
    // OFF retains legacy Join semantics; stable call identity belongs to Move.
    expect(current.callId).not.toBe(old.callId)
    expect(joined.grids[0]!.rooms[0]!.connection!.generation).not.toBe(generation)
    const effects = await db.select().from(gridProviderEffects)
    expect(
      effects.some(
        (effect) => effect.kind === "revoke_participant" &&
          effect.participantIdentity === `inline-grid-user-${contexts[0]!.currentUserId}-${old.membershipId}`,
      ),
    ).toBe(true)
    expect(effects.some((effect) => effect.kind === "close_connection" && effect.connectionGeneration === generation)).toBe(true)
    await expect(joinGridRoom({ roomId: old.roomId, expectedMembershipId: old.membershipId }, contexts[0]!)).rejects.toThrow()
    await expect(createGridRoom({ spaceId: BigInt(space.id), expectedMembershipId: old.membershipId }, contexts[0]!)).rejects.toThrow()
    expect((await ownPresence(contexts[0]!)).mediaMembershipId).toBe(current.membershipId)
  })

  test("OFF exact-fenced legacy Create can replace a foreign device without weakening its CAS", async () => {
    const { space, contexts, created, targetContext } = await activeCall()
    process.env["GRID_CALL_TRANSFER_ENABLED"] = ""
    const old = created.currentCall!
    const claimed = await createGridRoom(
      { spaceId: BigInt(space.id), expectedMembershipId: old.membershipId },
      targetContext,
    )
    const current = claimed.currentCall!
    expect((await ownPresence(contexts[0]!)).ownerSessionId).toBe(targetContext.currentSessionId)
    expect(current.roomId).not.toBe(old.roomId)
    expect(current.membershipId).not.toBe(old.membershipId)
    await expect(createGridRoom({ spaceId: BigInt(space.id), expectedMembershipId: old.membershipId }, contexts[0]!)).rejects.toThrow()
    await expect(joinGridRoom({ roomId: old.roomId, expectedMembershipId: old.membershipId }, contexts[0]!)).rejects.toThrow()
    expect((await ownPresence(contexts[0]!)).mediaMembershipId).toBe(current.membershipId)
  })

  test("OFF foreign exact fences cannot Leave, mute, Prepare, or renew; ON claims still require the owning device", async () => {
    const { space, contexts, created, targetContext, generation } = await activeCall()
    process.env["GRID_CALL_TRANSFER_ENABLED"] = ""
    const call = created.currentCall!
    const foreignInput = { expectedRoomId: call.roomId, expectedMembershipId: call.membershipId }
    expect((await leaveGridRoom(foreignInput, targetContext)).grids).toEqual([])
    await expect(setGridAvatarMicrophoneEnabled({ ...foreignInput, enabled: true }, targetContext)).rejects.toThrow()
    const prepared = await prepareGridConnection(
      { roomId: call.roomId, generation, expectedMembershipId: call.membershipId },
      targetContext,
    )
    expect(prepared.connection).toBeUndefined()
    expect(prepared.unavailableReason).toBe(GridConnectionUnavailableReason.NOT_ACTIVE)
    const shortenedLease = new Date(Date.now() + 60_000)
    await db.update(gridPresence).set({ leaseExpiresAt: shortenedLease }).where(eq(gridPresence.userId, contexts[0]!.currentUserId))
    await getGrid({ spaceId: BigInt(space.id), expectedMembershipId: call.membershipId }, targetContext)
    expect((await ownPresence(contexts[0]!)).leaseExpiresAt).toEqual(shortenedLease)
    process.env["GRID_CALL_TRANSFER_ENABLED"] = "true"
    await expect(joinGridRoom({ roomId: call.roomId, expectedMembershipId: call.membershipId }, targetContext)).rejects.toThrow()
    await expect(createGridRoom({ spaceId: BigInt(space.id), expectedMembershipId: call.membershipId }, targetContext)).rejects.toThrow()
    const unchanged = await ownPresence(contexts[0]!)
    expect(unchanged.ownerSessionId).toBe(contexts[0]!.currentSessionId)
    expect(unchanged.mediaMembershipId).toBe(call.membershipId)
  })

  test("browsing is read-only; only an exact admitted owner heartbeat renews", async () => {
    const { space, contexts } = await fixture(1)
    const created = await createGridRoom({ spaceId: BigInt(space.id), expectedMembershipId: "" }, contexts[0]!)
    const shortenedLease = new Date(Date.now() + 60_000)
    await db
      .update(gridPresence)
      .set({ leaseExpiresAt: shortenedLease })
      .where(eq(gridPresence.userId, contexts[0]!.currentUserId))
    await getGrid({ spaceId: BigInt(space.id) }, contexts[0]!)
    await getGridHome({}, contexts[0]!)
    await getGrid({ spaceId: BigInt(space.id), expectedMembershipId: randomUUID() }, contexts[0]!)
    expect((await ownPresence(contexts[0]!)).leaseExpiresAt).toEqual(shortenedLease)
    await getGrid({ spaceId: BigInt(space.id), expectedMembershipId: created.currentCall!.membershipId }, contexts[0]!)
    expect((await ownPresence(contexts[0]!)).leaseExpiresAt.getTime()).toBeGreaterThan(shortenedLease.getTime())
  })

  test("moves one stable presence to another device and isolates self-hosted media generations", async () => {
    const { contexts, created, generation, targetContext } = await activeCall()
    const before = await ownPresence(contexts[0]!)
    await setGridAvatarMicrophoneEnabled(
      {
        expectedRoomId: created.currentCall!.roomId,
        expectedMembershipId: before.mediaMembershipId,
        enabled: true,
      },
      contexts[0]!,
    )
    const moved = await moveGridCallHere(
      { callId: before.callId, expectedMembershipId: before.mediaMembershipId },
      targetContext,
    )
    const after = await ownPresence(contexts[0]!)
    expect(moved.moved).toBe(true)
    expect(after.callId).toBe(before.callId)
    expect(after.roomId).toBe(before.roomId)
    expect(after.joinedAt).toEqual(before.joinedAt)
    expect(after.ownerSessionId).toBe(targetContext.currentSessionId)
    expect(after.mediaMembershipId).not.toBe(before.mediaMembershipId)
    expect(after.microphoneEnabled).toBe(false)
    expect(after.microphoneRevision).toBe(0)
    expect(moved.currentCall).toMatchObject({
      callId: before.callId,
      membershipId: after.mediaMembershipId,
      ownedByCurrentSession: true,
      ownerClientType: "ios",
    })
    expect(moved.grids[0]!.rooms[0]!.avatars).toHaveLength(2)
    expect(moved.grids[0]!.rooms[0]!.connection!.generation).toBe(generation + 1)
    const oldView = await getGridHome({}, contexts[0]!)
    expect(oldView.currentCall?.ownedByCurrentSession).toBe(false)
    expect(oldView.currentCall?.membershipId).toBe(after.mediaMembershipId)
    const effects = await db.select().from(gridProviderEffects)
    expect(
      effects.some(
        (effect) =>
          effect.kind === "revoke_participant" &&
          effect.participantIdentity === `inline-grid-user-${contexts[0]!.currentUserId}-${before.mediaMembershipId}`,
      ),
    ).toBe(true)
    expect(
      effects.some((effect) => effect.kind === "close_connection" && effect.connectionGeneration === generation),
    ).toBe(true)
  })

  test("concurrent transfer intents claim the observed membership only once", async () => {
    const { contexts, created, targetContext } = await activeCall()
    const otherSession = await testUtils.createSessionForUser(contexts[0]!.currentUserId, { clientType: "macos" })
    const otherContext = testUtils.functionContext({
      userId: contexts[0]!.currentUserId,
      sessionId: otherSession.session.id,
    })
    const input = { callId: created.currentCall!.callId, expectedMembershipId: created.currentCall!.membershipId }
    const results = await Promise.all([moveGridCallHere(input, targetContext), moveGridCallHere(input, otherContext)])
    expect(results.filter((result) => result.moved)).toHaveLength(1)
    const presence = await ownPresence(contexts[0]!)
    const winnerContext = results[0]!.moved ? targetContext : otherContext
    expect(presence.ownerSessionId).toBe(winnerContext.currentSessionId)
    expect(presence.callId).toBe(input.callId)
    expect(await db.select().from(gridPresence)).toHaveLength(2)
  })

  test("A to B to A cannot apply A's old Leave, mute, join, create, renew, Prepare, or move", async () => {
    const { space, contexts, created, targetContext } = await activeCall()
    const old = created.currentCall!
    const toPhone = await moveGridCallHere(
      { callId: old.callId, expectedMembershipId: old.membershipId },
      targetContext,
    )
    const back = await moveGridCallHere(
      { callId: old.callId, expectedMembershipId: toPhone.currentCall!.membershipId },
      contexts[0]!,
    )
    const current = back.currentCall!
    const generation = back.grids[0]!.rooms[0]!.connection!.generation
    expect(current.membershipId).not.toBe(old.membershipId)
    expect(
      (await leaveGridRoom({ expectedRoomId: old.roomId, expectedMembershipId: old.membershipId }, contexts[0]!)).grids,
    ).toEqual([])
    await expect(
      setGridAvatarMicrophoneEnabled(
        { expectedRoomId: old.roomId, expectedMembershipId: old.membershipId, enabled: true },
        contexts[0]!,
      ),
    ).rejects.toThrow()
    await expect(
      joinGridRoom({ roomId: old.roomId, expectedMembershipId: old.membershipId }, contexts[0]!),
    ).rejects.toThrow()
    await expect(
      createGridRoom({ spaceId: BigInt(space.id), expectedMembershipId: old.membershipId }, contexts[0]!),
    ).rejects.toThrow()
    const prepared = await prepareGridConnection(
      { roomId: old.roomId, generation, expectedMembershipId: old.membershipId },
      contexts[0]!,
    )
    expect(prepared.connection).toBeUndefined()
    expect(prepared.unavailableReason).toBe(GridConnectionUnavailableReason.NOT_ACTIVE)
    const shortenedLease = new Date(Date.now() + 60_000)
    await db
      .update(gridPresence)
      .set({ leaseExpiresAt: shortenedLease })
      .where(eq(gridPresence.userId, contexts[0]!.currentUserId))
    await getGrid({ spaceId: BigInt(space.id), expectedMembershipId: old.membershipId }, contexts[0]!)
    expect((await ownPresence(contexts[0]!)).leaseExpiresAt).toEqual(shortenedLease)
    const staleMove = await moveGridCallHere(
      { callId: old.callId, expectedMembershipId: old.membershipId },
      targetContext,
    )
    expect(staleMove.moved).toBe(false)
    expect(staleMove.connection).toBeUndefined()
    expect((await ownPresence(contexts[0]!)).mediaMembershipId).toBe(current.membershipId)
  })

  test("explicit same-login cold Resume replaces ownership; retrying its old CAS does not replace it again", async () => {
    const { contexts, created } = await activeCall()
    const before = await ownPresence(contexts[0]!)
    const input = { callId: created.currentCall!.callId, expectedMembershipId: before.mediaMembershipId }
    const resumed = await moveGridCallHere(input, contexts[0]!)
    expect(resumed.moved).toBe(true)
    expect(resumed.currentCall!.callId).toBe(before.callId)
    expect(resumed.currentCall!.membershipId).not.toBe(before.mediaMembershipId)
    expect((await ownPresence(contexts[0]!)).joinedAt).toEqual(before.joinedAt)
    const retried = await moveGridCallHere(input, contexts[0]!)
    expect(retried.moved).toBe(false)
    expect(retried.currentCall!.membershipId).toBe(resumed.currentCall!.membershipId)
  })

  test("Leave ends the call episode even when the named room is reused", async () => {
    const { space, contexts } = await fixture(1)
    const created = await createGridRoom({ spaceId: BigInt(space.id), expectedMembershipId: "" }, contexts[0]!)
    const old = created.currentCall!
    await setGridRoomTitle({ roomId: old.roomId, title: "Persistent room" }, contexts[0]!)
    const left = await leaveGridRoom({ expectedRoomId: old.roomId, expectedMembershipId: old.membershipId }, contexts[0]!)
    expect(left.currentCall).toBeUndefined()
    const rejoined = await joinGridRoom({ roomId: old.roomId, expectedMembershipId: "" }, contexts[0]!)
    expect(rejoined.currentCall!.callId).not.toBe(old.callId)
    const staleMove = await moveGridCallHere({ callId: old.callId, expectedMembershipId: rejoined.currentCall!.membershipId }, contexts[0]!)
    expect(staleMove.moved).toBe(false)
    expect((await ownPresence(contexts[0]!)).callId).toBe(rejoined.currentCall!.callId)
  })

  test("an expired call cannot be moved or renewed back into existence", async () => {
    const { space, contexts, created, targetContext } = await activeCall()
    const old = created.currentCall!
    await db.update(gridPresence).set({ leaseExpiresAt: new Date(Date.now() - 1) }).where(eq(gridPresence.userId, contexts[0]!.currentUserId))
    const moved = await moveGridCallHere({ callId: old.callId, expectedMembershipId: old.membershipId }, targetContext)
    expect(moved.moved).toBe(false)
    expect(moved.currentCall).toBeUndefined()
    expect(moved.connection).toBeUndefined()
    await getGrid({ spaceId: BigInt(space.id), expectedMembershipId: old.membershipId }, contexts[0]!)
    expect(await db.select().from(gridPresence).where(eq(gridPresence.userId, contexts[0]!.currentUserId))).toEqual([])
  })

  test("Home returns self ownership independently of its capped public avatars", async () => {
    const { space, contexts } = await fixture(5)
    const created = await createGridRoom({ spaceId: BigInt(space.id), expectedMembershipId: "" }, contexts[0]!)
    for (const context of contexts.slice(1)) {
      await joinGridRoom({ roomId: created.currentCall!.roomId, expectedMembershipId: "" }, context)
    }
    const home = await getGridHome({}, contexts[0]!)
    expect(home.spaces[0]!.recentAvatars).toHaveLength(4)
    expect(home.currentCall?.callId).toBe(created.currentCall!.callId)
    expect(home.currentCall?.ownerClientType).toBe("macos")
    const otherHome = await getGridHome({}, contexts[1]!)
    expect(otherHome.currentCall?.callId).not.toBe(created.currentCall!.callId)
    expect(otherHome.currentCall?.ownedByCurrentSession).toBe(true)
    expect(otherHome.currentCall).not.toHaveProperty("ownerSessionId")
    expect(otherHome.currentCall).not.toHaveProperty("deviceId")
  })

  test("a delayed mint cannot return credentials for newer ownership on the same login", async () => {
    const { contexts, created, targetContext } = await activeCall()
    const enteredMint = Promise.withResolvers<void>()
    const releaseMint = Promise.withResolvers<void>()
    const pending = moveGridCallHere(
      {
        callId: created.currentCall!.callId,
        expectedMembershipId: created.currentCall!.membershipId,
      },
      targetContext,
      async (input) => {
        enteredMint.resolve()
        await releaseMint.promise
        return {
          connection: input.connection,
          serverUrl: "wss://grid.example.test",
          participantIdentity: input.participantIdentity!,
          token: "test-only-credential",
          expiresAt: BigInt(Math.floor(Date.now() / 1000) + 300),
          callId: input.callId!,
          membershipId: input.mediaMembershipId!,
        }
      },
    )
    await enteredMint.promise
    const firstPhoneMembership = (await ownPresence(contexts[0]!)).mediaMembershipId
    let latestPhoneMembership = firstPhoneMembership
    try {
      const toMac = await moveGridCallHere(
        { callId: created.currentCall!.callId, expectedMembershipId: firstPhoneMembership },
        contexts[0]!,
      )
      const toPhoneAgain = await moveGridCallHere(
        { callId: created.currentCall!.callId, expectedMembershipId: toMac.currentCall!.membershipId },
        targetContext,
      )
      latestPhoneMembership = toPhoneAgain.currentCall!.membershipId
    } finally {
      releaseMint.resolve()
    }
    const oldResult = await pending
    expect(oldResult.moved).toBe(true)
    expect(oldResult.currentCall!.membershipId).toBe(firstPhoneMembership)
    expect(oldResult.currentCall!.membershipId).not.toBe(latestPhoneMembership)
    expect(oldResult.connection).toBeUndefined()
    expect((await ownPresence(targetContext)).mediaMembershipId).toBe(latestPhoneMembership)
  })
})

describe("Grid call transfer transcription authority", () => {
  setupTestLifecycle()
  const secret = "grid-transfer-test-secret-0123456789012345"
  const original = new Map<string, string | undefined>()
  let providerSpy: ReturnType<typeof spyOn<typeof livekit, "getLiveKitGridConfig">> | undefined

  beforeEach(() => {
    for (const [key, value] of Object.entries({
      GRID_CALL_TRANSFER_ENABLED: "true",
      GRID_TRANSCRIPTION_ENABLED: "true",
      GRID_TRANSCRIPTION_WORKER_SECRET: secret,
      GRID_TRANSCRIPTION_MODEL: "meeting",
      GRID_TRANSCRIPTION_ALLOWED_CLIENT_VERSIONS: "qualified-transfer-test",
    })) {
      original.set(key, process.env[key])
      process.env[key] = value
    }
  })
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

  async function workerApi(action: string, body: unknown, token = secret) {
    return handleGridTranscriptionWorkerRequest(
      new Request(`http://localhost/_internal/grid-transcription/${action}`, {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: JSON.stringify(body),
      }),
    )
  }

  for (const provider of ["self_hosted", "cloud"] as const) {
    for (const sameLogin of [false, true]) {
      const replacement = sameLogin ? "same-login Resume" : "device Move"
      test(`${provider} ${replacement} discards admitted speech before ownership replacement`, async () => {
        providerSpy = spyOn(livekit, "getLiveKitGridConfig").mockReturnValue({
          serverUrl: "wss://grid-transfer.example.test",
          apiKey: "transfer-test-key",
          apiSecret: "transfer-test-secret-0123456789",
          provider,
        })
        const { space, contexts } = await fixture(2, "qualified-transfer-test")
        const owner = contexts[0]!
        const created = await createGridRoom(
          { spaceId: BigInt(space.id), expectedMembershipId: "", microphoneEnabled: true },
          owner,
        )
        const roomId = created.currentCall!.roomId
        await joinGridRoom({ roomId, expectedMembershipId: "", microphoneEnabled: true }, contexts[1]!)
        const before = await ownPresence(owner)
        const target = sameLogin
          ? owner
          : testUtils.functionContext({
              userId: owner.currentUserId,
              sessionId: (
                await testUtils.createSessionForUser(owner.currentUserId, {
                  clientType: "macos",
                  clientVersion: "qualified-transfer-test",
                })
              ).session.id,
            })
        const currentRoom = async (context: typeof owner) => {
          const result = await getGrid({ spaceId: BigInt(space.id) }, context)
          return result.grid!.rooms.find((room) => room.id === roomId)!
        }
        const start = async (context: typeof owner) => {
          const room = await currentRoom(context)
          const presence = await ownPresence(context)
          return setGridTranscription(
            {
              roomId,
              enabled: true,
              requestId: randomUUID(),
              expectedMembershipId: presence.mediaMembershipId,
              expectedGeneration: room.connection!.generation,
              expectedRunId: room.transcription?.runId,
              expectedRevision: room.transcription?.revision ?? 0,
              destination: GridTranscriptDestination.GRID_TRANSCRIPT_NEW,
            },
            context,
          )
        }
        const generation = (await currentRoom(owner)).connection!.generation
        const heartbeat = await workerApi("heartbeat", {
          workerId: "grid-transfer-test",
          model: "meeting",
          ready: true,
        })
        expect(heartbeat.status).toBe(200)
        await start(owner)
        const claimed = await workerApi("claim", { workerId: "grid-transfer-test" })
        expect(claimed.status).toBe(200)
        const claim = (await claimed.json()) as {
          runId: string
          runToken: string
          participants: { identity: string; userId: number; membershipId: string }[]
        }
        const participant = claim.participants.find((speaker) => speaker.userId === owner.currentUserId)!
        expect(participant.membershipId).toBe(before.mediaMembershipId)
        const admission = {
          participantIdentity: participant.identity,
          trackSid: "TR-transfer-old",
          sourceTurnKey: "pending-before-move",
        }
        const admitted = await workerApi("admit", admission, claim.runToken)
        expect(admitted.status).toBe(200)
        const ticket = (await admitted.json()) as { segmentId: string }
        const peer = claim.participants.find((speaker) => speaker.userId === contexts[1]!.currentUserId)!
        const admittedPeer = await workerApi(
          "admit",
          { participantIdentity: peer.identity, trackSid: "TR-transfer-peer", sourceTurnKey: "peer-before-move" },
          claim.runToken,
        )
        expect(admittedPeer.status).toBe(200)
        const peerTicket = (await admittedPeer.json()) as { segmentId: string }
        const run = (
          await db.select().from(gridTranscriptionRuns).where(eq(gridTranscriptionRuns.id, claim.runId))
        )[0]!
        const priorMessages = await db.select().from(messages).where(eq(messages.chatId, run.transcriptChatId))

        const moved = await moveGridCallHere(
          { callId: before.callId, expectedMembershipId: before.mediaMembershipId },
          target,
        )
        const after = await ownPresence(target)
        expect(moved.moved).toBe(true)
        expect(after.callId).toBe(before.callId)
        expect(after.roomId).toBe(before.roomId)
        expect(after.joinedAt).toEqual(before.joinedAt)
        expect(after.ownerSessionId).toBe(target.currentSessionId)
        expect(after.mediaMembershipId).not.toBe(before.mediaMembershipId)
        expect(after.microphoneEnabled).toBe(false)
        expect((await currentRoom(target)).connection!.generation).toBe(
          generation + (provider === "self_hosted" ? 1 : 0),
        )
        const stoppedRun = (
          await db.select().from(gridTranscriptionRuns).where(eq(gridTranscriptionRuns.id, claim.runId))
        )[0]
        expect(stoppedRun).toMatchObject({
          state: "stopping",
          interruptionReason: provider === "self_hosted" ? "generation_changed" : "authority_lost",
        })
        const oldSegment = (
          await db.select().from(gridTranscriptionSegments).where(eq(gridTranscriptionSegments.id, ticket.segmentId))
        )[0]
        expect(oldSegment?.state).toBe("discarded")
        expect(
          (await db.select().from(gridTranscriptionSegments).where(eq(gridTranscriptionSegments.id, peerTicket.segmentId)))[0]?.state,
        ).toBe("discarded")
        expect((await workerApi("admit", { ...admission, sourceTurnKey: "after-move" }, claim.runToken)).status).toBe(409)
        const final = await workerApi(
          "final",
          { segmentId: ticket.segmentId, text: "Late old membership" },
          claim.runToken,
        )
        expect(final.status).toBe(200)
        expect(await final.json()).toEqual({ messageId: null })
        expect(
          await (await workerApi("final", { segmentId: peerTicket.segmentId, text: "Late peer turn" }, claim.runToken)).json(),
        ).toEqual({ messageId: null })
        expect(await db.select().from(messages).where(eq(messages.chatId, run.transcriptChatId))).toEqual(priorMessages)
        expect(await (await workerApi("renew", {}, claim.runToken)).json()).toMatchObject({
          state: "stopping",
          allowFinalFlush: false,
        })
        const staleCredentials = await prepareGridConnection(
          { roomId, generation, expectedMembershipId: before.mediaMembershipId },
          owner,
        )
        expect(staleCredentials.connection).toBeUndefined()
        expect(staleCredentials.unavailableReason).toBe(GridConnectionUnavailableReason.NOT_ACTIVE)
        const freshCredentials = await prepareGridConnection(
          {
            roomId,
            generation: (await currentRoom(target)).connection!.generation,
            expectedMembershipId: after.mediaMembershipId,
          },
          target,
        )
        expect(freshCredentials.connection).toMatchObject({
          callId: before.callId,
          membershipId: after.mediaMembershipId,
          connection: { generation: generation + (provider === "self_hosted" ? 1 : 0) },
        })
        await expect(start(target)).rejects.toThrow()
        expect((await workerApi("stopped", {}, claim.runToken)).status).toBe(200)
        await start(target)
        const newClaimResponse = await workerApi("claim", { workerId: "grid-transfer-test" })
        expect(newClaimResponse.status).toBe(200)
        const newClaim = (await newClaimResponse.json()) as typeof claim
        expect(newClaim.runId).not.toBe(claim.runId)
        const newParticipant = newClaim.participants.find((speaker) => speaker.userId === owner.currentUserId)!
        expect(newParticipant.membershipId).toBe(after.mediaMembershipId)
        const newAdmission = await workerApi(
          "admit",
          { participantIdentity: newParticipant.identity, trackSid: "TR-transfer-new", sourceTurnKey: "new-turn" },
          newClaim.runToken,
        )
        expect(newAdmission.status).toBe(200)
        const newTicket = (await newAdmission.json()) as { segmentId: string }
        const newFinal = await workerApi("final", { segmentId: newTicket.segmentId, text: "New owner turn" }, newClaim.runToken)
        expect(newFinal.status).toBe(200)
        const committed = (await newFinal.json()) as { messageId: number | null }
        expect(committed.messageId).not.toBeNull()
        const newRun = (
          await db.select().from(gridTranscriptionRuns).where(eq(gridTranscriptionRuns.id, newClaim.runId))
        )[0]!
        expect(
          (await db.select().from(messages).where(eq(messages.chatId, newRun.transcriptChatId)))
            .some((message) => message.messageId === committed.messageId),
        ).toBe(true)
      })
    }
  }
})

async function fixture(count: number, clientVersion?: string) {
  const space = await testUtils.createSpace("Grid call transfer")
  if (!space) throw new Error("Expected fixture Space")
  const users = await Promise.all(
    Array.from({ length: count }, () => testUtils.createUser(`${randomUUID()}@example.test`)),
  )
  await db.insert(members).values(
    users.map((user, index) => ({
      spaceId: space.id,
      userId: user.id,
      role: index === 0 ? ("owner" as const) : ("member" as const),
    })),
  )
  const sessions = await Promise.all(
    users.map((user) => testUtils.createSessionForUser(user.id, { clientType: "macos", clientVersion })),
  )
  const contexts = users.map((user, index) =>
    testUtils.functionContext({ userId: user.id, sessionId: sessions[index]!.session.id }),
  )
  await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, contexts[0]!)
  return { space, users, contexts }
}

async function activeCall() {
  const { space, users, contexts } = await fixture(2)
  const created = await createGridRoom({ spaceId: BigInt(space.id), expectedMembershipId: "" }, contexts[0]!)
  const joined = await joinGridRoom({ roomId: created.currentCall!.roomId, expectedMembershipId: "" }, contexts[1]!)
  const target = await testUtils.createSessionForUser(users[0]!.id, { clientType: "ios" })
  const targetContext = testUtils.functionContext({ userId: users[0]!.id, sessionId: target.session.id })
  return { space, contexts, created, generation: joined.grids[0]!.rooms[0]!.connection!.generation, targetContext }
}

async function ownPresence(context: ReturnType<typeof testUtils.functionContext>) {
  const [presence] = await db.select().from(gridPresence).where(eq(gridPresence.userId, context.currentUserId))
  if (!presence) throw new Error("Expected live fixture presence")
  return presence
}
