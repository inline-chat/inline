import { describe, expect, test } from "bun:test"
import { db } from "../../db"
import * as schema from "../../db/schema"
import type { HandlerContext } from "../../controllers/helpers"
import { handler } from "../../methods/getIntegrations"
import { InlineError } from "../../types/errors"
import { setupTestLifecycle, testUtils } from "../setup"

describe("getIntegrations", () => {
  setupTestLifecycle()

  const makeContext = (userId: number): HandlerContext => ({
    currentUserId: userId,
    currentSessionId: 0,
    ip: "127.0.0.1",
  })

  test("treats spaceId 0 as unscoped integration lookup", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Zero Space Lookup", [
      "zero-space-lookup@example.com",
    ])
    const user = users[0]
    if (!user) throw new Error("Failed to create user")

    await db.insert(schema.integrations).values({
      userId: user.id,
      spaceId: space.id,
      provider: "notion",
    })

    const result = await handler({ userId: String(user.id), spaceId: "0" }, makeContext(user.id))

    expect(result.hasNotionConnected).toBe(true)
    expect(result.notionSpaces).toEqual([{ spaceId: space.id, spaceName: space.name }])
  })

  test("rejects non-numeric space ids", async () => {
    const user = await testUtils.createUser("bad-space-lookup@example.com")

    await expect(handler({ userId: String(user.id), spaceId: "abc" }, makeContext(user.id))).rejects.toMatchObject({
      type: InlineError.ApiError.BAD_REQUEST[0],
      code: InlineError.ApiError.BAD_REQUEST[1],
    })
  })
})
