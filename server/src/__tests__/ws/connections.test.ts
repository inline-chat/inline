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

describe("ConnectionManager", () => {
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
      expect(connectionManager.closeUserConnectionsForDurableRepair(4, "no_replayable_record", reconnectEpoch)).toBe(0)
      expect(reconnect.close).not.toHaveBeenCalled()
      connectionManager.removeConnection(reconnectId)
    } finally {
      connectionManager.removeConnection(firstId)
      readMemberships.mockRestore()
    }
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
