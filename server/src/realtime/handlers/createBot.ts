import type { CreateBotInput, CreateBotResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { createBot } from "@in/server/functions/createBot"

export const createBotHandler = async (
  input: CreateBotInput,
  handlerContext: HandlerContext,
): Promise<CreateBotResult> => {
  const result = await createBot(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })

  return result
}
