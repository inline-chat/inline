import { describe, expect, it } from "vitest"
import { threadResourceDomains } from "./thread-ui"

describe("thread resource CSP", () => {
  it("allows only the default photo origin and configured exact HTTPS origins", () => {
    expect(threadResourceDomains("")).toEqual(["https://api.inline.chat"])
    expect(threadResourceDomains(" https://media.example.com,https://api.inline.chat,https://media.example.com/ "))
      .toEqual(["https://api.inline.chat", "https://media.example.com"])
  })

  it.each(["http://media.example.com", "https://*.example.com", "https://media.example.com/path", "https://user:secret@media.example.com", "https://media.example.com?key=value", "https://media.example.com#fragment", "media.example.com"])("rejects a widened or malformed asset origin: %s", (value) => {
    expect(() => threadResourceDomains(value)).toThrow("MCP_UI_RESOURCE_DOMAINS")
  })
})
