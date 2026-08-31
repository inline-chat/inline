import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { sql } from "drizzle-orm"

// One process-independent PostgreSQL lock coordinates durable update commits
// with discovery watermarks. The numeric key is deliberately stable across
// deploys and server instances.
// This is a prospective date-cursor guarantee: drain old/unfenced writers at
// rollout, and keep the database clock disciplined. It cannot reconstruct
// already-skipped updates or replace a durable monotonic discovery frontier.
const UPDATE_DISCOVERY_LOCK_KEY = 4_922_095_338_106
const UPDATE_DISCOVERY_TIMEOUT_MS = 5_000
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
 * Wait for every already-fenced writer to commit, capture a database-clock
 * watermark, and release the exclusive side before doing resource/access work.
 * Never queue an exclusive lock: a writer may already own resource rows before
 * taking its shared fence. An exclusive waiter would block that new shared
 * acquisition and could deadlock against an earlier writer waiting for its rows.
 * Each failed try releases its connection before the bounded retry delay.
 * A timeout rejects the RPC; callers must never substitute or advance a
 * checkpoint when this transaction fails.
 */
export const captureUpdateDiscoveryWatermark = async (): Promise<Date> => {
  const deadline = performance.now() + UPDATE_DISCOVERY_TIMEOUT_MS
  let retryDelayMs = 10

  while (true) {
    const watermark = await db.transaction(async (tx) => {
      // Pool contention also consumes the same budget, not a fresh attempt.
      ensureBeforeDeadline(deadline)
      const [row] = await tx.execute<{ acquired: boolean }>(sql`
        select pg_try_advisory_xact_lock(${UPDATE_DISCOVERY_LOCK_KEY}::bigint) as acquired
      `)
      return row?.acquired === true ? await readDatabaseClock(tx) : undefined
    })
    ensureBeforeDeadline(deadline)
    if (watermark) return watermark

    await Bun.sleep(Math.min(retryDelayMs, deadline - performance.now()))
    retryDelayMs = Math.min(retryDelayMs * 2, MAX_DISCOVERY_RETRY_DELAY_MS)
  }
}

const ensureBeforeDeadline = (deadline: number): void => {
  if (performance.now() >= deadline) {
    throw new Error("Timed out waiting for durable update discovery writers")
  }
}
