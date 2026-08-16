import type {
  BotChat,
  BotChatLastMessage,
  BotCommand,
  BotMessage,
  BotMessageLite,
  BotPeer,
  BotTargetInput,
  BotUser,
  CreateReplyThreadParams,
  CreateThreadParams,
  AnswerMessageActionParams,
  DeleteReactionParams,
  DeleteWebhookParams,
  DeleteMessageParams,
  EditMessageTextParams,
  GetChatHistoryParams,
  GetChatParticipantCountParams,
  GetChatParticipantParams,
  GetChatParams,
  GetFileParams,
  GetMessagesParams,
  GetUpdatesParams,
  ForwardMessageParams,
  PinMessageParams,
  SendChatActionParams,
  SendMessageParams,
  SendReactionParams,
  SetThreadTitleParams,
  SearchMessagesParams,
  SetWebhookParams,
  SetMyCommandsParams,
  UnpinMessageParams,
  UploadFileResult,
} from "@inline-chat/bot-api-types"
import {
  InputPeer,
  MessageAction,
  MessageActionCallback,
  MessageActionCopyText,
  MessageActionResponseUi,
  MessageActionRow,
  MessageActions,
  MessageActionToast,
  MessageEntities,
  MessageSendMode,
  Peer,
  SearchMessagesFilter,
  UpdateComposeAction_ComposeAction,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { BotCommandsModel } from "@in/server/db/models/botCommands"
import { MembersModel } from "@in/server/db/models/members"
import { MessageModel, type DbFullMessage } from "@in/server/db/models/messages"
import { FileModel } from "@in/server/db/models/files"
import { BotUpdatesModel } from "@in/server/db/models/botUpdates"
import { UsersModel } from "@in/server/db/models/users"
import { addReaction as addReactionFn } from "@in/server/functions/messages.addReaction"
import { deleteReaction as deleteReactionFn } from "@in/server/functions/messages.deleteReaction"
import { answerMessageAction as answerMessageActionFn } from "@in/server/functions/messages.answerMessageAction"
import { sendComposeAction as sendComposeActionFn } from "@in/server/functions/messages.sendComposeAction"
import { deleteMessage as deleteMessageFn } from "@in/server/functions/messages.deleteMessage"
import { editMessage as editMessageFn } from "@in/server/functions/messages.editMessage"
import { getChat as getChatFn } from "@in/server/functions/messages.getChat"
import { getChatHistory as getChatHistoryFn } from "@in/server/functions/messages.getChatHistory"
import { getMessages as getMessagesFn } from "@in/server/functions/messages.getMessages"
import { searchMessages as searchMessagesFn } from "@in/server/functions/messages.searchMessages"
import { createChat as createChatFn } from "@in/server/functions/messages.createChat"
import { createSubthread as createSubthreadFn } from "@in/server/functions/messages.createSubthread"
import { sendMessage as sendMessageFn } from "@in/server/functions/messages.sendMessage"
import { forwardMessages as forwardMessagesFn } from "@in/server/functions/messages.forwardMessages"
import { pinMessage as pinMessageFn } from "@in/server/functions/messages.pinMessage"
import { getChatParticipants as getChatParticipantsFn } from "@in/server/functions/messages.getChatParticipants"
import { updateChatInfo as updateChatInfoFn } from "@in/server/functions/messages.updateChatInfo"
import { uploadFileOperation, type UploadFileOperationInput } from "@in/server/methods/uploadFileOperation"
import { handler as getMeHandler } from "@in/server/methods/getMe"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { InlineError } from "@in/server/types/errors"
import { chats, documents, photoSizes, videos, voices } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { getSignedMediaFileProxyUrl } from "@in/server/modules/files/path"
import { validateWebhookUrl } from "@in/server/modules/botUpdates/webhookSecurity"
import { BotUpdateProjector, encodeBotActions, encodeBotMedia } from "@in/server/modules/botUpdates/projector"
import {
  encodeBotEntities,
  parseBotEntities,
  type BotUserJson,
} from "./entityCodec"
import {
  type BotOperationContext,
  type BotOperationHandlers,
} from "./operations.effect"

type BotUserSource = {
  readonly id: number | bigint
  readonly bot?: boolean | null | undefined
  readonly username?: string | null | undefined
  readonly firstName?: string | null | undefined
  readonly lastName?: string | null | undefined
}

type BotChatSource = {
  readonly id: number | bigint
  readonly type?: "private" | "thread" | null | undefined
  readonly title?: string | null | undefined
  readonly spaceId?: number | bigint | null | undefined
  readonly isPublic?: boolean | null | undefined
  readonly parentChatId?: number | bigint | null | undefined
  readonly parentMessageId?: number | bigint | null | undefined
  readonly peerId?: { readonly type?: { readonly oneofKind?: string } } | null | undefined
  readonly lastMsgId?: number | bigint | null | undefined
  readonly emoji?: string | null | undefined
}

type BotMessageSource = {
  readonly messageId: number | bigint
  readonly chatId: number | bigint
  readonly fromId: number | bigint
  readonly date: number | Date
  readonly editDate?: number | Date | null | undefined
  readonly text?: string | null | undefined
  readonly entities?: MessageEntities | null | undefined
  readonly replyToMsgId?: number | bigint | null | undefined
} & Partial<Pick<DbFullMessage, "photo" | "video" | "document" | "voice" | "mediaType" | "actions">>

const toBotUser = (
  user: BotUserSource,
  options?: { readonly isBot?: boolean | undefined },
): BotUser => ({
    id: Number(user.id),
  is_bot:
    typeof user.bot === "boolean"
      ? user.bot
      : (options?.isBot ?? false),
  username: user.username ?? undefined,
  first_name: user.firstName ?? undefined,
  last_name: user.lastName ?? undefined,
})

const BOT_COMMAND_RE = /^[a-z0-9_]+$/
const BOT_COMMAND_LIMIT = 100

const toBotCommand = (row: {
  readonly command: string
  readonly description: string
  readonly sortOrder?: number | null | undefined
}): BotCommand => ({
  command: row.command,
  description: row.description,
  sort_order: row.sortOrder ?? undefined,
})

const isRecord = (
  value: unknown,
): value is Record<string, unknown> =>
  typeof value === "object" &&
  value !== null &&
  !Array.isArray(value)

const parseMaybeJsonValue = (value: unknown): unknown => {
  if (typeof value !== "string") return value
  const trimmed = value.trim()
  if (
    !trimmed.startsWith("{") &&
    !trimmed.startsWith("[")
  ) {
    return value
  }

  try {
    return JSON.parse(trimmed)
  } catch {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
}

const normalizeInputId = (
  value: unknown,
): number | undefined => {
  if (value === undefined) return undefined
  if (typeof value === "number") {
    return Number.isSafeInteger(value) ? value : undefined
  }
  if (typeof value !== "string") return undefined

  const trimmed = value.trim()
  if (!trimmed || !/^[+-]?\d+$/.test(trimmed)) {
    return undefined
  }

  const parsed = Number(trimmed)
  return Number.isSafeInteger(parsed) ? parsed : undefined
}

const normalizeBotCommandsInput = (
  value: unknown,
): Array<{
  command: string
  description: string
  sortOrder: number
}> => {
  const parsed = parseMaybeJsonValue(value)
  if (
    !Array.isArray(parsed) ||
    parsed.length > BOT_COMMAND_LIMIT
  ) {
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
    if (
      typeof rawCommand !== "string" ||
      typeof rawDescription !== "string"
    ) {
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }

    const command = rawCommand.trim()
    const description = rawDescription.trim()
    if (
      command.length < 1 ||
      command.length > 32 ||
      !BOT_COMMAND_RE.test(command) ||
      description.length < 1 ||
      description.length > 256 ||
      seenCommands.has(command)
    ) {
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }
    seenCommands.add(command)

    let sortOrder = index
    if (
      typeof rawSortOrder === "number" &&
      Number.isFinite(rawSortOrder)
    ) {
      sortOrder = rawSortOrder
    } else if (
      typeof rawSortOrder === "string" &&
      rawSortOrder.trim() !== ""
    ) {
      const parsedSortOrder = Number(rawSortOrder)
      if (!Number.isFinite(parsedSortOrder)) {
        throw new InlineError(
          InlineError.ApiError.BAD_REQUEST,
        )
      }
      sortOrder = parsedSortOrder
    }

    return { command, description, sortOrder }
  })
}

const toBotPeer = (peer: unknown): BotPeer => {
  if (!peer) return {}

  if (isRecord(peer)) {
    if (typeof peer["userId"] === "number") {
      return { user_id: peer["userId"] }
    }
    if (typeof peer["threadId"] === "number") {
      return { thread_id: peer["threadId"] }
    }
  }

  const type = (peer as Peer).type
  if (!type) return {}
  if (type.oneofKind === "user") {
    return { user_id: Number(type.user.userId) }
  }
  if (type.oneofKind === "chat") {
    return { thread_id: Number(type.chat.chatId) }
  }
  return {}
}

const minimalUnknownUser = (id: number): BotUser => ({
  id,
  is_bot: false,
})

const makeInputPeer = (
  userId: number | undefined,
  chatId: number | undefined,
): InputPeer => {
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

const parseBotTarget = (
  input: BotTargetInput,
): { userId?: number; chatId?: number } => {
  const userId = normalizeInputId(input.user_id)
  const userIdAlias = normalizeInputId(input.peer_user_id)
  if (
    userId !== undefined &&
    userIdAlias !== undefined &&
    userId !== userIdAlias
  ) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const chatId = normalizeInputId(input.chat_id)
  const chatIdAlias = normalizeInputId(
    input.peer_thread_id,
  )
  if (
    chatId !== undefined &&
    chatIdAlias !== undefined &&
    chatId !== chatIdAlias
  ) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const resolvedUserId = userId ?? userIdAlias
  const resolvedChatId = chatId ?? chatIdAlias
  if (
    (resolvedUserId ? 1 : 0) +
      (resolvedChatId ? 1 : 0) !==
    1
  ) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  return {
    userId: resolvedUserId,
    chatId: resolvedChatId,
  }
}

const makeInputPeerFromBotTarget = async (
  input: BotTargetInput,
  currentUserId: number,
): Promise<InputPeer> => {
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
    chat = await ChatModel.getChatFromInputPeer(chatPeer, {
      currentUserId,
    })
  } catch {
    throw new InlineError(
      InlineError.ApiError.CHAT_ID_INVALID,
    )
  }

  if (chat.type !== "private") return chatPeer
  if (!chat.minUserId || !chat.maxUserId) {
    throw new InlineError(
      InlineError.ApiError.CHAT_ID_INVALID,
    )
  }

  const peerUserId =
    chat.minUserId === currentUserId
      ? chat.maxUserId
      : chat.minUserId
  return makeInputPeer(peerUserId, undefined)
}

const toBotChat = (chat: BotChatSource): BotChat => ({
  chat_id: Number(chat.id),
  type:
    chat.type === "private"
      ? "user"
      : chat.type === "thread"
        ? "thread"
        : chat.peerId?.type?.oneofKind === "user"
          ? "user"
          : chat.peerId?.type?.oneofKind === "chat"
            ? "thread"
            : undefined,
  title: chat.title ? String(chat.title) : undefined,
  space_id: chat.spaceId
    ? Number(chat.spaceId)
    : undefined,
  is_public:
    typeof chat.isPublic === "boolean"
      ? chat.isPublic
      : undefined,
  parent_chat_id: chat.parentChatId
    ? Number(chat.parentChatId)
    : undefined,
  last_message_id: chat.lastMsgId
    ? Number(chat.lastMsgId)
    : undefined,
  emoji: chat.emoji ?? undefined,
})

const dateSeconds = (date: number | Date): number =>
  date instanceof Date
    ? Math.floor(date.getTime() / 1_000)
    : Number(date)

const toBotChatLastMessageFromDb = (
  message: BotMessageSource,
  usersById?: Map<number, BotUserJson>,
): BotChatLastMessage => {
  const fromId = Number(message.fromId)
  return {
    message_id: Number(message.messageId),
    from_id: fromId,
    from:
      usersById?.get(fromId) ??
      minimalUnknownUser(fromId),
    date: dateSeconds(message.date),
    text: message.text ?? undefined,
    entities: encodeBotEntities(message.entities, {
      usersById,
    }),
  }
}

const loadBotMessageSummary = async (
  messageId: number,
  chatId: number,
): Promise<BotChatLastMessage | undefined> => {
  const message = await MessageModel.getMessage(messageId, chatId).catch(() => null)
  if (!message) return undefined
  const usersById = await loadUsersByIds([
    ...mentionUserIdsFromEntities(message.entities),
    Number(message.fromId),
  ])
  return toBotChatLastMessageFromDb(message, usersById)
}

const parseBotBoolean = (
  value: unknown,
): boolean | undefined => {
  if (
    value === undefined ||
    value === null ||
    value === ""
  ) {
    return undefined
  }
  if (typeof value === "boolean") return value
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase()
    if (normalized === "true" || normalized === "1") {
      return true
    }
    if (normalized === "false" || normalized === "0") {
      return false
    }
  }
  throw new InlineError(InlineError.ApiError.BAD_REQUEST)
}

