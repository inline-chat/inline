import {
  BlockDisclosure_Kind,
  BlockList_Kind,
  BlockTable_Alignment,
  MessageEntity_Type,
  type Block,
  type BlockContent,
  type BlockImage,
  type BlockText,
  type MessageEntities,
  type MessageEntity,
} from "@inline-chat/protocol/core"
import { cleanPreLanguage, codeDelimiter, preFence } from "../translation2/entities/code"
import { validateBlockContent } from "./blockContent"

export type BlockContentMarkdownEncoderOptions = {
  imageURL?: (path: number[], image: BlockImage) => string | undefined
}

export function encodeBlockContentToMarkdown(input: {
  text: string
  entities?: MessageEntities
  blockContent: BlockContent
  options?: BlockContentMarkdownEncoderOptions
}): string {
  validateBlockContent(input.text, input.blockContent)
  return encodeBlocks(input.blockContent.blocks, [], input).join("\n\n")
}

type EncoderInput = {
  text: string
  entities?: MessageEntities
  blockContent: BlockContent
  options?: BlockContentMarkdownEncoderOptions
}

function encodeBlocks(blocks: Block[], path: number[], input: EncoderInput): string[] {
  return blocks.map((block, index) => encodeBlock(block, [...path, index], input))
}

function encodeBlock(block: Block, path: number[], input: EncoderInput): string {
  switch (block.kind.oneofKind) {
    case "paragraph":
      return encodeText(block.kind.paragraph, input)
    case "heading":
      return `${"#".repeat(block.kind.heading.level)} ${encodeText(block.kind.heading.text!, input)}`
    case "code": {
      const code = sliceText(block.kind.code.text!, input.text)
      const fence = preFence(code)
      const language = cleanPreLanguage(block.kind.code.language)
      return `${fence}${language}\n${code}\n${fence}`
    }
    case "list":
      return encodeList(block.kind.list, path, input)
    case "separator":
      return "---"
    case "image":
      return encodeImage(block.kind.image, path, input)
    case "album":
      return block.kind.album.images
        .map((image, imageIndex) => encodeImage(image, [...path, imageIndex], input))
        .join("\n")
    case "disclosure": {
      const open = block.kind.disclosure.initiallyOpen ? " open" : ""
      const progress = block.kind.disclosure.kind === BlockDisclosure_Kind.PROGRESS ? ' kind="progress"' : ""
      const summary = encodeText(block.kind.disclosure.summary!, input)
      const children = encodeBlocks(block.kind.disclosure.children, path, input).join("\n\n")
      return `<details${open}>\n<summary${progress}>${summary}</summary>${children ? `\n${children}` : ""}\n</details>`
    }
    case "footer":
      return `<footer>${encodeText(block.kind.footer, input)}</footer>`
    case "quote": {
      const children = encodeBlocks(block.kind.quote.children, path, input).join("\n\n")
      return children.split("\n").map((line) => line.length > 0 ? `> ${line}` : ">").join("\n")
    }
    case "table":
      return encodeTable(block.kind.table, input)
    default:
      return ""
  }
}

function encodeTable(
  table: Extract<Block["kind"], { oneofKind: "table" }>["table"],
  input: EncoderInput,
): string {
  const rows = table.rows.map((row) => `| ${row.cells.map((cell) => encodeText(cell, input)).join(" | ")} |`)
  const alignment = table.alignments.map((value) => {
    switch (value) {
      case BlockTable_Alignment.LEFT:
        return ":---"
      case BlockTable_Alignment.CENTER:
        return ":---:"
      case BlockTable_Alignment.RIGHT:
        return "---:"
      default:
        return "---"
    }
  })
  return [rows[0]!, `| ${alignment.join(" | ")} |`, ...rows.slice(1)].join("\n")
}

function encodeList(
  list: Extract<Block["kind"], { oneofKind: "list" }>["list"],
  path: number[],
  input: EncoderInput,
): string {
  let orderedNumber = Number(list.start ?? 1n)
  return list.items
    .map((item, itemIndex) => {
      const children = encodeBlocks(item.children, [...path, itemIndex], input).join("\n\n")
      const lines = children.split("\n")
      const baseMarker = list.kind === BlockList_Kind.ORDERED ? `${orderedNumber++}. ` : "- "
      const marker = item.checked === undefined
        ? baseMarker
        : `${baseMarker}${item.checked ? "[x] " : "[ ] "}`
      const continuation = " ".repeat(marker.length)
      return lines.map((line, lineIndex) => `${lineIndex === 0 ? marker : continuation}${line}`).join("\n")
    })
    .join("\n")
}

