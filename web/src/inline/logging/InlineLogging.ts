import {
  Log,
  LogRingBuffer,
  type LogLevel,
  type LogRecord,
} from "@inline/log"
import { isResizeObserverLoopError } from "~/platform/browser/BrowserResizeObserverErrors"

const logLevels = new Set<LogLevel>([
  "error",
  "warn",
  "info",
  "debug",
  "trace",
])
const isBrowser = typeof window !== "undefined"

const makeRunId = () => {
  try {
    return globalThis.crypto.randomUUID()
  } catch {
    return `run-${Date.now().toString(36)}`
  }
}

export const inlineWebRunId = makeRunId()
export const inlineLogBuffer = new LogRingBuffer()
export const inlineLog = new Log("Web", {
  level: "info",
  sink: isBrowser ? undefined : false,
  recordSinks: isBrowser ? [inlineLogBuffer] : [],
  fields: { runId: inlineWebRunId },
})

export type InlineDiagnostics = {
  readonly runId: string
  getLevel: () => LogLevel
  setLevel: (level: LogLevel) => void
  read: () => readonly LogRecord[]
  clear: () => void
  stats: () => { entries: number; bytes: number; dropped: number }
}

const diagnostics: InlineDiagnostics = Object.freeze({
  runId: inlineWebRunId,
  getLevel: () => inlineLog.getLevel(),
  setLevel: (level: LogLevel) => {
    if (!logLevels.has(level)) {
      throw new RangeError(`Unsupported Inline log level: ${String(level)}`)
    }
    inlineLog.setLevel(level)
    inlineLog.info("logging.level.changed", { level })
  },
  read: () => inlineLogBuffer.snapshot(),
  clear: () => inlineLogBuffer.clear(),
  stats: () => ({
    entries: inlineLogBuffer.snapshot().length,
    bytes: inlineLogBuffer.sizeBytes,
    dropped: inlineLogBuffer.droppedCount,
  }),
})

let listenerReferences = 0
let detachGlobalListeners: (() => void) | undefined

const exposeDiagnostics = () => {
  try {
    Object.defineProperty(window, "__inlineDiagnostics", {
      configurable: true,
      enumerable: false,
      value: diagnostics,
    })
  } catch {
    // Diagnostics are optional; logging must not prevent application boot.
  }
}

const attachGlobalListeners = () => {
  const runtimeLog = inlineLog.withScope("Runtime")
  const onError = (event: ErrorEvent) => {
    if (isResizeObserverLoopError(event.message)) return
    runtimeLog.error("runtime.window.error", {
      error: event.error ?? event.message,
    })
  }
  const onUnhandledRejection = (event: PromiseRejectionEvent) => {
    runtimeLog.error("runtime.promise.unhandled", {
      reason: event.reason,
    })
  }
  window.addEventListener("error", onError)
  window.addEventListener("unhandledrejection", onUnhandledRejection)
  return () => {
    window.removeEventListener("error", onError)
    window.removeEventListener("unhandledrejection", onUnhandledRejection)
  }
}

export const retainInlineGlobalLogging = () => {
  if (!isBrowser) return () => undefined
  exposeDiagnostics()
  listenerReferences += 1
  if (listenerReferences === 1) {
    detachGlobalListeners = attachGlobalListeners()
    inlineLog.info("runtime.logging.ready")
  }

  let released = false
  return () => {
    if (released) return
    released = true
    listenerReferences = Math.max(0, listenerReferences - 1)
    if (listenerReferences !== 0) return
    detachGlobalListeners?.()
    detachGlobalListeners = undefined
  }
}

export const logInlineRouteError = (
  route: "root" | "chat",
  error: unknown,
) => {
  inlineLog.withScope("Route").error("route.render.failed", {
    route,
    error,
  })
}

if (import.meta.hot) {
  import.meta.hot.dispose(() => {
    detachGlobalListeners?.()
    detachGlobalListeners = undefined
    listenerReferences = 0
  })
}

declare global {
  interface Window {
    __inlineDiagnostics?: InlineDiagnostics
  }
}
