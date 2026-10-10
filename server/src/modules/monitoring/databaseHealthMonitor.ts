import {
  makeHealthChecker,
  type HealthResponse,
} from "@in/server/controllers/healthCheck"
import { NODE_ENV } from "@in/server/env"
import { createTelegramAlertSender } from "./telegramAlerts"
import { Log } from "@in/server/utils/log"
import os from "node:os"

const log = new Log("monitoring.databaseHealth")

const DEFAULT_POLL_INTERVAL_MS = 30_000
const DEFAULT_ALERT_COOLDOWN_MS = 15 * 60 * 1000
const DEFAULT_FAILURE_THRESHOLD = 2

type HealthRunner = () => Promise<{
  readonly ok: boolean
  readonly checks: {
    readonly database: HealthResponse["checks"]["database"]
    readonly clock?: HealthResponse["checks"]["clock"]
  }
}>
type AlertSender = (message: string) => void | Promise<void>
type NowFn = () => number
type SetIntervalFn = (handler: () => void, timeout: number) => ReturnType<typeof setInterval>
type ClearIntervalFn = (id: ReturnType<typeof setInterval>) => void

export type DatabaseHealthMonitorOptions = {
  pollIntervalMs?: number
  alertCooldownMs?: number
  failureThreshold?: number
  healthRunner?: HealthRunner
  alertSender?: AlertSender
  now?: NowFn
  setIntervalFn?: SetIntervalFn
  clearIntervalFn?: ClearIntervalFn
}

type MonitorRuntimeOptions = {
  pollIntervalMs: number
  alertCooldownMs: number
  failureThreshold: number
  healthRunner: HealthRunner
  alertSender: AlertSender
  now: NowFn
  setIntervalFn: SetIntervalFn
  clearIntervalFn: ClearIntervalFn
}

const sanitizePositiveInt = (value: number | undefined, fallback: number): number => {
  if (!value || !Number.isFinite(value) || value <= 0) {
    return fallback
  }
  return Math.floor(value)
}

const parseEnvPositiveInt = (raw: string | undefined, fallback: number): number => {
  if (!raw) return fallback
  return sanitizePositiveInt(Number(raw), fallback)
}

const formatDuration = (milliseconds: number): string => {
  const totalSeconds = Math.max(0, Math.floor(milliseconds / 1000))
  if (totalSeconds < 60) {
    return `${totalSeconds}s`
  }

  const totalMinutes = Math.floor(totalSeconds / 60)
  const seconds = totalSeconds % 60
  if (totalMinutes < 60) {
    return `${totalMinutes}m ${seconds}s`
  }

  const hours = Math.floor(totalMinutes / 60)
  const minutes = totalMinutes % 60
  return `${hours}h ${minutes}m`
}

const createRuntimeOptions = (options: DatabaseHealthMonitorOptions = {}): MonitorRuntimeOptions => ({
  pollIntervalMs: sanitizePositiveInt(options.pollIntervalMs, DEFAULT_POLL_INTERVAL_MS),
  alertCooldownMs: sanitizePositiveInt(options.alertCooldownMs, DEFAULT_ALERT_COOLDOWN_MS),
  failureThreshold: sanitizePositiveInt(options.failureThreshold, DEFAULT_FAILURE_THRESHOLD),
  healthRunner: options.healthRunner ?? makeHealthChecker(),
  alertSender: options.alertSender ?? createTelegramAlertSender(),
  now: options.now ?? Date.now,
  setIntervalFn: options.setIntervalFn ?? setInterval,
  clearIntervalFn: options.clearIntervalFn ?? clearInterval,
})

export class DatabaseHealthMonitor {
  private intervalId: ReturnType<typeof setInterval> | null = null
  private generation = 0
  private inFlight = false
  private consecutiveFailures = 0
  private downSinceMs: number | null = null
  private downErrorCode: string | null = null
  private lastAlertAtMs: number | null = null
  private lastClockWarningAtMs: number | null = null
  // Coalesce repeated recoveries while delivery is unavailable, retaining the
  // latest recovery and count without an unbounded notification queue.
  private pendingRecovery: { message: string; count: number } | null = null
  private readonly runtime: MonitorRuntimeOptions

