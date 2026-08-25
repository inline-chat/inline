import type {
  BotFile,
  BotRichBlock,
  BotRichMessage,
  BotRichText,
  BotUser,
} from "@inline-chat/bot-api-types"
import {
  BlockDisclosure_Kind,
  BlockList_Kind,
  BlockTable_Alignment,
  MessageEntity_Type,
  Photo_Format,
  type Block,
  type BlockContent,
  type BlockImage,
  type BlockText,
  type MessageEntities,
  type MessageEntity,
  type Photo,
} from "@inline-chat/protocol/core"
import type { DbFullPhoto } from "@in/server/db/models/files"
import { projectReadyBlockPhotos } from "@in/server/modules/message/blockContent"
import { encodePhoto } from "@in/server/realtime/encoders/encodePhoto"

type RichTextNode = Exclude<BotRichText, string | BotRichText[]>

const minimalUser = (id: number): BotUser => ({ id, is_bot: false })

const nodeSignature = (node: RichTextNode): string => {
  switch (node.type) {
    case "bold":
    case "italic":
    case "code":
      return node.type
    case "url":
      return `${node.type}:${node.url}`
    case "email_address":
      return `${node.type}:${node.email_address}`
    case "phone_number":
      return `${node.type}:${node.phone_number}`
    case "mention":
      return `${node.type}:${node.username}`
    case "text_mention":
      return `${node.type}:${node.user.id}`
    case "bot_command":
      return `${node.type}:${node.bot_command}`
    case "chat_link":
      return `${node.type}:${node.chat_id}`
    case "thread_title":
      return `${node.type}:${node.space_id ?? ""}:${node.title}`
    case "group_mention":
      return `${node.type}:${node.group_id}`
  }
}

const isRichTextNode = (value: BotRichText): value is RichTextNode =>
  typeof value === "object" && !Array.isArray(value)

const combineRichText = (values: BotRichText[]): BotRichText => {
  const combined: BotRichText[] = []
  const append = (value: BotRichText): void => {
    if (Array.isArray(value)) {
      value.forEach(append)
      return
    }
    if (value === "") return

    const previous = combined.at(-1)
    if (typeof previous === "string" && typeof value === "string") {
      combined[combined.length - 1] = previous + value
      return
    }
    if (
      previous !== undefined &&
      isRichTextNode(previous) &&
      isRichTextNode(value) &&
      nodeSignature(previous) === nodeSignature(value)
    ) {
      combined[combined.length - 1] = {
        ...previous,
        text: combineRichText([previous.text, value.text]),
      } as RichTextNode
      return
    }
    combined.push(value)
  }

  values.forEach(append)
  if (combined.length === 0) return ""
  if (combined.length === 1) return combined[0]!
  return combined
}

const entityRange = (entity: MessageEntity) => {
  const start = Number(entity.offset)
  return { start, end: start + Number(entity.length) }
}

const wrapEntity = (
  entity: MessageEntity,
  child: BotRichText,
  source: string,
  usersById: ReadonlyMap<number, BotUser>,
): BotRichText => {
  switch (entity.type) {
    case MessageEntity_Type.BOLD:
      return { type: "bold", text: child }
    case MessageEntity_Type.ITALIC:
      return { type: "italic", text: child }
    case MessageEntity_Type.CODE:
    case MessageEntity_Type.PRE:
      return { type: "code", text: child }
    case MessageEntity_Type.URL:
      return { type: "url", text: child, url: source }
    case MessageEntity_Type.TEXT_URL:
      return entity.entity.oneofKind === "textUrl"
        ? { type: "url", text: child, url: entity.entity.textUrl.url }
        : child
    case MessageEntity_Type.EMAIL:
      return { type: "email_address", text: child, email_address: source }
    case MessageEntity_Type.PHONE_NUMBER:
      return { type: "phone_number", text: child, phone_number: source }
    case MessageEntity_Type.USERNAME_MENTION:
      return { type: "mention", text: child, username: source.replace(/^@/, "") }
    case MessageEntity_Type.MENTION: {
      if (entity.entity.oneofKind !== "mention") return child
      const userId = Number(entity.entity.mention.userId)
      return {
        type: "text_mention",
        text: child,
        user: usersById.get(userId) ?? minimalUser(userId),
      }
    }
    case MessageEntity_Type.BOT_COMMAND:
      return { type: "bot_command", text: child, bot_command: source }
    case MessageEntity_Type.THREAD:
      return entity.entity.oneofKind === "thread"
        ? { type: "chat_link", text: child, chat_id: Number(entity.entity.thread.chatId) }
        : child
    case MessageEntity_Type.THREAD_TITLE:
      return entity.entity.oneofKind === "threadTitle"
        ? {
            type: "thread_title",
            text: child,
            title: entity.entity.threadTitle.title,
            space_id: entity.entity.threadTitle.spaceId > 0n
              ? Number(entity.entity.threadTitle.spaceId)
              : undefined,
          }
        : child
    case MessageEntity_Type.GROUP_MENTION:
      return entity.entity.oneofKind === "groupMention"
        ? { type: "group_mention", text: child, group_id: Number(entity.entity.groupMention.groupId) }
        : child
    case MessageEntity_Type.UNSPECIFIED:
      return child
  }
}

