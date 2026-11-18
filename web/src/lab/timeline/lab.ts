/**
 * The timeline lab's model: the real timeline controller and DOM surface
 * over the lab's stand-in core, the lab frame's size and composer inset, and
 * the results table. Framework-free; `main.tsx` renders it.
 */

import { signal, type ReadSignal } from "@inline/reactive"
import type { RenderCounter } from "@inline/reactive/react/testing"
import { browserClock, browserFrames, createTimelineController } from "@inline/timeline"
import { createTimelineSurface } from "../../features/timeline"
import { browserFrameScheduler, createFrameWaiter } from "./frames"
import { LAB_VIEWER } from "./generate"
import { createLabCore, type LabCore } from "./lab-core"
import { resultsAsText, type OpResult } from "./results"

export const DEFAULT_SEED = 20261117
export const DEFAULT_FRAME = { width: 560, height: 600 }
/** Simulated network delay for requests the lab serves on its own (scrolling by hand). */
export const SERVE_DELAY_MS = 350

export type LabStatus = { state: "idle" | "running" | "done" | "error"; message: string }

/** What `globalThis.__timelineLab` holds: plain data, safe to read from a script. */
export type LabSnapshot = {
  status: LabStatus["state"]
  message: string
  seed: number
  devicePixelRatio: number
  userAgent: string
  startedAt: string | null
  finishedAt: string | null
  passed: number
  failed: number
  results: OpResult[]
  /** Tab-separated, for pasting. */
  table: string
  /** Per-repetition traces by operation, only with `?trace=1` (null otherwise). */
  trace: Record<string, unknown[]> | null
}

export const createTimelineLab = (options: { seed: number; counter: RenderCounter; trace?: boolean }) => {
  const scheduler = browserFrameScheduler()
  const waiter = createFrameWaiter(scheduler)
  const holder: { core?: LabCore } = {}
  const controller = createTimelineController({
    viewerId: LAB_VIEWER,
    clock: browserClock,
    frames: browserFrames,
    request: (range) => holder.core?.onRequest(range),
    markRead: (decision) => holder.core?.markRead(decision.maxId),
  })
  const core = createLabCore({
    seed: options.seed,
    total: 6000,
    liveEnd: 5600,
    controller,
    serveDelayMs: SERVE_DELAY_MS,
    delay: waiter.delay,
  })
  holder.core = core
  const surface = createTimelineSurface({ controller, window: core.window })

  // Rows are ready before the first render: the list paints placed in its first frame.
  core.openLatest()

  // ---------------------------------------------------------------------------
  // Frame size and composer inset

  let frameElement: HTMLElement | null = null
  const frameSize = signal({ ...DEFAULT_FRAME })
  const composerInset = signal(0)

  const writeFrameSize = () => {
    if (!frameElement) return
    const { width, height } = frameSize.peek()
    // CSSOM, which the content policy allows; the lab's only style writes.
    frameElement.style.setProperty("--lab-frame-inline-size", `${width}px`)
    frameElement.style.setProperty("--lab-frame-block-size", `${height}px`)
  }

  const frame = (element: HTMLElement) => {
    frameElement = element
    writeFrameSize()
    return () => {
      if (frameElement === element) frameElement = null
    }
  }

  const setFrameSize = (size: { width?: number; height?: number }) => {
    frameSize.set({ ...frameSize.peek(), ...size })
    writeFrameSize()
  }

  /** A translucent composer overlaying the list's bottom: the lab draws it, the surface gets the inset. */
  const setComposerInset = (height: number) => {
    composerInset.set(height)
    surface.setInsets({ top: 0, bottom: height })
  }

  // ---------------------------------------------------------------------------
  // Results

  const status = signal<LabStatus>({ state: "idle", message: "Ready." })
  const results = signal<readonly OpResult[]>([])
  const snapshot: LabSnapshot = {
    status: "idle",
    message: "Ready.",
    seed: options.seed,
    devicePixelRatio: globalThis.devicePixelRatio ?? 1,
    userAgent: globalThis.navigator?.userAgent ?? "",
    startedAt: null,
    finishedAt: null,
    passed: 0,
    failed: 0,
    results: [],
    table: "",
    trace: options.trace ? {} : null,
  }

  const publish = () => {
    const list = results.peek()
    const current = status.peek()
    snapshot.status = current.state
    snapshot.message = current.message
    snapshot.results = list.map((result) => structuredClone(result))
    snapshot.passed = list.filter((result) => result.pass).length
    snapshot.failed = list.length - snapshot.passed
    snapshot.devicePixelRatio = globalThis.devicePixelRatio ?? 1
    snapshot.table = resultsAsText(list)
    ;(globalThis as { __timelineLab?: LabSnapshot }).__timelineLab = snapshot
  }
  publish()

  return {
    seed: options.seed,
    counter: options.counter,
    controller,
    core,
    surface,
    waiter,
    frame,
    frameSize: frameSize as ReadSignal<{ width: number; height: number }>,
    setFrameSize,
    composerInset: composerInset as ReadSignal<number>,
    setComposerInset,
    status: status as ReadSignal<LabStatus>,
    results: results as ReadSignal<readonly OpResult[]>,
    setStatus: (next: LabStatus) => {
      status.set(next)
      if (next.state === "running" && snapshot.startedAt === null) snapshot.startedAt = new Date().toISOString()
      if (next.state === "done" || next.state === "error") snapshot.finishedAt = new Date().toISOString()
      publish()
    },
    beginRun: () => {
      results.set([])
      if (snapshot.trace) snapshot.trace = {}
      snapshot.startedAt = new Date().toISOString()
      snapshot.finishedAt = null
      publish()
    },
    record: (result: OpResult) => {
      results.set([...results.peek(), result])
      publish()
    },
    snapshot: () => snapshot,
    /** Whether operations record per-repetition traces (`?trace=1`). */
    tracing: options.trace === true,
    /** Replace one operation's trace on `__timelineLab.trace`. */
    setTrace: (operation: string, entries: unknown[]) => {
      if (!snapshot.trace) return
      snapshot.trace[operation] = entries
      publish()
    },
  }
}

export type TimelineLab = ReturnType<typeof createTimelineLab>
