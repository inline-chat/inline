import { MessageEntity_Type, type MessageEntities, type MessageEntity } from "@inline-chat/protocol/core"
import { mathOutputRanges, parseMarkdownWithSourceMap, type ParsedMarkdownWithSourceMap } from "@in/server/modules/message/parseMarkdown"
import { splitsSurrogatePair } from "../translation2/entities/offsets"

type ProcessMessageTextInput = {
  // Text from user which may contain markdown entities, URLs or global mentions
  text: string

  // Client entities refer to UTF-16 ranges in the original text.
  entities: MessageEntities | undefined

  /** Reuse the parser result when the rich-content path already produced it. */
  parsedMarkdown?: ParsedMarkdownWithSourceMap
}

type ProcessMessageTextOutput = {
  // Text with markdown symbols stripped out
  text: string

  // All entities including those sent by client and those detected here
  entities: MessageEntities | undefined
}

export const processMessageText = (input: ProcessMessageTextInput): ProcessMessageTextOutput => {
  const { text, entities } = input

  const parsed = input.parsedMarkdown ?? parseMarkdownWithSourceMap(text)

  const combinedEntities = [
    ...parsed.entities,
    ...remapClientEntities(text, entities?.entities ?? [], parsed),
  ]

  return {
    text: parsed.text,
    entities: combinedEntities.length > 0 ? { entities: combinedEntities } : undefined,
  }
}

function remapClientEntities(
  source: string,
  entities: MessageEntity[],
  parsed: ParsedMarkdownWithSourceMap,
): MessageEntity[] {
  if (entities.length === 0) return []
  const sourceLength = BigInt(source.length)
  const protectedRanges = mergeRanges([
    ...mathOutputRanges(parsed),
    ...parsed.entities.flatMap((entity) =>
      entity.type === MessageEntity_Type.CODE
        || entity.type === MessageEntity_Type.PRE
        || entity.type === MessageEntity_Type.MATH
        ? [{ start: Number(entity.offset), end: Number(entity.offset + entity.length) }]
        : []),
  ], parsed.text.length)
  const parsedRanges = new Set(parsed.entities.map((entity) => `${entity.type}:${entity.offset}:${entity.length}`))
  return entities.flatMap((entity) => {
    if (!entity) return []
    const end = entity.offset + entity.length
    if (entity.offset < 0n || entity.length <= 0n || end > sourceLength) return []

    const sourceStart = Number(entity.offset)
    const sourceEnd = Number(end)
    if (splitsSurrogatePair(source, sourceStart) || splitsSurrogatePair(source, sourceEnd)) return []

    const start = parsed.sourceToOutput[sourceStart]
    const stop = parsed.sourceToOutput[sourceEnd]
    if (
      start === undefined || stop === undefined || !Number.isInteger(start) || !Number.isInteger(stop)
      || start < 0 || stop <= start || stop > parsed.text.length
    ) return []
    if (splitsSurrogatePair(parsed.text, start) || splitsSurrogatePair(parsed.text, stop)) return []

    const offset = BigInt(start)
    const length = BigInt(stop - start)
    // Keep the parser's payload when both inputs describe the same entity range.
    if (parsedRanges.has(`${entity.type}:${offset}:${length}`)) return []
    // Parsed code and TeX remain literal even if the source carries an interactive entity.
    if (overlapsRanges(protectedRanges, start, stop)) return []
    return [{ ...entity, offset, length }]
  })
}

type ProtectedRange = { start: number; end: number }

/** Parser ranges are trusted but may overlap or repeat. Merge them once so a
 * large client entity list never rescans every code/formula span. */
function mergeRanges(ranges: ProtectedRange[], textLength: number): ProtectedRange[] {
  const sorted = ranges
    .filter((range) => Number.isInteger(range.start) && Number.isInteger(range.end)
      && range.start >= 0 && range.end > range.start && range.end <= textLength)
    .sort((a, b) => a.start - b.start || a.end - b.end)
  const merged: ProtectedRange[] = []
  for (const range of sorted) {
    const previous = merged.at(-1)
    if (previous && range.start <= previous.end) {
      previous.end = Math.max(previous.end, range.end)
    } else {
      merged.push({ ...range })
    }
  }
  return merged
}

function overlapsRanges(ranges: ProtectedRange[], start: number, end: number): boolean {
  let low = 0
  let high = ranges.length
  while (low < high) {
    const middle = (low + high) >>> 1
    if (ranges[middle]!.end <= start) low = middle + 1
    else high = middle
  }
  const range = ranges[low]
  return range !== undefined && range.start < end
}
