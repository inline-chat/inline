import {
  AbortMultipartUploadCommand,
  CompleteMultipartUploadCommand,
  CreateMultipartUploadCommand,
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  S3Client,
  UploadPartCommand,
} from "@aws-sdk/client-s3"
import { createHash } from "node:crypto"
import {
  R2_ACCESS_KEY_ID,
  R2_BUCKET,
  R2_ENDPOINT,
  R2_SECRET_ACCESS_KEY,
} from "@in/server/env"

export type MultipartUploadedPart = {
  readonly etag: string
  readonly partNumber: number
}

export type MultipartObjectHead = {
  readonly byteCount: number
  readonly etag: string
}

export interface MultipartObjectStore {
  create(key: string, contentType: string, signal?: AbortSignal): Promise<string>
  uploadPart(input: {
    key: string
    uploadId: string
    partNumber: number
    bytes: Uint8Array
    signal?: AbortSignal
  }): Promise<MultipartUploadedPart>
  complete(input: {
    key: string
    uploadId: string
    parts: MultipartUploadedPart[]
    signal?: AbortSignal
  }): Promise<{ etag: string }>
  abort(key: string, uploadId: string, signal?: AbortSignal): Promise<void>
  head(key: string, signal?: AbortSignal): Promise<MultipartObjectHead | undefined>
  stream(key: string, signal?: AbortSignal): Promise<ReadableStream<Uint8Array>>
  remove(key: string, signal?: AbortSignal): Promise<void>
}

const DEFAULT_OPERATION_TIMEOUT_MS = 60_000
const DEFAULT_STREAM_TIMEOUT_MS = 5 * 60_000

type MultipartObjectStoreOptions = {
  operationTimeoutMs?: number
  streamTimeoutMs?: number
}

export const storageDeadlineSignal = (signal: AbortSignal | undefined, timeoutMs: number): AbortSignal => {
  const deadline = AbortSignal.timeout(timeoutMs)
  return signal ? AbortSignal.any([signal, deadline]) : deadline
}

const streamWithSignal = <T>(source: ReadableStream<T>, signal: AbortSignal): ReadableStream<T> => {
  const reader = source.getReader()
  let controller: ReadableStreamDefaultController<T> | undefined
  let settled = false
  let readerReleased = false
  const removeAbortListener = () => signal.removeEventListener("abort", onAbort)
  const releaseReader = () => {
    if (readerReleased) return
    readerReleased = true
    try {
      reader.releaseLock()
    } catch {
      // Cancellation settles an in-flight read before releasing the lock.
    }
  }
  const onAbort = () => {
    if (settled) return
    settled = true
    const reason = signal.reason ?? new DOMException("The operation was aborted", "AbortError")
    removeAbortListener()
    controller?.error(reason)
    void reader.cancel(reason).catch(() => {}).finally(releaseReader)
  }
  return new ReadableStream<T>({
    start(value) {
      controller = value
      signal.addEventListener("abort", onAbort, { once: true })
      if (signal.aborted) onAbort()
    },
    async pull(value) {
      if (settled) return
      try {
        const result = await reader.read()
        if (settled) return
        if (result.done) {
          settled = true
          removeAbortListener()
          releaseReader()
          value.close()
        } else {
          value.enqueue(result.value)
        }
      } catch (cause) {
        if (settled) return
        settled = true
        removeAbortListener()
        releaseReader()
        value.error(cause)
      }
    },
    async cancel(reason) {
      if (settled) return
      settled = true
      removeAbortListener()
      try {
        await reader.cancel(reason)
      } finally {
        releaseReader()
      }
    },
  })
}

const normalizeEtag = (etag: string | undefined): string => {
  const normalized = etag?.trim().replace(/^"|"$/g, "").toLowerCase()
  if (!normalized) throw new MultipartStorageUnavailableError()
  return normalized
}

const isNotFound = (error: unknown): boolean => {
  if (!error || typeof error !== "object") return false
  const value = error as { name?: unknown; $metadata?: { httpStatusCode?: unknown } }
  return value.name === "NotFound" || value.name === "NoSuchKey" || value.$metadata?.httpStatusCode === 404
}

const isNoSuchUpload = (error: unknown): boolean => {
  if (!error || typeof error !== "object") return false
  const value = error as { name?: unknown; Code?: unknown; code?: unknown }
  return value.name === "NoSuchUpload" || value.Code === "NoSuchUpload" || value.code === "NoSuchUpload"
}

