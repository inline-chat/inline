import type { ErrorEvent } from "@sentry/bun"
import { sendInlineOnlyBotEvent } from "@in/server/modules/bot-events"
import { createTelegramAlertSender } from "./telegramAlerts"

/**
 * Pages when one error keeps happening, instead of waiting for Sentry's single
 * "new issue" email to be noticed. Counts are per process, keyed by error type
 * and route, in fixed windows. The production baseline is a handful of errors a
 * day, so a few of the same error in ten minutes is an incident.
 */
export type ErrorBurstOptions = {
  windowMs: number
  threshold: number
  cooldownMs: number
  maxKeys: number
}

export const DEFAULT_ERROR_BURST_OPTIONS: ErrorBurstOptions = {
  windowMs: 10 * 60_000,
  threshold: 5,
  cooldownMs: 2 * 60 * 60_000,
  maxKeys: 500,
}

type KeyState = { windowStartMs: number; count: number; lastAlertMs: number | null; totalSinceAlert: number }

export class ErrorBurstDetector {
  private readonly keys = new Map<string, KeyState>()

  constructor(private readonly options: ErrorBurstOptions = DEFAULT_ERROR_BURST_OPTIONS) {}

  /** Returns the window count when this occurrence should page, otherwise null. */
  record(key: string, nowMs: number): { count: number; repeat: boolean; totalSinceAlert: number } | null {
    let state = this.keys.get(key)
    if (!state) {
      if (this.keys.size >= this.options.maxKeys) {
        const oldest = this.keys.keys().next().value
        if (oldest !== undefined) this.keys.delete(oldest)
      }
      state = { windowStartMs: nowMs, count: 0, lastAlertMs: null, totalSinceAlert: 0 }
      this.keys.set(key, state)
    }
    if (nowMs - state.windowStartMs >= this.options.windowMs) {
      state.windowStartMs = nowMs
      state.count = 0
    }
    state.count += 1
    state.totalSinceAlert += 1

    if (state.count < this.options.threshold) return null
    if (state.lastAlertMs !== null && nowMs - state.lastAlertMs < this.options.cooldownMs) return null

    const result = { count: state.count, repeat: state.lastAlertMs !== null, totalSinceAlert: state.totalSinceAlert }
    state.lastAlertMs = nowMs
    state.totalSinceAlert = 0
    return result
  }
}

const SENTRY_ISSUES_URL = "https://usenoor.sentry.io/issues/"

/** Error type plus route: stable across occurrences, free of ids and user data. */
export const errorBurstKey = (event: ErrorEvent): { key: string; errorType: string; route: string } => {
  const errorType = event.exception?.values?.at(-1)?.type ?? "Error"
  const method = event.request?.method
  const path = event.request?.url ? safePath(event.request.url) : undefined
  const route = path ? `${method ? `${method} ` : ""}${path}` : event.transaction ?? "no route"
  return { key: `${errorType} | ${route}`, errorType, route }
}

const safePath = (url: string): string => {
  try {
    return new URL(url, "http://local").pathname
  } catch {
    return url.split("?", 1)[0] ?? url
  }
}

export const formatErrorBurstAlert = (input: {
  errorType: string
  route: string
  count: number
  windowMs: number
  repeat: boolean
  totalSinceAlert: number
  release: string | undefined
  machine: string | undefined
}): string => {
  const minutes = Math.round(input.windowMs / 60_000)
  const query = encodeURIComponent(`is:unresolved error.type:${input.errorType}`)
  return [
    `🚨 inline-server: ${input.errorType} on ${input.route}`,
    input.repeat
      ? `Still failing: ${input.totalSinceAlert} since the last alert, ${input.count} in the last ${minutes} min.`
      : `${input.count} in the last ${minutes} min.`,
    [input.machine ? `machine ${input.machine}` : null, input.release ? `release ${input.release}` : null]
      .filter(Boolean)
      .join(" · "),
    `${SENTRY_ISSUES_URL}?project=inline-server&query=${query}&statsPeriod=24h`,
  ]
    .filter((line) => line.length > 0)
    .join("\n")
}

let detector: ErrorBurstDetector | undefined
let telegram: ((message: string) => Promise<void>) | undefined

/**
 * Sentry error-event hook. Must never throw or delay the event: delivery is
 * fire-and-forget to the Inline alerts chat and, when configured, Telegram,
 * which still works when Inline itself is the thing failing.
 */
export const recordErrorBurst = (event: ErrorEvent): void => {
  try {
    if (event.level !== undefined && event.level !== "error" && event.level !== "fatal") return
    detector ??= new ErrorBurstDetector()
    const { key, errorType, route } = errorBurstKey(event)
    const burst = detector.record(key, Date.now())
    if (!burst) return

    const message = formatErrorBurstAlert({
      errorType,
      route,
      count: burst.count,
      windowMs: DEFAULT_ERROR_BURST_OPTIONS.windowMs,
      repeat: burst.repeat,
      totalSinceAlert: burst.totalSinceAlert,
      release: event.dist?.slice(0, 9),
      machine: process.env["FLY_MACHINE_ID"] ?? event.server_name,
    })
    sendInlineOnlyBotEvent(message)
    if (process.env["TELEGRAM_ALERTS_CHAT_ID"]) {
      telegram ??= createTelegramAlertSender()
      void telegram(message).catch(() => {})
    }
  } catch {
    // Alerting must never replace or block the error being reported.
  }
}
