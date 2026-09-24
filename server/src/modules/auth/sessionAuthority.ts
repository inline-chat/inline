import { Log } from "@in/server/utils/log"

export type SessionAuthorityIdentity = {
  userId: number
  sessionId: number
}

export type SessionAuthorityConfiguration = {
  reconciliationIntervalMs: number
  maximumAuthorityAgeMs: number
  batchSize: number
  invalidationRetentionMs: number
}

export type SessionAuthorityBindings = {
  connectedSessions: () => readonly SessionAuthorityIdentity[]
  closeSession: (identity: SessionAuthorityIdentity) => void
}

type AuthorityRecord = SessionAuthorityIdentity & {
  key: string
  verifiedAtMs: number
  /** The earliest retry that may query this authority again. */
  nextReconciliationAtMs: number
}

type SessionAuthorityDependencies = {
  now?: () => number
  findActiveSessions?: (sessionIds: readonly number[]) => Promise<readonly SessionAuthorityIdentity[]>
  log?: Pick<Log, "warn">
  scheduleTimer?: (callback: () => void, delayMs: number) => ReturnType<typeof setTimeout>
  cancelTimer?: (timer: ReturnType<typeof setTimeout>) => void
}

const DEFAULT_RECONCILIATION_INTERVAL_MS = 15_000
const DEFAULT_MAXIMUM_AUTHORITY_AGE_MS = 30_000
const DEFAULT_BATCH_SIZE = 512
const MINIMUM_DURATION_MS = 1_000
const MAXIMUM_DURATION_MS = 5 * 60_000

const keyFor = ({ userId, sessionId }: SessionAuthorityIdentity): string => `${userId}:${sessionId}`

const parseDuration = (raw: string | undefined, fallback: number, minimum = MINIMUM_DURATION_MS): number => {
  if (!raw) return fallback
  const parsed = Number(raw)
  return Number.isSafeInteger(parsed) && parsed >= minimum && parsed <= MAXIMUM_DURATION_MS
    ? parsed
    : fallback
}

/** The hard expiry is always at least two timer opportunities away. */
export const sessionAuthorityConfigurationFromEnvironment = (
  environment: Readonly<Record<string, string | undefined>> = process.env,
): SessionAuthorityConfiguration => {
  const maximumAuthorityAgeMs = parseDuration(
    environment["SESSION_AUTHORITY_MAX_AGE_MS"],
    DEFAULT_MAXIMUM_AUTHORITY_AGE_MS,
    MINIMUM_DURATION_MS * 2,
  )
  const requestedIntervalMs = parseDuration(
    environment["SESSION_AUTHORITY_RECONCILIATION_INTERVAL_MS"],
    DEFAULT_RECONCILIATION_INTERVAL_MS,
  )
  return {
    reconciliationIntervalMs: Math.min(requestedIntervalMs, Math.max(MINIMUM_DURATION_MS, Math.floor(maximumAuthorityAgeMs / 2))),
    maximumAuthorityAgeMs,
    batchSize: DEFAULT_BATCH_SIZE,
    // This only protects the small init/event interleave. A new connection
    // still performs an authoritative session query before it can be admitted.
    invalidationRetentionMs: maximumAuthorityAgeMs,
  }
}

const findActiveSessionsFromDatabase = async (
  sessionIds: readonly number[],
): Promise<readonly SessionAuthorityIdentity[]> => {
  if (sessionIds.length === 0) return []
  const [{ db }, schema, orm] = await Promise.all([
    import("@in/server/db"),
    import("@in/server/db/schema"),
    import("drizzle-orm"),
  ])
  const rows = await db.select({ sessionId: schema.sessions.id, userId: schema.sessions.userId })
    .from(schema.sessions)
    .innerJoin(schema.users, orm.eq(schema.sessions.userId, schema.users.id))
    .where(orm.and(
      orm.inArray(schema.sessions.id, [...sessionIds]),
      orm.isNull(schema.sessions.revoked),
      orm.or(orm.isNull(schema.users.deleted), orm.eq(schema.users.deleted, false)),
    ))
  return rows
    .map(({ sessionId, userId }) => ({ sessionId, userId }))
}

/**
 * Holds only process-local authority established by a fresh session lookup.
 * It never authorizes a new connection; callers must authenticate first, then
 * synchronously call admit before registering a socket.
 */
export class SessionAuthorityReconciler {
  private readonly now: () => number
  private readonly findActiveSessions: (sessionIds: readonly number[]) => Promise<readonly SessionAuthorityIdentity[]>
  private readonly log: Pick<Log, "warn">
  private readonly scheduleTimer: (callback: () => void, delayMs: number) => ReturnType<typeof setTimeout>
  private readonly cancelTimer: (timer: ReturnType<typeof setTimeout>) => void
  private readonly authorities = new Map<string, AuthorityRecord>()
  private readonly invalidatedUntil = new Map<string, number>()
  private bindings: SessionAuthorityBindings | undefined
  private configuration: SessionAuthorityConfiguration = sessionAuthorityConfigurationFromEnvironment()
  private timer: ReturnType<typeof setTimeout> | undefined
  private running = false
  private reconciliationInFlight = false
  private reconciliationTask: Promise<void> | undefined
  /** Invalidates a previous async reconciliation when the lifecycle restarts. */
  private lifecycleGeneration = 0

