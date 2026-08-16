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
    expect(toRealtimeRpcError(new Error("boom")).codeNumber).toBe(500)
    expect(toRealtimeRpcError(ModelError.Failed).codeNumber).toBe(500)
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
