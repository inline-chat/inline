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

    expect(result.dialog.open).toBe(true)
    expect(result.dialog.archived).toBe(false)
    expect(result.dialog.chatListHidden).toBe(true)
    expect(result.dialog.order).toBe("m")

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

    expect(result.dialog.open).toBe(false)
    expect(result.dialog.openedDate).toBeUndefined()
    expect(result.dialog.order).toBeUndefined()

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

    expect(result.dialog.open).toBe(false)

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
})
