import { GetUpdatesStateInput, GetUpdatesStateResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import { Method } from "@inline-chat/protocol/core"

export const method = Method.GET_UPDATES_STATE

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
