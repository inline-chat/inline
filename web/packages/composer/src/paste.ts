import {
  plainContent,
  readInternal,
  type ClipboardContent,
  type HtmlParser,
  type InternalClipboard,
  type PastedContent,
  type UrlPolicy,
} from "./internal"
import { markKey, normalizeEntities, normalizeText, type ComposerEntity, type Mark, type MarkType } from "./model"

/**
 * Clipboard to model: HTML and plain text become `{ text, entities }`.
 * Nothing from the clipboard is ever inserted as HTML. The HTML is parsed
 * into an inert document (no scripts run, nothing loads) and walked; only
 * text, line structure and a fixed set of formatting survive:
 *
 * - bold (`b`, `strong`, `font-weight` 600 or more), italic (`i`, `em`,
 *   `font-style: italic`), underline (`u`, `ins`, `text-decoration`),
 *   strikethrough (`s`, `strike`, `del`, `text-decoration`), inline code
 *   (`code`, `kbd`, `samp`, `tt`), code blocks (`pre`), and links (`a[href]`
 *   whose URL the injected policy accepts);
 * - blocks and `br` become line breaks; list items get a bullet or number;
 *   table cells are separated by tabs;
 * - everything else (scripts, styles, images, frames, forms, comments,
 *   hidden elements, attributes) is dropped.
 *
 * Hidden means hidden from layout: `display: none`, `visibility: hidden`,
 * the `hidden` attribute and `mso-hide: all`, as the browser's own plain-text
 * copy leaves them out. Text that is only made invisible (zero font size,
 * `opacity: 0`, the background's color, off screen, clipped) is kept as
 * plain visible text on purpose: no style survives a paste, so the user sees
 * all of it in the composer before sending (tests: "text hidden by styling").
 *
 * Text then goes through `normalizeText`: line endings become `\n`,
 * non-breaking spaces become spaces, control characters are removed, and the
 * zero-width non-joiner (U+200C) that Persian depends on is kept.
 *
 * Loaded on first use (`loadPasteModule` in `./clipboard`, or the subpath
 * `@inline/composer/paste`): the controller pastes the composer's own
 * payloads and plain text without it (`quickPaste`), and parses HTML late
 * when a paste arrives before this module does.
 */

export {
  INTERNAL_MIME,
  parseInternal,
  serializeInternal,
  wroteInternal,
  type ClipboardContent,
  type HtmlParser,
  type PastedContent,
  type UrlPolicy,
} from "./internal"

export type PasteOptions = {
  /** The app's link allowlist (owned by `chat-ui`). */
  safeUrl: UrlPolicy
  /** Paste and match style: ignore HTML and internal content. */
  plain?: boolean
  /** Defaults to `defaultHtmlParser`. */
  parseHtml?: HtmlParser
  /** HTML longer than this falls back to plain text. Start: 512 KB. */
  maxHtmlLength?: number
  /**
   * Recognizes the composer's own payloads (`./internal`). Default
   * `documentClipboard`: only this document's. The web app passes one keyed
   * with a per-browser secret so its tabs honor each other's copies.
   */
  clipboard?: InternalClipboard
}

const MAX_HTML = 512 * 1024

/**
 * `DOMParser` in the page. Under the production policy
 * (`require-trusted-types-for 'script'`, with `inline-script-url` the only
 * policy name allowed and no `default` policy), engines that enforce Trusted
 * Types refuse a plain string here and this returns `null`, so paste falls
 * back to plain text. The app can pass a parser that goes through a Trusted
 * Types policy instead (see README); that needs its name added to the
 * content policy, a reviewed change.
 */
export const defaultHtmlParser: HtmlParser = (html) => {
  const Parser = (globalThis as { DOMParser?: typeof DOMParser }).DOMParser
  if (!Parser) return null
  try {
    return new Parser().parseFromString(html, "text/html")
  } catch {
    return null
  }
}

export const sanitizePaste = (content: ClipboardContent, options: PasteOptions): PastedContent => {
  if (!options.plain && content.internal) {
    const internal = readInternal(content.internal, options.safeUrl, options.clipboard)
    if (internal) return internal
  }
  const plain = content.text ?? ""
  if (!options.plain && content.html && content.html.length <= (options.maxHtmlLength ?? MAX_HTML)) {
    const doc = (options.parseHtml ?? defaultHtmlParser)(content.html)
    if (doc) {
      const fromHtml = htmlDocumentToContent(doc, options.safeUrl)
      if (fromHtml.text.trim() !== "" || plain.trim() === "") return fromHtml
    }
  }
  return plainContent(content)
}

// ---------------------------------------------------------------------------
// HTML

