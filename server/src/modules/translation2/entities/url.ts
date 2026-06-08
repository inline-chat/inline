import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"

export const urlEntities = (text: string): MessageEntity[] => {
  const entities: MessageEntity[] = []
  const regex = /\b(?:https?:\/\/|www\.)[^\s<>()]+(?:\([^\s<>()]*\)[^\s<>()]*)*/gi
  let match: RegExpExecArray | null

  while ((match = regex.exec(text)) !== null) {
    const value = trimUrlPunctuation(match[0] ?? "")
    if (!value) {
      continue
    }

    entities.push({
      type: MessageEntity_Type.URL,
      offset: BigInt(match.index),
      length: BigInt(value.length),
      entity: { oneofKind: undefined },
    })
  }

  return entities
}

const trimUrlPunctuation = (value: string): string => {
  return value.replace(/[.,!?;:]+$/g, "")
}
