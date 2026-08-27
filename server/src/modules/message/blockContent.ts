import {
  BlockDisclosure_Kind,
  BlockList_Kind,
  BlockTable_Alignment,
  type Block,
  type BlockContent,
  type BlockImage,
  type BlockText,
  type Photo,
} from "@inline-chat/protocol/core"
import type { Paragraph, RootContent, Table, TableCell } from "mdast"
import { fromMarkdown } from "mdast-util-from-markdown"
import { gfmFromMarkdown } from "mdast-util-gfm"
import { gfm } from "micromark-extension-gfm"
import { cleanPreLanguage } from "../translation2/entities/code"
import { annotateBlockContentDirections } from "./blockDirection"
import { parseMarkdownWithSourceMap, type ParsedMarkdownWithSourceMap } from "./parseMarkdown"

export const blockContentLimits = {
  maxBlocks: 1_024,
  maxDepth: 16,
  maxListDepth: 12,
  maxImages: 64,
  maxAlbumImages: 10,
  maxTableRows: 256,
  maxTableColumns: 64,
  // Every cell becomes a native text surface on macOS. Keep rich rendering
  // bounded; oversized GFM tables retain the ordinary flat-text projection.
  maxTableCells: 256,
  // Stored snapshots written before the native-surface ceiling was reduced
  // remain mutable so pending image jobs can finish instead of retrying forever.
  maxPersistedTableCells: 4_096,
  maxImageDimension: 16_384,
  maxImageRatio: 100,
  maxStrippedThumbnailBytes: 8 * 1_024,
} as const

export type BlockImageSource = {
  path: number[]
  url: string
}

export type ParsedBlockContent = {
  blockContent: BlockContent
  imageSources: BlockImageSource[]
}

type PositionedImageSource = {
  image: BlockImage
  url: string
}

type Line = {
  start: number
  contentEnd: number
  next: number
  value: string
}

type Fence = {
  character: "`" | "~"
  length: number
}

export function parseBlockContent(
  markdown: string,
  parsedMarkdown?: ParsedMarkdownWithSourceMap,
): ParsedBlockContent | undefined {
  if (markdown.length === 0) {
    return undefined
  }

  try {
    const legacy = parsedMarkdown ?? parseMarkdownWithSourceMap(markdown)
    const positionedSources: PositionedImageSource[] = []
    const blocks = coalesceImages(parseRegion(markdown, legacy, 0, markdown.length, positionedSources))
    if (blocks.length === 0) {
      return undefined
    }

    const blockContent: BlockContent = { blocks }
    annotateBlockContentDirections(legacy.text, blockContent)
    validateBlockContent(legacy.text, blockContent)

    const sourceByImage = new Map(positionedSources.map((source) => [source.image, source.url]))
    const imageSources: BlockImageSource[] = []
    visitImages(blocks, [], (image, path) => {
      const url = sourceByImage.get(image)
      if (url) {
        imageSources.push({ path, url })
      }
    })

    return { blockContent, imageSources }
  } catch {
    return undefined
  }
}