export const encodeBotRichText = (input: {
  text: string
  range: BlockText
  entities?: MessageEntities | null
  usersById?: ReadonlyMap<number, BotUser>
}): BotRichText => {
  const start = Math.max(0, Math.min(input.text.length, Number(input.range.offset)))
  const end = Math.max(start, Math.min(input.text.length, start + Number(input.range.length)))
  const entities = (input.entities?.entities ?? [])
    .map((entity, index) => ({ entity, index, ...entityRange(entity) }))
    .filter(({ start: entityStart, end: entityEnd }) => entityStart < end && entityEnd > start)
  const boundaries = new Set<number>([start, end])
  for (const entity of entities) {
    boundaries.add(Math.max(start, entity.start))
    boundaries.add(Math.min(end, entity.end))
  }
  const points = Array.from(boundaries).sort((a, b) => a - b)
  const usersById = input.usersById ?? new Map<number, BotUser>()
  const segments: BotRichText[] = []

  for (let index = 0; index < points.length - 1; index += 1) {
    const segmentStart = points[index]!
    const segmentEnd = points[index + 1]!
    if (segmentEnd <= segmentStart) continue
    const source = input.text.slice(segmentStart, segmentEnd)
    let rich: BotRichText = source
    const active = entities
      .filter((entity) => entity.start <= segmentStart && entity.end >= segmentEnd)
      .sort((a, b) => a.start - b.start || b.end - a.end || a.index - b.index)
    for (let entityIndex = active.length - 1; entityIndex >= 0; entityIndex -= 1) {
      const activeEntity = active[entityIndex]!
      const entitySource = input.text.slice(
        Math.max(0, activeEntity.start),
        Math.min(input.text.length, activeEntity.end),
      )
      rich = wrapEntity(activeEntity.entity, rich, entitySource, usersById)
    }
    segments.push(rich)
  }

  return combineRichText(segments)
}

const trueOrUndefined = (value: boolean | undefined): true | undefined => value ? true : undefined

const largestPhotoSize = (photo: Photo) =>
  photo.sizes
    .filter((size) => size.type !== "s")
    .reduce<(typeof photo.sizes)[number] | undefined>((best, size) => {
      if (!best) return size
      return size.w * size.h >= best.w * best.h ? size : best
    }, undefined)

const photoFile = (photo: Photo): BotFile | undefined => {
  if (!photo.fileUniqueId) return undefined
  const size = largestPhotoSize(photo)
  return {
    file_id: photo.fileUniqueId,
    mime_type: photo.format === Photo_Format.PNG ? "image/png" : "image/jpeg",
    file_size: size?.size,
    width: size?.w,
    height: size?.h,
  }
}

const imageDimensions = (image: BlockImage): { width?: number; height?: number } => {
  if (image.state.oneofKind === "ready") {
    const size = largestPhotoSize(image.state.ready)
    return { width: size?.w, height: size?.h }
  }
  if (image.state.oneofKind === "pending") {
    return {
      width: image.state.pending.dimensions?.width,
      height: image.state.pending.dimensions?.height,
    }
  }
  if (image.state.oneofKind === "unavailable") {
    return {
      width: image.state.unavailable.dimensions?.width,
      height: image.state.unavailable.dimensions?.height,
    }
  }
  return {}
}

const alignment = (value: BlockTable_Alignment): "left" | "center" | "right" => {
  if (value === BlockTable_Alignment.CENTER) return "center"
  if (value === BlockTable_Alignment.RIGHT) return "right"
  return "left"
}

