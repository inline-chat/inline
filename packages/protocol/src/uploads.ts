import { sha256 } from "@noble/hashes/sha2.js"
import {
  Method,
  UploadKind,
  UploadStatus,
  type CancelUploadResult,
  type CreateUploadInput,
  type CreateUploadResult,
  type FinishUploadResult,
  type GetUploadStateResult,
  type SaveUploadPartResult,
  type UploadComplete,
  type UploadVideoMetadata,
  type UploadVoiceMetadata,
} from "./core.js"
import { INLINE_TRANSFER_PART_SIZE, INLINE_UPLOAD_MAX_PARTS } from "./transfers.js"

const HASH_READ_SIZE = 1024 * 1024
const DEFAULT_GLOBAL_CONCURRENCY = 3
const DEFAULT_UPLOAD_CONCURRENCY = 2
const MAX_PART_ATTEMPTS = 2
const MAX_FINISH_RECONCILIATION_ATTEMPTS = 3
const FINISH_RECONCILIATION_DELAY_SECONDS = 1
const MAX_PROCESSING_RETRY_SECONDS = 30
const CANCEL_RPC_TIMEOUT_MS = 5_000
const MAX_UPLOAD_BYTES_BY_KIND: Partial<Record<UploadKind, number>> = {
  [UploadKind.PHOTO]: 40_000_000,
  [UploadKind.VIDEO]: 200_000_000,
  [UploadKind.DOCUMENT]: 200_000_000,
  [UploadKind.VOICE]: 20_000_000,
}

const boundedUploadProcessingRetrySeconds = (seconds: number): number =>
  Number.isNaN(seconds)
    ? 1
    : Math.min(MAX_PROCESSING_RETRY_SECONDS, Math.max(1, Math.floor(seconds)))

export interface UploadByteSource {
  readonly byteCount: number
  /** Must settle on abort; keep underlying reads bounded in size and duration. */
  read(offset: number, length: number, signal?: AbortSignal): Promise<Uint8Array>
}

export type NativeUploadInput = {
  source: UploadByteSource
  fileName: string
  mimeType: string
  kind: UploadKind
  /** Persist and reuse this 16-byte idempotency key to resume after owner/process restart. */
  clientUploadId?: Uint8Array
  thumbnailFileUniqueId?: string
  metadata?:
    | { kind: "video"; value: UploadVideoMetadata }
    | { kind: "voice"; value: UploadVoiceMetadata }
  signal?: AbortSignal
  onProgress?: (progress: NativeUploadProgress) => void
}

export type NativeUploadProgress = {
  acceptedBytes: number
  totalBytes: number
}

export interface NativeUploadRpcTransport {
  // Adapters own RPC deadlines and must settle when the supplied signal aborts.
  shouldReplayCreate?(error: unknown): boolean
  create(input: CreateUploadInput, signal?: AbortSignal): Promise<CreateUploadResult>
  savePart(input: { uploadId: Uint8Array; partIndex: number; data: Uint8Array }, signal?: AbortSignal): Promise<SaveUploadPartResult>
  state(input: { uploadId: Uint8Array }, signal?: AbortSignal): Promise<GetUploadStateResult>
  finish(input: { uploadId: Uint8Array }, signal?: AbortSignal): Promise<FinishUploadResult>
  cancel(input: { uploadId: Uint8Array }, signal?: AbortSignal): Promise<CancelUploadResult>
}

type UploadJob = {
  input: NativeUploadInput
  upload: CreateUploadResult
  accepted: Set<number>
  queued: Set<number>
  active: number
  resolve: (complete: UploadComplete) => void
  reject: (error: Error) => void
  settled: boolean
  removeAbortListener?: () => void
}

const randomUploadId = (): Uint8Array => {
  const bytes = new Uint8Array(16)
  globalThis.crypto.getRandomValues(bytes)
  return bytes
}

const exactRead = async (source: UploadByteSource, offset: number, length: number, signal?: AbortSignal): Promise<Uint8Array> => {
  if (signal?.aborted) throw new NativeUploadError("canceled", "Upload was canceled")
  const bytes = await source.read(offset, length, signal)
  if (signal?.aborted) throw new NativeUploadError("canceled", "Upload was canceled")
  if (bytes.length !== length) throw new NativeUploadError("source_changed", "Upload source changed while it was being read")
  return bytes
}

