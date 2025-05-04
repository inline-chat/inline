import { describe, expect, test } from "bun:test"
import { createChat as handler } from "../../realtime/handlers/messages.createChat"
import { createChat } from "../../functions/messages.createChat"
import { CreateChatInput } from "@in/protocol/core"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { testUtils, defaultTestContext, setupTestLifecycle } from "../setup"
import type { FunctionContext } from "../../functions/_types"

describe("messages.createChat", () => {
  // Setup test lifecycle
  setupTestLifecycle()

  const mockHandlerContext = {
    userId: defaultTestContext.userId,
    sessionId: defaultTestContext.sessionId,
    connectionId: defaultTestContext.connectionId,
    sendRaw: () => {},
    sendRpcReply: () => {},
  }

  const mockFunctionContext: FunctionContext = {
    currentSessionId: defaultTestContext.sessionId,
    currentUserId: defaultTestContext.userId,
  }

  test("should create public chat without participants", async () => {
    // Create a space first
    const space = await testUtils.createSpace()
    if (!space) throw new Error("Failed to create space")

    // Create a user for the test
    const user = await testUtils.createUser()
    if (!user) throw new Error("Failed to create user")

    const input: CreateChatInput = {
      title: "Public Chat",
      spaceId: BigInt(space.id),
      isPublic: true,
      participants: [],
    }

    // Test handler
    const handlerResult = await handler(input, {
      ...mockHandlerContext,
      userId: user.id,
    })

    expect(handlerResult.chat?.isPublic).toBe(true)
    expect(handlerResult.chat?.title).toBe("Public Chat")

    // Test function directly
    const functionResult = await createChat(
      {
        title: "Public Chat",
        spaceId: BigInt(space.id),
        isPublic: true,
      },
      {
        ...mockFunctionContext,
        currentUserId: user.id,
      },
    )

    expect(functionResult.chat.isPublic).toBe(true)
    expect(functionResult.chat.title).toBe("Public Chat")
  })

  test("should create private chat with participants", async () => {
    // Create a space first
    const space = await testUtils.createSpace()
    if (!space) throw new Error("Failed to create space")

    // Create users for the test
    const currentUser = await testUtils.createUser("current@example.com")
    if (!currentUser) throw new Error("Failed to create current user")

    const otherUser = await testUtils.createUser("other@example.com")
    if (!otherUser) throw new Error("Failed to create other user")

    const input: CreateChatInput = {
      title: "Private Chat",
      spaceId: BigInt(space.id),
      participants: [{ userId: BigInt(otherUser.id) }],
      isPublic: false,
    }

    // Test handler
    const handlerResult = await handler(input, {
      ...mockHandlerContext,
      userId: currentUser.id,
    })

    expect(handlerResult.chat?.isPublic).toBe(false)
    expect(handlerResult.chat?.title).toBe("Private Chat")

    // Test function directly
    const functionResult = await createChat(
      {
        title: "Private Chat",
        spaceId: BigInt(space.id),
        isPublic: false,
        participants: [{ userId: BigInt(otherUser.id) }],
      },
      {
        ...mockFunctionContext,
        currentUserId: currentUser.id,
      },
    )

    expect(functionResult.chat.isPublic).toBe(false)
    expect(functionResult.chat.title).toBe("Private Chat")
  })
})
