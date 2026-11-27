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
import { decodedDocumentName, MEDIA_UPLOAD_MAX_BYTES } from "@in/server/modules/files/metadata"
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
  UploadPartStorageUnavailableError,
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
  isPartAccepted,
  markPartAccepted,
  type UploadGeometry,
} from "./geometryCache"
import {
  UPLOAD_PIECE_GRANULARITY,
  UploadPartIntake,
  UploadPieceAssembler,
  isValidPiece,
} from "./intake"
import { countTransferWork, transferTraces, withTransferCounters } from "@in/server/modules/transfers/trace"

const log = new Log("modules/uploads", uploadTraceLogLevel())
const RETRY_AFTER_SECONDS = 1
/** Clients back off this long when part storage is down, instead of failing the send. */
const STORAGE_RETRY_AFTER_SECONDS = 5
const MAX_WAVEFORM_BYTES = 2_048
// Deletes carry no file buffers; allow a wider bounded window so successful
// finalization does not serialize hundreds of cleanup round trips.
const CLEANUP_PART_CONCURRENCY = 16
const MAX_ACTIVE_UPLOADS_PER_SESSION = 20
const MAX_ACTIVE_RESERVED_UPLOAD_BYTES_PER_SESSION = 2n * 1_024n * 1_024n * 1_024n
/** Finish waits this long for this process's writes of the upload before reading the manifest. */
const FINISH_SETTLE_MS = 30_000
/** Shutdown waits this long for writes behind acknowledged parts (Fly allows 45 s). */
const SHUTDOWN_DRAIN_MS = 25_000
/**
 * A part for an unknown upload waits this long for its create: a client that picked the upload ID
 * sends parts right behind the create, and they can reach their handler first.
 */
const EARLY_PART_CREATE_WAIT_MS = 3_000
/** Parts of one session waiting for a create; beyond this a part for an unknown upload fails at once. */
const MAX_EARLY_PART_WAITS_PER_SESSION = 8

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
  if (kind === "document" && !decodedDocumentName(fileName)) return badRequest()
  const partCount = Number((input.byteCount + BigInt(INLINE_TRANSFER_PART_SIZE - 1)) /
    BigInt(INLINE_TRANSFER_PART_SIZE))
  if (partCount < 1 || partCount > INLINE_UPLOAD_MAX_PARTS) return badRequest()
  if (input.uploadId !== undefined && input.uploadId.length !== 16) return badRequest()
  if (input.thumbnailFileUniqueId !== undefined &&
      (input.thumbnailFileUniqueId.length < 1 || input.thumbnailFileUniqueId.length > 128 ||
       (kind !== "video" && kind !== "document"))) return badRequest()
  if (kind === "photo" && mimeType !== "image/jpeg" && mimeType !== "image/png") return badRequest()
  // Inline bytes must be the whole single-part file; reject before any row is created.
  if (input.inlineData !== undefined &&
      (BigInt(input.inlineData.byteLength) !== input.byteCount ||
       input.byteCount > BigInt(INLINE_TRANSFER_PART_SIZE))) return badRequest()

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

/** The 503 `#acceptPart` turns a part storage outage into. */
const isPartStorageOutage = (error: unknown): boolean =>
  error instanceof UploadPartStorageUnavailableError ||
  (error instanceof RealtimeRpcError && error.codeNumber === 503)

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
    stored?: Promise<boolean>,
  ) => Promise<"complete" | "running" | "processing">
  /** Writes a whole file sent with CREATE_UPLOAD to its final key; see NativeUploadWorker.storeEarly. */
  storeEarly?: (upload: InlineUploadRecord, bytes: Uint8Array, signal: AbortSignal) => Promise<boolean>
  /**
   * Acknowledges parts once held and stores them behind the reply; see UploadPartIntake. Without
   * it every part is stored before its reply.
   */
  intake?: UploadPartIntake
  /** Accepts parts sent in pieces (SaveUploadPartInput.offset); needs `intake`. */
  pieces?: UploadPieceAssembler
  /** See EARLY_PART_CREATE_WAIT_MS. */
  earlyPartCreateWaitMs?: number
}

