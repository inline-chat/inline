import { describe, expect, it } from "vitest"
import {
  INLINE_FOLLOW_MODE_MENTION_FRESH_LAST_MESSAGE_ID_LIMIT,
  isInlineFollowModeMentionGateEligible,
  isInlineFreshThreadForMentionGate,
  isInlineReplyThreadForMentionGate,
} from "./thread-mention-gating.js"

describe("thread mention gating", () => {
  it("treats reply threads as eligible regardless of size", () => {
    expect(isInlineReplyThreadForMentionGate({ parentChatId: 10n, parentMessageId: 5n })).toBe(true)
    expect(isInlineFollowModeMentionGateEligible({ parentMessageId: "5", lastMsgId: 500n })).toBe(true)
  })

  it("treats only fresh normal threads as eligible", () => {
    expect(isInlineFreshThreadForMentionGate(49n)).toBe(true)
    expect(isInlineFollowModeMentionGateEligible({ lastMsgId: 49n })).toBe(true)
    expect(isInlineFollowModeMentionGateEligible({ lastMsgId: INLINE_FOLLOW_MODE_MENTION_FRESH_LAST_MESSAGE_ID_LIMIT })).toBe(false)
    expect(isInlineFollowModeMentionGateEligible({ parentChatId: 10n, lastMsgId: 99n })).toBe(false)
  })
})
