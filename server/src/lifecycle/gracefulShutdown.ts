import * as Sentry from "@sentry/bun"
import { closeDb } from "@in/server/db"
import { shutdownApnProvider } from "@in/server/libs/apn"
import { stopUserSettingsCacheCleanup } from "@in/server/modules/cache/userSettings"
import { stopDatabaseHealthMonitor } from "@in/server/modules/monitoring/databaseHealthMonitor"
import { Log } from "@in/server/utils/log"
import { connectionManager } from "@in/server/ws/connections"
import { presenceManager } from "@in/server/ws/presence"
import { markServerShuttingDown, type ShutdownSignal } from "@in/server/lifecycle/shutdownState"
import type { Server } from "bun"

const log = new Log("server.shutdown")

const DEFAULT_SHUTDOWN_TIMEOUT_MS = 25_000
const SENTRY_FLUSH_TIMEOUT_MS = 2_000

type Step = () => void | Promise<void>
type SetTimeoutFn = (handler: () => void, timeout: number) => ReturnType<typeof setTimeout>
type ClearTimeoutFn = (timeoutId: ReturnType<typeof setTimeout>) => void

export type GracefulShutdownDeps = {
  markShuttingDown: (signal: ShutdownSignal) => void
  stopDatabaseMonitor: Step
  stopUserSettingsCleanup: Step
  stopServer: (server: Server<unknown>, closeActiveConnections: boolean) => void
  closeConnections: Step
  shutdownPresence: Step
  shutdownApn: Step
  closeDatabase: Step
  flushSentry: (timeoutMs: number) => Promise<boolean>
  setExitCode: (code: number) => void
  forceExit: (code: number) => void
  setTimeoutFn: SetTimeoutFn
  clearTimeoutFn: ClearTimeoutFn
}

export type GracefulShutdownManager = {
  installSignalHandlers: () => void
  shutdown: (signal: ShutdownSignal) => Promise<void>
}

const sanitizePositiveInt = (value: number | undefined, fallback: number): number => {
  if (!value || !Number.isFinite(value) || value <= 0) {
    return fallback
  }
  return Math.floor(value)
}

const readShutdownTimeoutMs = (): number => {
  const raw = process.env["SHUTDOWN_TIMEOUT_MS"]
  if (!raw) {
    return DEFAULT_SHUTDOWN_TIMEOUT_MS
  }

  return sanitizePositiveInt(Number(raw), DEFAULT_SHUTDOWN_TIMEOUT_MS)
}

const createDefaultDeps = (): GracefulShutdownDeps => ({
  markShuttingDown: markServerShuttingDown,
  stopDatabaseMonitor: () => stopDatabaseHealthMonitor(),
  stopUserSettingsCleanup: () => stopUserSettingsCacheCleanup(),
  stopServer: (server, closeActiveConnections) => server.stop(closeActiveConnections),
  closeConnections: () => connectionManager.shutdown(),
  shutdownPresence: () => presenceManager.shutdown(),
  shutdownApn: () => shutdownApnProvider(),
  closeDatabase: () => closeDb(),
  flushSentry: (timeoutMs) => Sentry.close(timeoutMs),
  setExitCode: (code) => {
    process.exitCode = code
  },
  forceExit: (code) => {
    process.exit(code)
  },
  setTimeoutFn: setTimeout,
  clearTimeoutFn: clearTimeout,
})

const runStep = async (name: string, step: Step): Promise<boolean> => {
  try {
    await step()
    return true
  } catch (error) {
    log.error("Shutdown step failed", { step: name, error })
    return false
  }
}

export const createGracefulShutdownManager = ({
  server,
  shutdownTimeoutMs = readShutdownTimeoutMs(),
  deps,
}: {
  server: Server<unknown>
  shutdownTimeoutMs?: number
  deps?: Partial<GracefulShutdownDeps>
}): GracefulShutdownManager => {
  const runtime: GracefulShutdownDeps = {
    ...createDefaultDeps(),
    ...deps,
  }

  let shutdownPromise: Promise<void> | null = null

  const shutdown = (signal: ShutdownSignal): Promise<void> => {
    if (shutdownPromise) {
      return shutdownPromise
    }

    shutdownPromise = (async () => {
      runtime.markShuttingDown(signal)
      log.warn("Starting graceful shutdown", { signal, timeoutMs: shutdownTimeoutMs })

      const timeoutId = runtime.setTimeoutFn(() => {
        runtime.markShuttingDown("timeout")
        log.error("Graceful shutdown timeout reached; forcing process exit", { timeoutMs: shutdownTimeoutMs })
        runtime.setExitCode(1)
        runtime.forceExit(1)
      }, shutdownTimeoutMs)

      let hasErrors = false

      hasErrors = !(await runStep("stop_database_monitor", runtime.stopDatabaseMonitor)) || hasErrors
      hasErrors = !(await runStep("stop_user_settings_cleanup", runtime.stopUserSettingsCleanup)) || hasErrors
      hasErrors = !(await runStep("stop_server_listener", () => runtime.stopServer(server, false))) || hasErrors
      hasErrors = !(await runStep("close_realtime_connections", runtime.closeConnections)) || hasErrors
      hasErrors = !(await runStep("shutdown_presence", runtime.shutdownPresence)) || hasErrors
      hasErrors = !(await runStep("close_remaining_server_connections", () => runtime.stopServer(server, true))) || hasErrors
      hasErrors = !(await runStep("shutdown_apn", runtime.shutdownApn)) || hasErrors
      hasErrors = !(await runStep("close_database", runtime.closeDatabase)) || hasErrors
      hasErrors =
        !(await runStep("flush_sentry", async () => {
          await runtime.flushSentry(Math.min(SENTRY_FLUSH_TIMEOUT_MS, shutdownTimeoutMs))
        })) || hasErrors

      runtime.clearTimeoutFn(timeoutId)
      runtime.setExitCode(hasErrors ? 1 : 0)

      if (hasErrors) {
        log.error("Graceful shutdown completed with errors")
      } else {
        log.info("Graceful shutdown completed")
      }
    })()

    return shutdownPromise
  }

  const installSignalHandlers = (): void => {
    process.once("SIGTERM", () => {
      void shutdown("SIGTERM")
    })

    process.once("SIGINT", () => {
      void shutdown("SIGINT")
    })
  }

  return {
    installSignalHandlers,
    shutdown,
  }
}

let globalManager: GracefulShutdownManager | null = null

export const registerGracefulShutdown = (server: Server<unknown>): GracefulShutdownManager => {
  if (globalManager) {
    return globalManager
  }

  const manager = createGracefulShutdownManager({ server })
  manager.installSignalHandlers()
  globalManager = manager
  return manager
}

export const resetGracefulShutdownForTests = (): void => {
  globalManager = null
}
