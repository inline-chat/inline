import { describe, expect, test } from "bun:test"
import { db, schema } from "@in/server/db"
import { TranslationModel, type InputTranslation } from "@in/server/db/models/translations"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { eq, and } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

describe("TranslationModel.insertTranslations", () => {
  setupTestLifecycle()

  test("skips translations whose source messages were deleted without failing the batch", async () => {
    const user = await testUtils.createUser("translations@test.com")
    const chat = await testUtils.createTestChat()

    await testUtils.createTestMessage({
      messageId: 1,
      chatId: chat.id,
      fromId: user.id,
      text: "hello",
    })

    await testUtils.createTestMessage({
      messageId: 2,
      chatId: chat.id,
      fromId: user.id,
      text: "goodbye",
    })

    await db
      .delete(schema.messages)
      .where(and(eq(schema.messages.chatId, chat.id), eq(schema.messages.messageId, 2)))

    const inputTranslations: InputTranslation[] = [
      {
        chatId: chat.id,
        messageId: 1,
        translation: "hola",
        entities: null,
        language: "es",
        date: new Date(),
      },
      {
        chatId: chat.id,
        messageId: 2,
        translation: "adios",
        entities: null,
        language: "es",
        date: new Date(),
      },
    ]

    const result = await TranslationModel.insertTranslations(inputTranslations)

    expect(result.persistedTranslations.map((translation) => translation.messageId)).toEqual([1])
    expect(result.skippedTranslations.map((translation) => translation.messageId)).toEqual([2])

    const storedTranslations = await db
      .select()
      .from(schema.translations)
      .where(eq(schema.translations.chatId, chat.id))

    expect(storedTranslations).toHaveLength(1)
    expect(storedTranslations[0]?.messageId).toBe(1)

    const decryptedTranslation = decrypt({
      encrypted: storedTranslations[0]!.translation!,
      iv: storedTranslations[0]!.translationIv!,
      authTag: storedTranslations[0]!.translationTag!,
    })

    expect(decryptedTranslation).toBe("hola")
  })
})
