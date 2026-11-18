import type { Method, RpcCall, RpcResult } from "@inline-chat/protocol/core"

/** Time as a dependency, so tests drive it with a virtual clock. */
export interface MediaClock {
  now(): number
  setTimeout(callback: () => void, delayMs: number): unknown
  clearTimeout(handle: unknown): void
}

export const systemClock: MediaClock = {
  now: () => Date.now(),
  setTimeout: (callback, delayMs) => globalThis.setTimeout(callback, delayMs),
  clearTimeout: (handle) => globalThis.clearTimeout(handle as ReturnType<typeof globalThis.setTimeout>),
}

/**
 * One RPC over whatever socket the core has (V2 or V3). Must settle when the
 * signal aborts. The media core passes a signal that carries its own per-call
 * deadline.
 */
export type MediaRpcCall = (
  method: Method,
  input: RpcCall["input"],
  signal?: AbortSignal,
) => Promise<RpcResult["result"]>

export type MediaFetch = (input: string, init?: RequestInit) => Promise<Response>

export type MediaErrorCode =
  | "canceled"
  | "invalid_source"
  | "source_changed"
  | "protocol"
  | "rejected"
  | "retryable"
  | "expired"
  | "processing_timeout"
  | "integrity"
  | "length_mismatch"
  | "http"
  | "link_rejected"
  | "range_not_supported"
  | "offline"
  | "closed"

/** Codes a later attempt cannot fix with the same server upload or the same bytes. */
const TERMINAL_CODES: ReadonlySet<MediaErrorCode> = new Set([
  "canceled",
  "invalid_source",
  "source_changed",
  "protocol",
  "rejected",
  "expired",
  "closed",
])

export class MediaError extends Error {
  constructor(
    readonly code: MediaErrorCode,
    message: string,
    readonly detail?: { status?: number; retryAfterMs?: number },
  ) {
    super(message)
    this.name = `MediaError:${code}`
  }

  get terminal(): boolean {
    return TERMINAL_CODES.has(this.code)
  }
}

export const canceled = (): MediaError => new MediaError("canceled", "The transfer was canceled")

export const isAbortError = (error: unknown): boolean =>
  error instanceof MediaError
    ? error.code === "canceled"
    : error instanceof Error && (error.name === "AbortError" || error.name === "TimeoutError")

export const throwIfAborted = (signal: AbortSignal | undefined): void => {
  if (signal?.aborted) throw canceled()
}

/**
 * A child signal that aborts with its parent or after `timeoutMs` of the
 * clock. `dispose` clears the timer and the parent listener.
 */
export const deadlineSignal = (
  clock: MediaClock,
  timeoutMs: number,
  parent?: AbortSignal,
): { signal: AbortSignal; dispose: () => void } => {
  const controller = new AbortController()
  const onParentAbort = () => controller.abort(parent?.reason)
  if (parent?.aborted) controller.abort(parent.reason)
  parent?.addEventListener("abort", onParentAbort, { once: true })
  const timer = clock.setTimeout(() => {
    controller.abort(new MediaError("retryable", "The request timed out"))
  }, timeoutMs)
  return {
    signal: controller.signal,
    dispose: () => {
      clock.clearTimeout(timer)
      parent?.removeEventListener("abort", onParentAbort)
    },
  }
}

/** Waits on the clock; rejects with `canceled` when the signal aborts. */
export const sleep = (clock: MediaClock, ms: number, signal?: AbortSignal): Promise<void> =>
  new Promise<void>((resolve, reject) => {
    if (signal?.aborted) {
      reject(canceled())
      return
    }
    const onAbort = () => {
      clock.clearTimeout(timer)
      reject(canceled())
    }
    const timer = clock.setTimeout(() => {
      signal?.removeEventListener("abort", onAbort)
      resolve()
    }, Math.max(0, ms))
    signal?.addEventListener("abort", onAbort, { once: true })
  })

/** File identity from the server: `[A-Za-z0-9_-]{6,128}` (`NativeDownloadManager.validFileID`). */
export const isValidFileUniqueId = (value: string): boolean => /^[A-Za-z0-9_-]{6,128}$/.test(value)
