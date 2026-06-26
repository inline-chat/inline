import { DEFAULT_TITLE_LENGTH } from "./constants.js"
import { cleanField, stripTags } from "./text.js"

type HTMLRewriterText = { text: string }
type HTMLRewriterElement = { getAttribute(name: string): string | null }
type HTMLRewriterHandlers = {
  element?: (element: HTMLRewriterElement) => void
  text?: (text: HTMLRewriterText) => void
}
type HTMLRewriterInstance = {
  on(selector: string, handlers: HTMLRewriterHandlers): HTMLRewriterInstance
  transform(response: Response): Response
}
type HTMLRewriterConstructor = new () => HTMLRewriterInstance

export type ParsedHtml = {
  title?: string
  meta: Map<string, string>
  metaValues: Map<string, string[]>
}

export async function parseHtml(html: string): Promise<ParsedHtml> {
  const rewriter = (globalThis as { HTMLRewriter?: HTMLRewriterConstructor }).HTMLRewriter
  if (!rewriter) {
    return parseHtmlFallback(html)
  }

  const parsed = emptyParsedHtml()
  let title = ""

  const response = new rewriter()
    .on("title", {
      text(text) {
        title += text.text
      },
    })
    .on("meta", {
      element(element) {
        const key = element.getAttribute("property") ?? element.getAttribute("name")
        const content = element.getAttribute("content")
        addMeta(parsed, key, content)
      },
    })
    .transform(new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } }))

  await response.arrayBuffer()
  parsed.title = cleanField(title, DEFAULT_TITLE_LENGTH) ?? undefined
  return parsed
}

export function firstMeta(parsed: ParsedHtml, keys: readonly string[]): string | undefined {
  for (const key of keys) {
    const value = parsed.meta.get(key)
    if (value) {
      return value
    }
  }
  return undefined
}

export function allMeta(parsed: ParsedHtml, keys: readonly string[]): string[] {
  const values: string[] = []
  for (const key of keys) {
    values.push(...(parsed.metaValues.get(key) ?? []))
  }
  return values
}

function parseHtmlFallback(html: string): ParsedHtml {
  const parsed = emptyParsedHtml()
  const title = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]
  parsed.title = cleanField(stripTags(title), DEFAULT_TITLE_LENGTH) ?? undefined

  for (const match of html.matchAll(/<meta\s+([^>]+)>/gi)) {
    const attrs = parseAttributes(match[1] ?? "")
    addMeta(parsed, attrs.get("property") ?? attrs.get("name"), attrs.get("content"))
  }

  return parsed
}

function emptyParsedHtml(): ParsedHtml {
  return { meta: new Map(), metaValues: new Map() }
}

function parseAttributes(input: string): Map<string, string> {
  const attrs = new Map<string, string>()
  for (const match of input.matchAll(/([a-zA-Z_:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/g)) {
    const key = match[1]?.toLowerCase()
    const value = match[2] ?? match[3] ?? match[4]
    if (key && value != null) {
      attrs.set(key, value)
    }
  }
  return attrs
}

function addMeta(parsed: ParsedHtml, key: string | null | undefined, value: string | null | undefined) {
  const normalizedKey = key?.trim().toLowerCase()
  const normalizedValue = cleanField(value, 1_000)
  if (!normalizedKey || !normalizedValue) {
    return
  }

  if (!parsed.meta.has(normalizedKey)) {
    parsed.meta.set(normalizedKey, normalizedValue)
  }

  const values = parsed.metaValues.get(normalizedKey) ?? []
  values.push(normalizedValue)
  parsed.metaValues.set(normalizedKey, values)
}
