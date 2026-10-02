import { afterEach, describe, expect, it, vi } from "vitest"
import { Buffer } from "node:buffer"
import { Message, Method } from "@inline-chat/protocol/core"
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js"
import type { JSONRPCMessage } from "@modelcontextprotocol/sdk/types.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import { createInlineMcpServer } from "./server"
import { CONVERSATION_SNAPSHOT_MAX_BYTES, serializeRecentConversationSnapshot } from "./conversation-mentions"
import type { RecentConversationSnapshot } from "./conversation-mentions"
import type { McpGrant } from "./grant"
import { createInlineApi, type InlineApi, type InlineEligibleChat, type InlineRecentMessagesResult } from "../inline/inline-api"

const sdk = vi.hoisted(() => ({
  client: {
    connect: vi.fn(async () => {}), close: vi.fn(async () => {}), invoke: vi.fn(),
    events: vi.fn(() => ({ async *[Symbol.asyncIterator]() {} })),
  },
}))
vi.mock("@inline-chat/realtime-sdk", () => ({
  InlineSdkClient: vi.fn(function InlineSdkClient() { return sdk.client }),
}))

const grant: McpGrant = {
  id: "g1", clientId: "c1", inlineUserId: 1n, scope: "messages:read", spaceIds: [10n], allowDms: true, allowHomeThreads: true,
}
const auth: AuthInfo = { token: "test-token", clientId: "c1", scopes: ["messages:read"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

function chat(overrides: Partial<InlineEligibleChat> = {}): InlineEligibleChat {
  return {
    chatId: 7n, title: "Launch", chatTitle: "Launch", kind: "space_chat", spaceId: 10n, spaceName: "Inline",
    peerUserId: null, peerDisplayName: null, peerUsername: null, archived: false, pinned: false, unreadCount: 0,
    readMaxId: null, lastMessageId: null, lastMessageDate: null, ...overrides,
  }
}

function row(id: bigint, text = `message ${id}`): Message {
  return Message.create({ id, chatId: 7n, fromId: 2n, date: id, message: text })
}

function page(messages: Message[] = [], overrides: Partial<InlineRecentMessagesResult> = {}): InlineRecentMessagesResult {
  return { chat: chat(), direction: "all", scannedCount: messages.length, nextOffsetId: null, messages, ...overrides }
}

function inlineStub(overrides: Partial<InlineApi> = {}): InlineApi {
  return {
    close: vi.fn(async () => {}), getEligibleChats: vi.fn(async () => []),
    resolveConversation: vi.fn(async () => ({ query: "", selected: null, candidates: [] })),
    recentMessages: vi.fn(async () => page()), ...overrides,
  } as unknown as InlineApi
}

const servers: ReturnType<typeof createInlineMcpServer>[] = []
afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => server.close()))
  vi.clearAllMocks()
})