function parseRegion(
  markdown: string,
  legacy: ParsedMarkdownWithSourceMap,
  start: number,
  end: number,
  sources: PositionedImageSource[],
): Block[] {
  const blocks: Block[] = []
  let ordinaryStart = start
  let cursor = start
  let fence: Fence | undefined

  const flushOrdinary = (ordinaryEnd: number): void => {
    if (ordinaryEnd > ordinaryStart) {
      blocks.push(...parseOrdinaryRegion(markdown, legacy, ordinaryStart, ordinaryEnd, sources))
    }
  }

  while (cursor < end) {
    const line = readLine(markdown, cursor, end)
    if (fence) {
      if (isClosingFence(line.value, fence)) fence = undefined
      cursor = line.next
      continue
    }

    const openingFence = parseOpeningFence(line.value)
    if (openingFence) {
      fence = openingFence
      cursor = line.next
      continue
    }

    const details = /^<details( open)?>$/.exec(line.value)
    if (details) {
      const summaryLine = line.next < end ? readLine(markdown, line.next, end) : undefined
      const summary = summaryLine
        ? /^<summary(?: kind="(progress)")?>(.*)<\/summary>$/.exec(summaryLine.value)
        : undefined

      if (summaryLine && summary) {
        flushOrdinary(line.start)
        const close = findDetailsClose(markdown, summaryLine.next, end)
        const childrenEnd = close?.start ?? end
        const summaryPrefixLength = summaryLine.value.indexOf(">") + 1
        const summaryStart = summaryLine.start + summaryPrefixLength
        const summaryEnd = summaryStart + (summary[2]?.length ?? 0)
        blocks.push({
          kind: {
            oneofKind: "disclosure",
            disclosure: {
              summary: mapText(legacy, summaryStart, summaryEnd),
              kind:
                summary[1] === "progress" ? BlockDisclosure_Kind.PROGRESS : BlockDisclosure_Kind.DEFAULT,
              initiallyOpen: details[1] !== undefined,
              children: coalesceImages(
                parseRegion(markdown, legacy, summaryLine.next, childrenEnd, sources),
              ),
            },
          },
        })
        cursor = close?.next ?? end
        ordinaryStart = cursor
        continue
      }
    }

    const footer = /^<footer>(.*)<\/footer>$/.exec(line.value)
    if (footer) {
      flushOrdinary(line.start)
      const footerStart = line.start + "<footer>".length
      blocks.push({
        kind: {
          oneofKind: "footer",
          footer: mapText(legacy, footerStart, footerStart + (footer[1]?.length ?? 0)),
        },
      })
      cursor = line.next
      ordinaryStart = cursor
      continue
    }

    cursor = line.next
  }

  flushOrdinary(end)
  return blocks
}

function parseOrdinaryRegion(
  markdown: string,
  legacy: ParsedMarkdownWithSourceMap,
  start: number,
  end: number,
  sources: PositionedImageSource[],
): Block[] {
  const source = markdown.slice(start, end)
  if (source.trim().length === 0) {
    return []
  }

  const root = fromMarkdown(source, {
    extensions: [gfm()],
    mdastExtensions: [gfmFromMarkdown()],
  })

  return root.children.flatMap((node) => convertNode(markdown, legacy, node, start, sources))
}

function convertNode(
  markdown: string,
  legacy: ParsedMarkdownWithSourceMap,
  node: RootContent,
  baseOffset: number,
  sources: PositionedImageSource[],
): Block[] {
  const range = nodeRange(node, baseOffset)
  if (!range) {
    return []
  }

  switch (node.type) {
    case "paragraph":
      return convertParagraph(markdown, legacy, node, baseOffset, sources)
    case "heading": {
      const childRanges = node.children.map((child) => nodeRange(child, baseOffset)).filter(isRange)
      const textRange = childRanges.length > 0
        ? { start: childRanges[0]!.start, end: childRanges[childRanges.length - 1]!.end }
        : { start: range.end, end: range.end }
      return [{
        kind: {
          oneofKind: "heading",
          heading: { text: mapText(legacy, textRange.start, textRange.end), level: node.depth },
        },
      }]
    }
    case "code": {
      const contentRange = findFencedCodeContentRange(markdown, range.start, range.end)
      if (!contentRange) {
        return [paragraphBlock(mapText(legacy, range.start, range.end))]
      }
      return [{
        kind: {
          oneofKind: "code",
          code: {
            text: mapText(legacy, contentRange.start, contentRange.end),
            language: cleanPreLanguage(node.lang ?? undefined) || undefined,
          },
        },
      }]
    }
    case "list":
      return [{
        kind: {
          oneofKind: "list",
          list: {
            kind: node.ordered ? BlockList_Kind.ORDERED : BlockList_Kind.UNORDERED,
            start: node.ordered ? BigInt(node.start ?? 1) : undefined,
            items: node.children.map((item) => ({
              children: coalesceImages(
                item.children.flatMap((child) => convertNode(markdown, legacy, child, baseOffset, sources)),
              ),
              checked: item.checked ?? undefined,
            })),
          },
        },
      }]
    case "blockquote": {
      const children = coalesceImages(
        node.children.flatMap((child) => convertNode(markdown, legacy, child, baseOffset, sources)),
      )
      return children.length > 0
        ? [{ kind: { oneofKind: "quote", quote: { children } } }]
        : [paragraphBlock(mapText(legacy, range.start, range.end))]
    }
    case "table":
      return [convertTable(legacy, node, baseOffset)]
    case "thematicBreak":
      return [{ kind: { oneofKind: "separator", separator: {} } }]
    default:
      // Arbitrary HTML remains visibly recoverable as literal text.
      return [paragraphBlock(mapText(legacy, range.start, range.end))]
  }
}

