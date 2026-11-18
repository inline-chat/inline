import { Method, UploadKind } from "@inline-chat/protocol/core"
import { describe, expect, it } from "vitest"
import { VirtualClock } from "../../testing/virtual-clock"
import { bytesEqual, toHex } from "../bytes"
import { PART_SIZE, STALE_UPLOAD_AGE_MS, UPLOAD_WINDOW_INITIAL } from "../constants"
import { MemoryByteStore } from "../store/byte-store"
import { testBytes, TransferServer } from "../testing/transfer-server"
import { ByteStoreJobStore, MemoryMediaJobStore, type MediaJobStore } from "./job"
import { PartWindow } from "./part-window"
import { UploadEngine, type UploadEvent } from "./upload-engine"

const ROOT = "accounts/a1/media/"

const setup = (options: { jobs?: MediaJobStore; store?: MemoryByteStore; clock?: VirtualClock; server?: TransferServer } = {}) => {
  const clock = options.clock ?? new VirtualClock()
  const server = options.server ?? new TransferServer(clock)
  const store = options.store ?? new MemoryByteStore(clock)
  const jobs = options.jobs ?? new MemoryMediaJobStore()
  const events: UploadEvent[] = []
  const makeEngine = () => {
    const engine = new UploadEngine({ rpc: server.call, store, jobs, root: ROOT, clock, random: () => 0.5 })
    engine.subscribe((event) => events.push(event))
    return engine
  }
  return { clock, server, store, jobs, events, makeEngine }
}

const doc = (bytes: Uint8Array, id = "job1") => ({
  id,
  source: bytes,
  fileName: "report.pdf",
  mimeType: "application/pdf",
  kind: UploadKind.DOCUMENT,
})

const complete = (engine: UploadEngine, id = "job1") => () => engine.get(id)?.state === "complete"

const sameBytes = (actual: Uint8Array | undefined, expected: Uint8Array) => actual !== undefined && bytesEqual(actual, expected)

