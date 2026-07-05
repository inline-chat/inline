import { afterEach, describe, expect, it, vi } from "vitest"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import type { JSONRPCMessage } from "@modelcontextprotocol/sdk/types.js"
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js"
import { createInlineMcpServer } from "./server"
import type { McpGrant } from "./grant"
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
      "account.me",
      "spaces.list",
      "people.search",
      "conversations.list",
      "conversations.get",
      "conversations.create",
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

    for (const tool of tools) {
      expect(tool.outputSchema?.type).toBe("object")
      expect(tool._meta?.securitySchemes?.[0]?.type).toBe("oauth2")
    }

    const accountMe = tools.find((tool) => tool.name === "account.me")
    expect(accountMe.inputSchema).toMatchObject({ type: "object", properties: {} })
    expect(accountMe._meta.securitySchemes[0].scopes).toEqual([])

    const send = tools.find((tool) => tool.name === "messages.send")
    expect(send.description).toContain("Provide exactly one of chatId or userId")
    expect(send.annotations.readOnlyHint).toBe(false)
    expect(send.annotations.destructiveHint).toBe(false)
    expect(send.annotations.idempotentHint).toBe(false)
    expect(send._meta.securitySchemes[0].scopes).toEqual(["messages:write"])

    const list = tools.find((tool) => tool.name === "messages.list")
    expect(list.annotations.readOnlyHint).toBe(true)
    expect(list.outputSchema.properties.messages.type).toBe("array")
    expect(list.outputSchema.properties.messages.items.properties.uri.type).toBe("string")
    expect(list.inputSchema.properties.direction).toBeUndefined()
    expect(list.inputSchema.properties.unreadOnly).toBeUndefined()
    expect(send.inputSchema.properties.parseMarkdown).toBeUndefined()

    const spaces = tools.find((tool) => tool.name === "spaces.list")
    expect(spaces._meta.securitySchemes[0].scopes).toEqual(["spaces:read"])
    const context = tools.find((tool) => tool.name === "messages.context")
    expect(context.outputSchema.properties.messages.type).toBe("array")
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
          messages: [{ id: 14n, fromId: 2n, chatId: resolvedChatId, message: "invoice is sent", out: false, date: 999n } as any],
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
