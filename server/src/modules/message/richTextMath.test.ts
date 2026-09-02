import { describe, expect, spyOn, test } from "bun:test"
import { BlockContent, MessageEntities, MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { fromMd, toMd } from "../translation2/entities"
import { mathLimits } from "../translation2/entities/math"
import { mathOutputRanges, parseMarkdown, parseMarkdownWithSourceMap } from "./parseMarkdown"
import { parseBlockContent, projectLiteralMathContent, validateBlockContent } from "./blockContent"
import { encodeBlockContentToMarkdown } from "./blockContentMarkdown"
import { processMessageText } from "./processText"
import { encodeBotEntities } from "../../controllers/bot/entityCodec"
import { encodeBotRichMessage } from "../../controllers/bot/richContent"
import { db } from "../../db"
import { processOutgoingText } from "./processOutgoingText"

const entity = (type: MessageEntity_Type, offset: number, length: number): MessageEntity => ({
  type, offset: BigInt(offset), length: BigInt(length), entity: { oneofKind: undefined },
})
const displayMath = (offset: number, length: number): MessageEntity => ({
  ...entity(MessageEntity_Type.MATH, offset, length),
  entity: { oneofKind: "math", math: { display: true } },
})
const parsers = [parseMarkdown, (markdown: string) => {
  const parsed = fromMd(markdown)
  return { text: parsed.text, entities: parsed.entities.entities }
}]

describe("rich text v2 math source contract", () => {
  test("literal native math receives a paragraph projection without parsing Markdown or resolving inside TeX", async () => {
    const formula = String.raw`\text{@not_a_real_user /not_a_command **x**} + x_1`
    const text = `😀 **literal** <u>literal</u> ${formula} ![literal](https://example.com/image.png)`
    const entities = { entities: [entity(MessageEntity_Type.MATH, text.indexOf(formula), formula.length)] }
    for (const parseMarkdown of [undefined, false]) {
      const result = await processOutgoingText({ text, entities, parseMarkdown })
      expect(result.text).toBe(text)
      expect(result.entities).toEqual(entities)
      expect(result.blockImageSources).toEqual([])
      expect(result.blockContent?.blocks).toEqual([{
        kind: { oneofKind: "paragraph", paragraph: { offset: 0n, length: BigInt(text.length), isRtl: false } },
      }])
      expect(() => validateBlockContent(result.text, result.blockContent!)).not.toThrow()
    }
    expect((await processOutgoingText({ text: "**literal**", entities: undefined, parseMarkdown: false })).blockContent).toBeUndefined()
  })

  test("display intent survives Markdown and native entity sends only when the formula owns its line", async () => {
    const markdown = "before\n$$x$$\nafter"
    const parsed = await processOutgoingText({ text: markdown, entities: undefined, parseMarkdown: true })
    expect(parsed.text).toBe("before\nx\nafter")
    expect(parsed.entities?.entities).toContainEqual(displayMath(7, 1))
    expect(parsed.blockContent?.blocks.map((block) => block.kind.oneofKind)).toEqual(["paragraph", "math", "paragraph"])

    const literal = await processOutgoingText({
      text: parsed.text,
      entities: parsed.entities,
      parseMarkdown: false,
    })
    expect(literal.entities).toEqual(parsed.entities)
    expect(literal.blockContent).toEqual(parsed.blockContent)

    const mixed = await processOutgoingText({
      text: "prefix x suffix",
      entities: { entities: [displayMath(7, 1)] },
      parseMarkdown: false,
    })
    expect(mixed.entities?.entities).toEqual([entity(MessageEntity_Type.MATH, 7, 1)])
    expect(mixed.blockContent?.blocks.map((block) => block.kind.oneofKind)).toEqual(["paragraph"])
  })

  test("literal math projection rejects malformed ranges and gives code precedence", () => {
    const text = "😀 x"
    for (const [offset, length] of [[-1n, 1n], [0n, 0n], [1n, 1n], [0n, 1n], [3n, 99n], [2n ** 63n, 1n]]) {
      expect(projectLiteralMathContent(text, { entities: [{
        type: MessageEntity_Type.MATH, offset: offset!, length: length!, entity: { oneofKind: undefined },
      }] })).toBeUndefined()
    }
    for (const type of [MessageEntity_Type.CODE, MessageEntity_Type.PRE]) {
      expect(projectLiteralMathContent(text, { entities: [entity(MessageEntity_Type.MATH, 3, 1), entity(type, 0, text.length)] })).toBeUndefined()
    }
    const source = "x".repeat(131_073)
    expect(projectLiteralMathContent(source, { entities: [entity(MessageEntity_Type.MATH, 0, 1)] })).toBeUndefined()
  })

  test("literal URLs retain dollar bytes and surrounding formatting", () => {
    for (const source of ["https://e.co/$x$", "www.example.com/?q=$x$", "https://e.co/(path)/$x$?q=2"]) {
      for (const parse of parsers) {
        const output = parse(`**${source}** $y$`)
        expect(output.text).toBe(`${source} y`)
        expect(output.entities.filter((value) => value.type === MessageEntity_Type.MATH)).toEqual([
          entity(MessageEntity_Type.MATH, source.length + 1, 1),
        ])
      }
    }
    const url = "https://e.co/x"
    const exported = toMd(url, { entities: [entity(MessageEntity_Type.MATH, url.length - 1, 1)] })
    for (const parse of parsers) expect(parse(exported).text).toBe(url)
  })

  test("display validation rejects empty, whitespace and split-surrogate source without interpreting TeX", () => {
    const blocks = (offset: bigint, length: bigint): BlockContent => ({
      blocks: [{ kind: { oneofKind: "math", math: { offset, length } } }],
    })
    for (const profile of ["native", "persisted"] as const) {
      expect(() => validateBlockContent("", blocks(0n, 0n), profile)).toThrow("Math source is empty")
      expect(() => validateBlockContent(" \n", blocks(0n, 2n), profile)).toThrow("Math source is empty")
      expect(() => validateBlockContent("😀x", blocks(1n, 2n), profile)).toThrow("Block text range splits a Unicode scalar")
      expect(() => validateBlockContent("😀x", blocks(0n, 1n), profile)).toThrow("Block text range splits a Unicode scalar")
      expect(() => validateBlockContent("😀x", blocks(0n, 3n), profile)).not.toThrow()
      expect(() => validateBlockContent(String.raw`\unknown{`, blocks(0n, 9n), profile)).not.toThrow()
    }
  })

  test("appends math wire values and preserves canonical source ranges", () => {
    expect(MessageEntity_Type.MATH).toBe(18)
    const entities = { entities: [entity(MessageEntity_Type.MATH, 3, 5)] }
    expect(MessageEntities.fromBinary(MessageEntities.toBinary(entities))).toEqual(entities)
    const blocks: BlockContent = { blocks: [{ kind: { oneofKind: "math", math: { offset: 3n, length: 5n } } }] }
    expect(BlockContent.fromBinary(BlockContent.toBinary(blocks))).toEqual(blocks)
    const display = { entities: [displayMath(3, 5)] }
    expect(MessageEntities.fromBinary(MessageEntities.toBinary(display))).toEqual(display)
  })

  test("TeX is opaque to formatting, links, code, and literal entity detectors", () => {
    const source = String.raw`\frac{a_b}{c^2} + \text{**x** <u>y</u> ~~z~~ ==w== [q](https://e.co) a@b.co @bob}`
    for (const parse of parsers) {
      expect(parse(`😀 $${source}$ end`)).toEqual({
        text: `😀 ${source} end`, entities: [entity(MessageEntity_Type.MATH, 3, source.length)],
      })
    }
  })

  test("outer formatting does not close on delimiters inside TeX", () => {
    for (const [open, close, type] of [
      ["**", "**", MessageEntity_Type.BOLD], ["*", "*", MessageEntity_Type.ITALIC],
      ["<u>", "</u>", MessageEntity_Type.UNDERLINE], ["~~", "~~", MessageEntity_Type.STRIKETHROUGH],
      ["==", "==", MessageEntity_Type.HIGHLIGHT],
    ] as const) {
      const source = String.raw`\text{** * </u> ~~ ==}`
      const text = `a ${source} z`
      for (const parse of parsers) {
        const result = parse(`${open}a $${source}$ z${close}`)
        expect(result.text).toBe(text)
        expect(result.entities).toContainEqual(entity(type, 0, text.length))
        expect(result.entities).toContainEqual(entity(MessageEntity_Type.MATH, 2, source.length))
        expect(result.entities).toHaveLength(2)
      }
    }
  })

  test("link labels can contain TeX brackets and destinations stay unchanged", () => {
    const source = String.raw`\left[x\right)`
    for (const parse of parsers) {
      const result = parse(`[$${source}$](https://e.co/$a$b)`)
      expect(result.text).toBe(source)
      expect(result.entities).toContainEqual(entity(MessageEntity_Type.MATH, 0, source.length))
      expect(result.entities).toContainEqual({ ...entity(MessageEntity_Type.TEXT_URL, 0, source.length),
        entity: { oneofKind: "textUrl", textUrl: { url: "https://e.co/$a$b" } },
      })
      expect(result.entities).toHaveLength(2)
    }
  })

  test("code shields dollars without swallowing later formulas", () => {
    for (const markdown of ["`$not math` $x$", "```txt\n$not math\n```\n$x$", "~~~txt\n$not math\n~~~\n$x$"]) {
      for (const parse of parsers) {
        const result = parse(markdown)
        const math = result.entities.filter((value) => value.type === MessageEntity_Type.MATH)
        expect(math).toEqual([entity(MessageEntity_Type.MATH, result.text.lastIndexOf("x"), 1)])
        expect(result.text).toContain("$not math")
        expect(result.entities.some((value) => value.type === MessageEntity_Type.CODE || value.type === MessageEntity_Type.PRE)).toBe(true)
      }
    }
  })

  test("code-looking text inside a formula does not mask following Markdown", () => {
    for (const parse of parsers) {
      const result = parse("$x`y$ **bold** `code`")
      expect(result.text).toBe("x`y bold code")
      expect(result.entities).toContainEqual(entity(MessageEntity_Type.MATH, 0, 3))
      expect(result.entities).toContainEqual(entity(MessageEntity_Type.BOLD, 4, 4))
      expect(result.entities).toContainEqual(entity(MessageEntity_Type.CODE, 9, 4))
    }
  })

  test("TeX does not enter Markdown fence normalization or disclosure state", () => {
    for (const source of ["\n```\nx\n``` (×2)\n", "\n<details>\n<summary>x</summary>\n"]) {
      expect(parseMarkdown(`$$${source}$$\nafter`)).toEqual({
        text: `${source}\nafter`, entities: [entity(MessageEntity_Type.MATH, 0, source.length)],
      })
    }
    expect(parseMarkdown("<footer>$x$</footer>")).toEqual({ text: "x", entities: [entity(MessageEntity_Type.MATH, 0, 1)] })
  })

  test("oversized complete formulas remain byte-for-byte literal", () => {
    const source = "x".repeat(mathLimits.inlineSource) + String.raw`**z** \_ [q](https://e.co)`
    for (const parse of parsers) expect(parse(`$${source}$`).text).toBe(`$${source}$`)
  })

  test("oversized formulas stay opaque through nested translation and outgoing source mapping", () => {
    const source = "x".repeat(mathLimits.inlineSource) + " a@b.co /cmd @bob"
    for (const wrapper of ["$", "<u>$", "**$"]) {
      const end = wrapper === "$" ? "$" : wrapper === "<u>$" ? "$</u>" : "$**"
      const markdown = wrapper + source + end
      const translated = fromMd(markdown)
      expect(translated.entities.entities.every((value) => value.type === MessageEntity_Type.BOLD || value.type === MessageEntity_Type.UNDERLINE)).toBe(true)
      const parsed = parseMarkdownWithSourceMap(markdown)
      const protectedRanges = mathOutputRanges(parsed)
      expect(protectedRanges).toHaveLength(1)
      expect(parsed.text.slice(protectedRanges[0]!.start, protectedRanges[0]!.end)).toBe(`$${source}$`)
    }
  })

  test("outgoing oversized TeX does not resolve usernames or fabricate commands", async () => {
    const source = "x".repeat(mathLimits.inlineSource) + " @bob /help"
    const markdown = `$${source}$`
    const select = spyOn(db, "select").mockImplementation(() => { throw new Error("Unexpected lookup inside TeX") })
    try {
      const result = await processOutgoingText({ text: markdown, entities: undefined, parseMarkdown: true })
      expect(result.text).toBe(markdown)
      expect(result.entities?.entities ?? []).toEqual([])
      expect(select).not.toHaveBeenCalled()
    } finally {
      select.mockRestore()
    }
  })

  test("literal dollars and pre-existing escaped parentheses round-trip as plain text", () => {
    const literal = String.raw`$x$ $$y$$ \(z\) [q]`
    for (const parse of parsers) expect(parse(toMd(literal, undefined))).toEqual({ text: literal, entities: [] })
    for (const parse of parsers) expect(parse(String.raw`\(x\) \[y\]`)).toEqual({ text: "(x) [y]", entities: [] })
  })

  test("export accounts for a following digit and keeps ambiguous adjacent formulas readable", () => {
    const single = { entities: [entity(MessageEntity_Type.MATH, 0, 1)] }
    expect(toMd("x2", single)).toBe("$$x$$2")
    for (const parse of parsers) expect(parse(toMd("x2", single))).toEqual({ text: "x2", entities: single.entities })
    const adjacent = { entities: [entity(MessageEntity_Type.MATH, 0, 1), entity(MessageEntity_Type.MATH, 1, 1)] }
    // Explicit v0.1 fallback: do not insert separators or persist raw dollar syntax.
    for (const parse of parsers) expect(parse(toMd("xy", adjacent))).toEqual({ text: "xy", entities: [] })
    const afterDollar = { entities: [entity(MessageEntity_Type.MATH, 1, 1)] }
    for (const parse of parsers) expect(parse(toMd("$x", afterDollar))).toEqual({ text: "$x", entities: afterDollar.entities })
  })

  test("ambiguous range-only math falls back without inventing display intent", () => {
    for (const { text, start, length } of [
      { text: "before\n\nx^2\ny^2\n\nafter", start: 8, length: 7 },
      { text: " x ", start: 0, length: 3 },
    ]) {
      const markdown = toMd(text, { entities: [entity(MessageEntity_Type.MATH, start, length)] })
      const decoded = fromMd(markdown)
      expect(decoded.text).toBe(text)
      expect(decoded.entities.entities).toEqual([])
    }
  })

  test("thread link labels shield TeX containing a double-bracket terminator", () => {
    const source = String.raw`\text{]](junk)}`
    const result = fromMd(`[[$${source}$]](inline://thread?id=1)`)
    expect(result.text).toBe(`[[${source}]]`)
    expect(result.entities.entities).toContainEqual(entity(MessageEntity_Type.MATH, 2, source.length))
    expect(result.entities.entities).toContainEqual({ ...entity(MessageEntity_Type.THREAD, 0, source.length + 4),
      entity: { oneofKind: "thread", thread: { chatId: 1n } },
    })
  })

  test("source mapping retains Unicode and remaps supplied entities only outside math", () => {
    const source = "😀 " + String.raw`$\text{@bob}$ Maya`
    const mention = (offset: number, length: number): MessageEntity => ({ ...entity(MessageEntity_Type.MENTION, offset, length),
      entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } },
    })
    const parsed = parseMarkdownWithSourceMap(source)
    const result = processMessageText({ text: source, parsedMarkdown: parsed, entities: { entities: [
      mention(source.indexOf("@bob"), 4), mention(source.indexOf("Maya"), 4),
    ] } })
    expect(result.text).toBe("😀 " + String.raw`\text{@bob} Maya`)
    expect(result.entities?.entities).toEqual([
      entity(MessageEntity_Type.MATH, 3, String.raw`\text{@bob}`.length), mention(result.text.indexOf("Maya"), 4),
    ])
    expect(parsed.sourceToOutput[source.indexOf("Maya")]).toBe(result.text.indexOf("Maya"))
  })

  test("display formulas project, validate, and export the exact TeX body", async () => {
    const body = String.raw`\begin{matrix}a&b\\c&d\end{matrix}`
    const markdown = `before\n\n$$\n${body}\n$$\n\nafter`
    const flat = parseMarkdownWithSourceMap(markdown)
    const parsed = parseBlockContent(markdown, flat)!
    expect(parsed.imageSources).toEqual([])
    expect(parsed.blockContent.blocks.map((block) => block.kind.oneofKind)).toEqual(["paragraph", "math", "paragraph"])
    const range = parsed.blockContent.blocks[1]!.kind
    expect(range.oneofKind).toBe("math")
    if (range.oneofKind !== "math") throw new Error("missing display math")
    expect(flat.text.slice(Number(range.math.offset), Number(range.math.offset + range.math.length))).toBe(`\n${body}\n`)
    expect(() => validateBlockContent(flat.text, parsed.blockContent)).not.toThrow()
    expect(encodeBlockContentToMarkdown({ text: flat.text, entities: { entities: flat.entities }, blockContent: parsed.blockContent })).toBe(markdown)
    expect(fromMd(markdown).entities.entities).toContainEqual(displayMath(Number(range.math.offset), Number(range.math.length)))
    const outgoing = await processOutgoingText({ text: markdown, entities: undefined, parseMarkdown: true })
    expect(outgoing.entities?.entities).toContainEqual(displayMath(Number(range.math.offset), Number(range.math.length)))
  })

  test("formatting cannot move display formulas out of block position", () => {
    const prefix = "before\n"
    const source = "\nformula\n"
    const suffix = "\nafter"
    const text = prefix + source + suffix
    for (const type of [MessageEntity_Type.BOLD, MessageEntity_Type.ITALIC, MessageEntity_Type.UNDERLINE,
      MessageEntity_Type.STRIKETHROUGH, MessageEntity_Type.HIGHLIGHT]) {
      for (const formatting of [entity(type, prefix.length, source.length), entity(type, 0, text.length)]) {
        const markdown = toMd(text, { entities: [formatting, displayMath(prefix.length, source.length)] })
        const flat = parseMarkdownWithSourceMap(markdown)
        const blocks = parseBlockContent(markdown, flat)?.blockContent.blocks ?? []
        expect(flat.text).toBe(text)
        expect(blocks.map((block) => block.kind.oneofKind)).toEqual(["paragraph", "math", "paragraph"])
        expect(flat.entities.filter((item) => item.type === MessageEntity_Type.MATH)).toEqual([
          entity(MessageEntity_Type.MATH, prefix.length, source.length),
        ])
      }
    }
  })

  test("mixed formulas stay one paragraph and TeX pipes do not split table cells", () => {
    const mixed = "prefix $$\n```\ncode\n```\n$$ suffix"
    const flat = parseMarkdownWithSourceMap(mixed)
    const parsed = parseBlockContent(mixed, flat)!
    expect(parsed.blockContent.blocks).toEqual([{ kind: { oneofKind: "paragraph", paragraph: { offset: 0n, length: BigInt(flat.text.length), isRtl: false } } }])
    const markdown = "| formula | tail |\n| --- | --- |\n| $|x|$ | end |"
    const tableText = parseMarkdownWithSourceMap(markdown)
    const table = parseBlockContent(markdown, tableText)!.blockContent.blocks[0]!.kind
    expect(table.oneofKind).toBe("table")
    if (table.oneofKind !== "table") throw new Error("missing table")
    expect(table.table.rows[1]!.cells).toHaveLength(2)
    const range = table.table.rows[1]!.cells[0]!
    expect(tableText.text.slice(Number(range.offset), Number(range.offset + range.length))).toBe("|x|")
  })

  test("Bot flat and rich output expose math with unchanged TeX", () => {
    const text = String.raw`\frac{a}{b}`
    const entities = { entities: [entity(MessageEntity_Type.MATH, 0, text.length)] }
    expect(encodeBotEntities(entities)).toEqual([{ type: "math", offset: 0, length: text.length }])
    const range = { offset: 0n, length: BigInt(text.length) }
    expect(encodeBotRichMessage({ text, entities, blockContent: { blocks: [
      { kind: { oneofKind: "paragraph", paragraph: range } }, { kind: { oneofKind: "math", math: range } },
    ] } })).toEqual({ blocks: [
      { type: "paragraph", text: { type: "math", text, latex: text } }, { type: "math", latex: text },
    ] })
  })
})
