import {
  BlockDisclosure_ActivityKind,
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
import { cleanPreLanguage, preFence } from "../translation2/entities/code"
import { toMd } from "../translation2/entities/toMarkdown"
import { mathMarkdown } from "../translation2/entities/math"
import { escapeLinkUrl, escapeMarkdownLineStarts } from "../translation2/entities/escape"
import { toRange } from "../translation2/entities/offsets"
import { validateBlockContent } from "./blockContent"

const disclosureActivityNames: Partial<Record<BlockDisclosure_ActivityKind, string>> = {
  [BlockDisclosure_ActivityKind.REASONING]: "reasoning",
  [BlockDisclosure_ActivityKind.EXPLORE]: "explore",
  [BlockDisclosure_ActivityKind.READ]: "read",
  [BlockDisclosure_ActivityKind.SEARCH]: "search",
  [BlockDisclosure_ActivityKind.EDIT]: "edit",
  [BlockDisclosure_ActivityKind.DELETE]: "delete",
  [BlockDisclosure_ActivityKind.MOVE]: "move",
  [BlockDisclosure_ActivityKind.COMMAND]: "command",
  [BlockDisclosure_ActivityKind.WEB]: "web",
  [BlockDisclosure_ActivityKind.TOOL]: "tool",
}

export type BlockContentMarkdownEncoderOptions = {
  imageURL?: (path: number[], image: BlockImage) => string | undefined
}

export function encodeBlockContentToMarkdown(input: {
  text: string
  entities?: MessageEntities
  blockContent: BlockContent
  options?: BlockContentMarkdownEncoderOptions
}): string {
  validateBlockContent(input.text, input.blockContent, "persisted")
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
    case "math": {
      const source = sliceText(block.kind.math, input.text)
      return mathMarkdown(source, true) ?? escapePlainMarkdown(source)
    }
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
      const activityName = disclosureActivityNames[block.kind.disclosure.activityKind]
      const activity = activityName ? ` activity="${activityName}"` : ""
      const summary = encodeText(block.kind.disclosure.summary!, input)
      const children = encodeBlocks(block.kind.disclosure.children, path, input).join("\n\n")
      return `<details${open}>\n<summary${progress}${activity}>${summary}</summary>${children ? `\n${children}` : ""}\n</details>`
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
  let orderedNumber = list.start ?? 1n
  return list.items
    .map((item, itemIndex) => {
      const children = encodeBlocks(item.children, [...path, itemIndex], input).join("\n\n")
      const lines = children.split("\n")
      // Only the first marker controls the parsed list's start; later markers
      // must still fit CommonMark's nine-digit grammar.
      const ordinal = orderedNumber++
      const baseMarker = list.kind === BlockList_Kind.ORDERED ? `${ordinal <= 999_999_999n ? ordinal : 1n}. ` : "- "
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
  return `![${alt}](${escapeLinkUrl(url)})${hint}`
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
  const entities = (input.entities?.entities ?? []).flatMap((entity) => {
    const source = toRange(input.text, entity)
    if (!source) return []
    if (source.start >= start && source.end <= end) return [entity]
    // Native formatting may cross paragraph/cell boundaries. Project only
    // range-only styles into each text slice; partial links, mentions, code
    // and TeX would change meaning if independently split here.
    if (!rangeOnlyStyles.has(entity.type)) return []
    const clippedStart = Math.max(start, source.start), clippedEnd = Math.min(end, source.end)
    return clippedStart < clippedEnd ? [{ ...entity, offset: BigInt(clippedStart), length: BigInt(clippedEnd - clippedStart) }] : []
  })
  return encodeInline(input.text.slice(start, end), entities, start)
}

const rangeOnlyStyles = new Set([
  MessageEntity_Type.BOLD, MessageEntity_Type.ITALIC, MessageEntity_Type.UNDERLINE,
  MessageEntity_Type.STRIKETHROUGH, MessageEntity_Type.HIGHLIGHT,
])

function encodeInline(text: string, entities: MessageEntity[], globalStart: number): string {
  return toMd(text, {
    entities: entities.map((entity) => ({ ...entity, offset: entity.offset - BigInt(globalStart) })),
  }, escapePlainMarkdown)
}

function sliceText(range: BlockText, text: string): string {
  return text.slice(Number(range.offset), Number(range.offset + range.length))
}

function escapePlainMarkdown(value: string, atLineStart = true): string {
  let output = ""
  for (const character of value) {
    output += markdownEscapablePunctuation.has(character) ? `\\${character}` : character
  }
  return escapeMarkdownLineStarts(output, atLineStart)
}

const markdownEscapablePunctuation = new Set(
  Array.from("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"),
)
