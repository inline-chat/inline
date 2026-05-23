import { describe, expect, it } from "vitest"
import {
  adaptInlineVisibleCopy,
  buildInlineInboundFormattingHints,
  buildInlineSystemPrompt,
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
      ]),
    })
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
