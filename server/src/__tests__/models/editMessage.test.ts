import { afterAll, describe, expect, test, beforeAll } from "bun:test"
import { setupTestDatabase, setupTestLifecycle, teardownTestDatabase, testUtils } from "../setup"
import { MessageModel } from "@in/server/db/models/messages"
import { decrypt, decryptBinary } from "@in/server/modules/encryption/encryption"
import { MessageEntities, MessageEntity_MessageEntityMention, MessageEntity_Type } from "@in/protocol/core"

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

  test("it should not fail when entities are cleared", async () => {
    await testUtils.createTestMessage({
      messageId: 3,
      fromId: userId,
      chatId: chatId,
      text: "test",
    })

    let edited = (await MessageModel.editMessage({
      messageId: 3,
      chatId: chatId,
      text: "edited",
      entities: undefined,
    }))!

    expect(edited).toBeTruthy()
  })
})
