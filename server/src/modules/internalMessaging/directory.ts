import { internalMessaging } from "./service"

export type ConnectionRegistration = {
  bootId: string
  connectionId: string
  userId: number
  sessionId: number
  clientType: string
  isBot: boolean
  expiresAt: number
}

const EXPIRY_MS = 45_000
const MAX_USER_CONNECTIONS = 128
const RENEW_INTERVAL_MS = 10_000
/**
 * A reconnect or a busy node may have thousands of local registrations. Keep
 * the directory's best-effort Redis work below one bounded concurrency budget
 * rather than creating one command/promise per socket at once.
 */
export const maxConcurrentDirectoryWrites = 32
export const maxPendingDirectoryWrites = 4_096

type LocalRegistration = Omit<ConnectionRegistration, "expiresAt">

type DesiredDirectoryWrite =
  | { readonly kind: "register"; readonly record: LocalRegistration }
  | { readonly kind: "remove"; readonly record: LocalRegistration }

/** One coalesced desired state per connection, whether queued or in flight. */
type DirectoryWriteState = {
  readonly connectionId: string
  desired: DesiredDirectoryWrite
  version: number
  running: boolean
  queued: boolean
}

const registerScript = `
redis.call('ZREMRANGEBYSCORE', KEYS[2], '-inf', ARGV[1])
redis.call('SET', KEYS[1], ARGV[2], 'PX', ARGV[3])
redis.call('ZADD', KEYS[2], ARGV[4], KEYS[1])
local excess = redis.call('ZCARD', KEYS[2]) - ${MAX_USER_CONNECTIONS}
if excess > 0 then redis.call('ZREMRANGEBYRANK', KEYS[2], 0, excess - 1) end
redis.call('PEXPIRE', KEYS[2], ARGV[3] + 5000)
return 1`

const removeScript = `
redis.call('DEL', KEYS[1])
redis.call('ZREM', KEYS[2], KEYS[1])
return 1`

/** The process owns only its own connection IDs. Redis registrations are hints, never authorization. */
export class ConnectionDirectory {
  private local = new Map<string, LocalRegistration>()
  /** Includes only the bounded queued and active desired states. */
  private readonly writes = new Map<string, DirectoryWriteState>()
  private readonly pendingWrites = new Map<string, DirectoryWriteState>()
  private readonly idleWaiters = new Set<() => void>()
  private activeWrites = 0
  private timer: ReturnType<typeof setTimeout> | undefined
  private stopped = false
  private rebuildsInFlight = 0
  private rebuildPromise: Promise<void> | undefined
  private shutdownPromise: Promise<void> | undefined
  private uncertainUntil = 0

  constructor(private readonly messaging = internalMessaging) {}

  resume(): void {
    this.stopped = false
    this.shutdownPromise = undefined
  }

  /** A newly reconnected broker may still be missing registrations from other boots. */
  async recoverFromBrokerRestart(): Promise<void> {
    this.uncertainUntil = Date.now() + EXPIRY_MS
    await this.rebuild()
  }

  register(input: Omit<ConnectionRegistration, "bootId" | "expiresAt">): void {
    if (this.stopped) return
    const record = { ...input, bootId: this.messaging.bootId }
    this.local.set(input.connectionId, record)
    this.requestWrite(input.connectionId, { kind: "register", record })
    this.scheduleRenewal()
  }

  unregister(connectionId: string): void {
    const record = this.local.get(connectionId)
    if (!record) return
    this.local.delete(connectionId)
    this.requestWrite(connectionId, { kind: "remove", record })
  }

  hasLocalConnection(connectionId: string, userId: number, sessionId: number): boolean {
    const record = this.local.get(connectionId)
    return record?.userId === userId && record.sessionId === sessionId
  }

  localUsers(): number[] { return [...new Set([...this.local.values()].map((record) => record.userId))] }

