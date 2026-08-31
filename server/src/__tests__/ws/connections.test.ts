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
      resolveOldRead([10])
      await oldRead
      await Promise.resolve()
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
    expect(handleConnectionClose).toHaveBeenCalledWith({ userId: 1, sessionId: 10 })
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
