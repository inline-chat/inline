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
  PHOTO_INVALID_DIMENSIONS: ["PHOTO_INVALID_DIMENSIONS", 400, "The photo dimensions are invalid"],
  PHOTO_INVALID_EXTENSION: ["PHOTO_INVALID_EXTENSION", 400, "The photo extension is not supported or invalid"],
  PHOTO_INVALID_TYPE: ["PHOTO_INVALID_TYPE", 400, "The photo type is not supported or invalid"],
  FILE_TOO_LARGE: ["FILE_TOO_LARGE", 400, "The file exceeds the maximum size of 40MB"],
  FILE_UNIQUE_ID_INVALID: ["FILE_UNIQUE_ID_INVALID", 400, "The file unique id does not exist or is invalid"],
  FILE_NOT_FOUND: ["FILE_NOT_FOUND", 400, "The file does not exist or you don't have access to it"],
  MSG_ID_INVALID: ["MSG_ID_INVALID", 400, "The message id is invalid"],
  CHAT_ID_INVALID: ["CHAT_ID_INVALID", 400, "The chat id is invalid"],
  VIDEO_INVALID_EXTENSION: ["VIDEO_INVALID_EXTENSION", 400, "The video extension is not supported or invalid"],
  VIDEO_INVALID_DIMENSIONS: ["VIDEO_INVALID_DIMENSIONS", 400, "The video dimensions are invalid"],
  VIDEO_INVALID_TYPE: ["VIDEO_INVALID_TYPE", 400, "The video type is not supported or invalid"],
  DOCUMENT_INVALID_EXTENSION: ["DOCUMENT_INVALID_EXTENSION", 400, "The document extension is not supported or invalid"],

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

    // Maintain proper stack trace
    Error.captureStackTrace(this, InlineError)

    // Set the name to match the class name
    this.name = "InlineError"
  }

  public static ApiError = ApiError

  public asApiResponse() {
    let error = ApiError[this.type]
    return new Response(
      JSON.stringify({
        ok: false,
        error: error[0],
        errorCode: error[1],
        description: this.description,
      }),
      {
        headers: {
          "Content-Type": "application/json",
        },
        status: error[1],
      },
    )
  }
}

/** @deprecated */
export enum ErrorCodes {
  INAVLID_ARGS = 400,
  UNAUTHORIZED = 403,
  SERVER_ERROR = 500,
  INVALID_INPUT = 400,
}
