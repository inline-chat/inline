import { chatId, messageId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { FullChatWindowState } from "./full-chat-window"
import { messageKey } from "./models"

const keys = (count: number) =>
  Array.from({ length: count }, (_, index) =>
    messageKey(chatId(10), messageId(index + 1)),
  )

describe("FullChatWindowState", () => {
  it("keeps renderer windows isolated", () => {
    const state = new FullChatWindowState()
    const first = keys(3)
    state.activate(chatId(10), first)
    state.activate(chatId(20), [])
    state.extend(chatId(20), [
      messageKey(chatId(20), messageId(9)),
    ])

    expect(state.keys(chatId(10))).toEqual(first)
    expect(state.keys(chatId(20))).toEqual([
      messageKey(chatId(20), messageId(9)),
    ])
  })

  it("trims only the far newer edge while viewing old history", () => {
    const state = new FullChatWindowState()
    const ordered = keys(700)
    state.activate(chatId(10), ordered)

    const removed = state.compact(
      chatId(10),
      ordered,
      ordered[40]!,
      ordered[60]!,
      500,
    )

    expect(removed).toEqual(ordered.slice(500))
    expect(state.keys(chatId(10))).toEqual(ordered.slice(0, 500))
    expect(state.isAtLatest(chatId(10))).toBe(false)
  })

  it("trims only the far older edge while viewing newer history", () => {
    const state = new FullChatWindowState()
    const ordered = keys(700)
    state.activate(chatId(10), ordered)

    const removed = state.compact(
      chatId(10),
      ordered,
      ordered[630]!,
      ordered[650]!,
      500,
    )

    expect(removed).toEqual(ordered.slice(0, 200))
    expect(state.keys(chatId(10))).toEqual(ordered.slice(200))
    expect(state.isAtLatest(chatId(10))).toBe(true)
  })
})
