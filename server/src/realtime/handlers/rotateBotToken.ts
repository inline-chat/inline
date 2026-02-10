import type { RotateBotTokenInput, RotateBotTokenResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { rotateBotToken } from "@in/server/functions/bot.rotateToken"

export const rotateBotTokenHandler = async (
  input: RotateBotTokenInput,
  handlerContext: HandlerContext,
): Promise<RotateBotTokenResult> => {
  const result = await rotateBotToken(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })

  return result
}

