import type { GetPeerBotCommandsInput, GetPeerBotCommandsResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { getPeerBotCommands } from "@in/server/functions/bot.getPeerCommands"

export const getPeerBotCommandsHandler = async (
  input: GetPeerBotCommandsInput,
  handlerContext: HandlerContext,
): Promise<GetPeerBotCommandsResult> => {
  return getPeerBotCommands(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })
}
