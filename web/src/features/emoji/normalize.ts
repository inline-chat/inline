/**
 * Search text normalization, a port of the Mac's `EmojiAutocomplete.normalize`
 * (`apple/InlineUI/Sources/EmojiAutocomplete/EmojiAutocomplete.swift`, lines
 * 323-347). Used by the search engine for terms and queries and by the data
 * generator for shortcodes rebuilt from accented labels.
 *
 * - Case and diacritics fold (`folding([.caseInsensitive, .diacriticInsensitive])`).
 * - Letters, marks and digits are kept (`CharacterSet.alphanumerics`).
 * - `+` and `-` are kept as a sign when they start a word and a digit (or the
 *   end) follows, so "+1" and "-1" survive.
 * - `_`, space, `-`, `:` and `.` become one `_`; runs collapse and the ends are trimmed.
 * - Anything else is dropped.
 */

const alphanumeric = /[\p{L}\p{M}\p{N}]/u
const decimalDigit = /\p{Nd}/u
const combiningMark = /\p{Mn}/gu

const isSeparator = (char: string) => char === "_" || char === " " || char === "-" || char === ":" || char === "."

export const normalize = (value: string): string => {
  const folded = value.normalize("NFD").replace(combiningMark, "").normalize("NFC").toLowerCase()
  const scalars = Array.from(folded)
  let result = ""
  let previousWasSeparator = false
  for (let index = 0; index < scalars.length; index++) {
    const scalar = scalars[index] as string
    const next = scalars[index + 1]
    const isSignedNumber =
      (scalar === "+" || scalar === "-") &&
      (result.length === 0 || previousWasSeparator) &&
      (next === undefined || decimalDigit.test(next))
    if (isSignedNumber || alphanumeric.test(scalar)) {
      result += scalar
      previousWasSeparator = false
    } else if (isSeparator(scalar)) {
      if (result.length === 0 || previousWasSeparator) continue
      result += "_"
      previousWasSeparator = true
    }
  }
  let end = result.length
  while (end > 0 && result.charCodeAt(end - 1) === 95) end--
  return result.slice(0, end)
}

/**
 * The UTF-8 bytes of a string as a "binary string" (one char per byte). The
 * Mac compares terms and queries as UTF-8 bytes; every dataset term is ASCII
 * (the generator checks), so terms are their own binary strings and a query
 * converted with this compares, measures and edits byte for byte as in Swift.
 */
export const utf8Binary = (value: string): string => {
  // Fast path: ASCII is its own binary string.
  let ascii = true
  for (let i = 0; i < value.length; i++) {
    if (value.charCodeAt(i) > 0x7f) {
      ascii = false
      break
    }
  }
  if (ascii) return value
  let out = ""
  for (const byte of new TextEncoder().encode(value)) out += String.fromCharCode(byte)
  return out
}
