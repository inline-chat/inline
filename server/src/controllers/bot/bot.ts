import { Elysia, t, type TSchema } from "elysia"
import { InlineError } from "@in/server/types/errors"
import { authenticateBotHeader, authenticateBotPathOrHeader, type BotHandlerContext } from "./auth"
import { handleBotError } from "./error"
import { TApiEnvelope, normalizeInputId } from "./helpers"
import {
  TBotChat,
  TBotCommand,
  TBotChatParticipant,
  TBotFile,
  TBotMessage,
  TBotUser,
  TDeleteMessageInput,
  TEditMessageTextInput,
  TGetChatHistoryInput,
  TGetChatInput,
  TGetMessagesInput,
  TSearchMessagesInput,
  TCreateThreadInput,
  TCreateReplyThreadInput,
  TSetMyCommandsInput,
  TForwardMessageInput,
  TPinMessageInput,
  TGetChatParticipantInput,
  TGetChatParticipantCountInput,
  TSetThreadTitleInput,
  TBotUploadFileInput,
  TSendMessageInput,
  TSendReactionInput,
  TAnswerMessageActionInput,
  TSendChatActionInput,
  TGetFileInput,
  TSetWebhookInput,
  TDeleteWebhookInput,
} from "./types"
import { handler as getMeHandler } from "@in/server/methods/getMe"
import type { InputPeer, Peer } from "@inline-chat/protocol/core"
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
import { botOperationHandlers } from "./operations"
import type {
  BotChat,
  BotChatLastMessage,
  BotMessage,
  BotMessageLite,
  BotPeer,
  BotTargetInput,
  BotUser,
  CreateReplyThreadParams,
  CreateThreadParams,
  GetMessagesParams,
  SearchMessagesParams,
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
      // TODO(effect-cutover): remove deprecated `peer.thread_id` after production
      // telemetry shows no Bot client use for 30 days. Prefer top-level `chat_id`.
      return { thread_id: (peer as any).threadId }
    }
  }

  // Protocol peer shape: { type: { oneofKind: "user" | "chat" } }
  const type = (peer as Peer).type
  if (!type) return {}

  if (type.oneofKind === "user") return { user_id: Number(type.user.userId) }
  if (type.oneofKind === "chat") {
    // TODO(effect-cutover): remove deprecated `peer.thread_id` after production
    // telemetry shows no Bot client use for 30 days. Prefer top-level `chat_id`.
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
  // TODO(effect-cutover): remove `peer_user_id` after production telemetry shows
  // no Bot client use for 30 days. Prefer `user_id`.
  const userIdAlias = normalizeInputId(input.peer_user_id)
  if (userId !== undefined && userIdAlias !== undefined && userId !== userIdAlias) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const chatId = normalizeInputId(input.chat_id)
  // TODO(effect-cutover): remove `peer_thread_id` after production telemetry
  // shows no Bot client use for 30 days. Prefer `chat_id`.
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
    type:
      chat.type === "private" || chat.peerId?.type?.oneofKind === "user"
        ? "user"
        : chat.type === "thread" || chat.peerId?.type?.oneofKind === "chat"
          ? "thread"
          : undefined,
    title: chat.title ? String(chat.title) : undefined,
    space_id: chat.spaceId ? Number(chat.spaceId) : undefined,
    is_public: typeof chat.isPublic === "boolean" ? chat.isPublic : undefined,
    parent_chat_id: chat.parentChatId ? Number(chat.parentChatId) : undefined,
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
  }
}

