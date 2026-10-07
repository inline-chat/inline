import { randomUUID } from "node:crypto"
import { fileURLToPath } from "node:url"
import { LEASE_MS, RUN_DURATION_MS, WorkerControlClient, RunControlClient, type ClaimedRun } from "./api.js"
import { TranscriptionError, type Model } from "./protocol.js"
import { SileroModel } from "./silero.js"
import { NativeRoomSupervisor, type NativeExitReceipt, type StopReason } from "./supervisor.js"
import { monotonicMilliseconds } from "./watchdog.js"

export type WorkerConfig = Readonly<{ apiBaseUrl: string; sharedSecret: string; workerId: string; model: Model; apiKey?: string }>
export function workerConfig(environment: Readonly<Record<string, string | undefined>>): WorkerConfig {
  const model = environment.GRID_TRANSCRIPTION_MODEL ?? "meeting"
  if (model !== "meeting" && model !== "standard") throw new TranscriptionError("protocol")
  const apiBaseUrl = environment.GRID_TRANSCRIPTION_API_URL
  const sharedSecret = environment.GRID_TRANSCRIPTION_WORKER_SECRET
  const label = environment.GRID_TRANSCRIPTION_WORKER_ID ?? "grid-worker"
  const apiKey = model === "meeting" ? environment.SONIOX_API_KEY : environment.OPENAI_API_KEY
  if (!apiBaseUrl || !sharedSecret || sharedSecret.length > 4096 || /[\r\n]/.test(sharedSecret)
    || !/^[a-zA-Z0-9_-]{1,40}$/.test(label)
    || (apiKey !== undefined && (apiKey.length > 4096 || /[\r\n]/.test(apiKey)))) throw new TranscriptionError("protocol")
  // Every boot gets distinct authority. Only transport retries within this boot may reclaim its lost claim response.
  return Object.freeze({ apiBaseUrl, sharedSecret, workerId: `${label}-${randomUUID()}`, model,
    ...(apiKey ? { apiKey } : {}) })
}

type OwnedRun = { run?: ClaimedRun; api: RunControlClient; expiresAtMs: number; exit?: Promise<NativeExitReceipt>;
  reported: Promise<void>; stopReason?: string; acknowledging?: Promise<boolean>; renewing: boolean }
export class WorkerDaemon {
  private readonly control: WorkerControlClient
  private readonly supervisor: NativeRoomSupervisor
  private current: OwnedRun | undefined
  private polling = false
  private claimPromise: Promise<void> | undefined
  private claimUncertain = false
  private heartbeating = false
  private closing = false
  private ready = false
  private claimTimer: NodeJS.Timeout | undefined
  private heartbeatTimer: NodeJS.Timeout | undefined
  private renewTimer: NodeJS.Timeout | undefined
  private shutdownPromise: Promise<void> | undefined

