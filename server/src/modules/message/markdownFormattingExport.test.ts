import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { fromMd, toMd } from "../translation2/entities"
import { encodeBlockContentToMarkdown } from "./blockContentMarkdown"
import { parseMarkdownWithSourceMap } from "./parseMarkdown"

const styles = [MessageEntity_Type.BOLD, MessageEntity_Type.ITALIC, MessageEntity_Type.UNDERLINE,
  MessageEntity_Type.STRIKETHROUGH, MessageEntity_Type.HIGHLIGHT]
const entity = (type: MessageEntity_Type, start: number, length: number): MessageEntity => ({
  type, offset: BigInt(start), length: BigInt(length), entity: { oneofKind: undefined },
})
const parsers = (markdown: string) => {
  const main = parseMarkdownWithSourceMap(markdown), translated = fromMd(markdown)
  return [main, { text: translated.text, entities: translated.entities.entities }]
}

describe("idempotent native formatting export", () => {
  test("duplicate styles neither become another style nor turn text into a code fence", () => {
    const text = "😀 abcdef"
    for (const type of styles) {
      const source = { entities: [entity(type, 0, text.length), entity(type, 0, text.length)] }
      const before = structuredClone(source)
      for (const result of parsers(toMd(text, source))) {
        expect(result.text).toBe(text)
        expect(result.entities).toEqual([entity(type, 0, text.length)])
      }
      expect(source).toEqual(before)
    }
  })

  test("contained copies of the same style preserve the full parent coverage", () => {
    const text = "abcdef"
    for (const type of styles) {
      const entities = [entity(type, 0, 6), entity(type, 1, 4), entity(type, 2, 2)]
      for (const ordered of [entities, [...entities].reverse(), [entities[1]!, entities[0]!, entities[2]!]]) {
        for (const result of parsers(toMd(text, { entities: ordered }))) {
          expect(result.text).toBe(text)
          expect(result.entities).toEqual([entity(type, 0, 6)])
        }
      }
    }
  })

  test("a redundant child cannot displace an overlapping Agent mention", () => {
    const text = "😀 abMaya end"
    const mention: MessageEntity = { ...entity(MessageEntity_Type.MENTION, 5, 4),
      entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } }
    for (const type of styles) {
      const source = { entities: [entity(type, 0, text.length), entity(type, 3, 4), mention] }
      const before = structuredClone(source)
      for (const result of parsers(toMd(text, source))) {
        expect(result.text).toBe(text)
        expect(result.entities.filter((item) => item.type === type)).toEqual([entity(type, 0, text.length)])
      }
      const markdown = toMd(text, source)
      // Send parsing resolves Inline URLs later; translation resolves them now.
      expect(parseMarkdownWithSourceMap(markdown).entities.filter((item) => item.type === MessageEntity_Type.TEXT_URL))
        .toEqual([{ ...entity(MessageEntity_Type.TEXT_URL, 5, 4),
          entity: { oneofKind: "textUrl", textUrl: { url: "inline://user?id=42&agent_id=7" } } }])
      expect(fromMd(markdown).entities.entities.filter((item) => item.type === MessageEntity_Type.MENTION)).toEqual([mention])
      expect(source).toEqual(before)
    }
  })

  test("adjacent parent styles merge after their redundant children are removed", () => {
    for (const type of styles) {
      const source = { entities: [entity(type, 0, 3), entity(type, 0, 2), entity(type, 3, 3), entity(type, 4, 1)] }
      for (const result of parsers(toMd("abcdef", source))) {
        expect(result.text).toBe("abcdef")
        expect(result.entities).toEqual([entity(type, 0, 6)])
      }
    }
  })

  test("a long adjacent style chain merges without changing its coverage", () => {
    const text = "a".repeat(8_192)
    const entities = Array.from({ length: text.length }, (_, offset) =>
      entity(MessageEntity_Type.BOLD, offset, 1))
    const markdown = toMd(text, { entities })
    expect(markdown).toBe(`**${text}**`)
    for (const result of parsers(markdown)) {
      expect(result.text).toBe(text)
      expect(result.entities).toEqual([entity(MessageEntity_Type.BOLD, 0, text.length)])
    }
  })

  test("independent styles and opaque code or TeX retain their own semantics", () => {
    const text = "before x^2 raw after"
    const math = entity(MessageEntity_Type.MATH, 7, 3), code = entity(MessageEntity_Type.CODE, 11, 3)
    const source = { entities: [...styles.flatMap((type) => [entity(type, 0, text.length), entity(type, 0, text.length)]), math, code] }
    for (const result of parsers(toMd(text, source))) {
      expect(result.text).toBe(text)
      for (const type of styles) expect(result.entities.filter((item) => item.type === type)).toEqual([entity(type, 0, text.length)])
      expect(result.entities.filter((item) => item.type === MessageEntity_Type.MATH)).toEqual([math])
      expect(result.entities.filter((item) => item.type === MessageEntity_Type.CODE)).toEqual([code])
    }
  })

  test("block export shares the same idempotent formatting normalization", () => {
    const text = "abcdef"
    for (const type of styles) {
      const markdown = encodeBlockContentToMarkdown({ text,
        entities: { entities: [entity(type, 0, 6), entity(type, 2, 2)] },
        blockContent: { blocks: [{ kind: { oneofKind: "paragraph", paragraph: { offset: 0n, length: 6n } } }] },
      })
      for (const result of parsers(markdown)) {
        expect(result.text).toBe(text)
        expect(result.entities).toEqual([entity(type, 0, 6)])
      }
    }
  })

  test("invalid UTF-16 ranges cannot put formatting between surrogate halves on the wire", () => {
    const text = "😀 bold 𐐀 é"
    for (const type of styles) {
      const valid = entity(type, 3, 4)
      const malformed = [entity(type, 1, 1), entity(type, 0, 1), entity(type, 9, 1), entity(type, 8, 1),
        entity(type, -1, 2), entity(type, 0, 0), entity(type, 0, text.length + 1),
        { ...entity(type, 0, 1), offset: 1n << 100n }, { ...entity(type, 0, 1), length: 1n << 100n }]
      const source = { entities: [...malformed, valid] }, before = structuredClone(source)
      const markdown = toMd(text, source)
      expect(markdown).toBe(toMd(text, { entities: [valid] }))
      expect(Buffer.from(markdown, "utf8").toString("utf8")).toBe(markdown)
      for (const result of parsers(markdown)) {
        expect(result.text).toBe(text)
        expect(result.entities).toEqual([valid])
      }
      expect(source).toEqual(before)
    }
  })
})
