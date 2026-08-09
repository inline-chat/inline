import {
  MessageEntity_Type,
  type MessageEntities,
  type MessageEntity,
} from "@inline-chat/protocol/core"

const flexibleRangeTypes = new Set<MessageEntity_Type>([
  MessageEntity_Type.BOLD,
  MessageEntity_Type.ITALIC,
  MessageEntity_Type.CODE,
  MessageEntity_Type.PRE,
])

const isUtf16Boundary = (text: string, offset: number) => {
  if (offset <= 0 || offset >= text.length) return true
  const before = text.charCodeAt(offset - 1)
  const after = text.charCodeAt(offset)
  return !(
    before >= 0xd800 &&
    before <= 0xdbff &&
    after >= 0xdc00 &&
    after <= 0xdfff
  )
}

const sharedEditRange = (before: string, after: string) => {
  let prefix = 0
  while (
    prefix < before.length &&
    prefix < after.length &&
    before.charCodeAt(prefix) === after.charCodeAt(prefix)
  ) {
    prefix += 1
  }
  while (
    prefix > 0 &&
    (!isUtf16Boundary(before, prefix) || !isUtf16Boundary(after, prefix))
  ) {
    prefix -= 1
  }

  let suffix = 0
  while (
    suffix < before.length - prefix &&
    suffix < after.length - prefix &&
    before.charCodeAt(before.length - suffix - 1) ===
      after.charCodeAt(after.length - suffix - 1)
  ) {
    suffix += 1
  }
  while (
    suffix > 0 &&
    (!isUtf16Boundary(before, before.length - suffix) ||
      !isUtf16Boundary(after, after.length - suffix))
  ) {
    suffix -= 1
  }

  return {
    beforeStart: prefix,
    beforeEnd: before.length - suffix,
    afterEnd: after.length - suffix,
  }
}

const safeRange = (
  entity: MessageEntity,
  textLength: number,
): { start: number; end: number } | undefined => {
  const start = Number(entity.offset)
  const length = Number(entity.length)
  const end = start + length
  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(length) ||
    start < 0 ||
    length <= 0 ||
    end > textLength
  ) {
    return undefined
  }
  return { start, end }
}

/**
 * Carries structured ranges through the textarea's single contiguous edit.
 * Semantic entities survive untouched text moving around them; changing their
 * label drops the stale payload. Formatting ranges may safely contract or
 * expand around inserted/replaced text.
 */
export const transformEditedMessageEntities = (
  before: string,
  after: string,
  value: MessageEntities | undefined,
): MessageEntities | undefined => {
  if (!value || value.entities.length === 0) return undefined
  if (before === after) return value

  const { beforeStart, beforeEnd, afterEnd } = sharedEditRange(before, after)
  const delta = afterEnd - beforeEnd
  const transformed: MessageEntity[] = []

  for (const entity of value.entities) {
    const range = safeRange(entity, before.length)
    if (!range) continue
    const { start, end } = range
    let nextStart: number
    let nextEnd: number

    if (end <= beforeStart) {
      nextStart = start
      nextEnd = end
    } else if (start >= beforeEnd) {
      nextStart = start + delta
      nextEnd = end + delta
    } else {
      if (!flexibleRangeTypes.has(entity.type)) continue
      nextStart = start <= beforeStart ? start : afterEnd
      nextEnd = end >= beforeEnd ? end + delta : beforeStart
    }

    if (
      nextStart < 0 ||
      nextEnd <= nextStart ||
      nextEnd > after.length ||
      !isUtf16Boundary(after, nextStart) ||
      !isUtf16Boundary(after, nextEnd)
    ) {
      continue
    }
    transformed.push({
      ...entity,
      offset: BigInt(nextStart),
      length: BigInt(nextEnd - nextStart),
    })
  }

  return transformed.length > 0 ? { entities: transformed } : undefined
}
