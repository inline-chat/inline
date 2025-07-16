import type { ChatModel } from "openai/resources/shared.mjs"
import { zodResponseFormat } from "openai/helpers/zod.mjs"
import invariant from "tiny-invariant"
import { z } from "zod"
import { openaiClient } from "@in/server/libs/openAI"
import { getCachedUserName } from "@in/server/modules/cache/userNames"
import { WANVER_TRANSLATION_CONTEXT } from "@in/server/env"
import { Log } from "@in/server/utils/log"
import type { TranslationCallInput } from "./types"

const log = new Log("modules/translation/textTranslation")

const CONTEXT_MESSAGE_MAX_LENGTH = 240

// Schema for text translation only (Step 1)
const TextTranslationResultSchema = z.object({
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

/**
 * Truncate message text for context to avoid overwhelming the AI
 */
function truncateMessageForContext(text: string | null): string | null {
  if (!text) return text
  if (text.length <= CONTEXT_MESSAGE_MAX_LENGTH) return text
  return text.substring(0, CONTEXT_MESSAGE_MAX_LENGTH) + "..."
}

/**
 * Translate message texts
 */
export async function translateTexts(
  input: TranslationCallInput,
): Promise<Array<{ messageId: number; translation: string }>> {
  invariant(openaiClient, "OpenAPI client is not defined")

  const languageName = getLanguageNameFromCode(input.language)
  const contextMessages = input.contextMessages || []

  log.info(`Translating ${input.messages.length} message texts to ${languageName}`)

  // Format context messages with sender information
  const formattedContextMessages = await Promise.all(
    contextMessages.map(async (msg) => {
      const userName = await getCachedUserName(msg.fromId)
      const senderName = userName?.firstName || userName?.username || `User ${msg.fromId}`
      const truncatedText = truncateMessageForContext(msg.text)
      return `${senderName}: ${truncatedText || "[media/attachment]"}`
    }),
  )

  const systemPrompt = `You are a professional translator for Inline app's messages, a work chat app like Slack. 
        # Instructions 
        • Translate user message texts to "${languageName} (${input.language})"
        - Keep parts already in ${languageName} unchanged
        - Use informal, conversational tone appropriate for workplace collaboration between teammates
        - Preserve formatting elements text content: emojis, special characters, code, numbers, URLs, @mentions, emails, and such.
        - Do not add, remove, summarize, or explain. Output only the translated messages.
        - Use conversation context to disambiguate meanings and choose the most appropriate translation
        - Find messages by their id in <message> tags and return translations with corresponding message IDs
        - Try to preserve original intent, tone, and style considering language differences, nuances, and idioms
        - Consider regional differences in ${languageName}. For examples, use of ~ in "謝謝~" in Chinese doesn't translate in English and the ~ shouldn't be translated literally.

         # Conversation Context
        ${
          formattedContextMessages.length > 0
            ? `Here are some previous messages from the chat for context (IMPORTANT: DO NOT translate these, they are for context only):\n<messages_context>\n${formattedContextMessages.join(
                "\n",
              )}\n</messages_context>\n`
            : ""
        }
        <chat_context>
        ${input.chat.title ? `Title: ${input.chat.title}` : ""}
        Type: ${input.chat.type}
        Date: ${new Date().toLocaleDateString()}
        ${WANVER_TRANSLATION_CONTEXT}
        </chat_context>   
  
        `

  const userPrompt = `
    # Messages to Translate
    <messages>
    ${input.messages
      .map(
        (m) =>
          `<message id="${m.messageId}" date="${m.date.toISOString()}" fromId="${m.fromId}" replyToId="${
            m.replyToMsgId
          }">
          <text length="${m.text?.length ?? 0}">${m.text}</text>
          </message>\n`,
      )
      .join("\n")}
    </messages>
        `

  log.debug("Text translation system prompt:", systemPrompt)
  log.debug("Text translation user prompt:", userPrompt)

  const response = await openaiClient.chat.completions.create({
    model: "gpt-4.1-mini" as ChatModel,
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: userPrompt },
    ],
    response_format: zodResponseFormat(TextTranslationResultSchema, "text_translation"),
    user: `User:${input.actorId}`,
    max_tokens: 16000,
  })

  const finishReason = response.choices[0]?.finish_reason
  if (finishReason !== "stop") {
    log.error(`Text translation failed: ${finishReason}`)
    throw new Error(`Text translation failed: ${finishReason}`)
  }

  try {
    log.debug(`Text translation result: ${response.choices[0]?.message.content}`)
    const result = TextTranslationResultSchema.parse(JSON.parse(response.choices[0]?.message.content ?? "{}"))
    return result.translations
  } catch (error) {
    log.error(`Text translation decoding failed: ${error}`)
    throw new Error(`Text translation decoding failed: ${error}`)
  }
}
