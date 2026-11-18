/**
 * The surface's per-row signals, flash timing and edges, DOM-free: the real
 * controller over the timeline package's fake host (virtual time and frames).
 * The DOM parts (`root`, `container`) are exercised by the lab in a browser.
 */
import { receivedMessageRowId, type MessageRow } from "@inline/core-protocol"
import { chatId, messageId, userId } from "@inline/ids"
import { effect, signal } from "@inline/reactive"
import {
  createTimelineController,
  timelineItems,
  type Highlight,
  type TimelineController,
  type TimelineItem,
  type TimelineWindow,
} from "@inline/timeline"
import { createFakeHost } from "@inline/timeline/testing"
import { describe, expect, it } from "vitest"
import { createTimelineSurface, FLASH_MS } from "./surface"

const CHAT = chatId(7)
const ME = userId(1)
const NOON = Date.UTC(2026, 10, 17, 12, 0, 0) / 1000
const LIVE: TimelineWindow = { hasOlder: true, hasNewer: false, atLatest: true, loading: "none" }

const row = (id: number, text = `message ${id}`): MessageRow => ({
  kind: "message",
  id: receivedMessageRowId(CHAT, messageId(id)),
  chatId: CHAT,
  messageId: messageId(id),
  fromId: userId(id % 2 === 0 ? 2 : 3),
  out: false,
  date: NOON + id * 600,
  text,
  state: "sent",
})

const setup = (count = 40) => {
  const fake = createFakeHost({ viewportHeight: 600, devicePixelRatio: 1 })
  const controller = createTimelineController({ viewerId: ME, clock: fake.clock, frames: fake.frames })
  const window = signal<TimelineWindow>(LIVE)
  const surface = createTimelineSurface({ controller, window, clock: fake.clock })
  controller.attach(fake.host)
  let rows = Array.from({ length: count }, (_, i) => row(i + 1))
  let items: TimelineItem[] = []
  const build = () => {
    items = timelineItems({ rows, viewerId: ME, timeZone: "UTC" }, items).items
    return items
  }
  /** Plays the view: commit the rendered items into the fake host. */
  const commit = () => fake.setRows(controller.rendered.peek().map((item) => ({ key: item.key, height: 50 })))
  controller.open({ target: { kind: "latest" }, items: build(), window: LIVE })
  commit()
  /** Run frames to the landing, committing after each, as the view renders after each signal change. */
  const land = () => {
    commit()
    for (let i = 0; i < 200 && (controller.mode.peek() === "target" || controller.debug().animating); i++) {
      fake.advance(16)
      fake.frame()
      commit()
    }
  }
  return {
    fake,
    controller,
    surface,
    window,
    commit,
    land,
    setRows: (next: MessageRow[], win: TimelineWindow = LIVE) => {
      rows = next
      controller.setItems(build(), win)
      window.set(win)
      commit()
    },
    get rows() {
      return rows
    },
  }
}

/** Count notifications of a signal (the first run is the subscription). */
const watch = (read: () => unknown) => {
  let runs = -1
  const stop = effect(() => {
    read()
    runs += 1
  })
  return { runs: () => runs, stop }
}

describe("per-row signals", () => {
  it("a content change to one row notifies that row only; the key list keeps its identity", () => {
    const t = setup()
    const keys = t.surface.keys.peek()
    const target = keys[keys.length - 5]!
    const other = keys[keys.length - 6]!
    const list = watch(() => t.surface.keys.get())
    const changed = watch(() => t.surface.item(target).get())
    const unchanged = watch(() => t.surface.item(other).get())
    const id = Number(target.split(":").pop())
    t.setRows(t.rows.map((r) => (Number(r.messageId) === id ? { ...r, text: "edited" } : r)))
    expect(list.runs()).toBe(0)
    expect(t.surface.keys.peek()).toBe(keys)
    expect(changed.runs()).toBe(1)
    expect(unchanged.runs()).toBe(0)
    const item = t.surface.item(target).peek()
    expect(item?.kind === "message" && item.row.text).toBe("edited")
  })

  it("appending changes the key list and notifies no existing row", () => {
    const t = setup()
    const keys = t.surface.keys.peek()
    const rows = keys.slice(-10).map((key) => watch(() => t.surface.item(key).get()))
    const list = watch(() => t.surface.keys.get())
    t.setRows([...t.rows, row(41)])
    expect(list.runs()).toBe(1)
    expect(t.surface.keys.peek().length).toBeGreaterThan(keys.length)
    expect(rows.map((r) => r.runs())).toEqual(rows.map(() => 0))
  })

  it("returns the same signal for a key, and keeps the last item for a row leaving the range", () => {
    const t = setup()
    const first = t.surface.keys.peek().find((key) => key.startsWith("m:"))!
    const signalA = t.surface.item(first)
    expect(t.surface.item(first)).toBe(signalA)
    const before = signalA.peek()
    t.setRows(t.rows.slice(5))
    expect(t.surface.keys.peek()).not.toContain(first)
    expect(signalA.peek()).toBe(before)
  })
})

