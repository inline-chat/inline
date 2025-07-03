import type { RemoveSpaceMemberInput, RemoveSpaceMemberResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Functions } from "@in/server/functions"

export const removeSpaceMember = async (
  input: RemoveSpaceMemberInput,
  handlerContext: HandlerContext,
): Promise<RemoveSpaceMemberResult> => {
  if (!input.spaceId) {
    throw RealtimeRpcError.BadRequest
  }

  if (!input.userId) {
    throw RealtimeRpcError.BadRequest
  }

  const result = await Functions.spaces.removeSpaceMember(
    {
      spaceId: input.spaceId,
      userId: input.userId,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return {
    updates: result.updates,
  }
}
