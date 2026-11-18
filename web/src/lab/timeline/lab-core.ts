/**
 * The timeline lab's stand-in for the core: a seeded history, a loaded window
 * over it, read state, and the controller's requests served on demand or
 * after a simulated network delay. It also holds the per-row "extras" the
 * lab's rows render (a late media box, a resizable spacer, streamed text),
 * each in its own signal, so changing one renders that row only.
 *
 * Framework-free; `main.tsx` renders it and `operations.ts` drives it.
 */

import type { MessageID } from "@inline/ids"
import { batch, signal, type ReadSignal, type Signal } from "@inline/reactive"
import {
  timelineItems,
  type ReadState,
  type TimelineController,
  type TimelineItem,
  type TimelineWindow,
  type UnreadInput,
  type WindowRequest,
} from "@inline/timeline"
import { generateHistory, LAB_SENDERS, LAB_VIEWER, labMessage, type LabMessage } from "./generate"

/** Rows of a window opened at latest, and of each page served for "older" or "newer". */
export const OPEN_ROWS = 120
export const PAGE_ROWS = 40
/** Rows on each side of a message a window is opened around (Mac `ChatUnreadOpening.windowLimit` / 2). */
export const AROUND_ROWS = 44

export type RowExtras = {
  /** Height of a spacer at the end of the row, px (the "resize a row" operation). */
  extra: number
  /** A media box; `height` is 0 while a late box has not resolved. */
  media: { height: number; finalHeight: number; late: boolean } | null
  /** Text streamed onto the row. */
  stream: string
}

export type LabCoreOptions = {
  seed: number
  /** Messages generated; the ones past `liveEnd` are appended by the lab. */
  total: number
  /** Messages that exist at start. */
  liveEnd: number
  controller: TimelineController
  /** Simulated network delay for requests served automatically, ms. */
  serveDelayMs: number
  delay: (ms: number) => Promise<void>
}

export type LabCore = ReturnType<typeof createLabCore>

const describeRequest = (request: WindowRequest) => (typeof request === "string" ? request : `around ${request.around}`)

