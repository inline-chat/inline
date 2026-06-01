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
}

export async function parseHtml(html: string): Promise<ParsedHtml> {
  const rewriter = (globalThis as { HTMLRewriter?: HTMLRewriterConstructor }).HTMLRewriter
  if (!rewriter) {
    return parseHtmlFallback(html)
  }

  const parsed: ParsedHtml = { meta: new Map() }
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
        addMeta(parsed.meta, key, content)
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

function parseHtmlFallback(html: string): ParsedHtml {
  const parsed: ParsedHtml = { meta: new Map() }
  const title = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]
  parsed.title = cleanField(stripTags(title), DEFAULT_TITLE_LENGTH) ?? undefined

  for (const match of html.matchAll(/<meta\s+([^>]+)>/gi)) {
    const attrs = parseAttributes(match[1] ?? "")
    addMeta(parsed.meta, attrs.get("property") ?? attrs.get("name"), attrs.get("content"))
  }

  return parsed
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

function addMeta(meta: Map<string, string>, key: string | null | undefined, value: string | null | undefined) {
  const normalizedKey = key?.trim().toLowerCase()
  const normalizedValue = cleanField(value, 1_000)
  if (!normalizedKey || !normalizedValue || meta.has(normalizedKey)) {
    return
  }
  meta.set(normalizedKey, normalizedValue)
}
