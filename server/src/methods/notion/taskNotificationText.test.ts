import { describe, expect, test } from "bun:test"
import { notionTaskNotificationText } from "./taskNotificationText"

describe("Notion task notification text", () => {
  test("uses stored plaintext when present", () => {
    expect(notionTaskNotificationText({
      text: "  Stored task message  ",
      textEncrypted: null,
      textIv: null,
      textTag: null,
    })).toBe("Stored task message")
  })

  test("falls back without throwing when encrypted text is unreadable", () => {
    expect(notionTaskNotificationText({
      text: null,
      textEncrypted: Buffer.from("invalid"),
      textIv: Buffer.alloc(12),
      textTag: Buffer.alloc(16),
    })).toBe("A new task has been created from a message")
  })
})
