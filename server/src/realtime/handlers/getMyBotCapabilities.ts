import { getMyBotCapabilities } from "@in/server/functions/bot.getMyCapabilities"
import type { HandlerContext } from "@in/server/realtime/types"
import type { GetMyBotCapabilitiesResult } from "@inline-chat/protocol/core"

export const getMyBotCapabilitiesHandler = (context: HandlerContext): Promise<GetMyBotCapabilitiesResult> =>
  getMyBotCapabilities({ currentSessionId: context.sessionId, currentUserId: context.userId })
