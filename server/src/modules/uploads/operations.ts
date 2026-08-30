import {
  UploadFailure_Code,
  UploadKind,
  UploadStatus,
  type CancelUploadInput,
  type CancelUploadResult,
  type CreateUploadInput,
  type CreateUploadResult,
  type FinishUploadInput,
  type FinishUploadResult,
  type GetUploadStateInput,
  type GetUploadStateResult,
  type SaveUploadPartInput,
  type SaveUploadPartResult,
  type UploadFailure,
} from "@inline-chat/protocol/core"
import { createHash } from "node:crypto"
import { setTimeout as delay } from "node:timers/promises"
import { MAX_FILE_SIZE } from "@in/server/config"
import { MEDIA_UPLOAD_MAX_BYTES } from "@in/server/modules/files/metadata"
import {
  INLINE_UPLOAD_MAX_PARTS,
  InlineUploadAdmissionCapacityError,
  InlineUploadAdmissionOwnerInvalidError,
  InlineUploadMetadataConflictError,
  InlineUploadPublicationConflictError,
  InlineUploadRepository,
  type InlineUploadKind,
  type InlineUploadMetadata,
  type InlineUploadOwner,
  type InlineUploadRecord,
} from "@in/server/db/models/inlineUploads"
import { InlineError } from "@in/server/types/errors"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Log } from "@in/server/utils/log"
import {
  UploadIntegrityError,
  UploadFinalizationOwnershipLostError,
  UploadMediaFinalizer,
  type MediaUploadFinalizer,
} from "./finalizer"
import {
  R2UploadPartStore,
  UploadPartStorageUnavailableError,
  type UploadPartStore,
} from "./partStore"

const log = new Log("modules/uploads")
const RETRY_AFTER_SECONDS = 2
const MAX_WAVEFORM_BYTES = 2_048
const CLEANUP_BATCH_SIZE = 100
// Deletes carry no file buffers; allow a wider bounded window so successful
// finalization does not serialize hundreds of cleanup round trips.
const CLEANUP_PART_CONCURRENCY = 16
const CLEANUP_MIN_INTERVAL_MS = 60_000
const MAX_ACTIVE_UPLOADS_PER_SESSION = 20
const MAX_ACTIVE_RESERVED_UPLOAD_BYTES_PER_SESSION = 2n * 1_024n * 1_024n * 1_024n
const MAX_CONCURRENT_FINALIZERS = 4
const FINALIZER_LEASE_RENEW_INTERVAL_MS = 60_000

const kindFor = (kind: UploadKind): InlineUploadKind | undefined => {
  switch (kind) {
    case UploadKind.PHOTO: return "photo"
    case UploadKind.VIDEO: return "video"
    case UploadKind.DOCUMENT: return "document"
    case UploadKind.VOICE: return "voice"
    default: return undefined
  }
}

const badRequest = (): never => {
  throw RealtimeRpcError.BadRequest()
}

const ownerUnavailable = (phase: "resolve" | "admission", carrier: "v2" | "v3"): never => {
  log.warn("Native upload owner validation failed", { phase, carrier })
  throw RealtimeRpcError.InternalError()
}

const requireValue = <T>(value: T | undefined): T => value ?? badRequest()

const throwIfAborted = (signal: AbortSignal | undefined): void => {
  if (signal?.aborted) throw signal.reason ?? new DOMException("The operation was aborted", "AbortError")
}