const skipped: ReadonlySet<string> = new Set([
  "applet", "area", "audio", "base", "button", "canvas", "datalist", "embed", "frame", "frameset",
  "head", "iframe", "img", "input", "link", "map", "math", "meta", "noembed", "noframes",
  "noscript", "object", "option", "param", "picture", "script", "select", "source", "style",
  "svg", "template", "textarea", "title", "track", "video",
])

const blocks: ReadonlySet<string> = new Set([
  "address", "article", "aside", "blockquote", "body", "center", "dd", "details", "dialog", "div",
  "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5",
  "h6", "header", "hgroup", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "summary",
  "table", "tbody", "tfoot", "thead", "tr", "ul", "caption",
])

const tagMarks: Readonly<Record<string, MarkType>> = {
  b: "bold",
  strong: "bold",
  i: "italic",
  em: "italic",
  u: "underline",
  ins: "underline",
  s: "strikethrough",
  strike: "strikethrough",
  del: "strikethrough",
  code: "code",
  kbd: "code",
  samp: "code",
  tt: "code",
}

const parseStyle = (style: string | null): Map<string, string> => {
  const map = new Map<string, string>()
  if (!style) return map
  for (const part of style.split(";")) {
    const colon = part.indexOf(":")
    if (colon < 0) continue
    const key = part.slice(0, colon).trim().toLowerCase()
    const value = part.slice(colon + 1).trim().toLowerCase().replace(/\s*!important$/, "")
    if (key) map.set(key, value)
  }
  return map
}

const ELEMENT = 1
const TEXT = 3
const CDATA = 4

type Frame = {
  marks: Map<string, Mark>
  pre: boolean
  inLink: boolean
}

type ListState = { ordered: boolean; next: number }

class Walker {
  out = ""
  entities: ComposerEntity[] = []
  private atLineStart = true
  private pendingBreak = false
  private pendingSpace = false
  private lastMarks: Map<string, Mark> = new Map()
  private lists: ListState[] = []
  private visited = 0

  constructor(private readonly safeUrl: UrlPolicy) {}

  private breakLine() {
    if (this.out.length > 0 && !this.out.endsWith("\n")) this.pendingBreak = true
    this.pendingSpace = false
  }

  private flushBreak() {
    if (this.pendingBreak) {
      this.out += "\n"
      this.atLineStart = true
      this.pendingBreak = false
      this.pendingSpace = false
    }
  }

  private emit(text: string, marks: Map<string, Mark>) {
    if (text.length === 0) return
    this.flushBreak()
    if (this.pendingSpace && !this.atLineStart) {
      const start = this.out.length
      this.out += " "
      for (const [key, mark] of marks) {
        if (this.lastMarks.has(key)) this.pushMark(mark, start, 1)
      }
    }
    this.pendingSpace = false
    const start = this.out.length
    this.out += text
    for (const mark of marks.values()) this.pushMark(mark, start, text.length)
    this.lastMarks = marks
    this.atLineStart = text.endsWith("\n")
  }

  private pushMark(mark: Mark, offset: number, length: number) {
    const entity: ComposerEntity = { type: mark.type, offset, length }
    if (mark.url !== undefined) entity.url = mark.url
    if (mark.language !== undefined) entity.language = mark.language
    this.entities.push(entity)
  }

  private text(raw: string, frame: Frame) {
    if (frame.pre) {
      this.emit(raw.replace(/\r\n?/g, "\n"), frame.marks)
      return
    }
    const collapsed = raw.replace(/[ \t\n\r\f]+/g, " ")
    if (collapsed === "") return
    const leading = collapsed.startsWith(" ")
    const trailing = collapsed.endsWith(" ") && collapsed.length > 1
    let core = collapsed
    if (leading) core = core.slice(1)
    if (core.endsWith(" ")) core = core.slice(0, -1)
    if (leading && !this.atLineStart && this.out.length > 0) this.pendingSpace = true
    if (core === "") return
    // Nothing but non-breaking spaces at the start of a line is how Word and
    // others draw an empty paragraph: keep it as an empty line.
    if ((this.atLineStart || this.pendingBreak) && /^[\s\u00A0]*$/.test(core)) {
      this.flushBreak()
      this.emit("\n", new Map())
      return
    }
    this.emit(core, frame.marks)
    if (trailing) this.pendingSpace = true
  }

