import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "../../db"
import { users } from "../../db/schema"
import { handler } from "../../methods/updateProfile"
import type { HandlerContext } from "../../controllers/helpers"
import { setupTestLifecycle, testUtils } from "../setup"
import { InlineError } from "../../types/errors"

describe("updateProfile", () => {
  setupTestLifecycle()

  const makeContext = (userId: number): HandlerContext => ({
    currentUserId: userId,
    currentSessionId: 0,
    ip: "127.0.0.1",
  })

  test("strips leading @ from username", async () => {
    const user = await testUtils.createUser("profile@example.com")

    const result = await handler({ username: "@profilehandle" }, makeContext(user.id))

    expect(result.user.username).toBe("profilehandle")

    const [storedUser] = await db.select().from(users).where(eq(users.id, user.id))
    expect(storedUser?.username).toBe("profilehandle")
  })

  test("surfaces taken username errors", async () => {
    const existing = await testUtils.createUser("existing-profile@example.com")
    const user = await testUtils.createUser("new-profile@example.com")
    await db.update(users).set({ username: "taken" }).where(eq(users.id, existing.id))

    await expect(handler({ username: "taken" }, makeContext(user.id))).rejects.toMatchObject({
      type: InlineError.ApiError.USERNAME_TAKEN[0],
      code: InlineError.ApiError.USERNAME_TAKEN[1],
      description: InlineError.ApiError.USERNAME_TAKEN[2],
    })
  })

  test("surfaces invalid username errors", async () => {
    const user = await testUtils.createUser("invalid-profile@example.com")

    await expect(handler({ username: "a" }, makeContext(user.id))).rejects.toMatchObject({
      type: InlineError.ApiError.USERNAME_INVALID[0],
      code: InlineError.ApiError.USERNAME_INVALID[1],
      description: InlineError.ApiError.USERNAME_INVALID[2],
    })
  })
})
