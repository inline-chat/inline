/**
 * Test harness for the controller: plays the view's part by committing the
 * controller's rendered items into a fake host, after each action and at the
 * end of each frame, as a view would render after a signal change. Not
 * exported from the package.
 */

import type { MessageID } from "@inline/ids"
import type { MessageRow } from "@inline/core-protocol"
import { createTimelineController, type OpenTarget, type SavedPlace, type TimelineWindow } from "../controller"
import type { Insets, ItemKey } from "../host"
import { timelineItems, type TimelineItem } from "../items"
import type { ReadDecision, WindowRequest } from "../policy"
import { createFakeHost, type FakeHostOptions } from "./fake-host"
import { ME } from "./fixtures"

export const defaultHeight = (item: TimelineItem): number => {
  if (item.kind === "day") return 28
  if (item.kind === "unread") return 32
  // Fractional heights, so rounding and sub-pixel corrections are exercised.
  const n = Number(item.row.messageId ?? 0)
  return 48.25 + (n % 4) * 10.5
}

export type HarnessOptions = FakeHostOptions & {
  heightOf?: (item: TimelineItem) => number
  /** Answer a window request, synchronously if the test wants a core that does. */
  onRequest?: (range: WindowRequest) => void
}

export const LIVE: TimelineWindow = { hasOlder: true, hasNewer: false, atLatest: true, loading: "none" }

export const createHarness = (options: HarnessOptions = {}) => {
  const fake = createFakeHost({ viewportHeight: 600, devicePixelRatio: 1, ...options })
  const heights = new Map<ItemKey, number>()
  const heightOf = options.heightOf ?? defaultHeight
  const requests: WindowRequest[] = []
  const reads: Exclude<ReadDecision, { kind: "none" }>[] = []
  const places: (SavedPlace | null)[] = []
  const controller = createTimelineController({
    viewerId: ME,
    clock: fake.clock,
    frames: fake.frames,
    request: (range) => {
      requests.push(range)
      options.onRequest?.(range)
    },
    markRead: (decision) => reads.push(decision),
    savePlace: (place) => places.push(place),
  })
  controller.attach(fake.host)

  let rows: MessageRow[] = []
  let window: TimelineWindow = LIVE
  let unread: { boundary: MessageID; lineAbove?: MessageID; reachesHistoryStart?: boolean } | undefined
  let items: TimelineItem[] = []
  let committed: readonly TimelineItem[] | undefined

  const build = () => {
    const result = timelineItems(
      { rows, viewerId: ME, timeZone: "UTC", ...(unread ? { unread } : {}) },
      items,
    )
    if (unread && result.unreadLineAbove !== undefined) unread = { ...unread, lineAbove: result.unreadLineAbove }
    items = result.items
    return items
  }

  const heightFor = (item: TimelineItem) => heights.get(item.key) ?? heightOf(item)

  const commit = () => {
    const rendered = controller.rendered.peek()
    if (rendered === committed) return
    committed = rendered
    fake.setRows(rendered.map((item) => ({ key: item.key, height: heightFor(item) })))
  }

  const harness = {
    fake,
    controller,
    requests,
    reads,
    places,
    get items() {
      return items
    },
    get rows() {
      return rows
    },
    commit,
    /** Open a chat and commit its first frame. */
    open(target: OpenTarget, nextRows: MessageRow[], nextWindow: TimelineWindow = LIVE) {
      rows = nextRows
      window = nextWindow
      unread = target.kind === "unread" ? { boundary: target.boundary, reachesHistoryStart: !nextWindow.hasOlder } : undefined
      items = []
      controller.open({ target, items: build(), window })
      commit()
    },
    /** New rows from the core, then the view's commit. */
    update(nextRows: MessageRow[], nextWindow: TimelineWindow = window) {
      rows = nextRows
      window = nextWindow
      if (unread) unread = { ...unread, reachesHistoryStart: !nextWindow.hasOlder }
      controller.setItems(build(), window)
      commit()
    },
    /** Change a rendered row's height (the observer reports it next frame). */
    resize(key: ItemKey, height: number) {
      heights.set(key, height)
      fake.resizeRow(key, height)
    },
    setHeight(key: ItemKey, height: number) {
      heights.set(key, height)
    },
    frame() {
      fake.frame()
      commit()
    },
    advance(ms: number) {
      const until = fake.now() + ms
      while (fake.now() < until) harness.frame()
    },
    /** A user scroll, its scroll event, and the commit of anything it asked to render. */
    scroll(delta: number) {
      fake.userScroll(delta)
      harness.frame()
    },
    /** Scroll, then let scrolling go idle. */
    scrollAndSettle(delta: number) {
      harness.scroll(delta)
      harness.advance(200)
    },
    act(fn: () => void) {
      fn()
      commit()
    },
    top(key: ItemKey) {
      const top = fake.rowTop(key)
      if (top === undefined) throw new Error(`row ${key} is not rendered`)
      return top
    },
    distance() {
      return fake.contentHeight() - 600 - fake.offset()
    },
    max() {
      return Math.max(0, fake.contentHeight() - fake.host.viewportHeight())
    },
    /** The first message row starting inside the viewport: what the reader is reading. */
    reading(): ItemKey {
      for (const key of fake.host.visibleKeys()) {
        if (!key.startsWith("m:")) continue
        if ((fake.rowTop(key) ?? -1) >= 0) return key
      }
      throw new Error("no message row on screen")
    },
    setInsets(insets: Insets) {
      fake.setInsets(insets)
    },
  }
  return harness
}

export type Harness = ReturnType<typeof createHarness>
