/**
 * Usage history and ranking for Quick Search.
 *
 * A port of the Mac app's `InlineSearchUsageHistory` (InlineKit/Sources/
 * InlineSearch/InlineSearchUsageHistory.swift) and the ranking rules of
 * `InlineSearchChatCatalog.swift`:
 *
 * - Every chat the user switches to is recorded (`recordSwitch`); its
 *   frecency, `log2(count + 1)` halved every 45 days, ranks the empty-query
 *   suggestions and breaks ties in search.
 * - Every pick from a search is recorded for the normalized query and for
 *   each of its compact prefixes of 2 to 8 letters (`recordSelection`), so
 *   typing "al" after picking Alice for "alice" ranks Alice first. That
 *   affinity halves every 30 days.
 * - Records older than 180 days are dropped; at most 500 items, 256 query
 *   keys and 12 items per key are kept.
 *
 * Persistence is injected. One store holds one account: key the persistence
 * by account, as the workspace store is keyed.
 */

import { signal, type Clock, type ReadSignal } from "@inline/reactive"
import { compareMatches, prepareQuery, type Match } from "./match"

const DAY_MS = 86_400_000

/** The Mac's constants. */
export const usageLimits = {
  switchHalfLifeDays: 45,
  queryHalfLifeDays: 30,
  retentionDays: 180,
  maxItems: 500,
  maxQueryKeys: 256,
  maxItemsPerQuery: 12,
  maxPrefixLength: 8,
  maxSwitchCount: 100_000,
  maxSelectionCount: 10_000,
  /** `QuickSearchUsageStore.scheduleSave`. */
  saveDelayMs: 350,
} as const

export type UsageRecord = {
  /** Count. */
  readonly c: number
  /** Last use, milliseconds since the epoch. */
  readonly t: number
}

export type UsageSnapshot = {
  readonly v: 1
  /** Switch records by usage key (`user:<id>`, `chat:<id>`). */
  readonly items: Readonly<Record<string, UsageRecord>>
  /** Selection records by hashed query key, then usage key. */
  readonly queries: Readonly<Record<string, Readonly<Record<string, UsageRecord>>>>
}

export interface UsagePersistence {
  /** The saved snapshot, or anything unreadable (treated as empty). */
  load(): unknown
  save(snapshot: UsageSnapshot): void
}

export type UsageSignal = {
  /** Decayed switch frequency. */
  readonly switchFrecency: number
  /** Decayed selections for this query and its prefixes. */
  readonly queryAffinity: number
  /** Last switch, milliseconds since the epoch. */
  readonly lastUsedAt?: number
}

export const noUsage: UsageSignal = Object.freeze({ switchFrecency: 0, queryAffinity: 0 })

/** In-memory persistence, for tests and windows without storage. */
export const memoryUsagePersistence = (initial?: unknown): UsagePersistence & { readonly saved: UsageSnapshot[] } => {
  let value = initial
  const saved: UsageSnapshot[] = []
  return {
    saved,
    load: () => value,
    save: (snapshot) => {
      value = JSON.parse(JSON.stringify(snapshot)) as unknown
      saved.push(snapshot)
    },
  }
}

type StorageLike = Pick<Storage, "getItem" | "setItem">

/** `localStorage` persistence under one key. Storage errors are swallowed: usage is a hint. */
export const storageUsagePersistence = (storage: StorageLike, key: string): UsagePersistence => ({
  load: () => {
    try {
      const raw = storage.getItem(key)
      return raw === null ? undefined : (JSON.parse(raw) as unknown)
    } catch {
      return undefined
    }
  },
  save: (snapshot) => {
    try {
      storage.setItem(key, JSON.stringify(snapshot))
    } catch {
      // Quota or a blocked storage: keep the in-memory history.
    }
  },
})

/**
 * A compact hash for query keys (cyrb53). The Mac stores SHA-256 hashes so
 * the file does not hold search text verbatim; this does the same job of
 * keeping keys short and opaque. It is not a privacy guarantee: prefixes of
 * two to eight letters can be guessed by hashing candidates.
 */
