import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import type { InputPeer } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { dialogFolders, dialogs } from "@in/server/db/schema"
import { updateDialogOrder } from "@in/server/functions/messages.updateDialogOrder"
import { setupTestLifecycle, testUtils } from "../setup"

describe("messages.updateDialogOrder", () => {
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

  test("updates normal sidebar order", async () => {
    const userA = await testUtils.createUser("dialog-order-a@example.com")
    const userB = await testUtils.createUser("dialog-order-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })

    const result = await updateDialogOrder(
      {
        peerId: peerUser(userB.id),
        order: "m",
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )

    expect(result.dialog.order).toBe("m")

    const [dialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .limit(1)

    expect(dialog?.order).toBe("m")
  })

  test("rejects invalid order keys", async () => {
    const userA = await testUtils.createUser("dialog-order-invalid-a@example.com")
    const userB = await testUtils.createUser("dialog-order-invalid-b@example.com")
    await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })

    await expect(
      updateDialogOrder(
        {
          peerId: peerUser(userB.id),
          order: "bad-key",
        },
        testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
      ),
    ).rejects.toThrow()
  })

  test("updates pinned sidebar order without touching normal order", async () => {
    const userA = await testUtils.createUser("dialog-pinned-order-a@example.com")
    const userB = await testUtils.createUser("dialog-pinned-order-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })

    await db
      .update(dialogs)
      .set({ order: "a", pinned: true, pinnedOrder: "b" })
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))

    const result = await updateDialogOrder(
      {
        peerId: peerUser(userB.id),
        pinnedOrder: "z",
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )

    expect(result.dialog.order).toBe("a")
    expect(result.dialog.pinnedOrder).toBe("z")

    const [dialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .limit(1)

    expect(dialog?.order).toBe("a")
    expect(dialog?.pinnedOrder).toBe("z")
  })

  test("pins dialog while assigning pinned order", async () => {
    const userA = await testUtils.createUser("dialog-order-pin-a@example.com")
    const userB = await testUtils.createUser("dialog-order-pin-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })

    await db
      .update(dialogs)
      .set({ open: false, order: "a", pinned: false, archived: true, chatListHidden: true })
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))

    const result = await updateDialogOrder(
      {
        peerId: peerUser(userB.id),
        pinned: true,
        pinnedOrder: "p",
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )

    expect(result.dialog.pinned).toBe(true)
    expect(result.dialog.open).toBe(true)
    expect(result.dialog.order).toBe("a")
    expect(result.dialog.pinnedOrder).toBe("p")

    const [dialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .limit(1)

    expect(dialog?.pinned).toBe(true)
    expect(dialog?.open).toBe(true)
    expect(dialog?.archived).toBe(false)
    expect(dialog?.chatListHidden).toBe(null)
    expect(dialog?.pinnedOrder).toBe("p")
  })

  test("unpins dialog and keeps it open in normal sidebar order", async () => {
    const userA = await testUtils.createUser("dialog-order-unpin-a@example.com")
    const userB = await testUtils.createUser("dialog-order-unpin-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })

    await db
      .update(dialogs)
      .set({ open: false, order: null, pinned: true, pinnedOrder: "p", archived: true, chatListHidden: true })
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))

    const result = await updateDialogOrder(
      {
        peerId: peerUser(userB.id),
        pinned: false,
        order: "n",
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )

    expect(result.dialog.pinned).toBe(false)
    expect(result.dialog.open).toBe(true)
    expect(result.dialog.order).toBe("n")

    const [dialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .limit(1)

    expect(dialog?.pinned).toBe(false)
    expect(dialog?.open).toBe(true)
    expect(dialog?.order).toBe("n")
    expect(dialog?.archived).toBe(false)
    expect(dialog?.chatListHidden).toBe(null)
  })

  test("serializes derived normal and pinned order allocation across concurrent pins", async () => {
    const userA = await testUtils.createUser("dialog-order-concurrent-a@example.com")
    const userB = await testUtils.createUser("dialog-order-concurrent-b@example.com")
    const chatsToPin = []

    for (let index = 0; index < 4; index += 1) {
      const chat = await testUtils.createChat(null, `Concurrent pin ${index}`, "thread", false, userA.id)
      if (!chat) throw new Error("Failed to create concurrent-pin chat")
      await testUtils.addParticipant(chat.id, userA.id)
      await testUtils.addParticipant(chat.id, userB.id)
      await db.insert(dialogs).values({ chatId: chat.id, userId: userA.id, open: true })
      chatsToPin.push(chat)
    }

    const results = await Promise.all(
      chatsToPin.map((chat) =>
        updateDialogOrder(
          { peerId: peerThread(chat.id), pinned: true },
          testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
        ),
      ),
    )
    const pinnedOrders = results.map((result) => result.dialog.pinnedOrder)

    expect(new Set(pinnedOrders).size).toBe(pinnedOrders.length)
  })

  test("moves a DM into a folder and pinning moves it back to the root", async () => {
    const userA = await testUtils.createUser("dialog-order-folder-a@example.com")
    const userB = await testUtils.createUser("dialog-order-folder-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })
    const [folder] = await db
      .insert(dialogFolders)
      .values({ userId: userA.id, title: null, order: "a" })
      .returning()
    if (!folder) throw new Error("Failed to create folder")

    const moved = await updateDialogOrder(
      {
        peerId: peerUser(userB.id),
        destination: { destination: { oneofKind: "folderId", folderId: BigInt(folder.id) } },
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )
    expect(moved.dialog.folderId).toBe(BigInt(folder.id))
    expect(moved.dialog.open).toBe(true)
    expect(moved.dialog.pinned).toBe(false)

    const pinned = await updateDialogOrder(
      { peerId: peerUser(userB.id), pinned: true },
      testUtils.functionContext({ userId: userA.id, sessionId: 11 }),
    )
    expect(pinned.dialog.folderId).toBeUndefined()

    const [stored] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
    expect(stored?.folderId).toBeNull()
  })
})
