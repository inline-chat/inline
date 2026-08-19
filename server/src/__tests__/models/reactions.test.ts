import { describe, expect, test } from "bun:test"
import { and, asc, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { ReactionModel } from "@in/server/db/models/reactions"
import { UpdatesModel } from "@in/server/db/models/updates"
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

  test("replays concurrent delete/add in chat sequence order", async () => {
    const user = await testUtils.createUser("reaction-order-user@example.com")
    const chat = await testUtils.createTestChat()
    const message = await testUtils.createTestMessage({
      messageId: 1,
      fromId: user.id,
      chatId: chat.id,
      text: "reaction ordering target",
    })
    const input = {
      messageId: message.messageId,
      chatId: chat.id,
      userId: user.id,
      emoji: "✅",
      date: new Date(),
    }

    await ReactionModel.insertReactionWithUpdate(input)

    const [deleted, added] = await Promise.all([
      ReactionModel.deleteReactionWithUpdate(BigInt(message.messageId), chat.id, input.emoji, user.id),
      ReactionModel.insertReactionWithUpdate(input),
    ])

    const stored = await ReactionModel.getReactions(BigInt(message.messageId), BigInt(chat.id))
    const chatUpdates = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, chat.id)))
      .orderBy(asc(updates.seq))

    const replayed = new Set<string>()
    for (const row of chatUpdates) {
      const payload = UpdatesModel.decrypt(row).payload.update
      if (payload.oneofKind === "reaction") {
        const reaction = payload.reaction.reaction
        if (reaction) replayed.add(`${reaction.userId}:${reaction.messageId}:${reaction.emoji}`)
      } else if (payload.oneofKind === "reactionDeleted") {
        replayed.delete(`${payload.reactionDeleted.userId}:${payload.reactionDeleted.messageId}:${payload.reactionDeleted.emoji}`)
      }
    }

    expect(chatUpdates.map((row) => row.seq)).toEqual(chatUpdates.map((_, index) => index + 1))
    expect(replayed).toEqual(
      new Set(stored.map((reaction) => `${reaction.userId}:${reaction.messageId}:${reaction.emoji}`)),
    )
    expect(Boolean(deleted) || Boolean(added)).toBe(true)
  })
})
