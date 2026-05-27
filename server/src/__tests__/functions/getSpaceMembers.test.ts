import { describe, test, expect } from "bun:test"
import { getSpaceMembers } from "@in/server/functions/space.getSpaceMembers"
import { handler as getSpaceMembersLegacy } from "@in/server/methods/getSpaceMembers"
import { testUtils, setupTestLifecycle } from "../setup"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"

function makeFunctionContext(userId: number) {
  return {
    currentUserId: userId,
    currentSessionId: 1,
    // Add other fields as needed
  }
}

describe("getSpaceMembers", () => {
  setupTestLifecycle()

  test("returns correct members and users for a space", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Test Space", ["a@ex.com", "b@ex.com"])
    const input = { spaceId: BigInt(space.id) }
    const context = makeFunctionContext(users[0].id)
    const result = await getSpaceMembers(input, context)
    expect(Array.isArray(result.members)).toBe(true)
    expect(Array.isArray(result.users)).toBe(true)
    expect(result.members.length).toBe(2)
    expect(result.users.length).toBe(2)
    // Check that returned user emails match
    const ids = result.users.map((u: any) => u.id)
    expect(ids).toContain(BigInt(users[0].id))
    expect(ids).toContain(BigInt(users[1].id))
  })

  test("throws for a space when caller is not a member", async () => {
    const space = await testUtils.createSpace("Empty Space")
    if (!space) throw new Error("Failed to create space")
    const input = { spaceId: BigInt(space.id) }
    const context = makeFunctionContext(1)
    await expect(getSpaceMembers(input, context)).rejects.toThrow()
  })

  test("returns public space members with min users for regular members", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Public Space", [
      "public-a@ex.com",
      "public-b@ex.com",
    ])
    await db.update(schema.spaces).set({ isPublic: true }).where(eq(schema.spaces.id, space.id))

    const result = await getSpaceMembers({ spaceId: BigInt(space.id) }, makeFunctionContext(users[0].id))
    expect(result.members.length).toBe(2)
    expect(result.users.length).toBe(2)
    expect(result.users.map((user) => user.id)).toContain(BigInt(users[1].id))
    const otherUser = result.users.find((user) => user.id === BigInt(users[1].id))
    expect(otherUser?.email).toBeUndefined()
    expect(otherUser?.phoneNumber).toBeUndefined()
    expect(otherUser?.timeZone).toBeUndefined()
    expect(otherUser?.status).toBeUndefined()
    expect(otherUser?.min).toBe(true)
  })

  test("legacy getSpaceMembers returns public members without personal user info", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Public Legacy Space", [
      "public-legacy-a@ex.com",
      "public-legacy-b@ex.com",
    ])
    await db.update(schema.spaces).set({ isPublic: true }).where(eq(schema.spaces.id, space.id))

    const result = await getSpaceMembersLegacy(
      { spaceId: space.id },
      { currentUserId: users[0].id },
    )
    expect(result.members.length).toBe(2)
    expect(result.users.length).toBe(2)
    expect(result.users.map((user) => user.id)).toContain(users[1].id)
    expect(result.users.some((user) => Object.hasOwn(user, "email"))).toBe(false)
  })

  test("allows admins to list public space members", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Public Admin Space", [
      "public-admin@ex.com",
      "public-member@ex.com",
    ])
    await db.update(schema.spaces).set({ isPublic: true }).where(eq(schema.spaces.id, space.id))
    await db
      .update(schema.members)
      .set({ role: "admin" })
      .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, users[0].id)))

    const result = await getSpaceMembers({ spaceId: BigInt(space.id) }, makeFunctionContext(users[0].id))
    expect(result.members.length).toBe(2)
    expect(result.users.map((user) => user.email)).toContain("public-member@ex.com")
  })

  test("throws error for invalid spaceId", async () => {
    const input = { spaceId: BigInt(-1) }
    const context = makeFunctionContext(1)
    await expect(getSpaceMembers(input, context)).rejects.toThrow()
  })
})
