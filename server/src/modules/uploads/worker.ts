import { createHash, type Hash } from "node:crypto"
import { InlineError } from "@in/server/types/errors"
import {
  INLINE_UPLOAD_PROCESSING_LEASE_MS,
  InlineUploadPublicationConflictError,
  InlineUploadRepository,
  inlineUploadPublicationPath,
  type InlineUploadProcessingClaim,
  type InlineUploadRecord,
  type InlineUploadStorageWork,
} from "@in/server/db/models/inlineUploads"
import { FILES_PATH_PREFIX } from "@in/server/modules/files/path"
import { FileByteLengthError } from "@in/server/modules/files/readFileBytes"
import { IdleBackoff } from "@in/server/utils/idleBackoff"
import { Log } from "@in/server/utils/log"
import {
  UploadIntegrityError,
  UploadInvalidMediaError,
  bufferedPublicationNeedsBytes,
  type MediaUploadFinalizer,
} from "./finalizer"
import { UploadGroupBuffer } from "./groupBuffer"
import {
  MultipartIntegrityError,
  MultipartStorageUnavailableError,
  MultipartUploadNotFoundError,
  multipartEtag,
  type MultipartObjectStore,
  type MultipartUploadedPart,
} from "./multipartStore"
import { UploadPartStorageUnavailableError, type UploadPartStore } from "./partStore"
import { IDENTITY_STORAGE_FORMAT, storageCodecFor } from "./storageCodec"
import { transferTraces, withTransferCounters } from "@in/server/modules/transfers/trace"

export const uploadTraceKey = (uploadDbId: number): string => `upload:${uploadDbId}`

const log = new Log("modules/uploads/worker")
export const STORAGE_FRAMES_PER_PART = 10
const DEFAULT_CONCURRENCY = 4
const DEFAULT_POLL_INTERVAL_MS = 2_000
const MAX_PROCESSING_ATTEMPTS = 12
const LEASE_RENEW_INTERVAL_MS = Math.min(60_000, INLINE_UPLOAD_PROCESSING_LEASE_MS / 3)
const DEFAULT_LEASE_RENEW_TIMEOUT_MS = Math.min(5_000, INLINE_UPLOAD_PROCESSING_LEASE_MS / 4)
const DEFAULT_SHUTDOWN_DRAIN_TIMEOUT_MS = 5_000
const STAGING_READ_CONCURRENCY = 4
const DEFAULT_EXPIRY_CLEANUP_INTERVAL_MS = 60_000
const CANCELED_UPLOAD_CLEANUP_TIMEOUT_MS = 60_000
const EXPIRY_CLEANUP_BATCH_SIZE = 100
const DEFAULT_INLINE_FINISH_TIMEOUT_MS = 20_000
const MAX_RUNNING_DIGESTS = 256
// A group claim skips a row locked by a concurrent part insert or another
// worker. Group wakes are one-shot, so retry a few times before leaving the
// group to the finish pass.
const GROUP_CLAIM_RETRIES = 3
const GROUP_CLAIM_RETRY_DELAY_MS = 100

type WorkerOptions = {
  concurrency?: number
  /** Accepted frames this process still holds; shared with the operations that fill it. */
  groupBuffer?: UploadGroupBuffer
  inlineFinishTimeoutMs?: number
  expiryCleanupIntervalMs?: number
  leaseRenewTimeoutMs?: number
  maximumIdleIntervalMs?: number
  pollIntervalMs?: number
  random?: () => number
  shutdownDrainTimeoutMs?: number
}

export type StoragePartGeometry = {
  partNumber: number
  firstFrameIndex: number
  frameCount: number
}

/**
 * Whole-file SHA-256 over compacted groups, fed strictly in group order. A
 * group compacted out of order waits in `pending`; a group this process never
 * sees (another process, a restart, an evicted buffer that was re-read from an
 * already recorded session) makes the digest incomplete, and finalization
 * falls back to reading the stored object.
 */
type RunningDigest = {
  hash: Hash
  nextGroup: number
  pending: Map<number, Uint8Array>
  incomplete: boolean
}

export const storagePartGeometry = (partCount: number): StoragePartGeometry[] => {
  if (!Number.isSafeInteger(partCount) || partCount < 1) throw new RangeError("Invalid upload part count")
  return Array.from({ length: Math.ceil(partCount / STORAGE_FRAMES_PER_PART) }, (_, index) => ({
    partNumber: index + 1,
    firstFrameIndex: index * STORAGE_FRAMES_PER_PART,
    frameCount: Math.min(STORAGE_FRAMES_PER_PART, partCount - index * STORAGE_FRAMES_PER_PART),
  }))
}

const sameBytes = (left: Uint8Array, right: Uint8Array): boolean =>
  Buffer.from(left).equals(Buffer.from(right))

const throwIfAborted = (signal: AbortSignal): void => {
  if (signal.aborted) throw signal.reason ?? new DOMException("The operation was aborted", "AbortError")
}

const settlesWithin = async (promise: Promise<unknown>, timeoutMs: number): Promise<boolean> =>
  await new Promise<boolean>((resolve) => {
    let settled = false
    const finish = (value: boolean) => {
      if (settled) return
      settled = true
      clearTimeout(timeout)
      resolve(value)
    }
    const timeout = setTimeout(() => finish(false), timeoutMs)
    void promise.then(() => finish(true), () => finish(true))
  })

