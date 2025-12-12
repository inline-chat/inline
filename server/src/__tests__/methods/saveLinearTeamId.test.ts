import { describe, test, expect } from "bun:test"
import { setupTestLifecycle, testUtils } from "../setup"
import { handler } from "../../methods/linear/saveLinearTeamId"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { and, eq } from "drizzle-orm"
import type { HandlerContext } from "../../controllers/helpers"

describe("saveLinearTeamId", () => {
  setupTestLifecycle()

  const makeContext = (userId: number): HandlerContext => ({
    currentUserId: userId,
    currentSessionId: 0,
    ip: "127.0.0.1",
  })

  test("updates linearTeamId for a space integration", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Linear Space", ["linear@example.com"])
    const user = users[0]
    if (!user) throw new Error("Failed to create user")

    // Promote to admin to allow saving options
    await db
      .update(schema.members)
      .set({ role: "admin" })
      .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, user.id)))

    await db.insert(schema.integrations).values({
      userId: user.id,
      spaceId: space.id,
      provider: "linear",
    })

    await handler({ spaceId: String(space.id), teamId: "team-123" }, makeContext(user.id))

    const [integration] = await db
      .select()
      .from(schema.integrations)
      .where(and(eq(schema.integrations.spaceId, space.id), eq(schema.integrations.provider, "linear")))

    expect(integration?.linearTeamId).toBe("team-123")
  })

  test("rejects updates from non-members", async () => {
    const { space } = await testUtils.createSpaceWithMembers("Linear Space 2", ["member@example.com"])
    const outsider = await testUtils.createUser("outsider@example.com")
    if (!outsider) throw new Error("Failed to create outsider user")

    await expect(
      handler({ spaceId: String(space.id), teamId: "team-x" }, makeContext(outsider.id)),
    ).rejects.toBeDefined()
  })
})
