import { getSpaces } from "@in/server/functions/space.getSpaces"
import type { HandlerContext } from "@in/server/realtime/types"
import type { GetSpacesInput, GetSpacesResult } from "@inline-chat/protocol/core"

export async function handleGetSpaces(input: GetSpacesInput, context: HandlerContext): Promise<GetSpacesResult> {
  return getSpaces(input, { currentUserId: context.userId, currentSessionId: context.sessionId })
}
