import { testUtils, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { eq, and, inArray } from "drizzle-orm"
import { handler } from "../../methods/getPrivateChats"
import { describe, test, expect } from "bun:test"
import type { HandlerContext } from "../../controllers/helpers"
import type { TDialogInfo, TMessageInfo } from "../../api-types"

describe("getPrivateChats", () => {
  setupTestLifecycle()

  const makeTestContext = (userId: number): HandlerContext => ({
    currentUserId: userId,
    currentSessionId: 0,
    ip: "127.0.0.1",
  })

  test("returns empty arrays when user has no private chats", async () => {
    // Create a user with no chats
    const user = await testUtils.createUser("lonely@example.com")
    if (!user) throw new Error("Failed to create user")

    // Call getPrivateChats
    const result = await handler({}, makeTestContext(user.id))

    // Verify empty results
    expect(result.chats).toEqual([])
    expect(result.dialogs).toEqual([])
    expect(result.messages).toEqual([])
    expect(result.peerUsers).toEqual([])
  })

  test("creates missing dialog for private chat when user is a participant", async () => {
    // Create two users
    const userA = await testUtils.createUser("userA@example.com")
    const userB = await testUtils.createUser("userB@example.com")
    if (!userA || !userB) throw new Error("Failed to create users")

    // Create a private chat between them, but only create dialog for userA
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })

    // Verify initial state - only one dialog exists
    const dialogsBefore = await db.query.dialogs.findMany({
      where: eq(schema.dialogs.chatId, chat.id),
    })
    expect(dialogsBefore.length).toBe(1)
    const firstDialog = dialogsBefore[0]
    if (!firstDialog) throw new Error("Dialog not found")
    expect(firstDialog.userId).toBe(userA.id)

    // Call getPrivateChats for userB
    const result = await handler({}, makeTestContext(userB.id))

    // Verify chat is returned
    expect(result.chats.some((c) => c.id === chat.id)).toBe(true)

    // Verify dialog was created for userB
    const dialogsAfter = await db.query.dialogs.findMany({
      where: eq(schema.dialogs.chatId, chat.id),
    })
    expect(dialogsAfter.length).toBe(2)
    expect(dialogsAfter.some((d) => d.userId === userB.id)).toBe(true)

    // Verify dialog is returned in result with correct peer
    expect(result.dialogs.some((d) => "userId" in d.peerId && d.peerId.userId === userA.id)).toBe(true)
  })

  test("does not create duplicate dialogs for existing conversations", async () => {
    // Create two users
    const userA = await testUtils.createUser("userA2@example.com")
    const userB = await testUtils.createUser("userB2@example.com")
    if (!userA || !userB) throw new Error("Failed to create users")

    // Create a private chat with dialogs for both users
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: true,
    })

    // Verify initial state - both dialogs exist
    const dialogsBefore = await db.query.dialogs.findMany({
      where: eq(schema.dialogs.chatId, chat.id),
    })
    expect(dialogsBefore.length).toBe(2)

    // Call getPrivateChats for userB
    const result = await handler({}, makeTestContext(userB.id))

    // Verify no new dialogs were created
    const dialogsAfter = await db.query.dialogs.findMany({
      where: eq(schema.dialogs.chatId, chat.id),
    })
    expect(dialogsAfter.length).toBe(2)

    // Verify existing dialog is returned in result
    expect(result.dialogs.some((d) => "userId" in d.peerId && d.peerId.userId === userA.id)).toBe(true)
  })

  test("handles multiple private chats with missing dialogs", async () => {
    // Create three users
    const userA = await testUtils.createUser("userA3@example.com")
    const userB = await testUtils.createUser("userB3@example.com")
    const userC = await testUtils.createUser("userC3@example.com")
    if (!userA || !userB || !userC) throw new Error("Failed to create users")

    // Create two private chats: one between A-B and one between B-C
    const { chat: chatAB } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })

    const { chat: chatBC } = await testUtils.createPrivateChatWithOptionalDialog({
      userA: userB,
      userB: userC,
      createDialogForUserA: false,
      createDialogForUserB: false,
    })

    // Verify initial state - only one dialog exists (for userA in chatAB)
    const dialogsBefore = await db.query.dialogs.findMany({
      where: inArray(schema.dialogs.chatId, [chatAB.id, chatBC.id]),
    })
    expect(dialogsBefore.length).toBe(1)

    // Call getPrivateChats for userB
    const result = await handler({}, makeTestContext(userB.id))

    // Verify both chats are returned (both chats involve userB)
    expect(result.chats.some((c) => c.id === chatAB.id)).toBe(true)
    expect(result.chats.some((c) => c.id === chatBC.id)).toBe(true)

    // Verify dialogs were created for userB in both chats
    const dialogsAfter = await db.query.dialogs.findMany({
      where: and(eq(schema.dialogs.userId, userB.id), inArray(schema.dialogs.chatId, [chatAB.id, chatBC.id])),
    })
    expect(dialogsAfter.length).toBe(2)

    // Verify dialogs are returned in result with correct peer users
    expect(result.dialogs.some((d) => "userId" in d.peerId && d.peerId.userId === userA.id)).toBe(true)
    expect(result.dialogs.some((d) => "userId" in d.peerId && d.peerId.userId === userC.id)).toBe(true)
  })

  test("handles private chats with deleted peer users", async () => {
    // Create two users
    const userA = await testUtils.createUser("userA4@example.com")
    const userB = await testUtils.createUser("userB4@example.com")
    if (!userA || !userB) throw new Error("Failed to create users")

    // Create a private chat between them
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: true,
    })

    // Mark userB as deleted
    await db.update(schema.users).set({ deleted: true }).where(eq(schema.users.id, userB.id)).execute()

    // Call getPrivateChats for userA
    const result = await handler({}, makeTestContext(userA.id))

    // Chat should still be returned
    expect(result.chats.some((c) => c.id === chat.id)).toBe(true)
    // Dialog should still exist
    expect(result.dialogs.length).toBe(1)
    // Peer user should still be in the result even though they are marked as deleted
    expect(result.peerUsers.some((u) => u.id === userB.id)).toBe(true)
  })

  test("returns correct unread counts for private chats", async () => {
    // Create two users
    const userA = await testUtils.createUser("userA5@example.com")
    const userB = await testUtils.createUser("userB5@example.com")
    if (!userA || !userB) throw new Error("Failed to create users")

    // Create a private chat with dialogs
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: true,
    })

    // Add some messages from userA to userB
    await db
      .insert(schema.messages)
      .values([
        {
          messageId: 1,
          chatId: chat.id,
          fromId: userA.id,
          text: "Message 1",
          date: new Date(),
        },
        {
          messageId: 2,
          chatId: chat.id,
          fromId: userA.id,
          text: "Message 2",
          date: new Date(),
        },
      ])
      .execute()

    // Update chat's last message
    await db.update(schema.chats).set({ lastMsgId: 2 }).where(eq(schema.chats.id, chat.id)).execute()

    // Set read inbox max id for userB's dialog to 1 (one unread message)
    await db
      .update(schema.dialogs)
      .set({ readInboxMaxId: 1 })
      .where(and(eq(schema.dialogs.chatId, chat.id), eq(schema.dialogs.userId, userB.id)))
      .execute()

    // Call getPrivateChats for userB
    const result = await handler({}, makeTestContext(userB.id))

    // Find the dialog for this chat
    const dialog = result.dialogs.find((d) => "userId" in d.peerId && d.peerId.userId === userA.id)
    if (!dialog) throw new Error("Dialog not found")
    // We know unreadCount will be defined and a number because getPrivateChats.ts always sets it via DialogsModel.getBatchUnreadCounts
    expect(dialog.unreadCount as number).toBe(1)
  })

  test("handles private chats with file attachments", async () => {
    // Create two users
    const userA = await testUtils.createUser("userA6@example.com")
    const userB = await testUtils.createUser("userB6@example.com")
    if (!userA || !userB) throw new Error("Failed to create users")

    // Create a private chat with dialogs
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: true,
    })

    // Create a file
    const [file] = await db
      .insert(schema.files)
      .values({
        fileUniqueId: "test123",
        userId: userA.id,
        fileType: "document",
        fileSize: 100,
        mimeType: "text/plain",
        width: 0,
        height: 0,
      })
      .returning()
    if (!file) throw new Error("Failed to create file")

    // Add a message with the file
    await db
      .insert(schema.messages)
      .values({
        messageId: 1,
        chatId: chat.id,
        fromId: userA.id,
        text: "File message",
        fileId: file.id,
        date: new Date(),
      })
      .execute()

    // Update chat's last message
    await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, chat.id)).execute()

    // Call getPrivateChats for userB
    const result = await handler({}, makeTestContext(userB.id))

    // Find the message for this chat
    const message = result.messages.find((m) => m.chatId === chat.id)
    expect(message).toBeDefined()
    // The file should be included in the photo array if it's an image
    if (file.fileType === "photo") {
      expect(message?.photo).toBeDefined()
      expect(message?.photo?.[0]?.fileUniqueId).toBe(file.fileUniqueId)
    }
  })
})
