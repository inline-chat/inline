import { createHash } from "node:crypto"
import { describe, expect, test } from "bun:test"
import type { S3Client } from "@aws-sdk/client-s3"
import {
  MultipartIntegrityError,
  MultipartStorageUnavailableError,
  MultipartUploadNotFoundError,
  R2MultipartObjectStore,
  multipartEtag,
} from "./multipartStore"

const md5 = (bytes: Uint8Array): string => createHash("md5").update(bytes).digest("hex")

describe("native upload multipart object store", () => {
  test("computes the provider multipart ETag from ordered part digests", () => {
    const first = md5(new Uint8Array([1, 2, 3]))
    const second = md5(new Uint8Array([4, 5]))
    expect(multipartEtag([
      { partNumber: 1, etag: first },
      { partNumber: 2, etag: second },
    ])).toBe(`${createHash("md5").update(Buffer.concat([
      Buffer.from(first, "hex"), Buffer.from(second, "hex"),
    ])).digest("hex")}-2`)
  })

  test("sends Content-MD5 and rejects an upload-part ETag mismatch", async () => {
    const bytes = new Uint8Array([9, 8, 7])
    let contentMd5: string | undefined
    const client = {
      async send(command: { input: { ContentMD5?: string } }) {
        contentMd5 = command.input.ContentMD5
        return { ETag: `"${"0".repeat(32)}"` }
      },
    } as unknown as S3Client
    const store = new R2MultipartObjectStore({ bucket: "test", client })
    await expect(store.uploadPart({
      key: "key", uploadId: "upload", partNumber: 1, bytes,
    })).rejects.toBeInstanceOf(MultipartIntegrityError)
    expect(contentMd5).toBe(createHash("md5").update(bytes).digest("base64"))
  })

  test("maps NoSuchUpload to the rebuildable session error", async () => {
    const client = {
      async send() {
        const error = new Error("gone")
        error.name = "NoSuchUpload"
        throw error
      },
    } as unknown as S3Client
    const store = new R2MultipartObjectStore({ bucket: "test", client })
    await expect(store.complete({
      key: "key", uploadId: "expired", parts: [{ partNumber: 1, etag: "0".repeat(32) }],
    })).rejects.toBeInstanceOf(MultipartUploadNotFoundError)
  })

  test("rebuilds a provider session whose durable part projection is invalid", async () => {
    const client = {
      async send() {
        const error = new Error("one or more parts are missing")
        error.name = "InvalidPart"
        throw error
      },
    } as unknown as S3Client
    const store = new R2MultipartObjectStore({ bucket: "test", client })
    await expect(store.complete({
      key: "key", uploadId: "damaged", parts: [{ partNumber: 1, etag: "0".repeat(32) }],
    })).rejects.toBeInstanceOf(MultipartUploadNotFoundError)
  })

  test("bounds a provider request that never returns", async () => {
    let requestSignal: AbortSignal | undefined
    const client = {
      async send(_command: unknown, options?: { abortSignal?: AbortSignal }) {
        requestSignal = options?.abortSignal
        return new Promise<never>((_, reject) => {
          requestSignal?.addEventListener("abort", () => reject(requestSignal?.reason), { once: true })
        })
      },
    } as unknown as S3Client
    const store = new R2MultipartObjectStore(
      { bucket: "test", client },
      { operationTimeoutMs: 10 },
    )

    await expect(store.head("key")).rejects.toBeInstanceOf(MultipartStorageUnavailableError)
    expect(requestSignal?.aborted).toBe(true)
  })

  test("keeps the stream deadline active after response headers", async () => {
    let canceled = false
    const body = new ReadableStream<Uint8Array>({
      pull() {},
      cancel() { canceled = true },
    })
    const client = {
      async send() {
        return { Body: { transformToWebStream: () => body } }
      },
    } as unknown as S3Client
    const store = new R2MultipartObjectStore(
      { bucket: "test", client },
      { streamTimeoutMs: 10 },
    )

    const reader = (await store.stream("key")).getReader()
    await expect(reader.read()).rejects.toMatchObject({ name: "TimeoutError" })
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(canceled).toBe(true)
    expect(body.locked).toBe(false)
  })

  test("rejects malformed persisted part ETags before completion", () => {
    expect(() => multipartEtag([{ partNumber: 1, etag: "not-an-md5" }]))
      .toThrow(MultipartIntegrityError)
  })
})
