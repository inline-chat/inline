/**
 * The timeline controller: the one owner of the message list's scroll
 * position. Framework-free; it reads DOM facts and issues commands through a
 * `TimelineHost` and exposes its state as signals. See the README for the
 * model and `web/docs/timeline-and-composer.md` for the rules. The behavioral
 * reference is `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`.
 */

import type { MessageID, UserID } from "@inline/ids"
import { batch, computed, signal, type ReadSignal } from "@inline/reactive"
import {
  MIN_CORRECTION_PX,
  OFFSET_ROUNDING_TOLERANCE_PX,
  SCROLL_IDLE_MS,
  UNREAD_SPINNER_DELAY_MS,
  UNREAD_WINDOW_SIDE_ROWS,
} from "./constants"
import { indexKeys, resizeDelta, structuralDelta, survivingAnchor, type SizeCache } from "./compensation"
import type { Activity, Clock, FrameSource, HostEvent, ItemKey, RowSize, TimelineHost } from "./host"
import { UNREAD_LINE_KEY, type MessageItem, type TimelineItem } from "./items"
import {
  atExactBottom,
  centeredOffset,
  clamp,
  compareMessageIds,
  decideRead,
  distanceFromBottom,
  heldOffset,
  initialWindowSize,
  isIncoming,
  jumpToLatestCount,
  landingOffset,
  planEdges,
  planJump,
  planLanding,
  planTrim,
  withinFollowZone,
  type JumpPhase,
  type Range,
  type ReadDecision,
  type WindowRequest,
} from "./policy"

export type TimelineMode =
  /** At the bottom; new rows keep it at the bottom. */
  | "following"
  /** Somewhere in history; nothing moves what the reader sees. */
  | "reading"
  /** A jump to a message or to latest is in progress. */
  | "target"
  /** Opening at a saved place or the unread line; the row is held until the user moves. */
  | "restoring"

/** What the controller needs to know about the core's window. `WindowResource` fits. */
export type TimelineWindow = {
  hasOlder: boolean
  hasNewer: boolean
  /** The window's end is the live end of the chat. */
  atLatest: boolean
  loading: "none" | "initial" | "older" | "newer"
  /**
   * History is certified contiguous from the read marker up to this message.
   * TODO(contract): `WindowResource` does not carry it yet. Without it the
   * controller assumes the window is contiguous through its newest message
   * when it reaches the read marker or the start of history (core.md: while
   * connected a window shows only contiguous certified history).
   */
  contiguousThrough?: MessageID
}

/** A reading place: a message and its top's distance below the uncovered top of the viewport. */
export type SavedPlace = { messageId: MessageID; offset: number }

export type OpenTarget =
  | { kind: "latest" }
  /** Open with the unread line at the top. `boundary` is the read marker captured at open. */
  | { kind: "unread"; boundary: MessageID }
  /** Reopen at a saved place. */
  | { kind: "place"; place: SavedPlace }
  /** Open centered on a message (a link). */
  | { kind: "message"; messageId: MessageID; highlight?: boolean }

export type ReadState = {
  /** The dialog's unread count, which the server owns. */
  unreadCount: number
  /** The dialog's read marker. */
  readMaxId?: MessageID
}

export type LatestButton = { visible: boolean; count: number }

export type Highlight = { key: ItemKey; seq: number }

export type TimelineControllerOptions = {
  viewerId: UserID
  clock: Clock
  frames: FrameSource
  /** Forward as `{ kind: "ensure", sub, range }`. The core treats repeats as no-ops. */
  request?: (range: WindowRequest) => void
  /** Forward as a `markRead` intent with `maxId`. Retries and their backoff are the core's. */
  markRead?: (decision: Exclude<ReadDecision, { kind: "none" }>) => void
  /** Persist per chat; null clears it. */
  savePlace?: (place: SavedPlace | null) => void
}

export interface TimelineController {
  readonly mode: ReadSignal<TimelineMode>
  /** All loaded items, as last given. */
  readonly items: ReadSignal<readonly TimelineItem[]>
  /** The part of the items the controller wants rendered, as indices. */
  readonly range: ReadSignal<Range>
  /** `items` sliced by `range`: what the view renders, keyed by `item.key`. */
  readonly rendered: ReadSignal<readonly TimelineItem[]>
  /** "Jump to latest": shown when not following latest, with the count of unread below. */
  readonly latestButton: ReadSignal<LatestButton>
  /** Keep the list invisible (opening at uncached unread history). */
  readonly hidden: ReadSignal<boolean>
  /** Show a spinner over the hidden list. */
  readonly spinner: ReadSignal<boolean>
  /** Flash this row; `seq` changes on every flash. */
  readonly highlight: ReadSignal<Highlight | null>

  attach(host: TimelineHost): void
  detach(): void
  open(input: { target: OpenTarget; items: readonly TimelineItem[]; window: TimelineWindow }): void
  setItems(items: readonly TimelineItem[], window: TimelineWindow): void
  setReadState(state: ReadState): void
  jumpToMessage(messageId: MessageID, options?: { highlight?: boolean }): void
  jumpToLatest(): void
  /** The user sent a message from this chat's composer. */
  userSent(): void
  /** The connection to the server was lost. */
  connectionLost(): void
  /** The chat is being left: capture its reading place. */
  leave(): void
  dispose(): void
  /** Internal state, for tests and the developer overlay. */
  debug(): TimelineDebug
}

export type TimelineDebug = {
  anchors: readonly { key: ItemKey; offset: number }[]
  pinned: boolean
  scrolledAway: boolean
  userScrolling: boolean
  hold: { key: ItemKey; offset: number } | null
  placement: Placement["kind"] | null
  jump: "load" | "land" | null
  animating: boolean
  readFrontier: MessageID | undefined
  /** The offset the controller intends, the offset it last saw, and the sub-pixel phase it keeps. */
  offsets: { intended: number; last: number; phase: number }
}

type Placement =
  | { kind: "latest" }
  | { kind: "hold"; key: ItemKey; offset: number }
  | { kind: "center"; key: ItemKey; highlight: boolean }
  /** Hidden while history around the unread line loads. */
  | { kind: "unreadWait" }

type Goal = { kind: "latest" } | { kind: "message"; key: ItemKey; highlight: boolean }

