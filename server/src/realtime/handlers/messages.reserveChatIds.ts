import { ReserveChatIdsInput, ReserveChatIdsResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import { Method } from "@inline-chat/protocol/core"

export const method = Method.RESERVE_CHAT_IDS

export const reserveChatIds = async (
  input: ReserveChatIdsInput,
  handlerContext: HandlerContext,
): Promise<ReserveChatIdsResult> => {
  return Functions.messages.reserveChatIds(
    {
      count: input.count,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )
}
