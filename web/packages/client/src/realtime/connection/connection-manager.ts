import { Log, type LogLevel } from "@inline/log"
import { AsyncChannel } from "../../utils/async-channel"
import type { ProtocolClient } from "../client/protocol-client"
import type { ClientEvent } from "../types"

export type ConnectionManagerState =
  | "stopped"
  | "waitingForConstraints"
  | "connectingTransport"
  | "authenticating"
  | "open"
  | "backoff"
  | "backgroundSuspended"

export type ConnectionConstraints = Readonly<{
  authAvailable: boolean
  networkAvailable: boolean
  appActive: boolean
  userWantsConnection: boolean
}>

export type ConnectionManagerOptions = {
  session: ProtocolClient
  logger?: Log
  logLevel?: LogLevel
  authTimeoutMs?: number
  backgroundGraceMs?: number
  wakeProbeTimeoutMs?: number
  backoffDelayMs?: (attempt: number) => number
}

const defaultBackoffDelayMs = (attempt: number) => {
  if (attempt >= 8) return 8_000 + Math.random() * 5_000
  return Math.min(
    8_000,
    200 + Math.pow(attempt, 1.5) * 400,
  )
}

/**
 * The sole owner of connection attempts, authentication timeout, backoff, and
 * lifecycle constraints. Transport performs one socket attempt; ProtocolClient
 * performs one protocol handshake; neither layer retries or observes browser
 * lifecycle itself.
 */
export class ConnectionManager {
  readonly events = new AsyncChannel<ClientEvent>()

  state: ConnectionManagerState = "stopped"

  private readonly session: ProtocolClient
  private readonly log: Log
  private readonly authTimeoutMs: number
  private readonly backgroundGraceMs: number
  private readonly wakeProbeTimeoutMs: number
  private readonly backoffDelayMs: (attempt: number) => number
  private userWantsConnection = false
  private authAvailable = true
  private networkAvailable = true
  private appActive = true
  private backgroundGraceActive = false
  private attempt = 0
  private generation = 0
  private lifecycleGeneration = 0
  private backoffTimer: ReturnType<typeof setTimeout> | null = null
  private authTimer: ReturnType<typeof setTimeout> | null = null
  private backgroundGraceTimer: ReturnType<typeof setTimeout> | null =
    null
  private wakeProbeTimer: ReturnType<typeof setTimeout> | null = null
  private wakeProbeNonce: bigint | null = null
  private listenerStarted = false

  constructor(options: ConnectionManagerOptions) {
    this.session = options.session
    this.log =
      options.logger ??
      new Log("RealtimeV2.ConnectionManager", options.logLevel)
    this.authTimeoutMs = options.authTimeoutMs ?? 10_000
    this.backgroundGraceMs = options.backgroundGraceMs ?? 30_000
    this.wakeProbeTimeoutMs = options.wakeProbeTimeoutMs ?? 2_000
    this.backoffDelayMs =
      options.backoffDelayMs ?? defaultBackoffDelayMs
    this.startListener()
  }

  get constraints(): ConnectionConstraints {
    return {
      authAvailable: this.authAvailable,
      networkAvailable: this.networkAvailable,
      appActive: this.appActive,
      userWantsConnection: this.userWantsConnection,
    }
  }

  async start() {
    if (this.userWantsConnection) return
    this.userWantsConnection = true
    this.attempt = 0
    await this.evaluateConstraints()
  }

  async stop() {
    if (
      !this.userWantsConnection &&
      this.state === "stopped"
    ) {
      return
    }
    this.userWantsConnection = false
    this.generation += 1
    this.lifecycleGeneration += 1
    this.cancelAllTimers()
    this.backgroundGraceActive = false
    this.state = "stopped"
    await this.session.stopTransport()
  }

  async setUserWantsConnection(wantsConnection: boolean) {
    if (wantsConnection) {
      await this.start()
    } else {
      await this.stop()
    }
  }

  async setAuthAvailable(available: boolean) {
    if (this.authAvailable === available) return
    this.authAvailable = available
    this.attempt = 0
    if (!available) {
      await this.handleConstraintLoss("authentication-unavailable")
      return
    }
    await this.evaluateConstraints()
  }

  async setNetworkAvailable(available: boolean) {
    if (this.networkAvailable === available) return
    this.networkAvailable = available
    this.attempt = 0
    if (!available) {
      await this.handleConstraintLoss("network-unavailable")
      return
    }
    await this.evaluateConstraints()
  }

  async setAppActive(active: boolean) {
    if (this.appActive === active) return
    this.appActive = active
    this.lifecycleGeneration += 1

    if (active) {
      this.attempt = 0
      this.backgroundGraceActive = false
      this.cancelBackgroundGrace()
      await this.evaluateConstraints()
      return
    }

    if (
      this.state === "open" ||
      this.state === "connectingTransport" ||
      this.state === "authenticating"
    ) {
      this.backgroundGraceActive = true
      this.scheduleBackgroundGrace(this.lifecycleGeneration)
      return
    }

    this.backgroundGraceActive = false
    await this.evaluateConstraints()
  }

