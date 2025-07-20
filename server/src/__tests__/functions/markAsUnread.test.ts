import { describe, test, expect, beforeEach, beforeAll } from "bun:test"
import { InputPeer } from "@in/protocol/core"
import { setupTestDatabase, testUtils } from "../setup"
import { markAsUnread } from "@in/server/functions/messages.markAsUnread"
import type { DbChat, DbUser, DbDialog } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { db } from "@in/server/db"
import { dialogs } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { handler as readMessagesHandler } from "@in/server/methods/readMessages"

// Test state
let currentUser: DbUser
let otherUser: DbUser
let privateChat: DbChat
let privateChatPeerId: InputPeer
let context: FunctionContext

describe("markAsUnread", () => {
  beforeAll(async () => {
    await setupTestDatabase()
    currentUser = (await testUtils.createUser("test@example.com"))!
    otherUser = (await testUtils.createUser("other@example.com"))!
    const chatResult = await testUtils.createPrivateChatWithOptionalDialog({
      userA: currentUser,
      userB: otherUser,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })
    privateChat = chatResult.chat
    privateChatPeerId = {
      type: { oneofKind: "chat" as const, chat: { chatId: BigInt(privateChat.id) } },
    }
    context = testUtils.functionContext({ userId: currentUser.id, sessionId: 1 })
  })

  test("should mark dialog as unread", async () => {
    // First, ensure the dialog exists and is initially not marked as unread
    const [initialDialog] = await db
      .select()
      .from(dialogs)
      .where(
        and(
          eq(dialogs.chatId, privateChat.id),
          eq(dialogs.userId, currentUser.id)
        )
      )
      .limit(1)
    
    expect(initialDialog).toBeTruthy()
    expect(initialDialog?.unreadMark).toBe(false)

    // Mark as unread
    const result = await markAsUnread(
      {
        peer: privateChatPeerId,
      },
      context,
    )

    expect(result.updates).toBeDefined()

    // Verify the dialog is now marked as unread
    const [updatedDialog] = await db
      .select()
      .from(dialogs)
      .where(
        and(
          eq(dialogs.chatId, privateChat.id),
          eq(dialogs.userId, currentUser.id)
        )
      )
      .limit(1)
    
    expect(updatedDialog?.unreadMark).toBe(true)
  })

  test("should throw error for invalid peer", async () => {
    const invalidPeerId: InputPeer = {
      type: { oneofKind: "chat" as const, chat: { chatId: BigInt(99999) } },
    }

    await expect(markAsUnread(
      {
        peer: invalidPeerId,
      },
      context,
    )).rejects.toThrow()
  })

  test("readMessages should set unreadMark to false", async () => {
    // First mark the dialog as unread
    await markAsUnread(
      {
        peer: privateChatPeerId,
      },
      context,
    )

    // Verify it's marked as unread
    const [markedDialog] = await db
      .select()
      .from(dialogs)
      .where(
        and(
          eq(dialogs.chatId, privateChat.id),
          eq(dialogs.userId, currentUser.id)
        )
      )
      .limit(1)
    
    expect(markedDialog?.unreadMark).toBe(true)

    // Call readMessages
    await readMessagesHandler(
      {
        peerThreadId: privateChat.id.toString(),
      },
      { 
        currentUserId: currentUser.id, 
        currentSessionId: 1, 
        ip: undefined 
      }
    )

    // Verify unreadMark is now false
    const [readDialog] = await db
      .select()
      .from(dialogs)
      .where(
        and(
          eq(dialogs.chatId, privateChat.id),
          eq(dialogs.userId, currentUser.id)
        )
      )
      .limit(1)
    
    expect(readDialog?.unreadMark).toBe(false)
  })
}) 