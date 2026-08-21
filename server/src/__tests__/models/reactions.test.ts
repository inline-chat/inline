import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { ReactionModel } from "@in/server/db/models/reactions"
import { UpdateBucket, updates } from "@in/server/db/schema"
import { setupTestLifecycle, testUtils } from "../setup"

describe("ReactionModel", () => {
  setupTestLifecycle()

  test("concurrently adding the same reaction inserts one row", async () => {
    const user = await testUtils.createUser("reaction-user@example.com")
    const chat = await testUtils.createTestChat()
    const message = await testUtils.createTestMessage({
      messageId: 1,
      fromId: user.id,
      chatId: chat.id,
      text: "reaction target",
    })
    const reaction = {
      messageId: message.messageId,
      chatId: chat.id,
      userId: user.id,
      emoji: "👍",
      date: new Date(),
    }

    const inserted = await Promise.all([
      ReactionModel.insertReaction(reaction),
      ReactionModel.insertReaction(reaction),
    ])

    expect(inserted.filter(Boolean)).toHaveLength(1)
    await expect(
      ReactionModel.getReactions(BigInt(message.messageId), BigInt(chat.id)),
    ).resolves.toHaveLength(1)
  })

  test("deleting an absent reaction is a convergent no-op", async () => {
    const user = await testUtils.createUser("reaction-delete-user@example.com")
    const chat = await testUtils.createTestChat()
    const message = await testUtils.createTestMessage({
      messageId: 1,
      fromId: user.id,
      chatId: chat.id,
      text: "reaction delete target",
    })

    await expect(
      ReactionModel.deleteReaction(BigInt(message.messageId), chat.id, "👋", user.id),
    ).resolves.toEqual([])

    await ReactionModel.insertReaction({
      messageId: message.messageId,
      chatId: chat.id,
      userId: user.id,
      emoji: "👋",
      date: new Date(),
    })
    await expect(
      ReactionModel.deleteReaction(BigInt(message.messageId), chat.id, "👋", user.id),
    ).resolves.toHaveLength(1)
    await expect(
      ReactionModel.deleteReaction(BigInt(message.messageId), chat.id, "👋", user.id),
    ).resolves.toEqual([])
  })

  test("adding and deleting a reaction never creates durable chat updates", async () => {
    const user = await testUtils.createUser("reaction-ephemeral-user@example.com")
    const chat = await testUtils.createTestChat()
    const message = await testUtils.createTestMessage({
      messageId: 1,
      fromId: user.id,
      chatId: chat.id,
      text: "ephemeral reaction target",
    })
    const input = {
      messageId: message.messageId,
      chatId: chat.id,
      userId: user.id,
      emoji: "✅",
      date: new Date(),
    }

    await ReactionModel.insertReaction(input)
    await ReactionModel.deleteReaction(BigInt(message.messageId), chat.id, input.emoji, user.id)
    const chatUpdates = await db
      .select({ seq: updates.seq })
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, chat.id)))

    expect(chatUpdates).toEqual([])
  })
})
