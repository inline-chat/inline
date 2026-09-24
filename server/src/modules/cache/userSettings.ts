import { UserSettingsModel } from "@in/server/db/models/userSettings"
import type { UserSettingsGeneral } from "@in/server/db/models/userSettings/types"
import { Log } from "@in/server/utils/log"

const log = new Log("UserSettingsCache")

export type CachedUserSettings = {
  general: UserSettingsGeneral | null
  cacheDate: number
  lastAccessed: number
}

export type CacheStats = {
  hits: number
  misses: number
  errors: number
  evictions: number
  size: number
}

class UserSettingsCache {
  private cache = new Map<number, CachedUserSettings>()
  private inflight = new Map<number, Promise<UserSettingsGeneral | null>>()
  // A fill may outlive an invalidation. Per-user generations prevent an
  // unrelated user's invalidation from discarding this user's refresh, while
  // the clear generation still fences every in-flight fill after clear().
  private clearEpoch = 0
  private userEpochs = new Map<number, number>()
  private readonly maxSize = 10000 // Maximum cache entries
  // Invalidations also fence in-flight fills. Bound their metadata separately
  // from cached values because a long-running process can invalidate many more
  // distinct users than it keeps in the cache.
  private readonly maxUserEpochs = this.maxSize * 2
  private readonly cacheValidTime = 30 * 1000

  private stats: CacheStats = {
    hits: 0,
    misses: 0,
    errors: 0,
    evictions: 0,
    size: 0,
  }

  async get(userId: number): Promise<UserSettingsGeneral | null> {
    const cached = this.cache.get(userId)
    const now = Date.now()

    if (cached) {
      cached.lastAccessed = now

      // Fresh data - return immediately
      if (cached.cacheDate + this.cacheValidTime > now) {
        this.stats.hits++
        return cached.general
      }

    }

    // Cache miss or expired entry: wait for a fresh database result.
    this.stats.misses++
    const existing = this.inflight.get(userId)
    if (existing) return existing
    const promise = this.fetchAndCache(userId)
    this.inflight.set(userId, promise)
    try { return await promise } finally {
      if (this.inflight.get(userId) === promise) this.inflight.delete(userId)
    }
  }

  private async fetchAndCache(userId: number, attempts = 0): Promise<UserSettingsGeneral | null> {
    const generation = this.generationFor(userId)

    try {
      const general = await UserSettingsModel.getGeneral(userId)

      const cached: CachedUserSettings = {
        general,
        cacheDate: Date.now(),
        lastAccessed: Date.now(),
      }

      if (this.isCurrentGeneration(userId, generation)) {
        this.set(userId, cached)
      } else {
        log.debug("Dropped stale settings fetch", { userId })
        if (attempts < 2) return this.fetchAndCache(userId, attempts + 1)
        throw new Error("Settings changed repeatedly during cache fill")
      }
      return general
    } catch (error) {
      this.stats.errors++
      log.error("Failed to fetch user settings", { userId, error })

      // An invalidated older fill can fail after a newer fill has installed a
      // current value. Return only that still-fresh value; expired settings
      // still reject, so this is not a stale-on-error grace period.
      const current = this.cache.get(userId)
      if (current && current.cacheDate + this.cacheValidTime > Date.now()) {
        return current.general
      }
      throw error
    }
  }

  private set(userId: number, cached: CachedUserSettings): void {
    // Evict oldest entries if cache is full
    if (this.cache.size >= this.maxSize && !this.cache.has(userId)) {
      this.evictOldest()
    }

    this.cache.set(userId, cached)
    this.stats.size = this.cache.size
  }

  private generationFor(userId: number): readonly [number, number] {
    return [this.clearEpoch, this.userEpochs.get(userId) ?? 0]
  }

  private isCurrentGeneration(userId: number, generation: readonly [number, number]): boolean {
    return generation[0] === this.clearEpoch && generation[1] === (this.userEpochs.get(userId) ?? 0)
  }

  private evictOldest(): void {
    let oldestKey: number | undefined
    // All entries can be written in the same millisecond. Infinity guarantees
    // the first entry is eligible, preserving the capacity bound on ties.
    let oldestTime = Infinity

    for (const [key, value] of this.cache.entries()) {
      if (value.lastAccessed < oldestTime) {
        oldestTime = value.lastAccessed
        oldestKey = key
      }
    }

    if (oldestKey !== undefined) {
      this.cache.delete(oldestKey)
      this.stats.evictions++
      log.debug("Evicted oldest cache entry", { userId: oldestKey })
    }
  }

  invalidate(userId: number): void {
    this.userEpochs.set(userId, (this.userEpochs.get(userId) ?? 0) + 1)
    this.inflight.delete(userId)
    const deleted = this.cache.delete(userId)
    if (deleted) {
      this.stats.size = this.cache.size
      log.debug("Invalidated user settings cache", { userId })
    }

    // Do not drop individual epochs: an old fill could then look current.
    // A whole-cache epoch fence preserves that safety property while bounding
    // metadata for workloads that invalidate a large number of distinct users.
    if (this.userEpochs.size > this.maxUserEpochs) {
      const size = this.cache.size
      this.clearEpoch += 1
      this.userEpochs.clear()
      this.inflight.clear()
      this.cache.clear()
      this.stats.size = 0
      log.debug("Cleared user settings cache after invalidation metadata limit", { previousSize: size })
    }
  }

  clear(): void {
    const size = this.cache.size
    this.clearEpoch += 1
    this.userEpochs.clear()
    this.inflight.clear()
    this.cache.clear()
    this.stats.size = 0
    log.debug("Cleared user settings cache", { previousSize: size })
  }

  getStats(): CacheStats {
    return {
      ...this.stats,
      size: this.cache.size,
    }
  }

  // Cleanup old entries periodically
  cleanup(): void {
    const now = Date.now()
    const maxAge = this.cacheValidTime * 2
    let cleaned = 0

    for (const [key, value] of this.cache.entries()) {
      if (value.lastAccessed + maxAge < now) {
        this.cache.delete(key)
        cleaned++
      }
    }

    if (cleaned > 0) {
      this.stats.size = this.cache.size
      log.debug("Cleaned up old cache entries", { cleaned, remainingSize: this.cache.size })
    }
  }
}

// Singleton instance
const userSettingsCache = new UserSettingsCache()

// Public API (maintaining backward compatibility)
export async function getCachedUserSettings(userId: number): Promise<UserSettingsGeneral | null> {
  return userSettingsCache.get(userId)
}

export function invalidateUserSettingsCache(userId: number): void {
  userSettingsCache.invalidate(userId)
}

export function clearUserSettingsCache(): void {
  userSettingsCache.clear()
}

export function getUserSettingsCacheStats(): CacheStats {
  return userSettingsCache.getStats()
}

export function cleanupUserSettingsCache(): void {
  userSettingsCache.cleanup()
}

const CLEANUP_INTERVAL_MS = 10 * 60 * 1000
let cleanupIntervalId: ReturnType<typeof setInterval> | null = null

export function startUserSettingsCacheCleanup(): void {
  if (cleanupIntervalId) {
    return
  }

  cleanupIntervalId = setInterval(() => {
    userSettingsCache.cleanup()
  }, CLEANUP_INTERVAL_MS)
}

export function stopUserSettingsCacheCleanup(): void {
  if (!cleanupIntervalId) {
    return
  }

  clearInterval(cleanupIntervalId)
  cleanupIntervalId = null
}