export const createLabCore = (options: LabCoreOptions) => {
  const { controller } = options
  const history: LabMessage[] = generateHistory(options.seed, options.total)
  const indexByRowId = new Map<string, number>()
  history.forEach((message, index) => indexByRowId.set(message.row.id, index))

  let liveEnd = Math.min(options.liveEnd, history.length)
  /** The loaded window: messages `lo` to `hi - 1`. */
  let lo = Math.max(0, liveEnd - OPEN_ROWS)
  let hi = liveEnd
  let loading: TimelineWindow["loading"] = "none"
  let unread: UnreadInput | undefined
  let items: TimelineItem[] = []
  let readMaxId: MessageID | undefined
  let autoServe = true
  const pending: WindowRequest[] = []
  const requestLog = signal<readonly string[]>([])

  const currentWindow = (): TimelineWindow => ({
    hasOlder: lo > 0,
    hasNewer: hi < liveEnd,
    atLatest: hi >= liveEnd,
    loading,
  })
  const windowSignal = signal<TimelineWindow>(currentWindow())

  // ---------------------------------------------------------------------------
  // Items

  const build = () => {
    const rows = history.slice(lo, hi).map((message) => message.row)
    const result = timelineItems(
      {
        rows,
        viewerId: LAB_VIEWER,
        timeZone: "UTC",
        ...(unread ? { unread: { ...unread, reachesHistoryStart: lo === 0 } } : {}),
      },
      items,
    )
    if (unread && result.unreadLineAbove !== undefined) unread = { ...unread, lineAbove: result.unreadLineAbove }
    items = result.items
    return items
  }

  const apply = () => {
    batch(() => {
      const window = currentWindow()
      controller.setItems(build(), window)
      windowSignal.set(window)
    })
  }

  // ---------------------------------------------------------------------------
  // Read state (feature map rules 4 and 5)

  const unreadCount = () => {
    let count = 0
    const floor = readMaxId === undefined ? 0 : Number(readMaxId)
    for (let i = floor; i < liveEnd; i++) if (!history[i]!.row.out) count += 1
    return count
  }

  const pushReadState = () => {
    const state: ReadState = { unreadCount: unreadCount(), ...(readMaxId !== undefined ? { readMaxId } : {}) }
    controller.setReadState(state)
  }

  /** The controller's `markRead` callback: the "server" moves its read marker, and the dialog's state comes back after the call. */
  const markRead = (maxId: MessageID) => {
    if (readMaxId === undefined || Number(maxId) > Number(readMaxId)) readMaxId = maxId
    queueMicrotask(pushReadState)
  }

  // ---------------------------------------------------------------------------
  // Requests

  const serve = (request: WindowRequest) => {
    if (request === "older") lo = Math.max(0, lo - PAGE_ROWS)
    else if (request === "newer") hi = Math.min(liveEnd, hi + PAGE_ROWS)
    else if (request === "latest") {
      lo = Math.max(0, liveEnd - OPEN_ROWS)
      hi = liveEnd
    } else {
      const index = Number(request.around) - 1
      lo = Math.max(0, index - AROUND_ROWS)
      hi = Math.min(liveEnd, index + 1 + AROUND_ROWS * 2)
    }
    loading = "none"
    apply()
  }

  const loadingFor = (request: WindowRequest): TimelineWindow["loading"] =>
    request === "older" ? "older" : request === "newer" ? "newer" : "initial"

  /**
   * The controller's `request` callback. Like the real core (an `ensure`
   * command to a worker), it answers later, never inside the controller's call.
   */
  const onRequest = (request: WindowRequest) => {
    requestLog.update((log) => [...log.slice(-19), describeRequest(request)])
    if (!autoServe) {
      pending.push(request)
      return
    }
    queueMicrotask(() => {
      loading = loadingFor(request)
      apply()
    })
    void options.delay(options.serveDelayMs).then(() => serve(request))
  }

  /** Serve the oldest pending request (operations run with automatic serving off). */
  const servePending = (match?: (request: WindowRequest) => boolean): WindowRequest | undefined => {
    const index = match ? pending.findIndex(match) : 0
    if (index < 0 || index >= pending.length) return undefined
    const [request] = pending.splice(index, 1)
    serve(request!)
    return request
  }

  // ---------------------------------------------------------------------------
  // Opening

  const resetWindow = (from: number, to: number) => {
    lo = Math.max(0, from)
    hi = Math.min(liveEnd, to)
    loading = "none"
    pending.length = 0
  }

  const openLatest = (rows = OPEN_ROWS) => {
    unread = undefined
    readMaxId = history[liveEnd - 1]?.row.messageId
    resetWindow(liveEnd - rows, liveEnd)
    const window = currentWindow()
    controller.open({ target: { kind: "latest" }, items: build(), window })
    windowSignal.set(window)
    pushReadState()
  }

  /**
   * Open with the read marker `behind` messages before the live end. Cached:
   * the window around the marker is loaded. Not cached: only the newest rows
   * are, and the controller asks for the rest.
   */
  const openUnread = (behind: number, cached: boolean) => {
    const marker = Math.max(1, liveEnd - behind)
    const boundary = history[marker - 1]!.row.messageId!
    unread = { boundary }
    readMaxId = boundary
    if (cached) resetWindow(marker - AROUND_ROWS, marker + AROUND_ROWS * 2)
    else resetWindow(liveEnd - OPEN_ROWS, liveEnd)
    const window = currentWindow()
    controller.open({ target: { kind: "unread", boundary }, items: build(), window })
    windowSignal.set(window)
    pushReadState()
    return boundary
  }

  // ---------------------------------------------------------------------------
  // Changes

  /** Older rows arrive at the head of the window. Returns how many. */
  const prepend = (count: number) => {
    const before = lo
    lo = Math.max(0, lo - count)
    apply()
    return before - lo
  }

  /**
   * A new incoming message at the live end, from someone other than the last
   * sender and 400 s later, so it starts its own group and leaves its
   * neighbour's item unchanged (an append renders the new row only).
   */
  const append = (text?: string) => {
    if (liveEnd >= history.length) throw new Error("The lab's history is used up; reload the page.")
    const previous = history[liveEnd - 1]!.row
    const sender = LAB_SENDERS.find((id) => id !== LAB_VIEWER && id !== previous.fromId)!
    const n = liveEnd + 1
    const generated = history[liveEnd]!
    const row = labMessage(n, sender, previous.date + 400, text ?? generated.row.text)
    history[liveEnd] = { row }
    const atLatest = hi >= liveEnd
    liveEnd += 1
    if (atLatest) hi = liveEnd
    apply()
    pushReadState()
    return `m:${row.id}`
  }

  // ---------------------------------------------------------------------------
  // Extras

  const extrasSignals = new Map<string, Signal<RowExtras>>()

  const initialExtras = (rowId: string): RowExtras => {
    const index = indexByRowId.get(rowId)
    const media = index === undefined ? undefined : history[index]?.media
    return {
      extra: 0,
      media: media ? { height: media.late ? 0 : media.height, finalHeight: media.height, late: media.late } : null,
      stream: "",
    }
  }

  const extrasSignal = (rowId: string) => {
    let cached = extrasSignals.get(rowId)
    if (!cached) {
      cached = signal(initialExtras(rowId))
      extrasSignals.set(rowId, cached)
    }
    return cached
  }

  const updateExtras = (rowId: string, fn: (current: RowExtras) => RowExtras) => extrasSignal(rowId).update(fn)

  return {
    history,
    window: windowSignal as ReadSignal<TimelineWindow>,
    requestLog: requestLog as ReadSignal<readonly string[]>,
    extras: (rowId: string): ReadSignal<RowExtras> => extrasSignal(rowId),
    updateExtras,
    /** Back to the generated state, for a fresh run. */
    resetExtras: () => {
      for (const [rowId, extras] of extrasSignals) extras.set(initialExtras(rowId))
    },
    onRequest,
    markRead,
    servePending,
    pending: () => [...pending],
    setAutoServe: (value: boolean) => {
      autoServe = value
    },
    openLatest,
    openUnread,
    prepend,
    append,
    /** The loaded window, as message indices. */
    bounds: () => ({ lo, hi, liveEnd }),
    rowIdOfKey: (key: string) => (key.startsWith("m:") ? key.slice(2) : undefined),
    messageOfKey: (key: string): LabMessage | undefined => {
      const index = key.startsWith("m:") ? indexByRowId.get(key.slice(2)) : undefined
      return index === undefined ? undefined : history[index]
    },
  }
}
