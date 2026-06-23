import { describe, expect, test } from "bun:test"
import { richTextLimits } from "@in/server/modules/message/richText"
import { cleanStreamingMarkdown } from "./outputMarkdown"
import {
  buildStreamingRichText,
  prepareStreamingRichDraft,
  STREAMING_THINKING_FALLBACK,
  STREAMING_THINKING_TEXT,
} from "./streamingRichText"

describe("ChatGPT streaming rich text", () => {
  test("builds a thinking-only rich draft for empty text", () => {
    const rich = buildStreamingRichText("")

    expect(rich.fallbackText).toBe(STREAMING_THINKING_FALLBACK)
    expect(rich.blocks).toHaveLength(1)
    expect(rich.blocks[0]?.block.oneofKind).toBe("thinking")
    expect(
      rich.blocks[0]?.block.oneofKind === "thinking"
        ? rich.blocks[0].block.thinking.blocks[0]?.block.oneofKind === "paragraph"
          ? rich.blocks[0].block.thinking.blocks[0]?.block.paragraph.text[0]?.text
          : undefined
        : undefined,
    ).toBe(STREAMING_THINKING_TEXT)
  })

  test("uses plain paragraph blocks for streaming drafts instead of full markdown parsing", () => {
    const cleaned = cleanStreamingMarkdown("## Progress\n\n- **one**\n\n![Preview](https://example.com/image.png)")
    const rich = buildStreamingRichText(cleaned)

    expect(cleaned).toBe("Progress\n\n- **one**")
    expect(rich.fallbackText).toBe("Progress\n\n- **one**")
    expect(rich.blocks.map((block) => block.block.oneofKind)).toEqual(["thinking", "paragraph", "paragraph"])
    expect(rich.blocks[1]?.block.oneofKind === "paragraph" ? rich.blocks[1].block.paragraph.text[0]?.text : undefined).toBe("Progress")
    expect(rich.blocks[2]?.block.oneofKind === "paragraph" ? rich.blocks[2].block.paragraph.text[0]?.text : undefined).toBe("- **one**")
  })

  test("caps streaming draft fallback text to rich text limits", () => {
    const rich = buildStreamingRichText("x".repeat(richTextLimits.maxTextLength + 100))

    expect(rich.fallbackText).toHaveLength(richTextLimits.maxTextLength)
    expect(rich.fallbackText.endsWith("...")).toBe(true)
    expect(rich.blocks[1]?.block.oneofKind === "paragraph" ? rich.blocks[1].block.paragraph.text[0]?.text : "").toHaveLength(richTextLimits.maxTextLength)
  })

  test("skips unchanged cleaned streaming drafts", () => {
    const first = prepareStreamingRichDraft("Generating:")
    expect(first?.changed).toBe(true)

    const second = prepareStreamingRichDraft(
      "Generating:\n\n![Preview](https://example.com/preview.png)",
      first?.text,
    )
    expect(second?.text).toBe("Generating:")
    expect(second?.changed).toBe(false)
  })

  test("does not prepare a draft when streaming text only contains stripped images", () => {
    expect(prepareStreamingRichDraft("![Preview](https://example.com/preview.png)")).toBeUndefined()
  })
})
