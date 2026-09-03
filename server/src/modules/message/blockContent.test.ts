import {
  BlockDisclosure_ActivityKind,
  BlockDisclosure_Kind,
  BlockList_Kind,
  BlockTable_Alignment,
  MessageEntity_Type,
  type Block,
  type BlockContent,
  type BlockText,
} from "@inline-chat/protocol/core"
import { describe, expect, test } from "bun:test"
import { parseMarkdown } from "./parseMarkdown"
import {
  getBlockImageAtPath,
  parseBlockContent,
  parseBlockContentResult,
  replaceBlockImageAtPath,
  validateBlockContent,
} from "./blockContent"
import { encodeBlockContentToMarkdown } from "./blockContentMarkdown"
import { detectFirstStrongIsRtl } from "./blockDirection"
import { processOutgoingText } from "./processOutgoingText"

const textFor = (markdown: string, range: BlockText | undefined): string => {
  if (!range) return ""
  const flat = parseMarkdown(markdown).text
  return flat.slice(Number(range.offset), Number(range.offset + range.length))
}

const kind = (block: Block | undefined): string | undefined => block?.kind.oneofKind

describe("block content parser", () => {
  test("all BlockText-bearing nodes reject surrogate-splitting ranges", () => {
    const text = "😀x"
    const malformed = [{ offset: 1n, length: 1n }, { offset: 0n, length: 1n }]
    const contents = (range: BlockText): BlockContent[] => [
      { blocks: [{ kind: { oneofKind: "paragraph", paragraph: range } }] },
      { blocks: [{ kind: { oneofKind: "footer", footer: range } }] },
      { blocks: [{ kind: { oneofKind: "heading", heading: { level: 2, text: range } } }] },
      { blocks: [{ kind: { oneofKind: "code", code: { text: range, language: "swift" } } }] },
      { blocks: [{ kind: { oneofKind: "disclosure", disclosure: {
        kind: BlockDisclosure_Kind.DEFAULT,
        activityKind: BlockDisclosure_ActivityKind.UNSPECIFIED,
        summary: range, children: [{ kind: { oneofKind: "separator", separator: {} } }],
      } } }] },
      { blocks: [{ kind: { oneofKind: "quote", quote: {
        children: [{ kind: { oneofKind: "paragraph", paragraph: range } }],
      } } }] },
      { blocks: [{ kind: { oneofKind: "list", list: {
        kind: BlockList_Kind.UNORDERED,
        items: [{ children: [{ kind: { oneofKind: "paragraph", paragraph: range } }] }],
      } } }] },
      { blocks: [{ kind: { oneofKind: "image", image: {
        alt: range, state: { oneofKind: "unavailable", unavailable: {} },
      } } }] },
      { blocks: [{ kind: { oneofKind: "table", table: {
        alignments: [BlockTable_Alignment.LEFT], rows: [{ cells: [range] }],
      } } }] },
    ]

    for (const profile of ["native", "persisted"] as const) {
      for (const range of malformed) {
        for (const content of contents(range)) {
          expect(() => validateBlockContent(text, content, profile))
            .toThrow("Block text range splits a Unicode scalar")
        }
      }
    }
  })

  test("reports content-free table fallback and retains neighboring blocks and their media jobs", () => {
    for (const cell of ["![photo](https://example.com/a.png)", "**![photo](https://example.com/a.png)**", "[![photo](https://example.com/a.png)](https://example.com)"]) {
      const markdown = "![before](https://example.com/b.png)\n\n| Item |\n| --- |\n| " + cell + " |"
      const result = parseBlockContentResult(markdown)
      expect(result.kind).toBe("parsed")
      if (result.kind !== "parsed") throw new Error("missing projection")
      expect(result.value.warnings).toEqual(["unsupported_table_content"])
      expect(result.value.blockContent.blocks.map(kind)).toEqual(["image", "paragraph"])
      expect(result.value.imageSources).toEqual([{ path: [0], url: "https://example.com/b.png" }])
      const table = result.value.blockContent.blocks[1]
      expect(textFor(markdown, table?.kind.oneofKind === "paragraph" ? table.kind.paragraph : undefined)).toBe(parseMarkdown(markdown.slice(markdown.indexOf("| Item"))).text)
    }
    expect(parseBlockContentResult("")).toEqual({ kind: "fallback", reason: "empty" })
    const oversized = "| x |\n| --- |\n" + "| x |\n".repeat(256)
    expect(parseBlockContentResult(oversized)).toEqual({ kind: "fallback", reason: "invalid_projection" })
  })

  test("outgoing table fallback preserves canonical text/entities and only schedules supported media", async () => {
    const markdown = "![before](https://example.com/b.png)\n\n| Item |\n| --- |\n| ![photo](https://example.com/a.png) |"
    const flat = parseMarkdown(markdown)
    const output = await processOutgoingText({ text: markdown, entities: undefined, parseMarkdown: true })
    expect(output.text).toBe(flat.text)
    expect(output.entities?.entities).toEqual(flat.entities)
    expect(output.blockContent?.blocks.map(kind)).toEqual(["image", "paragraph"])
    expect(output.blockImageSources).toEqual([{ path: [0], url: "https://example.com/b.png" }])
    expect(output.blockContentWarnings).toEqual(["unsupported_table_content"])
    expect(output.blockContentFallbackReason).toBeUndefined()
    const literal = await processOutgoingText({ text: markdown, entities: undefined, parseMarkdown: false })
    expect(literal.text).toBe(markdown)
    expect(literal.blockContentFallbackReason).toBeUndefined()
    expect(literal.blockContentWarnings).toBeUndefined()
  })

  test("text-only tables retain supported inline styles and TeX without interpreting math as media", () => {
    const markdown = "| Value |\n| --- |\n| **b** <u>u</u> ~~s~~ ==h== [link](https://example.com) $\\text{![x](a)}$ |"
    const result = parseBlockContentResult(markdown)
    expect(result.kind).toBe("parsed")
    if (result.kind !== "parsed") return
    expect(result.value.blockContent.blocks.map(kind)).toEqual(["table"])
    expect(result.value.imageSources).toEqual([])
  })

  test("an unsupported streamed table never removes or retypes completed prefix blocks", () => {
    const prefix = "# Finished\n\n```ts\nconst value = 1\n```\n\n"
    const tail = "| Item |\n| --- |\n| ![photo](https://example.com/a.png) |"
    const completed = parseBlockContent(prefix)!.blockContent.blocks
    expect(completed.map(kind)).toEqual(["heading", "code"])
    for (let length = 0; length <= tail.length; length++) {
      const result = parseBlockContent(prefix + tail.slice(0, length))
      expect(result?.blockContent.blocks.slice(0, 2)).toEqual(completed)
    }
  })

  test("adds structure without changing the legacy projection", () => {
    const markdown = "# Hello **world**\n\nParagraph with `code`.\n\n---\n\n```swift\nlet x = 1\n```"
    const parsed = parseBlockContent(markdown)
    expect(parsed).toBeDefined()
    expect(parsed!.blockContent.blocks.map(kind)).toEqual(["heading", "paragraph", "separator", "code"])

    const [heading, paragraph, , code] = parsed!.blockContent.blocks
    expect(textFor(markdown, heading?.kind.oneofKind === "heading" ? heading.kind.heading.text : undefined)).toBe(
      "Hello world",
    )
    expect(textFor(markdown, paragraph?.kind.oneofKind === "paragraph" ? paragraph.kind.paragraph : undefined)).toBe(
      "Paragraph with code.",
    )
    expect(textFor(markdown, code?.kind.oneofKind === "code" ? code.kind.code.text : undefined)).toBe("let x = 1")
    expect(() => validateBlockContent(parseMarkdown(markdown).text, parsed!.blockContent)).not.toThrow()
  })

  test("supports nested lists and preserves ordered starts", () => {
    const markdown = "3. first\n   - nested\n   - second\n4. last"
    const parsed = parseBlockContent(markdown)!
    const listBlock = parsed.blockContent.blocks[0]
    expect(listBlock?.kind.oneofKind).toBe("list")
    if (listBlock?.kind.oneofKind !== "list") return
    expect(listBlock.kind.list.kind).toBe(BlockList_Kind.ORDERED)
    expect(listBlock.kind.list.start).toBe(3n)
    expect(listBlock.kind.list.items).toHaveLength(2)
    expect(listBlock.kind.list.items[0]?.children.map(kind)).toEqual(["paragraph", "list"])
  })

  test("supports nested block quotes and GFM tables", () => {
    const markdown = [
      "> نقل **قول**",
      ">",
      "> - nested",
      "",
      "| Name | توضیح |",
      "| :--- | ---: |",
      "| **Alice** | a\\|b |",
    ].join("\n")
    const flat = parseMarkdown(markdown)
    const parsed = parseBlockContent(markdown)!

    expect(parsed.blockContent.blocks.map(kind)).toEqual(["quote", "table"])
    const quote = parsed.blockContent.blocks[0]
    expect(quote?.kind.oneofKind === "quote" ? quote.kind.quote.children.map(kind) : []).toEqual([
      "paragraph",
      "list",
    ])
    const table = parsed.blockContent.blocks[1]
    expect(table?.kind.oneofKind).toBe("table")
    if (table?.kind.oneofKind !== "table") return
    expect(table.kind.table.alignments).toEqual([
      BlockTable_Alignment.LEFT,
      BlockTable_Alignment.RIGHT,
    ])
    expect(table.kind.table.rows).toHaveLength(2)
    expect(textFor(markdown, table.kind.table.rows[1]?.cells[1])).toBe("a|b")

    const encoded = encodeBlockContentToMarkdown({
      text: flat.text,
      entities: { entities: flat.entities },
      blockContent: parsed.blockContent,
    })
    const roundTrip = parseBlockContent(encoded)!
    expect(roundTrip.blockContent.blocks.map(kind)).toEqual(["quote", "table"])
    expect(parseMarkdown(encoded).text).toContain("a|b")
  })

  test("annotates deterministic first-strong direction without Markdown syntax", () => {
    expect(detectFirstStrongIsRtl("123 😀 —")).toBeUndefined()
    expect(detectFirstStrongIsRtl("123 😀 سلام English")).toBe(true)
    expect(detectFirstStrongIsRtl("123 😀 English سلام")).toBe(false)
    expect(detectFirstStrongIsRtl("\u200fEnglish")).toBe(false)

    const markdown = [
      "😀 سلام English",
      "",
      "- 123",
      "  - فارسی",
      "- English",
      "",
      "> 123",
      ">",
      "> فارسی",
      "",
      "<details>",
      "<summary>123 😀</summary>",
      "فارسی",
      "</details>",
      "",
      "```txt",
      "فارسی",
      "```",
      "",
      "| 123 | فارسی |",
      "| --- | --- |",
      "| x | y |",
      "",
      "![فارسی](https://example.com/image.png)",
    ].join("\n")
    const parsed = parseBlockContent(markdown)!
    const blocks = parsed.blockContent.blocks

    const paragraph = blocks[0]?.kind.oneofKind === "paragraph" ? blocks[0].kind.paragraph : undefined
    expect(paragraph?.isRtl).toBe(true)
    expect(paragraph ? Object.hasOwn(paragraph, "isRtl") : false).toBe(true)

    const list = blocks[1]?.kind.oneofKind === "list" ? blocks[1].kind.list : undefined
    expect(list?.isRtl).toBe(true)
    const firstListParagraph = list?.items[0]?.children[0]
    expect(firstListParagraph?.kind.oneofKind).toBe("paragraph")
    if (firstListParagraph?.kind.oneofKind === "paragraph") {
      expect(Object.hasOwn(firstListParagraph.kind.paragraph, "isRtl")).toBe(false)
    }
    const nestedList = list?.items[0]?.children[1]
    expect(nestedList?.kind.oneofKind === "list" ? nestedList.kind.list.isRtl : undefined).toBe(true)
    if (nestedList?.kind.oneofKind === "list") {
      const nestedParagraph = nestedList.kind.list.items[0]?.children[0]
      if (nestedParagraph?.kind.oneofKind === "paragraph") {
        expect(Object.hasOwn(nestedParagraph.kind.paragraph, "isRtl")).toBe(false)
      }
    }

    const quote = blocks[2]?.kind.oneofKind === "quote" ? blocks[2].kind.quote : undefined
    expect(quote?.isRtl).toBe(true)

    const disclosure = blocks[3]?.kind.oneofKind === "disclosure" ? blocks[3].kind.disclosure : undefined
    expect(disclosure?.isRtl).toBe(true)
    expect(disclosure?.summary ? Object.hasOwn(disclosure.summary, "isRtl") : true).toBe(false)

    const codeText = blocks[4]?.kind.oneofKind === "code" ? blocks[4].kind.code.text : undefined
    expect(codeText ? Object.hasOwn(codeText, "isRtl") : true).toBe(false)

    const table = blocks[5]?.kind.oneofKind === "table" ? blocks[5].kind.table : undefined
    expect(table?.isRtl).toBe(true)
    expect(table?.rows.flatMap((row) => row.cells).every((cell) => !Object.hasOwn(cell, "isRtl"))).toBe(true)

    const image = blocks[6]?.kind.oneofKind === "image" ? blocks[6].kind.image : undefined
    expect(image?.alt ? Object.hasOwn(image.alt, "isRtl") : true).toBe(false)

    const encoded = encodeBlockContentToMarkdown({
      text: parseMarkdown(markdown).text,
      entities: { entities: parseMarkdown(markdown).entities },
      blockContent: parsed.blockContent,
    })
    expect(encoded).not.toContain("dir=")
  })

  test("supports nested and streaming disclosures with authoritative progress kind", () => {
    const markdown = [
      "<details open>",
      '<summary kind="progress">Working **now**</summary>',
      "Paragraph",
      "<details>",
      "<summary>Nested</summary>",
      "```ts",
      "const x = 1",
      "```",
      "</details>",
    ].join("\n")
    const parsed = parseBlockContent(markdown)!
    const disclosureBlock = parsed.blockContent.blocks[0]
    expect(disclosureBlock?.kind.oneofKind).toBe("disclosure")
    if (disclosureBlock?.kind.oneofKind !== "disclosure") return
    const disclosure = disclosureBlock.kind.disclosure
    expect(disclosure.kind).toBe(BlockDisclosure_Kind.PROGRESS)
    expect(disclosure.initiallyOpen).toBe(true)
    expect(textFor(markdown, disclosure.summary)).toBe("Working now")
    expect(disclosure.children.map(kind)).toEqual(["paragraph", "disclosure"])
    const nested = disclosure.children[1]
    expect(nested?.kind.oneofKind === "disclosure" ? nested.kind.disclosure.children.map(kind) : []).toEqual(["code"])
  })

  test("preserves semantic activity disclosures through parsing and encoding", () => {
    const markdown = [
      "<details open>",
      '<summary activity="reasoning">Mapping the renderer</summary>',
      "Provider reasoning content.",
      "<details>",
      '<summary activity="explore">Explored</summary>',
      "Read `stream_ui.rs`",
      "</details>",
      "</details>",
    ].join("\n")
    const parsed = parseBlockContent(markdown)!
    const reasoning = parsed.blockContent.blocks[0]
    expect(reasoning?.kind.oneofKind).toBe("disclosure")
    if (reasoning?.kind.oneofKind !== "disclosure") return
    expect(reasoning.kind.disclosure.activityKind).toBe(BlockDisclosure_ActivityKind.REASONING)
    const exploration = reasoning.kind.disclosure.children[1]
    expect(exploration?.kind.oneofKind).toBe("disclosure")
    if (exploration?.kind.oneofKind !== "disclosure") return
    expect(exploration.kind.disclosure.activityKind).toBe(BlockDisclosure_ActivityKind.EXPLORE)

    const encoded = encodeBlockContentToMarkdown({
      text: parseMarkdown(markdown).text,
      entities: { entities: parseMarkdown(markdown).entities },
      blockContent: parsed.blockContent,
    })
    expect(encoded).toContain('<summary activity="reasoning">Mapping the renderer</summary>')
    expect(encoded).toContain('<summary activity="explore">Explored</summary>')
    const reparsed = parseBlockContent(encoded)?.blockContent.blocks[0]
    expect(reparsed?.kind.oneofKind).toBe("disclosure")
    if (reparsed?.kind.oneofKind !== "disclosure") return
    expect(reparsed.kind.disclosure.activityKind).toBe(BlockDisclosure_ActivityKind.REASONING)
  })

  test("recognizes footer and leaves arbitrary HTML literal", () => {
    const markdown = "<aside>not supported</aside>\n\n<footer>Generated **carefully**</footer>"
    const parsed = parseBlockContent(markdown)!
    expect(parsed.blockContent.blocks.map(kind)).toEqual(["paragraph", "footer"])
    const footer = parsed.blockContent.blocks[1]
    expect(textFor(markdown, footer?.kind.oneofKind === "footer" ? footer.kind.footer : undefined)).toBe(
      "Generated carefully",
    )
  })

  test("keeps an incomplete disclosure literal until a complete summary establishes its boundary", () => {
    for (const markdown of [
      "<details>",
      "<details>\n<summary",
      "# Complete\n\n<details>\n<summary kind=\"progress\">Working",
    ]) {
      const flat = parseMarkdown(markdown)
      const parsed = parseBlockContent(markdown)

      expect(flat).toEqual({ text: markdown, entities: [] })
      expect(parsed).toBeDefined()
      expect(parsed?.blockContent.blocks.some((block) => block.kind.oneofKind === "disclosure")).toBe(false)
      expect(() => validateBlockContent(flat.text, parsed!.blockContent)).not.toThrow()
    }
  })

  test("streams a disclosure through snapshot EOF after its summary is complete", () => {
    const markdown = "<details open>\n<summary kind=\"progress\">Working</summary>\n- first\n- second"
    const flat = parseMarkdown(markdown)
    const parsed = parseBlockContent(markdown)
    const disclosure = parsed?.blockContent.blocks[0]

    expect(disclosure?.kind.oneofKind).toBe("disclosure")
    if (disclosure?.kind.oneofKind !== "disclosure") throw new Error("Expected disclosure")
    expect(disclosure.kind.disclosure.initiallyOpen).toBe(true)
    expect(disclosure.kind.disclosure.kind).toBe(BlockDisclosure_Kind.PROGRESS)
    expect(textFor(markdown, disclosure.kind.disclosure.summary)).toBe("Working")
    expect(disclosure.kind.disclosure.children.map(kind)).toEqual(["list"])
    expect(() => validateBlockContent(flat.text, parsed!.blockContent)).not.toThrow()
  })

  test("coalesces consecutive images in chunks of ten and keeps origins private", () => {
    const images = Array.from({ length: 12 }, (_, index) =>
      `![image ${index}](https://example.com/${index}.png){width=${100 + index} height=100}`,
    ).join("\n")
    const parsed = parseBlockContent(images)!
    expect(parsed.blockContent.blocks.map(kind)).toEqual(["album", "album"])
    const first = parsed.blockContent.blocks[0]
    const second = parsed.blockContent.blocks[1]
    expect(first?.kind.oneofKind === "album" ? first.kind.album.images : []).toHaveLength(10)
    expect(second?.kind.oneofKind === "album" ? second.kind.album.images : []).toHaveLength(2)
    expect(parsed.imageSources).toHaveLength(12)
    expect(parsed.imageSources[0]).toEqual({ path: [0, 0], url: "https://example.com/0.png" })
    const protocolImages = [
      ...(first?.kind.oneofKind === "album" ? first.kind.album.images : []),
      ...(second?.kind.oneofKind === "album" ? second.kind.album.images : []),
    ]
    expect(protocolImages.every((image) => !("url" in image))).toBe(true)
  })

  test("invalid image origins remain unavailable without exposing a link", () => {
    const markdown = "![private](file:///tmp/private.png)"
    const parsed = parseBlockContent(markdown)!
    const image = parsed.blockContent.blocks[0]
    expect(image?.kind.oneofKind).toBe("image")
    expect(image?.kind.oneofKind === "image" ? image.kind.image.state.oneofKind : undefined).toBe("unavailable")
    expect(parsed.imageSources).toEqual([])
  })

  test("an incomplete code fence is an open code block through the current snapshot", () => {
    const markdown = "```swift\nlet value = 1"
    const parsed = parseBlockContent(markdown)!
    expect(parsed.blockContent.blocks.map(kind)).toEqual(["code"])
    const code = parsed.blockContent.blocks[0]
    expect(textFor(markdown, code?.kind.oneofKind === "code" ? code.kind.code.text : undefined)).toBe(
      "let value = 1",
    )
  })

  test("never reparses a completed code boundary as the opening of a trailing streamed block", () => {
    const completed = ["```ts", "const first = true", "```"].join("\n")
    const trailing = ["", "```swift", "let second = `value`", "[not a link](target)"].join("\n")

    for (let length = 0; length <= trailing.length; length++) {
      const markdown = `${completed}${trailing.slice(0, length)}`
      const parsed = parseBlockContent(markdown)!
      const first = parsed.blockContent.blocks[0]

      expect(first?.kind.oneofKind).toBe("code")
      expect(textFor(markdown, first?.kind.oneofKind === "code" ? first.kind.code.text : undefined)).toBe(
        "const first = true",
      )

      if (trailing.slice(0, length).startsWith("\n```")) {
        expect(parsed.blockContent.blocks[1]?.kind.oneofKind).toBe("code")
      }
    }

    const finalMarkdown = `${completed}${trailing}`
    const final = parseBlockContent(finalMarkdown)!
    expect(final.blockContent.blocks.map(kind)).toEqual(["code", "code"])
    const second = final.blockContent.blocks[1]
    expect(textFor(finalMarkdown, second?.kind.oneofKind === "code" ? second.kind.code.text : undefined)).toBe(
      "let second = `value`\n[not a link](target)",
    )
  })

  test("preserves adaptive fence boundaries when open code contains shorter runs", () => {
    const markdown = [
      "~~~~txt",
      "first",
      "~~~~",
      "````swift",
      "let marker = ```",
    ].join("\r\n")
    const parsed = parseBlockContent(markdown)!

    expect(parsed.blockContent.blocks.map(kind)).toEqual(["code", "code"])
    const first = parsed.blockContent.blocks[0]
    const second = parsed.blockContent.blocks[1]
    expect(textFor(markdown, first?.kind.oneofKind === "code" ? first.kind.code.text : undefined)).toBe("first")
    expect(textFor(markdown, second?.kind.oneofKind === "code" ? second.kind.code.text : undefined)).toBe(
      "let marker = ```",
    )
  })

  test("projects completed and streaming container fences through canonical code ranges", () => {
    const markdown = [
      "> ```ts",
      "> const first = true",
      "> ```",
      "> ```swift",
      "> let second = `value`",
    ].join("\n")
    const parsed = parseBlockContent(markdown)!
    const quote = parsed.blockContent.blocks[0]

    expect(quote?.kind.oneofKind).toBe("quote")
    expect(quote?.kind.oneofKind === "quote" ? quote.kind.quote.children.map(kind) : []).toEqual([
      "code",
      "code",
    ])
    const children = quote?.kind.oneofKind === "quote" ? quote.kind.quote.children : []
    expect(children.map((child) => textFor(markdown, child.kind.oneofKind === "code" ? child.kind.code.text : undefined)))
      .toEqual(["const first = true", "let second = `value`"])
  })

  test("all structural streaming prefixes remain deterministic and valid", () => {
    const markdown = [
      "## Result",
      "",
      "> quote",
      "",
      "| A | B |",
      "| --- | ---: |",
      "| one | two |",
      "",
      "<details>",
      '<summary kind="progress">Working</summary>',
      "````ts",
      "const marker = ```;",
      "````",
      "</details>",
    ].join("\n")

    for (let length = 1; length <= markdown.length; length++) {
      const prefix = markdown.slice(0, length)
      const first = parseBlockContent(prefix)
      const second = parseBlockContent(prefix)
      expect(second).toEqual(first)
      if (first) {
        expect(() => validateBlockContent(parseMarkdown(prefix).text, first.blockContent)).not.toThrow()
      }
    }
  })

  test("falls back to the legacy projection when table budgets are exceeded", () => {
    const header = `| ${Array.from({ length: 65 }, (_, index) => `h${index}`).join(" | ")} |`
    const delimiter = `| ${Array.from({ length: 65 }, () => "---").join(" | ")} |`
    const markdown = `${header}\n${delimiter}`

    expect(parseBlockContent(markdown)).toBeUndefined()
    expect(parseMarkdown(markdown).text).toBe(markdown)

    const boundedHeader = `| ${Array.from({ length: 16 }, (_, index) => `h${index}`).join(" | ")} |`
    const boundedDelimiter = `| ${Array.from({ length: 16 }, () => "---").join(" | ")} |`
    const rows = Array.from(
      { length: 16 },
      (_, row) => `| ${Array.from({ length: 16 }, (_, column) => `${row}:${column}`).join(" | ")} |`,
    )
    const tooManyCells = [boundedHeader, boundedDelimiter, ...rows].join("\n")

    expect(parseBlockContent(tooManyCells)).toBeUndefined()
    expect(parseMarkdown(tooManyCells).text).toBe(tooManyCells)
  })

  test("persisted tables retain the historical budget without relaxing native or structural validation", () => {
    const table = (rows: number, columns: number): BlockContent => ({
      blocks: [{
        kind: {
          oneofKind: "table",
          table: {
            alignments: Array.from({ length: columns }, () => BlockTable_Alignment.LEFT),
            rows: Array.from({ length: rows }, () => ({
              cells: Array.from({ length: columns }, () => ({ offset: 0n, length: 1n })),
            })),
          },
        },
      }],
    })
    const native = table(16, 16)
    expect(() => validateBlockContent("x", native)).not.toThrow()
    expect(() => validateBlockContent("x", native, "persisted")).not.toThrow()

    const historical = table(256, 16)
    expect(() => validateBlockContent("x", historical)).toThrow("Too many block table cells")
    expect(() => validateBlockContent("x", historical, "persisted")).not.toThrow()
    expect(() => encodeBlockContentToMarkdown({ text: "x", blockContent: historical })).not.toThrow()

    expect(() => validateBlockContent("x", table(256, 17), "persisted")).toThrow("Too many block table cells")
    expect(() => validateBlockContent("x", {
      blocks: [...historical.blocks, ...native.blocks],
    }, "persisted")).toThrow("Too many block table cells")
    expect(() => validateBlockContent("", historical, "persisted")).toThrow("Block text range exceeds message text")
    expect(() => validateBlockContent("x", table(257, 1), "persisted")).toThrow("Invalid block table dimensions")
    expect(() => validateBlockContent("x", table(1, 65), "persisted")).toThrow("Invalid block table dimensions")
  })

  test("canonical Markdown is semantically idempotent", () => {
    const markdown = [
      "## Result **now**",
      "",
      "3. first",
      "   - nested",
      "4. last",
      "",
      "<details open>",
      '<summary kind="progress">Checking</summary>',
      "```ts",
      "const value = 1",
      "```",
      "</details>",
      "",
      "<footer>Generated *safely*</footer>",
    ].join("\n")
    const flat = parseMarkdown(markdown)
    const decoded = parseBlockContent(markdown)!
    const encoded = encodeBlockContentToMarkdown({
      text: flat.text,
      entities: { entities: flat.entities },
      blockContent: decoded.blockContent,
    })
    const roundTripFlat = parseMarkdown(encoded)
    const roundTrip = parseBlockContent(encoded)!
    const encodedAgain = encodeBlockContentToMarkdown({
      text: roundTripFlat.text,
      entities: { entities: roundTripFlat.entities },
      blockContent: roundTrip.blockContent,
    })

    expect(encodedAgain).toBe(encoded)
    expect(roundTrip.blockContent.blocks.map(kind)).toEqual(decoded.blockContent.blocks.map(kind))
    expect(roundTripFlat.entities.map((entity) => entity.type)).toEqual(flat.entities.map((entity) => entity.type))
  })

  test("structural punctuation and adaptive code delimiters round-trip without loss", () => {
    const text = "# heading - item | cell <footer> [link](target) \\ `tick`"
    const paragraph = {
      blocks: [{
        kind: {
          oneofKind: "paragraph" as const,
          paragraph: { offset: 0n, length: BigInt(text.length), isRtl: false },
        },
      }],
    }
    const escaped = encodeBlockContentToMarkdown({ text, blockContent: paragraph })
    expect(parseMarkdown(escaped)).toEqual({ text, entities: [] })
    expect(encodeBlockContentToMarkdown({
      text: parseMarkdown(escaped).text,
      blockContent: parseBlockContent(escaped)!.blockContent,
    })).toBe(escaped)

    const inlineText = "value with ` tick"
    const encodedInline = encodeBlockContentToMarkdown({
      text: inlineText,
      entities: {
        entities: [{
          offset: 0n,
          length: BigInt(inlineText.length),
          type: MessageEntity_Type.CODE,
          entity: { oneofKind: undefined },
        }],
      },
      blockContent: {
        blocks: [{
          kind: {
            oneofKind: "paragraph",
            paragraph: { offset: 0n, length: BigInt(inlineText.length), isRtl: false },
          },
        }],
      },
    })
    expect(encodedInline).toBe("``value with ` tick``")
    expect(parseMarkdown(encodedInline).text).toBe(inlineText)

    const codeText = "const marker = ```;"
    const encodedCode = encodeBlockContentToMarkdown({
      text: codeText,
      blockContent: {
        blocks: [{
          kind: {
            oneofKind: "code",
            code: {
              text: { offset: 0n, length: BigInt(codeText.length) },
              language: "ts",
            },
          },
        }],
      },
    })
    expect(encodedCode.startsWith("````ts\n")).toBe(true)
    expect(parseMarkdown(encodedCode).text).toBe(codeText)
  })

  test("resolves and replaces image paths through disclosures and albums", () => {
    const markdown = [
      "<details>",
      "<summary>Images</summary>",
      "![one](https://example.com/one.png)",
      "![two](https://example.com/two.png)",
      "</details>",
    ].join("\n")
    const parsed = parseBlockContent(markdown)!
    const second = parsed.imageSources[1]
    expect(second).toBeDefined()
    const existing = getBlockImageAtPath(parsed.blockContent, second!.path)
    expect(existing?.state.oneofKind).toBe("pending")
    const replacement = {
      ...existing!,
      state: { oneofKind: "unavailable" as const, unavailable: {} },
    }
    expect(replaceBlockImageAtPath(parsed.blockContent, second!.path, replacement)).toBe(true)
    expect(getBlockImageAtPath(parsed.blockContent, second!.path)?.state.oneofKind).toBe("unavailable")
  })

  test("resolves and replaces image paths through block quotes", () => {
    const markdown = "> ![quoted](https://example.com/quoted.png)"
    const parsed = parseBlockContent(markdown)!
    expect(parsed.imageSources).toEqual([{ path: [0, 0], url: "https://example.com/quoted.png" }])
    const existing = getBlockImageAtPath(parsed.blockContent, [0, 0])
    expect(existing?.state.oneofKind).toBe("pending")
    expect(replaceBlockImageAtPath(parsed.blockContent, [0, 0], {
      ...existing!,
      state: { oneofKind: "unavailable", unavailable: {} },
    })).toBe(true)
  })
})
