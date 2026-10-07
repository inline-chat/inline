import { fork, type ChildProcess } from "node:child_process"
import { realpathSync } from "node:fs"
import { fileURLToPath } from "node:url"
import type { CaptureIdentity } from "./authority.js"

// hrtime is the system monotonic clock, shared by processes on Linux and macOS.
export function monotonicMilliseconds(): number { return Number(process.hrtime.bigint() / 1_000_000n) }

export type StopReason = "stopping" | "authority" | "shutdown" | "startup" | "child_error"
  | "parent_stalled" | "parent_disconnected" | "child_stalled" | "expired"
export type ChildErrorCode = "protocol" | "provider" | "overflow" | "stopped" | "expired" | "audio" | "native" | "api" | "internal"
export type RoomChildCommand =
  | Readonly<{ type: "start"; identity: CaptureIdentity; payload: unknown; requestedAtMs: number; leaseMs: number; leaseDeadlineMs: number }>
  | Readonly<{ type: "renew"; identity: CaptureIdentity; payload?: unknown; requestedAtMs: number; leaseMs: number; leaseDeadlineMs: number }>
  | Readonly<{ type: "stop"; reason: StopReason }>
export type RoomChildMessage = Readonly<{ type: "ready" }> | Readonly<{ type: "stopped" }>
  | Readonly<{ type: "heartbeat"; sentAtMs: number }>
  | Readonly<{ type: "error"; code: ChildErrorCode }>
export type NativeExitReceipt = Readonly<{
  identity: CaptureIdentity; pid: number; code: number | null; signal: NodeJS.Signals | null;
  reason: StopReason | "exited"; hardKilled: boolean; exitedAtMs: number;
}>
export type WatchdogTimings = Readonly<{
  heartbeatTimeoutMs: number; stoppingGraceMs: number; authorityGraceMs: number;
  termGraceMs: number; killExitTimeoutMs: number; startupTimeoutMs: number;
}>
export type WatchdogStart = Readonly<{
  type: "start"; childPath: string; environment: Readonly<Record<string, string>>;
  identity: CaptureIdentity; requestedAtMs: number; leaseMs: number; expiresAtMs: number;
  payload: unknown; timings: WatchdogTimings;
}>
export type WatchdogCommand = WatchdogStart
  | Readonly<{ type: "heartbeat"; sentAtMs: number }>
  | Readonly<{ type: "renew"; identity: CaptureIdentity; requestedAtMs: number; leaseMs: number; payload?: unknown }>
  | Readonly<{ type: "ack_exit"; identity: CaptureIdentity; pid: number }>
  | Readonly<{ type: "stop"; reason: StopReason }>
export type WatchdogMessage = Readonly<{ type: "ready"; pid: number }>
  | Readonly<{ type: "exit"; receipt: NativeExitReceipt }>
  | Readonly<{ type: "error"; code: ChildErrorCode | "exit_unconfirmed" | "watchdog" }>

export function sameIdentity(left: CaptureIdentity, right: CaptureIdentity): boolean {
  return left.runId === right.runId && left.claimEpoch === right.claimEpoch && left.generation === right.generation
}
function object(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined
}
export function validIdentity(value: unknown): value is CaptureIdentity {
  const identity = object(value)
  return !!identity && typeof identity.runId === "string" && identity.runId.length > 0 && identity.runId.length <= 256
    && Number.isSafeInteger(identity.claimEpoch) && Number(identity.claimEpoch) > 0
    && Number.isSafeInteger(identity.generation) && Number(identity.generation) >= 0
}
const stopReasons: readonly StopReason[] = ["stopping", "authority", "shutdown", "startup", "child_error", "parent_stalled", "parent_disconnected", "child_stalled", "expired"]
const errorCodes: readonly ChildErrorCode[] = ["protocol", "provider", "overflow", "stopped", "expired", "audio", "native", "api", "internal"]
export function validStopReason(value: unknown): value is StopReason {
  return typeof value === "string" && stopReasons.some((reason) => reason === value)
}
export function parseChildMessage(value: unknown): RoomChildMessage | undefined {
  const message = object(value)
  if (message?.type === "ready" || message?.type === "stopped") return { type: message.type }
  if (message?.type === "heartbeat" && Number.isSafeInteger(message.sentAtMs) && Number(message.sentAtMs) >= 0) {
    return { type: "heartbeat", sentAtMs: Number(message.sentAtMs) }
  }
  if (message?.type === "error" && errorCodes.some((code) => code === message.code)) {
    return { type: "error", code: message.code as ChildErrorCode }
  }
  return undefined
}

