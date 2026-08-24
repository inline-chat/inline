import { Functions } from "@in/server/functions"
import type { HandlerContext } from "@in/server/realtime/types"
import type { GetSpaceInput, GetSpaceResult } from "@inline-chat/protocol/core"

export async function getSpace(input: GetSpaceInput, context: HandlerContext): Promise<GetSpaceResult> {
  return Functions.spaces.getSpace(input, {
    currentSessionId: context.sessionId,
    currentUserId: context.userId,
  })
}