const sourceHash = async (source: UploadByteSource, signal?: AbortSignal): Promise<Uint8Array> => {
  const hash = sha256.create()
  for (let offset = 0; offset < source.byteCount; offset += HASH_READ_SIZE) {
    if (signal?.aborted) throw new NativeUploadError("canceled", "Upload was canceled")
    const length = Math.min(HASH_READ_SIZE, source.byteCount - offset)
    const bytes = await exactRead(source, offset, length, signal)
    if (signal?.aborted) throw new NativeUploadError("canceled", "Upload was canceled")
    hash.update(bytes)
  }
  return hash.digest()
}

const acceptedBytes = (job: UploadJob): number => {
  let total = 0
  for (const index of job.accepted) {
    const offset = index * job.upload.partSize
    total += Math.min(job.upload.partSize, job.input.source.byteCount - offset)
  }
  return total
}

const validatePartIndices = (indices: number[], partCount: number): void => {
  if (indices.some((index) => !Number.isInteger(index) || index < 0 || index >= partCount)) {
    throw new NativeUploadError("protocol", "Server returned an invalid upload-part index")
  }
}

const reportProgress = (job: UploadJob): void => {
  // Progress is an observer. Host callbacks cannot strand an admitted job or
  // turn a durably accepted part into a failed transfer. Use signal to cancel.
  try {
    job.input.onProgress?.({ acceptedBytes: acceptedBytes(job), totalBytes: job.input.source.byteCount })
  } catch { /* A failed observer does not change transfer ownership. */ }
}

const delay = async (seconds: number, signal?: AbortSignal): Promise<void> => {
  if (signal?.aborted) throw new NativeUploadError("canceled", "Upload was canceled")
  await new Promise<void>((resolve, reject) => {
    const onAbort = () => {
      clearTimeout(timeout)
      signal?.removeEventListener("abort", onAbort)
      reject(new NativeUploadError("canceled", "Upload was canceled"))
    }
    const timeout = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort)
      resolve()
    }, Math.max(1, seconds) * 1_000)
    signal?.addEventListener("abort", onAbort, { once: true })
    if (signal?.aborted) onAbort()
  })
}

export class NativeUploadClient {
  readonly #jobs: UploadJob[] = []
  #active = 0
  #finishing = 0
  #cursor = 0

  constructor(
    private readonly rpc: NativeUploadRpcTransport,
    private readonly globalConcurrency = DEFAULT_GLOBAL_CONCURRENCY,
    private readonly uploadConcurrency = DEFAULT_UPLOAD_CONCURRENCY,
  ) {
    if (!Number.isInteger(globalConcurrency) || globalConcurrency < 1 ||
        !Number.isInteger(uploadConcurrency) || uploadConcurrency < 1) {
      throw new TypeError("Upload concurrency must be a positive integer")
    }
  }

