import { describe, expect, test } from "bun:test"
import { cleanInlineMarkdown, userVisibleError } from "./inlineMarkdown"

describe("inline markdown hygiene", () => {
  test("trims trailing whitespace and closes dangling code fences", () => {
    expect(cleanInlineMarkdown("  hello  \n```ts\nconst a = 1  \n")).toBe("hello\n```ts\nconst a = 1\n```")
  })

  test("normalizes indented list markers outside code fences", () => {
    const input = [
      "1. **Domain age**",
      " - Look it up on WHOIS services like:",
      " - `whois.com`",
      " - `lookup.icann.org`",
      "",
      "```",
      " - keep this code line unchanged",
      "```",
    ].join("\n")

    expect(cleanInlineMarkdown(input)).toBe([
      "1. **Domain age**",
      "- Look it up on WHOIS services like:",
      "- `whois.com`",
      "- `lookup.icann.org`",
      "",
      "```",
      " - keep this code line unchanged",
      "```",
    ].join("\n"))
  })

  test("strips unsupported markdown heading markers outside code fences", () => {
    const input = [
      "## Useful links",
      "",
      "```md",
      "## keep code heading",
      "```",
      "",
      "### More details ###",
    ].join("\n")

    expect(cleanInlineMarkdown(input)).toBe([
      "Useful links",
      "",
      "```md",
      "## keep code heading",
      "```",
      "",
      "More details",
    ].join("\n"))
  })

  test("bounds long replies", () => {
    const cleaned = cleanInlineMarkdown("x".repeat(25_000))

    expect(cleaned.length).toBeLessThan(24_050)
    expect(cleaned.endsWith("[truncated]")).toBe(true)
  })

  test("maps expected user visible errors", () => {
    expect(userVisibleError("not_connected")).toContain("Settings > Connections")
    expect(userVisibleError("canceled")).toBe("Stopped.")
    expect(userVisibleError("other")).toContain("unavailable")
  })
})
