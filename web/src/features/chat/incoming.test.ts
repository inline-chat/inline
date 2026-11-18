import type { MessageRow, MessageRowId, QueryDescriptor, WindowResource } from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import { manualTime } from "@inline/reactive"
import { AccountSession } from "@inline/view/features"
import { describe, expect, it, vi } from "vitest"
import { coreHarness, microtasks } from "../../app/test-fixtures"
import { ChatPaneModel, paneDestination, type ChatPaneStage } from "./chat-pane-model"

/**
 * Incoming message latency, the pane's part (performance.md: "painted within
 * one frame of the patch"). The store client applies the patch at the start
 * of a frame; from there every hand-off in the pane must happen in that same
 * task: the chat model's signals change inside the store's batch, the pane's
 * effect runs when the batch ends and calls `setItems` once, and the
 * controller publishes `rendered` before the frame callback returns.
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

const windowResource = (): WindowResource => ({ kind: "window", hasOlder: false, hasNewer: false, atLatest: true, loading: "none" })

const setup = async () => {
  const time = manualTime()
  const core = coreHarness(time)
  const session = new AccountSession({ userId: me, token: "t", connect: () => core.connection, clock: time })
  const stages: string[] = []
  const pane = new ChatPaneModel({
    session,
    timeZone: "UTC",
    clock: { now: () => time.now(), setTimeout: () => () => {} },
    frames: { request: () => () => {} },
    hooks: { onStage: (stage: ChatPaneStage) => stages.push(stage) },
  })
  pane.follow(paneDestination(session.workspace, session.workspace.focusedPaneId.peek()))
  const isWindow = (query: QueryDescriptor) => query.kind === "chatWindow" && query.chatId === chat
  session.workspace.open({ kind: "chat", chatId: chat })
  core.list(isWindow, [message(1), message(2), message(3)])
  core.endpoint.patch({ resources: [{ sub: core.sub(isWindow), value: windowResource() }] })
  time.frame()
  await microtasks()
  const open = pane.current.peek()!
  expect(open.opened.peek()).toBe(true)
  return { time, core, open, stages, isWindow }
}

describe("an incoming message", () => {
  it("reaches the timeline with one setItems in the same task as the store change", async () => {
    const s = await setup()
    const setItems = vi.spyOn(s.open.timeline, "setItems")
    s.stages.length = 0

    s.core.endpoint.patch({
      rows: [{ op: "upsert", row: message(4) }],
      lists: [{ sub: s.core.sub(s.isWindow), op: "splice", index: 3, remove: 0, insert: [`message:${chat}:4` as never] }],
    })
    // The patch waits for the frame lane: nothing has moved yet.
    expect(setItems).not.toHaveBeenCalled()

    // The frame: the store applies the patch, and in the same task the pane
    // reads the rows, calls setItems once, and the controller publishes them.
    s.time.frame()
    expect(setItems).toHaveBeenCalledTimes(1)
    const rendered = s.open.timeline.rendered.peek()
    expect(rendered.filter((item) => item.kind === "message").map((item) => item.key).at(-1)).toContain(":4")
    expect(s.stages).toEqual(["rows", "setItems"])

    // The commit stage is marked after the microtask the view framework queued.
    await microtasks()
    expect(s.stages).toEqual(["rows", "setItems", "commit"])
    expect(setItems).toHaveBeenCalledTimes(1)
  })

  it("a burst of patches inside one frame is one setItems", async () => {
    const s = await setup()
    const setItems = vi.spyOn(s.open.timeline, "setItems")
    for (const n of [4, 5, 6]) {
      s.core.endpoint.patch({
        rows: [{ op: "upsert", row: message(n) }],
        lists: [{ sub: s.core.sub(s.isWindow), op: "splice", index: n - 1, remove: 0, insert: [`message:${chat}:${n}` as never] }],
      })
    }
    s.time.frame()
    expect(setItems).toHaveBeenCalledTimes(1)
    expect(s.open.timeline.items.peek().filter((item) => item.kind === "message")).toHaveLength(6)
  })

  it("reports where a chat's first rows came from", async () => {
    const s = await setup()
    // Opened after the core answered (not in the opening task), with rows: the local store.
    expect(s.open.source.peek()).toBe("sqlite")
  })
})
