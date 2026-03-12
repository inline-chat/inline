import { MessageEntities } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import type { ProcessedMessageTranslation } from "@in/server/db/models/messages"
import { messages, translations, type DbNewTranslation } from "@in/server/db/schema"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { and, eq, or, sql } from "drizzle-orm"

export const TranslationModel = {
  insertTranslations,
}

export type InputTranslation = Omit<ProcessedMessageTranslation, "id">
export type InsertTranslationsResult = {
  persistedTranslations: InputTranslation[]
  skippedTranslations: InputTranslation[]
}

/**
 * Insert translations into the database and encrypt them
 */
async function insertTranslations(inputTranslations: InputTranslation[]): Promise<InsertTranslationsResult> {
  if (inputTranslations.length === 0) {
    return {
      persistedTranslations: [],
      skippedTranslations: [],
    }
  }

  // encrypt translations
  const dbNewTranslations: DbNewTranslation[] = inputTranslations.map((t) => {
    let encryptedTranslation = t.translation ? encrypt(t.translation) : null
    let encryptedEntities = t.entities ? Encryption2.encrypt(MessageEntities.toBinary(t.entities)) : null

    return {
      ...t,
      translation: encryptedTranslation?.encrypted,
      translationIv: encryptedTranslation?.iv,
      translationTag: encryptedTranslation?.authTag,

      entities: encryptedEntities,
    }
  })

  return await db.transaction(async (tx) => {
    const uniqueMessagePairs = Array.from(
      new Map(inputTranslations.map((translation) => [`${translation.chatId}:${translation.messageId}`, translation])).values(),
    )

    const existingMessages = await tx
      .select({
        chatId: messages.chatId,
        messageId: messages.messageId,
      })
      .from(messages)
      .where(
        or(
          ...uniqueMessagePairs.map((translation) =>
            and(eq(messages.chatId, translation.chatId), eq(messages.messageId, translation.messageId)),
          ),
        ),
      )
      .for("update")

    const existingMessageKeys = new Set(existingMessages.map((message) => `${message.chatId}:${message.messageId}`))

    const persistedTranslations = inputTranslations.filter((translation) =>
      existingMessageKeys.has(`${translation.chatId}:${translation.messageId}`),
    )
    const skippedTranslations = inputTranslations.filter(
      (translation) => !existingMessageKeys.has(`${translation.chatId}:${translation.messageId}`),
    )

    const dbTranslationsToPersist = dbNewTranslations.filter((translation) =>
      existingMessageKeys.has(`${translation.chatId}:${translation.messageId}`),
    )

    if (dbTranslationsToPersist.length > 0) {
      await tx
        .insert(translations)
        .values(dbTranslationsToPersist)
        .onConflictDoUpdate({
          target: [translations.messageId, translations.chatId, translations.language],
          set: {
            date: sql.raw(`excluded.${translations.date.name}`),
            translation: sql.raw(`excluded.${translations.translation.name}`),
            translationIv: sql.raw(`excluded.${translations.translationIv.name}`),
            translationTag: sql.raw(`excluded.${translations.translationTag.name}`),
            entities: sql.raw(`excluded.${translations.entities.name}`),
          },
        })
    }

    return {
      persistedTranslations,
      skippedTranslations,
    }
  })
}