const mapConcurrent = async <T>(
  values: T[],
  concurrency: number,
  run: (value: T, signal: AbortSignal) => Promise<void>,
  parentSignal: AbortSignal,
): Promise<void> => {
  throwIfAborted(parentSignal)
  let next = 0
  let firstError: unknown
  const controller = new AbortController()
  const abortFromParent = () => controller.abort(parentSignal.reason)
  parentSignal.addEventListener("abort", abortFromParent, { once: true })
  try {
    await Promise.all(Array.from({ length: Math.min(concurrency, values.length) }, async () => {
      while (next < values.length && !controller.signal.aborted) {
        const value = values[next++]!
        try {
          await run(value, controller.signal)
        } catch (error) {
          firstError ??= error
          controller.abort(error)
        }
      }
    }))
  } finally {
    parentSignal.removeEventListener("abort", abortFromParent)
  }
  if (firstError !== undefined) throw firstError
  throwIfAborted(parentSignal)
}

const storageKeyFor = (upload: InlineUploadRecord): string => {
  if (!upload.resultFileUniqueId) throw new UploadIntegrityError()
  return `${FILES_PATH_PREFIX}/${inlineUploadPublicationPath(upload.resultFileUniqueId)}`
}

const ownerFor = (upload: InlineUploadRecord) => ({
  userId: upload.userId,
  accountSessionId: upload.accountSessionId,
  permanentAuthKeyId: upload.permanentAuthKeyId
    ? Uint8Array.from(upload.permanentAuthKeyId)
    : undefined,
})

export class NativeUploadWorker {
  readonly #concurrency: number
  readonly #pollIntervalMs: number
  readonly #expiryCleanupIntervalMs: number
  readonly #leaseRenewTimeoutMs: number
  readonly #shutdownDrainTimeoutMs: number
  readonly #random: () => number
  readonly #backoff: IdleBackoff
  readonly #groupBuffer: UploadGroupBuffer
  readonly #inlineFinishTimeoutMs: number
  readonly #digests = new Map<number, RunningDigest>()
  /** Queued uploads; a group set means only those complete storage groups, `full` a whole pass. */
  readonly #queued = new Map<number, Set<number> | "full">()
  readonly #activeUploads = new Set<number>()
  readonly #claimControllers = new Map<number, AbortController>()
  readonly #tasks = new Set<Promise<void>>()
  readonly #cleanupTasks = new Set<Promise<void>>()
  #abort = new AbortController()
  #timer: ReturnType<typeof setInterval> | undefined
  #active = 0
  #pollPromise: Promise<void> | undefined
  #cleanupPromise: Promise<void> | undefined
  #drainPromise: Promise<void> | undefined
  #stopPromise: Promise<void> | undefined
  #lastCleanupStartedAt = Number.NEGATIVE_INFINITY
  #started = false

