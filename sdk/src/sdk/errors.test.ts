import { describe, expect, it } from "vitest"
import { ConnectionError_Reason } from "@inline-chat/protocol/core"
import {
  authenticationErrorFromConnectionReason,
  InlineSdkAuthenticationError,
} from "./errors.js"

describe("InlineSdkAuthenticationError", () => {
  it.each([
    [ConnectionError_Reason.UNAUTHORIZED, "UNAUTHORIZED"],
    [ConnectionError_Reason.INVALID_AUTH, "INVALID_AUTH"],
    [ConnectionError_Reason.SESSION_REVOKED, "SESSION_REVOKED"],
  ] as const)("classifies terminal reason %s as %s", (reason, code) => {
    const error = authenticationErrorFromConnectionReason(reason)

    expect(error).toBeInstanceOf(InlineSdkAuthenticationError)
    expect(error).toMatchObject({ code, reason, terminal: true })
  })

  it("leaves unspecified and future reasons retryable", () => {
    expect(
      authenticationErrorFromConnectionReason(
        ConnectionError_Reason.REASON_UNSPECIFIED,
      ),
    ).toBeNull()
    expect(authenticationErrorFromConnectionReason(99)).toBeNull()
  })
})
