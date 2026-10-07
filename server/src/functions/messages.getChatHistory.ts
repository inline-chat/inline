import { getChatAcknowledgements } from "@in/server/db/models/acknowledgements"
import type { InputPeer, Message, ChatAcknowledgements } from "@inline-chat/protocol/core"
import { MessageModel } from "@in/server/db/models/messages"
import type { FunctionContext } from "@in/server/functions/_types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { getMessageThreadProjectionsMap } from "@in/server/modules/subthreads"

import {
  historyLimit,
  validateHistoryId,
  withHistorySnapshot,
  MAX_HISTORY_LIMIT,
} from "@in/server/modules/message/historySnapshot"

type Input = {
  peerId: InputPeer
  offsetId?: bigint
  limit?: number
  mode?: "latest" | "older" | "newer" | "around"
  beforeId?: bigint
  afterId?: bigint
  anchorId?: bigint
  beforeLimit?: number
  afterLimit?: number
  includeAnchor?: boolean
}

type Output = {
  messages: Message[]
  acknowledgements: ChatAcknowledgements
  seq: bigint
}

export const getChatHistory = async (input: Input, context: FunctionContext): Promise<Output> => {
  // input data
  const inputPeer = input.peerId

  const mode = input.mode ?? (input.offsetId !== undefined ? "older" : "latest")

  if (mode === "older" && input.beforeId === undefined && input.offsetId === undefined) {
    throw RealtimeRpcError.BadRequest()
  }

  if (mode === "newer" && input.afterId === undefined) {
    throw RealtimeRpcError.BadRequest()
  }

  if (mode === "around" && input.anchorId === undefined) {
    throw RealtimeRpcError.BadRequest()
  }

  for (const id of [input.offsetId, input.beforeId, input.afterId, input.anchorId]) validateHistoryId(id)
  const limit = historyLimit(input.limit, 60)
  if (input.offsetId !== undefined && input.beforeId !== undefined && input.offsetId !== input.beforeId)
    throw RealtimeRpcError.BadRequest()
  if (
    mode === "latest" &&
    [input.offsetId, input.beforeId, input.afterId, input.anchorId].some((id) => id !== undefined)
  )
    throw RealtimeRpcError.BadRequest()
  if (mode === "older" && (input.afterId !== undefined || input.anchorId !== undefined))
    throw RealtimeRpcError.BadRequest()
  if (
    mode === "newer" &&
    (input.offsetId !== undefined || input.beforeId !== undefined || input.anchorId !== undefined)
  )
    throw RealtimeRpcError.BadRequest()
  if (
    mode === "around" &&
    (input.offsetId !== undefined || input.beforeId !== undefined || input.afterId !== undefined)
  )
    throw RealtimeRpcError.BadRequest()
  if (
    mode !== "around" &&
    (input.beforeLimit !== undefined || input.afterLimit !== undefined || input.includeAnchor !== undefined)
  )
    throw RealtimeRpcError.BadRequest()
  let beforeLimit: number | undefined
  let afterLimit: number | undefined
  if (mode === "around") {
    const maximumBefore = historyLimit(input.beforeLimit, Math.floor(limit / 2), true)
    const maximumAfter = historyLimit(input.afterLimit, limit - Math.floor(limit / 2), true)
    // An unspecified after side fills the missing anchor's slot. Leave the
    // default unresolved until the anchor is read in the same snapshot.
    const reservedAnchor = input.includeAnchor !== false && input.afterLimit !== undefined ? 1 : 0
    if (maximumBefore + maximumAfter + reservedAnchor > MAX_HISTORY_LIMIT) throw RealtimeRpcError.BadRequest()
    beforeLimit = input.beforeLimit === undefined ? undefined : maximumBefore
    afterLimit = input.afterLimit === undefined ? undefined : maximumAfter
  }

  // get messages
  return withHistorySnapshot(inputPeer, context.currentUserId, async (tx, chat) => {
    const canonicalPeer = Encoders.peerFromChat(chat, { currentUserId: context.currentUserId })
    const messages = await MessageModel.getMessages(inputPeer, {
      tx,
      chatId: chat.id,
      offsetId: input.offsetId,
      limit,
      mode,
      beforeId: input.beforeId,
      afterId: input.afterId,
      anchorId: input.anchorId,
      beforeLimit,
      afterLimit,
      includeAnchor: input.includeAnchor,
      currentUserId: context.currentUserId,
    })

    const threadProjections = await getMessageThreadProjectionsMap({
      parentChatId: chat.id,
      parentMessageIds: messages.map((message) => message.messageId),
      userId: context.currentUserId,
      tx,
    })

    // encode messages
    const encodedMessages = messages.map((message) => {
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
      acknowledgements: { cursors: (await getChatAcknowledgements([chat.id], { tx })).get(chat.id) ?? [] },
    }
  })
}
