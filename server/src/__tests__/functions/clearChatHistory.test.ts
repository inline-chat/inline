import { describe, expect, test } from "bun:test"
import { and, eq, inArray } from "drizzle-orm"
import { clearChatHistory } from "@in/server/functions/messages.clearChatHistory"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { clearChatHistoryHandler } from "@in/server/realtime/handlers/messages.clearChatHistory"
import type { HandlerContext } from "@in/server/realtime/types"
import type { ClearChatHistoryInput } from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "../setup"

const inputPeerForChat = (chatId: number) => ({
  type: {
    oneofKind: "chat" as const,
    chat: { chatId: BigInt(chatId) },
  },
})

const inputPeerForUser = (userId: number) => ({
  type: {
    oneofKind: "user" as const,
    user: { userId: BigInt(userId) },
  },
})

const addSpaceMembers = async (
  spaceId: number,
  rows: { userId: number; role?: "owner" | "admin" | "member"; canAccessPublicChats?: boolean }[],
) => {
  await db.insert(schema.members).values(
    rows.map((row) => ({
      spaceId,
      userId: row.userId,
      role: row.role ?? "member",
      canAccessPublicChats: row.canAccessPublicChats ?? true,
    })),
  )
}

const insertMessage = async (input: {
  chatId: number
  messageId: number
  fromId: number
  text?: string
  date?: Date
}) => {
  const [message] = await db
    .insert(schema.messages)
    .values({
      chatId: input.chatId,
      messageId: input.messageId,
      fromId: input.fromId,
      text: input.text ?? `message ${input.messageId}`,
      date: input.date,
    })
    .returning()

  if (!message) {
    throw new Error("Failed to insert message")
  }

  return message
}

const setLastMsgId = async (chatId: number, messageId: number | null) => {
  await db.update(schema.chats).set({ lastMsgId: messageId }).where(eq(schema.chats.id, chatId))
}

const insertTranslation = async (input: { chatId: number; messageId: number; language?: string }) => {
  await db.insert(schema.translations).values({
    chatId: input.chatId,
    messageId: input.messageId,
    language: input.language ?? "en",
  })
}

const handlerContext = (userId = 1): HandlerContext => ({
  userId,
  sessionId: 1,
  connectionId: "test",
  sendRaw: () => {},
  sendRpcReply: () => {},
})

