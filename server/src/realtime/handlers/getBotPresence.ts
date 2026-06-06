import type { GetBotPresenceInput, GetBotPresenceResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { getBotPresence } from "@in/server/functions/bot.getPresence"

export const getBotPresenceHandler = async (
  input: GetBotPresenceInput,
  handlerContext: HandlerContext,
): Promise<GetBotPresenceResult> =>
  getBotPresence(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })
