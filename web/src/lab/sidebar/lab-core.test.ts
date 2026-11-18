/** The lab's stand-in core, through the real store client and `SidebarModel`. */

import { createScheduler, createStoreClient, manualTime } from "@inline/reactive"
import { Workspace } from "@inline/view"
import { SidebarModel } from "@inline/view/features"
import { describe, expect, it } from "vitest"
import { LabCore } from "./lab-core"
import { generateAccount } from "./lab-data"

const setup = (count: number) => {
  const time = manualTime()
  const scheduler = createScheduler({ clock: time, frames: time.frames, idleSource: time.idleSource })
  const core = new LabCore(count, (fn) => scheduler.frame(fn))
  const client = createStoreClient({ endpoint: core.endpoint, scheduler })
  const model = new SidebarModel({ client, workspace: new Workspace({ createId: () => "w" }) })
  const answer = async () => {
    await new Promise((resolve) => setTimeout(resolve, 0))
    time.frame()
  }
  return { time, core, model, answer }
}

describe("lab data", () => {
  it("is seeded and mixes DMs, threads, pins, unread and drafts", () => {
    const a = generateAccount(500)
    expect(generateAccount(500)).toEqual(a)
    expect(a.chats.filter((chat) => chat.dialog.pinned)).toHaveLength(3)
    expect(a.chats.some((chat) => chat.chat.peerUserId)).toBe(true)
    expect(a.chats.some((chat) => chat.chat.emoji)).toBe(true)
    expect(a.chats.some((chat) => chat.dialog.unreadCount > 0)).toBe(true)
    expect(a.chats.some((chat) => chat.draft)).toBe(true)
  })
})

describe("LabCore", () => {
  it("answers the sidebar with pinned first, and is ready in the same frame as the list", async () => {
    const s = setup(200)
    expect(s.core.ready.peek()).toBe(false)
    await s.answer()
    const keys = s.model.items.peek()
    expect(s.core.ready.peek()).toBe(true)
    expect(keys.length).toBeGreaterThan(100)
    expect(keys.slice(0, 3).map((key) => s.core.chatByDialogKey(key)?.dialog.pinned)).toEqual([true, true, true])
    expect(s.model.item(keys[3]!).peek()?.title).toBeTruthy()
  })

  it("moves a chat with a new message to the top after the pins, and reorders without row changes", async () => {
    const s = setup(50)
    await s.answer()
    const before = s.model.items.peek()
    const last = before[before.length - 1]!
    const n = s.core.chatByDialogKey(last)!.n
    s.core.newMessage(n)
    s.time.frame()
    expect(s.model.items.peek()[3]).toBe(last)
    const item = s.model.item(last).peek()!
    s.core.reorder(0, 4)
    s.time.frame()
    expect(s.model.items.peek()[6]).toBe(last)
    expect(s.model.item(last).peek()).toBe(item)
  })

  it("filters by mode: all shows closed chats too", async () => {
    const s = setup(300)
    await s.answer()
    const inbox = s.model.items.peek().length
    s.model.setMode("all")
    expect(s.core.ready.peek()).toBe(false)
    await s.answer()
    expect(s.core.ready.peek()).toBe(true)
    expect(s.model.items.peek().length).toBe(300)
    expect(inbox).toBeLessThan(300)
  })
})