  constructor(options: DatabaseHealthMonitorOptions = {}) {
    this.runtime = createRuntimeOptions(options)
  }

  start(): void {
    if (this.intervalId) {
      return
    }

    this.generation += 1
    this.intervalId = this.runtime.setIntervalFn(() => {
      void this.pollOnce()
    }, this.runtime.pollIntervalMs)

    void this.pollOnce()
  }

  stop(): void {
    this.generation += 1
    if (!this.intervalId) {
      return
    }

    this.runtime.clearIntervalFn(this.intervalId)
    this.intervalId = null
  }

  async pollOnce(): Promise<void> {
    if (this.inFlight) {
      return
    }

    this.inFlight = true
    const generation = this.generation

    try {
      const result = await this.readHealth()
      if (generation !== this.generation) return
      if (result.checks.clock?.status === "warning") {
        await this.handleClockWarning(result.checks.clock.warning ?? "clock_offset_warning", generation)
      }
      if (generation !== this.generation) return
      if (result.ok && result.checks.database.ok) {
        await this.handleHealthy(generation)
      } else {
        await this.handleUnhealthy(
          result.checks.database.error ??
          result.checks.clock?.error ??
          "database_unavailable",
          generation,
        )
      }
    } finally {
      this.inFlight = false
    }
  }

  private async readHealth(): Promise<Awaited<ReturnType<HealthRunner>>> {
    try {
      return await this.runtime.healthRunner()
    } catch (error) {
      log.error("Database monitor health runner failed", { error })
      return {
        ok: false,
        checks: {
          database: {
            ok: false,
            latencyMs: 0,
            error: "database_unavailable",
          },
        },
      }
    }
  }

  private async handleHealthy(generation: number): Promise<void> {
    if (this.downSinceMs !== null) {
      const recoveredAt = this.runtime.now()
      const duration = formatDuration(recoveredAt - this.downSinceMs)
      const clockFailure = this.downErrorCode?.startsWith("clock_") ?? false
      log.info(clockFailure ? "Server clock health recovered" : "Database health recovered", {
        consecutiveFailures: this.consecutiveFailures,
        downtimeMs: recoveredAt - this.downSinceMs,
      })
      this.pendingRecovery = {
        message: `${clockFailure ? "CLOCK RECOVERED" : "DB RECOVERED"} on ${NODE_ENV}@${os.hostname()} after ${duration}.`,
        count: Math.min((this.pendingRecovery?.count ?? 0) + 1, Number.MAX_SAFE_INTEGER),
      }
    }

    this.consecutiveFailures = 0
    this.downSinceMs = null
    this.downErrorCode = null
    this.lastAlertAtMs = null
    await this.deliverPendingRecovery(generation)
  }

  private async handleClockWarning(warningCode: string, generation: number): Promise<void> {
    const now = this.runtime.now()
    if (
      this.lastClockWarningAtMs !== null &&
      now - this.lastClockWarningAtMs < this.runtime.alertCooldownMs
    ) return

    log.warn("Server clock warning", { warningCode })
    if (await this.notify(`CLOCK WARNING on ${NODE_ENV}@${os.hostname()} (${warningCode}).`, generation)) {
      this.lastClockWarningAtMs = this.runtime.now()
    }
  }

