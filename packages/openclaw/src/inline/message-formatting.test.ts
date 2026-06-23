import { describe, expect, it } from "vitest"
import {
  adaptInlineVisibleCopy,
  buildInlineInboundFormattingHints,
  buildInlineChatMarkdownLink,
  buildInlineSystemPrompt,
  buildInlineThreadMarkdownLink,
  buildInlineThreadTitleMarkdownLink,
  buildInlineUserMarkdownLink,
  sanitizeInlineOutgoingText,
} from "./message-formatting"

describe("inline/message-formatting", () => {
  it("keeps GroupSystemPrompt for custom config guidance only", () => {
    const prompt = buildInlineSystemPrompt("Keep replies short.")

    expect(prompt).toBe("Keep replies short.")
    expect(buildInlineSystemPrompt()).toBe("")
  })

  it("builds structured inbound formatting hints for OpenClaw metadata", () => {
    expect(buildInlineInboundFormattingHints()).toEqual({
      text_markup: "inline_markdown",
      rules: expect.arrayContaining([
        "Prefer bullet lists over markdown tables.",
        "Use plain URLs or markdown links; do not wrap bare URLs in inline code or backticks.",
        "Mention Inline users with markdown links like [@FirstName](inline://user?id=123); use inline://user?username=username only when the user id is unavailable.",
        "Link Inline chats/threads with markdown links like [Planning](inline://chat?id=123) or [Planning](inline://thread?id=123); use inline://thread?space_id=7 when only the title and space are known.",
      ]),
    })
  })

  it("builds Inline markdown links for users, chats, and threads", () => {
    expect(buildInlineUserMarkdownLink({ userId: "99", label: "Alice" })).toBe(
      "[@Alice](inline://user?id=99)",
    )
    expect(buildInlineChatMarkdownLink({ chatId: "7", title: "Alice DM" })).toBe(
      "[Alice DM](inline://chat?id=7)",
    )
    expect(buildInlineThreadMarkdownLink({ threadId: "8", title: "Eng Group" })).toBe(
      "[Eng Group](inline://thread?id=8)",
    )
    expect(buildInlineThreadTitleMarkdownLink({ spaceId: "22", title: "Eng Group" })).toBe(
      "[Eng Group](inline://thread?space_id=22)",
    )
    expect(
      buildInlineThreadTitleMarkdownLink({
        spaceId: "22",
        title: "Project Plan",
        label: "the thread",
      }),
    ).toBe("[the thread](inline://thread?space_id=22&title=Project%20Plan)")
  })

  it("strips inline code formatting from bare URLs only", () => {
    expect(
      sanitizeInlineOutgoingText("See `https://example.com/docs` and `http://example.com/a?b=1`."),
    ).toBe("See https://example.com/docs and http://example.com/a?b=1.")
  })

  it("preserves non-URL inline code spans", () => {
    expect(sanitizeInlineOutgoingText("Run `bun test` then open `src/index.ts`.")).toBe(
      "Run `bun test` then open `src/index.ts`.",
    )
  })

  it("adapts shared native-channel command copy for Inline", () => {
    expect(
      adaptInlineVisibleCopy(
        "/focus - Bind this thread (Discord) or topic/conversation (Telegram) to a session target.",
      ),
    ).toBe("/focus - Bind this Inline conversation to a session target.")
    expect(
      sanitizeInlineOutgoingText(
        "/unfocus - Remove the current thread (Discord) or topic/conversation (Telegram) binding.",
      ),
    ).toBe("/unfocus - Remove the current Inline conversation binding.")
  })

  it("adapts generic shared command copy variants for Inline", () => {
    expect(adaptInlineVisibleCopy("/bind - Bind this thread or topic/conversation to a session target")).toBe(
      "/bind - Bind this Inline conversation to a session target.",
    )
    expect(
      adaptInlineVisibleCopy("/unbind - Remove the current thread or topic/conversation binding"),
    ).toBe("/unbind - Remove the current Inline conversation binding.")
  })
})
