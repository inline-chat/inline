import { describe, expect, it } from "bun:test"
import { ModelError } from "@in/server/db/models/_errors"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { toRealtimeRpcError } from "@in/server/realtime/rpcErrorBoundary"
import { InlineError } from "@in/server/types/errors"

describe("toRealtimeRpcError", () => {
  it("keeps expected invalid-resource failures out of the 5xx path", () => {
    const chat = toRealtimeRpcError(ModelError.ChatInvalid)
    const message = toRealtimeRpcError(ModelError.MessageInvalid)

    expect(chat.code).toBe(RealtimeRpcError.Code.PEER_ID_INVALID)
    expect(chat.codeNumber).toBe(400)
    expect(message.code).toBe(RealtimeRpcError.Code.MESSAGE_ID_INVALID)
    expect(message.codeNumber).toBe(400)
  })

  it("keeps unknown and internal model failures on the 5xx path", () => {
    const unexpected = toRealtimeRpcError(new Error("private server failure"))
    expect(unexpected.codeNumber).toBe(500)
    expect(unexpected.message).toBe("Internal server error")
    expect(toRealtimeRpcError(ModelError.Failed).codeNumber).toBe(500)
  })

  it("preserves public login validation messages instead of replacing them with a 500", () => {
    for (const type of [
      "EMAIL_CODE_INVALID",
      "EMAIL_CODE_EMPTY",
      "SMS_CODE_INVALID",
      "SMS_CODE_EMPTY",
      "INVITE_CODE_REQUIRED",
      "INVITE_CODE_INVALID",
      "INVITE_CODE_NOT_FOUND",
      "INVITE_CODE_TAKEN",
      "SIGNUPS_DISABLED",
    ] as const) {
      const error = new InlineError(InlineError.ApiError[type], { cause: new Error("private auth failure") })
      const result = toRealtimeRpcError(error)

      expect(result.code).toBe(RealtimeRpcError.Code.BAD_REQUEST)
      expect(result.codeNumber).toBe(400)
      expect(result.message).toBe(InlineError.ApiError[type][2])
      expect(result.message).not.toContain("private auth failure")
    }
  })

  it("preserves the specific email and phone validation codes and public messages", () => {
    const email = toRealtimeRpcError(new InlineError(InlineError.ApiError.EMAIL_INVALID))
    const phone = toRealtimeRpcError(new InlineError(InlineError.ApiError.PHONE_INVALID))

    expect(email.code).toBe(RealtimeRpcError.Code.EMAIL_INVALID)
    expect(email.codeNumber).toBe(400)
    expect(email.message).toBe("The email is invalid")
    expect(phone.code).toBe(RealtimeRpcError.Code.PHONE_NUMBER_INVALID)
    expect(phone.codeNumber).toBe(400)
    expect(phone.message).toBe("The phone number is invalid")
  })

  it("preserves an existing realtime error", () => {
    const expected = RealtimeRpcError.RateLimit()
    expect(toRealtimeRpcError(expected)).toBe(expected)
  })

  it("preserves the public rate-limit boundary for Inline errors", () => {
    const result = toRealtimeRpcError(new InlineError(InlineError.ApiError.FLOOD))
    expect(result.code).toBe(RealtimeRpcError.Code.RATE_LIMIT)
    expect(result.codeNumber).toBe(429)
  })
})
