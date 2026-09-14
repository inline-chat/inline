import { describe, expect, it } from "vitest"
import { parseCurrentInlineSession } from "./tool-targets"

describe("inline/tool-targets", () => {
  it.each(["direct", "group"])("keeps specialized %s child tools in the child", (kind) => {
    expect(parseCurrentInlineSession({
      messageChannel: "inline",
      sessionKey: `agent:main:inline:${kind}:51:thread:8912:inline-agent:researcher`,
    })).toEqual({
      target: { normalized: "8912", peerId: { type: { oneofKind: "chat", chat: { chatId: 8912n } } } },
      parentChatId: kind === "group" ? 51n : null,
      threadId: 8912n,
    })
  })

  it("keeps ordinary specialized DMs as user targets", () => {
    expect(parseCurrentInlineSession({
      messageChannel: "inline", sessionKey: "agent:main:inline:direct:51:inline-agent:researcher",
    })?.target.peerId).toEqual({ type: { oneofKind: "user", user: { userId: 51n } } })
  })
})
