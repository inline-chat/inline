import { describe, test, expect } from "bun:test"
import { getSpaceMembers } from "@in/server/functions/space.getSpaceMembers"
import { testUtils, setupTestLifecycle } from "../setup"

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

  test("returns empty arrays for a space with no members", async () => {
    const space = await testUtils.createSpace("Empty Space")
    if (!space) throw new Error("Failed to create space")
    const input = { spaceId: BigInt(space.id) }
    const context = makeFunctionContext(1)
    const result = await getSpaceMembers(input, context)
    expect(result.members).toEqual([])
    expect(result.users).toEqual([])
  })

  test("throws error for invalid spaceId", async () => {
    const input = { spaceId: BigInt(-1) }
    const context = makeFunctionContext(1)
    await expect(getSpaceMembers(input, context)).rejects.toThrow()
  })
})