const encodeBlocks = (input: {
  blocks: readonly Block[]
  text: string
  entities?: MessageEntities | null
  usersById?: ReadonlyMap<number, BotUser>
}): BotRichBlock[] => {
  const richText = (range: BlockText | undefined): BotRichText =>
    range
      ? encodeBotRichText({
          text: input.text,
          range,
          entities: input.entities,
          usersById: input.usersById,
        })
      : ""
  const blocks = (children: readonly Block[]) => encodeBlocks({ ...input, blocks: children })
  const image = (value: BlockImage): BotRichBlock => {
    const dimensions = imageDimensions(value)
    return {
      type: "photo",
      alt: value.alt ? richText(value.alt) : undefined,
      file: value.state.oneofKind === "ready" ? photoFile(value.state.ready) : undefined,
      ...dimensions,
    }
  }

  return input.blocks.flatMap<BotRichBlock>((block) => {
    switch (block.kind.oneofKind) {
      case "paragraph":
        return [{ type: "paragraph", text: richText(block.kind.paragraph), is_rtl: trueOrUndefined(block.kind.paragraph.isRtl) }]
      case "heading":
        return [{
          type: "heading",
          text: richText(block.kind.heading.text),
          size: block.kind.heading.level,
          is_rtl: trueOrUndefined(block.kind.heading.text?.isRtl),
        }]
      case "code":
        return [{ type: "pre", text: richText(block.kind.code.text), language: block.kind.code.language }]
      case "footer":
        return [{ type: "footer", text: richText(block.kind.footer), is_rtl: trueOrUndefined(block.kind.footer.isRtl) }]
      case "separator":
        return [{ type: "divider" }]
      case "image":
        return [image(block.kind.image)]
      case "album":
        return [{ type: "collage", blocks: block.kind.album.images.map(image) }]
      case "quote":
        return [{ type: "blockquote", blocks: blocks(block.kind.quote.children), is_rtl: trueOrUndefined(block.kind.quote.isRtl) }]
      case "disclosure":
        return [{
          type: "details",
          summary: richText(block.kind.disclosure.summary),
          blocks: blocks(block.kind.disclosure.children),
          is_open: trueOrUndefined(block.kind.disclosure.initiallyOpen),
          kind: block.kind.disclosure.kind === BlockDisclosure_Kind.PROGRESS ? "progress" : undefined,
          is_rtl: trueOrUndefined(block.kind.disclosure.isRtl),
        }]
      case "list": {
        const list = block.kind.list
        const start = Number(list.start ?? 1n)
        return [{
          type: "list",
          items: list.items.map((item, index) => ({
            label: list.kind === BlockList_Kind.ORDERED ? String(start + index) : "•",
            blocks: blocks(item.children),
            has_checkbox: item.checked === undefined ? undefined : true,
            is_checked: trueOrUndefined(item.checked),
            value: list.kind === BlockList_Kind.ORDERED ? start + index : undefined,
          })),
          is_rtl: trueOrUndefined(list.isRtl),
        }]
      }
      case "table": {
        const table = block.kind.table
        return [{
          type: "table",
          cells: table.rows.map((row, rowIndex) =>
            row.cells.map((cell, columnIndex) => ({
              text: richText(cell),
              align: alignment(table.alignments[columnIndex] ?? BlockTable_Alignment.UNSPECIFIED),
              is_header: rowIndex === 0 ? true : undefined,
            }))),
          is_bordered: true,
          is_rtl: trueOrUndefined(table.isRtl),
        }]
      }
      case undefined:
        return []
    }
  })
}

export const encodeBotRichMessage = (input: {
  text?: string | null
  blockContent?: BlockContent | null
  entities?: MessageEntities | null
  usersById?: ReadonlyMap<number, BotUser>
}): BotRichMessage | undefined => {
  if (!input.blockContent) return undefined
  return {
    blocks: encodeBlocks({
      blocks: input.blockContent.blocks,
      text: input.text ?? "",
      entities: input.entities,
      usersById: input.usersById,
    }),
  }
}

export const encodeBotRichMessageFromStored = (input: {
  text?: string | null
  blockContent?: BlockContent | null
  blockContentPhotos?: ReadonlyMap<bigint, DbFullPhoto>
  entities?: MessageEntities | null
  usersById?: ReadonlyMap<number, BotUser>
}): BotRichMessage | undefined => {
  let blockContent = input.blockContent
  if (blockContent && input.blockContentPhotos) {
    const photos = new Map<bigint, Photo>()
    for (const [photoId, photo] of input.blockContentPhotos) {
      photos.set(photoId, encodePhoto({ photo }))
    }
    blockContent = projectReadyBlockPhotos(blockContent, photos)
  }
  return encodeBotRichMessage({ ...input, blockContent })
}
