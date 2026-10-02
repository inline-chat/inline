import { afterEach, describe, expect, it, vi } from "vitest"
import { readFileSync } from "node:fs"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import type { JSONRPCMessage } from "@modelcontextprotocol/sdk/types.js"
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js"
import { createInlineMcpServer, isUnsafeRemoteAddress } from "./server"
import type { EventsProxy } from "./events-proxy"
import type { McpGrant } from "./grant"
import { InlineAccessDeniedError } from "../inline/inline-api"
import { InlineSdkAuthenticationError, ProtocolClientError } from "@inline-chat/realtime-sdk"
import { ConnectionError_Reason, RpcError_Code } from "@inline-chat/protocol/core"
import type {
  InlineApi,
  InlineConversationResolution,
  InlineEligibleChat,
  InlineRecentMessagesResult,
  InlineSearchMessagesResult,
  InlineUnreadMessagesResult,
  InlineUploadFileResult,
} from "../inline/inline-api"

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

function createAuthInfo(scopes: string[]): AuthInfo {
  return { token: "t", clientId: "c1", scopes, expiresAt: Math.floor(Date.now() / 1000) + 3600 }
}

async function connectAndInitialize(server: ReturnType<typeof createInlineMcpServer>, authInfo: AuthInfo) {
  const { transport, sent } = createFakeTransport()
  await server.connect(transport as any)
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
  const initialize = await waitForResponse(sent, 1)
  await sendRequest(transport, { jsonrpc: "2.0", method: "notifications/initialized", params: {} } as any, { authInfo })
  return { transport, sent, initialize }
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

const grant: McpGrant = {
  id: "g1",
  clientId: "c1",
  inlineUserId: 1n,
  scope: "messages:read spaces:read messages:write",
  spaceIds: [10n],
  allowDms: false,
  allowHomeThreads: false,
}

describe("minimal thread workflows", () => {
  const auth = createAuthInfo(["messages:read", "messages:write"])
  const askArgs = { title: "Review", question: "What do you think?", participantUserIds: ["2"], spaceId: "10" }

  async function call(server: ReturnType<typeof createInlineMcpServer>, name: string, args: Record<string, unknown>, authInfo = auth) {
    const connection = await connectAndInitialize(server, authInfo)
    await sendRequest(connection.transport, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name, arguments: args } }, { authInfo })
    return { response: await waitForResponse(connection.sent, 2), connection }
  }

  it("keeps the legacy tool inventory free of new entrypoints", async () => {
    const server = createInlineMcpServer({ grant, inline: createInlineStub({}) })
    const { transport, sent } = await connectAndInitialize(server, auth)
    await sendRequest(transport, { jsonrpc: "2.0", id: 2, method: "tools/list" }, { authInfo: auth })
    const response = await waitForResponse(sent, 2)
    expect(response.result.tools.map((tool: { name: string }) => tool.name)).not.toContain("conversations.open")
    expect(response.result.tools.map((tool: { name: string }) => tool.name)).not.toContain("conversations.ask")
    await server.close()
  })

  it("opens an empty picker without fetching a workspace catalog", async () => {
    const getEligibleChats = vi.fn(async () => [])
    const getConversation = vi.fn()
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ getEligibleChats, getConversation }), contractVersion: "submission-v2" })
    const { response } = await call(server, "conversations.open", {})
    expect(response.result.structuredContent).toMatchObject({ chat: null, messages: [], participants: [], capabilities: { canSend: true } })
    expect(getEligibleChats).not.toHaveBeenCalled()
    expect(getConversation).not.toHaveBeenCalled()
    await server.close()
  })

  it("checks current auth and exposes only acknowledged, unexpired monitoring", async () => {
    const request = vi.fn<EventsProxy["request"]>(async () => ({ subscriptions: [
      { id: "expired", name: "message.created", refreshBefore: "2000-01-01T00:00:00Z" },
      { id: "other", name: "chat.updated", refreshBefore: "2099-01-01T00:00:00Z" },
      { id: "live", name: "message.created", refreshBefore: "2099-01-01T00:00:00Z" },
    ] }))
    const seenTokens: string[] = []
    const readAuth = { ...auth, token: "refreshed-token", scopes: ["messages:read"] }
    const server = createInlineMcpServer({ grant, inline: createInlineStub({}), contractVersion: "submission-v2", events: (currentAuth) => {
      seenTokens.push(currentAuth.token)
      return { request }
    } })
    const { response } = await call(server, "conversations.open", { chatId: "7" }, readAuth)
    expect(response.result.structuredContent).toMatchObject({ chat: { chatId: "7" }, capabilities: { canSend: false }, monitoring: { active: true, expiresAt: "2099-01-01T00:00:00Z" } })
    expect(request).toHaveBeenCalledWith("events/status", { chatId: "7" })
    expect(seenTokens).toEqual(["refreshed-token"])
    await server.close()
  })

  it("reads thread history when monitoring status is temporarily unavailable", async () => {
    const server = createInlineMcpServer({ grant, inline: createInlineStub({}), contractVersion: "submission-v2", events: () => ({ request: async () => { throw new Error("temporarily unavailable") } }) })
    const { response } = await call(server, "conversations.open", { chatId: "7" })
    expect(response.result.isError).not.toBe(true)
    expect(response.result.structuredContent.chat.chatId).toBe("7")
    expect(response.result.structuredContent).not.toHaveProperty("monitoring")
    await server.close()
  })

  it.each([
    new InlineAccessDeniedError("chat is not in an allowed context"),
    new InlineSdkAuthenticationError("SESSION_REVOKED", ConnectionError_Reason.SESSION_REVOKED),
    new ProtocolClientError("rpc-error", { code: RpcError_Code.CHAT_ID_INVALID }),
    new ProtocolClientError("rpc-error", { code: RpcError_Code.UNAUTHENTICATED }),
  ])("marks explicit read denial for the UI without exposing cached content (%s)", async (error) => {
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ getConversation: async () => { throw error } }), contractVersion: "submission-v2" })
    const { response } = await call(server, "conversations.open", { chatId: "7" })
    expect(response.result).toMatchObject({ isError: true, _meta: { inline: { accessDenied: true } } })
    expect(response.result.structuredContent).toBeUndefined()
    await server.close()
  })

  it.each([new ProtocolClientError("timeout"), new ProtocolClientError("rpc-error", { code: RpcError_Code.INTERNAL_ERROR })])(
    "does not label temporary read failure as authorization denial (%s)", async (error) => {
      const server = createInlineMcpServer({ grant, inline: createInlineStub({ getConversation: async () => { throw error } }), contractVersion: "submission-v2" })
      const { response } = await call(server, "conversations.open", { chatId: "7" })
      expect(response.result.isError).toBe(true)
      expect(response.result._meta?.inline?.accessDenied).not.toBe(true)
      await server.close()
    },
  )

  it("captures the reply cursor before sending and keeps the connected user implicit", async () => {
    const order: string[] = []
    const createChat = vi.fn(async () => { order.push("create"); return defaultEligibleChat() })
    const sendMessage = vi.fn(async () => { order.push("send"); return { messageId: 123n } })
    const request = vi.fn<EventsProxy["request"]>(async (method, params) => {
      order.push(method)
      if (method === "events/cursor") {
        expect(params).toEqual({ name: "message.created", arguments: { chatId: "7", excludeSelf: true } })
        return { cursor: "before-question" }
      }
      return { events: [{ name: "message.created" }] }
    })
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ createChat, sendMessage }), contractVersion: "submission-v2", events: () => ({ request }) })
    const { response } = await call(server, "conversations.ask", { ...askArgs, participantUserIds: ["1", "2", "2"] })
    expect(order).toEqual(["events/list", "create", "events/cursor", "send"])
    expect(createChat).toHaveBeenCalledWith({ title: "Review", isPublic: false, participantUserIds: [2n], spaceId: 10n })
    expect(sendMessage).toHaveBeenCalledWith({ chatId: 7n, text: "What do you think?", sendMode: "normal", parseMarkdown: true })
    expect(response.result.structuredContent).toMatchObject({ questionStatus: "sent", messageId: "123", event: { name: "message.created", arguments: { chatId: "7", excludeSelf: true }, cursor: "before-question" } })
    expect(response.result.structuredContent).not.toHaveProperty("monitoring")
    await server.close()
  })

  it("fails before creating or sending if the Events service is unavailable", async () => {
    const createChat = vi.fn()
    const sendMessage = vi.fn()
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ createChat, sendMessage }), contractVersion: "submission-v2", events: () => ({ request: async () => { throw new Error("Events unavailable") } }) })
    const { response } = await call(server, "conversations.ask", askArgs)
    expect(response.result.isError).toBe(true)
    expect(createChat).not.toHaveBeenCalled()
    expect(sendMessage).not.toHaveBeenCalled()
    await server.close()
  })

  it("retains the created chat when cursor capture fails, without sending the question", async () => {
    const createChat = vi.fn(async () => defaultEligibleChat())
    const sendMessage = vi.fn()
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ createChat, sendMessage }), contractVersion: "submission-v2", events: () => ({ request: async (method) => {
      if (method === "events/cursor") throw new Error("unavailable")
      return { events: [] }
    } }) })
    const { response } = await call(server, "conversations.ask", askArgs)
    expect(response.result.isError).toBe(true)
    expect(response.result.structuredContent).toMatchObject({ chat: { chatId: "7" }, questionStatus: "not_sent", messageId: null, event: null })
    expect(response.result.structuredContent.nextStep).toContain("Do not create another thread")
    expect(createChat).toHaveBeenCalledTimes(1)
    expect(sendMessage).not.toHaveBeenCalled()
    await server.close()
  })

  it("returns a known thread and cursor for uncertain send outcomes without retrying", async () => {
    const createChat = vi.fn(async () => defaultEligibleChat())
    const sendMessage = vi.fn(async () => { throw new Error("delivery may have happened") })
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ createChat, sendMessage }), contractVersion: "submission-v2", events: () => ({ request: async (method) => method === "events/cursor" ? { cursor: "checkpoint" } : { events: [] } }) })
    const { response } = await call(server, "conversations.ask", askArgs)
    expect(response.result.isError).toBe(true)
    expect(response.result.structuredContent).toMatchObject({ chat: { chatId: "7" }, questionStatus: "unknown", event: { cursor: "checkpoint" } })
    expect(createChat).toHaveBeenCalledTimes(1)
    expect(sendMessage).toHaveBeenCalledTimes(1)
    await server.close()
  })

  it("requires both read and write scopes before any consultation action", async () => {
    const createChat = vi.fn()
    const request = vi.fn<EventsProxy["request"]>()
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ createChat }), contractVersion: "submission-v2", events: () => ({ request }) })
    const { response } = await call(server, "conversations.ask", askArgs, createAuthInfo(["messages:write"]))
    expect(response.result.isError).toBe(true)
    expect(response.result._meta["mcp/www_authenticate"][0]).toContain("messages:read")
    expect(request).not.toHaveBeenCalled()
    expect(createChat).not.toHaveBeenCalled()
    await server.close()
  })
})

