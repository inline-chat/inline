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
import { MEDIA_UPLOAD_MAX_BYTES } from "@in/server/modules/files/metadata"
import {
  INLINE_UPLOAD_MAX_PARTS,
  InlineUploadAdmissionCapacityError,
  InlineUploadAdmissionOwnerInvalidError,
  InlineUploadMetadataConflictError,
  InlineUploadRepository,
  type InlineUploadKind,
  type InlineUploadMetadata,
  type InlineUploadOwner,
  type InlineUploadRecord,
} from "@in/server/db/models/inlineUploads"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { INLINE_TRANSFER_PART_SIZE } from "@inline-chat/protocol/transfers"
import { Log } from "@in/server/utils/log"
import { UploadMediaFinalizer, type MediaUploadFinalizer } from "./finalizer"
import {
  MAX_STORED_FRAME_BYTES,
  R2UploadPartStore,
  type UploadPartStore,
} from "./partStore"
import { R2MultipartObjectStore } from "./multipartStore"
import { IDENTITY_STORAGE_FORMAT, storageCodecFor } from "./storageCodec"
import { NativeUploadWorker, uploadTraceKey } from "./worker"
import { UploadGroupBuffer, uploadGroupBuffer } from "./groupBuffer"
import { uploadTraceLogLevel } from "./trace"
import {
  UploadGeometryCache,
  expectedPartLength,
  markPartAccepted,
  type UploadGeometry,
} from "./geometryCache"
import { countTransferWork, transferTraces } from "@in/server/modules/transfers/trace"

const log = new Log("modules/uploads", uploadTraceLogLevel())
const RETRY_AFTER_SECONDS = 1
const MAX_WAVEFORM_BYTES = 2_048
// Deletes carry no file buffers; allow a wider bounded window so successful
// finalization does not serialize hundreds of cleanup round trips.
const CLEANUP_PART_CONCURRENCY = 16
const MAX_ACTIVE_UPLOADS_PER_SESSION = 20
const MAX_ACTIVE_RESERVED_UPLOAD_BYTES_PER_SESSION = 2n * 1_024n * 1_024n * 1_024n

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
  const partCount = Number((input.byteCount + BigInt(INLINE_TRANSFER_PART_SIZE - 1)) /
    BigInt(INLINE_TRANSFER_PART_SIZE))
  if (partCount < 1 || partCount > INLINE_UPLOAD_MAX_PARTS) return badRequest()
  if (input.thumbnailFileUniqueId !== undefined &&
      (input.thumbnailFileUniqueId.length < 1 || input.thumbnailFileUniqueId.length > 128 ||
       (kind !== "video" && kind !== "document"))) return badRequest()
  if (kind === "photo" && mimeType !== "image/jpeg" && mimeType !== "image/png") return badRequest()

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

/** The owner the authenticated context proves; V3 authority is verified in memory per RPC. */
const contextOwner = (context: HandlerContext): InlineUploadOwner => ({
  userId: context.userId,
  accountSessionId: context.sessionId,
  permanentAuthKeyId: context.inlineProtocol?.permanentAuthKeyId,
})

/** Uploads at most this large may finalize inside FINISH_UPLOAD. */
const INLINE_FINISH_MAX_BYTES = 10n * 1_024n * 1_024n

export type NativeUploadOperationsOptions = {
  geometry?: UploadGeometryCache
  /** Shared with the worker so compaction can skip staging reads. */
  groupBuffer?: UploadGroupBuffer
  /** Finalizes now when this process holds the upload in memory; see NativeUploadWorker.processNow. */
  finishInline?: (
    upload: { id: number; partCount: number; kind: InlineUploadRecord["kind"] },
    signal?: AbortSignal,
  ) => Promise<"complete" | "running" | "processing">
}

export class NativeUploadOperations {
  readonly #geometry: UploadGeometryCache
  readonly #groupBuffer: UploadGroupBuffer | undefined
  readonly #finishInline: NativeUploadOperationsOptions["finishInline"]

  constructor(
    private readonly repository: InlineUploadRepository,
    private readonly partStore: UploadPartStore,
    private readonly finalizer: MediaUploadFinalizer,
    private readonly wakeWorker: (uploadDbId: number, groupNumber?: number) => void = () => {},
    private readonly discardStorage: (upload: InlineUploadRecord) => Promise<void> = async () => {},
    private readonly cancelWorker: (uploadDbId: number) => void = () => {},
    options: NativeUploadOperationsOptions = {},
  ) {
    this.#geometry = options.geometry ?? new UploadGeometryCache()
    this.#groupBuffer = options.groupBuffer
    this.#finishInline = options.finishInline
  }

