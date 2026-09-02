import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, type Block, type BlockText } from "@inline-chat/protocol/core"
import { fromMd } from "../translation2/entities/fromMarkdown"
import { parseBlockContent, validateBlockContent } from "./blockContent"
import { parseMarkdownWithSourceMap } from "./parseMarkdown"
import { processMessageText } from "./processText"

const slice = (text: string, range: BlockText) => text.slice(Number(range.offset), Number(range.offset + range.length))
function paragraphs(blocks: Block[], text: string): string[] {
  return blocks.flatMap(({ kind }) => {
    switch (kind.oneofKind) {
      case "paragraph": return [slice(text, kind.paragraph)]
      case "quote": return paragraphs(kind.quote.children, text)
      case "list": return kind.list.items.flatMap((item) => paragraphs(item.children, text))
      case "disclosure": return paragraphs(kind.disclosure.children, text)
      default: return []
    }
  })
}

describe("canonical Markdown container source ranges", () => {
  test("continuation prefixes disappear inside native paragraphs while initial fallback markers remain", () => {
    const cases: [string, string, string[]][] = [
      ["> first\n> second", "> first\nsecond", ["first\nsecond"]],
      ["> > first\n> > second", "> > first\nsecond", ["first\nsecond"]],
      ["  > first\n  > second", "  > first\nsecond", ["first\nsecond"]],
      ["- first\n  second", "- first\nsecond", ["first\nsecond"]],
      ["> - first\n>   second", "> - first\nsecond", ["first\nsecond"]],
      ["- first\n  - inner\n    continued", "- first\n  - inner\ncontinued", ["first", "inner\ncontinued"]],
      ["> first\nlazy continuation", "> first\nlazy continuation", ["first\nlazy continuation"]],
      ["> first\n>\n> second", "> first\n>\n> second", ["first", "second"]],
      ["- first\n\n  second", "- first\n\n  second", ["first", "second"]],
    ]
    for (const [source, expected, expectedParagraphs] of cases) {
      const main = parseMarkdownWithSourceMap(source), translation = fromMd(source)
      expect(main.text).toBe(expected)
      expect(translation.text).toBe(expected)
      const rich = parseBlockContent(source, main)!
      expect(paragraphs(rich.blockContent.blocks, main.text)).toEqual(expectedParagraphs)
      expect(() => validateBlockContent(main.text, rich.blockContent)).not.toThrow()
      expect(main.sourceToOutput).toHaveLength(source.length + 1)
      expect(main.sourceToOutput.at(-1)).toBe(main.text.length)
      expect(main.sourceToOutput.every((offset, index, map) => Number.isInteger(offset) && offset >= (map[index - 1] ?? 0))).toBe(true)
    }
  })

  test("styles, reference labels and explicit Unicode mentions share the projected ranges", () => {
    const source = "> [**😀 first**\n> **é second**][id] @Maya\n\n[id]: https://e.test"
    const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
    expect(main.text).toBe("> 😀 first\né second @Maya\n\n")
    expect(translated.text).toBe(main.text)
    for (const entities of [main.entities, translated.entities.entities]) {
      expect(entities.filter((entity) => entity.type === MessageEntity_Type.BOLD).map((entity) => slice(main.text, entity))).toEqual(["😀 first", "é second"])
      const link = entities.find((entity) => entity.type === MessageEntity_Type.TEXT_URL)!
      expect(slice(main.text, link)).toBe("😀 first\né second")
    }
    const result = processMessageText({ text: source, entities: { entities: [{
      type: MessageEntity_Type.MENTION, offset: BigInt(source.indexOf("@Maya")), length: 5n,
      entity: { oneofKind: "mention", mention: { userId: 7n, agentId: 9n } },
    }] } })
    const mention = result.entities?.entities.find((entity) => entity.type === MessageEntity_Type.MENTION)!
    expect(slice(result.text, mention)).toBe("@Maya")
    expect(mention.entity).toEqual({ oneofKind: "mention", mention: { userId: 7n, agentId: 9n } })
  })

  test("multiline inline links are validated in their original container context", () => {
    for (const source of [
      "> [first\n> second](https://e.test)",
      "- [first\n  second](https://e.test)",
      "> [first](https://e.test\n> \"title\")",
    ]) {
      const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
      expect(translated.text).toBe(main.text)
      for (const result of [main, { text: translated.text, entities: translated.entities.entities }]) {
        const links = result.entities.filter((entity) => entity.type === MessageEntity_Type.TEXT_URL)
        expect(links).toHaveLength(1)
        expect(slice(result.text, links[0]!)).toBe(source.includes("second") ? "first\nsecond" : "first")
        expect(links[0]?.entity).toEqual({ oneofKind: "textUrl", textUrl: { url: "https://e.test" } })
      }
    }
  })

  test("real container prefixes are removed from TeX but fake inner operators are preserved", () => {
    const cases: [string, string][] = [
      ["> $$\n> x + y\n> $$", "\nx + y\n"],
      ["> $$\n> > x\n> $$", "\n> x\n"],
      ["> > $$\n> > x\n> > $$", "\nx\n"],
      ["- $$\n  x\n  $$", "\nx\n"],
      ["> [$$\n> x\n> $$](https://e.test)", "\nx\n"],
      ["> $$\n> - x\n> $$", "\n- x\n"],
      ["- $$\n  - x\n  $$", "\n- x\n"],
    ]
    for (const [source, formula] of cases) {
      const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
      for (const result of [main, { text: translated.text, entities: translated.entities.entities }]) {
        const math = result.entities.find((entity) => entity.type === MessageEntity_Type.MATH)!
        expect(math).toBeDefined()
        expect(slice(result.text, math)).toBe(formula)
      }
    }
    const fencedTeX = "> $$\n> ```\n> $$\n>\n> $$\n> y\n> $$"
    const main = parseMarkdownWithSourceMap(fencedTeX), translated = fromMd(fencedTeX)
    for (const result of [main, { text: translated.text, entities: translated.entities.entities }]) {
      expect(result.entities.filter((entity) => entity.type === MessageEntity_Type.MATH).map((entity) => slice(result.text, entity))).toEqual(["\n```\n", "\ny\n"])
      expect(result.entities.some((entity) => entity.type === MessageEntity_Type.PRE)).toBe(false)
    }
    for (const source of ["> $$\n> x\n> $$", "- $$\n  x\n  $$", "> $$\n> x\n> $$  "]) {
      const main = parseMarkdownWithSourceMap(source), rich = parseBlockContent(source, main)!
      const outer = rich.blockContent.blocks[0]!.kind
      const children = outer.oneofKind === "quote" ? outer.quote.children : outer.oneofKind === "list" ? outer.list.items[0]!.children : []
      expect(children.map((block) => block.kind.oneofKind)).toEqual(["math"])
      const math = children[0]!.kind
      expect(math.oneofKind === "math" && slice(main.text, math.math)).toBe("\nx\n")
      expect(() => validateBlockContent(main.text, rich.blockContent)).not.toThrow()
    }
  })

  test("code bodies do not lose literal indentation or get deindented twice", () => {
    for (const source of ["> ```\n>   x\n>   y\n> ```", "- ```\n    x\n    y\n  ```"]) {
      const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
      for (const result of [main, { text: translated.text, entities: translated.entities.entities }]) {
        const code = result.entities.find((entity) => entity.type === MessageEntity_Type.PRE)!
        expect(slice(result.text, code)).toBe("  x\n  y")
      }
    }
    const main = parseMarkdownWithSourceMap("> first\n> ` second `")
    expect(slice(main.text, main.entities.find((entity) => entity.type === MessageEntity_Type.CODE)!)).toBe(" second ")
  })

  test("disclosure continuation indentation is outside paragraph content", () => {
    const source = "<details>\n<summary>Title</summary>\nfirst\nsecond\n\nthird\n</details>"
    const main = parseMarkdownWithSourceMap(source), rich = parseBlockContent(source, main)!
    expect(paragraphs(rich.blockContent.blocks, main.text)).toEqual(["first\nsecond", "third"])
    expect(main.text).toContain("\tfirst\nsecond")
    expect(() => validateBlockContent(main.text, rich.blockContent)).not.toThrow()
  })

  test("quoted inline and reference images coalesce without phantom prefix paragraphs", () => {
    for (const source of [
      "> ![first](https://e.test/a.png)\n> ![second](https://e.test/b.png)",
      "> ![first][a]\n> ![second][b]\n\n[a]: https://e.test/a.png\n[b]: https://e.test/b.png",
    ]) {
      const main = parseMarkdownWithSourceMap(source), rich = parseBlockContent(source, main)!
      const quote = rich.blockContent.blocks[0]!
      expect(quote.kind.oneofKind).toBe("quote")
      const children = quote.kind.oneofKind === "quote" ? quote.kind.quote.children : []
      expect(children.map((block) => block.kind.oneofKind)).toEqual(["album"])
      expect(rich.imageSources.map((image) => image.url)).toEqual(["https://e.test/a.png", "https://e.test/b.png"])
      expect(() => validateBlockContent(main.text, rich.blockContent)).not.toThrow()
    }
  })

  test("task checkbox markers are absent from styled or code-first native text", () => {
    for (const body of ["**bold**", "`code`", "<u>underlined</u>"]) {
      const source = `- [x] ${body}`
      const main = parseMarkdownWithSourceMap(source), rich = parseBlockContent(source, main)!
      expect(paragraphs(rich.blockContent.blocks, main.text).join("")).toBe(body.replaceAll("**", "").replaceAll("`", "").replace(/<\/?u>/g, ""))
      const list = rich.blockContent.blocks[0]!
      expect(list.kind.oneofKind === "list" && list.kind.list.items[0]?.checked).toBe(true)
    }
    // GFM requires content after a checkbox; a bare marker is still literal text.
    const source = "- [x] ", main = parseMarkdownWithSourceMap(source)
    expect(paragraphs(parseBlockContent(source, main)!.blockContent.blocks, main.text)).toEqual(["[x] "])
  })

  test("CR, LF, CRLF and tabbed containers preserve content and source boundaries", () => {
    for (const ending of ["\n", "\r", "\r\n"]) {
      for (const [first, next] of [[">\t", ">\t"], ["-\t", "\t"], ["> - ", ">   "]] as const) {
        const source = `${first}😀 first${ending}${next}é second`
        const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
        expect(main.text).toBe(`${first}😀 first${ending}é second`)
        expect(translated.text).toBe(main.text)
        expect(paragraphs(parseBlockContent(source, main)!.blockContent.blocks, main.text)).toEqual([`😀 first${ending}é second`])
        const start = source.indexOf("é")
        expect(main.text.slice(main.sourceToOutput[start], main.sourceToOutput[start + 2])).toBe("é")
      }
    }
  })

  test("every streamed prefix retains valid canonical ranges through completion", () => {
    const complete = "> [**😀 first**\n> second][id]\n>\n> ![a](https://e.test/a.png)\n> ![b](https://e.test/b.png)\n\n[id]: https://e.test"
    for (let length = 0; length <= complete.length; length++) {
      const source = complete.slice(0, length), main = parseMarkdownWithSourceMap(source)
      expect(main.sourceToOutput).toHaveLength(source.length + 1)
      expect(main.sourceToOutput.at(-1)).toBe(main.text.length)
      expect(main.sourceToOutput.every((offset, index, map) => Number.isInteger(offset) && offset >= (map[index - 1] ?? 0))).toBe(true)
      for (const entity of main.entities) {
        expect(entity.offset >= 0n && entity.length > 0n && entity.offset + entity.length <= BigInt(main.text.length)).toBe(true)
      }
      const rich = parseBlockContent(source, main)
      if (rich) expect(() => validateBlockContent(main.text, rich.blockContent)).not.toThrow()
    }
  })
})