  async list(userId: number): Promise<{ status: "available"; complete: boolean; connections: ConnectionRegistration[] } | { status: "unavailable" }> {
    const now = Date.now()
    const result = await this.messaging.sendCommand("ZRANGEBYSCORE", [this.userIndexKey(userId), String(now + 1), "+inf", "LIMIT", "0", String(MAX_USER_CONNECTIONS)])
    if (!Array.isArray(result)) return { status: "unavailable" }
    const keys = result.filter((value): value is string => typeof value === "string")
    if (keys.length === 0) return { status: "available", complete: this.isComplete(), connections: [] }
    const values = await this.messaging.sendCommand("MGET", keys)
    if (!Array.isArray(values)) return { status: "unavailable" }
    const connections: ConnectionRegistration[] = []
    for (const value of values) {
      if (typeof value !== "string") continue
      try {
        const parsed: unknown = JSON.parse(value)
        if (!isRegistration(parsed) || parsed.userId !== userId || parsed.expiresAt <= now) continue
        connections.push(parsed)
      } catch { /* expired/corrupt hint */ }
    }
    return { status: "available", complete: this.isComplete(), connections }
  }

  rebuild(): Promise<void> {
    if (this.rebuildPromise) return this.rebuildPromise
    this.rebuildsInFlight++
    const rebuild = this.rebuildLocalRegistrations().finally(() => {
      this.rebuildsInFlight--
      this.rebuildPromise = undefined
    })
    this.rebuildPromise = rebuild
    return rebuild
  }

  shutdown(): Promise<void> {
    if (this.shutdownPromise) return this.shutdownPromise
    this.shutdownPromise = this.stopAndDrain()
    return this.shutdownPromise
  }

  private async stopAndDrain(): Promise<void> {
    this.stopped = true
    if (this.timer) clearTimeout(this.timer)
    this.timer = undefined
    // Keep the old map as the removal source without copying every record.
    // Renewals use `this.local`, so an in-flight rebuild observes the empty
    // replacement and cannot enqueue later registrations after this point.
    const records = this.local
    this.local = new Map()
    await this.rebuildPromise
    for (const record of records.values()) {
      await this.requestWriteWhenCapacityAllows(record.connectionId, {
        kind: "remove",
        record,
      })
    }
    await this.waitForIdle()
  }

  private async rebuildLocalRegistrations(): Promise<void> {
    // Do not snapshot into a second unbounded array. The initial count gives
    // this sweep a finite target even if new sockets arrive while it runs.
    let remaining = this.local.size
    const connectionIds = this.local.keys()
    while (remaining > 0) {
      remaining--
      const next = connectionIds.next()
      if (next.done || this.stopped) break
      while (!this.renew(next.value)) {
        await this.waitForIdle()
        if (this.stopped) return
      }
    }
    await this.waitForIdle()
  }

  private renew(connectionId: string): boolean {
    const record = this.local.get(connectionId)
    if (!record || this.stopped) return true
    return this.requestWrite(connectionId, { kind: "register", record })
  }

  /**
   * Records only the latest desired state for a connection. If I/O is already
   * running, the newer state gets one ordered follow-up command; repeated
   * churn never creates a promise chain or another queued item.
   */
  private requestWrite(connectionId: string, desired: DesiredDirectoryWrite): boolean {
    const existing = this.writes.get(connectionId)
    if (existing) {
      existing.desired = desired
      existing.version++
      return true
    }

    if (this.activeWrites >= maxConcurrentDirectoryWrites &&
        this.pendingWrites.size >= maxPendingDirectoryWrites) {
      // The Redis directory is advisory. Do not retain an extra closure when
      // saturated: mark the view incomplete until old registrations expire.
      this.markUncertain()
      return false
    }

    const state: DirectoryWriteState = {
      connectionId,
      desired,
      version: 1,
      running: false,
      queued: false,
    }
    this.writes.set(connectionId, state)
    this.admitExistingWrite(state)
    return true
  }

  private async requestWriteWhenCapacityAllows(
    connectionId: string,
    desired: DesiredDirectoryWrite,
  ): Promise<void> {
    while (!this.requestWrite(connectionId, desired)) {
      await this.waitForIdle()
    }
  }

