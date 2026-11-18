import { describe, expect, it } from "vitest"
import { VirtualClock } from "../../testing/virtual-clock"
import { bytesEqual, sha256 } from "../bytes"
import { MediaCache } from "../cache/media-cache"
import { PART_SIZE } from "../constants"
import { MemoryByteStore } from "../store/byte-store"
import { testBytes, TransferServer } from "../testing/transfer-server"
import { downloadToCache } from "./download"
import { HttpRangeSource, parseContentRange, RpcRangeSource } from "./range-source"

const FILE = "file-abcdef"
const key = { fileUniqueId: FILE, variant: "file" }

const setup = async (size = 5 * PART_SIZE + 77) => {
  const clock = new VirtualClock()
  const server = new TransferServer(clock)
  const store = new MemoryByteStore(clock)
  const cache = new MediaCache({ store, root: "accounts/a1/media/", budgetBytes: 100 * PART_SIZE, clock })
  await cache.open()
  const bytes = testBytes(size)
  server.addFile(FILE, bytes, "video/mp4")
  return { clock, server, store, cache, bytes }
}

const cached = async (cache: MediaCache) => new Uint8Array(await (await cache.read(key))!.arrayBuffer())

const sameBytes = (actual: Uint8Array | undefined, expected: Uint8Array) => actual !== undefined && bytesEqual(actual, expected)

