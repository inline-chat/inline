import { MessageEntities } from "@in/protocol/core"
import { db } from "@in/server/db"
import type { ProcessedMessageTranslation } from "@in/server/db/models/messages"
import { translations, users, type DbNewTranslation } from "@in/server/db/schema"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { sql } from "drizzle-orm"

export const TranslationModel = {
  insertTranslations,
}

export type InputTranslation = Omit<ProcessedMessageTranslation, "id">

/**
 * Insert translations into the database and encrypt them
 */
async function insertTranslations(inputTranslations: InputTranslation[]) {
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

  // insert translations with upsert behavior
  await db
    .insert(translations)
    .values(dbNewTranslations)
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