  async systemDidWake() {
    const connectionWasOpen = this.state === "open"
    this.appActive = true
    this.lifecycleGeneration += 1
    this.attempt = 0
    this.backgroundGraceActive = false
    this.cancelBackgroundGrace()
    await this.evaluateConstraints()

    if (connectionWasOpen && this.state === "open") {
      this.startWakeProbe()
    }
  }

  async reconnectNow(reason = "requested") {
    if (!this.userWantsConnection) return
    this.log.debug(`Forcing reconnect: ${reason}`)
    this.generation += 1
    this.attempt = 0
    this.cancelConnectionTimers()
    this.state = "stopped"
    await this.session.stopTransport()
    await this.evaluateConstraints()
  }

  /**
   * Replace a transport which failed while serving application traffic.
   * Unlike an explicit wake probe, a runtime failure must retain the
   * connection manager's retry history and pass through its coalesced
   * backoff. Otherwise one queued transaction can create a tight
   * open/send-fail/reconnect loop.
   */
  async reconnectAfterFailure(reason = "runtime-failure") {
    if (!this.userWantsConnection) return
    await this.scheduleReconnect(reason)
  }

  private startListener() {
    if (this.listenerStarted) return
    this.listenerStarted = true
    ;(async () => {
      for await (const event of this.session.events) {
        await this.handleSessionEvent(event)
      }
    })().catch((error) => {
      this.log.error("Connection manager listener crashed", error)
    })
  }

  private async handleSessionEvent(event: ClientEvent) {
    switch (event.type) {
      case "connecting":
        if (!this.constraintsSatisfied()) return
        if (this.state !== "connectingTransport") {
          this.state = "connectingTransport"
          await this.events.send({ type: "connecting" })
        }
        return

      case "transportConnected":
        if (
          !this.constraintsSatisfied() ||
          this.state !== "connectingTransport"
        ) {
          return
        }
        this.state = "authenticating"
        this.startAuthTimeout(this.generation)
        return

      case "open":
        if (
          !this.constraintsSatisfied() ||
          (this.state !== "authenticating" &&
            this.state !== "connectingTransport")
        ) {
          return
        }
        this.cancelAuthTimeout()
        this.attempt = 0
        this.state = "open"
        await this.events.send(event)
        return

      case "disconnected":
        if (
          this.state === "stopped" ||
          this.state === "waitingForConstraints" ||
          this.state === "backgroundSuspended"
        ) {
          return
        }
        await this.scheduleReconnect(
          event.reason ?? "transport-disconnected",
        )
        return

      case "failure":
        if (event.reason === "authentication-missing") {
          this.authAvailable = false
          await this.handleConstraintLoss(
            "authentication-missing",
          )
          await this.events.send({
            type: "authInvalidated",
            reason: "missing",
          })
          return
        }
        await this.scheduleReconnect(event.reason)
        return

      case "connectionError":
        this.authAvailable = false
        await this.handleConstraintLoss(
          `server-auth-${event.reason}`,
        )
        await this.events.send({
          type: "authInvalidated",
          reason: event.reason,
        })
        return

      case "pong":
        if (event.nonce === this.wakeProbeNonce) {
          this.cancelWakeProbe()
        }
        return

      case "ack":
      case "rpcResult":
      case "rpcError":
      case "updates":
      case "authInvalidated":
        await this.events.send(event)
        return
    }
  }

  private async evaluateConstraints() {
    if (!this.userWantsConnection) {
      if (this.state !== "stopped") {
        this.state = "stopped"
        this.cancelAllTimers()
        await this.session.stopTransport()
      }
      return
    }

    if (!this.authAvailable || !this.networkAvailable) {
      if (this.state !== "waitingForConstraints") {
        this.state = "waitingForConstraints"
        await this.events.send({ type: "connecting" })
      }
      this.generation += 1
      this.cancelConnectionTimers()
      await this.session.stopTransport()
      return
    }

    if (!this.appActive && !this.backgroundGraceActive) {
      if (this.state !== "backgroundSuspended") {
        this.state = "backgroundSuspended"
        await this.events.send({ type: "connecting" })
      }
      this.generation += 1
      this.cancelConnectionTimers()
      await this.session.stopTransport()
      return
    }

    if (
      this.state === "stopped" ||
      this.state === "waitingForConstraints" ||
      this.state === "backgroundSuspended" ||
      this.state === "backoff"
    ) {
      await this.startAttempt()
    }
  }

  private async handleConstraintLoss(reason: string) {
    this.log.debug(`Connection constraint lost: ${reason}`)
    this.lifecycleGeneration += 1
    this.generation += 1
    this.backgroundGraceActive = false
    this.cancelAllTimers()
    if (!this.userWantsConnection) return
    if (this.state !== "waitingForConstraints") {
      this.state = "waitingForConstraints"
      await this.events.send({ type: "connecting" })
    }
    await this.session.stopTransport()
  }