  walk(node: Node, frame: Frame) {
    if (++this.visited > 200_000) return
    if (node.nodeType === TEXT || node.nodeType === CDATA) {
      this.text(node.nodeValue ?? "", frame)
      return
    }
    if (node.nodeType !== ELEMENT) {
      // Documents and fragments recurse; comments and the rest are dropped.
      if (node.nodeType === 9 || node.nodeType === 11) this.children(node, frame)
      return
    }
    const el = node as Element
    const tag = el.localName.toLowerCase()
    if (skipped.has(tag)) return
    if (el.hasAttribute("hidden")) return
    const style = parseStyle(el.getAttribute("style"))
    if (style.get("display") === "none" || style.get("visibility") === "hidden" || style.get("mso-hide") === "all") {
      return
    }

    if (tag === "br") {
      this.flushBreak()
      this.pendingSpace = false
      this.emit("\n", new Map())
      return
    }

    const marks = new Map(frame.marks)
    let pre = frame.pre
    let inLink = frame.inLink
    const add = (mark: Mark) => marks.set(markKey(mark), mark)
    const removeType = (type: MarkType) => {
      for (const [key, mark] of marks) if (mark.type === type) marks.delete(key)
    }

    const tagMark = tagMarks[tag]
    if (tagMark && !(tagMark === "code" && pre)) add({ type: tagMark })
    const weight = style.get("font-weight")
    if (weight !== undefined) {
      const numeric = Number.parseInt(weight, 10)
      if (weight === "bold" || weight === "bolder" || numeric >= 600) add({ type: "bold" })
      else if (weight === "normal" || weight === "lighter" || numeric > 0) removeType("bold")
    }
    const fontStyle = style.get("font-style")
    if (fontStyle === "italic" || fontStyle === "oblique") add({ type: "italic" })
    else if (fontStyle === "normal") removeType("italic")
    const decoration = `${style.get("text-decoration") ?? ""} ${style.get("text-decoration-line") ?? ""}`
    if (decoration.includes("underline") && !inLink) add({ type: "underline" })
    if (decoration.includes("line-through")) add({ type: "strikethrough" })

    if (tag === "a") {
      const href = el.getAttribute("href")
      const url = href ? this.safeUrl(href.trim()) : null
      if (url) {
        removeType("textUrl")
        add({ type: "textUrl", url })
        removeType("underline")
        inLink = true
      }
    }
    if (tag === "pre") {
      pre = true
      removeType("code")
      const language = languageOf(el)
      add(language ? { type: "pre", language } : { type: "pre" })
    }

    const isBlock = blocks.has(tag)
    if (isBlock) this.breakLine()

    if (tag === "ul" || tag === "ol") {
      const start = Number.parseInt(el.getAttribute("start") ?? "1", 10)
      this.lists.push({ ordered: tag === "ol", next: Number.isFinite(start) ? start : 1 })
    }
    if (tag === "li") {
      const list = this.lists[this.lists.length - 1]
      this.flushBreak()
      const bullet = list?.ordered ? `${list.next++}. ` : "• "
      this.emit(bullet, new Map())
    }
    if ((tag === "td" || tag === "th") && el.previousElementSibling) {
      this.flushBreak()
      this.emit("\t", new Map())
    }

    const childFrame: Frame = { marks, pre, inLink }
    this.children(el, childFrame)

    if (tag === "ul" || tag === "ol") this.lists.pop()
    if (isBlock) this.breakLine()
  }

  private children(node: Node, frame: Frame) {
    for (let child = node.firstChild; child; child = child.nextSibling) this.walk(child, frame)
  }
}

const languageOf = (pre: Element): string | undefined => {
  const candidates = [pre.getAttribute("class"), pre.querySelector("code")?.getAttribute("class")]
  for (const value of candidates) {
    const match = value ? /(?:^|\s)(?:language|lang)-([\w+#.-]{1,32})/.exec(value) : null
    if (match) return match[1]
  }
  return undefined
}

/** Walk a parsed HTML document into text and entities. */
export const htmlDocumentToContent = (doc: Document, safeUrl: UrlPolicy): PastedContent => {
  const walker = new Walker(safeUrl)
  const root = doc.body ?? doc.documentElement
  if (root) walker.walk(root, { marks: new Map(), pre: false, inLink: false })
  // Drop leading and trailing line breaks left by block boundaries.
  let text = walker.out
  let entities = walker.entities
  const lead = /^\n+/.exec(text)?.[0].length ?? 0
  if (lead > 0) {
    text = text.slice(lead)
    entities = entities.map((e) => ({ ...e, offset: e.offset - lead }))
  }
  text = text.replace(/\n+$/, "")
  const clean = normalizeText(text, entities)
  const normalized = normalizeEntities(clean.text, clean.entities)
  return {
    text: clean.text,
    // A link whose text is its own URL is left to the server's URL detection.
    entities: normalized.filter(
      (e) => !(e.type === "textUrl" && clean.text.slice(e.offset, e.offset + e.length) === e.url),
    ),
  }
}