// An expired or stopped lease is permanent; delayed responses cannot resurrect it.
export class WatchdogLease {
  private stopped = false
  private lastRequestMs: number
  private deadlineMs: number
  constructor(readonly identity: CaptureIdentity, requestedAtMs: number, leaseMs: number,
    private readonly expiresAtMs: number, private readonly now = monotonicMilliseconds) {
    if (!validIdentity(identity) || !Number.isFinite(expiresAtMs)) throw new Error("Grid watchdog protocol")
    this.lastRequestMs = requestedAtMs
    this.deadlineMs = this.calculateDeadline(requestedAtMs, leaseMs)
    this.assertCurrent()
  }
  private calculateDeadline(requestedAtMs: number, leaseMs: number): number {
    if (!Number.isSafeInteger(requestedAtMs) || requestedAtMs > this.now()
      || !Number.isSafeInteger(leaseMs) || leaseMs <= 0 || leaseMs > 30_000) throw new Error("Grid watchdog protocol")
    return Math.min(requestedAtMs + leaseMs, this.expiresAtMs)
  }
  get deadline(): number { return this.deadlineMs }
  assertCurrent(): void {
    if (this.stopped) throw new Error("Grid watchdog stopped")
    if (this.now() >= this.deadlineMs) { this.stopped = true; throw new Error("Grid watchdog expired") }
  }
  renew(identity: CaptureIdentity, requestedAtMs: number, leaseMs: number): boolean {
    this.assertCurrent()
    if (!sameIdentity(identity, this.identity)) throw new Error("Grid watchdog protocol")
    const deadline = this.calculateDeadline(requestedAtMs, leaseMs)
    if (requestedAtMs <= this.lastRequestMs) return false
    if (deadline <= this.now()) { this.stopped = true; throw new Error("Grid watchdog expired") }
    this.lastRequestMs = requestedAtMs
    this.deadlineMs = deadline
    return true
  }
  stop(): void { this.stopped = true }
}

function validTimings(value: unknown): value is WatchdogTimings {
  const timings = object(value)
  return !!timings && ["heartbeatTimeoutMs", "stoppingGraceMs", "authorityGraceMs", "termGraceMs", "killExitTimeoutMs", "startupTimeoutMs"]
    .every((key) => Number.isSafeInteger(timings[key]) && Number(timings[key]) >= 0 && Number(timings[key]) <= 30_000)
    && Number(timings.heartbeatTimeoutMs) > 0 && Number(timings.killExitTimeoutMs) > 0 && Number(timings.startupTimeoutMs) > 0
}
function parseStart(value: unknown): WatchdogStart | undefined {
  const message = object(value)
  const environment = object(message?.environment)
  if (message?.type !== "start" || typeof message.childPath !== "string" || !message.childPath
    || !validIdentity(message.identity) || !validTimings(message.timings) || !environment
    || !Object.entries(environment).every(([key, entry]) => /^[A-Z_][A-Z0-9_]*$/.test(key) && typeof entry === "string"
      && key !== "NODE_OPTIONS" && key !== "NODE_PATH")) return undefined
  if (typeof message.requestedAtMs !== "number" || typeof message.leaseMs !== "number" || typeof message.expiresAtMs !== "number") return undefined
  return { type: "start", childPath: message.childPath, environment: environment as Record<string, string>,
    identity: message.identity, requestedAtMs: message.requestedAtMs, leaseMs: message.leaseMs,
    expiresAtMs: message.expiresAtMs, payload: message.payload, timings: message.timings }
}