describe("flash", () => {
  it("flashes the target row for FLASH_MS, then clears so a remount does not replay it", () => {
    const t = setup(80)
    const target = t.surface.keys.peek().filter((key) => key.startsWith("m:"))[10]!
    const id = messageId(Number(target.split(":").pop()))
    const flash = t.surface.flash(target)
    const neighbour = t.surface.flash(t.surface.keys.peek().filter((key) => key.startsWith("m:"))[11]!)
    t.controller.jumpToMessage(id)
    // Run the jump's animation frames to the landing.
    for (let i = 0; i < 120 && t.controller.mode.peek() === "target"; i++) {
      t.fake.advance(16)
      t.fake.frame()
    }
    expect(t.controller.mode.peek()).not.toBe("target")
    expect(flash.peek()).toBeGreaterThan(0)
    expect(neighbour.peek()).toBe(0)
    t.fake.advance(FLASH_MS)
    expect(flash.peek()).toBe(0)
    expect(t.controller.highlight.peek()?.key).toBe(target)
  })
})

describe("flash on far jumps", () => {
  const messageKeys = (t: ReturnType<typeof setup>) => t.surface.keys.peek().filter((key) => key.startsWith("m:"))
  const idOf = (key: string) => messageId(Number(key.split(":").pop()))

  it("flashes the target of a two-phase jump within the rendered rows", () => {
    const t = setup(80)
    const target = messageKeys(t)[1]!
    const flash = t.surface.flash(target)
    t.controller.jumpToMessage(idOf(target))
    t.land()
    expect(t.controller.mode.peek()).not.toBe("target")
    expect(t.surface.keys.peek()).toContain(target)
    expect(flash.peek()).toBeGreaterThan(0)
  })

  it("flashes the target of a jump to a loaded row outside the rendered range", () => {
    const t = setup(300)
    const firstRendered = Number(messageKeys(t)[0]!.split(":").pop())
    const targetId = firstRendered - 120
    const target = `m:${receivedMessageRowId(CHAT, messageId(targetId))}`
    expect(t.surface.keys.peek()).not.toContain(target)
    const flash = t.surface.flash(target)
    t.controller.jumpToMessage(messageId(targetId))
    t.land()
    expect(t.controller.mode.peek()).not.toBe("target")
    expect(t.controller.highlight.peek()?.key).toBe(target)
    expect(t.surface.keys.peek()).toContain(target)
    expect(flash.peek()).toBeGreaterThan(0)
  })

  it("holds a highlight for a row that is not rendered yet, and times it from when the row renders", () => {
    // A stand-in controller, to fire the highlight before the row is in `rendered` (the real one never does).
    const fake = createFakeHost()
    const items = timelineItems({ rows: Array.from({ length: 20 }, (_, i) => row(i + 1)), viewerId: ME, timeZone: "UTC" }).items
    const rendered = signal<readonly TimelineItem[]>(items.slice(0, 10))
    const highlight = signal<Highlight | null>(null)
    const controller = {
      rendered,
      highlight,
      items: signal(items),
      range: signal({ start: 0, end: 10 }),
      hidden: signal(false),
    } as unknown as TimelineController
    const surface = createTimelineSurface({ controller, clock: fake.clock })
    const target = items[15]!.key
    const flash = surface.flash(target)
    highlight.set({ key: target, seq: 1 })
    fake.advance(FLASH_MS * 2)
    expect(flash.peek()).toBe(0)
    rendered.set(items.slice(5, 20))
    expect(flash.peek()).toBe(1)
    // The fake clock advances in whole frames, so stay a few frames clear of the edge.
    fake.advance(FLASH_MS - 50)
    expect(flash.peek()).toBe(1)
    fake.advance(100)
    expect(flash.peek()).toBe(0)
    // A later range change does not replay it.
    rendered.set(items.slice(0, 20))
    expect(flash.peek()).toBe(0)
    surface.dispose()
  })
})

describe("edges and empty state", () => {
  it("follow the window signal and the rendered range", () => {
    const t = setup()
    expect(t.surface.olderEdge.peek()).toBe("more")
    expect(t.surface.newerEdge.peek()).toBe("none")
    t.setRows(t.rows, { ...LIVE, loading: "older" })
    expect(t.surface.olderEdge.peek()).toBe("loading")
    t.setRows(t.rows, { ...LIVE, hasOlder: false })
    expect(t.surface.olderEdge.peek()).toBe("start")
    expect(t.surface.empty.peek()).toBe(false)
    t.setRows([], { ...LIVE, hasOlder: false })
    expect(t.surface.empty.peek()).toBe(true)
  })
})
