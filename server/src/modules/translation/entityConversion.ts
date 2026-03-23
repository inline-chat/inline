import type { ChatModel } from "openai/resources/shared.mjs"
import invariant from "tiny-invariant"
import { z } from "zod/v4"
import { MessageEntities } from "@inline-chat/protocol/core"
import { openaiClient } from "@in/server/libs/openAI"
import { Log } from "@in/server/utils/log"
import { zodResponseFormat } from "openai/helpers/zod"
import { createIndexedText } from "./entityConversionHelpers"

const log = new Log("modules/translation/entityConversion")

// Schema for batch entity offset conversion
const BatchEntityConversionResultSchema = z.object({
  conversions: z.array(
    z.object({
      messageId: z.number(),
      entities: z.string().nullable(),
    }),
  ),
})

function validateConversions(
  expectedMessageIds: number[],
  conversions: Array<{ messageId: number; entities: string | null }>,
): Array<{ messageId: number; entities: string | null }> {
  const expectedMessageIdSet = new Set(expectedMessageIds)
  const receivedMessageIds = conversions.map((conversion) => conversion.messageId)
  const seenMessageIds = new Set<number>()
  const validConversions = new Map<number, { messageId: number; entities: string | null }>()
  const duplicateMessageIds: number[] = []
  const unexpectedMessageIds: number[] = []

  for (const conversion of conversions) {
    if (!expectedMessageIdSet.has(conversion.messageId)) {
      unexpectedMessageIds.push(conversion.messageId)
      continue
    }

    if (seenMessageIds.has(conversion.messageId)) {
      duplicateMessageIds.push(conversion.messageId)
      continue
    }

    seenMessageIds.add(conversion.messageId)
    validConversions.set(conversion.messageId, conversion)
  }

  const missingMessageIds = expectedMessageIds.filter((messageId) => !validConversions.has(messageId))

  if (missingMessageIds.length > 0 || duplicateMessageIds.length > 0 || unexpectedMessageIds.length > 0) {
    log.warn("Invalid entity conversion output", {
      expectedMessageIds,
      receivedMessageIds,
      missingMessageIds,
      duplicateMessageIds,
      unexpectedMessageIds,
    })
  }

  return expectedMessageIds.flatMap((messageId) => {
    const conversion = validConversions.get(messageId)
    return conversion ? [conversion] : []
  })
}

const formatEntitiesJson = (entities: MessageEntities): string => {
  return MessageEntities.toJsonString(entities)
}

function parseConvertedEntitiesJson(input: { messageId: number; entities: string | null }): MessageEntities | null {
  if (!input.entities) {
    return null
  }

  try {
    const parsed: unknown = JSON.parse(input.entities)

    if (parsed == null) {
      return null
    }

    if (Array.isArray(parsed)) {
      return MessageEntities.fromJson({ entities: parsed })
    }

    if (
      typeof parsed === "object" &&
      parsed !== null &&
      "entities" in parsed &&
      Array.isArray(parsed.entities)
    ) {
      return MessageEntities.fromJson({ entities: parsed.entities })
    }

    log.warn(`Invalid entities format for messageId ${input.messageId}:`, parsed)
  } catch (error) {
    log.warn(`Failed to parse entities for messageId ${input.messageId}:`, error)
  }

  return null
}

/**
 * Convert entity offsets for one or more messages (batch processing)
 */
export async function convertEntityOffsets(input: {
  messages: Array<{
    messageId: number
    originalText: string
    translatedText: string
    originalEntities: MessageEntities
  }>
  actorId: number
}): Promise<Array<{ messageId: number; entities: MessageEntities | null }>> {
  invariant(openaiClient, "OpenAPI client is not defined")

  const messageCount = input.messages.length
  log.info(`Converting entity offsets for ${messageCount} message${messageCount === 1 ? "" : "s"}`)

  const systemPrompt = `You are an expert at converting rich text entity offsets in texts when translated.

# Task
Convert entity offsets from original texts to translated texts for ${
    messageCount === 1 ? "a message" : "multiple messages"
  }. Entities mark special formatting like mentions, links, bold text, etc.

# Instructions
• Count ALL UTF-16 characters: letters, numbers, spaces, punctuation, emojis, newlines
• Use the indexed translated text to see exactly where each character is positioned
• The offset is the position number where the entity content begins
• If entity starts at index 0, it means the entity is at the beginning of the text and keep it the same. no need to move it to 1.

# Input
- ${
    messageCount === 1 ? "A message" : "Multiple messages"
  } with original and translated text (both with character positions shown)
- Original entities in JSON format for each message

# Output Format
Return conversions array with messageId and updated entities JSON for each message.
If there's no entities for a message, set entities to null.`

  const userPrompt = `# Message${messageCount === 1 ? "" : "s"} to Convert
${input.messages
  .map(
    (msg) => `
<message id=${msg.messageId}>
<original_text_with_offsets>${createIndexedText(msg.originalText)}</original_text_with_offsets>
<original_entities>${formatEntitiesJson(msg.originalEntities)}</original_entities>
<translated_plaintext>${msg.translatedText}</translated_plaintext>
<translated_text_with_offsets>${createIndexedText(msg.translatedText)}</translated_text_with_offsets>
</message>
`,
  )
  .join("\n")}`

  log.debug("Entity conversion system prompt:", systemPrompt)
  log.debug("Entity conversion user prompt:", userPrompt)

  const response = await openaiClient.chat.completions.parse({
    model: "gpt-5.4-mini" as ChatModel,
    verbosity: "low",
    reasoning_effort: "none",
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: userPrompt },
    ],
    response_format: zodResponseFormat(BatchEntityConversionResultSchema, "entity_conversion"),
    user: `User:${input.actorId}`,
    max_completion_tokens: 20000,
  })

  const finishReason = response.choices[0]?.finish_reason
  if (finishReason !== "stop") {
    log.error(`Entity conversion failed: ${finishReason}`)
    throw new Error(`Entity conversion failed: ${finishReason}`)
  }

  try {
    log.debug(`Entity conversion result: ${response.choices[0]?.message.content}`)
    const result = response.choices[0]?.message.parsed
    if (!result) {
      throw new Error("Missing parsed entity conversion response")
    }

    return validateConversions(
      input.messages.map((message) => message.messageId),
      result.conversions,
    ).map((conversion) => {
      return {
        messageId: conversion.messageId,
        entities: parseConvertedEntitiesJson(conversion),
      }
    })
  } catch (error) {
    log.error(`Entity conversion decoding failed: ${error}`)
    throw new Error(`Entity conversion decoding failed: ${error}`)
  }
}
