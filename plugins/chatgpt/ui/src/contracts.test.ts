import { expect, it } from "vitest"
import { sampleThread } from "../scripts/fixtures"
import { mergeRecentMessages, readThreadSnapshot, readWidgetState, rememberThread, safeUrl } from "./contracts"

it("stores only explicit thread references rather than arbitrary chat metadata", () => {
  const thread = sampleThread()
  const state = rememberThread(readWidgetState(null), { ...thread.chat, peer: { userId: "9", displayName: "Private metadata" } } as typeof thread.chat)
  expect(state.threads).toEqual([{ chatId: "800", title: "Feedback on the proposal" }])
  expect(rememberThread(state, thread.chat)).toBe(state)
})

it("rejects unsafe media URLs and malformed native IDs instead of rendering active content", () => {
  expect(safeUrl("javascript:alert('test')")).toBeNull()
  expect(safeUrl("https://account:secret@example.com/file")).toBeNull()
  expect(safeUrl("http://example.com/file")).toBeNull()
  expect(safeUrl("https://api.inline.chat/file?expires=123")).toBe("https://api.inline.chat/file?expires=123")
  const thread = sampleThread()
  expect(readThreadSnapshot({ structuredContent: { ...thread, messages: [{ ...thread.messages[0], id: "9".repeat(1000) }] } })).toBeNull()
  expect(readThreadSnapshot({ structuredContent: { ...thread, details: { emoji: { injected: true } } } })).toBeNull()
})

it("refreshes the latest complete range without dropping older loaded pages", () => {
  const thread = sampleThread()
  const older = { ...thread.messages[0]!, id: "79999" }
  const updated = { ...thread.messages[3]!, text: "Updated reply" }
  const rows = mergeRecentMessages([older, ...thread.messages], [updated, thread.messages[4]!], "80004")
  expect(rows.map((row) => row.id)).toEqual(["79999", "80001", "80002", "80003", "80004", "80005"])
  expect(rows.find((row) => row.id === updated.id)?.text).toBe("Updated reply")
})

it("retains unresolved receipt fences independently of the bounded picker", () => {
  const state = readWidgetState({ version: 1, threads: [], activeChatId: null, unconfirmed: { "800": { text: "A previously attempted send", replyToMsgId: "80001" } } })
  expect(state.unconfirmed).toEqual({ "800": { text: "A previously attempted send", replyToMsgId: "80001" } })
  let remembered = state
  for (let id = 801; id <= 812; id++) remembered = rememberThread(remembered, { chatId: String(id), title: "Opened thread" })
  expect(readWidgetState(remembered).unconfirmed).toEqual(state.unconfirmed)
})

it("removes a deleted oldest row when the backend confirms the entire history was returned", () => {
  const thread = sampleThread()
  const current = thread.messages.slice(1)
  expect(mergeRecentMessages(thread.messages, current, null)).toEqual(current)
})
