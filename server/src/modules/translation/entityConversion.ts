import type { ChatModel } from "openai/resources/shared.mjs"
import { zodResponseFormat } from "openai/helpers/zod.mjs"
import invariant from "tiny-invariant"
import { z } from "zod"
import { MessageEntities } from "@in/protocol/core"
import { openaiClient } from "@in/server/libs/openAI"
import { Log } from "@in/server/utils/log"

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

/**
 * Create indexed text showing character positions like "Hi" -> "0H1i"
 */
function createIndexedText(text: string): string {
  return Array.from(text)
    .map((char, index) => `${index}${char}`)
    .join("")
}

const formatEntitiesJson = (entities: MessageEntities): string => {
  return MessageEntities.toJsonString(entities)
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

  const systemPrompt = `You are an expert at converting text entity offsets between different languages.

# Task
Convert entity offsets from original texts to translated texts for ${
    messageCount === 1 ? "a message" : "multiple messages"
  }. Entities mark special formatting like mentions, links, bold text, etc.

# Instructions
• Count ALL UTF-16 characters: letters, numbers, spaces, punctuation, emojis, newlines
• Use the indexed translated text to see exactly where each character is positioned
• The offset is the position number where the entity content begins

# Input
- ${
    messageCount === 1 ? "A message" : "Multiple messages"
  } with original and translated text (both with character positions shown)
- Original entities in JSON format for each message

# Output Format
Return conversions array with messageId and updated entities JSON for each message.
If there's no  entities for a message, set entities to null.`

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

  const response = await openaiClient.chat.completions.create({
    model: "gpt-4.1-mini" as ChatModel,
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: userPrompt },
    ],
    response_format: zodResponseFormat(BatchEntityConversionResultSchema, "entity_conversion"),
    user: `User:${input.actorId}`,
    max_tokens: 16000,
  })

  const finishReason = response.choices[0]?.finish_reason
  if (finishReason !== "stop") {
    log.error(`Entity conversion failed: ${finishReason}`)
    throw new Error(`Entity conversion failed: ${finishReason}`)
  }

  try {
    log.debug(`Entity conversion result: ${response.choices[0]?.message.content}`)
    const result = BatchEntityConversionResultSchema.parse(JSON.parse(response.choices[0]?.message.content ?? "{}"))

    return result.conversions.map((conversion) => {
      let entities: MessageEntities | null = null

      if (conversion.entities) {
        try {
          let parsed = JSON.parse(conversion.entities)
          if (Array.isArray(parsed)) {
            entities = MessageEntities.fromJson({ entities: parsed })
          } else if (typeof parsed === "object" && "entities" in parsed) {
            entities = MessageEntities.fromJson(parsed)
          } else {
            log.error(`Invalid entities format for messageId ${conversion.messageId}:`, parsed)
          }
        } catch (error) {
          log.error(`Failed to parse entities for messageId ${conversion.messageId}:`, error)
        }
      }

      return {
        messageId: conversion.messageId,
        entities,
      }
    })
  } catch (error) {
    log.error(`Entity conversion decoding failed: ${error}`)
    throw new Error(`Entity conversion decoding failed: ${error}`)
  }
}
