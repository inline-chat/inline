import { describe, expect, test } from "bun:test"
import {
  BlockContent,
  MessageEntity,
  MessageEntity_Type,
  type MessageEntity as MessageEntityValue,
} from "../src/core.js"

const range = (type: MessageEntity_Type): MessageEntityValue => ({
  type,
  offset: 3n,
  length: 5n,
  entity: { oneofKind: undefined },
})

describe("rich text protocol", () => {
  test("keeps additive style and math wire values stable", () => {
    expect([
      MessageEntity_Type.UNDERLINE,
      MessageEntity_Type.STRIKETHROUGH,
      MessageEntity_Type.HIGHLIGHT,
      MessageEntity_Type.MATH,
    ]).toEqual([15, 16, 17, 18])
  })

  test("round trips range-only inline styles and math", () => {
    for (const type of [
      MessageEntity_Type.UNDERLINE,
      MessageEntity_Type.STRIKETHROUGH,
      MessageEntity_Type.HIGHLIGHT,
      MessageEntity_Type.MATH,
    ]) {
      const value = range(type)
      expect(MessageEntity.fromBinary(MessageEntity.toBinary(value))).toEqual(value)
    }
  })

  test("round trips explicit display intent and structural math", () => {
    const entity: MessageEntityValue = {
      ...range(MessageEntity_Type.MATH),
      entity: { oneofKind: "math", math: { display: true } },
    }
    expect(MessageEntity.fromBinary(MessageEntity.toBinary(entity))).toEqual(entity)

    const content: BlockContent = {
      blocks: [{ kind: { oneofKind: "math", math: { offset: 3n, length: 5n } } }],
    }
    expect(BlockContent.fromBinary(BlockContent.toBinary(content))).toEqual(content)
  })
})
