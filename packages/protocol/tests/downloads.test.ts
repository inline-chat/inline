import { describe, expect, test } from "bun:test"
import { sha256 } from "@noble/hashes/sha2.js"
import { Document, GetFilePartInput, GetFilePartResult, Method, PhotoSize, RpcCall, RpcResult, Video, Voice } from "../src/core.js"
import { NativeDownloadClient, rpcDownloadTransport, type NativeDownloadRpcTransport } from "../src/downloads.js"
import { decodeInlineApplicationObject, encodeInlineResult } from "../src/secure/application.js"
import { decryptRecord, encryptRecord } from "../src/secure/record.js"
import { INLINE_TRANSFER_MAX_LOCATOR_ID, INLINE_TRANSFER_PART_SIZE } from "../src/transfers.js"

const source = Uint8Array.from(
  { length: INLINE_TRANSFER_PART_SIZE * 3 + 1 },
  (_, index) => index % 251,
)
const input = { fileUniqueId: "IND_test" }
const part = (request: GetFilePartInput): GetFilePartResult => {
  const data = source.slice(Number(request.offset), Number(request.offset) + request.limit)
  return { offset: request.offset, totalSize: BigInt(source.length), data, sha256: sha256(data) }
}
const deferred = () => {
  let resolve!: () => void
  const promise = new Promise<void>((done) => { resolve = done })
  return { promise, resolve }
}

