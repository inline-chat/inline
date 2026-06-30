import { CreateSubthreadInput, CreateSubthreadResult, Method } from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"

export const method = Method.CREATE_SUBTHREAD

export const createSubthread = async (
  input: CreateSubthreadInput,
  handlerContext: HandlerContext,
): Promise<CreateSubthreadResult> => {
  const participants = input.participants?.map((participant) => {
    if (participant.groupId != null || participant.userId == null) {
      throw RealtimeRpcError.BadRequest()
    }

    return { userId: participant.userId }
  })

  return Functions.messages.createSubthread({
    ...input,
    participants,
  }, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })
}
