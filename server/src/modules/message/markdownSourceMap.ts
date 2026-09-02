import type { EntityRange } from "../translation2/entities/types"

/** Parser metadata is ordered by source start. Nested labels only need their
 * own spans, without rescanning the whole document for each label. */
export function sourceRangesWithin<T extends EntityRange>(ranges: readonly T[], start: number, end: number): T[] {
  let low = 0, high = ranges.length
  while (low < high) {
    const middle = (low + high) >>> 1
    if (ranges[middle]!.start < start) low = middle + 1
    else high = middle
  }
  const result: T[] = []
  for (let index = low; index < ranges.length && ranges[index]!.start < end; index++) {
    const range = ranges[index]!
    if (range.end <= end) result.push(range)
  }
  return result
}

/** Remove verified source spans and retain every UTF-16 boundary. Invalid input
 * leaves the original text intact rather than clamping or deleting other text. */
export function removeSourceRanges(source: string, ranges: EntityRange[]): { text: string; sourceToOutput: number[] } {
  const identity = () => ({ text: source, sourceToOutput: Array.from({ length: source.length + 1 }, (_, index) => index) })
  if (ranges.some((range) => !Number.isInteger(range.start) || !Number.isInteger(range.end)
    || range.start < 0 || range.end < range.start || range.end > source.length)) return identity()
  const sorted = ranges.filter((range) => range.end > range.start).sort((a, b) => a.start - b.start || a.end - b.end)
  if (!sorted.length) return identity()
  const sourceToOutput = Array<number>(source.length + 1).fill(0)
  const parts: string[] = []
  let cursor = 0, output = 0
  for (const range of sorted) {
    if (range.end <= cursor) continue
    const start = Math.max(cursor, range.start)
    parts.push(source.slice(cursor, start))
    for (let index = cursor; index <= start; index++) sourceToOutput[index] = output + index - cursor
    output += start - cursor
    sourceToOutput.fill(output, start, range.end + 1)
    cursor = range.end
  }
  parts.push(source.slice(cursor))
  for (let index = cursor; index <= source.length; index++) sourceToOutput[index] = output + index - cursor
  return { text: parts.join(""), sourceToOutput }
}
