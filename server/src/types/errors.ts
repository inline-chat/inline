export enum ErrorCodes {
  INAVLID_ARGS = 400,
  UNAUTHORIZED = 403,
  SERVER_ERROR = 500,
  INVALID_INPUT = 400,
}

export class InlineError extends Error {
  constructor(public code: ErrorCodes, message?: string) {
    super(message ?? "An error occurred")
  }
}
