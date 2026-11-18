import type { ChatRow, MessageRow, PhotoInfo } from "@inline/core-protocol"
import { rowKeyOf, sentMessageRowId } from "@inline/core-protocol"
import { chatId as toChatId, messageId as toMessageId, spaceId as toSpaceId, userId as toUserId, type PhotoID } from "@inline/ids"
import { effect, signal } from "@inline/reactive"
import { afterEach, describe, expect, it } from "vitest"
import { createChatInfoModel, type ChatInfoModel } from "./chat-info-model"
import { createChatMediaModel, type ChatMediaModel } from "./chat-media-model"
import { columnsFor, createMediaGrid } from "./media-grid"
import { testHarness, type TestHarness } from "./testing"

const uid = (n: number) => toUserId(String(n))
const me = uid(1)
const space = toSpaceId("7")
const thread: ChatRow = { kind: "chat", id: toChatId("10"), title: "Launch plan", spaceId: space }

const photo = (id: number): PhotoInfo => ({
  id: String(id) as PhotoID,
  fileUniqueId: `P${id}`,
  sizes: [{ type: "f", width: 800, height: 600, fileUniqueId: `P${id}f` }],
})

const message = (id: number, extra: Partial<MessageRow> = {}): MessageRow => ({
  kind: "message",
  id: `${thread.id}:${id}` as MessageRow["id"],
  chatId: thread.id,
  messageId: toMessageId(String(id)),
  fromId: uid(2),
  out: false,
  date: 1_763_000_000 + id,
  text: "",
  state: "sent",
  ...extra,
})

let h: TestHarness | undefined
let models: { dispose(): void }[] = []
afterEach(() => {
  for (const model of models) model.dispose()
  models = []
  h?.dispose()
  h = undefined
})

const harness = () => {
  h = testHarness({ me })
  h.core.setUsers([
    { kind: "user", id: me, firstName: "Mo" },
    { kind: "user", id: uid(2), firstName: "Ada" },
  ])
  h.core.setChat(thread)
  return h
}

const mediaModel = (tab: "media" | "files" | "voice" | "links") => {
  const model = createChatMediaModel({ client: h!.client, chatId: thread.id, tab, formatDate: () => "Nov 13, 2025" })
  models.push(model)
  // Observe like the view does.
  const stop = effect(() => {
    model.ids.get()
    model.footer.get()
  })
  models.push({ dispose: stop })
  return model
}

const items = (model: ChatMediaModel) => model.ids.peek().map((key) => model.item(key).peek())

