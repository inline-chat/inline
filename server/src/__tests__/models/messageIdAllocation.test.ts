import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { and, asc, eq } from "drizzle-orm"
import { ChatModel } from "@in/server/db/models/chats"
import { MessageModel } from "@in/server/db/models/messages"
import { db } from "@in/server/db"
import { chats, messages } from "@in/server/db/schema"
import { setupTestDatabase, teardownTestDatabase, testUtils } from "../setup"

describe("message id allocation", () => {
  beforeAll(setupTestDatabase)
  afterAll(teardownTestDatabase)

  test("does not reuse deleted tail ids, including concurrent sends", async () => {
    const user = await testUtils.createUser("message-id-allocation@example.com")
    const chat = await testUtils.createTestChat()

    for (let index = 0; index < 5; index += 1) {
      const result = await MessageModel.insertMessage({
        chatId: chat.id,
        fromId: user.id,
        date: new Date(Date.now() + index),
      })
      expect(result.message.messageId).toBe(index + 1)
    }

    await MessageModel.deleteMessages([3n, 4n, 5n], chat.id)

    const afterDelete = await db
      .select({ lastMsgId: chats.lastMsgId, messageIdCounter: chats.messageIdCounter })
      .from(chats)
      .where(eq(chats.id, chat.id))
      .limit(1)
    expect(afterDelete[0]).toEqual({ lastMsgId: 2, messageIdCounter: 5 })

    const inserted = await Promise.all(
      [0, 1, 2].map((index) =>
        MessageModel.insertMessage({
          chatId: chat.id,
          fromId: user.id,
          date: new Date(Date.now() + index),
        }),
      ),
    )

    expect(inserted.map(({ message }) => message.messageId).sort((a, b) => a - b)).toEqual([6, 7, 8])

    const persisted = await db
      .select({ messageId: messages.messageId })
      .from(messages)
      .where(and(eq(messages.chatId, chat.id), eq(messages.fromId, user.id)))
      .orderBy(asc(messages.messageId))
    expect(persisted.map(({ messageId }) => messageId)).toEqual([1, 2, 6, 7, 8])

    const currentChat = (await db.select().from(chats).where(eq(chats.id, chat.id)).limit(1))[0]
    expect(currentChat?.lastMsgId).toBe(8)
    expect(currentChat?.messageIdCounter).toBe(8)
    expect(ChatModel.nextMessageId(currentChat!)).toBe(9)
  })

  test("database fence preserves the counter for rolling old-server writes", async () => {
    const owner = await testUtils.createUser("message-id-fence-owner@example.com")
    const chat = await testUtils.createChat(null, "Message ID fence", "thread", false, owner.id)
    if (!chat) throw new Error("Expected chat fixture")

    // Mirror the legacy writer's ordering: insert the message first, then move
    // only last_msg_id. Keep message 2 around for the legacy tail-delete step.
    await db.insert(messages).values([
      { chatId: chat.id, fromId: owner.id, messageId: 2 },
      { chatId: chat.id, fromId: owner.id, messageId: 6 },
    ])

    await db
      .update(chats)
      .set({ lastMsgId: 6 })
      .where(eq(chats.id, chat.id))

    const afterLegacySend = await db.query.chats.findFirst({ where: { id: chat.id } })
    expect(afterLegacySend?.messageIdCounter).toBe(6)

    await db
      .update(chats)
      .set({ lastMsgId: 2 })
      .where(eq(chats.id, chat.id))

    const afterLegacyTailDelete = await db.query.chats.findFirst({ where: { id: chat.id } })
    expect(afterLegacyTailDelete?.lastMsgId).toBe(2)
    expect(afterLegacyTailDelete?.messageIdCounter).toBe(6)
  })
})