const isInvalidMultipartManifest = (error: unknown): boolean => {
  if (!error || typeof error !== "object") return false
  const value = error as { name?: unknown; Code?: unknown; code?: unknown }
  return value.name === "InvalidPart" || value.Code === "InvalidPart" || value.code === "InvalidPart" ||
    value.name === "InvalidPartOrder" || value.Code === "InvalidPartOrder" || value.code === "InvalidPartOrder"
}

export type R2S3Configuration = {
  bucket: string
  client: S3Client
}

export const createR2S3Configuration = (): R2S3Configuration => {
  if (!R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY || !R2_BUCKET || !R2_ENDPOINT) {
    throw new MultipartStorageUnavailableError()
  }
  return {
    bucket: R2_BUCKET,
    client: new S3Client({
      credentials: {
        accessKeyId: R2_ACCESS_KEY_ID,
        secretAccessKey: R2_SECRET_ACCESS_KEY,
      },
      endpoint: R2_ENDPOINT,
      region: "auto",
      // The SDK's default WHEN_SUPPORTED mode adds CRC32 to PutObject and
      // UploadPart. R2 rejects that alongside our explicit Content-MD5, which
      // is required for the ETag integrity check below.
      requestChecksumCalculation: "WHEN_REQUIRED",
    }),
  }
}

export class R2MultipartObjectStore implements MultipartObjectStore {
  #configuration: { bucket: string; client: S3Client } | undefined
  readonly #operationTimeoutMs: number
  readonly #streamTimeoutMs: number

