import { describe, test, expect } from "bun:test"
import { processMessageText } from "./processText"
import { MessageEntity_Type, MessageEntity_MessageEntityTextUrl } from "@in/protocol/core"

describe("Markdown removal", () => {
  test("should remove markdown", () => {
    const text = "Hello **bold** world"
    const result = processMessageText({ text, entities: { entities: [] } })

    expect(result.entities).toEqual({ entities: [] })
    expect(result.text).toBe("Hello bold world")
  })

  test("should remove markdown with entities", () => {
    const text = "Hello **bold** [link](https://example.com) world"
    const result = processMessageText({
      text,
      entities: {
        entities: [
          {
            offset: BigInt(6),
            length: BigInt(4),
            type: MessageEntity_Type.BOLD,
            entity: { oneofKind: undefined },
          },
        ],
      },
    })

    expect(result.entities).toEqual({
      entities: [],
    })
    expect(result.text).toBe("Hello bold link world")
  })

  test("should preserve multiline text", () => {
    const text = "Hello **bold**\nworld"
    const result = processMessageText({ text, entities: { entities: [] } })

    expect(result.text).toBe("Hello bold\nworld")
  })

  test("should preserve text with entities if no markdown", () => {
    const text = "Hello world"
    const result = processMessageText({
      text,
      entities: {
        entities: [
          {
            offset: BigInt(6),
            length: BigInt(4),
            type: MessageEntity_Type.BOLD,
            entity: { oneofKind: undefined },
          },
        ],
      },
    })

    expect(result.text).toBe("Hello world")
    expect(result.entities).toEqual({
      entities: [
        {
          offset: BigInt(6),
          length: BigInt(4),
          type: MessageEntity_Type.BOLD,
          entity: { oneofKind: undefined },
        },
      ],
    })
  })

  test("should preserve normal URLs", () => {
    const text = "Hello https://example.com world"
    const result = processMessageText({ text, entities: { entities: [] } })

    expect(result.text).toBe("Hello https://example.com world")
    expect(result.entities).toEqual({ entities: [] })
  })
})
