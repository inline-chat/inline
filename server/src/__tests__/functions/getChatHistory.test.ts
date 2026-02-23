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

  test("supports offset pagination for batched history loading", async () => {
    const userA = (await testUtils.createUser("userA7@example.com"))!
    const userB = (await testUtils.createUser("userB7@example.com"))!

    const chat = (await testUtils.createPrivateChat(userA, userB))!
    await db
      .insert(schema.dialogs)
      .values([
        { chatId: chat.id, userId: userA.id, peerUserId: userB.id },
        { chatId: chat.id, userId: userB.id, peerUserId: userA.id },
      ])
      .execute()

    for (let messageId = 1; messageId <= 130; messageId += 1) {
      await testUtils.createTestMessage({
        messageId,
        chatId: chat.id,
        fromId: userA.id,
        text: `Message ${messageId}`,
      })
    }

    await db.update(schema.chats).set({ lastMsgId: 130 }).where(eq(schema.chats.id, chat.id)).execute()

    const peerId = {
      type: {
        oneofKind: "user" as const,
        user: { userId: BigInt(userB.id) },
      },
    }
    const context = makeFunctionContext(userA.id)

    const firstBatch = await getChatHistory(
      {
        peerId,
        limit: 50,
      },
      context,
    )
    expect(firstBatch.messages).toHaveLength(50)
    expect(firstBatch.messages[0]?.id).toBe(130n)
    expect(firstBatch.messages[49]?.id).toBe(81n)

    const secondBatch = await getChatHistory(
      {
        peerId,
        offsetId: firstBatch.messages[firstBatch.messages.length - 1]?.id,
        limit: 50,
      },
      context,
    )
    expect(secondBatch.messages).toHaveLength(50)
    expect(secondBatch.messages[0]?.id).toBe(80n)
    expect(secondBatch.messages[49]?.id).toBe(31n)

    const thirdBatch = await getChatHistory(
      {
        peerId,
        offsetId: secondBatch.messages[secondBatch.messages.length - 1]?.id,
        limit: 50,
      },
      context,
    )
    expect(thirdBatch.messages).toHaveLength(30)
    expect(thirdBatch.messages[0]?.id).toBe(30n)
    expect(thirdBatch.messages[29]?.id).toBe(1n)
  })

  test("supports explicit newer mode with after_id cursor", async () => {
    const userA = (await testUtils.createUser("userA8@example.com"))!
    const userB = (await testUtils.createUser("userB8@example.com"))!

    const chat = (await testUtils.createPrivateChat(userA, userB))!
    await db
      .insert(schema.dialogs)
      .values([
        { chatId: chat.id, userId: userA.id, peerUserId: userB.id },
        { chatId: chat.id, userId: userB.id, peerUserId: userA.id },
      ])
      .execute()

    for (let messageId = 1; messageId <= 8; messageId += 1) {
      await testUtils.createTestMessage({
        messageId,
        chatId: chat.id,
        fromId: userA.id,
        text: `Message ${messageId}`,
      })
    }

    await db.update(schema.chats).set({ lastMsgId: 8 }).where(eq(schema.chats.id, chat.id)).execute()

    const peerId = {
      type: {
        oneofKind: "user" as const,
        user: { userId: BigInt(userB.id) },
      },
    }
    const context = makeFunctionContext(userA.id)

    const result = await getChatHistory(
      {
        peerId,
        mode: "newer",
        afterId: 4n,
        limit: 3,
      },
      context,
    )

    expect(result.messages.map((message) => message.id)).toEqual([7n, 6n, 5n])
  })

  test("supports around mode with anchor inclusion", async () => {
    const userA = (await testUtils.createUser("userA9@example.com"))!
    const userB = (await testUtils.createUser("userB9@example.com"))!

    const chat = (await testUtils.createPrivateChat(userA, userB))!
    await db
      .insert(schema.dialogs)
      .values([
        { chatId: chat.id, userId: userA.id, peerUserId: userB.id },
        { chatId: chat.id, userId: userB.id, peerUserId: userA.id },
      ])
      .execute()

    for (let messageId = 1; messageId <= 12; messageId += 1) {
      await testUtils.createTestMessage({
        messageId,
        chatId: chat.id,
        fromId: userA.id,
        text: `Message ${messageId}`,
      })
    }

    await db.update(schema.chats).set({ lastMsgId: 12 }).where(eq(schema.chats.id, chat.id)).execute()

    const peerId = {
      type: {
        oneofKind: "user" as const,
        user: { userId: BigInt(userB.id) },
      },
    }
    const context = makeFunctionContext(userA.id)

    const aroundWithAnchor = await getChatHistory(
      {
        peerId,
        mode: "around",
        anchorId: 7n,
        beforeLimit: 2,
        afterLimit: 3,
        includeAnchor: true,
      },
      context,
    )

    expect(aroundWithAnchor.messages.map((message) => message.id)).toEqual([10n, 9n, 8n, 7n, 6n, 5n])

    const aroundWithoutAnchor = await getChatHistory(
      {
        peerId,
        mode: "around",
        anchorId: 7n,
        beforeLimit: 2,
        afterLimit: 3,
        includeAnchor: false,
      },
      context,
    )

    expect(aroundWithoutAnchor.messages.map((message) => message.id)).toEqual([10n, 9n, 8n, 6n, 5n])
  })

  test("rejects invalid explicit mode combinations", async () => {
    const userA = (await testUtils.createUser("userA10@example.com"))!
    const userB = (await testUtils.createUser("userB10@example.com"))!

    const chat = (await testUtils.createPrivateChat(userA, userB))!
    await db
      .insert(schema.dialogs)
      .values([
        { chatId: chat.id, userId: userA.id, peerUserId: userB.id },
        { chatId: chat.id, userId: userB.id, peerUserId: userA.id },
      ])
      .execute()

    const peerId = {
      type: {
        oneofKind: "user" as const,
        user: { userId: BigInt(userB.id) },
      },
    }
    const context = makeFunctionContext(userA.id)

    await expect(
      getChatHistory(
        {
          peerId,
          mode: "newer",
          limit: 10,
        },
        context,
      ),
    ).rejects.toThrow()

    await expect(
      getChatHistory(
        {
          peerId,
          mode: "around",
          limit: 10,
        },
        context,
      ),
    ).rejects.toThrow()
  })
})
