import { Elysia, t, type TSchema } from "elysia"
import { InlineError } from "@in/server/types/errors"
import { authenticateBotHeader, authenticateBotPathOrHeader, type BotHandlerContext } from "./auth"
import { handleBotError } from "./error"
import { TApiEnvelope, normalizeInputId } from "./helpers"
import {
  TBotChat,
  TBotCommand,
  TBotMessage,
  TBotUser,
  TDeleteMessageInput,
  TEditMessageTextInput,
  TGetChatHistoryInput,
  TGetChatInput,
  TSetMyCommandsInput,
  TSendMessageInput,
  TSendRichMessageInput,
  TSendRichMessageDraftInput,
  TSendReactionInput,
} from "./types"
import { handler as getMeHandler } from "@in/server/methods/getMe"
import { sendMessage as sendMessageFn } from "@in/server/functions/messages.sendMessage"
import {
  RichCollageLayout,
  RichDirection,
  RichHorizontalAlign,
  RichTextStyle,
  RichVerticalAlign,
  type InputPeer,
  type Peer,
  type RichBlock,
  type RichMediaRef,
  type RichMessage,
  type RichTableCell,
  type RichTableRow,
  type RichText,
} from "@inline-chat/protocol/core"
import { getChat as getChatFn } from "@in/server/functions/messages.getChat"
import { getChatHistory as getChatHistoryFn } from "@in/server/functions/messages.getChatHistory"
import { deleteMessage as deleteMessageFn } from "@in/server/functions/messages.deleteMessage"
import { editMessage as editMessageFn } from "@in/server/functions/messages.editMessage"
import { addReaction as addReactionFn } from "@in/server/functions/messages.addReaction"
import { ChatModel } from "@in/server/db/models/chats"
import { MessageModel } from "@in/server/db/models/messages"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { ModelError } from "@in/server/db/models/_errors"
import { encodeBotEntities, parseBotEntities, type BotUserJson } from "./entities"
import { UsersModel } from "@in/server/db/models/users"
import { BotCommandsModel } from "@in/server/db/models/botCommands"
import { parseRichHtml } from "@in/server/modules/message/richHtml"
import { parseRichMarkdown, RichTextValidationError } from "@in/server/modules/message/richText"
import { pushRichMessageDraftUpdate } from "@in/server/modules/message/richDraftUpdates"
import type {
  BotChat,
  BotChatLastMessage,
  BotMessage,
  BotMessageLite,
  BotPeer,
  BotRichBlock,
  BotRichBlockType,
  BotRichMessage,
  BotRichText,
  BotRichTextStyle,
  BotTargetInput,
  BotUser,
} from "@inline-chat/bot-api-types"

const toBotUser = (user: any, options?: { isBot?: boolean }): BotUser => {
  const isBot = typeof user.bot === "boolean" ? user.bot : (options?.isBot ?? false)
  return {
    id: user.id,
    is_bot: isBot,
    username: user.username ?? undefined,
    first_name: user.firstName ?? undefined,
    last_name: user.lastName ?? undefined,
  }
}

type BotCommandJson = {
  command: string
  description: string
  sort_order?: number
}

const BOT_COMMAND_RE = /^[a-z0-9_]+$/
const BOT_COMMAND_LIMIT = 100

const toBotCommand = (row: { command: string; description: string; sortOrder?: number | null }): BotCommandJson => ({
  command: row.command,
  description: row.description,
  sort_order: row.sortOrder ?? undefined,
})

