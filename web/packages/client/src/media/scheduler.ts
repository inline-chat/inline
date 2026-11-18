import type { FileMessageLocation } from "@inline-chat/protocol/core"
import { cacheId, type CacheEntry, type CacheKey, type MediaCache } from "./cache/media-cache"
import type { DownloadProgress } from "./download/download"
import { defaultMediaSettings, shouldAutoDownload, type AutoDownloadKind, type AutoDownloadLimits } from "./settings"
import { canceled, MediaError, systemClock, type MediaClock } from "./types"

/** What the UI says about an asset, most urgent first. */
export type MediaPriority = "opened" | "visible" | "nearby" | "prefetch"

const RANK: Record<MediaPriority, number> = { opened: 3, visible: 2, nearby: 1, prefetch: 0 }

/** Everything the scheduler needs to fetch one file in one variant. Plain data. */
export type MediaAsset = {
  readonly key: CacheKey
  readonly kind: AutoDownloadKind
  /** From the message metadata; required for automatic download. */
  readonly sizeBytes?: number
  /** A signed media URL. Without one the file comes over `GET_FILE_PART`. */
  readonly url?: string
  readonly message?: FileMessageLocation
  readonly sha256?: Uint8Array
}

export type DownloadRunner = (
  asset: MediaAsset,
  signal: AbortSignal,
  onProgress: (progress: DownloadProgress) => void,
) => Promise<CacheEntry>

export type DownloadEvent =
  | { readonly type: "download-queued"; readonly id: string; readonly priority: MediaPriority }
  | { readonly type: "download-progress"; readonly id: string; readonly receivedBytes: number; readonly totalBytes: number }
  | { readonly type: "download-complete"; readonly id: string; readonly entry: CacheEntry }
  | { readonly type: "download-failed"; readonly id: string; readonly code: string; readonly message: string }
  | { readonly type: "download-canceled"; readonly id: string }

export type DownloadStatus = "queued" | "running" | "complete" | "failed"

export type DownloadHandle = {
  readonly id: string
  readonly done: Promise<CacheEntry>
  /** Nobody here needs it any more; the download stops when no one else does. */
  release(): void
}

type Task = {
  id: string
  asset: MediaAsset
  /** Holder → priority. Area holders are `visible`, `nearby`, `prefetch`; explicit ones are unique. */
  holders: Map<string, MediaPriority>
  order: number
  status: "queued" | "running"
  controller?: AbortController
  attempts: number
  waiters: { resolve: (entry: CacheEntry) => void; reject: (error: Error) => void }[]
}

export type MediaSchedulerOptions = {
  cache: MediaCache
  run: DownloadRunner
  clock?: MediaClock
  autoDownload?: AutoDownloadLimits
  /** Files downloading at once. */
  maxConcurrent?: number
  /** Of those, at most this many may be prefetches. */
  maxPrefetch?: number
  /** Automatic retries of a transient failure. */
  maxAttempts?: number
  retryDelayMs?: number
}

/**
 * Decides what to download first. Visible and explicitly opened assets come
 * first, then nearby, then prefetch; one request per file however many ask;
 * a download nobody wants is canceled (its partial is kept); automatic
 * requests obey the auto-download limits; nothing starts while offline.
 * Separate from sync, and plain method calls in: the UI reports what it sees.
 */
export class MediaScheduler {
  readonly #cache: MediaCache
  readonly #run: DownloadRunner
  readonly #clock: MediaClock
  readonly #maxConcurrent: number
  readonly #maxPrefetch: number
  readonly #maxAttempts: number
  readonly #retryDelayMs: number
  readonly #tasks = new Map<string, Task>()
  readonly #retryTimers = new Map<string, unknown>()
  /** Automatic requests skip these until someone opens them explicitly. */
  readonly #failed = new Set<string>()
  readonly #listeners = new Set<(event: DownloadEvent) => void>()
  #limits: AutoDownloadLimits
  #order = 0
  #holderSeq = 0
  #online = true
  #closed = false

  constructor(options: MediaSchedulerOptions) {
    this.#cache = options.cache
    this.#run = options.run
    this.#clock = options.clock ?? systemClock
    this.#limits = options.autoDownload ?? defaultMediaSettings.autoDownload
    this.#maxConcurrent = options.maxConcurrent ?? 4
    this.#maxPrefetch = options.maxPrefetch ?? 1
    this.#maxAttempts = options.maxAttempts ?? 3
    this.#retryDelayMs = options.retryDelayMs ?? 2_000
  }

  subscribe(listener: (event: DownloadEvent) => void): () => void {
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  setAutoDownload(limits: AutoDownloadLimits): void {
    this.#limits = limits
  }

  /** May this asset download without the user asking? */
  allowsAuto(asset: MediaAsset): boolean {
    return shouldAutoDownload(this.#limits, asset.kind, asset.sizeBytes)
  }

  /** Replaces the visible set. Assets that left it lose their visible claim. */
  setVisible(assets: readonly MediaAsset[]): void {
    this.#setArea("visible", assets)
  }

  /** Replaces the nearby set (rows just outside the viewport, warmed when scrolling goes idle). */
  setNearby(assets: readonly MediaAsset[]): void {
    this.#setArea("nearby", assets)
  }

  /** Replaces the prefetch set. */
  setPrefetch(assets: readonly MediaAsset[]): void {
    this.#setArea("prefetch", assets)
  }

  /** The user asked for this file: it goes first and ignores auto-download limits. */
  open(asset: MediaAsset): DownloadHandle {
    return this.request(asset, "opened")
  }

  /** One explicit claim on an asset at a priority, released by the handle. */
  request(asset: MediaAsset, priority: MediaPriority): DownloadHandle {
    const id = cacheId(asset.key)
    const holder = `h${(this.#holderSeq += 1)}`
    let released = false
    const done = new Promise<CacheEntry>((resolve, reject) => {
      if (this.#closed) {
        reject(new MediaError("closed", "The media core is closed"))
        return
      }
      const cached = this.#cache.entry(asset.key)
      if (cached?.complete) {
        resolve(cached)
        return
      }
      if (priority === "opened") this.#failed.delete(id)
      const task = this.#claim(id, asset, holder, priority)
      task.waiters.push({ resolve, reject })
    })
    done.catch(() => {})
    this.#pump()
    return {
      id,
      done,
      release: () => {
        if (released) return
        released = true
        this.#unclaim(id, holder)
      },
    }
  }

  status(key: CacheKey): DownloadStatus | undefined {
    const id = cacheId(key)
    const task = this.#tasks.get(id)
    if (task) return task.status
    if (this.#cache.has(key)) return "complete"
    return this.#failed.has(id) ? "failed" : undefined
  }

  priorityOf(key: CacheKey): MediaPriority | undefined {
    const task = this.#tasks.get(cacheId(key))
    return task ? this.#priority(task) : undefined
  }

  /** Offline: running downloads stop (keeping their partials) and wait; nothing starts until online. */
  setOnline(online: boolean): void {
    if (this.#online === online) return
    this.#online = online
    if (!online) {
      for (const task of this.#tasks.values()) {
        if (task.status === "running") task.controller?.abort()
      }
      for (const [id, timer] of this.#retryTimers) {
        this.#clock.clearTimeout(timer)
        this.#retryTimers.delete(id)
      }
      return
    }
    this.#pump()
  }

  /** Cancels everything; outstanding handles reject. */
  close(): void {
    this.#closed = true
    for (const timer of this.#retryTimers.values()) this.#clock.clearTimeout(timer)
    this.#retryTimers.clear()
    for (const task of Array.from(this.#tasks.values())) this.#drop(task, new MediaError("closed", "The media core is closed"))
  }

  #setArea(area: MediaPriority, assets: readonly MediaAsset[]): void {
    if (this.#closed) return
    const wanted = new Map<string, MediaAsset>()
    for (const asset of assets) {
      const id = cacheId(asset.key)
      if (this.#cache.has(asset.key) || this.#failed.has(id) || !this.allowsAuto(asset)) continue
      wanted.set(id, asset)
    }
    for (const task of Array.from(this.#tasks.values())) {
      if (task.holders.get(area) === area && !wanted.has(task.id)) this.#unclaim(task.id, area)
    }
    for (const [id, asset] of wanted) this.#claim(id, asset, area, area)
    this.#pump()
  }

  #claim(id: string, asset: MediaAsset, holder: string, priority: MediaPriority): Task {
    let task = this.#tasks.get(id)
    if (!task) {
      task = { id, asset, holders: new Map(), order: (this.#order += 1), status: "queued", attempts: 0, waiters: [] }
      this.#tasks.set(id, task)
      task.holders.set(holder, priority)
      this.#emit({ type: "download-queued", id, priority })
      return task
    }
    task.holders.set(holder, priority)
    return task
  }

  #unclaim(id: string, holder: string): void {
    const task = this.#tasks.get(id)
    if (!task || !task.holders.delete(holder)) return
    if (task.holders.size > 0) return
    this.#drop(task, canceled())
    this.#emit({ type: "download-canceled", id })
    this.#pump()
  }

  #drop(task: Task, error: Error): void {
    this.#tasks.delete(task.id)
    const timer = this.#retryTimers.get(task.id)
    if (timer !== undefined) {
      this.#clock.clearTimeout(timer)
      this.#retryTimers.delete(task.id)
    }
    task.controller?.abort()
    for (const waiter of task.waiters) waiter.reject(error)
    task.waiters = []
  }

  #priority(task: Task): MediaPriority {
    let best: MediaPriority = "prefetch"
    for (const priority of task.holders.values()) if (RANK[priority] > RANK[best]) best = priority
    return best
  }

  #pump(): void {
    if (this.#closed || !this.#online) return
    let running = 0
    let runningPrefetch = 0
    for (const task of this.#tasks.values()) {
      if (task.status !== "running") continue
      running += 1
      if (this.#priority(task) === "prefetch") runningPrefetch += 1
    }
    const queued = Array.from(this.#tasks.values())
      .filter((task) => task.status === "queued" && !this.#retryTimers.has(task.id))
      .sort((left, right) => RANK[this.#priority(right)] - RANK[this.#priority(left)] || left.order - right.order)
    for (const task of queued) {
      if (running >= this.#maxConcurrent) return
      const prefetch = this.#priority(task) === "prefetch"
      if (prefetch && runningPrefetch >= this.#maxPrefetch) continue
      running += 1
      if (prefetch) runningPrefetch += 1
      void this.#start(task)
    }
  }

  async #start(task: Task): Promise<void> {
    const controller = new AbortController()
    task.controller = controller
    task.status = "running"
    let entry: CacheEntry | undefined
    let failure: unknown
    try {
      entry = await this.#run(task.asset, controller.signal, (progress) => {
        if (this.#tasks.get(task.id) === task) this.#emit({ type: "download-progress", id: task.id, ...progress })
      })
    } catch (error) {
      failure = error
    }
    task.controller = undefined
    if (this.#tasks.get(task.id) !== task) return
    if (entry) {
      this.#tasks.delete(task.id)
      for (const waiter of task.waiters) waiter.resolve(entry)
      this.#emit({ type: "download-complete", id: task.id, entry })
      this.#pump()
      return
    }
    task.status = "queued"
    // Stopped for going offline: wait for the network, spending no attempt.
    if (controller.signal.aborted && !this.#online) return
    const error = failure instanceof MediaError ? failure : new MediaError("retryable", String(failure))
    task.attempts += 1
    if (error.terminal || task.attempts >= this.#maxAttempts) {
      this.#failed.add(task.id)
      this.#drop(task, error)
      this.#emit({ type: "download-failed", id: task.id, code: error.code, message: error.message })
      this.#pump()
      return
    }
    const timer = this.#clock.setTimeout(() => {
      this.#retryTimers.delete(task.id)
      this.#pump()
    }, this.#retryDelayMs * 2 ** (task.attempts - 1))
    this.#retryTimers.set(task.id, timer)
    this.#pump()
  }

  #emit(event: DownloadEvent): void {
    for (const listener of this.#listeners) {
      try {
        listener(event)
      } catch {
        // Observers do not change scheduling.
      }
    }
  }
}
