import { MessageEntities } from "@in/protocol/core"
import type { InputTranslation } from "@in/server/db/models/translations"
import { Log } from "@in/server/utils/log"
import { translateTexts } from "./textTranslation"
import { convertEntityOffsets } from "./entityConversion"
import type { TranslationCallInput } from "./types"
import { isProd, WANVER_TRANSLATION_CONTEXT } from "@in/server/env"

const log = new Log("modules/translation")

export const TranslationModule = {
  translateMessages,
}

if (!WANVER_TRANSLATION_CONTEXT && isProd) {
  log.warn("WANVER_TRANSLATION_CONTEXT is not available")
}

async function translateMessages(input: TranslationCallInput): Promise<InputTranslation[]> {
  log.info(`Translating ${input.messages.length} messages to ${input.language} using 2-step process`)

  // Step 1: Translate text content only
  const textTranslations = await translateTexts(input)

  // Step 2: Convert entity offsets for messages that have entities
  // Collect messages that need entity conversion
  const messagesWithEntities = textTranslations
    .map((translation) => {
      const originalMessage = input.messages.find((m) => m.messageId === translation.messageId)
      if (!originalMessage) {
        throw new Error(`Original message not found for messageId: ${translation.messageId}`)
      }
      return { translation, originalMessage }
    })
    .filter(({ originalMessage }) => originalMessage.entities && originalMessage.text)

  // Convert entity offsets using batch processing (works for single messages too)
  let entityResults: Array<{ messageId: number; entities: MessageEntities | null }> = []

  if (messagesWithEntities.length > 0) {
    log.info(
      `Converting entity offsets for ${messagesWithEntities.length} message${
        messagesWithEntities.length === 1 ? "" : "s"
      }`,
    )
    try {
      entityResults = await convertEntityOffsets({
        messages: messagesWithEntities.map(({ translation, originalMessage }) => ({
          messageId: translation.messageId,
          originalText: originalMessage.text!,
          translatedText: translation.translation,
          originalEntities: originalMessage.entities!,
        })),
        actorId: input.actorId,
      })
    } catch (error) {
      log.error(`Entity conversion failed:`, error)
      // Continue without entities rather than failing the entire translation
      entityResults = messagesWithEntities.map(({ translation }) => ({
        messageId: translation.messageId,
        entities: null,
      }))
    }
  }

  // Create final results with entities merged in
  const entityMap = new Map(entityResults.map((r) => [r.messageId, r.entities]))

  const translationsWithEntities = textTranslations.map((translation) => {
    const entities = entityMap.get(translation.messageId) || null
    const date = new Date()
    return {
      translation: translation.translation,
      messageId: translation.messageId,
      chatId: input.chat.id,
      language: input.language,
      entities,
      date,
    }
  })

  log.info(`Translation completed: ${translationsWithEntities.length} messages processed`)
  return translationsWithEntities
}