const parseBotParseMarkdown = (
  input: Record<string, unknown>,
): boolean | undefined =>
  parseBotBoolean(
    input["parse_markdown"] ?? input["parseMarkdown"],
  )

const mentionUserIdsFromEntities = (
  entities: MessageEntities | null | undefined,
): number[] => {
  if (!entities?.entities) return []
  const ids: number[] = []
  for (const entity of entities.entities) {
    if (entity.entity.oneofKind === "mention") {
      ids.push(Number(entity.entity.mention.userId))
    }
  }
  return ids
}

const loadUsersByIds = async (
  userIds: number[],
): Promise<Map<number, BotUserJson>> => {
  const unique = Array.from(
    new Set(
      userIds.filter(
        (id) => Number.isFinite(id) && id > 0,
      ),
    ),
  )
  if (unique.length === 0) return new Map()

  const rows = await UsersModel.getUsersWithPhotos(unique)
  const map = new Map<number, BotUserJson>()
  for (const row of rows) {
    map.set(row.user.id, toBotUser(row.user))
  }
  return map
}

const toBotMessageLiteFromProto = (
  message: {
    readonly id: number | bigint
    readonly chatId: number | bigint
    readonly fromId: number | bigint
    readonly date: number | bigint
    readonly editDate?: number | bigint | undefined
    readonly message?: string | undefined
    readonly entities?: MessageEntities | undefined
    readonly peerId?: Peer | undefined
    readonly replyToMsgId?: number | bigint | undefined
  },
  botChat: BotChat,
  usersById?: Map<number, BotUserJson>,
): BotMessageLite => {
  const fromId = Number(message.fromId)
  return {
    message_id: Number(message.id),
    chat_id: Number(message.chatId),
    chat: botChat,
    peer: toBotPeer(message.peerId),
    from_id: fromId,
    from:
      usersById?.get(fromId) ??
      minimalUnknownUser(fromId),
    date: Number(message.date),
    edit_date: message.editDate
      ? Number(message.editDate)
      : undefined,
    text: message.message ?? undefined,
    entities: encodeBotEntities(message.entities, {
      usersById,
    }),
  }
}