  constructor(dependencies: SessionAuthorityDependencies = {}) {
    this.now = dependencies.now ?? (() => performance.now())
    this.findActiveSessions = dependencies.findActiveSessions ?? findActiveSessionsFromDatabase
    this.log = dependencies.log ?? new Log("auth.sessionAuthority")
    this.scheduleTimer = dependencies.scheduleTimer ?? setTimeout
    this.cancelTimer = dependencies.cancelTimer ?? clearTimeout
  }

  /** Returns false only when a revocation event won the auth-to-register race. */
  admit(identity: SessionAuthorityIdentity): boolean {
    const now = this.now()
    this.pruneInvalidations(now)
    const key = keyFor(identity)
    if (this.invalidatedUntil.has(key)) return false
    this.authorities.set(key, {
      ...identity,
      key,
      verifiedAtMs: now,
      nextReconciliationAtMs: now + this.configuration.reconciliationIntervalMs,
    })
    // `start()` and every reconciliation keep one timer no later than the
    // configured interval. An authority admitted after that timer is armed
    // cannot be due before it, so rescanning every tracked authority here
    // would only turn a connection burst into O(N²) timer work.
    return true
  }

  /**
   * Checks only the synchronous revoke fence for an already-admitted socket.
   * It deliberately does not refresh `verifiedAtMs`; revalidation remains
   * bounded even while that socket is busy.
   */
  allows(identity: SessionAuthorityIdentity): boolean {
    const now = this.now()
    this.pruneInvalidations(now)
    const key = keyFor(identity)
    const authority = this.authorities.get(key)
    return !this.invalidatedUntil.has(key) && authority !== undefined &&
      now - authority.verifiedAtMs < this.configuration.maximumAuthorityAgeMs
  }

  /** Call after the revocation transaction commits, before registering any new socket. */
  invalidate(identity: SessionAuthorityIdentity): void {
    const now = this.now()
    const key = keyFor(identity)
    this.authorities.delete(key)
    this.invalidatedUntil.set(key, now + this.configuration.invalidationRetentionMs)
    // Removing an authority may leave an earlier timer behind, which is a
    // harmless wake. Do not scan the remaining authority set per revocation.
  }

  /** Forget a disconnected local session without treating it as revoked. */
  forget(identity: SessionAuthorityIdentity): void {
    this.authorities.delete(keyFor(identity))
    // As with invalidation, a timer for a forgotten authority can only wake
    // early; the next reconciliation prunes it without delaying others.
  }

  start(bindings: SessionAuthorityBindings, configuration = sessionAuthorityConfigurationFromEnvironment()): void {
    this.bindings = bindings
    this.configuration = configuration
    if (this.running) {
      this.reschedule()
      return
    }
    this.running = true
    this.lifecycleGeneration += 1
    this.reschedule()
  }

  stop(): Promise<void> {
    this.lifecycleGeneration += 1
    this.running = false
    if (this.timer) this.cancelTimer(this.timer)
    this.timer = undefined
    this.bindings = undefined
    this.authorities.clear()
    this.invalidatedUntil.clear()
    // Invalidating results does not cancel the underlying database operation.
    // Retain its owner until it settles, including across a quick restart.
    return this.reconciliationTask ?? Promise.resolve()
  }

  /** Exposed for focused tests and a startup probe; normal operation uses the timer. */
  reconcileNow(): Promise<void> {
    if (this.reconciliationTask) {
      // A stalled query must not stall the independent hard-expiry timer.
      this.collectDueAuthorities()
      this.reschedule()
      return this.reconciliationTask
    }
    const task = this.reconcile().finally(() => {
      if (this.reconciliationTask === task) this.reconciliationTask = undefined
      this.reschedule()
    })
    this.reconciliationTask = task
    return task
  }

