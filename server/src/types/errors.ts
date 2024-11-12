// ref: https://core.telegram.org/api/errors
/**
 * All API Errors
 *
 * Format:
 * [error type, error code, human readable description (optional)]
 */
export const ApiError = {
  // 400 BAD_REQUEST
  BAD_REQUEST: ["BAD_REQUEST", 400, "Invalid arguments was provided"],
  PHONE_INVALID: ["PHONE_INVALID", 400, "The phone number is invalid"],
  EMAIL_INVALID: ["EMAIL_INVALID", 400, "The email is invalid"],
  PEER_INVALID: ["PEER_INVALID", 400, "The peer (chat or user) is invalid"],
  INVALID_RECIPIENT_TYPE: ["INVALID_RECIPIENT_TYPE", 400, "Invalid recipient type for this operation"],
  SPACE_INVALID: ["SPACE_INVALID", 400, "The space is invalid"],
  SPACE_CREATOR_REQUIRED: ["SPACE_CREATOR_REQUIRED", 400, "You must be the creator of space for this action"],
  SPACE_ADMIN_REQUIRED: ["SPACE_ADMIN_REQUIRED", 400, "You must be an admin of space for this action"],
  USER_INVALID: ["USER_INVALID", 400, "The user is invalid"],
  EMAIL_CODE_INVALID: ["EMAIL_CODE_INVALID", 400, "The email code is invalid"],
  EMAIL_CODE_EMPTY: ["EMAIL_CODE_EMPTY", 400, "The email code is empty"],
  SMS_CODE_EMPTY: ["SMS_CODE_EMPTY", 400, "The sms code is empty"],
  SMS_CODE_INVALID: ["SMS_CODE_INVALID", 400, "The sms code is invalid"],
  USERNAME_TAKEN: ["USERNAME_TAKEN", 400, "The username is already taken"],
  FIRST_NAME_INVALID: ["FIRST_NAME_INVALID", 400, "The first name is invalid"],
  LAST_NAME_INVALID: ["LAST_NAME_INVALID", 400, "The last name is invalid"],
  USERNAME_INVALID: ["USERNAME_INVALID", 400, "The username is invalid"],
  USER_NOT_PARTICIPANT: ["USER_NOT_PARTICIPANT", 400, "The user is not a participant of the space/chat"],

  // 404 NOT_FOUND
  METHOD_NOT_FOUND: ["METHOD_NOT_FOUND", 404, "Method not found"],

  // 401 UNAUTHORIZED
  UNAUTHORIZED: ["UNAUTHORIZED", 401, "Unauthorized"],
  USER_DEACTIVATED: ["USER_DEACTIVATED", 401, "The user has been deleted/deactivated"],
  SESSION_REVOKED: [
    "SESSION_REVOKED",
    401,
    "The authorization has been invalidated, because of the user terminating the session",
  ],
  SESSION_EXPIRED: ["SESSION_EXPIRED", 401, "The authorization has expired"],

  // 403 FORBIDDEN
  FORBIDDEN: ["FORBIDDEN", 403, "Forbidden"],

  // 500 SERVER_ERROR
  INTERNAL: ["INTERNAL", 500, "Internal server error happened"],

  // 429 FLOOD
  FLOOD: ["FLOOD", 420, "Too many requests. Please wait a bit before retrying."],
} as const

type ApiError = (typeof ApiError)[keyof typeof ApiError]
type ApiErrorCode = ApiError[1]
type ApiErrorType = ApiError[0]
type ApiErrorDescription = ApiError[2]

export class InlineError extends Error {
  public code: ApiErrorCode

  public type: ApiErrorType

  /** Human readable description of the error */
  public description: string | undefined

  constructor(error: ApiError) {
    super(error[2])
    this.type = error[0]
    this.code = error[1]
    this.description = error[2]
  }

  public static ApiError = ApiError
}

/** @deprecated */
export enum ErrorCodes {
  INAVLID_ARGS = 400,
  UNAUTHORIZED = 403,
  SERVER_ERROR = 500,
  INVALID_INPUT = 400,
}
