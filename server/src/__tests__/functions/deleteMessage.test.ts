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
      sidebarVisible: false,
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