// The watchdog is the child's actual parent. It never signals a caller-supplied PID.
// It remains alive if SIGKILL has no bounded exit receipt, keeping replacement fenced.
export function runWatchdog(): void {
  let child: ChildProcess | undefined
  let start: WatchdogStart | undefined
  let lease: WatchdogLease | undefined
  let heartbeatDeadlineMs = 0
  let childHeartbeatDeadlineMs = 0
  let startupDeadlineMs = 0
  let ready = false
  let stopped: StopReason | undefined
  let hardKilled = false
  let exited = false
  let exitReceipt: NativeExitReceipt | undefined
  let supervisionTimer: NodeJS.Timeout | undefined
  let escalationTimer: NodeJS.Timeout | undefined
  const send = (message: WatchdogMessage, done?: () => void): void => {
    if (!process.connected || !process.send) { done?.(); return }
    try { process.send(message, (error) => { if (error) stop("parent_disconnected"); done?.() }) }
    catch { stop("parent_disconnected"); done?.() }
  }
  const sendChild = (message: RoomChildCommand): void => {
    if (!child?.connected) return
    try { child.send(message, (error) => { if (error && !exited) stop("authority") }) }
    catch { stop("authority") }
  }
  const kill = (signal: NodeJS.Signals): void => {
    if (!child || exited) return
    try { child.kill(signal) } catch { send({ type: "error", code: "watchdog" }) }
  }
  const escalate = (): void => {
    kill("SIGTERM")
    escalationTimer = setTimeout(() => {
      if (exited) return
      hardKilled = true
      kill("SIGKILL")
      escalationTimer = setTimeout(() => {
        if (!exited) send({ type: "error", code: "exit_unconfirmed" })
      }, start?.timings.killExitTimeoutMs ?? 1_000)
    }, start?.timings.termGraceMs ?? 250)
  }
  const stop = (reason: StopReason): void => {
    if (exited) return
    // Authority loss overrides an existing graceful stop immediately.
    const shorten = stopped === "stopping" && reason !== "stopping"
    if (stopped && !shorten) return
    stopped = reason
    lease?.stop()
    clearTimeout(supervisionTimer)
    clearTimeout(escalationTimer)
    sendChild({ type: "stop", reason })
    if (!child) { process.exitCode = 1; process.disconnect?.(); return }
    const grace = reason === "stopping" ? start?.timings.stoppingGraceMs : start?.timings.authorityGraceMs
    escalationTimer = setTimeout(escalate, grace ?? 50)
    if (reason === "stopping") supervise()
  }
  const supervise = (): void => {
    clearTimeout(supervisionTimer)
    if (!lease || exited || (stopped !== undefined && stopped !== "stopping")) return
    const now = monotonicMilliseconds()
    if (!stopped && now >= lease.deadline) { stop("expired"); return }
    if (now >= heartbeatDeadlineMs) { stop("parent_stalled"); return }
    if (ready && now >= childHeartbeatDeadlineMs) { stop("child_stalled"); return }
    if (!stopped && !ready && now >= startupDeadlineMs) { stop("startup"); return }
    const deadline = stopped === "stopping" ? Math.min(heartbeatDeadlineMs, ready ? childHeartbeatDeadlineMs : Infinity)
      : Math.min(lease.deadline, heartbeatDeadlineMs, ready ? childHeartbeatDeadlineMs : startupDeadlineMs)
    supervisionTimer = setTimeout(supervise, Math.max(1, deadline - now))
  }
  process.on("message", (value: unknown) => {
    const message = object(value)
    if (exited) {
      if (message?.type === "ack_exit" && exitReceipt && validIdentity(message.identity)
        && sameIdentity(message.identity, exitReceipt.identity) && message.pid === exitReceipt.pid) {
        if (process.connected) process.disconnect()
      }
      return
    }
    if (!start) {
      // Signals or queued IPC can arrive between rejection/disconnect and process exit.
      // A terminal pre-start stop must never allocate a child afterward.
      if (stopped || exited) return
      const input = parseStart(value)
      if (!input) { send({ type: "error", code: "protocol" }); stop("authority"); return }
      try { lease = new WatchdogLease(input.identity, input.requestedAtMs, input.leaseMs, input.expiresAtMs) }
      catch { send({ type: "error", code: "expired" }); stop("expired"); return }
      start = input
      const now = monotonicMilliseconds()
      heartbeatDeadlineMs = now + input.timings.heartbeatTimeoutMs
      startupDeadlineMs = now + input.timings.startupTimeoutMs
      try { child = fork(input.childPath, [], { execPath: process.execPath, execArgv: [], env: { ...input.environment },
        stdio: ["ignore", "ignore", "ignore", "ipc"], serialization: "json" }) }
      catch { send({ type: "error", code: "native" }); stop("authority"); return }
      const ownedChild = child
      ownedChild.on("error", () => { send({ type: "error", code: "native" }); stop("child_error") })
      ownedChild.on("message", (event: unknown) => {
        const native = parseChildMessage(event)
        if (!native) { send({ type: "error", code: "protocol" }); stop("child_error"); return }
        if (native.type === "ready" && !ready && !stopped) {
          supervise()
          if (stopped) return
          ready = true
          childHeartbeatDeadlineMs = monotonicMilliseconds() + input.timings.heartbeatTimeoutMs
          if (ownedChild.pid !== undefined) send({ type: "ready", pid: ownedChild.pid })
          supervise()
        } else if (native.type === "heartbeat") {
          const now = monotonicMilliseconds()
          if (native.sentAtMs > now || (ready && now >= childHeartbeatDeadlineMs)) { stop("child_stalled"); return }
          childHeartbeatDeadlineMs = Math.max(childHeartbeatDeadlineMs, native.sentAtMs + input.timings.heartbeatTimeoutMs)
          supervise()
        } else if (native.type === "error") { send(native); stop("child_error") }
      })
      ownedChild.once("exit", (code, signal) => {
        exited = true
        clearTimeout(supervisionTimer)
        clearTimeout(escalationTimer)
        const pid = ownedChild.pid
        if (pid === undefined) { send({ type: "error", code: "native" }); process.disconnect?.(); return }
        exitReceipt = { identity: input.identity, pid, code, signal,
          reason: stopped ?? "exited", hardKilled, exitedAtMs: monotonicMilliseconds() }
        // Keep the IPC channel alive until the parent observes this receipt. A stalled
        // parent's queued heartbeat must not hit EPIPE before its buffered receipt.
        send({ type: "exit", receipt: exitReceipt })
      })
      sendChild({ type: "start", identity: input.identity, payload: input.payload, requestedAtMs: input.requestedAtMs,
        leaseMs: input.leaseMs, leaseDeadlineMs: lease.deadline })
      supervise()
      return
    }
    if (message?.type === "heartbeat" && typeof message.sentAtMs === "number") {
      const now = monotonicMilliseconds()
      if (message.sentAtMs > now || !Number.isSafeInteger(message.sentAtMs)) { stop("authority"); return }
      if ((stopped === undefined || stopped === "stopping") && now >= heartbeatDeadlineMs) { stop("parent_stalled"); return }
      heartbeatDeadlineMs = Math.max(heartbeatDeadlineMs, message.sentAtMs + start.timings.heartbeatTimeoutMs)
      supervise()
    } else if (message?.type === "renew" && validIdentity(message.identity)
      && typeof message.requestedAtMs === "number" && typeof message.leaseMs === "number") {
      supervise()
      if (stopped || !lease) return
      try {
        if (lease.renew(message.identity, message.requestedAtMs, message.leaseMs)) {
          sendChild({ type: "renew", identity: message.identity, payload: message.payload,
            requestedAtMs: message.requestedAtMs, leaseMs: message.leaseMs, leaseDeadlineMs: lease.deadline })
        }
        supervise()
      } catch { stop("authority") }
    } else if (message?.type === "stop" && validStopReason(message.reason)) stop(message.reason)
    else stop("authority")
  })
  process.on("disconnect", () => stop("parent_disconnected"))
  process.on("SIGTERM", () => stop("shutdown"))
  process.on("SIGINT", () => stop("shutdown"))
  // A parent that never delivers the initial start cannot leave a watchdog behind.
  supervisionTimer = setTimeout(() => stop("startup"), 10_000)
}

function isEntrypoint(): boolean {
  if (!process.argv[1]) return false
  try { return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]) }
  catch { return false }
}
if (isEntrypoint()) runWatchdog()
