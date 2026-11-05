import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, type BlockContent, type MessageEntity } from "@inline-chat/protocol/core"
import { projectLiteralBlockContent, validateBlockContent } from "./blockContent"

const entity = (type: MessageEntity_Type, offset: number, length: number): MessageEntity => ({
  type, offset: BigInt(offset), length: BigInt(length), entity: { oneofKind: undefined },
})
const quote = (offset: number, length: number) => entity(MessageEntity_Type.BLOCKQUOTE, offset, length)

const shape = (content: BlockContent | undefined, text: string): unknown =>
  content?.blocks.map(function describeBlock(block): unknown {
    switch (block.kind.oneofKind) {
      case "paragraph": {
        const range = block.kind.paragraph
        return text.slice(Number(range.offset), Number(range.offset + range.length))
      }
      case "quote":
        return { quote: block.kind.quote.children.map(describeBlock) }
      default:
        return block.kind.oneofKind
    }
  })

describe("literal blockquote projection", () => {
  test("projects a leading quote and the reply after it", () => {
    const text = "ship the quote reply on Friday\nYes, let's do it"
    const projected = projectLiteralBlockContent(text, { entities: [quote(0, 30)] })
    expect(shape(projected?.blockContent, text)).toEqual([
      { quote: ["ship the quote reply on Friday"] },
      "Yes, let's do it",
    ])
    validateBlockContent(text, projected!.blockContent)
  })

  test("keeps text before and after a quote in the middle", () => {
    const text = "Before\nquoted one\nquoted two\nAfter"
    const projected = projectLiteralBlockContent(text, { entities: [quote(7, 21)] })
    expect(shape(projected?.blockContent, text)).toEqual([
      "Before",
      { quote: ["quoted one\nquoted two"] },
      "After",
    ])
  })

  test("separate quotes in one reply stay separate, in order", () => {
    const text = "first\n\nsecond\nreply"
    const projected = projectLiteralBlockContent(text, { entities: [quote(0, 5), quote(7, 6)] })
    expect(shape(projected?.blockContent, text)).toEqual([{ quote: ["first"] }, { quote: ["second"] }, "reply"])
    validateBlockContent(text, projected!.blockContent)
  })

  test("blank lines inside a quote separate paragraphs", () => {
    const text = "first\n\nsecond\nreply"
    const projected = projectLiteralBlockContent(text, { entities: [quote(0, 13)] })
    expect(shape(projected?.blockContent, text)).toEqual([{ quote: ["first", "second"] }, "reply"])
  })

  test("rejects ranges that do not own whole lines", () => {
    const text = "say hello there\nnext"
    for (const range of [quote(4, 5), quote(0, 9), quote(4, 11)]) {
      expect(projectLiteralBlockContent(text, { entities: [range] })).toBeUndefined()
    }
  })

  test("rejects blank, malformed, and code-crossing quotes", () => {
    const text = "  \ncode\nmore"
    expect(projectLiteralBlockContent(text, { entities: [quote(0, 2)] })).toBeUndefined()
    expect(projectLiteralBlockContent(text, { entities: [quote(3, 99)] })).toBeUndefined()
    expect(projectLiteralBlockContent(text, {
      entities: [quote(3, 4), entity(MessageEntity_Type.PRE, 3, 9)],
    })).toBeUndefined()
  })

  test("inline code and styles stay inside the quoted paragraph", () => {
    const text = "run `bun test` now\nok"
    const projected = projectLiteralBlockContent(text, {
      entities: [quote(0, 18), entity(MessageEntity_Type.CODE, 4, 10), entity(MessageEntity_Type.BOLD, 0, 3)],
    })
    expect(shape(projected?.blockContent, text)).toEqual([{ quote: ["run `bun test` now"] }, "ok"])
  })

  test("overlapping quotes keep the first range", () => {
    const text = "a\nb\nc"
    const projected = projectLiteralBlockContent(text, { entities: [quote(0, 3), quote(2, 3)] })
    expect(shape(projected?.blockContent, text)).toEqual([{ quote: ["a\nb"] }, "c"])
  })
})
