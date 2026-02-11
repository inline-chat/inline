import { RpcError as RpcErrorProtocol, RpcError_Code } from "@inline-chat/protocol/core"
import type { InlineError } from "@in/server/types/errors"

export class RealtimeRpcError extends Error {
  public readonly codeName: string

  constructor(public readonly code: RpcError_Code, message: string, public readonly codeNumber: number) {
    super(message)
    this.codeName = RpcError_Code[code] ?? "UNKNOWN"
    this.name = this.codeName
    if (Error.captureStackTrace) {
      Error.captureStackTrace(this, RealtimeRpcError)
    }
  }

  public static Code = RpcError_Code

  public static is(error: unknown, code?: RpcError_Code): error is RealtimeRpcError {
    if (!(error instanceof RealtimeRpcError)) return false
    return code === undefined ? true : error.code === code
  }

  private static create(
    code: RpcError_Code,
    message: string,
    codeNumber: number,
    stackStartFn: () => RealtimeRpcError,
  ): RealtimeRpcError {
    const error = new RealtimeRpcError(code, message, codeNumber)
    if (Error.captureStackTrace) {
      Error.captureStackTrace(error, stackStartFn)
    }
    return error
  }

  // Convenience Helpers (fresh instance for correct stack traces)
  public static BadRequest() {
    return RealtimeRpcError.create(RpcError_Code.BAD_REQUEST, "Bad request", 400, RealtimeRpcError.BadRequest)
  }
  public static Unauthenticated() {
    return RealtimeRpcError.create(
      RpcError_Code.UNAUTHENTICATED,
      "Unauthenticated",
      401,
      RealtimeRpcError.Unauthenticated,
    )
  }
  public static InternalError() {
    return RealtimeRpcError.create(
      RpcError_Code.INTERNAL_ERROR,
      "Internal server error",
      500,
      RealtimeRpcError.InternalError,
    )
  }
  public static PeerIdInvalid() {
    return RealtimeRpcError.create(
      RpcError_Code.PEER_ID_INVALID,
      "Peer ID is invalid",
      400,
      RealtimeRpcError.PeerIdInvalid,
    )
  }
  public static MessageIdInvalid() {
    return RealtimeRpcError.create(
      RpcError_Code.MESSAGE_ID_INVALID,
      "Message ID is invalid",
      400,
      RealtimeRpcError.MessageIdInvalid,
    )
  }
  public static UserIdInvalid() {
    return RealtimeRpcError.create(
      RpcError_Code.USER_ID_INVALID,
      "User ID is invalid",
      400,
      RealtimeRpcError.UserIdInvalid,
    )
  }
  public static SpaceIdInvalid() {
    return RealtimeRpcError.create(
      RpcError_Code.SPACE_ID_INVALID,
      "Space ID is invalid",
      400,
      RealtimeRpcError.SpaceIdInvalid,
    )
  }
  public static UserAlreadyMember() {
    return RealtimeRpcError.create(
      RpcError_Code.USER_ALREADY_MEMBER,
      "User is already a member",
      400,
      RealtimeRpcError.UserAlreadyMember,
    )
  }
  public static ChatIdInvalid() {
    return RealtimeRpcError.create(
      RpcError_Code.CHAT_ID_INVALID,
      "Chat ID is invalid",
      400,
      RealtimeRpcError.ChatIdInvalid,
    )
  }
  public static EmailInvalid() {
    return RealtimeRpcError.create(RpcError_Code.EMAIL_INVALID, "Email is invalid", 400, RealtimeRpcError.EmailInvalid)
  }
  public static PhoneNumberInvalid() {
    return RealtimeRpcError.create(
      RpcError_Code.PHONE_NUMBER_INVALID,
      "Phone number is invalid",
      400,
      RealtimeRpcError.PhoneNumberInvalid,
    )
  }
  public static SpaceAdminRequired() {
    return RealtimeRpcError.create(
      RpcError_Code.SPACE_ADMIN_REQUIRED,
      "Space admin required",
      400,
      RealtimeRpcError.SpaceAdminRequired,
    )
  }
  public static SpaceOwnerRequired() {
    return RealtimeRpcError.create(
      RpcError_Code.SPACE_OWNER_REQUIRED,
      "Space owner required",
      400,
      RealtimeRpcError.SpaceOwnerRequired,
    )
  }
  // Helper to bridge InlineError from old handlers to RpcError
  public static fromInlineError(error: InlineError): RealtimeRpcError {
    switch (error.type) {
      case "BAD_REQUEST":
        return RealtimeRpcError.BadRequest()
      case "UNAUTHORIZED":
        return RealtimeRpcError.Unauthenticated()
      case "INTERNAL":
        return RealtimeRpcError.InternalError()
      case "PEER_INVALID":
        return RealtimeRpcError.PeerIdInvalid()
      case "MSG_ID_INVALID":
        return RealtimeRpcError.MessageIdInvalid()
      // TODO
      default:
        return RealtimeRpcError.InternalError()
    }
  }
}