const validateCreate = (input: CreateUploadInput): InlineUploadMetadata => {
  const kind = kindFor(input.kind)
  const fileName = input.fileName.trim()
  const mimeType = input.mimeType.trim().toLowerCase()
  if (!kind || input.clientUploadId.length !== 16 || input.sha256.length !== 32 ||
      !fileName || fileName.length > 255 || fileName.includes("\0") ||
      !mimeType || mimeType.length > 255 || input.byteCount <= 0n ||
      input.byteCount > BigInt(Math.min(MAX_FILE_SIZE, MEDIA_UPLOAD_MAX_BYTES[kind]))) return badRequest()
  const partCount = Number((input.byteCount + 524_287n) / 524_288n)
  if (partCount < 1 || partCount > INLINE_UPLOAD_MAX_PARTS) return badRequest()
  if (input.thumbnailFileUniqueId !== undefined &&
      (input.thumbnailFileUniqueId.length < 1 || input.thumbnailFileUniqueId.length > 128 ||
       (kind !== "video" && kind !== "document"))) return badRequest()

  let metadata: InlineUploadMetadata = {
    clientUploadId: input.clientUploadId.slice(),
    fileName,
    mimeType,
    byteCount: input.byteCount,
    sha256: input.sha256.slice(),
    kind,
    thumbnailFileUniqueId: input.thumbnailFileUniqueId,
  }
  switch (kind) {
    case "video": {
      const encodedMetadata = input.metadata
      if (encodedMetadata.oneofKind !== "video") return badRequest()
      const video = encodedMetadata.video
      if (video.width < 1 || video.height < 1 ||
          (video.isAnimated && video.hasAudio === true)) return badRequest()
      metadata = {
        ...metadata,
        videoWidth: video.width,
        videoHeight: video.height,
        duration: video.duration,
        isAnimated: video.isAnimated,
        hasAudio: video.hasAudio,
      }
      break
    }
    case "voice": {
      const encodedMetadata = input.metadata
      if (encodedMetadata.oneofKind !== "voice" ||
          encodedMetadata.voice.waveform.length > MAX_WAVEFORM_BYTES) return badRequest()
      metadata = {
        ...metadata,
        duration: encodedMetadata.voice.duration,
        waveform: encodedMetadata.voice.waveform.slice(),
      }
      break
    }
    default:
      if (input.metadata.oneofKind !== undefined) return badRequest()
  }
  return metadata
}

const failure = (code: UploadFailure_Code, retryable: boolean): UploadFailure => ({ code, retryable })

const failureForRow = (upload: InlineUploadRecord): UploadFailure => {
  switch (upload.failureCode) {
    case "integrity": return failure(UploadFailure_Code.UPLOAD_FAILURE_INTEGRITY, false)
    case "invalid_media": return failure(UploadFailure_Code.UPLOAD_FAILURE_INVALID_MEDIA, false)
    case "storage": return failure(UploadFailure_Code.UPLOAD_FAILURE_STORAGE, upload.failureRetryable ?? true)
    default: return failure(UploadFailure_Code.UPLOAD_FAILURE_PROCESSING, upload.failureRetryable ?? false)
  }
}

export class NativeUploadOperations {
  #cleanupPromise: Promise<void> | undefined
  #lastCleanupStartedAt = 0
  #activeFinalizers = 0

  constructor(
    private readonly repository: InlineUploadRepository,
    private readonly partStore: UploadPartStore,
    private readonly finalizer: MediaUploadFinalizer,
  ) {}

  async create(input: CreateUploadInput, context: HandlerContext): Promise<CreateUploadResult> {
    throwIfAborted(context.signal)
    const metadata = validateCreate(input)
    this.#scheduleCleanup()
    const owner = await this.#owner(context)
    throwIfAborted(context.signal)
    let result
    try {
      result = await this.repository.create(owner, metadata, {
        maxActiveCount: MAX_ACTIVE_UPLOADS_PER_SESSION,
        maxReservedBytes: MAX_ACTIVE_RESERVED_UPLOAD_BYTES_PER_SESSION,
      })
    } catch (error) {
      if (error instanceof InlineUploadMetadataConflictError) badRequest()
      if (error instanceof InlineUploadAdmissionCapacityError) throw RealtimeRpcError.RateLimit()
      if (error instanceof InlineUploadAdmissionOwnerInvalidError) {
        ownerUnavailable("admission", context.inlineProtocol ? "v3" : "v2")
      }
      throw error
    }
    return {
      uploadId: Uint8Array.from(result.upload.uploadId),
      partSize: result.upload.partSize,
      partCount: result.upload.partCount,
      expiresAt: BigInt(Math.floor(result.upload.expiresAt.getTime() / 1_000)),
      acceptedParts: result.upload.acceptedParts,
    }
  }

