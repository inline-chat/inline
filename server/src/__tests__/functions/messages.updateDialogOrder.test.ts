import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import type { InputPeer } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { dialogs } from "@in/server/db/schema"
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
})
