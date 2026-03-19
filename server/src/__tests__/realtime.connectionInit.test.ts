import { describe, expect, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { handleConnectionInit } from "@in/server/realtime/handlers/_connectionInit"
import { db } from "@in/server/db"
import { sessions } from "@in/server/db/schema"
import { eq } from "drizzle-orm"

setupTestLifecycle()

describe("handleConnectionInit", () => {
  test("ignores invalid client version without warning and falls back to build number", async () => {
    const user = await testUtils.createUser("connection-init@test.com")
    const { token, session } = await testUtils.createSessionForUser(user.id, { clientType: "ios" })

    await handleConnectionInit(
      {
        token,
        clientVersion: "unknown",
        buildNumber: 123,
        layer: 2,
      },
      {
        userId: 0,
        sessionId: 0,
        connectionId: "test-connection",
        sendRaw() {},
        sendRpcReply() {},
      },
    )

    const updatedSession = await db
      .select({ clientVersion: sessions.clientVersion })
      .from(sessions)
      .where(eq(sessions.id, session.id))
      .limit(1)
      .then((rows) => rows[0])

    expect(updatedSession?.clientVersion).toBe("123")
  })
})
