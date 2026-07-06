import { GetThreadSubthreadsInput, GetThreadSubthreadsResult, Method } from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import type { HandlerContext } from "@in/server/realtime/types"

export const method = Method.GET_THREAD_SUBTHREADS

export const getThreadSubthreads = async (
  input: GetThreadSubthreadsInput,
  handlerContext: HandlerContext,
): Promise<GetThreadSubthreadsResult> => {
  return Functions.messages.getThreadSubthreads(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })
}
