import { describe, expect, test, beforeEach } from "bun:test"
import { createBot } from "../../functions/createBot"
import { setupTestLifecycle, defaultTestContext, testUtils } from "../setup"
import type { FunctionContext } from "../../functions/_types"

describe("createBot", () => {
  // Setup test lifecycle
  setupTestLifecycle()

  let testUser: any
  let mockFunctionContext: FunctionContext

  beforeEach(async () => {
    // Create a test user to use as the bot creator
    testUser = await testUtils.createUser("creator@example.com")

    mockFunctionContext = {
      currentSessionId: defaultTestContext.sessionId,
      currentUserId: testUser.id,
    }
  })

  test("should create a bot with valid input", async () => {
    const input = {
      name: "Test Bot",
      username: "testbot",
    }

    const result = await createBot(input, mockFunctionContext)

    expect(result.bot).toBeDefined()
    expect(result.bot?.firstName).toBe("Test Bot")
    expect(result.bot?.username).toBe("testbot")
    expect(result.bot?.bot).toBe(true)
    expect(result.token).toBeDefined()
    expect(typeof result.token).toBe("string")
    expect(result.token.length).toBeGreaterThan(0)
  })

  test("should fail with invalid username", async () => {
    const input = {
      name: "Test Bot",
      username: "a", // Too short
    }

    await expect(createBot(input, mockFunctionContext)).rejects.toThrow()
  })

  test("should fail with empty name", async () => {
    const input = {
      name: "",
      username: "testbot2",
    }

    await expect(createBot(input, mockFunctionContext)).rejects.toThrow()
  })

  test("should fail with duplicate username", async () => {
    const input1 = {
      name: "Test Bot 1",
      username: "duplicatebot",
    }

    const input2 = {
      name: "Test Bot 2",
      username: "duplicatebot", // Same username
    }

    await createBot(input1, mockFunctionContext)
    await expect(createBot(input2, mockFunctionContext)).rejects.toThrow()
  })

  test("should create bot and add to space when addToSpace is provided", async () => {
    // Create a test space first
    const space = await testUtils.createSpace("Test Space")

    if (!space) {
      throw new Error("Failed to create test space")
    }

    const input = {
      name: "Space Bot",
      username: "spacebot",
      addToSpace: BigInt(space.id),
    }

    const result = await createBot(input, mockFunctionContext)

    expect(result.bot).toBeDefined()
    expect(result.bot?.firstName).toBe("Space Bot")
    expect(result.bot?.username).toBe("spacebot")
    expect(result.bot?.bot).toBe(true)
    expect(result.token).toBeDefined()
    expect(typeof result.token).toBe("string")
  })
})
