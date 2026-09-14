import { ConnectionError_Reason } from "@inline-chat/protocol/core"

export type InlineSdkAuthenticationErrorCode =
  | "UNAUTHORIZED"
  | "INVALID_AUTH"
  | "SESSION_REVOKED"

export class InlineSdkAuthenticationError extends Error {
  readonly terminal = true as const

  constructor(
    readonly code: InlineSdkAuthenticationErrorCode,
    readonly reason: ConnectionError_Reason,
  ) {
    super(`Inline authentication failed: ${code}`)
    this.name = "InlineSdkAuthenticationError"
  }
}

export function authenticationErrorFromConnectionReason(
  reason: ConnectionError_Reason,
): InlineSdkAuthenticationError | null {
  switch (reason) {
    case ConnectionError_Reason.UNAUTHORIZED:
      return new InlineSdkAuthenticationError("UNAUTHORIZED", reason)
    case ConnectionError_Reason.INVALID_AUTH:
      return new InlineSdkAuthenticationError("INVALID_AUTH", reason)
    case ConnectionError_Reason.SESSION_REVOKED:
      return new InlineSdkAuthenticationError("SESSION_REVOKED", reason)
    default:
      return null
  }
}
