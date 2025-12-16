import { MessageEntities } from "@in/protocol/core"
import { parseMarkdown } from "@in/server/modules/message/parseMarkdown"

type ProcessMessageTextInput = {
  // Text from user which may contain markdown entities, URLs or global mentions
  text: string

  // Entities passed from client which may contain parts of patterns already, we should ignore these ranges when computing additional entities
  entities: MessageEntities | undefined
}

type ProcessMessageTextOutput = {
  // Text with markdown symbols stripped out
  text: string

  // All entities including those sent by client and those detected here
  entities: MessageEntities | undefined
}

export const processMessageText = (input: ProcessMessageTextInput): ProcessMessageTextOutput => {
  const { text, entities } = input

  const parsed = parseMarkdown(text)

  // Combine parsed entities with any client-provided entities
  // Client entities are only valid if no markdown was parsed (text unchanged)
  let combinedEntities = parsed.entities

  if (entities && entities.entities.length > 0) {
    if (parsed.text.length === text.length) {
      // No markdown was parsed, client entities are still valid
      combinedEntities = [...parsed.entities, ...entities.entities]
    }
    // If markdown was parsed, discard client entities as their offsets are invalid
  }

  return {
    text: parsed.text,
    entities: combinedEntities.length > 0 ? { entities: combinedEntities } : undefined,
  }
}
