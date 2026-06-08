import type { MessageEntity } from "@inline-chat/protocol/core"
import type { EntityRange } from "./types"

export const toRange = (text: string, entity: MessageEntity): EntityRange | null => {
  const start = Number(entity.offset)
  const length = Number(entity.length)
  const end = start + length

  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(length) ||
    start < 0 ||
    length <= 0 ||
    end > text.length
  ) {
    return null
  }

  return { start, end }
}

export const hasPartialOverlap = (a: EntityRange, b: EntityRange): boolean => {
  const overlaps = a.start < b.end && b.start < a.end
  if (!overlaps) {
    return false
  }

  const aContainsB = a.start <= b.start && b.end <= a.end
  const bContainsA = b.start <= a.start && a.end <= b.end
  return !aContainsB && !bContainsA
}

export const contains = (outer: EntityRange, inner: EntityRange): boolean => {
  return outer.start <= inner.start && inner.end <= outer.end
}

export const overlapsAny = (range: EntityRange, ranges: EntityRange[]): boolean => {
  return ranges.some((candidate) => range.start < candidate.end && candidate.start < range.end)
}

export const sortEntities = <T extends MessageEntity>(entities: T[]): T[] => {
  return [...entities].sort((a, b) => {
    if (a.offset !== b.offset) {
      return a.offset < b.offset ? -1 : 1
    }
    if (a.length !== b.length) {
      return a.length > b.length ? -1 : 1
    }
    return a.type - b.type
  })
}
