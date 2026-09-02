import { describe, expect, test } from "bun:test"
import { BlockTable_Alignment, MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { fromMd, toMd } from "../translation2/entities"
import { inlineStyleTags } from "../translation2/entities/inlineStyles"
import { splitsSurrogatePair } from "../translation2/entities/offsets"
import { parseBlockContent, validateBlockContent } from "./blockContent"
import { encodeBlockContentToMarkdown } from "./blockContentMarkdown"
import { parseMarkdownWithSourceMap } from "./parseMarkdown"

const entity = (type: MessageEntity_Type, start: number, length: number): MessageEntity => ({
  type, offset: BigInt(start), length: BigInt(length), entity: { oneofKind: undefined },
})
const parsers = (markdown: string) => {
  const main = parseMarkdownWithSourceMap(markdown), translated = fromMd(markdown)
  return [main, { text: translated.text, entities: translated.entities.entities }]
}
const covered = (entities: MessageEntity[], type: MessageEntity_Type, offset: number) => entities.some((item) =>
  item.type === type && item.offset <= BigInt(offset) && BigInt(offset) < item.offset + item.length)

describe("native formatting at arbitrary scalar boundaries", () => {
  test("every valid selection in punctuation, whitespace, escaped syntax and Unicode preserves text and visible style coverage", () => {
    const samples = ["    abc", "&copy;", "x &amp; y", "- a\n  b", "a|b\n---", "😀 é", "*** literal",
      "&#32; end", "&#x1f600;", "&NotEqualTilde;", "a==b", "a~~b", "(i) x!", "\t a\r\n \t", "<u>x</u>"]
    for (const text of samples) for (const { type } of inlineStyleTags) {
      for (let start = 0; start < text.length; start++) for (let end = start + 1; end <= text.length; end++) {
        if (splitsSurrogatePair(text, start) || splitsSurrogatePair(text, end)) continue
        const source = { entities: [entity(type, start, end - start)] }, before = structuredClone(source)
        for (const result of parsers(toMd(text, source))) {
          expect(result.text).toBe(text)
          for (let offset = 0; offset < text.length; offset++) {
            // Multiline native styles are projected per physical line; the
            // separators themselves have no Markdown formatting representation.
            if (text[offset] === "\r" || text[offset] === "\n") continue
            expect(covered(result.entities, type, offset)).toBe(start <= offset && offset < end)
          }
        }
        expect(source).toEqual(before)
      }
    }
  })

  test("ordinary word formatting keeps its existing delimiter output", () => {
    expect(toMd("word", { entities: [entity(MessageEntity_Type.BOLD, 0, 4)] })).toBe("**word**")
    expect(toMd("word", { entities: [entity(MessageEntity_Type.ITALIC, 0, 4)] })).toBe("*word*")
    expect(toMd("word", { entities: [entity(MessageEntity_Type.BOLD, 0, 4), entity(MessageEntity_Type.ITALIC, 0, 4)] })).toBe("***word***")
    expect(toMd("word", { entities: [entity(MessageEntity_Type.STRIKETHROUGH, 0, 4)] })).toBe("~~word~~")
    expect(toMd("word", { entities: [entity(MessageEntity_Type.HIGHLIGHT, 0, 4)] })).toBe("==word==")
  })

  test("nested wrappers touching a parent boundary keep both style and Agent identity", () => {
    const text = "xaMayaZy"
    const mention: MessageEntity = { ...entity(MessageEntity_Type.MENTION, 2, 4),
      entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } }
    for (const type of [MessageEntity_Type.BOLD, MessageEntity_Type.ITALIC]) {
      for (const [start, length] of [[1, 5], [2, 5], [2, 4]]) {
        const style = entity(type, start!, length!)
        const markdown = toMd(text, { entities: [style, mention] })
        for (const result of parsers(markdown)) {
          expect(result.text).toBe(text)
          expect(result.entities.filter((item) => item.type === type)).toEqual([style])
        }
        expect(fromMd(markdown).entities.entities.filter((item) => item.type === MessageEntity_Type.MENTION)).toEqual([mention])
      }
    }
    for (const childType of [MessageEntity_Type.UNDERLINE, MessageEntity_Type.CODE, MessageEntity_Type.MATH]) {
      const outer = entity(MessageEntity_Type.BOLD, 1, 5), inner = entity(childType, 2, 4)
      for (const result of parsers(toMd(text, { entities: [outer, inner] }))) {
        expect(result.text).toBe(text)
        expect(result.entities.filter((item) => item.type === MessageEntity_Type.BOLD)).toEqual([outer])
        expect(result.entities.filter((item) => item.type === childType)).toEqual([inner])
      }
    }
  })

  test("only exact attribute-free formatting tags are interpreted", () => {
    for (const source of ['<b class="x">text</b>', "<B>text</B>", "<strong>text</strong>", "<b></b>",
      '<span title="<b>x</b>">literal</span>', "<span title='<u>x</u>'>literal</span>",
      '<span title="<b>**x** _y_ `z` $q$</b>">literal</span>',
      "<!--<mark>**x** _y_ `z` $q$</mark>-->",
      "<!--<mark>x</mark>-->", "<?test <i>x</i>?>", "<![CDATA[<s>x</s>]]>"]) {
      for (const result of parsers(source)) {
        expect(result.text).toBe(source)
        expect(result.entities).toEqual([])
      }
    }
    const body = 'before <span title="<b>x</b>"> after'
    for (const result of parsers("**" + body + "**")) {
      expect(result.text).toBe(body)
      expect(result.entities).toEqual([entity(MessageEntity_Type.BOLD, 0, body.length)])
    }
    for (const { type, open, close } of inlineStyleTags) {
      for (const body of ["!", " ", "\t  ", "😀", "\nword\n"]) {
        for (const result of parsers(open + body + close)) {
          expect(result.text).toBe(body)
          expect(result.entities).toEqual([entity(type, 0, body.length)])
        }
      }
    }
  })

  test("tags stay literal in code, TeX, escaped source and link destinations", () => {
    const tags = "<b>x</b><i>y</i><s>z</s><mark>q</mark>"
    for (const result of parsers("`" + tags + "`")) {
      expect(result.text).toBe(tags)
      expect(result.entities).toEqual([entity(MessageEntity_Type.CODE, 0, tags.length)])
    }
    for (const result of parsers("$x+" + tags + "$")) {
      expect(result.text).toBe("x+" + tags)
      expect(result.entities).toEqual([entity(MessageEntity_Type.MATH, 0, tags.length + 2)])
    }
    for (const result of parsers(toMd(tags, undefined))) {
      expect(result.text).toBe(tags)
      expect(result.entities).toEqual([])
    }
    const link: MessageEntity = { ...entity(MessageEntity_Type.TEXT_URL, 0, 1),
      entity: { oneofKind: "textUrl", textUrl: { url: "https://e.test/<b>x</b>" } } }
    for (const result of parsers(toMd("x", { entities: [link] }))) {
      expect(result.text).toBe("x")
      expect(result.entities).toEqual([link])
    }
    for (const result of parsers("`<span title='`**outside**'>")) {
      expect(result.text).toBe("<span title='outside'>")
      expect(result.entities).toEqual([entity(MessageEntity_Type.CODE, 0, 13), entity(MessageEntity_Type.BOLD, 13, 7)])
    }
  })

  test("table export retains punctuation and whitespace cell styles", () => {
    const text = "head !   ", span = (offset: number, length: number) => ({ offset: BigInt(offset), length: BigInt(length) })
    const markdown = encodeBlockContentToMarkdown({ text,
      entities: { entities: [entity(MessageEntity_Type.BOLD, 5, 1), entity(MessageEntity_Type.HIGHLIGHT, 7, 2)] },
      blockContent: { blocks: [{ kind: { oneofKind: "table", table: {
        alignments: [BlockTable_Alignment.UNSPECIFIED], rows: [{ cells: [span(0, 4)] }, { cells: [span(5, 1)] }, { cells: [span(7, 2)] }],
      } } }] },
    })
    const parsed = parseMarkdownWithSourceMap(markdown), rich = parseBlockContent(markdown, parsed)!
    expect(() => validateBlockContent(parsed.text, rich.blockContent)).not.toThrow()
    const table = rich.blockContent.blocks[0]?.kind
    expect(table?.oneofKind).toBe("table")
    if (table?.oneofKind === "table") expect(table.table.rows.map((row) => {
      const cell = row.cells[0]!
      return parsed.text.slice(Number(cell.offset), Number(cell.offset + cell.length))
    })).toEqual(["head", "!", "  "])
    expect(parsed.entities.filter((item) => item.type === MessageEntity_Type.BOLD).map((item) => parsed.text.slice(Number(item.offset), Number(item.offset + item.length)))).toEqual(["!"])
    expect(parsed.entities.filter((item) => item.type === MessageEntity_Type.HIGHLIGHT).map((item) => parsed.text.slice(Number(item.offset), Number(item.offset + item.length)))).toEqual(["  "])
  })

  test("partial and nested streamed tags keep valid source maps", () => {
    for (const source of ["x<b>!</b>y", "<b>A <i>!</i> Z</b>", "<mark> </mark>", '<span title="<b>x</b>">literal</span>',
      "<b>".repeat(35) + "x" + "</b>".repeat(35)]) {
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

  test("unfinished literal HTML comments shield inner Markdown until their closing token arrives", () => {
    for (const [open, close] of [["<!--", "-->"], ["<?", "?>"], ["<![CDATA[", "]]>"], ["<!DOCTYPE ", ">"]]) {
      const body = open === "<!DOCTYPE " ? "**bold** `code` $math$ &copy; " : "<b>**bold**</b> `code` $math$ &copy; "
      const source = open + body
      for (const result of parsers(source)) {
        expect(result.text).toBe(source)
        expect(result.entities).toEqual([])
      }
      const complete = source + close + "\n\n**after**"
      for (const result of parsers(complete)) {
        expect(result.text).toBe(source + close + "\n\nafter")
        expect(result.entities).toEqual([entity(MessageEntity_Type.BOLD, source.length + close!.length + 2, 5)])
      }
    }
    const source = "<!--".repeat(4096) + "<b>literal</b>"
    const parsed = parseMarkdownWithSourceMap(source)
    expect(parsed.text).toBe(source)
    expect(parsed.entities).toEqual([])
    expect(parsed.sourceToOutput.every((offset, index) => offset === index)).toBe(true)
  })
})