const toBotMessageLiteFromDb = (
  message: BotMessageSource,
  inputPeer: InputPeer,
  botChat: BotChat,
  usersById?: Map<number, BotUserJson>,
): BotMessageLite => {
  const fromId = Number(message.fromId)
  return {
    message_id: Number(message.messageId),
    chat_id: Number(message.chatId),
    chat: botChat,
    peer: toBotPeer({ type: inputPeer.type }),
    from_id: fromId,
    from:
      usersById?.get(fromId) ??
      minimalUnknownUser(fromId),
    date: dateSeconds(message.date),
    edit_date: message.editDate
      ? dateSeconds(message.editDate)
      : undefined,
    text: message.text ?? undefined,
    entities: encodeBotEntities(message.entities, {
      usersById,
    }),
    media:
      "mediaType" in message
        ? encodeBotMedia(message as DbFullMessage)
        : undefined,
    actions: encodeBotActions(message.actions),
  }
}

const toBotMessageFromDb = (
  message: BotMessageSource,
  inputPeer: InputPeer,
  botChat: BotChat,
  options?: {
    readonly usersById?: Map<number, BotUserJson>
    readonly replyMessage?: BotMessageSource | null | undefined
  },
): BotMessage => ({
  ...toBotMessageLiteFromDb(
    message,
    inputPeer,
    botChat,
    options?.usersById,
  ),
  reply_to_message: options?.replyMessage
    ? toBotMessageLiteFromDb(
        options.replyMessage,
        inputPeer,
        botChat,
        options.usersById,
      )
    : undefined,
})