type PendingJump = {
  stage: "load" | "land"
  goal: Goal
  /** For a message not loaded yet. */
  messageId?: MessageID
  highlight: boolean
  travel: "up" | "down"
  sawLoading: boolean
  headKey: ItemKey | undefined
}

type Animation = {
  goal: Goal
  phase: JumpPhase
  rest: JumpPhase[]
  finalTo: number
  startedAt: number
  cancel: () => void
}

type UnreadFetch = {
  boundary: MessageID
  sawLoading: boolean
  headKey: ItemKey | undefined
  cancelSpinner: () => void
}

const detachedHost: TimelineHost = {
  viewportHeight: () => 0,
  contentHeight: () => 0,
  scrollOffset: () => 0,
  insets: () => ({ top: 0, bottom: 0 }),
  rowKeys: () => [],
  rowRect: () => undefined,
  visibleKeys: () => [],
  activity: () => ({ visible: false, active: false }),
  setScrollOffset: () => {},
  animateScroll: () => () => {},
  subscribe: () => () => {},
}

const isMessageKey = (key: ItemKey) => key.startsWith("m:")
const sameRange = (a: Range, b: Range) => a.start === b.start && a.end === b.end
const sameButton = (a: LatestButton, b: LatestButton) => a.visible === b.visible && a.count === b.count

