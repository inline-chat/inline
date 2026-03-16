import { CreateSubthreadInput, CreateSubthreadResult, Method } from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import type { HandlerContext } from "@in/server/realtime/types"

export const method = Method.CREATE_SUBTHREAD

export const createSubthread = async (
  input: CreateSubthreadInput,
  handlerContext: HandlerContext,
): Promise<CreateSubthreadResult> => {
  return Functions.messages.createSubthread(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })
}
