const DEFAULT_FLUSH_INTERVAL_MS = 60_000
const DEFAULT_MAX_SESSIONS_PER_WRITE = 512
const DEFAULT_MAX_PENDING_SESSIONS = 4_096

export type SessionActivityWriter = (sessionIds: readonly number[]) => Promise<void>

const defaultWriter: SessionActivityWriter = async (sessionIds) => {
  const { SessionsModel } = await import("@in/server/db/models/sessions")
  await SessionsModel.touchLastActiveBulk(sessionIds)
}

export type SessionActivityTrackerOptions = {
  readonly write?: SessionActivityWriter
  readonly flushIntervalMs?: number
  readonly maxSessionsPerWrite?: number
  readonly maxPendingSessions?: number
  readonly reportError?: (error: unknown) => void
}

/**
 * Coalesces durable session activity. `mark` is O(1): it writes only into a
 * bounded Map. Each timer tick atomically swaps that Map for a snapshot, then
 * writes its batches sequentially. Marks arriving during a write land in the
 * next snapshot, so they cannot keep the first batch at the head forever.
 */
export class SessionActivityTracker {
  private readonly activeSessions = new Set<number>()
  private pendingSessions = new Map<number, true>()
  private readonly write: SessionActivityWriter
  private readonly flushIntervalMs: number
  private readonly maxSessionsPerWrite: number
  private readonly maxPendingSessions: number
  private readonly reportError: (error: unknown) => void
  private timer: ReturnType<typeof setInterval> | undefined
  private flushInFlight: Promise<void> | undefined
  private shutdownTask: Promise<void> | undefined
  private running = true
  private generation = 1

  constructor({
    write = defaultWriter,
    flushIntervalMs = DEFAULT_FLUSH_INTERVAL_MS,
    maxSessionsPerWrite = DEFAULT_MAX_SESSIONS_PER_WRITE,
    maxPendingSessions = DEFAULT_MAX_PENDING_SESSIONS,
    reportError = () => {},
  }: SessionActivityTrackerOptions = {}) {
    this.write = write
    this.flushIntervalMs = Math.max(1, Math.floor(flushIntervalMs))
    this.maxSessionsPerWrite = Math.max(1, Math.floor(maxSessionsPerWrite))
    this.maxPendingSessions = Math.max(this.maxSessionsPerWrite, Math.floor(maxPendingSessions))
    this.reportError = reportError
  }

  /** Begins a new owner generation only after the prior shutdown completed. */
  start(): number {
    if (this.shutdownTask) throw new Error("Session activity cannot restart before shutdown completes")
    if (this.running) return this.generation
    this.running = true
    this.generation += 1
    this.activeSessions.clear()
    this.pendingSessions.clear()
    return this.generation
  }

  activate(sessionId: number, generation = this.generation): void {
    if (!this.isCurrentGeneration(generation) || !isSessionId(sessionId)) return
    this.activeSessions.add(sessionId)
    this.mark(sessionId, generation)
  }

  deactivate(sessionId: number, generation = this.generation): void {
    if (!this.isCurrentGeneration(generation)) return
    this.activeSessions.delete(sessionId)
    this.pendingSessions.delete(sessionId)
  }

  /** Called from authenticated frame paths. It only changes bounded local state. */
  mark(sessionId: number, generation = this.generation): void {
    if (!this.isCurrentGeneration(generation) || !this.activeSessions.has(sessionId)) return
    this.enqueue(sessionId)
    this.ensureTimer(generation)
  }

  /** Exposed for lifecycle shutdown and deterministic tests. */
  async flushNow(generation = this.generation): Promise<void> {
    if (!this.isCurrentGeneration(generation)) return
    if (this.flushInFlight) {
      await this.flushInFlight
      return
    }

    this.enqueueActiveSweep()
    const snapshot = this.takePendingSnapshot()
    if (snapshot.size === 0) return
    await this.runSnapshot(snapshot)
  }

