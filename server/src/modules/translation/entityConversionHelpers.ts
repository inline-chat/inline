/**
 * Create indexed text showing UTF-16 character positions like "Hi" -> "0H1i"
 */
export function createIndexedText(text: string): string {
  let out = ""
  let index = 0

  for (const char of text) {
    out += `${index}${char}`
    index += char.length
  }

  return out
}
