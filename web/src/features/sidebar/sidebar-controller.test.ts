/**
 * The controller over a real `SidebarModel` and store client, driven by a
 * scripted core and a manual clock. No DOM: parts are not attached, so these
 * cover the state the view renders from (window, roving tab stop, status,
 * unread below) and the commands (keys, typeahead, open, mode).
 */

import type { ChatRow, DialogRow, QueryDescriptor, Row, RowKey, SubId, UserRow } from "@inline/core-protocol"
import { rowKeyOf } from "@inline/core-protocol"
import type { ChatID, DialogID, UserID } from "@inline/ids"
import { computed, createScheduler, createStoreClient, effect, manualTime, signal } from "@inline/reactive"
import { scriptedEndpoint } from "@inline/reactive/testing"
import { ContextMenuController, createManualClock, Lazy, type MenuKitCore } from "@inline/ui"
import { Workspace } from "@inline/view"
import { SidebarModel } from "@inline/view/features"
import { describe, expect, it } from "vitest"
import { basicActions } from "./actions"
import { SidebarHandle } from "./handle"
import { rowTop } from "./geometry"
import { SidebarController } from "./sidebar-controller"

const cid = (n: number) => String(n) as ChatID
const uid = (n: number) => String(n) as UserID
const did = (n: number) => String(n) as DialogID

const dialog = (n: number, extra: Partial<DialogRow> = {}): DialogRow => ({
  kind: "dialog",
  id: did(n),
  chatId: cid(n),
  pinned: false,
  archived: false,
  open: true,
  unreadCount: 0,
  unreadMark: false,
  ...extra,
})
const chat = (n: number, extra: Partial<ChatRow> = {}): ChatRow => ({ kind: "chat", id: cid(n), title: `Chat ${n}`, ...extra })
const user = (n: number, firstName: string): UserRow => ({ kind: "user", id: uid(n), firstName })
const upserts = (rows: Row[]) => rows.map((row) => ({ op: "upsert" as const, row }))

const setup = (options: { ready?: boolean } = {}) => {
  const time = manualTime()
  const scheduler = createScheduler({ clock: time, frames: time.frames, idleSource: time.idleSource })
  const endpoint = scriptedEndpoint()
  const client = createStoreClient({ endpoint, scheduler })
  const workspace = new Workspace({ createId: () => "w" })
  const model = new SidebarModel({ client, workspace })
  const ready = signal(options.ready ?? true)
  const clock = createManualClock()
  const handle = new SidebarHandle()
  const controller = new SidebarController({
    model,
    os: "mac",
    clock,
    handle,
    overscan: 2,
    initialViewportHeight: 406,
    // The menu's code without its view: what the kit's chunk gives the controller.
    menuKit: new Lazy<MenuKitCore>(async () => ({ ContextMenuController })),
    ...(options.ready === undefined ? {} : { ready: computed(() => ready.get()) }),
  })
  const sub = (match: (q: QueryDescriptor) => boolean): SubId => {
    let found: SubId | undefined
    const live = new Map<SubId, QueryDescriptor>()
    for (const command of endpoint.posted) {
      if (command.kind === "subscribe") live.set(command.sub, command.query)
      if (command.kind === "unsubscribe") live.delete(command.sub)
    }
    for (const [id, query] of live) if (match(query)) found = id
    if (found === undefined) throw new Error("no subscription")
    return found
  }
  const deliver = (rows: Row[], order?: DialogRow[], mode: "inbox" | "all" = "inbox") => {
    endpoint.patch({
      rows: upserts(rows),
      lists: order ? [{ sub: sub((q) => q.kind === "sidebar" && q.mode === mode), op: "replace", keys: order.map(rowKeyOf) }] : [],
    })
    time.frame()
  }
  return { time, endpoint, client, workspace, model, controller, ready, clock, handle, deliver }
}

