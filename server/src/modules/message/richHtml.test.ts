import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, RichDirection, RichHorizontalAlign, RichTextStyle } from "@inline-chat/protocol/core"
import { RichTextValidationError, renderRichMessage, richMediaDependencies } from "./richText"
import { parseRichHtml } from "./richHtml"

const kind = (rich: ReturnType<typeof parseRichHtml>) => rich.blocks[0]?.block.oneofKind
const flat = (nodes: Array<{ text: string; children: any[] }>): string =>
  nodes.map((node) => node.text + flat(node.children)).join("")

describe("parseRichHtml", () => {
  test("parses headings, paragraphs, links, spoiler, underline, and inline code", () => {
    const rich = parseRichHtml(
      '<h2>Release &amp; Notes</h2><p>Read <a href="https://example.com/docs"><strong>docs</strong></a> and <tg-spoiler>secret</tg-spoiler> <u>soon</u> <code>x=1</code>.</p>',
    )

    expect(rich.fallbackText).toBe("Release & Notes\n\nRead docs and secret soon x=1.")
    expect(rich.blocks.map((block) => block.block.oneofKind)).toEqual(["heading", "paragraph"])
    expect(renderRichMessage(rich).entities?.entities.map((entity) => entity.type)).toEqual(
      expect.arrayContaining([
        MessageEntity_Type.BOLD,
        MessageEntity_Type.TEXT_URL,
        MessageEntity_Type.CODE,
      ]),
    )

    const paragraph = rich.blocks[1]
    const styles =
      paragraph?.block.oneofKind === "paragraph"
        ? paragraph.block.paragraph.text.flatMap((node) => node.styles.map((style) => [node.text, style]))
        : []
    expect(styles).toEqual(expect.arrayContaining([["secret", RichTextStyle.STYLE_SPOILER]]))
    expect(styles).toEqual(expect.arrayContaining([["soon", RichTextStyle.STYLE_UNDERLINE]]))
  })

  test("parses details, expandable quotes, lists, code language, and table cells", () => {
    const rich = parseRichHtml(`
      <details open>
        <summary>Plan</summary>
        <p>Ship rich HTML</p>
      </details>
      <blockquote expandable><p>Expandable quote</p></blockquote>
      <ol start="3"><li>three</li><li>four</li></ol>
      <pre><code class="language-ts">const x = 1</code></pre>
      <table bordered>
        <tr><th align="left">Name</th><th align="right">Count</th></tr>
        <tr><td colspan="2">Total</td></tr>
      </table>
    `)

    expect(rich.blocks.map((block) => block.block.oneofKind)).toEqual(["details", "quote", "list", "code", "table"])
    const details = rich.blocks[0]
    expect(details?.block.oneofKind === "details" ? details.block.details.initiallyOpen : false).toBe(true)
    expect(details?.block.oneofKind === "details" ? flat(details.block.details.title) : "").toBe("Plan")

    const quote = rich.blocks[1]
    expect(quote?.block.oneofKind === "quote" ? quote.block.quote.expandable : false).toBe(true)
    expect(quote?.block.oneofKind === "quote" ? quote.block.quote.initiallyCollapsed : false).toBe(true)

    const list = rich.blocks[2]
    expect(list?.block.oneofKind === "list" ? list.block.list.start : 0).toBe(3)

    const code = rich.blocks[3]
    expect(code?.block.oneofKind === "code" ? code.block.code.language : undefined).toBe("ts")
    expect(code?.direction).toBe(RichDirection.DIRECTION_LTR)

    const table = rich.blocks[4]
    expect(table?.block.oneofKind === "table" ? table.block.table.bordered : false).toBe(true)
    expect(table?.block.oneofKind === "table" ? table.block.table.rows[0]?.cells[0]?.header : false).toBe(true)
    expect(table?.block.oneofKind === "table" ? table.block.table.rows[0]?.cells[1]?.align : undefined).toBe(
      RichHorizontalAlign.HORIZONTAL_ALIGN_RIGHT,
    )
  })

  test("parses safe HTTPS image blocks as rich media", () => {
    const rich = parseRichHtml('<img src="https://example.com/bird.png" alt="Bird" width="320" height="180" />')
    const block = rich.blocks[0]

    expect(kind(rich)).toBe("photo")
    expect(block?.block.oneofKind === "photo" ? block.block.photo.media?.media : undefined).toEqual({
      oneofKind: "publicUrl",
      publicUrl: "https://example.com/bird.png",
    })
    expect(block?.block.oneofKind === "photo" ? block.block.photo.media?.width : undefined).toBe(320)
    expect(block?.block.oneofKind === "photo" ? block.block.photo.media?.height : undefined).toBe(180)
    expect(richMediaDependencies(rich)[0]?.kind).toBe("public_url")
    expect(rich.fallbackText).toBe("[Image: Bird] Bird")
  })

  test("rejects unsupported tags, unsafe attributes, and unsafe image URLs", () => {
    expect(() => parseRichHtml("<script>alert(1)</script>")).toThrow(RichTextValidationError)
    expect(() => parseRichHtml('<p onclick="x()">bad</p>')).toThrow(RichTextValidationError)
    expect(() => parseRichHtml('<img src="http://example.com/bird.png" alt="Bird" />')).toThrow(RichTextValidationError)
  })
})
