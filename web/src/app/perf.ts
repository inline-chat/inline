/**
 * Boot and chat timing marks under stable names (`web/docs/performance.md`,
 * "Measuring"). Performance tests and the developer overlay read these.
 *
 * Every moment is a mark `inline.<moment>` and a measure of the same name
 * from the page's time origin (navigation start) to that mark, so a measure
 * is "how long after the user asked for the page". Boot moments are recorded
 * once per page; the chat switch is recorded on every switch (only the latest
 * entry is kept).
 */

/** The moments, with their mark and measure names. */
export const perfNames = {
  /** The app's module started running. */
  bootStart: "inline.boot.start",
  /** The auth store was read: the gate knows which screen to show. */
  gate: "inline.boot.gate",
  /** The sign-in screen painted (signed out). */
  signInPaint: "inline.boot.signin-paint",
  /** The signed-in shell painted (window frame, sidebar column, panes). */
  shellPaint: "inline.boot.shell-paint",
  /** The core reported `phase: ready`. */
  coreReady: "inline.boot.core-ready",
  /** The first sidebar rows painted. */
  sidebarRows: "inline.boot.sidebar-rows",
  /** The first chat rows painted. */
  chatRows: "inline.boot.chat-rows",
  /** The shell painted from the boot snapshot, before the core answered (boot-snapshot/README.md). */
  snapshotPaint: "inline.boot.snapshot-paint",
  /** Every list restored from the boot snapshot was answered by the core; painted. */
  snapshotReconciled: "inline.boot.snapshot-reconciled",
  /** From choosing a chat to its rows painted. Measured from `inline.chat.switch.start`. */
  chatSwitch: "inline.chat.switch",
} as const

/**
 * Rows reaching the screen in an open chat (an incoming message, a send, an
 * edit), one mark per hand-off; only the latest of each is kept. See
 * `ChatPaneStage` (`features/chat/chat-pane-model.ts`). The store client's
 * own `inline.patch.apply` (reactive) comes before `rows`.
 */
export const stageNames = {
  /** The chat pane read the chat model's rows after a store change (same task as the patch batch). */
  rows: "inline.timeline.rows",
  /** The timeline controller has the items and published what to render. */
  setItems: "inline.timeline.set-items",
  /** The view committed them (a microtask after `setItems`). */
  commit: "inline.timeline.commit",
} as const

export type PerfStage = keyof typeof stageNames

export type PerfMoment = keyof typeof perfNames

/** The parts of `performance` used; injected so tests run without timing APIs. */
export type PerformanceLike = {
  now(): number
  mark(name: string, options?: { detail?: unknown }): unknown
  measure(name: string, startOrOptions?: string | { start?: number | string; end?: number | string }, end?: string): unknown
  clearMarks?(name?: string): void
  clearMeasures?(name?: string): void
}

/** Runs a callback after the next paint: a frame, then a task. */
export type AfterPaint = (fn: () => void) => void

/**
 * How long to wait for a frame before running the callback anyway. A page
 * that is not being painted gets no animation frames: a tab opened in the
 * background, a window that is fully covered, an embedded pane that is not
 * shown. Work queued "after paint" (message content, notifications, the
 * warm-up queue) must still start there, or a chat opened in a background
 * tab would never load its content or notify.
 */
export const AFTER_PAINT_FALLBACK_MS = 200

export type AfterPaintEnv = {
  requestAnimationFrame?: (cb: () => void) => unknown
  setTimeout: (fn: () => void, ms: number) => unknown
  isHidden?: () => boolean
}

export const createAfterPaint = (env: AfterPaintEnv): AfterPaint => (fn) => {
  let ran = false
  const once = () => {
    if (ran) return
    ran = true
    fn()
  }
  const raf = env.requestAnimationFrame
  if (typeof raf !== "function" || env.isHidden?.()) {
    env.setTimeout(once, 0)
    return
  }
  raf(() => env.setTimeout(once, 0))
  env.setTimeout(once, AFTER_PAINT_FALLBACK_MS)
}

export const browserAfterPaint: AfterPaint = createAfterPaint({
  requestAnimationFrame: (cb) => {
    const g = globalThis as { requestAnimationFrame?: (cb: () => void) => number }
    return typeof g.requestAnimationFrame === "function" ? g.requestAnimationFrame(cb) : setTimeout(cb, 0)
  },
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  isHidden: () => (globalThis as { document?: { visibilityState?: string } }).document?.visibilityState === "hidden",
})

export type RecordedMeasure = { readonly name: string; readonly ms: number }

export interface BootMetrics {
  /** Mark a once-per-page moment now. Repeats are ignored. */
  mark(moment: Exclude<PerfMoment, "chatSwitch">): void
  /** Mark a once-per-page moment after the next paint. */
  markAfterPaint(moment: Exclude<PerfMoment, "chatSwitch">): void
  /** A chat switch began (input). */
  chatSwitchStarted(): void
  /** The chat's rows are rendered; measures the switch after the next paint. */
  chatSwitchPainted(): void
  /** Mark a hand-off stage now (`stageNames`). Only the latest mark of each name is kept. */
  stage(stage: PerfStage, detail?: Record<string, unknown>): void
  /** Measures recorded so far, in order. */
  measures(): readonly RecordedMeasure[]
  has(moment: PerfMoment): boolean
}

const switchStart = `${perfNames.chatSwitch}.start`

export const createBootMetrics = (options: {
  readonly performance?: PerformanceLike | undefined
  readonly afterPaint?: AfterPaint
}): BootMetrics => {
  const perf = options.performance
  const afterPaint = options.afterPaint ?? browserAfterPaint
  const recorded: RecordedMeasure[] = []
  const done = new Set<PerfMoment>()
  const pending = new Set<PerfMoment>()
  let switchStartedAt: number | undefined

  const safe = (fn: () => void) => {
    try {
      fn()
    } catch {
      // Timing is diagnostics; it never breaks the app.
    }
  }

  const record = (moment: PerfMoment) => {
    if (done.has(moment)) return
    done.add(moment)
    const name = perfNames[moment]
    const ms = perf ? perf.now() : 0
    safe(() => {
      perf?.mark(name)
      perf?.measure(name, { start: 0, end: name })
    })
    recorded.push({ name, ms: Math.round(ms * 10) / 10 })
  }

  return {
    mark: (moment) => record(moment),
    markAfterPaint: (moment) => {
      if (done.has(moment) || pending.has(moment)) return
      pending.add(moment)
      afterPaint(() => {
        pending.delete(moment)
        record(moment)
      })
    },
    chatSwitchStarted: () => {
      switchStartedAt = perf?.now() ?? 0
      safe(() => {
        perf?.clearMarks?.(switchStart)
        perf?.mark(switchStart)
      })
    },
    chatSwitchPainted: () => {
      const startedAt = switchStartedAt
      if (startedAt === undefined) return
      switchStartedAt = undefined
      afterPaint(() => {
        const name = perfNames.chatSwitch
        const ms = (perf?.now() ?? 0) - startedAt
        safe(() => {
          perf?.clearMeasures?.(name)
          perf?.measure(name, switchStart)
        })
        done.add("chatSwitch")
        const index = recorded.findIndex((entry) => entry.name === name)
        if (index >= 0) recorded.splice(index, 1)
        recorded.push({ name, ms: Math.round(ms * 10) / 10 })
      })
    },
    stage: (stage, detail) => {
      const name = stageNames[stage]
      safe(() => {
        perf?.clearMarks?.(name)
        perf?.mark(name, detail ? { detail } : undefined)
      })
    },
    measures: () => [...recorded],
    has: (moment) => done.has(moment),
  }
}
