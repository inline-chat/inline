import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "../../db"
import { users } from "../../db/schema"
import { handler } from "../../methods/updateProfile"
import type { HandlerContext } from "../../controllers/helpers"
import { setupTestLifecycle, testUtils } from "../setup"

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
})
