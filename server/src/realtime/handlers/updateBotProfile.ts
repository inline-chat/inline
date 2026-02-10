import type { UpdateBotProfileInput, UpdateBotProfileResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { updateBotProfile } from "@in/server/functions/bot.updateProfile"

export const updateBotProfileHandler = async (
  input: UpdateBotProfileInput,
  handlerContext: HandlerContext,
): Promise<UpdateBotProfileResult> => {
  const result = await updateBotProfile(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })

  return result
}

