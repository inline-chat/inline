import type { UploadComplete } from "@inline-chat/protocol/core"
import { Log } from "@inline/log"
import { MediaCache, type CacheKey, type PinReason, type SweepResult } from "./cache/media-cache"
import { MUTATION_TIMEOUT_MS } from "./constants"
import { downloadToCache } from "./download/download"
import { HttpRangeSource, RpcRangeSource, type RangeSource } from "./download/range-source"
import type { ImagePreparer, ImagePurpose, PreparedImage } from "./image/prepare-image"
import { MediaScheduler, type DownloadEvent, type DownloadHandle, type MediaAsset } from "./scheduler"
import { defaultMediaSettings, type MediaSettings } from "./settings"
import type { ByteStore } from "./store/byte-store"
import { ByteStoreJobStore, type MediaJobStore, type UploadJobRecord } from "./upload/job"
import { PartWindow } from "./upload/part-window"
import { UploadEngine, type StartUploadInput, type UploadEvent } from "./upload/upload-engine"
import { deadlineSignal, MediaError, systemClock, type MediaClock, type MediaFetch, type MediaRpcCall } from "./types"

export type MediaEvent = UploadEvent | DownloadEvent

export type MediaCoreOptions = {
  /** Path-safe account identity; everything of this account lives under `accounts/<accountKey>/media/`. */
  accountKey: string
  /** RPC over the account's realtime socket. */
  rpc: MediaRpcCall
  /** HTTP for media URLs. */
  fetch: MediaFetch
  /** OPFS in the browser (`OpfsByteStore`), memory in tests. */
  store: ByteStore
  /** Durable upload jobs. Defaults to JSON files in `store`. */
  jobs?: MediaJobStore
  clock?: MediaClock
  random?: () => number
  settings?: MediaSettings
  /** Browser: `browserImagePreparer`. */
  imagePreparer?: ImagePreparer
  /** A fresh signed URL when the one an asset carries is rejected. */
  refreshUrl?: (asset: MediaAsset, stale: string) => Promise<string | undefined>
  log?: Log
}

const ACCOUNT_KEY = /^[A-Za-z0-9_-]{1,64}$/

/**
 * The part of the account core that moves and keeps bytes: durable resumable
 * uploads, ranged downloads into a budgeted cache, and the scheduler that
 * decides what to fetch first. Framework-free and DOM-free; every dependency
 * is injected so the core host can construct it in its worker.
 */
export class MediaCore {
  readonly root: string
  readonly uploads: UploadEngine
  readonly cache: MediaCache
  readonly scheduler: MediaScheduler
  readonly #options: MediaCoreOptions
  readonly #clock: MediaClock
  readonly #listeners = new Set<(event: MediaEvent) => void>()
  readonly #uploadPins = new Map<string, (() => void)[]>()
  #settings: MediaSettings
  #closed = false