function defaultEligibleChat(overrides: Partial<InlineEligibleChat> = {}): InlineEligibleChat {
  return {
    chatId: 7n,
    title: "General",
    chatTitle: "General",
    kind: "space_chat",
    spaceId: 10n,
    spaceName: "Inline",
    peerUserId: null,
    peerDisplayName: null,
    peerUsername: null,
    archived: false,
    pinned: false,
    unreadCount: 0,
    readMaxId: null,
    lastMessageId: null,
    lastMessageDate: null,
    ...overrides,
  }
}

function createInlineStub(overrides: Partial<InlineApi>): InlineApi {
  return {
    async close() {},
    async listSpaces() {
      return [
        {
          id: 10n,
          name: "Inline",
          creator: true,
          date: 100n,
          isPublic: false,
          chatCount: 1,
          unreadCount: 0,
          lastMessageDate: null,
        },
      ]
    },
    async searchPeople() {
      return {
        query: null,
        bestMatch: null,
        items: [],
      }
    },
    async getEligibleChats() {
      return []
    },
    async resolveConversation(): Promise<InlineConversationResolution> {
      return { query: "", selected: null, candidates: [] }
    },
    async getConversation() {
      return {
        chat: defaultEligibleChat(),
        description: null,
        emoji: null,
        isPublic: false,
        date: 100n,
        createdBy: 1n,
        parentChatId: null,
        parentMessageId: null,
        number: null,
        pinnedMessageIds: [],
        groupParticipantCount: 0,
        participants: [],
      }
    },
    async messageContext() {
      return {
        chat: defaultEligibleChat(),
        anchorMessageId: null,
        before: 8,
        after: 8,
        includeAnchor: true,
        content: "all",
        messages: [],
      }
    },
    async getMessages() {
      return {
        chat: defaultEligibleChat(),
        messages: [],
      }
    },
    async recentMessages(): Promise<InlineRecentMessagesResult> {
      return {
        chat: defaultEligibleChat(),
        direction: "all",
        scannedCount: 0,
        nextOffsetId: null,
        messages: [],
      }
    },
    async searchMessages(): Promise<InlineSearchMessagesResult> {
      return {
        chat: {
          chatId: 7n,
          title: "General",
          chatTitle: "General",
          kind: "space_chat",
          spaceId: 10n,
          spaceName: "Inline",
          peerUserId: null,
          peerDisplayName: null,
          peerUsername: null,
          archived: false,
          pinned: false,
          unreadCount: 0,
          readMaxId: null,
          lastMessageId: null,
          lastMessageDate: null,
        },
        query: null,
        content: "all",
        mode: "scan",
        scannedCount: 0,
        nextOffsetId: null,
        messages: [],
      }
    },
    async unreadMessages(): Promise<InlineUnreadMessagesResult> {
      return {
        scannedChats: 0,
        items: [],
      }
    },
    async createChat() {
      return {
        chatId: 9n,
        title: "Created",
        chatTitle: "Created",
        kind: "space_chat",
        spaceId: 10n,
        spaceName: "Inline",
        peerUserId: null,
        peerDisplayName: null,
        peerUsername: null,
        archived: false,
        pinned: false,
        unreadCount: 0,
        readMaxId: null,
        lastMessageId: null,
        lastMessageDate: null,
      }
    },
    async uploadFile(): Promise<InlineUploadFileResult> {
      return {
        fileUniqueId: "file_1",
        media: { kind: "document", id: 99n },
      }
    },
    async createSubthread({ parentChatId, parentMessageId }) {
      return { chat: defaultEligibleChat({ chatId: 9n }), parentChatId, parentMessageId: parentMessageId ?? null, anchorMessageId: 100n }
    },
    async forwardMessages({ messageIds }) {
      return { sourceChat: defaultEligibleChat(), destinationChat: defaultEligibleChat({ chatId: 9n }), messages: messageIds.map((sourceMessageId, index) => ({ sourceMessageId, destinationMessageId: BigInt(100 + index) })) }
    },
    async sendMessage() {
      return { messageId: null, spaceId: null }
    },
    async sendMediaMessage() {
      return { messageId: null, spaceId: null }
    },
    ...overrides,
  }
}

describe("mcp tool server", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it.each([
    "0.0.0.0",
    "10.0.0.1",
    "100.64.0.1",
    "127.0.0.1",
    "169.254.1.1",
    "172.16.0.1",
    "192.0.2.1",
    "192.168.0.1",
    "198.18.0.1",
    "198.51.100.1",
    "203.0.113.1",
    "224.0.0.1",
    "::1",
    "::ffff:127.0.0.1",
    "fc00::1",
    "fe80::1",
    "2001:db8::1",
    "2002:0a00:0001::",
    "ff02::1",
  ])("classifies non-public remote address %s as unsafe", (address) => {
    expect(isUnsafeRemoteAddress(address)).toBe(true)
  })

  it.each(["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111", "2001:4860:4860::8888"])(
    "classifies public remote address %s as safe",
    (address) => {
      expect(isUnsafeRemoteAddress(address)).toBe(false)
    },
  )

  it("tools/list exposes instructions, output schemas, annotations, and auth metadata", async () => {
    const inline = createInlineStub({})
    const server = createInlineMcpServer({ grant, inline })
    const authInfo = createAuthInfo(["messages:read", "messages:write"])
    const { transport, sent, initialize } = await connectAndInitialize(server, authInfo)

    expect(initialize.result.serverInfo.title).toBe("Inline")
    expect(initialize.result.serverInfo.description).toContain("work chats")
    expect(initialize.result.instructions).toContain("Resolve people, spaces, or thread names")
    expect(initialize.result.instructions).toContain("Use account.me")

    await sendRequest(transport, { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} } as any, { authInfo })

    const res = await waitForResponse(sent, 2)
    const tools = res.result.tools as Array<any>
    expect(tools.map((tool) => tool.name)).toEqual([
      "conversations.mentions",
      "account.me",
      "spaces.list",
      "people.search",
      "conversations.list",
      "conversations.get",
      "conversations.create",
      "conversations.create_subthread",
      "messages.get",
      "messages.forward",
      "files.upload",
      "files.get",
      "messages.send_media",
      "messages.send_batch",
      "messages.list",
      "messages.context",
      "messages.search",
      "messages.unread",
      "messages.send",
    ])

    const expectedAnnotations: Record<
      string,
      { readOnlyHint: boolean; openWorldHint: boolean; destructiveHint: boolean }
    > = {
      "conversations.mentions": { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
      "account.me": { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
      "spaces.list": { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
      "people.search": { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
      "conversations.list": { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
      "conversations.get": { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
      "conversations.create": { readOnlyHint: false, openWorldHint: true, destructiveHint: false },
      "conversations.create_subthread": { readOnlyHint: false, openWorldHint: true, destructiveHint: false },
      "messages.get": { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
      "messages.forward": { readOnlyHint: false, openWorldHint: true, destructiveHint: true },
      "files.upload": { readOnlyHint: false, openWorldHint: true, destructiveHint: false },
      "files.get": { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
      "messages.send_media": { readOnlyHint: false, openWorldHint: true, destructiveHint: true },
      "messages.send_batch": { readOnlyHint: false, openWorldHint: true, destructiveHint: true },
      "messages.list": { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
      "messages.context": { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
      "messages.search": { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
      "messages.unread": { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
      "messages.send": { readOnlyHint: false, openWorldHint: true, destructiveHint: true },
    }

    for (const tool of tools) {
      expect(tool.outputSchema?.type).toBe("object")
      expect(tool._meta?.securitySchemes?.[0]?.type).toBe("oauth2")
      expect(tool.annotations).toMatchObject(expectedAnnotations[tool.name])
    }

    const accountMe = tools.find((tool) => tool.name === "account.me")
    expect(accountMe.inputSchema).toMatchObject({ type: "object", properties: {} })
    expect(accountMe._meta.securitySchemes[0].scopes).toEqual([])

    const send = tools.find((tool) => tool.name === "messages.send")
    expect(send.description).toContain("Provide exactly one of chatId or userId")
    expect(send.description).toContain("parsed as Inline Markdown")
    expect(send.inputSchema.properties.text.description).toContain("supported Inline Markdown")
    expect(send.annotations.readOnlyHint).toBe(false)
    expect(send.annotations.destructiveHint).toBe(true)
    expect(send.annotations.idempotentHint).toBe(false)
    expect(send._meta.securitySchemes[0].scopes).toEqual(["messages:write"])

    const sendBatch = tools.find((tool) => tool.name === "messages.send_batch")
    expect(sendBatch.description).toContain("parsed as Inline Markdown")
    expect(sendBatch.inputSchema.required).toEqual(["items"])
    expect(sendBatch.inputSchema.properties.items.items).toMatchObject({
      type: "object",
      required: ["type"],
    })
    expect(sendBatch.inputSchema.properties.items.items.oneOf).toBeUndefined()
    expect(sendBatch.inputSchema.properties.items.items.anyOf).toBeUndefined()

    const conversation = tools.find((tool) => tool.name === "conversations.get")
    expect(conversation.inputSchema.properties).toHaveProperty("userId")
    expect(conversation.description).toContain("not a complete audience list")
    expect(conversation.outputSchema.properties.details.properties.groupParticipantCount.description).toContain("not group-member or effective-audience count")
    expect(conversation.outputSchema.properties.participants.description).toContain("Direct user participants only")
    const subthread = tools.find((tool) => tool.name === "conversations.create_subthread")
    expect(subthread.description).toContain("An existing reply thread is returned without changing")
    expect(subthread.description).toContain("reuse does not repair older creator membership")
    expect(subthread.description).toContain("inherits root-chat access plus its own direct/group grants")
    expect(subthread.description).toContain("Participants added only to an intermediate child are not automatically inherited by descendants")
    expect(subthread.inputSchema.properties.parentMessageId.description).toContain("without changing metadata or participants")
    for (const field of ["title", "description", "emoji", "participantUserIds"]) {
      expect(subthread.inputSchema.properties[field].description).toContain("ignored on reuse")
    }
    const upload = tools.find((tool) => tool.name === "files.upload")
    expect(upload.inputSchema.properties).toHaveProperty("base64")
    expect(upload.inputSchema.properties).toHaveProperty("url")
    expect(upload.inputSchema.properties).not.toHaveProperty("sourceType")
    const files = tools.find((tool) => tool.name === "files.get")
    expect(files.inputSchema.properties).toHaveProperty("userId")
    expect(files.inputSchema.properties).toHaveProperty("messageId")

    const list = tools.find((tool) => tool.name === "messages.list")
    expect(list.annotations.readOnlyHint).toBe(true)
    expect(list.inputSchema.properties).toHaveProperty("userId")
    expect(list.outputSchema.properties.messages.type).toBe("array")
    expect(list.outputSchema.properties.messages.items.properties.uri.type).toBe("string")
    expect(list.inputSchema.properties.direction).toBeUndefined()
    expect(list.inputSchema.properties.unreadOnly).toBeUndefined()
    expect(list._meta.ui).toEqual({ resourceUri: "ui://inline/message-results-v1.html" })
    const search = tools.find((tool) => tool.name === "messages.search")
    expect(search._meta.ui).toEqual(list._meta.ui)
    expect(search._meta.securitySchemes[0].scopes).toEqual(["messages:read"])
    expect(send.inputSchema.properties.parseMarkdown).toBeUndefined()

    const spaces = tools.find((tool) => tool.name === "spaces.list")
    expect(spaces._meta.securitySchemes[0].scopes).toEqual(["spaces:read"])
    const context = tools.find((tool) => tool.name === "messages.context")
    expect(context.outputSchema.properties.messages.type).toBe("array")
  })

  it("submission-v2 exposes explicit unambiguous input schemas", async () => {
    const inline = createInlineStub({})
    const server = createInlineMcpServer({ grant, inline, contractVersion: "submission-v2" })
    const authInfo = createAuthInfo(["messages:read", "messages:write", "spaces:read"])
    const { transport, sent, initialize } = await connectAndInitialize(server, authInfo)

    expect(initialize.result.serverInfo.version).toBe("0.3.0")

    await sendRequest(transport, { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} } as any, { authInfo })
    const res = await waitForResponse(sent, 2)
    const tools = res.result.tools as Array<any>
    const byName = new Map(tools.map((tool) => [tool.name, tool]))

    const expectedRequired: Record<string, string[]> = {
      "account.me": [],
      "spaces.list": [],
      "people.search": [],
      "conversations.list": [],
      "conversations.get": ["chatId"],
      "conversations.create": ["title"],
      "conversations.create_subthread": ["parentChatId"],
      "messages.get": ["chatId", "messageIds"],
      "messages.forward": ["sourceChatId", "destinationChatId", "messageIds"],
      "files.upload": ["sourceType", "source"],
      "files.get": ["chatId", "messageIds"],
      "messages.send_media": ["chatId", "mediaKind", "mediaId"],
      "messages.send_batch": ["chatId", "items"],
      "messages.list": ["chatId"],
      "messages.context": ["chatId", "anchorMessageId"],
      "messages.search": ["chatId", "query"],
      "messages.unread": [],
      "messages.send": ["chatId", "text"],
    }

    const assertPlainSchema = (value: unknown): void => {
      if (Array.isArray(value)) {
        for (const item of value) assertPlainSchema(item)
        return
      }
      if (!value || typeof value !== "object") return
      const record = value as Record<string, unknown>
      expect(record.default).toBeUndefined()
      expect(record.oneOf).toBeUndefined()
      expect(record.anyOf).toBeUndefined()
      expect(record.allOf).toBeUndefined()
      for (const child of Object.values(record)) assertPlainSchema(child)
    }

    for (const [name, required] of Object.entries(expectedRequired)) {
      const tool = byName.get(name)
      expect(tool, `missing ${name}`).toBeTruthy()
      expect(tool.inputSchema.required ?? []).toEqual(required)
      assertPlainSchema(tool.inputSchema)
    }

    // These operations support public audiences or arbitrary URL sources, even
    // when a particular grant contains only private spaces.
    for (const name of ["conversations.create", "files.upload", "messages.send_media", "messages.send_batch", "messages.send"]) {
      expect(byName.get(name).annotations.openWorldHint, name).toBe(true)
    }
    expect(byName.get("conversations.create").inputSchema.properties.isPublic.description).toContain("public space")
    expect(byName.get("files.upload").inputSchema.properties.source.description).toContain("public HTTPS URL")

    expect(byName.get("conversations.get").inputSchema.properties.userId).toBeUndefined()
    expect(byName.get("files.upload").inputSchema.properties).not.toHaveProperty("base64")
    expect(byName.get("files.upload").inputSchema.properties).not.toHaveProperty("url")
    expect(byName.get("files.get").inputSchema.properties).not.toHaveProperty("messageId")
    expect(byName.get("files.get").inputSchema.properties).not.toHaveProperty("userId")
    expect(byName.get("messages.send").description).toContain("parsed as Inline Markdown")
    expect(byName.get("messages.send").inputSchema.properties.text.description).toContain(
      "supported Inline Markdown",
    )

    for (const name of [
      "messages.send_media",
      "messages.send_batch",
      "messages.list",
      "messages.context",
      "messages.search",
      "messages.send",
    ]) {
      expect(byName.get(name).inputSchema.properties.userId, `${name} still exposes userId`).toBeUndefined()
    }

    const batchItem = byName.get("messages.send_batch").inputSchema.properties.items.items
    expect(batchItem.required).toEqual(["type", "content"])
    expect(batchItem.properties.type.enum).toEqual(["text", "photo", "video", "document"])
    expect(Object.keys(batchItem.properties)).toEqual(["type", "content"])
    expect(batchItem.additionalProperties).toBe(false)
  })

  it("keeps the ChatGPT submission inventory and annotations aligned with current tools", async () => {
    const submission = JSON.parse(readFileSync(new URL("../../../chatgpt-app-submission.json", import.meta.url), "utf8"))
    const server = createInlineMcpServer({ grant, inline: createInlineStub({}), contractVersion: "submission-v2" })
    const authInfo = createAuthInfo(["messages:read", "messages:write", "spaces:read"])
    const { transport, sent } = await connectAndInitialize(server, authInfo)
    await sendRequest(transport, { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} } as any, { authInfo })
    const tools = (await waitForResponse(sent, 2)).result.tools
    expect(Object.keys(submission.tools).sort()).toEqual(tools.map((tool: any) => tool.name).sort())
    for (const tool of tools) expect(tool.annotations).toMatchObject(submission.tools[tool.name].annotations)
  })

  it("submission-v2 rejects legacy and incomplete argument shapes before handlers run", async () => {
    const inline = createInlineStub({
      async getConversation() {
        throw new Error("handler should not run")
      },
      async getMessages() {
        throw new Error("handler should not run")
      },
      async recentMessages() {
        throw new Error("handler should not run")
      },
      async searchMessages() {
        throw new Error("handler should not run")
      },
      async uploadFile() {
        throw new Error("handler should not run")
      },
      async sendMessage() {
        throw new Error("handler should not run")
      },
      async sendMediaMessage() {
        throw new Error("handler should not run")
      },
    })
    const server = createInlineMcpServer({ grant, inline, contractVersion: "submission-v2" })
    const authInfo = createAuthInfo(["messages:read", "messages:write", "spaces:read"])
    const { transport, sent } = await connectAndInitialize(server, authInfo)
    const invalidCalls = [
      { name: "conversations.get", arguments: { userId: "2" } },
      { name: "files.upload", arguments: { base64: "aGVsbG8=" } },
      { name: "files.get", arguments: { chatId: "7", messageId: "44" } },
      { name: "messages.send_media", arguments: { userId: "2", mediaKind: "photo", mediaId: "9" } },
      { name: "messages.send_batch", arguments: { chatId: "7", items: [{ type: "text", text: "hello" }] } },
      { name: "messages.send_batch", arguments: { chatId: "7", items: [{ type: "text", content: "hello", replyToMsgId: "1", sendMode: "silent" }] } },
      { name: "messages.list", arguments: { userId: "2" } },
      { name: "messages.context", arguments: { chatId: "7" } },
      { name: "messages.search", arguments: { chatId: "7" } },
      { name: "messages.send", arguments: { userId: "2", text: "hello" } },
    ]

    for (let index = 0; index < invalidCalls.length; index += 1) {
      const id = index + 2
      await sendRequest(
        transport,
        { jsonrpc: "2.0", id, method: "tools/call", params: invalidCalls[index] } as any,
        { authInfo },
      )
      const response = await waitForResponse(sent, id)
      expect(response.result?.isError, invalidCalls[index].name).toBe(true)
      const errorText = response.result?.content?.[0]?.text ?? ""
      expect(errorText, invalidCalls[index].name).toContain("Invalid arguments")
      expect(errorText, invalidCalls[index].name).not.toContain("handler should not run")
    }
  })

  it("submission-v2 executes the clean upload, file lookup, and batch contracts", async () => {
    const calls: string[] = []
    const inline = createInlineStub({
      async uploadFile({ type, file }) {
        calls.push("upload")
        expect(type).toBe("document")
        expect(file).toBeInstanceOf(Uint8Array)
        expect(new TextDecoder().decode(file as Uint8Array)).toBe("hello")
        return { fileUniqueId: "file_1", media: { kind: "document", id: 99n } }
      },
      async getMessages({ chatId, messageIds }) {
        calls.push("files")
        expect(chatId).toBe(7n)
        expect(messageIds).toEqual([44n, 45n])
        return { chat: defaultEligibleChat(), messages: [] }
      },
      async sendMessage({ chatId, text }) {
        calls.push("text")
        expect(chatId).toBe(7n)
        expect(text).toBe("hello")
        return { messageId: 46n, spaceId: 10n }
      },
      async sendMediaMessage({ chatId, media }) {
        calls.push("media")
        expect(chatId).toBe(7n)
        expect(media).toEqual({ kind: "document", id: 99n })
        return { messageId: 47n, spaceId: 10n }
      },
    })
    const server = createInlineMcpServer({ grant, inline, contractVersion: "submission-v2" })
    const authInfo = createAuthInfo(["messages:read", "messages:write"])
    const { transport, sent } = await connectAndInitialize(server, authInfo)

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: {
          name: "files.upload",
          arguments: { sourceType: "base64", source: "aGVsbG8=", kind: "document", fileName: "hello.txt" },
        },
      } as any,
      { authInfo },
    )
    expect((await waitForResponse(sent, 2)).result.structuredContent.upload.media).toEqual({ kind: "document", id: "99" })

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 3,
        method: "tools/call",
        params: { name: "files.get", arguments: { chatId: "7", messageIds: ["44", "45"] } },
      } as any,
      { authInfo },
    )
    expect((await waitForResponse(sent, 3)).result.structuredContent).toMatchObject({
      source: "messages",
      messageIds: ["44", "45"],
    })

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 4,
        method: "tools/call",
        params: {
          name: "messages.send_batch",
          arguments: {
            chatId: "7",
            items: [
              { type: "text", content: "hello" },
              { type: "document", content: "99" },
            ],
          },
        },
      } as any,
      { authInfo },
    )
    const batch = await waitForResponse(sent, 4)
    expect(batch.result.structuredContent.results).toMatchObject([
      { type: "text", status: "sent", messageId: "46" },
      { type: "document", status: "sent", messageId: "47", media: { kind: "document", id: "99" } },
    ])
    expect(calls).toEqual(["upload", "files", "text", "media"])
  })

  it("account.me returns scoped account and allowed context", async () => {
    const inline = createInlineStub({})
    const scopedGrant: McpGrant = {
      ...grant,
      inlineUserId: 42n,
      scope: "messages:read",
      spaceIds: [10n, 20n],
      allowDms: true,
      allowHomeThreads: true,
    }
    const server = createInlineMcpServer({ grant: scopedGrant, inline })
    const authInfo = createAuthInfo(["messages:read"])
    const { transport, sent } = await connectAndInitialize(server, authInfo)

    await sendRequest(transport, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "account.me", arguments: {} } } as any, {
      authInfo,
    })

    const res = await waitForResponse(sent, 2)
    expect(res.result.isError).toBeUndefined()
    expect(res.result.structuredContent).toEqual({
      user: { id: "42" },
      session: {
        clientId: "c1",
        scopes: ["messages:read"],
        expiresAt: authInfo.expiresAt,
      },
      allowed: {
        spaceIds: ["10", "20"],
        allowDms: true,
        allowHomeThreads: true,
      },
      hints: expect.arrayContaining([expect.stringContaining("conversations.list")]),
    })
  })

  it("supports discovery, context, and file lookup workflow", async () => {
    const calls: string[] = []
    const fileMessage = {
      id: 44n,
      fromId: 2n,
      chatId: 7n,
      message: "Spec attached",
      out: false,
      date: 1700000000n,
      media: {
        media: {
          oneofKind: "document",
          document: {
            document: {
              id: 900n,
              fileName: "spec.pdf",
              mimeType: "application/pdf",
              size: 4567,
              cdnUrl: "https://cdn.example/spec.pdf",
            },
          },
        },
      },
    } as any
    const inline = createInlineStub({
      async listSpaces({ query, limit }) {
        calls.push("spaces")
        expect(query).toBe("inline")
        expect(limit).toBe(5)
        return [
          {
            id: 10n,
            name: "Inline",
            creator: true,
            date: 100n,
            isPublic: false,
            chatCount: 3,
            unreadCount: 2,
            lastMessageDate: 1700000000n,
          },
        ]
      },
      async searchPeople({ query, limit }) {
        calls.push("people")
        expect(query).toBe("dena")
        expect(limit).toBe(5)
        const dena = {
          userId: 2n,
          displayName: "Dena",
          username: "dena",
          firstName: "Dena",
          lastName: null,
          dmChatId: 70n,
          spaceIds: [10n],
          spaceNames: ["Inline"],
          score: 850,
          matchReasons: ["username_exact", "dm_preference"],
        }
        return { query: "dena", bestMatch: dena, items: [dena] }
      },
      async getConversation({ chatId }) {
        calls.push("conversation")
        expect(chatId).toBe(7n)
        return {
          chat: defaultEligibleChat({ chatId: 7n, title: "Roadmap", chatTitle: "Roadmap", lastMessageId: 44n, lastMessageDate: 1700000000n }),
          description: "Shipping plan",
          emoji: "R",
          isPublic: true,
          date: 100n,
          createdBy: 1n,
          parentChatId: null,
          parentMessageId: null,
          number: 12,
          pinnedMessageIds: [40n],
          groupParticipantCount: 0,
          participants: [
            {
              userId: 2n,
              displayName: "Dena",
              username: "dena",
              firstName: "Dena",
              lastName: null,
              dmChatId: null,
              spaceIds: [10n],
              spaceNames: ["Inline"],
            },
          ],
        }
      },
      async messageContext({ chatId, anchorMessageId, before, after, includeAnchor, content }) {
        calls.push("context")
        expect(chatId).toBe(7n)
        expect(anchorMessageId).toBe(44n)
        expect(before).toBe(2)
        expect(after).toBe(1)
        expect(includeAnchor).toBe(true)
        expect(content).toBe("all")
        return {
          chat: defaultEligibleChat({ chatId: 7n, title: "Roadmap", chatTitle: "Roadmap" }),
          anchorMessageId: 44n,
          before: 2,
          after: 1,
          includeAnchor: true,
          content: "all",
          messages: [fileMessage],
        }
      },
      async getMessages({ chatId, messageIds }) {
        calls.push("files")
        expect(chatId).toBe(7n)
        expect(messageIds).toEqual([44n])
        return {
          chat: defaultEligibleChat({ chatId: 7n, title: "Roadmap", chatTitle: "Roadmap" }),
          messages: [fileMessage],
        }
      },
    })

    const server = createInlineMcpServer({ grant, inline })
    const authInfo = createAuthInfo(["messages:read", "messages:write", "spaces:read"])
    const { transport, sent } = await connectAndInitialize(server, authInfo)

    await sendRequest(transport, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "spaces.list", arguments: { query: "inline", limit: 5 } } } as any, {
      authInfo,
    })
    expect((await waitForResponse(sent, 2)).result.structuredContent.items[0]).toMatchObject({ id: "10", name: "Inline", chatCount: 3 })

    await sendRequest(transport, { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "people.search", arguments: { query: "dena", limit: 5 } } } as any, {
      authInfo,
    })
    expect((await waitForResponse(sent, 3)).result.structuredContent.bestMatch).toMatchObject({ userId: "2", uri: "inline://user/2", username: "dena", dmChatId: "70" })

    await sendRequest(transport, { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "conversations.get", arguments: { chatId: "7" } } } as any, {
      authInfo,
    })
    const conversation = await waitForResponse(sent, 4)
    expect(conversation.result.structuredContent.chat.uri).toBe("inline://chat/7")
    expect(conversation.result.structuredContent.details).toMatchObject({ description: "Shipping plan", number: 12, pinnedMessageIds: ["40"] })
    expect(conversation.result.structuredContent.participants[0]).toMatchObject({ userId: "2", uri: "inline://user/2" })

    await sendRequest(
      transport,
      { jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "messages.context", arguments: { chatId: "7", anchorMessageId: "44", before: 2, after: 1 } } } as any,
      { authInfo },
    )
    const context = await waitForResponse(sent, 5)
    expect(context.result.structuredContent.anchorMessageId).toBe("44")
    expect(context.result.structuredContent.messages[0].uri).toBe("inline://chat/7/message/44")
    expect(context.result.structuredContent.messages[0].media.fileName).toBe("spec.pdf")

    await sendRequest(transport, { jsonrpc: "2.0", id: 6, method: "tools/call", params: { name: "files.get", arguments: { chatId: "7", messageId: "44" } } } as any, {
      authInfo,
    })
    const files = await waitForResponse(sent, 6)
    expect(files.result.structuredContent.items[0].message.uri).toBe("inline://chat/7/message/44")
    expect(files.result.structuredContent.items[0].files[0]).toMatchObject({
      source: "message_media",
      messageId: "44",
      kind: "document",
      id: "900",
      fileName: "spec.pdf",
    })
    expect(calls).toEqual(["spaces", "people", "conversation", "context", "files"])
  })

  it("conversations.list returns ranked candidates and best match for query", async () => {
    const inline = createInlineStub({
      async resolveConversation(query) {
        expect(query).toBe("dena")
        return {
          query: "dena",
          selected: {
            chatId: 7n,
            title: "Dena",
            chatTitle: "Dena",
            kind: "dm",
            spaceId: null,
            spaceName: null,
            peerUserId: 2n,
            peerDisplayName: "Dena",
            peerUsername: "dena",
            archived: false,
            pinned: true,
            unreadCount: 1,
            readMaxId: 80n,
            lastMessageId: 88n,
            lastMessageDate: 1000n,
            score: 410,
            matchReasons: ["peer_name_exact", "dm_preference"],
          },
          candidates: [
            {
              chatId: 7n,
              title: "Dena",
              chatTitle: "Dena",
              kind: "dm",
              spaceId: null,
              spaceName: null,
              peerUserId: 2n,
              peerDisplayName: "Dena",
              peerUsername: "dena",
              archived: false,
              pinned: true,
              unreadCount: 1,
              readMaxId: 80n,
              lastMessageId: 88n,
              lastMessageDate: 1000n,
              score: 410,
              matchReasons: ["peer_name_exact", "dm_preference"],
            },
            {
              chatId: 12n,
              title: "Dena Design Notes",
              chatTitle: "Dena Design Notes",
              kind: "space_chat",
              spaceId: 10n,
              spaceName: "Inline",
              peerUserId: null,
              peerDisplayName: null,
              peerUsername: null,
              archived: false,
              pinned: false,
              unreadCount: 0,
              readMaxId: null,
              lastMessageId: 70n,
              lastMessageDate: 900n,
              score: 220,
              matchReasons: ["title_prefix"],
            },
          ],
        }
      },
    })

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
        params: { name: "conversations.list", arguments: { query: "dena", limit: 5 } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    expect(res.result.isError).toBeUndefined()
    const text = res.result.content?.[0]?.text
    expect(typeof text).toBe("string")
    const payload = JSON.parse(text)
    expect(payload.query).toBe("dena")
    expect(payload.sort).toBe("relevance")
    expect(payload.bestMatch.chatId).toBe("7")
    expect(payload.bestMatch.kind).toBe("dm")
    expect(payload.bestMatch.match.score).toBe(410)
    expect(payload.items).toHaveLength(2)
    expect(payload.items[0].rank).toBe(1)
    expect(payload.items[1].rank).toBe(2)
  })

  it("pages complete conversation discovery past 50 chats in stable ID order", async () => {
    const chats = Array.from({ length: 125 }, (_, index) => defaultEligibleChat({ chatId: BigInt(125 - index), title: `Example ${125 - index}`, lastMessageDate: BigInt(index + 1) }))
    const getEligibleChats = vi.fn<InlineApi["getEligibleChats"]>().mockResolvedValue(chats)
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ getEligibleChats }), contractVersion: "submission-v2" })
    const authInfo = createAuthInfo(["messages:read"])
    const { transport, sent } = await connectAndInitialize(server, authInfo)
    try {
      let afterChatId: string | undefined
      const all: string[] = []
      for (let page = 0; page < 3; page += 1) {
        const id = page + 2
        await sendRequest(transport, { jsonrpc: "2.0", id, method: "tools/call", params: { name: "conversations.list", arguments: { includeSubthreads: true, sort: "id", limit: 50, ...(afterChatId ? { afterChatId } : {}) } } } as any, { authInfo })
        const result = (await waitForResponse(sent, id)).result
        expect(result.isError).not.toBe(true)
        expect(result.structuredContent.sort).toBe("id")
        expect(result.structuredContent).toEqual(JSON.parse(result.content[0].text))
        all.push(...result.structuredContent.items.map((item: { chatId: string }) => item.chatId))
        afterChatId = result.structuredContent.nextAfterChatId ?? undefined
        expect(afterChatId).toBe(page === 0 ? "50" : page === 1 ? "100" : undefined)
      }
      expect(all).toEqual(Array.from({ length: 125 }, (_, index) => String(index + 1)))
      expect(getEligibleChats.mock.calls).toEqual([[{ includeSubthreads: true }], [{ includeSubthreads: true }], [{ includeSubthreads: true }]])
    } finally { await server.close() }
  })

  it("returns an empty authorized catalog and requires read scope", async () => {
    const getEligibleChats = vi.fn<InlineApi["getEligibleChats"]>().mockResolvedValue([])
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ getEligibleChats }), contractVersion: "submission-v2" })
    const authInfo = createAuthInfo(["messages:read"])
    const { transport, sent } = await connectAndInitialize(server, authInfo)
    try {
      await sendRequest(transport, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "conversations.list", arguments: { includeSubthreads: true } } } as any, { authInfo })
      expect((await waitForResponse(sent, 2)).result.structuredContent).toMatchObject({ sort: "id", nextAfterChatId: null, items: [] })
      await sendRequest(transport, { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "conversations.list", arguments: { includeSubthreads: true } } } as any, { authInfo: createAuthInfo(["offline_access"]) })
      const failure = (await waitForResponse(sent, 3)).result
      expect(failure.isError).toBe(true)
      expect(failure._meta["mcp/www_authenticate"][0]).toContain("messages:read")
      expect(getEligibleChats).toHaveBeenCalledTimes(1)
    } finally { await server.close() }
  })

  it.each([{ includeSubthreads: true, query: "example" }, { afterChatId: "7", sort: "recent" }, { includeSubthreads: true, sort: "unread" }])("rejects ambiguous archive discovery %j", async (args) => {
    const getEligibleChats = vi.fn<InlineApi["getEligibleChats"]>().mockResolvedValue([])
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ getEligibleChats }), contractVersion: "submission-v2" })
    const authInfo = createAuthInfo(["messages:read"])
    const { transport, sent } = await connectAndInitialize(server, authInfo)
    try {
      await sendRequest(transport, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "conversations.list", arguments: args } } as any, { authInfo })
      expect((await waitForResponse(sent, 2)).result.isError).toBe(true)
      expect(getEligibleChats).not.toHaveBeenCalled()
    } finally { await server.close() }
  })

  it("supports resolve, read, and reply workflow over MCP tools", async () => {
    const calls: string[] = []
    const inline = createInlineStub({
      async resolveConversation(query, limit) {
        calls.push("resolve")
        expect(query).toBe("roadmap")
        expect(limit).toBe(3)
        return {
          query: "roadmap",
          selected: {
            chatId: 7n,
            title: "Roadmap",
            chatTitle: "Roadmap",
            kind: "space_chat",
            spaceId: 10n,
            spaceName: "Inline",
            peerUserId: null,
            peerDisplayName: null,
            peerUsername: null,
            archived: false,
            pinned: false,
            unreadCount: 2,
            readMaxId: 40n,
            lastMessageId: 44n,
            lastMessageDate: 1700000000n,
            score: 350,
            matchReasons: ["title_prefix"],
          },
          candidates: [
            {
              chatId: 7n,
              title: "Roadmap",
              chatTitle: "Roadmap",
              kind: "space_chat",
              spaceId: 10n,
              spaceName: "Inline",
              peerUserId: null,
              peerDisplayName: null,
              peerUsername: null,
              archived: false,
              pinned: false,
              unreadCount: 2,
              readMaxId: 40n,
              lastMessageId: 44n,
              lastMessageDate: 1700000000n,
              score: 350,
              matchReasons: ["title_prefix"],
            },
          ],
        }
      },
      async recentMessages({ chatId, since, limit }) {
        calls.push("list")
        expect(chatId).toBe(7n)
        expect(typeof since).toBe("bigint")
        expect(limit).toBe(5)
        return {
          chat: {
            chatId: chatId ?? 7n,
            title: "Roadmap",
            chatTitle: "Roadmap",
            kind: "space_chat",
            spaceId: 10n,
            spaceName: "Inline",
            peerUserId: null,
            peerDisplayName: null,
            peerUsername: null,
            archived: false,
            pinned: false,
            unreadCount: 2,
            readMaxId: 40n,
            lastMessageId: 44n,
            lastMessageDate: 1700000000n,
          },
          direction: "all",
          scannedCount: 2,
          nextOffsetId: null,
          messages: [
            { id: 44n, fromId: 2n, chatId: chatId ?? 7n, message: "Can we ship this week?", out: false, date: 1700000000n } as any,
            { id: 43n, fromId: 1n, chatId: chatId ?? 7n, message: "Waiting on the API review", out: true, date: 1699999900n } as any,
          ],
        }
      },
      async sendMessage({ chatId, text, sendMode, parseMarkdown }) {
        calls.push("send")
        expect(chatId).toBe(7n)
        expect(text).toBe("I'll review the API today and post a status update.")
        expect(sendMode).toBe("normal")
        expect(parseMarkdown).toBe(true)
        return { messageId: 45n, spaceId: 10n }
      },
    })

    const server = createInlineMcpServer({ grant, inline })
    const authInfo = createAuthInfo(["messages:read", "messages:write"])
    const { transport, sent } = await connectAndInitialize(server, authInfo)

    await sendRequest(
      transport,
      { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "conversations.list", arguments: { query: "roadmap", limit: 3 } } } as any,
      { authInfo },
    )
    const resolved = await waitForResponse(sent, 2)
    expect(resolved.result.structuredContent.bestMatch.chatId).toBe("7")

    await sendRequest(
      transport,
      { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "messages.list", arguments: { chatId: "7", since: "yesterday", limit: 5 } } } as any,
      { authInfo },
    )
    const context = await waitForResponse(sent, 3)
    expect(context.result.structuredContent.messages).toHaveLength(2)
    expect(context.result.structuredContent.messages[0].text).toContain("ship")

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 4,
        method: "tools/call",
        params: { name: "messages.send", arguments: { chatId: "7", text: "I'll review the API today and post a status update." } },
      } as any,
      { authInfo },
    )
    const sentMessage = await waitForResponse(sent, 4)
    expect(sentMessage.result.structuredContent).toMatchObject({
      ok: true,
      chatId: "7",
      messageId: "45",
    })
    expect(calls).toEqual(["resolve", "list", "send"])
  })

  it("messages.list returns messages with useful context fields", async () => {
    const inline = createInlineStub({
      async recentMessages({ chatId, direction, limit, offsetId, since, until, unreadOnly, content }) {
        expect(chatId).toBe(7n)
        expect(direction).toBeUndefined()
        expect(limit).toBe(5)
        expect(offsetId).toBe(99n)
        expect(typeof since).toBe("bigint")
        expect(typeof until).toBe("bigint")
        expect((since ?? 0n) <= (until ?? 0n)).toBe(true)
        expect(unreadOnly).toBeUndefined()
        expect(content).toBe("links")
        const resolvedChatId = chatId ?? 7n
        return {
          chat: {
            chatId: resolvedChatId,
            title: "General",
            chatTitle: "General",
            kind: "space_chat",
            spaceId: 10n,
            spaceName: "Inline",
            peerUserId: null,
            peerDisplayName: null,
            peerUsername: null,
            archived: false,
            pinned: false,
            unreadCount: 0,
            readMaxId: 20n,
            lastMessageId: 9n,
            lastMessageDate: 5n,
          },
          direction: "all",
          scannedCount: 3,
          nextOffsetId: 8n,
          messages: [{ id: 9n, fromId: 2n, chatId: resolvedChatId, message: "hello from me", out: true, date: 5n } as any],
          senderDisplayNames: { "2": "Dena Example", "3": "Unrelated Person" },
          senderAvatarUrls: { "2": "https://api.inline.chat/file?id=avatar_two&exp=1999999999&sig=fixture" },
        }
      },
    })

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
        params: {
          name: "messages.list",
          arguments: { chatId: "7", limit: 5, offsetId: "99", since: "2024-12-31", until: "2024-12-31", content: "links" },
        },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.chat.chatId).toBe("7")
    expect(payload.nextOffsetId).toBe("8")
    expect(payload.content).toBe("links")
    expect(payload.messages).toHaveLength(1)
    expect(payload.messages[0].id).toBe("9")
    expect(payload.messages[0].text).toBe("hello from me")
    expect(payload.messages[0].senderDisplayName).toBe("Dena Example")
    expect(res.result.structuredContent.messages[0].senderDisplayName).toBe("Dena Example")
    expect(JSON.stringify(payload)).not.toContain("Unrelated Person")
    expect(res.result._meta.inline.senderAvatarUrls).toEqual({ "2": "https://api.inline.chat/file?id=avatar_two&exp=1999999999&sig=fixture" })
    expect(JSON.stringify([res.result.structuredContent, res.result.content])).not.toContain("sig=fixture")
    expect(payload.messages[0].chatId).toBe("7")
    expect(payload.messages[0].fromId).toBe("2")
    expect(payload.messages[0].urlPreviews).toEqual([])
    expect(payload.messages[0].externalTasks).toEqual([])
  })

  it("messages.search searches messages only in the selected chat", async () => {
    const inline = createInlineStub({
      async searchMessages({ chatId, query, limit, content }) {
        expect(chatId).toBe(7n)
        expect(query).toBe("invoice")
        expect(limit).toBe(3)
        expect(content).toBe("documents")
        const resolvedChatId = chatId ?? 7n
        return {
          chat: {
            chatId: resolvedChatId,
            title: "Dena",
            chatTitle: "Dena",
            kind: "dm",
            spaceId: null,
            spaceName: null,
            peerUserId: 2n,
            peerDisplayName: "Dena",
            peerUsername: "dena",
            archived: false,
            pinned: false,
            unreadCount: 0,
            readMaxId: null,
            lastMessageId: 15n,
            lastMessageDate: 1000n,
          },
          query: query ?? null,
          content: "documents",
          mode: "search",
          scannedCount: 1,
          nextOffsetId: null,
          messages: [{ id: 14n, fromId: 2n, chatId: resolvedChatId, message: "invoice is sent", out: false, date: 999n } as any],
          senderAvatarUrls: { "2": "https://api.inline.chat/file?id=avatar_two&exp=1999999999&sig=fixture" },
        }
      },
    })

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
        params: { name: "messages.search", arguments: { chatId: "7", query: "invoice", limit: 3, content: "documents" } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.query).toBe("invoice")
    expect(payload.content).toBe("documents")
    expect(payload.chat.chatId).toBe("7")
    expect(payload.messages).toHaveLength(1)
    expect(payload.messages[0].id).toBe("14")
    expect(payload.messages[0].text).toBe("invoice is sent")
    expect(res.result._meta.inline.senderAvatarUrls).toEqual({ "2": "https://api.inline.chat/file?id=avatar_two&exp=1999999999&sig=fixture" })
    expect(JSON.stringify([res.result.structuredContent, res.result.content])).not.toContain("sig=fixture")
  })

  it("messages.list includes media download metadata when present", async () => {
    const inline = createInlineStub({
      async recentMessages({ chatId }) {
        return {
          chat: {
            chatId: chatId ?? 7n,
            title: "Files",
            chatTitle: "Files",
            kind: "space_chat",
            spaceId: 10n,
            spaceName: "Inline",
            peerUserId: null,
            peerDisplayName: null,
            peerUsername: null,
            archived: false,
            pinned: false,
            unreadCount: 0,
            readMaxId: null,
            lastMessageId: 100n,
            lastMessageDate: 1000n,
          },
          direction: "all",
          scannedCount: 1,
          nextOffsetId: null,
          messages: [
            {
              id: 100n,
              fromId: 2n,
              chatId: chatId ?? 7n,
              message: "file",
              out: false,
              date: 1000n,
              media: {
                media: {
                  oneofKind: "document",
                  document: {
                    document: {
                      id: 44n,
                      fileName: "spec.pdf",
                      mimeType: "application/pdf",
                      size: 12345,
                      cdnUrl: "https://cdn.example/spec.pdf",
                      date: 1000n,
                    },
                  },
                },
              },
              attachments: {
                attachments: [
                  {
                    id: 501n,
                    attachment: {
                      oneofKind: "urlPreview",
                      urlPreview: {
                        id: 88n,
                        url: "https://example.com/spec",
                        displayUrl: "example.com/spec",
                        siteName: "Example",
                        title: "Spec",
                        description: "Spec preview",
                        provider: "example",
                        author: "Mo",
                        mediaType: 1,
                      },
                    },
                  },
                  {
                    id: 502n,
                    attachment: {
                      oneofKind: "externalTask",
                      externalTask: {
                        id: 99n,
                        taskId: "task_99",
                        application: "Linear",
                        title: "Review spec",
                        status: 3,
                        assignedUserId: 2n,
                        url: "https://linear.example/task_99",
                        number: "LIN-99",
                        date: 1000n,
                      },
                    },
                  },
                ],
              },
            } as any,
          ],
        }
      },
    })

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
        params: { name: "messages.list", arguments: { chatId: "7", limit: 1 } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.messages[0].media).toEqual({
      kind: "document",
      id: "44",
      url: "https://cdn.example/spec.pdf",
      fileName: "spec.pdf",
      mimeType: "application/pdf",
      sizeBytes: 12345,
    })
    expect(payload.messages[0].urlPreviews).toEqual([
      {
        attachmentId: "501",
        id: "88",
        url: "https://example.com/spec",
        displayUrl: "example.com/spec",
        siteName: "Example",
        title: "Spec",
        description: "Spec preview",
        provider: "example",
        author: "Mo",
        mediaType: "article",
        durationSeconds: null,
        media: null,
      },
    ])
    expect(payload.messages[0].externalTasks).toEqual([
      {
        attachmentId: "502",
        id: "99",
        taskId: "task_99",
        application: "Linear",
        title: "Review spec",
        status: "in_progress",
        assignedUserId: "2",
        url: "https://linear.example/task_99",
        number: "LIN-99",
        date: "1000",
      },
    ])
  })

  it("messages.unread returns unread messages across chats", async () => {
    const inline = createInlineStub({
      async unreadMessages({ limit, since, until, content }) {
        expect(limit).toBe(10)
        expect(content).toBe("all")
        expect(typeof since).toBe("bigint")
        expect(typeof until).toBe("bigint")
        expect((since ?? 0n) <= (until ?? 0n)).toBe(true)
        return {
          scannedChats: 2,
          items: [
            {
              chat: {
                chatId: 7n,
                title: "General",
                chatTitle: "General",
                kind: "space_chat",
                spaceId: 10n,
                spaceName: "Inline",
                peerUserId: null,
                peerDisplayName: null,
                peerUsername: null,
                archived: false,
                pinned: false,
                unreadCount: 3,
                readMaxId: 20n,
                lastMessageId: 30n,
                lastMessageDate: 1000n,
              },
              message: { id: 30n, fromId: 2n, chatId: 7n, message: "unread", out: false, date: 1000n } as any,
            },
          ],
        }
      },
    })

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
        params: { name: "messages.unread", arguments: { limit: 10, since: "2024-12-31", until: "2024-12-31" } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.scannedChats).toBe(2)
    expect(payload.items).toHaveLength(1)
    expect(payload.items[0].chat.chatId).toBe("7")
    expect(payload.items[0].message.id).toBe("30")
  })

  it("conversations.create creates a new chat", async () => {
    const inline = createInlineStub({
      async createChat({ title, spaceId, participantUserIds }) {
        expect(title).toBe("Roadmap")
        expect(spaceId).toBe(10n)
        expect(participantUserIds).toEqual([2n, 3n])
        return {
          chatId: 77n,
          title: "Roadmap",
          chatTitle: "Roadmap",
          kind: "space_chat",
          spaceId: 10n,
          spaceName: "Inline",
          peerUserId: null,
          peerDisplayName: null,
          peerUsername: null,
          archived: false,
          pinned: false,
          unreadCount: 0,
          readMaxId: null,
          lastMessageId: null,
          lastMessageDate: null,
        }
      },
    })

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
        params: { name: "conversations.create", arguments: { title: "Roadmap", spaceId: "10", participantUserIds: ["2", "3"] } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.chat.chatId).toBe("77")
    expect(payload.chat.title).toBe("Roadmap")
  })

  it("files.upload uploads base64 media and returns uploaded ids", async () => {
    const inline = createInlineStub({
      async uploadFile({ type, file, fileName, contentType }) {
        expect(type).toBe("photo")
        expect(fileName).toBe("photo.png")
        expect(contentType).toBe("image/png")
        expect(file).toBeInstanceOf(Uint8Array)
        expect((file as Uint8Array).byteLength).toBeGreaterThan(0)
        return {
          fileUniqueId: "INP_1",
          media: { kind: "photo", id: 501n },
        }
      },
    })

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
        params: {
          name: "files.upload",
          arguments: {
            kind: "auto",
            base64: "data:image/png;base64,aGVsbG8=",
            fileName: "photo.png",
          },
        },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.ok).toBe(true)
    expect(payload.source).toBe("base64")
    expect(payload.upload.fileUniqueId).toBe("INP_1")
    expect(payload.upload.media.kind).toBe("photo")
    expect(payload.upload.media.id).toBe("501")
    expect(payload.upload.fileName).toBe("photo.png")
    expect(payload.upload.contentType).toBe("image/png")
  })

  it("files.upload rejects non-https urls", async () => {
    const inline = createInlineStub({})
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
        params: {
          name: "files.upload",
          arguments: {
            url: "http://example.com/file.png",
          },
        },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    expect(res.result.isError).toBe(true)
    expect(res.result.content?.[0]?.text).toContain("https")
  })

  it.each(["https://127.0.0.1/file.png", "https://[::1]/file.png"])(
    "files.upload rejects local url %s without fetching it",
    async (url) => {
      const fetchMock = vi.spyOn(globalThis, "fetch")
      const inline = createInlineStub({})
      const server = createInlineMcpServer({ grant, inline })
      const authInfo = createAuthInfo(["messages:write"])
      const { transport, sent } = await connectAndInitialize(server, authInfo)

      await sendRequest(
        transport,
        {
          jsonrpc: "2.0",
          id: 2,
          method: "tools/call",
          params: { name: "files.upload", arguments: { url } },
        } as any,
        { authInfo },
      )

      const res = await waitForResponse(sent, 2)
      expect(res.result.isError).toBe(true)
      expect(res.result.content?.[0]?.text).toContain("private or local")
      expect(fetchMock).not.toHaveBeenCalled()
    },
  )

  it.each(["legacy", "submission-v2"] as const)("%s sends rich Markdown unchanged through text, captions, and batches", async (contractVersion) => {
    const markdown = "    code();\n\n# Update\n\n**Ready** ~~old~~ ==new== <u>reviewed</u> $x^2$\n\n| Task | Status |\n| --- | --- |\n| Tests | Passed |\n"
    const sendMessage = vi.fn<InlineApi["sendMessage"]>().mockResolvedValue({ messageId: 300n, spaceId: 10n })
    const sendMediaMessage = vi.fn<InlineApi["sendMediaMessage"]>().mockResolvedValue({ messageId: 301n, spaceId: 10n })
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ sendMessage, sendMediaMessage }), contractVersion })
    const authInfo = createAuthInfo(["messages:write"])
    const { transport, sent } = await connectAndInitialize(server, authInfo)
    const calls = [
      { name: "messages.send", arguments: { chatId: "7", text: markdown, replyToMsgId: "9" } },
      { name: "messages.send_media", arguments: { chatId: "7", mediaKind: "photo", mediaId: "501", text: markdown } },
      { name: "messages.send_batch", arguments: { chatId: "7", items: contractVersion === "submission-v2"
        ? [{ type: "text", content: markdown }, { type: "photo", content: "501" }]
        : [{ type: "text", text: markdown }, { type: "media", mediaKind: "photo", mediaId: "501", text: markdown }] } },
      { name: "messages.send_media", arguments: { chatId: "7", mediaKind: "photo", mediaId: "501", text: " \n\t " } },
    ]
    try {
      for (const [index, params] of calls.entries()) {
        const id = index + 2
        await sendRequest(transport, { jsonrpc: "2.0", id, method: "tools/call", params } as any, { authInfo })
        expect((await waitForResponse(sent, id)).result.isError).not.toBe(true)
      }
      expect(sendMessage).toHaveBeenCalledTimes(2)
      expect(sendMessage.mock.calls.map(([input]) => input)).toEqual([
        { chatId: 7n, text: markdown, replyToMsgId: 9n, sendMode: "normal", parseMarkdown: true },
        { chatId: 7n, text: markdown, sendMode: "normal", parseMarkdown: true },
      ])
      expect(sendMediaMessage).toHaveBeenCalledTimes(3)
      expect(sendMediaMessage.mock.calls.map(([input]) => input)).toEqual([
        { chatId: 7n, media: { kind: "photo", id: 501n }, text: markdown, sendMode: "normal", parseMarkdown: true },
        { chatId: 7n, media: { kind: "photo", id: 501n }, ...(contractVersion === "legacy" ? { text: markdown } : {}), sendMode: "normal", parseMarkdown: true },
        { chatId: 7n, media: { kind: "photo", id: 501n }, sendMode: "normal", parseMarkdown: true },
      ])
    } finally {
      await server.close()
    }
  })

  it("messages.send_media sends uploaded media", async () => {
    const inline = createInlineStub({
      async sendMediaMessage({ userId, media, text, replyToMsgId, sendMode, parseMarkdown }) {
        expect(userId).toBe(2n)
        expect(media).toEqual({ kind: "photo", id: 501n })
        expect(text).toBe("caption")
        expect(replyToMsgId).toBe(9n)
        expect(sendMode).toBe("silent")
        expect(parseMarkdown).toBe(true)
        return { messageId: 300n, spaceId: null }
      },
    })
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
        params: {
          name: "messages.send_media",
          arguments: {
            userId: "2",
            mediaKind: "photo",
            mediaId: "501",
            text: "caption",
            replyToMsgId: "9",
            sendMode: "silent",
          },
        },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.ok).toBe(true)
    expect(payload.userId).toBe("2")
    expect(payload.messageId).toBe("300")
    expect(payload.media).toEqual({ kind: "photo", id: "501" })
    expect(payload.metadata).toEqual({ sendMode: "silent", replyToMsgId: "9" })
  })

  it("messages.send_batch sends mixed text/media items in order", async () => {
    let messageCounter = 900n
    const inline = createInlineStub({
      async sendMessage({ chatId, text, sendMode, parseMarkdown }) {
        expect(chatId).toBe(7n)
        expect(text).toBe("hello")
        expect(sendMode).toBe("normal")
        expect(parseMarkdown).toBe(true)
        messageCounter += 1n
        return { messageId: messageCounter, spaceId: 10n }
      },
      async sendMediaMessage({ chatId, media, text, sendMode, parseMarkdown }) {
        expect(chatId).toBe(7n)
        expect(media).toEqual({ kind: "document", id: 44n })
        expect(text).toBe("spec file")
        expect(sendMode).toBe("silent")
        expect(parseMarkdown).toBe(true)
        messageCounter += 1n
        return { messageId: messageCounter, spaceId: 10n }
      },
    })

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
        params: {
          name: "messages.send_batch",
          arguments: {
            chatId: "7",
            items: [
              { type: "text", text: "hello" },
              { type: "media", mediaKind: "document", mediaId: "44", text: "spec file", sendMode: "silent" },
            ],
          },
        },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.ok).toBe(true)
    expect(payload.chatId).toBe("7")
    expect(payload.total).toBe(2)
    expect(payload.sentCount).toBe(2)
    expect(payload.failedCount).toBe(0)
    expect(payload.results).toHaveLength(2)
    expect(payload.results[0].status).toBe("sent")
    expect(payload.results[0].type).toBe("text")
    expect(payload.results[1].status).toBe("sent")
    expect(payload.results[1].type).toBe("media")
    expect(payload.results[1].media).toEqual({ kind: "document", id: "44" })
  })

  it("messages.send requires messages:write", async () => {
    const infoSpy = vi.spyOn(console, "info").mockImplementation(() => {})

    const inline = createInlineStub({
      async sendMessage() {
        return { messageId: 123n }
      },
    })

    const server = createInlineMcpServer({
      grant,
      inline,
      resourceMetadataUrl: "https://mcp.example/.well-known/oauth-protected-resource",
    })
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
        params: { name: "messages.send", arguments: { chatId: "7", text: "hi", sendMode: "normal", replyToMsgId: "9" } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    expect(res.result.isError).toBe(true)
    expect(res.result.content?.[0]?.text).toContain("messages:write")
    const challenges = res.result._meta?.["mcp/www_authenticate"]
    expect(challenges).toEqual([expect.stringContaining('resource_metadata="https://mcp.example/.well-known/oauth-protected-resource"')])
    expect(challenges[0]).toContain('error="insufficient_scope"')
    expect(challenges[0]).toContain('scope="messages:write"')

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

  it.each(["legacy", "submission-v2"] as const)("%s executes exact reads, child creation, and ordered forwarding with schemas", async (contractVersion) => {
    const createSubthread = vi.fn<InlineApi["createSubthread"]>().mockResolvedValue({ chat: defaultEligibleChat({ chatId: 9n }), parentChatId: 7n, parentMessageId: 44n, anchorMessageId: 44n })
    const forwardMessages = vi.fn<InlineApi["forwardMessages"]>().mockResolvedValue({ sourceChat: defaultEligibleChat(), destinationChat: defaultEligibleChat({ chatId: 9n }), messages: [{ sourceMessageId: 44n, destinationMessageId: 101n }, { sourceMessageId: 44n, destinationMessageId: 102n }] })
    const getMessages = vi.fn<InlineApi["getMessages"]>().mockResolvedValue({ chat: defaultEligibleChat(), messages: [{ id: 43n, chatId: 7n, fromId: 2n, message: "second", out: false, date: 1n }, { id: 44n, chatId: 7n, fromId: 2n, message: "first", out: false, date: 1n }] })
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ createSubthread, forwardMessages, getMessages }), contractVersion })
    const authInfo = createAuthInfo(["messages:read", "messages:write"])
    const { transport, sent } = await connectAndInitialize(server, authInfo)
    const calls = [
      { name: "messages.get", arguments: { chatId: "7", messageIds: ["44", "43", "44", "42"] } },
      { name: "conversations.create_subthread", arguments: { parentChatId: "7", parentMessageId: "44", title: "Review", participantUserIds: ["2"] } },
      { name: "messages.forward", arguments: { sourceChatId: "7", destinationChatId: "9", messageIds: ["44", "44"], shareForwardHeader: false } },
    ]
    for (const [index, params] of calls.entries()) {
      await sendRequest(transport, { jsonrpc: "2.0", id: index + 2, method: "tools/call", params } as any, { authInfo })
      const response = await waitForResponse(sent, index + 2)
      expect(response.error).toBeUndefined()
      expect(response.result.isError).not.toBe(true)
      expect(response.result.structuredContent).toEqual(JSON.parse(response.result.content[0].text))
    }
    const read = (await waitForResponse(sent, 2)).result.structuredContent
    expect(read.messageIds).toEqual(["44", "43", "42"])
    expect(read.messages.map((message: any) => message.id)).toEqual(["44", "43"])
    expect(read.missingMessageIds).toEqual(["42"])
    expect(getMessages).toHaveBeenCalledWith({ chatId: 7n, messageIds: [44n, 43n, 42n] })
    expect(createSubthread).toHaveBeenCalledWith({ parentChatId: 7n, parentMessageId: 44n, title: "Review", participantUserIds: [2n] })
    expect(forwardMessages).toHaveBeenCalledWith({ sourceChatId: 7n, destinationChatId: 9n, messageIds: [44n, 44n], shareForwardHeader: false })
    expect((await waitForResponse(sent, 4)).result.structuredContent.messages).toEqual([
      { sourceMessageId: "44", destinationMessageId: "101", uri: "inline://chat/9/message/101" },
      { sourceMessageId: "44", destinationMessageId: "102", uri: "inline://chat/9/message/102" },
    ])
  })

  it.each([0, 2])("conversations.get propagates %s group grants without claiming direct users", async (groupParticipantCount) => {
    const defaults = createInlineStub({})
    const inline = createInlineStub({
      async getConversation(target) {
        return { ...await defaults.getConversation(target), groupParticipantCount, participants: [] }
      },
    })
    const server = createInlineMcpServer({ grant, inline })
    const authInfo = createAuthInfo(["messages:read"])
    const { transport, sent } = await connectAndInitialize(server, authInfo)
    await sendRequest(transport, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "conversations.get", arguments: { chatId: "7" } } } as any, { authInfo })
    const response = await waitForResponse(sent, 2)
    expect(response.result.isError).not.toBe(true)
    expect(response.result.structuredContent.details.groupParticipantCount).toBe(groupParticipantCount)
    expect(response.result.structuredContent.participants).toEqual([])
  })

  it.each(["messages:read", "messages:write"])("forwarding refuses missing %s with a reauthorization challenge", async (missingScope) => {
    const forwardMessages = vi.fn<InlineApi["forwardMessages"]>()
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ forwardMessages }), contractVersion: "submission-v2" })
    const authInfo = createAuthInfo(["messages:read", "messages:write"].filter((scope) => scope !== missingScope))
    const { transport, sent } = await connectAndInitialize(server, authInfo)
    await sendRequest(transport, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "messages.forward", arguments: { sourceChatId: "7", destinationChatId: "9", messageIds: ["44"] } } } as any, { authInfo })
    const response = await waitForResponse(sent, 2)
    expect(response.result.isError).toBe(true)
    expect(response.result._meta["mcp/www_authenticate"][0]).toContain(`scope="${missingScope}"`)
    expect(forwardMessages).not.toHaveBeenCalled()
  })

  it.each(["0", "0x7", " 7 ", "+7", "9223372036854775808"])("rejects invalid decimal IDs %s before new read handlers", async (chatId) => {
    const getMessages = vi.fn<InlineApi["getMessages"]>()
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ getMessages }), contractVersion: "submission-v2" })
    const authInfo = createAuthInfo(["messages:read"])
    const { transport, sent } = await connectAndInitialize(server, authInfo)
    await sendRequest(transport, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "messages.get", arguments: { chatId, messageIds: ["44"] } } } as any, { authInfo })
    const response = await waitForResponse(sent, 2)
    expect(response.result?.isError || response.error).toBeTruthy()
    expect(getMessages).not.toHaveBeenCalled()
  })

  it.each([
    { since: "2026-02-31", until: undefined, error: "calendar date does not exist" },
    { since: "2026-02-31T00:00:00Z", until: undefined, error: "calendar date does not exist" },
    { since: "2026-02-29T12:00:00+03:30", until: undefined, error: "calendar date does not exist" },
    { since: "200", until: "100", error: "since must be earlier" },
  ])("rejects invalid time ranges before searching: $since / $until", async ({ since, until, error }) => {
    const searchMessages = vi.fn<InlineApi["searchMessages"]>()
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ searchMessages }), contractVersion: "submission-v2" })
    const authInfo = createAuthInfo(["messages:read"])
    const { transport, sent } = await connectAndInitialize(server, authInfo)
    await sendRequest(transport, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "messages.search", arguments: { chatId: "7", query: "topic", since, ...(until ? { until } : {}) } } } as any, { authInfo })
    const response = await waitForResponse(sent, 2)
    expect(response.result.isError).toBe(true)
    expect(response.result.content[0].text).toContain(error)
    expect(searchMessages).not.toHaveBeenCalled()
  })

  it("parses UTC calendar bounds and sender/cursor selections before searching", async () => {
    const searchMessages = vi.fn<InlineApi["searchMessages"]>().mockResolvedValue({ chat: defaultEligibleChat(), query: "topic", content: "all", mode: "search", messages: [], nextOffsetId: 40n, scannedCount: 20 })
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ searchMessages }), contractVersion: "submission-v2" })
    const authInfo = createAuthInfo(["messages:read"])
    const { transport, sent } = await connectAndInitialize(server, authInfo)
    await sendRequest(transport, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "messages.search", arguments: { chatId: "7", query: "topic", since: "2026-09-29", until: "2026-09-29", senderUserId: "2", offsetId: "60" } } } as any, { authInfo })
    const response = await waitForResponse(sent, 2)
    expect(response.result.isError).not.toBe(true)
    expect(searchMessages).toHaveBeenCalledWith({ chatId: 7n, query: "topic", senderUserId: 2n, offsetId: 60n, limit: 20, content: "all", since: BigInt(Date.parse("2026-09-29T00:00:00Z") / 1000), until: BigInt(Date.parse("2026-09-29T23:59:59Z") / 1000) })
    expect(response.result.structuredContent).toMatchObject({ nextOffsetId: "40", scannedCount: 20, senderUserId: "2", messages: [] })
  })

  it.each([
    { timestamp: "2024-02-29T00:00:00+03:30", epochSeconds: BigInt(Date.UTC(2024, 1, 28, 20, 30) / 1000) },
    { timestamp: "2026-09-29T12:00:00+03:30", epochSeconds: BigInt(Date.UTC(2026, 8, 29, 8, 30) / 1000) },
  ])("preserves the valid written date and offset in $timestamp", async ({ timestamp, epochSeconds }) => {
    const searchMessages = vi.fn<InlineApi["searchMessages"]>().mockResolvedValue({ chat: defaultEligibleChat(), query: "topic", content: "all", mode: "search", messages: [], nextOffsetId: null, scannedCount: 0 })
    const server = createInlineMcpServer({ grant, inline: createInlineStub({ searchMessages }), contractVersion: "submission-v2" })
    const authInfo = createAuthInfo(["messages:read"])
    const { transport, sent } = await connectAndInitialize(server, authInfo)
    await sendRequest(transport, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "messages.search", arguments: { chatId: "7", query: "topic", since: timestamp, until: timestamp } } } as any, { authInfo })
    const response = await waitForResponse(sent, 2)
    expect(response.result.isError).not.toBe(true)
    expect(searchMessages).toHaveBeenCalledWith(expect.objectContaining({ since: epochSeconds, until: epochSeconds }))
  })

  it("messages.send succeeds with messages:write", async () => {
    const infoSpy = vi.spyOn(console, "info").mockImplementation(() => {})

    const inline = createInlineStub({
      async sendMessage({ userId, replyToMsgId }) {
        expect(userId).toBe(2n)
        expect(replyToMsgId).toBe(10n)
        return { messageId: 123n, spaceId: 10n }
      },
    })

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
        params: { name: "messages.send", arguments: { userId: "2", text: "hi", replyToMsgId: "10" } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.ok).toBe(true)
    expect(payload.messageId).toBe("123")
    expect(payload.userId).toBe("2")
    expect(payload.metadata).toEqual({ sendMode: "normal", replyToMsgId: "10" })

    const audit = lastMessagesSendAuditRecord(infoSpy)
    expect(audit.outcome).toBe("success")
    expect(audit.grantId).toBe("g1")
    expect(audit.inlineUserId).toBe("1")
    expect(audit.chatId).toBeNull()
    expect(audit.spaceId).toBe("10")
    expect(audit.messageId).toBe("123")
    expect(typeof audit.timestamp).toBe("string")
    expect(audit).not.toHaveProperty("text")
    expect(audit).not.toHaveProperty("token")
    expect(JSON.stringify(audit)).not.toContain("hi")
  })
})