function encodeImage(image: BlockImage, path: number[], input: EncoderInput): string {
  const alt = escapePlainMarkdown(sliceText(image.alt!, input.text))
  const url = input.options?.imageURL?.(path, image) ?? fallbackImageURL(image)
  const dimensions = imageDimensions(image)
  const hint = dimensions ? `{width=${dimensions.width} height=${dimensions.height}}` : ""
  return `![${alt}](${escapeURL(url)})${hint}`
}

function fallbackImageURL(image: BlockImage): string {
  if (image.state.oneofKind === "ready") {
    return `inline-photo:${image.state.ready.id}`
  }
  return "inline-image:unavailable"
}

function imageDimensions(image: BlockImage): { width: number; height: number } | undefined {
  if (image.state.oneofKind === "pending") return image.state.pending.dimensions
  if (image.state.oneofKind === "unavailable") return image.state.unavailable.dimensions
  if (image.state.oneofKind === "ready") {
    const size = image.state.ready.sizes.find((candidate) => candidate.type !== "s" && candidate.w > 0 && candidate.h > 0)
    return size ? { width: size.w, height: size.h } : undefined
  }
  return undefined
}

function encodeText(range: BlockText, input: EncoderInput): string {
  const start = Number(range.offset)
  const end = Number(range.offset + range.length)
  const entities = (input.entities?.entities ?? []).filter((entity) => {
    const entityStart = Number(entity.offset)
    const entityEnd = Number(entity.offset + entity.length)
    return entityStart >= start && entityEnd <= end && entity.length > 0n
  })
  return encodeInline(input.text.slice(start, end), entities, start)
}

function encodeInline(text: string, entities: MessageEntity[], globalStart: number): string {
  const opens = new Map<number, MessageEntity[]>()
  const closes = new Map<number, MessageEntity[]>()
  for (const entity of entities) {
    if (!inlineMarkers(entity, text, globalStart)) continue
    const start = Number(entity.offset) - globalStart
    const end = start + Number(entity.length)
    opens.set(start, [...(opens.get(start) ?? []), entity])
    closes.set(end, [...(closes.get(end) ?? []), entity])
  }

  for (const values of opens.values()) {
    values.sort((left, right) => Number(right.length - left.length))
  }
  for (const values of closes.values()) {
    values.sort((left, right) => Number(right.offset - left.offset))
  }

  let output = ""
  let codeDepth = 0
  for (let boundary = 0; boundary <= text.length; boundary++) {
    for (const entity of closes.get(boundary) ?? []) {
      const markers = inlineMarkers(entity, text, globalStart)
      if (!markers) continue
      output += markers.close
      if (entity.type === MessageEntity_Type.CODE) codeDepth = Math.max(0, codeDepth - 1)
    }
    for (const entity of opens.get(boundary) ?? []) {
      const markers = inlineMarkers(entity, text, globalStart)
      if (!markers) continue
      output += markers.open
      if (entity.type === MessageEntity_Type.CODE) codeDepth += 1
    }
    if (boundary < text.length) {
      const character = text[boundary]!
      output += codeDepth > 0 ? character : escapePlainMarkdown(character)
    }
  }
  return output
}

function inlineMarkers(
  entity: MessageEntity,
  text?: string,
  globalStart = 0,
): { open: string; close: string } | undefined {
  switch (entity.type) {
    case MessageEntity_Type.BOLD:
      return { open: "**", close: "**" }
    case MessageEntity_Type.ITALIC:
      return { open: "*", close: "*" }
    case MessageEntity_Type.CODE:
      if (text === undefined) return { open: "`", close: "`" }
      const start = Number(entity.offset) - globalStart
      const end = start + Number(entity.length)
      const delimiter = codeDelimiter(text.slice(start, end))
      return { open: delimiter, close: delimiter }
    case MessageEntity_Type.TEXT_URL:
      return entity.entity.oneofKind === "textUrl"
        ? { open: "[", close: `](${escapeURL(entity.entity.textUrl.url)})` }
        : undefined
    default:
      return undefined
  }
}

function sliceText(range: BlockText, text: string): string {
  return text.slice(Number(range.offset), Number(range.offset + range.length))
}

function escapePlainMarkdown(value: string): string {
  let output = ""
  for (const character of value) {
    output += markdownEscapablePunctuation.has(character) ? `\\${character}` : character
  }
  return output
}

const markdownEscapablePunctuation = new Set(
  Array.from("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"),
)

function escapeURL(value: string): string {
  return value.replace(/\\/g, "%5C").replace(/\)/g, "%29").replace(/\(/g, "%28")
}
