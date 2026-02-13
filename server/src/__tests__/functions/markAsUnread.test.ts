import { describe, test, expect, beforeEach } from "bun:test"
import { InputPeer } from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "../setup"
import { markAsUnread } from "@in/server/functions/messages.markAsUnread"
import type { DbChat, DbUser } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { db } from "@in/server/db"
import { dialogs, updates, UpdateBucket } from "@in/server/db/schema"
import { and, desc, eq } from "drizzle-orm"
import { handler as readMessagesHandler } from "@in/server/methods/readMessages"
import { UpdatesModel } from "@in/server/db/models/updates"

// Test state
let currentUser: DbUser
let otherUser: DbUser
let privateChat: DbChat
let privateChatPeerId: InputPeer
let context: FunctionContext
let userCounter = 0

const nextEmail = (prefix: string) => {
  userCounter += 1
  return `${prefix}-${process.pid}-${userCounter}@example.com`
}

describe("markAsUnread", () => {
  setupTestLifecycle()

  beforeEach(async () => {
    currentUser = (await testUtils.createUser(nextEmail("mark-unread-current-user")))!
    otherUser = (await testUtils.createUser(nextEmail("mark-unread-other-user")))!
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

  test("readMessages (empty chat) should persist unreadMark cleared in user bucket", async () => {
    // Ensure unreadMark is true.
    await markAsUnread({ peer: privateChatPeerId }, context)

    // Capture current latest user update seq after markAsUnread persistence.
    const [beforeRow] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, currentUser.id)))
      .orderBy(desc(updates.seq))
      .limit(1)

    const beforeSeq = beforeRow?.seq ?? 0

    // Call readMessages without maxId; for an empty chat, this hits the branch that clears unreadMark.
    await readMessagesHandler(
      { peerThreadId: privateChat.id.toString() },
      {
        currentUserId: currentUser.id,
        currentSessionId: 1,
        ip: undefined,
      },
    )

    const [afterRow] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, currentUser.id)))
      .orderBy(desc(updates.seq))
      .limit(1)

    expect(afterRow).toBeTruthy()
    expect(afterRow!.seq).toBeGreaterThan(beforeSeq)

    const decrypted = UpdatesModel.decrypt(afterRow!)
    expect(decrypted.payload.update.oneofKind).toBe("userMarkAsUnread")
    if (decrypted.payload.update.oneofKind === "userMarkAsUnread") {
      expect(decrypted.payload.update.userMarkAsUnread.unreadMark).toBe(false)
    }
  })
}) 
