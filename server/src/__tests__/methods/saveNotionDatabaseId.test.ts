import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import type { HandlerContext } from "../../controllers/helpers"
import { handler } from "../../methods/notion/saveNotionDatabaseId"

describe("saveNotionDatabaseId", () => {
  setupTestLifecycle()

  test("saves only a source available to the connected workspace", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers(
      "Notion Source Validation",
      ["notion-source@example.com"],
    )
    const user = users[0]
    if (!user) throw new Error("Failed to create user")
    await db.update(schema.members).set({ role: "admin" }).where(and(
      eq(schema.members.spaceId, space.id),
      eq(schema.members.userId, user.id),
    ))
    await db.insert(schema.integrations).values({
      userId: user.id,
      spaceId: space.id,
      provider: "notion",
    })
    const context: HandlerContext = {
      currentUserId: user.id,
      currentSessionId: 0,
      ip: "127.0.0.1",
    }

    await expect(handler(
      { spaceId: String(space.id), databaseId: "stale-source" },
      context,
      { async listDatabases() { return [{ id: "current-source" }] } },
    )).rejects.toThrow("Notion source is not available")

    await handler(
      { spaceId: String(space.id), databaseId: "current-source" },
      context,
      { async listDatabases() { return [{ id: "current-source" }] } },
    )
    const [integration] = await db.select().from(schema.integrations).where(and(
      eq(schema.integrations.spaceId, space.id),
      eq(schema.integrations.provider, "notion"),
    ))
    expect(integration?.notionDatabaseId).toBe("current-source")
  })
})
