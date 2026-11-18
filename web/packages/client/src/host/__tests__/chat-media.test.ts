import { Method, type MessageMedia } from "@inline-chat/protocol/core"
import type { ChatMediaResource, MessageRow } from "@inline/core-protocol"
import { chatId as makeChatId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { ModelHost } from "./model-host"

/**
 * `chatMedia` against the real host: the device's messages first (offline
 * too), then the server's pages (`SEARCH_MESSAGES` with a filter), committed
 * to the replica so every listed row is on disk; `ensure older` pages on.
 */

const chat = makeChatId(10)

const running: ModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

const documentMedia = (id: bigint): MessageMedia =>
  ({
    media: {
      oneofKind: "document",
      document: { document: { id, fileName: `file-${id}.pdf`, mimeType: "application/pdf", size: 10, date: 1n } },
    },
  }) as MessageMedia

const photoMedia = (id: bigint): MessageMedia =>
  ({ media: { oneofKind: "photo", photo: { photo: { id, date: 1n, sizes: [] } } } }) as unknown as MessageMedia

/**
 * The device synced messages 1 to 4 (two files, a photo, a link). The server
 * also has files 100 to 154, which this device never saw.
 */
const boot = async (options: { online?: boolean } = {}) => {
  const mh = new ModelHost()
  running.push(mh)
  mh.model.addUser(2n, "Ada")
  mh.model.addChat({ id: 10n, title: "Design", participants: [2n] })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "spec", media: documentMedia(1n) })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "notes", media: documentMedia(2n) })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "shot", media: photoMedia(3n) })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "https://inline.chat", hasLink: true })
  await mh.seedDisk()
  for (let id = 100n; id <= 154n; id++) {
    mh.model.importMessage({
      id,
      chatId: 10n,
      fromId: 2n,
      text: `old file ${id}`,
      date: 1_000n + id,
      reactions: [],
      media: documentMedia(id),
    })
  }
  await mh.start(options)
  // The open chat makes the device's messages resident.
  mh.ui.subscribeTo(2, { kind: "chatWindow", chatId: chat, anchor: "latest" })
  await mh.until(() => mh.ui.list(2).length >= 4, "window")
  return mh
}

const ids = (mh: ModelHost, sub: number) => (mh.ui.rows(sub) as MessageRow[]).map((row) => Number(row.messageId))
const media = (mh: ModelHost, sub: number) => {
  const value = mh.ui.state.resources.get(sub)
  return value?.kind === "chatMedia" ? (value as ChatMediaResource) : undefined
}
const searches = (mh: ModelHost) => mh.model.rpcLog.filter((entry) => entry.method === Method.SEARCH_MESSAGES).length
const range = (from: number, to: number) => Array.from({ length: from - to + 1 }, (_, index) => from - index)

