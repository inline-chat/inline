import { Log } from "@inline/log"
import { decodeRecord, encodeRecord } from "../bytes"
import { DEFAULT_CACHE_BUDGET_BYTES, SWEEP_INTERVAL_MS, SWEEP_MINIMUM_AGE_MS } from "../constants"
import type { ByteStore, ByteWriter } from "../store/byte-store"
import { isValidFileUniqueId, MediaError, systemClock, type MediaClock } from "../types"

/**
 * A cached file: one server file in one variant. The variant is a photo size
 * type (`b`, `c`, `d`, `f`, `s`), `file` for the original, or another short
 * name a caller chooses.
 */
export type CacheKey = { readonly fileUniqueId: string; readonly variant: string }

/** Why an entry may not be evicted. */
export type PinReason = "viewer" | "upload" | "keep"

export type CacheEntry = {
  readonly fileUniqueId: string
  readonly variant: string
  readonly size: number
  readonly complete: boolean
  readonly writtenAt: number
  readonly lastAccess: number
  readonly pinned: boolean
}

export type CacheUsage = {
  readonly bytes: number
  readonly entries: number
  readonly pinnedBytes: number
  readonly budgetBytes: number
}

export type SweepResult = { removed: number; removedBytes: number; failed: number }

/** Saved beside a partial so a resume can send `If-Range` and check the size. */
export type PartialMeta = { totalSize: number; validator?: string }

export interface CacheWriter {
  /** Bytes in the partial: on open, the durable bytes a download resumes from. */
  readonly offset: number
  readonly meta: PartialMeta | undefined
  setMeta(meta: PartialMeta): Promise<void>
  /** Drops what was written; the file changed. */
  restart(): Promise<void>
  write(chunk: Uint8Array): Promise<void>
  checkpoint(): Promise<void>
  /** The download is whole: the partial becomes the entry. */
  commit(): Promise<CacheEntry>
  /** Stops, keeping checkpointed bytes for a resume. */
  release(): Promise<void>
  /** Stops and deletes the partial. */
  discard(): Promise<void>
  /** Reads back what was written (for a whole-file digest). */
  read(offset: number, length: number): Promise<Uint8Array | undefined>
}

type Entry = {
  id: string
  fileUniqueId: string
  variant: string
  size: number
  complete: boolean
  writtenAt: number
  lastAccess: number
  writing: boolean
  pins: Map<PinReason, number>
}

const VARIANT = /^[A-Za-z0-9-]{1,32}$/

export const cacheId = (key: CacheKey): string => {
  if (!isValidFileUniqueId(key.fileUniqueId) || !VARIANT.test(key.variant)) {
    throw new MediaError("invalid_source", "Invalid cache key")
  }
  return `${key.fileUniqueId}~${key.variant}`
}

const parseName = (name: string): { id: string; fileUniqueId: string; variant: string; kind: "body" | "partial" | "meta" } | undefined => {
  const kind = name.endsWith(".partial.json") ? "meta" : name.endsWith(".partial") ? "partial" : "body"
  const id = kind === "meta" ? name.slice(0, -".partial.json".length) : kind === "partial" ? name.slice(0, -".partial".length) : name
  const [fileUniqueId, variant, extra] = id.split("~")
  if (extra !== undefined || !fileUniqueId || !variant || !isValidFileUniqueId(fileUniqueId) || !VARIANT.test(variant)) return undefined
  return { id, fileUniqueId, variant, kind }
}

export type MediaCacheOptions = {
  store: ByteStore
  /** Account media root, ending with `/`. Entries live under `<root>cache/`. */
  root: string
  budgetBytes?: number
  clock?: MediaClock
  log?: Log
}

/**
 * Downloaded media for one account, under a byte budget. Least recently used
 * entries go first; an entry that is pinned (open in a viewer, the local copy
 * of a pending upload, kept by a setting) or being written is never evicted.
 * Recency survives a restart only as the write time.
 */
