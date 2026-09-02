import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, type BlockText, type MessageEntity } from "@inline-chat/protocol/core"
import { fromMd, toMd } from "../translation2/entities"
import { parseBlockContent, validateBlockContent } from "./blockContent"
import { encodeBlockContentToMarkdown } from "./blockContentMarkdown"
import { parseMarkdownWithSourceMap } from "./parseMarkdown"
import { processMessageText } from "./processText"
import { processOutgoingText } from "./processOutgoingText"

const entity = (type: MessageEntity_Type, start: number, length: number): MessageEntity => ({
  type, offset: BigInt(start), length: BigInt(length), entity: { oneofKind: undefined },
})
const displayMath = (start: number, length: number): MessageEntity => ({
  ...entity(MessageEntity_Type.MATH, start, length),
  entity: { oneofKind: "math", math: { display: true } },
})
const parsers = (source: string) => {
  const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
  return [main, { text: translated.text, entities: translated.entities.entities }]
}
const slice = (text: string, range: BlockText) => text.slice(Number(range.offset), Number(range.offset + range.length))

describe("canonical Markdown character references and literal export", () => {
  test("named, numeric, supplementary and multi-scalar references decode exactly once", () => {
    const source = "&copy; &amp;amp; &NotEqualTilde; &#x1F600; &#65; &#0; &#xD800; &#x110000;"
    for (const result of parsers(source)) {
      expect(result.text).toBe("© &amp; ≂̸ 😀 A � � �")
      expect(result.entities).toEqual([])
    }
    for (const source of ["&notanentity; &copy &CoPy;", "&#12345678; &#x1234567; &#-1; &#x;", "&" + "a".repeat(4_096) + ";"]) {
      for (const result of parsers(source)) expect(result.text).toBe(source)
    }
  })

  test("decoded markers stay text rather than being interpreted a second time", () => {
    const source = "&#42;&#42;literal&#42;&#42; &#36;x&#36; &#60;u&#62;text&#60;/u&#62;"
    for (const result of parsers(source)) {
      expect(result.text).toBe("**literal** $x$ <u>text</u>")
      expect(result.entities).toEqual([])
    }
    for (const result of parsers(String.raw`\&amp; \\&copy; &amp;amp;`)) {
      expect(result.text).toBe("&amp; \\" + "© &amp;")
    }
  })

  test("code, TeX, HTML attributes and literal autolink destinations remain opaque", () => {
    for (const result of parsers("before `&copy;` $x&copy;$ after")) {
      expect(result.text).toBe("before &copy; x&copy; after")
      expect(result.entities.filter((item) => item.type === MessageEntity_Type.CODE).map((item) => slice(result.text, item))).toEqual(["&copy;"])
      expect(result.entities.filter((item) => item.type === MessageEntity_Type.MATH).map((item) => slice(result.text, item))).toEqual(["x&copy;"])
    }
    const formula = "\n\\begin{matrix}x&copy;\\\\\n&#65;&y\\end{matrix}\n"
    for (const result of parsers("$$" + formula + "$$")) {
      expect(result.text).toBe(formula)
      expect(result.entities.map(({ type, offset, length }) => ({ type, offset, length }))).toEqual([
        { type: MessageEntity_Type.MATH, offset: 0n, length: BigInt(formula.length) },
      ])
    }
    expect(fromMd("$$" + formula + "$$").entities.entities).toEqual([displayMath(0, formula.length)])
    for (const source of ['a <b title="&copy;">&amp;</b>', '<div>\n&copy;\n</div>', '<https://e.test/&copy;>',
      'https://e.test/&copy;', 'https://e.test/&copy;&amp;', 'www.e.test/&copy;', 'https://e.test/a&amp;b=2']) {
      const expected = source.startsWith("a ") ? 'a <b title="&copy;">&</b>' : source
      for (const result of parsers(source)) expect(result.text).toBe(expected)
    }
  })

  test("link labels decode in their original scope while destinations retain their own decoding", () => {
    const source = '[**&#x1f600; &amp;**](https://e.test/?q=&#65; "&copy;")'
    for (const result of parsers(source)) {
      expect(result.text).toBe("😀 &")
      expect(result.entities.filter((item) => item.type === MessageEntity_Type.BOLD)).toEqual([entity(MessageEntity_Type.BOLD, 0, 4)])
      expect(result.entities.find((item) => item.type === MessageEntity_Type.TEXT_URL)?.entity)
        .toEqual({ oneofKind: "textUrl", textUrl: { url: "https://e.test/?q=A" } })
    }
    for (const result of parsers("[&#65;][id]\n\n[id]: https://e.test/?q=&amp;")) {
      expect(result.text).toBe("A\n\n")
      expect(result.entities.find((item) => item.type === MessageEntity_Type.TEXT_URL)?.entity)
        .toEqual({ oneofKind: "textUrl", textUrl: { url: "https://e.test/?q=&" } })
    }
    for (const result of parsers("[&#96;literal&#96;](https://e.test)")) {
      expect(result.text).toBe("`literal`")
      expect(result.entities.some((item) => item.type === MessageEntity_Type.CODE)).toBe(false)
    }
    for (const result of parsers("[https://e.test/&copy;](https://dest.test)")) expect(result.text).toBe("https://e.test/©")
    const imageSource = "![&#65;](https://e.test/a.png)", main = parseMarkdownWithSourceMap(imageSource)
    const image = parseBlockContent(imageSource, main)?.blockContent.blocks[0]?.kind
    expect(image?.oneofKind).toBe("image")
    if (image?.oneofKind === "image") expect(slice(main.text, image.image.alt!)).toBe("A")
  })

  test("UTF-16 source maps preserve explicit entities without splitting decoded scalars", () => {
    const source = "&#x1f600; **&amp;** @Maya"
    const mention: MessageEntity = { ...entity(MessageEntity_Type.MENTION, source.indexOf("@Maya"), 5),
      entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } }
    const result = processMessageText({ text: source, entities: { entities: [mention,
      entity(MessageEntity_Type.UNDERLINE, 0, 9), entity(MessageEntity_Type.HIGHLIGHT, 2, 2)] } })
    expect(result.text).toBe("😀 & @Maya")
    expect(result.entities?.entities.find((item) => item.type === MessageEntity_Type.MENTION)).toEqual({ ...mention, offset: 5n })
    expect(result.entities?.entities.find((item) => item.type === MessageEntity_Type.UNDERLINE)).toEqual(entity(MessageEntity_Type.UNDERLINE, 0, 2))
    expect(result.entities?.entities.some((item) => item.type === MessageEntity_Type.HIGHLIGHT)).toBe(false)
  })

  test("quotes and table cells use decoded ranges without changing their structure", () => {
    const source = "> &#x1f600;\n> &copy;\n\n| A &amp; B | &#65; |\n| --- | --- |\n| &#32; x | <u>&#x1f680;</u> |"
    const main = parseMarkdownWithSourceMap(source), rich = parseBlockContent(source, main)!
    expect(fromMd(source).text).toBe(main.text)
    expect(() => validateBlockContent(main.text, rich.blockContent)).not.toThrow()
    const quote = rich.blockContent.blocks[0]?.kind, table = rich.blockContent.blocks[1]?.kind
    expect(quote?.oneofKind).toBe("quote")
    if (quote?.oneofKind === "quote") {
      const body = quote.quote.children[0]?.kind
      expect(body?.oneofKind === "paragraph" && slice(main.text, body.paragraph)).toBe("😀\n©")
    }
    expect(table?.oneofKind).toBe("table")
    if (table?.oneofKind === "table") expect(table.table.rows.map((row) => row.cells.map((cell) => slice(main.text, cell))))
      .toEqual([["A & B", "A"], ["  x", "🚀"]])
  })

  test("native literal indentation, prefixes and reference-looking text round-trip exactly", () => {
    for (const text of ["- first\n  second", "    indentation", "plain\n\n    indented", "\tfirst\n\t second",
      "  😀\r\n   é\r\t𐐀", "# heading\n1. item\n   continuation", "word\n---\nword", "&copy; &amp; &#65;",
      String.raw`\&copy; <u>x</u> **literal**`, "| A | B |\n| - | - |\n| X | Y |", "   \n\t\n  end"]) {
      for (const result of parsers(toMd(text, undefined))) {
        expect(result.text).toBe(text)
        expect(result.entities).toEqual([])
      }
    }
  })

  test("native entity boundaries do not change the meaning of line-start escaping", () => {
    for (const newline of ["\n", "\r", "\r\n"]) {
      const text = "    bold" + newline + "\tMaya &copy;"
      const bold = entity(MessageEntity_Type.BOLD, 4, 4)
      const mention: MessageEntity = { ...entity(MessageEntity_Type.MENTION, text.indexOf("Maya"), 4),
        entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } }
      const entities = { entities: [bold, mention] }, before = structuredClone(entities)
      const markdown = toMd(text, entities), translated = fromMd(markdown)
      expect(translated).toEqual({ text, entities })
      expect(parseMarkdownWithSourceMap(markdown).text).toBe(text)
      expect(entities).toEqual(before)
    }
  })

  test("paragraph block export cannot turn its literal indentation into a code block", () => {
    const text = "    literal &copy;\n\tcontinued", range = { offset: 0n, length: BigInt(text.length) }
    const markdown = encodeBlockContentToMarkdown({ text,
      blockContent: { blocks: [{ kind: { oneofKind: "paragraph", paragraph: range } }] },
    })
    const main = parseMarkdownWithSourceMap(markdown)
    expect(main.text).toBe(text)
    expect(main.entities).toEqual([])
    expect(parseBlockContent(markdown, main)?.blockContent.blocks.map((block) => block.kind.oneofKind)).toEqual(["paragraph"])
  })

  test("parseMarkdown=false continues to preserve literal references and whitespace", async () => {
    const text = "    &copy; &#32; **literal**"
    const result = await processOutgoingText({ text, parseMarkdown: false, entities: undefined })
    expect(result.text).toBe(text)
    expect(result.entities).toBeUndefined()
    expect(result.blockContent).toBeUndefined()
  })

  test("streamed reference prefixes keep monotonic maps and bounded entity ranges", () => {
    for (const source of ["😀 **&#x1f680; &NotEqualTilde;** @Maya", "[<u>&amp;</u>][id]\n\n[id]: https://e.test",
      "> &#32;first\n> &#9;second", "| &#65; | &amp; |\n| --- | --- |\n| x | &#x1F600; |", "&amp;amp; &#12345678;"]) {
      for (let end = 0; end <= source.length; end++) {
        const prefix = source.slice(0, end), parsed = parseMarkdownWithSourceMap(prefix)
        expect(parsed.sourceToOutput).toHaveLength(prefix.length + 1)
        expect(parsed.sourceToOutput.at(-1)).toBe(parsed.text.length)
        expect(parsed.sourceToOutput.every((offset, index, map) => Number.isInteger(offset) && offset >= (map[index - 1] ?? 0))).toBe(true)
        for (const result of parsers(prefix)) expect(result.entities.every((item) => item.offset >= 0n && item.length > 0n
          && item.offset + item.length <= BigInt(result.text.length))).toBe(true)
      }
    }
  })
})
