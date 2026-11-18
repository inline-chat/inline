/**
 * Plain-text projections of a message: a one-line preview for the sidebar and
 * notifications, and the text a copy puts on the clipboard.
 *
 * Mentions, thread references and link labels are already the visible text
 * (`@Mo`, the label of a text link), so a preview reads as the message does.
 */

import { ellipsis, graphemeStartAtOrBefore, truncateGraphemes } from "./graphemes"
import type { BlockNode, InlineNode, ParagraphNode, TextDocument } from "./types"

export const defaultPreviewLength = 160

export type PreviewOptions = {
  /** Maximum grapheme clusters, ellipsis included. Default 160. */
  readonly maxGraphemes?: number
  /** Shown when the text is empty or only whitespace, for example "Photo". Default "". */
  readonly fallback?: string
}

/**
 * Control characters, and the bidirectional embedding, override and isolate
 * controls, which could reorder the rest of a preview line. Line breaks and
 * tabs are handled as whitespace first. Joiners and LRM/RLM stay.
 */
// oxlint-disable-next-line no-control-regex -- removing control characters is the point
const previewNoise = /[\u0000-\u0008\u000e-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069\ufeff]/gu
const whitespaceRun = /\s+/gu

/**
 * One line of text for a preview: whitespace (line breaks included) collapsed
 * to single spaces, control and bidi override characters removed, cut on a
 * grapheme boundary with an ellipsis.
 */
export const previewText = (text: unknown, options: PreviewOptions = {}): string => {
  const max = options.maxGraphemes ?? defaultPreviewLength
  const source = typeof text === "string" ? text : ""
  // Bound the work for very long messages before normalizing.
  const bound = max * 8 + 64
  const head = source.length > bound ? source.slice(0, graphemeStartAtOrBefore(source, bound)) : source
  const line = head.replace(previewNoise, "").replace(whitespaceRun, " ").trim()
  if (line.length === 0) return options.fallback ?? ""
  const cut = truncateGraphemes(line, max)
  return cut === line && head.length < source.length ? truncateGraphemes(`${line}${ellipsis}`, max) : cut
}

/** The preview of a built document. Same rules as `previewText`. */
export const documentPreview = (document: TextDocument, options: PreviewOptions = {}): string =>
  previewText(documentText(document), options)

export type CopyOptions = {
  /**
   * Append ` (url)` after a link whose label is not its URL, so a paste keeps
   * where it pointed. Default false: the Mac copies the visible text.
   */
  readonly linkTargets?: boolean
}

const inlineText = (node: InlineNode, options: CopyOptions): string => {
  switch (node.kind) {
    case "text":
      return node.text
    case "math":
      return node.source
    case "link": {
      const label = node.children.map((child) => child.text).join("")
      if (!options.linkTargets) return label
      const target = node.link.kind === "mail" ? node.link.address : node.link.kind === "phone" ? node.link.number : node.link.href
      return sameTarget(label, node.link.href, target) ? label : `${label} (${target})`
    }
    case "mention":
    case "threadRef":
    case "botCommand":
      return node.children.map((child) => child.text).join("")
  }
}

const sameTarget = (label: string, href: string, target: string): boolean => {
  const trimmed = label.trim()
  if (trimmed === target || trimmed === href) return true
  // `example.com` labels a link that normalizes to `https://example.com/`.
  const bare = href.replace(/^https?:\/\//, "").replace(/\/$/, "")
  return trimmed.replace(/\/$/, "") === bare
}

const paragraphText = (paragraph: ParagraphNode, options: CopyOptions): string =>
  paragraph.children.map((child) => inlineText(child, options)).join("")

const blockText = (block: BlockNode, options: CopyOptions): string => {
  switch (block.kind) {
    case "paragraph":
      return paragraphText(block, options)
    case "codeBlock":
      return block.text
    case "mathBlock":
      return block.source
    case "quote":
      return joinBlocks(block.children, options)
    default:
      return ""
  }
}

const joinBlocks = (blocks: readonly BlockNode[], options: CopyOptions): string => {
  let out = ""
  blocks.forEach((block, index) => {
    if (index > 0) out += "\n".repeat(1 + block.blankLinesBefore)
    out += blockText(block, options)
  })
  return out
}

/**
 * The document's visible text, blocks separated by their line breaks. For a
 * message without blank-only lines, this is the message text.
 */
export const documentText = (document: TextDocument, options: CopyOptions = {}): string =>
  joinBlocks(document.blocks, options)

/** The text a "Copy text" action puts on the clipboard. */
export const copyText = (document: TextDocument, options: CopyOptions = {}): string => documentText(document, options)
