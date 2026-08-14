import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { db, schema } from "@in/server/db"
import { deleteChat, deleteEmptyUntitledThreadAfterClose } from "@in/server/functions/messages.deleteChat"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { setupTestLifecycle, testUtils } from "../setup"

const inputPeerForChat = (chatId: number) => ({
  type: {
    oneofKind: "chat" as const,
    chat: { chatId: BigInt(chatId) },
  },
})

describe("messages.deleteChat", () => {
  setupTestLifecycle()

  test("deleting a source chat deletes materialized backlink messages", async () => {
    const currentUser = await testUtils.createUser("delete-chat-graph-owner@example.com")
    const source = await testUtils.createChat(null, "Delete Chat Link Source", "thread", false, currentUser.id)
    const target = await testUtils.createChat(null, "Delete Chat Link Target", "thread", false, currentUser.id)
    if (!source || !target) {
      throw new Error("Graph delete-chat test chats not created")
    }

    await testUtils.addParticipant(source.id, currentUser.id)
    await testUtils.addParticipant(target.id, currentUser.id)

    const sent = await sendMessage(
      {
        peerId: inputPeerForChat(source.id),
        message: "see target",
        entities: {
          entities: [
            {
              type: MessageEntity_Type.THREAD,
              offset: 4n,
              length: 6n,
              entity: {
                oneofKind: "thread",
                thread: { chatId: BigInt(target.id) },
              },
            },
          ],
        },
      },
      testUtils.functionContext({ userId: currentUser.id }),
    )

    const sentMessageId =
      sent.updates[0]?.update.oneofKind === "updateMessageId"
        ? sent.updates[0].update.updateMessageId.messageId
        : undefined
    expect(sentMessageId).toBeTruthy()

    const backlinkMessageGlobalId = await waitForThreadBacklink({
      fromChatId: source.id,
      fromMessageId: Number(sentMessageId),
      toChatId: target.id,
    })

    await deleteChat(
      {
        peer: inputPeerForChat(source.id),
      },
      testUtils.functionContext({ userId: currentUser.id }),
    )

    const backlinkMessages = await db
      .select({ globalId: schema.messages.globalId })
      .from(schema.messages)
      .where(eq(schema.messages.globalId, backlinkMessageGlobalId))
    expect(backlinkMessages).toHaveLength(0)
  })

  test("conditionally deletes a closed empty anchored reply thread", async () => {
    const currentUser = await testUtils.createUser("delete-closed-reply-thread-owner@example.com")
    const parent = await testUtils.createChat(null, "Parent", "thread", false, currentUser.id)
    const replyThread = await testUtils.createChat(null, "", "thread", false, currentUser.id)
    if (!parent || !replyThread) {
      throw new Error("Conditional delete test chats not created")
    }

    await testUtils.addParticipant(parent.id, currentUser.id)
    await testUtils.addParticipant(replyThread.id, currentUser.id)
    await db.insert(schema.messages).values({
      chatId: parent.id,
      messageId: 1,
      fromId: currentUser.id,
      text: "parent message",
    })
    await db
      .update(schema.chats)
      .set({ isUntitled: true, parentChatId: parent.id, parentMessageId: 1 })
      .where(eq(schema.chats.id, replyThread.id))
    await db.insert(schema.dialogs).values({
      chatId: replyThread.id,
      userId: currentUser.id,
      open: false,
    })

    await deleteEmptyUntitledThreadAfterClose(
      replyThread.id,
      testUtils.functionContext({ userId: currentUser.id }),
    )

    const [savedReplyThread] = await db
      .select()
      .from(schema.chats)
      .where(eq(schema.chats.id, replyThread.id))
      .limit(1)
    const [savedParentMessage] = await db
      .select()
      .from(schema.messages)
      .where(and(eq(schema.messages.chatId, parent.id), eq(schema.messages.messageId, 1)))
      .limit(1)

    expect(savedReplyThread).toBeUndefined()
    expect(savedParentMessage).toBeDefined()
  })

  test("conditional cleanup retains a closed thread that gained a message", async () => {
    const currentUser = await testUtils.createUser("retain-active-closed-thread-owner@example.com")
    const thread = await testUtils.createChat(null, "", "thread", false, currentUser.id)
    if (!thread) {
      throw new Error("Conditional retain test chat not created")
    }

    await testUtils.addParticipant(thread.id, currentUser.id)
    await db.update(schema.chats).set({ isUntitled: true }).where(eq(schema.chats.id, thread.id))
    await db.insert(schema.dialogs).values({
      chatId: thread.id,
      userId: currentUser.id,
      open: false,
    })
    await db.insert(schema.messages).values({
      chatId: thread.id,
      messageId: 1,
      fromId: currentUser.id,
      text: "arrived before cleanup",
    })

    await deleteEmptyUntitledThreadAfterClose(
      thread.id,
      testUtils.functionContext({ userId: currentUser.id }),
    )

    const [savedThread] = await db.select().from(schema.chats).where(eq(schema.chats.id, thread.id)).limit(1)
    expect(savedThread).toBeDefined()
  })
})

async function waitForThreadBacklink(input: {
  fromChatId: number
  fromMessageId: number
  toChatId: number
}): Promise<bigint> {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const [link] = await db
      .select()
      .from(schema.threadGraphLinks)
      .where(
        and(
          eq(schema.threadGraphLinks.kind, "thread_link"),
          eq(schema.threadGraphLinks.fromChatId, input.fromChatId),
          eq(schema.threadGraphLinks.fromMessageId, input.fromMessageId),
          eq(schema.threadGraphLinks.toChatId, input.toChatId),
        ),
      )
      .limit(1)

    if (link?.backlinkMessageGlobalId) {
      return link.backlinkMessageGlobalId
    }

    await new Promise((resolve) => setTimeout(resolve, 10))
  }

  throw new Error(`Expected graph backlink for message ${input.fromChatId}:${input.fromMessageId}`)
}