function convertTable(
  legacy: ParsedMarkdownWithSourceMap,
  node: Table,
  baseOffset: number,
): Block {
  return {
    kind: {
      oneofKind: "table",
      table: {
        rows: node.children.map((row) => ({
          cells: row.children.map((cell) => mapTableCell(legacy, cell, baseOffset)),
        })),
        alignments: (node.align ?? node.children[0]?.children.map(() => null) ?? []).map((alignment) => {
          switch (alignment) {
            case "left":
              return BlockTable_Alignment.LEFT
            case "center":
              return BlockTable_Alignment.CENTER
            case "right":
              return BlockTable_Alignment.RIGHT
            default:
              return BlockTable_Alignment.UNSPECIFIED
          }
        }),
      },
    },
  }
}

function mapTableCell(
  legacy: ParsedMarkdownWithSourceMap,
  cell: TableCell,
  baseOffset: number,
): BlockText {
  const childRanges = cell.children.map((child) => nodeRange(child, baseOffset)).filter(isRange)
  if (childRanges.length > 0) {
    return mapText(legacy, childRanges[0]!.start, childRanges[childRanges.length - 1]!.end)
  }
  const range = nodeRange(cell, baseOffset)
  const emptyOffset = range?.start ?? baseOffset
  return mapText(legacy, emptyOffset, emptyOffset)
}

function convertParagraph(
  markdown: string,
  legacy: ParsedMarkdownWithSourceMap,
  node: Paragraph,
  baseOffset: number,
  sources: PositionedImageSource[],
): Block[] {
  const paragraphRange = nodeRange(node, baseOffset)
  if (!paragraphRange) {
    return []
  }

  const images = node.children.filter((child) => child.type === "image")
  if (images.length === 0) {
    return [paragraphBlock(mapText(legacy, paragraphRange.start, paragraphRange.end))]
  }

  const blocks: Block[] = []
  let cursor = paragraphRange.start
  for (const imageNode of images) {
    const imageRange = nodeRange(imageNode, baseOffset)
    if (!imageRange) {
      continue
    }

    pushParagraphIfVisible(blocks, markdown, legacy, cursor, imageRange.start)
    const parsedToken = parseImageToken(markdown, imageRange.start, imageRange.end)
    if (!parsedToken) {
      pushParagraphIfVisible(blocks, markdown, legacy, imageRange.start, imageRange.end)
      cursor = imageRange.end
      continue
    }

    const hint = parseDimensionHint(markdown, imageRange.end, paragraphRange.end)
    const normalizedURL = normalizeImageURL(imageNode.url)
    const image: BlockImage = {
      alt: mapText(legacy, parsedToken.altStart, parsedToken.altEnd),
      state: normalizedURL
        ? {
            oneofKind: "pending",
            pending: {
              dimensions: hint?.dimensions,
              strippedThumbnail: undefined,
            },
          }
        : {
            oneofKind: "unavailable",
            unavailable: { dimensions: hint?.dimensions },
          },
    }
    blocks.push({ kind: { oneofKind: "image", image } })
    if (normalizedURL) {
      sources.push({ image, url: normalizedURL })
    }
    cursor = hint?.end ?? imageRange.end
  }

  pushParagraphIfVisible(blocks, markdown, legacy, cursor, paragraphRange.end)
  return blocks
}

