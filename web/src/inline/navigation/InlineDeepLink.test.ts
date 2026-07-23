import { chatId, messageId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { inlineMessageDeepLink, inlinePeerDeepLink } from "./InlineDeepLink"

describe("Inline deep links", () => {
  it("matches the native user, chat, and message URL shapes", () => {
    expect(inlinePeerDeepLink({ peerKind: "user", peerId: userId(7) })).toBe("in://user/7")
    expect(inlinePeerDeepLink({ peerKind: "chat", peerId: chatId(8) })).toBe("in://chat/8")
    expect(inlineMessageDeepLink(chatId(8), messageId(9))).toBe("in://chat/8/message/9")
  })
})
