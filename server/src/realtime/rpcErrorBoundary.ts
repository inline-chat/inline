import { ModelError } from "@in/server/db/models/_errors"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { InlineError } from "@in/server/types/errors"

/**
 * Converts failures that escaped a realtime handler into their public RPC
 * contract. Expected invalid-resource failures stay client errors and do not
 * enter the server-error reporting path.
 */
export const toRealtimeRpcError = (error: unknown): RealtimeRpcError => {
  if (error instanceof RealtimeRpcError) return error
  if (error instanceof InlineError) {
    return RealtimeRpcError.fromInlineError(error)
  }
  if (error instanceof ModelError) {
    switch (error.code) {
      case ModelError.Codes.CHAT_INVALID:
        return RealtimeRpcError.PeerIdInvalid()
      case ModelError.Codes.MESSAGE_INVALID:
        return RealtimeRpcError.MessageIdInvalid()
    }
  }
  return RealtimeRpcError.InternalError()
}
