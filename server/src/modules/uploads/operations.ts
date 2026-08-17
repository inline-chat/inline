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
import { MAX_FILE_SIZE } from "@in/server/config"
import {
  INLINE_UPLOAD_MAX_PARTS,
  InlineUploadMetadataConflictError,
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
const CLEANUP_MIN_INTERVAL_MS = 60_000
const MAX_ACTIVE_UPLOADS_PER_SESSION = 20
const MAX_CONCURRENT_FINALIZERS = 4

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

const requireValue = <T>(value: T | undefined): T => value ?? badRequest()

const validateCreate = (input: CreateUploadInput): InlineUploadMetadata => {
  const kind = kindFor(input.kind)
  const fileName = input.fileName.trim()
  const mimeType = input.mimeType.trim().toLowerCase()
  if (!kind || input.clientUploadId.length !== 16 || input.sha256.length !== 32 ||
      !fileName || fileName.length > 255 || fileName.includes("\0") ||
      !mimeType || mimeType.length > 255 || input.byteCount <= 0n ||
      input.byteCount > BigInt(MAX_FILE_SIZE)) return badRequest()
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
    this.#scheduleCleanup()
    const owner = await this.#owner(context)
    if (!await this.repository.hasClientUpload(owner, input.clientUploadId) &&
        await this.repository.activeCount(owner) >= MAX_ACTIVE_UPLOADS_PER_SESSION) {
      throw RealtimeRpcError.RateLimit()
    }
    let result
    try {
      result = await this.repository.create(owner, validateCreate(input))
    } catch (error) {
      if (error instanceof InlineUploadMetadataConflictError) badRequest()
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
    this.#scheduleCleanup()
    const owner = await this.#owner(context)
    const upload = requireValue(await this.repository.get(input.uploadId, owner))
    if (upload.status !== "uploading" || upload.expiresAt <= new Date() ||
        input.partIndex >= upload.partCount) return badRequest()
    const expected = input.partIndex === upload.partCount - 1
      ? Number(upload.byteCount - BigInt(upload.partSize) * BigInt(upload.partCount - 1))
      : upload.partSize
    if (input.data.length !== expected) return badRequest()
    const sha256 = createHash("sha256").update(input.data).digest()
    const existing = await this.repository.getPart(upload.id, input.partIndex)
    if (existing) {
      if (existing.byteCount !== input.data.length ||
          !Buffer.from(existing.sha256).equals(sha256)) return badRequest()
      return { alreadyPresent: true }
    }
    const objectKey = await this.partStore.put({
      uploadId: input.uploadId,
      partIndex: input.partIndex,
      sha256,
      data: input.data,
    })
    const accepted = await this.repository.acceptPart({
      upload,
      partIndex: input.partIndex,
      byteCount: input.data.length,
      sha256,
      objectKey,
    })
    if (accepted === "conflict" || accepted === "terminal") {
      await this.partStore.remove(objectKey).catch(() => {})
      return badRequest()
    }
    return { alreadyPresent: accepted === "already-present" }
  }

  async state(input: GetUploadStateInput, context: HandlerContext): Promise<GetUploadStateResult> {
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
    const owner = await this.#owner(context)
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
    this.#activeFinalizers += 1

    try {
      const thumbnailPhotoId = claim.upload.thumbnailFileUniqueId
        ? await this.repository.completedPhotoId(claim.upload.thumbnailFileUniqueId, owner)
        : undefined
      if (claim.upload.thumbnailFileUniqueId && !thumbnailPhotoId) {
        await this.repository.fail({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
          code: "invalid_media",
          retryable: false,
        })
        return { state: { oneofKind: "failed", failed: failure(UploadFailure_Code.UPLOAD_FAILURE_INVALID_MEDIA, false) } }
      }
      const result = await this.finalizer.finalize({
        upload: claim.upload,
        parts: claim.parts,
        thumbnailPhotoId,
      })
      if (!await this.repository.complete({
        uploadDbId: claim.upload.id,
        lockToken: claim.lockToken,
        fileUniqueId: result.fileUniqueId,
        mediaId: result.mediaId,
      })) {
        return { state: { oneofKind: "processing", processing: { retryAfterSeconds: RETRY_AFTER_SECONDS } } }
      }
      await this.#removeParts(claim.parts.map(({ objectKey }) => objectKey))
      return { state: { oneofKind: "complete", complete: result.complete } }
    } catch (error) {
      if (error instanceof UploadIntegrityError) {
        await this.repository.fail({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
          code: "integrity",
          retryable: false,
        })
        return { state: { oneofKind: "failed", failed: failure(UploadFailure_Code.UPLOAD_FAILURE_INTEGRITY, false) } }
      }
      if (error instanceof UploadPartStorageUnavailableError) {
        await this.repository.release({ uploadDbId: claim.upload.id, lockToken: claim.lockToken })
        return { state: { oneofKind: "failed", failed: failure(UploadFailure_Code.UPLOAD_FAILURE_STORAGE, true) } }
      }
      if (error instanceof InlineError &&
          (error.type === "BAD_REQUEST" || error.type === "FILE_TOO_LARGE")) {
        await this.repository.fail({
          uploadDbId: claim.upload.id,
          lockToken: claim.lockToken,
          code: "invalid_media",
          retryable: false,
        })
        return { state: { oneofKind: "failed", failed: failure(UploadFailure_Code.UPLOAD_FAILURE_INVALID_MEDIA, false) } }
      }
      await this.repository.release({ uploadDbId: claim.upload.id, lockToken: claim.lockToken })
      throw error
    } finally {
      this.#activeFinalizers -= 1
    }
  }

  async cancel(input: CancelUploadInput, context: HandlerContext): Promise<CancelUploadResult> {
    const owner = await this.#owner(context)
    const upload = requireValue(await this.repository.get(input.uploadId, owner))
    const result = requireValue(await this.repository.cancel(input.uploadId, owner))
    if (result.canceled) {
      const parts = await this.repository.parts(upload.id)
      await this.#removeParts(parts.map(({ objectKey }) => objectKey))
    }
    return result
  }

  async #owner(context: HandlerContext): Promise<InlineUploadOwner> {
    const owner = await this.repository.resolveOwner({
      userId: context.userId,
      accountSessionId: context.sessionId,
      permanentAuthKeyId: context.inlineProtocol?.permanentAuthKeyId,
    })
    if (!owner) throw RealtimeRpcError.Unauthenticated()
    return owner
  }

  async #removeParts(objectKeys: string[]): Promise<void> {
    const outcomes = await Promise.allSettled(objectKeys.map((key) => this.partStore.remove(key)))
    const failures = outcomes.filter(({ status }) => status === "rejected").length
    if (failures > 0) log.warn("Upload staging cleanup incomplete", { objectCount: objectKeys.length, failures })
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
    for (const upload of expired) {
      const parts = await this.repository.parts(upload.id)
      const outcomes = await Promise.allSettled(parts.map(({ objectKey }) => this.partStore.remove(objectKey)))
      if (outcomes.some(({ status }) => status === "rejected")) continue
      await this.repository.remove(upload.id)
    }
    if (expired.length > 0) log.info("Cleaned expired native uploads", { count: expired.length })
  }
}

const partStore = new R2UploadPartStore()
export const nativeUploadOperations = new NativeUploadOperations(
  new InlineUploadRepository(),
  partStore,
  new UploadMediaFinalizer(partStore),
)