  private admitExistingWrite(state: DirectoryWriteState): void {
    if (this.activeWrites < maxConcurrentDirectoryWrites) {
      this.startWrite(state)
      return
    }
    state.queued = true
    this.pendingWrites.set(state.connectionId, state)
  }

  private startWrite(state: DirectoryWriteState): void {
    state.running = true
    this.activeWrites++
    const version = state.version
    const desired = state.desired
    void this.runWrite(desired).finally(() => {
      this.activeWrites--
      state.running = false
      if (this.writes.get(state.connectionId) === state) {
        if (state.version === version) {
          this.writes.delete(state.connectionId)
        } else {
          this.admitExistingWrite(state)
        }
      }
      this.pumpWrites()
      this.resolveIdleWaiters()
    })
  }

  private pumpWrites(): void {
    while (this.activeWrites < maxConcurrentDirectoryWrites) {
      const next = this.pendingWrites.entries().next().value as
        | [string, DirectoryWriteState]
        | undefined
      if (!next) return
      const [connectionId, state] = next
      this.pendingWrites.delete(connectionId)
      state.queued = false
      this.startWrite(state)
    }
  }

  private async runWrite(desired: DesiredDirectoryWrite): Promise<void> {
    try {
      if (desired.kind === "remove") {
        await this.runDirectoryScript([
          removeScript,
          "2",
          this.recordKey(desired.record),
          this.userIndexKey(desired.record.userId),
        ])
        return
      }

      const now = Date.now()
      const record = { ...desired.record, expiresAt: now + EXPIRY_MS }
      await this.runDirectoryScript([
        registerScript,
        "2",
        this.recordKey(record),
        this.userIndexKey(record.userId),
        String(now),
        JSON.stringify(record),
        String(EXPIRY_MS),
        String(record.expiresAt),
      ])
    } catch {
      this.markUncertain()
    }
  }

  private waitForIdle(): Promise<void> {
    if (this.writes.size === 0) return Promise.resolve()
    return new Promise((resolve) => this.idleWaiters.add(resolve))
  }

  private resolveIdleWaiters(): void {
    if (this.writes.size !== 0) return
    for (const resolve of this.idleWaiters) resolve()
    this.idleWaiters.clear()
  }

  private async runDirectoryScript(args: string[]): Promise<void> {
    // The transport reports an unavailable command as `undefined`; accepting it
    // as a completed renewal would make an old registration look authoritative.
    if (await this.messaging.sendCommand("EVAL", args) !== 1) {
      this.markUncertain()
    }
  }

  private markUncertain(): void {
    this.uncertainUntil = Math.max(
      this.uncertainUntil,
      Date.now() + EXPIRY_MS,
    )
  }

  private scheduleRenewal(): void {
    if (this.timer || this.stopped) return
    this.timer = setTimeout(() => {
      this.timer = undefined
      void this.rebuild().finally(() => this.scheduleRenewal())
    }, RENEW_INTERVAL_MS + Math.floor(Math.random() * 2_000))
    this.timer.unref?.()
  }

  private isComplete(): boolean {
    return !this.stopped && this.rebuildsInFlight === 0 && this.writes.size === 0 && Date.now() >= this.uncertainUntil
  }

  private recordKey(record: Pick<ConnectionRegistration, "bootId" | "connectionId">): string {
    return this.messaging.key(`connection:${record.bootId}:${record.connectionId}`)
  }

  private userIndexKey(userId: number): string { return this.messaging.key(`connections:user:${userId}`) }
}

function isRegistration(value: unknown): value is ConnectionRegistration {
  if (!value || typeof value !== "object") return false
  const record = value as Partial<ConnectionRegistration>
  return typeof record.bootId === "string" && typeof record.connectionId === "string" &&
    Number.isSafeInteger(record.userId) && Number.isSafeInteger(record.sessionId) &&
    typeof record.clientType === "string" && typeof record.isBot === "boolean" &&
    Number.isSafeInteger(record.expiresAt)
}

export const connectionDirectory = new ConnectionDirectory()
