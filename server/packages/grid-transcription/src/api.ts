import { Buffer } from "node:buffer"
import { MAX_TURN_TEXT_BYTES, TranscriptionError, nonemptyString, record, type Model } from "./protocol.js"

export const RUN_DURATION_MS = 2 * 60 * 60 * 1000
export const SPEAKER_LIMIT = 8
export const LEASE_MS = 15_000
const MAX_RESPONSE_BYTES = 64 * 1024

export type ParticipantGrant = Readonly<{ identity: string; userId: string; membershipId: string }>
export type ClaimedRun = Readonly<{
  runId: string; claimEpoch: number; roomId: string; generation: number; runToken: string;
  providerTarget: string; livekit: Readonly<{ serverUrl: string; token: string }>;
  model: Model; leaseMs: number; expiresAt: string; participants: readonly ParticipantGrant[];
}>
export type StoppedClaim = Readonly<{ runId: string; claimEpoch: number; runToken: string; stopImmediately: true }>
export type RenewedRun = Readonly<{
  state: "active" | "stopping" | "stopped"; allowFinalFlush: boolean; leaseExpiresAt: string;
  participants: readonly ParticipantGrant[];
}>

function integer(value: unknown, minimum = 0): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum) {
    throw new TranscriptionError("protocol")
  }
  return value
}

function secret(value: unknown): string {
  if (typeof value !== "string" || value.length === 0 || value.length > 16_384 || /[\r\n]/.test(value)) {
    throw new TranscriptionError("protocol")
  }
  return value
}

function boundedString(value: unknown, maximum: number): string {
  const result = nonemptyString(value)
  if (result.length > maximum) throw new TranscriptionError("protocol")
  return result
}

function decimalId(value: unknown): string {
  const result = typeof value === "number" ? String(integer(value, 1)) : boundedString(value, 128)
  if (!/^[1-9][0-9]*$/.test(result)) throw new TranscriptionError("protocol")
  return result
}

function parseUrl(value: string): URL {
  try { return new URL(value) }
  catch { throw new TranscriptionError("protocol") }
}

function date(value: unknown): string {
  const result = nonemptyString(value)
  if (!Number.isFinite(Date.parse(result))) throw new TranscriptionError("protocol")
  return result
}

export function participants(value: unknown): readonly ParticipantGrant[] {
  // Manifest may include muted/trackless occupants; the microphone cap is checked separately.
  if (!Array.isArray(value) || value.length > 100) throw new TranscriptionError("overflow")
  const identities = new Set<string>()
  const result: ParticipantGrant[] = []
  for (const entry of value) {
    const item = record(entry)
    const identity = boundedString(item.identity, 128)
    const membershipId = boundedString(item.membershipId, 128)
    const userId = decimalId(item.userId)
    if (identities.has(identity)) throw new TranscriptionError("protocol")
    identities.add(identity)
    result.push(Object.freeze({ identity, membershipId, userId }))
  }
  return Object.freeze(result)
}

export function claimedRun(value: unknown): ClaimedRun {
  const item = record(value)
  const media = record(item.livekit)
  if (item.model !== "standard" && item.model !== "meeting") throw new TranscriptionError("protocol")
  const leaseMs = integer(item.leaseMs, 1)
  if (leaseMs > LEASE_MS) throw new TranscriptionError("protocol")
  const serverUrl = nonemptyString(media.serverUrl)
  const url = parseUrl(serverUrl)
  if (url.protocol !== "wss:" && url.protocol !== "ws:") throw new TranscriptionError("protocol")
  return Object.freeze({
    runId: boundedString(item.runId, 128), claimEpoch: integer(item.claimEpoch, 1),
    roomId: decimalId(item.roomId), generation: integer(item.generation),
    runToken: secret(item.runToken), providerTarget: nonemptyString(item.providerTarget),
    livekit: Object.freeze({ serverUrl, token: secret(media.token) }), model: item.model,
    leaseMs, expiresAt: date(item.expiresAt), participants: participants(item.participants),
  })
}
export function claimResponse(value: unknown): ClaimedRun | StoppedClaim {
  const item = record(value)
  if (item.stopImmediately !== undefined && typeof item.stopImmediately !== "boolean") throw new TranscriptionError("protocol")
  if (item.stopImmediately !== true) return claimedRun(value)
  return Object.freeze({ runId: boundedString(item.runId, 128), claimEpoch: integer(item.claimEpoch, 1),
    runToken: secret(item.runToken), stopImmediately: true })
}

