import type { DbTranslation } from "@in/server/db/schema"
import type { MessageTranslation } from "@in/protocol/core"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import type { InputTranslation } from "@in/server/db/models/translations"

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

  let translationProto: MessageTranslation = {
    messageId: BigInt(translation.messageId),
    language: translation.language,
    translation: translationText ?? "",
    date: encodeDateStrict(translation.date),
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
  }
}
