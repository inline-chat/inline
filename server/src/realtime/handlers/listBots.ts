import type { ListBotsInput, ListBotsResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { listBots } from "@in/server/functions/bot.listBots"

export const listBotsHandler = async (
  input: ListBotsInput,
  handlerContext: HandlerContext,
): Promise<ListBotsResult> => {
  const result = await listBots(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })

  return result
}
