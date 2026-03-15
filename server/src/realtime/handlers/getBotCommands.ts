import type { GetBotCommandsInput, GetBotCommandsResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { getBotCommands } from "@in/server/functions/bot.getCommands"

export const getBotCommandsHandler = async (
  input: GetBotCommandsInput,
  handlerContext: HandlerContext,
): Promise<GetBotCommandsResult> => {
  return getBotCommands(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })
}
