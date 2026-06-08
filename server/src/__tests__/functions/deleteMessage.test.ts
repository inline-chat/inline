import { describe, expect, test } from "bun:test"
import { and, desc, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { UpdatesModel } from "@in/server/db/models/updates"
import { deleteMessage } from "@in/server/functions/messages.deleteMessage"
import { getMessages } from "@in/server/functions/messages.getMessages"
import { setupTestLifecycle, testUtils } from "../setup"

describe("messages.deleteMessage", () => {
  setupTestLifecycle()

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
})
