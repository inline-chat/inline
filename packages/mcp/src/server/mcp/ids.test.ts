import { describe, expect, it } from "vitest"
import { formatInlineMessageId, formatInlineMessageUrl, parseInlineMessageId } from "./ids"

describe("inline message ids", () => {
  it("roundtrips format/parse", () => {
    const id = formatInlineMessageId({ chatId: 123n, messageId: 456n })
    expect(id).toBe("inline:chat:123:msg:456")
    expect(parseInlineMessageId(id)).toEqual({ chatId: 123n, messageId: 456n })
  })

  it("rejects invalid ids", () => {
    expect(() => parseInlineMessageId("")).toThrow()
    expect(() => parseInlineMessageId("inline:chat:1:msg")).toThrow()
    expect(() => parseInlineMessageId("nope:chat:1:msg:2")).toThrow()
    expect(() => parseInlineMessageId("inline:space:1:msg:2")).toThrow()
    expect(() => parseInlineMessageId("inline:chat:-1:msg:2")).toThrow()
    expect(() => parseInlineMessageId("inline:chat:1:msg:0")).toThrow()
  })

  it("formats a conservative url", () => {
    expect(formatInlineMessageUrl({ chatId: 7n, messageId: 9n })).toBe("inline://chat/7#message=9")
  })
})

