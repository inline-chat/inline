import { describe, expect, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { handleConnectionInit } from "@in/server/realtime/handlers/_connectionInit"
import { db } from "@in/server/db"
import { sessions } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { ConnVersion, connectionManager } from "@in/server/ws/connections"

setupTestLifecycle()

describe("handleConnectionInit", () => {
  test("falls back to build number and stores valid os version", async () => {
    const user = await testUtils.createUser("connection-init@test.com")
    const { token, session } = await testUtils.createSessionForUser(user.id, { clientType: "macos" })
    const connectionId = "test-connection"
    connectionManager.addConnection(
      { id: connectionId, close() {}, subscribe() {} } as never,
      ConnVersion.REALTIME_V1,
    )

    try {
      await handleConnectionInit(
        {
          token,
          clientVersion: "unknown",
          buildNumber: 123,
          osVersion: "15.2.1",
          layer: 2,
        },
        {
          userId: 0,
          sessionId: 0,
          connectionId,
          sendRaw() {},
          sendRpcReply() {},
        },
      )

      const updatedSession = await db
        .select({ clientVersion: sessions.clientVersion, osVersion: sessions.osVersion })
        .from(sessions)
        .where(eq(sessions.id, session.id))
        .limit(1)
        .then((rows) => rows[0])

      expect(updatedSession?.clientVersion).toBe("123")
      expect(updatedSession?.osVersion).toBe("15.2.1")
    } finally {
      connectionManager.removeConnection(connectionId)
    }
  })
})
