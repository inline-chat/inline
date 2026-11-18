/**
 * Emoji usage on this device: frecency (search ranking and the pickers'
 * Frequently Used), reaction pick counts (the quick reaction row) and the
 * preferred skin tone. Ports of the Mac's `EmojiUsageStore`
 * (`apple/InlineUI/Sources/EmojiAutocomplete/EmojiUsageStore.swift`),
 * `ReactionPickerEmojiUsageStore` (`ReactionPickerEmojis.swift` lines
 * 153-218) and `EmojiSkinTonePreferenceStore` (`EmojiPickerData.swift`
 * lines 72-86), over a key-value interface the app provides.
 *
 * Data-free and small: it does not import the emoji table.
 */

import { signal, type ReadSignal } from "@inline/reactive"
import { isSkinTone, usageKey, type SkinTone } from "./tone"
import type { UsageScores } from "./engine"

/** Where usage lives. The app decides (see README); values are JSON or plain strings. */
export type KeyValueStore = {
  get(key: string): string | null
  set(key: string, value: string): void
  remove(key: string): void
}

/** An in-memory store, for tests and when storage is unavailable. */
export const memoryKeyValueStore = (initial: Record<string, string> = {}): KeyValueStore & { readonly data: Map<string, string> } => {
  const data = new Map(Object.entries(initial))
  return {
    data,
    get: (key) => data.get(key) ?? null,
    set: (key, value) => void data.set(key, value),
    remove: (key) => void data.delete(key),
  }
}

/**
 * `localStorage`, guarded: a private window, a full quota or a blocked
 * storage reads as empty and drops writes, so emoji never break the app.
 */
export const localStorageKeyValueStore = (storage: () => Storage | undefined = () => globalThis.localStorage): KeyValueStore => ({
  get: (key) => {
    try {
      return storage()?.getItem(key) ?? null
    } catch {
      return null
    }
  },
  set: (key, value) => {
    try {
      storage()?.setItem(key, value)
    } catch {
      // Quota or access: usage is a convenience.
    }
  },
  remove: (key) => {
    try {
      storage()?.removeItem(key)
    } catch {
      // As above.
    }
  },
})

/** The Mac's keys, so the meaning of each value matches its store there. */
export const USAGE_KEYS = {
  frecency: "chat.inline.emojiUsage.v1",
  reactionCounts: "chat.inline.reactionPicker.emojiUsageCounts.v1",
  skinTone: "chat.inline.preferredEmojiSkinTone.v1",
} as const

/** Most frecency entries kept (`maxEntries`). */
export const MAX_USAGE_ENTRIES = 160
/** Days for a use to count half (`halfLifeDays`). */
export const USAGE_HALF_LIFE_DAYS = 10

const DAY_SECONDS = 86_400

type Entry = { readonly count: number; readonly lastUsed: number }

/** Count decayed by age, so a burst last month yields to steady use this week (`Entry.score`). */
export const frecencyScore = (entry: Entry, nowSeconds: number): number => {
  const ageDays = Math.max(0, nowSeconds - entry.lastUsed) / DAY_SECONDS
  return entry.count * 0.5 ** (ageDays / USAGE_HALF_LIFE_DAYS) + Math.min(entry.count, 20) * 0.05
}

/** First grapheme of the trimmed value (`ReactionPickerEmojis.normalizedEmoji`). */
export const normalizedEmoji = (value: string | null | undefined): string | undefined => {
  const trimmed = value?.trim()
  if (!trimmed) return undefined
  segmenter ??= new Intl.Segmenter(undefined, { granularity: "grapheme" })
  for (const { segment } of segmenter.segment(trimmed)) return segment
  return undefined
}

let segmenter: Intl.Segmenter | undefined

/** Compare by Unicode code point (Swift's `String <` for emoji). */
export const compareCodePoints = (a: string, b: string): number => {
  const left = a[Symbol.iterator]()
  const right = b[Symbol.iterator]()
  for (;;) {
    const l = left.next()
    const r = right.next()
    if (l.done) return r.done ? 0 : -1
    if (r.done) return 1
    const lc = l.value.codePointAt(0) ?? 0
    const rc = r.value.codePointAt(0) ?? 0
    if (lc !== rc) return lc < rc ? -1 : 1
  }
}

export type EmojiUsageOptions = {
  readonly store: KeyValueStore
  /** Milliseconds since the epoch. Default `Date.now`. */
  readonly now?: () => number
}

/**
 * One per app (usage is per device, as on the Mac). `revision` changes on
 * every write, so a picker that wants live data can read it in a computed;
 * the pickers instead read once when they open, so nothing reshuffles under
 * the pointer.
 */
export class EmojiUsage {
  readonly #store: KeyValueStore
  readonly #now: () => number
  readonly #revision = signal(0)
  readonly #skinTone = signal<SkinTone>("standard")

  /** Bumped on every write. */
  readonly revision: ReadSignal<number> = this.#revision
  /** The preferred skin tone. */
  readonly skinTone: ReadSignal<SkinTone> = this.#skinTone

  constructor(options: EmojiUsageOptions) {
    this.#store = options.store
    this.#now = options.now ?? (() => Date.now())
    const tone = this.#store.get(USAGE_KEYS.skinTone)
    this.#skinTone.set(isSkinTone(tone) ? tone : "standard")
  }

