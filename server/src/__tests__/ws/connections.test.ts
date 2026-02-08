import { describe, expect, it, mock } from "bun:test"

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
})
