/**
 * The reactive lab's model: 10,000 synthetic message rows behind the real
 * store client and scheduler, an in-page stand-in for the core, two loads,
 * and the measurements. Framework-free; main.tsx renders it.
 *
 * Measured per update: from the start of the frame-lane flush that applied
 * the patches to the end of React's commit (React flushes useSyncExternalStore
 * updates in a microtask queued during the flush, so a microtask queued after
 * the flush runs after it). Each one is recorded as a `reactive-lab:update`
 * performance measure.
 */

import type { Command, CoreEndpoint, CoreMessage, MessageRow, Patch, RowKey } from "@inline/core-protocol"
import { receivedMessageRowId, rowKey } from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import {
  browserScheduler,
  computed,
  createStoreClient,
  onDispose,
  sameKeys,
  signal,
  type FrameSource,
  type ReadSignal,
  type StoreClient,
  type SubscriptionHandle,
} from "@inline/reactive"
import type { RenderCounter } from "@inline/reactive/react/testing"

export const ROW_COUNT = 10_000
export const ROW_HEIGHT = 28
const OVERSCAN = 6
const CHAT = "1" as ChatID

export type LoadKind = "none" | "stream" | "spread"

export type UpdateSample = { ms: number; rows: number; lists: number }

export type LabStats = {
  updates: number
  lastMs: number
  meanMs: number
  p95Ms: number
  maxMs: number
  lastRows: number
  maxRows: number
  lastLists: number
  /** Longest gap between two animation frames in the last second. */
  longestFrameMs: number
}

const EMPTY_STATS: LabStats = {
  updates: 0,
  lastMs: 0,
  meanMs: 0,
  p95Ms: 0,
  maxMs: 0,
  lastRows: 0,
  maxRows: 0,
  lastLists: 0,
  longestFrameMs: 0,
}

const syntheticRow = (index: number, text: string): MessageRow => ({
  kind: "message",
  id: receivedMessageRowId(CHAT, String(index + 1) as MessageID),
  chatId: CHAT,
  messageId: String(index + 1) as MessageID,
  fromId: String((index % 7) + 1) as UserID,
  out: index % 5 === 0,
  date: 1_700_000_000 + index * 60,
  text,
  state: "sent",
})

/** A stand-in for the core: answers the first subscribe with every row, then sends what the loads produce. */
const labCore = () => {
  const listeners = new Set<(message: CoreMessage) => void>()
  let revision = 0
  let sub: number | undefined
  const rows = Array.from({ length: ROW_COUNT }, (_, i) => syntheticRow(i, `Row ${i + 1}`))
  const send = (parts: Omit<Patch, "base" | "revision" | "settled">) => {
    const patch: Patch = { base: revision, revision: revision + 1, settled: [], ...parts }
    revision = patch.revision
    for (const listener of listeners) listener({ kind: "patch", patch })
  }
  const endpoint: CoreEndpoint = {
    post: (command: Command) => {
      if (command.kind === "subscribe" && sub === undefined) {
        sub = command.sub
        const keys = rows.map((row) => rowKey(row.kind, row.id))
        // Delivered on a later task, as a worker's message would be.
        setTimeout(() => send({ rows: rows.map((row) => ({ op: "upsert", row })), lists: [{ sub: command.sub, op: "replace", keys }], resources: [] }), 0)
      }
    },
    subscribe: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    close: () => listeners.clear(),
  }
  const update = (index: number, text: string) => {
    const row = syntheticRow(index, text)
    rows[index] = row
    send({ rows: [{ op: "upsert", row }], lists: [], resources: [] })
  }
  return { endpoint, update, current: (index: number) => rows[index]! }
}

/** Visible range of a fixed-height list, driven by the scroll container. */
const windowController = (list: ReadSignal<readonly RowKey[]>) => {
  const scrollTop = signal(0)
  const height = signal(600)
  const range = computed(
    () => {
      const first = Math.max(0, Math.floor(scrollTop.get() / ROW_HEIGHT) - OVERSCAN)
      const count = Math.ceil(height.get() / ROW_HEIGHT) + OVERSCAN * 2
      return { first, last: first + count }
    },
    { equals: (a, b) => a.first === b.first && a.last === b.last },
  )
  const visible = computed(
    () => {
      const { first, last } = range.get()
      return list.get().slice(first, last)
    },
    { equals: sameKeys },
  )
  const offset = computed(() => range.get().first * ROW_HEIGHT)
  const attach = (element: HTMLElement) => {
    const onScroll = () => scrollTop.set(element.scrollTop)
    height.set(element.clientHeight)
    element.addEventListener("scroll", onScroll, { passive: true })
    const observer = new ResizeObserver(() => height.set(element.clientHeight))
    observer.observe(element)
    return () => {
      element.removeEventListener("scroll", onScroll)
      observer.disconnect()
    }
  }
  return { visible, offset, range, attach }
}

