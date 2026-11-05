import { describe, expect, it } from "bun:test"
import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { splitLeadingReplyQuote } from "@in/server/modules/message/replyQuote"

const entity = (type: MessageEntity_Type, offset: number, length: number): MessageEntity => ({
  type,
  offset: BigInt(offset),
  length: BigInt(length),
  entity: { oneofKind: undefined },
})

describe("splitLeadingReplyQuote", () => {
  it("moves the opening quote out and keeps the caption's own styles", () => {
    const split = splitLeadingReplyQuote("quoted\nsecond\nwhat now", {
      entities: [
        entity(MessageEntity_Type.BLOCKQUOTE, 0, 13),
        entity(MessageEntity_Type.BOLD, 1, 2),
        entity(MessageEntity_Type.BOLD, 14, 4),
      ],
    })

    expect(split?.quote).toBe("quoted\nsecond")
    expect(split?.caption).toBe("what now")
    expect(split?.entities?.entities).toEqual([entity(MessageEntity_Type.BOLD, 0, 4)])
  })

  it("counts offsets in UTF-16 like the apps", () => {
    const split = splitLeadingReplyQuote("لپ تاپ 👋\nwhat", {
      entities: [entity(MessageEntity_Type.BLOCKQUOTE, 0, 9)],
    })

    expect(split?.quote).toBe("لپ تاپ 👋")
    expect(split?.caption).toBe("what")
  })

  it("leaves messages without an opening quote or without a caption alone", () => {
    expect(splitLeadingReplyQuote("quoted", { entities: [entity(MessageEntity_Type.BLOCKQUOTE, 0, 6)] })).toBeUndefined()
    expect(
      splitLeadingReplyQuote("reply\nquoted", { entities: [entity(MessageEntity_Type.BLOCKQUOTE, 6, 6)] }),
    ).toBeUndefined()
    expect(splitLeadingReplyQuote("plain", undefined)).toBeUndefined()
  })
})
