import type { UpdateMemberAccessInput, UpdateMemberAccessResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Log } from "@in/server/utils/log"

const log = new Log("realtime.updateMemberAccessHandler")

export const updateMemberAccessHandler = async (
  input: UpdateMemberAccessInput,
  handlerContext: HandlerContext,
): Promise<UpdateMemberAccessResult> => {
  if (!input.spaceId) {
    throw RealtimeRpcError.BadRequest()
  }
  if (!input.userId) {
    throw RealtimeRpcError.UserIdInvalid()
  }

  try {
    return await Functions.spaces.updateMemberAccess(input, {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    })
  } catch (error) {
    log.error("updateMemberAccessHandler failed", error)
    if (error instanceof RealtimeRpcError) {
      throw error
    }
    throw RealtimeRpcError.InternalError()
  }
}

