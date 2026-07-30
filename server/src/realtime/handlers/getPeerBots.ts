import { getPeerBots } from "@in/server/functions/bot.getPeerBots"
import type { HandlerContext } from "@in/server/realtime/types"
import type { GetPeerBotsInput, GetPeerBotsResult } from "@inline-chat/protocol/core"

export const getPeerBotsHandler = (input: GetPeerBotsInput, context: HandlerContext): Promise<GetPeerBotsResult> =>
  getPeerBots(input, { currentSessionId: context.sessionId, currentUserId: context.userId })
