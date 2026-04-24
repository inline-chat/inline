import { Method, type RevokeSessionInput, type RevokeSessionResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { revokeSession } from "@in/server/modules/sessions/revokeSession"

export const method = Method.REVOKE_SESSION

export const revokeSessionHandler = async (
  input: RevokeSessionInput,
  handlerContext: HandlerContext,
): Promise<RevokeSessionResult> => {
  const sessionId = Number(input.sessionId)

  if (!Number.isSafeInteger(sessionId) || sessionId <= 0) {
    throw RealtimeRpcError.BadRequest()
  }

  if (sessionId === handlerContext.sessionId) {
    throw RealtimeRpcError.BadRequest()
  }

  const result = await revokeSession({
    actor: "user",
    actorUserId: handlerContext.userId,
    targetUserId: handlerContext.userId,
    sessionId,
  })

  if (!result.session) {
    throw RealtimeRpcError.BadRequest()
  }

  return {
    revoked: result.revoked,
    alreadyRevoked: result.alreadyRevoked,
  }
}
