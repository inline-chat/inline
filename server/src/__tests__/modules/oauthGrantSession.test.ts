import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db, schema } from "@in/server/db"
import { isGrantSessionActive } from "@in/server/modules/oauth/grantSession"
import { setupTestLifecycle, testUtils } from "../setup"

describe("OAuth backing session authority", () => {
  setupTestLifecycle()

  test("requires a live session for exactly the grant's account", async () => {
    const user = await testUtils.createUser("oauth-backing-session@example.com")
    const { token, session } = await testUtils.createSessionForUser(user.id)
    expect(await isGrantSessionActive(token, user.id)).toBe(true)
    expect(await isGrantSessionActive(token, user.id + 1)).toBe(false)
    expect(await isGrantSessionActive("invalid-token", user.id)).toBe(false)
    await db.update(schema.sessions).set({ revoked: new Date() }).where(eq(schema.sessions.id, session.id))
    expect(await isGrantSessionActive(token, user.id)).toBe(false)
  })

  test("a deleted account cannot retain OAuth access through an unrevoked session", async () => {
    const user = await testUtils.createUser("oauth-deleted-user@example.com")
    const { token } = await testUtils.createSessionForUser(user.id)
    await db.update(schema.users).set({ deleted: true }).where(eq(schema.users.id, user.id))
    expect(await isGrantSessionActive(token, user.id)).toBe(false)
  })
})
