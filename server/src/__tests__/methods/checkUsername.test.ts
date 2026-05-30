import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "../../db"
import { users } from "../../db/schema"
import { handler } from "../../methods/checkUsername"
import type { HandlerContext } from "../../controllers/helpers"
import { setupTestLifecycle, testUtils } from "../setup"

describe("checkUsername", () => {
  setupTestLifecycle()

  const makeContext = (userId: number): HandlerContext => ({
    currentUserId: userId,
    currentSessionId: 0,
    ip: "127.0.0.1",
  })

  test("reports reserved usernames as unavailable", async () => {
    const user = await testUtils.createUser("check-reserved@example.com")

    const result = await handler({ username: "@Inline" }, makeContext(user.id))

    expect(result.available).toBe(false)
  })

  test("reports an existing reserved username as available to its owner", async () => {
    const user = await testUtils.createUser("check-reserved-owner@example.com")
    await db.update(users).set({ username: "inline" }).where(eq(users.id, user.id))

    const result = await handler({ username: "inline" }, makeContext(user.id))

    expect(result.available).toBe(true)
  })
})
