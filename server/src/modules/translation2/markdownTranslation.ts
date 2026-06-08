import type { ChatModel } from "openai/resources/shared.mjs"
import invariant from "tiny-invariant"
import { z } from "zod/v4"
import { zodResponseFormat } from "openai/helpers/zod"
import { openaiClient } from "@in/server/libs/openAI"
import { getCachedUserName } from "@in/server/modules/cache/userNames"
import { HARDCODED_TRANSLATION_CONTEXT } from "@in/server/env"
import { Log } from "@in/server/utils/log"
import { relativeTimeFromNow } from "@in/server/modules/notifications/eval"
import type { MarkdownTranslation, MarkdownTranslationCallInput } from "./types"

const log = new Log("modules/translation2/markdownTranslation")

const CONTEXT_MESSAGE_MAX_LENGTH = 1024
const CONTEXT_BLOCK_START = "BEGIN_CONTEXT_MESSAGES"
const CONTEXT_BLOCK_END = "END_CONTEXT_MESSAGES"

const MarkdownTranslationResultSchema = z.object({
  translations: z.array(
    z.object({
      messageId: z.number(),
      markdown: z.string(),
    }),
  ),
})

function getLanguageNameFromCode(code: string): string {
  return new Intl.DisplayNames(["en"], { type: "language" }).of(code) ?? code
}

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

export function validateMarkdownTranslations(
  input: Pick<MarkdownTranslationCallInput, "messages">,
  translations: MarkdownTranslation[],
): MarkdownTranslation[] {
  const expectedMessageIds = input.messages.map((message) => message.messageId)
  const expectedMessageIdSet = new Set(expectedMessageIds)
  const receivedMessageIds = translations.map((translation) => translation.messageId)
  const seenMessageIds = new Set<number>()
  const translationById = new Map<number, MarkdownTranslation>()
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
    log.error("Invalid markdown translation output", {
      expectedMessageIds,
      receivedMessageIds,
      missingMessageIds,
      duplicateMessageIds,
      unexpectedMessageIds,
    })
    throw new Error("Invalid markdown translation output")
  }

  return expectedMessageIds.map((messageId) => translationById.get(messageId)!)
}

export async function translateMarkdowns(input: MarkdownTranslationCallInput): Promise<MarkdownTranslation[]> {
  invariant(openaiClient, "OpenAPI client is not defined")

  const languageName = getLanguageNameFromCode(input.language)
  const contextMessages = input.contextMessages || []

  log.info(`Translating ${input.messages.length} markdown messages to ${languageName}`)

  const formattedContextMessages = await Promise.all(
    contextMessages.map(async (msg) => {
      const userName = await getCachedUserName(msg.fromId)
      const senderName = userName?.firstName || userName?.username || `User ${msg.fromId}`
      const truncatedText = truncateMessageForContext(msg.text)
      return `${senderName}: ${truncatedText || "[media/attachment]"}`
    }),
  )
  const contextMessagesBlock = buildContextMessagesBlock(formattedContextMessages)

  const systemPrompt = `You are a translator for Inline chat app.
        # Instructions
        • Translate user messages to "${languageName} (${input.language})"; Keep parts already in ${languageName} unchanged
        - Find messages by their messageId and return translated markdown with the same messageId
        - The markdown is an internal transport for Inline rich-text entities. Preserve markdown syntax when the entity still applies.

        # Markdown rules
        - Preserve links as markdown links and keep link URLs exactly unchanged.
        - Preserve Inline links such as inline://user/... and inline://thread?... exactly; only translate the visible label.
        - Preserve inline code and code blocks exactly unless translating surrounding prose.
        - If a formatting/entity span no longer applies naturally after translation, omit that markdown syntax.
        - Return markdown text only in the structured response. Never return entity JSON, offsets, explanations, or comments.

        # Guidelines
        - Use informal, conversational tone appropriate for workplace collaboration between teammates
        - Preserve emojis and message structure
        - Only translate, no summarization/explanation
        - Consider regional differences in ${languageName}. eg. use of ~ in "謝謝~" won't make it in English.
        - Err on the side of translating more of text content than less; users can turn off translation if they want.
        - Translate and return the complete message content.

        # Use the conversation context below to guide your translation:
        ${contextMessagesBlock ? `${contextMessagesBlock}\n` : ""}
        <chat_context>
        ${input.chat.title ? `Title: ${input.chat.title}` : ""}
        Type: ${input.chat.type}
        Date: ${new Date().toLocaleDateString()}
        ${HARDCODED_TRANSLATION_CONTEXT}
        </chat_context>
        `

  const userPrompt = [
    "# Messages to Translate",
    ...input.messages.map((message) =>
      JSON.stringify({
        messageId: message.messageId,
        date: relativeTimeFromNow(message.date),
        fromId: message.fromId,
        replyToId: message.replyToMsgId ?? undefined,
        markdown: message.markdown,
      }),
    ),
  ].join("\n")

  log.debug("Markdown translation system prompt:", systemPrompt)
  log.debug("Markdown translation user prompt:", userPrompt)

  const response = await openaiClient.chat.completions.parse({
    model: "gpt-5.4-mini" as ChatModel,
    verbosity: "medium",
    reasoning_effort: "none",
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: userPrompt },
    ],
    response_format: zodResponseFormat(MarkdownTranslationResultSchema, "markdown_translation"),
    user: `User:${input.actorId}`,
    max_completion_tokens: 20000,
  })

  const finishReason = response.choices[0]?.finish_reason
  if (finishReason !== "stop") {
    log.error(`Markdown translation failed: ${finishReason}`)
    throw new Error(`Markdown translation failed: ${finishReason}`)
  }

  try {
    log.debug(`Markdown translation result: ${response.choices[0]?.message.content}`)
    const result = response.choices[0]?.message.parsed
    if (!result) {
      throw new Error("Missing parsed markdown translation response")
    }
    return validateMarkdownTranslations(input, result.translations)
  } catch (error) {
    if (error instanceof Error && error.message === "Invalid markdown translation output") {
      throw error
    }
    log.error(`Markdown translation decoding failed: ${error}`)
    throw new Error(`Markdown translation decoding failed: ${error}`)
  }
}
