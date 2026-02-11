import { Elysia, t } from "elysia"
import { InlineError } from "@in/server/types/errors"
import { authenticateBotHeader, authenticateBotPathOrHeader, type BotHandlerContext } from "./auth"
import { handleBotError } from "./error"
import { TApiEnvelope, normalizeInputId } from "./helpers"
import {
  TBotChat,
  TBotMessage,
  TBotUser,
  TDeleteMessageInput,
  TEditMessageTextInput,
  TGetChatHistoryInput,
  TGetChatInput,
  TSendMessageInput,
  TSendReactionInput,
} from "./types"
import { handler as getMeHandler } from "@in/server/methods/getMe"
import { sendMessage as sendMessageFn } from "@in/server/functions/messages.sendMessage"
import type { InputPeer, Peer } from "@in/protocol/core"
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
import type {
  BotChat,
  BotChatLastMessage,
  BotMessage,
  BotMessageLite,
  BotPeer,
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

const toBotPeer = (peer: any): BotPeer => {
  if (!peer) return {}

  // Legacy API peer shape: { userId } / { threadId }
  if (typeof peer === "object" && peer !== null) {
    if ("userId" in peer && typeof (peer as any).userId === "number") {
      return { user_id: (peer as any).userId }
    }
    if ("threadId" in peer && typeof (peer as any).threadId === "number") {
      return { thread_id: (peer as any).threadId }
    }
  }

  // Protocol peer shape: { type: { oneofKind: "user" | "chat" } }
  const type = (peer as Peer).type
  if (!type) return {}

  if (type.oneofKind === "user") return { user_id: Number(type.user.userId) }
  if (type.oneofKind === "chat") return { thread_id: Number(type.chat.chatId) }

  return {}
}

function minimalUnknownUser(id: number): BotUser {
  return { id, is_bot: false }
}

const makeInputPeer = (peerUserId: number | undefined, peerThreadId: number | undefined): InputPeer => {
  if ((peerUserId ? 1 : 0) + (peerThreadId ? 1 : 0) !== 1) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  if (peerUserId) {
    return {
      type: {
        oneofKind: "user",
        user: { userId: BigInt(peerUserId) },
      },
    }
  }

  return {
    type: {
      oneofKind: "chat",
      chat: { chatId: BigInt(peerThreadId!) },
    },
  }
}

const parseBotTarget = (input: BotTargetInput): { userId?: number; chatId?: number } => {
  const userId = normalizeInputId(input.user_id)
  const userIdAlias = normalizeInputId(input.peer_user_id)
  if (userId !== undefined && userIdAlias !== undefined && userId !== userIdAlias) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const chatId = normalizeInputId(input.chat_id)
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
        const input = mergePostInput(body, query)
        const text = input["text"]
        if (typeof text !== "string") {
          throw new InlineError(InlineError.ApiError.BAD_REQUEST)
        }

        const replyToMessageId = normalizeInputId(input["reply_to_message_id"] as any)
        const entities = parseBotEntities(parseMaybeJsonValue(input["entities"]))
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
    },
    {
      body: t.Optional(TSendMessageInput),
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
      query: TGetChatInput,
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
      query: TGetChatHistoryInput,
      response: TApiEnvelope(t.Object({ messages: t.Array(TBotMessage) })),
    },
  )

  app.post(
    "/editMessageText",
    async ({ body, query, store }: any) => {
      try {
        const input = mergePostInput(body, query)
        const peerId = await makeInputPeerFromBotTarget(input, store.currentUserId)
        const entities = parseBotEntities(parseMaybeJsonValue(input["entities"]))

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
          { messageId: BigInt(messageId), peer: peerId, text, entities },
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
      body: t.Optional(TEditMessageTextInput),
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
      body: t.Optional(TDeleteMessageInput),
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
      body: t.Optional(TSendReactionInput),
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

export const botApi = new Elysia({ name: "bot-api" })
  // Recommended: Authorization header auth
  .group("/bot", (app) => app.use(botMethods(authenticateBotHeader) as any))
  // Token in path: /bot<token>/<method>
  .group("/bot:token", (app) => app.use(botMethods(authenticateBotPathOrHeader) as any))
  .use(handleBotError)
