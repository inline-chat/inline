import { MessageEntity_Type, type MessageEntities } from "@inline-chat/protocol/core"
import { removeSourceRanges } from "../message/markdownSourceMap"
import { toRange } from "./entities/offsets"
import type { MarkdownText } from "./entities/types"

/** Fenced Markdown requires a newline before its closing delimiter, but a
 * native PRE need not end with one. Restore only an exact source-body match
 * plus that one newline. General fromMd parsing retains its whitespace policy.
 * Ambiguous originals (both "x" and "x\n") are deliberately left unchanged. */
export function restoreCodeTrailingNewlines(parsed: MarkdownText, sourceText: string, sourceEntities?: MessageEntities | null): MarkdownText {
  const originals = new Set<string>()
  for (const entity of sourceEntities?.entities ?? []) {
    if (entity.type !== MessageEntity_Type.PRE) continue
    const range = toRange(sourceText, entity)
    if (range) originals.add(sourceText.slice(range.start, range.end))
  }
  const addedNewlines = new Set([...originals].filter((body) => !body.endsWith("\n") && !originals.has(`${body}\n`))
    .map((body) => `${body}\n`))
  if (!addedNewlines.size) return parsed
  const removals = parsed.entities.entities.flatMap((entity) => {
    if (entity.type !== MessageEntity_Type.PRE) return []
    const range = toRange(parsed.text, entity)
    return range && addedNewlines.has(parsed.text.slice(range.start, range.end)) ? [{ start: range.end - 1, end: range.end }] : []
  })
  if (!removals.length) return parsed
  const projected = removeSourceRanges(parsed.text, removals)
  return { text: projected.text, entities: { entities: parsed.entities.entities.flatMap((entity) => {
    const range = toRange(parsed.text, entity)
    if (!range) return []
    const start = projected.sourceToOutput[range.start]!, end = projected.sourceToOutput[range.end]!
    return start < end ? [{ ...entity, offset: BigInt(start), length: BigInt(end - start) }] : []
  }) } }
}
