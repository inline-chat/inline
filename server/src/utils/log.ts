import * as Sentry from "@sentry/bun"
import { styleText } from "node:util"

export class Log {
  static shared = new Log("shared")

  constructor(private scope: string) {}

  error(
    messageOrError: string | unknown,
    errorOrMetadata?: unknown | Error | Record<string, unknown>,
    metadata?: Record<string, unknown>,
  ): void {
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
    const scopeColored = styleText("yellow", this.scope)
    if (typeof messageOrError === "string") {
      console.warn(scopeColored, messageOrError, error)
      Sentry.captureMessage(messageOrError, "warning")
    } else {
      console.warn(scopeColored, messageOrError)
      Sentry.captureMessage(String(messageOrError), "warning")
    }
  }

  debug(...args: any[]): void {
    const scopeColored = styleText("blue", this.scope)
    console.debug(scopeColored, ...args)
  }
}
