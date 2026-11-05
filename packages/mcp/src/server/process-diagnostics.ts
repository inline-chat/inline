import { writeSync } from "node:fs"

const ERROR_NAMES = new Set(["Error", "TypeError", "RangeError", "ReferenceError", "SyntaxError", "URIError", "EvalError", "AggregateError", "AbortError"])
const ERROR_CODES = new Set(["ECONNRESET", "ECONNREFUSED", "ETIMEDOUT", "EPIPE", "ABORT_ERR", "ERR_UNHANDLED_ERROR", "ERR_INVALID_STATE", "ERR_STREAM_WRITE_AFTER_END", "ERR_INVALID_ARG_TYPE", "ERR_ASSERTION"])
const OWNED_MODULES = [
  ["mcp/main", /packages\/mcp\/(?:src|dist)\/main\.[jt]s:(\d+):(\d+)/],
  ["mcp/handler", /packages\/mcp\/(?:src|dist)\/server\/mcp\/handler\.[jt]s:(\d+):(\d+)/],
  ["mcp/modern", /packages\/mcp\/(?:src|dist)\/server\/mcp\/modern\.[jt]s:(\d+):(\d+)/],
  ["mcp/sessions", /packages\/mcp\/(?:src|dist)\/server\/mcp\/sessions\.[jt]s:(\d+):(\d+)/],
  ["mcp/inline-api", /packages\/mcp\/(?:src|dist)\/server\/inline\/inline-api\.[jt]s:(\d+):(\d+)/],
  ["sdk/ws-transport", /packages\/sdk\/(?:src|dist)\/realtime\/ws-transport\.[jt]s:(\d+):(\d+)/],
  ["ws/websocket", /node_modules\/ws\/lib\/websocket\.js:(\d+):(\d+)/],
  ["ws", /(?:^|[\s(])ws:(\d+):(\d+)(?:[)\s]|$)/],
] as const

function revision(value: string | undefined): string | null {
  return value && /^[a-f0-9]{40}$/.test(value) ? value : null
}

export function mcpProcessIdentity(env: NodeJS.ProcessEnv = process.env) {
  return {
    revision: revision(env.INLINE_MCP_REVISION) ?? revision(env.SOURCE_COMMIT),
    runtime: typeof Bun !== "undefined" ? `bun-${Bun.version}` : `node-${process.versions.node}`,
  }
}

/** Only closed classifications and known source locations leave this boundary. */
export function classifyProcessFailure(error: unknown): Record<string, string | number> {
  try {
    if (!(error instanceof Error)) return { errorName: "NonError" }
    const details: Record<string, string | number> = { errorName: ERROR_NAMES.has(error.name) ? error.name : "Error" }
    const code: unknown = (error as Error & { code?: unknown }).code
    if (typeof code === "string" && ERROR_CODES.has(code)) details.errorCode = code
    // Never emit an Error, its message, arbitrary stack frames, paths or headers.
    if (typeof error.stack === "string") {
      for (const frame of error.stack.split("\n", 33).slice(1)) {
        for (const [module, pattern] of OWNED_MODULES) {
          const match = pattern.exec(frame)
          if (!match) continue
          const line = Number(match[1])
          const column = Number(match[2])
          if (line > 0 && line < 10_000_000 && column > 0 && column < 10_000_000) {
            return { ...details, module, line, column }
          }
        }
      }
    }
    return details
  } catch {
    return { errorName: "Unknown" }
  }
}

export function installMcpProcessDiagnostics(options: { write?: (line: string) => void } = {}) {
  const identity = mcpProcessIdentity()
  const write = options.write ?? ((line: string) => { writeSync(2, line) })
  const emit = (event: string, details: Record<string, string | number> = {}) => {
    try {
      write(JSON.stringify({ event, ...identity, pid: process.pid, uptimeMs: Math.round(process.uptime() * 1000), ...details }) + "\n")
    } catch { /* Best-effort diagnostics cannot change startup or termination. */ }
  }
  const failure = (error: unknown, origin: string) => {
    emit("mcp.process.fatal", {
      category: origin === "unhandledRejection" ? "unhandled_rejection" : origin === "startup" ? "startup_failure" : "uncaught_exception",
      ...classifyProcessFailure(error),
    })
  }
  const exit = (code: number) => {
    if (code !== 0) emit("mcp.process.exit", { exitCode: code })
  }
  try {
    // Unlike uncaughtException/unhandledRejection, this observes without taking
    // ownership of recovery or overriding the runtime's default fatal exit.
    process.on("uncaughtExceptionMonitor", failure)
    process.on("exit", exit)
  } catch { /* Unsupported observation must not prevent serving. */ }
  return {
    identity,
    started: () => emit("mcp.process.started"),
    startupFailure: (error: unknown) => failure(error, "startup"),
    dispose: () => {
      process.off("uncaughtExceptionMonitor", failure)
      process.off("exit", exit)
    },
  }
}