export type Lab = ReturnType<typeof createLab>

export const createLab = (counter: RenderCounter) => {
  const core = labCore()
  const samples: UpdateSample[] = []
  const stats = signal<LabStats>(EMPTY_STATS)
  const load = signal<LoadKind>("none")
  let frameGaps: { at: number; gap: number }[] = []

  // Measure every frame-lane flush, through to React's commit.
  const frames: FrameSource = {
    request: (fn) =>
      requestAnimationFrame(() => {
        const rows = counter.count("row")
        const lists = counter.count("list")
        const start = performance.now()
        fn()
        queueMicrotask(() => {
          const end = performance.now()
          performance.measure("reactive-lab:update", { start, end })
          samples.push({ ms: end - start, rows: counter.count("row") - rows, lists: counter.count("list") - lists })
          if (samples.length > 600) samples.splice(0, samples.length - 600)
        })
      }),
    cancel: (handle) => cancelAnimationFrame(handle as number),
  }
  const scheduler = browserScheduler({ frames })
  const client: StoreClient = createStoreClient({ endpoint: core.endpoint, scheduler })
  const subscription: SubscriptionHandle = client.subscribe({ kind: "chatWindow", chatId: CHAT, anchor: "latest" })
  const viewport = windowController(subscription.list)

  // Loads -----------------------------------------------------------------

  let timer: ReturnType<typeof setInterval> | undefined
  let tick = 0
  const stop = () => {
    if (timer !== undefined) clearInterval(timer)
    timer = undefined
    load.set("none")
  }
  const start = (kind: Exclude<LoadKind, "none">) => {
    stop()
    samples.length = 0
    load.set(kind)
    tick = 0
    timer = setInterval(() => {
      tick += 1
      const { first, last } = viewport.range.peek()
      if (kind === "stream") {
        // One row, 60 times a second: a streaming reply growing word by word.
        const index = Math.min(ROW_COUNT - 1, first + OVERSCAN + 2)
        const words = core.current(index).text.split(" ")
        const next = words.length > 40 ? `Row ${index + 1}` : `${words.join(" ")} w${tick}`
        core.update(index, next)
      } else {
        // 60 different rows a second, cycling through the visible window.
        const span = Math.max(1, last - first)
        const index = Math.min(ROW_COUNT - 1, first + (tick % span))
        core.update(index, `Row ${index + 1} · update ${tick}`)
      }
    }, 1000 / 60)
  }

  // Stats, refreshed four times a second outside the measured updates ------

  let lastFrame = performance.now()
  let rafId = 0
  const watchFrames = () => {
    const now = performance.now()
    frameGaps.push({ at: now, gap: now - lastFrame })
    lastFrame = now
    rafId = requestAnimationFrame(watchFrames)
  }
  rafId = requestAnimationFrame(watchFrames)

  const refresh = setInterval(() => {
    const now = performance.now()
    frameGaps = frameGaps.filter((entry) => now - entry.at < 1000)
    if (samples.length === 0) {
      stats.set({ ...EMPTY_STATS, longestFrameMs: Math.max(0, ...frameGaps.map((entry) => entry.gap)) })
      return
    }
    const sorted = samples.map((sample) => sample.ms).sort((a, b) => a - b)
    const last = samples[samples.length - 1]!
    stats.set({
      updates: samples.length,
      lastMs: last.ms,
      meanMs: sorted.reduce((sum, ms) => sum + ms, 0) / sorted.length,
      p95Ms: sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))]!,
      maxMs: sorted[sorted.length - 1]!,
      lastRows: last.rows,
      maxRows: Math.max(...samples.map((sample) => sample.rows)),
      lastLists: last.lists,
      longestFrameMs: Math.max(0, ...frameGaps.map((entry) => entry.gap)),
    })
  }, 250)

  onDispose(() => {
    stop()
    clearInterval(refresh)
    cancelAnimationFrame(rafId)
    client.dispose()
    scheduler.dispose()
  })

  return {
    store: client.store,
    subscription,
    viewport,
    stats: stats as ReadSignal<LabStats>,
    load: load as ReadSignal<LoadKind>,
    start,
    stop,
    resetSamples: () => {
      samples.length = 0
    },
  }
}
