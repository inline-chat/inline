import { describe, test, expect, beforeAll, afterAll, beforeEach, afterEach, setSystemTime } from "bun:test"
import { setupTestDatabase, teardownTestDatabase, testUtils, cleanDatabase } from "../../setup"
import { clearSpaceCache, getCachedSpaceInfo } from "@in/server/modules/cache/spaceCache"
import { db, schema } from "@in/server/db"
import { eq } from "drizzle-orm"

const BASE_TIME = 1 // Bun's setSystemTime treats 0 as "reset to real time".

describe("Space Cache", () => {
  beforeAll(async () => {
    await setupTestDatabase()
  })

  afterAll(async () => {
    await teardownTestDatabase()
  })

  beforeEach(async () => {
    await cleanDatabase()
    clearSpaceCache()
    setSystemTime(new Date(BASE_TIME))
  })

  afterEach(() => {
    setSystemTime()
  })

  test("should return undefined for non-existent space", async () => {
    const result = await getCachedSpaceInfo(99999)
    expect(result).toBeUndefined()
  })

  test("should cache and return space info correctly", async () => {
    // Create test space with members using the helper function
    const { space, users } = await testUtils.createSpaceWithMembers("Test Space", ["user1@test.com", "user2@test.com"])

    const result = await getCachedSpaceInfo(space.id)

    expect(result).toBeDefined()
    expect(result!.id).toBe(space.id)
    expect(result!.name).toBe("Test Space")
    expect(result!.memberUserIds).toHaveLength(2)
    expect(result!.memberUserIds).toContain(users[0]!.id)
    expect(result!.memberUserIds).toContain(users[1]!.id)
    expect(result!.cacheDate).toBeNumber()
    expect(result!.cacheDate).toBeLessThanOrEqual(Date.now())
  })

  test("should return cached result on second call", async () => {
    const { space } = await testUtils.createSpaceWithMembers("Test Space", ["user@test.com"])

    // First call - should fetch from database
    const result1 = await getCachedSpaceInfo(space.id)
    const cacheDate1 = result1!.cacheDate

    // Update the DB, then advance time slightly. Cached result should still be returned.
    await db.update(schema.spaces).set({ name: "Updated Space" }).where(eq(schema.spaces.id, space.id))
    setSystemTime(new Date(Date.now() + 1))

    // Second call - should return cached result
    const result2 = await getCachedSpaceInfo(space.id)

    expect(result2!.cacheDate).toBe(cacheDate1) // Same cache date means it was cached
    expect(result2!.id).toBe(space.id)
    expect(result2!.name).toBe("Test Space")
    expect(result2!.memberUserIds).toHaveLength(1)
  })

  test("should refresh cache after TTL expires", async () => {
    const { space } = await testUtils.createSpaceWithMembers("Test Space", ["user@test.com"])

    // Get initial cached result
    const result1 = await getCachedSpaceInfo(space.id)
    const cacheDate1 = result1!.cacheDate

    // Update DB and move time past cache validity (10 minutes).
    await db.update(schema.spaces).set({ name: "Updated Space" }).where(eq(schema.spaces.id, space.id))
    setSystemTime(new Date(cacheDate1 + 10 * 60 * 1000 + 1))

    const result2 = await getCachedSpaceInfo(space.id)

    // Cache should be refreshed.
    expect(result1).toBeDefined()
    expect(result2).toBeDefined()
    expect(result2!.id).toBe(space.id)
    expect(result2!.name).toBe("Updated Space")
    expect(result2!.cacheDate).toBeGreaterThan(cacheDate1)
  })

  test("should handle space with no members", async () => {
    const space = await testUtils.createSpace("Empty Space")

    const result = await getCachedSpaceInfo(space!.id)

    expect(result).toBeDefined()
    expect(result!.id).toBe(space!.id)
    expect(result!.name).toBe("Empty Space")
    expect(result!.memberUserIds).toHaveLength(0)
  })

  test("should handle space with empty name", async () => {
    // Create space directly in database with empty string name (not null)
    const [space] = await db
      .insert(schema.spaces)
      .values({
        name: "",
        creatorId: null,
      })
      .returning()

    const result = await getCachedSpaceInfo(space!.id)

    expect(result).toBeDefined()
    expect(result!.id).toBe(space!.id)
    expect(result!.name).toBe("")
    expect(result!.memberUserIds).toHaveLength(0)
  })

  test("should handle multiple members correctly", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Multi Member Space", [
      "user1@test.com",
      "user2@test.com",
      "user3@test.com",
      "user4@test.com",
      "user5@test.com",
    ])

    const result = await getCachedSpaceInfo(space.id)

    expect(result).toBeDefined()
    expect(result!.memberUserIds).toHaveLength(5)

    // Check all user IDs are present
    for (const user of users) {
      expect(result!.memberUserIds).toContain(user!.id)
    }
  })

  test("should maintain cache consistency with concurrent calls", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Concurrent Space", ["user@test.com"])

    // Make multiple concurrent calls
    const promises = Array(10)
      .fill(null)
      .map(() => getCachedSpaceInfo(space.id))
    const results = await Promise.all(promises)

    // All results should be defined and have the same basic properties
    for (let i = 0; i < results.length; i++) {
      expect(results[i]).toBeDefined()
      expect(results[i]!.id).toBe(space.id)
      expect(results[i]!.memberUserIds).toHaveLength(1)
    }

    // The cache dates should be close (within a reasonable time window)
    const firstCacheDate = results[0]!.cacheDate
    for (let i = 1; i < results.length; i++) {
      expect(results[i]!.cacheDate).toBe(firstCacheDate)
    }
  })
})
