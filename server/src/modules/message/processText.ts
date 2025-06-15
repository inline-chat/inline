import { MessageEntities } from "@in/protocol/core"
import { removeMarkdown } from "@in/server/modules/message/removeMarkdown"
import { Log } from "@in/server/utils/log"

const log = new Log("processText")

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

  const processedText = removeMarkdown(text)

  let processedEntities: MessageEntities | undefined

  if (entities) {
    if (processedText.length != text.length) {
      if (entities.entities.length > 0) {
        log.warn("Text markdown removed, removing all entities")
      }
      // For now, remove all entities as the indexes may be wrong
      processedEntities = { entities: [] } as MessageEntities
    } else {
      processedEntities = entities
    }
  }

  return {
    text: processedText,
    entities: processedEntities,
  }
}