  private async reconcile(): Promise<void> {
    const due = this.collectDueAuthorities()
    if (due.length === 0 || this.reconciliationInFlight) {
      this.reschedule()
      return
    }
    const generation = this.lifecycleGeneration
    this.reconciliationInFlight = true
    // A query can stall indefinitely. Keep an independent timer armed for
    // each authority's hard expiry while it is in flight; the expiry callback
    // removes stale authorities without starting a competing query.
    this.reschedule()
    try {
      for (let offset = 0; offset < due.length; offset += this.configuration.batchSize) {
        if (generation !== this.lifecycleGeneration) return
        const batch = due
          .slice(offset, offset + this.configuration.batchSize)
          .filter((authority) => this.authorities.get(authority.key) === authority)
        if (batch.length === 0) continue

        // Freshness is measured when the authority query starts. A slow
        // response cannot add its own latency to a previously verified proof.
        const queryStartedAtMs = this.now()
        let active: Set<string>
        try {
          active = new Set((await this.findActiveSessions(batch.map(({ sessionId }) => sessionId)))
            .map((identity) => keyFor(identity)))
        } catch (error) {
          if (generation !== this.lifecycleGeneration) return
          this.log.warn("Session authority reconciliation failed", { checkedSessions: batch.length, error })
          const completedAtMs = this.now()
          for (const authority of batch) {
            if (this.authorities.get(authority.key) !== authority) continue
            if (completedAtMs - authority.verifiedAtMs >= this.configuration.maximumAuthorityAgeMs) {
              this.revokeAuthority(authority)
            } else {
              // Retrying at the hard deadline prevents an unavailable database
              // from spinning while preserving a bounded fail-closed window.
              authority.nextReconciliationAtMs = authority.verifiedAtMs + this.configuration.maximumAuthorityAgeMs
            }
          }
          continue
        }

        if (generation !== this.lifecycleGeneration) return
        const completedAtMs = this.now()
        for (const authority of batch) {
          // A revoke or reconnect can replace this record while the query is
          // in flight. Only the exact still-current record may be refreshed.
          if (this.authorities.get(authority.key) !== authority) continue
          if (completedAtMs - authority.verifiedAtMs >= this.configuration.maximumAuthorityAgeMs || !active.has(authority.key)) {
            this.revokeAuthority(authority)
            continue
          }
          authority.verifiedAtMs = queryStartedAtMs
          authority.nextReconciliationAtMs = queryStartedAtMs + this.configuration.reconciliationIntervalMs
        }
        // A slow batch can exhaust an unchecked authority in a later batch.
        this.collectDueAuthorities()
      }
    } catch (error) {
      if (generation === this.lifecycleGeneration) {
        this.log.warn("Session authority reconciliation failed", { checkedSessions: due.length, error })
      }
    } finally {
      this.reconciliationInFlight = false
      this.reschedule()
    }
  }

  get diagnostics(): { trackedSessions: number; invalidatedSessions: number; reconciliationInFlight: boolean } {
    this.pruneInvalidations(this.now())
    return {
      trackedSessions: this.authorities.size,
      invalidatedSessions: this.invalidatedUntil.size,
      reconciliationInFlight: this.reconciliationInFlight,
    }
  }

  private collectDueAuthorities(): AuthorityRecord[] {
    const now = this.now()
    this.pruneInvalidations(now)
    const connected = new Set((this.bindings?.connectedSessions() ?? []).map(keyFor))
    const due: AuthorityRecord[] = []
    for (const authority of this.authorities.values()) {
      if (!connected.has(authority.key)) {
        this.authorities.delete(authority.key)
        continue
      }
      if (now - authority.verifiedAtMs >= this.configuration.maximumAuthorityAgeMs) {
        this.revokeAuthority(authority)
      } else if (now >= authority.nextReconciliationAtMs) {
        due.push(authority)
      }
    }
    return due
  }

  private revokeAuthority(authority: AuthorityRecord): void {
    if (this.authorities.get(authority.key) !== authority) return
    this.authorities.delete(authority.key)
    this.bindings?.closeSession({ userId: authority.userId, sessionId: authority.sessionId })
  }

  private pruneInvalidations(now: number): void {
    for (const [key, expiresAt] of this.invalidatedUntil) {
      if (expiresAt <= now) this.invalidatedUntil.delete(key)
    }
  }

  /**
   * Schedule the earliest individual refresh/expiry rather than a global
   * cadence. A connection admitted just after another timer tick therefore
   * still reaches its own hard expiry on time if verification is unavailable.
   */
  private reschedule(): void {
    if (!this.running) return
    if (this.timer) this.cancelTimer(this.timer)
    const now = this.now()
    let nextAtMs = now + this.configuration.reconciliationIntervalMs
    for (const authority of this.authorities.values()) {
      const expiryAtMs = authority.verifiedAtMs + this.configuration.maximumAuthorityAgeMs
      const candidateAtMs = this.reconciliationInFlight && authority.nextReconciliationAtMs <= now
        ? expiryAtMs
        : Math.min(authority.nextReconciliationAtMs, expiryAtMs)
      nextAtMs = Math.min(nextAtMs, candidateAtMs)
    }
    const delayMs = Math.max(0, nextAtMs - now)
    this.timer = this.scheduleTimer(() => {
      this.timer = undefined
      void this.reconcileNow()
    }, delayMs)
    this.timer.unref?.()
  }
}

export const sessionAuthority = new SessionAuthorityReconciler()
