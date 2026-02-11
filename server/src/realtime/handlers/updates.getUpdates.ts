import type { GetUpdatesInput, GetUpdatesResult } from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

export const getUpdates = async (input: GetUpdatesInput, handlerContext: HandlerContext): Promise<GetUpdatesResult> => {
  if (!input.bucket || input.bucket.type.oneofKind === undefined) {
    throw RealtimeRpcError.BadRequest()
  }

  return Functions.updates.getUpdates(
    {
      bucket: input.bucket,
      startSeq: input.startSeq ?? 0n,
      seqEnd: input.seqEnd ?? 0n,
      totalLimit: input.totalLimit ?? 0,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )
}
