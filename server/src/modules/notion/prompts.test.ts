import { describe, expect, test } from "bun:test"
import { systemPrompt14 } from "./prompts"

describe("systemPrompt14", () => {
  test("directs the agent to return markdown instead of legacy block arrays", () => {
    expect(systemPrompt14).toContain("properties, markdown, icon")
    expect(systemPrompt14).toContain("A markdown string, or null.")
    expect(systemPrompt14).toContain("Return valid JSON only.")
    expect(systemPrompt14).not.toContain("description:\n  - An array of simplified blocks")
  })
})
