import {
  RichDirection,
  RichHorizontalAlign,
  RichTextStyle,
  RichVerticalAlign,
  type RichBlock,
  type RichMediaRef,
  type RichMessage,
  type RichTableCell,
  type RichTableRow,
  type RichText,
} from "@inline-chat/protocol/core"
import { RichTextValidationError, normalizeRichMessage, richTextLimits } from "./richText"

type HtmlNode =
  | { kind: "root"; children: HtmlNode[] }
  | { kind: "text"; text: string }
  | { kind: "element"; tag: string; attrs: Record<string, string | true>; children: HtmlNode[] }

type Token =
  | { kind: "text"; text: string }
  | { kind: "tag"; tag: string; closing: boolean; selfClosing: boolean; attrs: Record<string, string | true> }

type InlineCtx = {
  styles: RichTextStyle[]
  url?: string
}

const blockTags = new Set([
  "blockquote",
  "details",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "hr",
  "img",
  "ol",
  "p",
  "pre",
  "table",
  "ul",
])

const inlineTags = new Set([
  "a",
  "b",
  "br",
  "code",
  "del",
  "em",
  "i",
  "s",
  "span",
  "strike",
  "strong",
  "tg-spoiler",
  "u",
])

const transparentTableTags = new Set(["tbody", "thead", "tfoot"])

const allowedAttrs: Record<string, Set<string>> = {
  a: new Set(["href"]),
  blockquote: new Set(["expandable"]),
  code: new Set(["class"]),
  details: new Set(["open"]),
  img: new Set(["alt", "height", "src", "width"]),
  ol: new Set(["start"]),
  span: new Set(["class"]),
  table: new Set(["bordered", "striped"]),
  td: new Set(["align", "colspan", "rowspan", "valign"]),
  th: new Set(["align", "colspan", "rowspan", "valign"]),
}

const voidTags = new Set(["br", "hr", "img"])

export function parseRichHtml(input: string): RichMessage {
  const root = parseHtmlTree(input)
  const blocks = nodesToBlocks(root.children)
  return normalizeRichMessage({
    blocks,
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText: "",
    version: 1,
  })
}

function parseHtmlTree(input: string): HtmlNode & { kind: "root" } {
  const root: HtmlNode & { kind: "root" } = { kind: "root", children: [] }
  const stack: Array<HtmlNode & { kind: "root" | "element" }> = [root]

  for (const token of tokenize(input)) {
    const parent = stack.at(-1)
    if (!parent) {
      throw new RichTextValidationError("invalid rich HTML")
    }

    if (token.kind === "text") {
      if (token.text) {
        parent.children.push({ kind: "text", text: decodeHtmlEntities(token.text) })
      }
      continue
    }

    if (token.closing) {
      const current = stack.at(-1)
      if (!current || current.kind !== "element" || current.tag !== token.tag) {
        throw new RichTextValidationError(`mismatched rich HTML closing tag: ${token.tag}`)
      }
      stack.pop()
      continue
    }

    const node: HtmlNode & { kind: "element" } = { kind: "element", tag: token.tag, attrs: token.attrs, children: [] }
    parent.children.push(node)
    if (!token.selfClosing && !voidTags.has(token.tag)) {
      stack.push(node)
    }
  }

  if (stack.length !== 1) {
    const open = stack.at(-1)
    throw new RichTextValidationError(`unclosed rich HTML tag: ${open?.kind === "element" ? open.tag : "root"}`)
  }

  return root
}