  async savePart(input: SaveUploadPartInput, context: HandlerContext): Promise<SaveUploadPartResult> {
    throwIfAborted(context.signal)
    if (input.uploadId.length !== 16 || !Number.isInteger(input.partIndex) || input.partIndex < 0) return badRequest()
    const startedAt = Date.now()
    this.#scheduleCleanup()
    const owner = await this.#owner(context)
    const ownerDoneAt = Date.now()
    const upload = requireValue(await this.repository.getPartTarget(input.uploadId, owner))
    throwIfAborted(context.signal)
    const uploadLookupDoneAt = Date.now()
    if (upload.status !== "uploading" || upload.expiresAt <= new Date() ||
        upload.hardExpiresAt <= new Date() ||
        input.partIndex >= upload.partCount) return badRequest()
    const expected = input.partIndex === upload.partCount - 1
      ? Number(upload.byteCount - BigInt(upload.partSize) * BigInt(upload.partCount - 1))
      : upload.partSize
    if (input.data.length !== expected) return badRequest()
    const sha256 = createHash("sha256").update(input.data).digest()
    const hashDoneAt = Date.now()
    const existing = await this.repository.getPart(upload.id, input.partIndex)
    const existingLookupDoneAt = Date.now()
    if (existing) {
      if (existing.byteCount !== input.data.length ||
          !Buffer.from(existing.sha256).equals(sha256)) return badRequest()
      log.debug("UPLOAD_TRACE phase=save_part_done", {
        outcome: "already_present",
        partIndex: input.partIndex,
        byteCount: input.data.length,
        ownerMs: ownerDoneAt - startedAt,
        uploadLookupMs: uploadLookupDoneAt - ownerDoneAt,
        hashMs: hashDoneAt - uploadLookupDoneAt,
        existingLookupMs: existingLookupDoneAt - hashDoneAt,
        objectStoreMs: 0,
        acceptMs: 0,
        elapsedMs: Date.now() - startedAt,
      })
      return { alreadyPresent: true }
    }
    const objectStoreStartedAt = Date.now()
    throwIfAborted(context.signal)
    const objectKey = await this.partStore.put({
      uploadId: input.uploadId,
      partIndex: input.partIndex,
      sha256,
      data: input.data,
    })
    const objectStoreDoneAt = Date.now()
    let accepted
    try {
      accepted = await this.repository.acceptPart({
        upload,
        partIndex: input.partIndex,
        byteCount: input.data.length,
        sha256,
        objectKey,
      })
    } catch (error) {
      // A lost commit response is not a rollback. Only a positive matching
      // manifest can resolve it; absence cannot authorize deletion while an
      // identical concurrent save may still be about to commit this same key.
      const manifested = await this.repository.getPart(upload.id, input.partIndex).catch(() => undefined)
      if (!manifested || manifested.objectKey !== objectKey || manifested.byteCount !== input.data.length ||
          !Buffer.from(manifested.sha256).equals(sha256)) throw error
      accepted = { kind: "already-present" as const, durableObjectKey: objectKey }
    }
    const acceptDoneAt = Date.now()
    if (accepted.durableObjectKey !== objectKey) {
      // The object-store write happens before the manifest transaction. Remove
      // only the key that transaction proved has no durable owner; a matching
      // key may belong to a concurrent/repeated accepted part.
      await this.partStore.remove(objectKey).catch((error) => {
        log.warn("Upload unowned staging object cleanup failed", { error })
      })
    }
    if (accepted.kind === "conflict" || accepted.kind === "terminal") {
      return badRequest()
    }
    log.debug("UPLOAD_TRACE phase=save_part_done", {
      outcome: accepted.kind === "already-present" ? "already_present_race" : "accepted",
      partIndex: input.partIndex,
      byteCount: input.data.length,
      ownerMs: ownerDoneAt - startedAt,
      uploadLookupMs: uploadLookupDoneAt - ownerDoneAt,
      hashMs: hashDoneAt - uploadLookupDoneAt,
      existingLookupMs: existingLookupDoneAt - hashDoneAt,
      objectStoreMs: objectStoreDoneAt - objectStoreStartedAt,
      acceptMs: acceptDoneAt - objectStoreDoneAt,
      elapsedMs: acceptDoneAt - startedAt,
    })
    return { alreadyPresent: accepted.kind === "already-present" }
  }

