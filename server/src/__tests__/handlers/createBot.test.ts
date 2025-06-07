import { describe, expect, test, beforeEach } from "bun:test"
import { createBotHandler } from "../../realtime/handlers/createBot"
import { setupTestLifecycle, testUtils } from "../setup"
import type { HandlerContext } from "../../realtime/types"
import type { CreateBotInput } from "@in/protocol/core"

describe("createBotHandler", () => {
  setupTestLifecycle()

  let testUser: any
  let handlerContext: HandlerContext

  beforeEach(async () => {
    // Create a test user to use as the bot creator
    testUser = await testUtils.createUser("creator@example.com")

    handlerContext = {
      userId: testUser.id,
      sessionId: 456,
      connectionId: "test-connection",
      sendRaw: () => {}, // Mock function
      sendRpcReply: () => {}, // Mock function
    }
  })

  test("should handle valid createBot RPC call", async () => {
    const input: CreateBotInput = {
      name: "Test RPC Bot",
      username: "rpcbot",
    }

    const result = await createBotHandler(input, handlerContext)

    expect(result.bot).toBeDefined()
    expect(result.bot?.firstName).toBe("Test RPC Bot")
    expect(result.bot?.username).toBe("rpcbot")
    expect(result.bot?.bot).toBe(true)
    expect(result.token).toBeDefined()
    expect(typeof result.token).toBe("string")
    expect(result.token.length).toBeGreaterThan(0)
  })

  test("should handle createBot with space invitation", async () => {
    // Create a test space first
    const space = await testUtils.createSpace("Test RPC Space")

    if (!space) {
      throw new Error("Failed to create test space")
    }

    const input: CreateBotInput = {
      name: "Space RPC Bot",
      username: "spacerpcbot",
      addToSpace: BigInt(space.id),
    }

    const result = await createBotHandler(input, handlerContext)

    expect(result.bot).toBeDefined()
    expect(result.bot?.firstName).toBe("Space RPC Bot")
    expect(result.bot?.username).toBe("spacerpcbot")
    expect(result.bot?.bot).toBe(true)
    expect(result.token).toBeDefined()
    expect(typeof result.token).toBe("string")
  })
})