  constructor(private readonly config: WorkerConfig) {
    this.control = new WorkerControlClient(config.apiBaseUrl, config.sharedSecret, config.workerId)
    this.supervisor = new NativeRoomSupervisor({ roomChildPath: new URL("./room-child.js", import.meta.url),
      // Secrets arrive only over IPC. Avoid inherited debug flags, NODE_OPTIONS and credential environment.
      environment: { NODE_ENV: "production" } })
  }
  async start(): Promise<void> {
    // Verify the vendored tensor contract and native runtime before advertising capture availability.
    const model = await SileroModel.load()
    await model.close()
    if (this.closing) return
    this.ready = !!this.config.apiKey
    await this.heartbeat()
    this.claimTimer = setInterval(() => { void this.claim() }, 2000)
    this.heartbeatTimer = setInterval(() => { void this.heartbeat() }, 5000)
    this.renewTimer = setInterval(() => { void this.renew() }, 1000)
    await this.claim()
  }
  private async heartbeat(): Promise<void> {
    if (this.heartbeating) return
    this.heartbeating = true
    try { await this.control.heartbeat(this.config.model, this.ready && !this.closing) }
    catch {
      // API loss removes availability and revokes any native owner immediately.
      if (this.current && this.supervisor.hasActiveChild) void this.stopCurrent("authority").catch(() => undefined)
    } finally {
      const owned = this.current
      if (owned?.stopReason) await this.acknowledgeStopped(owned)
      this.heartbeating = false
    }
  }
  private async claim(): Promise<void> {
    if (this.closing || !this.ready || this.polling || this.current || this.supervisor.hasActiveChild) return
    this.polling = true
    const operation = this.performClaim()
    this.claimPromise = operation
    try { await operation } finally {
      if (this.claimPromise === operation) this.claimPromise = undefined
      this.polling = false
    }
  }
  private async performClaim(): Promise<void> {
    try {
      const requestedAtMs = monotonicMilliseconds()
      const requestedAtWallMs = Date.now()
      this.claimUncertain = true
      const run = await this.control.claim()
      this.claimUncertain = false
      if (!run) return
      const api = new RunControlClient(this.config.apiBaseUrl, run.runToken)
      if ("stopImmediately" in run) {
        const owned: OwnedRun = { api, expiresAtMs: 0, reported: Promise.resolve(), renewing: false, stopReason: "authority" }
        this.current = owned
        owned.reported = this.acknowledgeStopped(owned).then(() => undefined)
        await owned.reported
        return
      }
      const expiresAtMs = Math.min(requestedAtMs + RUN_DURATION_MS,
        requestedAtMs + Date.parse(run.expiresAt) - requestedAtWallMs)
      const owned: OwnedRun = { run, api, expiresAtMs, reported: Promise.resolve(), renewing: false }
      this.current = owned
      if (this.closing || run.model !== this.config.model || !this.config.apiKey) {
        // No native transport has been allocated. This is a truthful no-child receipt.
        owned.stopReason = "configuration"
        owned.reported = this.acknowledgeStopped(owned).then(() => undefined)
        await owned.reported
        return
      }
      const identity = { runId: run.runId, claimEpoch: run.claimEpoch, generation: run.generation }
      const ready = this.supervisor.start({ identity, requestedAtMs, leaseMs: run.leaseMs, expiresAtMs,
        payload: { run, apiBaseUrl: this.config.apiBaseUrl, apiKey: this.config.apiKey, expiresAtMs } })
      const exit = this.supervisor.exitReceipt
      if (!exit) throw new TranscriptionError("protocol")
      owned.exit = exit
      owned.reported = this.observeExit(owned)
      await ready
    } catch {
      if (this.supervisor.hasActiveChild) void this.stopCurrent("authority").catch(() => undefined)
      else if (this.current && !this.current.exit) {
        const owned = this.current
        owned.stopReason = "startup"
        owned.reported = this.acknowledgeStopped(owned).then(() => undefined)
        await owned.reported
      }
    }
  }
  private async renew(): Promise<void> {
    const owned = this.current
    const run = owned?.run
    if (!owned || !run || owned.renewing || !this.supervisor.admitting || this.closing) return
    owned.renewing = true
    try {
      const requestedAtMs = monotonicMilliseconds()
      const requestedAtWallMs = Date.now()
      const renewed = await owned.api.renew()
      if (this.current !== owned || !this.supervisor.admitting || this.closing) return
      if (renewed.state !== "active") {
        await this.stopCurrent(renewed.state === "stopping" && renewed.allowFinalFlush ? "stopping" : "authority")
        return
      }
      const leaseMs = Math.min(LEASE_MS, Date.parse(renewed.leaseExpiresAt) - requestedAtWallMs)
      if (!Number.isSafeInteger(leaseMs) || leaseMs <= 0) throw new TranscriptionError("expired")
      this.supervisor.renew({ runId: run.runId, claimEpoch: run.claimEpoch, generation: run.generation },
        requestedAtMs, leaseMs, { participants: renewed.participants })
    } catch { if (this.current === owned) await this.stopCurrent("authority").catch(() => undefined) }
    finally { owned.renewing = false }
  }
  private async stopCurrent(reason: StopReason): Promise<void> {
    if (!this.current || !this.supervisor.hasActiveChild) return
    // This call closes the synchronous supervisor admission fence before waiting.
    await this.supervisor.stop(reason)
  }
  private async observeExit(owned: OwnedRun): Promise<void> {
    try {
      const receipt = await owned.exit
      if (!receipt) throw new TranscriptionError("protocol")
      // An OS receipt from the watchdog proves real native transport containment.
      // Server acknowledgement is idempotent and is required before this daemon claims another run.
      owned.stopReason = receipt.reason
      await this.acknowledgeStopped(owned)
    } catch {
      // Unknown exit keeps both the process slot and this run quarantined.
      this.ready = false
      await this.heartbeat()
    }
  }
  private async acknowledgeStopped(owned: OwnedRun): Promise<boolean> {
    if (!owned.stopReason) return false
    if (owned.acknowledging) return owned.acknowledging
    const operation = (async () => {
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          await owned.api.stopped(owned.stopReason!)
          if (this.current === owned) this.current = undefined
          this.ready = !!this.config.apiKey && !this.closing
          return true
        } catch { /* Retain the same known receipt for the existing heartbeat cadence. */ }
      }
      this.ready = false
      return false
    })()
    owned.acknowledging = operation
    try { return await operation } finally { if (owned.acknowledging === operation) owned.acknowledging = undefined }
  }
  shutdown(): Promise<void> {
    if (this.shutdownPromise) return this.shutdownPromise
    this.closing = true
    this.ready = false
    clearInterval(this.claimTimer)
    clearInterval(this.heartbeatTimer)
    clearInterval(this.renewTimer)
    this.shutdownPromise = this.finishShutdown()
    return this.shutdownPromise
  }
  private async finishShutdown(): Promise<void> {
    await this.heartbeat()
    // A claim already sent can allocate server authority before its response arrives.
    // Stop an already-known native owner now, then wait for the claim's late no-child receipt.
    if (this.current && this.supervisor.hasActiveChild) void this.stopCurrent("shutdown").catch(() => undefined)
    await this.claimPromise
    if (this.claimUncertain && !this.current && !this.supervisor.hasActiveChild) {
      // Only this boot's existing claim can be recovered after ready=false.
      // The API refuses new allocation to an unavailable worker.
      for (let attempt = 0; attempt < 2 && this.claimUncertain && !this.current; attempt++) await this.performClaim()
      if (this.claimUncertain) throw new TranscriptionError("provider")
    }
    const owned = this.current
    if (owned && this.supervisor.hasActiveChild) await this.stopCurrent("shutdown")
    if (owned) {
      await owned.exit
      await owned.reported
      if (this.current === owned) throw new TranscriptionError("provider")
    }
  }
}

export async function runDaemon(): Promise<void> {
  try {
    const daemon = new WorkerDaemon(workerConfig(process.env))
    process.on("SIGTERM", () => { void daemon.shutdown().then(() => process.exit(0)).catch(() => process.exit(1)) })
    process.on("SIGINT", () => { void daemon.shutdown().then(() => process.exit(0)).catch(() => process.exit(1)) })
    await daemon.start()
    // Coarse state only. No provider errors, room metadata, audio, text or credentials are logged.
    process.stdout.write("Grid transcription worker initialized\n")
  } catch {
    process.stderr.write("Grid transcription worker unavailable\n")
    process.exitCode = 1
  }
}
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) void runDaemon()
