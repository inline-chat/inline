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

  test("checks canonical collisions and rejects unusable candidates", async () => {
    const owner = await testUtils.createUser("canonical-owner@example.com")
    const user = await testUtils.createUser("canonical-check@example.com")
    await db.update(users).set({ username: "test_person" }).where(eq(users.id, owner.id))
    expect((await handler({ username: "Test.Person@example.com" }, makeContext(user.id))).available).toBe(false)
    for (const username of ["", "@@@", "💥", "a", "a".repeat(65)]) {
      expect((await handler({ username }, makeContext(user.id))).available).toBe(false)
    }
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
