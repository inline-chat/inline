import {
  UploadKind,
  UploadStatus,
  type CreateUploadInput,
  type CreateUploadResult,
  type GetUploadStateResult,
  type UploadComplete,
} from "@inline-chat/protocol/core"
import { NativeUploadError, rpcUploadTransport, type NativeUploadRpcTransport } from "@inline-chat/protocol/uploads"
import { Log } from "@inline/log"
import { randomBytes, Sha256 } from "../bytes"
import {
  CANCEL_TIMEOUT_MS,
  HASH_READ_SIZE,
  JOB_RETRY_BASE_MS,
  JOB_RETRY_MAX_MS,
  MAX_FINISH_RECONCILIATIONS,
  MAX_JOB_ATTEMPTS,
  MAX_PART_ATTEMPTS,
  MAX_PROCESSING_RETRY_SECONDS,
  MAX_UPLOAD_BYTES,
  MAX_UPLOAD_PARTS,
  MUTATION_TIMEOUT_MS,
  ORPHAN_BLOB_AGE_MS,
  PART_RETRY_MAX_MS,
  PART_RETRY_MIN_MS,
  PART_SIZE,
  PROCESSING_TIMEOUT_MS,
  STALE_UPLOAD_AGE_MS,
  STATE_PROBE_TIMEOUT_MS,
} from "../constants"
import type { ByteStore } from "../store/byte-store"
import {
  canceled,
  deadlineSignal,
  MediaError,
  sleep,
  systemClock,
  type MediaClock,
  type MediaRpcCall,
} from "../types"
import { cloneJob, isJobId, type MediaJobStore, type UploadJobMetadata, type UploadJobRecord, type UploadJobState } from "./job"
import { PartWindow } from "./part-window"

export type UploadEvent =
  | { readonly type: "upload-state"; readonly jobId: string; readonly state: UploadJobState; readonly failure?: UploadJobRecord["failure"] }
  | { readonly type: "upload-progress"; readonly jobId: string; readonly acceptedBytes: number; readonly totalBytes: number }
  | { readonly type: "upload-complete"; readonly jobId: string; readonly complete: UploadComplete }

export type StartUploadInput = {
  /** Stable logical ID, such as the attachment's local ID. Generated when absent. */
  id?: string
  source: Blob | Uint8Array
  fileName: string
  mimeType: string
  kind: UploadKind
  thumbnailFileUniqueId?: string
  metadata?: UploadJobMetadata
}

export type UploadEngineOptions = {
  rpc: MediaRpcCall
  store: ByteStore
  jobs: MediaJobStore
  /** Account media root, ending with `/`. Sources live under `<root>uploads/`. */
  root: string
  clock?: MediaClock
  random?: () => number
  /** Shared part window; one per account. */
  window?: PartWindow
  /** Jobs that run at once; parts are bounded by the window. Web-only. */
  maxConcurrentJobs?: number
  processingTimeoutMs?: number
  log?: Log
}

/** The server no longer has this upload (canceled, expired, failed): start again under a new identity. */
class ServerUploadGone extends Error {
  constructor(readonly reason: "canceled" | "expired" | "failed") {
    super(`Server upload ${reason}`)
  }
}

type Running = { controller: AbortController; done: Promise<void> }
type Waiter = { resolve: (complete: UploadComplete) => void; reject: (error: Error) => void }

const RESUMABLE: ReadonlySet<UploadJobState> = new Set(["staged", "uploading", "finishing", "paused"])

const acceptedBytes = (job: UploadJobRecord): number => {
  let total = 0
  for (const index of job.acceptedParts) total += Math.min(PART_SIZE, job.byteCount - index * PART_SIZE)
  return total
}

const maxBytesFor = (kind: UploadKind): number | undefined => {
  switch (kind) {
    case UploadKind.PHOTO: return MAX_UPLOAD_BYTES.photo
    case UploadKind.VIDEO: return MAX_UPLOAD_BYTES.video
    case UploadKind.DOCUMENT: return MAX_UPLOAD_BYTES.document
    case UploadKind.VOICE: return MAX_UPLOAD_BYTES.voice
    default: return undefined
  }
}

const toMediaError = (error: unknown): Error => {
  if (error instanceof NativeUploadError) {
    return new MediaError(error.code === "retryable" ? "retryable" : error.code === "canceled" ? "canceled" : "protocol", error.message)
  }
  return error instanceof Error ? error : new Error(String(error))
}

