import type { ConnectionManager } from "@inline/client/core"

type ConnectionLifecycleTarget = Pick<
  ConnectionManager,
  | "setAppActive"
  | "setNetworkAvailable"
  | "systemDidWake"
>

export type BrowserConnectionLifecycleOptions = {
  connection: ConnectionLifecycleTarget
  wakeCheckIntervalMs?: number
  wakeDriftThresholdMs?: number
  onError?: (error: unknown) => void
  onPageDiscard?: () => void
}

/**
 * Converts browser lifecycle hints into connection constraints. It never
 * opens, closes, or retries a socket itself; ConnectionManager remains the
 * only connection-policy owner.
 */
export class BrowserConnectionLifecycle {
  private readonly connection: ConnectionLifecycleTarget
  private readonly wakeCheckIntervalMs: number
  private readonly wakeDriftThresholdMs: number
  private readonly onError: (error: unknown) => void
  private readonly onPageDiscard: () => void
  private detachListeners: (() => void) | null = null

  constructor(options: BrowserConnectionLifecycleOptions) {
    this.connection = options.connection
    this.wakeCheckIntervalMs =
      options.wakeCheckIntervalMs ?? 15_000
    this.wakeDriftThresholdMs =
      options.wakeDriftThresholdMs ?? 45_000
    this.onError = options.onError ?? (() => undefined)
    this.onPageDiscard = options.onPageDiscard ?? (() => undefined)
  }

  attach() {
    if (this.detachListeners) return this.detachListeners
    if (
      typeof window === "undefined" ||
      typeof document === "undefined"
    ) {
      return () => undefined
    }

    let lastWakeCheckAt = performance.now()

    const run = (operation: Promise<void>) => {
      void operation.catch(this.onError)
    }
    const applyNetworkHint = () => {
      run(
        this.connection.setNetworkAvailable(
          window.navigator.onLine !== false,
        ),
      )
    }
    const applyVisibility = () => {
      run(this.connection.setAppActive(!document.hidden))
    }
    const handleOnline = () => {
      run(this.connection.setNetworkAvailable(true))
    }
    const handleOffline = () => {
      run(this.connection.setNetworkAvailable(false))
    }
    const handleVisibilityChange = () => {
      applyVisibility()
    }
    const handlePageHide = (event: PageTransitionEvent) => {
      run(this.connection.setAppActive(false))
      if (!event.persisted) this.onPageDiscard()
    }
    const handlePageShow = (event: PageTransitionEvent) => {
      run(this.connection.setAppActive(true))
      if (event.persisted) {
        run(this.connection.systemDidWake())
      }
    }
    const handleResume = () => {
      run(this.connection.systemDidWake())
    }

    window.addEventListener("online", handleOnline)
    window.addEventListener("offline", handleOffline)
    window.addEventListener("pageshow", handlePageShow)
    window.addEventListener("pagehide", handlePageHide)
    document.addEventListener(
      "visibilitychange",
      handleVisibilityChange,
    )
    document.addEventListener("resume", handleResume)

    const wakeCheckTimer = window.setInterval(() => {
      const now = performance.now()
      const elapsed = now - lastWakeCheckAt
      lastWakeCheckAt = now
      if (
        elapsed >
        this.wakeCheckIntervalMs + this.wakeDriftThresholdMs
      ) {
        run(this.connection.systemDidWake())
      }
    }, this.wakeCheckIntervalMs)

    applyNetworkHint()
    applyVisibility()

    this.detachListeners = () => {
      window.removeEventListener("online", handleOnline)
      window.removeEventListener("offline", handleOffline)
      window.removeEventListener("pageshow", handlePageShow)
      window.removeEventListener("pagehide", handlePageHide)
      document.removeEventListener(
        "visibilitychange",
        handleVisibilityChange,
      )
      document.removeEventListener("resume", handleResume)
      window.clearInterval(wakeCheckTimer)
      this.detachListeners = null
    }
    return this.detachListeners
  }

  detach() {
    this.detachListeners?.()
  }
}