describe("native downloads", () => {
  test("maximum download range survives protobuf, application and encrypted record serialization", () => {
    const data = Uint8Array.from({ length: 524288 }, (_, index) => index % 251)
    const result = RpcResult.create({ result: { oneofKind: "getFilePart", getFilePart: {
      offset: 0n, totalSize: BigInt(data.length), data, sha256: sha256(data),
    } } })
    const body = encodeInlineResult(RpcResult.toBinary(result))
    const key = new Uint8Array(256).fill(7)
    const padding = new Uint8Array(12 + (16 - ((32 + body.length + 12) % 16)) % 16)
    const record = encryptRecord(key, "server-to-client", {
      serverSalt: 1n, sessionId: 2n, messageId: (1000n << 32n) | 1n, sequenceNumber: 1, body,
    }, padding)
    expect(record.length).toBeLessThan(1024 * 1024)
    const decoded = decodeInlineApplicationObject(decryptRecord(record, key, {
      direction: "server-to-client", sessionId: 2n, validServerSalts: new Set([1n]), nowSeconds: 1000,
    }).body)
    expect(decoded.kind).toBe("result")
    expect(RpcResult.fromBinary(decoded.payload)).toEqual(result)
  })

  test("fixed Swift/TypeScript wire vectors preserve tags, binary payloads and uint64 precision", () => {
    // Also asserted in NativeDownloadTests.swift; independent of generated roundtrips.
    const callHex = "088801ca081e0a08494e445f77697265108180808080808010188080202205087b10c803"
    const resultHex = "ca08390881808080808080101084808080808080101a0300ff8022200000000000000000000000000000000000000000000000000000000000000000"
    const call = RpcCall.create({ method: Method.GET_FILE_PART, input: { oneofKind: "getFilePart", getFilePart: {
      fileUniqueId: "IND_wire", offset: 9007199254740993n, limit: 524288, message: { chatId: 123n, messageId: 456n },
    } } })
    expect(Buffer.from(RpcCall.toBinary(call)).toString("hex")).toBe(callHex)
    expect(RpcCall.fromBinary(Buffer.from(callHex, "hex"))).toEqual(call)
    const result = RpcResult.create({ result: { oneofKind: "getFilePart", getFilePart: {
      offset: 9007199254740993n, totalSize: 9007199254740996n, data: Uint8Array.of(0, 255, 128), sha256: new Uint8Array(32),
    } } })
    expect(Buffer.from(RpcResult.toBinary(result)).toString("hex")).toBe(resultHex)
    expect(RpcResult.fromBinary(Buffer.from(resultHex, "hex"))).toEqual(result)
    const media = [
      [Document.fromBinary(new Uint8Array()), Document.toBinary(Document.create({ fileUniqueId: "IND_wire" }))],
      [Video.fromBinary(new Uint8Array()), Video.toBinary(Video.create({ fileUniqueId: "IND_wire" }))],
      [Voice.fromBinary(new Uint8Array()), Voice.toBinary(Voice.create({ fileUniqueId: "IND_wire" }))],
      [PhotoSize.fromBinary(new Uint8Array()), PhotoSize.toBinary(PhotoSize.create({ fileUniqueId: "IND_wire" }))],
    ] as const
    for (const [old, current] of media) {
      expect(old.fileUniqueId).toBeUndefined()
      expect(Buffer.from(current).toString("hex")).toBe("a20608494e445f77697265")
    }
  })

  test("wire contract and adapter preserve IDs, range, bytes and digest", async () => {
    const transport = rpcDownloadTransport(async (method, value) => {
      const decoded = RpcCall.fromBinary(RpcCall.toBinary(RpcCall.create({ method, input: value })))
      expect(decoded.method).toBe(Method.GET_FILE_PART)
      if (decoded.input.oneofKind !== "getFilePart") throw new Error("wrong call")
      expect(decoded.input.getFilePart.message).toEqual({ chatId: 123n, messageId: 456n })
      return RpcResult.fromBinary(RpcResult.toBinary(RpcResult.create({
        result: { oneofKind: "getFilePart", getFilePart: part(decoded.input.getFilePart) },
      }))).result
    })
    const chunks = await Array.fromAsync(new NativeDownloadClient(transport).download({
      ...input, message: { chatId: 123n, messageId: 456n },
    }))
    expect(Buffer.concat(chunks.map((chunk) => chunk.data))).toEqual(Buffer.from(source))
    expect(chunks.map((chunk) => chunk.offset)).toEqual([
      0n,
      BigInt(INLINE_TRANSFER_PART_SIZE),
      BigInt(INLINE_TRANSFER_PART_SIZE * 2),
      BigInt(INLINE_TRANSFER_PART_SIZE * 3),
    ])
  })

  test("prefetches a bounded window, preserves order, and honors a slow consumer", async () => {
    const gates = [deferred(), deferred(), deferred()]
    const requested: bigint[] = []
    const transport: NativeDownloadRpcTransport = {
      async getPart(request) {
        requested.push(request.offset)
        if (request.offset > 0n) {
          await gates[Number(request.offset / BigInt(INLINE_TRANSFER_PART_SIZE)) - 1]?.promise
        }
        return part(request)
      },
    }
    const stream = new NativeDownloadClient(transport).download(input)
    expect((await stream.next()).value?.offset).toBe(0n)
    const second = stream.next()
    await Promise.resolve()
    expect(requested).toEqual([
      0n,
      BigInt(INLINE_TRANSFER_PART_SIZE),
      BigInt(INLINE_TRANSFER_PART_SIZE * 2),
      BigInt(INLINE_TRANSFER_PART_SIZE * 3),
    ])
    gates[2]!.resolve()
    gates[1]!.resolve()
    await Promise.resolve()
    expect(requested).toHaveLength(4)
    gates[0]!.resolve()
    expect((await second).value?.offset).toBe(BigInt(INLINE_TRANSFER_PART_SIZE))
    await Promise.resolve()
    expect(requested).toHaveLength(4)
    expect((await stream.next()).value?.offset).toBe(BigInt(INLINE_TRANSFER_PART_SIZE * 2))
    expect(requested).toHaveLength(4)
    await stream.return(undefined)
  })

  test("resumes only from the caller's checkpoint and handles exact EOF", async () => {
    const requested: bigint[] = []
    const client = new NativeDownloadClient({ async getPart(request) { requested.push(request.offset); return part(request) } }, 2)
    const chunks = await Array.fromAsync(client.download({ ...input, offset: 13n }))
    expect(Buffer.concat(chunks.map((chunk) => chunk.data))).toEqual(Buffer.from(source.slice(13)))
    expect(requested).toEqual([
      13n,
      13n + BigInt(INLINE_TRANSFER_PART_SIZE),
      13n + BigInt(INLINE_TRANSFER_PART_SIZE * 2),
    ])
    const eof = await Array.fromAsync(client.download({ ...input, offset: BigInt(source.length) }))
    expect(eof).toHaveLength(1)
    expect(eof[0]!.data).toHaveLength(0)
  })

  test("snapshots file identity and provenance for the whole transfer", async () => {
    const location = { chatId: 1n, messageId: 2n }
    const options = { ...input, message: location }
    const requests: GetFilePartInput[] = []
    const client = new NativeDownloadClient({ async getPart(request) { requests.push(request); return part(request) } }, 2)
    const stream = client.download(options)
    await stream.next()
    options.fileUniqueId = "IND_changed"
    location.messageId = 3n
    await Array.fromAsync(stream)
    expect(requests.every((request) => request.fileUniqueId === input.fileUniqueId && request.message?.messageId === 2n)).toBe(true)
  })

  test("cancels a pending request through the transport signal", async () => {
    const started = deferred()
    const abort = new AbortController()
    const client = new NativeDownloadClient({ async getPart(_request, signal) {
      started.resolve()
      return await new Promise((_resolve, reject) => {
        signal!.addEventListener("abort", () => reject(signal!.reason), { once: true })
      })
    } })
    const result = Array.fromAsync(client.download({ ...input, signal: abort.signal }))
    await started.promise
    abort.abort()
    await expect(result).rejects.toMatchObject({ name: "AbortError" })
  })

  test.each(["digest", "offset", "length", "total", "changed-total"])("rejects invalid %s before yielding it", async (failure) => {
    const client = new NativeDownloadClient({ async getPart(request) {
      const value = part(request)
      if (failure === "digest") value.sha256.fill(0)
      if (failure === "offset") value.offset += 1n
      if (failure === "length") value.data = value.data.slice(1)
      if (failure === "total") value.totalSize = 0n
      if (failure === "changed-total" && request.offset > 0n) value.totalSize += 1n
      return value
    } })
    await expect(Array.fromAsync(client.download(input))).rejects.toThrow()
  })

  test("forwards cancellation and cancels prefetched requests on early return", async () => {
    const signals: AbortSignal[] = []
    const transport: NativeDownloadRpcTransport = { async getPart(request, signal) {
      signals.push(signal!)
      return part(request)
    } }
    const stream = new NativeDownloadClient(transport).download(input)
    await stream.next()
    await stream.next()
    await stream.return(undefined)
    expect(signals.length).toBe(4)
    expect(signals.every((signal) => signal.aborted)).toBe(true)

    const abort = new AbortController()
    abort.abort()
    await expect(Array.fromAsync(new NativeDownloadClient(transport).download({ ...input, signal: abort.signal })))
      .rejects.toMatchObject({ name: "AbortError" })
    expect(signals.length).toBe(4)
  })

  test("transport failures preserve already yielded bytes and are not retried as authorization failures", async () => {
    const denied = new Error("denied")
    const client = new NativeDownloadClient({ async getPart(request) {
      if (request.offset > 0n) throw denied
      return part(request)
    } }, 1)
    const stream = client.download(input)
    expect((await stream.next()).value?.data).toEqual(source.slice(0, INLINE_TRANSFER_PART_SIZE))
    await expect(stream.next()).rejects.toBe(denied)
  })

  test("requires production geometry and signed-int32 message locators before transport", async () => {
    const transport: NativeDownloadRpcTransport = { async getPart(request) { return part(request) } }
    expect(() => new NativeDownloadClient(transport, 1, 1)).toThrow("part size")
    expect(() => new NativeDownloadClient(transport, 1, 16 * 1024 * 1024)).toThrow("part size")
    const calls: GetFilePartInput[] = []
    const client = new NativeDownloadClient({ async getPart(request) { calls.push(request); return part(request) } })
    await expect(Array.fromAsync(client.download({
      ...input, message: { chatId: INLINE_TRANSFER_MAX_LOCATOR_ID + 1n, messageId: 1n },
    }))).rejects.toThrow("Invalid file ID")
    expect(calls).toHaveLength(0)
  })
})
