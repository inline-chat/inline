import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { fromMd } from "../translation2/entities/fromMarkdown"
import { toMd } from "../translation2/entities/toMarkdown"
import { parseBlockContent, validateBlockContent } from "./blockContent"
import { parseMarkdownWithSourceMap } from "./parseMarkdown"
import { processMessageText } from "./processText"
import { inlineStyleTags } from "../translation2/entities/inlineStyles"

const values = (text: string, entities: MessageEntity[], type: MessageEntity_Type) => entities
  .filter((entity) => entity.type === type)
  .map((entity) => text.slice(Number(entity.offset), Number(entity.offset + entity.length)))

const parsers = (source: string) => {
  const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
  return [main, { text: translated.text, entities: translated.entities.entities }]
}

describe("shared multiline emphasis", () => {
  test("bold and italic cross soft line breaks with either delimiter", () => {
    for (const ending of ["\n", "\r", "\r\n"]) {
      for (const marker of ["**", "__", "*", "_"]) {
        const content = `😀 first${ending}é second`
        const source = `before ${marker}${content}${marker} after`
        const type = marker.length === 2 ? MessageEntity_Type.BOLD : MessageEntity_Type.ITALIC
        for (const result of parsers(source)) {
          expect(result.text).toBe(`before ${content} after`)
          expect(values(result.text, result.entities, type)).toEqual([content])
        }
        const main = parseMarkdownWithSourceMap(source)
        expect(main.sourceToOutput).toHaveLength(source.length + 1)
        expect(main.sourceToOutput.at(-1)).toBe(main.text.length)
      }
    }
  })

  test("nested emphasis uses the same delimiter tree on both paths", () => {
    for (const source of ["**first\n_second_**", "*first\n__second__*", "***first\nsecond***", "**first _both\nlines_ last**"]) {
      const [main, translated] = parsers(source)
      expect(main!.text).toBe(translated!.text)
      for (const type of [MessageEntity_Type.BOLD, MessageEntity_Type.ITALIC]) {
        expect(values(main!.text, main!.entities, type)).toEqual(values(translated!.text, translated!.entities, type))
        expect(values(main!.text, main!.entities, type)).toHaveLength(1)
      }
      expect(main!.text).not.toMatch(/[*_]/)
    }
  })

  test("quote and list continuation prefixes are outside rendered formatting", () => {
    for (const source of ["> **first\n> second**", "> > *first\n> > second*", "- **first\n  second**", "> - _first\n>   second_"]) {
      const [main, translated] = parsers(source)
      expect(main!.text).toBe(translated!.text)
      const type = source.includes("**") ? MessageEntity_Type.BOLD : MessageEntity_Type.ITALIC
      expect(values(main!.text, main!.entities, type)).toEqual(["first\nsecond"])
      expect(values(translated!.text, translated!.entities, type)).toEqual(["first\nsecond"])
      const parsed = parseMarkdownWithSourceMap(source)
      const rich = parseBlockContent(source, parsed)!
      expect(() => validateBlockContent(parsed.text, rich.blockContent)).not.toThrow()
    }
  })

  test("inline and reference link labels preserve verified nested emphasis", () => {
    for (const source of [
      "[**first\nsecond**](https://e.test)",
      "> [_first\n> second_][id]\n\n[id]: https://e.test",
      "**before\n[label][id] after**\n\n[id]: https://e.test",
      "<u>**first\n_second_**</u>",
    ]) {
      const [main, translated] = parsers(source)
      expect(main!.text).toBe(translated!.text)
      for (const type of [MessageEntity_Type.BOLD, MessageEntity_Type.ITALIC, MessageEntity_Type.TEXT_URL, MessageEntity_Type.UNDERLINE]) {
        expect(values(main!.text, main!.entities, type)).toEqual(values(translated!.text, translated!.entities, type))
      }
      expect(main!.text).not.toMatch(/[*_]/)
    }
  })

  test("code and TeX retain opacity within multiline emphasis", () => {
    for (const source of [
      "**first\n`_code_` and $x_i$**",
      "**first `literal\nsecond _code_` last**",
      "**first $$\nx_i + y\n$$ last**",
      "**first\n[link](https://e.test/a_**_b) last**",
    ]) {
      const [main, translated] = parsers(source)
      expect(main!.text).toBe(translated!.text)
      expect(values(main!.text, main!.entities, MessageEntity_Type.BOLD)).toEqual([main!.text])
      expect(values(translated!.text, translated!.entities, MessageEntity_Type.BOLD)).toEqual([translated!.text])
      for (const type of [MessageEntity_Type.CODE, MessageEntity_Type.MATH, MessageEntity_Type.ITALIC, MessageEntity_Type.TEXT_URL]) {
        expect(values(main!.text, main!.entities, type)).toEqual(values(translated!.text, translated!.entities, type))
      }
      expect(values(main!.text, main!.entities, MessageEntity_Type.ITALIC)).toEqual([])
    }
  })

  test("a paragraph, heading, list, or table cannot close a prior marker", () => {
    for (const ending of ["\n", "\r", "\r\n"]) {
      for (const source of [
        `**first${ending}${ending}second**`,
        `*first${ending}# second*`,
        `**first${ending}- second**`,
        `*first${ending}---${ending}second*`,
        `| **first | x |${ending}| --- | --- |${ending}| second** | y |`,
        `*first [label${ending}${ending}other](https://e.test)*`,
      ]) {
        for (const result of parsers(source)) {
          expect(values(result.text, result.entities, MessageEntity_Type.BOLD)).toEqual([])
          expect(values(result.text, result.entities, MessageEntity_Type.ITALIC)).toEqual([])
          expect(result.text).toContain("first")
        }
      }
    }
  })

  test("removing a style or link wrapper cannot turn inline code into an unclosed fence", () => {
    for (const source of ["**```ts\nx ```**", "[**```ts\nx ```**](https://e.test)"]) {
      const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
      expect(main.text).toBe("ts\nx ")
      expect(values(main.text, main.entities, MessageEntity_Type.CODE)).toEqual(["ts\nx "])
      expect(values(main.text, main.entities, MessageEntity_Type.BOLD)).toEqual([main.text])
      // Translation's established embedded-PRE syntax treats ts as language;
      // it must still consume the closing run and preserve body whitespace.
      expect(translated.text).toBe("x ")
      expect(values(translated.text, translated.entities.entities, MessageEntity_Type.PRE)).toEqual(["x "])
      expect(values(translated.text, translated.entities.entities, MessageEntity_Type.BOLD)).toEqual([translated.text])
    }
  })

  test("disclosure bodies retain their paragraph context for multiline emphasis", () => {
    const source = "<details>\n<summary>Title</summary>\n**first\n_second_**\n</details>"
    const parsed = parseMarkdownWithSourceMap(source)
    expect(values(parsed.text, parsed.entities, MessageEntity_Type.BOLD)).toEqual(["first\nsecond"])
    expect(values(parsed.text, parsed.entities, MessageEntity_Type.ITALIC)).toEqual(["second"])
    const rich = parseBlockContent(source, parsed)!
    expect(rich.blockContent.blocks[0]?.kind.oneofKind).toBe("disclosure")
    expect(() => validateBlockContent(parsed.text, rich.blockContent)).not.toThrow()
  })

  test("an opaque cursor jump cannot make a legacy marker cross paragraphs", () => {
    // The math scanner jumps over all internal newlines at once. The trailing
    // marker must not close an unverified opener from before that jump.
    const source = "**first\n\n$$\nx\n$$ second**"
    for (const result of parsers(source)) {
      expect(values(result.text, result.entities, MessageEntity_Type.BOLD)).toEqual([])
      expect(values(result.text, result.entities, MessageEntity_Type.MATH)).toEqual(["\nx\n"])
    }
  })

  test("padded and adjacent delimiter compatibility stays intact", () => {
    for (const source of ["** padded **", "* padded *", "**one****two**"]) {
      for (const result of parsers(source)) expect(result.text).toBe(source.replaceAll("*", ""))
    }
    expect(parseMarkdownWithSourceMap("*one**two*").text).toBe("onetwo")
    expect(fromMd("*one**two*").text).toBe("onetwo")
    expect(fromMd("_italic_").text).toBe("italic")
    expect(parseMarkdownWithSourceMap("_italic_").text).toBe("italic")
  })

  test("explicit mentions retain UTF-16 positions through nested formatting", () => {
    const source = "> **😀 first\n> _@Maya_** after"
    const entity: MessageEntity = { type: MessageEntity_Type.MENTION,
      offset: BigInt(source.indexOf("@Maya")), length: 5n,
      entity: { oneofKind: "mention", mention: { userId: 4n, agentId: 8n } } }
    const result = processMessageText({ text: source, entities: { entities: [entity] } })
    expect(result.text).toBe("> 😀 first\n@Maya after")
    expect(values(result.text, result.entities!.entities, MessageEntity_Type.MENTION)).toEqual(["@Maya"])
    expect(values(result.text, result.entities!.entities, MessageEntity_Type.ITALIC)).toEqual(["@Maya"])
    expect(result.entities!.entities.find((value) => value.type === MessageEntity_Type.MENTION)?.entity).toEqual(entity.entity)
  })

  test("translation round-trips canonical multiline style entities", () => {
    const source = "**😀 first\n_second_**"
    const parsed = fromMd(source)
    const decoded = fromMd(toMd(parsed.text, parsed.entities))
    expect(decoded.text).toBe(parsed.text)
    for (const type of [MessageEntity_Type.BOLD, MessageEntity_Type.ITALIC]) {
      expect(values(decoded.text, decoded.entities.entities, type).join("\n")).toBe(values(parsed.text, parsed.entities.entities, type).join("\n"))
    }
  })

  test("native style ranges spanning paragraphs survive translation as per-line formatting", () => {
    for (const ending of ["\n", "\r", "\r\n"]) {
      const text = `😀 first${ending}${ending}  second${ending}# third`
      for (const type of [MessageEntity_Type.BOLD, MessageEntity_Type.ITALIC, MessageEntity_Type.UNDERLINE,
        MessageEntity_Type.STRIKETHROUGH, MessageEntity_Type.HIGHLIGHT]) {
        const markdown = toMd(text, { entities: [{ type, offset: 0n, length: BigInt(text.length), entity: { oneofKind: undefined } }] })
        const decoded = fromMd(markdown)
        expect(decoded.text).toBe(text)
        expect(values(decoded.text, decoded.entities.entities, type)).toEqual(["😀 first", "  second", "# third"])
      }
    }
    const text = "first\n\nsecond"
    const entity: MessageEntity = { type: MessageEntity_Type.BOLD, offset: 0n, length: BigInt(text.length), entity: { oneofKind: undefined } }
    expect(toMd(text, { entities: [entity] })).toBe("**first**\n\n**second**")
  })

  test("serialization does not insert style markers within multiline code, math, or links", () => {
    for (const source of ["**first `code\nsecond` last**", "**first $$\nx_i\n$$ last**", "**first [a\nb](https://e.test) last**"]) {
      const parsed = fromMd(source), decoded = fromMd(toMd(parsed.text, parsed.entities))
      expect(decoded.text).toBe(parsed.text)
      for (const type of [MessageEntity_Type.BOLD, MessageEntity_Type.CODE, MessageEntity_Type.MATH, MessageEntity_Type.TEXT_URL]) {
        expect(values(decoded.text, decoded.entities.entities, type)).toEqual(values(parsed.text, parsed.entities.entities, type))
      }
    }
  })

  test("styles surrounding mixed display math survive without changing standalone block boundaries", () => {
    for (const newline of ["\n", "\r", "\r\n"]) for (const style of inlineStyleTags) {
      const source = `${style.open}first $$${newline}x_i${newline}$$ last${style.close}`
      const parsed = fromMd(source)
      const markdown = toMd(parsed.text, parsed.entities)
      for (const result of parsers(markdown)) {
        expect(result.text).toBe(parsed.text)
        expect(values(result.text, result.entities, style.type)).toEqual([parsed.text])
        expect(values(result.text, result.entities, MessageEntity_Type.MATH)).toEqual([`${newline}x_i${newline}`])
      }
    }
    for (const indent of ["", "  "]) {
      const text = `before\n\n${indent}\nx_i\n\n\nafter`
      const offset = text.indexOf("\nx_i")
      const formula: MessageEntity = { type: MessageEntity_Type.MATH, offset: BigInt(offset), length: 5n,
        entity: { oneofKind: undefined } }
      const displayFormula: MessageEntity = { ...formula,
        entity: { oneofKind: "math", math: { display: true } } }
      const style: MessageEntity = { type: MessageEntity_Type.BOLD, offset: 0n, length: BigInt(text.length),
        entity: { oneofKind: undefined } }
      const markdown = toMd(text, { entities: [style, displayFormula] })
      const parsed = parseMarkdownWithSourceMap(markdown)
      expect(parsed.text).toBe(text)
      expect(parsed.entities.filter((item) => item.type === MessageEntity_Type.MATH)).toEqual([formula])
      expect(parsed.entities.some((item) => item.type === MessageEntity_Type.BOLD
        && item.offset < formula.offset + formula.length && item.offset + item.length > formula.offset)).toBe(false)
      // Flat transport encodes literal indentation as character references;
      // BlockContent, when present, remains the structural source of truth.
      if (!indent) {
        const blocks = parseBlockContent(markdown, parsed)!
        expect(blocks.blockContent.blocks.some((block) => block.kind.oneofKind === "math")).toBe(true)
      }
    }
  })

  test("streamed prefixes keep valid source maps and entity bounds", () => {
    for (const source of ["> **😀 first\n> _second_** after", "[**first\n`code` $x_i$**](https://e.test)", "**first\n\nsecond**"]) {
      for (let end = 0; end <= source.length; end++) {
        const prefix = source.slice(0, end)
        const main = parseMarkdownWithSourceMap(prefix)
        expect(main.sourceToOutput).toHaveLength(prefix.length + 1)
        expect(main.sourceToOutput.at(-1)).toBe(main.text.length)
        expect(main.sourceToOutput.every((offset, index, map) => Number.isInteger(offset) && offset >= (map[index - 1] ?? 0))).toBe(true)
        for (const result of parsers(prefix)) {
          expect(result.entities.every((entity) => entity.offset >= 0n && entity.length > 0n && entity.offset + entity.length <= BigInt(result.text.length))).toBe(true)
        }
      }
    }
  })
})
