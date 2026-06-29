import * as Sentry from "@sentry/react-native"
import type { ComponentType } from "react"

import type { AuthSession } from "@/auth/session"
import { appConfig } from "@/config/app"

type CaptureContext = {
  scope: string
  data?: Record<string, unknown>
}

let initialized = false
let appLoaded = false

export function initSentry(): void {
  if (initialized) return
  initialized = true

  if (!appConfig.sentryDsn) return

  Sentry.init({
    dsn: appConfig.sentryDsn,
    environment: appConfig.environment,
    release: appConfig.sentryRelease,
    dist: appConfig.sentryDist,
    tracesSampleRate: appConfig.sentryTracesSampleRate,
    integrations: [
      Sentry.reactNativeTracingIntegration({
        shouldCreateSpanForRequest: (url) => url.startsWith(appConfig.apiBaseUrl),
      }),
    ],
    enableAutoSessionTracking: true,
    enableNativeCrashHandling: true,
    enableNdk: true,
    enableAutoPerformanceTracing: true,
    enableCaptureFailedRequests: false,
    sendDefaultPii: false,
    attachScreenshot: false,
    attachViewHierarchy: false,
    beforeSend(event) {
      const headers = event.request?.headers
      if (headers) {
        delete headers["Authorization"]
        delete headers["authorization"]
        delete headers["Cookie"]
        delete headers["cookie"]
      }
      return event
    },
  })
}

export function wrapWithSentry<P extends Record<string, unknown>>(component: ComponentType<P>): ComponentType<P> {
  return appConfig.sentryDsn ? Sentry.wrap(component) : component
}

export function markAppLoaded(): void {
  if (!appConfig.sentryDsn || appLoaded) return
  appLoaded = true
  addBreadcrumb("App loaded")
}

export function identifySentryUser(session: AuthSession): void {
  if (!appConfig.sentryDsn) return
  Sentry.setUser({ id: String(session.userId) })
  Sentry.setTag("inline.client", "android")
}

export function clearSentryUser(): void {
  if (!appConfig.sentryDsn) return
  Sentry.setUser(null)
}

export function addBreadcrumb(message: string, data?: Record<string, unknown>): void {
  if (!appConfig.sentryDsn) return
  Sentry.addBreadcrumb({
    category: "inline.mobile",
    level: "info",
    message,
    data: data ? redact(data) : undefined,
  })
}

export function captureError(error: unknown, context: CaptureContext): void {
  if (!appConfig.sentryDsn) return
  const exception = error instanceof Error ? error : new Error(String(error))
  Sentry.withScope((scope) => {
    scope.setTag("inline.scope", context.scope)
    if (context.data) {
      scope.setContext("inline", redact(context.data))
    }
    Sentry.captureException(exception)
  })
}

function redact(data: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(data).map(([key, value]) => {
      if (sensitiveKey(key)) return [key, "[redacted]"]
      return [key, value]
    }),
  )
}

function sensitiveKey(key: string): boolean {
  const lower = key.toLowerCase()
  return lower.includes("token") || lower.includes("password") || lower.includes("secret") || lower.includes("otp")
}
