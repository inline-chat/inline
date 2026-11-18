/**
 * Browser probes: frame recording, performance observers, waiting for a DOM
 * condition, "after paint", and the main-thread busy probe. Thin on purpose:
 * the arithmetic is in `stats.ts`, tested in Node.
 *
 * Every probe takes the app frame's window and reads its clock
 * (`win.performance.now()`), so times from different probes compare. The app
 * frame and the lab share one main thread (same origin, same agent), so its
 * animation frames are the lab's.
 */

import type { AppSnapshot } from "../../app/dev-snapshot"
import type { DemoControl } from "../../core/demo/control"
import { FrameTimeoutError, FRAME_TIMEOUT_MS } from "../timeline/frames"

/** The app frame's window, with the automation globals of the labs build. */
export type AppWindow = Window &
  typeof globalThis & {
    __inlineApp?: AppSnapshot
    __inlineDemo?: DemoControl
  }

export class ConditionTimeoutError extends Error {
  constructor(what: string, ms: number, detail?: string) {
    super(`Timed out after ${Math.round(ms)} ms waiting for ${what}${detail ? ` (${detail})` : ""}.`)
    this.name = "ConditionTimeoutError"
  }
}

/** A promise that rejects with a clear error when it does not settle in time. */
export const withTimeout = <T>(promise: Promise<T>, ms: number, what: string): Promise<T> =>
  new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new ConditionTimeoutError(what, ms)), ms)
    promise.then(
      (value) => {
        clearTimeout(timer)
        resolve(value)
      },
      (error: unknown) => {
        clearTimeout(timer)
        reject(error)
      },
    )
  })

// ---------------------------------------------------------------------------
// Frames

export type FrameRecording = {
  /** The frame's timestamp as the browser passed it (frame start). */
  frames: number[]
  /** When each frame callback ran, on `performance.now()`. Use these to order frames against events. */
  runs: number[]
  stop(): FrameRecording
}

/** A `requestAnimationFrame` loop that records every frame until stopped. It keeps frames coming while it runs. */
export const recordFrames = (win: AppWindow, each?: (now: number) => void): FrameRecording => {
  let running = true
  let id = 0
  const recording: FrameRecording = {
    frames: [],
    runs: [],
    stop: () => {
      running = false
      win.cancelAnimationFrame(id)
      return recording
    },
  }
  const tick = (timestamp: number) => {
    if (!running) return
    recording.frames.push(timestamp)
    const now = win.performance.now()
    recording.runs.push(now)
    each?.(now)
    id = win.requestAnimationFrame(tick)
  }
  id = win.requestAnimationFrame(tick)
  return recording
}

/** The next frame of the app's window; rejects when none comes (a hidden or occluded window). */
export const nextFrame = (win: AppWindow, what = "an animation frame", timeoutMs = FRAME_TIMEOUT_MS): Promise<number> =>
  new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      win.cancelAnimationFrame(id)
      reject(new FrameTimeoutError(what, timeoutMs))
    }, timeoutMs)
    const id = win.requestAnimationFrame((timestamp) => {
      clearTimeout(timer)
      resolve(timestamp)
    })
  })

export const waitFrames = async (win: AppWindow, count: number, what = "frames") => {
  for (let i = 0; i < count; i++) await nextFrame(win, what)
}

/**
 * After the next paint: a frame, then a task posted from it, as the app's
 * own marks define it (`web/src/app/perf.ts`). `frameAt` is when the frame's
 * callback ran; `paintedAt` is when the task ran (the frame has painted).
 */
export const afterPaint = (win: AppWindow): Promise<{ frameAt: number; paintedAt: number }> =>
  new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new FrameTimeoutError("Waiting for a paint", FRAME_TIMEOUT_MS)), FRAME_TIMEOUT_MS)
    win.requestAnimationFrame(() => {
      const frameAt = win.performance.now()
      const channel = new win.MessageChannel()
      channel.port1.onmessage = () => {
        clearTimeout(timer)
        channel.port1.close()
        resolve({ frameAt, paintedAt: win.performance.now() })
      }
      channel.port2.postMessage(null)
    })
  })

