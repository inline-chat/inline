import { describe, expect, test } from "bun:test"
import { DialogFollowMode } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { chats, dialogs, messages } from "@in/server/db/schema"
import { updateDialogFollowMode } from "@in/server/functions/messages.updateDialogFollowMode"
import { and, eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

describe("messages.updateDialogFollowMode", () => {
  setupTestLifecycle()

  test("manual follow opens and shows the reply-thread dialog", async () => {
    const owner = await testUtils.createUser("follow-mode-owner@example.com")
    const participant = await testUtils.createUser("follow-mode-participant@example.com")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, owner.id)
    if (!parentChat) throw new Error("Parent chat not created")

    await testUtils.addParticipant(parentChat.id, owner.id)
    await testUtils.addParticipant(parentChat.id, participant.id)

    await db.insert(messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: owner.id,
      text: "anchor",
    })

    const [childChat] = await db
      .insert(chats)
      .values({
        type: "thread",
        title: "Re: anchor",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!childChat) throw new Error("Child chat not created")

    const followResult = await updateDialogFollowMode(
      {
        peerId: {
          type: { oneofKind: "chat", chat: { chatId: BigInt(childChat.id) } },
        },
        followMode: DialogFollowMode.FOLLOWING,
      },
      testUtils.functionContext({ userId: participant.id, sessionId: 1 }),
    )

    expect(followResult.updates.map((update) => update.update.oneofKind)).toEqual([
      "dialogFollowMode",
      "chatOpen",
    ])

    let [dialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, childChat.id), eq(dialogs.userId, participant.id)))
      .limit(1)

    expect(dialog?.followMode).toBe("following")
    expect(dialog?.chatListHidden).toBeNull()
    expect(dialog?.open).toBe(true)
    expect(dialog?.order).toBeTruthy()
    expect(dialog?.archived).toBe(false)

    const order = dialog?.order
    const unfollowResult = await updateDialogFollowMode(
      {
        peerId: {
          type: { oneofKind: "chat", chat: { chatId: BigInt(childChat.id) } },
        },
        followMode: DialogFollowMode.UNFOLLOWED,
      },
      testUtils.functionContext({ userId: participant.id, sessionId: 1 }),
    )

    expect(unfollowResult.updates.map((update) => update.update.oneofKind)).toEqual(["dialogFollowMode"])

    ;[dialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, childChat.id), eq(dialogs.userId, participant.id)))
      .limit(1)

    expect(dialog?.followMode).toBe("unfollowed")
    expect(dialog?.chatListHidden).toBeNull()
    expect(dialog?.open).toBe(true)
    expect(dialog?.order).toBe(order)
  })

  test("manual follow opens and shows a normal thread dialog", async () => {
    const owner = await testUtils.createUser("follow-mode-plain-owner@example.com")
    const chat = await testUtils.createChat(null, "Plain Thread", "thread", false, owner.id)
    if (!chat) throw new Error("Thread chat not created")

    await testUtils.addParticipant(chat.id, owner.id)

    const followResult = await updateDialogFollowMode(
      {
        peerId: {
          type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } },
        },
        followMode: DialogFollowMode.FOLLOWING,
      },
      testUtils.functionContext({ userId: owner.id, sessionId: 1 }),
    )

    expect(followResult.updates.map((update) => update.update.oneofKind)).toEqual([
      "dialogFollowMode",
      "chatOpen",
    ])

    const [dialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, owner.id)))
      .limit(1)

    expect(dialog?.followMode).toBe("following")
    expect(dialog?.chatListHidden).toBeNull()
    expect(dialog?.open).toBe(true)
    expect(dialog?.order).toBeTruthy()
    expect(dialog?.archived).toBe(false)
  })

  test("rejects follow mode on private chats", async () => {
    const owner = await testUtils.createUser("follow-mode-dm-owner@example.com")
    const other = await testUtils.createUser("follow-mode-dm-other@example.com")
    const chat = await testUtils.createPrivateChat(owner, other)
    if (!chat) throw new Error("Private chat not created")

    await expect(
      updateDialogFollowMode(
        {
          peerId: {
            type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } },
          },
          followMode: DialogFollowMode.FOLLOWING,
        },
        testUtils.functionContext({ userId: owner.id, sessionId: 1 }),
      ),
    ).rejects.toThrow()
  })
})
