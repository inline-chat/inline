import { afterAll, beforeAll, describe, expect, spyOn, test } from "bun:test"
import { setupTestDatabase, teardownTestDatabase, testUtils } from "../setup"
import { MessageModel } from "@in/server/db/models/messages"
import { db } from "@in/server/db"
import { chats, messages, updates, UpdateBucket } from "@in/server/db/schema"
import { decrypt, decryptBinary } from "@in/server/modules/encryption/encryption"
import { MessageEntities, MessageEntity_Type } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"

describe("editMessage", () => {
  let userId: number
  let chatId: number

  // Setup
  beforeAll(async () => {
    await setupTestDatabase()
    let user = await testUtils.createUser("test@test.com")
    let chat = await testUtils.createTestChat()

    userId = user!.id
    chatId = chat!.id
  })
  afterAll(teardownTestDatabase)

  // Tests
  test("edits plain text message", async () => {
    await testUtils.createTestMessage({
      messageId: 1,
      fromId: userId,
      chatId: chatId,
      text: "test",
    })

    let { message: edited } = (await MessageModel.editMessage({
      messageId: 1,
      chatId: chatId,
      text: "edited",
    }))!

    expect(edited).toBeTruthy()

    let text = decrypt({
      authTag: edited.textTag!,
      iv: edited.textIv!,
      encrypted: edited.textEncrypted!,
    })

    expect(text).toBe("edited")
    expect(edited?.editDate).toBeDate()
  })

  test("can suppress edit date for bot streaming edits", async () => {
    await testUtils.createTestMessage({
      messageId: 5,
      fromId: userId,
      chatId: chatId,
      text: "streaming draft",
    })

    await MessageModel.editMessage({
      messageId: 5,
      chatId,
      text: "first stream update",
    })

    const { message: edited } = await MessageModel.editMessage({
      messageId: 5,
      chatId,
      text: "streaming answer",
      suppressEditDate: true,
    })

    expect(edited.editDate).toBeNull()
  })

  test("keeps the message update on the edit transaction handle", async () => {
    await testUtils.createTestMessage({
      messageId: 4,
      fromId: userId,
      chatId: chatId,
      text: "transactional edit",
    })

    const globalUpdate = spyOn(db, "update")
    try {
      await MessageModel.editMessage({
        messageId: 4,
        chatId,
        text: "edited transactionally",
      })
    } finally {
      globalUpdate.mockRestore()
    }

    expect(globalUpdate).not.toHaveBeenCalled()
  })

  test("does not commit an edit update when the message is absent", async () => {
    const [chatBefore] = await db.select().from(chats).where(eq(chats.id, chatId)).limit(1)
    const updatesBefore = await db
      .select({ id: updates.id, seq: updates.seq })
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, chatId)))

    await expect(
      MessageModel.editMessage({
        messageId: 404,
        chatId,
        text: "must not be committed",
      }),
    ).rejects.toThrow()

    const [chatAfter] = await db.select().from(chats).where(eq(chats.id, chatId)).limit(1)
    const updatesAfter = await db
      .select({ id: updates.id, seq: updates.seq })
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, chatId)))

    expect(chatAfter?.updateSeq).toBe(chatBefore?.updateSeq)
    expect(updatesAfter).toEqual(updatesBefore)
  })

  test("edits message with entities", async () => {
    await testUtils.createTestMessage({
      messageId: 2,
      fromId: userId,
      chatId: chatId,
      text: "@mo",
      entities: testUtils.mentionEntities(0, 3),
    })

    let { message: edited } = (await MessageModel.editMessage({
      messageId: 2,
      chatId: chatId,
      text: "edited @mo",
      entities: testUtils.mentionEntities(7, 3),
    }))!

    expect(edited).toBeTruthy()

    let text = decrypt({
      authTag: edited.textTag!,
      iv: edited.textIv!,
      encrypted: edited.textEncrypted!,
    })

    let entities = MessageEntities.fromBinary(
      decryptBinary({
        authTag: edited.entitiesTag!,
        iv: edited.entitiesIv!,
        encrypted: edited.entitiesEncrypted!,
      }),
    )

    expect(text).toBe("edited @mo")
    expect(entities.entities[0]?.type).toBe(MessageEntity_Type.MENTION)
    expect(entities.entities[0]?.offset).toBe(7n)
    expect(entities.entities[0]?.length).toBe(3n)
  })

  test("clears stale entity ciphertext when entities are removed", async () => {
    await testUtils.createTestMessage({
      messageId: 3,
      fromId: userId,
      chatId: chatId,
      text: "@mo",
      entities: testUtils.mentionEntities(0, 3),
    })

    const { message: edited } = await MessageModel.editMessage({
      messageId: 3,
      chatId: chatId,
      text: "edited",
      entities: undefined,
    })

    const [stored] = await db
      .select({
        text: messages.text,
        entitiesEncrypted: messages.entitiesEncrypted,
        entitiesIv: messages.entitiesIv,
        entitiesTag: messages.entitiesTag,
      })
      .from(messages)
      .where(and(eq(messages.chatId, chatId), eq(messages.messageId, 3)))
      .limit(1)

    expect(edited).toBeTruthy()
    expect(edited.entitiesEncrypted).toBeNull()
    expect(edited.entitiesIv).toBeNull()
    expect(edited.entitiesTag).toBeNull()
    expect(stored).toEqual({
      text: null,
      entitiesEncrypted: null,
      entitiesIv: null,
      entitiesTag: null,
    })
  })
})