describe("upload engine", () => {
  it("uploads a multi-part file in 512 KB parts within the window and completes once", async () => {
    const { clock, server, store, events, makeEngine } = setup()
    const bytes = testBytes(4 * PART_SIZE + 1234)
    const engine = makeEngine()
    await engine.open()
    let inFlight = 0
    let maxInFlight = 0
    server.latency = (method) => {
      if (method !== Method.SAVE_UPLOAD_PART) return 0
      inFlight += 1
      maxInFlight = Math.max(maxInFlight, inFlight)
      clock.setTimeout(() => (inFlight -= 1), 50)
      return 50
    }
    await engine.start(doc(bytes))
    await clock.runUntil(complete(engine))

    const parts = server.callsOf(Method.SAVE_UPLOAD_PART).map((input) =>
      input.oneofKind === "saveUploadPart" ? [input.saveUploadPart.partIndex, input.saveUploadPart.data.length] : [])
    expect(parts.sort((a, b) => a[0]! - b[0]!)).toEqual([[0, PART_SIZE], [1, PART_SIZE], [2, PART_SIZE], [3, PART_SIZE], [4, 1234]])
    expect(maxInFlight).toBeGreaterThan(1)
    expect(maxInFlight).toBeLessThanOrEqual(UPLOAD_WINDOW_INITIAL + 1)
    expect(server.finalized).toHaveLength(1)
    expect(sameBytes(server.files.get(server.finalized[0]!)?.bytes, bytes)).toBe(true)
    expect(await engine.completion("job1")).toEqual({ fileUniqueId: server.finalized[0], media: { oneofKind: undefined } })
    expect(await store.stat(`${ROOT}uploads/job1.body`)).toBeUndefined()
    const progress = events.filter((event) => event.type === "upload-progress").map((event) => event.type === "upload-progress" ? event.acceptedBytes : 0)
    expect(progress).toEqual([...progress].sort((a, b) => a - b))
    expect(progress.at(-1)).toBe(bytes.length)
    expect(events.filter((event) => event.type === "upload-complete")).toHaveLength(1)
  })

  it("sends a single-part file inside create: one round trip", async () => {
    const { clock, server, makeEngine } = setup()
    const engine = makeEngine()
    await engine.open()
    await engine.start(doc(testBytes(1000)))
    await clock.runUntil(complete(engine))
    expect(server.calls.map((call) => call.method)).toEqual([Method.CREATE_UPLOAD])
    expect(server.finalized).toHaveLength(1)
  })

  it("falls back to a part upload when the server ignores inline data", async () => {
    const { clock, server, makeEngine } = setup()
    server.acceptsInlineData = false
    const engine = makeEngine()
    await engine.open()
    await engine.start(doc(testBytes(1000)))
    await clock.runUntil(complete(engine))
    expect(server.calls.map((call) => call.method)).toEqual([Method.CREATE_UPLOAD, Method.SAVE_UPLOAD_PART, Method.FINISH_UPLOAD])
  })

  describe("resume after a restart at each step", () => {
    const steps: { name: string; method: Method; kind: "hold-before" | "hold-after"; nth?: number }[] = [
      { name: "create sent, not applied", method: Method.CREATE_UPLOAD, kind: "hold-before" },
      { name: "create applied, reply lost", method: Method.CREATE_UPLOAD, kind: "hold-after" },
      { name: "a part sent, not applied", method: Method.SAVE_UPLOAD_PART, kind: "hold-before", nth: 2 },
      { name: "a part applied, reply lost", method: Method.SAVE_UPLOAD_PART, kind: "hold-after", nth: 2 },
      { name: "finish sent, not applied", method: Method.FINISH_UPLOAD, kind: "hold-before" },
      { name: "finish applied, reply lost", method: Method.FINISH_UPLOAD, kind: "hold-after" },
    ]
    for (const step of steps) {
      it(step.name, async () => {
        const { clock, server, store, jobs, events, makeEngine } = setup()
        const bytes = testBytes(3 * PART_SIZE + 10)
        let seen = 0
        server.fault({
          method: step.method,
          kind: step.kind,
          when: () => (seen += 1) === (step.nth ?? 1),
          times: 1,
        })
        const first = makeEngine()
        await first.open()
        await first.start(doc(bytes))
        await clock.runUntil(() => server.held().length === 1)
        // The process dies here: in-flight calls are abandoned, nothing more is written.
        await first.close()
        store.dropUncommitted()

        const callsBefore = server.calls.length
        const second = makeEngine()
        await second.open()
        await clock.runUntil(complete(second))
        const after = server.calls.slice(callsBefore).map((call) => call.method)
        const job = await jobs.get("job1")
        expect(job?.state).toBe("complete")
        // With a known server upload, the first thing a restart does is ask for its state.
        if (step.method !== Method.CREATE_UPLOAD) expect(after[0]).toBe(Method.GET_UPLOAD_STATE)
        else expect(after[0]).toBe(Method.CREATE_UPLOAD)
        expect(server.uploads.size).toBe(1)
        expect(server.finalized).toHaveLength(1)
        expect(sameBytes(server.files.get(server.finalized[0]!)?.bytes, bytes)).toBe(true)
        expect(events.filter((event) => event.type === "upload-complete")).toHaveLength(1)
      })
    }

    it("restart after completion reports the same result and sends nothing", async () => {
      const { clock, server, jobs, makeEngine } = setup()
      const first = makeEngine()
      await first.open()
      await first.start(doc(testBytes(2 * PART_SIZE)))
      await clock.runUntil(complete(first))
      const result = await first.completion("job1")
      await first.close()
      const calls = server.calls.length
      const second = makeEngine()
      await second.open()
      await clock.settle()
      expect(server.calls.length).toBe(calls)
      expect(await second.completion("job1")).toEqual(result)
      await second.release("job1")
      expect(await jobs.get("job1")).toBeUndefined()
    })
  })

  it("completes exactly once after a lost final acknowledgement", async () => {
    const { clock, server, events, makeEngine } = setup()
    server.fault({ method: Method.FINISH_UPLOAD, kind: "lose-reply" })
    const engine = makeEngine()
    await engine.open()
    await engine.start(doc(testBytes(2 * PART_SIZE + 5)))
    await clock.runUntil(complete(engine))
    expect(server.finalized).toHaveLength(1)
    expect(server.callsOf(Method.GET_UPLOAD_STATE)).toHaveLength(1)
    expect(server.callsOf(Method.CREATE_UPLOAD)).toHaveLength(1)
    expect(events.filter((event) => event.type === "upload-complete")).toHaveLength(1)
  })

  it("does not resend a part whose acknowledgement was lost", async () => {
    const { clock, server, makeEngine } = setup()
    server.fault({ method: Method.SAVE_UPLOAD_PART, kind: "lose-reply", when: (input) => input.oneofKind === "saveUploadPart" && input.saveUploadPart.partIndex === 1 })
    const engine = makeEngine()
    await engine.open()
    await engine.start(doc(testBytes(3 * PART_SIZE)))
    await clock.runUntil(complete(engine))
    const sends = server.callsOf(Method.SAVE_UPLOAD_PART).filter((input) => input.oneofKind === "saveUploadPart" && input.saveUploadPart.partIndex === 1)
    expect(sends).toHaveLength(1)
    expect(server.duplicateParts).toBe(0)
    expect(server.finalized).toHaveLength(1)
  })

  it("retries a part that failed mid-request once, after the state shows it missing", async () => {
    const { clock, server, makeEngine } = setup()
    server.fault({ method: Method.SAVE_UPLOAD_PART, kind: "fail-before", when: (input) => input.oneofKind === "saveUploadPart" && input.saveUploadPart.partIndex === 0 })
    const engine = makeEngine()
    await engine.open()
    await engine.start(doc(testBytes(2 * PART_SIZE)))
    await clock.runUntil(complete(engine))
    const sends = server.callsOf(Method.SAVE_UPLOAD_PART).filter((input) => input.oneofKind === "saveUploadPart" && input.saveUploadPart.partIndex === 0)
    expect(sends).toHaveLength(2)
    expect(engine.window.history).toContain(2)
  })

  it("acknowledges a late duplicate of a part as already present", async () => {
    const { clock, server, makeEngine } = setup()
    // The first send of part 0 stalls on the wire past the client's deadline; the client asks
    // the state (missing), sends again, and then the stalled copy arrives.
    server.fault({
      method: Method.SAVE_UPLOAD_PART,
      kind: "hold-before",
      detached: true,
      when: (input) => input.oneofKind === "saveUploadPart" && input.saveUploadPart.partIndex === 0,
    })
    server.fault({ method: Method.FINISH_UPLOAD, kind: "hold-before" })
    const engine = makeEngine()
    await engine.open()
    await engine.start(doc(testBytes(2 * PART_SIZE)))
    await clock.runUntil(() => server.callsOf(Method.SAVE_UPLOAD_PART).length === 3, { stepMs: 1_000, maxMs: 120_000 })
    await clock.runUntil(() => server.held().length === 2)
    const late = server.held().find((call) => call.method === Method.SAVE_UPLOAD_PART)!
    late.release()
    expect(server.duplicateParts).toBe(1)
    server.held()[0]!.release()
    await clock.runUntil(complete(engine))
    expect(server.finalized).toHaveLength(1)
    expect(sameBytes(server.files.get(server.finalized[0]!)?.bytes, testBytes(2 * PART_SIZE))).toBe(true)
  })

  it("re-sends parts the finish reports missing", async () => {
    const { clock, server, makeEngine } = setup()
    server.fault({ method: Method.FINISH_UPLOAD, kind: "hold-before" })
    const engine = makeEngine()
    await engine.open()
    await engine.start(doc(testBytes(3 * PART_SIZE)))
    await clock.runUntil(() => server.held().length === 1)
    const row = [...server.uploads.values()][0]!
    row.parts.delete(1)
    server.held()[0]!.release()
    await clock.runUntil(complete(engine))
    const sends = server.callsOf(Method.SAVE_UPLOAD_PART).filter((input) => input.oneofKind === "saveUploadPart" && input.saveUploadPart.partIndex === 1)
    expect(sends).toHaveLength(2)
    expect(server.finalized).toHaveLength(1)
  })

  it("polls processing on the clock with the server's delay", async () => {
    const { clock, server, makeEngine } = setup()
    server.processingRounds = 3
    const engine = makeEngine()
    await engine.open()
    await engine.start(doc(testBytes(2 * PART_SIZE)))
    await clock.runUntil(() => server.callsOf(Method.FINISH_UPLOAD).length === 1)
    const startedAt = clock.now()
    await clock.runUntil(complete(engine), { stepMs: 10 })
    expect(server.callsOf(Method.FINISH_UPLOAD)).toHaveLength(4)
    expect(clock.now() - startedAt).toBeGreaterThanOrEqual(3_000)
  })

  it("cancels: the server upload, the source and the row", async () => {
    const { clock, server, store, jobs, events, makeEngine } = setup()
    server.fault({ method: Method.SAVE_UPLOAD_PART, kind: "hold-before" })
    const engine = makeEngine()
    await engine.open()
    await engine.start(doc(testBytes(3 * PART_SIZE)))
    const completion = engine.completion("job1")
    await clock.runUntil(() => server.held().length === 1)
    await engine.cancel("job1")
    await expect(completion).rejects.toMatchObject({ code: "canceled" })
    expect([...server.uploads.values()][0]?.status).toBe("canceled")
    expect(await store.stat(`${ROOT}uploads/job1.body`)).toBeUndefined()
    expect(await jobs.get("job1")).toBeUndefined()
    expect(events.some((event) => event.type === "upload-state" && event.state === "canceled")).toBe(true)
    await clock.settle()
    expect(server.finalized).toHaveLength(0)
  })

  it("keeps a cancellation the server did not hear and retries it after a restart", async () => {
    const { clock, server, jobs, makeEngine } = setup()
    server.fault({ method: Method.SAVE_UPLOAD_PART, kind: "hold-before" })
    server.fault({ method: Method.CANCEL_UPLOAD, kind: "fail-before" })
    const first = makeEngine()
    await first.open()
    await first.start(doc(testBytes(3 * PART_SIZE)))
    await clock.runUntil(() => server.held().length === 1)
    await first.cancel("job1")
    expect((await jobs.get("job1"))?.cancelPending).toBe(true)
    await first.close()
    const second = makeEngine()
    await second.open()
    await clock.settle()
    expect([...server.uploads.values()][0]?.status).toBe("canceled")
    expect(await jobs.get("job1")).toBeUndefined()
  })

  it("starts a new server upload when the old one expired, and completes once", async () => {
    const { clock, server, makeEngine } = setup()
    server.fault({ method: Method.SAVE_UPLOAD_PART, kind: "hold-before", when: (input) => input.oneofKind === "saveUploadPart" && input.saveUploadPart.partIndex === 2 })
    const engine = makeEngine()
    await engine.open()
    await engine.start(doc(testBytes(3 * PART_SIZE)))
    await clock.runUntil(() => server.held().length === 1)
    const firstUpload = engine.get("job1")!.uploadId!
    server.expire(firstUpload)
    server.held()[0]!.drop()
    await clock.runUntil(complete(engine))
    const job = engine.get("job1")!
    expect(job.identityGeneration).toBe(1)
    expect(server.uploads.size).toBe(2)
    expect(server.finalized).toHaveLength(1)
    const rows = [...server.uploads.values()]
    expect(rows.find((row) => toHex(row.uploadId) === toHex(firstUpload))?.status).toBe("uploading")
    expect(rows.find((row) => toHex(row.uploadId) !== toHex(firstUpload))?.status).toBe("complete")
  })

  it("asks for the state first on restart and re-creates an upload the server expired meanwhile", async () => {
    const { clock, server, makeEngine } = setup()
    server.fault({ method: Method.SAVE_UPLOAD_PART, kind: "hold-before" })
    const first = makeEngine()
    await first.open()
    await first.start(doc(testBytes(3 * PART_SIZE)))
    await clock.runUntil(() => server.held().length === 1)
    await first.close()
    await clock.advance(25 * 60 * 60 * 1_000)
    const before = server.calls.length
    const second = makeEngine()
    await second.open()
    await clock.runUntil(complete(second))
    expect(server.calls[before]?.method).toBe(Method.GET_UPLOAD_STATE)
    expect(server.calls[before + 1]?.method).toBe(Method.CREATE_UPLOAD)
    expect(second.get("job1")!.identityGeneration).toBe(1)
    expect(server.finalized).toHaveLength(1)
  })

  it("replays create under the same identity when the session cannot see the upload", async () => {
    const { clock, server, makeEngine } = setup()
    server.fault({ method: Method.SAVE_UPLOAD_PART, kind: "hold-before" })
    const first = makeEngine()
    await first.open()
    await first.start(doc(testBytes(2 * PART_SIZE)))
    await clock.runUntil(() => server.held().length === 1)
    await first.close()
    server.session = "session-2"
    const second = makeEngine()
    await second.open()
    await clock.runUntil(complete(second))
    expect(server.finalized).toHaveLength(1)
    expect(second.get("job1")!.identityGeneration).toBe(0)
  })

  it("expires a job older than the server keeps uploads, and drops its source", async () => {
    const { clock, store, jobs, makeEngine } = setup()
    const first = makeEngine()
    await first.open()
    first.setOnline(false)
    await first.start(doc(testBytes(PART_SIZE * 2)))
    await first.close()
    await clock.advance(STALE_UPLOAD_AGE_MS + 1)
    const second = makeEngine()
    await second.open()
    expect((await jobs.get("job1"))?.state).toBe("failed")
    expect((await jobs.get("job1"))?.failure?.code).toBe("expired")
    expect(await store.stat(`${ROOT}uploads/job1.body`)).toBeUndefined()
  })

  it("backs off on transient failures and fails after its attempt cap", async () => {
    const { clock, server, makeEngine } = setup()
    server.fault({ method: Method.CREATE_UPLOAD, kind: "fail-before", times: 100 })
    const engine = makeEngine()
    await engine.open()
    await engine.start(doc(testBytes(PART_SIZE * 2)))
    await clock.runUntil(() => engine.get("job1")?.state === "failed", { maxMs: 10 * 60_000, stepMs: 1_000 })
    // Five attempts, two creates each (the replay).
    expect(server.callsOf(Method.CREATE_UPLOAD)).toHaveLength(10)
    expect(engine.get("job1")?.failure?.retryable).toBe(true)
    await engine.retry("job1")
    await clock.runUntil(() => engine.get("job1")?.state === "failed", { maxMs: 10 * 60_000, stepMs: 1_000 })
    expect(server.callsOf(Method.CREATE_UPLOAD)).toHaveLength(20)
  })

  it("pauses offline and resumes online without spending attempts", async () => {
    const { clock, server, makeEngine } = setup()
    server.fault({ method: Method.SAVE_UPLOAD_PART, kind: "hold-before" })
    const engine = makeEngine()
    await engine.open()
    await engine.start(doc(testBytes(PART_SIZE * 3)))
    await clock.runUntil(() => server.held().length === 1)
    engine.setOnline(false)
    await clock.settle()
    expect(server.held()).toHaveLength(0)
    expect(engine.get("job1")?.attempts).toBe(0)
    engine.setOnline(true)
    await clock.runUntil(complete(engine))
    expect(server.finalized).toHaveLength(1)
  })

  it("fails a rejected upload without retrying it", async () => {
    const { clock, server, makeEngine } = setup()
    server.finalizationFailure = { code: 2, retryable: false }
    const engine = makeEngine()
    await engine.open()
    await engine.start(doc(testBytes(PART_SIZE * 2)))
    const completion = engine.completion("job1")
    await clock.runUntil(() => engine.get("job1")?.state === "failed")
    expect(engine.get("job1")?.failure?.code).toBe("rejected")
    await expect(completion).rejects.toMatchObject({ code: "rejected" })
    expect(server.callsOf(Method.FINISH_UPLOAD)).toHaveLength(1)
  })

  it("rejects an oversized or empty source before writing anything", async () => {
    const { store, makeEngine } = setup()
    const engine = makeEngine()
    await engine.open()
    await expect(engine.start({ ...doc(new Uint8Array(0)) })).rejects.toMatchObject({ code: "invalid_source" })
    expect(store.totalBytes).toBe(0)
  })

  it("collects source blobs that never got a job row", async () => {
    const { clock, store, makeEngine } = setup()
    await store.write(`${ROOT}uploads/orphan.body`, testBytes(10))
    const engine = makeEngine()
    await engine.open()
    engine.setOnline(false)
    await engine.start(doc(testBytes(10), "kept"))
    expect(await engine.collectOrphans()).toBe(0)
    await clock.advance(2 * 60 * 60 * 1_000)
    expect(await engine.collectOrphans()).toBe(1)
    expect(await store.stat(`${ROOT}uploads/orphan.body`)).toBeUndefined()
    expect(await store.stat(`${ROOT}uploads/kept.body`)).toBeDefined()
  })

  it("survives a restart with the job store kept in the byte store", async () => {
    const clock = new VirtualClock()
    const store = new MemoryByteStore(clock)
    const jobs = new ByteStoreJobStore(store, `${ROOT}jobs/`)
    const { server, makeEngine } = setup({ clock, store, jobs })
    server.fault({ method: Method.FINISH_UPLOAD, kind: "hold-after" })
    const first = makeEngine()
    await first.open()
    await first.start(doc(testBytes(PART_SIZE + 3)))
    await clock.runUntil(() => server.held().length === 1)
    await first.close()
    const second = makeEngine()
    await second.open()
    await clock.runUntil(complete(second))
    const stored = await jobs.get("job1")
    expect(stored?.complete?.fileUniqueId).toBe(server.finalized[0])
    expect(stored?.clientUploadId).toBeInstanceOf(Uint8Array)
    expect(server.finalized).toHaveLength(1)
  })
})

