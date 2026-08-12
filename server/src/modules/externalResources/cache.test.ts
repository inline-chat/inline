import { describe, expect, test } from "bun:test"
import { ExternalResourceCache } from "./cache"

describe("ExternalResourceCache", () => {
  test("reuses scoped values until TTL expiry", async () => {
    let now = 1_000
    let loads = 0
    const cache = new ExternalResourceCache<number>({
      ttlMs: 100,
      now: () => now,
    })
    const load = async () => ++loads

    expect(await cache.getOrLoad("space-1:roadmap", load)).toBe(1)
    expect(await cache.getOrLoad("space-1:roadmap", load)).toBe(1)
    expect(await cache.getOrLoad("space-2:roadmap", load)).toBe(2)

    now += 101
    expect(await cache.getOrLoad("space-1:roadmap", load)).toBe(3)
  })

  test("deduplicates concurrent loads and does not cache failures", async () => {
    let loads = 0
    const cache = new ExternalResourceCache<number>()
    let resolveLoad: ((value: number) => void) | undefined
    const pending = () => {
      loads += 1
      return new Promise<number>((resolve) => {
        resolveLoad = resolve
      })
    }

    const first = cache.getOrLoad("same", pending)
    const second = cache.getOrLoad("same", pending)
    expect(loads).toBe(1)
    resolveLoad?.(7)
    expect(await Promise.all([first, second])).toEqual([7, 7])

    let attempts = 0
    const failing = () => {
      attempts += 1
      return Promise.reject(new Error("failed"))
    }
    await expect(cache.getOrLoad("failure", failing)).rejects.toThrow("failed")
    await expect(cache.getOrLoad("failure", failing)).rejects.toThrow("failed")
    expect(attempts).toBe(2)
  })

  test("enforces its entry cap", async () => {
    const cache = new ExternalResourceCache<number>({ maxEntries: 2 })
    let loads = 0
    const load = async () => ++loads

    await cache.getOrLoad("a", load)
    await cache.getOrLoad("b", load)
    await cache.getOrLoad("c", load)
    await cache.getOrLoad("a", load)
    expect(loads).toBe(4)
  })
})
