import { MessageEntity_Type, type MessageEntities, type MessageEntity } from "@inline-chat/protocol/core"
import { describe, expect, test } from "bun:test"
import { fromMarkdown } from "mdast-util-from-markdown"
import { fromMd } from "../translation2/entities/fromMarkdown"
import { readInlineLinkDestination } from "../translation2/entities/linkSyntax"
import { toMd } from "../translation2/entities/toMarkdown"
import { parseBlockContent, validateBlockContent } from "./blockContent"
import { encodeBlockContentToMarkdown } from "./blockContentMarkdown"
import { parseMarkdown, parseMarkdownWithSourceMap } from "./parseMarkdown"
import { processMessageText } from "./processText"

const urlEntity = (url: string, length = 5): MessageEntity => ({
  type: MessageEntity_Type.TEXT_URL, offset: 0n, length: BigInt(length),
  entity: { oneofKind: "textUrl", textUrl: { url } },
})

describe("shared Markdown link destinations", () => {
  test("both message and translation parsers separate destinations from wrappers and titles", () => {
    const cases: [string, string][] = [
      ["<https://example.com/a%20b>", "https://example.com/a%20b"],
      ["<https://example.com/a b>", "https://example.com/a b"],
      ['https://example.com "a title with ) and ("', "https://example.com"],
      ["https://example.com 'single quoted title'", "https://example.com"],
      [String.raw`https://example.com (escaped \(title\))`, "https://example.com"],
      [String.raw`https://example.com "an escaped \" quote"`, "https://example.com"],
      [' \r\n <https://example.com/a>\t"first\r\nsecond" \r\n ', "https://example.com/a"],
      ["https://example.com/a(b(c(d)e)f)g", "https://example.com/a(b(c(d)e)f)g"],
      [String.raw`<https://example.com/a(b\>c>`, "https://example.com/a(b>c"],
      [String.raw`https://example.com/a\)b\q`, String.raw`https://example.com/a)b\q`],
      ["https://example.com/?a=1&amp;b=2&#x2f;c", "https://example.com/?a=1&b=2/c"],
      [String.raw`https://example.com/\&copy;`, "https://example.com/&copy;"],
      ["https://example.com/&not-a-reference;", "https://example.com/&not-a-reference;"],
    ]
    for (const [body, url] of cases) {
      const markdown = `[label](${body})`
      const main = parseMarkdown(markdown)
      expect(main).toEqual({ text: "label", entities: [urlEntity(url)] })
      expect(fromMd(markdown)).toEqual({ text: main.text, entities: { entities: main.entities } })
      const paragraph = fromMarkdown(markdown).children[0]
      const reference = paragraph?.type === "paragraph" ? paragraph.children[0] : undefined
      expect(reference?.type === "link" ? reference.url : undefined).toBe(url)
    }
  })

  test("invalid or unfinished bodies do not manufacture TEXT_URL entities", () => {
    for (const body of [
      "https://example.com bare words", '<https://example.com>"no separator"',
      'https://example.com "unfinished', '<https://example.com/unterminated',
      '<https://example.com/a\nb>', '<https://example.com/a<b>',
      'https://example.com "blank\n \t\nline"', 'https://example.com\n\n',
      'https://example.com (nested (unescaped))', "https://example.com/a(b",
      `https://example.com/${"(".repeat(33)}x${")".repeat(33)}`,
    ]) {
      const markdown = `[label](${body})`
      expect(parseMarkdown(markdown).entities.some((entity) => entity.type === MessageEntity_Type.TEXT_URL)).toBe(false)
      expect(fromMd(markdown).entities.entities.some((entity) => entity.type === MessageEntity_Type.TEXT_URL)).toBe(false)
      expect(parseMarkdown(markdown).text).toBe(markdown)
    }
  })

  test("empty destinations keep the label and nested formatting without an interactive URL", () => {
    for (const body of ["", " ", "<>", ' "title with words"', '<> "$x$ **title** <footer>hidden</footer>"']) {
      const markdown = `[**label**](${body})`
      const parsed = parseMarkdown(markdown)
      expect(parsed.text).toBe("label")
      expect(parsed.entities).toEqual([{
        type: MessageEntity_Type.BOLD, offset: 0n, length: 5n, entity: { oneofKind: undefined },
      }])
      expect(fromMd(markdown)).toEqual({ text: parsed.text, entities: { entities: parsed.entities } })
    }
  })

  test("streaming a title cannot close its link on an inner parenthesis or consume completed prefix content", () => {
    const prefix = "**done** "
    const link = String.raw`[label](<https://example.com/a(b> "a ) and \" quote")`
    for (let end = 1; end < link.length; end++) {
      const input = prefix + link.slice(0, end)
      const parsed = parseMarkdownWithSourceMap(input)
      expect(parsed.text.startsWith("done ")).toBe(true)
      expect(parsed.entities[0]).toMatchObject({ type: MessageEntity_Type.BOLD, offset: 0n, length: 4n })
      expect(parsed.entities.some((entity) => entity.type === MessageEntity_Type.TEXT_URL)).toBe(false)
      expect(parsed.sourceToOutput).toHaveLength(input.length + 1)
      expect(parsed.sourceToOutput.every((offset, index, values) => Number.isInteger(offset)
        && offset >= (values[index - 1] ?? 0) && offset <= parsed.text.length)).toBe(true)
    }
    expect(parseMarkdown(prefix + link).text).toBe("done label")
  })

  test("UTF-16 source remapping retains explicit mentions after a titled Unicode label", () => {
    const source = '😀 [**指南**](<https://example.com/a b> "title") Maya'
    const mention: MessageEntity = {
      type: MessageEntity_Type.MENTION, offset: BigInt(source.indexOf("Maya")), length: 4n,
      entity: { oneofKind: "mention", mention: { userId: 4n, agentId: 9n } },
    }
    const parsed = processMessageText({ text: source, entities: { entities: [mention] } })
    expect(parsed.text).toBe("😀 指南 Maya")
    expect(parsed.entities?.entities.find((entity) => entity.type === MessageEntity_Type.MENTION)).toEqual({ ...mention, offset: 6n })
    expect(parsed.entities?.entities.find((entity) => entity.type === MessageEntity_Type.BOLD)).toMatchObject({ offset: 3n, length: 2n })
  })

  test("multiline titles cannot consume a later heading, fence, list, or disclosure", () => {
    for (const block of ["# Heading", "```js\nconst x=1\n```", "- item", "> quote",
      "<details>\n<summary>summary</summary>\nbody\n</details>"]) {
      const input = `[label](url "title\n${block}\n")`
      const parsed = parseMarkdown(input)
      expect(parsed.entities.some((entity) => entity.type === MessageEntity_Type.TEXT_URL)).toBe(false)
      expect(parsed.text.length).toBeGreaterThan("label".length)
      expect(fromMd(input).entities.entities.some((entity) => entity.type === MessageEntity_Type.TEXT_URL)).toBe(false)
      const projected = parseBlockContent(input)!
      expect(() => validateBlockContent(parsed.text, projected.blockContent)).not.toThrow()
      if (block.startsWith("```")) {
        const code = parsed.entities.find((entity) => entity.type === MessageEntity_Type.PRE)!
        expect(parsed.text.slice(Number(code.offset), Number(code.offset + code.length))).toBe("const x=1")
      }
    }
  })

  test("ordinary multiline labels/titles retain custom opaque math and code labels", () => {
    for (const label of ["a\nlabel", String.raw`$x_[i]$`, String.raw`$x_[i\`]$`, "`[code]`", "`$code` $"]) {
      const input = `[${label}](https://example.com "first\nsecond")`
      const main = parseMarkdown(input)
      expect(main.entities.some((entity) => entity.type === MessageEntity_Type.TEXT_URL)).toBe(true)
      expect(fromMd(input).entities.entities.some((entity) => entity.type === MessageEntity_Type.TEXT_URL)).toBe(true)
    }
  })

  test("destination character references decode once, including semantic Inline links", () => {
    const parsed = fromMd('[Maya](inline://user?id=4&amp;agent_id=9 "Agent")')
    expect(parsed.entities.entities[0]).toEqual({
      type: MessageEntity_Type.MENTION, offset: 0n, length: 4n,
      entity: { oneofKind: "mention", mention: { userId: 4n, agentId: 9n } },
    })
    expect(readInlineLinkDestination("https://example.com/&amp;amp;)", 0)?.url).toBe("https://example.com/&amp;")
  })

  test("URL serialization preserves spaces, bracket bytes, queries and literal reference-looking bytes", () => {
    for (const url of ["https://example.com/a b", "https://example.com/a\tb", "https://example.com/<a>b",
      "https://example.com/?a=1&b=2", "https://example.com/&amp;", "https://example.com/&#x1f680;",
      String.raw`https://example.com/\&copy;`, String.raw`https://example.com/a\(b)c`]) {
      const entities: MessageEntities = { entities: [urlEntity(url)] }
      const markdown = toMd("label", entities)
      expect(parseMarkdown(markdown)).toEqual({ text: "label", entities: entities.entities })
      expect(fromMd(markdown)).toEqual({ text: "label", entities })
    }
    expect(toMd("label", { entities: [urlEntity("https://example.com/?a=1&b=2")] }))
      .toBe("[label](https://example.com/?a=1&b=2)")
  })

  test("multiline semantic labels retain line endings without creating Markdown blocks", () => {
    for (const label of ["a\n\nb", "a\r\nb", "a\rb", "a\n# b", "a\n~~~\nb", "a&#10;b"]) {
      const targets: MessageEntity[] = [urlEntity("https://example.com", label.length), {
        type: MessageEntity_Type.MENTION, offset: 0n, length: BigInt(label.length),
        entity: { oneofKind: "mention", mention: { userId: 4n, agentId: 9n } },
      }]
      for (const target of targets) {
        const entities = { entities: [target] }
        const markdown = toMd(label, entities)
        expect(fromMd(markdown)).toEqual({ text: label, entities })
        const main = parseMarkdown(markdown)
        expect(main.text).toBe(label)
        expect(main.entities).toHaveLength(1)
        expect(main.entities[0]).toMatchObject({ offset: 0n, length: BigInt(label.length) })
      }
    }
  })

  test("control-byte and malformed UTF-16 destinations fall back without corrupting text", () => {
    for (const url of ["https://example.com/a\nb", "https://example.com/a\rb", "https://example.com/a\fb",
      "https://example.com/\ud800", "https://example.com/\udfff", "https://example.com/\ud800a\udc00"]) {
      const markdown = toMd("label", { entities: [urlEntity(url)] })
      expect(markdown).toBe("label")
      expect(parseMarkdown(markdown)).toEqual({ text: "label", entities: [] })
      expect(fromMd(markdown)).toEqual({ text: "label", entities: { entities: [] } })
      expect(new TextDecoder().decode(new TextEncoder().encode(markdown))).toBe(markdown)
    }
    const valid = { entities: [urlEntity("https://example.com/😀")] }
    expect(fromMd(toMd("label", valid))).toEqual({ text: "label", entities: valid })
  })

  test("table links and image serialization agree with the canonical parser and media source projection", () => {
    const table = '| Link |\n| --- |\n| [guide](<https://example.com/a b> "title") |'
    const flat = parseMarkdown(table)
    const blocks = parseBlockContent(table)!
    expect(() => validateBlockContent(flat.text, blocks.blockContent)).not.toThrow()
    expect(flat.entities.find((entity) => entity.type === MessageEntity_Type.TEXT_URL)?.entity)
      .toEqual({ oneofKind: "textUrl", textUrl: { url: "https://example.com/a b" } })
    const block = blocks.blockContent.blocks[0]!
    expect(block.kind.oneofKind).toBe("table")
    if (block.kind.oneofKind !== "table") throw new Error("missing table")
    const cell = block.kind.table.rows[1]!.cells[0]!
    expect(flat.text.slice(Number(cell.offset), Number(cell.offset + cell.length))).toBe("guide")

    const image = parseBlockContent("![photo](https://example.com/a.png)")!
    const imageURL = "https://example.com/a b(1).png?q=&amp;"
    const encoded = encodeBlockContentToMarkdown({
      text: "!photo", blockContent: image.blockContent, options: { imageURL: () => imageURL },
    })
    const reencoded = parseBlockContent(encoded)!
    expect(reencoded.imageSources).toEqual([{ path: [0], url: new URL(imageURL).toString() }])
  })
})
