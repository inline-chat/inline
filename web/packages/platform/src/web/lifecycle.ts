/**
 * Page lifecycle as signals and events. The core needs visibility, online
 * state and wakes forwarded (`BrowserSignal` in core-protocol); `freezes` has
 * the shape of `LifecycleSource` in `@inline/link`, so link takes it directly.
 * Neither package imports the other.
 */

import type { Dispose } from "@inline/reactive"
import { batch, signal } from "@inline/reactive"
import type { FreezeEvent, Lifecycle, PageHideEvent, WakeEvent } from "../platform"
import { createWakeDetector } from "../wake-detector"
import type { WebEnv } from "./env"

export interface WebLifecycleOptions {
  readonly wakeIntervalMs?: number
  readonly wakeToleranceMs?: number
}

export const createWebLifecycle = (
  env: WebEnv,
  options: WebLifecycleOptions = {},
): { lifecycle: Lifecycle; dispose(): void } => {
  const { window, document, navigator } = env
  const readFocus = () => {
    try {
      return document.hasFocus()
    } catch {
      return false
    }
  }
  const visible = signal(document.visibilityState !== "hidden")
  const focused = signal(readFocus())
  const online = signal(navigator.onLine !== false)

  const freezeListeners = new Set<(event: FreezeEvent) => void>()
  const pageHideListeners = new Set<(event: PageHideEvent) => void>()
  const wakeListeners = new Set<(event: WakeEvent) => void>()

  let frozen = false
  const emitFreeze = (event: FreezeEvent) => {
    // `freeze` then `pagehide(persisted)` both mean frozen; report it once.
    const next = event === "freeze"
    if (next === frozen) return
    frozen = next
    for (const listener of Array.from(freezeListeners)) listener(event)
  }

  const detector = createWakeDetector({
    clock: env.clock,
    ...(options.wakeIntervalMs !== undefined ? { intervalMs: options.wakeIntervalMs } : {}),
    ...(options.wakeToleranceMs !== undefined ? { toleranceMs: options.wakeToleranceMs } : {}),
    onWake: (gapMs) => {
      for (const listener of Array.from(wakeListeners)) listener({ gapMs })
    },
  })

  const onVisibility = () => {
    const isVisible = document.visibilityState !== "hidden"
    batch(() => {
      visible.set(isVisible)
      focused.set(readFocus())
    })
    if (isVisible) detector.check()
  }
  const onFocus = () => {
    focused.set(true)
    detector.check()
  }
  const onBlur = () => focused.set(false)
  const onOnline = () => {
    online.set(true)
    detector.check()
  }
  const onOffline = () => online.set(false)
  const onFreeze = () => emitFreeze("freeze")
  const onResume = () => emitFreeze("resume")
  const onPageHide = (event: { persisted?: boolean }) => {
    const persisted = event.persisted === true
    for (const listener of Array.from(pageHideListeners)) listener({ persisted })
    if (persisted) emitFreeze("freeze")
  }
  const onPageShow = (event: { persisted?: boolean }) => {
    if (event.persisted === true) {
      emitFreeze("resume")
      onVisibility()
    }
  }

  document.addEventListener("visibilitychange", onVisibility)
  document.addEventListener("freeze", onFreeze)
  document.addEventListener("resume", onResume)
  window.addEventListener("focus", onFocus)
  window.addEventListener("blur", onBlur)
  window.addEventListener("online", onOnline)
  window.addEventListener("offline", onOffline)
  window.addEventListener("pagehide", onPageHide)
  window.addEventListener("pageshow", onPageShow)

  const subscribe =
    <E>(set: Set<(event: E) => void>) =>
    (listener: (event: E) => void): Dispose => {
      set.add(listener)
      return () => set.delete(listener)
    }

  return {
    lifecycle: {
      visible,
      focused,
      online,
      freezes: { subscribe: subscribe(freezeListeners) },
      onPageHide: subscribe(pageHideListeners),
      onWake: subscribe(wakeListeners),
    },
    dispose() {
      detector.dispose()
      document.removeEventListener("visibilitychange", onVisibility)
      document.removeEventListener("freeze", onFreeze)
      document.removeEventListener("resume", onResume)
      window.removeEventListener("focus", onFocus)
      window.removeEventListener("blur", onBlur)
      window.removeEventListener("online", onOnline)
      window.removeEventListener("offline", onOffline)
      window.removeEventListener("pagehide", onPageHide)
      window.removeEventListener("pageshow", onPageShow)
      freezeListeners.clear()
      pageHideListeners.clear()
      wakeListeners.clear()
    },
  }
}
