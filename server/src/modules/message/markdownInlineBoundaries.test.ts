import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { fromMd } from "../translation2/entities/fromMarkdown"
import { parseMarkdownWithSourceMap } from "./parseMarkdown"
import { parseBlockContent, validateBlockContent } from "./blockContent"
import { processMessageText } from "./processText"

const formats = [
  { type: MessageEntity_Type.BOLD, open: "**", close: "**" },
  { type: MessageEntity_Type.ITALIC, open: "*", close: "*" },
  { type: MessageEntity_Type.UNDERLINE, open: "<u>", close: "</u>" },
  { type: MessageEntity_Type.STRIKETHROUGH, open: "~~", close: "~~" },
  { type: MessageEntity_Type.HIGHLIGHT, open: "==", close: "==" },
]
const values = (text: string, entities: MessageEntity[], type: MessageEntity_Type) => entities
  .filter((entity) => entity.type === type)
  .map((entity) => text.slice(Number(entity.offset), Number(entity.offset + entity.length)))
const parsers = (source: string) => {
  const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
  return [main, { text: translated.text, entities: translated.entities.entities }]
}

describe("shared inline surface boundaries", () => {
  test("styles, links, and code cannot pair delimiters in separate table cells", () => {
    for (const format of [...formats, { type: MessageEntity_Type.CODE, open: "`", close: "`" },
      { type: MessageEntity_Type.TEXT_URL, open: "[", close: "](https://e.test)" }]) {
      const source = `| ${format.open}first | second${format.close} |\n| --- | --- |\n| a | b |`
      for (const result of parsers(source)) {
        expect(result.text).toBe(source)
        expect(values(result.text, result.entities, format.type)).toEqual([])
      }
      const parsed = parseMarkdownWithSourceMap(source), rich = parseBlockContent(source, parsed)!
      expect(rich.blockContent.blocks[0]?.kind.oneofKind).toBe("table")
      expect(() => validateBlockContent(parsed.text, rich.blockContent)).not.toThrow()
    }
  })

  test("an unmatched opener in one cell cannot swallow valid styling in the next", () => {
    for (const format of formats) {
      const source = `| ${format.open}broken | ${format.open}valid${format.close} |\n| --- | --- |\n| a | b |`
      for (const result of parsers(source)) {
        expect(values(result.text, result.entities, format.type)).toEqual(["valid"])
        expect(result.text).toBe(`| ${format.open}broken | valid |\n| --- | --- |\n| a | b |`)
      }
    }
  })

  test("all styles stay within a paragraph or heading for every line ending", () => {
    for (const format of formats) for (const ending of ["\n", "\r", "\r\n"]) {
      for (const separator of [`${ending}${ending}`, `${ending}# `, `${ending}- `]) {
        const source = `${format.open}first${separator}second${format.close}`
        for (const result of parsers(source)) {
          expect(values(result.text, result.entities, format.type)).toEqual([])
          expect(result.text).toBe(source)
        }
      }
    }
  })

  test("valid multiline styles and nested labels keep their container context", () => {
    for (const format of formats.slice(2)) for (const ending of ["\n", "\r", "\r\n"]) {
      const source = `> [${format.open}😀 first${ending}> second${format.close}](https://e.test)`
      for (const result of parsers(source)) {
        expect(result.text).toBe(`> 😀 first${ending}second`)
        expect(values(result.text, result.entities, format.type)).toEqual([`😀 first${ending}second`])
        expect(values(result.text, result.entities, MessageEntity_Type.TEXT_URL)).toEqual([`😀 first${ending}second`])
      }
    }
  })

  test("standalone underline tags neither hide headings nor rewrite code or TeX", () => {
    for (const source of ["<u>\nfirst\nsecond\n</u>", "> <u>\n> first\n> second\n> </u>", "<u>\n`literal <u>`\n</u>"]) {
      const [main, translated] = parsers(source)
      expect(main!.text).toBe(translated!.text)
      expect(values(main!.text, main!.entities, MessageEntity_Type.UNDERLINE)).toHaveLength(1)
      expect(values(translated!.text, translated!.entities, MessageEntity_Type.UNDERLINE)).toHaveLength(1)
      expect(main!.text).not.toContain("xxx")
    }
    for (const source of ["<u>\nfirst\n# second\n</u>", "> <u>\n> first\n> # second\n> </u>"]) {
      for (const result of parsers(source)) {
        expect(values(result.text, result.entities, MessageEntity_Type.UNDERLINE)).toEqual([])
        expect(result.text).toContain("<u>")
        expect(result.text).toContain("</u>")
      }
    }
    for (const source of ["```tex\n<u>\n```", "$$\n<u>\n$$"]) {
      for (const result of parsers(source)) {
        expect(result.text).toContain("<u>")
        expect(result.text).not.toContain("xxx")
      }
    }
  })

  test("math pipes do not create false cell boundaries or lose neighboring styles", () => {
    const source = "| ==$a|b$== | <u>right</u> |\n| --- | --- |\n| x | y |"
    for (const result of parsers(source)) {
      expect(values(result.text, result.entities, MessageEntity_Type.MATH)).toEqual(["a|b"])
      expect(values(result.text, result.entities, MessageEntity_Type.HIGHLIGHT)).toEqual(["a|b"])
      expect(values(result.text, result.entities, MessageEntity_Type.UNDERLINE)).toEqual(["right"])
    }
    const parsed = parseMarkdownWithSourceMap(source), rich = parseBlockContent(source, parsed)!
    expect(rich.blockContent.blocks[0]?.kind.oneofKind).toBe("table")
    expect(() => validateBlockContent(parsed.text, rich.blockContent)).not.toThrow()
  })

  test("unsupported HTML blocks do not expose hidden formatting or code spans", () => {
    const source = "<div>\n**bold** *italic* <u>under</u> ~~strike~~ ==mark== `code`\n</div>"
    for (const result of parsers(source)) {
      expect(result.text).toBe(source)
      expect(result.entities).toEqual([])
    }
  })

  test("table styles and explicit Agent mentions share correct UTF-16 maps", () => {
    const source = "| 😀 | <u>@Maya</u> |\n| --- | --- |\n| a | b |"
    const entity: MessageEntity = { type: MessageEntity_Type.MENTION, offset: BigInt(source.indexOf("@Maya")), length: 5n,
      entity: { oneofKind: "mention", mention: { userId: 4n, agentId: 8n } } }
    const parsed = processMessageText({ text: source, entities: { entities: [entity] } })
    expect(values(parsed.text, parsed.entities!.entities, MessageEntity_Type.MENTION)).toEqual(["@Maya"])
    expect(values(parsed.text, parsed.entities!.entities, MessageEntity_Type.UNDERLINE)).toEqual(["@Maya"])
    expect(parsed.entities!.entities.find((item) => item.type === MessageEntity_Type.MENTION)?.entity).toEqual(entity.entity)
  })

  test("streaming a table or standalone style retains valid source and entity ranges", () => {
    for (const source of ["| ==first | ==second== |\n| --- | --- |\n| 😀 | x |", "<u>\nfirst\n# second\n</u>"]) {
      for (let end = 0; end <= source.length; end++) {
        const prefix = source.slice(0, end), parsed = parseMarkdownWithSourceMap(prefix)
        expect(parsed.sourceToOutput).toHaveLength(prefix.length + 1)
        expect(parsed.sourceToOutput.at(-1)).toBe(parsed.text.length)
        expect(parsed.sourceToOutput.every((offset, index, map) => Number.isInteger(offset) && offset >= (map[index - 1] ?? 0))).toBe(true)
        for (const result of parsers(prefix)) {
          expect(result.entities.every((entity) => entity.offset >= 0n && entity.length > 0n && entity.offset + entity.length <= BigInt(result.text.length))).toBe(true)
        }
      }
    }
  })
})
