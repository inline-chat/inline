import { describe, expect, test } from "bun:test"
import type { ExternalResourceRecord } from "./externalResources.effect"
import { rankExternalResources } from "./ranking"

const page = (id: string, title: string, extra: Partial<ExternalResourceRecord> = {}): ExternalResourceRecord => ({
  id, title, provider: "notion", kind: "page", url: `https://notion.so/${id}`, ...extra,
})

describe("external resource ranking", () => {
  test("finds an old exact source behind recent task rows", () => {
    const rows = Array.from({ length: 24 }, (_, i) => page(`row-${i}`, `Reminders for customer ${i}`, {
      parentKind: "database", lastEditedTime: "2026-08-30T00:00:00Z",
    }))
    const source = page("source", "Reminders", { kind: "database", lastEditedTime: "2020-01-01T00:00:00Z" })
    expect(rankExternalResources([...rows, source], "reminders", 6)[0]?.id).toBe("source")
  })

  test("relevance outranks structure; structure breaks equally relevant matches", () => {
    const input = [
      page("row", "Reminders", { parentKind: "database" }),
      page("workspace", "Reminders", { parentKind: "workspace" }),
      page("ordinary", "Reminders", { parentKind: "page" }),
      page("source", "Reminders", { kind: "database" }),
      page("irrelevant-source", "Old team reminders", { kind: "database" }),
    ]
    expect(rankExternalResources(input, "  REMINDERS ", 5).map((x) => x.id))
      .toEqual(["source", "workspace", "ordinary", "row", "irrelevant-source"])
  })

  test("deduplicates object IDs across hosts and keeps the richer emoji", () => {
    const id = "01234567-89ab-cdef-0123-456789abcdef"
    const results = rankExternalResources([
      page(id, "Reminders", { url: `https://app.notion.com/p/${id}` }),
      page(id.replaceAll("-", ""), "Reminders", { emoji: "⏰" }),
    ], "Reminders", 6)
    expect(results).toHaveLength(1)
    expect(results[0]).toMatchObject({ id, emoji: "⏰", url: `https://app.notion.com/p/${id}` })
  })

  test("recent search uses recency without a container bias", () => {
    expect(rankExternalResources([
      page("old-source", "Tasks", { kind: "database", lastEditedTime: "2020-01-01T00:00:00Z" }),
      page("recent", "Meeting", { lastEditedTime: "2026-08-30T00:00:00Z" }),
    ], "", 1)[0]?.id).toBe("recent")
  })

  test("matches full Unicode titles before truncating display text", () => {
    const title = `${"😀".repeat(180)} Reminders`
    expect(rankExternalResources([
      page("exact", title), page("prefix", `${title} tomorrow`, { kind: "database" }),
    ], title, 1)[0]).toMatchObject({ id: "exact", title: "😀".repeat(180) })
  })

  test("display truncation preserves joined emoji graphemes", () => {
    const emoji = "👩🏽‍❤️‍💋‍👩🏻"
    expect(rankExternalResources([page("emoji", emoji.repeat(181))], "", 1)[0]?.title).toBe(emoji.repeat(180))
  })
})