describe("downloads", () => {
  it("downloads over HTTP in ordered ranges into the cache", async () => {
    const { server, cache, bytes } = await setup()
    const progress: number[] = []
    const entry = await downloadToCache(cache, {
      key,
      source: new HttpRangeSource(server.fetch, server.fileUrl(FILE)),
      expectedSize: bytes.length,
      onProgress: (event) => progress.push(event.receivedBytes),
    })
    expect(entry).toMatchObject({ complete: true, size: bytes.length })
    expect(sameBytes(await cached(cache), bytes)).toBe(true)
    expect(progress.at(-1)).toBe(bytes.length)
    expect(server.httpRequests.map((request) => request.range)).toEqual([
      `bytes=0-${PART_SIZE - 1}`,
      ...[1, 2, 3, 4, 5].map((n) => `bytes=${n * PART_SIZE}-${(n + 1) * PART_SIZE - 1}`),
    ])
  })

  it("resumes after an abort from the verified bytes it kept, sending If-Range", async () => {
    const { server, cache, bytes } = await setup(10 * PART_SIZE)
    const controller = new AbortController()
    await expect(downloadToCache(cache, {
      key,
      source: new HttpRangeSource(server.fetch, server.fileUrl(FILE)),
      signal: controller.signal,
      checkpointBytes: 2 * PART_SIZE,
      rangesInFlight: 1,
      onProgress: (event) => {
        if (event.receivedBytes === 5 * PART_SIZE) controller.abort()
      },
    })).rejects.toMatchObject({ code: "canceled" })
    // An orderly stop keeps every verified byte (a crash keeps up to the last checkpoint).
    expect(cache.entry(key)).toMatchObject({ complete: false, size: 5 * PART_SIZE })
    server.httpRequests.length = 0
    await downloadToCache(cache, { key, source: new HttpRangeSource(server.fetch, server.fileUrl(FILE)) })
    expect(sameBytes(await cached(cache), bytes)).toBe(true)
    expect(server.httpRequests[0]).toMatchObject({ range: `bytes=${5 * PART_SIZE}-${6 * PART_SIZE - 1}`, ifRange: TransferServer.entityTag(FILE, bytes.length) })
  })

  it("starts over once when the file changed since the partial was written", async () => {
    const { server, cache } = await setup(4 * PART_SIZE)
    const controller = new AbortController()
    await downloadToCache(cache, {
      key,
      source: new HttpRangeSource(server.fetch, server.fileUrl(FILE)),
      signal: controller.signal,
      rangesInFlight: 1,
      checkpointBytes: PART_SIZE,
      onProgress: () => controller.abort(),
    }).catch(() => {})
    const replaced = testBytes(3 * PART_SIZE + 5, 99)
    server.addFile(FILE, replaced)
    await downloadToCache(cache, { key, source: new HttpRangeSource(server.fetch, server.fileUrl(FILE)) })
    expect(sameBytes(await cached(cache), replaced)).toBe(true)
  })

  it("refreshes a rejected link once and continues", async () => {
    const { server, cache, bytes } = await setup(2 * PART_SIZE)
    const stale = server.fileUrl(FILE)
    server.expireLinks()
    let refreshes = 0
    const source = new HttpRangeSource(server.fetch, stale, async () => {
      refreshes += 1
      return server.fileUrl(FILE)
    })
    await downloadToCache(cache, { key, source })
    expect(refreshes).toBe(1)
    expect(sameBytes(await cached(cache), bytes)).toBe(true)
  })

  it("fails on a link that stays rejected", async () => {
    const { server, cache } = await setup(PART_SIZE)
    const stale = server.fileUrl(FILE)
    server.expireLinks()
    await expect(downloadToCache(cache, { key, source: new HttpRangeSource(server.fetch, stale) }))
      .rejects.toMatchObject({ code: "link_rejected" })
  })

  it("rejects a size that differs from the message, a truncated body and a changing total", async () => {
    const { server, cache, bytes } = await setup(3 * PART_SIZE)
    await expect(downloadToCache(cache, { key, source: new HttpRangeSource(server.fetch, server.fileUrl(FILE)), expectedSize: bytes.length + 1 }))
      .rejects.toMatchObject({ code: "length_mismatch" })
    server.httpFault({ kind: "truncate" })
    await expect(downloadToCache(cache, { key, source: new HttpRangeSource(server.fetch, server.fileUrl(FILE)) }))
      .rejects.toMatchObject({ code: "length_mismatch" })
    server.httpFault({ kind: "ignore-range" })
    await expect(downloadToCache(cache, { key, source: new HttpRangeSource(server.fetch, server.fileUrl(FILE)) }))
      .rejects.toMatchObject({ code: "range_not_supported" })
    expect(cache.has(key)).toBe(false)
    // Only clean ranges count: one more good run completes the file.
    await downloadToCache(cache, { key, source: new HttpRangeSource(server.fetch, server.fileUrl(FILE)) })
    expect(sameBytes(await cached(cache), bytes)).toBe(true)
  })

  it("rejects a range whose total changed mid-download", async () => {
    const { server, cache } = await setup(3 * PART_SIZE)
    let calls = 0
    const source = new HttpRangeSource(async (url, init) => {
      calls += 1
      if (calls === 2) server.httpFault({ kind: "wrong-total", total: 10 * PART_SIZE })
      return await server.fetch(url, init)
    }, server.fileUrl(FILE))
    await expect(downloadToCache(cache, { key, source, rangesInFlight: 1 })).rejects.toMatchObject({ code: "length_mismatch" })
  })

  it("keeps verified bytes when the body fails midway, and a whole-file digest guards the result", async () => {
    const { server, cache, bytes } = await setup(2 * PART_SIZE)
    server.httpFault({ kind: "error-mid-body" })
    await expect(downloadToCache(cache, { key, source: new HttpRangeSource(server.fetch, server.fileUrl(FILE)) }))
      .rejects.toMatchObject({ code: "retryable" })
    await expect(downloadToCache(cache, { key, source: new HttpRangeSource(server.fetch, server.fileUrl(FILE)), sha256: new Uint8Array(32) }))
      .rejects.toMatchObject({ code: "integrity" })
    expect(cache.entry(key)?.size ?? 0).toBe(0)
    await downloadToCache(cache, { key, source: new HttpRangeSource(server.fetch, server.fileUrl(FILE)), sha256: sha256(bytes) })
    expect(sameBytes(await cached(cache), bytes)).toBe(true)
  })

  it("aborts promptly while ranges are in flight on a slow server", async () => {
    const { clock, server, cache } = await setup(4 * PART_SIZE)
    server.httpFault({ kind: "delay", ms: 10_000, times: 10 })
    const controller = new AbortController()
    const done = downloadToCache(cache, { key, source: new HttpRangeSource(server.fetch, server.fileUrl(FILE)), signal: controller.signal })
    await clock.advance(1_000)
    controller.abort()
    await expect(done).rejects.toMatchObject({ code: "canceled" })
    expect(cache.entry(key)?.complete ?? false).toBe(false)
  })

  it("downloads over GET_FILE_PART with per-part digests", async () => {
    const { server, cache, bytes } = await setup(2 * PART_SIZE + 9)
    await downloadToCache(cache, { key, source: new RpcRangeSource(server.call, FILE) })
    expect(sameBytes(await cached(cache), bytes)).toBe(true)
    const tampered = new RpcRangeSource(async (method, input, signal) => {
      const result = await server.call(method, input, signal)
      if (result.oneofKind === "getFilePart") result.getFilePart.data[0] ^= 1
      return result
    }, FILE)
    await expect(downloadToCache(cache, { key: { fileUniqueId: FILE, variant: "d" }, source: tampered }))
      .rejects.toMatchObject({ code: "integrity" })
  })

  it("parses Content-Range like the Mac client", () => {
    expect(parseContentRange("bytes 0-9/100")).toEqual({ start: 0, end: 9, total: 100 })
    expect(parseContentRange("bytes 0-9/*")).toBeUndefined()
    expect(parseContentRange("bytes 9-0/100")).toBeUndefined()
    expect(parseContentRange("bytes 0-100/100")).toBeUndefined()
  })
})