/**
 * Durable, resumable part uploads, following `DurableUploadCoordinator`.
 *
 * Order of durability: the source blob is written, then the job row; a blob
 * without a row is an orphan collected later. After a restart a job with a
 * server upload asks `GetUploadState` before it sends anything; one whose
 * create reply was lost replays `CreateUpload` under the same identity, which
 * the server deduplicates. Completion is persisted before anyone is told, so a
 * lost finish reply resolves to the same file exactly once.
 */
export class UploadEngine {
  readonly window: PartWindow
  readonly #rpc: NativeUploadRpcTransport
  readonly #store: ByteStore
  readonly #jobStore: MediaJobStore
  readonly #root: string
  readonly #clock: MediaClock
  readonly #random: () => number
  readonly #maxConcurrentJobs: number
  readonly #processingTimeoutMs: number
  readonly #log: Log
  readonly #jobs = new Map<string, UploadJobRecord>()
  readonly #running = new Map<string, Running>()
  /** Jobs being stopped; the scheduler leaves them alone until their owner decides their state. */
  readonly #stopping = new Set<string>()
  readonly #retryTimers = new Map<string, unknown>()
  readonly #writes = new Map<string, Promise<void>>()
  readonly #waiters = new Map<string, Waiter[]>()
  readonly #listeners = new Set<(event: UploadEvent) => void>()
  #online = true
  #closed = false

  constructor(options: UploadEngineOptions) {
    if (!options.root.endsWith("/")) throw new TypeError("Media root ends with /")
    this.#rpc = rpcUploadTransport(options.rpc)
    this.#store = options.store
    this.#jobStore = options.jobs
    this.#root = options.root
    this.#clock = options.clock ?? systemClock
    this.#random = options.random ?? Math.random
    this.window = options.window ?? new PartWindow()
    this.#maxConcurrentJobs = options.maxConcurrentJobs ?? 4
    this.#processingTimeoutMs = options.processingTimeoutMs ?? PROCESSING_TIMEOUT_MS
    this.#log = options.log ?? new Log("media.upload")
  }

  get uploadsRoot(): string {
    return `${this.#root}uploads/`
  }