const normalizeBotCommandsInput = (value: unknown): Array<{ command: string; description: string; sortOrder: number }> => {
  const parsed = parseMaybeJsonValue(value)
  if (!Array.isArray(parsed)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  if (parsed.length > BOT_COMMAND_LIMIT) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const seenCommands = new Set<string>()

  return parsed.map((item, index) => {
    if (!isRecord(item)) {
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }

    const rawCommand = item["command"]
    const rawDescription = item["description"]
    const rawSortOrder = item["sort_order"]

    if (typeof rawCommand !== "string" || typeof rawDescription !== "string") {
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }

    const command = rawCommand.trim()
    const description = rawDescription.trim()

    if (command.length < 1 || command.length > 32 || !BOT_COMMAND_RE.test(command)) {
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }

    if (description.length < 1 || description.length > 256 || seenCommands.has(command)) {
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }

    seenCommands.add(command)

    let sortOrder = index
    if (typeof rawSortOrder === "number" && Number.isFinite(rawSortOrder)) {
      sortOrder = rawSortOrder
    } else if (typeof rawSortOrder === "string" && rawSortOrder.trim() !== "") {
      const parsedSortOrder = Number(rawSortOrder)
      if (!Number.isFinite(parsedSortOrder)) {
        throw new InlineError(InlineError.ApiError.BAD_REQUEST)
      }
      sortOrder = parsedSortOrder
    }

    return {
      command,
      description,
      sortOrder,
    }
  })
}

const toBotPeer = (peer: any): BotPeer => {
  if (!peer) return {}

  // Legacy API peer shape: { userId } / { threadId }
  if (typeof peer === "object" && peer !== null) {
    if ("userId" in peer && typeof (peer as any).userId === "number") {
      return { user_id: (peer as any).userId }
    }
    if ("threadId" in peer && typeof (peer as any).threadId === "number") {
      // 2026-06-03: Deprecated output shape kept for production bot clients.
      // Prefer top-level `chat_id`; remove after confirming no production use in the previous month.
      return { thread_id: (peer as any).threadId }
    }
  }

  // Protocol peer shape: { type: { oneofKind: "user" | "chat" } }
  const type = (peer as Peer).type
  if (!type) return {}

  if (type.oneofKind === "user") return { user_id: Number(type.user.userId) }
  if (type.oneofKind === "chat") {
    // 2026-06-03: Deprecated output shape kept for production bot clients.
    // Prefer top-level `chat_id`; remove after confirming no production use in the previous month.
    return { thread_id: Number(type.chat.chatId) }
  }

  return {}
}

function minimalUnknownUser(id: number): BotUser {
  return { id, is_bot: false }
}

const makeInputPeer = (userId: number | undefined, chatId: number | undefined): InputPeer => {
  if ((userId ? 1 : 0) + (chatId ? 1 : 0) !== 1) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  if (userId) {
    return {
      type: {
        oneofKind: "user",
        user: { userId: BigInt(userId) },
      },
    }
  }

  return {
    type: {
      oneofKind: "chat",
      chat: { chatId: BigInt(chatId!) },
    },
  }
}

const parseBotTarget = (input: BotTargetInput): { userId?: number; chatId?: number } => {
  const userId = normalizeInputId(input.user_id)
  // 2026-06-03: Deprecated compatibility for production bot clients; prefer `user_id`.
  // Remove after confirming no production use in the previous month.
  const userIdAlias = normalizeInputId(input.peer_user_id)
  if (userId !== undefined && userIdAlias !== undefined && userId !== userIdAlias) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const chatId = normalizeInputId(input.chat_id)
  // 2026-06-03: Deprecated compatibility for production bot clients; prefer `chat_id`.
  // Remove after confirming no production use in the previous month.
  const chatIdAlias = normalizeInputId(input.peer_thread_id)
  if (chatId !== undefined && chatIdAlias !== undefined && chatId !== chatIdAlias) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const resolvedUserId = userId ?? userIdAlias
  const resolvedChatId = chatId ?? chatIdAlias

  if ((resolvedUserId ? 1 : 0) + (resolvedChatId ? 1 : 0) !== 1) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  return { userId: resolvedUserId, chatId: resolvedChatId }
}

const makeInputPeerFromBotTarget = async (input: BotTargetInput, currentUserId: number): Promise<InputPeer> => {
  const target = parseBotTarget(input)

  if (target.userId) {
    return makeInputPeer(target.userId, undefined)
  }

  const chatId = target.chatId
  if (!chatId) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const chatPeer: InputPeer = {
    type: {
      oneofKind: "chat",
      chat: { chatId: BigInt(chatId) },
    },
  }

  let chat
  try {
    chat = await ChatModel.getChatFromInputPeer(chatPeer, { currentUserId })
  } catch {
    throw new InlineError(InlineError.ApiError.CHAT_ID_INVALID)
  }

  if (chat.type !== "private") {
    return chatPeer
  }

  if (!chat.minUserId || !chat.maxUserId) {
    throw new InlineError(InlineError.ApiError.CHAT_ID_INVALID)
  }

  const peerUserId = chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId
  return makeInputPeer(peerUserId, undefined)
}

const toBotChat = (chat: any): BotChat => {
  const chatId = typeof chat.id === "bigint" ? Number(chat.id) : Number(chat.id)
  return {
    chat_id: chatId,
    title: chat.title ? String(chat.title) : undefined,
    space_id: chat.spaceId ? Number(chat.spaceId) : undefined,
    is_public: typeof chat.isPublic === "boolean" ? chat.isPublic : undefined,
    last_message_id: chat.lastMsgId ? Number(chat.lastMsgId) : undefined,
    emoji: chat.emoji ?? undefined,
  }
}

const toBotChatLastMessageFromDb = (message: any, usersById?: Map<number, BotUserJson>): BotChatLastMessage => {
  const dateSeconds =
    message.date instanceof Date ? Math.floor(message.date.getTime() / 1000) : Number(message.date ?? 0)
  const fromId = Number(message.fromId)
  return {
    message_id: Number(message.messageId),
    from_id: fromId,
    from: usersById?.get(fromId) ?? minimalUnknownUser(fromId),
    date: dateSeconds,
    text: message.text ?? undefined,
    entities: encodeBotEntities(message.entities, { usersById }),
    rich_text: encodeBotRichMessage(message.richText),
  }
}

const isRecord = (value: unknown): value is Record<string, unknown> => {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

const mergePostInput = (body: unknown, query: unknown): Record<string, unknown> => {
  return {
    ...(isRecord(query) ? query : {}),
    ...(isRecord(body) ? body : {}),
  }
}

const parseMaybeJsonValue = (value: unknown): unknown => {
  if (typeof value !== "string") return value
  const trimmed = value.trim()
  if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) return value

  try {
    return JSON.parse(trimmed)
  } catch {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
}

const parseBotBoolean = (value: unknown): boolean | undefined => {
  if (value === undefined || value === null || value === "") return undefined
  if (typeof value === "boolean") return value
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase()
    if (normalized === "true" || normalized === "1") return true
    if (normalized === "false" || normalized === "0") return false
  }

  throw new InlineError(InlineError.ApiError.BAD_REQUEST)
}

const parseBotParseMarkdown = (input: Record<string, unknown>): boolean | undefined => {
  // 2026-06-03: Deprecated compatibility for production bot clients; prefer `parse_markdown`.
  // Remove after confirming no production use in the previous month.
  return parseBotBoolean(input["parse_markdown"] ?? input["parseMarkdown"])
}

const parseBotParseRichMarkdown = (input: Record<string, unknown>): boolean | undefined => {
  return parseBotBoolean(input["parse_rich_markdown"] ?? input["parseRichMarkdown"])
}

const parseBotSkipEntityDetection = (input: Record<string, unknown>): boolean | undefined => {
  return parseBotBoolean(input["skip_entity_detection"] ?? input["skipEntityDetection"])
}

const parseBotRichDirection = (value: unknown): RichDirection | undefined => {
  if (value === undefined || value === null || value === "") return undefined
  if (typeof value !== "string") {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  switch (value.trim().toLowerCase()) {
    case "auto":
      return RichDirection.DIRECTION_AUTO
    case "ltr":
      return RichDirection.DIRECTION_LTR
    case "rtl":
      return RichDirection.DIRECTION_RTL
    default:
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
}

const encodeBotRichDirection = (direction: RichDirection | undefined): "auto" | "ltr" | "rtl" | undefined => {
  switch (direction) {
    case RichDirection.DIRECTION_AUTO:
      return "auto"
    case RichDirection.DIRECTION_LTR:
      return "ltr"
    case RichDirection.DIRECTION_RTL:
      return "rtl"
    default:
      return undefined
  }
}

const parseBotRichTextStyle = (value: unknown): RichTextStyle => {
  if (typeof value !== "string") {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  switch (value.trim().toLowerCase()) {
    case "bold":
      return RichTextStyle.STYLE_BOLD
    case "italic":
      return RichTextStyle.STYLE_ITALIC
    case "underline":
      return RichTextStyle.STYLE_UNDERLINE
    case "strikethrough":
      return RichTextStyle.STYLE_STRIKETHROUGH
    case "code":
      return RichTextStyle.STYLE_CODE
    case "spoiler":
      return RichTextStyle.STYLE_SPOILER
    default:
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
}

const encodeBotRichTextStyle = (style: RichTextStyle): BotRichTextStyle | undefined => {
  switch (style) {
    case RichTextStyle.STYLE_BOLD:
      return "bold"
    case RichTextStyle.STYLE_ITALIC:
      return "italic"
    case RichTextStyle.STYLE_UNDERLINE:
      return "underline"
    case RichTextStyle.STYLE_STRIKETHROUGH:
      return "strikethrough"
    case RichTextStyle.STYLE_CODE:
      return "code"
    case RichTextStyle.STYLE_SPOILER:
      return "spoiler"
    default:
      return undefined
  }
}

const parseBotRichBlockType = (value: unknown): BotRichBlockType => {
  if (typeof value !== "string") {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  switch (value.trim().toLowerCase()) {
    case "paragraph":
      return "paragraph"
    case "heading":
      return "heading"
    case "list":
      return "list"
    case "list_item":
      return "list_item"
    case "quote":
      return "quote"
    case "code":
      return "code"
    case "divider":
      return "divider"
    case "thinking":
      return "thinking"
    case "details":
      return "details"
    case "photo":
      return "photo"
    case "video":
      return "video"
    case "document":
      return "document"
    case "audio":
      return "audio"
    case "table":
      return "table"
    case "math":
      return "math"
    case "map":
      return "map"
    case "embed":
      return "embed"
    case "embed_post":
      return "embed_post"
    case "link_preview":
      return "link_preview"
    case "collage":
      return "collage"
    default:
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
}

const parseBotRichText = (value: unknown): RichText => {
  if (!isRecord(value)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const text = value["text"]
  const children = value["children"]
  const styles = value["styles"]
  const url = value["url"]

  return {
    text: typeof text === "string" ? text : "",
    children: Array.isArray(children) ? children.map(parseBotRichText) : [],
    styles: Array.isArray(styles) ? styles.map(parseBotRichTextStyle) : [],
    url: typeof url === "string" ? url : undefined,
  }
}

const encodeBotRichText = (node: RichText): BotRichText => {
  const styles = (node.styles ?? []).map(encodeBotRichTextStyle).filter((style): style is BotRichTextStyle => style !== undefined)
  return {
    ...(node.text ? { text: node.text } : {}),
    ...(node.children?.length ? { children: node.children.map(encodeBotRichText) } : {}),
    ...(styles.length ? { styles } : {}),
    ...(node.url ? { url: node.url } : {}),
  }
}

const parseOptionalString = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined)
const parseOptionalNumber = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined
const parseOptionalInt = (value: unknown): number | undefined => {
  const number = parseOptionalNumber(value)
  return number === undefined ? undefined : Math.trunc(number)
}
const parseOptionalBoolean = (value: unknown): boolean | undefined => (typeof value === "boolean" ? value : undefined)
const parseOptionalBigInt = (value: unknown): bigint | undefined => {
  if (typeof value !== "string" && typeof value !== "number") {
    return undefined
  }

  const id = normalizeInputId(value)
  return id === undefined ? undefined : BigInt(id)
}

const parseBotRichTextList = (value: unknown): RichText[] => {
  if (Array.isArray(value)) {
    return value.map(parseBotRichText)
  }
  if (typeof value === "string") {
    return [{ text: value, children: [], styles: [] }]
  }
  return []
}

const plainTextFromBotRichText = (value: unknown): string => {
  if (typeof value === "string") {
    return value
  }
  if (!Array.isArray(value)) {
    return ""
  }

  const flatten = (node: RichText): string => `${node.text}${node.children.map(flatten).join("")}`
  return value.map(parseBotRichText).map(flatten).join("")
}

const parseBotRichBlockList = (value: Record<string, unknown>): RichBlock[] => {
  const blocks = value["blocks"]
  if (Array.isArray(blocks)) {
    return blocks.map(parseBotRichBlock)
  }

  const children = value["children"]
  if (Array.isArray(children)) {
    return children.map(parseBotRichBlock)
  }

  const text = parseBotRichTextList(value["text"])
  if (text.length === 0) {
    return []
  }

  return [
    {
      blockId: "",
      block: {
        oneofKind: "paragraph",
        paragraph: { text },
      },
    },
  ]
}

const parseBotRichMediaRef = (value: unknown): RichMediaRef | undefined => {
  if (!isRecord(value)) {
    return undefined
  }

  let media: RichMediaRef["media"] = { oneofKind: undefined }
  const photoId = parseOptionalBigInt(value["photo_id"] ?? value["photoId"])
  const videoId = parseOptionalBigInt(value["video_id"] ?? value["videoId"])
  const documentId = parseOptionalBigInt(value["document_id"] ?? value["documentId"])
  const voiceId = parseOptionalBigInt(value["voice_id"] ?? value["voiceId"])
  const publicUrl = parseOptionalString(value["public_url"] ?? value["publicUrl"])

  if (photoId !== undefined) {
    media = { oneofKind: "photoId", photoId }
  } else if (videoId !== undefined) {
    media = { oneofKind: "videoId", videoId }
  } else if (documentId !== undefined) {
    media = { oneofKind: "documentId", documentId }
  } else if (voiceId !== undefined) {
    media = { oneofKind: "voiceId", voiceId }
  } else if (publicUrl) {
    media = { oneofKind: "publicUrl", publicUrl }
  }

  return {
    alt: parseOptionalString(value["alt"]) ?? "",
    fileName: parseOptionalString(value["file_name"] ?? value["fileName"]),
    width: parseOptionalInt(value["width"]),
    height: parseOptionalInt(value["height"]),
    mimeType: parseOptionalString(value["mime_type"] ?? value["mimeType"]),
    cdnUrl: parseOptionalString(value["cdn_url"] ?? value["cdnUrl"]),
    fileUniqueId: parseOptionalString(value["file_unique_id"] ?? value["fileUniqueId"]),
    media,
  }
}

const encodeBotRichMediaRef = (ref: RichMediaRef | undefined): BotRichBlock["media"] | undefined => {
  if (!ref) {
    return undefined
  }

  return {
    ...(ref.alt ? { alt: ref.alt } : {}),
    ...(ref.fileName ? { file_name: ref.fileName } : {}),
    ...(ref.width !== undefined ? { width: ref.width } : {}),
    ...(ref.height !== undefined ? { height: ref.height } : {}),
    ...(ref.mimeType ? { mime_type: ref.mimeType } : {}),
    ...(ref.cdnUrl ? { cdn_url: ref.cdnUrl } : {}),
    ...(ref.fileUniqueId ? { file_unique_id: ref.fileUniqueId } : {}),
    ...(ref.media.oneofKind === "photoId" ? { photo_id: Number(ref.media.photoId) } : {}),
    ...(ref.media.oneofKind === "videoId" ? { video_id: Number(ref.media.videoId) } : {}),
    ...(ref.media.oneofKind === "documentId" ? { document_id: Number(ref.media.documentId) } : {}),
    ...(ref.media.oneofKind === "voiceId" ? { voice_id: Number(ref.media.voiceId) } : {}),
    ...(ref.media.oneofKind === "publicUrl" ? { public_url: ref.media.publicUrl } : {}),
  }
}

const parseBotHorizontalAlign = (value: unknown): RichHorizontalAlign | undefined => {
  if (typeof value !== "string") {
    return undefined
  }
  switch (value.trim().toLowerCase()) {
    case "left":
      return RichHorizontalAlign.HORIZONTAL_ALIGN_LEFT
    case "center":
      return RichHorizontalAlign.HORIZONTAL_ALIGN_CENTER
    case "right":
      return RichHorizontalAlign.HORIZONTAL_ALIGN_RIGHT
    default:
      return undefined
  }
}

const encodeBotHorizontalAlign = (value: RichHorizontalAlign | undefined): "left" | "center" | "right" | undefined => {
  switch (value) {
    case RichHorizontalAlign.HORIZONTAL_ALIGN_LEFT:
      return "left"
    case RichHorizontalAlign.HORIZONTAL_ALIGN_CENTER:
      return "center"
    case RichHorizontalAlign.HORIZONTAL_ALIGN_RIGHT:
      return "right"
    default:
      return undefined
  }
}

const parseBotVerticalAlign = (value: unknown): RichVerticalAlign | undefined => {
  if (typeof value !== "string") {
    return undefined
  }
  switch (value.trim().toLowerCase()) {
    case "top":
      return RichVerticalAlign.VERTICAL_ALIGN_TOP
    case "middle":
      return RichVerticalAlign.VERTICAL_ALIGN_MIDDLE
    case "bottom":
      return RichVerticalAlign.VERTICAL_ALIGN_BOTTOM
    default:
      return undefined
  }
}

const encodeBotVerticalAlign = (value: RichVerticalAlign | undefined): "top" | "middle" | "bottom" | undefined => {
  switch (value) {
    case RichVerticalAlign.VERTICAL_ALIGN_TOP:
      return "top"
    case RichVerticalAlign.VERTICAL_ALIGN_MIDDLE:
      return "middle"
    case RichVerticalAlign.VERTICAL_ALIGN_BOTTOM:
      return "bottom"
    default:
      return undefined
  }
}

const parseBotTableCell = (value: unknown): RichTableCell => {
  if (!isRecord(value)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  return {
    text: parseBotRichTextList(value["text"]),
    header: parseOptionalBoolean(value["header"]) ?? false,
    colspan: parseOptionalInt(value["colspan"]) ?? 1,
    rowspan: parseOptionalInt(value["rowspan"]) ?? 1,
    align: parseBotHorizontalAlign(value["align"]),
    valign: parseBotVerticalAlign(value["valign"]),
  }
}

const parseBotTableRow = (value: unknown): RichTableRow => {
  if (!isRecord(value) || !Array.isArray(value["cells"])) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  return {
    cells: value["cells"].map(parseBotTableCell),
  }
}

const encodeBotTableRows = (rows: RichTableRow[]): NonNullable<BotRichBlock["rows"]> =>
  rows.map((row) => ({
    cells: row.cells.map((cell) => ({
      text: cell.text.map(encodeBotRichText),
      ...(cell.header ? { header: true } : {}),
      ...(cell.colspan !== 1 ? { colspan: cell.colspan } : {}),
      ...(cell.rowspan !== 1 ? { rowspan: cell.rowspan } : {}),
      ...(encodeBotHorizontalAlign(cell.align) ? { align: encodeBotHorizontalAlign(cell.align) } : {}),
      ...(encodeBotVerticalAlign(cell.valign) ? { valign: encodeBotVerticalAlign(cell.valign) } : {}),
    })),
  }))

const parseBotCollageLayout = (value: unknown): RichCollageLayout | undefined => {
  if (typeof value !== "string") {
    return undefined
  }
  switch (value.trim().toLowerCase()) {
    case "grid":
      return RichCollageLayout.COLLAGE_LAYOUT_GRID
    case "masonry":
      return RichCollageLayout.COLLAGE_LAYOUT_MASONRY
    default:
      return undefined
  }
}

const encodeBotCollageLayout = (value: RichCollageLayout | undefined): "grid" | "masonry" | undefined => {
  switch (value) {
    case RichCollageLayout.COLLAGE_LAYOUT_GRID:
      return "grid"
    case RichCollageLayout.COLLAGE_LAYOUT_MASONRY:
      return "masonry"
    default:
      return undefined
  }
}

const parseBotRichBlock = (value: unknown): RichBlock => {
  if (!isRecord(value)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const text = value["text"]
  const children = value["children"]
  const level = value["level"]
  const language = value["language"]
  const ordered = value["ordered"]
  const start = value["start"]
  const type = parseBotRichBlockType(value["type"])
  const blockId = parseOptionalString(value["block_id"] ?? value["blockId"]) ?? ""
  const direction = parseBotRichDirection(value["direction"])
  const caption = parseBotRichTextList(value["caption"])
  const media = parseBotRichMediaRef(value["media"])

  const base = (block: RichBlock["block"]): RichBlock => ({
    blockId,
    direction,
    block,
  })

  switch (type) {
    case "heading":
      return base({
        oneofKind: "heading",
        heading: {
          text: parseBotRichTextList(text),
          level: parseOptionalInt(level) ?? 1,
        },
      })
    case "list": {
      const rawItems = Array.isArray(value["items"]) ? value["items"] : Array.isArray(children) ? children : []
      const items = rawItems.map((item) => {
        if (isRecord(item)) {
          if (item["type"] === "list_item") {
            const parsed = parseBotRichBlock(item)
            return parsed.block.oneofKind === "listItem" ? parsed.block.listItem : { blocks: [parsed] }
          }
          if (Array.isArray(item["blocks"]) || Array.isArray(item["children"]) || item["text"] !== undefined) {
            const checked = parseOptionalBoolean(item["checked"])
            return {
              blocks: parseBotRichBlockList(item),
              ...(checked !== undefined ? { checked } : {}),
            }
          }
        }
        return { blocks: [parseBotRichBlock(item)] }
      })
      return base({
        oneofKind: "list",
        list: {
          ordered: parseOptionalBoolean(ordered) ?? false,
          start: parseOptionalInt(start) ?? 1,
          items,
        },
      })
    }
    case "list_item": {
      const checked = parseOptionalBoolean(value["checked"])
      return base({
        oneofKind: "listItem",
        listItem: {
          blocks: parseBotRichBlockList(value),
          ...(checked !== undefined ? { checked } : {}),
        },
      })
    }
    case "quote":
      return base({
        oneofKind: "quote",
        quote: {
          blocks: parseBotRichBlockList(value),
          expandable: parseOptionalBoolean(value["expandable"]) ?? false,
          initiallyCollapsed: parseOptionalBoolean(value["initially_collapsed"] ?? value["initiallyCollapsed"]) ?? false,
        },
      })
    case "code":
      return base({
        oneofKind: "code",
        code: {
          text: plainTextFromBotRichText(value["code"] ?? text),
          language: parseOptionalString(language),
        },
      })
    case "divider":
      return base({ oneofKind: "divider", divider: {} })
    case "thinking":
      return base({
        oneofKind: "thinking",
        thinking: {
          blocks: parseBotRichBlockList(value),
          initiallyCollapsed: parseOptionalBoolean(value["initially_collapsed"] ?? value["initiallyCollapsed"]) ?? true,
        },
      })
    case "details":
      return base({
        oneofKind: "details",
        details: {
          title: parseBotRichTextList(value["title"] ?? text),
          blocks: parseBotRichBlockList(value),
          initiallyOpen: parseOptionalBoolean(value["initially_open"] ?? value["initiallyOpen"]) ?? false,
        },
      })
    case "photo":
      return base({ oneofKind: "photo", photo: { media, caption } })
    case "video":
      return base({
        oneofKind: "video",
        video: { media, caption, duration: parseOptionalInt(value["duration"]) },
      })
    case "document":
      return base({ oneofKind: "document", document: { media, caption } })
    case "audio":
      return base({
        oneofKind: "audio",
        audio: {
          media,
          caption,
          duration: parseOptionalInt(value["duration"]),
          title: parseOptionalString(value["title"]),
          performer: parseOptionalString(value["performer"]),
        },
      })
    case "table":
      return base({
        oneofKind: "table",
        table: {
          rows: Array.isArray(value["rows"]) ? value["rows"].map(parseBotTableRow) : [],
          caption,
          bordered: parseOptionalBoolean(value["bordered"]) ?? true,
          striped: parseOptionalBoolean(value["striped"]) ?? false,
        },
      })
    case "math":
      return base({
        oneofKind: "math",
        math: {
          source: parseOptionalString(value["source"]) ?? plainTextFromBotRichText(text),
          display: parseOptionalBoolean(value["display"]) ?? true,
          fallback: parseOptionalString(value["fallback"]),
        },
      })
    case "map":
      return base({
        oneofKind: "map",
        map: {
          latitude: parseOptionalNumber(value["latitude"]) ?? 0,
          longitude: parseOptionalNumber(value["longitude"]) ?? 0,
          zoom: parseOptionalInt(value["zoom"]) ?? 0,
          caption,
          title: parseOptionalString(value["title"]),
          address: parseOptionalString(value["address"]),
          openUrl: parseOptionalString(value["open_url"] ?? value["openUrl"]),
          aspectRatio: parseOptionalNumber(value["aspect_ratio"] ?? value["aspectRatio"]),
        },
      })
    case "embed":
      return base({
        oneofKind: "embed",
        embed: {
          url: parseOptionalString(value["url"]),
          html: parseOptionalString(value["html"]),
          poster: parseBotRichMediaRef(value["poster"]),
          width: parseOptionalInt(value["width"]),
          height: parseOptionalInt(value["height"]),
          caption,
          fullWidth: parseOptionalBoolean(value["full_width"] ?? value["fullWidth"]) ?? false,
          allowScrolling: parseOptionalBoolean(value["allow_scrolling"] ?? value["allowScrolling"]) ?? false,
          provider: parseOptionalString(value["provider"]),
        },
      })
    case "embed_post":
      return base({
        oneofKind: "embedPost",
        embedPost: {
          url: parseOptionalString(value["url"]) ?? "",
          author: parseOptionalString(value["author"]) ?? "",
          authorPhoto: parseBotRichMediaRef(value["author_photo"] ?? value["authorPhoto"]),
          date: parseOptionalBigInt(value["date"]),
          blocks: parseBotRichBlockList(value),
          caption,
        },
      })
    case "link_preview":
      return base({
        oneofKind: "linkPreview",
        linkPreview: {
          url: parseOptionalString(value["url"]) ?? "",
          displayUrl: parseOptionalString(value["display_url"] ?? value["displayUrl"]),
          siteName: parseOptionalString(value["site_name"] ?? value["siteName"]),
          title: parseOptionalString(value["title"]),
          description: parseOptionalString(value["description"]),
          media,
          mediaAspectRatio: parseOptionalNumber(value["media_aspect_ratio"] ?? value["mediaAspectRatio"]),
          compact: parseOptionalBoolean(value["compact"]) ?? false,
        },
      })
    case "collage":
      return base({
        oneofKind: "collage",
        collage: {
          items: Array.isArray(value["items"]) ? value["items"].map(parseBotRichBlock) : [],
          caption,
          layout: parseBotCollageLayout(value["layout"]),
        },
      })
    case "paragraph":
    default:
      return base({
        oneofKind: "paragraph",
        paragraph: { text: parseBotRichTextList(text) },
      })
  }
}

const encodeBotRichBlock = (block: RichBlock): BotRichBlock => {
  const base = (value: BotRichBlock): BotRichBlock => ({
    ...value,
    ...(block.blockId ? { block_id: block.blockId } : {}),
    ...(encodeBotRichDirection(block.direction) ? { direction: encodeBotRichDirection(block.direction) } : {}),
  })

  switch (block.block.oneofKind) {
    case "heading":
      return base({
        type: "heading",
        text: block.block.heading.text.map(encodeBotRichText),
        level: block.block.heading.level,
      })
    case "list":
      return base({
        type: "list",
        ordered: block.block.list.ordered,
        start: block.block.list.start,
        items: block.block.list.items.map((item) => ({
          type: "list_item",
          children: item.blocks.map(encodeBotRichBlock),
          ...(item.checked !== undefined ? { checked: item.checked } : {}),
        })),
      })
    case "listItem":
      return base({
        type: "list_item",
        children: block.block.listItem.blocks.map(encodeBotRichBlock),
        ...(block.block.listItem.checked !== undefined ? { checked: block.block.listItem.checked } : {}),
      })
    case "quote":
      return base({
        type: "quote",
        children: block.block.quote.blocks.map(encodeBotRichBlock),
        ...(block.block.quote.expandable ? { expandable: true } : {}),
        ...(block.block.quote.initiallyCollapsed ? { initially_collapsed: true } : {}),
      })
    case "code":
      return base({
        type: "code",
        text: [{ text: block.block.code.text }],
        ...(block.block.code.language ? { language: block.block.code.language } : {}),
      })
    case "divider":
      return base({ type: "divider" })
    case "thinking":
      return base({
        type: "thinking",
        children: block.block.thinking.blocks.map(encodeBotRichBlock),
        ...(block.block.thinking.initiallyCollapsed ? { initially_collapsed: true } : {}),
      })
    case "details":
      return base({
        type: "details",
        title: block.block.details.title.map(encodeBotRichText),
        children: block.block.details.blocks.map(encodeBotRichBlock),
        ...(block.block.details.initiallyOpen ? { initially_open: true } : {}),
      })
    case "photo":
      return base({
        type: "photo",
        media: encodeBotRichMediaRef(block.block.photo.media),
        ...(block.block.photo.caption.length ? { caption: block.block.photo.caption.map(encodeBotRichText) } : {}),
      })
    case "video":
      return base({
        type: "video",
        media: encodeBotRichMediaRef(block.block.video.media),
        ...(block.block.video.caption.length ? { caption: block.block.video.caption.map(encodeBotRichText) } : {}),
        ...(block.block.video.duration !== undefined ? { duration: block.block.video.duration } : {}),
      })
    case "document":
      return base({
        type: "document",
        media: encodeBotRichMediaRef(block.block.document.media),
        ...(block.block.document.caption.length ? { caption: block.block.document.caption.map(encodeBotRichText) } : {}),
      })
    case "audio":
      return base({
        type: "audio",
        media: encodeBotRichMediaRef(block.block.audio.media),
        ...(block.block.audio.caption.length ? { caption: block.block.audio.caption.map(encodeBotRichText) } : {}),
        ...(block.block.audio.duration !== undefined ? { duration: block.block.audio.duration } : {}),
        ...(block.block.audio.title ? { title: block.block.audio.title } : {}),
        ...(block.block.audio.performer ? { performer: block.block.audio.performer } : {}),
      })
    case "table":
      return base({
        type: "table",
        rows: encodeBotTableRows(block.block.table.rows),
        ...(block.block.table.caption.length ? { caption: block.block.table.caption.map(encodeBotRichText) } : {}),
        ...(block.block.table.bordered ? { bordered: true } : {}),
        ...(block.block.table.striped ? { striped: true } : {}),
      })
    case "math":
      return base({
        type: "math",
        source: block.block.math.source,
        display: block.block.math.display,
        ...(block.block.math.fallback ? { fallback: block.block.math.fallback } : {}),
      })
    case "map":
      return base({
        type: "map",
        latitude: block.block.map.latitude,
        longitude: block.block.map.longitude,
        zoom: block.block.map.zoom,
        ...(block.block.map.caption.length ? { caption: block.block.map.caption.map(encodeBotRichText) } : {}),
        ...(block.block.map.title ? { title: block.block.map.title } : {}),
        ...(block.block.map.address ? { address: block.block.map.address } : {}),
        ...(block.block.map.openUrl ? { open_url: block.block.map.openUrl } : {}),
        ...(block.block.map.aspectRatio !== undefined ? { aspect_ratio: block.block.map.aspectRatio } : {}),
      })
    case "embed":
      return base({
        type: "embed",
        ...(block.block.embed.url ? { url: block.block.embed.url } : {}),
        ...(block.block.embed.html ? { html: block.block.embed.html } : {}),
        ...(block.block.embed.poster ? { poster: encodeBotRichMediaRef(block.block.embed.poster) } : {}),
        ...(block.block.embed.width !== undefined ? { width: block.block.embed.width } : {}),
        ...(block.block.embed.height !== undefined ? { height: block.block.embed.height } : {}),
        ...(block.block.embed.caption.length ? { caption: block.block.embed.caption.map(encodeBotRichText) } : {}),
        ...(block.block.embed.fullWidth ? { full_width: true } : {}),
        ...(block.block.embed.allowScrolling ? { allow_scrolling: true } : {}),
        ...(block.block.embed.provider ? { provider: block.block.embed.provider } : {}),
      })
    case "embedPost":
      return base({
        type: "embed_post",
        url: block.block.embedPost.url,
        author: block.block.embedPost.author,
        ...(block.block.embedPost.authorPhoto ? { author_photo: encodeBotRichMediaRef(block.block.embedPost.authorPhoto) } : {}),
        ...(block.block.embedPost.date !== undefined ? { date: Number(block.block.embedPost.date) } : {}),
        children: block.block.embedPost.blocks.map(encodeBotRichBlock),
        ...(block.block.embedPost.caption.length ? { caption: block.block.embedPost.caption.map(encodeBotRichText) } : {}),
      })
    case "linkPreview":
      return base({
        type: "link_preview",
        url: block.block.linkPreview.url,
        ...(block.block.linkPreview.displayUrl ? { display_url: block.block.linkPreview.displayUrl } : {}),
        ...(block.block.linkPreview.siteName ? { site_name: block.block.linkPreview.siteName } : {}),
        ...(block.block.linkPreview.title ? { title: block.block.linkPreview.title } : {}),
        ...(block.block.linkPreview.description ? { description: block.block.linkPreview.description } : {}),
        ...(block.block.linkPreview.media ? { media: encodeBotRichMediaRef(block.block.linkPreview.media) } : {}),
        ...(block.block.linkPreview.mediaAspectRatio !== undefined ? { media_aspect_ratio: block.block.linkPreview.mediaAspectRatio } : {}),
        ...(block.block.linkPreview.compact ? { compact: true } : {}),
      })
    case "collage":
      return base({
        type: "collage",
        items: block.block.collage.items.map(encodeBotRichBlock),
        ...(block.block.collage.caption.length ? { caption: block.block.collage.caption.map(encodeBotRichText) } : {}),
        ...(encodeBotCollageLayout(block.block.collage.layout) ? { layout: encodeBotCollageLayout(block.block.collage.layout) } : {}),
      })
    case "paragraph":
    case undefined:
    default:
      return base({
        type: "paragraph",
        text: block.block.oneofKind === "paragraph" ? block.block.paragraph.text.map(encodeBotRichText) : [],
      })
  }
}

const parseBotRichMessage = (value: unknown): RichMessage | undefined => {
  const parsed = parseMaybeJsonValue(value)
  if (parsed === undefined || parsed === null || parsed === "") {
    return undefined
  }
  if (!isRecord(parsed) || !Array.isArray(parsed["blocks"])) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const fallbackText = parsed["fallback_text"] ?? parsed["fallbackText"]
  if (typeof fallbackText !== "string") {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  return {
    blocks: parsed["blocks"].map(parseBotRichBlock),
    direction: parseBotRichDirection(parsed["direction"]),
    fallbackText,
    version: 1,
  }
}

type ParsedBotInputRichMessage = {
  richText: RichMessage
  text?: string
  skipEntityDetection?: boolean
  demoteInlineOnlyRichText?: boolean
}

const parseBotInputRichMessage = (value: unknown): ParsedBotInputRichMessage | undefined => {
  const parsed = parseMaybeJsonValue(value)
  if (parsed === undefined || parsed === null || parsed === "") {
    return undefined
  }
  if (!isRecord(parsed)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const nested = parsed["rich_message"] ?? parsed["richMessage"] ?? parsed["rich_text"] ?? parsed["richText"]
  const hasMarkdown = Object.hasOwn(parsed, "markdown")
  const hasHtml = Object.hasOwn(parsed, "html")
  const hasNestedRich = nested !== undefined
  const hasDirectStructuredRich = Array.isArray(parsed["blocks"])
  const sourceCount = [hasMarkdown, hasHtml, hasNestedRich, hasDirectStructuredRich].filter(Boolean).length

  if (sourceCount !== 1) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  if (hasMarkdown && typeof parsed["markdown"] !== "string") {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  if (hasHtml && typeof parsed["html"] !== "string") {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const richText = hasNestedRich
    ? parseBotRichMessage(nested)
    : hasMarkdown
    ? parseRichMarkdown(parsed["markdown"] as string)
    : hasHtml
    ? parseRichHtml(parsed["html"] as string)
    : parseBotRichMessage(parsed)

  if (!richText) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const skipEntityDetection = parseBotInputSkipEntityDetection(parsed)

  return {
    richText: applyBotInputRichOptions(richText, parsed),
    ...(hasMarkdown || hasHtml ? { text: richText.fallbackText } : {}),
    ...(hasMarkdown || hasHtml ? { demoteInlineOnlyRichText: true } : {}),
    ...(skipEntityDetection !== undefined ? { skipEntityDetection } : {}),
  }
}

const parseBotInputSkipEntityDetection = (input: Record<string, unknown>): boolean | undefined => {
  return parseBotBoolean(input["skip_entity_detection"] ?? input["skipEntityDetection"])
}

const applyBotInputRichOptions = (message: RichMessage, input: Record<string, unknown>): RichMessage => {
  const direction = parseBotInputRichDirection(input)
  if (direction === undefined) {
    return message
  }
  return {
    ...message,
    direction,
  }
}

const parseBotInputRichDirection = (input: Record<string, unknown>): RichDirection | undefined => {
  const direction = parseBotRichDirection(input["direction"])
  if (direction !== undefined) {
    return direction
  }

  const isRtl = parseBotBoolean(input["is_rtl"] ?? input["isRtl"])
  if (isRtl === undefined) {
    return undefined
  }
  return isRtl ? RichDirection.DIRECTION_RTL : RichDirection.DIRECTION_LTR
}

const encodeBotRichMessage = (message: RichMessage | undefined | null): BotRichMessage | undefined => {
  if (!message) {
    return undefined
  }

  return {
    blocks: (message.blocks ?? []).map(encodeBotRichBlock),
    ...(encodeBotRichDirection(message.direction) ? { direction: encodeBotRichDirection(message.direction) } : {}),
    fallback_text: message.fallbackText,
  }
}

const mentionUserIdsFromEntities = (entities: any): number[] => {
  if (!entities?.entities) return []
  const ids: number[] = []
  for (const e of entities.entities) {
    if (e?.entity?.oneofKind === "mention") {
      ids.push(Number(e.entity.mention.userId))
    }
  }
  return ids
}

const loadUsersByIds = async (userIds: number[]): Promise<Map<number, BotUserJson>> => {
  const unique = Array.from(new Set(userIds.filter((id) => Number.isFinite(id) && id > 0)))
  if (unique.length === 0) return new Map()

  const rows = await UsersModel.getUsersWithPhotos(unique)
  const map = new Map<number, BotUserJson>()
  for (const row of rows) {
    map.set(row.user.id, toBotUser(row.user))
  }
  return map
}

const toBotMessageLiteFromProto = (
  message: any,
  botChat: BotChat,
  usersById?: Map<number, BotUserJson>,
): BotMessageLite => {
  const messageId = typeof message.id === "bigint" ? Number(message.id) : Number(message.id)
  const chatId = typeof message.chatId === "bigint" ? Number(message.chatId) : Number(message.chatId)
  const fromId = typeof message.fromId === "bigint" ? Number(message.fromId) : Number(message.fromId)

  return {
    message_id: messageId,
    chat_id: chatId,
    chat: botChat,
    peer: toBotPeer(message.peerId),
    from_id: fromId,
    from: usersById?.get(fromId) ?? minimalUnknownUser(fromId),
    date: Number(message.date),
    text: message.message ?? undefined,
    entities: encodeBotEntities(message.entities, { usersById }),
    rich_text: encodeBotRichMessage(message.richText),
  }
}

const toBotMessageLiteFromDb = (
  message: any,
  inputPeer: InputPeer,
  botChat: BotChat,
  usersById?: Map<number, BotUserJson>,
): BotMessageLite => {
  const dateSeconds =
    message.date instanceof Date ? Math.floor(message.date.getTime() / 1000) : Number(message.date ?? 0)

  const fromId = Number(message.fromId)
  return {
    message_id: Number(message.messageId),
    chat_id: Number(message.chatId),
    chat: botChat,
    peer: toBotPeer({ type: inputPeer.type }),
    from_id: fromId,
    from: usersById?.get(fromId) ?? minimalUnknownUser(fromId),
    date: dateSeconds,
    text: message.text ?? undefined,
    entities: encodeBotEntities(message.entities, { usersById }),
    rich_text: encodeBotRichMessage(message.richText),
  }
}

const toBotMessageFromDb = (
  message: any,
  inputPeer: InputPeer,
  botChat: BotChat,
  options?: { usersById?: Map<number, BotUserJson>; replyMessage?: any },
): BotMessage => {
  return {
    ...toBotMessageLiteFromDb(message, inputPeer, botChat, options?.usersById),
    reply_to_message: options?.replyMessage
      ? toBotMessageLiteFromDb(options.replyMessage, inputPeer, botChat, options?.usersById)
      : undefined,
  }
}

const randomId64 = (): bigint => {
  // Signed 63-bit random id for idempotency + fetch-after-send (fits Postgres BIGINT).
  const buf = crypto.getRandomValues(new Uint8Array(8))
  buf[0] = buf[0]! & 0x7f
  let hex = ""
  for (const b of buf) hex += b.toString(16).padStart(2, "0")
  const id = BigInt("0x" + hex)
  return id === 0n ? 1n : id
}

const jsonBodyDoc = (schema: TSchema) => ({
  requestBody: {
    required: false,
    content: {
      "application/json": {
        schema,
      },
    },
  },
})

const queryDoc = (schema: TSchema) => {
  const record = schema as Record<string, any>
  const properties = "properties" in record && record["properties"] ? record["properties"] : {}
  const required = new Set(Array.isArray((schema as any).required) ? (schema as any).required : [])
  return {
    parameters: [
      {
        name: "authorization",
        in: "header",
        required: false,
        description: "Bearer bot token. Recommended instead of token-in-path auth.",
        schema: { type: "string" },
      },
      ...Object.entries(properties).map(([name, value]) => {
        const { type, description, examples, ...rest } = value as any
        return {
          name,
          in: "query",
          required: required.has(name),
          description,
          examples,
          schema: { type, ...rest },
        }
      }),
    ],
  }
}

const throwInlineFromUnknown = (error: unknown): never => {
  if (error instanceof InlineError) throw error
  if (error instanceof RichTextValidationError) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  if (error instanceof ModelError) {
    switch (error.code) {
      case ModelError.Codes.CHAT_INVALID:
        throw new InlineError(InlineError.ApiError.PEER_INVALID)
      case ModelError.Codes.MESSAGE_INVALID:
        throw new InlineError(InlineError.ApiError.MSG_ID_INVALID)
      default:
        throw new InlineError(InlineError.ApiError.INTERNAL)
    }
  }

  if (RealtimeRpcError.is(error)) {
    switch (error.code) {
      case RealtimeRpcError.Code.UNAUTHENTICATED:
        throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
      case RealtimeRpcError.Code.PEER_ID_INVALID:
        throw new InlineError(InlineError.ApiError.PEER_INVALID)
      case RealtimeRpcError.Code.MESSAGE_ID_INVALID:
        throw new InlineError(InlineError.ApiError.MSG_ID_INVALID)
      case RealtimeRpcError.Code.CHAT_ID_INVALID:
        throw new InlineError(InlineError.ApiError.CHAT_ID_INVALID)
      case RealtimeRpcError.Code.USER_ID_INVALID:
        throw new InlineError(InlineError.ApiError.USER_INVALID)
      case RealtimeRpcError.Code.BAD_REQUEST:
        throw new InlineError(InlineError.ApiError.BAD_REQUEST)
      default:
        throw new InlineError(InlineError.ApiError.INTERNAL)
    }
  }

  throw new InlineError(InlineError.ApiError.INTERNAL)
}

const ctxFromStore = (store: any): BotHandlerContext => {
  return {
    currentUserId: store.currentUserId,
    currentSessionId: store.currentSessionId,
    ip: store.ip,
  }
}

const botMethods = (authPlugin: any): any => {
  const app: any = new Elysia({ tags: ["Bot"] })
  app.use(authPlugin)

  const sendMessageHandler = async ({ body, query, store }: any) => {
    try {
      const input = mergePostInput(body, query)
      const replyToMessageId = normalizeInputId(input["reply_to_message_id"] as any)
      const parseMarkdown = parseBotParseMarkdown(input)
      const inputRich = parseBotInputRichMessage(input["rich_message"] ?? input["rich_text"])
      const richText = inputRich?.richText
      const parseRichMarkdown = parseBotParseRichMarkdown(input)
      const skipEntityDetection = parseBotSkipEntityDetection(input) ?? inputRich?.skipEntityDetection
      if (parseRichMarkdown && richText) {
        throw new InlineError(InlineError.ApiError.BAD_REQUEST)
      }
      const inputText = input["text"]
      if (typeof inputText !== "string" && !richText) {
        throw new InlineError(InlineError.ApiError.BAD_REQUEST)
      }
      if (parseRichMarkdown && typeof inputText !== "string") {
        throw new InlineError(InlineError.ApiError.BAD_REQUEST)
      }
      const text = inputRich?.text ?? (typeof inputText === "string" ? inputText : richText?.fallbackText)
      const entities = parseBotEntities(parseMaybeJsonValue(input["entities"]), { text })

      const inputPeer = await makeInputPeerFromBotTarget(input, store.currentUserId)
      const chatResult = await getChatFn({ peerId: inputPeer }, ctxFromStore(store))
      const chatId = Number(chatResult.chat.id)
      const botChat = toBotChat(chatResult.chat)

      const randomId = randomId64()
      await sendMessageFn(
        {
          peerId: inputPeer,
          message: text,
          replyToMessageId: replyToMessageId ? BigInt(replyToMessageId) : undefined,
          entities,
          parseMarkdown,
          richText,
          parseRichMarkdown,
          demoteInlineOnlyRichText: inputRich?.demoteInlineOnlyRichText,
          skipEntityDetection,
          randomId,
        },
        ctxFromStore(store),
      )

      const sent = await MessageModel.getMessageByRandomId(randomId, store.currentUserId)
      const full = await MessageModel.getMessage(sent.messageId, chatId)
      const reply =
        full.replyToMsgId && Number.isFinite(full.replyToMsgId)
          ? await MessageModel.getMessage(full.replyToMsgId, chatId).catch(() => null)
          : null

      const mentionIds = [
        ...mentionUserIdsFromEntities(full.entities),
        ...mentionUserIdsFromEntities(reply?.entities),
      ]
      const fromIds = [
        Number(full.fromId),
        reply ? Number(reply.fromId) : undefined,
      ].filter((id): id is number => typeof id === "number" && Number.isFinite(id) && id > 0)

      const usersById = await loadUsersByIds([...mentionIds, ...fromIds])

      return {
        ok: true,
        result: { message: toBotMessageFromDb(full, inputPeer, botChat, { usersById, replyMessage: reply }) },
      }
    } catch (error) {
      throwInlineFromUnknown(error)
    }
  }

  app.get(
    "/getMe",
    async ({ store }: any) => {
      const result = await getMeHandler({}, { currentUserId: store.currentUserId })
      return { ok: true, result: { user: toBotUser(result.user, { isBot: true }) } }
    },
    {
      response: TApiEnvelope(t.Object({ user: TBotUser })),
    },
  )

  app.post(
    "/sendMessage",
    sendMessageHandler,
    {
      detail: jsonBodyDoc(TSendMessageInput),
      response: TApiEnvelope(t.Object({ message: TBotMessage })),
    },
  )

  app.post(
    "/sendRichMessage",
    sendMessageHandler,
    {
      detail: jsonBodyDoc(TSendRichMessageInput),
      response: TApiEnvelope(t.Object({ message: TBotMessage })),
    },
  )

  app.post(
    "/sendRichMessageDraft",
    async ({ body, query, store }: any) => {
      try {
        const input = mergePostInput(body, query)
        const rawDraftId = input["draft_id"] ?? input["draftId"]
        const draftId = typeof rawDraftId === "string" ? rawDraftId.trim() : ""
        if (!draftId) {
          throw new InlineError(InlineError.ApiError.BAD_REQUEST)
        }

        const clear = parseBotBoolean(input["clear"]) ?? false
        const inputRich = parseBotInputRichMessage(input["rich_message"] ?? input["rich_text"])
        const richText = inputRich?.richText
        if (!clear && !richText) {
          throw new InlineError(InlineError.ApiError.BAD_REQUEST)
        }

        const peerId = await makeInputPeerFromBotTarget(input, store.currentUserId)
        const chat = await ChatModel.getChatFromInputPeer(peerId, { currentUserId: store.currentUserId })
        await AccessGuards.ensureChatAccess(chat, store.currentUserId)

        const messageId = normalizeInputId(input["message_id"] as any)
        const ttlSeconds = parseOptionalInt(input["ttl_seconds"] ?? input["ttlSeconds"])
        await pushRichMessageDraftUpdate({
          inputPeer: peerId,
          currentUserId: store.currentUserId,
          senderUserId: store.currentUserId,
          draftId,
          richText,
          messageId: messageId ? BigInt(messageId) : undefined,
          clear,
          ttlSeconds,
        })

        return { ok: true, result: {} }
      } catch (error) {
        throwInlineFromUnknown(error)
      }
    },
    {
      detail: jsonBodyDoc(TSendRichMessageDraftInput),
      response: TApiEnvelope(t.Object({})),
    },
  )

  app.get(
    "/getChat",
    async ({ query, store }: any) => {
      try {
        const peerId = await makeInputPeerFromBotTarget(query, store.currentUserId)

        const result = await getChatFn({ peerId }, ctxFromStore(store))
        const chat = toBotChat(result.chat)
        const chatId = Number(result.chat.id)
        const lastMessageId =
          result.chat.lastMsgId !== undefined && result.chat.lastMsgId !== null
            ? Number(result.chat.lastMsgId)
            : undefined

        if (lastMessageId && Number.isFinite(lastMessageId) && lastMessageId > 0) {
          const last = await MessageModel.getMessage(lastMessageId, chatId).catch(() => null)
          if (last) {
            const mentionIds = mentionUserIdsFromEntities(last.entities)
            const fromIds = [Number(last.fromId)]
            const usersById = await loadUsersByIds([...mentionIds, ...fromIds])
            return {
              ok: true,
              result: { chat: { ...chat, last_message: toBotChatLastMessageFromDb(last, usersById) } },
            }
          }
        }

        return { ok: true, result: { chat } }
      } catch (error) {
        throwInlineFromUnknown(error)
      }
    },
    {
      detail: queryDoc(TGetChatInput),
      response: TApiEnvelope(t.Object({ chat: TBotChat })),
    },
  )

  app.get(
    "/getChatHistory",
    async ({ query, store }: any) => {
      try {
        const peerId = await makeInputPeerFromBotTarget(query, store.currentUserId)

        const offsetMessageId = normalizeInputId(query.offset_message_id)
        const limit = typeof query.limit === "number" && Number.isFinite(query.limit) ? query.limit : undefined

        const result = await getChatHistoryFn(
          {
            peerId,
            offsetId: offsetMessageId ? BigInt(offsetMessageId) : undefined,
            limit,
          },
          ctxFromStore(store),
        )

        const chatResult = await getChatFn({ peerId }, ctxFromStore(store))
        const chatId = Number(chatResult.chat.id)
        const botChat = toBotChat(chatResult.chat)

        const replyIds = result.messages
          .map((m) => (m.replyToMsgId !== undefined ? Number(m.replyToMsgId) : undefined))
          .filter((id): id is number => typeof id === "number" && Number.isFinite(id) && id > 0)

        const replyRows = await MessageModel.getMessagesByIds(
          chatId,
          Array.from(new Set(replyIds)).map((id) => BigInt(id)),
        )
        const replyById = new Map<number, any>(replyRows.map((m) => [Number(m.messageId), m]))

        const mentionIds: number[] = []
        const fromIds: number[] = []
        for (const m of result.messages) {
          mentionIds.push(...mentionUserIdsFromEntities(m.entities))
          fromIds.push(typeof m.fromId === "bigint" ? Number(m.fromId) : Number(m.fromId))
          const rid = m.replyToMsgId !== undefined ? Number(m.replyToMsgId) : undefined
          if (rid) {
            const reply = replyById.get(rid)
            if (reply) {
              mentionIds.push(...mentionUserIdsFromEntities(reply.entities))
              fromIds.push(Number(reply.fromId))
            }
          }
        }
        const usersById = await loadUsersByIds([...mentionIds, ...fromIds])

        const messages = result.messages.map((m) => {
          const base = toBotMessageLiteFromProto(m, botChat, usersById)
          const rid = m.replyToMsgId !== undefined ? Number(m.replyToMsgId) : undefined
          const reply = rid ? replyById.get(rid) : undefined
          return {
            ...base,
            reply_to_message: reply ? toBotMessageLiteFromDb(reply, peerId, botChat, usersById) : undefined,
          }
        })
        return { ok: true, result: { messages } }
      } catch (error) {
        throwInlineFromUnknown(error)
      }
    },
    {
      detail: queryDoc(TGetChatHistoryInput),
      response: TApiEnvelope(t.Object({ messages: t.Array(TBotMessage) })),
    },
  )

  app.post(
    "/editMessageText",
    async ({ body, query, store }: any) => {
      try {
        const input = mergePostInput(body, query)
        const peerId = await makeInputPeerFromBotTarget(input, store.currentUserId)
        const parseMarkdown = parseBotParseMarkdown(input)
        const inputRich = parseBotInputRichMessage(input["rich_message"] ?? input["rich_text"])
        const richText = inputRich?.richText
        const parseRichMarkdown = parseBotParseRichMarkdown(input)
        const skipEntityDetection = parseBotSkipEntityDetection(input) ?? inputRich?.skipEntityDetection
        if (parseRichMarkdown && richText) {
          throw new InlineError(InlineError.ApiError.BAD_REQUEST)
        }

        const messageId = normalizeInputId(input["message_id"] as any)
        if (!messageId) {
          throw new InlineError(InlineError.ApiError.MSG_ID_INVALID)
        }

        const inputText = input["text"]
        if (typeof inputText !== "string" && !richText) {
          throw new InlineError(InlineError.ApiError.BAD_REQUEST)
        }
        if (parseRichMarkdown && typeof inputText !== "string") {
          throw new InlineError(InlineError.ApiError.BAD_REQUEST)
        }
        const text = inputRich?.text ?? (typeof inputText === "string" ? inputText : richText?.fallbackText)
        const entities = parseBotEntities(parseMaybeJsonValue(input["entities"]), { text })

        const chat = await ChatModel.getChatFromInputPeer(peerId, { currentUserId: store.currentUserId })
        await AccessGuards.ensureChatAccess(chat, store.currentUserId)
        const botChat = toBotChat(chat)

        await editMessageFn(
          {
            messageId: BigInt(messageId),
            peer: peerId,
            text,
            entities,
            parseMarkdown,
            richText,
            parseRichMarkdown,
            demoteInlineOnlyRichText: inputRich?.demoteInlineOnlyRichText,
            skipEntityDetection,
          },
          ctxFromStore(store),
        )

        const updated = await MessageModel.getMessage(messageId, chat.id)
        const reply =
          updated.replyToMsgId && Number.isFinite(updated.replyToMsgId)
            ? await MessageModel.getMessage(updated.replyToMsgId, chat.id).catch(() => null)
            : null

        const mentionIds = [
          ...mentionUserIdsFromEntities(updated.entities),
          ...mentionUserIdsFromEntities(reply?.entities),
        ]
        const fromIds = [
          Number(updated.fromId),
          reply ? Number(reply.fromId) : undefined,
        ].filter((id): id is number => typeof id === "number" && Number.isFinite(id) && id > 0)
        const usersById = await loadUsersByIds([...mentionIds, ...fromIds])

        return {
          ok: true,
          result: { message: toBotMessageFromDb(updated, peerId, botChat, { usersById, replyMessage: reply }) },
        }
      } catch (error) {
        throwInlineFromUnknown(error)
      }
    },
    {
      detail: jsonBodyDoc(TEditMessageTextInput),
      response: TApiEnvelope(t.Object({ message: TBotMessage })),
    },
  )

  app.post(
    "/deleteMessage",
    async ({ body, query, store }: any) => {
      try {
        const input = mergePostInput(body, query)
        const peerId = await makeInputPeerFromBotTarget(input, store.currentUserId)

        const messageId = normalizeInputId(input["message_id"] as any)
        if (!messageId) {
          throw new InlineError(InlineError.ApiError.MSG_ID_INVALID)
        }

        await deleteMessageFn(
          { messageIds: [BigInt(messageId)], peer: peerId },
          ctxFromStore(store),
        )

        return { ok: true, result: {} }
      } catch (error) {
        throwInlineFromUnknown(error)
      }
    },
    {
      detail: jsonBodyDoc(TDeleteMessageInput),
      response: TApiEnvelope(t.Object({})),
    },
  )

  app.post(
    "/sendReaction",
    async ({ body, query, store }: any) => {
      try {
        const input = mergePostInput(body, query)
        const peerId = await makeInputPeerFromBotTarget(input, store.currentUserId)

        const messageId = normalizeInputId(input["message_id"] as any)
        if (!messageId) {
          throw new InlineError(InlineError.ApiError.MSG_ID_INVALID)
        }
        const emoji = input["emoji"]
        if (typeof emoji !== "string") {
          throw new InlineError(InlineError.ApiError.BAD_REQUEST)
        }

        const chat = await ChatModel.getChatFromInputPeer(peerId, { currentUserId: store.currentUserId })
        await AccessGuards.ensureChatAccess(chat, store.currentUserId)

        await addReactionFn(
          {
            messageId: BigInt(messageId),
            peer: peerId,
            emoji,
          },
          ctxFromStore(store),
        )

        return { ok: true, result: {} }
      } catch (error) {
        throwInlineFromUnknown(error)
      }
    },
    {
      detail: jsonBodyDoc(TSendReactionInput),
      response: TApiEnvelope(t.Object({})),
    },
  )

  app.get(
    "/getMyCommands",
    async ({ store }: any) => {
      try {
        return {
          ok: true,
          result: {
            commands: (await BotCommandsModel.getForBotUserId(store.currentUserId)).map((command) =>
              toBotCommand({
                command: command.command,
                description: command.description,
                sortOrder: command.sortOrder,
              }),
            ),
          },
        }
      } catch (error) {
        throwInlineFromUnknown(error)
      }
    },
    {
      response: TApiEnvelope(t.Object({ commands: t.Array(TBotCommand) })),
    },
  )

  app.post(
    "/setMyCommands",
    async ({ body, query, store }: any) => {
      try {
        const input = mergePostInput(body, query)
        const commands = normalizeBotCommandsInput(input["commands"]).map((command) => ({
          command: command.command,
          description: command.description,
          sortOrder: command.sortOrder,
        }))

        await BotCommandsModel.replaceForBotUserId(store.currentUserId, commands)

        return { ok: true, result: {} }
      } catch (error) {
        throwInlineFromUnknown(error)
      }
    },
    {
      detail: jsonBodyDoc(TSetMyCommandsInput),
      response: TApiEnvelope(t.Object({})),
    },
  )

  app.post(
    "/deleteMyCommands",
    async ({ store }: any) => {
      try {
        await BotCommandsModel.deleteForBotUserId(store.currentUserId)
        return { ok: true, result: {} }
      } catch (error) {
        throwInlineFromUnknown(error)
      }
    },
    {
      response: TApiEnvelope(t.Object({})),
    },
  )

  // Unknown methods should respond with a structured error envelope.
  // Note: bot docs live at `/bot-api-reference`, outside the `/bot/*` namespace, so this is safe.
  app.all("/*", () => {
    throw new InlineError(InlineError.ApiError.METHOD_NOT_FOUND)
  })

  return app
}

export const botApi: any = new Elysia({ name: "bot-api" })

botApi
  .use(handleBotError)
  // Recommended: Authorization header auth
  .group("/bot", (app: any) => app.use(botMethods(authenticateBotHeader) as any))
  // Token in path: /bot<token>/<method>
  .group("/bot:token", (app: any) => app.use(botMethods(authenticateBotPathOrHeader) as any))