describe("chatMedia", () => {
  it("lists the device's matches at once offline, then the server's pages, newest first", async () => {
    const mh = await boot({ online: false })
    mh.ui.subscribeTo(5, { kind: "chatMedia", chatId: chat, filter: "files" })
    await mh.until(() => media(mh, 5) != null, "first result")
    expect(ids(mh, 5)).toEqual([2, 1])
    expect(media(mh, 5)).toEqual({ kind: "chatMedia", loading: false, hasMore: true, fetched: false })
    expect(searches(mh)).toBe(0)

    mh.ui.post({ kind: "signal", signal: { kind: "online", online: true } })
    await mh.until(() => media(mh, 5)?.fetched === true, "first server page")
    expect(ids(mh, 5)).toEqual([...range(154, 105), 2, 1])
    expect(media(mh, 5)).toMatchObject({ loading: false, hasMore: true })

    mh.ui.post({ kind: "ensure", sub: 5, range: "older" })
    await mh.until(() => media(mh, 5)?.hasMore === false, "last page")
    expect(ids(mh, 5)).toEqual([...range(154, 100), 2, 1])
    expect(searches(mh)).toBe(2)
    // No more pages: another `ensure older` asks nothing.
    mh.ui.post({ kind: "ensure", sub: 5, range: "older" })
    await mh.synced()
    expect(searches(mh)).toBe(2)
  })

  it("commits the server's pages to the replica: every listed row is on disk", async () => {
    const mh = await boot()
    mh.ui.subscribeTo(5, { kind: "chatMedia", chatId: chat, filter: "files" })
    await mh.until(() => media(mh, 5)?.fetched === true, "first server page")
    await mh.synced()
    // The open window already fetched the newest 50 (105 to 154); the next
    // page's five older files reach the disk only through `chatMedia`.
    const before = await mh.disk.count("message")
    mh.ui.post({ kind: "ensure", sub: 5, range: "older" })
    await mh.until(() => media(mh, 5)?.hasMore === false, "last page")
    await mh.synced()
    expect(await mh.disk.count("message")).toBe(before + 5)
    // A later subscription lists them from the device before its own page arrives.
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: false } })
    await mh.until(() => mh.ui.core(1)?.connection === "waitingForNetwork", "offline")
    mh.ui.subscribeTo(6, { kind: "chatMedia", chatId: chat, filter: "files" })
    await mh.until(() => media(mh, 6) != null, "second subscription")
    expect(ids(mh, 6)).toEqual(ids(mh, 5))
  })

  it("lists matches on disk that are not in memory in its first result, then more on `ensure older`", async () => {
    const mh = new ModelHost()
    running.push(mh)
    mh.model.addUser(2n, "Ada")
    mh.model.addChat({ id: 10n, title: "Design", participants: [2n] })
    // 300 messages on disk, every third a file (100 files); no window is
    // open, so none of them is resident.
    for (let index = 1; index <= 300; index += 1) {
      mh.model.postMessage({
        chatId: 10n,
        fromId: 2n,
        text: `m${index}`,
        ...(index % 3 === 0 ? { media: documentMedia(BigInt(index)) } : {}),
      })
    }
    await mh.seedDisk()
    await mh.start({ online: false })
    const firsts: number[] = []
    const stop = mh.ui.observe((patch) => {
      if (patch.lists.some((change) => change.sub === 5) && firsts.length === 0) firsts.push(mh.ui.list(5).length)
    })
    mh.ui.subscribeTo(5, { kind: "chatMedia", chatId: chat, filter: "files" })
    await mh.until(() => media(mh, 5) != null, "first result")
    stop()
    // The first result already holds the newest 50 files from disk: no empty list first.
    expect(firsts).toEqual([50])
    expect(ids(mh, 5)).toEqual(range(300, 1).filter((id) => id % 3 === 0).slice(0, 50))
    expect(media(mh, 5)).toEqual({ kind: "chatMedia", loading: false, hasMore: true, fetched: false })
    expect(searches(mh)).toBe(0)

    mh.ui.post({ kind: "ensure", sub: 5, range: "older" })
    await mh.until(() => mh.ui.list(5).length === 100, "the rest from disk")
    expect(ids(mh, 5)).toEqual(range(300, 1).filter((id) => id % 3 === 0))
    await mh.until(() => media(mh, 5)?.hasMore === true, "settled")
    expect(searches(mh)).toBe(0)
  })

  it("filters: photos and videos, links", async () => {
    const mh = await boot({ online: false })
    mh.ui.subscribeTo(5, { kind: "chatMedia", chatId: chat, filter: "photosVideos" })
    mh.ui.subscribeTo(6, { kind: "chatMedia", chatId: chat, filter: "links" })
    mh.ui.subscribeTo(7, { kind: "chatMedia", chatId: chat, filter: "voice" })
    await mh.until(() => media(mh, 7) != null, "results")
    expect(ids(mh, 5)).toEqual([3])
    expect(ids(mh, 6)).toEqual([4])
    expect(ids(mh, 7)).toEqual([])
  })

  it("rejects a malformed descriptor without asking the server", async () => {
    const mh = await boot()
    mh.ui.subscribeTo(5, { kind: "chatMedia", chatId: chat, filter: "everything" as never })
    await mh.until(() => media(mh, 5) != null, "result")
    expect(mh.ui.list(5)).toEqual([])
    expect(searches(mh)).toBe(0)
  })
})