/** Frame rate of the app's window over `count` frames; 0 when frames stopped. */
export const measureFrameTimes = async (win: AppWindow, count = 30): Promise<number[]> => {
  const times: number[] = []
  try {
    for (let i = 0; i < count; i++) times.push(await nextFrame(win, "measuring the frame rate", 2_000))
  } catch {
    // Frames stopped: the caller sees too few timestamps.
  }
  return times
}

// ---------------------------------------------------------------------------
// Performance observers

export type EntryRecording<T extends PerformanceEntry = PerformanceEntry> = {
  supported: boolean
  entries: T[]
  stop(): T[]
}

export const supportsEntryType = (win: AppWindow, type: string): boolean => {
  const types = (win.PerformanceObserver as { supportedEntryTypes?: readonly string[] } | undefined)?.supportedEntryTypes
  return types?.includes(type) ?? false
}

/** Records entries of `type` in the app's window from now until `stop()`. */
export const recordEntries = <T extends PerformanceEntry = PerformanceEntry>(win: AppWindow, type: string): EntryRecording<T> => {
  const entries: T[] = []
  if (!supportsEntryType(win, type)) return { supported: false, entries, stop: () => entries }
  const observer = new win.PerformanceObserver((list) => {
    entries.push(...(list.getEntries() as T[]))
  })
  observer.observe({ type, buffered: false })
  return {
    supported: true,
    entries,
    stop: () => {
      entries.push(...(observer.takeRecords() as T[]))
      observer.disconnect()
      return entries
    },
  }
}

/** The parts of a Long Animation Frame entry the lab reads (not in TypeScript's DOM types yet). */
export type LongAnimationFrame = PerformanceEntry & {
  blockingDuration?: number
  renderStart?: number
  styleAndLayoutStart?: number
  scripts?: readonly {
    duration: number
    invoker?: string
    sourceURL?: string
    sourceFunctionName?: string
    forcedStyleAndLayoutDuration?: number
  }[]
}

/** Main-thread observers for a journey: long tasks, and Long Animation Frames where the browser has them. */
export const recordLongWork = (win: AppWindow) => {
  const tasks = recordEntries(win, "longtask")
  const frames = recordEntries<LongAnimationFrame>(win, "long-animation-frame")
  return {
    tasks,
    frames,
    stop: () => ({ tasks: tasks.stop(), frames: frames.stop() }),
  }
}

export type LongWorkSummary = {
  longTasks: number | undefined
  longestTaskMs: number | undefined
  longAnimationFrames: number | undefined
  longestFrameMs: number | undefined
  /** Script time inside long animation frames, by invoker or source, largest first. */
  topScripts: { what: string; ms: number }[]
}

export const summarizeLongWork = (recorded: ReturnType<ReturnType<typeof recordLongWork>["stop"]>, supported: {
  tasks: boolean
  frames: boolean
}): LongWorkSummary => {
  const byScript = new Map<string, number>()
  for (const frame of recorded.frames) {
    for (const script of frame.scripts ?? []) {
      const file = script.sourceURL ? script.sourceURL.split("/").pop() : undefined
      const what = [script.invoker, script.sourceFunctionName, file].filter(Boolean).join(" ") || "script"
      byScript.set(what, (byScript.get(what) ?? 0) + script.duration)
    }
  }
  return {
    longTasks: supported.tasks ? recorded.tasks.length : undefined,
    longestTaskMs: supported.tasks ? Math.max(0, ...recorded.tasks.map((t) => t.duration)) : undefined,
    longAnimationFrames: supported.frames ? recorded.frames.length : undefined,
    longestFrameMs: supported.frames ? Math.max(0, ...recorded.frames.map((f) => f.duration)) : undefined,
    topScripts: [...byScript]
      .map(([what, ms]) => ({ what, ms: Math.round(ms * 10) / 10 }))
      .sort((a, b) => b.ms - a.ms)
      .slice(0, 5),
  }
}

// ---------------------------------------------------------------------------
// DOM