const loadBotMessageSummary = async (
  messageId: number,
  chatId: number,
  context: Parameters<typeof getChatFn>[1],
): Promise<BotChatLastMessage | undefined> => {
  const parentChat = await getChatFn(
    { peerId: makeInputPeer(undefined, chatId) },
    context,
  ).catch(() => null)
  if (!parentChat) return undefined
  const message = await MessageModel.getMessage(messageId, chatId).catch(() => null)
  if (!message) return undefined
  const usersById = await loadUsersByIds([
    ...mentionUserIdsFromEntities(message.entities),
    Number(message.fromId),
  ])
  return toBotChatLastMessageFromDb(message, usersById)
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
  // TODO(effect-cutover): remove `parseMarkdown` after production telemetry
  // shows no Bot client use for 30 days. Prefer `parse_markdown`.
  return parseBotBoolean(input["parse_markdown"] ?? input["parseMarkdown"])
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
    edit_date: message.editDate ? Number(message.editDate) : undefined,
    text: message.message ?? undefined,
    entities: encodeBotEntities(message.entities, { usersById }),
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
  const editDateSeconds =
    message.editDate instanceof Date
      ? Math.floor(message.editDate.getTime() / 1000)
      : message.editDate != null
        ? Number(message.editDate)
        : undefined

  const fromId = Number(message.fromId)
  return {
    message_id: Number(message.messageId),
    chat_id: Number(message.chatId),
    chat: botChat,
    peer: toBotPeer({ type: inputPeer.type }),
    from_id: fromId,
    from: usersById?.get(fromId) ?? minimalUnknownUser(fromId),
    date: dateSeconds,
    edit_date: editDateSeconds,
    text: message.text ?? undefined,
    entities: encodeBotEntities(message.entities, { usersById }),
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
    async ({ body, query, store }: any) => {
      try {
        return {
          ok: true,
          result: await botOperationHandlers.sendMessage(
            mergePostInput(body, query) as any,
            ctxFromStore(store),
          ),
        }
      } catch (error) {
        throwInlineFromUnknown(error)
      }
    },
    {
      detail: jsonBodyDoc(TSendMessageInput),
      response: TApiEnvelope(t.Object({ message: TBotMessage })),
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
        const parentMessage =
          result.chat.parentChatId && result.chat.parentMessageId
            ? await loadBotMessageSummary(
                Number(result.chat.parentMessageId),
                Number(result.chat.parentChatId),
                ctxFromStore(store),
              )
            : undefined
        const chatWithParent = parentMessage ? { ...chat, parent_message: parentMessage } : chat
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
              result: { chat: { ...chatWithParent, last_message: toBotChatLastMessageFromDb(last, usersById) } },
            }
          }
        }

        return { ok: true, result: { chat: chatWithParent } }
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
    "/getMessages",
    async ({ body, query, store }: any) => {
      try {
        const input = mergePostInput(body, query) as GetMessagesParams
        return { ok: true, result: await botOperationHandlers.getMessages(input, ctxFromStore(store)) }
      } catch (error) {
        throwInlineFromUnknown(error)
      }
    },
    {
      detail: jsonBodyDoc(TGetMessagesInput),
      response: TApiEnvelope(t.Object({ messages: t.Array(TBotMessage) })),
    },
  )

  app.post(
    "/searchMessages",
    async ({ body, query, store }: any) => {
      try {
        const input = mergePostInput(body, query) as SearchMessagesParams
        return { ok: true, result: await botOperationHandlers.searchMessages(input, ctxFromStore(store)) }
      } catch (error) {
        throwInlineFromUnknown(error)
      }
    },
    {
      detail: jsonBodyDoc(TSearchMessagesInput),
      response: TApiEnvelope(t.Object({ messages: t.Array(TBotMessage) })),
    },
  )

  app.post(
    "/createThread",
    async ({ body, query, store }: any) => {
      try {
        const input = mergePostInput(body, query) as CreateThreadParams
        return { ok: true, result: await botOperationHandlers.createThread(input, ctxFromStore(store)) }
      } catch (error) {
        throwInlineFromUnknown(error)
      }
    },
    {
      detail: jsonBodyDoc(TCreateThreadInput),
      response: TApiEnvelope(t.Object({ chat: TBotChat })),
    },
  )

  app.post(
    "/createReplyThread",
    async ({ body, query, store }: any) => {
      try {
        const input = mergePostInput(body, query) as CreateReplyThreadParams
        return { ok: true, result: await botOperationHandlers.createReplyThread(input, ctxFromStore(store)) }
      } catch (error) {
        throwInlineFromUnknown(error)
      }
    },
    {
      detail: jsonBodyDoc(TCreateReplyThreadInput),
      response: TApiEnvelope(t.Object({ chat: TBotChat })),
    },
  )

  app.post(
    "/editMessageText",
    async ({ body, query, store }: any) => {
      try {
        const input = mergePostInput(body, query)
        const peerId = await makeInputPeerFromBotTarget(input, store.currentUserId)
        const entities = parseBotEntities(parseMaybeJsonValue(input["entities"]))
        const parseMarkdown = parseBotParseMarkdown(input)

        const messageId = normalizeInputId(input["message_id"] as any)
        if (!messageId) {
          throw new InlineError(InlineError.ApiError.MSG_ID_INVALID)
        }

        const text = input["text"]
        if (typeof text !== "string") {
          throw new InlineError(InlineError.ApiError.BAD_REQUEST)
        }

        const chat = await ChatModel.getChatFromInputPeer(peerId, { currentUserId: store.currentUserId })
        await AccessGuards.ensureChatAccess(chat, store.currentUserId)
        const botChat = toBotChat(chat)

        await editMessageFn(
          {
            messageId: BigInt(messageId),
            peer: peerId,
            text,
            entities,
            parseMarkdown: parseMarkdown ?? true,
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

  app.post("/deleteReaction", async ({ body, query, store }: any) => ({
    ok: true,
    result: await botOperationHandlers.deleteReaction(mergePostInput(body, query) as any, ctxFromStore(store)),
  }), { detail: jsonBodyDoc(TSendReactionInput), response: TApiEnvelope(t.Object({})) })

  app.post("/answerMessageAction", async ({ body, query, store }: any) => ({
    ok: true,
    result: await botOperationHandlers.answerMessageAction(mergePostInput(body, query) as any, ctxFromStore(store)),
  }), { detail: jsonBodyDoc(TAnswerMessageActionInput), response: TApiEnvelope(t.Object({})) })

  app.post("/sendChatAction", async ({ body, query, store }: any) => ({
    ok: true,
    result: await botOperationHandlers.sendChatAction(mergePostInput(body, query) as any, ctxFromStore(store)),
  }), { detail: jsonBodyDoc(TSendChatActionInput), response: TApiEnvelope(t.Object({})) })

  app.get("/getFile", async ({ query, store }: any) => ({
    ok: true,
    result: await botOperationHandlers.getFile(query as any, ctxFromStore(store)),
  }), { query: TGetFileInput, response: TApiEnvelope(t.Any()) })

  app.get("/getUpdates", async ({ query, store }: any) => {
    const input = { ...query }
    if (typeof input["allowed_updates"] === "string") input["allowed_updates"] = parseMaybeJsonValue(input["allowed_updates"])
    if (typeof input["limit"] === "string") input["limit"] = Number(input["limit"])
    if (typeof input["timeout"] === "string") input["timeout"] = Number(input["timeout"])
    if (typeof input["offset"] === "string") input["offset"] = Number(input["offset"])
    return { ok: true, result: await botOperationHandlers.getUpdates(input as any, ctxFromStore(store)) }
  }, { response: TApiEnvelope(t.Array(t.Any())) })

  app.post("/setWebhook", async ({ body, query, store }: any) => {
    const input = mergePostInput(body, query)
    if (typeof input["allowed_updates"] === "string") input["allowed_updates"] = parseMaybeJsonValue(input["allowed_updates"])
    return { ok: true, result: await botOperationHandlers.setWebhook(input as any, ctxFromStore(store)) }
  }, { detail: jsonBodyDoc(TSetWebhookInput), response: TApiEnvelope(t.Literal(true)) })

  app.post("/deleteWebhook", async ({ body, query, store }: any) => ({
    ok: true,
    result: await botOperationHandlers.deleteWebhook(mergePostInput(body, query) as any, ctxFromStore(store)),
  }), { detail: jsonBodyDoc(TDeleteWebhookInput), response: TApiEnvelope(t.Literal(true)) })

  app.get("/getWebhookInfo", async ({ store }: any) => ({
    ok: true,
    result: await botOperationHandlers.getWebhookInfo(ctxFromStore(store)),
  }), { response: TApiEnvelope(t.Any()) })

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

  app.post("/forwardMessage", async ({ body, query, store }: any) => ({
    ok: true,
    result: await botOperationHandlers.forwardMessage(mergePostInput(body, query) as any, ctxFromStore(store)),
  }), { detail: jsonBodyDoc(TForwardMessageInput), response: TApiEnvelope(t.Object({ message: TBotMessage })) })

  app.post("/pinMessage", async ({ body, query, store }: any) => ({
    ok: true,
    result: await botOperationHandlers.pinMessage(mergePostInput(body, query) as any, ctxFromStore(store)),
  }), { detail: jsonBodyDoc(TPinMessageInput), response: TApiEnvelope(t.Object({})) })

  app.post("/unpinMessage", async ({ body, query, store }: any) => ({
    ok: true,
    result: await botOperationHandlers.unpinMessage(mergePostInput(body, query) as any, ctxFromStore(store)),
  }), { detail: jsonBodyDoc(TPinMessageInput), response: TApiEnvelope(t.Object({})) })

  app.get("/getChatParticipant", async ({ query, store }: any) => ({
    ok: true,
    result: await botOperationHandlers.getChatParticipant(query as any, ctxFromStore(store)),
  }), { query: TGetChatParticipantInput, response: TApiEnvelope(t.Object({ participant: TBotChatParticipant })) })

  app.get("/getChatParticipantCount", async ({ query, store }: any) => ({
    ok: true,
    result: await botOperationHandlers.getChatParticipantCount(query as any, ctxFromStore(store)),
  }), { query: TGetChatParticipantCountInput, response: TApiEnvelope(t.Object({ count: t.Number() })) })

  app.post("/setThreadTitle", async ({ body, query, store }: any) => ({
    ok: true,
    result: await botOperationHandlers.setThreadTitle(mergePostInput(body, query) as any, ctxFromStore(store)),
  }), { detail: jsonBodyDoc(TSetThreadTitleInput), response: TApiEnvelope(t.Object({})) })

  app.post("/uploadFile", async ({ body, store }: any) => ({
    ok: true,
    result: await botOperationHandlers.uploadFile({
      ...body,
      isAnimated: body.is_animated,
      hasAudio: body.has_audio,
      waveform: body.waveform_base64,
    }, ctxFromStore(store)),
  }), {
    type: "multipart/form-data",
    body: TBotUploadFileInput,
    response: TApiEnvelope(t.Object({ file: TBotFile })),
  })

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