  private async startAttempt() {
    if (!this.constraintsSatisfied()) {
      await this.evaluateConstraints()
      return
    }
    const generation = ++this.generation
    this.cancelConnectionTimers()
    this.state = "connectingTransport"
    await this.events.send({ type: "connecting" })
    try {
      await this.session.startTransport()
    } catch (error) {
      if (
        generation !== this.generation ||
        !this.constraintsSatisfied()
      ) {
        return
      }
      this.log.warn("Transport start failed", error)
      await this.scheduleReconnect("transport-start-failed")
    }
  }

  private async scheduleReconnect(reason: string) {
    if (
      !this.userWantsConnection ||
      this.state === "stopped" ||
      this.state === "waitingForConstraints" ||
      this.state === "backgroundSuspended"
    ) {
      return
    }
    if (this.state === "backoff" && this.backoffTimer) return
    if (!this.constraintsSatisfied()) {
      await this.evaluateConstraints()
      return
    }

    this.cancelAuthTimeout()
    this.cancelWakeProbe()
    this.state = "backoff"
    this.attempt += 1
    const generation = ++this.generation
    const delay = this.backoffDelayMs(this.attempt)
    this.log.debug(
      `Reconnect attempt ${this.attempt} in ${delay}ms: ${reason}`,
    )
    await this.events.send({ type: "connecting" })
    await this.session.stopTransport()
    if (
      !this.constraintsSatisfied() ||
      generation !== this.generation
    ) {
      return
    }
    this.backoffTimer = setTimeout(() => {
      this.backoffTimer = null
      if (
        !this.constraintsSatisfied() ||
        generation !== this.generation
      ) {
        return
      }
      void this.startAttempt()
    }, delay)
  }

  private startAuthTimeout(generation: number) {
    this.cancelAuthTimeout()
    this.authTimer = setTimeout(() => {
      this.authTimer = null
      if (
        !this.constraintsSatisfied() ||
        generation !== this.generation ||
        this.state !== "authenticating"
      ) {
        return
      }
      void this.scheduleReconnect("authentication-timeout")
    }, this.authTimeoutMs)
  }

  private cancelAuthTimeout() {
    if (!this.authTimer) return
    clearTimeout(this.authTimer)
    this.authTimer = null
  }

  private scheduleBackgroundGrace(lifecycleGeneration: number) {
    this.cancelBackgroundGrace()
    this.backgroundGraceTimer = setTimeout(() => {
      this.backgroundGraceTimer = null
      if (
        lifecycleGeneration !== this.lifecycleGeneration ||
        this.appActive ||
        !this.userWantsConnection
      ) {
        return
      }
      this.backgroundGraceActive = false
      void this.evaluateConstraints()
    }, this.backgroundGraceMs)
  }

  private cancelBackgroundGrace() {
    if (!this.backgroundGraceTimer) return
    clearTimeout(this.backgroundGraceTimer)
    this.backgroundGraceTimer = null
  }

  private startWakeProbe() {
    this.cancelWakeProbe()
    if (this.state !== "open") return

    const nonce = this.randomNonce()
    const generation = this.generation
    const lifecycleGeneration = this.lifecycleGeneration
    this.wakeProbeNonce = nonce
    this.wakeProbeTimer = setTimeout(() => {
      this.wakeProbeTimer = null
      if (
        this.wakeProbeNonce !== nonce ||
        generation !== this.generation ||
        lifecycleGeneration !== this.lifecycleGeneration ||
        this.state !== "open"
      ) {
        return
      }
      this.wakeProbeNonce = null
      void this.reconnectNow("wake-probe-timeout")
    }, this.wakeProbeTimeoutMs)
    void this.session.sendPing(nonce)
  }

  private cancelWakeProbe() {
    this.wakeProbeNonce = null
    if (!this.wakeProbeTimer) return
    clearTimeout(this.wakeProbeTimer)
    this.wakeProbeTimer = null
  }

  private cancelConnectionTimers() {
    this.cancelAuthTimeout()
    if (this.backoffTimer) {
      clearTimeout(this.backoffTimer)
      this.backoffTimer = null
    }
    this.cancelWakeProbe()
  }

  private cancelAllTimers() {
    this.cancelConnectionTimers()
    this.cancelBackgroundGrace()
  }

  private constraintsSatisfied() {
    return (
      this.userWantsConnection &&
      this.authAvailable &&
      this.networkAvailable &&
      (this.appActive || this.backgroundGraceActive)
    )
  }

  private randomNonce() {
    if (
      typeof crypto !== "undefined" &&
      "getRandomValues" in crypto
    ) {
      const buffer = new Uint32Array(2)
      crypto.getRandomValues(buffer)
      return (
        (BigInt(buffer[0] ?? 0) << 32n) |
        BigInt(buffer[1] ?? 0)
      )
    }
    return BigInt(
      Math.floor(Math.random() * Number.MAX_SAFE_INTEGER),
    )
  }
}