function pushParagraphIfVisible(
  blocks: Block[],
  markdown: string,
  legacy: ParsedMarkdownWithSourceMap,
  start: number,
  end: number,
): void {
  if (end <= start || markdown.slice(start, end).trim().length === 0) {
    return
  }
  blocks.push(paragraphBlock(mapText(legacy, start, end)))
}

function paragraphBlock(text: BlockText): Block {
  return { kind: { oneofKind: "paragraph", paragraph: text } }
}

function mapText(legacy: ParsedMarkdownWithSourceMap, sourceStart: number, sourceEnd: number): BlockText {
  const start = legacy.sourceToOutput[sourceStart]
  const end = legacy.sourceToOutput[sourceEnd]
  if (start === undefined || end === undefined || end < start) {
    throw new Error("Invalid structural source range")
  }
  return { offset: BigInt(start), length: BigInt(end - start) }
}

function parseImageToken(
  markdown: string,
  start: number,
  end: number,
): { altStart: number; altEnd: number } | undefined {
  const raw = markdown.slice(start, end)
  if (!raw.startsWith("![")) {
    return undefined
  }
  const altEndInRaw = raw.indexOf("](", 2)
  if (altEndInRaw < 0) {
    return undefined
  }
  return { altStart: start + 2, altEnd: start + altEndInRaw }
}

function parseDimensionHint(
  markdown: string,
  start: number,
  paragraphEnd: number,
): { dimensions: { width: number; height: number }; end: number } | undefined {
  const match = /^\{width=(\d+) height=(\d+)\}/.exec(markdown.slice(start, paragraphEnd))
  if (!match) {
    return undefined
  }
  const width = Number(match[1])
  const height = Number(match[2])
  if (!validDimensions(width, height)) {
    return undefined
  }
  return { dimensions: { width, height }, end: start + match[0].length }
}

function normalizeImageURL(value: string): string | undefined {
  try {
    const url = new URL(value)
    if (url.protocol !== "http:" && url.protocol !== "https:") {
      return undefined
    }
    if (url.username || url.password) {
      return undefined
    }
    return url.toString()
  } catch {
    return undefined
  }
}

function coalesceImages(blocks: Block[]): Block[] {
  const output: Block[] = []
  let index = 0
  while (index < blocks.length) {
    if (blocks[index]?.kind.oneofKind !== "image") {
      output.push(blocks[index]!)
      index += 1
      continue
    }

    const images: BlockImage[] = []
    while (index < blocks.length) {
      const block = blocks[index]
      if (!block || block.kind.oneofKind !== "image") break
      images.push(block.kind.image)
      index += 1
    }

    for (let imageIndex = 0; imageIndex < images.length; imageIndex += blockContentLimits.maxAlbumImages) {
      const chunk = images.slice(imageIndex, imageIndex + blockContentLimits.maxAlbumImages)
      if (chunk.length === 1) {
        output.push({ kind: { oneofKind: "image", image: chunk[0]! } })
      } else {
        output.push({ kind: { oneofKind: "album", album: { images: chunk } } })
      }
    }
  }
  return output
}

