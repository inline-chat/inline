import { describe, expect, test } from "bun:test"
import { BlockList_Kind, BlockTable_Alignment, MessageEntity_Type, type BlockContent, type MessageEntity } from "@inline-chat/protocol/core"
import { fromMd } from "../translation2/entities"
import { parseBlockContent, validateBlockContent } from "./blockContent"
import { encodeBlockContentToMarkdown } from "./blockContentMarkdown"
import { parseMarkdownWithSourceMap } from "./parseMarkdown"

const entity = (type: MessageEntity_Type, offset: number, length: number): MessageEntity => ({
  type, offset: BigInt(offset), length: BigInt(length), entity: { oneofKind: undefined },
})
const range = (offset: number, length: number) => ({ offset: BigInt(offset), length: BigInt(length) })
const values = (text: string, entities: MessageEntity[], type: MessageEntity_Type) => entities
  .filter((item) => item.type === type)
  .map((item) => text.slice(Number(item.offset), Number(item.offset + item.length)))
const styles = [MessageEntity_Type.BOLD, MessageEntity_Type.ITALIC, MessageEntity_Type.UNDERLINE,
  MessageEntity_Type.STRIKETHROUGH, MessageEntity_Type.HIGHLIGHT]

describe("block Markdown formatting projection", () => {
  test("ordered lists preserve nine-digit starts and reject unsafe native ordinals", () => {
    const content = (start: bigint): BlockContent => ({ blocks: [{ kind: { oneofKind: "list", list: {
      kind: BlockList_Kind.ORDERED, start, items: [0, 1].map((offset) => ({ children: [{
        kind: { oneofKind: "paragraph", paragraph: range(offset, 1) },
      }] })),
    } } }] })
    for (const start of [0n, 999_999_999n]) {
      const markdown = encodeBlockContentToMarkdown({ text: "ab", blockContent: content(start) })
      const parsed = parseBlockContent(markdown)!
      const first = parsed.blockContent.blocks[0]!
      expect(first.kind.oneofKind).toBe("list")
      if (first.kind.oneofKind !== "list") throw new Error("missing list")
      expect(first.kind.list.start).toBe(start)
      expect(first.kind.list.items).toHaveLength(2)
    }
    for (const start of [-1n, 1_000_000_000n, 9_223_372_036_854_775_807n]) {
      for (const profile of ["native", "persisted"] as const) {
        expect(() => validateBlockContent("ab", content(start), profile)).toThrow("Invalid ordered list start")
      }
    }
  })

  test("native styles spanning paragraphs retain both visible fragments without mutating entities", () => {
    const text = "😀 first\n\nlast end"
    const blockContent: BlockContent = { blocks: [
      { kind: { oneofKind: "paragraph", paragraph: range(0, 8) } },
      { kind: { oneofKind: "paragraph", paragraph: range(10, 8) } },
    ] }
    for (const type of styles) {
      const entities = { entities: [entity(type, 3, 11)] }, before = structuredClone(entities)
      const markdown = encodeBlockContentToMarkdown({ text, entities, blockContent })
      const main = parseMarkdownWithSourceMap(markdown), translated = fromMd(markdown)
      expect(main.text).toBe(text)
      expect(translated.text).toBe(text)
      expect(values(main.text, main.entities, type)).toEqual(["first", "last"])
      expect(values(translated.text, translated.entities.entities, type)).toEqual(["first", "last"])
      expect(entities).toEqual(before)
      expect(parseBlockContent(markdown, main)?.blockContent.blocks.map((block) => block.kind.oneofKind)).toEqual(["paragraph", "paragraph"])
    }
  })

  test("a native style crossing table cells is exported independently within each cell", () => {
    const text = "first second third fourth"
    const blockContent: BlockContent = { blocks: [{ kind: { oneofKind: "table", table: {
      alignments: [BlockTable_Alignment.UNSPECIFIED, BlockTable_Alignment.UNSPECIFIED],
      rows: [{ cells: [range(0, 5), range(6, 6)] }, { cells: [range(13, 5), range(19, 6)] }],
    } } }] }
    for (const type of styles) {
      const markdown = encodeBlockContentToMarkdown({ text, blockContent, entities: { entities: [entity(type, 0, text.length)] } })
      const main = parseMarkdownWithSourceMap(markdown), rich = parseBlockContent(markdown, main)!
      expect(values(main.text, main.entities, type)).toEqual(["first", "second", "third", "fourth"])
      expect(rich.blockContent.blocks[0]?.kind.oneofKind).toBe("table")
      expect(rich.warnings).toBeUndefined()
      expect(() => validateBlockContent(main.text, rich.blockContent)).not.toThrow()
      expect(encodeBlockContentToMarkdown({ text: main.text, entities: { entities: main.entities }, blockContent: rich.blockContent })).toBe(markdown)
    }
  })

  test("partial semantic and raw ranges are never promoted to new meaning by clipping", () => {
    const text = "first\n\nsecond", blockContent: BlockContent = { blocks: [
      { kind: { oneofKind: "paragraph", paragraph: range(0, 5) } },
      { kind: { oneofKind: "paragraph", paragraph: range(7, 6) } },
    ] }
    const partial = [
      { ...entity(MessageEntity_Type.TEXT_URL, 0, text.length), entity: { oneofKind: "textUrl" as const, textUrl: { url: "https://e.test" } } },
      { ...entity(MessageEntity_Type.MENTION, 0, text.length), entity: { oneofKind: "mention" as const, mention: { userId: 4n, agentId: 8n } } },
      entity(MessageEntity_Type.CODE, 0, text.length), entity(MessageEntity_Type.MATH, 0, text.length),
      { ...entity(MessageEntity_Type.PRE, 0, text.length), entity: { oneofKind: "pre" as const, pre: { language: "ts" } } },
    ]
    for (const item of partial) {
      expect(encodeBlockContentToMarkdown({ text, blockContent, entities: { entities: [item] } })).toBe(text)
    }
    const contained = { ...entity(MessageEntity_Type.MENTION, 7, 6),
      entity: { oneofKind: "mention" as const, mention: { userId: 4n, agentId: 8n } } }
    const parsed = fromMd(encodeBlockContentToMarkdown({ text, blockContent, entities: { entities: [contained] } }))
    expect(parsed).toEqual({ text, entities: { entities: [contained] } })
  })

  test("out-of-bounds and malformed styles stay invalid instead of being clamped into a block", () => {
    const text = "first", blockContent: BlockContent = { blocks: [{ kind: { oneofKind: "paragraph", paragraph: range(0, text.length) } }] }
    const invalid = [entity(MessageEntity_Type.BOLD, -1, 3), entity(MessageEntity_Type.BOLD, 0, 6),
      entity(MessageEntity_Type.BOLD, 1, 0), entity(MessageEntity_Type.BOLD, 0, -1),
      { ...entity(MessageEntity_Type.BOLD, 0, 1), length: 2n ** 70n }]
    expect(encodeBlockContentToMarkdown({ text, blockContent, entities: { entities: invalid } })).toBe(text)
  })
})
