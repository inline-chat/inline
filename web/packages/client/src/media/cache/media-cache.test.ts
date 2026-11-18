import { describe, expect, it } from "vitest"
import { VirtualClock } from "../../testing/virtual-clock"
import { SWEEP_MINIMUM_AGE_MS } from "../constants"
import { MemoryByteStore } from "../store/byte-store"
import { testBytes } from "../testing/transfer-server"
import { MediaCache } from "./media-cache"

const key = (n: number, variant = "file") => ({ fileUniqueId: `file-${String(n).padStart(4, "0")}`, variant })
const DAY = 24 * 60 * 60 * 1_000

const setup = (budgetBytes = 1_000) => {
  const clock = new VirtualClock()
  const store = new MemoryByteStore(clock)
  const cache = new MediaCache({ store, root: "accounts/a1/media/", budgetBytes, clock })
  return { clock, store, cache }
}

describe("media cache", () => {
  it("evicts least recently used entries to fit the budget", async () => {
    const { cache } = setup(1_000)
    await cache.open()
    await cache.put(key(1), testBytes(400))
    await cache.put(key(2), testBytes(400))
    await cache.read(key(1))
    await cache.put(key(3), testBytes(400))
    expect(cache.has(key(1))).toBe(true)
    expect(cache.has(key(2))).toBe(false)
    expect(cache.has(key(3))).toBe(true)
    expect(cache.usage().bytes).toBe(800)
  })

  it("never evicts a pinned entry, for any reason, and evicts it once unpinned", async () => {
    const { cache } = setup(1_000)
    await cache.open()
    await cache.put(key(1), testBytes(400))
    await cache.put(key(2), testBytes(400))
    await cache.put(key(3), testBytes(400))
    const unpinViewer = cache.pin(key(2), "viewer")
    const unpinKeep = cache.pin(key(3), "keep")
    cache.pin(key(4), "upload")
    await cache.put(key(4), testBytes(400))
    await cache.put(key(5), testBytes(400))
    expect(cache.has(key(2))).toBe(true)
    expect(cache.has(key(3))).toBe(true)
    expect(cache.has(key(4))).toBe(true)
    expect(cache.usage().pinnedBytes).toBe(1_200)
    // Over budget with only pinned entries left besides the newest: pins hold.
    expect(cache.usage().bytes).toBeGreaterThan(1_000)
    unpinViewer()
    unpinKeep()
    await cache.evictToBudget()
    expect(cache.has(key(2))).toBe(false)
    expect(cache.has(key(4))).toBe(true)
  })

  it("rebuilds its index from storage after a restart", async () => {
    const { clock, store, cache } = setup(10_000)
    await cache.open()
    await cache.put(key(1, "d"), testBytes(100))
    const writer = await cache.beginWrite(key(2))
    await writer.setMeta({ totalSize: 300, validator: "\"v\"" })
    await writer.write(testBytes(120))
    await writer.checkpoint()
    await writer.write(testBytes(50))
    store.dropUncommitted()
    const reopened = new MediaCache({ store, root: "accounts/a1/media/", budgetBytes: 10_000, clock })
    await reopened.open()
    expect(reopened.has(key(1, "d"))).toBe(true)
    expect(reopened.entry(key(2))).toMatchObject({ complete: false, size: 120 })
    const resumed = await reopened.beginWrite(key(2))
    expect(resumed.offset).toBe(120)
    expect(resumed.meta).toEqual({ totalSize: 300, validator: "\"v\"" })
  })

  it("sweeps unreferenced week-old files once a day, and nothing when references fail", async () => {
    const { clock, cache } = setup(10_000)
    await cache.open()
    await cache.put(key(1), testBytes(10))
    await cache.put(key(2), testBytes(10))
    await cache.put(key(3), testBytes(10))
    const unpin = cache.pin(key(3), "viewer")
    await clock.advance(SWEEP_MINIMUM_AGE_MS)
    await cache.put(key(4), testBytes(10))
    expect(await cache.sweep({ referenced: () => Promise.reject(new Error("db closed")) })).toBeUndefined()
    expect(cache.usage().entries).toBe(4)
    // The failed run still counts for today.
    expect(await cache.sweep({ referenced: async () => new Set([key(1).fileUniqueId]) })).toBeUndefined()
    await clock.advance(DAY)
    const result = await cache.sweep({ referenced: async () => new Set([key(1).fileUniqueId]) })
    expect(result).toEqual({ removed: 1, removedBytes: 10, failed: 0 })
    expect(cache.has(key(1))).toBe(true)
    expect(cache.has(key(2))).toBe(false)
    expect(cache.has(key(3))).toBe(true)
    expect(cache.has(key(4))).toBe(true)
    unpin()
  })

  it("applies Keep Media to referenced files older than the setting", async () => {
    const { clock, cache } = setup(10_000)
    await cache.open()
    await cache.put(key(1), testBytes(10))
    await clock.advance(8 * DAY)
    await cache.put(key(2), testBytes(10))
    const result = await cache.sweep({ referenced: async () => new Set([key(1).fileUniqueId, key(2).fileUniqueId]), keepMediaDays: 7 })
    expect(result?.removed).toBe(1)
    expect(cache.has(key(1))).toBe(false)
    expect(cache.has(key(2))).toBe(true)
  })

  it("erases only its own account", async () => {
    const clock = new VirtualClock()
    const store = new MemoryByteStore(clock)
    const a = new MediaCache({ store, root: "accounts/a1/media/", clock })
    const b = new MediaCache({ store, root: "accounts/b2/media/", clock })
    await a.open()
    await b.open()
    await a.put(key(1), testBytes(10))
    await b.put(key(1), testBytes(10))
    await a.erase()
    expect(await store.list("accounts/a1/")).toEqual([])
    expect(await store.list("accounts/b2/")).toHaveLength(1)
    await expect(a.put(key(2), testBytes(1))).rejects.toMatchObject({ code: "closed" })
  })
})
