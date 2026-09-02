export type MarkdownLine = { start: number; contentEnd: number; next: number; value: string }
export type MarkdownFence = { character: "`" | "~"; length: number; info: string; indent: number }

export function readLine(text: string, start: number): MarkdownLine {
  const newline = text.indexOf("\n", start)
  const rawEnd = newline >= 0 ? newline : text.length
  const contentEnd = rawEnd > start && text[rawEnd - 1] === "\r" ? rawEnd - 1 : rawEnd
  return { start, contentEnd, next: rawEnd < text.length ? rawEnd + 1 : text.length, value: text.slice(start, contentEnd) }
}

export function parseOpeningFence(line: string): MarkdownFence | undefined {
  const match = /^( {0,3})(`{3,}|~{3,})(.*)$/.exec(line)
  const run = match?.[2]
  if (!run) return undefined
  const info = match?.[3] ?? ""
  if (run[0] === "`" && info.includes("`")) return undefined
  return { character: run[0] as "`" | "~", length: run.length, info, indent: match?.[1]?.length ?? 0 }
}

export function isClosingFence(line: string, fence: MarkdownFence): boolean {
  const match = /^ {0,3}(`+|~+)[ \t]*$/.exec(line)
  const run = match?.[1]
  return run?.[0] === fence.character && run.length >= fence.length
}

export function cleanFenceLanguage(info: string): string {
  const language = info.trim().split(/[ \t]+/, 1)[0] ?? ""
  return /^[A-Za-z0-9_+.#-]{0,64}$/.test(language) ? language : ""
}

/** The caller visits line starts in source order, outside other opaque spans. */
export function readFencedCode(text: string, start: number): {
  start: number; contentStart: number; contentEnd: number; end: number; language: string
} | undefined {
  const openingLine = readLine(text, start)
  const opening = parseOpeningFence(openingLine.value)
  if (!opening) return undefined
  let cursor = openingLine.next
  while (cursor < text.length) {
    const line = readLine(text, cursor)
    if (isClosingFence(line.value, opening)) {
      return { start: start + opening.indent, contentStart: openingLine.next, contentEnd: line.start,
        end: line.contentEnd, language: cleanFenceLanguage(opening.info) }
    }
    cursor = line.next
  }
  // Incomplete streaming fences protect the remaining document too.
  return { start: start + opening.indent, contentStart: openingLine.next, contentEnd: text.length,
    end: text.length, language: cleanFenceLanguage(opening.info) }
}
