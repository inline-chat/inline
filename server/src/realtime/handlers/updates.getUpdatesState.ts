import { GetUpdatesStateInput, GetUpdatesStateResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import { Method } from "@in/protocol/core"

export const method = Method.CREATE_CHAT

export const getUpdatesState = async (
  input: GetUpdatesStateInput,
  handlerContext: HandlerContext,
): Promise<GetUpdatesStateResult> => {
  const { date } = await Functions.updates.getUpdatesState(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })

  return {
    date,
  }
}
