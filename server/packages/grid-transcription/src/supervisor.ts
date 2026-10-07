import { fork, type ChildProcess } from "node:child_process"
import { fileURLToPath } from "node:url"
import type { CaptureIdentity } from "./authority.js"
import { monotonicMilliseconds, sameIdentity, validIdentity, validStopReason, WatchdogLease } from "./watchdog.js"
import type { ChildErrorCode, NativeExitReceipt, StopReason, WatchdogCommand, WatchdogMessage, WatchdogTimings } from "./watchdog.js"

export type { RoomChildCommand, RoomChildMessage, NativeExitReceipt, StopReason } from "./watchdog.js"
export type NativeRoomStart = Readonly<{
  identity: CaptureIdentity; requestedAtMs: number; leaseMs: number; expiresAtMs: number; payload: unknown;
}>
export type NativeReadyReceipt = Readonly<{ identity: CaptureIdentity; pid: number }>
export type NativeRoomSupervisorOptions = Readonly<{
  roomChildPath: string | URL; environment: Readonly<Record<string, string>>; watchdogPath?: string | URL;
  heartbeatIntervalMs?: number; heartbeatTimeoutMs?: number; stoppingGraceMs?: number; authorityGraceMs?: number;
  termGraceMs?: number; killExitTimeoutMs?: number; startupTimeoutMs?: number;
}>
export class SupervisionError extends Error {
  constructor(readonly code: ChildErrorCode | "exit_unconfirmed" | "watchdog") {
    super(`Grid transcription supervision ${code}`)
    this.name = "SupervisionError"
  }
}
type Deferred<T> = Readonly<{ promise: Promise<T>; resolve: (value: T) => void; reject: (error: SupervisionError) => void }>
function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void
  let reject!: (error: SupervisionError) => void
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no })
  // Exit may be observed after spontaneous failure without a caller awaiting stop.
  void promise.catch(() => undefined)
  return { promise, resolve, reject }
}
type ActiveRoom = {
  identity: CaptureIdentity; watchdog: ChildProcess; lease: WatchdogLease;
  ready: Deferred<NativeReadyReceipt>; exit: Deferred<NativeExitReceipt>;
  timer?: NodeJS.Timeout; readyReceived: boolean; admission: boolean; receipt?: NativeExitReceipt;
}
const defaults: WatchdogTimings = {
  heartbeatTimeoutMs: 1_500, stoppingGraceMs: 5_000, authorityGraceMs: 50,
  termGraceMs: 250, killExitTimeoutMs: 1_000, startupTimeoutMs: 10_000,
}
function path(value: string | URL): string { return typeof value === "string" ? value : fileURLToPath(value) }
function object(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined
}
function parseMessage(value: unknown, identity: CaptureIdentity): WatchdogMessage | undefined {
  const message = object(value)
  if (message?.type === "ready" && Number.isSafeInteger(message.pid) && Number(message.pid) > 0) {
    return { type: "ready", pid: Number(message.pid) }
  }
  if (message?.type === "error" && typeof message.code === "string"
    && ["protocol", "provider", "overflow", "stopped", "expired", "audio", "native", "api", "internal", "exit_unconfirmed", "watchdog"].includes(message.code)) {
    return { type: "error", code: message.code as SupervisionError["code"] }
  }
  const receipt = object(message?.receipt)
  if (message?.type !== "exit" || !receipt || !validIdentity(receipt.identity) || !sameIdentity(identity, receipt.identity)
    || !Number.isSafeInteger(receipt.pid) || Number(receipt.pid) <= 0
    || !(receipt.code === null || Number.isInteger(receipt.code))
    || !(receipt.signal === null || typeof receipt.signal === "string")
    || !(receipt.reason === "exited" || validStopReason(receipt.reason))
    || typeof receipt.hardKilled !== "boolean" || !Number.isSafeInteger(receipt.exitedAtMs)) return undefined
  return { type: "exit", receipt: { identity: receipt.identity, pid: Number(receipt.pid),
    code: receipt.code as number | null, signal: receipt.signal as NodeJS.Signals | null,
    reason: receipt.reason, hardKilled: receipt.hardKilled, exitedAtMs: Number(receipt.exitedAtMs) } }
}
function validatePayload(payload: unknown): void {
  // Validate JSON IPC before allocating a child; never log or echo the serialized value.
  try { const encoded = JSON.stringify(payload); if (encoded !== undefined && Buffer.byteLength(encoded) > 256 * 1024) throw new Error() }
  catch { throw new SupervisionError("protocol") }
}

