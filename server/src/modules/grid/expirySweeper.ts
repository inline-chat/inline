import type { GridConnection } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { gridPresence, gridRooms } from "@in/server/db/schema"
import { notifyGridChanged, onGridChanged } from "@in/server/modules/grid/realtime"
import {
  activeGridConnection,
  reconcileGridRoom,
  recordGridParticipantRevocation,
  tryLockGridMutations,
  type GridMutationState,
} from "@in/server/modules/grid/roomLifecycle"
import {
  nextGridTranscriptionDeadline,
  retireUnclaimedGridTranscriptions,
} from "@in/server/modules/grid/transcription/state"
import { IdleBackoff, MAXIMUM_IDLE_POLL_INTERVAL_MS } from "@in/server/utils/idleBackoff"
import { Log } from "@in/server/utils/log"
import { asc, eq, inArray, lte, min } from "drizzle-orm"

const SWEEP_BATCH_SIZE = 100
// A committed change is probed after this delay, so a burst of joins costs one
// probe. New presence expires 5 minutes out and new capture runs 30 s out.
const WAKE_DELAY_MS = 2_000
// Re-probe after progress; doubles up to the shared idle cap while the lock is
// busy, a sweep fails, or due work cannot be taken yet.
const RETRY_INTERVAL_MS = 1_000
// Leases are 5 minutes and capture runs at most 2 hours; bound the timer anyway.
const MAXIMUM_SLEEP_MS = 60 * 60_000
const log = new Log("grid.expirySweeper")

export type GridExpirySweep =
  | { readonly status: "idle"; readonly nextDueAt?: Date }
  | { readonly status: "busy" }
  | { readonly status: "swept"; readonly expiredPresences: number; readonly retiredTranscriptionSpaces: number }

/** Earliest presence lease or capture-run deadline, read from indexes without the Grid lock. */
async function nextGridExpiry(): Promise<Date | undefined> {
  // min() over the lease index reads one index entry, and nothing when the table is empty.
  const [presence] = await db.select({ dueAt: min(gridPresence.leaseExpiresAt) }).from(gridPresence)
  const presenceDueAt = presence?.dueAt ?? undefined
  const transcriptionDueAt = await nextGridTranscriptionDeadline(db)
  if (!presenceDueAt || !transcriptionDueAt) return presenceDueAt ?? transcriptionDueAt
  return presenceDueAt < transcriptionDueAt ? presenceDueAt : transcriptionDueAt
}

/**
 * Expires leased presence and abandoned transcription runs off the read path.
 * A sweep runs under the Grid mutation lock, so every deleted presence is
 * reconciled and revoked exactly as before. It never waits for that lock:
 * when a mutation holds it, the sweep reports busy and retries later.
 */
export async function sweepExpiredGridState(): Promise<GridExpirySweep> {
  const cutoff = new Date()
  const dueAt = await nextGridExpiry()
  if (!dueAt || dueAt > cutoff) return { status: "idle", nextDueAt: dueAt }

  const result = await db.transaction(async (tx) => {
    if (!(await tryLockGridMutations(tx))) return undefined
    // Row locks order this against lockless lease renewal: a presence whose
    // renewal is in flight is skipped, and a committed renewal no longer
    // matches the cutoff when the lock is taken. Only the rows deleted here
    // are reconciled and revoked, so a live avatar is never revoked.
    const candidates = await tx
      .select({
        room: gridRooms,
        userId: gridPresence.userId,
        mediaMembershipId: gridPresence.mediaMembershipId,
      })
      .from(gridPresence)
      .innerJoin(gridRooms, eq(gridRooms.id, gridPresence.roomId))
      .where(lte(gridPresence.leaseExpiresAt, cutoff))
      .orderBy(asc(gridPresence.userId))
      .limit(SWEEP_BATCH_SIZE)
      .for("update", { of: gridPresence, skipLocked: true })
    const deleted = candidates.length === 0
      ? []
      : await tx
          .delete(gridPresence)
          .where(inArray(gridPresence.userId, candidates.map(({ userId }) => userId)))
          .returning({ userId: gridPresence.userId })
    const deletedUserIds = new Set(deleted.map(({ userId }) => userId))
    const expired = candidates.filter(({ userId }) => deletedUserIds.has(userId))

    const endedConnections: GridConnection[] = []
    for (const roomId of new Set(expired.map(({ room }) => room.id))) {
      const endedConnection = await reconcileGridRoom(tx, roomId)
      if (endedConnection) endedConnections.push(endedConnection)
    }
    const state: GridMutationState = {
      affectedSpaceIds: new Set(expired.map(({ room }) => room.spaceId)),
      endedConnections,
    }
    for (const { room, userId, mediaMembershipId } of expired) {
      const connection = activeGridConnection(room)
      if (connection) await recordGridParticipantRevocation(tx, state, connection, userId, mediaMembershipId)
    }
    const retiredSpaceIds = await retireUnclaimedGridTranscriptions(tx)
    for (const spaceId of retiredSpaceIds) state.affectedSpaceIds.add(spaceId)
    return { state, expiredPresences: expired.length, retiredTranscriptionSpaces: retiredSpaceIds.size }
  })
  if (!result) return { status: "busy" }
  if (result.state.affectedSpaceIds.size > 0) await notifyGridChanged(result.state)
  return {
    status: "swept",
    expiredPresences: result.expiredPresences,
    retiredTranscriptionSpaces: result.retiredTranscriptionSpaces,
  }
}