  private constructor(options: MediaCoreOptions) {
    if (!ACCOUNT_KEY.test(options.accountKey)) throw new MediaError("invalid_source", "Invalid account key")
    this.#options = options
    this.#clock = options.clock ?? systemClock
    this.#settings = options.settings ?? defaultMediaSettings
    this.root = `accounts/${options.accountKey}/media/`
    const log = options.log ?? new Log("media")
    this.uploads = new UploadEngine({
      rpc: options.rpc,
      store: options.store,
      jobs: options.jobs ?? new ByteStoreJobStore(options.store, `${this.root}jobs/`),
      root: this.root,
      clock: this.#clock,
      random: options.random,
      window: new PartWindow(),
      log: log.withScope("upload"),
    })
    this.cache = new MediaCache({
      store: options.store,
      root: this.root,
      budgetBytes: this.#settings.cacheBudgetBytes,
      clock: this.#clock,
      log: log.withScope("cache"),
    })
    this.scheduler = new MediaScheduler({
      cache: this.cache,
      clock: this.#clock,
      autoDownload: this.#settings.autoDownload,
      run: (asset, signal, onProgress) => downloadToCache(this.cache, {
        key: asset.key,
        source: this.#sourceFor(asset),
        expectedSize: asset.sizeBytes,
        sha256: asset.sha256,
        signal,
        onProgress,
      }),
    })
    this.uploads.subscribe((event) => {
      if (event.type === "upload-state" && (event.state === "complete" || event.state === "canceled" || event.state === "failed")) {
        this.#releaseUploadPins(event.jobId)
      }
      this.#emit(event)
    })
    this.scheduler.subscribe((event) => this.#emit(event))
  }

  /** Opens the cache index and the job store, then resumes unfinished uploads. */
  static async open(options: MediaCoreOptions): Promise<MediaCore> {
    const core = new MediaCore(options)
    await core.cache.open()
    await core.uploads.open()
    return core
  }

  subscribe(listener: (event: MediaEvent) => void): () => void {
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  get settings(): MediaSettings {
    return this.#settings
  }

  async updateSettings(settings: MediaSettings): Promise<void> {
    this.#settings = settings
    this.scheduler.setAutoDownload(settings.autoDownload)
    await this.cache.setBudget(settings.cacheBudgetBytes)
  }

  // Uploads

  /** Stages the source durably and starts. `pin` keeps local copies (a preview in the cache) until the job ends. */
  async startUpload(input: StartUploadInput, options: { pin?: readonly CacheKey[] } = {}): Promise<UploadJobRecord> {
    const job = await this.uploads.start(input)
    if (options.pin?.length && job.state !== "complete") {
      const pins = this.#uploadPins.get(job.id) ?? []
      for (const key of options.pin) pins.push(this.cache.pin(key, "upload"))
      this.#uploadPins.set(job.id, pins)
    }
    return job
  }

  uploadCompletion(id: string): Promise<UploadComplete> {
    return this.uploads.completion(id)
  }

  cancelUpload(id: string): Promise<void> {
    return this.uploads.cancel(id)
  }

  retryUpload(id: string): Promise<void> {
    return this.uploads.retry(id)
  }

  /** The consumer took the completion: forget the job. */
  releaseUpload(id: string): Promise<void> {
    this.#releaseUploadPins(id)
    return this.uploads.release(id)
  }

  prepareImage(blob: Blob, purpose: ImagePurpose): Promise<PreparedImage> {
    if (!this.#options.imagePreparer) return Promise.reject(new MediaError("invalid_source", "No image preparer in this context"))
    return this.#options.imagePreparer.prepareImage(blob, purpose)
  }

  // Downloads

  setVisible(assets: readonly MediaAsset[]): void {
    this.scheduler.setVisible(assets)
  }

  setNearby(assets: readonly MediaAsset[]): void {
    this.scheduler.setNearby(assets)
  }

  setPrefetch(assets: readonly MediaAsset[]): void {
    this.scheduler.setPrefetch(assets)
  }

  /** The user opened it: first in line, no auto-download limit. Pinned for the viewer until released. */
  open(asset: MediaAsset): DownloadHandle {
    const unpin = this.cache.pin(asset.key, "viewer")
    const handle = this.scheduler.open(asset)
    return {
      id: handle.id,
      done: handle.done,
      release: () => {
        handle.release()
        unpin()
      },
    }
  }

  read(key: CacheKey): Promise<Blob | undefined> {
    return this.cache.read(key)
  }

  pin(key: CacheKey, reason: PinReason): () => void {
    return this.cache.pin(key, reason)
  }

  // Lifecycle

  setOnline(online: boolean): void {
    this.uploads.setOnline(online)
    this.scheduler.setOnline(online)
  }

  /**
   * The daily sweep (`MediaCacheSweep`) plus orphaned upload sources.
   * `referenced` is every file ID the replica or a draft still refers to.
   */
  async sweep(referenced: () => Promise<ReadonlySet<string>>, options: { force?: boolean } = {}): Promise<{ cache: SweepResult | undefined; orphans: number }> {
    const cache = await this.cache.sweep({ referenced, keepMediaDays: this.#settings.keepMediaDays, force: options.force })
    const orphans = await this.uploads.collectOrphans()
    return { cache, orphans }
  }

  async close(): Promise<void> {
    if (this.#closed) return
    this.#closed = true
    this.scheduler.close()
    await this.uploads.close()
  }

  /** Sign-out: stop everything and erase this account's jobs, sources and cache. Other accounts are untouched. */
  async erase(): Promise<void> {
    this.#closed = true
    this.scheduler.close()
    await this.uploads.erase()
    await this.cache.erase()
    await this.#options.store.removePrefix(this.root)
  }

  #sourceFor(asset: MediaAsset): RangeSource {
    if (asset.url) {
      const refresh = this.#options.refreshUrl
      return new HttpRangeSource(this.#options.fetch, asset.url, refresh ? (stale) => refresh(asset, stale) : undefined)
    }
    const rpc: MediaRpcCall = async (method, input, signal) => {
      const deadline = deadlineSignal(this.#clock, MUTATION_TIMEOUT_MS, signal)
      try {
        return await this.#options.rpc(method, input, deadline.signal)
      } finally {
        deadline.dispose()
      }
    }
    return new RpcRangeSource(rpc, asset.key.fileUniqueId, asset.message)
  }

  #releaseUploadPins(id: string): void {
    const pins = this.#uploadPins.get(id)
    this.#uploadPins.delete(id)
    for (const unpin of pins ?? []) unpin()
  }

  #emit(event: MediaEvent): void {
    for (const listener of this.#listeners) {
      try {
        listener(event)
      } catch {
        // Observers do not change transfers.
      }
    }
  }
}

export type { CacheEntry, CacheKey, CacheUsage, PinReason, SweepResult } from "./cache/media-cache"
export { MediaCache, cacheId } from "./cache/media-cache"
export * from "./constants"
export { downloadToCache, type DownloadProgress, type DownloadRequest } from "./download/download"
export { HttpRangeSource, RpcRangeSource, RepresentationChanged, parseContentRange, type RangeResult, type RangeSource } from "./download/range-source"
export {
  browserImageCodec,
  browserImagePreparer,
  createImagePreparer,
  planImage,
  type DecodedImage,
  type ImageCodec,
  type ImagePreparer,
  type ImagePurpose,
  type PreparedImage,
} from "./image/prepare-image"
export { MediaScheduler, type DownloadEvent, type DownloadHandle, type DownloadStatus, type MediaAsset, type MediaPriority } from "./scheduler"
export { clampMegabytes, defaultMediaSettings, shouldAutoDownload, type AutoDownloadKind, type AutoDownloadLimits, type MediaSettings } from "./settings"
export { MemoryByteStore, type ByteStore, type ByteWriter, type StoredItem } from "./store/byte-store"
export { OpfsByteStore } from "./store/opfs-byte-store"
export { ByteStoreJobStore, MemoryMediaJobStore, type MediaJobStore, type UploadJobRecord, type UploadJobState } from "./upload/job"
export { PartWindow } from "./upload/part-window"
export { UploadEngine, type StartUploadInput, type UploadEvent } from "./upload/upload-engine"
export { MediaError, systemClock, type MediaClock, type MediaErrorCode, type MediaFetch, type MediaRpcCall } from "./types"
