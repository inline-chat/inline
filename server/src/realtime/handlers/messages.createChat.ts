import { CreateChatInput, CreateChatResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Functions } from "@in/server/functions"
import { Method } from "@in/protocol/core"

export const method = Method.CREATE_CHAT

export const createChat = async (input: CreateChatInput, handlerContext: HandlerContext): Promise<CreateChatResult> => {
  const result = await Functions.messages.createChat(
    {
      title: input.title,
      spaceId: input.spaceId,
      emoji: input.emoji,
      description: input.description,
      isPublic: input.isPublic,
      participants: input.participants,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return result
}
