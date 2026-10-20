import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { sql } from "drizzle-orm"

// One process-independent PostgreSQL lock coordinates durable update commits
// with discovery watermarks. The numeric key is deliberately stable across
// deploys and server instances.
// This is a prospective date-cursor guarantee: drain old/unfenced writers at
// rollout, and keep the database clock disciplined. It cannot reconstruct
// already-skipped updates or replace a durable monotonic discovery frontier.
// Longer term, a commit-sequence frontier (writers allocate a durable
// sequence; discovery reads the highest gap-free committed sequence) would
// replace both this lock and the date cursor. Not implemented here.
const UPDATE_DISCOVERY_LOCK_KEY = 4_922_095_338_106
const UPDATE_DISCOVERY_TIMEOUT_MS = 5_000
const INITIAL_DISCOVERY_RETRY_DELAY_MS = 10
const MAX_DISCOVERY_RETRY_DELAY_MS = 100

const readDatabaseClock = async (tx: Transaction): Promise<Date> => {
  const [row] = await tx.execute<{ databaseTimeMillis: number | string }>(sql`
    select (extract(epoch from clock_timestamp()) * 1000)::double precision as "databaseTimeMillis"
  `)
  // Raw driver timestamp decoding differs from Drizzle's mapped date columns.
  // An explicit epoch scalar avoids locale/timezone-dependent string parsing.
  const millis = row === undefined ? NaN : Number(row.databaseTimeMillis)
  if (!Number.isFinite(millis)) {
    throw new Error("Failed to read update discovery database clock")
  }
  return new Date(millis)
}

/**
 * Durable update writers hold the shared side until their outer transaction
 * commits. The database clock must only be sampled after this fence is held.
 */
export const acquireUpdateDiscoveryWriterFence = async (
  tx: Transaction,
): Promise<Date> => {
  await tx.execute(sql`
    select pg_advisory_xact_lock_shared(${UPDATE_DISCOVERY_LOCK_KEY}::bigint)
  `)
  return await readDatabaseClock(tx)
}

/**
 * One exclusive try: wait for nothing, sample the clock only while holding the
 * exclusive side, and release it at commit. `wanted` reports whether any caller
 * this try serves is still within its budget.
 */
export type UpdateDiscoveryWatermarkAttempt = (wanted: () => boolean) => Promise<Date | undefined>

const tryCaptureWatermark: UpdateDiscoveryWatermarkAttempt = async (wanted) =>
  await db.transaction(async (tx) => {
    // Pool contention also consumes the same budget, not a fresh attempt.
    if (!wanted()) throw discoveryTimeout()
    const [row] = await tx.execute<{ acquired: boolean }>(sql`
      select pg_try_advisory_xact_lock(${UPDATE_DISCOVERY_LOCK_KEY}::bigint) as acquired
    `)
    return row?.acquired === true ? await readDatabaseClock(tx) : undefined
  })

type WatermarkWaiter = {
  readonly firstAttempt: number
  readonly deadline: number
  readonly resolve: (watermark: Date) => void
  readonly reject: (error: unknown) => void
}

/**
 * Single-flight capture for one process. Concurrent callers share one retry
 * loop, so a reconnect wave makes one try (one pooled connection) at a time
 * instead of one retry loop per caller.
 *
 * A caller only accepts a watermark from a try that started after it arrived.
 * Any watermark sampled under the exclusive side already proves that every
 * fenced writer at or before it committed; the arrival rule additionally keeps
 * a shared watermark from predating the request, so it never falls behind a
 * checkpoint the client already holds (which would read as a repair marker).
 * Each caller keeps its own 5 s budget and still fails rather than receiving a
 * substitute checkpoint.
 */
export class UpdateDiscoveryWatermarks {
  #waiters: WatermarkWaiter[] = []
  #startedAttempts = 0
  #running = false

  constructor(
    private readonly runtime: {
      readonly attempt: UpdateDiscoveryWatermarkAttempt
      readonly now: () => number
      readonly sleep: (ms: number) => Promise<void>
    } = { attempt: tryCaptureWatermark, now: () => performance.now(), sleep: (ms) => Bun.sleep(ms) },
  ) {}

  capture(): Promise<Date> {
    const { promise, resolve, reject } = Promise.withResolvers<Date>()
    this.#waiters.push({
      firstAttempt: this.#startedAttempts + 1,
      deadline: this.runtime.now() + UPDATE_DISCOVERY_TIMEOUT_MS,
      resolve,
      reject,
    })
    if (!this.#running) {
      this.#running = true
      void this.#run()
    }
    return promise
  }

  async #run(): Promise<void> {
    let retryDelayMs = INITIAL_DISCOVERY_RETRY_DELAY_MS
    try {
      while (this.#waiters.length > 0) {
        const attempt = ++this.#startedAttempts
        const served = (waiter: WatermarkWaiter) => waiter.firstAttempt <= attempt
        let watermark: Date | undefined
        let failure: { readonly error: unknown } | undefined
        try {
          watermark = await this.runtime.attempt(() =>
            this.#waiters.some((waiter) => served(waiter) && this.runtime.now() < waiter.deadline))
        } catch (error) {
          failure = { error }
        }

        const now = this.runtime.now()
        const waiting: WatermarkWaiter[] = []
        let earliestDeadline = Infinity
        for (const waiter of this.#waiters) {
          if (served(waiter) && failure) waiter.reject(failure.error)
          else if (now >= waiter.deadline) waiter.reject(discoveryTimeout())
          else if (served(waiter) && watermark) waiter.resolve(watermark)
          else {
            waiting.push(waiter)
            earliestDeadline = Math.min(earliestDeadline, waiter.deadline)
          }
        }
        this.#waiters = waiting
        if (waiting.length === 0) break

        // Callers that arrived during a completed try get their own try now;
        // a refused try backs off for everyone still waiting.
        if (failure || watermark) {
          retryDelayMs = INITIAL_DISCOVERY_RETRY_DELAY_MS
          continue
        }
        await this.runtime.sleep(Math.max(0, Math.min(retryDelayMs, earliestDeadline - now)))
        retryDelayMs = Math.min(retryDelayMs * 2, MAX_DISCOVERY_RETRY_DELAY_MS)
      }
    } catch (error) {
      // Defensive: never strand a caller behind a stopped loop.
      for (const waiter of this.#waiters.splice(0)) waiter.reject(error)
    }
    // Synchronous with the last empty check, so a new caller always restarts the loop.
    this.#running = false
  }
}

const sharedWatermarks = new UpdateDiscoveryWatermarks()

/**
 * Wait for every already-fenced writer to commit, capture a database-clock
 * watermark, and release the exclusive side before doing resource/access work.
 * Never queue an exclusive lock: a writer may already own resource rows before
 * taking its shared fence. An exclusive waiter would block that new shared
 * acquisition and could deadlock against an earlier writer waiting for its rows.
 * Each failed try releases its connection before the bounded retry delay.
 * A timeout rejects the RPC; callers must never substitute or advance a
 * checkpoint when this transaction fails.
 */
export const captureUpdateDiscoveryWatermark = (): Promise<Date> => sharedWatermarks.capture()

const discoveryTimeout = (): Error => new Error("Timed out waiting for durable update discovery writers")
