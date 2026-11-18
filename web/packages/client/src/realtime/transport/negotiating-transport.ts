import { TransportPreference, type ClientMessage, type ConnectionOpen } from "@inline-chat/protocol/core"
import {
  globalInlineProtocolClock,
  globalInlineProtocolTimers,
  type InlineProtocolClock,
  type InlineProtocolTimers,
} from "@inline-chat/protocol/secure/connection"
import { Log, type LogLevel } from "@inline/log"
import { AsyncChannel } from "../../utils/async-channel"
import type { TransportEvent } from "../types"
import { TransportError, type Transport } from "./transport"

/**
 * The operator's rollback lever for sessions that kept a bearer after a V3
 * upgrade. Every open carries the server's current choice; persisting it lets a
 * cold start honor a rollback before its first connection.
 */
export interface TransportPreferenceStore {
  prefersLegacy(): boolean
  record(prefersLegacy: boolean): void
}

export class MemoryTransportPreferenceStore implements TransportPreferenceStore {
  #prefersLegacy = false
  prefersLegacy() {
    return this.#prefersLegacy
  }
  record(prefersLegacy: boolean) {
    this.#prefersLegacy = prefersLegacy
  }
}

/** An open without the field comes from a server that predates the lever, so V3 is allowed. */
export const openPrefersLegacy = (open: ConnectionOpen): boolean =>
  open.upgradedSessionTransport === TransportPreference.LEGACY

export type NegotiatingTransportOptions = {
  createV3: () => Transport
  createV2: () => Transport
  /** Whether the signed-in account has bound V3 credentials. */
  hasV3Credentials: () => boolean | Promise<boolean>
  /** Whether the session still holds a V2 bearer. Without one there is no V2 path. */
  hasBearer: () => boolean
  preference?: TransportPreferenceStore
  /** Optional background `authUpgradeSession`, started after a V2 open. */
  upgrade?: { start(): void; stop(): Promise<void> }
  /** How long a V3 start may take before a bearer session falls back to V2. */
  fallbackDeadlineMs?: number
  /** After a fallback, V2 is used for this long before V3 is tried again. */
  fallbackCooldownMs?: number
  timers?: InlineProtocolTimers
  clock?: InlineProtocolClock
  logLevel?: LogLevel
  logger?: Log
}

type Kind = "v2" | "v3"
type State = "idle" | "starting" | "connected" | "disconnected" | "switching" | "stopping"

/**
 * Picks V3 or V2 per connection attempt, the way the Apple clients'
 * `NegotiatingRealtimeTransport` does:
 *
 * - V3 when the account has bound V3 credentials, and either it has no bearer
 *   or the operator preference allows V3 and no recent fallback is cooling down.
 * - A V3 start that fails or exceeds the deadline falls back to V2 inside the
 *   same start, for bearer sessions only, and V2 is kept for the cooldown.
 * - A V3 open whose `upgraded_session_transport` is LEGACY retires V3 and reports
 *   a disconnect, so the connection manager reconnects onto V2.
 * - A V2 open records the preference and starts the optional session upgrade.
 *
 * Children's events are forwarded only while they are the active child, so a
 * retired child's final `disconnected` or `stopping` never reaches the session.
 */
export class NegotiatingTransport implements Transport {
  readonly events = new AsyncChannel<TransportEvent>()

  readonly #options: NegotiatingTransportOptions
  readonly #log: Log
  readonly #timers: InlineProtocolTimers
  readonly #clock: InlineProtocolClock
  readonly #preference: TransportPreferenceStore
  #active: Transport | undefined
  #activeKind: Kind | undefined
  #state: State = "idle"
  #generation = 0
  #deadline: unknown
  #retryV3After: number | undefined
  #sessionRevoked = false

  constructor(options: NegotiatingTransportOptions) {
    this.#options = options
    this.#log = options.logger ?? new Log("Realtime.TransportSelection", options.logLevel)
    this.#timers = options.timers ?? globalInlineProtocolTimers()
    this.#clock = options.clock ?? globalInlineProtocolClock()
    this.#preference = options.preference ?? new MemoryTransportPreferenceStore()
  }

  get activeKind(): Kind | undefined {
    return this.#activeKind
  }