  async upload(input: NativeUploadInput): Promise<UploadComplete> {
    if (!Number.isSafeInteger(input.source.byteCount) || input.source.byteCount <= 0) {
      throw new NativeUploadError("invalid_source", "Upload source must have a positive safe byte count")
    }
    const maximumByteCount = MAX_UPLOAD_BYTES_BY_KIND[input.kind]
    if (maximumByteCount === undefined || input.source.byteCount > maximumByteCount) {
      throw new NativeUploadError("invalid_source", "Upload source exceeds the media size limit")
    }
    if (input.signal?.aborted) throw new NativeUploadError("canceled", "Upload was canceled")
    const clientUploadId = input.clientUploadId?.slice() ?? randomUploadId()
    if (clientUploadId.length !== 16) throw new NativeUploadError("invalid_source", "Client upload ID must be 16 bytes")
    const digest = await sourceHash(input.source, input.signal)
    const createInput: CreateUploadInput = {
      clientUploadId,
      fileName: input.fileName,
      mimeType: input.mimeType,
      byteCount: BigInt(input.source.byteCount),
      sha256: digest,
      kind: input.kind,
      thumbnailFileUniqueId: input.thumbnailFileUniqueId,
      metadata: input.metadata?.kind === "video"
        ? { oneofKind: "video", video: input.metadata.value }
        : input.metadata?.kind === "voice"
          ? { oneofKind: "voice", voice: input.metadata.value }
          : { oneofKind: undefined },
    }
    let created: CreateUploadResult
    try {
      created = await this.rpc.create(createInput, input.signal)
    } catch (error) {
      if (input.signal?.aborted) throw new NativeUploadError("canceled", "Upload was canceled")
      if (this.rpc.shouldReplayCreate?.(error) === false) throw error
      // create is idempotent by the stable clientUploadId. One replay recovers
      // a committed request whose response was lost without a resume registry.
      try {
        created = await this.rpc.create(createInput, input.signal)
      } catch (replayError) {
        if (input.signal?.aborted) throw new NativeUploadError("canceled", "Upload was canceled")
        throw replayError
      }
    }
    if (created.uploadId.length !== 16 || created.partSize !== INLINE_TRANSFER_PART_SIZE ||
        !Number.isSafeInteger(created.partCount) || created.partCount < 1 || created.partCount > INLINE_UPLOAD_MAX_PARTS ||
        created.partCount !== Math.ceil(input.source.byteCount / created.partSize) ||
        created.acceptedParts.some((index) => !Number.isInteger(index) || index < 0 || index >= created.partCount)) {
      throw new NativeUploadError("protocol", "Server returned invalid upload geometry")
    }

    return await new Promise<UploadComplete>((resolve, reject) => {
      const job: UploadJob = {
        input,
        upload: created,
        accepted: new Set(created.acceptedParts),
        queued: new Set(),
        active: 0,
        resolve,
        reject,
        settled: false,
      }
      this.#jobs.push(job)
      const signal = input.signal
      if (signal) {
        const onAbort = () => this.#abort(job)
        signal.addEventListener("abort", onAbort, { once: true })
        job.removeAbortListener = () => signal.removeEventListener("abort", onAbort)
      }
      if (signal?.aborted) {
        this.#abort(job)
        return
      }
      reportProgress(job)
      if (!job.settled) this.#pump()
    })
  }

  #pump(): void {
    while (this.#active + this.#finishing < this.globalConcurrency) {
      const selected = this.#nextJob()
      if (!selected) break
      const partIndex = this.#nextPart(selected)
      if (partIndex === undefined) {
        if (selected.active === 0) void this.#finish(selected)
        continue
      }
      selected.queued.add(partIndex)
      selected.active += 1
      this.#active += 1
      void this.#sendPart(selected, partIndex)
    }
    // A resumed create may already acknowledge every part. It needs no transfer
    // permit, but still needs finish to reconcile processing/completion.
    for (const job of this.#jobs) {
      if (!job.settled && job.active === 0 && this.#nextPart(job) === undefined) void this.#finish(job)
    }
  }

  #nextJob(): UploadJob | undefined {
    for (let offset = 0; offset < this.#jobs.length; offset += 1) {
      const index = (this.#cursor + offset) % this.#jobs.length
      const job = this.#jobs[index]
      if (job && !job.settled && job.active < this.uploadConcurrency && this.#nextPart(job) !== undefined) {
        this.#cursor = (index + 1) % this.#jobs.length
        return job
      }
    }
    return undefined
  }

