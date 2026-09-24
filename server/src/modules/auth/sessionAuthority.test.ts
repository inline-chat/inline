import { describe, expect, mock, test } from "bun:test"
import {
  SessionAuthorityReconciler,
  sessionAuthorityConfigurationFromEnvironment,
  type SessionAuthorityConfiguration,
  type SessionAuthorityIdentity,
} from "./sessionAuthority"

const configuration: SessionAuthorityConfiguration = {
  reconciliationIntervalMs: 10,
  maximumAuthorityAgeMs: 30,
  batchSize: 128,
  invalidationRetentionMs: 30,
}

const identity = (userId: number, sessionId: number): SessionAuthorityIdentity => ({ userId, sessionId })

describe("SessionAuthorityReconciler", () => {
  test("falls back to the safe authority age when configuration leaves no refresh window", () => {
    expect(sessionAuthorityConfigurationFromEnvironment({
      SESSION_AUTHORITY_MAX_AGE_MS: "1000",
      SESSION_AUTHORITY_RECONCILIATION_INTERVAL_MS: "1000",
    })).toMatchObject({
      maximumAuthorityAgeMs: 30_000,
      reconciliationIntervalMs: 1_000,
      invalidationRetentionMs: 30_000,
    })

    expect(sessionAuthorityConfigurationFromEnvironment({
      SESSION_AUTHORITY_MAX_AGE_MS: "2000",
      SESSION_AUTHORITY_RECONCILIATION_INTERVAL_MS: "1000",
    })).toMatchObject({
      maximumAuthorityAgeMs: 2_000,
      reconciliationIntervalMs: 1_000,
      invalidationRetentionMs: 2_000,
    })
  })

  test("revalidates unique connected session IDs in one batch", async () => {
    let now = 0
    const one = identity(10, 1)
    const two = identity(20, 2)
    const lookup = mock(async () => [one, two])
    const close = mock()
    const reconciler = new SessionAuthorityReconciler({ now: () => now, findActiveSessions: lookup })
    reconciler.start({ connectedSessions: () => [one, one, two], closeSession: close }, configuration)
    reconciler.admit(one)
    reconciler.admit(two)

    now = 10
    await reconciler.reconcileNow()

    expect(lookup).toHaveBeenCalledWith([1, 2])
    expect(close).not.toHaveBeenCalled()
    reconciler.stop()
  })

  test("fails closed at the monotonic maximum age when revalidation is unavailable", async () => {
    let now = 0
    const close = mock()
    const reconciler = new SessionAuthorityReconciler({
      now: () => now,
      findActiveSessions: async () => { throw new Error("database unavailable") },
      log: { warn() {} },
    })
    const target = identity(10, 1)
    reconciler.start({ connectedSessions: () => [target], closeSession: close }, configuration)
    reconciler.admit(target)

    now = 10
    await reconciler.reconcileNow()
    now = 30
    await reconciler.reconcileNow()

    expect(close).toHaveBeenCalledWith(target)
    expect(reconciler.diagnostics.trackedSessions).toBe(0)
    reconciler.stop()
  })

  test("does not revive authority when a revocation races an in-flight batch", async () => {
    let now = 0
    const query = Promise.withResolvers<readonly SessionAuthorityIdentity[]>()
    const close = mock()
    const reconciler = new SessionAuthorityReconciler({ now: () => now, findActiveSessions: () => query.promise })
    const target = identity(10, 1)
    reconciler.start({ connectedSessions: () => [target], closeSession: close }, configuration)
    reconciler.admit(target)

    now = 10
    const reconciling = reconciler.reconcileNow()
    await Promise.resolve()
    reconciler.invalidate(target)
    query.resolve([target])
    await reconciling

    expect(reconciler.diagnostics.trackedSessions).toBe(0)
    expect(close).not.toHaveBeenCalled()
    reconciler.stop()
  })

  test("fails closed when a verification query completes at the authority deadline", async () => {
    let now = 0
    const query = Promise.withResolvers<readonly SessionAuthorityIdentity[]>()
    const close = mock()
    const reconciler = new SessionAuthorityReconciler({ now: () => now, findActiveSessions: () => query.promise })
    const target = identity(10, 1)
    reconciler.start({ connectedSessions: () => [target], closeSession: close }, configuration)
    reconciler.admit(target)

    now = 10
    const reconciling = reconciler.reconcileNow()
    await Promise.resolve()
    now = 30
    query.resolve([target])
    await reconciling

    expect(close).toHaveBeenCalledWith(target)
    expect(reconciler.diagnostics.trackedSessions).toBe(0)
    reconciler.stop()
  })

  test("keeps the hard-expiry timer armed while a verification query is stalled", async () => {
    let now = 0
    const query = Promise.withResolvers<readonly SessionAuthorityIdentity[]>()
    const close = mock()
    let fireTimer: (() => void) | undefined
    const reconciler = new SessionAuthorityReconciler({
      now: () => now,
      findActiveSessions: () => query.promise,
      scheduleTimer: (callback) => {
        fireTimer = callback
        return { unref() {} } as unknown as ReturnType<typeof setTimeout>
      },
      cancelTimer: () => {},
    })
    const target = identity(10, 1)
    reconciler.start({ connectedSessions: () => [target], closeSession: close }, configuration)
    reconciler.admit(target)

    now = 10
    const reconciling = reconciler.reconcileNow()
    await Promise.resolve()
    now = 30
    if (!fireTimer) throw new Error("Expected hard-expiry timer")
    fireTimer()
    await Promise.resolve()

    expect(close).toHaveBeenCalledWith(target)
    expect(reconciler.diagnostics.trackedSessions).toBe(0)
    query.resolve([target])
    await reconciling
    reconciler.stop()
  })

  test("uses the verification query start rather than response completion as fresh authority", async () => {
    let now = 0
    const query = Promise.withResolvers<readonly SessionAuthorityIdentity[]>()
    const close = mock()
    const reconciler = new SessionAuthorityReconciler({ now: () => now, findActiveSessions: () => query.promise })
    const target = identity(10, 1)
    reconciler.start({ connectedSessions: () => [target], closeSession: close }, configuration)
    reconciler.admit(target)

    now = 10
    const reconciling = reconciler.reconcileNow()
    await Promise.resolve()
    now = 29
    query.resolve([target])
    await reconciling

    now = 40
    await reconciler.reconcileNow()
    expect(close).toHaveBeenCalledWith(target)
    reconciler.stop()
  })

  test("does not let an in-flight prior lifecycle alter a restarted reconciler", async () => {
    let now = 0
    const oldQuery = Promise.withResolvers<readonly SessionAuthorityIdentity[]>()
    let queryCount = 0
    const lookup = mock(() => {
      queryCount += 1
      return queryCount === 1 ? oldQuery.promise : Promise.resolve([identity(10, 1)])
    })
    const close = mock()
    const reconciler = new SessionAuthorityReconciler({ now: () => now, findActiveSessions: lookup })
    const target = identity(10, 1)
    const bindings = { connectedSessions: () => [target], closeSession: close }
    reconciler.start(bindings, configuration)
    reconciler.admit(target)

    now = 10
    const oldReconciliation = reconciler.reconcileNow()
    await Promise.resolve()
    let stopped = false
    const stopping = reconciler.stop().then(() => { stopped = true })
    reconciler.start(bindings, configuration)
    reconciler.admit(target)

    now = 20
    const whileOldQueryRuns = reconciler.reconcileNow()
    await Promise.resolve()
    expect(stopped).toBe(false)
    expect(lookup).toHaveBeenCalledTimes(1)
    oldQuery.resolve([])
    await Promise.all([oldReconciliation, whileOldQueryRuns, stopping])
    expect(stopped).toBe(true)
    await reconciler.reconcileNow()

    expect(lookup).toHaveBeenCalledTimes(2)
    expect(close).not.toHaveBeenCalled()
    expect(reconciler.diagnostics.trackedSessions).toBe(1)
    reconciler.stop()
  })

  test("rejects registration when a revocation arrives after the initial auth query", () => {
    let now = 0
    const reconciler = new SessionAuthorityReconciler({ now: () => now })
    const target = identity(10, 1)
    reconciler.start({ connectedSessions: () => [], closeSession() {} }, configuration)

    reconciler.invalidate(target)
    expect(reconciler.admit(target)).toBe(false)

    now = 31
    expect(reconciler.admit(target)).toBe(true)
    reconciler.stop()
  })

  test("does not permit an already-registered socket after its authority proof expires", () => {
    let now = 0
    const reconciler = new SessionAuthorityReconciler({ now: () => now })
    const target = identity(10, 1)
    reconciler.start({ connectedSessions: () => [target], closeSession() {} }, configuration)
    expect(reconciler.admit(target)).toBeTrue()

    now = 30
    expect(reconciler.allows(target)).toBeFalse()
    reconciler.stop()
  })
})
