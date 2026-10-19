import { describe, expect, test } from "bun:test"
import { GridProviderEffectWorker, type GridProviderEffectWorkerOptions } from "./providerEffects"

const settle = () => new Promise<void>((resolve) => setTimeout(resolve, 0))

describe("grid provider effect worker idle backoff", () => {
  test("skips claim queries on idle ticks and resumes at the base interval after work or a wake", async () => {
    let tick: (() => void) | undefined
    let claims = 0
    let pending: Awaited<ReturnType<NonNullable<GridProviderEffectWorkerOptions["claim"]>>> = []
    const worker = new GridProviderEffectWorker({
      pollIntervalMs: 2_000,
      maximumIdleIntervalMs: 8_000,
      claim: async () => { claims += 1; return pending },
      execute: async () => {},
      complete: async () => {},
      retry: async () => {},
      setIntervalFn: ((handler: () => void) => {
        tick = handler
        return Symbol("interval") as unknown as ReturnType<typeof setInterval>
      }) as unknown as GridProviderEffectWorkerOptions["setIntervalFn"],
      clearIntervalFn: () => {},
    })
    worker.start()
    await worker.pollOnce()
    expect(claims).toBe(1)
    expect(worker.idleMultiplier).toBe(2)

    const claimsPerTick: number[] = []
    for (let index = 0; index < 6; index += 1) {
      tick?.()
      await settle()
      claimsPerTick.push(claims)
    }
    // Tick 2 polls with a two-interval gap; the next poll waits four intervals (the cap) until tick 6.
    expect(claimsPerTick).toEqual([1, 2, 2, 2, 2, 3])
    expect(worker.idleMultiplier).toBe(4)

    worker.wake()
    expect(worker.idleMultiplier).toBe(1)
    tick?.()
    await settle()
    expect(claims).toBe(4)

    pending = [{
      id: 1, kind: "revoke_participant", deduplicationKey: "k", roomId: 1, connectionGeneration: 1,
      providerTarget: "t", userId: 1, participantIdentity: "p", availableAt: new Date(), claimToken: "c",
      claimExpiresAt: null, attempts: 0, lastError: null, createdAt: new Date(), updatedAt: new Date(),
    }]
    tick?.(); tick?.()
    await settle()
    expect(claims).toBe(5)
    expect(worker.idleMultiplier).toBe(1)
    await worker.stop()
  })
})
