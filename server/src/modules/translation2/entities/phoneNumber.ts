import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"

export const phoneNumberEntities = (text: string): MessageEntity[] => {
  const entities: MessageEntity[] = []
  const regex = /(?:^|[^\w+])(\+?\d[\d ().-]{5,}\d)(?=$|[^\w])/g
  let match: RegExpExecArray | null

  while ((match = regex.exec(text)) !== null) {
    const value = match[1] ?? ""
    const digits = value.replace(/\D/g, "")
    if (digits.length < 7) {
      continue
    }

    const prefix = match[0].length - value.length
    entities.push({
      type: MessageEntity_Type.PHONE_NUMBER,
      offset: BigInt(match.index + prefix),
      length: BigInt(value.length),
      entity: { oneofKind: undefined },
    })
  }

  return entities
}
