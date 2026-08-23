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

const HASH_READ_SIZE = 1024 * 1024
const MAX_NEGOTIATED_PART_SIZE = 16 * 1024 * 1024
const DEFAULT_GLOBAL_CONCURRENCY = 3
const DEFAULT_UPLOAD_CONCURRENCY = 2
const MAX_FINISH_RECONCILIATION_ATTEMPTS = 3
const FINISH_RECONCILIATION_DELAY_SECONDS = 1
const MAX_PROCESSING_RETRY_SECONDS = 30

const boundedUploadProcessingRetrySeconds = (seconds: number): number =>
  Number.isNaN(seconds)
    ? 1
    : Math.min(MAX_PROCESSING_RETRY_SECONDS, Math.max(1, Math.floor(seconds)))

export interface UploadByteSource {
  readonly byteCount: number
  read(offset: number, length: number): Promise<Uint8Array>
}

export type NativeUploadInput = {
  source: UploadByteSource
  fileName: string
  mimeType: string
  kind: UploadKind
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
  create(input: CreateUploadInput): Promise<CreateUploadResult>
  savePart(input: { uploadId: Uint8Array; partIndex: number; data: Uint8Array }): Promise<SaveUploadPartResult>
  state(input: { uploadId: Uint8Array }): Promise<GetUploadStateResult>
  finish(input: { uploadId: Uint8Array }): Promise<FinishUploadResult>
  cancel(input: { uploadId: Uint8Array }): Promise<CancelUploadResult>
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
}

const randomUploadId = (): Uint8Array => {
  const bytes = new Uint8Array(16)
  globalThis.crypto.getRandomValues(bytes)
  return bytes
}

const exactRead = async (source: UploadByteSource, offset: number, length: number): Promise<Uint8Array> => {
  const bytes = await source.read(offset, length)
  if (bytes.length !== length) throw new NativeUploadError("source_changed", "Upload source changed while it was being read")
  return bytes
}

const sourceHash = async (source: UploadByteSource, signal?: AbortSignal): Promise<Uint8Array> => {
  const hash = sha256.create()
  for (let offset = 0; offset < source.byteCount; offset += HASH_READ_SIZE) {
    if (signal?.aborted) throw new NativeUploadError("canceled", "Upload was canceled")
    const length = Math.min(HASH_READ_SIZE, source.byteCount - offset)
    hash.update(await exactRead(source, offset, length))
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

const delay = async (seconds: number, signal?: AbortSignal): Promise<void> => {
  if (signal?.aborted) throw new NativeUploadError("canceled", "Upload was canceled")
  await new Promise<void>((resolve, reject) => {
    const onAbort = () => {
      clearTimeout(timeout)
      reject(new NativeUploadError("canceled", "Upload was canceled"))
    }
    const timeout = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort)
      resolve()
    }, Math.max(1, seconds) * 1_000)
    signal?.addEventListener("abort", onAbort, { once: true })
  })
}

