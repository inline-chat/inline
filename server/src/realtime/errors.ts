import { RpcError_Code } from "@inline-chat/protocol/core"
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
  public static UnsupportedRpcMethod(method: number): RealtimeRpcError {
    return RealtimeRpcError.create(
      RpcError_Code.BAD_REQUEST,
      `Unsupported RPC method: ${method}`,
      400,
      (): RealtimeRpcError => RealtimeRpcError.UnsupportedRpcMethod(method),
    )
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
  public static RateLimit() {
    return RealtimeRpcError.create(RpcError_Code.RATE_LIMIT, "Too many requests", 429, RealtimeRpcError.RateLimit)
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
  public static UsernameInvalid() {
    return RealtimeRpcError.create(
      RpcError_Code.USERNAME_INVALID,
      "Username is invalid",
      400,
      RealtimeRpcError.UsernameInvalid,
    )
  }
  public static UsernameTaken() {
    return RealtimeRpcError.create(
      RpcError_Code.USERNAME_TAKEN,
      "Username is taken",
      400,
      RealtimeRpcError.UsernameTaken,
    )
  }
  public static FirstNameInvalid() {
    return RealtimeRpcError.create(
      RpcError_Code.FIRST_NAME_INVALID,
      "First name is invalid",
      400,
      RealtimeRpcError.FirstNameInvalid,
    )
  }
  public static UrlPreviewUnavailable() {
    return RealtimeRpcError.create(
      RpcError_Code.URL_PREVIEW_UNAVAILABLE,
      "URL preview unavailable",
      400,
      RealtimeRpcError.UrlPreviewUnavailable,
    )
  }
  public static AgentSessionMessageImmutable() {
    return RealtimeRpcError.create(
      RpcError_Code.AGENT_SESSION_MESSAGE_IMMUTABLE,
      "Imported agent session history cannot be edited or deleted yet",
      409,
      RealtimeRpcError.AgentSessionMessageImmutable,
    )
  }
  public static SpaceInviteInvalid() {
    return RealtimeRpcError.create(
      RpcError_Code.SPACE_INVITE_INVALID,
      "Space invite is invalid or unavailable",
      404,
      RealtimeRpcError.SpaceInviteInvalid,
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
      case "FLOOD":
        return RealtimeRpcError.RateLimit()
      case "INTERNAL":
        return RealtimeRpcError.InternalError()
      case "PEER_INVALID":
        return RealtimeRpcError.PeerIdInvalid()
      case "MSG_ID_INVALID":
        return RealtimeRpcError.MessageIdInvalid()
      case "EMAIL_INVALID":
        return new RealtimeRpcError(RpcError_Code.EMAIL_INVALID, error.description ?? error.message, error.code)
      case "PHONE_INVALID":
        return new RealtimeRpcError(RpcError_Code.PHONE_NUMBER_INVALID, error.description ?? error.message, error.code)
      case "EMAIL_CODE_INVALID":
      case "EMAIL_CODE_EMPTY":
      case "SMS_CODE_INVALID":
      case "SMS_CODE_EMPTY":
      case "INVITE_CODE_REQUIRED":
      case "INVITE_CODE_INVALID":
      case "INVITE_CODE_NOT_FOUND":
      case "INVITE_CODE_TAKEN":
      case "SIGNUPS_DISABLED":
        // These login failures have public copy but no dedicated RPC enum case.
        return new RealtimeRpcError(RpcError_Code.BAD_REQUEST, error.description ?? error.message, error.code)
      // TODO
      default:
        return RealtimeRpcError.InternalError()
    }
  }
}