  constructor(
    private readonly repository: InlineUploadRepository,
    private readonly partStore: UploadPartStore,
    private readonly multipartStore: MultipartObjectStore,
    private readonly finalizer: MediaUploadFinalizer,
    options: WorkerOptions = {},
  ) {
    this.#concurrency = options.concurrency ?? DEFAULT_CONCURRENCY
    this.#pollIntervalMs = options.pollIntervalMs ?? DEFAULT_POLL_INTERVAL_MS
    this.#expiryCleanupIntervalMs = options.expiryCleanupIntervalMs ?? DEFAULT_EXPIRY_CLEANUP_INTERVAL_MS
    this.#leaseRenewTimeoutMs = options.leaseRenewTimeoutMs ?? DEFAULT_LEASE_RENEW_TIMEOUT_MS
    this.#shutdownDrainTimeoutMs = options.shutdownDrainTimeoutMs ?? DEFAULT_SHUTDOWN_DRAIN_TIMEOUT_MS
    this.#random = options.random ?? Math.random
    this.#groupBuffer = options.groupBuffer ?? new UploadGroupBuffer()
    this.#inlineFinishTimeoutMs = options.inlineFinishTimeoutMs ?? DEFAULT_INLINE_FINISH_TIMEOUT_MS
    if (!Number.isSafeInteger(this.#concurrency) || this.#concurrency < 1) throw new RangeError("Invalid worker concurrency")
    if (!Number.isSafeInteger(this.#pollIntervalMs) || this.#pollIntervalMs < 10 ||
        !Number.isSafeInteger(this.#expiryCleanupIntervalMs) || this.#expiryCleanupIntervalMs < 10 ||
        !Number.isSafeInteger(this.#leaseRenewTimeoutMs) || this.#leaseRenewTimeoutMs < 1 ||
        this.#leaseRenewTimeoutMs >= INLINE_UPLOAD_PROCESSING_LEASE_MS ||
        !Number.isSafeInteger(this.#shutdownDrainTimeoutMs) || this.#shutdownDrainTimeoutMs < 1) {
      throw new RangeError("Invalid upload worker interval")
    }
    this.#backoff = IdleBackoff.forInterval(this.#pollIntervalMs, options.maximumIdleIntervalMs)
  }

  /** Base intervals between claim polls; exposed for diagnostics and tests. */
  get idleMultiplier(): number {
    return this.#backoff.multiplier
  }

  start(): void {
    if (this.#started) return
    if (this.#stopPromise || this.#drainPromise) {
      throw new Error("Native upload worker is still draining")
    }
    this.#started = true
    this.#abort = new AbortController()
    // The timer keeps its base cadence; idle backoff only skips the claim
    // query on ticks that come before the next due poll. Expiry cleanup has
    // its own, longer interval.
    this.#timer = setInterval(() => {
      if (!this.#pollPromise && this.#backoff.due()) this.#requestPoll()
      this.#requestCleanup()
    }, this.#pollIntervalMs)
    this.#requestPoll()
    this.#requestCleanup()
  }

  async stop(): Promise<void> {
    if (this.#stopPromise) return this.#stopPromise
    if (!this.#started) return
    this.#started = false
    if (this.#timer) clearInterval(this.#timer)
    this.#timer = undefined
    this.#abort.abort(new DOMException("Native upload worker stopped", "AbortError"))
    const drain = (async () => {
      await this.#pollPromise?.catch(() => {})
      await this.#cleanupPromise?.catch(() => {})
      await Promise.allSettled(this.#tasks)
      await Promise.allSettled(this.#cleanupTasks)
    })()
    const trackedDrain = drain.finally(() => {
      if (this.#drainPromise === trackedDrain) this.#drainPromise = undefined
    })
    this.#drainPromise = trackedDrain
    const stopping = settlesWithin(trackedDrain, this.#shutdownDrainTimeoutMs).then((drained) => {
      if (!drained) {
        log.warn("Native upload worker shutdown drain timed out", {
          timeoutMs: this.#shutdownDrainTimeoutMs,
        })
      }
    })
    const trackedStop = stopping.finally(() => {
      if (this.#stopPromise === trackedStop) this.#stopPromise = undefined
    })
    this.#stopPromise = trackedStop
    return trackedStop
  }

  /**
   * Queues work for an upload. With `groupNumber` (a 1-based storage part
   * number), only that complete ten-frame group is compacted; without it the
   * upload gets a full pass (finish, cross-process resume).
   */
  wake(uploadDbId: number, groupNumber?: number): void {
    if (!Number.isSafeInteger(uploadDbId) || uploadDbId < 1) return
    const queued = this.#queued.get(uploadDbId)
    if (groupNumber === undefined || !Number.isSafeInteger(groupNumber) || groupNumber < 1) {
      this.#queued.set(uploadDbId, "full")
    } else if (queued === undefined) {
      this.#queued.set(uploadDbId, new Set([groupNumber]))
    } else if (queued !== "full") {
      queued.add(groupNumber)
    }
    this.#backoff.reset()
    if (this.#started) this.#pump()
  }

  cancel(uploadDbId: number): void {
    this.#queued.delete(uploadDbId)
    this.#forgetUpload(uploadDbId)
    this.#claimControllers.get(uploadDbId)?.abort(new UploadOwnershipLostError())
  }

  async discardStorage(upload: InlineUploadRecord, signal?: AbortSignal): Promise<void> {
    if (!upload.storageUploadId || !upload.resultFileUniqueId) return
    await this.multipartStore.abort(storageKeyFor(upload), upload.storageUploadId, signal)
  }

  #pump(): void {
    while (this.#started && this.#active < this.#concurrency) {
      const uploadDbId = Array.from(this.#queued.keys()).find((id) => !this.#activeUploads.has(id))
      if (uploadDbId === undefined) break
      const queued = this.#queued.get(uploadDbId)!
      this.#queued.delete(uploadDbId)
      this.#track(uploadDbId, queued === "full"
        ? () => this.#runUpload(uploadDbId)
        : () => this.#runGroups(uploadDbId, [...queued]))
    }
  }

  /**
   * Finalizes a small upload inside its FINISH_UPLOAD request when this process
   * still holds every group in memory. Returns `complete` when published within
   * the timeout, `running` when this process claimed the work and it continues as
   * an ordinary worker task (no wake is needed), and `processing` when nothing
   * was claimed here.
   */
  async processNow(
    upload: { id: number; partCount: number; kind: InlineUploadRecord["kind"] },
    signal?: AbortSignal,
  ): Promise<"complete" | "running" | "processing"> {
    if (!this.#started || this.#activeUploads.has(upload.id) || !this.#holdsInMemory(upload)) return "processing"
    const claim = await this.repository.claimProcessing(upload.id)
    if (!claim) return "processing"
    if (this.#activeUploads.has(upload.id)) {
      await this.repository.releaseProcessingClaim({ uploadDbId: claim.upload.id, lockToken: claim.lockToken })
        .catch(() => false)
      return "processing"
    }
    this.#queued.delete(upload.id)
    let published = false
    const task = this.#track(upload.id, async () => { published = await this.#processClaim(claim) })
    let timer: ReturnType<typeof setTimeout> | undefined
    let onAbort: (() => void) | undefined
    await Promise.race([
      task,
      new Promise<void>((resolve) => {
        timer = setTimeout(resolve, this.#inlineFinishTimeoutMs)
        onAbort = resolve
        signal?.addEventListener("abort", onAbort, { once: true })
      }),
    ])
    if (timer !== undefined) clearTimeout(timer)
    if (onAbort) signal?.removeEventListener("abort", onAbort)
    return published ? "complete" : "running"
  }

  /** Every group is either already in the running digest or fully buffered; photos need every frame. */
  #holdsInMemory(upload: { id: number; partCount: number; kind: InlineUploadRecord["kind"] }): boolean {
    if (bufferedPublicationNeedsBytes(upload.kind)) {
      return this.#groupBuffer.hasAll(upload.id, 0, upload.partCount)
    }
    const digest = this.#digests.get(upload.id)
    if (digest?.incomplete) return false
    return storagePartGeometry(upload.partCount).every((group) =>
      (digest !== undefined && group.partNumber < digest.nextGroup) ||
      this.#groupBuffer.hasAll(upload.id, group.firstFrameIndex, group.frameCount))
  }

  #forgetUpload(uploadDbId: number): void {
    this.#groupBuffer.drop(uploadDbId)
    this.#digests.delete(uploadDbId)
  }

  #digestFor(upload: InlineUploadRecord): RunningDigest | undefined {
    if (upload.storageFormat !== IDENTITY_STORAGE_FORMAT) return undefined
    let digest = this.#digests.get(upload.id)
    if (!digest) {
      digest = { hash: createHash("sha256"), nextGroup: 1, pending: new Map(), incomplete: false }
      this.#digests.set(upload.id, digest)
      while (this.#digests.size > MAX_RUNNING_DIGESTS) {
        const oldest = this.#digests.keys().next().value
        if (oldest === undefined) break
        this.#digests.delete(oldest)
      }
    }
    return digest
  }

  #feedDigest(upload: InlineUploadRecord, partNumber: number, bytes: Uint8Array): void {
    const digest = this.#digestFor(upload)
    if (!digest || digest.incomplete || partNumber < digest.nextGroup) return
    if (partNumber > digest.nextGroup) {
      digest.pending.set(partNumber, bytes)
      if (digest.pending.size > this.#concurrency) {
        digest.incomplete = true
        digest.pending.clear()
      }
      return
    }
    digest.hash.update(bytes)
    digest.nextGroup += 1
    for (let next = digest.pending.get(digest.nextGroup); next; next = digest.pending.get(digest.nextGroup)) {
      digest.pending.delete(digest.nextGroup)
      digest.hash.update(next)
      digest.nextGroup += 1
    }
  }

  #track(uploadDbId: number, run: () => Promise<void>): Promise<void> {
    this.#active += 1
    this.#activeUploads.add(uploadDbId)
    // Worker statements and storage operations count toward this process's
    // open trace for the upload, when it received the parts.
    const trace = transferTraces.get(uploadTraceKey(uploadDbId))
    const task = trace ? withTransferCounters(trace.counters, run) : run()
    const observed = task.catch((error) => {
      if (!this.#abort.signal.aborted) log.error("Native upload worker task failed", { error })
    }).finally(() => {
      this.#active -= 1
      this.#activeUploads.delete(uploadDbId)
      this.#tasks.delete(observed)
      this.#pump()
    })
    this.#tasks.add(observed)
    return observed
  }

  #trackCleanup(uploadDbId: number, task: Promise<void>): void {
    const observed = task.catch((error) => {
      if (!this.#abort.signal.aborted) {
        log.warn("Native upload staging cleanup incomplete", { error, uploadDbId })
      }
    }).finally(() => {
      this.#cleanupTasks.delete(observed)
    })
    this.#cleanupTasks.add(observed)
  }

  #requestPoll(): void {
    if (!this.#started || this.#pollPromise) return
    this.#pollPromise = this.#poll().finally(() => { this.#pollPromise = undefined })
  }

  #requestCleanup(): void {
    const now = Date.now()
    if (!this.#started || this.#cleanupPromise ||
        now - this.#lastCleanupStartedAt < this.#expiryCleanupIntervalMs) return
    this.#lastCleanupStartedAt = now
    this.#cleanupPromise = this.#cleanupExpired(this.#abort.signal)
      .catch((error) => {
        if (!this.#abort.signal.aborted) log.warn("Expired native upload cleanup failed", { error })
      })
      .finally(() => { this.#cleanupPromise = undefined })
  }

  async #cleanupExpired(signal: AbortSignal): Promise<void> {
    const expired = await this.repository.listExpired(EXPIRY_CLEANUP_BATCH_SIZE)
    let cleaned = 0
    for (const candidate of expired) {
      throwIfAborted(signal)
      const claim = await this.repository.claimExpiredCleanup(candidate.id)
      if (!claim) continue
      try {
        throwIfAborted(signal)
        this.#forgetUpload(claim.upload.id)
        const parts = await this.repository.parts(claim.upload.id)
        throwIfAborted(signal)
        await this.#removeStaging({ upload: claim.upload, parts, storageParts: [] }, signal)
        await this.discardStorage(claim.upload, signal)
        if (claim.upload.status !== "complete") {
          await this.finalizer.discardPublication(claim.upload)
        }
      } catch (error) {
        await this.repository.releaseCleanupClaim(claim.upload.id, claim.cleanupToken).catch(() => false)
        if (signal.aborted) throw error
        if (!signal.aborted) {
          log.warn("Expired native upload storage cleanup incomplete", {
            error,
            uploadDbId: claim.upload.id,
          })
        }
        continue
      }
      if (await this.repository.removeCleanupClaim(claim.upload.id, claim.cleanupToken)) cleaned += 1
    }
    if (expired.length > 0) {
      log.info("Expired native upload cleanup", { candidates: expired.length, cleaned })
    }
  }

  async #poll(): Promise<void> {
    let claimed = false
    try {
      this.#pump()
      while (this.#started && this.#active < this.#concurrency) {
        const claim = await this.repository.claimProcessing()
        if (!claim) break
        claimed = true
        if (this.#activeUploads.has(claim.upload.id)) {
          await this.repository.releaseProcessingClaim({
            uploadDbId: claim.upload.id,
            lockToken: claim.lockToken,
          })
          this.#queued.set(claim.upload.id, "full")
          break
        }
        if (!this.#started) {
          await this.repository.releaseProcessingClaim({
            uploadDbId: claim.upload.id,
            lockToken: claim.lockToken,
          })
          break
        }
        this.#track(claim.upload.id, async () => { await this.#processClaim(claim) })
      }
    } catch (error) {
      if (!this.#abort.signal.aborted) log.warn("Native upload worker poll failed", { error })
    } finally {
      this.#backoff.observe(claimed)
    }
  }

  async #runUpload(uploadDbId: number): Promise<void> {
    throwIfAborted(this.#abort.signal)
    const work = await this.repository.getStorageWork(uploadDbId)
    if (!this.#started || this.#abort.signal.aborted) return
    if (!work) return
    if (work.upload.status === "processing") {
      const claim = await this.repository.claimProcessing(uploadDbId)
      if (!claim) return
      if (!this.#started || this.#abort.signal.aborted) {
        await this.repository.releaseProcessingClaim({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
        }).catch(() => false)
        return
      }
      await this.#processClaim(claim)
      return
    }
    if (work.upload.storageFormat) {
      const claim = await this.repository.claimUploadingCompaction(uploadDbId)
      if (!claim) return
      await this.#processUploadingClaim(claim)
    }
  }

  /**
   * Compacts complete groups announced by part acceptance. Claims directly,
   * skipping the storage-work read; a finished or concurrently claimed upload
   * is left to the finish path, which compacts whatever remains.
   */
  async #runGroups(uploadDbId: number, groupNumbers: number[], attempt = 0): Promise<void> {
    throwIfAborted(this.#abort.signal)
    const claim = await this.repository.claimUploadingCompaction(uploadDbId)
    if (!claim) {
      if (attempt < GROUP_CLAIM_RETRIES && this.#started) {
        const retry = setTimeout(() => {
          if (!this.#started || this.#queued.get(uploadDbId) === "full") return
          if (this.#activeUploads.has(uploadDbId)) {
            for (const groupNumber of groupNumbers) this.wake(uploadDbId, groupNumber)
            return
          }
          this.#track(uploadDbId, () => this.#runGroups(uploadDbId, groupNumbers, attempt + 1))
        }, GROUP_CLAIM_RETRY_DELAY_MS * (attempt + 1))
        retry.unref?.()
      }
      return
    }
    if (!this.#started || this.#abort.signal.aborted) {
      await this.repository.releaseProcessingClaim({
        uploadDbId: claim.upload.id,
        lockToken: claim.lockToken,
      }).catch(() => false)
      return
    }
    await this.#processUploadingClaim(claim, groupNumbers)
  }

  #claimLease(claim: InlineUploadProcessingClaim) {
    const controller = new AbortController()
    this.#claimControllers.set(claim.upload.id, controller)
    const abortFromRoot = () => controller.abort(this.#abort.signal.reason)
    this.#abort.signal.addEventListener("abort", abortFromRoot, { once: true })
    if (this.#abort.signal.aborted) abortFromRoot()
    let heartbeatRenewal: Promise<void> | undefined
    let leaseLost = false
    const assertOwnership = async (): Promise<void> => {
      throwIfAborted(controller.signal)
      let renewed = false
      if (!leaseLost) {
        renewed = await this.repository.renew({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
        }, AbortSignal.any([
          controller.signal,
          AbortSignal.timeout(this.#leaseRenewTimeoutMs),
        ])).catch(() => false)
      }
      if (!renewed) {
        leaseLost = true
        controller.abort(new UploadOwnershipLostError())
        throw new UploadOwnershipLostError()
      }
    }
    const heartbeat = setInterval(() => {
      if (heartbeatRenewal || controller.signal.aborted) return
      heartbeatRenewal = assertOwnership().catch((error) => {
        leaseLost = true
        controller.abort(error)
      }).finally(() => { heartbeatRenewal = undefined })
    }, LEASE_RENEW_INTERVAL_MS)
    return {
      assertOwnership,
      controller,
      dispose: async () => {
        clearInterval(heartbeat)
        await heartbeatRenewal?.catch(() => {})
        this.#abort.signal.removeEventListener("abort", abortFromRoot)
        if (this.#claimControllers.get(claim.upload.id) === controller) this.#claimControllers.delete(claim.upload.id)
      },
    }
  }

  async #processUploadingClaim(claim: InlineUploadProcessingClaim, onlyGroups?: readonly number[]): Promise<void> {
    const lease = this.#claimLease(claim)
    try {
      await lease.assertOwnership()
      await this.#compact(claim, false, lease.controller.signal, claim.lockToken, onlyGroups)
    } catch (error) {
      await this.#discardCanceledWork(claim.upload.id)
      if (!(error instanceof MultipartUploadNotFoundError) &&
          !(error instanceof UploadOwnershipLostError) &&
          !this.#abort.signal.aborted && !lease.controller.signal.aborted) {
        log.warn("Native upload opportunistic compaction failed", {
          error,
          uploadDbId: claim.upload.id,
        })
      }
    } finally {
      await lease.dispose()
      await this.repository.releaseProcessingClaim({
        uploadDbId: claim.upload.id,
        lockToken: claim.lockToken,
      }).catch(() => false)
    }
  }

  /** Returns true when this call published the upload. */
  async #processClaim(claim: InlineUploadProcessingClaim): Promise<boolean> {
    if (!this.#started || this.#abort.signal.aborted) {
      await this.repository.releaseProcessingClaim({
        uploadDbId: claim.upload.id,
        lockToken: claim.lockToken,
      }).catch(() => false)
      return false
    }
    const startedAt = Date.now()
    const lease = this.#claimLease(claim)
    const { assertOwnership, controller } = lease
    let terminalWorkPromise: Promise<InlineUploadStorageWork> | undefined
    const terminalWork = (): Promise<InlineUploadStorageWork> =>
      terminalWorkPromise ??= this.repository.getStorageWork(claim.upload.id)
        .then((work) => work ?? claim)
        .catch(() => claim)

    try {
      const thumbnailPhotoId = claim.upload.thumbnailFileUniqueId
        ? await this.repository.completedPhotoId(claim.upload.thumbnailFileUniqueId, ownerFor(claim.upload))
        : undefined
      if (claim.upload.thumbnailFileUniqueId && !thumbnailPhotoId) throw new UploadInvalidMediaError()

      let publication
      if (!claim.upload.storageFormat) {
        publication = await this.finalizer.preparePublication({
          upload: claim.upload,
          parts: claim.parts,
          thumbnailPhotoId,
          assertOwnership,
          signal: controller.signal,
        })
      } else {
        let work: InlineUploadStorageWork = claim
        let resetCount = 0
        while (true) {
          try {
            work = await this.#compact(work, true, controller.signal, claim.lockToken)
            await this.#completeStorage(work, controller.signal, assertOwnership)
            break
          } catch (error) {
            if (!(error instanceof MultipartUploadNotFoundError) ||
                !work.upload.storageUploadId || resetCount++ >= 1) throw error
            const staleStorageUploadId = work.upload.storageUploadId
            if (!await this.repository.resetStorageSession({
              uploadDbId: work.upload.id,
              storageUploadId: staleStorageUploadId,
              lockToken: claim.lockToken,
            })) throw new UploadOwnershipLostError()
            await this.multipartStore.abort(
              storageKeyFor(work.upload),
              staleStorageUploadId,
              controller.signal,
            ).catch((abortError) => {
              if (!controller.signal.aborted) {
                log.warn("Native upload stale multipart session cleanup incomplete", {
                  error: abortError,
                  uploadDbId: work.upload.id,
                })
              }
            })
            work = { ...work, upload: { ...work.upload, storageUploadId: null }, storageParts: [] }
          }
        }
        publication = await this.#prepareStoredWork(work, thumbnailPhotoId, assertOwnership, controller.signal)
      }

      await assertOwnership()
      const completed = await this.repository.publishComplete({
        uploadDbId: claim.upload.id,
        lockToken: claim.lockToken,
        publication,
      })
      if (!completed) throw new UploadOwnershipLostError()
      this.#forgetUpload(claim.upload.id)
      transferTraces.finish(uploadTraceKey(claim.upload.id), "complete")
      log.info("UPLOAD_TRACE phase=worker_complete", {
        uploadDbId: claim.upload.id,
        kind: claim.upload.kind,
        logicalPartCount: claim.parts.length,
        storagePartCount: Math.ceil(claim.upload.partCount / STORAGE_FRAMES_PER_PART),
        attempt: claim.upload.attempts + 1,
        elapsedMs: Date.now() - startedAt,
      })
      this.#trackCleanup(
        claim.upload.id,
        this.#removeStaging(claim, this.#abort.signal),
      )
      return true
    } catch (error) {
      // Cancellation may have happened on another process or just before
      // shutdown. Clean a late object write before taking the shutdown path.
      if (await this.#discardCanceledWork(claim.upload.id)) return false
      if (controller.signal.aborted && this.#abort.signal.aborted) {
        await this.repository.releaseProcessingClaim({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
        }).catch(() => false)
        return false
      }
      if (error instanceof UploadOwnershipLostError) return false
      if (error instanceof UploadIntegrityError || error instanceof MultipartIntegrityError) {
        const cleanupWork = await terminalWork()
        const failed = await this.repository.fail({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
          code: "integrity",
          retryable: false,
        })
        if (failed) {
          this.#forgetUpload(claim.upload.id)
          transferTraces.finish(uploadTraceKey(claim.upload.id), "failed")
          await this.#discardTerminalStorage(cleanupWork, controller.signal)
        }
        return false
      }
      if (error instanceof UploadInvalidMediaError ||
          (error instanceof InlineError && error.code === 400)) {
        const cleanupWork = await terminalWork()
        const failed = await this.repository.fail({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
          code: "invalid_media",
          retryable: false,
        })
        if (failed) {
          this.#forgetUpload(claim.upload.id)
          transferTraces.finish(uploadTraceKey(claim.upload.id), "failed")
          await this.#discardTerminalStorage(cleanupWork, controller.signal)
        }
        return false
      }
      if (error instanceof InlineUploadPublicationConflictError) {
        const cleanupWork = await terminalWork()
        const failed = await this.repository.fail({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
          code: "publication_conflict",
          retryable: false,
        })
        if (failed) {
          this.#forgetUpload(claim.upload.id)
          transferTraces.finish(uploadTraceKey(claim.upload.id), "failed")
          await this.#discardTerminalStorage(cleanupWork, controller.signal)
        }
        return false
      }
      if (claim.upload.attempts + 1 >= MAX_PROCESSING_ATTEMPTS) {
        const cleanupWork = await terminalWork()
        const failed = await this.repository.fail({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
          code: error instanceof MultipartStorageUnavailableError ||
            error instanceof UploadPartStorageUnavailableError ? "storage" : "processing",
          retryable: true,
        })
        if (failed) {
          this.#forgetUpload(claim.upload.id)
          transferTraces.finish(uploadTraceKey(claim.upload.id), "failed")
          await this.#discardTerminalStorage(cleanupWork, controller.signal)
        }
        return false
      }
      const exponentialMs = Math.min(30_000, 500 * 2 ** claim.upload.attempts)
      const retryMs = Math.round(exponentialMs * (0.75 + this.#random() * 0.5))
      const scheduled = await this.repository.scheduleProcessingRetry({
        uploadDbId: claim.upload.id,
        lockToken: claim.lockToken,
        retryDelayMs: retryMs,
      })
      if (!scheduled) return false
      log.warn("Native upload finalization scheduled for retry", {
        error,
        uploadDbId: claim.upload.id,
        attempt: claim.upload.attempts + 1,
        retryMs,
      })
    } finally {
      await lease.dispose()
    }
    return false
  }

  async #compact(
    initialWork: InlineUploadStorageWork,
    includeTail: boolean,
    signal: AbortSignal,
    lockToken?: Uint8Array,
    onlyGroups?: readonly number[],
  ): Promise<InlineUploadStorageWork> {
    throwIfAborted(signal)
    const codec = storageCodecFor(initialWork.upload.storageFormat)
    if (!codec) throw new UploadIntegrityError()
    const sourceByIndex = new Map(initialWork.parts.map((part) => [part.partIndex, part]))
    const readyGroups: number[] = []
    const selectedGroups = onlyGroups ? new Set(onlyGroups) : undefined
    for (const geometry of storagePartGeometry(initialWork.upload.partCount)) {
      if (!includeTail && geometry.frameCount < STORAGE_FRAMES_PER_PART) continue
      if (selectedGroups && !selectedGroups.has(geometry.partNumber)) continue
      if (Array.from({ length: geometry.frameCount }, (_, offset) =>
        sourceByIndex.has(geometry.firstFrameIndex + offset)).every(Boolean)) {
        readyGroups.push(geometry.partNumber)
      }
    }
    if (readyGroups.length === 0) return initialWork

    let storageUploadId: string | undefined = initialWork.upload.storageUploadId ?? undefined
    const key = storageKeyFor(initialWork.upload)
    if (!storageUploadId) {
      const created = await this.multipartStore.create(key, initialWork.upload.mimeType, signal)
      let installed: { installed: boolean; storageUploadId?: string }
      try {
        installed = await this.repository.installStorageSession({
          uploadDbId: initialWork.upload.id,
          expectedStorageUploadId: null,
          storageUploadId: created,
          lockToken,
        })
      } catch (cause) {
        // The provider create precedes the DB manifest write. If the commit
        // response is lost, reconcile before deciding whether this session is
        // owned or safe to abort. DB unavailability leaves it for the bucket's
        // incomplete-multipart lifecycle rather than risking a committed owner.
        let reconciled: InlineUploadStorageWork | undefined
        try {
          reconciled = await this.repository.getStorageWork(initialWork.upload.id)
        } catch {
          throw cause
        }
        if (reconciled?.upload.storageUploadId === created) {
          installed = { installed: true, storageUploadId: created }
        } else {
          await this.multipartStore.abort(key, created, signal).catch(() => {})
          throw cause
        }
      }
      if (!installed.installed) await this.multipartStore.abort(key, created, signal).catch(() => {})
      storageUploadId = installed.storageUploadId
      if (!storageUploadId) throw new UploadOwnershipLostError()
    }

    const existing = new Map(initialWork.storageParts
      .filter((part) => part.storageUploadId === storageUploadId)
      .map((part) => [part.partNumber, part]))
    const digest = this.#digestFor(initialWork.upload)
    if (digest && !digest.incomplete) {
      // Groups recorded without this process hashing them can never join the digest.
      for (const partNumber of existing.keys()) {
        if (partNumber >= digest.nextGroup && !digest.pending.has(partNumber)) {
          digest.incomplete = true
          digest.pending.clear()
          break
        }
      }
    }
    // Photos keep their frames buffered for content validation at publication.
    const retainFrames = bufferedPublicationNeedsBytes(initialWork.upload.kind)
    const missing = readyGroups.filter((partNumber) => !existing.has(partNumber))
    await mapConcurrent(missing, this.#concurrency, async (partNumber, groupSignal) => {
      throwIfAborted(groupSignal)
      const start = (partNumber - 1) * STORAGE_FRAMES_PER_PART
      const end = Math.min(start + STORAGE_FRAMES_PER_PART, initialWork.upload.partCount)
      const frames = Array.from({ length: end - start }, (_, offset) => sourceByIndex.get(start + offset)!)
      const buffered = retainFrames
        ? this.#groupBuffer.peekGroup(initialWork.upload.id, start, frames.length)
        : this.#groupBuffer.takeGroup(initialWork.upload.id, start, frames.length)
      const chunks: Uint8Array[] = buffered ?? Array.from({ length: frames.length })
      if (buffered) {
        frames.forEach((part, index) => {
          const bytes = buffered[index]!
          if (bytes.byteLength !== part.storedByteCount ||
              !sameBytes(createHash("sha256").update(bytes).digest(), part.storedSha256)) {
            throw new UploadIntegrityError()
          }
        })
      } else await mapConcurrent(frames.map((part, index) => ({ part, index })), STAGING_READ_CONCURRENCY, async ({ part, index }, readSignal) => {
        const bytes = await this.partStore.read(part.objectKey, part.storedByteCount, readSignal)
          .catch((error) => {
            if (error instanceof FileByteLengthError) throw new UploadIntegrityError()
            throw error
          })
        if (bytes.byteLength !== part.storedByteCount ||
            !sameBytes(createHash("sha256").update(bytes).digest(), part.storedSha256)) {
          throw new UploadIntegrityError()
        }
        chunks[index] = bytes
      }, groupSignal)
      const bytes = Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)))
      const storedSha256 = createHash("sha256").update(bytes).digest()
      const uploaded = await this.multipartStore.uploadPart({
        key,
        uploadId: storageUploadId!,
        partNumber,
        bytes,
        signal: groupSignal,
      })
      const recorded = await this.repository.recordStoragePart({
        uploadDbId: initialWork.upload.id,
        storageUploadId: storageUploadId!,
        partNumber,
        storedByteCount: bytes.byteLength,
        storedSha256,
        etag: uploaded.etag,
        lockToken,
      })
      if (recorded === "stale") throw new UploadOwnershipLostError()
      this.#feedDigest(initialWork.upload, partNumber, bytes)
    }, signal)

    // A group pass only needed its own groups recorded; recordStoragePart fenced ownership.
    if (onlyGroups) return initialWork
    const refreshed = await this.repository.getStorageWork(initialWork.upload.id)
    if (!refreshed || refreshed.upload.storageUploadId !== storageUploadId) throw new UploadOwnershipLostError()
    return refreshed
  }

  /** Completes the multipart object and proves it equals the recorded groups. */
  async #completeStorage(
    work: InlineUploadStorageWork,
    signal: AbortSignal,
    assertOwnership: () => Promise<void>,
  ): Promise<void> {
    const key = storageKeyFor(work.upload)
    const storageUploadId = work.upload.storageUploadId
    if (!storageUploadId) throw new UploadIntegrityError()
    const expectedCount = Math.ceil(work.upload.partCount / STORAGE_FRAMES_PER_PART)
    if (work.storageParts.length !== expectedCount ||
        work.storageParts.some((part, index) => part.partNumber !== index + 1 ||
          part.storageUploadId !== storageUploadId)) throw new UploadIntegrityError()
    const parts: MultipartUploadedPart[] = work.storageParts.map((part) => ({
      etag: part.etag,
      partNumber: part.partNumber,
    }))
    const expectedByteCount = work.storageParts.reduce((total, part) => total + part.storedByteCount, 0)
    const expectedEtag = multipartEtag(parts)
    await assertOwnership()
    let head = await this.multipartStore.head(key, signal)
    if (!head) {
      await assertOwnership()
      const completed = await this.multipartStore.complete({ key, uploadId: storageUploadId, parts, signal })
      if (completed.etag !== expectedEtag) throw new MultipartIntegrityError()
      head = await this.multipartStore.head(key, signal)
    }
    if (!head || head.byteCount !== expectedByteCount || head.etag !== expectedEtag) {
      throw new MultipartIntegrityError()
    }
  }

  /**
   * The multipart ETag proves the stored object is the concatenation of the
   * recorded group bodies; each frame was checked against its manifest digest
   * at receipt and again before its group was uploaded. A running digest over
   * those same bodies in order is therefore the stored object's digest, and the
   * object need not be read back. Otherwise, read and verify it as before.
   */
  async #prepareStoredWork(
    work: InlineUploadStorageWork,
    thumbnailPhotoId: number | undefined,
    assertOwnership: () => Promise<void>,
    signal: AbortSignal,
  ) {
    const upload = work.upload
    const digest = this.#digests.get(upload.id)
    const groupCount = Math.ceil(upload.partCount / STORAGE_FRAMES_PER_PART)
    if (digest && !digest.incomplete && digest.nextGroup === groupCount + 1) {
      this.#digests.delete(upload.id)
      if (!sameBytes(digest.hash.digest(), upload.sha256)) throw new UploadIntegrityError()
      const needsBytes = bufferedPublicationNeedsBytes(upload.kind)
      const frames = needsBytes ? this.#groupBuffer.peekGroup(upload.id, 0, upload.partCount) : undefined
      if (!needsBytes || frames) {
        return await this.finalizer.prepareBufferedPublication({
          upload,
          frames,
          thumbnailPhotoId,
          assertOwnership,
          signal,
        })
      }
    }
    const codec = storageCodecFor(upload.storageFormat)
    if (!codec) throw new UploadIntegrityError()
    await assertOwnership()
    const storedStream = await this.multipartStore.stream(storageKeyFor(upload), signal)
    return await this.finalizer.prepareStoredPublication({
      upload,
      stream: codec.decodeObject(storedStream, {
        uploadId: Uint8Array.from(upload.uploadId),
        logicalByteCount: upload.byteCount,
        logicalSha256: Uint8Array.from(upload.sha256),
        frames: work.parts.map((part) => ({
          uploadId: Uint8Array.from(upload.uploadId),
          partIndex: part.partIndex,
          logicalByteCount: part.byteCount,
          logicalSha256: part.sha256,
          storedByteCount: part.storedByteCount,
          storedSha256: part.storedSha256,
        })),
      }),
      thumbnailPhotoId,
      assertOwnership,
      signal,
    })
  }

  async #discardTerminalStorage(work: InlineUploadStorageWork, signal: AbortSignal): Promise<void> {
    const upload = work.upload
    if (upload.resultFileUniqueId) {
      const key = storageKeyFor(upload)
      if (upload.storageUploadId) {
        await this.multipartStore.abort(key, upload.storageUploadId, signal).catch(() => {})
      }
      await this.multipartStore.remove(key, signal).catch(() => {})
    }
    await this.#removeStaging(work, signal).catch(() => {})
  }

  async #discardCanceledWork(uploadDbId: number): Promise<boolean> {
    const work = await this.repository.getCanceledStorageWork(uploadDbId).catch(() => undefined)
    if (work?.upload.status !== "canceled" || work.upload.resultMediaId !== null) return false
    this.#forgetUpload(uploadDbId)
    // Do not reuse the revoked claim's signal for cleanup. Permanent media
    // from a committed publication is excluded by the durable state check.
    await this.#discardTerminalStorage(work, AbortSignal.timeout(CANCELED_UPLOAD_CLEANUP_TIMEOUT_MS))
    return true
  }

  async #removeStaging(work: InlineUploadStorageWork, signal: AbortSignal): Promise<void> {
    if (this.partStore.removeMany) {
      await this.partStore.removeMany(work.parts.map((part) => part.objectKey), signal)
      return
    }
    await mapConcurrent(
      work.parts,
      16,
      async (part, cleanupSignal) => this.partStore.remove(part.objectKey, cleanupSignal),
      signal,
    )
  }
}

class UploadOwnershipLostError extends Error {
  constructor() {
    super("Native upload worker ownership was lost")
    this.name = "UploadOwnershipLostError"
  }
}
