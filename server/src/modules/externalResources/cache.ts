export interface ExternalResourceCacheOptions {
  readonly maxEntries?: number
  readonly ttlMs?: number
  readonly now?: () => number
}

type CacheEntry<Value> = {
  readonly expiresAt: number
  readonly value: Value
}

/**
 * Small process-local autocomplete cache. Keys must include the authorization
 * scope; callers currently use provider + space + query + limit.
 */
export class ExternalResourceCache<Value> {
  private readonly entries = new Map<string, CacheEntry<Value>>()
  private readonly inFlight = new Map<string, Promise<Value>>()
  private readonly maxEntries: number
  private readonly ttlMs: number
  private readonly now: () => number

  constructor(options: ExternalResourceCacheOptions = {}) {
    this.maxEntries = Math.max(0, options.maxEntries ?? 256)
    this.ttlMs = Math.max(0, options.ttlMs ?? 30_000)
    this.now = options.now ?? Date.now
  }

  async getOrLoad(key: string, load: () => Promise<Value>): Promise<Value> {
    const now = this.now()
    const cached = this.entries.get(key)
    if (cached && cached.expiresAt > now) {
      // Refresh insertion order so the cap behaves as a tiny LRU.
      this.entries.delete(key)
      this.entries.set(key, cached)
      return cached.value
    }
    if (cached) {
      this.entries.delete(key)
    }

    const existingLoad = this.inFlight.get(key)
    if (existingLoad) {
      return existingLoad
    }

    const pending = load()
    this.inFlight.set(key, pending)
    try {
      const value = await pending
      this.store(key, value)
      return value
    } finally {
      if (this.inFlight.get(key) === pending) {
        this.inFlight.delete(key)
      }
    }
  }

  clear(): void {
    this.entries.clear()
    this.inFlight.clear()
  }

  private store(key: string, value: Value): void {
    if (this.maxEntries === 0 || this.ttlMs === 0) {
      return
    }

    const now = this.now()
    for (const [entryKey, entry] of this.entries) {
      if (entry.expiresAt <= now) {
        this.entries.delete(entryKey)
      }
    }

    this.entries.delete(key)
    while (this.entries.size >= this.maxEntries) {
      const oldestKey = this.entries.keys().next().value
      if (oldestKey === undefined) break
      this.entries.delete(oldestKey)
    }
    this.entries.set(key, {
      expiresAt: now + this.ttlMs,
      value,
    })
  }
}
