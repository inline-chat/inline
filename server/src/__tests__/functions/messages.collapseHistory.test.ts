import { describe, expect, test } from "bun:test"
import { and, asc, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { chats, dialogs, messages, updates, UpdateBucket } from "@in/server/db/schema"
import { MessageModel } from "@in/server/db/models/messages"
import { collapseHistory } from "@in/server/functions/messages.collapseHistory"
import { setupTestLifecycle, testUtils } from "../setup"

describe("messages.collapseHistory", () => {
  setupTestLifecycle()

  test("collapses through the locked high-water mark and advances read state atomically", async () => {
    const userA = await testUtils.createUser("collapse-a@example.com")
    const userB = await testUtils.createUser("collapse-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
    })

    await db.insert(messages).values([
      { chatId: chat.id, messageId: 1, fromId: userB.id, text: "one" },
      { chatId: chat.id, messageId: 2, fromId: userB.id, text: "two" },
      { chatId: chat.id, messageId: 3, fromId: userB.id, text: "three" },
    ])
    await db.update(chats).set({ lastMsgId: 3, messageIdHighWater: 3 }).where(eq(chats.id, chat.id))
    await db
      .update(dialogs)
      .set({ readInboxMaxId: 1, unreadMark: true })
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))

    const result = await collapseHistory(
      {
        peerId: { type: { oneofKind: "user", user: { userId: BigInt(userB.id) } } },
        maxId: 2,
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )

    expect(result.updates.map((update) => update.update.oneofKind)).toEqual([
      "collapseHistory",
      "updateReadMaxId",
    ])
    const collapseUpdate = result.updates[0]
    expect(collapseUpdate?.update.oneofKind).toBe("collapseHistory")
    if (collapseUpdate?.update.oneofKind === "collapseHistory") {
      expect(collapseUpdate.update.collapseHistory.collapsedAt).toBeDefined()
    }
    const readUpdate = result.updates[1]
    expect(readUpdate?.update.oneofKind).toBe("updateReadMaxId")
    if (readUpdate?.update.oneofKind === "updateReadMaxId") {
      expect(readUpdate.update.updateReadMaxId.unreadCount).toBe(0)
    }

    const dialog = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .then((rows) => rows[0])
    expect(dialog?.collapsedMaxId).toBe(3)
    expect(dialog?.collapsedAt).toBeInstanceOf(Date)
    expect(dialog?.readInboxMaxId).toBe(3)
    expect(dialog?.unreadMark).toBe(false)

    const bucketRows = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, userA.id)))
      .orderBy(asc(updates.seq))
    expect(bucketRows).toHaveLength(2)
  })

  test("does not move the boundary backward, refreshes its generation, and nil removes it", async () => {
    const userA = await testUtils.createUser("collapse-monotonic-a@example.com")
    const userB = await testUtils.createUser("collapse-monotonic-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
    })
    await db.update(chats).set({ messageIdHighWater: 5 }).where(eq(chats.id, chat.id))

    const context = testUtils.functionContext({ userId: userA.id, sessionId: 22 })
    const peerId = { type: { oneofKind: "user" as const, user: { userId: BigInt(userB.id) } } }

    await collapseHistory({ peerId, maxId: 5 }, context)
    const firstDialog = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .then((rows) => rows[0])
    expect(firstDialog?.collapsedAt).toBeInstanceOf(Date)

    const repeated = await collapseHistory({ peerId, maxId: 3 }, context)
    expect(repeated.updates.map((update) => update.update.oneofKind)).toEqual(["collapseHistory"])

    let dialog = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .then((rows) => rows[0])
    expect(dialog?.collapsedMaxId).toBe(5)
    expect(dialog?.collapsedAt?.getTime()).toBeGreaterThan(firstDialog?.collapsedAt?.getTime() ?? 0)

    const cleared = await collapseHistory({ peerId, maxId: undefined }, context)
    expect(cleared.updates.map((update) => update.update.oneofKind)).toEqual(["collapseHistory"])

    dialog = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .then((rows) => rows[0])
    expect(dialog?.collapsedMaxId).toBeNull()
    expect(dialog?.collapsedAt).toBeNull()
  })

  test("rejects boundaries beyond the chat message ID high-water mark", async () => {
    const userA = await testUtils.createUser("collapse-invalid-a@example.com")
    const userB = await testUtils.createUser("collapse-invalid-b@example.com")
    await testUtils.createPrivateChatWithOptionalDialog({ userA, userB, createDialogForUserA: true })

    await expect(
      collapseHistory(
        {
          peerId: { type: { oneofKind: "user", user: { userId: BigInt(userB.id) } } },
          maxId: 1,
        },
        testUtils.functionContext({ userId: userA.id, sessionId: 33 }),
      ),
    ).rejects.toThrow("Message ID is invalid")
  })

  test("keeps allocating above the high-water mark after visible history is deleted", async () => {
    const userA = await testUtils.createUser("collapse-high-water-a@example.com")
    const userB = await testUtils.createUser("collapse-high-water-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
    })

    await db.insert(messages).values([
      { chatId: chat.id, messageId: 1, fromId: userA.id, text: "one" },
      { chatId: chat.id, messageId: 2, fromId: userA.id, text: "two" },
    ])
    await db.update(chats).set({ lastMsgId: 2, messageIdHighWater: 2 }).where(eq(chats.id, chat.id))

    await db.update(chats).set({ lastMsgId: null }).where(eq(chats.id, chat.id))
    await db.delete(messages).where(eq(messages.chatId, chat.id))

    const inserted = await MessageModel.insertMessage({
      chatId: chat.id,
      fromId: userA.id,
      text: "after deletion",
    })

    expect(inserted.message.messageId).toBe(3)
    const updatedChat = await db.select().from(chats).where(eq(chats.id, chat.id)).then((rows) => rows[0])
    expect(updatedChat?.lastMsgId).toBe(3)
    expect(updatedChat?.messageIdHighWater).toBe(3)
  })
})