describe("messages.clearChatHistory", () => {
  setupTestLifecycle()

  test("handler rejects missing or empty targets", async () => {
    await expect(
      clearChatHistoryHandler(
        {
          keepLastDays: 0,
          deleteReplyThreads: false,
        } as unknown as ClearChatHistoryInput,
        handlerContext(),
      ),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })

    await expect(
      clearChatHistoryHandler(
        {
          target: { oneofKind: undefined },
          keepLastDays: 0,
          deleteReplyThreads: false,
        },
        handlerContext(),
      ),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
  })

  test("clears direct-message history for both users while keeping recent days", async () => {
    const userA = await testUtils.createUser("clear-dm-a@example.com")
    const userB = await testUtils.createUser("clear-dm-b@example.com")
    const chat = await testUtils.createPrivateChat(userA, userB)

    if (!chat) {
      throw new Error("Private chat not created")
    }

    const oldDate = new Date(Date.now() - 10 * 24 * 60 * 60 * 1000)
    const recentDate = new Date(Date.now() - 24 * 60 * 60 * 1000)

    await insertMessage({ chatId: chat.id, messageId: 1, fromId: userA.id, date: oldDate })
    await insertMessage({ chatId: chat.id, messageId: 2, fromId: userB.id, date: recentDate })
    await insertTranslation({ chatId: chat.id, messageId: 1, language: "en" })
    await insertTranslation({ chatId: chat.id, messageId: 2, language: "fr" })
    await setLastMsgId(chat.id, 2)

    const result = await clearChatHistory(
      {
        peer: inputPeerForUser(userB.id),
        keepLastDays: 7,
        deleteReplyThreads: false,
      },
      testUtils.functionContext({ userId: userA.id }),
    )

    expect(result.updates).toHaveLength(1)
    expect(result.updates[0]?.update.oneofKind).toBe("clearChatHistory")
    const clearUpdate = result.updates[0]?.update
    if (clearUpdate?.oneofKind === "clearChatHistory") {
      expect(clearUpdate.clearChatHistory.deletedChatIds).toEqual([])
      expect(clearUpdate.clearChatHistory.orphanedChatIds).toEqual([])
      expect(clearUpdate.clearChatHistory.detachedChatIds).toEqual([])
    }

    const remaining = await db
      .select({ messageId: schema.messages.messageId })
      .from(schema.messages)
      .where(eq(schema.messages.chatId, chat.id))
      .orderBy(schema.messages.messageId)

    expect(remaining.map((row) => row.messageId)).toEqual([2])

    const remainingTranslations = await db
      .select({ messageId: schema.translations.messageId })
      .from(schema.translations)
      .where(eq(schema.translations.chatId, chat.id))
      .orderBy(schema.translations.messageId)

    expect(remainingTranslations.map((row) => row.messageId)).toEqual([2])

    const [updatedChat] = await db.select().from(schema.chats).where(eq(schema.chats.id, chat.id)).limit(1)
    expect(updatedChat?.lastMsgId).toBe(2)

    const [updateRow] = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.Chat), eq(schema.updates.entityId, chat.id)))
      .limit(1)

    expect(updateRow).toBeTruthy()
    const update = UpdatesModel.decrypt(updateRow!)
    expect(update.payload.update.oneofKind).toBe("clearChatHistory")
    if (update.payload.update.oneofKind === "clearChatHistory") {
      expect(update.payload.update.clearChatHistory.beforeDate).toBeDefined()
      expect(update.payload.update.clearChatHistory.deleteReplyThreads).toBe(false)
    }
  })

  test("requires creator or space admin to clear thread history", async () => {
    const space = await testUtils.createSpace("clear-history-permissions")
    const creator = await testUtils.createUser("clear-permission-creator@example.com")
    const admin = await testUtils.createUser("clear-permission-admin@example.com")
    const member = await testUtils.createUser("clear-permission-member@example.com")

    if (!space) {
      throw new Error("Space not created")
    }

    await addSpaceMembers(space.id, [
      { userId: creator.id, role: "owner" },
      { userId: admin.id, role: "admin" },
      { userId: member.id },
    ])

    const chat = await testUtils.createChat(space.id, "Public Thread", "thread", true, creator.id)
    if (!chat) {
      throw new Error("Thread not created")
    }

    await insertMessage({ chatId: chat.id, messageId: 1, fromId: creator.id })
    await setLastMsgId(chat.id, 1)

    await expect(
      clearChatHistory(
        {
          peer: inputPeerForChat(chat.id),
          keepLastDays: 0,
          deleteReplyThreads: false,
        },
        testUtils.functionContext({ userId: member.id }),
      ),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.SPACE_ADMIN_REQUIRED })

    await clearChatHistory(
      {
        peer: inputPeerForChat(chat.id),
        keepLastDays: 0,
        deleteReplyThreads: false,
      },
      testUtils.functionContext({ userId: admin.id }),
    )

    const remaining = await db
      .select({ messageId: schema.messages.messageId })
      .from(schema.messages)
      .where(eq(schema.messages.chatId, chat.id))

    expect(remaining).toHaveLength(0)

    const privateThread = await testUtils.createChat(space.id, "Private Thread", "thread", false, creator.id)
    if (!privateThread) {
      throw new Error("Private thread not created")
    }

    await insertMessage({ chatId: privateThread.id, messageId: 1, fromId: creator.id })
    await setLastMsgId(privateThread.id, 1)

    await clearChatHistory(
      {
        peer: inputPeerForChat(privateThread.id),
        keepLastDays: 0,
        deleteReplyThreads: false,
      },
      testUtils.functionContext({ userId: admin.id }),
    )

    const privateRemaining = await db
      .select({ messageId: schema.messages.messageId })
      .from(schema.messages)
      .where(eq(schema.messages.chatId, privateThread.id))

    expect(privateRemaining).toHaveLength(0)
  })

  test("space admins can clear history across every chat in a space", async () => {
    const space = await testUtils.createSpace("clear-history-space-wide")
    const otherSpace = await testUtils.createSpace("clear-history-space-wide-other")
    const owner = await testUtils.createUser("clear-space-owner@example.com")
    const admin = await testUtils.createUser("clear-space-admin@example.com")
    const member = await testUtils.createUser("clear-space-member@example.com")

    if (!space || !otherSpace) {
      throw new Error("Space not created")
    }

    await addSpaceMembers(space.id, [
      { userId: owner.id, role: "owner" },
      { userId: admin.id, role: "admin" },
      { userId: member.id },
    ])
    await addSpaceMembers(otherSpace.id, [{ userId: owner.id, role: "owner" }])

    const publicThread = await testUtils.createChat(space.id, "Public Thread", "thread", true, owner.id)
    const privateThread = await testUtils.createChat(space.id, "Private Thread", "thread", false, owner.id)
    const untouchedThread = await testUtils.createChat(otherSpace.id, "Other Space Thread", "thread", true, owner.id)

    if (!publicThread || !privateThread || !untouchedThread) {
      throw new Error("Threads not created")
    }

    await testUtils.addParticipant(privateThread.id, owner.id)
    await testUtils.addParticipant(privateThread.id, admin.id)

    const oldDate = new Date(Date.now() - 10 * 24 * 60 * 60 * 1000)
    const recentDate = new Date(Date.now() - 24 * 60 * 60 * 1000)

    await insertMessage({ chatId: publicThread.id, messageId: 1, fromId: owner.id, date: oldDate })
    await insertMessage({ chatId: publicThread.id, messageId: 2, fromId: member.id, date: recentDate })
    await insertMessage({ chatId: privateThread.id, messageId: 1, fromId: owner.id, date: oldDate })
    await insertMessage({ chatId: untouchedThread.id, messageId: 1, fromId: owner.id, date: oldDate })
    await setLastMsgId(publicThread.id, 2)
    await setLastMsgId(privateThread.id, 1)
    await setLastMsgId(untouchedThread.id, 1)

    const [replyThread] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        spaceId: space.id,
        title: "Reply Thread",
        publicThread: true,
        createdBy: owner.id,
        parentChatId: publicThread.id,
        parentMessageId: 1,
      })
      .returning()

    if (!replyThread) {
      throw new Error("Reply thread not created")
    }

    await insertMessage({ chatId: replyThread.id, messageId: 1, fromId: admin.id, date: oldDate })
    await setLastMsgId(replyThread.id, 1)

    await expect(
      clearChatHistory(
        {
          spaceId: space.id,
          keepLastDays: 0,
          deleteReplyThreads: false,
        },
        testUtils.functionContext({ userId: member.id }),
      ),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.SPACE_ADMIN_REQUIRED })

    const result = await clearChatHistory(
      {
        spaceId: space.id,
        keepLastDays: 7,
        deleteReplyThreads: false,
      },
      testUtils.functionContext({ userId: admin.id }),
    )

    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["clearChatHistory", "newChat"])
    const resultUpdate = result.updates[0]?.update
    expect(resultUpdate?.oneofKind).toBe("clearChatHistory")
    if (resultUpdate?.oneofKind === "clearChatHistory") {
      expect(resultUpdate.clearChatHistory.target.oneofKind).toBe("spaceId")
      expect(resultUpdate.clearChatHistory.deletedChatIds).toEqual([])
      expect(resultUpdate.clearChatHistory.orphanedChatIds).toEqual([BigInt(replyThread.id)])
      expect(resultUpdate.clearChatHistory.detachedChatIds).toEqual([])
    }

    const messagesByChat = await db
      .select({ chatId: schema.messages.chatId, messageId: schema.messages.messageId })
      .from(schema.messages)
      .where(inArray(schema.messages.chatId, [publicThread.id, privateThread.id, replyThread.id, untouchedThread.id]))
      .orderBy(schema.messages.chatId, schema.messages.messageId)

    expect(messagesByChat).toEqual([
      { chatId: publicThread.id, messageId: 2 },
      { chatId: untouchedThread.id, messageId: 1 },
    ])

    const [orphanedReplyThread] = await db.select().from(schema.chats).where(eq(schema.chats.id, replyThread.id)).limit(1)
    expect(orphanedReplyThread?.parentChatId).toBe(publicThread.id)
    expect(orphanedReplyThread?.parentMessageId).toBeNull()

    const spaceUpdates = await db
      .select()
      .from(schema.updates)
      .where(
        and(
          eq(schema.updates.bucket, UpdateBucket.Space),
          eq(schema.updates.entityId, space.id),
        ),
      )

    expect(spaceUpdates).toHaveLength(1)
    const spaceUpdate = UpdatesModel.decrypt(spaceUpdates[0]!)
    expect(spaceUpdate.payload.update.oneofKind).toBe("spaceClearHistory")
    if (spaceUpdate.payload.update.oneofKind === "spaceClearHistory") {
      expect(spaceUpdate.payload.update.spaceClearHistory.deletedChatIds).toEqual([])
      expect(spaceUpdate.payload.update.spaceClearHistory.orphanedChatIds).toEqual([BigInt(replyThread.id)])
      expect(spaceUpdate.payload.update.spaceClearHistory.detachedChatIds).toEqual([])
    }

    const replyThreadUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.Chat), eq(schema.updates.entityId, replyThread.id)))

    expect(replyThreadUpdates).toHaveLength(1)
    const replyThreadUpdate = UpdatesModel.decrypt(replyThreadUpdates[0]!)
    expect(replyThreadUpdate.payload.update.oneofKind).toBe("newChat")
  })

  test("space clear publishes metadata updates for detached external reply threads", async () => {
    const targetSpace = await testUtils.createSpace("clear-history-target-space")
    const otherSpace = await testUtils.createSpace("clear-history-external-space")
    const owner = await testUtils.createUser("clear-external-owner@example.com")
    const admin = await testUtils.createUser("clear-external-admin@example.com")

    if (!targetSpace || !otherSpace) {
      throw new Error("Space not created")
    }

    await addSpaceMembers(targetSpace.id, [
      { userId: owner.id, role: "owner" },
      { userId: admin.id, role: "admin" },
    ])
    await addSpaceMembers(otherSpace.id, [{ userId: admin.id, role: "admin" }])

    const parent = await testUtils.createChat(targetSpace.id, "Target Parent", "thread", true, owner.id)
    if (!parent) {
      throw new Error("Parent thread not created")
    }

    await insertMessage({ chatId: parent.id, messageId: 1, fromId: owner.id })
    await setLastMsgId(parent.id, 1)

    const [externalReplyThread] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        spaceId: otherSpace.id,
        title: "External Reply Thread",
        publicThread: true,
        createdBy: admin.id,
        parentChatId: parent.id,
        parentMessageId: 1,
      })
      .returning()

    if (!externalReplyThread) {
      throw new Error("External reply thread not created")
    }

    await insertMessage({ chatId: externalReplyThread.id, messageId: 1, fromId: admin.id })
    await setLastMsgId(externalReplyThread.id, 1)

    const result = await clearChatHistory(
      {
        spaceId: targetSpace.id,
        keepLastDays: 0,
        deleteReplyThreads: true,
      },
      testUtils.functionContext({ userId: admin.id }),
    )

    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["clearChatHistory", "newChat"])
    const clearUpdate = result.updates[0]?.update
    if (clearUpdate?.oneofKind !== "clearChatHistory") {
      throw new Error("Expected clearChatHistory update")
    }
    expect(clearUpdate.clearChatHistory.deletedChatIds).toEqual([])
    expect(clearUpdate.clearChatHistory.orphanedChatIds).toEqual([])
    expect(clearUpdate.clearChatHistory.detachedChatIds).toEqual([BigInt(externalReplyThread.id)])

    const [retained] = await db
      .select()
      .from(schema.chats)
      .where(eq(schema.chats.id, externalReplyThread.id))
      .limit(1)
    expect(retained?.parentChatId).toBeNull()
    expect(retained?.parentMessageId).toBeNull()
    expect(retained?.updateSeq).toBe(1)
    expect(retained?.lastUpdateDate).toBeInstanceOf(Date)

    const externalUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.Chat), eq(schema.updates.entityId, externalReplyThread.id)))

    expect(externalUpdates).toHaveLength(1)
    const externalUpdate = UpdatesModel.decrypt(externalUpdates[0]!)
    expect(externalUpdate.payload.update.oneofKind).toBe("newChat")

    const ownerUserUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.User), eq(schema.updates.entityId, owner.id)))

    expect(ownerUserUpdates).toHaveLength(1)
    const ownerUserUpdate = UpdatesModel.decrypt(ownerUserUpdates[0]!)
    expect(ownerUserUpdate.payload.update.oneofKind).toBe("userChatParticipantDelete")
    if (ownerUserUpdate.payload.update.oneofKind === "userChatParticipantDelete") {
      expect(ownerUserUpdate.payload.update.userChatParticipantDelete.chatId).toBe(BigInt(externalReplyThread.id))
    }

    const spaceUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.Space), eq(schema.updates.entityId, targetSpace.id)))

    expect(spaceUpdates).toHaveLength(1)
    const spaceUpdate = UpdatesModel.decrypt(spaceUpdates[0]!)
    expect(spaceUpdate.payload.update.oneofKind).toBe("spaceClearHistory")
    if (spaceUpdate.payload.update.oneofKind === "spaceClearHistory") {
      expect(spaceUpdate.payload.update.spaceClearHistory.deletedChatIds).toEqual([])
      expect(spaceUpdate.payload.update.spaceClearHistory.orphanedChatIds).toEqual([])
      expect(spaceUpdate.payload.update.spaceClearHistory.detachedChatIds).toEqual([BigInt(externalReplyThread.id)])
    }
  })

  test("space clear publishes scoped updates for external descendants of deleted reply threads", async () => {
    const targetSpace = await testUtils.createSpace("clear-history-nested-target-space")
    const otherSpace = await testUtils.createSpace("clear-history-nested-external-space")
    const owner = await testUtils.createUser("clear-nested-owner@example.com")
    const admin = await testUtils.createUser("clear-nested-admin@example.com")
    const member = await testUtils.createUser("clear-nested-member@example.com")

    if (!targetSpace || !otherSpace) {
      throw new Error("Space not created")
    }

    await addSpaceMembers(targetSpace.id, [
      { userId: owner.id, role: "owner" },
      { userId: admin.id, role: "admin" },
      { userId: member.id },
    ])
    await addSpaceMembers(otherSpace.id, [{ userId: admin.id, role: "admin" }])

    const parent = await testUtils.createChat(targetSpace.id, "Nested Target Parent", "thread", true, owner.id)
    if (!parent) {
      throw new Error("Parent thread not created")
    }

    await insertMessage({ chatId: parent.id, messageId: 1, fromId: owner.id })
    await setLastMsgId(parent.id, 1)

    const [deletedReplyThread] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        spaceId: targetSpace.id,
        title: "Deleted Nested Reply Thread",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parent.id,
        parentMessageId: 1,
      })
      .returning()

    if (!deletedReplyThread) {
      throw new Error("Deleted reply thread not created")
    }

    await insertMessage({ chatId: deletedReplyThread.id, messageId: 1, fromId: owner.id })
    await setLastMsgId(deletedReplyThread.id, 1)

    const [externalGrandchild] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        spaceId: otherSpace.id,
        title: "External Nested Reply Thread",
        publicThread: true,
        createdBy: admin.id,
        parentChatId: deletedReplyThread.id,
        parentMessageId: 1,
      })
      .returning()

    if (!externalGrandchild) {
      throw new Error("External reply thread not created")
    }

    await insertMessage({ chatId: externalGrandchild.id, messageId: 1, fromId: admin.id })
    await setLastMsgId(externalGrandchild.id, 1)

    const result = await clearChatHistory(
      {
        spaceId: targetSpace.id,
        keepLastDays: 0,
        deleteReplyThreads: true,
      },
      testUtils.functionContext({ userId: admin.id }),
    )

    expect(result.updates.map((update) => update.update.oneofKind)).toEqual([
      "clearChatHistory",
      "newChat",
      "deleteChat",
    ])
    const clearUpdate = result.updates[0]?.update
    if (clearUpdate?.oneofKind !== "clearChatHistory") {
      throw new Error("Expected clearChatHistory update")
    }
    expect(clearUpdate.clearChatHistory.deletedChatIds).toEqual([BigInt(deletedReplyThread.id)])
    expect(clearUpdate.clearChatHistory.orphanedChatIds).toEqual([])
    expect(clearUpdate.clearChatHistory.detachedChatIds).toEqual([BigInt(externalGrandchild.id)])

    expect(await db.select().from(schema.chats).where(eq(schema.chats.id, deletedReplyThread.id)).limit(1)).toEqual([])
    const [retained] = await db.select().from(schema.chats).where(eq(schema.chats.id, externalGrandchild.id)).limit(1)
    expect(retained?.parentChatId).toBeNull()
    expect(retained?.parentMessageId).toBeNull()

    const externalUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.Chat), eq(schema.updates.entityId, externalGrandchild.id)))
    expect(externalUpdates).toHaveLength(1)
    expect(UpdatesModel.decrypt(externalUpdates[0]!).payload.update.oneofKind).toBe("newChat")

    const ownerUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.User), eq(schema.updates.entityId, owner.id)))
      .orderBy(schema.updates.seq)
    expect(
      ownerUpdates
        .map((update) => {
          const payload = UpdatesModel.decrypt(update).payload.update
          return payload.oneofKind === "userChatParticipantDelete" ? Number(payload.userChatParticipantDelete.chatId) : 0
        })
        .sort((a, b) => a - b),
    ).toEqual([externalGrandchild.id, deletedReplyThread.id].sort((a, b) => a - b))
  })

  test("space clear publishes deleted reply-thread updates only to scoped recipients", async () => {
    const targetSpace = await testUtils.createSpace("clear-history-delete-side-effects")
    const owner = await testUtils.createUser("clear-delete-side-owner@example.com")
    const admin = await testUtils.createUser("clear-delete-side-admin@example.com")
    const member = await testUtils.createUser("clear-delete-side-member@example.com")
    const directParticipant = await testUtils.createUser("clear-delete-side-direct@example.com")

    if (!targetSpace) {
      throw new Error("Space not created")
    }

    await addSpaceMembers(targetSpace.id, [
      { userId: owner.id, role: "owner" },
      { userId: admin.id, role: "admin" },
      { userId: member.id },
    ])

    const parent = await testUtils.createChat(targetSpace.id, "Target Parent", "thread", true, owner.id)
    if (!parent) {
      throw new Error("Parent thread not created")
    }

    await insertMessage({ chatId: parent.id, messageId: 1, fromId: owner.id })
    await setLastMsgId(parent.id, 1)

    const [replyThread] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        spaceId: targetSpace.id,
        title: "Deleted Reply Thread",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parent.id,
        parentMessageId: 1,
      })
      .returning()

    if (!replyThread) {
      throw new Error("Reply thread not created")
    }

    await testUtils.addParticipant(replyThread.id, directParticipant.id)
    await insertMessage({ chatId: replyThread.id, messageId: 1, fromId: directParticipant.id })
    await setLastMsgId(replyThread.id, 1)

    const result = await clearChatHistory(
      {
        spaceId: targetSpace.id,
        keepLastDays: 0,
        deleteReplyThreads: true,
      },
      testUtils.functionContext({ userId: admin.id }),
    )

    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["clearChatHistory", "deleteChat"])
    const clearUpdate = result.updates[0]?.update
    if (clearUpdate?.oneofKind !== "clearChatHistory") {
      throw new Error("Expected clearChatHistory update")
    }
    expect(clearUpdate.clearChatHistory.deletedChatIds).toEqual([BigInt(replyThread.id)])
    expect(clearUpdate.clearChatHistory.orphanedChatIds).toEqual([])
    expect(clearUpdate.clearChatHistory.detachedChatIds).toEqual([])

    const [deletedReplyThread] = await db.select().from(schema.chats).where(eq(schema.chats.id, replyThread.id)).limit(1)
    expect(deletedReplyThread).toBeUndefined()

    const spaceUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.Space), eq(schema.updates.entityId, targetSpace.id)))
    expect(spaceUpdates).toHaveLength(1)
    const spaceUpdate = UpdatesModel.decrypt(spaceUpdates[0]!)
    if (spaceUpdate.payload.update.oneofKind !== "spaceClearHistory") {
      throw new Error("Expected spaceClearHistory update")
    }
    expect(spaceUpdate.payload.update.spaceClearHistory.deletedChatIds).toEqual([BigInt(replyThread.id)])
    expect(spaceUpdate.payload.update.spaceClearHistory.orphanedChatIds).toEqual([])
    expect(spaceUpdate.payload.update.spaceClearHistory.detachedChatIds).toEqual([])

    const chatUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.Chat), eq(schema.updates.entityId, replyThread.id)))
    expect(chatUpdates).toHaveLength(1)
    const chatUpdate = UpdatesModel.decrypt(chatUpdates[0]!)
    expect(chatUpdate.payload.update.oneofKind).toBe("deleteChat")

    const userUpdates = await db
      .select()
      .from(schema.updates)
      .where(
        and(
          eq(schema.updates.bucket, UpdateBucket.User),
          inArray(schema.updates.entityId, [owner.id, admin.id, member.id, directParticipant.id]),
        ),
      )
      .orderBy(schema.updates.entityId)

    expect(userUpdates.map((update) => update.entityId)).toEqual([
      owner.id,
      admin.id,
      member.id,
      directParticipant.id,
    ].sort((a, b) => a - b))
    for (const update of userUpdates) {
      const decrypted = UpdatesModel.decrypt(update)
      expect(decrypted.payload.update.oneofKind).toBe("userChatParticipantDelete")
      if (decrypted.payload.update.oneofKind === "userChatParticipantDelete") {
        expect(decrypted.payload.update.userChatParticipantDelete.chatId).toBe(BigInt(replyThread.id))
      }
    }
  })

  test("orphaned reply threads remain when reply-thread deletion is disabled", async () => {
    const owner = await testUtils.createUser("clear-orphan-owner@example.com")
    const participant = await testUtils.createUser("clear-orphan-participant@example.com")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, owner.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, owner.id)
    await testUtils.addParticipant(parentChat.id, participant.id)
    await insertMessage({ chatId: parentChat.id, messageId: 1, fromId: owner.id, text: "anchor" })
    await setLastMsgId(parentChat.id, 1)

    const [childChat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Reply Thread",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!childChat) {
      throw new Error("Child chat not created")
    }

    await testUtils.addParticipant(childChat.id, owner.id)
    await testUtils.addParticipant(childChat.id, participant.id)
    await insertMessage({ chatId: childChat.id, messageId: 1, fromId: participant.id, text: "reply" })
    await setLastMsgId(childChat.id, 1)

    const result = await clearChatHistory(
      {
        peer: inputPeerForChat(parentChat.id),
        keepLastDays: 0,
        deleteReplyThreads: false,
      },
      testUtils.functionContext({ userId: owner.id }),
    )
    const update = result.updates[0]?.update
    if (update?.oneofKind !== "clearChatHistory") {
      throw new Error("Expected clearChatHistory update")
    }
    expect(update.clearChatHistory.orphanedChatIds).toEqual([BigInt(childChat.id)])

    const parentMessages = await db
      .select({ messageId: schema.messages.messageId })
      .from(schema.messages)
      .where(eq(schema.messages.chatId, parentChat.id))
    expect(parentMessages).toHaveLength(0)

    const [orphanedChat] = await db.select().from(schema.chats).where(eq(schema.chats.id, childChat.id)).limit(1)
    expect(orphanedChat).toBeTruthy()
    expect(orphanedChat?.parentChatId).toBe(parentChat.id)
    expect(orphanedChat?.parentMessageId).toBeNull()

    const childMessages = await db
      .select({ messageId: schema.messages.messageId })
      .from(schema.messages)
      .where(eq(schema.messages.chatId, childChat.id))
    expect(childMessages.map((row) => row.messageId)).toEqual([1])
  })

  test("orphaning reply threads respects kept recent days", async () => {
    const owner = await testUtils.createUser("clear-orphan-range-owner@example.com")
    const participant = await testUtils.createUser("clear-orphan-range-participant@example.com")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, owner.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    const oldDate = new Date(Date.now() - 10 * 24 * 60 * 60 * 1000)
    const recentDate = new Date(Date.now() - 24 * 60 * 60 * 1000)

    await testUtils.addParticipant(parentChat.id, owner.id)
    await testUtils.addParticipant(parentChat.id, participant.id)
    await insertMessage({ chatId: parentChat.id, messageId: 1, fromId: owner.id, text: "old anchor", date: oldDate })
    await insertMessage({
      chatId: parentChat.id,
      messageId: 2,
      fromId: owner.id,
      text: "recent anchor",
      date: recentDate,
    })
    await setLastMsgId(parentChat.id, 2)

    const [oldChildChat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Old Reply Thread",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    const [recentChildChat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Recent Reply Thread",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parentChat.id,
        parentMessageId: 2,
      })
      .returning()

    if (!oldChildChat || !recentChildChat) {
      throw new Error("Child chats not created")
    }

    const result = await clearChatHistory(
      {
        peer: inputPeerForChat(parentChat.id),
        keepLastDays: 7,
        deleteReplyThreads: false,
      },
      testUtils.functionContext({ userId: owner.id }),
    )
    const update = result.updates[0]?.update
    if (update?.oneofKind !== "clearChatHistory") {
      throw new Error("Expected clearChatHistory update")
    }
    expect(update.clearChatHistory.orphanedChatIds).toEqual([BigInt(oldChildChat.id)])

    const parentMessages = await db
      .select({ messageId: schema.messages.messageId })
      .from(schema.messages)
      .where(eq(schema.messages.chatId, parentChat.id))
      .orderBy(schema.messages.messageId)
    expect(parentMessages.map((row) => row.messageId)).toEqual([2])

    const [oldChild] = await db.select().from(schema.chats).where(eq(schema.chats.id, oldChildChat.id)).limit(1)
    const [recentChild] = await db.select().from(schema.chats).where(eq(schema.chats.id, recentChildChat.id)).limit(1)

    expect(oldChild?.parentMessageId).toBeNull()
    expect(recentChild?.parentMessageId).toBe(2)
  })

  test("deletes reply-thread subtrees when reply-thread deletion is enabled", async () => {
    const owner = await testUtils.createUser("clear-cascade-owner@example.com")
    const participant = await testUtils.createUser("clear-cascade-participant@example.com")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, owner.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, owner.id)
    await testUtils.addParticipant(parentChat.id, participant.id)
    await insertMessage({ chatId: parentChat.id, messageId: 1, fromId: owner.id, text: "anchor" })
    await setLastMsgId(parentChat.id, 1)

    const [childChat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Reply Thread",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!childChat) {
      throw new Error("Child chat not created")
    }

    await testUtils.addParticipant(childChat.id, owner.id)
    await testUtils.addParticipant(childChat.id, participant.id)
    await insertMessage({ chatId: childChat.id, messageId: 1, fromId: participant.id, text: "nested anchor" })
    await insertTranslation({ chatId: childChat.id, messageId: 1 })
    await setLastMsgId(childChat.id, 1)

    const [grandchildChat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Nested Reply Thread",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: childChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!grandchildChat) {
      throw new Error("Grandchild chat not created")
    }

    await testUtils.addParticipant(grandchildChat.id, owner.id)
    await testUtils.addParticipant(grandchildChat.id, participant.id)
    await insertMessage({ chatId: grandchildChat.id, messageId: 1, fromId: owner.id, text: "nested reply" })
    await setLastMsgId(grandchildChat.id, 1)

    const result = await clearChatHistory(
      {
        peer: inputPeerForChat(parentChat.id),
        keepLastDays: 0,
        deleteReplyThreads: true,
      },
      testUtils.functionContext({ userId: owner.id }),
    )
    const update = result.updates[0]?.update
    if (update?.oneofKind !== "clearChatHistory") {
      throw new Error("Expected clearChatHistory update")
    }
    expect(update.clearChatHistory.deletedChatIds.map(Number).sort((a, b) => a - b)).toEqual(
      [childChat.id, grandchildChat.id].sort((a, b) => a - b),
    )

    const [child] = await db.select().from(schema.chats).where(eq(schema.chats.id, childChat.id)).limit(1)
    const [grandchild] = await db.select().from(schema.chats).where(eq(schema.chats.id, grandchildChat.id)).limit(1)

    expect(child).toBeUndefined()
    expect(grandchild).toBeUndefined()

    const parentMessages = await db
      .select({ messageId: schema.messages.messageId })
      .from(schema.messages)
      .where(eq(schema.messages.chatId, parentChat.id))
    expect(parentMessages).toHaveLength(0)
  })
})
