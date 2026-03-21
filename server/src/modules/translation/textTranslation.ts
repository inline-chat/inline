import type { ChatModel } from "openai/resources/shared.mjs"
import invariant from "tiny-invariant"
import { z } from "zod/v4"
import { openaiClient } from "@in/server/libs/openAI"
import { getCachedUserName } from "@in/server/modules/cache/userNames"
import { HARDCODED_TRANSLATION_CONTEXT } from "@in/server/env"
import { Log } from "@in/server/utils/log"
import type { TranslationCallInput } from "./types"
import { relativeTimeFromNow } from "@in/server/modules/notifications/eval"
import { zodResponseFormat } from "openai/helpers/zod"

const log = new Log("modules/translation/textTranslation")

const CONTEXT_MESSAGE_MAX_LENGTH = 1024
const CONTEXT_BLOCK_START = "BEGIN_CONTEXT_MESSAGES"
const CONTEXT_BLOCK_END = "END_CONTEXT_MESSAGES"

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

function buildContextMessagesBlock(formattedContextMessages: string[]): string {
  if (formattedContextMessages.length === 0) {
    return ""
  }

  return [
    "Use the context block only to disambiguate meaning and tone.",
    `Never translate, quote, summarize, or include text from ${CONTEXT_BLOCK_START} in the output.`,
    CONTEXT_BLOCK_START,
    ...formattedContextMessages.map((message) => JSON.stringify(message)),
    CONTEXT_BLOCK_END,
  ].join("\n")
}

function validateTranslations(
  input: TranslationCallInput,
  translations: Array<{ messageId: number; translation: string }>,
): Array<{ messageId: number; translation: string }> {
  const expectedMessageIds = input.messages.map((message) => message.messageId)
  const expectedMessageIdSet = new Set(expectedMessageIds)
  const receivedMessageIds = translations.map((translation) => translation.messageId)
  const seenMessageIds = new Set<number>()
  const translationById = new Map<number, { messageId: number; translation: string }>()
  const duplicateMessageIds: number[] = []
  const unexpectedMessageIds: number[] = []

  for (const translation of translations) {
    if (!expectedMessageIdSet.has(translation.messageId)) {
      unexpectedMessageIds.push(translation.messageId)
      continue
    }

    if (seenMessageIds.has(translation.messageId)) {
      duplicateMessageIds.push(translation.messageId)
      continue
    }

    seenMessageIds.add(translation.messageId)
    translationById.set(translation.messageId, translation)
  }

  const missingMessageIds = expectedMessageIds.filter((messageId) => !translationById.has(messageId))

  if (missingMessageIds.length > 0 || duplicateMessageIds.length > 0 || unexpectedMessageIds.length > 0) {
    log.error("Invalid translation output", {
      expectedMessageIds,
      receivedMessageIds,
      missingMessageIds,
      duplicateMessageIds,
      unexpectedMessageIds,
    })
    throw new Error("Invalid translation output")
  }

  return expectedMessageIds.map((messageId) => translationById.get(messageId)!)
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
  const contextMessagesBlock = buildContextMessagesBlock(formattedContextMessages)

  const systemPrompt = `You are a professional translator for Inline chat app's messages, a work chat app like Slack.
        # Instructions
        • Translate user message to "${languageName} (${input.language})"; Keep parts already in ${languageName} unchanged
        - Find messages by their ID in <message> tags and return translations with corresponding message IDs

        # Guidelines
        - Use informal, conversational tone appropriate for workplace collaboration between teammates
        - Preserve formatting (emojis, special characters, code, @mentions, etc.)
        - Only translate, no summarization/explaination; Output only the translated messages.
        - Consider regional differences in ${languageName}. eg. use of ~ in "謝謝~" won't make it in English.
        - Err on the side of translating more of text content than less, users can turn off translation if they want.

        # Use the conversation context below to guide your translation:
        ${contextMessagesBlock ? `${contextMessagesBlock}\n` : ""}
        <chat_context>
        ${input.chat.title ? `Title: ${input.chat.title}` : ""}
        Type: ${input.chat.type}
        Date: ${new Date().toLocaleDateString()}
        ${HARDCODED_TRANSLATION_CONTEXT}
        </chat_context>

        `

  const userPrompt = `
    # Messages to Translate
    <messages>
    ${input.messages
      .map(
        (m) =>
          `<message id="${m.messageId}" date="${relativeTimeFromNow(m.date)}" fromId="${m.fromId}" ${
            m.replyToMsgId ? `replyToId="${m.replyToMsgId}"` : ""
          }>
          <text length="${m.text?.length ?? 0}">${m.text}</text>
          </message>\n`,
      )
      .join("\n")}
    </messages>
        `

  log.debug("Text translation system prompt:", systemPrompt)
  log.debug("Text translation user prompt:", userPrompt)

  const response = await openaiClient.chat.completions.parse({
    model: "gpt-5.4-mini" as ChatModel,
    verbosity: "medium",
    reasoning_effort: "none",
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: userPrompt },
    ],
    response_format: zodResponseFormat(TextTranslationResultSchema, "text_translation"),
    user: `User:${input.actorId}`,
    max_completion_tokens: 20000,
  })

  const finishReason = response.choices[0]?.finish_reason
  if (finishReason !== "stop") {
    log.error(`Text translation failed: ${finishReason}`)
    throw new Error(`Text translation failed: ${finishReason}`)
  }

  try {
    log.debug(`Text translation result: ${response.choices[0]?.message.content}`)
    const result = response.choices[0]?.message.parsed
    if (!result) {
      throw new Error("Missing parsed text translation response")
    }
    return validateTranslations(input, result.translations)
  } catch (error) {
    if (error instanceof Error && error.message === "Invalid translation output") {
      throw error
    }
    log.error(`Text translation decoding failed: ${error}`)
    throw new Error(`Text translation decoding failed: ${error}`)
  }
}
