import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import type { InputPeer } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { chats, dialogs, messages, updates, UpdateBucket } from "@in/server/db/schema"
import { updateDialogOpen } from "@in/server/functions/messages.updateDialogOpen"
import { setupTestLifecycle, testUtils } from "../setup"

describe("messages.updateDialogOpen", () => {
  setupTestLifecycle()

  const peerUser = (userId: number): InputPeer => ({
    type: {
      oneofKind: "user",
      user: { userId: BigInt(userId) },
    },
  })

  const peerThread = (chatId: number): InputPeer => ({
    type: {
      oneofKind: "chat",
      chat: { chatId: BigInt(chatId) },
    },
  })

  const markUntitledThread = async (chatId: number) => {
    await db.update(chats).set({ isUntitled: true }).where(eq(chats.id, chatId))
  }

  test("opens and unarchives an existing dialog without unhiding it", async () => {
    const userA = await testUtils.createUser("dialog-open-a@example.com")
    const userB = await testUtils.createUser("dialog-open-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })

    await db
      .update(dialogs)
      .set({ archived: true, chatListHidden: true, open: false, openedDate: null })
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))

    const result = await updateDialogOpen(
      {
        peerId: peerUser(userB.id),
        open: true,
        order: "m",
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )

    expect(result.dialog?.open).toBe(true)
    expect(result.dialog?.archived).toBe(false)
    expect(result.dialog?.chatListHidden).toBe(true)
    expect(result.dialog?.order).toBe("m")

    const [dialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .limit(1)

    expect(dialog?.open).toBe(true)
    expect(dialog?.archived).toBe(false)
    expect(dialog?.chatListHidden).toBe(true)
    expect(dialog?.order).toBe("m")

    const userUpdates = await db
      .select({ id: updates.id })
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, userA.id)))

    expect(userUpdates).toHaveLength(0)
  })

  test("preserves order when an already-open dialog is reopened", async () => {
    const userA = await testUtils.createUser("dialog-open-existing-a@example.com")
    const userB = await testUtils.createUser("dialog-open-existing-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })
    const order = "P"

    await db
      .update(dialogs)
      .set({ archived: true, chatListHidden: true, open: true, order })
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))

    await updateDialogOpen(
      {
        peerId: peerUser(userB.id),
        open: true,
        order: "z",
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )

    const [dialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .limit(1)

    expect(dialog?.open).toBe(true)
    expect(dialog?.archived).toBe(false)
    expect(dialog?.chatListHidden).toBe(true)
    expect(dialog?.order).toBe(order)
  })

  test("rejects invalid order keys", async () => {
    const userA = await testUtils.createUser("dialog-open-invalid-a@example.com")
    const userB = await testUtils.createUser("dialog-open-invalid-b@example.com")
    await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })

    await expect(
      updateDialogOpen(
        {
          peerId: peerUser(userB.id),
          open: true,
          order: "bad-key",
        },
        testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
      ),
    ).rejects.toThrow()
  })

  test("creates missing private dialogs when opening", async () => {
    const userA = await testUtils.createUser("dialog-open-missing-a@example.com")
    const userB = await testUtils.createUser("dialog-open-missing-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: false,
      createDialogForUserB: false,
    })

    await updateDialogOpen(
      {
        peerId: peerUser(userB.id),
        open: true,
        order: "m",
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )

    const [dialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .limit(1)

    expect(dialog?.open).toBe(true)
    expect(dialog?.order).toBe("m")
    expect(dialog?.peerUserId).toBe(userB.id)
    expect(dialog?.archived).toBe(false)
    expect(dialog?.chatListHidden).toBeNull()
  })

  test("creates missing reply-thread dialogs hidden when opening", async () => {
    const userA = await testUtils.createUser("dialog-open-reply-thread-a@example.com")
    const userB = await testUtils.createUser("dialog-open-reply-thread-b@example.com")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, userA.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, userA.id)
    await testUtils.addParticipant(parentChat.id, userB.id)

    await db.insert(messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: userB.id,
      text: "anchor",
    })

    const [childChat] = await db
      .insert(chats)
      .values({
        type: "thread",
        title: null,
        publicThread: false,
        createdBy: userA.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!childChat) {
      throw new Error("Child chat not created")
    }

    await updateDialogOpen(
      {
        peerId: peerThread(childChat.id),
        open: true,
        order: "m",
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )

    const [dialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, childChat.id), eq(dialogs.userId, userA.id)))
      .limit(1)

    expect(dialog?.open).toBe(true)
    expect(dialog?.order).toBe("m")
    expect(dialog?.chatListHidden).toBe(true)
  })

  test("closes open dialogs and clears openedDate and order", async () => {
    const userA = await testUtils.createUser("dialog-close-a@example.com")
    const userB = await testUtils.createUser("dialog-close-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })

    await db
      .update(dialogs)
      .set({ open: true, openedDate: new Date("2026-01-02T03:04:05.000Z"), order: "m" })
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))

    const result = await updateDialogOpen(
      {
        peerId: peerUser(userB.id),
        open: false,
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )

    expect(result.dialog?.open).toBe(false)
    expect(result.dialog?.openedDate).toBeUndefined()
    expect(result.dialog?.order).toBeUndefined()

    const [dialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .limit(1)

    expect(dialog?.open).toBe(false)
    expect(dialog?.openedDate).toBeNull()
    expect(dialog?.order).toBeNull()
  })

  test("records explicit close for null open state without emitting a change", async () => {
    const userA = await testUtils.createUser("dialog-close-default-a@example.com")
    const userB = await testUtils.createUser("dialog-close-default-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })

    await db
      .update(dialogs)
      .set({ open: null, openedDate: null })
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))

    const updatesBefore = await db
      .select({ id: updates.id })
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, userA.id)))

    const result = await updateDialogOpen(
      {
        peerId: peerUser(userB.id),
        open: false,
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )

    expect(result.dialog?.open).toBe(false)

    const [dialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .limit(1)

    expect(dialog?.open).toBe(false)
    expect(dialog?.openedDate).toBeNull()

    const updatesAfter = await db
      .select({ id: updates.id })
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, userA.id)))

    expect(updatesAfter.length).toBe(updatesBefore.length)
  })

  test("deletes own empty untitled thread when closing sidebar item", async () => {
    const userA = await testUtils.createUser("dialog-close-empty-thread-a@example.com")
    const userB = await testUtils.createUser("dialog-close-empty-thread-b@example.com")
    const chat = await testUtils.createChat(null, "", "thread", false, userA.id)
    if (!chat) {
      throw new Error("Failed to create empty thread")
    }

    await markUntitledThread(chat.id)
    await testUtils.addParticipant(chat.id, userA.id)
    await testUtils.addParticipant(chat.id, userB.id)
    await db.insert(dialogs).values({
      chatId: chat.id,
      userId: userA.id,
      open: true,
      order: "m",
    })

    const result = await updateDialogOpen(
      {
        peerId: peerThread(chat.id),
        open: false,
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )

    expect(result.deletedChat).toBe(true)
    expect(result.chat?.id).toBe(BigInt(chat.id))
    expect(result.dialog?.open).toBe(false)

    const [savedChat] = await db.select().from(chats).where(eq(chats.id, chat.id)).limit(1)
    const [savedDialog] = await db.select().from(dialogs).where(eq(dialogs.chatId, chat.id)).limit(1)
    const [chatUpdate] = await db
      .select({ id: updates.id })
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, chat.id)))
      .limit(1)

    expect(savedChat).toBeUndefined()
    expect(savedDialog).toBeUndefined()
    expect(chatUpdate).toBeDefined()
  })

  test("does not delete blank thread without untitled flag when closing", async () => {
    const userA = await testUtils.createUser("dialog-close-blank-titled-thread-a@example.com")
    const userB = await testUtils.createUser("dialog-close-blank-titled-thread-b@example.com")
    const chat = await testUtils.createChat(null, "", "thread", false, userA.id)
    if (!chat) {
      throw new Error("Failed to create blank-titled thread")
    }

    await testUtils.addParticipant(chat.id, userA.id)
    await testUtils.addParticipant(chat.id, userB.id)
    await db.insert(dialogs).values({
      chatId: chat.id,
      userId: userA.id,
      open: true,
      order: "m",
    })

    const result = await updateDialogOpen(
      {
        peerId: peerThread(chat.id),
        open: false,
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )

    expect(result.deletedChat).toBeUndefined()
    expect(result.dialog?.open).toBe(false)

    const [savedChat] = await db.select().from(chats).where(eq(chats.id, chat.id)).limit(1)
    const [savedDialog] = await db.select().from(dialogs).where(eq(dialogs.chatId, chat.id)).limit(1)

    expect(savedChat).toBeDefined()
    expect(savedDialog?.open).toBe(false)
  })

  test("does not delete pinned empty untitled thread when closing", async () => {
    const userA = await testUtils.createUser("dialog-close-pinned-empty-thread-a@example.com")
    const userB = await testUtils.createUser("dialog-close-pinned-empty-thread-b@example.com")
    const chat = await testUtils.createChat(null, "", "thread", false, userA.id)
    if (!chat) {
      throw new Error("Failed to create pinned empty thread")
    }

    await markUntitledThread(chat.id)
    await testUtils.addParticipant(chat.id, userA.id)
    await testUtils.addParticipant(chat.id, userB.id)
    await db.insert(dialogs).values({
      chatId: chat.id,
      userId: userA.id,
      open: true,
      pinned: true,
      order: "m",
    })

    const result = await updateDialogOpen(
      {
        peerId: peerThread(chat.id),
        open: false,
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )

    expect(result.deletedChat).toBeUndefined()
    expect(result.dialog?.open).toBe(false)

    const [savedChat] = await db.select().from(chats).where(eq(chats.id, chat.id)).limit(1)
    const [savedDialog] = await db.select().from(dialogs).where(eq(dialogs.chatId, chat.id)).limit(1)

    expect(savedChat).toBeDefined()
    expect(savedDialog?.open).toBe(false)
    expect(savedDialog?.pinned).toBe(true)
  })

  test("does not delete untitled thread with message rows when closing", async () => {
    const userA = await testUtils.createUser("dialog-close-nonempty-thread-a@example.com")
    const userB = await testUtils.createUser("dialog-close-nonempty-thread-b@example.com")
    const chat = await testUtils.createChat(null, "", "thread", false, userA.id)
    if (!chat) {
      throw new Error("Failed to create nonempty thread")
    }

    await markUntitledThread(chat.id)
    await testUtils.addParticipant(chat.id, userA.id)
    await testUtils.addParticipant(chat.id, userB.id)
    await db.insert(dialogs).values({
      chatId: chat.id,
      userId: userA.id,
      open: true,
      order: "m",
    })
    await db.insert(messages).values({
      chatId: chat.id,
      messageId: 1,
      fromId: userA.id,
      text: "message",
    })

    const result = await updateDialogOpen(
      {
        peerId: peerThread(chat.id),
        open: false,
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )

    expect(result.deletedChat).toBeUndefined()
    expect(result.dialog?.open).toBe(false)

    const [savedChat] = await db.select().from(chats).where(eq(chats.id, chat.id)).limit(1)
    const [savedDialog] = await db.select().from(dialogs).where(eq(dialogs.chatId, chat.id)).limit(1)

    expect(savedChat).toBeDefined()
    expect(savedDialog?.open).toBe(false)
  })
})