describe("shared media tabs", () => {
  it("subscribes chatMedia with the tab's filter and lists what is on the device in its first answer", async () => {
    const t = harness()
    t.core.setChatMedia(thread.id, "photosVideos", [message(3, { media: { kind: "photo", photo: photo(3) } }), message(2, { media: { kind: "video", video: { id: "5" as never, width: 1280, height: 720, duration: 75, size: 10, thumbnail: photo(9) } } })], {
      loading: true,
      hasMore: true,
      fetched: false,
    })
    const model = mediaModel("media")
    expect(model.footer.peek()).toEqual({ kind: "pending" })
    await t.flush()
    expect(t.core.subsOf("chatMedia")).toEqual([{ kind: "chatMedia", chatId: thread.id, filter: "photosVideos" }])
    // Local rows show while the server page loads: no empty state, a loading footer.
    expect(items(model).map((item) => item?.kind === "media" && item.label)).toEqual(["Photo, Nov 13, 2025", "Video, 1:15, Nov 13, 2025"])
    expect(model.footer.peek()).toEqual({ kind: "loading", empty: false })
    const video = items(model)[1]
    expect(video?.kind === "media" && video.photo?.id).toBe("9")
    t.core.setChatMedia(thread.id, "photosVideos", t.core.chatMedia(thread.id, "photosVideos")!.rows, { loading: false, hasMore: true, fetched: true })
    await t.flush()
    expect(model.footer.peek()).toEqual({ kind: "more" })
  })

  it("asks for the next page with ensure older, once, only when there may be more", async () => {
    const t = harness()
    t.core.setChatMedia(thread.id, "files", [], { hasMore: true, fetched: true })
    const model = mediaModel("files")
    await t.flush()
    expect(model.loadMore()).toBe(true)
    expect(t.core.ensures).toEqual([{ query: { kind: "chatMedia", chatId: thread.id, filter: "files" }, range: "older" }])
    t.core.setChatMedia(thread.id, "files", [], { hasMore: true, fetched: true, loading: true })
    await t.flush()
    expect(model.loadMore()).toBe(false)
    t.core.setChatMedia(thread.id, "files", [], { hasMore: false, fetched: true })
    await t.flush()
    expect(model.loadMore()).toBe(false)
    expect(t.core.ensures).toHaveLength(1)
    expect(model.footer.peek()).toEqual({ kind: "empty", text: "No files found in this chat." })
  })

  it("files, voice and links rows are prepared: names without bidi controls, sizes, durations, safe links", async () => {
    const t = harness()
    t.core.setChatMedia(thread.id, "files", [
      message(4, { media: { kind: "document", document: { id: "1" as never, fileName: "invoice‮fdp.exe", mimeType: "application/pdf", size: 2_400_000 } } }),
    ])
    t.core.setChatMedia(thread.id, "voice", [message(5, { media: { kind: "voice", voice: { id: "2" as never, duration: 65, size: 10, mimeType: "audio/ogg" } as never } })])
    t.core.setChatMedia(thread.id, "links", [
      message(6, { text: "see https://example.com/a and javascript:alert(1)", entities: [{ type: "url", offset: 4, length: 21 }] }),
      message(7, { text: "evil", entities: [{ type: "textUrl", offset: 0, length: 4, url: "javascript:alert(1)" }] }),
    ])
    const files = mediaModel("files")
    const voice = mediaModel("voice")
    const links = mediaModel("links")
    await t.flush()
    expect(items(files)[0]).toMatchObject({ kind: "file", fileName: "invoicefdp.exe", sizeText: "2.4 MB", typeText: "EXE" })
    expect(items(voice)[0]).toMatchObject({ kind: "voice", durationText: "1:05", senderName: "Ada" })
    expect(items(links)).toMatchObject([
      { kind: "link", url: "https://example.com/a", title: "example.com" },
      { kind: "link", url: undefined, title: "evil" },
    ])
  })

  it("failed: says so with Retry, which subscribes again and keeps the rows on screen until the new answer", async () => {
    const t = harness()
    t.core.setChatMedia(thread.id, "links", [message(8, { text: "https://a.example", entities: [{ type: "url", offset: 0, length: 17 }] })], {
      failed: true,
      hasMore: true,
      fetched: false,
    })
    const model = mediaModel("links")
    await t.flush()
    expect(model.footer.peek()).toEqual({ kind: "failed" })
    t.core.autoAnswer = false
    model.retry()
    expect(model.ids.peek()).toHaveLength(1)
    await t.flush()
    expect(model.ids.peek()).toHaveLength(1)
    t.core.setChatMedia(thread.id, "links", t.core.chatMedia(thread.id, "links")!.rows, { hasMore: false, fetched: true })
    t.core.answer()
    await t.flush()
    expect(model.footer.peek()).toEqual({ kind: "end" })
    expect(t.core.subsOf("chatMedia")).toHaveLength(1)
  })

  it("one row changing re-runs one item, and the item keeps its identity while unchanged", async () => {
    const t = harness()
    const rows = Array.from({ length: 30 }, (_, i) => message(100 + i, { media: { kind: "photo", photo: photo(100 + i) } }))
    t.core.setChatMedia(thread.id, "photosVideos", rows)
    const model = mediaModel("media")
    await t.flush()
    const before = items(model)
    const sent: MessageRow = { ...rows[3]!, media: { kind: "photo", photo: photo(999) } }
    t.core.setChatMedia(thread.id, "photosVideos", rows.map((row, i) => (i === 3 ? sent : row)))
    await t.flush()
    const after = items(model)
    expect(after.filter((item, i) => item !== before[i])).toHaveLength(1)
    expect(rowKeyOf(sent)).toBe(model.ids.peek()[3])
  })
})

