import { describe, expect, test } from "bun:test"
import { getChatHistory } from "../../functions/messages.getChatHistory"
import { testUtils, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { eq, and } from "drizzle-orm"

const makeFunctionContext = (userId: number): any => ({
  currentUserId: userId,
  currentSessionId: 1,
})

describe("getChatHistory", () => {
  setupTestLifecycle()

  test("returns messages when chat exists between users", async () => {
    const userA = (await testUtils.createUser("userA@example.com"))!
    const userB = (await testUtils.createUser("userB@example.com"))!

    const chat = (await testUtils.createPrivateChat(userA, userB))!

    await db
      .insert(schema.dialogs)
      .values([
        { chatId: chat.id, userId: userA.id, peerUserId: userB.id },
        { chatId: chat.id, userId: userB.id, peerUserId: userA.id },
      ])
      .execute()

    const message = await testUtils.createTestMessage({
      messageId: 1,
      chatId: chat.id,
      fromId: userA.id,
      text: "Hello from userA",
    })

    await db.update(schema.chats).set({ lastMsgId: message.messageId }).where(eq(schema.chats.id, chat.id)).execute()

    const input = {
      peerId: {
        type: {
          oneofKind: "user" as const,
          user: { userId: BigInt(userB.id) },
        },
      },
    }
    const context = makeFunctionContext(userA.id)

    const result = await getChatHistory(input, context)

    expect(result.messages.length).toBe(1)
    expect(result.messages[0]?.id).toBe(BigInt(message.messageId))
  })

  test("auto-creates chat and dialogs when chat doesn't exist for valid user", async () => {
    const userA = (await testUtils.createUser("userA2@example.com"))!
    const userB = (await testUtils.createUser("userB2@example.com"))!

    const chatsBefore = await db._query.chats.findMany({
      where: and(
        eq(schema.chats.type, "private"),
        eq(schema.chats.minUserId, Math.min(userA.id, userB.id)),
        eq(schema.chats.maxUserId, Math.max(userA.id, userB.id)),
      ),
    })
    expect(chatsBefore.length).toBe(0)

    const input = {
      peerId: {
        type: {
          oneofKind: "user" as const,
          user: { userId: BigInt(userB.id) },
        },
      },
    }
    const context = makeFunctionContext(userA.id)

    const result = await getChatHistory(input, context)

    expect(result.messages.length).toBe(0)

    const chatsAfter = await db._query.chats.findMany({
      where: and(
        eq(schema.chats.type, "private"),
        eq(schema.chats.minUserId, Math.min(userA.id, userB.id)),
        eq(schema.chats.maxUserId, Math.max(userA.id, userB.id)),
      ),
    })
    expect(chatsAfter.length).toBe(1)

    const dialogsUserA = await db._query.dialogs.findMany({
      where: and(eq(schema.dialogs.userId, userA.id), eq(schema.dialogs.peerUserId, userB.id)),
    })
    expect(dialogsUserA.length).toBe(1)

    const dialogsUserB = await db._query.dialogs.findMany({
      where: and(eq(schema.dialogs.userId, userB.id), eq(schema.dialogs.peerUserId, userA.id)),
    })
    expect(dialogsUserB.length).toBe(1)
  })

  test("throws error when trying to get chat history for non-existent user", async () => {
    const userA = (await testUtils.createUser("userA3@example.com"))!
    const invalidUserId = 999999

    const input = {
      peerId: {
        type: {
          oneofKind: "user" as const,
          user: { userId: BigInt(invalidUserId) },
        },
      },
    }
    const context = makeFunctionContext(userA.id)

    await expect(getChatHistory(input, context)).rejects.toThrow()
  })

  test("throws error when userId is invalid (zero or negative)", async () => {
    const userA = (await testUtils.createUser("userA4@example.com"))!

    const input = {
      peerId: {
        type: {
          oneofKind: "user" as const,
          user: { userId: BigInt(0) },
        },
      },
    }
    const context = makeFunctionContext(userA.id)

    await expect(getChatHistory(input, context)).rejects.toThrow()
  })

  test("returns empty messages for newly created chat", async () => {
    const userA = (await testUtils.createUser("userA5@example.com"))!
    const userB = (await testUtils.createUser("userB5@example.com"))!

    const input = {
      peerId: {
        type: {
          oneofKind: "user" as const,
          user: { userId: BigInt(userB.id) },
        },
      },
    }
    const context = makeFunctionContext(userA.id)

    const result = await getChatHistory(input, context)

    expect(result.messages).toEqual([])
  })

  test("does not create duplicate chats if chat already exists", async () => {
    const userA = (await testUtils.createUser("userA6@example.com"))!
    const userB = (await testUtils.createUser("userB6@example.com"))!

    const chat = (await testUtils.createPrivateChat(userA, userB))!
    await db
      .insert(schema.dialogs)
      .values([
        { chatId: chat.id, userId: userA.id, peerUserId: userB.id },
        { chatId: chat.id, userId: userB.id, peerUserId: userA.id },
      ])
      .execute()

    const input = {
      peerId: {
        type: {
          oneofKind: "user" as const,
          user: { userId: BigInt(userB.id) },
        },
      },
    }
    const context = makeFunctionContext(userA.id)

    await getChatHistory(input, context)

    const chatsAfter = await db._query.chats.findMany({
      where: and(
        eq(schema.chats.type, "private"),
        eq(schema.chats.minUserId, Math.min(userA.id, userB.id)),
        eq(schema.chats.maxUserId, Math.max(userA.id, userB.id)),
      ),
    })
    expect(chatsAfter.length).toBe(1)
  })
})
