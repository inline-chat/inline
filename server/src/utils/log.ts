import * as Sentry from "@sentry/bun"
import { styleText } from "node:util"

// cannot depend on env.ts
const isProd = process.env.NODE_ENV === "production"
const isTest = process.env.NODE_ENV === "test"

type Redacted = "<redacted>"
const REDACTED: Redacted = "<redacted>"

const BOT_TOKEN_SEGMENT_RE = /\bbot[^\/\s]*(?::|%3A|%3a)[^\/\s]+\b/g // matches "bot<userId>:IN...." (raw or url-encoded ':')
const BEARER_RE = /\bBearer\s+[^\s]+/gi

export const redactString = (value: string): string => {
  // Avoid leaking tokens in path (e.g. /bot<token>/sendMessage) or in auth headers.
  return value.replace(BEARER_RE, `Bearer ${REDACTED}`).replace(BOT_TOKEN_SEGMENT_RE, `bot${REDACTED}`)
}

const shouldRedactKey = (key: string): boolean => {
  const k = key.toLowerCase()
  return (
    k.includes("authorization") ||
    k === "token" ||
    k.endsWith("token") ||
    k.includes("secret") ||
    k.includes("password")
  )
}

export const redactValue = (value: unknown, depth = 0): unknown => {
  if (depth > 6) return value
  if (value === null || value === undefined) return value

  if (typeof value === "string") return redactString(value)
  if (typeof value === "number" || typeof value === "boolean" || typeof value === "bigint") return value

  if (value instanceof Error) {
    // Preserve the Error object, but redact the message (common place for request paths).
    const next = new Error(redactString(value.message))
    next.name = value.name
    // Redact stack too because it includes the original message on the first line.
    const stack = (value as any).stack
    ;(next as any).stack = typeof stack === "string" ? redactString(stack) : stack
    ;(next as any).cause = redactValue((value as any).cause, depth + 1)
    return next
  }

  if (Array.isArray(value)) return value.map((v) => redactValue(v, depth + 1))

  if (typeof value === "object") {
    const obj = value as Record<string, unknown>
    const out: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(obj)) {
      if (shouldRedactKey(k)) {
        out[k] = REDACTED
      } else {
        out[k] = redactValue(v, depth + 1)
      }
    }
    return out
  }

  return value
}

export enum LogLevel {
  NONE = -1,
  ERROR = 0,
  WARN = 1,
  INFO = 2,
  DEBUG = 3,
  TRACE = 4,
}

// scope -> log level
const globalLogLevel: Record<string, LogLevel> = {
  // shared: LogLevel.INFO,
  // server: LogLevel.INFO,
  //"modules/translation/translation": LogLevel.DEBUG,
}

export class Log {
  static shared = new Log("shared")

  private disableLogging = isTest && !process.env["DEBUG"]
  private static logLevel = (() => {
    let defaultLevel =
      isTest && !process.env["DEBUG"]
        ? LogLevel.ERROR
        : isProd
        ? LogLevel.WARN
        : LogLevel.DEBUG
    const scopeColored = styleText("green", "logger")
    if (!(isTest && !process.env["DEBUG"])) {
      console.info(scopeColored, "Initialized with default level:", LogLevel[defaultLevel])
    }
    return defaultLevel
  })()

  private logLevel: LogLevel

  constructor(private scope: string, level?: LogLevel) {
    this.logLevel = level ?? globalLogLevel[scope] ?? Log.logLevel
  }

  /**
   * @param messageOrError - The message to log or an error object
   * @param errorOrMetadata - The error object or metadata to attach to the error
   * @param metadata - Additional metadata to attach to the error
   */
  error(
    messageOrError: string | unknown,
    errorOrMetadata?: unknown | Error | Record<string, unknown>,
    metadata?: Record<string, unknown>,
  ): void {
    if (this.disableLogging) return
    if (this.logLevel < LogLevel.ERROR) return

    const scopeColored = styleText("red", this.scope)
    if (typeof messageOrError === "string") {
      const args: unknown[] = [scopeColored, redactValue(messageOrError)]
      if (errorOrMetadata !== undefined) args.push(redactValue(errorOrMetadata))
      if (metadata !== undefined) args.push(redactValue(metadata))
      console.error(...args)

      // Check if second argument is an Error - support both log.error("desc", error) and log.error(error, "desc")
      if (this.isError(errorOrMetadata)) {
        Sentry.captureException(redactValue(errorOrMetadata) as Error, {
          extra: redactValue({ message: messageOrError, metadata }) as Record<string, unknown>,
        })
      } else {
        Sentry.captureException(new Error(redactString(messageOrError)), {
          extra: redactValue(errorOrMetadata) as Record<string, unknown>,
        })
      }
    } else {
      const args: unknown[] = [scopeColored, redactValue(messageOrError)]
      if (errorOrMetadata !== undefined) args.push(redactValue(errorOrMetadata))
      if (metadata !== undefined) args.push(redactValue(metadata))
      console.error(...args)
      Sentry.captureException(redactValue(messageOrError) as any)
    }
  }

  private isError(obj: unknown): obj is Error {
    return obj instanceof Error || (typeof obj === "object" && obj !== null && "message" in obj && "stack" in obj)
  }

  warn(messageOrError: string | unknown, error?: unknown | Error): void {
    if (this.disableLogging) return
    if (this.logLevel < LogLevel.WARN) return

    const scopeColored = styleText("yellow", this.scope)
    if (typeof messageOrError === "string") {
      console.warn(scopeColored, redactValue(messageOrError), redactValue(error))
      Sentry.captureMessage(redactString(messageOrError), "warning")
    } else {
      console.warn(scopeColored, redactValue(messageOrError))
      Sentry.captureMessage(redactString(String(messageOrError)), "warning")
    }
  }

  info(...args: any[]): void {
    if (this.disableLogging) return
    if (this.logLevel < LogLevel.INFO) return

    const scopeColored = styleText("cyan", this.scope)
    console.info(scopeColored, ...args.map((a) => redactValue(a)))
  }

  debug(...args: any[]): void {
    if (this.disableLogging) return
    if (this.logLevel < LogLevel.DEBUG) return

    const scopeColored = styleText("blue", this.scope)
    console.debug(scopeColored, ...args.map((a) => redactValue(a)))
  }

  trace(...args: any[]): void {
    if (this.disableLogging) return
    if (this.logLevel < LogLevel.TRACE) return

    const scopeColored = styleText("magenta", this.scope)
    console.trace(scopeColored, ...args.map((a) => redactValue(a)))
  }
}
