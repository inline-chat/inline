import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { createSubthread } from "@in/server/functions/messages.createSubthread"
import { getChat } from "@in/server/functions/messages.getChat"
import { getMessages } from "@in/server/functions/messages.getMessages"
import { setupTestLifecycle, testUtils } from "../setup"

describe("messages.createSubthread", () => {
  setupTestLifecycle()

  test("creates a reply-thread subthread with anchor metadata and a hidden dialog for the opener", async () => {
    const creator = await testUtils.createUser("subthread-creator@example.com")
    const anchorAuthor = await testUtils.createUser("subthread-anchor-author@example.com")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, creator.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, creator.id)
    await testUtils.addParticipant(parentChat.id, anchorAuthor.id)

    await db.insert(schema.messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: anchorAuthor.id,
      text: "anchor",
    })
    await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, parentChat.id))

    const result = await createSubthread(
      {
        parentChatId: BigInt(parentChat.id),
        parentMessageId: 1n,
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    expect(result.chat.parentChatId).toBe(BigInt(parentChat.id))
    expect(result.chat.parentMessageId).toBe(1n)
    expect(result.anchorMessage?.id).toBe(1n)
    expect(result.dialog).toBeDefined()

    const childChatId = Number(result.chat.id)
    const childDialogs = await db
      .select({ userId: schema.dialogs.userId, sidebarVisible: schema.dialogs.sidebarVisible })
      .from(schema.dialogs)
      .where(eq(schema.dialogs.chatId, childChatId))

    expect(childDialogs).toEqual([
      {
        userId: creator.id,
        sidebarVisible: false,
      },
    ])

    const childChatUpdates = await db
      .select({ id: schema.updates.id })
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, schema.UpdateBucket.Chat), eq(schema.updates.entityId, childChatId)))

    expect(childChatUpdates).toHaveLength(0)

    const parentMessages = await getMessages(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(parentChat.id) },
          },
        },
        messageIds: [1n],
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    expect(parentMessages.messages[0]?.replies?.chatId).toBe(BigInt(childChatId))
    expect(parentMessages.messages[0]?.replies?.replyCount).toBe(0)
    expect(parentMessages.messages[0]?.replies?.recentReplierUserIds).toEqual([])
  })

  test("getChat creates a hidden dialog when opening a linked subthread", async () => {
    const creator = await testUtils.createUser("linked-subthread-owner@example.com")
    const participant = await testUtils.createUser("linked-subthread-participant@example.com")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, creator.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, creator.id)
    await testUtils.addParticipant(parentChat.id, participant.id)

    await db.insert(schema.messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: creator.id,
      text: "anchor",
    })
    await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, parentChat.id))

    const [childChat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Re: anchor",
        publicThread: false,
        createdBy: creator.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!childChat) {
      throw new Error("Child chat not created")
    }

    const result = await getChat(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(childChat.id) },
          },
        },
      },
      testUtils.functionContext({ userId: participant.id }),
    )

    expect(result.dialog?.chatId).toBe(BigInt(childChat.id))
    expect(result.dialog?.sidebarVisible).toBe(false)
    expect(result.anchorMessage?.id).toBe(1n)

    const existingDialog = await db
      .select()
      .from(schema.dialogs)
      .where(and(eq(schema.dialogs.chatId, childChat.id), eq(schema.dialogs.userId, participant.id)))
      .limit(1)
      .then((rows) => rows[0])

    expect(existingDialog?.sidebarVisible).toBe(false)
  })
})
