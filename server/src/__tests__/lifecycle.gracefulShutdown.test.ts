import { createGracefulShutdownManager } from "@in/server/lifecycle/gracefulShutdown"
import { describe, expect, it } from "bun:test"
import type { Server } from "bun"

describe("graceful shutdown lifecycle", () => {
  it("runs shutdown steps in order and only once", async () => {
    const calls: string[] = []
    const timerId = Symbol("shutdown-timer") as unknown as ReturnType<typeof setTimeout>

    const server = {
      stop(closeActiveConnections?: boolean) {
        calls.push(`server.stop:${closeActiveConnections ? "true" : "false"}`)
      },
    } as unknown as Server<unknown>

    const manager = createGracefulShutdownManager({
      server,
      shutdownTimeoutMs: 5_000,
      deps: {
        markShuttingDown: (signal) => calls.push(`mark:${signal}`),
        stopDatabaseMonitor: () => {
          calls.push("monitor.stop")
        },
        stopUserSettingsCleanup: () => {
          calls.push("cache.stop")
        },
        closeConnections: async () => {
          calls.push("connections.close")
        },
        shutdownPresence: async () => {
          calls.push("presence.shutdown")
        },
        shutdownApn: () => {
          calls.push("apn.shutdown")
        },
        closeDatabase: async () => {
          calls.push("db.close")
        },
        flushSentry: async (timeoutMs) => {
          calls.push(`sentry.flush:${timeoutMs}`)
          return true
        },
        setExitCode: (code) => calls.push(`exitCode:${code}`),
        forceExit: (code) => calls.push(`forceExit:${code}`),
        setTimeoutFn: (_handler, timeoutMs) => {
          calls.push(`timer.start:${timeoutMs}`)
          return timerId
        },
        clearTimeoutFn: (id) => {
          if (id === timerId) {
            calls.push("timer.clear")
          }
        },
      },
    })

    const firstShutdown = manager.shutdown("SIGTERM")
    const secondShutdown = manager.shutdown("SIGINT")

    expect(secondShutdown).toBe(firstShutdown)
    await firstShutdown

    expect(calls).toEqual([
      "mark:SIGTERM",
      "timer.start:5000",
      "monitor.stop",
      "cache.stop",
      "server.stop:false",
      "connections.close",
      "presence.shutdown",
      "server.stop:true",
      "apn.shutdown",
      "db.close",
      "sentry.flush:2000",
      "timer.clear",
      "exitCode:0",
    ])
  })

  it("keeps running remaining cleanup steps when one step fails", async () => {
    const calls: string[] = []
    const timerId = Symbol("shutdown-timer") as unknown as ReturnType<typeof setTimeout>

    const server = {
      stop(closeActiveConnections?: boolean) {
        calls.push(`server.stop:${closeActiveConnections ? "true" : "false"}`)
      },
    } as unknown as Server<unknown>

    const manager = createGracefulShutdownManager({
      server,
      shutdownTimeoutMs: 5_000,
      deps: {
        markShuttingDown: (signal) => calls.push(`mark:${signal}`),
        stopDatabaseMonitor: () => {
          calls.push("monitor.stop")
        },
        stopUserSettingsCleanup: () => {
          calls.push("cache.stop")
        },
        closeConnections: async () => {
          calls.push("connections.close")
          throw new Error("close failed")
        },
        shutdownPresence: async () => {
          calls.push("presence.shutdown")
        },
        shutdownApn: () => {
          calls.push("apn.shutdown")
        },
        closeDatabase: async () => {
          calls.push("db.close")
        },
        flushSentry: async (timeoutMs) => {
          calls.push(`sentry.flush:${timeoutMs}`)
          return true
        },
        setExitCode: (code) => calls.push(`exitCode:${code}`),
        forceExit: (code) => calls.push(`forceExit:${code}`),
        setTimeoutFn: (_handler, timeoutMs) => {
          calls.push(`timer.start:${timeoutMs}`)
          return timerId
        },
        clearTimeoutFn: () => calls.push("timer.clear"),
      },
    })

    await manager.shutdown("SIGTERM")

    expect(calls).toContain("connections.close")
    expect(calls).toContain("presence.shutdown")
    expect(calls).toContain("db.close")
    expect(calls).toContain("sentry.flush:2000")
    expect(calls).toContain("exitCode:1")
    expect(calls).not.toContain("forceExit:1")
  })
})
