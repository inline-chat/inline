import type { RedisClient } from "bun"

export type BrokerHealth = "ready" | "unavailable" | "closed"
export type BrokerPublication = { status: "published"; subscribers: number } | { status: "unavailable" }

const OPERATION_TIMEOUT_MS = 500
type ConnectionPair = { commands: RedisClient; subscriber: RedisClient }
const closeClient = (client: RedisClient): void => {
  // Bun may already have torn the native client down after a remote close.
  try { client.close() } catch { /* the socket is already unusable */ }
}
const bounded = <T>(operation: Promise<T>): Promise<T> => new Promise<T>((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error("Broker operation timed out")), OPERATION_TIMEOUT_MS)
  timer.unref?.()
  operation.then((value) => { clearTimeout(timer); resolve(value) }, (error) => { clearTimeout(timer); reject(error) })
})

/** A private, disposable transport. Feature code must use service.ts, never this client. */
export class InternalRedisTransport {
  private pair: ConnectionPair | undefined
  private reconnectTimer: ReturnType<typeof setTimeout> | undefined
  private state: BrokerHealth = "unavailable"
  private stopped = false
  private connecting = false
  private readonly listeners = new Map<string, (message: string) => void>()
  private readonly continuityListeners = new Set<() => void>()
  private readonly readyListeners = new Set<() => void>()
  private readonly url: string | undefined

  constructor(url: string | undefined) {
    this.url = url?.trim() || undefined
  }

  get health(): BrokerHealth { return this.state }

  onContinuityLost(listener: () => void): () => void {
    this.continuityListeners.add(listener)
    return () => this.continuityListeners.delete(listener)
  }
  onReady(listener: () => void): () => void {
    this.readyListeners.add(listener)
    return () => this.readyListeners.delete(listener)
  }

  async start(channels: readonly string[], receive: (message: string, channel: string) => void): Promise<void> {
    for (const channel of channels) this.listeners.set(channel, (message) => receive(message, channel))
    // PostgreSQL recovery is always available. Try the optional fast path once;
    // a failed attempt reconnects in the background without holding admission.
    await this.connect()
  }

  private async connect(): Promise<void> {
    if (this.stopped || this.connecting || !this.url) return
    this.connecting = true
    const options = { connectionTimeout: 1_000, autoReconnect: false, enableOfflineQueue: false }
    let commands: RedisClient | undefined
    let subscriber: RedisClient | undefined
    let pair: ConnectionPair | undefined
    try {
      // Vitest imports the server graph under Node. Load Bun's Redis client
      // only when a Bun process actually starts the cluster transport.
      const builtin = "bun"
      const { RedisClient: BunRedisClient } = await import(/* @vite-ignore */ builtin) as typeof import("bun")
      if (this.stopped) return
      commands = new BunRedisClient(this.url, options)
      subscriber = new BunRedisClient(this.url, options)
      pair = { commands, subscriber }
      this.pair = pair
      const currentPair = pair
      commands.onclose = () => this.disconnected(currentPair)
      subscriber.onclose = () => this.disconnected(currentPair)
      await Promise.all([commands.connect(), subscriber.connect()])
      if (this.stopped || this.pair !== pair) return
      for (const [channel, listener] of this.listeners) {
        await bounded(subscriber.subscribe(channel, (message) => {
          if (this.pair === currentPair && !this.stopped) listener(message)
        }))
      }
      // A socket can close while the other subscription is still being
      // established. Never report a half-connected pair as ready.
      if (this.stopped || this.pair !== pair || !commands.connected || !subscriber.connected) {
        this.disconnected(pair)
        return
      }
      this.state = "ready"
      for (const listener of this.readyListeners) {
        try { listener() } catch { /* readiness observers are best effort */ }
      }
    } catch {
      if (pair) this.disconnected(pair)
      else {
        if (commands) closeClient(commands)
        if (subscriber) closeClient(subscriber)
      }
    } finally {
      this.connecting = false
      if (this.state !== "ready") this.scheduleReconnect()
    }
  }

  private disconnected(pair: ConnectionPair): void {
    // A timeout or callback from an old pair cannot tear down its replacement.
    if (this.stopped || this.pair !== pair) return
    const wasReady = this.state === "ready"
    this.state = "unavailable"
    this.pair = undefined
    // Invalidate ownership before closing either socket: onclose may re-enter.
    // Unsubscribe also clears Bun's local subscription references, including
    // when the remote socket is already closed. Do not wait on a broken pair.
    void this.unsubscribe(pair)
    closeClient(pair.commands)
    closeClient(pair.subscriber)
    if (wasReady) for (const listener of this.continuityListeners) {
      try { listener() } catch { /* observers cannot prevent transport recovery */ }
    }
    this.scheduleReconnect()
  }

  private scheduleReconnect(): void {
    if (this.stopped || !this.url || this.reconnectTimer) return
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined
      void this.connect()
    }, 750 + Math.floor(Math.random() * 1_500))
    this.reconnectTimer.unref?.()
  }

  async publish(channel: string, frame: string): Promise<BrokerPublication> {
    const pair = this.readyPair()
    if (!pair) return { status: "unavailable" }
    try {
      return { status: "published", subscribers: await bounded(pair.commands.publish(channel, frame)) }
    } catch {
      this.disconnected(pair)
      return { status: "unavailable" }
    }
  }

  async get(key: string): Promise<string | null | undefined> {
    const pair = this.readyPair()
    if (!pair) return undefined
    try { return await bounded(pair.commands.get(key)) } catch { this.disconnected(pair); return undefined }
  }

  async setExpiring(key: string, value: string, ttlMs: number): Promise<boolean> {
    const pair = this.readyPair()
    if (!pair) return false
    try { await bounded(pair.commands.set(key, value, "PX", ttlMs)); return true } catch { this.disconnected(pair); return false }
  }

  async delete(key: string): Promise<boolean> {
    const pair = this.readyPair()
    if (!pair) return false
    try { await bounded(pair.commands.del(key)); return true } catch { this.disconnected(pair); return false }
  }

  async command(name: string, args: string[]): Promise<unknown | undefined> {
    const pair = this.readyPair()
    if (!pair) return undefined
    try { return await bounded(pair.commands.send(name, args)) } catch { this.disconnected(pair); return undefined }
  }

  private readyPair(): ConnectionPair | undefined {
    const pair = this.pair
    return this.state === "ready" && pair?.commands.connected && pair.subscriber.connected ? pair : undefined
  }

  private async unsubscribe(pair: ConnectionPair): Promise<void> {
    await Promise.all(Array.from(this.listeners.keys(), async (channel) => {
      try { await bounded(pair.subscriber.unsubscribe(channel)) }
      catch { /* local subscription references are cleared even after disconnect */ }
    }))
  }

  async close(): Promise<void> {
    this.stopped = true
    this.state = "closed"
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer)
    const pair = this.pair
    this.pair = undefined
    if (pair) {
      // Bun 1.4 keeps subscribed clients referenced after close(). Explicitly
      // remove subscriptions before closing so shutdown can exit naturally.
      try {
        await this.unsubscribe(pair)
      } finally {
        closeClient(pair.commands)
        closeClient(pair.subscriber)
      }
    }
  }
}
