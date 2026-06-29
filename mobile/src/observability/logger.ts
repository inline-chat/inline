import { addBreadcrumb, captureError } from "@/observability/sentry"

type Meta = Record<string, unknown>
type LogLevel = "debug" | "info" | "warn" | "error"

export function createLogger(scope: string) {
  return {
    debug(message: string, meta?: Meta) {
      write("debug", scope, message, meta)
    },
    info(message: string, meta?: Meta) {
      write("info", scope, message, meta)
    },
    warn(message: string, meta?: Meta) {
      write("warn", scope, message, meta)
    },
    error(message: string, error: unknown, meta?: Meta) {
      write("error", scope, message, meta)
      captureError(error, {
        scope,
        data: {
          message,
          ...meta,
        },
      })
    },
  }
}

function write(level: LogLevel, scope: string, message: string, meta?: Meta): void {
  addBreadcrumb(`${scope}: ${message}`, {
    level,
    ...meta,
  })

  if (!__DEV__ && level === "debug") return

  const line = `[${scope}] ${message}`
  switch (level) {
    case "debug":
      console.debug(line, meta ?? "")
      break
    case "info":
      console.info(line, meta ?? "")
      break
    case "warn":
      console.warn(line, meta ?? "")
      break
    case "error":
      console.error(line, meta ?? "")
      break
  }
}
