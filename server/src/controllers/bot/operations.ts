import type {
  BotChat,
  BotChatLastMessage,
  BotCommand,
  BotMessage,
  BotMessageLite,
  BotPeer,
  BotTargetInput,
  BotUser,
  DeleteMessageParams,
  EditMessageTextParams,
  GetChatHistoryParams,
  GetChatParams,
  SendMessageParams,
  SendReactionParams,
  SetMyCommandsParams,
  SetMyCapabilitiesParams,
} from "@inline-chat/bot-api-types"
import type {
  InputPeer,
  MessageEntities,
  Peer,
} from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { BotCommandsModel } from "@in/server/db/models/botCommands"
import { BotCapabilitiesModel } from "@in/server/db/models/botCapabilities"
import { MessageModel } from "@in/server/db/models/messages"
import { UsersModel } from "@in/server/db/models/users"
import { addReaction as addReactionFn } from "@in/server/functions/messages.addReaction"
import { deleteMessage as deleteMessageFn } from "@in/server/functions/messages.deleteMessage"
import { editMessage as editMessageFn } from "@in/server/functions/messages.editMessage"
import { getChat as getChatFn } from "@in/server/functions/messages.getChat"
import { getChatHistory as getChatHistoryFn } from "@in/server/functions/messages.getChatHistory"
import { sendMessage as sendMessageFn } from "@in/server/functions/messages.sendMessage"
import { handler as getMeHandler } from "@in/server/methods/getMe"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { InlineError } from "@in/server/types/errors"
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
  readonly id: number
  readonly bot?: boolean | null | undefined
  readonly username?: string | null | undefined
  readonly firstName?: string | null | undefined
  readonly lastName?: string | null | undefined
}

type BotChatSource = {
  readonly id: number | bigint
  readonly title?: string | null | undefined
  readonly spaceId?: number | bigint | null | undefined
  readonly isPublic?: boolean | null | undefined
  readonly lastMsgId?: number | bigint | null | undefined
  readonly emoji?: string | null | undefined
}

type BotMessageSource = {
  readonly messageId: number | bigint
  readonly chatId: number | bigint
  readonly fromId: number | bigint
  readonly date: number | Date
  readonly text?: string | null | undefined
  readonly entities?: MessageEntities | null | undefined
  readonly replyToMsgId?: number | bigint | null | undefined
}