describe("part window", () => {
  it("grows under 1 s, halves over 2 s or after a failure, within 2...8", () => {
    const window = new PartWindow()
    for (let index = 0; index < 6; index += 1) {
      expect(window.tryAcquire()).toBe(true)
      window.release({ latencyMs: 300 })
    }
    expect(window.size).toBe(8)
    window.tryAcquire()
    window.release({ latencyMs: 1_500 })
    expect(window.size).toBe(8)
    window.tryAcquire()
    window.release({ latencyMs: 2_500 })
    expect(window.size).toBe(4)
    window.tryAcquire()
    window.release({ failed: true })
    window.tryAcquire()
    window.release({ failed: true })
    expect(window.size).toBe(2)
  })

  it("adapts to part latency on the virtual clock: up when fast, down when slow", async () => {
    const { clock, server, makeEngine } = setup()
    const engine = makeEngine()
    await engine.open()
    server.latency = (method) => (method === Method.SAVE_UPLOAD_PART ? 200 : 0)
    await engine.start(doc(testBytes(12 * PART_SIZE), "fast"))
    await clock.runUntil(complete(engine, "fast"))
    expect(engine.window.size).toBe(8)

    server.latency = (method) => (method === Method.SAVE_UPLOAD_PART ? 3_000 : 0)
    await engine.start(doc(testBytes(6 * PART_SIZE, 7), "slow"))
    await clock.runUntil(complete(engine, "slow"), { stepMs: 500, maxMs: 120_000 })
    expect(engine.window.size).toBe(2)
    expect(engine.window.history).toEqual(expect.arrayContaining([4, 5, 6, 7, 8, 2]))
  })

  it("serves waiters in arrival order", async () => {
    const window = new PartWindow(2, 2, 2)
    window.tryAcquire()
    window.tryAcquire()
    const order: string[] = []
    const a = window.acquire().then(() => order.push("a"))
    const b = window.acquire().then(() => order.push("b"))
    window.release()
    window.release()
    await Promise.all([a, b])
    expect(order).toEqual(["a", "b"])
  })
})
