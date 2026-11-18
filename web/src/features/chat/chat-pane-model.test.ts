import type { DraftRow, MessageRow, MessageRowId, QueryDescriptor, WindowResource } from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import { manualTime, signal } from "@inline/reactive"
import { AccountSession } from "@inline/view/features"
import { describe, expect, it } from "vitest"
import { coreHarness, microtasks } from "../../app/test-fixtures"
import { ChatPaneModel, followDraft, paneDestination } from "./chat-pane-model"

const cid = (n: number) => String(n) as ChatID
const mid = (n: number) => String(n) as MessageID
const me = "7" as UserID

const message = (chat: number, n: number, text = `m${n}`): MessageRow => ({
  kind: "message",
  id: `${chat}:${n}` as MessageRowId,
  chatId: cid(chat),
  messageId: mid(n),
  fromId: "9" as UserID,
  out: false,
  date: 1_800_000_000 + n,
  text,
  state: "sent",
} as MessageRow)

const windowResource = (extra: Partial<WindowResource> = {}): WindowResource => ({
  kind: "window",
  hasOlder: false,
  hasNewer: false,
  atLatest: true,
  loading: "none",
  ...extra,
})

const setup = () => {
  const time = manualTime()
  const core = coreHarness(time)
  const session = new AccountSession({ userId: me, token: "t", connect: () => core.connection, clock: time })
  const paneId = session.workspace.focusedPaneId.peek()
  const events: string[] = []
  const pane = new ChatPaneModel({
    session,
    timeZone: "UTC",
    clock: { now: () => time.now(), setTimeout: () => () => {} },
    frames: { request: () => () => {} },
    hooks: {
      onSwitch: () => events.push("switch"),
      onRowsShown: () => events.push("rows"),
      trackSend: () => events.push("send"),
    },
  })
  pane.follow(paneDestination(session.workspace, paneId))
  const isWindow = (chat: number) => (query: QueryDescriptor) => query.kind === "chatWindow" && query.chatId === cid(chat)
  const flush = async () => {
    time.frame()
    await microtasks()
  }
  /** The core answers a chat's window with these messages. */
  const answer = async (chat: number, rows: MessageRow[], extra: Partial<WindowResource> = {}) => {
    core.list(isWindow(chat), rows)
    core.endpoint.patch({ resources: [{ sub: core.sub(isWindow(chat)), value: windowResource(extra) }] })
    await flush()
  }
  const open = (chat: number) => session.workspace.open({ kind: "chat", chatId: cid(chat) })
  return { time, core, session, pane, events, answer, open, flush, isWindow }
}

