import { describe, expect, it, mock, spyOn } from "bun:test"

const handleConnectionOpen = mock().mockResolvedValue(undefined)
const handleConnectionClose = mock().mockResolvedValue(undefined)

// Avoid importing the real PresenceManager in tests (it starts long-lived intervals).
mock.module("@in/server/ws/presence", () => ({
  presenceManager: {
    handleConnectionOpen,
    handleConnectionClose,
  },
}))

type MembershipManager = typeof import("@in/server/ws/connections").connectionManager

async function withMembershipConnection(
  userId: number,
  run: (manager: MembershipManager, connectionId: string) => Promise<void>,
): Promise<void> {
  const { ConnVersion, connectionManager } = await import("@in/server/ws/connections")
  const reader = connectionManager as unknown as { getUserSpaceIds(userId: number): Promise<number[]> }
  const memberships = spyOn(reader, "getUserSpaceIds").mockResolvedValue([])
  const connectionId = connectionManager.addConnection(
    { id: `membership-race-${userId}`, close: mock(), subscribe: mock() } as unknown as Parameters<MembershipManager["addConnection"]>[0],
    ConnVersion.REALTIME_V1,
  )
  connectionManager.authenticateConnection(connectionId, userId, userId + 10_000)
  try {
    await connectionManager.waitForBackgroundWork()
    await run(connectionManager, connectionId)
  } finally {
    connectionManager.removeConnection(connectionId)
    await connectionManager.waitForBackgroundWork()
    memberships.mockRestore()
  }
}

