import { createHash } from "node:crypto"
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
import { Log } from "@in/server/utils/log"
import {
  UploadIntegrityError,
  UploadInvalidMediaError,
  type MediaUploadFinalizer,
} from "./finalizer"
import {
  MultipartIntegrityError,
  MultipartStorageUnavailableError,
  MultipartUploadNotFoundError,
  multipartEtag,
  type MultipartObjectStore,
  type MultipartUploadedPart,
} from "./multipartStore"
import { UploadPartStorageUnavailableError, type UploadPartStore } from "./partStore"
import { storageCodecFor } from "./storageCodec"

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
const EXPIRY_CLEANUP_BATCH_SIZE = 100

type WorkerOptions = {
  concurrency?: number
  expiryCleanupIntervalMs?: number
  leaseRenewTimeoutMs?: number
  pollIntervalMs?: number
  random?: () => number
  shutdownDrainTimeoutMs?: number
}

export type StoragePartGeometry = {
  partNumber: number
  firstFrameIndex: number
  frameCount: number
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
  readonly #queued = new Set<number>()
  readonly #activeUploads = new Set<number>()
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
    if (!Number.isSafeInteger(this.#concurrency) || this.#concurrency < 1) throw new RangeError("Invalid worker concurrency")
    if (!Number.isSafeInteger(this.#pollIntervalMs) || this.#pollIntervalMs < 10 ||
        !Number.isSafeInteger(this.#expiryCleanupIntervalMs) || this.#expiryCleanupIntervalMs < 10 ||
        !Number.isSafeInteger(this.#leaseRenewTimeoutMs) || this.#leaseRenewTimeoutMs < 1 ||
        this.#leaseRenewTimeoutMs >= INLINE_UPLOAD_PROCESSING_LEASE_MS ||
        !Number.isSafeInteger(this.#shutdownDrainTimeoutMs) || this.#shutdownDrainTimeoutMs < 1) {
      throw new RangeError("Invalid upload worker interval")
    }
  }

  start(): void {
    if (this.#started) return
    if (this.#stopPromise || this.#drainPromise) {
      throw new Error("Native upload worker is still draining")
    }
    this.#started = true
    this.#abort = new AbortController()
    this.#timer = setInterval(() => {
      this.#requestPoll()
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

  wake(uploadDbId: number): void {
    if (!Number.isSafeInteger(uploadDbId) || uploadDbId < 1) return
    this.#queued.add(uploadDbId)
    if (this.#started) this.#pump()
  }

  async discardStorage(upload: InlineUploadRecord, signal?: AbortSignal): Promise<void> {
    if (!upload.storageUploadId || !upload.resultFileUniqueId) return
    await this.multipartStore.abort(storageKeyFor(upload), upload.storageUploadId, signal)
  }

  #pump(): void {
    while (this.#started && this.#active < this.#concurrency) {
      const uploadDbId = Array.from(this.#queued).find((id) => !this.#activeUploads.has(id))
      if (uploadDbId === undefined) break
      this.#queued.delete(uploadDbId)
      this.#track(uploadDbId, this.#runUpload(uploadDbId))
    }
  }

  #track(uploadDbId: number, task: Promise<void>): void {
    this.#active += 1
    this.#activeUploads.add(uploadDbId)
    const observed = task.catch((error) => {
      if (!this.#abort.signal.aborted) log.error("Native upload worker task failed", { error })
    }).finally(() => {
      this.#active -= 1
      this.#activeUploads.delete(uploadDbId)
      this.#tasks.delete(observed)
      this.#pump()
    })
    this.#tasks.add(observed)
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
    try {
      this.#pump()
      while (this.#started && this.#active < this.#concurrency) {
        const claim = await this.repository.claimProcessing()
        if (!claim) break
        if (this.#activeUploads.has(claim.upload.id)) {
          await this.repository.releaseProcessingClaim({
            uploadDbId: claim.upload.id,
            lockToken: claim.lockToken,
          })
          this.#queued.add(claim.upload.id)
          break
        }
        if (!this.#started) {
          await this.repository.releaseProcessingClaim({
            uploadDbId: claim.upload.id,
            lockToken: claim.lockToken,
          })
          break
        }
        this.#track(claim.upload.id, this.#processClaim(claim))
      }
    } catch (error) {
      if (!this.#abort.signal.aborted) log.warn("Native upload worker poll failed", { error })
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

  #claimLease(claim: InlineUploadProcessingClaim) {
    const controller = new AbortController()
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
      },
    }
  }

  async #processUploadingClaim(claim: InlineUploadProcessingClaim): Promise<void> {
    const lease = this.#claimLease(claim)
    try {
      await lease.assertOwnership()
      await this.#compact(claim, false, lease.controller.signal, claim.lockToken)
    } catch (error) {
      if (!(error instanceof MultipartUploadNotFoundError) &&
          !(error instanceof UploadOwnershipLostError) &&
          !this.#abort.signal.aborted) {
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

  async #processClaim(claim: InlineUploadProcessingClaim): Promise<void> {
    if (!this.#started || this.#abort.signal.aborted) {
      await this.repository.releaseProcessingClaim({
        uploadDbId: claim.upload.id,
        lockToken: claim.lockToken,
      }).catch(() => false)
      return
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
        let storedStream: ReadableStream<Uint8Array>
        while (true) {
          try {
            work = await this.#compact(work, true, controller.signal, claim.lockToken)
            storedStream = await this.#completeAndStream(work, controller.signal, assertOwnership)
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
        const codec = storageCodecFor(work.upload.storageFormat)
        if (!codec) throw new UploadIntegrityError()
        publication = await this.finalizer.prepareStoredPublication({
          upload: work.upload,
          stream: codec.decodeObject(storedStream, {
            uploadId: Uint8Array.from(work.upload.uploadId),
            logicalByteCount: work.upload.byteCount,
            logicalSha256: Uint8Array.from(work.upload.sha256),
            frames: work.parts.map((part) => ({
              uploadId: Uint8Array.from(work.upload.uploadId),
              partIndex: part.partIndex,
              logicalByteCount: part.byteCount,
              logicalSha256: part.sha256,
              storedByteCount: part.storedByteCount,
              storedSha256: part.storedSha256,
            })),
          }),
          thumbnailPhotoId,
          assertOwnership,
          signal: controller.signal,
        })
      }

      await assertOwnership()
      const completed = await this.repository.publishComplete({
        uploadDbId: claim.upload.id,
        lockToken: claim.lockToken,
        publication,
      })
      if (!completed) throw new UploadOwnershipLostError()
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
    } catch (error) {
      if (controller.signal.aborted && this.#abort.signal.aborted) {
        await this.repository.releaseProcessingClaim({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
        }).catch(() => false)
        return
      }
      if (error instanceof UploadOwnershipLostError) return
      if (error instanceof UploadIntegrityError || error instanceof MultipartIntegrityError) {
        const cleanupWork = await terminalWork()
        const failed = await this.repository.fail({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
          code: "integrity",
          retryable: false,
        })
        if (failed) await this.#discardTerminalStorage(cleanupWork, controller.signal)
        return
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
        if (failed) await this.#discardTerminalStorage(cleanupWork, controller.signal)
        return
      }
      if (error instanceof InlineUploadPublicationConflictError) {
        const cleanupWork = await terminalWork()
        const failed = await this.repository.fail({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
          code: "publication_conflict",
          retryable: false,
        })
        if (failed) await this.#discardTerminalStorage(cleanupWork, controller.signal)
        return
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
        if (failed) await this.#discardTerminalStorage(cleanupWork, controller.signal)
        return
      }
      const exponentialMs = Math.min(30_000, 500 * 2 ** claim.upload.attempts)
      const retryMs = Math.round(exponentialMs * (0.75 + this.#random() * 0.5))
      const scheduled = await this.repository.scheduleProcessingRetry({
        uploadDbId: claim.upload.id,
        lockToken: claim.lockToken,
        retryDelayMs: retryMs,
      })
      if (!scheduled) return
      log.warn("Native upload finalization scheduled for retry", {
        error,
        uploadDbId: claim.upload.id,
        attempt: claim.upload.attempts + 1,
        retryMs,
      })
    } finally {
      await lease.dispose()
    }
  }

  async #compact(
    initialWork: InlineUploadStorageWork,
    includeTail: boolean,
    signal: AbortSignal,
    lockToken?: Uint8Array,
  ): Promise<InlineUploadStorageWork> {
    throwIfAborted(signal)
    const codec = storageCodecFor(initialWork.upload.storageFormat)
    if (!codec) throw new UploadIntegrityError()
    const sourceByIndex = new Map(initialWork.parts.map((part) => [part.partIndex, part]))
    const readyGroups: number[] = []
    for (const geometry of storagePartGeometry(initialWork.upload.partCount)) {
      if (!includeTail && geometry.frameCount < STORAGE_FRAMES_PER_PART) continue
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
    const missing = readyGroups.filter((partNumber) => !existing.has(partNumber))
    await mapConcurrent(missing, this.#concurrency, async (partNumber, groupSignal) => {
      throwIfAborted(groupSignal)
      const start = (partNumber - 1) * STORAGE_FRAMES_PER_PART
      const end = Math.min(start + STORAGE_FRAMES_PER_PART, initialWork.upload.partCount)
      const frames = Array.from({ length: end - start }, (_, offset) => sourceByIndex.get(start + offset)!)
      const chunks: Uint8Array[] = Array.from({ length: frames.length })
      await mapConcurrent(frames.map((part, index) => ({ part, index })), STAGING_READ_CONCURRENCY, async ({ part, index }, readSignal) => {
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
    }, signal)

    const refreshed = await this.repository.getStorageWork(initialWork.upload.id)
    if (!refreshed || refreshed.upload.storageUploadId !== storageUploadId) throw new UploadOwnershipLostError()
    return refreshed
  }

  async #completeAndStream(
    work: InlineUploadStorageWork,
    signal: AbortSignal,
    assertOwnership: () => Promise<void>,
  ): Promise<ReadableStream<Uint8Array>> {
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
    await assertOwnership()
    return this.multipartStore.stream(key, signal)
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

  async #removeStaging(work: InlineUploadStorageWork, signal: AbortSignal): Promise<void> {
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
