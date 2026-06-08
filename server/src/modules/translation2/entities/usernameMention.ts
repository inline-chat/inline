import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"

export const usernameMentionEntities = (text: string): MessageEntity[] => {
  const entities: MessageEntity[] = []
  const regex = /(^|[^\w@])(@[A-Za-z0-9_]{2,32})\b/g
  let match: RegExpExecArray | null

  while ((match = regex.exec(text)) !== null) {
    const value = match[2] ?? ""
    if (!value) {
      continue
    }

    const prefix = match[0].length - value.length
    entities.push({
      type: MessageEntity_Type.USERNAME_MENTION,
      offset: BigInt(match.index + prefix),
      length: BigInt(value.length),
      entity: { oneofKind: undefined },
    })
  }

  return entities
}
