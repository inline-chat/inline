import { afterEach, describe, expect, it, vi } from "vitest"
import { userId } from "@inline/ids"
import { IndexedDbInlineMediaCache } from "./IndexedDbInlineMediaCache"

describe("IndexedDbInlineMediaCache", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("evicts the least recently used metadata without scanning blobs", async () => {
    const now = vi.spyOn(Date, "now")
    const cache = new IndexedDbInlineMediaCache({
      accountId: userId(99_001),
      maxBytes: 6,
    })

    now.mockReturnValue(1_000)
    await cache.put("older", new Blob(["1234"]))
    now.mockReturnValue(2_000)
    await cache.put("newer", new Blob(["5678"]))

    await expect(cache.get("older")).resolves.toBeUndefined()
    await expect(cache.get("newer")).resolves.toBeDefined()
  })

  it("uses successful reads as LRU touches", async () => {
    const now = vi.spyOn(Date, "now")
    const cache = new IndexedDbInlineMediaCache({
      accountId: userId(99_002),
      maxBytes: 6,
    })

    now.mockReturnValue(1_000)
    await cache.put("first", new Blob(["12"]))
    now.mockReturnValue(2_000)
    await cache.put("second", new Blob(["34"]))
    now.mockReturnValue(3_000)
    await expect(cache.get("first")).resolves.toBeDefined()
    now.mockReturnValue(4_000)
    await cache.put("third", new Blob(["5678"]))

    await expect(cache.get("first")).resolves.toBeDefined()
    await expect(cache.get("second")).resolves.toBeUndefined()
    await expect(cache.get("third")).resolves.toBeDefined()
  })

  it("does not evict existing media for an entry larger than the cache", async () => {
    const cache = new IndexedDbInlineMediaCache({
      accountId: userId(99_003),
      maxBytes: 4,
    })

    await cache.put("existing", new Blob(["1234"]))
    await cache.put("oversized", new Blob(["12345"]))

    await expect(cache.get("existing")).resolves.toBeDefined()
    await expect(cache.get("oversized")).resolves.toBeUndefined()
  })

  it("keeps concurrent completed downloads inside the byte budget", async () => {
    const cache = new IndexedDbInlineMediaCache({
      accountId: userId(99_004),
      maxBytes: 6,
    })

    await Promise.all([
      cache.put("first", new Blob(["1234"])),
      cache.put("second", new Blob(["5678"])),
    ])

    const stored = await Promise.all([
      cache.get("first"),
      cache.get("second"),
    ])
    expect(stored.filter(Boolean)).toHaveLength(1)
  })
})
