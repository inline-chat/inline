import { describe, expect, test } from "bun:test"
import { MessageEntities, MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { fromMd, toMd } from "../translation2/entities"
import { parseMarkdown, parseMarkdownWithSourceMap } from "./parseMarkdown"
import { encodeBlockContentToMarkdown } from "./blockContentMarkdown"

const style = (type: MessageEntity_Type, offset: number, length: number): MessageEntity => ({
  type, offset: BigInt(offset), length: BigInt(length), entity: { oneofKind: undefined },
})
const sorted = (entities: MessageEntity[]) => [...entities].sort((a, b) => Number(a.offset - b.offset) || a.type - b.type)
const parsers = [parseMarkdown, (markdown: string) => {
  const parsed = fromMd(markdown)
  return { text: parsed.text, entities: parsed.entities.entities }
}]

describe("rich text v2 inline styles", () => {
  test("appends wire values and preserves range-only style entities through protobuf", () => {
    expect([MessageEntity_Type.UNDERLINE, MessageEntity_Type.STRIKETHROUGH, MessageEntity_Type.HIGHLIGHT]).toEqual([15, 16, 17])
    const entities = { entities: [style(MessageEntity_Type.UNDERLINE, 2, 5), style(MessageEntity_Type.STRIKETHROUGH, 3, 4), style(MessageEntity_Type.HIGHLIGHT, 4, 3)] }
    expect(MessageEntities.fromBinary(MessageEntities.toBinary(entities))).toEqual(entities)
  })

  test("both parsers retain Unicode offsets for the three styles", () => {
    for (const parse of parsers) {
      const parsed = parse("😀 <u>under</u> ~~strike~~ ==mark==")
      expect(parsed.text).toBe("😀 under strike mark")
      expect(sorted(parsed.entities)).toEqual([
        style(MessageEntity_Type.UNDERLINE, 3, 5),
        style(MessageEntity_Type.STRIKETHROUGH, 9, 6),
        style(MessageEntity_Type.HIGHLIGHT, 16, 4),
      ])
    }
  })

  test("nested styles round-trip together without losing existing bold", () => {
    const entities = [MessageEntity_Type.BOLD, MessageEntity_Type.UNDERLINE, MessageEntity_Type.STRIKETHROUGH, MessageEntity_Type.HIGHLIGHT]
      .map((type) => style(type, 0, 1))
    const markdown = toMd("x", { entities })
    for (const parse of parsers) {
      const parsed = parse(markdown)
      expect(parsed.text).toBe("x")
      expect(sorted(parsed.entities)).toEqual(entities)
    }
    expect(parseMarkdown("**bold**").entities).toEqual([style(MessageEntity_Type.BOLD, 0, 4)])
  })

  test("the conservative dialect keeps Telegram and established Inline meanings distinct", () => {
    for (const parse of parsers) {
      expect(parse("~single~")).toEqual({ text: "~single~", entities: [] })
      expect(parse("**bold**")).toEqual({ text: "bold", entities: [style(MessageEntity_Type.BOLD, 0, 4)] })
      expect(parse("<u>under</u>")).toEqual({ text: "under", entities: [style(MessageEntity_Type.UNDERLINE, 0, 5)] })
    }
  })

  test("block Markdown export uses the same nested styles and preserves Agent mention payloads", () => {
    const text = "😀 Maya"
    const entities = [MessageEntity_Type.UNDERLINE, MessageEntity_Type.STRIKETHROUGH, MessageEntity_Type.HIGHLIGHT]
      .map((type) => style(type, 3, 4))
    entities.push({ ...style(MessageEntity_Type.MENTION, 3, 4), entity: {
      oneofKind: "mention", mention: { userId: 42n, agentId: 7n },
    } })
    const markdown = encodeBlockContentToMarkdown({
      text, entities: { entities },
      blockContent: { blocks: [{ kind: { oneofKind: "paragraph", paragraph: { offset: 0n, length: 7n } } }] },
    })
    const decoded = fromMd(markdown)
    expect(decoded.text).toBe(text)
    expect(sorted(decoded.entities.entities)).toEqual(sorted(entities))
  })

  test("style syntax is shielded in code and escaped literal text", () => {
    const literal = "~~no~~ ==no== <u>no</u>"
    for (const parse of parsers) {
      expect(parse("`" + literal + "`")).toEqual({ text: literal, entities: [style(MessageEntity_Type.CODE, 0, literal.length)] })
      expect(parse(String.raw`\~~no\~~ \==no\== \<u>no\</u>`)).toEqual({ text: literal, entities: [] })
    }
    expect(fromMd(toMd(literal, undefined))).toEqual({ text: literal, entities: { entities: [] } })
  })

  test("styles remain in link labels while destinations remain unchanged", () => {
    for (const parse of parsers) {
      const label = parse("[<u>==go==</u>](https://example.com/a==b)")
      expect(label.text).toBe("go")
      expect(sorted(label.entities)).toEqual([
        { ...style(MessageEntity_Type.TEXT_URL, 0, 2), entity: { oneofKind: "textUrl", textUrl: { url: "https://example.com/a==b" } } },
        style(MessageEntity_Type.UNDERLINE, 0, 2),
        style(MessageEntity_Type.HIGHLIGHT, 0, 2),
      ])
      const outer = parse("~~[go](https://example.com/a~~b) end~~")
      expect(outer.text).toBe("go end")
      expect(sorted(outer.entities)).toEqual([
        { ...style(MessageEntity_Type.TEXT_URL, 0, 2), entity: { oneofKind: "textUrl", textUrl: { url: "https://example.com/a~~b" } } },
        style(MessageEntity_Type.STRIKETHROUGH, 0, 6),
      ])
    }
  })

  test("a code span inside styling protects delimiter-looking code", () => {
    for (const parse of parsers) {
      const parsed = parse("~~a `~~` z~~")
      expect(parsed.text).toBe("a ~~ z")
      expect(sorted(parsed.entities)).toEqual([style(MessageEntity_Type.STRIKETHROUGH, 0, 6), style(MessageEntity_Type.CODE, 2, 2)])
    }
  })

  test("unrepresentable native code preserves visible text without emitting corrupt delimiters", () => {
    for (const literal of ["`", "`leading", "trailing`", "first\n\nsecond", "first\n# heading", "first\n---\nlast",
      "a\n===\nb", "a\n<div>\nb", "a\n~~~\nb", "a\n1) b", "a\nb``c"]) {
      const markdown = toMd(literal, { entities: [style(MessageEntity_Type.CODE, 0, literal.length)] })
      for (const parse of parsers) {
        const parsed = parse(markdown)
        expect(parsed.text).toBe(literal)
        expect(parsed.entities.some((item) => item.type === MessageEntity_Type.CODE)).toBe(false)
      }
    }
  })

  test("duplicate multiline code validates one selected source range without changing neighbors", () => {
    for (const body of ["a\nb", "a\n===\nb"]) {
      const text = `${body} after`
      const entities = Array.from({ length: 8_192 }, () => style(MessageEntity_Type.CODE, 0, body.length))
      entities.push(style(MessageEntity_Type.BOLD, body.length + 1, 5))
      const markdown = toMd(text, { entities })
      for (const parse of parsers) {
        const result = parse(markdown)
        expect(result.text).toBe(text)
        expect(result.entities.filter((item) => item.type === MessageEntity_Type.CODE)).toHaveLength(body === "a\nb" ? 1 : 0)
        expect(result.entities.filter((item) => item.type === MessageEntity_Type.BOLD))
          .toEqual([style(MessageEntity_Type.BOLD, body.length + 1, 5)])
      }
    }
  })

  test("unfinished streaming prefixes stay literal and closed spans map visible source ranges", () => {
    for (const markdown of ["<u>x</u>", "~~x~~", "==x=="]) {
      for (let end = 1; end < markdown.length; end++) {
        const prefix = markdown.slice(0, end)
        for (const parse of parsers) expect(parse(prefix)).toEqual({ text: prefix, entities: [] })
      }
      const parsed = parseMarkdownWithSourceMap(markdown)
      const start = markdown.indexOf("x")
      expect(parsed.sourceToOutput[start]).toBe(0)
      expect(parsed.sourceToOutput[start + 1]).toBe(1)
    }
  })

  test("deep nesting is bounded and block-only extension tags remain literal inside inline styles", () => {
    const deep = "<u>".repeat(80) + "x" + "</u>".repeat(80)
    for (const parse of parsers) expect(parse(deep).text).toContain("x")
    expect(parseMarkdown("**<footer>x</footer>**").text).toBe("<footer>x</footer>")
    expect(parseMarkdown("<u><footer>x</footer></u>").text).toBe("<footer>x</footer>")
  })
})