export class NativeRoomSupervisor {
  private active: ActiveRoom | undefined
  private readonly timings: WatchdogTimings
  private readonly heartbeatIntervalMs: number
  constructor(private readonly options: NativeRoomSupervisorOptions) {
    this.timings = { heartbeatTimeoutMs: options.heartbeatTimeoutMs ?? defaults.heartbeatTimeoutMs,
      stoppingGraceMs: options.stoppingGraceMs ?? defaults.stoppingGraceMs,
      authorityGraceMs: options.authorityGraceMs ?? defaults.authorityGraceMs,
      termGraceMs: options.termGraceMs ?? defaults.termGraceMs,
      killExitTimeoutMs: options.killExitTimeoutMs ?? defaults.killExitTimeoutMs,
      startupTimeoutMs: options.startupTimeoutMs ?? defaults.startupTimeoutMs }
    this.heartbeatIntervalMs = options.heartbeatIntervalMs ?? 250
    if (!Object.values(this.timings).every((value) => Number.isSafeInteger(value) && value >= 0 && value <= 30_000)
      || this.timings.heartbeatTimeoutMs <= 0 || this.timings.killExitTimeoutMs <= 0 || this.timings.startupTimeoutMs <= 0
      || !Number.isSafeInteger(this.heartbeatIntervalMs) || this.heartbeatIntervalMs <= 0
      || this.heartbeatIntervalMs >= this.timings.heartbeatTimeoutMs
      || !Object.entries(options.environment).every(([key, value]) => /^[A-Z_][A-Z0-9_]*$/.test(key) && typeof value === "string"
        && key !== "NODE_OPTIONS" && key !== "NODE_PATH")) throw new SupervisionError("protocol")
  }
  get hasActiveChild(): boolean { return this.active !== undefined }
  get admitting(): boolean { return this.active?.admission ?? false }
  get exitReceipt(): Promise<NativeExitReceipt> | undefined { return this.active?.exit.promise }

