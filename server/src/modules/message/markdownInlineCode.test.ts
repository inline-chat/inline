import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { fromMd } from "../translation2/entities/fromMarkdown"
import { parseBlockContent, validateBlockContent } from "./blockContent"
import { parseMarkdownWithSourceMap } from "./parseMarkdown"
import { processMessageText } from "./processText"
import { richMarkdownAst } from "./markdownAst"
import type { Nodes } from "mdast"

const values = (text: string, entities: MessageEntity[], type = MessageEntity_Type.CODE) => entities
  .filter((entity) => entity.type === type)
  .map((entity) => text.slice(Number(entity.offset), Number(entity.offset + entity.length)))

describe("shared multiline inline code", () => {
  test("keeps code whitespace and literal syntax across lines and containers", () => {
    const cases: [string, string][] = [
      ["before `first\nsecond` after", "first\nsecond"],
      ["> `first\n> second`", "first\nsecond"],
      ["> > `first\n> > second`", "first\nsecond"],
      ["- `first\n  second`", "first\nsecond"],
      ["> - `first\n>   second`", "first\nsecond"],
      ["before ` \n x \n ` after", " \n x \n "],
      ["before `\n` after", "\n"],
      ["before ``first ` tick\nsecond`` after", "first ` tick\nsecond"],
      ["before `😀 é\n\0last` after", "😀 é\n\0last"],
      ["before `**bold** $x$\n[u][id] ![i](https://e.test/i)` after\n\n[id]: https://e.test", "**bold** $x$\n[u][id] ![i](https://e.test/i)"],
    ]
    for (const [source, expected] of cases) {
      const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
      expect(values(main.text, main.entities)).toEqual([expected])
      expect(values(translated.text, translated.entities.entities)).toEqual([expected])
      expect(main.text).toBe(translated.text)
      expect(main.entities.map((entity) => entity.type)).toEqual([MessageEntity_Type.CODE])
      expect(translated.entities.entities.map((entity) => entity.type)).toEqual([MessageEntity_Type.CODE])
      expect(main.sourceToOutput).toHaveLength(source.length + 1)
      expect(main.sourceToOutput.at(-1)).toBe(main.text.length)
      expect(main.sourceToOutput.every((offset, index, map) => Number.isInteger(offset) && offset >= (map[index - 1] ?? 0))).toBe(true)
      const rich = parseBlockContent(source, main)!
      expect(rich.imageSources).toEqual([])
      expect(() => validateBlockContent(main.text, rich.blockContent)).not.toThrow()
    }
  })

  test("a later paragraph or heading cannot close inline code", () => {
    for (const source of ["`first\n\nsecond`", "`first\n# heading`", "> `first\n\noutside`", "`first\n---\nlast`", "before ```ts\n\n# heading\n``` after"]) {
      const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
      expect(values(main.text, main.entities)).toEqual([])
      expect(values(translated.text, translated.entities.entities)).toEqual([])
      expect(translated.entities.entities.some((entity) => entity.type === MessageEntity_Type.PRE && entity.offset === 7n)).toBe(false)
      expect(main.text).toContain(source.includes("first") ? "first" : "heading")
      if (source.includes("first")) {
        expect(main.text).toBe(source)
        expect(translated.text).toBe(source)
      }
    }
  })

  test("single-line padding and adjacent-code compatibility remain unchanged", () => {
    for (const [source, text] of [["` padded `", " padded "], ["`one``two`", "onetwo"], ["``value ` tick``", "value ` tick"]]) {
      expect(parseMarkdownWithSourceMap(source!).text).toBe(text!)
      expect(fromMd(source!).text).toBe(text!)
    }
  })

  test("table row boundaries cannot become one multiline code entity", () => {
    const source = "| `first | x |\n| --- | --- |\n| second` | y |"
    const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
    expect(values(main.text, main.entities)).toEqual([])
    expect(values(translated.text, translated.entities.entities)).toEqual([])
    expect(main.text).toBe(source)
    expect(translated.text).toBe(source)
    expect(parseBlockContent(source, main)?.blockContent.blocks[0]?.kind.oneofKind).toBe("table")
  })

  test("inline and reference link labels retain multiline code and container maps", () => {
    for (const source of [
      "> [`😀 first\n> second`](https://e.test)",
      "> [`😀 first\n> second`][id]\n\n[id]: https://e.test",
      "<u>`first\nsecond`</u>",
    ]) {
      const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
      const expected = source.includes("😀") ? "😀 first\nsecond" : "first\nsecond"
      expect(values(main.text, main.entities)).toEqual([expected])
      expect(values(translated.text, translated.entities.entities)).toEqual([expected])
      expect(main.text).toBe(translated.text)
      expect(main.entities.some((entity) => entity.type === (source.startsWith("<u>") ? MessageEntity_Type.UNDERLINE : MessageEntity_Type.TEXT_URL))).toBe(true)
    }
  })

  test("code and TeX use source-order opacity even with fake fences", () => {
    for (const source of [
      "`$not math\ncode` $y$",
      "$$\n> ```\n$$\n\n`first\nsecond`",
      "before $$\n```\n$$\n\n`first\nsecond`",
      "`first\nsecond` $$\n```\n$$ $z$",
    ]) {
      const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
      expect(values(main.text, main.entities)).toHaveLength(1)
      expect(values(translated.text, translated.entities.entities)).toEqual(values(main.text, main.entities))
      expect(values(translated.text, translated.entities.entities, MessageEntity_Type.MATH)).toEqual(values(main.text, main.entities, MessageEntity_Type.MATH))
      expect(main.entities.some((entity) => entity.type === MessageEntity_Type.PRE)).toBe(false)
    }
  })

  test("flow TeX shields fake fences in the prepared AST before inline scanning", () => {
    const kinds = (node: Nodes): string[] => [node.type, ...("children" in node ? node.children.flatMap(kinds) : [])]
    for (const prefix of ["", "lead\n", "> "]) {
      const next = prefix === "> " ? "> " : ""
      const source = `${prefix}$$\n${next}\`\`\`\n${next}$$\n\n\`first\nsecond\``
      const nodes = kinds(richMarkdownAst(source))
      expect(nodes.filter((kind) => kind === "inlineCode")).toHaveLength(1)
      expect(nodes).not.toContain("code")
    }
  })

  test("explicit mentions remap after code and remain noninteractive within it", () => {
    const source = "> `😀 first\n> second` @Maya"
    const entities = ["second", "@Maya"].map((text): MessageEntity => ({
      type: MessageEntity_Type.MENTION, offset: BigInt(source.indexOf(text)), length: BigInt(text.length),
      entity: { oneofKind: "mention", mention: { userId: 4n, agentId: 8n } },
    }))
    const result = processMessageText({ text: source, entities: { entities } })
    expect(values(result.text, result.entities!.entities, MessageEntity_Type.MENTION)).toEqual(["@Maya"])
  })

  test("disclosure bodies use the same code projection after extension masking", () => {
    const source = "<details>\n<summary>Title</summary>\nbefore `first\nsecond` after\n</details>"
    const main = parseMarkdownWithSourceMap(source)
    expect(values(main.text, main.entities)).toEqual(["first\nsecond"])
    const rich = parseBlockContent(source, main)!
    expect(rich.blockContent.blocks[0]?.kind.oneofKind).toBe("disclosure")
    expect(() => validateBlockContent(main.text, rich.blockContent)).not.toThrow()
  })

  test("line endings and every streamed prefix retain valid source maps", () => {
    for (const ending of ["\n", "\r", "\r\n"]) {
      const source = `> \`first${ending}> 😀 é\` after`
      const main = parseMarkdownWithSourceMap(source)
      expect(values(main.text, main.entities)).toEqual([`first${ending}😀 é`])
      for (let end = 0; end <= source.length; end++) {
        const current = parseMarkdownWithSourceMap(source.slice(0, end))
        expect(current.sourceToOutput.at(-1)).toBe(current.text.length)
        expect(current.sourceToOutput.every((offset, index, map) => Number.isInteger(offset) && offset >= (map[index - 1] ?? 0))).toBe(true)
        expect(current.entities.every((entity) => entity.offset >= 0n && entity.length > 0n && entity.offset + entity.length <= BigInt(current.text.length))).toBe(true)
      }
    }
  })

  test("deep containers keep code opaque and preserve its exact Unicode source", () => {
    for (const depth of [16, 128]) {
      const prefix = "> ".repeat(depth), source = `${prefix}\`😀 **literal**\n${prefix}$x$\``
      const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
      expect(values(main.text, main.entities)).toEqual(["😀 **literal**\n$x$"])
      expect(values(translated.text, translated.entities.entities)).toEqual(["😀 **literal**\n$x$"])
      expect(main.entities.map((entity) => entity.type)).toEqual([MessageEntity_Type.CODE])
      expect(translated.entities.entities.map((entity) => entity.type)).toEqual([MessageEntity_Type.CODE])
    }
  })
})