describe("media grid keyboard", () => {
  const grid = (count: number, columns = 4) => {
    const opened: number[] = []
    let nearEnd = 0
    const size = signal(count)
    const g = createMediaGrid({ count: size, onOpen: (i) => opened.push(i), onNearEnd: () => (nearEnd += 1) })
    g.setColumns(columns)
    return { g, opened, nearEnd: () => nearEnd, size }
  }

  it("matches the CSS grid's columns: 100 px cells, 4 px gaps", () => {
    expect(columnsFor(99)).toBe(1)
    expect(columnsFor(204)).toBe(2)
    expect(columnsFor(320)).toBe(3)
    expect(columnsFor(416)).toBe(4)
  })

  it("moves by cell and by row, mirrors left and right in right to left, opens with Enter, asks for more at the last row", () => {
    const { g, opened, nearEnd } = grid(10)
    g.handleKey("ArrowRight")
    expect(g.active.peek()).toBe(1)
    g.handleKey("ArrowDown")
    expect(g.active.peek()).toBe(5)
    g.handleKey("ArrowUp")
    g.handleKey("ArrowUp")
    expect(g.active.peek()).toBe(1)
    g.setDirection("rtl")
    g.handleKey("ArrowRight")
    expect(g.active.peek()).toBe(0)
    g.handleKey("ArrowLeft")
    expect(g.active.peek()).toBe(1)
    expect(nearEnd()).toBe(0)
    g.handleKey("End")
    expect(g.active.peek()).toBe(9)
    expect(nearEnd()).toBe(1)
    g.handleKey("Home")
    g.handleKey("PageDown")
    expect(g.active.peek()).toBe(9)
    g.handleKey("Enter")
    g.handleKey(" ")
    expect(opened).toEqual([9, 9])
    expect(g.handleKey("a")).toBe(false)
  })

  it("keeps one tab stop, inside the list when it shrinks", () => {
    const { g, size } = grid(6)
    g.handleKey("End")
    expect(g.isTabStop(5).peek()).toBe(true)
    expect(g.isTabStop(0).peek()).toBe(false)
    size.set(3)
    expect(g.active.peek()).toBe(2)
    expect(g.isTabStop(2).peek()).toBe(true)
  })
})

describe("chat info: media tabs in the pane", () => {
  let model: ChatInfoModel | undefined
  afterEach(() => {
    model?.dispose()
    model = undefined
  })

  it("makes a tab's model on first use, opens a photo through onOpenMedia, and releases everything on dispose", async () => {
    const t = harness()
    t.core.setParticipants(thread.id, [me])
    t.core.setChatMedia(thread.id, "photosVideos", [message(3, { media: { kind: "photo", photo: photo(3) } })])
    const opened: unknown[] = []
    model = createChatInfoModel({
      client: t.client,
      chatId: thread.id,
      viewerId: me,
      dialog: signal(undefined),
      tab: "media",
      onOpenProfile: () => {},
      clock: t.time,
      media: { sources: { photo: () => ({ state: signal({ status: "pending" as const }), retry: () => {} }), video: () => ({ state: signal({ status: "pending" as const }), retry: () => {} }), voice: () => ({ state: signal({ status: "pending" as const }), retry: () => {} }) }, onOpenMedia: (input) => opened.push(input) },
    })
    expect(t.core.subsOf("chatMedia")).toEqual([])
    const media = model.mediaTab("media")
    expect(model.mediaTab("media")).toBe(media)
    const stop = effect(() => void model!.mediaGrid.active.get())
    await t.flush()
    expect(t.core.subsOf("chatMedia")).toHaveLength(1)
    model.mediaGrid.handleKey("Enter")
    expect(opened).toEqual([{ rowId: `${thread.id}:3`, key: "photo:3", kind: "photo", photo: photo(3), video: undefined }])
    stop()
    model.dispose()
    model = undefined
    await t.flush()
    expect(t.core.subsOf("chatMedia")).toEqual([])
  })

  it("a send from this device keeps its owner fields for the media layer", async () => {
    const t = harness()
    const local = message(0, { id: sentMessageRowId(thread.id, "77"), clientKey: "77", out: true, fromId: me, media: { kind: "photo", photo: photo(1) } })
    t.core.setChatMedia(thread.id, "photosVideos", [local])
    const m = mediaModel("media")
    await t.flush()
    expect(items(m)[0]).toMatchObject({ owner: { chatId: thread.id, clientKey: "77", messageId: "0" }, senderName: "You" })
  })
})