const hashKey = (value: string): string => {
  let h1 = 0xdeadbeef
  let h2 = 0x41c6ce57
  for (let i = 0; i < value.length; i++) {
    const ch = value.charCodeAt(i)
    h1 = Math.imul(h1 ^ ch, 2654435761)
    h2 = Math.imul(h2 ^ ch, 1597334677)
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909)
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909)
  return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(36)
}

/** The keys a query is recorded under: the whole normalized query and compact prefixes of 2 to 8 units. */
export const usageQueryKeys = (query: string): string[] => {
  const prepared = prepareQuery(query)
  if (!prepared) return []
  const raw = [`query:${prepared.normalized}`]
  const max = Math.min(Array.from(prepared.compact).length, usageLimits.maxPrefixLength)
  const letters = Array.from(prepared.compact)
  for (let length = 2; length <= max; length++) raw.push(`compact:${letters.slice(0, length).join("")}`)
  return [...new Set(raw.map(hashKey))].sort()
}

const decayed = (record: UsageRecord, now: number, halfLifeDays: number): number => {
  if (record.c <= 0) return 0
  const ageDays = Math.max(0, (now - record.t) / DAY_MS)
  return Math.log2(record.c + 1) * Math.pow(0.5, ageDays / halfLifeDays)
}

const isRecord = (value: unknown): value is UsageRecord =>
  typeof value === "object" &&
  value !== null &&
  typeof (value as UsageRecord).c === "number" &&
  typeof (value as UsageRecord).t === "number" &&
  Number.isFinite((value as UsageRecord).c) &&
  Number.isFinite((value as UsageRecord).t)

const readRecords = (value: unknown): Map<string, UsageRecord> => {
  const out = new Map<string, UsageRecord>()
  if (typeof value !== "object" || value === null || Array.isArray(value)) return out
  for (const [key, record] of Object.entries(value)) if (isRecord(record)) out.set(key, { c: record.c, t: record.t })
  return out
}

/** Read a saved snapshot; anything unreadable gives an empty history. Never throws. */
export const parseUsageSnapshot = (
  raw: unknown,
): { items: Map<string, UsageRecord>; queries: Map<string, Map<string, UsageRecord>> } => {
  const items = new Map<string, UsageRecord>()
  const queries = new Map<string, Map<string, UsageRecord>>()
  if (typeof raw !== "object" || raw === null || (raw as { v?: unknown }).v !== 1) return { items, queries }
  for (const [key, record] of readRecords((raw as { items?: unknown }).items)) items.set(key, record)
  const rawQueries = (raw as { queries?: unknown }).queries
  if (typeof rawQueries === "object" && rawQueries !== null && !Array.isArray(rawQueries)) {
    for (const [key, records] of Object.entries(rawQueries)) {
      const parsed = readRecords(records)
      if (parsed.size > 0) queries.set(key, parsed)
    }
  }
  return { items, queries }
}

export type UsageStoreOptions = {
  readonly persistence?: UsagePersistence
  /** Wall time in milliseconds since the epoch. Defaults to `Date.now`. */
  readonly now?: () => number
  /** Timers for the debounced save. Without one, every change saves at once. */
  readonly clock?: Pick<Clock, "setTimeout" | "clearTimeout">
  readonly saveDelayMs?: number
}

export class UsageStore {
  readonly #persistence: UsagePersistence | undefined
  readonly #now: () => number
  readonly #clock: Pick<Clock, "setTimeout" | "clearTimeout"> | undefined
  readonly #saveDelayMs: number
  #items = new Map<string, UsageRecord>()
  #queries = new Map<string, Map<string, UsageRecord>>()
  #loaded = false
  #saveTimer: unknown
  readonly #revision = signal(0)

  /** Bumps on every change, so ranking that reads usage re-runs. */
  readonly revision: ReadSignal<number> = this.#revision

  constructor(options: UsageStoreOptions = {}) {
    this.#persistence = options.persistence
    this.#now = options.now ?? Date.now
    this.#clock = options.clock
    this.#saveDelayMs = options.saveDelayMs ?? usageLimits.saveDelayMs
  }

