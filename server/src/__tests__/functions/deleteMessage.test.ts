import { describe, expect, test } from "bun:test"
import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { and, desc, eq, isNull } from "drizzle-orm"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { UpdatesModel } from "@in/server/db/models/updates"
import { deleteMessage } from "@in/server/functions/messages.deleteMessage"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { getMessages } from "@in/server/functions/messages.getMessages"
import { setupTestLifecycle, testUtils } from "../setup"
import { insertThreadBacklinkSystemMessage } from "@in/server/modules/systemMessages"
import { RealtimeRpcError } from "@in/server/realtime/errors"

describe("messages.deleteMessage", () => {
  setupTestLifecycle()

  test("allows service message authors to delete their own service messages in space threads", async () => {
    const author = await testUtils.createUser("space-service-delete-author@example.com")
    const space = await testUtils.createSpace("Space Service Delete")
    if (!space) {
      throw new Error("Space not created")
    }

    await db.insert(schema.members).values({ spaceId: space.id, userId: author.id, role: "member" })

    const source = await testUtils.createChat(space.id, "Source Thread", "thread", true, author.id)
    const target = await testUtils.createChat(space.id, "Target Thread", "thread", true, author.id)
    if (!source || !target) {
      throw new Error("Space service delete chats not created")
    }

    const systemMessage = await insertThreadBacklinkSystemMessage({
      chatId: target.id,
      actorUserId: author.id,
      graphLinkId: 1n,
      sourceChatId: source.id,
      sourceTitle: source.title,
    })

    await deleteMessage(
      {
        peer: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(target.id) },
          },
        },
        messageIds: [BigInt(systemMessage.messageId)],
      },
      testUtils.functionContext({ userId: author.id }),
    )

    const deleted = await db
      .select({ messageId: schema.messages.messageId })
      .from(schema.messages)
      .where(and(eq(schema.messages.chatId, target.id), eq(schema.messages.messageId, systemMessage.messageId)))

    expect(deleted).toHaveLength(0)
  })

  test("allows message authors to delete their own messages in space threads", async () => {
    const author = await testUtils.createUser("space-delete-own-author@example.com")
    const space = await testUtils.createSpace("Space Delete Own")
    if (!space) {
      throw new Error("Space not created")
    }

    await db.insert(schema.members).values({ spaceId: space.id, userId: author.id, role: "member" })

    const chat = await testUtils.createChat(space.id, "Author Space Thread", "thread", true, author.id)
    if (!chat) {
      throw new Error("Author space thread not created")
    }

    await db.insert(schema.messages).values({
      chatId: chat.id,
      messageId: 1,
      fromId: author.id,
      text: "author message",
    })
    await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, chat.id))

    await deleteMessage(
      {
        peer: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(chat.id) },
          },
        },
        messageIds: [1n],
      },
      testUtils.functionContext({ userId: author.id }),
    )

    const deleted = await db
      .select({ messageId: schema.messages.messageId })
      .from(schema.messages)
      .where(and(eq(schema.messages.chatId, chat.id), eq(schema.messages.messageId, 1)))

    expect(deleted).toHaveLength(0)
  })

  test("rejects deleting another user's message in a private space thread for non-admin members", async () => {
    const author = await testUtils.createUser("space-delete-author@example.com")
    const member = await testUtils.createUser("space-delete-member@example.com")
    const space = await testUtils.createSpace("Space Delete Member")
    if (!space) {
      throw new Error("Space not created")
    }

    await db.insert(schema.members).values([
      { spaceId: space.id, userId: author.id, role: "member" },
      { spaceId: space.id, userId: member.id, role: "member" },
    ])

    const chat = await testUtils.createChat(space.id, "Private Space Thread", "thread", false, author.id)
    if (!chat) {
      throw new Error("Private space thread not created")
    }
    await testUtils.addParticipant(chat.id, author.id)
    await testUtils.addParticipant(chat.id, member.id)

    await db.insert(schema.messages).values({
      chatId: chat.id,
      messageId: 1,
      fromId: author.id,
      text: "author message",
    })
    await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, chat.id))

    await expect(
      deleteMessage(
        {
          peer: {
            type: {
              oneofKind: "chat",
              chat: { chatId: BigInt(chat.id) },
            },
          },
          messageIds: [1n],
        },
        testUtils.functionContext({ userId: member.id }),
      ),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.SPACE_ADMIN_REQUIRED })

    const retained = await db
      .select({ messageId: schema.messages.messageId })
      .from(schema.messages)
      .where(and(eq(schema.messages.chatId, chat.id), eq(schema.messages.messageId, 1)))

    expect(retained).toHaveLength(1)
  })

  test("rejects deleting another user's message in a public space thread for non-admin members", async () => {
    const author = await testUtils.createUser("space-delete-public-author@example.com")
    const member = await testUtils.createUser("space-delete-public-member@example.com")
    const space = await testUtils.createSpace("Public Space Delete Member")
    if (!space) {
      throw new Error("Space not created")
    }

    await db.insert(schema.members).values([
      { spaceId: space.id, userId: author.id, role: "member" },
      { spaceId: space.id, userId: member.id, role: "member" },
    ])

    const chat = await testUtils.createChat(space.id, "Public Space Thread", "thread", true, author.id)
    if (!chat) {
      throw new Error("Public space thread not created")
    }

    await db.insert(schema.messages).values({
      chatId: chat.id,
      messageId: 1,
      fromId: author.id,
      text: "author message",
    })
    await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, chat.id))

    await expect(
      deleteMessage(
        {
          peer: {
            type: {
              oneofKind: "chat",
              chat: { chatId: BigInt(chat.id) },
            },
          },
          messageIds: [1n],
        },
        testUtils.functionContext({ userId: member.id }),
      ),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.SPACE_ADMIN_REQUIRED })

    const retained = await db
      .select({ messageId: schema.messages.messageId })
      .from(schema.messages)
      .where(and(eq(schema.messages.chatId, chat.id), eq(schema.messages.messageId, 1)))

    expect(retained).toHaveLength(1)
  })

  test("allows space admins to delete another user's message in a space thread", async () => {
    const author = await testUtils.createUser("space-delete-admin-author@example.com")
    const admin = await testUtils.createUser("space-delete-admin@example.com")
    const space = await testUtils.createSpace("Space Delete Admin")
    if (!space) {
      throw new Error("Space not created")
    }

    await db.insert(schema.members).values([
      { spaceId: space.id, userId: author.id, role: "member" },
      { spaceId: space.id, userId: admin.id, role: "admin" },
    ])

    const chat = await testUtils.createChat(space.id, "Public Space Thread", "thread", true, author.id)
    if (!chat) {
      throw new Error("Public space thread not created")
    }

    await db.insert(schema.messages).values({
      chatId: chat.id,
      messageId: 1,
      fromId: author.id,
      text: "author message",
    })
    await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, chat.id))

    await deleteMessage(
      {
        peer: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(chat.id) },
          },
        },
        messageIds: [1n],
      },
      testUtils.functionContext({ userId: admin.id }),
    )

    const deleted = await db
      .select({ messageId: schema.messages.messageId })
      .from(schema.messages)
      .where(and(eq(schema.messages.chatId, chat.id), eq(schema.messages.messageId, 1)))

    expect(deleted).toHaveLength(0)
  })

  test("allows space admins to delete another user's message in a private space thread they can access", async () => {
    const author = await testUtils.createUser("space-delete-private-admin-author@example.com")
    const admin = await testUtils.createUser("space-delete-private-admin@example.com")
    const space = await testUtils.createSpace("Private Space Delete Admin")
    if (!space) {
      throw new Error("Space not created")
    }

    await db.insert(schema.members).values([
      { spaceId: space.id, userId: author.id, role: "member" },
      { spaceId: space.id, userId: admin.id, role: "admin" },
    ])

    const chat = await testUtils.createChat(space.id, "Private Admin Space Thread", "thread", false, author.id)
    if (!chat) {
      throw new Error("Private admin space thread not created")
    }
    await testUtils.addParticipant(chat.id, author.id)
    await testUtils.addParticipant(chat.id, admin.id)

    await db.insert(schema.messages).values({
      chatId: chat.id,
      messageId: 1,
      fromId: author.id,
      text: "author message",
    })
    await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, chat.id))

    await deleteMessage(
      {
        peer: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(chat.id) },
          },
        },
        messageIds: [1n],
      },
      testUtils.functionContext({ userId: admin.id }),
    )

    const deleted = await db
      .select({ messageId: schema.messages.messageId })
      .from(schema.messages)
      .where(and(eq(schema.messages.chatId, chat.id), eq(schema.messages.messageId, 1)))

    expect(deleted).toHaveLength(0)
  })

  test("orphaning reply threads when deleting their anchor message", async () => {
    const currentUser = await testUtils.createUser("reply-anchor-delete-owner@example.com")
    const participant = await testUtils.createUser("reply-anchor-delete-participant@example.com")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, currentUser.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, currentUser.id)
    await testUtils.addParticipant(parentChat.id, participant.id)

    await db.insert(schema.messages).values([
      {
        chatId: parentChat.id,
        messageId: 1,
        fromId: currentUser.id,
        text: "anchor",
      },
      {
        chatId: parentChat.id,
        messageId: 2,
        fromId: participant.id,
        text: "still here",
      },
    ])
    await db.update(schema.chats).set({ lastMsgId: 2 }).where(eq(schema.chats.id, parentChat.id))

    const [childChat] = await db
      .insert(schema.chats)
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

    await testUtils.addParticipant(childChat.id, currentUser.id)
    await testUtils.addParticipant(childChat.id, participant.id)

    await db.insert(schema.dialogs).values({
      chatId: childChat.id,
      userId: currentUser.id,
    })

    await db.insert(schema.messages).values({
      chatId: childChat.id,
      messageId: 1,
      fromId: participant.id,
      text: "reply",
    })
    await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, childChat.id))

    const result = await deleteMessage(
      {
        peer: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(parentChat.id) },
          },
        },
        messageIds: [1n],
      },
      testUtils.functionContext({ userId: currentUser.id }),
    )

    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["deleteMessages", "newChat"])

    const [deletedAnchor] = await db
      .select()
      .from(schema.messages)
      .where(and(eq(schema.messages.chatId, parentChat.id), eq(schema.messages.messageId, 1)))
      .limit(1)
    expect(deletedAnchor).toBeUndefined()

    const [retainedParentMessage] = await db
      .select()
      .from(schema.messages)
      .where(and(eq(schema.messages.chatId, parentChat.id), eq(schema.messages.messageId, 2)))
      .limit(1)
    expect(retainedParentMessage).toBeTruthy()

    const [updatedChild] = await db.select().from(schema.chats).where(eq(schema.chats.id, childChat.id)).limit(1)
    expect(updatedChild?.parentChatId).toBe(parentChat.id)
    expect(updatedChild?.parentMessageId).toBeNull()

    const childMessageIds = (
      await db
        .select({ messageId: schema.messages.messageId })
        .from(schema.messages)
        .where(eq(schema.messages.chatId, childChat.id))
    )
      .map((row) => row.messageId)
      .sort((a, b) => a - b)
    expect(childMessageIds).toEqual([1])

    const childParticipantIds = (
      await db
        .select({ userId: schema.chatParticipants.userId })
        .from(schema.chatParticipants)
        .where(eq(schema.chatParticipants.chatId, childChat.id))
    )
      .map((row) => row.userId)
      .sort((a, b) => a - b)
    expect(childParticipantIds).toEqual([currentUser.id, participant.id].sort((a, b) => a - b))

    const childDialogUserIds = (
      await db
        .select({ userId: schema.dialogs.userId })
        .from(schema.dialogs)
        .where(eq(schema.dialogs.chatId, childChat.id))
    ).map((row) => row.userId)
    expect(childDialogUserIds).toEqual([currentUser.id])

    const [metadataUpdateRow] = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.Chat), eq(schema.updates.entityId, childChat.id)))
      .orderBy(desc(schema.updates.seq))
      .limit(1)

    expect(metadataUpdateRow).toBeTruthy()
    const decrypted = UpdatesModel.decrypt(metadataUpdateRow!)
    expect(decrypted.payload.update.oneofKind).toBe("newChat")
    if (decrypted.payload.update.oneofKind === "newChat") {
      expect(Number(decrypted.payload.update.newChat.chatId)).toBe(childChat.id)
    }
  })

  test("orphaning multiple anchored reply threads in one delete", async () => {
    const currentUser = await testUtils.createUser("reply-anchor-batch-owner@example.com")
    const parentChat = await testUtils.createChat(null, "Batch Parent", "thread", false, currentUser.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, currentUser.id)

    await db.insert(schema.messages).values([
      {
        chatId: parentChat.id,
        messageId: 1,
        fromId: currentUser.id,
        text: "anchor one",
      },
      {
        chatId: parentChat.id,
        messageId: 2,
        fromId: currentUser.id,
        text: "anchor two",
      },
      {
        chatId: parentChat.id,
        messageId: 3,
        fromId: currentUser.id,
        text: "keep",
      },
    ])
    await db.update(schema.chats).set({ lastMsgId: 3 }).where(eq(schema.chats.id, parentChat.id))

    const [firstChild, secondChild, retainedChild] = await db
      .insert(schema.chats)
      .values([
        {
          type: "thread",
          title: "Re: one",
          publicThread: false,
          createdBy: currentUser.id,
          parentChatId: parentChat.id,
          parentMessageId: 1,
        },
        {
          type: "thread",
          title: "Re: two",
          publicThread: false,
          createdBy: currentUser.id,
          parentChatId: parentChat.id,
          parentMessageId: 2,
        },
        {
          type: "thread",
          title: "Re: keep",
          publicThread: false,
          createdBy: currentUser.id,
          parentChatId: parentChat.id,
          parentMessageId: 3,
        },
      ])
      .returning()

    if (!firstChild || !secondChild || !retainedChild) {
      throw new Error("Child chats not created")
    }

    await deleteMessage(
      {
        peer: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(parentChat.id) },
          },
        },
        messageIds: [1n, 2n],
      },
      testUtils.functionContext({ userId: currentUser.id }),
    )

    const childRows = await db.select().from(schema.chats).where(eq(schema.chats.parentChatId, parentChat.id))
    const parentMessageIds = new Map(childRows.map((chat) => [chat.id, chat.parentMessageId]))

    expect(parentMessageIds.get(firstChild.id)).toBeNull()
    expect(parentMessageIds.get(secondChild.id)).toBeNull()
    expect(parentMessageIds.get(retainedChild.id)).toBe(3)
  })

  test("refreshes parent replies summary when deleting a reply-thread message", async () => {
    const currentUser = await testUtils.createUser("reply-delete-owner@example.com")
    const firstReplier = await testUtils.createUser("reply-delete-first@example.com")
    const secondReplier = await testUtils.createUser("reply-delete-second@example.com")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, currentUser.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, currentUser.id)
    await testUtils.addParticipant(parentChat.id, firstReplier.id)
    await testUtils.addParticipant(parentChat.id, secondReplier.id)

    await db.insert(schema.messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: currentUser.id,
      text: "anchor",
    })
    await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, parentChat.id))

    const [childChat] = await db
      .insert(schema.chats)
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

    await testUtils.addParticipant(childChat.id, currentUser.id)
    await testUtils.addParticipant(childChat.id, firstReplier.id)
    await testUtils.addParticipant(childChat.id, secondReplier.id)

    await db.insert(schema.dialogs).values({
      chatId: childChat.id,
      userId: currentUser.id,
    })

    await db.insert(schema.messages).values([
      {
        chatId: childChat.id,
        messageId: 1,
        fromId: firstReplier.id,
        text: "first reply",
      },
      {
        chatId: childChat.id,
        messageId: 2,
        fromId: secondReplier.id,
        text: "second reply",
      },
    ])
    await db.update(schema.chats).set({ lastMsgId: 2 }).where(eq(schema.chats.id, childChat.id))

    const beforeDelete = await getMessages(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(parentChat.id) },
          },
        },
        messageIds: [1n],
      },
      testUtils.functionContext({ userId: currentUser.id }),
    )

    expect(beforeDelete.messages[0]?.replies?.replyCount).toBe(2)
    expect(beforeDelete.messages[0]?.replies?.recentReplierUserIds).toEqual([
      BigInt(secondReplier.id),
      BigInt(firstReplier.id),
    ])

    const [beforeUpdateRow] = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.Chat), eq(schema.updates.entityId, parentChat.id)))
      .orderBy(desc(schema.updates.seq))
      .limit(1)

    await deleteMessage(
      {
        peer: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(childChat.id) },
          },
        },
        messageIds: [2n],
      },
      testUtils.functionContext({ userId: currentUser.id }),
    )

    const afterDelete = await getMessages(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(parentChat.id) },
          },
        },
        messageIds: [1n],
      },
      testUtils.functionContext({ userId: currentUser.id }),
    )

    expect(afterDelete.messages[0]?.replies?.replyCount).toBe(1)
    expect(afterDelete.messages[0]?.replies?.recentReplierUserIds).toEqual([
      BigInt(firstReplier.id),
    ])

    const [afterUpdateRow] = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.Chat), eq(schema.updates.entityId, parentChat.id)))
      .orderBy(desc(schema.updates.seq))
      .limit(1)

    expect(afterUpdateRow).toBeTruthy()
    expect(afterUpdateRow!.seq).toBeGreaterThan(beforeUpdateRow?.seq ?? 0)

    const decrypted = UpdatesModel.decrypt(afterUpdateRow!)
    expect(decrypted.payload.update.oneofKind).toBe("editMessage")
    if (decrypted.payload.update.oneofKind === "editMessage") {
      expect(Number(decrypted.payload.update.editMessage.chatId)).toBe(parentChat.id)
      expect(Number(decrypted.payload.update.editMessage.msgId)).toBe(1)
    }
  })

  test("deleting a linked source message deletes its backlink system message", async () => {
    const currentUser = await testUtils.createUser("thread-link-delete-owner@example.com")
    const source = await testUtils.createChat(null, "Delete Link Source", "thread", false, currentUser.id)
    const target = await testUtils.createChat(null, "Delete Link Target", "thread", false, currentUser.id)
    if (!source || !target) {
      throw new Error("Graph delete test chats not created")
    }

    await testUtils.addParticipant(source.id, currentUser.id)
    await testUtils.addParticipant(target.id, currentUser.id)

    const sent = await sendMessage(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(source.id) },
          },
        },
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
        ? sent.updates[0].update.updateMessageId?.messageId
        : undefined
    expect(sentMessageId).toBeTruthy()

    const link = await waitForThreadGraphLink({
      fromChatId: source.id,
      fromMessageId: Number(sentMessageId),
      toChatId: target.id,
    })
    const backlinkMessageGlobalId = link.backlinkMessageGlobalId
    expect(backlinkMessageGlobalId).toBeTruthy()

    const [backlinkMessageBeforeDelete] = await db
      .select({
        chatId: schema.messages.chatId,
        messageId: schema.messages.messageId,
      })
      .from(schema.messages)
      .where(eq(schema.messages.globalId, backlinkMessageGlobalId!))
      .limit(1)
    expect(backlinkMessageBeforeDelete).toBeTruthy()

    const result = await deleteMessage(
      {
        peer: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(source.id) },
          },
        },
        messageIds: [sentMessageId!],
      },
      testUtils.functionContext({ userId: currentUser.id }),
    )

    const backlinkDeleteUpdate = result.updates.find((update) => {
      if (update.update.oneofKind !== "deleteMessages") {
        return false
      }

      const deleteMessages = update.update.deleteMessages
      return (
        deleteMessages.peerId?.type.oneofKind === "chat" &&
        deleteMessages.peerId.type.chat.chatId === BigInt(target.id) &&
        deleteMessages.messageIds.includes(BigInt(backlinkMessageBeforeDelete!.messageId))
      )
    })
    expect(backlinkDeleteUpdate).toBeTruthy()

    const activeLinks = await db
      .select()
      .from(schema.threadGraphLinks)
      .where(
        and(
          eq(schema.threadGraphLinks.kind, "thread_link"),
          eq(schema.threadGraphLinks.fromChatId, source.id),
          eq(schema.threadGraphLinks.fromMessageId, Number(sentMessageId)),
          isNull(schema.threadGraphLinks.deletedAt),
        ),
      )
    expect(activeLinks).toHaveLength(0)

    const backlinkMessages = await db
      .select({ globalId: schema.messages.globalId })
      .from(schema.messages)
      .where(eq(schema.messages.globalId, backlinkMessageGlobalId!))
    expect(backlinkMessages).toHaveLength(0)
  })
})

async function waitForThreadGraphLink(input: { fromChatId: number; fromMessageId: number; toChatId: number }) {
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
          isNull(schema.threadGraphLinks.deletedAt),
        ),
      )
      .limit(1)

    if (link?.backlinkMessageGlobalId) {
      return link
    }

    await sleep(10)
  }

  throw new Error(`Expected graph backlink for message ${input.fromChatId}:${input.fromMessageId}`)
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}
