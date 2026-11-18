import { describe, expect, it } from "vitest"
import { VirtualClock } from "../testing/virtual-clock"
import { MediaCache, type CacheKey } from "./cache/media-cache"
import { PART_SIZE } from "./constants"
import { downloadToCache } from "./download/download"
import { HttpRangeSource } from "./download/range-source"
import { MediaScheduler, type DownloadEvent, type MediaAsset } from "./scheduler"
import { MemoryByteStore } from "./store/byte-store"
import { testBytes, TransferServer } from "./testing/transfer-server"

type Gate = { id: string; open: () => void }

/**
 * The real scheduler over the real downloader and the scripted server. Each
 * HTTP request waits at a gate the test opens, so the test decides when a
 * download makes progress.
 */
const setup = async (options: { maxConcurrent?: number; maxPrefetch?: number } = {}) => {
  const clock = new VirtualClock()
  const server = new TransferServer(clock)
  const store = new MemoryByteStore(clock)
  const cache = new MediaCache({ store, root: "accounts/a1/media/", budgetBytes: 1_000 * PART_SIZE, clock })
  await cache.open()
  const gates: Gate[] = []
  let gated = true
  const fetch = (url: string, init?: RequestInit) => {
    if (!gated) return server.fetch(url, init)
    const id = new URL(url).searchParams.get("id") ?? ""
    return new Promise<Response>((resolve, reject) => {
      const gate: Gate = { id, open: () => resolve(server.fetch(url, init)) }
      init?.signal?.addEventListener("abort", () => {
        gates.splice(gates.indexOf(gate), 1)
        reject(new DOMException("aborted", "AbortError"))
      }, { once: true })
      gates.push(gate)
    })
  }
  const scheduler = new MediaScheduler({
    cache,
    clock,
    maxConcurrent: options.maxConcurrent ?? 1,
    maxPrefetch: options.maxPrefetch,
    run: (asset, signal, onProgress) => downloadToCache(cache, {
      key: asset.key,
      source: new HttpRangeSource(fetch, asset.url!),
      expectedSize: asset.sizeBytes,
      signal,
      onProgress,
    }),
  })
  const events: DownloadEvent[] = []
  scheduler.subscribe((event) => events.push(event))
  const asset = (name: string, size = 1_000, kind: MediaAsset["kind"] = "media"): MediaAsset => {
    const id = `file-${name}`
    if (!server.files.has(id)) server.addFile(id, testBytes(size, name.length + size))
    return { key: { fileUniqueId: id, variant: "file" }, kind, sizeBytes: size, url: server.fileUrl(id) }
  }
  const openGate = async (id?: string) => {
    await clock.settle()
    const gate = id ? gates.find((candidate) => candidate.id === id) : gates[0]
    if (!gate) throw new Error(`No request waiting${id ? ` for ${id}` : ""}`)
    gates.splice(gates.indexOf(gate), 1)
    gate.open()
    await clock.settle()
  }
  const waiting = async () => {
    await clock.settle()
    return gates.map((gate) => gate.id)
  }
  return { clock, server, cache, scheduler, events, asset, openGate, waiting, ungate: () => (gated = false) }
}

const short = (key: CacheKey) => key.fileUniqueId.replace("file-", "")

