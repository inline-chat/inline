export type MarkdownImageEmbed = {
  readonly type: "image"
  readonly alt: string
  readonly url: string
  readonly title?: string
}

export type MarkdownOutput = {
  readonly text: string
  readonly images: readonly MarkdownImageEmbed[]
}

export type ParseMarkdownOutputOptions = {
  readonly maxImages?: number
  readonly allowedImageProtocols?: readonly string[]
}

const defaultMaxImages = 8
const markdownLinkSpanPattern = /!?\[(?:\\[\s\S]|[^\]\\])*\]\((?:\\[\s\S]|[^)\\])*\)/g
const detachedListLinkPattern = /^([ \t]*(?:[-*+]|\d{1,3}[.)]))[ \t]*\n[ \t]+(?=!\[|\[)/gm

export function parseMarkdownOutput(markdown: string, options: ParseMarkdownOutputOptions = {}): MarkdownOutput {
  const maxImages = options.maxImages ?? defaultMaxImages
  const images: MarkdownImageEmbed[] = []
  const lines = normalizeMarkdownText(markdown).split("\n")
  const output: string[] = []
  let inFence = false

  for (const line of lines) {
    if (isFenceBoundary(line)) {
      inFence = !inFence
      output.push(line)
      continue
    }

    if (inFence || images.length >= maxImages) {
      output.push(line)
      continue
    }

    const { text, extracted } = extractLineImages(line, {
      remaining: maxImages - images.length,
      allowedImageProtocols: options.allowedImageProtocols,
    })
    images.push(...extracted)
    output.push(text)
  }

  return {
    text: cleanupRemovedImageWhitespace(output.join("\n")),
    images,
  }
}

export function normalizeMarkdownText(markdown: string): string {
  const output: string[] = []
  let pending: string[] = []
  let inFence = false

  for (const line of markdown.split("\n")) {
    if (isFenceBoundary(line)) {
      if (!inFence) {
        flushPending(output, pending)
        pending = []
      }
      output.push(line)
      inFence = !inFence
      continue
    }

    if (inFence) {
      output.push(line)
    } else {
      pending.push(line)
    }
  }

  flushPending(output, pending)
  return output.join("\n")
}

function extractLineImages(
  line: string,
  options: {
    readonly remaining: number
    readonly allowedImageProtocols?: readonly string[]
  },
): { readonly text: string; readonly extracted: MarkdownImageEmbed[] } {
  const extracted: MarkdownImageEmbed[] = []
  let text = ""
  let index = 0

  while (index < line.length) {
    const parsed = extracted.length < options.remaining && line.startsWith("![", index)
      ? parseImageSpan(line, index)
      : undefined

    if (!parsed) {
      text += line[index] ?? ""
      index += 1
      continue
    }

    if (!parsed.target.url || !isAllowedImageUrl(parsed.target.url, options.allowedImageProtocols)) {
      text += line.slice(index, parsed.end)
      index = parsed.end
      continue
    }

    extracted.push({
      type: "image",
      alt: decodeMarkdownText(parsed.alt).trim(),
      url: parsed.target.url,
      title: parsed.target.title,
    })
    index = parsed.end
  }

  return { text, extracted }
}

function parseImageSpan(
  line: string,
  start: number,
): { readonly alt: string; readonly target: ParsedImageTarget; readonly end: number } | undefined {
  const labelStart = start + 2
  const labelEnd = findClosingBracket(line, labelStart)
  if (labelEnd === undefined || line[labelEnd + 1] !== "(") {
    return undefined
  }

  const destination = parseLinkDestination(line, labelEnd + 1)
  if (!destination) {
    return undefined
  }

  return {
    alt: line.slice(labelStart, labelEnd),
    target: parseImageTarget(destination.value),
    end: destination.end,
  }
}

function findClosingBracket(line: string, start: number): number | undefined {
  for (let index = start; index < line.length; index += 1) {
    const char = line[index]
    if (char === "\\") {
      index += 1
      continue
    }
    if (char === "]") {
      return index
    }
  }
  return undefined
}

function parseLinkDestination(line: string, openParen: number): { readonly value: string; readonly end: number } | undefined {
  let index = openParen + 1
  while (line[index] === " " || line[index] === "\t") {
    index += 1
  }

  let depth = 0
  for (; index < line.length; index += 1) {
    const char = line[index]
    if (char === "\\") {
      index += 1
      continue
    }
    if (char === "(") {
      depth += 1
      continue
    }
    if (char !== ")") {
      continue
    }
    if (depth > 0) {
      depth -= 1
      continue
    }

    return {
      value: line.slice(openParen + 1, index).trim(),
      end: index + 1,
    }
  }

  return undefined
}

type ParsedImageTarget = {
  readonly url: string
  readonly title?: string
}

function parseImageTarget(value: string): ParsedImageTarget {
  const trimmed = value.trim()
  if (trimmed.startsWith("<")) {
    const close = trimmed.indexOf(">")
    if (close !== -1) {
      return {
        url: removeLineBreaks(trimmed.slice(1, close)),
        title: normalizeOptionalTitle(trimmed.slice(close + 1)),
      }
    }
  }

  const title = splitTrailingTitle(trimmed)
  if (title) {
    return {
      url: removeLineBreaks(title.target),
      title: normalizeOptionalTitle(title.title),
    }
  }

  return { url: removeLineBreaks(trimmed) }
}

function flushPending(output: string[], pending: readonly string[]): void {
  if (pending.length === 0) {
    return
  }

  output.push(normalizeMarkdownSegment(pending.join("\n")))
}

function normalizeMarkdownSegment(text: string): string {
  return text.replace(detachedListLinkPattern, "$1 ").replace(markdownLinkSpanPattern, normalizeMarkdownLinkSpan)
}

function normalizeMarkdownLinkSpan(span: string): string {
  const parts = splitMarkdownLinkSpan(span)
  if (!parts) {
    return span
  }

  const label = normalizeLinkLabel(parts.label)
  const target = normalizeLinkTarget(parts.target)
  return `${parts.prefix}[${label}](${target})`
}

function splitMarkdownLinkSpan(span: string): { readonly prefix: "" | "!"; readonly label: string; readonly target: string } | undefined {
  const prefix = span.startsWith("![") ? "!" : ""
  const labelStart = prefix ? 2 : 1

  for (let i = labelStart; i < span.length - 1; i++) {
    const char = span[i]
    if (char === "\\") {
      i += 1
      continue
    }

    if (char === "]" && span[i + 1] === "(" && span.endsWith(")")) {
      return {
        prefix,
        label: span.slice(labelStart, i),
        target: span.slice(i + 2, -1),
      }
    }
  }

  return undefined
}

function normalizeLinkLabel(value: string): string {
  return value.replace(/[ \t]*\n[ \t]*/g, " ").replace(/[ \t]{2,}/g, " ").trim()
}

function normalizeLinkTarget(value: string): string {
  const trimmed = value.trim()
  if (!trimmed) {
    return trimmed
  }

  if (trimmed.startsWith("<")) {
    const close = trimmed.indexOf(">")
    if (close !== -1) {
      const url = removeLineBreaks(trimmed.slice(0, close + 1))
      const title = normalizeTitlePart(trimmed.slice(close + 1))
      return title ? `${url} ${title}` : url
    }
  }

  const title = splitTrailingTitle(trimmed)
  if (title) {
    const target = removeLineBreaks(title.target)
    const titlePart = normalizeTitlePart(title.title)
    return titlePart ? `${target} ${titlePart}` : target
  }

  return removeLineBreaks(trimmed)
}

function splitTrailingTitle(value: string): { readonly target: string; readonly title: string } | undefined {
  const end = value.trimEnd()
  const quote = end.at(-1)
  if (quote !== '"' && quote !== "'") {
    return undefined
  }

  for (let i = end.length - 2; i >= 0; i--) {
    if (end[i] !== quote) {
      continue
    }

    const beforeQuote = end[i - 1]
    if (beforeQuote === undefined || /\s/.test(beforeQuote)) {
      return {
        target: end.slice(0, i).trimEnd(),
        title: end.slice(i),
      }
    }
  }

  return undefined
}

function normalizeTitlePart(value: string): string {
  return value.replace(/[ \t]*\n[ \t]*/g, " ").replace(/[ \t]{2,}/g, " ").trim()
}

function removeLineBreaks(value: string): string {
  return value.replace(/[ \t]*\n[ \t]*/g, "").trim()
}

function decodeMarkdownText(value: string): string {
  return value.replace(/\\([\\`*_{}`[\]()#+\-.!|>])/g, "$1")
}

function normalizeOptionalTitle(value: string): string | undefined {
  const title = normalizeTitlePart(value)
  if (!title) {
    return undefined
  }

  const first = title[0]
  const last = title.at(-1)
  if ((first !== "\"" && first !== "'") || last !== first || title.length < 2) {
    return undefined
  }

  const decoded = decodeMarkdownText(title.slice(1, -1)).trim()
  return decoded || undefined
}

function isAllowedImageUrl(value: string, allowedProtocols: readonly string[] | undefined): boolean {
  if (!allowedProtocols) {
    return true
  }

  try {
    return allowedProtocols.includes(new URL(value).protocol)
  } catch {
    return false
  }
}

function cleanupRemovedImageWhitespace(text: string): string {
  const output: string[] = []
  let inFence = false

  for (const line of text.split("\n")) {
    if (isFenceBoundary(line)) {
      inFence = !inFence
      output.push(line)
      continue
    }

    if (inFence) {
      output.push(line)
      continue
    }

    const cleaned = line.replace(/[ \t]{2,}/g, " ").trimEnd()
    output.push(isBareListMarker(cleaned) ? "" : cleaned)
  }

  return output.join("\n").replace(/\n{3,}/g, "\n\n").trim()
}

function isFenceBoundary(line: string): boolean {
  return /^\s*(```|~~~)/.test(line)
}

function isBareListMarker(line: string): boolean {
  return /^\s*(?:[-*+]|\d{1,3}[.)])$/.test(line)
}
