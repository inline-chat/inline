import { MessageEntity_Type, type Block, type MessageEntity } from "@inline-chat/protocol/core"
import { describe, expect, test } from "bun:test"
import { fromMarkdown } from "mdast-util-from-markdown"
import type { Nodes } from "mdast"
import { fromMd } from "../translation2/entities/fromMarkdown"
import { parseBlockContent, validateBlockContent } from "./blockContent"
import { parseMarkdown, parseMarkdownWithSourceMap } from "./parseMarkdown"
import { processMessageText } from "./processText"

const bodies = (text: string, entities: MessageEntity[]): string[] => entities
  .filter((entity) => entity.type === MessageEntity_Type.PRE)
  .map((entity) => text.slice(Number(entity.offset), Number(entity.offset + entity.length)))

const codeBlocks = (blocks: Block[]): Block[] => blocks.flatMap((block): Block[] => {
  switch (block.kind.oneofKind) {
    case "code": return [block]
    case "quote": return codeBlocks(block.kind.quote.children)
    case "list": return block.kind.list.items.flatMap((item) => codeBlocks(item.children))
    case "disclosure": return codeBlocks(block.kind.disclosure.children)
    default: return []
  }
})

describe("CommonMark code source projection", () => {
  test("indented and container code stays verbatim in message, translation, and rich blocks", () => {
    const cases: [string, string][] = [
      ["    **code**\n    second", "**code**\nsecond"],
      [">     **code**\n>     second", "**code**\nsecond"],
      ["- item\n\n      **code**\n      second", "**code**\nsecond"],
      ["\t**code**\n \t  nested", "**code**\n  nested"],
      [">\t\tfoo\n>\t\tbar", "  foo\n  bar"],
      ["- item\n\n\t\tfoo\n\t\tbar", "  foo\n  bar"],
      ["> ```ts\n>  first\n>\n>   last\n> ```", " first\n\n  last"],
      ["- ```ts\n  first\n  second\n  ```", "first\nsecond"],
      ["> ~~~~ts\n> ```\n> ~~~~", "```"],
      ["> ```\n>\n> x\n>\n> ```", "\nx\n"],
      ["    a\r\n    \r\n    b\r\n", "a\r\n\r\nb"],
      ["    a\rb\r", "a"],
      ["    foo\tbar\n    \0emoji 😀", "foo\tbar\n\0emoji 😀"],
      ["    $x$ ~~s~~ ==h== <u>u</u> [link](https://e.test) ![image](https://e.test/i)",
        "$x$ ~~s~~ ==h== <u>u</u> [link](https://e.test) ![image](https://e.test/i)"],
    ]
    for (const [source, expected] of cases) {
      const main = parseMarkdownWithSourceMap(source)
      const translated = fromMd(source)
      expect(bodies(main.text, main.entities)).toEqual([expected])
      expect(bodies(translated.text, translated.entities.entities)).toEqual([expected])
      expect(main.entities.map((entity) => entity.type)).toEqual([MessageEntity_Type.PRE])
      expect(translated.entities.entities.map((entity) => entity.type)).toEqual([MessageEntity_Type.PRE])
      const rich = parseBlockContent(source, main)!
      expect(rich).toBeDefined()
      expect(rich.imageSources).toEqual([])
      const blocks = codeBlocks(rich.blockContent.blocks)
      expect(blocks).toHaveLength(1)
      const range = blocks[0]?.kind.oneofKind === "code" ? blocks[0].kind.code.text : undefined
      expect(main.text.slice(Number(range?.offset), Number((range?.offset ?? 0n) + (range?.length ?? 0n)))).toBe(expected)
      expect(() => validateBlockContent(main.text, rich.blockContent)).not.toThrow()
      expect(main.sourceToOutput).toHaveLength(source.length + 1)
      let previous = 0
      for (const boundary of main.sourceToOutput) {
        expect(Number.isInteger(boundary) && boundary >= previous && boundary <= main.text.length).toBe(true)
        previous = boundary
      }
      expect(previous).toBe(main.text.length)
    }
  })

  test("UTF-16 source ranges preserve emoji and combining marks after partial tabs and removed prefixes", () => {
    const source = ">\t\t😀 é\n>\t\tsecond\n\nMaya"
    const parsed = parseMarkdownWithSourceMap(source)
    for (const text of ["😀", "é", "second", "Maya"]) {
      const start = source.indexOf(text)
      expect(parsed.text.slice(parsed.sourceToOutput[start], parsed.sourceToOutput[start + text.length])).toBe(text)
    }
    const entity = (name: string): MessageEntity => ({ type: MessageEntity_Type.MENTION,
      offset: BigInt(source.indexOf(name)), length: BigInt(name.length),
      entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 9n } } })
    const result = processMessageText({ text: source, entities: { entities: [entity("second"), entity("Maya")] } })
    const mentions = result.entities?.entities.filter((value) => value.type === MessageEntity_Type.MENTION) ?? []
    expect(mentions).toHaveLength(1)
    expect(mentions[0]).toEqual({ ...entity("Maya"), offset: BigInt(result.text.indexOf("Maya")) })
  })

  test("extensions inside code stay literal and a disclosure can contain indented code", () => {
    const source = "<details>\n<summary>Result</summary>\n\n    <footer>**code**</footer>\n    <details>\n    $x$\n\n</details>"
    const parsed = parseMarkdownWithSourceMap(source)
    expect(bodies(parsed.text, parsed.entities)).toEqual(["<footer>**code**</footer>\n<details>\n$x$"])
    expect(codeBlocks(parseBlockContent(source, parsed)!.blockContent.blocks)).toHaveLength(1)
  })

  test("summary and footer remain inline surfaces even when their labels begin with indentation", () => {
    const source = "<details>\n<summary>    **Summary**</summary>\n    body\n</details>\n<footer>    **Footer**</footer>"
    const parsed = parseMarkdownWithSourceMap(source)
    expect(bodies(parsed.text, parsed.entities)).toEqual(["body"])
    expect(parsed.entities.filter((entity) => entity.type === MessageEntity_Type.BOLD)
      .map((entity) => parsed.text.slice(Number(entity.offset), Number(entity.offset + entity.length))))
      .toEqual(["Summary", "Footer"])
    expect(parsed.text).toContain("    Footer")
  })

  test("earlier math shields fake container fences without hiding later real code", () => {
    const source = "$$\n> ```\n    not code\n$$\n\n    **real code**"
    for (const result of [parseMarkdown(source), (() => { const parsed = fromMd(source); return { ...parsed, entities: parsed.entities.entities } })()]) {
      expect(bodies(result.text, result.entities)).toEqual(["**real code**"])
      expect(result.entities.filter((entity) => entity.type === MessageEntity_Type.MATH)).toHaveLength(1)
    }
  })

  test("ordinary paragraph continuation and literal HTML do not become indented code", () => {
    for (const source of ["paragraph\n    **still prose**", "<div>\n    **still HTML**\n</div>"]) {
      expect(bodies(parseMarkdown(source).text, parseMarkdown(source).entities)).toEqual([])
      const translated = fromMd(source)
      expect(bodies(translated.text, translated.entities.entities)).toEqual([])
    }
  })

  test("empty container code has monotonic boundaries after a nonzero prefix", () => {
    const source = "> ```\n>\n> ```\n\nMaya"
    const parsed = parseMarkdownWithSourceMap(source)
    expect(parsed.text).toBe("> \n\nMaya")
    expect(parsed.sourceToOutput.slice(2, source.indexOf("\n\n"))).toEqual(Array(11).fill(2))
    const rich = parseBlockContent(source, parsed)!
    expect(codeBlocks(rich.blockContent.blocks)).toHaveLength(1)
    expect(() => validateBlockContent(parsed.text, rich.blockContent)).not.toThrow()
  })

  test("inline styles cannot cross a new block-code boundary", () => {
    for (const [open, close] of [["**", "**"], ["*", "*"], ["~~", "~~"], ["==", "=="], ["<u>", "</u>"]]) {
      const source = `${open}before\n\n    code\n\nend${close}`
      const main = parseMarkdown(source), translated = fromMd(source)
      expect(main.text).toBe(`${open}before\n\ncode\n\nend${close}`)
      expect(translated.text).toBe(main.text)
      expect(main.entities.map((entity) => entity.type)).toEqual([MessageEntity_Type.PRE])
      expect(translated.entities.entities.map((entity) => entity.type)).toEqual([MessageEntity_Type.PRE])
    }
  })

  test("root fence and embedded translation PRE keep their existing whitespace policies", () => {
    const source = "```ts\n  code  \n```"
    expect(bodies(parseMarkdown(source).text, parseMarkdown(source).entities)).toEqual(["code"])
    const translated = fromMd(source)
    expect(bodies(translated.text, translated.entities.entities)).toEqual(["  code  \n"])
    const embedded = fromMd("before ```ts\n  code  ``` after")
    expect(embedded.text).toBe("before   code   after")
    expect(bodies(embedded.text, embedded.entities.entities)).toEqual(["  code  "])
  })

  test("streamed container fences stay valid and never parse their body as inline markup", () => {
    const source = "> ```ts\n> **bold**\n> $x$\n> ![x](https://e.test/i)\n> ```\n\nEnd"
    for (let end = source.indexOf("**bold**") + 1; end <= source.length; end++) {
      const snapshot = source.slice(0, end)
      const parsed = parseMarkdownWithSourceMap(snapshot)
      expect(parsed.entities.every((entity) => entity.type === MessageEntity_Type.PRE)).toBe(true)
      const rich = parseBlockContent(snapshot, parsed)!
      expect(rich).toBeDefined()
      expect(rich.imageSources).toEqual([])
      expect(() => validateBlockContent(parsed.text, rich.blockContent)).not.toThrow()
    }
  })

  test("container, indentation, blank-line and line-ending combinations agree with the CommonMark AST", () => {
    const expectedBodies = (node: Nodes): string[] => node.type === "code" ? [node.value]
      : "children" in node ? node.children.flatMap(expectedBodies) : []
    for (const newline of ["\n", "\r\n", "\r"]) {
      for (const [first, next] of [["> ", "> "], ["> > ", "> > "], ["- ", "  "], ["1. ", "   "], ["> - ", ">   "]]) {
        for (const body of [["x"], ["", "x", ""], ["  x", "", "\ty"], ["**x**", "$x$", "[x](https://e.test)"]]) {
          for (const delimiter of ["```ts", "~~~~ts"]) {
            const close = delimiter.startsWith("`") ? "```" : "~~~~"
            const source = [first + delimiter, ...body.map((line) => next + line), next + close].join(newline)
            const expected = expectedBodies(fromMarkdown(source)).filter(Boolean)
            const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
            expect(bodies(main.text, main.entities)).toEqual(expected)
            expect(bodies(translated.text, translated.entities.entities)).toEqual(expected)
            for (let index = 1; index < main.sourceToOutput.length; index++) {
              expect(main.sourceToOutput[index]! >= main.sourceToOutput[index - 1]!).toBe(true)
            }
          }
        }
      }
    }
  })

  test("deep container input either maps verified code or retains the complete literal source", () => {
    for (const depth of [16, 128, 512]) {
      const prefix = "> ".repeat(depth)
      const body = "**literal** $x$ [link](https://e.test)"
      const source = `${prefix}\`\`\`\n${prefix}${body}\n${prefix}\`\`\``
      const parsed = parseMarkdownWithSourceMap(source)
      const translated = fromMd(source)
      for (const result of [parsed, { text: translated.text, entities: translated.entities.entities }]) {
        if (result.entities.length === 0) expect(result.text).toBe(source)
        else {
          expect(result.entities.map((entity) => entity.type)).toEqual([MessageEntity_Type.PRE])
          expect(bodies(result.text, result.entities)).toEqual([body])
        }
      }
      expect(parsed.sourceToOutput).toHaveLength(source.length + 1)
      for (let index = 1; index < parsed.sourceToOutput.length; index++) {
        expect(parsed.sourceToOutput[index]! >= parsed.sourceToOutput[index - 1]!).toBe(true)
      }
    }
  })
})
