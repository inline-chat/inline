import { describe, expect, test } from "bun:test"
import { handler as getDialogsHandler } from "../../methods/getDialogs"
import { testUtils, defaultTestContext, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { eq, and, or } from "drizzle-orm"

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

  test("creates private chats for space members without dialogs", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("PrivateChatSpace", [
      "userA3@example.com",
      "userB3@example.com",
      "userC3@example.com",
    ])
    const [userA, userB, userC] = users

    // Create a private chat between userA and userB only
    const existingChat = await db
      .insert(schema.chats)
      .values({
        type: "private",
        minUserId: Math.min(userA.id, userB.id),
        maxUserId: Math.max(userA.id, userB.id),
        date: new Date(),
      })
      .returning()
      .then((rows) => rows[0])

    if (!existingChat) throw new Error("Chat was not created")

    // Create dialog for userA
    await db
      .insert(schema.dialogs)
      .values({
        chatId: existingChat.id,
        userId: userA.id,
        peerUserId: userB.id,
        date: new Date(),
      })
      .execute()

    // Sanity: ensure no private chat exists between userA and userC
    const chatsBefore = await db.query.chats.findMany({
      where: and(
        eq(schema.chats.type, "private"),
        or(
          and(
            eq(schema.chats.minUserId, Math.min(userA.id, userC.id)),
            eq(schema.chats.maxUserId, Math.max(userA.id, userC.id)),
          ),
          and(
            eq(schema.chats.minUserId, Math.max(userA.id, userC.id)),
            eq(schema.chats.maxUserId, Math.min(userA.id, userC.id)),
          ),
        ),
      ),
    })
    expect(chatsBefore.length).toBe(0)

    // Call handler for userA
    const input = { spaceId: space.id }
    const context = makeHandlerContext(userA.id)
    const result = await getDialogsHandler(input, context)

    // Should now have a private chat between userA and userC
    const chatsAfter = await db.query.chats.findMany({
      where: and(
        eq(schema.chats.type, "private"),
        or(
          and(
            eq(schema.chats.minUserId, Math.min(userA.id, userC.id)),
            eq(schema.chats.maxUserId, Math.max(userA.id, userC.id)),
          ),
          and(
            eq(schema.chats.minUserId, Math.max(userA.id, userC.id)),
            eq(schema.chats.maxUserId, Math.min(userA.id, userC.id)),
          ),
        ),
      ),
    })
    expect(chatsAfter.length).toBe(1)

    // Should have a dialog for userA with userC
    const dialogsAfter = await db.query.dialogs.findMany({
      where: and(eq(schema.dialogs.userId, userA.id), eq(schema.dialogs.peerUserId, userC.id)),
    })
    expect(dialogsAfter.length).toBe(1)

    // Should be returned in the result
    const dialogPeerIds = result.dialogs.map((d) => (d.peerId && "userId" in d.peerId ? d.peerId.userId : undefined))
    expect(dialogPeerIds).toContain(userC.id)

    // Should include all users
    const userEmails = result.users.map((u) => u.email)
    expect(userEmails).toContain("userA3@example.com")
    expect(userEmails).toContain("userB3@example.com")
    expect(userEmails).toContain("userC3@example.com")
  })

  test("does not create duplicate private chats for existing conversations", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("DuplicateChatSpace", [
      "userA4@example.com",
      "userB4@example.com",
    ])
    const [userA, userB] = users

    // Create an existing private chat between userA and userB
    const existingChat = await db
      .insert(schema.chats)
      .values({
        type: "private",
        minUserId: Math.min(userA.id, userB.id),
        maxUserId: Math.max(userA.id, userB.id),
        date: new Date(),
      })
      .returning()
      .then((rows) => rows[0])

    if (!existingChat) throw new Error("Chat was not created")

    // Create dialog for userA
    await db
      .insert(schema.dialogs)
      .values({
        chatId: existingChat.id,
        userId: userA.id,
        peerUserId: userB.id,
        date: new Date(),
      })
      .execute()

    // Count existing chats before
    const chatsBefore = await db.query.chats.findMany({
      where: and(
        eq(schema.chats.type, "private"),
        or(
          and(
            eq(schema.chats.minUserId, Math.min(userA.id, userB.id)),
            eq(schema.chats.maxUserId, Math.max(userA.id, userB.id)),
          ),
          and(
            eq(schema.chats.minUserId, Math.max(userA.id, userB.id)),
            eq(schema.chats.maxUserId, Math.min(userA.id, userB.id)),
          ),
        ),
      ),
    })
    const initialChatCount = chatsBefore.length

    // Call handler for userA
    const input = { spaceId: space.id }
    const context = makeHandlerContext(userA.id)
    const result = await getDialogsHandler(input, context)

    // Should still have the same number of chats
    const chatsAfter = await db.query.chats.findMany({
      where: and(
        eq(schema.chats.type, "private"),
        or(
          and(
            eq(schema.chats.minUserId, Math.min(userA.id, userB.id)),
            eq(schema.chats.maxUserId, Math.max(userA.id, userB.id)),
          ),
          and(
            eq(schema.chats.minUserId, Math.max(userA.id, userB.id)),
            eq(schema.chats.maxUserId, Math.min(userA.id, userB.id)),
          ),
        ),
      ),
    })
    expect(chatsAfter.length).toBe(initialChatCount)

    // Should have exactly one dialog for userA with userB
    const dialogsAfter = await db.query.dialogs.findMany({
      where: and(eq(schema.dialogs.userId, userA.id), eq(schema.dialogs.peerUserId, userB.id)),
    })
    expect(dialogsAfter.length).toBe(1)

    // Should return the existing dialog in the result
    const dialogPeerIds = result.dialogs.map((d) => (d.peerId && "userId" in d.peerId ? d.peerId.userId : undefined))
    expect(dialogPeerIds).toContain(userB.id)
    expect(dialogPeerIds.filter((id) => id === userB.id).length).toBe(1) // Should appear exactly once

    // Should include both users
    const userEmails = result.users.map((u) => u.email)
    expect(userEmails).toContain("userA4@example.com")
    expect(userEmails).toContain("userB4@example.com")
  })

  test("creates dialog for public thread when new user joins space", async () => {
    // Create initial space with one user and a public thread
    const {
      space,
      users: [initialUser],
    } = await testUtils.createSpaceWithMembers("ThreadSpace", ["initial@example.com"])

    // Create a public thread in the space
    const chat = await testUtils.createChat(space.id, "Public Thread", "thread")
    if (!chat) throw new Error("Failed to create chat")

    // Add a message to the thread from the initial user
    const msg = await db
      .insert(schema.messages)
      .values({
        messageId: 1,
        chatId: chat.id,
        fromId: initialUser.id,
        text: "Initial message",
      })
      .returning()
      .then((rows) => rows[0])

    if (!msg) throw new Error("Failed to create message")
    await db.update(schema.chats).set({ lastMsgId: msg.messageId }).where(eq(schema.chats.id, chat.id)).execute()

    // Create and add new user to the space
    const newUser = await testUtils.createUser("newuser@example.com")
    if (!newUser) throw new Error("Failed to create new user")

    await db
      .insert(schema.members)
      .values({ userId: newUser.id, spaceId: space.id, role: "member" as const })
      .execute()

    // Verify no dialog exists for new user
    const dialogsBefore = await db.query.dialogs.findMany({
      where: and(eq(schema.dialogs.chatId, chat.id), eq(schema.dialogs.userId, newUser.id)),
    })
    expect(dialogsBefore.length).toBe(0)

    // Call getDialogs for new user
    const input = { spaceId: space.id }
    const context = makeHandlerContext(newUser.id)
    const result = await getDialogsHandler(input, context)

    // Verify dialog was created
    const dialogsAfter = await db.query.dialogs.findMany({
      where: and(eq(schema.dialogs.chatId, chat.id), eq(schema.dialogs.userId, newUser.id)),
    })
    expect(dialogsAfter.length).toBe(1)

    // Verify the dialog is included in the result
    const dialogThreadIds = result.dialogs.map((d) =>
      d.peerId && "threadId" in d.peerId ? d.peerId.threadId : undefined,
    )
    expect(dialogThreadIds).toContain(chat.id)

    // Verify the chat is included in the result
    const chatIds = result.chats.map((c) => c.id)
    expect(chatIds).toContain(chat.id)
  })

  test("should not return private threads where user is not a participant", async () => {
    // Create a space with two users
    const { space, users } = await testUtils.createSpaceWithMembers("Test Space", ["user1@ex.com", "user2@ex.com"])
    const [user1, user2] = users

    // Create a private thread chat
    const { chat } = await testUtils.createThreadWithDialogAndMessage({
      spaceId: space.id,
      user: user1,
      otherUsers: [user2],
      title: "Private Thread",
      isPublic: false,
      messageText: "Hello private thread",
    })

    // Call getDialogs as user1 (who is a participant)
    const result1 = await getDialogsHandler({ spaceId: space.id }, makeHandlerContext(user1.id))
    const hasThread = result1.dialogs.some((d) => {
      if ("threadId" in d.peerId) {
        return d.peerId.threadId === chat.id
      }
      return false
    })
    expect(hasThread).toBe(true)

    // Create a third user who is NOT a participant but IS in the space
    const user3 = await testUtils.createUser("user3@ex.com")
    if (!user3) throw new Error("Failed to create user3")

    // Create a dialog for this user
    await db
      .insert(schema.dialogs)
      .values({
        chatId: chat.id,
        userId: user3.id,
        spaceId: space.id,
      })
      .execute()

    // Add user3 to the space
    await db
      .insert(schema.members)
      .values({ userId: user3.id, spaceId: space.id, role: "member" as const })
      .execute()

    // Call getDialogs as user3 (who is in the space but not a thread participant)
    const result3 = await getDialogsHandler({ spaceId: space.id }, makeHandlerContext(user3.id))
    const hasThread3 = result3.dialogs.some((d) => {
      if ("threadId" in d.peerId) {
        return d.peerId.threadId === chat.id
      }
      return false
    })
    console.log("🌴 result3", result3)
    expect(hasThread3).toBe(false)
  })
})
