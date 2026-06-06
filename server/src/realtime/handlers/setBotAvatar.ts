import type { SetBotAvatarInput, SetBotAvatarResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { setBotAvatar } from "@in/server/functions/bot.setAvatar"

export const setBotAvatarHandler = async (
  input: SetBotAvatarInput,
  handlerContext: HandlerContext,
): Promise<SetBotAvatarResult> =>
  setBotAvatar(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })
