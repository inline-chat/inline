import { describe, expect, spyOn, test } from "bun:test"
import { db } from "@in/server/db"
import { gridProviderEffects } from "@in/server/db/schema"
import { setupTestLifecycle } from "@in/server/__tests__/setup"
import { RoomServiceClient, ServerError } from "livekit-server-sdk"
import { executeGridProviderEffect, GridProviderEffectWorker } from "@in/server/modules/grid/providerEffects"

const effect = {
  id: 1,
  kind: "revoke_participant",
  deduplicationKey: "revoke_participant:42:3:inline-grid-user-7-1000",
  roomId: 42,
  connectionGeneration: 3,
  providerTarget: "https://cloud-project.livekit.cloud",
  userId: 7,
  participantIdentity: "inline-grid-user-7-1000",
  availableAt: new Date(1_000),
  attempts: 0,
  claimToken: "claim-1",
  claimExpiresAt: new Date(31_000),
  lastError: null,
  createdAt: new Date(1_000),
  updatedAt: new Date(1_000),
}

describe("Grid provider effect worker", () => {
  test("coalesces overlapping polls and completes a successful leased effect", async () => {
    let releaseClaim: (() => void) | undefined
    let claimCount = 0
    const completed: number[] = []
    const worker = new GridProviderEffectWorker({
      claim: async () => {
        claimCount += 1
        await new Promise<void>((resolve) => {
          releaseClaim = resolve
        })
        return [effect]
      },
      execute: async () => {},
      complete: async (item) => void completed.push(item.id),
    })

    const first = worker.pollOnce()
    const second = worker.pollOnce()
    expect(second).toBe(first)
    releaseClaim?.()
    await first

    expect(claimCount).toBe(1)
    expect(completed).toEqual([1])
  })

  test("releases a failed effect for durable retry instead of dropping it", async () => {
    const retries: Array<{ id: number; message: string }> = []
    const worker = new GridProviderEffectWorker({
      now: () => 50_000,
      claim: async () => [effect],
      execute: async () => {
        throw new Error("provider offline")
      },
      complete: async () => {
        throw new Error("must not complete")
      },
      retry: async (item, error) => {
        retries.push({ id: item.id, message: error instanceof Error ? error.message : String(error) })
      },
    })

    await worker.pollOnce()
    expect(retries).toEqual([{ id: 1, message: "provider offline" }])
  })

  test("bounds a hung provider operation and keeps shutdown wait finite", async () => {
    let retryMessage = ""
    const worker = new GridProviderEffectWorker({
      providerTimeoutMs: 5,
      claim: async () => [effect],
      execute: () => new Promise<void>(() => {}),
      complete: async () => {},
      retry: async (_item, error) => {
        retryMessage = error instanceof Error ? error.message : String(error)
      },
    })

    await worker.pollOnce()
    await worker.stop()
    expect(retryMessage).toContain("timed out")
  })

  test("refuses to replay an effect against a different provider origin", async () => {
    await expect(
      executeGridProviderEffect(effect, {
        serverUrl: "wss://livekit.inline.chat",
        apiKey: "test-key",
        apiSecret: "test-secret-that-is-long-enough-for-hmac",
      }),
    ).rejects.toThrow("Grid provider target mismatch")
  })

  test("keeps an effect with unknown ownership fail-closed", async () => {
    await expect(
      executeGridProviderEffect(
        { ...effect, providerTarget: "unconfigured" },
        {
          serverUrl: "wss://livekit.inline.chat",
          apiKey: "test-key",
          apiSecret: "test-secret-that-is-long-enough-for-hmac",
        },
      ),
    ).rejects.toThrow("Grid provider target mismatch")
  })

  test("never sends a legacy effect with missing ownership to the current provider", async () => {
    const fetch = spyOn(globalThis, "fetch").mockRejectedValue(new Error("unexpected provider request"))
    try {
      await expect(
        executeGridProviderEffect(
          { ...effect, providerTarget: null },
          {
            serverUrl: "wss://livekit.example.invalid",
            apiKey: "test-key",
            apiSecret: "test-secret-that-is-long-enough-for-hmac",
          },
        ),
      ).rejects.toThrow("Grid provider target mismatch")
      expect(fetch).not.toHaveBeenCalled()
    } finally {
      fetch.mockRestore()
    }
  })
})