const toBotUser = (
  user: BotUserSource,
  options?: { readonly isBot?: boolean | undefined },
): BotUser => ({
  id: user.id,
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
  title: chat.title ? String(chat.title) : undefined,
  space_id: chat.spaceId
    ? Number(chat.spaceId)
    : undefined,
  is_public:
    typeof chat.isPublic === "boolean"
      ? chat.isPublic
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
    readonly message?: string | undefined
    readonly entities?: MessageEntities | undefined
    readonly peerId?: Peer | undefined
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
    text: message.text ?? undefined,
    entities: encodeBotEntities(message.entities, {
      usersById,
    }),
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
  if (typeof raw["text"] !== "string") {
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

  await sendMessageFn(
    {
      peerId: inputPeer,
      message: raw["text"],
      replyToMessageId: replyToMessageId
        ? BigInt(replyToMessageId)
        : undefined,
      entities,
      parseMarkdown: parseMarkdown ?? true,
      randomId,
    },
    context,
  )

  const sent = await MessageModel.getMessageByRandomId(
    randomId,
    context.currentUserId,
  )
  const full = await MessageModel.getMessage(
    sent.messageId,
    chatId,
  )
  const reply =
    full.replyToMsgId &&
    Number.isFinite(full.replyToMsgId)
      ? await MessageModel.getMessage(
          full.replyToMsgId,
          chatId,
        ).catch(() => null)
      : null
  const mentionIds = [
    ...mentionUserIdsFromEntities(full.entities),
    ...mentionUserIdsFromEntities(reply?.entities),
  ]
  const fromIds = [
    Number(full.fromId),
    reply ? Number(reply.fromId) : undefined,
  ].filter(
    (id): id is number =>
      typeof id === "number" &&
      Number.isFinite(id) &&
      id > 0,
  )
  const usersById = await loadUsersByIds([
    ...mentionIds,
    ...fromIds,
  ])

  return {
    message: toBotMessageFromDb(
      full,
      inputPeer,
      botChat,
      { usersById, replyMessage: reply },
    ),
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
          ...chat,
          last_message: toBotChatLastMessageFromDb(
            last,
            usersById,
          ),
        },
      }
    }
  }

  return { chat }
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
  const chatId = Number(chatResult.chat.id)
  const botChat = toBotChat(chatResult.chat)
  const replyIds = result.messages
    .map((message) =>
      message.replyToMsgId !== undefined
        ? Number(message.replyToMsgId)
        : undefined,
    )
    .filter(
      (id): id is number =>
        typeof id === "number" &&
        Number.isFinite(id) &&
        id > 0,
    )
  const replyRows = await MessageModel.getMessagesByIds(
    chatId,
    Array.from(new Set(replyIds)).map((id) => BigInt(id)),
  )
  const replyById = new Map<number, BotMessageSource>(
    replyRows.map((message) => [
      Number(message.messageId),
      message,
    ]),
  )

  const mentionIds: number[] = []
  const fromIds: number[] = []
  for (const message of result.messages) {
    mentionIds.push(
      ...mentionUserIdsFromEntities(message.entities),
    )
    fromIds.push(Number(message.fromId))
    const replyId =
      message.replyToMsgId !== undefined
        ? Number(message.replyToMsgId)
        : undefined
    if (replyId) {
      const reply = replyById.get(replyId)
      if (reply) {
        mentionIds.push(
          ...mentionUserIdsFromEntities(reply.entities),
        )
        fromIds.push(Number(reply.fromId))
      }
    }
  }
  const usersById = await loadUsersByIds([
    ...mentionIds,
    ...fromIds,
  ])
  const messages = result.messages.map((message) => {
    const base = toBotMessageLiteFromProto(
      message,
      botChat,
      usersById,
    )
    const replyId =
      message.replyToMsgId !== undefined
        ? Number(message.replyToMsgId)
        : undefined
    const reply = replyId
      ? replyById.get(replyId)
      : undefined
    return {
      ...base,
      reply_to_message: reply
        ? toBotMessageLiteFromDb(
            reply,
            peerId,
            botChat,
            usersById,
          )
        : undefined,
    }
  })
  return { messages }
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

const toBotCapability = (row: { kind: string; version: number }) =>
  row.kind === "chat_settings" && row.version === 1
    ? { kind: "chat_settings" as const, version: 1 as const }
    : undefined

const normalizeBotCapabilitiesInput = (input: SetMyCapabilitiesParams) => {
  if (!Array.isArray(input.capabilities) || input.capabilities.length > 100) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  const seen = new Set<string>()
  return input.capabilities.map((capability) => {
    if (capability?.kind !== "chat_settings" || capability.version !== 1 || seen.has(capability.kind)) {
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }
    seen.add(capability.kind)
    return { kind: capability.kind, version: capability.version }
  })
}

const getMyCapabilities = async (context: BotOperationContext) => ({
  capabilities: (await BotCapabilitiesModel.getForBotUserId(context.currentUserId)).flatMap((row) => {
    const capability = toBotCapability(row)
    return capability ? [capability] : []
  }),
})

const setMyCapabilities = async (input: SetMyCapabilitiesParams, context: BotOperationContext) => ({
  capabilities: (await BotCapabilitiesModel.replaceForBotUserId(
    context.currentUserId,
    normalizeBotCapabilitiesInput(input),
  )).flatMap((row) => {
    const capability = toBotCapability(row)
    return capability ? [capability] : []
  }),
})

const deleteMyCapabilities = async (context: BotOperationContext) => {
  await BotCapabilitiesModel.replaceForBotUserId(context.currentUserId, [])
  return {}
}

export const botOperationHandlers: BotOperationHandlers = {
  getMe,
  sendMessage,
  getChat,
  getChatHistory,
  editMessageText,
  deleteMessage,
  sendReaction,
  getMyCommands,
  setMyCommands,
  deleteMyCommands,
  getMyCapabilities,
  setMyCapabilities,
  deleteMyCapabilities,
}