type GridExpirySweeperRuntime = {
  readonly sweep: () => Promise<GridExpirySweep>
  readonly subscribe: (listener: () => void) => () => void
  readonly now: () => number
  readonly setTimeoutFn: (handler: () => void, timeout: number) => ReturnType<typeof setTimeout>
  readonly clearTimeoutFn: (id: ReturnType<typeof setTimeout>) => void
}

/**
 * Deadline-driven, not polling. One probe at start learns the earliest lease or
 * capture deadline; the sweeper then sleeps until it. With no presence and no
 * capture run it arms no timer at all, so an idle instance makes no queries
 * until a committed Grid change here or a hint from another node wakes it.
 * Lease renewals only move deadlines later, so they need no wake.
 */
export class GridExpirySweeper {
  #timer: ReturnType<typeof setTimeout> | null = null
  #armedAt: number | null = null
  #inFlight: Promise<void> | null = null
  #wokenDuringSweep = false
  #unsubscribe: (() => void) | null = null
  #failureCount = 0
  readonly #retry = IdleBackoff.forInterval(RETRY_INTERVAL_MS, MAXIMUM_IDLE_POLL_INTERVAL_MS)
  readonly #runtime: GridExpirySweeperRuntime

  constructor(runtime: Partial<GridExpirySweeperRuntime> = {}) {
    this.#runtime = {
      sweep: runtime.sweep ?? sweepExpiredGridState,
      subscribe: runtime.subscribe ?? onGridChanged,
      now: runtime.now ?? Date.now,
      setTimeoutFn: runtime.setTimeoutFn ?? setTimeout,
      clearTimeoutFn: runtime.clearTimeoutFn ?? clearTimeout,
    }
  }

  start(): void {
    if (this.#unsubscribe) return
    this.#unsubscribe = this.#runtime.subscribe(() => this.wake())
    void this.sweepOnce()
  }

  /** A committed Grid change may have added presence or a capture run. */
  wake(): void {
    if (!this.#unsubscribe) return
    if (this.#inFlight) {
      this.#wokenDuringSweep = true
      return
    }
    this.#arm(this.#runtime.now() + WAKE_DELAY_MS)
  }

  async stop(): Promise<void> {
    this.#unsubscribe?.()
    this.#unsubscribe = null
    this.#disarm()
    await this.#inFlight
  }

  /** When the next probe runs, or null while dormant; for diagnostics and tests. */
  get nextSweepAt(): number | null {
    return this.#armedAt
  }

  sweepOnce(): Promise<void> {
    if (this.#inFlight) return this.#inFlight
    this.#disarm()
    const work = this.#sweep().finally(() => {
      if (this.#inFlight === work) this.#inFlight = null
    })
    this.#inFlight = work
    return work
  }

  async #sweep(): Promise<void> {
    let nextAt: number | undefined
    try {
      const sweep = await this.#runtime.sweep()
      this.#failureCount = 0
      if (sweep.status === "idle") {
        this.#retry.reset()
        nextAt = sweep.nextDueAt?.getTime()
      } else if (sweep.status === "swept" && sweep.expiredPresences + sweep.retiredTranscriptionSpaces > 0) {
        this.#retry.reset()
        log.debug("GRID_TRACE phase=expiry_sweep", {
          expiredPresences: sweep.expiredPresences,
          retiredTranscriptionSpaces: sweep.retiredTranscriptionSpaces,
        })
        nextAt = this.#runtime.now() + RETRY_INTERVAL_MS
      } else {
        nextAt = this.#retryAt()
      }
    } catch (error) {
      this.#failureCount += 1
      if (this.#failureCount === 1 || this.#failureCount === 10 || this.#failureCount % 100 === 0) {
        log.warn("Failed to sweep expired Grid state", { consecutiveFailures: this.#failureCount, error })
      }
      nextAt = this.#retryAt()
    }
    if (!this.#unsubscribe) return
    const now = this.#runtime.now()
    if (this.#wokenDuringSweep) {
      this.#wokenDuringSweep = false
      nextAt = Math.min(nextAt ?? Infinity, now + WAKE_DELAY_MS)
    }
    if (nextAt !== undefined) this.#arm(Math.max(nextAt, now + RETRY_INTERVAL_MS))
  }

  #retryAt(): number {
    const at = this.#runtime.now() + RETRY_INTERVAL_MS * this.#retry.multiplier
    this.#retry.observe(false)
    return at
  }

  #arm(at: number): void {
    const now = this.#runtime.now()
    const bounded = Math.min(at, now + MAXIMUM_SLEEP_MS)
    if (this.#armedAt !== null && this.#armedAt <= bounded) return
    this.#disarm()
    this.#armedAt = bounded
    this.#timer = this.#runtime.setTimeoutFn(() => {
      this.#timer = null
      this.#armedAt = null
      void this.sweepOnce()
    }, Math.max(0, bounded - now))
  }

  #disarm(): void {
    if (this.#timer !== null) this.#runtime.clearTimeoutFn(this.#timer)
    this.#timer = null
    this.#armedAt = null
  }
}

let sweeper: GridExpirySweeper | null = null

export function startGridExpirySweeper(): GridExpirySweeper {
  sweeper ??= new GridExpirySweeper()
  sweeper.start()
  return sweeper
}

export async function stopGridExpirySweeper(owned: GridExpirySweeper | null = sweeper): Promise<void> {
  if (!owned) return
  if (sweeper === owned) sweeper = null
  await owned.stop()
}