  async start() {
    // A V2 connection carrying requests keeps its owner until it actually disconnects.
    if (this.#state !== "idle" && this.#state !== "disconnected") return
    this.#state = "starting"
    const kind = await this.#selectKind()
    if (this.#state !== "starting") return
    if (this.#activeKind !== kind) {
      await this.#retireChild()
      if (this.#state !== "starting") return
      this.#install(kind)
    }
    const active = this.#active
    if (!active) return
    this.#sessionRevoked = false
    this.#armFallbackDeadline()
    await active.start()
  }

  async stop() {
    if (this.#state === "stopping") return
    const wasIdle = this.#state === "idle"
    this.#state = "stopping"
    this.#clearDeadline()
    await this.#options.upgrade?.stop()
    await this.#retireChild()
    this.#state = "idle"
    if (!wasIdle) await this.events.send({ type: "stopping" })
  }

  async send(message: ClientMessage) {
    const active = this.#active
    if (!active || this.#state !== "connected") throw TransportError.notConnected()
    await active.send(message)
  }

  async #selectKind(): Promise<Kind> {
    const hasV3 = await this.#options.hasV3Credentials()
    if (!hasV3) return "v2"
    if (!this.#options.hasBearer()) return "v3"
    if (this.#preference.prefersLegacy()) return "v2"
    if (this.#retryV3After !== undefined && this.#clock.monotonicMilliseconds() < this.#retryV3After) return "v2"
    return "v3"
  }

  #install(kind: Kind) {
    const child = kind === "v3" ? this.#options.createV3() : this.#options.createV2()
    this.#log.debug("transport.selected", { protocol: kind })
    this.#active = child
    this.#activeKind = kind
    const generation = ++this.#generation
    void (async () => {
      for await (const event of child.events) {
        if (generation !== this.#generation) continue
        await this.#receive(event, generation)
      }
    })().catch((error: unknown) => {
      this.#log.error("transport.forwarder.crashed", { error })
    })
  }

  /** Invalidates the child's events first, then stops it, so its final events are discarded. */
  async #retireChild() {
    ++this.#generation
    const child = this.#active
    this.#active = undefined
    this.#activeKind = undefined
    if (!child) return
    await child.stop()
    child.events.close()
  }

  async #receive(event: TransportEvent, generation: number) {
    if (this.#state === "switching" || this.#state === "stopping") return
    switch (event.type) {
      case "connected":
        if (this.#state !== "starting") return
        this.#clearDeadline()
        this.#state = "connected"
        break
      case "disconnected":
        this.#clearDeadline()
        if (this.#canFallback()) {
          void this.#fallback(generation, "startup_failure")
          return
        }
        this.#state = "disconnected"
        break
      case "stopping":
        break
      case "message": {
        const body = event.message.body
        if (body.oneofKind === "connectionError") {
          this.#sessionRevoked = true
          this.#clearDeadline()
        }
        if (body.oneofKind === "connectionOpen" && this.#state === "connected") {
          const prefersLegacy = openPrefersLegacy(body.connectionOpen)
          this.#preference.record(prefersLegacy)
          if (this.#activeKind === "v3" && prefersLegacy && this.#options.hasBearer()) {
            void this.#applyLegacyPreference(generation)
            return
          }
          this.#log.info("transport.opened", { protocol: this.#activeKind ?? "unknown" })
          await this.events.send(event)
          // Optional key work waits for a usable V2 session and never competes with it.
          if (this.#activeKind === "v2" && generation === this.#generation) this.#options.upgrade?.start()
          return
        }
        break
      }
      case "connecting":
        break
    }
    await this.events.send(event)
  }

  #canFallback() {
    return (this.#state === "starting" || this.#state === "switching") &&
      this.#activeKind === "v3" && this.#options.hasBearer() && !this.#sessionRevoked
  }

  #armFallbackDeadline() {
    this.#clearDeadline()
    if (!this.#canFallback()) return
    const generation = this.#generation
    this.#deadline = this.#timers.setTimeout(() => {
      this.#deadline = undefined
      if (generation !== this.#generation) return
      void this.#fallback(generation, "deadline")
    }, this.#options.fallbackDeadlineMs ?? 6_000)
  }

  #clearDeadline() {
    if (this.#deadline === undefined) return
    this.#timers.clearTimeout(this.#deadline)
    this.#deadline = undefined
  }

  async #fallback(generation: number, reason: string) {
    if (generation !== this.#generation || !this.#canFallback()) return
    this.#state = "switching"
    this.#clearDeadline()
    this.#retryV3After = this.#clock.monotonicMilliseconds() + (this.#options.fallbackCooldownMs ?? 300_000)
    this.#log.warn("transport.v3_fallback", { protocol: "v2", reason })
    await this.#retireChild()
    if (this.#state !== "switching") return
    this.#state = "starting"
    this.#install("v2")
    await this.#active?.start()
  }

  async #applyLegacyPreference(generation: number) {
    if (generation !== this.#generation || this.#state !== "connected") return
    this.#state = "switching"
    this.#log.warn("transport.v3_fallback", { protocol: "v2", reason: "operator_preference" })
    await this.#retireChild()
    if (this.#state !== "switching") return
    this.#state = "disconnected"
    await this.events.send({ type: "disconnected", reason: "transport_preference" })
  }
}
