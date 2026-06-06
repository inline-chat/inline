import type { ClearBotAvatarInput, ClearBotAvatarResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { clearBotAvatar } from "@in/server/functions/bot.clearAvatar"

export const clearBotAvatarHandler = async (
  input: ClearBotAvatarInput,
  handlerContext: HandlerContext,
): Promise<ClearBotAvatarResult> =>
  clearBotAvatar(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })
