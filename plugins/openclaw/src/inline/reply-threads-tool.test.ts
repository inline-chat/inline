import { describe, expect, it, vi } from "vitest"
import { createInlineReplyThreadsTool } from "./reply-threads-tool"

async function loadTool(params: { senderIsOwner?: boolean; sessionKey?: string; parentChatId?: bigint }) {
  vi.resetModules()
  const invokeRaw = vi.fn(async () => ({
    oneofKind: "getChat",
    getChat: { chat: { id: 91n, ...(params.parentChatId != null ? { parentChatId: params.parentChatId } : {}) } },
  }))
  vi.doMock("@inline-chat/realtime-sdk", async () => {
    const actual = await vi.importActual<Record<string, unknown>>("@inline-chat/realtime-sdk")
    return {
      ...actual,
      InlineSdkClient: class {
        connect = vi.fn(async () => {})
        close = vi.fn(async () => {})
        invokeRaw = invokeRaw
      },
    }
  })
  const { createInlineReplyThreadsTool: create } = await import("./reply-threads-tool")
  let config: any = { channels: { inline: { token: "token", baseUrl: "https://api.inline.chat" } } }
  const tool = create(
    {
      messageChannel: "inline",
      sessionKey: params.sessionKey ?? "agent:main:inline:group:88:thread:91",
      ...(params.senderIsOwner != null ? { senderIsOwner: params.senderIsOwner } : {}),
    },
    {
      current: () => config,
      mutateConfigFile: async ({ mutate }) => {
        const draft = structuredClone(config)
        mutate(draft)
        config = draft
        return { nextConfig: draft }
      },
    },
  )
  return { tool: tool as ReturnType<typeof createInlineReplyThreadsTool> & { execute: any }, current: () => config }
}

describe("inline/reply-threads-tool", () => {
  it("asked inside a thread, sets the chat it hangs off", async () => {
    const { tool, current } = await loadTool({ senderIsOwner: true, parentChatId: 88n })
    const result = await tool.execute("call", { action: "on" })
    expect(current().channels.inline.groups["88"].replyThreadMode).toBe("on")
    expect(JSON.stringify(result)).toContain('\\"mode\\": \\"on\\"')
  })

  it("sets a DM by its chat id", async () => {
    const { tool, current } = await loadTool({
      senderIsOwner: true,
      sessionKey: "agent:main:inline:direct:42",
    })
    await tool.execute("call", { action: "on" })
    expect(current().channels.inline.groups["91"].replyThreadMode).toBe("on")
  })

  it("reset clears the chat's setting back to Auto", async () => {
    const { tool, current } = await loadTool({ senderIsOwner: true, parentChatId: 88n })
    await tool.execute("call", { action: "on" })
    const result = await tool.execute("call", { action: "reset" })
    expect(current().channels.inline.groups["88"].replyThreadMode).toBeUndefined()
    expect(JSON.stringify(result)).toContain('\\"mode\\": \\"auto\\"')
  })

  it("only the owner can change it, and anyone can read it", async () => {
    const { tool, current } = await loadTool({ senderIsOwner: false, parentChatId: 88n })
    await expect(tool.execute("call", { action: "on" })).rejects.toThrow(/owner/)
    expect(current().channels.inline.groups).toBeUndefined()
    const result = await tool.execute("call", { action: "status" })
    expect(JSON.stringify(result)).toContain('\\"mode\\": \\"auto\\"')
  })
})