  async state(input: GetUploadStateInput, context: HandlerContext): Promise<GetUploadStateResult> {
    this.#scheduleCleanup()
    const owner = await this.#owner(context)
    const upload = requireValue(await this.repository.get(input.uploadId, owner))
    if (upload.expiresAt <= new Date() || upload.hardExpiresAt <= new Date()) {
      return { status: UploadStatus.EXPIRED, acceptedParts: upload.acceptedParts }
    }
    switch (upload.status) {
      case "uploading":
        return { status: UploadStatus.UPLOADING, acceptedParts: upload.acceptedParts }
      case "processing":
        return { status: UploadStatus.PROCESSING, acceptedParts: upload.acceptedParts }
      case "canceled":
        return { status: UploadStatus.CANCELED, acceptedParts: upload.acceptedParts }
      case "failed":
        return {
          status: UploadStatus.FAILED,
          acceptedParts: upload.acceptedParts,
          failure: failureForRow(upload),
        }
      case "complete":
        if (!upload.resultFileUniqueId || !upload.resultMediaId) throw RealtimeRpcError.InternalError()
        return {
          status: UploadStatus.COMPLETE,
          acceptedParts: upload.acceptedParts,
          complete: await this.finalizer.project(upload.kind, upload.resultFileUniqueId, upload.resultMediaId),
        }
      default:
        throw RealtimeRpcError.InternalError()
    }
  }

