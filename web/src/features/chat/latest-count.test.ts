import type { DialogRow, MessageRow, MessageRowId, QueryDescriptor, WindowResource } from "@inline/core-protocol"
import type { ChatID, DialogID, MessageID, UserID } from "@inline/ids"
import { manualTime } from "@inline/reactive"
import { createFakeHost } from "@inline/timeline/testing"
import { AccountSession } from "@inline/view/features"
import { describe, expect, it } from "vitest"
import { coreHarness, microtasks } from "../../app/test-fixtures"
import { ChatPaneModel, paneDestination } from "./chat-pane-model"

/**
 * The jump-to-latest count is the timeline controller's: the dialog's unread
 * count (server-owned, which the core raises on each incoming message) minus
 * incoming messages read locally that the server has not caught up with
 * (`jumpToLatestCount`). The pane feeds it the dialog through
 * `setReadState` and the rows through `setItems`. This drives the whole
 * chain: scripted core patch, store, chat model, pane model, controller.
 */

const me = "7" as UserID
const peer = "9" as UserID
const chat = "5" as ChatID
const mid = (n: number) => String(n) as MessageID

const message = (n: number): MessageRow => ({
  kind: "message",
  id: `${chat}:${n}` as MessageRowId,
  chatId: chat,
  messageId: mid(n),
  fromId: peer,
  out: false,
  date: 1_800_000_000 + n * 10,
  text: `m${n}`,
  state: "sent",
})

const dialog = (unreadCount: number, readMaxId: number): DialogRow => ({
  kind: "dialog",
  id: "5" as DialogID,
  chatId: chat,
  peerUserId: peer,
  pinned: false,
  archived: false,
  open: true,
  unreadCount,
  unreadMark: false,
  readMaxId: mid(readMaxId),
})

const windowResource = (extra: Partial<WindowResource> = {}): WindowResource => ({
  kind: "window",
  hasOlder: false,
  hasNewer: false,
  atLatest: true,
  loading: "none",
  ...extra,
})

describe("jump to latest count", () => {
  it("a new incoming row while reading above raises the count by one", async () => {
    const time = manualTime()
    const core = coreHarness(time)
    const session = new AccountSession({ userId: me, token: "t", connect: () => core.connection, clock: time })
    const fake = createFakeHost({ viewportHeight: 600, devicePixelRatio: 1 })
    const pane = new ChatPaneModel({ session, timeZone: "UTC", clock: fake.clock, frames: fake.frames })
    pane.follow(paneDestination(session.workspace, session.workspace.focusedPaneId.peek()))
    const flush = async () => {
      time.frame()
      await microtasks()
    }
    const isAll = (query: QueryDescriptor) => query.kind === "sidebar" && query.mode === "all"
    const isWindow = (query: QueryDescriptor) => query.kind === "chatWindow" && query.chatId === chat

    // 40 messages, read through 20: 20 unread.
    // The chat row names its dialog (`dialogId`), as the core's do: that is how the session finds it.
    core.list(isAll, [{ kind: "chat", id: chat, peerUserId: peer, dialogId: "5" as DialogID }, dialog(20, 20)])
    await flush()
    session.workspace.open({ kind: "chat", chatId: chat })
    const open = pane.current.peek()!
    const rows = Array.from({ length: 40 }, (_, index) => message(index + 1))
    core.list(isWindow, rows)
    core.endpoint.patch({ resources: [{ sub: core.sub(isWindow), value: windowResource({ unreadBoundary: mid(20) }) }] })
    await flush()
    expect(open.opened.peek()).toBe(true)

    // Render what the controller asks for, land, and let it read what is on screen.
    const commit = () =>
      fake.setRows(open.timeline.rendered.peek().map((item) => ({ key: item.key, height: item.kind === "message" ? 60 : 30 })))
    open.timeline.attach(fake.host)
    commit()
    fake.advance(100)
    expect(open.timeline.mode.peek()).toBe("restoring")
    const before = open.timeline.latestButton.peek()
    expect(before.visible).toBe(true)
    // The reader saw 21 to 30 and marked them read; the server's dialog has not caught up yet.
    expect(core.endpoint.commands("intent").map((command) => command.intent)).toEqual([
      { kind: "markRead", chatId: chat, maxId: mid(30) },
    ])
    expect(before.count).toBe(10)

    // An incoming message: the core appends it to the window and raises the dialog's unread count.
    core.endpoint.patch({
      rows: [
        { op: "upsert", row: message(41) },
        { op: "upsert", row: dialog(21, 20) },
      ],
      lists: [{ sub: core.sub(isWindow), op: "splice", index: 40, remove: 0, insert: [`message:${chat}:41` as never] }],
    })
    await flush()
    commit()
    fake.advance(100)

    expect(open.timeline.items.peek().filter((item) => item.kind === "message")).toHaveLength(41)
    const after = open.timeline.latestButton.peek()
    expect(after.count).toBe(before.count + 1)
    expect(open.timeline.mode.peek()).toBe("restoring")
  })
})
