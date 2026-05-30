import type { DeleteBotInput, DeleteBotResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { deleteBot } from "@in/server/functions/bot.deleteBot"

export const deleteBotHandler = async (
  input: DeleteBotInput,
  handlerContext: HandlerContext,
): Promise<DeleteBotResult> => {
  const result = await deleteBot(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })

  return result
}
