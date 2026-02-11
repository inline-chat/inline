import type { RevealBotTokenInput, RevealBotTokenResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { revealBotToken } from "@in/server/functions/bot.revealToken"

export const revealBotTokenHandler = async (
  input: RevealBotTokenInput,
  handlerContext: HandlerContext,
): Promise<RevealBotTokenResult> => {
  const result = await revealBotToken(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })

  return result
}
