import {
  describe,
  expect,
  test,
} from "bun:test"

const {
  connectionPresenceForUser,
} = await import("./presenceView")

describe("connection presence view", () => {
  test("marks locally observed sessions incomplete while the broker is unavailable", async () => {
    const runtime = {
      directory: {
        list: async () => ({ status: "unavailable" as const }),
      },
      connections: {
        getUserConnectionSummary: () => ({
          totalConnections: 1,
          sessions: [{ sessionId: 9, count: 1 }],
        }),
      },
    }

    const presence = await connectionPresenceForUser(4, runtime)

    expect(presence.complete).toBe(false)
    expect(presence.totalConnections).toBe(1)
    expect(presence.activeSessionIds).toEqual(new Set([9]))
  })

  test("preserves incompleteness while registration reconstruction is pending", async () => {
    const runtime = {
      directory: {
        list: async () => ({
          status: "available" as const,
          complete: false,
          connections: [{
            bootId: "boot",
            connectionId: "connection",
            userId: 4,
            sessionId: 10,
            clientType: "macos",
            isBot: false,
            expiresAt: Date.now() + 1_000,
          }],
        }),
      },
      connections: {
        getUserConnectionSummary: () => ({
          totalConnections: 0,
          sessions: [],
        }),
      },
    }

    const presence = await connectionPresenceForUser(4, runtime)

    expect(presence.complete).toBe(false)
    expect(presence.activeSessionIds).toEqual(new Set([10]))
  })
})