  async finish(input: FinishUploadInput, context: HandlerContext): Promise<FinishUploadResult> {
    this.#scheduleCleanup()
    const startedAt = Date.now()
    throwIfAborted(context.signal)
    const owner = await this.#owner(context)
    throwIfAborted(context.signal)
    const claim = await this.repository.claimFinish(input.uploadId, owner)
    switch (claim.kind) {
      case "rejected": return badRequest()
      case "missing":
        return { state: { oneofKind: "missing", missing: { partIndices: claim.partIndices } } }
      case "processing":
        return { state: { oneofKind: "processing", processing: { retryAfterSeconds: RETRY_AFTER_SECONDS } } }
      case "failed":
        return { state: { oneofKind: "failed", failed: failureForRow(claim.upload) } }
      case "complete": {
        const upload = claim.upload
        if (!upload.resultFileUniqueId || !upload.resultMediaId) throw RealtimeRpcError.InternalError()
        return {
          state: {
            oneofKind: "complete",
            complete: await this.finalizer.project(upload.kind, upload.resultFileUniqueId, upload.resultMediaId),
          },
        }
      }
      case "claimed":
        break
    }

    if (this.#activeFinalizers >= MAX_CONCURRENT_FINALIZERS) {
      await this.repository.release({ uploadDbId: claim.upload.id, lockToken: claim.lockToken })
      return { state: { oneofKind: "processing", processing: { retryAfterSeconds: RETRY_AFTER_SECONDS } } }
    }
    // The claim is released if cancellation wins before publication starts.
    // Once preparePublication begins, the object-store write is an
    // irreversible boundary and an abort must not be interpreted as rollback.
    if (context.signal?.aborted) {
      await this.repository.release({ uploadDbId: claim.upload.id, lockToken: claim.lockToken })
      throwIfAborted(context.signal)
    }
    this.#activeFinalizers += 1
    const leaseAbort = new AbortController()
    let leaseLost = false
    const renewLease = async (): Promise<void> => {
      if (leaseLost || !await this.repository.renew({
        uploadDbId: claim.upload.id,
        lockToken: claim.lockToken,
      })) {
        leaseLost = true
        throw new UploadFinalizationOwnershipLostError()
      }
    }
    const leaseHeartbeat = (async () => {
      while (!leaseAbort.signal.aborted) {
        try {
          await delay(FINALIZER_LEASE_RENEW_INTERVAL_MS, undefined, { signal: leaseAbort.signal })
        } catch (error) {
          if (leaseAbort.signal.aborted) return
          leaseLost = true
          log.warn("Upload finalization lease heartbeat failed", { error })
          return
        }
        try {
          await renewLease()
        } catch (error) {
          leaseLost = true
          log.warn("Upload finalization lease was lost", { error })
          return
        }
      }
    })()

    try {
      const thumbnailPhotoId = claim.upload.thumbnailFileUniqueId
        ? await this.repository.completedPhotoId(claim.upload.thumbnailFileUniqueId, owner)
        : undefined
      if (claim.upload.thumbnailFileUniqueId && !thumbnailPhotoId) {
        const failed = await this.repository.fail({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
          code: "invalid_media",
          retryable: false,
        })
        if (!failed) return { state: { oneofKind: "processing", processing: { retryAfterSeconds: RETRY_AFTER_SECONDS } } }
        return { state: { oneofKind: "failed", failed: failure(UploadFailure_Code.UPLOAD_FAILURE_INVALID_MEDIA, false) } }
      }
      const finalizerStartedAt = Date.now()
      const publication = await this.finalizer.preparePublication({
        upload: claim.upload,
        parts: claim.parts,
        thumbnailPhotoId,
        assertOwnership: renewLease,
        signal: context.signal,
      })
      const finalizedAt = Date.now()
      const result = await this.repository.publishComplete({
        uploadDbId: claim.upload.id,
        lockToken: claim.lockToken,
        publication,
      })
      if (!result) {
        return { state: { oneofKind: "processing", processing: { retryAfterSeconds: RETRY_AFTER_SECONDS } } }
      }
      leaseAbort.abort()
      const complete = await this.finalizer.project(claim.upload.kind, result.fileUniqueId, result.mediaId)
      const completedAt = Date.now()
      await this.#removeParts(claim.parts.map(({ objectKey }) => objectKey))
      log.debug("UPLOAD_TRACE phase=finish_done", {
        outcome: "complete",
        kind: claim.upload.kind,
        partCount: claim.parts.length,
        finalizerMs: finalizedAt - finalizerStartedAt,
        completionMs: completedAt - finalizedAt,
        cleanupMs: Date.now() - completedAt,
        elapsedMs: Date.now() - startedAt,
      })
      return { state: { oneofKind: "complete", complete } }
    } catch (error) {
      if (error instanceof UploadFinalizationOwnershipLostError) {
        return { state: { oneofKind: "processing", processing: { retryAfterSeconds: RETRY_AFTER_SECONDS } } }
      }
      if (error instanceof UploadIntegrityError) {
        const failed = await this.repository.fail({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
          code: "integrity",
          retryable: false,
        })
        if (!failed) return { state: { oneofKind: "processing", processing: { retryAfterSeconds: RETRY_AFTER_SECONDS } } }
        return { state: { oneofKind: "failed", failed: failure(UploadFailure_Code.UPLOAD_FAILURE_INTEGRITY, false) } }
      }
      if (error instanceof UploadPartStorageUnavailableError) {
        const released = await this.repository.release({ uploadDbId: claim.upload.id, lockToken: claim.lockToken })
        if (!released) return { state: { oneofKind: "processing", processing: { retryAfterSeconds: RETRY_AFTER_SECONDS } } }
        return { state: { oneofKind: "failed", failed: failure(UploadFailure_Code.UPLOAD_FAILURE_STORAGE, true) } }
      }
      if (error instanceof InlineUploadPublicationConflictError) {
        const failed = await this.repository.fail({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
          code: "publication_conflict",
          retryable: false,
        })
        if (!failed) return { state: { oneofKind: "processing", processing: { retryAfterSeconds: RETRY_AFTER_SECONDS } } }
        return { state: { oneofKind: "failed", failed: failure(UploadFailure_Code.UPLOAD_FAILURE_PROCESSING, false) } }
      }
      if (error instanceof InlineError &&
          (error.type === "BAD_REQUEST" || error.type === "FILE_TOO_LARGE")) {
        const failed = await this.repository.fail({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
          code: "invalid_media",
          retryable: false,
        })
        if (!failed) return { state: { oneofKind: "processing", processing: { retryAfterSeconds: RETRY_AFTER_SECONDS } } }
        return { state: { oneofKind: "failed", failed: failure(UploadFailure_Code.UPLOAD_FAILURE_INVALID_MEDIA, false) } }
      }
      await this.repository.release({ uploadDbId: claim.upload.id, lockToken: claim.lockToken })
      throw error
    } finally {
      leaseAbort.abort()
      await leaseHeartbeat
      this.#activeFinalizers -= 1
    }
  }

