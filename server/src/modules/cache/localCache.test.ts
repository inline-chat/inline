import { describe, expect, test } from "bun:test"
import { LocalCache } from "./localCache"

describe("LocalCache", () => {
  test("shares a fill and refetches after invalidation during that fill", async () => {
    const cache = new LocalCache<number, string>({ ttlMs: 1000, negativeTtlMs: 100, maxEntries: 2 })
    let finish!: (value: string) => void
    const old = new Promise<string>((resolve) => { finish = resolve })
    let loads = 0
    const loader = async () => ++loads === 1 ? old : "new"
    const first = cache.get(1, loader)
    const second = cache.get(1, loader)
    cache.invalidate(1)
    finish("old")
    expect(await first).toBe("new")
    expect(await second).toBe("new")
    expect(await cache.get(1, loader)).toBe("new")
    expect(loads).toBe(2)
  })

  test("bounds staleness on loader failure", async () => {
    const cache = new LocalCache<number, string>({ ttlMs: 10, negativeTtlMs: 5, maxEntries: 2, staleOnErrorMs: 10 })
    let now = 1000
    const originalNow = Date.now
    Date.now = () => now
    try {
      expect(await cache.get(1, async () => "value")).toBe("value")
      now = 1012
      expect(await cache.get(1, async () => { throw new Error("database") })).toBe("value")
      now = 1021
      await expect(cache.get(1, async () => { throw new Error("database") })).rejects.toThrow("database")
    } finally { Date.now = originalNow }
  })
})
