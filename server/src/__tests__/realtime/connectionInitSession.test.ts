import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { sessions } from "@in/server/db/schema"
import { storeSessionInfo } from "@in/server/realtime/handlers/_connectionInit"

describe("connection init session metadata", () => {
  setupTestLifecycle()

  test("writes the session row only when the client or OS version changed", async () => {
    const user = await testUtils.createUser("session-info@example.com")
    const { session } = await testUtils.createSessionForUser(user.id, { clientVersion: "1.0.0", osVersion: "26.0" })
    if (!session) throw new Error("Session not created")

    expect(await storeSessionInfo(session.id, user.id, "1.0.0", "26.0")).toBe(0)
    expect(await storeSessionInfo(session.id, user.id, "1.0.1", "26.0")).toBe(1)
    expect(await storeSessionInfo(session.id, user.id, "1.0.1", "26.0")).toBe(0)
    expect(await storeSessionInfo(session.id, user.id, undefined, "26.1")).toBe(1)
    expect(await storeSessionInfo(session.id, user.id)).toBe(0)

    const [row] = await db.select().from(sessions).where(eq(sessions.id, session.id))
    expect(row?.clientVersion).toBe("1.0.1")
    expect(row?.osVersion).toBe("26.1")
  })

  test("a first report fills empty metadata, and another user's session is never touched", async () => {
    const user = await testUtils.createUser("session-info-empty@example.com")
    const other = await testUtils.createUser("session-info-other@example.com")
    const { session } = await testUtils.createSessionForUser(user.id)
    if (!session) throw new Error("Session not created")

    expect(await storeSessionInfo(session.id, other.id, "2.0.0")).toBe(0)
    expect(await storeSessionInfo(session.id, user.id, "2.0.0")).toBe(1)
    const [row] = await db.select().from(sessions).where(eq(sessions.id, session.id))
    expect(row?.clientVersion).toBe("2.0.0")
  })
})
