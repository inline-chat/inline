import { DeleteObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3"
import { createHash } from "node:crypto"
import { getR2 } from "@in/server/libs/r2"
import { readFileBytes, FileByteLengthError } from "@in/server/modules/files/readFileBytes"
import { INLINE_TRANSFER_PART_SIZE } from "@inline-chat/protocol/transfers"
import {
  createR2S3Configuration,
  storageDeadlineSignal,
  type R2S3Configuration,
} from "./multipartStore"

const STAGING_PREFIX = "inline-upload-parts/v1"
// Identity frames are 512 KiB. Reserve bounded headroom for a later
// authenticated frame envelope without permitting unbounded staging reads.
export const MAX_STORED_FRAME_BYTES = INLINE_TRANSFER_PART_SIZE + 64 * 1_024
const DEFAULT_STAGING_READ_TIMEOUT_MS = 60_000
const DEFAULT_STAGING_OPERATION_TIMEOUT_MS = 60_000

type UploadPartStoreOptions = {
  configuration?: R2S3Configuration
  readStream?: (key: string) => ReadableStream<Uint8Array>
  readTimeoutMs?: number
  operationTimeoutMs?: number
  removePart?: (key: string, signal?: AbortSignal) => Promise<void>
}

export interface UploadPartStore {
  put(input: {
    uploadId: Uint8Array
    partIndex: number
    sha256: Uint8Array
    data: Uint8Array
  }, signal?: AbortSignal): Promise<string>
  read(objectKey: string, byteCount: number, signal?: AbortSignal): Promise<Uint8Array>
  remove(objectKey: string, signal?: AbortSignal): Promise<void>
}

const requireR2 = () => {
  const r2 = getR2()
  if (!r2) throw new UploadPartStorageUnavailableError()
  return r2
}

const objectKey = ({
  uploadId,
  partIndex,
  sha256,
}: {
  uploadId: Uint8Array
  partIndex: number
  sha256: Uint8Array
}): string => {
  const id = Buffer.from(uploadId).toString("base64url")
  const digest = Buffer.from(sha256).toString("hex")
  return `${STAGING_PREFIX}/${id}/${partIndex}-${digest}`
}

export class R2UploadPartStore implements UploadPartStore {
  #configuration: R2S3Configuration | undefined
  readonly #writePart: (key: string, data: Uint8Array, signal?: AbortSignal) => Promise<number>
  readonly #removePart: (key: string, signal?: AbortSignal) => Promise<void>
  readonly #readStream: (key: string) => ReadableStream<Uint8Array>
  readonly #readTimeoutMs: number
  readonly #operationTimeoutMs: number

  constructor(
    writePart?: (
      key: string,
      data: Uint8Array,
      signal?: AbortSignal,
    ) => Promise<number>,
    options: UploadPartStoreOptions = {},
  ) {
    this.#configuration = options.configuration
    this.#readStream = options.readStream ?? ((key) => requireR2().file(key).stream())
    this.#readTimeoutMs = options.readTimeoutMs ?? DEFAULT_STAGING_READ_TIMEOUT_MS
    this.#operationTimeoutMs = options.operationTimeoutMs ?? DEFAULT_STAGING_OPERATION_TIMEOUT_MS
    this.#writePart = writePart ?? (async (key, data, signal) => {
      const md5 = createHash("md5").update(data).digest()
      const { bucket, client } = this.#requireConfiguration()
      const result = await client.send(new PutObjectCommand({
        Body: data,
        Bucket: bucket,
        ContentLength: data.byteLength,
        ContentMD5: md5.toString("base64"),
        ContentType: "application/octet-stream",
        Key: key,
      }), { abortSignal: signal })
      const etag = result.ETag?.trim().replace(/^"|"$/g, "").toLowerCase()
      if (etag !== md5.toString("hex")) throw new Error("Upload staging object ETag mismatch")
      return data.byteLength
    })
    this.#removePart = options.removePart ?? (async (key, signal) => {
      const { bucket, client } = this.#requireConfiguration()
      await client.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }), {
        abortSignal: signal,
      })
    })
    if (!Number.isSafeInteger(this.#readTimeoutMs) || this.#readTimeoutMs < 1 ||
        !Number.isSafeInteger(this.#operationTimeoutMs) || this.#operationTimeoutMs < 1) {
      throw new RangeError("Invalid upload staging timeout")
    }
  }

  #requireConfiguration(): R2S3Configuration {
    return this.#configuration ??= createR2S3Configuration()
  }

  async put(input: {
    uploadId: Uint8Array
    partIndex: number
    sha256: Uint8Array
    data: Uint8Array
  }, signal?: AbortSignal): Promise<string> {
    const key = objectKey(input)
    try {
      const written = await this.#writePart(
        key,
        input.data,
        storageDeadlineSignal(signal, this.#operationTimeoutMs),
      )
      if (written !== input.data.byteLength) {
        throw new Error(`Upload part storage wrote ${written} of ${input.data.byteLength} bytes`)
      }
    } catch (cause) {
      signal?.throwIfAborted()
      throw new UploadPartStorageUnavailableError({ cause })
    }
    return key
  }

  async read(key: string, byteCount: number, signal?: AbortSignal): Promise<Uint8Array> {
    signal?.throwIfAborted()
    if (!Number.isInteger(byteCount) || byteCount < 1 || byteCount > MAX_STORED_FRAME_BYTES) {
      throw new UploadPartStorageUnavailableError()
    }
    try {
      const deadline = AbortSignal.timeout(this.#readTimeoutMs)
      const readSignal = signal ? AbortSignal.any([signal, deadline]) : deadline
      return await readFileBytes(this.#readStream(key), byteCount, readSignal)
    } catch (cause) {
      signal?.throwIfAborted()
      if (cause instanceof FileByteLengthError) throw cause
      throw new UploadPartStorageUnavailableError({ cause })
    }
  }

  async remove(key: string, signal?: AbortSignal): Promise<void> {
    try {
      await this.#removePart(key, storageDeadlineSignal(signal, this.#operationTimeoutMs))
    } catch (cause) {
      signal?.throwIfAborted()
      throw new UploadPartStorageUnavailableError({ cause })
    }
  }
}

export class UploadPartStorageUnavailableError extends Error {
  constructor(options?: ErrorOptions) {
    super("Upload part storage is unavailable", options)
    this.name = "UploadPartStorageUnavailableError"
  }
}