describe("ChatPaneModel", () => {
  it("follows the pane's destination and feeds the timeline once the core answers", async () => {
    const s = setup()
    expect(s.pane.current.peek()).toBeUndefined()
    s.open(5)
    const chat = s.pane.current.peek()!
    expect(chat.chatId).toBe(cid(5))
    expect(chat.opened.peek()).toBe(false)
    expect(chat.timeline.items.peek()).toEqual([])
    await s.answer(5, [message(5, 1), message(5, 2)])
    expect(chat.opened.peek()).toBe(true)
    expect(chat.timeline.items.peek().filter((item) => item.kind === "message")).toHaveLength(2)
    expect(s.events).toEqual(["rows"])
  })

  it("swaps models in the same pane, and a resident chat repaints from memory in the same task", async () => {
    const s = setup()
    s.open(5)
    await s.answer(5, [message(5, 1)])
    const first = s.pane.current.peek()!
    s.open(6)
    const second = s.pane.current.peek()!
    expect(second.chatId).toBe(cid(6))
    expect(first.disposed).toBe(true)
    // Chat 5 stays resident: its window subscription is still open.
    expect(s.core.openSubs().some(s.isWindow(5))).toBe(true)
    await s.answer(6, [message(6, 1)])

    s.events.length = 0
    s.open(5)
    const back = s.pane.current.peek()!
    expect(back).not.toBe(first)
    expect(back.model).toBe(first.model)
    // Opened with its rows before any frame or patch: the next paint shows them.
    expect(back.opened.peek()).toBe(true)
    expect(back.timeline.items.peek().filter((item) => item.kind === "message")).toHaveLength(1)
    expect(s.events).toEqual(["switch", "rows"])
    // `__inlineApp.openChat.source`: the first visit came from the core, the second from memory.
    expect(first.source.peek()).toBe("sqlite")
    expect(back.source.peek()).toBe("memory")
  })

  it("jumps within the same chat for a message destination instead of reopening it", async () => {
    const s = setup()
    s.open(5)
    await s.answer(5, [message(5, 1), message(5, 2)])
    const chat = s.pane.current.peek()!
    s.session.workspace.open({ kind: "message", chatId: cid(5), messageId: mid(1) })
    expect(s.pane.current.peek()).toBe(chat)
    expect(chat.target.messageId).toBe(mid(1))
  })

  it("opens a message link around that message", () => {
    const s = setup()
    s.session.workspace.open({ kind: "message", chatId: cid(5), messageId: mid(40) })
    const window = s.core.openSubs().find(s.isWindow(5))
    expect(window).toMatchObject({ kind: "chatWindow", anchor: { around: mid(40) } })
  })

  it("clears the pane for a destination without a chat and releases everything on dispose", async () => {
    const s = setup()
    s.open(5)
    const chat = s.pane.current.peek()!
    s.session.workspace.open({ kind: "settings" })
    expect(s.pane.current.peek()).toBeUndefined()
    expect(chat.disposed).toBe(true)
    s.pane.dispose()
    s.open(6)
    expect(s.pane.current.peek()).toBeUndefined()
  })

  it("restores the draft synchronously for a resident chat, and follows one that arrives later", async () => {
    const s = setup()
    s.open(5)
    const chat = s.pane.current.peek()!
    expect(chat.initialDraft()).toBeUndefined()
    const doc = signal({ text: "", revision: 0 })
    const set: string[] = []
    const stop = followDraft(chat, {
      doc,
      setDraft: (draft) => {
        set.push(draft.text)
        doc.set({ text: draft.text, revision: draft.revision })
      },
    })
    const draft: DraftRow = { kind: "draft", id: cid(5), text: "hello", revision: 3 }
    s.core.endpoint.patch({ rows: [{ op: "upsert", row: draft }] })
    await s.flush()
    expect(set).toEqual(["hello"])
    expect(chat.initialDraft()).toEqual({ text: "hello", revision: 3 })
    // Typed text wins over a draft that arrives after it.
    doc.set({ text: "typed", revision: 4 })
    s.core.endpoint.patch({ rows: [{ op: "upsert", row: { ...draft, text: "older", revision: 5 } }] })
    await s.flush()
    expect(set).toEqual(["hello"])
    stop()
  })

  it("tracks sends and keeps the reader following them", async () => {
    const s = setup()
    s.open(5)
    await s.answer(5, [message(5, 1)])
    const chat = s.pane.current.peek()!
    void chat.send({ kind: "send", text: "hi", entities: [], revision: 1 })
    expect(s.events.at(-1)).toBe("send")
    expect(s.core.endpoint.commands("intent").at(-1)).toMatchObject({ intent: { kind: "sendText", text: "hi" } })
    // The optimistic row is in the window in the same task.
    expect(chat.model.rowKeys.peek()).toHaveLength(2)
  })

  it("shows the connection state in the subtitle", async () => {
    const s = setup()
    s.open(5)
    const chat = s.pane.current.peek()!
    expect(chat.subtitle.peek()).toEqual({ kind: "none" })
    s.core.core({ connection: "connecting" })
    await s.flush()
    expect(chat.subtitle.peek()).toEqual({ kind: "connection", state: "connecting" })
  })
})