  async create(input: CreateUploadInput, context: HandlerContext): Promise<CreateUploadResult> {
    throwIfAborted(context.signal)
    const metadata = validateCreate(input)
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
    if (result.upload.status === "uploading") {
      this.#geometry.put({
        uploadId: result.upload.uploadId,
        uploadDbId: result.upload.id,
        byteCount: result.upload.byteCount,
        partSize: result.upload.partSize,
        partCount: result.upload.partCount,
        hardExpiresAt: result.upload.hardExpiresAt,
        owner,
        storageFormat: result.upload.storageFormat,
        acceptedParts: result.upload.acceptedParts,
      })
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
    const owner = contextOwner(context)
    const geometry = await this.#partGeometry(input.uploadId, owner)
    throwIfAborted(context.signal)
    const geometryDoneAt = Date.now()
    if (input.partIndex >= geometry.partCount ||
        input.data.length !== expectedPartLength(geometry, input.partIndex)) return badRequest()
    const traceKey = uploadTraceKey(geometry.uploadDbId)
    const trace = transferTraces.touch(traceKey, "upload", context.inlineProtocol ? "v3" : "v2")
    const { value: result, counters } = await countTransferWork(() => transferTraces.part(
      traceKey, trace, input.data.length,
      () => this.#acceptPart(input, owner, geometry, context.signal),
    ))
    if (result.alreadyPresent) trace.retries += 1
    else {
      trace.parts += 1
      trace.bytes += input.data.length
    }
    log.debug("UPLOAD_TRACE phase=save_part_done", {
      outcome: result.outcome,
      partIndex: input.partIndex,
      byteCount: input.data.length,
      geometryMs: geometryDoneAt - startedAt,
      hashMs: result.hashDoneAt - geometryDoneAt,
      objectStoreMs: result.objectStoreDoneAt - result.hashDoneAt,
      acceptMs: result.acceptDoneAt - result.objectStoreDoneAt,
      elapsedMs: Date.now() - startedAt,
      sqlStatements: counters.sqlStatements,
      storageOps: counters.storagePut + counters.storageGet + counters.storageDelete,
    })
    return { alreadyPresent: result.alreadyPresent }
  }

  async #acceptPart(
    input: SaveUploadPartInput,
    owner: InlineUploadOwner,
    geometry: UploadGeometry,
    signal: AbortSignal | undefined,
  ): Promise<{
    alreadyPresent: boolean
    outcome: "accepted" | "already_present"
    hashDoneAt: number
    objectStoreDoneAt: number
    acceptDoneAt: number
  }> {
    const sha256 = createHash("sha256").update(input.data).digest()
    const codec = storageCodecFor(geometry.storageFormat ?? IDENTITY_STORAGE_FORMAT)
    if (!codec) return badRequest()
    const encoded = codec.encodeFrame(input.data, {
      uploadId: input.uploadId,
      partIndex: input.partIndex,
      logicalByteCount: input.data.byteLength,
      logicalSha256: sha256,
    })
    if (encoded.bytes.byteLength < 1 || encoded.bytes.byteLength > MAX_STORED_FRAME_BYTES) {
      return badRequest()
    }
    const storedSha256 = createHash("sha256").update(encoded.bytes).digest()
    const hashDoneAt = Date.now()
    throwIfAborted(signal)
    // Durability: a part is acknowledged only after its staging object exists.
    const objectKey = await this.partStore.put({
      uploadId: input.uploadId,
      partIndex: input.partIndex,
      sha256: storedSha256,
      data: encoded.bytes,
    }, signal)
    const objectStoreDoneAt = Date.now()
    let accepted
    try {
      accepted = await this.repository.acceptPartFast({
        uploadId: input.uploadId,
        owner,
        uploadDbId: geometry.uploadDbId,
        partIndex: input.partIndex,
        byteCount: input.data.length,
        sha256,
        storedByteCount: encoded.bytes.byteLength,
        storedSha256,
        objectKey,
      })
    } catch (error) {
      // A lost commit response is not a rollback. Only a positive matching
      // manifest can resolve it; absence cannot authorize deletion while an
      // identical concurrent save may still be about to commit this same key.
      const manifested = await this.repository.getPart(geometry.uploadDbId, input.partIndex).catch(() => undefined)
      if (!manifested || manifested.objectKey !== objectKey || manifested.byteCount !== input.data.length ||
          !Buffer.from(manifested.sha256).equals(sha256) ||
          manifested.storedByteCount !== encoded.bytes.byteLength ||
          !Buffer.from(manifested.storedSha256).equals(storedSha256)) throw error
      accepted = { kind: "already-present" as const, durableObjectKey: objectKey }
    }
    const acceptDoneAt = Date.now()
    if (accepted.durableObjectKey !== objectKey) {
      // The object-store write happens before the manifest statement. Remove
      // only the key that statement proved has no durable owner; a matching
      // key may belong to a concurrent/repeated accepted part.
      await this.partStore.remove(objectKey).catch((error) => {
        log.warn("Upload unowned staging object cleanup failed", { error })
      })
    }
    if (accepted.kind === "terminal") {
      // Unknown, foreign, expired, or no longer uploading; the cache may be stale.
      this.#geometry.drop(input.uploadId)
      return badRequest()
    }
    if (accepted.kind === "conflict") return badRequest()
    // The staged frame is durable; this copy only spares the worker a read.
    this.#groupBuffer?.put(geometry.uploadDbId, input.partIndex, encoded.bytes)
    const completedGroup = markPartAccepted(geometry, input.partIndex)
    if (completedGroup !== undefined) this.#wake(geometry.uploadDbId, completedGroup)
    return {
      alreadyPresent: accepted.kind === "already-present",
      outcome: accepted.kind === "already-present" ? "already_present" : "accepted",
      hashDoneAt,
      objectStoreDoneAt,
      acceptDoneAt,
    }
  }

  /** Cached geometry, or one statement on a miss; rejects foreign and non-uploading uploads. */
  async #partGeometry(uploadId: Uint8Array, owner: InlineUploadOwner): Promise<UploadGeometry> {
    const cached = this.#geometry.get(uploadId, owner)
    if (cached === "owner_mismatch") return badRequest()
    if (cached) return cached
    const upload = requireValue(await this.repository.getPartGeometry(uploadId, owner))
    if (upload.status !== "uploading" || upload.expired) return badRequest()
    return this.#geometry.put({
      uploadId,
      uploadDbId: upload.id,
      byteCount: upload.byteCount,
      partSize: upload.partSize,
      partCount: upload.partCount,
      hardExpiresAt: upload.hardExpiresAt,
      owner,
      storageFormat: upload.storageFormat,
      acceptedParts: upload.acceptedParts,
    })
  }

  async state(input: GetUploadStateInput, context: HandlerContext): Promise<GetUploadStateResult> {
    const owner = contextOwner(context)
    const upload = requireValue(await this.repository.get(input.uploadId, owner))
    if (upload.status === "uploading" && upload.expired) {
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
    const startedAt = Date.now()
    throwIfAborted(context.signal)
    const owner = await this.#owner(context)
    throwIfAborted(context.signal)
    const result = await this.repository.requestFinish(input.uploadId, owner)
    if (result.kind !== "missing") this.#geometry.drop(input.uploadId)
    switch (result.kind) {
      case "rejected": return badRequest()
      case "missing":
        return { state: { oneofKind: "missing", missing: { partIndices: result.partIndices } } }
      case "processing":
        return { state: { oneofKind: "processing", processing: { retryAfterSeconds: RETRY_AFTER_SECONDS } } }
      case "queued": {
        const inline = result.byteCount <= INLINE_FINISH_MAX_BYTES && this.#finishInline
          ? await this.#finishInline({ id: result.uploadDbId, partCount: result.partCount, kind: result.uploadKind }, context.signal)
            .catch((error) => {
              log.warn("Native upload inline finish failed", { error, uploadDbId: result.uploadDbId })
              return "processing" as const
            })
          : "processing"
        log.debug("UPLOAD_TRACE phase=finish_queued", {
          uploadDbId: result.uploadDbId,
          inline,
          elapsedMs: Date.now() - startedAt,
        })
        if (inline === "complete") {
          const upload = await this.repository.get(input.uploadId, owner)
          if (upload?.status === "complete" && upload.resultFileUniqueId && upload.resultMediaId) {
            return {
              state: {
                oneofKind: "complete",
                complete: await this.finalizer.project(upload.kind, upload.resultFileUniqueId, upload.resultMediaId),
              },
            }
          }
        }
        // A queued upload not finished here belongs to the worker; one this process already
        // claimed is still its task and must not be queued for a second full pass.
        if (inline !== "running") this.#wake(result.uploadDbId)
        return { state: { oneofKind: "processing", processing: { retryAfterSeconds: RETRY_AFTER_SECONDS } } }
      }
      case "failed":
        return { state: { oneofKind: "failed", failed: failureForRow(result.upload) } }
      case "complete": {
        const upload = result.upload
        if (!upload.resultFileUniqueId || !upload.resultMediaId) throw RealtimeRpcError.InternalError()
        return {
          state: {
            oneofKind: "complete",
            complete: await this.finalizer.project(upload.kind, upload.resultFileUniqueId, upload.resultMediaId),
          },
        }
      }
    }
  }
  async cancel(input: CancelUploadInput, context: HandlerContext): Promise<CancelUploadResult> {
    const owner = await this.#owner(context)
    const canceled = requireValue(await this.repository.cancel(input.uploadId, owner))
    this.#geometry.drop(input.uploadId)
    this.#groupBuffer?.drop(canceled.upload.id)
    if (canceled.result.canceled) {
      transferTraces.finish(uploadTraceKey(canceled.upload.id), "canceled")
      this.cancelWorker(canceled.upload.id)
      const parts = await this.repository.parts(canceled.upload.id)
      await this.#removeParts(parts.map(({ objectKey }) => objectKey))
      await this.discardStorage(canceled.upload).catch((error) => {
        log.warn("Upload multipart session cleanup incomplete", { error, uploadDbId: canceled.upload.id })
      })
      await this.#discardPublication(canceled.upload)
    }
    return canceled.result
  }

  async #owner(context: HandlerContext): Promise<InlineUploadOwner> {
    const owner = await this.repository.resolveOwner({
      userId: context.userId,
      accountSessionId: context.sessionId,
      permanentAuthKeyId: context.inlineProtocol?.permanentAuthKeyId,
    })
    return owner ?? ownerUnavailable("resolve", context.inlineProtocol ? "v3" : "v2")
  }

  #wake(uploadDbId: number, groupNumber?: number): void {
    try {
      this.wakeWorker(uploadDbId, groupNumber)
    } catch (error) {
      // The row/manifest is durable. Polling recovers a lost in-process wake.
      log.warn("Native upload worker wake failed", { error, uploadDbId })
    }
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

}

