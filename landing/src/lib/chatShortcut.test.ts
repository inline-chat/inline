import { describe, expect, it } from "vitest"

import { chatShortcutDeepLink, chatShortcutResponse } from "./chatShortcut"

describe("chatShortcutDeepLink", () => {
  it("builds a deep link without adding thread metadata", () => {
    expect(chatShortcutDeepLink("123456")).toBe("in://chat/123456")
  })

  it("accepts the largest signed 64-bit chat id", () => {
    expect(chatShortcutDeepLink("9223372036854775807")).toBe(
      "in://chat/9223372036854775807",
    )
  })

  it.each([
    "",
    "0",
    "-1",
    "12.3",
    "chat-12",
    "9223372036854775808",
    "99999999999999999999999999999999999999999999999999",
  ])(
    "rejects invalid chat id %s",
    (chatId) => {
      expect(chatShortcutDeepLink(chatId)).toBeNull()
    },
  )
})

describe("chatShortcutResponse", () => {
  it("returns only a private deep-link shortcut", async () => {
    const response = chatShortcutResponse("123456")

    expect(response.status).toBe(200)
    expect(response.headers.get("cache-control")).toBe("private, no-store")
    expect(response.headers.get("referrer-policy")).toBe("no-referrer")
    expect(response.headers.get("x-robots-tag")).toContain("noindex")
    expect(await response.text()).toContain('content="0;url=in://chat/123456"')
  })

  it("returns an empty 404 for an invalid id", async () => {
    const response = chatShortcutResponse("not-a-chat")

    expect(response.status).toBe(404)
    expect(await response.text()).toBe("")
  })

  it("omits the body for HEAD requests", async () => {
    const response = chatShortcutResponse("123456", false)

    expect(response.status).toBe(200)
    expect(await response.text()).toBe("")
  })
})
