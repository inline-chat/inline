import type { CreateCliSessionInput, CreateCliSessionResult } from "@inline-chat/protocol/core"
import { createCliSession } from "@in/server/functions/user.createCliSession"
import type { HandlerContext } from "@in/server/realtime/types"

export async function createCliSessionHandler(
  input: CreateCliSessionInput,
  context: HandlerContext,
): Promise<CreateCliSessionResult> {
  return createCliSession(input, {
    currentUserId: context.userId,
    currentSessionId: context.sessionId,
  })
}
