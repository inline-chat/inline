import { describe, expect, test } from "bun:test"
import { validateMarkdownTranslations } from "./markdownTranslation"

const input = {
  messages: [
    { messageId: 1, markdown: "one" },
    { messageId: 2, markdown: "two" },
  ],
}

describe("validateMarkdownTranslations", () => {
  test("orders validated translations by requested message order", () => {
    expect(
      validateMarkdownTranslations(input as any, [
        { messageId: 2, markdown: "deux" },
        { messageId: 1, markdown: "un" },
      ]),
    ).toEqual([
      { messageId: 1, markdown: "un" },
      { messageId: 2, markdown: "deux" },
    ])
  })

  test("rejects missing duplicate and unexpected message IDs", () => {
    expect(() =>
      validateMarkdownTranslations(input as any, [
        { messageId: 1, markdown: "un" },
        { messageId: 1, markdown: "duplicate" },
        { messageId: 3, markdown: "unexpected" },
      ]),
    ).toThrow("Invalid markdown translation output")
  })
})
