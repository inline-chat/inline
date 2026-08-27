import { afterEach, describe, expect, it, vi } from "vitest"

afterEach(() => vi.unstubAllGlobals())

describe("inline/agents-tool", () => {
  it("creates a name-only Agent without inventing skill or instructions", async () => {
    const fetchMock = vi.fn(async (_url: string, _init?: RequestInit) =>
      new Response(JSON.stringify({
        ok: true,
        result: { agent: { id: 7, bot_user_id: 200, name: "Concierge" } },
      }), { status: 200, headers: { "content-type": "application/json" } }))
    vi.stubGlobal("fetch", fetchMock)
    const { createInlineAgentsTool } = await import("./agents-tool")
    const tool = createInlineAgentsTool({
      config: { channels: { inline: { token: "secret", baseUrl: "https://api.inline.chat" } } },
    } as never)
    const result = await tool?.execute("call-1", { action: "create", name: "Concierge" })
    expect(result).toMatchObject({ content: expect.any(Array) })
    const [, init] = fetchMock.mock.calls[0] ?? []
    expect(JSON.parse(String(init?.body))).toEqual({ name: "Concierge" })
  })

  it("gets an Agent by globally unique ID", async () => {
    const fetchMock = vi.fn(async (_url: string) =>
      new Response(JSON.stringify({ ok: true, result: { agent: { id: 7, name: "Concierge" } } }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }))
    vi.stubGlobal("fetch", fetchMock)
    const { createInlineAgentsTool } = await import("./agents-tool")
    const tool = createInlineAgentsTool({
      config: { channels: { inline: { token: "secret", baseUrl: "https://api.inline.chat" } } },
    } as never)
    await tool?.execute("call-2", { action: "get", agent_id: 7 })
    expect(String(fetchMock.mock.calls[0]?.[0])).toContain("agent_id=7")
  })

  it("updates fields, including explicit clears", async () => {
    const fetchMock = vi.fn(async () =>
      new Response(JSON.stringify({ ok: true, result: { agent: { id: 7, name: "Data Analyst" } } }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }))
    vi.stubGlobal("fetch", fetchMock)
    const { createInlineAgentsTool } = await import("./agents-tool")
    const tool = createInlineAgentsTool({
      config: { channels: { inline: { token: "secret", baseUrl: "https://api.inline.chat" } } },
    } as never)!

    await tool.execute("call-1", {
      action: "update",
      agent_id: 7,
      name: "Data Analyst",
      description: "",
    })

    expect(String(fetchMock.mock.calls[0]?.[0])).toContain("/updateAgent")
    const [, init] = fetchMock.mock.calls[0] ?? []
    expect(JSON.parse(String(init?.body))).toEqual({ agent_id: 7, name: "Data Analyst", description: "" })
  })

  it("deletes an Agent by globally unique ID", async () => {
    const fetchMock = vi.fn(async () =>
      new Response(JSON.stringify({ ok: true, result: { agent_id: 7 } }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }))
    vi.stubGlobal("fetch", fetchMock)
    const { createInlineAgentsTool } = await import("./agents-tool")
    const tool = createInlineAgentsTool({
      config: { channels: { inline: { token: "secret", baseUrl: "https://api.inline.chat" } } },
    } as never)!

    await tool.execute("call-1", { action: "delete", agent_id: 7 })

    expect(String(fetchMock.mock.calls[0]?.[0])).toContain("/deleteAgent")
    const [, init] = fetchMock.mock.calls[0] ?? []
    expect(JSON.parse(String(init?.body))).toEqual({ agent_id: 7 })
  })
})
