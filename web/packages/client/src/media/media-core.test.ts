import { Method, UploadKind } from "@inline-chat/protocol/core"
import { describe, expect, it } from "vitest"
import { VirtualClock } from "../testing/virtual-clock"
import { bytesEqual } from "./bytes"
import { PART_SIZE } from "./constants"
import { MediaCore, type MediaEvent } from "./index"
import { MemoryByteStore } from "./store/byte-store"
import { testBytes, TransferServer } from "./testing/transfer-server"

const setup = () => {
  const clock = new VirtualClock()
  const server = new TransferServer(clock)
  const store = new MemoryByteStore(clock)
  const open = (accountKey: string) => MediaCore.open({ accountKey, rpc: server.call, fetch: server.fetch, store, clock, random: () => 0.5 })
  return { clock, server, store, open }
}

describe("media core", () => {
  it("uploads, then downloads the same file into the cache through the scheduler", async () => {
    const { clock, server, open } = setup()
    const core = await open("acct1")
    const events: MediaEvent[] = []
    core.subscribe((event) => events.push(event))
    const bytes = testBytes(2 * PART_SIZE + 100)
    const localPreview = { fileUniqueId: "local-job1", variant: "s" }
    await core.cache.put(localPreview, testBytes(64))
    await core.startUpload({ id: "job1", source: bytes, fileName: "clip.mp4", mimeType: "video/mp4", kind: UploadKind.DOCUMENT }, { pin: [localPreview] })
    expect(core.cache.entry(localPreview)?.pinned).toBe(true)
    await clock.runUntil(() => core.uploads.get("job1")?.state === "complete")
    const complete = await core.uploadCompletion("job1")
    expect(core.cache.entry(localPreview)?.pinned).toBe(false)
    await core.releaseUpload("job1")

    const asset = { key: { fileUniqueId: complete.fileUniqueId, variant: "file" }, kind: "file" as const, sizeBytes: bytes.length, url: server.fileUrl(complete.fileUniqueId) }
    const handle = core.open(asset)
    const entry = await handle.done
    expect(entry.size).toBe(bytes.length)
    expect(core.cache.entry(asset.key)?.pinned).toBe(true)
    handle.release()
    expect(core.cache.entry(asset.key)?.pinned).toBe(false)
    const blob = await core.read(asset.key)
    expect(bytesEqual(new Uint8Array(await blob!.arrayBuffer()), bytes)).toBe(true)
    expect(events.some((event) => event.type === "upload-complete")).toBe(true)
    expect(events.some((event) => event.type === "download-complete")).toBe(true)
  })

  it("downloads over GET_FILE_PART when an asset has no URL", async () => {
    const { server, open } = setup()
    const core = await open("acct1")
    const bytes = testBytes(PART_SIZE + 1)
    server.addFile("file-rpc-1", bytes)
    const entry = await core.open({ key: { fileUniqueId: "file-rpc-1", variant: "file" }, kind: "file", sizeBytes: bytes.length }).done
    expect(entry.size).toBe(bytes.length)
    expect(server.callsOf(Method.GET_FILE_PART)).toHaveLength(2)
  })

  it("resumes an unfinished upload when the account core opens again", async () => {
    const { clock, server, open } = setup()
    server.fault({ method: Method.FINISH_UPLOAD, kind: "hold-after" })
    const first = await open("acct1")
    await first.startUpload({ id: "u1", source: testBytes(PART_SIZE * 2), fileName: "a.bin", mimeType: "application/octet-stream", kind: UploadKind.DOCUMENT })
    await clock.runUntil(() => server.held().length === 1)
    await first.close()
    const second = await open("acct1")
    await clock.runUntil(() => second.uploads.get("u1")?.state === "complete")
    expect(server.finalized).toHaveLength(1)
  })

  it("erases one account's jobs, sources and cache, and nothing of another account", async () => {
    const { clock, server, store, open } = setup()
    const a = await open("acctA")
    const b = await open("acctB")
    server.fault({ method: Method.SAVE_UPLOAD_PART, kind: "hold-before", times: 10 })
    await a.startUpload({ id: "pending", source: testBytes(PART_SIZE * 3), fileName: "a.bin", mimeType: "application/octet-stream", kind: UploadKind.DOCUMENT })
    await a.cache.put({ fileUniqueId: "file-aaaaaa", variant: "file" }, testBytes(100))
    await b.cache.put({ fileUniqueId: "file-bbbbbb", variant: "file" }, testBytes(100))
    await clock.runUntil(() => server.held().length > 0)
    await a.erase()
    expect(await store.list("accounts/acctA/")).toEqual([])
    expect((await store.list("accounts/acctB/")).length).toBe(1)
    const calls = server.calls.length
    await clock.advance(60_000)
    expect(server.calls.length).toBe(calls)
    const reopened = await open("acctA")
    expect(reopened.uploads.list()).toEqual([])
    expect(reopened.cache.usage().entries).toBe(0)
  })

  it("applies new settings: a smaller budget evicts at once", async () => {
    const { open } = setup()
    const core = await open("acct1")
    await core.cache.put({ fileUniqueId: "file-111111", variant: "file" }, testBytes(1_000))
    await core.cache.put({ fileUniqueId: "file-222222", variant: "file" }, testBytes(1_000))
    await core.updateSettings({ ...core.settings, cacheBudgetBytes: 1_500 })
    expect(core.cache.usage().bytes).toBe(1_000)
  })
})
