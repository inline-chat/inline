import { RpcError as RpcErrorProtocol, RpcError_Code } from "@in/protocol/core"
import type { InlineError } from "@in/server/types/errors"

export class RealtimeRpcError extends Error {
  constructor(public readonly code: RpcError_Code, message: string) {
    super(message)
  }

  public static Code = RpcError_Code

  // Convenience Helpers
  public static BadRequest = new RealtimeRpcError(RpcError_Code.BAD_REQUEST, "Bad request")
  public static Unauthenticated = new RealtimeRpcError(RpcError_Code.UNAUTHENTICATED, "Unauthenticated")
  public static InternalError = new RealtimeRpcError(RpcError_Code.INTERNAL_ERROR, "Internal server error")
  public static PeerIdInvalid = new RealtimeRpcError(RpcError_Code.PEER_ID_INVALID, "Peer ID is invalid")
  public static MessageIdInvalid = new RealtimeRpcError(RpcError_Code.MESSAGE_ID_INVALID, "Message ID is invalid")

  // Helper to bridge InlineError from old handlers to RpcError
  public static fromInlineError(error: InlineError): RealtimeRpcError {
    switch (error.type) {
      case "BAD_REQUEST":
        return RealtimeRpcError.BadRequest
      case "UNAUTHORIZED":
        return RealtimeRpcError.Unauthenticated
      case "INTERNAL":
        return RealtimeRpcError.InternalError
      case "PEER_INVALID":
        return RealtimeRpcError.PeerIdInvalid
      case "MSG_ID_INVALID":
        return RealtimeRpcError.MessageIdInvalid
      // TODO
      default:
        return RealtimeRpcError.InternalError
    }
  }
}