export function renewedRun(value: unknown): RenewedRun {
  const item = record(value)
  if (item.state !== "active" && item.state !== "stopping" && item.state !== "stopped") {
    throw new TranscriptionError("protocol")
  }
  if (item.allowFinalFlush !== undefined && typeof item.allowFinalFlush !== "boolean") {
    throw new TranscriptionError("protocol")
  }
  return Object.freeze({
    state: item.state, allowFinalFlush: item.allowFinalFlush ?? false,
    leaseExpiresAt: date(item.leaseExpiresAt), participants: participants(item.participants),
  })
}

class ControlHttp {
  private readonly base: URL

  constructor(baseUrl: string, private readonly bearer: string, private readonly timeoutMs = 2500) {
    this.base = parseUrl(baseUrl)
    if (this.base.protocol !== "https:" && !(this.base.protocol === "http:"
      && ["127.0.0.1", "localhost", "[::1]"].includes(this.base.hostname))) {
      throw new TranscriptionError("protocol")
    }
    if (this.base.username || this.base.password || this.base.search || this.base.hash || this.base.pathname !== "/"
      || !Number.isFinite(timeoutMs) || timeoutMs < 1 || timeoutMs > 5000) {
      throw new TranscriptionError("protocol")
    }
    secret(bearer)
  }

  async post(path: string, body: unknown): Promise<unknown | undefined> {
    try {
      const url = new URL(`/_internal/grid-transcription/${path}`, this.base)
      const response = await fetch(url, {
        method: "POST", redirect: "error", signal: AbortSignal.timeout(this.timeoutMs),
        headers: { Authorization: `Bearer ${this.bearer}`, "Content-Type": "application/json" },
        body: JSON.stringify(body),
      })
      if (response.status === 204) return undefined
      if (!response.ok) {
        await response.body?.cancel()
        throw new TranscriptionError(response.status === 410 ? "expired"
          : [401, 403, 404, 409].includes(response.status) ? "stopped" : "provider")
      }
      const reader = response.body?.getReader()
      if (!reader) throw new TranscriptionError("protocol")
      const chunks: Uint8Array[] = []
      let size = 0
      try {
        while (true) {
          const part = await reader.read()
          if (part.done) break
          size += part.value.byteLength
          if (size > MAX_RESPONSE_BYTES) {
            await reader.cancel()
            throw new TranscriptionError("overflow")
          }
          chunks.push(part.value)
        }
      } finally { reader.releaseLock() }
      const bytes = Buffer.concat(chunks, size)
      return JSON.parse(bytes.toString("utf8")) as unknown
    } catch (error) {
      throw error instanceof TranscriptionError ? error : new TranscriptionError("provider")
    }
  }
}

export class WorkerControlClient {
  private readonly http: ControlHttp

  constructor(baseUrl: string, sharedSecret: string, readonly workerId: string, timeoutMs?: number) {
    boundedString(workerId, 80)
    this.http = new ControlHttp(baseUrl, sharedSecret, timeoutMs)
  }

  async heartbeat(model: Model, ready: boolean): Promise<void> {
    await this.http.post("heartbeat", { workerId: this.workerId, model, ready })
  }

  async claim(): Promise<ClaimedRun | StoppedClaim | undefined> {
    const value = await this.http.post("claim", { workerId: this.workerId })
    return value === undefined ? undefined : claimResponse(value)
  }
}

export class RunControlClient {
  private readonly http: ControlHttp

  constructor(baseUrl: string, runToken: string, timeoutMs?: number) {
    this.http = new ControlHttp(baseUrl, runToken, timeoutMs)
  }

  async renew(): Promise<RenewedRun> { return renewedRun(await this.http.post("renew", {})) }

  async admit(participantIdentity: string, trackSid: string, sourceTurnKey: string): Promise<string> {
    const value = record(await this.http.post("admit", {
      participantIdentity: boundedString(participantIdentity, 128), trackSid: boundedString(trackSid, 128),
      sourceTurnKey: boundedString(sourceTurnKey, 128),
    }))
    return boundedString(value.segmentId, 128)
  }

  async final(segmentId: string, text: string): Promise<void> {
    if (typeof text !== "string") throw new TranscriptionError("protocol")
    if (text.length > MAX_TURN_TEXT_BYTES || Buffer.byteLength(text) > MAX_TURN_TEXT_BYTES) {
      throw new TranscriptionError("overflow")
    }
    const value = record(await this.http.post("final", { segmentId: boundedString(segmentId, 128), text }))
    if (value.messageId !== null) decimalId(value.messageId)
  }

  async stopped(reason: string): Promise<void> { await this.http.post("stopped", { reason: boundedString(reason, 80) }) }
}
