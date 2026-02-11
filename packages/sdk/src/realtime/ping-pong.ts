import type { InlineSdkLogger } from "../sdk/logger.js"
import type { ProtocolClient } from "./protocol-client.js"

export class PingPongService {
  private readonly log: InlineSdkLogger
  private readonly crypto: Crypto | null
  private client: ProtocolClient | null = null
  private running = false
  private sleepTimer: ReturnType<typeof setTimeout> | null = null
  private sleepResolver: (() => void) | null = null

  private pings = new Map<bigint, number>()

  constructor(options?: { logger?: InlineSdkLogger; crypto?: Crypto | null }) {
    this.log = options?.logger ?? {}
    const cryptoAny: unknown = (globalThis as unknown as { crypto?: unknown }).crypto
    this.crypto = options?.crypto === undefined ? (isCrypto(cryptoAny) ? cryptoAny : null) : options.crypto
  }

  configure(client: ProtocolClient) {
    this.client = client
  }

  start() {
    if (this.running) return
    this.running = true
    this.reset()
    void this.loop()
  }

  stop() {
    this.running = false
    this.clearSleep()
    this.reset()
  }

  async ping() {
    const client = this.client
    if (!client) return
    if (client.state !== "open") return

    const nonce = this.randomNonce()
    await client.sendPing(nonce)
    this.pings.set(nonce, Date.now())
  }

  pong(nonce: bigint) {
    const pingDate = this.pings.get(nonce)
    if (!pingDate) return
    this.pings.delete(nonce)
  }

  private async loop() {
    while (this.running) {
      await this.checkConnection()
      await this.sleep(10_000)
      if (!this.running) break
      await this.ping()
    }
  }

  private reset() {
    this.pings.clear()
  }

  private async checkConnection() {
    const client = this.client
    if (!client) return
    if (client.state !== "open") return

    const now = Date.now()
    const hasTimedOutPing = [...this.pings.values()].some((timestamp) => now - timestamp > 30_000)
    if (!hasTimedOutPing) return

    this.log.warn?.("Ping timeout, reconnecting")
    await client.reconnect()
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
    if (this.crypto) {
      const buf = new Uint32Array(2)
      this.crypto.getRandomValues(buf)
      // Under `noUncheckedIndexedAccess`, `buf[0]` becomes `number | undefined`.
      // This array is fixed-size (2), so the cast is safe.
      const hi = buf[0] as number
      const lo = buf[1] as number
      return (BigInt(hi) << 32n) | BigInt(lo)
    }

    return BigInt(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER))
  }
}

const isCrypto = (value: unknown): value is Crypto =>
  typeof value === "object" && value !== null && "getRandomValues" in value && typeof (value as Crypto).getRandomValues === "function"
