import * as Sentry from "@sentry/bun"
import { styleText } from "node:util"

// cannot depend on env.ts
const isProd = process.env.NODE_ENV === "production"

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

  private disableLogging = process.env.NODE_ENV === "test" && !process.env["DEBUG"]
  private static logLevel = (() => {
    let defaultLevel =
      process.env.NODE_ENV === "test" && !process.env["DEBUG"]
        ? LogLevel.ERROR
        : isProd
        ? LogLevel.WARN
        : LogLevel.DEBUG
    const scopeColored = styleText("green", "logger")
    console.info(scopeColored, "Initialized with default level:", LogLevel[defaultLevel])
    return defaultLevel
  })()

  private logLevel: LogLevel

  constructor(private scope: string, level?: LogLevel) {
    this.logLevel = level ?? globalLogLevel[scope] ?? Log.logLevel
  }

  error(
    messageOrError: string | unknown,
    errorOrMetadata?: unknown | Error | Record<string, unknown>,
    metadata?: Record<string, unknown>,
  ): void {
    if (this.disableLogging) return
    if (this.logLevel < LogLevel.ERROR) return

    const scopeColored = styleText("red", this.scope)
    if (typeof messageOrError === "string") {
      console.error(scopeColored, messageOrError, errorOrMetadata, metadata)
      Sentry.captureException(new Error(messageOrError), { extra: errorOrMetadata as Record<string, unknown> })
    } else {
      console.error(scopeColored, messageOrError, errorOrMetadata, metadata)
      Sentry.captureException(messageOrError)
    }
  }

  warn(messageOrError: string | unknown, error?: unknown | Error): void {
    if (this.disableLogging) return
    if (this.logLevel < LogLevel.WARN) return

    const scopeColored = styleText("yellow", this.scope)
    if (typeof messageOrError === "string") {
      console.warn(scopeColored, messageOrError, error)
      Sentry.captureMessage(messageOrError, "warning")
    } else {
      console.warn(scopeColored, messageOrError)
      Sentry.captureMessage(String(messageOrError), "warning")
    }
  }

  info(...args: any[]): void {
    if (this.disableLogging) return
    if (this.logLevel < LogLevel.INFO) return

    const scopeColored = styleText("cyan", this.scope)
    console.info(scopeColored, ...args)
  }

  debug(...args: any[]): void {
    if (this.disableLogging) return
    if (this.logLevel < LogLevel.DEBUG) return

    const scopeColored = styleText("blue", this.scope)
    console.debug(scopeColored, ...args)
  }

  trace(...args: any[]): void {
    if (this.disableLogging) return
    if (this.logLevel < LogLevel.TRACE) return

    const scopeColored = styleText("magenta", this.scope)
    console.trace(scopeColored, ...args)
  }
}