  start(input: NativeRoomStart): Promise<NativeReadyReceipt> {
    if (this.active) throw new SupervisionError("stopped")
    validatePayload(input.payload)
    let lease: WatchdogLease
    try { lease = new WatchdogLease(Object.freeze({ ...input.identity }), input.requestedAtMs, input.leaseMs, input.expiresAtMs) }
    catch { throw new SupervisionError("expired") }
    const watchdog = fork(path(this.options.watchdogPath ?? new URL("./watchdog.js", import.meta.url)), [], {
      execPath: process.execPath, execArgv: [], env: {}, stdio: ["ignore", "ignore", "ignore", "ipc"], serialization: "json",
    })
    const active: ActiveRoom = { identity: lease.identity, watchdog, lease, ready: deferred(), exit: deferred(),
      readyReceived: false, admission: true }
    this.active = active
    watchdog.on("message", (value: unknown) => {
      const message = parseMessage(value, active.identity)
      if (!message) { this.fail(active, "protocol"); return }
      if (message.type === "ready") {
        if (!active.admission || active.readyReceived) return
        try { active.lease.assertCurrent() } catch { this.fail(active, "expired"); return }
        active.readyReceived = true
        active.ready.resolve({ identity: active.identity, pid: message.pid })
      } else if (message.type === "error") this.fail(active, message.code)
      else {
        active.receipt = message.receipt
        this.send(active, { type: "ack_exit", identity: active.identity, pid: message.receipt.pid })
        active.admission = false
        active.lease.stop()
        clearInterval(active.timer)
        if (!active.readyReceived) active.ready.reject(new SupervisionError("stopped"))
        active.exit.resolve(message.receipt)
        if (this.active === active) this.active = undefined
      }
    })
    watchdog.on("error", () => {
      this.fail(active, "watchdog")
      clearInterval(active.timer)
      active.exit.reject(new SupervisionError("exit_unconfirmed"))
      // Spawn failure can emit error without exit. Keep the slot fenced, but never hang its caller.
    })
    watchdog.once("disconnect", () => {
      // Let already-buffered IPC receipts drain before classifying a bare channel closure.
      setImmediate(() => { if (!active.receipt) this.transportFailed(active) })
    })
    watchdog.once("close", () => {
      clearInterval(active.timer)
      if (active.receipt) return
      active.admission = false
      active.lease.stop()
      const failure = new SupervisionError("exit_unconfirmed")
      active.ready.reject(failure)
      active.exit.reject(failure)
      // Keep the occupied slot: watchdog death alone does not prove native exit.
    })
    active.timer = setInterval(() => {
      if (active.receipt) return
      this.send(active, { type: "heartbeat", sentAtMs: monotonicMilliseconds() })
    }, this.heartbeatIntervalMs)
    this.send(active, { type: "start", childPath: path(this.options.roomChildPath), environment: this.options.environment,
      ...input, identity: active.identity, timings: this.timings })
    return active.ready.promise
  }
  renew(identity: CaptureIdentity, requestedAtMs: number, leaseMs: number, payload?: unknown): void {
    const active = this.active
    if (!active || !active.admission) throw new SupervisionError("stopped")
    validatePayload(payload)
    try {
      if (!active.lease.renew(identity, requestedAtMs, leaseMs)) return
    } catch { this.fail(active, "expired"); throw new SupervisionError("expired") }
    this.send(active, { type: "renew", identity, requestedAtMs, leaseMs, payload })
  }
  stop(reason: StopReason = "authority"): Promise<NativeExitReceipt> {
    const active = this.active
    if (!active) return Promise.reject(new SupervisionError("stopped"))
    if (!validStopReason(reason)) return Promise.reject(new SupervisionError("protocol"))
    // Synchronous parent admission barrier, followed by the child's IPC barrier.
    active.admission = false
    active.lease.stop()
    this.send(active, { type: "stop", reason })
    return active.exit.promise
  }
  private fail(active: ActiveRoom, code: SupervisionError["code"]): void {
    if (active.receipt) return
    active.admission = false
    active.lease.stop()
    active.ready.reject(new SupervisionError(code))
    if (code === "exit_unconfirmed") active.exit.reject(new SupervisionError(code))
    this.send(active, { type: "stop", reason: "authority" })
  }
  private send(active: ActiveRoom, message: WatchdogCommand): void {
    if (!active.watchdog.connected) { if (!active.receipt) this.transportFailed(active); return }
    try { active.watchdog.send(message, (error) => { if (error && !active.receipt) this.transportFailed(active) }) }
    catch { this.transportFailed(active) }
  }
  private transportFailed(active: ActiveRoom): void {
    if (active.receipt) return
    active.admission = false
    active.lease.stop()
    active.ready.reject(new SupervisionError("watchdog"))
    active.exit.reject(new SupervisionError("exit_unconfirmed"))
    clearInterval(active.timer)
    // Closing the control channel makes the independent watchdog stop its owned child.
    // Without that channel, its later OS exit cannot substitute for a native exit receipt.
    if (active.watchdog.connected) { try { active.watchdog.disconnect() } catch { /* Already disconnected. */ } }
  }
}
