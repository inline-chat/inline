import { describe, expect, it } from "vitest"
import { buildInlineSystemPrompt, sanitizeInlineOutgoingText } from "./message-formatting"

describe("inline/message-formatting", () => {
  it("builds a base system prompt and appends custom config guidance", () => {
    const prompt = buildInlineSystemPrompt("Keep replies short.")

    expect(prompt).toContain("Do not wrap bare URLs in inline code")
    expect(prompt).toContain("Keep replies short.")
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
})