export class MediaCache {
  readonly cacheRoot: string
  readonly #store: ByteStore
  readonly #stampPath: string
  readonly #clock: MediaClock
  readonly #log: Log
  readonly #entries = new Map<string, Entry>()
  #budget: number
  #tick = 0
  #erased = false

  constructor(options: MediaCacheOptions) {
    if (!options.root.endsWith("/")) throw new TypeError("Media root ends with /")
    this.#store = options.store
    this.cacheRoot = `${options.root}cache/`
    this.#stampPath = `${options.root}sweep-stamp`
    this.#budget = options.budgetBytes ?? DEFAULT_CACHE_BUDGET_BYTES
    this.#clock = options.clock ?? systemClock
    this.#log = options.log ?? new Log("media.cache")
  }

  async open(): Promise<void> {
    for (const item of await this.#store.list(this.cacheRoot)) {
      const parsed = parseName(item.path.slice(this.cacheRoot.length))
      if (!parsed) continue
      if (parsed.kind === "meta") continue
      const existing = this.#entries.get(parsed.id)
      // A body wins over a leftover partial of the same entry.
      if (existing?.complete) continue
      this.#entries.set(parsed.id, {
        id: parsed.id,
        fileUniqueId: parsed.fileUniqueId,
        variant: parsed.variant,
        size: item.size,
        complete: parsed.kind === "body",
        writtenAt: item.modifiedAt,
        lastAccess: item.modifiedAt,
        writing: false,
        pins: existing?.pins ?? new Map(),
      })
    }
  }

  get budgetBytes(): number {
    return this.#budget
  }

  async setBudget(bytes: number): Promise<void> {
    this.#budget = Math.max(0, bytes)
    await this.evictToBudget()
  }

  has(key: CacheKey): boolean {
    return this.#entries.get(cacheId(key))?.complete === true
  }

  entry(key: CacheKey): CacheEntry | undefined {
    const entry = this.#entries.get(cacheId(key))
    return entry ? this.#snapshot(entry) : undefined
  }

  entries(): CacheEntry[] {
    return [...this.#entries.values()].map((entry) => this.#snapshot(entry))
  }

  usage(): CacheUsage {
    let bytes = 0
    let pinnedBytes = 0
    for (const entry of this.#entries.values()) {
      bytes += entry.size
      if (entry.pins.size > 0) pinnedBytes += entry.size
    }
    return { bytes, entries: this.#entries.size, pinnedBytes, budgetBytes: this.#budget }
  }

  /** The cached file, marking it used. */
  async read(key: CacheKey): Promise<Blob | undefined> {
    const entry = this.#entries.get(cacheId(key))
    if (!entry?.complete) return undefined
    const blob = await this.#store.blob(this.#path(entry.id))
    if (!blob) {
      this.#entries.delete(entry.id)
      return undefined
    }
    entry.lastAccess = this.#nextAccess()
    return blob
  }

  /** Stores a whole file at once (a local preview, a file the user just sent). */
  async put(key: CacheKey, data: Blob | Uint8Array): Promise<CacheEntry> {
    this.#requireOpen()
    const id = cacheId(key)
    await this.#store.write(this.#path(id), data)
    const size = data instanceof Uint8Array ? data.length : data.size
    const entry = this.#upsert(id, key, size, true)
    entry.lastAccess = this.#nextAccess()
    await this.evictToBudget()
    return this.#snapshot(entry)
  }

  /** Keeps an entry from eviction until the returned function is called. Pinning a missing entry pins it once it exists. */
  pin(key: CacheKey, reason: PinReason): () => void {
    const id = cacheId(key)
    let entry = this.#entries.get(id)
    if (!entry) {
      entry = { id, fileUniqueId: key.fileUniqueId, variant: key.variant, size: 0, complete: false, writtenAt: 0, lastAccess: 0, writing: false, pins: new Map() }
      this.#entries.set(id, entry)
    }
    const pinned = entry
    pinned.pins.set(reason, (pinned.pins.get(reason) ?? 0) + 1)
    let released = false
    return () => {
      if (released) return
      released = true
      const count = (pinned.pins.get(reason) ?? 1) - 1
      if (count > 0) pinned.pins.set(reason, count)
      else pinned.pins.delete(reason)
      if (pinned.pins.size === 0 && pinned.size === 0 && !pinned.complete && !pinned.writing) this.#entries.delete(id)
      void this.evictToBudget()
    }
  }

  async remove(key: CacheKey): Promise<void> {
    const id = cacheId(key)
    await this.#removeEntry(id)
  }

  /** Opens a resumable writer. One writer per entry at a time. */
  async beginWrite(key: CacheKey): Promise<CacheWriter> {
    this.#requireOpen()
    const id = cacheId(key)
    const existing = this.#entries.get(id)
    if (existing?.writing) throw new MediaError("protocol", "This entry is already being written")
    const partialPath = `${this.cacheRoot}${id}.partial`
    const metaPath = `${partialPath}.json`
    let meta: PartialMeta | undefined
    const metaBytes = await this.#store.read(metaPath)
    if (metaBytes) {
      try {
        meta = decodeRecord<PartialMeta>(new TextDecoder().decode(metaBytes))
      } catch {
        meta = undefined
      }
    }
    // Without a readable meta the partial cannot be trusted to be the same file.
    let writer: ByteWriter = await this.#store.openWriter(partialPath, meta ? {} : { truncateTo: 0 })
    if (meta && writer.size > meta.totalSize) {
      await writer.abort()
      writer = await this.#store.openWriter(partialPath, { truncateTo: 0 })
      meta = undefined
    }
    const entry = this.#upsert(id, key, writer.size, false)
    entry.writing = true
    const finish = () => {
      entry.writing = false
    }
    return {
      get offset() {
        return writer.size
      },
      get meta() {
        return meta
      },
      setMeta: async (next) => {
        meta = next
        await this.#store.write(metaPath, new TextEncoder().encode(encodeRecord(next)))
      },
      restart: async () => {
        await writer.abort()
        writer = await this.#store.openWriter(partialPath, { truncateTo: 0 })
        meta = undefined
        await this.#store.remove(metaPath)
        entry.size = 0
      },
      write: async (chunk) => {
        await writer.write(chunk)
        entry.size = writer.size
      },
      checkpoint: async () => {
        await writer.checkpoint()
      },
      commit: async () => {
        await writer.close()
        finish()
        const path = this.#path(id)
        await this.#store.rename(partialPath, path)
        await this.#store.remove(metaPath)
        const stat = await this.#store.stat(path)
        entry.complete = true
        entry.size = stat?.size ?? entry.size
        entry.writtenAt = this.#clock.now()
        entry.lastAccess = this.#nextAccess()
        await this.evictToBudget()
        return this.#snapshot(entry)
      },
      release: async () => {
        await writer.close().catch(() => writer.abort())
        finish()
        entry.size = (await this.#store.stat(partialPath))?.size ?? 0
        await this.evictToBudget()
      },
      discard: async () => {
        await writer.abort()
        finish()
        await this.#store.remove(partialPath)
        await this.#store.remove(metaPath)
        if (!entry.complete) {
          entry.size = 0
          if (entry.pins.size === 0) this.#entries.delete(id)
        }
      },
      read: (at, length) => {
        return this.#store.read(partialPath, at, length)
      },
    }
  }

  /** Removes least recently used entries until the cache fits its budget. Returns bytes removed. */
  async evictToBudget(): Promise<number> {
    let total = 0
    for (const entry of this.#entries.values()) total += entry.size
    if (total <= this.#budget) return 0
    const candidates = [...this.#entries.values()]
      .filter((entry) => entry.pins.size === 0 && !entry.writing)
      .sort((left, right) => left.lastAccess - right.lastAccess)
    let removed = 0
    for (const entry of candidates) {
      if (total <= this.#budget) break
      total -= entry.size
      removed += entry.size
      await this.#removeEntry(entry.id)
    }
    return removed
  }

  /**
   * Removes files nothing refers to any more, as `MediaCacheSweep` does: at
   * most once a day; only files unchanged for a week; references are read
   * after listing, so one added meanwhile is still seen; if references cannot
   * be read, nothing is removed. With `keepMediaDays`, entries older than that
   * go too (Keep Media), except pinned ones. Stale partials that no download
   * is writing are removed as well.
   */
  async sweep(options: {
    referenced: () => Promise<ReadonlySet<string>>
    keepMediaDays?: number
    force?: boolean
  }): Promise<SweepResult | undefined> {
    this.#requireOpen()
    const now = this.#clock.now()
    const stamp = await this.#store.read(this.#stampPath)
    const last = stamp ? Number(new TextDecoder().decode(stamp)) : Number.NaN
    if (!options.force && Number.isFinite(last) && last <= now && now - last < SWEEP_INTERVAL_MS) return undefined
    const old = (entry: Entry) => entry.pins.size === 0 && !entry.writing && now - entry.writtenAt >= SWEEP_MINIMUM_AGE_MS
    const candidates = [...this.#entries.values()].filter(old).map((entry) => entry.id)
    let result: SweepResult | undefined
    try {
      const referenced = await options.referenced()
      result = { removed: 0, removedBytes: 0, failed: 0 }
      const keepMs = options.keepMediaDays && options.keepMediaDays > 0 ? options.keepMediaDays * 24 * 60 * 60 * 1_000 : undefined
      for (const id of candidates) {
        const entry = this.#entries.get(id)
        // Checked again right before removal: something may have just rewritten or pinned it.
        if (!entry || !old(entry)) continue
        const expired = keepMs !== undefined && now - entry.writtenAt >= keepMs
        if (entry.complete && referenced.has(entry.fileUniqueId) && !expired) continue
        const size = entry.size
        try {
          await this.#removeEntry(id)
          result.removed += 1
          result.removedBytes += size
        } catch {
          result.failed += 1
        }
      }
    } catch (error) {
      this.#log.warn("Skipping media sweep: references could not be read", { error: String(error) })
    }
    await this.#store.write(this.#stampPath, new TextEncoder().encode(String(now)))
    return result
  }

  /** Sign-out: every byte of this account's cache. */
  async erase(): Promise<void> {
    this.#erased = true
    this.#entries.clear()
    await this.#store.removePrefix(this.cacheRoot)
    await this.#store.remove(this.#stampPath)
  }

  #requireOpen(): void {
    if (this.#erased) throw new MediaError("closed", "The media cache was erased")
  }

  #path(id: string): string {
    return `${this.cacheRoot}${id}`
  }

  #nextAccess(): number {
    // Strictly increasing within a session, and after every write time from a previous one.
    this.#tick = Math.max(this.#tick + 1, this.#clock.now())
    return this.#tick
  }

  #upsert(id: string, key: CacheKey, size: number, complete: boolean): Entry {
    const now = this.#clock.now()
    let entry = this.#entries.get(id)
    if (!entry) {
      entry = { id, fileUniqueId: key.fileUniqueId, variant: key.variant, size, complete, writtenAt: now, lastAccess: now, writing: false, pins: new Map() }
      this.#entries.set(id, entry)
    } else {
      entry.size = size
      entry.complete = complete || entry.complete
      entry.writtenAt = now
    }
    return entry
  }

  async #removeEntry(id: string): Promise<void> {
    const entry = this.#entries.get(id)
    if (entry?.writing) return
    if (entry && entry.pins.size === 0) this.#entries.delete(id)
    else if (entry) {
      entry.size = 0
      entry.complete = false
    }
    await this.#store.remove(this.#path(id))
    await this.#store.remove(`${this.cacheRoot}${id}.partial`)
    await this.#store.remove(`${this.cacheRoot}${id}.partial.json`)
  }

  #snapshot(entry: Entry): CacheEntry {
    return {
      fileUniqueId: entry.fileUniqueId,
      variant: entry.variant,
      size: entry.size,
      complete: entry.complete,
      writtenAt: entry.writtenAt,
      lastAccess: entry.lastAccess,
      pinned: entry.pins.size > 0,
    }
  }
}
