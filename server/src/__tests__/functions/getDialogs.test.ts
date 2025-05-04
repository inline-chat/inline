import { describe, expect, test } from "bun:test"
import { handler as getDialogsHandler } from "../../methods/getDialogs"
import { testUtils, defaultTestContext, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { eq, and } from "drizzle-orm"

// Helper to create a HandlerContext
const makeHandlerContext = (userId: number): any => ({
  currentUserId: userId,
  currentSessionId: defaultTestContext.sessionId,
  ip: "127.0.0.1",
})

describe("getDialogs", () => {
  setupTestLifecycle()

  test("returns empty arrays when user has no dialogs", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("DM Space", ["empty@example.com"])
    const input = { spaceId: space.id }
    const context = makeHandlerContext(users[0].id)
    const result = await getDialogsHandler(input, context)
    try {
      expect(result.dialogs).toEqual([])
      expect(result.chats).toEqual([])
      expect(result.messages).toEqual([])
      // Should include the user as a space member
      expect(result.users.length).toBe(1)
      expect(result.users[0]?.email).toBe("empty@example.com")
    } catch (err) {
      // Log the full result for debugging
      // eslint-disable-next-line no-console
      console.error("Test failed: returns empty arrays when user has no dialogs", JSON.stringify(result, null, 2))
      throw err
    }
  })

  test("returns dialogs for public and private threads in a space", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Space1", ["a@example.com", "b@example.com"])
    const [userA, userB] = users
    await testUtils.createThreadWithDialogAndMessage({
      spaceId: space.id,
      user: userA,
      title: "Public Thread",
      isPublic: true,
      messageText: "Hello public",
    })
    await testUtils.createThreadWithDialogAndMessage({
      spaceId: space.id,
      user: userA,
      otherUsers: [userB],
      title: "Private Thread",
      isPublic: false,
      messageText: "Hello private",
      messageFromUser: userB,
    })
    const input = { spaceId: space.id }
    const context = makeHandlerContext(userA.id)
    const result = await getDialogsHandler(input, context)
    try {
      // Check for expected chat titles
      const chatTitles = result.chats.map((c) => c.title)
      expect(chatTitles).toContain("Public Thread")
      expect(chatTitles).toContain("Private Thread")
      // Check for expected user emails
      const userEmails = result.users.map((u) => u.email)
      expect(userEmails).toContain("a@example.com")
      expect(userEmails).toContain("b@example.com")
      // There should be at least 2 dialogs and 2 messages
      expect(result.dialogs.length).toBeGreaterThanOrEqual(2)
      expect(result.messages.length).toBeGreaterThanOrEqual(2)
    } catch (err) {
      // Log the full result for debugging
      // eslint-disable-next-line no-console
      console.error(
        "Test failed: returns dialogs for public and private threads in a space",
        JSON.stringify(result, null, 2),
      )
      throw err
    }
  })

  test("returns direct messages when using a dedicated DM spaceId", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("DM Space", ["dmA@example.com", "dmB@example.com"])
    const [userA, userB] = users
    await testUtils.createDMWithDialogAndMessage({
      spaceId: space.id,
      userA,
      userB,
      messageText: "Hey DM!",
      messageFromUser: userB,
    })
    const input = { spaceId: space.id }
    const context = makeHandlerContext(userA.id)
    const result = await getDialogsHandler(input, context)
    try {
      // There should be a DM chat and userB in users
      const chatTitles = result.chats.map((c) => c.title)
      expect(chatTitles).toContain("DM Chat")
      const userEmails = result.users.map((u) => u.email)
      expect(userEmails).toContain("dmB@example.com")
      expect(result.dialogs.length).toBeGreaterThanOrEqual(1)
      expect(result.messages.length).toBeGreaterThanOrEqual(1)
    } catch (err) {
      // Log the full result for debugging
      // eslint-disable-next-line no-console
      console.error(
        "Test failed: returns direct messages when using a dedicated DM spaceId",
        JSON.stringify(result, null, 2),
      )
      throw err
    }
  })

  test("throws error for invalid spaceId", async () => {
    const { users } = await testUtils.createSpaceWithMembers("ErrSpace", ["err@example.com"])
    const input = { spaceId: "not-a-number" as any }
    const context = makeHandlerContext(users[0].id)
    await expect(getDialogsHandler(input, context)).rejects.toThrow()
  })

  test("creates missing Dialog for a Chat being returned", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("ThreadSpace", ["missing@example.com"])
    const [user] = users
    // Create a thread chat directly in the DB, but do NOT create a dialog for the user
    const chat = await db
      .insert(schema.chats)
      .values({
        spaceId: space.id,
        type: "thread",
        publicThread: true,
        title: "Orphan Thread",
      })
      .returning()
      .then((rows) => rows[0])
    // Sanity: ensure no dialog exists for this chat/user
    if (!chat) throw new Error("Chat was not created")
    const dialogsBefore = await db.query.dialogs.findMany({
      where: and(eq(schema.dialogs.chatId, chat.id), eq(schema.dialogs.userId, user.id)),
    })
    expect(dialogsBefore.length).toBe(0)
    // Call handler
    const input = { spaceId: space.id }
    const context = makeHandlerContext(user.id)
    const result = await getDialogsHandler(input, context)
    // Should now have a dialog for the chat
    const dialogsAfter = await db.query.dialogs.findMany({
      where: and(eq(schema.dialogs.chatId, chat.id), eq(schema.dialogs.userId, user.id)),
    })
    expect(dialogsAfter.length).toBe(1)
    // Should be returned in the result
    // For thread dialogs, peerId is { threadId: chat.id }
    const dialogThreadIds = result.dialogs.map((d) =>
      d.peerId && "threadId" in d.peerId ? d.peerId.threadId : undefined,
    )
    expect(dialogThreadIds).toContain(chat.id)
    // Should also return the chat
    const chatIds = result.chats.map((c) => c.id)
    expect(chatIds).toContain(chat.id)
  })

  test("creates missing Dialog for a private thread the user is a participant of", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("PrivateThreadSpace", [
      "userA@example.com",
      "userB@example.com",
    ])
    const [userA, userB] = users
    // Create a private thread chat directly in the DB, but do NOT create a dialog for userA
    const chat = await db
      .insert(schema.chats)
      .values({
        spaceId: space.id,
        type: "thread",
        publicThread: false,
        title: "Private Orphan Thread",
      })
      .returning()
      .then((rows) => rows[0])
    if (!chat) throw new Error("Chat was not created")
    // Add both users as participants
    await db
      .insert(schema.chatParticipants)
      .values([
        { chatId: chat.id, userId: userA.id },
        { chatId: chat.id, userId: userB.id },
      ])
      .execute()
    // Sanity: ensure no dialog exists for userA
    const dialogsBefore = await db.query.dialogs.findMany({
      where: and(eq(schema.dialogs.chatId, chat.id), eq(schema.dialogs.userId, userA.id)),
    })
    expect(dialogsBefore.length).toBe(0)
    // Call handler for userA
    const input = { spaceId: space.id }
    const context = makeHandlerContext(userA.id)
    const result = await getDialogsHandler(input, context)
    // Should now have a dialog for the chat
    const dialogsAfter = await db.query.dialogs.findMany({
      where: and(eq(schema.dialogs.chatId, chat.id), eq(schema.dialogs.userId, userA.id)),
    })
    expect(dialogsAfter.length).toBe(1)
    // Should be returned in the result
    const dialogThreadIds = result.dialogs.map((d) =>
      d.peerId && "threadId" in d.peerId ? d.peerId.threadId : undefined,
    )
    expect(dialogThreadIds).toContain(chat.id)
    // Should also return the chat
    const chatIds = result.chats.map((c) => c.id)
    expect(chatIds).toContain(chat.id)
  })

  test("does not return or create Dialog for private thread user is not a participant of", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("PrivateThreadSpace2", [
      "userA2@example.com",
      "userB2@example.com",
    ])
    const [userA, userB] = users
    // Create a private thread chat directly in the DB
    const chat = await db
      .insert(schema.chats)
      .values({
        spaceId: space.id,
        type: "thread",
        publicThread: false,
        title: "Private Not Participant Thread",
      })
      .returning()
      .then((rows) => rows[0])
    if (!chat) throw new Error("Chat was not created")
    // Add only userB as a participant
    await db
      .insert(schema.chatParticipants)
      .values([{ chatId: chat.id, userId: userB.id }])
      .execute()
    // Sanity: ensure no dialog exists for userA
    const dialogsBefore = await db.query.dialogs.findMany({
      where: and(eq(schema.dialogs.chatId, chat.id), eq(schema.dialogs.userId, userA.id)),
    })
    expect(dialogsBefore.length).toBe(0)
    // Call handler for userA
    const input = { spaceId: space.id }
    const context = makeHandlerContext(userA.id)
    const result = await getDialogsHandler(input, context)
    // Should still have no dialog for userA
    const dialogsAfter = await db.query.dialogs.findMany({
      where: and(eq(schema.dialogs.chatId, chat.id), eq(schema.dialogs.userId, userA.id)),
    })
    expect(dialogsAfter.length).toBe(0)
    // Should not be returned in the result
    const dialogThreadIds = result.dialogs.map((d) =>
      d.peerId && "threadId" in d.peerId ? d.peerId.threadId : undefined,
    )
    expect(dialogThreadIds).not.toContain(chat.id)
    const chatIds = result.chats.map((c) => c.id)
    expect(chatIds).not.toContain(chat.id)
  })
})