function tokenize(input: string): Token[] {
  if (input.length > richTextLimits.maxTextLength * 4) {
    throw new RichTextValidationError("rich HTML input is too long")
  }

  const tokens: Token[] = []
  let index = 0

  while (index < input.length) {
    const open = input.indexOf("<", index)
    if (open === -1) {
      tokens.push({ kind: "text", text: input.slice(index) })
      break
    }

    if (open > index) {
      tokens.push({ kind: "text", text: input.slice(index, open) })
    }

    const close = input.indexOf(">", open + 1)
    if (close === -1) {
      throw new RichTextValidationError("unclosed rich HTML tag")
    }

    const raw = input.slice(open + 1, close).trim()
    if (!raw || raw.startsWith("!") || raw.startsWith("?")) {
      throw new RichTextValidationError("unsupported rich HTML tag")
    }

    const closing = raw.startsWith("/")
    const body = closing ? raw.slice(1).trim() : raw
    const selfClosing = !closing && body.endsWith("/")
    const tagBody = selfClosing ? body.slice(0, -1).trim() : body
    const nameMatch = tagBody.match(/^([A-Za-z][A-Za-z0-9-]*)([\s\S]*)$/)
    if (!nameMatch) {
      throw new RichTextValidationError("invalid rich HTML tag")
    }

    const tag = (nameMatch[1] ?? "").toLowerCase()
    assertAllowedTag(tag)
    tokens.push({
      kind: "tag",
      tag,
      closing,
      selfClosing,
      attrs: closing ? {} : parseAttrs(tag, nameMatch[2] ?? ""),
    })

    index = close + 1
  }

  return tokens
}

function assertAllowedTag(tag: string): void {
  if (
    blockTags.has(tag) ||
    inlineTags.has(tag) ||
    transparentTableTags.has(tag) ||
    tag === "summary" ||
    tag === "li" ||
    tag === "tr" ||
    tag === "td" ||
    tag === "th"
  ) {
    return
  }
  throw new RichTextValidationError(`unsupported rich HTML tag: ${tag}`)
}

