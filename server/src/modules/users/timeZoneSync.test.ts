import { describe, expect, test } from "bun:test"
import { db } from "@in/server/db"
import { sessions, users } from "@in/server/db/schema"
import { syncTimeZoneForElectedAppleSession } from "@in/server/modules/users/timeZoneSync"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { eq } from "drizzle-orm"

describe("time-zone writer election", () => {
  setupTestLifecycle()

  test("only the newest non-revoked Apple session writes", async () => {
    const user = await testUtils.createUser("timezone-election@example.com")
    const oldSession = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    const webSession = await testUtils.createSessionForUser(user.id, { clientType: "web" })
    const newSession = await testUtils.createSessionForUser(user.id, { clientType: "macos" })

    expect(
      await syncTimeZoneForElectedAppleSession({
        userId: user.id,
        sessionId: oldSession.session.id,
        timeZone: "America/Toronto",
      }),
    ).toBeUndefined()
    expect(
      await syncTimeZoneForElectedAppleSession({
        userId: user.id,
        sessionId: webSession.session.id,
        timeZone: "Europe/London",
      }),
    ).toBeUndefined()

    const updated = await syncTimeZoneForElectedAppleSession({
      userId: user.id,
      sessionId: newSession.session.id,
      timeZone: "Asia/Tehran",
    })
    expect(updated?.timeZone).toBe("Asia/Tehran")

    const [storedUser] = await db.select().from(users).where(eq(users.id, user.id))
    expect(storedUser?.timeZone).toBe("Asia/Tehran")

    await db.update(sessions).set({ revoked: new Date() }).where(eq(sessions.id, newSession.session.id))
    const fallbackUpdate = await syncTimeZoneForElectedAppleSession({
      userId: user.id,
      sessionId: oldSession.session.id,
      timeZone: "America/Toronto",
    })
    expect(fallbackUpdate?.timeZone).toBe("America/Toronto")
  })
})
