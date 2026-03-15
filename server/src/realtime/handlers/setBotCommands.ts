import type { SetBotCommandsInput, SetBotCommandsResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { setBotCommands } from "@in/server/functions/bot.setCommands"

export const setBotCommandsHandler = async (
  input: SetBotCommandsInput,
  handlerContext: HandlerContext,
): Promise<SetBotCommandsResult> => {
  return setBotCommands(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })
}
