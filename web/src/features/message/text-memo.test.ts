import type { MessageRow, ReactionSummary } from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { createMessageTextMemo } from "./text-memo"

const chatId = "7" as ChatID
const message = (id: string, text: string, extra: Partial<MessageRow> = {}): MessageRow => ({
  kind: "message",
  id,
  chatId,
  messageId: id.split(":")[1] as MessageID,
  fromId: "1" as UserID,
  out: false,
  date: 1_700_000_000,
  text,
  state: "sent",
  ...extra,
})

const reaction = (emoji: string, count: number, mine = false): ReactionSummary => ({ emoji, count, mine })

describe("MessageTextMemo", () => {
  it("returns the same content while the text and entities are unchanged", () => {
    const memo = createMessageTextMemo()
    const row = message("7:1", "Hello")
    const first = memo.read(row)
    expect(memo.read(row)).toBe(first)
    // A new row object (a reaction changed) with the same text keeps the content.
    const reacted: MessageRow = { ...row, reactions: [reaction("👍", 1)] }
    expect(memo.read(reacted)).toBe(first)
    expect(memo.builds).toBe(1)
  })

  it("keeps the identity of unchanged blocks while text streams in", () => {
    const memo = createMessageTextMemo()
    const full = "First paragraph.\n\nSecond paragraph grows"
    let previous = memo.read(message("7:1", "First paragraph.\n\nSe"))
    const firstBlock = previous.document.blocks[0]
    for (let end = 21; end <= full.length; end += 1) {
      const next = memo.read(message("7:1", full.slice(0, end)))
      expect(next).not.toBe(previous)
      expect(next.document.blocks[0]).toBe(firstBlock)
      previous = next
    }
    expect(previous.document.text).toBe(full)
  })

  it("starts over for a different row instead of reusing its nodes", () => {
    const memo = createMessageTextMemo()
    const a = memo.read(message("7:1", "Same text"))
    const b = memo.read(message("7:2", "Same text"))
    expect(b).not.toBe(a)
    expect(b.document).not.toBe(a.document)
  })

  it("rebuilds when the entities change and carries the emoji class", () => {
    const memo = createMessageTextMemo()
    const plain = memo.read(message("7:1", "see docs"))
    // An entity that renders nothing ("docs" is no link) leaves the document as it was.
    const same = memo.read(message("7:1", "see docs", { entities: [{ type: "url", offset: 4, length: 4 }] }))
    expect(same.document).toBe(plain.document)
    const bold = memo.read(message("7:1", "see docs", { entities: [{ type: "bold", offset: 4, length: 4 }] }))
    expect(bold).not.toBe(plain)
    expect(bold.document.blocks[0]).not.toBe(plain.document.blocks[0])
    expect(memo.read(message("7:1", "🎉")).emoji).toBe("single")
    expect(memo.read(message("7:1", "🎉 done")).emoji).toBe("none")
  })
})