function parseAttrs(tag: string, raw: string): Record<string, string | true> {
  const attrs: Record<string, string | true> = {}
  let rest = raw.trim()

  while (rest) {
    const match = rest.match(/^([A-Za-z_:][A-Za-z0-9_:.:-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'))?/)
    if (!match) {
      throw new RichTextValidationError(`invalid rich HTML attribute on ${tag}`)
    }

    const name = (match[1] ?? "").toLowerCase()
    const allowed = allowedAttrs[tag] ?? new Set<string>()
    if (!allowed.has(name)) {
      throw new RichTextValidationError(`unsupported rich HTML attribute: ${tag}.${name}`)
    }

    attrs[name] = match[2] !== undefined ? decodeHtmlEntities(match[2]) : match[3] !== undefined ? decodeHtmlEntities(match[3]) : true
    rest = rest.slice(match[0].length).trim()
  }

  return attrs
}

function nodesToBlocks(nodes: HtmlNode[]): RichBlock[] {
  const blocks: RichBlock[] = []
  let inlineRun: HtmlNode[] = []

  const flushInline = () => {
    const text = normalizeInlineWhitespace(textContent(inlineRun))
    if (text) {
      blocks.push(paragraphBlock(inlineRun))
    }
    inlineRun = []
  }

  for (const node of nodes) {
    if (isBlankText(node)) {
      continue
    }
    if (node.kind !== "element" || !blockTags.has(node.tag)) {
      inlineRun.push(node)
      continue
    }

    flushInline()
    const block = elementToBlock(node)
    if (block) {
      blocks.push(block)
    }
  }

  flushInline()
  return blocks
}

function elementToBlock(node: HtmlNode & { kind: "element" }): RichBlock | undefined {
  switch (node.tag) {
    case "p":
      return paragraphBlock(node.children)
    case "h1":
    case "h2":
    case "h3":
    case "h4":
    case "h5":
    case "h6":
      return headingBlock(node.children, Number(node.tag.slice(1)))
    case "hr":
      return {
        blockId: "",
        direction: RichDirection.DIRECTION_AUTO,
        block: { oneofKind: "divider", divider: {} },
      }
    case "pre":
      return preBlock(node)
    case "blockquote":
      return quoteBlock(node)
    case "details":
      return detailsBlock(node)
    case "ul":
    case "ol":
      return listBlock(node)
    case "table":
      return tableBlock(node)
    case "img":
      return imageBlock(node)
    default:
      throw new RichTextValidationError(`unsupported rich HTML block: ${node.tag}`)
  }
}

function paragraphBlock(nodes: HtmlNode[]): RichBlock {
  return {
    blockId: "",
    direction: inferDirection(textContent(nodes)),
    block: {
      oneofKind: "paragraph",
      paragraph: { text: inlineNodes(nodes, { styles: [] }) },
    },
  }
}

function headingBlock(nodes: HtmlNode[], level: number): RichBlock {
  return {
    blockId: "",
    direction: inferDirection(textContent(nodes)),
    block: {
      oneofKind: "heading",
      heading: {
        text: inlineNodes(nodes, { styles: [] }),
        level,
      },
    },
  }
}

function preBlock(node: HtmlNode & { kind: "element" }): RichBlock {
  const codeChild = node.children.find(
    (child): child is HtmlNode & { kind: "element" } => child.kind === "element" && child.tag === "code",
  )
  const text = textContent(codeChild ? codeChild.children : node.children).replace(/^\n|\n$/g, "")
  return {
    blockId: "",
    direction: RichDirection.DIRECTION_LTR,
    block: {
      oneofKind: "code",
      code: {
        text,
        language: codeChild ? languageFromClass(codeChild.attrs["class"]) : undefined,
      },
    },
  }
}

function quoteBlock(node: HtmlNode & { kind: "element" }): RichBlock {
  const blocks = nodesToBlocks(node.children)
  return {
    blockId: "",
    direction: inferDirection(textContent(node.children)),
    block: {
      oneofKind: "quote",
      quote: {
        blocks,
        expandable: node.attrs["expandable"] === true || node.attrs["expandable"] === "true",
        initiallyCollapsed: node.attrs["expandable"] === true || node.attrs["expandable"] === "true",
      },
    },
  }
}

function detailsBlock(node: HtmlNode & { kind: "element" }): RichBlock {
  let title: RichText[] = [{ text: "Details", children: [], styles: [] }]
  const body: HtmlNode[] = []

  for (const child of node.children) {
    if (child.kind === "element" && child.tag === "summary") {
      title = inlineNodes(child.children, { styles: [] })
      continue
    }
    body.push(child)
  }

  return {
    blockId: "",
    direction: inferDirection(`${textContent(title.map(textNodeFromRichText))}\n${textContent(body)}`),
    block: {
      oneofKind: "details",
      details: {
        title,
        blocks: nodesToBlocks(body),
        initiallyOpen: node.attrs["open"] === true || node.attrs["open"] === "true",
      },
    },
  }
}

function listBlock(node: HtmlNode & { kind: "element" }): RichBlock {
  const items = node.children
    .filter((child): child is HtmlNode & { kind: "element" } => child.kind === "element" && child.tag === "li")
    .map((item) => ({ blocks: nodesToBlocks(item.children) }))

  return {
    blockId: "",
    direction: RichDirection.DIRECTION_AUTO,
    block: {
      oneofKind: "list",
      list: {
        ordered: node.tag === "ol",
        start: node.tag === "ol" ? (positiveInt(node.attrs["start"], 1) ?? 1) : 1,
        items,
      },
    },
  }
}

function tableBlock(node: HtmlNode & { kind: "element" }): RichBlock {
  const rows: RichTableRow[] = []
  for (const rowNode of tableRows(node.children)) {
    const cells = rowNode.children
      .filter((child): child is HtmlNode & { kind: "element" } => child.kind === "element" && (child.tag === "td" || child.tag === "th"))
      .slice(0, richTextLimits.maxTableColumns)
      .map(tableCell)
    if (cells.length > 0) {
      rows.push({ cells })
    }
  }

  return {
    blockId: "",
    direction: RichDirection.DIRECTION_AUTO,
    block: {
      oneofKind: "table",
      table: {
        rows,
        caption: [],
        bordered: boolAttr(node.attrs["bordered"]),
        striped: boolAttr(node.attrs["striped"]),
      },
    },
  }
}

function tableRows(nodes: HtmlNode[]): Array<HtmlNode & { kind: "element" }> {
  const rows: Array<HtmlNode & { kind: "element" }> = []
  for (const node of nodes) {
    if (node.kind !== "element") {
      continue
    }
    if (node.tag === "tr") {
      rows.push(node)
      continue
    }
    if (transparentTableTags.has(node.tag)) {
      rows.push(...tableRows(node.children))
    }
  }
  return rows
}

function tableCell(node: HtmlNode & { kind: "element" }): RichTableCell {
  return {
    text: inlineNodes(node.children, { styles: [] }),
    header: node.tag === "th",
    colspan: positiveInt(node.attrs["colspan"], 1) ?? 1,
    rowspan: positiveInt(node.attrs["rowspan"], 1) ?? 1,
    align: parseHorizontalAlign(node.attrs["align"]),
    valign: parseVerticalAlign(node.attrs["valign"]),
  }
}

function imageBlock(node: HtmlNode & { kind: "element" }): RichBlock {
  const url = publicMediaUrl(attrString(node.attrs["src"]))
  if (!url) {
    throw new RichTextValidationError("rich HTML image requires a safe HTTPS src")
  }

  const alt = attrString(node.attrs["alt"])?.trim() ?? ""
  const media: RichMediaRef = {
    alt,
    width: positiveInt(node.attrs["width"]),
    height: positiveInt(node.attrs["height"]),
    media: { oneofKind: "publicUrl", publicUrl: url },
  }

  return {
    blockId: "",
    direction: RichDirection.DIRECTION_AUTO,
    block: {
      oneofKind: "photo",
      photo: {
        media,
        caption: alt ? [{ text: alt, children: [], styles: [] }] : [],
      },
    },
  }
}

function inlineNodes(nodes: HtmlNode[], ctx: InlineCtx): RichText[] {
  const output: RichText[] = []

  for (const node of nodes) {
    if (node.kind === "text") {
      const text = normalizeInlineWhitespace(node.text)
      if (text) {
        output.push({ text, children: [], styles: ctx.styles, url: ctx.url })
      }
      continue
    }

    if (node.kind !== "element") {
      continue
    }

    if (!inlineTags.has(node.tag)) {
      throw new RichTextValidationError(`unsupported rich HTML inline child: ${node.tag}`)
    }

    if (node.tag === "br") {
      output.push({ text: "\n", children: [], styles: ctx.styles, url: ctx.url })
      continue
    }

    const next = nextInlineCtx(node, ctx)
    output.push(...inlineNodes(node.children, next))
  }

  return compactRichText(output)
}

function nextInlineCtx(node: HtmlNode & { kind: "element" }, ctx: InlineCtx): InlineCtx {
  switch (node.tag) {
    case "b":
    case "strong":
      return { ...ctx, styles: addStyle(ctx.styles, RichTextStyle.STYLE_BOLD) }
    case "i":
    case "em":
      return { ...ctx, styles: addStyle(ctx.styles, RichTextStyle.STYLE_ITALIC) }
    case "u":
      return { ...ctx, styles: addStyle(ctx.styles, RichTextStyle.STYLE_UNDERLINE) }
    case "s":
    case "strike":
    case "del":
      return { ...ctx, styles: addStyle(ctx.styles, RichTextStyle.STYLE_STRIKETHROUGH) }
    case "code":
      return { ...ctx, styles: addStyle(ctx.styles, RichTextStyle.STYLE_CODE) }
    case "tg-spoiler":
      return { ...ctx, styles: addStyle(ctx.styles, RichTextStyle.STYLE_SPOILER) }
    case "span":
      if (classList(node.attrs["class"]).includes("tg-spoiler")) {
        return { ...ctx, styles: addStyle(ctx.styles, RichTextStyle.STYLE_SPOILER) }
      }
      throw new RichTextValidationError("unsupported rich HTML span class")
    case "a": {
      const url = linkUrl(attrString(node.attrs["href"]))
      if (!url) {
        throw new RichTextValidationError("rich HTML link requires a supported href")
      }
      return { ...ctx, url }
    }
    default:
      return ctx
  }
}

function compactRichText(nodes: RichText[]): RichText[] {
  const output: RichText[] = []
  for (const node of nodes) {
    const prev = output.at(-1)
    if (
      prev &&
      prev.url === node.url &&
      sameStyles(prev.styles, node.styles) &&
      prev.children.length === 0 &&
      node.children.length === 0
    ) {
      prev.text += node.text
      continue
    }
    output.push({ ...node, styles: [...node.styles] })
  }
  return output
}

function textContent(nodes: HtmlNode[]): string {
  return nodes
    .map((node) => {
      if (node.kind === "text") return node.text
      if (node.kind === "element" && node.tag === "br") return "\n"
      if (node.kind === "element") return textContent(node.children)
      return ""
    })
    .join("")
}

function textNodeFromRichText(node: RichText): HtmlNode {
  return { kind: "text", text: node.text + textContent(node.children.map(textNodeFromRichText)) }
}

function isBlankText(node: HtmlNode): boolean {
  return node.kind === "text" && !node.text.trim()
}

function normalizeInlineWhitespace(text: string): string {
  return text.replace(/\s+/g, " ")
}

function addStyle(styles: RichTextStyle[], style: RichTextStyle): RichTextStyle[] {
  return styles.includes(style) ? styles : [...styles, style]
}

function sameStyles(a: RichTextStyle[], b: RichTextStyle[]): boolean {
  return a.length === b.length && a.every((style, index) => style === b[index])
}

function classList(value: string | true | undefined): string[] {
  return typeof value === "string" ? value.split(/\s+/).filter(Boolean) : []
}

function boolAttr(value: string | true | undefined): boolean {
  return value === true || value === "true" || value === "1"
}

function attrString(value: string | true | undefined): string | undefined {
  return typeof value === "string" ? value : undefined
}

function positiveInt(value: string | true | undefined, fallback?: number): number | undefined {
  if (typeof value !== "string") {
    return fallback
  }
  const parsed = Number(value)
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return fallback
  }
  return Math.trunc(parsed)
}

function parseHorizontalAlign(value: string | true | undefined): RichHorizontalAlign | undefined {
  switch (typeof value === "string" ? value.toLowerCase() : "") {
    case "left":
      return RichHorizontalAlign.HORIZONTAL_ALIGN_LEFT
    case "center":
      return RichHorizontalAlign.HORIZONTAL_ALIGN_CENTER
    case "right":
      return RichHorizontalAlign.HORIZONTAL_ALIGN_RIGHT
    default:
      return RichHorizontalAlign.HORIZONTAL_ALIGN_UNSPECIFIED
  }
}

function parseVerticalAlign(value: string | true | undefined): RichVerticalAlign | undefined {
  switch (typeof value === "string" ? value.toLowerCase() : "") {
    case "top":
      return RichVerticalAlign.VERTICAL_ALIGN_TOP
    case "middle":
    case "center":
      return RichVerticalAlign.VERTICAL_ALIGN_MIDDLE
    case "bottom":
      return RichVerticalAlign.VERTICAL_ALIGN_BOTTOM
    default:
      return RichVerticalAlign.VERTICAL_ALIGN_UNSPECIFIED
  }
}

function languageFromClass(value: string | true | undefined): string | undefined {
  const language = classList(value)
    .find((item) => item.startsWith("language-"))
    ?.slice("language-".length)
    .replace(/[^\w.+-]/g, "")
    .slice(0, richTextLimits.maxLanguageLength)
  return language || undefined
}

function linkUrl(raw: string | undefined): string | undefined {
  if (!raw || raw.length > richTextLimits.maxUrlLength) {
    return undefined
  }
  try {
    const url = new URL(raw)
    const protocol = url.protocol.toLowerCase()
    if (protocol === "http:" || protocol === "https:" || protocol === "mailto:" || protocol === "tel:" || protocol === "inline:") {
      return raw
    }
  } catch {
    return undefined
  }
  return undefined
}

function publicMediaUrl(raw: string | undefined): string | undefined {
  if (!raw || raw.length > richTextLimits.maxUrlLength) {
    return undefined
  }
  try {
    const url = new URL(raw)
    if (url.protocol !== "https:" || url.username || url.password) {
      return undefined
    }
    return url.toString()
  } catch {
    return undefined
  }
}

function decodeHtmlEntities(value: string): string {
  return value.replace(/&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos|nbsp);/g, (_, entity: string) => {
    switch (entity) {
      case "amp":
        return "&"
      case "lt":
        return "<"
      case "gt":
        return ">"
      case "quot":
        return "\""
      case "apos":
        return "'"
      case "nbsp":
        return " "
      default: {
        const code = entity.startsWith("#x") ? Number.parseInt(entity.slice(2), 16) : Number.parseInt(entity.slice(1), 10)
        return Number.isFinite(code) ? String.fromCodePoint(code) : ""
      }
    }
  })
}

function inferDirection(text: string): RichDirection {
  if (/[\u0590-\u05ff\u0600-\u06ff\u0750-\u077f\u08a0-\u08ff\ufb50-\ufdff\ufe70-\ufeff]/.test(text)) {
    return RichDirection.DIRECTION_RTL
  }
  return RichDirection.DIRECTION_AUTO
}