  /** Signals for every item with any usage, for this query (empty query: switch frecency only). */
  signals(query: string, now = this.#now()): ReadonlyMap<string, UsageSignal> {
    this.#load()
    const out = new Map<string, { switchFrecency: number; queryAffinity: number; lastUsedAt?: number }>()
    for (const [key, record] of this.#items) {
      out.set(key, {
        switchFrecency: decayed(record, now, usageLimits.switchHalfLifeDays),
        queryAffinity: 0,
        lastUsedAt: record.t,
      })
    }
    for (const queryKey of usageQueryKeys(query)) {
      const records = this.#queries.get(queryKey)
      if (!records) continue
      for (const [key, record] of records) {
        const current = out.get(key) ?? { switchFrecency: 0, queryAffinity: 0 }
        current.queryAffinity += decayed(record, now, usageLimits.queryHalfLifeDays)
        out.set(key, current)
      }
    }
    return out
  }

  /** The user opened this chat or person, by any route. The app calls it when the visible chat changes. */
  recordSwitch(key: string, now = this.#now()): void {
    this.#load()
    const record = this.#items.get(key)
    this.#items.set(key, { c: Math.min((record?.c ?? 0) + 1, usageLimits.maxSwitchCount), t: now })
    this.#changed(now)
  }

  /** The user picked this item for this query. An empty query records nothing (Mac). */
  recordSelection(key: string, query: string, now = this.#now()): void {
    const queryKeys = usageQueryKeys(query)
    if (queryKeys.length === 0) return
    this.#load()
    for (const queryKey of queryKeys) {
      const records = this.#queries.get(queryKey) ?? new Map<string, UsageRecord>()
      const record = records.get(key)
      records.set(key, { c: Math.min((record?.c ?? 0) + 1, usageLimits.maxSelectionCount), t: now })
      this.#queries.set(queryKey, records)
    }
    this.#changed(now)
  }

  /** Forget everything (sign-out). Saves at once. */
  clear(): void {
    this.#loaded = true
    this.#items = new Map()
    this.#queries = new Map()
    this.#cancelSave()
    this.#persistence?.save(this.snapshot())
    this.#revision.update((n) => n + 1)
  }

