import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
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
      accessTokenEncrypted: Buffer.from("encrypted"),
      accessTokenIv: Buffer.from("iv"),
      accessTokenTag: Buffer.from("tag"),
    })

    const result = await handler({ userId: String(user.id), spaceId: "0" }, makeContext(user.id))

    expect(result.hasNotionConnected).toBe(true)
    expect(result.notionSpaces).toEqual([{ spaceId: space.id, spaceName: space.name }])
  })

  test("does not advertise a tokenless integration", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Tokenless Space", [
      "tokenless-space@example.com",
    ])
    const user = users[0]
    if (!user) throw new Error("Failed to create user")
    await db.insert(schema.integrations).values({
      userId: user.id,
      spaceId: space.id,
      provider: "notion",
    })

    const result = await handler(
      { userId: String(user.id), spaceId: String(space.id) },
      makeContext(user.id),
    )

    expect(result.hasNotionConnected).toBe(false)
    expect(result.hasIntegrationAccess).toBe(false)
  })

  test("rejects non-numeric space ids", async () => {
    const user = await testUtils.createUser("bad-space-lookup@example.com")

    await expect(handler({ userId: String(user.id), spaceId: "abc" }, makeContext(user.id))).rejects.toMatchObject({
      type: InlineError.ApiError.BAD_REQUEST[0],
      code: InlineError.ApiError.BAD_REQUEST[1],
    })
  })

  test("does not advertise integrations from a public space", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Public Connector Space", [
      "public-connector-member@example.com",
    ])
    const user = users[0]
    if (!user) throw new Error("Failed to create user")
    await db.update(schema.spaces)
      .set({ isPublic: true })
      .where(eq(schema.spaces.id, space.id))
    await db.insert(schema.integrations).values({
      userId: user.id,
      spaceId: space.id,
      provider: "notion",
    })

    const scoped = await handler(
      { userId: String(user.id), spaceId: String(space.id) },
      makeContext(user.id),
    )
    const unscoped = await handler(
      { userId: String(user.id) },
      makeContext(user.id),
    )

    expect(scoped.hasNotionConnected).toBe(false)
    expect(scoped.hasIntegrationAccess).toBe(false)
    expect(unscoped.hasNotionConnected).toBe(false)
    expect(unscoped.notionSpaces).toBeUndefined()
  })
})
