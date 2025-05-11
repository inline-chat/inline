import type { MessageTranslation } from "@in/protocol/core"
import type { ProcessedMessage, ProcessedMessageTranslation } from "@in/server/db/models/messages"
import type { InputTranslation } from "@in/server/db/models/translations"
import type { DbChat } from "@in/server/db/schema"
import { openaiClient } from "@in/server/libs/openAI"
import { Log } from "@in/server/utils/log"
import { zodResponseFormat } from "openai/helpers/zod.mjs"
import invariant from "tiny-invariant"
import { z } from "zod"

const log = new Log("modules/translation/translation")

export const TranslationModule = {
  translateMessages,
}

// ----------------

async function translateMessages(input: {
  messages: ProcessedMessage[]
  language: string
  chat: DbChat

  /** User ID of the actor that is translating the messages */
  actorId: number
}): Promise<InputTranslation[]> {
  // Checks
  invariant(openaiClient, "openaiClient is not defined")

  // Data
  const languageName = getLanguageNameFromCode(input.language)

  log.info(`Translating ${input.messages.length} messages to ${languageName}`)

  // Call OpenAI
  const response = await openaiClient.chat.completions.create({
    model: "gpt-4.1-mini",
    messages: [
      {
        role: "system",
        content: `You are a translator. Translate the following text to ${getLanguageNameFromCode(
          input.language,
        )} language. This is a work chat app like Slack. Try to preserve the original meaning, intent and tone of the messages. Do not use formal language. Do not add or remove or change any emojis, special characters, code, numbers, barcodes, URLs, etc. Preserve those as is properly. Then, output the translations, no explanations or additional text. Find messages by their id between <message id="<id>" date="<ISO date>" [...more attributes]> and </message> tags. Use the context to help you translate the messages. Return the translations in an array of objects by attaching the message id to the translation.`,
      },
      {
        role: "user",
        content: `
        <context>
        Chat ID: ${input.chat.id}
        Chat: ${input.chat.title}
        Today's date: ${new Date().toLocaleDateString()}
        </context>

        <messages>
        ${input.messages
          .map(
            (m) =>
              `<message id="${m.messageId}" date="${m.date.toISOString()}" fromId="${m.fromId}" replyToId="${
                m.replyToMsgId
              }">${m.text}</message>\n`,
          )
          .join("\n")}
        </messages>
        `,
      },
    ],
    response_format: zodResponseFormat(BatchTranslationResultSchema, "event"),
    user: `User:${input.actorId}`,
    max_tokens: 16000,
  })

  // Parse result
  let finishReason = response.choices[0]?.finish_reason
  if (finishReason !== "stop") {
    log.error(`Translation failed: ${finishReason}`)
    throw new Error(`Translation failed: ${finishReason}`)
  }

  try {
    const result = BatchTranslationResultSchema.parse(response.choices[0]?.message.content)
    const date = new Date()
    return result.translations.map((t) => ({
      translation: t.translation,
      messageId: t.messageId,
      chatId: input.chat.id,
      language: input.language,
      date,
    }))
  } catch (error) {
    log.error(`Translation decoding failed: ${error}`)
    throw new Error(`Translation decoding failed: ${error}`)
  }
}

const BatchTranslationResultSchema = z.object({
  translations: z.array(
    z.object({
      messageId: z.number(),
      translation: z.string(),
    }),
  ),
})

function getLanguageNameFromCode(code: string): string {
  return new Intl.DisplayNames(["en"], { type: "language" }).of(code) ?? code
}

async function gatherContext(input: { messages: ProcessedMessage[]; chat: DbChat }): Promise<string> {
  // TODO
  return ""
}
