import { getChats } from "@in/server/functions/messages.getChats"
import type { FunctionContext } from "@in/server/functions/_types"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Log } from "@in/server/utils/log"

const log = new Log("handlers.messages.getChats")

export const handleGetChats = async (input: {}, context: HandlerContext) => {
  try {
    const functionContext: FunctionContext = {
      currentUserId: context.userId,
      currentSessionId: context.sessionId,
    }
    return await getChats(input, functionContext)
  } catch (error) {
    log.error("Failed to get chats", { error })
    throw RealtimeRpcError.InternalError
  }
}
