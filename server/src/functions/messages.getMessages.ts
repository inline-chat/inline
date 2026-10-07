import type { InputPeer, Message } from "@inline-chat/protocol/core"
import { MessageModel, type DbFullMessage } from "@in/server/db/models/messages"
import type { FunctionContext } from "@in/server/functions/_types"
import { getMessageThreadProjectionsMap } from "@in/server/modules/subthreads"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"

import { MAX_HISTORY_ID, withHistorySnapshot } from "@in/server/modules/message/historySnapshot"

type Input = {
  peerId: InputPeer
  messageIds: bigint[]
}

type Output = {
  messages: Message[]
  seq: bigint
}

export const getMessages = async (input: Input, context: FunctionContext): Promise<Output> => {
  validateMessageIds(input.messageIds)

  return withHistorySnapshot(input.peerId, context.currentUserId, async (tx, chat) => {
    if (input.messageIds.length === 0) {
      return { messages: [], seq: BigInt(chat.updateSeq ?? 0) }
    }

    const uniqueIds = uniqueMessageIds(input.messageIds)
    const fullMessages = await MessageModel.getMessagesByIds(chat.id, uniqueIds, { tx })
    const orderedMessages = orderMessagesByRequestedIds(uniqueIds, fullMessages)
    const threadProjections = await getMessageThreadProjectionsMap({
      parentChatId: chat.id,
      parentMessageIds: orderedMessages.map((message) => message.messageId),
      userId: context.currentUserId,
      tx,
    })

    const canonicalPeer = Encoders.peerFromChat(chat, { currentUserId: context.currentUserId })

    return {
      seq: BigInt(chat.updateSeq ?? 0),
      messages: orderedMessages.map((message) => {
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
  })
}

function validateMessageIds(messageIds: bigint[]): void {
  for (const messageId of messageIds) {
    if (messageId <= 0n || messageId > MAX_HISTORY_ID) {
      throw RealtimeRpcError.MessageIdInvalid()
    }
  }
}

function uniqueMessageIds(messageIds: bigint[]): bigint[] {
  return Array.from(new Set(messageIds))
}

function orderMessagesByRequestedIds(requestedIds: bigint[], messages: DbFullMessage[]): DbFullMessage[] {
  const byMessageId = new Map<number, DbFullMessage>(messages.map((message) => [message.messageId, message]))
  const ordered: DbFullMessage[] = []

  for (const requestedId of requestedIds) {
    const message = byMessageId.get(Number(requestedId))
    if (message) {
      ordered.push(message)
    }
  }

  return ordered
}