const repository = new InlineUploadRepository()
const partStore = new R2UploadPartStore()
const multipartStore = new R2MultipartObjectStore()
const finalizer = new UploadMediaFinalizer(
  partStore,
  (key) => multipartStore.remove(key),
)
export const nativeUploadWorker = new NativeUploadWorker(
  repository,
  partStore,
  multipartStore,
  finalizer,
  { groupBuffer: uploadGroupBuffer },
)

export class NativeUploadWorkerAlreadyOwnedError extends Error {
  constructor() {
    super("Native upload worker already has a process owner")
    this.name = "NativeUploadWorkerAlreadyOwnedError"
  }
}

export type NativeUploadWorkerLease = {
  readonly worker: NativeUploadWorker
  readonly release: () => Promise<void>
}

let nativeUploadWorkerOwner: symbol | undefined

/** One server root owns the singleton worker and its shutdown at a time. */
export const acquireNativeUploadWorker = (): NativeUploadWorkerLease => {
  if (nativeUploadWorkerOwner) throw new NativeUploadWorkerAlreadyOwnedError()
  const owner = Symbol("native-upload-worker-owner")
  nativeUploadWorkerOwner = owner
  try {
    nativeUploadWorker.start()
  } catch (error) {
    if (nativeUploadWorkerOwner === owner) nativeUploadWorkerOwner = undefined
    throw error
  }
  let released = false
  return {
    worker: nativeUploadWorker,
    release: async () => {
      if (released) return
      released = true
      try {
        await nativeUploadWorker.stop()
      } finally {
        if (nativeUploadWorkerOwner === owner) nativeUploadWorkerOwner = undefined
      }
    },
  }
}

export const nativeUploadOperations = new NativeUploadOperations(
  repository,
  partStore,
  finalizer,
  (uploadDbId, groupNumber) => nativeUploadWorker.wake(uploadDbId, groupNumber),
  (upload) => nativeUploadWorker.discardStorage(upload),
  (uploadDbId) => nativeUploadWorker.cancel(uploadDbId),
  {
    groupBuffer: uploadGroupBuffer,
    finishInline: (upload, signal) => nativeUploadWorker.processNow(upload, signal),
  },
)
