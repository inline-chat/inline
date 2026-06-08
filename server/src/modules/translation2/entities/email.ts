import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"

export const emailEntities = (text: string): MessageEntity[] => {
  const entities: MessageEntity[] = []
  const regex = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi
  let match: RegExpExecArray | null

  while ((match = regex.exec(text)) !== null) {
    const email = match[0] ?? ""
    if (!email) {
      continue
    }

    entities.push({
      type: MessageEntity_Type.EMAIL,
      offset: BigInt(match.index),
      length: BigInt(email.length),
      entity: { oneofKind: undefined },
    })
  }

  return entities
}
