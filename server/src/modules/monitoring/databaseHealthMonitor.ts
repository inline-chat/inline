import { runHealthChecks, type HealthResponse } from "@in/server/controllers/health"
import { NODE_ENV } from "@in/server/env"
import { sendBotEvent } from "@in/server/modules/bot-events"
import { Log } from "@in/server/utils/log"
import os from "node:os"

const log = new Log("monitoring.databaseHealth")

const DEFAULT_POLL_INTERVAL_MS = 30_000
const DEFAULT_ALERT_COOLDOWN_MS = 15 * 60 * 1000
const DEFAULT_FAILURE_THRESHOLD = 2

type HealthRunner = () => Promise<Pick<HealthResponse, "ok" | "checks">>
type AlertSender = (message: string) => void
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
  healthRunner: options.healthRunner ?? runHealthChecks,
  alertSender: options.alertSender ?? sendBotEvent,
  now: options.now ?? Date.now,
  setIntervalFn: options.setIntervalFn ?? setInterval,
  clearIntervalFn: options.clearIntervalFn ?? clearInterval,
})

export class DatabaseHealthMonitor {
  private intervalId: ReturnType<typeof setInterval> | null = null
  private inFlight = false
  private consecutiveFailures = 0
  private downSinceMs: number | null = null
  private lastAlertAtMs: number | null = null
  private readonly runtime: MonitorRuntimeOptions

  constructor(options: DatabaseHealthMonitorOptions = {}) {
    this.runtime = createRuntimeOptions(options)
  }

  start(): void {
    if (this.intervalId) {
      return
    }

    this.intervalId = this.runtime.setIntervalFn(() => {
      void this.pollOnce()
    }, this.runtime.pollIntervalMs)

    void this.pollOnce()
  }

  stop(): void {
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

    try {
      const result = await this.readHealth()
      if (result.ok && result.checks.database.ok) {
        this.handleHealthy()
      } else {
        this.handleUnhealthy(result.checks.database.error ?? "database_unavailable")
      }
    } finally {
      this.inFlight = false
    }
  }

  private async readHealth(): Promise<Pick<HealthResponse, "ok" | "checks">> {
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

  private handleHealthy(): void {
    if (this.downSinceMs !== null) {
      const recoveredAt = this.runtime.now()
      const duration = formatDuration(recoveredAt - this.downSinceMs)
      this.notify(`DB RECOVERED on ${NODE_ENV}@${os.hostname()} after ${duration}.`)
    }

    this.consecutiveFailures = 0
    this.downSinceMs = null
    this.lastAlertAtMs = null
  }

  private handleUnhealthy(errorCode: string): void {
    this.consecutiveFailures += 1

    if (this.consecutiveFailures < this.runtime.failureThreshold) {
      return
    }

    const now = this.runtime.now()
    if (this.downSinceMs === null) {
      this.downSinceMs = now
      this.lastAlertAtMs = now
      this.notify(
        `DB DOWN on ${NODE_ENV}@${os.hostname()} (failures=${this.consecutiveFailures}, error=${errorCode}).`,
      )
      return
    }

    if (this.lastAlertAtMs === null || now - this.lastAlertAtMs >= this.runtime.alertCooldownMs) {
      this.lastAlertAtMs = now
      const duration = formatDuration(now - this.downSinceMs)
      this.notify(
        `DB STILL DOWN on ${NODE_ENV}@${os.hostname()} for ${duration} (error=${errorCode}, failures=${this.consecutiveFailures}).`,
      )
    }
  }

  private notify(message: string): void {
    try {
      this.runtime.alertSender(message)
    } catch (error) {
      log.error("Failed to send DB health alert", { error })
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

export const stopDatabaseHealthMonitor = (): void => {
  if (!monitorInstance) {
    return
  }

  monitorInstance.stop()
  monitorInstance = null
  log.info("Stopped DB health monitor")
}
