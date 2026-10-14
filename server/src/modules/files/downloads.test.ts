import { createHash } from "node:crypto"
import { describe, expect, spyOn, test } from "bun:test"
import { GetFilePartInput, RpcError_Code } from "@inline-chat/protocol/core"
import { INLINE_TRANSFER_MAX_LOCATOR_ID } from "@inline-chat/protocol/transfers"
import type { DbFile } from "@in/server/db/schema"
import { encrypt } from "@in/server/modules/encryption/encryption"
import type { HandlerContext } from "@in/server/realtime/types"
import { NativeDownloadOperations, type DownloadPartTrace } from "./downloads"
import { readFileBytes, FileByteLengthError } from "./readFileBytes"
import { toRealtimeRpcError } from "@in/server/realtime/rpcErrorBoundary"
import { Log } from "@in/server/utils/log"

const context: HandlerContext = {
  userId: 1, sessionId: 2, connectionId: "test", sendRaw() {}, sendRpcReply() {},
  inlineProtocol: { permanentAuthKeyId: new Uint8Array(8) },
}
const bytes = new Uint8Array([1, 2, 3, 4, 5])
const encrypted = encrypt("test-download")
const file = { fileSize: 5, pathEncrypted: encrypted.encrypted, pathIv: encrypted.iv, pathTag: encrypted.authTag } as DbFile
const request = (offset = 0n, limit = 4) => GetFilePartInput.create({ fileUniqueId: "IND_test", offset, limit })
const carrierContext = (carrier: "V2" | "V3"): HandlerContext => ({
  ...context,
  inlineProtocol: carrier === "V3" ? context.inlineProtocol : undefined,
})

