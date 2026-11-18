import type { ComposerEntity } from "./types"

/**
 * Characters removed from text entering the composer: C0 controls other than
 * tab and line feed, DEL, and the byte-order mark. Zero-width joiners and
 * non-joiners (U+200D, U+200C) are kept: Persian and emoji depend on them.
 */
// oxlint-disable-next-line no-control-regex -- removing control characters is the point
const dropped = new RegExp("[\\u0000-\\u0008\\u000B\\u000C\\u000E-\\u001F\\u007F\\uFEFF]")

const lineSeparators = new RegExp("\\r\\n|[\\r\\u2028\\u2029]")

/**
 * Normalize text from outside (a draft, a message being edited, the
 * clipboard): CRLF, lone CR, U+2028 and U+2029 become `\n`; non-breaking
 * spaces (U+00A0) become plain spaces; control characters listed above are
 * removed. Entity offsets are mapped through the change, so ranges stay on
 * the same characters.
 */
export const normalizeText = (
  text: string,
  entities: readonly ComposerEntity[] = [],
): { text: string; entities: ComposerEntity[] } => {
  if (!lineSeparators.test(text) && !dropped.test(text) && !text.includes("\u00A0")) {
    return { text, entities: [...entities] }
  }
  // map[i] = new offset of old offset i (length + 1 entries).
  const map: number[] = Array.from({ length: text.length + 1 }, () => 0)
  let out = ""
  let i = 0
  while (i < text.length) {
    map[i] = out.length
    const ch = text[i]!
    if (ch === "\r" && text[i + 1] === "\n") {
      map[i + 1] = out.length
      out += "\n"
      i += 2
      continue
    }
    if (ch === "\r" || ch === "\u2028" || ch === "\u2029") out += "\n"
    else if (ch === "\u00A0") out += " "
    else if (!dropped.test(ch)) out += ch
    i += 1
  }
  map[text.length] = out.length
  const at = (offset: number) => map[Math.max(0, Math.min(text.length, offset))] ?? out.length
  const mapped = entities.map((e) => {
    const start = at(e.offset)
    const end = at(e.offset + e.length)
    return { ...e, offset: start, length: end - start }
  })
  return { text: out, entities: mapped }
}
