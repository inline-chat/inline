/**
 * Browser facts the core cannot see from its worker, sent as `signal` commands:
 * `online`/`offline`, `visibilitychange`, and wake from sleep.
 *
 * Touches `window` and `document` only when called, and only if they exist.
 */

import type { Command } from "@inline/core-protocol"
import { type Clock, type TimerHandle, systemClock } from "./platform"

type SignalWindow = EventTarget & { navigator?: { onLine?: boolean } }
type SignalDocument = EventTarget & { visibilityState?: string }

export type BrowserSignalOptions = {
  window?: SignalWindow
  document?: SignalDocument
  clock?: Clock
  /** How often the wake detector checks the clock. Default 10000. */
  wakeCheckMs?: number
  /** A check that runs this much later than scheduled counts as a wake. Default 30000. */
  wakeGapMs?: number
}

/**
 * Forwards browser signals to `target` (a `LinkedCore`, usually) until the
 * returned function is called. Sends the current online and visibility state
 * at once.
 *
 * The wake detector is a timer that notices it ran much later than scheduled.
 * Throttled background timers can look the same, so it only reports `wake`; it
 * never decides anything about liveness.
 */
export const watchBrowserSignals = (
  target: { post(command: Command): void },
  options: BrowserSignalOptions = {},
): (() => void) => {
  const win = options.window ?? (globalThis as { window?: SignalWindow }).window
  const doc = options.document ?? (globalThis as { document?: SignalDocument }).document
  const clock = options.clock ?? systemClock()
  const checkMs = options.wakeCheckMs ?? 10_000
  const gapMs = options.wakeGapMs ?? 30_000
  const cleanups: (() => void)[] = []

  const post = (signal: Extract<Command, { kind: "signal" }>["signal"]) => target.post({ kind: "signal", signal })

  if (win) {
    const onOnline = () => post({ kind: "online", online: true })
    const onOffline = () => post({ kind: "online", online: false })
    win.addEventListener("online", onOnline)
    win.addEventListener("offline", onOffline)
    cleanups.push(() => {
      win.removeEventListener("online", onOnline)
      win.removeEventListener("offline", onOffline)
    })
    const online = win.navigator?.onLine
    if (typeof online === "boolean") post({ kind: "online", online })
  }

  if (doc) {
    const visible = () => doc.visibilityState !== "hidden"
    const onVisibility = () => post({ kind: "visibility", visible: visible() })
    doc.addEventListener("visibilitychange", onVisibility)
    cleanups.push(() => doc.removeEventListener("visibilitychange", onVisibility))
    post({ kind: "visibility", visible: visible() })
  }

  if (win || doc) {
    let expected = clock.now() + checkMs
    let timer: TimerHandle | undefined
    const tick = () => {
      const now = clock.now()
      if (now - expected >= gapMs) post({ kind: "wake" })
      expected = now + checkMs
      timer = clock.setTimeout(tick, checkMs)
    }
    timer = clock.setTimeout(tick, checkMs)
    cleanups.push(() => {
      if (timer !== undefined) clock.clearTimeout(timer)
    })
  }

  let stopped = false
  return () => {
    if (stopped) return
    stopped = true
    for (const cleanup of cleanups) cleanup()
  }
}
