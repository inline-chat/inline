import { GetThreadReferencesInput, GetThreadReferencesResult, Method } from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import type { HandlerContext } from "@in/server/realtime/types"

export const method = Method.GET_THREAD_REFERENCES

export const getThreadReferences = async (
  input: GetThreadReferencesInput,
  handlerContext: HandlerContext,
): Promise<GetThreadReferencesResult> => {
  return Functions.messages.getThreadReferences(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })
}