async function harness(inline = inlineStub(), selectedGrant = grant) {
  const server = createInlineMcpServer({ grant: selectedGrant, inline })
  servers.push(server)
  const pending = new Map<number, (message: any) => void>()
  const transport: Transport = {
    async start() {}, async close() {},
    async send(message) {
      if ("id" in message && typeof message.id === "number") pending.get(message.id)?.(message)
    },
  }
  await server.connect(transport)
  let id = 0
  const request = async (method: string, params: Record<string, unknown>, requestAuth: AuthInfo | null = auth) => {
    const requestId = ++id
    const response = new Promise<any>((resolve) => { pending.set(requestId, resolve) })
    transport.onmessage?.({ jsonrpc: "2.0", id: requestId, method, params } as JSONRPCMessage, { authInfo: requestAuth ?? undefined })
    return response
  }
  await request("initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "mentions-test", version: "1" } })
  transport.onmessage?.({ jsonrpc: "2.0", method: "notifications/initialized" }, { authInfo: auth })
  return { request, inline, server }
}

describe("conversation composer mentions", () => {
  it("advertises the upstream mention descriptor, required empty-capable query, and the resource template", async () => {
    const { request } = await harness()
    const tools = await request("tools/list", {})
    const mention = tools.result.tools.find((tool: any) => tool.name === "conversations.mentions")
    expect(mention._meta).toMatchObject({
      ui: { visibility: ["app"] }, "openai/extensions": { "mentions/search": {} }, securitySchemes: [{ type: "oauth2", scopes: ["messages:read"] }],
    })
    expect(mention.annotations).toMatchObject({ readOnlyHint: true, destructiveHint: false, openWorldHint: false })
    expect(mention.inputSchema.required).toEqual(["query"])
    const templates = await request("resources/templates/list", {})
    expect(templates.result.resourceTemplates).toContainEqual(expect.objectContaining({ uriTemplate: "inline://chat/{chatId}", mimeType: "application/json" }))
  })

  it("returns at most 20 metadata-only recent links and makes equal titles distinguishable", async () => {
    const chats = Array.from({ length: 25 }, (_, index) => chat({ chatId: BigInt(index + 1) }))
    chats[0] = chat({ chatId: 1n, kind: "dm", spaceId: null, spaceName: null })
    chats[1] = chat({ chatId: 2n, kind: "home_thread", spaceId: null, spaceName: null })
    chats.unshift(chat({ chatId: 30n, spaceId: 99n }))
    const inline = inlineStub({ getEligibleChats: vi.fn(async () => chats) })
    const { request } = await harness(inline)
    const response = await request("tools/call", { name: "conversations.mentions", arguments: { query: "  " } })
    expect(response.result.content).toEqual([])
    const items = response.result.structuredContent.items
    expect(items).toHaveLength(20)
    expect(items[0]).toMatchObject({ type: "resource_link", uri: "inline://chat/1", name: "Launch · Direct message · chat 1", mimeType: "application/json" })
    expect(items[1].name).toBe("Launch · Home thread · chat 2")
    expect(items[2].name).toBe("Launch · Inline (space 10) · chat 3")
    expect(inline.recentMessages).not.toHaveBeenCalled()
    expect(inline.resolveConversation).not.toHaveBeenCalled()
  })

  it("reuses the ranked resolver without fetching candidate history", async () => {
    const candidate = { ...chat(), score: 100, matchReasons: ["title_exact"] }
    const inline = inlineStub({ resolveConversation: vi.fn(async () => ({ query: "Launch", selected: candidate, candidates: [candidate] })) })
    const { request } = await harness(inline)
    const response = await request("tools/call", { name: "conversations.mentions", arguments: { query: " Launch " } })
    expect(inline.resolveConversation).toHaveBeenCalledWith("Launch", 20)
    expect(response.result.structuredContent.items[0].uri).toBe("inline://chat/7")
    expect(inline.getEligibleChats).not.toHaveBeenCalled()
    expect(inline.recentMessages).not.toHaveBeenCalled()
  })

  it("reads a direct URI independently of picker selection and returns only text/IDs/media kinds", async () => {
    const mediaMessage = row(9n, "file caption")
    mediaMessage.media = { media: { oneofKind: "document", document: { document: { id: 100n, cdnUrl: "https://private.test/file", fileName: "private-name", mimeType: "text/plain", size: 12, date: 1n } } } }
    mediaMessage.replyToMsgId = 3n
    const inline = inlineStub({ recentMessages: vi.fn(async () => page([mediaMessage, row(8n)])) })
    const { request } = await harness(inline)
    const response = await request("resources/read", { uri: "inline://chat/7" })
    expect(inline.recentMessages).toHaveBeenCalledWith({ chatId: 7n, limit: 20, freshChatAuthorization: true })
    expect(inline.getEligibleChats).not.toHaveBeenCalled()
    const content = response.result.contents[0]
    expect(content.mimeType).toBe("application/json")
    const snapshot = JSON.parse(content.text)
    expect(snapshot.messages.map((message: RecentConversationSnapshot["messages"][number]) => message.id)).toEqual(["8", "9"])
    expect(snapshot.messages[1]).toMatchObject({ id: "9", fromId: "2", date: "9", replyToMsgId: "3", mediaKind: "document", text: "file caption", shortened: false })
    expect(content.text).not.toContain("private.test")
    expect(content.text).not.toContain("private-name")
    expect(snapshot.coverage).toContain("not complete history")
    expect(new Date(snapshot.capturedAt).toISOString()).toBe(snapshot.capturedAt)
  })

  it("returns a valid empty snapshot, preserving any supplied older cursor", async () => {
    const { request } = await harness(inlineStub({ recentMessages: vi.fn(async () => page([], { nextOffsetId: 30n })) }))
    const response = await request("resources/read", { uri: "inline://chat/7" })
    expect(JSON.parse(response.result.contents[0].text)).toMatchObject({ messages: [], truncated: false, nextOffsetId: "30" })
  })

  it.each(["missing", "scope", "expired", "client", "grant", "user"])("rejects %s authorization on a direct read before touching history", async (kind) => {
    const { request, inline } = await harness()
    const requestAuth = kind === "missing" ? null : {
      ...auth,
      ...(kind === "scope" ? { scopes: [] } : {}),
      ...(kind === "expired" ? { expiresAt: 1 } : {}),
      ...(kind === "client" ? { clientId: "other" } : {}),
      ...(kind === "grant" ? { extra: { grantId: "other" } } : {}),
      ...(kind === "user" ? { extra: { inlineUserId: "2" } } : {}),
    }
    const response = await request("resources/read", { uri: "inline://chat/7" }, requestAuth)
    expect(response.error.message).toMatch(/authorization|scope/i)
    expect(response.error.data["mcp/www_authenticate"][0]).toContain(kind === "scope" ? "insufficient_scope" : "invalid_token")
    expect(inline.recentMessages).not.toHaveBeenCalled()
  })

  it("does not grant a request more read scope than the original session", async () => {
    const { request, inline } = await harness(inlineStub(), { ...grant, scope: "messages:write" })
    const response = await request("resources/read", { uri: "inline://chat/7" })
    expect(response.error.message).toContain("scope")
    expect(inline.recentMessages).not.toHaveBeenCalled()
  })

  it("returns the scope authorization challenge on mention search too", async () => {
    const { request, inline } = await harness()
    const response = await request("tools/call", { name: "conversations.mentions", arguments: { query: "" } }, { ...auth, scopes: [] })
    expect(response.result).toMatchObject({ isError: true, _meta: { "mcp/www_authenticate": [expect.stringContaining("insufficient_scope")] } })
    expect(inline.getEligibleChats).not.toHaveBeenCalled()
  })

  it.each(["space", "dm", "home"])("intersects current %s context with the original grant for discovery and reads", async (kind) => {
    const selectedChat = chat(kind === "dm" ? { kind: "dm", spaceId: null } : kind === "home" ? { kind: "home_thread", spaceId: null } : {})
    const requestAuth = { ...auth, extra: kind === "space" ? { spaceIds: [] } : kind === "dm" ? { allowDms: false } : { allowHomeThreads: false } }
    const { request } = await harness(inlineStub({ getEligibleChats: vi.fn(async () => [selectedChat]), recentMessages: vi.fn(async () => page([row(1n)], { chat: selectedChat })) }))
    const search = await request("tools/call", { name: "conversations.mentions", arguments: { query: "" } }, requestAuth)
    expect(search.result.structuredContent.items).toEqual([])
    const read = await request("resources/read", { uri: "inline://chat/7" }, requestAuth)
    expect(read.error.message).toContain("allowed context")
    expect(read.result).toBeUndefined()
  })

  it.each(["inline://chat/0", "inline://chat/-1", "inline://chat/01", "inline://chat/1?x=2", "inline://chat/9223372036854775808"])("rejects invalid URI %s", async (uri) => {
    const { request, inline } = await harness()
    const response = await request("resources/read", { uri })
    expect(response.error).toBeDefined()
    expect(inline.recentMessages).not.toHaveBeenCalled()
  })

  it("propagates a backend access failure instead of returning cached picker context", async () => {
    let revoked = false
    sdk.client.invoke.mockImplementation(async (method: Method) => {
      if (method === Method.GET_CHATS) return { getChats: { dialogs: [], folders: [], chats: [{ id: 7n, title: "Launch", spaceId: 10n, date: 1n }], spaces: [{ id: 10n, name: "Inline", creator: false, date: 1n }], users: [], messages: [] } }
      if (method === Method.GET_CHAT) return { getChat: { chat: { id: 7n, title: "Launch", spaceId: 10n, date: 1n } } }
      if (method === Method.GET_CHAT_HISTORY) {
        if (revoked) throw new Error("CHAT_ACCESS_DENIED")
        return { getChatHistory: { messages: [row(20n, "authorized message")] } }
      }
      throw new Error(`Unexpected method ${method}`)
    })
    const api = createInlineApi({ baseUrl: "https://inline.test", token: "test-token", allowed: { allowedSpaceIds: [10n], allowDms: false, allowHomeThreads: false } })
    try {
      const { request } = await harness(api)
      const search = await request("tools/call", { name: "conversations.mentions", arguments: { query: "" } })
      expect(search.result.structuredContent.items).toHaveLength(1)
      const read = await request("resources/read", { uri: "inline://chat/7" })
      expect(read.result.contents[0].text).toContain("authorized message")
      revoked = true
      const denied = await request("resources/read", { uri: "inline://chat/7" })
      expect(denied.error.message).toContain("CHAT_ACCESS_DENIED")
      expect(denied.result).toBeUndefined()
      expect(sdk.client.invoke.mock.calls.filter(([method]) => method === Method.GET_CHATS)).toHaveLength(1)
      expect(sdk.client.invoke.mock.calls.filter(([method]) => method === Method.GET_CHAT)).toHaveLength(2)
      expect(sdk.client.invoke.mock.calls.filter(([method]) => method === Method.GET_CHAT_HISTORY)).toHaveLength(2)
    } finally {
      await api.close()
    }
  })

  it("rechecks a cached chat's current space before reading any message bodies", async () => {
    let moved = false
    sdk.client.invoke.mockImplementation(async (method: Method) => {
      if (method === Method.GET_CHATS) return { getChats: { dialogs: [], folders: [], chats: [{ id: 7n, title: "Launch", spaceId: 10n, date: 1n }], spaces: [], users: [], messages: [] } }
      if (method === Method.GET_CHAT) return { getChat: { chat: { id: 7n, title: "Launch", spaceId: moved ? 20n : 10n, date: 1n } } }
      if (method === Method.GET_CHAT_HISTORY) return { getChatHistory: { messages: [row(20n, "authorized message")] } }
      throw new Error(`Unexpected method ${method}`)
    })
    const api = createInlineApi({ baseUrl: "https://inline.test", token: "test-token", allowed: { allowedSpaceIds: [10n], allowDms: false, allowHomeThreads: false } })
    try {
      const { request } = await harness(api)
      await request("tools/call", { name: "conversations.mentions", arguments: { query: "" } })
      moved = true
      const denied = await request("resources/read", { uri: "inline://chat/7" })
      expect(denied.error.message).toContain("not in an allowed context")
      expect(denied.result).toBeUndefined()
      expect(sdk.client.invoke.mock.calls.filter(([method]) => method === Method.GET_CHAT_HISTORY)).toHaveLength(0)
    } finally {
      await api.close()
    }
  })
})

describe("bounded conversation snapshots", () => {
  it("retains the latest 20 in chronological order and resumes at the oldest retained row", () => {
    const messages = Array.from({ length: 30 }, (_, index) => row(BigInt(index + 1)))
    const snapshot = JSON.parse(serializeRecentConversationSnapshot(page(messages, { nextOffsetId: 1n })))
    expect(snapshot.messages.map((message: RecentConversationSnapshot["messages"][number]) => message.id)).toEqual(Array.from({ length: 20 }, (_, index) => String(index + 11)))
    expect(snapshot).toMatchObject({ truncated: true, nextOffsetId: "11" })
  })

  it("preserves the adapter cursor when no rows were omitted", () => {
    const snapshot = JSON.parse(serializeRecentConversationSnapshot(page([row(10n), row(9n)], { nextOffsetId: 9n })))
    expect(snapshot).toMatchObject({ truncated: false, nextOffsetId: "9" })
  })

  it.each(["😀é漢字".repeat(20_000), "\u0000\"\\\n".repeat(20_000)])("caps escaped UTF-8 JSON, bounds metadata, and marks shortened bodies", (text) => {
    const encoded = serializeRecentConversationSnapshot(page([row(20n, text)], { chat: chat({ title: "😀".repeat(30_000), spaceName: "\u0000".repeat(30_000) }) }))
    expect(Buffer.byteLength(encoded, "utf8")).toBeLessThanOrEqual(CONVERSATION_SNAPSHOT_MAX_BYTES)
    const snapshot: RecentConversationSnapshot = JSON.parse(encoded)
    expect(snapshot.truncated).toBe(true)
    expect(snapshot.messages[0].shortened).toBe(true)
    expect(text.startsWith(snapshot.messages[0].text)).toBe(true)
    expect(snapshot.messages[0].text).not.toMatch(/[\uD800-\uDBFF]$/)
    expect(Buffer.byteLength(JSON.stringify(snapshot.chat.title), "utf8")).toBeLessThanOrEqual(1024)
  })

  it("does not skip the unreturned rows of an oversized fetched page", () => {
    const messages = Array.from({ length: 20 }, (_, index) => row(BigInt(100 - index), "x".repeat(3000)))
    const encoded = serializeRecentConversationSnapshot(page(messages, { nextOffsetId: 80n }))
    const snapshot: RecentConversationSnapshot = JSON.parse(encoded)
    expect(Buffer.byteLength(encoded, "utf8")).toBeLessThanOrEqual(CONVERSATION_SNAPSHOT_MAX_BYTES)
    expect(snapshot.messages.length).toBeGreaterThan(0)
    expect(snapshot.messages.length).toBeLessThan(20)
    expect(snapshot.messages.at(-1)?.id).toBe("100")
    expect(snapshot.nextOffsetId).toBe(snapshot.messages[0].id)
    expect(snapshot.truncated).toBe(true)
    const older = messages.filter((message) => message.id < BigInt(snapshot.nextOffsetId!))
    expect([...snapshot.messages.map((message) => message.id), ...older.map((message) => message.id.toString())].sort()).toEqual(messages.map((message) => message.id.toString()).sort())
  })
})