describe("ConnectionManager", () => {
  it("retains one successor for a burst of newer membership invalidations and joins it", async () => {
    await withMembershipConnection(171, async (manager) => {
      const oldStarted = Promise.withResolvers<void>()
      const oldRead = Promise.withResolvers<boolean>()
      const newStarted = Promise.withResolvers<void>()
      const newRead = Promise.withResolvers<boolean>()
      let newerReads = 0
      manager.activateSpaceMembership(171, 8)
      try {
        const first = manager.refreshSpaceMembership(171, 8, () => {
          oldStarted.resolve()
          return oldRead.promise
        })
        await oldStarted.promise
        const loadNew = () => {
          newerReads += 1
          newStarted.resolve()
          return newRead.promise
        }
        for (let i = 0; i < 5_000; i++) {
          expect(manager.refreshSpaceMembership(171, 8, loadNew)).toBe(first)
        }
        let completed = false
        const drained = manager.waitForBackgroundWork().then(() => { completed = true })
        oldRead.resolve(false)
        await newStarted.promise
        expect(newerReads).toBe(1)
        expect(completed).toBe(false)
        // Do not briefly apply the obsolete removal while the grant is read.
        expect(manager.getSpaceUserIds(8)).toContain(171)
        newRead.resolve(true)
        await Promise.all([first, drained])
        expect(manager.getSpaceUserIds(8)).toContain(171)
      } finally {
        oldRead.resolve(false)
        newRead.resolve(true)
      }
    })
  })

  it("does not cancel a membership result when another space completes first", async () => {
    await withMembershipConnection(172, async (manager) => {
      const a = Promise.withResolvers<boolean>()
      const b = Promise.withResolvers<boolean>()
      const startedA = Promise.withResolvers<void>()
      const startedB = Promise.withResolvers<void>()
      try {
        const first = manager.refreshSpaceMembership(172, 8, () => { startedA.resolve(); return a.promise })
        const second = manager.refreshSpaceMembership(172, 9, () => { startedB.resolve(); return b.promise })
        await Promise.all([startedA.promise, startedB.promise])
        a.resolve(true)
        await first
        b.resolve(true)
        await second
        expect(manager.getSpaceUserIds(8)).toContain(172)
        expect(manager.getSpaceUserIds(9)).toContain(172)
      } finally {
        a.resolve(true)
        b.resolve(true)
      }
    })
  })

  it("fences a stale result for a locally projected space without cancelling another space", async () => {
    await withMembershipConnection(173, async (manager) => {
      const gate = Promise.withResolvers<boolean>()
      let started = 0
      const bothStarted = Promise.withResolvers<void>()
      const load = () => { if (++started === 2) bothStarted.resolve(); return gate.promise }
      manager.activateSpaceMembership(173, 9)
      try {
        const first = manager.refreshSpaceMembership(173, 8, load)
        const second = manager.refreshSpaceMembership(173, 9, load)
        await bothStarted.promise
        manager.activateSpaceMembership(173, 8)
        gate.resolve(false)
        await Promise.all([first, second])
        expect(manager.getSpaceUserIds(8)).toContain(173)
        expect(manager.getSpaceUserIds(9)).not.toContain(173)
      } finally { gate.resolve(false) }
    })
  })

  it("runs a queued successor even when the obsolete membership read fails", async () => {
    await withMembershipConnection(174, async (manager) => {
      const started = Promise.withResolvers<void>()
      const gate = Promise.withResolvers<boolean>()
      try {
        const first = manager.refreshSpaceMembership(174, 8, () => { started.resolve(); return gate.promise })
        await started.promise
        const successor = manager.refreshSpaceMembership(174, 8, async () => true)
        gate.reject(new Error("Obsolete read failed"))
        await Promise.all([first, successor])
        expect(manager.getSpaceUserIds(8)).toContain(174)
      } finally { gate.resolve(false) }
    })
  })

  it("admits another refresh between the last read settling and its caller completing", async () => {
    await withMembershipConnection(175, async (manager) => {
      const started = Promise.withResolvers<void>()
      const gate = Promise.withResolvers<boolean>()
      let newerReads = 0
      try {
        const first = manager.refreshSpaceMembership(175, 8, () => { started.resolve(); return gate.promise })
        await started.promise
        gate.resolve(false)
        // Runs after the owner's await resumes, before its outer promise has
        // propagated completion. Deferred map cleanup used to lose this call.
        await gate.promise
        const second = manager.refreshSpaceMembership(175, 8, async () => { newerReads += 1; return true })
        await Promise.all([first, second])
        expect(newerReads).toBe(1)
        expect(manager.getSpaceUserIds(8)).toContain(175)
      } finally { gate.resolve(false) }
    })
  })

  it("does not let an old targeted read overwrite a reconnected user's membership", async () => {
    await withMembershipConnection(176, async (manager, oldConnectionId) => {
      const { ConnVersion } = await import("@in/server/ws/connections")
      const started = Promise.withResolvers<void>()
      const gate = Promise.withResolvers<boolean>()
      let newConnectionId: string | undefined
      try {
        const first = manager.refreshSpaceMembership(176, 8, () => { started.resolve(); return gate.promise })
        await started.promise
        manager.removeConnection(oldConnectionId)
        newConnectionId = manager.addConnection(
          { id: "membership-race-176-new", close: mock(), subscribe: mock() } as unknown as Parameters<MembershipManager["addConnection"]>[0],
          ConnVersion.REALTIME_V1,
        )
        manager.authenticateConnection(newConnectionId, 176, 10_176)
        const successor = manager.refreshSpaceMembership(176, 8, async () => true)
        gate.resolve(false)
        await Promise.all([first, successor])
        expect(manager.getSpaceUserIds(8)).toContain(176)
      } finally {
        gate.resolve(false)
        if (newConnectionId) manager.removeConnection(newConnectionId)
      }
    })
  })

  it("does not let a disconnected lifetime's pending membership read repopulate a reconnect", async () => {
    const { ConnVersion, connectionManager } = await import("@in/server/ws/connections")
    const membershipReader = connectionManager as unknown as {
      getUserSpaceIds(userId: number): Promise<number[]>
    }
    let resolveOldRead!: (spaceIds: number[]) => void
    const oldRead = new Promise<number[]>((resolve) => { resolveOldRead = resolve })
    const read = spyOn(membershipReader, "getUserSpaceIds")
      .mockImplementationOnce(() => oldRead)
      .mockResolvedValueOnce([20])
    const oldId = connectionManager.addConnection(
      { id: "membership-old", close: mock(), subscribe: mock() } as unknown as Parameters<typeof connectionManager.addConnection>[0],
      ConnVersion.REALTIME_V1,
    )
    connectionManager.authenticateConnection(oldId, 101, 1001)
    connectionManager.removeConnection(oldId)
    const newId = connectionManager.addConnection(
      { id: "membership-new", close: mock(), subscribe: mock() } as unknown as Parameters<typeof connectionManager.addConnection>[0],
      ConnVersion.REALTIME_V1,
    )
    connectionManager.authenticateConnection(newId, 101, 1001)
    try {
      let drained = false
      const drain = connectionManager.waitForBackgroundWork().then(() => { drained = true })
      await Promise.resolve()
      expect(drained).toBe(false)
      resolveOldRead([10])
      await drain
      expect(connectionManager.getSpaceUserIds(10)).not.toContain(101)
      expect(connectionManager.getSpaceUserIds(20)).toContain(101)
    } finally {
      connectionManager.removeConnection(newId)
      read.mockRestore()
    }
    expect(connectionManager.getSpaceUserIds(20)).not.toContain(101)
  })

  it("refetches an in-flight membership snapshot after a committed membership projection", async () => {
    const { ConnVersion, connectionManager } = await import("@in/server/ws/connections")
    const membershipReader = connectionManager as unknown as {
      getUserSpaceIds(userId: number): Promise<number[]>
    }
    let resolveOldRead!: (spaceIds: number[]) => void
    const oldRead = new Promise<number[]>((resolve) => { resolveOldRead = resolve })
    const read = spyOn(membershipReader, "getUserSpaceIds")
      .mockImplementationOnce(() => oldRead)
      .mockResolvedValueOnce([30])
    const connectionId = connectionManager.addConnection(
      { id: "membership-revision", close: mock(), subscribe: mock() } as unknown as Parameters<typeof connectionManager.addConnection>[0],
      ConnVersion.REALTIME_V1,
    )
    connectionManager.authenticateConnection(connectionId, 102, 1002)
    try {
      connectionManager.activateSpaceMembership(102, 30)
      resolveOldRead([10])
      await oldRead
      await Promise.resolve()
      await Promise.resolve()
      expect(read).toHaveBeenCalledTimes(2)
      expect(connectionManager.getSpaceUserIds(10)).not.toContain(102)
      expect(connectionManager.getSpaceUserIds(30)).toContain(102)
    } finally {
      connectionManager.removeConnection(connectionId)
      read.mockRestore()
    }
  })

  it("coalesces concurrent V3 client-type hydration and drains its database read", async () => {
    const { ConnVersion, connectionManager } = await import("@in/server/ws/connections")
    const membershipReader = connectionManager as unknown as {
      getUserSpaceIds(userId: number): Promise<number[]>
    }
    const memberships = spyOn(membershipReader, "getUserSpaceIds").mockResolvedValue([])
    const firstId = connectionManager.addConnection(
      { id: "client-type-first", close: mock(), subscribe: mock() } as unknown as Parameters<typeof connectionManager.addConnection>[0],
      ConnVersion.REALTIME_V3,
    )
    const secondId = connectionManager.addConnection(
      { id: "client-type-second", close: mock(), subscribe: mock() } as unknown as Parameters<typeof connectionManager.addConnection>[0],
      ConnVersion.REALTIME_V3,
    )
    connectionManager.authenticateConnection(firstId, 103, 1003)
    connectionManager.authenticateConnection(secondId, 103, 1003)

    const lookupStarted = Promise.withResolvers<void>()
    const releaseLookup = Promise.withResolvers<void>()
    let lookups = 0
    const load = async () => {
      lookups += 1
      lookupStarted.resolve()
      await releaseLookup.promise
      return "macos"
    }

    try {
      connectionManager.hydrateAuthenticatedClientType(103, 1003, load)
      connectionManager.hydrateAuthenticatedClientType(103, 1003, load)
      await lookupStarted.promise
      expect(lookups).toBe(1)

      let drained = false
      const drain = connectionManager.waitForBackgroundWork().then(() => { drained = true })
      await Promise.resolve()
      expect(drained).toBe(false)

      releaseLookup.resolve()
      await drain
      expect(connectionManager.getConnection(firstId)?.clientType).toBe("macos")
      expect(connectionManager.getConnection(secondId)?.clientType).toBe("macos")
      expect(connectionManager.getAuthenticatedSessionIdentities()).toEqual([{ userId: 103, sessionId: 1003 }])

      connectionManager.removeConnection(firstId)
      expect(connectionManager.getAuthenticatedSessionIdentities()).toEqual([{ userId: 103, sessionId: 1003 }])
      connectionManager.removeConnection(secondId)
      expect(connectionManager.getAuthenticatedSessionIdentities()).toEqual([])
    } finally {
      releaseLookup.resolve()
      connectionManager.removeConnection(firstId)
      connectionManager.removeConnection(secondId)
      memberships.mockRestore()
    }
  })

  it("hydrates one V3 session without iterating 1,000 unrelated live connections", async () => {
    const { connectedUserRepair } = await import("@in/server/modules/internalMessaging/repair")
    const observe = spyOn(connectedUserRepair, "observeConnection").mockImplementation(() => {})
    const { ConnVersion, connectionManager } = await import("@in/server/ws/connections")
    const membershipReader = connectionManager as unknown as {
      getUserSpaceIds(userId: number): Promise<number[]>
    }
    const memberships = spyOn(membershipReader, "getUserSpaceIds").mockResolvedValue([])
    const connectionIds: string[] = []
    const connections = (connectionManager as unknown as {
      connections: Map<string, unknown>
    }).connections
    const originalValues = connections.values
    let visits = 0

    try {
      for (let index = 0; index < 1_000; index += 1) {
        const userId = 11_000 + index
        const sessionId = 21_000 + index
        const connectionId = connectionManager.addConnection(
          { id: `client-type-index-${index}`, close: mock(), subscribe: mock() } as unknown as Parameters<typeof connectionManager.addConnection>[0],
          ConnVersion.REALTIME_V3,
        )
        connectionManager.authenticateConnection(connectionId, userId, sessionId)
        connectionIds.push(connectionId)
      }
      await connectionManager.waitForBackgroundWork()

      Object.defineProperty(connections, "values", {
        configurable: true,
        value: function values(this: Map<string, unknown>) {
          const iterator = originalValues.call(this)
          return {
            next() {
              const next = iterator.next()
              if (!next.done) visits += 1
              return next
            },
            [Symbol.iterator]() { return this },
          }
        },
      })

      connectionManager.hydrateAuthenticatedClientType(11_000, 21_000, async () => "ios")
      await connectionManager.waitForBackgroundWork()

      expect(visits).toBe(0)
      expect(connectionManager.getConnection(connectionIds[0]!)?.clientType).toBe("ios")
    } finally {
      delete (connections as { values?: unknown }).values
      for (const connectionId of connectionIds) connectionManager.removeConnection(connectionId)
      memberships.mockRestore()
      observe.mockRestore()
    }
  })

  it("coalesces and joins an access-change membership refresh before teardown", async () => {
    const { ConnVersion, connectionManager } = await import("@in/server/ws/connections")
    const membershipReader = connectionManager as unknown as {
      getUserSpaceIds(userId: number): Promise<number[]>
    }
    const memberships = spyOn(membershipReader, "getUserSpaceIds").mockResolvedValue([])
    const connectionId = connectionManager.addConnection(
      { id: "access-change-refresh", close: mock(), subscribe: mock() } as unknown as Parameters<typeof connectionManager.addConnection>[0],
      ConnVersion.REALTIME_V1,
    )
    connectionManager.authenticateConnection(connectionId, 104, 1004)
    const refreshStarted = Promise.withResolvers<void>()
    const releaseRefresh = Promise.withResolvers<void>()
    let reads = 0
    const load = async () => {
      reads += 1
      refreshStarted.resolve()
      await releaseRefresh.promise
      return true
    }

    try {
      const first = connectionManager.refreshSpaceMembership(104, 40, load)
      const second = connectionManager.refreshSpaceMembership(104, 40, load)
      expect(second).toBe(first)
      await refreshStarted.promise
      expect(reads).toBe(1)

      let drained = false
      const drain = connectionManager.waitForBackgroundWork().then(() => { drained = true })
      await Promise.resolve()
      expect(drained).toBe(false)

      connectionManager.removeConnection(connectionId)
      releaseRefresh.resolve()
      await Promise.all([first, second, drain])
      expect(connectionManager.getSpaceUserIds(40)).not.toContain(104)
    } finally {
      releaseRefresh.resolve()
      connectionManager.removeConnection(connectionId)
      memberships.mockRestore()
    }
  })

  it("only marks a session inactive after the last connection for that session closes", async () => {
    const { ConnVersion, connectionManager } = await import("@in/server/ws/connections")

    const ws1 = { id: "c1", close: mock(), subscribe: mock() } as any
    const ws2 = { id: "c2", close: mock(), subscribe: mock() } as any

    const id1 = connectionManager.addConnection(ws1, ConnVersion.REALTIME_V1)
    const id2 = connectionManager.addConnection(ws2, ConnVersion.REALTIME_V1)

    const conn1 = connectionManager.getConnection(id1)
    const conn2 = connectionManager.getConnection(id2)
    if (!conn1 || !conn2) {
      throw new Error("Failed to create test connections")
    }
    conn1.userId = 1
    conn1.sessionId = 10
    conn2.userId = 1
    conn2.sessionId = 10

    handleConnectionClose.mockClear()

    connectionManager.closeConnection(id1)
    expect(handleConnectionClose).toHaveBeenCalledTimes(0)

    connectionManager.closeConnection(id2)
    expect(handleConnectionClose).toHaveBeenCalledTimes(1)
    expect(handleConnectionClose).toHaveBeenCalledWith({ userId: 1, sessionId: 10 }, undefined, false)
  })

  it("marks an explicitly revoked session with the terminal authentication close code", async () => {
    const {
      ConnVersion,
      REALTIME_CLOSE_SESSION_REVOKED,
      REALTIME_CLOSE_SESSION_REVOKED_REASON,
      connectionManager,
    } = await import("@in/server/ws/connections")
    const ws = { id: "revoked", close: mock(), subscribe: mock() } as any
    const id = connectionManager.addConnection(ws, ConnVersion.REALTIME_V3)
    connectionManager.authenticateConnection(id, 2, 20)

    connectionManager.closeConnectionForSession(2, 20, { authenticationInvalidated: true })

    expect(ws.close).toHaveBeenCalledWith(
      REALTIME_CLOSE_SESSION_REVOKED,
      REALTIME_CLOSE_SESSION_REVOKED_REASON,
    )
    expect(connectionManager.getConnection(id)).toBeUndefined()
  })

  it("uses a guarded, non-authentication close for the durable-repair reconnect fallback", async () => {
    const {
      ConnVersion,
      REALTIME_CLOSE_DURABLE_REPAIR,
      REALTIME_CLOSE_DURABLE_REPAIR_REASON,
      connectionManager,
    } = await import("@in/server/ws/connections")
    const membershipReader = connectionManager as unknown as {
      getUserSpaceIds(userId: number): Promise<number[]>
    }
    const readMemberships = spyOn(membershipReader, "getUserSpaceIds").mockResolvedValue([])
    const first = { id: "durable-repair-first", close: mock(), subscribe: mock() } as any
    const firstId = connectionManager.addConnection(first, ConnVersion.REALTIME_V1)
    connectionManager.authenticateConnection(firstId, 4, 40)
    try {
      const firstEpoch = connectionManager.getUserConnectionEpoch(4)
      expect(connectionManager.closeUserConnectionsForDurableRepair(4, "transport_not_accepted", firstEpoch + 1)).toBe(0)
      expect(first.close).not.toHaveBeenCalled()

      expect(connectionManager.closeUserConnectionsForDurableRepair(4, "transport_not_accepted", firstEpoch)).toBe(1)
      expect(first.close).toHaveBeenCalledWith(
        REALTIME_CLOSE_DURABLE_REPAIR,
        REALTIME_CLOSE_DURABLE_REPAIR_REASON,
      )

      const reconnect = { id: "durable-repair-reconnect", close: mock(), subscribe: mock() } as any
      const reconnectId = connectionManager.addConnection(reconnect, ConnVersion.REALTIME_V1)
      connectionManager.authenticateConnection(reconnectId, 4, 40)
      const reconnectEpoch = connectionManager.getUserConnectionEpoch(4)
      expect(connectionManager.closeUserConnectionsForDurableRepair(4, "no_replayable_record", reconnectEpoch, 9)).toBe(0)
      expect(reconnect.close).not.toHaveBeenCalled()
      connectionManager.removeConnection(reconnectId)
    } finally {
      connectionManager.removeConnection(firstId)
      readMemberships.mockRestore()
    }
  })

  it("retains unreplayable frontiers across reconnects without suppressing newer or transport-refused repair", async () => {
    await withMembershipConnection(180, async (manager, initialId) => {
      let now = performance.now()
      const clock = spyOn(performance, "now").mockImplementation(() => now)
      const { ConnVersion } = await import("@in/server/ws/connections")
      let currentId = initialId
      const reconnect = async () => {
        const ws = { id: "frontier-reconnect", close: mock(), subscribe: mock() }
        currentId = manager.addConnection(ws as unknown as Parameters<MembershipManager["addConnection"]>[0], ConnVersion.REALTIME_V1)
        manager.authenticateConnection(currentId, 180, 10_180)
        await manager.waitForBackgroundWork()
        return ws
      }
      const close = (reason: "no_replayable_record" | "transport_not_accepted", frontier: number) =>
        manager.closeUserConnectionsForDurableRepair(180, reason, manager.getUserConnectionEpoch(180), frontier)
      try {
        const firstEpoch = manager.getUserConnectionEpoch(180)
        expect(close("no_replayable_record", 9)).toBe(1)
        expect(manager.getConnection(initialId)).toBeUndefined()
        // Disconnected observations may be pruned before any replacement exists.
        expect(close("no_replayable_record", 10)).toBe(0)
        for (let wave = 0; wave < 4; wave++) {
          now += 31_000
          const ws = await reconnect()
          expect(manager.closeUserConnectionsForDurableRepair(180, "no_replayable_record", firstEpoch, 10)).toBe(0)
          expect(close("no_replayable_record", 9)).toBe("frontier_already_reconnected")
          expect(ws.close).not.toHaveBeenCalled()
          manager.removeConnection(currentId)
        }
        await reconnect()
        expect(close("no_replayable_record", 10)).toBe(1)
        const ws = await reconnect()
        expect(close("no_replayable_record", 11)).toBe(0)
        expect(close("transport_not_accepted", 10)).toBe(0)
        expect(ws.close).not.toHaveBeenCalled()
        now += 31_000
        expect(close("transport_not_accepted", 10)).toBe(1)
        await reconnect()
        now += 31_000
        expect(close("no_replayable_record", 10)).toBe("frontier_already_reconnected")
        expect(close("no_replayable_record", 11)).toBe(1)
      } finally {
        manager.removeConnection(currentId)
        clock.mockRestore()
      }
    })
  })

  it("protects every cooldown through capacity pressure, then permits expired frontier eviction", async () => {
    const { ConnVersion, connectionManager } = await import("@in/server/ws/connections")
    const manager = new (connectionManager.constructor as new () => MembershipManager)()
    const reader = manager as unknown as { getUserSpaceIds(userId: number): Promise<number[]> }
    const memberships = spyOn(reader, "getUserSpaceIds").mockResolvedValue([])
    const guards = manager as unknown as {
      durableRepairCloseGuards: Map<number, { closedAt: number; closedThrough?: number }>
    }
    const startedAt = performance.now()
    let now = startedAt
    const clock = spyOn(performance, "now").mockImplementation(() => now)
    const actualCloses: { userId: number; at: number }[] = []
    const connect = (userId: number) => {
      const ws = {
        id: `guard-capacity-${userId}`,
        close: mock(() => { actualCloses.push({ userId, at: now }) }), subscribe: mock(),
      }
      const id = manager.addConnection(ws as unknown as Parameters<MembershipManager["addConnection"]>[0], ConnVersion.REALTIME_V1)
      manager.authenticateConnection(id, userId, userId)
      return id
    }
    const close = (userId: number) => manager.closeUserConnectionsForDurableRepair(
      userId, "no_replayable_record", manager.getUserConnectionEpoch(userId), 9,
    )
    const wave = () => {
      for (let userId = 70_000; userId <= 74_096; userId++) {
        if (manager.getUserConnections(userId).length === 0) connect(userId)
        close(userId)
      }
    }
    try {
      wave()
      expect(actualCloses).toHaveLength(4096)
      expect(guards.durableRepairCloseGuards.size).toBe(4096)
      for (const elapsed of [1_000, 2_000]) {
        now = startedAt + elapsed
        wave()
        expect(actualCloses).toHaveLength(4096)
        expect(guards.durableRepairCloseGuards.size).toBe(4096)
      }
      expect(manager.getUserConnections(74_096)).toHaveLength(1)

      now = startedAt + 30_000
      expect(close(74_096)).toBe(1)
      // Capacity eviction can forget an old frontier, but never before that
      // account's last actual close has completed its minimum interval.
      expect(close(70_000)).toBe(1)
      expect(actualCloses.filter(value => value.userId === 70_000)).toEqual([
        { userId: 70_000, at: startedAt }, { userId: 70_000, at: startedAt + 30_000 },
      ])
      expect(actualCloses).toHaveLength(4098)
      expect(guards.durableRepairCloseGuards.size).toBe(4096)
      connect(70_000)
      expect(close(70_000)).toBe("frontier_already_reconnected")
      expect(actualCloses).toHaveLength(4098)
    } finally {
      await manager.shutdown()
      clock.mockRestore()
      memberships.mockRestore()
    }
  })

  it("keeps scheduler reconnect recovery complete across pruning and retries a newer cooldown-limited frontier", async () => {
    await withMembershipConnection(181, async (manager) => {
      const { ConnectedUserRepair } = await import("@in/server/modules/internalMessaging/repair")
      const { ConnVersion } = await import("@in/server/ws/connections")
      let now = performance.now()
      let frontier = 9
      const clock = spyOn(performance, "now").mockImplementation(() => now)
      const closed: number[] = []
      const repair = new ConnectedUserRepair({
        discovery: {
          captureWatermark: async () => new Date(1_700_000_000_000),
          prepare: async () => new Map(),
          discover: async () => ({ date: 1_700_000_000n, seq: frontier }),
        },
        connectedUserIds: () => manager.getAuthenticatedUserIds().filter(id => id === 181),
        hasConnections: id => manager.getUserConnections(id).length > 0,
        getConnectionEpoch: id => manager.getUserConnectionEpoch(id),
        emitUserHint: async () => 1,
        replayCurrentUserUpdate: async () => "filtered_record",
        closeForUnrecoverableFrontier: (id, reason, epoch, seq) => {
          const result = manager.closeUserConnectionsForDurableRepair(id, reason, epoch, seq)
          if (typeof result === "number" && result > 0) closed.push(seq!)
          return result
        },
        deliverTargetedBucketHint: async () => {},
      })
      const sweep = async () => { repair.observeConnectedUsers(); await repair.waitForIdle() }
      const reconnect = async () => {
        const id = manager.addConnection({ id: "scheduler-reconnect", close: mock(), subscribe: mock() } as unknown as
          Parameters<MembershipManager["addConnection"]>[0], ConnVersion.REALTIME_V1)
        manager.authenticateConnection(id, 181, 10_181)
        await manager.waitForBackgroundWork()
        repair.observeConnection(181)
        await repair.waitForIdle()
      }
      try {
        await repair.start()
        await sweep()
        expect(closed).toEqual([9])
        await sweep() // prune every observation for the disconnected account
        for (let wave = 0; wave < 3; wave++) {
          now += 31_000
          await reconnect()
          await sweep()
          expect(closed).toEqual([9])
          for (const connection of manager.getUserConnections(181)) manager.removeConnection(connection.connectionId)
          expect(manager.getUserConnections(181)).toHaveLength(0)
          await sweep()
        }
        await reconnect()
        frontier = 10
        await sweep()
        expect(closed).toEqual([9, 10])
        await reconnect()
        frontier = 11
        await sweep()
        expect(closed).toEqual([9, 10])
        now += 31_000
        await sweep()
        expect(closed).toEqual([9, 10, 11])
      } finally {
        await repair.stop()
        for (const connection of manager.getUserConnections(181)) manager.removeConnection(connection.connectionId)
        clock.mockRestore()
      }
    })
  })

  it("preserves the logout caller until its terminal protocol result is written", async () => {
    const { ConnVersion, connectionManager } = await import("@in/server/ws/connections")
    const caller = { id: "logout-caller", close: mock(), subscribe: mock() } as any
    const sibling = { id: "logout-sibling", close: mock(), subscribe: mock() } as any
    const callerId = connectionManager.addConnection(caller, ConnVersion.REALTIME_V3)
    const siblingId = connectionManager.addConnection(sibling, ConnVersion.REALTIME_V3)
    connectionManager.authenticateConnection(callerId, 3, 30)
    connectionManager.authenticateConnection(siblingId, 3, 30)

    connectionManager.closeConnectionForSession(
      3,
      30,
      { authenticationInvalidated: true },
      callerId,
    )

    expect(caller.close).not.toHaveBeenCalled()
    expect(connectionManager.getConnection(callerId)).toBeDefined()
    expect(sibling.close).toHaveBeenCalled()
    expect(connectionManager.getConnection(siblingId)).toBeUndefined()

    connectionManager.closeConnection(callerId)
  })
})
