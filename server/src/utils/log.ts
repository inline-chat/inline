import * as Sentry from "@sentry/bun"
import { styleText } from "node:util"

// cannot depend on env.ts
const isProd = process.env.NODE_ENV === "production"
const isTest = process.env.NODE_ENV === "test"

type Redacted = "<redacted>"
const REDACTED: Redacted = "<redacted>"
type SentryLogLevel = "trace" | "debug" | "info" | "warn" | "error" | "fatal"
type SentryLogMessage = Parameters<typeof Sentry.logger.info>[0]
type SentryLogAttributes = Record<string, unknown>

const BOT_TOKEN_SEGMENT_RE = /\bbot[^/\s]*(?::|%3A|%3a)[^/\s]+\b/g // matches "bot<userId>:IN...." (raw or url-encoded ':')
const BEARER_RE = /\bBearer\s+[^\s]+/gi
const AUTH_TOKEN_SEGMENT_RE = /(^|\/)\d+(?::|%3A|%3a)[^/\s]+/g
const SENTRY_PROD_DROP_LEVELS = new Set<SentryLogLevel>(["trace", "debug"])
const SENTRY_USER_DETAIL_ATTRIBUTES = ["user.email", "user.name"]

export const redactString = (value: string): string => {
  // Avoid leaking tokens in path (e.g. /bot<token>/sendMessage) or in auth headers.
  return value
    .replace(BEARER_RE, `Bearer ${REDACTED}`)
    .replace(BOT_TOKEN_SEGMENT_RE, `bot${REDACTED}`)
    .replace(AUTH_TOKEN_SEGMENT_RE, `$1${REDACTED}`)
}

