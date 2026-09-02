import { describe, test, expect, beforeEach } from "bun:test"
import { InputPeer } from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "../setup"
import { markAsUnread } from "@in/server/functions/messages.markAsUnread"
import type { DbChat, DbUser } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { db } from "@in/server/db"
import { chats, dialogs, messages, updates, UpdateBucket } from "@in/server/db/schema"
import { and, desc, eq, sql } from "drizzle-orm"
import { handler as readMessagesHandler } from "@in/server/methods/readMessages"
import { readMessages } from "@in/server/functions/messages.readMessages"
import { UpdatesModel } from "@in/server/db/models/updates"
import { getMessages } from "@in/server/functions/messages.getMessages"

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

const waitForDialogMutationWaiters = async (minimum: number) => {
  const deadline = Date.now() + 5_000
  while (Date.now() < deadline) {
    const rows = await db.execute<{ count: number }>(sql`
      SELECT count(*)::int AS count
      FROM pg_stat_activity
      WHERE pid <> pg_backend_pid()
        AND wait_event_type = 'Lock'
        AND (query ILIKE '%dialogs%' OR query ILIKE '%users%')
    `)
    if (Number(rows[0]?.count ?? 0) >= minimum) return
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  throw new Error(`Timed out waiting for ${minimum} dialog mutation lock waiters`)
}

const holdDialogRowLock = async (chatId: number, userId: number) => {
  let release!: () => void
  const released = new Promise<void>((resolve) => {
    release = resolve
  })
  let locked!: () => void
  const lockAcquired = new Promise<void>((resolve) => {
    locked = resolve
  })

  const transaction = db.transaction(async (tx) => {
    await tx
      .select({ id: dialogs.id })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chatId), eq(dialogs.userId, userId)))
      .for("update")
      .limit(1)
    locked()
    await released
  })

  await lockAcquired
  return { release, transaction }
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

  test("markAsUnread rejects revoked thread access without changing a stale dialog", async () => {
    const inaccessible = await testUtils.createChat(null, "Revoked unread thread", "thread", false, otherUser.id)
    if (!inaccessible) throw new Error("Failed to create inaccessible thread")
    await testUtils.addParticipant(inaccessible.id, otherUser.id)
    await db.insert(dialogs).values({
      chatId: inaccessible.id,
      userId: currentUser.id,
      open: false,
      unreadMark: false,
    })
    const peer: InputPeer = {
      type: { oneofKind: "chat", chat: { chatId: BigInt(inaccessible.id) } },
    }

    await expect(markAsUnread({ peer }, context)).rejects.toThrow()

    const [staleDialog] = await db
      .select({ unreadMark: dialogs.unreadMark })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, inaccessible.id), eq(dialogs.userId, currentUser.id)))
      .limit(1)
    expect(staleDialog?.unreadMark).toBe(false)
  })

  test("readMessages rejects revoked thread access without changing a stale dialog", async () => {
    const inaccessible = await testUtils.createChat(null, "Revoked read thread", "thread", false, otherUser.id)
    if (!inaccessible) throw new Error("Failed to create inaccessible thread")
    await testUtils.addParticipant(inaccessible.id, otherUser.id)
    await db.insert(dialogs).values({
      chatId: inaccessible.id,
      userId: currentUser.id,
      open: false,
      unreadMark: true,
      readInboxMaxId: 0,
    })
    const peer: InputPeer = {
      type: { oneofKind: "chat", chat: { chatId: BigInt(inaccessible.id) } },
    }

    await expect(readMessages({ peer, maxId: 1 }, context)).rejects.toThrow()

    const [staleDialog] = await db
      .select({ unreadMark: dialogs.unreadMark, readInboxMaxId: dialogs.readInboxMaxId })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, inaccessible.id), eq(dialogs.userId, currentUser.id)))
      .limit(1)
    expect(staleDialog).toMatchObject({ unreadMark: true, readInboxMaxId: 0 })
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

  test("concurrent reads keep the highest read watermark", async () => {
    await db
      .update(dialogs)
      .set({ readInboxMaxId: 0, unreadMark: false })
      .where(and(eq(dialogs.chatId, privateChat.id), eq(dialogs.userId, currentUser.id)))

    const lock = await holdDialogRowLock(privateChat.id, currentUser.id)
    const highRead = readMessages(
      { peer: privateChatPeerId, maxId: 100 },
      context,
    )
    await waitForDialogMutationWaiters(1)
    const lowRead = readMessages(
      { peer: privateChatPeerId, maxId: 50 },
      context,
    )
    await waitForDialogMutationWaiters(2)

    lock.release()
    await Promise.all([lock.transaction, highRead, lowRead])

    const [dialog] = await db
      .select({ readInboxMaxId: dialogs.readInboxMaxId })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, privateChat.id), eq(dialogs.userId, currentUser.id)))
      .limit(1)
    expect(dialog?.readInboxMaxId).toBe(100)
  })

  test("a read serialized after mark-as-unread clears the mark it observed", async () => {
    await db
      .update(dialogs)
      .set({ readInboxMaxId: 1, unreadMark: false })
      .where(and(eq(dialogs.chatId, privateChat.id), eq(dialogs.userId, currentUser.id)))

    const lock = await holdDialogRowLock(privateChat.id, currentUser.id)
    const mark = markAsUnread({ peer: privateChatPeerId }, context)
    await waitForDialogMutationWaiters(1)
    const read = readMessages(
      {
        peer: privateChatPeerId,
        maxId: 1,
      },
      context,
    )
    await waitForDialogMutationWaiters(2)

    lock.release()
    const [, readResult] = await Promise.all([mark, read])

    const [dialog] = await db
      .select({ unreadMark: dialogs.unreadMark })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, privateChat.id), eq(dialogs.userId, currentUser.id)))
      .limit(1)
    expect(dialog?.unreadMark).toBe(false)
    expect(readResult.updates[0]?.update.oneofKind).toBe("markAsUnread")

    const [latestUpdate] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, currentUser.id)))
      .orderBy(desc(updates.seq))
      .limit(1)
    expect(UpdatesModel.decrypt(latestUpdate!).payload.update.oneofKind).toBe("userMarkAsUnread")
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

  test("reply-thread parent replies summary updates when unread state changes", async () => {
    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, currentUser.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, currentUser.id)
    await testUtils.addParticipant(parentChat.id, otherUser.id)

    await db.insert(messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: otherUser.id,
      text: "anchor",
    })
    await db.update(chats).set({ lastMsgId: 1 }).where(eq(chats.id, parentChat.id))

    const [childChat] = await db
      .insert(chats)
      .values({
        type: "thread",
        title: "Re: anchor",
        publicThread: false,
        createdBy: currentUser.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!childChat) {
      throw new Error("Child chat not created")
    }

    await db.insert(dialogs).values({
      chatId: childChat.id,
      userId: currentUser.id,
      readInboxMaxId: 1,
      unreadMark: false,
    })

    await db.insert(messages).values({
      chatId: childChat.id,
      messageId: 1,
      fromId: otherUser.id,
      text: "reply",
    })
    await db.update(chats).set({ lastMsgId: 1 }).where(eq(chats.id, childChat.id))

    const initialParentMessages = await getMessages(
      {
        peerId: {
          type: { oneofKind: "chat", chat: { chatId: BigInt(parentChat.id) } },
        },
        messageIds: [1n],
      },
      context,
    )

    expect(initialParentMessages.messages[0]?.replies?.hasUnread).toBe(false)

    const [beforeMarkRow] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, parentChat.id)))
      .orderBy(desc(updates.seq))
      .limit(1)

    const childPeerId: InputPeer = {
      type: { oneofKind: "chat" as const, chat: { chatId: BigInt(childChat.id) } },
    }

    await markAsUnread({ peer: childPeerId }, context)

    const afterMarkParentMessages = await getMessages(
      {
        peerId: {
          type: { oneofKind: "chat", chat: { chatId: BigInt(parentChat.id) } },
        },
        messageIds: [1n],
      },
      context,
    )

    expect(afterMarkParentMessages.messages[0]?.replies?.hasUnread).toBe(true)

    const [afterMarkRow] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, parentChat.id)))
      .orderBy(desc(updates.seq))
      .limit(1)

    expect(afterMarkRow).toBeTruthy()
    expect(afterMarkRow!.seq).toBeGreaterThan(beforeMarkRow?.seq ?? 0)

    const decryptedAfterMark = UpdatesModel.decrypt(afterMarkRow!)
    expect(decryptedAfterMark.payload.update.oneofKind).toBe("editMessage")
    if (decryptedAfterMark.payload.update.oneofKind === "editMessage") {
      expect(Number(decryptedAfterMark.payload.update.editMessage.chatId)).toBe(parentChat.id)
      expect(Number(decryptedAfterMark.payload.update.editMessage.msgId)).toBe(1)
    }

    await readMessagesHandler(
      {
        peerThreadId: childChat.id.toString(),
      },
      {
        currentUserId: currentUser.id,
        currentSessionId: 1,
        ip: undefined,
      },
    )

    const afterReadParentMessages = await getMessages(
      {
        peerId: {
          type: { oneofKind: "chat", chat: { chatId: BigInt(parentChat.id) } },
        },
        messageIds: [1n],
      },
      context,
    )

    expect(afterReadParentMessages.messages[0]?.replies?.hasUnread).toBe(false)

    const [afterReadRow] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, parentChat.id)))
      .orderBy(desc(updates.seq))
      .limit(1)

    expect(afterReadRow).toBeTruthy()
    expect(afterReadRow!.seq).toBeGreaterThan(afterMarkRow!.seq)
  })
}) 
