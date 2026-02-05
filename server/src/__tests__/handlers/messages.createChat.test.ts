import { describe, expect, test } from "bun:test"
import { createChat as handler } from "../../realtime/handlers/messages.createChat"
import { createChat } from "../../functions/messages.createChat"
import { CreateChatInput } from "@in/protocol/core"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { testUtils, defaultTestContext, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { eq } from "drizzle-orm"
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
        title: "Public Chat 2",
        spaceId: BigInt(space.id),
        isPublic: true,
      },
      {
        ...mockFunctionContext,
        currentUserId: user.id,
      },
    )

    expect(functionResult.chat.isPublic).toBe(true)
    expect(functionResult.chat.title).toBe("Public Chat 2")
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
        title: "Private Chat 2",
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
    expect(functionResult.chat.title).toBe("Private Chat 2")
  })

  test("should create home thread with participants and creator", async () => {
    const currentUser = await testUtils.createUser("home-owner@example.com")
    if (!currentUser) throw new Error("Failed to create current user")
    const otherUser = await testUtils.createUser("home-participant@example.com")
    if (!otherUser) throw new Error("Failed to create other user")

    const input: CreateChatInput = {
      title: "Home Thread",
      isPublic: false,
      participants: [{ userId: BigInt(otherUser.id) }],
    }

    const handlerResult = await handler(input, {
      ...mockHandlerContext,
      userId: currentUser.id,
    })

    expect(handlerResult.chat?.isPublic).toBe(false)
    expect(handlerResult.chat?.spaceId).toBeUndefined()

    const [createdChat] = await db
      .select()
      .from(schema.chats)
      .where(eq(schema.chats.id, Number(handlerResult.chat?.id)))

    expect(createdChat?.spaceId).toBeNull()
    expect(createdChat?.createdBy).toBe(currentUser.id)
    expect(createdChat?.publicThread).toBe(false)

    const participants = await db
      .select()
      .from(schema.chatParticipants)
      .where(eq(schema.chatParticipants.chatId, createdChat!.id))

    const participantIds = participants.map((p) => p.userId).sort()
    expect(participantIds).toEqual([currentUser.id, otherUser.id].sort())
  })

  test("rejects public home thread creation", async () => {
    const currentUser = await testUtils.createUser("home-public-owner@example.com")
    if (!currentUser) throw new Error("Failed to create current user")

    await expect(
      createChat(
        {
          title: "Home Public Thread",
          isPublic: true,
        },
        {
          ...mockFunctionContext,
          currentUserId: currentUser.id,
        },
      ),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
  })

  test("rejects home thread creation without participants", async () => {
    const currentUser = await testUtils.createUser("home-empty-owner@example.com")
    if (!currentUser) throw new Error("Failed to create current user")

    await expect(
      createChat(
        {
          title: "Home Thread Missing Participants",
          isPublic: false,
        },
        {
          ...mockFunctionContext,
          currentUserId: currentUser.id,
        },
      ),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
  })

  test("rejects duplicate thread names in the same space (case-insensitive)", async () => {
    const space = await testUtils.createSpace()
    if (!space) throw new Error("Failed to create space")

    const user = await testUtils.createUser("dup-space-owner@example.com")
    if (!user) throw new Error("Failed to create user")

    await createChat(
      {
        title: "Design",
        spaceId: BigInt(space.id),
        isPublic: true,
      },
      {
        ...mockFunctionContext,
        currentUserId: user.id,
      },
    )

    await expect(
      createChat(
        {
          title: "design",
          spaceId: BigInt(space.id),
          isPublic: true,
        },
        {
          ...mockFunctionContext,
          currentUserId: user.id,
        },
      ),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
  })
})
