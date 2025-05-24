import { UserSettingsModel } from "@in/server/db/models/userSettings"
import type { UserSettingsGeneral } from "@in/server/db/models/userSettings/types"
import { Log } from "@in/server/utils/log"

const log = new Log("UserSettingsCache")

export type CachedUserSettings = {
  general: UserSettingsGeneral | null
  cacheDate: number
  lastAccessed: number
  isRefreshing?: boolean
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
  private readonly maxSize = 10000 // Maximum cache entries
  private readonly cacheValidTime = 60 * 60 * 1000 // 1 hour
  private readonly staleTime = 90 * 60 * 1000 // 1.5 hours (serve stale data up to this point)

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

      // Stale but within acceptable range - return stale data and refresh in background
      if (cached.cacheDate + this.staleTime > now && !cached.isRefreshing) {
        this.stats.hits++
        this.refreshInBackground(userId, cached)
        return cached.general
      }
    }

    // Cache miss or data too stale - fetch fresh data
    this.stats.misses++
    return this.fetchAndCache(userId)
  }

  private async refreshInBackground(userId: number, cached: CachedUserSettings): Promise<void> {
    if (cached.isRefreshing) return

    cached.isRefreshing = true

    try {
      const general = await UserSettingsModel.getGeneral(userId)

      const newCached: CachedUserSettings = {
        general,
        cacheDate: Date.now(),
        lastAccessed: cached.lastAccessed,
      }

      this.cache.set(userId, newCached)
      log.debug("Background refresh completed", { userId })
    } catch (error) {
      this.stats.errors++
      log.error("Background refresh failed", { userId, error })
      // Remove isRefreshing flag on error
      cached.isRefreshing = false
    }
  }

  private async fetchAndCache(userId: number): Promise<UserSettingsGeneral | null> {
    try {
      const general = await UserSettingsModel.getGeneral(userId)

      const cached: CachedUserSettings = {
        general,
        cacheDate: Date.now(),
        lastAccessed: Date.now(),
      }

      this.set(userId, cached)
      return general
    } catch (error) {
      this.stats.errors++
      log.error("Failed to fetch user settings", { userId, error })

      // Return stale data if available, even if very old
      const stale = this.cache.get(userId)
      if (stale) {
        log.warn("Returning stale user settings due to fetch error", { userId })
        return stale.general
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

  private evictOldest(): void {
    let oldestKey: number | undefined
    let oldestTime = Date.now()

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
    const deleted = this.cache.delete(userId)
    if (deleted) {
      this.stats.size = this.cache.size
      log.debug("Invalidated user settings cache", { userId })
    }
  }

  clear(): void {
    const size = this.cache.size
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
    const maxAge = this.staleTime * 2 // Remove entries older than 2x stale time
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

// Periodic cleanup (run every 10 minutes)
setInterval(() => {
  userSettingsCache.cleanup()
}, 10 * 60 * 1000)
