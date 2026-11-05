import { describe, expect, it } from "bun:test"
import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { prependReplyQuote } from "@in/server/modules/message/replyQuote"

const entity = (type: MessageEntity_Type, offset: number, length: number): MessageEntity => ({
  type,
  offset: BigInt(offset),
  length: BigInt(length),
  entity: { oneofKind: undefined },
})

describe("prependReplyQuote", () => {
  it("puts the quote back before the caption and moves the caption's styles", () => {
    const folded = prependReplyQuote(" quoted\nsecond ", "what now", {
      entities: [entity(MessageEntity_Type.BOLD, 0, 4)],
    })

    expect(folded.text).toBe("quoted\nsecond\nwhat now")
    expect(folded.entities.entities).toEqual([
      entity(MessageEntity_Type.BLOCKQUOTE, 0, 13),
      entity(MessageEntity_Type.BOLD, 14, 4),
    ])
  })

  it("counts offsets in UTF-16 like the apps", () => {
    const folded = prependReplyQuote("لپ تاپ 👋", "what", undefined)

    expect(folded.text).toBe("لپ تاپ 👋\nwhat")
    expect(folded.entities.entities).toEqual([entity(MessageEntity_Type.BLOCKQUOTE, 0, 9)])
  })

  it("keeps a quote sent without a caption", () => {
    const folded = prependReplyQuote("quoted", undefined, undefined)

    expect(folded.text).toBe("quoted")
    expect(folded.entities.entities).toEqual([entity(MessageEntity_Type.BLOCKQUOTE, 0, 6)])
  })
})