  /** Save now if a save is pending. */
  flush(): void {
    if (this.#saveTimer === undefined) return
    this.#cancelSave()
    this.#persistence?.save(this.snapshot())
  }

  snapshot(): UsageSnapshot {
    this.#load()
    const queries: Record<string, Record<string, UsageRecord>> = {}
    for (const [key, records] of this.#queries) queries[key] = Object.fromEntries(records)
    return { v: 1, items: Object.fromEntries(this.#items), queries }
  }

  dispose(): void {
    this.flush()
  }

  #load(): void {
    if (this.#loaded) return
    this.#loaded = true
    let raw: unknown
    try {
      raw = this.#persistence?.load()
    } catch {
      raw = undefined
    }
    const parsed = parseUsageSnapshot(raw)
    this.#items = parsed.items
    this.#queries = parsed.queries
  }

  #changed(now: number): void {
    this.#prune(now)
    this.#revision.update((n) => n + 1)
    this.#scheduleSave()
  }

  #prune(now: number): void {
    const cutoff = now - usageLimits.retentionDays * DAY_MS
    const newestFirst = (a: [string, UsageRecord], b: [string, UsageRecord]) => b[1].t - a[1].t
    this.#items = new Map(
      [...this.#items].filter(([, r]) => r.t >= cutoff).sort(newestFirst).slice(0, usageLimits.maxItems),
    )
    const keys: [string, Map<string, UsageRecord>, number][] = []
    for (const [key, records] of this.#queries) {
      const recent = [...records].filter(([, r]) => r.t >= cutoff).sort(newestFirst).slice(0, usageLimits.maxItemsPerQuery)
      const newest = recent[0]
      if (newest) keys.push([key, new Map(recent), newest[1].t])
    }
    keys.sort((a, b) => b[2] - a[2])
    this.#queries = new Map(keys.slice(0, usageLimits.maxQueryKeys).map(([key, records]) => [key, records]))
  }

  #scheduleSave(): void {
    if (!this.#persistence) return
    if (!this.#clock) {
      this.#persistence.save(this.snapshot())
      return
    }
    this.#cancelSave()
    this.#saveTimer = this.#clock.setTimeout(() => {
      this.#saveTimer = undefined
      this.#persistence?.save(this.snapshot())
    }, this.#saveDelayMs)
  }

  #cancelSave(): void {
    if (this.#saveTimer === undefined) return
    this.#clock?.clearTimeout(this.#saveTimer)
    this.#saveTimer = undefined
  }
}

// ---------------------------------------------------------------------------
// Ranking

/** What ranks a chat-like result beyond its match. */
export type RankInput = {
  readonly match: Match
  readonly usage: UsageSignal
  /** In the space the user is in. */
  readonly currentSpace?: boolean
  readonly pinned?: boolean
  readonly unread?: boolean
  /** Last activity, seconds since the epoch; 0 when unknown. */
  readonly lastActivity?: number
  /** Stable last tiebreak: sidebar order or source order. */
  readonly order: number
}

/**
 * The Mac order for chats (`InlineSearchChatCatalog.searchResultPrecedes`):
 * match tier, then affinity for this query, then switch frecency, then field
 * priority, then the current space, then pinned and unread, then recent
 * activity, then source order. Negative when `a` ranks first.
 */
export const compareRanked = (a: RankInput, b: RankInput): number => {
  if (a.match.tier !== b.match.tier) return b.match.tier - a.match.tier
  if (a.usage.queryAffinity !== b.usage.queryAffinity) return b.usage.queryAffinity - a.usage.queryAffinity
  if (a.usage.switchFrecency !== b.usage.switchFrecency) return b.usage.switchFrecency - a.usage.switchFrecency
  if (a.match.fieldPriority !== b.match.fieldPriority) return b.match.fieldPriority - a.match.fieldPriority
  if ((a.currentSpace ?? false) !== (b.currentSpace ?? false)) return a.currentSpace ? -1 : 1
  const weak = (r: RankInput) => (r.pinned ? 2 : 0) + (r.unread ? 1 : 0)
  if (weak(a) !== weak(b)) return weak(b) - weak(a)
  if ((a.lastActivity ?? 0) !== (b.lastActivity ?? 0)) return (b.lastActivity ?? 0) - (a.lastActivity ?? 0)
  return a.order - b.order
}

/**
 * One number for mixing chats with people who have no chat
 * (`InlineSearchChatCatalog.searchScore` and `knownUserSearchScore`):
 * tier × 100,000 + query affinity × 1,000 (at most 90,000) + frecency × 100
 * (at most 9,000) + field priority. Usage adds at most 99,000, so it never
 * lifts a result over a better match tier, as on the Mac.
 */
export const rankScore = (match: Match, usage: UsageSignal = noUsage): number => {
  return (
    match.tier * 100_000 +
    Math.floor(Math.min(usage.queryAffinity * 1_000, 90_000)) +
    Math.floor(Math.min(usage.switchFrecency * 100, 9_000)) +
    match.fieldPriority
  )
}

/** The empty-query suggestion order (`suggestionPrecedes`): frecency, then last use, then sidebar order. */
export const compareSuggestions = (
  a: { readonly usage: UsageSignal; readonly order: number },
  b: { readonly usage: UsageSignal; readonly order: number },
): number => {
  if (a.usage.switchFrecency !== b.usage.switchFrecency) return b.usage.switchFrecency - a.usage.switchFrecency
  if ((a.usage.lastUsedAt ?? 0) !== (b.usage.lastUsedAt ?? 0)) return (b.usage.lastUsedAt ?? 0) - (a.usage.lastUsedAt ?? 0)
  return a.order - b.order
}

/** Order for results ranked by match alone (people, spaces, commands): `compareMatches`, then source order. */
export const compareByMatch = (
  a: { readonly match: Match; readonly order: number },
  b: { readonly match: Match; readonly order: number },
): number => compareMatches(a.match, b.match) || a.order - b.order
