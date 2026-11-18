import { rowKeyOf, type WindowResource } from "@inline/core-protocol"
import { manualTime } from "@inline/reactive"
import { AccountSession } from "@inline/view/features"
import { describe, expect, it } from "vitest"
import { coreHarness, microtasks } from "../test-fixtures"
import { captureBootSnapshot } from "./capture"
import { BOOT_SNAPSHOT_BUDGET, SNAPSHOT_SIDEBAR_ITEMS, SNAPSHOT_WINDOW_ROWS } from "./format"
import { provisionalData } from "./restore"
import { account, answer, BUILD, cid, mid, uid, type Account } from "./test-support"

const running = async (data: Account, place?: number) => {
  const time = manualTime()
  const core = coreHarness(time)
  const session = new AccountSession({ userId: uid(7), token: "t7", clock: time, connect: () => core.connection })
  session.workspace.open({ kind: "chat", chatId: cid(1) })
  if (place !== undefined) session.workspace.viewState.set({ kind: "chat", chatId: cid(1) }, { place: { messageId: mid(place), offset: 12 } })
  const lease = session.openChat(cid(1))
  answer(core, data)
  time.frame()
  await microtasks()
  return { session, lease, core }
}

const options = { buildId: BUILD, now: () => 5 }

const windowOf = (capture: NonNullable<ReturnType<typeof captureBootSnapshot>>) => {
  const sub = capture.snapshot.client.queries.find((entry) => entry.query.kind === "chatWindow")?.sub
  return capture.snapshot.client.store.lists.find((list) => list.sub === sub)
}

describe("capturing the boot snapshot", () => {
  it("keeps what is on screen: the user, the sidebar, the open chat's window and the rows they need", async () => {
    const data = account()
    const { session } = await running(data)
    const capture = captureBootSnapshot(session, options)!
    expect(capture.dropped).toEqual([])
    expect(capture.snapshot).toMatchObject({ build: BUILD, user: uid(7), savedAt: 5, chat: { chatId: cid(1) } })
    expect(capture.snapshot.client.queries.map((entry) => entry.query.kind)).toEqual(["me", "sidebar", "chatWindow"])
    const keys = new Set(capture.snapshot.client.store.rows.map(rowKeyOf))
    for (const row of [data.me, ...data.dialogs, ...data.chats, ...data.peers, ...data.lasts, ...data.window, ...data.drafts]) {
      expect(keys.has(rowKeyOf(row))).toBe(true)
    }
    // The visit's unread line is not carried over; the core's window brings the new one.
    const resource = windowOf(capture)?.resource as WindowResource
    expect(resource.unreadBoundary).toBeUndefined()
    expect(resource.loading).toBe("none")
    expect(JSON.parse(capture.text)).toEqual(capture.snapshot)
    expect(capture.text).not.toContain("t7")
  })

  it("cuts the window around the saved reading place and asks the core for the same place", async () => {
    const data = account({ messages: 200 })
    const { session } = await running(data, 120)
    const capture = captureBootSnapshot(session, options)!
    const window = windowOf(capture)!
    expect(window.keys).toHaveLength(SNAPSHOT_WINDOW_ROWS)
    expect(window.keys[0]).toBe(rowKeyOf(data.window[109]!))
    expect(window.keys).toContain(rowKeyOf(data.window[119]!))
    expect(window.resource).toMatchObject({ hasOlder: true, hasNewer: true, atLatest: false })
    expect(capture.snapshot.chat).toEqual({ chatId: cid(1), around: mid(120) })
    const restored = provisionalData(capture.snapshot)
    expect(restored.queries.find((entry) => entry.query.kind === "chatWindow")?.query).toEqual({
      kind: "chatWindow",
      chatId: cid(1),
      anchor: { around: mid(120) },
    })
  })

  it("keeps the newest rows when the reader was at the end", async () => {
    const data = account({ messages: 200 })
    const { session } = await running(data)
    const capture = captureBootSnapshot(session, options)!
    const window = windowOf(capture)!
    expect(window.keys.at(-1)).toBe(rowKeyOf(data.window[199]!))
    expect(window.keys).toHaveLength(SNAPSHOT_WINDOW_ROWS)
    expect(window.resource).toMatchObject({ hasOlder: true, hasNewer: false, atLatest: true })
    expect(provisionalData(capture.snapshot).queries.find((entry) => entry.query.kind === "chatWindow")?.query).toMatchObject({
      anchor: "unread",
    })
  })

  it("keeps the first screens of a long sidebar", async () => {
    const data = account({ chats: 300 })
    const { session } = await running(data)
    const capture = captureBootSnapshot(session, options)!
    const sub = capture.snapshot.client.queries.find((entry) => entry.query.kind === "sidebar")?.sub
    expect(capture.snapshot.client.store.lists.find((list) => list.sub === sub)?.keys).toHaveLength(SNAPSHOT_SIDEBAR_ITEMS)
    expect(capture.snapshot.client.store.rows.some((row) => row.kind === "dialog" && row.id === "200")).toBe(false)
    expect(capture.text.length).toBeLessThan(BOOT_SNAPSHOT_BUDGET)
  })

  it("drops the chat window first when over the budget, then halves the sidebar", async () => {
    const data = account({ chats: 40, messages: 60, text: (id) => `${id} `.padEnd(1_000, "x") })
    const { session } = await running(data)
    const full = captureBootSnapshot(session, options)!
    expect(full.dropped).toEqual([])

    const noChat = captureBootSnapshot(session, { ...options, budget: full.text.length - 1 })!
    expect(noChat.dropped).toEqual(["chat"])
    expect(noChat.snapshot.chat).toBeUndefined()
    expect(noChat.snapshot.client.queries.map((entry) => entry.query.kind)).toEqual(["me", "sidebar"])
    // The open chat's own messages went with its window; the sidebar's last messages stayed.
    expect(noChat.snapshot.client.store.rows.some((row) => row.kind === "message" && row.chatId === cid(1) && row.messageId === mid(30))).toBe(false)
    expect(noChat.snapshot.client.store.rows.filter((row) => row.kind === "dialog")).toHaveLength(40)

    const half = captureBootSnapshot(session, { ...options, budget: noChat.text.length - 1 })!
    expect(half.dropped).toEqual(["chat", "sidebarRows"])
    expect(half.snapshot.client.store.rows.filter((row) => row.kind === "dialog")).toHaveLength(20)
    expect(half.text.length).toBeLessThan(noChat.text.length)

    expect(captureBootSnapshot(session, { ...options, budget: 10 })).toBeUndefined()
  })

  it("leaves the chat out while its window has not loaded", async () => {
    const time = manualTime()
    const core = coreHarness(time)
    const session = new AccountSession({ userId: uid(7), token: "t7", clock: time, connect: () => core.connection })
    session.workspace.open({ kind: "chat", chatId: cid(1) })
    session.openChat(cid(1))
    const capture = captureBootSnapshot(session, options)!
    expect(capture.snapshot.chat).toBeUndefined()
    expect(capture.snapshot.client.queries.map((entry) => entry.query.kind)).toEqual(["me", "sidebar"])
  })
})