export class NativeUploadOperations {
  readonly #geometry: UploadGeometryCache
  readonly #groupBuffer: UploadGroupBuffer | undefined
  readonly #finishInline: NativeUploadOperationsOptions["finishInline"]
  readonly #storeEarly: NativeUploadOperationsOptions["storeEarly"]
  readonly #intake: UploadPartIntake | undefined
  readonly #pieces: UploadPieceAssembler | undefined
  /** Creates in flight by the upload ID their client picked; see EARLY_PART_CREATE_WAIT_MS. */
  readonly #creating = new Map<string, Promise<void>>()
  readonly #createWaiters = new Map<string, Set<() => void>>()
  readonly #earlyPartCreateWaitMs: number
  readonly #earlyPartWaitsBySession = new Map<number, number>()

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
    this.#storeEarly = options.storeEarly
    this.#intake = options.intake
    this.#pieces = options.intake ? options.pieces : undefined
    this.#earlyPartCreateWaitMs = options.earlyPartCreateWaitMs ?? EARLY_PART_CREATE_WAIT_MS
  }

  /** Waits, bounded, for parts acknowledged before their write; call at shutdown. */
  async drain(): Promise<void> {
    await this.#intake?.drain(SHUTDOWN_DRAIN_MS)
  }

  async create(input: CreateUploadInput, context: HandlerContext): Promise<CreateUploadResult> {
    throwIfAborted(context.signal)
    const metadata = validateCreate(input)
    if (input.uploadId === undefined) return await this.#create(input, metadata, context)
    // Registered before the first await, so parts sent right behind this create find it.
    const key = Buffer.from(input.uploadId).toString("hex")
    let settle!: () => void
    const created = new Promise<void>((resolve) => { settle = resolve })
    this.#creating.set(key, created)
    for (const wake of this.#createWaiters.get(key) ?? []) wake()
    this.#createWaiters.delete(key)
    try {
      return await this.#create(input, metadata, context)
    } finally {
      settle()
      if (this.#creating.get(key) === created) this.#creating.delete(key)
    }
  }

  /** Waits for a create of this upload ID that is in flight here or arrives shortly. */
  async #awaitCreate(uploadId: Uint8Array, accountSessionId: number): Promise<boolean> {
    const key = Buffer.from(uploadId).toString("hex")
    let inFlight = this.#creating.get(key)
    if (!inFlight) {
      // Each waiting part holds its bytes; a client sending parts for uploads it never creates
      // gets no waits beyond a few.
      const waiting = this.#earlyPartWaitsBySession.get(accountSessionId) ?? 0
      if (waiting >= MAX_EARLY_PART_WAITS_PER_SESSION) return false
      this.#earlyPartWaitsBySession.set(accountSessionId, waiting + 1)
      const arrived = await new Promise<boolean>((resolve) => {
        const waiters = this.#createWaiters.get(key) ?? new Set<() => void>()
        this.#createWaiters.set(key, waiters)
        const wake = () => {
          clearTimeout(timer)
          resolve(true)
        }
        const timer = setTimeout(() => {
          waiters.delete(wake)
          if (waiters.size === 0 && this.#createWaiters.get(key) === waiters) this.#createWaiters.delete(key)
          resolve(false)
        }, this.#earlyPartCreateWaitMs)
        waiters.add(wake)
      }).finally(() => {
        const remaining = (this.#earlyPartWaitsBySession.get(accountSessionId) ?? 1) - 1
        if (remaining > 0) this.#earlyPartWaitsBySession.set(accountSessionId, remaining)
        else this.#earlyPartWaitsBySession.delete(accountSessionId)
      })
      if (!arrived) return false
      inFlight = this.#creating.get(key)
    }
    await inFlight
    return true
  }

  async #create(
    input: CreateUploadInput,
    metadata: InlineUploadMetadata,
    context: HandlerContext,
  ): Promise<CreateUploadResult> {
    const owner = await this.#owner(context)
    throwIfAborted(context.signal)
    let result
    try {
      result = await this.repository.create(owner, metadata, {
        maxActiveCount: MAX_ACTIVE_UPLOADS_PER_SESSION,
        maxReservedBytes: MAX_ACTIVE_RESERVED_UPLOAD_BYTES_PER_SESSION,
      }, input.uploadId)
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
    const created: CreateUploadResult = {
      uploadId: Uint8Array.from(result.upload.uploadId),
      partSize: result.upload.partSize,
      partCount: result.upload.partCount,
      expiresAt: BigInt(Math.floor(result.upload.expiresAt.getTime() / 1_000)),
      acceptedParts: this.#withHeldParts(result.upload.id, result.upload.acceptedParts),
      pieceGranularity: this.#pieces && result.upload.status === "uploading" ? UPLOAD_PIECE_GRANULARITY : undefined,
    }
    return input.inlineData === undefined
      ? created
      : await this.#finishInlineData(created, result.upload, owner, input.inlineData, context)
  }

  /**
   * Saves a whole single-part file sent with CREATE_UPLOAD and finishes it in the same call, so a
   * small photo costs one round trip instead of create, part and finish. On any failure the
   * upload still exists and the client continues with the ordinary part and finish calls.
   *
   * The final object is written alongside staging rather than after it (see
   * NativeUploadWorker.storeEarly for who cleans up a write that outlives its upload).
   */
  async #finishInlineData(
    created: CreateUploadResult,
    upload: InlineUploadRecord,
    owner: InlineUploadOwner,
    data: Uint8Array,
    context: HandlerContext,
  ): Promise<CreateUploadResult> {
    if (created.partCount !== 1) return created
    const early = this.#startEarlyStore(upload, data, context)
    const stored = early?.stored
    try {
      if (!created.acceptedParts.includes(0)) {
        await this.savePart({ uploadId: created.uploadId, partIndex: 0, data }, context)
      }
      const finished = await this.#finish({ uploadId: created.uploadId }, context, owner, stored)
      switch (finished.state.oneofKind) {
        case "complete": return { ...created, acceptedParts: [0], complete: finished.state.complete }
        case "missing": return created
        default: return { ...created, acceptedParts: [0] }
      }
    } catch (error) {
      if (context.signal?.aborted) throw error
      log.warn("Inline upload data was not finished in create", { error })
      return created
    } finally {
      // The reply waits for no storage deadline: a write still running here (the finish timed out
      // or failed early) is stopped, and the worker writes the object itself if it needs it.
      early?.stop()
      await stored
    }
  }

  /** Starts `storeEarly` when this request can finish the upload itself; `stored` never rejects. */
  #startEarlyStore(
    upload: InlineUploadRecord,
    data: Uint8Array,
    context: HandlerContext,
  ): { stored: Promise<boolean>; stop: () => void } | undefined {
    const storeEarly = this.#storeEarly
    if (!storeEarly || !this.#finishInline || upload.status !== "uploading" ||
        upload.byteCount > INLINE_FINISH_MAX_BYTES) return undefined
    const controller = new AbortController()
    const signal = context.signal ? AbortSignal.any([controller.signal, context.signal]) : controller.signal
    const trace = transferTraces.touch(uploadTraceKey(upload.id), "upload", context.inlineProtocol ? "v3" : "v2")
    const stored = withTransferCounters(trace.counters, () => storeEarly(upload, data, signal)).catch(() => false)
    return { stored, stop: () => controller.abort() }
  }

  async savePart(input: SaveUploadPartInput, context: HandlerContext): Promise<SaveUploadPartResult> {
    throwIfAborted(context.signal)
    if (input.uploadId.length !== 16 || !Number.isInteger(input.partIndex) || input.partIndex < 0) return badRequest()
    if (input.offset !== undefined && !this.#pieces) return badRequest()
    const startedAt = Date.now()
    const owner = contextOwner(context)
    const resolved = await this.#partGeometry(input.uploadId, owner)
    if ("finishedAcceptedParts" in resolved) {
      // A part re-sent after finish (its reply was lost) is already in the file.
      if (resolved.finishedAcceptedParts.includes(input.partIndex)) return { alreadyPresent: true }
      return badRequest()
    }
    const geometry = resolved
    throwIfAborted(context.signal)
    const geometryDoneAt = Date.now()
    if (input.partIndex >= geometry.partCount) return badRequest()
    const partLength = expectedPartLength(geometry, input.partIndex)
    const traceKey = uploadTraceKey(geometry.uploadDbId)
    const trace = transferTraces.touch(traceKey, "upload", context.inlineProtocol ? "v3" : "v2")
    transferTraces.arrived(trace)
    const intake = this.#intake
    let data = input.data
    if (input.offset !== undefined) {
      if (!isValidPiece(partLength, input.offset, input.data.length)) return badRequest()
      trace.pieces += 1
    } else if (input.data.length !== partLength) return badRequest()
    if (intake && (isPartAccepted(geometry, input.partIndex) || intake.isPending(geometry.uploadDbId, input.partIndex))) {
      // Stored, or held here for storage: a resend (its reply was lost) needs no second write.
      trace.retries += 1
      return { alreadyPresent: isPartAccepted(geometry, input.partIndex) }
    }
    if (input.offset !== undefined && data.length !== partLength) {
      const whole = this.#pieces!.add(geometry.uploadDbId, input.partIndex, partLength, input.offset, data)
      if (!whole) return { alreadyPresent: false }
      data = whole
    }
    const part: SaveUploadPartInput = { uploadId: input.uploadId, partIndex: input.partIndex, data }
    const store = async (signal: AbortSignal | undefined) => {
      const { value: result, counters } = await countTransferWork(() => transferTraces.part(
        traceKey, trace, data.length,
        () => this.#acceptPart(part, owner, geometry, signal),
      ))
      log.debug("UPLOAD_TRACE phase=save_part_done", {
        outcome: result.outcome,
        partIndex: input.partIndex,
        byteCount: data.length,
        geometryMs: geometryDoneAt - startedAt,
        hashMs: result.hashDoneAt - geometryDoneAt,
        objectStoreMs: result.objectStoreDoneAt - result.hashDoneAt,
        acceptMs: result.acceptDoneAt - result.objectStoreDoneAt,
        elapsedMs: Date.now() - startedAt,
        sqlStatements: counters.sqlStatements,
        storageOps: counters.storagePut + counters.storageGet + counters.storageDelete,
      })
      return result
    }
    if (intake) {
      // The write outlives this request: a closed connection must not cancel stored bytes.
      const accepted = await intake.accept(geometry.uploadDbId, input.partIndex, data.length, () => store(undefined))
      if (accepted.queued) {
        trace.parts += 1
        trace.bytes += data.length
        return { alreadyPresent: false }
      }
      return this.#countStored(trace, data.length, accepted.value)
    }
    return this.#countStored(trace, data.length, await store(context.signal))
  }

  #countStored(
    trace: ReturnType<typeof transferTraces.touch>,
    byteCount: number,
    result: { alreadyPresent: boolean },
  ): SaveUploadPartResult {
    if (result.alreadyPresent) trace.retries += 1
    else {
      trace.parts += 1
      trace.bytes += byteCount
    }
    return { alreadyPresent: result.alreadyPresent }
  }

  /** Accepted parts plus the ones this process holds for storage behind an acknowledgement. */
  #withHeldParts(uploadDbId: number, acceptedParts: number[]): number[] {
    const held = this.#intake?.pendingParts(uploadDbId) ?? []
    if (held.length === 0) return acceptedParts
    return [...new Set([...acceptedParts, ...held])].sort((left, right) => left - right)
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
    // The identity codec stores the input bytes as they are; hash them once.
    const storedSha256 = encoded.bytes === input.data ? sha256 : createHash("sha256").update(encoded.bytes).digest()
    const hashDoneAt = Date.now()
    throwIfAborted(signal)
    // Durability: a part is acknowledged only after its staging object exists.
    const objectKey = await this.partStore.put({
      uploadId: input.uploadId,
      partIndex: input.partIndex,
      sha256: storedSha256,
      data: encoded.bytes,
    }, signal).catch((error: unknown) => {
      // A storage outage is temporary: tell the client to back off and resend, not that the
      // server is broken. The part is not acknowledged, so a resend is always correct.
      if (error instanceof UploadPartStorageUnavailableError) {
        log.warn("Upload part storage unavailable", { error })
        throw RealtimeRpcError.ServiceUnavailable(STORAGE_RETRY_AFTER_SECONDS)
      }
      throw error
    })
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
      if (accepted.durableObjectKey !== objectKey) return badRequest()
      // A stale cache let a late resend of an accepted part rewrite its content-addressed staging
      // object. Answer as the cache-miss path does. Staging cleanup runs when an upload completes,
      // fails or is canceled and may already be done, so remove the rewrite then; while processing
      // the worker may still read it, and an expired upload's reaper has yet to remove it.
      const upload = await this.repository.getPartGeometry(input.uploadId, owner)
      if (upload?.status !== "processing" && upload?.status !== "uploading") {
        await this.partStore.remove(objectKey).catch((error) => {
          log.warn("Upload late staging object cleanup failed", { error })
        })
      }
      if (upload?.status !== "processing" && upload?.status !== "complete") return badRequest()
      return { alreadyPresent: true, outcome: "already_present", hashDoneAt, objectStoreDoneAt, acceptDoneAt }
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

  /**
   * Cached geometry, or one statement on a miss; rejects foreign, expired and canceled uploads.
   * A finished upload returns its accepted parts so a late duplicate part can be acknowledged.
   */
  async #partGeometry(
    uploadId: Uint8Array,
    owner: InlineUploadOwner,
  ): Promise<UploadGeometry | { finishedAcceptedParts: number[] }> {
    const cached = this.#geometry.get(uploadId, owner)
    if (cached === "owner_mismatch") return badRequest()
    if (cached) return cached
    let found = await this.repository.getPartGeometry(uploadId, owner)
    if (!found) {
      // Sent right behind its create: that create puts the geometry here. After the wait the
      // row is read again, since the create may have landed on another machine (a reconnect).
      if (await this.#awaitCreate(uploadId, owner.accountSessionId)) {
        const created = this.#geometry.get(uploadId, owner)
        if (created === "owner_mismatch") return badRequest()
        if (created) return created
      }
      found = await this.repository.getPartGeometry(uploadId, owner)
    }
    const upload = requireValue(found)
    if (upload.status === "processing" || upload.status === "complete") {
      return { finishedAcceptedParts: upload.acceptedParts }
    }
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
        return { status: UploadStatus.UPLOADING, acceptedParts: this.#withHeldParts(upload.id, upload.acceptedParts) }
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
    return await this.#finish(input, context)
  }

  /** `owner` is one the same request already resolved; `stored` comes from `#startEarlyStore`. */
  async #finish(
    input: FinishUploadInput,
    context: HandlerContext,
    resolvedOwner?: InlineUploadOwner,
    stored?: Promise<boolean>,
  ): Promise<FinishUploadResult> {
    const startedAt = Date.now()
    throwIfAborted(context.signal)
    const owner = resolvedOwner ?? await this.#owner(context)
    throwIfAborted(context.signal)
    const cached = this.#intake ? this.#geometry.get(input.uploadId, owner) : undefined
    if (cached && cached !== "owner_mismatch") {
      // Parts acknowledged before their write must be in the manifest before it is read.
      await this.#intake!.settle(cached.uploadDbId, FINISH_SETTLE_MS)
      throwIfAborted(context.signal)
    }
    const thumbnail = input.thumbnailFileUniqueId
    if (thumbnail !== undefined && (thumbnail.length < 1 || thumbnail.length > 128)) return badRequest()
    const result = await this.repository.requestFinish(input.uploadId, owner, thumbnail)
    if (result.kind !== "missing") {
      this.#geometry.drop(input.uploadId)
      if (cached && cached !== "owner_mismatch") this.#pieces?.drop(cached.uploadDbId)
    }
    switch (result.kind) {
      case "rejected": return badRequest()
      case "missing":
        return { state: { oneofKind: "missing", missing: { partIndices: result.partIndices } } }
      case "processing":
        return { state: { oneofKind: "processing", processing: { retryAfterSeconds: RETRY_AFTER_SECONDS } } }
      case "queued": {
        const inline = result.byteCount <= INLINE_FINISH_MAX_BYTES && this.#finishInline
          ? await this.#finishInline(
            { id: result.uploadDbId, partCount: result.partCount, kind: result.uploadKind },
            context.signal,
            stored,
          ).catch((error) => {
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
    this.#pieces?.drop(canceled.upload.id)
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
        // Parts acknowledged before their write are stored before the worker stops.
        await nativeUploadOperations.drain()
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
    finishInline: (upload, signal, stored) => nativeUploadWorker.processNow(upload, signal, stored),
    storeEarly: (upload, bytes, signal) => nativeUploadWorker.storeEarly(upload, bytes, signal),
    intake: new UploadPartIntake({ isStorageOutage: isPartStorageOutage }),
    pieces: new UploadPieceAssembler(),
  },
)