const shouldRedactKey = (key: string): boolean => {
  const k = key.toLowerCase()
  return (
    k.includes("authorization") ||
    k === "token" ||
    k.endsWith("token") ||
    k.includes("email") ||
    k.includes("phone") ||
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

const isRecord = (value: unknown): value is Record<string, unknown> =>
  Object.prototype.toString.call(value) === "[object Object]"

const isError = (value: unknown): value is Error =>
  value instanceof Error || (typeof value === "object" && value !== null && "message" in value && "stack" in value)

const toSentryValue = (value: unknown, depth = 0): unknown => {
  const redacted = redactValue(value)

  if (depth > 6 || redacted === null || redacted === undefined) return redacted
  if (typeof redacted === "bigint") return redacted.toString()
  if (typeof redacted === "string" || typeof redacted === "number" || typeof redacted === "boolean") return redacted
  if (redacted instanceof String) return redactString(redacted.toString())
  if (redacted instanceof Date) return redacted.toISOString()

  if (isError(redacted)) {
    return {
      name: redacted.name,
      message: redactString(redacted.message),
    }
  }

  if (Array.isArray(redacted)) return redacted.map((v) => toSentryValue(v, depth + 1))

  if (typeof redacted === "object") {
    const out: Record<string, unknown> = {}
    for (const [key, next] of Object.entries(redacted)) {
      out[key] = toSentryValue(next, depth + 1)
    }
    return out
  }

  return redacted
}

const toSentryAttributes = (attributes: Record<string, unknown> | undefined): SentryLogAttributes | undefined => {
  if (!attributes) return undefined

  const out: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(attributes)) {
    if (SENTRY_USER_DETAIL_ATTRIBUTES.includes(key)) continue
    out[key] = shouldRedactKey(key) ? REDACTED : toSentryValue(value)
  }

  return out
}

type SentryLog = {
  level: SentryLogLevel
  message: SentryLogMessage
  attributes?: Record<string, unknown>
}

export const beforeSendLog = <T extends SentryLog>(log: T): T | null => {
  if (isProd && SENTRY_PROD_DROP_LEVELS.has(log.level)) {
    return null
  }

  return {
    ...log,
    message: redactString(log.message.toString()) as SentryLogMessage,
    attributes: toSentryAttributes(log.attributes),
  }
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
  static fmt = Sentry.logger.fmt

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

  fatal(
    messageOrError: string | unknown,
    errorOrMetadata?: unknown | Error | Record<string, unknown>,
    metadata?: Record<string, unknown>,
  ): void {
    if (this.disableLogging) return
    if (this.logLevel < LogLevel.ERROR) return

    const scopeColored = styleText("red", this.scope)
    this.writeConsole(console.error, scopeColored, messageOrError, errorOrMetadata, metadata)
    this.sendSentryLog("fatal", messageOrError, [errorOrMetadata, metadata])

    if (isError(messageOrError)) {
      Sentry.captureException(redactValue(messageOrError))
    } else if (isError(errorOrMetadata)) {
      Sentry.captureException(redactValue(errorOrMetadata) as Error, {
        extra: toSentryValue({ message: this.messageText(messageOrError), metadata }) as Record<string, unknown>,
      })
    } else {
      Sentry.captureException(new Error(this.messageText(messageOrError)), {
        extra: toSentryValue(errorOrMetadata) as Record<string, unknown>,
      })
    }
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
    this.sendSentryLog("error", messageOrError, [errorOrMetadata, metadata])
    if (typeof messageOrError === "string") {
      const args: unknown[] = [scopeColored, redactValue(messageOrError)]
      if (errorOrMetadata !== undefined) args.push(redactValue(errorOrMetadata))
      if (metadata !== undefined) args.push(redactValue(metadata))
      console.error(...args)

      // Check if second argument is an Error - support both log.error("desc", error) and log.error(error, "desc")
      if (isError(errorOrMetadata)) {
        Sentry.captureException(redactValue(errorOrMetadata) as Error, {
          extra: toSentryValue({ message: messageOrError, metadata }) as Record<string, unknown>,
        })
      } else {
        Sentry.captureException(new Error(redactString(messageOrError)), {
          extra: toSentryValue(errorOrMetadata) as Record<string, unknown>,
        })
      }
    } else {
      const args: unknown[] = [scopeColored, redactValue(messageOrError)]
      if (errorOrMetadata !== undefined) args.push(redactValue(errorOrMetadata))
      if (metadata !== undefined) args.push(redactValue(metadata))
      console.error(...args)
      Sentry.captureException(redactValue(messageOrError))
    }
  }

  warn(messageOrError: string | unknown, error?: unknown | Error): void {
    if (this.disableLogging) return
    if (this.logLevel < LogLevel.WARN) return

    const scopeColored = styleText("yellow", this.scope)
    this.sendSentryLog("warn", messageOrError, [error])
    if (typeof messageOrError === "string") {
      console.warn(scopeColored, redactValue(messageOrError), redactValue(error))
    } else {
      console.warn(scopeColored, redactValue(messageOrError))
    }
  }

  info(...args: any[]): void {
    if (this.disableLogging) return
    if (this.logLevel < LogLevel.INFO) return

    const scopeColored = styleText("cyan", this.scope)
    this.sendSentryLog("info", args[0] ?? "Log", args.slice(1))
    console.info(scopeColored, ...args.map((a) => redactValue(a)))
  }

  debug(...args: any[]): void {
    if (this.disableLogging) return
    if (this.logLevel < LogLevel.DEBUG) return

    const scopeColored = styleText("blue", this.scope)
    this.sendSentryLog("debug", args[0] ?? "Log", args.slice(1))
    console.debug(scopeColored, ...args.map((a) => redactValue(a)))
  }

  trace(...args: any[]): void {
    if (this.disableLogging) return
    if (this.logLevel < LogLevel.TRACE) return

    const scopeColored = styleText("magenta", this.scope)
    this.sendSentryLog("trace", args[0] ?? "Log", args.slice(1))
    console.trace(scopeColored, ...args.map((a) => redactValue(a)))
  }

  private writeConsole(
    writer: (...args: unknown[]) => void,
    scopeColored: string,
    messageOrError: unknown,
    errorOrMetadata?: unknown,
    metadata?: Record<string, unknown>,
  ) {
    const args: unknown[] = [scopeColored, redactValue(messageOrError)]
    if (errorOrMetadata !== undefined) args.push(redactValue(errorOrMetadata))
    if (metadata !== undefined) args.push(redactValue(metadata))
    writer(...args)
  }

  private sendSentryLog(level: SentryLogLevel, messageOrError: unknown, values: unknown[]) {
    try {
      const message = this.sentryMessage(messageOrError)
      const attributes = this.sentryAttributes(values)

      switch (level) {
        case "fatal":
          Sentry.logger.fatal(message, attributes)
          break
        case "error":
          Sentry.logger.error(message, attributes)
          break
        case "warn":
          Sentry.logger.warn(message, attributes)
          break
        case "info":
          Sentry.logger.info(message, attributes)
          break
        case "debug":
          Sentry.logger.debug(message, attributes)
          break
        case "trace":
          Sentry.logger.trace(message, attributes)
          break
      }
    } catch {
      // Logging should never affect request handling.
    }
  }

  private sentryMessage(value: unknown): SentryLogMessage {
    if (typeof value === "string" || value instanceof String) {
      return value as SentryLogMessage
    }

    if (isError(value)) {
      return redactString(value.message) as SentryLogMessage
    }

    return this.messageText(value) as SentryLogMessage
  }

  private messageText(value: unknown): string {
    if (typeof value === "string") return redactString(value)
    if (value instanceof String) return redactString(value.toString())
    if (isError(value)) return redactString(value.message)

    try {
      return redactString(JSON.stringify(toSentryValue(value)) ?? String(value))
    } catch {
      return String(value)
    }
  }

  private sentryAttributes(values: unknown[]): SentryLogAttributes {
    const attributes: Record<string, unknown> = {
      "logger.scope": this.scope,
    }
    let argIndex = 0

    for (const value of values) {
      if (value === undefined) continue

      if (isError(value)) {
        attributes["error"] = toSentryValue(value)
        continue
      }

      if (isRecord(value)) {
        Object.assign(attributes, toSentryValue(value))
        continue
      }

      attributes[`arg.${argIndex}`] = toSentryValue(value)
      argIndex += 1
    }

    return attributes
  }
}