  private async handleUnhealthy(errorCode: string, generation: number): Promise<void> {
    this.consecutiveFailures += 1
    const now = this.runtime.now()
    if (this.downSinceMs === null && this.consecutiveFailures >= this.runtime.failureThreshold) {
      this.downSinceMs = now
      this.downErrorCode = errorCode
      const clockFailure = errorCode.startsWith("clock_")
      log.error(clockFailure ? "Server clock safety threshold reached" : "Database health threshold reached", {
        consecutiveFailures: this.consecutiveFailures,
        errorCode,
      })
    }

    // Deliver an earlier recovery before announcing a new outage. Keep reading
    // health and recording thresholds even while that delivery is retried.
    if (!await this.deliverPendingRecovery(generation) || this.downSinceMs === null) return

    if (this.lastAlertAtMs === null) {
      const clockFailure = this.downErrorCode?.startsWith("clock_") ?? false
      if (await this.notify(
        `${clockFailure ? "CLOCK UNSAFE" : "DB DOWN"} on ${NODE_ENV}@${os.hostname()} (failures=${this.consecutiveFailures}, error=${errorCode}).`,
        generation,
      )) this.lastAlertAtMs = this.runtime.now()
      return
    }

    if (now - this.lastAlertAtMs >= this.runtime.alertCooldownMs) {
      const duration = formatDuration(now - this.downSinceMs)
      log.warn(errorCode.startsWith("clock_") ? "Server clock remains unsafe" : "Database remains unhealthy", {
        consecutiveFailures: this.consecutiveFailures,
        downtimeMs: now - this.downSinceMs,
        errorCode,
      })
      if (await this.notify(
        `${errorCode.startsWith("clock_") ? "CLOCK STILL UNSAFE" : "DB STILL DOWN"} on ${NODE_ENV}@${os.hostname()} for ${duration} (error=${errorCode}, failures=${this.consecutiveFailures}).`,
        generation,
      )) this.lastAlertAtMs = this.runtime.now()
    }
  }

  private async deliverPendingRecovery(generation: number): Promise<boolean> {
    const pending = this.pendingRecovery
    if (!pending) return true
    const message = pending.count > 1
      ? `${pending.message} (${pending.count} recoveries observed while alert delivery was unavailable.)`
      : pending.message
    if (!await this.notify(message, generation)) return false
    this.pendingRecovery = null
    return true
  }

  private async notify(message: string, generation: number): Promise<boolean> {
    if (generation !== this.generation) return false
    try {
      await this.runtime.alertSender(message)
      return true
    } catch {
      log.warn("DB health alert delivery failed; will retry on a later poll")
      return false
    }
  }
}

let monitorInstance: DatabaseHealthMonitor | null = null

const shouldStartDatabaseMonitor = (): boolean => {
  if (NODE_ENV === "production") {
    return true
  }

  return process.env["ENABLE_DATABASE_HEALTH_MONITOR"] === "1"
}

export const startDatabaseHealthMonitor = (): DatabaseHealthMonitor | null => {
  if (!shouldStartDatabaseMonitor()) {
    return null
  }

  if (monitorInstance) {
    return monitorInstance
  }

  const monitor = new DatabaseHealthMonitor({
    pollIntervalMs: parseEnvPositiveInt(process.env["DB_HEALTH_MONITOR_INTERVAL_MS"], DEFAULT_POLL_INTERVAL_MS),
    alertCooldownMs: parseEnvPositiveInt(process.env["DB_HEALTH_ALERT_COOLDOWN_MS"], DEFAULT_ALERT_COOLDOWN_MS),
    failureThreshold: parseEnvPositiveInt(
      process.env["DB_HEALTH_ALERT_FAILURE_THRESHOLD"],
      DEFAULT_FAILURE_THRESHOLD,
    ),
  })

  monitor.start()
  monitorInstance = monitor
  log.info("Started DB health monitor", {
    intervalMs: parseEnvPositiveInt(process.env["DB_HEALTH_MONITOR_INTERVAL_MS"], DEFAULT_POLL_INTERVAL_MS),
    alertCooldownMs: parseEnvPositiveInt(process.env["DB_HEALTH_ALERT_COOLDOWN_MS"], DEFAULT_ALERT_COOLDOWN_MS),
    failureThreshold: parseEnvPositiveInt(
      process.env["DB_HEALTH_ALERT_FAILURE_THRESHOLD"],
      DEFAULT_FAILURE_THRESHOLD,
    ),
  })
  return monitor
}

export const stopDatabaseHealthMonitor = (
  monitor: DatabaseHealthMonitor | null =
    monitorInstance,
): void => {
  if (!monitor) {
    return
  }

  monitor.stop()
  if (monitorInstance === monitor) {
    monitorInstance = null
  }
  log.info("Stopped DB health monitor")
}