export class NativeUploadClient {
  readonly #jobs: UploadJob[] = []
  #active = 0
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
    if (input.signal?.aborted) throw new NativeUploadError("canceled", "Upload was canceled")
    const clientUploadId = input.clientUploadId?.slice() ?? randomUploadId()
    if (clientUploadId.length !== 16) throw new NativeUploadError("invalid_source", "Client upload ID must be 16 bytes")
    const digest = await sourceHash(input.source, input.signal)
    const created = await this.rpc.create({
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
    })
    if (created.uploadId.length !== 16 || created.partSize < 1 ||
        created.partSize > MAX_NEGOTIATED_PART_SIZE || created.partCount < 1 ||
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
      input.onProgress?.({ acceptedBytes: acceptedBytes(job), totalBytes: input.source.byteCount })
      input.signal?.addEventListener("abort", () => void this.#abort(job), { once: true })
      this.#pump()
    })
  }

  #pump(): void {
    while (this.#active < this.globalConcurrency) {
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
      const data = await exactRead(job.input.source, offset, length)
      await this.rpc.savePart({ uploadId: job.upload.uploadId, partIndex, data })
      job.accepted.add(partIndex)
      job.input.onProgress?.({ acceptedBytes: acceptedBytes(job), totalBytes: job.input.source.byteCount })
    } catch (error) {
      if (!job.settled && !job.input.signal?.aborted) {
        try {
          const state = await this.rpc.state({ uploadId: job.upload.uploadId })
          if (state.acceptedParts.includes(partIndex)) {
            job.accepted.add(partIndex)
            job.input.onProgress?.({ acceptedBytes: acceptedBytes(job), totalBytes: job.input.source.byteCount })
          } else {
            this.#reject(job, error)
          }
        } catch {
          this.#reject(job, error)
        }
      }
    } finally {
      job.queued.delete(partIndex)
      job.active -= 1
      this.#active -= 1
      this.#pump()
      if (!job.settled && job.active === 0 && this.#nextPart(job) === undefined) void this.#finish(job)
    }
  }

  async #finish(job: UploadJob): Promise<void> {
    if (job.settled || job.active > 0) return
    job.active = -1
    let reconciliationAttempts = 0
    try {
      for (;;) {
        if (job.input.signal?.aborted) throw new NativeUploadError("canceled", "Upload was canceled")
        let result: FinishUploadResult
        try {
          result = await this.rpc.finish({ uploadId: job.upload.uploadId })
        } catch (error) {
          if (job.input.signal?.aborted) throw new NativeUploadError("canceled", "Upload was canceled")
          if (++reconciliationAttempts > MAX_FINISH_RECONCILIATION_ATTEMPTS) throw error

          let state: GetUploadStateResult
          try {
            state = await this.rpc.state({ uploadId: job.upload.uploadId })
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
              await delay(FINISH_RECONCILIATION_DELAY_SECONDS, job.input.signal)
              continue
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
            validatePartIndices(result.state.missing.partIndices, job.upload.partCount)
            for (const index of result.state.missing.partIndices) job.accepted.delete(index)
            job.active = 0
            this.#pump()
            return
          case "processing":
            await delay(
              boundedUploadProcessingRetrySeconds(result.state.processing.retryAfterSeconds),
              job.input.signal,
            )
            break
          default:
            throw new NativeUploadError("protocol", "Server returned an empty finish result")
        }
      }
    } catch (error) {
      this.#reject(job, error)
    }
  }

  async #abort(job: UploadJob): Promise<void> {
    if (job.settled) return
    await this.rpc.cancel({ uploadId: job.upload.uploadId }).catch(() => {})
    this.#reject(job, new NativeUploadError("canceled", "Upload was canceled"))
  }

  #reject(job: UploadJob, error: unknown): void {
    if (job.settled) return
    job.settled = true
    this.#remove(job)
    job.reject(error instanceof Error ? error : new Error(String(error)))
  }

  #remove(job: UploadJob): void {
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
  call: (method: Method, input: import("./core.js").RpcCall["input"]) => Promise<import("./core.js").RpcResult["result"]>,
): NativeUploadRpcTransport => ({
  create: async (input) => {
    const result = await call(Method.CREATE_UPLOAD, { oneofKind: "createUpload", createUpload: input })
    if (result.oneofKind !== "createUpload") throw new NativeUploadError("protocol", "Unexpected createUpload result")
    return result.createUpload
  },
  savePart: async (input) => {
    const result = await call(Method.SAVE_UPLOAD_PART, { oneofKind: "saveUploadPart", saveUploadPart: input })
    if (result.oneofKind !== "saveUploadPart") throw new NativeUploadError("protocol", "Unexpected saveUploadPart result")
    return result.saveUploadPart
  },
  state: async (input) => {
    const result = await call(Method.GET_UPLOAD_STATE, { oneofKind: "getUploadState", getUploadState: input })
    if (result.oneofKind !== "getUploadState") throw new NativeUploadError("protocol", "Unexpected getUploadState result")
    return result.getUploadState
  },
  finish: async (input) => {
    const result = await call(Method.FINISH_UPLOAD, { oneofKind: "finishUpload", finishUpload: input })
    if (result.oneofKind !== "finishUpload") throw new NativeUploadError("protocol", "Unexpected finishUpload result")
    return result.finishUpload
  },
  cancel: async (input) => {
    const result = await call(Method.CANCEL_UPLOAD, { oneofKind: "cancelUpload", cancelUpload: input })
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