  /** Loads durable jobs, expires stale ones, retries pending cancellations and resumes the rest. */
  async open(): Promise<void> {
    const now = this.#clock.now()
    for (const job of await this.#jobStore.list()) {
      this.#jobs.set(job.id, job)
      if (job.state === "canceled") continue
      if (job.state !== "complete" && now - job.createdAt > STALE_UPLOAD_AGE_MS) {
        await this.#fail(job, new MediaError("expired", "The upload is older than the server keeps uploads"))
        await this.#store.remove(job.sourcePath).catch(() => {})
      }
    }
    for (const job of this.#jobs.values()) if (job.state === "canceled") void this.#cancelOnServer(job)
    this.#pump()
  }

  subscribe(listener: (event: UploadEvent) => void): () => void {
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  get(id: string): UploadJobRecord | undefined {
    const job = this.#jobs.get(id)
    return job ? cloneJob(job) : undefined
  }

  list(): UploadJobRecord[] {
    return Array.from(this.#jobs.values()).map(cloneJob)
  }

  /** Writes the source, then the row, then starts. Starting an ID that exists returns that job. */
  async start(input: StartUploadInput): Promise<UploadJobRecord> {
    if (this.#closed) throw new MediaError("closed", "The media core is closed")
    const id = input.id ?? Array.from(randomBytes(12), (byte) => byte.toString(16).padStart(2, "0")).join("")
    if (!isJobId(id)) throw new MediaError("invalid_source", "Invalid upload ID")
    const existing = this.#jobs.get(id)
    if (existing) return cloneJob(existing)
    const byteCount = input.source instanceof Uint8Array ? input.source.length : input.source.size
    const limit = maxBytesFor(input.kind)
    if (limit === undefined || byteCount <= 0 || byteCount > limit) {
      throw new MediaError("invalid_source", "The file is empty or exceeds the media size limit")
    }
    if (Math.ceil(byteCount / PART_SIZE) > MAX_UPLOAD_PARTS) throw new MediaError("invalid_source", "Too many parts")
    const sourcePath = `${this.uploadsRoot}${id}.body`
    await this.#store.write(sourcePath, input.source)
    const now = this.#clock.now()
    const job: UploadJobRecord = {
      id,
      sourcePath,
      fileName: input.fileName,
      mimeType: input.mimeType,
      kind: input.kind,
      byteCount,
      thumbnailFileUniqueId: input.thumbnailFileUniqueId,
      metadata: input.metadata,
      createdAt: now,
      updatedAt: now,
      state: "staged",
      clientUploadId: randomBytes(16),
      identityGeneration: 0,
      acceptedParts: [],
      attempts: 0,
    }
    await this.#jobStore.put(job)
    this.#jobs.set(id, job)
    this.#emit({ type: "upload-state", jobId: id, state: job.state })
    this.#pump()
    return cloneJob(job)
  }

  /** Resolves with the completion, now or when it arrives. Rejects when the job fails or is canceled. */
  completion(id: string): Promise<UploadComplete> {
    const job = this.#jobs.get(id)
    if (!job) return Promise.reject(new MediaError("invalid_source", "No such upload"))
    if (job.state === "complete" && job.complete) return Promise.resolve(job.complete)
    if (job.state === "canceled") return Promise.reject(canceled())
    if (job.state === "failed") return Promise.reject(new MediaError(job.failure?.retryable ? "retryable" : "rejected", job.failure?.message ?? "Upload failed"))
    const promise = new Promise<UploadComplete>((resolve, reject) => {
      const list = this.#waiters.get(id) ?? []
      list.push({ resolve, reject })
      this.#waiters.set(id, list)
    })
    // A caller that stops listening must not turn a failed upload into an unhandled rejection.
    promise.catch(() => {})
    return promise
  }

  /** Cancels locally at once and tells the server; the row stays until the server confirms. */
  async cancel(id: string): Promise<void> {
    const job = this.#jobs.get(id)
    if (!job || job.state === "complete" || job.state === "canceled") return
    await this.#stop(id)
    // The run may have completed while it was being stopped; a completion is never undone.
    if ((job.state as UploadJobState) === "complete") return
    job.state = "canceled"
    job.cancelPending = job.uploadId !== undefined
    await this.#persist(job)
    await this.#store.remove(job.sourcePath).catch(() => {})
    this.#emit({ type: "upload-state", jobId: id, state: "canceled" })
    this.#settleWaiters(id, canceled())
    await this.#cancelOnServer(job)
  }

  /** Restarts a failed or paused job with a fresh attempt budget. */
  async retry(id: string): Promise<void> {
    const job = this.#jobs.get(id)
    if (!job || (job.state !== "failed" && job.state !== "paused")) return
    this.#clearRetry(id)
    job.attempts = 0
    job.failure = undefined
    job.state = job.uploadId ? "uploading" : "staged"
    await this.#persist(job)
    this.#emit({ type: "upload-state", jobId: id, state: job.state })
    this.#pump()
  }

  /** The consumer has the completion (or gave up on the job): forget the row and any bytes. */
  async release(id: string): Promise<void> {
    const job = this.#jobs.get(id)
    if (!job) return
    if (job.state !== "complete" && job.state !== "canceled" && job.state !== "failed") {
      await this.cancel(id)
      if (this.#jobs.get(id)?.cancelPending) return
    }
    if (job.cancelPending) return
    await this.#stop(id)
    this.#jobs.delete(id)
    await this.#writes.get(id)
    await this.#jobStore.delete(id)
    await this.#store.remove(job.sourcePath).catch(() => {})
  }

  /** Online again: resume. Offline: stop sending; jobs keep their state and resume later without losing attempts. */
  setOnline(online: boolean): void {
    if (this.#online === online) return
    this.#online = online
    if (!online) {
      for (const id of Array.from(this.#running.keys())) void this.#stop(id)
      for (const id of Array.from(this.#retryTimers.keys())) this.#clearRetry(id)
      return
    }
    for (const job of this.#jobs.values()) {
      if (job.state === "canceled" && job.cancelPending) void this.#cancelOnServer(job)
    }
    this.#pump()
  }

  /** Removes source blobs that have no job row and are older than `ORPHAN_BLOB_AGE_MS`. */
  async collectOrphans(): Promise<number> {
    const now = this.#clock.now()
    let removed = 0
    for (const item of await this.#store.list(this.uploadsRoot)) {
      const name = item.path.slice(this.uploadsRoot.length)
      const id = name.endsWith(".body") ? name.slice(0, -".body".length) : undefined
      const job = id ? this.#jobs.get(id) : undefined
      const keep = job && RESUMABLE.has(job.state) || (job?.state === "failed")
      if (keep || now - item.modifiedAt < ORPHAN_BLOB_AGE_MS) continue
      await this.#store.remove(item.path)
      removed += 1
    }
    return removed
  }

  /** Stops every job. Nothing is written after this resolves. */
  async close(): Promise<void> {
    this.#closed = true
    for (const id of Array.from(this.#retryTimers.keys())) this.#clearRetry(id)
    await Promise.all(Array.from(this.#running.keys()).map((id) => this.#stop(id)))
    await Promise.all(Array.from(this.#writes.values()))
    for (const id of Array.from(this.#waiters.keys())) this.#settleWaiters(id, new MediaError("closed", "The media core closed"))
  }

  /** Sign-out: stop, then forget every job and staged source of this account. */
  async erase(): Promise<void> {
    await this.close()
    this.#jobs.clear()
    await this.#jobStore.clear()
    await this.#store.removePrefix(this.uploadsRoot)
  }

  // Scheduling

  #pump(): void {
    if (this.#closed || !this.#online) return
    for (const job of this.#jobs.values()) {
      if (this.#running.size >= this.#maxConcurrentJobs) return
      if (this.#running.has(job.id) || this.#retryTimers.has(job.id) || this.#stopping.has(job.id)) continue
      // A paused job without a timer lost it to a restart or to going offline.
      if (RESUMABLE.has(job.state)) this.#launch(job)
    }
  }

  #launch(job: UploadJobRecord): void {
    const controller = new AbortController()
    const done = this.#run(job, controller.signal).finally(() => {
      this.#running.delete(job.id)
      this.#pump()
    })
    this.#running.set(job.id, { controller, done })
  }

  async #stop(id: string): Promise<void> {
    this.#clearRetry(id)
    const running = this.#running.get(id)
    if (!running) return
    this.#stopping.add(id)
    try {
      running.controller.abort()
      await running.done
    } finally {
      this.#stopping.delete(id)
    }
  }

  #clearRetry(id: string): void {
    const timer = this.#retryTimers.get(id)
    if (timer === undefined) return
    this.#clock.clearTimeout(timer)
    this.#retryTimers.delete(id)
  }

  // One run of a job, from wherever it stopped

  async #run(job: UploadJobRecord, signal: AbortSignal): Promise<void> {
    try {
      if (this.#clock.now() - job.createdAt > STALE_UPLOAD_AGE_MS) {
        throw new MediaError("expired", "The upload is older than the server keeps uploads")
      }
      const stat = await this.#store.stat(job.sourcePath)
      if (!stat || stat.size !== job.byteCount) throw new MediaError("source_changed", "The staged source is missing or changed")
      if (!job.sha256) {
        job.sha256 = await this.#hash(job, signal)
        await this.#persist(job)
      }
      let complete = await this.#establish(job, signal)
      while (!complete) {
        await this.#transferParts(job, signal)
        const finished = await this.#finish(job, signal)
        if (finished !== "parts") complete = finished
      }
      await this.#complete(job, complete)
    } catch (rawError) {
      await this.#handleRunError(job, toMediaError(rawError), signal)
    }
  }

  async #handleRunError(job: UploadJobRecord, error: Error, signal: AbortSignal): Promise<void> {
    if (this.#closed) return
    // Stopped by cancel, release or going offline: the caller owns the state.
    if (signal.aborted) return
    if (error instanceof ServerUploadGone) {
      job.attempts += 1
      if (error.reason === "failed" || job.attempts >= MAX_JOB_ATTEMPTS) {
        await this.#fail(job, new MediaError(error.reason === "failed" ? "rejected" : "retryable", error.message), error.reason !== "failed")
        return
      }
      await this.#rotateIdentity(job)
      this.#pump()
      return
    }
    if (error instanceof MediaError && error.terminal) {
      // The server upload is of no further use: free it, and make a later retry start fresh.
      const uploadId = job.uploadId
      if (uploadId) await this.#rotateIdentity(job, false)
      await this.#fail(job, error)
      if (uploadId && error.code !== "expired") void this.#cancelUploadId(uploadId)
      return
    }
    job.attempts += 1
    this.#log.warn("upload attempt failed", { attempt: job.attempts, code: error instanceof MediaError ? error.code : "transport" })
    if (job.attempts >= MAX_JOB_ATTEMPTS) {
      await this.#fail(job, error, true)
      return
    }
    job.state = "paused"
    job.failure = { code: error instanceof MediaError ? error.code : "transport", message: error.message, retryable: true }
    await this.#persist(job)
    this.#emit({ type: "upload-state", jobId: job.id, state: "paused", failure: job.failure })
    const delay = Math.min(JOB_RETRY_BASE_MS * 2 ** (job.attempts - 1), JOB_RETRY_MAX_MS)
    const timer = this.#clock.setTimeout(() => {
      this.#retryTimers.delete(job.id)
      if (this.#closed || job.state !== "paused") return
      job.state = job.uploadId ? "uploading" : "staged"
      this.#emit({ type: "upload-state", jobId: job.id, state: job.state })
      this.#pump()
    }, delay)
    this.#retryTimers.set(job.id, timer)
  }

  async #hash(job: UploadJobRecord, signal: AbortSignal): Promise<Uint8Array> {
    const hash = new Sha256()
    for (let offset = 0; offset < job.byteCount; offset += HASH_READ_SIZE) {
      if (signal.aborted) throw canceled()
      const length = Math.min(HASH_READ_SIZE, job.byteCount - offset)
      const bytes = await this.#store.read(job.sourcePath, offset, length)
      if (!bytes || bytes.length !== length) throw new MediaError("source_changed", "The staged source changed")
      hash.update(bytes)
    }
    return hash.digest()
  }

  /** Asks the server where this upload stands, or creates it. Returns the completion when it is already done. */
  async #establish(job: UploadJobRecord, signal: AbortSignal): Promise<UploadComplete | undefined> {
    if (job.uploadId) {
      let state: GetUploadStateResult | undefined
      try {
        state = await this.#call(STATE_PROBE_TIMEOUT_MS, signal, (s) => this.#rpc.state({ uploadId: job.uploadId! }, s))
      } catch (error) {
        if (signal.aborted) throw canceled()
        // Unknown to this session (or unreachable): the idempotent create below answers both.
        this.#log.debug("upload state probe failed; replaying create", { error: String(error) })
      }
      if (state) {
        const outcome = await this.#applyState(job, state)
        if (outcome !== "create") return outcome === "continue" ? undefined : outcome
      }
    }
    return await this.#create(job, signal)
  }

  /** `continue`: transfer what is missing; `create`: this upload is gone, make a new one. */
  async #applyState(job: UploadJobRecord, state: GetUploadStateResult): Promise<UploadComplete | "continue" | "create"> {
    this.#validateIndices(job, state.acceptedParts)
    switch (state.status) {
      case UploadStatus.UPLOADING:
      case UploadStatus.PROCESSING:
        job.acceptedParts = [...new Set(state.acceptedParts)].sort((a, b) => a - b)
        job.state = state.status === UploadStatus.PROCESSING ? "finishing" : "uploading"
        await this.#persist(job)
        this.#emitProgress(job)
        return "continue"
      case UploadStatus.COMPLETE:
        if (!state.complete) throw new MediaError("protocol", "Complete upload state had no result")
        return state.complete
      case UploadStatus.FAILED:
        if (!state.failure?.retryable) throw new MediaError("rejected", `Upload failed with code ${state.failure?.code ?? "unknown"}`)
        throw new ServerUploadGone("expired")
      case UploadStatus.CANCELED:
      case UploadStatus.EXPIRED:
        await this.#rotateIdentity(job, false)
        return "create"
      default:
        throw new MediaError("protocol", "Server returned an invalid upload state")
    }
  }

  async #create(job: UploadJobRecord, signal: AbortSignal): Promise<UploadComplete | undefined> {
    job.state = "uploading"
    await this.#persist(job)
    this.#emit({ type: "upload-state", jobId: job.id, state: "uploading" })
    const input: CreateUploadInput = {
      clientUploadId: job.clientUploadId,
      fileName: job.fileName,
      mimeType: job.mimeType,
      byteCount: BigInt(job.byteCount),
      sha256: job.sha256!,
      kind: job.kind,
      thumbnailFileUniqueId: job.thumbnailFileUniqueId,
      metadata: job.metadata?.kind === "video"
        ? { oneofKind: "video", video: job.metadata.value }
        : job.metadata?.kind === "voice"
          ? { oneofKind: "voice", voice: job.metadata.value }
          : { oneofKind: undefined },
    }
    // A single-part file rides along with create when a slot is free now: one round trip
    // instead of three. Older servers ignore it and the part uploads as usual.
    const inlineSlot = job.byteCount <= PART_SIZE && this.window.tryAcquire()
    let created: CreateUploadResult
    try {
      if (inlineSlot) {
        const data = await this.#store.read(job.sourcePath, 0, job.byteCount)
        if (!data || data.length !== job.byteCount) throw new MediaError("source_changed", "The staged source changed")
        input.inlineData = data
      }
      try {
        created = await this.#call(MUTATION_TIMEOUT_MS, signal, (s) => this.#rpc.create(input, s))
      } catch (error) {
        if (signal.aborted) throw canceled()
        if (error instanceof MediaError && error.terminal) throw error
        // Idempotent by the stable identity: one replay recovers a committed create whose
        // reply was lost. The replay goes without the body.
        input.inlineData = undefined
        created = await this.#call(MUTATION_TIMEOUT_MS, signal, (s) => this.#rpc.create(input, s))
      }
    } finally {
      if (inlineSlot) this.window.release()
    }
    const partCount = Math.ceil(job.byteCount / PART_SIZE)
    if (created.uploadId.length !== 16 || created.partSize !== PART_SIZE || created.partCount !== partCount ||
        created.partCount > MAX_UPLOAD_PARTS) {
      throw new MediaError("protocol", "Server returned invalid upload geometry")
    }
    job.uploadId = created.uploadId
    job.partCount = created.partCount
    this.#validateIndices(job, created.acceptedParts)
    job.acceptedParts = [...new Set(created.acceptedParts)].sort((a, b) => a - b)
    job.serverExpiresAt = Number(created.expiresAt) * 1_000
    await this.#persist(job)
    this.#emitProgress(job)
    return created.complete
  }

  async #transferParts(job: UploadJobRecord, signal: AbortSignal): Promise<void> {
    const accepted = new Set(job.acceptedParts)
    const queue: number[] = []
    for (let index = 0; index < (job.partCount ?? 0); index += 1) if (!accepted.has(index)) queue.push(index)
    if (queue.length === 0) return
    if (job.state !== "uploading") {
      job.state = "uploading"
      await this.#persist(job)
      this.#emit({ type: "upload-state", jobId: job.id, state: "uploading" })
    }
    // Workers only wait for a slot; the shared window decides how many parts move.
    const group = new AbortController()
    const onAbort = () => group.abort()
    signal.addEventListener("abort", onAbort, { once: true })
    let firstError: unknown
    const worker = async () => {
      while (queue.length > 0 && !group.signal.aborted) {
        const index = queue.shift()!
        try {
          await this.#transferPart(job, index, group.signal)
        } catch (error) {
          if (firstError === undefined) firstError = error
          group.abort()
        }
      }
    }
    try {
      await Promise.all(Array.from({ length: Math.min(this.window.max, queue.length) }, worker))
    } finally {
      signal.removeEventListener("abort", onAbort)
    }
    if (signal.aborted) throw canceled()
    if (firstError !== undefined) throw firstError
  }

  async #transferPart(job: UploadJobRecord, index: number, signal: AbortSignal): Promise<void> {
    await this.window.acquire(signal)
    let latencyMs: number | undefined
    let failed = false
    try {
      const offset = index * PART_SIZE
      const length = Math.min(PART_SIZE, job.byteCount - offset)
      const data = await this.#store.read(job.sourcePath, offset, length)
      if (!data || data.length !== length) throw new MediaError("source_changed", "The staged source changed")
      for (let attempt = 0; attempt < MAX_PART_ATTEMPTS; attempt += 1) {
        if (signal.aborted) throw canceled()
        const startedAt = this.#clock.now()
        try {
          await this.#call(MUTATION_TIMEOUT_MS, signal, (s) => this.#rpc.savePart({ uploadId: job.uploadId!, partIndex: index, data }, s))
          latencyMs = this.#clock.now() - startedAt
          break
        } catch (saveError) {
          if (signal.aborted) throw canceled()
          if (saveError instanceof MediaError && saveError.terminal) throw saveError
          failed = true
          let state: GetUploadStateResult
          try {
            state = await this.#call(STATE_PROBE_TIMEOUT_MS, signal, (s) => this.#rpc.state({ uploadId: job.uploadId! }, s))
          } catch {
            if (signal.aborted) throw canceled()
            throw saveError
          }
          this.#validateIndices(job, state.acceptedParts)
          if (state.acceptedParts.includes(index)) break
          // The server's verdict on this upload is final: start over instead of retrying a dead upload.
          switch (state.status) {
            case UploadStatus.EXPIRED: throw new ServerUploadGone("expired")
            case UploadStatus.CANCELED: throw new ServerUploadGone("canceled")
            case UploadStatus.FAILED: throw state.failure?.retryable ? new ServerUploadGone("expired") : new ServerUploadGone("failed")
            default: break
          }
          if (state.status !== UploadStatus.UPLOADING || attempt + 1 >= MAX_PART_ATTEMPTS) throw saveError
          await sleep(this.#clock, PART_RETRY_MIN_MS + this.#random() * (PART_RETRY_MAX_MS - PART_RETRY_MIN_MS), signal)
        }
      }
      if (signal.aborted) throw canceled()
      if (!job.acceptedParts.includes(index)) {
        job.acceptedParts = [...job.acceptedParts, index].sort((a, b) => a - b)
        await this.#persist(job)
        this.#emitProgress(job)
      }
    } finally {
      this.window.release({ latencyMs: failed ? undefined : latencyMs, failed })
    }
  }

  /** Finishes, polling processing. `parts` when the server is missing parts. */
  async #finish(job: UploadJobRecord, signal: AbortSignal): Promise<UploadComplete | "parts"> {
    if (job.state !== "finishing") {
      job.state = "finishing"
      await this.#persist(job)
      this.#emit({ type: "upload-state", jobId: job.id, state: "finishing" })
    }
    const deadline = this.#clock.now() + this.#processingTimeoutMs
    let reconciliations = 0
    for (;;) {
      if (signal.aborted) throw canceled()
      if (this.#clock.now() >= deadline) {
        throw new MediaError("processing_timeout", "The file transferred, but processing did not finish in time")
      }
      let result
      try {
        result = await this.#call(MUTATION_TIMEOUT_MS, signal, (s) => this.#rpc.finish({ uploadId: job.uploadId! }, s))
        reconciliations = 0
      } catch (finishError) {
        if (signal.aborted) throw canceled()
        if (finishError instanceof MediaError && finishError.terminal) throw finishError
        reconciliations += 1
        if (reconciliations > MAX_FINISH_RECONCILIATIONS) throw finishError
        let state: GetUploadStateResult
        try {
          state = await this.#call(STATE_PROBE_TIMEOUT_MS, signal, (s) => this.#rpc.state({ uploadId: job.uploadId! }, s))
        } catch {
          if (signal.aborted) throw canceled()
          throw finishError
        }
        const outcome = await this.#applyState(job, state)
        if (outcome === "create") throw new ServerUploadGone("expired")
        if (outcome !== "continue") return outcome
        if (job.acceptedParts.length < (job.partCount ?? 0)) return "parts"
        // Processing: replay the idempotent finish so it can reclaim a stale lease.
        continue
      }
      switch (result.state.oneofKind) {
        case "complete":
          return result.state.complete
        case "missing": {
          const missing = result.state.missing.partIndices
          if (missing.length === 0) throw new MediaError("protocol", "Server returned an empty missing-parts result")
          this.#validateIndices(job, missing)
          job.acceptedParts = job.acceptedParts.filter((index) => !missing.includes(index))
          await this.#persist(job)
          return "parts"
        }
        case "processing": {
          const seconds = Math.min(MAX_PROCESSING_RETRY_SECONDS, Math.max(1, Math.floor(result.state.processing.retryAfterSeconds)))
          await sleep(this.#clock, Math.min(seconds * 1_000, Math.max(0, deadline - this.#clock.now())), signal)
          continue
        }
        case "failed":
          if (result.state.failed.retryable) throw new ServerUploadGone("expired")
          throw new MediaError("rejected", `Upload processing failed with code ${result.state.failed.code}`)
        default:
          throw new MediaError("protocol", "Server returned an empty finish result")
      }
    }
  }

  async #complete(job: UploadJobRecord, complete: UploadComplete): Promise<void> {
    if (job.state === "complete") return
    job.complete = complete
    job.state = "complete"
    job.failure = undefined
    job.acceptedParts = Array.from({ length: job.partCount ?? Math.ceil(job.byteCount / PART_SIZE) }, (_, index) => index)
    // Durable before anyone is told: a restart reports the same completion and never uploads again.
    await this.#persist(job)
    await this.#store.remove(job.sourcePath).catch(() => {})
    this.#emitProgress(job)
    this.#emit({ type: "upload-state", jobId: job.id, state: "complete" })
    this.#emit({ type: "upload-complete", jobId: job.id, complete })
    const waiters = this.#waiters.get(job.id) ?? []
    this.#waiters.delete(job.id)
    for (const waiter of waiters) waiter.resolve(complete)
  }

  async #fail(job: UploadJobRecord, error: Error, retryable = false): Promise<void> {
    job.state = "failed"
    job.failure = {
      code: error instanceof MediaError ? error.code : "transport",
      message: error.message,
      retryable: retryable || (error instanceof MediaError && !error.terminal),
    }
    await this.#persist(job)
    this.#emit({ type: "upload-state", jobId: job.id, state: "failed", failure: job.failure })
    this.#settleWaiters(job.id, error instanceof MediaError ? error : new MediaError("retryable", error.message))
  }

  /** A server upload that is gone cannot be reused: the next create must not find it again. */
  async #rotateIdentity(job: UploadJobRecord, persist = true): Promise<void> {
    job.clientUploadId = randomBytes(16)
    job.identityGeneration += 1
    job.uploadId = undefined
    job.partCount = undefined
    job.serverExpiresAt = undefined
    job.acceptedParts = []
    job.state = "staged"
    if (persist) await this.#persist(job)
    this.#emitProgress(job)
  }

  async #cancelOnServer(job: UploadJobRecord, options: { keepRow?: boolean } = {}): Promise<void> {
    const uploadId = job.uploadId
    if (!uploadId) {
      if (!options.keepRow && job.state === "canceled") await this.#forget(job)
      return
    }
    if (!(await this.#cancelUploadId(uploadId))) return
    if (options.keepRow) return
    await this.#forget(job)
  }

  /** Best effort; a canceled row keeps `cancelPending` and the server's idle expiry is the safety net. */
  async #cancelUploadId(uploadId: Uint8Array): Promise<boolean> {
    try {
      await this.#call(CANCEL_TIMEOUT_MS, undefined, (s) => this.#rpc.cancel({ uploadId }, s))
      return true
    } catch {
      return false
    }
  }

  async #forget(job: UploadJobRecord): Promise<void> {
    if (this.#closed) return
    this.#jobs.delete(job.id)
    await this.#writes.get(job.id)
    await this.#jobStore.delete(job.id)
  }

  #validateIndices(job: UploadJobRecord, indices: readonly number[]): void {
    const count = job.partCount ?? Math.ceil(job.byteCount / PART_SIZE)
    if (indices.some((index) => !Number.isInteger(index) || index < 0 || index >= count)) {
      throw new MediaError("protocol", "Server returned an invalid upload-part index")
    }
  }

  /** One RPC under its own deadline, aborted with the job. */
  async #call<T>(timeoutMs: number, signal: AbortSignal | undefined, run: (signal: AbortSignal) => Promise<T>): Promise<T> {
    if (signal?.aborted) throw canceled()
    const deadline = deadlineSignal(this.#clock, timeoutMs, signal)
    try {
      return await run(deadline.signal)
    } catch (error) {
      if (signal?.aborted) throw canceled()
      throw toMediaError(error)
    } finally {
      deadline.dispose()
    }
  }

  /** Serializes writes per job, so a later state never lands under an earlier one. */
  #persist(job: UploadJobRecord): Promise<void> {
    if (this.#closed && !this.#jobs.has(job.id)) return Promise.resolve()
    job.updatedAt = this.#clock.now()
    const snapshot = cloneJob(job)
    const previous = this.#writes.get(job.id) ?? Promise.resolve()
    const next = previous.catch(() => {}).then(() => {
      if (!this.#jobs.has(job.id) && this.#closed) return
      return this.#jobStore.put(snapshot)
    })
    this.#writes.set(job.id, next)
    return next
  }

  #settleWaiters(id: string, error: Error): void {
    const waiters = this.#waiters.get(id) ?? []
    this.#waiters.delete(id)
    for (const waiter of waiters) waiter.reject(error)
  }

  #emitProgress(job: UploadJobRecord): void {
    this.#emit({ type: "upload-progress", jobId: job.id, acceptedBytes: acceptedBytes(job), totalBytes: job.byteCount })
  }

  #emit(event: UploadEvent): void {
    for (const listener of this.#listeners) {
      try {
        listener(event)
      } catch {
        // An observer never changes transfer ownership.
      }
    }
  }
}
