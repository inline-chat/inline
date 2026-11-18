import { readFileSync } from "node:fs"
import { describe, expect, it } from "vitest"
import { queueAccountStorageSweep } from "./storage-sweep"
import { manualPaints } from "./test-fixtures"
import { afterFirstPaint, chunkImporters } from "./view-chunks"
import { Warmup } from "./warmup"

const signedIn = { hasHydrated: true, storageStatus: "ready", currentUserId: "7", userIdHint: null } as never

const harness = () => {
  const paints = manualPaints()
  const idle: (() => boolean | void)[] = []
  const warmup = new Warmup({ afterPaint: paints.afterPaint, idle: (task) => void idle.push(task) })
  const calls: unknown[] = []
  let loads = 0
  const load = async () => {
    loads++
    return {
      sweepBrowserAccountStorage: async (options: unknown) => {
        calls.push(options)
        return undefined
      },
    }
  }
  const drain = async () => {
    while (idle.length > 0) {
      const task = idle.shift()!
      if (task()) idle.push(task)
      await Promise.resolve()
    }
    for (let i = 0; i < 5; i++) await Promise.resolve()
  }
  return { paints, warmup, calls, loads: () => loads, load, drain }
}

describe("the boot sweep", () => {
  it("is queued on the warm-up lane: nothing loads or runs before the first paint, then it sweeps with the auth store", async () => {
    const h = harness()
    const authStore = { getState: () => signedIn }
    expect(queueAccountStorageSweep({ warmup: h.warmup, demo: false, authStore, load: h.load })).toBe(true)
    await h.drain()
    expect(h.loads()).toBe(0)
    h.warmup.painted()
    h.paints.paint()
    await h.drain()
    expect(h.loads()).toBe(1)
    expect(h.calls).toEqual([{ authStore }])
  })

  it("never runs in the demo", async () => {
    const h = harness()
    expect(queueAccountStorageSweep({ warmup: h.warmup, demo: true, authStore: { getState: () => signedIn }, load: h.load })).toBe(false)
    h.warmup.painted()
    h.paints.paint()
    await h.drain()
    expect(h.loads()).toBe(0)
    expect(h.warmup.pending).toBe(0)
  })

  it("is a chunk of its own, loaded after the first paint, and boot queues it only outside the demo", () => {
    expect(afterFirstPaint).toContain("storageSweep")
    expect(String(chunkImporters.storageSweep)).toContain("account-storage-sweep")
    // The one call in boot.ts, after the demo's sign-in, keyed on the demo user.
    const boot = readFileSync(new URL("./boot.ts", import.meta.url), "utf8")
    const call = boot.indexOf("queueAccountStorageSweep({ warmup, demo: demoUserId !== undefined, authStore, log })")
    expect(call).toBeGreaterThan(boot.indexOf('await authStore.login({ userId: demoUserId, token: "demo" })'))
    expect(boot.split("queueAccountStorageSweep(").length).toBe(2)
  })
})