describe("media scheduler", () => {
  it("starts opened, then visible, then nearby, then prefetch", async () => {
    const { scheduler, asset, openGate, waiting } = await setup()
    scheduler.open(asset("blocker"))
    expect(await waiting()).toEqual(["file-blocker"])
    scheduler.setPrefetch([asset("p")])
    scheduler.setNearby([asset("n")])
    scheduler.setVisible([asset("v")])
    scheduler.open(asset("o"))
    const order: string[] = []
    for (let step = 0; step < 5; step += 1) {
      const [next] = await waiting()
      order.push(next!.replace("file-", ""))
      await openGate(next)
    }
    expect(order).toEqual(["blocker", "o", "v", "n", "p"])
  })

  it("raises a queued request when it becomes visible", async () => {
    const { scheduler, asset, openGate, waiting } = await setup()
    scheduler.open(asset("blocker"))
    scheduler.setPrefetch([asset("a"), asset("b")])
    expect(scheduler.priorityOf(asset("b").key)).toBe("prefetch")
    scheduler.setVisible([asset("b")])
    expect(scheduler.priorityOf(asset("b").key)).toBe("visible")
    await openGate("file-blocker")
    expect(await waiting()).toEqual(["file-b"])
  })

  it("downloads an asset once however many ask for it", async () => {
    const { server, scheduler, asset, ungate } = await setup()
    ungate()
    const first = scheduler.open(asset("same"))
    const second = scheduler.open(asset("same"))
    scheduler.setVisible([asset("same")])
    const [a, b] = await Promise.all([first.done, second.done])
    expect(a).toEqual(b)
    expect(server.httpRequests.filter((request) => request.url.includes("file-same"))).toHaveLength(1)
    // Cached now: a new request resolves without the network.
    const third = scheduler.open(asset("same"))
    await third.done
    expect(server.httpRequests).toHaveLength(1)
  })

  it("cancels a download nobody wants any more and keeps it while someone does", async () => {
    const { scheduler, events, asset, waiting } = await setup()
    const handle = scheduler.open(asset("x"))
    scheduler.setVisible([asset("x")])
    expect(await waiting()).toEqual(["file-x"])
    handle.release()
    expect(await waiting()).toEqual(["file-x"])
    scheduler.setVisible([])
    expect(await waiting()).toEqual([])
    expect(events.some((event) => event.type === "download-canceled" && event.id.startsWith("file-x"))).toBe(true)
    expect(scheduler.status(asset("x").key)).toBeUndefined()
  })

  it("rejects a released handle's promise only when the download is dropped", async () => {
    const { scheduler, asset, waiting } = await setup()
    const handle = scheduler.open(asset("y"))
    expect(await waiting()).toEqual(["file-y"])
    handle.release()
    await expect(handle.done).rejects.toMatchObject({ code: "canceled" })
  })

  it("applies auto-download limits by kind and size; opening bypasses them", async () => {
    const { scheduler, asset, waiting } = await setup({ maxConcurrent: 4 })
    const big = { ...asset("big"), sizeBytes: 26 * 1024 * 1024 }
    const unknown = { ...asset("unknown"), sizeBytes: undefined }
    const doc = asset("doc", 11 * 1024 * 1024, "file")
    const voice = asset("voice", 5 * 1024 * 1024, "voice")
    scheduler.setVisible([big, unknown, doc, voice])
    expect(await waiting()).toEqual(["file-voice"])
    expect(scheduler.allowsAuto(big)).toBe(false)
    scheduler.setAutoDownload({ mediaMaxMB: 30, fileMaxMB: 0, voiceMaxMB: 10 })
    scheduler.setVisible([big, doc, voice])
    expect((await waiting()).sort()).toEqual(["file-big", "file-voice"])
    scheduler.open(doc)
    expect((await waiting()).sort()).toEqual(["file-big", "file-doc", "file-voice"])
  })

  it("limits concurrency and prefetches one at a time", async () => {
    const { scheduler, asset, waiting } = await setup({ maxConcurrent: 2, maxPrefetch: 1 })
    scheduler.setPrefetch([asset("p1"), asset("p2"), asset("p3")])
    expect(await waiting()).toEqual(["file-p1"])
    scheduler.setVisible([asset("v1"), asset("v2")])
    expect((await waiting()).sort()).toEqual(["file-p1", "file-v1"])
  })

  it("pauses offline without spending attempts, and resumes from the partial", async () => {
    const { server, scheduler, asset, openGate, waiting, ungate } = await setup()
    const big = asset("big", 3 * PART_SIZE)
    const handle = scheduler.open(big)
    await openGate("file-big")
    // The first range told the size; the other two are in flight.
    expect(await waiting()).toEqual(["file-big", "file-big"])
    scheduler.setOnline(false)
    expect(await waiting()).toEqual([])
    expect(scheduler.status(big.key)).toBe("queued")
    ungate()
    scheduler.setOnline(true)
    const entry = await handle.done
    expect(entry.size).toBe(3 * PART_SIZE)
    const ranges = server.httpRequests.map((request) => request.range)
    expect(ranges.filter((range) => range === `bytes=0-${PART_SIZE - 1}`)).toHaveLength(1)
  })

  it("retries a transient failure with backoff, and gives up on a missing file", async () => {
    const { clock, server, scheduler, events, asset, ungate } = await setup()
    ungate()
    server.httpFault({ kind: "status", status: 503 })
    const flaky = scheduler.open(asset("flaky"))
    await clock.runUntil(() => scheduler.status(asset("flaky").key) === "complete", { stepMs: 500 })
    await flaky.done
    const gone = asset("gone")
    server.files.delete(gone.key.fileUniqueId)
    const missing = scheduler.open(gone)
    await expect(missing.done).rejects.toMatchObject({ code: "rejected" })
    expect(events.some((event) => event.type === "download-failed" && event.id.startsWith("file-gone"))).toBe(true)
    // Automatic requests leave a failed file alone; only the user can try again.
    scheduler.setVisible([gone])
    expect(scheduler.status(gone.key)).toBe("failed")
    expect(short(gone.key)).toBe("gone")
  })
})