describe("submission-v2 authorization boundary", () => {
  const calls = [
    ["spaces.list", {}],
    ["people.search", {}],
    ["conversations.list", {}],
    ["conversations.get", { chatId: "7" }],
    ["conversations.create", { title: "Test", spaceId: "10" }],
    ["files.upload", { sourceType: "base64", source: "aGVsbG8=", fileName: "hello.txt", contentType: "text/plain" }],
    ["files.get", { chatId: "7", messageIds: ["44"] }],
    ["messages.list", { chatId: "7" }],
    ["messages.search", { chatId: "7", query: "invoice" }],
    ["messages.context", { chatId: "7", anchorMessageId: "44" }],
    ["messages.unread", {}],
    ["messages.send", { chatId: "7", text: "hello" }],
    ["messages.send_media", { chatId: "7", mediaKind: "photo", mediaId: "501" }],
    ["messages.send_batch", { chatId: "7", items: [{ type: "text", content: "hello" }] }],
  ] as const

  it.each(calls)("%s rejects missing scopes before accessing Inline", async (name, args) => {
    const inline = createInlineStub({})
    const accesses = Object.entries(inline).filter(([method]) => method !== "close")
      .map(([method]) => vi.spyOn(inline, method as keyof InlineApi))
    const server = createInlineMcpServer({ inline, grant, contractVersion: "submission-v2" })
    try {
      const authInfo = createAuthInfo([])
      const { transport, sent } = await connectAndInitialize(server, authInfo)
      await sendRequest(transport, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name, arguments: args } } as any, { authInfo })
      const response = await waitForResponse(sent, 2)
      expect(response.result.isError).toBe(true)
      expect(response.result.content[0].text).toMatch(/scope/i)
      for (const access of accesses) expect(access).not.toHaveBeenCalled()
    } finally {
      await server.close()
      vi.restoreAllMocks()
    }
  })

  it("surfaces a transport failure and audits it without reporting a successful send", async () => {
    const info = vi.spyOn(console, "info").mockImplementation(() => {})
    const sendMessage = vi.fn().mockRejectedValue(new Error("Inline transport unavailable"))
    const server = createInlineMcpServer({ inline: createInlineStub({ sendMessage }), grant, contractVersion: "submission-v2" })
    try {
      const authInfo = createAuthInfo(["messages:write"])
      const { transport, sent } = await connectAndInitialize(server, authInfo)
      await sendRequest(transport, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "messages.send", arguments: { chatId: "7", text: "hello" } } } as any, { authInfo })
      const response = await waitForResponse(sent, 2)
      expect(response.result.isError).toBe(true)
      expect(response.result.content[0].text).toContain("Inline transport unavailable")
      expect(sendMessage).toHaveBeenCalledTimes(1)
      expect(lastMessagesSendAuditRecord(info)).toMatchObject({ outcome: "failure", chatId: "7", messageId: null })
    } finally {
      await server.close()
      vi.restoreAllMocks()
    }
  })
})
