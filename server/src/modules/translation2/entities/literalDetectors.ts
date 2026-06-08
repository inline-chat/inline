import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { botCommandEntities } from "./botCommand"
import { emailEntities } from "./email"
import { overlapsAny, sortEntities, toRange } from "./offsets"
import { phoneNumberEntities } from "./phoneNumber"
import { urlEntities } from "./url"
import { usernameMentionEntities } from "./usernameMention"
import type { EntityRange } from "./types"

const protectedTypes = new Set<MessageEntity_Type>([
  MessageEntity_Type.CODE,
  MessageEntity_Type.PRE,
  MessageEntity_Type.TEXT_URL,
  MessageEntity_Type.MENTION,
  MessageEntity_Type.THREAD,
  MessageEntity_Type.THREAD_TITLE,
])

export const detectLiteralEntities = (text: string, existing: MessageEntity[]): MessageEntity[] => {
  const protectedRanges = existing
    .filter((entity) => protectedTypes.has(entity.type))
    .map((entity) => toRange(text, entity))
    .filter((range): range is EntityRange => range !== null)

  const entities = [...existing]
  const takenLiteralRanges: EntityRange[] = []

  for (const candidate of [
    ...emailEntities(text),
    ...urlEntities(text),
    ...phoneNumberEntities(text),
    ...botCommandEntities(text),
    ...usernameMentionEntities(text),
  ]) {
    const range = toRange(text, candidate)
    if (!range || overlapsAny(range, protectedRanges) || overlapsAny(range, takenLiteralRanges)) {
      continue
    }

    takenLiteralRanges.push(range)
    entities.push(candidate)
  }

  return sortEntities(entities)
}