export function validateBlockContent(
  text: string,
  content: BlockContent,
  options?: { maxTableCells?: number },
): void {
  let blockCount = 0
  let imageCount = 0
  let tableCellCount = 0

  const validateText = (range: BlockText | undefined): void => {
    if (!range || range.offset < 0n || range.length < 0n) {
      throw new Error("Invalid block text range")
    }
    const end = range.offset + range.length
    if (end > BigInt(text.length)) {
      throw new Error("Block text range exceeds message text")
    }
  }

  const validateImage = (image: BlockImage | undefined): void => {
    if (!image) throw new Error("Missing block image")
    imageCount += 1
    if (imageCount > blockContentLimits.maxImages) throw new Error("Too many block images")
    validateText(image.alt)
    if (image.alt?.isRtl !== undefined) throw new Error("Block image alt direction must be absent")
    switch (image.state.oneofKind) {
      case "pending":
        if (image.state.pending.dimensions) {
          validateDimensions(image.state.pending.dimensions.width, image.state.pending.dimensions.height)
        }
        if ((image.state.pending.strippedThumbnail?.byteLength ?? 0) > blockContentLimits.maxStrippedThumbnailBytes) {
          throw new Error("Block image thumbnail is too large")
        }
        break
      case "ready":
        if (image.state.ready.id <= 0n) throw new Error("Invalid ready block photo")
        break
      case "unavailable":
        if (image.state.unavailable.dimensions) {
          validateDimensions(image.state.unavailable.dimensions.width, image.state.unavailable.dimensions.height)
        }
        break
      default:
        throw new Error("Missing block image state")
    }
  }

  const visit = (
    blocks: Block[],
    depth: number,
    listDepth: number,
    suppressLeafDirection: boolean,
  ): void => {
    if (depth > blockContentLimits.maxDepth) throw new Error("Block tree is too deep")
    for (const block of blocks) {
      blockCount += 1
      if (blockCount > blockContentLimits.maxBlocks) throw new Error("Too many blocks")
      switch (block.kind.oneofKind) {
        case "paragraph":
          validateText(block.kind.paragraph)
          if (suppressLeafDirection && block.kind.paragraph.isRtl !== undefined) {
            throw new Error("List prose leaf direction must be absent")
          }
          break
        case "footer":
          validateText(block.kind.footer)
          if (suppressLeafDirection && block.kind.footer.isRtl !== undefined) {
            throw new Error("List prose leaf direction must be absent")
          }
          break
        case "heading":
          if (block.kind.heading.level < 1 || block.kind.heading.level > 6) throw new Error("Invalid heading level")
          validateText(block.kind.heading.text)
          if (suppressLeafDirection && block.kind.heading.text?.isRtl !== undefined) {
            throw new Error("List prose leaf direction must be absent")
          }
          break
        case "code":
          validateText(block.kind.code.text)
          if (block.kind.code.text?.isRtl !== undefined) throw new Error("Code direction must be absent")
          if ((block.kind.code.language?.length ?? 0) > 64) throw new Error("Code language is too long")
          break
        case "list":
          if (listDepth + 1 > blockContentLimits.maxListDepth) throw new Error("List tree is too deep")
          if (block.kind.list.kind === BlockList_Kind.UNSPECIFIED || block.kind.list.items.length === 0) {
            throw new Error("Invalid block list")
          }
          for (const item of block.kind.list.items) {
            if (item.children.length === 0) throw new Error("Empty block list item")
            visit(item.children, depth + 1, listDepth + 1, true)
          }
          break
        case "separator":
          break
        case "image":
          validateImage(block.kind.image)
          break
        case "album":
          if (block.kind.album.images.length < 2 || block.kind.album.images.length > blockContentLimits.maxAlbumImages) {
            throw new Error("Invalid block album")
          }
          for (const image of block.kind.album.images) validateImage(image)
          break
        case "disclosure":
          validateText(block.kind.disclosure.summary)
          if (block.kind.disclosure.summary?.isRtl !== undefined) {
            throw new Error("Disclosure summary direction must be absent")
          }
          visit(block.kind.disclosure.children, depth + 1, listDepth, suppressLeafDirection)
          break
        case "quote":
          if (block.kind.quote.children.length === 0) throw new Error("Empty block quote")
          visit(block.kind.quote.children, depth + 1, listDepth, suppressLeafDirection)
          break
        case "table": {
          const columnCount = block.kind.table.alignments.length
          if (
            block.kind.table.rows.length === 0 ||
            block.kind.table.rows.length > blockContentLimits.maxTableRows ||
            columnCount === 0 ||
            columnCount > blockContentLimits.maxTableColumns
          ) {
            throw new Error("Invalid block table dimensions")
          }
          for (const alignment of block.kind.table.alignments) {
            if (!Object.values(BlockTable_Alignment).includes(alignment)) {
              throw new Error("Invalid block table alignment")
            }
          }
          for (const row of block.kind.table.rows) {
            if (row.cells.length !== columnCount) throw new Error("Inconsistent block table row")
            tableCellCount += row.cells.length
            if (tableCellCount > (options?.maxTableCells ?? blockContentLimits.maxTableCells)) {
              throw new Error("Too many block table cells")
            }
            for (const cell of row.cells) {
              validateText(cell)
              if (cell.isRtl !== undefined) throw new Error("Block table cell direction must be absent")
              const cellText = text.slice(Number(cell.offset), Number(cell.offset + cell.length))
              if (cellText.includes("\n") || cellText.includes("\r")) {
                throw new Error("Block table cells must be single-line")
              }
            }
          }
          break
        }
        default:
          throw new Error("Missing block kind")
      }
    }
  }

  visit(content.blocks, 0, 0, false)
}

