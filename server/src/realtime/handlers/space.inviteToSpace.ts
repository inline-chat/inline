// TODO: Use generated protocol types when available
import type { InviteToSpaceInput, InviteToSpaceResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Functions } from "@in/server/functions"

export const inviteToSpace = async (
  input: InviteToSpaceInput,
  handlerContext: HandlerContext,
): Promise<InviteToSpaceResult> => {
  if (!input.spaceId) {
    throw RealtimeRpcError.BadRequest
  }

  const result = await Functions.spaces.inviteToSpace(
    {
      spaceId: input.spaceId,
      via: input.via,
      role: input.role,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return {
    member: result.member,
    user: result.user,
    dialog: result.dialog,
    chat: result.chat,
  }
}
