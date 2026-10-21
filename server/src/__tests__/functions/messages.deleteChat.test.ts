import { describe, expect, spyOn, test } from "bun:test"
import { and, eq, inArray } from "drizzle-orm"
import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { db, schema } from "@in/server/db"
import { deleteChat, deleteEmptyUntitledThreadAfterClose } from "@in/server/functions/messages.deleteChat"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { setupTestLifecycle, testUtils } from "../setup"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { RealtimeRpcError } from "@in/server/realtime/errors"

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

  test("fans out child-thread deletion to its effective recipients", async () => {
    const owner = await testUtils.createUser("delete-child-owner@example.com")
    const participant = await testUtils.createUser("delete-child-participant@example.com")
    if (!owner || !participant) throw new Error("Delete child users not created")
    const parent = await testUtils.createChat(null, "Delete Child Parent", "thread", false, owner.id)
    if (!parent) throw new Error("Delete child parent not created")
    await testUtils.addParticipant(parent.id, owner.id)
    await testUtils.addParticipant(parent.id, participant.id)
    await db.insert(schema.messages).values({ chatId: parent.id, messageId: 1, fromId: owner.id, text: "anchor" })
    const [child] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Delete Child",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parent.id,
        parentMessageId: 1,
      })
      .returning()
    if (!child) throw new Error("Delete child not created")

    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    try {
      await deleteChat(
        { peer: inputPeerForChat(child.id) },
        testUtils.functionContext({ userId: owner.id }),
      )

      const deleteRecipients = push.mock.calls.flatMap(([userId, updates]) =>
        updates.some((update) => update.update.oneofKind === "deleteChat") ? [userId] : []
      )
      expect(new Set(deleteRecipients)).toEqual(new Set([owner.id, participant.id]))
    } finally {
      push.mockRestore()
    }
  })

  test("a creator removed from a private space thread cannot delete it", async () => {
    const space = await testUtils.createSpace("Delete Removed Creator Space")
    if (!space) throw new Error("Failed to create space")
    const creator = await testUtils.createUser("delete-removed-creator@example.com")
    const remaining = await testUtils.createUser("delete-removed-creator-remaining@example.com")
    await db.insert(schema.members).values([
      { userId: creator.id, spaceId: space.id, role: "member" },
      { userId: remaining.id, spaceId: space.id, role: "member" },
    ])
    const chat = await createThreadWithMessage(space.id, "Removed Creator Thread", creator.id, [creator.id, remaining.id])

    // Removed from the thread, still a member of the Space.
    await removeParticipant(chat.id, creator.id)

    await expect(
      deleteChat({ peer: inputPeerForChat(chat.id) }, testUtils.functionContext({ userId: creator.id })),
    ).rejects.toBeInstanceOf(RealtimeRpcError)
    await expectThreadIntact(chat.id, [remaining.id])
  })

  test("a creator removed from a home thread cannot delete it", async () => {
    const creator = await testUtils.createUser("delete-removed-home-creator@example.com")
    const remaining = await testUtils.createUser("delete-removed-home-remaining@example.com")
    const chat = await createThreadWithMessage(null, "Removed Home Thread", creator.id, [creator.id, remaining.id])

    await removeParticipant(chat.id, creator.id)

    await expect(
      deleteChat({ peer: inputPeerForChat(chat.id) }, testUtils.functionContext({ userId: creator.id })),
    ).rejects.toBeInstanceOf(RealtimeRpcError)
    await expectThreadIntact(chat.id, [remaining.id])
  })

  test("a current creator and a space admin can still delete threads", async () => {
    const space = await testUtils.createSpace("Delete Authority Space")
    if (!space) throw new Error("Failed to create space")
    const creator = await testUtils.createUser("delete-current-creator@example.com")
    const admin = await testUtils.createUser("delete-space-admin@example.com")
    await db.insert(schema.members).values([
      { userId: creator.id, spaceId: space.id, role: "member" },
      { userId: admin.id, spaceId: space.id, role: "admin" },
    ])
    const creatorThread = await createThreadWithMessage(space.id, "Creator Deletes", creator.id, [creator.id])
    // The admin is not a participant of this private thread.
    const adminThread = await createThreadWithMessage(space.id, "Admin Deletes", creator.id, [creator.id])
    const homeThread = await createThreadWithMessage(null, "Creator Deletes Home", creator.id, [creator.id])

    await deleteChat({ peer: inputPeerForChat(creatorThread.id) }, testUtils.functionContext({ userId: creator.id }))
    await deleteChat({ peer: inputPeerForChat(adminThread.id) }, testUtils.functionContext({ userId: admin.id }))
    await deleteChat({ peer: inputPeerForChat(homeThread.id) }, testUtils.functionContext({ userId: creator.id }))

    const remaining = await db
      .select({ id: schema.chats.id })
      .from(schema.chats)
      .where(inArray(schema.chats.id, [creatorThread.id, adminThread.id, homeThread.id]))
    expect(remaining).toHaveLength(0)
  })
})

async function createThreadWithMessage(
  spaceId: number | null,
  title: string,
  creatorId: number,
  participantIds: number[],
): Promise<schema.DbChat> {
  const chat = await testUtils.createChat(spaceId, title, "thread", false, creatorId)
  if (!chat) throw new Error("Failed to create thread")
  for (const userId of participantIds) {
    await testUtils.addParticipant(chat.id, userId)
  }
  await db.insert(schema.messages).values({ chatId: chat.id, messageId: 1, fromId: creatorId, text: "keep me" })
  await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, chat.id))
  return chat
}

async function removeParticipant(chatId: number, userId: number) {
  await db
    .delete(schema.chatParticipants)
    .where(and(eq(schema.chatParticipants.chatId, chatId), eq(schema.chatParticipants.userId, userId)))
}

async function expectThreadIntact(chatId: number, participantIds: number[]) {
  const [chat] = await db.select({ id: schema.chats.id }).from(schema.chats).where(eq(schema.chats.id, chatId))
  expect(chat?.id).toBe(chatId)
  const participants = await db
    .select({ userId: schema.chatParticipants.userId })
    .from(schema.chatParticipants)
    .where(eq(schema.chatParticipants.chatId, chatId))
  expect(participants.map((row) => row.userId).sort()).toEqual([...participantIds].sort())
  const messages = await db
    .select({ messageId: schema.messages.messageId })
    .from(schema.messages)
    .where(eq(schema.messages.chatId, chatId))
  expect(messages).toHaveLength(1)
}

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