function validDimensions(width: number, height: number): boolean {
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width < 1 || height < 1) return false
  if (width > blockContentLimits.maxImageDimension || height > blockContentLimits.maxImageDimension) return false
  const ratio = width / height
  return ratio >= 1 / blockContentLimits.maxImageRatio && ratio <= blockContentLimits.maxImageRatio
}

function validateDimensions(width: number, height: number): void {
  if (!validDimensions(width, height)) throw new Error("Invalid block image dimensions")
}

function visitImages(
  blocks: Block[],
  path: number[],
  visit: (image: BlockImage, path: number[]) => void,
): void {
  blocks.forEach((block, blockIndex) => {
    const blockPath = [...path, blockIndex]
    switch (block.kind.oneofKind) {
      case "image":
        visit(block.kind.image, blockPath)
        break
      case "album":
        block.kind.album.images.forEach((image, imageIndex) => visit(image, [...blockPath, imageIndex]))
        break
      case "disclosure":
        visitImages(block.kind.disclosure.children, blockPath, visit)
        break
      case "quote":
        visitImages(block.kind.quote.children, blockPath, visit)
        break
      case "list":
        block.kind.list.items.forEach((item, itemIndex) => {
          visitImages(item.children, [...blockPath, itemIndex], visit)
        })
        break
    }
  })
}

export function collectReadyBlockPhotoIds(content: BlockContent): bigint[] {
  const ids = new Set<bigint>()
  visitImages(content.blocks, [], (image) => {
    if (image.state.oneofKind === "ready") ids.add(image.state.ready.id)
  })
  return [...ids]
}

