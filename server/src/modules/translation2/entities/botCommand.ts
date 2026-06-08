import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"

const isNameChar = (char: string): boolean => {
  const code = char.charCodeAt(0)
  return (
    (code >= 48 && code <= 57) ||
    (code >= 65 && code <= 90) ||
    (code >= 97 && code <= 122) ||
    code === 95
  )
}

const isBoundary = (char: string | undefined): boolean => {
  return char === undefined || /\s/.test(char)
}

export const botCommandEntities = (text: string): MessageEntity[] => {
  const entities: MessageEntity[] = []

  for (let i = 0; i < text.length; i++) {
    if (text[i] !== "/" || !isBoundary(text[i - 1])) {
      continue
    }

    let end = i + 1
    while (end < text.length && isNameChar(text[end]!)) {
      end += 1
    }

    const commandLength = end - i - 1
    if (commandLength < 1 || commandLength > 32) {
      continue
    }

    if (text[end] === "@") {
      const suffixStart = end
      end += 1
      while (end < text.length && isNameChar(text[end]!)) {
        end += 1
      }
      if (end === suffixStart + 1) {
        end = suffixStart
      }
    }

    entities.push({
      type: MessageEntity_Type.BOT_COMMAND,
      offset: BigInt(i),
      length: BigInt(end - i),
      entity: { oneofKind: undefined },
    })

    i = end - 1
  }

  return entities
}