describe("native download ranges", () => {
  test("requires an authenticated account and session before looking up files", async () => {
    let lookups = 0
    const operations = new NativeDownloadOperations(async () => { lookups += 1; return file })
    for (const invalidContext of [
      { ...carrierContext("V2"), userId: 0 },
      { ...carrierContext("V2"), sessionId: 0 },
      { ...context, userId: -1 },
      { ...context, sessionId: 1.5 },
    ]) {
      await expect(operations.getPart(request(), invalidContext)).rejects.toMatchObject({ code: RpcError_Code.UNAUTHENTICATED })
    }
    expect(lookups).toBe(0)
  })

  test.each(["V2", "V3"] as const)("%s reads only the requested range, returns exact tail/EOF and a digest", async (carrier) => {
    const currentContext = carrierContext(carrier)
    const calls: number[][] = []
    const operations = new NativeDownloadOperations(async () => file, async (_path, offset, length) => {
      calls.push([offset, length])
      return bytes.slice(offset, offset + length)
    })
    expect(await operations.getPart(request(), currentContext)).toEqual({
      offset: 0n, totalSize: 5n, data: bytes.slice(0, 4),
      sha256: createHash("sha256").update(bytes.slice(0, 4)).digest(),
    })
    expect((await operations.getPart(request(4n), currentContext)).data).toEqual(new Uint8Array([5]))
    expect((await operations.getPart(request(5n), currentContext)).data.length).toBe(0)
    expect(calls).toEqual([[0, 4], [4, 1]])
    await expect(operations.getPart(request(6n), currentContext)).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
  })

  test.each(["V2", "V3"] as const)("%s rejects malformed ranges before authorization or storage I/O", async (carrier) => {
    let lookups = 0
    const operations = new NativeDownloadOperations(async () => { lookups += 1; return file })
    for (const input of [request(-1n), request(2n ** 63n), request(0n, 0), request(0n, 524289),
      request(0n, 1.5), { ...request(), message: { chatId: 1n, messageId: 0n } },
      { ...request(), message: { chatId: INLINE_TRANSFER_MAX_LOCATOR_ID + 1n, messageId: 1n } }]) {
      await expect(operations.getPart(input, carrierContext(carrier))).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    }
    expect(lookups).toBe(0)
  })

  test.each(["V2", "V3"] as const)("%s does not read missing or unauthorized files", async (carrier) => {
    let reads = 0
    const operations = new NativeDownloadOperations(async () => undefined, async () => { reads += 1; return bytes })
    await expect(operations.getPart(request(), carrierContext(carrier))).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    expect(reads).toBe(0)
  })

  test.each(["V2", "V3"] as const)("%s holds per-session admission until reads settle and recovers after failure", async (carrier) => {
    const currentContext = carrierContext(carrier)
    let release!: () => void
    const gate = new Promise<void>((resolve) => { release = resolve })
    const operations = new NativeDownloadOperations(async () => file, async () => { await gate; throw new Error("storage failed") })
    const pending = Array.from({ length: 8 }, () => operations.getPart(request(), currentContext).catch((error: unknown) => error))
    await expect(operations.getPart(request(), currentContext)).rejects.toMatchObject({ code: RpcError_Code.RATE_LIMIT, codeNumber: 429 })
    release()
    await Promise.all(pending)
    await expect(operations.getPart(request(), currentContext)).rejects.toThrow("storage failed")
  })

  test.each(["V2", "V3"] as const)("%s bounds global reads across different account sessions", async (carrier) => {
    const currentContext = carrierContext(carrier)
    let release!: () => void
    const gate = new Promise<void>((resolve) => { release = resolve })
    const operations = new NativeDownloadOperations(async () => file, async () => { await gate; return bytes.slice(0, 4) })
    const pending = Array.from({ length: 64 }, (_, sessionId) => operations.getPart(request(), { ...currentContext, sessionId: sessionId + 1 }))
    await expect(operations.getPart(request(), { ...currentContext, sessionId: 100 })).rejects.toMatchObject({ code: RpcError_Code.RATE_LIMIT })
    release()
    await Promise.all(pending)
    expect((await operations.getPart(request(), currentContext)).data.length).toBe(4)
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

  test("V2 deadlines cancel stalled storage reads and release every session slot", async () => {
    let reads = 0
    let canceled = 0
    const operations = new NativeDownloadOperations(async () => file, async (_path, _offset, length, signal) => {
      reads += 1
      if (reads > 8) return bytes.slice(0, length)
      return readFileBytes(new ReadableStream<Uint8Array>({ cancel() { canceled += 1 } }), length, signal)
    }, 10)
    const currentContext = carrierContext("V2")
    const pending = Array.from({ length: 8 }, () => operations.getPart(request(), currentContext).catch((error: unknown) => error))
    await expect(operations.getPart(request(), currentContext)).rejects.toMatchObject({ code: RpcError_Code.RATE_LIMIT })
    for (const result of await Promise.all(pending)) {
      expect(toRealtimeRpcError(result)).toMatchObject({
        code: RpcError_Code.INTERNAL_ERROR, codeNumber: 408, message: "File download part timed out",
      })
    }
    expect(canceled).toBe(8)
    const recovered = await Promise.all(Array.from({ length: 8 }, () => operations.getPart(request(), currentContext)))
    expect(recovered.every((part) => part.data.length === 4)).toBe(true)
  })

  test("V3 cancellation reaches the storage stream and releases admission before the local deadline", async () => {
    const controller = new AbortController()
    let started!: () => void
    const entered = new Promise<void>((resolve) => { started = resolve })
    let reads = 0
    let canceled = false
    const operations = new NativeDownloadOperations(async () => file, async (_path, _offset, length, signal) => {
      reads += 1
      if (reads > 1) return bytes.slice(0, length)
      started()
      return readFileBytes(new ReadableStream<Uint8Array>({ cancel() { canceled = true } }), length, signal)
    })
    const pending = operations.getPart(request(), { ...context, signal: controller.signal })
    await entered
    controller.abort(new DOMException("Carrier disconnected", "AbortError"))
    await expect(pending).rejects.toMatchObject({ name: "AbortError" })
    expect(canceled).toBe(true)
    const recovered = await Promise.all(Array.from({ length: 8 }, () => operations.getPart(request(), context)))
    expect(recovered.every((part) => part.data.length === 4)).toBe(true)
  })

  test("an external TimeoutError stays the cancellation reason even if the local deadline also expires", async () => {
    const controller = new AbortController()
    let started!: () => void
    const entered = new Promise<void>((resolve) => { started = resolve })
    const operations = new NativeDownloadOperations(async () => file, async (_path, _offset, length, signal) => {
      started()
      // Model a provider that settles after both cancellation sources fired.
      await new Promise<void>((resolve) => { setTimeout(resolve, 20) })
      signal?.throwIfAborted()
      return bytes.slice(0, length)
    }, 10)
    const pending = operations.getPart(request(), { ...context, signal: controller.signal })
    await entered
    const reason = new DOMException("Carrier application deadline", "TimeoutError")
    controller.abort(reason)
    await expect(pending).rejects.toBe(reason)
  })

  test.each([new Error("storage failed after deadline"), new FileByteLengthError()])(
    "does not classify a provider failure after the local deadline as a timeout (%s)", async (failure) => {
      const operations = new NativeDownloadOperations(async () => file, async () => {
        await new Promise<void>((resolve) => { setTimeout(resolve, 20) })
        throw failure
      }, 10)
      await expect(operations.getPart(request(), context)).rejects.toBe(failure)
    },
  )

  test("caches positive authorization for no more than 60 seconds without sliding on use", async () => {
    let now = 0
    let authorized = true
    let lookups = 0
    const operations = new NativeDownloadOperations(async () => {
      lookups += 1
      return authorized ? file : undefined
    }, async (_path, _offset, length) => bytes.slice(0, length), 25_000, { now: () => now })
    await operations.getPart(request(), context)
    authorized = false
    now = 59_999
    await operations.getPart(request(), context)
    expect(lookups).toBe(1)
    now = 60_000
    await expect(operations.getPart(request(), context)).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    expect(lookups).toBe(2)
  })

  test("isolates cached access by account, session, file and exact message location", async () => {
    let lookups = 0
    const operations = new NativeDownloadOperations(async () => { lookups += 1; return file },
      async (_path, _offset, length) => bytes.slice(0, length))
    const located = { ...request(), message: { chatId: 10n, messageId: 20n } }
    await operations.getPart(located, context)
    await operations.getPart(located, context)
    expect(lookups).toBe(1)
    for (const [input, caller] of [
      [located, { ...context, userId: 3 }],
      [located, { ...context, sessionId: 4 }],
      [{ ...located, fileUniqueId: "IND_other" }, context],
      [{ ...located, message: { chatId: 11n, messageId: 20n } }, context],
      [{ ...located, message: { chatId: 10n, messageId: 21n } }, context],
      [request(), context],
    ] as const) await operations.getPart(input, caller)
    expect(lookups).toBe(7)
  })

  test("never caches negative results or operational lookup failures", async () => {
    let lookups = 0
    const failure = new Error("database unavailable")
    const operations = new NativeDownloadOperations(async () => {
      lookups += 1
      if (lookups === 2) throw failure
      return lookups < 3 ? undefined : file
    }, async (_path, _offset, length) => bytes.slice(0, length))
    await expect(operations.getPart(request(), context)).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    await expect(operations.getPart(request(), context)).rejects.toBe(failure)
    await operations.getPart(request(), context)
    await operations.getPart(request(), context)
    expect(lookups).toBe(3)
  })

  test("does not extend revocation lag with time spent looking up authorization", async () => {
    let now = 0
    let lookups = 0
    const operations = new NativeDownloadOperations(async () => {
      lookups += 1
      now += 60_000
      return file
    }, async (_path, _offset, length) => bytes.slice(0, length), 25_000, { now: () => now })
    await operations.getPart(request(), context)
    await operations.getPart(request(), context)
    expect(lookups).toBe(2)
  })

  test("expires a positive slow lookup within 60 seconds of its start", async () => {
    let now = 0
    let authorized = true
    let lookups = 0
    const operations = new NativeDownloadOperations(async () => {
      lookups += 1
      now += 40_000
      return authorized ? file : undefined
    }, async (_path, _offset, length) => bytes.slice(0, length), 25_000, { now: () => now })
    await operations.getPart(request(), context)
    authorized = false
    now = 59_999
    await operations.getPart(request(), context)
    expect(lookups).toBe(1)
    now = 60_000
    await expect(operations.getPart(request(), context)).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    expect(lookups).toBe(2)
  })

  test("does not cache authorization from a canceled lookup", async () => {
    const controller = new AbortController()
    let lookups = 0
    const operations = new NativeDownloadOperations(async () => {
      if (++lookups === 1) controller.abort()
      return file
    }, async (_path, _offset, length) => bytes.slice(0, length))
    await expect(operations.getPart(request(), { ...context, signal: controller.signal })).rejects.toMatchObject({ name: "AbortError" })
    await operations.getPart(request(), context)
    expect(lookups).toBe(2)
  })

  test("bounds cache entries per session and globally while retaining recent authorizations", async () => {
    let lookups = 0
    const operations = new NativeDownloadOperations(async () => { lookups += 1; return file },
      async (_path, _offset, length) => bytes.slice(0, length), 25_000,
      { maxEntries: 3, maxEntriesPerSession: 2 })
    const first = { ...request(), fileUniqueId: "IND_first" }
    const second = { ...request(), fileUniqueId: "IND_second" }
    const third = { ...request(), fileUniqueId: "IND_third" }
    await operations.getPart(first, context)
    await operations.getPart(second, context)
    await operations.getPart(first, context)
    await operations.getPart(third, context)
    await operations.getPart(first, context)
    expect(lookups).toBe(3)
    await operations.getPart(second, context)
    expect(lookups).toBe(4)
    await operations.getPart(first, { ...context, sessionId: 8 })
    await operations.getPart(first, { ...context, sessionId: 9 })
    await operations.getPart(second, context)
    expect(lookups).toBe(6)
    await operations.getPart(first, context)
    expect(lookups).toBe(7)
  })

  test("concurrent misses for one key do not evict an unrelated recent authorization", async () => {
    let lookups = 0
    let pendingLookups = 0
    let release!: () => void
    let entered!: () => void
    const gate = new Promise<void>((resolve) => { release = resolve })
    const started = new Promise<void>((resolve) => { entered = resolve })
    const operations = new NativeDownloadOperations(async (fileUniqueId) => {
      lookups += 1
      if (fileUniqueId === "IND_parallel") {
        if (++pendingLookups === 2) entered()
        await gate
      }
      return file
    }, async (_path, _offset, length) => bytes.slice(0, length), 25_000,
    { maxEntries: 2, maxEntriesPerSession: 2 })
    await operations.getPart(request(), context)
    const pending = Array.from({ length: 2 }, () => operations.getPart({ ...request(), fileUniqueId: "IND_parallel" }, context))
    try {
      await started
      release()
      await Promise.all(pending)
      await operations.getPart(request(), context)
      expect(lookups).toBe(3)
    } finally {
      release()
      await Promise.allSettled(pending)
    }
  })

  test("enforces the default 64 per-session and 4096 global authorization limits", async () => {
    let lookups = 0
    const operations = new NativeDownloadOperations(async () => { lookups += 1; return file },
      async (_path, _offset, length) => bytes.slice(0, length), 25_000, { now: () => 0 })
    const input = (id: number) => ({ ...request(), fileUniqueId: `IND_file_${id}` })
    for (let id = 0; id < 65; id += 1) await operations.getPart(input(id), context)
    await operations.getPart(input(64), context)
    expect(lookups).toBe(65)
    await operations.getPart(input(0), context)
    expect(lookups).toBe(66)

    let globalLookups = 0
    const global = new NativeDownloadOperations(async () => { globalLookups += 1; return file },
      async (_path, _offset, length) => bytes.slice(0, length), 25_000, { now: () => 0 })
    for (let sessionId = 1; sessionId <= 64; sessionId += 1) {
      for (let id = 0; id < 64; id += 1) await global.getPart(input(id), { ...context, sessionId })
    }
    await global.getPart(input(0), { ...context, sessionId: 65 })
    await global.getPart(input(0), { ...context, sessionId: 65 })
    expect(globalLookups).toBe(4097)
    await global.getPart(input(0), { ...context, sessionId: 1 })
    expect(globalLookups).toBe(4098)
  })

  test.each(["V2", "V3"] as const)("%s traces whitelisted phase timings, bytes and cache hits once per admitted range", async (carrier) => {
    let now = 0
    const traces: DownloadPartTrace[] = []
    const operations = new NativeDownloadOperations(async () => { now += 7; return file },
      async (_path, _offset, length) => { now += 11; return bytes.slice(0, length) }, 25_000,
      { now: () => now, trace: (trace) => { traces.push(trace) } })
    await operations.getPart(request(), carrierContext(carrier))
    await operations.getPart(request(4n), carrierContext(carrier))
    expect(traces).toEqual([
      { authorizationMs: 7, storageMs: 11, bytes: 4, carrier, cacheHit: false, outcome: "ok" },
      { authorizationMs: 0, storageMs: 11, bytes: 1, carrier, cacheHit: true, outcome: "ok" },
    ])
    const serialized = JSON.stringify(traces)
    for (const secret of ["IND_test", "test-download", "permanentAuthKeyId", "sessionId", "connectionId"]) {
      expect(serialized).not.toContain(secret)
    }
  })

  test("trace logging is disabled unless explicitly enabled with 1 and stays on one line", async () => {
    const original = process.env["INLINE_DOWNLOAD_TRACE"]
    const debug = spyOn(Log.prototype, "debug").mockImplementation(() => {})
    try {
      for (const value of [undefined, "", "true", "0", "1"]) {
        if (value === undefined) delete process.env["INLINE_DOWNLOAD_TRACE"]
        else process.env["INLINE_DOWNLOAD_TRACE"] = value
        const operations = new NativeDownloadOperations(async () => file,
          async (_path, _offset, length) => bytes.slice(0, length))
        await operations.getPart(request(), context)
      }
      expect(debug).toHaveBeenCalledTimes(1)
      const line = debug.mock.calls[0]?.[0]
      expect(typeof line).toBe("string")
      expect(String(line)).toStartWith("DOWNLOAD_TRACE ")
      expect(String(line)).not.toContain("\n")
      expect(JSON.parse(String(line).slice("DOWNLOAD_TRACE ".length))).toMatchObject({
        bytes: 4, carrier: "V3", cacheHit: false, outcome: "ok",
      })
    } finally {
      if (original === undefined) delete process.env["INLINE_DOWNLOAD_TRACE"]
      else process.env["INLINE_DOWNLOAD_TRACE"] = original
      debug.mockRestore()
    }
  })

  test("traces failed authorization without raw errors and never lets diagnostics change range results", async () => {
    let now = 0
    const traces: DownloadPartTrace[] = []
    const failure = new Error("sensitive-provider-url-and-token")
    const operations = new NativeDownloadOperations(async () => { now += 5; throw failure },
      async () => bytes, 25_000, { now: () => now, trace: (trace) => { traces.push(trace) } })
    await expect(operations.getPart(request(), context)).rejects.toBe(failure)
    expect(traces).toEqual([
      { authorizationMs: 5, storageMs: 0, bytes: 0, carrier: "V3", cacheHit: false, outcome: "failed" },
    ])
    const healthy = new NativeDownloadOperations(async () => file,
      async (_path, _offset, length) => bytes.slice(0, length), 25_000,
      { trace: () => { throw failure } })
    expect((await healthy.getPart(request(), context)).data.length).toBe(4)
  })

  test.each(["timeout", "canceled"] as const)("emits one safe trace after a storage %s", async (outcome) => {
    const traces: DownloadPartTrace[] = []
    const controller = new AbortController()
    let entered!: () => void
    const started = new Promise<void>((resolve) => { entered = resolve })
    const operations = new NativeDownloadOperations(async () => file, async (_path, _offset, length, signal) => {
      entered()
      return readFileBytes(new ReadableStream<Uint8Array>(), length, signal)
    }, outcome === "timeout" ? 10 : 25_000, { trace: (trace) => { traces.push(trace) } })
    const pending = operations.getPart(request(), { ...carrierContext(outcome === "timeout" ? "V2" : "V3"), signal: controller.signal })
    await started
    if (outcome === "canceled") controller.abort(new DOMException("private carrier details", "AbortError"))
    await expect(pending).rejects.toMatchObject(outcome === "timeout"
      ? { code: RpcError_Code.INTERNAL_ERROR, codeNumber: 408 }
      : { name: "AbortError" })
    expect(traces).toHaveLength(1)
    expect(traces[0]).toMatchObject({ bytes: 0, outcome, cacheHit: false, carrier: outcome === "timeout" ? "V2" : "V3" })
    expect(traces[0]!.authorizationMs).toBeGreaterThanOrEqual(0)
    expect(traces[0]!.storageMs).toBeGreaterThanOrEqual(0)
    expect(JSON.stringify(traces)).not.toContain("private carrier details")
  })

  test.each(["V2", "V3"] as const)("%s serves the first and final bounded ranges of a 500 MB document", async (carrier) => {
    const size = 500_000_000
    const rangeCalls: number[][] = []
    const operations = new NativeDownloadOperations(async () => ({ ...file, fileSize: size }), async (_path, offset, length) => {
      rangeCalls.push([offset, length])
      return new Uint8Array(length).fill(83)
    })
    const first = await operations.getPart(request(0n, 524_288), carrierContext(carrier))
    expect(first.totalSize).toBe(BigInt(size))
    expect(first.data.length).toBe(524_288)
    const lastOffset = Math.floor((size - 1) / 524_288) * 524_288
    const last = await operations.getPart(request(BigInt(lastOffset), 524_288), carrierContext(carrier))
    expect(last.data.length).toBe(size - lastOffset)
    expect(last.sha256).toEqual(createHash("sha256").update(last.data).digest())
    expect(rangeCalls).toEqual([[0, 524_288], [lastOffset, size - lastOffset]])
  })
})