export const createTimelineController = (options: TimelineControllerOptions): TimelineController => {
  const { clock, frames, viewerId } = options

  // -------------------------------------------------------------------------
  // Signals

  const mode = signal<TimelineMode>("following")
  const itemsSignal = signal<readonly TimelineItem[]>([])
  const range = signal<Range>({ start: 0, end: 0 }, { equals: sameRange })
  const latestButton = signal<LatestButton>({ visible: false, count: 0 }, { equals: sameButton })
  const hidden = signal(false)
  const spinner = signal(false)
  const highlight = signal<Highlight | null>(null)
  const rendered = computed(() => {
    const { start, end } = range.get()
    return itemsSignal.get().slice(start, end)
  })

  // -------------------------------------------------------------------------
  // State

  let host: TimelineHost = detachedHost
  let unsubscribe: (() => void) | undefined
  let disposed = false

  let items: readonly TimelineItem[] = []
  let indexByKey = new Map<ItemKey, number>()
  let keyByMessageId = new Map<string, ItemKey>()
  let oldestId: MessageID | undefined
  let newestId: MessageID | undefined
  let win: TimelineWindow = { hasOlder: false, hasNewer: false, atLatest: true, loading: "none" }
  let followsHead = true
  let followsTail = true

  /** The rendered order as the host last reported it, and the size of every rendered row. */
  let domKeys: ItemKey[] = []
  let domIndex = new Map<ItemKey, number>()
  const sizes: SizeCache = new Map()

  /** Visible message rows in reading order, rows starting inside the viewport first. */
  let anchors: { key: ItemKey; offset: number }[] = []
  /** The offset the controller intends; kept unrounded so rounding never accumulates. */
  let intended = 0
  /** The offset after the controller's last write or the last move it accepted. */
  let lastOffset = 0
  /** The sub-pixel remainder set by the last absolute write; corrections keep it. */
  let phase = 0
  /** The last write was absolute, so an engine snapping it later moves the phase too. */
  let phaseFollowsSnap = false
  /** The controller wrote the offset since the last scroll event. */
  let wroteSinceScroll = false
  let pinned = true
  let scrolledAway = false
  let userScrolling = false
  let inputHeld = false
  let cancelIdle: (() => void) | undefined

  let hold: { key: ItemKey; offset: number } | null = null
  let animation: Animation | null = null
  let jump: PendingJump | null = null
  let placement: Placement | null = null
  let unreadFetch: UnreadFetch | null = null
  let followNext = false
  let placeCaptureBlocked = false
  const inflight = { older: false, newer: false }
  let readFrontier: MessageID | undefined
  let readState: ReadState = { unreadCount: 0 }
  /** The read boundary captured when the chat opened at unread: a known read marker before `setReadState`. */
  let openBoundary: MessageID | undefined
  let activity: Activity = { visible: false, active: false }
  let highlightSeq = 0
  let lastPlace: SavedPlace | null | undefined
  let cancelReveal: (() => void) | undefined

  // -------------------------------------------------------------------------
  // Outbox: callbacks run after the controller's call has finished

  /**
   * A core may answer `request` (or a `markRead`, or a saved place)
   * synchronously, re-entering `setItems` in the middle of the call that
   * asked. Callbacks are queued while a call is running and delivered, in
   * order, when the outermost call finishes, so the controller's state is
   * complete when anything outside sees it.
   */
  let depth = 0
  const outbox: (() => void)[] = []
  const send = (fn: () => void) => {
    if (depth > 0) outbox.push(fn)
    else fn()
  }
  const guard =
    <A extends unknown[], R>(fn: (...args: A) => R) =>
    (...args: A): R => {
      depth++
      try {
        return fn(...args)
      } finally {
        depth--
        if (depth === 0) {
          for (let next = outbox.shift(); next; next = outbox.shift()) next()
        }
      }
    }

  // -------------------------------------------------------------------------
  // Geometry

  const geometry = () => {
    const viewportHeight = host.viewportHeight()
    const contentHeight = host.contentHeight()
    const offset = host.scrollOffset()
    return {
      viewportHeight,
      contentHeight,
      offset,
      max: Math.max(0, contentHeight - viewportHeight),
      distance: distanceFromBottom(offset, viewportHeight, contentHeight),
    }
  }

  const inZone = () => withinFollowZone(geometry().distance, scrolledAway)
  const renderedAtLatest = () => win.atLatest && range.peek().end === items.length
  const canFollow = () => !userScrolling && !animation && !hold
  const pageSize = () => initialWindowSize(host.viewportHeight())

  /**
   * Write an offset, clamped. Writes under half a pixel are skipped. The
   * engine may snap what is written (round, floor or ceil to device pixels,
   * at once or when it commits the scroll); `intended - lastOffset` is the
   * remainder it has not applied, which the next correction starts from.
   *
   * An `absolute` write (a placement, a landing, the bottom) sets the
   * sub-pixel phase: the remainder the reader sees from then on. A
   * correction aims at the offset that keeps that phase, not at the nearest
   * pixel, so every later remainder stays within half a device pixel of it
   * and a run of corrections never adds up to more than that, under any
   * rounding.
   */
  const writeOffset = (target: number, kind: "absolute" | "correction" = "absolute") => {
    const g = geometry()
    const next = clamp(target, 0, g.max)
    intended = next
    const aim = kind === "correction" ? clamp(next - phase, 0, g.max) : next
    if (Math.abs(aim - g.offset) >= MIN_CORRECTION_PX) {
      host.setScrollOffset(aim)
      // An engine that floors or ceils to whole pixels leaves up to a pixel
      // off; the nearest whole pixel is representable under any policy.
      const landed = host.scrollOffset()
      if (Math.abs(landed - aim) > MIN_CORRECTION_PX) {
        const nearest = Math.round(aim)
        if (Math.abs(nearest - aim) < Math.abs(landed - aim)) host.setScrollOffset(nearest)
      }
    }
    lastOffset = host.scrollOffset()
    wroteSinceScroll = true
    phaseFollowsSnap = kind === "absolute"
    if (kind === "absolute") phase = remainder()
  }

  /**
   * What the engine has not applied of the intended offset. A phase can be
   * almost a pixel (a placement clamped at a fractional maximum), and
   * corrections keep within half a pixel of it; anything larger is not
   * rounding and is dropped.
   */
  const remainder = () => {
    const rest = intended - lastOffset
    return Math.abs(rest) <= 2 * OFFSET_ROUNDING_TOLERANCE_PX ? rest : 0
  }

  /** Start fresh from where the host is, with no remainder. */
  const resetOffset = (offset: number) => {
    intended = lastOffset = offset
    phase = 0
    phaseFollowsSnap = false
  }

  /**
   * The offset corrections start from: what the controller intended, unless
   * something else moved it. Three differences are not moves: engine
   * rounding, snapping when the engine commits the scroll, and the clamp
   * layout applies when the list got shorter above a reader near the bottom
   * (the offset then sits at the new maximum, below the intended one; starting
   * from it would apply that shrink twice). A move not reported yet keeps the
   * remainder too.
   */
  const baseOffset = () => {
    const actual = host.scrollOffset()
    if (Math.abs(actual - lastOffset) <= OFFSET_ROUNDING_TOLERANCE_PX) return lastOffset + remainder()
    const max = Math.max(0, host.contentHeight() - host.viewportHeight())
    if (intended > actual && actual >= max - OFFSET_ROUNDING_TOLERANCE_PX) return intended
    return actual + remainder()
  }

  const applyDelta = (delta: number) => {
    if (delta === 0) return
    writeOffset(baseOffset() + delta, "correction")
  }

  const toBottom = () => {
    writeOffset(geometry().max)
    pinned = true
    scrolledAway = false
  }

  const captureAnchors = () => {
    const started: { key: ItemKey; offset: number }[] = []
    const cut: { key: ItemKey; offset: number }[] = []
    for (const key of host.visibleKeys()) {
      if (!isMessageKey(key)) continue
      const rect = host.rowRect(key)
      if (!rect) continue
      // A row cut by the top edge grows out of sight; prefer the first row starting on screen.
      ;(rect.top >= -MIN_CORRECTION_PX ? started : cut).push({ key, offset: rect.top })
    }
    anchors = started.concat(cut)
  }

  const anchorKeys = () => anchors.map((anchor) => anchor.key)

  // -------------------------------------------------------------------------
  // Items and range

  const reindex = (next: readonly TimelineItem[]) => {
    items = next
    indexByKey = new Map()
    keyByMessageId = new Map()
    oldestId = undefined
    newestId = undefined
    for (let i = 0; i < next.length; i++) {
      const item = next[i]!
      indexByKey.set(item.key, i)
      if (item.kind !== "message") continue
      const id = item.row.messageId
      if (id === undefined) continue
      keyByMessageId.set(id, item.key)
      if (oldestId === undefined || compareMessageIds(id, oldestId) < 0) oldestId = id
      if (newestId === undefined || compareMessageIds(id, newestId) > 0) newestId = id
    }
  }

  const firstMessageKey = (list: readonly TimelineItem[]) => list.find((item) => item.kind === "message")?.key
  const lastMessageKey = (list: readonly TimelineItem[]) => {
    for (let i = list.length - 1; i >= 0; i--) if (list[i]!.kind === "message") return list[i]!.key
    return undefined
  }

  /** A separator or the unread line belongs to the message below it. */
  const includeLeading = (start: number) => {
    let s = start
    while (s > 0 && items[s - 1]!.kind !== "message") s--
    return s
  }

  const aroundRange = (index: number, before: number, after: number): Range => ({
    start: includeLeading(clamp(index - before, 0, items.length)),
    end: clamp(index + after, 0, items.length),
  })

  const tailRange = (): Range => ({
    start: includeLeading(Math.max(0, items.length - pageSize())),
    end: items.length,
  })

  const setRange = (next: Range) => {
    const start = includeLeading(clamp(next.start, 0, items.length))
    const end = clamp(next.end, start, items.length)
    range.set({ start, end })
    followsHead = start === 0
    followsTail = end === items.length
  }

  /** Map the rendered range onto new items by the keys at its edges. */
  const carryRange = (previous: readonly TimelineItem[]): Range | null => {
    if (items.length === 0) return { start: 0, end: 0 }
    const current = range.peek()
    const locate = (from: number, step: 1 | -1): number | undefined => {
      for (let i = from; i >= 0 && i < previous.length; i += step) {
        const index = indexByKey.get(previous[i]!.key)
        if (index !== undefined) return index
      }
      return undefined
    }
    const start = followsHead ? 0 : locate(current.start, 1)
    const endIndex = followsTail ? items.length - 1 : locate(current.end - 1, -1)
    if (start === undefined || endIndex === undefined || endIndex < start) return null
    return { start, end: endIndex + 1 }
  }

  // -------------------------------------------------------------------------
  // Signals derived from state

  const contiguousThrough = (): MessageID | undefined => {
    if (win.contiguousThrough !== undefined) return win.contiguousThrough
    if (oldestId === undefined) return undefined
    const readMax = readState.readMaxId ?? openBoundary
    if (!win.hasOlder || (readMax !== undefined && compareMessageIds(oldestId, readMax) <= 0)) return newestId
    return undefined
  }

  let count = 0
  const recount = () => {
    const rows = []
    for (const item of items) if (item.kind === "message") rows.push(item.row)
    count = jumpToLatestCount({
      unreadCount: readState.unreadCount,
      ...(readState.readMaxId !== undefined ? { readMaxId: readState.readMaxId } : {}),
      ...(readFrontier !== undefined ? { readFrontier } : {}),
      ...(contiguousThrough() !== undefined ? { contiguousThrough: contiguousThrough()! } : {}),
      rows,
      viewerId,
    })
  }

  const refreshLatest = () => {
    const visible = !hidden.peek() && !(mode.peek() === "following" && renderedAtLatest())
    latestButton.set({ visible, count })
  }

  const setMode = (next: TimelineMode) => {
    const previous = mode.peek()
    mode.set(next)
    refreshLatest()
    if (previous !== "following" && next === "following" && !userScrolling) evaluateRead()
  }

  const settledMode = (): TimelineMode => (inZone() ? "following" : "reading")

  const flash = (key: ItemKey) => highlight.set({ key, seq: ++highlightSeq })

  // -------------------------------------------------------------------------
  // Read marking and saved place

  const highestVisibleIncoming = (): MessageID | undefined => {
    let best: MessageID | undefined
    for (const key of host.visibleKeys()) {
      const index = indexByKey.get(key)
      const item = index === undefined ? undefined : items[index]
      if (item?.kind !== "message") continue
      const id = item.row.messageId
      if (id === undefined || !isIncoming(item.row, viewerId)) continue
      if (best === undefined || compareMessageIds(id, best) > 0) best = id
    }
    return best
  }

  const frontier = (): MessageID | undefined => {
    const a = readFrontier
    const b = readState.readMaxId
    if (a === undefined) return b
    if (b === undefined) return a
    return compareMessageIds(a, b) >= 0 ? a : b
  }

  function evaluateRead() {
    if (!options.markRead || disposed) return
    const through = contiguousThrough()
    const visible = highestVisibleIncoming()
    const marker = frontier()
    const decision = decideRead({
      appActive: activity.active,
      windowVisible: activity.visible,
      placed: !placement && !hidden.peek() && !animation && !jump,
      withinFollowZone: inZone(),
      atLiveEnd: renderedAtLatest(),
      ...(newestId !== undefined ? { newestMessageId: newestId } : {}),
      ...(visible !== undefined ? { highestVisibleIncoming: visible } : {}),
      ...(through !== undefined ? { contiguousThrough: through } : {}),
      ...(marker !== undefined ? { readFrontier: marker } : {}),
    })
    if (decision.kind === "none") return
    readFrontier = decision.maxId
    send(() => options.markRead?.(decision))
    recount()
    refreshLatest()
  }

  const messageItemAt = (key: ItemKey): MessageItem | undefined => {
    const index = indexByKey.get(key)
    const item = index === undefined ? undefined : items[index]
    return item?.kind === "message" ? item : undefined
  }

  const newestOnScreen = (): boolean => {
    if (!renderedAtLatest()) return false
    const key = lastMessageKey(items)
    if (key === undefined) return true
    const rect = host.rowRect(key)
    if (!rect) return false
    return rect.top < host.viewportHeight() - host.insets().bottom
  }

  const topReadingPlace = (): SavedPlace | null => {
    const top = host.insets().top
    for (const key of host.visibleKeys()) {
      const item = messageItemAt(key)
      const id = item?.row.messageId
      if (id === undefined) continue
      const rect = host.rowRect(key)
      if (!rect || rect.bottom <= top) continue
      return { messageId: id, offset: rect.top - top }
    }
    return null
  }

  const emitPlace = (place: SavedPlace | null) => {
    const last = lastPlace
    if (last !== undefined) {
      if (last === null && place === null) return
      if (last && place && last.messageId === place.messageId && Math.abs(last.offset - place.offset) < MIN_CORRECTION_PX)
        return
    }
    lastPlace = place
    send(() => options.savePlace?.(place))
  }

  /** Mac `captureReadingPlace`: save where the reader is, or clear it when the newest message is on screen. */
  const captureSavedPlace = () => {
    if (placement || hidden.peek() || animation || jump || domKeys.length === 0) return
    if (newestOnScreen()) {
      placeCaptureBlocked = false
      emitPlace(null)
      return
    }
    if (placeCaptureBlocked) return
    const place = topReadingPlace()
    if (place) emitPlace(place)
  }

  // -------------------------------------------------------------------------
  // Window growth and trimming

  const checkEdges = () => {
    const g = geometry()
    const plan = planEdges({
      offset: g.offset,
      viewportHeight: g.viewportHeight,
      contentHeight: g.contentHeight,
      range: range.peek(),
      length: items.length,
      hasOlder: win.hasOlder,
      hasNewer: win.hasNewer,
      loadingOlder: inflight.older || win.loading === "older",
      loadingNewer: inflight.newer || win.loading === "newer",
      page: pageSize(),
    })
    if (plan.range) setRange(plan.range)
    for (const request of plan.requests) {
      inflight[request] = true
      send(() => options.request?.(request))
    }
  }

  const maybeTrim = () => {
    if (userScrolling || animation || jump || placement || hidden.peek()) return
    const current = range.peek()
    const visible = host.visibleKeys()
    const first = visible.length ? indexByKey.get(visible[0]!) : undefined
    const last = visible.length ? indexByKey.get(visible[visible.length - 1]!) : undefined
    const plan = planTrim({
      range: current,
      firstVisible: first ?? current.end - 1,
      lastVisible: last ?? current.end - 1,
      following: mode.peek() === "following" && pinned,
    })
    if (plan) setRange(plan)
  }

  // -------------------------------------------------------------------------
  // Placement, holds and jumps

  const reveal = () => {
    if (!hidden.peek() || cancelReveal) return
    // Fade in on the frame after placement, so the first frame shown is settled. Mac: `revealListAfterLayout`.
    cancelReveal = frames.request(guard(() => {
      cancelReveal = undefined
      if (disposed) return
      if (hold) maintainHold()
      batch(() => {
        hidden.set(false)
        spinner.set(false)
      })
      refreshLatest()
      evaluateRead()
    }))
  }

  const endUnreadFetch = () => {
    if (!unreadFetch) return
    unreadFetch.cancelSpinner()
    unreadFetch = null
    spinner.set(false)
  }

  const afterPlaced = () => {
    captureAnchors()
    endUnreadFetch()
    if (hidden.peek()) reveal()
    else evaluateRead()
    refreshLatest()
  }

  const domHas = (key: ItemKey | undefined) => key !== undefined && domIndex.has(key)

  const tryPlace = () => {
    const p = placement
    if (!p || p.kind === "unreadWait") return
    const g = geometry()
    const insets = host.insets()
    if (p.kind === "latest") {
      // Placed at the bottom of what is rendered; a newer window that arrives later stays pinned.
      const last = items[range.peek().end - 1]?.key
      if (last !== undefined && !domHas(last)) return
      placement = null
      toBottom()
      setMode("following")
      afterPlaced()
      return
    }
    const rect = host.rowRect(p.key)
    if (!rect || !domHas(p.key)) return
    placement = null
    if (p.kind === "center") {
      writeOffset(
        centeredOffset({
          offset: g.offset,
          rowTop: rect.top,
          rowBottom: rect.bottom,
          viewportHeight: g.viewportHeight,
          contentHeight: g.contentHeight,
          insetTop: insets.top,
          insetBottom: insets.bottom,
        }),
      )
      pinned = atExactBottom(geometry().distance)
      setMode(pinned && renderedAtLatest() ? "following" : "reading")
      if (p.highlight) flash(p.key)
      afterPlaced()
      return
    }
    const landing = landingOffset({
      offset: g.offset,
      rowTop: rect.top,
      viewportHeight: g.viewportHeight,
      contentHeight: g.contentHeight,
      insetTop: insets.top,
      hold: p.offset,
    })
    if (landing === null || (landing >= g.max - MIN_CORRECTION_PX && renderedAtLatest())) {
      // The rows from there down fit on screen: open at the bottom, holding nothing.
      toBottom()
      setMode("following")
    } else {
      hold = { key: p.key, offset: p.offset }
      pinned = false
      scrolledAway = true
      writeOffset(landing)
      setMode("restoring")
    }
    afterPlaced()
  }

  /** Mac `maintainReadingHoldIfNeeded`: keep the held row where it landed, clamped. */
  function maintainHold() {
    const current = hold
    if (!current) return
    const rect = host.rowRect(current.key)
    if (!rect) {
      hold = null
      setMode(settledMode())
      return
    }
    const g = geometry()
    const target = heldOffset({
      offset: g.offset,
      rowTop: rect.top,
      viewportHeight: g.viewportHeight,
      contentHeight: g.contentHeight,
      insetTop: host.insets().top,
      hold: current.offset,
    })
    // Measured from where the row is now, so it is exact; kept at the phase the hold landed with.
    // It also records a clamp the browser applied for this layout as the hold's own position.
    writeOffset(target, "correction")
  }

  const goalOffset = (goal: Goal): number | undefined => {
    const g = geometry()
    if (goal.kind === "latest") return g.max
    const rect = host.rowRect(goal.key)
    if (!rect) return undefined
    const insets = host.insets()
    return centeredOffset({
      offset: g.offset,
      rowTop: rect.top,
      rowBottom: rect.bottom,
      viewportHeight: g.viewportHeight,
      contentHeight: g.contentHeight,
      insetTop: insets.top,
      insetBottom: insets.bottom,
    })
  }

  const land = (goal: Goal) => {
    animation = null
    resetOffset(host.scrollOffset())
    scrolledAway = false
    if (goal.kind === "latest") {
      toBottom()
      setMode("following")
    } else {
      pinned = atExactBottom(geometry().distance)
      setMode(pinned && renderedAtLatest() ? "following" : "reading")
      if (goal.highlight) flash(goal.key)
    }
    captureAnchors()
    if (hidden.peek()) reveal()
    evaluateRead()
    refreshLatest()
  }

  const runPhases = (goal: Goal, phases: JumpPhase[], finalTo: number) => {
    const [phase, ...rest] = phases
    if (!phase) {
      land(goal)
      return
    }
    const startedAt = clock.now()
    const current: Animation = {
      goal,
      phase,
      rest,
      finalTo,
      startedAt,
      cancel: () => {},
    }
    animation = current
    current.cancel = host.animateScroll(phase.to, { duration: phase.duration, easing: phase.easing }, guard(() => {
      if (animation !== current) return
      animation = null
      resetOffset(host.scrollOffset())
      const next = current.rest[0]
      if (!next) {
        land(goal)
        return
      }
      // Aim the next phase at where the goal is now.
      const to = goalOffset(goal) ?? current.finalTo
      runPhases(goal, [{ ...next, to }, ...current.rest.slice(1)], to)
    }))
  }

  const animateTo = (goal: Goal) => {
    const to = goalOffset(goal)
    if (to === undefined) {
      setMode(settledMode())
      return
    }
    runPhases(goal, planJump(host.scrollOffset(), to, host.viewportHeight()), to)
  }

  /** Layout changed under a running jump: shift with the content and re-aim at the goal. */
  const retarget = (delta: number) => {
    const current = animation
    if (!current) return
    const finalTo = goalOffset(current.goal)
    if (delta === 0 && (finalTo === undefined || Math.abs(finalTo - current.finalTo) < MIN_CORRECTION_PX)) return
    current.cancel()
    animation = null
    if (delta !== 0) writeOffset(host.scrollOffset() + delta)
    const to = finalTo ?? current.finalTo + delta
    const phaseTo = current.rest.length === 0 ? to : current.phase.to + (to - current.finalTo)
    const remaining = Math.max(0, current.phase.duration - (clock.now() - current.startedAt))
    runPhases(current.goal, [{ ...current.phase, to: phaseTo, duration: remaining }, ...current.rest], to)
  }

  const tryLand = () => {
    const pending = jump
    if (!pending || pending.stage !== "land") return
    const goal = pending.goal
    if (goal.kind === "latest") {
      const last = items[items.length - 1]?.key
      if (last !== undefined && !domHas(last)) return
    } else if (!domHas(goal.key) || !host.rowRect(goal.key)) {
      return
    }
    const to = goalOffset(goal)
    if (to === undefined) return
    jump = null
    // The rows in between were never rendered: start half a viewport short and ease in.
    const { from, phase } = planLanding(to, host.viewportHeight(), pending.travel)
    writeOffset(from)
    runPhases(goal, [{ ...phase, to: goalOffset(goal) ?? to }], to)
  }

  const cancelMotion = () => {
    if (animation) {
      animation.cancel()
      animation = null
      resetOffset(host.scrollOffset())
    }
    jump = null
    hold = null
    followNext = false
    if (placement && placement.kind !== "unreadWait") placement = null
  }

  const travelTo = (messageId: MessageID): "up" | "down" => {
    for (const anchor of anchors) {
      const id = messageItemAt(anchor.key)?.row.messageId
      if (id !== undefined) return compareMessageIds(messageId, id) < 0 ? "up" : "down"
    }
    return "up"
  }

  const fallbackToLatest = () => {
    endUnreadFetch()
    cancelMotion()
    placement = { kind: "latest" }
    if (!win.atLatest) send(() => options.request?.("latest"))
    else setRange(tailRange())
    setMode("following")
    tryPlace()
  }

  // -------------------------------------------------------------------------
  // Reconciling after layout changes

  const reconcile = (delta: number) => {
    if (disposed) return
    if (placement) {
      tryPlace()
      return
    }
    if (jump?.stage === "land") {
      tryLand()
      return
    }
    if (hidden.peek()) return
    if (animation) {
      retarget(delta)
      return
    }
    if (hold) {
      maintainHold()
      return
    }
    if (mode.peek() === "following" && !userScrolling && (pinned || followNext)) {
      const arrived = followNext
      followNext = false
      toBottom()
      if (arrived) evaluateRead()
      return
    }
    // Anchors are not re-captured here: a layout change can still have
    // observer entries pending, and anchors read from that layout would
    // misjudge which rows are above. The keys stay valid; only the user,
    // a placement or a landing moves them.
    applyDelta(delta)
  }

  const onRows = (keys: readonly ItemKey[], measured: readonly RowSize[]) => {
    for (const { key, height } of measured) if (height > 0) sizes.set(key, height)
    const beforeKeys = domKeys
    const beforeIndex = domIndex
    domKeys = [...keys]
    domIndex = indexKeys(domKeys)
    const anchor = survivingAnchor(anchorKeys(), beforeIndex, domIndex)
    const delta = anchor ? structuralDelta(beforeKeys, beforeIndex, domKeys, domIndex, anchor, sizes) : 0
    for (const key of beforeKeys) if (!domIndex.has(key)) sizes.delete(key)
    // Deleted anchors fall away; the next surviving row is the reference from now on.
    anchors = anchors.filter((entry) => domIndex.has(entry.key))
    reconcile(delta)
  }

  const onResize = (rows: readonly RowSize[]) => {
    const anchor = survivingAnchor(anchorKeys(), domIndex)
    reconcile(resizeDelta(rows, domIndex, anchor, sizes))
  }

  // -------------------------------------------------------------------------
  // User input and scrolling

  const armIdle = () => {
    cancelIdle?.()
    cancelIdle = undefined
    if (inputHeld) return
    cancelIdle = clock.setTimeout(guard(endUserScroll), SCROLL_IDLE_MS)
  }

  /** The user wins: input cancels a jump or animation and releases a hold, in the same event. */
  const beginUserScroll = (held: boolean) => {
    userScrolling = true
    if (held) inputHeld = true
    const wasMoving = mode.peek() === "target" || mode.peek() === "restoring"
    cancelMotion()
    if (placement && !hidden.peek()) placement = null
    placeCaptureBlocked = false
    if (wasMoving && !hidden.peek()) setMode(settledMode())
    armIdle()
  }

  const onInput = (event: Extract<HostEvent, { kind: "input" }>) => {
    beginUserScroll(event.held === true)
    if (event.direction === "up") {
      // One upward input detaches at once, before its scroll arrives.
      scrolledAway = true
      pinned = false
      if (mode.peek() === "following") setMode("reading")
    }
    captureAnchors()
  }

  const acceptMove = (offset: number, byUser: boolean) => {
    const previous = lastOffset
    // The reader moved; the sub-pixel remainder of earlier corrections is
    // carried, so corrections on both sides of the move still add up exactly.
    const rest = remainder()
    lastOffset = offset
    intended = offset + rest
    const g = geometry()
    if (atExactBottom(g.distance)) scrolledAway = false
    else if (offset < previous) scrolledAway = true
    else if (offset > previous) scrolledAway = false
    pinned = atExactBottom(g.distance)
    hold = null
    const current = mode.peek()
    if (current === "following" || current === "reading" || current === "restoring") setMode(settledMode())
    captureAnchors()
    if (byUser) {
      checkEdges()
      armIdle()
    }
    refreshLatest()
  }

  const onScroll = () => {
    if (animation || hidden.peek()) return
    const offset = host.scrollOffset()
    const ours = Math.abs(offset - lastOffset) <= OFFSET_ROUNDING_TOLERANCE_PX
    // The scroll event of the controller's own write, even mid-gesture: an
    // engine that snaps the offset only when it commits the scroll changes
    // the remainder now, which is kept (taking it as a move would drop it).
    if (ours && (wroteSinceScroll || !userScrolling)) {
      wroteSinceScroll = false
      lastOffset = offset
      if (phaseFollowsSnap) phase = remainder()
      if (userScrolling) armIdle()
      return
    }
    wroteSinceScroll = false
    if (userScrolling) {
      acceptMove(offset, true)
      return
    }
    // Moved by something else: find in page, focus, or the browser clamping a shorter list.
    acceptMove(offset, false)
  }

  function endUserScroll() {
    cancelIdle?.()
    cancelIdle = undefined
    if (!userScrolling || disposed) return
    userScrolling = false
    inputHeld = false
    pinned = atExactBottom(geometry().distance)
    const current = mode.peek()
    if (current === "following" || current === "reading") setMode(settledMode())
    captureAnchors()
    captureSavedPlace()
    evaluateRead()
    maybeTrim()
    refreshLatest()
  }

  const onEvent = (event: HostEvent) => {
    if (disposed) return
    switch (event.kind) {
      case "input":
        onInput(event)
        return
      case "inputEnd":
        inputHeld = false
        if (userScrolling) armIdle()
        return
      case "scroll":
        onScroll()
        return
      case "scrollEnd":
        if (userScrolling && !inputHeld) endUserScroll()
        return
      case "rows":
        onRows(event.keys, event.measured)
        return
      case "resize":
        onResize(event.rows)
        return
      case "viewport":
        reconcile(0)
        return
      case "activity": {
        const wasReading = activity.visible && activity.active
        activity = { visible: event.visible, active: event.active }
        if (!wasReading && activity.visible && activity.active) evaluateRead()
        return
      }
    }
  }

  // -------------------------------------------------------------------------
  // Public API

  const attach = (next: TimelineHost) => {
    detach()
    host = next
    activity = next.activity()
    domKeys = next.rowKeys()
    domIndex = indexKeys(domKeys)
    sizes.clear()
    for (const key of domKeys) {
      const rect = next.rowRect(key)
      if (rect && rect.bottom - rect.top > 0) sizes.set(key, rect.bottom - rect.top)
    }
    resetOffset(next.scrollOffset())
    unsubscribe = next.subscribe(guard(onEvent))
    if (placement) {
      tryPlace()
      return
    }
    // Back on screen (a resident chat): put the reader where they were.
    if (hold) maintainHold()
    else if (mode.peek() === "following" && pinned) toBottom()
    else {
      const g = geometry()
      for (const anchor of anchors) {
        const rect = next.rowRect(anchor.key)
        if (!rect) continue
        const target = g.offset + rect.top - anchor.offset
        if (Math.abs(target - g.offset) >= MIN_CORRECTION_PX) writeOffset(target)
        break
      }
    }
    captureAnchors()
  }

  function detach() {
    if (host === detachedHost) return
    if (animation) {
      animation.cancel()
      animation = null
    }
    // Where the reader is, for when this chat is attached again.
    if (!placement && !hidden.peek()) captureAnchors()
    cancelIdle?.()
    cancelIdle = undefined
    userScrolling = false
    inputHeld = false
    unsubscribe?.()
    unsubscribe = undefined
    host = detachedHost
  }

  const open: TimelineController["open"] = ({ target, items: next, window }) => {
    batch(() => {
      cancelMotion()
      endUnreadFetch()
      cancelReveal?.()
      cancelReveal = undefined
      placement = null
      anchors = []
      followNext = false
      placeCaptureBlocked = false
      inflight.older = inflight.newer = false
      readFrontier = undefined
      openBoundary = target.kind === "unread" ? target.boundary : undefined
      lastPlace = undefined
      scrolledAway = false
      pinned = true
      highlight.set(null)
      hidden.set(false)
      spinner.set(false)
      reindex(next)
      win = window
      const page = pageSize()
      const indexOf = (messageId: MessageID) => {
        const key = keyByMessageId.get(messageId)
        return key === undefined ? undefined : { key, index: indexByKey.get(key)! }
      }

      if (target.kind === "unread") {
        const line = indexByKey.get(UNREAD_LINE_KEY)
        if (line !== undefined) {
          setRange(aroundRange(line, UNREAD_WINDOW_SIDE_ROWS, Math.max(UNREAD_WINDOW_SIDE_ROWS, page)))
          placement = { kind: "hold", key: UNREAD_LINE_KEY, offset: 0 }
          mode.set("restoring")
        } else if (win.atLatest && !win.hasOlder && win.loading === "none") {
          // Everything is loaded and nothing unread is shown: open at latest.
          setRange(tailRange())
          placement = { kind: "latest" }
          mode.set("following")
        } else {
          // Not cached: stay hidden while history around the line loads.
          setRange(tailRange())
          placement = { kind: "unreadWait" }
          mode.set("restoring")
          hidden.set(true)
          const fetch: UnreadFetch = {
            boundary: target.boundary,
            sawLoading: win.loading !== "none",
            headKey: firstMessageKey(items),
            cancelSpinner: () => {},
          }
          fetch.cancelSpinner = clock.setTimeout(() => {
            if (unreadFetch === fetch) spinner.set(true)
          }, UNREAD_SPINNER_DELAY_MS)
          unreadFetch = fetch
          const boundary = target.boundary
          send(() => options.request?.({ around: boundary }))
        }
      } else if (target.kind === "place") {
        const found = indexOf(target.place.messageId)
        if (found) {
          setRange(aroundRange(found.index, page, page))
          placement = { kind: "hold", key: found.key, offset: target.place.offset }
          mode.set("restoring")
        } else {
          setRange(tailRange())
          placement = { kind: "latest" }
          mode.set("following")
        }
      } else if (target.kind === "message") {
        const found = indexOf(target.messageId)
        if (found) {
          setRange(aroundRange(found.index, page, page))
          placement = { kind: "center", key: found.key, highlight: target.highlight ?? true }
          mode.set("target")
        } else {
          setRange(tailRange())
          placement = { kind: "latest" }
          mode.set("following")
        }
      } else {
        setRange(tailRange())
        placement = { kind: "latest" }
        mode.set("following")
      }

      itemsSignal.set(items)
      recount()
      refreshLatest()
    })
    if (target.kind === "message" && !keyByMessageId.has(target.messageId)) {
      // A targeted open never paints the live bottom first: hidden until the target lands.
      placement = null
      hidden.set(true)
      jumpToMessage(target.messageId, { highlight: target.highlight ?? true })
      return
    }
    // A resident chat whose rows are already rendered places now.
    tryPlace()
  }

  const handleUnreadFetchItems = () => {
    const fetch = unreadFetch
    if (!fetch) return
    if (win.loading !== "none") fetch.sawLoading = true
    const line = indexByKey.get(UNREAD_LINE_KEY)
    if (line !== undefined) {
      setRange(aroundRange(line, UNREAD_WINDOW_SIDE_ROWS, Math.max(UNREAD_WINDOW_SIDE_ROWS, pageSize())))
      placement = { kind: "hold", key: UNREAD_LINE_KEY, offset: 0 }
      return
    }
    const settled = win.loading === "none" && (fetch.sawLoading || firstMessageKey(items) !== fetch.headKey)
    if (settled) fallbackToLatest()
  }

  const handleJumpItems = () => {
    const pending = jump
    if (!pending || pending.stage !== "load") return
    if (win.loading !== "none") pending.sawLoading = true
    if (pending.goal.kind === "latest") {
      if (!win.atLatest) return
      setRange(tailRange())
      pending.stage = "land"
      return
    }
    const id = pending.messageId
    if (id === undefined) return
    const key = keyByMessageId.get(id)
    if (key !== undefined) {
      setRange(aroundRange(indexByKey.get(key)!, pageSize(), pageSize()))
      pending.goal = { kind: "message", key, highlight: pending.highlight }
      pending.stage = "land"
      return
    }
    const settled = win.loading === "none" && (pending.sawLoading || firstMessageKey(items) !== pending.headKey)
    if (!settled) return
    // The message is gone: land on the nearest message instead, without a highlight. Mac: `nearestDisplayedMessageID`.
    let nearest: ItemKey | undefined
    let nearestId: MessageID | undefined
    for (const item of items) {
      if (item.kind !== "message" || item.row.messageId === undefined) continue
      const candidate = item.row.messageId
      const after = compareMessageIds(candidate, id) > 0
      if (after) {
        if (nearestId === undefined || compareMessageIds(nearestId, id) < 0 || compareMessageIds(candidate, nearestId) < 0) {
          nearest = item.key
          nearestId = candidate
        }
      } else if (nearestId === undefined || (compareMessageIds(nearestId, id) < 0 && compareMessageIds(candidate, nearestId) > 0)) {
        nearest = item.key
        nearestId = candidate
      }
    }
    if (nearest === undefined) {
      jump = null
      if (hidden.peek()) {
        // Opened at a message that cannot be shown: show latest rather than nothing.
        placement = { kind: "latest" }
        setRange(tailRange())
        setMode("following")
      } else {
        setMode(settledMode())
      }
      return
    }
    setRange(aroundRange(indexByKey.get(nearest)!, pageSize(), pageSize()))
    pending.goal = { kind: "message", key: nearest, highlight: false }
    pending.stage = "land"
  }

  const updateInflight = (previous: readonly TimelineItem[], previousWindow: TimelineWindow) => {
    if (inflight.older) {
      const headChanged = firstMessageKey(previous) !== firstMessageKey(items)
      if (headChanged || !win.hasOlder || (previousWindow.loading === "older" && win.loading !== "older"))
        inflight.older = false
    }
    if (inflight.newer) {
      const tailChanged = lastMessageKey(previous) !== lastMessageKey(items)
      if (tailChanged || !win.hasNewer || (previousWindow.loading === "newer" && win.loading !== "newer"))
        inflight.newer = false
    }
  }

  const setItems: TimelineController["setItems"] = (next, window) => {
    if (disposed) return
    batch(() => {
      const previous = items
      const previousWindow = win
      // New rows at the live end follow when the reader is in the follow zone and free to follow.
      const oldLast = lastMessageKey(previous)
      const newLast = lastMessageKey(next)
      const appended = oldLast !== undefined && newLast !== oldLast && next.some((item) => item.key === oldLast)
      if (appended && followsTail && mode.peek() === "following" && canFollow() && inZone()) followNext = true

      reindex(next)
      win = window
      updateInflight(previous, previousWindow)
      const carried = carryRange(previous)
      setRange(carried ?? tailRange())
      handleUnreadFetchItems()
      handleJumpItems()
      itemsSignal.set(items)
      recount()
      refreshLatest()
    })
    if (placement) tryPlace()
    else if (jump?.stage === "land") tryLand()
    else maybeTrim()
  }

  function jumpToMessage(messageId: MessageID, jumpOptions: { highlight?: boolean } = {}) {
    if (disposed) return
    const highlightTarget = jumpOptions.highlight ?? true
    endUnreadFetch()
    const travel = travelTo(messageId)
    cancelMotion()
    placement = null
    placeCaptureBlocked = false
    setMode("target")
    const key = keyByMessageId.get(messageId)
    if (key !== undefined) {
      const index = indexByKey.get(key)!
      const current = range.peek()
      if (index >= current.start && index < current.end && domHas(key) && !hidden.peek()) {
        animateTo({ kind: "message", key, highlight: highlightTarget })
        return
      }
      setRange(aroundRange(index, pageSize(), pageSize()))
      jump = {
        stage: "land",
        goal: { kind: "message", key, highlight: highlightTarget },
        highlight: highlightTarget,
        travel,
        sawLoading: false,
        headKey: firstMessageKey(items),
      }
      tryLand()
      return
    }
    jump = {
      stage: "load",
      goal: { kind: "message", key: "", highlight: highlightTarget },
      messageId,
      highlight: highlightTarget,
      travel,
      sawLoading: false,
      headKey: firstMessageKey(items),
    }
    send(() => options.request?.({ around: messageId }))
  }

  const jumpToLatest = () => {
    if (disposed) return
    if (unreadFetch) {
      fallbackToLatest()
      return
    }
    cancelMotion()
    placement = null
    // Do not save the place being left while latest loads. Mac: `readingPlaceCaptureBlocked`.
    placeCaptureBlocked = true
    setMode("target")
    if (win.atLatest) {
      const last = items[items.length - 1]?.key
      if (range.peek().end === items.length && (last === undefined || domHas(last))) {
        animateTo({ kind: "latest" })
        return
      }
      setRange(tailRange())
      jump = {
        stage: "land",
        goal: { kind: "latest" },
        highlight: false,
        travel: "down",
        sawLoading: false,
        headKey: firstMessageKey(items),
      }
      tryLand()
      return
    }
    jump = {
      stage: "load",
      goal: { kind: "latest" },
      highlight: false,
      travel: "down",
      sawLoading: false,
      headKey: firstMessageKey(items),
    }
    send(() => options.request?.("latest"))
  }

  const controller: TimelineController = {
    mode,
    items: itemsSignal,
    range,
    rendered,
    latestButton,
    hidden,
    spinner,
    highlight,
    attach: guard(attach),
    detach: guard(detach),
    open: guard(open),
    setItems: guard(setItems),
    setReadState: guard((state: ReadState) => {
      readState = state
      recount()
      refreshLatest()
    }),
    jumpToMessage: guard(jumpToMessage),
    jumpToLatest: guard(jumpToLatest),
    userSent: guard(() => {
      if (unreadFetch) {
        fallbackToLatest()
        return
      }
      if (!(mode.peek() === "following" && renderedAtLatest())) jumpToLatest()
    }),
    connectionLost: guard(() => {
      if (unreadFetch) fallbackToLatest()
    }),
    leave: guard(() => captureSavedPlace()),
    dispose: guard(() => {
      if (disposed) return
      captureSavedPlace()
      cancelMotion()
      endUnreadFetch()
      cancelReveal?.()
      detach()
      disposed = true
    }),
    debug: () => ({
      anchors: anchors.map((anchor) => ({ ...anchor })),
      pinned,
      scrolledAway,
      userScrolling,
      hold: hold ? { ...hold } : null,
      placement: placement?.kind ?? null,
      jump: jump?.stage ?? null,
      animating: animation !== null,
      readFrontier,
      offsets: { intended, last: lastOffset, phase },
    }),
  }
  return controller
}
