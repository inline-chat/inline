import { Log } from "@inline/log"
import type { ProtocolClient } from "./protocol-client"

export class PingPongService {
  private readonly log: Log
  private client: ProtocolClient | null = null
  private running = false
  private sleepTimer: ReturnType<typeof setTimeout> | null = null
  private sleepResolver: (() => void) | null = null

  private pings = new Map<bigint, number>()
  private recentLatenciesMs: number[] = []

  constructor(logger?: Log) {
    this.log = logger ?? new Log("RealtimeV2.PingPongService", "info")
  }

  configure(client: ProtocolClient) {
    this.client = client
  }

  start() {
    if (this.running) return
    this.log.debug("starting ping pong service")
    this.running = true
    this.reset()
    void this.loop()
  }

  stop() {
    this.log.debug("stopping ping pong service")
    this.running = false
    this.clearSleep()
    this.reset()
  }

  async ping() {
    const client = this.client
    if (!client) return
    if (client.state !== "open") return

    const nonce = this.randomNonce()
    this.log.debug("ping sent with nonce", nonce)
    await client.sendPing(nonce)
    this.pings.set(nonce, Date.now())
  }

  pong(nonce: bigint) {
    this.log.debug("pong received for nonce", nonce)
    const pingDate = this.pings.get(nonce)
    if (!pingDate) {
      this.log.trace("pong received for unknown ping nonce", nonce)
      return
    }

    this.pings.delete(nonce)
    this.recordLatency(pingDate)
    this.log.debug("avg latency", this.avgLatencyMs(), "ms")
  }

  private async loop() {
    while (this.running) {
      await this.checkConnection()

      const delay = this.getNextPingDelayMs()
      await this.sleep(delay)
      if (!this.running) break

      await this.ping()
    }
  }

  private reset() {
    this.pings.clear()
    this.recentLatenciesMs = []
  }

  private getNextPingDelayMs() {
    if (this.avgLatencyMs() > 2000) {
      this.log.debug("avg latency is high, increasing ping interval")
      return 25_000
    }
    return 10_000
  }

  private async checkConnection() {
    const client = this.client
    if (!client) return
    if (client.state !== "open") return

    const now = Date.now()
    const hasTimedOutPing = [...this.pings.values()].some((timestamp) => now - timestamp > 30_000)
    if (!hasTimedOutPing) return

    await client.reconnect()
  }

  private recordLatency(pingDateMs: number) {
    const latency = Date.now() - pingDateMs
    this.recentLatenciesMs.push(latency)
    if (this.recentLatenciesMs.length > 10) {
      this.recentLatenciesMs.shift()
    }
  }

  private avgLatencyMs() {
    if (this.recentLatenciesMs.length === 0) return 0
    const sum = this.recentLatenciesMs.reduce((acc, value) => acc + value, 0)
    return Math.round(sum / this.recentLatenciesMs.length)
  }

  private async sleep(ms: number) {
    if (ms <= 0) return
    await new Promise<void>((resolve) => {
      this.sleepResolver = resolve
      this.sleepTimer = setTimeout(() => {
        this.sleepTimer = null
        this.sleepResolver = null
        resolve()
      }, ms)
    })
  }

  private clearSleep() {
    if (this.sleepTimer) {
      clearTimeout(this.sleepTimer)
      this.sleepTimer = null
    }
    if (this.sleepResolver) {
      this.sleepResolver()
      this.sleepResolver = null
    }
  }

  private randomNonce(): bigint {
    if (typeof crypto !== "undefined" && "getRandomValues" in crypto) {
      const buffer = new Uint32Array(2)
      crypto.getRandomValues(buffer)
      return (BigInt(buffer[0]) << 32n) | BigInt(buffer[1])
    }

    return BigInt(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER))
  }
}
