import type { InputPeer, Message } from "@in/protocol/core"
import { ModelError } from "@in/server/db/models/_errors"
import { MessageModel, type DbFullMessage } from "@in/server/db/models/messages"
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
  keywords: string[]
  limit?: number
}

type Output = {
  messages: Message[]
}

const log = new Log("functions.searchMessages")

const DEFAULT_LIMIT = 50

export const searchMessages = async (input: Input, context: FunctionContext): Promise<Output> => {
  const keywords = normalizeKeywords(input.keywords)
  if (keywords.length === 0) {
    throw RealtimeRpcError.BadRequest
  }

  const maxResults = normalizeLimit(input.limit)

  const chat = await getChatWithAccess(input.peerId, context.currentUserId)

  log.debug("searchMessages start", {
    chatId: chat.id,
    keywordCount: keywords.length,
    maxResults,
  })

  const messageIds = await MessageSearchModule.searchMessagesInChat({
    chatId: chat.id,
    keywords,
    maxResults,
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
          throw RealtimeRpcError.UserIdInvalid
        }

        const user = await UsersModel.getUserById(peerUserId)
        if (!user) {
          throw RealtimeRpcError.UserIdInvalid
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
        throw RealtimeRpcError.ChatIdInvalid
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

function normalizeKeywords(keywords: string[] | undefined): string[] {
  if (!keywords) {
    return []
  }

  const normalized = keywords
    .map((keyword) => keyword.trim().toLowerCase())
    .filter((keyword) => keyword.length > 0)

  return [...new Set(normalized)]
}

function normalizeLimit(limit: number | undefined): number {
  if (limit === undefined || limit === null) {
    return DEFAULT_LIMIT
  }

  if (!Number.isFinite(limit)) {
    throw RealtimeRpcError.BadRequest
  }

  const normalized = Math.floor(limit)

  if (normalized <= 0) {
    throw RealtimeRpcError.BadRequest
  }

  return normalized
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
