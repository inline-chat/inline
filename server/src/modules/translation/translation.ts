import { MessageEntities, MessageEntity_Type, type MessageTranslation } from "@in/protocol/core"
import type { ProcessedMessage, ProcessedMessageTranslation } from "@in/server/db/models/messages"
import type { InputTranslation } from "@in/server/db/models/translations"
import type { DbChat } from "@in/server/db/schema"
import { isProd, WANVER_TRANSLATION_CONTEXT } from "@in/server/env"
import { openaiClient } from "@in/server/libs/openAI"
import { formatEntities } from "@in/server/modules/notifications/eval"
import { Log } from "@in/server/utils/log"
import { zodResponseFormat } from "openai/helpers/zod.mjs"
import invariant from "tiny-invariant"
import { z } from "zod"

const log = new Log("modules/translation")

export const TranslationModule = {
  translateMessages,
}

if (!WANVER_TRANSLATION_CONTEXT && isProd) {
  log.warn("WANVER_TRANSLATION_CONTEXT is not available")
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
  invariant(openaiClient, "OpenAPI client is not defined")

  // Data
  const languageName = getLanguageNameFromCode(input.language)

  log.info(`Translating ${input.messages.length} messages to ${languageName}`)

  // Call OpenAI
  const response = await openaiClient.chat.completions.create({
    model: "gpt-4.1-mini",

    messages: [
      {
        role: "system",
        content: `You are a professional‍ translator for Inline Chat app's messages, a work chat app like Slack. 
        # Instructions 
        Translate the following message texts to ${languageName} language. If parts of text are already in "${languageName}", keep them as is. Don't be formal, this is a chat between coworkers. Try to preserve the original meaning, intent and tone of the messages. Don't add extra information. Don't summarize. Do not add or remove or change any emojis, special characters, code, numbers, barcodes, URLs, @mentions, emails, etc. Preserve those as is properly. Then, output the translations, no explanations or additional text. This is a work context, people collaborating, coordinating, discussing, sharing information, etc usually. Find messages by their id between <message id="<id>" date="<ISO date>" [...more attributes]> and </message> tags. Use the context to help you translate the messages. Return the translations in an array of objects by attaching the message id to the translation.

        # Entities
        Entities are a list of objects that describe the entities in the message such as mentions, links, bold, italic, etc. The offset and length should be adjusted to the translated text. For example, if the original text is "Hello @John", with "@John" having an offset of 6 and a length of 4, and the translated text is "Hola @Dan", the offset should be 5 and the length should be 4. The entities should be returned in exactly the same JSON format as the original text only with the offset and length adjusted to the translated text. If no entities are present, return null.
        `,
      },
      {
        role: "user",
        content: `
        <context>
        # Chat Info
        Chat ID: ${input.chat.id}
        Chat: ${input.chat.title}
        Type: ${input.chat.type}
        Today's date: ${new Date().toLocaleDateString()}

        ${WANVER_TRANSLATION_CONTEXT}
        </context>

        <messages>
        ${input.messages
          .map(
            (m) =>
              `<message id="${m.messageId}" date="${m.date.toISOString()}" fromId="${m.fromId}" replyToId="${
                m.replyToMsgId
              }">
              <text>${m.text}</text>
              ${m.entities ? `<entities>${formatEntitiesJson(m.entities)}</entities>` : ""}
              </message>\n`,
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
    log.debug(`Translation result: ${response.choices[0]?.message.content}`)
    log.debug("AI usage", response.usage)

    // Calculate price based on token usage
    // Input tokens: $0.40 per 1M tokens ($0.00040 per 1K tokens)
    // Output tokens: $1.60 per 1M tokens ($0.00160 per 1K tokens)
    const inputTokens = response.usage?.prompt_tokens ?? 0
    const outputTokens = response.usage?.completion_tokens ?? 0

    const inputPrice = (inputTokens * 0.0004) / 1000
    const outputPrice = (outputTokens * 0.0016) / 1000
    const totalPrice = inputPrice + outputPrice

    log.info(`Translation price: $${totalPrice.toFixed(4)} • actorId: ${input.actorId}`)

    const result = BatchTranslationResultSchema.parse(JSON.parse(response.choices[0]?.message.content ?? "{}"))
    const date = new Date()
    return result.translations.map((t) => {
      let entities: MessageEntities | null = null
      try {
        if (t.entities) {
          entities = MessageEntities.fromJsonString(t.entities)
        }
      } catch (error) {
        log.error(`Translation entities decoding failed`, error)
      }

      return {
        translation: t.translation,
        messageId: t.messageId,
        chatId: input.chat.id,
        language: input.language,
        entities,
        date,
      }
    })
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
      entities: z.string().nullable(),
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

const formatEntitiesJson = (entities: MessageEntities): string => {
  return MessageEntities.toJsonString(entities)
}
