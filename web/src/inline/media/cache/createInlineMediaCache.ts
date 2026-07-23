import { IndexedDbInlineMediaCache } from "./IndexedDbInlineMediaCache"
import type { InlineMediaCache, InlineMediaCacheOptions } from "./InlineMediaCache"
import { OpfsInlineMediaCache } from "./OpfsInlineMediaCache"

class FallbackInlineMediaCache implements InlineMediaCache {
  private primaryAvailable = true

  constructor(
    private readonly primary: InlineMediaCache,
    private readonly fallback: InlineMediaCache,
  ) {}

  async get(key: string) {
    if (this.primaryAvailable) {
      try {
        const value = await this.primary.get(key)
        if (value) return value
      } catch {
        this.primaryAvailable = false
      }
    }
    return await this.fallback.get(key)
  }

  async put(key: string, blob: Blob) {
    if (this.primaryAvailable) {
      try {
        await this.primary.put(key, blob)
        return
      } catch {
        this.primaryAvailable = false
      }
    }
    await this.fallback.put(key, blob)
  }
}

const supportsOpfs = () =>
  typeof navigator !== "undefined" &&
  "storage" in navigator &&
  typeof (navigator.storage as StorageManager & { getDirectory?: unknown }).getDirectory === "function"

export const createInlineMediaCache = (options: InlineMediaCacheOptions): InlineMediaCache => {
  const indexedDb = new IndexedDbInlineMediaCache(options)
  return supportsOpfs()
    ? new FallbackInlineMediaCache(new OpfsInlineMediaCache(options), indexedDb)
    : indexedDb
}
