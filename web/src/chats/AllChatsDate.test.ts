import { describe, expect, it } from "vitest"
import {
  allChatsRowTime,
  allChatsSectionTitle,
} from "./AllChatsDate"

const seconds = (date: Date) => date.getTime() / 1_000

describe("All Chats dates", () => {
  const now = new Date(2026, 6, 20, 14, 30)

  it("uses native Today and Yesterday section names", () => {
    expect(allChatsSectionTitle(seconds(new Date(2026, 6, 20, 9)), now)).toBe("Today")
    expect(allChatsSectionTitle(seconds(new Date(2026, 6, 19, 21)), now)).toBe("Yesterday")
  })

  it("only shows row time details for recent activity", () => {
    expect(allChatsRowTime(seconds(new Date(2026, 6, 20, 14, 29, 30)), now)).toBe("just now")
    expect(allChatsRowTime(seconds(new Date(2026, 6, 10, 14, 30)), now)).toBeUndefined()
  })
})