/**
 * Resolves when `check` returns a value, checked now and after every DOM
 * mutation under `root` (a microtask after the change, so `at` is close to
 * when the change happened). Rejects with the `what` named when it does not
 * happen in time.
 */
export const waitForDom = <T>(
  win: AppWindow,
  root: Node,
  check: () => T | undefined | null | false,
  what: string,
  timeoutMs: number,
  detail?: () => string,
): Promise<{ value: T; at: number }> =>
  new Promise((resolve, reject) => {
    const first = check()
    if (first) {
      resolve({ value: first, at: win.performance.now() })
      return
    }
    const observer = new win.MutationObserver(() => {
      const value = check()
      if (!value) return
      const at = win.performance.now()
      observer.disconnect()
      clearTimeout(timer)
      resolve({ value, at })
    })
    const timer = setTimeout(() => {
      observer.disconnect()
      reject(new ConditionTimeoutError(what, timeoutMs, detail?.()))
    }, timeoutMs)
    observer.observe(root, { subtree: true, childList: true, attributes: true, characterData: true })
  })

/** Every mutation under `root` until stopped, with the time of each callback. */
export const recordMutations = (win: AppWindow, root: Node) => {
  const batches: { at: number; records: MutationRecord[] }[] = []
  const observer = new win.MutationObserver((records) => {
    batches.push({ at: win.performance.now(), records })
  })
  observer.observe(root, { subtree: true, childList: true, attributes: true, characterData: true })
  return {
    batches,
    stop: () => {
      const rest = observer.takeRecords()
      if (rest.length > 0) batches.push({ at: win.performance.now(), records: rest })
      observer.disconnect()
      return batches
    },
  }
}

/** A short description of a mutation's target, for notes. */
export const describeMutation = (record: MutationRecord): string => {
  const target = record.target
  const element = target.nodeType === 1 ? (target as Element) : target.parentElement
  const tag = element ? element.tagName.toLowerCase() : "#node"
  const marker = element
    ? ["data-timeline-key", "data-sidebar-key", "aria-label", "role"]
        .map((name) => (element.hasAttribute(name) ? `[${name}="${(element.getAttribute(name) ?? "").slice(0, 30)}"]` : ""))
        .find((text) => text !== "") ?? ""
    : ""
  const kind = record.type === "attributes" ? `@${record.attributeName ?? ""}` : record.type === "childList" ? "children" : "text"
  return `${tag}${marker} ${kind}`
}

export const countNodes = (doc: Document): { elements: number; nodes: number } => {
  let nodes = 0
  const walker = doc.createTreeWalker(doc, 0xffffffff)
  while (walker.nextNode()) nodes += 1
  return { elements: doc.getElementsByTagName("*").length, nodes }
}

// ---------------------------------------------------------------------------
// Busy probe

/**
 * A self-posting message loop that records when each turn runs. Gaps between
 * turns are time the main thread spent elsewhere (see `busyIntervals`). It
 * keeps the thread spinning, which disturbs frame timing, so journeys run it
 * in a separate pass from their frame measurements.
 */
export const startBusyProbe = (win: AppWindow) => {
  const ticks: number[] = []
  const channel = new win.MessageChannel()
  let running = true
  channel.port1.onmessage = () => {
    ticks.push(win.performance.now())
    if (running) channel.port2.postMessage(null)
  }
  channel.port2.postMessage(null)
  return {
    ticks,
    stop: () => {
      running = false
      channel.port1.close()
      return ticks
    },
  }
}

/** A small fixed workload, timed: compare runs on one machine (it takes about 4x as long under 4x throttling). */
export const cpuProbe = (now: () => number): number => {
  const runs: number[] = []
  for (let run = 0; run < 3; run++) {
    const started = now()
    const values: number[] = []
    let seed = 1
    for (let i = 0; i < 60_000; i++) {
      seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648
      values.push(seed)
    }
    values.sort((a, b) => a - b)
    const text = JSON.stringify(values.slice(0, 5_000))
    if ((JSON.parse(text) as number[]).length !== 5_000) throw new Error("cpu probe")
    runs.push(now() - started)
  }
  runs.sort((a, b) => a - b)
  return runs[1] as number
}
