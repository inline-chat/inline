import type { InputTranslation } from "@in/server/db/models/translations"
import { HARDCODED_TRANSLATION_CONTEXT, isProd } from "@in/server/env"
import { Log } from "@in/server/utils/log"
import { fromMd, toMd } from "./entities"
import { translateMarkdowns } from "./markdownTranslation"
import type { MarkdownTranslationCallInput, TranslationCallInput } from "./types"

const log = new Log("modules/translation2")

type TranslationDependencies = {
  translateMarkdowns: typeof translateMarkdowns
}

export function createTranslationModule(deps: TranslationDependencies) {
  return {
    translateMessages(input: TranslationCallInput) {
      return translateMessages(input, deps)
    },
  }
}

export const TranslationModule = createTranslationModule({
  translateMarkdowns,
})

if (!HARDCODED_TRANSLATION_CONTEXT && isProd) {
  log.warn("HARDCODED_TRANSLATION_CONTEXT is not available")
}

async function translateMessages(
  input: TranslationCallInput,
  deps: TranslationDependencies,
): Promise<InputTranslation[]> {
  log.info(`Translating ${input.messages.length} messages to ${input.language} using markdown transport`)

  const markdownInput: MarkdownTranslationCallInput = {
    ...input,
    messages: input.messages.map((message) => ({
      ...message,
      markdown: toMd(message.text ?? "", message.entities),
    })),
  }

  const markdownTranslations = await deps.translateMarkdowns(markdownInput)

  const translations = markdownTranslations.map((translation) => {
    const sourceMessage = input.messages.find((message) => message.messageId === translation.messageId)
    if (!sourceMessage) {
      throw new Error(`Original message not found for messageId: ${translation.messageId}`)
    }

    const parsed = fromMd(translation.markdown)
    const date = new Date()
    const msgRev = sourceMessage.rev ?? 0

    return {
      translation: parsed.text,
      messageId: translation.messageId,
      chatId: input.chat.id,
      language: input.language,
      entities: parsed.entities,
      date,
      msgRev,
    }
  })

  log.info(`Translation completed: ${translations.length} messages processed`)
  return translations
}
