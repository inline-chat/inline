import { createHash } from "node:crypto"
import { describe, expect, test } from "bun:test"
import { GetFilePartInput, RpcError_Code } from "@inline-chat/protocol/core"
import { INLINE_TRANSFER_MAX_LOCATOR_ID } from "@inline-chat/protocol/transfers"
import type { DbFile } from "@in/server/db/schema"
import { encrypt } from "@in/server/modules/encryption/encryption"
import type { HandlerContext } from "@in/server/realtime/types"
import { NativeDownloadOperations } from "./downloads"
import { readFileBytes, FileByteLengthError } from "./readFileBytes"

const context: HandlerContext = {
  userId: 1, sessionId: 2, connectionId: "test", sendRaw() {}, sendRpcReply() {},
  inlineProtocol: { permanentAuthKeyId: new Uint8Array(8) },
}
const bytes = new Uint8Array([1, 2, 3, 4, 5])
const encrypted = encrypt("test-download")
const file = { fileSize: 5, pathEncrypted: encrypted.encrypted, pathIv: encrypted.iv, pathTag: encrypted.authTag } as DbFile
const request = (offset = 0n, limit = 4) => GetFilePartInput.create({ fileUniqueId: "IND_test", offset, limit })

describe("native download ranges", () => {
  test("does not serve file bytes on the legacy carrier", async () => {
    let lookups = 0
    const operations = new NativeDownloadOperations(async () => { lookups += 1; return file })
    await expect(operations.getPart(request(), { ...context, inlineProtocol: undefined })).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    expect(lookups).toBe(0)
  })

  test("reads only the requested range, returns exact tail/EOF and a digest", async () => {
    const calls: number[][] = []
    const operations = new NativeDownloadOperations(async () => file, async (_path, offset, length) => {
      calls.push([offset, length])
      return bytes.slice(offset, offset + length)
    })
    expect(await operations.getPart(request(), context)).toEqual({
      offset: 0n, totalSize: 5n, data: bytes.slice(0, 4),
      sha256: createHash("sha256").update(bytes.slice(0, 4)).digest(),
    })
    expect((await operations.getPart(request(4n), context)).data).toEqual(new Uint8Array([5]))
    expect((await operations.getPart(request(5n), context)).data.length).toBe(0)
    expect(calls).toEqual([[0, 4], [4, 1]])
    await expect(operations.getPart(request(6n), context)).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
  })

  test("rejects malformed ranges before authorization or storage I/O", async () => {
    let lookups = 0
    const operations = new NativeDownloadOperations(async () => { lookups += 1; return file })
    for (const input of [request(-1n), request(2n ** 63n), request(0n, 0), request(0n, 524289),
      request(0n, 1.5), { ...request(), message: { chatId: 1n, messageId: 0n } },
      { ...request(), message: { chatId: INLINE_TRANSFER_MAX_LOCATOR_ID + 1n, messageId: 1n } }]) {
      await expect(operations.getPart(input, context)).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    }
    expect(lookups).toBe(0)
  })

  test("does not read missing or unauthorized files", async () => {
    let reads = 0
    const operations = new NativeDownloadOperations(async () => undefined, async () => { reads += 1; return bytes })
    await expect(operations.getPart(request(), context)).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    expect(reads).toBe(0)
  })

  test("holds per-session admission until reads settle and recovers after failure", async () => {
    let release!: () => void
    const gate = new Promise<void>((resolve) => { release = resolve })
    const operations = new NativeDownloadOperations(async () => file, async () => { await gate; throw new Error("storage failed") })
    const pending = Array.from({ length: 8 }, () => operations.getPart(request(), context).catch((error: unknown) => error))
    await expect(operations.getPart(request(), context)).rejects.toMatchObject({ code: RpcError_Code.RATE_LIMIT })
    release()
    await Promise.all(pending)
    await expect(operations.getPart(request(), context)).rejects.toThrow("storage failed")
  })

  test("bounds global reads across different account sessions", async () => {
    let release!: () => void
    const gate = new Promise<void>((resolve) => { release = resolve })
    const operations = new NativeDownloadOperations(async () => file, async () => { await gate; return bytes.slice(0, 4) })
    const pending = Array.from({ length: 64 }, (_, sessionId) => operations.getPart(request(), { ...context, sessionId }))
    await expect(operations.getPart(request(), { ...context, sessionId: 100 })).rejects.toMatchObject({ code: RpcError_Code.RATE_LIMIT })
    release()
    await Promise.all(pending)
    expect((await operations.getPart(request(), context)).data.length).toBe(4)
  })

  test("fails closed on short or oversized storage responses", async () => {
    for (const length of [3, 5]) {
      const operations = new NativeDownloadOperations(async () => file, async () => new Uint8Array(length))
      await expect(operations.getPart(request(), context)).rejects.toMatchObject({ code: RpcError_Code.INTERNAL_ERROR })
      const stream = new ReadableStream<Uint8Array>({ start(c) { c.enqueue(new Uint8Array(length)); c.close() } })
      await expect(readFileBytes(stream, 4)).rejects.toBeInstanceOf(FileByteLengthError)
    }
  })

  test("cancellation closes a pending storage stream", async () => {
    const abort = new AbortController()
    let canceled = false
    const stream = new ReadableStream<Uint8Array>({ cancel() { canceled = true } })
    const read = readFileBytes(stream, 4, abort.signal)
    abort.abort()
    await expect(read).rejects.toMatchObject({ name: "AbortError" })
    expect(canceled).toBe(true)
  })

  test("cancellation during lookup prevents storage I/O", async () => {
    const abort = new AbortController()
    let reads = 0
    const operations = new NativeDownloadOperations(async () => { abort.abort(); return file }, async () => { reads += 1; return bytes })
    await expect(operations.getPart(request(), { ...context, signal: abort.signal })).rejects.toMatchObject({ name: "AbortError" })
    expect(reads).toBe(0)
  })
})
