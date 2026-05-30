import { describe, expect, test } from "bun:test"
import { db, schema } from "@in/server/db"
import { getUserIdFromToken } from "@in/server/controllers/plugins"
import { getOrCreateUserByEmailForSignup } from "@in/server/modules/auth/signupInvites"
import { setupTestLifecycle, testUtils } from "./setup"
import { eq } from "drizzle-orm"

describe("deleted user auth", () => {
  setupTestLifecycle()

  test("rejects tokens for soft-deleted users", async () => {
    const user = await testUtils.createUser("deleted-auth@example.com")
    const { token } = await testUtils.createSessionForUser(user.id)

    await db.update(schema.users).set({ deleted: true }).where(eq(schema.users.id, user.id))

    await expect(getUserIdFromToken(token)).rejects.toMatchObject({ type: "USER_DEACTIVATED" })
  })

  test("does not revive soft-deleted users during email signup", async () => {
    const user = await testUtils.createUser("deleted-signup@example.com")
    await db.update(schema.users).set({ deleted: true }).where(eq(schema.users.id, user.id))

    await expect(getOrCreateUserByEmailForSignup("deleted-signup@example.com")).rejects.toMatchObject({
      type: "USER_DEACTIVATED",
    })
  })
})
