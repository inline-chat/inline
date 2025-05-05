// TODO: Use generated protocol types when available
import type { GetSpaceMembersInput, GetSpaceMembersResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Functions } from "@in/server/functions"

export const getSpaceMembers = async (
  input: GetSpaceMembersInput,
  handlerContext: HandlerContext,
): Promise<GetSpaceMembersResult> => {
  if (!input.spaceId) {
    throw RealtimeRpcError.BadRequest
  }

  const result = await Functions.spaces.getSpaceMembers(
    {
      spaceId: input.spaceId,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return {
    members: result.members,
    users: result.users,
  }
}
