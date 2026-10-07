import { SearchMessagesFilter, type InputPeer, type Message } from "@inline-chat/protocol/core"
import { MessageModel, type DbFullMessage, type MessageMediaFilter } from "@in/server/db/models/messages"
import type { FunctionContext } from "@in/server/functions/_types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { Log } from "@in/server/utils/log"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { getMessageThreadProjectionsMap } from "@in/server/modules/subthreads"
import { MessageSearchModule } from "@in/server/modules/search/messagesSearch"

import { historyLimit, validateHistoryId, withHistorySnapshot } from "@in/server/modules/message/historySnapshot"

type Input = {
  peerId: InputPeer
  queries: string[]
  limit?: number
  offsetId?: bigint
  filter?: SearchMessagesFilter
}

type Output = {
  messages: Message[]
  seq: bigint
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

  const maxResults = historyLimit(input.limit, DEFAULT_LIMIT)
  validateHistoryId(input.offsetId)

  return withHistorySnapshot(input.peerId, context.currentUserId, async (tx, chat) => {
    const canonicalPeer = Encoders.peerFromChat(chat, { currentUserId: context.currentUserId })
    log.debug("searchMessages start", {
      chatId: chat.id,
      queryCount: keywordGroups.length,
      keywordCount: keywordGroups.reduce((total, keywords) => total + keywords.length, 0),
      maxResults,
      offsetId: input.offsetId ? Number(input.offsetId) : undefined,
      mediaFilter,
    })

    if (!hasQueries && mediaFilter && mediaFilter !== "links") {
      const fullMessages = await MessageModel.getMessagesWithMediaFilter({
        chatId: chat.id,
        offsetId: input.offsetId,
        limit: maxResults,
        filter: mediaFilter,
        tx,
      })
      const threadProjections = await getMessageThreadProjectionsMap({
        parentChatId: chat.id,
        parentMessageIds: fullMessages.map((message) => message.messageId),
        userId: context.currentUserId,
        tx,
      })

      return {
        seq: BigInt(chat.updateSeq ?? 0),
        messages: fullMessages.map((message) => {
          const threadProjection = threadProjections.get(message.messageId)
          return Encoders.fullMessage({
            message,
            encodingForUserId: context.currentUserId,
            encodingForPeer: { inputPeer: canonicalPeer },
            replies: threadProjection?.replies,
            subthread: threadProjection?.subthread,
          })
        }),
      }
    }

    const messageIds = await MessageSearchModule.searchMessagesInChat({
      chatId: chat.id,
      keywordGroups,
      maxResults,
      beforeMessageId: input.offsetId ? Number(input.offsetId) : undefined,
      mediaFilter,
      tx,
    })

    if (messageIds.length === 0) {
      return { messages: [], seq: BigInt(chat.updateSeq ?? 0) }
    }

    const fullMessages = await MessageModel.getMessagesByIds(chat.id, messageIds, { tx })
    const orderedMessages = orderMessagesById(messageIds, fullMessages)
    if (orderedMessages.length !== messageIds.length) throw RealtimeRpcError.InternalError()
    const threadProjections = await getMessageThreadProjectionsMap({
      parentChatId: chat.id,
      parentMessageIds: orderedMessages.map((message) => message.messageId),
      userId: context.currentUserId,
      tx,
    })

    const encodedMessages = orderedMessages.map((message) => {
      const threadProjection = threadProjections.get(message.messageId)
      return Encoders.fullMessage({
        message,
        encodingForUserId: context.currentUserId,
        encodingForPeer: { inputPeer: canonicalPeer },
        replies: threadProjection?.replies,
        subthread: threadProjection?.subthread,
      })
    })

    return {
      seq: BigInt(chat.updateSeq ?? 0),
      messages: encodedMessages,
    }
  })
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
    case SearchMessagesFilter.FILTER_VOICE_MEMOS:
      return "voice_memos"
    case SearchMessagesFilter.FILTER_UNSPECIFIED:
    case undefined:
      return undefined
    default:
      throw RealtimeRpcError.BadRequest()
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
