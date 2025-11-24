const TTL_MS = 10 * 60 * 1000 // 10 minutes

// Note: we only cache positives so cache can't block new access; flip this if we ever need negative caching.
const MAX_ENTRIES = 10_000

type CacheEntry = { value: true; expiresAt: number }

const cache = new Map<string, CacheEntry>()

const makeKey = (scope: string, a: number, b: number) => `${scope}:${a}:${b}`

const isExpired = (entry: CacheEntry, now: number) => entry.expiresAt <= now

function get(key: string): boolean | undefined {
  const now = Date.now()
  const entry = cache.get(key)
  if (!entry) return undefined
  if (isExpired(entry, now)) {
    cache.delete(key)
    return undefined
  }
  return entry.value
}

function ensureCapacity() {
  if (cache.size >= MAX_ENTRIES) {
    cache.clear()
  }
}

function setPositive(key: string) {
  ensureCapacity()
  cache.set(key, { value: true, expiresAt: Date.now() + TTL_MS })
}

function resetByPrefix(prefix: string) {
  for (const key of cache.keys()) {
    if (key.startsWith(prefix)) {
      cache.delete(key)
    }
  }
}

export const AccessGuardsCache = {
  getSpaceMember(spaceId: number, userId: number) {
    return get(makeKey("spaceMember", spaceId, userId))
  },
  setSpaceMember(spaceId: number, userId: number) {
    setPositive(makeKey("spaceMember", spaceId, userId))
  },
  resetSpaceMember(spaceId: number, userId?: number) {
    if (userId !== undefined) {
      cache.delete(makeKey("spaceMember", spaceId, userId))
      return
    }
    resetByPrefix(`spaceMember:${spaceId}:`)
  },

  getChatParticipant(chatId: number, userId: number) {
    return get(makeKey("chatParticipant", chatId, userId))
  },
  setChatParticipant(chatId: number, userId: number) {
    setPositive(makeKey("chatParticipant", chatId, userId))
  },
  resetChatParticipant(chatId: number, userId?: number) {
    if (userId !== undefined) {
      cache.delete(makeKey("chatParticipant", chatId, userId))
      return
    }
    resetByPrefix(`chatParticipant:${chatId}:`)
  },

  resetForUser(userId: number) {
    for (const key of cache.keys()) {
      if (key.endsWith(`:${userId}`)) {
        cache.delete(key)
      }
    }
  },

  resetAll() {
    cache.clear()
  },
}
