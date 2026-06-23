import { RichDirection } from "@inline-chat/realtime-sdk"
import { describe, expect, it } from "vitest"
import {
  buildInlineProgressDraftRichText,
  buildInlineProgressDraftRichTextFromLines,
  buildInlineStreamingRichText,
  inlineStreamingTextOptions,
  prepareInlineStreamingTextDraft,
} from "./rich-text"

const baseAccount = {
  config: {},
} as Parameters<typeof inlineStreamingTextOptions>[0]

describe("inline/rich-text", () => {
  it("builds stable paragraph ids for streaming rich snapshots", () => {
    const richText = buildInlineStreamingRichText("first **paragraph**\r\n\r\nsecond paragraph")

    expect(richText).toMatchObject({
      direction: RichDirection.DIRECTION_AUTO,
      fallbackText: "first **paragraph**\n\nsecond paragraph",
      version: 1,
    })
    expect(richText.blocks.map((block) => block.blockId)).toEqual([
      "openclaw_stream_visible_0",
      "openclaw_stream_visible_1",
    ])
    expect(richText.blocks[0]?.block.oneofKind).toBe("paragraph")
    expect(richText.blocks[0]?.block.paragraph.text).toEqual([
      { text: "first **paragraph**", children: [], styles: [] },
    ])
    expect(richText.blocks[1]?.block.paragraph.text).toEqual([
      { text: "second paragraph", children: [], styles: [] },
    ])
  })

  it("uses structured rich text for streaming unless markdown parsing is disabled", () => {
    expect(inlineStreamingTextOptions(baseAccount, "hello")).toMatchObject({
      richText: {
        fallbackText: "hello",
        blocks: [
          expect.objectContaining({
            blockId: "openclaw_stream_visible_0",
          }),
        ],
      },
    })

    expect(
      inlineStreamingTextOptions({ config: { parseMarkdown: false } } as typeof baseAccount, "hello"),
    ).toEqual({ parseMarkdown: false })
  })

  it("strips markdown image embeds from streaming rich snapshots", () => {
    const richText = buildInlineStreamingRichText(
      [
        "Intro",
        "",
        "![Preview](https://commons.wikimedia.org/wiki/Special:FilePath/Cockatiel_(Nymphicus_hollandicus).jpg)",
        "",
        "[docs](https://example.com/docs)",
      ].join("\n"),
    )

    expect(richText.fallbackText).toBe("Intro\n\n[docs](https://example.com/docs)")
    expect(richText.fallbackText).not.toContain("![")
    expect(richText.fallbackText).not.toContain("Cockatiel")
    expect(richText.blocks.map((block) => block.blockId)).toEqual([
      "openclaw_stream_visible_0",
      "openclaw_stream_visible_1",
    ])
    expect(richText.blocks[1]?.block.oneofKind === "paragraph" ? richText.blocks[1].block.paragraph.text[0]?.text : undefined).toBe(
      "[docs](https://example.com/docs)",
    )
  })

  it("prepares cleaned visible text for streaming rich snapshots", () => {
    const draft = prepareInlineStreamingTextDraft(
      baseAccount,
      [
        "Intro",
        "",
        "![Preview](https://commons.wikimedia.org/wiki/Special:FilePath/Cockatiel_(Nymphicus_hollandicus).jpg)",
      ].join("\n"),
    )

    expect(draft).toMatchObject({
      text: "Intro",
      options: {
        richText: {
          fallbackText: "Intro",
        },
      },
    })
  })

  it("skips rich streaming drafts that clean to empty", () => {
    expect(
      prepareInlineStreamingTextDraft(
        baseAccount,
        "![Preview](https://commons.wikimedia.org/wiki/Special:FilePath/Cockatiel_(Nymphicus_hollandicus).jpg)",
      ),
    ).toBeUndefined()
  })

  it("does not strip streaming text when markdown parsing is disabled", () => {
    const text = "![Preview](https://example.com/image.png)"

    expect(
      prepareInlineStreamingTextDraft({ config: { parseMarkdown: false } } as typeof baseAccount, text),
    ).toEqual({
      text,
      options: { parseMarkdown: false },
    })
  })

  it("preserves fenced markdown image text in streaming rich snapshots", () => {
    const richText = buildInlineStreamingRichText(
      [
        "Example:",
        "",
        "```md",
        "![Preview](https://example.com/image.png)",
        "```",
      ].join("\n"),
    )

    expect(richText.fallbackText).toContain("![Preview](https://example.com/image.png)")
    expect(richText.blocks).toHaveLength(2)
  })

  it("caps streaming rich text to server rich text limits", () => {
    const richText = buildInlineStreamingRichText("x".repeat(32_868))

    expect(richText.fallbackText).toHaveLength(32_768)
    expect(richText.fallbackText.endsWith("...")).toBe(true)
    expect(richText.blocks[0]?.block.oneofKind === "paragraph" ? richText.blocks[0].block.paragraph.text[0]?.text : "").toHaveLength(
      32_768,
    )
  })

  it("caps streaming rich paragraph count to server rich block limits", () => {
    const richText = buildInlineStreamingRichText(
      Array.from({ length: 520 }, (_, index) => `paragraph ${index}`).join("\n\n"),
    )

    expect(richText.blocks).toHaveLength(500)
    expect(richText.blocks.at(-1)?.blockId).toBe("openclaw_stream_visible_499")
  })

  it("builds visible thinking blocks for progress drafts", () => {
    const richText = buildInlineProgressDraftRichText("Working\nlisted files")

    expect(richText.fallbackText).toBe("Working\nlisted files")
    expect(richText.blocks).toHaveLength(1)
    expect(richText.blocks[0]?.block.oneofKind).toBe("thinking")
    const thinking = richText.blocks[0]?.block.oneofKind === "thinking" ? richText.blocks[0].block.thinking : undefined
    expect(thinking?.initiallyCollapsed).toBe(false)
    expect(thinking?.blocks.map((block) => block.blockId)).toEqual([
      "openclaw_progress_line_0",
      "openclaw_progress_line_1",
    ])
    expect(thinking?.blocks[1]?.block.oneofKind === "paragraph" ? thinking.blocks[1].block.paragraph.text[0]?.text : undefined).toBe(
      "listed files",
    )
  })

  it("strips markdown image embeds from progress drafts", () => {
    const richText = buildInlineProgressDraftRichText(
      "Working\n- ![Preview](https://example.com/image_(1).png)\nlisted files",
    )

    expect(richText.fallbackText).toBe("Working\nlisted files")
    const thinking = richText.blocks[0]?.block.oneofKind === "thinking" ? richText.blocks[0].block.thinking : undefined
    expect(thinking?.blocks.map((block) => block.block.oneofKind === "paragraph" ? block.block.paragraph.text[0]?.text : undefined)).toEqual([
      "Working",
      "listed files",
    ])
  })

  it("caps progress draft lines to leave room for the thinking wrapper", () => {
    const richText = buildInlineProgressDraftRichText(
      Array.from({ length: 520 }, (_, index) => `line ${index}`).join("\n"),
    )

    const thinking = richText.blocks[0]?.block.oneofKind === "thinking" ? richText.blocks[0].block.thinking : undefined
    expect(thinking?.blocks).toHaveLength(499)
    expect(thinking?.blocks.at(-1)?.blockId).toBe("openclaw_progress_line_498")
  })

  it("keeps progress metadata aligned with capped visible lines", () => {
    const richText = buildInlineProgressDraftRichTextFromLines(
      Array.from({ length: 520 }, (_, index) => `line ${index}`).join("\n"),
      Array.from({ length: 520 }, (_, index) => ({
        id: `item-${index}`,
      })),
    )

    const thinking = richText.blocks[0]?.block.oneofKind === "thinking" ? richText.blocks[0].block.thinking : undefined
    expect(thinking?.blocks.at(0)?.blockId).toBe("openclaw_progress_item-0")
    expect(thinking?.blocks.at(-1)?.blockId).toBe("openclaw_progress_item-498")
  })

  it("preserves progress line ids as rich draft block ids", () => {
    const richText = buildInlineProgressDraftRichTextFromLines("Thinking...\n• listed files\n• tests passed", [
      {
        id: "command:exec-1",
        kind: "item",
        toolName: "exec",
        label: "Shell",
      },
      {
        id: "summary:tests",
        kind: "command-output",
        toolName: "exec",
        label: "Shell",
      },
    ])

    const thinking = richText.blocks[0]?.block.oneofKind === "thinking" ? richText.blocks[0].block.thinking : undefined
    expect(thinking?.blocks.map((block) => block.blockId)).toEqual([
      "openclaw_progress_label",
      "openclaw_progress_command_exec-1",
      "openclaw_progress_summary_tests",
    ])
  })
})