describe("Grid provider retry overlap", () => {
  setupTestLifecycle()

  for (const kind of ["close_connection", "revoke_participant"] as const) {
    test(`${kind} late completion cannot affect a newer generation or membership`, async () => {
      const config = {
        serverUrl: "wss://cloud-project.livekit.cloud",
        apiKey: "test-key",
        apiSecret: "test-secret-that-is-long-enough-for-hmac",
      }
      await db.insert(gridProviderEffects).values({
        kind,
        deduplicationKey: `${kind}:42:3:overlap`,
        roomId: 42,
        connectionGeneration: 3,
        providerTarget: effect.providerTarget,
        userId: kind === "revoke_participant" ? effect.userId : null,
        participantIdentity: kind === "revoke_participant" ? effect.participantIdentity : null,
        availableAt: new Date(1_000),
      })

      // Fake only the SDK boundary. Keep claim leases, retry persistence,
      // execution routing and completion on the production paths.
      const oldRoom = "inline-grid-42-3"
      const newRoom = "inline-grid-42-4"
      const oldIdentity = effect.participantIdentity
      const rejoinedIdentity = "inline-grid-user-7-new-membership"
      const rooms = new Map([
        [oldRoom, new Set([oldIdentity, rejoinedIdentity])],
        [newRoom, new Set([oldIdentity, rejoinedIdentity])],
      ])
      const requests: Array<{ room: string; identity?: string }> = []
      const firstStarted = Promise.withResolvers<void>()
      const releaseFirst = Promise.withResolvers<void>()
      const apply = async (room: string, identity?: string) => {
        requests.push({ room, identity })
        if (requests.length === 1) {
          firstStarted.resolve()
          await releaseFirst.promise
        }
        const removed = identity === undefined ? rooms.delete(room) : rooms.get(room)?.delete(identity)
        if (!removed) throw new ServerError("NotFound", "already absent", 404, "not_found")
      }
      const close = spyOn(RoomServiceClient.prototype, "deleteRoom").mockImplementation((room) => apply(room))
      const revoke = spyOn(RoomServiceClient.prototype, "removeParticipant")
        .mockImplementation((room, identity) => apply(room, identity))
      const executions: Promise<void>[] = []
      const execute = (item: Parameters<typeof executeGridProviderEffect>[0]) => {
        const operation = executeGridProviderEffect(item, config)
        executions.push(operation)
        return operation
      }
      let now = 1_000
      const first = new GridProviderEffectWorker({ now: () => now, providerTimeoutMs: 5, execute })
      const second = new GridProviderEffectWorker({ now: () => now, execute })
      try {
        const initialPoll = first.pollOnce()
        await firstStarted.promise
        await initialPoll // The first provider call is still held after timeout.
        await first.stop()
        const [retry] = await db.select().from(gridProviderEffects)
        expect(retry?.attempts).toBe(1)
        expect(retry?.claimToken).toBeNull()
        expect(retry?.lastError).toContain("timed out")
        expect(requests).toHaveLength(1)

        now = retry!.availableAt.getTime()
        await second.pollOnce()
        expect(requests).toHaveLength(2)
        expect(await db.select().from(gridProviderEffects)).toHaveLength(0)

        // The delayed first request really finishes after the retry. Repeating
        // deletion is harmless even when the provider reports already absent.
        releaseFirst.resolve()
        await expect(executions[0]!).rejects.toMatchObject({ status: 404, code: "not_found" })
        expect(requests).toEqual([
          { room: oldRoom, identity: kind === "revoke_participant" ? oldIdentity : undefined },
          { room: oldRoom, identity: kind === "revoke_participant" ? oldIdentity : undefined },
        ])
        expect(rooms.get(newRoom)).toEqual(new Set([oldIdentity, rejoinedIdentity]))
        if (kind === "revoke_participant") {
          expect(rooms.get(oldRoom)).toEqual(new Set([rejoinedIdentity]))
        } else {
          expect(rooms.has(oldRoom)).toBe(false)
        }
        expect(await db.select().from(gridProviderEffects)).toHaveLength(0)
      } finally {
        releaseFirst.resolve()
        await Promise.allSettled(executions)
        await Promise.all([first.stop(), second.stop()])
        close.mockRestore()
        revoke.mockRestore()
      }
    })
  }
})