  #nextPart(job: UploadJob): number | undefined {
    for (let index = 0; index < job.upload.partCount; index += 1) {
      if (!job.accepted.has(index) && !job.queued.has(index)) return index
    }
    return undefined
  }

  async #sendPart(job: UploadJob, partIndex: number): Promise<void> {
    try {
      if (job.input.signal?.aborted) throw new NativeUploadError("canceled", "Upload was canceled")
      const offset = partIndex * job.upload.partSize
      const length = Math.min(job.upload.partSize, job.input.source.byteCount - offset)
      const data = await exactRead(job.input.source, offset, length, job.input.signal)
      if (job.settled) return
      await this.#savePart(job, partIndex, data)
      if (job.settled) return
      job.accepted.add(partIndex)
      reportProgress(job)
    } catch (error) {
      if (!job.settled && !job.input.signal?.aborted) {
        this.#reject(job, error)
      }
    } finally {
      job.queued.delete(partIndex)
      job.active -= 1
      this.#active -= 1
      this.#pump()
      if (!job.settled && job.active === 0 && this.#nextPart(job) === undefined) void this.#finish(job)
    }
  }

  async #savePart(job: UploadJob, partIndex: number, data: Uint8Array): Promise<void> {
    for (let attempt = 0; attempt < MAX_PART_ATTEMPTS; attempt += 1) {
      if (job.settled || job.input.signal?.aborted) {
        throw new NativeUploadError("canceled", "Upload was canceled")
      }
      try {
        await this.rpc.savePart({ uploadId: job.upload.uploadId, partIndex, data }, job.input.signal)
        return
      } catch (error) {
        if (job.settled || job.input.signal?.aborted) {
          throw new NativeUploadError("canceled", "Upload was canceled")
        }
        let state: GetUploadStateResult
        try {
          state = await this.rpc.state({ uploadId: job.upload.uploadId }, job.input.signal)
        } catch {
          throw error
        }
        validatePartIndices(state.acceptedParts, job.upload.partCount)
        if (state.acceptedParts.includes(partIndex)) return
        if (state.status !== UploadStatus.UPLOADING || attempt + 1 === MAX_PART_ATTEMPTS) throw error
      }
    }
  }

  async #finish(job: UploadJob): Promise<void> {
    if (job.settled || job.active !== 0 || this.#active + this.#finishing >= this.globalConcurrency) return
    this.#finishing += 1
    job.active = -1
    let reconciliationAttempts = 0
    try {
      for (;;) {
        if (job.input.signal?.aborted) throw new NativeUploadError("canceled", "Upload was canceled")
        let result: FinishUploadResult
        try {
          result = await this.rpc.finish({ uploadId: job.upload.uploadId }, job.input.signal)
        } catch (error) {
          if (job.input.signal?.aborted) throw new NativeUploadError("canceled", "Upload was canceled")
          if (++reconciliationAttempts > MAX_FINISH_RECONCILIATION_ATTEMPTS) throw error

          let state: GetUploadStateResult
          try {
            state = await this.rpc.state({ uploadId: job.upload.uploadId }, job.input.signal)
          } catch {
            throw error
          }
          validatePartIndices(state.acceptedParts, job.upload.partCount)
          switch (state.status) {
            case UploadStatus.COMPLETE:
              if (!state.complete) throw new NativeUploadError("protocol", "Complete upload state had no result")
              job.settled = true
              this.#remove(job)
              job.resolve(state.complete)
              return
            case UploadStatus.PROCESSING:
              this.#resumeFinishAfter(job, FINISH_RECONCILIATION_DELAY_SECONDS)
              return
            case UploadStatus.UPLOADING:
              job.accepted = new Set(state.acceptedParts)
              if (this.#nextPart(job) === undefined) continue
              job.active = 0
              this.#pump()
              return
            case UploadStatus.FAILED:
              throw new NativeUploadError(
                state.failure?.retryable ? "retryable" : "rejected",
                `Upload finalization failed with code ${state.failure?.code ?? "unknown"}`,
              )
            case UploadStatus.CANCELED:
              throw new NativeUploadError("canceled", "Upload was canceled")
            case UploadStatus.EXPIRED:
              throw new NativeUploadError("rejected", "Upload expired before finalization completed")
            default:
              throw new NativeUploadError("protocol", "Server returned an invalid upload state")
          }
        }
        switch (result.state.oneofKind) {
          case "complete":
            job.settled = true
            this.#remove(job)
            job.resolve(result.state.complete)
            return
          case "failed":
            throw new NativeUploadError(
              result.state.failed.retryable ? "retryable" : "rejected",
              `Upload finalization failed with code ${result.state.failed.code}`,
            )
          case "missing":
            if (result.state.missing.partIndices.length === 0) {
              throw new NativeUploadError("protocol", "Server returned an empty missing-parts result")
            }
            validatePartIndices(result.state.missing.partIndices, job.upload.partCount)
            for (const index of result.state.missing.partIndices) job.accepted.delete(index)
            job.active = 0
            this.#pump()
            return
          case "processing":
            this.#resumeFinishAfter(
              job,
              boundedUploadProcessingRetrySeconds(result.state.processing.retryAfterSeconds),
            )
            return
          default:
            throw new NativeUploadError("protocol", "Server returned an empty finish result")
        }
      }
    } catch (error) {
      this.#reject(job, error)
    } finally {
      this.#finishing -= 1
      this.#pump()
    }
  }

  #resumeFinishAfter(job: UploadJob, seconds: number): void {
    void delay(seconds, job.input.signal).then(() => {
      if (job.settled) return
      job.active = 0
      void this.#finish(job)
    }, (error: unknown) => {
      if (!job.settled) this.#reject(job, error)
    })
  }

  #abort(job: UploadJob): void {
    if (job.settled) return
    this.#reject(job, new NativeUploadError("canceled", "Upload was canceled"))
    void this.rpc.cancel(
      { uploadId: job.upload.uploadId },
      AbortSignal.timeout(CANCEL_RPC_TIMEOUT_MS),
    ).catch(() => {})
  }

  #reject(job: UploadJob, error: unknown): void {
    if (job.settled) return
    job.settled = true
    this.#remove(job)
    job.reject(error instanceof Error ? error : new Error(String(error)))
  }

  #remove(job: UploadJob): void {
    job.removeAbortListener?.()
    job.removeAbortListener = undefined
    const index = this.#jobs.indexOf(job)
    if (index >= 0) this.#jobs.splice(index, 1)
    this.#cursor = this.#jobs.length === 0 ? 0 : this.#cursor % this.#jobs.length
  }
}