  async cancel(input: CancelUploadInput, context: HandlerContext): Promise<CancelUploadResult> {
    this.#scheduleCleanup()
    const owner = await this.#owner(context)
    const upload = requireValue(await this.repository.get(input.uploadId, owner))
    const result = requireValue(await this.repository.cancel(input.uploadId, owner))
    if (result.canceled) {
      const parts = await this.repository.parts(upload.id)
      await this.#removeParts(parts.map(({ objectKey }) => objectKey))
      await this.#discardPublication(upload)
    }
    return result
  }

  async #owner(context: HandlerContext): Promise<InlineUploadOwner> {
    const owner = await this.repository.resolveOwner({
      userId: context.userId,
      accountSessionId: context.sessionId,
      permanentAuthKeyId: context.inlineProtocol?.permanentAuthKeyId,
    })
    return owner ?? ownerUnavailable("resolve", context.inlineProtocol ? "v3" : "v2")
  }

  async #removeParts(objectKeys: string[]): Promise<boolean> {
    let next = 0
    let failures = 0
    await Promise.all(Array.from({ length: Math.min(CLEANUP_PART_CONCURRENCY, objectKeys.length) }, async () => {
      while (next < objectKeys.length) {
        const key = objectKeys[next++]!
        try { await this.partStore.remove(key) } catch { failures += 1 }
      }
    }))
    if (failures > 0) log.warn("Upload staging cleanup incomplete", { objectCount: objectKeys.length, failures })
    return failures === 0
  }

  async #discardPublication(upload: InlineUploadRecord): Promise<boolean> {
    if (!upload.resultFileUniqueId || upload.resultMediaId !== null || upload.status === "complete") return true
    try {
      await this.finalizer.discardPublication(upload)
      return true
    } catch (error) {
      log.warn("Upload permanent publication cleanup incomplete", { error, uploadDbId: upload.id })
      return false
    }
  }

  #scheduleCleanup(): void {
    const now = Date.now()
    if (this.#cleanupPromise || now - this.#lastCleanupStartedAt < CLEANUP_MIN_INTERVAL_MS) return
    this.#lastCleanupStartedAt = now
    this.#cleanupPromise = this.#cleanupExpired()
      .catch((error) => log.warn("Expired upload cleanup failed", { error }))
      .finally(() => { this.#cleanupPromise = undefined })
  }

  async #cleanupExpired(): Promise<void> {
    const expired = await this.repository.listExpired(CLEANUP_BATCH_SIZE)
    let cleaned = 0
    for (const listedUpload of expired) {
      const claim = await this.repository.claimExpiredCleanup(listedUpload.id)
      if (!claim) continue
      const parts = await this.repository.parts(claim.upload.id)
      if (!await this.#removeParts(parts.map(({ objectKey }) => objectKey))) continue
      if (claim.upload.status !== "complete" && !await this.#discardPublication(claim.upload)) continue
      if (await this.repository.removeCleanupClaim(claim.upload.id, claim.cleanupToken)) cleaned += 1
    }
    if (expired.length > 0) log.info("Expired native upload cleanup", { candidates: expired.length, cleaned })
  }
}

const partStore = new R2UploadPartStore()
export const nativeUploadOperations = new NativeUploadOperations(
  new InlineUploadRepository(),
  partStore,
  new UploadMediaFinalizer(partStore),
)