  // Frecency -----------------------------------------------------------------

  /** Count one use (`EmojiUsageStore.record`). Insert from a picker or autocomplete, or a reaction. */
  record(emoji: string, atMs: number = this.#now()): void {
    const key = usageKey(emoji.trim())
    if (key === "") return
    const now = atMs / 1000
    const entries = this.#loadFrecency()
    const previous = entries.get(key)
    entries.set(key, { count: (previous?.count ?? 0) + 1, lastUsed: now })
    let kept = entries
    if (entries.size > MAX_USAGE_ENTRIES) {
      kept = new Map(
        [...entries].sort((a, b) => frecencyScore(b[1], now) - frecencyScore(a[1], now)).slice(0, MAX_USAGE_ENTRIES),
      )
    }
    this.#saveFrecency(kept)
  }

  /** Scores by usage key for search ranking, at one moment (`EmojiUsageStore.snapshot`). */
  scores(atMs: number = this.#now()): UsageScores {
    const now = atMs / 1000
    const map = new Map<string, number>()
    for (const [key, entry] of this.#loadFrecency()) map.set(key, frecencyScore(entry, now))
    return { score: (key) => map.get(key) ?? 0 }
  }

  /**
   * Most-used first, ties by emoji (`EmojiUsageStore.frequentlyUsed`). Keys
   * have no tone or VS16; `resolve` maps one to the dataset's emoji
   * (`engine.lookup(key)?.emoji`), as the Mac does.
   */
  frequentlyUsed(limit: number, resolve?: (key: string) => string | undefined, atMs: number = this.#now()): string[] {
    if (limit <= 0) return []
    const now = atMs / 1000
    return [...this.#loadFrecency()]
      .map(([key, entry]) => ({ key, score: frecencyScore(entry, now) }))
      .sort((a, b) => (a.score !== b.score ? b.score - a.score : compareCodePoints(a.key, b.key)))
      .slice(0, limit)
      .map(({ key }) => resolve?.(key) ?? key)
  }

  /** Forget an emoji (`EmojiUsageStore.remove`). */
  remove(emoji: string): void {
    const entries = this.#loadFrecency()
    entries.delete(usageKey(emoji))
    this.#saveFrecency(entries)
  }

  #loadFrecency(): Map<string, Entry> {
    const out = new Map<string, Entry>()
    const raw = this.#readJson(USAGE_KEYS.frecency)
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return out
    for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
      if (!Array.isArray(value) || value.length !== 2) continue
      const [count, lastUsed] = value as unknown[]
      if (typeof count !== "number" || typeof lastUsed !== "number" || !(count > 0) || !Number.isFinite(lastUsed)) continue
      out.set(key, { count, lastUsed })
    }
    return out
  }

  #saveFrecency(entries: Map<string, Entry>): void {
    const json: Record<string, [number, number]> = {}
    for (const [key, entry] of entries) json[key] = [entry.count, entry.lastUsed]
    this.#store.set(USAGE_KEYS.frecency, JSON.stringify(json))
    this.#bump()
  }

  // Reaction picks -----------------------------------------------------------

  /** Picks per emoji as shown (tone kept), positive only (`ReactionPickerEmojiUsageStore.usageCounts`). */
  reactionCounts(): Map<string, number> {
    const out = new Map<string, number>()
    const raw = this.#readJson(USAGE_KEYS.reactionCounts)
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return out
    for (const [emoji, value] of Object.entries(raw as Record<string, unknown>)) {
      const count = typeof value === "number" ? Math.trunc(value) : undefined
      const normalized = normalizedEmoji(emoji)
      if (count === undefined || !(count > 0) || !normalized) continue
      out.set(normalized, (out.get(normalized) ?? 0) + count)
    }
    return out
  }

  /** A reaction was added from a picker (`recordPick`): counts it and feeds frecency. */
  recordReaction(emoji: string): void {
    const normalized = normalizedEmoji(emoji)
    if (!normalized) return
    const counts = this.reactionCounts()
    counts.set(normalized, (counts.get(normalized) ?? 0) + 1)
    this.#saveCounts(counts)
    this.record(normalized)
  }

  /** "Remove from suggestions" (`removeSuggestion`): drops the count, keeps frecency. */
  removeReactionSuggestion(emoji: string): void {
    const normalized = normalizedEmoji(emoji)
    if (!normalized) return
    const counts = this.reactionCounts()
    counts.delete(normalized)
    this.#saveCounts(counts)
  }

  #saveCounts(counts: Map<string, number>): void {
    const json: Record<string, number> = {}
    for (const [emoji, count] of counts) if (count > 0) json[emoji] = count
    this.#store.set(USAGE_KEYS.reactionCounts, JSON.stringify(json))
    this.#bump()
  }

  // Skin tone ----------------------------------------------------------------

  setSkinTone(tone: SkinTone): void {
    if (tone === this.#skinTone.peek()) return
    this.#store.set(USAGE_KEYS.skinTone, tone)
    this.#skinTone.set(tone)
    this.#bump()
  }

  // ---------------------------------------------------------------------------

  #readJson(key: string): unknown {
    const raw = this.#store.get(key)
    if (raw === null) return undefined
    try {
      return JSON.parse(raw) as unknown
    } catch {
      return undefined
    }
  }

  #bump(): void {
    this.#revision.set(this.#revision.peek() + 1)
  }
}
