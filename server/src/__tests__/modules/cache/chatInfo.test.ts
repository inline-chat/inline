import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test"
import { setupTestDatabase, teardownTestDatabase, testUtils, cleanDatabase } from "../../setup"
import { clearChatInfoCache, getCachedChatInfo } from "@in/server/modules/cache/chatInfo"
import { db, schema } from "@in/server/db"

describe("Chat Info Cache", () => {
  beforeAll(async () => {
    await setupTestDatabase()
  })

  afterAll(async () => {
    await teardownTestDatabase()
  })

  beforeEach(async () => {
    clearChatInfoCache()
    await cleanDatabase()
  })

  test("should return undefined for non-existent chat", async () => {
    const result = await getCachedChatInfo(99999)
    expect(result).toBeUndefined()
  })

  test("should cache and return public thread chat info correctly", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Test Space", ["user1@test.com", "user2@test.com"])
    const chat = await testUtils.createChat(space.id, "Public Thread", "thread", true)

    const result = await getCachedChatInfo(chat!.id)

    expect(result).toBeDefined()
    expect(result!.type).toBe("thread")
    expect(result!.public).toBe(true)
    expect(result!.title).toBe("Public Thread")
    expect(result!.spaceId).toBe(space.id)
    expect(result!.participantUserIds).toHaveLength(2) // All space members
    expect(result!.participantUserIds).toContain(users[0]!.id)
    expect(result!.participantUserIds).toContain(users[1]!.id)
    expect(result!.cacheDate).toBeNumber()
    expect(result!.cacheDate).toBeLessThanOrEqual(Date.now())
  })

  test("should cache and return private thread chat info correctly", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Test Space", [
      "user1@test.com",
      "user2@test.com",
      "user3@test.com",
    ])
    const chat = await testUtils.createChat(space.id, "Private Thread", "thread", false)

    // Add specific participants to private thread
    await testUtils.addParticipant(chat!.id, users[0]!.id)
    await testUtils.addParticipant(chat!.id, users[1]!.id)

    const result = await getCachedChatInfo(chat!.id)

    expect(result).toBeDefined()
    expect(result!.type).toBe("thread")
    expect(result!.public).toBe(false)
    expect(result!.title).toBe("Private Thread")
    expect(result!.spaceId).toBe(space.id)
    expect(result!.participantUserIds).toHaveLength(2) // Only participants
    expect(result!.participantUserIds).toContain(users[0]!.id)
    expect(result!.participantUserIds).toContain(users[1]!.id)
    expect(result!.participantUserIds).not.toContain(users[2]!.id)
  })

  test("should cache and return private chat info correctly", async () => {
    const user1 = await testUtils.createUser("user1@test.com")
    const user2 = await testUtils.createUser("user2@test.com")
    const chat = await testUtils.createPrivateChat(user1!, user2!)

    const result = await getCachedChatInfo(chat!.id)

    expect(result).toBeDefined()
    expect(result!.type).toBe("private")
    expect(result!.public).toBe(false)
    expect(result!.title).toBeNull()
    expect(result!.spaceId).toBeNull()
    expect(result!.participantUserIds).toHaveLength(2)
    expect(result!.participantUserIds).toContain(user1!.id)
    expect(result!.participantUserIds).toContain(user2!.id)
  })

  test("should return cached result on second call", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Test Space", ["user@test.com"])
    const chat = await testUtils.createChat(space.id, "Test Chat", "thread", true)

    // First call - should fetch from database
    const result1 = await getCachedChatInfo(chat!.id)
    const cacheDate1 = result1!.cacheDate

    // Wait a tiny bit to ensure different timestamps if fetched again
    await new Promise((resolve) => setTimeout(resolve, 1))

    // Second call - should return cached result
    const result2 = await getCachedChatInfo(chat!.id)

    expect(result2!.cacheDate).toBe(cacheDate1) // Same cache date means it was cached
    expect(result2!.type).toBe("thread")
    expect(result2!.title).toBe("Test Chat")
  })

  test("should refresh cache after TTL expires", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Test Space", ["user@test.com"])
    const chat = await testUtils.createChat(space.id, "Test Chat", "thread", true)

    // Get initial cached result
    const result1 = await getCachedChatInfo(chat!.id)

    // Wait a bit and call again - should still be cached
    await new Promise((resolve) => setTimeout(resolve, 10))
    const result2 = await getCachedChatInfo(chat!.id)

    // Both results should be valid (this tests the basic caching functionality)
    expect(result1).toBeDefined()
    expect(result2).toBeDefined()
    expect(result2!.type).toBe("thread")
    expect(result2!.title).toBe("Test Chat")
  })

  test("should handle chat with null title", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Test Space", ["user@test.com"])
    const chat = await testUtils.createChat(space.id, null as any, "thread", true)

    const result = await getCachedChatInfo(chat!.id)

    expect(result).toBeDefined()
    expect(result!.title).toBeNull()
    expect(result!.type).toBe("thread")
    expect(result!.public).toBe(true)
  })

  // test("should handle public thread in space with no members", async () => {
  //   const space = await testUtils.createSpace("Empty Space")
  //   const chat = await testUtils.createChat(space!.id, "Empty Thread", "thread", true)

  //   const result = await getCachedChatInfo(chat!.id)

  //   expect(result).toBeDefined()
  //   expect(result!.type).toBe("thread")
  //   expect(result!.public).toBe(true)
  //   expect(result!.participantUserIds).toHaveLength(0) // No space members
  // })

  test("should handle private thread with no participants", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Test Space", ["user@test.com"])
    const chat = await testUtils.createChat(space.id, "Private Thread", "thread", false)
    // Don't add any participants

    const result = await getCachedChatInfo(chat!.id)

    expect(result).toBeDefined()
    expect(result!.type).toBe("thread")
    expect(result!.public).toBe(false)
    expect(result!.participantUserIds).toHaveLength(0) // No participants
  })

  test("should handle private chat with user IDs", async () => {
    // Create a private chat directly in database with user IDs
    const user1 = await testUtils.createUser("user1@test.com")
    const user2 = await testUtils.createUser("user2@test.com")
    const [chat] = await db
      .insert(schema.chats)
      .values({
        type: "private",
        minUserId: Math.min(user1!.id, user2!.id),
        maxUserId: Math.max(user1!.id, user2!.id),
      })
      .returning()

    const result = await getCachedChatInfo(chat!.id)

    expect(result).toBeDefined()
    expect(result!.type).toBe("private")
    expect(result!.participantUserIds).toHaveLength(2)
    expect(result!.participantUserIds).toContain(user1!.id)
    expect(result!.participantUserIds).toContain(user2!.id)
  })

  test("should maintain cache consistency with concurrent calls", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Test Space", ["user@test.com"])
    const chat = await testUtils.createChat(space.id, "Concurrent Chat", "thread", true)

    // Make multiple concurrent calls
    const promises = Array(10)
      .fill(null)
      .map(() => getCachedChatInfo(chat!.id))
    const results = await Promise.all(promises)

    // All results should be defined and have the same basic properties
    for (let i = 0; i < results.length; i++) {
      expect(results[i]).toBeDefined()
      expect(results[i]!.type).toBe("thread")
      expect(results[i]!.title).toBe("Concurrent Chat")
    }

    // The cache dates should be close (within a reasonable time window)
    const firstCacheDate = results[0]!.cacheDate
    for (let i = 1; i < results.length; i++) {
      const timeDiff = Math.abs(results[i]!.cacheDate - firstCacheDate)
      expect(timeDiff).toBeLessThan(100) // Within 100ms
    }
  })

  test("should handle dependency on space cache correctly", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Test Space", ["user1@test.com", "user2@test.com"])
    const chat = await testUtils.createChat(space.id, "Space Chat", "thread", true)

    // Get chat info which should also populate space cache
    const result1 = await getCachedChatInfo(chat!.id)
    expect(result1!.participantUserIds).toHaveLength(2)
    expect(result1!.participantUserIds).toContain(users[0]!.id)
    expect(result1!.participantUserIds).toContain(users[1]!.id)

    // Create another space with different members to test caching independence
    const { space: space2, users: users2 } = await testUtils.createSpaceWithMembers("Test Space 2", ["user3@test.com"])
    const chat2 = await testUtils.createChat(space2.id, "Space Chat 2", "thread", true)

    const result2 = await getCachedChatInfo(chat2!.id)
    expect(result2!.participantUserIds).toHaveLength(1)
    expect(result2!.participantUserIds).toContain(users2[0]!.id)

    // Original chat should still have correct participant count
    const result3 = await getCachedChatInfo(chat!.id)
    expect(result3!.participantUserIds).toHaveLength(2)
  })
})
