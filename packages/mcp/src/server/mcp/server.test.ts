import { afterEach, describe, expect, it, vi } from "vitest"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import type { JSONRPCMessage } from "@modelcontextprotocol/sdk/types.js"
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js"
import { createInlineMcpServer } from "./server"
import type { Grant } from "../store/types"
import type { InlineApi } from "../inline/inline-api"

type Sent = { message: JSONRPCMessage }

function createFakeTransport(): { transport: Transport; sent: Sent[] } {
  const sent: Sent[] = []

  const transport: Transport = {
    async start() {},
    async close() {},
    async send(message) {
      sent.push({ message })
    },
  }

  return { transport, sent }
}

async function sendRequest(transport: Transport, message: JSONRPCMessage, extra?: { authInfo?: AuthInfo }) {
  // The server installs transport.onmessage during connect().
  transport.onmessage?.(message as any, extra as any)
}

async function waitForResponse(sent: Sent[], id: number, timeoutMs = 500): Promise<any> {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    const found = [...sent].reverse().find((s) => (s.message as any).id === id)
    if (found) return found.message as any
    await new Promise((r) => setTimeout(r, 1))
  }
  throw new Error("missing response")
}

function lastMessagesSendAuditRecord(infoSpy: ReturnType<typeof vi.spyOn>) {
  const serialized = infoSpy.mock.calls
    .map((call: unknown[]) => call[0])
    .filter((entry: unknown): entry is string => typeof entry === "string")
    .map((line: string) => {
      try {
        return JSON.parse(line) as unknown
      } catch {
        return null
      }
    })
    .reverse()
    .find((entry: unknown) => {
      if (!entry || typeof entry !== "object") return false
      const record = entry as Record<string, unknown>
      return record.event === "mcp.audit" && record.tool === "messages.send"
    })

  expect(serialized).toBeTruthy()
  return serialized as Record<string, unknown>
}

const grant: Grant = {
  id: "g1",
  clientId: "c1",
  inlineUserId: 1n,
  scope: "messages:read spaces:read messages:write",
  spaceIds: [10n],
  inlineTokenEnc: "v1.fake.fake",
  createdAtMs: Date.now(),
  revokedAtMs: null,
}

