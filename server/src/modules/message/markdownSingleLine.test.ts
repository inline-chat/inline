import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { fromMd, toMd } from "../translation2/entities"
import { parseMarkdownWithSourceMap } from "./parseMarkdown"
import { processMessageText } from "./processText"

const entity = (type: MessageEntity_Type, offset: number, length: number): MessageEntity => ({
  type, offset: BigInt(offset), length: BigInt(length), entity: { oneofKind: undefined },
})
const values = (text: string, entities: MessageEntity[], type: MessageEntity_Type) => entities
  .filter((item) => item.type === type)
  .map((item) => text.slice(Number(item.offset), Number(item.offset + item.length)))
const parsers = (source: string) => {
  const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
  return [main, { text: translated.text, entities: translated.entities.entities }]
}

describe("shared single-line emphasis grammar", () => {
  test("triple markers and both nesting directions retain exact text and ranges", () => {
    const fixtures: [string, string, string, string][] = [
      ["😀 ***both*** end", "😀 both end", "both", "both"],
      ["*italic **bold** tail*", "italic bold tail", "bold", "italic bold tail"],
      ["**bold *italic* tail**", "bold italic tail", "bold italic tail", "italic"],
      ["_italic __bold__ tail_", "italic bold tail", "bold", "italic bold tail"],
      ["__bold _italic_ tail__", "bold italic tail", "bold italic tail", "italic"],
    ]
    for (const [source, text, bold, italic] of fixtures) for (const result of parsers(source)) {
      expect(result.text).toBe(text)
      expect(values(result.text, result.entities, MessageEntity_Type.BOLD)).toEqual([bold])
      expect(values(result.text, result.entities, MessageEntity_Type.ITALIC)).toEqual([italic])
    }
  })

  test("underscores format words but never remove characters from identifiers", () => {
    for (const source of ["snake_case_name", "foo__bar__baz", "𐐀__word__𐐀", "نام__کاربر__جدید", "123__value__456"]) {
      for (const result of parsers(source)) {
        expect(result.text).toBe(source)
        expect(result.entities).toEqual([])
      }
    }
    for (const result of parsers("_italic_ __bold__")) {
      expect(result.text).toBe("italic bold")
      expect(values(result.text, result.entities, MessageEntity_Type.ITALIC)).toEqual(["italic"])
      expect(values(result.text, result.entities, MessageEntity_Type.BOLD)).toEqual(["bold"])
    }
  })

  test("existing adjacent asterisk ranges work without swallowing nested emphasis", () => {
    for (const [source, type] of [["*one**two*", MessageEntity_Type.ITALIC], ["**one****two**", MessageEntity_Type.BOLD]] as const) {
      for (const result of parsers(source)) {
        expect(result.text).toBe("onetwo")
        expect(values(result.text, result.entities, type)).toEqual(["one", "two"])
      }
    }
    for (const result of parsers("**_one_****_two_**")) {
      expect(result.text).toBe("onetwo")
      expect(values(result.text, result.entities, MessageEntity_Type.BOLD)).toEqual(["one", "two"])
      expect(values(result.text, result.entities, MessageEntity_Type.ITALIC)).toEqual(["one", "two"])
    }
  })

  test("literal stars in code, TeX, escaped text, and link targets remain opaque", () => {
    const fixtures: [string, string][] = [
      ["*first `x**y` last*", "first x**y last"],
      ["*first $x**y$ last*", "first x**y last"],
      [String.raw`*first \*\* last*`, "first ** last"],
      ["*[go](https://e.test/a**b) last*", "go last"],
      ["**first `x****y` last**", "first x****y last"],
    ]
    for (const [source, text] of fixtures) for (const result of parsers(source)) {
      expect(result.text).toBe(text)
      const type = source.startsWith("**") ? MessageEntity_Type.BOLD : MessageEntity_Type.ITALIC
      expect(values(result.text, result.entities, type)).toEqual([text])
    }
  })

  test("adjacent native style ranges serialize without ambiguous repeated markers", () => {
    for (const type of [MessageEntity_Type.BOLD, MessageEntity_Type.ITALIC, MessageEntity_Type.UNDERLINE,
      MessageEntity_Type.STRIKETHROUGH, MessageEntity_Type.HIGHLIGHT]) {
      const source = { entities: [entity(type, 0, 3), entity(type, 3, 3)] }
      const snapshot = structuredClone(source)
      const markdown = toMd("onetwo", source)
      for (const result of parsers(markdown)) {
        expect(result.text).toBe("onetwo")
        expect(values(result.text, result.entities, type)).toEqual(["onetwo"])
      }
      expect(source).toEqual(snapshot)
    }
    const entities = [entity(MessageEntity_Type.BOLD, 0, 3), entity(MessageEntity_Type.ITALIC, 0, 3),
      entity(MessageEntity_Type.BOLD, 3, 3), entity(MessageEntity_Type.ITALIC, 3, 3)]
    expect(toMd("onetwo", { entities })).toBe("***onetwo***")
    for (const result of parsers(toMd("onetwo", { entities }))) {
      expect(result.text).toBe("onetwo")
      expect(values(result.text, result.entities, MessageEntity_Type.BOLD)).toEqual(["onetwo"])
      expect(values(result.text, result.entities, MessageEntity_Type.ITALIC)).toEqual(["onetwo"])
    }
  })

  test("merging adjacent formatting cannot invalidate links or other style ranges", () => {
    const link: MessageEntity = { ...entity(MessageEntity_Type.TEXT_URL, 2, 4),
      entity: { oneofKind: "textUrl", textUrl: { url: "https://e.test" } } }
    const markdown = toMd("abcdef", { entities: [entity(MessageEntity_Type.BOLD, 0, 2), entity(MessageEntity_Type.BOLD, 2, 2), link] })
    expect(markdown).toBe("**ab**[**cd**ef](https://e.test)")
    for (const result of parsers(markdown)) {
      expect(result.text).toBe("abcdef")
      expect(values(result.text, result.entities, MessageEntity_Type.BOLD)).toEqual(["ab", "cd"])
      expect(values(result.text, result.entities, MessageEntity_Type.TEXT_URL)).toEqual(["cdef"])
    }
    const mixed = toMd("abcdef", { entities: [entity(MessageEntity_Type.BOLD, 0, 2), entity(MessageEntity_Type.BOLD, 2, 2),
      entity(MessageEntity_Type.ITALIC, 2, 2), entity(MessageEntity_Type.ITALIC, 4, 2)] })
    for (const result of parsers(mixed)) {
      expect(result.text).toBe("abcdef")
      expect(values(result.text, result.entities, MessageEntity_Type.BOLD)).toEqual(["abcd"])
      expect(values(result.text, result.entities, MessageEntity_Type.ITALIC)).toEqual(["cd", "ef"])
    }
    const leftLink = { ...link, offset: 0n }
    const leftBlocked = toMd("abcdef", { entities: [leftLink,
      entity(MessageEntity_Type.BOLD, 2, 2), entity(MessageEntity_Type.BOLD, 4, 2)] })
    for (const result of parsers(leftBlocked)) {
      expect(result.text).toBe("abcdef")
      expect(values(result.text, result.entities, MessageEntity_Type.BOLD)).toEqual(["cd", "ef"])
      expect(values(result.text, result.entities, MessageEntity_Type.TEXT_URL)).toEqual(["abcd"])
    }
  })

  test("large adjacent style chains remain one semantic range", () => {
    const text = "x".repeat(8_192)
    const markdown = toMd(text, { entities: Array.from({ length: text.length }, (_, index) =>
      entity(MessageEntity_Type.BOLD, index, 1)) })
    expect(markdown).toBe(`**${text}**`)
    for (const result of parsers(markdown)) {
      expect(result.text).toBe(text)
      expect(values(result.text, result.entities, MessageEntity_Type.BOLD)).toEqual([text])
    }
  })

  test("Unicode Agent mentions keep their range through adjacent and nested syntax", () => {
    const source = "😀 *first**@Maya* and ***last***"
    const mention: MessageEntity = { ...entity(MessageEntity_Type.MENTION, source.indexOf("@Maya"), 5),
      entity: { oneofKind: "mention", mention: { userId: 4n, agentId: 8n } } }
    const parsed = processMessageText({ text: source, entities: { entities: [mention] } })
    expect(parsed.text).toBe("😀 first@Maya and last")
    expect(values(parsed.text, parsed.entities!.entities, MessageEntity_Type.MENTION)).toEqual(["@Maya"])
    expect(parsed.entities!.entities.find((item) => item.type === MessageEntity_Type.MENTION)?.entity).toEqual(mention.entity)
  })

  test("one compatibility reader preserves padded stars and underscores with nested links", () => {
    for (const marker of ["*", "**", "_", "__"]) {
      const type = marker.length === 1 ? MessageEntity_Type.ITALIC : MessageEntity_Type.BOLD
      for (const body of [" padded ", " padded `literal` ", " padded [**label**](https://e.test) "]) {
        for (const result of parsers(marker + body + marker)) {
          const expected = body.replace("`literal`", "literal").replace("[**label**](https://e.test)", "label")
          expect(result.text).toBe(expected)
          expect(values(result.text, result.entities, type)).toContain(expected)
        }
      }
    }
  })

  test("a styled link label cannot close its surrounding style", () => {
    for (const marker of ["~~", "=="]) {
      const source = `${marker}before [${marker}label${marker}](https://e.test) after${marker}`
      const type = marker === "~~" ? MessageEntity_Type.STRIKETHROUGH : MessageEntity_Type.HIGHLIGHT
      for (const result of parsers(source)) {
        expect(result.text).toBe("before label after")
        expect(values(result.text, result.entities, type)).toEqual(["before label after", "label"])
        expect(values(result.text, result.entities, MessageEntity_Type.TEXT_URL)).toEqual(["label"])
      }
    }
  })

  test("single-line streaming prefixes maintain monotonic UTF-16 maps", () => {
    for (const source of ["😀 ***both***", "*italic **bold** tail*", "__bold _italic_ tail__", "*one**two*", "**_one_****_two_**"]) {
      for (let end = 0; end <= source.length; end++) {
        const prefix = source.slice(0, end), parsed = parseMarkdownWithSourceMap(prefix)
        expect(parsed.sourceToOutput).toHaveLength(prefix.length + 1)
        expect(parsed.sourceToOutput.at(-1)).toBe(parsed.text.length)
        expect(parsed.sourceToOutput.every((offset, index, map) => Number.isInteger(offset) && offset >= (map[index - 1] ?? 0))).toBe(true)
        for (const result of parsers(prefix)) {
          expect(result.entities.every((item) => item.offset >= 0n && item.length > 0n && item.offset + item.length <= BigInt(result.text.length))).toBe(true)
        }
      }
    }
  })
})
