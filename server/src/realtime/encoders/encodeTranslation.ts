import type { DbTranslation } from "@in/server/db/schema"
import { MessageEntities, type MessageTranslation } from "@in/protocol/core"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import type { InputTranslation } from "@in/server/db/models/translations"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"

export const encodeTranslation = ({ translation }: { translation: DbTranslation }): MessageTranslation => {
  // Decrypt translation
  const translationText: string | null =
    translation.translation && translation.translationIv && translation.translationTag
      ? decrypt({
          encrypted: translation.translation,
          iv: translation.translationIv,
          authTag: translation.translationTag,
        })
      : null

  const entities: MessageEntities | undefined = translation.entities
    ? MessageEntities.fromBinary(Encryption2.decryptBinary(translation.entities))
    : undefined

  let translationProto: MessageTranslation = {
    messageId: BigInt(translation.messageId),
    language: translation.language,
    translation: translationText ?? "",
    date: encodeDateStrict(translation.date),
    entities,
  }

  return translationProto
}

export const encodeUnencryptedTranslation = ({
  translation,
}: {
  translation: InputTranslation
}): MessageTranslation => {
  return {
    messageId: BigInt(translation.messageId),
    language: translation.language,
    translation: translation.translation ?? "",
    date: encodeDateStrict(translation.date),
    entities: translation.entities ?? undefined,
  }
}
