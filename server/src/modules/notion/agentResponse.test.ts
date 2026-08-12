import { describe, expect, test } from "bun:test"
import { parseNotionAgentResponse } from "./agentResponse"

describe("parseNotionAgentResponse", () => {
  test("prefers structured parsed output even when raw content is malformed", () => {
    const result = parseNotionAgentResponse({
      parsed: {
        properties: {
          Name: {
            title: [{ text: { content: "Ship the fix" } }],
          },
        },
        markdown: "## Goal\n\nHandle invalid JSON from the model.",
        icon: null,
      },
      content: '{"properties":[',
    })

    expect(result.properties).toEqual({
      Name: {
        title: [{ text: { content: "Ship the fix" } }],
      },
    })
    expect(result.markdown).toBe("## Goal\n\nHandle invalid JSON from the model.")
    expect(result.icon).toBeNull()
  })

  test("falls back to parsing raw JSON content when parsed output is absent", () => {
    const result = parseNotionAgentResponse({
      content: JSON.stringify({
        properties: {
          Name: {
            title: [{ text: { content: "Follow up with Notion" } }],
          },
        },
        markdown: "- Follow up with Notion",
        icon: null,
      }),
    })

    expect(result.properties).toEqual({
      Name: {
        title: [{ text: { content: "Follow up with Notion" } }],
      },
    })
    expect(result.markdown).toBe("- Follow up with Notion")
  })

  test("normalizes blank markdown to null", () => {
    const result = parseNotionAgentResponse({
      parsed: {
        properties: {
          Name: {
            title: [{ text: { content: "Keep the valid task data" } }],
          },
        },
        markdown: "   \n\n",
        icon: null,
      },
    })

    expect(result.properties).toEqual({
      Name: {
        title: [{ text: { content: "Keep the valid task data" } }],
      },
    })
    expect(result.markdown).toBeNull()
  })

  test("preserves dynamic Notion property payloads without widening the response envelope", () => {
    const result = parseNotionAgentResponse({
      parsed: {
        properties: {
          Name: { title: [{ text: { content: "Ship connector settings" } }] },
          Status: { status: { name: "In progress" } },
          Due: { date: { start: "2026-08-14", end: null } },
          Assignee: { people: [{ id: "notion-user-id" }] },
        },
        markdown: "  ## Goal\n\nShip connector settings safely.  ",
        icon: { emoji: "🚀" },
        unexpected: "ignored",
      },
    })

    expect(result).toEqual({
      properties: {
        Name: { title: [{ text: { content: "Ship connector settings" } }] },
        Status: { status: { name: "In progress" } },
        Due: { date: { start: "2026-08-14", end: null } },
        Assignee: { people: [{ id: "notion-user-id" }] },
      },
      markdown: "## Goal\n\nShip connector settings safely.",
      icon: null,
    })
  })

  test("rejects a non-object properties payload", () => {
    expect(() => parseNotionAgentResponse({
      parsed: {
        properties: ["not", "a", "property map"],
        markdown: null,
        icon: null,
      },
    })).toThrow()
  })
})