export function projectReadyBlockPhotos(
  content: BlockContent,
  photosById: ReadonlyMap<bigint, Photo>,
): BlockContent {
  if (photosById.size === 0) return content

  const projectImage = (image: BlockImage): BlockImage => {
    if (image.state.oneofKind !== "ready") return image
    const current = photosById.get(image.state.ready.id)
    if (!current || current === image.state.ready) return image
    return { ...image, state: { oneofKind: "ready", ready: current } }
  }

  const projectImages = (images: BlockImage[]): BlockImage[] => {
    let changed = false
    const projected = images.map((image) => {
      const next = projectImage(image)
      if (next !== image) changed = true
      return next
    })
    return changed ? projected : images
  }

  const projectBlocks = (blocks: Block[]): Block[] => {
    let changed = false
    const projected = blocks.map((block): Block => {
      let next = block
      switch (block.kind.oneofKind) {
        case "image": {
          const image = projectImage(block.kind.image)
          if (image !== block.kind.image) {
            next = { kind: { oneofKind: "image", image } }
          }
          break
        }
        case "album": {
          const images = projectImages(block.kind.album.images)
          if (images !== block.kind.album.images) {
            next = {
              kind: {
                oneofKind: "album",
                album: { ...block.kind.album, images },
              },
            }
          }
          break
        }
        case "disclosure": {
          const children = projectBlocks(block.kind.disclosure.children)
          if (children !== block.kind.disclosure.children) {
            next = {
              kind: {
                oneofKind: "disclosure",
                disclosure: { ...block.kind.disclosure, children },
              },
            }
          }
          break
        }
        case "quote": {
          const children = projectBlocks(block.kind.quote.children)
          if (children !== block.kind.quote.children) {
            next = {
              kind: {
                oneofKind: "quote",
                quote: { ...block.kind.quote, children },
              },
            }
          }
          break
        }
        case "list": {
          let itemsChanged = false
          const items = block.kind.list.items.map((item) => {
            const children = projectBlocks(item.children)
            if (children === item.children) return item
            itemsChanged = true
            return { ...item, children }
          })
          if (itemsChanged) {
            next = {
              kind: {
                oneofKind: "list",
                list: { ...block.kind.list, items },
              },
            }
          }
          break
        }
      }
      if (next !== block) changed = true
      return next
    })
    return changed ? projected : blocks
  }

  const blocks = projectBlocks(content.blocks)
  return blocks === content.blocks ? content : { ...content, blocks }
}

export function getBlockImageAtPath(content: BlockContent, path: number[]): BlockImage | undefined {
  if (path.length === 0) return undefined
  return getImageInBlocks(content.blocks, path)
}

export function replaceBlockImageAtPath(
  content: BlockContent,
  path: number[],
  image: BlockImage,
): boolean {
  if (path.length === 0) return false
  return replaceImageInBlocks(content.blocks, path, image)
}

function getImageInBlocks(blocks: Block[], path: number[]): BlockImage | undefined {
  const [blockIndex, ...rest] = path
  if (blockIndex === undefined) return undefined
  const block = blocks[blockIndex]
  if (!block) return undefined

  switch (block.kind.oneofKind) {
    case "image":
      return rest.length === 0 ? block.kind.image : undefined
    case "album": {
      const imageIndex = rest[0]
      return rest.length === 1 && imageIndex !== undefined
        ? block.kind.album.images[imageIndex]
        : undefined
    }
    case "disclosure":
      return getImageInBlocks(block.kind.disclosure.children, rest)
    case "quote":
      return getImageInBlocks(block.kind.quote.children, rest)
    case "list": {
      const [itemIndex, ...childPath] = rest
      if (itemIndex === undefined) return undefined
      const item = block.kind.list.items[itemIndex]
      return item ? getImageInBlocks(item.children, childPath) : undefined
    }
    default:
      return undefined
  }
}

function replaceImageInBlocks(blocks: Block[], path: number[], image: BlockImage): boolean {
  const [blockIndex, ...rest] = path
  if (blockIndex === undefined) return false
  const block = blocks[blockIndex]
  if (!block) return false

  switch (block.kind.oneofKind) {
    case "image":
      if (rest.length !== 0) return false
      block.kind.image = image
      return true
    case "album": {
      const imageIndex = rest[0]
      if (rest.length !== 1 || imageIndex === undefined || !block.kind.album.images[imageIndex]) return false
      block.kind.album.images[imageIndex] = image
      return true
    }
    case "disclosure":
      return replaceImageInBlocks(block.kind.disclosure.children, rest, image)
    case "quote":
      return replaceImageInBlocks(block.kind.quote.children, rest, image)
    case "list": {
      const [itemIndex, ...childPath] = rest
      if (itemIndex === undefined) return false
      const item = block.kind.list.items[itemIndex]
      return item ? replaceImageInBlocks(item.children, childPath, image) : false
    }
    default:
      return false
  }
}