  constructor(
    configuration?: { bucket: string; client: S3Client },
    options: MultipartObjectStoreOptions = {},
  ) {
    this.#configuration = configuration
    this.#operationTimeoutMs = options.operationTimeoutMs ?? DEFAULT_OPERATION_TIMEOUT_MS
    this.#streamTimeoutMs = options.streamTimeoutMs ?? DEFAULT_STREAM_TIMEOUT_MS
    if (!Number.isSafeInteger(this.#operationTimeoutMs) || this.#operationTimeoutMs < 1 ||
        !Number.isSafeInteger(this.#streamTimeoutMs) || this.#streamTimeoutMs < 1) {
      throw new RangeError("Invalid multipart object-store timeout")
    }
  }

  #requireConfiguration(): { bucket: string; client: S3Client } {
    return this.#configuration ??= createR2S3Configuration()
  }

  async create(key: string, contentType: string, signal?: AbortSignal): Promise<string> {
    try {
      const { bucket, client } = this.#requireConfiguration()
      const result = await client.send(new CreateMultipartUploadCommand({
        Bucket: bucket,
        ContentType: contentType,
        Key: key,
      }), { abortSignal: storageDeadlineSignal(signal, this.#operationTimeoutMs) })
      if (!result.UploadId) throw new MultipartStorageUnavailableError()
      return result.UploadId
    } catch (cause) {
      if (cause instanceof MultipartStorageUnavailableError) throw cause
      throw new MultipartStorageUnavailableError({ cause })
    }
  }

  async uploadPart(input: {
    key: string
    uploadId: string
    partNumber: number
    bytes: Uint8Array
    signal?: AbortSignal
  }): Promise<MultipartUploadedPart> {
    const md5 = createHash("md5").update(input.bytes).digest()
    try {
      const { bucket, client } = this.#requireConfiguration()
      const result = await client.send(new UploadPartCommand({
        Body: input.bytes,
        Bucket: bucket,
        ContentLength: input.bytes.byteLength,
        ContentMD5: md5.toString("base64"),
        Key: input.key,
        PartNumber: input.partNumber,
        UploadId: input.uploadId,
      }), { abortSignal: storageDeadlineSignal(input.signal, this.#operationTimeoutMs) })
      const etag = normalizeEtag(result.ETag)
      if (etag !== md5.toString("hex")) throw new MultipartIntegrityError()
      return { etag, partNumber: input.partNumber }
    } catch (cause) {
      if (cause instanceof MultipartIntegrityError) throw cause
      if (isNoSuchUpload(cause)) throw new MultipartUploadNotFoundError({ cause })
      throw new MultipartStorageUnavailableError({ cause })
    }
  }

  async complete(input: {
    key: string
    uploadId: string
    parts: MultipartUploadedPart[]
    signal?: AbortSignal
  }): Promise<{ etag: string }> {
    try {
      const { bucket, client } = this.#requireConfiguration()
      const result = await client.send(new CompleteMultipartUploadCommand({
        Bucket: bucket,
        Key: input.key,
        MultipartUpload: {
          Parts: input.parts.map((part) => ({
            ETag: `"${part.etag}"`,
            PartNumber: part.partNumber,
          })),
        },
        UploadId: input.uploadId,
      }), { abortSignal: storageDeadlineSignal(input.signal, this.#operationTimeoutMs) })
      return { etag: normalizeEtag(result.ETag) }
    } catch (cause) {
      // A provider can retain the multipart session while losing or rejecting
      // one projected part after a crash. Rebuilding from durable staging is
      // the only safe recovery; blind Complete retries cannot repair it.
      if (isNoSuchUpload(cause) || isInvalidMultipartManifest(cause)) {
        throw new MultipartUploadNotFoundError({ cause })
      }
      throw new MultipartStorageUnavailableError({ cause })
    }
  }

  async abort(key: string, uploadId: string, signal?: AbortSignal): Promise<void> {
    try {
      const { bucket, client } = this.#requireConfiguration()
      await client.send(new AbortMultipartUploadCommand({
        Bucket: bucket,
        Key: key,
        UploadId: uploadId,
      }), { abortSignal: storageDeadlineSignal(signal, this.#operationTimeoutMs) })
    } catch (cause) {
      if (isNoSuchUpload(cause)) return
      throw new MultipartStorageUnavailableError({ cause })
    }
  }

  async head(key: string, signal?: AbortSignal): Promise<MultipartObjectHead | undefined> {
    try {
      const { bucket, client } = this.#requireConfiguration()
      const result = await client.send(new HeadObjectCommand({
        Bucket: bucket,
        Key: key,
      }), { abortSignal: storageDeadlineSignal(signal, this.#operationTimeoutMs) })
      if (result.ContentLength === undefined) throw new MultipartStorageUnavailableError()
      return { byteCount: result.ContentLength, etag: normalizeEtag(result.ETag) }
    } catch (cause) {
      if (isNotFound(cause)) return undefined
      if (cause instanceof MultipartStorageUnavailableError) throw cause
      throw new MultipartStorageUnavailableError({ cause })
    }
  }

  async stream(key: string, signal?: AbortSignal): Promise<ReadableStream<Uint8Array>> {
    try {
      const { bucket, client } = this.#requireConfiguration()
      const streamSignal = storageDeadlineSignal(signal, this.#streamTimeoutMs)
      const result = await client.send(new GetObjectCommand({
        Bucket: bucket,
        Key: key,
      }), { abortSignal: streamSignal })
      if (!result.Body) throw new MultipartStorageUnavailableError()
      return streamWithSignal(
        result.Body.transformToWebStream() as ReadableStream<Uint8Array>,
        streamSignal,
      )
    } catch (cause) {
      if (cause instanceof MultipartStorageUnavailableError) throw cause
      throw new MultipartStorageUnavailableError({ cause })
    }
  }

  async remove(key: string, signal?: AbortSignal): Promise<void> {
    try {
      const { bucket, client } = this.#requireConfiguration()
      await client.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }), {
        abortSignal: storageDeadlineSignal(signal, this.#operationTimeoutMs),
      })
    } catch (cause) {
      throw new MultipartStorageUnavailableError({ cause })
    }
  }
}

export const multipartEtag = (parts: MultipartUploadedPart[]): string => {
  if (parts.length === 0) throw new RangeError("Multipart upload requires at least one part")
  const digests = parts.map(({ etag }) => {
    const normalized = normalizeEtag(etag)
    if (!/^[a-f0-9]{32}$/.test(normalized)) throw new MultipartIntegrityError()
    return Buffer.from(normalized, "hex")
  })
  return `${createHash("md5").update(Buffer.concat(digests)).digest("hex")}-${parts.length}`
}

export class MultipartStorageUnavailableError extends Error {
  constructor(options?: ErrorOptions) {
    super("Multipart object storage is unavailable", options)
    this.name = "MultipartStorageUnavailableError"
  }
}

export class MultipartUploadNotFoundError extends Error {
  constructor(options?: ErrorOptions) {
    super("Multipart upload no longer exists", options)
    this.name = "MultipartUploadNotFoundError"
  }
}

export class MultipartIntegrityError extends Error {
  constructor() {
    super("Multipart object integrity validation failed")
    this.name = "MultipartIntegrityError"
  }
}
