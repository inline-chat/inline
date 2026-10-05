import { fileURLToPath } from "node:url"
import { claimedRun, participants } from "./api.js"
import { TranscriptionError, record } from "./protocol.js"
import { RoomWorker } from "./room-worker.js"
import { monotonicMilliseconds, sameIdentity, validIdentity, validStopReason, type RoomChildMessage } from "./watchdog.js"

export function runRoomChild(): void {
  let worker: RoomWorker | undefined
  let started = false
  let stopping = false
  const send = (message: RoomChildMessage): void => {
    if (!process.connected || !process.send) return
    try { process.send(message, () => undefined) } catch { /* Watchdog owns final process containment. */ }
  }
  const stop = (graceful: boolean): void => {
    stopping = true
    if (!worker) { process.exit(0); return }
    void worker.stop(graceful).then(() => {
      send({ type: "stopped" })
      process.exit(0)
    }).catch(() => { send({ type: "error", code: "native" }); process.exit(1) })
  }
  const fail = (error: unknown): void => {
    send({ type: "error", code: error instanceof TranscriptionError ? error.code : "internal" })
    stop(false)
  }
  process.on("message", (value: unknown) => {
    try {
      const message = record(value)
      if (message.type === "stop" && validStopReason(message.reason)) { stop(message.reason === "stopping"); return }
      if (stopping) return
      if (message.type === "start" && !started && validIdentity(message.identity)) {
        started = true
        setInterval(() => send({ type: "heartbeat", sentAtMs: monotonicMilliseconds() }), 250)
        const payload = record(message.payload)
        const run = claimedRun(payload.run)
        if (!sameIdentity(message.identity, { runId: run.runId, claimEpoch: run.claimEpoch, generation: run.generation })
          || typeof message.requestedAtMs !== "number" || typeof message.leaseMs !== "number"
          || typeof payload.expiresAtMs !== "number" || typeof payload.apiKey !== "string" || !payload.apiKey
          || payload.apiKey.length > 4096 || typeof payload.apiBaseUrl !== "string" || !payload.apiBaseUrl) {
          throw new TranscriptionError("protocol")
        }
        if (payload.apiTimeoutMs !== undefined && typeof payload.apiTimeoutMs !== "number") throw new TranscriptionError("protocol")
        worker = new RoomWorker({ run, identity: message.identity, requestedAtMs: message.requestedAtMs,
          leaseMs: message.leaseMs, expiresAtMs: payload.expiresAtMs, apiBaseUrl: payload.apiBaseUrl, apiKey: payload.apiKey,
          apiTimeoutMs: payload.apiTimeoutMs, onFailure: fail })
        void worker.start().then(() => { if (!stopping) send({ type: "ready" }) }).catch((error: unknown) => {
          if (!stopping) fail(error)
        })
      } else if (message.type === "renew" && worker && validIdentity(message.identity)) {
        if (typeof message.requestedAtMs !== "number" || typeof message.leaseMs !== "number") throw new TranscriptionError("protocol")
        const payload = record(message.payload)
        worker.renew(message.identity, message.requestedAtMs, message.leaseMs, participants(payload.participants))
      } else throw new TranscriptionError("protocol")
    } catch (error) { fail(error) }
  })
  process.on("disconnect", () => stop(false))
  process.on("SIGTERM", () => stop(false))
  process.on("SIGINT", () => stop(false))
}
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) runRoomChild()