/** N dialogs with chats; every third one a prominent DM with unread. */
const seed = (count: number) => {
  const rows: Row[] = []
  const dialogs: DialogRow[] = []
  for (let n = 1; n <= count; n++) {
    const dm = n % 3 === 0
    const d = dialog(n, dm ? { peerUserId: uid(n), unreadCount: 1 } : {})
    dialogs.push(d)
    rows.push(d, chat(n, dm ? { peerUserId: uid(n) } : {}))
    if (dm) rows.push(user(n, `User ${n}`))
  }
  return { rows, dialogs }
}

const press = (key: string, extra: Record<string, boolean> = {}) => {
  let prevented = false
  return {
    event: { key, ...extra, preventDefault: () => (prevented = true) },
    prevented: () => prevented,
  }
}

const keyOf = (n: number) => `dialog:${n}` as RowKey

describe("SidebarController", () => {
  it("renders a bounded window over thousands of rows, in the core's order", () => {
    const s = setup()
    const { rows, dialogs } = seed(5000)
    s.deliver(rows, dialogs)
    expect(s.controller.status.peek()).toBe("list")
    expect(s.controller.displayKeys.peek()).toHaveLength(5000)
    // 406 px at 40 px a row: rows 0..9 visible, 2 overscan below.
    expect(s.controller.windowKeys.peek()).toEqual(dialogs.slice(0, 12).map(rowKeyOf))
    s.controller.setViewport(rowTop(2000, 40), 406)
    const window = s.controller.windowKeys.peek()
    expect(window.length).toBeLessThanOrEqual(16)
    // The current row (the first, nothing selected) stays rendered, first in order.
    expect(window[0]).toBe(keyOf(1))
    expect(window[1]).toBe(keyOf(1999))
  })

  it("keeps the window's identity when an item changes, and changes it on a reorder", () => {
    const s = setup()
    const { rows, dialogs } = seed(50)
    s.deliver(rows, dialogs)
    const before = s.controller.windowKeys.peek()
    let windows = 0
    const stop = effect(() => {
      s.controller.windowKeys.get()
      windows += 1
    })
    s.deliver([dialog(2, { unreadCount: 5 })])
    expect(s.controller.windowKeys.peek()).toBe(before)
    expect(windows).toBe(1)
    const swapped = [dialogs[1]!, dialogs[0]!, ...dialogs.slice(2)]
    s.deliver([], swapped)
    expect(s.controller.windowKeys.peek().slice(0, 2)).toEqual([keyOf(2), keyOf(1)])
    expect(windows).toBe(2)
    stop()
  })

  it("recycles row slots: a reorder keeps every slot, scrolling reuses them", () => {
    const s = setup()
    const { rows, dialogs } = seed(200)
    s.deliver(rows, dialogs)
    const slots = s.controller.slotKeys.peek()
    expect(slots).toHaveLength(12)
    const swapped = [dialogs[1]!, dialogs[0]!, ...dialogs.slice(2)]
    s.deliver([], swapped)
    expect(s.controller.slotKeys.peek()).toBe(slots)
    // Three rows down: the window grows at the bottom (the first row stays as
    // the current row), so every slot keeps its key and new slots are added.
    s.controller.scrolled(rowTop(3, 40))
    const grown = s.controller.slotKeys.peek()
    expect(grown.slice(0, 12)).toEqual(slots)
    // Twenty rows further, four at a time (slow): rows leaving free slots for
    // rows entering; the slot count holds and nothing is drawn lite.
    for (const row of [7, 11, 15, 19, 23]) s.controller.scrolled(rowTop(row, 40))
    const after = s.controller.slotKeys.peek()
    expect(after.length).toBe(grown.length)
    expect(new Set(after).size).toBe(after.length)
    expect(after).toContain(s.controller.currentKey.peek())
    for (let slot = 0; slot < after.length; slot++) {
      const view = s.controller.slot(slot).peek()
      expect(view.key).toBe(after[slot])
      expect(view.lite).toBe(false)
    }
  })

  it("draws rows lite while scrolling fast and fills them in a few per frame after", () => {
    const s = setup()
    const { rows, dialogs } = seed(5000)
    s.deliver(rows, dialogs)
    s.controller.scrolled(rowTop(1000, 40))
    const lite = () => s.controller.slotKeys.peek().filter((_, slot) => s.controller.slot(slot).peek().lite).length
    expect(s.controller.snapshot().fast).toBe(true)
    expect(lite()).toBeGreaterThan(8)
    // A small move while still fast keeps lite; then scrolling settles.
    s.controller.scrolled(rowTop(1001, 40))
    s.clock.advance(120)
    expect(s.controller.snapshot().fast).toBe(false)
    const before = lite()
    s.clock.advance(16)
    expect(lite()).toBe(Math.max(0, before - 8))
    s.clock.advance(16 * 10)
    expect(lite()).toBe(0)
    // A slow scroll draws full rows.
    s.controller.scrolled(rowTop(1003, 40))
    expect(lite()).toBe(0)
    expect(s.controller.snapshot().lite).toBe(0)
  })

  it("is loading, not empty, until the core answers, and holds the list across a mode switch", () => {
    const s = setup({ ready: false })
    expect(s.controller.status.peek()).toBe("loading")
    const { rows, dialogs } = seed(5)
    s.deliver(rows, dialogs)
    s.ready.set(true)
    expect(s.controller.status.peek()).toBe("list")
    s.ready.set(false)
    s.controller.setMode("all")
    expect(s.model.mode.peek()).toBe("all")
    // The new subscription has no answer yet: the inbox list stays on screen.
    expect(s.controller.displayKeys.peek()).toEqual(dialogs.map(rowKeyOf))
    expect(s.controller.busy.peek()).toBe(true)
    s.deliver([], dialogs.slice(0, 2), "all")
    s.ready.set(true)
    expect(s.controller.displayKeys.peek()).toEqual(dialogs.slice(0, 2).map(rowKeyOf))
    expect(s.controller.busy.peek()).toBe(false)
  })

  it("is empty once the core answers with nothing", () => {
    const s = setup({ ready: false })
    s.deliver([], [])
    expect(s.controller.status.peek()).toBe("loading")
    s.ready.set(true)
    expect(s.controller.status.peek()).toBe("empty")
  })

  it("moves the roving tab stop with the arrows, Home and End, without opening", () => {
    const s = setup()
    const { rows, dialogs } = seed(100)
    s.deliver(rows, dialogs)
    expect(s.controller.currentKey.peek()).toBe(keyOf(1))
    const down = press("ArrowDown")
    expect(s.controller.handleKeyDown(down.event)).toBe(true)
    expect(down.prevented()).toBe(true)
    expect(s.controller.currentKey.peek()).toBe(keyOf(2))
    s.controller.handleKeyDown(press("End").event)
    expect(s.controller.currentKey.peek()).toBe(keyOf(100))
    // The window followed: the last row is rendered and the list scrolled to it.
    expect(s.controller.windowKeys.peek()).toContain(keyOf(100))
    expect(s.controller.range.peek().last).toBe(100)
    s.controller.handleKeyDown(press("Home").event)
    expect(s.controller.currentKey.peek()).toBe(keyOf(1))
    s.controller.handleKeyDown(press("ArrowUp").event)
    expect(s.controller.currentKey.peek()).toBe(keyOf(1))
    s.controller.handleKeyDown(press("PageDown").event)
    expect(s.controller.currentKey.peek()).toBe(keyOf(10))
    expect(s.workspace.focusedDestination.peek().kind).not.toBe("chat")
    // Alt+Down belongs to the app (next chat).
    const alt = press("ArrowDown", { altKey: true })
    expect(s.controller.handleKeyDown(alt.event)).toBe(false)
    expect(alt.prevented()).toBe(false)
  })

  it("opens with Enter and Space, mapping modifiers to the model's intents, and reports it", () => {
    const opened: unknown[] = []
    const opener: string[] = []
    const s = setup()
    const { rows, dialogs } = seed(10)
    s.deliver(rows, dialogs)
    s.controller.setCallbacks({ onOpened: (event) => opened.push(event) })
    s.controller.handleKeyDown(press("ArrowDown").event)
    s.controller.handleKeyDown(press("Enter").event)
    expect(s.workspace.focusedDestination.peek()).toEqual({ kind: "chat", chatId: cid(2) })
    expect(s.controller.selectedKey.peek()).toBe(keyOf(2))
    expect(opened).toEqual([{ key: keyOf(2), chatId: cid(2), intent: "here", via: "keyboard" }])
    s.controller.handleKeyDown(press("ArrowDown").event)
    s.controller.handleKeyDown(press("Enter", { altKey: true }).event)
    expect(s.workspace.panes.peek()).toHaveLength(2)
    expect(s.workspace.focusedDestination.peek()).toEqual({ kind: "chat", chatId: cid(3) })
    s.controller.setCallbacks({ openIntent: () => "newPane", onOpened: (event) => opener.push(event.intent) })
    s.controller.handleKeyDown(press(" ").event)
    expect(opener).toEqual(["newPane"])
  })

  it("follows the selection while the list does not have focus", () => {
    const s = setup()
    const { rows, dialogs } = seed(200)
    s.deliver(rows, dialogs)
    s.model.open(keyOf(150))
    expect(s.controller.currentKey.peek()).toBe(keyOf(150))
    // Revealed: selection from elsewhere (next chat, a link) scrolls to it.
    expect(s.controller.windowKeys.peek()).toContain(keyOf(150))
    expect(s.controller.range.peek().first).toBeGreaterThan(100)
    expect(s.handle.revealSelected()).toBe(true)
  })

  it("typeahead finds titles across the whole list, not only the window", () => {
    const s = setup()
    const rows: Row[] = []
    const dialogs: DialogRow[] = []
    for (let n = 1; n <= 3000; n++) {
      dialogs.push(dialog(n))
      rows.push(dialog(n), chat(n, { title: n === 2500 ? "Zanzibar launch" : `Thread ${n}` }))
    }
    s.deliver(rows, dialogs)
    s.controller.handleKeyDown(press("z").event)
    s.controller.handleKeyDown(press("a").event)
    expect(s.controller.currentKey.peek()).toBe(keyOf(2500))
    expect(s.controller.windowKeys.peek()).toContain(keyOf(2500))
    // Space continues the search instead of opening.
    s.controller.handleKeyDown(press(" ").event)
    expect(s.workspace.focusedDestination.peek().kind).not.toBe("chat")
    s.clock.advance(600)
    s.controller.handleKeyDown(press("t").event)
    expect(s.controller.currentKey.peek()).toBe(keyOf(2501))
  })

  it("counts prominent unread rows below the viewport and scrolls to the nearest", () => {
    const s = setup()
    const { rows, dialogs } = seed(60)
    s.deliver(rows, dialogs)
    // Not tracked before the first paint.
    expect(s.controller.unreadBelow.peek()).toEqual({ count: 0 })
    s.controller.trackUnreadBelow()
    // Counted in its own task, not in the frame that changed the list.
    expect(s.controller.unreadBelow.peek()).toEqual({ count: 0 })
    s.clock.advance(50)
    // Rows 0..9 visible (10 rows of 40 px in 406 px); DMs at indices 2, 5, 8, ... 59.
    expect(s.controller.unreadBelow.peek()).toEqual({ count: 17, target: 11 })
    // A chat read elsewhere without moving: picked up when scrolling stops.
    s.deliver([dialog(12, { peerUserId: uid(12), unreadCount: 0 })])
    expect(s.controller.unreadBelow.peek()).toEqual({ count: 17, target: 11 })
    s.controller.setViewport(1, 406)
    s.clock.advance(250)
    expect(s.controller.unreadBelow.peek()).toEqual({ count: 16, target: 14 })
    // A list change (chat 60 read and moved to the top) is recounted 50 ms later.
    const moved = [dialog(60), ...seed(59).dialogs]
    s.deliver([dialog(60, { peerUserId: uid(60), unreadCount: 0 })], moved)
    expect(s.controller.unreadBelow.peek().count).toBe(16)
    s.clock.advance(50)
    expect(s.controller.unreadBelow.peek()).toEqual({ count: 15, target: 15 })
    s.deliver([], seed(60).dialogs)
    s.clock.advance(50)
    expect(s.controller.revealUnreadBelow()).toBe(true)
    expect(s.controller.windowKeys.peek()).toContain(keyOf(15))
    expect(s.controller.unreadBelow.peek().target).toBeGreaterThan(14)
  })

  it("supplies the context menu from the caller's actions for one row", async () => {
    const s = setup()
    await s.controller.contextMenu.warm()
    const { rows, dialogs } = seed(5)
    s.deliver(rows, dialogs)
    expect(s.controller.targetMenu(keyOf(2))).toBe(false)
    const pinned: string[] = []
    s.controller.setCallbacks({ actions: (item) => basicActions(item, { togglePin: (it) => pinned.push(it.title) }) })
    const entries = () => s.controller.contextMenu.controller.peek()?.menu.entries.peek() ?? []
    expect(entries()).toEqual([])
    // What a secondary click on row 2 does (the DOM part finds the row).
    expect(s.controller.targetMenu(keyOf(2))).toBe(true)
    expect(s.controller.isContextTarget(keyOf(2)).peek()).toBe(true)
    expect(s.controller.isContextTarget(keyOf(1)).peek()).toBe(false)
    const pin = entries()[0]
    expect(pin).toMatchObject({ type: "item", id: "pin", label: "Pin" })
    if (pin?.type === "item") pin.onSelect?.()
    expect(pinned).toEqual(["Chat 2"])
    // The entries follow the row while the menu is open.
    s.deliver([dialog(2, { pinned: true })])
    expect(entries()[0]).toMatchObject({ label: "Unpin" })
  })

  it("gives each row its chat's compose activity, so typing in one chat notifies one row", () => {
    const s = setup()
    const { rows, dialogs } = seed(5)
    s.deliver(rows, dialogs)
    const typing = new Map([2, 3].map((n) => [cid(n), signal<{ status?: { kind: "typing"; text: string } } | undefined>(undefined)]))
    s.controller.setCallbacks({ typingFor: (item) => typing.get(item.chatId) })
    const seen = { two: 0, three: 0, four: 0 }
    const stops = [
      effect(() => void (s.controller.activityOf(keyOf(2)).get(), seen.two++)),
      effect(() => void (s.controller.activityOf(keyOf(3)).get(), seen.three++)),
      effect(() => void (s.controller.activityOf(keyOf(4)).get(), seen.four++)),
    ]
    const baseline = { ...seen }
    expect(s.controller.activityOf(keyOf(2)).peek()).toBeUndefined()

    typing.get(cid(2))!.set({ status: { kind: "typing", text: "Ada is typing" } })
    expect(s.controller.activityOf(keyOf(2)).peek()).toEqual({ kind: "typing", text: "Ada is typing" })
    expect(seen).toEqual({ ...baseline, two: baseline.two + 1 })

    // The same activity again (the 3 s refresh) and a change to the chat's row notify nothing.
    typing.get(cid(2))!.set({ status: { kind: "typing", text: "Ada is typing" } })
    s.deliver([dialog(2, { unreadCount: 4 })])
    expect(seen).toEqual({ ...baseline, two: baseline.two + 1 })

    typing.get(cid(2))!.set(undefined)
    expect(s.controller.activityOf(keyOf(2)).peek()).toBeUndefined()
    expect(seen).toEqual({ ...baseline, two: baseline.two + 2 })
    expect(s.controller.activityOf(undefined).peek()).toBeUndefined()
    for (const stop of stops) stop()
  })

  it("binds the handle while alive and lets go on dispose", () => {
    const s = setup()
    expect(s.handle.attached).toBe(true)
    s.controller.dispose()
    expect(s.handle.attached).toBe(false)
    expect(s.handle.focus()).toBe(false)
  })
})