  /** Stops the producer and joins a current snapshot or one final bounded write. */
  shutdown(generation = this.generation): Promise<void> {
    if (generation !== this.generation) return Promise.resolve()
    if (this.shutdownTask) return this.shutdownTask
    if (!this.running) return Promise.resolve()
    const task = this.stop(generation).finally(() => {
      if (this.shutdownTask === task) this.shutdownTask = undefined
    })
    this.shutdownTask = task
    return task
  }

  private async stop(generation: number): Promise<void> {
    this.running = false
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = undefined
    }

    try {
      if (this.flushInFlight) {
        await this.flushInFlight
      } else {
        await this.writeFinalBatch()
      }
    } catch (error) {
      this.reportError(error)
    } finally {
      if (this.generation === generation) {
        this.activeSessions.clear()
        this.pendingSessions.clear()
      }
    }
  }

  private ensureTimer(generation: number): void {
    if (this.timer || !this.isCurrentGeneration(generation)) return
    this.timer = setInterval(() => {
      void this.flushNow(generation).catch((error) => this.reportError(error))
    }, this.flushIntervalMs)
    this.timer.unref?.()
  }

  private enqueue(sessionId: number): void {
    if (this.pendingSessions.has(sessionId) || this.pendingSessions.size >= this.maxPendingSessions) return
    this.pendingSessions.set(sessionId, true)
  }

  /**
   * Quiet sockets are refreshed without copying every active id. Successful
   * writes move their session ids to the tail of the Set, so this bounded
   * iteration starts at sessions that have waited longest on the next tick.
   */
  private enqueueActiveSweep(): void {
    let attempts = Math.min(this.activeSessions.size, this.maxPendingSessions - this.pendingSessions.size)
    for (const sessionId of this.activeSessions) {
      if (attempts <= 0) return
      this.enqueue(sessionId)
      attempts -= 1
    }
  }

  private takePendingSnapshot(): Map<number, true> {
    const snapshot = this.pendingSessions
    this.pendingSessions = new Map()
    return snapshot
  }

  private async runSnapshot(snapshot: Map<number, true>): Promise<void> {
    const run = this.writeSnapshot(snapshot)
    this.flushInFlight = run
    try {
      await run
    } finally {
      if (this.flushInFlight === run) this.flushInFlight = undefined
    }
  }

  private async writeSnapshot(snapshot: Map<number, true>): Promise<void> {
    let batch: number[] = []
    try {
      while (snapshot.size > 0) {
        batch = this.takeBatch(snapshot)
        if (batch.length === 0) continue
        await this.write(batch)
        this.rotateActiveSessions(batch)
        batch = []
      }
    } catch (error) {
      // Preserve active failed work at the tail of the next bounded snapshot.
      for (const sessionId of batch) this.enqueueIfActive(sessionId)
      for (const sessionId of snapshot.keys()) this.enqueueIfActive(sessionId)
      throw error
    }
  }

  private takeBatch(snapshot: Map<number, true>): number[] {
    const batch: number[] = []
    for (const sessionId of snapshot.keys()) {
      snapshot.delete(sessionId)
      if (this.activeSessions.has(sessionId)) batch.push(sessionId)
      if (batch.length === this.maxSessionsPerWrite) break
    }
    return batch
  }

  private async writeFinalBatch(): Promise<void> {
    const snapshot = this.takePendingSnapshot()
    const batch = this.takeBatch(snapshot)
    if (batch.length > 0) await this.write(batch)
  }

  private enqueueIfActive(sessionId: number): void {
    if (this.activeSessions.has(sessionId)) this.enqueue(sessionId)
  }

  private rotateActiveSessions(sessionIds: readonly number[]): void {
    for (const sessionId of sessionIds) {
      if (!this.activeSessions.delete(sessionId)) continue
      this.activeSessions.add(sessionId)
    }
  }

  private isCurrentGeneration(generation: number): boolean {
    return this.running && this.generation === generation
  }
}

const isSessionId = (sessionId: number): boolean =>
  Number.isSafeInteger(sessionId) && sessionId > 0