export const uploadByteSource = (value: Blob | Uint8Array | ArrayBuffer): UploadByteSource => {
  if (value instanceof Blob) {
    return {
      byteCount: value.size,
      read: async (offset, length) => new Uint8Array(await value.slice(offset, offset + length).arrayBuffer()),
    }
  }
  const bytes = value instanceof Uint8Array ? value : new Uint8Array(value)
  return {
    byteCount: bytes.length,
    read: async (offset, length) => bytes.slice(offset, offset + length),
  }
}

export const rpcUploadTransport = (
  call: (method: Method, input: import("./core.js").RpcCall["input"], signal?: AbortSignal) => Promise<import("./core.js").RpcResult["result"]>,
  shouldReplayCreate?: (error: unknown) => boolean,
): NativeUploadRpcTransport => ({
  shouldReplayCreate,
  create: async (input, signal) => {
    const result = await call(Method.CREATE_UPLOAD, { oneofKind: "createUpload", createUpload: input }, signal)
    if (result.oneofKind !== "createUpload") throw new NativeUploadError("protocol", "Unexpected createUpload result")
    return result.createUpload
  },
  savePart: async (input, signal) => {
    const result = await call(Method.SAVE_UPLOAD_PART, { oneofKind: "saveUploadPart", saveUploadPart: input }, signal)
    if (result.oneofKind !== "saveUploadPart") throw new NativeUploadError("protocol", "Unexpected saveUploadPart result")
    return result.saveUploadPart
  },
  state: async (input, signal) => {
    const result = await call(Method.GET_UPLOAD_STATE, { oneofKind: "getUploadState", getUploadState: input }, signal)
    if (result.oneofKind !== "getUploadState") throw new NativeUploadError("protocol", "Unexpected getUploadState result")
    return result.getUploadState
  },
  finish: async (input, signal) => {
    const result = await call(Method.FINISH_UPLOAD, { oneofKind: "finishUpload", finishUpload: input }, signal)
    if (result.oneofKind !== "finishUpload") throw new NativeUploadError("protocol", "Unexpected finishUpload result")
    return result.finishUpload
  },
  cancel: async (input, signal) => {
    const result = await call(Method.CANCEL_UPLOAD, { oneofKind: "cancelUpload", cancelUpload: input }, signal)
    if (result.oneofKind !== "cancelUpload") throw new NativeUploadError("protocol", "Unexpected cancelUpload result")
    return result.cancelUpload
  },
})

export class NativeUploadError extends Error {
  constructor(
    readonly code: "canceled" | "invalid_source" | "protocol" | "rejected" | "retryable" | "source_changed",
    message: string,
  ) {
    super(message)
    this.name = `NativeUploadError:${code}`
  }
}

export { UploadKind, UploadStatus }