type BotProtoMessageSource = Parameters<
  typeof toBotMessageLiteFromProto
>[0]

const encodeBotMessagesFromProto = async (
  messages: ReadonlyArray<BotProtoMessageSource>,
  peerId: InputPeer,
  botChat: BotChat,
): Promise<BotMessage[]> => {
  const chatId = botChat.chat_id
  const replyIds = messages
    .map((message) =>
      message.replyToMsgId !== undefined
        ? Number(message.replyToMsgId)
        : undefined,
    )
    .filter(
      (id): id is number =>
        typeof id === "number" && Number.isFinite(id) && id > 0,
    )
  const replyRows = await MessageModel.getMessagesByIds(
    chatId,
    Array.from(new Set(replyIds)).map((id) => BigInt(id)),
  )
  const replyById = new Map<number, BotMessageSource>(
    replyRows.map((message) => [Number(message.messageId), message]),
  )
  const userIds: number[] = []
  for (const message of messages) {
    userIds.push(
      Number(message.fromId),
      ...mentionUserIdsFromEntities(message.entities),
    )
    const replyId = message.replyToMsgId
      ? Number(message.replyToMsgId)
      : undefined
    const reply = replyId ? replyById.get(replyId) : undefined
    if (reply) {
      userIds.push(
        Number(reply.fromId),
        ...mentionUserIdsFromEntities(reply.entities),
      )
    }
  }
  const usersById = await loadUsersByIds(userIds)

  return messages.map((message) => {
    const replyId = message.replyToMsgId
      ? Number(message.replyToMsgId)
      : undefined
    const reply = replyId ? replyById.get(replyId) : undefined
    return {
      ...toBotMessageLiteFromProto(message, botChat, usersById),
      reply_to_message: reply
        ? toBotMessageLiteFromDb(reply, peerId, botChat, usersById)
        : undefined,
    }
  })
}

const randomId64 = (): bigint => {
  const buffer = crypto.getRandomValues(new Uint8Array(8))
  buffer[0] = buffer[0]! & 0x7f
  let hexadecimal = ""
  for (const byte of buffer) {
    hexadecimal += byte.toString(16).padStart(2, "0")
  }
  const id = BigInt(`0x${hexadecimal}`)
  return id === 0n ? 1n : id
}

const toProtocolActions = (
  actions: SendMessageParams["actions"] | EditMessageTextParams["actions"],
): MessageActions | undefined => {
  if (actions === undefined) return undefined
  return MessageActions.create({
    rows: actions.map((row) =>
      MessageActionRow.create({
        actions: row.map((action) => {
          if (action.type === "copy_text") {
            return MessageAction.create({
              actionId: action.action_id,
              text: action.text,
              action: {
                oneofKind: "copyText",
                copyText: MessageActionCopyText.create({ text: action.copy_text }),
              },
            })
          }
          const data = action.callback_data_base64 !== undefined
            ? Buffer.from(action.callback_data_base64, "base64")
            : Buffer.from(action.callback_data ?? "", "utf8")
          return MessageAction.create({
            actionId: action.action_id,
            text: action.text,
            action: {
              oneofKind: "callback",
              callback: MessageActionCallback.create({ data }),
            },
          })
        }),
      }),
    ),
  })
}

const resolveBotMedia = async (
  media: SendMessageParams["media"],
): Promise<{
  photoId?: bigint
  videoId?: bigint
  documentId?: bigint
  voiceId?: bigint
  nudge?: boolean
}> => {
  if (!media) return {}
  if (media.type === "nudge") return { nudge: true }
  const file = await FileModel.getFileByUniqueId(media.file_id)
  if (!file) {
    throw new InlineError(InlineError.ApiError.FILE_NOT_FOUND)
  }
  switch (media.type) {
    case "photo": {
      const [row] = await db.select({ id: photoSizes.photoId }).from(photoSizes).where(eq(photoSizes.fileId, file.id)).limit(1)
      if (!row?.id) throw new InlineError(InlineError.ApiError.FILE_UNIQUE_ID_INVALID)
      return { photoId: BigInt(row.id) }
    }
    case "video": {
      const [row] = await db.select({ id: videos.id }).from(videos).where(eq(videos.fileId, file.id)).limit(1)
      if (!row) throw new InlineError(InlineError.ApiError.FILE_UNIQUE_ID_INVALID)
      return { videoId: BigInt(row.id) }
    }
    case "document": {
      const [row] = await db.select({ id: documents.id }).from(documents).where(eq(documents.fileId, file.id)).limit(1)
      if (!row) throw new InlineError(InlineError.ApiError.FILE_UNIQUE_ID_INVALID)
      return { documentId: BigInt(row.id) }
    }
    case "voice": {
      const [row] = await db.select({ id: voices.id }).from(voices).where(eq(voices.fileId, file.id)).limit(1)
      if (!row) throw new InlineError(InlineError.ApiError.FILE_UNIQUE_ID_INVALID)
      return { voiceId: BigInt(row.id) }
    }
  }
}

