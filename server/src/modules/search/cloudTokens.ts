import { createHmac } from "node:crypto"
import { GlobalSearchExcerpt_Field, type GlobalSearchExcerpt } from "@inline-chat/protocol/core"

export const CLOUD_TOKENIZER_VERSION = "inline-whole-word-v1"
export type CloudSearchFields = { text?: string | null; fileName?: string | null }
type Field = keyof CloudSearchFields
type Token = { value: string; start: number; end: number }
export type ParsedCloudQuery = string[][]
const fields: Field[] = ["text", "fileName"]
const segmenter = new Intl.Segmenter("und", { granularity: "word" })

function normalize(word: string): string {
  return word
    .normalize("NFC")
    .toLowerCase()
    .replace(/ς/gu, "σ")
    .replace(/[\u0640\u064b-\u0652]/gu, "")
    .replace(/[أإآٱ]/gu, "ا")
    .replace(/ک/gu, "ك")
    .replace(/ی/gu, "ي")
    .replace(/[٠-٩۰-۹]/gu, (digit) => String(digit.charCodeAt(0) & 15))
    .normalize("NFC")
}

function tokenize(text: string): Token[] {
  // Replace each separator with one UTF-16 unit so ICU offsets point into the original display string.
  const parts = segmenter.segment(text.replace(/[._/@:\\-]/gu, " "))
  const tokens: Token[] = []
  for (const part of parts) {
    if (!part.isWordLike) continue
    const value = normalize(part.segment)
    if (value) tokens.push({ value, start: part.index, end: part.index + part.segment.length })
  }
  return tokens
}

export function parseCloudQuery(query: string): ParsedCloudQuery {
  if (Buffer.byteLength(query) > 512 || query.includes("*")) throw new Error("Invalid search query")
  const parts = query.split('"')
  if (parts.length % 2 === 0) throw new Error("Unclosed search phrase")
  const terms: ParsedCloudQuery = []
  let count = 0
  for (const [index, part] of parts.entries()) {
    const groups = index % 2 === 0 ? part.split(/\s+/u) : [part]
    for (const group of groups) {
      const words = tokenize(group).map((token) => token.value)
      if (!words.length && index % 2) throw new Error("Empty search phrase")
      count += words.length
      if (words.length) terms.push(words)
    }
  }
  if (!count || count > 8) throw new Error("Invalid number of search words")
  return terms
}

function tag(chatId: number, key: Uint8Array, field: Field, word: string): string {
  // PostgreSQL accepts 32 hex digits as a UUID without overwriting version or variant bits.
  const hex = createHmac("sha256", key)
    .update(JSON.stringify(["inline-search", CLOUD_TOKENIZER_VERSION, chatId, field, "word", word]))
    .digest("hex")
    .slice(0, 32)
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}

export function cloudDocumentTags(
  chatId: number,
  key: Uint8Array,
  values: CloudSearchFields,
  limit: number,
): string[] | null {
  const tags: string[] = []
  for (const field of fields) {
    const words = new Set(tokenize(values[field] ?? "").map((token) => token.value))
    if (tags.length + words.size > limit) return null
    for (const word of words) tags.push(tag(chatId, key, field, word))
  }
  return tags
}

export function cloudQueryTags(chatId: number, key: Uint8Array, terms: ParsedCloudQuery): string[][] {
  return [...new Set(terms.flat())].map((word) => fields.map((field) => tag(chatId, key, field, word)))
}

// Find each whole word or ordered phrase in one field. Unquoted words can span fields.
export function matchExcerpts(query: ParsedCloudQuery, values: CloudSearchFields): GlobalSearchExcerpt[] | undefined {
  const sources = fields.map((field) => {
    const text = values[field] ?? ""
    return { field, text, tokens: tokenize(text), found: new Set<Token>() }
  })
  for (const phrase of query) {
    let matched = false
    for (const source of sources) {
      const start = source.tokens.findIndex((_, i) => phrase.every((word, j) => source.tokens[i + j]?.value === word))
      if (start < 0) continue
      matched = true
      for (const token of source.tokens.slice(start, start + phrase.length)) source.found.add(token)
    }
    if (!matched) return undefined
  }
  const result: GlobalSearchExcerpt[] = []
  for (const { field, text, found } of sources) {
    const tokens = [...found].sort((a, b) => a.start - b.start)
    while (tokens.length) {
      const first = tokens[0]!
      let start = Math.max(0, first.start - 48)
      let end = Math.min(text.length, start + 256, Math.max(first.end, first.start + 160))
      if (start > 0 && /[\uDC00-\uDFFF]/u.test(text[start]!)) start--
      if (end < text.length && /[\uDC00-\uDFFF]/u.test(text[end]!)) end++
      const highlights = []
      while (tokens.length && tokens[0]!.start < end) {
        const token = tokens.shift()!
        highlights.push({ offset: token.start - start, length: Math.min(token.end, end) - token.start })
      }
      result.push({
        field: field === "text" ? GlobalSearchExcerpt_Field.BODY : GlobalSearchExcerpt_Field.DOCUMENT_FILENAME,
        text: text.slice(start, end),
        highlights,
      })
    }
  }
  return result
}
