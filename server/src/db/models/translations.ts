import { MessageEntities } from "@in/protocol/core"
import { db } from "@in/server/db"
import type { ProcessedMessageTranslation } from "@in/server/db/models/messages"
import { translations, type DbNewTranslation } from "@in/server/db/schema"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"

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

  // insert translations
  await db.insert(translations).values(dbNewTranslations)
}
