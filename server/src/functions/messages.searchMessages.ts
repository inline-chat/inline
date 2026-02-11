import { SearchMessagesFilter, type InputPeer, type Message } from "@inline-chat/protocol/core"
import { ModelError } from "@in/server/db/models/_errors"
import { MessageModel, type DbFullMessage, type MessageMediaFilter } from "@in/server/db/models/messages"
import { ChatModel } from "@in/server/db/models/chats"
import { UsersModel } from "@in/server/db/models/users"
import type { FunctionContext } from "@in/server/functions/_types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { Log } from "@in/server/utils/log"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import type { DbChat } from "@in/server/db/schema"
import { MessageSearchModule } from "@in/server/modules/search/messagesSearch"

type Input = {
  peerId: InputPeer
  queries: string[]
  limit?: number
  offsetId?: bigint
  filter?: SearchMessagesFilter
}

type Output = {
  messages: Message[]
}

const log = new Log("functions.searchMessages")

const DEFAULT_LIMIT = 50

export const searchMessages = async (input: Input, context: FunctionContext): Promise<Output> => {
  const keywordGroups = normalizeQueries(input.queries)
  const mediaFilter = normalizeMediaFilter(input.filter)
  const hasQueries = keywordGroups.length > 0
  const hasFilter = mediaFilter !== undefined
  if (!hasQueries && !hasFilter) {
    throw RealtimeRpcError.BadRequest()
  }

  const maxResults = normalizeLimit(input.limit)

  const chat = await getChatWithAccess(input.peerId, context.currentUserId)

  log.debug("searchMessages start", {
    chatId: chat.id,
    queryCount: keywordGroups.length,
    keywordCount: keywordGroups.reduce((total, keywords) => total + keywords.length, 0),
    maxResults,
    offsetId: input.offsetId ? Number(input.offsetId) : undefined,
    mediaFilter,
  })

  if (!hasQueries && mediaFilter) {
    const fullMessages = await MessageModel.getMessagesWithMediaFilter({
      chatId: chat.id,
      offsetId: input.offsetId,
      limit: maxResults,
      filter: mediaFilter,
    })

    return {
      messages: fullMessages.map((message) =>
        Encoders.fullMessage({
          message,
          encodingForUserId: context.currentUserId,
          encodingForPeer: { inputPeer: input.peerId },
        }),
      ),
    }
  }

  const messageIds = await MessageSearchModule.searchMessagesInChat({
    chatId: chat.id,
    keywordGroups,
    maxResults,
    beforeMessageId: input.offsetId ? Number(input.offsetId) : undefined,
    mediaFilter,
  })

  if (messageIds.length === 0) {
    return { messages: [] }
  }

  const fullMessages = await MessageModel.getMessagesByIds(chat.id, messageIds)
  const orderedMessages = orderMessagesById(messageIds, fullMessages)

  const encodedMessages = orderedMessages.map((message) =>
    Encoders.fullMessage({
      message,
      encodingForUserId: context.currentUserId,
      encodingForPeer: { inputPeer: input.peerId },
    }),
  )

  return {
    messages: encodedMessages,
  }
}

async function getChatWithAccess(inputPeer: InputPeer, currentUserId: number): Promise<DbChat> {
  let chat: DbChat

  try {
    chat = await ChatModel.getChatFromInputPeer(inputPeer, { currentUserId })
  } catch (error) {
    if (error instanceof ModelError && error.code === ModelError.Codes.CHAT_INVALID) {
      if (inputPeer.type.oneofKind === "user") {
        const peerUserId = Number(inputPeer.type.user.userId)

        if (!peerUserId || peerUserId <= 0) {
          throw RealtimeRpcError.UserIdInvalid()
        }

        const user = await UsersModel.getUserById(peerUserId)
        if (!user) {
          throw RealtimeRpcError.UserIdInvalid()
        }

        log.info("Auto-creating private chat and dialogs", {
          currentUserId,
          peerUserId,
        })

        await ChatModel.createUserChatAndDialog({
          peerUserId,
          currentUserId,
        })

        await ChatModel.createUserChatAndDialog({
          peerUserId: currentUserId,
          currentUserId: peerUserId,
        })

        chat = await ChatModel.getChatFromInputPeer(inputPeer, { currentUserId })
      } else if (inputPeer.type.oneofKind === "chat") {
        throw RealtimeRpcError.ChatIdInvalid()
      } else {
        throw error
      }
    } else {
      throw error
    }
  }

  try {
    await AccessGuards.ensureChatAccess(chat, currentUserId)
  } catch (error) {
    log.error("searchMessages blocked: chat access denied", {
      chatId: chat.id,
      currentUserId,
      inputPeer,
      error,
    })
    throw error
  }

  return chat
}

function normalizeQueries(queries: string[] | undefined): string[][] {
  if (!queries) {
    return []
  }

  const normalized = queries
    .map((query) =>
      query
        .split(/\s+/)
        .map((keyword) => keyword.trim().toLowerCase())
        .filter((keyword) => keyword.length > 0),
    )
    .map((keywords) => [...new Set(keywords)])
    .filter((keywords) => keywords.length > 0)

  return normalized
}

function normalizeLimit(limit: number | undefined): number {
  if (limit === undefined || limit === null) {
    return DEFAULT_LIMIT
  }

  if (!Number.isFinite(limit)) {
    throw RealtimeRpcError.BadRequest()
  }

  const normalized = Math.floor(limit)

  if (normalized <= 0) {
    throw RealtimeRpcError.BadRequest()
  }

  return normalized
}

function normalizeMediaFilter(filter: SearchMessagesFilter | undefined): MessageMediaFilter | undefined {
  switch (filter) {
    case SearchMessagesFilter.FILTER_PHOTOS:
      return "photos"
    case SearchMessagesFilter.FILTER_VIDEOS:
      return "videos"
    case SearchMessagesFilter.FILTER_PHOTO_VIDEO:
      return "photo_video"
    case SearchMessagesFilter.FILTER_DOCUMENTS:
      return "documents"
    case SearchMessagesFilter.FILTER_LINKS:
      return "links"
    case SearchMessagesFilter.FILTER_UNSPECIFIED:
    case undefined:
      return undefined
  }
}

function orderMessagesById(messageIds: bigint[], messages: DbFullMessage[]): DbFullMessage[] {
  const messageMap = new Map<number, DbFullMessage>(messages.map((message) => [message.messageId, message]))

  const ordered: DbFullMessage[] = []
  for (const messageId of messageIds) {
    const message = messageMap.get(Number(messageId))
    if (message) {
      ordered.push(message)
    }
  }

  return ordered
}