describe("mcp tool server", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("search returns message snippets with source chat metadata", async () => {
    const inline: InlineApi = {
      async close() {},
      async getEligibleChats() {
        return []
      },
      async search() {
        return [
          {
            chatId: 7n,
            chatTitle: "General",
            spaceId: 10n,
            message: {
              id: 9n,
              fromId: 1n,
              chatId: 7n,
              peerId: undefined,
              message: "hello world",
              date: 123n,
              entities: undefined,
              randomId: 0n,
              replyToMsgId: undefined,
              edited: undefined,
              views: undefined,
              reactions: [],
              photoId: undefined,
              videoId: undefined,
              documentId: undefined,
              hasLink: undefined,
              translation: undefined,
              isService: undefined,
              serviceAction: undefined,
              postAuthor: undefined,
              topicId: undefined,
              pinned: undefined,
              forwardInfo: undefined,
              externalTaskId: undefined,
            } as any,
          },
        ]
      },
      async fetchMessage() {
        throw new Error("not needed")
      },
      async sendMessage() {
        throw new Error("not needed")
      },
    }

    const server = createInlineMcpServer({ grant, inline })
    const { transport, sent } = createFakeTransport()
    await server.connect(transport as any)

    const authInfo: AuthInfo = { token: "t", clientId: "c1", scopes: ["messages:read"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } },
      } as any,
      { authInfo },
    )

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        method: "notifications/initialized",
        params: {},
      } as any,
      { authInfo },
    )

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: { name: "search", arguments: { query: "hello" } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    expect(res.result.isError).toBeUndefined()
    const text = res.result.content?.[0]?.text
    expect(typeof text).toBe("string")
    const payload = JSON.parse(text)
    expect(Array.isArray(payload.results)).toBe(true)
    expect(payload.results[0].id).toBe("inline:chat:7:msg:9")
    expect(payload.results[0].title).toBe("General")
    expect(payload.results[0].source).toEqual({ chatId: "7", title: "General" })
    expect(payload.results[0].snippet).toBe("hello world")
  })

  it("fetch returns message text and source chat metadata", async () => {
    const inline: InlineApi = {
      async close() {},
      async getEligibleChats() {
        return []
      },
      async search() {
        return []
      },
      async fetchMessage(chatId, messageId) {
        return {
          chat: { id: chatId, title: "General", spaceId: 10n } as any,
          message: { id: messageId, fromId: 2n, chatId, message: "hello", date: 5n } as any,
        }
      },
      async sendMessage() {
        throw new Error("not needed")
      },
    }

    const server = createInlineMcpServer({ grant, inline })
    const { transport, sent } = createFakeTransport()
    await server.connect(transport as any)

    const authInfo: AuthInfo = { token: "t", clientId: "c1", scopes: ["messages:read"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } },
      } as any,
      { authInfo },
    )

    await sendRequest(transport, { jsonrpc: "2.0", method: "notifications/initialized", params: {} } as any, { authInfo })

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: { name: "fetch", arguments: { id: "inline:chat:7:msg:9" } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.id).toBe("inline:chat:7:msg:9")
    expect(payload.title).toBe("General")
    expect(payload.text).toBe("hello")
    expect(payload.source).toEqual({ chatId: "7", title: "General" })
    expect(payload.metadata.chatId).toBe("7")
  })

  it("messages.send requires messages:write", async () => {
    const infoSpy = vi.spyOn(console, "info").mockImplementation(() => {})

    const inline: InlineApi = {
      async close() {},
      async getEligibleChats() {
        return []
      },
      async search() {
        return []
      },
      async fetchMessage() {
        throw new Error("not needed")
      },
      async sendMessage() {
        return { messageId: 123n }
      },
    }

    const server = createInlineMcpServer({ grant, inline })
    const { transport, sent } = createFakeTransport()
    await server.connect(transport as any)

    const authInfo: AuthInfo = { token: "t", clientId: "c1", scopes: ["messages:read"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } },
      } as any,
      { authInfo },
    )

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        method: "notifications/initialized",
        params: {},
      } as any,
      { authInfo },
    )

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: { name: "messages.send", arguments: { chatId: "7", text: "hi", sendMode: "normal", parseMarkdown: true } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    expect(res.result.isError).toBe(true)
    expect(res.result.content?.[0]?.text).toContain("messages:write")

    const audit = lastMessagesSendAuditRecord(infoSpy)
    expect(audit.outcome).toBe("failure")
    expect(audit.grantId).toBe("g1")
    expect(audit.inlineUserId).toBe("1")
    expect(audit.chatId).toBe("7")
    expect(audit.spaceId).toBeNull()
    expect(audit.messageId).toBeNull()
    expect(typeof audit.timestamp).toBe("string")
    expect(audit).not.toHaveProperty("text")
    expect(audit).not.toHaveProperty("token")
    expect(JSON.stringify(audit)).not.toContain("hi")
  })

  it("messages.send succeeds with messages:write", async () => {
    const infoSpy = vi.spyOn(console, "info").mockImplementation(() => {})

    const inline: InlineApi = {
      async close() {},
      async getEligibleChats() {
        return []
      },
      async search() {
        return []
      },
      async fetchMessage() {
        throw new Error("not needed")
      },
      async sendMessage() {
        return { messageId: 123n, spaceId: 10n }
      },
    }

    const server = createInlineMcpServer({ grant, inline })
    const { transport, sent } = createFakeTransport()
    await server.connect(transport as any)

    const authInfo: AuthInfo = { token: "t", clientId: "c1", scopes: ["messages:write"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } },
      } as any,
      { authInfo },
    )

    await sendRequest(transport, { jsonrpc: "2.0", method: "notifications/initialized", params: {} } as any, { authInfo })

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: { name: "messages.send", arguments: { chatId: "7", text: "hi", sendMode: "normal", parseMarkdown: true } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.ok).toBe(true)
    expect(payload.messageId).toBe("123")

    const audit = lastMessagesSendAuditRecord(infoSpy)
    expect(audit.outcome).toBe("success")
    expect(audit.grantId).toBe("g1")
    expect(audit.inlineUserId).toBe("1")
    expect(audit.chatId).toBe("7")
    expect(audit.spaceId).toBe("10")
    expect(audit.messageId).toBe("123")
    expect(typeof audit.timestamp).toBe("string")
    expect(audit).not.toHaveProperty("text")
    expect(audit).not.toHaveProperty("token")
    expect(JSON.stringify(audit)).not.toContain("hi")
  })
})