function readLine(markdown: string, start: number, end: number): Line {
  const newline = markdown.indexOf("\n", start)
  const rawEnd = newline >= 0 && newline < end ? newline : end
  const contentEnd = rawEnd > start && markdown[rawEnd - 1] === "\r" ? rawEnd - 1 : rawEnd
  return {
    start,
    contentEnd,
    next: rawEnd < end ? rawEnd + 1 : end,
    value: markdown.slice(start, contentEnd),
  }
}

function findDetailsClose(markdown: string, start: number, end: number): Line | undefined {
  let cursor = start
  let depth = 1
  let fence: Fence | undefined
  while (cursor < end) {
    const line = readLine(markdown, cursor, end)
    if (fence) {
      if (isClosingFence(line.value, fence)) fence = undefined
      cursor = line.next
      continue
    }

    const openingFence = parseOpeningFence(line.value)
    if (openingFence) {
      fence = openingFence
      cursor = line.next
      continue
    }

    if (/^<details( open)?>$/.test(line.value)) depth += 1
    if (line.value === "</details>") {
      depth -= 1
      if (depth === 0) return line
    }
    cursor = line.next
  }
  return undefined
}

function parseOpeningFence(line: string): Fence | undefined {
  const match = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line)
  const run = match?.[1]
  if (!run) return undefined
  if (run[0] === "`" && (match?.[2] ?? "").includes("`")) return undefined
  return { character: run[0] as "`" | "~", length: run.length }
}

function isClosingFence(line: string, fence: Fence): boolean {
  const match = /^ {0,3}(`+|~+)[ \t]*$/.exec(line)
  const run = match?.[1]
  return run?.[0] === fence.character && run.length >= fence.length
}

function findFencedCodeContentRange(
  markdown: string,
  start: number,
  end: number,
): { start: number; end: number } | undefined {
  const sourceLineStart = markdown.lastIndexOf("\n", Math.max(0, start - 1)) + 1
  // mdast positions may start after a block-quote or deeply nested list
  // prefix. The legacy projection does not remove those repeated container
  // markers, so it cannot represent that code body as one contiguous range.
  // Keep the literal fallback until both projections share container-aware
  // fence mapping.
  if (!/^ {0,3}$/.test(markdown.slice(sourceLineStart, start))) return undefined

  const openingLine = readLine(markdown, start, end)
  const fence = parseOpeningFence(openingLine.value)
  if (!fence) return undefined

  let cursor = openingLine.next
  while (cursor < end) {
    const line = readLine(markdown, cursor, end)
    if (isClosingFence(line.value, fence)) {
      if (line.contentEnd !== end) return undefined
      return trimmedRange(markdown, openingLine.next, line.start)
    }
    cursor = line.next
  }

  // An unclosed fenced code node extends through the end of the current
  // CommonMark document. This is especially important for full-replacement
  // streaming snapshots: the open trailing block remains code without
  // borrowing a boundary from any completed block before it.
  return trimmedRange(markdown, openingLine.next, end)
}

function trimmedRange(markdown: string, start: number, end: number): { start: number; end: number } {
  const raw = markdown.slice(start, end)
  const leading = raw.length - raw.trimStart().length
  const trimmed = raw.trim()
  const contentStart = start + leading
  return {
    start: contentStart,
    end: trimmed.length === 0 ? contentStart : contentStart + trimmed.length,
  }
}

function nodeRange(
  node: { position?: { start: { offset?: number }; end: { offset?: number } } },
  baseOffset: number,
): { start: number; end: number } | undefined {
  const start = node.position?.start.offset
  const end = node.position?.end.offset
  if (start === undefined || end === undefined) return undefined
  return { start: baseOffset + start, end: baseOffset + end }
}

function isRange(value: { start: number; end: number } | undefined): value is { start: number; end: number } {
  return value !== undefined
}
