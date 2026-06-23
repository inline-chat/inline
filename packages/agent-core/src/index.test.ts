import { describe, expect, test } from "bun:test"
import { isAgentRunTerminalStatus, mergeToolPacks, textMessage, type AgentTool } from "./index"

const params = {
  type: "object",
  additionalProperties: false,
  properties: {},
}

function tool(name: string): AgentTool {
  return {
    name,
    parameters: params,
    run: () => ({ ok: true }),
  }
}

describe("agent-core", () => {
  test("identifies terminal run statuses", () => {
    expect(isAgentRunTerminalStatus("succeeded")).toBe(true)
    expect(isAgentRunTerminalStatus("running")).toBe(false)
  })

  test("merges tool packs with duplicate name protection", () => {
    const merged = mergeToolPacks("inline", { name: "chat", tools: [tool("read_chat")] }, { name: "files", tools: [tool("read_file")] })

    expect(merged.tools.map((item) => item.name)).toEqual(["read_chat", "read_file"])
    expect(() => mergeToolPacks("bad", { name: "a", tools: [tool("same")] }, { name: "b", tools: [tool("same")] })).toThrow(
      "Duplicate agent tool: same",
    )
  })

  test("creates simple text messages", () => {
    expect(textMessage("user", "hello")).toEqual({
      role: "user",
      parts: [{ type: "text", text: "hello" }],
    })
  })
})
