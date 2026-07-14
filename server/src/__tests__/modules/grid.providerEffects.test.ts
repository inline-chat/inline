import { describe, expect, test } from "bun:test"
import { GridProviderEffectWorker } from "@in/server/modules/grid/providerEffects"

const effect = {
  id: 1,
  kind: "revoke_participant",
  deduplicationKey: "revoke_participant:42:3:inline-grid-user-7-1000",
  roomId: 42,
  connectionGeneration: 3,
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
})