const encodeStoredBotMessage = async (input: {
  messageId: number
  chatId: number
  peerId: InputPeer
  botChat: BotChat
}) => {
  const full = await MessageModel.getMessage(input.messageId, input.chatId)
  const reply = full.replyToMsgId && Number.isFinite(full.replyToMsgId)
    ? await MessageModel.getMessage(full.replyToMsgId, input.chatId).catch(() => null)
    : null
  const usersById = await loadUsersByIds([
    ...mentionUserIdsFromEntities(full.entities),
    ...mentionUserIdsFromEntities(reply?.entities),
    Number(full.fromId),
    ...(reply ? [Number(reply.fromId)] : []),
  ])
  return toBotMessageFromDb(full, input.peerId, input.botChat, { usersById, replyMessage: reply })
}

const inputRecord = (
  input:
    | SendMessageParams
    | EditMessageTextParams
    | SetMyCommandsParams,
): Record<string, unknown> =>
  input as Record<string, unknown>

const getMe = async (context: BotOperationContext) => {
  const result = await getMeHandler(
    {},
    { currentUserId: context.currentUserId },
  )
  return {
    user: toBotUser(result.user, { isBot: true }),
  }
}

const sendMessage = async (
  input: SendMessageParams,
  context: BotOperationContext,
) => {
  const raw = inputRecord(input)
  if (raw["text"] !== undefined && typeof raw["text"] !== "string") {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  const media = await resolveBotMedia(input.media)
  if ((typeof raw["text"] !== "string" || raw["text"].length === 0) && Object.keys(media).length === 0) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const replyToMessageId = normalizeInputId(
    raw["reply_to_message_id"],
  )
  const entities = parseBotEntities(
    parseMaybeJsonValue(raw["entities"]),
  )
  const parseMarkdown = parseBotParseMarkdown(raw)
  const inputPeer = await makeInputPeerFromBotTarget(
    input,
    context.currentUserId,
  )
  const chatResult = await getChatFn(
    { peerId: inputPeer },
    context,
  )
  const chatId = Number(chatResult.chat.id)
  const botChat = toBotChat(chatResult.chat)
  const randomId = randomId64()

  await sendMessageFn({
    peerId: inputPeer,
    message: typeof raw["text"] === "string" ? raw["text"] : undefined,
    replyToMessageId: replyToMessageId
      ? BigInt(replyToMessageId)
      : undefined,
    entities,
    parseMarkdown: parseMarkdown ?? true,
    randomId,
    ...media,
    actions: toProtocolActions(input.actions),
    sendMode: input.silent ? MessageSendMode.MODE_SILENT : undefined,
  }, context)

  const sent = await MessageModel.getMessageByRandomId(
    randomId,
    context.currentUserId,
  )
  return {
    message: await encodeStoredBotMessage({ messageId: sent.messageId, chatId, peerId: inputPeer, botChat }),
  }
}

const getChat = async (
  input: GetChatParams,
  context: BotOperationContext,
) => {
  const peerId = await makeInputPeerFromBotTarget(
    input,
    context.currentUserId,
  )
  const result = await getChatFn({ peerId }, context)
  const chat = toBotChat(result.chat)
  const chatId = Number(result.chat.id)
  const parentMessage =
    result.chat.parentChatId && result.chat.parentMessageId
      ? await loadBotMessageSummary(
          Number(result.chat.parentMessageId),
          Number(result.chat.parentChatId),
        )
      : undefined
  const chatWithParent = parentMessage
    ? { ...chat, parent_message: parentMessage }
    : chat
  const lastMessageId =
    result.chat.lastMsgId !== undefined &&
    result.chat.lastMsgId !== null
      ? Number(result.chat.lastMsgId)
      : undefined

  if (
    lastMessageId &&
    Number.isFinite(lastMessageId) &&
    lastMessageId > 0
  ) {
    const last = await MessageModel.getMessage(
      lastMessageId,
      chatId,
    ).catch(() => null)
    if (last) {
      const usersById = await loadUsersByIds([
        ...mentionUserIdsFromEntities(last.entities),
        Number(last.fromId),
      ])
      return {
        chat: {
          ...chatWithParent,
          last_message: toBotChatLastMessageFromDb(
            last,
            usersById,
          ),
        },
      }
    }
  }

  return { chat: chatWithParent }
}

const getChatHistory = async (
  input: GetChatHistoryParams,
  context: BotOperationContext,
) => {
  const peerId = await makeInputPeerFromBotTarget(
    input,
    context.currentUserId,
  )
  const offsetMessageId = normalizeInputId(
    input.offset_message_id,
  )
  const limit =
    typeof input.limit === "number" &&
    Number.isFinite(input.limit)
      ? input.limit
      : undefined
  const result = await getChatHistoryFn(
    {
      peerId,
      offsetId: offsetMessageId
        ? BigInt(offsetMessageId)
        : undefined,
      limit,
    },
    context,
  )
  const chatResult = await getChatFn(
    { peerId },
    context,
  )
  const botChat = toBotChat(chatResult.chat)
  return {
    messages: await encodeBotMessagesFromProto(
      result.messages,
      peerId,
      botChat,
    ),
  }
}

const normalizeInputIds = (values: ReadonlyArray<unknown>): number[] => {
  const ids = values.map(normalizeInputId)
  if (ids.some((id) => id === undefined)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  return Array.from(new Set(ids as number[]))
}

const getMessages = async (
  input: GetMessagesParams,
  context: BotOperationContext,
) => {
  const peerId = await makeInputPeerFromBotTarget(input, context.currentUserId)
  const messageIds = normalizeInputIds(input.message_ids)
  const [result, chatResult] = await Promise.all([
    getMessagesFn(
      { peerId, messageIds: messageIds.map((id) => BigInt(id)) },
      context,
    ),
    getChatFn({ peerId }, context),
  ])
  const botChat = toBotChat(chatResult.chat)
  return {
    messages: await encodeBotMessagesFromProto(result.messages, peerId, botChat),
  }
}

const toSearchFilter = (
  filter: SearchMessagesParams["filter"],
): SearchMessagesFilter | undefined => {
  switch (filter) {
    case "photo":
      return SearchMessagesFilter.FILTER_PHOTOS
    case "video":
      return SearchMessagesFilter.FILTER_VIDEOS
    case "photo_video":
      return SearchMessagesFilter.FILTER_PHOTO_VIDEO
    case "document":
      return SearchMessagesFilter.FILTER_DOCUMENTS
    case "link":
      return SearchMessagesFilter.FILTER_LINKS
    case "voice":
      return SearchMessagesFilter.FILTER_VOICE_MEMOS
    case undefined:
      return undefined
  }
}

const searchMessages = async (
  input: SearchMessagesParams,
  context: BotOperationContext,
) => {
  const peerId = await makeInputPeerFromBotTarget(input, context.currentUserId)
  const offsetId = normalizeInputId(input.offset_message_id)
  const [result, chatResult] = await Promise.all([
    searchMessagesFn(
      {
        peerId,
        queries: [input.query],
        limit: input.limit,
        offsetId: offsetId ? BigInt(offsetId) : undefined,
        filter: toSearchFilter(input.filter),
      },
      context,
    ),
    getChatFn({ peerId }, context),
  ])
  const botChat = toBotChat(chatResult.chat)
  return {
    messages: await encodeBotMessagesFromProto(result.messages, peerId, botChat),
  }
}

const createThread = async (
  input: CreateThreadParams,
  context: BotOperationContext,
) => {
  const spaceId = normalizeInputId(input.space_id)
  const isPublic = input.is_public ?? spaceId !== undefined
  if (isPublic && (input.participant_ids?.length ?? 0) > 0) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  const participantIds = isPublic
    ? []
    : normalizeInputIds([
        ...(input.participant_ids ?? []),
        context.currentUserId,
      ])
  const result = await createChatFn(
    {
      title: input.title,
      emoji: input.emoji,
      spaceId: spaceId ? BigInt(spaceId) : undefined,
      isPublic,
      participants: participantIds.map((userId) => ({ userId: BigInt(userId) })),
    },
    context,
  )
  const createdChat = await ChatModel.getChatFromInputPeer(
    { type: { oneofKind: "chat", chat: { chatId: BigInt(result.chat.id) } } },
    context,
  )
  BotUpdateProjector.participationChanged({
    botUserId: context.currentUserId,
    chat: createdChat,
    actorUserId: context.currentUserId,
    added: true,
  })
  return { chat: toBotChat(result.chat) }
}

const createReplyThread = async (
  input: CreateReplyThreadParams,
  context: BotOperationContext,
) => {
  const chatId = normalizeInputId(input.chat_id)
  const messageId = normalizeInputId(input.message_id)
  if (!chatId || !messageId) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  const participantIds = normalizeInputIds(input.participant_ids ?? [])
  const result = await createSubthreadFn(
    {
      parentChatId: BigInt(chatId),
      parentMessageId: BigInt(messageId),
      title: input.title,
      emoji: input.emoji,
      participants: participantIds.map((userId) => ({ userId: BigInt(userId) })),
    },
    context,
  )
  const parentMessage = await loadBotMessageSummary(messageId, chatId)
  return {
    chat: {
      ...toBotChat(result.chat),
      parent_message: parentMessage,
    },
  }
}

const editMessageText = async (
  input: EditMessageTextParams,
  context: BotOperationContext,
) => {
  const raw = inputRecord(input)
  const peerId = await makeInputPeerFromBotTarget(
    input,
    context.currentUserId,
  )
  const entities = parseBotEntities(
    parseMaybeJsonValue(raw["entities"]),
  )
  const parseMarkdown = parseBotParseMarkdown(raw)
  const messageId = normalizeInputId(raw["message_id"])
  if (!messageId) {
    throw new InlineError(
      InlineError.ApiError.MSG_ID_INVALID,
    )
  }
  if (typeof raw["text"] !== "string") {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const chat = await ChatModel.getChatFromInputPeer(peerId, {
    currentUserId: context.currentUserId,
  })
  await AccessGuards.ensureChatAccess(
    chat,
    context.currentUserId,
  )
  const botChat = toBotChat(chat)
  await editMessageFn(
    {
      messageId: BigInt(messageId),
      peer: peerId,
      text: raw["text"],
      entities,
      parseMarkdown: parseMarkdown ?? true,
      actions: toProtocolActions(input.actions),
    },
    context,
  )

  const updated = await MessageModel.getMessage(
    messageId,
    chat.id,
  )
  const reply =
    updated.replyToMsgId &&
    Number.isFinite(updated.replyToMsgId)
      ? await MessageModel.getMessage(
          updated.replyToMsgId,
          chat.id,
        ).catch(() => null)
      : null
  const usersById = await loadUsersByIds([
    ...mentionUserIdsFromEntities(updated.entities),
    ...mentionUserIdsFromEntities(reply?.entities),
    Number(updated.fromId),
    ...(reply ? [Number(reply.fromId)] : []),
  ])
  return {
    message: toBotMessageFromDb(
      updated,
      peerId,
      botChat,
      { usersById, replyMessage: reply },
    ),
  }
}

const deleteMessage = async (
  input: DeleteMessageParams,
  context: BotOperationContext,
) => {
  const peerId = await makeInputPeerFromBotTarget(
    input,
    context.currentUserId,
  )
  const messageId = normalizeInputId(input.message_id)
  if (!messageId) {
    throw new InlineError(
      InlineError.ApiError.MSG_ID_INVALID,
    )
  }
  await deleteMessageFn(
    {
      messageIds: [BigInt(messageId)],
      peer: peerId,
    },
    context,
  )
  return {}
}

const forwardMessage = async (
  input: ForwardMessageParams,
  context: BotOperationContext,
) => {
  const destinationPeer = await makeInputPeerFromBotTarget(
    { chat_id: input.chat_id },
    context.currentUserId,
  )
  const sourcePeer = await makeInputPeerFromBotTarget(
    { chat_id: input.from_chat_id },
    context.currentUserId,
  )
  const messageId = normalizeInputId(input.message_id)
  if (!messageId) throw new InlineError(InlineError.ApiError.MSG_ID_INVALID)
  const destination = await ChatModel.getChatFromInputPeer(destinationPeer, context)
  const result = await forwardMessagesFn({
    fromPeerId: sourcePeer,
    toPeerId: destinationPeer,
    messageIds: [BigInt(messageId)],
  }, context)
  const forwardedMessageId = result.messageIds[0]
  if (!forwardedMessageId) throw new InlineError(InlineError.ApiError.INTERNAL)
  return {
    message: await encodeStoredBotMessage({
      messageId: forwardedMessageId,
      chatId: destination.id,
      peerId: destinationPeer,
      botChat: toBotChat(destination),
    }),
  }
}

const setPinnedState = async (
  input: PinMessageParams | UnpinMessageParams,
  context: BotOperationContext,
  unpin: boolean,
) => {
  const peer = await makeInputPeerFromBotTarget({ chat_id: input.chat_id }, context.currentUserId)
  const messageId = normalizeInputId(input.message_id)
  if (!messageId) throw new InlineError(InlineError.ApiError.MSG_ID_INVALID)
  await pinMessageFn({ peer, messageId: BigInt(messageId), unpin }, context)
  return {}
}

const pinMessage = (input: PinMessageParams, context: BotOperationContext) =>
  setPinnedState(input, context, false)

const unpinMessage = (input: UnpinMessageParams, context: BotOperationContext) =>
  setPinnedState(input, context, true)

const getChatParticipants = async (chatIdInput: unknown, context: BotOperationContext) => {
  const chatId = normalizeInputId(chatIdInput)
  if (!chatId) throw new InlineError(InlineError.ApiError.CHAT_ID_INVALID)
  return getChatParticipantsFn({ chatId }, context)
}

const getChatParticipant = async (input: GetChatParticipantParams, context: BotOperationContext) => {
  const chatId = normalizeInputId(input.chat_id)
  const userId = normalizeInputId(input.user_id)
  if (!chatId) throw new InlineError(InlineError.ApiError.CHAT_ID_INVALID)
  if (!userId) throw new InlineError(InlineError.ApiError.USER_INVALID)
  const participants = await getChatParticipants(chatId, context)
  const user = participants.users.find((candidate) => Number(candidate.id) === userId)
  if (!user) throw new InlineError(InlineError.ApiError.USER_INVALID)
  const [chat] = await db.select({ spaceId: chats.spaceId }).from(chats).where(eq(chats.id, chatId)).limit(1)
  const member = chat?.spaceId
    ? await MembersModel.getMemberByUserId(chat.spaceId, userId)
    : undefined
  return {
    participant: {
      user: toBotUser(user),
      member: member
        ? {
            id: member.id,
            space_id: member.spaceId,
            user_id: member.userId,
            role: member.role ?? undefined,
            date: Math.floor(member.date.getTime() / 1_000),
            can_access_public_chats: member.canAccessPublicChats ?? true,
          }
        : undefined,
    },
  }
}

const getChatParticipantCount = async (input: GetChatParticipantCountParams, context: BotOperationContext) => {
  const participants = await getChatParticipants(input.chat_id, context)
  return { count: participants.users.length }
}

const setThreadTitle = async (input: SetThreadTitleParams, context: BotOperationContext) => {
  const chatId = normalizeInputId(input.chat_id)
  if (!chatId || typeof input.title !== "string") {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  await updateChatInfoFn({ chatId, title: input.title }, context)
  return {}
}

const sendReaction = async (
  input: SendReactionParams,
  context: BotOperationContext,
) => {
  const peerId = await makeInputPeerFromBotTarget(
    input,
    context.currentUserId,
  )
  const messageId = normalizeInputId(input.message_id)
  if (!messageId) {
    throw new InlineError(
      InlineError.ApiError.MSG_ID_INVALID,
    )
  }
  if (typeof input.emoji !== "string") {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const chat = await ChatModel.getChatFromInputPeer(peerId, {
    currentUserId: context.currentUserId,
  })
  await AccessGuards.ensureChatAccess(
    chat,
    context.currentUserId,
  )
  await addReactionFn(
    {
      messageId: BigInt(messageId),
      peer: peerId,
      emoji: input.emoji,
    },
    context,
  )
  return {}
}

const deleteReaction = async (
  input: DeleteReactionParams,
  context: BotOperationContext,
) => {
  const peerId = await makeInputPeerFromBotTarget(input, context.currentUserId)
  const messageId = normalizeInputId(input.message_id)
  if (!messageId || typeof input.emoji !== "string") {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  await deleteReactionFn({ messageId: BigInt(messageId), peer: peerId, emoji: input.emoji }, context)
  return {}
}

const answerMessageAction = async (
  input: AnswerMessageActionParams,
  context: BotOperationContext,
) => {
  const interactionId = normalizeInputId(input.interaction_id)
  if (!interactionId) throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  const ui = input.text === undefined
    ? undefined
    : MessageActionResponseUi.create({
        kind: {
          oneofKind: "toast",
          toast: MessageActionToast.create({ text: input.text }),
        },
      })
  await answerMessageActionFn({ interactionId: BigInt(interactionId), ui }, context)
  return {}
}

const composeAction = (action: SendChatActionParams["action"]): UpdateComposeAction_ComposeAction => {
  switch (action) {
    case "typing": return UpdateComposeAction_ComposeAction.TYPING
    case "upload_photo": return UpdateComposeAction_ComposeAction.UPLOADING_PHOTO
    case "upload_video": return UpdateComposeAction_ComposeAction.UPLOADING_VIDEO
    case "upload_document": return UpdateComposeAction_ComposeAction.UPLOADING_DOCUMENT
    case "record_voice": return UpdateComposeAction_ComposeAction.RECORDING_VOICE
    case "cancel": return UpdateComposeAction_ComposeAction.NONE
  }
}

const sendChatAction = async (
  input: SendChatActionParams,
  context: BotOperationContext,
) => {
  const peer = await makeInputPeerFromBotTarget(input, context.currentUserId)
  await sendComposeActionFn({ peer, action: composeAction(input.action) }, context)
  return {}
}

const getFile = async (input: GetFileParams, _context: BotOperationContext) => {
  const file = await FileModel.getFileByUniqueId(input.file_id)
  if (!file) {
    throw new InlineError(InlineError.ApiError.FILE_NOT_FOUND)
  }
  const expiresIn = 60 * 60
  return {
    file: {
      file_id: file.fileUniqueId,
      mime_type: file.mimeType ?? undefined,
      file_size: file.fileSize ?? undefined,
      width: file.width ?? undefined,
      height: file.height ?? undefined,
      duration: file.videoDuration ?? undefined,
      download_url: getSignedMediaFileProxyUrl(file, expiresIn) ?? undefined,
      download_url_expires_at: Math.floor(Date.now() / 1_000) + expiresIn,
    },
  }
}

const uploadFile = async (
  input: UploadFileOperationInput,
  context: BotOperationContext,
): Promise<UploadFileResult> => {
  const uploaded = await uploadFileOperation(input, context)
  return getFile({ file_id: uploaded.fileUniqueId }, context)
}

const getUpdates = (input: GetUpdatesParams, context: BotOperationContext) => {
  if (
    (input.limit !== undefined && (!Number.isInteger(input.limit) || input.limit < 1 || input.limit > 100)) ||
    (input.timeout !== undefined && (!Number.isInteger(input.timeout) || input.timeout < 0 || input.timeout > 50))
  ) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  return BotUpdatesModel.getUpdates(context.currentUserId, input)
}

const setWebhook = async (input: SetWebhookParams, context: BotOperationContext) => {
  if (input.url !== "") await validateWebhookUrl(input.url)
  return BotUpdatesModel.setWebhook(context.currentUserId, input)
}

const deleteWebhook = (input: DeleteWebhookParams, context: BotOperationContext) =>
  BotUpdatesModel.deleteWebhook(context.currentUserId, input)

const getWebhookInfo = (context: BotOperationContext) =>
  BotUpdatesModel.getWebhookInfo(context.currentUserId)

const getMyCommands = async (
  context: BotOperationContext,
) => ({
  commands: (
    await BotCommandsModel.getForBotUserId(
      context.currentUserId,
    )
  ).map(toBotCommand),
})

const setMyCommands = async (
  input: SetMyCommandsParams,
  context: BotOperationContext,
) => {
  const raw = inputRecord(input)
  const commands = normalizeBotCommandsInput(
    raw["commands"],
  )
  await BotCommandsModel.replaceForBotUserId(
    context.currentUserId,
    commands,
  )
  return {}
}

const deleteMyCommands = async (
  context: BotOperationContext,
) => {
  await BotCommandsModel.deleteForBotUserId(
    context.currentUserId,
  )
  return {}
}

export const botOperationHandlers: BotOperationHandlers = {
  getMe,
  sendMessage,
  getChat,
  getChatHistory,
  getMessages,
  searchMessages,
  createThread,
  createReplyThread,
  editMessageText,
  deleteMessage,
  forwardMessage,
  pinMessage,
  unpinMessage,
  getChatParticipant,
  getChatParticipantCount,
  setThreadTitle,
  sendReaction,
  deleteReaction,
  answerMessageAction,
  sendChatAction,
  getFile,
  uploadFile,
  getUpdates,
  setWebhook,
  deleteWebhook,
  getWebhookInfo,
  getMyCommands,
  setMyCommands,
  deleteMyCommands,
}
